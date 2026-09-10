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
		// What refuses a move, from `rtl/cadr_disk_pack.sv`'s `refuse`: not
		// one bit of three, an unaligned address, a slot past the store, a
		// move in flight, or the channel active and not waiting ON THE SLOT
		// NAMED --- `bad_ch`.  The first four are this program's own doing
		// and are named.  Anything else IS `bad_ch`: the walk was on that
		// slot at the beat.  **`ch_active` and `waiting` in the word read
		// back are live, and the read is a GP0 round trip after the beat**,
		// so they say where the walk is now, not where it was when it
		// refused: between a START and its first lookup the controller's
		// `ch_slot` still names the slot the previous transfer wrote, a
		// write-back of that slot is refused there, and by the read the walk
		// has missed and stands WAITING --- status 0x5a on the board at
		// 13:48:13, once in 48,879 moves, and reproduced in feeder_test.c.
		// The answer is the caller's: another slot for a fetch, a later pass
		// for a write-back.
		if (!one) {
			++ps->refused_other;
			snprintf(why, whylen, "refused: CTL 0x%x asks for %s", ctl,
				 ctl ? "two requests in one word" : "nothing");
			return -1;
		}
		if ((addr & (PS_RECORD_ALIGN - 1)) && ctl != PS_CTL_TAKE) {
			++ps->refused_other;
			snprintf(why, whylen, "refused: address 0x%08x is not 128-byte aligned", addr);
			return -1;
		}
		if (slot >= PS_SLOTS) {
			++ps->refused_other;
			snprintf(why, whylen, "refused: slot %u is past the store's %u", slot, PS_SLOTS);
			return -1;
		}
		if (st & PS_ST_BUSY) {
			++ps->refused_other;
			snprintf(why, whylen, "refused: the face was busy with a move this program did not start");
			return -1;
		}
		++ps->refused_walk;
		return PS_WALK_SLOT;
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
