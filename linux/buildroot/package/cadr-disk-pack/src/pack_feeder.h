// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk pack program's core: the store as a cache Linux keeps.  A block the
// controller asks for goes from the pack into a slot of the store, a slot
// the CADR wrote goes back onto the pack, both through the record in DDR.
//
// WHERE THE RECORDS GO.  `rtl/cadr_ddr_map.sv` reserves 128 MB at
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
// THE RULE IS LINUX'S (`rtl/cadr_disk_pack.sv`, "the request path"), and it
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

struct feeder {
	struct pack *pack;
	struct pack_side *ps;
	// The mapped spare, `mem[0]` at physical `mem_phys`.
	volatile uint32_t *mem;
	uint32_t mem_phys;
	size_t mem_bytes;
	// Which block each slot holds, or -1.
	int32_t slot_lba[PS_SLOTS];
	// The unit the pack is on; a request on any other is denied.
	unsigned unit;
	// Second chance's hand: the slot looked at next.
	unsigned hand;
	FILE *log;
	// The tally.
	unsigned long polls, requests, served, denied, written_back, takes;
	unsigned long refused_walk, deferred_dirty, nothing_moved, pad_written, failures;
	unsigned long lost_at_start;
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

int feeder_init(struct feeder *f, struct pack *p, struct pack_side *ps,
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
// drive on `unit` made present with its read-only switch and whether its
// time is charged.  0, or -1 with `err`.
int feeder_start(struct feeder *f, unsigned unit, int read_only, int timed, char *err, size_t errlen);

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
