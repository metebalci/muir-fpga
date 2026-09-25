<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The machine's timing contract

Every instant in this machine is a count of ticks. This document says what
each of those counts is, where the number came from, and — the part that
exists nowhere else — **what else has to move when one of them moves.**

The reason it exists is that a tick count is easy to change and hard to
change safely. An instant is rarely alone: the microcycle's length is derived
from the read tap, the write pulse is measured from the end of the read
phase, and the bus's setup time is quoted in a timing constraint in another
file. Rounding one number in isolation gives a machine that still builds,
still lights the lamps, and is not the CADR.

## Overview

This section is the short version. The sections after it give every instant
with its source, its constant and its count on both grids.

### What is MIT's

MIT's drawings give every instant in nanoseconds, and muir carries each one
as a named constant.

| Group | Instants |
|---|---|
| The ring, a delay line started by `-TPR0` | TSE at 5 and 25 ns; `-TPR60` from 60 to 100 ns; SELECT at 65 ns; the write pulse from 30 to 45 ns; the restart at 60 ns; the read tap at 75 (fast), 85 (normal), 100 (slow) or 160 ns (extra slow), 40 ns later under ILONG |
| Triggered delays, started by an event | the master's 80 ns setup; the 60 ns read deskew; on the Unibus the select at 200, the address at 100, the acknowledgment at 150 and the MD strobe at 100 ns; the register strobe at 150 and the answer at 250 ns; the debug request at 100 ns; `-MFINISHD` at 30 and `-RDFINISH` at 140 ns |
| Free-running oscillators | the timeout oscillator, 850 ns a period; the microsecond clock, 1,000 ns; `KB CLK`, 8,000 ns; `FCLK`, 125 ns; the half-microsecond clock, 500 ns at a phase of 203; the sixty-cycle clock; the sync program, 500 or 625 ns an instruction; the display frame, 15,456,000 ns |
| The disk | a revolution, a sector, the seek's settle and its time per cylinder, and the 2.56 s hang timer |

### What is ours

- **The grid.** The ring and every triggered delay are rounded up to the next
  10 ns. A normal microcycle is 15 ticks, 150 ns against MIT's 145, so the
  machine runs at about 97% of the original speed. Eleven instants move, eight
  by 5 ns and three by 7 ns, and none earlier: TSE's two edges, SELECT, the
  end of the control store's write pulse, the fast and normal read taps with
  and without ILONG, the receive buffer's setup, the counter's low half and the
  half-microsecond clock's first edge.
- **Oscillators keep their exact period.** A free-running clock is an
  accumulator that acts at the first tick at or after each true edge, so it
  never drifts from MIT's rate.
- **Power-on is two edges after the reset edge** for every oscillator,
  because that is where the reference's time zero falls in the fabric.
- **A few fabric adjustments are made, each explained where it is made.** The
  control store is written on the write pulse's leading edge. The scratchpads,
  the maps and the dispatch memory are written as the pulse ends, on the
  boundary's own tick, and a cycle `-WAIT` holds writes nothing. A memory strobe
  on a boundary's own tick belongs to that boundary. The processor tests
  SPEEDCLK a tick early. `-RDFINISH` is three ticks short, the ticks that
  ending a hang costs. The disk holds a stored word two ticks and a read one.
- **Some counts are not MIT's timing at all.** The debug cable's signaling,
  the console's pulses, the watchdog and the lamps' hold times are counted in
  real board ticks. They are listed under *What is not MIT's timing at all*.

### What depends on what

1. A microcycle is the read tap plus the restart, and each is rounded on its
   own.
2. The write pulse is measured from the end of the read phase. TSE, SELECT and
   `-TPR60` are measured from the start of the cycle, so the two groups cannot
   collide.
3. SELECT must fall after `-TPR60` and before the earliest read tap. On the
   grid that is 6 < 7 < 8 ticks, with nothing to spare.
4. The NXM timeout is five oscillator periods and fires on the sixth rising
   edge. The acknowledgment follows the oscillator's phase, so anything that
   changes when the oscillator starts moves every timeout.
5. On the Unibus the MD strobe lands 50 ns before the acknowledgment. On the
   Xbus the two coincide.
6. The register blocks' pulse, strobe and answer are three taps of one delay
   line, and they move together.
7. On the I/O board a mouse step and the interval counter's tick are each two
   `KB CLK` periods, and `-BOOT*` is half of one.
8. The timing constraints write tick counts as literals. `grid.pass` fails
   when a literal and the grid disagree.
9. muir generates the reference traces under the same grid, with
   `--timing-model fpga`.

The full list is *The relationships* below.

## Where the grid lives

The conversion from MIT's nanoseconds into ticks is one number with four
kinds of home. They must move together, and `make check` holds them to it.

| Home | What it covers |
|---|---|
| `rtl/machine/cadr_tick_pkg.sv` | the fabric: `TICK_NS`, `ticks(ns)` and `POWER_ON_EDGES` |
| `tb/cadr_tick.h` | the testbenches: `kGridNs`, `GridTicks(ns)` and `kPowerOnEdges` |
| `golden/src/busint_regs.rs`, `busint_xbus.rs`, `color_tv.rs`, `disk.rs`, `iob.rs`, `phase_gen.rs`, `power_on.rs`, `trace.rs`, `tv.rs` | the reference side, one `TICK_NS` each |
| `cadr-checkpoint/src/chk.h` and `cadr-console/src/console_test.c` | the board programs: `CHK_GRID_NS`, and the console model's microcycle and diagnostic cycle in ticks |

**The grid is 10 ns.** MIT's drawings place most instants on multiples of
five nanoseconds, and this grid places each one at the first 10 ns tick at or
after it. So a normal microcycle is 15 ticks where the drawings say 145 ns,
and the machine runs at 145/150 of the original speed, about 97%. The previous
grid was 5 ns, which kept every instant exact but, with the board's 10 ns
tick, ran the machine at half speed.

**The grid is not the length of a tick.** How long a tick lasts is the
board's business: `boards/arty-z7-20/cadr_arty.sv` makes it 10 ns. The two
tens are still two numbers. One is a divisor in the package and one is a
clock period in the board file, so a board can change its tick without
touching the grid.

**Rounding is always up.** `ticks(ns)` is `(ns + TICK_NS - 1) / TICK_NS` and
never a plain division. Truncation collapses MIT's 5 ns instant to zero ticks
and puts SELECT on top of a read tap. It also makes the fabric sample
*earlier* than the real machine did, which is the wrong direction for a setup
time, a deskew or a strobe: each of those is a promise that something has
settled.

