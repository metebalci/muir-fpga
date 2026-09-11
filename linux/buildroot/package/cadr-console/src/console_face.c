// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The driver of the console's register face and the vocabulary on it;
// `console_face.h` says what the face is and where every number comes from.

#include "console_face.h"

#include <cadr/cadr_log.h>

#include <string.h>

void cons_init(struct console *c)
{
	c->read = NULL;
	c->write = NULL;
	c->pause = NULL;
	c->ctx = NULL;
	c->reads = c->writes = c->lost = 0;
}

// --- the flags -----------------------------------------------------------

struct cons_flag1 cons_flag1_of(uint16_t w)
{
	struct cons_flag1 f;
	// The high byte in the board's polarities: four of its eight are
	// active low.  The low byte comes through an INVERTING driver, so it
	// reads high for an error and is taken as it stands.
	f.wait = !(w & (1u << 15));
	f.v1pe = !(w & (1u << 14));
	f.v0pe = !(w & (1u << 13));
	f.promdisable = !!(w & (1u << 12));
	f.stathalt = !(w & (1u << 11));
	f.err = !!(w & (1u << 10));
	f.ssdone = !!(w & (1u << 9));
	f.srun = !!(w & (1u << 8));
	f.higherr = !!(w & (1u << 7));
	f.mempe = !!(w & (1u << 6));
	f.ipe = !!(w & (1u << 5));
	f.dpe = !!(w & (1u << 4));
	f.spe = !!(w & (1u << 3));
	f.pdlpe = !!(w & (1u << 2));
	f.mpe = !!(w & (1u << 1));
	f.ape = !!(w & (1u << 0));
	return f;
}

uint16_t cons_flag1_word(const struct cons_flag1 *f)
{
	uint16_t w = 0;
	w |= (uint16_t)(!f->wait) << 15;
	w |= (uint16_t)(!f->v1pe) << 14;
	w |= (uint16_t)(!f->v0pe) << 13;
	w |= (uint16_t)(!!f->promdisable) << 12;
	w |= (uint16_t)(!f->stathalt) << 11;
	w |= (uint16_t)(!!f->err) << 10;
	w |= (uint16_t)(!!f->ssdone) << 9;
	w |= (uint16_t)(!!f->srun) << 8;
	w |= (uint16_t)(!!f->higherr) << 7;
	w |= (uint16_t)(!!f->mempe) << 6;
	w |= (uint16_t)(!!f->ipe) << 5;
	w |= (uint16_t)(!!f->dpe) << 4;
	w |= (uint16_t)(!!f->spe) << 3;
	w |= (uint16_t)(!!f->pdlpe) << 2;
	w |= (uint16_t)(!!f->mpe) << 1;
	w |= (uint16_t)(!!f->ape) << 0;
	return w;
}

struct cons_flag2 cons_flag2_of(uint16_t w)
{
	struct cons_flag2 f;
	f.wmapd = !!(w & (1u << 13));
	f.destspcd = !!(w & (1u << 12));
	f.iwrited = !!(w & (1u << 11));
	f.imodd = !!(w & (1u << 10));
	f.pdlwrited = !!(w & (1u << 9));
	f.spushd = !!(w & (1u << 8));
	f.ir48 = !!(w & (1u << 5));
	f.nop = !!(w & (1u << 4));
	// -VMAOK is low when the access is permitted.
	f.vmaok = !(w & (1u << 3));
	f.jcond = !!(w & (1u << 2));
	f.pcs1 = !!(w & (1u << 1));
	f.pcs0 = !!(w & (1u << 0));
	return f;
}

uint16_t cons_flag2_word(const struct cons_flag2 *f)
{
	// The four floating inputs first: bits 15, 14, 7 and 6 read as ones on
	// the board and no field of ours can clear them.
	uint16_t w = CONS_FLAG2_OPEN;
	w |= (uint16_t)(!!f->wmapd) << 13;
	w |= (uint16_t)(!!f->destspcd) << 12;
	w |= (uint16_t)(!!f->iwrited) << 11;
	w |= (uint16_t)(!!f->imodd) << 10;
	w |= (uint16_t)(!!f->pdlwrited) << 9;
	w |= (uint16_t)(!!f->spushd) << 8;
	w |= (uint16_t)(!!f->ir48) << 5;
	w |= (uint16_t)(!!f->nop) << 4;
	w |= (uint16_t)(!f->vmaok) << 3;
	w |= (uint16_t)(!!f->jcond) << 2;
	w |= (uint16_t)(!!f->pcs1) << 1;
	w |= (uint16_t)(!!f->pcs0) << 0;
	return w;
}

