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

## The disk pack program

The program on Linux that serves the CADR's disk from the pack file on the
card: `linux/buildroot/package/cadr-disk-pack/src/cadr-disk-pack.c` and the
files beside it, built into the Buildroot image and started at boot by
`S80cadr-disk-pack`. This is its second revision, written against the
register face at `a899799` --- the request path --- and it serves on demand;
the first revision, at `388d03b`, moved blocks and could not learn which
block the CADR wanted (its record is in "The request path, built" below,
and in the history of this section). `feeder_test.c` in the same directory
is its check. **It has run on the board**, with the `a899799` bitstream: the
drive came present, the boot PROM asked for blocks 1, 0 and 17, and in the
first minute the disk pack program served 32,780 blocks and wrote 16,101 back --- the
CADR reading and writing its disk on silicon. That run also found the one
fault this revision then fixed, below at "the refusal read back with
WAITING up". The last paragraphs say what to copy and what the console
must show.

**What it does, in order.** *The guard first*: a read on `M_AXI_GP0` that
nothing answers hangs both Arm cores (CLAUDE.md), so before any GP0 access
it reads the EMIO tally at `0xE000A068`/`6C` through `/dev/mem` and requires
the marker bits `(w & 0x80008000) == 0x00008000` in both words, which only a
bitstream with the processing system in it drives; all ones, or zero (the
GPIO clock gated, or no instrument), and it stops before touching GP0 and
says why. `--no-guard` is for a board somebody knows. *IDENT second*:
register 7 must read `"PACK"`; `"NONE"` is the proving boards' default slave
and is named as such. *Then the pack*: `pack.img` on the card, muir's
format, its geometry from its size (a T-300 is 269,562,880 bytes, a T-80
70,937,600), the only disk file on the card. *Then the drive
comes present*: every one of the 24 slots is taken away --- what the store
held before this program is unknown to it, the tags being in the fabric and
not readable over GP0, and a slot that was DIRTY then is reported lost, once,
with the count --- and DRIVE is written with the unit the pack is on
(`--unit`, 0 by default), its read-only switch (`--read-only`) and whether
its own time is charged (`--timed`; untimed by default, muir's default, with
which every count this project quotes was measured). *Then the loop*, until
SIGTERM or SIGINT, on which every dirty slot is written back and the drive
is taken absent.

**The loop, as `rtl/cadr_disk_pack.sv`'s header prescribes it.** Each pass
reads IRQ and clears what it read, then REQ, then DIRTY. A request (REQ bit
31) is the disk address of the block the walk lacks in the tag's own layout,
`{unit<2:0>, cylinder<11:0>, head<7:0>, block<7:0>}`: a unit other than the
pack's, or a cylinder, head or block off the geometry, is **denied** (`CTL`
bit 3, never refused) and the walk takes its miss --- `store_miss` up,
not-active at once, the page untouched, as `tb/cadr_disk_pack_tb.cpp` holds
for the fabric; anything else is served: the block's 259 words are built
from the pack file and the tables, placed at the chosen slot's fetch address,
and fetched with `TAG = REQ & 0x7fffffff`, and the tag landing is what ends
the wait, whichever slot it lands in. **The slot is second chance over
REF**: a hand goes round the 24; a slot whose REF bit is up is passed and
its bit cleared (a 1 written to REF), the first whose bit is down is taken.
**A dirty victim is written back first**, or the CADR's write is lost.
**The walk's slot is never taken**: the face refuses a move on it (the
refusal is per slot now), `ps_request` returns that as its own answer,
`PS_WALK_SLOT`, and the hand moves on without a clear and without a pause;
while the walk waits (`CTL` bit 6) every slot is anyone's. After the
request, every slot DIRTY says a transfer wrote is written back at leisure,
the walk's own left for the next pass --- deferred, counted, and said once
if a slot is refused a hundred passes in a row (25 ms; a Read All holds a
slot for a revolution, 16.7 ms).

