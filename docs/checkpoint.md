<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# The checkpoint

Written at the checkpoint slice, 2026-09-11, against `cadr-checkpoint` as it
stands at this slice. Numbers below are measured at that point. The format's
version and the four fields muir's display work added are the exception. They
are measured against the muir that `muir.commit` pins today.

A checkpoint is the board's whole machine written into a file that muir can
open and resume. It exists because the console is a keyhole: sixteen
diagnostic registers and three words beside them can say where the machine's
PC is, and cannot say why it got there. A file opened in muir has a
disassembler, a symbol table, a screen, a prompt and every engine muir has,
and it can be run forwards. A board that halts at a microcycle nobody can
explain becomes a thing somebody can take apart.

The program is `cadr-checkpoint`, one Buildroot package of its own beside
`cadr-readout`, whose readout window it borrows rather than copies. It is not
a daemon and has no init script, because it halts the machine while it reads.

## What it does, in order

1. Reads the tally at the PS7's EMIO pins, before touching a GP port at all.
   A read on a GP port that nothing in the fabric answers hangs both Arm
   cores, measured on the board, and no software guard can catch it
   afterwards.
2. Looks at the drive bay and refuses to go on if it finds no pack and was
   not told there is none.
3. Halts the machine, by writing the clock control register with RUN clear.
   A read taken while the datapath moves is torn. The file records the run
   state the machine had before that halt: a machine found running is
   written with RUN and SRUN set, as they stood, and muir resumes it running
   from where it stood, with no `continue`. A machine found halted is
   written halted.

   A microcycle counter standing still is not yet a halt. A machine that
   has stopped retiring microcycles with SRUN up, in a wait that never ends
   or a pipeline that never drains, stands as still as a halted one, and a
   checkpoint is of a halted machine. So when the counter stands, the
   program asks why. On the CADR, FLAG-1 must name a halt: SRUN down (the
   console's), ERR up (HALT-CONS under ERRSTOP), or -STATHALT low (the
   statistics counter's). On QUUX the pipeline's own halted bit must be up, word 19 of the halted
   pipeline's readout, which rises only when the drain ends; SRUN follows
   RUN there, so it falls on a write of zero whether or not the drain ends.
   A machine that stands and is not halted is refused, found so or after
   the program's own halt: nothing is written, the program says where the
   counter stood, FLAG-1, PC and OPC, and exits non-zero. A machine it
   halted is started again as it was found. On QUUX a pipeline
   stopped at an error (OA-OUTSIDE-FIELDS, PDL-FIELD-MISMATCH) reads the
   same way, and is refused too: it has not drained either. So is a
   QUUX machine held in reset, whose halted bit is down. `--halt`
   refuses the same machines and marks no halt.
4. Reads the processor's memories and its register table through the
   console's readout window, and main memory and the display straight out of
   DDR through `/dev/mem`. Main memory is read at the machine's own amount,
   the console's page 2 word 37, which the card sets: the CADR's memory
   boards, `--main-memory-boards`, and QUUX's amount, `--main-memory-size`.
   A fabric older than that word has 32 boards fixed, 2MW on QUUX. The
   program's own flags are each machine's: `--boards N` on the CADR and
   `--main-memory-size <n>MW` on QUUX, in muir's form, and each is refused
   on the other machine. One that disagrees with the machine is refused,
   because a checkpoint of less memory drops memory the band has and one of
   more invents it. QUUX's video controller is read at the bitstream's own
   size, the console's page 2 word 39: its buffer, and the size muir's
   `Tv::save` writes. A bitstream older than that word is 1280 by 1024. The
   sidecar's resume line names the size as muir's `--video-size`, which muir
   refuses a checkpoint of another size under.
5. Reads every disk pack through and digests it, still halted.
6. Writes the checkpoint, then the sidecar that binds it to those packs.
7. Starts the machine again, unless told to leave it halted.

The refusal at step 5 comes before anything is written. A checkpoint that
cannot name the disk it was taken on is the thing this program exists to
prevent, so a pack that cannot be read costs the run and not the evidence.

## The format has a version, and it moves with muir

muir writes its `checkpoint::VERSION` into the header, and a file of any other
version is refused by name rather than read wrong. **The version is 54.** It is
`CHK_VERSION` in `chk.h`, and `chk.h` is a transcription of
`../muir-sim/src/checkpoint.rs` and not an interpretation of it.

So the program is tied to the commit of muir that `muir.commit` pins, and a
muir that moves the format stops the board's checkpoints loading. That failure
is loud, which is the right way round: the refusal names both versions.

Version 54 is version 49 with the Chaosnet interface's pending state after its
turn timer: a frame looped back waiting for its `START^`, the busy receiver's
decision at a destination word to come, the read register, the reads'
count-down inside a dropped frame, and the last frame dropped. The program
writes them as a fresh interface has them, six zero bytes, since the readout
does not reach the I/O board. **A file the program wrote at 49, 50 or 51,
before that change, is refused by every muir from it on**, and nothing
converts it: a board checkpoint resumes in the muir of its own card set.
Mutants 52 and 53, the six bytes left out and the read register written 1,
are caught by `build/checkpoint.pass`.

Version 49 is QUUX's revision 12, the fused return (muir's first commit of
it was version 48, and its second, with the operand address, 49): every
machine's body carries the
geometry's `macro_dispatch` and `MacroDispatch`, which a CADR writes as
zeros, the memory port carries the prefetch's word and a fetch still to be
answered, and the engine its `memstart_fetch`.

