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

// darius_dual68k_top — Top-level del core Darius.
// Istanzia entrambe le CPU 68000 (main + sub), memory maps, shared/sprite/
// FG/palette RAM, sprite renderer, FG renderer, 3 panel renderer (L/C/R),
// vram arbiter, sdram bridge, audio Z80 subsystem, triple screen composer.

module darius_dual68k_top
#(
	parameter [1:0] MAIN_CORE_IMPL    = 2'd1,
	parameter [1:0] SUB_CORE_IMPL     = 2'd1,
	parameter       HOLD_SUB_IN_RESET = 1'b0,
	parameter       ENABLE_C00050_NOP = 1'b1,
	parameter       ENABLE_WATCHDOG   = 1'b1,
	parameter       ENABLE_PC080_CTRL = 1'b1,
	parameter       ENABLE_DC0000     = 1'b1,
	parameter       ENABLE_C00060     = 1'b1,
	parameter       ENABLE_C00020     = 1'b1,
	parameter       ENABLE_C00022     = 1'b1,
	parameter       ENABLE_C00024     = 1'b1,
	parameter       ENABLE_C00030     = 1'b1,
	parameter       ENABLE_C00032     = 1'b1,
	parameter       ENABLE_C00034     = 1'b1,
	parameter       ENABLE_D40000     = 1'b1,
	parameter       ENABLE_D40002     = 1'b1,
	parameter       ENABLE_D20000     = 1'b1,
	parameter       ENABLE_D20002     = 1'b1,
	parameter       ENABLE_C0000C     = 1'b1,
	parameter       ENABLE_C00010     = 1'b1,
	parameter       ENABLE_MAIN_PC060HA_PORT = 1'b1,
	parameter       ENABLE_MAIN_PC060HA_COMM = 1'b1,
	parameter       ENABLE_MAIN_D00000 = 1'b1,
	parameter       ENABLE_MAIN_PALETTE = 1'b1,
	parameter       ENABLE_FG_RAM      = 1'b1,
	parameter       ENABLE_MAIN_CTRL  = 1'b1,
	parameter       ENABLE_MAIN_SHARED = 1'b1,
	parameter       ENABLE_MAIN_SPRITE = 1'b1,
	parameter       ENABLE_MAIN_IO    = 1'b1,
	parameter       ENABLE_MAIN_VIDEO = 1'b1,
	parameter       ENABLE_MAIN_PLAYER_IO = 1'b1,
	parameter       ENABLE_SUB_SHARED = 1'b1,
	parameter       ENABLE_SUB_SPRITE = 1'b1,
	parameter       ENABLE_SUB_PALETTE = 1'b1,
	parameter       ENABLE_SUB_IO     = 1'b1,
	parameter       ENABLE_VBLANK_IRQ = 1'b1
)
(
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,
	input  wire  [2:0] clk_sel,      // Main CPU: 000=8MHz, 001=12MHz, 010=16MHz, 011=24MHz, 100=32MHz*, 101=48MHz*
	input  wire  [2:0] sub_clk_sel,   // Sub CPU: 000=8MHz, 001=12MHz, 010=16MHz, 011=24MHz, 100=32MHz*, 101=48MHz*
	input  wire  [1:0] z80_clk_sel,  // Z80: 00=4MHz, 01=8MHz, 10=2MHz, 11=1MHz
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire  [7:0] system_input,   // MAME SYSTEM port: {00,start2,start1,tilt,service,coin2,coin1}
	input  wire [15:0] dsw_input,
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,
	input  wire [15:0] sub_rom_rdata,
	input  wire        sub_rom_ready,
	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,
	input  wire [31:0] tilerom_data,
	input  wire        tilerom_valid,
	output wire [23:0] main_rom_addr,
	output wire        main_rom_req,
	output wire [23:0] sub_rom_addr,
	output wire        sub_rom_req,
	output wire [23:0] tilerom_addr,
	output wire        tilerom_req,
	output wire        tilerom_is_sprite,
	output wire        tilerom_is_text,
	// Audio ROM download (ioctl → BRAM inside audio module)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	output wire [23:0] fg_rgb,
	output wire        fg_opaque,
	output wire [15:0] xscroll_l0,
	output wire [15:0] xscroll_l1,
	output wire [15:0] yscroll_l0,
	output wire [15:0] yscroll_l1,
	output wire [15:0] ctrl_l0,
	output wire [15:0] ctrl_l1,
	output wire [23:0] tile_rgb,
	output wire [1:0]  tile_prio,
	output wire        tile_opaque,
	output wire [23:0] sprite_rgb,
	output wire  [1:0] sprite_prio,
	output wire        sprite_opaque,
	// OSD layer offsets
	input  wire signed [9:0] l0_xoff, l0_yoff,
	input  wire signed [9:0] l1_xoff, l1_yoff,
	input  wire signed [9:0] spr_xoff, spr_yoff,
	input  wire signed [9:0] fg_xoff, fg_yoff,
	// Text ROM download for FG BRAM
	input  wire        fg_dl_wr,
	input  wire [13:0] fg_dl_addr,
	input  wire [15:0] fg_dl_data,
	// Audio output
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r
);

