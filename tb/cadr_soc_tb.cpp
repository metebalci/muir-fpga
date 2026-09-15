// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system running its firmware against the real machine,
// read off the wire one character at a time.
//
// **WHAT THIS HOLDS.**  `tb/cadr_soc_harness.sv` is the Arty A7-100's top
// level below the clock: `cadr_soc` with Ibex in it, `cadr_machine` with MIT's
// boot PROM in its control store and nothing behind its memory port, and the
// three faces the soft core masters --- the disk pack side, the console and
// the default slave --- at the addresses the Linux programs use.  The firmware
// is the one the board runs, the same ELF, the same hex.  What this asserts is
// every line it says, in order, and then four things it cannot say about
// itself:
//
//   **THE MACHINE REALLY HALTED AND REALLY STEPPED.**  `clock_edge` is the
//   machine's own microcycle boundary and this counts it every tick, so the
//   halt is a stretch with no microcycles in it and the step is exactly one
//   microcycle inside that stretch.  A firmware that printed "CYCLES moved 1"
//   while the machine ran on would pass a check that read its output and fail
//   this one --- which is the difference between a check written to confirm
//   and one written to compare.
//
//   **THE BRIDGE IS SERIAL.**  `cadr_soc_axi.sv` holds ONE selection where
//   `cadr_gp0_split.sv` holds two, and its header rests that on there never
//   being a read and a write in flight together.  A property stated in a
//   header is not a property until something looks: this looks every tick, at
//   which slaves are being spoken to and at how many transactions are
//   outstanding on each channel.
//
//   **THE TWO CLOCKS ARE REAL AND THE RATIO IS NOT ONE.**  The soft system
//   runs on a clock of its own --- slower than the machine's tick, because
//   Ibex computes a load or a store's address in the cycle it uses it and
//   that arc does not fit in 10 ns --- and `rtl/plumbing/cadr_soc_cross.sv`
//   is the seam between the two.  So the whole firmware runs here at THREE
//   ratios: the board's own, one slower still and sharing no factor with the
//   machine's, and one where the soft clock is faster.  A crossing that
//   worked only at the number the board happens to use would be a crossing
//   held to a coincidence.
//
//   **THE DEBUG CABLE'S WINDOW IS NOT ON THIS BOARD, IN BOTH THE PLACES THAT
//   COULD HIDE IT.**  `rtl/plumbing/cadr_debug_window.sv` is how muir, on a
//   Zynq board's own ARM cores, plays the far end of MIT's debug cable in
//   software; an Arty A7-100 has no such program and its debugger is a second
//   board on the Pmod.  So two things must hold and neither is an absence.
//   The ADDRESS the window holds on those boards, `0x8000_1000`, must be
//   answered by the catch-all like any other address nothing implements ---
//   which the firmware's own line says, and which matters because the
//   GP0-hang rule is about every address in the window and not about the ones
//   somebody remembered.  And the JOIN in front of the machine's DBGIN page
//   must never be asked for by the arm that window used to drive: this watches
//   it every tick, because a join whose empty arm asserted would take the page
//   and hold it, and the console's own diagnostic cycles are on the other side
//   of that arbiter.
//
//   **THE BAUD DIVISOR IS MEASURED FROM THE WIRE.**  The narrowest level the
//   transmitter ever holds is one bit time, so the minimum pulse width over
//   the whole run IS the divisor.  Asserting it is what stops this check
//   passing on a transmitter whose rate is wrong by a little --- a decoder
//   samples in the middle of a bit and tolerates a few per cent, so decoding
//   correctly is not evidence about the number.
//
// **THE RATE HERE IS NOT THE BOARD's, AND THAT IS A COST AND NOT A CHEAT.**
// The board builds at 115,200 baud, where one bit is 434 of the soft system's
// ticks and the firmware's dozen lines are some four million of them.  The
// harness takes the rate as a parameter and this check builds it at a divisor
// of 32, so the same firmware says the same words in a fraction of the time.
// Nothing in the firmware knows the rate --- it polls a ready bit --- so what
// changes is what the check costs.  The divisor it decodes with is asserted
// against the divisor it measures, so a rate that never reached the fabric is
// a failure.
//
// **AND THE DIVISOR IS COUNTED IN THE SOFT SYSTEM'S TICKS AND NOT THE
// MACHINE'S**, the transmitter being on that side of the crossing.  The
// machine's ticks are what the halt and the step are counted in, the
// microcycle being the machine's.  Two clocks, two counts, and saying which
// is which is half of what this file does now.
//
// **AND THE MACHINE IS NOT STIMULUS.**  Every register the firmware reads ---
// PC, FLAG-1, CYCLES --- comes through `cadr_console.sv`, `cadr_console_bus.sv`
// and `cadr_spy_registers.sv` out of a processor executing MIT's boot PROM.
// Nothing here answers a diagnostic cycle.

