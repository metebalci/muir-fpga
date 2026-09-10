// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack feeder, held on the build host to a fabric that ASKS: no board,
// a model of the register face at a899799 in its place, and a scripted
// disk controller behind the model posting the requests the CADR's
// transfers would.
//
//     feeder_test <disk.golden> <work dir>
//
// WHAT THE TRACE SUPPLIES.  `golden/src/disk.rs` writes three kinds of row
// this test reads.  `BLK load|lay` is a block as the pack carries it before
// any transfer --- what a formatter or the vendor laid --- and goes onto the
// pack file exactly as muir's `Unit` would hold it.  `NEED` is a block a
// transfer read off the pack, in the order the walk reached it: here each
// run of NEED rows is one transfer the modelled controller makes, and the
// controller posts each block it lacks in REQ for the feeder to answer.
// `BLK write` is a block a transfer wrote: a Write the modelled controller
// makes of that block with those words, which dirties a slot the feeder
// must take back and put on the pack.
//
// WHAT THE SCRIPT ADDS, past the trace: requests for blocks off the pack
// and on a unit the feeder has no pack for (must be DENIED); a request
// posted as a prefetch while the walk stands on the one slot the hand
// would take (must be refused there and land elsewhere); a dirty slot
// that the hand reaches before its leisure write-back (must be written
// back before it is fetched into); forty more blocks than the store has
// slots (so second chance must evict); a Write All's foreign header and
// checkwords (so the sidecar has something to carry); and one address on
// two units.  The pack sits on unit 2 throughout, so the unit field of
// every tag is live and a request on unit 0 is the other-unit case.
//
// WHAT IS CHECKED, at the model's own registers as the fabric would see
// them.  Every request the controller posts is answered within a bounded
// number of the feeder's polls, by a fetch that lands the 259 words the
// pack carries, tagged with the request's own tag, from a 128-byte-aligned
// address in the spare part of the CADR's region with no burst across 4 KB
// --- or by a denial, exactly when the block is off the pack or on another
// unit.  No fetch or take-away ever lands on a DIRTY slot: the write-back
// comes first and the pack holds the CADR's words before the slot is
// reused.  The slot chosen is second chance over REF: the REF bits cleared
// on the way and the slot taken form one run of the hand from where the
// last fetch left it, the slot taken has its bit down, and the walk's slot
// is passed on the refusal and never taken.  Every dirty slot is written
// back within a few polls of the event unless the walk is on it.  And at
// the end the pack file holds, block for block, what the scripted writes
// imply; the sidecar brings the laid headers and checkwords back across a
// restart; deleted, the pack starts fresh and the sidecar is rebuilt on the
// first write-back; corrupted, it is refused and named, and replaced only
// when asked.
//
// THE MODEL OF THE REGISTER FACE follows `rtl/cadr_disk_pack.sv` at
// a899799: the tag with the unit in bits 30:28; the refusal terms at its
// `bad_align`, `bad_slot`, `bad_busy` and `bad_ch` --- the last PER SLOT,
// the channel active and not waiting on the slot named; `refused`
// rewritten on every move; busy for a number of status reads, then done;
// the slot taken away before a fetch and tagged after it; REQ valid until
// a tag lands equal to it or a DENY; DIRTY set by the walk's write and
// cleared by a move on the slot; REF set by the walk's hit and cleared by
// a fetch or a 1 written; IRQ's three events set by the fabric and cleared
// by ones written.  A model, not the RTL: what it holds the feeder to is
// the face's contract, and the RTL is held to the same contract by
// `tb/cadr_disk_pack_tb.cpp`.

#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include "pack_ecc.h"
#include "pack_feeder.h"
#include "pack_file.h"
#include "pack_side.h"

static int bad = 0;
static void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("FAIL: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++bad;
	if (bad > 40) {
		fprintf(stderr, "FAIL: too many; stopping\n");
		exit(1);
	}
}

// The unit the pack is on for this run: not zero, so the tag's unit field
// is live in every fetch.
#define UNIT 2u
#define ALL_SLOTS ((1u << PS_SLOTS) - 1u)
// How many polls a request may stand before it is answered, and a dirty
// slot before it is written back when the walk is not on it.
#define ANSWER_BOUND 2
#define DIRTY_BOUND 3
// How many polls a transfer may take from START to idle.
#define TRANSFER_BOUND 64

static const struct pack_geometry *G = &PACK_T300;

// ------------------------------------------------------- the shadow pack
// What the scripted writes imply the pack holds: the data, and whether the
// header and data checkword are laid or the format's own.  A second
// expression of muir's `write_sector_at` rule, kept apart from
// pack_file.c's so that a mutation there is caught here.
struct blk {
	uint32_t lba;
	uint32_t data[PACK_BLOCK_WORDS];
	uint32_t hdr, hck, dck;
	int hdr_laid, dck_laid;
	int touched;		// ever read or written by the script
};
static struct blk blocks[128];
static size_t n_blocks;

static struct blk *shadow(uint32_t lba, int make)
{
	for (size_t i = 0; i < n_blocks; ++i)
		if (blocks[i].lba == lba)
			return &blocks[i];
	if (!make)
		return NULL;
	if (n_blocks == sizeof blocks / sizeof blocks[0]) {
		fail("more distinct blocks than this test holds");
		exit(2);
	}
	memset(&blocks[n_blocks], 0, sizeof blocks[0]);
	blocks[n_blocks].lba = lba;
	return &blocks[n_blocks++];
}

static void shadow_expect(const struct blk *s, uint32_t w[PACK_RECORD_WORDS])
{
	memcpy(w, s->data, sizeof s->data);
	uint32_t c, h, b;
	pack_chb(G, s->lba, &c, &h, &b);
	if (s->hdr_laid) {
		w[256] = s->hdr;
		w[257] = s->hck;
	} else {
		w[256] = pack_header_of(G, c, h, b);
		w[257] = ecc_over_words(&w[256], 1);
	}
	w[258] = s->dck_laid ? s->dck : ecc_over_words(w, PACK_BLOCK_WORDS);
}

static void shadow_writeback(struct blk *s, const uint32_t w[PACK_RECORD_WORDS])
{
	memcpy(s->data, w, sizeof s->data);
	uint32_t c, h, b;
	pack_chb(G, s->lba, &c, &h, &b);
	const uint32_t own = pack_header_of(G, c, h, b);
	s->hdr_laid = !(w[256] == own && w[257] == ecc_over_words(&own, 1));
	s->hdr = w[256];
	s->hck = w[257];
	s->dck_laid = (w[258] != ecc_over_words(w, PACK_BLOCK_WORDS));
	s->dck = w[258];
}

// The format's own three words for a block.
static void format_words(uint32_t lba, const uint32_t data[PACK_BLOCK_WORDS], uint32_t w[PACK_RECORD_WORDS])
{
	uint32_t c, h, b;
	pack_chb(G, lba, &c, &h, &b);
	memcpy(w, data, PACK_BLOCK_BYTES);
	w[256] = pack_header_of(G, c, h, b);
	w[257] = ecc_over_words(&w[256], 1);
	w[258] = ecc_over_words(w, PACK_BLOCK_WORDS);
}

// A word of synthetic content: a function of the block and the offset, so
// that a wrong block and a wrong offset both read wrong.
static uint32_t synth(uint32_t lba, int i, uint32_t salt)
{
	return lba * 0x9E3779B1u ^ (uint32_t)i * 0x85EBCA6Bu ^ (lba ^ (uint32_t)i ^ salt) * 0xC2B2AE35u ^ 0x3C5A0F96u ^ salt;
}

// ------------------------------------------------------------ the model
struct fake {
	uint32_t regs[11];
	uint32_t store[PS_SLOTS][PACK_RECORD_WORDS];
	uint32_t tag[PS_SLOTS];
	int valid[PS_SLOTS];
	uint32_t dirty, ref, irq, irqen;
	int req_valid;
	uint32_t req_tag;
	int ch_active, waiting;
	unsigned ch_slot;
	int miss;
	uint32_t *ddr;		// the spare region, `ddr[0]` at `ddr_phys`
	uint32_t ddr_phys, ddr_bytes;
	int busy_left, busy_polls;	// status reads a move stays busy for
	int done, error, refused;
	int drop_next_write;		// a write-back that moves nothing
	uint32_t last_addr, last_ctl;
	unsigned long fetches, writes, takes, denials, refusals, refusals_walk, reads, pauses;

