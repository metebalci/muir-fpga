// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack: a file of 1,024-byte blocks in muir's format, and the two tables
// beside it.
//
// muir's `disk_unit::Unit` is the reference and this follows it line for
// line.  The file holds each block's 256 words low byte first, block `lba`
// at byte `lba * 1024`, and is exactly the size the geometry implies ---
// `Unit::open_with` refuses any other size, and so does `pack_open`, which
// tells a T-80 from a T-300 by that size alone.  Beside the file muir keeps
// `headers` and `data_checkwords`: the sectors a Write All laid down with
// something other than the format's own header and checkwords, which is
// the only way a pack can disagree with itself.  They live in memory for
// the run, as muir's do (a checkpoint carries them; the pack file has no
// room for them), and `pack_record` and `pack_writeback` consult and
// maintain them exactly as `Unit::header_at`, `Unit::data_checkword_at`
// and `Unit::write_sector_at` do.  So a pack muir wrote reads identically
// here, and a pack this wrote reads identically in muir --- with the one
// caveat both share: a sector laid with a header or checkword that is not
// its own forgets that at the next start, and reads as a fresh pack's
// sector, the format's own header and the code over the data.  **A sidecar
// file persisting the two tables was built and then dropped, by Mete on 10
// Sep, once what it preserved was understood**: the pack file is the only
// disk file on the card, and this file holds exactly what muir's `Unit`
// holds.

#ifndef PACK_FILE_H
#define PACK_FILE_H

#include <stddef.h>
#include <stdint.h>

// "Each disk block contains one Lisp Machine page worth of data, i.e. 256.
// words or 1024. bytes."
#define PACK_BLOCK_WORDS 256
#define PACK_BLOCK_BYTES (PACK_BLOCK_WORDS * 4)
// The record the fabric fetches: the block, its header, its header
// checkword and its data checkword.
#define PACK_RECORD_WORDS (PACK_BLOCK_WORDS + 3)

struct pack_geometry {
	uint32_t cylinders, heads, blocks_per_track;
};

// The two drive types the controller was used with; `Geometry::T80` and
// `Geometry::T300`.
extern const struct pack_geometry PACK_T80, PACK_T300;

struct pack_header_entry {
	uint32_t lba, word, checkword;
};
struct pack_dck_entry {
	uint32_t lba, checkword;
};

struct pack {
	int fd;
	int writable;
	struct pack_geometry g;
	uint32_t blocks;
	// `headers`: sectors whose header is not the format's own.
	struct pack_header_entry *headers;
	size_t n_headers, cap_headers;
	// `data_checkwords`: sectors whose data checkword does not check.
	struct pack_dck_entry *dcks;
	size_t n_dcks, cap_dcks;
};

// Opens the file and tells its geometry from its size.  Returns 0, or -1
// with `err` saying why.
int pack_open(struct pack *p, const char *path, int writable, char *err, size_t errlen);
void pack_close(struct pack *p);

// A block number from the start of the pack, or -1 off it.
int pack_lba(const struct pack_geometry *g, uint32_t c, uint32_t h, uint32_t b, uint32_t *lba);
// Back again.
void pack_chb(const struct pack_geometry *g, uint32_t lba, uint32_t *c, uint32_t *h, uint32_t *b);

// `header_of`: what a sector at this address should say, `<31:30>` the
// next-block code, `<27:16>` cylinder, `<15:8>` head, `<7:0>` block.
uint32_t pack_header_of(const struct pack_geometry *g, uint32_t c, uint32_t h, uint32_t b);

// The record of block `lba`, the 259 words the fabric fetches: the data
// from the file, the header and both checkwords from the tables or the
// format.  Returns 0, or -1 with `err`.
int pack_record(struct pack *p, uint32_t lba, uint32_t words[PACK_RECORD_WORDS], char *err, size_t errlen);

// A block the fabric wrote back, the 259 words as the sector now lies:
// the data into the file, the header and checkwords into the tables where
// they are not the format's own and out of them where they are, as
// `Unit::write_sector_at` does.  Synced to the medium before it returns.
int pack_writeback(struct pack *p, uint32_t lba, const uint32_t words[PACK_RECORD_WORDS], char *err, size_t errlen);

#endif