**The reference is generated under the same grid.** muir's
`--timing-model fpga` (`TimingModel::Fpga`, `GRID_NS` = 10) rounds a delay up
from its own trigger and takes a free-running clock's edge at the first tick at
or after its exact instant. Every generator builds muir's engines under that
model, and `tools/grid_check.py` fails a generator that builds `Rtl`,
`Busint`, `IoBoardTiming` or the disk's `Controller` without it.

**The reference side is the half that cannot be checked by building.** The
Rust constants belong to separate binaries with no shared library, so they are
not unified here. They are load-bearing: `golden/src/disk.rs` writes tick
counts into the trace (`# ticks {}`), and `color_tv.rs` asserts that the
display's frame divides by the grid. Moving the fabric's grid without moving
these would change what the traces mean, and nothing in the build would fail.
That is why `tools/grid_check.py` exists. It runs as `grid.pass`, finds every
home, and fails when one is missing or when two disagree.

## What the 10 ns grid moved

These are the instants the grid rounds rather than divides. Eight move up by
five nanoseconds and three by seven, none earlier, and every one of them is
rounded the same way by muir's `--timing-model fpga`.

| Instant | Drawings | On the grid |
|---|---|---|
| `TPTSE` clears | 5 ns | 10 ns |
| `TPTSE` sets | 25 ns | 30 ns |
| SELECT | 65 ns | 70 ns |
| control store write pulse ends, `-TPW45` | 45 ns | 50 ns |
| read tap, fast | 75 ns | 80 ns |
| read tap, fast + ILONG | 115 ns | 120 ns |
| read tap, normal | 85 ns | 90 ns |
| read tap, normal + ILONG | 125 ns | 130 ns |
| the I/O board's low counter half | 313 ns | 320 ns |
| the receive buffer's setup | 33 ns | 40 ns |
| the half-microsecond clock's first edge | 203 ns | 210 ns |

A microcycle is the rounded tap plus the rounded restart, as muir's
`TimingModel::cycle_ns` computes it:

| Speed | Drawings | 5 ns grid | 10 ns grid |
|---|---|---|---|
| fast | 135 ns | 27 ticks | 14 ticks |
| fast + ILONG | 175 ns | 35 | 18 |
| normal | 145 ns | 29 | 15 |
| normal + ILONG | 185 ns | 37 | 19 |
| slow | 160 ns | 32 | 16 |
| slow + ILONG | 200 ns | 40 | 20 |
| extra slow | 220 ns | 44 | 22 |

**Three places in the fabric were right at 5 ns and wrong at 10 ns, and each
is fixed and held by a mutation.**

- **The control store was written on the write pulse's trailing edge.** The
  store is read synchronously, so a word written must land two edges before
  the boundary that loads IR. At 10 ns the trailing edge, 50 ns into the write
  phase, is one tick before the restart at 60, and every word the boot PROM
  loaded read back all ones from microcycle 410,840. The write is taken on the
  leading edge now, which is the end of the read phase. The word is the same
  at either edge, because `pc`, `iwr` and `iwrited` stand through the whole
  pulse. `the-control-store-is-written-on-the-pulse-trailing-edge` holds it.
- **A memory strobe on a boundary's own tick waited a microcycle.** muir runs
  `after_memack` at the boundary instant before the next read phase, so a word
  acknowledged on the boundary is in MD for the next microcycle. At 10 ns a
  read acknowledged a whole number of microcycles after its grant lands
  exactly on a boundary three times in the band's 2,800,000 microcycles. MD
  now takes such a word at that boundary. `a-strobe-on-the-boundary-waits-a-microcycle`
  holds it.
- **The disk's attention countdowns subtracted a literal five.** At 10 ns they
  counted at half the rate and a seek's attention arrived twice as far after
  the heads. They subtract `TICK_NS` now, as the busy counter does.
  `disk-attention-counts-five-nanoseconds-a-tick` holds it.

## The rule: triggered goes on the grid, free-running keeps its period

There are three kinds of timing instant, and the kind decides the treatment.

1. **The ring.** One phase counter in `rtl/machine/cadr_phase_gen.sv`, which
   is MIT's delay line started by `-TPR0`. Every microcycle instant is a
   comparison against it. **On the grid.**
2. **Triggered delays.** Not off the ring, but started by an event and fixed
   relative to it — the bus's setup time, the read deskew, the Unibus
   handshake, the register blocks' strobe and answer. **On the grid**, for
   the same reason: the machine reads them at named instants and the traces
   compare them tick for tick.
3. **Free-running oscillators.** Started by nothing and running since power
   came up. What matters is the phase one is at when something asks, not its
   spacing from any event.

The rule that follows is that **anything triggered goes on the grid and
anything free-running keeps its true period.**

### One refinement, which is why a few constants keep their period

Class 3 divides again, and the halves behave differently.

- **Rounding a free-running PERIOD drifts without bound.** The error repeats
  every period and accumulates, so every answer synchronized to that
  oscillator moves further as the run goes on.
- **Rounding a free-running PHASE is a single error under one tick.** It is
  applied once, at power-on, and never again.

The I/O board rounds a phase, deliberately: the half-microsecond clock the
serial port's select is synchronized to sits at 203 ns modulo 500 from
power-on, and `HU_FIRST_T` rounds it up. The module says so at the constant,
and the reference trace carries a `slip` column rather than a tolerance, so
the rounding is a stated instant and not a fudge. The microsecond counter's
low half at 313 ns is rounded the same way.

So the constants that must not be rounded are precisely the free-running
**periods that do not divide by the grid**:

| Constant | Period | At a 5 ns grid | At the 10 ns grid |
|---|---|---|---|
| `VCO_HALF_NS`, `rtl/machine/cadr_busint_xbus.sv` | 425 ns | 85 ticks, uniform | 42.5 — alternates 43 and 42 |
| `FCLK_NS`, `rtl/machine/cadr_io_board.sv` | 125 ns | 25 ticks, uniform | 12.5 — alternates 13 and 12 |
| `INSTRUCTION_NS_SLOW`, `rtl/machine/cadr_tv.sv` | 625 ns | 125 ticks, uniform | 62.5 — alternates 63 and 62 |

Each keeps its period in nanoseconds and advances an accumulator by the grid
each tick, so none is ever rounded. Writing the alternation out instead would
hard-code one particular grid in a second place, which is the thing having a
single grid constant exists to prevent.

The other free-running constants are on the grid because they happen to
divide: the microsecond clock's 890 ns first edge and 1,000 ns period, the
display's fast instruction of 500 ns, and `KB CLK^` at 8,000 ns. **They are
safe by arithmetic and not by design**, which is why the class needs naming
even though nothing is wrong with them.

