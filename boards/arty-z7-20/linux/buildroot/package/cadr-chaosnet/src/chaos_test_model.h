// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A MODEL of the fabric half of `chaos_face.h`, behind the same two function
// pointers the board fills with a mapping: no board, no /dev/mem, and the
// code the board runs is the code the check runs.  `feeder_test.c` and
// `console_test.c` do this one seam along, and for the same reason.
//
// **IT IS ITS OWN TRANSLATION UNIT BECAUSE TWO SUITES DRIVE IT.**
// `chaos_test_face.c` holds the driver of the register face to it, and
// `chaos_test_inject.c` holds the retry above that driver to it.  It was in
// the first of those until the second existed.
//
// **THE MODEL SHARES NO EXPRESSION AND NO CONSTANT WITH THE CODE IT CHECKS.**
// Every register number below is written out from `chaos_face.h`'s own
// documented table --- "+0x14  5  CTL", so 5 --- and not taken from
// `enum chaos_reg`; every status and control bit is written from the same
// table and not from `enum chaos_stat` or `enum chaos_ctl`; the identity word
// is spelled out rather than named.  This project has twice been caught by a
// check that moved with the bug it was meant to find --- a shadow memory keyed
// off the thing under test, and a stimulus that mirrored the DUT --- and a
// model that called `CHAOS_TX_WINDOW` would agree with a driver that had the
// window in the wrong place.  Written out, the two disagree loudly.
//
// **WHAT THE MODEL IS NOT.**  It is the seam's contract and not the RTL: the
// fabric half is `rtl/plumbing/cadr_chaos_cable.sv`'s and is held to
// `muir::chaos::interface` by a testbench of its own.  Where the contract is
// silent the model makes a choice and says so at the choice, and no check
// asserts one of those choices as though it were known --- what is asserted is
// that the program behaves correctly WHATEVER the fabric answers, which is a
// different and stronger thing.
//
// ## The machine's own clock, which is what the burst checks need
//
// The face checks drive the machine by hand: `chaos_model_drains` is the
// machine reading the incoming buffer out and writing Clear Receiver.  A
// burst check cannot, because what it is measuring is a RACE --- frames
// arriving against a machine that takes a while to empty its buffer --- so the
// model has a clock the check advances and a service time after which the
// machine empties the buffer by itself.
//
// **WHERE THE SERVICE TIME COMES FROM.**  Microcode 323's `CHAOS-INTR`
// (`ucadr/uc-chaos.lisp`) is 21 microinstructions of prologue, then a loop of
// 19 for every two 16-bit words of the packet, then 8 more to the write that
// clears the receiver --- counted from the control-store addresses of the band
// the board runs, `0o25762` for `CHAOS-INTR`, `0o26007` for
// `CHAOS-RCV-INTR-LOOP` and `0o26040` for the Clear Receiver write.  At 150 ns
// a microcycle, fifteen ticks of MIT's 10 ns grid, that is about 371 us for the
// longest packet and about 26 us for a short one.  `docs/chaosnet.md` has the derivation; the checks state the
// service time they use and run at more than one, so that no answer of theirs
// rests on the figure being exact.

#ifndef CHAOS_TEST_MODEL_H
#define CHAOS_TEST_MODEL_H

#include <stdint.h>

#include "chaos_face.h"

// --- the register table, transcribed from `chaos_face.h`'s own words ------
//
//    +0x00   0  IDENT    "CHAO", read-only
//    +0x04   1  STAT     read-only
//    +0x08   2  MYADDR   the sixteen address switches
//    +0x0C   3  TXLEN    read-only
//    +0x10   4  RXLEN    written
//    +0x14   5  CTL      written
//    +0x18   6  LOST     read-only, saturating
//    +0x1C   7  IRQ      a 1 written clears the bit
//    +0x20   8  IRQEN    the mask over IRQ
//    +0x400     TX window, word k at +0x400 + 4k, read-only
//    +0x800     RX window, word k at +0x800 + 4k, written
#define R_IDENT		0u
#define R_STAT		1u
#define R_MYADDR	2u
#define R_TXLEN		3u
#define R_RXLEN		4u
#define R_CTL		5u
#define R_LOST		6u
#define R_IRQ		7u
#define R_IRQEN		8u
#define W_TX		0x100u		/* 0x400 bytes / 4 */
#define W_RX		0x200u		/* 0x800 bytes / 4 */
#define W_WORDS		256u

