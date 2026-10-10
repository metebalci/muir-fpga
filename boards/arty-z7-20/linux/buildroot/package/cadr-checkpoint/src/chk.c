// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// muir's checkpoint format, written from C.  `chk.h` says what and why.

#include "chk.h"

#include <errno.h>
#include <stdint.h>
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
	w->word_bytes = 4;
	w->version = 0;
	w->hole = NULL;
	w->hole_at = 0;
	w->hole_len = 0;
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

void chk_word(struct chk *w, uint64_t v)
{
	uint8_t b[8];
	for (unsigned i = 0; i < w->word_bytes; ++i)
		b[i] = (uint8_t)(v >> (8 * i));
	put(w, b, w->word_bytes);
}

void chk_words(struct chk *w, const uint64_t *v, size_t n)
{
	chk_u64(w, (uint64_t)n);
	for (size_t i = 0; i < n; ++i)
		chk_word(w, v[i]);
}

void chk_hole(struct chk *w, const volatile uint8_t *bytes, size_t n)
{
	if (w->hole)
		w->broken = 1;	/* one hole a body */
	w->hole = bytes;
	w->hole_at = w->len;
	w->hole_len = n;
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
//
// **THE BODY IS READ THROUGH A SOURCE, AND THE FILE WRITTEN THROUGH A SINK.**
// A 32-bit machine's body is one buffer.  Revision 13's is a buffer with a
// hole in it where main memory goes (`chk_hole`), filled by main memory's
// bytes where they stand --- on a board the DDR mapping, 160 MB at 32M words
// --- so that neither a copy of it nor a packed copy of the whole body is
// ever held: the packer reads the hole twice, once to find where a literal
// run ends and once to copy it, and writes the file as it goes.  The runs are
// muir's `pack`'s whatever the source, so the file is the same bytes either
// way.

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

// Where the packed bytes go: a buffer, or a file.
struct sink {
	struct buf *b;
	FILE *f;
	int broken;
};

static void sput(struct sink *k, const void *d, size_t n)
{
	if (k->b)
		bput(k->b, d, n);
	else if (!k->broken && n && fwrite(d, 1, n, k->f) != n)
		k->broken = 1;
}

static void varint(struct sink *k, uint64_t v)
{
	for (;;) {
		uint8_t byte = (uint8_t)(v & 0x7f);
		v >>= 7;
		if (v == 0) {
			sput(k, &byte, 1);
			return;
		}
		byte |= 0x80;
		sput(k, &byte, 1);
	}
}

// The body as one run of bytes: `a` then the hole then `b`.  The hole is read
// a block at a time, aligned 32-bit words where the whole word is the hole's
// (`cadr_mem.h`: device memory takes naturally aligned accesses), into
// `block`; a block's base is a multiple of `SRC_BLOCK` from the hole's start,
// which is page-aligned on a board.
#define SRC_BLOCK 4096u
struct src {
	const uint8_t *a;
	size_t alen;
	const volatile uint8_t *h;
	size_t hlen;
	const uint8_t *b;
	size_t blen;
	size_t len;
	uint8_t block[SRC_BLOCK];
	size_t block_at;	/* the hole's offset of `block`, or SIZE_MAX */
};

static void src_load(struct src *s, size_t at)
{
	const size_t n = s->hlen - at < SRC_BLOCK ? s->hlen - at : SRC_BLOCK;
	size_t o = 0;
	for (; o < n && ((uintptr_t)(s->h + at + o) & 3u); ++o)
		s->block[o] = s->h[at + o];
	for (; o + 4u <= n; o += 4u) {
		const uint32_t v = *(const volatile uint32_t *)(const volatile void *)(s->h + at + o);
		s->block[o] = (uint8_t)v, s->block[o + 1] = (uint8_t)(v >> 8);
		s->block[o + 2] = (uint8_t)(v >> 16), s->block[o + 3] = (uint8_t)(v >> 24);
	}
	for (; o < n; ++o)
		s->block[o] = s->h[at + o];
	s->block_at = at;
}

static uint8_t src_at(struct src *s, size_t i)
{
	if (i < s->alen)
		return s->a[i];
	i -= s->alen;
	if (i < s->hlen) {
		const size_t at = i - i % SRC_BLOCK;
		if (s->block_at != at)
			src_load(s, at);
		return s->block[i - at];
	}
	return s->b[i - s->hlen];
}

// Bytes `from` to `from + n` of the source into the sink.
static void src_copy(struct src *s, size_t from, size_t n, struct sink *k)
{
	while (n) {
		size_t take;
		if (from < s->alen) {
			take = s->alen - from < n ? s->alen - from : n;
			sput(k, s->a + from, take);
		} else if (from - s->alen < s->hlen) {
			const size_t i = from - s->alen, at = i - i % SRC_BLOCK;
			if (s->block_at != at)
				src_load(s, at);
			const size_t in = SRC_BLOCK - (i - at) < s->hlen - i ? SRC_BLOCK - (i - at) : s->hlen - i;
			take = in < n ? in : n;
			sput(k, s->block + (i - at), take);
		} else {
			take = n;
			sput(k, s->b + (from - s->alen - s->hlen), take);
		}
		from += take;
		n -= take;
	}
}

static size_t zeros_at(struct src *s, size_t i)
{
	size_t n = 0;
	while (i + n < s->len && src_at(s, i + n) == 0)
		++n;
	return n;
}

// muir's `pack`, run for run.  A zero run shorter than `MIN_ZERO_RUN` stays
// inside the literal block it falls in; a longer one ends it.  A body that
// ends in zeros emits a final pair with no literals.
static void pack(struct src *s, struct sink *k)
{
	size_t i = 0;
	while (i < s->len) {
		size_t zeros = zeros_at(s, i);
		i += zeros;
		size_t start = i;
		while (i < s->len) {
			if (src_at(s, i) != 0) {
				++i;
				continue;
			}
			size_t run = zeros_at(s, i);
			if (run >= CHK_MIN_ZERO_RUN)
				break;
			i += run;
		}
		varint(k, (uint64_t)zeros);
		varint(k, (uint64_t)(i - start));
		src_copy(s, start, i - start, k);
	}
}

static struct src *src_of(const struct chk *w)
{
	struct src *s = malloc(sizeof *s);
	if (!s)
		return NULL;
	const size_t at = w->hole ? w->hole_at : w->len;
	*s = (struct src){ .a = w->p, .alen = at, .h = w->hole, .hlen = w->hole ? w->hole_len : 0,
			   .b = w->p + at, .blen = w->len - at, .block_at = SIZE_MAX };
	s->len = s->alen + s->hlen + s->blen;
	return s;
}

uint8_t *chk_pack(const uint8_t *raw, size_t len, size_t *out_len)
{
	struct buf out = { NULL, 0, 0, 0 };
	struct sink k = { &out, NULL, 0 };
	struct chk w;
	chk_init(&w);
	w.p = (uint8_t *)raw;
	w.len = len;
	struct src *s = src_of(&w);
	if (!s) {
		*out_len = 0;
		return NULL;
	}
	pack(s, &k);
	free(s);
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
	struct chk head;
	chk_init(&head);
	put(&head, kMagic, sizeof kMagic - 1);
	// The version says the width (muir's `checkpoint::write`): 49 for a
	// machine of 32-bit words, 50 for revision 13's 40.
#if CHK_MUTATE == 31
	chk_u32(&head, CHK_VERSION);
#else
	chk_u32(&head, body->version ? body->version
		       : body->word_bytes == 5 ? CHK_VERSION_40 : CHK_VERSION);
#endif
	size_t n = strlen(engine);
	chk_u8(&head, (uint8_t)n);
	put(&head, engine, n);
	chk_u32(&head, boards);
	struct src *s = src_of(body);
	if (head.broken || !s) {
		free(s);
		chk_free(&head);
		errno = ENOMEM;
		return -1;
	}

	FILE *f = fopen(path, "wb");
	if (!f) {
		free(s);
		chk_free(&head);
		return -1;
	}
	struct sink k = { NULL, f, 0 };
	sput(&k, head.p, head.len);
	pack(s, &k);
	int ok = !k.broken;
	if (fclose(f) != 0)
		ok = 0;
	free(s);
	chk_free(&head);
	if (!ok) {
		if (errno == 0)
			errno = EIO;
		return -1;
	}
	return 0;
}
