// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The checkpoint program's core, against a model of the fabric, on the build
// host --- no board, no Vivado, nothing but a C compiler.
//
// **WHAT THIS PROVES AND WHAT muir PROVES.**  This file holds the parts that
// can be decided here: that the packer is muir's packer, that the program
// compares the echo and refuses a word that came back for another address,
// and that every memory and every register the window reports reaches the
// body at the offset muir's format puts it.  **It cannot prove the format is
// right**, because a self-consistent writer and a self-consistent reader of
// the same wrong format agree perfectly.  What proves that is muir itself,
// and `build/checkpoint.pass` does it: this program writes a file, muir
// resumes it and writes its own, and the two are compared BYTE FOR BYTE.
// That is muir's own round-trip property --- `tests/checkpoint.rs`'s
// "the checkpoint loads and saves as itself" --- and it is the only evidence
// available here that every field went where it was meant to.
//
// The machine behind the model is a poison, injective in the memory and the
// address, for the reason every stimulus in this repository is: a machine of
// zeros would let a program that wrote the same field twice, or skipped one,
// or crossed two, agree with muir at every byte.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cadr_image.h"
#include "chk.h"
#include "chk_rtl.h"
#include "pack_bind.h"
#include "sha256.h"
#include "readout.h"

static long bad;
static void fail(const char *what, unsigned long long got, unsigned long long want)
{
	fprintf(stderr, "%s is 0x%llx, the reference says 0x%llx\n", what, got, want);
	++bad;
}

// --- the model -------------------------------------------------------------

// One of QUUX's timers as the fabric runs it: when its flag first rose (or
// will), and its period, in ticks of muir's clock since power-on.
struct qtimer {
	int en, live;
	uint64_t first_rise, period;
};

struct model {
	uint64_t imem[IMG_IMEM_WORDS], prom[IMG_PROM_WORDS];
	uint32_t amem[IMG_AMEM_WORDS], mmem[IMG_MMEM_WORDS];
	// QUUX's sizes, of which the CADR uses the first 1,024 of each.
	uint32_t pdl[IMG_QUUX_PDL_WORDS], spc[IMG_SPC_WORDS];
	uint32_t dmem[IMG_DMEM_WORDS], l1[IMG_L1_WORDS], l2[IMG_QUUX_L2_WORDS];
	uint16_t opcs[IMG_OPCS];
	uint64_t regs[21];
	uint32_t ro_addr;
	uint64_t latched;
	uint32_t hi_latch_cycles, hi_latch_ticks;
	uint64_t cycles, ticks;
	int running;
	// **THE ECHO, DELIBERATELY STALE FOR THE FIRST `stale_for` READS.**  A
	// program that did not compare it would take a word for the address
	// before the one it asked for and never know; this is how the check
	// asks whether it does.
	int stale_for;

	// --- QUUX: the bitstream says it is one, at K and L, and answers the
	// --- register table's entries 21 to 25 and selector 12.  **ITS CLOCK
	// --- MOVES**: `qm` is muir's, ticks since power-on, and every access
	// --- to the window advances it by `step`, as the board's does between
	// --- a reader's accesses.  TICKS is two ahead of it, the reset being
	// --- two edges before power-on.
	int quux;
	unsigned k, l;
	uint64_t qm, step;
	struct qtimer timer[2];
	uint32_t interval_us;
	uint64_t input;			/* selector 12 word 0, as the fabric packs it */
	uint32_t fifo[IMG_QUUX_FIFO_WORDS];
	uint32_t disk[4];		/* command, pointer, disk address, last address */
	uint64_t disk_flags;		/* word 5 */
	uint64_t page;			/* word 6 */
};

// A timer's word at muir's tick `m`: the fabric's counts to its next rise,
// and the microsecond clock's low bits of the same tick.
static uint64_t qtimer_word(const struct qtimer *t, uint64_t m)
{
	int sticky = 0;
	uint64_t pre = 0x55u, us = 0x5A5A5Au;	/* stopped: whatever it held */
	if (t->en && t->live) {
		uint64_t next = t->first_rise;
		if (m > t->first_rise) {
			sticky = 1;
			next = t->first_rise +
			       ((m - t->first_rise) / t->period + 1u) * t->period;
		}
		pre = (next - m) % 100u;
		us = (next - m) / 100u + 1u;
	}
	const uint64_t usec = m / 100u, usec_t = 99u - m % 100u;
	return ((usec & 0x7Fu) << 41) | (usec_t << 34) | ((uint64_t)t->en << 33) |
	       ((uint64_t)sticky << 32) | ((uint64_t)t->live << 31) | (pre << 24) | us;
}

static uint64_t model_word(struct model *m, unsigned sel, unsigned a)
{
	switch (sel) {
	case IMG_SEL_IMEM: return a < IMG_IMEM_WORDS ? m->imem[a] : 0;
	case IMG_SEL_PROM: return a < IMG_PROM_WORDS ? m->prom[a] : 0;
	case IMG_SEL_AMEM: return a < IMG_AMEM_WORDS ? m->amem[a] : 0;
	case IMG_SEL_MMEM: return a < IMG_MMEM_WORDS ? m->mmem[a] : 0;
	case IMG_SEL_PDL:  return a < (m->quux ? IMG_QUUX_PDL_WORDS : IMG_PDL_WORDS) ? m->pdl[a] : 0;
	case IMG_SEL_SPC:  return a < IMG_SPC_WORDS ? m->spc[a] : 0;
	case IMG_SEL_DMEM: return a < IMG_DMEM_WORDS ? m->dmem[a] : 0;
	case IMG_SEL_MAP1: return a < IMG_L1_WORDS ? m->l1[a] : 0;
	case IMG_SEL_MAP2: return a < (m->quux ? IMG_QUUX_L2_WORDS : IMG_L2_WORDS) ? m->l2[a] : 0;
	case IMG_SEL_OPCS: return a < IMG_OPCS ? m->opcs[a] : 0;
	case IMG_SEL_REGS:
		if (a < 21)
			return m->regs[a];
		if (!m->quux)
			return RO_NO_MEMORY;
		switch (a) {
		case IMG_RG_QUUX_ID:
			return ((uint64_t)IMG_QUUX_MARK << 32) | ((uint64_t)m->k << 24) |
			       ((uint64_t)m->l << 16);
		case IMG_RG_QUUX_TIME:
			return ((uint64_t)(99u - m->qm % 100u) << 32) |
			       ((m->qm / 100u) & 0xFFFFFFFFull);
		case IMG_RG_QUUX_TICK: return qtimer_word(&m->timer[0], m->qm);
		case IMG_RG_QUUX_INTERVAL: return qtimer_word(&m->timer[1], m->qm);
		case IMG_RG_QUUX_PERIOD: return m->interval_us;
		default: return RO_NO_MEMORY;
		}
	case IMG_SEL_QUUX_PAGE:
		if (!m->quux)
			return RO_NO_MEMORY;
		if (a >= IMG_QP_FIFO && a < IMG_QP_FIFO + IMG_QUUX_FIFO_WORDS)
			return m->fifo[a - IMG_QP_FIFO];
		switch (a) {
		case IMG_QP_INPUT: return m->input;
		case IMG_QP_CMD: case IMG_QP_CLP: case IMG_QP_DA: case IMG_QP_LMA:
			return m->disk[a - IMG_QP_CMD];
		case IMG_QP_DISK: return m->disk_flags;
		case IMG_QP_PAGE: return m->page;
		default: return RO_NO_MEMORY;
		}
	default: return RO_NO_MEMORY;
	}
}