// ── Forward declarations (needed by ModelSim) ────────────────────────────
wire [23:0] main_bus_addr;
wire [23:0] sub_bus_addr;
wire        main_bus_asn;
wire        sub_bus_asn;
wire        main_bus_rnw;
wire        sub_bus_rnw;
wire [1:0]  main_bus_dsn;
wire [1:0]  sub_bus_dsn;
wire [15:0] main_bus_dout;
wire [15:0] sub_bus_dout;
wire [15:0] main_bus_rdata;
wire [15:0] sub_bus_rdata;
wire        main_bus_cs;
wire        sub_bus_cs;
wire        main_bus_busy;
wire        sub_bus_busy;
wire [15:0] shared_main_rdata;
wire [15:0] shared_sub_rdata;
wire        shared_main_ready;
wire        shared_sub_ready;
wire        main_shared_rd;
wire        main_shared_wr;
wire [11:0] main_shared_addr;
wire [15:0] main_shared_wdata;
wire        sub_shared_rd;
wire        sub_shared_wr;
wire [11:0] sub_shared_addr;
wire [15:0] sub_shared_wdata;
wire [15:0] main_ram_rdata;
wire [15:0] main_e100_rdata;
wire [15:0] sub_ram_rdata;
wire [15:0] d000_main_rdata;
wire [15:0] palette_main_rdata;
wire [15:0] sprite_main_rdata;
wire [15:0] sprite_sub_rdata;
wire        sprite_main_ready;
wire        sprite_sub_ready;
wire        main_sprite_rd;
wire        main_sprite_wr;
wire [10:0] main_sprite_addr;
wire [15:0] main_sprite_wdata;
wire        sub_sprite_rd;
wire        sub_sprite_wr;
wire [10:0] sub_sprite_addr;
wire [15:0] sub_sprite_wdata;
wire [15:0] fg_main_rdata;
wire [15:0] fg_sub_rdata;
wire        fg_main_ready;
wire        fg_sub_ready;
wire        main_fg_rd;
wire        main_fg_wr;
wire [13:0] main_fg_addr;
wire [15:0] main_fg_wdata;
wire        sub_fg_rd;
wire        sub_fg_wr;
wire [13:0] sub_fg_addr;
wire [15:0] sub_fg_wdata;
wire        main_ram_rd;
wire        main_ram_wr;
wire  [1:0] main_ram_be;
wire  [1:0] main_bus_be;
wire  [1:0] sub_bus_be = ~sub_bus_dsn;
wire [14:0] main_ram_addr;
wire [15:0] main_ram_wdata;
wire        main_e100_rd;
wire        main_e100_wr;
wire [10:0] main_e100_addr;
wire [15:0] main_e100_wdata;
wire        main_d000_rd;
wire        main_d000_wr;
wire [14:0] main_d000_addr;
wire [15:0] main_d000_wdata;
wire        main_palette_rd;
wire        main_palette_wr;
wire [10:0] main_palette_addr;
wire [15:0] main_palette_wdata;
wire        palette_main_ready;
wire        sub_palette_wr;
wire [10:0] sub_palette_addr;
wire [15:0] sub_palette_wdata;
wire        palette_sub_ready;
wire [15:0] palette_sub_rdata;
wire        sub_ram_rd;
wire        sub_ram_wr;
wire [14:0] sub_ram_addr;
wire [15:0] sub_ram_wdata;
wire        cpua_ctrl_wr;
wire [7:0]  cpua_ctrl_data;
wire        main_pc060ha_port_wr;
wire [7:0]  main_pc060ha_port_data;
wire        main_pc060ha_comm_wr;
wire [7:0]  main_pc060ha_comm_data;
reg  [7:0]  cpua_ctrl_reg;
reg  [7:0]  main_pc060ha_port_reg;
reg  [7:0]  main_pc060ha_comm_reg;
wire        main_iack;
wire        sub_iack;
wire [2:0]  main_ipl_n;
wire [2:0]  sub_ipl_n;
wire        pc060_snd_cs;
wire        pc060_snd_addr;
wire        pc060_snd_wr;
wire        pc060_snd_rd;
wire  [7:0] pc060_snd_wdata;
wire  [7:0] pc060_snd_rdata;
wire        pc060_snd_nmi_n;
wire        pc060_snd_reset;

// --- VBlank IRQ4 generation (cpp: set_vblank_int irq4_line_hold, both CPUs) ---

