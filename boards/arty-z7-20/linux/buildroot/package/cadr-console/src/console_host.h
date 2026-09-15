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

// --- THE TRACES, WHICH ARE THE WORDS THAT ARE NOT ABOUT THE FABRIC ---------
//
// **`trace-keys on|off` SWITCHES THE TWO INPUT PROGRAMS' TRACES**, and it is
// a word of `cadr-console` because this is the program somebody already has
// open when a key does nothing.  A key's road has two halves --- `cadr-usb-input` turns a key code
// into a keysym, `cadr-terminal` turns a keysym into MIT's own key position
// --- and each says what it did under a trace of its own.  Turning them on
// means finding two daemons and signaling them, which is a thing to type
// once and not twice.
//
// **`trace-chaos on|off` IS THE SAME WORD FOR THE NETWORK**, and it switches
// `cadr-chaosnet`'s packet trace: every frame as it goes by, and every
// datagram refused and why.  It is one program rather than two, and it is
// here for the reason the key trace is --- a link that is quietly refusing
// datagrams is a question somebody asks with the console already open, and
// the alternative is stopping the program to add a flag, which on this board
// means the machine's world has to be booted off the disk again.
//
// **ONE PAIR OF FUNCTIONS SERVES BOTH, AND `what` IS THE ONLY DIFFERENCE.**
// The job is a pid file read and a signal sent, which is the same job
// whichever daemon is being told; naming it after one of the two callers
// would make the second one read as a borrowed function.  `what` is the
// words that go in the line --- `key trace`, `packet trace` --- so that what
// a person is told names the thing they asked about.
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
// --- WHO IS BEING TOLD, WHICH DECIDES WHETHER THE LINE IS BARE ------------
//
// **A REPLY TO A PERSON IS BARE; A LINE WRITTEN TO A LOG CARRIES THE
// PROGRAM'S NAME.**  `say()` puts `cadr-console: ` in front of every line,
// and that prefix exists for the boot log, where five programs write to one
// serial console and a line has to say which of them said it.  At the prompt,
// and in a command typed in a session over ssh, there is nobody else talking:
// the person asked this program, and the name in front of every line of a
// `regs` table is noise between them and the answer.  `ssh board cadr-console
// status` with no terminal is the other case and keeps the prefix, its output
// being a pipe and so on its way into something.
//
// muir's prompt is the reference: its answers carry no program name at all,
// and even the `muir: ` it writes while the machine is held goes only to a
// terminal, "a pipe or a file gets muir's answers alone"
// (`../muir/src/prompt.rs`).
//
// **THE TEST IS THE ONE THE RULE IS ABOUT: IS ANYBODY THERE.**  Standard
// output a terminal means a person is reading it as it comes; a pipe or a
// file means it is being kept, and a line that is kept has to name its
// program.  And `--log PATH` is the same question answered by the caller, so a
// line written through one is prefixed whatever stdout is: that is a log by
// the person's own say-so.
//
// **`/dev/console` IS A TERMINAL AND THE TEST CANNOT TELL IT FROM A PERSON**,
// so an init script that lets these lines into the boot log says which it is:
// `S80cadr-disk-packs` calls `cadr-console --log /dev/console` on the two
// commands whose output it passes through.  A boot log is where six programs
// write and is exactly what the prefix exists for.
//
// It is here rather than in `console_face.c` for the reason the file says at
// its head --- the face is compiled for the Arty A7-100's bare-metal
// firmware, which has a `say()` of its own over a UART and no terminals at
// all.
#define CONS_LOG_PREFIX "cadr-console: "

// The prefix to open the log with: `CONS_LOG_PREFIX`, or "" for a bare reply.
// `logs_named` is how many `--log` destinations were given and
// `stdout_is_a_terminal` is `isatty(1)`; both are read by the caller so that
// this is a decision a check can make without a terminal of its own.
const char *cons_log_prefix(int logs_named, int stdout_is_a_terminal);

#define CONS_TRACE_TERMINAL "cadr-terminal"
#define CONS_TRACE_TERMINAL_PID "/var/run/cadr-terminal.pid"
#define CONS_TRACE_USB "cadr-usb-input"
#define CONS_TRACE_USB_PID "/var/run/cadr-usb-input.pid"
#define CONS_TRACE_CHAOS "cadr-chaosnet"
#define CONS_TRACE_CHAOS_PID "/var/run/cadr-chaosnet.pid"

// What is being traced, in the words the line uses.  The two programs of
// `trace-keys` trace one thing between them and `cadr-chaosnet` another.
#define CONS_TRACE_WHAT_KEYS "key trace"
#define CONS_TRACE_WHAT_CHAOS "packet trace"

enum cons_trace_reached {
	CONS_TRACE_NOT_RUNNING = 0,	/* no pid file, or nothing at that pid */
	CONS_TRACE_SIGNALLED = 1,	/* the signal went */
	CONS_TRACE_REFUSED = -1		/* it is there and would not take it */
};

struct cons_trace {
	const char *program;	/* `cadr-terminal`, for the line */
	const char *pidfile;
	const char *what;	/* `key trace`, `packet trace` */
	long pid;		/* what the file held, or 0 */
	int reached;		/* `enum cons_trace_reached` */
	char why[128];		/* what was wrong, in the system's own words */
};

// One program told to turn a trace on (`on` non-zero) or off.  The result is
// filled in whatever happens; the return is `r->reached`, so that a caller
// may count.  `pidfile` is the board's on the board and the check's own file
// in the host test.
int cons_trace_signal(const char *program, const char *pidfile, const char *what, int on,
		      struct cons_trace *r);
void cons_say_trace(const struct cons_trace *r, int on);

// --- WHICH BUILD THIS PROGRAM IS -----------------------------------------
//
// **A DIFFERENT QUESTION FROM WHICH BUILD THE FABRIC IS**, and both are worth
// having on a board: `status` names the bitstream's commit out of the part's
// own AXSS register, and this names the commit the program in the root
// filesystem was compiled from.  They are served as one set and they can
// still come apart --- a bitstream served without its image, or an image
// built before a rebuild was forced --- and two lines that disagree say so.
//
// **muir's SPELLING, WHICH IS `muir 0.1.0-<commit>-release`.**  muir's
// `build.rs` asks git for the commit and hands it to the compiler, and
// `src/main.rs` reads it with `option_env!` so that a build outside a
// checkout drops the field rather than inventing one.  This does the same
// with a `-D` from the Makefile, and drops the field the same way.
//
// **THE VERSION NUMBER IS `0` AND THAT IS NOT A PLACEHOLDER.**  muir's
// `0.1.0` is cargo's; ours is the Buildroot package's own
// `CADR_CONSOLE_VERSION`, which is 0 because these programs have never been
// released and the commit is what identifies them.  Writing `0.1.0` here to
// make the line look like muir's would be inventing a number, which is the
// one thing this project does not do with numbers.
//
// It is in the HOST half and not the face, because a version is about the
// program and the firmware is a different program: the Arty A7-100's banner
// names the FABRIC's build through `cons_say_build`, and its own build is the
// firmware's business.
const char *cons_version(void);

#endif
