// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE CONSOLE'S HOST HALF: THE WORDS THAT NEED AN OPERATING SYSTEM UNDER
// THEM.**
//
// `console_face.h` and `console_face.c` are the diagnostic register face, and
// they are compiled TWICE.  Once for Linux, on the Arty Z7-20 and the Cora;
// and once by `boards/arty-a7-100/firmware/`, for an Ibex core with picolibc
// and no kernel at all.  Everything in them is a cycle on the bus and means
// the same thing on both machines.
//
// This pair is the other half: what `cadr-console` does that is not about the
// fabric, and so asks an operating system for something.  The front end and
// `console_test.c` compile it; the firmware's own rules in the top-level
// Makefile name `console_face.c` and not this file, so a word that needs a
// kernel cannot reach the firmware's link by accident.
//
// **THAT SEPARATION IS NOT TIDINESS, IT IS A MEASUREMENT.**  `trace-keys` was
// written into `console_face.c` and the firmware stopped linking the same
// day: `fopen` alone drags picolibc's stdio in, which wants `open`, `close`,
// `read`, `write` and `lseek`, and `sbrk` wants a `__heap_end` this firmware
// has not got.  Nothing called the new function --- it was enough that it was
// in the object file.  So a check on the rule is cheap and exists:
// `make build/soc.pass` builds this firmware, and it is the thing that says
// the face file is still a face file.

#ifndef CONSOLE_HOST_H
#define CONSOLE_HOST_H

// --- THE KEY TRACE, WHICH IS THE ONE WORD THAT IS NOT ABOUT THE FABRIC -----
//
// **`trace-keys on|off` SWITCHES THE TWO INPUT PROGRAMS' TRACES**, and it is
// a word of `cadr-console` because this is the program somebody already has
// open when a key does nothing.  A key's road has two halves --- `cadr-usb-input` turns a key code
// into a keysym, `cadr-terminal` turns a keysym into MIT's own key position
// --- and each says what it did under a trace of its own.  Turning them on
// means finding two daemons and signalling them, which is a thing to type
// once and not twice.
//
// **IT TOUCHES NO REGISTER AND NEEDS NO BITSTREAM.**  Every other word the
// console has is a cycle on the diagnostic bus; this one reads a pid file
// and calls `kill`.  So `cadr-console trace-keys on` works on a board whose fabric has
// no console in it at all, and the program does it before the guard rather
// than after --- a word that cannot touch M_AXI_GP1 must not be stopped by a
// window that does not answer.
//
// **THE SIGNALS ARE SIGUSR1 AND SIGUSR2**, on and off, because that is what a
// program with no control socket has: both programs install handlers that do
// nothing but set a flag, act on it once a pass of their own loop, and say
// one line when it CHANGES, so a second `on` is silent rather than confusing.
//
// **A PID FILE IS READ AND NEVER GUESSED AT**, and the pid is REFUSED unless
// it is at least 1: `kill(0, SIGUSR1)` signals the whole process group ---
// this program's own shell, and whatever else is in it --- and a negative pid
// signals a group by number.  A pid file holding `0` is a `start-stop-daemon`
// that wrote nothing useful, not an instruction to signal everybody.
#define CONS_TRACE_TERMINAL "cadr-terminal"
#define CONS_TRACE_TERMINAL_PID "/var/run/cadr-terminal.pid"
#define CONS_TRACE_USB "cadr-usb-input"
#define CONS_TRACE_USB_PID "/var/run/cadr-usb-input.pid"

enum cons_trace_reached {
	CONS_TRACE_NOT_RUNNING = 0,	/* no pid file, or nothing at that pid */
	CONS_TRACE_SIGNALLED = 1,	/* the signal went */
	CONS_TRACE_REFUSED = -1		/* it is there and would not take it */
};

struct cons_trace_keys {
	const char *program;	/* `cadr-terminal`, for the line */
	const char *pidfile;
	long pid;		/* what the file held, or 0 */
	int reached;		/* `enum cons_trace_reached` */
	char why[128];		/* what was wrong, in the system's own words */
};

// One program told to turn its trace on (`on` non-zero) or off.  The result
// is filled in whatever happens; the return is `r->reached`, so that a caller
// may count.  `pidfile` is the board's on the board and the check's own file
// in the host test.
int cons_trace_keys(const char *program, const char *pidfile, int on,
		    struct cons_trace_keys *r);
void cons_say_trace_keys(const struct cons_trace_keys *r, int on);

#endif
