// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console program, held on the build host to a MODEL of the slave: no
// board, no fabric, nothing but a C compiler.
//
//     console_test
//
// **A MODEL AND NOT THE RTL.**  What follows `rtl/plumbing/cadr_console.sv` at this
// slice is the two pages of sixteen words, the latch of each counter's high
// half by the read of its low half, UNMAPPED for an address in neither page,
// the sticky lost bit in STAT and bit 16 of a page-1 read meaning the
// diagnostic cycle was not answered; and behind the diagnostic bus a modelled
// machine whose CYCLES counter advances only while RUN is set.  What it holds
// the program to is the face's CONTRACT, and the RTL is held to the same
// contract by `tb/cadr_console_tb.cpp`.  `feeder_test.c` says the same of
// itself at its lines 51-62 and this is the same seam one program along.
//
// **THE MODELLED REGISTER BLOCK DROPS BITS 4:1 OF A CLOCK CONTROL WRITE**,
// because `cadr_spy_registers.sv` does and `cadr_microcycle.sv` has neither
// `SSTEP` nor `SSDONE`.  So `step` cannot move the modelled machine either,
// and the test's job there is to hold that the program SAYS the machine did
// not move rather than returning quietly.
//
// **WHAT IS CHECKED.**  IDENT, and the two other words a wrong board answers
// with.  The EMIO tally guard rejecting all ones and all zeros and taking
// only the marker bits.  `halt` then `status` reporting halted with SRUN
// down; `start` then `status` reporting running, with CYCLES having moved and
// the report saying so because it moved and not because a flag said it would.
// `step` reporting that the machine did not move and why.  The FLAG-1 and
// FLAG-2 decoders against known words, including FLAG-1's low byte through
// its inverting driver and FLAG-2's four floating ones.  The CYCLES/CYCLESH
// order --- that the low read latches the high half, that the pair is one
// instant across a carry, and that reading the high word alone gets a stale
// latch.  All sixteen registers read back as the model holds them, so that a
// register index off by one has nowhere to hide.  And a lost cycle reported
// as lost and never mistaken for data.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "console_face.h"

static int bad;
static unsigned checks;

static void fail(int line, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void fail(int line, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "console_test.c:%d: FAIL: ", line);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++bad;
}

#define CHECK(cond, ...)                                  \
	do {                                              \
		++checks;                                 \
		if (!(cond))                              \
			fail(__LINE__, __VA_ARGS__);      \
	} while (0)

// ---- the model of the slave --------------------------------------------

// A microcycle is 29 ticks at normal speed: 145 ns, 5 ns a tick.
#define TICKS_PER_MICROCYCLE 29u
// A diagnostic cycle is DIAGNOSTIC_NS = 250 ns = 50 ticks; the module holds
// the bus for that plus the drop, 260 ns.
#define TICKS_PER_DIAGNOSTIC 52u

struct model {
	// The modelled machine.
	int run;			/* the clock control register's bit 0 */
	uint64_t cycles, ticks;
	uint16_t ir[3], opc, pc, ob[2], m[2], a[2], st[2];
	// Page 0's words 7 and 8, which are not on the diagnostic bus at all.
	// `q_latch` is the model of the RTL's own: the read of word 7 takes
	// both, and word 8 reads what it took.
	uint32_t vma, q, q_latch;
	struct cons_flag1 f1;
	struct cons_flag2 f2;
	uint16_t mode, opc_control;	/* what the write strobes loaded */
	uint16_t clk_written;		/* the last CLK write AS ASKED, bits and all */
	// The face.
	uint32_t ident;			/* what word 0 answers: a wrong board is a wrong IDENT */
	uint32_t cycles_hi_latch, ticks_hi_latch;
	int answered, lost_ever;
	int grant;			/* 0: nothing answers, every cycle is lost */
	int freeze;			/* the counters stand: for a check that reads them */
	unsigned long diag_reads, diag_writes;
};

static void model_advance(struct model *m, uint64_t t)
{
	if (m->freeze)
		return;
	// TICKS runs whether or not the machine does; CYCLES only while RUN.
	m->ticks += t;
	if (m->run)
		m->cycles += t / TICKS_PER_MICROCYCLE;
}

static uint16_t model_spy_read(struct model *m, unsigned eadr)
{
	m->f1.srun = m->run;
	switch (eadr) {
	case SPY_IR_LOW: return m->ir[0];
	case SPY_IR_MED: return m->ir[1];
	case SPY_IR_HIGH: return m->ir[2];
	// No read select is decoded at 3: the floating bus, all ones.
	case SPY_OPEN: return SPY_OPEN_READ;
	case SPY_OPC: return m->opc;
	case SPY_PC: return m->pc;
	case SPY_OB_LOW: return m->ob[0];
	case SPY_OB_HIGH: return m->ob[1];
	case SPY_FLAG_1: return cons_flag1_word(&m->f1);
	case SPY_FLAG_2: return cons_flag2_word(&m->f2);
	case SPY_M_LOW: return m->m[0];
	case SPY_M_HIGH: return m->m[1];
	case SPY_A_LOW: return m->a[0];
	case SPY_A_HIGH: return m->a[1];
	case SPY_STAT_LOW: return m->st[0];
	default: return m->st[1];
	}
}

