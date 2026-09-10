// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack: a file of 1,024-byte blocks in muir's format, the two tables
// beside it, and the sidecar file that makes the tables persist.
//
// muir's `disk_unit::Unit` is the reference and this follows it line for
// line.  The file holds each block's 256 words low byte first, block `lba`
// at byte `lba * 1024`, and is exactly the size the geometry implies ---
// `Unit::open_with` refuses any other size, and so does `pack_open`, which
// tells a T-80 from a T-300 by that size alone.  Beside the file muir keeps
// `headers` and `data_checkwords`: the sectors a Write All laid down with
// something other than the format's own header and checkwords, which is
// the only way a pack can disagree with itself.  `pack_record` and
// `pack_writeback` consult and maintain them exactly as `Unit::header_at`,
// `Unit::data_checkword_at` and `Unit::write_sector_at` do.  So a pack muir
// wrote reads identically here, and a pack this wrote reads identically in
// muir.
//
// **THE SIDECAR.**  muir keeps the two tables in memory and in a checkpoint
// only; on the board a pack the CADR has written must survive a reboot
// exactly (decided by Mete, 10 Sep: "ok we can use a sidecar file also"),
// so the tables also go to a file beside the pack, `pack.meta` beside
// `pack.img` --- `meta` being `rtl/cadr_disk_pack.sv`'s own word for the
// two-beat burst that carries these three words after the block, not a new
// one.  The format, everything little-endian as the pack's own words are:
//
//     bytes 0..7    "CADRMETA"
//     8..11         version, 1
//     12..15        cylinders     } the geometry the file is sized by
//     16..19        heads         }
//     20..23        blocks a track}
//     24..31        zero
//     32 + 16*lba   one entry a block, for every block of the pack:
//                     +0  the header word the sector was laid with
//                     +4  its header checkword
//                     +8  the data checkword the sector was laid with
//                     +12 flags: bit 0 the header entry is live (the sector
//                         carries a header that is not the format's own),
//                         bit 1 the data checkword entry is live (it does
//                         not check over the data); other bits zero
//
// An entry with both flag bits clear is a block as the format lays it ---
// `header_of` with the code over it, and the code over the data --- so a
// file of zeros means what an absent file means.  **THE SIDECAR IS SAFE TO
// DELETE** (Mete, 10 Sep): absent, every block's header and checkwords are
// as the format lays them for a fresh pack, which is muir's fresh-pack
// state; the program says so once and creates the file on the first
// write-back, not before, so a pack nothing writes never grows one and
// `rm pack.meta` is how a pack's tables are reset.  A sidecar that does not
// match the pack --- not this magic or version, a size other than the
// geometry's, or a pack file NEWER than it (a pack copied over while an old
// sidecar stayed) --- is REFUSED, one line naming the two files and the
// mismatch, and treated as absent only if the caller asks
// (`PACK_OPEN_REPLACE_META`), never silently.  The newer-than test is on
// modification times, which the card's FAT keeps to two seconds; a write-back
// touches the pack first and the sidecar after, so a pack the feeder wrote is
// never newer than its sidecar, and a copy that preserved an old time on the
// pack file is the one case it cannot see.  The entry is written on every
// write-back, after the data and with the same `fdatasync` discipline, at
// the one offset its block owns: a 16-byte write that either lands or does
// not, and a power loss between the data and the entry leaves the block
// with its previous header and checkword state, which is the caveat muir's
// in-memory tables carry across a restart in a stronger form.  4,211,952
// bytes for a T-300, 1,108,512 for a T-80.

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

// The sidecar.
#define PACK_META_MAGIC        "CADRMETA"
#define PACK_META_VERSION      1u
#define PACK_META_HEADER_BYTES 32u
#define PACK_META_ENTRY_BYTES  16u
#define PACK_META_HEADER_LAID  1u
#define PACK_META_DCK_LAID     2u

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
	// The sidecar: its path (empty for none), its descriptor once it exists
	// (-1 until the first write-back creates it, or for none), and what
	// `pack_open` found.
	char meta_path[4096];
	int meta_fd;
	enum { PACK_META_NONE, PACK_META_ABSENT, PACK_META_READ, PACK_META_REPLACED } meta_state;
	// Read from the sidecar at open: how many entries of each kind were live.
	size_t meta_headers_read, meta_dcks_read;
};

// Flags for `pack_open_with`.
#define PACK_OPEN_WRITABLE      1
// A sidecar that does not match the pack is treated as absent --- and
// replaced at the first write-back --- instead of refusing the open.
#define PACK_OPEN_REPLACE_META  2

// Opens the file and tells its geometry from its size; reads the sidecar
// beside it if there is one (`pack.img` -> `pack.meta`; any other name gets
// `.meta` appended), refusing one that does not match.  Returns 0, or -1
// with `err` saying why.
int pack_open(struct pack *p, const char *path, int writable, char *err, size_t errlen);
// The same with the sidecar named and the flags above: `meta_path` NULL
// derives it as above, "" means no sidecar at all --- the tables live for
// the run only, as muir's do.
int pack_open_with(struct pack *p, const char *path, const char *meta_path, int flags,
		   char *err, size_t errlen);
void pack_close(struct pack *p);

// The sidecar's size for a geometry, and the derived name.
uint64_t pack_meta_bytes(const struct pack_geometry *g);
void pack_meta_name(const char *path, char *out, size_t outlen);

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
// `Unit::write_sector_at` does, and the tables' entry for the block into
// the sidecar.  Synced to the medium before it returns.
int pack_writeback(struct pack *p, uint32_t lba, const uint32_t words[PACK_RECORD_WORDS], char *err, size_t errlen);

#endif
