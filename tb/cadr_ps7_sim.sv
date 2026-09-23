// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_ps7` for a simulation: the Zynq's processing system as far as the
// fabric sees it, the two general-purpose ports driven by the processor and
// the high-performance ports answered by memory, with the behavior of both in
// `tb/cadr_board_reset_tb.cpp` through `tb/cadr_sim_axi.sv`.  The port list
// is `boards/arty-z7-20/cadr_ps7.sv`'s, and `CADR_PS7_NO_HP3` takes out the
// one port the Cora Z7-07S's wrapper does not bring out.  A port list that
// drifted from the wrapper's would not elaborate against the top level.
//
// It stands in for the wrapper and not for `PS7`, so that the stub of the
// primitive (`tb/cadr_ps7_stub.sv`) stays a lint stub and nothing else.

`default_nettype none

// A model's ports are the hard block's, and it reads what it needs of them.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */

module cadr_ps7 (
    input  var logic         hp0_aclk,
    output var logic         hp0_aresetn,
    input  var logic [31:0]  hp0_awaddr,
    input  var logic [3:0]   hp0_awlen,
    input  var logic [1:0]   hp0_awsize,
    input  var logic [1:0]   hp0_awburst,
    input  var logic         hp0_awvalid,
    output var logic         hp0_awready,
    input  var logic [63:0]  hp0_wdata,
    input  var logic [7:0]   hp0_wstrb,
    input  var logic         hp0_wlast,
    input  var logic         hp0_wvalid,
    output var logic         hp0_wready,
    output var logic [1:0]   hp0_bresp,
    output var logic         hp0_bvalid,
    input  var logic         hp0_bready,
    input  var logic [31:0]  hp0_araddr,
    input  var logic [3:0]   hp0_arlen,
    input  var logic [1:0]   hp0_arsize,
    input  var logic [1:0]   hp0_arburst,
    input  var logic         hp0_arvalid,
    output var logic         hp0_arready,
    output var logic [63:0]  hp0_rdata,
    output var logic [1:0]   hp0_rresp,
    output var logic         hp0_rlast,
    output var logic         hp0_rvalid,
    input  var logic         hp0_rready,
    input  var logic [63:0]  gpio_i,
    input  var logic         hp2_aclk,
    output var logic         hp2_aresetn,
    input  var logic [31:0]  hp2_awaddr,
    input  var logic [3:0]   hp2_awlen,
    input  var logic [1:0]   hp2_awsize,
    input  var logic [1:0]   hp2_awburst,
    input  var logic         hp2_awvalid,
    output var logic         hp2_awready,
    input  var logic [63:0]  hp2_wdata,
    input  var logic [7:0]   hp2_wstrb,
    input  var logic         hp2_wlast,
    input  var logic         hp2_wvalid,
    output var logic         hp2_wready,
    output var logic [1:0]   hp2_bresp,
    output var logic         hp2_bvalid,
    input  var logic         hp2_bready,
    input  var logic [31:0]  hp2_araddr,
    input  var logic [3:0]   hp2_arlen,
    input  var logic [1:0]   hp2_arsize,
    input  var logic [1:0]   hp2_arburst,
    input  var logic         hp2_arvalid,
    output var logic         hp2_arready,
    output var logic [63:0]  hp2_rdata,
    output var logic [1:0]   hp2_rresp,
    output var logic         hp2_rlast,
    output var logic         hp2_rvalid,
    input  var logic         hp2_rready,
`ifndef CADR_PS7_NO_HP3
    input  var logic         hp3_aclk,
    output var logic         hp3_aresetn,
    input  var logic [31:0]  hp3_awaddr,
    input  var logic [3:0]   hp3_awlen,
    input  var logic [1:0]   hp3_awsize,
    input  var logic [1:0]   hp3_awburst,
    input  var logic         hp3_awvalid,
    output var logic         hp3_awready,
    input  var logic [63:0]  hp3_wdata,
    input  var logic [7:0]   hp3_wstrb,
    input  var logic         hp3_wlast,
    input  var logic         hp3_wvalid,
    output var logic         hp3_wready,
    output var logic [1:0]   hp3_bresp,
    output var logic         hp3_bvalid,
    input  var logic         hp3_bready,
    input  var logic [31:0]  hp3_araddr,
    input  var logic [3:0]   hp3_arlen,
    input  var logic [1:0]   hp3_arsize,
    input  var logic [1:0]   hp3_arburst,
    input  var logic         hp3_arvalid,
    output var logic         hp3_arready,
    output var logic [63:0]  hp3_rdata,
    output var logic [1:0]   hp3_rresp,
    output var logic         hp3_rlast,
    output var logic         hp3_rvalid,
    input  var logic         hp3_rready,
