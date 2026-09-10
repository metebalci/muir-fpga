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
This paragraph once gave up `<15>`, ECC soft, and with it the ECC register's
burst location, on the grounds that `Ecc::trap` was not going into fabric ---
without a cost attached. The cost was then measured: one 32-bit LFSR and a
16-bit step counter, 34,753 spin shifts and at most 8,193 scan shifts, 214.7 us
worst case at one shift a tick, under a quarter of a block's own 968 us on the
pack. So the decision was re-taken and **`Ecc::trap` is in fabric**: `<15>` and
the ECC register are live and compared on every face after a START, and the
trace plants a burst at bit 1000 and reads pattern `0x19` at position 1001
back out of register 3. The two bad blocks in the trace cost 37,061 and 44,250
ticks of trapping.

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

## The pack side, built

Written at the slice that replaced the block store's seam, so read the
"before building" prose above as history: the drive has its channel and its
pack side now. What was decided here, and what was measured.

**The pack in DDR is muir's `Unit` split down the middle.** `Unit` is a
file plus two tables --- `headers` and `data_checkwords`, the sectors a
Write All laid down with something other than the format's own header and
checkwords. On the board the file is in DDR and Linux is the drive: it
decides which block goes in which of the store's 24 slots, hands the fabric
**the block's address**, and takes a written block back. The seam between
the drive and the controller is exactly the one the trace testbench drove
from `BLK` rows --- 259 words a slot and a tag --- with `rtl/cadr_disk_pack.sv`
on the drive's side of it. Nothing in fabric computes a header or a checkword
for a fetched block; Linux does, as `Header::of` and `Ecc::over` do for a
block nothing laid, and keeps what a write-back hands it.

**The record is the 259 words at the block's address**: word i at
address + 4i, low byte first, so the 256 data words are the pack file's
own 1,024 bytes unchanged and the header, header checkword and data checkword
follow at +1024, +1028, +1032. A 64-bit beat at + 8k carries words 2k and
2k+1. Eight AXI3 bursts of sixteen beats and one of two; the last beat goes
out with its low half strobed and its high half not, so the word after the
record is never written. **The address must be 128-byte aligned** so that
no burst crosses 4 KB, and an unaligned one is refused rather than masked.
The Python model (`~/.cache/pack/packmodel.py` at the slice, thrown away)
reproduced every `BLK write` and `PAGE` row of the trace with the store
filled only through modelled records before a line of the RTL was written.

**Linux writes five words and reads one more**, at `0x4000_0000` on
`M_AXI_GP0`: `ADDR`, `TAG`, `SLOT`, `CTL` (fetch, write back, take away; and
busy, done, error, refused, `ch_active`, `store_miss` read back), `DRIVE`
(present, read-only, timed --- the drive seam, eight units of it) and
`IDENT`. Anything outside the sixty-four bytes is SLVERR. Kept minimal on
purpose: the block moves at Linux's word and the CADR never waits on Linux.

**A fetch takes the slot away first and writes the tag last**, which needed
one change to the controller: a tag written with bit 31 set clears the
slot's valid bit, and Linux can take a pack away with it. **And the interlock
is mutual.** A request while the channel is walking is refused, not queued;
and a walk STARTed while the pack side is moving a block defers its first
command-list fetch until the move is over, the wait coming off the access
time like the rest of the walk. Mutual because the pack side reads
`ch_active` through a register --- the controller's state reaching its
enables was -0.530 ns on the DDR=1 board --- and a register is a tick
behind: the controller announces a START two ticks ahead from the store's
own hold registers, and the deferral covers the tick the announcement
cannot. So a walk that meets a fill waits and reads the block whole, neither
a miss nor half old and half new. Held by `tb/cadr_disk_pack_tb.cpp`, which
STARTs a Read as a fetch begins and asks for a fetch in the middle of a
42,946-shift `Ecc::trap`.