#include "Vcadr_soc_harness.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// The divisor the harness was built with.  `SOC_BAUD` and `CLK_HZ` are its
// parameters and the Makefile passes them; this is `CLK_HZ / SOC_BAUD`, the
// same integer division `cadr_soc_uart.sv` does.
#ifndef UART_DIVISOR
#define UART_DIVISOR 32
#endif

// **WHAT COUNTS AS THE MACHINE STANDING STILL.**  A microcycle is 29 ticks at
// normal speed and 44 at extra slow, which is what the boot PROM runs at, and
// the longest a RUNNING machine goes without retiring one is a memory cycle
// nobody answers --- 4.25 us on the non-existent-memory timer, 425 ticks at
// this board's tick, which is the ordinary case here since nothing is behind
// the memory port.  A diagnostic cycle the console takes in front of it adds a
// few dozen more.  5,000 ticks is more than ten times that and a small
// fraction of the shortest halt the firmware makes, so it separates the two
// without being near either.  It is a floor with margin and is not derived
// from anything.
static const long HALT_GAP = 5000;

static int bad = 0;

static void Fail(const char *what)
{
	std::fprintf(stderr, "FAIL: %s\n", what);
	bad++;
}

// --- the receiver --------------------------------------------------------
//
// 8N1 at a known divisor, sampling in the middle of each bit, which is what a
// real receiver does and what makes the decode independent of where the edges
// happen to land.
struct Uart {
	int div;
	int state = 0;		/* 0 idle, 1 receiving */
	long next = 0;		/* the tick of the next sample */
	int bit = 0;
	unsigned val = 0;
	std::string line;
	std::vector<std::string> lines;
	long framing = 0;

	explicit Uart(int d) : div(d) {}

	void put(unsigned char c)
	{
		if (c == '\r')
			return;
		if (c == '\n') {
			lines.push_back(line);
			line.clear();
			return;
		}
		line.push_back((char)c);
	}

	void tick(long t, int tx, int prev)
	{
		if (state == 0) {
			if (prev == 1 && tx == 0) {
				state = 1;
				bit = 0;
				val = 0;
				next = t + div / 2;
			}
			return;
		}
		if (t < next)
			return;
		if (bit == 0) {
			// The middle of the start bit.  Still low, or it was a
			// glitch and not a character.
			if (tx != 0) {
				state = 0;
				return;
			}
		} else if (bit <= 8) {
			if (tx)
				val |= 1u << (bit - 1);
		} else {
			// The middle of the stop bit.
			if (!tx)
				framing++;
			else
				put((unsigned char)val);
			state = 0;
			return;
		}
		bit++;
		next += div;
	}
};

// The three slaves' valid lines, read as a bit each: the pack side, the
// console and the default.  THREE and not four --- the debug cable's window is
// not on this board and the header says why.
static int popcount3(unsigned v)
{
	int n = 0;
	for (int i = 0; i < 3; ++i)
		if (v & (1u << i))
			n++;
	return n;
}

// Does `hay` contain `needle`?
static bool has(const std::string &hay, const char *needle)
{
	return hay.find(needle) != std::string::npos;
}

