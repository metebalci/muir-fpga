// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_ps8` for a simulation: the Kria KR260's processing system as far as
// the fabric sees it, the counterpart of `tb/cadr_ps7_sim.sv`.  The two
// general-purpose ports, `M_AXI_HPM0_FPD` and `M_AXI_HPM1_FPD`, are driven by
// the processor through `tb/cadr_sim_axi.sv`, and the two high-performance
// ports the wrapper brings out are answered by memory there.  The port list
// is `boards/kria-kr260/cadr_ps8.sv`'s; a port list that drifted from the
// wrapper's would not elaborate against a top level.
//
// It stands in for the wrapper and not for `PS8`, so that the stub of the
// primitive (`tb/cadr_ps8_stub.sv`) stays a lint stub and nothing else.
//
// **THE PROCESSOR'S PORTS ARE 128 BITS WIDE AND ITS ACCESSES A WORD**, as on
// the board (`rtl/plumbing/cadr_axi_lanes128.sv` says why): a word's beat is
// placed in the lane its address selects, that lane's four strobes open and
// every other clear, and a read's word is taken from the lane its address
// selects.  The address of each beat of a burst steps by the word, as an
// INCR burst of four-byte beats does, so a burst walks the lanes.
//
// **THE PORTS' RESET IS `pl_resetn0`**, EMIO GPIO 95, which the processing
// system drives on `gpio_o`: level 0 of `cadr_sim_level`, high out of reset,
// as `ps7_post_config`'s level is on the Zynq-7000's model.
//
// **THE MEMORY PORTS ARE WATCHED, NOT SERVED WIDE**: `cadr_sim_mem_slave` is
// 64 bits wide, so the high-performance ports hand it the low half of their
// payload and the low 32 bits of their address.  What the fault check asks of
// them is that nothing raises a valid, which needs no more.  A harness that
// moves data through them needs a 128-bit memory first.

