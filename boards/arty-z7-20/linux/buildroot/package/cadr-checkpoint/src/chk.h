// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// muir's checkpoint format, written from C.
//
// `../muir/src/checkpoint.rs` is the authority and this is a transcription of
// it, not an interpretation.  A checkpoint is a header --- the magic, the
// format's version, the engine's name and how many memory boards the machine
// had --- and a body packed as runs.  The body is a stream of fixed-width
// little-endian fields in one order, and the matching reader takes them back
// in that order; there is no framing inside it and no checksum over it, so a
// field of the wrong width silently shifts everything after it.
//
// **THE VERSION IS 21 AND A FILE OF ANY OTHER VERSION IS REFUSED BY NAME**,
// which is the one thing that stops a format change here from being read
// wrong somewhere else.  When muir's `checkpoint::VERSION` moves, this file
// moves with it or the board's checkpoints stop loading --- loudly, which is
// the right way round.
//
// **THE PACKING MUST MATCH muir's OWN, NOT MERELY DECODE TO THE SAME BYTES.**
// `unpack` accepts any valid packing, so a lazier writer would still load;
// but muir's own round-trip test is a BYTE COMPARISON of what it re-saves
// against what it read, and that is the only proof available here that every
// field went where it was meant to.  So `chk_pack` below is muir's `pack`
// transcribed greedily, run for run.

#ifndef CHK_H
#define CHK_H

#include <stddef.h>
#include <stdint.h>

// muir's `checkpoint::VERSION`.
#define CHK_VERSION 21u
// muir's `MIN_ZERO_RUN`: the shortest run of zero bytes worth a count.
#define CHK_MIN_ZERO_RUN 4u

// A growable body.  Every put appends; nothing seeks back, because the format
// has no length that has to be filled in afterwards.
struct chk {
	uint8_t *p;
	size_t len, cap;
	// Set once and never cleared: an allocation failed, and every put
	// after it does nothing.  A writer that checked every call would be
	// unreadable, and a truncated file is refused by muir at the first
	// short read.
	int broken;
};

void chk_init(struct chk *w);
void chk_free(struct chk *w);

void chk_u8(struct chk *w, uint8_t v);
void chk_u16(struct chk *w, uint16_t v);
void chk_u32(struct chk *w, uint32_t v);
void chk_u64(struct chk *w, uint64_t v);
void chk_bool(struct chk *w, int v);
// A count, then the items.  The count is a `u64` and is ALWAYS written, even
// in front of an array whose length the reader already knows --- muir's
// `count_for` then refuses any other count, which is what turns a wrong
// length into a message rather than into a shifted file.
void chk_bytes(struct chk *w, const uint8_t *v, size_t n);
void chk_u16s(struct chk *w, const uint16_t *v, size_t n);
void chk_u32s(struct chk *w, const uint32_t *v, size_t n);
void chk_u64s(struct chk *w, const uint64_t *v, size_t n);
// A flag, then the value if there is one.  **muir has three Option encodings
// and only this one omits the value**; the other two write a flag and then
// the value whatever the flag said, and the fields that take them are named
// where they are written.
void chk_opt_u8(struct chk *w, int present, uint8_t v);
void chk_opt_u16(struct chk *w, int present, uint16_t v);
void chk_opt_u64(struct chk *w, int present, uint64_t v);

// `raw` as muir's `pack` writes it: pairs of counts, zeros then literals, each
// an LEB128 varint, and the literal bytes.  The caller owns the result.
uint8_t *chk_pack(const uint8_t *raw, size_t len, size_t *out_len);

// The whole file: the header naming `engine` and `boards`, then the packed
// body.  Returns 0, or -1 with errno set.
int chk_write_file(const char *path, const char *engine, uint32_t boards,
		   const struct chk *body);

#endif
