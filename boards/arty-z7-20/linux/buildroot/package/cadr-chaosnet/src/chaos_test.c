// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet program, held on the build host to muir: no board, no fabric,
// no Chaosnet --- nothing but a C compiler and a loopback socket.
//
//     chaos_test
//
// **WHAT IT IS FOR.**  This program is the cable the CADR's Chaosnet
// interface is plugged into, and the interface itself is in fabric.  Nothing
// here can reach that fabric, so what is held is everything that is NOT the
// fabric: the packet's layout and its check word, CHUDP's frame, and the
// register face against a model of the RTL written to `chaos_face.h`'s own
// table.
//
// **THERE IS NO TRANSPORT AND THERE ARE NO SERVICES TO CHECK.**  A CADR has
// no file or time server in it, muir removed its own at `79c7590`, and this
// program never should have had them.  The suites for the connection
// protocol and for STATUS, TIME, UPTIME and FILE went with the code they
// were written for.  Nothing here touches the filesystem any more.
//
// **EACH SUITE IS ITS OWN TRANSLATION UNIT AND THIS FILE ONLY CALLS THEM.**
// A mutation aimed at one piece is then caught by the suite that exists for
// it rather than by whichever check happens to run first, which is what makes
// the mutation list's verdicts mean anything.
//
// The order is the order the layers stack: a packet, then the two ways a
// packet leaves this process.

#include "chaos_test.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cadr/cadr_log.h>

int chaos_test_bad;
unsigned chaos_test_checks;

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

int main(int argc, char **argv)
{
	if (argc > 1) {
		fprintf(stderr, "usage: chaos_test\n");
		return 2;
	}
	(void)argv;
	// The suites say what they are doing; the library they share prints
	// through `say`, and its lines belong beside theirs.
	cadr_log_init("chaos_test: ", stdout);

	chaos_test_note("-- the packet: its words, its frame and its check word");
	chaos_test_packet();
	chaos_test_note("-- the register face, against a model of the fabric");
	chaos_test_face();
	chaos_test_note("-- Chaosnet over UDP, on a loopback socket");
	chaos_test_udp();

	printf("chaos_test: %u checks, %d failed\n", chaos_test_checks, chaos_test_bad);
	return chaos_test_bad ? 1 : 0;
}
