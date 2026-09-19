// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// /dev/mem and the EMIO tally guard; `cadr/cadr_mem.h` says why the guard is
// the first thing any of these programs does.

#include "cadr/cadr_mem.h"
#include "cadr/cadr_log.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int cadr_open_mem(void)
{
	const int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0)
		say("/dev/mem: %s", strerror(errno));
	return fd;
}

void *cadr_map(int fd, uint32_t phys, size_t bytes, const char *what)
{
	void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	if (p == MAP_FAILED) {
		say("mapping %s at 0x%08x: %s", what, phys, strerror(errno));
		return NULL;
	}
	return p;
}

int cadr_parse_u32(const char *what, const char *s, uint32_t *out)
{
	// A digit first: strtoull would take leading blanks and a sign, and
	// "-1" is 0xFFFF...F to it.
	if (!s || s[0] < '0' || s[0] > '9') {
		say("%s: \"%s\" is not a number", what, s ? s : "");
		return -1;
	}
	char *end = NULL;
	errno = 0;
	const unsigned long long v = strtoull(s, &end, 0);
	if (errno || !end || *end != '\0') {
		say("%s: \"%s\" is not a number", what, s);
		return -1;
	}
	if (v > 0xFFFFFFFFull) {
		say("%s: %s does not fit in 32 bits", what, s);
		return -1;
	}
	*out = (uint32_t)v;
	return 0;
}

int cadr_tally_ok(uint32_t w2, uint32_t w3)
{
	return (w2 & CADR_TALLY_MASK) == CADR_TALLY_MARK
	    && (w3 & CADR_TALLY_MASK) == CADR_TALLY_MARK;
}

#if CADR_BOARD_TALLY_WORDS == 2

// The Zynq-7000 boards: the EMIO tally, two words of the GPIO block.
int cadr_guard(int fd, const char *port)
{
	volatile uint32_t *gpio = cadr_map(fd, CADR_BOARD_TALLY_PAGE, 4096, "the GPIO block");
	if (!gpio)
		return -1;
	const uint32_t w2 = gpio[CADR_BOARD_TALLY_OFF0 / 4], w3 = gpio[CADR_BOARD_TALLY_OFF1 / 4];
	munmap((void *)gpio, 4096);
	if (cadr_tally_ok(w2, w3)) {
		say("the EMIO tally reads 0x%08x 0x%08x: a fabric with the processing system in it; %s may be read",
		    w2, w3, port);
		return 0;
	}
	if (w2 == 0 && w3 == 0)
		say("the EMIO tally reads zero twice: either the GPIO block's clock is gated (APER_CLK_CTRL bit 22) or there is no instrument; "
		    "not touching %s, which would hang the processor on a bitstream without the processing system", port);
	else
		say("the EMIO tally reads 0x%08x 0x%08x, not the marker bits of a bitstream with the processing system in it; "
		    "not touching %s, which would hang the processor (--no-guard overrides)", w2, w3, port);
	return -1;
}

#elif CADR_BOARD_TALLY_WORDS == 1

// The DE25-Nano: one word of the tally, on `h2f_gp_in`, which the system
// manager's GPI register reports.  The system manager is the processor's own
// and answers whatever the fabric holds, so this read cannot hang; the words
// that can are the bridges', which is why it comes first.  The marker test is
// the Zynq boards', asked of the one word as of both halves.
int cadr_guard(int fd, const char *port)
{
	volatile uint32_t *sysmgr = cadr_map(fd, CADR_BOARD_TALLY_PAGE, 4096, "the system manager");
	if (!sysmgr)
		return -1;
	const uint32_t w = sysmgr[CADR_BOARD_TALLY_OFF0 / 4];
	munmap((void *)sysmgr, 4096);
	if (cadr_tally_ok(w, w)) {
		say("the GPI tally reads 0x%08x: a fabric with the CADR's tally on h2f_gp_in; %s may be read",
		    w, port);
		return 0;
	}
	if (w == 0)
		say("the GPI tally reads zero: nothing in the fabric drives h2f_gp_in, or no fabric is loaded; "
		    "not touching %s, which may hang the processor (--no-guard overrides)", port);
	else
		say("the GPI tally reads 0x%08x, not the marker bits of a fabric with the CADR's tally in it; "
		    "not touching %s, which may hang the processor (--no-guard overrides)", w, port);
	return -1;
}

#else
#error "cadr_mem.c: the board's tally is neither one word nor two"
#endif