generate if (ENABLE_VBLANK_IRQ) begin : gen_vblank_irq
	// 60Hz VBlank from render_y: assert when render_y enters vblank region
	// V_ACTIVE=224, vblank starts at vc >= 224 (render_y = screen_y)
	wire vblank_area = (render_y >= 9'd224);
	reg  vblank_prev;
	reg  main_irq4_pending;
	reg  sub_irq4_pending;

	always @(posedge clk) begin
		if (reset) begin
			vblank_prev       <= 1'b0;
			main_irq4_pending <= 1'b0;
			sub_irq4_pending  <= 1'b0;
		end else begin
			vblank_prev <= vblank_area;
			// Rising edge of vblank → assert IRQ4
			if (vblank_area && !vblank_prev) begin
				main_irq4_pending <= 1'b1;
				sub_irq4_pending  <= 1'b1;
			end
			// Clear on IACK
			if (main_iack) main_irq4_pending <= 1'b0;
			if (sub_iack)  sub_irq4_pending  <= 1'b0;
		end
	end

	// IRQ4 = level 4 → ipl_n = ~3'd4 = 3'b011
	assign main_ipl_n = main_irq4_pending ? 3'b011 : 3'b111;
	assign sub_ipl_n  = sub_irq4_pending  ? 3'b011 : 3'b111;
end else begin : gen_no_vblank
	assign main_ipl_n = 3'b111;
	assign sub_ipl_n  = 3'b111;
end
endgenerate

always @(posedge clk) begin
	if (reset)
		cpua_ctrl_reg <= 8'h00;
	else if (cpua_ctrl_wr)
		cpua_ctrl_reg <= cpua_ctrl_data;
end

always @(posedge clk) begin
	if (reset)
		main_pc060ha_port_reg <= 8'h00;
	else if (main_pc060ha_port_wr)
		main_pc060ha_port_reg <= main_pc060ha_port_data;
end

always @(posedge clk) begin
	if (reset)
		main_pc060ha_comm_reg <= 8'h00;
	else if (main_pc060ha_comm_wr)
		main_pc060ha_comm_reg <= main_pc060ha_comm_data;
end

// PC060HA — real protocol handler (jtrastan_pc060 rewrite, single clock)
wire [7:0] pc060ha_main_rdata;

// Main 68K CS: active when accessing C00000-C00003
wire pc060_main_cs = ~main_bus_asn & main_bus_cs &
                     (main_bus_addr >= 24'hC00000) & (main_bus_addr <= 24'hC00003);
wire pc060_main_addr = main_bus_addr[1];  // 0=port (C00000), 1=comm (C00002)
wire pc060_main_wr = pc060_main_cs & ~main_bus_rnw;
wire pc060_main_rd = pc060_main_cs &  main_bus_rnw;

pc060ha_link u_pc060ha (
	.clk(clk),
	.reset(reset),
	// Main 68000 side
	.main_cs(pc060_main_cs),
	.main_addr(pc060_main_addr),
	.main_wr(pc060_main_wr),
	.main_rd(pc060_main_rd),
	.main_wdata(main_bus_dout[7:0]),
	.main_rdata(pc060ha_main_rdata),
	// Sound Z80 side
	.snd_cs(pc060_snd_cs),
	.snd_addr(pc060_snd_addr),
	.snd_wr(pc060_snd_wr),
	.snd_rd(pc060_snd_rd),
	.snd_wdata(pc060_snd_wdata),
	.snd_rdata(pc060_snd_rdata),
	// Control outputs
	.snd_nmi_n(pc060_snd_nmi_n),
	.snd_reset(pc060_snd_reset),
	.dbg_snd_full(),
	.dbg_main_full()
);

// Main CPU clock divider (96MHz / den)
reg [7:0] main_clk_den;
always @(*) case (clk_sel)
	3'd0: main_clk_den = 8'd12;  // 96/12 = 8MHz (original, default)
	3'd1: main_clk_den = 8'd8;   // 96/8  = 12MHz
	3'd2: main_clk_den = 8'd6;   // 96/6  = 16MHz
	3'd3: main_clk_den = 8'd4;   // 96/4  = 24MHz
	3'd4: main_clk_den = 8'd3;   // 96/3  = 32MHz
	3'd5: main_clk_den = 8'd2;   // 96/2  = 48MHz
	default: main_clk_den = 8'd12;
endcase

// Sub CPU clock divider (96MHz / den)
reg [7:0] sub_clk_den;
always @(*) case (sub_clk_sel)
	3'd0: sub_clk_den = 8'd12;  // 96/12 = 8MHz (original, default)
	3'd1: sub_clk_den = 8'd8;   // 96/8  = 12MHz
	3'd2: sub_clk_den = 8'd6;   // 96/6  = 16MHz
	3'd3: sub_clk_den = 8'd4;   // 96/4  = 24MHz
	3'd4: sub_clk_den = 8'd3;   // 96/3  = 32MHz
	3'd5: sub_clk_den = 8'd2;   // 96/2  = 48MHz
	default: sub_clk_den = 8'd12;
endcase

darius_cpu_node #(
	.CPU_ID(1'b0),
	.CORE_IMPL(MAIN_CORE_IMPL)
) u_main_cpu (
	.clk(clk),
	.reset(reset),
	.soft_reset(1'b0),
	.halt_n(~pause),
	.clk_num(7'd1),
	.clk_den(main_clk_den),
	.ipl_n(main_ipl_n),
	.bus_din(main_bus_rdata),
	.bus_cs(main_bus_cs),
	.bus_busy(main_bus_busy),
	.dev_br(1'b0),
	.bus_addr(main_bus_addr),
	.bus_asn(main_bus_asn),
	.bus_rnw(main_bus_rnw),
	.bus_dsn(main_bus_dsn),
	.bus_dout(main_bus_dout),
	.dbg_pc(),
	.dbg_fc(),
	.dbg_dtackn(),
	.dbg_fave(),
	.dbg_fworst(),
	.iack(main_iack)
);

darius_cpu_node #(
	.CPU_ID(1'b1),
	.CORE_IMPL(SUB_CORE_IMPL)
) u_sub_cpu (
	.clk(clk),
	.reset(reset),
	.soft_reset(HOLD_SUB_IN_RESET ? 1'b1 : ~cpua_ctrl_reg[0]),
	.halt_n(~pause),
	.clk_num(7'd1),
	.clk_den(sub_clk_den),
	.ipl_n(sub_ipl_n),
	.bus_din(sub_bus_rdata),
	.bus_cs(sub_bus_cs),
	.bus_busy(sub_bus_busy),
	.dev_br(1'b0),
	.bus_addr(sub_bus_addr),
	.bus_asn(sub_bus_asn),
	.bus_rnw(sub_bus_rnw),
	.bus_dsn(sub_bus_dsn),
	.bus_dout(sub_bus_dout),
	.dbg_pc(),
	.dbg_fc(),
	.dbg_dtackn(),
	.dbg_fave(),
	.dbg_fworst(),
	.iack(sub_iack)
);

darius_maincpu_map #(
	.ENABLE_NOP_C00050(ENABLE_C00050_NOP),
	.ENABLE_WATCHDOG(ENABLE_WATCHDOG),
	.ENABLE_PC080_CTRL(ENABLE_PC080_CTRL),
	.ENABLE_DC0000(ENABLE_DC0000),
	.ENABLE_C00060(ENABLE_C00060),
	.ENABLE_C00020(ENABLE_C00020),
	.ENABLE_C00022(ENABLE_C00022),
	.ENABLE_C00024(ENABLE_C00024),
	.ENABLE_C00030(ENABLE_C00030),
	.ENABLE_C00032(ENABLE_C00032),
	.ENABLE_C00034(ENABLE_C00034),
	.ENABLE_D40000(ENABLE_D40000),
	.ENABLE_D40002(ENABLE_D40002),
	.ENABLE_D20000(ENABLE_D20000),
	.ENABLE_D20002(ENABLE_D20002),
	.ENABLE_C0000C(ENABLE_C0000C),
	.ENABLE_C00010(ENABLE_C00010),
	.ENABLE_PC060HA_PORT(ENABLE_MAIN_PC060HA_PORT),
	.ENABLE_PC060HA_COMM(ENABLE_MAIN_PC060HA_COMM),
	.ENABLE_D00000(ENABLE_MAIN_D00000),
	.ENABLE_PALETTE(ENABLE_MAIN_PALETTE),
	.ENABLE_FG(ENABLE_FG_RAM),
	.ENABLE_CTRL(ENABLE_MAIN_CTRL),
	.ENABLE_SHARED(ENABLE_MAIN_SHARED),
	.ENABLE_SPRITE(ENABLE_MAIN_SPRITE),
	.ENABLE_IO(ENABLE_MAIN_IO),
	.ENABLE_VIDEO(ENABLE_MAIN_VIDEO),
	.ENABLE_PLAYER_IO(ENABLE_MAIN_PLAYER_IO)
) u_main_map
(
	.clk(clk),
	.reset(reset),
	.p1_input(p1_input),
	.p2_input(p2_input),
	.system_input(system_input),
	.dsw_input(dsw_input),
	.bus_addr(main_bus_addr),
	.bus_asn(main_bus_asn),
	.bus_rnw(main_bus_rnw),
	.bus_dsn(main_bus_dsn),
	.bus_wdata(main_bus_dout),
	.bus_rdata(main_bus_rdata),
	.bus_cs(main_bus_cs),
	.bus_busy(main_bus_busy),
	.rom_rdata(main_rom_rdata),
	.rom_ready(main_rom_ready),
	.cpua_ctrl_q(cpua_ctrl_reg),
	.shared_rdata(shared_main_rdata),
	.shared_ready(shared_main_ready),
	.shared_rd(main_shared_rd),
	.shared_wr(main_shared_wr),
	.shared_addr(main_shared_addr),
	.shared_wdata(main_shared_wdata),
	.sprite_rdata(sprite_main_rdata),
	.sprite_ready(sprite_main_ready),
	.sprite_rd(main_sprite_rd),
	.sprite_wr(main_sprite_wr),
	.sprite_addr(main_sprite_addr),
	.sprite_wdata(main_sprite_wdata),
	.fg_rdata(fg_main_rdata),
	.fg_ready(fg_main_ready),
	.fg_rd(main_fg_rd),
	.fg_wr(main_fg_wr),
	.fg_addr(main_fg_addr),
	.fg_wdata(main_fg_wdata),
	.ram_rdata(main_ram_rdata),
	.ram_rd(main_ram_rd),
	.ram_wr(main_ram_wr),
	.ram_be(main_ram_be),
	.bus_byte_en(main_bus_be),
	.ram_addr(main_ram_addr),
	.ram_wdata(main_ram_wdata),
	.e100_rdata(main_e100_rdata),
	.e100_rd(main_e100_rd),
	.e100_wr(main_e100_wr),
	.e100_addr(main_e100_addr),
	.e100_wdata(main_e100_wdata),
	.d000_rdata(d000_main_rdata),
	.d000_rd(main_d000_rd),
	.d000_wr(main_d000_wr),
	.d000_addr(main_d000_addr),
	.d000_wdata(main_d000_wdata),
	.palette_rdata(palette_main_rdata),
	.palette_ready(palette_main_ready),
	.palette_rd(main_palette_rd),
	.palette_wr(main_palette_wr),
	.palette_addr(main_palette_addr),
	.palette_wdata(main_palette_wdata),
	.cpua_ctrl_wr(cpua_ctrl_wr),
	.cpua_ctrl_data(cpua_ctrl_data),
	.pc060ha_port_wr(main_pc060ha_port_wr),
	.pc060ha_port_data(main_pc060ha_port_data),
	.pc060ha_comm_wr(main_pc060ha_comm_wr),
	.pc060ha_comm_data(main_pc060ha_comm_data),
	.pc060ha_comm_rdata(pc060ha_main_rdata),
	.rom_addr(main_rom_addr),
	.rom_req(main_rom_req),
	.cs_vector()
);

darius_subcpu_map #(
	.ENABLE_NOP_C00050(ENABLE_C00050_NOP),
	.ENABLE_SHARED(ENABLE_SUB_SHARED),
	.ENABLE_SPRITE(ENABLE_SUB_SPRITE),
	.ENABLE_FG(ENABLE_FG_RAM),
	.ENABLE_PALETTE(ENABLE_SUB_PALETTE),
	.ENABLE_IO(ENABLE_SUB_IO)
) u_sub_map
(
	.clk(clk),
	.reset(reset),
	.bus_addr(sub_bus_addr),
	.bus_asn(sub_bus_asn),
	.bus_rnw(sub_bus_rnw),
	.bus_dsn(sub_bus_dsn),
	.bus_wdata(sub_bus_dout),
	.bus_rdata(sub_bus_rdata),
	.bus_cs(sub_bus_cs),
	.bus_busy(sub_bus_busy),
	.rom_rdata(sub_rom_rdata),
	.rom_ready(sub_rom_ready),
	.shared_rdata(shared_sub_rdata),
	.shared_ready(shared_sub_ready),
	.shared_rd(sub_shared_rd),
	.shared_wr(sub_shared_wr),
	.shared_addr(sub_shared_addr),
	.shared_wdata(sub_shared_wdata),
	.sprite_rdata(sprite_sub_rdata),
	.sprite_ready(sprite_sub_ready),
	.sprite_rd(sub_sprite_rd),
	.sprite_wr(sub_sprite_wr),
	.sprite_addr(sub_sprite_addr),
	.sprite_wdata(sub_sprite_wdata),
	.fg_rdata(fg_sub_rdata),
	.fg_ready(fg_sub_ready),
	.fg_rd(sub_fg_rd),
	.fg_wr(sub_fg_wr),
	.fg_addr(sub_fg_addr),
	.fg_wdata(sub_fg_wdata),
	.ram_rdata(sub_ram_rdata),
	.ram_rd(sub_ram_rd),
	.ram_wr(sub_ram_wr),
	.ram_addr(sub_ram_addr),
	.ram_wdata(sub_ram_wdata),
	.palette_ready(palette_sub_ready),
	.palette_wr(sub_palette_wr),
	.palette_addr(sub_palette_addr),
	.palette_wdata(sub_palette_wdata),
	.rom_addr(sub_rom_addr),
	.rom_req(sub_rom_req),
	.cs_vector()
);

darius_shared_ram #(
	.ADDR_WIDTH(12)
) u_shared_ram
(
	.clk(clk),
	.main_rd(main_shared_rd),
	.main_wr(main_shared_wr),
	.main_be(main_bus_be),
	.main_addr(main_shared_addr),
	.main_wdata(main_shared_wdata),
	.main_rdata(shared_main_rdata),
	.main_ready(shared_main_ready),
	.sub_rd(sub_shared_rd),
	.sub_wr(sub_shared_wr),
	.sub_be(sub_bus_be),
	.sub_addr(sub_shared_addr),
	.sub_wdata(sub_shared_wdata),
	.sub_rdata(shared_sub_rdata),
	.sub_ready(shared_sub_ready)
);

darius_shared_ram #(
	.ADDR_WIDTH(11)
) u_sprite_ram
(
	.clk(clk),
	.main_rd(main_sprite_rd),
	.main_wr(main_sprite_wr),
	.main_be(main_bus_be),
	.main_addr(main_sprite_addr),
	.main_wdata(main_sprite_wdata),
	.main_rdata(sprite_main_rdata),
	.main_ready(sprite_main_ready),
	.sub_rd(sub_sprite_rd),
	.sub_wr(sub_sprite_wr),
	.sub_be(sub_bus_be),
	.sub_addr(sub_sprite_addr),
	.sub_wdata(sub_sprite_wdata),
	.sub_rdata(sprite_sub_rdata),
	.sub_ready(sprite_sub_ready)
);

// FG RAM — dual BRAM (primary + mirror) to eliminate cross-port
// read/write collision on no_rw_check M10K.
// Primary: main Port A (R/W) + sub Port B (R/W, no renderer).
// Mirror:  main Port A (write only, read ignored) +
//          sub Port B write + renderer Port B read (tiny mux, sub_wr has priority).
// Both RAMs receive identical writes from main and sub. Renderer reads
// exclusively from mirror Port B: zero collisions with sub reads.
wire [13:0] fg_render_addr;
wire [15:0] fg_render_rdata;
wire        fg_render_stall;

// Mirror Port B mux: sub_wr (priority, rare) vs renderer read (default)
wire mirror_sub_active = sub_fg_wr;  // sub READS go to primary only
wire        mirror_portb_rd    = mirror_sub_active ? 1'b0          : 1'b1;
wire        mirror_portb_wr    = mirror_sub_active ? sub_fg_wr     : 1'b0;
wire [1:0]  mirror_portb_be    = mirror_sub_active ? sub_bus_be    : 2'b11;
wire [13:0] mirror_portb_addr  = mirror_sub_active ? sub_fg_addr   : fg_render_addr;
wire [15:0] mirror_portb_wdata = sub_fg_wdata;
wire [15:0] mirror_portb_rdata;
wire        mirror_portb_ready;

// Stall renderer when sub writes on mirror (same 2-cycle recovery as old mux)
reg mirror_sub_active_d, mirror_sub_active_d2;
always @(posedge clk) begin
	if (reset) begin mirror_sub_active_d <= 1'b0; mirror_sub_active_d2 <= 1'b0; end
	else begin mirror_sub_active_d <= mirror_sub_active; mirror_sub_active_d2 <= mirror_sub_active_d; end
end
assign fg_render_stall = mirror_sub_active | mirror_sub_active_d | mirror_sub_active_d2;
assign fg_render_rdata = mirror_portb_rdata;

// Primary FG RAM — CPU-visible (main_rdata, sub_rdata come from here)
darius_shared_ram #(
	.ADDR_WIDTH(14)
) u_fg_ram
(
	.clk(clk),
	.main_rd(main_fg_rd),
	.main_wr(main_fg_wr),
	.main_be(main_bus_be),
	.main_addr(main_fg_addr),
	.main_wdata(main_fg_wdata),
	.main_rdata(fg_main_rdata),
	.main_ready(fg_main_ready),
	.sub_rd(sub_fg_rd),
	.sub_wr(sub_fg_wr),
	.sub_be(sub_bus_be),
	.sub_addr(sub_fg_addr),
	.sub_wdata(sub_fg_wdata),
	.sub_rdata(fg_sub_rdata),
	.sub_ready(fg_sub_ready)
);

// Mirror FG RAM — renderer reads exclusively from here
darius_shared_ram #(
	.ADDR_WIDTH(14)
) u_fg_ram_mirror
(
	.clk(clk),
	.main_rd(1'b0),
	.main_wr(main_fg_wr),
	.main_be(main_bus_be),
	.main_addr(main_fg_addr),
	.main_wdata(main_fg_wdata),
	.main_rdata(/* unused */),
	.main_ready(/* unused */),
	.sub_rd(mirror_portb_rd),
	.sub_wr(mirror_portb_wr),
	.sub_be(mirror_portb_be),
	.sub_addr(mirror_portb_addr),
	.sub_wdata(mirror_portb_wdata),
	.sub_rdata(mirror_portb_rdata),
	.sub_ready(mirror_portb_ready)
);

darius_local_ram #(
	.ADDR_WIDTH(15)
) u_main_ram (
	.clk(clk),
	.rd(main_ram_rd),
	.wr(main_ram_wr),
	.be(main_ram_be),
	.addr(main_ram_addr),
	.wdata(main_ram_wdata),
	.rdata(main_ram_rdata)
);

darius_local_ram #(
	.ADDR_WIDTH(11)
) u_main_e100_ram (
	.clk(clk),
	.rd(main_e100_rd),
	.wr(main_e100_wr),
	.be(main_bus_be),
	.addr(main_e100_addr),
	.wdata(main_e100_wdata),
	.rdata(main_e100_rdata)
);

