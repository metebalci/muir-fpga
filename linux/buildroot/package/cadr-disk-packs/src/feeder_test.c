// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk pack program, held on the build host to a fabric that ASKS: no board,
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
// checkwords (so a restart has something to forget); and one address on
// two units.  The trace's pack sits on unit 2 throughout, so the unit field
// of every tag is live and a request on unit 0 is the other-unit case.
//
// AND THE DRIVE BAY, which is a real directory of real files under the work
// directory --- there is no model of a filesystem here, because a rename
// and a delete are exactly what has to be exercised.  A SECOND drive, a
// T-80 where the trace's is a T-300, is copied into the bay on unit 5 and
// then: served alongside unit 2, block for block out of its own pack with
// its own geometry; RENAMED away with blocks the machine had written still
// in the store, where the flush must land in the file under its new name;
// DELETED with blocks in the store, where the flush cannot land anywhere
// and the loss must be said, with the unit and the count, on the console
// this test reads back; write-protected and unprotected by its read-only
// mark alone; overwritten in place, where flushing would corrupt the copy
// arriving and must not be attempted; and changed while the channel is
// walking, where nothing may move at all.  A file of the wrong size is not
// a drive, which is what makes a pack still being copied in not one.
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
// imply; and after a restart the tables are the format's again --- a laid
// header or checkword is forgotten, as muir's `Unit` forgets it, and the
// data stands.
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
#include <sys/types.h>
#include <unistd.h>

#include "pack_bay.h"
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

// The unit the trace's pack is on for this run: not zero, so the tag's unit
// field is live in every fetch.  UNIT2 is the drive bay's second drive, a
// T-80 against the trace's T-300, so that a geometry taken from the wrong
// drive reads wrong.
#define UNIT 2u
#define UNIT2 5u
#define ALL_SLOTS ((1u << PS_SLOTS) - 1u)
// How many polls a request may stand before it is answered, and a dirty
// slot before it is written back when the walk is not on it.
#define ANSWER_BOUND 2
#define DIRTY_BOUND 3
// How many polls a transfer may take from START to idle.
#define TRANSFER_BOUND 64

static const struct pack_geometry *G = &PACK_T300;
// Which geometry a unit's pack has.  Two drives of two types is what says
// nothing here reads one drive's geometry off the other.
static const struct pack_geometry *geom(unsigned unit)
{
	return unit == UNIT2 ? &PACK_T80 : &PACK_T300;
}

// ------------------------------------------------------- the shadow pack
// What the scripted writes imply the pack holds: the data, and whether the
// header and data checkword are laid or the format's own.  A second
// expression of muir's `write_sector_at` rule, kept apart from
// pack_file.c's so that a mutation there is caught here.
struct blk {
	unsigned unit;
	uint32_t lba;
	uint32_t data[PACK_BLOCK_WORDS];
	uint32_t hdr, hck, dck;
	int hdr_laid, dck_laid;
	int touched;		// ever read or written by the script
	int gone;		// its drive left the bay: not compared at the end
};
static struct blk blocks[256];
static size_t n_blocks;

static struct blk *shadow(unsigned unit, uint32_t lba, int make)
{
	for (size_t i = 0; i < n_blocks; ++i)
		if (blocks[i].lba == lba && blocks[i].unit == unit)
			return &blocks[i];
	if (!make)
		return NULL;
	if (n_blocks == sizeof blocks / sizeof blocks[0]) {
		fail("more distinct blocks than this test holds");
		exit(2);
	}
	memset(&blocks[n_blocks], 0, sizeof blocks[0]);
	blocks[n_blocks].unit = unit;
	blocks[n_blocks].lba = lba;
	return &blocks[n_blocks++];
}

static void shadow_expect(const struct blk *s, uint32_t w[PACK_RECORD_WORDS])
{
	const struct pack_geometry *g = geom(s->unit);
	memcpy(w, s->data, sizeof s->data);
	uint32_t c, h, b;
	pack_chb(g, s->lba, &c, &h, &b);
	if (s->hdr_laid) {
		w[256] = s->hdr;
		w[257] = s->hck;
	} else {
		w[256] = pack_header_of(g, c, h, b);
		w[257] = ecc_over_words(&w[256], 1);
	}
	w[258] = s->dck_laid ? s->dck : ecc_over_words(w, PACK_BLOCK_WORDS);
}

static void shadow_writeback(struct blk *s, const uint32_t w[PACK_RECORD_WORDS])
{
	const struct pack_geometry *g = geom(s->unit);
	memcpy(s->data, w, sizeof s->data);
	uint32_t c, h, b;
	pack_chb(g, s->lba, &c, &h, &b);
	const uint32_t own = pack_header_of(g, c, h, b);
	s->hdr_laid = !(w[256] == own && w[257] == ecc_over_words(&own, 1));
	s->hdr = w[256];
	s->hck = w[257];
	s->dck_laid = (w[258] != ecc_over_words(w, PACK_BLOCK_WORDS));
	s->dck = w[258];
}

// The format's own three words for a block.
static void format_words(unsigned unit, uint32_t lba, const uint32_t data[PACK_BLOCK_WORDS], uint32_t w[PACK_RECORD_WORDS])
{
	const struct pack_geometry *g = geom(unit);
	uint32_t c, h, b;
	pack_chb(g, lba, &c, &h, &b);
	memcpy(w, data, PACK_BLOCK_BYTES);
	w[256] = pack_header_of(g, c, h, b);
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
	// The DRIVE register as the fabric would take it: the seam, and the
	// attention field (bits 24:17) which is a PULSE --- what is written
	// with it, and what stands in the last word written.
	uint32_t drive_attention, drive_att_standing;
	unsigned long drive_writes;
	// A slot taken away while DIRTY is the CADR's write lost, and is a
	// fault --- except where the script has just made a pack vanish with
	// blocks still in the store, which is the one case where the loss is
	// the honest outcome and must be reported rather than avoided.
	int allow_dirty_take;
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
	} queue[160];
	int q_head, q_tail;
	// T_START is the command-list fetch between a START and the first
	// lookup: the channel active, waiting on nothing, and `ch_slot` still
	// naming the slot the previous transfer was on --- the RTL sets it at a
	// hit and nowhere else (`rtl/cadr_disk_controller.sv`, `C_LOOK`).
	enum { T_IDLE, T_START, T_LOOK, T_WAIT, T_MOVE } tstate;
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
	unsigned long start_refusals;	// refused in the command-list fetch, on the previous transfer's slot
	int last_move_was_writeback_of;		// slot, or -1
	// Write-backs to verify against the pack file after the poll.
	struct { unsigned slot, unit; uint32_t lba; uint32_t words[PACK_RECORD_WORDS]; } pending_wb[32];
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
	if (pack_lba(geom(*unit), c, h, b, &lba) < 0)
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

