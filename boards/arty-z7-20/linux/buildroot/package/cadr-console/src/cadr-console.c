// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-console: the program on Linux that is the CADR's console.
//
// WHAT IT IS.  muir's console is CC, the program one CADR runs to debug
// another over the debug cable, and its whole vocabulary is `crate::spy`:
// sixteen diagnostic registers at Unibus `0o766000`, three of them written
// and all sixteen read.  `rtl/plumbing/cadr_console.sv` is a second master on that
// same diagnostic bus with nothing between it and the register block but the
// arbiter, and it puts the sixteen registers on `M_AXI_GP1` where Linux can
// reach them.  So `spy_read(eadr)` is a load and `spy_write(eadr, v)` a
// store, and this program's vocabulary is muir's with no translation in
// between.  `console_face.c` is the face and the vocabulary; `console_test.c`
// holds them, on the build host, to a model of the slave.
//
// THE QUESTION IT EXISTS TO ANSWER.  On the board the machine loads its
// microcode from its pack, does a fixed amount of disk work and goes quiet,
// and nothing built could say whether it is waiting or has halted.  `status`
// answers that, and answers it by MEASURING: CYCLES sampled twice a few
// milliseconds apart, because `Machine::cycles` does not advance on a halted
// master clock cycle and a stopped machine's `step` goes on returning Ok.
//
// HOW IT RUNS.  From the command line --- `cadr-console status` --- or with
// no command, at a `>` prompt reading lines on stdin.  It is INTERACTIVE and
// therefore NOT A DAEMON: there is no init script and nothing starts it at
// boot.  A console that ran unasked would be a second master on the
// diagnostic bus that nobody had asked for, taking the bus from the
// processor's own Unibus cycles for as long as the board was up.
//
// In order, before anything:
//
//   1. THE GUARD.  A read on M_AXI_GP1 that nothing in the fabric answers
//      does not fault the Arm: it hangs both cores at one PC each, measured
//      on the board.  The EMIO tally's marker bits are the one thing that can
//      be read first; `cadr/cadr_mem.h` has the argument.  `--no-guard` is
//      for a board somebody knows.
//   2. IDENT.  Word 0 reads "CONS".  "NONE" is `rtl/plumbing/cadr_gp0_default.sv`'s
//      answer, a board with a GP port and nothing of ours behind it;
//      0xBCB0B1AC is this module's own UNMAPPED, which means the window is
//      somewhere else.  Each is a reason to stop and say which.
//
// THE COMMANDS.  muir's references for each are in `console_face.h` beside
// the function; the two that need saying here:
//
//   step N   CC's `CC-CLOCK`, `2` then `0`, N times.  `SSTEP` and `SSDONE`
//            are two flip flops of the 74S174 at OLORD1 1A10 and `MACHRUN`'s
//            first term is `SSTEP AND -SSDONE`, so raising the bit clocks the
//            machine ONCE and it must be lowered before the next.  The
//            command measures CYCLES either side and reports both, and names
//            either failure out loud: nothing moved, or more than one
//            microcycle a step.  A silent no-op is the failure this project
//            keeps meeting, and so is a silent runaway.
//
//   examine  **READS DDR DIRECTLY AND NOT THROUGH THE MACHINE**, and says so
//   deposit  on every line it prints.  CC reaches main memory through the
//            debuggee's Unibus map, and this fabric has half of one: the
//            sixteen map registers at `0o766140`-`0o766176` are in
//            `rtl/machine/cadr_busint_regs.sv` and store and read back, and
//            the mapped window at `0o140000`-`0o177777` that a cycle would
//            go through is answered by nothing.  `console_face.h` has the
//            whole finding and the muir line numbers.  So these go through /dev/mem on the
//            machine's reserved region, at `rtl/plumbing/cadr_ddr_map.sv`'s base and
//            with its own `main_byte_address` arithmetic; the address is the
//            CADR's 22-bit physical WORD address.  What that reads is the
//            memory the machine's bus cycles land in, not the machine's view
//            of it --- halt it first if the answer is to mean anything.
//
//     cadr-console [--regs ADDR] [--log PATH]... [--settle-us N] [--no-guard]
//                  [command [arguments]]
//
//     halt | start | step [N] | regs | status | ident | switch
//     read EADR | write EADR VALUE
//     examine ADDR [N] | deposit ADDR VALUE
//     trace-keys on|off | trace-chaos on|off
//     help | quit
//
// **TWO WORDS HERE ARE NOT ABOUT THE FABRIC AT ALL: `trace-keys` AND
// `trace-chaos`.**  The first tells `cadr-terminal` and `cadr-usb-input` to
// say what each key becomes, which is how a key that does nothing is followed
// from the board's USB port or a viewer to MIT's own key position.  The
// second tells `cadr-chaosnet` to say every frame that goes by and every
// datagram it refuses, which is how a network that reaches nobody is told
// from one nothing is speaking to.  Both read a pid file and signal, touching
// no register --- so they run BEFORE the guard and the IDENT below and work
// on a board whose fabric has no console in it.  `console_host.h` has the
// whole of it, and says why they are not in the face.