### The pattern all of them use

Every oscillator in the machine keeps its period in nanoseconds and advances
it by `TICK_NS` each tick, which is exact at any grid:

- the I/O board's sixty-cycle clock, `mains_acc` in `cadr_io_board.sv`, whose
  16,666,666 ns period is 6 modulo 10 and so lies off the grid on four
  periods in five;
- the serial line's crystal, `XTAL_WRAP` in `cadr_serial_line.sv`, which adds
  a frequency each tick and wraps at `1_000_000_000 / TICK_NS`;
- the disk controller, which counts every span down in nanoseconds by
  `TICK_NS` a tick, reaching zero on exactly the tick a counter loaded with
  `ceil(span / TICK_NS)` would;
- the timeout oscillator, FCLK and the display's sync program.

**The wrap subtracts the period and never clears.** Clearing discards the
remainder, and carrying the remainder is the whole of the difference: a
cleared counter loses a little every period and its phase walks away.

**The starting parity is a decision and is stated at each constant.** The
accumulators are zero when their oscillator starts, which makes the first
period the longer of the two wherever the grid does not divide the period —
43 ticks then 42 for the timeout oscillator, 13 then 12 for FCLK, 63 then 62
for a slow sync instruction. That is also muir's answer: under
`--timing-model fpga` an edge is taken at the first tick at or after its exact
instant, so the timeout oscillator's edges fall at 0, 430, 850 and 1,280 ns,
measured on the composed machine.

### A change on an edge counts as before it

muir carries the bus to an edge before it takes the edge, so an asynchronous
change that falls exactly on an edge is seen by that edge. MIT's board agrees
wherever the tie comes from rounding onto the grid. The two rules this settles
are that a word strobed into MD on a boundary is read by the microcycle that
boundary starts, and that MFINISHD on a master clock edge ends a wait on
MBUSY.SYNC at that edge.

In the fabric this fixes where an instant sits. A change at instant T has to
be on the D inputs of the registers clocked at T, so it is combinational over
the tick that ends at T. A register that moves at T is seen only by the edge
after it, so a register that stands for an asynchronous level moves on the
edge before its instant. That is why several constants are one tick short:

- `-XBUS.RQ` and `-UB MSYN` rise at `elapsed >= SETUP_T - 1` and
  `UB_ADDRESS_T - 1`, counted from the grant's edge;
- `MFINISHD_T` is `ticks(30) - 1`, because `MBUSY` is a register;
- the NXM timer takes its last rise on the edge before the rise;
- `RD_FINISH_T` is `ticks(140) - 2`, because ending a hang costs the fabric
  two ticks of its own: one for -HANG to lift and the generator to raise
  TPCLK, one for the boundary to reach the registers.
- the register block lands a write at SPEEDCLK two ticks ahead of it, for
  the synchronizer, so a strobe due on either of those ticks is landed
  there from the word on the bus.

Every check that compares an acknowledgment with muir reads it in this frame,
before the edge and with the tick's inputs driven, and prints the
difference. `dispatch_write_order` holds programs that put each tie on an
edge.

### Power-on is two edges after the reset edge, for every oscillator

The reference counts every free-running clock in whole periods from its
power-on, which is the instant the ring starts. The ring starts on the first
edge reset is low. The processor and the bus interface then act on the ring's
boundary one edge after the ring makes it. So in the frame every trace compares
in, power-on is two edges after the reset edge. `POWER_ON_EDGES` in
`cadr_tick_pkg.sv` is that number. It is a count of the fabric's edges, so it
is two at any grid.

The bus interface's timeout oscillator started at the reset edge, and every
cycle nothing answered was acknowledged two ticks before the reference's. That
was issue #21, measured on the whole machine by reading the oscillator itself,
whose rises fell at 840 modulo 850 of the reference's time. **The I/O board's
clocks and the display's program from power-on started at the reset edge too,
and they carried the same two ticks.** Measured on the composed machine at
the 10 ns grid, with the reference's origin taken from the processor's first
microcycles:

| Clock | Reference | Started at the reset edge | Started at power-on |
|---|---|---|---|
| `FCLK^`, first four edges | 130, 250, 380, 500 ns | 110, 230, 360, 480 | 130, 250, 380, 500 |
| half-microsecond clock | 210, 710, 1,210 ns | 190, 690, 1,190 | 210, 710, 1,210 |
| microsecond clock | 890, 1,890 ns | 870, 1,870 | 890, 1,890 |
| `KB CLK^` | 8,000, 16,000 ns | 7,980, 15,980 | 8,000, 16,000 |
| the mains | 16,666,670 ns | 16,666,650 | 16,666,670 |
| the display's first instruction | 500 ns | 480 | 500 |
| the display's first `-TVMA CLR` | 16,000 ns | 15,980 | 16,000 |

`cadr_busint_xbus.sv`, `cadr_io_board.sv` and `cadr_tv.sv` now start their
clocks `POWER_ON_EDGES` after the reset edge. The bus interface does it by
setting its accumulator that many ticks short of a toggle. The I/O board and
the display hold their clocks at their reset values for that many edges, and
held there none of them is at an edge.

`power_on.pass` holds all of it. Its testbench builds the composed machine,
finds the reference's origin from the ticks at which the processor's first
eight microcycles end, and compares 26 edges of the I/O board's clocks and the
display's program against muir's instants from `golden/src/power_on.rs`. It
reads no power-on constant, so a module that started at any other edge fails
by disagreeing with muir. Before the fix it failed on all 26, each 20 ns early.
Its records are `iob-the-clocks-start-a-tick-before-power-on` and
`tv-program-from-power-on-starts-a-tick-early`.

The standalone checks use the same frame. `busint_xbus`, `memory_path`, `tv`,
`color_tv` and now `iob` put the reset edge and one idle edge before their
first row, and `unibus` puts them before the tick it counts from. They used to
reset on their row 0, which is why each passed with its clocks two ticks early
in the whole machine. `tools/grid_check.py` fails a testbench that keeps a
`kPowerOnEdges` of its own and a module that writes a power-on count of its
own.

**Two free-running clocks are not held by it.** The disk's spindle still
starts at the reset edge. Measured on the composed machine, its first wrap
falls 30 ns before the first tick of the reference's revolution. The module's
own convention of counting a tick ahead for the read word accounts for one
tick of that, and the start at the reset edge for the other two. No
whole-machine trace compares a rotational instant, and the disk check places
the spindle with a pre-roll counted from its own reset, so moving it is work
of its own. The serial line's crystal is not in the composed machine at all.

