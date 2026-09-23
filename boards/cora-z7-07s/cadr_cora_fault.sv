// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fault bitstream for the Cora Z7-07S: no machine, both lamps blinking.
//
// **WHAT IT IS FOR.**  U-Boot loads it when the CADR's own bitstream could
// not be loaded, so that a board whose card is wrong says so at a glance
// rather than on a serial console nobody is watching.  `docs/board.md` says
// when it is loaded and what to check.
//
// **WHAT IT DOES.**  Both lamps blink together, two flashes a second, red,
// with their green and blue pins dark.
// One register drives every one of them (`rtl/plumbing/cadr_fault_lamp.sv`),
// so they cannot drift apart.
//
// **AND WHAT IT KEEPS, WHICH IS THE PROCESSING SYSTEM'S SIDE OF THE BOARD.**
// Linux runs on while this is loaded, and a read of a general-purpose port
// that nothing in the fabric answers hangs both Arm cores
// (`rtl/plumbing/cadr_gp0_default.sv` has the measurement).  So `M_AXI_GP0`
// and `M_AXI_GP1` are each answered, whole, by the default slave, at every
// address the CADR's bitstream answers and every other: each read returns
// "FALT" in every beat and each write is taken and dropped.  Nothing in the
// fabric masters memory: the two high-performance ports this board's wrapper
// brings out see no valid and take any response.
//
// **IT SAYS WHAT IT IS.**  The EMIO tally, which every program reads before
// it touches a port (`cadr_mem.h`), reads "FALT" in both words.  That fails
// the tally's marker test, so every program refuses the fabric, and it is a
// value the init scripts recognize as this bitstream.  The build stamp in
// USERCODE and USR_ACCESS marks it too (`tools/build_stamp.tcl`).
//
// `tb/cadr_fault_tb.cpp` simulates this file with the processing system of
// `tb/cadr_ps7_sim.sv`, and holds all of the above.

