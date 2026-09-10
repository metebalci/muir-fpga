// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack file, its two tables and the sidecar that keeps them;
// `pack_file.h` says what and why.

#include "pack_file.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "pack_ecc.h"

const struct pack_geometry PACK_T80 = { 815, 5, 17 };
const struct pack_geometry PACK_T300 = { 815, 19, 17 };

static uint64_t pack_bytes_of(const struct pack_geometry *g)
{
	return (uint64_t)g->cylinders * g->heads * g->blocks_per_track * PACK_BLOCK_BYTES;
}

uint64_t pack_meta_bytes(const struct pack_geometry *g)
{
	return PACK_META_HEADER_BYTES + (uint64_t)g->cylinders * g->heads * g->blocks_per_track * PACK_META_ENTRY_BYTES;
}

void pack_meta_name(const char *path, char *out, size_t outlen)
{
	const size_t n = strlen(path);
	if (n >= 4 && strcmp(path + n - 4, ".img") == 0)
		snprintf(out, outlen, "%.*s.meta", (int)(n - 4), path);
	else
		snprintf(out, outlen, "%s.meta", path);
}

// ---- little-endian words, as the pack's own are -----------------------
static uint32_t rd32(const uint8_t *b)
{
	return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}
static void wr32(uint8_t *b, uint32_t v)
{
	for (int j = 0; j < 4; ++j)
		b[j] = (uint8_t)(v >> (8 * j));
}

// ---- the tables: tiny, linear, as muir's HashMaps are in effect ---------
static struct pack_header_entry *header_find(struct pack *p, uint32_t lba)
{
	for (size_t i = 0; i < p->n_headers; ++i)
		if (p->headers[i].lba == lba)
			return &p->headers[i];
	return NULL;
}
static struct pack_dck_entry *dck_find(struct pack *p, uint32_t lba)
{
	for (size_t i = 0; i < p->n_dcks; ++i)
		if (p->dcks[i].lba == lba)
			return &p->dcks[i];
	return NULL;
}
static void header_remove(struct pack *p, uint32_t lba)
{
	struct pack_header_entry *e = header_find(p, lba);
	if (e)
		*e = p->headers[--p->n_headers];
}
static void dck_remove(struct pack *p, uint32_t lba)
{
	struct pack_dck_entry *e = dck_find(p, lba);
	if (e)
		*e = p->dcks[--p->n_dcks];
}
static int header_insert(struct pack *p, uint32_t lba, uint32_t word, uint32_t checkword)
{
	struct pack_header_entry *e = header_find(p, lba);
	if (!e) {
		if (p->n_headers == p->cap_headers) {
			size_t cap = p->cap_headers ? 2 * p->cap_headers : 16;
			void *n = realloc(p->headers, cap * sizeof *p->headers);
			if (!n)
				return -1;
			p->headers = n;
			p->cap_headers = cap;
		}
		e = &p->headers[p->n_headers++];
		e->lba = lba;
	}
	e->word = word;
	e->checkword = checkword;
	return 0;
}
static int dck_insert(struct pack *p, uint32_t lba, uint32_t checkword)
{
	struct pack_dck_entry *e = dck_find(p, lba);
	if (!e) {
		if (p->n_dcks == p->cap_dcks) {
			size_t cap = p->cap_dcks ? 2 * p->cap_dcks : 16;
			void *n = realloc(p->dcks, cap * sizeof *p->dcks);
			if (!n)
				return -1;
			p->dcks = n;
			p->cap_dcks = cap;
		}
		e = &p->dcks[p->n_dcks++];
		e->lba = lba;
	}
	e->checkword = checkword;
	return 0;
}

// ---- the sidecar ----------------------------------------------------------

