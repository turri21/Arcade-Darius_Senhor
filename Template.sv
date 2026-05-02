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

    Derived from the MiSTer core template by Sorgelig (MiSTer-devel).

*/

// Template.sv — Darius (Taito, 1986) top-level wrapper (module `emu`).
// Connects the MiSTer framework (`sys/`) to the Darius core
// (`darius_dual68k_top`): HPS I/O, OSD, SDRAM arbitration, audio/video
// output, ROM download, input routing.

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// Pause: toggle on rising edge of joy[12] (standard MiSTer pause bit)
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle | status[17];  // pad OR OSD
assign HDMI_FREEZE = 1'b0;  // overlay pause renderizzato real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// OSD layer offsets: 6-bit signed 2's complement, default 0 on reset
wire signed [9:0] osd_l0_xoff  = {{4{status[43]}}, status[43:38]};
wire signed [9:0] osd_l0_yoff  = {{4{status[49]}}, status[49:44]};
wire signed [9:0] osd_l1_xoff  = {{4{status[55]}}, status[55:50]};
wire signed [9:0] osd_l1_yoff  = {{4{status[61]}}, status[61:56]};
wire signed [9:0] osd_spr_xoff = {{4{status[67]}}, status[67:62]};
wire signed [9:0] osd_spr_yoff = {{4{status[73]}}, status[73:68]};
wire signed [9:0] osd_fg_xoff  = {{4{status[79]}}, status[79:74]};
wire signed [9:0] osd_fg_yoff  = {{4{status[85]}}, status[85:80]};