darius_shared_ram #(
	.ADDR_WIDTH(11)
) u_palette_ram (
	.clk(clk),
	.main_rd(main_palette_rd),
	.main_wr(main_palette_wr),
	.main_be(main_bus_be),
	.main_addr(main_palette_addr),
	.main_wdata(main_palette_wdata),
	.main_rdata(palette_main_rdata),
	.main_ready(palette_main_ready),
	.sub_rd(1'b0),
	.sub_wr(sub_palette_wr),
	.sub_be(sub_bus_be),
	.sub_addr(sub_palette_addr),
	.sub_wdata(sub_palette_wdata),
	.sub_rdata(palette_sub_rdata),
	.sub_ready(palette_sub_ready)
);

darius_local_ram #(
	.ADDR_WIDTH(15)
) u_sub_ram (
	.clk(clk),
	.rd(sub_ram_rd),
	.wr(sub_ram_wr),
	.be(sub_bus_be),
	.addr(sub_ram_addr),
	.wdata(sub_ram_wdata),
	.rdata(sub_ram_rdata)
);

// =====================================================================
// 3 parallel panel renderers + tile ROM arbiter
// =====================================================================

// =====================================================================
// Shared VRAM for 3 panel renderers (replaces 3 internal copies)
// =====================================================================
// Unified VRAM: True Dual-Port M10K
//   Port A: CPU read + write (from maincpu_map d000 interface, with byte enable)
//   Port B: renderer read (from VRAM arbiter, read-only)
// Replaces both d000_ram (64 M10K) and shared_vram (52 M10K) → saves 64 M10K.
// =====================================================================
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] unified_vram_hi [0:32767];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] unified_vram_lo [0:32767];