// Reads a sidecar that is there into the tables.  Returns 0; 1 if it does
// not match the pack, with `err` naming the two files and the mismatch; -1
// on an I/O failure.
static int meta_read(struct pack *p, const char *path, const struct stat *pack_st, char *err, size_t errlen)
{
	int fd = open(p->meta_path, O_RDONLY);
	if (fd < 0) {
		snprintf(err, errlen, "%s: %s", p->meta_path, strerror(errno));
		return -1;
	}
	struct stat st;
	if (fstat(fd, &st) < 0) {
		snprintf(err, errlen, "%s: %s", p->meta_path, strerror(errno));
		close(fd);
		return -1;
	}
	if ((uint64_t)st.st_size != pack_meta_bytes(&p->g)) {
		snprintf(err, errlen, "%s does not match %s: %lld bytes, and a sidecar for %u cylinders, %u heads, %u blocks a track is %llu",
			 p->meta_path, path, (long long)st.st_size, p->g.cylinders, p->g.heads, p->g.blocks_per_track,
			 (unsigned long long)pack_meta_bytes(&p->g));
		close(fd);
		return 1;
	}
	uint8_t hdr[PACK_META_HEADER_BYTES];
	if (pread(fd, hdr, sizeof hdr, 0) != (ssize_t)sizeof hdr) {
		snprintf(err, errlen, "%s: reading the header: %s", p->meta_path, strerror(errno));
		close(fd);
		return -1;
	}
	if (memcmp(hdr, PACK_META_MAGIC, 8) != 0) {
		snprintf(err, errlen, "%s does not match %s: it does not begin with %s", p->meta_path, path, PACK_META_MAGIC);
		close(fd);
		return 1;
	}
	if (rd32(hdr + 8) != PACK_META_VERSION) {
		snprintf(err, errlen, "%s does not match %s: version %u, and this program writes version %u",
			 p->meta_path, path, rd32(hdr + 8), PACK_META_VERSION);
		close(fd);
		return 1;
	}
	if (rd32(hdr + 12) != p->g.cylinders || rd32(hdr + 16) != p->g.heads || rd32(hdr + 20) != p->g.blocks_per_track) {
		snprintf(err, errlen, "%s does not match %s: it says %u cylinders, %u heads, %u blocks a track and the pack is %u, %u, %u",
			 p->meta_path, path, rd32(hdr + 12), rd32(hdr + 16), rd32(hdr + 20),
			 p->g.cylinders, p->g.heads, p->g.blocks_per_track);
		close(fd);
		return 1;
	}
	// A pack file newer than its sidecar was copied over while the sidecar
	// stayed: the entries are another pack's.
	if (pack_st->st_mtime > st.st_mtime) {
		snprintf(err, errlen, "%s does not match %s: the pack file is newer than its sidecar (%lld against %lld); a pack copied in beside an old sidecar",
			 p->meta_path, path, (long long)pack_st->st_mtime, (long long)st.st_mtime);
		close(fd);
		return 1;
	}
	// The entries, a block at a time into the tables where they are live.
	uint8_t buf[PACK_META_ENTRY_BYTES * 256];
	for (uint32_t lba = 0; lba < p->blocks; lba += 256) {
		const uint32_t n = (p->blocks - lba < 256) ? p->blocks - lba : 256;
		const ssize_t want = (ssize_t)(n * PACK_META_ENTRY_BYTES);
		if (pread(fd, buf, (size_t)want, (off_t)PACK_META_HEADER_BYTES + (off_t)lba * PACK_META_ENTRY_BYTES) != want) {
			snprintf(err, errlen, "%s: reading the entries at block %u: %s", p->meta_path, lba, strerror(errno));
			close(fd);
			return -1;
		}
		for (uint32_t i = 0; i < n; ++i) {
			const uint8_t *e = buf + i * PACK_META_ENTRY_BYTES;
			const uint32_t flags = rd32(e + 12);
			if (flags & PACK_META_HEADER_LAID) {
				if (header_insert(p, lba + i, rd32(e), rd32(e + 4)) < 0) {
					snprintf(err, errlen, "out of memory for the header table");
					close(fd);
					return -1;
				}
				++p->meta_headers_read;
			}
			if (flags & PACK_META_DCK_LAID) {
				if (dck_insert(p, lba + i, rd32(e + 8)) < 0) {
					snprintf(err, errlen, "out of memory for the checkword table");
					close(fd);
					return -1;
				}
				++p->meta_dcks_read;
			}
		}
	}
	close(fd);
	return 0;
}

