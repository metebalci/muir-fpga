// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_prove` with the path it actually drives underneath it.
//
// The witness is three modules on the board --- the state machine, the AXI
// adapter, the widening --- and the question step two asks is not whether the
// state machine sequences correctly but whether a word ends up at an address.
// That question has three modules in it, so the check has three modules in
// it: this wires them exactly as `rtl/cadr_arty.sv`'s `g_ddr` does and brings
// out the 64-bit AXI3 port `cadr_ps7.sv` would be on the far end of.
//
// IT IS IN `tb/` FOR THE REASON `tb/cadr_arty_stubs.sv` GIVES.  Both Vivado
// scripts read `[glob rtl/*.sv]`, so a wiring harness in `rtl/` would join
// the bitstream --- a second copy of the memory path, in the synthesised
// design, that nothing on the board would ever reach.  `tb/` is globbed by
// nothing.
//
// AND IT IS A HARNESS AND NOT THE THING CHECKED.  The mutations are aimed at
// `rtl/cadr_prove.sv`; this file is in the runner's `extra` beside the
// adapter and the widening, which have checks of their own.  What it can
// still get wrong is a crossing in its own wiring --- and the top level can
// get the same one, which is what `build/arty.pass`'s `DDR=1` lint pass and
// `mutations/list.txt`'s `the-beat-that-came-back-is-the-one-that-went-out`
// are for.

`default_nettype none

module cadr_prove_harness #(
    parameter int unsigned SETUP_T = 16
) (
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        go,

    // What the witness is asked to do. Inputs here for the reason
    // `rtl/cadr_prove.sv`'s header gives: one model, both steps, and an
    // address the check can sweep.
    input  var logic [31:0] addr,
    input  var logic [31:0] word,
    input  var logic        writes,

    // The verdict.
    output var logic        has_run,
    output var logic        matched,

    // The machine's port, brought out so the testbench can hold the witness
    // to the 80 ns the bus specification puts on a master.  Nothing drives
    // these from outside: they are the state machine's own outputs.
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,

    // The port's side: AXI3, 64 bits, one beat.  `S_AXI_HP0` on the board.
    output var logic [31:0] hp0_awaddr,
    output var logic [3:0]  hp0_awlen,
    output var logic [1:0]  hp0_awsize,
    output var logic [1:0]  hp0_awburst,
    output var logic        hp0_awvalid,
    input  var logic        hp0_awready,
    output var logic [63:0] hp0_wdata,
    output var logic [7:0]  hp0_wstrb,
    output var logic        hp0_wlast,
    output var logic        hp0_wvalid,
    input  var logic        hp0_wready,
    input  var logic [1:0]  hp0_bresp,
    input  var logic        hp0_bvalid,
    output var logic        hp0_bready,
    output var logic [31:0] hp0_araddr,
    output var logic [3:0]  hp0_arlen,
    output var logic [1:0]  hp0_arsize,
    output var logic [1:0]  hp0_arburst,
    output var logic        hp0_arvalid,
    input  var logic        hp0_arready,
    input  var logic [63:0] hp0_rdata,
    input  var logic [1:0]  hp0_rresp,
    input  var logic        hp0_rlast,
    input  var logic        hp0_rvalid,
    output var logic        hp0_rready
);

  logic        mem_done, mem_error;
  logic [31:0] mem_rdata;

  cadr_prove #(
      .SETUP_T(SETUP_T)
  ) u_prove (
      .clk(clk), .rst(rst), .go(go),
      .addr(addr), .word(word), .writes(writes),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(mem_error),
      .has_run(has_run), .matched(matched)
  );

  // The adapter's AXI4 side, 32 bits wide.
  logic [31:0] awaddr, araddr, wdata, rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [3:0]  wstrb;

  cadr_axi_master u_axi (
      .clk(clk), .rst(rst),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(mem_error),
      .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(hp0_awburst), .m_axi_awvalid(hp0_awvalid),
      .m_axi_awready(hp0_awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(hp0_wlast),
      .m_axi_wvalid(hp0_wvalid), .m_axi_wready(hp0_wready),
      .m_axi_bresp(hp0_bresp), .m_axi_bvalid(hp0_bvalid),
      .m_axi_bready(hp0_bready),
      .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
      .m_axi_arburst(hp0_arburst), .m_axi_arvalid(hp0_arvalid),
      .m_axi_arready(hp0_arready),
      .m_axi_rdata(rdata), .m_axi_rresp(hp0_rresp), .m_axi_rlast(hp0_rlast),
      .m_axi_rvalid(hp0_rvalid), .m_axi_rready(hp0_rready)
  );

  cadr_axi_widen u_widen (
      .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
      .s_wdata(wdata), .s_wstrb(wstrb),
      .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
      .s_rdata(rdata),
      .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize),
      .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb),
      .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize),
      .m_rdata(hp0_rdata)
  );

endmodule

`default_nettype wire
