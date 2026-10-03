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

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

// One of QUUX's interval timers as the fabric runs it: when its flag first
// rose (or will), and its period, in ticks of muir's clock since power-on;
// its mode and interrupt enable, and its period as the word holds it.
struct qtimer {
	int en, live;
	uint64_t first_rise, period;
	int one_shot, ie;
	uint32_t period_us;
};

struct model {
	uint64_t imem[IMG_IMEM_WORDS], prom[IMG_PROM_WORDS];
	// Words: 32 bits, and 40 on revision 13.
	uint64_t amem[IMG_AMEM_WORDS], mmem[IMG_MMEM_WORDS];
	// The largest machine's sizes, QUUX's PDL buffer and revision 13's
	// dispatch memory and maps, of which the others use the first part.
	uint64_t pdl[IMG_QUUX_PDL_WORDS];
	uint32_t spc[IMG_SPC_WORDS];
	uint32_t dmem[IMG_DMEM_WORDS_13], l1[IMG_L1_WORDS_13], l2[IMG_L2_WORDS_13];
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
	int quux, rev13;
	unsigned k, l;
	uint64_t qm, step;
	struct qtimer timer[IMG_QUUX_TIMERS];
	uint64_t input;			/* selector 12 word 0, as the fabric packs it */
	uint32_t fifo[IMG_QUUX_FIFO_WORDS];
	uint32_t disk[4];		/* command, pointer, disk address, last address */
	uint64_t disk_flags;		/* word 5 */
	uint64_t page;			/* word 6 */
	uint64_t fd[3];			/* words 7, 8 and 9: the file device */
	uint64_t fd_resp_13;		/* word 10, revision 13's response ring's base */
	// Revision 12's fused return: the register table's entries 29 to 40 and
	// selector 13, the MACRO DISPATCH MEMORY.
	uint64_t macro[12];
	uint32_t entries[IMG_QUUX_MACRO_ENTRIES];
};

