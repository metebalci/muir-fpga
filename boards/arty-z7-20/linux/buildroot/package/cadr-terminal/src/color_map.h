// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The color TV's color map, read out of the console face.
//
// **THE MAP IS WRITE ONLY ON THE XBUS AND THE PICTURE CANNOT BE DRAWN
// WITHOUT IT.**  A pixel of the color screen is four bits, an address into
// sixteen colors, and `sys/window/color.lisp` keeps `HARDWARE-COLOR-MAP` in
// the band precisely because "the hardware does not allow reading back of the
// color map": the RAMs and their converters are off the board.  So the fabric
// keeps the sixteen entries as muir's `tv::Tv::color_map` does and offers
// them to Linux on pages 4 and 5 of the console face, read only, and this is
// how a screen server asks.
//
// **THE WINDOW'S ADDRESSES ARE COPIED FROM `cadr-console`'s
// `console_face.h`, DELIBERATELY AND NOT BY ACCIDENT.**  Buildroot's `local`
// site method rsyncs only THIS package's `src/` into the build tree, so a
// relative include of a sibling package's header builds on the host and fails
// under Buildroot --- `cadr-readout`'s `readout.h` records the same seam and
// so does `pack_side.h`.  What is copied is the handful of constants a reader
// needs and nothing else; `rtl/plumbing/cadr_console.sv` is the authority for
// all of them.
//
// **AND THE FACE IS REACHED THROUGH ONE FUNCTION POINTER** so that the host
// check can put a model of the fabric behind it and the board puts /dev/mem.
// `input_face.h` one file along has the same seam and the same reason.

#ifndef COLOR_MAP_H
#define COLOR_MAP_H

#include <stdint.h>

#include <cadr/cadr_board.h>

// `M_AXI_GP1` decodes 0x80000000 upwards to the fabric; the console sits at
// the bottom of it.  This program reads page 2's word 33 and page 5's sixteen
// and nothing else, so 384 bytes is what it maps: six pages of sixteen words,
// which is the whole face.  The console's address is the board's
// (<cadr/cadr_board.h>).
#define CMAP_REG_BASE   CADR_BOARD_CONSOLE_BASE
#define CMAP_REG_BYTES  384u
#define CMAP_IDENT_WORD 0x434F4E53u	/* "CONS" */

// Page 2's word 33: which display boards the backplane has.  Read only here
// --- `cadr-console tv-board` and `color-tv` are what write it, and the disk
// pack program's init script is what calls them at boot.
#define CMAP_IDENT      0u
#define CMAP_DISPLAY    33u
#define CMAP_TV_MARK    0x5456u		/* "TV" */
#define CMAP_TV_MARK_OF(w) ((w) >> 16)
#define CMAP_TV_LISPM   (1u << 0)
#define CMAP_TV_COLOR   (1u << 1)

// Pages 4 and 5: the two boards' maps, word 64 + c and word 80 + c.  Red in
// bits 23 to 16, green in 15 to 8 and blue in 7 to 0, which is
// `WRITE-COLOR-MAP`'s own channel order --- it writes red on channel 0.
#define CMAP_PAGE4      64u
#define CMAP_PAGE5      80u
#define CMAP_WORD(board, color) (((board) ? CMAP_PAGE5 : CMAP_PAGE4) + (unsigned)(color))
#define CMAP_COLORS     16
#define CMAP_CHANNELS   3
#define CMAP_RED(w)     (((w) >> 16) & 0xFFu)
#define CMAP_GREEN(w)   (((w) >> 8) & 0xFFu)
#define CMAP_BLUE(w)    ((w) & 0xFFu)

struct color_map_face {
	uint32_t (*read)(struct color_map_face *f, unsigned word);
	void *ctx;
};

// /dev/mem behind it, at `base`.  0, or -1 having said why.
int color_map_open(struct color_map_face *f, int fd, uint32_t base);
void color_map_close(struct color_map_face *f);

// IDENT reads "CONS".  0 if it does, -1 with `*got` otherwise.
int color_map_ident(struct color_map_face *f, uint32_t *got);

// Whether the fabric says a color TV is fitted.  -1 when the word carries no
// marker, which is a fabric older than it is rather than a backplane with
// nothing set: both read zero in the two bits, and only the marker tells them
// apart.
int color_map_fitted(struct color_map_face *f);

// The color TV's sixteen colors, `[color][channel]` with red first.
// Returns 1 if any of the forty-eight bytes is not zero, which is what says
// the machine has written a map: an unwritten one is every gun at zero and
// every color black, and a screen drawn through it is a black screen.
int color_map_read(struct color_map_face *f, uint8_t map[CMAP_COLORS][CMAP_CHANNELS]);

#endif
