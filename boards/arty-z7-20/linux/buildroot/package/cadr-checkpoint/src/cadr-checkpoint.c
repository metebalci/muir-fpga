// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The checkpoint program: the board's machine into a file muir can open, and
// its disks bound to it.
//
//     cadr-checkpoint [-o FILE] [--boards N] [--pack FILE[,UNIT]] [--no-packs]
//                     [--pack-dir DIR] [--chaos-address N] [--no-display]
//                     [--already-halted] [--leave-halted] [--packs-stopped]
//                     [--no-guard]
//     cadr-checkpoint --halt | --start
//     cadr-checkpoint --verify FILE.packs [--pack FILE[,UNIT]]
//     cadr-checkpoint --what-it-cannot-read
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
#include "chk.h"
#include "chk_rtl.h"
#include "pack_bind.h"
#include "readout.h"

// `rtl/plumbing/cadr_ddr_map.sv`, which is the one map in the project shared
// with the Linux side: the reserved region, main memory at its base and the
// display at its own.  A change there is a change here.
#define DDR_MAIN_BASE    0x18000000u
#define DDR_DISPLAY_BASE 0x1C000000u

// muir's own default Chaosnet address, `chaos::Config::default()`.
#define DEFAULT_CHAOS_ADDRESS 0177001u
// `boards(7'd32)` in `boards/arty-z7-20/cadr_arty.sv`.  **A board raised past
// 32 cannot cold-boot System 100** --- measured --- so this is the machine's
// number and not a default anybody should move here.
#define DEFAULT_BOARDS 32u

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
		"usage: cadr-checkpoint [-o FILE] [--boards N] [--pack FILE[,UNIT]]\n"
		"                       [--no-packs] [--pack-dir DIR] [--chaos-address N]\n"
		"                       [--no-display] [--already-halted] [--leave-halted]\n"
		"                       [--packs-stopped] [--no-guard]\n"
		"       cadr-checkpoint --halt | --start\n"
		"       cadr-checkpoint --verify FILE" BIND_SUFFIX " [--pack FILE[,UNIT]]\n"
		"       cadr-checkpoint --what-it-cannot-read\n");
	exit(2);
}