static void model_spy_write(struct model *m, unsigned eadr, uint16_t v)
{
	// spy::write_strobe: EADR<2:0>, the decoder's G1 being HI1.
	switch (eadr & 7u) {
	case 0: case 1: case 2:
		m->ir[eadr & 3u] = v;	/* the debug IR's three halves */
		break;
	case 3:
		// **cadr_spy_registers.sv TAKES BIT 0 AND DROPS BITS 4:1.**
		// STEP, NOP11, IDEBUG and LDSTAT reach nothing in this fabric.
		m->clk_written = v;
		m->run = v & CLK_RUN ? 1 : 0;
		break;
	case 4: m->opc_control = v; break;
	case 5: m->mode = v; break;
	default: break;		/* Y6 and Y7 are not connected */
	}
}

static uint32_t model_read(struct console *c, unsigned word)
{
	struct model *m = c->ctx;
	// Time passes over a register read whatever it names.
	model_advance(m, 8);
	if (word >= 32)
		return CONS_UNMAPPED;
	if (word >= CONS_PAGE1) {
		const unsigned eadr = word - CONS_PAGE1;
		++m->diag_reads;
		model_advance(m, TICKS_PER_DIAGNOSTIC);
		if (!m->grant) {
			m->answered = 0;
			m->lost_ever = 1;
			return CONS_LOST_BIT;
		}
		m->answered = 1;
		return model_spy_read(m, eadr);
	}
	switch (word) {
	case CONS_IDENT: return m->ident;
	case CONS_STAT:
		return (m->lost_ever ? CONS_ST_LOST : 0u) | (m->answered ? CONS_ST_ANSWERED : 0u)
		     | (m->grant ? CONS_ST_GNT : 0u);
	case CONS_CYCLES:
		// The low half's read latches the high half beside it.
		m->cycles_hi_latch = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case CONS_CYCLESH: return m->cycles_hi_latch;
	case CONS_TICKS:
		m->ticks_hi_latch = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case CONS_TICKSH: return m->ticks_hi_latch;
	// The machine's reset.  This program does not write it; what it reads
	// is the key's own top half as a marker and the count of resets, and
	// the model carries it so that the sweep below can say which page-0
	// words really are UNMAPPED and which are registers.
	case CONS_RESET: return 0x52530000u;
	// **THE READ OF WORD 7 LATCHES Q BESIDE IT**, exactly as CONS_CYCLES
	// latches CONS_CYCLESH, so the pair a program reads names one
	// microcycle of the machine.  Word 8 does not arm it, or a read of 7
	// then 8 would be two instants.
	case CONS_VMA:
		m->q_latch = m->q;
		return m->vma;
	case CONS_Q: return m->q_latch;
	default: return CONS_UNMAPPED;	/* words 9-15 */
	}
}

static void model_write(struct console *c, unsigned word, uint32_t v)
{
	struct model *m = c->ctx;
	model_advance(m, 8);
	if (word >= 32 || word < CONS_PAGE1)
		return;			/* page 0 is read-only; outside is dropped */
	++m->diag_writes;
	model_advance(m, TICKS_PER_DIAGNOSTIC);
	if (!m->grant) {
		m->answered = 0;
		m->lost_ever = 1;
		return;
	}
	m->answered = 1;
	model_spy_write(m, word - CONS_PAGE1, (uint16_t)v);
}

static void model_pause(struct console *c, unsigned us)
{
	model_advance(c->ctx, (uint64_t)us * 200u);	/* 200 MHz */
}

static void attach(struct console *c, struct model *m)
{
	cons_init(c);
	c->read = model_read;
	c->write = model_write;
	c->pause = model_pause;
	c->ctx = m;
}

static void model_init(struct model *m)
{
	memset(m, 0, sizeof *m);
	m->ident = CONS_IDENT_WORD;
	m->grant = 1;
	// Sixteen distinct words, so that a register index off by one lands on
	// a word it cannot be mistaken for.  Registers 3, 8 and 9 are the
	// board's own and are not settable here.
	m->ir[0] = 0x1111; m->ir[1] = 0x2222; m->ir[2] = 0x3333;
	m->opc = 0x0444; m->pc = 0x0555;
	m->ob[0] = 0x6666; m->ob[1] = 0x7777;
	m->m[0] = 0xAAAA; m->m[1] = 0xBBBB;
	m->a[0] = 0xCCCC; m->a[1] = 0xDDDD;
	m->st[0] = 0xEEEE; m->st[1] = 0xFFF0;
	// A virtual address and a `Q` that are neither equal nor the same
	// page, so that the pair is evidence from the start: page 0o2467 and
	// page 0o1234, which differ in more than their low eight bits.  The
	// low byte differs too, so a word taken for a page or a page for a
	// word cannot read right by accident.
	m->vma = 0x00152735u;		/* page 0x1527 = 0o12447 */
	m->q = 0x00129C42u;		/* page 0x129C = 0o11234 */
	m->q_latch = 0;
}

// ---- capturing what the program says ------------------------------------

static char *cap_buf;
static size_t cap_len;
static FILE *cap;

static void capture_start(void)
{
	if (cap)
		fclose(cap);
	free(cap_buf);
	cap_buf = NULL;
	cap_len = 0;
	cap = open_memstream(&cap_buf, &cap_len);
	cadr_log_init("cadr-console: ", cap);
}

static const char *capture_end(void)
{
	fflush(cap);
	return cap_buf ? cap_buf : "";
}

// ---- the checks ---------------------------------------------------------

