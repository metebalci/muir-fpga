// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The driver of the pack side's register face; `pack_side.h` says what the
// face is.

#include "pack_side.h"

#include <stdio.h>

void ps_init(struct pack_side *ps)
{
	ps->read = NULL;
	ps->write = NULL;
	ps->pause = NULL;
	ps->ctx = NULL;
	// A move is nine bursts, some 650 ticks at 5 ns; a register read over
	// GP0 is longer than that.  The cap is for a face that never answers.
	ps->poll_cap = 100000;
	ps->fetches = ps->writebacks = ps->takes = ps->denials = 0;
	ps->refused_walk = ps->refused_other = ps->errors = ps->polls = ps->stuck = 0;
}

uint32_t ps_tag(unsigned unit, uint32_t c, uint32_t h, uint32_t b)
{
	return (uint32_t)(unit & 7u) << 28 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
}

void ps_tag_split(uint32_t tag, unsigned *unit, uint32_t *c, uint32_t *h, uint32_t *b)
{
	*unit = (tag >> 28) & 7u;
	*c = (tag >> 16) & 0xFFFu;
	*h = (tag >> 8) & 0xFFu;
	*b = tag & 0xFFu;
}

int ps_ident_ok(struct pack_side *ps, uint32_t *got)
{
	*got = ps->read(ps, PS_IDENT);
	return *got == PS_IDENT_WORD;
}

void ps_drive(struct pack_side *ps, uint8_t present, uint8_t read_only, int timed)
{
	ps->write(ps, PS_DRIVE, (uint32_t)present | (uint32_t)read_only << 8 | (timed ? 1u << 16 : 0u));
}

void ps_deny(struct pack_side *ps)
{
	ps->write(ps, PS_CTL, PS_CTL_DENY);
	++ps->denials;
}

int ps_request(struct pack_side *ps, uint32_t ctl, uint32_t addr, uint32_t tag, unsigned slot,
	       uint32_t *status, char *why, size_t whylen)
{
	const int one = (ctl == PS_CTL_FETCH || ctl == PS_CTL_WRITE || ctl == PS_CTL_TAKE);
	ps->write(ps, PS_ADDR, addr);
	ps->write(ps, PS_TAG, tag);
	ps->write(ps, PS_SLOT, slot);
	ps->write(ps, PS_CTL, ctl);
	// The face acts on the CTL beat one tick later and shows busy or
	// refused the tick after that; the write and read halves of GP0 are
	// independent, so a read issued on the heels of the write could in
	// principle see the word before the request.  A read of IDENT first is
	// a whole round trip through the interconnect, tens of ticks, and
	// re-checks that the face is still there.
	if (ps->read(ps, PS_IDENT) != PS_IDENT_WORD) {
		snprintf(why, whylen, "IDENT stopped reading PACK during a request");
		*status = 0;
		return -1;
	}
	uint32_t st = ps->read(ps, PS_CTL);
	if (st & PS_ST_REFUSED) {
		*status = st;
		if (one && !(addr & (PS_RECORD_ALIGN - 1) && ctl != PS_CTL_TAKE) && slot < PS_SLOTS
		    && (st & PS_ST_CH_ACTIVE) && !(st & PS_ST_WAITING) && !(st & PS_ST_BUSY)) {
			// The one refusal the face raises on its own: the slot named
			// is the one the walk is on.  Not queued in fabric, by design,
			// and not waited for here: the caller chooses another slot.
			++ps->refused_walk;
			return PS_WALK_SLOT;
		}
		++ps->refused_other;
		if (!one)
			snprintf(why, whylen, "refused: CTL 0x%x asks for %s", ctl,
				 ctl ? "two requests in one word" : "nothing");
		else if ((addr & (PS_RECORD_ALIGN - 1)) && ctl != PS_CTL_TAKE)
			snprintf(why, whylen, "refused: address 0x%08x is not 128-byte aligned", addr);
		else if (slot >= PS_SLOTS)
			snprintf(why, whylen, "refused: slot %u is past the store's %u", slot, PS_SLOTS);
		else if (st & PS_ST_BUSY)
			snprintf(why, whylen, "refused: the face was busy with a move this program did not start");
		else if (st & PS_ST_WAITING)
			snprintf(why, whylen, "refused while the walk waits, which cannot be the channel's doing (status 0x%02x)", st);
		else
			snprintf(why, whylen, "refused for a reason this program did not create (status 0x%02x)", st);
		return -1;
	}
	// Accepted: busy until the move is over.
	for (unsigned polls = 0; st & PS_ST_BUSY; ++polls) {
		if (polls >= ps->poll_cap) {
			++ps->stuck;
			snprintf(why, whylen, "the face stayed busy for %u polls", polls);
			*status = st;
			return -1;
		}
		++ps->polls;
		ps->pause(ps);
		st = ps->read(ps, PS_CTL);
	}
	*status = st;
	if (!(st & PS_ST_DONE)) {
		snprintf(why, whylen, "the request was not seen: status 0x%02x is neither busy, done nor refused", st);
		return -1;
	}
	if (st & PS_ST_ERROR) {
		++ps->errors;
		snprintf(why, whylen, "the port answered an error: SLVERR or DECERR on a burst, or a burst that did not end where it should");
		return -1;
	}
	if (ctl == PS_CTL_FETCH)
		++ps->fetches;
	else if (ctl == PS_CTL_WRITE)
		++ps->writebacks;
	else
		++ps->takes;
	return 0;
}
