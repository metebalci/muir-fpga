// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet program, held on the build host to muir: no board, no fabric,
// no Chaosnet --- nothing but a C compiler, a scratch directory and a
// loopback socket.
//
//     chaos_test [--work DIR]
//
// **WHAT IT IS FOR.**  This program is the other half of a machine that has
// booted MIT's Lisp Machine system, and the half it is joined to is in
// fabric.  Nothing here can reach that fabric, so what is held is everything
// that is NOT the fabric: the packet's layout and its check word, the
// transport of AIM-628 chapters 3 and 4, the four services, CHUDP's frame,
// and the register face against a model of the RTL written to
// `chaos_face.h`'s own table.
//
// **EACH SUITE IS ITS OWN TRANSLATION UNIT AND THIS FILE ONLY CALLS THEM.**
// A mutation aimed at one piece is then caught by the suite that exists for
// it rather than by whichever check happens to run first, which is what makes
// the mutation list's verdicts mean anything.
//
// The order is the order the layers stack: a packet before the transport that
// carries it, the transport before the services that answer on it, then the
// two ways a packet leaves this process.

#include "chaos_test.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

int chaos_test_bad;
unsigned chaos_test_checks;

// Where scratch trees go.  `~/.cache` and not `/tmp`, which is a RAM disk on
// this build host --- a rule this project has written down after filling one.
static char work_root[512];

void chaos_test_fail(const char *file, int line, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "%s:%d: FAIL: ", file, line);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++chaos_test_bad;
	if (chaos_test_bad > 40) {
		fprintf(stderr, "FAIL: too many; stopping\n");
		exit(1);
	}
}

void chaos_test_note(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	putchar('\n');
	va_end(ap);
	fflush(stdout);
}

static void wipe(const char *path)
{
	// No `rm -rf` by hand: the scratch tree is small and this is the one
	// place the check touches the filesystem outside its own root.
	char cmd[1024];
	snprintf(cmd, sizeof cmd, "rm -rf '%s'", path);
	if (system(cmd) != 0)
		fprintf(stderr, "chaos_test: could not clear %s\n", path);
}

const char *chaos_test_work_root(void)
{
	return work_root;
}

const char *chaos_test_scratch(const char *leaf)
{
	static char path[768];
	snprintf(path, sizeof path, "%s/%s", work_root, leaf);
	wipe(path);
	if (mkdir(path, 0755) != 0 && access(path, W_OK) != 0) {
		fprintf(stderr, "chaos_test: cannot make %s\n", path);
		exit(1);
	}
	return path;
}

int main(int argc, char **argv)
{
	const char *home = getenv("HOME");
	snprintf(work_root, sizeof work_root, "%s/.cache/muir-fpga-chaosnet",
		 home ? home : ".");
	for (int i = 1; i < argc; ++i) {
		if (!strcmp(argv[i], "--work") && i + 1 < argc)
			snprintf(work_root, sizeof work_root, "%s", argv[++i]);
		else {
			fprintf(stderr, "usage: chaos_test [--work DIR]\n");
			return 2;
		}
	}
	{
		char cmd[1024];
		snprintf(cmd, sizeof cmd, "mkdir -p '%s'", work_root);
		if (system(cmd) != 0) {
			fprintf(stderr, "chaos_test: cannot make %s\n", work_root);
			return 1;
		}
	}
	// The suites say what they are doing; the library they share prints
	// through `say`, and its lines belong beside theirs.
	cadr_log_init("chaos_test: ", stdout);

	chaos_test_note("chaos_test: scratch under %s", work_root);
	chaos_test_note("-- the packet: its words, its frame and its check word");
	chaos_test_packet();
	chaos_test_note("-- the transport, and the STATUS, TIME and UPTIME services");
	chaos_test_ncp();
	chaos_test_note("-- the FILE service, against a real directory");
	chaos_test_file();
	chaos_test_note("-- the register face, against a model of the fabric");
	chaos_test_face();
	chaos_test_note("-- Chaosnet over UDP, on a loopback socket");
	chaos_test_udp();

	printf("chaos_test: %u checks, %d failed\n", chaos_test_checks, chaos_test_bad);
	return chaos_test_bad ? 1 : 0;
}
