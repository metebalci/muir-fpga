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
//   step N   **DOES NOT WORK ON TODAY'S FABRIC AND SAYS SO.**  `SSTEP` and
//            `SSDONE` are two flip flops of the 74S174 at OLORD1 1A10 and
//            `cadr_microcycle.sv` has neither, and `cadr_spy_registers.sv`
//            takes bit 0 of a clock control write and drops bits 4:1.  So the
//            command runs, measures CYCLES either side, finds that nothing
//            moved and reports that plainly, naming `docs/console.md`, which
//            carries the two hunks.  A silent no-op is the failure this
//            project keeps meeting.
//
//   examine  **READS DDR DIRECTLY AND NOT THROUGH THE MACHINE**, and says so
//   deposit  on every line it prints.  CC reaches main memory through the
//            debuggee's Unibus map, and this fabric has no Unibus map:
//            `rtl/machine/cadr_memory_path.sv` answers only `0o766xxx` on its Unibus
//            and the only thing behind it is the register block at
//            `0o766000`-`0o766036`.  `console_face.h` has the whole finding
//            and the muir line numbers.  So these go through /dev/mem on the
//            machine's reserved region, at `rtl/plumbing/cadr_ddr_map.sv`'s base and
//            with its own `main_byte_address` arithmetic; the address is the
//            CADR's 22-bit physical WORD address.  What that reads is the
//            memory the machine's bus cycles land in, not the machine's view
//            of it --- halt it first if the answer is to mean anything.
//
//     cadr-console [--regs ADDR] [--log PATH] [--settle-us N] [--no-guard]
//                  [command [arguments]]
//
//     halt | start | step [N] | regs | status | ident
//     read EADR | write EADR VALUE
//     examine ADDR [N] | deposit ADDR VALUE
//     help | quit

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "console_face.h"

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
	"read straight out of DDR over /dev/mem, NOT through the machine: this fabric has no Unibus map, "
	"so nothing was halted and nothing was synchronised";

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
	say("deposit: written straight into DDR over /dev/mem, NOT through the machine: this fabric has no "
	    "Unibus map, so nothing was halted and the machine may overwrite this at its next bus cycle");
	if (ddr_word(mem, phys, NULL, &v) < 0)
		return;
	if (ddr_word(mem, phys, &back, NULL) < 0)
		return;
	say("  %o (0x%06x) at 0x%08x: 0x%08x, read back 0x%08x%s", phys, phys,
	    cons_main_byte_address(phys), v, back, back == v ? "" : "  --- DIFFERENT");
}

// ---- the commands -------------------------------------------------------

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

static void help(void)
{
	say("halt            0 into the clock control register: RUN clear (CC's first act on a debuggee)");
	say("start           1 into it: RUN");
	say("step [N]        CC's CC-CLOCK, 2 then 0, N times. THE FABRIC HAS NO SSTEP: it will say so");
	say("regs            all sixteen registers by muir's names, FLAG-1 and FLAG-2 field by field");
	say("status          running or halted, and why; PC; CYCLES measured twice");
	say("ident           IDENT, STAT, CYCLES and TICKS");
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
	say("IDENT 0x%08x  STAT 0x%08x (busy %d, gnt %d, answered %d, lost-since-reset %d)",
	    id, stat, !!(stat & CONS_ST_BUSY), !!(stat & CONS_ST_GNT),
	    !!(stat & CONS_ST_ANSWERED), !!(stat & CONS_ST_LOST));
	say("CYCLES %llu microcycles, TICKS %llu at 5 ns = %llu us since reset",
	    (unsigned long long)cy, (unsigned long long)ti, (unsigned long long)(ti / 200));
}

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
		cons_start(c);
		say("start: 1 written to the clock control register (EADR 3); RUN is set");
		do_status(c, settle_us);
	} else if (!strcmp(cmd, "step"))
		do_step(c, argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : 1);
	else if (!strcmp(cmd, "regs"))
		do_regs(c);
	else if (!strcmp(cmd, "status"))
		do_status(c, settle_us);
	else if (!strcmp(cmd, "ident"))
		do_ident(c);
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
		"  --log PATH       where to write (default stdout)\n"
		"  --settle-us N    how long `status` waits between its two reads of CYCLES (default 2000)\n"
		"  --no-guard       touch M_AXI_GP1 without checking the EMIO tally first\n"
		"with no command it reads lines at a `>` prompt; `help` lists them\n");
}

int main(int argc, char **argv)
{
	const char *log_path = NULL;
	uint32_t regs_phys = CONS_REG_BASE;
	unsigned settle_us = 2000, no_guard = 0;
	static const struct option opts[] = {
		{ "regs", required_argument, NULL, 'r' },
		{ "log", required_argument, NULL, 'l' },
		{ "settle-us", required_argument, NULL, 's' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "r:l:s:Gh", opts, NULL)) != -1) {
		switch (c) {
		case 'r': regs_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'l': log_path = optarg; break;
		case 's': settle_us = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'G': no_guard = 1; break;
		default: usage(); return 2;
		}
	}
	FILE *dest = stdout;
	if (log_path) {
		dest = fopen(log_path, "a");
		if (!dest) {
			fprintf(stderr, "cadr-console: %s: %s\n", log_path, strerror(errno));
			return 2;
		}
	}
	cadr_log_init("cadr-console: ", dest);

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

	if (optind < argc)
		return command(&con, &m, settle_us, argc - optind, argv + optind) < 0 ? 1 : 0;
	prompt(&con, &m, settle_us);
	return 0;
}
