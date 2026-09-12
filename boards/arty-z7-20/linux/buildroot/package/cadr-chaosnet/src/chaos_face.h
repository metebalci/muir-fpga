// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet interface's register face, as Linux drives it over a general
// purpose AXI port, and the frame-level vocabulary built on it.
//
// **THIS FILE IS THE ONE PLACE THE TWO HALVES MEET, AND IT IS WRITTEN THAT
// WAY ON PURPOSE.**  The fabric half --- the Chaosnet interface's own
// registers at `0o764140`-`0o764156` inside `rtl/machine/cadr_io_board.sv`
// --- is another slice's and is held to `muir::chaos::interface`.  What is
// here is the OTHER side of the same buffers: the cable.  Nothing else in
// this program knows a register number, so if the fabric names a different
// base, a different layout or a different handshake, this header and
// `chaos_face.c` change and nothing above them does.
//
// ## What the seam IS, which is the thing to agree on first
//
// muir puts the CADR's interface on a modelled `ether` and hangs the
// Chaosnet server, the CHUDP link and every other station off that ether as
// `ether::Node`s.  On this board the interface is in fabric and the ether is
// this program.  So the seam is a **mailbox for whole frames**, not a copy of
// the interface's registers:
//
//   - the machine writes a packet into its outgoing buffer and reads `START`
//     (`0o764152`) to transmit it.  The fabric then holds ONE frame for
//     Linux, and `STAT`'s `TX_VALID` says so.  Linux takes it and says it has
//     (`CTL_TX_TAKE`), which is the moment the interface may set Transmit
//     Done and take another packet.
//   - Linux hands a frame down (`RX` words, then `CTL_RX_COMMIT`) and the
//     fabric stores it in the incoming buffer, sets the bit count and raises
//     Receive Done.  If the machine has not yet read the previous packet out,
//     the fabric refuses and counts it in `LOST`, which is exactly what the
//     interface's four-bit Lost Count means (AIM-628 §7).
//
// ## What a FRAME is here: the words, in the order the buffer holds them
//
// AIM-628 §7 and `muir::chaos::packet`.  The software writes the eight header
// words, then the data words, then the cable destination; "the hardware
// appends the source address and the check word itself".  A receiver reads
// the same words back and then "the destination address, the source address,
// and the checksum".  So one frame, at both ends of this seam, is:
//
//     [0]      operation        (opcode in bits 15:8)
//     [1]      count            (forwarding count 15:12, byte count 11:0)
//     [2]      destination address
//     [3]      destination index
//     [4]      source address
//     [5]      source index
//     [6]      packet number
//     [7]      acknowledgement
//     [8..]    the data, two bytes a word, LOW byte first (§3.6)
//     [n-3]    the cable destination, or 0 for a broadcast
//     [n-2]    the cable source, which the transmitting hardware inserted
//     [n-1]    the check word
//
// **The last three words are the hardware trailer and they are ON this
// seam.**  Including them costs three words and buys two things: the check
// word can be verified by whoever reads a frame rather than trusted, and the
// frame is byte for byte what CHUDP puts in a datagram (`chaos_udp.c`), so a
// packet crossing between the machine and a peer is copied and not rebuilt.
// `muir::chaos::packet::frame` builds exactly this sequence before it plays
// it out backwards on the wire, and `unframe` takes exactly this back.
//
// **ASSUMED, AND THE FABRIC HALF CONFIRMS OR CORRECTS IT:** that the fabric
// appends the source and the check word on transmit, as the board's Fairchild
// 9401 at LMTBUF C09 does, and takes them as given on receive.  If instead
// the fabric hands over only what the software wrote and expects only that
// back, `CHAOS_FACE_TRAILER` below goes to 0 and `chaos_face.c` computes the
// two words with `chaos_check_word()`, which is ported here anyway.  That is
// a three-line change and no caller sees it.
//
// ## The registers
//
// Sixteen words at `CHAOS_REG_BASE`, and two windows of 256 words each.  A
// window rather than an auto-incrementing port because a window has no
// ordering hazard: a read that the interconnect repeats, or a program that
// reads word 5 twice, cannot lose a word.
//
//    +0x00   0  IDENT   "CHAO", read-only
//    +0x04   1  STAT    read-only, the bits of `enum chaos_stat`
//    +0x08   2  MYADDR  the sixteen address switches: what the machine reads
//                       at `MY_ADDRESS` (`0o764142`) and the source word the
//                       transmitter inserts.  Written by Linux, because on
//                       this board there is no DIP switch to set
//    +0x0C   3  TXLEN   read-only: 16-bit words in the waiting frame, or 0
//    +0x10   4  RXLEN   written: how many words the frame about to be
//                       committed has.  Read back so a driver can check it
//    +0x14   5  CTL     written: `enum chaos_ctl`.  Read-only bits are the
//                       reset count, so a write of 0 is a harmless probe
//    +0x18   6  LOST    read-only: frames refused because the machine had not
//                       emptied the incoming buffer.  Saturating, not
//                       wrapping, so a reader cannot mistake a wrap for calm
//    +0x1C   7  IRQ     bit 0 a frame is waiting to be taken, bit 1 the
//                       machine emptied the incoming buffer.  A 1 written
//                       clears the bit
//    +0x20   8  IRQEN   the mask over IRQ; `IRQ_F2P` is the OR under it
//    +0x400     TX window: word k of the waiting frame at +0x400 + 4k,
//                       read-only, bits 15:0, bits 31:16 zero
//    +0x800     RX window: word k of the frame being built at +0x800 + 4k,
//                       written, bits 15:0
//
// **EVERY ADDRESS IN WHATEVER WINDOW THE FABRIC GIVES THIS MUST BE
// ANSWERED.**  A read on a GP port that nothing answers hangs both Arm cores
// at one PC each --- measured on this board, and `cadr_gp0_default.sv` and
// `<cadr/cadr_mem.h>` say it at length.  So this program runs `cadr_guard()`
// before it maps anything, and reads `IDENT` before it believes any other
// word.
//
// ## Where it is
//
// **ASSUMED**: the low end of `M_AXI_GP0`'s window one 4 KB page above the
// pack side, which owns `0x40000000` today.  `site/index.html` already says
// GP0 is the port "over which the PS reaches the disk controller and the
// Chaosnet buffers", so the port is the drawing's and only the offset is
// this file's guess.  Putting a second slave on GP0 needs a decode in front
// of `cadr_disk_pack.sv`, which is the fabric half's work and is named in
// the report.  If the interface lands on `M_AXI_GP1` beside the console
// instead, this one constant changes.

