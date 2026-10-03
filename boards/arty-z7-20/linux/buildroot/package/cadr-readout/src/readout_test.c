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
	uint64_t amem[IMG_AMEM_WORDS];
	uint32_t mmem[IMG_MMEM_WORDS];
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
	// Page 2's word 37 as the fabric reads it: the memory boards' count
	// under its marker, or 0 for a fabric older than the word.
	uint32_t boards_word;
	uint32_t video_word;
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
	// **THE MACHINE STOPS A LITTLE AFTER THE WRITE THAT STOPS IT**, as the
	// board does: the write lands at the machine's next look, and the
	// microcycles already under way retire after the store has returned.
	// Measured on the Arty Z7-20 over 3,000 halts: none to two more
	// microcycles, the last up to five reads (about 0.8 us) after the
	// store.  `tail_at` is the tick each of them retires at; zero is none.
	uint64_t tail_at[2];
	// A machine that ignores the write altogether: nothing here can stop
	// it, and the program must say so and leave it as it found it.
	int ignores_halt;
	// TICKS as the model held it when the program last read it: the clock
	// runs on, so the value to compare with is the one at the read.
	uint64_t ticks_read;
	// A halted machine that still retires one microcycle every
	// `trickle_every` ticks, the next at `trickle_next`, until the tick
	// `trickle_until` if that is not zero; zero `trickle_every` is none.  It
	// puts the settle window's edges under test: a counter that never stands
	// for 2 ms is running, and one that does, however late in the 10 ms, is
	// halted.
	uint64_t trickle_every, trickle_next, trickle_until;
	// The register table's entry 21, QUUX's signature, when it is set: a
	// CADR answers `RO_NO_MEMORY` there.
	uint64_t quux_id;
};

// **THE FABRIC'S TIME RUNS WHILE THE PROGRAM READS**, 16 ticks a read, the
// board's figure (66 single-word reads took 1,030 ticks).  A model whose
// clock stood still would let a check that waits on TICKS wait for ever.
#define MODEL_TICKS_PER_READ 16u

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
	case IMG_SEL_REGS:
		if (a == IMG_RG_QUUX_ID && m->quux_id)
			return m->quux_id;
		return a < 21 ? m->regs[a] : RO_NO_MEMORY;
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
// own: the page hash table word at physical 0o103757, which turned out to be
// the faulting virtual address rather than a page table word.
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
	m->ticks += MODEL_TICKS_PER_READ;
	for (unsigned i = 0; i < 2; ++i)
		if (m->tail_at[i] && m->ticks >= m->tail_at[i]) {
			++m->cycles;
			m->tail_at[i] = 0;
		}
	if (m->trickle_every && m->ticks >= m->trickle_next
	    && (!m->trickle_until || m->ticks < m->trickle_until)) {
		++m->cycles;
		m->trickle_next += m->trickle_every;
	}
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
		m->ticks_read = m->ticks;
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
	case RO_BOARDS: return m->boards_word ? m->boards_word : RO_UNMAPPED;
	case RO_VIDEO: return m->video_word ? m->video_word : RO_UNMAPPED;
	default: return RO_UNMAPPED;
	}
}

