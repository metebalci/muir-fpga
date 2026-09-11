<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The whole machine on a band, and where the comparison has to stop

Every processor check in this repository compares `cadr_microcycle` against
muir with the bus, the memory and the acknowledgements supplied from muir's own
columns. `machine.pass` and `map_boot.pass` compare the whole machine, but they
run MIT's boot PROM, which stops before the microcode is loaded. So the
composed machine — the processor with the real bus interface, the real memory
path, real memory behind it and the disk controller under it — had never been
compared against muir while running microcode 323 at all.

`tb/cadr_band_tb.cpp` is that comparison, and `make band` runs it. This
document is what it found, and why it can go no further than it does.

## What it is

`cadr_machine` runs from reset against `build/rtl_sys.golden`, the System 100
band trace, with nothing driven nearer than the memory port and the block
store's seam.

- **The memory** is a store keyed by `mem_addr`, zero where nothing has written
  it, which is what `Machine::with_memory_boards` gives muir. The answer is
  placed where muir's own bus interface placed it, out of the trace's `ack`
  column. A memory of no access time is not muir: `Responder::Memory` goes
  through `MemoryBoard::request`, which has the board's own refresh in it, and
  over the boot PROM's parity loop its answers land 573 and 608 ns after the
  grant where a device's land 140.
- **The pack** is a fresh copy of the release image, opened read-only, and a
  block the machine writes is kept in memory for the run exactly as muir's
  `Unit::written` keeps it. The block served is the one at the disk address the
  controller itself posted over the request path; an address off the pack is
  denied rather than invented. The header and both checkwords are computed from
  the address and the data at the move.
- **The drive** is one unit present, writable, and its own time not charged,
  which is `Controller::timed` false and the way the reference is generated.

Twenty-two columns are compared every microcycle: PC, IR, LPC, OPC, ST, LC, the
A and M buses, the ALU, R, OB, Q, DC, VMA, MD, `-VMAOK`, JCOND, NOP, PCS1,
PCS0, IWRITED, PROMDISABLE and `-XBUS.INTR`.

## What it reaches

**1,062,507 of the band's 2,800,000 microcycles agree exactly**, with no
exemption of any kind, and with the fabric's clock and muir's the same to the
nanosecond over the whole of it. Measured at `822535c`.

Of those, 524,650 are past microcycle 537,857, which is where this trace and
the boot PROM's part company. They are a program no other check runs on the
whole machine, and through them the disk controller answers out of a real drive
— unit selection, the spindle, on-line, on-cylinder, seek and attention —
instead of the no-drive constant `0x2321` that a wire would satisfy.

What it does not reach is worth as much. The machine never leaves the boot PROM
in this span, no pack block ever reaches main memory, and the map is never
written with an asymmetric access code — which is the half of the map the board
halts in. **And the pack's content is not checked: a pack of zeros passes, and
that was measured rather than assumed**, because the comparison ends before the
first block's words reach memory. What is held is that the seam ran and that
the disk address came from the fabric.

## Why it stops, and why that is not a bug

It stops at the machine's first disk transfer. muir's channel does not exist as
a bus master: `Controller::transfer` writes straight into main memory, and
`Controller::timed` is false, so `done_in` finishes every operation at the
instant it starts. The fabric's channel is a second Xbus master — 256 bus
cycles a page through the arbiter, plus 261 ticks to put each block through the
store's seam a word at a time. So at reference microcycle 1,062,507 the boot
PROM reads the disk status register, the fabric's channel is still walking and
still waiting for its block, and `STATUS<0>` not-active reads 0 where muir
reads 1.

This is the program and not a rare event to be exempted: the trace carries 457
disk interrupts, 225 of them before the cold load ends.

**The cost is small and the consequence is total**, and `--observe` is what
says so. Let the fabric go on running past the point of comparison and it
reaches `PROMDISABLE` — the microcode loaded off its own pack and the boot PROM
let go — at its own microcycle 1,418,045 against muir's 1,410,035. That is
8,010 microcycles more, 0.57 per cent, for 153 transfers and 1,895 blocks, with
21,875 microcycles spent inside `ch_active` in total. The fabric is not slow.
It is simply never at the same instant as a model whose channel takes none, and
a microcycle-for-microcycle comparison has no tolerance for that at all.