## The display's sync program

`rtl/machine/cadr_tv.sv` runs MIT's sync program one instruction at a time,
and an instruction is 500 ns in clock modes 0 and 1 and 625 ns in modes 2 and
3 (`sync::INSTRUCTION_NS`, measured on the netlist LISPM TV). The program runs
off the board's crystal, so it is a free-running clock and not a delay from an
event.

- **An instruction keeps its length in nanoseconds.** `seq_ns` counts
  nanoseconds into the instruction by `TICK_NS` a tick. A boundary falls at
  the first tick at or after the instruction's end, which is the tick whose
  next count would reach it. The boundary subtracts the instruction and
  carries the remainder. At the 10 ns grid a fast instruction is exactly 50
  ticks, and a slow one alternates 63 and 62.
- **The phase starts at the restart, not at power-on.** muir's `Tv::restart`
  puts the program's origin at the write that loads it or changes the clock
  mode, and counts every boundary from there. So the accumulator starts again
  at zero on that write's tick, and a remainder the old program left is thrown
  away with it. Until the software restarts it, `cpt.prom` runs from power-on,
  which is `POWER_ON_EDGES` after the reset edge like every other oscillator.
- **The frame is made by the program.** For `cpt.prom` it is 15,456,000 ns,
  which is 1,545,600 ticks at the 10 ns grid, and `-TVMA CLR` falls 16,000 ns
  into it in clock mode 0.

Held by `tv-sync-instruction-a-tick-long`, `tv-sync-instruction-a-tick-short`,
`tv-slow-sync-instruction-is-the-fast-one`,
`tv-slow-sync-instruction-rounded-to-the-grid`,
`tv-sync-remainder-dropped-at-a-boundary`, `tv-sync-boundary-a-tick-late`,
`tv-sync-phase-survives-a-restart` and
`tv-program-from-power-on-starts-a-tick-early`. The trace restarts the
program nine times and holds the machine in clock mode 3 for a whole frame, so
the slow alternation is compared.

## The instants

`†` marks a value that rounds rather than divides. Class is **R** for the
ring, **T** for a triggered delay, **F** for free-running.

### The ring — `rtl/machine/cadr_phase_gen.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| `TPTSE` clears, `-TPR5` | 5 | R | `clock::TSE_OFF_NS` | `TSE_OFF_T` | 1 | 1† |
| `TPTSE` sets, `-TPR25` | 25 | R | `clock::TSE_ON_NS` | `TSE_ON_T` | 5 | 3† |
| `-TPR60` opens | 60 | R | `clock::TPR60_NS` | `TPR60_ON_T` | 12 | 6 |
| `-TPR60` closes | 100 | R | `+ clock::TPR_PULSE_NS` | `TPR60_OFF_T` | 20 | 10 |
| SELECT, the 74S151 read | 65 | R | `clock::SELECT_NS` | `SELECT_T` | 13 | 7† |
| write pulse on, `-TPW30` | 30 | R | `clock::WP_ON_NS` | `WP_ON_T` | 6 | 3 |
| control store off, `-TPW45` | 45 | R | `clock::WPIRAM_OFF_NS` | `WPIRAM_OFF_T` | 9 | 5† |
| restart, `-TPDONE` | 60 | R | `clock::RESTART_AFTER_READ_NS` | `RESTART_T` | 12 | 6 |
| read tap, fast | 75 | R | `Speed::read_phase_ns` | `READ_FAST_T` | 15 | 8† |
| read tap, fast + ILONG | 115 | R | the same | `READ_FAST_ILONG_T` | 23 | 12† |
| read tap, normal | 85 | R | the same | `READ_NORMAL_T` | 17 | 9† |
| read tap, normal + ILONG | 125 | R | the same | `READ_NORMAL_ILONG_T` | 25 | 13† |
| read tap, slow | 100 | R | the same | `READ_SLOW_T` | 20 | 10 |
| read tap, slow + ILONG | 140 | R | the same | `READ_SLOW_ILONG_T` | 28 | 14 |
| read tap, extra slow | 160 | R | the same | `READ_EXTRA_SLOW_T` | 32 | 16 |

### The bus interface — `rtl/machine/cadr_busint_xbus.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| master setup before `-XBUS.RQ` | 80 | T | `busint::SETUP_NS`, `xspec.text.3` | `SETUP_T`, less one | 16 | 8 |
| read deskew, TD100 at REQLM 0C09 | 60 | T | `busint::XBUS_ACK_NS` | `DESKEW_T` | 12 | 6 |
| `-SACK` to the grant | 200 | T | `busint::UNIBUS_SELECT_NS` | `UB_SELECT_T` | 40 | 20 |
| grant to `-UB MSYN` | 100 | T | `busint::UNIBUS_ADDRESS_NS` | `UB_ADDRESS_T`, less one | 20 | 10 |
| `-UB SSYN` to `-LMACK` | 150 | T | `busint::UNIBUS_ACK_NS` | `UB_ACK_T` | 30 | 15 |
| `-UB SSYN` to the MD strobe | 100 | T | `busint::UNIBUS_STROBE_NS` | `UB_STROBE_T` | 20 | 10 |
| timeout oscillator, half period | 425 | F | `chip::VCO_PERIOD` | `VCO_HALF_NS` | 85 | 43 then 42 |
| timeout oscillator starts, edges after the reset edge | — | fabric | the reference's power-on | `POWER_ON_T`, from `POWER_ON_EDGES` | 2 | 2 |

### The processor — `rtl/machine/cadr_microcycle.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| SPEEDCLK, the speed synchronizer | 60 | R | `clock::TPR60_NS` | `SPEEDCLK_T`, less one | 12 | 6 |
| `-MFINISHD`, TD50 at VCTL1 1D23 | 30 | T | `busint::MFINISHD_NS` | `MFINISHD_T`, less one | 6 | 3 |
| `-RDFINISH`, TD250 at VCTL1 1D22 | 140 | T | the tap ordering | `RD_FINISH_T`, less two | 28 | 14 |

