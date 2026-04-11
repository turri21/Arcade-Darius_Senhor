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

// darius_audio_z80 — Sottosistema audio.
// Z80 #1 (main audio): YM2203 ×2 + PC060HA slave + ROM bank-switched.
// Z80 #2 (ADPCM): MSM5205 ADPCM, ROM-only (no RAM).
// Memory maps e I/O per comunicazione con Main CPU via PC060HA.
//
// MAME memory maps:
//   Z80 #1: 0000-3FFF ROM (fixed), 4000-7FFF ROM (banked, 4×16KB),
//           8000-8FFF RAM (4KB), 9000-9001 YM2203#1, A000-A001 YM2203#2,
//           B000 PC060HA port_w, B001 PC060HA comm R/W,
//           C000/C400/C800/CC00/D000 pan regs, D400 ADPCM cmd, DC00 bank switch
//   Z80 #2: 0000-FFFF ROM (flat, no RAM), I/O port 00 = ADPCM command from Z80#1

module darius_audio_z80 (
	input  wire        clk,          // 96 MHz system clock
	input  wire        reset,
	input  wire        pause,        // halt Z80+YM when high (keeps sync with main)
	input  wire  [1:0] clk_sel,      // 00=4MHz, 01=8MHz, 10=2MHz, 11=1MHz

	// ROM download (ioctl) — fills BRAM during MRA load
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,

	// PC060HA sound side — directly to/from PC060HA
	output wire        snd_cs,        // CS active during B000-B001 access
	output wire        snd_addr,      // 0=port (B000), 1=comm (B001)
	output wire        snd_wr,
	output wire        snd_rd,
	output wire  [7:0] snd_wdata,
	input  wire  [7:0] snd_rdata,
	input  wire        snd_nmi_n,     // NMI from PC060HA (active low)
	input  wire        snd_reset_in,  // reset from PC060HA

	// Audio output
	output reg signed [15:0] audio_l,
	output reg signed [15:0] audio_r
);

// =====================================================================
// Clock enable: selectable Z80 speed from 96 MHz
// =====================================================================
reg [6:0] ce_cnt;
reg [6:0] ce_div;

always @(*) case (clk_sel)
	2'd0: ce_div = 7'd24;   // 96/24 = 4 MHz (original)
	2'd1: ce_div = 7'd12;   // 96/12 = 8 MHz
	2'd2: ce_div = 7'd48;   // 96/48 = 2 MHz
	2'd3: ce_div = 7'd96;   // 96/96 = 1 MHz
endcase

