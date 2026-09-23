// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The processing system's two kinds of AXI port, for a simulation of a whole
// board's top level: a general-purpose master and a memory slave.  Each is a
// shell around one DPI call a tick, and the behavior is C++'s, in
// `tb/cadr_board_reset_tb.cpp`, where the stimulus is and where the checks
// are.  `tb/cadr_ps7_sim.sv` and `tb/cadr_de25_hps_sim.sv` put them where
// the hard blocks are.
//
// THE CALL IS MADE AT THE RISING EDGE AND SEES WHAT THE FABRIC DROVE BEFORE
// IT, and what it returns is driven from the edge on, as a register is.  So
// the C++ side is a synchronous master or slave: a handshake is its own
// valid (or ready) as it stood before the edge, together with the other
// side's ready (or valid) as it stood before the edge.
//
// Nothing here is a model of the hard block's timing, and nothing needs to
// be: what is checked is whether the fabric answers, not how fast.

`default_nettype none

// A model's ports are the hard block's, and it reads what it needs of them.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */

package cadr_sim_axi_dpi;
  // A master on port `port`.  In: what the slave drove.  Out: what the
  // master drives from this edge.
  import "DPI-C" context function void cadr_sim_gp(
      input int port,
      input bit awready, input bit wready,
      input bit bvalid, input int bresp, input int bid,
      input bit arready,
      input bit rvalid, input int rdata, input int rresp, input int rid,
      input bit rlast,
      output int awaddr, output int awlen, output int awid, output bit awvalid,
      output int wdata, output int wstrb, output bit wlast, output bit wvalid,
      output bit bready,
      output int araddr, output int arlen, output int arid, output bit arvalid,
      output bit rready);

  // A memory slave on port `port`.  In: what the master drove, and the
  // port's own reset as the processing system holds it.  Out: what the
  // slave drives from this edge.
  import "DPI-C" context function void cadr_sim_mem(
      input int port, input bit rst,
      input int awaddr, input int awlen, input int awid, input bit awvalid,
      input longint wdata, input int wstrb, input bit wlast, input bit wvalid,
      input bit bready,
      input int araddr, input int arlen, input int arid, input bit arvalid,
      input bit rready,
      output bit awready, output bit wready,
      output bit bvalid, output int bresp, output int bid,
      output bit arready,
      output bit rvalid, output longint rdata, output int rresp,
      output int rid, output bit rlast);

  // A level the processing system drives: see the C++ for which is which.
  import "DPI-C" context function int cadr_sim_level(input int which);
endpackage

module cadr_sim_gp_master #(
    parameter int PORT  = 0,
    parameter int AW    = 32,
    parameter int ID_W  = 12,
    parameter int LEN_W = 4
) (
    input  var logic             clk,
    output var logic [AW-1:0]    awaddr,
    output var logic [LEN_W-1:0] awlen,
    output var logic [ID_W-1:0]  awid,
    output var logic             awvalid,
    input  var logic             awready,
    output var logic [31:0]      wdata,
    output var logic [3:0]       wstrb,
    output var logic             wlast,
    output var logic             wvalid,
    input  var logic             wready,
    input  var logic [1:0]       bresp,
    input  var logic [ID_W-1:0]  bid,
    input  var logic             bvalid,
    output var logic             bready,
    output var logic [AW-1:0]    araddr,
    output var logic [LEN_W-1:0] arlen,
    output var logic [ID_W-1:0]  arid,
    output var logic             arvalid,
    input  var logic             arready,
    input  var logic [31:0]      rdata,
    input  var logic [1:0]       rresp,
    input  var logic [ID_W-1:0]  rid,
    input  var logic             rlast,
    input  var logic             rvalid,
    output var logic             rready
);
  import cadr_sim_axi_dpi::*;
  always_ff @(posedge clk) begin
    int o_awaddr, o_awlen, o_awid, o_wdata, o_wstrb, o_araddr, o_arlen, o_arid;
    bit o_awvalid, o_wlast, o_wvalid, o_bready, o_arvalid, o_rready;
    cadr_sim_gp(PORT, awready, wready, bvalid, int'(bresp), int'(bid),
                arready, rvalid, int'(rdata), int'(rresp), int'(rid), rlast,
                o_awaddr, o_awlen, o_awid, o_awvalid,
                o_wdata, o_wstrb, o_wlast, o_wvalid, o_bready,
                o_araddr, o_arlen, o_arid, o_arvalid, o_rready);
    awaddr  <= AW'(o_awaddr);
    awlen   <= LEN_W'(o_awlen);
    awid    <= ID_W'(o_awid);
    awvalid <= o_awvalid;
    wdata   <= o_wdata;
    wstrb   <= 4'(o_wstrb);
    wlast   <= o_wlast;
    wvalid  <= o_wvalid;
    bready  <= o_bready;
    araddr  <= AW'(o_araddr);
    arlen   <= LEN_W'(o_arlen);
    arid    <= ID_W'(o_arid);
    arvalid <= o_arvalid;
    rready  <= o_rready;
  end
endmodule

module cadr_sim_mem_slave #(
    parameter int PORT  = 0,
    parameter int ID_W  = 1,
    parameter int LEN_W = 4
) (
    input  var logic             clk,
    input  var logic             rst,
    input  var logic [31:0]      awaddr,
    input  var logic [LEN_W-1:0] awlen,
    input  var logic [ID_W-1:0]  awid,
    input  var logic             awvalid,
    output var logic             awready,
    input  var logic [63:0]      wdata,
    input  var logic [7:0]       wstrb,
    input  var logic             wlast,
    input  var logic             wvalid,
    output var logic             wready,
    output var logic [1:0]       bresp,
    output var logic [ID_W-1:0]  bid,
    output var logic             bvalid,
    input  var logic             bready,
    input  var logic [31:0]      araddr,
    input  var logic [LEN_W-1:0] arlen,
    input  var logic [ID_W-1:0]  arid,
    input  var logic             arvalid,
    output var logic             arready,
    output var logic [63:0]      rdata,
    output var logic [1:0]       rresp,
    output var logic [ID_W-1:0]  rid,
    output var logic             rlast,
    output var logic             rvalid,
    input  var logic             rready
);
  import cadr_sim_axi_dpi::*;
  always_ff @(posedge clk) begin
    bit o_awready, o_wready, o_bvalid, o_arready, o_rvalid, o_rlast;
    int o_bresp, o_bid, o_rresp, o_rid;
    longint o_rdata;
    cadr_sim_mem(PORT, rst, int'(awaddr), int'(awlen), int'(awid), awvalid,
                 longint'(wdata), int'(wstrb), wlast, wvalid, bready,
                 int'(araddr), int'(arlen), int'(arid), arvalid, rready,
                 o_awready, o_wready, o_bvalid, o_bresp, o_bid,
                 o_arready, o_rvalid, o_rdata, o_rresp, o_rid, o_rlast);
    awready <= o_awready;
    wready  <= o_wready;
    bvalid  <= o_bvalid;
    bresp   <= 2'(o_bresp);
    bid     <= ID_W'(o_bid);
    arready <= o_arready;
    rvalid  <= o_rvalid;
    rdata   <= o_rdata;
    rresp   <= 2'(o_rresp);
    rid     <= ID_W'(o_rid);
    rlast   <= o_rlast;
  end
endmodule

`default_nettype wire
