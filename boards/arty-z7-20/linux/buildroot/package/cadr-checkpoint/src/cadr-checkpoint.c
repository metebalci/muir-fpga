// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The checkpoint program: the board's machine into a file muir can open, and
// its disks bound to it.
//
//     cadr-checkpoint [-o FILE] [--boards N | --main-memory-size <n>MW]
//                     [--pack FILE[,UNIT]] [--no-packs]
//                     [--pack-dir DIR] [--chaos-address OCTAL] [--no-display]
//                     [--already-halted] [--leave-halted] [--packs-stopped]
//                     [--no-guard] [--machine cadr|quux]
//     cadr-checkpoint --halt | --start
//     cadr-checkpoint --verify FILE.packs [--pack FILE[,UNIT]]
//     cadr-checkpoint --what-it-cannot-read [--machine cadr|quux]
//
// **WHICH MACHINE, `--machine cadr|quux`**, muir's own flag and the one
// `cadr-terminal` and `cadr-disk-packs` take: the CADR, or QUUX, whose
// checkpoint carries its clocks, its register page's keyboard and mouse,
// block-disk, the video controller and its K and L (`chk_rtl.c`).
// **THE FABRIC IS ASKED, AND WITHOUT THE FLAG ITS ANSWER IS THE MACHINE**: the
// readout's register table says which machine the bitstream is, as
// `cadr-console machine` reads it, before a pack is looked at, since what a
// pack is follows the machine.  A flag that names the other machine is
// refused, naming both, since it would be a file of one machine's fields
// filled from the other's; and an identity that cannot be read is refused,
// with no machine assumed (`bind_machine_bay`).  The CADR was the default,
// and the bay was held to it first: on a QUUX board without `--machine quux`
// the QUUX disk was refused for its size, and the refusal that names the two
// machines was never reached.
//
// **MAIN MEMORY IN EACH MACHINE'S OWN WORDS.**  The CADR's is its memory
// boards, `--boards N`; QUUX has no memory boards, and its main memory is an
// amount, `--main-memory-size <n>MW` in muir's form.  Each is refused on the
// other machine, and everything said about QUUX's is in megawords.
//
// **WHAT IT IS FOR.**  When the board goes wrong there are sixteen diagnostic
// registers and three words beside them, and that is a keyhole.  A checkpoint
// is the other thing: the whole machine in a file, opened in muir, where
// there is a disassembler, a symbol table, a screen, a prompt and every
// engine muir has --- and where it can be RESUMED.  A board that halts at a
// microcycle nobody can explain becomes a file somebody can take apart.
//
// **IT HALTS THE MACHINE AND THAT IS NOT A CONVENIENCE.**  The console's own
// documentation says to halt first, and a read taken while the datapath moves
// is torn: `docs/console.md` records a mid-run readout that reported six
// parity errors on a machine whose parity bits were all clean.  So this
// writes the clock control register with RUN clear, reads, and writes RUN
// back unless `--leave-halted` says not to.
//
// **AND THE FILE RECORDS THE RUN STATE THE MACHINE HAD BEFORE THAT HALT.**
// RUN and SRUN read clear on a machine this program halted, and a file
// written as read resumes halted in muir; so a machine found running is
// written with both set, as they stood, and muir runs it on from where it
// stood with no `continue`.  `--halt` writes down the halt it made, and
// `--already-halted` takes the machine as running when the count still
// stands there (`bind_halted_here`).  The sidecar's `running:` line says
// which, and its resume line names what muir needs to take the file as the
// board ran it: on QUUX the clock's period, and on the CADR its Chaosnet
// address, which is the one the fabric's interface holds unless
// `--chaos-address` says otherwise (`bind_chaos_address`).
//
// **AND THE PACKS ARE READ AT THE SAME INSTANT AS THE MACHINE.**  A
// checkpoint carries the blocks a run has written and never the disk, so a
// resume against a pack that has moved on restores a machine into a disk it
// never had --- and on this board the pack moves continuously, because
// `cadr-disk-packs` writes the machine's blocks straight through to the card.
// So the packs are digested while the machine is halted, between the halt and
// the start, and the digests go in a sidecar beside the checkpoint.
// `pack_bind.h` has the whole argument.  **The program refuses to write
// anything at all if it cannot read a pack**: a checkpoint with no binding is
// the thing this exists to prevent.
//
// **AND IT SAYS WHAT IT COULD NOT READ.**  A checkpoint that silently
// invented state would be worse than no checkpoint at all, so the fields the
// fabric has no reading for are listed on the program's own output every time
// it runs --- not in a document somebody might not have.
// `--what-it-cannot-read` prints that list and nothing else, and needs no
// board.
//
// **THE ORDER IS THE ONE THE GP0 RULE FORCES.**  `cadr_guard` runs before
// anything on a GP port is touched: a read on `M_AXI_GP1` that nothing in the
// fabric answers hangs both Arm cores at one PC each, measured on the board,
// and no software guard can catch that afterwards.  The tally at the PS7's
// own EMIO pins is somewhere the processing system can always reach, and it
// is read first.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cadr/cadr_log.h"
#include "cadr/cadr_mem.h"
#include "cadr_image.h"
#include "chaos_face.h"
#include "chk.h"
#include "chk_rtl.h"
#include "pack_bind.h"
#include "readout.h"