### The register blocks — `cadr_spy_registers.sv`, `cadr_busint_regs.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| `-UB SSYN`, the TD250 at UBCYC 0F04 | 250 | T | `busint::DIAGNOSTIC_NS` | `SSYN_T` | 50 | 25 |
| the register strobe | 150 | T | `busint::REGISTER_STROBE_NS` | `STROBE_T` | 30 | 15 |
| the reset and boot pulse's width | 50 | T | `REGISTER_STROBE_NS` less `REGISTER_PULSE_NS` | `PULSE_T`, as `150 - 100` | 10 | 5 |
| `UBXRQ` after `-UB MSYN` | 100 | T | `busint::UB_XBUS_REQUEST_NS` | `XBUS_RQ_T` | 20 | 10 |
| `-UB SSYN` after `-UBACK`, mapped read | 100 | T | `busint::UB_XBUS_READ_ACK_NS` | `READ_ACK_T` | 20 | 10 |
| `-LOADMD ACK` on a mapped write | 100 | T | `busint::UB_MD_ACK_NS` | `MD_ACK_T` | 20 | 10 |
| `-DEBUG OUT REQ`, MTD100 at DBGOUT 0A10 | 100 | T | `busint::DEBUG_OUT_REQUEST_NS` | `DBG_REQ_T` | 20 | 10 |

### The debug cable — `cadr_dbgin.sv`, `cadr_debug_window.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| `DBUB MASTER` to `-UB MSYN` | 100 | T | `busint::DEBUG_MSYN_NS` | `MSYN_T` | 20 | 10 |
| `-DEBUG IN REQ` to the master clearing | 100 | T | `busint::DEBUG_RELEASE_NS` | `RELEASE_T` | 20 | 10 |
| levels on the cable before the request | 100 | T | `busint::DEBUG_OUT_REQUEST_NS` | `LEAD_T` | 20 | 10 |

### The I/O board — `cadr_io_board.sv`, `cadr_input_cables.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| microsecond clock, first edge | 890 | F | `ioboard::FIRST_USEC_EDGE_NS` | `FIRST_EDGE_T` | 178 | 89 |
| microsecond clock, period | 1,000 | F | the same chain | `USEC_PERIOD_T` | 200 | 100 |
| the counter's low half | 313 | T | `busint::IOB_USEC_LOW_NS` | `USEC_LOW_T` | 63† | 32† |
| `KB CLK^`, 74LS163 at IOBCLK 0D24 | 8,000 | F | `ioboard::KB_CLK_NS` | `KB_CLK_T` | 1,600 | 800 |
| the interval counter's tick | 16,000 | T | `ioboard::INTERVAL_TICK_NS` | `INTERVAL_T` | 3,200 | 1,600 |
| a mouse step | 16,000 | T | `mouse::MOUSE_STEP_NS` | `MOUSE_STEP_T` | 3,200 | 1,600 |
| the TD250 at IOBADR 0E09 | 250 | T | `busint::IOB_STRAIGHT_NS` | `STRAIGHT_T` | 50 | 25 |
| the Chaosnet transmit buffer | 350 | T | `busint::IOB_CHAOS_BUFFER_NS` | `CHAOS_BUF_T` | 70 | 35 |
| `FCLK^`, 74S163 at LMTCLK 0B03 | 125 | F | `busint::IOB_FCLK_NS` | `FCLK_NS` | 25 | 13 then 12 |
| the receive buffer's setup | 33 | T | `busint::IOB_RBUF_SETUP_NS` | `RBUF_SETUP_T` | 7† | 4† |
| the half-microsecond clock's period | 500 | F | `busint::IOB_HALF_USEC_NS` | `HU_PERIOD_T` | 100 | 50 |
| its phase from power-on | 203 | F | `busint::IOB_HALF_USEC_PHASE_NS` | `HU_FIRST_T` | 41† | 21† |
| the serial group's answer | 750 | T | `busint::IOB_SERIAL_NS` | `SERIAL_T` | 150 | 75 |
| `-BOOT*` | 4,000 | T | half of `ioboard::KB_CLK_NS` | `BOOT_T` | 800 | 400 |
| the sixty-cycle clock | 16,666,666 | F | `ioboard::SIXTY_CYCLE_NS` | accumulator | — | — |
| every clock above starts, edges after the reset edge | — | fabric | the reference's power-on | `POWER_ON_EDGES` | 2 | 2 |

### The display — `cadr_tv.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| a sync instruction, clock modes 0 and 1 | 500 | F | `sync::INSTRUCTION_NS` | `INSTRUCTION_NS_FAST` | 100 | 50 |
| a sync instruction, clock modes 2 and 3 | 625 | F | the same | `INSTRUCTION_NS_SLOW` | 125 | 63 then 62 |
| `cpt.prom`'s frame | 15,456,000 | F | `tv::FRAME_NS` | made by the program | 3,091,200 | 1,545,600 |
| the program from power-on starts, edges after the reset edge | — | fabric | the reference's power-on | `POWER_ON_EDGES` | 2 | 2 |

### The disk — `cadr_disk_controller.sv`

The disk keeps every span in nanoseconds and counts down by `TICK_NS` a
tick, so none of these is a tick count and none is rounded.

| Span | ns | Class | Constant |
|---|---|---|---|
| a revolution | 16,666,667 | F | `REVOLUTION_NS` |
| a sector | 968,448 | F | `SECTOR_NS` |
| the index pulse | 4,000 | T | `INDEX_PULSE_NS` |
| the sector pulse | 1,240 | T | `SECTOR_PULSE_NS` |
| the hang timer, 74LS124 at DCTMOT 0B04 over 128 | 2,560,000,000 | T | `TIMEOUT_NS` |
| seek settle | 5,939,729 | T | `SEEK_SETTLE_NS` |
| seek, per cylinder | 60,271 | T | `SEEK_NS_PER_CYLINDER` |
| a unit's attention | the seek | T | `u_att_ns`, by `TICK_NS` a tick |
| the store hold | two ticks | fabric | `STORE_HOLD_NS` |
| the read hold | one tick | fabric | `READ_HOLD_NS` |

## The relationships

These are the invariants *between* instants. They are what makes changing one
number dangerous, and they are the reason this document exists.

