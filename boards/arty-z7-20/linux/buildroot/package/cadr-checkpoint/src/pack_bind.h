// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack binding: which disk packs the machine in a checkpoint was running
// on, and what they held at the instant the checkpoint was taken.
//
// **WHY A CHECKPOINT ALONE IS NOT A MACHINE.**  muir's format carries the
// blocks a run has WRITTEN and never the pack itself --- a pack is a file a
// resume opens again --- so a checkpoint resumed over a different pack
// restores a machine into a disk it never had.  On the board that is not a
// remote possibility: `cadr-disk-packs` writes the machine's blocks straight
// through to the card, so the pack under a running CADR changes every second,
// and a checkpoint taken now and the pack ten minutes later are two different
// machines.  Nothing in muir can notice, because nothing in muir has ever
// seen the pack the checkpoint came from.
//
// So the binding is made here, and it is made of three things:
//
//   the SET of units, which muir DOES enforce.  `Controller::load` refuses a
//     checkpoint that says a drive is present where the resuming machine has
//     none, and the other way round.  The checkpoint therefore declares
//     exactly the units this binding found, and cannot declare a drive that
//     was not there.
//   the GEOMETRY of each, which muir ALSO enforces --- `Unit::load` refuses
//     "a pack of Geometry { .. }, and the drive holds one of .." --- and
//     which is taken from the pack file's own SIZE, exactly as
//     `cadr-disk-packs` takes it, so it cannot be declared wrong either.
//   the CONTENT of each, which muir does not enforce and cannot: a SHA-256
//     of every byte, recorded in a sidecar beside the checkpoint.
//
// **THE SIDECAR IS BESIDE THE FILE AND NOT INSIDE IT**, because the format is
// muir's and has to stay byte-compatible: muir's own round-trip test saves a
// resumed checkpoint and compares it with the file it read, and a field of
// ours anywhere in that stream would break it. A sidecar costs nothing and
// can hold whatever a person needs.
//
// **AND IT IS FOR A PERSON AS WELL AS FOR A PROGRAM.**  One `key: value` a
// line, plain text, with the digests in the same lower-case hex `sha256sum`
// prints --- so the check is either `cadr-checkpoint --verify <sidecar>` or
// one `sha256sum` and a pair of eyes, and neither needs the board.

#ifndef PACK_BIND_H
#define PACK_BIND_H

#include <stdint.h>
#include <stddef.h>

#include "sha256.h"

// The controller's eight unit slots (`rtl/machine/cadr_disk_controller.sv`).
#define BIND_UNITS 8
// Where `S80cadr-disk-packs` mounts the card's pack partition, and what the
// eight packs are called there.  **The same two constants as
// `package/cadr-disk-packs/src/pack_bay.h`**, which is the authority: a name
// that is a pack is one of these eight and nothing else.
#define BIND_DIR "/mnt/packs"
#define BIND_NAME_FMT "disk-pack-%u.img"

// The sidecar's suffix, appended to the checkpoint's own name.
#define BIND_SUFFIX ".packs"
// What the first line says.  A reader that does not know this number must
// refuse the file rather than guess at it.
#define BIND_FORMAT "cadr-checkpoint-packs 1"

struct bind_pack {
	int present;
	char path[1024];
	uint64_t bytes;
	char sha256[SHA256_HEX];
	uint32_t cylinders, heads, blocks_per_track;
	int read_only;
	// Set by `bind_verify` when the pack on disk is not the one recorded.
	int moved;
	char now[SHA256_HEX];
};

struct binding {
	struct bind_pack u[BIND_UNITS];
	unsigned present;		/* how many of the eight are there */
	// What the checkpoint beside it is.  Filled after the checkpoint is
	// written, because the digest is of the finished file.
	char checkpoint[512];
	char checkpoint_sha[SHA256_HEX];
	uint64_t checkpoint_bytes;
	char taken[64];			/* ISO 8601, local time with its offset */
	unsigned boards;
	uint64_t microcycles;
	uint64_t ns;
	// How the packs were made to hold still; see `cadr-checkpoint.c`.
	int machine_halted_first;
	int packs_program_stopped;
};

void bind_init(struct binding *b);

// The geometry a file of this size is a pack of: `Geometry::T300` or
// `Geometry::T80`, the two `pack_file.c` knows.  0 if it is one, -1 if the
// size is no geometry's --- which is also how a pack still being copied in
// is told from a pack.
int bind_geometry_of_size(uint64_t bytes, uint32_t *cylinders, uint32_t *heads,
			  uint32_t *blocks_per_track);

// The drive bay: whichever of `disk-pack-0.img` .. `disk-pack-7.img` exist in
// `dir` and are a geometry's size.  Returns how many were found; a name that
// is there and is NOT a pack is reported through `err` and counts as absent.
int bind_scan(struct binding *b, const char *dir, char *err, size_t errlen);

// One pack named by hand: `<file>[,<unit>]`, muir's own `--disk-pack` syntax
// bar the `ro` it has no use for here.  The unit defaults to 0.  Returns 0,
// or -1 with `err`.
int bind_add(struct binding *b, const char *spec, char *err, size_t errlen);

// Read every present pack through and digest it.  Returns 0, or -1 with
// `err` --- and **a caller must not write a checkpoint after -1**: a pack
// that cannot be read is a pack nothing can be bound to.
int bind_digest(struct binding *b, char *err, size_t errlen);

// The sidecar.  `path` is the checkpoint's name with BIND_SUFFIX on it.
int bind_write(const struct binding *b, const char *path, char *err, size_t errlen);
// And back: a sidecar read into `b`.  Refuses a format line it does not know.
int bind_read(struct binding *b, const char *path, char *err, size_t errlen);

// Re-read and re-digest every pack the binding names, and the checkpoint
// beside it.  Returns the number that have MOVED --- each with `moved` set
// and `now` holding what it reads today --- or -1 with `err` if one could not
// be read at all.  `chk_moved` is set if the checkpoint itself has changed.
int bind_verify(struct binding *b, int *chk_moved, char *err, size_t errlen);

// The command a resume takes, into `out`.  The packs in unit order, the
// checkpoint last, which is the order muir's own usage puts them in.
void bind_resume_command(const struct binding *b, const char *chk, char *out, size_t n);

#endif