// "CHAO", spelled out: C is 0x43, H 0x48, A 0x41, O 0x4F.
#define IDENT_CHAO	0x4348414Fu

// STAT, and CTL's three commands.
#define ST_TX_VALID	(1u << 0)
#define ST_RX_BUSY	(1u << 1)
#define ST_RX_ARMED	(1u << 2)
#define ST_LOOPED	(1u << 3)
#define DO_TX_TAKE	(1u << 0)
#define DO_RX_COMMIT	(1u << 1)
#define DO_RX_ABORT	(1u << 2)

// IRQ: bit 0 a frame is waiting to be taken, bit 1 the machine emptied the
// incoming buffer.
#define IRQ_TX		(1u << 0)
#define IRQ_RX_FREE	(1u << 1)

// The longest frame: the eight header words, 488 bytes of data as 244 words,
// and the three-word hardware trailer.  Written out rather than named, for
// the reason at the top of this file.
#define MODEL_MAX_WORDS	(8u + 244u + 3u)

// How many frames the machine is remembered to have taken out, by packet
// number and in the order it took them.  A burst check reads that list to say
// what reached the machine and in what order, rather than inferring it from
// what is left in the buffer at the end.
#define MODEL_SEEN	128u

struct face_model {
	uint32_t ident;			/* what word 0 answers; "CHAO" unless a check changes it */
	uint32_t myaddr;
	// The frame the machine transmitted, waiting for Linux to take it.
	uint16_t tx[W_WORDS];
	uint32_t txlen;
	int tx_valid;
	// The window Linux writes, and the buffer a commit stores it in.
	uint16_t rxwin[W_WORDS];
	uint32_t rxlen;
	uint16_t rx[W_WORDS];
	unsigned rx_words;
	int rx_busy, rx_armed, looped;
	uint32_t lost;
	uint32_t irq, irqen;
	// What the driver did, counted: a check reads these rather than
	// guessing from the state left behind.
	unsigned takes, commits, aborts, reads, writes;
	// **What the model refuses to do quietly.**  A write to a read-only
	// register, a write past a window, or a commit of a length no frame can
	// be: each is a fault in the driver, and a model that shrugged would
	// hide it.  Every check ends by holding this at zero.
	unsigned faults;
	// The machine's own clock, which only a burst check uses.  `now` is the
	// check's to advance; `service_ns` is how long the machine takes to
	// read a packet out of the buffer and write Clear Receiver, and 0 says
	// the machine does not empty it by itself at all.  `free_at` is when
	// the packet in the buffer will have been read out.
	uint64_t now, free_at, service_ns;
	// Every frame the machine took out, by packet number and in the order
	// it took them.  The burst checks read this rather than guessing from
	// what is left behind.
	unsigned delivered;
	uint16_t seen[MODEL_SEEN];
};

// A service time of 0 means the machine does NOT empty its buffer by itself:
// the face checks drive it with `chaos_model_drains` and want no clock at all.
// So 0 is "nobody is servicing this interface", which is also what a machine
// whose microcode has not started is.

void chaos_model_init(struct face_model *m);
void chaos_model_attach(struct chaos_face *f, struct face_model *m);

// The machine puts a frame in its outgoing buffer and reads START.
void chaos_model_transmits(struct face_model *m, const uint16_t *words, unsigned n);

// The machine reads the incoming buffer out and writes Clear Receiver.
void chaos_model_drains(struct face_model *m);

// A frame to send through the seam: a packet from 3040 to 3050 carrying
// `number`, which is what a burst check tells its frames apart by.  Every data
// byte differs from its neighbors and from its own index's low bits, so a
// swap, a shift or a lost byte shows.
unsigned chaos_model_frame(uint16_t *out, unsigned data_len, unsigned number);

// The same frame addressed to everybody: the cable destination is zero, which
// is MIT's own "the cable address of the destination of the packet, or 0 to
// broadcast it".
//
// **ONLY THAT ONE WORD DIFFERS** from `chaos_model_frame`'s --- the software
// header, the data and the length are the same, and the check word follows
// the destination as it must.  A check where a broadcast is treated
// differently from a frame by name is then a check about the cable
// destination and about nothing else, and code that decided from the software
// header instead would fail it.
unsigned chaos_model_broadcast(uint16_t *out, unsigned data_len, unsigned number);

#endif