static uint32_t model_read(struct readout *r, unsigned word)
{
	struct model *m = r->ctx;
	const unsigned sel = (m->ro_addr >> 14) & 0xFu;
	const unsigned a = m->ro_addr & 0x3FFFu;
	if (m->quux) {
		m->qm += m->step;
		m->ticks = m->qm + 2u;
	}
	switch (word) {
	case RO_IDENT: return RO_IDENT_WORD;
	case RO_STAT: return 0;
	case RO_CYCLES:
		m->hi_latch_cycles = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case RO_CYCLESH: return m->hi_latch_cycles;
	case RO_TICKS:
		m->hi_latch_ticks = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case RO_TICKSH: return m->hi_latch_ticks;
	case RO_ADDR:
		// A read of word 10 latches the word beside it, as the console
		// does, so the two halves are of one instant.
		m->latched = model_word(m, sel, a);
		if (m->stale_for > 0) {
			--m->stale_for;
			// One address short: the word for the one before it.
			return (m->ro_addr - 1u) & 0x3FFFFu;
		}
		return m->ro_addr;
	case RO_DATA_LO: return (uint32_t)m->latched;
	case RO_DATA_HI: return (uint32_t)(m->latched >> 32) & 0xFFFFu;
	default: return RO_UNMAPPED;
	}
}

static void model_write(struct readout *r, unsigned word, uint32_t v)
{
	struct model *m = r->ctx;
	if (m->quux) {
		m->qm += m->step;
		m->ticks = m->qm + 2u;
	}
	if (word == RO_ADDR)
		m->ro_addr = v & 0x3FFFFu;
	else if (word == RO_SPY(RO_SPY_CLK_W))
		m->running = (v & RO_CLK_RUN) != 0;
}

// The poison, `tb/cadr_readout_tb.cpp`'s, so that the two checks disagree
// about nothing.
static uint64_t poison(unsigned sel, unsigned addr, unsigned bits)
{
	const uint64_t h = (uint64_t)(sel + 1) * 0x9E3779B97F4A7C15ull +
			   (uint64_t)(addr + 1) * 0xC2B2AE3D27D4EB4Full;
	return bits >= 64 ? h : (h & ((1ull << bits) - 1ull));
}

static void fill(struct model *m)
{
	memset(m, 0, sizeof *m);
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		m->imem[i] = poison(IMG_SEL_IMEM, i, 48);
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		m->prom[i] = poison(IMG_SEL_PROM, i, 48);
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		m->amem[i] = (uint32_t)poison(IMG_SEL_AMEM, i, 32);
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		m->mmem[i] = (uint32_t)poison(IMG_SEL_MMEM, i, 32);
	for (unsigned i = 0; i < IMG_PDL_WORDS; ++i)
		m->pdl[i] = (uint32_t)poison(IMG_SEL_PDL, i, 32);
	for (unsigned i = 0; i < IMG_SPC_WORDS; ++i)
		m->spc[i] = (uint32_t)poison(IMG_SEL_SPC, i, 21);
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		m->dmem[i] = (uint32_t)poison(IMG_SEL_DMEM, i, 17);
	for (unsigned i = 0; i < IMG_L1_WORDS; ++i)
		m->l1[i] = (uint32_t)poison(IMG_SEL_MAP1, i, 5);
	for (unsigned i = 0; i < IMG_L2_WORDS; ++i)
		m->l2[i] = (uint32_t)poison(IMG_SEL_MAP2, i, 24);
	for (unsigned i = 0; i < IMG_OPCS; ++i)
		m->opcs[i] = (uint16_t)poison(IMG_SEL_OPCS, i, 14);

	// The register table.  **Every entry is masked to the width the
	// machine's own register has**, because muir refuses a pointer wider
	// than its register by name --- `spcptr > 0o37` and the two PDL
	// pointers past ten bits are three of its four range checks.
	static const unsigned bits[21] = { 14, 14, 48, 48, 32, 32, 32, 32,
					   32, 26, 10, 10, 10, 5, 14, 10,
					   24, 32, 22, 6, 33 };
	for (unsigned i = 0; i < 21; ++i)
		m->regs[i] = poison(IMG_SEL_REGS, i, bits[i]);
	m->cycles = 0x1234567890ull;
	m->ticks = 0x9876543210ull;
	m->running = 0;
}

// --- QUUX's machine ----------------------------------------------------------
//
// **THE SAME MACHINE `golden/src/quux_checkpoint.rs` BUILDS IN muir'S TERMS,
// HERE IN THE FABRIC'S**, and `build/checkpoint.quux.pass` compares the two
// files byte for byte.  There the clocks are enabled and a period written,
// keys pressed and read, the mouse moved and block-disk started through
// muir's own calls; here is what the fabric's counters and registers hold
// after the same history.  Every constant is the generator's, by the same
// name.  The `Rtl` engine's own registers are a fresh engine's on both sides,
// muir keeping them private: IR, PC and the flags are zero, LVMO its
// power-on value.
#define Q_M0        0x9876543210ull
#define Q_ENABLED   (Q_M0 - 1000037u)
#define Q_PERIOD_US 6000u
#define Q_CYCLES    0x1234567890ull
#define Q_DISK_CMD  0x12345805u
#define Q_DISK_CLP  0x00ABCDEFu
#define Q_DISK_DA   0x3FEDCBA9u
#define Q_KEYS      70u
#define Q_KEYS_READ 59u
#define Q_MOUSE_X   0x5a3u
#define Q_MOUSE_Y   0x2c7u
#define Q_BUTTONS   5u
#define Q_TICK_TICKS (16667u * 100u)

