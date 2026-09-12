<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# The checkpoint

Written at the checkpoint slice, 2026-09-11, against `cadr-checkpoint` as it
stands at this slice. Numbers below are measured at that point.

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
   A read taken while the datapath moves is torn.
4. Reads the processor's memories and its register table through the
   console's readout window, and main memory and the display straight out of
   DDR through `/dev/mem`.
5. Reads every disk pack through and digests it, still halted.
6. Writes the checkpoint, then the sidecar that binds it to those packs.
7. Starts the machine again, unless told to leave it halted.

The refusal at step 5 comes before anything is written. A checkpoint that
cannot name the disk it was taken on is the thing this program exists to
prevent, so a pack that cannot be read costs the run and not the evidence.

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
    checkpoint: muir-20260911-193000.chk
    checkpoint-bytes: 561465
    checkpoint-sha256: 9bc7...
    taken: 2026-09-11T19:30:00+0300
    engine: rtl
    boards: 32
    microcycles: 1234567890
    ns: 6172839506
    machine-halted-first: yes
    packs-program-stopped: unknown
    packs: 1
    pack: unit=0 bytes=269562880 geometry=815,19,17 read-only=no sha256=... file=/mnt/packs/disk-pack-0.img
    resume: muir --rtl --disk-pack /mnt/packs/disk-pack-0.img,0 --main-memory-boards 32 --resume muir-20260911-193000.chk

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

    cadr-checkpoint --verify muir-20260911-193000.chk.packs

which re-reads every pack and the checkpoint and names any that has changed,
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
| the clock control register's STEP, NOP11, IDEBUG, LDSTAT | clear | a resumed machine cannot be single-stepped from where the board left it; neither can the board |
| the OPC control register, all three bits | clear | nothing: the fabric behaves as all three clear, `lpc` following `pc` at every boundary and the shift register shifting at every one |
| the debug IR, 48 bits | zero | nothing: IDEBUG is not built, so nothing would look at it |
| the bus interface's own registers — the sixteen Unibus map entries, their read and write buffers, the error register, WRITE-THROUGH | clear, with the interrupt status at its power-on LOCAL-ENABLE | the interrupt status register, the error status register and the sixteen map entries are in the fabric now, and a checkpoint puts each of them back where a power-on leaves it. The read and write buffers are not, their one master being the debug cable's. Nothing the boot PROM does touches any of them |
| the disk controller, whole: command, command-list pointer, disk address, eight error flops, the channel, and the eight drives' head positions and attention timers | a controller that has just been built, heads at cylinder 0 | **a transfer in flight when the board was halted is lost.** The resumed machine's next look at the controller finds it idle with no error. The microcode's own retry covers a lost transfer; a half-walked command list it does not. Halt between transfers — the disk light is the instrument — or expect the cold boot to be re-driven |
| the display's mode register, its sync RAM, its vertical-interrupt flag | clear | the **picture** is read, out of DDR, word for word. The sync RAM is muir's model of a sync generator the fabric does not have; the flag is set again at the next frame |
| the I/O board, whole: the keyboard, the mouse, the sixty-cycle interval, and the microsecond clock | idle, with the mouse's two quadrature phases at 2, which is what a fresh mouse has | **the microsecond clock is the one that matters.** `(TIME)` is that counter shifted, and off it hang the wall clock, `PROCESS-SLEEP`, every Chaosnet timer and the scheduler, so a resumed machine's time of day starts again from zero. Nothing it computes depends on the clock being continuous; what it will see is one very long or very short interval at the seam |
| the serial line's registers | idle | the CADR's serial line is in `cadr_io_board.sv` and has no readout |
| the Chaosnet interface | idle, with its switches at the address `--chaos-address` names | `IoBoard::load` refuses a checkpoint whose address is not the resuming machine's, so the two have to agree; muir's own default is used unless told otherwise |
| the bus cycle in flight — the address and word in the air, the responder, three absolute deadlines | idle | nothing, and this is what makes the whole thing possible: muir's own rule for a netlist checkpoint is that it is taken "between cycles with nothing in flight", and a machine the console has halted at a microcycle boundary is such a point |
| the bus interface's memory-board refresh model and its own state | a machine that has just been built | **the resumed machine's clock is not the board's.** The elapsed time is real — it is the fabric's own tick count on MIT's five-nanosecond grid — but the refresh one-shot fires once, early, for nothing. This is the one place the file knowingly hands muir a machine that is not bit-for-bit the board's |
| how long the machine has stalled, and how many bus cycles it has made | zero | nothing computes from either; they are totals muir keeps |
| `Rtl`'s trace and flag columns, twelve words each | zero | nothing: they are a record of the last microcycle that nothing running reads, overwritten by the first microcycle after a resume |
| the disk packs | not in the format at all | the sidecar, above |