#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "console_face.h"
#include "console_host.h"

// ---- the face over /dev/mem --------------------------------------------
struct mmio {
	volatile uint32_t *regs;
	int mem;			/* /dev/mem, for examine and deposit */
	uint32_t regs_phys;
};

static uint32_t mmio_read(struct console *c, unsigned word)
{
	struct mmio *m = c->ctx;
	return m->regs[word];
}
static void mmio_write(struct console *c, unsigned word, uint32_t v)
{
	struct mmio *m = c->ctx;
	m->regs[word] = v;
	__sync_synchronize();
}
static void mmio_pause(struct console *c, unsigned us)
{
	(void)c;
	usleep(us);
}

static int probe_face(struct console *c, uint32_t regs_phys)
{
	uint32_t ident;
	if (cons_ident_ok(c, &ident) == 0) {
		say("the console answers at 0x%08x (IDENT \"CONS\"); STAT 0x%08x", regs_phys, cons_stat(c));
		return 0;
	}
	if (ident == CADR_IDENT_NONE)
		say("no console at 0x%08x: word 0 reads \"NONE\", the proving boards' default slave; "
		    "a board with a GP port and nothing of ours behind it", regs_phys);
	else if (ident == CONS_UNMAPPED)
		say("no console at 0x%08x: word 0 reads 0x%08x, which is cadr_console.sv's own UNMAPPED --- "
		    "something of ours answers on M_AXI_GP1 but the window is not here", regs_phys, ident);
	else
		say("no console at 0x%08x: word 0 reads 0x%08x, wanting 0x%08x (\"CONS\"); "
		    "is the fabric a bitstream with the console in it?", regs_phys, ident, CONS_IDENT_WORD);
	return -1;
}

// ---- main memory, over /dev/mem and not through the machine -------------
//
// One word at a time, each with its own page-aligned mapping: this is a
// person at a prompt and not a datapath, and a mapping that outlived the
// command would be a stale view of a region the machine is writing.

static const char *ddr_note =
	"read straight out of DDR over /dev/mem, NOT through the machine: this fabric answers no mapped "
	"Unibus window, so nothing was halted and nothing was synchronized";

static int ddr_word(int mem, uint32_t phys, uint32_t *out, const uint32_t *in)
{
	const long ps = sysconf(_SC_PAGESIZE);
	const uint32_t byte = cons_main_byte_address(phys);
	const uint32_t page = byte & ~(uint32_t)(ps - 1);
	volatile uint32_t *p = cadr_map(mem, page, (size_t)ps, "the CADR's main memory");
	if (!p)
		return -1;
	volatile uint32_t *w = p + (byte - page) / 4;
	if (in) {
		*w = *in;
		__sync_synchronize();
	} else {
		*out = *w;
	}
	munmap((void *)p, (size_t)ps);
	return 0;
}