static void check_ident(void)
{
	struct model m;
	struct console c;
	uint32_t got = 0;
	model_init(&m);
	attach(&c, &m);
	CHECK(cons_ident_ok(&c, &got) == 0 && got == CONS_IDENT_WORD,
	      "IDENT reads 0x%08x, wanting 0x%08x (\"CONS\")", got, CONS_IDENT_WORD);

	// The proving boards' default slave, and this module's own UNMAPPED:
	// two wrong boards that must not read as a console.
	m.ident = CADR_IDENT_NONE;
	CHECK(cons_ident_ok(&c, &got) == -1 && got == CADR_IDENT_NONE,
	      "\"NONE\" is taken for a console");
	m.ident = CONS_UNMAPPED;
	CHECK(cons_ident_ok(&c, &got) == -1 && got == CONS_UNMAPPED,
	      "UNMAPPED is taken for a console");
	m.ident = 0;
	CHECK(cons_ident_ok(&c, &got) == -1, "a bus reading zeros is taken for a console");
	m.ident = 0xFFFFFFFFu;
	CHECK(cons_ident_ok(&c, &got) == -1, "a bus reading ones is taken for a console");
	m.ident = CONS_IDENT_WORD;

	// The ten words of page 0 that name nothing, and an address past the
	// window: UNMAPPED, which is neither zero nor all ones.
	CHECK(CONS_UNMAPPED == ~CONS_IDENT_WORD, "UNMAPPED is not the complement of IDENT");
	CHECK(CONS_UNMAPPED != 0 && CONS_UNMAPPED != 0xFFFFFFFFu,
	      "UNMAPPED is a value a dead or undriven bus could produce");
	// 6 is the machine's reset, 7 and 8 are VMA and Q; the rest of page 0
	// names nothing.
	for (unsigned k = 9; k < 16; ++k)
		CHECK(c.read(&c, k) == CONS_UNMAPPED, "page 0 word %u is not UNMAPPED", k);
	for (unsigned k = 6; k < 9; ++k)
		CHECK(c.read(&c, k) != CONS_UNMAPPED,
		      "page 0 word %u reads UNMAPPED, and it is a register", k);
	CHECK(c.read(&c, 40) == CONS_UNMAPPED, "an address past the window is not UNMAPPED");
}

// The guard, on words already in hand, so that no /dev/mem is needed.  The
// two readings the negative control on the board measured must both be
// refused, and the test must be the marker pattern and not "not zero".
static void check_guard(void)
{
	CHECK(cadr_tally_ok(0xFFFFFFFFu, 0xFFFFFFFFu) == 0,
	      "all ones passes the guard: an undriven EMIO pin reads exactly like four saturated counters");
	CHECK(cadr_tally_ok(0x00000000u, 0x00000000u) == 0,
	      "all zeros passes the guard: the level shifters off read the same as a dead instrument");
	CHECK(cadr_tally_ok(0x01008100u, 0x01008100u) == 1,
	      "the marker bits of a passing run are refused");
	// A tally with SOME top bit set is not a tally: only the pattern is.
	CHECK(cadr_tally_ok(0x81008100u, 0x01008100u) == 0, "bit 31 set passes the guard");
	CHECK(cadr_tally_ok(0x01008100u, 0x01000100u) == 0, "a half with bit 15 clear passes the guard");
	CHECK(cadr_tally_ok(0x0100FFFFu, 0x01008100u) == 1, "a full low field is refused");
	CHECK(CADR_TALLY_MARK == 0x00008000u && CADR_TALLY_MASK == 0x80008000u,
	      "the marker pattern has moved from what rtl/plumbing/cadr_mem_count.sv writes");
}

