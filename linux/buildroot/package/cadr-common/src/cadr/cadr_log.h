// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One log line at a time, with the program's own name in front of it.
//
// Every program on the processing system prints the same way: a prefix, a
// line, a flush, so that a log written to /dev/console interleaves with the
// kernel's own without a half line standing in a buffer when the board is
// power-cycled.  The destination and the prefix are set once at start-up and
// are file-statics of this library, which is why this is a library and not a
// header of `static inline`s --- `cadr-common.mk`'s header says so at
// length.

#ifndef CADR_LOG_H
#define CADR_LOG_H

#include <stdio.h>

// The prefix and the destination.  `prefix` is used as given, so it carries
// its own ": "; `dest` NULL means stdout.  Called once, before anything is
// said.  The prefix string is not copied and must outlive the program's
// logging, which a string literal does.
void cadr_log_init(const char *prefix, FILE *dest);

// Where lines go now, so that a program can hand it to something that takes
// a FILE * of its own (the feeder's progress lines do).
FILE *cadr_log_file(void);

// One line: the prefix, the text, a newline, a flush.
void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