**The refusal read back with WAITING up, found on the board.** Once in
48,879 moves the disk pack program failed a write-back with `refused while the walk
waits, which cannot be the channel's doing (status 0x5a)`. `0x5a` is
WAITING | CH_ACTIVE | REFUSED | DONE. The RTL's refusal terms at `a899799`
(`rtl/cadr_disk_pack.sv` lines 476--491) are not one bit of three, an
unaligned address, a slot past the store, busy, and `bad_ch_q <=
ch_active_q && !ch_waiting_q && (r_slot == ch_slot_q)` (line 484), decided
at the go; and the controller sets `ch_slot` at a hit and nowhere else
(`rtl/cadr_disk_controller.sv`, `C_LOOK`, `ch_slot <= slot_of`). So between
a START and its first `C_LOOK` --- the command-list fetch --- the channel is
active, waiting on nothing, and `ch_slot` still names the slot the previous
transfer was on, which for a Write is exactly the slot that just went DIRTY;
a write-back of it in that window is refused by `bad_ch`, the walk then
misses its block, posts and waits, and by the time Linux's read comes back
the live bits say WAITING. **The RTL is conservative there, not wrong**:
the refusal is harmless and the answer is a later pass. The disk pack program's fault
was reading the live `ch_active` and `waiting` bits as the reason for the
refusal; it now classifies a refusal by the request's own terms and takes
any well-formed, non-busy one as the walk's slot. `feeder_test.c`
reproduces it --- a model state for the command-list fetch, and the fabric
running on between the CTL beat and the status read --- and the fixed
feeder writes the slot back on the next pass, no failure counted; the
mutation that restores the old reading is caught on it. A request still standing after its block was served three
times over --- a tag that landed and did not match --- is said and denied
rather than served for ever. Requests are counted; the first three are
named on the console with block, slot and address, and every denied block
is named once.

**The header and the checkwords are muir's, and they live for the run.**
`Unit` keeps `headers` and `data_checkwords` beside the file for the
sectors a Write All laid down with something other than the format's own;
`pack_file.c` keeps the same two tables and maintains them exactly as
`Unit::write_sector_at` does, so an ordinary Write (fresh checkword, header
as fetched) and a Write All (whatever the program laid) both come out right
without the disk pack program knowing which it was. Like muir's, the tables are in
memory for the run: a fresh start has every block's header and checkwords
as the format lays them --- `header_of` with the code over it, the code
over the data --- and a sector laid with others forgets that at the next
start. **A sidecar file that persisted the two tables (`pack.meta`) was
built at this revision and dropped, by Mete on 10 Sep, once what it
preserved was understood**: the pack file is the only disk file on the
card, and the program holds exactly what muir's `Unit` holds. What got
simpler: `pack_file.c` lost its file format, its creation on the first
write-back, its mismatch rules (magic, version, size, a pack newer than the
sidecar by mtime) and the flag that overrode them; `struct pack` five
fields; the disk pack program an option and three console states; the host test a
whole arm and seven mutations; the card a second file that had to agree
with the first and a 4 MB write at the first write-back; and there is no
procedure for resetting a pack's headers, because there is nothing to
reset. `pack_ecc.h` is DCECC's code as `disk_unit::Ecc` has it.

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

**The polling rate and the latency budget.** `--poll-us`, 250 by default,
`IRQEN` zero. What the controller gives Linux to answer in is time the walk
spends anyway (`rtl/cadr_disk_controller.sv`, "prefetch"): at a START with
the drive's time charged, the seek --- 5,939,729 ns settle plus 60,271 ns a
cylinder, nothing for none --- and the rotational wait, 0 to 16,666,667 ns;
and for each further block of a chained list the sector's own 968,448 ns,
since the next block is asked for as the current one begins to move. A poll
a quarter of a sector apart keeps the worst poll latency inside the smallest
of those; the answer itself then costs a 1 KB read of the pack file (from
the page cache after the first touch --- a cold read off the card is
milliseconds and is the part no polling rate can hide), 259 uncached word
writes and a fetch of some 300 ticks, 1.5 us. **Untimed, the default, the
budget is nil**: the walk asks at the START and waits the poll latency plus
the answer for every first block of a transfer, and a chained block's budget
is the previous block's 256 bus cycles, tens of microseconds, so it waits
most of a poll too --- still far under a real T-300's 6 ms seek. **When the
budget is missed nothing is wrong**: the transfer stands with BUSY up and
not-active down until the block lands, which is `DISK-WAIT`'s own loop, and
`disk_pack.pass` holds that a Linux 4,000,000 ticks late loses no word. The
cost of 250 us is some 4,000 wakeups a second with three uncached reads
each, expected to be a few percent of one A9 core; **to be measured on the
board, not asserted here.**

