// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's disk file; `quux_disk.h` says what the three formats are, why a
// dynamic VHD is translated here rather than converted, and what a write to
// a block not yet allocated does.

#include "quux_disk.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define FOOTER_CHECKSUM 64
#define HEADER_BYTES 1024u
#define HEADER_CHECKSUM 36
#define UNALLOCATED 0xFFFFFFFFu

static uint64_t be(const uint8_t *b, int n)
{
	uint64_t v = 0;
	for (int i = 0; i < n; ++i)
		v = v << 8 | b[i];
	return v;
}

static void put_be32(uint8_t *b, uint32_t v)
{
	b[0] = (uint8_t)(v >> 24);
	b[1] = (uint8_t)(v >> 16);
	b[2] = (uint8_t)(v >> 8);
	b[3] = (uint8_t)v;
}

// The VHD checksum of a footer or a dynamic header: the one's complement of
// the sum of its bytes, its own field at `at` counted as zero.
static uint32_t checksum(const uint8_t *b, size_t n, size_t at)
{
	uint32_t sum = 0;
	for (size_t i = 0; i < n; ++i)
		if (i < at || i >= at + 4)
			sum += b[i];
	return ~sum;
}

static int read_at(int fd, uint64_t at, void *buf, size_t n)
{
	const ssize_t r = pread(fd, buf, n, (off_t)at);
	if (r == (ssize_t)n)
		return 0;
	if (r >= 0)
		errno = EIO;
	return -1;
}

static int write_at(int fd, uint64_t at, const void *buf, size_t n)
{
	const ssize_t r = pwrite(fd, buf, n, (off_t)at);
	if (r == (ssize_t)n)
		return 0;
	if (r >= 0)
		errno = ENOSPC;
	return -1;
}

// These 512 bytes as a footer: 1 with `type` and `size` filled, 0 without
// the cookie, -1 for a cookie whose checksum does not check.
static int footer(const uint8_t b[QUUX_SECTOR], uint32_t *type, uint64_t *size, char *err, size_t errlen)
{
	if (memcmp(b, "conectix", 8) != 0)
		return 0;
	const uint32_t want = (uint32_t)be(b + FOOTER_CHECKSUM, 4);
	const uint32_t got = checksum(b, QUUX_SECTOR, FOOTER_CHECKSUM);
	if (want != got) {
		snprintf(err, errlen, "a VHD footer whose checksum does not check: %08x, the bytes sum to %08x", want, got);
		return -1;
	}
	*type = (uint32_t)be(b + 60, 4);
	*size = be(b + 48, 8);
	return 1;
}

const char *quux_format_name(enum quux_format f)
{
	switch (f) {
	case QUUX_RAW:
		return "raw";
	case QUUX_FIXED_VHD:
		return "a fixed VHD";
	case QUUX_DYNAMIC_VHD:
		return "a dynamic VHD";
	}
	return "?";
}

