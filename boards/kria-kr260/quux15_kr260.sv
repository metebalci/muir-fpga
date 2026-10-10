// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15 ON THE AMD KRIA KR260** (contract G3 revision 15,
// §12.3): `rtl/machine/quux15_core.sv`, the pipelined machine, on this
// board's processing system, at the period its fit closes.  Revisions 13 and
// 14 and the CADR stay `cadr_kr260.sv`'s; this machine has another face to
// the board, so it has its own top level, with that file's facts of the
// board and the part kept as they are:
//
//   - **THE CLOCK IS THE CARRIER'S 25 MHz, ON C3, THROUGH AN `MMCME4_BASE`**,
//     25 x 40 = 1000 MHz at the VCO, divided by `CLKOUT0_DIVIDE_F`: the
//     period in nanoseconds, `PERIOD_NS`, which the machine is told in its
//     units of 0.5 ns (`period`, A15b.12) and the console face reports.
//   - **THE PROCESSING SYSTEM IS `cadr_ps8.sv`'s `PS8`**, every port clocked
//     by the machine's clock and live while `pl_resetn0` is high.
//   - **MAIN MEMORY IS ON `S_AXI_HP0_FPD`**, packed storage at
//     `CADR_DDR_MAP_KR260`'s revision-13 base (`QUUX13_MAIN_BASE`), where
//     revisions 13 and 14 keep theirs and the board's revision-13 device
//     tree reserves it, the frame buffer at the display base: the machine's
//     own 64-bit master
//     (`quux15_axi_master.sv`, inside the core's port) behind
//     `quux_axi_narrow128.sv` on the 128-bit port.  Its writes carry one
//     AXI ID (A15b.5), so the port's one ID answers them in order.
//   - **THE CONSOLE FACE IS ON `M_AXI_HPM1_FPD` AT 0xB000_0000**
//     (`rtl/plumbing/quux15_face.sv`), the console's words: the machine's
//     counts, its reset, the diagnostic registers, the readout of the
//     halted machine a checkpoint takes, the build stamp, main memory's
//     size, the video controller's, the period and the real-time clock's
//     start.  The machine comes out of reset running from its PROM, as
//     revisions 13 and 14 do on this board.  Every
//     other address on both master ports is answered with a constant
//     (`cadr_gp0_default.sv`), since a read nothing answers hangs both Arm
//     cores.
//   - **NOT ON THIS BOARD YET**: the file device's page, the display output,
//     the disk packs and the I/O cables, which the programs that serve them
//     bring; the debug cable, which QUUX never has (contract Q5), PMOD1's
//     pads left undriven.
//   - **TWO LAMPS**: UF1 a count of committed microcycles, so it flickers
//     while the machine runs and freezes when it stops; UF2 lit at an error
//     halt.  **THE FAN IS DRIVEN ON**, `fan_en_b` low, as every KR260
//     bitstream holds it.