// `rtl/plumbing/cadr_ddr_map.sv`, which is the one map in the project shared
// with the Linux side: the reserved region, main memory at its base and the
// display at its own.  A change there is a change here --- and in
// <cadr/cadr_board.h>, which has the region's base for every board.
#define DDR_MAIN_BASE    CADR_BOARD_MAIN_BASE
#define DDR_DISPLAY_BASE CADR_BOARD_DISPLAY_BASE
// QUUX's main memory, packed storage below the display.
#define DDR_MAIN13_BASE  CADR_BOARD_QUUX13_MAIN_BASE

// **THE MACHINE'S OWN MAIN MEMORY IS THE CONSOLE'S PAGE 2 WORD 37**, in
// 64K-word units: the CADR's memory boards, muir's `--main-memory-boards`, or
// QUUX's amount, muir's `--main-memory-size`, sixteen units a megaword; the
// card sets it at boot (`ro_main_boards`).  This is the count of a fabric
// older than that word, which had 32 fixed in its top level, and muir's own
// default: the CADR's 32 boards, QUUX's 2MW.  **A CADR raised past 32 boards
// cannot cold-boot System 100** --- measured --- and System 1003 and later can.
#define DEFAULT_BOARDS 32u
// **QUUX's MAIN MEMORY IS 32MW ON THE BOARDS BY DEFAULT** (contract G2
// §3), which the fabric comes up with and word 37 reads; the most is the
// room the board keeps for it (`cadr_board.h`), in 64K-word units.
#define MAX_BOARDS_13 (CADR_BOARD_QUUX13_MAIN_WORDS_MAX >> 16)
// The most the CADR's backplane holds, sixty 64K-word boards.
#define MAX_BOARDS 60u

// --- the face over /dev/mem ------------------------------------------------

struct mem_face {
	volatile uint32_t *reg;
};

static uint32_t mem_read(struct readout *r, unsigned word)
{
	struct mem_face *f = r->ctx;
	return f->reg[word];
}

static void mem_write(struct readout *r, unsigned word, uint32_t v)
{
	struct mem_face *f = r->ctx;
	f->reg[word] = v;
}

// --- the program -----------------------------------------------------------

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-checkpoint [-o FILE] [--boards N | --main-memory-size <n>MW]\n"
		"                       [--pack FILE[,UNIT]] [--no-packs] [--pack-dir DIR]\n"
		"                       [--chaos-address OCTAL]\n"
		"                       [--no-display] [--already-halted] [--leave-halted]\n"
		"                       [--packs-stopped] [--no-guard] [--machine cadr|quux]\n"
		"       cadr-checkpoint --halt | --start\n"
		"       cadr-checkpoint --verify FILE" BIND_SUFFIX " [--pack FILE[,UNIT]]\n"
		"       cadr-checkpoint --what-it-cannot-read [--machine cadr|quux]\n");
	exit(2);
}

// QUUX has a window of its own, and its own list.
static void print_missing(int quux)
{
	const char *const *m = quux ? chk_rtl_missing_quux15() : chk_rtl_missing();
	say("what a checkpoint off this board cannot carry, and what is written");
	say("instead.  Every one of these is a field muir's own format has and");
	say("this fabric has no reading for:");
	for (; *m; ++m)
		say("  %s", *m);
}

static char *timestamped(void)
{
	static char buf[64];
	time_t t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);
	snprintf(buf, sizeof buf, "muir-%04d%02d%02d-%02d%02d%02d.chk",
		 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
		 tm.tm_min, tm.tm_sec);
	return buf;
}

static void when(char *out, size_t n)
{
	time_t t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);
	// ISO 8601 with the offset, so that two checkpoints taken in two
	// places can be put in order without anybody asking which clock.
	if (strftime(out, n, "%Y-%m-%dT%H:%M:%S%z", &tm) == 0)
		snprintf(out, n, "unknown");
}

// The window, opened.  Everything that touches `M_AXI_GP1` goes through this,
// so the guard and the two refusals are written once.
static int open_window(struct readout *r, struct mem_face *face, int guard, int *fd)
{
	*fd = cadr_open_mem();
	if (*fd < 0)
		return -1;
	// **BEFORE ANYTHING ON GP1.**  See the header, and `cadr_mem.h`'s.
	if (guard && cadr_guard(*fd, CADR_BOARD_CONSOLE_PORT) != 0)
		return -1;
	face->reg = cadr_map(*fd, RO_REG_BASE, RO_REG_BYTES, "the console's window");
	if (!face->reg)
		return -1;
	memset(r, 0, sizeof *r);
	r->read = mem_read;
	r->write = mem_write;
	r->ctx = face;

	uint32_t ident = 0;
	if (ro_ident_ok(r, &ident) != 0) {
		if (ident == CADR_IDENT_NONE)
			say("no console at 0x%08x: word 0 reads \"NONE\", which is the "
			    "default slave --- this bitstream has no console in it",
			    RO_REG_BASE);
		else if (ident == RO_UNMAPPED)
			say("no console at 0x%08x: word 0 reads 0x%08x, the window's "
			    "own UNMAPPED", RO_REG_BASE, ident);
		else
			say("no console at 0x%08x: word 0 reads 0x%08x, wanting "
			    "\"CONS\" 0x%08x", RO_REG_BASE, ident, RO_IDENT_WORD);
		return -1;
	}
	// **THE READOUT HAS TO BE IN THE BITSTREAM, AND THE WINDOW SAYS SO
	// WITHOUT BEING ASKED.**  A fabric older than these three words answers
	// UNMAPPED at all of them, and UNMAPPED is a value that means nothing:
	// it must not be read as an address or as a word.
	const uint32_t echo = r->read(r, RO_ADDR);
	if (echo == RO_UNMAPPED) {
		say("this bitstream's console has no readout: page 0's word 10 "
		    "reads 0x%08x, cadr_console.sv's own UNMAPPED.  There is "
		    "nothing to make a checkpoint out of.", echo);
		return -1;
	}
	return 0;
}

