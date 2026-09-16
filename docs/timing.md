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

## Where the grid lives

The conversion from MIT's nanoseconds into ticks is one number with three
kinds of home. They must move together, and `make check` holds them to it.

| Home | What it covers |
|---|---|
| `rtl/machine/cadr_tick_pkg.sv` | the fabric: `TICK_NS` and `ticks(ns)` |
| `tb/cadr_tick.h` | the testbenches: `kGridNs` and `GridTicks(ns)` |
| `golden/src/busint_regs.rs`, `busint_xbus.rs`, `color_tv.rs`, `disk.rs`, `iob.rs`, `phase_gen.rs`, `trace.rs`, `tv.rs` | the reference side, one `TICK_NS` each |

**The grid is not the length of a tick.** How long a tick lasts is the
board's business: `boards/arty-z7-20/cadr_arty.sv` makes it 10 ns, so the
machine runs at half the speed the hardware ran at while every instant keeps
its exact ratio to every other. The two tens are unrelated numbers that
happen to match. One is a divisor in the package and one is a clock period in
the board file.

**Rounding is always up.** `ticks(ns)` is `(ns + TICK_NS - 1) / TICK_NS` and
never a plain division. Truncation collapses MIT's 5 ns instant to zero ticks
and puts SELECT on top of a read tap. It also makes the fabric sample
*earlier* than the real machine did, which is the wrong direction for a setup
time, a deskew or a strobe: each of those is a promise that something has
settled.

**The reference side is the half that cannot be checked by building.** The
eight Rust constants belong to separate binaries with no shared library, so
they are not unified here. They are load-bearing: `golden/src/disk.rs` writes
tick counts into the trace (`# ticks {}`), and `color_tv.rs` asserts that the
display's frame divides by the grid. Moving the fabric's grid without moving
these would change what the traces mean, and nothing in the build would fail.
That is why `tools/grid_check.py` exists. It runs as `grid.pass`, finds every
home, and fails when one is missing or when two disagree.

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

### One refinement, which is why exactly two constants keep their period

Class 3 divides again, and the halves behave differently.

- **Rounding a free-running PERIOD drifts without bound.** The error repeats
  every period and accumulates, so every answer synchronized to that
  oscillator moves further as the run goes on.
- **Rounding a free-running PHASE is a single error under one tick.** It is
  applied once, at power-on, and never again.

The I/O board already rounds a phase, deliberately: the half-microsecond
clock the serial port's select is synchronized to sits at 203 ns modulo 500
from power-on, and `HU_FIRST_T` rounds it up. The module says so at the
constant, and the reference trace carries a `slip` column rather than a
tolerance, so the rounding is a stated instant and not a fudge. The
microsecond counter's low half at 313 ns is rounded the same way.

So the constants that must not be rounded are precisely the free-running
**periods that do not divide by the grid**, and there are exactly two:

| Constant | Period | At a 5 ns grid | At a 10 ns grid |
|---|---|---|---|
| `VCO_HALF_NS`, `rtl/machine/cadr_busint_xbus.sv` | 425 ns | 85 ticks, uniform | 42.5 — alternates 43 and 42 |
| `FCLK_NS`, `rtl/machine/cadr_io_board.sv` | 125 ns | 25 ticks, uniform | 12.5 — alternates 13 and 12 |

Both keep their period in nanoseconds and advance an accumulator by the grid
each tick, so neither is ever rounded. Writing the alternation out instead
would hard-code one particular grid in a second place, which is the thing
having a single grid constant exists to prevent.

The other free-running constants are on the grid because they happen to
divide: the microsecond clock's 890 ns first edge and 1,000 ns period, and
`KB CLK^` at 8,000 ns. **They are safe by arithmetic accident and not by
design**, which is why the class needs naming even though nothing is
currently wrong with them.

### The pattern all of them use

Every oscillator in the machine keeps its period in nanoseconds and advances
it by `TICK_NS` each tick, which is exact at any grid:

