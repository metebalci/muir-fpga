// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk pack program's core: the store as a cache Linux keeps.  A block the
// controller asks for goes from the pack into a slot of the store, a slot
// the CADR wrote goes back onto the pack, both through the record in DDR.
//
// WHERE THE RECORDS GO.  `rtl/plumbing/cadr_ddr_map.sv` reserves 128 MB at
// 0x1800_0000 for the machine: 64 MB main memory, 8 MB display, and 56 MB
// spare from 0x1C80_0000.  The records go in the spare, one area per slot
// for fetches and a second per slot for write-backs, 2 KB apart: a record is
// 1,036 bytes and 128-byte alignment is what the fabric demands, so that no
// sixteen-beat burst crosses 4 KB; at a 2 KB stride from a 2 KB-aligned base
// a record never does.  Fetch and write-back areas are separate so that a
// write-back which moved nothing cannot read back as the block it was
// fetched from --- the write-back area is POISONED before every move and a
// record still all poison afterwards is reported and not committed to the
// pack.  `feeder_test.c` checks the alignment and the region of every
// address the feeder chooses.
//
// THE DRIVE BAY.  `pack_bay.h` holds the eight names and the eight open
// packs; this file holds the rules about *when* the bay may change and what
// has to happen first.  `feeder_bay_scan` is one look at the eight names and
// is called on an interval (250 ms by default) rather than on every poll,
// because a stat of eight names four thousand times a second buys nothing a
// quarter of a second does not.  Four things can have happened to a name:
//
//   IT APPEARED     ---  the unit comes present, its write-protect switch is
//                        the file's read-only mark, and its attention is
//                        raised, as a drive's is when it comes ready
//   IT WENT AWAY    ---  everything the machine has written and this program
//                        has not yet put back is FLUSHED FIRST, every slot of
//                        that unit is taken away, the unit goes absent and
//                        its attention is raised
//   ITS MARK MOVED  ---  the write-protect switch flips.  Going read-only
//                        flushes first, because a block written while the
//                        pack was writable belongs on the pack and not in a
//                        store about to be told it may not write
//   IT WAS REPLACED ---  a different file under the same name, or the same
//                        file at a different size: the pack that was there
//                        went away and the one that is there arrived, in
//                        that order, in one pass
//
// **NONE OF IT HAPPENS IN THE MIDDLE OF A TRANSFER.**  A scan that finds the
// channel walking (CTL's `ch_active`) changes nothing and says so, and the
// caller tries again on its next poll --- 250 us, and a transfer is a block
// or a chain of them, so the wait is under a millisecond.  A real drive will
// not let you open the door with the heads loaded.
//
// **RENAMING A PACK IS SAFE AND DELETING ONE IS NOT, AND THE DIFFERENCE IS
// THE LINK COUNT.**  A renamed file is still a file: the descriptor this
// program holds followed it, so the flush lands in the file under its new
// name and nothing is lost.  A deleted file is nameless: the flush would go
// into clusters the kernel frees at the last close, so this program does not
// pretend --- it says which unit and exactly how many blocks were lost, and
// names them.  `pack_alive` is the test and renaming is the gesture to
// document.
//
// **AND A PACK WRITTEN OVER WHERE IT LIES IS A THIRD CASE, NOT THE
// SECOND.**  `scp` onto a name already in use truncates the file and refills
// it, so the link count says the file is alive --- and it is --- but its
// contents are becoming somebody else's pack, and the old pack's words would
// corrupt the new one.  So flushing is refused there on purpose and the
// blocks are called lost, which is the one place `pack_alive` is not the
// question being asked.
//
// The attention this file raises is written into DRIVE's bits 24:17.
// **The fabric does not act on that field yet**; `pack_side.h` says which
// two lines of RTL it wants and nothing else here depends on it.
//
// THE RULE IS LINUX'S (`rtl/plumbing/cadr_disk_pack.sv`, "the request path"), and it
// is second chance over the twenty-four slots: a hand goes round; a slot
// whose REF bit is up is passed and the bit cleared, the first slot whose
// bit is down is taken --- written back first if it is DIRTY --- and never
// the slot the walk is on, which the face tells this program by refusing
// the move on it.  A request for a block off the pack, or on a unit this
// program has no pack for, is DENIED and the walk takes its miss.  DIRTY
// slots are written back at leisure on the dirty event, and always before
// they are fetched into or taken away, or the CADR's write is lost.
//
// WHAT THE STORE HELD BEFORE THIS PROGRAM STARTED IS UNKNOWN TO IT: the
// tags are in the fabric and not readable over GP0.  So `feeder_start`
// takes every slot away, and a slot that was DIRTY then is reported as
// lost --- its block cannot be named.  On a board the store is empty at
// configuration and the feeder starts once, so this is a restart's cost.

