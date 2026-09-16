// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The driver of the console's register face and the vocabulary on it;
// `console_face.h` says what the face is and where every number comes from.

#include "console_face.h"

#include <cadr/cadr_log.h>

#include <errno.h>
#include <string.h>
#include <unistd.h>

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
// of word 7 latches Q and MD beside it, so the three name one microcycle of
// the machine.  Reading word 8 or word 9 first would pair a value the last
// read of word 7 latched with a VMA from now.  There is deliberately no
// function here that reads one of the three on its own.
void cons_read_machine_words(struct console *c, struct cons_machine_words *v)
{
	v->vma = c->read(c, CONS_VMA);
	v->q = c->read(c, CONS_Q);
	v->md = c->read(c, CONS_MD);
	// VMA<23:8> is the page number, which is what the two levels of the
	// map are indexed by: a CADR page is 256 words.  The bits above 24
	// are not address --- a map write carries its data there --- so the
	// page numbers are given beside the raw words and not instead of
	// them.  MD<23:8> is a page number in exactly the same sense and for
	// a sharper reason: `cadr_microcycle.sv:1006` makes MAPI VMA<23:8>
	// while MEMSTART is up and MD<23:8> otherwise, so this is the entry a
	// SRCMAP read looks at.
	v->vma_page = (v->vma >> 8) & 0xFFFFu;
	v->q_page = (v->q >> 8) & 0xFFFFu;
	v->md_page = (v->md >> 8) & 0xFFFFu;
	// A fabric older than these words answers UNMAPPED at all of them,
	// and UNMAPPED is a value that means nothing: it must not be read as
	// a virtual address or as a word out of memory.  All three, because
	// any one alone could in principle be a word the machine really
	// holds.
	v->unmapped = v->vma == CONS_UNMAPPED && v->q == CONS_UNMAPPED &&
		      v->md == CONS_UNMAPPED;
}