## Three ways round it, all built and all measured

They are kept as flags on the testbench because what they print is the reason.

**Hold the reference and let the fabric catch up** (`--absorb`). The machine is
only going round a wait loop more times, so the obvious rule is to hold the
reference row until the fabric's whole sample is that row again. It never
rejoins. The near misses say why: `OPC` and `LPC` are the eighth and first
stages of the shift register of past PCs, so a machine that waited longer
carries that, and the state it arrives in is not the reference row and does not
become it. A machine's history is part of its state.

**Charge the drive's own time, on both sides** (`--timed`). This is the one
change that makes the two channels finish together, because the fabric's 256
bus cycles fit inside the drive's seek and rotational wait and `elapsed` counts
the wait off the access time. It works as far as it goes: two real pack blocks
move into main memory and the machine does not notice, and the two clocks stay
within 150 ns over 1,076,016 microcycles. Then the drive's block counter,
`STATUS<28:24>`, reads one apart, because 150 ns is enough to put the spindle on
the other side of a sector pulse. It needs a reference generated with
`m.disk.timed = true`, which this repository does not have; the figures here
were taken against one made in a worktree.

**Let a disagreement stand for a bounded number of microcycles** (`--tolerate`),
in lockstep, both machines executing the same microcycle and differing about a
value in it — which is exactly what a spindle one region out is. With the drive
timed and a bound of 16 microcycles it reaches 1,205,508, with nineteen bursts
of 89 microcycles in all and every one of them confined to `STATUS<28:24>`. At
a bound of 512 it reaches 1,276,905 **and a burst appears that moves PC, IR and
VMA** — the exemption beginning to hide the machine rather than the clock. That
is this project's standing hazard caught in the act, and it is why the default
is zero.

## And the wall no exemption can climb

Even with a perfect clock this shape cannot reach the divergence window. The
band's machine reads its own microsecond clock — Unibus `0o764120` and
`0o764122`, the I/O board's counter — **476 times, the first at microcycle
2,087,406**, and the value is elapsed microseconds. Those two addresses and
`0o766040` are the only three Unibus addresses the whole 2,800,000 microcycles
touch, 476, 476 and 240 times. The window that wants searching, 2,093,261 to
4,441,390, begins 5,855 microcycles after the machine has started reading a
number that is a function of the instant it is at. Two machines that are not at
the same instant read different numbers there, and the difference goes into the
machine rather than past it.

So extending `rtl_sys.golden` past 2,800,000 microcycles would not help, and it
was not done.

## What would close it

Three things, in the order they are worth doing.

1. **A reference whose channel takes the bus.** The real fix is on muir's side:
   a disk channel that moves a block a word at a time, over the Xbus, taking
   the time the fabric takes. Then the two machines share a clock for the same
   reason the processor's two halves already do, and this comparison runs as
   far as the trace does. That is a decision about muir and about every count
   this project quotes, not a change to make quietly.
2. **A directed check of the routine the board halts in.** `map_boot.pass`
   already writes a second-level map entry on the boot PROM and reads through
   it, and its own output names what it cannot reach: every map word the boot
   PROM writes has `MAP-ACCESS-CODE 3`, both bits alike, so the two access bits
   cannot be told apart, and `-VMAOK` is compared only in its permitted
   direction. `PDL-BUFFER-REFILL`'s `0o27200352` is asymmetric. A check that
   writes that word and reads through it needs no band and no pack.
3. **Promoting `make band` into `make check`.** It costs twenty-five seconds
   and skips without the release. It is phony today because a `.pass` file
   would make the mutation runner report a check that nothing mutates, and
   aiming a record at it first needs an entry in that runner's `CHECKS` — a
   record naming a check the runner has no entry for kills the whole run at
   parse. The two changes go together.