// A timer's count word at muir's tick `m`: the fabric's counts to its next
// rise, and the microsecond clock's low bits of the same tick.  A one-shot
// that has risen has stopped there, `live` down, its prescaler reloaded and
// its count at one (`quux_clocks.sv`).
static uint64_t qtimer_word(const struct qtimer *t, uint64_t m)
{
	int sticky = 0, live = t->live;
	uint64_t pre = 0x55u, us = 0x5A5A5Au;	/* stopped: whatever it held */
	if (t->en && t->live && t->one_shot && m > t->first_rise) {
		sticky = 1;
		live = 0;
		pre = 99u;
		us = 1u;
	} else if (t->en && t->live) {
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
	       ((uint64_t)sticky << 32) | ((uint64_t)live << 31) | (pre << 24) | us;
}

// A timer's other word: its interrupt enable, its mode and its period.
static uint64_t qtimer_conf(const struct qtimer *t)
{
	return ((uint64_t)t->ie << 25) | ((uint64_t)t->one_shot << 24) | t->period_us;
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
	case IMG_SEL_DMEM: return a < (m->rev13 ? IMG_DMEM_WORDS_13 : IMG_DMEM_WORDS) ? m->dmem[a] : 0;
	case IMG_SEL_MAP1: return a < (m->rev13 ? IMG_L1_WORDS_13 : IMG_L1_WORDS) ? m->l1[a] : 0;
	case IMG_SEL_MAP2:
		return a < (m->rev13 ? IMG_L2_WORDS_13 : m->quux ? IMG_QUUX_L2_WORDS : IMG_L2_WORDS)
			       ? m->l2[a] : 0;
	case IMG_SEL_OPCS: return a < IMG_OPCS ? m->opcs[a] : 0;
	case IMG_SEL_REGS:
		if (a < 21)
			return m->regs[a];
		if (!m->quux)
			return RO_NO_MEMORY;
		switch (a) {
		case IMG_RG_QUUX_ID:
			return ((uint64_t)IMG_QUUX_MARK << 32) | ((uint64_t)m->k << 24) |
			       ((uint64_t)m->l << 16) | (m->rev13 ? IMG_QUUX_ID_13 : 0u);
		case IMG_RG_QUUX_TIME:
			return ((uint64_t)(99u - m->qm % 100u) << 32) |
			       ((m->qm / 100u) & 0xFFFFFFFFull);
		default:
			if (a >= IMG_RG_QUUX_COUNT && a < IMG_RG_QUUX_COUNT + IMG_QUUX_TIMERS)
				return qtimer_word(&m->timer[a - IMG_RG_QUUX_COUNT], m->qm);
			if (a >= IMG_RG_QUUX_CONF && a < IMG_RG_QUUX_CONF + IMG_QUUX_TIMERS)
				return qtimer_conf(&m->timer[a - IMG_RG_QUUX_CONF]);
			if (a >= IMG_RG_QUUX_MACRO && a <= IMG_RG_QUUX_PF_FETCH)
				return m->macro[a - IMG_RG_QUUX_MACRO];
			return RO_NO_MEMORY;
		}
	case IMG_SEL_MACRO:
		if (!m->quux)
			return RO_NO_MEMORY;
		return a < IMG_QUUX_MACRO_ENTRIES ? m->entries[a] : RO_NO_MEMORY;
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
		case IMG_QP_FD_BASES: case IMG_QP_FD_INDEXES: case IMG_QP_FD_FLAGS:
			return m->fd[a - IMG_QP_FD_BASES];
		case IMG_QP_FD_RESP_BASE_13:
			return m->rev13 ? m->fd_resp_13 : RO_NO_MEMORY;
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
// files byte for byte.  There the timers are turned on and periods written,
// keys pressed and read, the mouse moved and block-disk started through
// muir's own calls; here is what the fabric's counters and registers hold
// after the same history.  Every constant is the generator's, by the same
// name.  The `Rtl` engine's own registers are a fresh engine's on both sides,
// muir keeping them private: IR, PC and the flags are zero, LVMO its
// power-on value.
#define Q_M0        0x9876543210ull
#define Q_ENABLED   (Q_M0 - 1000037u)
#define Q_PERIOD_US 6000u
#define Q_ONE_SHOT_US 16667u
#define Q_SHOT_AT_M0_US 3000u
#define Q_CYCLES    0x1234567890ull
#define Q_DISK_CMD  0x12345805u
#define Q_DISK_CLP  0x00ABCDEFu
#define Q_DISK_DA   0x3FEDCBA9u
#define Q_KEYS      70u
#define Q_KEYS_READ 59u
#define Q_MOUSE_X   0x5a3u
#define Q_MOUSE_Y   0x2c7u
#define Q_BUTTONS   5u
// Block-disk's disk, declared as a pack of this geometry on unit 0: 256
// blocks, `DISK_BLOCKS` in `golden/src/quux_checkpoint.rs`.
#define Q_DISK_CYLINDERS 16u
#define Q_DISK_HEADS     1u
#define Q_DISK_BPT       16u
// The file device (revision 9): the rings configured and enabled with the
// interrupt enable, one command answered and its response consumed, and an
// index fault left standing.
#define Q_FD_CMD_BASE  0x001000u
#define Q_FD_CMD_LOG2  2u
#define Q_FD_RESP_BASE 0x001100u
#define Q_FD_RESP_LOG2 1u

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
	// A halted QUUX's memory port idle, its write buffer drained.
	m->regs[IMG_RG_FLAGS] = (1ull << IMG_F_VMAOK) | (1ull << IMG_F_RUN) |
				(1ull << IMG_F_ERRSTOP) | (1ull << IMG_F_STATHENB) |
				(1ull << IMG_F_MEM_DRAINED);
	m->cycles = Q_CYCLES;
	m->qm = Q_M0;
	m->ticks = Q_M0 + 2u;

	// The interval timers: timers 0 and 1 turned on at `Q_ENABLED`, a write
	// landing a tick after its edge and the count one tick shorter, so each
	// flag first rises a period after the edge (`quux_clocks.sv`); timer 0
	// one-shot with its interrupt enable, not yet risen, timer 1 periodic
	// with its, risen once; and timer 2 one-shot without it, turned on so
	// that it rose at the tick before `Q_M0`.
	m->timer[0] = (struct qtimer){ 1, 1, Q_ENABLED + Q_ONE_SHOT_US * 100u, Q_ONE_SHOT_US * 100u,
				       1, 1, Q_ONE_SHOT_US };
	m->timer[1] = (struct qtimer){ 1, 1, Q_ENABLED + Q_PERIOD_US * 100u, Q_PERIOD_US * 100u,
				       0, 1, Q_PERIOD_US };
	m->timer[2] = (struct qtimer){ 1, 1, Q_M0 - 1u, Q_SHOT_AT_M0_US * 100u, 1, 0, Q_SHOT_AT_M0_US };

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
	// The file device: words 7 to 9 as `cadr_machine.sv` packs them, no
	// handle open and nothing queued, so a checkpoint may be taken.
	m->fd[0] = ((uint64_t)Q_FD_CMD_BASE << 24) | Q_FD_RESP_BASE;
	m->fd[1] = (1ull << 32) | (1ull << 16) | 1u;
	m->fd[2] = ((uint64_t)Q_FD_CMD_LOG2 << 24) | ((uint64_t)Q_FD_RESP_LOG2 << 20) |
		   (1u << 3) /* index fault */ | (1u << 1) /* interrupt enable */ | 1u;
	// Revision 12's fused return, as `golden/src/quux_checkpoint.rs` sets
	// it: the register (its <30:29> 0), the index, the base copies, an
	// operand address armed for ARG and M 31's word armed; the counts,
	// which no checkpoint carries; and no prefetched word and no fetch.
	m->macro[IMG_RG_QUUX_MACRO - IMG_RG_QUUX_MACRO] = poison(10, 29, 32) & ~(3ull << 29);
	m->macro[IMG_RG_QUUX_MACRO_IX - IMG_RG_QUUX_MACRO] = poison(10, 30, 10);
	m->macro[IMG_RG_QUUX_BASES - IMG_RG_QUUX_MACRO] =
		(poison(10, 131, 14) << 14) | poison(10, 31, 14);
	m->macro[IMG_RG_QUUX_ARMED - IMG_RG_QUUX_MACRO] =
		(1u << 9) | (1u << 8) | (1u << 7) | poison(10, 32, 6);
	m->macro[IMG_RG_QUUX_M31_W - IMG_RG_QUUX_MACRO] = poison(10, 33, 32);
	m->macro[IMG_RG_QUUX_FUSED_N - IMG_RG_QUUX_MACRO] = 0x12345u;
	m->macro[IMG_RG_QUUX_OPR_N - IMG_RG_QUUX_MACRO] = 0x2345u;
	m->macro[IMG_RG_QUUX_PF_N - IMG_RG_QUUX_MACRO] = 0x345u;
	for (unsigned i = 0; i < IMG_QUUX_MACRO_ENTRIES; ++i)
		m->entries[i] = (uint32_t)poison(13, i, 18);
}

// --- QUUX revision 13's machine ------------------------------------------------
//
// **THE MACHINE `golden/src/quux_checkpoint.rs --revision 13` BUILDS**, the
// same history as revision 12's above at revision 13's widths and sizes
// (contract G2 appendix A1.13): words of 40 bits whose tags are not zero, a
// dispatch memory of 4,096 entries, a level-1 map of 8,192 seven-bit entries
// and a level-2 map of 4,096 28-bit ones, the overflow flag set, block-disk's
// pointer and the file device's response ring at revision 13's addresses,
// and a fresh engine's LVMO, revision 13's. `build/checkpoint.quux.pass`
// compares the file with muir's byte for byte and has muir load it and save
// it again.  Main memory is packed storage, `main13` below.
#define Q_DISK_CLP_13      0x0ABCDEF0u
#define Q_FD_RESP_BASE_13  0x001108u
// `Geometry::lvmo_at_power_on` on revision 13: the access bits at <27:26>
// and the page's 18 bits all ones.
#define Q_LVMO_13          ((1u << 27) | (1u << 26) | 0777777u)

static void fill_quux13(struct model *m)
{
	fill_quux(m);
	m->rev13 = 1;
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		m->amem[i] = poison(IMG_SEL_AMEM, i, 40);
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		m->mmem[i] = poison(IMG_SEL_MMEM, i, 40);
	for (unsigned i = 0; i < IMG_QUUX_PDL_WORDS; ++i)
		m->pdl[i] = poison(IMG_SEL_PDL, i, 40);
	for (unsigned i = 0; i < IMG_DMEM_WORDS_13; ++i)
		m->dmem[i] = (uint32_t)poison(IMG_SEL_DMEM, i, 17);
	for (unsigned i = 0; i < IMG_L1_WORDS_13; ++i)
		m->l1[i] = (uint32_t)poison(IMG_SEL_MAP1, i, 7);
	for (unsigned i = 0; i < IMG_L2_WORDS_13; ++i)
		m->l2[i] = (uint32_t)poison(IMG_SEL_MAP2, i, 28);
	m->regs[IMG_RG_Q] = poison(IMG_SEL_REGS, IMG_RG_Q, 40);
	m->regs[IMG_RG_VMA] = poison(IMG_SEL_REGS, IMG_RG_VMA, 40);
	m->regs[IMG_RG_MD] = poison(IMG_SEL_REGS, IMG_RG_MD, 40);
	m->regs[IMG_RG_MDHELD] = poison(IMG_SEL_REGS, IMG_RG_MDHELD, 40);
	m->regs[IMG_RG_LVMO] = Q_LVMO_13;
	m->regs[IMG_RG_FLAGS] |= 1ull << IMG_F_OVERFLOW;
	m->disk[1] = Q_DISK_CLP_13;
	// Words 7 and 10: the rings' bases, 28 bits each.
	m->fd[0] = Q_FD_CMD_BASE;
	m->fd_resp_13 = Q_FD_RESP_BASE_13;
	m->macro[IMG_RG_QUUX_M31_W - IMG_RG_QUUX_MACRO] = poison(10, 33, 40);
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

// The body of `img` as it would be written, into `out` (freed by the caller).
static void body_of(const struct cadr_image *img, const struct chk_declared *d, struct chk *out)
{
	chk_init(out);
	chk_rtl_body(out, img, d);
}

// The one byte at which two bodies differ, or -1 when they differ at none or
// at more than one, or in length.
static long one_byte_apart(const struct chk *a, const struct chk *b)
{
	if (a->len != b->len)
		return -1;
	long at = -1;
	for (size_t i = 0; i < a->len; ++i) {
		if (a->p[i] == b->p[i])
			continue;
		if (at >= 0)
			return -1;
		at = (long)i;
	}
	return at;
}

// **THE RUN STATE, HELD ON THE TWO SLOTS muir READS IT FROM.**  `found` is a
// machine as the window read it; returns 0, or -1 having said why.
static int run_state_check(const struct cadr_image *found, const struct chk_declared *d,
			   const char *which)
{
	const uint64_t both = (1ull << IMG_F_RUN) | (1ull << IMG_F_SRUN);
	struct cadr_image halted = *found, run_only = *found, srun_only = *found;
	halted.flags &= ~both;
	run_only.flags = (found->flags & ~both) | (1ull << IMG_F_RUN);
	srun_only.flags = (found->flags & ~both) | (1ull << IMG_F_SRUN);
	struct chk b0, br, bs, bw, bh;
	body_of(&halted, d, &b0);
	body_of(&run_only, d, &br);
	body_of(&srun_only, d, &bs);
	const long at_run = one_byte_apart(&b0, &br), at_srun = one_byte_apart(&b0, &bs);
	int bad_here = 0;
	if (at_run < 0 || at_srun < 0 || at_run == at_srun ||
	    b0.p[at_run] != 0 || br.p[at_run] != 1 || b0.p[at_srun] != 0 || bs.p[at_srun] != 1) {
		fprintf(stderr, "%s: RUN and SRUN are not one byte each, 0 and 1 (%ld, %ld)\n",
			which, at_run, at_srun);
		bad_here = 1;
	}
	// Found running and halted for the read: both set, and nothing else moved.
	struct cadr_image ran = halted;
	chk_rtl_run_state(&ran, 1);
	body_of(&ran, d, &bw);
	if (!bad_here) {
		int ok = bw.len == b0.len && bw.p[at_run] == 1 && bw.p[at_srun] == 1;
		for (size_t i = 0; ok && i < b0.len; ++i)
			if ((long)i != at_run && (long)i != at_srun && bw.p[i] != b0.p[i])
				ok = 0;
		if (!ok) {
			fprintf(stderr, "%s: a machine found running is not written with RUN %u and "
				"SRUN %u set and the rest as read\n", which,
				bw.len > (size_t)at_run ? bw.p[at_run] : 9u,
				bw.len > (size_t)at_srun ? bw.p[at_srun] : 9u);
			bad_here = 1;
		}
	}
	// Found halted: written exactly as read.
	struct cadr_image stood = halted;
	chk_rtl_run_state(&stood, 0);
	body_of(&stood, d, &bh);
	if (bh.len != b0.len || memcmp(bh.p, b0.p, b0.len) != 0) {
		fprintf(stderr, "%s: a machine found halted is not written as it was read\n", which);
		bad_here = 1;
	}
	chk_free(&b0);
	chk_free(&br);
	chk_free(&bs);
	chk_free(&bw);
	chk_free(&bh);
	if (bad_here) {
		fprintf(stderr, "checkpoint: FAIL: %s's run state before the halt\n", which);
		++bad;
		return -1;
	}
	printf("checkpoint: %s's run state: RUN at byte %ld and SRUN at byte %ld of the body, "
	       "both set for a machine found running and as read for one found halted\n",
	       which, at_run, at_srun);
	return 0;
}

// ---- QUUX's main memory in its own words ----------------------------------

static void memory_fail(const char *what, const char *got, const char *want)
{
	fprintf(stderr, "checkpoint: FAIL: main memory: %s: [%s], wanting [%s]\n", what, got, want);
	++bad;
}

// How many lines of the sidecar at `side` are `line` (`whole` 1) or begin
// with it (`whole` 0).
static int sidecar_has(const char *side, const char *line, int whole)
{
	FILE *f = fopen(side, "r");
	char buf[8192];
	int n = 0;
	while (f && fgets(buf, sizeof buf, f)) {
		buf[strcspn(buf, "\n")] = '\0';
		n += whole ? strcmp(buf, line) == 0 : strncmp(buf, line, strlen(line)) == 0;
	}
	if (f)
		fclose(f);
	return n;
}

static void memory_words_check(const char *side)
{
	char got[128], err[512];
	// What a person reads: the CADR's boards, QUUX's amount.
	{
		const struct { int quux; unsigned units; const char *want; } t[] = {
			{0, 32, "32 memory boards"}, {0, 60, "60 memory boards"}, {0, 1, "1 memory board"},
			{1, 512, "32MW of main memory"}, {1, 1024, "64MW of main memory"},
			{1, 32, "2MW of main memory"}, {1, 60, "3840KW of main memory"}};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			bind_memory_words(t[i].quux, t[i].units, got, sizeof got);
			if (strcmp(got, t[i].want) != 0)
				memory_fail("said", got, t[i].want);
		}
	}
	// What the flags take: each machine's own, and the other's refused by
	// name; QUUX's in whole megawords with the unit, within the board's room.
	{
		const struct {
			int quux; const char *boards, *size; int rc; unsigned units; const char *says;
		} t[] = {
			{0, NULL, NULL, 0, 0, NULL},
			{1, NULL, NULL, 0, 0, NULL},
			{0, "32", NULL, 0, 32, NULL},
			{0, "60", NULL, 0, 60, NULL},
			{0, "1", NULL, 0, 1, NULL},
			{0, "61", NULL, 2, 0, "1 to 60"},
			{0, "0", NULL, 2, 0, "1 to 60"},
			{0, "32x", NULL, 2, 0, "1 to 60"},
			{0, NULL, "2MW", 2, 0, "--main-memory-size is QUUX's"},
			{1, "512", NULL, 2, 0, "--boards is the CADR's"},
			{1, "512", NULL, 2, 0, "--main-memory-size <n>MW, such as --main-memory-size 32MW"},
			{1, NULL, "32MW", 0, 512, NULL},
			{1, NULL, "1MW", 0, 16, NULL},
			{1, NULL, "33MW", 2, 0, "1MW to 32MW"},
			{1, NULL, "0MW", 2, 0, "1MW to 32MW"},
			{1, NULL, "32", 2, 0, "main memory is given in megawords, with the unit MW, such as 32MW"},
			{1, NULL, "32M", 2, 0, "main memory is given in megawords, with the unit MW, such as 32MW"},
			{1, NULL, "2048KW", 2, 0, "main memory is given in megawords, with the unit MW, such as 32MW"},
			{1, "512", "32MW", 2, 0, "--boards is the CADR's"},
		};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			unsigned units = 0xDEADu;
			err[0] = '\0';
			const int rc = bind_memory_asked(t[i].quux, t[i].boards, t[i].size, 512u, &units,
							 err, sizeof err);
			char what[160];
			snprintf(what, sizeof what, "%s with --boards %s --main-memory-size %s",
				 t[i].quux ? "QUUX" : "the CADR", t[i].boards ? t[i].boards : "-",
				 t[i].size ? t[i].size : "-");
			if (rc != t[i].rc) {
				snprintf(got, sizeof got, "%d, %s", rc, err);
				memory_fail(what, got, t[i].rc ? "refused" : "taken");
			} else if (rc == 0 && units != t[i].units) {
				char w[32];
				snprintf(got, sizeof got, "%u units", units);
				snprintf(w, sizeof w, "%u units", t[i].units);
				memory_fail(what, got, w);
			} else if (t[i].says && !strstr(err, t[i].says)) {
				memory_fail(what, err, t[i].says);
			}
		}
	}
	// What the sidecar records: QUUX's amount under muir's flag's name, and
	// the CADR's boards; read back to the same units either way.
	{
		const struct { int quux; unsigned units; const char *line, *not; } t[] = {
			{1, 512, "main-memory-size: 32MW", "boards:"},
			{1, 60, "main-memory-size: 3840KW", "boards:"},
			{0, 32, "boards: 32", "main-memory-size:"}};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			struct binding b, rd;
			bind_init(&b);
			b.quux = t[i].quux;
			b.boards = t[i].units;
			b.revision = t[i].quux ? 13u : 0u;
			b.sync_k = t[i].quux ? 5u : 0u;
			snprintf(b.checkpoint, sizeof b.checkpoint, "m.chk");
			if (bind_write(&b, side, err, sizeof err) != 0) {
				memory_fail("a sidecar written", err, "written");
				continue;
			}
			if (sidecar_has(side, t[i].line, 1) != 1)
				memory_fail("the sidecar's memory line", "absent", t[i].line);
			if (sidecar_has(side, t[i].not, 0) != 0)
				memory_fail("the other machine's memory line in the sidecar", t[i].not, "none");
			bind_init(&rd);
			if (bind_read(&rd, side, err, sizeof err) != 0 || rd.boards != t[i].units) {
				snprintf(got, sizeof got, "%u units %s", rd.boards, err);
				memory_fail("the sidecar's memory read back", got, t[i].line);
			}
		}
		// A sidecar written before QUUX's line was says boards, and is read.
		FILE *f = fopen(side, "w");
		if (f) {
			fprintf(f, "format: %s\nmachine: quux\nboards: 512\n", BIND_FORMAT);
			fclose(f);
		}
		struct binding rd;
		bind_init(&rd);
		if (bind_read(&rd, side, err, sizeof err) != 0 || rd.boards != 512u)
			memory_fail("an older QUUX sidecar's boards", err, "512 units");
		// An amount the sidecar cannot be held to is refused, not guessed.
		static const char *const badv[] = {"32", "32M", "2.5MW", "100KW", "MW"};
		for (unsigned i = 0; i < sizeof badv / sizeof badv[0]; ++i) {
			f = fopen(side, "w");
			if (f) {
				fprintf(f, "format: %s\nmachine: quux\nmain-memory-size: %s\n",
					BIND_FORMAT, badv[i]);
				fclose(f);
			}
			bind_init(&rd);
			if (bind_read(&rd, side, err, sizeof err) == 0)
				memory_fail("a sidecar's amount that is no amount", badv[i], "refused");
		}
		remove(side);
	}
}

