<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Before building the disk controller

Reconnaissance, measured 2026-09-09 at `871b467`, before a line of it was
written --- 56 commits before the memory path landed, so read that date on
anything below which says what does or does not exist. None of this is
derivable from the RTL because none of it is in the RTL: it is what muir has
to check against, what the two reference programs actually ask of it, and the
two decisions that came out of that. Written down because it is an
afternoon of reading and probing and nobody should repeat it.

## muir has no `rtl`-level disk controller

Every other block here is held to a muir structure with a clock in it ---
`cadr_phase_gen.sv` to `clock::Behavioural` tick for tick,
`cadr_busint_xbus.sv` to `busint::Busint` tick for tick, `cadr_microcycle.sv`
to `Rtl::signals()` microcycle for microcycle. The disk has **two** models and
neither is the middle one:

- **`src/disk_controller.rs`, behavioural**, and what muir's own `rtl` engine
  uses. No clock beyond `now`/`done_at`, no sequencer, no channel, no fifo. Its
  own doc: "the transfer completes inside the store to START rather than taking
  milliseconds, so the controller is never seen busy". The band issues
  transfers of **512 pages --- 131,072 words --- that way.** `timed` is off by
  default and muir's note says every count this project quotes was measured
  with it off; turning it on moves the boot by 21% and fails 19 tests.
- **`data/CADRDC.netlist` with `newdsk.31`**, assembled by `src/dcmicro.rs`
  into three 512x8 74S472s --- a 512 x 24 control store --- and exercised by
  `tests/cadrdc_netlist.rs`. That is `chip` fidelity: the sequencer, the fifo,
  the tag lines and a drive on a cable.

There is nothing between them. **This is why the fidelity question exists at
all**, and it is worth knowing before starting rather than after.

`tests/disk.rs` is the property list worth mining --- about fifty named
behaviours, each a candidate row of a generated stimulus.

## What the two reference programs actually ask of it

Measured with a throwaway probe against muir. `Controller`'s fields are
private, so **its own `save` is the window on them**: `Controller::save` writes
them in a fixed order into a `checkpoint::Writer`, and the prefix parses back
out --- reading the model rather than guessing at it. Bus cycles were sniffed
off `busint().busy()` and `writing()`, with `Machine::translate` for the
physical address and `Machine::md` for the word a write carries. 2.2M
microcycles run in 2.4 seconds.

### MIT's boot PROM, no drive, 600,000 microcycles

    11,301 reads of register 0        the status register
     5,650 writes of register 2       the disk address register
    ------
    16,951 cycles of 17,466 in the whole run

**No command is ever written**, and the status is `0x2321` throughout: `<0>`
not active, `<5>` no unit selected, `<8>` not on cylinder, `<9>` not on line,
`<13>` transfer aborted. That is `AWAIT-DRIVE-READY` polling a cable with
nothing on it, and it is exactly what the board is doing today --- the 16,951
is the same figure `docs/board.md` reports off the hardware.

### A System 100 band, 2,200,000 microcycles

3,295 register cycles: 530 reads and 692 writes of register 0, and 285 reads
with about 405 writes of each of the other three.

    commands used     read 0, write 0o11, read-compare 0o10,
                      recalibrate 0o1005, fault clear 0o405,
                      and clearing the register to 0
    never used        read all 0o02, write all 0o13, seek 0o04, at ease 0o05,
                      offset clear 0o06, reset 0o16, and every one of
                      1, 3, 7, 12, 14, 15, 17
    status bits set   <0> <1> <2> <3> and the block counter --- no error
                      bit, ever
    pages a transfer  1 to 512
    PROMDISABLE at    microcycle 1,410,035

The microcode writes **bit 21** of the command register (`0o10001005` for the
recalibrate), which `Controller` ignores.

The opening sequence, which is what a fabric controller has to satisfy first:

    537853  reg2 <- 0            DA: unit 0, cylinder 0, head 0, block 0
    537872  reg0 <- 0o405        fault clear
    537875  reg1 <- 0o777        CLP, and a physical address
    537966  reg2 <- 0 ; reg3 <- 0    START
    537991  reg0 <- 0o10001005   recalibrate
   1062408  reg0 <- 0o11         write a block, read-compare it, then read
   1062916  reg2 <- 0o400        and then walk the pack, head by head

The band writes to the pack at 1,062,408, which is why its image must be opened
read-write and why a trace against a working copy is not reproducible ---
`golden/src/rtl_sys.rs` has that part.

### The conclusion those support

**A check driven only by the band tests the happy path and nothing else.** Ten
of sixteen command codes unreached, and not one error bit ever set. That is the
same shape as the control store whose only exercise wrote zero to all 16,384
words, where dropping the write pulse for all but one address survived.