void cons_say_machine_words(const struct cons_machine_words *v)
{
	if (v->unmapped) {
		say("  VMA, Q and MD all read 0x%08x, which is this face's own UNMAPPED: page 0's words 7, 8 "
		    "and 9 are not in this bitstream", CONS_UNMAPPED);
		return;
	}
	say("  VMA 0x%08x  %o   the virtual address register, page 0 word 7 --- NOT a diagnostic register: "
	    "MIT's sixteen have none for it.  Page VMA<23:8> = %o", v->vma, v->vma, v->vma_page);
	say("  Q   0x%08x  %o   the Q register, page 0 word 8, latched when VMA was read so the three name "
	    "one microcycle.  Page Q<23:8> = %o", v->q, v->q, v->q_page);
	say("  MD  0x%08x  %o   the memory data register, page 0 word 9, latched when VMA was read.  "
	    "Page MD<23:8> = %o", v->md, v->md, v->md_page);
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
	// **WHAT MD IS AND WHAT ITS READING MEANS HERE**, in two sentences and
	// no name for either comparison.  The first is what the word is: a
	// reference the map refuses starts no bus cycle at all --- the cycle
	// is armed by MEMSTART AND VMAOK --- so the faulting read never
	// strobed -LOADMD, and what stands in MD is the word the last
	// COMPLETED read left.  The second is the sharper one and it is a
	// fact about this machine's wiring rather than about the microcode:
	// the map is indexed by VMA<23:8> on a memory reference and by
	// MD<23:8> otherwise, so those two page numbers are the entry the
	// machine read THROUGH and the entry a SRCMAP read LOOKED AT.  In
	// PDL-BUFFER-REFILL the microcode does one of each.
	say("  MD is the word the last COMPLETED read left: a reference the map refuses starts no bus "
	    "cycle at all, so a read that page-faulted never strobed -LOADMD and what stands here is "
	    "the word before it.  Compare it with muir's md at the same microcycle");
	if (v->md_page == v->vma_page)
		say("  MD and VMA name the same page %o.  The map is indexed by VMA<23:8> on a memory "
		    "reference and by MD<23:8> otherwise (cadr_microcycle.sv:1006, the 74S258s at VMAS "
		    "1C20), so a SRCMAP read here looks at the entry the machine also reads through",
		    v->md_page);
	else
		say("  MD and VMA name DIFFERENT pages, %o and %o.  The map is indexed by VMA<23:8> on a "
		    "memory reference and by MD<23:8> otherwise (cadr_microcycle.sv:1006, the 74S258s at "
		    "VMAS 1C20), so a SRCMAP read here looks at a DIFFERENT entry from the one the "
		    "machine reads through", v->md_page, v->vma_page);
	say("  all three are as of the last microcycle boundary, which is exact on a halted machine --- "
	    "halt first if the answer is to mean anything");
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

// The button.  One store; the fabric holds the write's answer off until the
// line is back up, so this returns with the machine already running the PROM.
void cons_boot(struct console *c)
{
	c->write(c, CONS_BOOT, CONS_BOOT_KEY);
	++c->writes;
}

int cons_boot_and_report(struct console *c, unsigned settle_us,
			 struct cons_boot_report *r)
{
	uint16_t pc = 0, f1 = 0;
	memset(r, 0, sizeof *r);
	// Before: where the machine was and how far it had got.  A machine
	// halted from the console answers these perfectly well --- the
	// diagnostic bus does not need the machine to be running --- so a
	// `boot` of a halted machine reports where it was halted.
	r->cycles_before = cons_cycles(c);
	if (cons_spy_read(c, SPY_PC, &pc) < 0)
		r->lost_before = 1;
	r->pc_before = pc & 0x3FFFu;

	cons_boot(c);

	// After: the press's own register, then the machine.  Word 13 is read
	// first because it is the only thing that says the press HAPPENED ---
	// a wrong key is dropped in silence, which is what the key is for, and
	// the count is how a caller tells a press from a typo.
	r->word = c->read(c, CONS_BOOT);
	r->presses = (r->word >> 8) & 0xFFu;
	r->held = r->word & 1u;

	r->cycles_after = cons_cycles(c);
	pc = 0;
	if (cons_spy_read(c, SPY_PC, &pc) < 0)
		r->lost_after = 1;
	r->pc_after = pc & 0x3FFFu;
	if (cons_spy_read(c, SPY_FLAG_1, &f1) < 0)
		r->lost_after = 1;
	else
		r->promdisable = cons_flag1_of(f1).promdisable;

	// **RUNNING IS THE COUNTER MOVING AND NOTHING ELSE**, as it is in
	// `cons_status`: the PC of a machine running the PROM is a moving
	// target and a stopped machine has one too.
	if (c->pause)
		c->pause(c, settle_us);
	{
		const uint64_t later = cons_cycles(c);
		r->running = later != r->cycles_after;
		r->cycles_after = later;
	}
	return (r->lost_before || r->lost_after) ? -1 : 0;
}

int cons_held(const char *path)
{
	return access(path, F_OK) == 0;
}

int cons_release_held(const char *path)
{
	if (unlink(path) == 0)
		return 0;
	// Already gone is the answer this asks for, and is not a failure: the
	// ordinary machine has no marker and `boot` must work on it.
	return errno == ENOENT ? 0 : -1;
}

void cons_read_switch(struct console *c, struct cons_switch *sw)
{
	// ONE read for both bits, so that the pair names one instant.  Two
	// reads would let a switch moved between them report a state the board
	// was never in, which is the same rule the VMA/Q/MD latch is for.
	sw->stat = cons_stat(c);
	sw->held_at_reset = (sw->stat & CONS_ST_HELD_AT_RESET) != 0;
	sw->now = (sw->stat & CONS_ST_SWITCH_NOW) != 0;
}

// **THE DEBUG CABLE'S ROLE, page 0's word 14.**  A write of a key and of
// nothing else; every other value is dropped by the fabric, which is the same
// guard the machine's reset and the light panel's button carry and is there
// for the same reason --- a value that means nothing, zero off a dead bus or
// all ones off an undriven one, must not change what the connector is doing.
//
// Neither of these waits for anything: the write completes at once and the
// role may still be refused.  `cons_read_debug_cable` is how a caller finds
// out, and `cons_say_debug_cable` is what says it in words.
void cons_debug_cable_connect(struct console *c)
{
	c->write(c, CONS_DEBUG, CONS_DEBUG_CONNECT_KEY);
}

void cons_debug_cable_disconnect(struct console *c)
{
	c->write(c, CONS_DEBUG, CONS_DEBUG_DISCONNECT_KEY);
}

// And which way round the ribbon was made.  Three keys and no complement,
// because there are three of them; every other value is dropped, and so is
// any of these while this board is already the debugger.
void cons_debug_cable_wiring(struct console *c, int wire)
{
	uint32_t key;

	switch (wire) {
	case CONS_DBG_WIRE_AUTO_IDLE:
		key = CONS_DEBUG_WIRE_AUTO_KEY;
		break;
	case CONS_DBG_WIRE_STRAIGHT:
		key = CONS_DEBUG_WIRE_STRAIGHT_KEY;
		break;
	case CONS_DBG_WIRE_CROSSOVER:
		key = CONS_DEBUG_WIRE_CROSSOVER_KEY;
		break;
	default:
		return;
	}
	c->write(c, CONS_DEBUG, key);
}

void cons_read_debug_cable(struct console *c, struct cons_debug_cable *d)
{
	// ONE read for all of it, so that the bits name one instant --- the
	// rule the switch's two bits and the VMA/Q/MD latch are both for.
	d->word = c->read(c, CONS_DEBUG);
	d->engaged = (d->word & CONS_DBG_ENGAGED) != 0;
	d->asked = (d->word & CONS_DBG_ASKED) != 0;
	d->foreign = (d->word & CONS_DBG_FOREIGN) != 0;
	d->peer_far = (d->word & CONS_DBG_PEER_FAR) != 0;
	d->active = (d->word & CONS_DBG_ACTIVE) != 0;
	d->live = (d->word & CONS_DBG_LIVE) != 0;
	d->wire = (int)((d->word >> CONS_DBG_WIRE_SHIFT) & CONS_DBG_WIRE_MASK);
	d->connects = (d->word >> 9) & 0x7Fu;
	// **AND THE TWO COUNTS ARE A SECOND READ, WHICH IS RIGHT HERE AND IS
	// NOT ELSEWHERE.**  The bits above name one instant because the fabric
	// presents them in one word: a role and the reason it was refused would
	// contradict each other if they came from two.  These two are counters,
	// and a counter read a few microseconds after a flag is still the same
	// counter --- what would be wrong is reading the two COUNTS apart, and
	// they are one word.
	d->frames = c->read(c, CONS_DEBUG_FRAMES);
	d->frames_ok = (d->frames >> 24) == CONS_DEBUG_FRAMES_MARK;
	d->heard = CONS_DEBUG_FRAMES_HEARD(d->frames);
	d->refused = CONS_DEBUG_FRAMES_REFUSED(d->frames);
}

// What came of the wiring, in words.  The eight values are one axis and each
// says both which way the board is driving and how it came to think so, which
// is what somebody diagnosing a cable needs: a board that was TOLD and a board
// that FOUND OUT are different kinds of evidence.
static const char *wire_words(int wire)
{
	switch (wire) {
	case CONS_DBG_WIRE_STRAIGHT:
		return "straight, set";
	case CONS_DBG_WIRE_CROSSOVER:
		return "crossover, set";
	case CONS_DBG_WIRE_LISTENING:
		return "looking for the far end, driving nothing";
	case CONS_DBG_WIRE_ST_FOUND:
		return "straight, detected";
	case CONS_DBG_WIRE_CR_FOUND:
		return "crossover, detected";
	case CONS_DBG_WIRE_ST_ASSUMED:
		return "nothing heard, assuming straight";
	case CONS_DBG_WIRE_CR_ASSUMED:
		return "nothing heard, assuming crossover";
	default:
		return "auto --- it is looked for when this board takes the role";
	}
}

void cons_say_debug_cable(const struct cons_debug_cable *d)
{
	// **THE WIRING IS ITS OWN LINE AND IS ALWAYS SAID.**  It is a different
	// fact from the role --- which end of the cable this board is, against
	// which four pins that end drives --- and a board that is a debuggee
	// today still holds the setting it will use when it is told to connect.
	// Somebody checking what a card set reads it here without having to
	// take the role first.
	say("debug cable: the wiring is %s", wire_words(d->wire));
	// **AND WHAT THE CABLE IS DOING TO THE FRAMES.**  The pins of a Pmod row
	// are coupled pairs; this link drives one signal a pair with the partner
	// held low as a guard, and the counts say whether an edge still couples
	// into the strobe beside it; a frame that catches one
	// fails its marker or parity and is dropped, and the next carries the
	// levels again.  So a refusal is not a fault to act on and a RATE of
	// them is: the two numbers are printed together for that reason.
	if (d->frames_ok)
		say("debug cable: %u frame(s) heard, %u refused%s", d->heard, d->refused,
		    d->refused == 0 ? "" :
		    " --- a refused frame costs a frame and never a word, and what the"
		    " number says is how much of the cable's time that costs");
	else
		say("debug cable: the frame counts did not carry their marker (0x%08x);"
		    " this fabric is older than they are", d->frames);
	if (d->engaged)
		// **AND AN ANSWER COMES FROM A DEBUGGEE.**  `live` says good
		// frames are arriving and `foreign` says they are a second
		// DEBUGGER's, which on a mirrored ribbon is where the other
		// board's requests land.  The fabric will not take one word of
		// them, and neither will this line call them an answer.
		say("debug cable: this board is the DEBUGGER on Pmod JA%s",
		    d->foreign ? ", and what is on the connector is ANOTHER DEBUGGER, whose "
				 "frames are not an answer and are not taken for one"
		    : d->live ? ", and the board at the far end is answering"
			      : ", and nothing is answering it yet");
	else if (d->asked)
		// **THE ONE CASE THE TWO BITS EXIST FOR.**  A board that can
		// see a debugger already on the connector holds its own
		// engagement down, and the first board told is the one that
		// has the role.  Without this line a refused connect would
		// read as a console that did nothing.
		say("debug cable: this board ASKED to be the debugger on Pmod JA and does not "
		    "have the role%s",
		    d->foreign ? ": somebody else is driving the connector, and the first "
				 "board told is the one that has it"
			       : ", and nothing on the connector says why");
	else
		say("debug cable: this board is a DEBUGGEE on Pmod JA, which is what a CADR is "
		    "with nothing set%s",
		    // **AND THE ONE CASE THAT NAMES A CROSSED CABLE FROM THIS
		    // END.**  A debuggee listens on the low four and answers on
		    // the high four, so frames on the high four can only be the
		    // far board's low four reaching the wrong pins.  Said before
		    // the plain `foreign`, because it is the more particular
		    // fact and the two are true together.
		    d->peer_far ? ", AND WHAT IS ON THE CONNECTOR IS ARRIVING ON THE FOUR "
				  "PINS THIS BOARD ANSWERS ON: the two ends disagree about "
				  "the cable's wiring, and the board at the far end is the "
				  "one with the setting"
		    : d->foreign ? ", and a debugger is on the connector now"
		    : d->active ? ", and something is driving the connector"
				: ", with nothing driving the connector");
	// The DBGIN page is never switched off by any of this, and saying so is
	// worth a line: somebody reading `DEBUGGER` above could otherwise think
	// this board had stopped being debuggable.
	say("debug cable: %u connect(s) since the console came up; the register window is a "
	    "debugger of its own and is never switched off, so this board is debuggable "
	    "through it either way",
	    d->connects);
}

void cons_say_switch(const struct cons_switch *sw)
{
	if (sw->held_at_reset)
		say("SW0 held the machine at the last reset: it came up with RUN clear, as a "
		    "CADR is when the power comes on, and only the boot button starts it");
	else
		say("SW0 did not hold the machine: it came out of reset running, which is what "
		    "a board switched on to be used does");
	// **AND THE DISAGREEMENT IS THE THING WORTH SAYING OUT LOUD.**  The
	// fabric reads the switch at the machine's own reset arms and at no
	// other instant, so a switch moved since then has changed nothing.
	// Without this line the two bits would look like a console that
	// contradicts itself.
	if (sw->now != sw->held_at_reset)
		say("and SW0 is %s NOW, so somebody has moved it since: that changes nothing "
		    "until the next reset, the switch being read only there",
		    sw->now ? "ON" : "OFF");
	else
		say("and SW0 is still %s", sw->now ? "ON" : "OFF");
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
		// **AND IT IS NOT READ AT ONCE, WHICH IS A RACE THAT WAS AN
		// ACCIDENT OF TWO RATES UNTIL IT WAS MEASURED.**  SSTEP and
		// SSDONE are STEP registered once and twice on MCLK5A, so
		// SSDONE rises TWO master clocks after the write lands --- 88
		// ticks at extra slow, 58 at normal --- and a reader quick
		// enough off the mark sees it still down on a machine that
		// stepped perfectly.  An ARM through /dev/mem was never quick
		// enough and the bit read up by luck.  A soft RISC-V core in
		// fabric IS quick enough, and that was measured rather than
		// reasoned: it reported `SSDONE 0` on a step whose CYCLES had
		// moved by exactly one, and one build later, on the same
		// program, `SSDONE 1`.  A bit whose value depends on how fast
		// the processor reading it happens to be is not a witness.
		//
		// One microsecond is 100 ticks, more than the two master
		// clocks at either speed, and it is a bound rather than a
		// poll: on a fabric whose step does not work at all --- which
		// this program shipped against for months --- a poll would not
		// return.
		if (c->pause)
			c->pause(c, 1);
		// **SSDONE IS READ WHILE STEP IS STILL UP, AND THAT IS NOT A
		// CONVENIENCE.**  SSTEP and SSDONE are STEP registered once
		// and twice on MCLK5A, so SSDONE rises one master clock after
		// the step's microcycle and falls two master clocks after STEP
		// is lowered.  A diagnostic cycle is longer than that, so a
		// read taken after the lowering sees it down on a machine that
		// stepped perfectly --- which would make the console report a
		// fault that is its own reading order.
		if (k + 1 == n) {
			uint16_t f1 = 0;
			if (cons_spy_read(c, SPY_FLAG_1, &f1) == 0)
				s->ssdone = !!(f1 & (1u << 9));
		}
		cons_spy_write(c, SPY_CLK, 0);
	}
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
	cons_read_machine_words(c, &r->mw);
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
	cons_read_machine_words(c, &st->mw);
	if (c->pause)
		c->pause(c, settle_us);
	st->cycles_second = cons_cycles(c);
	st->ticks = cons_ticks(c);
	// SW0, off the STAT word.  It is taken AFTER the second sample of
	// CYCLES on purpose: what the switch did at the last reset does not
	// change while this runs, so it belongs outside the bracket the two
	// samples make rather than inside it, where one more register read
	// would widen the window `running` is measured over.
	cons_read_switch(c, &st->sw);
	// And which build the fabric is, outside the bracket for the switch's
	// reason: it is a constant from configuration onward, so a read of it
	// inside the two samples of CYCLES would widen the window `running` is
	// measured over and tell nobody anything new.
	st->build = cons_build_of(cons_build_word(c));
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
	if (!s->asked)
		return;
	// **THE TWO WAYS A STEP GOES WRONG ARE OPPOSITE AND BOTH ARE SILENT.**
	// Nothing moved means the STEP bit reached nothing --- which is what
	// this console reported for as long as the clock control register was
	// one bit wide.  More than one microcycle a step means the bit was
	// taken as a level rather than as an edge, and the machine ran on
	// while it was up.  Either way the number is printed and named.
	if (s->moved == 0) {
		say("step: THE MACHINE DID NOT MOVE.  Single-stepping is SSTEP and SSDONE, two flip flops of the "
		    "74S174 at OLORD1 1A10, and MACHRUN's first term SSTEP AND -SSDONE");
		say("step: the clock control register is EADR 3 and five bits wide --- RUN, STEP, NOP11, IDEBUG, "
		    "LDSTAT --- and a fabric that takes only bit 0 clocks nothing for the 2-then-0 CC-CLOCK writes");
	} else if (s->moved != s->asked) {
		say("step: THE MACHINE RAN %llu MICROCYCLES FOR %u STEP(S).  Raising STEP clocks the machine ONCE; "
		    "SSDONE catches SSTEP at the next master clock and holds MACHRUN down until STEP is lowered",
		    (unsigned long long)s->moved, s->asked);
	} else if (!s->ssdone) {
		say("step: the machine moved, but FLAG-1 bit 9 SSDONE is down.  That bit is the board's own witness "
		    "that the step it was asked for has run, and it is read here while STEP is still up, where it "
		    "must be set: the count and the witness disagree");
	}
}

