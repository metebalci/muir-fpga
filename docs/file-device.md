<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# QUUX's file device and real-time clock

QUUX's hardware revision 9 adds two devices to the register page: a real-time
clock at word 103 and a file device at words 160 to 171, with its interrupt
at word 100 `<6>`. QUUX reads and writes files on its host through the file
device. muir's `docs/quux.md` ("The file device" and "The real-time clock")
defines the machine's side of both: what each register reads, what each write
does, the two rings of commands and responses in the machine's main memory,
the ten commands, and the folders of the host served as one pathname host,
`HOST`.

On a board the registers are in the fabric, and the device's other half is a
Linux program, `quux-file-device`. It reads each command and its buffers out
of DDR, does the command on a Linux folder, and writes the answer back. It
also keeps the real-time clock. This page describes both halves as they are
built here: the fabric's page that Linux reaches, and the program.

Both devices are QUUX's alone. A CADR bitstream has no register page, and the
page described below is answered there by the default slave like every other
address nothing claims.

## What HOST serves on a board

The card's `sys/`, `site/` and `home/` are served as three named mounts, in
muir's grammar:

    --file-root sys=/mnt/card/sys
    --file-root site=/mnt/card/site
    --file-root home=/mnt/card/home

`sys/` and `site/` hold the band's Lisp files, and `home/<user>/` the users'
own. With named mounts and no default folder, `HOST:/` holds these three and is
read-only. The card's root is not served whole, because it also holds the boot
files and `packs/`, which is the disk the machine is running on.

The init script makes `home/` when the card has none, because a folder the
machine may write has to exist. It serves `sys/` and `site/` when they are
there, and says on the console which one is missing when not.

A card that names `--file-root` in `fpgarc` gets its own lines and none of the
script's. The flag is muir's, with muir's grammar, and it is taken once for
each mount. `<folder>[,ro]` is `HOST:/`, and `<name>=<folder>[,ro]` is the
top-level directory `<name>`. `,ro` makes a mount read-only.

The init script, `S81quux-file-device`, starts the program only when `fpgarc`
says `--machine quux`. On any other card it says so and starts nothing.

## The program's flags

    --file-root <folder>[,ro]           HOST's /
    --file-root <name>=<folder>[,ro]    the top-level directory <name>
    --no-guard                          skip the fabric guard
    --log <file>                        where to write; repeatable

`cadr_daemon` gives it the console and `/var/log/quux-file-device.log`, as it
gives every daemon here.

## The page

The page is the fifth 4 KB page of the port the other faces share, at the
pack side's base plus `0x4000`: `0x4000_4000` on a Zynq board's `M_AXI_GP0`,
and `0x4000_4000` on the DE25-Nano's HPS-to-FPGA bridge, which hands the
fabric the offset `0x0000_4000`. `cadr_board.h` names it `CADR_BOARD_FD_BASE`
for both boards, and `qfd_face_fabric.c` is the only file of the program that
knows the offsets below.

Every access is a single aligned 32-bit word. A write of fewer than four bytes
goes nowhere, because no register here has halves that mean anything apart. A
word not in the table reads 0 and takes no write.

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `0x000` | IDENT | read | `0x5146_4439`, "QFD9". The program refuses to run on anything else. A CADR bitstream reads `0x4E4F_4E45`, "NONE", here. |
| `0x010` | RTC_SECONDS | read, write | Read: what word 103 reads now. Write: the seconds, taking effect at once, starting the second at the fraction staged at `0x014` (0 if none is staged). The stage is then cleared. |
| `0x014` | RTC_FRACTION | read, write | Read: nanoseconds into the current second, 0 to 999,999,990. Write: stages a fraction for the next write of `0x010`. A value of a second or more is ignored and the stage keeps what it had. |
| `0x100` | STATE | read | `<0>` enabled (word 160 `<0>`); `<1>` the interrupt enable (160 `<8>`); `<2>` busy, the program's claim; `<3>` quiet (161 `<1>`); `<4>` work waiting; `<5>` the last completion was refused; `<31:16>` EPOCH. |
| `0x104` | CLAIM | read, write | Write `{EPOCH, <0> = 1}` to set busy, which takes effect only while enabled and in that epoch. Write `<0> = 0` to clear busy, in any epoch. Read: `<0>` busy. |
| `0x108` | CMD_BASE | read | The command ring's base, word 162, a physical word address. |
| `0x10C` | CMD_LOG2 | read | The log2 of the command ring's entries, word 163. |
| `0x110` | RESP_BASE | read | The response ring's base, word 166. |
| `0x114` | RESP_LOG2 | read | The log2 of the response ring's entries, word 167. |
| `0x118` | CMD_PROD | read | The command producer, word 164, as the program may see it (below). 0 while disabled. |
| `0x11C` | RESP_PROD | read, write | Read: words 165 and 170, which are always equal. Write `{EPOCH, <15:0> index}`: the commands up to `index` are complete (below). |
| `0x120` | RESP_CONS | read | The response consumer, word 171. |
| `0x124` | HANDLES | read, write | Write `{EPOCH, <7:0> count}`: the handles open, 0 to 64, from the next accepted completion on. Read: the count the machine sees in 161 `<23:16>`. |
| `0x128` | MEM_WORDS | read | The words of main memory this bitstream has, the memory boards' count times 65,536: `0x20_0000` today. |

