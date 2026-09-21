<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Questions

These are the questions this project is asked, each answered from the file
that settles it. The site's [FAQ page](https://muir-fpga.metebalci.com/faq.html)
gives each answer in a sentence or two and links here for the whole of it.

Every answer rests on a file, and the line under it names that file. Where
the material does not settle something, the answer says so rather than
filling the gap. A question with no source does not go in this file. MIT's
own files are cited at the path [muir](https://github.com/metebalci/muir)
gives them. The rest are files in this repository.

## The machine

### Why is there no disk multiplexor block?

MIT built one, and it is a board of its own: board type LG684, eleven drawing
pages, titled DISK MULTIPLEXOR. It hangs off the disk controller's edge
connector rather than sitting on a bus, and its work is electrical. It fans
the controller's one read and write path out to eight drives. It selects a
unit, decodes each drive's sector pulses into a block counter of its own, and
carries their attention and spin-up lines.

Without it the controller cannot drive the unit number at all. MIT's jumper
sheet has a one-board version whose jumpers are "not to be installed if this
DC is associated with a DM board", and they ground those lines so that the
single drive is unit 0.

Here there is nothing for such a board to do. A drive is a file in the card's
`packs/` folder, handed to the controller through a register face, so there
are no cables to fan out and no sector pulses to count. The fabric's
controller is held to muir's behavioral controller, which has addressed eight
units all along and wants no such board either. It selects among them by the
disk address's own `DA<30:28>`, as MIT's controller does. Nothing in these
files describes several machines sharing a drive through it. What they
describe is one controller reaching eight.

Source: MIT's `mit/cadrdc/dm.txt`, `dm.wls`, `dm.eco` and `disk.hand`, and
muir's `src/cable.rs` and `src/disk_controller.rs`;
[`docs/disk-controller.md`](disk-controller.md).

### Why is muir the reference, and what does "held tick for tick" mean?

A machine with no reference is a machine nobody can check. muir simulates the
CADR at three fidelities, and `rtl` is the middle one. It is the machine's own
two-phase clock, every datapath signal on it, and everything that is a matter
of *when*.

Each file in `rtl/machine/` has a muir type it is compared against over a
recorded trace, cycle for cycle. Every file in `rtl/plumbing/` says in its own
header that no muir reference exists for it, being held to a bus protocol or to
a property instead. `muir.commit` names the commit the traces were taken from,
so a trace and the muir that made it travel together.

Source: [`README.md`](../README.md); the header of `mutations/list.txt`.

### Why is a tick ten nanoseconds?

Because the design does not meet its timing with a clock of five nanoseconds.
With a clock of ten it does.

Two numbers are ten nanoseconds here, and they are different things. The grid
is the conversion from MIT's drawings into ticks: `TICK_NS` in
`rtl/machine/cadr_tick_pkg.sv` places every instant at the first 10 ns tick at
or after it. The tick is how long one lasts, which is the board's business, and
this board makes one ten nanoseconds.

The processor's microcycles and the machine's clocks run at the original
CADR's speed to within about 5%. A normal microcycle is 15 ticks, 150 ns, where
the drawings say 145 ns, and every microcycle is within 4% of the drawings. The
read taps are 8, 9, 10, 12, 13, 14 and 16 ticks. Main memory and the disk are
not timed as the original's were, and `README.md` compares them part by part.

The timing of the clock edges is close to the CADR's but not identical. The
CADR placed its clock edges with tapped delay lines, while the FPGA clocks
everything from one 10 ns clock. Eleven instants move later, eight of them by
five nanoseconds and three by seven, and none moves earlier. Every instant
keeps its order, so what the machine computes does not change. muir's
`--timing-model fpga` rounds the same way, so the references are generated
under the same grid.

The grid was five nanoseconds before, which kept every instant exact. The clock
was ten nanoseconds then too, so the machine ran at about half speed.

Source: [`docs/timing.md`](timing.md); the header of
`rtl/machine/cadr_tick_pkg.sv`; [`README.md`](../README.md).

### Does the machine's own clock agree with the wall?

Yes, while the grid and the tick are the same number. The I/O board's
microsecond clock counts 100 ticks, which is one real microsecond, and the
display's vertical interrupt arrives at the display board's own 64.70 Hz. MIT's
microcode uses that interrupt as its roughly-sixty-cycle clock.

At the five nanosecond grid the same clocks counted 200 ticks and a frame of
3,091,200, so a CADR wall clock lost half a day in a day, and on the board the
who-line advanced 31 seconds over 61 real ones.

Source: [`docs/io-board.md`](io-board.md), [`docs/tv.md`](tv.md),
[`docs/board.md`](board.md).

### Is the color TV four bits a pixel or eight?

Four, and nothing here implements eight. A pixel of the color screen is a
four-bit address into a map of sixteen colors, and each of those sixteen holds
three eight-bit channels. So the eight is the depth of a gun and not of a
pixel.

MIT's own software settles it. `COLOR:MAKE-SCREEN` declares the screen
`:BITS-PER-PIXEL 4`. `%COLOR-TRANSFORM` accepts only `ART-4B` arrays and traps
on anything else. And `lmtv.order` says of the map that "we only use a 16x8
subset of it". The board has one mode here and it is that one.

Source: [`docs/tv.md`](tv.md); muir's `src/tv.rs`, its
`COLOR_BITS_PER_PIXEL`, `COLORS` and `CHANNELS`; MIT's
`sys/window/color.lisp`, `sys/ucadr/uc-hacks.lisp` and `cadrtv/lmtv.order`.

### Why does the screen keep the previous boot's picture?

Because the real machine did. A reset on the display board clears the vertical
flag and nothing else. The mode register and the sync enable clear on a
separate power-reset wire, and the frame buffer has no clear of any kind.

MIT knew that and wrote the clear in software. `LISP-REINITIALIZE` calls
`CLEAR-SCREEN-BUFFER` under the comment "Clear all the bits of the main screen
after a cold boot". Elsewhere it takes care "to avoid bashing the bits of
whatever window was exposed before a warm boot".

Here the buffer is a region of memory no reset writes. So the previous world
stays on the glass until the band comes up and clears it.

Source: [`docs/tv.md`](tv.md); MIT's `sys/sys/ltop.lisp` in the System 100
release.

## The boards, and the way they are checked

### Why is the debug cable on one Pmod connector?

Because a board is a debugger or a debuggee and never both at once. Each
direction takes four of the header's eight pins: a strobe, a data line and two
guards. Neither group is ever driven from both ends, so one connector carries
the whole link in both directions at once.

A second connector would have bought exactly one thing: a chain of three
machines, where a board is one machine's debuggee and another's debugger at
once. Nobody needs that. On the two Zynq boards muir reaches the debuggee end
through a window of registers anyway.

Source: [`docs/debug-cable.md`](debug-cable.md).

### How does a board become the debugger?

A board with a cable in it and nothing said is a debuggee. That is the power-on
state, and it needs nothing set.

It becomes the debugger by `--debug-cable-connect` in `fpgarc`, which the disk
pack program's init script applies at boot through the console. It also
becomes the debugger by `cadr-console debug-cable-connect`, at any time.
`cadr-console debug-cable-disconnect` gives the role back, and
`cadr-console debug-cable` says which role a board holds. There is no listen
flag, here or in muir, because listening is what a CADR always does.

Source: [`docs/debug-cable.md`](debug-cable.md) again.

### Why are the checks themselves mutation-tested?

`make check` says the checks pass. `make mutants` says the checks can still
fail.

A mutation is a deliberate, small, wrong version of the design. The runner
applies one, rebuilds, and runs the check that is supposed to hold that part.
If the check passes anyway, the mutation survived, and that check cannot tell a
right design from that wrong one. Line coverage cannot see the difference,
because a line can be executed by every test and still be unchecked, nothing
having looked at what it produced.

Source: [`docs/mutations.md`](mutations.md).

### Why is there no ILA or other Vivado debug core?

It was meant to be one. The license used here is the free BASIC tier, which
refuses `create_debug_core` outright, so Vivado's scripted debug flow does not
exist. The ILA core does generate at BASIC, but it arrives as a directory of
generated XML. This project declines that for the same reason it declines the
clock generator's.

So the probe is a `BSCANE2` and a shift register, which is one primitive in a
file somebody can read. It fills from the first qualifying edge after reset and
freezes, so nothing has to be armed and nobody has to be at the board.

Source: the header of `rtl/plumbing/cadr_probe.sv`;
[`docs/toolchain.md`](toolchain.md).

### What license is this under, and what in it is not this project's work?

The fabric, the checks and their reference traces, the programs beside the
machine, the documents and the site are free software under the GNU Affero
General Public License, version 3 or later. Nearly every file repeats that in
its own SPDX header.

Eight files are under the GNU General Public License, version 2 or later, four
for each Zynq board, because each is compiled into U-Boot.

What is not this project's work is listed in [`docs/license.md`](license.md)
and on the site's front page. Each entry names whose it is and under what
terms, and says where no terms are recorded rather than guessing.

Source: [`docs/license.md`](license.md), and the front page's license and
third-party material.