// --- the face ------------------------------------------------------------

int cons_ident_ok(struct console *c, uint32_t *got)
{
	*got = c->read(c, CONS_IDENT);
	return *got == CONS_IDENT_WORD ? 0 : -1;
}

uint32_t cons_stat(struct console *c)
{
	return c->read(c, CONS_STAT);
}

// **THE LOW HALF FIRST, ALWAYS.**  Reading CONS_CYCLES latches CONS_CYCLESH
// beside it, so the pair names one instant across the carry; the other order
// pairs a high half from the last low read with a low half from now.
uint64_t cons_cycles(struct console *c)
{
	const uint32_t lo = c->read(c, CONS_CYCLES);
	const uint32_t hi = c->read(c, CONS_CYCLESH);
	return (uint64_t)hi << 32 | lo;
}

uint64_t cons_ticks(struct console *c)
{
	const uint32_t lo = c->read(c, CONS_TICKS);
	const uint32_t hi = c->read(c, CONS_TICKSH);
	return (uint64_t)hi << 32 | lo;
}

// **VMA FIRST, ALWAYS**, for the reason CYCLES goes before CYCLESH: the read
// of word 7 latches Q beside it, so the pair names one microcycle of the
// machine.  Reading word 8 first would pair a Q the last read of word 7
// latched with a VMA from now.
void cons_read_vmaq(struct console *c, struct cons_vmaq *v)
{
	v->vma = c->read(c, CONS_VMA);
	v->q = c->read(c, CONS_Q);
	// VMA<23:8> is the page number, which is what the two levels of the
	// map are indexed by: a CADR page is 256 words.  The bits above 24
	// are not address --- a map write carries its data there --- so the
	// page numbers are given beside the raw words and not instead of
	// them.
	v->vma_page = (v->vma >> 8) & 0xFFFFu;
	v->q_page = (v->q >> 8) & 0xFFFFu;
	// A fabric older than these two words answers UNMAPPED at both, and
	// UNMAPPED is a value that means nothing: it must not be read as a
	// virtual address.  Both, because either alone could in principle be
	// a word the machine really holds.
	v->unmapped = v->vma == CONS_UNMAPPED && v->q == CONS_UNMAPPED;
}

void cons_say_vmaq(const struct cons_vmaq *v)
{
	if (v->unmapped) {
		say("  VMA and Q both read 0x%08x, which is this face's own UNMAPPED: page 0's words 7 and 8 "
		    "are not in this bitstream", CONS_UNMAPPED);
		return;
	}
	say("  VMA 0x%08x  %o   the virtual address register, page 0 word 7 --- NOT a diagnostic register: "
	    "MIT's sixteen have none for it.  Page VMA<23:8> = %o", v->vma, v->vma, v->vma_page);
	say("  Q   0x%08x  %o   the Q register, page 0 word 8, latched when VMA was read so the two name "
	    "one microcycle.  Page Q<23:8> = %o", v->q, v->q, v->q_page);
	// **THE TWO VALUES AND WHAT EACH MEANS, AND NO NAME FOR THE
	// COMPARISON.**  In PDL-BUFFER-REFILL the microcode reads a
	// second-level map entry, writes it back with read/write access ORed
	// in, and then reads through the entry it has just hacked.  Three
	// faults injected into muir give the same PC, OPC, flag words, IR, A,
	// M and OB, and are told apart here and nowhere else.
	if (v->vma == v->q)
		say("  VMA and Q hold the same word.  In PDL-BUFFER-REFILL that is what the map-side faults "
		    "leave behind --- the address read IS the page the map was hacked for, so a page fault "
		    "there is the map write not having taken");
	else if (v->vma_page == v->q_page)
		say("  VMA and Q differ but name the same page %o, so whatever is between them is inside one "
		    "page of 256 words and the map sees one entry for both", v->vma_page);
	else
		// The distance in OCTAL, as the page numbers beside it are:
		// one page apart is `1`, which is the reading this word pair
		// was put on the face to make visible.
		say("  VMA and Q name DIFFERENT pages, %o and %o, %lo pages apart.  In PDL-BUFFER-REFILL that "
		    "is what the wrong-address fault leaves behind --- the address read is not the page the "
		    "map was hacked for", v->vma_page, v->q_page,
		    (unsigned long)(v->vma_page > v->q_page ? v->vma_page - v->q_page
							    : v->q_page - v->vma_page));
	say("  both are as of the last microcycle boundary, which is exact on a halted machine --- halt "
	    "first if the answer is to mean anything");
}

