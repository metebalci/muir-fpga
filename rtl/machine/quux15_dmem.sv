// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **DISPATCH MEMORY** (the CADR's D-MEM, 4,096 entries of 17 bits;
// `quux15_core.sv`'s DISPATCH words): written by a dispatch-memory write in
// EX at the clock's end, and read combinationally at two addresses, one
// port each: EX's dispatch (`ex`) and the console's readout (`ro`, its
// address registered in the core).
//
// **IN TWO HALVES**, its even entries and its odd: both read at the
// address's `<11:1>`, and `<0>`, which a map-bit dispatch takes from port
// B's lookup, picks between their words last.
//
// This is the behavioral implementation, which Vivado builds in LUT RAM.
// `rtl/plumbing/agilex5/quux15_dmem.sv` is the Agilex 5 one.
//
// **A READ OF THE ADDRESS WRITTEN AT THE CLOCK'S START GIVES THE NEW ENTRY,
// AND THE CORE USES IT**: the boot PROM's words 3 and 4 write an entry and
// dispatch through it in the next microcycle (a poison of that read fails
// 20 of the core's 59 goldens' passes).  An implementation whose write lands after the
// clock's edge (an MLAB) must deliver the new entry in that clock.

`default_nettype none

module quux15_dmem (
    input  var logic        clk,
    input  var logic        we,
    input  var logic [11:0] waddr,
    input  var logic [16:0] wdata,
    input  var logic [11:0] ex_a,
    output var logic [16:0] ex_e,
    input  var logic [11:0] ro_a,
    output var logic [16:0] ro_e
);
  logic [16:0] even[2048] /* verilator public_flat_rw */;
  logic [16:0] odd[2048] /* verilator public_flat_rw */;

  initial begin
    for (int k = 0; k < 2048; k++) begin
      even[k] = 17'd0;
      odd[k]  = 17'd0;
    end
  end

  always_ff @(posedge clk) begin
    if (we && !waddr[0]) even[waddr[11:1]] <= wdata;
    if (we && waddr[0]) odd[waddr[11:1]] <= wdata;
  end

  // Each read a plain `assign` of the halves (`quux15_mdmem.sv` says why).
  assign ex_e = ex_a[0] ? odd[ex_a[11:1]] : even[ex_a[11:1]];
  assign ro_e = ro_a[0] ? odd[ro_a[11:1]] : even[ro_a[11:1]];
endmodule

`default_nettype wire