// Port A: CPU (read + write with byte enable)
reg [15:0] vram_cpu_rdata;
always @(posedge clk) begin
	if (main_d000_wr) begin
		if (main_bus_be[1]) unified_vram_hi[main_d000_addr] <= main_d000_wdata[15:8];
		if (main_bus_be[0]) unified_vram_lo[main_d000_addr] <= main_d000_wdata[7:0];
	end
	vram_cpu_rdata <= {unified_vram_hi[main_d000_addr], unified_vram_lo[main_d000_addr]};
end
assign d000_main_rdata = vram_cpu_rdata;

// Port B: renderer (read-only, via VRAM arbiter)
reg [15:0] shared_vram_rdata;
wire [14:0] shared_vram_rd_addr;
always @(posedge clk) begin
	shared_vram_rdata <= {unified_vram_hi[shared_vram_rd_addr], unified_vram_lo[shared_vram_rd_addr]};
end

// Per-panel VRAM read ports
wire [14:0] r0_vram_addr, r1_vram_addr, r2_vram_addr;
wire        r0_vram_req,  r1_vram_req,  r2_vram_req;
wire [15:0] r0_vram_data, r1_vram_data, r2_vram_data;
wire        r0_vram_valid, r1_vram_valid, r2_vram_valid;

darius_vram_arbiter u_vram_arb (
	.clk(clk), .reset(reset),
	.p0_addr(r0_vram_addr), .p0_req(r0_vram_req), .p0_data(r0_vram_data), .p0_valid(r0_vram_valid),
	.p1_addr(r1_vram_addr), .p1_req(r1_vram_req), .p1_data(r1_vram_data), .p1_valid(r1_vram_valid),
	.p2_addr(r2_vram_addr), .p2_req(r2_vram_req), .p2_data(r2_vram_data), .p2_valid(r2_vram_valid),
	.vram_addr(shared_vram_rd_addr), .vram_data(shared_vram_rdata)
);