// Creates the sidecar --- the header, then zeros for every block --- on the
// first write-back, or rewrites a mismatched one the caller asked to
// replace.  Synced before it returns.
static int meta_create(struct pack *p, char *err, size_t errlen)
{
	int fd = open(p->meta_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		snprintf(err, errlen, "creating %s: %s", p->meta_path, strerror(errno));
		return -1;
	}
	uint8_t hdr[PACK_META_HEADER_BYTES];
	memset(hdr, 0, sizeof hdr);
	memcpy(hdr, PACK_META_MAGIC, 8);
	wr32(hdr + 8, PACK_META_VERSION);
	wr32(hdr + 12, p->g.cylinders);
	wr32(hdr + 16, p->g.heads);
	wr32(hdr + 20, p->g.blocks_per_track);
	if (pwrite(fd, hdr, sizeof hdr, 0) != (ssize_t)sizeof hdr) {
		snprintf(err, errlen, "writing %s: %s", p->meta_path, strerror(errno));
		close(fd);
		return -1;
	}
	// Zeros, written rather than left to ftruncate: FAT has no holes and a
	// file of zeros is what "every block as the format lays it" is.
	uint8_t zeros[PACK_META_ENTRY_BYTES * 4096];
	memset(zeros, 0, sizeof zeros);
	uint64_t left = pack_meta_bytes(&p->g) - PACK_META_HEADER_BYTES;
	off_t at = PACK_META_HEADER_BYTES;
	while (left > 0) {
		const size_t n = left < sizeof zeros ? (size_t)left : sizeof zeros;
		if (pwrite(fd, zeros, n, at) != (ssize_t)n) {
			snprintf(err, errlen, "writing %s: %s", p->meta_path, strerror(errno));
			close(fd);
			return -1;
		}
		at += (off_t)n;
		left -= n;
	}
	if (fdatasync(fd) < 0 && errno != EINVAL) {
		snprintf(err, errlen, "syncing %s: %s", p->meta_path, strerror(errno));
		close(fd);
		return -1;
	}
	p->meta_fd = fd;
	return 0;
}

// The block's entry, from the tables as they stand, into the sidecar.
static int meta_write_entry(struct pack *p, uint32_t lba, char *err, size_t errlen)
{
	uint8_t e[PACK_META_ENTRY_BYTES];
	memset(e, 0, sizeof e);
	uint32_t flags = 0;
	const struct pack_header_entry *he = header_find(p, lba);
	if (he) {
		wr32(e, he->word);
		wr32(e + 4, he->checkword);
		flags |= PACK_META_HEADER_LAID;
	}
	const struct pack_dck_entry *de = dck_find(p, lba);
	if (de) {
		wr32(e + 8, de->checkword);
		flags |= PACK_META_DCK_LAID;
	}
	wr32(e + 12, flags);
	if (pwrite(p->meta_fd, e, sizeof e, (off_t)PACK_META_HEADER_BYTES + (off_t)lba * PACK_META_ENTRY_BYTES) != (ssize_t)sizeof e) {
		snprintf(err, errlen, "writing block %u's entry of %s: %s", lba, p->meta_path, strerror(errno));
		return -1;
	}
	if (fdatasync(p->meta_fd) < 0 && errno != EINVAL) {
		snprintf(err, errlen, "syncing %s: %s", p->meta_path, strerror(errno));
		return -1;
	}
	return 0;
}

// ---- the pack ---------------------------------------------------------------

int pack_open(struct pack *p, const char *path, int writable, char *err, size_t errlen)
{
	return pack_open_with(p, path, NULL, writable ? PACK_OPEN_WRITABLE : 0, err, errlen);
}