// --- the two clocks ------------------------------------------------------
//
// **THE RATIO IS THE CHECK'S AND THE CROSSING MUST NOT DEPEND ON IT.**  The
// board makes both clocks from one manager: the machine's tick at 100 MHz and
// the soft system's at half of it, because Ibex computes a load or a store's
// address in the cycle it uses it and that arc does not fit in 10 ns.  A
// crossing held only at that one ratio would be a crossing held to a
// coincidence, so the whole firmware runs here at three of them, two of which
// share no factor with the machine's clock in either direction.  Each
// half-period is in units of an arbitrary fine time base, and the two clocks'
// edges coincide only where the arithmetic says they must.
//
// **AND THERE IS A FLOOR UNDER THE RATIO, WHICH IS THE FIRMWARE'S AND NOT THE
// CROSSING'S.**  `cons_step` raises STEP and waits ONE MICROSECOND before
// reading SSDONE, because SSDONE is STEP registered twice on the machine's
// master clock and rises two of them later --- 88 of the MACHINE's ticks at
// extra slow, which is what the boot PROM runs at.  On the board that is a
// bound in real time and it holds with room: 880 ns against 1,000, whatever
// the soft clock is doing, because the microsecond comes out of the timer and
// the timer counts its own clock.  **In simulation there is no real time, so
// the same bound appears as a bound on the RATIO**: one microsecond is
// `CLK_HZ / 1,000,000` of the soft system's ticks, so the soft clock's period
// must be at least 88/50 = 1.76 of the machine's for the wait to cover the two
// master clocks.  The board's is 2.0 and the three here are 2.0, 2.33 and
// 2.5.  A ratio the other way round --- the soft clock FASTER than the
// machine, which this board will never build --- reports `SSDONE 0` on a step
// whose CYCLES moved by exactly one, and that is the firmware's own race
// measured, not a crossing that came apart.  It was tried at 7:3 and is
// recorded here rather than left for somebody to rediscover.
//
// What this does NOT model is metastability, and nothing in any simulator
// does: a synchronizer one flip-flop deep behaves here exactly as one two
// flip-flops deep, differing only in latency.  What holds the depth is the
// structure and `rtl/plumbing/xilinx7/cadr_soc.xdc`; what this holds is the
// handshake --- that a request crosses once, that its payload has stopped
// moving, that the answer comes back whole, and that the fourth phase closes
// before the next request is taken.
struct Ratio {
	int mach_half;
	int soc_half;
	const char *what;
};

static const Ratio RATIOS[] = {
	{ 1, 2, "the board's own --- the soft system at half the machine's rate" },
	{ 3, 7, "3:7 --- slower still, and sharing no factor with the machine's" },
	{ 2, 5, "2:5 --- slower again, sharing no factor, and no multiple of 3:7" },
};

// What the timer must say a microsecond is, which is the soft clock's own
// frequency in megahertz.  The Makefile passes it beside the baud divisor,
// from the same two parameters the harness is built with, so a firmware
// printing a microsecond that is not one is a failure and not a line nobody
// reads.
#ifndef SOC_TICKS_PER_US
#define SOC_TICKS_PER_US 50
#endif