A word written `{EPOCH, ...}` carries the epoch in its top sixteen bits.

## The real-time clock

Word 103 is the real time in whole seconds since 1970-01-01 00:00 UTC, as an
unsigned 32-bit number. The machine only reads it: a write of word 103 goes
nowhere. The fabric keeps a count of seconds and nanoseconds, 10 ns a tick of
its 100 MHz clock, carrying into the seconds at each 10^9 ns. The seconds hold
at 2^32 - 1 and never wrap to 0.

The host keeps the time. The program writes the host's time at the start and
whenever the second changes: the nanoseconds to `0x014` and then the seconds
to `0x010`. The two land together at the second write, so the fabric's second
starts where Linux's does, to within the time the writes take.

The count runs whatever the machine does, as a real clock runs on its own
crystal: a halt, a machine reset from the console or the board's reset button
and a boot all leave it alone, so a band reading word 103 as it boots reads
the time. It comes up at 0 when the fabric is configured, and the program
sets it within the second.

## The rings, and what the page promises

The machine owns the command producer (164) and the response consumer (171).
The program owns the response producer (170, written through `RESP_PROD`) and
the handles open. Commands and responses are entries of eight words in the
two rings in main memory, as muir's `docs/quux.md` gives them. A ring's slot
`i` is at its base plus `8 * (i mod entries)`, and a physical word address
`w` is at byte `CADR_BOARD_MAIN_BASE + 4 * w` in the processing system's
memory.

**CMD_PROD moves only once the processor's writes before it are in main
memory.** The processor writes a command into its ring and then writes 164.
Its memory writes go through a write buffer, so the command may still be in
that buffer when 164 lands. The fabric shows the new producer at `0x118` only
once the buffer has drained behind the write of 164, so every command up to
`CMD_PROD` can be read from main memory.

**A completion invalidates the machine's whole cache before the machine sees
it.** The program writes buffer B and the response entry into main memory
itself, and the machine's cache cannot see those writes. So an accepted write
of `RESP_PROD` drops the whole cache in the tick after it reaches the machine,
the tick the interrupt, word 100 `<6>`, rises; 165, 170, 161 `<8>` and 161
`<23:16>` show the new values in the tick after that. The page hands every
write to the machine a tick after the port takes it.

**Work** (`STATE <4>`) is up while the device is enabled, `CMD_PROD` differs
from `RESP_PROD`, and the response ring has a free slot: `RESP_PROD -
RESP_CONS` is less than its entries.

**Quiet and the claim.** After a disable the machine may reuse ring and buffer
memory once quiet, 161 `<1>`, reads 1. The program may be in the middle of a
command then, copying into DDR, so quiet is "not enabled and not busy", and
busy is the program's claim: taken before it touches the machine's memory for
a command and dropped after. A disable does not clear busy; only the program
does.

**The epoch** counts the disables, modulo 2^16. It goes up by one whenever
enabled goes from 1 to 0, whether the machine wrote 160, `RESET-DEVICES`
disabled the device, or the whole machine was reset. The claim, the
handle count and the completion each carry the epoch the program last read,
and the fabric ignores one that carries a stale epoch. A program that sees the
epoch move closes every handle, discards every write and forgets the command
it holds. A command overtaken by a disable writes memory while its claim still
holds quiet low, and is never published. Its host effect stands, which the
contract allows. Neither busy nor the epoch is reset with the machine, so a
completion from before a machine reset can never land after it.

**`RESET-DEVICES`** is the register page's word 104 `<0>` (QUUX revision
10, contract Q11): a write with `<0>` set disables the device and clears 161
`<2>` and `<3>`, as a write of 160 with 0 disables it, whoever writes it.
The boot PROM writes it before it reads the disk, and muir-sys's microcode
may write it too. `INTERRUPT-CONTROL<28>`, `PROG.UNIBUS.RESET`, reaches
nothing on QUUX since revision 10. The ring bases and sizes stay. Quiet
follows as for any disable, when the program drops its claim.

**A completion** is accepted only when the device is enabled and the write's
EPOCH is the current one, the index moves 170 forward by 1 up to the number of
commands shown, `CMD_PROD - RESP_PROD`, and the response ring does not
overfill: `index - RESP_CONS` is at most its entries. Otherwise nothing changes
and `STATE <5>` goes up, until the next accepted completion or the next write
of `CLAIM`. A write of `HANDLES` in the current epoch is staged and lands with
the next accepted completion, so the machine sees the handles open and 170
change in the same tick.

## One step of the program