static void walk_runs_on(struct fake *k);
static void fake_write_at_beat(struct pack_side *ps, unsigned reg, uint32_t v);
// The beat is acted on with the state at the beat; then the fabric runs on
// before Linux reads anything back.
static void fake_write(struct pack_side *ps, unsigned reg, uint32_t v)
{
	fake_write_at_beat(ps, reg, v);
	if (reg == PS_CTL)
		walk_runs_on(ps->ctx);
}
static void fake_write_at_beat(struct pack_side *ps, unsigned reg, uint32_t v)
{
	struct fake *k = ps->ctx;
	switch (reg) {
	case PS_ADDR: k->regs[reg] = v; return;
	case PS_TAG: k->regs[reg] = v & PS_TAG_MASK; return;
	case PS_SLOT: k->regs[reg] = v & 0x1Fu; return;
	case PS_DRIVE:
		k->regs[reg] = v & 0x1FFFFu;
		k->drive_att_standing = (v >> PS_DRIVE_ATTENTION_SHIFT) & 0xFFu;
		k->drive_attention |= k->drive_att_standing;
		++k->drive_writes;
		return;
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
			if (k->tstate == T_START)
				++k->start_refusals;
		}
		return;
	}
	k->done = 0;
	k->error = 0;
	k->busy_left = k->busy_polls;
	k->last_addr = addr;
	if (go == PS_CTL_TAKE) {
		if ((k->dirty & (1u << slot)) && !k->starting && !k->allow_dirty_take)
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
					k->pending_wb[k->n_pending_wb].unit = unit;
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
	struct blk *sh = shadow(unit, lba, 0);
	if (!sh) {
		fail("the walk hit block %x of unit %u, which the script never put on that pack", lba, unit);
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
				k->tstate = T_START;
			}
			break;
		case T_START:
			k->tstate = T_LOOK;
			again = 1;
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

// Between a CTL beat and Linux's read of the status --- a GP0 round trip,
// tens of ticks --- the fabric runs on: a walk in its command-list fetch
// reaches its lookup, and waits if the block is absent.  So a refusal
// decided with the walk between transfers is read back with WAITING up,
// which is the board's `status 0x5a` at 13:48:13.
static void walk_runs_on(struct fake *k)
{
	if (k->tstate != T_START)
		return;
	struct xfer *x = &k->queue[k->q_head];
	const uint32_t tag = x->tag[k->t_idx];
	const int s = find_slot(k, tag);
	if (s >= 0) {
		hit(k, x, s);
	} else {
		if (!(k->req_valid && k->req_tag == tag))
			post(k, tag);
		k->waiting = 1;
		k->tstate = T_WAIT;
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
	pack_chb(geom(x->unit), lba, &c, &h, &b);
	xfer_block(x, c, h, b);
}

// ---- the run loop ------------------------------------------------------
static struct bay bay;
static struct feeder f;
static struct fake k;
static struct pack_side ps;
static unsigned long polls_run;

static void verify_pending_writebacks(void)
{
	for (int i = 0; i < k.n_pending_wb; ++i) {
		const uint32_t lba = k.pending_wb[i].lba;
		const unsigned unit = k.pending_wb[i].unit;
		const uint32_t *w = k.pending_wb[i].words;
		struct pack *pkp = bay_pack(&bay, unit);
		uint8_t file_bytes[PACK_BLOCK_BYTES], want_bytes[PACK_BLOCK_BYTES];
		if (!pkp) {
			fail("block %x was written back on unit %u, which has no pack in the bay", lba, unit);
			continue;
		}
		if (pread(pkp->fd, file_bytes, sizeof file_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof file_bytes) {
			fail("reading block %x of unit %u's pack file after a write-back", lba, unit);
			continue;
		}
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			for (int q = 0; q < 4; ++q)
				want_bytes[4 * j + q] = (uint8_t)(w[j] >> (8 * q));
		if (memcmp(file_bytes, want_bytes, sizeof file_bytes) != 0)
			fail("block %x in unit %u's pack file differs from what the CADR wrote into slot %u",
			     lba, unit, k.pending_wb[i].slot);
		uint32_t again[PACK_RECORD_WORDS];
		char err[256];
		if (pack_record(pkp, lba, again, err, sizeof err) < 0)
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

// The model stepped WITHOUT the feeder polling, so that a slot the CADR has
// just written is still DIRTY when the drive bay is looked at.  That state
// --- blocks the machine has given this program and this program has not yet
// put back --- is what the whole rename-against-delete distinction is about,
// and `run()` would flush it away before the bay was ever looked at.
static void run_to_dirty(void)
{
	for (int n = 0; n < 64; ++n) {
		model_step(&k);
		if (k.tstate == T_IDLE && k.q_head >= k.q_tail && k.dirty)
			return;
	}
	fail("the scripted Write left nothing dirty with the walk idle");
}

// One look at the bay: 0 it ran, 1 the channel was walking.
static int scan(void)
{
	char err[256];
	const int r = feeder_bay_scan(&f, err, sizeof err);
	if (r < 0)
		fail("feeder_bay_scan: %s", err);
	return r;
}

// A page of synthetic words for a Write on a unit, and the same page as the
// bytes the pack file must then carry.
static void page_of(unsigned unit, uint32_t lba, uint32_t salt, uint32_t page[PACK_BLOCK_WORDS])
{
	for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
		page[j] = synth(lba + unit * 0x10000u, j, salt);
}

// Block `lba` of `unit` made resident and then written by the CADR, left
// DIRTY with the walk idle.  Returns the page written.
static void write_and_leave_dirty(unsigned unit, uint32_t lba, uint32_t salt, uint32_t page[PACK_BLOCK_WORDS])
{
	struct xfer *x = enqueue(&k, unit, 0);
	xfer_lba(x, lba);
	run();
	x = enqueue(&k, unit, 1);
	xfer_lba(x, lba);
	page_of(unit, lba, salt, page);
	memcpy(x->page[0], page, PACK_BLOCK_BYTES);
	run_to_dirty();
	if (!k.dirty)
		fail("unit %u block %x was written and no slot is dirty", unit, lba);
}

// What a pack file must carry at a block, read by name and not through
// anything this program holds open.
static void file_block_is(const char *path, unsigned lba, const uint32_t page[PACK_BLOCK_WORDS], const char *what)
{
	uint8_t got[PACK_BLOCK_BYTES], want[PACK_BLOCK_BYTES];
	for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
		for (int q = 0; q < 4; ++q)
			want[4 * j + q] = (uint8_t)(page[j] >> (8 * q));
	const int fd = open(path, O_RDONLY);
	if (fd < 0) {
		fail("%s: %s: %s", what, path, strerror(errno));
		return;
	}
	if (pread(fd, got, sizeof got, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof got)
		fail("%s: reading block %x of %s", what, lba, path);
	else if (memcmp(got, want, sizeof got) != 0)
		fail("%s: block %x of %s is not what the machine wrote", what, lba, path);
	close(fd);
}

static void lay(unsigned unit, uint32_t lba, const uint32_t w[PACK_RECORD_WORDS])
{
	char err[256];
	struct blk *s = shadow(unit, lba, 1);
	// A formatter laid the sector behind the store: a copy in the store is
	// stale and Linux takes it away, writing it back first if the CADR's
	// write is in it --- the trace's LAY rows are the fabric's stimulus and
	// the testbench fetches them afresh; here the feeder is asked to.
	{
		uint32_t c, h, b;
		pack_chb(geom(unit), lba, &c, &h, &b);
		const int sl = find_slot(&k, ps_tag(unit, c, h, b));
		if (sl >= 0) {
			if ((k.dirty & (1u << sl)) && feeder_writeback(&f, (unsigned)sl, err, sizeof err) != 0)
				fail("writing slot %d back before a lay: %s", sl, err);
			if (feeder_take(&f, (unsigned)sl, err, sizeof err) != 0)
				fail("taking slot %d away before a lay: %s", sl, err);
		}
	}
	struct pack *pkp = bay_pack(&bay, unit);
	if (!pkp)
		fail("laying block %x on unit %u, which has no pack in the bay", lba, unit);
	else if (pack_writeback(pkp, lba, w, err, sizeof err) < 0)
		fail("laying block %x: %s", lba, err);
	shadow_writeback(s, w);
}

// A synthetic block laid as the format lays it.
static void lay_synth(unsigned unit, uint32_t lba, uint32_t salt)
{
	uint32_t data[PACK_BLOCK_WORDS], w[PACK_RECORD_WORDS];
	for (int i = 0; i < PACK_BLOCK_WORDS; ++i)
		data[i] = synth(lba + unit * 0x10000u, i, salt);
	format_words(unit, lba, data, w);
	lay(unit, lba, w);
}

static uint32_t hex(const char *s)
{
	return (uint32_t)strtoul(s, NULL, 16);
}

// A pack file of a geometry's size, sparse, fresh.
static int make_pack(const char *path, const struct pack_geometry *g)
{
	unlink(path);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0 || ftruncate(fd, (off_t)pack_size_of(g)) < 0) {
		fprintf(stderr, "feeder_test: %s: %s\n", path, strerror(errno));
		if (fd >= 0)
			close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

// The console the program wrote, since `mark`: what a line has to be found
// in.  A count that names nothing is not a report, and neither is a check
// that only counts.
static FILE *console;
static char logpath[4096];
static long console_mark(void)
{
	fflush(console);
	return ftell(console);
}
static int console_says(long mark, const char *needle)
{
	fflush(console);
	const long end = ftell(console);
	if (end <= mark)
		return 0;
	char *buf = malloc((size_t)(end - mark) + 1);
	if (!buf)
		return 0;
	fseek(console, mark, SEEK_SET);
	const size_t n = fread(buf, 1, (size_t)(end - mark), console);
	buf[n] = 0;
	const int found = strstr(buf, needle) != NULL;
	free(buf);
	fseek(console, 0, SEEK_END);
	return found;
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

	// The drive bay: a real directory of real files, because a rename and
	// a delete are what has to be exercised and there is no modelling
	// those.  The trace's pack goes in as unit 2's, at a T-300's size,
	// sparse and fresh for this run.
	char bay_dir[4000], path[4096];
	snprintf(bay_dir, sizeof bay_dir, "%s/packs", argv[2]);
	{
		char cmd[4200];
		snprintf(cmd, sizeof cmd, "rm -rf '%s'", bay_dir);
		if (system(cmd) != 0)
			fail("clearing %s", bay_dir);
	}
	if (mkdir(bay_dir, 0755) < 0 && errno != EEXIST) {
		fprintf(stderr, "feeder_test: %s: %s\n", bay_dir, strerror(errno));
		return 2;
	}
	bay_init(&bay, bay_dir);
	bay_path(&bay, UNIT, path, sizeof path);
	if (make_pack(path, &PACK_T300) < 0)
		return 2;
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
		if (pack_open(&w, wrong, 0, err, sizeof err) == 0) {
			fail("a file of 1,234,567 bytes was opened as a pack");
			pack_close(&w);
		}
		struct pack_geometry g;
		if (pack_geometry_of_size(1234567, &g) == 0)
			fail("1,234,567 bytes was taken for a geometry");
		if (pack_geometry_of_size(pack_size_of(&PACK_T80), &g) < 0 || g.heads != 5)
			fail("a T-80's size was not taken for a T-80");
		if (pack_geometry_of_size(pack_size_of(&PACK_T300), &g) < 0 || g.heads != 19)
			fail("a T-300's size was not taken for a T-300");
		unlink(wrong);
	}

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
	// The console this program writes, read back: a loss that is not said
	// is a loss pretended away, and only the text says it was said.
	snprintf(logpath, sizeof logpath, "%s/console.log", argv[2]);
	unlink(logpath);
	console = fopen(logpath, "w+");
	if (!console) {
		fprintf(stderr, "feeder_test: %s: %s\n", logpath, strerror(errno));
		return 2;
	}
	if (feeder_init(&f, &bay, &ps, k.ddr, k.ddr_phys, k.ddr_bytes, console) < 0) {
		fail("feeder_init");
		return 1;
	}
	every_fetch_address_checked();
	k.starting = 1;
	if (feeder_start(&f, 0, err, sizeof err) < 0)
		fail("feeder_start: %s", err);
	k.starting = 0;
	if (!bay_pack(&bay, UNIT))
		fail("the trace's pack in the bay did not come present at the start");
	else if (bay_pack(&bay, UNIT)->g.heads != 19)
		fail("a file of a T-300's size was taken for %u heads", bay_pack(&bay, UNIT)->g.heads);
	if (f.appeared != 1)
		fail("%lu drives appeared at the start, wanting 1", f.appeared);
	if (k.drive_attention != (1u << UNIT))
		fail("the attention field was 0x%02x when the drive came present, wanting 0x%02x",
		     k.drive_attention, 1u << UNIT);
	if (k.drive_att_standing)
		fail("the attention field stands at 0x%02x after the drive came present: it must be a pulse",
		     k.drive_att_standing);
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
			if (pack_lba(G, c, h, b, &lba2) < 0 || lba2 != lba)
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
				struct blk *s = shadow(UNIT, lba, 0);
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
					if (words[256] != pack_header_of(G, c, h, b))
						fail("line %ld: header_of(%u,%u,%u) is 0x%08x here, 0x%08x in muir", lineno, c, h, b, pack_header_of(G, c, h, b), words[256]);
				} else {
					++lays;
				}
				lay(UNIT, lba, words);
			}
		} else if (strcmp(kind, "NEED") == 0) {
			const uint32_t lba = hex(strtok_r(NULL, " ", &save));
			const uint32_t c = hex(strtok_r(NULL, " ", &save));
			const uint32_t h = hex(strtok_r(NULL, " ", &save));
			const uint32_t b = hex(strtok_r(NULL, " ", &save));
			++needs;
			if (!shadow(UNIT, lba, 0)) {
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
			lay_synth(UNIT, lbas[i], 0x11u);
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
					x->page[0][j] = synth(lbas[i - 2] + UNIT * 0x10000u, j, 0x22u + (uint32_t)i);
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
		lay_synth(UNIT, A, 0x33u);
		lay_synth(UNIT, C, 0x33u);
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
				x->page[0][j] = synth(A + UNIT * 0x10000u, j, 0x44u);
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
	// The board's fault of 13:48:13 (a899799 bitstream): a Write of block A
	// ends and the CADR STARTs a Read of an absent block at once.  The
	// feeder's write-back of A's slot lands in the command-list fetch,
	// where the channel is active, not waiting, and `ch_slot` still names
	// A's slot: refused as the walk's.  By the time the status is read the
	// walk has looked its block up, missed and is WAITING --- status
	// WAITING | CH_ACTIVE | REFUSED | DONE, 0x5a.  The feeder must take
	// that as the walk's slot and write A back on a later pass, not fail.
	unsigned long start_refusals = 0;
	{
		const uint32_t A = 0x2100u, B = 0x2101u;
		lay_synth(UNIT, A, 0x99u);
		lay_synth(UNIT, B, 0x99u);
		struct xfer *x = enqueue(&k, UNIT, 0);
		xfer_lba(x, A);
		run();
		x = enqueue(&k, UNIT, 1);
		xfer_lba(x, A);
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			x->page[0][j] = synth(A + UNIT * 0x10000u, j, 0xAAu);
		x = enqueue(&k, UNIT, 0);
		xfer_lba(x, B);
		const unsigned long r0 = k.start_refusals, f0 = f.failures;
		run();
		start_refusals = k.start_refusals - r0;
		if (start_refusals == 0)
			fail("the write-back of the slot the previous transfer wrote never met the next START");
		if (f.failures != f0)
			fail("the feeder counted a failure on a refusal read back with WAITING up");
		if (k.dirty)
			fail("A's slot is still dirty after the START's refusal: DIRTY 0x%06x", k.dirty);
	}
	// The walk's slot: a chained Read whose first block sits in the one
	// slot with REF down, and whose second block is absent.  The prefetch
	// is posted while the walk is on that slot; the hand must be refused
	// there and take the next.
	unsigned long walk_case_refusals = 0;
	{
		const uint32_t X1 = 0x3000u, X2 = 0x3001u, Y = 0x3002u;
		lay_synth(UNIT, X1, 0x55u);
		lay_synth(UNIT, X2, 0x55u);
		lay_synth(UNIT, Y, 0x55u);
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
	// tables carry something a restart forgets.
	unsigned long laid_blocks = 0;
	{
		const uint32_t L = 0x4000u;
		lay_synth(UNIT, L, 0x66u);
		struct xfer *x = enqueue(&k, UNIT, 1);
		xfer_lba(x, L);
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			x->page[0][j] = synth(L + UNIT * 0x10000u, j, 0x77u);
		x->laid = 1;
		x->laid_hdr = 0x5A000000u | (L & 0xFFFFu);
		x->laid_hck = ecc_over_words(&x->laid_hdr, 1) ^ 0x00010000u;
		x->laid_dck = ecc_over_words(x->page[0], PACK_BLOCK_WORDS) ^ 0x80000001u;
		run();
		struct blk *s = shadow(UNIT, L, 0);
		if (!s || !s->hdr_laid || !s->dck_laid)
			fail("the Write All did not lay a foreign header and checkword in the shadow");
		// And read back: the laid words come through the store.
		x = enqueue(&k, UNIT, 0);
		xfer_lba(x, L);
		run();
	}


	// ---- the drive bay ----------------------------------------------------
	//
	// A real directory of real files: a rename and a delete are exactly what
	// has to be exercised and there is no modelling those.  Every arm below
	// ends with the store consistent with the bay, because a drive that
	// leaves takes its slots with it.
	unsigned long bay_two_unit_hits = 0, bay_scans_deferred = 0;
	char pack2[4096], taken_out[4096];
	bay_path(&bay, UNIT2, pack2, sizeof pack2);
	snprintf(taken_out, sizeof taken_out, "%s/taken-out.img", bay_dir);
	{
		// A unit with no file in the bay is a cable with nothing on it, and
		// a request on it is DENIED exactly as one on unit 0 was.
		struct xfer *x = enqueue(&k, UNIT2, 0);
		xfer_block(x, 0, 0, 0);
		x->expect_deny = 1;
		++denials_expected;
		const unsigned long d0 = k.denied_ok;
		run();
		if (k.denied_ok != d0 + 1)
			fail("a request on unit %u, which has no file in the bay, was not denied", UNIT2);
		k.miss = 0;
	}
	{
		// A FILE OF THE WRONG SIZE IS NOT A DRIVE.  This is what makes a
		// pack still being copied in not one: every intermediate size is
		// the wrong size, and the drive appears when the last byte lands.
		const int fd = open(pack2, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0 || ftruncate(fd, 4096) < 0)
			fail("making a short file in the bay");
		if (fd >= 0)
			close(fd);
		const unsigned long w0 = k.drive_writes;
		scan();
		if (bay_pack(&bay, UNIT2))
			fail("a file of 4,096 bytes in the bay became unit %u's drive", UNIT2);
		if (k.regs[PS_DRIVE] & (1u << UNIT2))
			fail("DRIVE says unit %u is present with only a short file there", UNIT2);
		if (k.drive_writes != w0)
			fail("DRIVE was written by a scan that changed nothing");
	}
	{
		// The copy finishes: a T-80 where the trace's drive is a T-300, so
		// a geometry read off the wrong drive reads wrong.
		if (make_pack(pack2, &PACK_T80) < 0)
			return 2;
		k.drive_attention = 0;
		scan();
		const struct pack *p2 = bay_pack(&bay, UNIT2);
		if (!p2)
			fail("a T-80 in the bay did not become unit %u's drive", UNIT2);
		else if (p2->g.heads != 5 || p2->blocks != 815u * 5u * 17u)
			fail("unit %u's pack was taken for %u heads and %u blocks, wanting a T-80's 5 and 69275",
			     UNIT2, p2->g.heads, p2->blocks);
		if (!(k.regs[PS_DRIVE] & (1u << UNIT2)))
			fail("DRIVE does not say unit %u is present", UNIT2);
		if (k.regs[PS_DRIVE] & (1u << (UNIT2 + 8)))
			fail("unit %u came present write-protected with its write bits up", UNIT2);
		if (k.drive_attention != (1u << UNIT2))
			fail("the attention field was 0x%02x when unit %u's pack was loaded, wanting 0x%02x",
			     k.drive_attention, UNIT2, 1u << UNIT2);
		if (k.drive_att_standing)
			fail("the attention field stands at 0x%02x: it must be a pulse", k.drive_att_standing);
	}
	{
		// TWO UNITS SERVING TWO PACKS AT ONCE, under the same block number,
		// each block out of its own file with its own geometry.
		const uint32_t P = 0x900u;
		lay_synth(UNIT, P, 0xB1u);
		lay_synth(UNIT2, P, 0xB2u);
		lay_synth(UNIT2, P + 1u, 0xB2u);
		struct xfer *x = enqueue(&k, UNIT, 0);
		xfer_lba(x, P);
		x = enqueue(&k, UNIT2, 0);
		xfer_lba(x, P);
		x = enqueue(&k, UNIT, 0);
		xfer_lba(x, P);
		x = enqueue(&k, UNIT2, 0);
		xfer_lba(x, P + 1u);
		const unsigned long h0 = k.hits_compared;
		run();
		bay_two_unit_hits = k.hits_compared - h0;
		if (bay_two_unit_hits < 4)
			fail("%lu hits over two units, wanting at least 4", bay_two_unit_hits);
		uint32_t c, h, b;
		pack_chb(geom(UNIT), P, &c, &h, &b);
		const int s1 = find_slot(&k, ps_tag(UNIT, c, h, b));
		pack_chb(geom(UNIT2), P, &c, &h, &b);
		const int s2 = find_slot(&k, ps_tag(UNIT2, c, h, b));
		if (s1 < 0 || s2 < 0 || s1 == s2)
			fail("block %x of two units did not sit in two slots at once (%d, %d)", P, s1, s2);
	}
	{
		// **NOTHING MOVES IN THE MIDDLE OF A TRANSFER.**  The read-only mark
		// is set with the channel walking: four looks change nothing and say
		// so, and the change lands on the first look with the channel idle.
		k.ch_active = 1;
		k.waiting = 0;
		const unsigned long w0 = k.drive_writes, d0 = f.scans_deferred, sc0 = f.scans;
		if (chmod(pack2, 0444) < 0)
			fail("chmod: %s", strerror(errno));
		for (int n = 0; n < 4; ++n)
			if (scan() != 1)
				fail("the bay was looked at while the channel was walking");
		bay_scans_deferred = f.scans_deferred - d0;
		if (f.scans != sc0)
			fail("a scan ran while the channel was walking");
		if (bay_scans_deferred != 4)
			fail("%lu looks were put off for the transfer, wanting 4", bay_scans_deferred);
		if (k.drive_writes != w0)
			fail("DRIVE was written while the channel was walking");
		if (bay_read_only_mask(&bay) & (1u << UNIT2))
			fail("the write-protect switch flipped in the middle of a transfer");
		if (f.worst_scan_deferral < 4)
			fail("the worst run of deferred looks reads %u, wanting at least 4", f.worst_scan_deferral);
		k.ch_active = 0;
		if (scan() != 0)
			fail("the bay was still not looked at with the channel idle");
		if (!(bay_read_only_mask(&bay) & (1u << UNIT2)))
			fail("the read-only mark did not reach the drive");
		if (!(k.regs[PS_DRIVE] & (1u << (UNIT2 + 8))))
			fail("DRIVE does not say unit %u is write-protected", UNIT2);
		if (f.protects != 1)
			fail("%lu write-protections, wanting 1", f.protects);
		// And the switch reaches the pack itself: a write-back onto it is
		// refused, which is what a write-protected drive is for.
		struct pack *p2 = bay_pack(&bay, UNIT2);
		uint32_t rec[PACK_RECORD_WORDS];
		if (!p2 || pack_record(p2, 0, rec, err, sizeof err) < 0)
			fail("reading a write-protected pack: %s", err);
		else if (pack_writeback(p2, 0, rec, err, sizeof err) == 0)
			fail("a write-back onto a write-protected pack was taken");
	}
	{
		// Unprotected again, and then a block the machine has written left
		// in the store when the mark is set: **the flush comes before the
		// switch**, or the block would be stranded in a store that may no
		// longer write.
		if (chmod(pack2, 0644) < 0)
			fail("chmod: %s", strerror(errno));
		scan();
		if (bay_read_only_mask(&bay) & (1u << UNIT2))
			fail("unit %u is still write-protected after its mark was cleared", UNIT2);
		if (f.unprotects != 1)
			fail("%lu unprotections, wanting 1", f.unprotects);
		const uint32_t Q = 0x901u;
		uint32_t page[PACK_BLOCK_WORDS];
		lay_synth(UNIT2, Q, 0xC0u);
		write_and_leave_dirty(UNIT2, Q, 0xC1u, page);
		const unsigned long fl0 = f.flushed;
		if (chmod(pack2, 0444) < 0)
			fail("chmod: %s", strerror(errno));
		scan();
		if (f.flushed != fl0 + 1)
			fail("%lu block(s) were flushed before the write-protect switch flipped, wanting 1", f.flushed - fl0);
		if (k.dirty)
			fail("a slot is still dirty after the write-protect flush: DIRTY 0x%06x", k.dirty);
		file_block_is(pack2, Q, page, "the flush before a write-protect");
		k.n_pending_wb = 0;
		if (chmod(pack2, 0644) < 0)
			fail("chmod: %s", strerror(errno));
		scan();
	}
	unsigned long bay_flushed_out = 0, bay_lost = 0;
	{
		// **A RENAME TAKES A PACK OUT AND LOSES NOTHING.**  The file stays
		// alive under its new name, this program's descriptor followed it,
		// and the flush lands there --- read back by name, from a descriptor
		// nothing here holds.
		const uint32_t R = 0x902u;
		uint32_t page[PACK_BLOCK_WORDS];
		lay_synth(UNIT2, R, 0xD0u);
		write_and_leave_dirty(UNIT2, R, 0xD1u, page);
		const unsigned long fl0 = f.flushed, lost0 = f.lost_blocks, away0 = f.went_away;
		k.drive_attention = 0;
		const long mark = console_mark();
		if (rename(pack2, taken_out) < 0)
			fail("rename: %s", strerror(errno));
		scan();
		bay_flushed_out = f.flushed - fl0;
		if (f.went_away != away0 + 1)
			fail("the renamed pack did not leave the bay");
		if (bay_flushed_out != 1)
			fail("the renamed pack took %lu block(s) with it, wanting 1", bay_flushed_out);
		if (f.lost_blocks != lost0)
			fail("%lu block(s) were called lost on a RENAME, which loses nothing", f.lost_blocks - lost0);
		if (bay_pack(&bay, UNIT2))
			fail("unit %u still has a pack after its file was renamed away", UNIT2);
		if (k.regs[PS_DRIVE] & (1u << UNIT2))
			fail("DRIVE still says unit %u is present after its file was renamed away", UNIT2);
		if (k.drive_attention != (1u << UNIT2))
			fail("the attention field was 0x%02x when the drive went away, wanting 0x%02x",
			     k.drive_attention, 1u << UNIT2);
		if (k.dirty)
			fail("DIRTY is 0x%06x after the drive went away", k.dirty);
		file_block_is(taken_out, R, page, "the flush into the renamed pack");
		if (!console_says(mark, "flushed onto the pack before it left the bay"))
			fail("the console does not say the blocks were flushed on the way out");
		// **A DRIVE THAT LEAVES TAKES ITS SLOTS WITH IT.**  A block of a pack
		// that is no longer in the bay left in the store is a block the walk
		// would hit and be served out of a drive that is not there.
		for (unsigned sl = 0; sl < PS_SLOTS; ++sl)
			if (k.valid[sl] && ((k.tag[sl] >> 28) & 7u) == UNIT2)
				fail("slot %u still holds a block of unit %u after its pack was renamed out of the bay", sl, UNIT2);
		k.n_pending_wb = 0;
	}
	{
		// **A DELETE LOSES WHAT THE MACHINE HAD WRITTEN, AND THIS PROGRAM
		// SAYS SO.**  The name is put back first so there is a drive again.
		if (rename(taken_out, pack2) < 0)
			fail("rename back: %s", strerror(errno));
		scan();
		if (!bay_pack(&bay, UNIT2))
			fail("the pack renamed back into the bay did not become a drive again");
		const uint32_t S = 0x903u;
		uint32_t page[PACK_BLOCK_WORDS];
		lay_synth(UNIT2, S, 0xE0u);
		write_and_leave_dirty(UNIT2, S, 0xE1u, page);
		const unsigned long lost0 = f.lost_blocks, ev0 = f.lost_events, fl0 = f.flushed;
		const long mark = console_mark();
		// The one place where a slot may be taken away DIRTY: the block has
		// nowhere left to go and the honest thing is to say so.
		k.allow_dirty_take = 1;
		if (unlink(pack2) < 0)
			fail("unlink: %s", strerror(errno));
		scan();
		k.allow_dirty_take = 0;
		bay_lost = f.lost_blocks - lost0;
		if (bay_lost != 1)
			fail("a delete with one block in the store reported %lu lost, wanting 1", bay_lost);
		if (f.lost_events != ev0 + 1)
			fail("%lu loss events, wanting 1", f.lost_events - ev0);
		if (f.flushed != fl0)
			fail("%lu block(s) were 'flushed' into a file that had been deleted", f.flushed - fl0);
		if (bay_pack(&bay, UNIT2))
			fail("unit %u still has a pack after its file was deleted", UNIT2);
		if (k.dirty)
			fail("DIRTY is 0x%06x after the deleted pack's drive went away", k.dirty);
		char want_line[128];
		snprintf(want_line, sizeof want_line, "unit %u: LOST 1 block(s)", UNIT2);
		if (!console_says(mark, want_line))
			fail("the console does not name the unit and the count of the loss ('%s')", want_line);
		snprintf(want_line, sizeof want_line, "The blocks: %u", S);
		if (!console_says(mark, want_line))
			fail("the console does not name the block that was lost ('%s')", want_line);
		if (!console_says(mark, "RENAME a pack"))
			fail("the console does not say what to do instead of deleting");
		for (unsigned sl = 0; sl < PS_SLOTS; ++sl)
			if (k.valid[sl] && ((k.tag[sl] >> 28) & 7u) == UNIT2)
				fail("slot %u still holds a block of unit %u after its pack was deleted", sl, UNIT2);
		k.n_pending_wb = 0;
	}
	{
		// **A PACK OVERWRITTEN WHERE IT LIES IS NOT ONE TO FLUSH INTO.**  The
		// file is alive and its link count says so, but its contents are
		// becoming somebody else's pack, and the old pack's words would
		// corrupt it.  So the blocks are lost and named, not written.
		if (make_pack(pack2, &PACK_T80) < 0)
			return 2;
		scan();
		const uint32_t T = 0x904u;
		uint32_t page[PACK_BLOCK_WORDS];
		lay_synth(UNIT2, T, 0xF0u);
		write_and_leave_dirty(UNIT2, T, 0xF1u, page);
		const unsigned long lost0 = f.lost_blocks, fl0 = f.flushed;
		const int fd = open(pack2, O_RDWR);
		if (fd < 0 || ftruncate(fd, 4096) < 0)
			fail("truncating the pack in place");
		if (fd >= 0)
			close(fd);
		k.allow_dirty_take = 1;
		const long mark = console_mark();
		scan();
		k.allow_dirty_take = 0;
		if (bay_pack(&bay, UNIT2))
			fail("a pack truncated under the drive is still a drive");
		if (f.flushed != fl0)
			fail("%lu block(s) of the old pack were written into a file being written over", f.flushed - fl0);
		if (f.lost_blocks != lost0 + 1)
			fail("%lu block(s) reported lost when a pack was written over, wanting 1", f.lost_blocks - lost0);
		if (!console_says(mark, "written over where it lies"))
			fail("the console does not say the pack was written over where it lies");
		if (unlink(pack2) < 0)
			fail("unlink: %s", strerror(errno));
		scan();
		k.n_pending_wb = 0;
	}
	{
		// **A PACK REPLACED UNDER ITS OWN NAME IS A NEW PACK**, and the
		// proof is that the drive serves the NEW file's words: the new
		// file's block is written by name, before it is renamed into place,
		// and the shadow is set from that --- so a program that kept the old
		// descriptor, or kept the old block in the store, serves the old
		// words and is caught.  A shadow filled through the drive would have
		// moved with the bug.
		if (make_pack(pack2, &PACK_T80) < 0)
			return 2;
		scan();
		const uint32_t Z = 0x906u;
		lay_synth(UNIT2, Z, 0x11u);		// the OLD file's words at Z
		struct xfer *x = enqueue(&k, UNIT2, 0);
		xfer_lba(x, Z);
		run();					// resident, out of the old file
		char incoming[4096];
		snprintf(incoming, sizeof incoming, "%s/incoming.img", bay_dir);
		if (make_pack(incoming, &PACK_T80) < 0)
			return 2;
		uint32_t page[PACK_BLOCK_WORDS];
		uint8_t bytes[PACK_BLOCK_BYTES];
		page_of(UNIT2, Z, 0x22u, page);
		for (int j = 0; j < PACK_BLOCK_WORDS; ++j)
			for (int q = 0; q < 4; ++q)
				bytes[4 * j + q] = (uint8_t)(page[j] >> (8 * q));
		{
			const int fd = open(incoming, O_RDWR);
			if (fd < 0 || pwrite(fd, bytes, sizeof bytes, (off_t)Z * PACK_BLOCK_BYTES) != (ssize_t)sizeof bytes)
				fail("writing the incoming pack by name");
			if (fd >= 0)
				close(fd);
		}
		struct blk *sh = shadow(UNIT2, Z, 1);
		memcpy(sh->data, page, PACK_BLOCK_BYTES);
		sh->hdr_laid = sh->dck_laid = 0;
		const unsigned long away0 = f.went_away, in0 = f.appeared, rep0 = f.replaced;
		if (rename(incoming, pack2) < 0)
			fail("renaming the incoming pack into place: %s", strerror(errno));
		scan();
		if (f.went_away != away0 + 1 || f.appeared != in0 + 1)
			fail("a pack replaced under its own name gave %lu removal(s) and %lu arrival(s), wanting 1 and 1",
			     f.went_away - away0, f.appeared - in0);
		if (f.replaced != rep0 + 1)
			fail("the replacement was not counted as one");
		if (!bay_pack(&bay, UNIT2))
			fail("unit %u has no pack after one was renamed into its name", UNIT2);
		// The walk asks for Z again: it must miss, and be served the NEW
		// file's words.
		x = enqueue(&k, UNIT2, 0);
		xfer_lba(x, Z);
		run();
		k.n_pending_wb = 0;
	}
	{
		// **THE EIGHT NAMES ARE THE RULE.**  Two more drives, at the two
		// ends of the range, each serving the same block number out of its
		// own file: a name mapped to the wrong unit hands one drive's words
		// to the other and the hit comparison says so.
		char p0[4096], p7[4096];
		bay_path(&bay, 0, p0, sizeof p0);
		bay_path(&bay, 7, p7, sizeof p7);
		if (!strstr(p0, "disk-pack-0.img") || !strstr(p7, "disk-pack-7.img"))
			fail("the bay's names are '%s' and '%s'", p0, p7);
		if (make_pack(p0, &PACK_T300) < 0 || make_pack(p7, &PACK_T300) < 0)
			return 2;
		k.drive_attention = 0;
		scan();
		if (!bay_pack(&bay, 0) || !bay_pack(&bay, 7))
			fail("the packs at the two ends of the range did not become drives");
		if (bay_present_mask(&bay) != (uint8_t)((1u << 0) | (1u << UNIT) | (1u << UNIT2) | (1u << 7)))
			fail("the drives present are 0x%02x, wanting 0x%02x", bay_present_mask(&bay),
			     (1u << 0) | (1u << UNIT) | (1u << UNIT2) | (1u << 7));
		if (k.drive_attention != (uint8_t)((1u << 0) | (1u << 7)))
			fail("the attention field was 0x%02x when two drives came present at once", k.drive_attention);
		const uint32_t N = 0x905u;
		lay_synth(0, N, 0xA0u);
		lay_synth(7, N, 0xA7u);
		struct xfer *x = enqueue(&k, 0, 0);
		xfer_lba(x, N);
		x = enqueue(&k, 7, 0);
		xfer_lba(x, N);
		run();
	}
	// Unit 5's blocks went with its pack; nothing at the end may compare
	// them against a file that is not there.
	for (size_t i = 0; i < n_blocks; ++i)
		if (blocks[i].unit == UNIT2)
			blocks[i].gone = 1;

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
		if (!s->touched || s->gone)
			continue;
		struct pack *pkp = bay_pack(&bay, s->unit);
		if (!pkp) {
			fail("block %x of unit %u has no pack in the bay at the end", s->lba, s->unit);
			continue;
		}
		++touched;
		uint8_t file_bytes[PACK_BLOCK_BYTES], want_bytes[PACK_BLOCK_BYTES];
		if (pread(pkp->fd, file_bytes, sizeof file_bytes, (off_t)s->lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof file_bytes) {
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
		if (pack_record(pkp, s->lba, got, err, sizeof err) < 0)
			fail("%s", err);
		else if (memcmp(got, want, sizeof got) != 0)
			fail("block %x's record at the end is not what the scripted writes imply", s->lba);
		if (s->hdr_laid || s->dck_laid)
			++laid_blocks;
	}
	if (laid_blocks == 0)
		fail("no block carries a laid header or checkword: the restart test would be vacuous");

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
		struct blk *s = shadow(UNIT, lba, 0);
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
		struct pack *pkp = bay_pack(&bay, UNIT);
		if (pread(pkp->fd, before_bytes, sizeof before_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof before_bytes)
			fail("reading the pack before the dropped write-back");
		k.store[slot][5] ^= 0xFFFFFFFFu;
		k.drop_next_write = 1;
		if (feeder_writeback(&f, (unsigned)slot, err, sizeof err) == 0)
			fail("a write-back that moved nothing was reported done");
		else if (!strstr(err, "nothing"))
			fail("a write-back that moved nothing was reported as '%s'", err);
		if (pread(pkp->fd, after_bytes, sizeof after_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof after_bytes)
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

	// ---- a restart: the tables are the format's again ---------------------------
	// muir's `Unit` keeps `headers` and `data_checkwords` for the run; so does
	// this.  Reopened, every touched block's data is what was written and its
	// header and checkwords are the format's own --- and for the blocks laid
	// with foreign ones that is a change, or this arm would be vacuous.
	unsigned long restart_compared = 0, restart_differ = 0;
	struct pack again_pk;
	bay_path(&bay, UNIT, path, sizeof path);
	for (unsigned u = 0; u < BAY_UNITS; ++u)
		bay_close(&bay, u);
	if (pack_open(&again_pk, path, 1, err, sizeof err) < 0)
		fail("reopening the pack: %s", err);
	else {
		if (again_pk.n_headers || again_pk.n_dcks)
			fail("the tables are not empty after a restart: %zu headers, %zu checkwords",
			     again_pk.n_headers, again_pk.n_dcks);
		for (size_t i = 0; i < n_blocks; ++i) {
			const struct blk *s = &blocks[i];
			if (!s->touched || s->gone || s->unit != UNIT)
				continue;
			uint32_t want[PACK_RECORD_WORDS], got[PACK_RECORD_WORDS], before[PACK_RECORD_WORDS];
			format_words(s->unit, s->lba, s->data, want);
			shadow_expect(s, before);
			if (pack_record(&again_pk, s->lba, got, err, sizeof err) < 0)
				fail("%s", err);
			else if (memcmp(got, want, sizeof got) != 0)
				fail("after a restart block %x's record is not the format's own over the data written", s->lba);
			else
				++restart_compared;
			if (memcmp(want, before, sizeof want) != 0)
				++restart_differ;
		}
		if (restart_differ == 0)
			fail("the restart changed no record: the arm is vacuous");
		// And a Write All laid again after the restart is carried for this run.
		const uint32_t L = 0x4000u;
		uint32_t w[PACK_RECORD_WORDS], again[PACK_RECORD_WORDS];
		shadow_expect(shadow(UNIT, L, 0), w);
		if (pack_writeback(&again_pk, L, w, err, sizeof err) < 0)
			fail("laying after the restart: %s", err);
		else if (pack_record(&again_pk, L, again, err, sizeof err) < 0 || memcmp(again, w, sizeof w) != 0)
			fail("a header laid after the restart did not come back within the run");
		pack_close(&again_pk);
	}

	{
		char cmd[4200];
		snprintf(cmd, sizeof cmd, "rm -rf '%s'", bay_dir);
		if (system(cmd) != 0)
			fail("clearing %s at the end", bay_dir);
	}
	fclose(console);
	unlink(logpath);
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
	if (f.appeared != 8 || f.went_away != 4)
		fail("the bay saw %lu drives appear and %lu go away, wanting 8 and 4", f.appeared, f.went_away);
	if (f.replaced < 1)
		fail("no pack was ever replaced under its own name");
	if (f.lost_blocks != 2 || f.lost_events != 2)
		fail("the bay lost %lu block(s) in %lu event(s), wanting 2 and 2", f.lost_blocks, f.lost_events);
	if (f.bay_failures)
		fail("%lu failures in the bay", f.bay_failures);
	if (ps.attentions == 0)
		fail("no attention was ever raised: a drive coming ready raises one");

	if (bad) {
		fprintf(stderr, "FAIL: %d mismatches\n", bad);
		return 1;
	}
	printf("ok: the disk pack program serves the disk controller on demand and keeps\n"
	       "    the pack as muir's Unit keeps it\n"
	       "    %lu requests posted by the modelled controller --- %lu from the\n"
	       "      trace's %lu NEED rows in %lu transfers --- %lu answered within\n"
	       "      %ld poll(s) each, %lu denied (other unit, off the pack);\n"
	       "      %lu hits compared, %lu words, every record 128-byte aligned\n"
	       "      in the spare region\n"
	       "    second chance over REF on every fetch, %lu times round the whole\n"
	       "      store; the walk's slot refused %lu times and passed, %lu of them a\n"
	       "      write-back meeting the next START and read back WAITING (the\n"
	       "      board's 0x5a); %lu dirty\n"
	       "      slot(s) written back on the way to being fetched into; every\n"
	       "      dirty slot back within %ld poll(s) of the walk leaving it\n"
	       "    %lu blocks touched, %lu bytes of the pack file equal to what the\n"
	       "      scripted writes imply, %lu Writes from the trace and %lu from the\n"
	       "      sweep; %lu load rows' checkwords agree with muir's Ecc, %lu laid\n"
	       "    after a restart %lu blocks' records are the format's own over the\n"
	       "      data written, %lu of them changed by it: the tables are the run's,\n"
	       "      as muir's are\n"
	       "    %lu refusals seen and named; a move that moved nothing seen by\n"
	       "      its poison; %lu polls of a busy face, %lu passes over the face\n"
	       "    the drive bay, on real files: %lu looks, %lu drive(s) appeared and\n"
	       "      %lu went away; two units served %lu hits out of two packs of two\n"
	       "      types at once; a rename took %lu block(s) out with it, read back\n"
	       "      from the renamed file; a delete and an overwrite lost %lu, each\n"
	       "      said on the console with its unit and its block; the read-only\n"
	       "      mark protected once and unprotected once, the flush first; a\n"
	       "      pack replaced under its own name served the NEW file's words;\n"
	       "      %lu look(s) put off for a transfer and nothing applied in one;\n"
	       "      %lu attention pulse(s), none left standing\n",
	       k.requests, trace_requests, needs, transfers, k.answered, k.worst_answer, k.denied_ok,
	       k.hits_compared, k.words_compared,
	       k.full_circles, k.refusals_walk, k.start_refusals, k.evict_writebacks, k.worst_dirty,
	       touched, compared_final, writes, sweep_writes, ecc_checked, lays,
	       restart_compared, restart_differ,
	       refusals, ps.polls, polls_run,
	       f.scans, f.appeared, f.went_away, bay_two_unit_hits, bay_flushed_out,
	       f.lost_blocks, bay_scans_deferred, ps.attentions);
	(void)loads;
	(void)sweep_reads;
	return 0;
}
