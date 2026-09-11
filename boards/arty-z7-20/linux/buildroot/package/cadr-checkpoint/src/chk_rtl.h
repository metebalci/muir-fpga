// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A board's machine as an `rtl` checkpoint body.  `chk_rtl.c`'s header says
// what is read off the fabric and what is not.

#ifndef CHK_RTL_H
#define CHK_RTL_H

// The machine as the console's readout window can be asked about it.  **It is
// `cadr-readout`'s header and not a copy of it**: that package installs its
// readout as a library into the staging tree, and this one links against it,
// so there is one description of the window in the repository and not two.
// `cadr-checkpoint.mk` has the argument.
#include "cadr_image.h"
#include "chk.h"

// simpletv's sync RAM, 4096 bytes.  It is here and not in `cadr_image.h`
// because the fabric has no sync generator to read one out of --- the readout
// window never produces this and only the checkpoint has to know the size.
#define IMG_TV_SYNC 4096u

// What the checkpoint DECLARES rather than reads.
//
// A pack is not in a checkpoint --- it is a file a resume opens again --- but
// whether a drive is THERE is, and so is its geometry, and muir refuses a
// checkpoint that disagrees with the machine resuming it on either.  So both
// come from the packs `pack_bind.c` found, which is what makes the
// declaration a reading of the drive bay rather than an assertion of the
// program's.
struct chk_declared {
	// Unit u is present when bit u is set.
	unsigned present;
	uint32_t cylinders[8], heads[8], blocks_per_track[8];
	int read_only[8];
	// The Chaosnet interface's switches.  `IoBoard::load` refuses a
	// checkpoint whose address is not the resuming machine's, so this has
	// to match `--chaos-address`, and muir's own default is what the
	// program uses unless told otherwise.
	uint32_t chaos_address;
};

// The whole body, `Machine::save` then the `Rtl` tail, in muir's order.
void chk_rtl_body(struct chk *w, const struct cadr_image *img,
		  const struct chk_declared *d);

// Every field the fabric has no reading for, one line each, NULL-terminated.
const char *const *chk_rtl_missing(void);

// What a mutant of this file was built to do, or NULL for the real thing.
// `CHK_MUTATE` is never defined in the program that goes on the board; the
// host check builds this file again with each value and requires muir to
// refuse or to disagree.  A round trip that cannot fail is not evidence.
const char *chk_rtl_mutation(void);

#endif