int main(int argc, char **argv)
{
	// **THE SCRATCH DIRECTORY IS NOT OPTIONAL.**  Half of what this file
	// checks --- the sidecar written, read back and made to notice a pack
	// that has moved --- needs somewhere to put three small files, and a
	// check that quietly does less when an argument is missing is the
	// failure this repository keeps meeting.  So it is demanded.
	//
	// **AND NEITHER ARE QUUX'S DISKS.**  A QUUX disk is bound by its footers,
	// and the files that hold that to something are muir's `data/quux-disk*`,
	// made by qemu and never by this program; the directory holding them is
	// the second argument, and the Makefile checks their digests first.
	if (argc < 3) {
		fprintf(stderr, "usage: checkpoint_test <scratch directory> <QUUX's disks, "
			"muir's data/> [<CADR checkpoint to write> [<QUUX checkpoint to write> "
			"[<QUUX revision 13's to write>]]]\n");
		return 2;
	}
	const char *work = argv[1];
	const char *q8 = argv[2];
	const char *out = argc > 3 ? argv[3] : NULL;
	const char *quux_out = argc > 4 ? argv[4] : NULL;
	const char *quux13_out = argc > 5 ? argv[5] : NULL;
	const char *quux13hd_out = argc > 6 ? argv[6] : NULL;

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
		// A CADR pack is declared to the checkpoint as its geometry.
		{
			uint32_t dc = 0, dh = 0, db = 0;
			bind_declared(&w.u[3], &dc, &dh, &db);
			if (dc != 815 || dh != 5 || db != 17)
				fail("a CADR pack's declared geometry", (uint64_t)dc * dh * db, 815u * 5u * 17u);
		}
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

		// **A QUUX BINDING SAYS SO, AND ITS RESUME IS QUUX'S, WHOLE.**  The
		// line survives the file, and the command it prints is muir's
		// `quux` with everything muir needs to take the file as the board
		// ran it: the revision, which `quux` reads from the environment
		// and refuses a checkpoint of the other at, and K, which muir
		// refuses a checkpoint of another K at --- the Arty Z7-20's revision
		// 13 runs at 5 and muir's default is 4.  No memory flag: muir
		// builds the machine with the checkpoint's own memory.  The CADR's
		// is `cadr` with its timing model and its boards.  Held whole,
		// every word, against the line a person pastes.
		struct binding qb;
		bind_init(&qb);
		qb.quux = 1;
		qb.boards = 512;
		qb.revision = 13;
		qb.sync_k = 5;
		qb.video_width = 1920;
		qb.video_height = 1080;
		qb.running = 1;
		qb.u[0].present = 1;
		snprintf(qb.u[0].path, sizeof qb.u[0].path, "/mnt/card/packs/disk-pack-0.img");
		snprintf(qb.u[0].format, sizeof qb.u[0].format, "vhd-dynamic");
		qb.present = 1;
		snprintf(qb.checkpoint, sizeof qb.checkpoint, "%s", stand);
		char cmd[4096];
		static const char want13[] = "MUIR_QUUX_REVISION=13 quux --rtl --sync-cycle-ticks 5 "
			"--video-size 1920x1080 --disk-pack /mnt/card/packs/disk-pack-0.img,0 --resume q.chk";
		bind_resume_command(&qb, "q.chk", cmd, sizeof cmd);
		if (strcmp(cmd, want13) != 0) {
			fprintf(stderr, "QUUX revision 13's resume line is [%s], wanting [%s]\n", cmd, want13);
			fail("QUUX revision 13's resume line", 1, 0);
		}
		if (bind_write(&qb, side, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || !rd.quux)
			fail("the sidecar lost the machine", 0, 1);
		else if (rd.video_width != 1920 || rd.video_height != 1080)
			fail("the sidecar lost the video controller's size",
			     ((uint64_t)rd.video_width << 16) | rd.video_height, (1920u << 16) | 1080u);
		else if (rd.revision != 13 || rd.sync_k != 5 || rd.running != 1)
			fail("the sidecar lost the revision, K or the run state",
			     ((uint64_t)rd.revision << 16) | (rd.sync_k << 8) | (unsigned)rd.running,
			     (13u << 16) | (5u << 8) | 1u);
		else {
			// `--verify` prints the line from the sidecar it read.
			bind_resume_command(&rd, "q.chk", cmd, sizeof cmd);
			if (strcmp(cmd, want13) != 0)
				fail("the resume line from the sidecar read back", 1, 0);
		}
		// And the file says it in words a person reads.
		{
			FILE *sf = fopen(side, "r");
			char line[8192];
			int saw_rev = 0, saw_k = 0, saw_run = 0, saw_resume = 0, saw_video = 0;
			while (sf && fgets(line, sizeof line, sf)) {
				line[strcspn(line, "\n")] = '\0';
				saw_rev += strcmp(line, "revision: 13") == 0;
				saw_k += strcmp(line, "sync-cycle-ticks: 5") == 0;
				saw_video += strcmp(line, "video-size: 1920x1080") == 0;
				saw_run += strcmp(line, "running: yes") == 0;
				saw_resume += strncmp(line, "resume: ", 8) == 0 &&
					      strstr(line, "MUIR_QUUX_REVISION=13 quux --rtl --sync-cycle-ticks 5 ");
			}
			if (sf)
				fclose(sf);
			if (saw_rev != 1 || saw_k != 1 || saw_run != 1 || saw_resume != 1 || saw_video != 1)
				fail("the sidecar's revision, K, running, resume and video size lines",
				     (uint64_t)saw_video * 10000 + saw_rev * 1000 + saw_k * 100 + saw_run * 10 +
				     saw_resume, 11111);
		}
		// Revision 12 at K = 4 names its own revision and K.
		qb.revision = 12;
		qb.sync_k = 4;
		qb.video_width = 1280;
		qb.video_height = 1024;
		qb.running = 0;
		bind_resume_command(&qb, "q.chk", cmd, sizeof cmd);
		if (strcmp(cmd, "MUIR_QUUX_REVISION=12 quux --rtl --sync-cycle-ticks 4 --video-size 1280x1024 "
			   "--disk-pack /mnt/card/packs/disk-pack-0.img,0 --resume q.chk") != 0)
			fail("QUUX revision 12's resume line", 1, 0);
		if (bind_write(&qb, side, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || rd.running != 0)
			fail("a halted machine's sidecar read back as running", (unsigned)rd.running, 0);
		// A sidecar written before the lines were names neither, and its
		// run state is unknown rather than a guess.
		{
			FILE *sf = fopen(side, "w");
			if (sf) {
				fprintf(sf, "format: %s\nmachine: quux\nboards: 32\n", BIND_FORMAT);
				fclose(sf);
			}
			if (bind_read(&rd, side, err, sizeof err) != 0 || rd.running != -1 ||
			    rd.revision != 0 || rd.sync_k != 0 || rd.video_width != 0)
				fail("an old sidecar's run state, revision or K", (unsigned)rd.running, 0);
			bind_resume_command(&rd, "q.chk", cmd, sizeof cmd);
			if (strcmp(cmd, "quux --rtl --resume q.chk") != 0)
				fail("an old sidecar's resume line", 1, 0);
		}
		qb.quux = 0;
		qb.revision = 0;
		qb.sync_k = 0;
		qb.boards = 32;
		qb.u[0].format[0] = '\0';
		bind_resume_command(&qb, "c.chk", cmd, sizeof cmd);
		if (strcmp(cmd, "cadr --rtl --timing-model fpga --disk-pack "
			   "/mnt/card/packs/disk-pack-0.img,0 --main-memory-boards 32 --resume c.chk") != 0) {
			fprintf(stderr, "the CADR's resume line is [%s]\n", cmd);
			fail("the CADR's resume command", 1, 0);
		}
		if (bind_write(&qb, side, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || rd.quux)
			fail("a CADR sidecar read back as QUUX's", 1, 0);
		remove(side);

		// **QUUX's MAIN MEMORY IS AN AMOUNT, NEVER BOARDS; THE CADR KEEPS
		// ITS BOARDS.**  What the program says, what its flags take and what
		// its sidecar records, each machine in its own words.  Every
		// failure here prints one line under one prefix, which is what the
		// Makefile's memory mutants are judged by.
		memory_words_check(side);

		// **THE HALT `--halt` MADE**, which `--already-halted` takes as the
		// machine running before it only at the count it was made at.
		{
			char mark[320];
			snprintf(mark, sizeof mark, "%s/halted", work);
			remove(mark);
			if (bind_halted_here(mark, 77))
				fail("no mark taken as a halt this program made", 1, 0);
			if (bind_halt_mark(mark, 0x123456789ull) != 0)
				fail("the halt mark could not be written", 1, 0);
			if (!bind_halted_here(mark, 0x123456789ull))
				fail("the halt mark at its own count", 0, 1);
			if (bind_halted_here(mark, 0x12345678Aull))
				fail("a machine that ran on since the mark taken as halted there", 1, 0);
			bind_halt_unmark(mark);
			if (bind_halted_here(mark, 0x123456789ull))
				fail("a mark taken away and still taken", 1, 0);
		}
	}

	// ---- a QUUX disk, bound by its footers and never by its size -------
	//
	// QUUX's disk is block-disk's one pack, unit 0, of any size, raw, a
	// fixed VHD or a dynamic VHD (contract Q8).  So under `--machine quux`
	// the drive bay's `disk-pack-0.img` is a pack when `cadr-disk-packs`'s own
	// test says it is a QUUX disk --- the footers, the dynamic header, the
	// block count --- and the CADR's rule, a T-300's or a T-80's size, would
	// find none of them.  Each of muir's three is put in a bay of its own
	// under the same name, as the card holds it.
	{
		char bay[256], pack0[320], err[512];
		snprintf(bay, sizeof bay, "%s/q8-bay", work);
		snprintf(pack0, sizeof pack0, "%s/disk-pack-0.img", bay);
		mkdir(bay, 0755);
		static const struct { const char *file, *format; } disks[] = {
			{ "quux-disk.img", "raw" },
			{ "quux-disk-fixed.vhd", "fixed-vhd" },
			{ "quux-disk-dynamic.vhd", "dynamic-vhd" },
		};
		for (unsigned i = 0; i < sizeof disks / sizeof disks[0]; ++i) {
			char src[512];
			snprintf(src, sizeof src, "%s/%s", q8, disks[i].file);
			struct stat st;
			if (stat(src, &st) != 0) {
				fprintf(stderr, "no %s: QUUX's disks are muir's data/quux-disk*\n", src);
				++bad;
				continue;
			}
			remove(pack0);
			if (symlink(src, pack0) != 0) {
				fprintf(stderr, "%s: %s\n", pack0, strerror(errno));
				++bad;
				continue;
			}
			struct binding q;
			bind_init(&q);
			q.quux = 1;
			err[0] = '\0';
			const int n = bind_scan(&q, bay, err, sizeof err);
			if (n != 1 || !q.u[0].present || q.present != 1) {
				fprintf(stderr, "QUUX's %s was not bound as unit 0: %d found, %s\n",
					disks[i].file, n, err);
				++bad;
				continue;
			}
			if (strcmp(q.u[0].format, disks[i].format) != 0) {
				fprintf(stderr, "QUUX's %s was bound as \"%s\", and it is %s\n",
					disks[i].file, q.u[0].format, disks[i].format);
				++bad;
			}
			// Every one of the three holds the same disk of 8 MiB.
			if (q.u[0].blocks != 8192)
				fail("a QUUX disk's blocks", q.u[0].blocks, 8192);
			if (q.u[0].bytes != (uint64_t)st.st_size)
				fail("a QUUX disk's bytes, the file's", q.u[0].bytes, (uint64_t)st.st_size);
			// And it is declared to the checkpoint as its blocks, which is
			// the disk size muir holds the resuming disk to.
			{
				uint32_t dc = 0, dh = 0, db = 0;
				bind_declared(&q.u[0], &dc, &dh, &db);
				if ((uint64_t)dc * dh * db != 8192)
					fail("a QUUX disk's declared blocks", (uint64_t)dc * dh * db, 8192);
			}
			if (bind_digest(&q, err, sizeof err) != 0) {
				fprintf(stderr, "QUUX's %s could not be digested: %s\n", disks[i].file, err);
				++bad;
			}
			// The sidecar carries what the file is, and its resume is QUUX's
			// with the disk as unit 0.
			char side[400], cmd[4096];
			snprintf(side, sizeof side, "%s/q8.chk%s", work, BIND_SUFFIX);
			snprintf(q.checkpoint, sizeof q.checkpoint, "%s/q8.chk", work);
			struct binding rd;
			if (bind_write(&q, side, err, sizeof err) != 0 ||
			    bind_read(&rd, side, err, sizeof err) != 0) {
				fprintf(stderr, "a QUUX sidecar: %s\n", err);
				++bad;
			} else if (!rd.quux || !rd.u[0].present ||
				   strcmp(rd.u[0].format, disks[i].format) != 0 ||
				   rd.u[0].blocks != 8192 ||
				   strcmp(rd.u[0].sha256, q.u[0].sha256) != 0) {
				fprintf(stderr, "a QUUX sidecar lost the disk's format, blocks or "
					"digest: \"%s\", %llu\n", rd.u[0].format,
					(unsigned long long)rd.u[0].blocks);
				++bad;
			}
			remove(side);
			bind_resume_command(&q, "q8.chk", cmd, sizeof cmd);
			char want[400];
			snprintf(want, sizeof want, " --disk-pack %s,0 ", pack0);
			if (strncmp(cmd, "quux --rtl ", 11) != 0 || !strstr(cmd, want)) {
				fprintf(stderr, "QUUX's resume command: %s\n", cmd);
				++bad;
			}
			// Named by hand, the same.
			struct binding h;
			bind_init(&h);
			h.quux = 1;
			char spec[400];
			snprintf(spec, sizeof spec, "%s,0", pack0);
			if (bind_add(&h, spec, err, sizeof err) != 0 ||
			    strcmp(h.u[0].format, disks[i].format) != 0) {
				fprintf(stderr, "QUUX's %s named by hand: %s\n", disks[i].file, err);
				++bad;
			}
			// And the CADR's rule finds no pack in it: 8 MiB is no drive's.
			struct binding c;
			bind_init(&c);
			err[0] = '\0';
			if (bind_scan(&c, bay, err, sizeof err) != 0 || c.present != 0)
				fail("the CADR bound a QUUX disk", c.present, 0);
		}
		// A VHD whose footer does not check is no disk: the fixed one copied,
		// one byte of its footer changed.
		remove(pack0);
		{
			char src[512];
			snprintf(src, sizeof src, "%s/quux-disk-fixed.vhd", q8);
			FILE *in = fopen(src, "rb"), *o = fopen(pack0, "wb");
			int c;
			while (in && o && (c = fgetc(in)) != EOF)
				fputc(c, o);
			if (in)
				fclose(in);
			if (o) {
				fseek(o, -512 + 20, SEEK_END);
				fputc(0x5a, o);
				fclose(o);
			}
			struct binding q;
			bind_init(&q);
			q.quux = 1;
			err[0] = '\0';
			if (bind_scan(&q, bay, err, sizeof err) != 0 || q.present != 0)
				fail("a VHD whose footer does not check was bound", q.present, 0);
			else if (!strstr(err, "checksum"))
				fprintf(stderr, "a VHD whose footer does not check was refused "
					"without saying why: \"%s\"\n", err), ++bad;
		}
		remove(pack0);
		rmdir(bay);
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
	//   geometry   1 + 1 + 1 + 1 + 1  = 5        (Geometry::CADR: 5, 10, no
	//                                             multiply and divide, no tick,
	//                                             no fused return: version 49)
	//   timers     3 * (1+1+1+4+8)    = 45       (Timers::new: three
	//                                             interval timers off,
	//                                             periodic, interrupt
	//                                             enable 0, period 0, no
	//                                             deadline; version 45)
	//   macro_dispatch 4 + 2 + (8+4096) + 4 + 4 + 1 + 1 = 4120
	//                                            (MacroDispatch::default:
	//                                             the register, the index,
	//                                             1,024 entries, the base
	//                                             copies, nothing armed:
	//                                             version 49)
	//   rtc        1                  = 1        (Rtc::Host, the option
	//                                             absent: version 42)
	//   file_device 4 + 4*4 + 3*2 + 1 = 27      (FileDevice::new: four
	//                                             flags, the rings, the
	//                                             indexes, no due time:
	//                                             version 43)
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
	//                                            (the board's tag, the video size, the
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
	//   bus        1 + busint: which bus, `Bus::Cadr` (version 40), then
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
	//   memstart_fetch                 = 1        (version 49)
	//
	// The arithmetic is written out rather than summed by hand so that a
	// reader can check one line instead of one number.
	{
		const size_t machine_part =
			8200 + 131080 + 14 + 10 + 78120 + 29 + 8200 + 5 + 45 + 4120 + 1 + 27 + 1 + 8200 + 4 +
			262152 + 125 + 1 + 69 + 1 + 135263 + 1 + 253 + 13 + 16;
		const size_t rtl_part =
			208 + 32 + 19 + 21 + 1 + 163 + 1 + 32 + 25 + 26 + 24 + 28 + 1;
		// **A MUTANT IS JUDGED BY muir AND NOT HERE.**  Six of the seven
		// keep the body's length and one does not, and the point of
		// building them is what the ROUND TRIP does with them, so this
		// assertion --- which belongs to the real thing --- stands down.
		if (!chk_rtl_mutation() && body.len != machine_part + rtl_part)
			fail("the body's length", body.len, machine_part + rtl_part);
		machine_body_len = machine_part + rtl_part;
	}

	// ---- the run state before the halt ----------------------------------
	//
	// **A MACHINE FOUND RUNNING IS WRITTEN RUNNING, AND ONE FOUND HALTED AS
	// IT WAS READ.**  The program halts a running machine to read it, so the
	// window gives RUN and SRUN clear; `chk_rtl_run_state` puts both back.
	// Where the two bytes are is found here independently of that function:
	// the image with each flag set alone against the image with neither,
	// each one byte apart --- so the assertion below is on the two slots muir
	// reads RUN and SRUN from, and not on whatever the function touched.
	if (run_state_check(&img, &decl, "the CADR") != 0)
		return 1;

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
		if (qi.qx.fd_cmd_base != Q_FD_CMD_BASE || qi.qx.fd_resp_base != Q_FD_RESP_BASE ||
		    qi.qx.fd_cmd_log2 != Q_FD_CMD_LOG2 || qi.qx.fd_resp_log2 != Q_FD_RESP_LOG2)
			fail("the file device's rings", qi.qx.fd_cmd_base, Q_FD_CMD_BASE);
		if (qi.qx.fd_cmd_prod != 1 || qi.qx.fd_cmd_cons != 1 || qi.qx.fd_resp_cons != 1)
			fail("the file device's indexes", qi.qx.fd_cmd_prod, 1);
		if (!qi.qx.fd_enabled || !qi.qx.fd_ie || qi.qx.fd_refused || !qi.qx.fd_fault ||
		    qi.qx.fd_busy || qi.qx.fd_handles != 0)
			fail("the file device's flags", qi.qx.fd_enabled, 1);
		// **THE REFUSAL, muir's**: none for this machine; one for a handle
		// open, one for a command queued, and one for both.
		{
			char why[160];
			if (chk_rtl_refusal(&qi, why, sizeof why))
				fail("a checkpoint refused with no handle open and nothing queued", 1, 0);
			struct cadr_image t = qi;
			t.qx.fd_handles = 1;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with a handle open", 0, 1);
			t.qx.fd_handles = 0;
			t.qx.fd_cmd_prod = 2;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with a command queued", 0, 1);
			t.qx.fd_cmd_prod = 0;
			t.qx.fd_cmd_cons = 0xFFFFu;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with a command queued across the wrap", 0, 1);
			t.qx.fd_cmd_prod = 0x1234;
			t.qx.fd_cmd_cons = 0x1234;
			if (chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint refused with the indexes equal", 1, 0);
			struct cadr_image c = t;
			c.quux = 0;
			c.qx.fd_handles = 3;
			if (chk_rtl_refusal(&c, why, sizeof why))
				fail("a CADR's checkpoint refused on a file device it has not", 1, 0);
		}
		for (size_t i = 0; i < IMG_BOARD_WORDS; ++i)
			qi.main[i] = (uint32_t)poison(12, (unsigned)i, 32);
		for (size_t i = 0; i < IMG_QUUX_TV_WORDS; ++i)
			qi.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);

		// QUUX's drive bay: one pack, unit 0, block-disk's disk.
		struct chk_declared qdecl = decl;
		qdecl.present = 1u;
		qdecl.cylinders[0] = Q_DISK_CYLINDERS;
		qdecl.heads[0] = Q_DISK_HEADS;
		qdecl.blocks_per_track[0] = Q_DISK_BPT;
		struct chk qb;
		chk_init(&qb);
		chk_rtl_body(&qb, &qi, &qdecl);
		// **THE BODY'S LENGTH, AGAIN AN ARITHMETIC EXPRESSION**: the
		// CADR's, and what QUUX has that it has not --- block-disk's
		// forty-four bytes after its flag, the video controller's 8,192
		// words past the CADR display's 32,768, the five key words
		// waiting, and K and L after the timing model's tag; and in place
		// of the bus interface's 163 bytes, the memory port's (version
		// 40): its state, direction,
		// address and flag, the cache's shape, counts and 512 empty sets,
		// and the two timings and two instants; and block-disk's disk
		// (version 41), its size in blocks and a count of none written.
		// The file device's fields are the CADR's too (version 43), at
		// the same widths, so they add nothing here.  And revision 12's
		// (version 49): the operand address armed, its ARG and delta, and
		// M 31's word armed; and the prefetch's two options after the
		// memory port's instants, both absent.
		const size_t quux_len = cadr_body_len + 44 + 8192 * 4 + 5 * 4 + 2 -
			163 + (1 + 1 + 4 + 1) + (4 * 3 + 8 + 1 + 8 + 8 + 512 * 4) + 8 * 4 +
			(4 + 8) + (1 + 1) + 4 + (1 + 1);
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
				for (unsigned t = 0; t < IMG_QUUX_TIMERS; ++t) {
					const struct quux_timer *b = &mv.qx.timer[t];
					const struct qtimer *s = &q->timer[t];
					const uint64_t got = b->m + b->pre + (uint64_t)(b->us - 1u) * 100u;
					const int up = b->m > s->first_rise;
					const uint64_t want = up ? s->first_rise +
						((b->m - s->first_rise) / s->period + 1u) * s->period
						: s->first_rise;
					// A one-shot that has risen has stopped: the flag up,
					// nothing counting.
					if (s->one_shot && up) {
						if (!b->sticky || b->live)
							fail("a risen one-shot, read on a moving clock", b->live, 0);
					} else if (got != want || b->sticky != up) {
						fail("a timer's next rise, read on a moving clock", got, want);
					}
					if (b->one_shot != s->one_shot || b->ie != s->ie || b->period_us != s->period_us)
						fail("a timer's mode, enable or period, read on a moving clock",
						     b->period_us, s->period_us);
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

		// ---- QUUX revision 13 ------------------------------------------
		//
		// The same window at revision 13, entry 21 saying so; the file goes
		// where the fifth argument says and `build/checkpoint.quux.pass`
		// holds it to muir's own and has muir load it and save it again.
		fill_quux13(q);
		if (ro_quux_revision(&qr) != 13)
			fail("revision 13's window read as another revision", ro_quux_revision(&qr), 13);
		struct cadr_image q13;
		if (img_alloc_revision(&q13, 1, 1, 13) != 0) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		if (ro_read_machine(&qr, &q13) != 0) {
			fail("the window would not give revision 13 up", qr.stale, 0);
			return 1;
		}
		// The transport, at revision 13's sizes and in its 40-bit words.
		// **Not under a mutant**, three of which are of the transport and
		// are held by muir's own file instead (`chk_rtl.c`'s mutants 28,
		// 29): asserting here what the mutant took out would call it
		// broken, not caught.
		if (!chk_rtl_mutation() && (q13.amem[IMG_AMEM_WORDS - 1] != q->amem[IMG_AMEM_WORDS - 1] ||
		    q13.pdl[IMG_QUUX_PDL_WORDS - 1] != q->pdl[IMG_QUUX_PDL_WORDS - 1] ||
		    q13.q != q->regs[IMG_RG_Q] || q13.qx.m31_w != q->macro[IMG_RG_QUUX_M31_W - IMG_RG_QUUX_MACRO]))
			fail("a revision 13 word", q13.amem[IMG_AMEM_WORDS - 1], q->amem[IMG_AMEM_WORDS - 1]);
		if (q13.dmem[IMG_DMEM_WORDS_13 - 1] != q->dmem[IMG_DMEM_WORDS_13 - 1] ||
		    q13.l1_map[IMG_L1_WORDS_13 - 1] != q->l1[IMG_L1_WORDS_13 - 1] ||
		    q13.l2_map[IMG_L2_WORDS_13 - 1] != q->l2[IMG_L2_WORDS_13 - 1])
			fail("revision 13's dispatch memory and maps' last entries",
			     q13.l1_map[IMG_L1_WORDS_13 - 1], q->l1[IMG_L1_WORDS_13 - 1]);
		if (!chk_rtl_mutation() &&
		    (q13.qx.fd_cmd_base != Q_FD_CMD_BASE || q13.qx.fd_resp_base != Q_FD_RESP_BASE_13))
			fail("revision 13's ring bases", q13.qx.fd_resp_base, Q_FD_RESP_BASE_13);
		if (!img_flag(&q13, IMG_F_OVERFLOW))
			fail("the overflow flag", 0, 1);
		// Main memory, packed storage: word i at bytes 5i to 5i + 4.
		uint8_t *packed = malloc((size_t)IMG_BOARD_WORDS * 5u);
		if (!packed) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		for (size_t i = 0; i < IMG_BOARD_WORDS; ++i) {
			const uint64_t v = poison(12, (unsigned)i, 40);
			for (unsigned b = 0; b < 5; ++b)
				packed[5 * i + b] = (uint8_t)(v >> (8 * b));
		}
		q13.main13 = packed;
		for (size_t i = 0; i < IMG_QUUX_TV_WORDS; ++i)
			q13.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);
		struct chk_declared q13decl = decl;
		q13decl.present = 1u;
		q13decl.cylinders[0] = Q_DISK_CYLINDERS;
		q13decl.heads[0] = Q_DISK_HEADS;
		q13decl.blocks_per_track[0] = Q_DISK_BPT;
		struct chk qb13;
		chk_init(&qb13);
		chk_rtl_body(&qb13, &q13, &q13decl);
		// **THE BODY'S LENGTH**: revision 12's, and a byte more for each
		// word --- A, M, the PDL buffer, Q, VMA, MD, M 31's armed word, L
		// and the two idle bus words, and main memory, which is the hole
		// --- the dispatch memory's and both maps' further entries, the
		// width and the overflow flag after the geometry, and the cache's
		// 256 sets in place of 512.  muir's own for the same machine is
		// 794,267 bytes.
		const size_t quux13_len = quux_len + IMG_AMEM_WORDS + IMG_MMEM_WORDS +
			(IMG_DMEM_WORDS_13 - IMG_DMEM_WORDS) * 4 + IMG_QUUX_PDL_WORDS + 3 +
			(IMG_L1_WORDS_13 - IMG_L1_WORDS) * 4 + 2 + 1 +
			(IMG_L2_WORDS_13 - IMG_QUUX_L2_WORDS) * 4 + IMG_BOARD_WORDS + 3 - 256 * 4;
		if (!chk_rtl_mutation() && (qb13.len + qb13.hole_len != quux13_len ||
					    qb13.hole_len != (size_t)IMG_BOARD_WORDS * 5u))
			fail("revision 13's body's length", qb13.len + qb13.hole_len, quux13_len);
		// The run state again, on revision 13's body, whose slots are its own.
		if (run_state_check(&q13, &q13decl, "QUUX revision 13") != 0)
			return 1;
		if (quux13_out && chk_write_file(quux13_out, "rtl", 1, &qb13) != 0) {
			perror(quux13_out);
			return 1;
		}
		// **AND THE HOLE IS READ WHERE IT STANDS**: the file written from
		// a body with main memory in its hole is the file written from the
		// same body with main memory copied in, byte for byte.
		{
			struct chk flat;
			chk_init(&flat);
			flat.word_bytes = qb13.word_bytes;
			for (size_t i = 0; i < qb13.hole_at; ++i)
				chk_u8(&flat, qb13.p[i]);
			for (size_t i = 0; i < qb13.hole_len; ++i)
				chk_u8(&flat, packed[i]);
			for (size_t i = qb13.hole_at; i < qb13.len; ++i)
				chk_u8(&flat, qb13.p[i]);
			char a[320], b[320];
			snprintf(a, sizeof a, "%s/hole.chk", work);
			snprintf(b, sizeof b, "%s/flat.chk", work);
			if (chk_write_file(a, "rtl", 1, &qb13) != 0 || chk_write_file(b, "rtl", 1, &flat) != 0)
				fail("the two revision 13 files could not be written", 1, 0);
			else {
				FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
				int same = fa && fb;
				for (int ca = 0, cb = 0; same && (ca != EOF || cb != EOF);) {
					ca = fgetc(fa);
					cb = fgetc(fb);
					same = ca == cb;
				}
				if (fa)
					fclose(fa);
				if (fb)
					fclose(fb);
				if (!same)
					fail("the file with main memory in place and the one with it copied", 1, 0);
				remove(a);
				remove(b);
			}
			chk_free(&flat);
		}
		printf("checkpoint: QUUX revision 13, %zu bytes of body and %zu of main memory "
		       "where it stands, %lu reads over a modeled window%s%s\n", qb13.len,
		       qb13.hole_len, qr.reads, quux13_out ? ", wrote " : "",
		       quux13_out ? quux13_out : "");
		// **AND THE SAME MACHINE WITH THE KRIA KR260'S VIDEO CONTROLLER**,
		// 1920 by 1080 (contract HD): the image sized by the bitstream's
		// word 39, its 64,800 words carried and its size written where
		// muir's `Tv::save` writes it, so that muir resumes the file under
		// `--video-size 1920x1080` and refuses it under another.  The file
		// goes where the sixth argument says and `build/checkpoint.quux.pass`
		// holds it to muir's own for the same machine at that size.
		{
			struct cadr_image hd;
			if (img_alloc_video(&hd, 1, 1, 13, 1920u, 1080u) != 0) {
				fprintf(stderr, "out of memory\n");
				return 1;
			}
			if (ro_read_machine(&qr, &hd) != 0) {
				fail("the window would not give revision 13 up at 1920 by 1080", qr.stale, 0);
				return 1;
			}
			if (!chk_rtl_mutation() &&
			    (hd.tv_words != 64800u || hd.video_width != 1920u || hd.video_height != 1080u))
				fail("the image's video controller at 1920 by 1080, in words", hd.tv_words, 64800);
			hd.main13 = packed;
			for (size_t i = 0; i < hd.tv_words; ++i)
				hd.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);
			struct chk hb;
			chk_init(&hb);
			chk_rtl_body(&hb, &hd, &q13decl);
			// Revision 13's body and the 23,840 further words of the
			// buffer, four bytes each.
			if (!chk_rtl_mutation() && hb.len + hb.hole_len != quux13_len + (64800u - 40960u) * 4u)
				fail("the body's length at 1920 by 1080", hb.len + hb.hole_len,
				     quux13_len + (64800u - 40960u) * 4u);
			if (quux13hd_out && chk_write_file(quux13hd_out, "rtl", 1, &hb) != 0) {
				perror(quux13hd_out);
				return 1;
			}
			// And a size no QUUX has is refused.
			struct cadr_image no;
			if (img_alloc_video(&no, 1, 1, 13, 1900u, 1080u) == 0) {
				fail("a video controller 1900 wide, taken", 1900, 0);
				img_free(&no);
			}
			printf("checkpoint: and at 1920 by 1080, %zu bytes of body%s%s\n", hb.len,
			       quux13hd_out ? ", wrote " : "", quux13hd_out ? quux13hd_out : "");
			chk_free(&hb);
			img_free(&hd);
		}
		free(packed);
		chk_free(&qb13);
		img_free(&q13);
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
