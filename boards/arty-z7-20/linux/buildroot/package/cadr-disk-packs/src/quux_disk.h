// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's disk file: raw, a fixed VHD or a dynamic VHD, read and written as
// block-disk's blocks of 1,024 bytes.  Block `n` is the disk's 512-byte
// sectors `2n` and `2n + 1`, and the partition table on it is a GPT that
// nothing here reads: this layer serves blocks by number and knows nothing of
// what is in them, so it assumes no CADR label and no partition either.
//
// muir's `disk_image` is the reference and this follows it: the format is
// told by the footer, never by the file's name; a raw file is the disk from
// byte 0; a fixed VHD is the disk and then a footer of 512 bytes, which is
// past the data and so needs nothing; a dynamic VHD is translated here, block
// by block, on every read and write.
//
// **WHY A VIEW AND NOT A CONVERSION.**  The dynamic VHD is read and written in
// place, through its block allocation table, rather than converted to a raw
// file when the drive comes present.  A conversion needs the whole disk's
// size free on the card beside the VHD (the point of a dynamic VHD is that it
// is smaller than its disk), a raw file of more than 4 GiB cannot sit on the
// card's FAT32 at all, and the machine's writes would land in the copy and
// have to be carried back into the VHD at a stop that a power cut does not
// wait for.  A raw view through the kernel is no better: the boards carry no
// qemu-nbd, the Zynq boards' kernel configuration has neither NBD nor FUSE,
// and a view through either would still need a server doing this same
// translation.  This program already owns every read and write of the pack,
// so the translation is a table lookup in the one place the blocks pass
// through.
//
// The VHD layout is Microsoft's *Virtual Hard Disk Image Format
// Specification* (October 2006), every field big-endian:
//
//   - the FOOTER, 512 bytes at the file's end: cookie `conectix` at 0, data
//     offset at 16, current size at 48, disk type at 60 (2 fixed, 3 dynamic,
//     4 differencing), and at 64 a checksum, the one's complement of the sum
//     of the footer's bytes with the field taken as zero;
//   - a DYNAMIC VHD has a copy of the footer at 0, its dynamic header
//     (cookie `cxsparse`, 1,024 bytes, the same kind of checksum at 36) at
//     the footer's data offset, the block allocation table at the header's
//     table offset (16), its entry count at 28 and the block size at 32.  A
//     table entry is the sector where a block's sector bitmap begins, the
//     block's data following the bitmap, or FFFFFFFF for a block not
//     allocated, which reads as zeros.
//
// **A WRITE TO AN UNALLOCATED BLOCK** does what the specification and qemu
// do: the block goes where the footer was, its bitmap all ones and its data
// zeros but for what is written, then the footer after it, then the table
// entry.  The footer's bytes are the ones read at the open; only where they
// are moves.  Between the footer and the entry the file is synced, so that a
// power cut leaves at worst a block no entry names, never an entry naming a
// block that is not there; and a footer missing at the end is what the copy
// at 0 is for, so such a file opens by the copy, as muir's does.
//
// Held to files made by qemu-img and qemu-io, never by this program or muir,
// by `feeder_test.c`: each VHD reads block for block as its raw twin, and a
// dynamic VHD grown here by the same writes is qemu-io's own file byte for
// byte.

#ifndef QUUX_DISK_H
#define QUUX_DISK_H

#include <stddef.h>
#include <stdint.h>

#define QUUX_SECTOR 512u
#define QUUX_BLOCK_BYTES 1024u
// Block-disk's disk address is `<27:0>` (`rtl/machine/quux_block_disk.sv`), so
// this many blocks are all it can reach, and a disk of more is refused as
// muir's `disk_image::MAX_BLOCKS` refuses it.
#define QUUX_MAX_BLOCKS (1ull << 28)

enum quux_format { QUUX_RAW, QUUX_FIXED_VHD, QUUX_DYNAMIC_VHD };

struct quux_disk {
	enum quux_format format;
	// The disk's bytes (a VHD's footer's current size), and its whole blocks.
	uint64_t size;
	uint32_t blocks;
	// A dynamic VHD's: the table as in the file (the entries the disk
	// reaches, where the header may give more), where it is, a block's data
	// and the bitmap before it, the footer as read, and where the footer is
	// now, which is where the next block goes.
	uint32_t *table;
	uint32_t entries;
	uint64_t table_offset, block_bytes, bitmap_bytes, end;
	uint8_t footer[QUUX_SECTOR];
};

// What the file on `fd` is: the format and the size, footers and dynamic
// header checked, the table not read.  What the drive bay asks four times a
// second.  0, or -1 with `err` saying why the file is not a QUUX disk.
int quux_disk_probe(int fd, struct quux_disk *d, char *err, size_t errlen);
// The same, and a dynamic VHD's table read and checked: every allocated
// block's bitmap and data inside the file, before the footer.  0, or -1 with
// `err`.
int quux_disk_open(int fd, struct quux_disk *d, char *err, size_t errlen);
void quux_disk_close(struct quux_disk *d);

// Block `n`'s 1,024 bytes.  0, or -1 with `err`, and past the end is -1.
int quux_disk_read(int fd, struct quux_disk *d, uint32_t n, uint8_t buf[QUUX_BLOCK_BYTES], char *err, size_t errlen);
// Block `n` written, a dynamic VHD's block allocated if it has to be.  Not
// synced: the caller syncs, as it does a raw pack's write.
int quux_disk_write(int fd, struct quux_disk *d, uint32_t n, const uint8_t buf[QUUX_BLOCK_BYTES], char *err, size_t errlen);

// The words the console uses: "raw", "a fixed VHD", "a dynamic VHD".
const char *quux_format_name(enum quux_format f);

#endif
