// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **A SIMPLE DUAL-PORT RAM OF REVISION 15'S CORE**: one write and one
// synchronous read a clock, the read's word registered, each enabled.  The A
// memory, the PDL buffer and the control store are each one
// (`quux15_core.sv`, `quux15_store.sv`).
//
// **A READ AND A WRITE OF ONE ADDRESS IN ONE CLOCK** read the old word, as
// QUUX defines it (A15b.3, "A RAM read in its own write's cycle").  The core
// never uses that word: a forward replaces it wherever the row says the read
// takes the new one (d3 for A, the PDL buffer's forward), and it is the old
// word wherever the row says so.  Under `QUUX15_RDW_POISON` the read takes
// the old word's complement instead, so that a design that came to rely on
// the RAM's own result in that clock fails its golden.  The poison is a
// simulation's; nothing is built with it.
//
// `INIT_WORD` is every word at power-on: an FPGA's RAM comes up as its
// bitstream says, and the core's convention is muir's machine's.

`default_nettype none

module quux15_ram #(
    parameter int unsigned WIDTH = 40,
    parameter int unsigned DEPTH = 1024,
    parameter logic [WIDTH-1:0] INIT_WORD = '0
) (
    input  var logic                     clk,
    input  var logic                     re,
    input  var logic [$clog2(DEPTH)-1:0] raddr,
    output var logic [WIDTH-1:0]         rdata,
    input  var logic                     we,
    input  var logic [$clog2(DEPTH)-1:0] waddr,
    input  var logic [WIDTH-1:0]         wdata
);

  logic [WIDTH-1:0] mem[DEPTH] /* verilator public_flat_rw */;

  initial begin
    for (int unsigned k = 0; k < DEPTH; k++) mem[k] = INIT_WORD;
  end

  // In the vendor's template's form (Vivado's simple dual port): the write
  // and the read each in a process of their own, so that the board's flow
  // can take the RAM into UltraRAM (`RAM_STYLE`) as well as block RAM.
  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
  end
  always_ff @(posedge clk) begin
    if (re) begin
`ifdef QUUX15_RDW_POISON
      rdata <= (we && waddr == raddr) ? ~mem[raddr] : mem[raddr];
`else
      rdata <= mem[raddr];
`endif
    end
  end

endmodule

`default_nettype wire