| # | Invariant | Why, and where it is written |
|---|---|---|
| 1 | **A generator cycle is the read tap plus the restart, each rounded on its own.** 85 + 60 = 145 ns, which is 9 + 6 = 15 ticks at the 10 ns grid and 29 at 5. | `Speed::cycle_ns` is `read_phase_ns(ilong) + RESTART_AFTER_READ_NS`, and `TimingModel::cycle_ns` rounds the two separately. Every cycle length in the machine follows from its tap; none is written down separately. |
| 2 | **The write-pulse family is measured from the END of the read phase; TSE, SELECT and `-TPR60` are measured from `-TPR0`.** | `cadr_phase_gen.sv` computes `wp_on_at` as `read_sel + WP_ON_T`, while `tptse` compares against `TSE_OFF_T` directly. They are two different origins, which is why they cannot collide however the tap moves. |
| 3 | **The write pulse is 15 ns wide on the drawings**, `WPIRAM_OFF` minus `WP_ON`. The width is the claim, not either end. At the 10 ns grid both ends round up separately and the pulse is 20 ns wide. | `clock.rs`: "no signal on the board is derived from the pulse's width" — so what matters is that the control store sees a pulse at all, and both ends must move together. |
| 4 | **The write pulse is clamped to the cycle boundary.** The board's `-TPW70` outlives `-TPDONE` at 60 by 10 ns; the model takes `WP_OFF_NS.min(RESTART)`. | `clock.rs` at `RESTART_AFTER_READ_NS`: "the write pulse of one cycle overlaps the start of the next by 10 ns". With no gate delays in fabric, an unclamped pulse would write at the next instruction's address. The scratchpads, the maps and the dispatch memory take their address and word as the clamped pulse ends, which is the boundary's own tick. On the CADR a map or dispatch read in the microcycle that writes the same memory gets the new word, the board's race as muir's netlist model settles it, so the processor passes the word being written around the RAM. On QUUX it gets the old word, as QUUX defines it. In a microcycle `-HANG` holds, the pulse ends on the park's first tick, and the maps' and the dispatch memory's write lands with the same address and word up to two ticks before it or up to two ticks after it (row 30). QUUX has no hung microcycle: a microcycle that reads MD with a read in flight waits whole cycles with no write pulse and then runs once. Held by `build/dispatch_write_order.pass` and `build/dispatch_write_order.quux.pass`. |
| 5 | **ILONG adds exactly 40 ns to a read tap before it is rounded, except at extra slow.** | `Speed::read_phase_ns`. At extra slow 160 ns is already the longest tap the chain provides. Held by `extra-slow-stretches-with-ilong`. |
| 6 | **SELECT falls after `-TPR60` and before the earliest read tap: 60 < 65 < 75.** | `clock.rs` at `SELECT_NS`: "after SPEEDCLK at 60 has clocked the synchronizer and the board has settled, before the earliest tap at 75". In ticks that is 12 < 13 < 15 at 5 ns, and 6 < 7 < 8 at 10 ns — the ordering survives, with nothing to spare. Held by `the-read-phase-is-selected-at-the-start-of-the-cycle`. |
| 7 | **`-TPR60`'s window is `TPR60_ON` to `TPR60_ON + TPR_PULSE_NS`**, 60 to 100 ns. | The `-TPR0` pulse is 40 ns wide and every read tap is that pulse delayed, so the window's width is the pulse's. |
| 8 | **SPEEDCLK is `-TPR60` inverted, and two modules name the same instant.** `cadr_spy_registers.sv` uses `ticks(60)`; `cadr_microcycle.sv` uses `ticks(60) - 1`. | The processor compares against its own phase counter, which is a tick behind the generator's, so it must test a tick early. The two must move together and a reader meeting only one of them will not know that. |
| 9 | **The bus master's 80 ns of setup is `ticks(80)` ticks, and a timing constraint claims exactly that many.** Eight at the 10 ns grid. | `rtl/plumbing/xilinx7/cadr_ddr.xdc` writes `set_multicycle_path -setup 8`, on the strength of the same sentence from `xspec.text.3` and nothing else. `the-setup-time-is-short` is the mutation one tick outside that bound: the check that catches a fabric which stopped honoring the 80 ns is the check that would catch a constraint claiming it wrongly. `grid.pass` fails the constraint if the grid moves and it does not. |
| 10 | **A read is deskewed by 60 ns and a write is not.** | The 74S64 at REQLM 0C11 makes XACK combinationally for a write and through the TD100's 60 ns tap for a read. Held by `memack-registered-on-a-write`. |
| 11 | **On the Unibus the word lands 50 ns BEFORE the acknowledgment; on the Xbus they coincide.** `UB_STROBE` 100 against `UB_ACK` 150. | `busint::UNIBUS_STROBE_NS`: "`MSYN OUT` drops at `SSYN T100` and `-LOADMD` rises with it". That 50 ns gap is the only place on either bus where the word and the acknowledgment come apart, and it is why `-LOADMD` is a port of its own. Held by `unibus-the-md-strobe-lands-with-the-acknowledgement`. |
| 12 | **The register block answers 100 ns after it strobes.** `STROBE` 150, `SSYN` 250, on one TD250. | `busint::DIAGNOSTIC_NS`: the block "runs `UB REG CYC T0` down the TD250 at 0F04 for any of them, strobes the register between the 50 and 150 ns taps, and answers at the last". One delay line, three taps; they cannot be moved independently. |
| 13 | **The reset and boot pulse ENDS at the strobe**, so its width is `STROBE - PULSE` = 50 ns. | `cadr_spy_registers.sv` writes `PULSE_T` as `ticks(150 - 100)`. `busint::REGISTER_PULSE_NS` is measured from the same leading edge as the strobe, so the two are one relationship and not two constants. |
| 14 | **The NXM timeout is five oscillator periods and fires on the SIXTH rising edge; the debug table is thirteen and fires on the fourteenth.** | `busint::TIMEOUT_NS` is `5 * NXM_VCO_NS` and `DEBUG_TIMEOUT_NS` is `13 * NXM_VCO_NS`; `cadr_busint_xbus.sv` carries `NXM_RISES = 6` and `DBG_RISES = 14`. The invariant is *rises = periods + 1*, and a change to either constant that forgets the other moves every timeout. |
| 15 | **The timeout is 4,250 ns because the oscillator is 850.** | `TIMEOUT_NS = 5 * 850`. The timeout is not an independent number; it is the oscillator's period counted five times. |
| 16 | **A mouse step is exactly two `KB CLK^` periods.** 16,000 against 8,000. | So every quadrature phase is latched into `NEW` and then into `OLD` before the next, and none is missed. At the card's own rate the counts would still come out right and only the time would be wrong, which is why the check measures the span and not only the count. Held by `iob-the-mouse-samples-at-16-us` and `input-the-mouse-steps-twice-as-fast`. |
| 17 | **The interval counter's tick is also two `KB CLK^` periods.** | `ioboard::INTERVAL_TICK_NS` is 16,000, one count of the four 74LS193s at CLKTIM on the 16 us clock. |
| 18 | **`-BOOT*` is exactly half a `KB CLK^` period.** 4,000 against 8,000. | The comparator's enable is low for exactly that half clock — the one before the rising edge that latches the word and sets `KBD READY`. Held by `boot-the-pulse-is-a-tick-short`. |
| 19 | **The serial group answers 750 ns after the first half-microsecond edge STRICTLY after `-MSYN`**, with those edges at 203 modulo 500 from power-on. | Moving the phase moves every answer of the group, by as much as half a microsecond at the wrong side of an edge. Held by `iob-the-serial-ports-select-has-no-phase`. |
| 20 | **The receive buffer is read at the first `FCLK^` edge whose tick is at or after `-MSYN` plus `ticks(33)`**, and that is muir's rule under `--timing-model fpga` as well as the fabric's. | The fabric tests `fclk_now` on a tick at least `RBUF_SETUP_T` after `-UB MSYN`. muir's `fclk_edge_at_or_after` looks for the first exact edge at or after that threshold less `GRID_NS - 1`, which is the first edge whose tick is at or after it. The two forms agree on every phase: with `-UB MSYN` at 1,090 ns both take the edge at 1,125, whose tick is 1,130, and answer at 1,380 rather than 1,500. `iob.pass` compares them. `RBUF_SETUP_T` is triggered and on the grid, and `FCLK_NS` is the oscillator and keeps its true period. |
| 21 | **The disk's store hold is two ticks and its read hold is one, and every timer a START loads is loaded that much short.** | So that what expires expires at the reference's instant despite the register on the counter's output. These are the one place a *fabric* concession is expressed in nanoseconds, and they move with the grid by construction. |
| 22 | **The sixty-cycle clock accumulates and never reloads.** Its period is 6 modulo 10, so a counter that adds the tick and subtracts the period is exactly `now mod SIXTY_CYCLE_NS`; one that reloads with zero loses nanoseconds every period. | Held by `iob-the-mains-counter-reloads-not-accumulates`. |
| 23 | **The display's frame divides the grid exactly**: 15,456,000 ns is 1,545,600 ticks at 10 ns and 3,091,200 at 5. | `golden/src/color_tv.rs` asserts `FRAME_NS % TICK_NS == 0` and would fail rather than round. A grid that does not divide the frame breaks that assertion, which is the one place the reference side checks the grid at all. |
| 24 | **The timeout oscillator's PHASE, not its period, is what the acknowledgment instant carries.** The grant only opens the oscillator's output; it does not start it. | This is why a one-tick shift anywhere in the reset network moves every NXM answer: `the-memory-path-leaves-reset-a-tick-late` delays only the memory path's reset and is caught. The oscillator starts `POWER_ON_EDGES` after the reset edge, and `the-timeout-oscillator-starts-a-tick-before-power-on` holds that from the whole machine. **Anything that changes when this counter starts, how long its period is, or how many edges the ring and the processor put between the reset edge and a grant, changes the answer on every cycle nothing answers.** |
| 25 | **Timing constraints and their flows write grid-derived tick counts as literals, and each carries a tag naming its instant.** At the 10 ns grid the fast read tap, 75 ns, and the bus setup, 80 ns, are both eight ticks, and the register strobe, 150 ns, is fifteen. Each hold is one less than its setup. | The relaxed set in `cadr_machine.xdc` and `-to $probe_stable` in both boards' `cadr_probe.xdc` are `# grid: 75 ns`; `-to $bus_word` in `cadr_machine.xdc` and `-to $contract` in `cadr_ddr.xdc` are `# grid: 80 ns`; `-to $ub_strobe` is `# grid: 150 ns`; and each assertion in `fit.tcl` and both `bitstream.tcl` carries its own tag. `tools/grid_check.py` fails a constraint with no tag, a count that is not `ticks(ns)` at the package's grid, and a hold that is not one less. **Two instants now share a count**, so an `assert_multicycle_applied` that matches a requirement cannot say which clause gave it; its tag must say `(shared with 80 ns)`, and the instance assertions say what holds each clause instead. The debug link's beat in `cadr_debug.xdc`, `cadr_debug_pmod.xdc` and the flows is tagged `# board ticks` and is not on the grid. |
| 26 | **The control store is written on the write pulse's LEADING edge, at least two edges before the boundary.** | The store is read synchronously: `imem_q` takes a word a tick after it is written, and IR takes `imem_q` at the boundary. At the 10 ns grid the trailing edge, `-TPW45` at 50 ns, is one tick before the restart at 60. Held by `the-control-store-is-written-on-the-pulse-trailing-edge`. |
| 27 | **A memory strobe on a boundary's own tick is that boundary's word.** | muir runs `after_memack` at the boundary instant before the next read phase. `cadr_microcycle.sv` commits the word to MD at that boundary rather than holding it for the next. Held by `a-strobe-on-the-boundary-waits-a-microcycle`. |
| 28 | **Every free-running clock starts `POWER_ON_EDGES` after the reset edge**, in the composed machine and in every standalone check. | See *Power-on is two edges after the reset edge*. Held by `power_on.pass` and its two records, and by `tools/grid_check.py`, which keeps the number in one package and one header. |
| 29 | **The display's sync program keeps its phase from the write that restarts it.** | `Tv::restart` puts the origin at that write. The accumulator starts again at zero there and drops the old program's remainder. Held by `tv-sync-phase-survives-a-restart`. |
| 30 | **A path split by a register that loads every tick, or launched by a write inside the cycle, has less than the relaxed set's eight ticks, and its constraint says how much less.** IR to the scratchpad latches has the read tap less one tick, seven at fast speed. The latches to the next boundary have the restart plus one tick, seven at every speed, and to the dispatch memory's write they have the restart less one tick, five. The control store's word has five after a `WRITE-I-MEM`. A write of either map level or of the dispatch memory reaches a boundary three ticks later at the least, and MD reaches those writes' address two ticks later at the least. MD_HELD into MD and the stack's write into its latch have one tick, and so do the three memories' writes into the readout's copies. The second hop out of `memgo_q`, the held halves of -WAIT and the memory path's held decode has `ticks(60)`, so that both hops together fit the fast microcycle. | The processor's registers move one tick after the generator's boundary, the latches last load at the read tap, and the write pulse ends on the boundary's own tick. In a microcycle `-HANG` holds, the pulse ends on the park's first tick and the boundary that ends the hang can be the next edge, and MD takes the bus's strobe at once. There the maps' and the dispatch memory's write is placed two ticks early, a tick late, or two ticks late when the read's strobe falls on the pulse's end, with the address and word the pulse's end would take, so that it is two ticks from MD and three from the boundary. Nothing but the boundary reads those memories in between, and `cadr_microcycle.sv`'s `mw` says why. `CADR_GAP_MONITOR` measures both counts on every tick of the checks that define it, and `dispatch_write_order` brings a write to each bound. A count one tick either side of an instant is tagged `# grid: 75 ns - 1 tick` or `# grid: 60 ns + 1 tick`, a count of the fabric's own ticks `# grid: 0 ns + 3 ticks`, and `tools/grid_check.py` holds it. The clauses are in `cadr_machine.xdc` and `cadr_de25.sdc`, the flows assert that each took and that nothing wider reaches its paths, and each has a `grid` mutation record one tick outside it. The DE25-Nano has no clause for the maps' or the dispatch memory's write, because Quartus times no path out of an MLAB's write. There the three ticks leave the tick in which an MLAB gives no defined word unread. |