// Per-renderer tile ROM interface
wire [23:0] r0_tilerom_addr, r1_tilerom_addr, r2_tilerom_addr;
wire        r0_tilerom_req,  r1_tilerom_req,  r2_tilerom_req;
wire [31:0] r0_tilerom_data, r1_tilerom_data, r2_tilerom_data;
wire        r0_tilerom_valid, r1_tilerom_valid, r2_tilerom_valid;

// Per-renderer pixel output
wire [23:0] r0_rgb, r1_rgb, r2_rgb;
wire [1:0]  r0_prio, r1_prio, r2_prio;
wire        r0_opaque, r1_opaque, r2_opaque;

// Debug from LEFT renderer only

// LEFT panel (pixels 0-287)
darius_panel_renderer #(.X_OFFSET(10'd0), .H_PIXELS(10'd288)) u_render_left (
	.clk(clk), .reset(reset),
	.render_x(render_x), .render_y(render_y),
	.cpu_bus_addr(main_bus_addr), .cpu_bus_asn(main_bus_asn),
	.cpu_bus_rnw(main_bus_rnw), .cpu_bus_dsn(main_bus_dsn),
	.cpu_bus_wdata(main_bus_dout), .cpu_bus_cs(main_bus_cs),
	.sub_pal_wr(sub_palette_wr), .sub_pal_addr(sub_palette_addr),
	.sub_pal_wdata(sub_palette_wdata), .sub_pal_be(sub_bus_be),
	.vram_rd_addr(r0_vram_addr), .vram_rd_req(r0_vram_req), .vram_rd_data(r0_vram_data), .vram_rd_valid(r0_vram_valid),
	.tilerom_data(r0_tilerom_data), .tilerom_valid(r0_tilerom_valid),
	.tilerom_addr(r0_tilerom_addr), .tilerom_req(r0_tilerom_req),
	.xscroll_l0(xscroll_l0), .xscroll_l1(xscroll_l1),
	.yscroll_l0(yscroll_l0), .yscroll_l1(yscroll_l1),
	.ctrl_l0(ctrl_l0), .ctrl_l1(ctrl_l1),
	.l0_xoff(l0_xoff), .l0_yoff(l0_yoff), .l1_xoff(l1_xoff), .l1_yoff(l1_yoff),
	.tile_rgb(r0_rgb), .tile_prio(r0_prio), .tile_opaque(r0_opaque),
	.dbg_tile_code(), .dbg_tile_attr(),
	.dbg_tile_romdata()
);