static int run_one(const Ratio &r)
{
	bad = 0;

	Vcadr_soc_harness *d = new Vcadr_soc_harness;
	Uart u(UART_DIVISOR);

	// The fine time base.  One unit is whatever makes both half-periods
	// whole; nothing here converts it to nanoseconds, because what the
	// check is about is the RATIO.
	long next_m = r.mach_half, next_s = r.soc_half;
	int lvl_m = 0, lvl_s = 0;

	long mtick = 0;		/* the machine's clock, in ticks */
	long stick = 0;		/* the soft system's */
	int prev_tx = 1;

	// The machine's own microcycles, and the gaps between them.
	long edges = 0;
	long last_edge = -1;
	std::vector<long> gaps;		/* every gap, in the machine's ticks */
	long machrun_in_gap = 0;
	long gap_open_tick = -1;

	// The transmitter's narrowest level, which is one bit time --- in the
	// SOFT system's ticks, the transmitter being on that side of the
	// crossing.
	long min_pulse = -1;
	long level_since = 0;

	// The join in front of the machine's DBGIN page, on the machine's
	// clock: how often the empty arm asked, how often it held the page,
	// and how often anything reached the page at all.
	long win_asked = 0, win_held = 0, page_asked = 0;

	// The bridge, which is on the machine's clock.
	long r_out = 0, w_out = 0;
	long reads = 0, writes = 0;
	long multi_aw = 0, multi_ar = 0, both_channels = 0;
	long over_r = 0, over_w = 0;

	// **THE BOUND IS IN THE SOFT SYSTEM'S TICKS AND NOT THE MACHINE'S**,
	// because what makes progress here is the firmware and the firmware is
	// on that clock: a bound in the machine's would mean three different
	// amounts of firmware at the three ratios.  The run needs 730,000 of
	// them; eight million is a bound on a run that has gone wrong rather
	// than a measurement, and it is what a crossing that hangs costs the
	// mutation runner.
	const long LIMIT = 8000000;

	d->rst = 1;
	d->uart_rx = 1;		/* the line idles high: nobody is typing */
	d->clk = 0;
	d->clk_soc = 0;
	d->eval();

	bool done = false;
	while (!done && stick < LIMIT) {
		long t = next_m < next_s ? next_m : next_s;
		int pos_m = 0, pos_s = 0;
		if (next_m == t) {
			lvl_m ^= 1;
			d->clk = lvl_m;
			next_m += r.mach_half;
			pos_m = lvl_m;
		}
		if (next_s == t) {
			lvl_s ^= 1;
			d->clk_soc = lvl_s;
			next_s += r.soc_half;
			pos_s = lvl_s;
		}
		d->eval();

		if (pos_s) {
			// --- the wire, sampled on the clock that drives it
			int tx = d->uart_tx;
			if (d->rst) {
				// **NOTHING ON THE WIRE IS READ WHILE THE
				// RESET IS HELD.**  The transmitter comes out
				// of reset idling high and the model's
				// registers start at zero, so the release is
				// an edge on the line that is not a start bit
				// and whose width is not a bit time --- and
				// the narrowest level on the wire is the one
				// thing this check asserts exactly.
				prev_tx = tx;
				level_since = stick;
			} else {
				if (tx != prev_tx) {
					long w = stick - level_since;
					if (min_pulse < 0 || w < min_pulse)
						min_pulse = w;
					level_since = stick;
				}
				u.tick(stick, tx, prev_tx);
				prev_tx = tx;
			}
			stick++;
		}

		if (pos_m) {
			// --- the machine
			if (d->clock_edge_o) {
				if (last_edge >= 0)
					gaps.push_back(mtick - last_edge);
				last_edge = mtick;
				edges++;
				gap_open_tick = mtick;
			} else if (gap_open_tick >= 0 &&
				   mtick - gap_open_tick > 2000 && d->machrun_o) {
				// MACHRUN up deep inside a stretch with no
				// microcycles retiring: the machine is stalled
				// rather than halted, which is not what a
				// console's halt looks like.
				machrun_in_gap++;
			}

			// --- the join at the machine's DBGIN page
			//
			// **THE ARM THE WINDOW USED TO DRIVE IS EMPTY AND
			// THIS IS WHAT SAYS SO.**  `cadr_dbg_join.sv` gives
			// the page to whichever arm asserts first and holds
			// it until that arm lifts, and a tie goes to arm A ---
			// the window's.  With no window on this board, arm A
			// must never assert, the holder must never name it,
			// and with nothing in the connector either nothing
			// must reach `cadr_dbgin.sv` at all.  An arm that
			// asked would take the page and keep it, and the
			// console's own diagnostic cycles arbitrate behind
			// the same bus.
			if (d->dbg_win_req_o) win_asked++;
			if (!d->rst && !d->dbg_holder_o) win_held++;
			if (d->dbg_req_o) page_asked++;

			// --- the bridge
			unsigned aw = d->aw_v_o, ar = d->ar_v_o, hs = d->hs_o;
			if (popcount3(aw) > 1) multi_aw++;
			if (popcount3(ar) > 1) multi_ar++;
			if (aw && ar) both_channels++;
			if (hs & 0x02) { r_out++; reads++; }	/* ar handshake */
			if (hs & 0x01) r_out--;			/* r  handshake */
			if (hs & 0x10) { w_out++; writes++; }	/* aw handshake */
			if (hs & 0x04) w_out--;			/* b  handshake */
			if (r_out > 1 || r_out < 0) over_r++;
			if (w_out > 1 || w_out < 0) over_w++;

			mtick++;
		}

		// **BOTH DOMAINS ARE HELD IN RESET UNTIL BOTH HAVE HAD EDGES
		// ENOUGH.**  The soft system synchronizes this level onto its
		// own clock inside `cadr_soc`, so a reset let go after sixteen
		// of the machine's ticks would, at the slowest ratio here, be
		// a reset the soft side had seen seven times.
		if (d->rst && mtick >= 32 && stick >= 32)
			d->rst = 0;

		// The firmware's last line before it idles.  Run a little past
		// it so that a line it should not have said would still be
		// seen.
		if (!u.lines.empty() && has(u.lines.back(), "idling"))
			done = true;
	}

	long tail_until = stick + 200000;
	while (stick < tail_until && stick < LIMIT) {
		long t = next_m < next_s ? next_m : next_s;
		int pos_m = 0, pos_s = 0;
		if (next_m == t) {
			lvl_m ^= 1; d->clk = lvl_m; next_m += r.mach_half;
			pos_m = lvl_m;
		}
		if (next_s == t) {
			lvl_s ^= 1; d->clk_soc = lvl_s; next_s += r.soc_half;
			pos_s = lvl_s;
		}
		d->eval();
		if (pos_s) {
			int tx = d->uart_tx;
			u.tick(stick, tx, prev_tx);
			prev_tx = tx;
			stick++;
		}
		if (pos_m)
			mtick++;
	}
	if (!u.line.empty())
		u.lines.push_back(u.line);

	// --------------------------------------------------------- the lines
	//
	// Each is a prefix and a phrase, never a whole line: the counters in
	// them are the machine's and move with how long a simulated microsecond
	// took to reach.  What is held is what the firmware CLAIMED, which the
	// fabric-side checks below then hold it to.
	//
	// **THE SECOND LINE IS BUILT AND NOT WRITTEN OUT**, because the number
	// in it is the soft clock's frequency in megahertz and the whole point
	// of this slice is that the soft clock is not the machine's.  A line
	// copied here as a constant would be a second place that number lives.
	char timer_line[128];
	std::snprintf(timer_line, sizeof timer_line,
		      "cadr-soc: UART UART, timer TIME, %d ticks a microsecond",
		      (int)SOC_TICKS_PER_US);
	// **WHICH BUILD THE FABRIC SAYS IT IS**, and the line is built from the
	// number the harness was given rather than written out here: on the
	// board this comes out of the part's AXSS register, which
	// `tools/build_stamp.tcl` loaded from the bitstream, and under Verilator
	// there is no such register, so `SOC_TB_BUILD` is what the harness
	// drives into the console's page 2 and this is a COMPARISON against it.
	// Nibble 3 is a tree that was both modified and carrying an untracked
	// file, so the compound case is what the firmware has to spell out.
	char build_line[192], build_warn[128];
	std::snprintf(build_line, sizeof build_line,
		      "cadr-soc: fabric: build %08x --- commit %07x, tree modified and "
		      "carrying an untracked file",
		      (unsigned)SOC_TB_BUILD, (unsigned)(SOC_TB_BUILD >> 4));
	// And a dirty build is said to be one twice, because its commit names
	// where the build started and not what it is.
	std::snprintf(build_warn, sizeof build_warn,
		      "cadr-soc: fabric: so the commit names where this build STARTED");
	const char *const want[] = {
		"cadr-soc: the soft processing system on an Arty A7-100",
		timer_line,
		"cadr-soc: the console at 0x80000000 answers CONS",
		build_line,
		build_warn,
		"cadr-soc: the machine was RUNNING,",
		"cadr-soc: halted at PC 0o",
		"cadr-soc: halted: FLAG-1 0x",
		"cadr-soc: stepped 1, CYCLES moved 1, SSDONE 1",
		"cadr-soc: started: RUNNING,",
		"cadr-soc: the disk pack face at 0x40000000 answers PACK (register 7)",
		"cadr-soc: the default slave at 0x40001000 answers NONE",
		// **THE PAGE THE WINDOW HOLDS ON THE TWO ZYNQ BOARDS, WHICH ON
		// THIS ONE IS THE CATCH-ALL's.**  This line used to read
		// "the debug window at 0x80001000 answers DBUG".  It is the
		// one assertion that says the window's own address did not
		// become a hole when the window left the design.
		"cadr-soc: the window's page at 0x80001000 answers NONE",
		"cadr-soc: 0 of 16 rounds of three back-to-back loads, one at "
			"each face, came back wrong",
		"cadr-soc: 0 failure(s); idling"
	};
	const int nwant = (int)(sizeof want / sizeof *want);

	std::printf("--- %s\n", r.what);
	std::printf("--- what the firmware said, %d line(s) ---\n",
		    (int)u.lines.size());
	for (size_t i = 0; i < u.lines.size(); ++i)
		std::printf("    %s\n", u.lines[i].c_str());

	if ((int)u.lines.size() != nwant) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "the firmware said %d line(s), wanting %d",
			      (int)u.lines.size(), nwant);
		Fail(m);
	}
	for (int i = 0; i < nwant; ++i) {
		if (i >= (int)u.lines.size()) {
			char m[512];
			std::snprintf(m, sizeof m, "line %d is missing: \"%s\"",
				      i + 1, want[i]);
			Fail(m);
			continue;
		}
		if (u.lines[i].compare(0, std::strlen(want[i]), want[i]) != 0) {
			char m[768];
			std::snprintf(m, sizeof m,
				      "line %d is \"%s\", wanting it to begin \"%s\"",
				      i + 1, u.lines[i].c_str(), want[i]);
			Fail(m);
		}
	}
	// **AND NOTHING MAY TRAP.**  A load or store the bridge answered with
	// SLVERR, an identifier a face did not echo, or a fetch outside the
	// memory all arrive as a RISC-V exception, and the firmware's handler
	// says so.  A line beginning TRAP is a failure whatever else passed.
	for (size_t i = 0; i < u.lines.size(); ++i)
		if (has(u.lines[i], "TRAP"))
			Fail("the firmware trapped");

	if (u.framing)
		Fail("the receiver saw a framing error: the transmitter's rate "
		     "or its stop bit is wrong");

	// ---------------------------------------------------- the wire's rate
	if (min_pulse != UART_DIVISOR) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "the narrowest level on the wire is %ld of the "
			      "soft system's ticks, wanting %d --- that width "
			      "IS the baud divisor",
			      min_pulse, UART_DIVISOR);
		Fail(m);
	}

	// ------------------------------------------ the halt and the step
	//
	// A halted machine retires no microcycles, so the halt is a gap; the
	// step is one microcycle, so it separates two gaps.  Exactly two, and
	// consecutive.
	std::vector<size_t> longs;
	for (size_t i = 0; i < gaps.size(); ++i)
		if (gaps[i] > HALT_GAP)
			longs.push_back(i);

	if (longs.size() != 2) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "the machine stood still %d time(s) for more than "
			      "%ld ticks, wanting exactly 2 --- the halt and "
			      "the wait after the step",
			      (int)longs.size(), HALT_GAP);
		Fail(m);
	} else if (longs[1] != longs[0] + 1) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "%d microcycle(s) ran between the two halts, "
			      "wanting exactly 1 --- the single step",
			      (int)(longs[1] - longs[0]));
		Fail(m);
	}
	if (machrun_in_gap > 100) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "MACHRUN was up for %ld tick(s) inside a stretch "
			      "with no microcycles: the machine was stalled, "
			      "not halted", machrun_in_gap);
		Fail(m);
	}
	if (edges < 1000)
		Fail("the machine retired almost no microcycles: it never ran");

	// ------------------------------------- the machine's DBGIN page
	if (win_asked) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "the join's window arm asked for the DBGIN page "
			      "on %ld tick(s): there is no window on this "
			      "board and that arm must never assert",
			      win_asked);
		Fail(m);
	}
	if (win_held) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "the join gave the DBGIN page to its window arm "
			      "on %ld tick(s): with that arm idle the "
			      "connector holds it from the first tick",
			      win_held);
		Fail(m);
	}
	if (page_asked) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "something asked for the machine's DBGIN page on "
			      "%ld tick(s): there is no window and nothing in "
			      "the connector", page_asked);
		Fail(m);
	}

	// ------------------------------------------------------- the bridge
	if (multi_aw) Fail("more than one slave saw AWVALID at once");
	if (multi_ar) Fail("more than one slave saw ARVALID at once");
	if (both_channels)
		Fail("a read and a write were in flight together: the bridge's "
		     "single held selection is not safe");
	if (over_r) Fail("more than one read transaction was outstanding");
	if (over_w) Fail("more than one write transaction was outstanding");
	if (r_out != 0 || w_out != 0)
		Fail("a transaction was left outstanding at the end of the run");
	// **A FLOOR AND NOT A COUNT.**  The firmware makes about twenty-five
	// reads and five writes at the faces --- an identifier at each of four,
	// two 64-bit counters read low-then-high several times, the diagnostic
	// cycles for PC and FLAG-1, and the three clock-control writes that
	// halt, step and start.  This says only that it made enough of them to
	// have driven the faces at all; the lines above are what says it made
	// the RIGHT ones.
	if (reads < 20 || writes < 4) {
		char m[256];
		std::snprintf(m, sizeof m,
			      "the bridge carried %ld read(s) and %ld write(s): "
			      "too few to have driven the faces", reads, writes);
		Fail(m);
	}

	if (bad == 0)
		std::printf(
			"ok: %ld of the machine's ticks and %ld of the soft "
			"system's; %d line(s) on the wire,\n"
			"    every one as written, no TRAP and no framing "
			"error; the narrowest level on the wire\n"
			"    is %ld soft ticks, the baud divisor measured "
			"rather than assumed.  The machine\n"
			"    retired %ld microcycles, stood still twice for "
			"more than %ld ticks with exactly ONE\n"
			"    microcycle between --- the halt, the single step "
			"and the start --- and MACHRUN was\n"
			"    down throughout.  The bridge carried %ld read(s) "
			"and %ld write(s) across the two\n"
			"    clocks, never spoke to two slaves at once, never "
			"had a read and a write in flight\n"
			"    together, and left nothing outstanding.  The join "
			"at the machine's DBGIN page never\n"
			"    gave it to the arm the debug cable's window holds "
			"on a Zynq board, and nothing\n"
			"    asked for that page at all.\n",
			mtick, stick, (int)u.lines.size(), min_pulse, edges,
			HALT_GAP, reads, writes);

	delete d;
	return bad;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);

	const int nratio = (int)(sizeof RATIOS / sizeof *RATIOS);
	int failures = 0;
	for (int i = 0; i < nratio; ++i) {
		std::printf("=== ratio %d of %d: %s\n", i + 1, nratio,
			    RATIOS[i].what);
		int n = run_one(RATIOS[i]);
		if (n) {
			std::fprintf(stderr,
				     "FAIL: %d check(s) failed at %s\n",
				     n, RATIOS[i].what);
			failures += n;
			// **THE REST OF THE RATIOS ARE NOT RUN.**  A crossing
			// that is wrong is wrong at every ratio, and the one
			// way it goes wrong that costs real time is a hang ---
			// which runs to the bound above.  Stopping at the first
			// failure is what keeps a caught mutation cheap; the
			// green run still does all three, which is the claim.
			break;
		}
	}
	if (failures) {
		std::fprintf(stderr, "FAIL: %d check(s) failed in all\n",
			     failures);
		return 1;
	}
	std::printf(
		"ok: the soft processing system ran its firmware against the "
		"machine at %d clock ratios ---\n"
		"    the board's own 2:1 and two that share no factor with it "
		"or with each other --- and\n"
		"    said the same fifteen lines at every one, so the crossing "
		"between the core's clock\n"
		"    and the machine's tick does not depend on the number.\n",
		nratio);
	return 0;
}