static void check_halt_and_start(void)
{
	struct model m;
	struct console c;
	struct cons_status st;
	model_init(&m);
	attach(&c, &m);

	// Running first, so that the halt is a change and not the start state.
	cons_start(&c);
	CHECK(m.run == 1, "start did not set RUN");
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a running machine");
	CHECK(st.running, "a machine with RUN set and CYCLES moving is not reported running");
	CHECK(st.cycles_second > st.cycles_first,
	      "CYCLES did not move over the settle: %llu then %llu",
	      (unsigned long long)st.cycles_first, (unsigned long long)st.cycles_second);
	CHECK(st.f1.srun, "FLAG-1 bit 8 is down on a running machine");
	CHECK(st.why == NULL, "a running machine was given a reason for being stopped: %s", st.why ? st.why : "");
	cons_say_status(&st);
	CHECK(strstr(capture_end(), "RUNNING") != NULL, "status did not say RUNNING");

	// CC's first act on a debuggee: 0 into the clock control register.
	cons_halt(&c);
	CHECK(m.run == 0, "halt did not clear RUN");
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a halted machine");
	CHECK(!st.running, "a machine with RUN clear is reported running");
	CHECK(st.cycles_second == st.cycles_first,
	      "CYCLES moved on a halted machine: Machine::cycles does not advance on a halted master clock");
	CHECK(!st.f1.srun, "FLAG-1 bit 8 is up on a halted machine");
	CHECK(st.why && strstr(st.why, "SRUN is down") != NULL,
	      "the halt was not attributed to the console: %s", st.why ? st.why : "(nothing)");
	cons_say_status(&st);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "NOT RUNNING") != NULL, "status did not say NOT RUNNING");
		CHECK(strstr(out, "SRUN down") != NULL, "status did not print SRUN down");
	}

	// **A MACHINE THAT STOPPED ITSELF**: RUN still set and the counter
	// standing, which is MACHRUN low under a set RUN --- what `HALT-CONS`
	// does, MIT's `(si:%halt)`.  muir's `machrun_low` tells this from the
	// console's halt and so must this.
	m.run = 1;
	m.freeze = 1;			/* MACHRUN is low: no microcycle retires */
	m.f1.err = 1;
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a self-halted machine");
	CHECK(!st.running, "a machine whose CYCLES stands is reported running");
	CHECK(st.f1.srun && st.f1.err, "FLAG-1 does not carry SRUN up with ERR up");
	CHECK(st.why && strstr(st.why, "HALT-CONS") != NULL,
	      "a self-halt was not told from the console's halt: %s", st.why ? st.why : "(nothing)");
	CHECK(strstr(st.why, "ERRSTOP itself cannot be read back") != NULL,
	      "status claimed to know ERRSTOP, which is write-only");
	cons_say_status(&st);
	CHECK(strstr(capture_end(), "SRUN up") != NULL, "status did not print SRUN up on a self-halt");

	// The statistics halt, the other self-halt, and the bus wait, which is
	// neither: a machine comes out of a bus wait by itself.
	m.f1.err = 0;
	m.f1.stathalt = 1;
	cons_status(&c, 0, &st);
	CHECK(st.why && strstr(st.why, "statistics counter") != NULL,
	      "the statistics halt was not named: %s", st.why ? st.why : "(nothing)");
	m.f1.stathalt = 0;
	m.f1.wait = 1;
	cons_status(&c, 0, &st);
	CHECK(st.why && strstr(st.why, "-WAIT") != NULL,
	      "a bus wait was not named: %s", st.why ? st.why : "(nothing)");
	CHECK(strstr(st.why, "transient") != NULL, "a bus wait was reported as a halt");
	m.f1.wait = 0;
	m.freeze = 0;

	// And the decode itself, which is what the reason turns on.
	{
		struct cons_flag1 f = { 0 };
		f.srun = 1;
		f.err = 1;
		const uint16_t w = cons_flag1_word(&f);
		const struct cons_flag1 back = cons_flag1_of(w);
		CHECK(back.srun && back.err && !back.stathalt && !back.wait,
		      "SRUN up with ERR up did not survive FLAG-1's polarities: 0x%04x", w);
	}
}

static void check_step(void)
{
	struct model m;
	struct console c;
	struct cons_step s;
	model_init(&m);
	attach(&c, &m);
	cons_halt(&c);

	m.diag_writes = 0;
	capture_start();
	cons_step(&c, 3, &s);
	cons_say_step(&s);
	const char *out = capture_end();

	CHECK(s.asked == 3, "step did not ask for three");
	CHECK(s.moved == 0, "the modelled machine moved %llu microcycle(s) on a fabric with no SSTEP",
	      (unsigned long long)s.moved);
	CHECK(s.after == s.before, "CYCLES was not sampled either side of the step");
	// The write went out as CC's CC-CLOCK writes it, and the register
	// block took bit 0 of it: that is the whole of what happened.
	CHECK(m.diag_writes == 6, "three steps are six diagnostic writes, not %lu", m.diag_writes);
	CHECK(m.clk_written == 0, "the last clock control write was 0x%04x, not the 0 of `2 then 0`", m.clk_written);
	CHECK(m.run == 0, "the step left the machine running");
	CHECK(!s.ssdone, "SSDONE is up on a fabric with no SSDONE flip flop");
	// **AND IT MUST SAY SO.**  A silent no-op is the failure this project
	// keeps meeting.
	CHECK(strstr(out, "THE MACHINE DID NOT MOVE") != NULL,
	      "step did not report that the machine did not move");
	CHECK(strstr(out, "SSTEP") != NULL, "step did not name SSTEP as the missing thing");
	CHECK(strstr(out, "docs/console.md") != NULL,
	      "step did not name docs/console.md, which carries the two hunks");

	// A step on a RUNNING machine moves the counter for the ordinary
	// reason and must not be reported as a step having worked.
	cons_start(&c);
	cons_step(&c, 1, &s);
	CHECK(m.run == 0, "`2 then 0` left RUN set: the second write is what clears it");
}

