// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Waking the board's own display output, through the console face.
//
// **THE DISPLAY OUTPUT SLEEPS A MONITOR BY STOPPING THE LINK**, which is the
// only way a digital link puts one to sleep, after `--hdmi-sleep` seconds with
// nobody at the board.  `rtl/plumbing/cadr_display_out.sv` holds the setting and
// runs the timer, and the console's page 2 word 36 carries two things to it: a
// setting, and a wake.  This file is the wake.
//
// **ONLY A PERSON AT THE BOARD WAKES IT, AND ONLY THIS PROGRAM CAN TELL.**  A key
// or the mouse at the board reaches the machine through `cadr-usb-input` and
// this program's input link; a key in a viewer reaches it through this program's
// socket; and the fabric sees one keyboard register written for both.  So the
// fabric cannot decide, and the server calls this for an input-link record and
// for nothing else.  A viewer's key still goes to the machine: it simply does not
// wake a monitor nobody at the board is looking at, and it does not keep one
// awake either.  A source attaching or going away is not a record and is not a
// wake.
//
// **ONE WRITE A TENTH OF A SECOND AT MOST.**  A mouse reports a hundred times a
// second or more, and every report would be a write through the general-purpose
// port and a pulse in the fabric that starts the timer over.  The timer counts
// whole seconds, so a wake a tenth of a second old is as good as one made now,
// and the first record after a quiet spell always wakes at once.
//
// **THE WORD'S ADDRESS AND ITS KEYS ARE COPIED FROM `cadr-console`'s
// `console_face.h`**, deliberately, for the reason `color_map.h` gives: Buildroot
// builds this package from its own `src/` alone, so a sibling package's header is
// not there to include.  `rtl/plumbing/cadr_console.sv` is the authority.
//
// **AND THE FACE IS REACHED THROUGH TWO FUNCTION POINTERS** so that the host
// check can put a model behind them and the board puts /dev/mem, which is
// `color_map.h`'s own seam one word along.

#ifndef DISPLAY_WAKE_H
#define DISPLAY_WAKE_H

#include <stdint.h>

#include <cadr/cadr_board.h>

// `M_AXI_GP1` decodes 0x80000000 upwards; the console sits at the bottom of it.
// The console's address is the board's (<cadr/cadr_board.h>).
#define DWAKE_REG_BASE   CADR_BOARD_CONSOLE_BASE
#define DWAKE_REG_BYTES  384u
#define DWAKE_IDENT      0u
#define DWAKE_IDENT_WORD 0x434F4E53u	/* "CONS" */

// Page 2's word 36: the display output's sleep.  It reads back the marker in
// the top half, the lanes muted in bit 15 and the setting in bits 14 to 0, and
// `UNMAPPED` on a board with no display output.  A write of `DWAKE_KEY` is a
// wake.
#define DWAKE_WORD       36u
#define DWAKE_MARK       0x5A5Au	/* "ZZ" */
#define DWAKE_MARK_OF(w) ((w) >> 16)
#define DWAKE_KEY        0x57414B45u	/* "WAKE" */

// The least time between two wakes written.
#define DWAKE_EVERY_NS   ((uint64_t)100 * 1000 * 1000)

struct display_wake {
	uint32_t (*read)(struct display_wake *w, unsigned word);
	void (*write)(struct display_wake *w, unsigned word, uint32_t v);
	void *ctx;
	// When the last wake was written, and whether one ever was.
	uint64_t last_ns;
	int ever;
	// For a status line: wakes written, and records that came too soon after
	// one to need another.
	unsigned long written, coalesced;
};

// /dev/mem behind it, at `base`.  0, or -1 having said why.
int display_wake_open(struct display_wake *w, int fd, uint32_t base);
void display_wake_close(struct display_wake *w);

// Whether there is a display output to wake: 1 when IDENT reads "CONS" and word
// 36 carries its marker; 0 when it is the console and the word is not there ---
// a board with no display output, or a fabric older than the word; -1 when it is
// not the console at all.  `*ident` and `*word` are what were read.
int display_wake_ready(struct display_wake *w, uint32_t *ident, uint32_t *word);

// A person at the board did something, at `now_ns` on the caller's monotonic
// clock: write a wake unless one was written less than `DWAKE_EVERY_NS` ago.
// Answers 1 if it wrote and 0 if it did not.
int display_wake_poke(struct display_wake *w, uint64_t now_ns);

#endif
