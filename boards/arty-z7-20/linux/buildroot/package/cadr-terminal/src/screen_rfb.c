// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// RFC 6143 on the wire; `screen_rfb.h` says what it is and where it came
// from.  Every multi-byte field of this protocol is big-endian, section 7.

#include "screen_rfb.h"

#include <stdio.h>
#include <string.h>

const struct rfb_format RFB_RGB888 = {
	.bits_per_pixel = 32,
	.depth = 24,
	.big_endian = 0,
	.true_colour = 1,
	.red_max = 255, .green_max = 255, .blue_max = 255,
	.red_shift = 16, .green_shift = 8, .blue_shift = 0,
};

static void be16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static void be32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

static uint16_t rd16(const uint8_t *p)
{
	return (uint16_t)((uint16_t)p[0] << 8 | p[1]);
}

static uint32_t rd32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

void rfb_format_encode(const struct rfb_format *f, uint8_t out[16])
{
	memset(out, 0, 16);
	out[0] = f->bits_per_pixel;
	out[1] = f->depth;
	out[2] = f->big_endian != 0;
	out[3] = f->true_colour != 0;
	be16(out + 4, f->red_max);
	be16(out + 6, f->green_max);
	be16(out + 8, f->blue_max);
	out[10] = f->red_shift;
	out[11] = f->green_shift;
	out[12] = f->blue_shift;
	// 13, 14, 15 are padding and stay zero.
}

void rfb_format_parse(const uint8_t in[16], struct rfb_format *f)
{
	f->bits_per_pixel = in[0];
	f->depth = in[1];
	f->big_endian = in[2] != 0;
	f->true_colour = in[3] != 0;
	f->red_max = rd16(in + 4);
	f->green_max = rd16(in + 6);
	f->blue_max = rd16(in + 8);
	f->red_shift = in[10];
	f->green_shift = in[11];
	f->blue_shift = in[12];
}

unsigned rfb_bytes_per_pixel(const struct rfb_format *f)
{
	switch (f->bits_per_pixel) {
	case 8: return 1;
	case 16: return 2;
	case 32: return 4;
	default: return 0;
	}
}

int rfb_format_fits(const struct rfb_format *f)
{
	if (rfb_bytes_per_pixel(f) == 0)
		return 0;
	if (!f->true_colour)
		return 1;
	const unsigned width = f->bits_per_pixel;
	return f->red_shift < width && f->green_shift < width && f->blue_shift < width;
}

uint32_t rfb_white(const struct rfb_format *f)
{
	if (!f->true_colour)
		return RFB_WHITE_INDEX;
	// A shift off the word, which `rfb_format_fits` refuses on arrival,
	// contributes nothing.
	const unsigned width = f->bits_per_pixel;
	uint32_t v = 0;
	if (f->red_shift < width)
		v |= (uint32_t)f->red_max << f->red_shift;
	if (f->green_shift < width)
		v |= (uint32_t)f->green_max << f->green_shift;
	if (f->blue_shift < width)
		v |= (uint32_t)f->blue_max << f->blue_shift;
	return v;
}

uint32_t rfb_black(const struct rfb_format *f)
{
	(void)f;
	return 0;
}

unsigned rfb_put(const struct rfb_format *f, uint8_t *out, uint32_t value)
{
	unsigned n = rfb_bytes_per_pixel(f);
	if (n == 0)
		n = 4;
	uint8_t b[4];
	be32(b, value);
	// The low `n` bytes of the value, most significant first if the viewer
	// asked for big-endian and the other way round if it did not.
	for (unsigned k = 0; k < n; ++k)
		out[k] = f->big_endian ? b[4 - n + k] : b[3 - k];
	return n;
}

size_t rfb_colour_map(uint8_t out[RFB_COLOUR_MAP_BYTES], const uint8_t map[16][3],
		      unsigned values)
{
	if (values > 16)
		values = 16;
	out[0] = 1;			/* message type: SetColourMapEntries */
	out[1] = 0;			/* padding */
	be16(out + 2, 0);		/* first color */
	be16(out + 4, (uint16_t)values);
	for (unsigned v = 0; v < values; ++v) {
		uint8_t *e = out + 6 + v * 6;
		if (values == 2) {
			// The first display board: black at 0 and white at 1.
			const uint16_t w = v ? 0xFFFF : 0;
			be16(e + 0, w);
			be16(e + 2, w);
			be16(e + 4, w);
		} else {
			// The color TV: the map the machine wrote.  **RFB's
			// entries are sixteen bits a gun and the CADR's map is
			// eight**, so a byte is repeated into both halves ---
			// 0xFF becomes 0xFFFF and 0x00 stays 0x0000, which is
			// what makes full and empty come out full and empty.
			for (unsigned k = 0; k < 3; ++k) {
				const uint16_t b = map[v][k];
				be16(e + k * 2, (uint16_t)(b << 8 | b));
			}
		}
	}
	return 6 + (size_t)values * 6;
}

