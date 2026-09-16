// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The clock lamp: LD1 on the Arty Z7-20.  It says the fabric is clocked, and
// it says nothing about the machine.
//
// **BLINKING, WHICH IS THE DEFAULT.**  The top bit of a counter of fabric
// ticks, `tick[25]` in the board file, about 1.5 Hz at 100 MHz.  A blink is
// honest about a clock by construction: a counter that stops counting stops
// blinking, lit or dark.
//
// **STEADY, WHICH IS `--no-blinking-leds`, AND IT IS THE CLOCK GENERATOR'S
// LOCK.**  Not the clock and not anything counted off it.  Logic clocked by a
// clock that has stopped cannot turn its own lamp off --- the last value it
// registered stays on the pin for ever --- and a clock routed to a pad freezes
// at whichever level it stopped at, so neither is a level that goes out when
// the clock goes.  The MMCM's `LOCKED` output is made by the clock generator
// itself and drops when it has no clock to lock to.  So the steady lamp is lit
// while the fabric has a clock and dark while it has none, and it is the same
// signal the fabric's own reset is held on.
//
// **WHICH IS WHY THIS MODULE HAS NO CLOCK.**  A register here would be exactly
// the lamp that cannot go out, so the lock reaches the pin through a gate and
// nothing else.  The setting that chooses between the two is the console's
// register and it does stand still when the clock does --- but standing still
// is what a setting should do, and in the steady mode what reaches the pin is
// the lock, which does not stand still.
//
// **WHY IT IS A MODULE AND NOT ONE LINE IN THE TOP LEVEL.**  The top level is
// reached by lint and by nothing else, and lint cannot tell a lamp that
// follows the lock from one that samples it.  `build/blink_lamps.pass` can,
// by dropping the lock with no clock edge at all.  Which signals reach the
// inputs stays lint-only, and `boards/arty-z7-20/cadr_arty.sv` says so where
// it instantiates this.

`default_nettype none

module cadr_lamp_clock (
    // The console's setting: 0 blinks, 1 holds a level.
    input  var logic steady,

    // The clock generator's lock.  Asynchronous to everything, which is fine:
    // a lamp samples nothing.
    input  var logic locked,

    // The blink: a bit of a counter of fabric ticks.
    input  var logic blink,

    // The lamp.  High lights it.
    output var logic lit
);

  assign lit = steady ? locked : blink;

endmodule

`default_nettype wire
