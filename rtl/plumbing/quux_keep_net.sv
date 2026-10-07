// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A net a timing constraint names, passed through unchanged.
//
// **THE BEHAVIORAL ONE, FOR EVERY FLOW BUT QUARTUS.**  `q` is `d`.  The
// testbenches, Verilator's lint and Vivado read this file; Vivado keeps the
// hierarchical pins of the module that drives the net, and its constraints
// name those (`rtl/plumbing/xilinx7/quux14_machine.xdc`).  Quartus Pro
// flattens a hierarchical net into the logic around it, so a clause written
// `-through` such a net binds nothing there; its flow reads
// `rtl/plumbing/agilex5/quux_keep_net.sv` instead, the same module with the
// net kept, and `boards/de25-nano/quartus/quux_de25.sdc` names that net.
//
// Used by `rtl/machine/quux_mmu.sv` for the side seam's look and address,
// the one-tick paths that share their sources and their RAMs with the
// processor's own look, timed at the microcycle, so that only a clause
// through these nets can tell them apart.

`default_nettype none

module quux_keep_net #(
    parameter int unsigned W = 1
) (
    input  var logic [W-1:0] d,
    output var logic [W-1:0] q
);
  assign q = d;
endmodule

`default_nettype wire