The program reads STATE. If nothing is waiting it sleeps a millisecond: the
page raises no interrupt to Linux and has no doorbell. Otherwise it takes the
claim, reads the page again, does the command at slot `165 mod size`, and
reads the page a third time. Then it writes the handle count and the
completion, and drops the claim. If the page does not take a completion under
the same epoch, the program stops rather than doing the command again.

**The order of the writes.** Buffer B and the response entry are written
through an uncached mapping of DDR (`/dev/mem`, `O_SYNC`). Then comes
`__sync_synchronize()` and a `dsb sy`, then the completion. The disk pack
program has used the same order on every board: words into DDR, a barrier,
then a face register that makes the fabric read them. **For this page it is
not yet measured on a board.**

## Writes, and what the start sweeps

A write goes to a temporary file beside its target, named `.quux-write-` and
more, and CLOSE renames it onto the name. The file therefore appears or changes
whole. DIRECTORY and COMPLETE never show such a name. A power cut or a killed
program leaves one behind, so at the start the program walks every writable
mount for them and removes each one it finds. A read-only mount is left as it
is, and symlinks are not followed.

## LOG

LOG's line goes to the program's log, `log: ` and the text, with a byte outside
040-176 written as a backslash and three octal digits. This is muir's text,
and the log is the console and the file above.

## A checkpoint waits for an idle device

A handle's host file and a command's host effect are outside the machine, so a
checkpoint is refused while a handle is open or a command is queued, as muir
refuses one, with muir's sentence. `cadr-checkpoint` reads the file device's
registers through the console's readout window, selector 12 words 7 to 9: the
rings, the three indexes, the flags and the handles open. The count lands with
the completion it belongs to, so a checkpoint that finds 164 equal to 165
finds the count that goes with it. No lock file is needed. The checkpoint
writes the real-time clock as the host's clock, which is what a board's clock
is, and the file device's registers as muir's `FileDevice` saves them.

## The card is FAT

The card is FAT32, and the device's contract accounts for three things FAT
does.

- **Case is exact.** FAT finds a name whatever its case. The program asks the
  folder's own list for the spelling whenever the name's case-flipped twin is
  the same file, so a name that matches only with case ignored is not found.
- **Times are kept to two seconds.** CLOSE answers the time the host then
  has, and the Lisp side takes that, never the date it sent.
- **Some names are refused.** FAT refuses `:`, `*`, `?` and others with
  EINVAL, which answers IPS rather than DAT.

## What holds it

The fabric's side:

- `build/quux_files.quux.k4.pass` runs a program on the whole machine that
  drives every register of the file device against muir's own device, with
  the testbench playing the program at muir's instants through the machine's
  host side. It also checks that when the host is first shown a command, the
  command's entry is already in main memory as the processor wrote it.
- `build/quux_rtc.quux.k4.pass` reads word 103 against muir's clock with the
  host setting it twice, once to the last second.
- `build/quux_fd_face.pass` drives this page over AXI in the program's order,
  with the machine's register page behind it, and holds every rule above,
  including each ordering by the tick.
- `build/gp0_split.pass` sweeps the port with the page present, as QUUX
  builds it, and absent, as the CADR builds it.
- `build/checkpoint.pass` and `build/checkpoint.quux.pass` hold the
  checkpoint's format against muir's, and the refusal.

The program's side, `build/quux_file_device.pass`, which the top-level
mutation runner does not reach:

- **muir is the judge.** `golden/src/quux_file_device.rs` runs muir's own
  device over each script of rings in `qfd_scenarios.py`, against one copy of
  a folder. `qfd_test` runs this program's core, service step and page face
  over the same script, against another copy, through a model of the page's
  rules. `qfd_compare.py` then holds the two transcripts and the two folders
  after to each other, byte for byte. A transcript has every response, every
  buffer B, every LOG line, the handles and the commands queued, the
  checkpoint's refusal, and a digest of all of main memory. The folders are
  compared by name, kind, permissions, content, time and link target.
- **The scripts must reach something.** muir's transcripts must show all ten
  opcodes and every status but NMR and DAT, which no folder of the build host
  produces on its own.
- **The errno table.** muir's status for every errno from 1 to 133 is compared
  with this program's.
- **The model watches the program.** Every word of main memory must be touched
  under the claim, every completion must follow a barrier that follows the
  last word written, and the claim must be dropped when a step returns.
- **The unit checks** reach what a script cannot: a disable in the middle of a
  command, the words the program writes to the page and their order, the
  clock, a page that is not the file device's, the start's sweep, and the FAT
  cases, through hooks that give a host call EINVAL, ENOSPC or EIO and make a
  folder fold case.
- **The mutations.** `qfd_mutations.txt`, run by the package's own
  `mutate.py`, must print "N caught, 0 survived, 0 broken".

What neither holds: a real FAT folder, since the build host cannot mount one
without root, which the hooks stand in for; and the order of the writes on
silicon, which needs a QUUX bitstream that carries the page.