#ifndef PACK_FEEDER_H
#define PACK_FEEDER_H

#include <stdint.h>
#include <stdio.h>

#include "pack_bay.h"
#include "pack_file.h"
#include "pack_side.h"

#define FEEDER_SPARE_BASE   0x1C800000u
#define FEEDER_SPARE_BYTES  (56u * 1024u * 1024u)
#define FEEDER_RECORD_STRIDE 0x800u
#define FEEDER_FETCH_OFF    0x00000u
#define FEEDER_WB_OFF       0x10000u
// What the feeder maps of the spare: both areas for all 24 slots.
#define FEEDER_MAP_BYTES    0x20000u

// How many requests are named on the console one by one before they are
// only counted, and how many distinct denied blocks are named.
#define FEEDER_NAMED_REQUESTS 3
#define FEEDER_NAMED_DENIALS  16

// How many blocks of one loss are named on the console before they are only
// counted.
#define FEEDER_NAMED_LOSSES 16
// How many passes a removal's flush may take before the rest is called
// stuck.  The channel is idle when this runs, so a refusal is the walk's
// last beat and one more pass clears it.
#define FEEDER_FLUSH_PASSES 8

struct feeder {
	struct bay *bay;
	struct pack_side *ps;
	// The mapped spare, `mem[0]` at physical `mem_phys`.
	volatile uint32_t *mem;
	uint32_t mem_phys;
	size_t mem_bytes;
	// Which block each slot holds, or -1, and on which unit's pack.  **THE
	// UNIT IS PART OF IT**: eight drives can be in the bay and a store
	// holding two drives' blocks under one disk address would put one
	// drive's block on the other's pack.
	int32_t slot_lba[PS_SLOTS];
	int8_t slot_unit[PS_SLOTS];
	// Whether the drive's own seek and rotational times are charged
	// (`Controller::timed`).  A property of the run, not of a file, so it
	// stays an option and is written into DRIVE with every seam change.
	int timed;
	// Second chance's hand: the slot looked at next.
	unsigned hand;
	FILE *log;
	// The tally.
	unsigned long polls, requests, served, denied, written_back, takes;
	unsigned long refused_walk, deferred_dirty, nothing_moved, pad_written, failures;
	unsigned long lost_at_start;
	// The drive bay's tally.
	unsigned long scans, scans_deferred, appeared, went_away, protects, unprotects;
	unsigned long replaced, flushed, lost_blocks, lost_events, bay_failures;
	unsigned worst_scan_deferral, scan_deferrals_in_a_row;
	// The seam as it was last written, so a scan that changed nothing
	// writes nothing.
	uint8_t drive_present, drive_read_only;
	int bay_missing_said;
	// A file in the bay that could not be opened is said ONCE and not four
	// times a second: which file was refused, per unit, so that the same
	// one is only counted afterwards and a different one is said afresh.
	ino_t refused_ino[BAY_UNITS];
	off_t refused_size[BAY_UNITS];
	// The last failure, for the summary line: a count that names nothing
	// is not a report.
	char last_failure[256];
	// How many passes a dirty slot has been refused as the walk's in a row,
	// per slot, and the longest run seen: bounded, so a slot the walk never
	// leaves is said rather than deferred for ever.
	unsigned deferred_runs[PS_SLOTS];
	unsigned longest_deferral;
	// What has been named on the console.
	unsigned long named_requests;
	uint32_t named_denials[FEEDER_NAMED_DENIALS];
	unsigned n_named_denials;
	// The request last answered, so a REQ still standing for it --- the
	// tag lands a few ticks after the move's done --- is not answered
	// twice.
	uint32_t last_answered;
	int have_last;
	unsigned repeat_serves;
};

