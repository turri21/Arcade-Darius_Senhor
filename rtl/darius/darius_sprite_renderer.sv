/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Darius_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// darius_sprite_renderer — Sprite renderer.
// Legge entry sprite da local RAM (snooped dal CPU bus), fetch pixel dalla
// sprite ROM via SDRAM, disegna in line buffer. Supporta flip X/Y, priority,
// tiles 16x16 4bpp.
//
// Sprite RAM format (MAME, 4 words per entry at $E00100):
//   word[0]: Y position → sy = (256 - data) & 0x1FF
//   word[1]: X position → sx = data & 0x3FF
//   word[2]: tile code[12:0], flipX[14], flipY[15]
//   word[3]: priority[7], color[6:0]
//
// Sprite tiles: 16x16, 4bpp, 128 bytes each (32 SDRAM words)
// Layout: 4 quadrants (TL, TR, BL, BR), each 8x8, 4 planes
// SDRAM word = {plane3[7:0], plane2[7:0], plane1[7:0], plane0[7:0]}
// draw_sprites called with x_offs=xoffs (scroll-dependent), y_offs=-8

module darius_sprite_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire  [9:0] render_x,
	input  wire  [8:0] render_y,

	// X offset (scroll-dependent, from MAME draw_sprites x_offs parameter)
	input  wire  [9:0] x_offset,

	// Main CPU bus snoop (sprite RAM writes at $E00100-$E00FFF)
	input  wire [23:0] cpu_bus_addr,
	input  wire        cpu_bus_asn,
	input  wire        cpu_bus_rnw,
	input  wire  [1:0] cpu_bus_dsn,
	input  wire [15:0] cpu_bus_wdata,
	input  wire        cpu_bus_cs,

	// Sub CPU bus snoop (also writes sprite RAM)
	input  wire [23:0] sub_bus_addr,
	input  wire        sub_bus_asn,
	input  wire        sub_bus_rnw,
	input  wire  [1:0] sub_bus_dsn,
	input  wire [15:0] sub_bus_wdata,
	input  wire        sub_bus_cs,

	// Sprite ROM via SDRAM (32-bit reads)
	input  wire [31:0] spriterom_data,
	input  wire        spriterom_valid,
	output reg  [23:0] spriterom_addr,
	output reg         spriterom_req,

	// Palette lookup (shared with tile palette)
	input  wire [15:0] pal_data,       // xBGR555 from palette RAM
	output reg  [10:0] pal_lookup_addr, // {color[6:0], pixel[3:0]}

	// Pixel output
	// OSD adjustable offsets
	input  wire signed [9:0] spr_xoff, spr_yoff,

	output wire [23:0] sprite_rgb,
	output wire  [1:0] sprite_prio,
	output wire        sprite_opaque,
	output wire [12:0] dbg_disp_word
);

localparam H_ACTIVE = 10'd864;
localparam V_ACTIVE = 9'd224;
localparam Y_OFFSET = 9'd32;  // y_offs = -8 from MAME + north adjust

