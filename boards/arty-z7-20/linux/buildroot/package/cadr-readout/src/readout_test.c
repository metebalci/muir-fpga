// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The readout program's core, against a model of the window, on the build
// host --- no board, no fabric, nothing but a C compiler.
//
// **WHAT THIS HOLDS AND WHAT `build/readout.pass` HOLDS.**  That one is the
// FABRIC: the second read ports, the pipeline and the echo, against the
// arrays themselves.  This one is the TRANSPORT: that the program writes the
// address where the window takes it, reads the three words in the order that
// latches them together, and **refuses a word whose echo is not the address
// it asked for.**  The two meet at one place and it is worth naming --- the
// selector numbers, the two values that mean nothing, and the three word
// offsets are `cadr_microcycle.sv`'s and `cadr_console.sv`'s, repeated in
// `readout.h` and `cadr_image.h` because C cannot read Verilog.  A number
// moved in one and not the other is caught by neither check, which is why
// they are written down in the module and not derived.
//
// The machine behind the model is a poison, injective in the memory and the
// address --- the same one `tb/cadr_readout_tb.cpp` uses --- for the reason
// every stimulus in this repository is: a machine of zeros lets a reader that
// asked for the wrong word agree with it.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cadr_image.h"
#include "readout.h"

static long bad;
static void fail(const char *what, unsigned long long got, unsigned long long want)
{
	fprintf(stderr, "%s is 0x%llx, the reference says 0x%llx\n", what, got, want);
	++bad;
}

struct model {
	uint64_t imem[IMG_IMEM_WORDS], prom[IMG_PROM_WORDS];
	uint32_t amem[IMG_AMEM_WORDS], mmem[IMG_MMEM_WORDS];
	uint32_t pdl[IMG_PDL_WORDS], spc[IMG_SPC_WORDS];
	uint32_t dmem[IMG_DMEM_WORDS], l1[IMG_L1_WORDS], l2[IMG_L2_WORDS];
	uint16_t opcs[IMG_OPCS];
	uint64_t regs[21];
	// The transaction audit's nine words, packed as the fabric packs them.
	uint64_t audit[IMG_AUDIT_WORDS];
	// **AND A WAY TO TAKE THE MARKER OFF THEM**, because the property that
	// matters about this selector is that the program refuses a word which
	// does not say who wrote it: a bitstream older than the audit answers
	// the window's own `A5A5_5A5A_A5A5` here and a reader that believed it
	// would report a clean instrument off a board that has none.
	int audit_unmarked;
	uint32_t ro_addr;
	uint32_t hi_latch_cycles, hi_latch_ticks;
	uint64_t cycles, ticks;
	int running;
	// **THE ECHO, DELIBERATELY STALE FOR THE FIRST `stale_for` READS.**  A
	// program that did not compare it would take a word for the address
	// before the one it asked for and never know; this is how the check
	// asks whether it does.
	int stale_for;
	// What the last write of the clock control register said, so that the
	// halt and the start can be asserted rather than assumed.
	int clk_writes;
};

static uint64_t model_word(struct model *m, unsigned sel, unsigned a)
{
	switch (sel) {
	case IMG_SEL_IMEM: return a < IMG_IMEM_WORDS ? m->imem[a] : 0;
	case IMG_SEL_PROM: return a < IMG_PROM_WORDS ? m->prom[a] : 0;
	case IMG_SEL_AMEM: return a < IMG_AMEM_WORDS ? m->amem[a] : 0;
	case IMG_SEL_MMEM: return a < IMG_MMEM_WORDS ? m->mmem[a] : 0;
	case IMG_SEL_PDL:  return a < IMG_PDL_WORDS ? m->pdl[a] : 0;
	case IMG_SEL_SPC:  return a < IMG_SPC_WORDS ? m->spc[a] : 0;
	case IMG_SEL_DMEM: return a < IMG_DMEM_WORDS ? m->dmem[a] : 0;
	case IMG_SEL_MAP1: return a < IMG_L1_WORDS ? m->l1[a] : 0;
	case IMG_SEL_MAP2: return a < IMG_L2_WORDS ? m->l2[a] : 0;
	case IMG_SEL_OPCS: return a < IMG_OPCS ? m->opcs[a] : 0;
	case IMG_SEL_REGS: return a < 21 ? m->regs[a] : RO_NO_MEMORY;
	case IMG_SEL_AUDIT:
		if (m->audit_unmarked)
			return RO_NO_MEMORY;
		return a < IMG_AUDIT_WORDS ? m->audit[a]
					   : ((uint64_t)IMG_AUDIT_MARK << 32);
	default: return RO_NO_MEMORY;
	}
}

