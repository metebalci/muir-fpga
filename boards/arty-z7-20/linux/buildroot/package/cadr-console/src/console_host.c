// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console's host half: the words that are not cycles on the diagnostic
// bus.  `console_host.h` says why they are not in `console_face.c`, which is
// compiled for the Arty A7-100's bare-metal firmware as well as for Linux.

#include "console_host.h"

#include <cadr/cadr_log.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *cons_log_prefix(int logs_named, int stdout_is_a_terminal)
{
	// The header has the rule.  A `--log` wins over the terminal: the
	// caller has said where the lines are being kept, and a kept line
	// names its program.
	return (logs_named == 0 && stdout_is_a_terminal) ? "" : CONS_LOG_PREFIX;
}

int cons_trace_keys(const char *program, const char *pidfile, int on,
		    struct cons_trace_keys *r)
{
	memset(r, 0, sizeof *r);
	r->program = program;
	r->pidfile = pidfile;
	r->reached = CONS_TRACE_NOT_RUNNING;

	FILE *f = fopen(pidfile, "r");
	if (!f) {
		snprintf(r->why, sizeof r->why, "%s", strerror(errno));
		return r->reached;
	}
	char line[64];
	const char *got = fgets(line, sizeof line, f);
	fclose(f);
	if (!got) {
		snprintf(r->why, sizeof r->why, "the file is empty");
		return r->reached;
	}
	char *end = NULL;
	const long pid = strtol(line, &end, 10);
	// **NOTHING BUT A WHOLE NUMBER OF AT LEAST 1.**  See the header: 0 and
	// a negative signal a process GROUP, so a pid file that says either is
	// refused rather than acted on.  `strtol` stopping at the first
	// non-digit is not enough by itself --- `0x` and an empty line both
	// give 0 --- so the value is what is tested.
	if (end == line || pid < 1) {
		snprintf(r->why, sizeof r->why,
			 "the file does not hold a process id (%.32s)", line);
		return r->reached;
	}
	r->pid = pid;
	if (kill((pid_t)pid, on ? SIGUSR1 : SIGUSR2) == 0) {
		r->reached = CONS_TRACE_SIGNALLED;
		return r->reached;
	}
	// ESRCH is a pid file left behind by a program that has gone, which is
	// the ordinary case and is not an error worth alarming anybody with;
	// anything else is the system's own word for why.
	snprintf(r->why, sizeof r->why, "%s", strerror(errno));
	r->reached = errno == ESRCH ? CONS_TRACE_NOT_RUNNING : CONS_TRACE_REFUSED;
	return r->reached;
}

void cons_say_trace_keys(const struct cons_trace_keys *r, int on)
{
	switch (r->reached) {
	case CONS_TRACE_SIGNALLED:
		say("trace-keys: %s (pid %ld) was told to turn its key trace %s; what it "
		    "traces goes to its own log, which on this board is the serial console "
		    "and /var/log/%s.log --- `tail -F` that file to follow it over ssh",
		    r->program, r->pid, on ? "ON" : "off", r->program);
		break;
	case CONS_TRACE_REFUSED:
		say("trace-keys: %s (pid %ld) would not take the signal: %s",
		    r->program, r->pid, r->why);
		break;
	default:
		say("trace-keys: %s is not running (%s: %s)", r->program, r->pidfile, r->why);
		break;
	}
}
