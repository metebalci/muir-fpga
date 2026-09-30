// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// quux-file-device: QUUX's file device, the Linux side.
//
//     quux-file-device [--file-root <folder>[,ro]] [--file-root <name>=<folder>[,ro]]...
//                      [--no-guard] [--log <file>]...
//
// QUUX (revision 9 and on) reads and writes files on its host through a file
// device: commands and responses in two rings in its main memory, served
// here from Linux folders as the pathname host HOST.  The machine's
// registers are in the fabric; this program is the device's other half, and
// reaches them through the file device's page (`qfd_face_fabric.c`).  The
// protocol is muir's, and `qfd.h` says how it is held to muir's own device.
//
// **`--file-root` IS muir's FLAG, WITH muir's GRAMMAR.**  `<folder>[,ro]` is
// HOST's `/`; `<name>=<folder>[,ro]`, once for each name, is the top-level
// directory `<name>`, over the default folder's entry of that name.  A value
// is a named mount when the text before its first `=` is a valid component.
// With no default folder `/` holds the mounts alone and is read-only; with no
// `--file-root` at all it is empty.  The board's init script gives the card's
// `sys`, `site` and `home` as three named mounts unless the card says
// otherwise.
//
// **AT THE START, THE TEMPORARY FILES OF A WRITE THAT NEVER CLOSED ARE
// SWEPT.**  A write goes to `.quux-write-...` beside its target and is renamed
// onto it at CLOSE.  A power cut or a killed program leaves one behind, which
// DIRECTORY never shows and nothing would ever remove; so every writable
// mount's folder is walked for them before anything is served.
//
// **LOG's LINES GO TO THIS PROGRAM'S LOG**, which is what the contract calls
// "the server's log": the console and the file under /var/log that
// `cadr_daemon` names, each line `log: ` and the text, as muir prints them.
//
// **THE REAL-TIME CLOCK IS SET HERE TOO**, at the start and at least once a
// second: word 103 is a fabric counter that Linux keeps to its own clock.
//
// There is no interrupt to Linux in this revision of the page, so the loop
// polls: while the device has nothing to do it sleeps a millisecond.

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_board.h>
#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "qfd.h"
#include "qfd_face.h"
#include "qfd_ring.h"

static volatile sig_atomic_t stopping;

static void on_signal(int sig)
{
	(void)sig;
	stopping = 1;
}

static void usage(void)
{
	fprintf(stderr,
"usage: quux-file-device [--file-root <folder>[,ro]] [--file-root <name>=<folder>[,ro]]...\n"
"                        [--no-guard] [--log <file>]...\n"
"\n"
"  --file-root <folder>[,ro]         HOST's /, muir's flag; ,ro makes it read-only\n"
"  --file-root <name>=<folder>[,ro]  the top-level directory <name>; once for each name\n"
"  --no-guard                        skip " CADR_BOARD_TALLY " guard.  Only for a board\n"
"                                    somebody knows to have the fabric loaded.\n"
"  --log <file>                      where to write; may be given more than once\n");
}

static void say_line(void *ctx, const char *line)
{
	(void)ctx;
	say("%s", line);
}

static void say_swept(void *ctx, const char *path)
{
	(void)ctx;
	say("removed a write that never closed: %s", path);
}

int main(int argc, char **argv)
{
	static struct qfd d;
	qfd_init(&d);
	int guard = 1, roots = 0;
	const char *specs[64];
	for (int i = 1; i < argc; ++i) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!strcmp(a, "--file-root") && v) {
			if (roots == 64) {
				fprintf(stderr, "quux-file-device: too many --file-root\n");
				return 2;
			}
			specs[roots++] = argv[++i];
		} else if (!strcmp(a, "--no-guard")) {
			guard = 0;
		} else if (!strcmp(a, "--log") && v) {
			cadr_log_dest(argv[++i]);
		} else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
			usage();
			return 0;
		} else {
			usage();
			return 2;
		}
	}
	if (cadr_log_open("quux-file-device: ") < 0)
		return 1;
	for (int k = 0; k < roots; ++k) {
		char why[512];
		if (qfd_mount_add(&d.mounts, specs[k], why, sizeof why) != 0) {
			say("--file-root %s: %s", specs[k], why);
			return 2;
		}
	}
	qfd_mounts_describe(&d.mounts, say_line, NULL);
	const unsigned swept = qfd_sweep(&d.mounts, say_swept, NULL);
	if (swept)
		say("%u writes that never closed removed", swept);
	d.log = say_line;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	const int fd = cadr_open_mem();
	if (fd < 0)
		return 1;
	if (guard && cadr_guard(fd, "the file device's page") != 0)
		return 1;
	struct qfd_fabric fb = { 0 };
	fb.page = cadr_map(fd, CADR_BOARD_PACK_BASE + QFD_FACE_OFFSET, 4096, "the file device's page");
	if (!fb.page)
		return 1;
	char why[256];
	if (qfd_fabric_attach(&fb, why, sizeof why) != 0) {
		say("%s; not started", why);
		return 1;
	}
	// Main memory: 32-bit words at the CADR's base to revision 12, and on
	// revision 13 packed storage, 5 bytes a word, at its own base below the
	// display (`cadr_board.h`), in a room the board keeps for so many words.
	const uint32_t base = fb.revision_13 ? CADR_BOARD_QUUX13_MAIN_BASE : CADR_BOARD_MAIN_BASE;
	if (fb.revision_13 && fb.mem_words > CADR_BOARD_QUUX13_MAIN_WORDS_MAX) {
		say("the file device's page says main memory is %u words, and this board keeps room for "
		    "%u; not started", fb.mem_words, CADR_BOARD_QUUX13_MAIN_WORDS_MAX);
		return 1;
	}
	volatile void *main_mem = cadr_map(fd, base, (size_t)fb.mem_words * (fb.revision_13 ? 5u : 4u),
					   "the machine's main memory");
	if (!main_mem)
		return 1;
	struct qfd_face face;
	qfd_fabric_face(&fb, main_mem, &face);
	say("serving the file device: revision %s, main memory %u words at 0x%08x%s",
	    fb.revision_13 ? "13" : "9 to 12", fb.mem_words, base,
	    fb.revision_13 ? ", packed storage" : "");

	struct qfd_ring g;
	qfd_ring_init(&g, &d);
	g.say = say_line;
	int failed = 0;
	while (!stopping) {
		struct timespec now;
		clock_gettime(CLOCK_REALTIME, &now);
		qfd_ring_clock(&g, &face, &now);
		const int r = qfd_ring_step(&g, &face);
		if (r < 0) {
			failed = 1;
			break;
		}
		if (r == 0) {
			const struct timespec ms = { 0, 1000000 };
			nanosleep(&ms, NULL);
		}
	}
	// A write still open is discarded, as a disable discards it, and the
	// page is told none are open: the handles went with this program.
	struct qfd_state s;
	face.state(face.ctx, &s);
	qfd_reset(&d);
	face.handles(face.ctx, s.epoch, 0);
	say("stopped");
	return failed;
}