**The interrupt is behind `--irq PATH` and not required.** With it the loop
sets `IRQEN` for the request and dirty events and sleeps in `poll(2)` on a
UIO device, the polling interval as the timeout so a missed interrupt is
still served, reads four bytes per interrupt and writes a 1 to re-enable.
What a later interrupt path needs and this slice does not build: a node in
the board's tree --- `compatible = "generic-uio"; reg = <0x40000000 0x1000>;
interrupts = <0 29 4>;` (`IRQ_F2P` bit 0 is GIC interrupt 61) ---
`CONFIG_UIO_PDRV_GENIRQ` in the kernel and `uio_pdrv_genirq.of_id=generic-uio`
on its command line. Neither the tree nor the kernel is touched here.

**The check.** `make -C linux/buildroot/package/cadr-disk-pack/src check`, on
the build host, needing a C compiler and `build/disk.golden`; scratch under
`~/.cache/muir-fpga-disk-pack`. The disk pack program's core runs against a model of
the register face at `a899799` --- the tag with the unit, REQ, DIRTY, REF,
IRQ, IRQEN, DENY, the refusal per slot, `waiting` --- with a scripted disk
controller behind it that **asks**: each run of the trace's `NEED` rows is
a transfer that posts the blocks it lacks in REQ and waits, each `BLK write`
row a Write of that block with those words (the trace's own Write All with
header `0x30009` on block 1 among them), each `BLK load|lay` row the pack as
laid; then, past the trace, one address on two units, three blocks off the
pack, forty more blocks than the store has slots with Writes among them, a
dirty slot the hand reaches before its leisure write-back, a prefetch posted
while the walk stands on the one slot whose REF bit is down, a Write All
laying a foreign header and checkwords, and the board's fault: a Write of a
block followed at once by a Read of an absent one, the write-back landing
in the command-list fetch and read back WAITING. The pack sits on unit 2
throughout, so the unit field of every tag is live. The model decides a
refusal with the state at the CTL beat and then lets the walk run on before
the status is read, as the fabric does. What it holds: every request
answered within one poll by the 259 words the pack carries, tagged with the
request's own tag, from an aligned address in the spare, or denied exactly
for the other unit and the off-pack blocks; no fetch or take-away ever on a
DIRTY slot; the REF bits cleared and the slot taken forming one run of the
hand from where the last fetch left it, the slot taken with its bit down,
the walk's slot passed on the refusal; every dirty slot back within three
polls of the walk leaving it; the pack file at the end block for block what
the scripted writes imply; and after a restart every record the format's
own over the data written, the laid ones changed by that (six, or the arm
is vacuous), a header laid again carried for the run. At this revision: 76
requests, 72 served and 4 denied, 112 hits and 29,008 words compared, the
hand four times round the store, the walk's slot refused 43 times of which
9 in the command-list fetch, 67 blocks and 68,608 bytes of the
pack compared at the end, 23 load rows' checkwords agreeing with muir's
`Ecc`. **Fifteen hand mutations of the program are each caught on the
property they break**: the denial dropped for an off-pack block and
for the other unit (the disk pack program fails on the block), a dirty victim not
written back ("fetched into while DIRTY: the CADR's write is lost"), the
first slot taken regardless of REF and REF cleared wholesale ("second
chance: ..."), the walk's slot retried instead of passed, the tag without
its unit and with head and block swapped (the request is denied where it
should be served), the record placed without its three words, the dirty
event ignored (dirty for 7 polls), the WAITING bit read back taken as "not
the walk's" (the board's fault put back: the disk pack program fails the write-back),
a deferred write-back given up (the slot's block forgotten: the slot stays
dirty past the bound), a laid header not tabled, the pad's poison test off by
one, and a start that leaves the store alone. The mutation script is
scratch, not in the tree.

**What to copy where.** The change is the root filesystem image alone:
`rootfs.cpio.uboot` from `make buildroot-rebuild`, 2,805,700 bytes at this
revision against 2,802,503 before (the program is 30,048 bytes on the
target). On the network path that is one file into the TFTP server's
directory and a reset; the bitstream, kernel, tree and loader are unchanged,
and the bitstream must be the one with the request path (`a899799` or
later --- the `997b734` one on the board today has no REQ register and the
feeder would read zeros there and serve nothing). `linux/mksd-buildroot.sh`
puts a pack on the card as `pack.img` with `PACK=<file>`, and that is the
whole of the disk on the card.

**What the console must show, with a pack on the card and the drive
untimed**, in this order, and nothing else at the same rate:

    cadr-disk-pack: card mounted at /mnt/card
    Starting cadr-disk-pack: OK
    cadr-disk-pack: the EMIO tally reads 0x01008100 0x01008100: a fabric with the processing system in it; M_AXI_GP0 may be read
    cadr-disk-pack: the pack side answers at 0x40000000 (IDENT "PACK"); status 0x00
    cadr-disk-pack: pack /mnt/card/pack.img: 815 cylinders, 19 heads, 17 blocks a track, 263245 blocks
    cadr-disk-pack: block 0 word 0 is 0x4c42414c (LABL: a labelled pack); header 0x00000000
    cadr-disk-pack: headers and checkwords are the format's own until a transfer lays others, and are the run's, as muir's are
    cadr-disk-pack: records at 0x1c800000 (fetches) and 0x1c810000 (write-backs), 24 slots 0x800 apart
    cadr-disk-pack: 24 slots taken away; the drive on unit 0 is present (writable, untimed)
    cadr-disk-pack: polling REQ and DIRTY every 250 us

The tally's two words are whatever the machine's memory cycles have counted
by then (256 and 256 after the boot PROM's parity loop, `0x01008100` twice,
as `vivado/ddr_run.tcl` and the earlier boot measured); the marker bits are
what is checked. **The drive coming present is the line that changes
the CADR**: until then the boot PROM sits in `AWAIT-DRIVE-READY` polling a
status of `0x2321`; with unit 0 present it goes on, and the first requests
follow within the PROM's own time:

    cadr-disk-pack: request 1: block B (C/H/B) served into slot 0 from 0x1c800000
    cadr-disk-pack: request 2: block ... served into slot 1 from 0x1c800800
    cadr-disk-pack: request 3: block ... served into slot 2 from 0x1c801000; further requests are counted, not named

On the board the PROM asked for blocks 1, 0 and 17 (unit 0: 0/0/1, 0/0/0,
0/1/0), in that order; the reference band's opening sequence, earlier in
this file, shows a Write followed by a Read-compare and a Read before the
pack is walked, so DIRTY write-backs come early. A band loading is consecutive
blocks in chained transfers, each next block posted as the one before it
begins to move and served by the next poll, so the CADR sees a drive with
no seek and a 250 us sector. Then, once a minute at most while the counts
move:

    cadr-disk-pack: served 32780, written back 16101, denied 0, refused for the walk's slot 3 (write-backs deferred 3, at most 1 passes in a row), 0 lost at start, 0 failures; 240000 polls, 6170 of the face while busy

The served and written-back figures are the board's first minute; the rest
are placeholders for the shape. **A `failures` count above zero names its
last failure on the same line** (`..., 1 failures, the last: writing slot 6
(block 18764) back to ...`), and every failure was also said when it
happened, once, with a repeat of the same text said once a minute. The
board's one failure at this revision's first run was the WAITING refusal
above, which is no failure now: it is a deferred write-back, counted in
"refused for the walk's slot" and "write-backs deferred".

A denial is named once per block, `denied block C/H/B on unit U: no pack on
that unit` or `... off a pack of 815 cylinders, 19 heads, 17 blocks a
track`; a program on the CADR that addresses a second drive or runs off the
pack produces exactly those and nothing worse. **What would be wrong**: the
guard line saying the tally reads zero or all ones (the wrong bitstream, or
the GPIO clock gated --- stop there; the program did); `no pack side ...
"NONE"` (a proving board); `request N: ...` lines with no
`served` count moving afterwards; or any `failures` above zero in the
summary, each of which was named when it happened. `cadr-disk-pack
--selftest` still runs the round trip of block 0 through the store with the
drive absent, as at `997b734`, and passes on the board at that bitstream.

## The request path, built

Written at the slice after the disk pack program, which found the face wanting: the
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
the board, the disk pack program reading IDENT on a bitstream without the pack side).
So: with `DDR=1` the pack side completes every transaction --- the sixteen
words, SLVERR outside them, anywhere in the port's gigabyte; the two
proving boards (`PROVE=1`, `PROVE=2`), which bring GP0 out without the pack
side, carry `rtl/cadr_gp0_default.sv`, which completes every read with
OKAY and `0x4E4F4E45` ("NONE") and every write with OKAY, dropped, so that
the disk pack program's own IDENT check says "not this face" instead of freezing the
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

**What the Linux program (`linux/buildroot/package/cadr-disk-pack/src`) must
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
4. The disk pack program: serve on demand. Read `REQ` on the interrupt (or by polling
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

## The CCW walk, and the day the board halted on it

Written on 2026-09-10, after the board booted, loaded its microcode off the
pack, ran, and stopped itself at microcode PC `0o5163` on
`ILLOP-IF-PAGE-FAULT`.

### What the cold boot asks the channel to do

`sys/ucadr/uc-cold-disk.lisp` at `DISK-RESTORE-1` reads the label with three
one-page reads and then makes **one** call with `(M-2) 3`, "Core pages 0, 1
and 2", `(M-B) 0` and `(M-C) COPY-BUFFER-CCW-ORIGIN`. `START-DISK-N-PAGES`
in `uc-disk.lisp` builds the list from that: `MD` starts at
`page << 8 | 1`, `BUILD-CCW-LIST-1` clears bit 0 on the last word only, and
each word goes to `A-DISK-CLP + k` with `MD` advanced by `PAGE-SIZE`. So the
first thing the cold boot does after the label is a command list of **three
CCWs into three consecutive physical pages**, and every disk transfer before
it --- the PROM's own microcode load and the three label reads --- is a list
of one.

Taken from muir rather than transcribed: `golden/src/disk_boot.rs` runs the
`rtl` engine on MIT's boot PROM with the pack attached and takes the command,
the disk address and the pages from the first START that moves more than one
page. It is **microcycle 1,423,405**, disk address `0x01191101` --- unit 0,
cylinder 281, head 17, block 1 --- into pages 0, 1 and 2, with the list at
`0o40000` reading `1, 101, 200`. The next one, at microcycle 1,423,665, is
nine CCWs into pages 7 to 15 from block 4. The generator asserts the list is
where `COLD-DISK-READ` puts it rather than assuming it.

### What the walk is, as built

`rtl/cadr_disk_controller.sv`, and it is `Controller::command_list` state for
state:

    C_CCW    fetch the word at `clp_now` --- `{clp[31:16], clp[15:0] + ch_n}`,
             "only bits <15:0> of the CLP can count" --- and take `ch_page`
             from `<21:8>` and `ch_more` from `<0>`
    C_LOOK   look the block under the heads up in the store; miss, and POST
             it and wait
    C_HDRC   the header compare, under the mask
    C_HDRE   the header's four bytes through the code
    C_HDRCK  the header checkword, and then, if the list goes on and the next
             block is on the pack, `C_PF` --- the prefetch, which asks for the
             NEXT block before this one moves
    C_DATA   the data field and `C_DCK` its checkword, through the code
    C_ECCQ   the checkword's verdict, and `C_TSPIN`/`C_TSCAN` for the trap
    C_MOVE   the page, a word a bus cycle
    C_NEXT   `lma` to the page's last word, `ch_moved` up, and then one of
             three things: no More flag, stop; a track command, fetch the
             next CCW with the heads standing; otherwise advance the heads by
             `next_block` and fetch the next CCW --- or, if that steps off the
             pack, `STATUS<17>` and stop

The three paths back to `C_CCW` are muir's three, and `ch_n` counts once on
each of the two that go on.

### What `disk_boot` holds to

`golden/src/disk_boot.rs` and `tb/cadr_disk_boot_tb.cpp`. **A new generator
rather than an extension of `golden/src/disk.rs`**, and the reason is that the
two references answer different questions: `disk.rs` is a *timed* trace on the
5 ns grid against a blank pack the program formats itself, with every block
already in the store before the START that needs it --- "a Linux of no
latency", which is what keeps its rows on their instants, and what its own
testbench asserts by requiring the request path silent at every tick. Putting
a real pack and an on-demand store into it would contradict that invariant and
would make CI depend on `vendor/`. This one is untimed, and about data.

Eleven transfers, 52 CCWs, the longest list sixteen; 43 pages and 11,008 words
compared word for word against what `Controller::transfer` put in muir's own
main memory; 46 blocks of the real System 100 pack placed in a modelled DDR
and fetched over `S_AXI_HP2` on demand, three written back and compared. The
cold boot's own two lists are the first two; the rest are a list of one (the
control --- what the board did get right), lists that walk off the end of a
track and off the end of a cylinder, a list of sixteen, a list whose CLP
carries out of `<15:0>`, a read-compare that agrees and one that differs, and
a Write of three pages with the read back into three others.

Everything that could come from the DUT comes from somewhere else instead.
The destination pages are poisoned by the trace with a function of the page
**and** the offset before every read, so a page nothing wrote cannot read back
like one that was written --- which matters here more than anywhere, the
board's own symptom having been a page of zeros. The record the feeder serves
is the trace's `BLK` row and never the DUT's; a tag no row named is denied
rather than invented; and the read after the Write is served from a fresh row
taken from muir's pack rather than from the fabric's own write-back, so the
two halves cannot agree on a shared mistake.

The store comes up **empty**, so every block has to be asked for: 46 requests,
46 served, and the check fails if it saw fewer than 40 of either. The feeder
is second chance over the twenty-four slots with the walk's slot passed over,
which is `pack_feeder.c`'s rule, and it answers a varying number of ticks
late. The processor polls the status register every 300 ticks throughout each
walk, as `DISK-RECALIBRATE-WAIT` does, and `<0>` is required down at every one
of the 421 polls.

### The hole this closed, stated plainly

Three checks touch the channel and none of them could see a walk that honours
the first CCW of a list and not the rest:

* `disk` walks lists of three CCWs, but pre-fills every block: the request
  path is required silent at every tick of that trace, so nothing there has
  ever asked Linux for a block mid-walk;
* `disk_pack` fills the store on demand, but every command list in it is one
  CCW long bar a single chained pair whose first block is already resident;
* `machine` is MIT's boot PROM: 512 identity memory cycles and no channel
  traffic at all, and the 2,200,000-microcycle band runs against
  `Vcadr_microcycle`, where `rdata`, `-MEMACK` and `-LOADMD` are stimulus out
  of muir, so nothing that *produces* `rdata` had ever been run against that
  program.

`ccw-walk-stops-after-four-pages` is the record that measures how much of it
is left. Aimed at `disk_pack` it SURVIVES, and so it does at `ddr_boot`,
`machine` and `probe`; aimed at `disk` it is CAUGHT, but not by any command
list in `disk.golden` --- the longest of those moves three pages --- and
instead by `tb/cadr_disk_tb.cpp`'s own track section, which builds a list
long enough for a whole track's 20,160 bytes and fails at "the last memory
address after a Read All is 001003ff, wanting 001013ff". That was measured
after the note in `mutations/list.txt` had already claimed the opposite, and
the note now says so: the trace's lists are short, the testbench's are not,
and quoting the trace at this question gives the wrong answer.

### The board's failure is not in `rtl/`

Measured on 2026-09-10, three ways, none of which reproduces it:

1. `disk_boot` passes at HEAD --- the controller with `rtl/cadr_disk_pack.sv`
   under it over a modelled `S_AXI_HP2`, walking the cold boot's own lists
   over the real pack, with the feeder delayed by anything from a tick to
   50,000 and the processor polling as often as every 40 ticks.
2. `cadr_machine` with a modelled DDR behind `mem_*` and a feeder driving the
   block-store seam directly, run from reset through MIT's boot PROM and the
   microcode off the pack: physical `0o400` first goes non-zero at microcycle
   1,441,677 and **physical words 0 to 1023 come out byte-identical to muir**
   at the same point. The machine goes on past it, to PC `0o25333` at four
   million microcycles, where the board halted at `0o5163`.
3. The same again with `rtl/cadr_disk_pack.sv` under the machine over a
   modelled `S_AXI_HP2` and a feeder on `M_AXI_GP0` --- which is
   `rtl/cadr_arty.sv`'s `g_ddr` short of the PS7 --- also byte-identical to
   muir over 0 to 1023, with `store_miss` low, nothing denied and no protocol
   error on the port.

The board's dump differs from muir in 352 of those 1,024 words. So whatever
put the hole there is **outside `rtl/`**: the disk pack program in
`linux/buildroot/package/cadr-disk-pack/`, where the pack is in DDR, or the
bitstream the board was carrying. Two things about the fabric are worth
having written down before anyone looks there, because they shape what the
symptom can mean:

* **A store miss raises no error bit the CADR can read.** `C_LOOK` takes
  `store_deny`, sets `store_miss` --- which goes to Linux and to nothing else
  --- and stops the transfer through `C_ACCMUL` with a clean status. So a
  denied block looks to the microcode exactly like a transfer that finished:
  `DISK-COMPLETION-GET-STATUS` sees no error, `COLD-DISK-READ` returns, and
  the machine runs on with pages nothing wrote. That is precisely the board's
  shape, and it is the first thing to check on the board's own console: a
  denial is named there once per block by `pack_feeder.c`.
* The other clean end is `ch_more` read as zero. Both leave one page moved,
  no error bit, and the disk address at the block the walk stopped on ---
  which is what `RES` compares in `disk_boot`, and what a board capture of
  registers 0, 1 and 2 after the halt would separate: a walk that stopped for
  want of a block leaves the disk address at the block it could not get, and
  one that read the More flag as zero leaves it at the first.

### Two things `disk_boot` measured on the way, neither of them the board's bug

**`ch_moved` is eight bits and MIT's own software asks for 512 pages.**
`uc-cold-disk.lisp` assigns `COPY-BUFFER-CCW-BLOCK-LENGTH 1000` --- 512
decimal --- and says so in its own words: "The two pages starting at
COPY-BUFFER-CCW-PAGE-ORIGIN are used for disk CCWs, allowing transfer of up
to 512. pages (128k words) at a time." `rtl/cadr_disk_controller.sv` counts
the pages a walk has moved in `logic [7:0] ch_moved`, so a list of more than
255 wraps it, where muir's `command_list` returns a `u32` into
`access_ns(from, to, block, n)`. **It costs nothing as the board runs**: the
only reader is `acc_mv`, the sector-times the drive is charged for the
transfer, and `C_ACCFIN` forces `busy_ns` to zero unless `drive_timed` is
set, which the board's feeder does not set. It is a divergence from muir all
the same, it is reachable by real software rather than by a test, and it is
recorded here rather than fixed because fixing it widens an operand of the
access-time DSP and wants a fit of its own. `disk_boot`'s longest list is
sixteen and does not reach it.

**A store miss is invisible to the CADR**, which is stated above and is worth
repeating as a property rather than as a clue: nothing the microcode can read
distinguishes "the block was denied and the transfer stopped" from "the
transfer finished". Whether it should is Mete's to decide --- the board has no
such condition, the store being this fabric's own invention --- but a driver
that denies a block silently truncates a transfer, and the CADR runs on.

## The interrupt, and the night the band restored and stopped

Written on 2026-09-10, after the board booted, loaded its microcode off the
pack, and **restored the whole band** --- 42,967 blocks served, 21,340 written
back, no denials, over a billion microcycles retired --- and then spun for
ever in three instructions.

### What the machine was doing

    AWAIT-DISK
    25221  (POPJ-EQUAL A-DISK-BUSY M-ZERO)
    25222  (CHECK-PAGE-READ)        ; conditional call on PG-FAULT-OR-INTERRUPT
    25223  (JUMP AWAIT-DISK)        ; its N bit NOPs 25224, which is why PC
    25224  DISK-COMPLETION          ; shows four addresses for three instructions

`A-DISK-BUSY` is cleared in exactly one place, `DISK-COMPLETION-OK`, which is
reached only from the Xbus interrupt handler. Read off the console, halting
and starting the machine: at `0o25222` **JCOND reads 0** with `-VMAOK`
permitted, and the jump condition there is `!vmaok || sint` --- so `sint` was
0 and no interrupt was arriving; one instruction earlier the A bus read
`0xffff`, `A-DISK-BUSY` still `-1`. The disk had finished its transfer and
had no way to say so.

The cold boot never noticed because it does not use the interrupt:
`DISK-RECALIBRATE-WAIT`'s own comment says it must **not** check for one, and
it polls. That is why the entire band restored before this bit mattered. The
running system's page-fault path waits on the interrupt instead.

### What was wrong

`rtl/cadr_disk_controller.sv` had computed the level all along ---
`not_active && (cmd[11] || (cmd[10] && any_attention))`, the done enable or an
attention with the attention enable, `Controller::interrupt()` exactly --- and
reported it in `STATUS<3>`. It was **not a port**. `cadr_machine`'s `sintr`
was still a stimulus input fed from the trace, and `rtl/cadr_arty.sv` tied it
to `1'b0`. Nothing joined the two: the `dev_wdata` shape, a signal that
exists on one side of a boundary and not the other, and the module's own
header had said so in as many words rather than fixing it.

