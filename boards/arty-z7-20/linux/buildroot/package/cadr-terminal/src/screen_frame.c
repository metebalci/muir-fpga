// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The frame; `screen_frame.h` says why the copy is the frame.

#include <string.h>

#include "screen_frame.h"

void screen_frame_init(struct screen_frame *f, int black_on_white)
{
	f->width = SCREEN_WIDTH;
	f->height = SCREEN_HEIGHT;
	f->words_per_line = SCREEN_WORDS_PER_LINE;
	f->visible_words = SCREEN_VISIBLE_WORDS;
	f->bpp = 1;
	f->black_on_white = black_on_white != 0;
	f->reads = 0;
	for (unsigned c = 0; c < SCREEN_COLORS; ++c)
		f->map[c][0] = f->map[c][1] = f->map[c][2] = 0;
	for (unsigned i = 0; i < SCREEN_MAX_VISIBLE_WORDS; ++i)
		f->words[i] = 0;
}

void screen_frame_init_color(struct screen_frame *f)
{
	screen_frame_init(f, 0);
	f->width = SCREEN_COLOR_WIDTH;
	f->height = SCREEN_COLOR_HEIGHT;
	f->words_per_line = SCREEN_COLOR_WORDS_PER_LINE;
	f->visible_words = SCREEN_COLOR_VISIBLE_WORDS;
	f->bpp = SCREEN_COLOR_BPP;
	// **`MODE BOW` IS NOT CARRIED HERE AND IT IS NOT AN OVERSIGHT.**  A
	// four-bit pixel is an address into the map, so there is no bit to
	// invert, and muir's `Tv::color` takes no notice of the mode register
	// either.
	f->black_on_white = 0;
}

void screen_frame_init_mono(struct screen_frame *f, int black_on_white)
{
	screen_frame_init(f, black_on_white);
	f->width = SCREEN_MONO_WIDTH;
	f->height = SCREEN_MONO_HEIGHT;
	f->words_per_line = SCREEN_MONO_WORDS_PER_LINE;
	f->visible_words = SCREEN_MONO_VISIBLE_WORDS;
}

// muir's own two words and nothing else: `--machine wants cadr or quux`.
int screen_machine_parse(const char *word, enum screen_machine *out)
{
	if (strcmp(word, "cadr") == 0) {
		*out = SCREEN_MACHINE_CADR;
		return 0;
	}
	if (strcmp(word, "quux") == 0) {
		*out = SCREEN_MACHINE_QUUX;
		return 0;
	}
	return -1;
}

const char *screen_machine_name(enum screen_machine m)
{
	return m == SCREEN_MACHINE_QUUX ? "quux" : "cadr";
}

void screen_frame_init_for(struct screen_frame *f, enum screen_machine m, int black_on_white)
{
	if (m == SCREEN_MACHINE_QUUX)
		screen_frame_init_mono(f, black_on_white);
	else
		screen_frame_init(f, black_on_white);
}

unsigned screen_window_bytes(enum screen_machine m)
{
	return m == SCREEN_MACHINE_QUUX ? SCREEN_MONO_WINDOW_BYTES : SCREEN_WINDOW_BYTES;
}

int screen_machine_has_color(enum screen_machine m)
{
	return m == SCREEN_MACHINE_CADR;
}

void screen_frame_map(struct screen_frame *f, const uint8_t map[SCREEN_COLORS][3])
{
	for (unsigned c = 0; c < SCREEN_COLORS; ++c)
		for (unsigned k = 0; k < 3; ++k)
			f->map[c][k] = map[c][k];
}

void screen_frame_read(struct screen_frame *f, const volatile uint32_t *window)
{
	// Word by word and not memcpy: the source is a volatile mapping of
	// somebody else's memory, and memcpy takes a plain pointer and is
	// entitled to read it twice or in another width.
	for (unsigned i = 0; i < f->visible_words; ++i)
		f->words[i] = window[i];
	++f->reads;
}

int screen_frame_blank(const struct screen_frame *f)
{
	const uint32_t first = f->words[0];
	for (unsigned i = 1; i < f->visible_words; ++i)
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
	for (unsigned i = 0; i < f->visible_words; ++i) {
		uint32_t w = f->words[i];
		while (w) {
			n += w & 1u;
			w >>= 1;
		}
	}
	return n;
}
