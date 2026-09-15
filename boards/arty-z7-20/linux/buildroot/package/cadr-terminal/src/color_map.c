// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `color_map.h` says what the face is and where every number comes from.

#include "color_map.h"

#include <stdio.h>
#include <sys/mman.h>

#include <cadr/cadr_mem.h>

struct cmap_ctx {
	volatile uint32_t *regs;
};

static struct cmap_ctx cmap_ctx;

static uint32_t cmap_read(struct color_map_face *f, unsigned word)
{
	const struct cmap_ctx *c = f->ctx;
	return c->regs[word];
}

int color_map_open(struct color_map_face *f, int fd, uint32_t base)
{
	volatile uint32_t *regs = cadr_map(fd, base, CMAP_REG_BYTES, "the console's face");
	if (!regs)
		return -1;
	cmap_ctx.regs = regs;
	f->read = cmap_read;
	f->ctx = &cmap_ctx;
	return 0;
}

void color_map_close(struct color_map_face *f)
{
	// Only a face `color_map_open` opened owns a mapping.  The host check
	// puts its own model behind the same pointer, and a `ctx` that is not
	// this one must not be unmapped --- so the test is the function
	// pointer, which is `input_face_close`'s own rule one file along.
	if (f->read == cmap_read && cmap_ctx.regs) {
		munmap((void *)cmap_ctx.regs, CMAP_REG_BYTES);
		cmap_ctx.regs = NULL;
	}
	f->read = NULL;
	f->ctx = NULL;
}

int color_map_ident(struct color_map_face *f, uint32_t *got)
{
	const uint32_t w = f->read(f, CMAP_IDENT);
	if (got)
		*got = w;
	return w == CMAP_IDENT_WORD ? 0 : -1;
}

int color_map_fitted(struct color_map_face *f)
{
	const uint32_t w = f->read(f, CMAP_DISPLAY);
	if (CMAP_TV_MARK_OF(w) != CMAP_TV_MARK)
		return -1;
	return (w & CMAP_TV_COLOR) != 0;
}

int color_map_read(struct color_map_face *f, uint8_t map[CMAP_COLORS][CMAP_CHANNELS])
{
	int any = 0;
	for (int c = 0; c < CMAP_COLORS; ++c) {
		const uint32_t w = f->read(f, CMAP_WORD(1, c));
		map[c][0] = (uint8_t)CMAP_RED(w);
		map[c][1] = (uint8_t)CMAP_GREEN(w);
		map[c][2] = (uint8_t)CMAP_BLUE(w);
		if (map[c][0] || map[c][1] || map[c][2])
			any = 1;
	}
	return any;
}