void cons_say_boot(const struct cons_boot_report *r)
{
	say("boot: the light panel's button pressed and let go --- "
	    "word 13 reads 0x%08x, %u press%s since the console came up, the line %s",
	    r->word, r->presses, r->presses == 1 ? "" : "es",
	    r->held ? "STILL DOWN" : "back up");
	if (r->lost_before || r->lost_after) {
		say("boot: a diagnostic cycle was not answered, so the PC either "
		    "side of the press is not data");
	} else {
		say("boot: PC %o before, %o after; CYCLES %llu then %llu",
		    r->pc_before, r->pc_after,
		    (unsigned long long)r->cycles_before,
		    (unsigned long long)r->cycles_after);
	}
	say("boot: %s, PROMDISABLE %s --- %s",
	    r->running ? "RUNNING" : "NOT RUNNING",
	    r->promdisable ? "set" : "clear",
	    r->running && !r->promdisable
		    ? "the boot PROM is running from word 0 again"
		    : "the machine did not come back: ask `status`");
}

// ---------------------------------------------------------------------------
// **WHICH BUILD THE FABRIC IS**, page 2's word 32
// ---------------------------------------------------------------------------
//
// `tools/build_stamp.tcl` is the authority on the format and this reads what
// it writes: the commit's first seven hex digits in the top 28 bits and a
// nibble saying how the tree stood.  Nothing here formats a number the tcl
// could not have produced, and the one value it reserves --- all ones, which
// an unprogrammed part reads and which a bitstream built before the flows
// stamped them leaves behind --- is reported as "no stamp" and never as a
// commit.
//
// **PURE, AND IT IS KEPT THAT WAY.**  This file was once compiled a second
// time for a bare-metal core with picolibc and no kernel under it, where a
// decode that reached for a file or a process did not merely waste space: it
// stopped the link.  That second build is gone and no check enforces the rule
// now, so it is written down here instead --- what is in this file is a cycle
// on the bus and arithmetic on what comes back, and nothing else.
struct cons_build cons_build_of(uint32_t w)
{
	struct cons_build b;
	memset(&b, 0, sizeof b);
	b.word = w;
	if (w == CONS_BUILD_NONE)
		return b;		/* stamped stays 0; there is nothing to read */
	b.stamped = 1;
	b.commit = w >> 4;
	b.tree = w & 0xFu;
	switch (b.tree) {
	case CONS_BUILD_CLEAN:					b.known = 1; break;
	case CONS_BUILD_MODIFIED:	b.modified = 1;		b.known = 1; break;
	case CONS_BUILD_UNTRACKED:	b.untracked = 1;	b.known = 1; break;
	case CONS_BUILD_BOTH:		b.modified = 1;
					b.untracked = 1;	b.known = 1; break;
	case CONS_BUILD_NO_TREE:				b.known = 1;
		// `0000000f` is the whole word the stamp writes when git said
		// nothing at all, and that is a different fact from a known
		// commit whose tree could not be read.  Running the two
		// together would print `commit 0000000`.
		b.no_git = (b.commit == 0);
		break;
	default:
		break;
	}
	return b;
}

