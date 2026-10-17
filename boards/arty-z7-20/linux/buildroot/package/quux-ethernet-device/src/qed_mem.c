// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Packed storage, a run of words at a time: `quux-file-device`'s way.  Word
// k is the five bytes at 5k, so four words in five straddle a 32-bit boundary
// of the mapping.  Every access to DDR is still naturally aligned
// (`cadr_mem.h`): the run's bytes are moved as aligned 32-bit words where all
// four of them are the run's, and as single bytes at its two ends, and never
// a byte outside it --- a word beside a buffer may be the machine's, and the
// machine may be writing it.

#include "qed_mem.h"

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "packed storage is read and written as little-endian 32-bit words"
#endif

#define PACK_RUN 64u

#ifdef QED_TEST_HOOKS
unsigned long qed_hook_bad_access;
#define ACCESS(b, o, width, lo, hi)                                                                \
	do {                                                                                       \
		if (((uintptr_t)((b) + (o)) & ((width) - 1u)) || (o) < (lo) || (o) + (width) > (hi))  \
			++qed_hook_bad_access;                                                     \
	} while (0)
#else
#define ACCESS(b, o, width, lo, hi) ((void)0)
#endif

static void packed_load(volatile uint8_t *b, size_t lo, size_t hi, uint8_t *img)
{
	size_t o = lo;
	for (; o < hi && (o & 3u); ++o) {
		ACCESS(b, o, 1u, lo, hi);
		*img++ = b[o];
	}
	for (; o + 4u <= hi; o += 4u, img += 4) {
		ACCESS(b, o, 4u, lo, hi);
		const uint32_t v = *(volatile uint32_t *)(void *)(b + o);
		img[0] = (uint8_t)v, img[1] = (uint8_t)(v >> 8), img[2] = (uint8_t)(v >> 16),
		img[3] = (uint8_t)(v >> 24);
	}
	for (; o < hi; ++o) {
		ACCESS(b, o, 1u, lo, hi);
		*img++ = b[o];
	}
}

static void packed_store(volatile uint8_t *b, size_t lo, size_t hi, const uint8_t *img)
{
	size_t o = lo;
	for (; o < hi && (o & 3u); ++o) {
		ACCESS(b, o, 1u, lo, hi);
		b[o] = *img++;
	}
	for (; o + 4u <= hi; o += 4u, img += 4) {
		ACCESS(b, o, 4u, lo, hi);
		*(volatile uint32_t *)(void *)(b + o) = (uint32_t)img[0] | (uint32_t)img[1] << 8 |
							 (uint32_t)img[2] << 16 | (uint32_t)img[3] << 24;
	}
	for (; o < hi; ++o) {
		ACCESS(b, o, 1u, lo, hi);
		b[o] = *img++;
	}
}

void qed_mem_read(struct qed_mem *m, size_t k, size_t n, uint32_t *out)
{
	while (n) {
		const size_t c = n < PACK_RUN ? n : PACK_RUN;
		if (m->touch)
			for (size_t i = 0; i < c; ++i)
				m->touch(m->ctx);
		uint8_t img[5 * PACK_RUN];
		packed_load(m->b, 5 * k, 5 * (k + c), img);
		for (size_t i = 0; i < c; ++i)
			out[i] = (uint32_t)img[5 * i] | (uint32_t)img[5 * i + 1] << 8 |
				 (uint32_t)img[5 * i + 2] << 16 | (uint32_t)img[5 * i + 3] << 24;
		k += c, n -= c, out += c;
	}
}

void qed_mem_write(struct qed_mem *m, size_t k, size_t n, const uint32_t *in)
{
	while (n) {
		const size_t c = n < PACK_RUN ? n : PACK_RUN;
		if (m->touch)
			for (size_t i = 0; i < c; ++i)
				m->touch(m->ctx);
		uint8_t img[5 * PACK_RUN];
		for (size_t i = 0; i < c; ++i) {
			img[5 * i] = (uint8_t)in[i], img[5 * i + 1] = (uint8_t)(in[i] >> 8);
			img[5 * i + 2] = (uint8_t)(in[i] >> 16), img[5 * i + 3] = (uint8_t)(in[i] >> 24);
			img[5 * i + 4] = QED_TAG_FIXNUM;
		}
		packed_store(m->b, 5 * k, 5 * (k + c), img);
		k += c, n -= c, in += c;
	}
}
