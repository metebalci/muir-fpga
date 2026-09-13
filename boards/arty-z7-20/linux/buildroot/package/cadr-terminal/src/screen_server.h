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
// **AND IT IS NO LONGER READ-ONLY.**  It was, for as long as the fabric had
// no I/O board to put a keystroke into; the card is in the machine now and
// `rtl/plumbing/cadr_input_cables.sv` is the far end of its keyboard's cable
// and its mouse's.  Given an `input_face`, a `KeyEvent` becomes a stream of
// twenty-four-bit words through `input_keys.h` --- muir's own mapping, its
// own table --- and a `PointerEvent` becomes deltas and a button mask.
// Given NULL it is the read-only server it was, which is what a bitstream
// without the input cables gets and what most of the host check runs.
//
// **THERE IS ONE MOUSE AND THERE ARE UP TO EIGHT VIEWERS.**  A
// `PointerEvent` carries an absolute position and the CADR's mouse counts
// deltas, so the server keeps the last position it was told and sends the
// difference --- `muir::terminal::mouse::Mouse::pointer`, one count a pixel,
// right and down positive, the first event only establishing where the
// pointer is.  With two viewers moving pointers the difference is taken
// between one viewer's position and the other's, and the machine's cursor
// jumps.  muir has exactly this and for the same reason: the machine has one
// mouse, and which of the people watching is holding it is not something RFB
// says.
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

#include "input_face.h"
#include "input_keys.h"
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

	// --- input.  NULL for the read-only server, which is what a board
	// whose bitstream has no input cables gets.
	struct input_face *input;
	struct key_state keys;
	// The last pointer position anybody reported, and whether anybody has.
	uint16_t ptr_x, ptr_y;
	int have_ptr;
	uint8_t buttons;
	// What went across, for a status line: words into the fabric, words
	// the fabric had no room for, and pointer movements.
	unsigned long keys_sent, keys_stuck, pointer_moves;
	// What has gone out, by encoding, and what Raw would have cost for the
	// rectangles RRE was used on: the measurement `docs/terminal.md` quotes.
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
// board's own raster.  A viewer asking for the whole screen at every poll
// would otherwise have this program encode 739,584 pixels instead of
// sleeping.  A frame is the right interval because the machine cannot produce
// a new picture faster than the display board scans one; an incremental
// update is never held back.
//
// **IT IS THE REAL FRAME AND NOT THE MACHINE'S**, and the two stopped being
// the same number when the tick stopped being 5 ns.  This is compared against
// `CLOCK_MONOTONIC` by `screen_server_poll`'s caller, so what it has to be is
// how long the FABRIC takes over a frame: 3,091,200 ticks, 30.912 ms, where
// the machine's own name for that interval is still muir's 15.456 ms.  See
// `screen_geom.h` for both and for why they are kept apart.
#define SCREEN_FULL_UPDATE_NS ((uint64_t)SCREEN_FRAME_REAL_NS)

// A connection that has not got through RFC 6143's opening exchange in this
// long is dropped: a port scanner that opens a socket and says nothing must
// not take one of the eight places for ever.
#define SCREEN_HANDSHAKE_NS ((uint64_t)30 * 1000 * 1000 * 1000)

#endif
