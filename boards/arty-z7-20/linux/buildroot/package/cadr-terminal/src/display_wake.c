// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `display_wake.h` says what the word is and why it is written when it is.

#include "display_wake.h"

#include <stdio.h>
#include <sys/mman.h>

#include <cadr/cadr_mem.h>

struct dwake_ctx {
	volatile uint32_t *regs;
};

static struct dwake_ctx dwake_ctx;

static uint32_t dwake_read(struct display_wake *w, unsigned word)
{
	const struct dwake_ctx *c = w->ctx;
	return c->regs[word];
}

static void dwake_write(struct display_wake *w, unsigned word, uint32_t v)
{
	const struct dwake_ctx *c = w->ctx;
	c->regs[word] = v;
}

int display_wake_open(struct display_wake *w, int fd, uint32_t base)
{
	volatile uint32_t *regs = cadr_map(fd, base, DWAKE_REG_BYTES, "the console's face");
	if (!regs)
		return -1;
	dwake_ctx.regs = regs;
	w->read = dwake_read;
	w->write = dwake_write;
	w->ctx = &dwake_ctx;
	w->last_ns = 0;
	w->ever = 0;
	w->written = 0;
	w->coalesced = 0;
	return 0;
}

void display_wake_close(struct display_wake *w)
{
	// Only a face `display_wake_open` opened owns a mapping; the check puts
	// its own model behind the same pointers.  `color_map_close`'s rule.
	if (w->read == dwake_read && dwake_ctx.regs) {
		munmap((void *)dwake_ctx.regs, DWAKE_REG_BYTES);
		dwake_ctx.regs = NULL;
	}
	w->read = NULL;
	w->write = NULL;
	w->ctx = NULL;
}

int display_wake_ready(struct display_wake *w, uint32_t *ident, uint32_t *word)
{
	const uint32_t id = w->read(w, DWAKE_IDENT);
	if (ident)
		*ident = id;
	if (word)
		*word = 0;
	if (id != DWAKE_IDENT_WORD)
		return -1;
	// **THE MARKER AND NOT THE SETTING SAYS WHETHER THE WORD IS THERE.**  A
	// setting of zero and a display asleep are both display outputs to wake;
	// a board without one reads `UNMAPPED`, whose top half is not the marker.
	const uint32_t v = w->read(w, DWAKE_WORD);
	if (word)
		*word = v;
	return DWAKE_MARK_OF(v) == DWAKE_MARK ? 1 : 0;
}

int display_wake_poke(struct display_wake *w, uint64_t now_ns)
{
	// The first always goes, whatever the clock reads: a monotonic clock is
	// allowed to be small, and a board that has just booted is where it is.
	if (w->ever && now_ns - w->last_ns < DWAKE_EVERY_NS) {
		++w->coalesced;
		return 0;
	}
	w->write(w, DWAKE_WORD, DWAKE_KEY);
	w->last_ns = now_ns;
	w->ever = 1;
	++w->written;
	return 1;
}