`endif
    input  var logic         gp0_aclk,
    output var logic         gp0_aresetn,
    output var logic [31:0]  gp0_awaddr,
    output var logic [3:0]   gp0_awlen,
    output var logic [11:0]  gp0_awid,
    output var logic         gp0_awvalid,
    input  var logic         gp0_awready,
    output var logic [31:0]  gp0_wdata,
    output var logic [3:0]   gp0_wstrb,
    output var logic         gp0_wlast,
    output var logic         gp0_wvalid,
    input  var logic         gp0_wready,
    input  var logic [1:0]   gp0_bresp,
    input  var logic [11:0]  gp0_bid,
    input  var logic         gp0_bvalid,
    output var logic         gp0_bready,
    output var logic [31:0]  gp0_araddr,
    output var logic [3:0]   gp0_arlen,
    output var logic [11:0]  gp0_arid,
    output var logic         gp0_arvalid,
    input  var logic         gp0_arready,
    input  var logic [31:0]  gp0_rdata,
    input  var logic [1:0]   gp0_rresp,
    input  var logic [11:0]  gp0_rid,
    input  var logic         gp0_rlast,
    input  var logic         gp0_rvalid,
    output var logic         gp0_rready,
    input  var logic         gp1_aclk,
    output var logic         gp1_aresetn,
    output var logic [31:0]  gp1_awaddr,
    output var logic [3:0]   gp1_awlen,
    output var logic [11:0]  gp1_awid,
    output var logic         gp1_awvalid,
    input  var logic         gp1_awready,
    output var logic [31:0]  gp1_wdata,
    output var logic [3:0]   gp1_wstrb,
    output var logic         gp1_wlast,
    output var logic         gp1_wvalid,
    input  var logic         gp1_wready,
    input  var logic [1:0]   gp1_bresp,
    input  var logic [11:0]  gp1_bid,
    input  var logic         gp1_bvalid,
    output var logic         gp1_bready,
    output var logic [31:0]  gp1_araddr,
    output var logic [3:0]   gp1_arlen,
    output var logic [11:0]  gp1_arid,
    output var logic         gp1_arvalid,
    input  var logic         gp1_arready,
    input  var logic [31:0]  gp1_rdata,
    input  var logic [1:0]   gp1_rresp,
    input  var logic [11:0]  gp1_rid,
    input  var logic         gp1_rlast,
    input  var logic         gp1_rvalid,
    output var logic         gp1_rready,
    input  var logic [19:0]  irqf2p
);

  /* verilator lint_off UNUSEDSIGNAL */
  import cadr_sim_axi_dpi::*;

  // Every port's reset is one level here, as `ps7_post_config` releases them
  // together on the board: level 0 is it, high out of reset.
  logic aresetn_q;
  always_ff @(posedge gp0_aclk) aresetn_q <= cadr_sim_level(0) != 0;
  assign hp0_aresetn = aresetn_q;
  assign hp2_aresetn = aresetn_q;
  assign gp0_aresetn = aresetn_q;
  assign gp1_aresetn = aresetn_q;

  // The two general-purpose ports, the processor the master: ports 0 and 1.
  cadr_sim_gp_master #(.PORT(0), .AW(32), .ID_W(12), .LEN_W(4)) u_gp0 (
      .clk(gp0_aclk),
      .awaddr(gp0_awaddr), .awlen(gp0_awlen), .awid(gp0_awid),
      .awvalid(gp0_awvalid), .awready(gp0_awready),
      .wdata(gp0_wdata), .wstrb(gp0_wstrb), .wlast(gp0_wlast),
      .wvalid(gp0_wvalid), .wready(gp0_wready),
      .bresp(gp0_bresp), .bid(gp0_bid), .bvalid(gp0_bvalid), .bready(gp0_bready),
      .araddr(gp0_araddr), .arlen(gp0_arlen), .arid(gp0_arid),
      .arvalid(gp0_arvalid), .arready(gp0_arready),
      .rdata(gp0_rdata), .rresp(gp0_rresp), .rid(gp0_rid), .rlast(gp0_rlast),
      .rvalid(gp0_rvalid), .rready(gp0_rready));
  cadr_sim_gp_master #(.PORT(1), .AW(32), .ID_W(12), .LEN_W(4)) u_gp1 (
      .clk(gp1_aclk),
      .awaddr(gp1_awaddr), .awlen(gp1_awlen), .awid(gp1_awid),
      .awvalid(gp1_awvalid), .awready(gp1_awready),
      .wdata(gp1_wdata), .wstrb(gp1_wstrb), .wlast(gp1_wlast),
      .wvalid(gp1_wvalid), .wready(gp1_wready),
      .bresp(gp1_bresp), .bid(gp1_bid), .bvalid(gp1_bvalid), .bready(gp1_bready),
      .araddr(gp1_araddr), .arlen(gp1_arlen), .arid(gp1_arid),
      .arvalid(gp1_arvalid), .arready(gp1_arready),
      .rdata(gp1_rdata), .rresp(gp1_rresp), .rid(gp1_rid), .rlast(gp1_rlast),
      .rvalid(gp1_rvalid), .rready(gp1_rready));

  // The high-performance ports, the fabric the master: memory slaves 0, 2
  // and 3, which carry no ID.
  logic hp0_bid_u, hp0_rid_u, hp2_bid_u, hp2_rid_u;
  cadr_sim_mem_slave #(.PORT(0), .ID_W(1), .LEN_W(4)) u_hp0 (
      .clk(hp0_aclk), .rst(!aresetn_q),
      .awaddr(hp0_awaddr), .awlen(hp0_awlen), .awid(1'b0),
      .awvalid(hp0_awvalid), .awready(hp0_awready),
      .wdata(hp0_wdata), .wstrb(hp0_wstrb), .wlast(hp0_wlast),
      .wvalid(hp0_wvalid), .wready(hp0_wready),
      .bresp(hp0_bresp), .bid(hp0_bid_u), .bvalid(hp0_bvalid), .bready(hp0_bready),
      .araddr(hp0_araddr), .arlen(hp0_arlen), .arid(1'b0),
      .arvalid(hp0_arvalid), .arready(hp0_arready),
      .rdata(hp0_rdata), .rresp(hp0_rresp), .rid(hp0_rid_u), .rlast(hp0_rlast),
      .rvalid(hp0_rvalid), .rready(hp0_rready));
  cadr_sim_mem_slave #(.PORT(2), .ID_W(1), .LEN_W(4)) u_hp2 (
      .clk(hp2_aclk), .rst(!aresetn_q),
      .awaddr(hp2_awaddr), .awlen(hp2_awlen), .awid(1'b0),
      .awvalid(hp2_awvalid), .awready(hp2_awready),
      .wdata(hp2_wdata), .wstrb(hp2_wstrb), .wlast(hp2_wlast),
      .wvalid(hp2_wvalid), .wready(hp2_wready),
      .bresp(hp2_bresp), .bid(hp2_bid_u), .bvalid(hp2_bvalid), .bready(hp2_bready),
      .araddr(hp2_araddr), .arlen(hp2_arlen), .arid(1'b0),
      .arvalid(hp2_arvalid), .arready(hp2_arready),
      .rdata(hp2_rdata), .rresp(hp2_rresp), .rid(hp2_rid_u), .rlast(hp2_rlast),
      .rvalid(hp2_rvalid), .rready(hp2_rready));
`ifndef CADR_PS7_NO_HP3
  logic hp3_bid_u, hp3_rid_u;
  assign hp3_aresetn = aresetn_q;
  cadr_sim_mem_slave #(.PORT(3), .ID_W(1), .LEN_W(4)) u_hp3 (
      .clk(hp3_aclk), .rst(!aresetn_q),
      .awaddr(hp3_awaddr), .awlen(hp3_awlen), .awid(1'b0),
      .awvalid(hp3_awvalid), .awready(hp3_awready),
      .wdata(hp3_wdata), .wstrb(hp3_wstrb), .wlast(hp3_wlast),
      .wvalid(hp3_wvalid), .wready(hp3_wready),
      .bresp(hp3_bresp), .bid(hp3_bid_u), .bvalid(hp3_bvalid), .bready(hp3_bready),
      .araddr(hp3_araddr), .arlen(hp3_arlen), .arid(1'b0),
      .arvalid(hp3_arvalid), .arready(hp3_arready),
      .rdata(hp3_rdata), .rresp(hp3_rresp), .rid(hp3_rid_u), .rlast(hp3_rlast),
      .rvalid(hp3_rvalid), .rready(hp3_rready));
`endif
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