- the I/O board's sixty-cycle clock, `mains_acc` in `cadr_io_board.sv`, whose
  16,666,666 ns period is 1 modulo 5 and so lies off the grid at every tick;
- the serial line's crystal, `XTAL_WRAP` in `cadr_serial_line.sv`, which adds
  a frequency each tick and wraps at `1_000_000_000 / TICK_NS`;
- the disk controller, which counts every span down in nanoseconds by
  `TICK_NS` a tick, reaching zero on exactly the tick a counter loaded with
  `ceil(span / TICK_NS)` would;
- and, since this document was first written, the timeout oscillator and
  FCLK, which were tick counters and are now accumulators of the same shape.

**The wrap subtracts the period and never clears.** Clearing discards the
remainder, and carrying the remainder is the whole of the difference: a
cleared counter loses a little every period and its phase walks away.

**The starting parity is a decision and is stated at each constant.** Both
accumulators are zero when their oscillator starts, which makes the first
period the longer of the two wherever the grid does not divide the period —
43 ticks then 42 for the timeout oscillator at a 10 ns grid, 13 then 12 for
FCLK. At the 5 ns grid the machine runs at, every period is uniform and the
parity does not arise. At a grid that does not divide the period, no starting
value keeps every edge on the reference's instant.

**The timeout oscillator starts two edges after the reset edge, not at it.**
The reference counts it in whole periods from its power-on, which is the
instant the ring starts. The ring starts on the first edge reset is low. The
processor and the bus interface then register a grant on the edge after the
ring makes its boundary. So in the frame the grants are counted in, power-on
is two edges after the reset edge. `POWER_ON_T` in `cadr_busint_xbus.sv` puts
the oscillator's start there. It is a count of the fabric's edges, so it is
two at any grid.

It used to start at the reset edge, and every cycle nothing answered was
acknowledged two ticks before the reference's. That was issue #21. It was
measured on the whole machine by reading the oscillator itself, whose rises
fell at 840 modulo 850 of the reference's time. The two suspects the issue
first named were not the cause. The timer takes each edge on the same clock
edge the oscillator's output takes it. The machine check reads every
acknowledgment one tick late, but that tick was already in every
acknowledgment it compares, and the check now measures it on 16,951 device
cycles in the same run.

The checks that hold the bus interface to the reference outside the whole
machine now use the same frame. `busint_xbus`, `memory_path`, `tv` and
`color_tv` put the reset edge and one idle edge before their first row, and
`unibus` puts them before the tick it counts from. So their zero is the
reference's power-on, as it is in the machine. They used to reset on that
zero, which is why all five passed with the oscillator two ticks early.

The I/O board's free-running clocks also start at the reset edge. No check of
the whole machine compares them against the reference, so whether they carry
the same two ticks is not established.

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
| master setup before `-XBUS.RQ` | 80 | T | `busint::SETUP_NS`, `xspec.text.3` | `SETUP_T` | 16 | 8 |
| read deskew, TD100 at REQLM 0C09 | 60 | T | `busint::XBUS_ACK_NS` | `DESKEW_T` | 12 | 6 |
| `-SACK` to the grant | 200 | T | `busint::UNIBUS_SELECT_NS` | `UB_SELECT_T` | 40 | 20 |
| grant to `-UB MSYN` | 100 | T | `busint::UNIBUS_ADDRESS_NS` | `UB_ADDRESS_T` | 20 | 10 |
| `-UB SSYN` to `-LMACK` | 150 | T | `busint::UNIBUS_ACK_NS` | `UB_ACK_T` | 30 | 15 |
| `-UB SSYN` to the MD strobe | 100 | T | `busint::UNIBUS_STROBE_NS` | `UB_STROBE_T` | 20 | 10 |
| timeout oscillator, half period | 425 | F | `chip::VCO_PERIOD` | `VCO_HALF_NS` | 85 | 43 then 42 |
| timeout oscillator starts, edges after the reset edge | — | fabric | the reference's power-on in the frame grants are counted in | `POWER_ON_T` | 2 | 2 |