static void check_flags(void)
{
	// FLAG-1, all clear in the logical sense.  The four active-low bits of
	// the high byte read as ones and the low byte reads as zeros, the
	// driver being inverting.
	// A quiet machine: the four active-low bits of the high byte read as
	// ones (bits 15, 14, 13 and 11) and everything else reads as zero.
	#define QUIET1 0xE800u
	struct cons_flag1 f = { 0 };
	uint16_t w = cons_flag1_word(&f);
	CHECK(w == QUIET1, "a quiet FLAG-1 reads 0x%04x, wanting 0x%04x "
	      "(-WAIT, -V1PE, -V0PE and -STATHALT high, everything else low)", w, QUIET1);

	// A machine running with no error: SRUN up.
	f.srun = 1;
	w = cons_flag1_word(&f);
	CHECK(w == (QUIET1 | 0x0100u), "running with no error reads 0x%04x, wanting 0x%04x", w, QUIET1 | 0x0100u);
	CHECK(cons_flag1_of(w).srun, "bit 8 is not SRUN");
	CHECK(!cons_flag1_of(QUIET1).srun, "SRUN is up in a word with bit 8 clear");
	// Bit 9 is SSDONE and bit 8 is SRUN, and neither is the other.
	CHECK(cons_flag1_of(QUIET1 | 0x0200u).ssdone && !cons_flag1_of(QUIET1 | 0x0200u).srun,
	      "bit 9 is read as SRUN");
	CHECK(cons_flag1_of(QUIET1 | 0x0100u).srun && !cons_flag1_of(QUIET1 | 0x0100u).ssdone,
	      "bit 8 is read as SSDONE");

	// **THE LOW BYTE THROUGH ITS INVERTING DRIVER.**  All ones there is
	// every parity error at once; all zeros is a quiet machine.  Reading
	// that byte upside down is the mistake CC's own comment warns of.
	{
		const struct cons_flag1 hot = cons_flag1_of(QUIET1 | 0x00FFu);
		CHECK(hot.ape && hot.mpe && hot.pdlpe && hot.spe && hot.dpe && hot.ipe && hot.mempe && hot.higherr,
		      "a low byte of ones is not eight errors");
		const struct cons_flag1 cold = cons_flag1_of(QUIET1);
		CHECK(!cold.ape && !cold.mpe && !cold.pdlpe && !cold.spe && !cold.dpe && !cold.ipe
		      && !cold.mempe && !cold.higherr, "a low byte of zeros is read as errors");
		// bit 0 is A-memory parity and bit 7 is HIGH-ERR, in CC's order.
		CHECK(cons_flag1_of(QUIET1 | 1u).ape && !cons_flag1_of(QUIET1 | 1u).higherr, "bit 0 is not -APE");
		CHECK(cons_flag1_of(QUIET1 | 0x80u).higherr && !cons_flag1_of(QUIET1 | 0x80u).ape, "bit 7 is not -HIGHERR");
	}
	// The four active-low bits of the high byte: a ZERO is the condition.
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 15)).wait && !cons_flag1_of(QUIET1).wait, "bit 15 is not -WAIT");
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 11)).stathalt && !cons_flag1_of(QUIET1).stathalt,
	      "bit 11 is not -STATHALT");
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 14)).v1pe && !cons_flag1_of(QUIET1).v1pe, "bit 14 is not -V1PE");
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 13)).v0pe && !cons_flag1_of(QUIET1).v0pe, "bit 13 is not -V0PE");
	CHECK(cons_flag1_of(QUIET1 | (1u << 12)).promdisable && !cons_flag1_of(QUIET1).promdisable,
	      "bit 12 is not PROMDISABLE");
	CHECK(cons_flag1_of(QUIET1 | (1u << 10)).err && !cons_flag1_of(QUIET1).err, "bit 10 is not ERR");
	#undef QUIET1

	// FLAG-2.  **BITS 15, 14, 7 AND 6 ARE FOUR FLOATING TTL INPUTS AND
	// READ AS ONES**; reading them as zeros is the natural assumption and
	// is wrong.  A quiet FLAG-2 is therefore 0xC0C8, the 8 being -VMAOK
	// high for an access that was not permitted.
	{
		struct cons_flag2 g = { 0 };
		uint16_t v = cons_flag2_word(&g);
		CHECK((v & CONS_FLAG2_OPEN) == CONS_FLAG2_OPEN,
		      "FLAG-2 0x%04x does not carry the four floating ones", v);
		CHECK(v == 0xC0C8u, "a quiet FLAG-2 reads 0x%04x, wanting 0xC0C8", v);
		g.vmaok = 1;
		v = cons_flag2_word(&g);
		CHECK(v == 0xC0C0u, "a permitted access reads 0x%04x, wanting 0xC0C0 --- -VMAOK is LOW when it is permitted", v);
		CHECK(cons_flag2_of(0xC0C0u).vmaok, "-VMAOK low is read as not permitted");
		CHECK(!cons_flag2_of(0xC0C8u).vmaok, "-VMAOK high is read as permitted");
		const struct cons_flag2 all = cons_flag2_of(0xFFFFu);
		CHECK(all.wmapd && all.destspcd && all.iwrited && all.imodd && all.pdlwrited && all.spushd
		      && all.ir48 && all.nop && all.jcond && all.pcs1 && all.pcs0 && !all.vmaok,
		      "a FLAG-2 of all ones does not set every field");
		CHECK(cons_flag2_of(0xC0C1u).pcs0 && !cons_flag2_of(0xC0C1u).pcs1, "bit 0 is not PCS0");
		CHECK(cons_flag2_of(0xC0C2u).pcs1 && !cons_flag2_of(0xC0C2u).pcs0, "bit 1 is not PCS1");
		CHECK(cons_flag2_of(0xC0C0u).wmapd == 0, "bit 13 is read as set in a word that has it clear");
		CHECK(cons_flag2_of(0xC0C0u | (1u << 13)).wmapd, "bit 13 is not WMAPD");
	}
}