`default_nettype none

// A model's ports are the hard block's, and it reads what it needs of them.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
module cadr_ps8 (
    input  var logic          hpm0_aclk,
    output var logic [39:0]   hpm0_awaddr,
    output var logic [7:0]    hpm0_awlen,
    output var logic [15:0]   hpm0_awid,
    output var logic          hpm0_awvalid,
    input  var logic          hpm0_awready,
    output var logic [127:0]  hpm0_wdata,
    output var logic [15:0]   hpm0_wstrb,
    output var logic          hpm0_wlast,
    output var logic          hpm0_wvalid,
    input  var logic          hpm0_wready,
    input  var logic [1:0]    hpm0_bresp,
    input  var logic [15:0]   hpm0_bid,
    input  var logic          hpm0_bvalid,
    output var logic          hpm0_bready,
    output var logic [39:0]   hpm0_araddr,
    output var logic [7:0]    hpm0_arlen,
    output var logic [15:0]   hpm0_arid,
    output var logic          hpm0_arvalid,
    input  var logic          hpm0_arready,
    input  var logic [127:0]  hpm0_rdata,
    input  var logic [1:0]    hpm0_rresp,
    input  var logic [15:0]   hpm0_rid,
    input  var logic          hpm0_rlast,
    input  var logic          hpm0_rvalid,
    output var logic          hpm0_rready,
    input  var logic          hpm1_aclk,
    output var logic [39:0]   hpm1_awaddr,
    output var logic [7:0]    hpm1_awlen,
    output var logic [15:0]   hpm1_awid,
    output var logic          hpm1_awvalid,
    input  var logic          hpm1_awready,
    output var logic [127:0]  hpm1_wdata,
    output var logic [15:0]   hpm1_wstrb,
    output var logic          hpm1_wlast,
    output var logic          hpm1_wvalid,
    input  var logic          hpm1_wready,
    input  var logic [1:0]    hpm1_bresp,
    input  var logic [15:0]   hpm1_bid,
    input  var logic          hpm1_bvalid,
    output var logic          hpm1_bready,
    output var logic [39:0]   hpm1_araddr,
    output var logic [7:0]    hpm1_arlen,
    output var logic [15:0]   hpm1_arid,
    output var logic          hpm1_arvalid,
    input  var logic          hpm1_arready,
    input  var logic [127:0]  hpm1_rdata,
    input  var logic [1:0]    hpm1_rresp,
    input  var logic [15:0]   hpm1_rid,
    input  var logic          hpm1_rlast,
    input  var logic          hpm1_rvalid,
    output var logic          hpm1_rready,
    input  var logic          hp0_rclk,
    input  var logic          hp0_wclk,
    input  var logic [48:0]   hp0_awaddr,
    input  var logic [7:0]    hp0_awlen,
    input  var logic [2:0]    hp0_awsize,
    input  var logic [1:0]    hp0_awburst,
    input  var logic          hp0_awvalid,
    output var logic          hp0_awready,
    input  var logic [127:0]  hp0_wdata,
    input  var logic [15:0]   hp0_wstrb,
    input  var logic          hp0_wlast,
    input  var logic          hp0_wvalid,
    output var logic          hp0_wready,
    output var logic [1:0]    hp0_bresp,
    output var logic          hp0_bvalid,
    input  var logic          hp0_bready,
    input  var logic [48:0]   hp0_araddr,
    input  var logic [7:0]    hp0_arlen,
    input  var logic [2:0]    hp0_arsize,
    input  var logic [1:0]    hp0_arburst,
    input  var logic          hp0_arvalid,
    output var logic          hp0_arready,
    output var logic [127:0]  hp0_rdata,
    output var logic [1:0]    hp0_rresp,
    output var logic          hp0_rlast,
    output var logic          hp0_rvalid,
    input  var logic          hp0_rready,
    input  var logic          hp2_rclk,
    input  var logic          hp2_wclk,
    input  var logic [48:0]   hp2_awaddr,
    input  var logic [7:0]    hp2_awlen,
    input  var logic [2:0]    hp2_awsize,
    input  var logic [1:0]    hp2_awburst,
    input  var logic          hp2_awvalid,
    output var logic          hp2_awready,
    input  var logic [127:0]  hp2_wdata,
    input  var logic [15:0]   hp2_wstrb,
    input  var logic          hp2_wlast,
    input  var logic          hp2_wvalid,
    output var logic          hp2_wready,
    output var logic [1:0]    hp2_bresp,
    output var logic          hp2_bvalid,
    input  var logic          hp2_bready,
    input  var logic [48:0]   hp2_araddr,
    input  var logic [7:0]    hp2_arlen,
    input  var logic [2:0]    hp2_arsize,
    input  var logic [1:0]    hp2_arburst,
    input  var logic          hp2_arvalid,
    output var logic          hp2_arready,
    output var logic [127:0]  hp2_rdata,
    output var logic [1:0]    hp2_rresp,
    output var logic          hp2_rlast,
    output var logic          hp2_rvalid,
    input  var logic          hp2_rready,
    input  var logic [95:0]   gpio_i,
    output var logic [95:0]   gpio_o,
    input  var logic [7:0]    irq0
);

  import cadr_sim_axi_dpi::*;

  // `pl_resetn0` on EMIO 95, and nothing else driven on EMIO.
  logic resetn_q;
  always_ff @(posedge hpm0_aclk) resetn_q <= cadr_sim_level(0) != 0;
  assign gpio_o = {resetn_q, 95'd0};

  // ------------------------------------------- the two processor ports
  //
  // One word a beat from `cadr_sim_gp_master`, placed in its lane here.
  logic [31:0] m0_awaddr, m0_araddr, m1_awaddr, m1_araddr;
  logic [31:0] m0_wdata, m1_wdata;
  logic [3:0]  m0_wstrb, m1_wstrb;
  logic [31:0] m0_rdata, m1_rdata;

  cadr_sim_gp_master #(.PORT(0), .AW(32), .ID_W(16), .LEN_W(8)) u_hpm0 (
      .clk(hpm0_aclk),
      .awaddr(m0_awaddr), .awlen(hpm0_awlen), .awid(hpm0_awid),
      .awvalid(hpm0_awvalid), .awready(hpm0_awready),
      .wdata(m0_wdata), .wstrb(m0_wstrb), .wlast(hpm0_wlast),
      .wvalid(hpm0_wvalid), .wready(hpm0_wready),
      .bresp(hpm0_bresp), .bid(hpm0_bid), .bvalid(hpm0_bvalid), .bready(hpm0_bready),
      .araddr(m0_araddr), .arlen(hpm0_arlen), .arid(hpm0_arid),
      .arvalid(hpm0_arvalid), .arready(hpm0_arready),
      .rdata(m0_rdata), .rresp(hpm0_rresp), .rid(hpm0_rid), .rlast(hpm0_rlast),
      .rvalid(hpm0_rvalid), .rready(hpm0_rready));
  cadr_sim_gp_master #(.PORT(1), .AW(32), .ID_W(16), .LEN_W(8)) u_hpm1 (
      .clk(hpm1_aclk),
      .awaddr(m1_awaddr), .awlen(hpm1_awlen), .awid(hpm1_awid),
      .awvalid(hpm1_awvalid), .awready(hpm1_awready),
      .wdata(m1_wdata), .wstrb(m1_wstrb), .wlast(hpm1_wlast),
      .wvalid(hpm1_wvalid), .wready(hpm1_wready),
      .bresp(hpm1_bresp), .bid(hpm1_bid), .bvalid(hpm1_bvalid), .bready(hpm1_bready),
      .araddr(m1_araddr), .arlen(hpm1_arlen), .arid(hpm1_arid),
      .arvalid(hpm1_arvalid), .arready(hpm1_arready),
      .rdata(m1_rdata), .rresp(hpm1_rresp), .rid(hpm1_rid), .rlast(hpm1_rlast),
      .rvalid(hpm1_rvalid), .rready(hpm1_rready));

  assign hpm0_awaddr = {8'd0, m0_awaddr};
  assign hpm0_araddr = {8'd0, m0_araddr};
  assign hpm1_awaddr = {8'd0, m1_awaddr};
  assign hpm1_araddr = {8'd0, m1_araddr};

  // The beat within the burst, on each channel of each port: the master
  // holds a transaction's address through all of its beats.
  logic [7:0] w0_beat, r0_beat, w1_beat, r1_beat;
  always_ff @(posedge hpm0_aclk) begin
    if (hpm0_wvalid && hpm0_wready) w0_beat <= hpm0_wlast ? 8'd0 : w0_beat + 8'd1;
    if (hpm0_rvalid && hpm0_rready) r0_beat <= hpm0_rlast ? 8'd0 : r0_beat + 8'd1;
    if (!resetn_q) begin w0_beat <= 8'd0; r0_beat <= 8'd0; end
  end
  always_ff @(posedge hpm1_aclk) begin
    if (hpm1_wvalid && hpm1_wready) w1_beat <= hpm1_wlast ? 8'd0 : w1_beat + 8'd1;
    if (hpm1_rvalid && hpm1_rready) r1_beat <= hpm1_rlast ? 8'd0 : r1_beat + 8'd1;
    if (!resetn_q) begin w1_beat <= 8'd0; r1_beat <= 8'd0; end
  end

  logic [1:0] w0_lane, r0_lane, w1_lane, r1_lane;
  assign w0_lane = m0_awaddr[3:2] + w0_beat[1:0];
  assign r0_lane = m0_araddr[3:2] + r0_beat[1:0];
  assign w1_lane = m1_awaddr[3:2] + w1_beat[1:0];
  assign r1_lane = m1_araddr[3:2] + r1_beat[1:0];

  assign hpm0_wdata = 128'(m0_wdata) << (32 * w0_lane);
  assign hpm0_wstrb = 16'(m0_wstrb) << (4 * w0_lane);
  assign hpm1_wdata = 128'(m1_wdata) << (32 * w1_lane);
  assign hpm1_wstrb = 16'(m1_wstrb) << (4 * w1_lane);
  assign m0_rdata = hpm0_rdata[32 * r0_lane +: 32];
  assign m1_rdata = hpm1_rdata[32 * r1_lane +: 32];

  // ----------------------------------------- the two memory ports
  //
  // Memory slaves 0 and 2, which carry no ID, watched through their low half.
  logic hp0_bid_u, hp0_rid_u, hp2_bid_u, hp2_rid_u;
  logic [63:0] hp0_rdata_lo, hp2_rdata_lo;
  cadr_sim_mem_slave #(.PORT(0), .ID_W(1), .LEN_W(8)) u_hp0 (
      .clk(hp0_wclk), .rst(!resetn_q),
      .awaddr(hp0_awaddr[31:0]), .awlen(hp0_awlen), .awid(1'b0),
      .awvalid(hp0_awvalid), .awready(hp0_awready),
      .wdata(hp0_wdata[63:0]), .wstrb(hp0_wstrb[7:0]), .wlast(hp0_wlast),
      .wvalid(hp0_wvalid), .wready(hp0_wready),
      .bresp(hp0_bresp), .bid(hp0_bid_u), .bvalid(hp0_bvalid), .bready(hp0_bready),
      .araddr(hp0_araddr[31:0]), .arlen(hp0_arlen), .arid(1'b0),
      .arvalid(hp0_arvalid), .arready(hp0_arready),
      .rdata(hp0_rdata_lo), .rresp(hp0_rresp), .rid(hp0_rid_u), .rlast(hp0_rlast),
      .rvalid(hp0_rvalid), .rready(hp0_rready));
  cadr_sim_mem_slave #(.PORT(2), .ID_W(1), .LEN_W(8)) u_hp2 (
      .clk(hp2_wclk), .rst(!resetn_q),
      .awaddr(hp2_awaddr[31:0]), .awlen(hp2_awlen), .awid(1'b0),
      .awvalid(hp2_awvalid), .awready(hp2_awready),
      .wdata(hp2_wdata[63:0]), .wstrb(hp2_wstrb[7:0]), .wlast(hp2_wlast),
      .wvalid(hp2_wvalid), .wready(hp2_wready),
      .bresp(hp2_bresp), .bid(hp2_bid_u), .bvalid(hp2_bvalid), .bready(hp2_bready),
      .araddr(hp2_araddr[31:0]), .arlen(hp2_arlen), .arid(1'b0),
      .arvalid(hp2_arvalid), .arready(hp2_arready),
      .rdata(hp2_rdata_lo), .rresp(hp2_rresp), .rid(hp2_rid_u), .rlast(hp2_rlast),
      .rvalid(hp2_rvalid), .rready(hp2_rready));
  assign hp0_rdata = {64'd0, hp0_rdata_lo};
  assign hp2_rdata = {64'd0, hp2_rdata_lo};
endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
