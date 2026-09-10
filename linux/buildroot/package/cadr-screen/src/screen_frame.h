// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One frame: the machine's screen taken out of DDR and held where the
// encoder can read it many times.
//
// **THE COPY IS NOT AN OPTIMISATION, IT IS THE FRAME.**  The window is an
// uncached mapping --- `cadr_open_mem` opens /dev/mem with O_SYNC, because a
// word the fabric writes over `S_AXI_HP0` must not sit in a cache the port
// cannot see --- so every read of it goes to the DDR controller.  An encoder
// reading the window directly would read the same word once to find whether
// the line changed and again to encode it, at uncached speed, and would read
// a screen that the CADR went on writing underneath it, so that a rectangle
// declared changed could be encoded from words newer than the ones that
// declared it.  Copying the visible 92,448 bytes once a pass gives every
// viewer in that pass ONE screen, and the diff and the pixels come from the
// same one.
//
// **WHAT IT STILL CANNOT DO IS STOP THE MACHINE.**  The CADR writes the
// window while this copy is being made, so a copy may hold the top of the
// screen from before a write and the bottom from after it.  There is no
// interlock to take: muir's own terminal has the same seam (`Frame::of` hands
// over the buffer as it stands) and the vertical flag the microcode uses is a
// frame counter in the fabric with no path to Linux.  A torn frame is one
// frame; the next pass sends the rest.  Said here so that nobody looks for
// the interlock.
//
// **BLANK IS A STATE WORTH SAYING.**  Uninitialised DDR on this board reads
// as alternating bands of zeros and ones (CLAUDE.md, measured on the first
// bring-up), and a CADR that has not drawn leaves the window exactly as the
// controller left it.  A viewer shown 739,584 identical pixels cannot tell
// "the machine has drawn nothing" from "this program is reading the wrong
// address", so the program says which it found, once, rather than serving
// a blank screen silently.

#ifndef SCREEN_FRAME_H
#define SCREEN_FRAME_H

#include <stdint.h>

#include "screen_geom.h"

// What the window held when it was last read.
struct screen_frame {
	uint32_t words[SCREEN_VISIBLE_WORDS];
	unsigned width, height, words_per_line;
	// Whether a one bit shows black rather than white: the display board's
	// `MODE BOW`, which this program is told rather than reads.
	int black_on_white;
	// How many times it has been read.
	unsigned long reads;
};

// Everything but the words.
void screen_frame_init(struct screen_frame *f, int black_on_white);

// The visible words out of the window, which may be an uncached mapping.
// `window` is at least SCREEN_VISIBLE_WORDS long.
void screen_frame_read(struct screen_frame *f, const volatile uint32_t *window);

// What a frame of one repeated word is: 0 for neither, 1 for all zeros, 2 for
// all ones, 3 for some other single word repeated 23,112 times.  Anything
// else is 0.
#define SCREEN_BLANK_NO     0
#define SCREEN_BLANK_ZEROS  1
#define SCREEN_BLANK_ONES   2
#define SCREEN_BLANK_OTHER  3
int screen_frame_blank(const struct screen_frame *f);

// How many of the visible pixels are lit, for the line the program says when
// it first sees content.
unsigned long screen_frame_lit(const struct screen_frame *f);

#endif
