// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT'S INSTANTS ON THE FABRIC'S GRID, IN ONE PLACE.
//
// Every instant in this machine is a count of ticks, and this package is the
// one constant every one of those counts derives from.  `TICK_NS` is the
// conversion from MIT's drawings into ticks; `ticks(ns)` performs it.
//
// **`TICK_NS` IS NOT THE LENGTH OF A TICK.**  How long a tick lasts is the
// board's business: `boards/arty-z7-20/cadr_arty.sv` makes it 10 ns.  The
// grid is 10 ns too, so a microcycle the fabric counts in ticks takes that
// many tens of real nanoseconds, and the two tens are still two numbers ---
// one a divisor here and one a clock period there --- which is why a board
// can change its tick without touching this file.
//
// The reason this is a package and not a literal in each file is that the
// grid must be able to move as one constant, and for a while it could not:
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
// MIT's drawings place most edges on multiples of five nanoseconds, so at
// this grid eleven instants move up and none moves earlier: eight of the
// ring's by five nanoseconds --- TSE's two edges, SELECT, the end of the
// control store's write pulse, and the fast and normal read taps with and
// without ILONG --- and three of the I/O board's by seven, the counter's low
// half, the receive buffer's setup and the half-microsecond clock's first
// edge.  `docs/timing.md` lists every one with its count at both grids.
// muir's `--timing-model fpga` rounds the same way, each delay from its own
// trigger, and is what the references are generated under.
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
// that does not divide it.  There are five: the bus interface's timeout
// oscillator (`cadr_busint_xbus.sv`, `VCO_HALF_NS`, 43 then 42 ticks), the
// I/O board's FCLK (`cadr_io_board.sv`, `FCLK_NS`, 13 then 12) and
// sixty-cycle clock (`mains_acc`), the display's sync program
// (`cadr_tv.sv`, `seq_ns`, 63 then 62 in its slow clock modes) and the
// serial line's crystal (`cadr_serial_line.sv`, `XTAL_WRAP`).  The disk
// controller counts its spans down in nanoseconds the same way.  An
// oscillator whose period the grid divides --- the microsecond clock and its
// half, the keyboard's --- is a plain tick counter, being the same thing.
//
// So a constant that is a delay from an event belongs here.  A constant that
// is an oscillator's period belongs in nanoseconds beside an accumulator
// that adds `TICK_NS`.  And a constant that is neither --- the debug
// carrier's beat, the console's watchdog, the reset pulses --- is a fabric
// choice measured in BOARD ticks and is not MIT's timing at all; those name
// no nanosecond figure and must not be given one.
//
// This number has homes in four languages, and `tools/grid_check.py` fails
// the check when they disagree, when a generator runs muir under any model
// but the fabric's, or when a timing constraint's tick count is not the
// grid's count of the instant its tag names.

`default_nettype none

package cadr_tick_pkg;

  // MIT's instants, placed on a grid of this many nanoseconds.  See the header
  // before changing it --- this is a divisor into the drawings and not the
  // board's clock period.
  localparam int unsigned TICK_NS = 10;

  // Nanoseconds to ticks, rounded UP.  The fabric can only act on a clock
  // edge, so an instant that falls between two of them is taken at the first
  // edge at or after it --- never the one before, which would have the fabric
  // sampling something the real machine had not yet settled.
  function automatic int unsigned ticks(input int unsigned ns);
    return (ns + TICK_NS - 1) / TICK_NS;
  endfunction

  // **POWER-ON, IN EDGES AFTER THE RESET EDGE, FOR EVERY OSCILLATOR IN THE
  // MACHINE.**  muir's t = 0 is where the ring starts, and every free-running
  // clock's phase is counted from there.  In the fabric the ring starts on
  // the first edge reset is low, and the processor and the bus interface act
  // on the ring's boundary one edge after it makes it, so the instants every
  // trace compares --- a microcycle's end, a grant, an acknowledgment --- are
  // counted from two edges after the reset edge.  An oscillator that starts
  // at the reset edge runs two ticks ahead of muir in the composed machine,
  // whatever it agrees with alone: the bus interface's timeout oscillator was
  // issue #21, and the I/O board's clocks and the display's sync program were
  // measured the same way afterwards, every one of them 20 ns early at the
  // 10 ns grid.  `cadr_busint_xbus.sv`, `cadr_io_board.sv` and `cadr_tv.sv`
  // start theirs this many edges after the reset edge, a standalone check
  // puts the same number of edges before its row 0 (`kPowerOnEdges` in
  // `tb/cadr_tick.h`), and `power_on.pass` holds the composed machine's
  // clocks to muir's instants from the processor's own first microcycles.
  // It counts the fabric's edges and not an instant on MIT's drawings, so it
  // is not on the grid.  Waived for lint here and nowhere else: every design
  // compiles this package, three modules take this constant, and a design
  // without them is not wrong to leave it unread.
  /* verilator lint_off UNUSEDPARAM */
  localparam int unsigned POWER_ON_EDGES = 2;
  /* verilator lint_on UNUSEDPARAM */

endpackage

`default_nettype wire
