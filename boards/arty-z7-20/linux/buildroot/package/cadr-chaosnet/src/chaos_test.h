// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The check's harness: what every suite in `chaos_test_*.c` shares.
//
// The whole check runs on the build host with no board and no fabric ---
// nothing but a C compiler, a temporary directory and a loopback socket ---
// which is the shape `feeder_test.c` and `screen_test.c` use and the reason
// this program can be held to muir at all.
//
// **EACH SUITE IS ITS OWN TRANSLATION UNIT** so that the pieces can be
// written and read separately, and so that a mutation aimed at one of them is
// caught by the suite that exists for it rather than by whatever happens to
// run first.  `chaos_test.c` calls them in order and reports the totals.

#ifndef CHAOS_TEST_H
#define CHAOS_TEST_H

#include <stdarg.h>

extern int chaos_test_bad;
extern unsigned chaos_test_checks;

void chaos_test_fail(const char *file, int line, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

#define CHECK(cond, ...)                                             \
	do {                                                         \
		++chaos_test_checks;                                 \
		if (!(cond))                                         \
			chaos_test_fail(__FILE__, __LINE__, __VA_ARGS__); \
	} while (0)

// A line of progress, printed with the suite's name in front of it, so that a
// check that hangs says where it got to.
void chaos_test_note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// A scratch directory under the work root, made and emptied, whose path the
// caller must not free.
const char *chaos_test_scratch(const char *leaf);

// The work root itself, which `--work` names.  A suite needing a tree it can
// put things BESIDE --- the FILE service's containment checks want two
// directories outside the served root, one linked at the root and one deeper
// --- makes its own under this rather than reaching for `$HOME`.  **That is
// not tidiness: `mutate.py` gives every mutant its own `--work`, and a suite
// that ignores it writes into the baseline's tree.**  This project has the
// same failure recorded twice over one shared cargo target directory, where
// three mutations were reported caught on one mutation's evidence.
const char *chaos_test_work_root(void);

// The suites.  Each returns having called CHECK as many times as it likes;
// the totals are the harness's.
void chaos_test_packet(void);
void chaos_test_ncp(void);
void chaos_test_udp(void);
void chaos_test_face(void);
void chaos_test_file(void);

#endif