int pack_open_with(struct pack *p, const char *path, const char *meta_path, int flags,
		   char *err, size_t errlen)
{
	const int writable = (flags & PACK_OPEN_WRITABLE) != 0;
	memset(p, 0, sizeof *p);
	p->meta_fd = -1;
	p->fd = open(path, writable ? O_RDWR : O_RDONLY);
	if (p->fd < 0) {
		snprintf(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	struct stat st;
	if (fstat(p->fd, &st) < 0) {
		snprintf(err, errlen, "%s: %s", path, strerror(errno));
		close(p->fd);
		return -1;
	}
	// The size is what ties the geometry to the image: muir's `open_with`
	// refuses any other size, and the two types differ in theirs.
	if ((uint64_t)st.st_size == pack_bytes_of(&PACK_T300))
		p->g = PACK_T300;
	else if ((uint64_t)st.st_size == pack_bytes_of(&PACK_T80))
		p->g = PACK_T80;
	else {
		snprintf(err, errlen, "%s: %lld bytes, which is neither a T-300 (%llu) nor a T-80 (%llu)",
			 path, (long long)st.st_size,
			 (unsigned long long)pack_bytes_of(&PACK_T300),
			 (unsigned long long)pack_bytes_of(&PACK_T80));
		close(p->fd);
		return -1;
	}
	p->writable = writable;
	p->blocks = p->g.cylinders * p->g.heads * p->g.blocks_per_track;
	// The sidecar.
	if (meta_path == NULL)
		pack_meta_name(path, p->meta_path, sizeof p->meta_path);
	else
		snprintf(p->meta_path, sizeof p->meta_path, "%s", meta_path);
	if (p->meta_path[0] == 0) {
		p->meta_state = PACK_META_NONE;
		return 0;
	}
	struct stat mst;
	if (stat(p->meta_path, &mst) < 0) {
		if (errno != ENOENT) {
			snprintf(err, errlen, "%s: %s", p->meta_path, strerror(errno));
			close(p->fd);
			return -1;
		}
		p->meta_state = PACK_META_ABSENT;
		return 0;
	}
	const int r = meta_read(p, path, &st, err, errlen);
	if (r < 0) {
		pack_close(p);
		return -1;
	}
	if (r > 0) {
		if (!(flags & PACK_OPEN_REPLACE_META)) {
			pack_close(p);
			return -1;
		}
		// Asked to: the tables empty, the file rewritten at the first
		// write-back.  Nothing read into the tables above survives.
		p->n_headers = p->n_dcks = 0;
		p->meta_headers_read = p->meta_dcks_read = 0;
		p->meta_state = PACK_META_REPLACED;
		return 0;
	}
	// Read: kept open for the write-backs.
	if (writable) {
		p->meta_fd = open(p->meta_path, O_RDWR);
		if (p->meta_fd < 0) {
			snprintf(err, errlen, "%s: %s", p->meta_path, strerror(errno));
			pack_close(p);
			return -1;
		}
	}
	p->meta_state = PACK_META_READ;
	return 0;
}

void pack_close(struct pack *p)
{
	if (p->fd >= 0)
		close(p->fd);
	if (p->meta_fd >= 0)
		close(p->meta_fd);
	free(p->headers);
	free(p->dcks);
	memset(p, 0, sizeof *p);
	p->fd = -1;
	p->meta_fd = -1;
}

int pack_lba(const struct pack_geometry *g, uint32_t c, uint32_t h, uint32_t b, uint32_t *lba)
{
	if (c >= g->cylinders || h >= g->heads || b >= g->blocks_per_track)
		return -1;
	*lba = c * g->heads * g->blocks_per_track + h * g->blocks_per_track + b;
	return 0;
}

void pack_chb(const struct pack_geometry *g, uint32_t lba, uint32_t *c, uint32_t *h, uint32_t *b)
{
	const uint32_t per_cyl = g->heads * g->blocks_per_track;
	*c = lba / per_cyl;
	*h = (lba % per_cyl) / g->blocks_per_track;
	*b = lba % g->blocks_per_track;
}

// `format::next_block_code`: "0 following block on same track, 1 block 0
// on next track (next head), 2 block 0 on head 0 of next cylinder", 3 at
// the end of the pack.
static uint32_t next_block_code(const struct pack_geometry *g, uint32_t c, uint32_t h, uint32_t b)
{
	if (b + 1 < g->blocks_per_track)
		return 0;
	if (h + 1 < g->heads)
		return 1;
	if (c + 1 < g->cylinders)
		return 2;
	return 3;
}

uint32_t pack_header_of(const struct pack_geometry *g, uint32_t c, uint32_t h, uint32_t b)
{
	return next_block_code(g, c, h, b) << 30 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
}

int pack_record(struct pack *p, uint32_t lba, uint32_t words[PACK_RECORD_WORDS], char *err, size_t errlen)
{
	if (lba >= p->blocks) {
		snprintf(err, errlen, "block %u is off a pack of %u", lba, p->blocks);
		return -1;
	}
	// `Unit::file_block`: 1,024 bytes at lba * 1024, each word low byte
	// first.
	uint8_t bytes[PACK_BLOCK_BYTES];
	ssize_t n = pread(p->fd, bytes, sizeof bytes, (off_t)lba * PACK_BLOCK_BYTES);
	if (n != (ssize_t)sizeof bytes) {
		snprintf(err, errlen, "reading block %u of the pack: %s", lba,
			 n < 0 ? strerror(errno) : "short read");
		return -1;
	}
	for (int i = 0; i < PACK_BLOCK_WORDS; ++i)
		words[i] = rd32(bytes + 4 * i);
	// `Unit::header_at`: what a Write All laid, or `header_of` with a
	// checkword over it.
	const struct pack_header_entry *he = header_find(p, lba);
	if (he) {
		words[256] = he->word;
		words[257] = he->checkword;
	} else {
		uint32_t c, h, b;
		pack_chb(&p->g, lba, &c, &h, &b);
		words[256] = pack_header_of(&p->g, c, h, b);
		words[257] = ecc_over_words(&words[256], 1);
	}
	// `Unit::data_checkword_at`: what a Write All laid, or the one over
	// the data now.
	const struct pack_dck_entry *de = dck_find(p, lba);
	words[258] = de ? de->checkword : ecc_over_words(words, PACK_BLOCK_WORDS);
	return 0;
}

int pack_writeback(struct pack *p, uint32_t lba, const uint32_t words[PACK_RECORD_WORDS], char *err, size_t errlen)
{
	if (lba >= p->blocks) {
		snprintf(err, errlen, "block %u is off a pack of %u", lba, p->blocks);
		return -1;
	}
	if (!p->writable) {
		snprintf(err, errlen, "the pack is open read-only");
		return -1;
	}
	// `Unit::write_sector_at`: the data into the file ...
	uint8_t bytes[PACK_BLOCK_BYTES];
	for (int i = 0; i < PACK_BLOCK_WORDS; ++i)
		wr32(bytes + 4 * i, words[i]);
	ssize_t n = pwrite(p->fd, bytes, sizeof bytes, (off_t)lba * PACK_BLOCK_BYTES);
	if (n != (ssize_t)sizeof bytes) {
		snprintf(err, errlen, "writing block %u of the pack: %s", lba,
			 n < 0 ? strerror(errno) : "short write");
		return -1;
	}
	// ... the header into the table unless it is the format's own, word
	// and checkword both ...
	uint32_t c, h, b;
	pack_chb(&p->g, lba, &c, &h, &b);
	const uint32_t own = pack_header_of(&p->g, c, h, b);
	if (words[256] == own && words[257] == ecc_over_words(&own, 1))
		header_remove(p, lba);
	else if (header_insert(p, lba, words[256], words[257]) < 0) {
		snprintf(err, errlen, "out of memory for the header table");
		return -1;
	}
	// ... and the data checkword likewise, after the data, because an
	// ordinary write's fresh checkword is the one over the data and clears
	// what a Write All laid.
	if (words[258] == ecc_over_words(words, PACK_BLOCK_WORDS))
		dck_remove(p, lba);
	else if (dck_insert(p, lba, words[258]) < 0) {
		snprintf(err, errlen, "out of memory for the checkword table");
		return -1;
	}
	// On the medium before the caller hears it is done: the card can lose
	// power at any moment and a block half on the pack is a pack that
	// disagrees with itself.
	if (fdatasync(p->fd) < 0 && errno != EINVAL) {
		snprintf(err, errlen, "syncing the pack: %s", strerror(errno));
		return -1;
	}
	// Then the block's entry in the sidecar, made on the first write-back
	// if it is not there yet, with the same discipline.
	if (p->meta_state != PACK_META_NONE) {
		if (p->meta_fd < 0 && meta_create(p, err, errlen) < 0)
			return -1;
		if (meta_write_entry(p, lba, err, errlen) < 0)
			return -1;
	}
	return 0;
}