// The two counters, and the rule that makes them one instant.
static void check_counters(void)
{
	struct model m;
	struct console c;
	model_init(&m);
	attach(&c, &m);
	m.run = 0;
	m.freeze = 1;			/* nothing may move under the test, its own reads included */

	// Distinct halves, so that a swap is visible.
	m.cycles = 0x0000000700000009ull;
	m.ticks = 0x0000000A0000000Bull;
	// Read once into a variable: a second call to report the first one's
	// answer would find the latch populated and print a word the failing
	// call never saw.
	const uint64_t cy = cons_cycles(&c), ti = cons_ticks(&c);
	CHECK(cy == 0x0000000700000009ull,
	      "the FIRST read of CYCLES gave 0x%016llx, wanting 0x0000000700000009 --- the halves are swapped, "
	      "or the high half was read before the low one that latches it", (unsigned long long)cy);
	CHECK(ti == 0x0000000A0000000Bull,
	      "the first read of TICKS gave 0x%016llx, wanting 0x0000000A0000000B", (unsigned long long)ti);

	// **THE LOW READ LATCHES THE HIGH HALF**: read the pair, move the
	// counter, and the high word alone still answers the latch.
	CHECK(cons_cycles(&c) == 0x0000000700000009ull, "the pair changed under a still machine");
	m.cycles = 0x000000080000000Bull;
	CHECK(c.read(&c, CONS_CYCLESH) == 7,
	      "the high word alone gave 0x%08x: it is a LATCH, and a program that reads it without the low "
	      "word first gets whatever the last low read latched", c.read(&c, CONS_CYCLESH));
	CHECK(cons_cycles(&c) == 0x000000080000000Bull, "the low read did not re-latch the high half");

	// And the carry the rule exists for.  A reader that took the high half
	// first would pair a high word from before the carry with a low word
	// from after it and name a time 4,294,967,296 microcycles away.
	m.cycles = 0x00000007FFFFFFFFull;
	CHECK(cons_cycles(&c) == 0x00000007FFFFFFFFull, "the pair just below the carry is wrong");
	const uint32_t hi_first = c.read(&c, CONS_CYCLESH);	/* 7, and right at this instant */
	m.cycles = 0x0000000800000000ull;			/* the carry lands */
	const uint32_t lo_after = c.read(&c, CONS_CYCLES);
	const uint64_t wrong = (uint64_t)hi_first << 32 | lo_after;
	CHECK(wrong != m.cycles, "the wrong order happened to be right, so this check proves nothing");
	CHECK(cons_cycles(&c) == 0x0000000800000000ull, "the right order did not give the right pair");
}

// All sixteen registers, so that an index off by one lands somewhere it can
// be seen.
static void check_regs(void)
{
	struct model m;
	struct console c;
	struct cons_regs r;
	model_init(&m);
	attach(&c, &m);
	m.run = 0;
	m.freeze = 1;
	cons_read_regs(&c, &r);
	CHECK(r.lost == 0, "a register's cycle was lost with the grant up: 0x%04x", r.lost);

	const uint16_t want[16] = {
		0x1111, 0x2222, 0x3333, SPY_OPEN_READ,
		0x0444, 0x0555, 0x6666, 0x7777,
		cons_flag1_word(&m.f1), cons_flag2_word(&m.f2),
		0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD, 0xEEEE, 0xFFF0
	};
	for (unsigned k = 0; k < 16; ++k)
		CHECK(r.v[k] == want[k], "register %u (%s) read 0x%04x, the model holds 0x%04x",
		      k, cons_reg_name(k), r.v[k], want[k]);
	// Register 3 is the open bus and not a register: no read select is
	// decoded there, so the bus interface's 8304s read all ones.
	CHECK(r.v[SPY_OPEN] == 0xFFFFu, "register 3 is not the open bus");
	// And the one read the vocabulary makes by name lands on the same word.
	{
		uint16_t pc = 0;
		CHECK(cons_spy_read(&c, SPY_PC, &pc) == 0 && pc == 0x0555,
		      "SPY_PC read 0x%04x, the model holds 0x0555", pc);
	}
	// A write goes to the strobe muir's write_strobe names, and 8..15
	// alias onto 0..7 because EADR3 does not reach the write decoder.
	cons_spy_write(&c, SPY_MODE, MODE_ERRSTOP | MODE_PROMDISABLE);
	CHECK(m.mode == (MODE_ERRSTOP | MODE_PROMDISABLE), "the mode register took 0x%04x", m.mode);
	cons_spy_write(&c, SPY_MODE + 8, MODE_TRAPENB);
	CHECK(m.mode == MODE_TRAPENB, "EADR 13 did not alias onto the mode register's strobe");
}

// A diagnostic cycle nothing answered.  Bit 16 is the whole of the answer and
// there is no data under it.
static void check_lost(void)
{
	struct model m;
	struct console c;
	struct cons_regs r;
	struct cons_status st;
	uint16_t v = 0x5A5A;
	model_init(&m);
	attach(&c, &m);
	m.grant = 0;			/* the grant never comes */

	CHECK((c.read(&c, CONS_SPY_WORD(SPY_PC)) & CONS_LOST_BIT) != 0,
	      "the model did not set bit 16 on a cycle nothing answered");
	CHECK(cons_spy_read(&c, SPY_PC, &v) == -1, "a lost cycle was reported as data");
	CHECK(v == 0x5A5A, "a lost cycle overwrote the caller's word with 0x%04x --- there is no data under bit 16", v);
	CHECK(c.lost == 1, "the lost cycle was not counted: %lu", c.lost);
	CHECK((cons_stat(&c) & CONS_ST_LOST) != 0, "STAT's sticky lost bit is down after a lost cycle");

	cons_read_regs(&c, &r);
	CHECK(r.lost == 0xFFFFu, "all sixteen cycles were lost and the mask says 0x%04x", r.lost);
	for (unsigned k = 0; k < 16; ++k)
		CHECK(r.v[k] == 0, "register %u carries 0x%04x after a lost cycle: a lost cycle is not a zero",
		      k, r.v[k]);

	capture_start();
	CHECK(cons_status(&c, 100, &st) == -1, "status on a machine nothing answers did not fail");
	CHECK(st.lost, "status did not mark the reading lost");
	CHECK(st.why && strstr(st.why, "not answered") != NULL,
	      "status did not say the cycle was not answered: %s", st.why ? st.why : "(nothing)");
	cons_say_status(&st);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "not answered") != NULL, "status printed nothing about the lost cycle");
		CHECK(strstr(out, "RUNNING") == NULL,
		      "status called a machine nothing answered running or not running; it knows neither");
	}

	// And the guard against the other mistake: a program that masked bit
	// 16 away would read FLAG-1 as zero, whose decode is a machine that is
	// halted, waiting, and reporting a level-2 map parity error.  Nothing
	// may reach that decode from a lost cycle.
	{
		const struct cons_flag1 f = cons_flag1_of(0);
		CHECK(f.wait && f.v1pe && f.v0pe && f.stathalt && !f.srun,
		      "a FLAG-1 of zero does not decode as the alarming word it is");
	}
}