int feeder_init(struct feeder *f, struct bay *bay, struct pack_side *ps,
		volatile uint32_t *mem, uint32_t mem_phys, size_t mem_bytes, FILE *log);

uint32_t feeder_fetch_addr(unsigned slot);
uint32_t feeder_wb_addr(unsigned slot);
// The poison a write-back area holds before a move: a function of the
// address and the word, never zero and never all ones.
uint32_t feeder_poison(uint32_t addr, unsigned i);

// Block c/h/b of the pack, on `unit`, into `slot`: its record placed at the
// slot's fetch address and fetched by the fabric.  0; PS_WALK_SLOT if the
// slot is the walk's; -1 with `err`.
int feeder_serve(struct feeder *f, unsigned unit, uint32_t c, uint32_t h, uint32_t b, unsigned slot,
		 char *err, size_t errlen);
// The slot's 259 words written back by the fabric into the slot's
// write-back address, checked to have moved, and put on the pack.  0;
// PS_WALK_SLOT; -1 with `err`.
int feeder_writeback(struct feeder *f, unsigned slot, char *err, size_t errlen);
// The slot's block taken away.  0; PS_WALK_SLOT; -1 with `err`.
int feeder_take(struct feeder *f, unsigned slot, char *err, size_t errlen);

// The cache begins: every slot taken away (a dirty one reported lost), the
// seam written empty, and then one scan of the bay, which brings up whatever
// packs are already in it.  `timed` is remembered and written with every
// seam change afterwards.  0, or -1 with `err`.
int feeder_start(struct feeder *f, int timed, char *err, size_t errlen);

// One look at the eight names, and whatever it implies.  Returns 0 when it
// ran, 1 when it changed nothing because the channel was walking (call again
// on the next poll), or -1 with `err` on a failure it could not get past.
int feeder_bay_scan(struct feeder *f, char *err, size_t errlen);

// Every dirty slot of one unit written back, in up to `passes` passes: what
// a pack leaving the bay costs before its descriptor is closed.  `wrote`
// takes the number that landed.  Returns the number still dirty.
unsigned feeder_flush_unit(struct feeder *f, unsigned unit, unsigned passes,
			   unsigned long *wrote, char *err, size_t errlen);
// Every slot holding a block of one unit taken away.  Returns how many.
unsigned feeder_take_unit(struct feeder *f, unsigned unit, char *err, size_t errlen);

// One pass over the face: IRQ read and cleared, REQ answered --- served or
// denied --- and every DIRTY slot written back that the walk is not on.
// Returns how many moves and denials it made, or -1 with `err` on a failure
// it could not get past (the pass is otherwise complete).
int feeder_poll(struct feeder *f, char *err, size_t errlen);

// How many passes in a row a dirty slot may be refused as the walk's before
// it is said: a block's move is some 256 bus cycles, a Read All a
// revolution of 16.7 ms, so at 250 us a poll a hundred passes is 25 ms.
#define FEEDER_DEFERRAL_CAP 100

// Every dirty slot written back, for a stop: as many passes as it takes,
// up to `passes`.  Returns the number still dirty.
unsigned feeder_flush(struct feeder *f, unsigned passes, char *err, size_t errlen);

#endif