const char *cons_build_tree_words(const struct cons_build *b)
{
	if (!b->known)
		return "a state this program does not know";
	if (b->tree == CONS_BUILD_NO_TREE)
		return "unknown --- git could not say";
	if (b->modified && b->untracked)
		return "modified and carrying an untracked file";
	if (b->modified)
		return "modified";
	if (b->untracked)
		return "carrying an untracked file";
	return "clean";
}

void cons_say_build(const struct cons_build *b)
{
	if (!b->stamped) {
		say("fabric: no build stamp --- this bitstream was built before the flows "
		    "stamped them, or the part is not configured; all ones is the one "
		    "value a build can never be");
		return;
	}
	if (b->no_git) {
		say("fabric: build %08x --- no git information: it was not built from a "
		    "checkout, so nothing here names a commit", b->word);
		return;
	}
	say("fabric: build %08x --- commit %07x, tree %s",
	    b->word, b->commit, cons_build_tree_words(b));
	// **AND A TREE THAT WAS NOT CLEAN IS WORTH SAYING TWICE.**  A bring-up
	// run against an uncommitted change is legitimate work and the stamp
	// records it rather than refusing it; what must not happen is somebody
	// reading the commit off this line and believing the fabric is what
	// that commit builds.
	if (b->modified || b->untracked)
		say("fabric: so the commit names where this build STARTED and not what it "
		    "is --- the tree had changes in it that are in no commit");
	if (!b->known)
		say("fabric: and the low nibble is %x, which is not one of the five the "
		    "stamp's format defines, so the commit above may not be one either",
		    b->tree);
}