	// The controller behind the face: a queue of transfers, one at a time.
	struct xfer {
		unsigned unit;
		uint32_t tag[16];	// {unit, c, h, b}
		int n, write;
		uint32_t page[16][PACK_BLOCK_WORDS];
		int expect_deny;	// the script says this block is not servable
		int laid;		// a Write All: the three words after the block are these
		uint32_t laid_hdr, laid_hck, laid_dck;
	} queue[96];
	int q_head, q_tail;
	enum { T_IDLE, T_LOOK, T_WAIT, T_MOVE } tstate;
	int t_idx, move_left;
	int t_denied;
	// The script's hooks: REF to force when the walk goes idle, or right
	// after its next hit; and the start, when take-aways of what was there
	// before are the program's right.
	int ref_override_pending, ref_override_on_hit;
	uint32_t ref_override;
	int starting;

	// The clock: the test loop's iteration.
	long now;
	// The checks on the request path.
	long req_posted_at;
	uint32_t ref_cleared, walk_refused;	// since the request was posted
	uint32_t dirty_at_post;
	unsigned hand_expect;
	long dirty_since[PS_SLOTS];
	long worst_answer, worst_dirty;
	unsigned long requests, answered, denied_ok, denied_wrong, evict_writebacks, walk_refusals_seen;
	unsigned long hits_compared, words_compared, second_chance_runs, full_circles;
	int last_move_was_writeback_of;		// slot, or -1
	// Write-backs to verify against the pack file after the poll.
	struct { unsigned slot; uint32_t lba; uint32_t words[PACK_RECORD_WORDS]; } pending_wb[32];
	int n_pending_wb;
};

static int fake_in_ddr(struct fake *k, uint32_t addr, uint32_t bytes)
{
	return addr >= k->ddr_phys && addr - k->ddr_phys + bytes <= k->ddr_bytes;
}

static uint32_t fake_status(struct fake *k, int consume)
{
	int busy = 0;
	if (k->busy_left > 0) {
		if (consume)
			--k->busy_left;
		busy = 1;
	}
	return (k->waiting ? PS_ST_WAITING : 0) | (k->miss ? PS_ST_STORE_MISS : 0)
	     | (k->ch_active ? PS_ST_CH_ACTIVE : 0) | (k->refused ? PS_ST_REFUSED : 0)
	     | (k->error ? PS_ST_ERROR : 0) | (k->done && !busy ? PS_ST_DONE : 0) | (busy ? PS_ST_BUSY : 0);
}

static uint32_t fake_read(struct pack_side *ps, unsigned reg)
{
	struct fake *k = ps->ctx;
	++k->reads;
	switch (reg) {
	case PS_ADDR: case PS_TAG: case PS_SLOT: case PS_DRIVE:
		return k->regs[reg];
	case PS_CTL:
		return fake_status(k, 1);
	case PS_REQ:
		return (k->req_valid ? PS_REQ_VALID : 0) | k->req_tag;
	case PS_DIRTY:
		return k->dirty;
	case PS_IDENT:
		return PS_IDENT_WORD;
	case PS_REF:
		return k->ref;
	case PS_IRQ:
		return k->irq;
	case PS_IRQEN:
		return k->irqen;
	default:
		return 0;
	}
}

static uint32_t tag_lba(uint32_t tag, unsigned *unit)
{
	uint32_t c, h, b, lba;
	ps_tag_split(tag, unit, &c, &h, &b);
	if (pack_lba(G, c, h, b, &lba) < 0)
		return 0xFFFFFFFFu;
	return lba;
}

// The second-chance check, at a fetch into `s`: the REF bits Linux cleared
// since the request was posted, plus the walk's slots it was refused on,
// plus `s`, are one run of the hand from `hand_expect`; every slot passed
// had its bit up and was cleared, or was the walk's; `s` has its bit down.
static void check_second_chance(struct fake *k, unsigned s)
{
	if (k->ref & (1u << s))
		fail("second chance: slot %u was taken with its REF bit up (REF 0x%06x)", s, k->ref);
	uint32_t run = 0;
	unsigned j = k->hand_expect;
	int steps = 0;
	int full = 0;
	for (;;) {
		if (j == s && (steps > 0 || (k->ref_cleared == 0 && k->walk_refused == 0)))
			break;
		if (steps > (int)PS_SLOTS) {
			fail("second chance: the hand went round more than once from %u to %u", k->hand_expect, s);
			break;
		}
		run |= 1u << j;
		if (k->walk_refused & (1u << j)) {
			// The walk's slot, tried and refused: passed without a clear.
		} else if (!(k->ref_cleared & (1u << j))) {
			fail("second chance: slot %u was passed on the way from %u to %u without its REF bit being cleared (cleared 0x%06x, refused 0x%06x)",
			     j, k->hand_expect, s, k->ref_cleared, k->walk_refused);
		}
		j = (j + 1) % PS_SLOTS;
		++steps;
	}
	if (steps >= (int)PS_SLOTS - 1)
		full = 1;
	if (k->ref_cleared & ~run)
		fail("second chance: REF bits 0x%06x were cleared off the hand's run 0x%06x (from %u to %u)",
		     k->ref_cleared & ~run, run, k->hand_expect, s);
	if (k->walk_refused & ~run)
		fail("second chance: the walk's slot 0x%06x was tried off the hand's run (from %u to %u)",
		     k->walk_refused & ~run, k->hand_expect, s);
	k->hand_expect = (s + 1) % PS_SLOTS;
	++k->second_chance_runs;
	if (full)
		++k->full_circles;
}

static void fake_write(struct pack_side *ps, unsigned reg, uint32_t v)
{
	struct fake *k = ps->ctx;
	switch (reg) {
	case PS_ADDR: k->regs[reg] = v; return;
	case PS_TAG: k->regs[reg] = v & PS_TAG_MASK; return;
	case PS_SLOT: k->regs[reg] = v & 0x1Fu; return;
	case PS_DRIVE: k->regs[reg] = v & 0x1FFFFu; return;
	case PS_REF: k->ref &= ~(v & ALL_SLOTS); k->ref_cleared |= v & ALL_SLOTS; return;
	case PS_IRQ: k->irq &= ~(v & 7u); return;
	case PS_IRQEN: k->irqen = v & 7u; return;
	case PS_CTL: break;
	default: return;
	}
	// A denial rides beside the move bits and is never refused.
	if (v & PS_CTL_DENY) {
		++k->denials;
		if (!k->req_valid)
			fail("a denial with no request standing");
		else {
			unsigned unit;
			const uint32_t lba = tag_lba(k->req_tag, &unit);
			const struct xfer *x = &k->queue[k->q_head];
			if (k->tstate == T_IDLE || !x->expect_deny || unit != x->unit) {
				fail("request 0x%08x (unit %u, block %x) was denied and the script expected it served", k->req_tag, unit, lba);
				++k->denied_wrong;
			} else {
				++k->denied_ok;
			}
			k->req_valid = 0;
			k->t_denied = 1;
			k->miss = 1;
		}
	}
	const uint32_t go = v & 7u;
	if (!go)
		return;
	const int one = (go == 1 || go == 2 || go == 4);
	const uint32_t addr = k->regs[PS_ADDR];
	const unsigned slot = k->regs[PS_SLOT];
	const int bad_align = (addr & 0x7Fu) != 0 && go != PS_CTL_TAKE;
	const int bad_slot = slot >= PS_SLOTS;
	const int busy = k->busy_left > 0;
	const int bad_ch = k->ch_active && !k->waiting && slot == k->ch_slot;
	k->refused = !one || bad_align || bad_slot || busy || bad_ch;
	k->last_ctl = go;
	if (k->refused) {
		++k->refusals;
		if (bad_ch && one && !bad_align && !bad_slot && !busy) {
			++k->refusals_walk;
			k->walk_refused |= 1u << slot;
		}
		return;
	}
	k->done = 0;
	k->error = 0;
	k->busy_left = k->busy_polls;
	k->last_addr = addr;
	if (go == PS_CTL_TAKE) {
		if ((k->dirty & (1u << slot)) && !k->starting)
			fail("slot %u was taken away while DIRTY: the CADR's write is lost", slot);
		k->valid[slot] = 0;
		k->dirty &= ~(1u << slot);
		++k->takes;
	} else if (go == PS_CTL_FETCH) {
		if (k->dirty & (1u << slot))
			fail("slot %u was fetched into while DIRTY: the CADR's write is lost", slot);
		if (k->req_valid) {
			check_second_chance(k, slot);
			// Dirty when the request was posted and clean now: written
			// back on the way, or the check above would have fired.
			if (k->dirty_at_post & (1u << slot))
				++k->evict_writebacks;
		}
		k->valid[slot] = 0;
		k->dirty &= ~(1u << slot);
		k->ref &= ~(1u << slot);
		if (!fake_in_ddr(k, addr, PACK_RECORD_WORDS * 4)) {
			k->error = 1;	// SLVERR/DECERR from the port
		} else {
			memcpy(k->store[slot], k->ddr + (addr - k->ddr_phys) / 4, PACK_RECORD_WORDS * 4);
			k->tag[slot] = k->regs[PS_TAG];
			k->valid[slot] = 1;
			// The tag landing is what ends a wait.
			if (k->req_valid && k->tag[slot] == k->req_tag) {
				k->req_valid = 0;
				++k->answered;
				const long took = k->now - k->req_posted_at + 1;   // polls, the answering one included
				if (took > k->worst_answer)
					k->worst_answer = took;
				if (took > ANSWER_BOUND)
					fail("request 0x%08x stood %ld polls before its block landed (bound %d)", k->req_tag, took, ANSWER_BOUND);
			}
		}
		++k->fetches;
	} else {
		if (!fake_in_ddr(k, addr, PACK_RECORD_WORDS * 4))
			k->error = 1;
		else if (k->drop_next_write)
			k->drop_next_write = 0;
		else {
			memcpy(k->ddr + (addr - k->ddr_phys) / 4, k->store[slot], PACK_RECORD_WORDS * 4);
			if (k->valid[slot] && (k->dirty & (1u << slot))) {
				if (k->now - k->dirty_since[slot] > k->worst_dirty)
					k->worst_dirty = k->now - k->dirty_since[slot];
				if (k->n_pending_wb < (int)(sizeof k->pending_wb / sizeof k->pending_wb[0])) {
					unsigned unit;
					k->pending_wb[k->n_pending_wb].slot = slot;
					k->pending_wb[k->n_pending_wb].lba = tag_lba(k->tag[slot], &unit);
					memcpy(k->pending_wb[k->n_pending_wb].words, k->store[slot], sizeof k->store[slot]);
					++k->n_pending_wb;
				}
			}
		}
		k->dirty &= ~(1u << slot);
		++k->writes;
	}
	k->last_move_was_writeback_of = (go == PS_CTL_WRITE) ? (int)slot : -1;
	k->done = 1;
}