`default_nettype none

module cadr_cora_fault #(
    // The lamps' half period in ticks: 250 ms at the fabric's 100 MHz.
    parameter int unsigned HALF_T = 25_000_000
) (
    input  var logic       sysclk,   // 125 MHz, pin H16
    input  var logic [1:0] btn,
    // The two RGB lamps. Driven high to light, one pin a color.
    output var logic       led0_r, led0_g, led0_b,
    output var logic       led1_r, led1_g, led1_b,
    // The debug cable's header, left to its pull-downs.
    inout  wire  [7:0]     ja
);

  // "FALT": the tally's two words and every answer of both ports.
  localparam logic [31:0] FAULT_WORD = 32'h4641_4C54;

  // ------------------------------------------------------------ the clock
  //
  // The CADR's own: 125 MHz in, 1000 MHz at the VCO, 100 MHz out, so that
  // the ports run at the clock they run at under the CADR.
  logic clk_fb, clk_raw, clk, mmcm_locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME2_BASE #(
      .CLKIN1_PERIOD  (8.000),
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(8.000),
      .CLKOUT0_DIVIDE_F(10.000)
  ) u_mmcm (
      .CLKIN1  (sysclk),
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

  // ------------------------------------------------------------ the lamps
  logic lit;
  cadr_fault_lamp #(.HALF_T(HALF_T)) u_lamp (.clk(clk), .lit(lit));

  assign led0_r = lit;
  assign led0_g = 1'b0;
  assign led0_b = 1'b0;
  assign led1_r = lit;
  assign led1_g = 1'b0;
  assign led1_b = 1'b0;

  // ------------------------------------------------ the processing system
  //
  // Each port's default slave takes the port's own reset and nothing else,
  // synchronized, as under the CADR: a reset of it with a transaction in
  // flight would take the address and never answer it.
  logic        gp0_aresetn, gp1_aresetn;
  logic [2:0]  gp0_rst_sync, gp1_rst_sync;
  logic        gp0_rst, gp1_rst;
  always_ff @(posedge clk) begin
    gp0_rst_sync <= {gp0_rst_sync[1:0], gp0_aresetn};
    gp0_rst      <= !gp0_rst_sync[2];
    gp1_rst_sync <= {gp1_rst_sync[1:0], gp1_aresetn};
    gp1_rst      <= !gp1_rst_sync[2];
  end

  logic [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
  logic [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb;
  logic [11:0] gp0_awid, gp0_arid, gp0_bid, gp0_rid;
  logic [1:0]  gp0_bresp, gp0_rresp;
  logic        gp0_awvalid, gp0_awready, gp0_wlast, gp0_wvalid, gp0_wready;
  logic        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
  logic        gp0_rlast, gp0_rvalid, gp0_rready;
  logic [31:0] gp1_awaddr, gp1_araddr, gp1_wdata, gp1_rdata;
  logic [3:0]  gp1_awlen, gp1_arlen, gp1_wstrb;
  logic [11:0] gp1_awid, gp1_arid, gp1_bid, gp1_rid;
  logic [1:0]  gp1_bresp, gp1_rresp;
  logic        gp1_awvalid, gp1_awready, gp1_wlast, gp1_wvalid, gp1_wready;
  logic        gp1_bvalid, gp1_bready, gp1_arvalid, gp1_arready;
  logic        gp1_rlast, gp1_rvalid, gp1_rready;

  cadr_gp0_default #(.WORD(FAULT_WORD)) u_gp0 (
      .clk(clk), .rst(gp0_rst),
      .s_awvalid(gp0_awvalid), .s_awid(gp0_awid), .s_awready(gp0_awready),
      .s_wlast(gp0_wlast), .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
      .s_bresp(gp0_bresp), .s_bid(gp0_bid), .s_bvalid(gp0_bvalid),
      .s_bready(gp0_bready),
      .s_arlen(gp0_arlen), .s_arid(gp0_arid), .s_arvalid(gp0_arvalid),
      .s_arready(gp0_arready), .s_rdata(gp0_rdata), .s_rresp(gp0_rresp),
      .s_rid(gp0_rid), .s_rlast(gp0_rlast), .s_rvalid(gp0_rvalid),
      .s_rready(gp0_rready)
  );
  cadr_gp0_default #(.WORD(FAULT_WORD)) u_gp1 (
      .clk(clk), .rst(gp1_rst),
      .s_awvalid(gp1_awvalid), .s_awid(gp1_awid), .s_awready(gp1_awready),
      .s_wlast(gp1_wlast), .s_wvalid(gp1_wvalid), .s_wready(gp1_wready),
      .s_bresp(gp1_bresp), .s_bid(gp1_bid), .s_bvalid(gp1_bvalid),
      .s_bready(gp1_bready),
      .s_arlen(gp1_arlen), .s_arid(gp1_arid), .s_arvalid(gp1_arvalid),
      .s_arready(gp1_arready), .s_rdata(gp1_rdata), .s_rresp(gp1_rresp),
      .s_rid(gp1_rid), .s_rlast(gp1_rlast), .s_rvalid(gp1_rvalid),
      .s_rready(gp1_rready)
  );

  // The tally, on EMIO: "FALT" in both words, a pattern without the marker
  // bits and not one an absent instrument reads.
  logic [63:0] gpio_i;
  assign gpio_i = {FAULT_WORD, FAULT_WORD};

  // The two memory ports: no address, no data, and every response taken.
  logic hp0_aresetn, hp2_aresetn;
  logic hp0_awready, hp0_wready, hp0_bvalid, hp0_arready, hp0_rlast, hp0_rvalid;
  logic hp2_awready, hp2_wready, hp2_bvalid, hp2_arready, hp2_rlast, hp2_rvalid;
  logic [1:0]  hp0_bresp, hp0_rresp, hp2_bresp, hp2_rresp;
  logic [63:0] hp0_rdata, hp2_rdata;

  cadr_ps7 u_ps7 (
      .hp0_aclk(clk), .hp0_aresetn(hp0_aresetn),
      .hp0_awaddr(32'd0), .hp0_awlen(4'd0), .hp0_awsize(2'b11), .hp0_awburst(2'b01),
      .hp0_awvalid(1'b0), .hp0_awready(hp0_awready),
      .hp0_wdata(64'd0), .hp0_wstrb(8'd0), .hp0_wlast(1'b0), .hp0_wvalid(1'b0),
      .hp0_wready(hp0_wready),
      .hp0_bresp(hp0_bresp), .hp0_bvalid(hp0_bvalid), .hp0_bready(1'b1),
      .hp0_araddr(32'd0), .hp0_arlen(4'd0), .hp0_arsize(2'b11), .hp0_arburst(2'b01),
      .hp0_arvalid(1'b0), .hp0_arready(hp0_arready),
      .hp0_rdata(hp0_rdata), .hp0_rresp(hp0_rresp), .hp0_rlast(hp0_rlast),
      .hp0_rvalid(hp0_rvalid), .hp0_rready(1'b1),
      .gpio_i(gpio_i),
      .hp2_aclk(clk), .hp2_aresetn(hp2_aresetn),
      .hp2_awaddr(32'd0), .hp2_awlen(4'd0), .hp2_awsize(2'b11), .hp2_awburst(2'b01),
      .hp2_awvalid(1'b0), .hp2_awready(hp2_awready),
      .hp2_wdata(64'd0), .hp2_wstrb(8'd0), .hp2_wlast(1'b0), .hp2_wvalid(1'b0),
      .hp2_wready(hp2_wready),
      .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid), .hp2_bready(1'b1),
      .hp2_araddr(32'd0), .hp2_arlen(4'd0), .hp2_arsize(2'b11), .hp2_arburst(2'b01),
      .hp2_arvalid(1'b0), .hp2_arready(hp2_arready),
      .hp2_rdata(hp2_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
      .hp2_rvalid(hp2_rvalid), .hp2_rready(1'b1),
      .gp0_aclk(clk), .gp0_aresetn(gp0_aresetn),
      .gp0_awaddr(gp0_awaddr), .gp0_awlen(gp0_awlen), .gp0_awid(gp0_awid),
      .gp0_awvalid(gp0_awvalid), .gp0_awready(gp0_awready),
      .gp0_wdata(gp0_wdata), .gp0_wstrb(gp0_wstrb), .gp0_wlast(gp0_wlast),
      .gp0_wvalid(gp0_wvalid), .gp0_wready(gp0_wready),
      .gp0_bresp(gp0_bresp), .gp0_bid(gp0_bid), .gp0_bvalid(gp0_bvalid),
      .gp0_bready(gp0_bready),
      .gp0_araddr(gp0_araddr), .gp0_arlen(gp0_arlen), .gp0_arid(gp0_arid),
      .gp0_arvalid(gp0_arvalid), .gp0_arready(gp0_arready),
      .gp0_rdata(gp0_rdata), .gp0_rresp(gp0_rresp), .gp0_rid(gp0_rid),
      .gp0_rlast(gp0_rlast), .gp0_rvalid(gp0_rvalid), .gp0_rready(gp0_rready),
      .gp1_aclk(clk), .gp1_aresetn(gp1_aresetn),
      .gp1_awaddr(gp1_awaddr), .gp1_awlen(gp1_awlen), .gp1_awid(gp1_awid),
      .gp1_awvalid(gp1_awvalid), .gp1_awready(gp1_awready),
      .gp1_wdata(gp1_wdata), .gp1_wstrb(gp1_wstrb), .gp1_wlast(gp1_wlast),
      .gp1_wvalid(gp1_wvalid), .gp1_wready(gp1_wready),
      .gp1_bresp(gp1_bresp), .gp1_bid(gp1_bid), .gp1_bvalid(gp1_bvalid),
      .gp1_bready(gp1_bready),
      .gp1_araddr(gp1_araddr), .gp1_arlen(gp1_arlen), .gp1_arid(gp1_arid),
      .gp1_arvalid(gp1_arvalid), .gp1_arready(gp1_arready),
      .gp1_rdata(gp1_rdata), .gp1_rresp(gp1_rresp), .gp1_rid(gp1_rid),
      .gp1_rlast(gp1_rlast), .gp1_rvalid(gp1_rvalid), .gp1_rready(gp1_rready),
      .irqf2p(20'd0)
  );

  // ------------------------------------------------------- the connectors
  assign ja = 8'bzzzz_zzzz;


  // What this design reads of nothing: the buttons, the
  // addresses and data of both ports, the memory ports' answers and resets,
  // and the clock generator's lock, which a lamp with no reset has no use for.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{btn, mmcm_locked,
                    gp0_awaddr, gp0_araddr, gp0_wdata, gp0_wstrb, gp0_awlen,
                    gp1_awaddr, gp1_araddr, gp1_wdata, gp1_wstrb, gp1_awlen,
                    hp0_aresetn, hp2_aresetn,
                    hp0_awready, hp0_wready, hp0_bvalid, hp0_arready, hp0_rlast, hp0_rvalid,
                    hp2_awready, hp2_wready, hp2_bvalid, hp2_arready, hp2_rlast, hp2_rvalid,
                    hp0_bresp, hp0_rresp, hp2_bresp, hp2_rresp,
                    hp0_rdata, hp2_rdata};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
