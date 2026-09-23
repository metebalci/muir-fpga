// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fault bitstream's one lamp signal: on for a quarter of a second, off
// for a quarter, two flashes a second, for as long as the part is configured.
//
// **ONE REGISTER DRIVES EVERY LAMP OF THE BOARD**, so the lamps are in phase
// by construction and not by agreement between counters.  Each board's fault
// top level (`boards/*/cadr_*_fault.sv`) fans this one bit out to its pins
// with the board's own polarity and, on a color lamp, to the red pin alone.
// `tb/cadr_fault_tb.cpp` watches every lamp pin and requires that each one
// toggles, that all of them toggle on the same tick, and that no green or
// blue pin is ever lit.
//
// **NO RESET, AS THE MACHINE'S HEARTBEAT HAS NONE.**  A fault image is loaded
// because something is wrong, and a lamp that could be held dark by a reset
// would be one more thing that can be wrong.  The register powers up at
// zero, which is the part's configured value on both vendors here.
//
// `HALF_T` is the half period in clock cycles.  At the 100 MHz both flows
// give the fabric, 25,000,000 is 250 ms; the check builds it shorter so that
// a run sees many edges.

`default_nettype none

module cadr_fault_lamp #(
    parameter int unsigned HALF_T = 25_000_000
) (
    input  var logic clk,
    output var logic lit
);

  localparam int unsigned W = $clog2(HALF_T);

  logic [W-1:0] count = '0;
  logic         on = 1'b0;

  always_ff @(posedge clk) begin
    if (count == W'(HALF_T - 1)) begin
      count <= '0;
      on    <= !on;
    end else begin
      count <= count + W'(1);
    end
  end

  assign lit = on;

endmodule

`default_nettype wire
