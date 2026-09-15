// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The logging; `cadr/cadr_log.h` says what it is for.

// `fileno`, and `fopencookie` with its `cookie_io_functions_t`, which glibc
// puts behind `__USE_MISC`.  `-std=gnu11` happens to turn that on and
// `-std=c11` does not, so it is asked for here rather than left to whichever
// flag a build was given; `serial_endpoint.c` does the same for the same
// reason.  It must stand before the first include.
#define _GNU_SOURCE

#include "cadr/cadr_log.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

// A path long enough that `<path>.1` does not fit is not rotated, and says so
// once rather than half-renaming something.  Nothing on the card is anywhere
// near this; the branch exists because a cap that silently stopped applying
// would be worse than one that was never there.
#define LOG_PATH 256

struct dest {
	FILE *f;
	const char *path;	/* NULL when this library did not open it */
	int rotate;		/* a regular file: the only kind that grows */
	long size;		/* what it holds now, from ftell after a flush */
};

static const char *log_prefix = "";
static struct dest dests[CADR_LOG_DESTS];
static unsigned ndests;

// Let go of everything this library opened, so that a second `cadr_log_open`
// or a `cadr_log_init` does not leave a file open with nothing pointing at
// it.  A stream this library did NOT open is the caller's --- stdout, a
// test's memory stream --- and is left alone.
static void close_ours(void)
{
	for (unsigned k = 0; k < ndests; ++k)
		if (dests[k].path && dests[k].f)
			fclose(dests[k].f);
	ndests = 0;
}

// What `--log` named, before anything is opened.
static const char *wanted[CADR_LOG_DESTS];
static unsigned nwanted;
static int too_many;

void cadr_log_dest(const char *path)
{
	if (!path)
		return;
	if (nwanted >= CADR_LOG_DESTS) {
		// Not said here: the prefix it would be said under is not set
		// until cadr_log_open, which is where every other way of
		// failing to open a log is reported.
		too_many = 1;
		return;
	}
	wanted[nwanted++] = path;
}

unsigned cadr_log_dests(void)
{
	return nwanted;
}

// One destination from a stream this library opened, or from a stream it did
// not.  A regular file is the only thing that grows, so a `fstat` decides
// whether the cap applies rather than the name: /dev/console is a character
// device and a pipe is a pipe, and neither has a size to cap.
static void add(FILE *f, const char *path)
{
	struct dest *d = &dests[ndests++];
	struct stat st;
	d->f = f;
	d->path = path;
	d->rotate = 0;
	d->size = 0;
	setvbuf(f, NULL, _IOLBF, 0);
	if (!path)
		return;
	if (fstat(fileno(f), &st) == 0 && S_ISREG(st.st_mode)) {
		const long at = ftell(f);
		if (strlen(path) + 2 < LOG_PATH) {
			d->rotate = 1;
			d->size = at < 0 ? 0 : at;
		} else {
			fprintf(stderr, "%s%s: this path is too long for a `.1` "
				"beside it, so the file is not capped\n",
				log_prefix, path);
		}
	}
}

int cadr_log_open(const char *prefix)
{
	// **WHAT WAS NAMED IS CONSUMED HERE.**  Opening is the end of the
	// option loop's business, so the remembered paths are let go of and a
	// caller that reads options again starts from nothing rather than
	// opening the first set twice.
	const unsigned n = nwanted;
	const int over = too_many;
	nwanted = 0;
	too_many = 0;
	log_prefix = prefix ? prefix : "";
	close_ours();
	if (over) {
		fprintf(stderr, "%s--log may name at most %d destinations\n",
			log_prefix, CADR_LOG_DESTS);
		return -1;
	}
	if (n == 0) {
		add(stdout, NULL);
		return 0;
	}
	for (unsigned k = 0; k < n; ++k) {
		// Append and never truncate.  A log is a log: a program
		// restarted by hand must not take away what the one before it
		// said, and the cap below is what keeps that from growing.
		FILE *f = fopen(wanted[k], "a");
		if (!f) {
			fprintf(stderr, "%s%s: %s\n", log_prefix, wanted[k],
				strerror(errno));
			return -1;
		}
		add(f, wanted[k]);
	}
	return 0;
}

void cadr_log_init(const char *prefix, FILE *dest)
{
	log_prefix = prefix ? prefix : "";
	close_ours();
	add(dest ? dest : stdout, NULL);
}

FILE *cadr_log_file(void)
{
	// A program that says something before it has chosen writes to stdout,
	// which is what it would have got anyway.
	return ndests ? dests[0].f : stdout;
}