static int in_range(uint32_t phys)
{
	if (phys < CONS_MAIN_WORDS_REACHABLE)
		return 1;
	say("word %o (%u) is past the %u words this machine can address --- its physical address is 22 bits and "
	    "the top four 64K slots are the display, the disk controller and the Unibus (rtl/plumbing/cadr_ddr_map.sv)",
	    phys, phys, CONS_MAIN_WORDS_REACHABLE);
	return 0;
}

static void do_examine(int mem, uint32_t phys, unsigned n)
{
	say("examine: %s", ddr_note);
	for (unsigned k = 0; k < n; ++k) {
		uint32_t v = 0;
		if (!in_range(phys + k))
			return;
		if (ddr_word(mem, phys + k, &v, NULL) < 0)
			return;
		say("  %o (0x%06x) at 0x%08x: 0x%08x  %o", phys + k, phys + k,
		    cons_main_byte_address(phys + k), v, v);
	}
}

static void do_deposit(int mem, uint32_t phys, uint32_t v)
{
	uint32_t back = 0;
	if (!in_range(phys))
		return;
	say("deposit: written straight into DDR over /dev/mem, NOT through the machine: this fabric answers "
	    "no mapped Unibus window, so nothing was halted and the machine may overwrite this at its next "
	    "bus cycle");
	if (ddr_word(mem, phys, NULL, &v) < 0)
		return;
	if (ddr_word(mem, phys, &back, NULL) < 0)
		return;
	say("  %o (0x%06x) at 0x%08x: 0x%08x, read back 0x%08x%s", phys, phys,
	    cons_main_byte_address(phys), v, back, back == v ? "" : "  --- DIFFERENT");
}

// ---- the commands -------------------------------------------------------

// The debug cable's role on Pmod JA.  **ASKING IS NOT HAVING**, so this reads
// the word back after every write rather than reporting what was asked for:
// a board that can see a debugger already on the connector refuses, and the
// line says which happened.
static void do_debug_cable(struct console *c)
{
	struct cons_debug_cable d;
	cons_read_debug_cable(c, &d);
	cons_say_debug_cable(&d);
}

// **`trace-keys on|off`: THE TWO INPUT PROGRAMS TOLD TO SAY WHAT A KEY
// BECOMES.**  One line a program, whether it was reached or is not running,
// because a word that silently reached one of the two would be worse than one
// that reached neither.  It touches no register; `console_host.h` says why it
// lives beside the face rather than in it, and why it runs before the guard.
static int do_trace_keys(int argc, char **argv)
{
	if (argc < 2 || (strcmp(argv[1], "on") != 0 && strcmp(argv[1], "off") != 0)) {
		say("trace-keys on|off   tell cadr-terminal and cadr-usb-input to say what "
		    "each key becomes, on their own logs");
		return 2;
	}
	const int on = strcmp(argv[1], "on") == 0;
	struct cons_trace r;
	int reached = 0;
	cons_trace_signal(CONS_TRACE_TERMINAL, CONS_TRACE_TERMINAL_PID,
			  CONS_TRACE_WHAT_KEYS, on, &r);
	cons_say_trace(&r, on);
	reached += r.reached == CONS_TRACE_SIGNALLED;
	cons_trace_signal(CONS_TRACE_USB, CONS_TRACE_USB_PID, CONS_TRACE_WHAT_KEYS, on, &r);
	cons_say_trace(&r, on);
	reached += r.reached == CONS_TRACE_SIGNALLED;
	// **THE STATUS ANSWERS "DID ANYBODY HEAR IT"**, as `switch` answers a
	// question of its own: 0 when at least one program was told, 1 when
	// neither was.  A board with no USB keyboard runs one of the two, and
	// that is not a failure.
	return reached ? 0 : 1;
}

