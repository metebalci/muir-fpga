// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fault bitstream for the Kria KR260: no machine, both lamps blinking.
//
// **WHAT IT IS FOR.**  `boot.scr` loads it when the CADR's own bitstream
// could not be loaded (`boot.cmd`'s `cadr_fault_card`, `uEnv.net`'s
// `cadr_fabric_net`), so that a board whose card is wrong says so at a glance
// rather than on a serial console nobody is watching.  `docs/board.md` says
// when it is loaded and what to check.
//
// **WHAT IT DOES.**  UF1 and UF2 blink together, two flashes a second.  One
// register drives both (`rtl/plumbing/cadr_fault_lamp.sv`), so they cannot
// drift apart.  None of the CADR's lamp patterns (`cadr_kr260.sv`, the two
// lamps) has both lamps changing together at this rate.
//
// **AND WHAT IT KEEPS, WHICH IS THE PROCESSING SYSTEM'S SIDE OF THE BOARD.**
// Linux runs on while this is loaded, and a read of a port that nothing in
// the fabric answers hangs the Arm cores (`rtl/plumbing/cadr_gp0_default.sv`
// has the measurement on the Zynq-7000).  So `M_AXI_HPM0_FPD` and
// `M_AXI_HPM1_FPD` are each answered, whole, by the default slave, at every
// address the CADR's bitstream answers and every other: each read returns
// "FALT" in every beat and, the ports being 128 bits wide here, in every lane
// of every beat, and each write is taken and dropped.  Nothing in the fabric
// masters memory: the two high-performance ports the wrapper brings out see
// no valid and take any response.
//
// **IT SAYS WHAT IT IS.**  The EMIO tally, which every program reads before
// it touches a port (`cadr_mem.h`), reads "FALT" in both words, EMIO 31:0 and
// 63:32 (`DATA_3_RO` and `DATA_4_RO`).  That fails the tally's marker test,
// so every program refuses the fabric, and it is a value the init scripts
// recognize as this bitstream.  The build stamp in USERCODE and USR_ACCESS
// marks it too (`tools/build_stamp.tcl`).
//
// **THE FAN RUNS**, `fan_en_b` low, as under the CADR: a bitstream that
// stopped the SOM's fan would be a thermal fault of its own.
//
// The ports are clocked by the CADR's own 100 MHz, made the CADR's way from
// the carrier's 25 MHz, and each port's logic is held in reset by
// `pl_resetn0`, EMIO GPIO 95, synchronized, as under the CADR
// (`cadr_kr260.sv`, the ports' reset).
//
// `tb/cadr_fault_tb.cpp` simulates this file with the processing system of
// `tb/cadr_ps8_sim.sv`, and holds all of the above.

