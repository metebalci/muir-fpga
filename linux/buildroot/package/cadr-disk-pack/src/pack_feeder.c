// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk pack program's core; `pack_feeder.h` says where the records go, what
// the replacement rule is, and why.

#include "pack_feeder.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

int feeder_init(struct feeder *f, struct pack *p, struct pack_side *ps,
		volatile uint32_t *mem, uint32_t mem_phys, size_t mem_bytes, FILE *log)
{
	memset(f, 0, sizeof *f);
	f->pack = p;
	f->ps = ps;
	f->mem = mem;
	f->mem_phys = mem_phys;
	f->mem_bytes = mem_bytes;
	f->log = log;
	for (unsigned s = 0; s < PS_SLOTS; ++s)
		f->slot_lba[s] = -1;
	// Both areas for every slot must be inside what is mapped.
	if (mem_phys > FEEDER_SPARE_BASE || mem_phys + mem_bytes < FEEDER_SPARE_BASE + FEEDER_MAP_BYTES)
		return -1;
	return 0;
}

uint32_t feeder_fetch_addr(unsigned slot)
{
	return FEEDER_SPARE_BASE + FEEDER_FETCH_OFF + slot * FEEDER_RECORD_STRIDE;
}

uint32_t feeder_wb_addr(unsigned slot)
{
	return FEEDER_SPARE_BASE + FEEDER_WB_OFF + slot * FEEDER_RECORD_STRIDE;
}

uint32_t feeder_poison(uint32_t addr, unsigned i)
{
	uint32_t v = (addr >> 7) * 0x9E3779B1u ^ i * 0x85EBCA6Bu ^ ((addr >> 7) ^ i) * 0xC2B2AE35u ^ 0x5A5AA5A5u;
	if (v == 0)
		v = 1;
	if (v == 0xFFFFFFFFu)
		v = 0xFFFFFFFEu;
	return v;
}

static volatile uint32_t *at(struct feeder *f, uint32_t addr)
{
	return f->mem + (addr - f->mem_phys) / 4;
}