So **the generated stimulus is primary** and has to reach every code and every
reachable bit, and the band's own traffic is the second reference --- optional,
skipped without the release archive, the way `rtl.golden` and `rtl_sys.golden`
already divide. It is the band that proves the machine can boot; it is the
generated program that proves the controller is right.

## The two decisions

**Port the behavioural controller, behind a seam the gate-level one could
replace.** Everything here is held to what muir's `rtl` engine uses, and `Rtl`
uses `Controller`. Holding the disk to the CADRDC netlist instead would hold
one block to a fidelity the machine it plugs into does not have, and the
composed check could then no longer compare it against `Rtl` at all --- a
better-checked block that the project's own top-level check could no longer
see. CLAUDE.md points the same way: the netlists are read for provenance, and
`rtl` is the word this project works at.

**The drive carries three words a block beyond its data**: the header word, the
header checkword and the data checkword. So `STATUS<18>` header compare,
`<17>` header ECC and `<16>` a data checkword that does not check can all fire.
What is given up is `<15>`, ECC soft, and with it the ECC register's burst
location, `Ecc::trap` not being in fabric. 1.2% of the store, and additive
later.

The alternative --- data only --- was rejected on the measurement above: those
four bits would be dead in the fabric *and* never exercised by the reference
either, so nothing would ever notice they were wrong.

## What the check can and cannot hold to

**Cannot: the duration of a transfer.** `Controller` moves up to 131,072 words
inside one Xbus write; fabric takes bus cycles. So the comparison is at
*quiescence* --- the testbench runs the module until it is idle and compares
there --- and the interval where the fabric reports itself busy and the model
never does is a parting of the same kind as `busint.rs` seeing the future. It
makes the fabric **more** like MIT's board than the model is: the board is busy
for milliseconds and `DISK-WAIT` exists to poll it.

The only bound available on that interval is the gap to the next access, and
the band gives a measured one: about 3,000 microcycles between transfers, 660
us at 220 ns a microcycle. A fabric slower than that is slower than the
machine's own spacing.

**Can, tick for tick, and these are the two worth taking:**

- **The block counter, `STATUS<31:24>`.** `disk_unit::turn` lays the
  revolution out: 18 regions, region `k` beginning at `k * SECTOR_NS` with the
  index at zero, `SECTOR_NS` 968,448 ns and a revolution 16,666,667, so the
  last region is the track's 203,051 ns leftover. The count steps to `k` as
  region `k`'s pulse ends --- `INDEX_PULSE_NS` 4,000 at region 0 and
  `SECTOR_PULSE_NS` 1,240 elsewhere --- and holds the region before through the
  pulse. Sampling either side of all eighteen trailing edges is what catches a
  counter clocked on the other one. CC's `DCHECK-BLOCK-COUNTER` wants every
  value 0 to 17 and no other.
- **The timeout.** `TIMEOUT_NS` is 2.56 s: the 74LS124 at DCTMOT 0B04 section 1
  at 20 ms, divided by 128 by the 74393 at 0C03. **That is 512,000,000 ticks of
  the fabric's 200 MHz clock**, so running every hanging code out to it would
  cost more than the rest of `make check` together. One full-length hang, and
  the rest checked for the hang itself, which is visible on the store to START:
  `Controller::hang` charges `done_at` whatever `timed` says, so `STATUS<0>`
  goes to zero at once.

**Four status bits `Controller` never sets**, so nothing can reach them and the
next person should not go looking: `<23>` internal parity (the board's two
running accumulators), `<19>` memory parity, `<12>` start block (the board has
a detector and this has none), `<4>` multiple units selected. And `<21>` CCW
cycle is set and cleared inside one store, so no read can ever see it.

**A blank pack reads zeros.** Every block a generated program reads has to be
written with distinct content first --- a function of both the block and the
offset within it, so that neither a wrong block nor a wrong offset reads back
as the right word --- or a read that never happened reads back exactly like one
that did. Same fix as bringing the control store up all ones, and the same
reason.

## A gap in the seam, found while reading

**~~`cadr_machine.sv` brings out `dev_rq`, `dev_write` and `phys`, and not the
word.~~ Closed at `b562621`.** `cadr_memory_path.sv` had `wdata` and its own
comment calling `phys` and `wdata` "the address and the word" for a slave that
is not main memory, and the machine's boundary dropped it: an Xbus device could
have been written to and never seen what. `dev_wdata` is a port of
`cadr_machine` now and the mutation this paragraph asked for is in
`mutations/list.txt` --- together with what it found, which is that all 5,650
device writes the boot PROM makes carry the same word and that word is zero.
So a rotation of `dev_wdata` is an equivalence on that trace rather than a
hole, and `build/machine.pass` counts the distinct words on the seam and says
so if the count ever rises above one.

The controller is also a bus **master**: the memory channel fetches its CCWs
and moves its pages over the Xbus, and `cadr_machine.sv` has no provision for a
second master on it. That is the other half of the same seam.