// **`trace-chaos on|off`: THE NETWORK PROGRAM TOLD TO SAY WHAT IT HEARS.**
// One program rather than two, so the status is simply whether it was
// reached.  What it turns on is `cadr-chaosnet`'s `--chaos-trace`: every
// frame as it goes by, and every datagram refused with the reason and the
// endpoint it came from.  The report line counts those refusals in four
// classes and this is how the one that is not zero is followed to a sender.
static int do_trace_chaos(int argc, char **argv)
{
	if (argc < 2 || (strcmp(argv[1], "on") != 0 && strcmp(argv[1], "off") != 0)) {
		say("trace-chaos on|off  tell cadr-chaosnet to say every frame and every "
		    "datagram it refuses, on its own log");
		return 2;
	}
	const int on = strcmp(argv[1], "on") == 0;
	struct cons_trace r;
	cons_trace_signal(CONS_TRACE_CHAOS, CONS_TRACE_CHAOS_PID, CONS_TRACE_WHAT_CHAOS, on, &r);
	cons_say_trace(&r, on);
	return r.reached == CONS_TRACE_SIGNALLED ? 0 : 1;
}

static void do_status(struct console *c, unsigned settle_us)
{
	struct cons_status st;
	cons_status(c, settle_us, &st);
	cons_say_status(&st);
}

static void do_regs(struct console *c)
{
	struct cons_regs r;
	cons_read_regs(c, &r);
	say("the sixteen diagnostic registers, muir's names (../muir/src/spy.rs); "
	    "reads and writes at one EADR are uncorrelated");
	cons_say_regs(&r);
}

static void do_step(struct console *c, unsigned n)
{
	struct cons_step s;
	cons_step(c, n, &s);
	cons_say_step(&s);
}

// **THE BUTTON, AND IT IS WHAT TAKES THE HOLD OFF.**  muir's prompt does the
// same: its `Command::Boot` presses and then clears its own hold, with the
// comment "the button starts the machine: it presets RUN, and a finger on it
// is all a CADR is given.  So the hold comes off with it."
static void do_boot(struct console *c, unsigned settle_us)
{
	struct cons_boot_report r;
	cons_boot_and_report(c, settle_us, &r);
	cons_say_boot(&r);
	if (cons_held(CONS_HELD_PATH)) {
		if (cons_release_held(CONS_HELD_PATH) == 0)
			say("boot: the machine was being held unbooted (%s); the hold is off",
			    CONS_HELD_PATH);
		else
			say("boot: the machine was being held unbooted and %s could not be "
			    "removed, so start and step will go on refusing", CONS_HELD_PATH);
	}
}

// Whether a command that runs the machine must refuse.  The marker means an
// init step halted the machine before anything presented it a drive, which is
// what `--no-auto-boot` is on muir; only the button starts one.
static int refuse_while_held(const char *cmd)
{
	if (!cons_held(CONS_HELD_PATH))
		return 0;
	say("%s: %s", cmd, CONS_HELD_SAYING);
	say("%s: this machine is being held unbooted (%s); `boot` presses the button",
	    cmd, CONS_HELD_PATH);
	return 1;
}