static void fill_quux(struct model *m)
{
	memset(m, 0, sizeof *m);
	m->quux = 1;
	m->k = 4;
	m->l = 0;
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		m->imem[i] = poison(IMG_SEL_IMEM, i, 48);	/* under the PROM too */
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		m->prom[i] = poison(IMG_SEL_PROM, i, 48);
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		m->amem[i] = (uint32_t)poison(IMG_SEL_AMEM, i, 32);
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		m->mmem[i] = (uint32_t)poison(IMG_SEL_MMEM, i, 32);
	for (unsigned i = 0; i < IMG_QUUX_PDL_WORDS; ++i)
		m->pdl[i] = (uint32_t)poison(IMG_SEL_PDL, i, 32);
	for (unsigned i = 0; i < IMG_SPC_WORDS; ++i)
		m->spc[i] = (uint32_t)poison(IMG_SEL_SPC, i, 21);
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		m->dmem[i] = (uint32_t)poison(IMG_SEL_DMEM, i, 17);
	for (unsigned i = 0; i < IMG_L1_WORDS; ++i)
		m->l1[i] = (uint32_t)poison(IMG_SEL_MAP1, i, 6);
	for (unsigned i = 0; i < IMG_QUUX_L2_WORDS; ++i)
		m->l2[i] = (uint32_t)poison(IMG_SEL_MAP2, i, 24);
	// A fresh `Rtl`'s OPC shift register, and its register table but for
	// the entries that are `Machine`'s, which are poisoned at their widths.
	for (unsigned i = 0; i < 21; ++i)
		m->regs[i] = 0;
	m->regs[IMG_RG_Q] = poison(IMG_SEL_REGS, IMG_RG_Q, 32);
	m->regs[IMG_RG_VMA] = poison(IMG_SEL_REGS, IMG_RG_VMA, 32);
	m->regs[IMG_RG_MD] = poison(IMG_SEL_REGS, IMG_RG_MD, 32);
	m->regs[IMG_RG_PDLPTR] = poison(IMG_SEL_REGS, IMG_RG_PDLPTR, 14);
	m->regs[IMG_RG_PDLIDX] = poison(IMG_SEL_REGS, IMG_RG_PDLIDX, 14);
	m->regs[IMG_RG_SPCPTR] = poison(IMG_SEL_REGS, IMG_RG_SPCPTR, 5);
	m->regs[IMG_RG_DC] = poison(IMG_SEL_REGS, IMG_RG_DC, 10);
	m->regs[IMG_RG_LVMO] = 0x00C03FFFu;
	m->regs[IMG_RG_MDHELD] = poison(IMG_SEL_REGS, IMG_RG_MDHELD, 32);
	m->regs[IMG_RG_PHYS] = poison(IMG_SEL_REGS, IMG_RG_PHYS, 22);
	m->regs[IMG_RG_FLAGS] = (1ull << IMG_F_VMAOK) | (1ull << IMG_F_RUN) |
				(1ull << IMG_F_ERRSTOP) | (1ull << IMG_F_STATHENB);
	m->cycles = Q_CYCLES;
	m->qm = Q_M0;
	m->ticks = Q_M0 + 2u;

	// The clocks: both enabled at `Q_ENABLED`, a write landing a tick after
	// its edge and the count one tick shorter, so each flag first rises a
	// period after the edge (`quux_clocks.sv`).
	m->timer[0] = (struct qtimer){ 1, 1, Q_ENABLED + Q_TICK_TICKS, Q_TICK_TICKS };
	m->timer[1] = (struct qtimer){ 1, 1, Q_ENABLED + Q_PERIOD_US * 100u, Q_PERIOD_US * 100u };
	m->interval_us = Q_PERIOD_US;

	// Seventy key words pressed into sixty-four slots, the last six dropped
	// and the overflow set, and fifty-nine read: five waiting from slot 59.
	for (unsigned i = 0; i < IMG_QUUX_FIFO_WORDS; ++i)
		m->fifo[i] = (uint32_t)poison(20, i, 24);
	const uint64_t head = Q_KEYS_READ, count = IMG_QUUX_FIFO_WORDS - Q_KEYS_READ;
	m->input = (head << 38) | (count << 31) | (1ull << 30) /* overflowed */ |
		   (1ull << 29) /* keyboard enable */ | (1ull << 28) /* mouse moved */ |
		   (1ull << 27) /* mouse enable */ | ((uint64_t)Q_BUTTONS << 24) |
		   ((uint64_t)Q_MOUSE_Y << 12) | Q_MOUSE_X;

	// Block-disk: a command it does not do, started, and nothing moved.
	m->disk[0] = Q_DISK_CMD;
	m->disk[1] = Q_DISK_CLP;
	m->disk[2] = Q_DISK_DA & 0x0FFFFFFFu;
	m->disk[3] = 0;
	m->disk_flags = (1ull << 36) /* not active */ | (1ull << 33) /* bad command */ |
			0x5A5A5Au;	/* the ticks since, which a disk that never walked has no use for */
	// The page: Xbus NXM and the map error, and black-on-white.
	m->page = (1u << 8) | 041u;
}

// --- the packer, against its own inverse -----------------------------------

static int unpack_equals(const uint8_t *raw, size_t len)
{
	size_t plen = 0;
	uint8_t *p = chk_pack(raw, len, &plen);
	if (!p)
		return 0;
	uint8_t *out = malloc(len ? len : 1);
	size_t o = 0, at = 0;
	int ok = 1;
	while (at < plen) {
		uint64_t zeros = 0, lit = 0;
		unsigned shift = 0;
		while (at < plen) {
			uint8_t b = p[at++];
			zeros |= (uint64_t)(b & 0x7f) << shift;
			shift += 7;
			if (!(b & 0x80))
				break;
		}
		shift = 0;
		while (at < plen) {
			uint8_t b = p[at++];
			lit |= (uint64_t)(b & 0x7f) << shift;
			shift += 7;
			if (!(b & 0x80))
				break;
		}
		if (o + zeros + lit > len) { ok = 0; break; }
		memset(out + o, 0, zeros);
		o += zeros;
		memcpy(out + o, p + at, lit);
		o += lit;
		at += lit;
	}
	if (ok)
		ok = (o == len) && (len == 0 || memcmp(out, raw, len) == 0);
	free(out);
	free(p);
	return ok;
}