int quux_disk_probe(int fd, struct quux_disk *d, char *err, size_t errlen)
{
	memset(d, 0, sizeof *d);
	struct stat st;
	if (fstat(fd, &st) < 0) {
		snprintf(err, errlen, "%s", strerror(errno));
		return -1;
	}
	const uint64_t len = (uint64_t)st.st_size;
	uint8_t first[QUUX_SECTOR] = { 0 }, last[QUUX_SECTOR] = { 0 };
	if (len >= 8 && read_at(fd, 0, first, len < QUUX_SECTOR ? (size_t)len : QUUX_SECTOR) < 0) {
		snprintf(err, errlen, "reading the start: %s", strerror(errno));
		return -1;
	}
	if (len >= 8 && memcmp(first, "vhdxfile", 8) == 0) {
		snprintf(err, errlen, "a VHDX, which is not a VHD: QUUX's disk is raw, a fixed VHD or a dynamic VHD");
		return -1;
	}
	uint32_t type = 0;
	uint64_t size = len;
	int is_vhd = 0;
	if (len >= QUUX_SECTOR) {
		if (read_at(fd, len - QUUX_SECTOR, last, QUUX_SECTOR) < 0) {
			snprintf(err, errlen, "reading the end: %s", strerror(errno));
			return -1;
		}
		const int r = footer(last, &type, &size, err, errlen);
		if (r < 0)
			return -1;
		if (r > 0) {
			is_vhd = 1;
			memcpy(d->footer, last, QUUX_SECTOR);
			d->end = len - QUUX_SECTOR;
		} else {
			// A dynamic VHD's copy at 0, its footer at the end lost: what a
			// power cut in the middle of growing it leaves, and why the copy
			// is there.  Only a dynamic VHD's; anything else is raw.
			uint32_t t0 = 0;
			uint64_t s0 = 0;
			const int r0 = footer(first, &t0, &s0, err, errlen);
			if (r0 < 0)
				return -1;
			if (r0 > 0 && t0 == 3) {
				is_vhd = 1;
				type = t0;
				size = s0;
				memcpy(d->footer, first, QUUX_SECTOR);
				d->end = len;
			}
		}
	}
	if (!is_vhd) {
		d->format = QUUX_RAW;
		size = len;
	} else if (type == 2) {
		d->format = QUUX_FIXED_VHD;
		if (size > d->end) {
			snprintf(err, errlen, "a fixed VHD of %llu bytes in a file of %llu, its footer included",
				 (unsigned long long)size, (unsigned long long)len);
			return -1;
		}
	} else if (type == 3) {
		d->format = QUUX_DYNAMIC_VHD;
	} else if (type == 4) {
		snprintf(err, errlen, "a differencing VHD, which needs its parent: QUUX's disk is raw, a fixed VHD or a dynamic VHD");
		return -1;
	} else {
		snprintf(err, errlen, "a VHD of disk type %u, which is none QUUX's disk is", type);
		return -1;
	}
	// Whole blocks: a last half block is out of reach of a block number.
	const uint64_t blocks = size / QUUX_BLOCK_BYTES;
	if (blocks > QUUX_MAX_BLOCKS) {
		snprintf(err, errlen, "%llu blocks, and block-disk's address reaches %llu",
			 (unsigned long long)blocks, (unsigned long long)QUUX_MAX_BLOCKS);
		return -1;
	}
	d->size = size;
	d->blocks = (uint32_t)blocks;
	if (d->format != QUUX_DYNAMIC_VHD)
		return 0;

	// The dynamic header, at the footer's data offset.
	const uint64_t at = be(d->footer + 16, 8);
	uint8_t h[HEADER_BYTES];
	if (at > d->end || d->end - at < HEADER_BYTES || read_at(fd, at, h, sizeof h) < 0 || memcmp(h, "cxsparse", 8) != 0) {
		snprintf(err, errlen, "no dynamic header at %llu: a dynamic VHD has one", (unsigned long long)at);
		return -1;
	}
	const uint32_t want = (uint32_t)be(h + HEADER_CHECKSUM, 4);
	const uint32_t got = checksum(h, sizeof h, HEADER_CHECKSUM);
	if (want != got) {
		snprintf(err, errlen, "a dynamic header whose checksum does not check: %08x, the bytes sum to %08x", want, got);
		return -1;
	}
	d->table_offset = be(h + 16, 8);
	d->entries = (uint32_t)be(h + 28, 4);
	d->block_bytes = be(h + 32, 4);
	if (d->block_bytes == 0 || d->block_bytes % QUUX_SECTOR) {
		snprintf(err, errlen, "a dynamic VHD's blocks of %llu bytes, not whole sectors", (unsigned long long)d->block_bytes);
		return -1;
	}
	if ((uint64_t)d->entries * d->block_bytes < d->size) {
		snprintf(err, errlen, "a dynamic VHD's table of %u blocks of %llu bytes, short of the disk's %llu",
			 d->entries, (unsigned long long)d->block_bytes, (unsigned long long)d->size);
		return -1;
	}
	if (d->table_offset > d->end || (d->end - d->table_offset) / 4 < d->entries) {
		snprintf(err, errlen, "a dynamic VHD's table of %u entries at %llu, past the end of the file",
			 d->entries, (unsigned long long)d->table_offset);
		return -1;
	}
	// The entries the disk reaches, and no more: a table may be longer than
	// its disk needs, and reading only these keeps the table this program
	// holds to the disk's size, at most 2^17 entries for 2 MiB blocks.
	d->entries = (uint32_t)((d->size + d->block_bytes - 1) / d->block_bytes);
	// A bit a sector, padded to whole sectors.
	d->bitmap_bytes = (d->block_bytes / QUUX_SECTOR + 7) / 8;
	d->bitmap_bytes = (d->bitmap_bytes + QUUX_SECTOR - 1) / QUUX_SECTOR * QUUX_SECTOR;
	// Where the next block goes: where the footer is, on a sector.
	d->end = (d->end + QUUX_SECTOR - 1) / QUUX_SECTOR * QUUX_SECTOR;
	return 0;
}