int cons_spy_read(struct console *c, unsigned eadr, uint16_t *v)
{
	const uint32_t w = c->read(c, CONS_SPY_WORD(eadr & 15u));
	++c->reads;
	// Bit 16 is the whole of the answer when it is up: there is no data
	// under it and masking it away would hand back a plausible zero.
	if (w & CONS_LOST_BIT) {
		++c->lost;
		return -1;
	}
	*v = (uint16_t)w;
	return 0;
}

void cons_spy_write(struct console *c, unsigned eadr, uint16_t v)
{
	c->write(c, CONS_SPY_WORD(eadr & 15u), v);
	++c->writes;
}

// --- the vocabulary ------------------------------------------------------

void cons_halt(struct console *c)
{
	cons_spy_write(c, SPY_CLK, 0);
}

void cons_start(struct console *c)
{
	cons_spy_write(c, SPY_CLK, CLK_RUN);
}

void cons_step(struct console *c, unsigned n, struct cons_step *s)
{
	memset(s, 0, sizeof *s);
	s->asked = n;
	s->before = cons_cycles(c);
	for (unsigned k = 0; k < n; ++k) {
		// CC's `CC-CLOCK`: raise STEP, lower it.  It must be lowered
		// again before the next.
		cons_spy_write(c, SPY_CLK, CLK_STEP);
		cons_spy_write(c, SPY_CLK, 0);
	}
	uint16_t f1 = 0;
	if (cons_spy_read(c, SPY_FLAG_1, &f1) == 0)
		s->ssdone = !!(f1 & (1u << 9));
	s->after = cons_cycles(c);
	s->moved = s->after - s->before;
}

const char *cons_reg_name(unsigned eadr)
{
	static const char *const names[16] = {
		"IR-LOW   IR<15:0>",
		"IR-MED   IR<31:16>",
		"IR-HIGH  IR<47:32>",
		"(open)   no read select is decoded: the floating bus, all ones",
		"OPC      OPC<13:0>, bits 15 and 14 grounded",
		"PC       PC<13:0>, bits 15 and 14 grounded",
		"OB-LOW   OB<15:0>",
		"OB-HIGH  OB<31:16>",
		"FLAG-1",
		"FLAG-2",
		"M-LOW    M<15:0>",
		"M-HIGH   M<31:16>",
		"A-LOW    AA<15:0>",
		"A-HIGH   A<31:16>",
		"STAT-LOW  ST<15:0>, the statistics counter",
		"STAT-HIGH ST<31:16>"
	};
	return names[eadr & 15u];
}

void cons_read_regs(struct console *c, struct cons_regs *r)
{
	memset(r, 0, sizeof *r);
	for (unsigned k = 0; k < 16; ++k) {
		uint16_t v = 0;
		if (cons_spy_read(c, k, &v) < 0)
			r->lost |= (uint16_t)(1u << k);
		else
			r->v[k] = v;
	}
	// And the two that are not on that bus.  No diagnostic cycle is run
	// for these, so they cannot be lost and there is no bit for them in
	// `lost`; they are two loads of page 0.
	cons_read_vmaq(c, &r->vq);
}