## QUUX's synchronous microcycle

QUUX does not replay the CADR's delay line. Its microcycle is a fixed number
of ticks, K, and an `ILONG` instruction takes L ticks more. This is muir's
`TimingModel::Sync { cycle_ticks, ilong_ticks }`, run as `--timing-model sync
--sync-cycle-ticks K`. K and L belong to a board: the Arty Z7-20 and the
DE25-Nano both run at K = 4 and L = 0, which is 40 ns a microcycle. Four is
the least K QUUX takes. A `DIV` whose M source is MD needs the word read in
the divider 17 ticks before the edge that ends the microcycle it runs in.
That microcycle can start 14 ticks after the word's strobe, and the
earliest the divider can take the word from a register is the tick after
the strobe. Each board's top level states
K as `SYNC_K`, and its QUUX constraint file states the same K
(`quux_machine.xdc`, `quux_de25.sdc`). `tools/grid_check.py` holds every
`# sync:` count to that board's `SYNC_K`.

Inside a microcycle:

- `rtl/machine/quux_phase_gen.sv` counts K ticks, or K + L, and raises TPCLK
  on the boundary's tick. It has no read tap, no TSE, no SELECT and no
  `-TPR60`, and it ignores `-HANG`, because QUUX has no hung microcycle.
- Every write lands on the edge that ends the microcycle. That covers the
  scratchpads, the stack, both map levels, the dispatch memory and the
  control store. A read of a RAM in the same microcycle as its write gets
  the old word.