// =====================================================================
// CPU bus write detection (main + sub)
// =====================================================================
// Main CPU snoop
wire main_sprite_sel = (cpu_bus_addr >= 24'hE00100) && (cpu_bus_addr <= 24'hE00FFF);
wire main_write_active = ~cpu_bus_asn && ~cpu_bus_rnw && cpu_bus_cs && (cpu_bus_dsn != 2'b11);
reg main_write_seen;
always @(posedge clk) begin
	if (reset) main_write_seen <= 1'b0;
	else if (!main_write_active) main_write_seen <= 1'b0;
	else main_write_seen <= 1'b1;
end
wire main_wr_pulse = main_write_active && !main_write_seen;
wire main_spr_wr = main_wr_pulse && main_sprite_sel;

// Sub CPU snoop
wire sub_sprite_sel = (sub_bus_addr >= 24'hE00100) && (sub_bus_addr <= 24'hE00FFF);
wire sub_write_active = ~sub_bus_asn && ~sub_bus_rnw && sub_bus_cs && (sub_bus_dsn != 2'b11);
reg sub_write_seen;
always @(posedge clk) begin
	if (reset) sub_write_seen <= 1'b0;
	else if (!sub_write_active) sub_write_seen <= 1'b0;
	else sub_write_seen <= 1'b1;
end
wire sub_wr_pulse = sub_write_active && !sub_write_seen;
wire sub_spr_wr = sub_wr_pulse && sub_sprite_sel;

// Mux: main has priority if both write same cycle (unlikely)
wire spr_wr = main_spr_wr || sub_spr_wr;

// =====================================================================
// Local sprite RAM (snooped, 1920 words = 480 sprites × 4 words)
// =====================================================================
// Sprite RAM word address: $E00100[11:1]=0x080, $E00FFF[11:1]=0x7FF
// Subtract base 0x080 to get 0-based index (0 to 0x77F = 1919)
wire [10:0] main_spr_word_addr = cpu_bus_addr[11:1] - 11'h080;
wire [10:0] sub_spr_word_addr  = sub_bus_addr[11:1] - 11'h080;
wire [10:0] spr_wr_addr  = main_spr_wr ? main_spr_word_addr : sub_spr_word_addr;
wire [15:0] spr_wr_data  = main_spr_wr ? cpu_bus_wdata : sub_bus_wdata;
wire [1:0]  spr_wr_be    = main_spr_wr ? ~cpu_bus_dsn : ~sub_bus_dsn;
(* ramstyle = "no_rw_check" *) reg [7:0] spr_ram_hi [0:2047];
(* ramstyle = "no_rw_check" *) reg [7:0] spr_ram_lo [0:2047];
reg  [7:0] spr_rdata_hi, spr_rdata_lo;
reg [10:0] spr_rd_addr;
wire [15:0] spr_rdata = {spr_rdata_hi, spr_rdata_lo};

always @(posedge clk) begin
	if (spr_wr && spr_wr_be[1]) spr_ram_hi[spr_wr_addr] <= spr_wr_data[15:8];
	if (spr_wr && spr_wr_be[0]) spr_ram_lo[spr_wr_addr] <= spr_wr_data[7:0];
	spr_rdata_hi <= spr_ram_hi[spr_rd_addr];
	spr_rdata_lo <= spr_ram_lo[spr_rd_addr];
end

// =====================================================================
// Sprite line buffer (double-buffered)
// =====================================================================
// Entry: {priority[1:0], color[6:0], pixel[3:0]} = 13 bits, 0 = transparent
(* ramstyle = "no_rw_check" *) reg [12:0] spr_lb0 [0:1023];
(* ramstyle = "no_rw_check" *) reg [12:0] spr_lb1 [0:1023];
reg [12:0] spr_lb0_q, spr_lb1_q;

reg        spr_disp_sel;     // which buffer is being displayed
reg [12:0] spr_disp_word;
reg  [9:0] spr_disp_addr;

always @(posedge clk) begin
	spr_lb0_q <= spr_lb0[spr_disp_addr];
	spr_lb1_q <= spr_lb1[spr_disp_addr];
end

// Line buffer write
reg        lb_we;
reg  [9:0] lb_waddr;
reg [12:0] lb_wdata;
reg        lb_buf_sel;  // which buffer is being written (opposite of display)

always @(posedge clk) begin
	if (lb_we) begin
		if (lb_buf_sel)
			spr_lb1[lb_waddr] <= lb_wdata;
		else
			spr_lb0[lb_waddr] <= lb_wdata;
	end
end

// Display read
wire in_active = (render_x < H_ACTIVE) && (render_y < V_ACTIVE);
always @(posedge clk) begin
	spr_disp_addr <= (render_x < H_ACTIVE - 10'd1) ? render_x + 10'd1 : 10'd0;
end
// Combinatorial mux — matches panel renderer pipeline (no extra register stage)
always @(*) begin
	if (!in_active)
		spr_disp_word = 13'd0;
	else if (spr_disp_sel)
		spr_disp_word = spr_lb1_q;
	else
		spr_disp_word = spr_lb0_q;
end

// =====================================================================
// Pixel extraction: bit-per-plane (MAME method)
// =====================================================================
// Pixel extraction: bit-per-plane
//
// BYTE ORDER — HARDWARE VALIDATED (2026-03-31)
// The theoretical model of the MRA->WIDE=1->SDRAM->bridge path predicted:
//   tile_data = {a96_46, a96_47, a96_44, a96_45}
// But real MiSTer hardware produces a different byte order in row_data.
// This was confirmed by:
//   - Debug overlay showing PA=646 (pixel 6) where MAME expects pixel 5
//   - Systematic HW testing of 8+ permutations
//   - PA lookup live showing correct bank 0x64x entries with this mapping
// The effective byte layout observed on hardware is:
//   [31:24] = plane2 byte    [23:16] = plane3 byte
//   [15:8]  = plane0 byte    [7:0]   = plane1 byte
// The root cause is likely in how the HPS/framework packs MRA interleave
// output="32" bytes into WIDE=1 16-bit transfers — the two central bytes
// of the 32-bit word arrive swapped relative to the theoretical model.
//
// MAME pixel = {plane3_bit, plane2_bit, plane1_bit, plane0_bit}
function automatic [3:0] spr_get_pixel;
	input [31:0] row_data;
	input        hflip;
	input  [2:0] pix_idx;
	reg [2:0] bp;
	reg [7:0] p0, p1, p2, p3;
	begin
		bp = 3'd7 - pix_idx;   // flip handled by draw_x, not bit extraction
		p0 = row_data[23:16];  // plane 0 — original mapping (MRA reordered)
		p1 = row_data[7:0];    // plane 1
		p2 = row_data[31:24];  // plane 2
		p3 = row_data[15:8];   // plane 3
		spr_get_pixel = { p3[bp], p2[bp], p1[bp], p0[bp] };  // original nibble order
	end
endfunction

// =====================================================================
// Scan + render FSM
// =====================================================================
reg  [8:0] prev_render_y;
wire new_line = in_active && (render_y != prev_render_y);

// Scan state
localparam S_IDLE     = 4'd0;
localparam S_CLEAR    = 4'd1;
localparam S_READ_Y   = 4'd2;
localparam S_LATCH_Y  = 4'd3;
localparam S_READ_X   = 4'd4;
localparam S_LATCH_X  = 4'd5;
localparam S_READ_CODE = 4'd6;
localparam S_LATCH_CODE = 4'd7;
localparam S_READ_ATTR = 4'd8;
localparam S_CHECK    = 4'd9;
localparam S_FETCH_ROM = 4'd10;
localparam S_WAIT_ROM = 4'd11;
localparam S_DRAW     = 4'd12;
localparam S_NEXT     = 4'd13;
localparam S_WAIT_Y   = 4'd14;  // BRAM latency wait for Y word

reg  [3:0] scan_state;
reg  [8:0] scan_idx;       // sprite index (0-479 max)
reg  [9:0] clear_addr;
reg  [8:0] prep_line_y;    // line being prepared

// Sprite attributes
reg  [8:0] cur_sy;
reg signed [10:0] cur_sx;
reg [12:0] cur_code;
reg        cur_flipx, cur_flipy;
reg  [6:0] cur_color;
reg        cur_prio;
reg [31:0] cur_romdata;

// Draw state
reg  [3:0] draw_pix;       // pixel counter within row (0-15)
reg  [3:0] draw_row_in_spr; // which row of sprite hits this line
reg  [3:0] row_diff_hit;

always @(posedge clk) begin
	lb_we <= 1'b0;
	spriterom_req <= 1'b0;

	if (reset) begin
		prev_render_y <= 9'h1FF;
		scan_state    <= S_IDLE;
		scan_idx      <= 0;
		clear_addr    <= 0;
		spr_disp_sel  <= 0;
		lb_buf_sel    <= 1;
		prep_line_y   <= 0;
	end else begin
		if (new_line) prev_render_y <= render_y;

		case (scan_state)
			S_IDLE: begin
				if (new_line) begin
					// Swap buffers and start preparing next line
					spr_disp_sel <= lb_buf_sel;
					lb_buf_sel   <= ~lb_buf_sel;
					prep_line_y  <= (render_y >= V_ACTIVE - 9'd1) ? 9'd0 : render_y + 9'd1;
					clear_addr   <= 0;
					scan_state   <= S_CLEAR;
				end
			end

			// Clear the write buffer
			S_CLEAR: begin
				lb_we    <= 1'b1;
				lb_waddr <= clear_addr;
				lb_wdata <= 13'd0;
				if (clear_addr == H_ACTIVE - 10'd1) begin
					scan_idx   <= 9'd479;  // draw order: 479→0 (first sprite wins)
					scan_state <= S_READ_Y;
				end else
					clear_addr <= clear_addr + 10'd1;
			end

			// Read sprite entry word 0 (Y)
			S_READ_Y: begin
				spr_rd_addr <= {scan_idx, 2'b00};
				scan_state  <= S_WAIT_Y;
			end

			S_WAIT_Y: begin
				// BRAM latency: addr registered at S_READ_Y, data available now
				scan_state <= S_LATCH_Y;
			end

			S_LATCH_Y: begin
				reg [8:0] sy_calc;
				reg [8:0] row_diff;
				sy_calc = (9'd256 - spr_rdata[8:0] - 9'd16 + spr_yoff[8:0]) & 9'h1FF;  // MAME y_offs=-8, +8 north
				row_diff = (prep_line_y - sy_calc) & 9'h1FF;
				cur_sy <= sy_calc;
				if (row_diff < 9'd16) begin
					row_diff_hit <= row_diff[3:0];
					spr_rd_addr  <= {scan_idx, 2'b01};
					scan_state   <= S_READ_X;
				end else begin
					scan_state <= S_NEXT;
				end
			end

			// Read word 1 (X)
			S_READ_X: begin
				scan_state <= S_LATCH_X;
			end

			S_LATCH_X: begin
				// MAME: curx = sx - x_offs; if (curx > 900) curx -= 1024;
				begin
					reg signed [10:0] sx_raw;
					sx_raw = {1'b0, spr_rdata[9:0]} - {1'b0, x_offset} + spr_xoff;
					cur_sx <= (sx_raw > 11'sd900) ? (sx_raw - 11'sd1024) : sx_raw;
				end
				spr_rd_addr <= {scan_idx, 2'b10};
				scan_state <= S_READ_CODE;
			end

			// Read word 2 (code + flip)
			S_READ_CODE: begin
				scan_state <= S_LATCH_CODE;
			end

			S_LATCH_CODE: begin
				cur_code  <= spr_rdata[12:0];
				cur_flipx <= spr_rdata[14];
				cur_flipy <= spr_rdata[15];
				spr_rd_addr <= {scan_idx, 2'b11};
				scan_state <= S_READ_ATTR;
			end

			// Read word 3 (color + priority)
			S_READ_ATTR: begin
				scan_state <= S_CHECK;
			end

			// Check if sprite is on this line
			S_CHECK: begin
				cur_color <= spr_rdata[6:0];
				cur_prio  <= spr_rdata[7];

				if (cur_code != 13'd0) begin
					draw_row_in_spr <= cur_flipy ? (4'd15 - row_diff_hit) : row_diff_hit;
					scan_state <= S_FETCH_ROM;
				end else begin
					scan_state <= S_NEXT;
				end
			end

			// Fetch sprite ROM data for this row
			S_FETCH_ROM: begin
				// Sprite ROM address calculation:
				// Each sprite = 128 bytes = 32 words (16-bit) = 16 words (32-bit)
				// 4 quadrants: TL(rows 0-7, cols 0-7), TR(rows 0-7, cols 8-15),
				//              BL(rows 8-15, cols 0-7), BR(rows 8-15, cols 8-15)
				// Each quadrant = 8 rows × 1 word/row = 8 words (32-bit)
				//
				// For row R in sprite:
				//   if R < 8: quadrant = TL (word offset 0) for cols 0-7
				//   if R >= 8: quadrant = BL (word offset 16) for cols 0-7
				//   Right half: +8 words
				//
				// Byte address = sprite_code × 128 + quadrant_offset + row_in_quad × 4
				// We fetch left half first, then right half in S_DRAW

				// Left half address
				spriterom_addr <= {cur_code, draw_row_in_spr[3], 1'b0, draw_row_in_spr[2:0], 2'b00};
				spriterom_req  <= 1'b1;
				draw_pix       <= 0;
				scan_state     <= S_WAIT_ROM;
			end

			S_WAIT_ROM: begin
				if (spriterom_valid) begin
					cur_romdata <= spriterom_data;
					scan_state  <= S_DRAW;
				end
			end

			// Draw 8 pixels from current ROM word (bit-per-plane, MAME method)
			S_DRAW: begin
				reg [3:0] pixel;
				reg signed [10:0] draw_x;

				pixel = spr_get_pixel(cur_romdata, cur_flipx, draw_pix[2:0]);
				draw_x = cur_flipx ? (cur_sx + (11'sd15 - {7'd0, draw_pix})) : (cur_sx + {7'd0, draw_pix});

				if (pixel != 4'd0 && draw_x >= 0 && draw_x < $signed({1'b0, H_ACTIVE})) begin
					lb_we    <= 1'b1;
					lb_waddr <= draw_x[9:0];
					lb_wdata <= {1'b0, cur_prio, cur_color, pixel};
				end

				if (draw_pix == 4'd7) begin
					// Fetch right half
					spriterom_addr <= {cur_code, draw_row_in_spr[3], 1'b1, draw_row_in_spr[2:0], 2'b00};
					spriterom_req  <= 1'b1;
					draw_pix       <= 4'd8;
					scan_state     <= S_WAIT_ROM;
				end else if (draw_pix == 4'd15) begin
					scan_state <= S_NEXT;
				end else begin
					draw_pix <= draw_pix + 4'd1;
				end
			end

			// Advance to next sprite
			S_NEXT: begin
				if (scan_idx == 9'd0) begin
					scan_state <= S_IDLE;
				end else begin
					scan_idx   <= scan_idx - 9'd1;  // draw order: 479→0
					scan_state <= S_READ_Y;
				end
			end

			default: scan_state <= S_IDLE;
		endcase
	end
end

// =====================================================================
// Output: line buffer → palette → RGB
// =====================================================================
wire [3:0] disp_pixel = spr_disp_word[3:0];
wire [6:0] disp_color = spr_disp_word[10:4];
wire       disp_prio  = spr_disp_word[11];
wire       disp_hit   = (disp_pixel != 4'd0) && in_active;

// Register palette address (1 cycle latency)
always @(posedge clk) begin
	pal_lookup_addr <= {disp_color, disp_pixel};
end

// Delay opaque/prio by 2 clocks to align with pal_data:
//   Cycle N:   spr_disp_word available (combinatorial)
//   Cycle N+1: pal_lookup_addr registered here
//   Cycle N+2: sprite_pal_data registered in darius_dual68k_top.sv
// So opaque/prio need 2 stages, not 1.
reg        disp_hit_d,  disp_hit_dd;
reg        disp_prio_d, disp_prio_dd;
always @(posedge clk) begin
	disp_hit_d   <= disp_hit;
	disp_prio_d  <= disp_prio;
	disp_hit_dd  <= disp_hit_d;
	disp_prio_dd <= disp_prio_d;
end

// xBGR555 → RGB888
wire [7:0] out_r = {pal_data[4:0],  pal_data[4:2]};
wire [7:0] out_g = {pal_data[9:5],  pal_data[9:7]};
wire [7:0] out_b = {pal_data[14:10], pal_data[14:12]};

assign sprite_rgb    = {out_r, out_g, out_b};
assign sprite_prio   = {1'b0, disp_prio_dd};
assign sprite_opaque = disp_hit_dd;
assign dbg_disp_word = spr_disp_word;

endmodule
