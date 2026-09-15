// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One frame: the machine's screen taken out of DDR and held where the
// encoder can read it many times.
//
// **THE COPY IS NOT AN OPTIMIZATION, IT IS THE FRAME.**  The window is an
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
// over the buffer as it stands) and the vertical flag the microcode uses is
// the sync program's own in the fabric, with no path to Linux.  A torn frame is one
// frame; the next pass sends the rest.  Said here so that nobody looks for
// the interlock.
//
// **BLANK IS A STATE WORTH SAYING.**  Uninitialized DDR on this board reads
// as alternating bands of zeros and ones (measured on the first
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
//
// **ONE STRUCT SERVES BOTH DISPLAY BOARDS**, because everything a viewer is
// shown comes through `screen_value` below and the geometry is fields rather
// than constants.  The words are sized for the LARGER of the two screens ---
// the color one, 32,688 words against 23,112 --- so a frame of either fits.
struct screen_frame {
	uint32_t words[SCREEN_MAX_VISIBLE_WORDS];
	unsigned width, height, words_per_line;
	// How many words of the window are the picture: 963 x 24 or 454 x 72.
	unsigned visible_words;
	// One or four.  **FOUR IS THE COLOR TV**, whose pixel is an address
	// into the sixteen colors `map` holds rather than a bit.
	unsigned bpp;
	// Whether a one bit shows black rather than white: the display board's
	// `MODE BOW`, which this program is told rather than reads.  It reaches
	// a one-bit screen only: a four-bit pixel has no bit to invert, and
	// muir's `Tv::color` takes no notice of the mode register either.
	int black_on_white;
	// The color map, `[color][channel]` with red first, which is
	// `WRITE-COLOR-MAP`'s own channel order.  Meaningless at one bit a
	// pixel; read out of the console face at four, because the map is
	// write only on the Xbus and the picture cannot be drawn without it.
	uint8_t map[SCREEN_COLORS][3];
	// How many times it has been read.
	unsigned long reads;
};

// Everything but the words.
void screen_frame_init(struct screen_frame *f, int black_on_white);

// The same for the second display board: 576 x 454 at four bits a pixel,
// through a color map of sixteen.  The map starts as MIT's software leaves
// an unwritten one --- every gun zero, `Tv::default`'s --- and
// `screen_frame_map` is how the real one arrives.
void screen_frame_init_color(struct screen_frame *f);

// The sixteen colors, `[color][channel]` with red first.
void screen_frame_map(struct screen_frame *f, const uint8_t map[SCREEN_COLORS][3]);

// The visible words out of the window, which may be an uncached mapping.
// `window` is at least `f->visible_words` long.
void screen_frame_read(struct screen_frame *f, const volatile uint32_t *window);

// **WHAT A VIEWER IS SHOWN AT `x`, `y`, AND IT IS ONE FUNCTION FOR BOTH
// BOARDS.**  A color, as an index: 0 or 1 on the one-bit screen --- black
// and white, with `MODE BOW` already applied --- and 0 to 15 on the color
// one.  Every encoding in `screen_server.c` goes through this or through a
// table built from it, so the two screens differ in this function and in the
// table's width and nowhere else.
// **AND IT GOES THROUGH `screen_shows_white` AND NOT ROUND IT.**  The one-bit
// case is that function and no second expression of it: every mutation aimed
// at which bit is which pixel, and at which way round black and white are, is
// anchored there, and a copy here would take the encodings out of their
// reach while leaving them matching.  That is the rule about a
// mutation downstream of a guard, met from the other side.
static inline unsigned screen_value(const struct screen_frame *f, unsigned x, unsigned y)
{
	if (f->bpp == SCREEN_COLOR_BPP)
		return screen_color_index(f->words, x, y);
	return (unsigned)screen_shows_white(f->words, x, y, f->black_on_white);
}

// How many distinct values a pixel of this screen can take: two or sixteen.
static inline unsigned screen_values(const struct screen_frame *f)
{
	return f->bpp == SCREEN_COLOR_BPP ? SCREEN_COLORS : 2u;
}

// What a frame of one repeated word is: 0 for neither, 1 for all zeros, 2 for
// all ones, 3 for some other single word repeated over the whole picture,
// which is 23,112 words on the first display board and 32,688 on the color
// TV.  Anything else is 0.
#define SCREEN_BLANK_NO     0
#define SCREEN_BLANK_ZEROS  1
#define SCREEN_BLANK_ONES   2
#define SCREEN_BLANK_OTHER  3
int screen_frame_blank(const struct screen_frame *f);

// How many of the visible pixels are lit, for the line the program says when
// it first sees content.
unsigned long screen_frame_lit(const struct screen_frame *f);

#endif
