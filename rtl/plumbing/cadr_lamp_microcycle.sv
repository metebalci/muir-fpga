// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The microcycle lamp: LD2 on the Arty Z7-20, LD1's green on the Cora Z7-07S.
// It says the machine is retiring microcycles, and it says it one of two ways.
//
// **BLINKING, WHICH IS THE DEFAULT.**  Bit 19 of a count of retired
// microcycles, 524,288 of them a half-period: about 89 ms on the 10 ns grid,
// where the Arty Z7-20 retired 5.88 million microcycles a second running Lisp
// at d4cf2ca --- fast enough to be obviously alive and slow enough to count.
// It FREEZES when the machine stops, lit or dark, which is the thing a level
// cannot say --- motion cannot be faked, where a frozen fabric would still
// hold a level high.
//
// **STEADY, WHICH IS `--no-blinking-leds`.**  Lit for `HOLD_T` ticks after
// every retired microcycle, re-armed by each one.  So the lamp is solid while
// the machine runs and goes dark a moment after it stops.  A blink is bright
// and moving, and a board left running on a desk overnight is a board somebody
// wants to be able to stop looking at; a level answers the same question ---
// is it executing --- and a level that goes OUT when the machine stops still
// cannot be held up by a frozen fabric, because the hold counts down.
//
// **WHY `HOLD_T` IS 2^22 TICKS**, 41.9 ms at the 10 ns tick.  It is a fabric
// choice in board ticks, real time, and it names nothing on MIT's drawings, so
// it is not on the grid.  It has to sit between two numbers.  Below it is the
// longest gap between two microcycles of a machine that is running: a bus
// cycle nothing answers ends on the NXM timer within about 550 ticks of its
// grant at the 10 ns grid, and the debug cable's longer deadline is 1,105
// ticks after the oscillator's first rise, so even the slowest stall is about
// ten microseconds.  Above it is how long a person takes to see a lamp go
// out, which is on the order of a tenth of a second.  2^22 is over three
// thousand times the first and under half the second, so a running machine
// never flickers the lamp and a stopped one reads as stopped at once.  It is
// also `DISK_LIT_T` in `boards/arty-z7-20/cadr_arty.sv`, the disk lamp's own
// persistence one lamp along, so the two lamps a person reads as activity
// hold for the same time.
// At a 5 ns tick it would be 21 ms, which is still between the two.
//
// **THE HOLD COUNTS IN BOTH MODES, AND THE BEAT IN BOTH.**  The setting chooses
// which of the two reaches the pin and nothing else, so switching the mode at
// run time shows the right state on the next tick rather than after the next
// microcycle: a machine that stopped a moment ago is still lit for the rest of
// its hold, and one that stopped long ago is dark.
//
// **WHY IT IS A MODULE AND NOT A FEW LINES IN THE TOP LEVEL.**  The top level
// is reached by lint and by nothing else, and lint cannot tell a hold that is
// re-armed from one that is not, or a lamp that blinks from one that is lit.
// `build/blink_lamps.pass` can.  What stays lint-only is the WIRING: which
// signal reaches `retired` and which pin `lit` drives, and the two board files
// say so where they instantiate this.

`default_nettype none

module cadr_lamp_microcycle #(
    // The bit of the count that blinks, and how long a retired microcycle
    // keeps the steady lamp lit.  The header has the argument for both.
    parameter int unsigned BLINK_BIT = 19,
    parameter int unsigned HOLD_T    = 1 << 22    // 41.9 ms at the 10 ns tick
) (
    input  var logic clk,      // 100 MHz, one tick = 10 ns
    input  var logic rst,      // the machine's reset: a machine held there retires nothing

    // The console's setting: 0 blinks, 1 holds a level.  A level, held by the
    // console until it is told otherwise.
    input  var logic steady,

    // One tick for each microcycle the machine retires: `clock_edge` out of
    // `cadr_machine`, the processor's own boundary.
    input  var logic retired,

    // The lamp.  High lights it.
    output var logic lit
);

  localparam int unsigned HOLD_W = $clog2(HOLD_T);

  logic [BLINK_BIT:0] beat;
  logic [HOLD_W-1:0]  hold_t;
  logic               held;

  always_ff @(posedge clk) begin
    if (rst) begin
      beat   <= '0;
      held   <= 1'b0;
      hold_t <= '0;
    end else begin
      // The disk lamp's shape: a flag and a countdown beside it, so that the
      // lamp is a flip flop and the counter needs no bit for `HOLD_T` itself.
      // Armed at a retirement, the flag stays up for `HOLD_T` ticks and falls
      // on the tick after the countdown reaches zero.
      if (hold_t != '0) hold_t <= hold_t - 1'b1;
      else held <= 1'b0;
      if (retired) begin
        held   <= 1'b1;
        hold_t <= HOLD_W'(HOLD_T - 1);
      end
      // The blink's count, beside the hold and not inside it: both are
      // counted whichever of them the setting shows.
      if (retired) beat <= beat + 1'b1;
    end
  end

  assign lit = steady ? held : beat[BLINK_BIT];

endmodule

`default_nettype wire
