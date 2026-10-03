// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's video controller's size, as the fabric says it: the console's page
// 2 word 39 (`rtl/plumbing/cadr_console.sv`).
//
// **THE SIZE IS THE BITSTREAM'S, SO THE PROGRAMS TAKE IT FROM THE
// BITSTREAM** (contract HD).  Each board's top level gives its QUUX a size ---
// 1280 by 1024 on the Arty Z7-20 and the DE25-Nano, the Kria KR260's raster
// on the Kria KR260 --- and the same size to its console, so the RFB server,
// the readout and the checkpoint read it here rather than carrying a
// constant that one board's bitstream would contradict.  The band reads it
// from its feature words 11 and 12, which the same top level sets.
//
//     bits 31:22  CADR_VIDEO_MARK, a marker
//     bits 21:11  the width in pixels, a multiple of 32
//     bits 10:0   the height in lines
//
// The CADR has no video controller and reads `UNMAPPED` there, as a QUUX
// bitstream older than the word does; neither carries the marker.  An older
// QUUX bitstream's video controller is 1280 by 1024, every board's then.

#ifndef CADR_VIDEO_H
#define CADR_VIDEO_H

#include <stdint.h>

#define CADR_VIDEO_WORD   39u
#define CADR_VIDEO_MARK   0x356u
// muir's `check_video_size`: at most 1920 by 1080, a line a whole number of
// 32-bit words; so at most 64,800 words.
#define CADR_VIDEO_MAX_WIDTH  1920u
#define CADR_VIDEO_MAX_HEIGHT 1080u
#define CADR_VIDEO_MAX_WORDS  (CADR_VIDEO_MAX_HEIGHT * (CADR_VIDEO_MAX_WIDTH / 32u))
// The size of a QUUX bitstream older than the word.
#define CADR_VIDEO_OLD_WIDTH  1280u
#define CADR_VIDEO_OLD_HEIGHT 1024u

struct cadr_video {
	unsigned width, height, words_per_line, words;
};

// What `word` says: 1 and the size when it carries the marker and a size
// muir takes; 0 when it carries no marker (a CADR, or QUUX older than the
// word); -1 when it carries the marker and a size no QUUX has.
static inline int cadr_video_decode(uint32_t word, struct cadr_video *v)
{
	if ((word >> 22) != CADR_VIDEO_MARK)
		return 0;
	const unsigned w = (word >> 11) & 0x7FFu, h = word & 0x7FFu;
	if (w == 0 || h == 0 || w % 32u != 0 || w > CADR_VIDEO_MAX_WIDTH || h > CADR_VIDEO_MAX_HEIGHT)
		return -1;
	v->width = w;
	v->height = h;
	v->words_per_line = w / 32u;
	v->words = h * (w / 32u);
	return 1;
}

// The size a QUUX bitstream older than the word has.
static inline void cadr_video_old(struct cadr_video *v)
{
	v->width = CADR_VIDEO_OLD_WIDTH;
	v->height = CADR_VIDEO_OLD_HEIGHT;
	v->words_per_line = CADR_VIDEO_OLD_WIDTH / 32u;
	v->words = CADR_VIDEO_OLD_HEIGHT * (CADR_VIDEO_OLD_WIDTH / 32u);
}

#endif