static void say(struct feeder *f, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void say(struct feeder *f, const char *fmt, ...)
{
	if (!f->log)
		return;
	va_list ap;
	va_start(ap, fmt);
	fputs("cadr-disk-pack: ", f->log);
	vfprintf(f->log, fmt, ap);
	fputc('\n', f->log);
	va_end(ap);
	fflush(f->log);
}

int feeder_serve(struct feeder *f, unsigned unit, uint32_t c, uint32_t h, uint32_t b, unsigned slot,
		 char *err, size_t errlen)
{
	uint32_t lba;
	if (slot >= PS_SLOTS) {
		snprintf(err, errlen, "slot %u is past the store's %u", slot, PS_SLOTS);
		++f->failures;
		return -1;
	}
	if (unit != f->unit) {
		snprintf(err, errlen, "unit %u has no pack; the pack is on unit %u", unit, f->unit);
		++f->failures;
		return -1;
	}
	if (pack_lba(&f->pack->g, c, h, b, &lba) < 0) {
		snprintf(err, errlen, "%u/%u/%u is off the pack", c, h, b);
		++f->failures;
		return -1;
	}
	uint32_t words[PACK_RECORD_WORDS];
	if (pack_record(f->pack, lba, words, err, errlen) < 0) {
		++f->failures;
		return -1;
	}
	// The record at the slot's fetch address, word i at + 4i.
	const uint32_t addr = feeder_fetch_addr(slot);
	volatile uint32_t *rec = at(f, addr);
	for (int i = 0; i < PACK_RECORD_WORDS; ++i)
		rec[i] = words[i];
	__sync_synchronize();
	uint32_t st;
	char why[160];
	const int r = ps_fetch(f->ps, addr, ps_tag(unit, c, h, b), slot, &st, why, sizeof why);
	if (r == PS_WALK_SLOT) {
		++f->refused_walk;
		return PS_WALK_SLOT;
	}
	if (r < 0) {
		snprintf(err, errlen, "fetching block %u (%u/%u/%u) into slot %u: %s", lba, c, h, b, slot, why);
		++f->failures;
		// A refused request moved nothing and the slot holds what it held;
		// an accepted one that failed had taken the slot's block away first.
		if (!(st & PS_ST_REFUSED))
			f->slot_lba[slot] = -1;
		return -1;
	}
	// A stale claim on the same block elsewhere in the table is dropped.
	for (unsigned s = 0; s < PS_SLOTS; ++s)
		if (s != slot && f->slot_lba[s] == (int32_t)lba)
			f->slot_lba[s] = -1;
	f->slot_lba[slot] = (int32_t)lba;
	++f->served;
	return 0;
}

int feeder_writeback(struct feeder *f, unsigned slot, char *err, size_t errlen)
{
	if (slot >= PS_SLOTS || f->slot_lba[slot] < 0) {
		snprintf(err, errlen, "slot %u holds no block this feeder served", slot);
		++f->failures;
		return -1;
	}
	const uint32_t lba = (uint32_t)f->slot_lba[slot];
	const uint32_t addr = feeder_wb_addr(slot);
	volatile uint32_t *rec = at(f, addr);
	// Poison the record and the pad after it, so that a move which moved
	// nothing, or one that wrote the pad, is seen.
	for (int i = 0; i <= PACK_RECORD_WORDS; ++i)
		rec[i] = feeder_poison(addr, (unsigned)i);
	__sync_synchronize();
	uint32_t st;
	char why[160];
	const int r = ps_writeback(f->ps, addr, slot, &st, why, sizeof why);
	if (r == PS_WALK_SLOT) {
		++f->refused_walk;
		return PS_WALK_SLOT;
	}
	if (r < 0) {
		snprintf(err, errlen, "writing slot %u (block %u) back to 0x%08x: %s", slot, lba, addr, why);
		++f->failures;
		return -1;
	}
	__sync_synchronize();
	uint32_t words[PACK_RECORD_WORDS];
	int still = 0;
	for (int i = 0; i < PACK_RECORD_WORDS; ++i) {
		words[i] = rec[i];
		if (words[i] == feeder_poison(addr, (unsigned)i))
			++still;
	}
	if (still == PACK_RECORD_WORDS) {
		++f->nothing_moved;
		++f->failures;
		snprintf(err, errlen, "slot %u (block %u): the face said done and nothing moved; the record at 0x%08x is all poison, not committed to the pack",
			 slot, lba, addr);
		return -1;
	}
	if (rec[PACK_RECORD_WORDS] != feeder_poison(addr, PACK_RECORD_WORDS)) {
		++f->pad_written;
		++f->failures;
		snprintf(err, errlen, "slot %u (block %u): the pad word after the record at 0x%08x was written; not committed to the pack",
			 slot, lba, addr);
		return -1;
	}
	if (pack_writeback(f->pack, lba, words, err, errlen) < 0) {
		++f->failures;
		return -1;
	}
	++f->written_back;
	return 0;
}

int feeder_take(struct feeder *f, unsigned slot, char *err, size_t errlen)
{
	uint32_t st;
	char why[160];
	if (slot >= PS_SLOTS) {
		snprintf(err, errlen, "slot %u is past the store's %u", slot, PS_SLOTS);
		return -1;
	}
	const int r = ps_take(f->ps, slot, &st, why, sizeof why);
	if (r == PS_WALK_SLOT) {
		++f->refused_walk;
		return PS_WALK_SLOT;
	}
	if (r < 0) {
		snprintf(err, errlen, "taking slot %u away: %s", slot, why);
		++f->failures;
		return -1;
	}
	f->slot_lba[slot] = -1;
	++f->takes;
	return 0;
}

int feeder_start(struct feeder *f, unsigned unit, int read_only, int timed, char *err, size_t errlen)
{
	f->unit = unit & 7u;
	f->hand = 0;
	// What the store holds is unknown to this program: every slot taken
	// away, and a dirty one is a write this program cannot put on the pack,
	// its block being unknown.  Said once, with the count.
	const uint32_t dirty = ps_dirty(f->ps);
	for (unsigned s = 0; s < PS_SLOTS; ++s) {
		if (dirty & (1u << s))
			++f->lost_at_start;
		char why[160];
		uint32_t st;
		const int r = ps_take(f->ps, s, &st, why, sizeof why);
		if (r == PS_WALK_SLOT) {
			snprintf(err, errlen, "slot %u is the walk's at the start: the CADR is in a transfer while this program starts", s);
			return -1;
		}
		if (r < 0) {
			snprintf(err, errlen, "taking slot %u away at the start: %s", s, why);
			return -1;
		}
		f->slot_lba[s] = -1;
	}
	if (f->lost_at_start)
		say(f, "%lu slot(s) were dirty before this program started; their blocks are unknown to it and the CADR's writes to them are lost",
		    f->lost_at_start);
	// Whatever stood in IRQ and REF before this program is not its.
	ps_irq_clear(f->ps, PS_IRQ_REQ | PS_IRQ_DIRTY | PS_IRQ_DONE);
	ps_ref_clear(f->ps, (1u << PS_SLOTS) - 1u);
	ps_drive(f->ps, (uint8_t)(1u << f->unit), (uint8_t)(read_only ? 1u << f->unit : 0u), timed);
	say(f, "%u slots taken away; the drive on unit %u is present (%s, %s)", PS_SLOTS, f->unit,
	    read_only ? "read-only" : "writable", timed ? "its own time charged" : "untimed");
	return 0;
}

// Second chance: from the hand, pass a slot whose REF bit is up and clear
// it, stop at the first whose bit is down.  The walk's slot, learned from
// the refusal, is passed without a clear.  Returns the slot, or -1 after a
// full turn of refusals (the walk on every slot, which cannot be).
static int next_victim(struct feeder *f, uint32_t skip)
{
	uint32_t ref = ps_ref(f->ps);
	for (unsigned tries = 0; tries < 2 * PS_SLOTS + 1; ++tries) {
		const unsigned s = f->hand;
		f->hand = (f->hand + 1) % PS_SLOTS;
		if (skip & (1u << s))
			continue;
		if (ref & (1u << s)) {
			ps_ref_clear(f->ps, 1u << s);
			ref &= ~(1u << s);
			continue;
		}
		return (int)s;
	}
	return -1;
}

// A denial, named once per block on the console.
static void deny(struct feeder *f, uint32_t tag, const char *why)
{
	ps_deny(f->ps);
	++f->denied;
	int named = 0;
	for (unsigned i = 0; i < f->n_named_denials; ++i)
		if (f->named_denials[i] == tag)
			named = 1;
	if (!named) {
		unsigned unit;
		uint32_t c, h, b;
		ps_tag_split(tag, &unit, &c, &h, &b);
		if (f->n_named_denials < FEEDER_NAMED_DENIALS)
			f->named_denials[f->n_named_denials++] = tag;
		say(f, "denied block %u/%u/%u on unit %u: %s", c, h, b, unit, why);
	}
}

// One request answered: denied, or served into a slot of second chance's
// choosing, a dirty victim written back first.
static int answer(struct feeder *f, uint32_t tag, char *err, size_t errlen)
{
	unsigned unit;
	uint32_t c, h, b, lba;
	ps_tag_split(tag, &unit, &c, &h, &b);
	++f->requests;
	if (unit != f->unit) {
		deny(f, tag, "no pack on that unit");
		return 1;
	}
	if (pack_lba(&f->pack->g, c, h, b, &lba) < 0) {
		char why[96];
		snprintf(why, sizeof why, "off a pack of %u cylinders, %u heads, %u blocks a track",
			 f->pack->g.cylinders, f->pack->g.heads, f->pack->g.blocks_per_track);
		deny(f, tag, why);
		return 1;
	}
	// The same request standing after it was served means the tag that
	// landed did not match it: said, and denied rather than served for
	// ever.
	if (f->have_last && f->last_answered == tag && ++f->repeat_serves >= 3) {
		say(f, "block %u/%u/%u was served %u times and the request still stands: the tag that landed does not match it",
		    c, h, b, f->repeat_serves);
		f->repeat_serves = 0;
		deny(f, tag, "served and not taken");
		++f->failures;
		return 1;
	}
	uint32_t skip = 0;
	for (unsigned tries = 0; tries < PS_SLOTS; ++tries) {
		const int v = next_victim(f, skip);
		if (v < 0)
			break;
		const uint32_t dirty = ps_dirty(f->ps);
		if (dirty & (1u << v)) {
			const int w = feeder_writeback(f, (unsigned)v, err, errlen);
			if (w == PS_WALK_SLOT) {
				skip |= 1u << v;
				continue;
			}
			if (w < 0)
				return -1;
		}
		const int r = feeder_serve(f, unit, c, h, b, (unsigned)v, err, errlen);
		if (r == PS_WALK_SLOT) {
			skip |= 1u << v;
			continue;
		}
		if (r < 0) {
			// The pack could not give the block: a read error is a denial
			// the CADR must see, not a wait for ever.
			say(f, "%s", err);
			deny(f, tag, "the pack could not be read");
			return -1;
		}
		if (f->have_last && f->last_answered == tag)
			++f->repeat_serves;
		else
			f->repeat_serves = 1;
		f->have_last = 1;
		f->last_answered = tag;
		if (f->named_requests < FEEDER_NAMED_REQUESTS) {
			++f->named_requests;
			say(f, "request %lu: block %u (%u/%u/%u) served into slot %d from 0x%08x%s", f->requests, lba, c, h, b, v,
			    feeder_fetch_addr((unsigned)v),
			    f->named_requests == FEEDER_NAMED_REQUESTS ? "; further requests are counted, not named" : "");
		}
		return 1;
	}
	snprintf(err, errlen, "no slot could take block %u: every slot was the walk's", lba);
	++f->failures;
	return -1;
}

static int feeder_pass(struct feeder *f, char *err, size_t errlen);
int feeder_poll(struct feeder *f, char *err, size_t errlen)
{
	const int r = feeder_pass(f, err, errlen);
	if (r < 0)
		snprintf(f->last_failure, sizeof f->last_failure, "%s", err);
	return r;
}
static int feeder_pass(struct feeder *f, char *err, size_t errlen)
{
	int actions = 0;
	++f->polls;
	// The events, cleared as read: an event after the read stands for the
	// next pass.
	const uint32_t irq = ps_irq(f->ps);
	if (irq)
		ps_irq_clear(f->ps, irq);
	// The request.
	const uint32_t req = ps_req(f->ps);
	if (req & PS_REQ_VALID) {
		const int r = answer(f, req & PS_TAG_MASK, err, errlen);
		if (r < 0)
			return -1;
		actions += r;
	}
	// Dirty slots, at leisure; the walk's is left for the next pass.
	const uint32_t dirty = ps_dirty(f->ps);
	for (unsigned s = 0; s < PS_SLOTS; ++s) {
		if (!(dirty & (1u << s)))
			continue;
		if (f->slot_lba[s] < 0) {
			// Written by the CADR into a slot this program never filled:
			// cannot happen after the start's take-aways unless the
			// table is wrong.  Said once per pass and left.
			snprintf(err, errlen, "slot %u is dirty and this program does not know its block", s);
			++f->failures;
			continue;
		}
		const int r = feeder_writeback(f, s, err, errlen);
		if (r == PS_WALK_SLOT) {
			// The walk is on it, or was at the beat --- the previous
			// transfer's slot during the next START's command-list fetch
			// (feeder_test.c, the board's 0x5a).  The next pass.
			++f->deferred_dirty;
			if (++f->deferred_runs[s] > f->longest_deferral)
				f->longest_deferral = f->deferred_runs[s];
			if (f->deferred_runs[s] == FEEDER_DEFERRAL_CAP)
				say(f, "slot %u (block %d) has been refused as the walk's on %u passes in a row; still trying",
				    s, f->slot_lba[s], FEEDER_DEFERRAL_CAP);
			continue;
		}
		f->deferred_runs[s] = 0;
		if (r < 0)
			return -1;
		++actions;
	}
	return actions;
}

unsigned feeder_flush(struct feeder *f, unsigned passes, char *err, size_t errlen)
{
	for (unsigned n = 0; n < passes; ++n) {
		if (ps_dirty(f->ps) == 0)
			return 0;
		if (feeder_poll(f, err, errlen) < 0)
			return PS_SLOTS;
		f->ps->pause(f->ps);
	}
	const uint32_t dirty = ps_dirty(f->ps);
	unsigned still = 0;
	for (unsigned s = 0; s < PS_SLOTS; ++s)
		if (dirty & (1u << s))
			++still;
	if (still)
		snprintf(err, errlen, "%u slot(s) still dirty after %u passes: DIRTY 0x%06x", still, passes, dirty);
	return still;
}