// The audit's record as the fabric lays it out, with every field distinct so
// that a field taken out of the wrong word shows.  The numbers are the board's
// own: CLAUDE.md's page hash table word at physical 0o103757, which turned out
// to be the faulting virtual address rather than a page table word.
#define AUD_MARK ((uint64_t)IMG_AUDIT_MARK << 32)
static void fill_audit(struct model *m)
{
	m->audit[0] = AUD_MARK | ((uint64_t)9u << 16) | (1ull << 15) | 5ull;
	m->audit[1] = AUD_MARK | ((uint64_t)0x48u << 25) |
		      ((uint64_t)IMG_AUD_PORT_EXTRA << 22) | 0103757ull;
	m->audit[2] = AUD_MARK | 0x1810FDF4ull;
	m->audit[3] = AUD_MARK | 0x261FC9F9ull;
	m->audit[4] = AUD_MARK | 0x261FC9F9ull;
	m->audit[5] = AUD_MARK | 0x0A1FC941ull;
	m->audit[6] = AUD_MARK | 176119628ull;
	m->audit[7] = AUD_MARK | ((uint64_t)012345u << 16) | 023555ull;
	m->audit[8] = AUD_MARK | ((uint64_t)77u << 16) | (1ull << 15) | 1234ull;
}

static uint32_t model_read(struct readout *r, unsigned word)
{
	struct model *m = r->ctx;
	const unsigned sel = (m->ro_addr >> 14) & 0xFu;
	const unsigned a = m->ro_addr & 0x3FFFu;
	switch (word) {
	case RO_IDENT: return RO_IDENT_WORD;
	case RO_STAT: return 0;
	case RO_CYCLES:
		m->hi_latch_cycles = (uint32_t)(m->cycles >> 32);
		// A running machine retires microcycles between two reads,
		// which is what `ro_is_halted` looks for.
		if (m->running)
			m->cycles += 1000;
		return (uint32_t)m->cycles;
	case RO_CYCLESH: return m->hi_latch_cycles;
	case RO_TICKS:
		m->hi_latch_ticks = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case RO_TICKSH: return m->hi_latch_ticks;
	case RO_ADDR:
		if (m->stale_for > 0) {
			--m->stale_for;
			// One address short: the word for the one before it.
			return (m->ro_addr - 1u) & 0x3FFFFu;
		}
		return m->ro_addr;
	case RO_DATA_LO: return (uint32_t)model_word(m, sel, a);
	case RO_DATA_HI: return (uint32_t)(model_word(m, sel, a) >> 32) & 0xFFFFu;
	default: return RO_UNMAPPED;
	}
}

static void model_write(struct readout *r, unsigned word, uint32_t v)
{
	struct model *m = r->ctx;
	if (word == RO_ADDR)
		m->ro_addr = v & 0x3FFFFu;
	else if (word == RO_SPY(RO_SPY_CLK_W)) {
		m->running = (v & RO_CLK_RUN) != 0;
		++m->clk_writes;
	}
}

// `tb/cadr_readout_tb.cpp`'s poison, so that the two checks disagree about
// nothing.
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
	for (unsigned i = 0; i < 21; ++i)
		m->regs[i] = poison(IMG_SEL_REGS, i, 48);
	m->cycles = 0x1234567890ull;
	m->ticks = 0x9876543210ull;
	m->running = 1;
	fill_audit(m);
}