Versions 28 to 33 are what muir's second machine left. muir's `Machine`
holds either the CADR or QUUX, so its PDL buffer and level-2 map are sized for
the larger machine, 16,384 and 2,048 words, and the machine's geometry follows
the level-1 map: the level-1 entry's width, the PDL pointer's width, whether
the machine has QUUX's multiply and divide, and whether it has QUUX's tick.
The fabric is a CADR, so the program writes its 1,024 words of each followed
by zeros, and declares the CADR's geometry: a five-bit level-1 entry, a
ten-bit PDL pointer, no multiply and divide and no tick. The clocks' state
follows the geometry, written as a CADR's machine holds it. From version 45
that is QUUX's three interval timers (contract Q11), each off, periodic, its
interrupt enable 0, its period 0 and no deadline. From version 38 to 44 it
was Q1's tick, off and with no deadline, and the interval timer after it,
off, with a period of 0 and no deadline, and before version 38 the tick
carried its period, 16,667 microseconds. The display writes the size QUUX's MONO
TV would have after its board's tag, which a CADR's display keeps and never
uses. That size is 1,280 by 1,024 from version 35 on, and was 1,920 by 1,080
before it. The engine also keeps the instant the instruction in
`IR` was loaded, which only QUUX's divider reads. The program writes it as
zero, which is what a freshly built engine holds.

Version 34 adds the microcycle length of QUUX's synchronous timing model to the
engine's timing byte. The fabric declares muir's grid model, which carries no
such length, so the program writes the same byte as before. Version 35 adds
one flag to the engine: whether a microcycle held by `-HANG` has already fired
its write pulse. The flag is set only inside a hung microcycle, and a halted
machine is never inside one, so the program writes it as false.

Version 36 adds QUUX's memory cache. The bus interface gains the cache and
QUUX's own memory timing, each an option, and four fields beside them: the
cycle's address, whether the cache answered it, and when the write buffer and
the memory are free again. The machine gains one flag, whether the disk
controller has written memory since the engine last looked, which is what
empties the cache. A CADR has neither the cache nor that timing, so the
program writes both options absent, the four fields as a new bus interface
holds them, and the flag as false. Version 37 adds QUUX's block-disk after the
disk controller, as an option. The CADR fits none, so the program writes it
absent. Version 38 changes QUUX's clocks after the machine's widths: the
tick's period goes, the tick being fixed at 60 Hz, and the interval timer's
enable, period and deadline follow the tick's. Version 39 adds QUUX's keyboard
and mouse after the I/O board: the FIFO's words, the overflow, the two
enables, the counts, the buttons and the changed bit. A CADR holds all of
them off and empty, and the program writes them so.

Version 40 writes which bus the processor's cycles go through, one byte
before it: the CADR's bus interface, written as before, or QUUX's memory
port, which has no bus interface at all. The memory port is written as a
fresh port holds it: no cycle in flight, the cache at QUUX's shape with no
hits, no misses and no lines, the nominal timing of 380 ns a line fill and
290 ns a write, and main memory free. muir restores a cache warm, so a
machine resumed from this file misses where the one saved would have hit.
That moves when a read is answered and never what it reads, because the
cache is write-through and every line it holds is main memory's word. The
cache's lines are not read from the fabric.

Version 41 writes QUUX's block-disk disk as a disk of any size, where it
wrote a T-300's drive: its size in blocks and the blocks written that the
file does not hold. The size is the pack file's own, 1,024 bytes a block,
and muir refuses a checkpoint whose size is not the resuming disk's. The
program writes no written blocks, because `cadr-disk-packs` writes the
machine's blocks straight through to the card. The engine's instant that
QUUX's divider counts from is renamed, being now when the `DIV`'s operands
were ready, and is written as zero as before. The CADR's file changes in its
version alone.

Versions 42 and 43 add QUUX's revision 9 after the clocks, on both machines:
the real-time clock's setting and then the file device. A board's clock is
the host's, kept by Linux, so the program writes the setting as muir writes
it without `--rtc`, the option absent. The file device is written as muir's
`FileDevice::save` has it: four flags, the rings' bases and sizes and the
three indexes, then the head command's due time, which is always absent
because a checkpoint is refused while a command is queued. On QUUX those come
from the register page's readout, selector 12 words 7 to 9; on the CADR they
are a power-on file device's, zero. The CADR's body grows by 28 bytes, every
one of them zero.

Version 44 is muir's `micro` engine's alone and changes nothing this program
writes. Version 45 is QUUX's revision 10: the clocks are three interval
timers, each written as muir's `Timers::save` has it: on, its mode, its
interrupt enable, its period and its deadline. The CADR's body grows by 23
bytes, 632,386 to 632,409.

