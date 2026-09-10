// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack feeder's core: a block from the pack into a slot of the store,
// and a slot the CADR wrote back into the pack, through the record in DDR.
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

struct feeder {
	struct pack *pack;
	struct pack_side *ps;
	// The mapped spare, `mem[0]` at physical `mem_phys`.
	volatile uint32_t *mem;
	uint32_t mem_phys;
	size_t mem_bytes;
	// Which block each slot holds, or -1.
	int32_t slot_lba[PS_SLOTS];
	FILE *log;
	// The tally.
	unsigned long served, written_back, takes, nothing_moved, pad_written, failures;
};

int feeder_init(struct feeder *f, struct pack *p, struct pack_side *ps,
		volatile uint32_t *mem, uint32_t mem_phys, size_t mem_bytes, FILE *log);

uint32_t feeder_fetch_addr(unsigned slot);
uint32_t feeder_wb_addr(unsigned slot);
// The poison a write-back area holds before a move: a function of the
// address and the word, never zero and never all ones.
uint32_t feeder_poison(uint32_t addr, unsigned i);

// Block c/h/b of the pack into `slot`: its record placed at the slot's
// fetch address and fetched by the fabric.  0, or -1 with `err`.
int feeder_serve(struct feeder *f, uint32_t c, uint32_t h, uint32_t b, unsigned slot,
		 char *err, size_t errlen);
// The slot's 259 words written back by the fabric into the slot's
// write-back address, checked to have moved, and put on the pack.
int feeder_writeback(struct feeder *f, unsigned slot, char *err, size_t errlen);
// The slot's block taken away.
int feeder_take(struct feeder *f, unsigned slot, char *err, size_t errlen);

#endif