**~~Fetching on demand is deliberately not built.~~ Built, at the request
path's slice: see "The request path, built" below.** What stood here was
the decision the Linux program's author then found wanting --- a block the
walk asked for and was not given stopped the transfer, and nothing on GP0
said which block. The wait does sit inside a transfer whose time the trace
compares, and the trace never sees one, for the reason given there.

**The register store is held one tick, and the timers it loads are loaded
one tick short.** Found by the first fit with the drive present: the decision
to store was made from the bus interface's tick counter --- `elapsed`
reaching the 80 ns setup makes `-XBUS.RQ`, which makes the controller's
`asked`, which through "a write, not taken, into register 3, a transfer, a
drive present" reached the clock enable of every drive register --- seven
logic levels, 6.8 ns, 3,620 of 23,423 endpoints failing by up to 2.077 ns
on the DDR=1 board where the baseline met at +0.030. The remedy is the one
`cadr_machine.xdc` prescribes for a signal read once a bus cycle: the
acknowledgement stays a gate exactly as -MEMACK on a write does, and the
registers take the store a tick after the request, from copies of the word
and the register number registered every tick with no enable. Nothing on the
bus can see 5 ns in a register --- the next cycle is 145 ns away --- except
the trace, which samples every timer a START loads either side of its expiry
to the tick; so each such load is written `- STORE_HOLD_NS` at the load, the
spindle's position is taken from a one-tick copy rather than by arithmetic
across the wrap, and the walk's tally of ticks starts at 5. `RD_FINISH_T`'s
"two ticks short of 140 ns" is the precedent, and it is in the open rather
than in the constant. The proof it is exact is that `disk-timeout-a-tick-
short` and `disk-seek-settle-a-tick-short` are still caught: paid twice or
not at all, they would survive. A write in the testbenches costs three ticks
now --- the address, the request, the hold --- so that a read on the tick
after sees the registers; the request's tick is still the instant.

**Measured.** `disk.pass` holds the whole trace with the store reachable
only over AXI at exactly the residue it had before: block counter exempt on
136 rows and compared on 81, 29 rows one way round, 15 shared groups, 43
STARTs off their instant, 1 turn; 27 blocks fetched, 5 written back and
compared, all 46 `NEED` blocks resident. A fetch costs 302 ticks at fixed
slave delays, a write-back 557, a register write 3. **Both directions of
the beat are registered at the seam** --- `RVALID` and `RDATA` leave the PS7
late in the tick, and written straight into the store they reached every
slot's tag enable at -0.513 ns on the DDR=1 board; and the block RAM's own
read offered straight to the PS7's `WDATA` pin was -0.505. Registered, a
read beat still costs two ticks and a write beat four. The channel's
access-time sum is registered before `elapsed` comes off it for the same
reason, the tick counted by `elapsed` itself. `disk_pack.pass` runs
22 fetches and 4 write-backs under varying delays with 243 bursts counted.
`ps7_init` with `S_AXI_HP2` on at 64 bits is **byte-identical in its 673
operations** to the committed routine, as CLAUDE.md predicted for HP0 and
HP1, so Digilent's FSBL still needs no change.

## The pack feeder

The program on Linux that serves the CADR's disk from the pack file on the
card: `linux/buildroot/package/cadr-tools/src/cadr-pack-feeder.c` and the
three files beside it, built into the Buildroot image and started at boot by
`S80cadr-pack-feeder`. Written at `388d03b` against the register face as it
stood there; `feeder_test.c` in the same directory is its check. **The moves
are complete and checked, and the request path is not there to drive them
--- read the last part of this section before anything else.**