wire ce_4m_raw   = (ce_cnt == ce_div - 7'd1);
wire ce_4m_n_raw = (ce_cnt == (ce_div >> 1) - 7'd1);
wire ce_4m   = ce_4m_raw   & ~pause;
wire ce_4m_n = ce_4m_n_raw & ~pause;

always @(posedge clk) begin
	if (reset)
		ce_cnt <= 0;
	else
		ce_cnt <= ce_4m ? 7'd0 : ce_cnt + 7'd1;
end

// =====================================================================
// Audio ROM BRAM — loaded via ioctl during MRA download
// =====================================================================
localparam [26:0] Z80A_ROM_BASE = 27'h1C8000;
localparam [26:0] Z80B_ROM_BASE = 27'h1D8000;

wire z80a_rom_dl = ioctl_download && ioctl_wr &&
                   (ioctl_addr >= Z80A_ROM_BASE) && (ioctl_addr < Z80B_ROM_BASE);
wire z80b_rom_dl = ioctl_download && ioctl_wr &&
                   (ioctl_addr >= Z80B_ROM_BASE) && (ioctl_addr < (Z80B_ROM_BASE + 27'h10000));

// Z80 #1 ROM: 64KB, split into even/odd byte arrays
(* ramstyle = "M10K" *) reg [7:0] z80a_rom_even [0:32767];
(* ramstyle = "M10K" *) reg [7:0] z80a_rom_odd  [0:32767];
reg [7:0] z80a_rom_q;
wire [16:0] z80a_rom_dl_off = ioctl_addr - Z80A_ROM_BASE;
wire [14:0] z80a_rom_dl_word = z80a_rom_dl_off[15:1];

always @(posedge clk) begin
	if (z80a_rom_dl) begin
		z80a_rom_even[z80a_rom_dl_word] <= ioctl_dout[7:0];    // WIDE=1: [7:0] = even byte (confirmed by overlay R2=C3)
		z80a_rom_odd[z80a_rom_dl_word]  <= ioctl_dout[15:8];   // WIDE=1: [15:8] = odd byte
	end
end

// Z80 #2 ROM: 64KB, same split
(* ramstyle = "M10K" *) reg [7:0] z80b_rom_even [0:32767];
(* ramstyle = "M10K" *) reg [7:0] z80b_rom_odd  [0:32767];
reg [7:0] z80b_rom_q;
wire [16:0] z80b_rom_dl_off = ioctl_addr - Z80B_ROM_BASE;
wire [14:0] z80b_rom_dl_word = z80b_rom_dl_off[15:1];

always @(posedge clk) begin
	if (z80b_rom_dl) begin
		z80b_rom_even[z80b_rom_dl_word] <= ioctl_dout[7:0];
		z80b_rom_odd[z80b_rom_dl_word]  <= ioctl_dout[15:8];
	end
end

// =====================================================================
// Z80 #1 — Main audio CPU
// =====================================================================
wire [15:0] z80a_addr;
wire  [7:0] z80a_dout;
reg   [7:0] z80a_din;
wire        z80a_mreq_n, z80a_iorq_n, z80a_rd_n, z80a_wr_n;
wire        z80a_m1_n, z80a_rfsh_n;
wire        z80a_wait_n = 1'b1;  // no wait — BRAM ROM is 1-cycle

// Forward declaration for YM2203 IRQ
wire       ym1_irq_n;

// PC060HA NMI: active low, directly from PC060HA
wire z80a_nmi_n = snd_nmi_n;

// YM2203 #1 IRQ → Z80 #1 INT
wire z80a_int_n = ym1_irq_n;

// Z80 #1 reset: global reset OR PC060HA sub-reset (MAME: only main audio CPU)
wire z80a_reset = reset | snd_reset_in;

T80pa z80_audio (
	.RESET_n (~z80a_reset),
	.CLK     (clk),
	.CEN_p   (ce_4m),
	.CEN_n   (ce_4m_n),
	.WAIT_n  (z80a_wait_n),
	.INT_n   (z80a_int_n),
	.NMI_n   (z80a_nmi_n),
	.BUSRQ_n (1'b1),
	.M1_n    (z80a_m1_n),
	.MREQ_n  (z80a_mreq_n),
	.IORQ_n  (z80a_iorq_n),
	.RD_n    (z80a_rd_n),
	.WR_n    (z80a_wr_n),
	.RFSH_n  (z80a_rfsh_n),
	.HALT_n  (),
	.BUSAK_n (),
	.A       (z80a_addr),
	.DI      (z80a_din),
	.DO      (z80a_dout)
);

// --- Bank switch register ---
reg [1:0] audio_bank;
always @(posedge clk) begin
	if (reset)
		audio_bank <= 2'd0;
	else if (!z80a_mreq_n && !z80a_wr_n && z80a_rfsh_n && z80a_addr == 16'hDC00)
		audio_bank <= z80a_dout[1:0];
end

// --- ADPCM command register (Z80#1 → Z80#2) ---
reg [7:0] adpcm_cmd;
wire      z80b_reads_cmd;  // forward declaration

always @(posedge clk) begin
	if (reset)
		adpcm_cmd <= 8'd0;
	else if (!z80a_mreq_n && !z80a_wr_n && z80a_rfsh_n && z80a_addr == 16'hD400)
		adpcm_cmd <= z80a_dout;
end

// --- Pan registers (stub — just capture, no routing yet) ---
reg [7:0] pan_fm0, pan_fm1, pan_psg0, pan_psg1, pan_da;
always @(posedge clk) begin
	if (reset) begin
		pan_fm0 <= 8'h80; pan_fm1 <= 8'h80;
		pan_psg0 <= 8'h80; pan_psg1 <= 8'h80; pan_da <= 8'h88;  // nibble L=8, R=8 (centered)
	end else if (!z80a_mreq_n && !z80a_wr_n && z80a_rfsh_n) begin
		case (z80a_addr)
			16'hC000: pan_fm0  <= z80a_dout;
			16'hC400: pan_fm1  <= z80a_dout;
			16'hC800: pan_psg0 <= z80a_dout;
			16'hCC00: pan_psg1 <= z80a_dout;
			16'hD000: pan_da   <= z80a_dout;
		endcase
	end
end

// --- Z80 #1 RAM (4KB) ---
reg  [7:0] z80a_ram [0:4095];
reg  [7:0] z80a_ram_q;
wire       z80a_ram_sel = !z80a_mreq_n && (z80a_addr[15:12] == 4'h8);

always @(posedge clk) begin
	if (z80a_ram_sel && !z80a_wr_n)
		z80a_ram[z80a_addr[11:0]] <= z80a_dout;
	z80a_ram_q <= z80a_ram[z80a_addr[11:0]];
end

// --- Z80 #1 ROM read (from BRAM, 1-cycle latency) ---
wire z80a_rom_sel = !z80a_mreq_n && !z80a_rd_n && z80a_rfsh_n && (z80a_addr < 16'h8000);
wire [15:0] z80a_rom_addr_calc = (z80a_addr < 16'h4000) ? z80a_addr : {audio_bank, z80a_addr[13:0]};

reg [7:0] z80a_rom_even_q, z80a_rom_odd_q;
reg       z80a_rom_lsb;
always @(posedge clk) begin
	z80a_rom_even_q <= z80a_rom_even[z80a_rom_addr_calc[15:1]];
	z80a_rom_odd_q  <= z80a_rom_odd[z80a_rom_addr_calc[15:1]];
	z80a_rom_lsb    <= z80a_rom_addr_calc[0];
end
always @(*) z80a_rom_q = z80a_rom_lsb ? z80a_rom_odd_q : z80a_rom_even_q;

// --- Z80 #1 address decode — PC060HA (B000=port, B001=comm) ---
wire z80a_pc060_sel = !z80a_mreq_n && z80a_rfsh_n &&
                      (z80a_addr == 16'hB000 || z80a_addr == 16'hB001);

assign snd_cs    = z80a_pc060_sel;
assign snd_addr  = z80a_addr[0];
assign snd_wr    = z80a_pc060_sel && !z80a_wr_n;
assign snd_rd    = z80a_pc060_sel && !z80a_rd_n;
assign snd_wdata = z80a_dout;

// --- Z80 #1 YM2203 x2 (jt03) ---
wire z80a_ym1_sel = !z80a_mreq_n && z80a_rfsh_n && (z80a_addr[15:1] == 15'h4800);  // 9000-9001
wire z80a_ym2_sel = !z80a_mreq_n && z80a_rfsh_n && (z80a_addr[15:1] == 15'h5000);  // A000-A001

wire [7:0] ym1_dout, ym2_dout;
wire signed [15:0] ym1_snd, ym2_snd;
wire signed [15:0] ym1_fm, ym2_fm;
wire [9:0] ym1_psg_snd, ym2_psg_snd;
wire [7:0] ym1_psg_a, ym1_psg_b, ym1_psg_c;
wire [7:0] ym2_psg_a, ym2_psg_b, ym2_psg_c;
wire [7:0] ym1_ioa_out, ym1_iob_out;
wire [7:0] ym2_ioa_out, ym2_iob_out;
wire       ym1_ioa_oe, ym1_iob_oe;
wire       ym2_ioa_oe, ym2_iob_oe;

jt03 u_ym1 (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_4m),
	.din    (z80a_dout),
	.addr   (z80a_addr[0]),
	.cs_n   (~z80a_ym1_sel),
	.wr_n   (z80a_wr_n),
	.dout   (ym1_dout),
	.irq_n  (ym1_irq_n),
	.IOA_in (ym1_ioa_oe ? ym1_ioa_out : 8'hFF),
	.IOB_in (ym1_iob_oe ? ym1_iob_out : 8'hFF),
	.IOA_out(ym1_ioa_out), .IOB_out(ym1_iob_out),
	.IOA_oe (ym1_ioa_oe), .IOB_oe (ym1_iob_oe),
	.psg_A  (ym1_psg_a), .psg_B  (ym1_psg_b), .psg_C  (ym1_psg_c),
	.fm_snd (ym1_fm),
	.psg_snd(ym1_psg_snd),
	.snd    (ym1_snd),
	.snd_sample(),
	.debug_view()
);

jt03 u_ym2 (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_4m),
	.din    (z80a_dout),
	.addr   (z80a_addr[0]),
	.cs_n   (~z80a_ym2_sel),
	.wr_n   (z80a_wr_n),
	.dout   (ym2_dout),
	.irq_n  (),
	.IOA_in (ym2_ioa_oe ? ym2_ioa_out : 8'hFF),
	.IOB_in (ym2_iob_oe ? ym2_iob_out : 8'hFF),
	.IOA_out(ym2_ioa_out), .IOB_out(ym2_iob_out),
	.IOA_oe (ym2_ioa_oe), .IOB_oe (ym2_iob_oe),
	.psg_A  (ym2_psg_a), .psg_B  (ym2_psg_b), .psg_C  (ym2_psg_c),
	.fm_snd (ym2_fm),
	.psg_snd(ym2_psg_snd),
	.snd    (ym2_snd),
	.snd_sample(),
	.debug_view()
);

// =====================================================================
// Volume registers from YM2203 I/O ports (MAME: write_portA0/B0/A1/B1)
// =====================================================================
// def_vol lookup: 100 / 10^((32 - i*32/15) / 20) for i=0..15
// Precomputed as 7-bit values (0..100)
function automatic [6:0] def_vol_lut;
	input [3:0] idx;
	case (idx)
		4'd0:  def_vol_lut = 7'd0;    // -inf dB
		4'd1:  def_vol_lut = 7'd2;
		4'd2:  def_vol_lut = 7'd3;
		4'd3:  def_vol_lut = 7'd4;
		4'd4:  def_vol_lut = 7'd6;
		4'd5:  def_vol_lut = 7'd8;
		4'd6:  def_vol_lut = 7'd11;
		4'd7:  def_vol_lut = 7'd14;
		4'd8:  def_vol_lut = 7'd19;
		4'd9:  def_vol_lut = 7'd25;
		4'd10: def_vol_lut = 7'd33;
		4'd11: def_vol_lut = 7'd44;
		4'd12: def_vol_lut = 7'd58;
		4'd13: def_vol_lut = 7'd75;
		4'd14: def_vol_lut = 7'd89;
		4'd15: def_vol_lut = 7'd100;
	endcase
endfunction

// Volume directly from YM2203 I/O port outputs (combinatorial, no extra registers)
// MAME: write_portA0 = YM1 IOA, write_portB0 = YM1 IOB, etc.
wire [6:0] vol_fm0   = def_vol_lut(ym1_ioa_out[3:0]);
wire [6:0] vol_psg0a = def_vol_lut(ym1_ioa_out[7:4]);
wire [6:0] vol_psg0b = def_vol_lut(ym1_iob_out[7:4]);
wire [6:0] vol_psg0c = def_vol_lut(ym1_iob_out[3:0]);
wire [6:0] vol_fm1   = def_vol_lut(ym2_ioa_out[3:0]);
wire [6:0] vol_psg1a = def_vol_lut(ym2_ioa_out[7:4]);
wire [6:0] vol_psg1b = def_vol_lut(ym2_iob_out[7:4]);
wire [6:0] vol_psg1c = def_vol_lut(ym2_iob_out[3:0]);

// --- Z80 #1 data bus mux (combinatorial — BRAM already has 1-cycle registered output) ---
always @(*) begin
	if (z80a_rom_sel)
		z80a_din = z80a_rom_q;
	else if (z80a_ram_sel)
		z80a_din = z80a_ram_q;
	else if (z80a_ym1_sel)
		z80a_din = ym1_dout;
	else if (z80a_ym2_sel)
		z80a_din = ym2_dout;
	else if (z80a_pc060_sel)
		z80a_din = snd_rdata;
	else
		z80a_din = 8'hFF;
end

// =====================================================================
// Z80 #2 — ADPCM CPU (ROM only, no RAM)
// =====================================================================
wire [15:0] z80b_addr;
wire  [7:0] z80b_dout;
reg   [7:0] z80b_din;
wire        z80b_mreq_n, z80b_iorq_n, z80b_rd_n, z80b_wr_n;
wire        z80b_m1_n;
wire        z80b_wait_n = 1'b1;

// --- MSM5205 (ADPCM) ---
reg [7:0] msm_ce_cnt;
wire      msm_cen = (msm_ce_cnt == 8'd249);
always @(posedge clk) begin
	if (reset) msm_ce_cnt <= 0;
	else msm_ce_cnt <= msm_cen ? 8'd0 : msm_ce_cnt + 8'd1;
end

// NMI enable gate + data write (MAME: port 0x00=nmi_disable, 0x01=nmi_enable, 0x02=adpcm_data)
reg       msm_nmi_en;
wire      msm_irq;
wire      msm_vclk;
wire signed [11:0] msm_snd;

wire z80b_io_wr = !z80b_iorq_n && !z80b_wr_n;
wire z80b_nmi_dis  = z80b_io_wr && z80b_addr[7:0] == 8'h00;
wire z80b_nmi_en   = z80b_io_wr && z80b_addr[7:0] == 8'h01;
wire z80b_adpcm_wr = z80b_io_wr && z80b_addr[7:0] == 8'h02;

always @(posedge clk) begin
	if (reset)
		msm_nmi_en <= 1'b0;
	else begin
		if (z80b_nmi_dis) msm_nmi_en <= 1'b0;
		if (z80b_nmi_en)  msm_nmi_en <= 1'b1;
	end
end

// MSM5205 data + reset (MAME: m_msm->data_w(data), m_msm->reset_w(!(data & 0x20)))
reg [3:0] msm_din;
reg       msm_reset;
always @(posedge clk) begin
	if (reset) begin
		msm_din   <= 4'd0;
		msm_reset <= 1'b1;
	end else if (z80b_adpcm_wr) begin
		msm_din   <= z80b_dout[3:0];
		msm_reset <= !(z80b_dout[5]);
	end
end

jt5205 u_msm5205 (
	.rst    (msm_reset),
	.clk    (clk),
	.cen    (msm_cen),
	.sel    (2'b10),    // S1=1, S0=0 → divide by 48 → 384K/48 = 8KHz (matches MAME)
	.din    (msm_din),
	.sound  (msm_snd),
	.sample (),
	.irq    (msm_irq),
	.vclk_o (msm_vclk)
);

T80pa z80_adpcm (
	.RESET_n (~reset),
	.CLK     (clk),
	.CEN_p   (ce_4m),
	.CEN_n   (ce_4m_n),
	.WAIT_n  (z80b_wait_n),
	.INT_n   (1'b1),
	.NMI_n   (~(msm_irq & msm_nmi_en)),
	.BUSRQ_n (1'b1),
	.M1_n    (z80b_m1_n),
	.MREQ_n  (z80b_mreq_n),
	.IORQ_n  (z80b_iorq_n),
	.RD_n    (z80b_rd_n),
	.WR_n    (z80b_wr_n),
	.RFSH_n  (z80b_rfsh_n),
	.HALT_n  (),
	.BUSAK_n (),
	.A       (z80b_addr),
	.DI      (z80b_din),
	.DO      (z80b_dout)
);

// --- Z80 #2 ROM read (from BRAM, 1-cycle latency, flat 64KB) ---
wire z80b_rfsh_n;
wire z80b_rom_sel = !z80b_mreq_n && !z80b_rd_n && z80b_rfsh_n;

reg [7:0] z80b_rom_even_q, z80b_rom_odd_q;
reg       z80b_rom_lsb;
always @(posedge clk) begin
	z80b_rom_even_q <= z80b_rom_even[z80b_addr[15:1]];
	z80b_rom_odd_q  <= z80b_rom_odd[z80b_addr[15:1]];
	z80b_rom_lsb    <= z80b_addr[0];
end
always @(*) z80b_rom_q = z80b_rom_lsb ? z80b_rom_odd_q : z80b_rom_even_q;

// --- Z80 #2 I/O port 0x00: read ADPCM command from Z80 #1 ---
assign z80b_reads_cmd = !z80b_iorq_n && !z80b_rd_n && z80b_addr[7:0] == 8'h00;

// --- Z80 #2 I/O read: port 0x00=cmd, 0x02/0x03=0 (MAME), else 0xFF ---
wire z80b_io_rd = !z80b_iorq_n && !z80b_rd_n;
wire z80b_io_rd_02 = z80b_io_rd && (z80b_addr[7:0] == 8'h02 || z80b_addr[7:0] == 8'h03);

// --- Z80 #2 data bus mux (combinatorial) ---
always @(*) begin
	if (z80b_rom_sel)
		z80b_din = z80b_rom_q;
	else if (z80b_reads_cmd)
		z80b_din = adpcm_cmd;
	else if (z80b_io_rd_02)
		z80b_din = 8'h00;
	else
		z80b_din = 8'hFF;
end

// =====================================================================
// =====================================================================
// Audio sample rate generation (192kHz for JTFRAME filters)
// =====================================================================
reg [8:0] sample_cnt;
wire sample_192k = (sample_cnt == 9'd499);  // 96MHz / 500 = 192kHz
always @(posedge clk) begin
	if (reset) sample_cnt <= 9'd0;
	else sample_cnt <= sample_192k ? 9'd0 : sample_cnt + 9'd1;
end

// =====================================================================
// Per-channel analog reconstruction (JTFRAME modules)
// =====================================================================
// DC removal for PSG (unsigned 8-bit → signed 8-bit)
wire signed [7:0] psg1a_dc, psg1b_dc, psg1c_dc;
wire signed [7:0] psg2a_dc, psg2b_dc, psg2c_dc;

jtframe_dcrm #(.SW(8)) u_dc_p1a(.rst(reset),.clk(clk),.sample(sample_192k),.din(ym1_psg_a),.dout(psg1a_dc));
jtframe_dcrm #(.SW(8)) u_dc_p1b(.rst(reset),.clk(clk),.sample(sample_192k),.din(ym1_psg_b),.dout(psg1b_dc));
jtframe_dcrm #(.SW(8)) u_dc_p1c(.rst(reset),.clk(clk),.sample(sample_192k),.din(ym1_psg_c),.dout(psg1c_dc));
jtframe_dcrm #(.SW(8)) u_dc_p2a(.rst(reset),.clk(clk),.sample(sample_192k),.din(ym2_psg_a),.dout(psg2a_dc));
jtframe_dcrm #(.SW(8)) u_dc_p2b(.rst(reset),.clk(clk),.sample(sample_192k),.din(ym2_psg_b),.dout(psg2b_dc));
jtframe_dcrm #(.SW(8)) u_dc_p2c(.rst(reset),.clk(clk),.sample(sample_192k),.din(ym2_psg_c),.dout(psg2c_dc));

// Pole filters currently bypassed: DC-removed PSG and raw FM/MSM are
// fed directly to the mixer. May be revisited in future versions.
wire signed [15:0] ym1_fm_f = ym1_fm;
wire signed [15:0] ym2_fm_f = ym2_fm;
wire signed [7:0] ym1_psg_a_f = psg1a_dc;
wire signed [7:0] ym1_psg_b_f = psg1b_dc;
wire signed [7:0] ym1_psg_c_f = psg1c_dc;
wire signed [7:0] ym2_psg_a_f = psg2a_dc;
wire signed [7:0] ym2_psg_b_f = psg2b_dc;
wire signed [7:0] ym2_psg_c_f = psg2c_dc;
wire signed [11:0] msm_f = msm_snd;

// =====================================================================
// Audio mixer — MAME-ratio-matched, 3-stage pipeline
// =====================================================================
// Coefficients scaled for jt03 integer output ranges (not MAME floats).
// FM:PSG:MSM ratios match MAME route gains (0.60 : 0.08 : 1.00).
// Division by 65536 (>>>16) instead of /10000. No post-gain ×4.
// Pipeline: stage 1 = products, stage 2 = sum, stage 3 = >>>16 + clamp

// --- Stage 0: pv quantization (MAME-exact: (pan * vol) >> 8) — REGISTERED ---
reg [6:0] pv_fm0_l, pv_fm0_r, pv_fm1_l, pv_fm1_r;
reg [6:0] pv_p0a_l, pv_p0a_r, pv_p0b_l, pv_p0b_r, pv_p0c_l, pv_p0c_r;
reg [6:0] pv_p1a_l, pv_p1a_r, pv_p1b_l, pv_p1b_r, pv_p1c_l, pv_p1c_r;
reg [6:0] pv_da_l, pv_da_r;

always @(posedge clk) begin
	pv_fm0_l <= ({7'd0, pan_fm0} * {8'd0, vol_fm0}) >> 8;
	pv_fm0_r <= ({7'd0, 8'd255 - pan_fm0} * {8'd0, vol_fm0}) >> 8;
	pv_fm1_l <= ({7'd0, pan_fm1} * {8'd0, vol_fm1}) >> 8;
	pv_fm1_r <= ({7'd0, 8'd255 - pan_fm1} * {8'd0, vol_fm1}) >> 8;
	pv_p0a_l <= ({7'd0, pan_psg0} * {8'd0, vol_psg0a}) >> 8;
	pv_p0a_r <= ({7'd0, 8'd255 - pan_psg0} * {8'd0, vol_psg0a}) >> 8;
	pv_p0b_l <= ({7'd0, pan_psg0} * {8'd0, vol_psg0b}) >> 8;
	pv_p0b_r <= ({7'd0, 8'd255 - pan_psg0} * {8'd0, vol_psg0b}) >> 8;
	pv_p0c_l <= ({7'd0, pan_psg0} * {8'd0, vol_psg0c}) >> 8;
	pv_p0c_r <= ({7'd0, 8'd255 - pan_psg0} * {8'd0, vol_psg0c}) >> 8;
	pv_p1a_l <= ({7'd0, pan_psg1} * {8'd0, vol_psg1a}) >> 8;
	pv_p1a_r <= ({7'd0, 8'd255 - pan_psg1} * {8'd0, vol_psg1a}) >> 8;
	pv_p1b_l <= ({7'd0, pan_psg1} * {8'd0, vol_psg1b}) >> 8;
	pv_p1b_r <= ({7'd0, 8'd255 - pan_psg1} * {8'd0, vol_psg1b}) >> 8;
	pv_p1c_l <= ({7'd0, pan_psg1} * {8'd0, vol_psg1c}) >> 8;
	pv_p1c_r <= ({7'd0, 8'd255 - pan_psg1} * {8'd0, vol_psg1c}) >> 8;
	pv_da_l  <= def_vol_lut(pan_da[3:0]);
	pv_da_r  <= def_vol_lut(pan_da[7:4]);
end

// --- Stage 0b: coefficients (coeff × pv) — REGISTERED ---
// Ratios FM:PSG:MSM match MAME route gains (0.60 : 0.08 : 1.00).
// FM: 154, PSG: 5284, MSM: 4071. Divide by 65536 (>>>16) at output.
reg [13:0] c_fm0_l, c_fm0_r, c_fm1_l, c_fm1_r;
reg [18:0] c_p0a_l, c_p0a_r, c_p0b_l, c_p0b_r, c_p0c_l, c_p0c_r;
reg [18:0] c_p1a_l, c_p1a_r, c_p1b_l, c_p1b_r, c_p1c_l, c_p1c_r;
reg [19:0] c_msm_l, c_msm_r;

always @(posedge clk) begin
	c_fm0_l <= 8'd154 * {7'd0, pv_fm0_l};
	c_fm0_r <= 8'd154 * {7'd0, pv_fm0_r};
	c_fm1_l <= 8'd154 * {7'd0, pv_fm1_l};
	c_fm1_r <= 8'd154 * {7'd0, pv_fm1_r};
	c_p0a_l <= 13'd5284 * {12'd0, pv_p0a_l};
	c_p0a_r <= 13'd5284 * {12'd0, pv_p0a_r};
	c_p0b_l <= 13'd5284 * {12'd0, pv_p0b_l};
	c_p0b_r <= 13'd5284 * {12'd0, pv_p0b_r};
	c_p0c_l <= 13'd5284 * {12'd0, pv_p0c_l};
	c_p0c_r <= 13'd5284 * {12'd0, pv_p0c_r};
	c_p1a_l <= 13'd5284 * {12'd0, pv_p1a_l};
	c_p1a_r <= 13'd5284 * {12'd0, pv_p1a_r};
	c_p1b_l <= 13'd5284 * {12'd0, pv_p1b_l};
	c_p1b_r <= 13'd5284 * {12'd0, pv_p1b_r};
	c_p1c_l <= 13'd5284 * {12'd0, pv_p1c_l};
	c_p1c_r <= 13'd5284 * {12'd0, pv_p1c_r};
	c_msm_l <= 13'd4071 * {13'd0, pv_da_l};
	c_msm_r <= 13'd4071 * {13'd0, pv_da_r};
end

// --- Stage 1: per-channel products (registered) ---
// FM:  16s × 14u → signed [29:0] (max ±32767×15246 = ±499,594,482)
// PSG:  9s × 19u → signed [27:0] (max 255×261558 = 66,697,290)
// MSM: 12s × 20u → signed [31:0] (max ±2047×407100 = ±833,337,700)
reg signed [29:0] s1_fm0_l, s1_fm0_r, s1_fm1_l, s1_fm1_r;
reg signed [27:0] s1_p0a_l, s1_p0a_r, s1_p0b_l, s1_p0b_r, s1_p0c_l, s1_p0c_r;
reg signed [27:0] s1_p1a_l, s1_p1a_r, s1_p1b_l, s1_p1b_r, s1_p1c_l, s1_p1c_r;
reg signed [31:0] s1_msm_l, s1_msm_r;

always @(posedge clk) begin
	s1_fm0_l <= ym1_fm_f * $signed({1'b0, c_fm0_l});
	s1_fm0_r <= ym1_fm_f * $signed({1'b0, c_fm0_r});
	s1_fm1_l <= ym2_fm_f * $signed({1'b0, c_fm1_l});
	s1_fm1_r <= ym2_fm_f * $signed({1'b0, c_fm1_r});
	s1_p0a_l <= ym1_psg_a_f * $signed({1'b0, c_p0a_l});
	s1_p0a_r <= ym1_psg_a_f * $signed({1'b0, c_p0a_r});
	s1_p0b_l <= ym1_psg_b_f * $signed({1'b0, c_p0b_l});
	s1_p0b_r <= ym1_psg_b_f * $signed({1'b0, c_p0b_r});
	s1_p0c_l <= ym1_psg_c_f * $signed({1'b0, c_p0c_l});
	s1_p0c_r <= ym1_psg_c_f * $signed({1'b0, c_p0c_r});
	s1_p1a_l <= ym2_psg_a_f * $signed({1'b0, c_p1a_l});
	s1_p1a_r <= ym2_psg_a_f * $signed({1'b0, c_p1a_r});
	s1_p1b_l <= ym2_psg_b_f * $signed({1'b0, c_p1b_l});
	s1_p1b_r <= ym2_psg_b_f * $signed({1'b0, c_p1b_r});
	s1_p1c_l <= ym2_psg_c_f * $signed({1'b0, c_p1c_l});
	s1_p1c_r <= ym2_psg_c_f * $signed({1'b0, c_p1c_r});
	s1_msm_l <= msm_f * $signed({1'b0, c_msm_l});
	s1_msm_r <= msm_f * $signed({1'b0, c_msm_r});
end

// --- Stage 2: sum (registered) ---
// Worst-case sum: 2×FM(500M) + 6×PSG(67M) + MSM(833M) = ~2.23G → signed [32:0] (max 4.29G)
wire signed [32:0] sum_l_w =
	{{3{s1_fm0_l[29]}}, s1_fm0_l} + {{3{s1_fm1_l[29]}}, s1_fm1_l} +
	{{5{s1_p0a_l[27]}}, s1_p0a_l} + {{5{s1_p0b_l[27]}}, s1_p0b_l} +
	{{5{s1_p0c_l[27]}}, s1_p0c_l} + {{5{s1_p1a_l[27]}}, s1_p1a_l} +
	{{5{s1_p1b_l[27]}}, s1_p1b_l} + {{5{s1_p1c_l[27]}}, s1_p1c_l} +
	{{1{s1_msm_l[31]}}, s1_msm_l};
wire signed [32:0] sum_r_w =
	{{3{s1_fm0_r[29]}}, s1_fm0_r} + {{3{s1_fm1_r[29]}}, s1_fm1_r} +
	{{5{s1_p0a_r[27]}}, s1_p0a_r} + {{5{s1_p0b_r[27]}}, s1_p0b_r} +
	{{5{s1_p0c_r[27]}}, s1_p0c_r} + {{5{s1_p1a_r[27]}}, s1_p1a_r} +
	{{5{s1_p1b_r[27]}}, s1_p1b_r} + {{5{s1_p1c_r[27]}}, s1_p1c_r} +
	{{1{s1_msm_r[31]}}, s1_msm_r};

reg signed [32:0] s2_sum_l, s2_sum_r;
always @(posedge clk) begin
	s2_sum_l <= sum_l_w;
	s2_sum_r <= sum_r_w;
end

// --- Stage 3: >>>16 + clamp (registered) ---
// No /10000, no ×4. Coefficients already calibrated for 16-bit output.
wire signed [16:0] div_l = s2_sum_l >>> 16;
wire signed [16:0] div_r = s2_sum_r >>> 16;

always @(posedge clk) begin
	audio_l <= (div_l > 17'sd32767)  ? 16'sd32767 :
	           (div_l < -17'sd32768) ? -16'sd32768 : div_l[15:0];
	audio_r <= (div_r > 17'sd32767)  ? 16'sd32767 :
	           (div_r < -17'sd32768) ? -16'sd32768 : div_r[15:0];
end

endmodule
