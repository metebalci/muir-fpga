<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The Chaosnet, and the serial line beside it

Both are on the CADR's I/O board, and both are split between fabric and Linux.
This document covers the whole of each, because the two halves were built by
separate slices and neither is a thing on its own.

The fabric half is in `rtl/machine/cadr_io_board.sv`, held to muir's `ioboard`
model over a scripted trace. The Linux half is two Buildroot packages,
`cadr-chaosnet` and `cadr-serial`, ported from muir's `src/chaos/` and
`src/serial.rs`.

## Where the line between them falls

**Fabric holds anything with a clock edge the CADR can see. Linux holds
anything with a protocol, a file, or a name in it.** That is this project's
rule and it decides everything here.

So the fabric has the registers the machine reads and writes: the Chaosnet
interface's five registers from AIM-628 section 7, its two packet buffers of
256 words each, its bit counter and its lost count, and the serial port's four
2651 registers with their mode pointer and status byte. Nothing above that is
in fabric.

Linux has the rest: the cable, the frame, the check word, routing, the TIME
and FILE services, the turn timer, the baud-rate generator and the line. What
crosses the boundary is a buffer and a status register, and nothing more.

## What the machine sees

`0o764140` to `0o764156` is the Chaosnet interface and `0o764160` to
`0o764176` is the serial port. Both are answered in full. The card's own check
prints `NOTHING IS EXEMPT`, and it answers 55 directions where it answered 28
before these two landed.

The Chaosnet's decode is subtle and the subtlety is MIT's. The 74LS138 at
LMUCON 0C18 decodes two address bits **and read against write**, so one
address is a different register depending on direction. Address bit 3 is
decoded only twice: it makes a read of `0o764152` the address START rather
than MY ADDRESS, and it disables the receive buffer's read at `0o764154`,
which is then unanswered. Writes reach the CSR and the transmit buffer at
`0o764150` and `0o764152` exactly as at `0o764140` and `0o764142`.

The serial port is simpler. Address bit 3 is not decoded at all, so
`0o764170` to `0o764176` are aliases of `0o764160` to `0o764166`, and every
address of the group is answered in both directions.

The interrupt vectors are `0o274` for the clock, `0o270` for the Chaosnet,
`0o264` for the serial port and the keyboard and mouse last. MIT's priority is
clock over Chaosnet over serial over keyboard. `0o270` is compared against
muir for the first time now, because the trace plugs a Chaosnet interface in
and uses Loop Back as the far end, which no trace against this model could do
before.

## What Linux sees

Two register faces, each behind one header so that a change of address touches
one file. `chaos_face.h` and `serial_face.h` are those headers.

The Chaosnet face is sixteen words with two windows of 256 words each, one for
each packet buffer. Its identity word is `CHAO`. The serial face is eight
words. Both are on `M_AXI_GP0`, which is where the drawing has always put the
Chaosnet buffers.

**A read on a general-purpose port that nothing in the fabric answers does not
fault the Arm cores. It freezes them, and no software guard can catch it.**
That was measured on this board. So whatever owns that port must answer every
address in its window, and adding these two faces to a port the disk pack
program already answers end to end needs a decode in front of it.

What each program must do at the face is written in the two headers. The
shapes are worth knowing here: the Chaosnet program takes a frame off the
transmit window a word at a time after the machine starts a transmission, and
streams a received frame in and then reports its length in bits and whether
the check word was good. The serial program holds the modem-control lines
while a client is connected, reads the character frame and the rate out of the
mode registers, and **paces the transmitter at the rate those registers
name**. Without that pacing the transmitter never empties.

## What is not built, and why each

**The mapped Unibus window.** The map's registers exist; the window they
translate through does not. So a Chaosnet or serial cycle reaches the card,
and a debug cycle cannot reach main memory.

**The SYN and DLE registers and their pointer**, the parity and framing flags,
and the Chaosnet's timer interrupt. Each is unfalsifiable at this seam, and
the module's header says so at each one.

**Auto echo and remote loop back's echo.** muir puts the echoed character back
at the end of the received frame, which is a second instant this seam does not
carry. The transmitter's refusal to run in both modes is built and held.

**Reassembly of a control command split across two packets.** muir does not do
it either. If a band ever sends one longer than 488 bytes, both are wrong
together.

**CHUDP's two byte-order constants are unverified**, here as in muir. One
capture or one interoperation would settle them, and the pinned datagram in
the check is the single place a correction lands.

## `ED-FILE` is a hole in the band's host table, not a missing server

The board's screen, with Lisp booted, shows this:

    >>ERROR: #<ZWEI::ZWEI-FILE-HOST "ED-FILE"> is not a known host.

**No Chaosnet server can answer it.** The failure is in `SI:PARSE-HOST`,
before a single packet is sent. The band's whole host table is two lines:

    HOST MIT-LISPM-1,	CHAOS 3050,USER,LISPM,LISPM,[CADR-1,CADR1,LM1]
    HOST MIT-OZ,		CHAOS 3060,SERVER,UNIX,VAX,[OZ]

`ED-FILE` is in neither. It is a name ZWEI's site configuration still refers
to and the restorers' trimmed table no longer contains, so making it resolve
is a change on the pack.

What the Chaosnet program does buy is better than silencing that line. As
`MIT-OZ` at 3060 it is what the band resolves `SYS:` to, so the TIME lookup is
answered and the machine has a date instead of stopping to ask for one,
`(hostat)` sees the server, and anything loading through the system host
reaches the FILE service. That last is how CC is loaded in muir's own tests,
which is what the debug cable needs.

## What the checks hold to

`iob` compares the card against muir's model over a scripted trace at the
Unibus: 82,305,913 ticks, 1,874 bus cycles, 55 directions answered and 524,233
silent over all 524,288 directions of an eighteen-bit address, read and
written, a real bus cycle each. 52 mutation records, all caught.

`unibus` holds the composed claim, that the machine's own bus cycle reaches
the card and that the three slaves' address sets are disjoint over the whole
address space in both directions, read out of muir's two traces rather than
transcribed.

`chaosnet` and `serial` hold the two programs on the build host with no board:
772 checks and 61 mutation records for the first, 115 and 19 for the second.
**The check word is held to silicon rather than to itself.** muir pins
`0o135771` as the word the netlist board produced for twelve given words, so a
wrong polynomial or bit order disagrees with a measurement off hardware and
not with a round trip that agrees with itself.

## One measurement worth not re-deriving

The serial port answers off MIT's five-nanosecond grid, on every cycle of its
group. Two constants put muir's answer at 953 nanoseconds plus a multiple of
500,000, and the fabric counts the same edges at 955, which is the first grid
point at or after it.

**That is exact rather than close, and the reason is that nothing can happen
in between.** The next multiple of five at or after 203 is 205, so no grid
point lies strictly between the two, and "strictly after the strobe" therefore
selects the same edge whether it is measured on the grid or on the netlist.
The trace carries the two-nanosecond slip on all 80 cycles rather than hiding
it.
