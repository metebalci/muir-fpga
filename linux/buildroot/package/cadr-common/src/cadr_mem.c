// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// /dev/mem and the EMIO tally guard; `cadr/cadr_mem.h` says why the guard is
// the first thing any of these programs does.

#include "cadr/cadr_mem.h"
#include "cadr/cadr_log.h"

#include <errno.h>
#include <fcntl.h>
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

int cadr_tally_ok(uint32_t w2, uint32_t w3)
{
	return (w2 & CADR_TALLY_MASK) == CADR_TALLY_MARK
	    && (w3 & CADR_TALLY_MASK) == CADR_TALLY_MARK;
}

int cadr_guard(int fd, const char *port)
{
	volatile uint32_t *gpio = cadr_map(fd, CADR_GPIO_BASE, 4096, "the GPIO block");
	if (!gpio)
		return -1;
	const uint32_t w2 = gpio[CADR_GPIO_DATA2_RO / 4], w3 = gpio[CADR_GPIO_DATA3_RO / 4];
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