The two that change what a resumed machine *does* are the disk controller and
the microsecond clock. Everything else in the table either has no reader or is
written at the value the fabric behaves as.

## The proof, and what each leg of it proves

`make build/checkpoint.pass` is the check. It builds the program's core
against a model of the console's window on the build host — no board, no
fabric, nothing but a C compiler — and then hands the file it writes to muir.

The round trip is the centre of it: muir loads the file and saves it back, and
the two are compared **byte for byte**. That is muir's own round-trip property
and it holds the framing — every field at the offset muir's reader expects,
every array's count, every flag a 0 or a 1, every range check passed, and the
packing muir's own rather than merely a legal one, since `unpack` accepts any
valid packing but `save` re-emits muir's.

**One leg is not enough, and that was measured rather than assumed.** Three
mutants of `chk_rtl.c` were built and run against each leg:

| mutant | caught by |
|---|---|
| `prog_boot` dropped, so every byte after it is at the wrong offset | muir refuses the file |
| the mouse's quadrature phases written 0 where a fresh mouse has 2 | the recorded digest, and nothing else |
| `Machine::opc` taken from the OPC shift register instead of LPC | the recorded digest, and nothing else |

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

    cadr-checkpoint -o /mnt/packs/checkpoints/$(date +%Y%m%d-%H%M%S).chk

It halts the machine, reads it, digests the packs it finds in `/mnt/packs`,
writes the checkpoint and the sidecar, and starts the machine again. Make
`/mnt/packs/checkpoints` first; `cadr-disk-packs` stats only the eight
`disk-pack-N.img` names, so a directory beside them is invisible to it.
Digesting a T-300 is 269 MB read off the card and hashed, so it takes a
while, and the machine is halted throughout, which is the point.

If you want the packs held still by something stronger than the halt — no
program that writes packs running at all — there is a longer way, and it has
one trap in it: **the init script's `stop` unmounts `/mnt/packs`**, so the bay
has to be brought back read-only before the packs can be digested, and the
checkpoint then has nowhere on the card to go.

    cadr-checkpoint --halt
    /etc/init.d/S80cadr-disk-packs stop
    mount -t vfat -o ro /dev/mmcblk0p2 /mnt/packs
    cadr-checkpoint --already-halted --leave-halted --packs-stopped \
        -o /tmp/$(date +%Y%m%d-%H%M%S).chk
    umount /mnt/packs
    /etc/init.d/S80cadr-disk-packs start
    cadr-checkpoint --start

`--already-halted` refuses to read a machine that is still retiring
microcycles, so the order cannot be got wrong silently. `--packs-stopped` is
the operator saying that nothing was writing the packs; the program cannot
see that for itself, so the sidecar records it as `unknown` when it is not
said rather than claiming something nothing checked. `/tmp` is RAM here, and
the checkpoint has to be copied off before the board is rebooted.

Either way, copy the `.chk` and its `.packs` sidecar off the board together —
they are one thing — and the pack itself if the checkpoint is to be resumed
anywhere but on the card it came from.
