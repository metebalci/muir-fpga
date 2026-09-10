// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-screen: the program on Linux that shows the CADR's screen to a VNC
// viewer.
//
// WHAT IT IS.  The CADR's display board --- MIT's TV, `rtl/cadr_tv.sv` ---
// keeps no frame buffer of its own in the fabric: a cycle to the window at
// `0o17000000` is answered by main memory's bridge at the display's own base
// in PS DDR3, `0x1C00_0000` (`rtl/cadr_ddr_map.sv`, `rtl/cadr_xbus_ddr.sv`).
// So the picture the machine draws is 92,448 bytes of ordinary DDR that
// Linux can map, and **showing it needs no new fabric at all** --- which is
// why this program exists before the display output block does.  It maps
// that region, reads it once a frame, and serves it over RFB, RFC 6143,
// which is what a VNC viewer speaks.
//
// **READ-ONLY, AND THE PROGRAM SAYS SO.**  No keyboard, no mouse, no pointer.
// A viewer's `KeyEvent` and `PointerEvent` are read off the wire, counted and
// dropped, and one line says so the first time one arrives.  The CADR's
// keyboard and mouse are the I/O board's --- muir's `terminal` serves all
// three because muir has an I/O board to put a keystroke into --- and that
// board is not in the fabric.  Mete asked for the screen first and the input
// later, and this is the screen.
//
// HOW IT RUNS.  `S85cadr-screen` starts it at boot with `--log /dev/console`.
// In order:
//
//   1. THE GUARD.  A read on `M_AXI_GP0` or `M_AXI_GP1` that nothing in the
//      fabric answers hangs both Arm cores, and no software guard can catch
//      it afterwards (CLAUDE.md; measured on the board).  The one thing a
//      program can read first is the EMIO tally at 0xE000A068/6C, which
//      carries marker bits --- `(w & 0x80008000) == 0x00008000` --- only on a
//      bitstream with the processing system in it.  **This program reaches no
//      GP port**: the display's window is DDR, and DDR answers whatever is in
//      the fabric.  The guard runs anyway, and for a reason of its own: a
//      bitstream without the processing system is a bitstream whose CADR
//      never wrote a word of that region, so what this program would serve is
//      whatever the DDR controller last held.  Reading the tally first is how
//      it tells a machine that has not drawn from a board that cannot.
//      `--no-guard` is for a board somebody knows.
//   2. THE WINDOW: 128 KB at 0x1C00_0000 through /dev/mem, uncached --- a
//      word the fabric writes over `S_AXI_HP0` must not be read out of a
//      cache the port cannot see.
//   3. THE SOCKET: RFB on `--port`, 5900 by default, which a viewer reaches
//      as display `:0`.
//   4. THE LOOP: the visible 23,112 words copied out of the window once a
//      pass and every viewer answered from that one copy.  Nothing is read
//      while nobody is watching.
//
// **WHAT IT CANNOT READ, AND WHAT IT ASSUMES INSTEAD.**  `MODE BOW` decides
// whether a one bit is white or black, and it is four flops in the fabric
// with no path to the processing system.  The default here is the fabric's
// own power-on state and muir's, zero --- a one bit is white --- which is
// also the mode both reference programs leave the register in.  `--bow`
// swaps it.  `screen_geom.h` and `docs/screen.md` say what reading it would
// take.
//
// WHAT IT PRINTS, low rate on purpose: one line when it starts, one when a
// viewer connects or leaves, one the first time a viewer sends input, one
// when the screen goes blank or stops being blank, and NOTHING per frame.  A
// summary at most once a minute, and only while the counts move.
//
//     cadr-screen [--port N] [--bind ADDR] [--log PATH] [--bow]
//                   [--interval-ms N] [--no-rre] [--no-guard] [--once]

#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "screen_frame.h"
#include "screen_geom.h"
#include "screen_server.h"