int main(void)
{
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

	// ---- IDENT, and the window's own two values -------------------------
	uint32_t got = 0;
	if (ro_ident_ok(&r, &got) != 0)
		fail("IDENT", got, RO_IDENT_WORD);

	// ---- the echo, which the program must compare ------------------------
	//
	// This is the property the whole window is built around, and the one a
	// reader is most likely to skip: read the two halves, believe them, and
	// never ask whether they are the address that was asked for.
	{
		m->stale_for = 1;
		uint64_t w = 0;
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) == 0)
			fail("a word came back for an address that was not asked "
			     "for and the program took it", 1, 0);
		if (r.stale != 1)
			fail("the stale read was not counted", r.stale, 1);
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) != 0)
			fail("an honest read was refused", 1, 0);
		if (w != poison(IMG_SEL_IMEM, 7, 48))
			fail("the word", w, poison(IMG_SEL_IMEM, 7, 48));
	}

	// ---- the halt, asserted rather than assumed --------------------------
	//
	// A machine that goes on retiring microcycles is a machine whose
	// memories move under the reader.  The program halts first and this is
	// what says the model would have noticed if it did not.
	if (ro_is_halted(&r))
		fail("a running machine reported halted", 1, 0);
	ro_halt(&r);
	if (!ro_is_halted(&r))
		fail("a halted machine reported running", 0, 1);
	if (m->clk_writes != 1)
		fail("writes of the clock control register", m->clk_writes, 1);

	// ---- every word of every memory --------------------------------------
	//
	// A selector read into the wrong array, or a length off by one, shows
	// here; the poison is injective in both so there is nowhere to hide.
	long words = 0;
	const unsigned sels[] = { IMG_SEL_IMEM, IMG_SEL_PROM, IMG_SEL_AMEM,
				  IMG_SEL_MMEM, IMG_SEL_PDL, IMG_SEL_SPC,
				  IMG_SEL_DMEM, IMG_SEL_MAP1, IMG_SEL_MAP2,
				  IMG_SEL_OPCS };
	const unsigned depths[] = { IMG_IMEM_WORDS, IMG_PROM_WORDS,
				    IMG_AMEM_WORDS, IMG_MMEM_WORDS,
				    IMG_PDL_WORDS, IMG_SPC_WORDS,
				    IMG_DMEM_WORDS, IMG_L1_WORDS,
				    IMG_L2_WORDS, IMG_OPCS };
	const unsigned bits[] = { 48, 48, 32, 32, 32, 21, 17, 5, 24, 14 };
	for (unsigned i = 0; i < 10 && bad < 10; ++i) {
		for (unsigned a = 0; a < depths[i]; ++a) {
			uint64_t w = 0;
			if (ro_word(&r, sels[i], a, &w) != 0) {
				fail("an echo", sels[i], a);
				break;
			}
			const uint64_t want = poison(sels[i], a, bits[i]);
			if (w != want) {
				fail("a word", w, want);
				break;
			}
			++words;
		}
	}

	// ---- the whole machine, through `ro_read_machine` ---------------------
	struct cadr_image img;
	if (img_alloc(&img, 1) != 0) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	if (ro_read_machine(&r, &img) != 0)
		fail("the window would not give the machine up", r.stale, 0);
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
	if (img.imem[4095] != m->imem[4095])
		fail("a control store word", img.imem[4095], m->imem[4095]);
	if (img.l2_map[1023] != m->l2[1023])
		fail("the last level-2 map entry", img.l2_map[1023], m->l2[1023]);
	img_free(&img);

	// ---- the transaction audit, at its own selector ------------------------
	//
	// **THE MARKER IS THE PROPERTY AND IT IS TESTED BOTH WAYS.**  A reading
	// of "no faults" off a bitstream with no audit in it would be the worst
	// thing this window could do, and the only thing separating the two is
	// `B05A` in the top sixteen bits of every word.  So the unmarked case is
	// run FIRST, and it must be refused.
	{
		struct cadr_audit a;
		unsigned mark = 0;
		m->audit_unmarked = 1;
		if (ro_audit(&r, &a, &mark) == 0)
			fail("a window with no audit behind it was read as an "
			     "audit", 1, 0);
		if (mark != 0xA5A5u)
			fail("the refused marker", mark, 0xA5A5u);
		m->audit_unmarked = 0;

		memset(&a, 0, sizeof a);
		if (ro_audit(&r, &a, &mark) != 0)
			fail("an honest audit was refused", 1, 0);
		if (a.faults != 5)
			fail("the fault count", a.faults, 5);
		if (a.stalled != 9)
			fail("the stall count", a.stalled, 9);
		if (a.clause != IMG_AUD_PORT_EXTRA)
			fail("the first clause", a.clause, IMG_AUD_PORT_EXTRA);
		if (a.seen != 0x48u)
			fail("the clause bitmap", a.seen, 0x48u);
		if (a.phys != 0103757u)
			fail("the physical address", a.phys, 0103757u);
		if (a.addr != 0x1810FDF4u)
			fail("the byte address", a.addr, 0x1810FDF4u);
		if (a.data != 0x261FC9F9u)
			fail("the word on the write-data lines", a.data,
			     0x261FC9F9u);
		if (a.vma != 0x261FC9F9u)
			fail("VMA", a.vma, 0x261FC9F9u);
		if (a.md != 0x0A1FC941u)
			fail("MD", a.md, 0x0A1FC941u);
		if (a.micro != 176119628u)
			fail("the microcycle", a.micro, 176119628u);
		if (a.pc != 012345u)
			fail("PC", a.pc, 012345u);
		if (a.opc != 023555u)
			fail("OPC", a.opc, 023555u);
		if (a.port_reads != 1234u)
			fail("the port's answered reads", a.port_reads, 1234u);
		if (a.port_writes != 77u)
			fail("the port's answered writes", a.port_writes, 77u);
	}

	// ---- and the machine is started again ---------------------------------
	ro_start(&r);
	if (!m->running)
		fail("the machine was not started again", 0, 1);

	printf("readout: %ld words compared through a modelled window, %lu reads "
	       "and %lu writes, %lu refused for a stale echo, and the "
	       "transaction audit read back field for field with an unmarked "
	       "one refused\n",
	       words, r.reads, r.writes, r.stale);
	free(m);
	if (bad) {
		fprintf(stderr, "FAIL: %ld mismatches\n", bad);
		return 1;
	}
	printf("PASS\n");
	return 0;
}