// A machine `ro_found` found stood and not halted, said: `when` it was
// found so, and what it read.
static void say_not_halted(int found, const struct ro_stand *s, int rev15, const char *when)
{
	char text[512];
	ro_stand_text(s, rev15, text, sizeof text);
	if (found == RO_FOUND_LOST)
		say("%s, the machine was retiring no microcycles and the console's window "
		    "did not answer the question why: %s", when, text);
	else
		say("%s, the machine has stopped retiring microcycles and is NOT HALTED: %s",
		    when, text);
}

// --- verifying a binding, which needs no board -----------------------------

static int do_verify(const char *sidecar, char **override, unsigned overrides)
{
	struct binding b;
	char err[512] = "";
	if (bind_read(&b, sidecar, err, sizeof err) != 0) {
		say("%s", err);
		return 1;
	}
	for (unsigned i = 0; i < overrides; ++i) {
		// A pack the resume has under another name.  It replaces the
		// recorded path and NOT the recorded digest, which is the whole
		// point of the exercise.
		const char *spec = override[i];
		const char *comma = strrchr(spec, ',');
		const unsigned u = comma ? (unsigned)strtoul(comma + 1, NULL, 10) : 0u;
		if (u >= BIND_UNITS || !b.u[u].present) {
			say("--pack %s: the binding has no unit %u", spec, u);
			return 1;
		}
		const size_t n = comma ? (size_t)(comma - spec) : strlen(spec);
		if (n >= sizeof b.u[u].path) {
			say("--pack %s: the file's name is too long", spec);
			return 1;
		}
		memcpy(b.u[u].path, spec, n);
		b.u[u].path[n] = '\0';
	}
	char memory[64];
	bind_memory_words(b.quux, b.boards, memory, sizeof memory);
	say("%s: the checkpoint %s, taken %s, %llu microcycles, %s, "
	    "%u pack(s)", sidecar, b.checkpoint, b.taken,
	    (unsigned long long)b.microcycles, memory, b.present);
	int chk_moved = 0;
	const int moved = bind_verify(&b, &chk_moved, err, sizeof err);
	if (moved < 0) {
		say("%s", err);
		say("REFUSED: a pack this binding names cannot be read, so nothing "
		    "can be said about it.  Do not resume.");
		return 1;
	}
	if (chk_moved)
		say("the checkpoint %s is NOT the file this binding was written "
		    "for: its digest has changed", b.checkpoint);
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!b.u[u].present)
			continue;
		if (b.u[u].moved)
			say("unit %u %s HAS MOVED: %s now, %s when the checkpoint "
			    "was taken", u, b.u[u].path, b.u[u].now, b.u[u].sha256);
		else
			say("unit %u %s is the pack the checkpoint was taken on",
			    u, b.u[u].path);
	}
	if (moved || chk_moved) {
		say("DO NOT RESUME THIS CHECKPOINT ON THESE FILES.  A checkpoint "
		    "carries the blocks the run had written and not the disk, so "
		    "the machine would come up holding pages it wrote onto a pack "
		    "that has since been written by something else.  Nothing in "
		    "muir can notice: the controller recomputes a block's header "
		    "and checkwords as it moves it, so a block from another moment "
		    "is handed to the microcode as good.");
		return 1;
	}
	char cmd[4096];
	bind_resume_command(&b, cmd, sizeof cmd);
	say("the binding holds.  To resume: %s", cmd);
	return 0;
}

// --- the capture -----------------------------------------------------------