#ifndef CHAOS_FACE_H
#define CHAOS_FACE_H

#include <stddef.h>
#include <stdint.h>

#define CHAOS_REG_BASE    0x40001000u
#define CHAOS_REG_BYTES   0x1000u
#define CHAOS_IDENT_WORD  0x4348414Fu	/* "CHAO" */

// The windows, as word offsets into the mapping's 32-bit words.
#define CHAOS_TX_WINDOW   0x100u	/* +0x400 */
#define CHAOS_RX_WINDOW   0x200u	/* +0x800 */

// The most words a frame can be: the eight header words, the data rounded up
// to whole words, and the three-word hardware trailer.  AIM-628 §3.5 puts the
// data at "a maximum value of 488" bytes, which is 244 words.
#define CHAOS_MAX_DATA    488u
#define CHAOS_MAX_WORDS   (8u + (CHAOS_MAX_DATA / 2u) + 3u)	/* 255 */

// Whether a frame on this seam carries the hardware trailer.  See the note
// above: 1 means the fabric appends the source and check word on transmit and
// takes them on receive, which is what the board's own hardware does.
#define CHAOS_FACE_TRAILER 1

enum chaos_reg {
	CHAOS_IDENT = 0, CHAOS_STAT = 1, CHAOS_MYADDR = 2, CHAOS_TXLEN = 3,
	CHAOS_RXLEN = 4, CHAOS_CTL = 5, CHAOS_LOST = 6, CHAOS_IRQ = 7,
	CHAOS_IRQEN = 8
};

