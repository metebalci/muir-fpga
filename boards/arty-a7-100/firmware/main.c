// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The first firmware: what a soft processing system can say about the machine
// beside it before anything else is built.
//
// **IT IS `cadr-console` WITH THE OPERATING SYSTEM TAKEN OUT.**  The console's
// whole vocabulary --- halt, the registers, step, start --- is
// `console_face.c`, which is the Arty Z7-20's file compiled here unchanged;
// the disk pack side's is `pack_side.c`, the same way.  What this file
// supplies is the two things those two need from their surroundings and
// nothing more: an access layer that is a load and a store where Linux has an
// `mmap`, and a `say()` that is a UART where Linux has a `FILE *`.  **If this
// firmware had its own copy of either driver it would be the beginning of two
// descriptions of one register face**, and this repository's own record of
// what that costs fills a page.
//
// WHAT IT DOES, in order, and each step is a line on the wire:
//
//   the banner, and this system's own two faces answering
//   the console's IDENT, which must be "CONS"
//   whether the machine is running, measured rather than inferred: CYCLES
//     twice with a wait between them, because a halted machine cannot move it
//   halt, and then PC and FLAG-1 off the diagnostic bus
//   one step, and the count CYCLES moved by, which must be exactly one
//   start again, and CYCLES moving again
//   the disk pack face's IDENT, which must be "PACK"
//   the I/O board's three faces behind the same splitter: "CHAO", "SERI" and
//     "INPT", at the pages the Linux programs use
//   the default slave, which must read "NONE" --- the proof that an address
//     nothing implements is ANSWERED and does not hang the core
//   0x8000_1000, where the debug cable's register window sits on the two Zynq
//     boards, which on THIS board must read "NONE" as well: there is no muir
//     here to play a debugger in software, the debugger is a second board on
//     the Pmod, and the window is not in the design
//   main memory, through the DDR window: a record written and read back, a
//     byte store refused, and the disk pack face fetching the record and
//     writing it back where the window reads it
//   the disk pack face's interrupt, at the fast interrupt `soc.h` names
//   a round of back-to-back loads at five places, one of them main memory
//   a summary naming how many of the checks failed, and then an idle loop
//     that takes four commands from the wire
//
// **EVERY ONE OF THOSE IS AN ASSERTION AND NOT A PRINT.**  A firmware that
// read a face and printed whatever came back would say "IDENT 00000000" on a
// bus that was not answering at all and look exactly like one that worked.
// So each reads, compares against the constant the face's own header gives,
// counts a failure, and the summary line carries the count --- which is what
// `tb/cadr_soc_tb.cpp` asserts, line by line, against a real `cadr_machine`
// running MIT's boot PROM.

#include "soc.h"

#include <chaos_face.h>
#include <console_face.h>
#include <input_face.h>
#include <pack_side.h>
#include <serial_face.h>

#include <cadr/cadr_log.h>

#include <stdint.h>

// --- the access layer ----------------------------------------------------
//
// The whole of what replaces `/dev/mem` and `mmap`.  Both faces are already at
// their addresses; a load is the read and a store is the write.

static uint32_t con_read(struct console *c, unsigned word)
{
	c->reads++;
	return soc_rd(CONS_REG_BASE + 4u * word);
}

static void con_write(struct console *c, unsigned word, uint32_t v)
{
	c->writes++;
	soc_wr(CONS_REG_BASE + 4u * word, v);
}

static void con_pause(struct console *c, unsigned us)
{
	(void)c;
	soc_delay_us(us);
}

static uint32_t pack_read(struct pack_side *ps, unsigned reg)
{
	(void)ps;
	return soc_rd(PS_REG_BASE + 4u * reg);
}

static void pack_write(struct pack_side *ps, unsigned reg, uint32_t v)
{
	(void)ps;
	soc_wr(PS_REG_BASE + 4u * reg, v);
}

static void pack_pause(struct pack_side *ps)
{
	(void)ps;
	soc_delay_us(1);
}