**What it does.** The pack is `pack.img` on the card's FAT partition, in
muir's format --- 1,024 bytes a block, each word low byte first, block `lba`
at byte `lba * 1024`, the file exactly the size the geometry implies, which
is how a T-300 (269,562,880 bytes) is told from a T-80 (70,937,600). The
init script mounts the card read-write at **`/mnt/card`** --- the one place
Linux mounts it, since the root filesystem is an initramfs and U-Boot reads
the card without mounting --- and the feeder opens `/mnt/card/pack.img`. It
maps two things through `/dev/mem`, opened `O_SYNC` so both mappings are
uncached: the pack side's sixteen registers at `0x4000_0000`, and 128 KB of
the spare part of the CADR's region from `0x1C80_0000`. To serve block
c/h/b into slot s it builds the block's record --- the 256 data words from
the file, then the block's header, header checkword and data checkword ---
puts the 259 words at the slot's fetch address, and asks the face to fetch
them. To take back a block the CADR wrote it poisons the slot's write-back
area, asks the face to write the slot back, checks that something moved and
that the word after the record is still poison, and writes the 1,024 bytes
into the pack file, `fdatasync` before it reports done.

**The header and the checkwords are muir's, not recomputed from the
address.** `Unit` keeps `headers` and `data_checkwords` beside the file for
the sectors a Write All laid down with something other than the format's
own; `pack_file.c` keeps the same two tables and maintains them exactly as
`Unit::write_sector_at` does: a header that is `header_of` with a checkword
over it leaves the table, any other enters it; a data checkword that is the
code over the data leaves, any other enters. A written-back block hands the
feeder all 259 words, so an ordinary Write (fresh checkword, header as
fetched) and a Write All (whatever the program laid) both come out right
without the feeder knowing which it was. Like muir's, the tables live only
for the run --- the pack file has no room for them and muir persists them
only in a checkpoint --- so a pack this wrote reads identically in muir and a
pack muir wrote reads identically here, with the one caveat both share: a
sector laid with a header or checkword that is not its own forgets that at
the next start. `pack_ecc.h` is DCECC's code as `disk_unit::Ecc` has it, and
the check holds it to muir on the header checkword and the data checkword
of every `load` row of `disk.golden`.

**The protocol, as read from `rtl/cadr_disk_pack.sv`.** Four writes and a
read: ADDR, TAG (`{cylinder<11:0>, head<7:0>, block<7:0>}`), SLOT, then CTL
with exactly one of fetch, write back, take away; the face acts on the CTL
beat one tick later (`go_q`) and latches the other three at that instant,
so they may be rewritten at once. CTL reads back busy, done, error,
refused, `ch_active` and `store_miss`. A request is refused --- moving
nothing, issuing no burst --- for an unaligned address, a slot past 24,
two bits at once, a move already in flight, or the channel walking
(`bad_align`, `bad_slot`, `bad_busy`, `bad_ch`, `go_one`). Of those only
the last can arise from a correct program, and the driver retries it with a
pause, because the fabric refuses rather than queues on purpose; the others
are reported as the caller's bug, named from what was asked. The error bit
is SLVERR or DECERR on a burst, or a burst that did not end where its
length said, and the next clean move clears it. The driver reads IDENT
between the CTL write and the status read: the two halves of GP0 are
independent and a read on the heels of the write could see the word from
before the request. The DRIVE register is the drive seam --- present,
read-only, timed, eight units of it --- and the feeder writes it.

**Where the records go, and why.** `rtl/cadr_ddr_map.sv`'s spare, 56 MB
from `0x1C80_0000`, nothing else in it today. One fetch area per slot at
`0x1C80_0000 + 2 KB * slot` and one write-back area per slot at
`0x1C81_0000 + 2 KB * slot`. 128-byte alignment is the fabric's rule, so
that no sixteen-beat burst crosses 4 KB; at a 2 KB stride from a 2 KB-
aligned base a 1,036-byte record never does, and no two records overlap.
Fetch and write-back areas are separate so that a write-back which moved
nothing cannot read back as the block it was fetched from: the write-back
area is poisoned before every move, a record still all poison afterwards is
reported and not committed, and so is a pad word that was written.