// --- the virtual address register and Q, page 0's words 7 and 8 ----------
//
// **THE PAIR IS THE WHOLE POINT AND THE LATCH IS WHAT MAKES IT A PAIR.**  The
// read of word 7 takes Q beside it, so what a program compares is one
// microcycle of the machine; a word 8 read on its own is the last read of
// word 7's Q and must be, or the two values would be two instants and the
// difference between them could be the gap rather than the machine.
static void check_vmaq(void)
{
	struct model m;
	struct console c;
	struct cons_vmaq v;
	model_init(&m);
	attach(&c, &m);

	cons_read_vmaq(&c, &v);
	CHECK(v.vma == m.vma, "VMA reads 0x%08x, the model holds 0x%08x", v.vma, m.vma);
	CHECK(v.q == m.q, "Q reads 0x%08x, the model holds 0x%08x", v.q, m.q);
	CHECK(!v.unmapped, "a face that answered both words called them unmapped");
	// Bits 23:8, which is what the two levels of the map are indexed by:
	// a CADR page is 256 words.
	CHECK(v.vma_page == ((m.vma >> 8) & 0xFFFFu), "VMA's page is 0%o, wanting 0%o",
	      v.vma_page, (m.vma >> 8) & 0xFFFFu);
	CHECK(v.q_page == ((m.q >> 8) & 0xFFFFu), "Q's page is 0%o, wanting 0%o",
	      v.q_page, (m.q >> 8) & 0xFFFFu);
	// **AND THEY ARE NOT CROSSED**, which is the one mistake that would
	// make this instrument answer the question it exists for with the two
	// sides swapped.  The model holds two words that differ, so this is
	// evidence and not an accident; a check made where they read alike
	// would pass either way, which is `tb/cadr_console_tb.cpp`'s own
	// lesson about counting the discriminating samples.
	CHECK(m.vma != m.q, "the model's VMA and Q read alike, so nothing here can tell one from the other");
	CHECK(v.vma != v.q, "VMA and Q came back equal from a model holding two different words");

	// **THE LATCH.**  Move Q under the program without reading word 7:
	// word 8 alone must still be what the last read of word 7 took.
	const uint32_t was = v.q;
	m.q = 0x00077777u;
	CHECK(c.read(&c, CONS_Q) == was,
	      "word 8 read alone gave 0x%08x and not the 0x%08x the last read of word 7 latched",
	      c.read(&c, CONS_Q), was);
	cons_read_vmaq(&c, &v);
	CHECK(v.q == 0x00077777u, "reading VMA did not re-arm the latch: Q reads 0x%08x", v.q);

	// **AND THE ORDER IS THE RULE AND NOT THE ADVICE**: the wrong order
	// pairs a Q from the last read of word 7 with a VMA from now, and this
	// is what that looks like when it happens.
	{
		m.q = 0x00011111u;
		const uint32_t stale = c.read(&c, CONS_Q);
		const uint32_t now = c.read(&c, CONS_VMA);
		CHECK(stale == 0x00077777u && now == m.vma,
		      "Q then VMA did not give a stale Q with a fresh VMA: 0x%08x, 0x%08x", stale, now);
	}

	// What it says, which is part of the contract: the two values, what
	// each is, and what each reading points at.  No name for the
	// comparison --- the numbers and the sentence.
	m.q = m.vma;
	capture_start();
	cons_read_vmaq(&c, &v);
	cons_say_vmaq(&v);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "VMA") && strstr(out, "Q ") , "the pair was not printed by name");
		CHECK(strstr(out, "same word") != NULL,
		      "an equal pair was not reported as equal");
		CHECK(strstr(out, "map write not having taken") != NULL,
		      "an equal pair did not say what it points at");
		CHECK(strstr(out, "halt") != NULL,
		      "the output did not say the answer means nothing on a machine that was not halted");
	}
	m.q = 0x00129C42u;
	capture_start();
	cons_read_vmaq(&c, &v);
	cons_say_vmaq(&v);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "DIFFERENT pages") != NULL,
		      "a pair a page apart was not reported as naming different pages");
		CHECK(strstr(out, "not the page the map was hacked for") != NULL,
		      "a pair a page apart did not say what it points at");
	}
	// Two words of one page: neither reading, and it must not be reported
	// as either.
	m.q = m.vma + 4u;
	capture_start();
	cons_read_vmaq(&c, &v);
	cons_say_vmaq(&v);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "same page") != NULL, "two words of one page were not reported as such");
		CHECK(strstr(out, "same word") == NULL, "two different words were called the same word");
		CHECK(strstr(out, "DIFFERENT pages") == NULL, "two words of one page were called different pages");
	}

	// **AND A FABRIC WITHOUT THESE WORDS MUST NOT READ AS A VIRTUAL
	// ADDRESS.**  An older bitstream answers UNMAPPED at both, and
	// UNMAPPED is a value that means nothing: the rule this project keeps
	// meeting is that it must not be a value the instrument can mean.
	m.vma = CONS_UNMAPPED;
	m.q = CONS_UNMAPPED;
	capture_start();
	cons_read_vmaq(&c, &v);
	cons_say_vmaq(&v);
	CHECK(v.unmapped, "both words reading UNMAPPED was taken for a machine's state");
	CHECK(strstr(capture_end(), "not in this bitstream") != NULL,
	      "a fabric without these words was not named as one");

	// They come back through `regs` and through `status` too, which is
	// where a person actually meets them.
	model_init(&m);
	{
		struct cons_regs r;
		capture_start();
		cons_read_regs(&c, &r);
		cons_say_regs(&r);
		const char *out = capture_end();
		CHECK(r.vq.vma == m.vma && r.vq.q == m.q, "`regs` did not read the pair");
		CHECK(strstr(out, "on no diagnostic register") != NULL,
		      "`regs` printed the pair as though it were a seventeenth register");
	}
	{
		struct cons_status st;
		capture_start();
		cons_status(&c, 0, &st);
		cons_say_status(&st);
		CHECK(st.vq.vma == m.vma && st.vq.q == m.q, "`status` did not read the pair");
		CHECK(strstr(capture_end(), "virtual address register") != NULL,
		      "`status` did not print the pair");
	}
}

