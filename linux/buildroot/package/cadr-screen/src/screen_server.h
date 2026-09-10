// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The socket, the viewers on it, and the screen each of them is shown.
//
// This is muir's `src/terminal/mod.rs` in C, and deliberately: the same
// `Frame`, the same one-outstanding-request rule, the same whole-screen
// interval of one frame, the same diff by rows of frame-buffer words, the
// same table of eight pixels per frame-buffer byte.  Two programs showing
// one machine must not disagree about what a viewer is shown, and the
// argument for each of those decisions is written out there.
//
// **THIS ONE IS READ-ONLY AND muir's IS NOT.**  muir's terminal is the
// display, the keyboard and the mouse, because muir has an I/O board to
// put a keystroke into.  The fabric has no I/O board yet, so a `KeyEvent`
// or a `PointerEvent` here has nowhere to go: it is read off the wire,
// counted, and dropped, and the program says so once.  Dropping it is not
// the same as refusing the connection --- RFC 6143 gives a viewer no way
// to be told a server takes no input, and every viewer sends pointer
// events as the mouse crosses its window --- so a viewer that types at
// this screen sees nothing happen, which is what a machine with no
// keyboard attached does.
//
// **AND IT HAS RRE BESIDE RAW.**  `screen_rfb.h` has the measurement and
// the reason.
//
// **THE FRAME IS THE CALLER'S.**  This module never reads DDR: it is given
// a `struct screen_frame` at every poll and encodes out of it, so the host
// check drives it with a screen of its own and nothing in it knows whether
// a board exists.

#ifndef SCREEN_SERVER_H
#define SCREEN_SERVER_H

#include <stdint.h>

#include "screen_frame.h"
#include "screen_rfb.h"

// How many viewers are served at once; the next connection is closed as it
// arrives, with a line saying so.  Each viewer holds a copy of the screen,
// 92 KB, and an outbox of up to a whole update, 2.9 MB at 32 bits a pixel.
// muir's number, for muir's reason: eight is a room of people watching, and
// a bound.
#define SCREEN_MAX_VIEWERS 8

// The name a viewer puts on its window.
#define SCREEN_NAME "CADR"

struct screen_viewer;

struct screen_server {
	int listener;
	struct screen_viewer *viewer[SCREEN_MAX_VIEWERS];
	unsigned viewers;
	// RRE is offered unless this is clear: `--no-rre`, for measuring the
	// difference and for a viewer that says it takes RRE and does not.
	int rre_offered;
	// The read-only line, said once for the program and not once a viewer.
	int said_input;
	unsigned long connects, drops, refused;
	unsigned long input_events;
	// What has gone out, by encoding, and what Raw would have cost for the
	// rectangles RRE was used on: the measurement `docs/screen.md` quotes.
	unsigned long long sent_raw, sent_rre, saved_by_rre;
	unsigned long rects_raw, rects_rre;
	// And what RRE WOULD have cost for the rectangles it lost, so that the
	// decision is a measurement in both directions and not only where it
	// went the way it usually goes.
	unsigned long long declined_rre;
};

// Binds and listens.  `bind_addr` is a dotted quad or NULL for every
// interface.  0 on success, -1 having said why.
int screen_server_bind(struct screen_server *s, const char *bind_addr, unsigned port);

// One pass: accept what is waiting, read what viewers have sent, answer the
// outstanding requests out of `f`, and write what will go.  `timeout_ms` is
// how long poll(2) may wait, and `now_ns` is a monotonic clock the caller
// keeps --- passed in rather than read here so that the host check can hold
// the whole-screen interval still.
void screen_server_poll(struct screen_server *s, const struct screen_frame *f,
			int timeout_ms, uint64_t now_ns);

// What port the listener actually took, which is the interesting question
// only when a caller asked for 0 and let the kernel choose --- the host
// check does, so that two runs of it never collide on one port.
unsigned screen_server_port(const struct screen_server *s);

// The listener and every viewer.
void screen_server_close(struct screen_server *s);

// The most often a viewer is given the whole screen: one frame of the
// board's own raster, SCREEN_FRAME_NS, 15.456 ms.  A viewer asking for the
// whole screen at every poll would otherwise have this program encode
// 739,584 pixels instead of sleeping.  A frame is the right interval because
// the machine cannot produce a new picture faster than the display board
// scans one; an incremental update is never held back.
#define SCREEN_FULL_UPDATE_NS ((uint64_t)SCREEN_FRAME_NS)

// A connection that has not got through RFC 6143's opening exchange in this
// long is dropped: a port scanner that opens a socket and says nothing must
// not take one of the eight places for ever.
#define SCREEN_HANDSHAKE_NS ((uint64_t)30 * 1000 * 1000 * 1000)

#endif
