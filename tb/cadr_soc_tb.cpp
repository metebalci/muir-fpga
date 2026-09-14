// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system running its firmware against the real machine,
// read off the wire one character at a time.
//
// **WHAT THIS HOLDS.**  `tb/cadr_soc_harness.sv` is the Arty A7-100's top
// level below the clock: `cadr_soc` with Ibex in it, `cadr_machine` with MIT's
// boot PROM in its control store and nothing behind its memory port, and the
// four faces the soft core masters --- the disk pack side, the console, the
// debug cable's window and the default slave --- at the addresses the Linux
// programs use.  The firmware is the one the board runs, the same ELF, the
// same hex.  What this asserts is every line it says, in order, and then three
// things it cannot say about itself:
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
//   **THE BAUD DIVISOR IS MEASURED FROM THE WIRE.**  The narrowest level the
//   transmitter ever holds is one bit time, so the minimum pulse width over
//   the whole run IS the divisor.  Asserting it is what stops this check
//   passing on a transmitter whose rate is wrong by a little --- a decoder
//   samples in the middle of a bit and tolerates a few per cent, so decoding
//   correctly is not evidence about the number.
//
// **THE RATE HERE IS NOT THE BOARD's, AND THAT IS A COST AND NOT A CHEAT.**
// The board builds at 115,200 baud, where one bit is 868 ticks and the
// firmware's dozen lines are some eight million of them.  The harness takes
// the rate as a parameter and this check builds it at a divisor of 32, so the
// same firmware says the same words in a fraction of the time.  Nothing in the
// firmware knows the rate --- it polls a ready bit --- so what changes is what
// the check costs.  The divisor it decodes with is asserted against the
// divisor it measures, so a rate that never reached the fabric is a failure.
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

static int popcount4(unsigned v)
{
	int n = 0;
	for (int i = 0; i < 4; ++i)
		if (v & (1u << i))
			n++;
	return n;
}