int quux_disk_open(int fd, struct quux_disk *d, char *err, size_t errlen)
{
	if (quux_disk_probe(fd, d, err, errlen) < 0)
		return -1;
	if (d->format != QUUX_DYNAMIC_VHD)
		return 0;
	uint8_t *raw = malloc((size_t)d->entries * 4 + 1);
	d->table = malloc((size_t)d->entries * sizeof *d->table + 1);
	if (!raw || !d->table) {
		free(raw);
		quux_disk_close(d);
		snprintf(err, errlen, "out of memory for a table of %u entries", d->entries);
		return -1;
	}
	if (read_at(fd, d->table_offset, raw, (size_t)d->entries * 4) < 0) {
		snprintf(err, errlen, "reading the dynamic VHD's table: %s", strerror(errno));
		free(raw);
		quux_disk_close(d);
		return -1;
	}
	for (uint32_t k = 0; k < d->entries; ++k) {
		d->table[k] = (uint32_t)be(raw + 4 * k, 4);
		if (d->table[k] == UNALLOCATED)
			continue;
		// An allocated block, its bitmap and its data, lies wholly in the
		// file before the footer, or a read of it would come back short and
		// a write would land on the footer.
		const uint64_t at = (uint64_t)d->table[k] * QUUX_SECTOR;
		if (at > d->end || d->end - at < d->bitmap_bytes + d->block_bytes) {
			snprintf(err, errlen, "the dynamic VHD's table puts block %u at sector %u, which runs past the data into byte %llu",
				 k, d->table[k], (unsigned long long)d->end);
			free(raw);
			quux_disk_close(d);
			return -1;
		}
	}
	free(raw);
	return 0;
}

void quux_disk_close(struct quux_disk *d)
{
	free(d->table);
	d->table = NULL;
}

// Where in the file the disk's byte `at` lies, or 0 in a block not
// allocated.  `at` and the span after it lie in one block.
static uint64_t locate(const struct quux_disk *d, uint64_t at, uint32_t *k)
{
	*k = (uint32_t)(at / d->block_bytes);
	const uint32_t entry = d->table[*k];
	if (entry == UNALLOCATED)
		return 0;
	return (uint64_t)entry * QUUX_SECTOR + d->bitmap_bytes + at % d->block_bytes;
}

int quux_disk_read(int fd, struct quux_disk *d, uint32_t n, uint8_t buf[QUUX_BLOCK_BYTES], char *err, size_t errlen)
{
	if (n >= d->blocks) {
		snprintf(err, errlen, "block %u is past the end of a disk of %u", n, d->blocks);
		return -1;
	}
	const uint64_t at = (uint64_t)n * QUUX_BLOCK_BYTES;
	if (d->format != QUUX_DYNAMIC_VHD) {
		if (read_at(fd, at, buf, QUUX_BLOCK_BYTES) < 0) {
			snprintf(err, errlen, "reading block %u: %s", n, strerror(errno));
			return -1;
		}
		return 0;
	}
	// A sector at a time: a block of the VHD may be as small as a sector,
	// and then one of block-disk's blocks spans two of them.
	for (unsigned s = 0; s < QUUX_BLOCK_BYTES / QUUX_SECTOR; ++s) {
		uint32_t k;
		const uint64_t off = locate(d, at + s * QUUX_SECTOR, &k);
		uint8_t *into = buf + s * QUUX_SECTOR;
		if (!off)
			memset(into, 0, QUUX_SECTOR);
		else if (read_at(fd, off, into, QUUX_SECTOR) < 0) {
			snprintf(err, errlen, "reading block %u from the dynamic VHD's block %u: %s", n, k, strerror(errno));
			return -1;
		}
	}
	return 0;
}

