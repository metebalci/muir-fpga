// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Waking the board's own display output, through the console face.
//
// **THE DISPLAY OUTPUT SLEEPS A MONITOR BY STOPPING THE LINK**, which is the
// only way a digital link puts one to sleep, after `--display-sleep` seconds with
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
// **AND THE RECORD THAT WAKES A MONITOR ASLEEP WAKES IT AND DOES NOTHING ELSE.**
// Somebody who touches a key to light a dark screen has not typed that key, so
// it does not reach the machine.  The rule, exactly:
//
//   - Each input-link record asks here, as it arrives, whether the monitor is
//     asleep.  It is asleep when word 36 carries its marker with bit 15 set,
//     bit 15 being the lanes muted as the machine's clock sees them, AND no
//     wake has been written in the last `DWAKE_EVERY_NS`.  Anything else ---
//     no marker, a fabric that cannot say --- is awake, so that a key is never
//     lost on a word this program cannot read.
//   - A record that finds it asleep writes a wake at once and is SWALLOWED:
//     a key down does not reach the machine, and neither does its matching key
//     up, nor any repeat of it in between; a mouse movement does not; a button
//     pressed does not, and neither does its release.  The key up, repeat and
//     release are swallowed whenever they come, the monitor long awake by then.
//   - **EXCEPT A SHIFTING KEY** --- Shift, Control, Meta and the rest of the
//     mapping's --- which wakes the monitor and is delivered all the same.  It
//     types nothing by itself, and swallowing it would change what the key
//     after it means: Control held to wake the screen and then x would reach
//     the machine as x.  And `--keyboard-boot`'s chord is the keyboard's own
//     firmware, which this program runs over the keys the machine is sent
//     (`input_keys.c`, `check_boot`), so a swallowed Control would leave the
//     chord one key short and a sleeping screen could not be booted from.
//     Held in the usual order, the modifiers first, the chord boots and
//     wakes at once.  Begun with Rubout or Return, that key is swallowed and
//     the chord completes at its next press.
//   - Only what the waking record STARTS is swallowed.  A key up, or a button
//     release, of something that went down while the monitor was awake --- a
//     key held across the sleep --- still reaches the machine when it wakes it,
//     or the machine would hold that key down for ever.  A source going away
//     lifts its keys, and a swallowed key's lift is swallowed with the rest.
//   - Everything after the waking record flows as before, including a second
//     record in the same read, or one arriving before the fabric has taken the
//     wake.  The wake reaches the lanes at the next frame boundary and comes
//     back to bit 15 through two flops, so the bit reads asleep for up to a
//     frame, about 17 ms, after the wake is written.  That is why a wake
//     written less than `DWAKE_EVERY_NS` ago means awake whatever the bit says:
//     the coalescing window is the settling window.  It is sound because the
//     monitor cannot fall asleep again inside it: the wake starts the timer
//     over, and the shortest setting is a second.  The window is measured on
//     a clock read when the record is, which is why the board's hook reads its
//     own rather than the pass's (`cadr-terminal.c`, `terminal_wake`).
//   - Waking a monitor and waking the person's attention take different times:
//     the monitor itself takes a second or two to find the link again.  Only
//     ONE record is swallowed, because a person who goes on typing at a screen
//     that is coming back expects the keys to arrive.
//
// The other way round, the timer running out between the bit being read and the
// lanes stopping, is a record that finds it awake, reaches the machine and
// starts the timer over; the lanes may stop for a frame at that boundary and
// come back at the next.
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
#define DWAKE_ASLEEP     0x8000u	/* the lanes are muted */
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
	// For a status line: wakes written, records that came too soon after one
	// to need another, and of the wakes written those that found the monitor
	// asleep.
	unsigned long written, coalesced, woke;
};

// /dev/mem behind it, at `base`.  0, or -1 having said why.
int display_wake_open(struct display_wake *w, int fd, uint32_t base);
void display_wake_close(struct display_wake *w);

// Whether there is a display output to wake: 1 when IDENT reads "CONS" and word
// 36 carries its marker; 0 when it is the console and the word is not there ---
// a board with no display output, or a fabric older than the word; -1 when it is
// not the console at all.  `*ident` and `*word` are what were read.
int display_wake_ready(struct display_wake *w, uint32_t *ident, uint32_t *word);

// What `display_wake_poke` did.
#define DWAKE_COALESCED  0	/* a wake was written too recently to need another */
#define DWAKE_WRITTEN    1	/* written, and the monitor was awake */
#define DWAKE_WOKE       2	/* written, and the monitor was asleep */

// A person at the board did something, at `now_ns` on the caller's monotonic
// clock: write a wake unless one was written less than `DWAKE_EVERY_NS` ago,
// and say which of the three it was.  Word 36 is read only when a wake is to
// be written, so the face sees one read and one write a tenth of a second at
// most.
int display_wake_poke(struct display_wake *w, uint64_t now_ns);

// The server's wake hook (`screen_server.h`), with `ctx` a `struct
// display_wake`: 1 when the record found the monitor asleep and is to be
// swallowed, 0 when it is delivered.
int display_wake_hook(void *ctx, uint64_t now_ns);

#endif