uint32_t cons_build_word(struct console *c)
{
	return c->read(c, CONS_BUILD);
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
	cons_say_machine_words(&st->mw);
	say("status: FLAG-1 0x%04x: SRUN %s, SSDONE %s, ERR %s, -STATHALT %s, -WAIT %s, PROMDISABLE %s",
	    st->flag1_word, st->f1.srun ? "up" : "down", st->f1.ssdone ? "up" : "down",
	    st->f1.err ? "up" : "down", st->f1.stathalt ? "halted" : "clear",
	    st->f1.wait ? "waiting" : "clear", st->f1.promdisable ? "set" : "clear");
	if (st->why)
		say("status: %s", st->why);
	// **AND WHETHER IT EVER RAN AT ALL.**  A machine SW0 held has SRUN down
	// and reads exactly like one somebody halted, so the reason above would
	// be true and would send a person looking for whoever halted it.  This
	// is printed on a held machine and on a moved switch, and on nothing
	// else: a board that boots itself and whose switch has not been touched
	// has nothing to say about a switch.
	if (st->sw.held_at_reset)
		say("status: and SW0 held this machine at the last reset --- it came up with RUN "
		    "clear and has never run, as a CADR is when the power comes on; "
		    "`boot` presses the button that starts it");
	if (st->sw.now != st->sw.held_at_reset)
		say("status: SW0 is %s NOW, which is not what it was at the last reset; the switch "
		    "is read only there, so that changes nothing until the next one",
		    st->sw.now ? "ON" : "OFF");
	// **AND WHICH BUILD THE FABRIC IS**, last, because it is about the
	// bitstream and everything above it is about the machine.  It is the
	// answer to the question this project has twice had to reconstruct from
	// a file's timestamp.
	cons_say_build(&st->build);
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
	say("and page 0's words 7, 8 and 9, which are the machine's own and are on no diagnostic register:");
	cons_say_machine_words(&r->mw);
}

