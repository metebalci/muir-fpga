// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The driver of the serial port's register face; `serial_face.h` says what
// the face is, where every number in it comes from, and what it assumed about
// the fabric.
//
// **THIS IS THE ONLY FILE IN THE PROGRAM THAT KNOWS A REGISTER NUMBER.**
// Everything above it --- the endpoint, the loop --- speaks in characters and
// in modem-control lines.  That is the same seam `pack_side.c` and
// `console_face.c` use, and it is what lets `serial_test.c` put a model of
// the fabric's far side behind two function pointers and run the whole
// program on a build host with no board.

#include "serial_face.h"

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include <stdlib.h>
#include <sys/mman.h>

// ---- the face over /dev/mem ---------------------------------------------

struct ser_mmio {
	volatile uint32_t *regs;
	size_t bytes;
};

static uint32_t mmio_read(struct serial_face *f, unsigned word)
{
	const struct ser_mmio *m = f->ctx;
	return m->regs[word];
}

static void mmio_write(struct serial_face *f, unsigned word, uint32_t v)
{
	const struct ser_mmio *m = f->ctx;
	m->regs[word] = v;
	// The mapping is uncached (`cadr_open_mem` opens /dev/mem with
	// O_SYNC), so this is a barrier against the compiler and the core's
	// own store buffer and not against a cache: a write of WDATA followed
	// by a read of STAT must reach the fabric in that order.
	__sync_synchronize();
}

int serial_face_open(struct serial_face *f, int fd, uint32_t base)
{
	f->read = NULL;
	f->write = NULL;
	f->ctx = NULL;
	struct ser_mmio *m = calloc(1, sizeof *m);
	if (!m) {
		say("out of memory mapping the serial port's registers");
		return -1;
	}
	m->bytes = SER_REG_BYTES;
	m->regs = cadr_map(fd, base, m->bytes, "the serial port's registers");
	if (!m->regs) {
		free(m);
		return -1;
	}
	f->read = mmio_read;
	f->write = mmio_write;
	f->ctx = m;
	return 0;
}

void serial_face_close(struct serial_face *f)
{
	// Only a face `serial_face_open` opened owns a mapping.  The host
	// check puts its own model behind the same two pointers, and a `ctx`
	// that is not a `struct ser_mmio` must not be freed as one --- so the
	// test is the function pointer and not the pointer being non-NULL.
	if (f->read != mmio_read)
		return;
	struct ser_mmio *m = f->ctx;
	if (m) {
		if (m->regs)
			munmap((void *)m->regs, m->bytes);
		free(m);
	}
	f->read = NULL;
	f->write = NULL;
	f->ctx = NULL;
}

// ---- what is on the face ------------------------------------------------

int serial_face_ident(struct serial_face *f)
{
	const uint32_t got = f->read(f, SER_IDENT);
	if (got == SER_IDENT_WORD) {
		say("the serial port answers at word 0 with \"SERI\"; STAT 0x%08x", f->read(f, SER_STAT));
		return 0;
	}
	if (got == CADR_IDENT_NONE)
		say("no serial port here: word 0 reads \"NONE\", which is "
		    "rtl/plumbing/cadr_gp0_default.sv's default slave --- a board with a GP port and "
		    "nothing of ours behind it");
	else
		say("no serial port here: word 0 reads 0x%08x, wanting 0x%08x (\"SERI\"); is the "
		    "fabric a bitstream with the I/O board in it?", got, SER_IDENT_WORD);
	return -1;
}

int serial_face_get(struct serial_face *f)
{
	// **STAT FIRST, ALWAYS.**  `serial_face.h`: reading RDATA CONSUMES the
	// character, "which is the one place in this face where a read has an
	// effect, and is why STAT's RX_VALID is read first and RDATA only
	// then".  RDATA's own valid bit would answer the same question, and
	// asking it would cost a character every time the answer was no.
	if (!(f->read(f, SER_STAT) & SER_ST_RX_VALID))
		return -1;
	const uint32_t w = f->read(f, SER_RDATA);
	// Belt and braces, and not redundant: between the two reads the
	// machine's transmitter has not put a character in, but a fabric that
	// answered RX_VALID and then handed over nothing would otherwise have
	// this program deliver a zero byte nobody sent.
	if (!(w & SER_RDATA_VALID))
		return -1;
	return (int)(w & 0xFFu);
}

int serial_face_put(struct serial_face *f, uint8_t c)
{
	// `serial_face.h`: WDATA is "Refused, and lost, unless TX_ROOM is up".
	// So the room is asked for before the character is written, and a
	// refusal is reported rather than swallowed --- the caller offers the
	// same character again next pass and nothing is lost.
	if (!(f->read(f, SER_STAT) & SER_ST_TX_ROOM))
		return 0;
	f->write(f, SER_WDATA, c);
	return 1;
}

void serial_face_set_lines(struct serial_face *f, uint32_t lines)
{
	// Masked to the three this end asserts: DSR, DCD and CTS.  Nothing
	// else in the register is ours to write, and a caller that has ORed a
	// stray bit in must not put it on the cable.
	f->write(f, SER_CTL, lines & SER_CTL_PLUGGED);
}

uint32_t serial_face_stat(struct serial_face *f)
{
	return f->read(f, SER_STAT);
}

uint32_t serial_face_dropped(struct serial_face *f)
{
	return f->read(f, SER_DROPPED);
}

unsigned serial_face_rate(struct serial_face *f)
{
	// MODE carries MR1 in bits 7:0 and MR2 in bits 15:8, and the rate is
	// MR2's `MR23`..`MR20` --- muir `src/serial.rs`, `mode2::RATE_MASK`,
	// which is the Signetics sheet's Table 6.
	return (f->read(f, SER_MODE) >> 8) & 0xFu;
}

uint32_t serial_rate_tenths(unsigned rate)
{
	// muir `src/serial.rs`, `BAUD_TENTHS`: the sixteen rates mode register
	// 2 selects, in tenths of a baud so that 134.5 is a number.  The
	// Signetics sheet's Table 6, and the same list in MIT's
	// `sys/io1/serial.lisp` `:BAUD`.  Nothing in this program acts on it;
	// it is printed, because the rate the machine chose is worth knowing
	// when a far end is producing garbage.
	static const uint32_t tenths[16] = {
		500, 750, 1100, 1345, 1500, 3000, 6000, 12000,
		18000, 20000, 24000, 36000, 48000, 72000, 96000, 192000
	};
	return tenths[rate & 0xFu];
}