int main(int argc, char **argv)
{
	// **THE SCRATCH DIRECTORY IS NOT OPTIONAL.**  Half of what this file
	// checks --- the sidecar written, read back and made to notice a pack
	// that has moved --- needs somewhere to put three small files, and a
	// check that quietly does less when an argument is missing is the
	// failure this repository keeps meeting.  So it is demanded.
	if (argc < 2) {
		fprintf(stderr, "usage: checkpoint_test <scratch directory> "
			"[<CADR checkpoint to write> [<QUUX checkpoint to write>]]\n");
		return 2;
	}
	const char *work = argv[1];
	const char *out = argc > 2 ? argv[2] : NULL;
	const char *quux_out = argc > 3 ? argv[3] : NULL;

	if (chk_rtl_mutation())
		printf("checkpoint: THIS IS A MUTANT --- %s\n", chk_rtl_mutation());

	// ---- SHA-256, against the standard's own vectors ---------------------
	//
	// **A HASH THAT IS SELF-CONSISTENTLY WRONG AGREES WITH ITSELF PERFECTLY
	// AND WITH NOBODY ELSE**, and the whole point of the digest in a
	// sidecar is that somebody with `sha256sum` and no software of ours can
	// check it.  So it is held to FIPS 180-4's published values and not to
	// a second implementation of the same mistake.
	{
		struct { const char *in; unsigned long repeat; const char *want; } v[] = {
			{ "", 1,
			  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
			{ "abc", 1,
			  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
			{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 1,
			  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
			// A million 'a's, fed a thousand at a time: the vector that
			// exercises the length field and the buffering together.
			{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 20000,
			  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
		};
		for (unsigned i = 0; i < sizeof v / sizeof v[0]; ++i) {
			struct sha256 h;
			sha256_init(&h);
			for (unsigned long k = 0; k < v[i].repeat; ++k)
				sha256_feed(&h, v[i].in, strlen(v[i].in));
			uint8_t d[SHA256_BYTES];
			char hex[SHA256_HEX];
			sha256_end(&h, d);
			sha256_hex(d, hex);
			if (strcmp(hex, v[i].want) != 0) {
				fprintf(stderr, "SHA-256 vector %u is %s, the standard "
					"says %s\n", i, hex, v[i].want);
				++bad;
			}
		}
	}

	// ---- a pack's geometry, which is its size and nothing else -----------
	//
	// `Unit::load` REFUSES a checkpoint whose geometry is not the resuming
	// drive's, so a geometry guessed rather than measured turns into a
	// refusal at the far end.  It is measured the way `cadr-disk-packs`
	// measures it: from the file's length.
	{
		uint32_t c = 0, h = 0, b = 0;
		if (bind_geometry_of_size(269562880ull, &c, &h, &b) != 0 ||
		    c != 815 || h != 19 || b != 17)
			fail("the T-300's geometry", ((uint64_t)c << 32) | (h << 8) | b, 0);
		if (bind_geometry_of_size(70937600ull, &c, &h, &b) != 0 ||
		    c != 815 || h != 5 || b != 17)
			fail("the T-80's geometry", ((uint64_t)c << 32) | (h << 8) | b, 0);
		// One byte short is a pack still being copied in, and is no drive.
		if (bind_geometry_of_size(269562879ull, &c, &h, &b) == 0)
			fail("a file one byte short was taken for a pack", 1, 0);
	}

	// ---- the sidecar: written, read back, and made to notice ------------
	//
	// Two small files stand in for packs.  `bind_verify` digests whatever
	// path it is given and does not care what a pack's size is, so the
	// property under test --- that a pack which has moved since the
	// checkpoint is NAMED rather than passed over --- is reachable without
	// a quarter of a gigabyte.
	{
		// Short by construction: `struct binding` holds a checkpoint's name in
		// 512 bytes and a pack's in 1024, and a scratch name that could not
		// fit would be a warning here rather than a finding.
		char a[256], b2[256], side[320], stand[256];
		snprintf(a, sizeof a, "%s/stand-in-pack-0", work);
		snprintf(b2, sizeof b2, "%s/stand-in-pack-1", work);
		snprintf(stand, sizeof stand, "%s/stand-in.chk", work);
		snprintf(side, sizeof side, "%s%s", stand, BIND_SUFFIX);
		FILE *f = fopen(a, "wb");
		if (f) { fputs("the pack as it was", f); fclose(f); }
		f = fopen(b2, "wb");
		if (f) { fputs("the other pack", f); fclose(f); }
		f = fopen(stand, "wb");
		if (f) { fputs("a checkpoint, for the purposes of this check", f); fclose(f); }

		struct binding w;
		bind_init(&w);
		w.boards = 32;
		w.microcycles = 1234567890ull;
		w.ns = 9876543210ull;
		w.machine_halted_first = 1;
		snprintf(w.taken, sizeof w.taken, "2026-09-11T19:30:00+0300");
		snprintf(w.checkpoint, sizeof w.checkpoint, "%s", stand);
		if (sha256_file(stand, w.checkpoint_sha, &w.checkpoint_bytes) != 0)
			fail("the stand-in checkpoint could not be digested", 1, 0);
		w.u[0].present = 1;
		snprintf(w.u[0].path, sizeof w.u[0].path, "%s", a);
		w.u[0].bytes = strlen("the pack as it was");
		w.u[0].cylinders = 815; w.u[0].heads = 19; w.u[0].blocks_per_track = 17;
		w.u[3].present = 1;
		snprintf(w.u[3].path, sizeof w.u[3].path, "%s", b2);
		w.u[3].bytes = strlen("the other pack");
		w.u[3].cylinders = 815; w.u[3].heads = 5; w.u[3].blocks_per_track = 17;
		w.u[3].read_only = 1;
		w.present = 2;
		char err[512] = "";
		if (bind_digest(&w, err, sizeof err) != 0)
			fail("the stand-in packs could not be digested", 1, 0);
		// **A DIGEST OF NOTHING IS NOT A DIGEST.**  Two different files
		// must have two different digests, or the check below would pass
		// against a binding that recorded one constant.
		if (strcmp(w.u[0].sha256, w.u[3].sha256) == 0)
			fail("two different packs digested the same", 1, 0);
		if (bind_write(&w, side, err, sizeof err) != 0)
			fail("the sidecar could not be written", 1, 0);

		struct binding rd;
		if (bind_read(&rd, side, err, sizeof err) != 0) {
			fprintf(stderr, "reading the sidecar back: %s\n", err);
			++bad;
		} else {
			if (rd.present != 2)
				fail("the sidecar's pack count", rd.present, 2);
			if (!rd.u[0].present || !rd.u[3].present)
				fail("the sidecar lost a unit", 0, 1);
			if (strcmp(rd.u[0].sha256, w.u[0].sha256) != 0)
				fail("unit 0's digest did not survive the sidecar", 1, 0);
			if (strcmp(rd.u[0].path, a) != 0)
				fail("unit 0's path did not survive the sidecar", 1, 0);
			if (rd.u[3].heads != 5 || !rd.u[3].read_only)
				fail("unit 3's geometry or switch did not survive", 1, 0);
			if (rd.boards != 32 || rd.microcycles != 1234567890ull)
				fail("the sidecar's header did not survive", rd.boards, 32);
			int chk_moved = 0;
			const int moved = bind_verify(&rd, &chk_moved, err, sizeof err);
			if (moved != 0)
				fail("an unchanged pack was called moved", (unsigned)moved, 0);
			// Now move one, by one byte, and require that it is named.
			f = fopen(a, "ab");
			if (f) { fputc('!', f); fclose(f); }
			struct binding again;
			if (bind_read(&again, side, err, sizeof err) != 0)
				fail("the sidecar could not be read a second time", 1, 0);
			const int moved2 = bind_verify(&again, &chk_moved, err, sizeof err);
			if (moved2 != 1)
				fail("a pack that moved was not caught", (unsigned)moved2, 1);
			else if (!again.u[0].moved || again.u[3].moved)
				fail("the wrong unit was named as moved", 1, 0);
			// And a pack that is not there at all is a refusal and not
			// a verdict: nothing can be said about a file nobody has.
			remove(a);
			struct binding gone;
			if (bind_read(&gone, side, err, sizeof err) != 0)
				fail("the sidecar could not be read a third time", 1, 0);
			if (bind_verify(&gone, &chk_moved, err, sizeof err) >= 0)
				fail("a missing pack was given a verdict", 1, 0);
			remove(b2);
			remove(stand);
			remove(side);
		}

		// **A QUUX BINDING SAYS SO, AND ITS RESUME IS QUUX'S.**  The line
		// survives the file, and the command it prints names the machine
		// and not the CADR's timing model, which muir refuses on QUUX.
		struct binding qb;
		bind_init(&qb);
		qb.quux = 1;
		qb.boards = 32;
		snprintf(qb.checkpoint, sizeof qb.checkpoint, "%s", stand);
		char cmd[4096];
		bind_resume_command(&qb, "q.chk", cmd, sizeof cmd);
		if (!strstr(cmd, "--machine quux") || strstr(cmd, "--timing-model"))
			fail("QUUX's resume command", 1, 0);
		if (bind_write(&qb, side, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || !rd.quux)
			fail("the sidecar lost the machine", 0, 1);
		qb.quux = 0;
		bind_resume_command(&qb, "c.chk", cmd, sizeof cmd);
		if (strstr(cmd, "--machine") || !strstr(cmd, "--timing-model fpga"))
			fail("the CADR's resume command", 1, 0);
		if (bind_write(&qb, side, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || rd.quux)
			fail("a CADR sidecar read back as QUUX's", 1, 0);
		remove(side);
	}

	// ---- the packer ----------------------------------------------------
	//
	// muir's `unpack` accepts any valid packing, so this does not prove the
	// packing is muir's; what proves that is the byte comparison against
	// muir's own re-save.  What this proves is that nothing is LOST, which
	// a round trip can say on its own.
	{
		static const uint8_t cases[][24] = {
			{ 0 },
			{ 1, 2, 3 },
			{ 0, 0, 0, 1 },			/* three zeros stay literal */
			{ 0, 0, 0, 0, 1 },		/* four end the run */
			{ 1, 0, 0, 2, 0, 0, 0, 0, 3 },
		};
		static const size_t lens[] = { 0, 3, 4, 5, 9 };
		for (unsigned i = 0; i < 5; ++i)
			if (!unpack_equals(cases[i], lens[i]))
				fail("a packed case does not unpack to itself", i, i);
		uint8_t big[4096];
		for (unsigned i = 0; i < sizeof big; ++i)
			big[i] = (i % 37u) < 30u ? 0u : (uint8_t)i;
		if (!unpack_equals(big, sizeof big))
			fail("a long packed case does not unpack to itself", 1, 0);
	}

	// ---- the echo, which the program must compare -----------------------
	{
		struct model m;
		fill(&m);
		m.stale_for = 1;
		struct readout r;
		memset(&r, 0, sizeof r);
		r.read = model_read;
		r.write = model_write;
		r.ctx = &m;
		uint64_t w = 0;
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) == 0)
			fail("a word came back for an address that was not asked "
			     "for and the program took it", 1, 0);
		if (r.stale != 1)
			fail("the stale read was not counted", r.stale, 1);
		// And the next read, with the echo honest, must succeed.
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) != 0)
			fail("an honest read was refused", 1, 0);
		if (w != poison(IMG_SEL_IMEM, 7, 48))
			fail("the word", w, poison(IMG_SEL_IMEM, 7, 48));
	}

	// ---- the whole machine through the window ---------------------------
	struct model *m = malloc(sizeof *m);
	if (!m) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	fill(m);
	struct readout r;
	memset(&r, 0, sizeof r);
	r.read = model_read;
	r.write = model_write;
	r.ctx = m;

	// One memory board: the file is then small enough to be diffed by hand
	// and muir resumes it at the header's own count.  Thirty-two is what
	// the board has and the field is the same field either way.
	struct cadr_image img;
	if (img_alloc(&img, 1) != 0) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	// **NO DRIVE, SO THE FILE muir RESUMES NEEDS NO PACK.**  The board
	// declares the units its drive bay holds; here there are none, which
	// is a state `Controller::load` accepts and is the one that makes the
	// round trip runnable with nothing but a muir.
	struct chk_declared decl;
	memset(&decl, 0, sizeof decl);
	// **THE ADDRESS IS PARSED AND NOT WRITTEN AS A LITERAL**, so that the
	// parser is in the path the checkpoint's own field comes down.  muir's
	// spelling for muir's default: a bare octal number.  A parser that read
	// it as decimal would put 0o131551 in the switches and muir would
	// refuse the file, which is exactly what happened on the board.
	if (chk_chaos_address("177001", &decl.chaos_address) != 0)
		fail("muir's own default address parsed", 1, 0);

	if (ro_read_machine(&r, &img) != 0) {
		fail("the window would not give the machine up", r.stale, 0);
		return 1;
	}

	// Every memory came back as the model holds it.  This is the program's
	// own transport, not muir's format: a selector read into the wrong
	// array, or a length off by one, shows here.
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		if (img.imem[i] != m->imem[i]) { fail("imem", img.imem[i], m->imem[i]); break; }
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		if (img.prom[i] != m->prom[i]) { fail("prom", img.prom[i], m->prom[i]); break; }
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		if (img.amem[i] != m->amem[i]) { fail("amem", img.amem[i], m->amem[i]); break; }
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		if (img.dmem[i] != m->dmem[i]) { fail("dmem", img.dmem[i], m->dmem[i]); break; }
	for (unsigned i = 0; i < IMG_L2_WORDS; ++i)
		if (img.l2_map[i] != m->l2[i]) { fail("l2_map", img.l2_map[i], m->l2[i]); break; }
	if (img.pc != (uint16_t)m->regs[IMG_RG_PC])
		fail("PC", img.pc, m->regs[IMG_RG_PC]);
	if (img.ir != m->regs[IMG_RG_IR])
		fail("IR", img.ir, m->regs[IMG_RG_IR]);
	if (img.spcptr != (uint8_t)m->regs[IMG_RG_SPCPTR])
		fail("SPCPTR", img.spcptr, m->regs[IMG_RG_SPCPTR]);
	if (img.cycles != m->cycles)
		fail("CYCLES", img.cycles, m->cycles);
	if (img.ticks != m->ticks)
		fail("TICKS", img.ticks, m->ticks);

	// Main memory and the display are DDR on the board and are poisoned
	// here, so that the two largest arrays in the file are not zeros.
	for (size_t i = 0; i < IMG_BOARD_WORDS; ++i)
		img.main[i] = (uint32_t)poison(12, (unsigned)i, 32);
	for (size_t i = 0; i < IMG_TV_WORDS; ++i)
		img.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);
	// **AND THE FIRST DISPLAY BOARD'S COLOR MAP, WHICH IS NOT DDR AND IS NOT
	// ZERO EITHER.**  It comes off the console face's page 4 on the board ---
	// register 4 is write only on the Xbus, so that page is the only way to
	// ask what a color is --- and a check that only ever ran it at zero
	// would pass a program that wrote zeros, which is what this one used to
	// do.  Poisoned in the color and the channel, none of the forty-eight
	// bytes zero, so a byte taken from the wrong slot cannot come back right.
	for (unsigned c = 0; c < IMG_MAP_COLORS; ++c)
		for (unsigned k = 0; k < IMG_MAP_CHANNELS; ++k)
			img.tv_map[c][k] =
				(uint8_t)(1u + (unsigned)poison(14, c * 4u + k, 8) % 250u);

	struct chk body;
	size_t machine_body_len = 0;
	chk_init(&body);
	chk_rtl_body(&body, &img, &decl);
	if (body.broken) {
		fail("the body ran out of memory", 1, 0);
		return 1;
	}

	// **THE BODY'S LENGTH IS A FIXED NUMBER AND IT IS ASSERTED.**  Every
	// field in an `rtl` body is fixed-width and every array's length is
	// known, so the whole body is one arithmetic expression --- and a field
	// added, dropped or written at the wrong width moves it.  That is a
	// cheap, sharp check on a format with no framing in it: muir would
	// catch the same mistake, but only after the file reached a machine
	// with muir on it.
	//
	// Machine::save, one board:
	//   prom       8 + 1024*8         = 8200
	//   imem       8 + 16384*8        = 131080
	//   mode/clk/opc  6 + 5 + 3       = 14
	//   debug_ir + prog_reset + boot  = 10
	//   amem/mmem/dmem/pdl/spc  (8+4096)+(8+128)+(8+8192)+(8+65536)+(8+128) = 78120
	//                                            (the PDL is muir's largest
	//                                             machine's, 16K words, of
	//                                             which a CADR has 1K)
	//   spcptr..dispatch_constant     = 1+2+2+4+2+4+4+4+4+2 = 29
	//   l1_map     8 + 8192           = 8200
	//   geometry   1 + 1 + 1 + 1      = 4        (Geometry::CADR: 5, 10, no
	//                                             multiply and divide, no tick)
	//   tick       1 + 8 + 1 + 4 + 8  = 22       (Tick::new: the tick off
	//                                             with no deadline, the
	//                                             interval timer off, its
	//                                             period 0, no deadline;
	//                                             version 38)
	//   dma_written 1
	//   l2_map     8 + 8192           = 8200     (2048 entries, QUUX's; a
	//                                             CADR has 1024)
	//   boards     4
	//   main       8 + 65536*4        = 262152
	//   bus_error..write_buffer  2+2+1+(8+32)*3 = 125
	//   vmaok      1
	//   disk       61 + 8             = 69       (no drives: 8 flag bytes)
	//   block_disk 1                  = 1        (none: the flag alone)
	//   tv         1+2+2+(8+131072)+4+(8+4096)+2+1+48+1+8+8+1+1 = 135263
	//                                            (the board's tag, MONO TV's size, the
	//                                             buffer, the mode, the
	//                                             sync RAM, the color map
	//                                             as 48 bare bytes, the
	//                                             flag, two instants, and the
	//                                             two held sync bits)
	//   color_tv   1                  = 1        (the flag alone: none is
	//                                             fitted, so no board
	//                                             follows it)
	//   ioboard    57 + 110 + 1 + 85  = 253      (its own, the serial port's
	//                                             Pci, the chaos flag, and
	//                                             the Chaosnet interface)
	//   quux_input 4+1+1+2+2+1+1+1    = 13       (QUUX's keyboard and mouse,
	//                                             empty: version 39)
	//   cycles+ns  16
	// Rtl tail:
	//   trace+flags  (8+96)*2         = 208
	//   ir..lc       8+8+2+1+1+4+2+2+4 = 32
	//   19 bools                       = 19
	//   halted_ns + ir_loaded_ns + pulsed + 4 bools = 21
	//   busint     (1+1+8) + 42*1 + (1+8+1+1+8+1+1+1+1+8+8+1+2+2+8+8+8+1+1+1+8+8)
	//              + (1+4+1+8+1+8) = 163  (the cache and QUUX's memory
	//                                      timing, both absent, and the
	//                                      four fields beside them)
	//   mbusy_sync                     = 1
	//   bus_addr..bus_acked            = 4+4+1+1+1+1+2+1+8+8+1 = 32
	//   debug_*                        = 1+1+1+1+1+1+8+1+2+8 = 25
	//   wmapd..imodd                   = 1+4+8+8+1+1+2+1 = 26
	//   opc        8 + 16              = 24
	//   stat..executed                 = 4+1+1+1+8+4+8+1 = 28
	//
	// The arithmetic is written out rather than summed by hand so that a
	// reader can check one line instead of one number.
	{
		const size_t machine_part =
			8200 + 131080 + 14 + 10 + 78120 + 29 + 8200 + 4 + 22 + 1 + 8200 + 4 +
			262152 + 125 + 1 + 69 + 1 + 135263 + 1 + 253 + 13 + 16;
		const size_t rtl_part =
			208 + 32 + 19 + 21 + 163 + 1 + 32 + 25 + 26 + 24 + 28;
		// **A MUTANT IS JUDGED BY muir AND NOT HERE.**  Six of the seven
		// keep the body's length and one does not, and the point of
		// building them is what the ROUND TRIP does with them, so this
		// assertion --- which belongs to the real thing --- stands down.
		if (!chk_rtl_mutation() && body.len != machine_part + rtl_part)
			fail("the body's length", body.len, machine_part + rtl_part);
		machine_body_len = machine_part + rtl_part;
	}

	if (out) {
		if (chk_write_file(out, "rtl", 1, &body) != 0) {
			perror(out);
			return 1;
		}
	}

	printf("checkpoint: %zu bytes of body, %lu reads and %lu writes over a "
	       "modeled window, %lu of them refused for a stale echo\n",
	       body.len, r.reads, r.writes, r.stale);
	if (out)
		printf("checkpoint: wrote %s --- muir opening it is the proof, and "
		       "`make build/checkpoint.pass` is where that happens\n", out);
	chk_free(&body);
	const size_t cadr_body_len = machine_body_len;

	// ---- QUUX -------------------------------------------------------------
	//
	// The machine `golden/src/quux_checkpoint.rs` builds, through a modeled
	// window that says it is QUUX; the file goes where the third argument
	// says and `build/checkpoint.quux.pass` compares it with muir's own.
	{
		unsigned k = 99, l = 99;
		if (ro_machine_is_quux(&r, &k, &l) != 0)
			fail("the CADR's window was taken for QUUX's", 1, 0);

		struct model *q = malloc(sizeof *q);
		if (!q) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		fill_quux(q);
		struct readout qr;
		memset(&qr, 0, sizeof qr);
		qr.read = model_read;
		qr.write = model_write;
		qr.ctx = q;
		if (ro_machine_is_quux(&qr, &k, &l) != 1 || k != 4 || l != 0)
			fail("QUUX's window, K and L", ((uint64_t)k << 8) | l, 4u << 8);

		struct cadr_image qi;
		if (img_alloc_machine(&qi, 1, 1) != 0) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		if (qi.pdl_words != IMG_QUUX_PDL_WORDS || qi.l2_words != IMG_QUUX_L2_WORDS ||
		    qi.tv_words != IMG_QUUX_TV_WORDS)
			fail("QUUX's arrays' sizes", qi.pdl_words, IMG_QUUX_PDL_WORDS);
		if (ro_read_machine(&qr, &qi) != 0) {
			fail("the window would not give QUUX up", qr.stale, 0);
			return 1;
		}
		// The transport, at QUUX's sizes and in QUUX's words.
		if (qi.pdl[IMG_QUUX_PDL_WORDS - 1] != q->pdl[IMG_QUUX_PDL_WORDS - 1])
			fail("the PDL buffer's last word", qi.pdl[IMG_QUUX_PDL_WORDS - 1],
			     q->pdl[IMG_QUUX_PDL_WORDS - 1]);
		if (qi.l2_map[IMG_QUUX_L2_WORDS - 1] != q->l2[IMG_QUUX_L2_WORDS - 1])
			fail("level 2's last entry", qi.l2_map[IMG_QUUX_L2_WORDS - 1],
			     q->l2[IMG_QUUX_L2_WORDS - 1]);
		if (qi.qx.m != Q_M0)
			fail("muir's clock off the microsecond clock", qi.qx.m, Q_M0);
		if (qi.qx.head != Q_KEYS_READ || qi.qx.count != 5)
			fail("the FIFO's head and count", qi.qx.head, Q_KEYS_READ);
		if (qi.qx.x != Q_MOUSE_X || qi.qx.y != Q_MOUSE_Y || qi.qx.buttons != Q_BUTTONS)
			fail("the mouse", qi.qx.x, Q_MOUSE_X);
		if (qi.qx.da != (Q_DISK_DA & 0x0FFFFFFFu) || !qi.qx.bad_command)
			fail("block-disk", qi.qx.da, Q_DISK_DA & 0x0FFFFFFFu);
		if (qi.qx.bus_error != 041u || !qi.qx.bow)
			fail("the page", qi.qx.bus_error, 041u);
		for (size_t i = 0; i < IMG_BOARD_WORDS; ++i)
			qi.main[i] = (uint32_t)poison(12, (unsigned)i, 32);
		for (size_t i = 0; i < IMG_QUUX_TV_WORDS; ++i)
			qi.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);

		struct chk qb;
		chk_init(&qb);
		chk_rtl_body(&qb, &qi, &decl);
		// **THE BODY'S LENGTH, AGAIN AN ARITHMETIC EXPRESSION**: the
		// CADR's, and what QUUX has that it has not --- block-disk's
		// forty-four bytes after its flag, MONO TV's 8,192 words past the
		// CADR display's 32,768, the five key words waiting, and K and L
		// after the timing model's tag.
		const size_t quux_len = cadr_body_len + 44 + 8192 * 4 + 5 * 4 + 2;
		if (!chk_rtl_mutation() && qb.len != quux_len)
			fail("QUUX's body's length", qb.len, quux_len);
		if (quux_out && chk_write_file(quux_out, "rtl", 1, &qb) != 0) {
			perror(quux_out);
			return 1;
		}
		printf("checkpoint: QUUX, %zu bytes of body, %lu reads over a modeled "
		       "window%s%s\n", qb.len, qr.reads, quux_out ? ", wrote " : "",
		       quux_out ? quux_out : "");

		// **THE CLOCK MOVES WHILE IT IS READ.**  The same machine read with
		// its clock advancing 37 ticks at every access, some tens of
		// milliseconds over the whole read, so both timers rise meanwhile:
		// each timer's word must still be placed at the tick it was taken
		// at, which is what makes its next rise the rise the schedule has
		// after that tick.
		{
			struct cadr_image mv;
			fill_quux(q);
			q->step = 37;
			if (img_alloc_machine(&mv, 1, 1) != 0 || ro_read_machine(&qr, &mv) != 0) {
				fail("QUUX with a moving clock was refused", 1, 0);
			} else {
				if (mv.qx.m <= Q_M0)
					fail("the checkpoint's instant did not move", mv.qx.m, Q_M0);
				for (unsigned t = 0; t < 2; ++t) {
					const struct quux_timer *b = &mv.qx.timer[t];
					const struct qtimer *s = &q->timer[t];
					const uint64_t got = b->m + b->pre + (uint64_t)(b->us - 1u) * 100u;
					const int up = b->m > s->first_rise;
					const uint64_t want = up ? s->first_rise +
						((b->m - s->first_rise) / s->period + 1u) * s->period
						: s->first_rise;
					if (got != want || b->sticky != up)
						fail("a timer's next rise, read on a moving clock", got, want);
					if (b->m < mv.qx.m || b->m - mv.qx.m > RO_QUUX_SPAN)
						fail("a timer's word placed outside the read", b->m, mv.qx.m);
				}
			}
			img_free(&mv);
			// And a reader too slow to name one tick by seven bits of
			// microseconds is refused rather than believed.
			fill_quux(q);
			q->step = 5000;
			if (img_alloc_machine(&mv, 1, 1) == 0 && ro_read_machine(&qr, &mv) == 0)
				fail("a read of the clocks spread over milliseconds was taken", 1, 0);
			img_free(&mv);
		}
		chk_free(&qb);
		img_free(&qi);
		free(q);
	}
	// ---- **AN ADDRESS IS OCTAL** ----------------------------------------
	//
	// `--chaos-address 177100` went through `strtoul(.., 0)` and put
	// 0o131714 --- the low sixteen bits of one hundred and seventy-seven
	// thousand --- into the checkpoint's switches, and muir refused the
	// file saying exactly that.  Only `0177100` worked.  muir's flag
	// "wants one address in octal or subnet:host", and
	// `chaos::parse_address` is the whole of what it takes; this is that
	// parser in C, so the spellings are compared against muir's rules and
	// not against this program's own habits.
	//
	// **SKIPPED UNDER A MUTANT, AND THAT IS NOT A CHECK LOOKING AWAY.**
	// Mutant 8 REPLACES this parser, so these vectors would be asserting
	// the thing the mutant took out: they fail by construction, the test
	// exits non-zero, and the loop that judges the mutants would call it
	// BROKEN rather than caught.  What holds the mutant is the file ---
	// the address in it comes down this parser, so a decimal reader puts
	// 0o131551 in the switches and muir refuses it by name, which is the
	// first leg of that loop and is exactly how the defect was found on
	// the board.  The two hold different halves: the vectors hold the
	// parser, the mutant holds that the FIELD comes through it.
	if (!chk_rtl_mutation()) {
		static const struct { const char *s; int ok; unsigned want; } t[] = {
			// The board's own, which is the spelling that was wrong.
			{ "177100", 1, 0177100u },
			// A leading zero changes nothing: the string is octal
			// already, and both spellings are the same address.
			{ "0177100", 1, 0177100u },
			{ "3050", 1, 03050u },
			{ "177001", 1, 0177001u },
			// subnet:host, muir's other form --- and `376:1` is the
			// same address as `177001` written the other way, which
			// is what says the two forms are one number.
			{ "376:1", 1, 0177001u },
			{ "1:1", 1, 0401u },
			// **A DIGIT 8 OR 9 IS NOT OCTAL.**  This is the whole of
			// the defect: a decimal reader takes these and an octal
			// one refuses them.
			{ "177108", 0, 0 },
			{ "9", 0, 0 },
			{ "18:1", 0, 0 },
			// No prefix of any kind, which muir has none of either.
			{ "0x1234", 0, 0 },
			{ "0o177100", 0, 0 },
			// Both halves non-zero, which is muir's `both`.
			{ "0", 0, 0 },
			{ "377", 0, 0 },
			{ "177000", 0, 0 },
			{ "1:0", 0, 0 },
			{ "0:1", 0, 0 },
			// A byte of a pair is at most 0o377.
			{ "400:1", 0, 0 },
			{ "1:400", 0, 0 },
			// And nothing at all is nothing.
			{ "", 0, 0 },
			{ ":", 0, 0 },
			{ "177100:", 0, 0 },
			{ "177777", 1, 0177777u },
			{ "200000", 0, 0 },
		};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			unsigned got = 0xFFFFFFFFu;
			const int rc = chk_chaos_address(t[i].s, &got);
			if (t[i].ok) {
				if (rc != 0)
					fail("an address this program must take", 1, 0);
				else if (got != t[i].want)
					fail(t[i].s, got, t[i].want);
			} else if (rc == 0) {
				fail("an address this program must refuse", got, 1);
			}
		}
	}

	img_free(&img);
	free(m);

	if (bad) {
		fprintf(stderr, "FAIL: %ld mismatches\n", bad);
		return 1;
	}
	printf("PASS\n");
	return 0;
}
