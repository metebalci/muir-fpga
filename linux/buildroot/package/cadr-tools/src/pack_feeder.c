// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack feeder's core; `pack_feeder.h` says where the records go and why.

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
	fputs("cadr-pack-feeder: ", f->log);
	vfprintf(f->log, fmt, ap);
	fputc('\n', f->log);
	va_end(ap);
	fflush(f->log);
}

int feeder_serve(struct feeder *f, uint32_t c, uint32_t h, uint32_t b, unsigned slot,
		 char *err, size_t errlen)
{
	uint32_t lba;
	if (slot >= PS_SLOTS) {
		snprintf(err, errlen, "slot %u is past the store's %u", slot, PS_SLOTS);
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
	if (ps_fetch(f->ps, addr, ps_tag(c, h, b), slot, &st, why, sizeof why) < 0) {
		snprintf(err, errlen, "fetching block %u (%u/%u/%u) into slot %u: %s", lba, c, h, b, slot, why);
		++f->failures;
		// A refused request moved nothing and the slot holds what it held;
		// an accepted one that failed had taken the slot's block away first.
		if (!(st & PS_ST_REFUSED))
			f->slot_lba[slot] = -1;
		return -1;
	}
	f->slot_lba[slot] = (int32_t)lba;
	++f->served;
	say(f, "served block %u (%u/%u/%u) into slot %u from 0x%08x", lba, c, h, b, slot, addr);
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
	if (ps_writeback(f->ps, addr, slot, &st, why, sizeof why) < 0) {
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
	say(f, "wrote slot %u back to the pack as block %u, header 0x%08x", slot, lba, words[256]);
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
	if (ps_take(f->ps, slot, &st, why, sizeof why) < 0) {
		snprintf(err, errlen, "taking slot %u away: %s", slot, why);
		++f->failures;
		return -1;
	}
	f->slot_lba[slot] = -1;
	++f->takes;
	say(f, "took slot %u away", slot);
	return 0;
}
