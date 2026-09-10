// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The frame; `screen_frame.h` says why the copy is the frame.

#include "screen_frame.h"

void screen_frame_init(struct screen_frame *f, int black_on_white)
{
	f->width = SCREEN_WIDTH;
	f->height = SCREEN_HEIGHT;
	f->words_per_line = SCREEN_WORDS_PER_LINE;
	f->black_on_white = black_on_white != 0;
	f->reads = 0;
	for (unsigned i = 0; i < SCREEN_VISIBLE_WORDS; ++i)
		f->words[i] = 0;
}

void screen_frame_read(struct screen_frame *f, const volatile uint32_t *window)
{
	// Word by word and not memcpy: the source is a volatile mapping of
	// somebody else's memory, and memcpy takes a plain pointer and is
	// entitled to read it twice or in another width.
	for (unsigned i = 0; i < SCREEN_VISIBLE_WORDS; ++i)
		f->words[i] = window[i];
	++f->reads;
}

int screen_frame_blank(const struct screen_frame *f)
{
	const uint32_t first = f->words[0];
	for (unsigned i = 1; i < SCREEN_VISIBLE_WORDS; ++i)
		if (f->words[i] != first)
			return SCREEN_BLANK_NO;
	if (first == 0)
		return SCREEN_BLANK_ZEROS;
	if (first == 0xFFFFFFFFu)
		return SCREEN_BLANK_ONES;
	return SCREEN_BLANK_OTHER;
}

unsigned long screen_frame_lit(const struct screen_frame *f)
{
	unsigned long n = 0;
	for (unsigned i = 0; i < SCREEN_VISIBLE_WORDS; ++i) {
		uint32_t w = f->words[i];
		while (w) {
			n += w & 1u;
			w >>= 1;
		}
	}
	return n;
}
