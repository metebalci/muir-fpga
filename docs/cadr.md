<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The CADR

This file is the text of the site's
[page on the real machine](https://metebalci.github.io/muir-fpga/cadr.html),
which carries the ten drawings with a one-sentence caption each. What each
drawing shows is said here, in the order the page draws them, and the sources
the drawings were read from are listed at the end.

## The machine this project reproduces

The CADR is a 32-bit microcoded processor built at the MIT Artificial
Intelligence Laboratory around 1978, and published as AI Memo 528 in 1980. It
is the machine the Lisp Machine system was written for.

It is a general-purpose processor designed for convenient emulation of complex
order codes. On it the microcode interprets the 16-bit order code the Lisp
machine compiler produces. The drawings are read from MIT's own files, and the
table at the end says which file each one came from.

The processor is two boards of its own. Everything else in the machine plugs
into one of the two buses the bus interface arbitrates.

## The processor

The CADR board carries the data paths and the ICMEM board the control memory.
Every edge-triggered register on them takes one clock edge a microcycle.
Between the edges the clock is a level, and the board reads it as one: a read
phase and then a write phase.

The read phase is set by a tap of a delay line, so the machine has four speeds
and the instruction can ask for a long one.

## The microinstruction

A microinstruction is 48 bits and there are four classes of it. Every one names
two sources, called A and M, and two of the four also name a destination. Three
bits mean the same thing in every class: STAT, ILONG and POPJ.

A JUMP with both its R and P bits set is not a jump at all. It is how the
microcode writes the control store.

## The map

Memory is reached through two levels of paging that turn a 24-bit virtual
address into a 22-bit physical one. A page is 256 words, so the low eight bits
pass through untouched. There is no state in either level: a lookup is a ripple
through two memories inside one microcycle.

The refusal is what a page fault is, and a JUMP can test for it.
[`map.md`](map.md) is the long form.

## What is where

The physical address is 22 bits, so the Xbus can carry four million words. The
top four of its 64 slots are not memory: two are I/O space and two are the whole
of the Unibus. A cycle to an address nothing answers is given up on by a timer
on the bus interface.

A Unibus master reaches Xbus memory through the window at the foot of the
address space, because the Unibus address space is not big enough to name it.

## The disk

The disk controller is one board on the Xbus, and it is a bus master as well as
a slave: it moves blocks into main memory itself. Writing the command register
starts nothing. A transfer begins when something is written to START, after
the other registers have been set up.

A block is one Lisp machine page. The drive carries three words of its own
beside it: a header, a checkword over the header, and a checkword over the
data. [`disk-controller.md`](disk-controller.md) is the long form.

## The display

MIT's word for the display controller is the TV, and the board this project
reproduces first is the black-and-white SIMPLE TV. It has no color and no gray.
The picture is exactly what the software has written into the frame buffer. A
second board, MIT's color TV, can be fitted beside it.

The frame is the machine's only regular interrupt, and the microcode counts
time by it. [`tv.md`](tv.md) is the long form.

## The I/O board

The I/O board is the machine's half of a conversation with a person. It is a
Unibus board carrying the keyboard, the mouse, two clocks, the serial port and
the Chaosnet interface. It answers a block of 64 addresses, in eight groups of
eight.

The microsecond clock starts when the power comes on, and no Unibus reset stops
it. [`io-board.md`](io-board.md) is the long form.

## The light panel

A CADR has a small panel of lamps and one button, on a cable from the control
memory board. Twelve of the connector's wires are used and the rest are not.
Every internal memory in the machine is parity checked, and the panel is where
the checks show.

The button is one wire grounded by a push button, and it is one of five ways a
CADR can be told to boot.

## The debug cable

A CADR is debugged by another CADR. The debugger's DBGOUT connector goes to the
debuggee's DBGIN. Over the cable one machine's Unibus cycles run on the other
machine's bus. The console program that does it is called CC, and it is Lisp
software running on the debugging machine.

Once a cycle can run on the debuggee's Unibus, everything on that bus is
reachable, main memory included, through the debuggee's own Unibus map.
[`debug-cable.md`](debug-cable.md) is the long form.

## Where each drawing came from

Nothing in the drawings is a first-hand invention. Numbers written with a
leading `0o` are octal, which is how MIT writes an address.

| Figure | Read from |
|---|---|
| the machine, whole | `busint.erface`, muir's `data/cables.txt`, `xspec.text.3`, the three wire lists |
| the data paths | AI Memo 528, and the CLOCK1 delay-line taps as muir's `clock.rs` has them |
| the microinstruction | `cadr/ir.bits`, and muir's `isa.rs` for the bit ranges |
| the map | AI Memo 528, `docs/map.md`, the VMEM drawings |
| the address space | `sys/doc/unaddr.text`, muir's `busint.rs`, `cadr_xbus_decode.sv` |
| the disk | `sys/doc/disk.text`, and muir's `dm.rs` for the multiplexor |
| the display | `cadrtv/lmtv.order`, `docs/tv.md`, `shwarm.lisp` |
| the I/O board | `docs/io-board.md`, `sys/io1/ukbd.lisp`, the `cadrio` drawings |
| the light panel | `cadrwd/icmem3.wlr`, connector 1AJ2 pin by pin; AI Memo 528 |
| the debug cable | `docs/debug-cable.md`, `cadr/ir.bits`, the DBGOUT and DBGIN drawings |

## Sources

### MIT's own files

- `lmdoc/cadr.164` is AI Memo 528, *CADR*, in the printing of 15 May 1980. It
  is the machine in MIT's own words.
- `cadr/ir.bits` is the microinstruction's field diagram, the functional source
  and destination tables, and the sixteen diagnostic registers.
- `cadr/busint.erface` is the five cables, the two buses they carry, and what a
  wait and a hang are.
- `cadr1/xspec.text.3` is the Xbus specification: its cycles, its deskew
  delays, its arbitration, and the pinout of every kind of slot in the cage.
- `cadrwd/cadr4.wlr`, `cadrwd/icmem3.wlr` and `cadr1/busint.wlr` are the wire
  lists the two processor boards and the bus interface were wrapped from. The
  light panel's connector is read from the second of them.
- `cadrtv/lmtv.order` is the programming specification for the display board.
- `cadrio/`, `cadrdc/`, `cadrm/` and `chaos/lispm/` are the drawings of the I/O
  board, the disk controller, the memory board and the Chaosnet interface.
- `sys/ucadr/promh.text` is MIT's source for the boot PROM, with its comments.

### Files in the System 100 release

- `sys/doc/disk.text` is "Programming the Disk Controller": every register, the
  format of a block, and the two drive geometries.
- `sys/doc/unaddr.text` is MIT's own allocation of Unibus and Xbus addresses.
- `sys/io1/ukbd.lisp` is the keyboard's firmware, with the protocol at the end
  of it: the 24-bit word, the key table, and the boot combination.
- `sys/io1/time.lisp` and `sys/io1/serial.lisp` are the drivers for the two
  clocks and the serial port. They are where their Unibus addresses are written
  down.
- `sys/window/shwarm.lisp` is the window system's own use of the display, which
  is what fixes the shape of the screen.

### This project, and muir

- muir's `mit/README.md` is the inventory of MIT's recovered files: what each
  one is, and how it reached us.
- muir's `src/` and `data/cables.txt` are the simulator's module headers, which
  cite MIT's drawings by page and part reference for each behavior they model,
  and the 92 wires of the five cables pin by pin.
- `docs/` holds this repository's notes on the map, the display, the I/O board,
  the disk controller and the debug cable. Each was written by reading MIT's
  files and naming the line every claim came from.
- `rtl/machine/` is the fabric this project builds, whose module headers
  transcribe the drawings page by page.