// **THE CAP, APPLIED BEFORE THE LINE AND NOT AFTER IT.**  A file that has
// reached CADR_LOG_MAX is renamed to `<name>.1` --- `rename` replaces any
// earlier `.1`, so there is never a third generation --- and a fresh file is
// opened in its place.  So a file holds the cap plus the one line that
// reached it, and a program's log is never more than twice that.
static void rotate(struct dest *d)
{
	char one[LOG_PATH];
	FILE *f;
	const int n = snprintf(one, sizeof one, "%s.1", d->path);
	if (n < 0 || (size_t)n >= sizeof one) {
		d->rotate = 0;
		return;
	}
	fclose(d->f);
	// A rename that fails leaves the file where it is; reopening it for
	// append then puts the next line back on the end of a file at the cap
	// and this runs again at the next line, which is a log that does not
	// rotate rather than a log that is lost.
	rename(d->path, one);
	f = fopen(d->path, "a");
	if (!f) {
		// The destination is gone --- the directory removed under it,
		// or the disk full.  Drop it rather than write through a
		// closed stream, and say so where the others can still say it.
		fprintf(stderr, "%s%s: %s\n", log_prefix, d->path, strerror(errno));
		d->f = NULL;
		d->rotate = 0;
		return;
	}
	setvbuf(f, NULL, _IOLBF, 0);
	d->f = f;
	// **AND THIS LINE IS ONLY FOR THE CASE WHERE `ftell` FAILS**, which on
	// a regular file it does not: `say_to` reads the size back out of the
	// file after every line, so on any board this is written over before
	// it is next looked at.  Measured as a mutation and recorded as an
	// equivalence in `console_mutations.txt`'s place --- what it buys is
	// that a destination whose `ftell` started failing stops rotating
	// rather than renaming itself once a line for ever.
	d->size = 0;
}

// Bytes straight to one destination, the cap applied first.  This is what
// `say` and the fan-out stream below share: everything that reaches a log goes
// through one of these two and so is counted against the cap.
static void bytes_to(struct dest *d, const char *buf, size_t n)
{
	long at;
	if (d->rotate && d->size >= (long)CADR_LOG_MAX)
		rotate(d);
	if (!d->f)
		return;
	fwrite(buf, 1, n, d->f);
	fflush(d->f);
	if (d->rotate && (at = ftell(d->f)) >= 0)
		d->size = at;
}

static void say_to(struct dest *d, const char *fmt, va_list ap)
{
	long at;
	if (d->rotate && d->size >= (long)CADR_LOG_MAX)
		rotate(d);
	if (!d->f)
		return;
	fputs(log_prefix, d->f);
	vfprintf(d->f, fmt, ap);
	fputc('\n', d->f);
	fflush(d->f);
	if (d->rotate && (at = ftell(d->f)) >= 0)
		d->size = at;
}

void say(const char *fmt, ...)
{
	if (!ndests)
		cadr_log_init(log_prefix, NULL);
	for (unsigned k = 0; k < ndests; ++k) {
		va_list ap;
		va_start(ap, fmt);
		say_to(&dests[k], fmt, ap);
		va_end(ap);
	}
}

// **A `FILE *` OF THIS LIBRARY'S OWN THAT REACHES EVERY DESTINATION.**  The
// disk pack program's feeder is handed a stream and writes whole lines of its
// own through it --- eighteen of them, the denied block among them --- and
// handing it `cadr_log_file()` would put those lines on the console and NOT in
// the file somebody over ssh is reading, which is the whole point of there
// being two.  `cadr/cadr_log.h` states what it is and is not.
//
// `fopencookie` is glibc's; the board's image is glibc and so is the build
// host, both measured.  Somewhere without it the stream is the first
// destination, which is what a caller got before this existed.
#ifdef __GLIBC__
static FILE *fan;

static ssize_t fan_write(void *cookie, const char *buf, size_t n)
{
	(void)cookie;
	if (!ndests)
		cadr_log_init(log_prefix, NULL);
	for (unsigned k = 0; k < ndests; ++k)
		bytes_to(&dests[k], buf, n);
	return (ssize_t)n;
}
#endif

FILE *cadr_log_stream(void)
{
#ifdef __GLIBC__
	if (!fan) {
		static const cookie_io_functions_t io = {
			NULL, fan_write, NULL, NULL
		};
		fan = fopencookie(NULL, "w", io);
		// A line at a time, so that a whole line reaches every
		// destination before the cap can rotate one of them: rotating
		// inside a line would leave half of it in each file.
		if (fan)
			setvbuf(fan, NULL, _IOLBF, 0);
	}
	if (fan)
		return fan;
#endif
	return cadr_log_file();
}