uint32_t rfb_pixel(const struct rfb_format *f, const uint8_t map[16][3], unsigned value,
		   unsigned values)
{
	value &= 15u;
	if (!f->true_colour)
		return value;
	if (values == 2)
		return value ? rfb_white(f) : rfb_black(f);
	// The color TV, in the viewer's own format.  A gun is eight bits here
	// and `red_max` is whatever the viewer asked for, so the byte is
	// scaled into it rather than shifted: a viewer asking for five bits a
	// gun gets 0xFF as 31 and 0x00 as 0.
	uint32_t v = 0;
	const unsigned width = f->bits_per_pixel;
	const uint16_t max[3] = { f->red_max, f->green_max, f->blue_max };
	const uint8_t shift[3] = { f->red_shift, f->green_shift, f->blue_shift };
	for (unsigned k = 0; k < 3; ++k) {
		if (shift[k] >= width)
			continue;
		const uint32_t scaled = ((uint32_t)map[value][k] * max[k] + 127u) / 255u;
		v |= scaled << shift[k];
	}
	return v;
}

enum rfb_version rfb_version_parse(const uint8_t b[12])
{
	if (memcmp(b, "RFB 003.007\n", 12) == 0)
		return RFB_V3_7;
	if (memcmp(b, "RFB 003.008\n", 12) == 0)
		return RFB_V3_8;
	return RFB_V3_3;
}

unsigned rfb_security(enum rfb_version v, uint8_t out[4], int *read_back)
{
	if (v == RFB_V3_3) {
		// 3.3: the type as a word, and nothing to read.
		be32(out, 1);
		*read_back = 0;
		return 4;
	}
	// 3.7 and 3.8: one type on offer, and the viewer names it.
	out[0] = 1;
	out[1] = 1;
	*read_back = 1;
	return 2;
}

int rfb_wants_security_result(enum rfb_version v)
{
	return v == RFB_V3_8;
}

size_t rfb_security_failed(uint8_t *out, const char *reason)
{
	const size_t n = strlen(reason);
	be32(out, 1);
	be32(out + 4, (uint32_t)n);
	memcpy(out + 8, reason, n);
	return 8 + n;
}

int rfb_parse(const uint8_t *buf, size_t len, struct rfb_message *m, size_t *used, const char **why)
{
	static char complaint[64];
	if (len < 1)
		return 0;
	switch (buf[0]) {
	case 0:
		if (len < 20)
			return 0;
		m->kind = RFB_SET_PIXEL_FORMAT;
		rfb_format_parse(buf + 4, &m->format);
		*used = 20;
		return 1;
	case 2: {
		if (len < 4)
			return 0;
		const unsigned count = rd16(buf + 2);
		if (len < 4 + 4 * (size_t)count)
			return 0;
		m->kind = RFB_SET_ENCODINGS;
		m->encoding_count = count < RFB_MAX_ENCODINGS ? count : RFB_MAX_ENCODINGS;
		for (unsigned k = 0; k < m->encoding_count; ++k)
			m->encodings[k] = (int32_t)rd32(buf + 4 + 4 * k);
		*used = 4 + 4 * (size_t)count;
		return 1;
	}
	case 3:
		if (len < 10)
			return 0;
		m->kind = RFB_UPDATE_REQUEST;
		m->incremental = buf[1] != 0;
		m->x = rd16(buf + 2);
		m->y = rd16(buf + 4);
		m->w = rd16(buf + 6);
		m->h = rd16(buf + 8);
		*used = 10;
		return 1;
	case 4:
		if (len < 8)
			return 0;
		m->kind = RFB_KEY;
		m->down = buf[1] != 0;
		m->keysym = rd32(buf + 4);
		*used = 8;
		return 1;
	case 5:
		if (len < 6)
			return 0;
		m->kind = RFB_POINTER;
		m->buttons = buf[1];
		m->x = rd16(buf + 2);
		m->y = rd16(buf + 4);
		*used = 6;
		return 1;
	case 6:
		if (len < 8)
			return 0;
		m->kind = RFB_CUT_TEXT;
		m->len = rd32(buf + 4);
		*used = 8;
		return 1;
	default:
		snprintf(complaint, sizeof complaint,
			 "message type %u, whose length RFC 6143 does not give", buf[0]);
		*why = complaint;
		return -1;
	}
}

size_t rfb_server_init(uint8_t *out, uint16_t width, uint16_t height, const char *name)
{
	const size_t n = strlen(name);
	be16(out, width);
	be16(out + 2, height);
	rfb_format_encode(&RFB_RGB888, out + 4);
	be32(out + 20, (uint32_t)n);
	memcpy(out + 24, name, n);
	return 24 + n;
}

void rfb_update_header(uint8_t out[4], uint16_t rectangles)
{
	out[0] = 0;			/* message type: FramebufferUpdate */
	out[1] = 0;			/* padding */
	be16(out + 2, rectangles);
}

void rfb_rectangle_header(uint8_t out[12], uint16_t x, uint16_t y, uint16_t w, uint16_t h,
			  int32_t encoding)
{
	be16(out, x);
	be16(out + 2, y);
	be16(out + 4, w);
	be16(out + 6, h);
	be32(out + 8, (uint32_t)encoding);
}