static void help(void)
{
	say("halt            0 into the clock control register: RUN clear (CC's first act on a debuggee)");
	say("start           1 into it: RUN");
	say("boot            the light panel's button: it presets RUN, and the machine runs from the PROM at 0");
	say("step [N]        CC's CC-CLOCK, 2 then 0, N times: one microcycle each, CYCLES either side");
	say("regs            all sixteen registers by muir's names, FLAG-1 and FLAG-2 field by field");
	say("status          running or halted, and why; PC; CYCLES measured twice");
	say("ident           IDENT, STAT, CYCLES and TICKS");
	say("switch          SW0, the no-auto-boot switch: what it did at the last reset,");
	say("                and where it is now.  Exits 0 when it held the machine");
	say("debug-cable     the role on Pmod JA: debugger, debuggee, or asked and refused");
	say("debug-cable-connect     ask to be the debugger on it (muir's --debug-cable-connect)");
	say("debug-cable-disconnect  give the role back.  A board is a debuggee with nothing set,");
	say("                        and its own register window is a debugger either way");
	say("debug-cable-wiring auto|straight|crossover");
	say("                        which way round the JA ribbon was made.  Only a DEBUGGER");
	say("                        applies it; `auto` looks for the answer and is the default.");
	say("                        Refused while this board is the debugger");
	say("tv-board [simple-tv|lispm-tv]");
	say("                which display board the first one is, muir's own --tv-board.");
	say("                With no word it reports.  It reaches mode bit 7 and nothing else");
	say("color-tv [on|off]       whether the second display board --- the color TV at");
	say("                0o17200000 --- is in the backplane.  A machine with none gives");
	say("                the NXM there, which is how the band finds out.  Exits 0 when fitted");
	say("color-map [first|color] one board's sixteen colors, three guns each: the map the");
	say("                machine wrote through register 4, which no bus cycle can read back");
	say("trace-keys on|off  tell cadr-terminal and cadr-usb-input to say what each key");
	say("                becomes --- a keysym, MIT's own key position, or nothing at all.");
	say("                Their logs, not this one; no register is touched");
	say("trace-chaos on|off tell cadr-chaosnet to say every frame that goes by and every");
	say("                datagram it refuses, with the reason and where it came from.");
	say("                Its log, not this one; no register is touched");
	say("read EADR       one diagnostic READ cycle");
	say("write EADR VAL  one diagnostic WRITE cycle");
	say("examine A [N]   N words of DDR from CADR physical word A --- not through the machine");
	say("deposit A VAL   one word of DDR at CADR physical word A --- not through the machine");
	say("quit");
}

static void do_ident(struct console *c)
{
	uint32_t id = 0;
	const uint32_t stat = cons_stat(c);
	const uint64_t cy = cons_cycles(c), ti = cons_ticks(c);
	cons_ident_ok(c, &id);
	say("IDENT 0x%08x  STAT 0x%08x (busy %d, gnt %d, answered %d, lost-since-reset %d,"
	    " SW0 held the machine %d, SW0 now %d)",
	    id, stat, !!(stat & CONS_ST_BUSY), !!(stat & CONS_ST_GNT),
	    !!(stat & CONS_ST_ANSWERED), !!(stat & CONS_ST_LOST),
	    !!(stat & CONS_ST_HELD_AT_RESET), !!(stat & CONS_ST_SWITCH_NOW));
	// TICKS is the fabric's clock and the divisor is the one number here
	// that is about the wall clock: `CONS_TICKS_PER_US`, 100 at the 10 ns
	// tick `cadr_arty.sv`'s MMCM builds.  The microcycle count beside it is
	// the machine's own and needs no conversion at all.
	say("CYCLES %llu microcycles, TICKS %llu at 10 ns = %llu us since reset",
	    (unsigned long long)cy, (unsigned long long)ti,
	    (unsigned long long)(ti / CONS_TICKS_PER_US));
}

// **WHAT THE SHELL IS TOLD, WHICH IS A DIFFERENT QUESTION FROM WHETHER TO GO
// ON READING.**  `command` returns 0 to go on and 1 to stop, and at the prompt
// anything non-zero ends the session --- so a command that wants to answer a
// QUESTION with its exit status cannot say so that way without quitting the
// prompt.  `switch` is the one such command: it asks whether SW0 held the
// machine, and an init script reads the status where a person reads the line.
// So the status is set here and `main` returns it, and nothing about the
// prompt changes.
static int exit_status;