`include "build_id.v"
localparam CONF_STR = {
	"Darius;;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[6:5],Scale,Narrower HV-Integer,V-Integer,HV-Integer;",
	"-;",
	"O[17],Pause,Off,On;",
	"O[18],Clean Pause,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Fire,Bomb,Start 1P,Start 2P,Coin;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

// --- Joystick to Darius input mapping ---
// MiSTer joy bits: 0=R, 1=L, 2=D, 3=U, 4=Fire(A), 5=Bomb(B), 6=Start1P, 7=Start2P, 8=Coin
// Darius P1 ($C00008): active low, bits: 7=unused,6=unused,5=Fire2,4=Fire1,3=U,2=D,1=L,0=R
// Darius P2 ($C0000A): same layout
// Darius SYSTEM ($C0000E): bit0=coin1, bit1=coin2, bit2=service (active low)
// MAME: bit0=UP, bit1=DOWN, bit2=RIGHT, bit3=LEFT, bit4=FIRE, bit5=BOMB (active low)
// MiSTer: joy[0]=R, joy[1]=L, joy[2]=D, joy[3]=U, joy[4]=btn1, joy[5]=btn2
wire [7:0] p1_input = ~{2'b00, joy0[5], joy0[4], joy0[1], joy0[0], joy0[2], joy0[3]};
wire [7:0] p2_input = ~{2'b00, joy1[5], joy1[4], joy1[1], joy1[0], joy1[2], joy1[3]};


// MAME SYSTEM port ($C0000C) bit layout:
//   bit 7:6 = unused (idle=0, IP_ACTIVE_HIGH)
//   bit 5   = start2 (active LOW, idle=1)
//   bit 4   = start1 (active LOW, idle=1)
//   bit 3   = tilt   (active LOW, idle=1) — not mapped, hardcode idle
//   bit 2   = service(active LOW, idle=1) — not mapped, hardcode idle
//   bit 1   = coin2  (active HIGH, idle=0)
//   bit 0   = coin1  (active HIGH, idle=0)
// MiSTer joy bits: [3:0]=R,L,D,U  [4]=A  [5]=B
//                   [10]=Start  [11]=Coin  [12]=Pause
// MAME SYSTEM port ($C0000C) — verified from _mame_darius.cpp lines 753-758:
//   bit 0: COIN1   (active HIGH) ← joy0[11]
//   bit 1: COIN2   (active HIGH) ← joy1[11]
//   bit 2: START1  (active LOW)  ← ~joy0[10]
//   bit 3: START2  (active LOW)  ← ~joy1[10]
//   bit 4: SERVICE (active LOW)  ← idle=1
//   bit 5: TILT    (active LOW)  ← idle=1
//   bit 7:6: unused (=0)
wire [7:0] system_input = {2'b11, 2'b11, ~joy1[10], ~joy0[10], joy1[11], joy0[11]};

// DIP switches — loaded from MRA via ioctl (index 254)
// Active-LOW: default "FF,FF" = all OFF = all 1s
reg [15:0] dip_sw = 16'hFFFF;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dip_sw <= ioctl_dout;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Game reset: includes download (game held in reset while ROM loads)
wire reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM   ///////////////////////////////

// Genesis 4-port SDRAM controller (Sorgelig + port 3 for audio)
// Port 0: Tile ROM + download
// Port 1: Main CPU ROM
// Port 2: Sub CPU ROM
// Port 3: Audio Z80 ROM

wire [24:1] sd_addr0, sd_addr1, sd_addr2, sd_addr3;
wire [15:0] sd_din0, sd_din1, sd_din2, sd_din3;
wire        sd_wrl0, sd_wrh0, sd_wrl1, sd_wrh1, sd_wrl2, sd_wrh2, sd_wrl3, sd_wrh3;
wire        sd_req0, sd_req1, sd_req2, sd_req3;
wire        sd_ack0, sd_ack1, sd_ack2, sd_ack3;
wire [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3;
wire        sdram_ready;

sdram sdram_ctrl
(
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

	.init(~pll_locked),
	.clk(clk_sys),
	.prio_mode(status[35:34]),
	.ready(sdram_ready),

	.addr0(sd_addr0), .wrl0(sd_wrl0), .wrh0(sd_wrh0),
	.din0(sd_din0), .dout0(sd_dout0), .req0(sd_req0), .ack0(sd_ack0),

	.addr1(sd_addr1), .wrl1(sd_wrl1), .wrh1(sd_wrh1),
	.din1(sd_din1), .dout1(sd_dout1), .req1(sd_req1), .ack1(sd_ack1),

	.addr2(sd_addr2), .wrl2(sd_wrl2), .wrh2(sd_wrh2),
	.din2(sd_din2), .dout2(sd_dout2), .req2(sd_req2), .ack2(sd_ack2),

	.addr3(sd_addr3), .wrl3(sd_wrl3), .wrh3(sd_wrh3),
	.din3(sd_din3), .dout3(sd_dout3), .req3(sd_req3), .ack3(sd_ack3)
);

///////////////////////   BRIDGE   ///////////////////////////////

// Bridge between darius game logic (level protocol) and Genesis SDRAM (toggle protocol)
wire [23:0] game_tile_addr, game_main_addr, game_sub_addr;
wire        game_tile_req, game_main_req, game_sub_req;
wire        game_tile_is_sprite;
wire        game_tile_is_text;
wire [31:0] game_tile_data;
wire        game_tile_valid;
wire [15:0] game_main_data, game_sub_data;
// Audio Z80 ROM removed from SDRAM — will use BRAM when audio implemented
wire        game_main_ready, game_sub_ready;

// ROM instruction cache — between game and SDRAM bridge
wire [23:0] bridge_main_addr, bridge_sub_addr;
wire        bridge_main_req, bridge_sub_req;
wire [15:0] bridge_main_data, bridge_sub_data;
wire        bridge_main_ready, bridge_sub_ready;

rom_cache #(.CACHE_BITS(9)) u_main_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_main_addr), .cpu_req(game_main_req),
	.cpu_data(game_main_data), .cpu_ready(game_main_ready),
	.sdram_addr(bridge_main_addr), .sdram_req(bridge_main_req),
	.sdram_data(bridge_main_data), .sdram_ready(bridge_main_ready)
);

rom_cache #(.CACHE_BITS(9)) u_sub_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_sub_addr), .cpu_req(game_sub_req),
	.cpu_data(game_sub_data), .cpu_ready(game_sub_ready),
	.sdram_addr(bridge_sub_addr), .sdram_req(bridge_sub_req),
	.sdram_data(bridge_sub_data), .sdram_ready(bridge_sub_ready)
);

sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	// Game: Tile ROM (32-bit)
	.tile_byte_addr(game_tile_addr),
	.tile_req(game_tile_req),
	.tile_is_sprite(game_tile_is_sprite),
	.tile_is_text(game_tile_is_text),
	.tile_data(game_tile_data),
	.tile_valid(game_tile_valid),

	// Game: Main CPU ROM (16-bit)
	.main_byte_addr(bridge_main_addr),
	.main_req(bridge_main_req),
	.main_data(bridge_main_data),
	.main_ready(bridge_main_ready),

	// Game: Sub CPU ROM (16-bit)
	.sub_byte_addr(bridge_sub_addr),
	.sub_req(bridge_sub_req),
	.sub_data(bridge_sub_data),
	.sub_ready(bridge_sub_ready),

	// SDRAM ports
	.sdram_addr0(sd_addr0), .sdram_din0(sd_din0),
	.sdram_wrl0(sd_wrl0), .sdram_wrh0(sd_wrh0),
	.sdram_req0(sd_req0), .sdram_ack0(sd_ack0), .sdram_dout0(sd_dout0),

	.sdram_addr1(sd_addr1), .sdram_din1(sd_din1),
	.sdram_wrl1(sd_wrl1), .sdram_wrh1(sd_wrh1),
	.sdram_req1(sd_req1), .sdram_ack1(sd_ack1), .sdram_dout1(sd_dout1),

	.sdram_addr2(sd_addr2), .sdram_din2(sd_din2),
	.sdram_wrl2(sd_wrl2), .sdram_wrh2(sd_wrh2),
	.sdram_req2(sd_req2), .sdram_ack2(sd_ack2), .sdram_dout2(sd_dout2),

	.sdram_addr3(sd_addr3), .sdram_din3(sd_din3),
	.sdram_wrl3(sd_wrl3), .sdram_wrh3(sd_wrh3),
	.sdram_req3(sd_req3), .sdram_ack3(sd_ack3), .sdram_dout3(sd_dout3)
);

///////////////////////   GAME   ///////////////////////////////

wire [9:0]  render_x;
wire [8:0]  render_y;
wire [23:0] tile_rgb;
wire [1:0]  tile_prio;
wire        tile_opaque;
wire [23:0] game_sprite_rgb;
wire [1:0]  game_sprite_prio;
wire        game_sprite_opaque;
wire [23:0] game_fg_rgb;
wire        game_fg_opaque;
wire [15:0] map_xscroll_l0, map_xscroll_l1;
wire [15:0] map_yscroll_l0, map_yscroll_l1;

darius_dual68k_top game
(
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),
	.clk_sel(status[22:20]),      // OSD: Main CPU speed
	.sub_clk_sel(status[25:23]), // OSD: Sub CPU speed
	.z80_clk_sel(status[37:36]), // OSD: Z80 audio speed
	.p1_input(p1_input),
	.p2_input(p2_input),
	.system_input(system_input),
	.dsw_input(dip_sw),

	// SDRAM ROM (via bridge)
	.main_rom_rdata(game_main_data),
	.main_rom_ready(game_main_ready),
	.sub_rom_rdata(game_sub_data),
	.sub_rom_ready(game_sub_ready),
	.tilerom_data(game_tile_data),
	.tilerom_valid(game_tile_valid),

	.main_rom_addr(game_main_addr),
	.main_rom_req(game_main_req),
	.sub_rom_addr(game_sub_addr),
	.sub_rom_req(game_sub_req),
	.tilerom_addr(game_tile_addr),
	.tilerom_req(game_tile_req),
	.tilerom_is_sprite(game_tile_is_sprite),
	.tilerom_is_text(game_tile_is_text),

	// Audio ROM download (ioctl → BRAM)
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	// Video
	.render_x(render_x),
	.render_y(render_y),
	.tile_rgb(tile_rgb),
	.tile_prio(tile_prio),
	.tile_opaque(tile_opaque),
	.sprite_rgb(game_sprite_rgb),
	.sprite_prio(game_sprite_prio),
	.sprite_opaque(game_sprite_opaque),
	.fg_rgb(game_fg_rgb),
	.fg_opaque(game_fg_opaque),

	// Scroll/debug
	.xscroll_l0(map_xscroll_l0),
	.xscroll_l1(map_xscroll_l1),
	.yscroll_l0(map_yscroll_l0),
	.yscroll_l1(map_yscroll_l1),
	.ctrl_l0(),
	.ctrl_l1(),
	// OSD layer offsets
	.l0_xoff(osd_l0_xoff), .l0_yoff(osd_l0_yoff),
	.l1_xoff(osd_l1_xoff), .l1_yoff(osd_l1_yoff),
	.spr_xoff(osd_spr_xoff), .spr_yoff(osd_spr_yoff),
	.fg_xoff(osd_fg_xoff), .fg_yoff(osd_fg_yoff),
	// Text ROM download → FG BRAM
	.fg_dl_wr(ioctl_download && ioctl_wr && ioctl_index == 16'd0 &&
	           ioctl_addr >= 27'h1C0000 && ioctl_addr < 27'h1C8000),
	.fg_dl_addr(ioctl_addr[14:1]),
	.fg_dl_data(ioctl_dout),
	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r)
);

///////////////////////   VIDEO   ///////////////////////////////

// Triple screen video timing via dedicated module (864x224 Darius layout)
wire ce_pix;
wire HBlank, VBlank, HSync, VSync;
wire [7:0] video_r, video_g, video_b;

triple_screen_test u_video (
	.clk(clk_sys),
	.reset(video_reset),
	.layer_en({~status[33], ~status[32], ~status[31], ~status[30]}),  // {FG, SPR, L1, L0}
	.tile_rgb(tile_rgb),
	.tile_prio(tile_prio),
	.tile_opaque(tile_opaque),
	.sprite_pix_rgb(game_sprite_rgb),
	.sprite_prio(game_sprite_prio),
	.sprite_opaque(game_sprite_opaque),
	.fg_rgb(game_fg_rgb),
	.fg_opaque(game_fg_opaque),
	.ce_pix(ce_pix),
	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),
	.render_x(render_x),
	.render_y(render_y),
	.R(video_r),
	.G(video_g),
	.B(video_b)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_HS    = HSync;
assign VGA_VS    = VSync;

// Pause overlay: dim video + logo 48x48 al centro durante pausa.
// OSD "Clean Pause" (status[18]): ON=video raw senza addon, OFF=overlay attivo.
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (pause),
	.clean     (status[18]),
	.render_x  (render_x),
	.render_y  (render_y),
	.rgb_r_in  (video_r),
	.rgb_g_in  (video_g),
	.rgb_b_in  (video_b),
	.rgb_r_out (VGA_R),
	.rgb_g_out (VGA_G),
	.rgb_b_out (VGA_B)
);

// Aspect ratio: Original = 4:1 (3x 4:3 monitors), Full Screen = 0:0
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd1 : 12'd0;

// Integer scaling (Scale menu: Normal / V-Integer / Narrower HV-Integer)
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE((status[6:5] == 2'd0) ? 3'd2 :   // Narrower HV-Integer (default, = HV-Integer-)
	        (status[6:5] == 2'd1) ? 3'd1 :   // V-Integer
	                                3'd4)    // HV-Integer
);

// LED: blink during download
assign LED_USER = ioctl_download;

// ============================================================
// JTAG Debug Probes (readable via quartus_stp / System Console)
// ============================================================
// JTAG boot trace removed to save M10K for 64KB work RAM

endmodule