`default_nettype none

module cadr_kr260_fault #(
    // The lamps' half period in ticks: 250 ms at the fabric's 100 MHz.
    parameter int unsigned HALF_T = 25_000_000
) (
    input  var logic       clk25,     // the carrier's 25 MHz, pin C3
    // UF1 and UF2, lit when driven high.
    output var logic       uf1,
    output var logic       uf2,
    // The SOM's fan, on when LOW.
    output var logic       fan_en_b,
    // The debug cable's header, left to its pull-downs.
    inout  wire  [7:0]     pmod1
);

  // "FALT": the tally's two words and every answer of both ports.
  localparam logic [31:0] FAULT_WORD = 32'h4641_4C54;

  // ------------------------------------------------------------ the clock
  //
  // The CADR's own: 25 MHz in, 1000 MHz at the VCO, 100 MHz out, so that
  // the ports run at the clock they run at under the CADR.
  logic clk_fb, clk_raw, clk, mmcm_locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME4_BASE #(
      .CLKIN1_PERIOD  (40.000),
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(40.000),
      .CLKOUT0_DIVIDE_F(10.000)
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

  // ------------------------------------------------------------ the lamps
  logic lit;
  cadr_fault_lamp #(.HALF_T(HALF_T)) u_lamp (.clk(clk), .lit(lit));

  assign uf1 = lit;
  assign uf2 = lit;

  // -------------------------------------------------------------- the fan
  assign fan_en_b = 1'b0;

  // ------------------------------------------------ the processing system
  //
  // `pl_resetn0`, synchronized, holds both default slaves in reset: a reset
  // of one with a transaction in flight would take the address and never
  // answer it, so they take the ports' reset and nothing else.
  logic [95:0] gpio_o;
  logic [2:0]  port_rst_sync;
  logic        port_rst;
  always_ff @(posedge clk) begin
    port_rst_sync <= {port_rst_sync[1:0], gpio_o[95]};
    port_rst      <= !port_rst_sync[2];
  end

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
  logic [31:0]  hpm0_word, hpm1_word;

  cadr_gp0_default #(.WORD(FAULT_WORD), .ID_W(16), .LEN_W(8)) u_hpm0 (
      .clk(clk), .rst(port_rst),
      .s_awvalid(hpm0_awvalid), .s_awid(hpm0_awid), .s_awready(hpm0_awready),
      .s_wlast(hpm0_wlast), .s_wvalid(hpm0_wvalid), .s_wready(hpm0_wready),
      .s_bresp(hpm0_bresp), .s_bid(hpm0_bid), .s_bvalid(hpm0_bvalid),
      .s_bready(hpm0_bready),
      .s_arlen(hpm0_arlen), .s_arid(hpm0_arid), .s_arvalid(hpm0_arvalid),
      .s_arready(hpm0_arready), .s_rdata(hpm0_word), .s_rresp(hpm0_rresp),
      .s_rid(hpm0_rid), .s_rlast(hpm0_rlast), .s_rvalid(hpm0_rvalid),
      .s_rready(hpm0_rready)
  );
  cadr_gp0_default #(.WORD(FAULT_WORD), .ID_W(16), .LEN_W(8)) u_hpm1 (
      .clk(clk), .rst(port_rst),
      .s_awvalid(hpm1_awvalid), .s_awid(hpm1_awid), .s_awready(hpm1_awready),
      .s_wlast(hpm1_wlast), .s_wvalid(hpm1_wvalid), .s_wready(hpm1_wready),
      .s_bresp(hpm1_bresp), .s_bid(hpm1_bid), .s_bvalid(hpm1_bvalid),
      .s_bready(hpm1_bready),
      .s_arlen(hpm1_arlen), .s_arid(hpm1_arid), .s_arvalid(hpm1_arvalid),
      .s_arready(hpm1_arready), .s_rdata(hpm1_word), .s_rresp(hpm1_rresp),
      .s_rid(hpm1_rid), .s_rlast(hpm1_rlast), .s_rvalid(hpm1_rvalid),
      .s_rready(hpm1_rready)
  );

  // The word in every lane, so whichever lane a narrow read's address
  // selects holds it (`rtl/plumbing/cadr_axi_lanes128.sv`, a read).
  assign hpm0_rdata = {4{hpm0_word}};
  assign hpm1_rdata = {4{hpm1_word}};

  // The tally, on EMIO banks 3 and 4: "FALT" in both words, a pattern
  // without the marker bits and not one an absent instrument reads.  Bank
  // 5 reads zero: no clock is counted here.
  logic [95:0] gpio_i;
  assign gpio_i = {32'd0, FAULT_WORD, FAULT_WORD};

  // The two memory ports: no address, no data, and every response taken.
  logic hp0_awready, hp0_wready, hp0_bvalid, hp0_arready, hp0_rlast, hp0_rvalid;
  logic hp2_awready, hp2_wready, hp2_bvalid, hp2_arready, hp2_rlast, hp2_rvalid;
  logic [1:0]   hp0_bresp, hp0_rresp, hp2_bresp, hp2_rresp;
  logic [127:0] hp0_rdata, hp2_rdata;

  // **KEPT BY NAME.**  Nothing here leaves the chip through the processing
  // system: its ports feed the default slaves and the slaves feed it back,
  // a loop with no load outside it, and Vivado's `opt_design` swept the
  // whole of it, the `PS8` with both slaves, on the first fit of this file.
  // `tools/fault_zynq.tcl` counts the `PS8` and stops when it is missing;
  // under the CADR the machine and its lamps are the load that keeps it.
  (* DONT_TOUCH = "true" *)
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
      .hp0_rclk(clk), .hp0_wclk(clk),
      .hp0_awaddr(49'd0), .hp0_awlen(8'd0), .hp0_awsize(3'b100), .hp0_awburst(2'b01),
      .hp0_awvalid(1'b0), .hp0_awready(hp0_awready),
      .hp0_wdata(128'd0), .hp0_wstrb(16'd0), .hp0_wlast(1'b0), .hp0_wvalid(1'b0),
      .hp0_wready(hp0_wready),
      .hp0_bresp(hp0_bresp), .hp0_bvalid(hp0_bvalid), .hp0_bready(1'b1),
      .hp0_araddr(49'd0), .hp0_arlen(8'd0), .hp0_arsize(3'b100), .hp0_arburst(2'b01),
      .hp0_arvalid(1'b0), .hp0_arready(hp0_arready),
      .hp0_rdata(hp0_rdata), .hp0_rresp(hp0_rresp), .hp0_rlast(hp0_rlast),
      .hp0_rvalid(hp0_rvalid), .hp0_rready(1'b1),
      .hp2_rclk(clk), .hp2_wclk(clk),
      .hp2_awaddr(49'd0), .hp2_awlen(8'd0), .hp2_awsize(3'b100), .hp2_awburst(2'b01),
      .hp2_awvalid(1'b0), .hp2_awready(hp2_awready),
      .hp2_wdata(128'd0), .hp2_wstrb(16'd0), .hp2_wlast(1'b0), .hp2_wvalid(1'b0),
      .hp2_wready(hp2_wready),
      .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid), .hp2_bready(1'b1),
      .hp2_araddr(49'd0), .hp2_arlen(8'd0), .hp2_arsize(3'b100), .hp2_arburst(2'b01),
      .hp2_arvalid(1'b0), .hp2_arready(hp2_arready),
      .hp2_rdata(hp2_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
      .hp2_rvalid(hp2_rvalid), .hp2_rready(1'b1),
      .gpio_i(gpio_i), .gpio_o(gpio_o),
      .irq0(8'd0)
  );

  // ------------------------------------------------------- the connectors
  assign pmod1 = 8'bzzzz_zzzz;

  // What this design reads of nothing: the addresses and data of both
  // ports, the memory ports' answers, every EMIO output but `pl_resetn0`,
  // and the clock generator's lock, which a lamp with no reset has no use
  // for.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{mmcm_locked, gpio_o[94:0],
                    hpm0_awaddr, hpm0_araddr, hpm0_wdata, hpm0_wstrb, hpm0_awlen,
                    hpm1_awaddr, hpm1_araddr, hpm1_wdata, hpm1_wstrb, hpm1_awlen,
                    hp0_awready, hp0_wready, hp0_bvalid, hp0_arready, hp0_rlast, hp0_rvalid,
                    hp2_awready, hp2_wready, hp2_bvalid, hp2_arready, hp2_rlast, hp2_rvalid,
                    hp0_bresp, hp0_rresp, hp2_bresp, hp2_rresp,
                    hp0_rdata, hp2_rdata};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