// One command line, already split.  0 to go on, 1 to stop.
static int command(struct console *c, struct mmio *m, unsigned settle_us, int argc, char **argv)
{
	if (argc == 0)
		return 0;
	const char *cmd = argv[0];
	if (!strcmp(cmd, "quit") || !strcmp(cmd, "exit"))
		return 1;
	if (!strcmp(cmd, "help") || !strcmp(cmd, "?"))
		help();
	else if (!strcmp(cmd, "halt")) {
		cons_halt(c);
		say("halt: 0 written to the clock control register (EADR 3); RUN is clear");
		do_status(c, settle_us);
	} else if (!strcmp(cmd, "start")) {
		if (refuse_while_held("start"))
			return 0;
		cons_start(c);
		say("start: 1 written to the clock control register (EADR 3); RUN is set");
		do_status(c, settle_us);
	} else if (!strcmp(cmd, "boot"))
		do_boot(c, settle_us);
	else if (!strcmp(cmd, "step")) {
		if (refuse_while_held("step"))
			return 0;
		do_step(c, argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : 1);
	}
	else if (!strcmp(cmd, "regs"))
		do_regs(c);
	else if (!strcmp(cmd, "status"))
		do_status(c, settle_us);
	else if (!strcmp(cmd, "ident"))
		do_ident(c);
	else if (!strcmp(cmd, "debug-cable-connect")) {
		cons_debug_cable_connect(c);
		do_debug_cable(c);
	}
	else if (!strcmp(cmd, "debug-cable-disconnect")) {
		cons_debug_cable_disconnect(c);
		do_debug_cable(c);
	}
	else if (!strcmp(cmd, "debug-cable-wiring")) {
		// The one command here that takes a word.  A spelling nothing
		// names writes nothing and says so, rather than picking a
		// wiring for somebody: the fabric refuses the write while this
		// board is the debugger, and reading it back is how the caller
		// learns what took.
		const char *w = (argc > 1) ? argv[1] : "";
		int wire = -1;
		if (!strcmp(w, "auto"))
			wire = CONS_DBG_WIRE_AUTO_IDLE;
		else if (!strcmp(w, "straight"))
			wire = CONS_DBG_WIRE_STRAIGHT;
		else if (!strcmp(w, "crossover"))
			wire = CONS_DBG_WIRE_CROSSOVER;
		if (wire < 0) {
			say("debug-cable-wiring auto|straight|crossover");
			return 0;
		}
		cons_debug_cable_wiring(c, wire);
		do_debug_cable(c);
	}
	else if (!strcmp(cmd, "debug-cable"))
		do_debug_cable(c);
	else if (!strcmp(cmd, "switch")) {
		struct cons_switch sw;
		cons_read_switch(c, &sw);
		cons_say_switch(&sw);
		// The answer, for a script: 0 when the switch held the machine.
		// `console_face.h` has the argument for putting it here as well
		// as in the line above.
		exit_status = sw.held_at_reset ? 0 : 1;
	}
	else if (!strcmp(cmd, "tv-board")) {
		// muir's own two words, and a spelling nothing names writes
		// nothing and says so rather than picking a board for
		// somebody.  With no word it reports.
		struct cons_display d;
		if (argc > 1) {
			if (!strcmp(argv[1], "simple-tv"))
				cons_set_tv_board(c, 0);
			else if (!strcmp(argv[1], "lispm-tv"))
				cons_set_tv_board(c, 1);
			else {
				say("tv-board simple-tv|lispm-tv");
				return 0;
			}
		}
		cons_read_display(c, &d);
		cons_say_display(&d);
	}
	else if (!strcmp(cmd, "color-tv")) {
		struct cons_display d;
		if (argc > 1) {
			if (!strcmp(argv[1], "on"))
				cons_set_color_tv(c, 1);
			else if (!strcmp(argv[1], "off"))
				cons_set_color_tv(c, 0);
			else {
				say("color-tv on|off");
				return 0;
			}
		}
		cons_read_display(c, &d);
		cons_say_display(&d);
		// The answer, for a script: 0 when a color board is fitted.
		exit_status = d.color ? 0 : 1;
	}
	else if (!strcmp(cmd, "color-map")) {
		// One board's sixteen colors, out of a port no bus cycle can
		// reach.  The default is the color board's, which is the one
		// anything drawing a picture wants.
		uint8_t map[CONS_MAP_COLORS][CONS_MAP_CHANNELS];
		int board = 1;
		if (argc > 1) {
			if (!strcmp(argv[1], "color"))
				board = 1;
			else if (!strcmp(argv[1], "first"))
				board = 0;
			else {
				say("color-map [first|color]");
				return 0;
			}
		}
		cons_read_color_map(c, board, map);
		say("the %s board's color map, as the machine last wrote it:",
		    board ? "color" : "first");
		for (int k = 0; k < CONS_MAP_COLORS; ++k)
			say("  %2d  red %3u  green %3u  blue %3u", k,
			    map[k][0], map[k][1], map[k][2]);
	}
	else if (!strcmp(cmd, "trace-keys"))
		exit_status = do_trace_keys(argc, argv);
	else if (!strcmp(cmd, "trace-chaos"))
		exit_status = do_trace_chaos(argc, argv);
	else if (!strcmp(cmd, "read")) {
		if (argc < 2) {
			say("read EADR");
			return 0;
		}
		const unsigned e = (unsigned)strtoul(argv[1], NULL, 0) & 15u;
		uint16_t v = 0;
		if (cons_spy_read(c, e, &v) < 0)
			say("read %u (%s): NOT ANSWERED --- the diagnostic cycle was lost (bit 16), this is not data",
			    e, cons_reg_name(e));
		else
			say("read %u (%s): 0x%04x  %o", e, cons_reg_name(e), v, v);
	} else if (!strcmp(cmd, "write")) {
		if (argc < 3) {
			say("write EADR VALUE");
			return 0;
		}
		const unsigned e = (unsigned)strtoul(argv[1], NULL, 0) & 15u;
		const uint16_t v = (uint16_t)strtoul(argv[2], NULL, 0);
		cons_spy_write(c, e, v);
		// spy::write_strobe: the write decoder's G1 is HI1 and not
		// EADR3, so EADR<2:0> is what fires and 8..15 alias onto 0..7.
		say("write %u: 0x%04x on SPY<15:0>; the write strobe is EADR<2:0> = %u, "
		    "so this is %s (reads and writes at one EADR are uncorrelated)",
		    e, v, e & 7u,
		    (e & 7u) < 3 ? "a half of the debug IR" :
		    (e & 7u) == 3 ? "the clock control register" :
		    (e & 7u) == 4 ? "the OPC control register" :
		    (e & 7u) == 5 ? "the mode register" : "nothing: Y6 and Y7 are not connected");
	} else if (!strcmp(cmd, "examine")) {
		if (argc < 2) {
			say("examine ADDR [N]   ADDR is a CADR physical WORD address, 22 bits");
			return 0;
		}
		do_examine(m->mem, (uint32_t)strtoul(argv[1], NULL, 0),
			   argc > 2 ? (unsigned)strtoul(argv[2], NULL, 0) : 1);
	} else if (!strcmp(cmd, "deposit")) {
		if (argc < 3) {
			say("deposit ADDR VALUE   ADDR is a CADR physical WORD address, 22 bits");
			return 0;
		}
		do_deposit(m->mem, (uint32_t)strtoul(argv[1], NULL, 0),
			   (uint32_t)strtoul(argv[2], NULL, 0));
	} else
		say("%s: no such command; `help` lists them", cmd);
	return 0;
}