- The control store is read at the edge from NPC, and its word stands for
  the whole microcycle. A `WRITE-I-MEM`'s word is bypassed onto the I bus,
  as muir's `Rtl::read_phase` does.
- The scratchpad latches load on every tick. Each holds its word from the
  tick after the edge until the next edge.
- `-WAIT`, the wait for MD and the divider's hold stop a microcycle in whole
  K-tick cycles, with the master clock running and no write. Each is tested
  at the cycle's start.
- A console write lands at the master clock edge, and nowhere else.
- There are no speed bits and no speed synchronizer. The mode register's
  bits 1 and 0 go nowhere.
- `SINTR` is registered at the edge that ends each microcycle that runs,
  waiting or not, from the interrupt as it stands on that edge's own tick
  (muir's `Machine::interrupt_at`). A clock flag that rises inside a
  microcycle, or on the edge that ends it, is in it.
  `build/quux_tickwin.quux.k4l1.pass` puts rises at every tick of a
  microcycle and inside a wait for MD.

What stays in nanoseconds is everything on the bus side: the setup, strobe
and acknowledgment times, `-MFINISHD` and `-RDFINISH`, the Unibus figures,
the I/O board's clocks and the disk's spans. They are on the grid as they
are for the CADR. Only the master clock that samples them comes every K
ticks.

The traces QUUX is held to are taken at a K and an L named in their files:
`rtl.quux.k4.golden`, `quux_divmd.quux.k4l1.golden` and so on. `make check
MACHINE=quux` runs them at `SYNC_K` and `SYNC_L`, which are 4 and 0 unless
the command line sets them. It also runs the programs with `ILONG`
instructions at an L of one.

## What is not MIT's timing at all

Some tick counts in the tree name no nanosecond figure and must not be given
one. They are fabric choices measured in **board** ticks — real time — and
putting them on the grid would tie them to a number that has nothing to do
with them.

| Constant | What it is |
|---|---|
| `BEAT_T`, `GAP_T`, `LOSS_T` in `cadr_dbg_cable.sv` and its carrier | the debug link's own signaling rate, chosen against the cable's 11,050 ns deadline |
| `LOST_T`, `RESET_T`, `BOOT_T` in `cadr_console.sv` | how long the console holds a line, and how long it waits for the processing system |
| `WATCHDOG_T` in `cadr_debug_window.sv` | one second of real time before a wedged bus is released |
| `CLKIN_PERIOD_NS` in `xilinx7/cadr_hdmi_phy.sv` | the board's own oscillator, in real nanoseconds |
| `POWER_ON_EDGES` in `cadr_tick_pkg.sv` | how many edges after the reset edge the reference's power-on falls, as the processor and the bus interface count time |
| `HOLD_T` in `cadr_lamp_microcycle.sv` | how long the steady microcycle lamp stays lit after a microcycle, 2^22 ticks: longer than any stall of a running machine and shorter than a person takes to see a lamp go out |
| `DISK_LIT_T` in `boards/arty-z7-20/cadr_arty.sv` | how long the disk lamp stays lit after a block moves, the same 2^22 ticks for the same reason |

The test is whether the number answers a question about the CADR or a
question about this board. `RESET_T` is "long enough that the machine
notices", which is a fabric judgment with a floor and a margin.
`SETUP_T` is "the 80 ns the bus specification puts on the master", which is
the CADR's, and it derives from the grid even in
`rtl/plumbing/cadr_prove.sv`, where a witness built to honor the bus rule
would otherwise stop honoring it silently when the grid moved.

## If you are about to change an instant

1. Find it in the tables above and read its class. If it is free-running, ask
   whether you are changing a period or a phase.
2. Read every relationship that names it. There is usually more than one.
3. Check whether a timing constraint quotes it. Relationships 9 and 25 list
   the ones that do today, and `grid.pass` fails each one that no longer
   agrees with the grid.
4. If you are changing the grid itself, every home at the top of this
   document moves together, and `grid.pass` fails until they agree. The
   constraint literals of relationship 25 move too, and a count two instants
   come to share must say so in its tag. Every generator must run muir under
   the matching timing model. The oscillators follow on their own, and their
   starting parity becomes visible.
5. Regenerate every trace, and read what moved column by column before
   believing it. A mutation whose magnitude was one tick at the old grid may
   be no tick at all at the new one: 5 ns and 10 ns are the same tick at a
   10 ns grid, so every record that moves an instant by five nanoseconds is
   re-derived to one tick of the new grid.
