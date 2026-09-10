// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The logging; `cadr/cadr_log.h` says what it is for.

#include "cadr/cadr_log.h"

#include <stdarg.h>

static const char *log_prefix = "";
static FILE *logf;

void cadr_log_init(const char *prefix, FILE *dest)
{
	log_prefix = prefix ? prefix : "";
	logf = dest ? dest : stdout;
	setvbuf(logf, NULL, _IOLBF, 0);
}

FILE *cadr_log_file(void)
{
	// A program that says something before it has chosen writes to stdout,
	// which is what it would have got anyway.
	return logf ? logf : stdout;
}

void say(const char *fmt, ...)
{
	FILE *f = cadr_log_file();
	va_list ap;
	va_start(ap, fmt);
	fputs(log_prefix, f);
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	va_end(ap);
	fflush(f);
}