A status bit is a word a program has to ask for. The level is what tells it to
ask. They are one expression and they are now one wire.

### What is built

`cadr_disk_controller` brings the level out as `intr`.
`rtl/cadr_machine.sv` ORs it with the display's `tv_intr` --- `LM INT` is
`UB INT OR XBUS INTR IN` at UBINTC 0E04, and the join belongs one gate before
the 74S175 at LCC 3E12, which `cadr_microcycle.sv` registers at the microcycle
edge --- and brings the result out as `sintr_o`, for a check to compare and
for the top level to fold. `sintr` has stopped being an input of `cadr_machine`
anywhere: the tie-off in `rtl/cadr_arty.sv` is gone, and so is every line in
`tb/` that drove it. Deleted and not left unused, which is CLAUDE.md's `md`
trap word for word --- Verilator lets a testbench write an output, so a drive
line that stayed would have gone on supplying the right answer with every
check green.

### What holds it

**`build/disk.pass`, the level itself.** `tb/cadr_disk_tb.cpp` compares
-XBUS.INTR **at the port** against `disk.golden`'s own `intr` column ---
`Controller::interrupt()` --- on all 380 of the trace's rows rather than only
on the 49 faces, under the same one-way rule the four counter bits get when a
row does not land on its own instant (38 of them). The trace enables the done
interrupt at row 260, the attention interrupt at row 264, raises the level on
nine rows, and reaches an **active** controller with the done enable set at
row 320. The check fails if the level never rises at all, because a port
compared only against zero would pass a port tied low --- which is the bug
this section is about. Measured, the three records aimed here are caught at
row 260 (`-XBUS.INTR at the port is 00000000, muir says 00000001`), row 264
(the same line the other way round) and row 320 (`interrupt() is 00000001,
muir says 00000000`).

