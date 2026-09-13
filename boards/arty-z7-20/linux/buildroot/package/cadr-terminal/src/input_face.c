// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The driver of the keyboard's and the mouse's register face; `input_face.h`
// says what the face is, where every number in it comes from, and what it
// assumed about the fabric.
//
// **THIS IS THE ONLY FILE IN THE PROGRAM THAT KNOWS A REGISTER NUMBER.**
// Everything above it --- `input_keys.c`, the RFB server --- speaks in
// twenty-four-bit words, in counts and in a button mask.  That is the seam
// `serial_face.c`, `chaos_face.c` and `pack_side.c` use, and it is what lets
// `screen_test.c` put a model of the fabric behind two function pointers and
// run the whole thing on a build host with no board.

#include "input_face.h"

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include <stdlib.h>
#include <sys/mman.h>

// ---- the face over /dev/mem ---------------------------------------------

struct in_mmio {
	volatile uint32_t *regs;
	size_t bytes;
};

static uint32_t mmio_read(struct input_face *f, unsigned word)
{
	const struct in_mmio *m = f->ctx;
	return m->regs[word];
}

static void mmio_write(struct input_face *f, unsigned word, uint32_t v)
{
	const struct in_mmio *m = f->ctx;
	m->regs[word] = v;
	// The mapping is uncached (`cadr_open_mem` opens /dev/mem with
	// O_SYNC), so this is a barrier against the compiler and the core's
	// own store buffer and not against a cache: a write of KEY followed
	// by a read of STAT must reach the fabric in that order.
	__sync_synchronize();
}

int input_face_open(struct input_face *f, int fd, uint32_t base)
{
	f->read = NULL;
	f->write = NULL;
	f->ctx = NULL;
	struct in_mmio *m = calloc(1, sizeof *m);
	if (!m) {
		say("out of memory mapping the keyboard and mouse registers");
		return -1;
	}
	m->bytes = IN_REG_BYTES;
	m->regs = cadr_map(fd, base, m->bytes, "the keyboard and mouse registers");
	if (!m->regs) {
		free(m);
		return -1;
	}
	f->read = mmio_read;
	f->write = mmio_write;
	f->ctx = m;
	return 0;
}

void input_face_close(struct input_face *f)
{
	// Only a face `input_face_open` opened owns a mapping.  The host check
	// puts its own model behind the same two pointers, and a `ctx` that is
	// not a `struct in_mmio` must not be freed as one --- so the test is
	// the function pointer and not the pointer being non-NULL.
	if (f->read != mmio_read)
		return;
	struct in_mmio *m = f->ctx;
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

int input_face_ident(struct input_face *f)
{
	const uint32_t got = f->read(f, IN_IDENT);
	if (got == IN_IDENT_WORD) {
		say("the keyboard and mouse answer at word 0 with \"INPT\"; STAT 0x%08x",
		    f->read(f, IN_STAT));
		return 0;
	}
	if (got == CADR_IDENT_NONE)
		say("no keyboard and mouse here: word 0 reads \"NONE\", which is "
		    "rtl/plumbing/cadr_gp0_default.sv's default slave --- a board with a GP port "
		    "and nothing of ours behind it");
	else
		say("no keyboard and mouse here: word 0 reads 0x%08x, wanting 0x%08x (\"INPT\"); "
		    "is the fabric a bitstream with the I/O board's input cables in it?",
		    got, IN_IDENT_WORD);
	return -1;
}

void input_face_flush(struct input_face *f)
{
	f->write(f, IN_CTL, IN_CTL_FLUSH);
}

uint32_t input_face_stat(struct input_face *f)
{
	return f->read(f, IN_STAT);
}

uint32_t input_face_lost(struct input_face *f)
{
	return f->read(f, IN_LOST);
}

int input_face_key_idle(struct input_face *f)
{
	// One read of STAT answers both halves of it: `IN_ST_KBD_READY` is
	// the card's own flop, and `IN_ST_QUEUED` is what the fabric still
	// holds for it.  Both must be empty --- a word in the queue has not
	// reached the card yet, so a seam that asked only about the card
	// would hand over a second word while the first was still on its way.
	const uint32_t st = f->read(f, IN_STAT);
	return !(st & IN_ST_KBD_READY) && IN_ST_QUEUED(st) == 0u;
}

int input_face_key(struct input_face *f, uint32_t word)
{
	// **ROOM FIRST, ALWAYS.**  `input_face.h`: a word written to a full
	// queue is "Dropped and counted in LOST".  So the room is asked for
	// before the word is written, and a refusal is reported rather than
	// swallowed --- the caller keeps the word and offers it again, which is
	// what `muir::terminal::keyboard::press` does at its own backlog.
	if (!(f->read(f, IN_STAT) & IN_ST_ROOM))
		return 0;
	f->write(f, IN_KEY, word & 0xFFFFFFu);
	return 1;
}

// The register's two fields are twelve bits of two's complement each, and
// the fabric saturates what it OWES rather than what it is handed --- so a
// delta wider than the field has to be held here, or it wraps on the way in
// and the mouse goes the other way.  A whole screen is 963 pixels, well
// inside, so this only ever bites on a pointer that jumped.
static uint32_t clamp12(int v)
{
	if (v > 2047)
		v = 2047;
	if (v < -2048)
		v = -2048;
	return (uint32_t)v & 0xFFFu;
}

void input_face_move(struct input_face *f, int dx, int dy)
{
	if (dx == 0 && dy == 0)
		return;
	f->write(f, IN_MOUSE, clamp12(dx) | (clamp12(dy) << 12));
}

void input_face_buttons(struct input_face *f, uint32_t mask)
{
	// Masked to the three switches the cable has.  A viewer may send a
	// mask with wheel buttons in it --- RFB puts them at bits 3 and 4 ---
	// and the CADR's mouse has three, so the rest go nowhere.  Written
	// every time and not only on a change: it is a LEVEL, the card's own
	// comparator decides whether anything happened, and a face that
	// remembered would be a second copy of a register the fabric already
	// reads back.
	f->write(f, IN_BUTTONS, mask & 0x7u);
}
