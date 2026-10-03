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
//     `cadr-disk-packs` takes it, so it cannot be declared wrong either.  A
//     QUUX disk has none: block-disk's one pack is any size, and what the
//     file is --- raw, a fixed VHD or a dynamic VHD --- is told by its
//     footers with `cadr-disk-packs`'s own `quux_disk_probe`.
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
// Where `S80cadr-disk-packs` puts the drive bay, and what the eight packs are
// called there.  **The same two constants as
// `package/cadr-disk-packs/src/pack_bay.h`**, which is the authority: a name
// that is a pack is one of these eight and nothing else.  `--pack-dir`
// overrides it, which is what a card of the old two-partition shape needs,
// its bay having been the root of the second partition.
#define BIND_DIR "/mnt/card/packs"
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
	// A QUUX disk's instead of a geometry: what the file is, told by its
	// footers as `cadr-disk-packs` tells it (`quux_disk.h`), "raw",
	// "fixed-vhd" or "dynamic-vhd", and its whole blocks of 1,024 bytes.
	// Empty and zero for a CADR pack.
	char format[16];
	uint64_t blocks;
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
	// Main memory in 64K-word units: the CADR's boards, or QUUX's amount,
	// sixteen a megaword, which the sidecar records as an amount under
	// `main-memory-size:` and never as boards.
	unsigned boards;
	uint64_t microcycles;
	uint64_t ns;
	// How the packs were made to hold still; see `cadr-checkpoint.c`.
	int machine_halted_first;
	int packs_program_stopped;
	// Which machine the checkpoint is of: the CADR, or QUUX, whose resume
	// is muir's `quux` and whose one pack is block-disk's, unit 0.  A
	// sidecar without the line is the CADR's, which is all there was.
	int quux;
	// **WHAT muir NEEDS TO RESUME IT AS THE BOARD RAN IT**: QUUX's revision,
	// 12 or 13, which muir's `quux` takes from `MUIR_QUUX_REVISION` and
	// refuses a checkpoint of the other at; and the microcycle's length in
	// ticks, K, which `--sync-cycle-ticks` gives and muir refuses a
	// checkpoint of another K at.  Both are the fabric's own (the readout's
	// register table's entry 21).  0 on the CADR, and 0 in a sidecar written
	// before the lines were, whose resume then names neither.
	unsigned revision;
	unsigned sync_k;
	// **AND QUUX's VIDEO CONTROLLER'S SIZE**, the bitstream's (console word
	// 39), which muir's `--video-size` gives and muir refuses a checkpoint
	// of another size at.  0 on the CADR and in a sidecar written before
	// the size was named.
	unsigned video_width, video_height;
	// The run state the file records: 1 when the machine was running and
	// this program halted it for the read, so that the file carries RUN and
	// SRUN set and muir resumes it running; 0 when it was found halted and
	// is written so; -1 in a sidecar written before the line was.
	int running;
};

void bind_init(struct binding *b);

// **WHAT A UNIT IS DECLARED AS IN THE CHECKPOINT**, which muir holds the
// resuming disk to: a CADR pack's geometry, and a QUUX disk's blocks as
// `blocks` by 1 by 1, since `chk_rtl.c` writes block-disk's disk size as the
// product.  A QUUX disk has no geometry of its own, and declaring its zero
// one wrote a disk of no blocks, which muir refuses against the real one.
void bind_declared(const struct bind_pack *p, uint32_t *cylinders, uint32_t *heads,
		   uint32_t *blocks_per_track);

// The geometry a file of this size is a pack of: `Geometry::T300` or
// `Geometry::T80`, the two `pack_file.c` knows.  0 if it is one, -1 if the
// size is no geometry's --- which is also how a pack still being copied in
// is told from a pack.
int bind_geometry_of_size(uint64_t bytes, uint32_t *cylinders, uint32_t *heads,
			  uint32_t *blocks_per_track);

// The drive bay: whichever of `disk-pack-0.img` .. `disk-pack-7.img` exist in
// `dir` and are a pack of the binding's machine --- on the CADR a geometry's
// size, on QUUX (`quux` set before the scan) a QUUX disk by its footers, raw,
// a fixed VHD or a dynamic VHD of any size, as `cadr-disk-packs --machine
// quux` takes it.  Returns how many were found; a name that is there and is
// NOT a pack is reported through `err` and counts as absent.
int bind_scan(struct binding *b, const char *dir, char *err, size_t errlen);

// One pack named by hand: `<file>[,<unit>]`, muir's own `--disk-pack` syntax
// bar the `ro` it has no use for here.  The unit defaults to 0, and the file
// is held to the binding's machine's rule as `bind_scan` holds it.  Returns
// 0, or -1 with `err`.
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

// **THE HALT `cadr-checkpoint --halt` MADE**, for the longer way round
// (`docs/checkpoint.md`): `--halt` writes the microcycle count it halted a
// running machine at into `path`, and `--already-halted` takes the machine
// as running before the halt only when the mark is there and the count still
// stands at it --- a machine that has retired a microcycle since was started
// by somebody, and a mark of a count it is not at is not about this halt.
// `--start` takes the mark away.  `BIND_HALT_MARK` on the board.
#define BIND_HALT_MARK "/var/run/cadr-checkpoint-halted"
int bind_halt_mark(const char *path, uint64_t cycles);
// 1 when the mark is there and names `cycles`, 0 otherwise.
int bind_halted_here(const char *path, uint64_t cycles);
void bind_halt_unmark(const char *path);

// **WHAT A PERSON READS OF MAIN MEMORY**, `units` of 64K words in the
// machine's own words: the CADR's `32 memory boards`, and QUUX's amount,
// `32MW of main memory` (`ro_main_amount`).  QUUX has no memory boards, and
// nothing this program says about it counts them.
void bind_memory_words(int quux, unsigned units, char *out, size_t n);

// **THE MAIN MEMORY THE COMMAND LINE ASKED FOR**, held to the machine named:
// the CADR's `--boards N`, 1 to 60, and QUUX's `--main-memory-size <n>MW`,
// muir's flag and form, 1MW to `most_units`.  Each machine's flag is refused
// on the other, naming the right one.  An argument not given is NULL.
// Returns 0 with `*units` set (0 when neither was given: the machine's own
// is taken), or 2 with `err`, the program's exit status for a bad flag.
int bind_memory_asked(int quux, const char *boards_arg, const char *size_arg,
		      unsigned most_units, unsigned *units, char *err, size_t errlen);

// The command a resume takes, into `out`.  The packs in unit order, the
// checkpoint last, which is the order muir's own usage puts them in.  It
// names everything muir needs to take the file as the board ran it: on the
// CADR the timing model and the boards; on QUUX the revision, as the
// environment's `MUIR_QUUX_REVISION=` before the command, K and the video
// controller's size.
void bind_resume_command(const struct binding *b, const char *chk, char *out, size_t n);

#endif
