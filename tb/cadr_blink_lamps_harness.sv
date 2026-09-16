// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The two lamps `--no-blinking-leds` changes, side by side, and nothing else:
// `rtl/plumbing/cadr_lamp_clock.sv` and `rtl/plumbing/cadr_lamp_microcycle.sv`
// at their own default parameters, which are the parameters the boards build
// them with.  One setting reaches both, as the console's one word does on the
// board.  `tb/cadr_blink_lamps_tb.cpp` is the check.

`default_nettype none

module cadr_blink_lamps_harness (
    input  var logic clk,
    input  var logic rst,
    input  var logic steady,
    input  var logic locked,
    input  var logic tick_blink,
    input  var logic retired,
    output var logic clock_lit,
    output var logic cycle_lit
);

  cadr_lamp_clock u_clock (
      .steady(steady), .locked(locked), .blink(tick_blink), .lit(clock_lit)
  );

  cadr_lamp_microcycle u_cycle (
      .clk(clk), .rst(rst), .steady(steady), .retired(retired), .lit(cycle_lit)
  );

endmodule

`default_nettype wire