// --- what a four-letter identifier reads as ------------------------------
//
// Every face in this repository answers with four printable bytes, most
// significant first, so that the first load a program makes tells it what it
// is talking to.  Printing them as characters is what makes a wrong answer
// legible: "NONE" where "CONS" was wanted says which slave answered, where a
// hex word says only that something did.

static void ident4(uint32_t w, char *out)
{
	out[0] = (char)((w >> 24) & 0xFF);
	out[1] = (char)((w >> 16) & 0xFF);
	out[2] = (char)((w >> 8) & 0xFF);
	out[3] = (char)(w & 0xFF);
	for (int i = 0; i < 4; ++i)
		if (out[i] < 0x20 || out[i] > 0x7E)
			out[i] = '.';
	out[4] = 0;
}

static unsigned failures;

// Read one word and hold it to a constant.  `what` names the face and `where`
// its address, so that a failure line says which of them did not answer and
// not merely that one did not.
static uint32_t expect(const char *what, uint32_t addr, uint32_t want)
{
	uint32_t got = soc_rd(addr);
	char g[5], w[5];
	ident4(got, g);
	ident4(want, w);
	if (got == want) {
		say("%s at 0x%08lx answers %s", what, (unsigned long)addr, g);
	} else {
		// **uint32_t IS `long` ON THIS TARGET AND `int` ON THE OTHER
		// BOARD's**, both of them 32 bits.  The casts are what let one
		// format string be right in both places; the shared drivers
		// print `%08x` and are compiled here with the format warning
		// off for exactly this reason, which the Makefile says at the
		// rule.
		say("%s at 0x%08lx answers %s (0x%08lx), wanting %s (0x%08lx)",
		    what, (unsigned long)addr, g, (unsigned long)got, w,
		    (unsigned long)want);
		failures++;
	}
	return got;
}

// --- the machine ---------------------------------------------------------

static struct console con;

// --- main memory, through the window --------------------------------------
//
// **THE RECORD THE DISK PACK FACE MOVES, AT THE ADDRESSES ITS LINUX PROGRAM
// USES.**  A record is the block's 256 words, the header and its two
// checkwords, and a pad after them that the face never writes.  The disk pack
// program puts them in the spare above the display, a fetch area and a
// write-back area 2 KB apart, and so does this.
#define REC_WORDS  259u
#define REC_FETCH  0x1C800000u
#define REC_BACK   0x1C800800u
#define REC_SLOT   1u
#define REC_TAG    0x00123456u

// Two families of word, each injective in its address and neither able to be
// the other at these addresses: the record, and the poison the write-back
// area holds before the face writes into it.  A write-back that moved nothing
// reads as poison, and one that moved the wrong words reads as the wrong
// record words.
static uint32_t rec_word(uint32_t addr) { return 0x5EC00000u ^ addr; }
static uint32_t rec_poison(uint32_t addr) { return ~addr; }

static int have_memory;

static int machine_running(unsigned settle_us, uint64_t *moved)
{
	uint64_t a = cons_cycles(&con);
	soc_delay_us(settle_us);
	uint64_t b = cons_cycles(&con);
	*moved = b - a;
	return b != a;
}

static void say_flag1(const char *lead, uint16_t f1)
{
	struct cons_flag1 f = cons_flag1_of(f1);
	say("%s FLAG-1 0x%04x SRUN %d ERR %d -WAIT %d PROMDISABLE %d STATHALT %d",
	    lead, f1, f.srun, f.err, f.wait, f.promdisable, f.stathalt);
}

// The four commands the idle loop takes.  **THE CONSOLE'S OWN WORDS**, and
// deliberately the same four `cadr-console` offers, so that somebody who knows
// one knows the other.
static void say_status(void)
{
	uint16_t pc = 0, f1 = 0;
	uint64_t moved = 0;
	int running = machine_running(2000, &moved);

	if (cons_spy_read(&con, SPY_PC, &pc) != 0) {
		say("the diagnostic cycle was not answered: nothing to report");
		return;
	}
	(void)cons_spy_read(&con, SPY_FLAG_1, &f1);
	say("%s, %llu microcycles in 2000 us, PC 0o%o",
	    running ? "RUNNING" : "NOT RUNNING", (unsigned long long)moved, pc);
	say_flag1(running ? "running:" : "stopped:", f1);
}

