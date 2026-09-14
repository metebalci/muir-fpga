// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The firmware's floor: the UART, the clock, `say()`, and the two POSIX calls
// the shared drivers make that a board with no filesystem has to answer.

#include "soc.h"

#include <cadr/cadr_log.h>

#include <stdarg.h>
#include <stdio.h>

// ---------------------------------------------------------------- the UART

void soc_putc(char c)
{
	// **A NEWLINE GOES OUT AS A CARRIAGE RETURN AND A NEWLINE**, because
	// the other end of this wire is a terminal program and not a tty
	// driver: there is no line discipline on a board to do it.
	if (c == '\n')
		soc_putc('\r');
	while (!(soc_rd(SOC_UART_BASE + SOC_UART_R_STAT) & SOC_UART_TX_READY))
		;
	soc_wr(SOC_UART_BASE + SOC_UART_R_TX, (uint32_t)(unsigned char)c);
}

int soc_getc(void)
{
	uint32_t w = soc_rd(SOC_UART_BASE + SOC_UART_R_RX);
	if (!(w & SOC_UART_RX_HAS))
		return -1;
	return (int)(w & 0xFFu);
}

// --------------------------------------------------------------- the clock

uint64_t soc_ticks(void)
{
	// Low word first: the fabric latches the high word beside it, so the
	// pair names one instant across a carry.  Reading the high word first
	// would give a time 4,294,967,296 ticks away every 43 seconds.
	uint32_t lo = soc_rd(SOC_TIMER_BASE + SOC_TIMER_R_MTIME_LO);
	uint32_t hi = soc_rd(SOC_TIMER_BASE + SOC_TIMER_R_MTIME_HI);
	return ((uint64_t)hi << 32) | lo;
}

uint32_t soc_ticks_per_us(void)
{
	return soc_rd(SOC_TIMER_BASE + SOC_TIMER_R_TICKS_PER_US);
}

void soc_delay_us(unsigned us)
{
	uint64_t until = soc_ticks() + (uint64_t)us * soc_ticks_per_us();
	while (soc_ticks() < until)
		;
}

// ------------------------------------------------------- stdout and `say()`

static int soc_stdio_put(char c, FILE *f)
{
	(void)f;
	soc_putc(c);
	return (unsigned char)c;
}

// picolibc's stdio wants a stream; this is the whole of it, and it is
// write-only because a firmware that read from `stdin` would be blocking on a
// person.
static FILE soc_stdout_file =
	FDEV_SETUP_STREAM(soc_stdio_put, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &soc_stdout_file;

static const char *log_prefix = "";

void cadr_log_init(const char *prefix, FILE *dest)
{
	(void)dest;
	log_prefix = prefix ? prefix : "";
}

void say(const char *fmt, ...)
{
	va_list ap;
	fputs(log_prefix, stdout);
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	soc_putc('\n');
}

// ------------------------------------------------- the two POSIX calls
//
// `console_face.c`'s `cons_held` and `cons_release_held` ask whether a marker
// file exists.  **THE MARKER IS A LINUX ARRANGEMENT AND THERE IS NO FILESYSTEM
// HERE**: on the Arty Z7-20 an init step writes `/var/run/cadr-held` when
// `--no-auto-boot` is in `fpgarc`, and this board's equivalent is SW0, which
// the console reports in STAT's own bits 4 and 5 and which needs no file at
// all.  So `access` says nothing is there and `unlink` succeeds at removing
// nothing, which makes `cons_held` false and `cons_release_held` a no-op ---
// the ordinary case on the other board too.
//
// **THEY ARE STUBS THAT ANSWER RATHER THAN STUBS THAT FAIL**, and the
// difference matters: a firmware that trapped here would be a firmware that
// could not call a shared function it otherwise compiles.
int access(const char *path, int mode);
int unlink(const char *path);

int access(const char *path, int mode)
{
	(void)path;
	(void)mode;
	return -1;		/* nothing is there */
}

int unlink(const char *path)
{
	(void)path;
	return 0;		/* and removing nothing succeeded */
}
