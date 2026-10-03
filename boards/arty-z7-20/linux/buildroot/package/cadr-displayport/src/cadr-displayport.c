// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-displayport: the Kria KR260's DisplayPort link, for the display
// output in the fabric.
//
//     cadr-displayport [--log <path>] [--no-guard]   the daemon, from S83cadr-displayport
//     cadr-displayport --status                      what the link and the monitor say, and exit
//     cadr-displayport --crc                         the monitor's frame CRC and the
//                                                    controller's, a few times, and exit
//
// `dp_link.h` is the account of what it does and why.  This file is the
// board's side of the seam --- /dev/mem behind `struct dp_io` --- and the
// loop: every tenth of a second the console's word 36 is read and the keeper
// takes one step.
//
// **THE CONSOLE IS ASKED FIRST, BEFORE ANY REGISTER OF THE CONTROLLER.**  The
// keeper follows the display output's mute, which is word 36 of the console's
// page in the fabric; a fabric whose console does not answer, or whose word
// 36 does not carry the display output's marker, is not one with a display
// output, and the program says so and stops.

#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_board.h>
#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "dp_link.h"

#ifndef CADR_BOARD_KR260
#error "cadr-displayport is the Kria KR260's: build it with CADR_BOARD_KR260"
#endif

struct board_ctx {
	volatile uint32_t *ctrl, *serdes, *console;
};

static uint32_t b_rd(struct dp_io *io, enum dp_space s, uint32_t off)
{
	const struct board_ctx *c = io->ctx;
	switch (s) {
	case DP_CTRL: return c->ctrl[off / 4];
	case DP_SERDES: return c->serdes[off / 4];
	case DP_CONSOLE: return c->console[off];
	}
	return 0;
}

static void b_wr(struct dp_io *io, enum dp_space s, uint32_t off, uint32_t v)
{
	const struct board_ctx *c = io->ctx;
	switch (s) {
	case DP_CTRL: c->ctrl[off / 4] = v; break;
	case DP_SERDES: c->serdes[off / 4] = v; break;
	case DP_CONSOLE: c->console[off] = v; break;
	}
}

static void b_sleep(struct dp_io *io, uint32_t us)
{
	(void)io;
	struct timespec t = { us / 1000000u, (long)(us % 1000000u) * 1000L };
	while (nanosleep(&t, &t) != 0)
		;
}