// --- the backplane's display boards, page 2's word 33 and pages 4 and 5 ---
//
// A CADR carries one display board or two, and which is a fact about the
// backplane rather than about the machine.  `console_face.h` has the argument
// for putting it on page 2 beside the build stamp and for the three keys.

void cons_read_display(struct console *c, struct cons_display *d)
{
	// ONE read for both bits, so that they name one instant: a word saying
	// the first board is a LISPM TV and the second is fitted has to be one
	// backplane and not two reads of a changing one.
	d->word = c->read(c, CONS_DISPLAY);
	d->mark_ok = CONS_TV_MARK_OF(d->word) == CONS_TV_MARK;
	d->lispm = (d->word & CONS_TV_LISPM) != 0;
	d->color = (d->word & CONS_TV_COLOR) != 0;
}

void cons_set_tv_board(struct console *c, int lispm)
{
	c->write(c, CONS_DISPLAY, lispm ? CONS_TV_LISPM_KEY : CONS_TV_SIMPLE_KEY);
	++c->writes;
}

void cons_set_color_tv(struct console *c, int on)
{
	c->write(c, CONS_DISPLAY, on ? CONS_COLOR_TV_KEY : CONS_NO_COLOR_TV_KEY);
	++c->writes;
}

void cons_read_hdmi(struct console *c, struct cons_hdmi *h)
{
	h->word = c->read(c, CONS_HDMI);
	h->mark_ok = CONS_HDMI_MARK_OF(h->word) == CONS_HDMI_MARK;
	h->first = (h->word & CONS_HDMI_FIRST) != 0;
	h->color = (h->word & CONS_HDMI_COLOR) != 0;
	h->rotate = (int)((h->word >> CONS_HDMI_ROT_SHIFT) & CONS_HDMI_ROT_MASK);
	h->mode = (int)((h->word >> CONS_HDMI_MODE_SHIFT) & CONS_HDMI_MODE_MASK);
}

