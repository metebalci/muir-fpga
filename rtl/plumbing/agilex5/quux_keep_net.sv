// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A net a timing constraint names, passed through unchanged and kept: the
// Agilex 5 version of `rtl/plumbing/quux_keep_net.sv`, which says why.
//
// `kept` carries `keep`, and Quartus Pro 26.1 then keeps the net under its
// name, `<instance>|kept[*]`, for `boards/de25-nano/quartus/quux_de25.sdc`
// to name and `boards/de25-nano/quartus/sta_check.tcl` to count; without it
// the same nets are gone after synthesis and the clause binds nothing
// (measured on revision 14's DE25-Nano build, both ways).  `q` is `d`, as
// in the behavioral version.

`default_nettype none

module quux_keep_net #(
    parameter int unsigned W = 1
) (
    input  var logic [W-1:0] d,
    output var logic [W-1:0] q
);
  (* keep *) logic [W-1:0] kept;
  assign kept = d;
  assign q    = kept;
endmodule

`default_nettype wire