int cons_status(struct console *c, unsigned settle_us, struct cons_status *st)
{
	uint16_t f1 = 0, f2 = 0, pc = 0, opc = 0;
	memset(st, 0, sizeof *st);
	st->settle_us = settle_us;
	// The two samples of CYCLES bracket everything else, so what is
	// between them is what the machine did while being asked.
	st->cycles_first = cons_cycles(c);
	if (cons_spy_read(c, SPY_FLAG_1, &f1) < 0)
		st->lost = 1;
	if (cons_spy_read(c, SPY_FLAG_2, &f2) < 0)
		st->lost = 1;
	if (cons_spy_read(c, SPY_PC, &pc) < 0)
		st->lost = 1;
	if (cons_spy_read(c, SPY_OPC, &opc) < 0)
		st->lost = 1;
	// The virtual address register and Q, which no diagnostic cycle can
	// reach: two loads of page 0, taken inside the bracket with
	// everything else so that they belong to the same look at the machine.
	cons_read_vmaq(c, &st->vq);
	if (c->pause)
		c->pause(c, settle_us);
	st->cycles_second = cons_cycles(c);
	st->ticks = cons_ticks(c);
	st->flag1_word = f1;
	st->flag2_word = f2;
	st->f1 = cons_flag1_of(f1);
	st->f2 = cons_flag2_of(f2);
	// PC and OPC are fourteen bits; the two above them are grounded.
	st->pc = pc & 0x3FFFu;
	st->opc = opc & 0x3FFFu;
	if (st->lost) {
		st->why = "a diagnostic cycle was not answered: nothing here is data";
		return -1;
	}
	// **RUNNING IS THE COUNTER MOVING AND NOTHING ELSE.**
	st->running = st->cycles_second != st->cycles_first;
	if (st->running) {
		st->why = NULL;
		return 0;
	}
	// Not running.  `machrun_low` (../muir/src/main.rs:2278-2305) in its
	// own order: a cleared RUN is the console's halt and is not a machine
	// that stopped itself, and the two self-halts are read off FLAG-1.
	if (!st->f1.srun)
		st->why = "halted from the console: SRUN is down, so RUN in the clock control register is clear";
	else if (st->f1.err)
		// muir asks `mode.errstop` here as well.  A console cannot:
		// the mode register is write-only, so what can be said is that
		// ERR is up and that under ERRSTOP that is a self-halt.
		st->why = "ERR is up: under ERRSTOP this is what HALT-CONS does, MIT's (si:%halt). "
			  "The mode register is write-only, so ERRSTOP itself cannot be read back";
	else if (st->f1.stathalt)
		st->why = "the statistics counter ran out under STATHENB";
	else if (st->f1.wait)
		st->why = "-WAIT is low: the cpu clock is stopped for a bus cycle. A machine comes out of a bus wait by itself, "
			  "so this is transient unless it stands";
	else
		st->why = "SRUN is up and no microcycle was retired, and FLAG-1 names no halt: ask again over a longer settle";
	return 0;
}

// --- what they print -----------------------------------------------------
//
// The printing is here and not in `cadr-console.c` so that the host test can
// hold the WORDS as well as the decode: a `step` that reported nothing while
// returning `moved = 0` would be exactly the silent no-op this is written to
// prevent, and only an assertion on the line catches that.

void cons_say_step(const struct cons_step *s)
{
	say("step %u: CYCLES %llu -> %llu, %llu microcycle(s) retired; SSDONE %s",
	    s->asked, (unsigned long long)s->before, (unsigned long long)s->after,
	    (unsigned long long)s->moved, s->ssdone ? "up" : "down");
	if (s->moved == 0 && s->asked) {
		say("step: THE MACHINE DID NOT MOVE, and on today's fabric it cannot: single-stepping is SSTEP and "
		    "SSDONE, two flip flops of the 74S174 at OLORD1 1A10, and cadr_microcycle.sv has neither");
		say("step: cadr_spy_registers.sv takes bit 0 of a clock control write --- RUN --- and drops bits 4:1, "
		    "so the 2-then-0 CC's CC-CLOCK writes lands as RUN cleared twice and clocks nothing");
		say("step: halt and start are the whole of what a console can make this machine do today; "
		    "docs/console.md names the two hunks that would add the rest");
	}
}