enum chaos_stat {
	// A frame the machine transmitted is waiting to be taken.
	CHAOS_ST_TX_VALID = 1u << 0,
	// The incoming buffer still holds a packet the machine has not read
	// out: Receive Done is set.  A frame given now is refused and counted
	// in LOST.
	CHAOS_ST_RX_BUSY  = 1u << 1,
	// The machine has the receiver enabled at all: Clear Receiver has been
	// written since the last packet.  Down, and the machine is not
	// listening --- which it is not before its microcode has started.
	CHAOS_ST_RX_ARMED = 1u << 2,
	// The interface is in Loop Back (`csr::LOOP_BACK`): the fabric is
	// carrying the machine's packets back to itself and Linux must not
	// inject any.  A maintenance mode, and honoured rather than ignored.
	CHAOS_ST_LOOPED   = 1u << 3
};

enum chaos_ctl {
	// The frame `TXLEN` counted has been taken: drop it, and let the
	// machine's Transmit Done come up.
	CHAOS_CTL_TX_TAKE   = 1u << 0,
	// The `RXLEN` words in the RX window are a whole frame: store it and
	// raise Receive Done.  Refused, and `LOST` counts it.
	CHAOS_CTL_RX_COMMIT = 1u << 1,
	// Throw away what has been written into the RX window without storing
	// it: a frame that turned out to be for somebody else.
	CHAOS_CTL_RX_ABORT  = 1u << 2
};

enum chaos_irq {
	CHAOS_IRQ_TX = 1u << 0,		// a frame is waiting to be taken
	CHAOS_IRQ_RX_FREE = 1u << 1	// the machine emptied the incoming buffer
};

// The face, reached through two function pointers so that the host test can
// put a model of the RTL behind them and the board puts /dev/mem.  That seam
// is `pack_side.h`'s and `console_face.h`'s, copied deliberately: same shape,
// same reason, and a fourth program should copy it too rather than invent a
// fourth.
struct chaos_face {
	uint32_t (*read)(struct chaos_face *f, unsigned word);
	void (*write)(struct chaos_face *f, unsigned word, uint32_t v);
	void *ctx;
};

// A /dev/mem-backed face at `CHAOS_REG_BASE`.  `fd` is `cadr_open_mem()`'s,
// and `cadr_guard()` must have passed first.  0, or -1 having said why.
int chaos_face_open(struct chaos_face *f, int fd, uint32_t base);
void chaos_face_close(struct chaos_face *f);

// IDENT, read and checked.  0 if it is `CHAOS_IDENT_WORD`, -1 having said
// what was there instead --- `CADR_IDENT_NONE` for a bitstream with a default
// slave where this should be, which is the common mistake and is named as
// such.
int chaos_face_ident(struct chaos_face *f);

// The sixteen address switches.
uint16_t chaos_face_address(struct chaos_face *f);
void chaos_face_set_address(struct chaos_face *f, uint16_t address);

// The frame the machine transmitted, if one is waiting: its words into
// `words`, and the count returned.  0 if none is waiting.  -1 if the fabric
// reports a length this program cannot hold, which is a fault in one half or
// the other and is said rather than truncated.
//
// Taking a frame includes telling the fabric it was taken, so a caller that
// drops the frame on the floor has still let the machine transmit again ---
// which is right: the cable carried it and nobody wanted it.
int chaos_face_take(struct chaos_face *f, uint16_t *words, unsigned max);

// A frame onto the machine's incoming buffer.  1 if it was stored, 0 if the
// machine had not emptied the buffer and the fabric refused it (the caller
// may try again, and `LOST` has counted it), -1 for a frame this seam cannot
// carry.
int chaos_face_give(struct chaos_face *f, const uint16_t *words, unsigned n);

// `STAT` and `LOST`, for the status line and for the tests.
uint32_t chaos_face_stat(struct chaos_face *f);
uint32_t chaos_face_lost(struct chaos_face *f);

#endif