int main(int argc, char **argv)
{
	cadr_log_init("cadr-checkpoint: ", NULL);

	const char *out = NULL;
	const char *verify = NULL;
	const char *pack_dir = BIND_DIR;
	unsigned boards = 0;	/* 64K-word units: the machine's own unless a flag says */
	const char *boards_arg = NULL;	/* the CADR's --boards */
	const char *size_arg = NULL;	/* QUUX's --main-memory-size */
	unsigned long chaos = BIND_CHAOS_DEFAULT;
	int chaos_asked = 0;
	int want_display = 1, leave_halted = 0, guard = 1;
	int already_halted = 0, no_packs = 0, halt_only = 0, start_only = 0;
	int packs_stopped = 0;
	// `--machine`'s, or the fabric's when it is not given.
	int machine = BIND_MACHINE_FABRIC, want_missing = 0;
	char *packs[BIND_UNITS];
	unsigned npacks = 0;

	for (int i = 1; i < argc; ++i) {
		const char *a = argv[i];
		if (!strcmp(a, "--what-it-cannot-read")) {
			want_missing = 1;
		} else if (!strcmp(a, "--machine") && i + 1 < argc) {
			// muir's own two words, as `cadr-terminal` takes them.
			const char *v = argv[++i];
			if (!strcmp(v, "quux")) {
				machine = 1;
			} else if (!strcmp(v, "cadr")) {
				machine = 0;
			} else {
				say("--machine %s: wants cadr or quux", v);
				return 2;
			}
		} else if (!strcmp(a, "-o") && i + 1 < argc) {
			out = argv[++i];
		} else if (!strcmp(a, "--verify") && i + 1 < argc) {
			verify = argv[++i];
		} else if (!strcmp(a, "--boards") && i + 1 < argc) {
			boards_arg = argv[++i];
		} else if (!strcmp(a, "--main-memory-size") && i + 1 < argc) {
			size_arg = argv[++i];
		} else if (!strcmp(a, "--pack") && i + 1 < argc) {
			if (npacks >= BIND_UNITS) {
				say("--pack: the controller has %u unit slots",
				    BIND_UNITS);
				return 2;
			}
			packs[npacks++] = argv[++i];
		} else if (!strcmp(a, "--pack-dir") && i + 1 < argc) {
			pack_dir = argv[++i];
		} else if (!strcmp(a, "--no-packs")) {
			no_packs = 1;
		} else if (!strcmp(a, "--chaos-address") && i + 1 < argc) {
			unsigned v = 0;
			if (chk_chaos_address(argv[++i], &v) != 0) {
				say("--chaos-address %s: an address is OCTAL, as muir's own "
				    "flag takes it --- a bare octal number or subnet:host, "
				    "both halves non-zero and neither above 377",
				    argv[i]);
				return 2;
			}
			chaos = v;
			chaos_asked = 1;
		} else if (!strcmp(a, "--no-display")) {
			want_display = 0;
		} else if (!strcmp(a, "--packs-stopped")) {
			packs_stopped = 1;
		} else if (!strcmp(a, "--already-halted")) {
			already_halted = 1;
		} else if (!strcmp(a, "--leave-halted")) {
			leave_halted = 1;
		} else if (!strcmp(a, "--no-guard")) {
			guard = 0;
		} else if (!strcmp(a, "--halt")) {
			halt_only = 1;
		} else if (!strcmp(a, "--start")) {
			start_only = 1;
		} else {
			usage();
		}
	}
	// Needs no board, so with no machine named both lists are given.
	if (want_missing) {
		if (machine == BIND_MACHINE_FABRIC) {
			say("no --machine, and this needs no board: the CADR's list, then QUUX's");
			print_missing(0);
			print_missing(1);
		} else {
			print_missing(machine);
		}
		return 0;
	}
	if (verify)
		return do_verify(verify, packs, npacks);
	if (halt_only && start_only)
		usage();
	// The main memory flags are held to the machine, which is not known
	// until the fabric is asked (`bind_machine_bay`).
	int quux = 0;

	struct readout r;
	struct mem_face face;
	int fd = -1;
	if (open_window(&r, &face, guard, &fd) != 0)
		return 1;

	// --- the two standalone modes.  They exist so that an operator can put
	// --- `cadr-disk-packs` to bed BETWEEN the halt and the capture, which
	// --- is the only order in which the packs are certainly whole; the
	// --- board procedure in `docs/checkpoint.md` is those five commands.
	// --- **THE CADR's ONLY**: on QUUX a stopped `cadr-disk-packs` marks the
	// --- drive absent, and the capture then refuses block-disk's empty
	// --- unit 0 against the bay's pack (below), as it must.
	if (halt_only) {
		// QUUX's halt is its drain's end, which `ro_found` asks for by
		// the machine.  A QUUX this program does not read is refused by
		// the revision MACHINE-ID names.
		const int rev = ro_quux_revision(&r);
		if (rev < 0) {
			say("the readout's register table entry %u does not answer: which "
			    "machine this is, and so what its halt is, cannot be said",
			    IMG_RG_QUUX_ID);
			return 1;
		}
		if (ro_machine_of(rev) < 0) {
			say("the bitstream is QUUX revision %d, and this program has no "
			    "layout of its window: nothing is halted", rev);
			return 1;
		}
		const int pipe = rev != 0;
		struct ro_stand st;
		int found = ro_found(&r, pipe, &st);
		if (found == RO_FOUND_HALTED) {
			say("the machine is already halted at %llu microcycles",
			    (unsigned long long)st.cycles);
			return 0;
		}
		if (found != RO_FOUND_RUNNING) {
			say_not_halted(found, &st, pipe, "found");
			say("nothing is written, and the machine is left as it was found");
			return 1;
		}
		ro_halt(&r);
		found = ro_found(&r, pipe, &st);
		if (found == RO_FOUND_RUNNING) {
			say("the machine did not stop: it is still retiring "
			    "microcycles after a write of zero to the clock "
			    "control register");
			return 1;
		}
		if (found != RO_FOUND_HALTED) {
			say_not_halted(found, &st, pipe,
				       "after a write of zero to the clock control register");
			say("no halt is marked, and RUN is left clear");
			return 1;
		}
		// **THE HALT IS THIS PROGRAM'S AND IT IS WRITTEN DOWN**, so that
		// the checkpoint `--already-halted` takes next records the machine
		// as running, which it was until this write: `bind_halted_here`.
		const uint64_t at = ro_cycles(&r);
		if (bind_halt_mark(BIND_HALT_MARK, at) != 0)
			say("%s could not be written: %s.  The checkpoint taken next will "
			    "record the machine halted, as it then reads", BIND_HALT_MARK,
			    strerror(errno));
		say("halted at %llu microcycles.  Nothing is written to the packs "
		    "from here on; stop cadr-disk-packs now, then take the "
		    "checkpoint with --already-halted --leave-halted.",
		    (unsigned long long)at);
		return 0;
	}
	if (start_only) {
		bind_halt_unmark(BIND_HALT_MARK);
		ro_start(&r);
		say("the machine is running again");
		return 0;
	}

	if (!out)
		out = timestamped();

	// --- **WHICH MACHINE THE BITSTREAM IS, ASKED BEFORE ANYTHING IS READ**,
	// --- and then the drive bay held to that machine's rule, BEFORE the
	// --- machine is touched, so that a pack that is not there is found out
	// --- while the machine is still running (`bind_machine_bay`).
	struct binding bind;
	char err[1024] = "";
	unsigned sync_k = 0;
	{
		const struct bind_ask ask = { machine, boards_arg, size_arg, MAX_BOARDS_13,
					      packs, npacks, pack_dir, no_packs };
		char said[1100] = "";
		const int rc = bind_machine_bay(&bind, &r, &ask, &boards, &sync_k, said,
						sizeof said, err, sizeof err);
		if (said[0])
			say("%s", said);
		if (rc != 0) {
			say("%s", err);
			return rc;
		}
		quux = bind.quux;
		if (machine == BIND_MACHINE_FABRIC)
			say("no --machine: the fabric is %s, and the checkpoint is its",
			    quux ? "QUUX" : "the CADR");
	}
	// **AND EVERY FILE NAMED FROM THE PACK FOLDER, ASKED NOW**, while the
	// machine is still running: a pack or a checkpoint outside the pack
	// folder is one the resume line cannot name from there, so it is
	// refused before anything is halted or written.  The names are given
	// to the binding after the packs are digested (`bind_relative`).
	{
		static struct binding named;
		named = bind;
		if (bind_relative(&named, pack_dir, out, err, sizeof err) != 0) {
			say("%s", err);
			say("nothing is halted and nothing is written");
			return 1;
		}
	}

	// **THE CADR's CHAOSNET ADDRESS IS THE INTERFACE's OWN**, read as
	// `cadr-chaosnet` reads it: the guard, the interface's face at
	// `CHAOS_REG_BASE`, "CHAO", then the switches.  muir refuses to resume a
	// checkpoint at any address but its switches', so the file and the
	// resume line carry this one (`bind_chaos_address`).  QUUX has no
	// Chaosnet, and its checkpoint keeps the address asked or muir's default.
	if (!quux) {
		struct chaos_face cf;
		int opened = 0;
		if ((!guard || cadr_guard(fd, "the Chaosnet interface") == 0) &&
		    chaos_face_open(&cf, fd, CHAOS_REG_BASE) == 0)
			opened = 1;
		char msg[512];
		chaos = bind_chaos_address(opened ? &cf : NULL, chaos_asked, (unsigned)chaos,
					   msg, sizeof msg);
		if (msg[0])
			say("%s", msg);
		if (opened)
			chaos_face_close(&cf);
	}
	// **AND WHICH REVISION OF QUUX**, entry 21's <15:0>, MACHINE-ID's: this
	// program reads QUUX at `IMG_QUUX_REVISION` alone, and an older fabric
	// is refused by the revision the identity line reads.
	int revision = 0;
	if (quux) {
		revision = ro_quux_revision(&r);
		if (revision < 0) {
			say("the readout's register table entry %u names no revision of QUUX",
			    IMG_RG_QUUX_ID);
			return 1;
		}
		if (ro_machine_of(revision) < 0) {
			say("the bitstream is QUUX revision %d, and this program has no layout "
			    "of its window: nothing is written", revision);
			return 1;
		}
		// Entry 21's <31:24> is the clock's period in units of 0.5 ns.
		say("the bitstream is QUUX, its clock's period %u%s ns, 40-bit words and "
		    "packed main memory, checkpoint version %u", sync_k / 2u,
		    sync_k % 2u ? ".5" : "", CHK_VERSION_16);
	}
	// **HOW MUCH MAIN MEMORY, WHICH IS THE MACHINE'S AND NOT A GUESS.**  A
	// checkpoint is of all of main memory, and muir refuses to resume one
	// under another amount, so it is the fabric's own: the console's word
	// 37.  A fabric older than the word had 32 units fixed.  A `--boards` or
	// `--main-memory-size` that disagrees with the fabric is refused,
	// because a checkpoint of less drops memory the band has and one of more
	// invents it.
	char memory[64];
	{
		const unsigned fabric = ro_main_boards(&r);
		bind_memory_words(quux, DEFAULT_BOARDS, memory, sizeof memory);
		if (!fabric)
			say("the console's word 37 carries no main memory: this bitstream "
			    "is older than the word and has %s fixed", memory);
		const unsigned has = fabric ? fabric : DEFAULT_BOARDS;
		if (boards && boards != has) {
			bind_memory_words(quux, has, memory, sizeof memory);
			say("%s %s, and the machine has %s: a checkpoint is of all of main "
			    "memory, so it is taken at the machine's own",
			    quux ? "--main-memory-size" : "--boards", quux ? size_arg : boards_arg,
			    memory);
			return 2;
		}
		boards = has;
	}
	bind_memory_words(quux, boards, memory, sizeof memory);
	if (!quux && boards > MAX_BOARDS) {
		say("the machine has %s: the backplane holds 1 to %u", memory, MAX_BOARDS);
		return 2;
	}
	if (quux && boards > MAX_BOARDS_13) {
		say("the machine has %s: QUUX's room on this board holds 1MW to %uMW",
		    memory, MAX_BOARDS_13 / RO_MW_UNITS);
		return 2;
	}

	// **QUUX'S VIDEO CONTROLLER IS THE BITSTREAM'S SIZE** (console word 39):
	// the checkpoint carries its buffer and its size, and muir resumes it at
	// that size alone.  A bitstream older than the word has 1280 by 1024.
	struct cadr_video video;
	cadr_video_old(&video);
	if (quux) {
		const int v = ro_video(&r, &video);
		if (v < 0) {
			say("the console's word 39 says a video controller no QUUX has (%08x)",
			    (unsigned)r.read(&r, RO_VIDEO));
			return 1;
		}
		if (v == 0) {
			cadr_video_old(&video);
			say("the console's word 39 carries no video controller: this bitstream "
			    "is older than the word, and its video controller is %ux%u",
			    video.width, video.height);
		}
	}

	struct cadr_image img;
	if (img_alloc_video(&img, boards, quux, revision, video.width, video.height) != 0) {
		say("out of memory for a machine of %s", memory);
		return 1;
	}
	struct chk_declared decl;
	memset(&decl, 0, sizeof decl);
	decl.chaos_address = (uint32_t)chaos;
	// QUUX's memory timing is the board's preset of muir's
	// (`cadr_board.h`), declared in the file and named on the resume line.
	if (quux && bind_memory_timing(&bind, &decl, CADR_BOARD_MEMORY_TIMING) != 0) {
		say("this board's memory timing, %s, is none of muir's presets",
		    CADR_BOARD_MEMORY_TIMING);
		img_free(&img);
		return 1;
	}
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!bind.u[u].present)
			continue;
		decl.present |= 1u << u;
		bind_declared(&bind.u[u], &decl.cylinders[u], &decl.heads[u],
			      &decl.blocks_per_track[u]);
		decl.read_only[u] = bind.u[u].read_only;
	}

	// **A CHECKPOINT IS OF A HALTED MACHINE, AND A MACHINE THAT HAS STOPPED
	// RETIRING IS NOT ONE.**  CYCLES stands still on both, so `ro_found`
	// asks why it stands (`readout.h`): one stopped with SRUN up and no halt
	// named, or on QUUX with its pipeline undrained, is refused here,
	// before anything is read, and left as it was found.
	const int rev15 = quux;
	struct ro_stand stand;
	const int found = ro_found(&r, rev15, &stand);
	if (found != RO_FOUND_RUNNING && found != RO_FOUND_HALTED) {
		say_not_halted(found, &stand, rev15, "found");
		say("REFUSED: nothing is written.  A checkpoint is of a halted machine, "
		    "and this one stands wherever it stopped; the machine is left as "
		    "it was found.");
		img_free(&img);
		return 1;
	}
	const int was_running = found == RO_FOUND_RUNNING;
	// **WHETHER THE MACHINE WAS RUNNING BEFORE THE HALT THIS CHECKPOINT IS
	// TAKEN IN**: running when found, and so halted here; or halted by
	// `--halt` for it, at the count it still stands at.
	const int halted_for_it = !was_running && already_halted &&
				  bind_halted_here(BIND_HALT_MARK, ro_cycles(&r));
	const int ran = was_running || halted_for_it;
	if (was_running && already_halted) {
		say("--already-halted, and the machine is still retiring "
		    "microcycles.  Nothing is read.");
		img_free(&img);
		return 1;
	}
	if (was_running) {
		say("the machine is running; halting it, as the console's own "
		    "documentation says to.  A read taken while the datapath "
		    "moves is torn.");
		ro_halt(&r);
		const int after = ro_found(&r, rev15, &stand);
		if (after == RO_FOUND_RUNNING) {
			say("the machine did not stop: it was still retiring microcycles "
			    "2 ms after a write of zero to the clock control register, "
			    "and it is started again as it was found");
			ro_start(&r);
			img_free(&img);
			return 1;
		}
		if (after != RO_FOUND_HALTED) {
			say_not_halted(after, &stand, rev15,
				       "after a write of zero to the clock control register");
			say("REFUSED: nothing is written, and it is started again as it "
			    "was found");
			ro_start(&r);
			img_free(&img);
			return 1;
		}
	}
	bind.machine_halted_first = 1;
	// **SAID BY THE OPERATOR, NOT GUESSED.**  This program cannot see
	// whether `cadr-disk-packs` is running, and a sidecar that claimed it
	// had been stopped when it had not would be a claim nothing checked.
	// So the field is "unknown" unless `--packs-stopped` says otherwise.
	bind.packs_program_stopped = packs_stopped;

	if (ro_read_machine(&r, &img) != 0) {
		say("the readout gave back a word for an address that was not "
		    "the one asked for, %lu times: the window is not answering",
		    r.stale);
		img_free(&img);
		return 1;
	}
	// **QUUX: THE WRITE BUFFER IS DRAINED BEFORE MAIN MEMORY IS READ**
	// (contract Q6): its halt drains the port before it stands (A15b.13).
	// **QUUX: THE FABRIC'S DISK AND THE BAY MUST AGREE, AND NO TRANSFER MAY
	// BE IN FLIGHT.**  Block-disk says whether a pack is on unit 0, and muir
	// refuses a checkpoint with a pack onto a machine without one; a walk in
	// progress is a transfer half done, which no file can carry.
	if (quux) {
		const int bay = (decl.present & 1u) != 0;
		if (img.qx.present != bay) {
			say("block-disk %s a pack on unit 0 and the drive bay %s one",
			    img.qx.present ? "has" : "has not", bay ? "holds" : "holds no");
			img_free(&img);
			if (was_running && !leave_halted)
				ro_start(&r);
			return 1;
		}
		if (img.qx.walking) {
			say("block-disk is walking a command list: a transfer is in "
			    "flight and no checkpoint can carry it.  Start the machine "
			    "and halt it between transfers.");
			img_free(&img);
			if (was_running && !leave_halted)
				ro_start(&r);
			return 1;
		}
		// **THE FILE DEVICE, AS muir REFUSES IT** (revision 9):
		// `chk_rtl_refusal` has the rule.
		{
			char why[160];
			if (chk_rtl_refusal(&img, why, sizeof why)) {
				say("%s", why);
				img_free(&img);
				if (was_running && !leave_halted)
					ro_start(&r);
				return 1;
			}
		}
	}

	// **AND THE RUN STATE IT HAD BEFORE THE HALT**: RUN and SRUN read clear
	// on a machine this program halted, and are written as they stood, so
	// that muir resumes it running from where it stood (`chk_rtl_run_state`).
	chk_rtl_run_state(&img, ran);
	if (ran)
		say("the machine was running%s: the file records RUN and SRUN set, as "
		    "they stood before the halt, and muir resumes it running",
		    halted_for_it ? " until cadr-checkpoint --halt stopped it" : "");
	else if (quux)
		// QUUX's RUN is the console word's `<6>`, and it keeps no SRUN in
		// its file (`chk_rtl_run_state`).
		say("the machine was halted when found: the file records RUN %s, as read",
		    (img.q15.tail[IMG_TL15_CONSOLE] >> 6) & 1u ? "set" : "clear");
	else
		say("the machine was halted when found: the file records RUN %s "
		    "and SRUN %s, as read",
		    img_flag(&img, IMG_F_RUN) ? "set" : "clear",
		    img_flag(&img, IMG_F_SRUN) ? "set" : "clear");

	// **THE FIRST DISPLAY BOARD'S COLOR MAP**, off the console face's page
	// 4.  It is not DDR and it is not the readout window: register 4 is
	// write only on the Xbus, the RAMs and their converters being off the
	// board, so the fabric keeps the sixteen entries as muir's
	// `tv::Tv::color_map` does and that page is the only way to ask.  A
	// fabric older than the page reads its own UNMAPPED there, whose bytes
	// are not zero --- so a map is taken only when the read looks like one,
	// and a machine that has written none leaves the power-on map of zeros
	// muir comes up with.
	if (!quux && ro_color_map(&r, 0, img.tv_map)) {
		unsigned n = 0;
		for (unsigned c = 0; c < IMG_MAP_COLORS; ++c)
			for (unsigned k = 0; k < IMG_MAP_CHANNELS; ++k)
				n += img.tv_map[c][k] != 0;
		say("the first display board's color map: %u of its %u channels are not zero",
		    n, IMG_MAP_COLORS * IMG_MAP_CHANNELS);
	}

	// Main memory and the display, straight out of DDR.  **Not through the
	// machine**: the fabric's own memory port is the machine's, and Linux
	// reads the same cells from the other side of the controller, which is
	// what the proving boards established on silicon.
	if (quux) {
		// **QUUX's IS NOT COPIED.**  Packed storage is the file's
		// own layout for 40-bit words, and 32M words are 160 MB, which a
		// copy beside a body of the same size would leave Linux no room
		// for: the mapping is handed to the file as it stands, and read
		// while the machine is halted (`chk_hole`).
		img.main13 = cadr_map(fd, DDR_MAIN13_BASE, (size_t)boards * IMG_BOARD_WORDS * 5u,
				      "QUUX's main memory");
		if (!img.main13) {
			img_free(&img);
			return 1;
		}
	} else {
		volatile uint32_t *main_mem =
			cadr_map(fd, DDR_MAIN_BASE, (size_t)boards * IMG_BOARD_WORDS * 4u,
				 "main memory");
		if (!main_mem) {
			img_free(&img);
			return 1;
		}
		for (size_t i = 0; i < (size_t)boards * IMG_BOARD_WORDS; ++i)
			img.main[i] = main_mem[i];
	}

	if (want_display) {
		// The CADR display's 32,768 words, or the video controller's, its
		// height times its width over 32: 40,960 at 1280 by 1024, 64,800 at
		// 1920 by 1080.
		volatile uint32_t *tv =
			cadr_map(fd, DDR_DISPLAY_BASE, (size_t)img.tv_words * 4u,
				 "the display's window");
		if (!tv) {
			img_free(&img);
			return 1;
		}
		for (size_t i = 0; i < img.tv_words; ++i)
			img.tv[i] = tv[i];
	}

	// **THE PACKS, STILL HALTED, AND BEFORE ANYTHING IS WRITTEN.**  A pack
	// this cannot read is a pack nothing can be bound to, and a checkpoint
	// with no binding is worse than none --- so the refusal comes before
	// the file exists rather than after it.
	if (bind.present) {
		say("digesting %u pack(s) while the machine is halted.  This reads "
		    "every byte and takes a while; the machine is not running and "
		    "the packs are not moving, which is the point.", bind.present);
		if (bind_digest(&bind, err, sizeof err) != 0) {
			say("%s", err);
			say("REFUSED: nothing is written.  A checkpoint that cannot "
			    "name the disk it was taken on is a machine restored "
			    "into a disk it never had.");
			img_free(&img);
			if (was_running && !leave_halted)
				ro_start(&r);
			return 1;
		}
	}

	struct chk body;
	chk_init(&body);
	chk_rtl_body(&body, &img, &decl);
	if (chk_write_file(out, "rtl", boards, &body) != 0) {
		say("could not write %s: %s", out, strerror(errno));
		chk_free(&body);
		img_free(&img);
		return 1;
	}
	const size_t body_len = body.len;
	chk_free(&body);

	// The sidecar, named for the checkpoint and carrying its digest too, so
	// that a sidecar beside the wrong file is found out as well.
	bind.boards = boards;
	bind.quux = quux;
	bind.revision = quux ? (unsigned)revision : 0u;
	bind.sync_k = quux ? sync_k : 0u;
	bind.video_width = quux ? img.video_width : 0u;
	// QUUX's 253-257, the board's device's: the resume line names them,
	// since muir refuses a resume under others.
	bind.eth = quux;
	if (quux) {
		memcpy(bind.eth_mac, img.q15.eth.mac, sizeof bind.eth_mac);
		bind.eth_address = img.q15.eth.address;
		bind.eth_netmask = img.q15.eth.netmask;
		bind.eth_gateway = img.q15.eth.gateway;
	}
	bind.video_height = quux ? img.video_height : 0u;
	bind.running = ran;
	bind.chaos_address = quux ? 0u : (unsigned)chaos;
	bind.microcycles = img.cycles;
	// QUUX's instant is in units of 0.5 ns.
	bind.ns = quux ? img.q15.ns / 2u : img.ticks * CHK_GRID_NS;
	when(bind.taken, sizeof bind.taken);
	snprintf(bind.checkpoint, sizeof bind.checkpoint, "%s", out);
	if (sha256_file(out, bind.checkpoint_sha, &bind.checkpoint_bytes) != 0) {
		say("%s was written and cannot be read back: %s", out, strerror(errno));
		img_free(&img);
		return 1;
	}
	// The packs digested and the checkpoint read back, every name is the
	// pack folder's from here on.
	if (bind_relative(&bind, pack_dir, out, err, sizeof err) != 0) {
		say("the checkpoint is written and its binding is not: %s", err);
		say("DO NOT RESUME %s: nothing says which packs it belongs to.", out);
		img_free(&img);
		return 1;
	}
	char sidecar[1024];
	snprintf(sidecar, sizeof sidecar, "%s" BIND_SUFFIX, out);
	// **THE LINE PRINTED IS THE SIDECAR's `resume:` LINE**, given back by
	// the write that wrote it, so the two are one string.
	char cmd[4096];
	if (bind_write(&bind, sidecar, cmd, sizeof cmd, err, sizeof err) != 0) {
		say("the checkpoint is written and its binding is not: %s", err);
		say("DO NOT RESUME %s: nothing says which packs it belongs to.", out);
		img_free(&img);
		return 1;
	}

	say("%s written: %s, %llu microcycles retired, PC %o, "
	    "%zu bytes of body packed",
	    out, memory, (unsigned long long)img.cycles,
	    quux ? (unsigned)(img.q15.tail[IMG_TL15_NPC] & 0x3FFFu) : (unsigned)img.pc, body_len);
	say("  %lu reads and %lu writes over the console's window",
	    r.reads, r.writes);
	say("%s written: %u pack(s) bound to it by name, geometry and SHA-256",
	    sidecar, bind.present);
	for (unsigned u = 0; u < BIND_UNITS; ++u)
		if (bind.u[u].present)
			say("  unit %u %s  %u,%u,%u  %s", u, bind.u[u].path,
			    bind.u[u].cylinders, bind.u[u].heads,
			    bind.u[u].blocks_per_track, bind.u[u].sha256);
	say("  the names are the pack folder's, %s: run these from there", pack_dir);
	say("  to open it: %s", cmd);
	// **SAID EVERY TIME, BECAUSE IT IS THE ONE THING NOTHING CHECKS.**
	say("BEFORE RESUMING, check the packs against the digests above ---");
	say("  cadr-checkpoint --verify %s" BIND_SUFFIX, bind.checkpoint);
	say("  or sha256sum on each pack, by hand.");
	say("A pack written since this instant makes the resumed machine hold "
	    "pages that no longer match its disk, and NEITHER muir NOR anything "
	    "in the fabric can see that: the controller recomputes a block's "
	    "header and checkwords as it moves it, so a block from another "
	    "moment passes every check the machine makes.");
	print_missing(quux);

	img_free(&img);
	if (was_running && !leave_halted) {
		ro_start(&r);
		say("the machine is running again");
	} else if (leave_halted) {
		say("the machine is left halted, as asked");
	}
	return 0;
}
