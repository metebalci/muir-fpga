// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One log line at a time, to every destination the program was given, with
// the program's own name in front of it.
//
// Every program on the processing system prints the same way: a prefix, a
// line, a flush, so that a log written to /dev/console interleaves with the
// kernel's own without a half line standing in a buffer when the board is
// power-cycled.  The destinations and the prefix are set once at start-up and
// are file-statics of this library, which is why this is a library and not a
// header of `static inline`s --- `cadr-common.mk`'s header says so at
// length.
//
// **`--log` MAY BE GIVEN MORE THAN ONCE AND EVERY LINE GOES TO EVERY
// DESTINATION NAMED.**  The board's five daemons are started with
// `--log /dev/console --log /var/log/cadr-<program>.log`, so what a program
// says is on the serial console, where a boot is watched, AND in a file,
// where somebody with nothing but ssh can read it and follow it.  Before
// this there was one destination, it was the console, and a key trace
// switched on over ssh went somewhere the person who asked for it could not
// see.
//
// **AND A FILE DESTINATION IS CAPPED, BECAUSE THE ROOT FILESYSTEM IS A RAM
// DISK.**  `/var/log` is a symlink to `/tmp` in this Buildroot skeleton ---
// measured, not assumed --- so a log that grew without bound would eat the
// memory the board runs in and take it down.  `CADR_LOG_MAX` is the cap and
// the rotation below is what holds it.

#ifndef CADR_LOG_H
#define CADR_LOG_H

#include <stdio.h>

// How many destinations `--log` may name.  Two is what the board uses; four
// leaves room for somebody at a prompt adding a file of their own without
// this number becoming a thing to argue about.
#define CADR_LOG_DESTS 4

// **THE CAP ON ONE FILE, AND THE REASON IS THE RAM DISK.**  The root
// filesystem is unpacked into memory at every boot and is a few hundred
// megabytes shared with everything else, `/var/log` being `/tmp` and `/tmp`
// being that same RAM.  A log nobody rotates is therefore a way to take the
// board down, and the board has five of them.  So a file destination that has
// reached this size is renamed to `<name>.1`, replacing any earlier `.1`, and
// a fresh file is started: a program's log holds at most two of these and the
// five programs at most ten times it.  1 MiB, which is some ten thousand of
// these lines --- far more than any of these programs says in a day, and
// small enough that ten of them are nothing beside the root filesystem.
//
// A destination that is not a regular file --- /dev/console, a pipe, a
// terminal --- is never rotated: there is nothing there to grow.
#define CADR_LOG_MAX (1024u * 1024u)

// `--log PATH`, from the option loop.  It may be given more than once.  The
// path is remembered and nothing is opened until `cadr_log_open`, because the
// prefix a failure has to be reported under is not known until the options
// have been read.  The string is used as given and must outlive the program's
// logging, which `argv` does.
void cadr_log_dest(const char *path);

// How many destinations `--log` named.  Zero means the lines are going where
// they would have gone anyway, which is stdout --- `cadr-console` asks so that
// a reply to a person at a terminal can be bare.
unsigned cadr_log_dests(void);

// Set the prefix, open every remembered path for append and make them the
// destinations; with none remembered the destination is stdout.  What
// `cadr_log_dest` remembered is CONSUMED, and any destination this library had
// opened before is closed.  `prefix` is used as given, so it carries its own
// ": ".  Returns 0, or -1 having said on stderr which path could not be opened
// and why, with the prefix in front of it --- a caller that gets -1 has no log
// and should stop.
//
// Both ways of failing need a `--log` to have been given, so the prefix is
// never the empty one `cadr-console` uses for a bare reply at a terminal.
int cadr_log_open(const char *prefix);

// The prefix and ONE destination, replacing any the calls above set up.  The
// prefix string is not copied and must outlive the program's logging, which a
// string literal does; `dest` NULL means stdout.  This is what a test uses to
// catch what a program says in a file of its own, and what a program with no
// `--log` of any kind calls.  The destination is not rotated: this library did
// not open it and does not know its name.
void cadr_log_init(const char *prefix, FILE *dest);

// Where lines go now, so that a program can hand it to something that takes
// a FILE * of its own (the feeder's progress lines do).  **It is the FIRST
// destination and not all of them**, so what is written through it goes to
// one place where `say` goes to every place; there is no way to hand several
// streams to something that takes one.
FILE *cadr_log_file(void);

// A stream of this library's own whose writes reach EVERY destination, for
// something that takes a `FILE *` and writes whole lines of its own --- the
// disk pack program's feeder does.  What goes through it is not given the
// prefix, the caller writing its own lines, and it IS counted against a file
// destination's cap, so nothing escapes the cap by taking this road.  It is
// line-buffered, so a line reaches every destination whole.
FILE *cadr_log_stream(void);

// One line: the prefix, the text, a newline, a flush --- to each destination
// in turn, each rotated first if it is a file that has reached the cap.
void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
