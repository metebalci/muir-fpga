// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE MACRO DISPATCH MEMORY** (A15.2, A15b.9, A15b.16; muir's
// `MacroDispatch`): 1,024 entries of 18 bits, written by EX's destination 7
// at the clock's end and read combinationally at five addresses, one port
// each: RD's plan from the copies as the clock began (`rd`), RD's plan from
// the copies EX restores (`rx`), EX's fused return (`ex`, its three calls
// at one address), D's decision (`d`), and the console's readout (`ro`, its
// address registered in the core).
//
// This is the behavioral implementation, one array read five times, which
// Vivado builds in LUT RAM.  `rtl/plumbing/agilex5/quux15_mdmem.sv` is the
// Agilex 5 one, a copy in MLAB for each read, all written together, since
// Quartus builds a read whose address and word are both unregistered in
// flip-flops (`uninferred due to asynchronous read logic`).
//
// **A READ OF THE ADDRESS WRITTEN IN THE SAME CLOCK** gives the old entry
// here, and under `QUUX15_RDW_POISON` its complement, so that a core that
// came to rely on it fails its golden: at `wmay`, a word trying EX that
// names destination 7, a superset of `we` that does not depend on the
// entries read.
//
// **A READ OF THE ADDRESS WRITTEN AT THE CLOCK'S START GIVES THE NEW ENTRY,
// AND THE CORE USES IT**: a fused return or D right after destination 7
// writes the entry it takes (the `mainloop` group's `entry-written` runs).
// `QUUX15_MD_POISON_NEXT` poisons that read too, and those runs fail under
// it; it measures, and is no check.  An implementation whose write lands
// after the clock's edge (an MLAB) must deliver the new entry in that clock.

`default_nettype none

module quux15_mdmem (
    input  var logic        clk,
    input  var logic        we,
    input  var logic [9:0]  waddr,
    input  var logic [17:0] wdata,
    // Only the simulation's poison reads it: a write may be made at `waddr`
    // this clock, known before `we` is.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic        wmay,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [9:0]  rd_a,
    output var logic [17:0] rd_e,
    input  var logic [9:0]  rx_a,
    output var logic [17:0] rx_e,
    input  var logic [9:0]  ex_a,
    output var logic [17:0] ex_e,
    input  var logic [9:0]  d_a,
    output var logic [17:0] d_e,
    input  var logic [9:0]  ro_a,
    output var logic [17:0] ro_e
);
  logic [17:0] mem[1024] /* verilator public_flat_rw */;

  initial begin
    for (int k = 0; k < 1024; k++) mem[k] = 18'd0;
  end

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
  end

`ifdef QUUX15_MD_POISON_NEXT
  logic       we_q = 1'b0;
  logic [9:0] waddr_q;
  always_ff @(posedge clk) begin
    we_q    <= we;
    waddr_q <= waddr;
  end
`endif

  // Each read a plain `assign` of the array, as Vivado's distributed RAM
  // template has it: written as calls of one function, Vivado 2026.1 built
  // one read port's worth of LUT RAM for all five (the boards' flows count
  // them, `tools/quux15_lutram_ports.tcl`).  The poisons are the simulation's.
  logic [17:0] rd_w, rx_w, ex_w, d_w, ro_w;
  assign rd_w = mem[rd_a];
  assign rx_w = mem[rx_a];
  assign ex_w = mem[ex_a];
  assign d_w  = mem[d_a];
  assign ro_w = mem[ro_a];
`ifdef QUUX15_RDW_POISON
  function automatic logic hit(input logic [9:0] a);
    logic p;
    p = wmay && waddr == a;
`ifdef QUUX15_MD_POISON_NEXT
    if (we_q && waddr_q == a) p = 1'b1;
`endif
    return p;
  endfunction
  assign rd_e = hit(rd_a) ? ~rd_w : rd_w;
  assign rx_e = hit(rx_a) ? ~rx_w : rx_w;
  assign ex_e = hit(ex_a) ? ~ex_w : ex_w;
  assign d_e  = hit(d_a)  ? ~d_w  : d_w;
  assign ro_e = hit(ro_a) ? ~ro_w : ro_w;
`else
  assign rd_e = rd_w;
  assign rx_e = rx_w;
  assign ex_e = ex_w;
  assign d_e  = d_w;
  assign ro_e = ro_w;
`endif
endmodule

`default_nettype wire