static void fake_pause(struct pack_side *ps)
{
	struct fake *k = ps->ctx;
	++k->pauses;
}

// ---- the controller behind the face -----------------------------------
static int find_slot(struct fake *k, uint32_t tag)
{
	for (unsigned s = 0; s < PS_SLOTS; ++s)
		if (k->valid[s] && k->tag[s] == tag)
			return (int)s;
	return -1;
}

static void post(struct fake *k, uint32_t tag)
{
	k->req_valid = 1;
	k->req_tag = tag;
	k->irq |= PS_IRQ_REQ;
	k->req_posted_at = k->now;
	k->ref_cleared = 0;
	k->walk_refused = 0;
	k->dirty_at_post = k->dirty;
	++k->requests;
}

static void hit(struct fake *k, struct xfer *x, int s)
{
	k->ch_slot = (unsigned)s;
	k->ref |= 1u << s;
	k->waiting = 0;
	unsigned unit;
	const uint32_t lba = tag_lba(x->tag[k->t_idx], &unit);
	struct blk *sh = shadow(lba, 0);
	if (!sh) {
		fail("the walk hit block %x, which the script never put on the pack", lba);
	} else {
		// What the store holds is what the pack carries.
		uint32_t want[PACK_RECORD_WORDS];
		shadow_expect(sh, want);
		for (int i = 0; i < PACK_RECORD_WORDS; ++i) {
			if (k->store[s][i] != want[i]) {
				fail("block %x word %d in slot %d is 0x%08x, the pack carries 0x%08x", lba, i, s, k->store[s][i], want[i]);
				break;
			}
			++k->words_compared;
		}
		++k->hits_compared;
		if (k->tag[s] != x->tag[k->t_idx])
			fail("slot %d is tagged 0x%08x, the walk wanted 0x%08x", s, k->tag[s], x->tag[k->t_idx]);
		if (x->write) {
			// The CADR's page into the block, the fresh data checkword
			// after it; a Write All lays what the script says.
			memcpy(k->store[s], x->page[k->t_idx], PACK_BLOCK_BYTES);
			k->store[s][258] = ecc_over_words(k->store[s], PACK_BLOCK_WORDS);
			if (x->laid) {
				k->store[s][256] = x->laid_hdr;
				k->store[s][257] = x->laid_hck;
				k->store[s][258] = x->laid_dck;
			}
			shadow_writeback(sh, k->store[s]);
			sh->touched = 1;
			if (!(k->dirty & (1u << s))) {
				k->irq |= PS_IRQ_DIRTY;
				k->dirty_since[s] = k->now;
			}
			k->dirty |= 1u << s;
		} else {
			sh->touched = 1;
		}
	}
	if (k->ref_override_on_hit) {
		k->ref = k->ref_override;
		k->ref_override_on_hit = 0;
	}
	// The prefetch: the next block asked for as this one begins to move.
	if (k->t_idx + 1 < x->n) {
		const uint32_t nt = x->tag[k->t_idx + 1];
		if (find_slot(k, nt) < 0 && !k->req_valid)
			post(k, nt);
	}
	k->tstate = T_MOVE;
	k->move_left = 2;
}

static void model_step(struct fake *k)
{
	++k->now;
	struct xfer *x = &k->queue[k->q_head];
	for (int again = 1; again;) {
		again = 0;
		switch (k->tstate) {
		case T_IDLE:
			if (k->q_head < k->q_tail) {
				x = &k->queue[k->q_head];
				k->t_idx = 0;
				k->t_denied = 0;
				k->ch_active = 1;
				k->tstate = T_LOOK;
				again = 1;
			}
			break;
		case T_LOOK: {
			const uint32_t tag = x->tag[k->t_idx];
			const int s = find_slot(k, tag);
			if (s >= 0) {
				if (x->expect_deny)
					fail("block 0x%08x, which the script says is not servable, is in slot %d", tag, s);
				hit(k, x, s);
			} else {
				if (!(k->req_valid && k->req_tag == tag))
					post(k, tag);
				k->waiting = 1;
				k->tstate = T_WAIT;
			}
			break;
		}
		case T_WAIT:
			if (k->req_valid)
				break;
			k->waiting = 0;
			if (k->t_denied) {
				k->ch_active = 0;
				k->tstate = T_IDLE;
				++k->q_head;
			} else {
				k->tstate = T_LOOK;
				again = 1;
			}
			break;
		case T_MOVE:
			if (--k->move_left > 0)
				break;
			++k->t_idx;
			if (k->t_idx >= x->n) {
				k->ch_active = 0;
				k->tstate = T_IDLE;
				++k->q_head;
				if (k->ref_override_pending) {
					k->ref = k->ref_override;
					k->ref_override_pending = 0;
				}
				// The next START can come at once, before Linux has
				// polled again.
				again = 1;
			} else {
				k->tstate = T_LOOK;
				again = 1;
			}
			break;
		}
	}
}

static struct xfer *enqueue(struct fake *k, unsigned unit, int write)
{
	if (k->q_tail == (int)(sizeof k->queue / sizeof k->queue[0])) {
		fail("the transfer queue is full");
		exit(2);
	}
	struct xfer *x = &k->queue[k->q_tail++];
	memset(x, 0, sizeof *x);
	x->unit = unit;
	x->write = write;
	return x;
}
static void xfer_block(struct xfer *x, uint32_t c, uint32_t h, uint32_t b)
{
	x->tag[x->n++] = ps_tag(x->unit, c, h, b);
}
static void xfer_lba(struct xfer *x, uint32_t lba)
{
	uint32_t c, h, b;
	pack_chb(G, lba, &c, &h, &b);
	xfer_block(x, c, h, b);
}

// ---- the run loop ------------------------------------------------------
static struct pack pk;
static struct feeder f;
static struct fake k;
static struct pack_side ps;
static unsigned long polls_run;