// Does `hay` contain `needle`?
static bool has(const std::string &hay, const char *needle)
{
	return hay.find(needle) != std::string::npos;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	Vcadr_soc_harness *d = new Vcadr_soc_harness;

	Uart u(UART_DIVISOR);

	long tick = 0;
	int prev_tx = 1;

	// The machine's own microcycles, and the gaps between them.
	long edges = 0;
	long last_edge = -1;
	std::vector<long> gaps;		/* every gap, in ticks */
	std::vector<long> gap_at;	/* the edge index each gap precedes */
	long machrun_in_gap = 0;
	long gap_open_tick = -1;

	// The transmitter's narrowest level, which is one bit time.
	long min_pulse = -1;
	long level_since = 0;

	// The bridge.
	long r_out = 0, w_out = 0;	/* outstanding read and write transactions */
	long reads = 0, writes = 0;
	long multi_aw = 0, multi_ar = 0, both_channels = 0;
	long over_r = 0, over_w = 0;

	// 40 million ticks is far past what the firmware needs and is a bound
	// on a run that has gone wrong rather than a measurement.  A firmware
	// that stopped saying anything would otherwise sit here for ever, which
	// is the shape of failure this project will not build.
	const long LIMIT = 40000000;

	d->rst = 1;
	d->uart_rx = 1;		/* the line idles high: nobody is typing */
	d->clk = 0;
	d->eval();
	for (int i = 0; i < 16; ++i) {
		d->clk = 1; d->eval();
		d->clk = 0; d->eval();
	}
	d->rst = 0;

	bool done = false;
	while (!done && tick < LIMIT) {
		d->clk = 1;
		d->eval();

		// --- the wire
		int tx = d->uart_tx;
		if (tx != prev_tx) {
			long w = tick - level_since;
			if (min_pulse < 0 || w < min_pulse)
				min_pulse = w;
			level_since = tick;
		}
		u.tick(tick, tx, prev_tx);
		prev_tx = tx;

		// --- the machine
		if (d->clock_edge_o) {
			if (last_edge >= 0) {
				long g = tick - last_edge;
				gaps.push_back(g);
				gap_at.push_back(edges);
			}
			last_edge = tick;
			edges++;
			gap_open_tick = tick;
		} else if (gap_open_tick >= 0 && tick - gap_open_tick > 2000 &&
			   d->machrun_o) {
			// MACHRUN up deep inside a stretch with no microcycles
			// retiring: the machine is stalled rather than halted,
			// which is not what a console's halt looks like.
			machrun_in_gap++;
		}

		// --- the bridge
		unsigned aw = d->aw_v_o, ar = d->ar_v_o, hs = d->hs_o;
		if (popcount4(aw) > 1) multi_aw++;
		if (popcount4(ar) > 1) multi_ar++;
		if (aw && ar) both_channels++;
		if (hs & 0x02) { r_out++; reads++; }	/* ar handshake */
		if (hs & 0x01) r_out--;			/* r  handshake */
		if (hs & 0x10) { w_out++; writes++; }	/* aw handshake */
		if (hs & 0x04) w_out--;			/* b  handshake */
		if (r_out > 1 || r_out < 0) over_r++;
		if (w_out > 1 || w_out < 0) over_w++;

		d->clk = 0;
		d->eval();
		tick++;

		// The firmware's last line before it idles.  Run a little past
		// it so that a line it should not have said would still be
		// seen.
		if (!u.lines.empty() && has(u.lines.back(), "idling"))
			done = true;
	}
	for (int i = 0; i < 200000 && tick < LIMIT; ++i) {
		d->clk = 1; d->eval();
		int tx = d->uart_tx;
		u.tick(tick, tx, prev_tx);
		prev_tx = tx;
		d->clk = 0; d->eval();
		tick++;
	}
	if (!u.line.empty())
		u.lines.push_back(u.line);

	// --------------------------------------------------------- the lines
	//
	// Each is a prefix and a phrase, never a whole line: the counters in
	// them are the machine's and move with how long a simulated microsecond
	// took to reach.  What is held is what the firmware CLAIMED, which the
	// fabric-side checks below then hold it to.
	static const char *const want[] = {
		"cadr-soc: the soft processing system on an Arty A7-100",
		"cadr-soc: UART UART, timer TIME, 100 ticks a microsecond",
		"cadr-soc: the console at 0x80000000 answers CONS",
		"cadr-soc: the machine was RUNNING,",
		"cadr-soc: halted at PC 0o",
		"cadr-soc: halted: FLAG-1 0x",
		"cadr-soc: stepped 1, CYCLES moved 1, SSDONE 1",
		"cadr-soc: started: RUNNING,",
		"cadr-soc: the disk pack face at 0x40000000 answers PACK (register 7)",
		"cadr-soc: the default slave at 0x40001000 answers NONE",
		"cadr-soc: the debug window at 0x80001000 answers DBUG",
		"cadr-soc: 0 failure(s); idling"
	};
	const int nwant = (int)(sizeof want / sizeof *want);

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
			      "the narrowest level on the wire is %ld ticks, "
			      "wanting %d --- that width IS the baud divisor",
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

	if (bad) {
		std::fprintf(stderr, "FAIL: %d check(s) failed\n", bad);
		return 1;
	}
	std::printf(
		"ok: the soft processing system ran its firmware against the machine, "
		"%ld ticks.\n"
		"    %d line(s) on the wire, every one of them as written, no TRAP and no "
		"framing error;\n"
		"    the narrowest level on the wire is %ld ticks, which is the baud "
		"divisor measured\n"
		"    rather than assumed.  The machine retired %ld microcycles, stood "
		"still twice for\n"
		"    more than %ld ticks with exactly ONE microcycle between the two --- "
		"the halt, the\n"
		"    single step, and the start --- and MACHRUN was down throughout.  The "
		"bridge carried\n"
		"    %ld read(s) and %ld write(s), never spoke to two slaves at once, "
		"never had a read\n"
		"    and a write in flight together, and left nothing outstanding.\n",
		tick, (int)u.lines.size(), min_pulse, edges, HALT_GAP,
		reads, writes);
	delete d;
	return 0;
}
