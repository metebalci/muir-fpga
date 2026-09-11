// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// SHA-256, FIPS 180-4.  `sha256.h` says why it is here.

#include "sha256.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

static const uint32_t K[64] = {
	0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
	0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
	0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
	0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
	0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
	0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
	0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
	0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
	0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
	0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
	0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
	0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
	0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static uint32_t ror(uint32_t x, unsigned n)
{
	return (x >> n) | (x << (32u - n));
}

static void compress(struct sha256 *s, const uint8_t *p)
{
	uint32_t w[64];
	for (unsigned i = 0; i < 16; ++i)
		w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
		       ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
	for (unsigned i = 16; i < 64; ++i) {
		const uint32_t s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
		const uint32_t s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3];
	uint32_t e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
	for (unsigned i = 0; i < 64; ++i) {
		const uint32_t S1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
		const uint32_t ch = (e & f) ^ (~e & g);
		const uint32_t t1 = h + S1 + ch + K[i] + w[i];
		const uint32_t S0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
		const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		const uint32_t t2 = S0 + maj;
		h = g; g = f; f = e; e = d + t1;
		d = c; c = b; b = a; a = t1 + t2;
	}
	s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
	s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

void sha256_init(struct sha256 *s)
{
	static const uint32_t iv[8] = {
		0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
		0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
	};
	memcpy(s->h, iv, sizeof iv);
	s->bits = 0;
	s->have = 0;
}

void sha256_feed(struct sha256 *s, const void *data, size_t n)
{
	const uint8_t *p = data;
	s->bits += (uint64_t)n * 8u;
	while (n) {
		if (s->have == 0 && n >= 64) {
			compress(s, p);
			p += 64;
			n -= 64;
			continue;
		}
		size_t take = 64 - s->have;
		if (take > n)
			take = n;
		memcpy(s->block + s->have, p, take);
		s->have += take;
		p += take;
		n -= take;
		if (s->have == 64) {
			compress(s, s->block);
			s->have = 0;
		}
	}
}

void sha256_end(struct sha256 *s, uint8_t *out)
{
	const uint64_t bits = s->bits;
	static const uint8_t one = 0x80u;
	static const uint8_t zero = 0x00u;
	sha256_feed(s, &one, 1);
	// The length field is the last eight bytes of a block, so pad to 56.
	while (s->have != 56)
		sha256_feed(s, &zero, 1);
	uint8_t len[8];
	for (int i = 0; i < 8; ++i)
		len[i] = (uint8_t)(bits >> (56 - 8 * i));
	// `sha256_feed` would add these eight to `bits` as well, which is
	// harmless: the value has already been taken.
	memcpy(s->block + 56, len, 8);
	compress(s, s->block);
	s->have = 0;
	for (unsigned i = 0; i < 8; ++i) {
		out[4 * i] = (uint8_t)(s->h[i] >> 24);
		out[4 * i + 1] = (uint8_t)(s->h[i] >> 16);
		out[4 * i + 2] = (uint8_t)(s->h[i] >> 8);
		out[4 * i + 3] = (uint8_t)s->h[i];
	}
}

void sha256_hex(const uint8_t *digest, char *out)
{
	static const char d[] = "0123456789abcdef";
	for (unsigned i = 0; i < SHA256_BYTES; ++i) {
		out[2 * i] = d[digest[i] >> 4];
		out[2 * i + 1] = d[digest[i] & 0xFu];
	}
	out[2 * SHA256_BYTES] = '\0';
}

int sha256_file(const char *path, char *hex, uint64_t *bytes)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return -1;
	struct sha256 s;
	sha256_init(&s);
	// A quarter of a megabyte: big enough that the card's own read-ahead
	// is what limits this and not the call, small enough to sit on a
	// stack the board's BusyBox gives a program.
	static uint8_t buf[256 * 1024];
	uint64_t total = 0;
	for (;;) {
		const size_t n = fread(buf, 1, sizeof buf, f);
		if (n == 0)
			break;
		sha256_feed(&s, buf, n);
		total += n;
	}
	// **A SHORT READ IS A FAILURE AND NOT A DIGEST.**  A pack the card
	// cannot read all of would otherwise be bound to a checkpoint by the
	// digest of its readable half, which is a binding that says yes to a
	// pack nobody has.
	if (ferror(f)) {
		const int e = errno;
		fclose(f);
		errno = e;
		return -1;
	}
	if (fclose(f) != 0)
		return -1;
	uint8_t digest[SHA256_BYTES];
	sha256_end(&s, digest);
	sha256_hex(digest, hex);
	*bytes = total;
	return 0;
}