// The prompt.  No readline: it is one dependency for a program whose whole
// input is a word and two numbers, and Buildroot would carry the library onto
// the card for it.
static void prompt(struct console *c, struct mmio *m, unsigned settle_us)
{
	char line[256];
	for (;;) {
		fputs("> ", stdout);
		fflush(stdout);
		if (!fgets(line, sizeof line, stdin))
			break;
		char *word[8];
		int n = 0;
		for (char *p = strtok(line, " \t\r\n"); p && n < 8; p = strtok(NULL, " \t\r\n"))
			word[n++] = p;
		if (command(c, m, settle_us, n, word))
			break;
	}
	say("the console lets go of the diagnostic bus; the machine is as it was left");
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-console [options] [command [arguments]]\n"
		"  --regs ADDR      the console's window (default 0x80000000, the bottom of M_AXI_GP1)\n"
		"  --log PATH       where to write; may be given more than once, and every\n"
		"                   line then goes to every destination named.  With none, the\n"
		"                   lines go to stdout, and to a TERMINAL they go bare: a reply\n"
		"                   to a person does not name the program they asked\n"
		"  --settle-us N    how long `status` waits between its two reads of CYCLES (default 2000)\n"
		"  --no-guard       touch M_AXI_GP1 without checking the EMIO tally first\n"
		"  --version        which build THIS PROGRAM is, and exit.  `status` names\n"
		"                   which build the FABRIC is, which is the other half\n"
		"with no command it reads lines at a `>` prompt; `help` lists them\n"
		"`trace-keys on|off` and `trace-chaos on|off` are the commands that touch no\n"
		"register: the first tells cadr-terminal and cadr-usb-input to say what each\n"
		"key becomes, the second tells cadr-chaosnet to say every frame and every\n"
		"datagram it refuses\n");
}