static void verify_pending_writebacks(void)
{
	for (int i = 0; i < k.n_pending_wb; ++i) {
		const uint32_t lba = k.pending_wb[i].lba;
		const uint32_t *w = k.pending_wb[i].words;
		uint8_t file_bytes[PACK_BLOCK_BYTES], want_bytes[PACK_BLOCK_BYTES];
		if (pread(pk.fd, file_bytes, sizeof file_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof file_bytes) {
			fail("reading block %x of the pack file after a write-back", lba);
			continue;
		}
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			for (int q = 0; q < 4; ++q)
				want_bytes[4 * j + q] = (uint8_t)(w[j] >> (8 * q));
		if (memcmp(file_bytes, want_bytes, sizeof file_bytes) != 0)
			fail("block %x in the pack file differs from what the CADR wrote into slot %u", lba, k.pending_wb[i].slot);
		uint32_t again[PACK_RECORD_WORDS];
		char err[256];
		if (pack_record(&pk, lba, again, err, sizeof err) < 0)
			fail("%s", err);
		else if (memcmp(again, w, sizeof again) != 0)
			fail("block %x's record after its write-back is not the 259 words written back", lba);
	}
	k.n_pending_wb = 0;
}

// Runs the queue to idle, the feeder polling once a step.
static void run(void)
{
	char err[256];
	long began = k.now;
	int head_seen = k.q_head;
	for (;;) {
		model_step(&k);
		if (k.q_head != head_seen) {
			head_seen = k.q_head;
			began = k.now;
		}
		if (k.tstate == T_IDLE && k.q_head >= k.q_tail) {
			// One more pass, so the dirty event of the last transfer is
			// seen; then the dirty bound.
			if (feeder_poll(&f, err, sizeof err) < 0)
				fail("feeder_poll: %s", err);
			++polls_run;
			verify_pending_writebacks();
			break;
		}
		if (feeder_poll(&f, err, sizeof err) < 0)
			fail("feeder_poll: %s", err);
		++polls_run;
		verify_pending_writebacks();
		if (k.now - began > TRANSFER_BOUND) {
			fail("a transfer did not run to idle in %ld polls: state %d, REQ %s0x%08x", k.now - began, (int)k.tstate,
			     k.req_valid ? "valid " : "", k.req_tag);
			// Drain so the next phase can go on.
			k.tstate = T_IDLE;
			k.ch_active = k.waiting = 0;
			k.req_valid = 0;
			k.q_head = k.q_tail;
			break;
		}
	}
	// Every dirty slot the walk is no longer on is written back within the
	// bound.
	for (unsigned s = 0; s < PS_SLOTS; ++s)
		if ((k.dirty & (1u << s)) && k.now - k.dirty_since[s] > DIRTY_BOUND) {
			for (int extra = 0; extra < 2 && (k.dirty & (1u << s)); ++extra) {
				++k.now;
				if (feeder_poll(&f, err, sizeof err) < 0)
					fail("feeder_poll: %s", err);
				++polls_run;
				verify_pending_writebacks();
			}
			if (k.dirty & (1u << s))
				fail("slot %u has been dirty for %ld polls with the walk idle (bound %d)", s, k.now - k.dirty_since[s], DIRTY_BOUND);
		}
}

static void lay(uint32_t lba, const uint32_t w[PACK_RECORD_WORDS])
{
	char err[256];
	struct blk *s = shadow(lba, 1);
	// A formatter laid the sector behind the store: a copy in the store is
	// stale and Linux takes it away, writing it back first if the CADR's
	// write is in it --- the trace's LAY rows are the fabric's stimulus and
	// the testbench fetches them afresh; here the feeder is asked to.
	{
		uint32_t c, h, b;
		pack_chb(G, lba, &c, &h, &b);
		const int sl = find_slot(&k, ps_tag(UNIT, c, h, b));
		if (sl >= 0) {
			if ((k.dirty & (1u << sl)) && feeder_writeback(&f, (unsigned)sl, err, sizeof err) != 0)
				fail("writing slot %d back before a lay: %s", sl, err);
			if (feeder_take(&f, (unsigned)sl, err, sizeof err) != 0)
				fail("taking slot %d away before a lay: %s", sl, err);
		}
	}
	if (pack_writeback(&pk, lba, w, err, sizeof err) < 0)
		fail("laying block %x: %s", lba, err);
	shadow_writeback(s, w);
}

// A synthetic block laid as the format lays it.
static void lay_synth(uint32_t lba, uint32_t salt)
{
	uint32_t data[PACK_BLOCK_WORDS], w[PACK_RECORD_WORDS];
	for (int i = 0; i < PACK_BLOCK_WORDS; ++i)
		data[i] = synth(lba, i, salt);
	format_words(lba, data, w);
	lay(lba, w);
}

static uint32_t hex(const char *s)
{
	return (uint32_t)strtoul(s, NULL, 16);
}

// Checks on an address the feeder chose: the fabric's rules, and that no
// two records the feeder ever placed lie within a record of each other.
static uint32_t areas[2 * PS_SLOTS + 8];
static size_t n_areas;
static void check_addr(uint32_t at, const char *what)
{
	int seen = 0;
	for (size_t i = 0; i < n_areas; ++i) {
		if (areas[i] == at)
			seen = 1;
		else if ((areas[i] > at ? areas[i] - at : at - areas[i]) < PACK_RECORD_WORDS * 4)
			fail("%s: the record at 0x%08x overlaps the one at 0x%08x", what, at, areas[i]);
	}
	if (!seen && n_areas < sizeof areas / sizeof areas[0])
		areas[n_areas++] = at;
	if (at % PS_RECORD_ALIGN)
		fail("%s: address 0x%08x is not 128-byte aligned", what, at);
	if (at < FEEDER_SPARE_BASE || at + PACK_RECORD_WORDS * 4 > FEEDER_SPARE_BASE + FEEDER_SPARE_BYTES)
		fail("%s: address 0x%08x is not inside the spare part of the CADR's region", what, at);
	for (unsigned burst = 0; burst < 9; ++burst) {
		const uint32_t a = at + (burst < 8 ? 128u * burst : 1024u);
		const uint32_t n = burst < 8 ? 128u : 16u;
		if ((a >> 12) != ((a + n - 1) >> 12))
			fail("%s: burst %u of the record at 0x%08x crosses 4 KB", what, burst, at);
	}
}

static void every_fetch_address_checked(void)
{
	// The model records only the last address; the addresses the feeder
	// uses are a function of the slot, so all 48 are checked here.
	for (unsigned s = 0; s < PS_SLOTS; ++s) {
		check_addr(feeder_fetch_addr(s), "a fetch");
		check_addr(feeder_wb_addr(s), "a write-back");
	}
}

static int file_exists(const char *path)
{
	struct stat st;
	return stat(path, &st) == 0;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: feeder_test <disk.golden> <work dir>\n");
		return 2;
	}
	FILE *trace = fopen(argv[1], "r");
	if (!trace) {
		fprintf(stderr, "feeder_test: %s: %s\n", argv[1], strerror(errno));
		return 2;
	}
	char err[256];

	// The pack: a T-300's size, sparse, fresh for this run, with no sidecar.
	char path[4096], meta[4096];
	snprintf(path, sizeof path, "%s/pack-test.img", argv[2]);
	snprintf(meta, sizeof meta, "%s/pack-test.meta", argv[2]);
	unlink(path);
	unlink(meta);
	{
		int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0 || ftruncate(fd, (off_t)G->cylinders * G->heads * G->blocks_per_track * PACK_BLOCK_BYTES) < 0) {
			fprintf(stderr, "feeder_test: %s: %s\n", path, strerror(errno));
			return 2;
		}
		close(fd);
	}
	{
		// A file of the wrong size is refused, as muir refuses it.
		char wrong[4096];
		snprintf(wrong, sizeof wrong, "%s/wrong-size.img", argv[2]);
		int fd = open(wrong, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) {
			if (ftruncate(fd, 1234567) < 0)
				fail("truncating the wrong-size file");
			close(fd);
		}
		struct pack w;
		if (pack_open_with(&w, wrong, "", 0, err, sizeof err) == 0) {
			fail("a file of 1,234,567 bytes was opened as a pack");
			pack_close(&w);
		}
		unlink(wrong);
	}
	// The derived name.
	{
		char n[64];
		pack_meta_name("/mnt/card/pack.img", n, sizeof n);
		if (strcmp(n, "/mnt/card/pack.meta") != 0)
			fail("the sidecar of /mnt/card/pack.img is named %s", n);
		pack_meta_name("/a/b/disk", n, sizeof n);
		if (strcmp(n, "/a/b/disk.meta") != 0)
			fail("the sidecar of /a/b/disk is named %s", n);
	}
	if (pack_open_with(&pk, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) < 0) {
		fail("opening the test pack: %s", err);
		return 1;
	}
	if (pk.g.heads != 19)
		fail("a file of a T-300's size was taken for %u heads", pk.g.heads);
	if (pk.meta_state != PACK_META_ABSENT)
		fail("with no sidecar the pack opened in state %d, not ABSENT", (int)pk.meta_state);
	if (file_exists(meta))
		fail("opening a pack created its sidecar; it is to be created at the first write-back");

	// The face, the spare, the feeder.
	memset(&k, 0, sizeof k);
	k.busy_polls = 5;
	k.ddr_phys = FEEDER_SPARE_BASE;
	k.ddr_bytes = FEEDER_MAP_BYTES;
	k.ddr = calloc(k.ddr_bytes / 4, 4);
	for (uint32_t i = 0; i < k.ddr_bytes / 4; ++i)
		k.ddr[i] = (i * 0x9E3779B1u) | 1u;
	k.last_move_was_writeback_of = -1;
	// The store holds something from before the feeder started: one dirty
	// slot the feeder can never write back, which it must report lost.
	k.valid[7] = 1;
	k.tag[7] = ps_tag(UNIT, 1, 1, 1);
	k.dirty = 1u << 7;
	ps_init(&ps);
	ps.read = fake_read;
	ps.write = fake_write;
	ps.pause = fake_pause;
	ps.ctx = &k;
	uint32_t ident;
	if (!ps_ident_ok(&ps, &ident))
		fail("IDENT read 0x%08x", ident);
	if (feeder_init(&f, &pk, &ps, k.ddr, k.ddr_phys, k.ddr_bytes, NULL) < 0) {
		fail("feeder_init");
		return 1;
	}
	every_fetch_address_checked();
	k.starting = 1;
	if (feeder_start(&f, UNIT, 0, 0, err, sizeof err) < 0)
		fail("feeder_start: %s", err);
	k.starting = 0;
	if (k.takes != PS_SLOTS)
		fail("feeder_start took %lu slots away, not %u", k.takes, PS_SLOTS);
	if (f.lost_at_start != 1)
		fail("feeder_start reported %lu slots lost, wanting 1 (slot 7 was dirty from before)", f.lost_at_start);
	if (k.regs[PS_DRIVE] != (1u << UNIT))
		fail("DRIVE is 0x%x after the start, wanting the drive present on unit %u", k.regs[PS_DRIVE], UNIT);
	for (unsigned s = 0; s < PS_SLOTS; ++s)
		if (k.valid[s])
			fail("slot %u is still valid after the start", s);
	k.hand_expect = f.hand;
	if (k.dirty)
		fail("DIRTY is 0x%06x after the start", k.dirty);

	// ---- the trace ---------------------------------------------------------
	unsigned long want_needs = 0, want_writes = 0;
	unsigned long needs = 0, loads = 0, lays = 0, writes = 0, ecc_checked = 0, transfers = 0;
	struct xfer *open_x = NULL;	// the run of NEED rows being gathered
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	long lineno = 0;
	while ((len = getline(&line, &cap, trace)) > 0) {
		++lineno;
		if (line[len - 1] == '\n')
			line[--len] = 0;
		if (line[0] == '#') {
			unsigned long v;
			if (sscanf(line, "# blocks_needed %lu", &v) == 1)
				want_needs = v;
			if (sscanf(line, "# starts %*u pages_to_memory %*u blocks_to_pack %lu", &v) == 1)
				want_writes = v;
			continue;
		}
		char *save = NULL;
		char *kind = strtok_r(line, " ", &save);
		if (!kind)
			continue;
		if (strcmp(kind, "NEED") != 0 && open_x) {
			run();
			++transfers;
			open_x = NULL;
		}
		if (strcmp(kind, "BLK") == 0) {
			const char *why = strtok_r(NULL, " ", &save);
			strtok_r(NULL, " ", &save);	// the trace's slot: the feeder chooses its own now
			strtok_r(NULL, " ", &save);	// `at`: the trace's DDR address, the testbench's business
			const uint32_t lba = hex(strtok_r(NULL, " ", &save));
			const uint32_t c = hex(strtok_r(NULL, " ", &save));
			const uint32_t h = hex(strtok_r(NULL, " ", &save));
			const uint32_t b = hex(strtok_r(NULL, " ", &save));
			uint32_t words[PACK_RECORD_WORDS];
			words[256] = hex(strtok_r(NULL, " ", &save));
			words[257] = hex(strtok_r(NULL, " ", &save));
			words[258] = hex(strtok_r(NULL, " ", &save));
			for (int i = 0; i < PACK_BLOCK_WORDS; ++i) {
				const char *w = strtok_r(NULL, " ", &save);
				if (!w) {
					fail("line %ld: BLK row with fewer than 256 words", lineno);
					break;
				}
				words[i] = hex(w);
			}
			uint32_t lba2;
			if (pack_lba(&pk.g, c, h, b, &lba2) < 0 || lba2 != lba)
				fail("line %ld: %u/%u/%u is lba %x here and %x in the trace", lineno, c, h, b, lba2, lba);
			if (strcmp(why, "write") == 0) {
				// The CADR wrote it: a Write of the block with these words
				// as the page.  The three words after it are what the
				// controller leaves --- the header as fetched, a fresh
				// data checkword --- and the model's hit must agree.
				++writes;
				struct xfer *x = enqueue(&k, UNIT, 1);
				xfer_block(x, c, h, b);
				memcpy(x->page[0], words, PACK_BLOCK_BYTES);
				x->laid = 1;
				x->laid_hdr = words[256];
				x->laid_hck = words[257];
				x->laid_dck = words[258];
				run();
				++transfers;
				struct blk *s = shadow(lba, 0);
				uint32_t got[PACK_RECORD_WORDS];
				if (s) {
					shadow_expect(s, got);
					if (memcmp(got, words, sizeof got) != 0)
						fail("line %ld: after the Write of block %x the record is not the trace's 259 words", lineno, lba);
				}
			} else {
				if (strcmp(why, "load") == 0) {
					++loads;
					if (ecc_over_words(&words[256], 1) != words[257])
						fail("line %ld: header checkword of 0x%08x is 0x%08x here, 0x%08x in muir", lineno, words[256], ecc_over_words(&words[256], 1), words[257]);
					else if (ecc_over_words(words, PACK_BLOCK_WORDS) != words[258])
						fail("line %ld: data checkword of block %x is 0x%08x here, 0x%08x in muir", lineno, lba, ecc_over_words(words, PACK_BLOCK_WORDS), words[258]);
					else
						++ecc_checked;
					if (words[256] != pack_header_of(&pk.g, c, h, b))
						fail("line %ld: header_of(%u,%u,%u) is 0x%08x here, 0x%08x in muir", lineno, c, h, b, pack_header_of(&pk.g, c, h, b), words[256]);
				} else {
					++lays;
				}
				lay(lba, words);
			}
		} else if (strcmp(kind, "NEED") == 0) {
			const uint32_t lba = hex(strtok_r(NULL, " ", &save));
			const uint32_t c = hex(strtok_r(NULL, " ", &save));
			const uint32_t h = hex(strtok_r(NULL, " ", &save));
			const uint32_t b = hex(strtok_r(NULL, " ", &save));
			++needs;
			if (!shadow(lba, 0)) {
				fail("line %ld: NEED %x, which no BLK row put on the pack", lineno, lba);
				continue;
			}
			if (!open_x || open_x->n == 16)
				open_x = enqueue(&k, UNIT, 0);
			xfer_block(open_x, c, h, b);
		}
		// ATTACH, RO, TIMED: the drive seam, the feeder's flags.  CYC,
		// MEMPAGE, MEMW, PAGE, LAY, INIT: the controller's business.
	}
	if (open_x) {
		run();
		++transfers;
	}
	free(line);
	fclose(trace);
	const unsigned long trace_requests = k.requests, trace_answered = k.answered;

	// ---- the script ----------------------------------------------------------
	unsigned long denials_expected = 0;
	// One address on two units: the other unit is denied, ours is served.
	{
		struct xfer *x = enqueue(&k, 0, 0);
		xfer_block(x, 0, 0, 0);
		x->expect_deny = 1;
		++denials_expected;
		x = enqueue(&k, UNIT, 0);
		xfer_block(x, 0, 0, 0);
		run();
		if (k.denied_ok != 1)
			fail("the request on unit 0 was not denied (%lu denials so far)", k.denied_ok);
		if (!k.miss)
			fail("store_miss is not up after a denial");
		k.miss = 0;
	}
	// Off the pack three ways.
	{
		struct xfer *x = enqueue(&k, UNIT, 0);
		xfer_block(x, G->cylinders, 0, 0);
		x->expect_deny = 1;
		x = enqueue(&k, UNIT, 0);
		xfer_block(x, 0, G->heads, 0);
		x->expect_deny = 1;
		x = enqueue(&k, UNIT, 0);
		xfer_block(x, 0, 0, G->blocks_per_track);
		x->expect_deny = 1;
		denials_expected += 3;
		run();
		if (k.denied_ok != denials_expected)
			fail("%lu denials for %lu blocks off the pack", k.denied_ok, denials_expected);
		k.miss = 0;
	}
	// Forty blocks more than the store has slots, with Writes among them:
	// second chance must evict, and evicted dirty slots go back first.
	unsigned long sweep_reads = 0, sweep_writes = 0;
	{
		uint32_t lbas[40];
		for (int i = 0; i < 40; ++i) {
			lbas[i] = 0x1000u + 7u * (uint32_t)i;
			lay_synth(lbas[i], 0x11u);
		}
		for (int i = 0; i < 40; ++i) {
			struct xfer *x = enqueue(&k, UNIT, 0);
			xfer_lba(x, lbas[i]);
			++sweep_reads;
			if (i % 5 == 4) {
				// A Write of a block read a few transfers ago, so it is
				// resident and dirtied; the leisure write-back follows.
				x = enqueue(&k, UNIT, 1);
				xfer_lba(x, lbas[i - 2]);
				for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
					x->page[0][j] = synth(lbas[i - 2], j, 0x22u + (uint32_t)i);
				++sweep_writes;
			}
		}
		run();
	}
	// A dirty slot the hand reaches before its leisure write-back: a Write
	// of block A ends and, in the same step, a Read of an absent block C
	// begins; REF is arranged so the hand lands on A's slot, dirty, with
	// its bit down.  The feeder must write A back and then fetch C there.
	{
		const uint32_t A = 0x2000u, C = 0x2001u;
		lay_synth(A, 0x33u);
		lay_synth(C, 0x33u);
		struct xfer *x = enqueue(&k, UNIT, 0);
		xfer_lba(x, A);
		run();
		const int vA = find_slot(&k, x->tag[0]);
		if (vA < 0)
			fail("block A did not land");
		else {
			// All bits up but A's, forced as the Write's walk goes idle.
			k.ref_override_pending = 1;
			k.ref_override = ALL_SLOTS & ~(1u << vA);
			x = enqueue(&k, UNIT, 1);
			xfer_lba(x, A);
			for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
				x->page[0][j] = synth(A, j, 0x44u);
			x = enqueue(&k, UNIT, 0);
			xfer_lba(x, C);
			const unsigned long ev0 = k.evict_writebacks;
			run();
			if (k.evict_writebacks != ev0 + 1)
				fail("the dirty slot the hand reached was not written back and then fetched into (%lu eviction write-backs, wanting %lu)", k.evict_writebacks, ev0 + 1);
			if (find_slot(&k, x->tag[0]) != vA)
				fail("block C landed in slot %d, not A's slot %d", find_slot(&k, x->tag[0]), vA);
		}
	}
	// The walk's slot: a chained Read whose first block sits in the one
	// slot with REF down, and whose second block is absent.  The prefetch
	// is posted while the walk is on that slot; the hand must be refused
	// there and take the next.
	unsigned long walk_case_refusals = 0;
	{
		const uint32_t X1 = 0x3000u, X2 = 0x3001u, Y = 0x3002u;
		lay_synth(X1, 0x55u);
		lay_synth(X2, 0x55u);
		lay_synth(Y, 0x55u);
		k.ref = 0;
		struct xfer *x = enqueue(&k, UNIT, 0);
		xfer_lba(x, X2);
		run();
		const int v2 = find_slot(&k, x->tag[0]);
		if (v2 < 0)
			fail("block X2 did not land");
		else {
			// Every bit but the walk's slot's, forced as the walk hits it:
			// the hit sets the bit, so the state is forced rather than
			// reached, and what is checked is what the program does with
			// a hand that lands on the walk's slot.
			k.ref_override_on_hit = 1;
			k.ref_override = ALL_SLOTS & ~(1u << v2);
			x = enqueue(&k, UNIT, 0);
			xfer_lba(x, X2);
			xfer_lba(x, Y);
			const unsigned long r0 = k.refusals_walk;
			run();
			walk_case_refusals = k.refusals_walk - r0;
			if (walk_case_refusals != 1)
				fail("the walk's slot was refused %lu times, wanting exactly 1", walk_case_refusals);
			const int vY = find_slot(&k, x->tag[1]);
			if (vY != (v2 + 1) % (int)PS_SLOTS)
				fail("the prefetched block landed in slot %d; the hand should have passed the walk's %d to %d", vY, v2, (v2 + 1) % (int)PS_SLOTS);
			if (find_slot(&k, x->tag[0]) != v2)
				fail("the block the walk was on left its slot");
		}
		(void)X1;
	}
	// A Write All: foreign header and checkwords laid on a block, so the
	// sidecar has something to carry.
	unsigned long laid_blocks = 0;
	{
		const uint32_t L = 0x4000u;
		lay_synth(L, 0x66u);
		struct xfer *x = enqueue(&k, UNIT, 1);
		xfer_lba(x, L);
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			x->page[0][j] = synth(L, j, 0x77u);
		x->laid = 1;
		x->laid_hdr = 0x5A000000u | (L & 0xFFFFu);
		x->laid_hck = ecc_over_words(&x->laid_hdr, 1) ^ 0x00010000u;
		x->laid_dck = ecc_over_words(x->page[0], PACK_BLOCK_WORDS) ^ 0x80000001u;
		run();
		struct blk *s = shadow(L, 0);
		if (!s || !s->hdr_laid || !s->dck_laid)
			fail("the Write All did not lay a foreign header and checkword in the shadow");
		// And read back: the laid words come through the store.
		x = enqueue(&k, UNIT, 0);
		xfer_lba(x, L);
		run();
	}

	// ---- the end of the run: every dirty slot back, the pack as implied -----
	{
		const unsigned still = feeder_flush(&f, 4, err, sizeof err);
		if (still)
			fail("%u slots still dirty after the flush: %s", still, err);
		if (k.dirty)
			fail("DIRTY is 0x%06x after the flush", k.dirty);
		verify_pending_writebacks();
	}
	unsigned long touched = 0, compared_final = 0;
	for (size_t i = 0; i < n_blocks; ++i) {
		const struct blk *s = &blocks[i];
		if (!s->touched)
			continue;
		++touched;
		uint8_t file_bytes[PACK_BLOCK_BYTES], want_bytes[PACK_BLOCK_BYTES];
		if (pread(pk.fd, file_bytes, sizeof file_bytes, (off_t)s->lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof file_bytes) {
			fail("reading block %x of the pack file at the end", s->lba);
			continue;
		}
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			for (int q = 0; q < 4; ++q)
				want_bytes[4 * j + q] = (uint8_t)(s->data[j] >> (8 * q));
		if (memcmp(file_bytes, want_bytes, sizeof file_bytes) != 0)
			fail("block %x in the pack file at the end is not what the scripted writes imply", s->lba);
		else
			compared_final += sizeof file_bytes;
		uint32_t want[PACK_RECORD_WORDS], got[PACK_RECORD_WORDS];
		shadow_expect(s, want);
		if (pack_record(&pk, s->lba, got, err, sizeof err) < 0)
			fail("%s", err);
		else if (memcmp(got, want, sizeof got) != 0)
			fail("block %x's record at the end is not what the scripted writes imply", s->lba);
		if (s->hdr_laid || s->dck_laid)
			++laid_blocks;
	}
	if (laid_blocks == 0)
		fail("no block carries a laid header or checkword: the sidecar test would be vacuous");

	// ---- the driver's handling of what the face can refuse ------------------
	unsigned long refusals = 0;
	{
		uint32_t st;
		if (ps_fetch(&ps, feeder_fetch_addr(1) + 64, ps_tag(UNIT, 1, 2, 3), 1, &st, err, sizeof err) == 0)
			fail("an unaligned fetch was not refused");
		else if (!strstr(err, "align"))
			fail("an unaligned fetch was refused with '%s'", err);
		else
			++refusals;
		if (ps_fetch(&ps, feeder_fetch_addr(1), ps_tag(UNIT, 1, 2, 3), PS_SLOTS, &st, err, sizeof err) == 0)
			fail("a fetch into slot 24 was not refused");
		else if (!strstr(err, "slot"))
			fail("a fetch into slot 24 was refused with '%s'", err);
		else
			++refusals;
		if (ps_request(&ps, PS_CTL_FETCH | PS_CTL_WRITE, feeder_fetch_addr(1), 0, 1, &st, err, sizeof err) == 0)
			fail("two requests in one word were not refused");
		else
			++refusals;
		if (ps.refused_other != 3)
			fail("the driver counted %lu refusals it caused, wanting 3", ps.refused_other);
		// The walk's slot: PS_WALK_SLOT, no retry, no pause.
		k.ch_active = 1;
		k.waiting = 0;
		k.ch_slot = 3;
		const unsigned long p0 = k.pauses;
		const int r = ps_fetch(&ps, feeder_fetch_addr(3), ps_tag(UNIT, 1, 2, 3), 3, &st, err, sizeof err);
		if (r != PS_WALK_SLOT)
			fail("a fetch into the walk's slot returned %d, not PS_WALK_SLOT", r);
		if (k.pauses != p0)
			fail("the driver paused %lu times on the walk's slot instead of choosing another", k.pauses - p0);
		++refusals;
		// While the walk waits, its slot is anyone's.
		k.waiting = 1;
		if (ps_fetch(&ps, feeder_fetch_addr(3), ps_tag(UNIT, 1, 2, 3), 3, &st, err, sizeof err) != 0)
			fail("a fetch into the walk's slot while it waits was refused: %s", err);
		k.ch_active = k.waiting = 0;
		k.valid[3] = 0;
		// A write-back that moved nothing: seen by the poison, the pack
		// left as it was.
		const uint32_t lba = 0x1000u;
		struct blk *s = shadow(lba, 0);
		int slot = find_slot(&k, ps_tag(UNIT, 0, 0, 0));
		{
			uint32_t c, h, b;
			pack_chb(G, lba, &c, &h, &b);
			slot = find_slot(&k, ps_tag(UNIT, c, h, b));
		}
		if (slot < 0) {
			// Evicted by the sweep; bring it back.
			struct xfer *x = enqueue(&k, UNIT, 0);
			xfer_lba(x, lba);
			run();
			uint32_t c, h, b;
			pack_chb(G, lba, &c, &h, &b);
			slot = find_slot(&k, ps_tag(UNIT, c, h, b));
		}
		uint8_t before_bytes[PACK_BLOCK_BYTES], after_bytes[PACK_BLOCK_BYTES];
		if (pread(pk.fd, before_bytes, sizeof before_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof before_bytes)
			fail("reading the pack before the dropped write-back");
		k.store[slot][5] ^= 0xFFFFFFFFu;
		k.drop_next_write = 1;
		if (feeder_writeback(&f, (unsigned)slot, err, sizeof err) == 0)
			fail("a write-back that moved nothing was reported done");
		else if (!strstr(err, "nothing"))
			fail("a write-back that moved nothing was reported as '%s'", err);
		if (pread(pk.fd, after_bytes, sizeof after_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof after_bytes)
			fail("reading the pack after the dropped write-back");
		if (memcmp(before_bytes, after_bytes, sizeof before_bytes) != 0)
			fail("a write-back that moved nothing changed the pack");
		if (f.nothing_moved != 1)
			fail("nothing_moved is %lu", f.nothing_moved);
		k.store[slot][5] ^= 0xFFFFFFFFu;
		(void)s;
		// A port that answers SLVERR: the error bit, reported.
		if (ps_fetch(&ps, FEEDER_SPARE_BASE + FEEDER_SPARE_BYTES - 0x800u, ps_tag(UNIT, 1, 2, 3), 2, &st, err, sizeof err) == 0)
			fail("a fetch the port answered with an error was reported done");
		else if (!(st & PS_ST_ERROR))
			fail("the error bit was not read back after a refused burst");
		// A take-away.
		if (feeder_take(&f, (unsigned)slot, err, sizeof err) < 0)
			fail("take: %s", err);
		if (k.valid[slot])
			fail("slot %d is still valid after a take-away", slot);
	}

	// ---- the sidecar ----------------------------------------------------------
	unsigned long sidecar_blocks_compared = 0;
	if (!file_exists(meta))
		fail("the sidecar was not created by the first write-back");
	else {
		struct stat st;
		stat(meta, &st);
		if ((uint64_t)st.st_size != pack_meta_bytes(G))
			fail("the sidecar is %lld bytes, wanting %llu", (long long)st.st_size, (unsigned long long)pack_meta_bytes(G));
	}
	// A restart from the files: the same headers and checkwords come back.
	pack_close(&pk);
	if (pack_open_with(&pk, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) < 0)
		fail("reopening the pack with its sidecar: %s", err);
	else {
		if (pk.meta_state != PACK_META_READ)
			fail("reopened with a sidecar present, the state is %d, not READ", (int)pk.meta_state);
		if (pk.meta_headers_read == 0 || pk.meta_dcks_read == 0)
			fail("the sidecar read back %zu laid headers and %zu laid checkwords; both should be live", pk.meta_headers_read, pk.meta_dcks_read);
		for (size_t i = 0; i < n_blocks; ++i) {
			const struct blk *s = &blocks[i];
			if (!s->touched)
				continue;
			uint32_t want[PACK_RECORD_WORDS], got[PACK_RECORD_WORDS];
			shadow_expect(s, want);
			if (pack_record(&pk, s->lba, got, err, sizeof err) < 0)
				fail("%s", err);
			else if (memcmp(got, want, sizeof got) != 0)
				fail("after the restart block %x's record is not what was written", s->lba);
			else
				++sidecar_blocks_compared;
		}
	}
	// Deleted: the pack starts fresh, every block as the format lays it,
	// and the sidecar is rebuilt on the first write-back.
	unsigned long fresh_differ = 0;
	pack_close(&pk);
	unlink(meta);
	if (pack_open_with(&pk, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) < 0)
		fail("reopening the pack without its sidecar: %s", err);
	else {
		if (pk.meta_state != PACK_META_ABSENT)
			fail("reopened with the sidecar deleted, the state is %d, not ABSENT", (int)pk.meta_state);
		if (pk.n_headers || pk.n_dcks)
			fail("the tables are not empty after the sidecar was deleted");
		for (size_t i = 0; i < n_blocks; ++i) {
			const struct blk *s = &blocks[i];
			if (!s->touched)
				continue;
			uint32_t want[PACK_RECORD_WORDS], got[PACK_RECORD_WORDS], shadow_w[PACK_RECORD_WORDS];
			format_words(s->lba, s->data, want);
			shadow_expect(s, shadow_w);
			if (pack_record(&pk, s->lba, got, err, sizeof err) < 0)
				fail("%s", err);
			else if (memcmp(got, want, sizeof got) != 0)
				fail("without a sidecar block %x's record is not the format's own", s->lba);
			if (memcmp(want, shadow_w, sizeof want) != 0)
				++fresh_differ;
		}
		if (fresh_differ == 0)
			fail("deleting the sidecar changed no record: the test is vacuous");
		if (file_exists(meta))
			fail("reopening recreated the sidecar before any write-back");
		// The first write-back rebuilds it, with that block's entry.
		const uint32_t L = 0x4000u;
		uint32_t w[PACK_RECORD_WORDS];
		struct blk *s = shadow(L, 0);
		shadow_expect(s, w);	// the laid words, written back again
		if (pack_writeback(&pk, L, w, err, sizeof err) < 0)
			fail("the write-back that rebuilds the sidecar: %s", err);
		if (!file_exists(meta))
			fail("the first write-back did not create the sidecar");
		else {
			int fd = open(meta, O_RDONLY);
			uint8_t hdr[PACK_META_HEADER_BYTES], entry[PACK_META_ENTRY_BYTES];
			struct stat st;
			fstat(fd, &st);
			if ((uint64_t)st.st_size != pack_meta_bytes(G))
				fail("the rebuilt sidecar is %lld bytes", (long long)st.st_size);
			if (pread(fd, hdr, sizeof hdr, 0) != (ssize_t)sizeof hdr || memcmp(hdr, PACK_META_MAGIC, 8) != 0)
				fail("the rebuilt sidecar does not begin with %s", PACK_META_MAGIC);
			if (pread(fd, entry, sizeof entry, PACK_META_HEADER_BYTES + (off_t)L * PACK_META_ENTRY_BYTES) != (ssize_t)sizeof entry)
				fail("reading block %x's entry of the rebuilt sidecar", L);
			else {
				const uint32_t flags = (uint32_t)entry[12] | (uint32_t)entry[13] << 8 | (uint32_t)entry[14] << 16 | (uint32_t)entry[15] << 24;
				const uint32_t eh = (uint32_t)entry[0] | (uint32_t)entry[1] << 8 | (uint32_t)entry[2] << 16 | (uint32_t)entry[3] << 24;
				if (flags != (PACK_META_HEADER_LAID | PACK_META_DCK_LAID))
					fail("block %x's entry has flags 0x%x, wanting both laid", L, flags);
				if (eh != w[256])
					fail("block %x's entry carries header 0x%08x, wanting 0x%08x", L, eh, w[256]);
			}
			// And the entry of a block written as the format lays it is
			// all zero.
			if (pread(fd, entry, sizeof entry, PACK_META_HEADER_BYTES + (off_t)0x1000u * PACK_META_ENTRY_BYTES) == (ssize_t)sizeof entry) {
				int nz = 0;
				for (size_t i = 0; i < sizeof entry; ++i) nz |= entry[i];
				if (nz)
					fail("block 1000's entry is not zero in a rebuilt sidecar it was never laid into");
			}
			close(fd);
		}
		// Reopened, only that block carries its laid words.
		pack_close(&pk);
		if (pack_open_with(&pk, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) < 0)
			fail("reopening after the rebuild: %s", err);
		else if (pk.meta_headers_read != 1 || pk.meta_dcks_read != 1)
			fail("the rebuilt sidecar read back %zu headers and %zu checkwords, wanting 1 and 1", pk.meta_headers_read, pk.meta_dcks_read);
	}
	// Corrupted: refused, both files named; replaced only when asked.
	unsigned long refused_sidecars = 0;
	{
		pack_close(&pk);
		// The version.
		int fd = open(meta, O_RDWR);
		uint8_t v2[4] = { 2, 0, 0, 0 };
		if (fd < 0 || pwrite(fd, v2, 4, 8) != 4)
			fail("corrupting the sidecar's version");
		close(fd);
		struct pack w;
		if (pack_open_with(&w, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) == 0) {
			fail("a sidecar of version 2 was accepted");
			pack_close(&w);
		} else {
			if (!strstr(err, "version") || !strstr(err, meta) || !strstr(err, path))
				fail("the version mismatch was reported as '%s'", err);
			else
				++refused_sidecars;
		}
		// Asked to, the open replaces it: fresh tables, and the file is
		// rewritten from zeros at the first write-back.
		if (pack_open_with(&w, path, meta, PACK_OPEN_WRITABLE | PACK_OPEN_REPLACE_META, err, sizeof err) < 0)
			fail("replacing a mismatched sidecar: %s", err);
		else {
			if (w.meta_state != PACK_META_REPLACED)
				fail("asked to replace, the state is %d, not REPLACED", (int)w.meta_state);
			if (w.n_headers || w.n_dcks)
				fail("a replaced sidecar left entries in the tables");
			uint32_t data[PACK_BLOCK_WORDS], words[PACK_RECORD_WORDS];
			for (int j = 0; j < PACK_BLOCK_WORDS; ++j) data[j] = synth(0x1007u, j, 0x88u);
			format_words(0x1007u, data, words);
			if (pack_writeback(&w, 0x1007u, words, err, sizeof err) < 0)
				fail("the write-back after a replacement: %s", err);
			pack_close(&w);
			fd = open(meta, O_RDONLY);
			uint8_t hdr[PACK_META_HEADER_BYTES], entry[PACK_META_ENTRY_BYTES];
			if (pread(fd, hdr, sizeof hdr, 0) != (ssize_t)sizeof hdr || hdr[8] != 1)
				fail("the replaced sidecar does not carry version 1");
			// Block 0x4000's laid entry from before the replacement is gone.
			if (pread(fd, entry, sizeof entry, PACK_META_HEADER_BYTES + (off_t)0x4000u * PACK_META_ENTRY_BYTES) == (ssize_t)sizeof entry) {
				int nz = 0;
				for (size_t i = 0; i < sizeof entry; ++i) nz |= entry[i];
				if (nz)
					fail("the replaced sidecar still carries the old entry of block 4000");
			}
			close(fd);
		}
		// The size.
		if (truncate(meta, (off_t)pack_meta_bytes(G) - 16) < 0)
			fail("truncating the sidecar");
		if (pack_open_with(&w, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) == 0) {
			fail("a sidecar 16 bytes short was accepted");
			pack_close(&w);
		} else if (!strstr(err, "bytes") || !strstr(err, meta))
			fail("the size mismatch was reported as '%s'", err);
		else
			++refused_sidecars;
		if (truncate(meta, (off_t)pack_meta_bytes(G)) < 0)
			fail("restoring the sidecar's size");
		// A pack newer than its sidecar.
		{
			struct stat st;
			stat(meta, &st);
			struct timeval tv[2];
			tv[0].tv_sec = st.st_mtime + 10; tv[0].tv_usec = 0;
			tv[1] = tv[0];
			if (utimes(path, tv) < 0)
				fail("touching the pack newer than its sidecar");
		}
		if (pack_open_with(&w, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) == 0) {
			fail("a pack newer than its sidecar was accepted");
			pack_close(&w);
		} else if (!strstr(err, "newer") || !strstr(err, meta) || !strstr(err, path))
			fail("the newer pack was reported as '%s'", err);
		else
			++refused_sidecars;
		// Touched back, it opens.
		{
			struct timeval tv[2];
			gettimeofday(&tv[0], NULL);
			tv[0].tv_sec -= 100;
			tv[1] = tv[0];
			if (utimes(path, tv) < 0)
				fail("touching the pack older than its sidecar");
		}
		if (pack_open_with(&w, path, meta, PACK_OPEN_WRITABLE, err, sizeof err) < 0)
			fail("the pack older than its sidecar was refused: %s", err);
		else
			pack_close(&w);
		// No sidecar at all, by request: the tables live for the run.
		if (pack_open_with(&w, path, "", PACK_OPEN_WRITABLE, err, sizeof err) < 0)
			fail("opening without a sidecar: %s", err);
		else {
			if (w.meta_state != PACK_META_NONE)
				fail("asked for no sidecar, the state is %d", (int)w.meta_state);
			pack_close(&w);
		}
	}

	unlink(path);
	unlink(meta);
	free(k.ddr);

	// ---- the totals -------------------------------------------------------------
	if (needs != want_needs)
		fail("%lu NEED rows, the trace's header says %lu", needs, want_needs);
	if (writes != want_writes)
		fail("%lu BLK write rows, the trace's header says %lu", writes, want_writes);
	if (needs == 0 || writes == 0)
		fail("a trace with nothing to serve tests nothing");
	if (trace_requests == 0 || trace_answered != trace_requests)
		fail("the trace posted %lu requests and %lu were answered", trace_requests, trace_answered);
	if (k.requests != k.answered + k.denied_ok)
		fail("%lu requests, %lu answered and %lu denied", k.requests, k.answered, k.denied_ok);
	if (k.denied_wrong)
		fail("%lu requests denied that the script expected served", k.denied_wrong);
	if (k.second_chance_runs != k.answered)
		fail("%lu second-chance runs checked for %lu answered requests", k.second_chance_runs, k.answered);
	if (k.full_circles == 0)
		fail("the hand never went round the whole store");
	if (k.evict_writebacks == 0)
		fail("no dirty slot was ever written back on the way to being fetched into");
	if (f.denied != k.denied_ok)
		fail("the feeder counts %lu denials, the face saw %lu", f.denied, k.denied_ok);
	if (f.served != k.answered)
		fail("the feeder counts %lu served, the face saw %lu answered", f.served, k.answered);
	if (ps.polls == 0)
		fail("the driver never polled a busy face");

	if (bad) {
		fprintf(stderr, "FAIL: %d mismatches\n", bad);
		return 1;
	}
	printf("ok: the pack feeder serves the disk controller on demand and keeps\n"
	       "    the pack, its headers and its checkwords across a restart\n"
	       "    %lu requests posted by the modelled controller --- %lu from the\n"
	       "      trace's %lu NEED rows in %lu transfers --- %lu answered within\n"
	       "      %ld poll(s) each, %lu denied (other unit, off the pack);\n"
	       "      %lu hits compared, %lu words, every record 128-byte aligned\n"
	       "      in the spare region\n"
	       "    second chance over REF on every fetch, %lu times round the whole\n"
	       "      store; the walk's slot refused %lu time(s) and passed; %lu dirty\n"
	       "      slot(s) written back on the way to being fetched into; every\n"
	       "      dirty slot back within %ld poll(s) of the walk leaving it\n"
	       "    %lu blocks touched, %lu bytes of the pack file equal to what the\n"
	       "      scripted writes imply, %lu Writes from the trace and %lu from the\n"
	       "      sweep; %lu load rows' checkwords agree with muir's Ecc, %lu laid\n"
	       "    the sidecar: %lu blocks' laid headers and checkwords back across a\n"
	       "      restart; deleted, %lu records fell back to the format's own and\n"
	       "      the file was rebuilt on the first write-back; %lu mismatched\n"
	       "      sidecars refused and named, one replaced on request\n"
	       "    %lu refusals seen and named; a move that moved nothing seen by\n"
	       "      its poison; %lu polls of a busy face, %lu passes over the face\n",
	       k.requests, trace_requests, needs, transfers, k.answered, k.worst_answer, k.denied_ok,
	       k.hits_compared, k.words_compared,
	       k.full_circles, walk_case_refusals, k.evict_writebacks, k.worst_dirty,
	       touched, compared_final, writes, sweep_writes, ecc_checked, lays,
	       sidecar_blocks_compared, fresh_differ, refused_sidecars,
	       refusals, ps.polls, polls_run);
	(void)loads;
	(void)sweep_reads;
	return 0;
}
