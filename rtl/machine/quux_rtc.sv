// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's real-time clock (contract Q9, revision 9): word 103 of the register
// page, the real time in whole seconds since 1970-01-01 00:00 UTC, Unix
// time, unsigned and 32 bits.  muir's `Rtc`, and on a board the host's clock
// carried into the fabric.
//
// **THE MACHINE ONLY READS IT.**  A write of word 103 goes nowhere, as a
// write of any read-only word on the page does (`quux_feature_page.sv` never
// hands it here).  The host keeps the time: Linux writes the seconds, and the
// fraction of the second they start at, through the host side at boot and at
// least once a second after (`docs/file-device.md`).  In between the count
// runs on the fabric's own clock, a nanosecond count of the second that moves
// by the tick's real length a tick and carries into the seconds at 10^9.
//
// **THE TICK'S REAL LENGTH IS THE BOARD'S** (`TICK_PS`, picoseconds, from the
// board's top through `cadr_machine.sv`): 10 ns on every board but the Arty
// Z7-20's revision 14 build, whose tick is 15 ns.  A length that is not whole
// nanoseconds carries its picoseconds in a count of its own (`ps_q`), so the
// clock keeps wall time exactly over any run, its nanoseconds never more than
// one behind.  `build/wall_time.pass` holds it at four lengths.
//
// **IT HOLDS AT 2^32 - 1** and never wraps to 0, which would read as no
// clock at all; muir's `Rtc::seconds` saturates the same way.
//
// **A TRACE'S CLOCK IS muir'S `--rtc <s>`**: word 103 reads `s` at power-on
// and a second more for each 10^9 ns of the machine's own time, which on the
// fabric's grid is 10^8 ticks.  The testbench loads `s` through the host side
// as Linux would, so the word is exact against muir's, and the host setting
// it mid-run is muir's `Rtc::Counted` restarted at that instant.  The carry
// across a second never happens inside a trace, a second being 25 million of
// QUUX's microcycles, so `build/quux_fd_face.pass` holds it, and the hold,
// through the host side: a fraction staged a few ticks short of the second
// and the carry counted.  What holds the word as the machine reads it is
// `build/quux13_rtc.quux.k4.pass`.
//
// The host side:
//
//     we_seconds   the seconds, and with them the fraction staged by the last
//                  `we_fraction` (0 if none since), which the stage then
//                  forgets
//     we_fraction  stages a fraction, nanoseconds into the second; a value of
//                  a second or more is ignored and the stage keeps what it had
//
// Both land at the edge they are written on.
//
// **NO RESET REACHES IT.**  A machine reset --- the console's, BTN1's, a
// boot --- leaves the time alone, as a real clock keeps real time whatever
// happens to the processor, and as muir's does: a band reads word 103 while
// it boots, and a clock just reset would read 1970 for up to a second before
// Linux set it again.  It comes up at 0 with the fabric's configuration, and
// Linux sets it within a second.

`default_nettype none

module quux_rtc #(
    // A tick's real length in picoseconds, the board's: the grid's 10 ns by
    // default.
    parameter int unsigned TICK_PS = cadr_tick_pkg::TICK_NS * 1000
) (
    input  var logic        clk,

    input  var logic        we_seconds,
    input  var logic        we_fraction,
    input  var logic [31:0] wdata,

    output var logic [31:0] seconds,
    output var logic [29:0] fraction
);

  // The count, from the fabric's configuration on.
  logic [31:0] sec_q  = 32'd0;
  logic [29:0] frac_q = 30'd0;
  assign seconds  = sec_q;
  assign fraction = frac_q;

  localparam logic [29:0] SECOND  = 30'd1_000_000_000;
  // The whole nanoseconds of a tick, and the picoseconds over them.
  localparam logic [29:0] STEP    = 30'(TICK_PS / 1000);
  localparam logic [9:0]  STEP_PS = 10'(TICK_PS % 1000);

  logic [29:0] stage = 30'd0;
  logic [9:0]  ps_q  = 10'd0;
  logic [9:0]  next_ps;
  logic        ps_carry;
  logic [29:0] next_fraction;
  logic        carry;

  assign next_ps       = ps_q + STEP_PS;
  assign ps_carry      = next_ps >= 10'd1000;
  assign next_fraction = frac_q + STEP + 30'(ps_carry);
  assign carry         = next_fraction >= SECOND;

  always_ff @(posedge clk) begin
    if (we_seconds) begin
      sec_q  <= wdata;
      frac_q <= stage;
      stage  <= 30'd0;
      ps_q   <= 10'd0;
    end else begin
      ps_q   <= ps_carry ? next_ps - 10'd1000 : next_ps;
      if (we_fraction && wdata < 32'd1_000_000_000) stage <= wdata[29:0];
      frac_q <= carry ? next_fraction - SECOND : next_fraction;
      if (carry && sec_q != 32'hFFFF_FFFF) sec_q <= sec_q + 32'd1;
    end
  end

endmodule

`default_nettype wire