int cons_set_hdmi_output(struct console *c, int first, int color)
{
	uint32_t key;
	if (first && color)
		key = CONS_HDMI_BOTH_KEY;
	else if (color)
		key = CONS_HDMI_COLOR_KEY;
	else if (first)
		key = CONS_HDMI_TV_KEY;
	else
		return -1;
	c->write(c, CONS_HDMI, key);
	++c->writes;
	return 0;
}

int cons_set_hdmi_rotate(struct console *c, int rot)
{
	uint32_t key;
	if (rot == CONS_HDMI_UPRIGHT)
		key = CONS_HDMI_UP_KEY;
	else if (rot == CONS_HDMI_CW)
		key = CONS_HDMI_CW_KEY;
	else if (rot == CONS_HDMI_CCW)
		key = CONS_HDMI_CCW_KEY;
	else
		return -1;
	c->write(c, CONS_HDMI, key);
	++c->writes;
	return 0;
}

const char *cons_hdmi_mode_name(int mode)
{
	switch (mode) {
	case CONS_HDMI_1280: return "1280x1024 at 60 Hz";
	case CONS_HDMI_1400: return "1400x1050 at 60 Hz, reduced blanking";
	case CONS_HDMI_1920: return "1920x1080 at 30 Hz";
	default: return "a mode this program does not know";
	}
}

