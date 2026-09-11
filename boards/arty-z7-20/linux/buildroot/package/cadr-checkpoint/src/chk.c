// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// muir's checkpoint format, written from C.  `chk.h` says what and why.

#include "chk.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Sixteen bytes, and the array carries its own terminator so that the
// compiler need not be told the string is not one; `sizeof - 1` is what
// goes in the file.
static const char kMagic[] = "muir checkpoint\n";

void chk_init(struct chk *w)
{
	w->p = NULL;
	w->len = 0;
	w->cap = 0;
	w->broken = 0;
}

void chk_free(struct chk *w)
{
	free(w->p);
	chk_init(w);
}

static void put(struct chk *w, const void *b, size_t n)
{
	if (w->broken)
		return;
	if (w->len + n > w->cap) {
		size_t want = w->cap ? w->cap * 2 : 4096;
		while (want < w->len + n)
			want *= 2;
		uint8_t *q = realloc(w->p, want);
		if (!q) {
			w->broken = 1;
			return;
		}
		w->p = q;
		w->cap = want;
	}
	memcpy(w->p + w->len, b, n);
	w->len += n;
}

void chk_u8(struct chk *w, uint8_t v)
{
	put(w, &v, 1);
}

// Little-endian by construction rather than by the host's byte order: this
// program is built for an Arm and checked on an x86, and a `memcpy` of the
// native word would agree on both today and stop agreeing on the day somebody
// builds it somewhere else.
void chk_u16(struct chk *w, uint16_t v)
{
	uint8_t b[2] = { (uint8_t)v, (uint8_t)(v >> 8) };
	put(w, b, 2);
}

void chk_u32(struct chk *w, uint32_t v)
{
	uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16),
			 (uint8_t)(v >> 24) };
	put(w, b, 4);
}

void chk_u64(struct chk *w, uint64_t v)
{
	uint8_t b[8];
	for (int i = 0; i < 8; ++i)
		b[i] = (uint8_t)(v >> (8 * i));
	put(w, b, 8);
}

void chk_bool(struct chk *w, int v)
{
	// muir refuses any byte but 0 and 1 for a flag, by name.
	chk_u8(w, v ? 1u : 0u);
}

void chk_bytes(struct chk *w, const uint8_t *v, size_t n)
{
	chk_u64(w, (uint64_t)n);
	put(w, v, n);
}

void chk_u16s(struct chk *w, const uint16_t *v, size_t n)
{
	chk_u64(w, (uint64_t)n);
	for (size_t i = 0; i < n; ++i)
		chk_u16(w, v[i]);
}

void chk_u32s(struct chk *w, const uint32_t *v, size_t n)
{
	chk_u64(w, (uint64_t)n);
	for (size_t i = 0; i < n; ++i)
		chk_u32(w, v[i]);
}

void chk_u64s(struct chk *w, const uint64_t *v, size_t n)
{
	chk_u64(w, (uint64_t)n);
	for (size_t i = 0; i < n; ++i)
		chk_u64(w, v[i]);
}

void chk_opt_u8(struct chk *w, int present, uint8_t v)
{
	chk_bool(w, present);
	if (present)
		chk_u8(w, v);
}

void chk_opt_u16(struct chk *w, int present, uint16_t v)
{
	chk_bool(w, present);
	if (present)
		chk_u16(w, v);
}

void chk_opt_u64(struct chk *w, int present, uint64_t v)
{
	chk_bool(w, present);
	if (present)
		chk_u64(w, v);
}

// --- packing ---------------------------------------------------------------

struct buf {
	uint8_t *p;
	size_t len, cap;
	int broken;
};

static void bput(struct buf *b, const void *d, size_t n)
{
	if (b->broken)
		return;
	if (b->len + n > b->cap) {
		size_t want = b->cap ? b->cap * 2 : 4096;
		while (want < b->len + n)
			want *= 2;
		uint8_t *q = realloc(b->p, want);
		if (!q) {
			b->broken = 1;
			return;
		}
		b->p = q;
		b->cap = want;
	}
	memcpy(b->p + b->len, d, n);
	b->len += n;
}

static void varint(struct buf *b, uint64_t v)
{
	for (;;) {
		uint8_t byte = (uint8_t)(v & 0x7f);
		v >>= 7;
		if (v == 0) {
			bput(b, &byte, 1);
			return;
		}
		byte |= 0x80;
		bput(b, &byte, 1);
	}
}

static size_t zeros_at(const uint8_t *raw, size_t len, size_t i)
{
	size_t n = 0;
	while (i + n < len && raw[i + n] == 0)
		++n;
	return n;
}

// muir's `pack`, run for run.  A zero run shorter than `MIN_ZERO_RUN` stays
// inside the literal block it falls in; a longer one ends it.  A body that
// ends in zeros emits a final pair with no literals.
uint8_t *chk_pack(const uint8_t *raw, size_t len, size_t *out_len)
{
	struct buf out = { NULL, 0, 0, 0 };
	size_t i = 0;
	while (i < len) {
		size_t zeros = zeros_at(raw, len, i);
		i += zeros;
		size_t start = i;
		while (i < len) {
			if (raw[i] != 0) {
				++i;
				continue;
			}
			size_t run = zeros_at(raw, len, i);
			if (run >= CHK_MIN_ZERO_RUN)
				break;
			i += run;
		}
		varint(&out, (uint64_t)zeros);
		varint(&out, (uint64_t)(i - start));
		bput(&out, raw + start, i - start);
	}
	if (out.broken) {
		free(out.p);
		*out_len = 0;
		return NULL;
	}
	*out_len = out.len;
	// A body that is entirely empty packs to nothing, which is a legal
	// file: `unpack` of no bytes is no bytes.
	if (!out.p) {
		out.p = malloc(1);
		if (!out.p) {
			*out_len = 0;
			return NULL;
		}
	}
	return out.p;
}

int chk_write_file(const char *path, const char *engine, uint32_t boards,
		   const struct chk *body)
{
	if (body->broken) {
		errno = ENOMEM;
		return -1;
	}
	size_t packed_len = 0;
	uint8_t *packed = chk_pack(body->p, body->len, &packed_len);
	if (!packed) {
		errno = ENOMEM;
		return -1;
	}

	struct chk head;
	chk_init(&head);
	put(&head, kMagic, sizeof kMagic - 1);
	chk_u32(&head, CHK_VERSION);
	size_t n = strlen(engine);
	chk_u8(&head, (uint8_t)n);
	put(&head, engine, n);
	chk_u32(&head, boards);
	if (head.broken) {
		free(packed);
		chk_free(&head);
		errno = ENOMEM;
		return -1;
	}

	FILE *f = fopen(path, "wb");
	if (!f) {
		free(packed);
		chk_free(&head);
		return -1;
	}
	int ok = fwrite(head.p, 1, head.len, f) == head.len &&
		 (packed_len == 0 || fwrite(packed, 1, packed_len, f) == packed_len);
	if (fclose(f) != 0)
		ok = 0;
	free(packed);
	chk_free(&head);
	if (!ok) {
		if (errno == 0)
			errno = EIO;
		return -1;
	}
	return 0;
}
