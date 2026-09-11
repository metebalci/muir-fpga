// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack file and its two tables; `pack_file.h` says what and why.

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

uint64_t pack_size_of(const struct pack_geometry *g)
{
	return (uint64_t)g->cylinders * g->heads * g->blocks_per_track * PACK_BLOCK_BYTES;
}

int pack_geometry_of_size(uint64_t bytes, struct pack_geometry *g)
{
	if (bytes == pack_size_of(&PACK_T300)) {
		*g = PACK_T300;
		return 0;
	}
	if (bytes == pack_size_of(&PACK_T80)) {
		*g = PACK_T80;
		return 0;
	}
	return -1;
}

int pack_open(struct pack *p, const char *path, int writable, char *err, size_t errlen)
{
	memset(p, 0, sizeof *p);
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
	if (pack_geometry_of_size((uint64_t)st.st_size, &p->g) < 0) {
		snprintf(err, errlen, "%s: %lld bytes, which is neither a T-300 (%llu) nor a T-80 (%llu)",
			 path, (long long)st.st_size,
			 (unsigned long long)pack_size_of(&PACK_T300),
			 (unsigned long long)pack_size_of(&PACK_T80));
		close(p->fd);
		return -1;
	}
	p->writable = writable;
	p->blocks = p->g.cylinders * p->g.heads * p->g.blocks_per_track;
	p->dev = st.st_dev;
	p->ino = st.st_ino;
	p->size = st.st_size;
	return 0;
}

int pack_alive(const struct pack *p)
{
	struct stat st;
	if (p->fd < 0 || fstat(p->fd, &st) < 0)
		return 0;
	// `vfat`'s unlink calls `clear_nlink` on the inode, as every local
	// filesystem's does, so a deleted pack reads zero here while its
	// descriptor is still open and still writable --- and every byte
	// written through it is thrown away at the last close.
	return st.st_nlink > 0;
}

int pack_reopen(struct pack *p, const char *path, int writable, char *err, size_t errlen)
{
	const int fd = open(path, writable ? O_RDWR : O_RDONLY);
	if (fd < 0) {
		snprintf(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	struct stat st;
	if (fstat(fd, &st) < 0) {
		snprintf(err, errlen, "%s: %s", path, strerror(errno));
		close(fd);
		return -1;
	}
	// The same file, or this is not a reopen but a replacement, and the
	// caller's tables belong to the pack that went away.
	if (st.st_dev != p->dev || st.st_ino != p->ino || st.st_size != p->size) {
		snprintf(err, errlen, "%s is not the file this drive was opened on any more", path);
		close(fd);
		return -1;
	}
	close(p->fd);
	p->fd = fd;
	p->writable = writable;
	return 0;
}

void pack_close(struct pack *p)
{
	if (p->fd >= 0)
		close(p->fd);
	free(p->headers);
	free(p->dcks);
	memset(p, 0, sizeof *p);
	p->fd = -1;
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
		words[i] = (uint32_t)bytes[4 * i] | (uint32_t)bytes[4 * i + 1] << 8
			 | (uint32_t)bytes[4 * i + 2] << 16 | (uint32_t)bytes[4 * i + 3] << 24;
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
		for (int j = 0; j < 4; ++j)
			bytes[4 * i + j] = (uint8_t)(words[i] >> (8 * j));
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
	return 0;
}
