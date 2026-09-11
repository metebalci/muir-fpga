// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// SHA-256, FIPS 180-4, over a stream.
//
// **WHY THIS AND NOT SOMETHING CHEAPER.**  The digest in a checkpoint's
// sidecar exists so that somebody holding a pack and a checkpoint, on a
// machine that has neither this program nor the board, can ask whether they
// belong together.  A bespoke checksum would answer that only to a program
// that has this source; `sha256sum` is on the board's BusyBox, on every
// build host and in every operating system anyone will resume a checkpoint
// on, so the sidecar's digests can be checked with one command and no
// software of ours.  That is worth the fifteen milliseconds a megabyte.
//
// It is a transcription of the standard and is held to the standard's own
// vectors in `checkpoint_test.c` --- the empty string, "abc", the 56-byte
// message and a million 'a's --- because a hash that is self-consistently
// wrong agrees with itself perfectly and with nobody else, which is the
// exact failure this file exists to avoid.

#ifndef SHA256_H
#define SHA256_H

#include <stddef.h>
#include <stdint.h>

#define SHA256_BYTES 32u
// 64 hex digits and the terminator.
#define SHA256_HEX 65u

struct sha256 {
	uint32_t h[8];
	uint64_t bits;
	uint8_t block[64];
	size_t have;
};

void sha256_init(struct sha256 *s);
void sha256_feed(struct sha256 *s, const void *data, size_t n);
// Ends the digest into `out`, which is `SHA256_BYTES` long.  The state is
// spent afterwards.
void sha256_end(struct sha256 *s, uint8_t *out);
// The digest as the sixty-four lower-case hex digits `sha256sum` prints.
void sha256_hex(const uint8_t *digest, char *out);

// A whole file, read in order.  Returns 0 with the hex digest in `hex` and
// the file's length in `*bytes`, or -1 with errno set --- and on -1 nothing
// is written to either, so a caller cannot mistake a partial read for a
// digest.
int sha256_file(const char *path, char *hex, uint64_t *bytes);

#endif