// CENTER panel (pixels 288-575)
darius_panel_renderer #(.X_OFFSET(10'd288), .H_PIXELS(10'd288)) u_render_center (
	.clk(clk), .reset(reset),
	.render_x(render_x), .render_y(render_y),
	.cpu_bus_addr(main_bus_addr), .cpu_bus_asn(main_bus_asn),
	.cpu_bus_rnw(main_bus_rnw), .cpu_bus_dsn(main_bus_dsn),
	.cpu_bus_wdata(main_bus_dout), .cpu_bus_cs(main_bus_cs),
	.sub_pal_wr(sub_palette_wr), .sub_pal_addr(sub_palette_addr),
	.sub_pal_wdata(sub_palette_wdata), .sub_pal_be(sub_bus_be),
	.vram_rd_addr(r1_vram_addr), .vram_rd_req(r1_vram_req), .vram_rd_data(r1_vram_data), .vram_rd_valid(r1_vram_valid),
	.tilerom_data(r1_tilerom_data), .tilerom_valid(r1_tilerom_valid),
	.tilerom_addr(r1_tilerom_addr), .tilerom_req(r1_tilerom_req),
	.xscroll_l0(), .xscroll_l1(),
	.yscroll_l0(), .yscroll_l1(),
	.ctrl_l0(), .ctrl_l1(),
	.l0_xoff(l0_xoff), .l0_yoff(l0_yoff), .l1_xoff(l1_xoff), .l1_yoff(l1_yoff),
	.tile_rgb(r1_rgb), .tile_prio(r1_prio), .tile_opaque(r1_opaque),
	.dbg_tile_code(), .dbg_tile_attr(), .dbg_tile_romdata()
);

// RIGHT panel (pixels 576-863)
darius_panel_renderer #(.X_OFFSET(10'd576), .H_PIXELS(10'd288)) u_render_right (
	.clk(clk), .reset(reset),
	.render_x(render_x), .render_y(render_y),
	.cpu_bus_addr(main_bus_addr), .cpu_bus_asn(main_bus_asn),
	.cpu_bus_rnw(main_bus_rnw), .cpu_bus_dsn(main_bus_dsn),
	.cpu_bus_wdata(main_bus_dout), .cpu_bus_cs(main_bus_cs),
	.sub_pal_wr(sub_palette_wr), .sub_pal_addr(sub_palette_addr),
	.sub_pal_wdata(sub_palette_wdata), .sub_pal_be(sub_bus_be),
	.vram_rd_addr(r2_vram_addr), .vram_rd_req(r2_vram_req), .vram_rd_data(r2_vram_data), .vram_rd_valid(r2_vram_valid),
	.tilerom_data(r2_tilerom_data), .tilerom_valid(r2_tilerom_valid),
	.tilerom_addr(r2_tilerom_addr), .tilerom_req(r2_tilerom_req),
	.xscroll_l0(), .xscroll_l1(),
	.yscroll_l0(), .yscroll_l1(),
	.ctrl_l0(), .ctrl_l1(),
	.l0_xoff(l0_xoff), .l0_yoff(l0_yoff), .l1_xoff(l1_xoff), .l1_yoff(l1_yoff),
	.tile_rgb(r2_rgb), .tile_prio(r2_prio), .tile_opaque(r2_opaque),
	.dbg_tile_code(), .dbg_tile_attr(), .dbg_tile_romdata()
);

// Sprite renderer ROM interface
wire [23:0] sprite_romaddr;
wire        sprite_romreq;
wire [31:0] sprite_romdata;
wire        sprite_romvalid;

// FG text renderer (text ROM in local BRAM, no SDRAM)
wire [10:0] fg_pal_addr;
reg  [15:0] fg_pal_data;

// FG palette: snooped copy (same bus write detection as panel renderer)
wire fg_pal_bus_active = ~main_bus_asn && ~main_bus_rnw && main_bus_cs && (main_bus_dsn != 2'b11);
reg  fg_pal_write_seen;
always @(posedge clk) begin
	if (reset) fg_pal_write_seen <= 1'b0;
	else if (!fg_pal_bus_active) fg_pal_write_seen <= 1'b0;
	else fg_pal_write_seen <= 1'b1;
end
wire fg_pal_wr_pulse = fg_pal_bus_active && !fg_pal_write_seen;
wire fg_pal_sel = (main_bus_addr >= 24'hD80000) && (main_bus_addr <= 24'hD80FFF);
wire fg_pal_wr = fg_pal_wr_pulse && fg_pal_sel;

// Split into HI/LO byte RAMs so byte enables are respected on byte writes.
// Previous single-word write corrupted the non-selected byte on move.b to palette,
// producing grey blocks in Japan set (uses move.b on palette).
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] fg_pal_ram_hi [0:2047];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] fg_pal_ram_lo [0:2047];
always @(posedge clk) begin
	if (fg_pal_wr) begin
		if (main_bus_be[1]) fg_pal_ram_hi[main_bus_addr[11:1]] <= main_bus_dout[15:8];
		if (main_bus_be[0]) fg_pal_ram_lo[main_bus_addr[11:1]] <= main_bus_dout[7:0];
	end else if (sub_palette_wr) begin
		if (sub_bus_be[1]) fg_pal_ram_hi[sub_palette_addr] <= sub_palette_wdata[15:8];
		if (sub_bus_be[0]) fg_pal_ram_lo[sub_palette_addr] <= sub_palette_wdata[7:0];
	end
	fg_pal_data <= {fg_pal_ram_hi[fg_pal_addr], fg_pal_ram_lo[fg_pal_addr]};
end


darius_fg_renderer u_fg_renderer (
	.clk(clk), .reset(reset),
	.render_x(render_x), .render_y(render_y),
	.fg_ram_addr(fg_render_addr),
	.fg_ram_rdata(fg_render_rdata),
	.fg_stall(fg_render_stall),
	.dl_wr(fg_dl_wr), .dl_addr(fg_dl_addr), .dl_data(fg_dl_data),
	.fg_xoff(fg_xoff), .fg_yoff(fg_yoff),
	.pal_addr(fg_pal_addr), .pal_data(fg_pal_data),
	.fg_rgb(fg_rgb), .fg_opaque(fg_opaque)
);