Version 46 writes what version 45 wrote. It is a new number because
destination 3 no longer controls timer 0 at QUUX's revision 10: a version 45
checkpoint of a band whose microcode ran timer 0 through destination 3 would
resume with timer 0 on and a microcode that can clear it only through
destination 3, which no longer reaches it, so muir refuses version 45. Only
the header's version changes.

Version 47 writes what version 46 wrote. It is a new number because QUUX's
revision 11 moved the register page to `17777400`, with block-disk and the
video controller on it, so muir refuses version 46. Only the header's
version changes.

**A QUUX checkpoint is refused while the file device has a handle open or a
command queued**, as muir refuses one, with muir's sentence. A handle is a
host file the Linux server holds, and a queued command is a host effect still
to come; neither is in the machine to be carried. `docs/file-device.md` has
the device.

On QUUX the program also waits, after the halt and before it reads main
memory, for the memory port to say its write buffer is empty (bit 33 of the
readout's flag word). A write is acknowledged when the buffer takes it and
reaches main memory behind the processor, so a machine halted just after one
can still owe DDR that word for a few hundred nanoseconds. A port that never
empties is refused by name.

Version 27 adds one byte to the engine: whose nanoseconds its clock counts,
muir's `TimingModel`. This program declares it. Version 26 added the two sync
bits the display's mode register held when its program started, written as
zeros.

Version 25 is what muir's display work left. It added four fields. The
program reads one of them out of the fabric and declares the other three.

| field | what this program writes | why |
|---|---|---|
| `Tv::board`, which of the two display boards it is | `0`, the SIMPLE TV | the program does not read the console's display word, so it writes the SIMPLE TV even when `--tv-board` has strapped the fabric's board as the LISPM TV (`chk_rtl.c`, `emit_tv`). muir compares the loaded board with `--tv-board` and refuses a resume that disagrees, so a wrong tag is a message and not a machine |
| `Tv::color_map`, sixteen colors of three channels | the first display board's map, read | register 4 is write only on the Xbus, and the fabric keeps the sixteen entries as muir does and offers them on the console face's page 4, which is where the program reads them |
| `Tv::origin`, when the running sync program last started from its location 0 | `0` | no readout reaches the sync program, so zero says it has been running since the machine came up |
| whether a color display board is on the backplane | `false`, and no board after it | the program does not read whether `cadr-console color-tv` has fitted the second board (`chk_rtl.c`, the flag after `emit_tv`). Without one, the color board's addresses `17200000` and `17377750` answer with an NXM, which is how `COLOR-EXISTS-P` finds out which machine it is on |

The first and the last are **declared** rather than read, and muir
cross-checks both. The origin is in the list below with the rest.

## The pack is bound to the checkpoint, and why it has to be

muir's format carries the blocks a run has **written** and never the disk
itself, because a pack is a file a resume opens again. On this board that is
not a remote difficulty: `cadr-disk-packs` writes the machine's blocks
straight through to the card, so the pack under a running CADR changes every
second. A checkpoint taken now and the pack ten minutes later are two
different machines, and resuming the one over the other restores a machine
into a disk it never had.

Three things make the binding, and only the first two are things muir can
enforce on its own.

**The set of units.** `Controller::load` refuses a checkpoint that says a
drive is present where the resuming machine has none — "a drive on unit 0,
and this machine has none there: give it the pack" — and the other way round,
"no drive on unit 0, and this machine has one there". The checkpoint
therefore declares exactly the units the drive bay held at the capture, taken
from the bay rather than from an option, so it cannot declare a drive that was
not there.

**The geometry of each.** `Unit::load` refuses "a pack of `Geometry { .. }`,
and the drive holds one of `..`". The geometry is taken from the pack file's
own size, exactly as `cadr-disk-packs` takes it: 269,562,880 bytes is a
T-300 at 815/19/17 and 70,937,600 is a T-80 at 815/5/17, and a file of any
other size is not a pack at all — which is also what makes a pack still being
copied in simply not a drive yet.

A QUUX disk has no geometry. Under `--machine quux` block-disk's one pack,
unit 0, is any size, and the file is a disk when `cadr-disk-packs`'s own test
says so: raw, a fixed VHD or a dynamic VHD, told by its footers and a dynamic
VHD's header, never by its size. The program links that test from
`cadr-disk-packs` rather than keeping a copy of it. A QUUX disk's `pack:` line
says what the file is and how many blocks of 1,024 bytes it holds in place of
the geometry:

    pack: unit=0 bytes=4197888 format=dynamic-vhd blocks=8192 read-only=no sha256=... file=./disk-pack-0.img

**The content of each.** Nothing in muir can check this and nothing in the
fabric can either, so it is recorded: a SHA-256 of every byte of every pack,
taken while the machine was halted, in a sidecar beside the checkpoint.

The digest is SHA-256 rather than something cheaper for one reason. Whoever
resumes the checkpoint may have neither this program nor the board, and
`sha256sum` is on the board's BusyBox, on every build host and in every
operating system anyone will resume a checkpoint on. A bespoke checksum would
answer the question only to somebody holding our source.

### The sidecar

It is a plain text file named for the checkpoint with `.packs` after it, one
`key: value` a line, with a comment block at the top saying what it is for and
what to do with it. A `pack:` line's fields are `name=value` separated by
single spaces, and `file=` is last because a path may hold a space and nothing
else may. It is beside the checkpoint and not inside it because the format is
muir's and must stay byte-compatible: muir's own round-trip test saves a
resumed checkpoint and compares it with the file it read, and a field of ours
anywhere in that stream would break it.

    format: cadr-checkpoint-packs 1
    checkpoint: checkpoints/muir-20260911-193000.chk
    checkpoint-bytes: 561465
    checkpoint-sha256: 9bc7...
    taken: 2026-09-11T19:30:00+0300
    engine: rtl
    boards: 32
    microcycles: 1234567890
    ns: 6172839506
    chaos-address: 177201
    running: yes
    machine-halted-first: yes
    packs-program-stopped: unknown
    packs: 1
    pack: unit=0 bytes=269562880 geometry=815,19,17 read-only=no sha256=... file=./disk-pack-0.img
    resume: cadr --rtl --timing-model fpga --disk-pack ./disk-pack-0.img,0 --main-memory-boards 32 --chaos-address 177201 --resume checkpoints/muir-20260911-193000.chk

`running` says whether the file records the machine running (`yes`, it was
running when the program halted it) or halted (`no`). The `resume` line is
the command, to be run as written, that resumes the file as the board ran
it. It is the line the program prints when it writes the checkpoint, the
same string.

**Run the resume line from the pack folder.** Its paths, like the
`checkpoint` and `file=` lines', are the pack folder's, whatever form the
capture was given them in: the pack as `./disk-pack-0.img` and the checkpoint
as its path from the pack folder, `checkpoints/<name>.chk`. The pack folder is
`--pack-dir`, `/mnt/card/packs` unless it is given, and `--pack-dir
/mnt/card/packs` and `--pack-dir .` run there write the same line. A file's
folder is resolved and its own name kept. The line runs from the pack folder
on the card, and from any folder the files are copied to in the card's
layout: the pack in the folder, and the checkpoint and its sidecar in its
`checkpoints/`.

**A checkpoint or a pack outside the pack folder is refused**, before the
machine is halted and before anything is written, because a line naming it
could not be run from the pack folder. A pack named with `--pack` is held to
the same rule, so a bay elsewhere is named with `--pack-dir`. So is a
checkpoint whose folder is not there.

A CADR checkpoint's sidecar carries the Chaosnet address the checkpoint
was written at, and its line names it as `--chaos-address`, since muir refuses
to resume a checkpoint at any other address. A sidecar written before the
address was named carries no `chaos-address`, and its line names none.
A QUUX checkpoint's sidecar also carries the revision, the clock's period
in units of 0.5 ns (the `sync-cycle-ticks` line), the board's memory timing
and the video controller's size, and its line names the period as
`--microcycle-ns`, the timing as `--memory-timing` and the size, since
muir's `quux` refuses a checkpoint of another revision, another period,
another memory timing or another size, and runs the one revision:

    revision: 16
    sync-cycle-ticks: 50
    memory-timing: kria
    video-size: 1920x1080
    running: yes
    ...
    resume: quux --rtl --microcycle-ns 25 --memory-timing kria --video-size 1920x1080 --disk-pack ./disk-pack-0.img,0 --resume checkpoints/muir-20261003-101500.chk

A sidecar written before the size was named carries no `video-size`, and its
line names none: its checkpoint is 1280 by 1024, muir's default.

The QUUX line names no memory flag: muir builds the machine with as much
main memory as the checkpoint has. QUUX has no memory boards, so its sidecar
records its main memory as an amount, in whole megawords, or in kilowords
when it is not a whole number of them, where the CADR's says `boards`:

    main-memory-size: 32MW

A sidecar written before that line says `boards` on QUUX too, counting
64K-word units, and is still read.

The checkpoint's own digest is in there too, so a sidecar that has drifted
away from the file it was written for is found out as well as a pack that has.

### What a resume does when it does not match

This is the part worth being blunt about. **If the packs have moved on,
nothing anywhere will say so.** muir refuses a missing drive and a wrong
geometry, and has no way at all to notice wrong contents. The disk controller
recomputes a block's header and both checkwords as it moves the block, so a
block from another moment passes every check the machine makes and is handed
to the microcode as good. What goes wrong afterwards is a Lisp world whose
structures point at pages that are no longer what they were, which can look
like anything at all — and which is exactly the kind of fault somebody would
then spend a day blaming on the fabric.

So the binding is checked before the resume, not after. Either

    cadr-checkpoint --verify checkpoints/muir-20260911-193000.chk.packs

from the pack folder, as the resume line is run, which re-reads every pack
and the checkpoint and names any that has changed,
or `sha256sum` on each pack by hand against the digests in the file. The
program says both, every time it writes a checkpoint. `--verify` needs no
board and no fabric; a pack that lives somewhere else on the resuming machine
is named with `--pack <file>,<unit>`, which replaces the recorded path and
never the recorded digest.

A pack the verify cannot read at all is a refusal and not a verdict: nothing
can be said about a file nobody has.

## What the fabric cannot fill

A muir checkpoint is a whole machine. The readout window reaches the
processor's memories and its register table, and DDR gives main memory and
the display's picture; everything else in the format is something this
program decides. **Every such field is named**, in the program's own output
every time it runs, by `cadr-checkpoint --what-it-cannot-read`, and at the
line that writes it in `chk_rtl.c`. A checkpoint that silently invented state
would be worse than no checkpoint.

The list, with what is written and what it costs a resume.

| what | written as | what it costs |
|---|---|---|
| the mode register's TRAPENB | clear | nothing: `cadr_spy_registers.sv` drops bit 4, and the fabric raises MIT's boot trap out of reset rather than from this bit, so the machine behaves as it reads |
| the clock control register's STEP, NOP11, IDEBUG, LDSTAT, and with them SSTEP and SSDONE | clear | nothing: the fabric has all of them but brings none out where this program reads, and a halted machine is what a console leaves them clear at |
| the OPC control register, all three bits | clear | nothing: the fabric behaves as all three clear, `lpc` following `pc` at every boundary and the shift register shifting at every one |
| the debug IR, 48 bits | zero | it is built and is written only by a console or a debugger, and nothing brings it out to be read back |
| the bus interface's own registers — the sixteen Unibus map entries, their read and write buffers, the error register, WRITE-THROUGH | clear, with the interrupt status at its power-on LOCAL-ENABLE | the interrupt status register, the error status register and the sixteen map entries are in the fabric now, and a checkpoint puts each of them back where a power-on leaves it. **The read and write buffers are in the fabric too and a checkpoint does NOT carry them**, so a restore leaves them at whatever the last mapped cycle put there. The readout window does not reach any of these registers |
| the disk controller, whole: command, command-list pointer, disk address, eight error flops, the channel, and the eight drives' head positions and attention timers | a controller that has just been built, heads at cylinder 0 | **a transfer in flight when the board was halted is lost.** The resumed machine's next look at the controller finds it idle with no error. The microcode's own retry covers a lost transfer; a half-walked command list it does not. Halt between transfers — the disk light is the instrument — or expect the cold boot to be re-driven |
| the display's mode register, its sync RAM, its vertical-interrupt flag | clear | the **picture** is read, out of DDR, word for word, and so is **the color map**, off the console face's page 4. Register 4 is write only on the Xbus, the RAMs being off the board, so that page is the only way to ask what a color is, and the fabric keeps the sixteen entries as muir does. The sync program is 4,096 bytes and no readout reaches it, so a resumed machine runs MIT's PROM from its power-on instant; the flag is set again at the next frame |
| the I/O board, whole: the keyboard, the mouse, the sixty-cycle interval, and the microsecond clock | idle, with the mouse's two quadrature phases at 2, which is what a fresh mouse has | **the microsecond clock is the one that matters.** `(TIME)` is that counter shifted, and off it hang the wall clock, `PROCESS-SLEEP`, every Chaosnet timer and the scheduler, so a resumed machine's time of day starts again from zero. Nothing it computes depends on the clock being continuous; what it will see is one very long or very short interval at the seam |
| the serial line's registers | idle | the CADR's serial line is in `cadr_io_board.sv` and has no readout |
| the Chaosnet interface | idle, with its switches at the address the fabric's interface holds, or the one `--chaos-address` names | `IoBoard::load` refuses a checkpoint whose address is not the resuming machine's, so the two have to agree, and the resume line names it. The program reads the interface's address as `cadr-chaosnet` reads it; muir's own default is used only when the interface cannot be read or its switches read 0. **The address is OCTAL**, as muir's own flag takes it — see below |
| the bus cycle in flight — the address and word in the air, the responder, three absolute deadlines | idle | nothing, and this is what makes the whole thing possible: muir's own rule for a netlist checkpoint is that it is taken "between cycles with nothing in flight", and a machine the console has halted at a microcycle boundary is such a point |
| the bus interface's memory-board refresh model and its own state | a machine that has just been built | **the resumed machine's clock is not the board's.** The elapsed time is real — it is the fabric's own tick count on the 10 ns grid, `CHK_GRID_NS` — but the refresh one-shot fires once, early, for nothing. This is the one place the file knowingly hands muir a machine that is not bit-for-bit the board's |
| how long the machine has stalled, and how many bus cycles it has made | zero | nothing computes from either; they are totals muir keeps |
| `Rtl`'s trace and flag columns, twelve words each | zero | nothing: they are a record of the last microcycle that nothing running reads, overwritten by the first microcycle after a resume |
| the disk packs | not in the format at all | the sidecar, above |

The two that change what a resumed machine *does* are the disk controller and
the microsecond clock. Everything else in the table either has no reader or is
written at the value the fabric behaves as.

## A QUUX checkpoint

`cadr-checkpoint --machine quux` takes a checkpoint of a QUUX bitstream,
`--machine` being muir's own flag and the one `cadr-terminal` and
`cadr-disk-packs` take. The program asks the fabric which machine it is before
it reads anything. The readout's register table has QUUX's signature,
`0x5155`, at entry 21, with MACHINE-ID's revision, and the CADR answers
`RO_NO_MEMORY` there. A checkpoint of the other machine is refused, because it
would be one machine's fields filled from the other's, and so is a QUUX of an
older revision than the program writes, named by the revision entry 21 reads.

What the file holds is the pipeline's checkpoint and the Ethernet device's
(the two sections below). Two checks hold the board's writer to muir. The core's
checkpoints group holds the file the board's own reader and writer make off the
core to muir's own byte for byte. `make build/checkpoint.quux.pass` writes a
QUUX file from the package's fixed machine through a modeled window
(`checkpoint_test.c`'s `fill_quux`), whose devices hold what a known history
leaves in them. `golden/src/quux_checkpoint.rs` runs the same history on
muir's machine through its register page, composes the pipeline's state in
`Pipeline::save`'s order, has a fresh pipeline load the result and save it
back unchanged, and writes muir's file for that machine. The two files must be
the same file, byte for byte. The package also writes the same machine as each
other board writes it, its memory timing that board's preset, each file with
its sidecar, laid out as the card holds them: the pack in a pack folder, and
each file and its sidecar in its `checkpoints/`. muir's `quux` then resumes
each file under its sidecar's resume line, run from the pack folder, with no
flag of the check's own but the stop and the file to save back,
and saves it back byte for byte, and its report names the microcycles, the
nanoseconds and the main memory the model gave. Mutants 11, 17, 18, 31, 39,
40, 59, 60, 61 and 62 of `chk_rtl.c` and `pack_bind.c` are caught there.

**Neither machine's checkpoint can be restored to the fabric.** The readout
window only reads, so a checkpoint is resumed in muir and not on
the board. Restoring one would need a write path into every memory and
register named here, which neither machine has.

## The pipeline's checkpoint

QUUX's checkpoint is `Pipeline::save`'s body (contract G3 revision 15,
A15b.13, at revision 16): the machine, whose level-1 byte carries the
revision with `<7>` set and which ends with word 225; then the clock's period in units of 0.5 ns,
the memory port's timing and cache, and the pipeline's state between two
microcycles (contract G3 revision 15, A15b.13), D's wait among it: a halt
that squashed a return's delay slot leaves D waiting with the slot to fetch
again, and the file carries both (A15b.9). The control store's words are 64
bits. A fabric checkpoint resumes in muir; nothing is restored to the fabric.

The machine is read through the pipelined core's own window
(`rtl/machine/quux15_core.sv`, behind `rtl/plumbing/quux15_face.sv`, the
console's words), not the CADR's register table. The memories are read on
their write ports, so the readout adds nothing to the core's read paths, and
only halted, drained, when nothing writes. A write of selector 15 first takes
the devices' snapshot: the instant and the interval timers, with each timer's
deadline as muir keeps it, so that every time word names one instant however
long the reads take. The devices' words carry the keyboard and the mouse
too: the FIFO's head and count, the flags, the buttons and the counts in one
word, and the FIFO's words from 64 up. `cadr-readout`'s `ro_read_quux15`
reads it all, and `chk_rtl.c` writes the file.

What the file holds otherwise than muir's own:

- the cache written empty, no line held and the recency zero. A drained
  cache's words are main memory's, so a resumed machine misses where muir's
  would hit, which moves when a read is answered and never what it reads;
- the I/O board as muir's machine comes up, with no Chaosnet interface.
  Nothing of the board is QUUX's; a resumed machine's board catches up
  with the clock at its first look;
- a data push's word waiting for the micro stack at the stack's 19 bits,
  which are all `SPC<18:0>` keeps.

`cadr-checkpoint --what-it-cannot-read` names them on a QUUX board.

## The Ethernet device in the checkpoint

QUUX's checkpoint is muir's version 58: the pipeline's body, the level-1 byte
carrying revision 16, with the Ethernet device after word 225
(`EthernetDevice::save`), and an I/O board with no Chaosnet interface, which
revision 16 has not got (QUUX's Ethernet contract, section 8 R4). muir
refuses version 57, revision 16's file with the interface. The device's
registers, its indexes, its four counters and 253 to 257 are read off the
devices' words 24 to 30 (`rtl/machine/quux16_ethernet.sv`'s readout). A transmit waiting between 245
and 244 is the board's program's to send, and the board has no instant of
muir's to give for it, so the file names the checkpoint's own instant as its
due time, and a resumed machine sends it at once.

muir refuses a resume under other `--ethernet-mac`, `--ip-address` or
`--ip-gateway` than the checkpoint's, so the resume line names the three the
board's device holds, and the sidecar records them as `ethernet-mac:`,
`ip-address:` and `ip-gateway:` lines. `make check`'s checkpoints group holds the board's
file to muir's byte for byte, and
`quux16_resume.quux.pass` resumes one under those flags and has muir refuse
it under its defaults.

**Block-disk's pack** is bound to the file as the CADR's pack is, its
registers, DONE and the instant it was last told read off the devices' words.
A checkpoint is refused while a transfer is in flight: its walk running or
its words still on the memory port, which muir moves at START and no file
carries (the devices' word 15 `<4>`, which `chk_rtl_refusal` reads). Halt the
machine between transfers. The halt itself does not wait for a walk, only for
the processor's writes.

The resume line names `--microcycle-ns` at the bitstream's period, which
muir refuses another at, as it refuses another memory timing or cache.

**The memory timing is muir's preset for the board.** The file declares the
memory port's read, write and occupancy in ns, and the resume line names the
preset by the name muir's `--memory-timing` takes: `kria` on the Kria KR260,
`arty` on the Arty Z7-20 and `de25` on the DE25-Nano (`cadr_board.h`'s
`CADR_BOARD_MEMORY_TIMING`). The figures are muir's `PortTiming` presets in
its `src/pipeline/port.rs`, copied into `chk_rtl.c`'s `chk_memory_timings`.
`memory_timing_pin.quux.pass` holds that table, and the preset each board
names, to muir's at the pinned commit, and `checkpoint.quux.pass` resumes
each board's file of the package's machine in muir under the file's own
resume line, run from the pack folder, and nothing else.

**The proof is the core's own testbench.** The checkpoints group of
`golden/src/quux15_console.rs` halts programs of every kind at clocks spread
over each run, ends each run there with muir's checkpoint of the halted
machine, and `tb/quux15_core_tb.cpp` reads the core through its window with
the board's own reader and writes the file with the board's own writer, both
linked into it. The two files must be the same bytes, at 10 ns and at the
Kria's 17 ns. muir's file is taken with the cache empty, the I/O board fresh
and the stack's word at 19 bits, the three differences above, and with the
control store under the PROM zero, as muir's own machine holds it and the
board's writer writes it (the traces' machine comes up all ones there, the
fabric's power-on convention, which nothing fetches); every other byte is
muir's. A run muir refuses, a file device with a command queued, the
board's writer must refuse too. The mutation records `quux15-readout-*`,
`quux15-checkpoint-*` and the devices' time words are caught there.

## The CADR's address is the interface's own

On the CADR the program reads the address the fabric's Chaosnet interface
holds, as `cadr-chaosnet` reads it: the interface's face at its base, its
identity word, then the switches, which `cadr-chaosnet` set when it started.
The checkpoint's switches are written at that address, and the sidecar's
resume line names it. A checkpoint of a board at 177201 written at muir's
default, 177001, or a resume line naming no address, is refused: "switches
read 177201, this machine's 177001".

`--chaos-address` still wins. When it differs from the interface's address,
the program says so, naming both, because muir would refuse the checkpoint
at the board's own address. When the interface cannot be read, or its
switches read 0 because nothing has set them, the program says so and writes
the address asked, or muir's default.

QUUX has no Chaosnet. Its checkpoint keeps the address asked, or muir's
default, and its resume line names none.

The package's check holds all of this on a model of the interface's face.
Mutant 54 takes muir's default whatever the interface holds, and mutant 55
drops the address from the resume line; the check fails on both.

## `--chaos-address` is octal, as muir's is

muir's flag "wants one address in octal or subnet:host", and
`chaos::parse_address` is the whole of what it takes. A bare octal number, with
no prefix of any kind: not `0o`, not `0x`, and a leading `0` changes nothing
because the string is octal already. Or `subnet:host`, each an octal byte of at
most `0o377`. In both forms both halves must be non-zero, so `0`, `377` and
`177000` are not addresses.

This program takes exactly that, and it used to take decimal. `strtoul` with a
base of 0 reads a plain string of digits as decimal, so `--chaos-address
177100` put `0o131714` — the low sixteen bits of one hundred and seventy-seven
thousand — into the checkpoint's switches. muir then refused the file and said
which two addresses disagreed. Only the spelling `0177100` worked. It was found
on the board.

Twenty-three spellings are held in the package's own check, including the one
that was wrong, a value with a digit 8, both prefixes, and every form muir
refuses. The eighth mutant is the defect itself: it reads the address as
decimal, and muir refuses the file it writes.

## The proof, and what each leg of it proves

`make build/checkpoint.pass` is the check. It builds the program's core
against a model of the console's window on the build host — no board, no
fabric, nothing but a C compiler — and then hands the file it writes to muir.

The round trip is the center of it: muir loads the file and saves it back, and
the two are compared **byte for byte**. That is muir's own round-trip property
and it holds the framing — every field at the offset muir's reader expects,
every array's count, every flag a 0 or a 1, every range check passed, and the
packing muir's own rather than merely a legal one, since `unpack` accepts any
valid packing but `save` re-emits muir's.

**One leg is not enough, and that was measured rather than assumed.** Three
mutants of `chk_rtl.c` were built and run against each leg, and no leg caught
all three:

| mutant | caught by |
|---|---|
| `prog_boot` dropped, so every byte after it is at the wrong offset | muir refuses the file |
| the mouse's quadrature phases written 0 where a fresh mouse has 2 | the recorded digest, and nothing else |
| `Machine::opc` taken from the OPC shift register instead of LPC | the recorded digest, and nothing else |

There are eight now. Format 25's four fields have one mutant each, for the
same reason: a field nothing is aimed at is a field the check does not hold.
The eighth is the address's own spelling.

| mutant | caught by |
|---|---|
| the display board written as the LISPM TV where the fabric is the SIMPLE TV | muir refuses it: "a lispm-tv checkpoint, and `--tv-board` is simple-tv" |
| a color display board claimed on a backplane that has none | muir refuses it at the short read, having tried to take a second display out of the eight hundred bytes that are left |
| the color map written all ones where the board's own map is read | the recorded digest, and nothing else |
| the sync program's origin written at the machine's clock instead of zero | the recorded digest, and nothing else |
| `--chaos-address` read as decimal, which is what `strtoul(.., 0)` does | muir refuses it, naming the two addresses that disagree |

**The eighth is a mutation of a PARSER and the loop judges files**, so the
check's own twenty-three spellings are skipped while a mutant is built ---
they would be asserting the function the mutant replaced, the test would exit
non-zero, and the loop would call it BROKEN rather than caught. The two hold
different halves: the spellings hold the parser, and the mutant holds that the
field in the file comes down it. `checkpoint_test.c` says so at the skip.

The round trip cannot see a wrong value in a right-shaped slot, by
construction: muir re-saves whatever it read, so any valid value survives it.
So the check has two more legs. muir's own report of what it resumed names the
microcycle count and the nanoseconds the synthetic machine was given, asserted
in muir's words rather than through an exit code. And the file's SHA-256 is
compared with a value recorded in the Makefile, which is a golden value and
moves like one: when it changes, the round trip is re-run, the new value is
recorded, and the commit says what moved.

`CHK_MUTATE` is never defined in the program installed on the board.

## Taking one on the board

`cadr-disk-packs` polls every 250 microseconds and writes a block back with
`fdatasync` as soon as the channel is not using its slot. With the CADR
halted the channel is idle, so within about a millisecond of the halt every
block the machine has written is on its pack. That is what makes the normal
capture one command.

    cadr-checkpoint -o /mnt/card/packs/checkpoints/$(date +%Y%m%d-%H%M%S).chk

It halts the machine, reads it, digests the packs it finds in the pack
folder, `/mnt/card/packs`, writes the checkpoint and the sidecar into its
`checkpoints/`, and starts the machine again. It names the pack and the
checkpoint from the pack folder, and so does the line it prints, which is its
sidecar's resume line: run that line, and `--verify`, from the pack folder.
Make `/mnt/card/packs/checkpoints` first; `cadr-disk-packs`
stats only the eight `disk-pack-N.img` names, so a directory beside them is
invisible to it. Digesting a T-300 is 269 MB read off the card and hashed, so
it takes a while, and the machine is halted throughout, which is the point.

If you want the packs held still by something stronger than the halt — no
program that writes packs running at all — there is a longer way, and it has
one trap in it: **the init script's `stop` unmounts the card**, so it has to be
mounted again before the packs can be digested. That `stop` also writes the
board's clock to `clock` at the root of the card before it unmounts it, which
is one small write and is not a pack.

    cadr-checkpoint --halt
    /etc/init.d/S80cadr-disk-packs stop
    mount -t vfat /dev/mmcblk0p1 /mnt/card
    cadr-checkpoint --already-halted --leave-halted --packs-stopped \
        -o /mnt/card/packs/checkpoints/$(date +%Y%m%d-%H%M%S).chk
    umount /mnt/card
    /etc/init.d/S80cadr-disk-packs start
    cadr-checkpoint --start

The card is mounted read-write, because the checkpoint goes into the pack
folder's `checkpoints/` like any other; with `cadr-disk-packs` stopped,
nothing writes the packs. A read-only mount leaves the checkpoint nowhere to
go but outside the pack folder, in `/tmp` for one, and the program refuses
that before it reads anything: a resume line naming `/tmp` could not be run
from the pack folder. On a card of the older two-partition shape that mount
is `/dev/mmcblk0p2`, and the bay is that partition's own root rather than
`packs/` in it, so it is named with `--pack-dir`.

`--already-halted` refuses to read a machine that is still retiring
microcycles, so the order cannot be got wrong silently, and both it and
`--halt` refuse a machine that has stopped retiring without halting (step 3
above). `--halt` writes down
the microcycle count it halted the machine at, in
`/var/run/cadr-checkpoint-halted`, and `--already-halted` records the
machine as running when the count still stands there, since it was running
until that halt; `--start` takes the note away. `--packs-stopped` is
the operator saying that nothing was writing the packs; the program cannot
see that for itself, so the sidecar records it as `unknown` when it is not
said rather than claiming something nothing checked.

Either way, copy the `.chk` and its `.packs` sidecar off the board together —
they are one thing — and the pack itself if the checkpoint is to be resumed
anywhere but on the card it came from, in the card's layout: the pack in a
folder, and the two files in its `checkpoints/`. The resume line then runs
from that folder.