### The processor — `rtl/machine/cadr_microcycle.sv`

| Instant | ns | Class | Source | Constant | 5 ns | 10 ns |
|---|---|---|---|---|---|---|
| SPEEDCLK, the speed synchronizer | 60 | R | `clock::TPR60_NS` | `SPEEDCLK_T`, less one | 12 | 6 |
| `-MFINISHD`, TD50 at VCTL1 1D23 | 30 | T | `busint::MFINISHD_NS` | `MFINISHD_T` | 6 | 3 |
| `-RDFINISH`, TD250 at VCTL1 1D22 | 140 | T | the tap ordering | `RD_FINISH_T`, less three | 28 | 14 |

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
| the store hold | two ticks | fabric | `STORE_HOLD_NS` |
| the read hold | one tick | fabric | `READ_HOLD_NS` |

## The relationships

These are the invariants *between* instants. They are what makes changing one
number dangerous, and they are the reason this document exists.

| # | Invariant | Why, and where it is written |
|---|---|---|
| 1 | **A generator cycle is the read tap plus the restart.** 85 + 60 = 145 ns, 29 ticks at normal speed. | `Speed::cycle_ns` is `read_phase_ns(ilong) + RESTART_AFTER_READ_NS`. Every cycle length in the machine follows from its tap; none is written down separately. |
| 2 | **The write-pulse family is measured from the END of the read phase; TSE, SELECT and `-TPR60` are measured from `-TPR0`.** | `cadr_phase_gen.sv` computes `wp_on_at` as `read_sel + WP_ON_T`, while `tptse` compares against `TSE_OFF_T` directly. They are two different origins, which is why they cannot collide however the tap moves. |
| 3 | **The write pulse is 15 ns wide**, `WPIRAM_OFF` minus `WP_ON`. The width is the claim, not either end. At a 10 ns grid both ends round up separately and the pulse is 20 ns wide. | `clock.rs`: "no signal on the board is derived from the pulse's width" — so what matters is that the control store sees a pulse at all, and both ends must move together. |
| 4 | **The write pulse is clamped to the cycle boundary.** The board's `-TPW70` outlives `-TPDONE` at 60 by 10 ns; the model takes `WP_OFF_NS.min(RESTART)`. | `clock.rs` at `RESTART_AFTER_READ_NS`: "the write pulse of one cycle overlaps the start of the next by 10 ns". With no gate delays in fabric, an unclamped pulse would write at the next instruction's address. |
| 5 | **ILONG adds exactly 40 ns to a read tap, except at extra slow.** | `Speed::read_phase_ns`. At extra slow 160 ns is already the longest tap the chain provides. Held by `extra-slow-stretches-with-ilong`. |
| 6 | **SELECT falls after `-TPR60` and before the earliest read tap: 60 < 65 < 75.** | `clock.rs` at `SELECT_NS`: "after SPEEDCLK at 60 has clocked the synchronizer and the board has settled, before the earliest tap at 75". In ticks that is 12 < 13 < 15, and at a 10 ns grid 6 < 7 < 8 — the ordering survives, with nothing to spare. Held by `the-read-phase-is-selected-at-the-start-of-the-cycle`. |
| 7 | **`-TPR60`'s window is `TPR60_ON` to `TPR60_ON + TPR_PULSE_NS`**, 60 to 100 ns. | The `-TPR0` pulse is 40 ns wide and every read tap is that pulse delayed, so the window's width is the pulse's. |
| 8 | **SPEEDCLK is `-TPR60` inverted, and two modules name the same instant.** `cadr_spy_registers.sv` uses `ticks(60)`; `cadr_microcycle.sv` uses `ticks(60) - 1`. | The processor compares against its own phase counter, which is a tick behind the generator's, so it must test a tick early. The two must move together and a reader meeting only one of them will not know that. |
| 9 | **The bus master's 80 ns of setup is 16 ticks, and a timing constraint claims exactly 16.** | `rtl/plumbing/xilinx7/cadr_ddr.xdc` writes `set_multicycle_path -setup 16`, on the strength of the same sentence from `xspec.text.3` and nothing else. `the-setup-time-is-short` is the mutation one tick outside that bound: the check that catches a fabric which stopped honoring the 80 ns is the check that would catch a constraint claiming it wrongly. **If the grid moves, this constraint moves with it.** |
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
| 20 | **The receive buffer is read at the first `FCLK^` edge at or after `-MSYN` plus 33 ns.** | A threshold measured from an event, resolved against a free-running clock: `RBUF_SETUP_T` is triggered and on the grid, `FCLK_NS` is the oscillator and keeps its true period. |
| 21 | **The disk's store hold is two ticks and its read hold is one, and every timer a START loads is loaded that much short.** | So that what expires expires at the reference's instant despite the register on the counter's output. These are the one place a *fabric* concession is expressed in nanoseconds, and they move with the grid by construction. |
| 22 | **The sixty-cycle clock accumulates and never reloads.** Its period is 1 modulo 5, so a counter that adds the tick and subtracts the period is exactly `now mod SIXTY_CYCLE_NS`; one that reloads with zero loses four nanoseconds a period. | Held by `iob-the-mains-counter-reloads-not-accumulates`. |
| 23 | **The display's frame divides the grid exactly**: 15,456,000 ns is 3,091,200 ticks at 5 ns. | `golden/src/color_tv.rs` asserts `FRAME_NS % TICK_NS == 0` and would fail rather than round. A grid that does not divide the frame breaks that assertion, which is the one place the reference side checks the grid at all. |
| 24 | **The timeout oscillator's PHASE, not its period, is what the acknowledgment instant carries.** The grant only opens the oscillator's output; it does not start it. | This is why a one-tick shift anywhere in the reset network moves every NXM answer: `the-memory-path-leaves-reset-a-tick-late` delays only the memory path's reset and is caught. The oscillator starts `POWER_ON_T` edges after the reset edge, which is the reference's power-on in the frame the grants are counted in, and `the-timeout-oscillator-starts-a-tick-before-power-on` holds that from the whole machine. Issue #21 was this phase and nothing else: the oscillator started at the reset edge, so every cycle nothing answered was acknowledged two ticks early. **Anything that changes when this counter starts, how long its period is, or how many edges the ring and the processor put between the reset edge and a grant, changes the answer on every cycle nothing answers.** |
| 25 | **Four timing constraints and their flows write grid-derived tick counts as literals.** Fifteen is the fast read tap, 75 ns. Sixteen is the bus setup, 80 ns. Thirty is the register strobe, 150 ns. Each hold is one less than its setup. | Fifteen: `cadr_machine.xdc`'s relaxed set, `-to $probe_stable` in both boards' `cadr_probe.xdc`, and `assert_multicycle_applied` and `assert_instance_timing` in `fit.tcl` and both boards' `bitstream.tcl`. Sixteen: `-to $bus_word` in `cadr_machine.xdc`, `-to $contract` in `cadr_ddr.xdc`, and the flows' assertions. Thirty: `-to $ub_strobe` in `cadr_machine.xdc` and one assertion in each `bitstream.tcl`. **None of these follows the package, and `grid.pass` does not hold them.** A grid of 10 ns makes them 8, 8 and 15. The six in `cadr_debug.xdc` and `cadr_debug_pmod.xdc` is the debug link's beat in board ticks and is not on the grid. |

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
| `POWER_ON_T` in `cadr_busint_xbus.sv` | how many edges after the reset edge the reference's power-on falls, as the processor and the bus interface count time |
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
   the ones that do today, and each would silently become a false claim.
4. If you are changing the grid itself, every home at the top of this
   document moves together, and `grid.pass` fails until they agree. The
   constraint literals of relationship 25 move too, and nothing checks them.
   The four oscillators follow on their own, but their starting parity
   becomes visible, and at such a grid no starting value keeps every edge on
   the reference's instant.