`default_nettype none

module quux15_kr260 #(
    parameter string PROM_HEX = "build/quux15_transfer_prom.hex",
    // **THE PERIOD**, in nanoseconds: the MMCM's divide below, the one place
    // it is decided on this board.
    parameter int unsigned PERIOD_NS = 13
) (
    input  var logic       clk25,      // the carrier's 25 MHz, pin C3
    output var logic       uf1,
    output var logic       uf2,
    output var logic       fan_en_b,
    inout  wire  [7:0]     pmod1
);

  localparam logic [31:0] MAIN_BASE    = 32'h5A00_0000;
  localparam logic [31:0] DISPLAY_BASE = 32'h6400_0000;
  if (cadr_ddr_map::QUUX13_MAIN_BASE != MAIN_BASE || cadr_ddr_map::DISPLAY_BASE != DISPLAY_BASE) begin : g_map
    $error("cadr_ddr_map's bases are %h and %h, and the Kria KR260's are %h and %h: define CADR_DDR_MAP_KR260",
           cadr_ddr_map::QUUX13_MAIN_BASE, cadr_ddr_map::DISPLAY_BASE, MAIN_BASE, DISPLAY_BASE);
  end
  // Main memory: the core's 2M words, 32 units of 64K.
  localparam int unsigned MAIN_WORDS = 32'h0020_0000;

  // ------------------------------------------------------------ the clock
  logic clk_fb, clk_raw, clk, mmcm_locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME4_BASE #(
      .CLKIN1_PERIOD  (40.000),          // 25 MHz
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(40.000),          // 1000 MHz at the VCO
      .CLKOUT0_DIVIDE_F(real'(PERIOD_NS)) // the period, in nanoseconds
  ) u_mmcm (
      .CLKIN1  (clk25),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_raw),
      .LOCKED  (mmcm_locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .CLKFBOUTB()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  BUFG u_bufg (.I(clk_raw), .O(clk));

  // ------------------------------------------------------------- the reset
  //
  // The MMCM's lock, synchronized; the ports' `pl_resetn0` (EMIO GPIO 95),
  // synchronized; and the console face's reset, RESET's key's pulse.  The
  // machine is held while any is.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked};
  assign rst = rst_sync[3];

  logic [95:0] gpio_o;
  logic [2:0]  port_rst_sync;
  always_ff @(posedge clk) port_rst_sync <= {port_rst_sync[1:0], gpio_o[95]};
  logic axi_rst;
  assign axi_rst = !port_rst_sync[2];

  logic face_rst, mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || axi_rst || face_rst;

  // ---------------------------------------------------------- the machine
  logic [15:0] obs_cs, obs_rd, obs_ex, obs_wb, obs_commit;
  logic [13:0] obs_pdlptr, obs_pdlidx;
  logic [4:0]  obs_spcptr;
  logic [39:0] obs_q, obs_vma, obs_md, obs_ea, obs_em, obs_ob, obs_mdword;
  logic [40:0] obs_lc;
  logic [31:0] obs_ic, obs_gaddr, obs_raddr;
  logic        obs_opnd, obs_mdl, obs_reg, obs_halted;
  logic [25:0] obs_oalow;
  logic [21:0] obs_oahigh;
  logic [1:0]  obs_grant, obs_errhalt;
  logic [3:0]  obs_queue;
  logic [4:0]  obs_inflight;
  logic        fd_doorbell, fd_enabled, axi_one_write_id;
  logic [15:0] fd_prod;
  logic [3:0]  axi_read_clocks, axi_write_clocks;
  logic        spy_we;
  logic [3:0]  spy_eadr, spy_raddr;
  logic [15:0] spy_wdata, spy_rdata;
  logic [63:0] ro_word, rm_word, obs_committed;
  logic [47:0] obs_clocks;
  logic        rm_en, rm_snap;
  logic [3:0]  rm_sel;
  logic [13:0] rm_addr;
  logic [31:0] rtc_start;

  // The machine's 64-bit AXI master.
  logic [3:0]  qm_awid;
  logic [31:0] qm_awaddr, qm_araddr;
  logic [7:0]  qm_awlen, qm_arlen;
  logic [2:0]  qm_awsize, qm_arsize;
  logic [1:0]  qm_awburst, qm_arburst;
  logic        qm_awvalid, qm_awready, qm_wlast, qm_wvalid, qm_wready;
  logic        qm_bvalid, qm_bready, qm_arvalid, qm_arready, qm_rlast, qm_rvalid, qm_rready;
  logic [63:0] qm_wdata, qm_rdata;
  logic [7:0]  qm_wstrb;
  logic [1:0]  qm_bresp, qm_rresp;

  quux15_core #(
      .PROM_HEX(PROM_HEX),
      .MAIN_WORDS(MAIN_WORDS),
      .MAIN_BASE(MAIN_BASE),
      .DISPLAY_BASE(DISPLAY_BASE)
  ) u_core (
      .clk(clk), .rst(mach_rst),
      .obs_cs(obs_cs), .obs_rd(obs_rd), .obs_ex(obs_ex), .obs_wb(obs_wb), .obs_commit(obs_commit),
      .obs_pdlptr(obs_pdlptr), .obs_pdlidx(obs_pdlidx), .obs_spcptr(obs_spcptr),
      .obs_q(obs_q), .obs_vma(obs_vma), .obs_md(obs_md), .obs_lc(obs_lc), .obs_ic(obs_ic),
      .obs_opnd(obs_opnd), .obs_ea(obs_ea), .obs_em(obs_em), .obs_ob(obs_ob),
      .obs_oalow(obs_oalow), .obs_oahigh(obs_oahigh), .obs_grant(obs_grant), .obs_gaddr(obs_gaddr),
      .obs_mdl(obs_mdl), .obs_mdword(obs_mdword), .obs_reg(obs_reg), .obs_raddr(obs_raddr),
      .obs_queue(obs_queue), .obs_inflight(obs_inflight), .obs_halted(obs_halted),
      .obs_errhalt(obs_errhalt),
      .m_awid(qm_awid), .m_awaddr(qm_awaddr), .m_awlen(qm_awlen), .m_awsize(qm_awsize),
      .m_awburst(qm_awburst), .m_awvalid(qm_awvalid), .m_awready(qm_awready),
      .m_wdata(qm_wdata), .m_wstrb(qm_wstrb), .m_wlast(qm_wlast), .m_wvalid(qm_wvalid),
      .m_wready(qm_wready), .m_bid(4'd0), .m_bresp(qm_bresp), .m_bvalid(qm_bvalid),
      .m_bready(qm_bready),
      .m_araddr(qm_araddr), .m_arlen(qm_arlen), .m_arsize(qm_arsize), .m_arburst(qm_arburst),
      .m_arvalid(qm_arvalid), .m_arready(qm_arready), .m_rdata(qm_rdata), .m_rresp(qm_rresp),
      .m_rlast(qm_rlast), .m_rvalid(qm_rvalid), .m_rready(qm_rready),
      .period(7'(2 * PERIOD_NS)), .rtc_start(rtc_start),
      .fd_doorbell(fd_doorbell), .fd_prod(fd_prod), .fd_enabled(fd_enabled),
      .fd_done(1'b0), .fd_handles(8'd0),
      .axi_one_write_id(axi_one_write_id), .axi_read_clocks(axi_read_clocks),
      .axi_write_clocks(axi_write_clocks),
      .spy_we(spy_we), .spy_eadr(spy_eadr), .spy_wdata(spy_wdata),
      .spy_raddr(spy_raddr), .spy_rdata(spy_rdata),
      .ro_sel(5'd0), .ro_word(ro_word),
      .rm_en(rm_en), .rm_snap(rm_snap), .rm_sel(rm_sel), .rm_addr(rm_addr), .rm_word(rm_word),
      .obs_committed(obs_committed), .obs_clocks(obs_clocks)
  );

  // ------------------------------------------------------- main memory, HP0
  logic [31:0]  hp0_awaddr, hp0_araddr;
  logic [7:0]   hp0_awlen, hp0_arlen;
  logic [2:0]   hp0_awsize, hp0_arsize;
  logic [127:0] hp0_wdata, hp0_rdata;
  logic [15:0]  hp0_wstrb;
  logic         hp0_awvalid, hp0_awready, hp0_wlast, hp0_wvalid, hp0_wready;
  logic         hp0_arvalid, hp0_arready, hp0_rlast, hp0_rvalid;

  // The machine's bursts are at most five beats of eight bytes: AXI3's
  // four bits of length and two of size hold them.
  quux_axi_narrow128 u_narrow (
      .clk(clk), .rst(axi_rst),
      .s_awaddr(qm_awaddr), .s_awlen(qm_awlen[3:0]), .s_awsize(qm_awsize[1:0]),
      .s_awvalid(qm_awvalid), .s_awready(qm_awready),
      .s_wdata(qm_wdata), .s_wstrb(qm_wstrb), .s_wlast(qm_wlast),
      .s_wvalid(qm_wvalid), .s_wready(qm_wready),
      .s_araddr(qm_araddr), .s_arlen(qm_arlen[3:0]), .s_arsize(qm_arsize[1:0]),
      .s_arvalid(qm_arvalid), .s_arready(qm_arready),
      .s_rdata(qm_rdata), .s_rready(qm_rready),
      .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize),
      .m_awvalid(hp0_awvalid), .m_awready(hp0_awready),
      .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb), .m_wlast(hp0_wlast),
      .m_wvalid(hp0_wvalid), .m_wready(hp0_wready),
      .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize),
      .m_arvalid(hp0_arvalid), .m_arready(hp0_arready),
      .m_rdata(hp0_rdata), .m_rlast(hp0_rlast), .m_rvalid(hp0_rvalid)
  );
  assign qm_rlast  = hp0_rlast;
  assign qm_rvalid = hp0_rvalid;

  // ------------------------------------- the master ports: HPM0 and HPM1
  logic [39:0]  hpm0_awaddr, hpm0_araddr, hpm1_awaddr, hpm1_araddr;
  logic [7:0]   hpm0_awlen, hpm0_arlen, hpm1_awlen, hpm1_arlen;
  logic [15:0]  hpm0_awid, hpm0_arid, hpm0_bid, hpm0_rid;
  logic [15:0]  hpm1_awid, hpm1_arid, hpm1_bid, hpm1_rid;
  logic [127:0] hpm0_wdata, hpm0_rdata, hpm1_wdata, hpm1_rdata;
  logic [15:0]  hpm0_wstrb, hpm1_wstrb;
  logic [1:0]   hpm0_bresp, hpm0_rresp, hpm1_bresp, hpm1_rresp;
  logic         hpm0_awvalid, hpm0_awready, hpm0_wlast, hpm0_wvalid, hpm0_wready;
  logic         hpm0_bvalid, hpm0_bready, hpm0_arvalid, hpm0_arready;
  logic         hpm0_rlast, hpm0_rvalid, hpm0_rready;
  logic         hpm1_awvalid, hpm1_awready, hpm1_wlast, hpm1_wvalid, hpm1_wready;
  logic         hpm1_bvalid, hpm1_bready, hpm1_arvalid, hpm1_arready;
  logic         hpm1_rlast, hpm1_rvalid, hpm1_rready;

  // HPM0: nothing of this machine's yet, every address answered.
  logic [31:0] gp0_rdata, gp0_wdata;
  logic [3:0]  gp0_wstrb;
  cadr_axi_lanes128 u_hpm0_lanes (
      .s_wdata(hpm0_wdata), .s_wstrb(hpm0_wstrb), .s_rdata(hpm0_rdata),
      .m_wdata(gp0_wdata), .m_wstrb(gp0_wstrb), .m_rdata(gp0_rdata)
  );
  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp0_rest (
      .clk(clk), .rst(axi_rst),
      .s_awvalid(hpm0_awvalid), .s_awid(hpm0_awid), .s_awready(hpm0_awready),
      .s_wlast(hpm0_wlast), .s_wvalid(hpm0_wvalid), .s_wready(hpm0_wready),
      .s_bresp(hpm0_bresp), .s_bid(hpm0_bid), .s_bvalid(hpm0_bvalid), .s_bready(hpm0_bready),
      .s_arlen(hpm0_arlen), .s_arid(hpm0_arid), .s_arvalid(hpm0_arvalid),
      .s_arready(hpm0_arready), .s_rdata(gp0_rdata), .s_rresp(hpm0_rresp),
      .s_rid(hpm0_rid), .s_rlast(hpm0_rlast), .s_rvalid(hpm0_rvalid), .s_rready(hpm0_rready)
  );

  // HPM1: the console face's page at 0xB000_0000; the next page and every
  // other address answered.
  logic [31:0] gp1_wdata, gp1_rdata;
  logic [3:0]  gp1_wstrb;
  cadr_axi_lanes128 u_hpm1_lanes (
      .s_wdata(hpm1_wdata), .s_wstrb(hpm1_wstrb), .s_rdata(hpm1_rdata),
      .m_wdata(gp1_wdata), .m_wstrb(gp1_wstrb), .m_rdata(gp1_rdata)
  );

  logic [31:0] gp1c_awaddr, gp1c_araddr, gp1c_wdata, gp1c_rdata;
  logic [7:0]  gp1c_awlen, gp1c_arlen;
  logic [3:0]  gp1c_wstrb;
  logic [15:0] gp1c_awid, gp1c_arid, gp1c_bid, gp1c_rid;
  logic        gp1c_awvalid, gp1c_awready, gp1c_wlast, gp1c_wvalid, gp1c_wready;
  logic        gp1c_bvalid, gp1c_bready, gp1c_arvalid, gp1c_arready;
  logic        gp1c_rlast, gp1c_rvalid, gp1c_rready;
  logic [1:0]  gp1c_bresp, gp1c_rresp;
  logic [31:0] gp1d_awaddr, gp1d_araddr, gp1d_wdata, gp1d_rdata;
  logic [7:0]  gp1d_awlen, gp1d_arlen;
  logic [3:0]  gp1d_wstrb;
  logic [15:0] gp1d_awid, gp1d_arid, gp1d_bid, gp1d_rid;
  logic        gp1d_awvalid, gp1d_awready, gp1d_wlast, gp1d_wvalid, gp1d_wready;
  logic        gp1d_bvalid, gp1d_bready, gp1d_arvalid, gp1d_arready;
  logic        gp1d_rlast, gp1d_rvalid, gp1d_rready;
  logic [1:0]  gp1d_bresp, gp1d_rresp;
  logic [31:0] gp1x_rdata;
  logic [7:0]  gp1x_arlen;
  logic [15:0] gp1x_awid, gp1x_arid, gp1x_bid, gp1x_rid;
  logic        gp1x_awvalid, gp1x_awready, gp1x_wlast, gp1x_wvalid, gp1x_wready;
  logic        gp1x_bvalid, gp1x_bready, gp1x_arvalid, gp1x_arready;
  logic        gp1x_rlast, gp1x_rvalid, gp1x_rready;
  logic [1:0]  gp1x_bresp, gp1x_rresp;

  cadr_gp1_split #(
      .CON_BASE(32'hB000_0000), .DBG_BASE(32'hB000_1000),
      .ID_W(16), .LEN_W(8)
  ) u_gp1_split (
      .clk(clk), .rst(axi_rst),
      .s_awaddr(hpm1_awaddr[31:0]), .s_awlen(hpm1_awlen), .s_awid(hpm1_awid),
      .s_awvalid(hpm1_awvalid), .s_awready(hpm1_awready),
      .s_wdata(gp1_wdata), .s_wstrb(gp1_wstrb), .s_wlast(hpm1_wlast),
      .s_wvalid(hpm1_wvalid), .s_wready(hpm1_wready),
      .s_bresp(hpm1_bresp), .s_bid(hpm1_bid), .s_bvalid(hpm1_bvalid), .s_bready(hpm1_bready),
      .s_araddr(hpm1_araddr[31:0]), .s_arlen(hpm1_arlen), .s_arid(hpm1_arid),
      .s_arvalid(hpm1_arvalid), .s_arready(hpm1_arready),
      .s_rdata(gp1_rdata), .s_rresp(hpm1_rresp), .s_rid(hpm1_rid),
      .s_rlast(hpm1_rlast), .s_rvalid(hpm1_rvalid), .s_rready(hpm1_rready),
      .con_awaddr(gp1c_awaddr), .con_awlen(gp1c_awlen), .con_awid(gp1c_awid),
      .con_awvalid(gp1c_awvalid), .con_awready(gp1c_awready),
      .con_wdata(gp1c_wdata), .con_wstrb(gp1c_wstrb), .con_wlast(gp1c_wlast),
      .con_wvalid(gp1c_wvalid), .con_wready(gp1c_wready),
      .con_bresp(gp1c_bresp), .con_bid(gp1c_bid), .con_bvalid(gp1c_bvalid),
      .con_bready(gp1c_bready),
      .con_araddr(gp1c_araddr), .con_arlen(gp1c_arlen), .con_arid(gp1c_arid),
      .con_arvalid(gp1c_arvalid), .con_arready(gp1c_arready),
      .con_rdata(gp1c_rdata), .con_rresp(gp1c_rresp), .con_rid(gp1c_rid),
      .con_rlast(gp1c_rlast), .con_rvalid(gp1c_rvalid), .con_rready(gp1c_rready),
      .dbg_awaddr(gp1d_awaddr), .dbg_awlen(gp1d_awlen), .dbg_awid(gp1d_awid),
      .dbg_awvalid(gp1d_awvalid), .dbg_awready(gp1d_awready),
      .dbg_wdata(gp1d_wdata), .dbg_wstrb(gp1d_wstrb), .dbg_wlast(gp1d_wlast),
      .dbg_wvalid(gp1d_wvalid), .dbg_wready(gp1d_wready),
      .dbg_bresp(gp1d_bresp), .dbg_bid(gp1d_bid), .dbg_bvalid(gp1d_bvalid),
      .dbg_bready(gp1d_bready),
      .dbg_araddr(gp1d_araddr), .dbg_arlen(gp1d_arlen), .dbg_arid(gp1d_arid),
      .dbg_arvalid(gp1d_arvalid), .dbg_arready(gp1d_arready),
      .dbg_rdata(gp1d_rdata), .dbg_rresp(gp1d_rresp), .dbg_rid(gp1d_rid),
      .dbg_rlast(gp1d_rlast), .dbg_rvalid(gp1d_rvalid), .dbg_rready(gp1d_rready),
      .dflt_awid(gp1x_awid), .dflt_awvalid(gp1x_awvalid), .dflt_awready(gp1x_awready),
      .dflt_wlast(gp1x_wlast), .dflt_wvalid(gp1x_wvalid), .dflt_wready(gp1x_wready),
      .dflt_bresp(gp1x_bresp), .dflt_bid(gp1x_bid), .dflt_bvalid(gp1x_bvalid),
      .dflt_bready(gp1x_bready),
      .dflt_arlen(gp1x_arlen), .dflt_arid(gp1x_arid),
      .dflt_arvalid(gp1x_arvalid), .dflt_arready(gp1x_arready),
      .dflt_rdata(gp1x_rdata), .dflt_rresp(gp1x_rresp), .dflt_rid(gp1x_rid),
      .dflt_rlast(gp1x_rlast), .dflt_rvalid(gp1x_rvalid), .dflt_rready(gp1x_rready)
  );

  logic [31:0] build;
  cadr_usr_access u_usr_access (.build(build));

  quux15_face #(
      .ID_W(16), .LEN_W(8), .PERIOD(32'(2 * PERIOD_NS)), .MAIN_UNITS(MAIN_WORDS >> 16)
  ) u_face (
      .clk(clk), .rst(axi_rst),
      .s_awaddr(gp1c_awaddr[11:0]), .s_awlen(gp1c_awlen), .s_awid(gp1c_awid),
      .s_awvalid(gp1c_awvalid), .s_awready(gp1c_awready),
      .s_wdata(gp1c_wdata), .s_wstrb(gp1c_wstrb), .s_wlast(gp1c_wlast),
      .s_wvalid(gp1c_wvalid), .s_wready(gp1c_wready),
      .s_bresp(gp1c_bresp), .s_bid(gp1c_bid), .s_bvalid(gp1c_bvalid), .s_bready(gp1c_bready),
      .s_araddr(gp1c_araddr[11:0]), .s_arlen(gp1c_arlen), .s_arid(gp1c_arid),
      .s_arvalid(gp1c_arvalid), .s_arready(gp1c_arready),
      .s_rdata(gp1c_rdata), .s_rresp(gp1c_rresp), .s_rid(gp1c_rid),
      .s_rlast(gp1c_rlast), .s_rvalid(gp1c_rvalid), .s_rready(gp1c_rready),
      .build(build),
      .mach_rst(face_rst), .rtc_start(rtc_start),
      .committed(obs_committed), .clocks(obs_clocks),
      .vma(obs_vma), .q(obs_q), .md(obs_md),
      .spy_we(spy_we), .spy_eadr(spy_eadr), .spy_wdata(spy_wdata),
      .spy_raddr(spy_raddr), .spy_rdata(spy_rdata),
      .rm_en(rm_en), .rm_snap(rm_snap), .rm_sel(rm_sel), .rm_addr(rm_addr), .rm_word(rm_word)
  );

  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp1_dbg_rest (
      .clk(clk), .rst(axi_rst),
      .s_awvalid(gp1d_awvalid), .s_awid(gp1d_awid), .s_awready(gp1d_awready),
      .s_wlast(gp1d_wlast), .s_wvalid(gp1d_wvalid), .s_wready(gp1d_wready),
      .s_bresp(gp1d_bresp), .s_bid(gp1d_bid), .s_bvalid(gp1d_bvalid), .s_bready(gp1d_bready),
      .s_arlen(gp1d_arlen), .s_arid(gp1d_arid), .s_arvalid(gp1d_arvalid),
      .s_arready(gp1d_arready), .s_rdata(gp1d_rdata), .s_rresp(gp1d_rresp),
      .s_rid(gp1d_rid), .s_rlast(gp1d_rlast), .s_rvalid(gp1d_rvalid), .s_rready(gp1d_rready)
  );
  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp1_rest (
      .clk(clk), .rst(axi_rst),
      .s_awvalid(gp1x_awvalid), .s_awid(gp1x_awid), .s_awready(gp1x_awready),
      .s_wlast(gp1x_wlast), .s_wvalid(gp1x_wvalid), .s_wready(gp1x_wready),
      .s_bresp(gp1x_bresp), .s_bid(gp1x_bid), .s_bvalid(gp1x_bvalid), .s_bready(gp1x_bready),
      .s_arlen(gp1x_arlen), .s_arid(gp1x_arid), .s_arvalid(gp1x_arvalid),
      .s_arready(gp1x_arready), .s_rdata(gp1x_rdata), .s_rresp(gp1x_rresp),
      .s_rid(gp1x_rid), .s_rlast(gp1x_rlast), .s_rvalid(gp1x_rvalid), .s_rready(gp1x_rready)
  );

  // ------------------------------------------- the processing system
  logic         hp2_awready, hp2_wready, hp2_bvalid, hp2_arready, hp2_rlast, hp2_rvalid;
  logic [1:0]   hp2_bresp, hp2_rresp;
  logic [127:0] hp2_rdata, hp3_rdata;
  logic         hp3_awready, hp3_wready, hp3_bvalid, hp3_arready, hp3_rlast, hp3_rvalid;
  logic [1:0]   hp3_bresp, hp3_rresp;

  cadr_ps8 u_ps8 (
      .hpm0_aclk(clk),
      .hpm0_awaddr(hpm0_awaddr), .hpm0_awlen(hpm0_awlen), .hpm0_awid(hpm0_awid),
      .hpm0_awvalid(hpm0_awvalid), .hpm0_awready(hpm0_awready),
      .hpm0_wdata(hpm0_wdata), .hpm0_wstrb(hpm0_wstrb), .hpm0_wlast(hpm0_wlast),
      .hpm0_wvalid(hpm0_wvalid), .hpm0_wready(hpm0_wready),
      .hpm0_bresp(hpm0_bresp), .hpm0_bid(hpm0_bid), .hpm0_bvalid(hpm0_bvalid),
      .hpm0_bready(hpm0_bready),
      .hpm0_araddr(hpm0_araddr), .hpm0_arlen(hpm0_arlen), .hpm0_arid(hpm0_arid),
      .hpm0_arvalid(hpm0_arvalid), .hpm0_arready(hpm0_arready),
      .hpm0_rdata(hpm0_rdata), .hpm0_rresp(hpm0_rresp), .hpm0_rid(hpm0_rid),
      .hpm0_rlast(hpm0_rlast), .hpm0_rvalid(hpm0_rvalid), .hpm0_rready(hpm0_rready),
      .hpm1_aclk(clk),
      .hpm1_awaddr(hpm1_awaddr), .hpm1_awlen(hpm1_awlen), .hpm1_awid(hpm1_awid),
      .hpm1_awvalid(hpm1_awvalid), .hpm1_awready(hpm1_awready),
      .hpm1_wdata(hpm1_wdata), .hpm1_wstrb(hpm1_wstrb), .hpm1_wlast(hpm1_wlast),
      .hpm1_wvalid(hpm1_wvalid), .hpm1_wready(hpm1_wready),
      .hpm1_bresp(hpm1_bresp), .hpm1_bid(hpm1_bid), .hpm1_bvalid(hpm1_bvalid),
      .hpm1_bready(hpm1_bready),
      .hpm1_araddr(hpm1_araddr), .hpm1_arlen(hpm1_arlen), .hpm1_arid(hpm1_arid),
      .hpm1_arvalid(hpm1_arvalid), .hpm1_arready(hpm1_arready),
      .hpm1_rdata(hpm1_rdata), .hpm1_rresp(hpm1_rresp), .hpm1_rid(hpm1_rid),
      .hpm1_rlast(hpm1_rlast), .hpm1_rvalid(hpm1_rvalid), .hpm1_rready(hpm1_rready),
      // Main memory: the port's 49 address bits, of which the region needs
      // 31.
      .hp0_rclk(clk), .hp0_wclk(clk),
      .hp0_awaddr({17'd0, hp0_awaddr}), .hp0_awlen(hp0_awlen),
      .hp0_awsize(hp0_awsize), .hp0_awburst(qm_awburst),
      .hp0_awvalid(hp0_awvalid), .hp0_awready(hp0_awready),
      .hp0_wdata(hp0_wdata), .hp0_wstrb(hp0_wstrb),
      .hp0_wlast(hp0_wlast), .hp0_wvalid(hp0_wvalid), .hp0_wready(hp0_wready),
      .hp0_bresp(qm_bresp), .hp0_bvalid(qm_bvalid), .hp0_bready(qm_bready),
      .hp0_araddr({17'd0, hp0_araddr}), .hp0_arlen(hp0_arlen),
      .hp0_arsize(hp0_arsize), .hp0_arburst(qm_arburst),
      .hp0_arvalid(hp0_arvalid), .hp0_arready(hp0_arready),
      .hp0_rdata(hp0_rdata), .hp0_rresp(qm_rresp), .hp0_rlast(hp0_rlast),
      .hp0_rvalid(hp0_rvalid), .hp0_rready(qm_rready),
      // The pack side and the display's reads: not on this board yet.
      .hp2_rclk(clk), .hp2_wclk(clk),
      .hp2_awaddr(49'd0), .hp2_awlen(8'd0), .hp2_awsize(3'd4), .hp2_awburst(2'b01),
      .hp2_awvalid(1'b0), .hp2_awready(hp2_awready),
      .hp2_wdata(128'd0), .hp2_wstrb(16'd0), .hp2_wlast(1'b0), .hp2_wvalid(1'b0),
      .hp2_wready(hp2_wready), .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid),
      .hp2_bready(1'b1),
      .hp2_araddr(49'd0), .hp2_arlen(8'd0), .hp2_arsize(3'd4), .hp2_arburst(2'b01),
      .hp2_arvalid(1'b0), .hp2_arready(hp2_arready),
      .hp2_rdata(hp2_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
      .hp2_rvalid(hp2_rvalid), .hp2_rready(1'b1),
      .gpio_i(96'd0), .gpio_o(gpio_o),
      .hp3_rclk(clk), .hp3_wclk(clk),
      .hp3_awaddr(49'd0), .hp3_awlen(8'd0), .hp3_awsize(3'd4), .hp3_awburst(2'b01),
      .hp3_awvalid(1'b0), .hp3_awready(hp3_awready),
      .hp3_wdata(128'd0), .hp3_wstrb(16'd0), .hp3_wlast(1'b0), .hp3_wvalid(1'b0),
      .hp3_wready(hp3_wready), .hp3_bresp(hp3_bresp), .hp3_bvalid(hp3_bvalid),
      .hp3_bready(1'b1),
      .hp3_araddr(49'd0), .hp3_arlen(8'd0), .hp3_arsize(3'd4), .hp3_arburst(2'b01),
      .hp3_arvalid(1'b0), .hp3_arready(hp3_arready),
      .hp3_rdata(hp3_rdata), .hp3_rresp(hp3_rresp), .hp3_rlast(hp3_rlast),
      .hp3_rvalid(hp3_rvalid), .hp3_rready(1'b1),
      .dp_videoinclk(clk), .dp_livevideoinvsync(1'b0),
      .dp_livevideoinhsync(1'b0), .dp_livevideoinde(1'b0),
      .dp_livevideoinpixel1(36'd0),
      .irq0(8'd0)
  );

  // ------------------------------------------------------------ the lamps
  //
  // UF1: bit 19 of a count of committed microcycles, so it flickers while
  // the machine runs and freezes when it stops.  UF2: lit while the machine
  // is stopped at an error.  Registered on the way to the pad.
  logic [19:0] commits;
  always_ff @(posedge clk) begin
    if (mach_rst) commits <= 20'd0;
    else if (obs_commit[15]) commits <= commits + 20'd1;
    uf1 <= commits[19];
    uf2 <= obs_errhalt != 2'd0;
  end

  // ---------------------------------------------------------------- the fan
  //
  // Low runs it.  Every KR260 bitstream holds it so.
  assign fan_en_b = 1'b0;

  // PMOD1 is the debug cable's connector, which QUUX has not got: its pads
  // undriven, held low by the pin file's pull-downs.
  for (genvar i = 0; i < 8; i = i + 1) begin : g_pmod1
    assign pmod1[i] = 1'bz;
  end

  // What nothing on this board reads yet.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{obs_cs, obs_rd, obs_ex, obs_wb, obs_commit[14:0], obs_pdlptr, obs_pdlidx,
                    obs_spcptr, obs_q, obs_vma, obs_md, obs_lc, obs_ic, obs_opnd, obs_ea, obs_em,
                    obs_ob, obs_oalow, obs_oahigh, obs_grant, obs_gaddr, obs_mdl, obs_mdword,
                    obs_reg, obs_raddr, obs_queue, obs_inflight, obs_halted, ro_word,
                    fd_doorbell, fd_prod, fd_enabled,
                    axi_one_write_id, axi_read_clocks, axi_write_clocks, qm_awid,
                    qm_awlen[7:4], qm_arlen[7:4], qm_awsize[2], qm_arsize[2],
                    hpm0_awaddr, hpm0_araddr, hpm0_awlen, gp0_wdata, gp0_wstrb, hpm1_awaddr[39:32], hpm1_araddr[39:32],
                    gpio_o[94:0], gp1c_awaddr[31:12], gp1c_araddr[31:12],
                    gp1d_awaddr, gp1d_araddr, gp1d_awlen, gp1d_wdata, gp1d_wstrb,
                    hp2_awready, hp2_wready, hp2_bvalid, hp2_arready, hp2_rlast, hp2_rvalid,
                    hp2_bresp, hp2_rresp, hp2_rdata, hp3_rdata, hp3_awready, hp3_wready,
                    hp3_bvalid, hp3_arready, hp3_rlast, hp3_rvalid, hp3_bresp, hp3_rresp};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