int main(void)
{
	cadr_log_init("cadr-soc: ", NULL);

	say("the soft processing system on an Arty A7-100: ibex rv32imc in fabric");

	// This system's own two faces first.  A UART that is not answering
	// cannot report anything, so the very first line has already proved
	// the wire; what this proves is the REGISTER, which is a different
	// claim --- a transmitter wired straight to a pin would print the
	// banner and read zeros here.
	{
		uint32_t u = soc_rd(SOC_UART_BASE + SOC_UART_R_IDENT);
		uint32_t t = soc_rd(SOC_TIMER_BASE + SOC_TIMER_R_IDENT);
		char a[5], b[5];
		ident4(u, a);
		ident4(t, b);
		if (u != SOC_UART_IDENT || t != SOC_TIMER_IDENT)
			failures++;
		say("UART %s, timer %s, %u ticks a microsecond",
		    a, b, (unsigned)soc_ticks_per_us());
	}

	cons_init(&con);
	con.read = con_read;
	con.write = con_write;
	con.pause = con_pause;

	expect("the console", CONS_REG_BASE, CONS_IDENT_WORD);

	// **AND WHICH BUILD THIS FABRIC IS**, page 2's word 32, straight after
	// the face has been shown to be there.  `tools/build_stamp.tcl` wrote
	// the commit and the tree's state into `BITSTREAM.CONFIG.USR_ACCESS`
	// before this bitstream was written; `cadr_usr_access.sv` reads them
	// back out of the part's AXSS register and the console's page 2 carries
	// them here.  The same eight digits are in the JTAG USERCODE register,
	// so somebody with a cable and this banner have compared two registers
	// loaded from one value over paths that share nothing.
	//
	// The line is `cons_say_build`'s and not this file's, so the banner and
	// `cadr-console status` on a Zynq board print the same words --- one
	// sentence in one place, which cannot drift.
	{
		const struct cons_build b = cons_build_of(cons_build_word(&con));
		cons_say_build(&b);
	}

	// **RUNNING IS MEASURED AND NOT INFERRED**, which is `cons_status`'s own
	// rule: `Machine::cycles` does not advance on a halted master clock, so
	// nothing but the counter can answer this.
	{
		uint64_t moved = 0;
		int running = machine_running(2000, &moved);
		say("the machine was %s, %llu microcycles in 2000 us",
		    running ? "RUNNING" : "NOT RUNNING",
		    (unsigned long long)moved);
		if (!running)
			failures++;
	}

	// Halt, and then look.  The registers are sampled while the datapath
	// moves, so a read taken of a running machine is a torn sample --- this
	// project has a whole paragraph about a torn FLAG-1 that read as
	// catastrophic memory failure on a machine that was perfectly well.
	cons_halt(&con);
	{
		uint16_t pc = 0, f1 = 0;
		uint64_t moved = 0;
		int still = machine_running(1000, &moved);
		if (still)
			failures++;
		if (cons_spy_read(&con, SPY_PC, &pc) != 0 ||
		    cons_spy_read(&con, SPY_FLAG_1, &f1) != 0) {
			say("halted, but the diagnostic cycle was not answered");
			failures++;
		} else {
			say("halted at PC 0o%o, %llu microcycles in 1000 us",
			    pc, (unsigned long long)moved);
			say_flag1("halted:", f1);
			if (cons_flag1_of(f1).srun)
				failures++;
		}
	}

	// One step.  **THE COUNT IS THE WITNESS**: `MACHRUN`'s first term is
	// `SSTEP AND -SSDONE`, so the machine runs for exactly the one master
	// clock in which the first is set and the second is not, and a step
	// that clocked nothing or clocked a stream is the failure this project
	// keeps meeting.
	{
		struct cons_step s;
		cons_step(&con, 1, &s);
		say("stepped %u, CYCLES moved %llu, SSDONE %d",
		    s.asked, (unsigned long long)s.moved, s.ssdone);
		if (s.moved != s.asked || !s.ssdone)
			failures++;
	}

	cons_start(&con);
	{
		uint64_t moved = 0;
		int running = machine_running(2000, &moved);
		say("started: %s, %llu microcycles in 2000 us",
		    running ? "RUNNING" : "NOT RUNNING",
		    (unsigned long long)moved);
		if (!running)
			failures++;
	}

	// The disk pack side, through its own driver.  **IDENT IS REGISTER 7
	// AND NOT REGISTER 0**, which is the pack side's own arrangement and
	// the reason this goes through `ps_ident_ok` rather than reading the
	// base: a firmware that assumed every face puts its identifier first
	// would read PS_ADDR and report whatever Linux last wrote.
	{
		struct pack_side ps;
		uint32_t got = 0;
		char g[5];
		ps_init(&ps);
		ps.read = pack_read;
		ps.write = pack_write;
		ps.pause = pack_pause;
		// **THE TWO SHARED HEADERS DISAGREE ABOUT WHAT "OK" RETURNS, AND
		// THE CHECK FOUND IT.**  `cons_ident_ok` answers 0 for right and
		// -1 for wrong, the way a system call does; `ps_ident_ok`
		// answers TRUE for right, the way a predicate does.  Both are
		// their own file's convention and neither is wrong; a firmware
		// reading one as the other counts a failure that did not happen
		// --- which is exactly what this line did until
		// `tb/cadr_soc_tb.cpp` held the summary to "0 failure(s)" and
		// said so.  A summary line that only ever printed a number
		// nobody compared would have shipped it.
		if (!ps_ident_ok(&ps, &got))
			failures++;
		ident4(got, g);
		say("the disk pack face at 0x%08lx answers %s (register %u)",
		    (unsigned long)PS_REG_BASE, g, (unsigned)PS_IDENT);
	}

	// **AND THE I/O BOARD'S THREE FACES, BEHIND THE SAME SPLITTER AT THE SAME
	// PAGES AS ON THE ZYNQ BOARDS.**  Each identifier is its own header's
	// constant, so a face wired where another should be names itself.
	expect("the Chaosnet cable", CHAOS_REG_BASE, CHAOS_IDENT_WORD);
	expect("the serial line", SER_REG_BASE, SER_IDENT_WORD);
	expect("the keyboard and mouse", IN_REG_BASE, IN_IDENT_WORD);

	// **THE ADDRESS NOTHING IMPLEMENTS, WHICH IS THE ONE THAT MATTERS.**
	// On the Zynq a read nothing answers inside a general-purpose window
	// hangs both ARM cores at one PC each, measured, and no software guard
	// can catch a load that never completes.  A soft core is worse off: it
	// has no interconnect to give it an error response at all.  So the
	// bridge's last port is a catch-all and `cadr_gp0_default.sv` is behind
	// it, and THIS LINE IS THE PROOF --- a firmware that reached this line
	// at all is a firmware whose load came back.
	//
	// **IT USED TO BE `0x4000_1000`, WHICH IS THE CHAOSNET CABLE's PAGE
	// NOW.**  The first page past the four faces is the splitter's own
	// default slave, which is the one this board shares with the Zynq's.
	expect("the default slave", PS_REG_BASE + 0x4000u, 0x4E4F4E45u);

	// **AND THE PAGE THE DEBUG CABLE'S WINDOW HOLDS ON THE OTHER TWO
	// BOARDS, WHICH ON THIS ONE IS NOT A FACE AT ALL.**  This used to read
	// `0x44425547`, "DBUG", off `cadr_debug_window.sv`.  That window exists
	// so that a PROGRAM can be the far end of MIT's debug cable --- muir, on
	// a Zynq board's own ARM cores --- and there is no such program here:
	// the only processor on this board is the one saying this line, and it
	// is the console.  This board's debugger is a SECOND BOARD on the Pmod,
	// which reaches the machine's DBGIN page through the cable's own
	// carrier and never through this bridge.
	//
	// So the window is not in the design and this page is one more address
	// nothing implements.  Reading it is not a leftover: it is the
	// assertion that the catch-all covers the page a face used to hold,
	// which is the one place where "every address is answered" could have
	// been left with a hole and nothing would have said so.
	expect("the window's page", 0x80001000u, 0x4E4F4E45u);

	// **MAIN MEMORY, THROUGH THE WINDOW, AND THE DISK PACK FACE MOVING A
	// RECORD THROUGH IT.**  On the Zynq boards Linux puts a record in DDR and
	// the face fetches it; here this firmware is the one that puts it there.
	//
	// **A BOARD BUILT WITHOUT MEMORY ANSWERS THE WINDOW WITH A FAULT**, and
	// the same firmware runs on both, so the first load is a probe.  A fault
	// there is said and is not a failure: it is the design, not a defect.
	{
		uint32_t cause = 0;
		(void)soc_probe_load(soc_ddr(REC_FETCH), &cause);
		have_memory = (cause == 0);
		if (!have_memory)
			say("the DDR window at 0x%08lx faults (mcause %lu): no memory "
			    "is built into this design", (unsigned long)SOC_DDR_WINDOW,
			    (unsigned long)cause);
	}

	if (have_memory) {
		// The record and its pad, written and read back.
		unsigned wrong = 0;
		for (unsigned i = 0; i <= REC_WORDS; ++i)
			soc_wr(soc_ddr(REC_FETCH + 4u * i), rec_word(REC_FETCH + 4u * i));
		for (unsigned i = 0; i <= REC_WORDS; ++i)
			if (soc_rd(soc_ddr(REC_FETCH + 4u * i)) != rec_word(REC_FETCH + 4u * i))
				wrong++;
		if (wrong)
			failures++;
		say("the DDR window at 0x%08lx wrote %u words at 0x%08lx and read "
		    "%u back wrong", (unsigned long)SOC_DDR_WINDOW, REC_WORDS + 1u,
		    (unsigned long)REC_FETCH, wrong);
	}

	if (have_memory) {
		// **A BYTE STORE IS REFUSED, AND REFUSED MEANS UNWRITTEN.**  The
		// memory port writes whole words, so a byte store would either
		// overwrite the three bytes beside it or need a read and a write the
		// machine could step between.  It must fault, and the word it aimed
		// at must be what it was.
		uint32_t cause = 0;
		uint32_t before = soc_rd(soc_ddr(REC_FETCH));
		soc_probe_store8(soc_ddr(REC_FETCH), 0xA5u, &cause);
		uint32_t after = soc_rd(soc_ddr(REC_FETCH));
		if (cause != SOC_CAUSE_STORE_ACCESS || after != before)
			failures++;
		say("a byte stored into the window is refused with mcause %lu, and "
		    "the word %s", (unsigned long)cause,
		    after == before ? "is unchanged" : "CHANGED");
	}

	{
		struct pack_side ps;
		char why[112];
		uint32_t st = 0;
		ps_init(&ps);
		ps.read = pack_read;
		ps.write = pack_write;
		ps.pause = pack_pause;

		if (have_memory) {
			// **THE FACE FETCHES WHAT THE WINDOW WROTE**, through its own
			// master, `cadr_hp2_mem.sv` and the memory's arbiter.
			int r = ps_fetch(&ps, REC_FETCH, REC_TAG, REC_SLOT, &st, why,
					 sizeof why);
			if (r != 0)
				failures++;
			say("the disk pack face fetched 0x%08lx into slot %u: %s",
			    (unsigned long)REC_FETCH, REC_SLOT, r == 0 ? "done" : why);

			// **AND THE WINDOW READS WHAT THE FACE WROTE BACK**, into an
			// area poisoned first, and to a different address from the one
			// it was fetched from, so a write-back that went where the
			// fetch came from, or moved nothing, reads wrong.  The pad after
			// the record must still be poison, because the face's last beat
			// strobes only its low half.
			//
			// **THIS IS A ROUND TRIP AND IT CANNOT SEE A FAULT THAT IS THE
			// SAME BOTH WAYS**: two halves of a beat swapped on the fetch and
			// swapped back on the write-back agree with themselves.
			// `tb/cadr_a7_mem_tb.cpp` reads the store the face filled
			// directly, which is what holds that.
			for (unsigned i = 0; i <= REC_WORDS; ++i)
				soc_wr(soc_ddr(REC_BACK + 4u * i), rec_poison(REC_BACK + 4u * i));
			r = ps_writeback(&ps, REC_BACK, REC_SLOT, &st, why, sizeof why);
			unsigned wrong = 0;
			for (unsigned i = 0; i < REC_WORDS; ++i)
				if (soc_rd(soc_ddr(REC_BACK + 4u * i)) != rec_word(REC_FETCH + 4u * i))
					wrong++;
			int pad = soc_rd(soc_ddr(REC_BACK + 4u * REC_WORDS)) ==
				  rec_poison(REC_BACK + 4u * REC_WORDS);
			if (r != 0 || wrong || !pad)
				failures++;
			say("the disk pack face wrote slot %u back to 0x%08lx: %s; the "
			    "window read %u of %u words wrong, and the pad after them is "
			    "%s", REC_SLOT, (unsigned long)REC_BACK,
			    r == 0 ? "done" : why, wrong, REC_WORDS,
			    pad ? "untouched" : "WRITTEN");
		}

		// **THE FACE'S INTERRUPT, AT THE WIRE `soc.h` SAYS.**  A take moves
		// no DDR traffic and ends a move all the same, so the face's "a move
		// finished" event is set whether or not there is memory.  Enabled,
		// the face's line rises and `mip` shows fast interrupt 0 and no other
		// face's; disabled, it falls.  Nothing enables the core's own
		// interrupts: `mip` shows the wires as they stand.
		(void)ps_take(&ps, REC_SLOT + 1u, &st, why, sizeof why);
		ps_irqen(&ps, PS_IRQ_DONE);
		soc_delay_us(20);
		uint32_t on = soc_read_mip() & SOC_MIP_FACES;
		ps_irqen(&ps, 0);
		soc_delay_us(20);
		uint32_t off = soc_read_mip() & SOC_MIP_FACES;
		if (on != SOC_MIP_FAST(0) || off != 0)
			failures++;
		say("the disk pack face's interrupt reads mip 0x%05lx enabled and "
		    "0x%05lx disabled", (unsigned long)on, (unsigned long)off);
	}

	// **AND THE SEAM AT THE RATE A DRIVER WOULD DRIVE IT.**  Every line
	// above is one load with a `say()` behind it, which is the slowest
	// stimulus there is: between two of them the core executes hundreds of
	// instructions and the crossing between its clock and the machine's has
	// long since finished with the last one.  **A RACE CHECK NEEDS THE
	// STIMULUS THAT LOSES THE RACE**, and this repository has the entry to
	// prove it --- a record for a hazard in the disk's request path
	// survived at the slave's usual speed and was caught the moment the
	// stimulus was slowed enough for the writer to overtake.  Here the
	// stimulus has to be made FASTER, not slower.
	//
	// Three loads with nothing between them: no branch, no compare, no
	// store, so the compiler emits three `lw` instructions in a row and the
	// core asks again as soon as it is answered.  **THREE DIFFERENT
	// ANSWERS, which is what makes a wrong one legible**: each comes back a
	// four-letter word of its own, so a load handed the answer to the load
	// before it comes back as the wrong slave's name and not as a plausible
	// value.  A loop reading ONE register this way would be a check that
	// could not tell a stale answer from a fresh one, which is the shape of
	// exercise this project already records as testing nothing.
	//
	// **IT WAS FOUR AND THE FOURTH WAS 0x8000_1000, AND IT HAD TO GO WITH
	// THE WINDOW.**  That address answers "NONE" now, which is the default
	// slave's own word --- so a round holding both would be a round with
	// two loads whose answers are the same constant, and a stale answer
	// handed from one of them to the other would be invisible.  That is the
	// memory-exercised-with-one-constant shape this repository has met
	// twice, and it is worth more to lose a load than to keep a round that
	// cannot tell two of its own answers apart.
	//
	// **AND NOW IT IS FIVE, BECAUSE THERE ARE FIVE DIFFERENT ANSWERS AGAIN.**
	// The console, the Chaosnet cable behind the splitter, the disk pack face
	// behind it too, the catch-all at the window's page, and a word of main
	// memory through the window and the arbiter --- five words, none of them
	// another's, and two of them the same bridge target so that the
	// splitter's own selection is raced as well.  A board with no memory runs
	// the round without the fifth, in a loop of its own, so neither loop has a
	// branch between its loads.
	{
		unsigned wrong = 0;
		const uint32_t want_e = rec_word(REC_FETCH);
		if (have_memory) {
			for (unsigned k = 0; k < 16u; ++k) {
				uint32_t a = soc_rd(CONS_REG_BASE);
				uint32_t b = soc_rd(CHAOS_REG_BASE);
				uint32_t c = soc_rd(PS_REG_BASE + 4u * PS_IDENT);
				uint32_t d = soc_rd(0x80001000u);
				uint32_t e = soc_rd(soc_ddr(REC_FETCH));
				if (a != CONS_IDENT_WORD || b != CHAOS_IDENT_WORD ||
				    c != PS_IDENT_WORD || d != 0x4E4F4E45u || e != want_e)
					wrong++;
			}
		} else {
			for (unsigned k = 0; k < 16u; ++k) {
				uint32_t a = soc_rd(CONS_REG_BASE);
				uint32_t b = soc_rd(CHAOS_REG_BASE);
				uint32_t c = soc_rd(PS_REG_BASE + 4u * PS_IDENT);
				uint32_t d = soc_rd(0x80001000u);
				if (a != CONS_IDENT_WORD || b != CHAOS_IDENT_WORD ||
				    c != PS_IDENT_WORD || d != 0x4E4F4E45u)
					wrong++;
			}
		}
		if (wrong)
			failures++;
		say("%u of 16 rounds of %s back-to-back loads, each at a place of "
		    "its own, came back wrong", wrong, have_memory ? "five" : "four");
	}

	say("%u failure(s); idling --- s status, h halt, c continue, . step",
	    failures);

	// **THE IDLE LOOP IS A CRUDE MACHINE CONTROL THING AND IS MEANT TO
	// STAY ONE.**  The four commands are `cadr-console`'s and muir's
	// prompt's, for the reason that file gives: somebody who knows one
	// should know the other.  It is not to grow into a debugger --- the
	// debugger is CC over the debug cable, and on this board that is
	// another board on the Pmod rather than anything this firmware can
	// reach.
	for (;;) {
		int ch = soc_getc();
		if (ch < 0)
			continue;
		switch (ch) {
		case 's':
			say_status();
			break;
		case 'h':
			cons_halt(&con);
			say("halted");
			break;
		case 'c':
			cons_start(&con);
			say("started");
			break;
		case '.': {
			struct cons_step s;
			cons_step(&con, 1, &s);
			say("stepped %u, CYCLES moved %llu, SSDONE %d",
			    s.asked, (unsigned long long)s.moved, s.ssdone);
			break;
		}
		default:
			say("s status, h halt, c continue, . step");
			break;
		}
	}
}

// The trap handler `start.S` calls.  It does not return: a firmware that
// carried on from an access fault would be a firmware reporting a machine it
// could not reach.
void soc_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval);

void soc_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
	// The eleven causes RISC-V's privileged specification gives for a
	// machine-mode trap that is not an interrupt.  Named rather than
	// numbered, because "mcause 5" sends a reader to a document and "load
	// access fault" sends them to the bridge.
	static const char *const why[] = {
		"instruction address misaligned", "instruction access fault",
		"illegal instruction", "breakpoint",
		"load address misaligned", "load access fault",
		"store address misaligned", "store access fault",
		"environment call from U", "environment call from S",
		"reserved", "environment call from M"
	};
	unsigned c = mcause & 0x7FFFFFFFu;
	const char *w = (mcause & 0x80000000u) ? "interrupt"
		      : (c < sizeof why / sizeof *why) ? why[c] : "unknown";
	say("TRAP: %s (mcause 0x%08lx) at pc 0x%08lx, mtval 0x%08lx",
	    w, (unsigned long)mcause, (unsigned long)mepc,
	    (unsigned long)mtval);
	say("stopped");
	for (;;)
		;
}