static void print_missing(void)
{
	const char *const *m = chk_rtl_missing();
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
	if (guard && cadr_guard(*fd, "M_AXI_GP1") != 0)
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
	say("%s: the checkpoint %s, taken %s, %llu microcycles, %u memory boards, "
	    "%u pack(s)", sidecar, b.checkpoint, b.taken,
	    (unsigned long long)b.microcycles, b.boards, b.present);
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
	bind_resume_command(&b, b.checkpoint, cmd, sizeof cmd);
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
	unsigned boards = DEFAULT_BOARDS;
	unsigned long chaos = DEFAULT_CHAOS_ADDRESS;
	int want_display = 1, leave_halted = 0, guard = 1;
	int already_halted = 0, no_packs = 0, halt_only = 0, start_only = 0;
	int packs_stopped = 0;
	char *packs[BIND_UNITS];
	unsigned npacks = 0;

	for (int i = 1; i < argc; ++i) {
		const char *a = argv[i];
		if (!strcmp(a, "--what-it-cannot-read")) {
			print_missing();
			return 0;
		} else if (!strcmp(a, "-o") && i + 1 < argc) {
			out = argv[++i];
		} else if (!strcmp(a, "--verify") && i + 1 < argc) {
			verify = argv[++i];
		} else if (!strcmp(a, "--boards") && i + 1 < argc) {
			boards = (unsigned)strtoul(argv[++i], NULL, 0);
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
			chaos = strtoul(argv[++i], NULL, 0);
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
	if (verify)
		return do_verify(verify, packs, npacks);
	if (halt_only && start_only)
		usage();
	if (boards < 1 || boards > 60) {
		say("--boards %u: the backplane holds 1 to 60", boards);
		return 2;
	}

	struct readout r;
	struct mem_face face;
	int fd = -1;
	if (open_window(&r, &face, guard, &fd) != 0)
		return 1;

	// --- the two standalone modes.  They exist so that an operator can put
	// --- `cadr-disk-packs` to bed BETWEEN the halt and the capture, which
	// --- is the only order in which the packs are certainly whole; the
	// --- board procedure in `docs/checkpoint.md` is those five commands.
	if (halt_only) {
		if (ro_is_halted(&r)) {
			say("the machine is already halted at %llu microcycles",
			    (unsigned long long)ro_cycles(&r));
			return 0;
		}
		ro_halt(&r);
		if (!ro_is_halted(&r)) {
			say("the machine did not stop: it is still retiring "
			    "microcycles after a write of zero to the clock "
			    "control register");
			return 1;
		}
		say("halted at %llu microcycles.  Nothing is written to the packs "
		    "from here on; stop cadr-disk-packs now, then take the "
		    "checkpoint with --already-halted --leave-halted.",
		    (unsigned long long)ro_cycles(&r));
		return 0;
	}
	if (start_only) {
		ro_start(&r);
		say("the machine is running again");
		return 0;
	}

	if (!out)
		out = timestamped();

	// --- the drive bay, BEFORE the machine is touched, so that a pack that
	// --- is not there is found out while the machine is still running.
	struct binding bind;
	bind_init(&bind);
	char err[1024] = "";
	for (unsigned i = 0; i < npacks; ++i) {
		if (bind_add(&bind, packs[i], err, sizeof err) != 0) {
			say("%s", err);
			return 1;
		}
	}
	if (!npacks && !no_packs) {
		err[0] = '\0';
		bind_scan(&bind, pack_dir, err, sizeof err);
		if (err[0])
			say("looking at the drive bay: %s", err);
	}
	if (!bind.present && !no_packs) {
		say("no pack in %s and none named with --pack.  A checkpoint of a "
		    "machine with a disk and no binding to that disk is the thing "
		    "this program exists to prevent, so nothing is written.  Name "
		    "the packs, or say --no-packs if the machine really has no "
		    "drive.", pack_dir);
		return 1;
	}
	if (no_packs && bind.present) {
		say("--no-packs, and the drive bay holds %u pack(s): the two "
		    "disagree", bind.present);
		return 1;
	}

	struct cadr_image img;
	if (img_alloc(&img, boards) != 0) {
		say("out of memory for a machine of %u boards", boards);
		return 1;
	}
	struct chk_declared decl;
	memset(&decl, 0, sizeof decl);
	decl.chaos_address = (uint32_t)chaos;
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!bind.u[u].present)
			continue;
		decl.present |= 1u << u;
		decl.cylinders[u] = bind.u[u].cylinders;
		decl.heads[u] = bind.u[u].heads;
		decl.blocks_per_track[u] = bind.u[u].blocks_per_track;
		decl.read_only[u] = bind.u[u].read_only;
	}

	const int was_running = !ro_is_halted(&r);
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
	}
	if (!ro_is_halted(&r)) {
		say("the machine did not stop: it is still retiring microcycles "
		    "after a write of zero to the clock control register");
		img_free(&img);
		return 1;
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

	// Main memory and the display, straight out of DDR.  **Not through the
	// machine**: the fabric's own memory port is the machine's, and Linux
	// reads the same cells from the other side of the controller, which is
	// what the proving boards established on silicon.
	volatile uint32_t *main_mem =
		cadr_map(fd, DDR_MAIN_BASE, (size_t)boards * IMG_BOARD_WORDS * 4u,
			 "main memory");
	if (!main_mem) {
		img_free(&img);
		return 1;
	}
	for (size_t i = 0; i < (size_t)boards * IMG_BOARD_WORDS; ++i)
		img.main[i] = main_mem[i];

	if (want_display) {
		volatile uint32_t *tv =
			cadr_map(fd, DDR_DISPLAY_BASE, IMG_TV_WORDS * 4u,
				 "the display's window");
		if (!tv) {
			img_free(&img);
			return 1;
		}
		for (size_t i = 0; i < IMG_TV_WORDS; ++i)
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
	bind.microcycles = img.cycles;
	bind.ns = img.ticks * 5u;
	when(bind.taken, sizeof bind.taken);
	snprintf(bind.checkpoint, sizeof bind.checkpoint, "%s", out);
	if (sha256_file(out, bind.checkpoint_sha, &bind.checkpoint_bytes) != 0) {
		say("%s was written and cannot be read back: %s", out, strerror(errno));
		img_free(&img);
		return 1;
	}
	char sidecar[1024];
	snprintf(sidecar, sizeof sidecar, "%s" BIND_SUFFIX, out);
	if (bind_write(&bind, sidecar, err, sizeof err) != 0) {
		say("the checkpoint is written and its binding is not: %s", err);
		say("DO NOT RESUME %s: nothing says which packs it belongs to.", out);
		img_free(&img);
		return 1;
	}

	say("%s written: %u memory boards, %llu microcycles retired, PC %o, "
	    "%zu bytes of body packed",
	    out, boards, (unsigned long long)img.cycles, img.pc, body_len);
	say("  %lu reads and %lu writes over the console's window",
	    r.reads, r.writes);
	say("%s written: %u pack(s) bound to it by name, geometry and SHA-256",
	    sidecar, bind.present);
	for (unsigned u = 0; u < BIND_UNITS; ++u)
		if (bind.u[u].present)
			say("  unit %u %s  %u,%u,%u  %s", u, bind.u[u].path,
			    bind.u[u].cylinders, bind.u[u].heads,
			    bind.u[u].blocks_per_track, bind.u[u].sha256);
	char cmd[4096];
	bind_resume_command(&bind, out, cmd, sizeof cmd);
	say("  to open it: %s", cmd);
	// **SAID EVERY TIME, BECAUSE IT IS THE ONE THING NOTHING CHECKS.**
	say("BEFORE RESUMING, check the packs against the digests above ---");
	say("  cadr-checkpoint --verify %s", sidecar);
	say("  or sha256sum on each pack, by hand.");
	say("A pack written since this instant makes the resumed machine hold "
	    "pages that no longer match its disk, and NEITHER muir NOR anything "
	    "in the fabric can see that: the controller recomputes a block's "
	    "header and checkwords as it moves it, so a block from another "
	    "moment passes every check the machine makes.");
	print_missing();

	img_free(&img);
	if (was_running && !leave_halted) {
		ro_start(&r);
		say("the machine is running again");
	} else if (leave_halted) {
		say("the machine is left halted, as asked");
	}
	return 0;
}