static volatile sig_atomic_t stopping;
static void on_stop(int sig)
{
	(void)sig;
	stopping = 1;
}

static uint64_t monotonic_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-screen [options]\n"
		"  --port N          the RFB port (default 5900, which is display :0)\n"
		"  --bind ADDR       the address to listen on (default every interface)\n"
		"  --log PATH        where to write (default stdout)\n"
		"  --bow             the display's MODE BOW: one bits are black (default: white)\n"
		"  --window ADDR     the display's region (default 0x1C000000)\n"
		"  --interval-ms N   how often the window is read while anybody watches (default 16)\n"
		"  --no-rre          send every rectangle Raw, for measuring what RRE buys\n"
		"  --no-guard        do not check the EMIO tally first\n"
		"  --once            do the checks, read one frame, say what is on it, and exit\n");
}

static const char *blank_word(int blank)
{
	switch (blank) {
	case SCREEN_BLANK_ZEROS: return "every visible word zero";
	case SCREEN_BLANK_ONES: return "every visible word all ones";
	case SCREEN_BLANK_OTHER: return "one word repeated 23,112 times";
	default: return "content";
	}
}

int main(int argc, char **argv)
{
	const char *log_path = NULL, *bind_addr = NULL;
	unsigned port = 5900, interval_ms = 16;
	uint32_t window_phys = SCREEN_BASE;
	int bow = 0, no_guard = 0, once = 0, no_rre = 0;
	static const struct option opts[] = {
		{ "port", required_argument, NULL, 'p' },
		{ "bind", required_argument, NULL, 'b' },
		{ "log", required_argument, NULL, 'l' },
		{ "bow", no_argument, NULL, 'B' },
		{ "window", required_argument, NULL, 'w' },
		{ "interval-ms", required_argument, NULL, 'i' },
		{ "no-rre", no_argument, NULL, 'R' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "once", no_argument, NULL, 'o' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "p:b:l:Bw:i:RGoh", opts, NULL)) != -1) {
		switch (c) {
		case 'p': port = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'b': bind_addr = optarg; break;
		case 'l': log_path = optarg; break;
		case 'B': bow = 1; break;
		case 'w': window_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'i': interval_ms = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'R': no_rre = 1; break;
		case 'G': no_guard = 1; break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	// A zero interval would make the loop a busy wait: poll(2) with no
	// timeout to wait for and a window read every pass.
	if (interval_ms == 0)
		interval_ms = 1;
	if (port > 65535) {
		fprintf(stderr, "cadr-screen: --port %u: a port is 0 to 65535\n", port);
		return 2;
	}
	FILE *dest = stdout;
	if (log_path) {
		dest = fopen(log_path, "a");
		if (!dest) {
			fprintf(stderr, "cadr-screen: %s: %s\n", log_path, strerror(errno));
			return 2;
		}
	}
	cadr_log_init("cadr-screen: ", dest);

	int mem = cadr_open_mem();
	if (mem < 0)
		return 1;
	// 1. The guard.  This program touches no GP port; the header says why
	// it runs anyway.
	if (!no_guard && cadr_guard(mem, "the display's window") < 0)
		return 1;
	// 2. The window.
	volatile uint32_t *window = cadr_map(mem, window_phys, SCREEN_WINDOW_BYTES,
					     "the display's window");
	if (!window)
		return 1;

	struct screen_frame frame;
	screen_frame_init(&frame, bow);
	screen_frame_read(&frame, window);
	say("the display's window is %u KB at 0x%08x; the screen is %ux%u, %u words a line, "
	    "%u of the window's %u words, one bit a pixel, a one bit %s",
	    SCREEN_WINDOW_BYTES / 1024u, window_phys, SCREEN_WIDTH, SCREEN_HEIGHT,
	    SCREEN_WORDS_PER_LINE, SCREEN_VISIBLE_WORDS, SCREEN_WINDOW_WORDS,
	    bow ? "BLACK (MODE BOW, --bow)" : "WHITE (MODE BOW clear, the fabric's power-on state)");

	int blank = screen_frame_blank(&frame);
	if (blank != SCREEN_BLANK_NO)
		say("the screen is BLANK: %s (0x%08x). Either the machine has not drawn, or this is "
		    "not the region it draws into --- an unwritten word of this board's DDR reads zero "
		    "in some places and all ones in others (docs/board.md)",
		    blank_word(blank), frame.words[0]);
	else
		say("the screen has content: %lu of %u pixels lit",
		    screen_frame_lit(&frame), SCREEN_WIDTH * SCREEN_HEIGHT);
	if (once)
		return 0;

	// 3. The socket.
	struct screen_server srv;
	if (screen_server_bind(&srv, bind_addr, port) < 0)
		return 1;
	srv.rre_offered = !no_rre;
	say("RFB on %s:%u --- display :%u to a viewer. NO AUTHENTICATION: RFC 6143's None is the "
	    "only security type offered, so anyone who can reach this port sees the screen. "
	    "READ-ONLY: keys and pointer events are dropped. Encodings: Raw%s",
	    bind_addr && *bind_addr ? bind_addr : "0.0.0.0", port,
	    port >= 5900 && port < 5900 + 100 ? port - 5900 : 0,
	    no_rre ? " only (--no-rre)" : " and RRE, whichever is smaller for each rectangle");

	// 4. The loop.
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	signal(SIGPIPE, SIG_IGN);
	time_t last_said = time(NULL);
	unsigned long said_connects = 0, said_input = 0;
	uint64_t last_read_ns = 0;
	unsigned long long said_bytes = 0;
	while (!stopping) {
		const uint64_t now = monotonic_ns();
		// Nothing is read while nobody is watching: the window is an
		// uncached mapping and 92,448 bytes of it is real traffic on
		// the DDR controller's debug port.  A machine with no viewer
		// costs this program a poll and nothing else.
		if (srv.viewers && now - last_read_ns >= (uint64_t)interval_ms * 1000000u) {
			screen_frame_read(&frame, window);
			last_read_ns = now;
			const int now_blank = screen_frame_blank(&frame);
			if (now_blank != blank) {
				if (now_blank == SCREEN_BLANK_NO)
					say("the screen has content: %lu of %u pixels lit",
					    screen_frame_lit(&frame), SCREEN_WIDTH * SCREEN_HEIGHT);
				else
					say("the screen has gone blank: %s", blank_word(now_blank));
				blank = now_blank;
			}
		}
		screen_server_poll(&srv, &frame, (int)interval_ms, monotonic_ns());
		const time_t t = time(NULL);
		if (t - last_said >= 60
		    && (srv.connects != said_connects || srv.input_events != said_input
			|| srv.sent_raw + srv.sent_rre != said_bytes)) {
			say("%u watching (%lu connected, %lu gone, %lu refused); %lu frames read; "
			    "%lu rectangles Raw for %llu bytes (RRE would have been %llu), "
			    "%lu RRE for %llu, saving %llu; %lu input events dropped",
			    srv.viewers, srv.connects, srv.drops, srv.refused, frame.reads,
			    srv.rects_raw, srv.sent_raw, srv.declined_rre, srv.rects_rre,
			    srv.sent_rre, srv.saved_by_rre, srv.input_events);
			said_connects = srv.connects;
			said_input = srv.input_events;
			said_bytes = srv.sent_raw + srv.sent_rre;
			last_said = t;
		}
	}
	say("stopped: %lu viewers came and %lu went; %lu frames read; %llu bytes of pixels sent, "
	    "%llu saved by RRE; %lu input events dropped",
	    srv.connects, srv.drops, frame.reads, srv.sent_raw + srv.sent_rre, srv.saved_by_rre,
	    srv.input_events);
	screen_server_close(&srv);
	return 0;
}