int main(int argc, char **argv)
{
	uint32_t regs_phys = CONS_REG_BASE;
	unsigned settle_us = 2000, no_guard = 0;
	static const struct option opts[] = {
		{ "regs", required_argument, NULL, 'r' },
		{ "log", required_argument, NULL, 'l' },
		{ "settle-us", required_argument, NULL, 's' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "version", no_argument, NULL, 'V' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "r:l:s:GVh", opts, NULL)) != -1) {
		switch (c) {
		case 'r': regs_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'l': cadr_log_dest(optarg); break;
		case 's': settle_us = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'G': no_guard = 1; break;
		// **BEFORE THE LOG IS OPENED AND BEFORE ANYTHING TOUCHES THE
		// BUS**, as muir prints its own version before it reads an rc
		// file.  A version is what somebody asks for when nothing else
		// works, so it must not need a window that answers, a
		// bitstream with a console in it, or /dev/mem.
		case 'V': printf("%s\n", cons_version()); return 0;
		default: usage(); return 2;
		}
	}
	// **THE REPLY IS BARE WHEN A PERSON IS READING IT.**  `console_host.h`
	// has the rule and the reference in muir's own prompt; the decision is
	// a function of its own there so that the check can make it without a
	// terminal.
	if (cadr_log_open(cons_log_prefix((int)cadr_log_dests(),
					  isatty(STDOUT_FILENO))) < 0)
		return 2;

	// **THE WORDS THAT ARE NOT ABOUT THE FABRIC, DONE BEFORE THE GUARD.**
	// `trace-keys` reads two pid files and signals two programs and
	// `trace-chaos` reads a third; neither touches a register, so a board
	// whose window does not answer must not stop them --- and the guard
	// below and the IDENT after it would.
	if (optind < argc && !strcmp(argv[optind], "trace-keys"))
		return do_trace_keys(argc - optind, argv + optind);
	if (optind < argc && !strcmp(argv[optind], "trace-chaos"))
		return do_trace_chaos(argc - optind, argv + optind);

	int mem = cadr_open_mem();
	if (mem < 0)
		return 1;
	// 1. The guard, before anything on GP1.
	if (!no_guard && cadr_guard(mem, "M_AXI_GP1") < 0)
		return 1;
	struct mmio m;
	m.mem = mem;
	m.regs_phys = regs_phys;
	m.regs = cadr_map(mem, regs_phys, 4096, "the console's registers");
	if (!m.regs)
		return 1;

	struct console con;
	cons_init(&con);
	con.read = mmio_read;
	con.write = mmio_write;
	con.pause = mmio_pause;
	con.ctx = &m;

	// 2. The face is there, or nothing is.
	if (probe_face(&con, regs_phys) < 0)
		return 1;

	if (optind < argc) {
		(void)command(&con, &m, settle_us, argc - optind, argv + optind);
		// `switch` is the one command that answers a question with the
		// status; every other leaves it at 0.
		return exit_status;
	}
	prompt(&con, &m, settle_us);
	return 0;
}