**`build/machine.pass`, the wire end to end.** `rtl.golden`'s `sintr` column
is `Machine::xbus_interrupt()`, muir's own OR of the disk's request and the
display's, and it is compared against `sintr_o` on all 600,000 microcycles of
MIT's boot PROM. It used to be *driven* there and is *compared* now.

**The zero it compares against is a live zero.** The column is 0 on every row,
because the boot PROM writes no command register and enables no display --- but
`not_active`, the interrupt's other term, is true throughout: 11,301 status
polls all answer `0x2321`, `<0>` set, and MD holds that word on 33,908 rows.
So a fabric that ignored the enable raises the line and fails on the first
microcycle, and `disk-done-interrupt-enable-read-the-wrong-way` is the record
that says so. `tb/cadr_machine_tb.cpp` fails the run if MD never holds that
word, so a controller that stopped answering could not make the comparison
vacuous in silence.

### What is not held, and it is not the band

Five records cover the expression and the wire:
`disk-interrupt-never-leaves-the-module` (the board's own bug, put back),
`disk-interrupts-while-it-is-still-active`,
`disk-attention-interrupt-reads-the-attention-the-wrong-way`,
`disk-done-interrupt-enable-read-the-wrong-way`, and the two halves of the
gate, `the-disk-half-of-the-interrupt-gate-inverted` and
`the-display-half-of-the-interrupt-gate-inverted`.

The two gate records **invert** an operand rather than dropping it, and that
is a measurement and not a preference. Dropped, the mutant does not build:
the dropped operand is read nowhere else in `cadr_machine`, so Verilator
reports `Signal is not used: 'tv_intr'` (or `'disk_intr'`) and lint does the
catching, which the mutation list forbids. Made an **AND** instead ---
`disk_intr && tv_intr`, every signal still read --- it builds and **survives**
`machine`, and `ddr_boot` and `probe` on the way past, because with neither
request ever raised by either reference program `0 || 0` and `0 && 0` are the
same zero. On the board that mutant is this section's own bug one gate along:
the disk unable to interrupt unless the display interrupts in the same tick.
It is recorded in `mutations/list.txt`'s section note rather than filed as a
hole; a record with an `@hole` needs an issue, and inventing one to hold a
limit that was never a defect is the suppression that list exists to prevent.

**The band cannot close it, and that is worth being exact about.**
`rtl_sys.golden` has `sintr` up on 17,185 of its 2,200,000 rows and CLAUDE.md
records that on the band it is the disk's done interrupt and nothing else's.
But `build/microcycle_sys.pass` runs `cadr_microcycle` **alone**, where the
disk is outside the module and `sintr` is properly a port with the trace
driving it --- so those 17,185 rows check the *processor's* end of the wire,
which is real and which this slice leaves exactly as it was. They cannot reach
this end. What would is a composed band check, `cadr_machine` on
`rtl_sys.golden`, and it is a slice rather than a line: it needs the pack side,
a Linux serving blocks on demand, and something over a billion ticks --- and
muir's channel reaches main memory in no bus cycles at all where the fabric's
takes the bus for 256 words a block, so the `ns` and `stall` columns would
drift by the ten ticks `memory_path`'s configuration B measured and the rows
could not be compared as they stand. Whoever builds it owns that arithmetic
first.

### What the board should do differently

The machine should leave `AWAIT-DISK`. `A-DISK-BUSY` should go to zero at
`DISK-COMPLETION-OK` within a microcycle or two of the transfer ending, and
the PC should move off the three addresses `0o25221`--`0o25224`. A console
read of the disk's status register at `0o17377774` should show `<3>` set only
while the level is up --- which is the same bit as before; what has changed is
that it now also reaches the processor.