void cons_say_status(const struct cons_status *st)
{
	if (st->lost) {
		say("status: %s", st->why);
		return;
	}
	say("status: %s --- CYCLES %llu then %llu, %u us apart, %llu retired between them; TICKS %llu",
	    st->running ? "RUNNING" : "NOT RUNNING", (unsigned long long)st->cycles_first,
	    (unsigned long long)st->cycles_second, st->settle_us,
	    (unsigned long long)(st->cycles_second - st->cycles_first), (unsigned long long)st->ticks);
	say("status: PC %o (0x%04x), OPC %o", st->pc, st->pc, st->opc);
	cons_say_vmaq(&st->vq);
	say("status: FLAG-1 0x%04x: SRUN %s, SSDONE %s, ERR %s, -STATHALT %s, -WAIT %s, PROMDISABLE %s",
	    st->flag1_word, st->f1.srun ? "up" : "down", st->f1.ssdone ? "up" : "down",
	    st->f1.err ? "up" : "down", st->f1.stathalt ? "halted" : "clear",
	    st->f1.wait ? "waiting" : "clear", st->f1.promdisable ? "set" : "clear");
	if (st->why)
		say("status: %s", st->why);
}

// FLAG-1's sixteen fields, the low byte named as CC's `CC-PRINT-ERROR-STATUS`
// names it --- an error there reads HIGH, the driver being inverting.
void cons_say_flag1(uint16_t w)
{
	const struct cons_flag1 f = cons_flag1_of(w);
	say("  FLAG-1 0x%04x  SRUN %d  SSDONE %d  ERR %d  -STATHALT %s  PROMDISABLE %d  -V0PE %s  -V1PE %s  -WAIT %s",
	    w, f.srun, f.ssdone, f.err, f.stathalt ? "halted" : "clear", f.promdisable,
	    f.v0pe ? "error" : "clear", f.v1pe ? "error" : "clear", f.wait ? "waiting" : "clear");
	say("  FLAG-1 low byte, through an inverting driver so a one is an error: "
	    "A-MEM-PAR %d  M-MEM-PAR %d  PDL-BUF-PAR %d  SPC-PAR %d  DISP-PAR %d  C-MEM-PAR %d  MN-MEM-PAR %d  HIGH-ERR %d",
	    f.ape, f.mpe, f.pdlpe, f.spe, f.dpe, f.ipe, f.mempe, f.higherr);
}

void cons_say_flag2(uint16_t w)
{
	const struct cons_flag2 f = cons_flag2_of(w);
	say("  FLAG-2 0x%04x  WMAPD %d  DESTSPC %d  IWRITED %d  IMODD %d  PDLWRITED %d  SPUSHD %d",
	    w, f.wmapd, f.destspcd, f.iwrited, f.imodd, f.pdlwrited, f.spushd);
	say("  FLAG-2        IR48 %d  NOP %d  -VMAOK %s  JCOND %d  PCS1 %d  PCS0 %d; "
	    "bits 15, 14, 7 and 6 read 0x%x --- four floating TTL inputs, ones on the board and not fields",
	    f.ir48, f.nop, f.vmaok ? "permitted" : "NOT permitted", f.jcond, f.pcs1, f.pcs0,
	    w & CONS_FLAG2_OPEN);
}

void cons_say_regs(const struct cons_regs *r)
{
	for (unsigned k = 0; k < 16; ++k) {
		if (r->lost & (1u << k)) {
			say("  %2u  %-52s  NOT ANSWERED --- the diagnostic cycle was lost, this is not data",
			    k, cons_reg_name(k));
			continue;
		}
		say("  %2u  %-52s  0x%04x  %o", k, cons_reg_name(k), r->v[k], r->v[k]);
		if (k == SPY_FLAG_1)
			cons_say_flag1(r->v[k]);
		if (k == SPY_FLAG_2)
			cons_say_flag2(r->v[k]);
	}
	// **AND THE TWO THAT ARE NOT AMONG THEM**, said so rather than
	// printed as though they were a seventeenth and eighteenth register:
	// `EADR<3:0>` names sixteen things and all sixteen are MIT's.
	say("and page 0's words 7 and 8, which are the machine's own and are on no diagnostic register:");
	cons_say_vmaq(&r->vq);
}
