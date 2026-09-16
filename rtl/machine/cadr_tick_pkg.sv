// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT'S GRID, IN ONE PLACE.
//
// Every instant in this machine is a count of ticks, and this package is the
// one constant every one of those counts derives from.  `TICK_NS` is the
// conversion from MIT's drawings into ticks; `ticks(ns)` performs it.
//
// **`TICK_NS` IS NOT THE LENGTH OF A TICK.**  How long a tick lasts is the
// board's business: `boards/arty-z7-20/cadr_arty.sv` makes it 10 ns, so the
// machine runs at half the speed the hardware ran at and nothing inside it
// can tell, because every instant keeps its exact ratio to every other.  The
// two tens are unrelated numbers that happen to match --- one is a divisor
// here and one is a clock period there.
//
// The reason this is a package and not a literal in each file is that the
// two must be able to move independently, and for a while they could not:
// the grid was written out as `/ 5` in module after module and in twenty-one
// testbenches, so an experiment that changed one file produced a processor
// at one speed against a bus at another, which is a machine MIT never built.
//
// ROUNDING IS UP, ALWAYS.  `ticks()` is `(ns + TICK_NS - 1) / TICK_NS` and
// never a plain division, which truncates: at a 10 ns grid a plain division
// collapses MIT's 5 ns instant to zero ticks and puts SELECT on top of a
// read tap.  Rounding down also makes the fabric sample EARLIER than the
// real machine did, which is the wrong direction for a setup time, a deskew
// or a strobe --- every one of them is a promise that something has settled.
// Three instants on the I/O board already do not divide by five and are
// already rounded up here rather than approximated in place: 313, 203 and
// 33 nanoseconds.
//
// ---------------------------------------------------------------------------
// WHICH CONSTANTS BELONG HERE, AND WHICH DO NOT
// ---------------------------------------------------------------------------
//
// There are three kinds of timing instant in this machine, and the kind
// decides whether it goes on the grid.  The rule is that **anything
// TRIGGERED goes on the grid and anything FREE-RUNNING keeps its true
// period**.
//
//   1. THE RING.  One phase counter in `cadr_phase_gen.sv`, which is MIT's
//      delay line started by `-TPR0`.  Every microcycle instant is a
//      comparison against it: `TPCLK`, `TPTSE`, `-TPR60`, SELECT, `-TPW30`,
//      `-TPW45`, `-TPDONE` and the seven read taps.  ON THE GRID.
//
//   2. TRIGGERED DELAYS.  Not off the ring, but started by an event and
//      fixed relative to it: the bus's 80 ns of setup before the request,
//      the 60 ns read deskew, the Unibus select, address, acknowledgment
//      and strobe, the register block's own strobe and answer.  ON THE GRID,
//      for the same reason --- the machine reads them at named instants and
//      the traces compare them tick for tick.
//
//   3. FREE-RUNNING OSCILLATORS.  Started by nothing and running since power
//      came up, so what matters is the PHASE they are at when something asks,
//      not their spacing from any event.  Rounding one makes it drift, and a
//      drifting phase moves every answer that is synchronized to it.  These
//      are deliberately NOT on the grid.
//
// **EVERY OSCILLATOR IN THE MACHINE KEEPS ITS PERIOD IN NANOSECONDS AND
// ADVANCES BY `TICK_NS` EACH TICK**, wrapping by SUBTRACTING the period and
// never by clearing.  Clearing discards the remainder, and carrying the
// remainder is the whole of what makes the average period exact at a grid
// that does not divide it.  There are four: the bus interface's timeout
// oscillator (`cadr_busint_xbus.sv`, `VCO_HALF_NS`), the I/O board's FCLK
// (`cadr_io_board.sv`, `FCLK_NS`) and sixty-cycle clock (`mains_acc`), and
// the serial line's crystal (`cadr_serial_line.sv`, `XTAL_WRAP`).  The disk
// controller counts its spans down in nanoseconds the same way.
//
// At the 5 ns grid the machine runs at, every one of those remainders is
// zero and each oscillator's period is a whole number of ticks, so the form
// degenerates to the tick counters it replaced.  That degeneration is what
// makes it checkable: the traces do not move.  See `docs/timing.md`.
//
// So a constant that is a delay from an event belongs here.  A constant that
// is an oscillator's period belongs in nanoseconds beside an accumulator
// that adds `TICK_NS`.  And a constant that is neither --- the debug
// carrier's beat, the console's watchdog, the reset pulses --- is a fabric
// choice measured in BOARD ticks and is not MIT's timing at all; those name
// no nanosecond figure and must not be given one.
//
// This number has homes in three languages, and `tools/grid_check.py` fails
// the check when they disagree.  Timing constraints that write a tick count
// out as a literal are NOT held by it; `docs/timing.md` lists them.

`default_nettype none

package cadr_tick_pkg;

  // MIT's grid: the drawings place every edge on a multiple of five
  // nanoseconds.  See the header before changing it --- this is a divisor
  // into the drawings and not the board's clock period.
  localparam int unsigned TICK_NS = 5;

  // Nanoseconds to ticks, rounded UP.  The fabric can only act on a clock
  // edge, so an instant that falls between two of them is taken at the first
  // edge at or after it --- never the one before, which would have the fabric
  // sampling something the real machine had not yet settled.
  function automatic int unsigned ticks(input int unsigned ns);
    return (ns + TICK_NS - 1) / TICK_NS;
  endfunction

endpackage

`default_nettype wire
