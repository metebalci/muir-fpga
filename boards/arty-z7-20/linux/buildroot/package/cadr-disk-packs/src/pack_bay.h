// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The drive bay: eight units, eight names, one directory.
//
// **THE NAMES ARE THE RULE.**  The card's second partition holds nothing but
// disk packs, named `disk-pack-0.img` to `disk-pack-7.img`.  Whichever of
// the eight exist are the drives that are present, and the unit field of a
// request --- `DA<30:28>`, "that disk unit whose number is currently in bits
// <30:28> of the disk-address register" --- chooses the file.  There is no
// option naming a pack and none naming a unit, because there is nothing left
// for one to say.
//
// **A FILE IS A PACK ONLY WHEN ITS SIZE IS A GEOMETRY'S**, a T-300's
// 269,562,880 bytes or a T-80's 70,937,600 (`pack_geometry_of_size`).  That
// one rule does two jobs: it tells the two drive types apart, as muir's
// `Unit::open_with` does, and it makes a pack still being copied in --- every
// intermediate size is the wrong size --- simply not a drive yet.  Copy a
// pack in over the network and the drive appears at the instant the last
// byte lands; no flag, no signal, no restart.
//
// **THE READ-ONLY MARK IS THE WRITE-PROTECT SWITCH.**  FAT carries a
// read-only attribute per file; Windows sets it from a file's properties and
// Linux from `chmod -w`, and Linux's `vfat` shows it by clearing the write
// bits in the mode.  So the switch is read from the mode and from nothing
// else --- not from whether an open for writing succeeds, which as root it
// always does.
//
// WHAT THIS FILE IS AND IS NOT.  It is the filesystem side alone: the names,
// the eight open packs, what a name says right now.  It knows nothing of the
// register face or of the block store, so nothing here decides *when* a
// change may be applied or what has to be flushed first --- that is
// `pack_feeder.c`'s `feeder_bay_scan`, which is where the drive bay's rules
// live.

#ifndef PACK_BAY_H
#define PACK_BAY_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "pack_file.h"

// The eight units the controller selects between (`rtl/machine/cadr_disk_controller.sv`,
// the unit slots).
#define BAY_UNITS 8
// Where the packs are, and what they are called.  The directory is the
// card's second partition; `S80cadr-disk-packs` mounts it there.
#define BAY_DIR "/mnt/packs"
#define BAY_NAME_FMT "disk-pack-%u.img"

struct bay_drive {
	// Valid while `present`.  The pack's own `dev`/`ino`/`size` are the
	// identity of the file the descriptor is on, which is how a rename, a
	// replacement and an overwrite in place are told apart.
	struct pack pack;
	int present;
	int read_only;
};

struct bay {
	char dir[3072];
	struct bay_drive d[BAY_UNITS];
};

// What one of the eight names says at this instant.
struct bay_look {
	int there;		// the name resolves to something
	int is_pack;		// ... a regular file whose size is a geometry's
	int read_only;		// ... with its write bits down
	dev_t dev;
	ino_t ino;
	off_t size;
	struct pack_geometry g;
};

void bay_init(struct bay *b, const char *dir);
// The full path of a unit's pack.
void bay_path(const struct bay *b, unsigned unit, char *out, size_t n);
// One stat of one name.  Always returns; `l->there` says what it found.
void bay_look(const struct bay *b, unsigned unit, struct bay_look *l);

// Open what `l` describes as this unit's pack, or -1 with `err`.
int bay_open(struct bay *b, unsigned unit, const struct bay_look *l, char *err, size_t errlen);
// Close it and make the unit absent.  Whatever had to be flushed or reported
// was the caller's business and has already happened.
void bay_close(struct bay *b, unsigned unit);
// The same file with a different writability: the read-only mark changed.
int bay_reopen(struct bay *b, unsigned unit, int writable, char *err, size_t errlen);

// The two masks the DRIVE register takes.
uint8_t bay_present_mask(const struct bay *b);
uint8_t bay_read_only_mask(const struct bay *b);

// The pack on a unit, or NULL when nothing is on that cable.
struct pack *bay_pack(struct bay *b, unsigned unit);

#endif
