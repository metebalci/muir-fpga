// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The drive bay's filesystem side; `pack_bay.h` says what the rules are and
// where the rest of them live.

#include "pack_bay.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

void bay_init(struct bay *b, const char *dir)
{
	memset(b, 0, sizeof *b);
	snprintf(b->dir, sizeof b->dir, "%s", dir);
	for (unsigned u = 0; u < BAY_UNITS; ++u)
		b->d[u].pack.fd = -1;
}

void bay_path(const struct bay *b, unsigned unit, char *out, size_t n)
{
	char name[32];
	snprintf(name, sizeof name, BAY_NAME_FMT, unit & 7u);
	snprintf(out, n, "%s/%s", b->dir, name);
}

void bay_look(const struct bay *b, unsigned unit, struct bay_look *l)
{
	char path[4096];
	struct stat st;
	memset(l, 0, sizeof *l);
	bay_path(b, unit, path, sizeof path);
	if (stat(path, &st) < 0)
		return;
	l->there = 1;
	l->dev = st.st_dev;
	l->ino = st.st_ino;
	l->size = st.st_size;
	if (!S_ISREG(st.st_mode))
		return;
	// The size is the whole of the test: a T-300's or a T-80's, and every
	// other size --- an empty file, a copy still arriving, something that is
	// not a pack at all --- is not a drive.
	if (pack_geometry_of_size((uint64_t)st.st_size, &l->g) < 0)
		return;
	l->is_pack = 1;
	// FAT's read-only attribute, as `vfat` shows it: the write bits down.
	// Read from the mode and not from an open, because root's open for
	// writing succeeds whatever the mode says.
	l->read_only = (st.st_mode & 0222) == 0;
}

int bay_open(struct bay *b, unsigned unit, const struct bay_look *l, char *err, size_t errlen)
{
	char path[4096];
	struct bay_drive *d = &b->d[unit];
	bay_path(b, unit, path, sizeof path);
	if (pack_open(&d->pack, path, !l->read_only, err, errlen) < 0)
		return -1;
	// The file that was stat'ed and the file that was opened must be one
	// file, or the pack was replaced between the two and this drive is
	// holding a descriptor on something nobody asked for.
	if (d->pack.dev != l->dev || d->pack.ino != l->ino || d->pack.size != l->size) {
		snprintf(err, errlen, "%s changed between the look and the open", path);
		pack_close(&d->pack);
		d->pack.fd = -1;
		return -1;
	}
	d->present = 1;
	d->read_only = l->read_only;
	return 0;
}

void bay_close(struct bay *b, unsigned unit)
{
	struct bay_drive *d = &b->d[unit];
	if (d->present)
		pack_close(&d->pack);
	d->pack.fd = -1;
	d->present = 0;
	d->read_only = 0;
}

int bay_reopen(struct bay *b, unsigned unit, int writable, char *err, size_t errlen)
{
	char path[4096];
	struct bay_drive *d = &b->d[unit];
	if (!d->present) {
		snprintf(err, errlen, "unit %u has no pack to reopen", unit);
		return -1;
	}
	bay_path(b, unit, path, sizeof path);
	if (pack_reopen(&d->pack, path, writable, err, errlen) < 0)
		return -1;
	d->read_only = !writable;
	return 0;
}

uint8_t bay_present_mask(const struct bay *b)
{
	uint8_t m = 0;
	for (unsigned u = 0; u < BAY_UNITS; ++u)
		if (b->d[u].present)
			m |= (uint8_t)(1u << u);
	return m;
}

uint8_t bay_read_only_mask(const struct bay *b)
{
	uint8_t m = 0;
	for (unsigned u = 0; u < BAY_UNITS; ++u)
		if (b->d[u].present && b->d[u].read_only)
			m |= (uint8_t)(1u << u);
	return m;
}

struct pack *bay_pack(struct bay *b, unsigned unit)
{
	if (unit >= BAY_UNITS || !b->d[unit].present)
		return NULL;
	return &b->d[unit].pack;
}