// The address arithmetic examine and deposit use, which is
// cadr_ddr_map::main_byte_address and not a second description of it.
static void check_main_address(void)
{
	CHECK(cons_main_byte_address(0) == 0x18000000u, "word 0 is not at the region's base");
	CHECK(cons_main_byte_address(1) == 0x18000004u, "a word is not four bytes");
	// The word the proving boards used, from CLAUDE.md: 0o12345671.
	CHECK(cons_main_byte_address(012345671u) == 0x18A72EE4u,
	      "main_byte_address(22'o12345671) is 0x%08x, wanting 0x18A72EE4 --- the address the proving "
	      "boards wrote on the board", cons_main_byte_address(012345671u));
	CHECK(cons_main_byte_address(0x3FFFFFu) == 0x18000000u + (0x3FFFFFu << 2),
	      "the top of the 22-bit physical space is not where the map puts it");
	CHECK(CONS_MAIN_WORDS_REACHABLE == 3932160u,
	      "the reachable words have moved from cadr_ddr_map.sv's 60 boards of 64K");
}

int main(void)
{
	capture_start();		/* nothing may print to the terminal but the verdict */
	check_ident();
	check_guard();
	check_halt_and_start();
	check_step();
	check_flags();
	check_counters();
	check_regs();
	check_lost();
	check_vmaq();
	check_main_address();
	fflush(cap);

	if (bad) {
		fprintf(stderr, "console_test: %d of %u checks FAILED\n", bad, checks);
		return 1;
	}
	printf("ok: the console program drives the register face rtl/plumbing/cadr_console.sv defines, and\n"
	       "    says what it found\n"
	       "    %u checks against a model of the slave --- two pages of sixteen, the high\n"
	       "      halves latched by the low reads, UNMAPPED outside, bit 16 for a cycle\n"
	       "      nothing answered --- with a modelled machine behind the diagnostic bus\n"
	       "    IDENT \"CONS\", and \"NONE\", UNMAPPED, zeros and ones all refused\n"
	       "    the EMIO tally guard refuses all ones and all zeros and takes only the\n"
	       "      marker pattern (w & 0x80008000) == 0x00008000\n"
	       "    halt then status: SRUN down, CYCLES standing, the halt attributed to the\n"
	       "      console; start then status: CYCLES MEASURED to have moved\n"
	       "    step: the machine did not move, and it says so and names docs/console.md\n"
	       "    FLAG-1's low byte through its inverting driver and FLAG-2's four floating\n"
	       "      ones, field by field against known words\n"
	       "    CYCLES low then high: the pair is one instant across a carry, the high word\n"
	       "      alone is a stale latch, and the other order is measurably wrong\n"
	       "    all sixteen registers read back as the model holds them, register 3 the\n"
	       "      open bus, a write aliasing onto EADR<2:0> as spy::write_strobe says\n"
	       "    a lost cycle reported lost and never mistaken for data\n"
	       "    page 0's words 7 and 8 --- the virtual address register and Q, which are on\n"
	       "      NO diagnostic register and which MIT's sixteen have no room for: read in\n"
	       "      that order because word 7's read latches Q beside it, so the pair names\n"
	       "      one microcycle; word 8 alone is a stale latch and the wrong order is\n"
	       "      measurably wrong; the page numbers are VMA<23:8> and Q<23:8>, a CADR page\n"
	       "      being 256 words; and the three readings each say what they point at ---\n"
	       "      the same word, two words of one page, or two pages --- with both values\n"
	       "      printed and no name given to the comparison.  Both reading UNMAPPED is a\n"
	       "      bitstream without these words and is refused as a virtual address\n", checks);
	return 0;
}