// A dynamic VHD's block `k` allocated where the footer is, with one sector
// of it written: the bitmap all ones, the data zeros but for that sector,
// then the footer after it, synced, and only then the table entry.
static int allocate(int fd, struct quux_disk *d, uint32_t k, uint64_t in_block, const uint8_t *sector,
		    char *err, size_t errlen)
{
	if (d->end / QUUX_SECTOR >= UNALLOCATED) {
		snprintf(err, errlen, "a block at byte %llu, past what a table entry holds", (unsigned long long)d->end);
		return -1;
	}
	const uint32_t entry = (uint32_t)(d->end / QUUX_SECTOR);
	const size_t n = (size_t)(d->bitmap_bytes + d->block_bytes);
	uint8_t *block = calloc(1, n);
	if (!block) {
		snprintf(err, errlen, "out of memory for a block of %zu bytes", n);
		return -1;
	}
	memset(block, 0xFF, (size_t)d->bitmap_bytes);
	memcpy(block + d->bitmap_bytes + in_block, sector, QUUX_SECTOR);
	const uint64_t end = d->end + n;
	int r = write_at(fd, d->end, block, n);
	free(block);
	if (r == 0)
		r = write_at(fd, end, d->footer, QUUX_SECTOR);
	// The block and the footer on the medium before the entry names the
	// block: a cut between the two leaves a block nothing names, not an
	// entry naming a block that is not there.
	if (r == 0 && fdatasync(fd) < 0 && errno != EINVAL)
		r = -1;
	uint8_t e[4];
	put_be32(e, entry);
	if (r == 0)
		r = write_at(fd, d->table_offset + 4ull * k, e, sizeof e);
	if (r < 0) {
		snprintf(err, errlen, "allocating the dynamic VHD's block %u at byte %llu: %s", k,
			 (unsigned long long)d->end, strerror(errno));
		return -1;
	}
	d->table[k] = entry;
	d->end = end;
	return 0;
}

int quux_disk_write(int fd, struct quux_disk *d, uint32_t n, const uint8_t buf[QUUX_BLOCK_BYTES], char *err, size_t errlen)
{
	if (n >= d->blocks) {
		snprintf(err, errlen, "block %u is past the end of a disk of %u", n, d->blocks);
		return -1;
	}
	const uint64_t at = (uint64_t)n * QUUX_BLOCK_BYTES;
	if (d->format != QUUX_DYNAMIC_VHD) {
		// A fixed VHD's footer is past the data, so the block goes where a
		// raw file's would.
		if (write_at(fd, at, buf, QUUX_BLOCK_BYTES) < 0) {
			snprintf(err, errlen, "writing block %u: %s", n, strerror(errno));
			return -1;
		}
		return 0;
	}
	for (unsigned s = 0; s < QUUX_BLOCK_BYTES / QUUX_SECTOR; ++s) {
		const uint64_t sat = at + s * QUUX_SECTOR;
		const uint8_t *from = buf + s * QUUX_SECTOR;
		uint32_t k;
		const uint64_t off = locate(d, sat, &k);
		if (!off) {
			if (allocate(fd, d, k, sat % d->block_bytes, from, err, errlen) < 0)
				return -1;
			continue;
		}
		if (write_at(fd, off, from, QUUX_SECTOR) < 0) {
			snprintf(err, errlen, "writing block %u into the dynamic VHD's block %u: %s", n, k, strerror(errno));
			return -1;
		}
		// The sector's bit in the bitmap, set if it is not, the bitmap's
		// first sector being the high bit of its first byte.  **Unverified**,
		// as muir's is: qemu and this program set every bit when they
		// allocate, so no file either made has a bit clear to exercise it.
		const uint64_t sector = sat % d->block_bytes / QUUX_SECTOR;
		const uint64_t bit_at = (uint64_t)d->table[k] * QUUX_SECTOR + sector / 8;
		const uint8_t bit = (uint8_t)(0x80u >> (sector % 8));
		uint8_t byte;
		if (read_at(fd, bit_at, &byte, 1) < 0) {
			snprintf(err, errlen, "reading the bitmap of the dynamic VHD's block %u: %s", k, strerror(errno));
			return -1;
		}
		if (!(byte & bit)) {
			byte |= bit;
			if (write_at(fd, bit_at, &byte, 1) < 0) {
				snprintf(err, errlen, "writing the bitmap of the dynamic VHD's block %u: %s", k, strerror(errno));
				return -1;
			}
		}
	}
	return 0;
}