**The check.** `make -C linux/buildroot/package/cadr-tools/src check`, on
the build host, needing a C compiler and `build/disk.golden`. It plays the
trace's `BLK load|lay` rows onto a fresh pack file of a T-300's size, asks
the feeder to serve each `NEED` row into the slot the trace names, and
holds the model's store to the 259 words the pack carries, tagged with the
disk address, from an aligned address in the spare with no burst across
4 KB and no overlap; then plays each `BLK write` row into the model's slot
and holds the pack file byte for byte to what the CADR wrote and the
record read back out of it to the same 259 words. The register face is a
model that follows the RTL's refusal terms and move semantics; the driver's
refusal handling is exercised against it, the channel's retried, a move
that moved nothing detected. At `388d03b`: 46 blocks served and 11,914
words compared, 5 written back and 5,120 bytes compared, 23 load rows'
checkwords agreeing with muir's `Ecc`, 6 refusals named, 275 polls of a
busy face. Eight hand mutations --- the ECC's taps, `header_of`'s
next-block code, a write-back off by one word, a 1 KB stride, a record with
the wrong header, the checkword table ignored, an unaligned fetch address,
the poison test off by one --- are each caught on the property they break.
The scratch goes under `~/.cache/muir-fpga-pack-feeder`.

**~~What the register face does not carry~~, and what the feeder therefore
did at `388d03b`.** Written before the request path; the face carries all
three things now (REQ, DIRTY and `IRQ_F2P`, below), and the paragraph
stands as the record of why. Nothing on `M_AXI_GP0` said **which block the
CADR asked for**. The controller's walk looks a slot up by tag and, missing, stops
the transfer and raises `store_miss` --- one sticky bit, read back in CTL
(`cadr_disk_pack.sv`, the status word; `cadr_disk_controller.sv` at
`store_miss`, whose own comment says "fetching on demand ... is not
built"). The disk address the walk missed on is register 2 of the
controller, on the Xbus, and no path reaches it from Linux. Nor does
anything say **which slot a transfer wrote**, so the feeder cannot know a
write-back is pending; and the TAG has no unit field, so the store cannot
hold blocks of two drives with one disk address. So the feeder cannot serve
on demand and does not pretend to: it opens the pack, maps both windows,
checks IDENT reads "PACK", says what it found, **leaves the drive absent**
--- the CADR then sees no drive, as it does today, rather than a drive whose
every block is missing --- says why on the console once, and watches the
status word. The 24-slot store against a 263,245-block pack means the
request path is the whole of what is missing: no pre-filling can stand in
for it. What that path needs, in the fabric's terms, is the disk address of
the block the walk missed on readable over GP0 (unit, cylinder, head,
block), a way to see which slots a transfer wrote, and --- for a program
that does not poll --- an interrupt; that is the RTL's next slice and is
not written here.

**What has not been shown on the board.** Nothing of this has run on the
board; the board it needs is the memory-on bitstream with the disk's pack
side on `M_AXI_GP0` and `S_AXI_HP2`. Boot with a `pack.img` on the card and
watch the console for:

    cadr-pack-feeder: card mounted at /mnt/card
    Starting cadr-pack-feeder: OK
    cadr-pack-feeder: the pack side answers at 0x40000000 (IDENT "PACK"); status 0x00
    cadr-pack-feeder: pack /mnt/card/pack.img: 815 cylinders, 19 heads, 17 blocks a track, 263245 blocks
    cadr-pack-feeder: block 0 word 0 is 0x4c42414c (LABL: a labelled pack); header 0x00000000
    cadr-pack-feeder: records at 0x1c800000 (fetches) and 0x1c810000 (write-backs), 24 slots 0x800 apart
    cadr-pack-feeder: the register face has no way to say which block the CADR asked for ...
    cadr-pack-feeder: the drive is left absent (DRIVE = 0) ...

Then, at the prompt, `cadr-pack-feeder --selftest`, which is the first
thing the pack side has ever been asked to do on silicon: block 0 fetched
over HP2 into slot 0, written back to the poisoned area, the 259 words
compared and the pad checked, the slot taken away ---

    cadr-pack-feeder: selftest: PASS: block 0 fetched over HP2 from 0x1c800000 into slot 0, written back to 0x1c810000, all 259 words equal, the pad untouched, the slot taken away

A round trip through the store cannot see a fault the two directions share
--- `tb/cadr_disk_pack_tb.cpp`'s header says why it reads every block back
through the CADR instead --- so a PASS says the ports move a block on
silicon and nothing subtler. A bus error at the first read means nothing
answers on GP0 (the wrong bitstream); `no pack side ... register 7 reads
0x...` means something does and it is not this face. `pack.img` is the name
the card image already reserves; `PACK=<file> linux/mksd-buildroot.sh` puts
one there.

## The request path, built

Written at the slice after the feeder, which found the face wanting: the
store is a cache Linux keeps, and the controller now says what it lacks.
`rtl/cadr_disk_controller.sv` (the request register, the wait, the
prefetch, the events) and `rtl/cadr_disk_pack.sv` (the registers Linux
reads and the interrupt) have the reasoning at each line; this is the
register map as built, what the checks hold, and what the Linux program
has to change.

**The register map**, sixteen words at `0x4000_0000` on `M_AXI_GP0`, in
`rtl/cadr_disk_pack.sv`'s header (lines 87--147 at this slice) and its
read mux (`r_word`):

    0  ADDR    the block's address in DDR; bits 6:0 zero                   (unchanged)
    1  TAG     {unit<2:0>, cylinder<11:0>, head<7:0>, block<7:0>}, bits 30:0
               --- the unit is NEW; bit 31 reads zero and is ignored
    2  SLOT    which of the 24 slots                                        (unchanged)
    3  CTL     written: bit 0 fetch, bit 1 write back, bit 2 take away,
                        exactly one of the three; bit 3 DENY the request
                        REQ holds --- NEW, independent of bits 2:0, never
                        refused
               read:    bit 0 busy, 1 done, 2 error, 3 refused,
                        4 ch_active, 5 store_miss (now: a denied request or
                        a track command's absent sector), 6 WAITING --- NEW,
                        the walk is stopped for want of REQ's block
    4  DRIVE   bits 7:0 present, 15:8 read-only, 16 timed                    (unchanged)
    5  REQ     NEW, read only: bit 31 valid, bits 30:0 the disk address the
               controller lacks in TAG's layout, so REQ & 0x7fffffff is the
               TAG to write.  Valid falls when a slot's tag becomes that
               address (any slot), on a deny, and when the channel stops
    6  DIRTY   NEW, read only: bit s up when a transfer has written slot s
               since Linux last fetched into it, wrote it back or took it
               away
    7  IDENT   "PACK"                                                        (unchanged)
    8  REF     NEW: bit s up when the walk has taken slot s for a block since
               the bit was last cleared or the slot last fetched into.
               Written: a 1 clears the bit, a 0 leaves it
    9  IRQ     NEW: bit 0 a request was posted, bit 1 a slot became dirty,
               bit 2 a move finished (busy fell).  Written: a 1 clears the
               bit.  `IRQ_F2P` bit 0 is the OR of these under IRQEN
   10  IRQEN   NEW: the mask, bits 2:0, read and written; zero at reset

Every other word in the sixteen reads zero and ignores writes; every
address outside them is answered SLVERR, as before.

**The refusal changed shape.** `refused` with `ch_active` used to mean "the
channel is walking, ask again"; it now means "the channel is walking **on
the slot you named**, and is not waiting" (`bad_ch_q` in
`cadr_disk_pack.sv`). A move on any other slot is taken during a walk,
which is what lets a prefetch land while the current block moves; and
while the walk waits (`CTL` bit 6) every slot may be moved, including the
one `ch_slot` still names. The controller's half of the interlock is a
second look at its slot before a data word moves (`slot_ok_q` at
`C_HDRCK`): a move that began on the slot in the tick before the walk chose
it is over before the walk touches it, and the walk looks the block up
again.

**The protocol, as a program runs it.** Enable `IRQEN` (or poll). On the
interrupt, read `IRQ`; for bit 0 read `REQ`, and if valid choose a slot ---
never one with `REF` set unless every slot has it (clear the bits you pass:
second chance), never the slot the walk is on (`ch_active` up and `waiting`
down: the refusal tells you), writing a dirty one back first --- then
`ADDR`, `TAG = REQ & 0x7fffffff`, `SLOT`, `CTL = fetch`, and the wait ends
by itself when the tag lands; or `CTL = deny` if the block is not on the
pack, and the CADR sees the transfer stop as it did before. For bit 1 read
`DIRTY` and write the slots back at leisure (a slot written twice raises the
event once). Clear `IRQ` by writing the bits back. `REQ` valid and
`waiting` are readable without the interrupt.

**What the trace holds.** `disk.pass` fills every block before the START
that needs it --- a Linux of no latency --- and asserts that REQ is never
valid and the interrupt never up on any tick of the run: measured against
`build/disk.golden` with a Python model of the request path first
(`~/.cache/muir-fpga-reqpath/reqmodel.py` at the slice, thrown away), 19
transfers, 33 lookups and 15 prefetch lookups, all hits, so the trace could
be exact by construction. Every residue is what it was: block counter
exempt on 136 rows and compared on 81, 29 rows one way round, 15 shared
groups, 43 STARTs off their instant, 1 turn; `machine.pass` byte-identical.
The prefetch state costs four ticks a chained block --- 48 more ticks of
walking over the run's 19 transfers, on the fabric's side of a comparison
made at quiescence.

**What the property run holds** (`disk_pack.pass`). A Read of a block the
store lacks on a drive whose time is charged, with Linux 4,000,000 ticks
behind the START --- longer than any access time on the heads' cylinder,
3,527,024 ticks at most: sampled 80 times during the wait, BUSY up,
not-active and the interrupt request down, `waiting` up, REQ the block, the
page still poison, nothing dirty, no miss; then the block fetched, the
transfer complete, the page compared, not-active at once (the access time
long past), and the transfer ending **2,589 ticks after REQ fell against an
unstalled walk of 2,595** --- derived as `walk - 4 - lat` (the stalled walk
made its command-list fetch before the wait; `lat` is the testbench's
channel latency, 2 there) and allowed 4. The slot the walk stood on for the
four million ticks is written back afterwards and compared. A Write that
waits dirties nothing until its block has arrived, and what is written
back is the page. The next block of a chained list is asked for while the
first block's page is still poison. Two units with one cylinder, head and
block are two blocks. DIRTY, REF and the three events are read back
exactly. A denial ends a wait with `store_miss` and the page untouched.
Every address on GP0 is answered.

**The interrupt.** `IRQ_F2P` bit 0, brought out of `rtl/cadr_ps7.sv` by
`vivado/gen_ps7.py` (the other nineteen tied low in `rtl/cadr_arty.sv`).
Digilent's configuration already has `PCW_USE_FABRIC_INTERRUPT 1`,
`PCW_IRQ_F2P_INTR 1` and `PCW_IRQ_F2P_MODE DIRECT` (`vivado/ps7_config.tcl`
lines 253--254, 628), so `ps7_init` does not change: `make current` compares
the routine and says so. Bit 0 of `IRQ_F2P` is shared peripheral interrupt
61 on the GIC (UG585 Table 7-4), which a device tree names `<0 29 4>`.

**GP0 is answered on every board that has it.** A read nothing answers on
GP0 does not fault the Arm; it hangs both cores at one PC each (measured on
the board, the feeder reading IDENT on a bitstream without the pack side).
So: with `DDR=1` the pack side completes every transaction --- the sixteen
words, SLVERR outside them, anywhere in the port's gigabyte; the two
proving boards (`PROVE=1`, `PROVE=2`), which bring GP0 out without the pack
side, carry `rtl/cadr_gp0_default.sv`, which completes every read with
OKAY and `0x4E4F4E45` ("NONE") and every write with OKAY, dropped, so that
the feeder's own IDENT check says "not this face" instead of freezing the
processor; `gp0_default.pass` holds that it answers, the arty lint that it
is wired. **The default board (`DDR=0`) has no `PS7` in it and cannot
answer**: a program that touches `0x4000_0000` on that bitstream hangs the
processor whatever the fabric does. The one guard a program has before its
first GP0 read is the EMIO tally at `0xE000A068`/`6C`, which reads all ones
on that board and carries its marker bits on the others. A SLVERR on a
Cortex-A9 *write* is a posted write's error and arrives as an imprecise
abort the kernel cannot attribute; the pack side's out-of-window SLVERR is
the decision recorded above and stands, but a program should not write
outside the sixteen words.

**What the Linux program (`linux/buildroot/package/cadr-tools/src`) must
change**, for its author --- nothing there is edited by this slice:

1. `pack_side.h`: `ps_tag(c, h, b)` gains the unit in bits 30:28
   (`(unit & 7) << 28 | ...`); a tag for unit 0 is unchanged, so every
   existing call is right for unit 0 and wrong for any other.
2. `pack_side.h`: new registers `PS_REQ = 5`, `PS_DIRTY = 6`, `PS_REF = 8`,
   `PS_IRQ = 9`, `PS_IRQEN = 10`; new bits `PS_CTL_DENY = 1 << 3`,
   `PS_ST_WAITING = 1 << 6`, `PS_REQ_VALID = 1u << 31`; the IRQ bits
   `PS_IRQ_REQ`, `PS_IRQ_DIRTY`, `PS_IRQ_DONE` (bits 0, 1, 2).
3. `pack_side.c`, `ps_request`: the retry on `PS_ST_REFUSED | PS_ST_CH_ACTIVE`
   still works, but the refusal now means the slot named is the walk's
   own; the fix is to choose another slot rather than to wait, and a
   refusal while `PS_ST_WAITING` is up cannot come from the channel at all.
   `PS_ST_STORE_MISS` no longer means "the store lacked a block": it means
   a denial (or a track command's absent sector).
4. The feeder: serve on demand. Read `REQ` on the interrupt (or by polling
   `REQ` valid / `CTL` waiting); the disk address is bits 30:0 and the
   `lba` is `pack_file`'s from cylinder, head and block; unit is bits
   30:28 and selects the pack (one pack today: deny anything on another
   unit). Fetch into a slot chosen by second chance over `REF`, writing a
   dirty slot back first; or `CTL = PS_CTL_DENY` when the block is off the
   pack. Stop leaving the drive absent: `ps_drive(present = 1 << unit,
   ...)` once the pack is open and the request path is being served.
5. Write-backs: read `DIRTY` on the dirty event and write those slots back;
   a slot must be written back before it is fetched into or taken away, or
   the CADR's write is lost. The write-back and take-away paths are
   unchanged.
6. Optional: `IRQEN = 7` and a driver on GIC interrupt 61 (device tree
   `interrupts = <0 29 4>`) instead of polling; polling `REQ`, `DIRTY` and
   `CTL` works with `IRQEN = 0`.
7. `feeder_test.c`'s model of the face: the tag width and the new
   registers, the refusal per slot, `store_miss` on denial only.
8. Before the first GP0 access, check the EMIO tally's marker bits (a
   bitstream with the PS7 in it) --- a `DDR=0` bitstream hangs the processor
   on the first read and nothing in software can catch it afterwards.