void cons_say_hdmi(const struct cons_hdmi *h)
{
	if (!h->mark_ok) {
		say("hdmi: word 34 did not carry its marker (0x%08x);"
		    " this fabric is older than it is", h->word);
		return;
	}
	if (h->first && h->color)
		say("hdmi: both screens, the color board drawn over the first");
	else if (h->color)
		say("hdmi: the color board alone");
	else if (h->first)
		say("hdmi: the first display alone");
	else
		say("hdmi: neither screen --- the monitor is black");
	switch (h->rotate) {
	case CONS_HDMI_CW:  say("hdmi: a quarter turn clockwise"); break;
	case CONS_HDMI_CCW: say("hdmi: a quarter turn anticlockwise"); break;
	default:            say("hdmi: upright"); break;
	}
	// **THE MODE IS WHAT THE BITSTREAM CARRIES AND NOTHING HERE CAN MOVE
	// IT**, so it is said as a fact about the fabric rather than as a
	// setting somebody forgot to change.
	say("hdmi: %s --- the mode this bitstream was built with",
	    cons_hdmi_mode_name(h->mode));
}

void cons_read_color_map(struct console *c, int board,
			 uint8_t map[CONS_MAP_COLORS][CONS_MAP_CHANNELS])
{
	for (int color = 0; color < CONS_MAP_COLORS; ++color) {
		const uint32_t w = c->read(c, CONS_COLOR_MAP_WORD(board, color));
		map[color][0] = (uint8_t)CONS_MAP_RED(w);
		map[color][1] = (uint8_t)CONS_MAP_GREEN(w);
		map[color][2] = (uint8_t)CONS_MAP_BLUE(w);
	}
}

void cons_say_display(const struct cons_display *d)
{
	if (!d->mark_ok) {
		// The marker is what tells a fabric older than this word from a
		// backplane with nothing set: both read zero in the two bits.
		say("display: word 33 did not carry its marker (0x%08x);"
		    " this fabric is older than it is", d->word);
		return;
	}
	say("display: the first board is a %s", d->lispm ? "LISPM TV" : "SIMPLE TV");
	// **AND THE SECOND BOARD'S ABSENCE IS A FACT AND NOT A SILENCE.**  A
	// machine with no color board gives the NXM at `0o17200000` and
	// `0o17377750`, which is what `COLOR-EXISTS-P` probes for, so saying
	// nothing here would leave a person wondering whether the word was
	// read at all.
	say("display: %s", d->color
	    ? "a color TV is fitted, at 0o17200000 with its registers at 0o17377750"
	    : "no color TV --- those addresses give the NXM, which is how the band finds out");
}