static uint64_t b_now(struct dp_io *io)
{
	(void)io;
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

static void b_log(struct dp_io *io, const char *line)
{
	(void)io;
	say("%s", line);
}

static volatile sig_atomic_t stopping;
static void on_stop(int sig) { (void)sig; stopping = 1; }

static void usage(void)
{
	fprintf(stderr, "usage: cadr-displayport [--log <path>] [--no-guard] [--status | --crc]\n");
}

static void status(struct dp_io *io)
{
	uint8_t s[8], p;
	say("source: LINK_BW_SET %02x, TRANSMITTER_ENABLE %u, MAIN_STREAM_ENABLE %u, PHY_STATUS %08x, "
	    "live input %02x, clock source %u, HPD %u",
	    (unsigned)io->rd(io, DP_CTRL, DPR_LINK_BW_SET),
	    (unsigned)io->rd(io, DP_CTRL, DPR_TRANSMITTER_ENABLE),
	    (unsigned)io->rd(io, DP_CTRL, DPR_MAIN_STREAM_ENABLE),
	    (unsigned)io->rd(io, DP_CTRL, DPR_PHY_STATUS),
	    (unsigned)io->rd(io, DP_CTRL, DPR_AV_BUF_LIVE_VID_CONFIG),
	    (unsigned)io->rd(io, DP_CTRL, DPR_AV_BUF_AUD_VID_CLK_SOURCE),
	    dp_hpd(io));
	if (!dp_hpd(io)) {
		say("sink: no monitor (HPD low)");
		return;
	}
	if (dp_dpcd_rd(io, 0x200, s, 8) == 0)
		say("sink: lane status %02x, aligned %02x, in sync %u (DPCD 0x202 0x204 0x205)",
		    s[2], s[4], s[5] & 1u);
	if (dp_dpcd_rd(io, 0x600, &p, 1) == 0)
		say("sink: power state %02x (1 D0, 2 D3)", p);
}

static void crc(struct dp_io *io)
{
	uint8_t c[6], m;
	dp_dpcd_wr1(io, 0x270, 1);
	for (int i = 0; i < 4; i++) {
		io->sleep_us(io, 200000);
		if (dp_dpcd_rd(io, 0x246, &m, 1) || dp_dpcd_rd(io, 0x240, c, 6))
			break;
		say("crc: monitor %04x %04x %04x (count %u), controller %04x %04x %04x",
		    c[0] | c[1] << 8, c[2] | c[3] << 8, c[4] | c[5] << 8, m & 15u,
		    (unsigned)io->rd(io, DP_CTRL, DPR_PATGEN_CRC_R),
		    (unsigned)io->rd(io, DP_CTRL, DPR_PATGEN_CRC_G),
		    (unsigned)io->rd(io, DP_CTRL, DPR_PATGEN_CRC_B));
	}
	dp_dpcd_wr1(io, 0x270, 0);
}

int main(int argc, char **argv)
{
	int no_guard = 0, want_status = 0, want_crc = 0;
	static const struct option opts[] = {
		{ "log", required_argument, NULL, 'l' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "status", no_argument, NULL, 's' },
		{ "crc", no_argument, NULL, 'c' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int c;
	while ((c = getopt_long(argc, argv, "l:Gsch", opts, NULL)) != -1) {
		switch (c) {
		case 'l': cadr_log_dest(optarg); break;
		case 'G': no_guard = 1; break;
		case 's': want_status = 1; break;
		case 'c': want_crc = 1; break;
		default: usage(); return 2;
		}
	}
	if (optind < argc) {
		fprintf(stderr, "cadr-displayport: %s: not a flag this program takes\n", argv[optind]);
		return 2;
	}
	if (cadr_log_open("cadr-displayport: ") < 0)
		return 2;

	int mem = cadr_open_mem();
	if (mem < 0)
		return 1;
	// The guard, before anything on the console's port.
	if (!no_guard && cadr_guard(mem, CADR_BOARD_CONSOLE_PORT) < 0)
		return 1;
	struct board_ctx ctx;
	ctx.console = cadr_map(mem, CADR_BOARD_CONSOLE_BASE, 384, "the console's face");
	ctx.ctrl = cadr_map(mem, CADR_BOARD_DISPLAYPORT_BASE, CADR_BOARD_DISPLAYPORT_BYTES,
			    "the DisplayPort controller");
	ctx.serdes = cadr_map(mem, CADR_BOARD_SERDES_BASE, CADR_BOARD_SERDES_BYTES,
			      "the PS-GTR transceivers");
	if (!ctx.console || !ctx.ctrl || !ctx.serdes)
		return 1;
	struct dp_io io = { b_rd, b_wr, b_sleep, b_now, b_log, &ctx };

	const uint32_t ident = io.rd(&io, DP_CONSOLE, DP_CONSOLE_IDENT);
	const uint32_t w36 = io.rd(&io, DP_CONSOLE, DP_CONSOLE_SLEEP);
	if (ident != DP_CONSOLE_IDENT_WORD) {
		say("the console does not answer at %s (IDENT %08x): not this fabric",
		    CADR_BOARD_CONSOLE_BASE_STR, (unsigned)ident);
		return 1;
	}
	if ((w36 >> 16) != DP_SLEEP_MARK) {
		say("word 36 is %08x, with no display output's marker: this fabric has no display "
		    "output, and there is nothing to show", (unsigned)w36);
		return 1;
	}
	if (want_status || want_crc) {
		say("word 36 %08x: the display output %s, sleep after %u s",
		    (unsigned)w36, (w36 & DP_SLEEP_MUTED) ? "is muted" : "is awake",
		    (unsigned)(w36 & 0x7FFFu));
		status(&io);
		if (want_crc)
			crc(&io);
		return 0;
	}

	say("the display output is in the fabric; keeping the DisplayPort link at 1920x1080 at "
	    "60 Hz, HBR2 on one lane, and following word 36's mute (the controller at "
	    CADR_BOARD_STR(CADR_BOARD_DISPLAYPORT_HEX) ", the lane at "
	    CADR_BOARD_STR(CADR_BOARD_SERDES_HEX) ", the console at "
	    CADR_BOARD_STR(CADR_BOARD_CONSOLE_HEX) ")");
	_Static_assert(DP_H_ACTIVE == 1920 && DP_V_ACTIVE == 1080,
		       "the message above names the mode dp_link.h builds");
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	struct dp_keeper k;
	dp_keeper_init(&k);
	while (!stopping) {
		dp_keeper_step(&io, &k, io.rd(&io, DP_CONSOLE, DP_CONSOLE_SLEEP));
		b_sleep(&io, 100000);
	}
	// The stream stops with the program: what the monitor shows without it
	// is the monitor's own "no signal", not a picture nobody keeps.
	dp_stream_off(&io);
	say("stopped: %u bring-ups, %u failed, %u trainings after a wake, %u sleeps, %u wakes, "
	    "the stream lost %u times", k.bring_ups, k.failures, k.trainings, k.sleeps, k.wakes, k.lost);
	return 0;
}