// GFX ROM arbiter: 3 tile + 1 sprite + 1 FG text -> 1 bridge Port0
tile_rom_arbiter u_tile_arb (
	.clk(clk), .reset(reset),
	.hblank(render_x >= 10'd864),
	.r0_req(r0_tilerom_req), .r0_addr(r0_tilerom_addr),
	.r0_data(r0_tilerom_data), .r0_valid(r0_tilerom_valid),
	.r1_req(r1_tilerom_req), .r1_addr(r1_tilerom_addr),
	.r1_data(r1_tilerom_data), .r1_valid(r1_tilerom_valid),
	.r2_req(r2_tilerom_req), .r2_addr(r2_tilerom_addr),
	.r2_data(r2_tilerom_data), .r2_valid(r2_tilerom_valid),
	.r3_req(sprite_romreq), .r3_addr(sprite_romaddr),
	.r3_data(sprite_romdata), .r3_valid(sprite_romvalid),
	.r4_req(1'b0), .r4_addr(24'd0),
	.r4_data(), .r4_valid(),
	.tile_req(tilerom_req), .tile_addr(tilerom_addr),
	.tile_is_sprite(tilerom_is_sprite),
	.tile_is_text(tilerom_is_text),
	.tile_data(tilerom_data), .tile_valid(tilerom_valid)
);

// Output mux: select panel based on render_x
assign tile_rgb    = (render_x < 10'd288) ? r0_rgb :
                     (render_x < 10'd576) ? r1_rgb : r2_rgb;
assign tile_prio   = (render_x < 10'd288) ? r0_prio :
                     (render_x < 10'd576) ? r1_prio : r2_prio;
assign tile_opaque = (render_x < 10'd288) ? r0_opaque :
                     (render_x < 10'd576) ? r1_opaque : r2_opaque;


// =====================================================================
// Sprite renderer
// =====================================================================
// Sprite palette: shared with tile palette in panel renderer LEFT
// We need a separate palette read port for sprites — use a dedicated copy
wire [10:0] sprite_pal_addr;
reg  [15:0] sprite_pal_data;

// Sprite palette RAM (snooped from CPU, same as tile palette)
wire spr_pal_sel = (main_bus_addr >= 24'hD80000) && (main_bus_addr <= 24'hD80FFF);
wire spr_pal_wr_active = ~main_bus_asn && ~main_bus_rnw && main_bus_cs && (main_bus_dsn != 2'b11);
reg  spr_pal_seen;
always @(posedge clk) begin
	if (reset) spr_pal_seen <= 0;
	else if (!spr_pal_wr_active) spr_pal_seen <= 0;
	else spr_pal_seen <= 1;
end
wire spr_pal_wr = spr_pal_wr_active && !spr_pal_seen && spr_pal_sel;

(* ramstyle = "M10K,no_rw_check" *) reg [7:0] spr_pal_ram_hi [0:2047];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] spr_pal_ram_lo [0:2047];
always @(posedge clk) begin
	if (spr_pal_wr) begin
		if (main_bus_be[1]) spr_pal_ram_hi[main_bus_addr[11:1]] <= main_bus_dout[15:8];
		if (main_bus_be[0]) spr_pal_ram_lo[main_bus_addr[11:1]] <= main_bus_dout[7:0];
	end else if (sub_palette_wr) begin
		if (sub_bus_be[1]) spr_pal_ram_hi[sub_palette_addr] <= sub_palette_wdata[15:8];
		if (sub_bus_be[0]) spr_pal_ram_lo[sub_palette_addr] <= sub_palette_wdata[7:0];
	end
	sprite_pal_data <= {spr_pal_ram_hi[sprite_pal_addr], spr_pal_ram_lo[sprite_pal_addr]};
end

darius_sprite_renderer u_sprite (
	.clk(clk), .reset(reset),
	.render_x(render_x), .render_y(render_y),
	.x_offset(10'd0),  // wide-screen: sprites use raw sx, no panel offset needed
	.cpu_bus_addr(main_bus_addr), .cpu_bus_asn(main_bus_asn),
	.cpu_bus_rnw(main_bus_rnw), .cpu_bus_dsn(main_bus_dsn),
	.cpu_bus_wdata(main_bus_dout), .cpu_bus_cs(main_bus_cs),
	.sub_bus_addr(sub_bus_addr), .sub_bus_asn(sub_bus_asn),
	.sub_bus_rnw(sub_bus_rnw), .sub_bus_dsn(sub_bus_dsn),
	.sub_bus_wdata(sub_bus_dout), .sub_bus_cs(sub_bus_cs),
	.spriterom_data(sprite_romdata), .spriterom_valid(sprite_romvalid),
	.spriterom_addr(sprite_romaddr), .spriterom_req(sprite_romreq),
	.spr_xoff(spr_xoff), .spr_yoff(spr_yoff),
	.pal_data(sprite_pal_data), .pal_lookup_addr(sprite_pal_addr),
	.sprite_rgb(sprite_rgb), .sprite_prio(sprite_prio), .sprite_opaque(sprite_opaque),
	.dbg_disp_word()
);

// =====================================================================
// Audio subsystem — 2× Z80 + YM2203 ×2 + MSM5205 + PC060HA
// =====================================================================
darius_audio_z80 u_audio (
	.clk(clk), .reset(reset),
	.pause(pause),
	.clk_sel(z80_clk_sel),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.snd_cs(pc060_snd_cs),
	.snd_addr(pc060_snd_addr),
	.snd_wr(pc060_snd_wr),
	.snd_rd(pc060_snd_rd),
	.snd_wdata(pc060_snd_wdata),
	.snd_rdata(pc060_snd_rdata),
	.snd_nmi_n(pc060_snd_nmi_n),
	.snd_reset_in(pc060_snd_reset),
	.audio_l(audio_l), .audio_r(audio_r)
);

endmodule