static void model_write(struct readout *r, unsigned word, uint32_t v)
{
	struct model *m = r->ctx;
	if (word == RO_ADDR)
		m->ro_addr = v & 0x3FFFFu;
	else if (word == RO_SPY(RO_SPY_CLK_W)) {
		const int run = (v & RO_CLK_RUN) != 0;
		// The board's tail: the two microcycles under way retire 40 and
		// 80 ticks after the store, the first after the program's first
		// read of CYCLES and the second before its seventeenth.
		if (m->running && !run && !m->ignores_halt) {
			m->tail_at[0] = m->ticks + 40;
			m->tail_at[1] = m->ticks + 80;
		}
		if (!m->ignores_halt || run)
			m->running = run;
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
	if (m->tail_at[0] || m->tail_at[1])
		fail("the halt was judged before the machine's last microcycles "
		     "retired", 1, 0);
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
	if (img.ticks != m->ticks_read)
		fail("TICKS", img.ticks, m->ticks_read);
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

	// ---- which revision of QUUX ---------------------------------------------
	//
	// Entry 21 carries MACHINE-ID's <15:0> on revision 13 and 0 on revision
	// 12; anything else under QUUX's signature is neither, and the CADR's
	// `RO_NO_MEMORY` is the CADR.
	{
		const uint64_t sig = ((uint64_t)IMG_QUUX_MARK << 32) | (4ull << 24) | (1ull << 16);
		const struct { uint64_t id; int rev; } cases[] = {
			{ 0, 0 }, { sig, 12 }, { sig | IMG_QUUX_ID_13, 13 },
			{ sig | 0x00C4u, -1 }, { sig | 0x00D5u, -1 },
		};
		for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
			m->quux_id = cases[i].id;
			const int rev = ro_quux_revision(&r);
			if (rev != cases[i].rev)
				fail("the revision entry 21 says", (unsigned long long)rev,
				     (unsigned long long)cases[i].rev);
		}
		m->quux_id = 0;
	}

	// ---- revision 13's words, 40 bits of the window's 48 ---------------------
	//
	// The same window read as revision 13's machine: A, M and the PDL buffer
	// whole at 40 bits and nothing above, the dispatch memory and both map
	// levels at revision 13's depths, and the registers that are words.
	{
		for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
			m->amem[i] = poison(IMG_SEL_AMEM, i, 48);
		struct cadr_image w;
		if (img_alloc_revision(&w, 1, 1, 13) != 0) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		if (w.dmem_words != 4096 || w.l1_words != 8192 || w.l2_words != 4096 ||
		    w.word_bits != 40 || w.main)
			fail("revision 13's arrays", w.dmem_words, 4096);
		// The model is the CADR's arrays, and what is past them reads 0.
		// Through the machine's own reader, whose QUUX half needs the
		// clocks this model has not: the words, and not QUUX's own.
		w.quux = 0;
		if (ro_read_machine(&r, &w) != 0)
			fail("revision 13's window would not give its words up", r.stale, 0);
		for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
			if (w.amem[i] != poison(IMG_SEL_AMEM, i, 40)) {
				fail("an A memory word at 40 bits", w.amem[i],
				     poison(IMG_SEL_AMEM, i, 40));
				break;
			}
		if (w.q != (m->regs[IMG_RG_Q] & 0xFFFFFFFFFFull) ||
		    w.md_held != (m->regs[IMG_RG_MDHELD] & 0xFFFFFFFFFFull))
			fail("Q at 40 bits", w.q, m->regs[IMG_RG_Q] & 0xFFFFFFFFFFull);
		if (w.dmem[IMG_DMEM_WORDS - 1] != m->dmem[IMG_DMEM_WORDS - 1] ||
		    w.dmem[IMG_DMEM_WORDS] != 0 || w.l1_map[IMG_L1_WORDS] != 0)
			fail("the dispatch memory past 2,048", w.dmem[IMG_DMEM_WORDS], 0);
		img_free(&w);
		for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
			m->amem[i] = (uint32_t)poison(IMG_SEL_AMEM, i, 32);
	}

	// ---- and the machine is started again ---------------------------------
	ro_start(&r);
	if (!m->running)
		fail("the machine was not started again", 0, 1);

	// ---- the whole halt as the programs take it: `ro_halt_to_read` -------
	//
	// Three machines: one running, which is halted and said to have been;
	// one already halted, which is left alone; and one that ignores the
	// write, which must be refused AND LEFT RUNNING, as it was found.  The
	// last is the board's fault of 29 Sep: the program said the machine
	// had not stopped, exited, and left it halted with nobody to start it.
	{
		int was_running = -1;
		m->clk_writes = 0;
		if (ro_halt_to_read(&r, &was_running) != 0)
			fail("a running machine was not halted for reading", 1, 0);
		if (was_running != 1)
			fail("was_running for a running machine", was_running, 1);
		if (m->running || m->clk_writes != 1)
			fail("writes of the clock control register for one halt",
			     m->clk_writes, 1);

		m->clk_writes = 0;
		if (ro_halt_to_read(&r, &was_running) != 0 || was_running != 0)
			fail("an already halted machine", was_running, 0);
		if (m->clk_writes != 0)
			fail("writes to an already halted machine", m->clk_writes, 0);

		ro_start(&r);
		m->ignores_halt = 1;
		m->clk_writes = 0;
		const unsigned long before = r.reads;
		if (ro_halt_to_read(&r, &was_running) != -1)
			fail("a machine that would not stop was read", 1, 0);
		if (!m->running)
			fail("a machine that would not stop was left halted", 0, 1);
		if (m->clk_writes != 2)
			fail("writes of the clock control register: the halt and "
			     "the start", m->clk_writes, 2);
		// Bounded: the checks wait on the fabric's time, not for ever.
		if (r.reads - before > 600000u)
			fail("reads spent refusing a machine that would not stop",
			     r.reads - before, 600000u);
		m->ignores_halt = 0;
	}

	// ---- the settle window's edges ---------------------------------------
	//
	// Written in ticks, not in `RO_HALT_SETTLE_TICKS`, so that the model
	// does not move with the constant it is holding: 2 ms is 200,000 ticks
	// and 10 ms is 1,000,000.  A machine that retires one microcycle every
	// 1.99 ms never stands for 2 ms and is running; one that retires one
	// every 2.01 ms stands for 2 ms within the 10 ms and is halted; and one
	// that retires them for 7.5 ms and then stops stands for 2 ms by 9.5 ms
	// and is halted too.  A window that is not restarted when CYCLES moves
	// calls the first one halted.
	{
		m->running = 0;
		m->trickle_every = 199000u;
		m->trickle_next = m->ticks + m->trickle_every;
		if (ro_is_halted(&r))
			fail("a machine retiring a microcycle every 1.99 ms reported "
			     "halted", 1, 0);
		m->trickle_every = 201000u;
		m->trickle_next = m->ticks + m->trickle_every;
		if (!ro_is_halted(&r))
			fail("a machine retiring a microcycle every 2.01 ms reported "
			     "running", 0, 1);
		m->trickle_every = 1000u;
		m->trickle_next = m->ticks + m->trickle_every;
		m->trickle_until = m->ticks + 750000u;
		if (!ro_is_halted(&r))
			fail("a machine that stood for 2 ms from 7.5 ms on reported "
			     "running", 0, 1);
		m->trickle_every = 0;
		m->trickle_until = 0;
		ro_start(&r);
	}

	// ---- how many memory boards, page 2's word 37 -------------------------
	//
	// A checkpoint is sized by it, so a count read wrong is a checkpoint
	// that drops memory or invents it.  The ends, the default and one past
	// it read as themselves, and revision 13's 512 and 1,024 with them; a
	// word with no marker --- a fabric older than the word --- and a count
	// outside 1 to 1,024 read 0, which the caller takes as the old fabric's
	// fixed 32.
	{
		const struct { uint32_t word; unsigned want; } cases[] = {
			{0x42440001u, 1}, {0x42440020u, 32}, {0x42440021u, 33}, {0x4244003Cu, 60},
			{0x4244003Du, 61}, {0x4244007Fu, 127}, {0x42440121u, 289}, {0x42440200u, 512},
			{0x42440400u, 1024}, {0x42440401u, 0}, {0x424407FFu, 0}, {0x42440821u, 0},
			{0x42440000u, 0}, {0x4D420021u, 0}, {0x00000021u, 0}, {0, 0}};
		for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
			m->boards_word = cases[i].word;
			const unsigned got_boards = ro_main_boards(&r);
			if (got_boards != cases[i].want)
				fail("the memory boards from word 37", got_boards, cases[i].want);
		}
		m->boards_word = 0;
	}

	// ---- QUUX's video controller, page 2's word 39 ------------------------
	//
	// A checkpoint and its image are sized by it (contract HD): the marker
	// over 1920 by 1080 or 1280 by 1024 reads as that size; no marker --- a
	// CADR's, or QUUX older than the word --- reads 0; the marker over a
	// size no QUUX has reads -1.  And the image is allocated at the size it
	// is given, its buffer the height times the width over 32.
	{
		const struct { uint32_t word; int want; unsigned w, h; } cases[] = {
			{(0x356u << 22) | (1920u << 11) | 1080u, 1, 1920, 1080},
			{(0x356u << 22) | (1280u << 11) | 1024u, 1, 1280, 1024},
			{(0x356u << 22) | (1024u << 11) | 768u, 1, 1024, 768},
			{(0x356u << 22) | (1900u << 11) | 1080u, -1, 0, 0},
			{(0x356u << 22) | (1952u << 11) | 1080u, -1, 0, 0},
			{(0x356u << 22) | (1920u << 11) | 1081u, -1, 0, 0},
			{(0x356u << 22) | (0u << 11) | 1080u, -1, 0, 0},
			{(0x357u << 22) | (1920u << 11) | 1080u, 0, 0, 0},
			{0x42440200u, 0, 0, 0}, {0, 0, 0, 0}};
		for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
			struct cadr_video v = { 0, 0, 0, 0 };
			m->video_word = cases[i].word;
			const int got = ro_video(&r, &v);
			if (got != cases[i].want || (got == 1 && (v.width != cases[i].w || v.height != cases[i].h ||
								 v.words != cases[i].h * (cases[i].w / 32u))))
				fail("the video controller from word 39", ((uint64_t)(unsigned)got << 32) |
				     (v.width << 16) | v.height, ((uint64_t)(unsigned)cases[i].want << 32) |
				     (cases[i].w << 16) | cases[i].h);
		}
		m->video_word = 0;
		struct cadr_image hd;
		if (img_alloc_video(&hd, 1, 1, 13, 1920u, 1080u) != 0 || hd.tv_words != 64800u ||
		    hd.video_width != 1920u || hd.video_height != 1080u)
			fail("an image of QUUX at 1920 by 1080, its buffer's words", hd.tv_words, 64800);
		else
			img_free(&hd);
		if (img_alloc_revision(&hd, 1, 1, 13) != 0 || hd.tv_words != 40960u || hd.video_width != 1280u)
			fail("an image of QUUX at the old size, its buffer's words", hd.tv_words, 40960);
		else
			img_free(&hd);
		if (img_alloc_video(&hd, 1, 1, 13, 1900u, 1080u) == 0) {
			fail("an image of QUUX 1900 wide, taken", 1900, 0);
			img_free(&hd);
		}
		if (img_alloc_video(&hd, 1, 0, 12, 0, 0) != 0 || hd.tv_words != IMG_TV_WORDS || hd.video_width != 0)
			fail("the CADR's image, its buffer's words", hd.tv_words, IMG_TV_WORDS);
		else
			img_free(&hd);
	}

	// ---- QUUX's main memory is an amount, never boards --------------------
	//
	// The same word holds QUUX's main memory in 64K-word units, sixteen a
	// megaword, and what a person reads of it is the amount: whole
	// megawords, or kilowords when the units are not a whole number of
	// them, as muir's own report has it.  A flag takes `<n>MW` alone, as
	// muir's `--main-memory-size` does: digits, then the unit, and nothing
	// else --- never a bare number, never a bare M, no other unit, no space.
	{
		const struct { unsigned units; const char *want; } amounts[] = {
			{16, "1MW"}, {32, "2MW"}, {512, "32MW"}, {1024, "64MW"},
			{60, "3840KW"}, {1, "64KW"}, {33, "2112KW"}};
		for (unsigned i = 0; i < sizeof amounts / sizeof amounts[0]; ++i) {
			char got[32];
			ro_main_amount(amounts[i].units, got, sizeof got);
			if (strcmp(got, amounts[i].want) != 0) {
				fprintf(stderr, "QUUX's main memory of %u units reads \"%s\", wanting \"%s\"\n",
					amounts[i].units, got, amounts[i].want);
				fail("QUUX's main memory as an amount", i, ~0u);
			}
		}
		const struct { const char *text; int ok; unsigned units; } flags[] = {
			{"32MW", 1, 512}, {"1MW", 1, 16}, {"64MW", 1, 1024}, {"2MW", 1, 32},
			{"32", 0, 0}, {"32M", 0, 0}, {"32mw", 0, 0}, {"32Mw", 0, 0},
			{"MW", 0, 0}, {"3.5MW", 0, 0}, {"32 MW", 0, 0}, {" 32MW", 0, 0},
			{"32KW", 0, 0}, {"32MB", 0, 0}, {"-1MW", 0, 0}, {"+1MW", 0, 0},
			{"0x20MW", 0, 0}, {"32MWW", 0, 0}, {"", 0, 0},
			{"99999999999MW", 0, 0}, {"268435456MW", 0, 0}};
		for (unsigned i = 0; i < sizeof flags / sizeof flags[0]; ++i) {
			unsigned units = 0xDEADu;
			const int rc = ro_parse_megawords(flags[i].text, &units);
			if (flags[i].ok && (rc != 0 || units != flags[i].units)) {
				fprintf(stderr, "\"%s\" is refused or read as %u units, wanting %u\n",
					flags[i].text, units, flags[i].units);
				fail("an amount in megawords this must take", i, flags[i].units);
			} else if (!flags[i].ok && rc == 0) {
				fprintf(stderr, "\"%s\" is taken as %u units, and is no amount in MW\n",
					flags[i].text, units);
				fail("a form of main memory this must refuse", i, ~0u);
			}
		}
		if (ro_parse_megawords(NULL, NULL) == 0)
			fail("no text taken as an amount", 1, 0);
	}

	printf("readout: %ld words compared through a modeled window, %lu reads "
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
