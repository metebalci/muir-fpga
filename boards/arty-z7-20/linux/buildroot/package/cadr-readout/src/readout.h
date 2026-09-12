// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console's window as this program uses it, and the readout in it.
//
// **THE WINDOW'S ADDRESSES ARE COPIED FROM `cadr-console`'s
// `console_face.h`, DELIBERATELY AND NOT BY ACCIDENT.**  Buildroot's `local`
// site method rsyncs only THIS package's `src/` into the build tree, so a
// relative include of a sibling package's header builds on the host and fails
// under Buildroot --- `cadr-console.mk` records that, and `pack_side.h` one
// package further along has the same seam for the same reason.  What is
// copied is the handful of constants a driver needs and nothing else;
// `rtl/plumbing/cadr_console.sv` is the authority for all of them.
//
// **AND THE FACE IS REACHED THROUGH TWO FUNCTION POINTERS** so that the host
// check can put a model of the fabric behind them and the board puts
// /dev/mem.  Again `pack_side.h`'s seam, copied rather than reinvented.

#ifndef READOUT_H
#define READOUT_H

#include <stdint.h>

#include "cadr_image.h"

// `M_AXI_GP1` decodes 0x80000000 upwards to the fabric; the console sits at
// the bottom of it, thirty-two words, two pages of sixteen.
#define RO_REG_BASE   0x80000000u
#define RO_REG_BYTES  128u
#define RO_IDENT_WORD 0x434F4E53u	/* "CONS" */
#define RO_UNMAPPED   0xBCB0B1ACu	/* ~IDENT */

// Page 0.
enum ro_p0 { RO_IDENT = 0, RO_STAT = 1, RO_CYCLES = 2, RO_CYCLESH = 3,
	     RO_TICKS = 4, RO_TICKSH = 5, RO_RESET = 6, RO_VMA = 7,
	     RO_Q = 8, RO_MD = 9,
	     // The readout window: word 10 is written with
	     // `{sel<3:0>, word<13:0>}` and read as the echo of the address
	     // the word beside it was read at; words 11 and 12 are that
	     // word's two halves.  **A read of word 10 latches all three**,
	     // exactly as a read of word 7 latches VMA, Q and MD.
	     RO_ADDR = 10, RO_DATA_LO = 11, RO_DATA_HI = 12 };

// Page 1: word 16 + k is diagnostic register k.
#define RO_PAGE1      16u
#define RO_SPY(k)     (RO_PAGE1 + (unsigned)(k))
#define RO_LOST_BIT   0x00010000u

// The diagnostic registers this program uses, muir's `spy.rs` names.
enum ro_spy { RO_SPY_PC = 5, RO_SPY_FLAG_1 = 8, RO_SPY_CLK_W = 3 };
#define RO_CLK_RUN 0x1u

// The reserved selector, and what the fabric answers for one.  Neither is a
// word a memory can hold or an address a program may ask for, so "nothing has
// been asked" is not a value the instrument can mean.
#define RO_NONE        0x3FFFFu
#define RO_NO_MEMORY   0xA5A55A5AA5A5ull

struct readout {
	uint32_t (*read)(struct readout *r, unsigned word);
	void (*write)(struct readout *r, unsigned word, uint32_t v);
	void *ctx;
	// What it did, for the program's own output.
	unsigned long reads, writes, stale;
};

// IDENT reads "CONS".  0 if it does, -1 with `*got` otherwise.
int ro_ident_ok(struct readout *r, uint32_t *got);

// One word out of the window: the address is written, then the echo and the
// two halves are read.  **The echo is compared with the address asked for**
// and a disagreement is an error rather than a word --- which is the whole
// reason the echo exists.  Returns 0, or -1 with nothing written to `*word`.
int ro_word(struct readout *r, unsigned sel, unsigned addr, uint64_t *word);

// A run of words of one memory, `ro_word` at a time.
int ro_block(struct readout *r, unsigned sel, unsigned n, uint64_t *into);
int ro_block32(struct readout *r, unsigned sel, unsigned n, uint32_t *into);

// Halt the machine and start it again: a write of zero to the clock control
// register and of `RUN` back.  **The file is of a halted machine and this is
// not a convenience**: a read taken while the datapath moves is torn, and the
// console's own documentation says to halt first.
void ro_halt(struct readout *r);
void ro_start(struct readout *r);
int ro_is_halted(struct readout *r);

// The machine's own counters, low half then high: the high word is latched by
// the low word's read, which is the rule for the whole of page 0.
uint64_t ro_cycles(struct readout *r);
uint64_t ro_ticks(struct readout *r);

// Everything the window can say, into `img`.  Main memory and the display are
// not here --- they are DDR and come through /dev/mem.  Returns 0, or -1.
int ro_read_machine(struct readout *r, struct cadr_image *img);

// The transaction audit at selector 11, unpacked.  **Every one of its nine
// words must carry `B05A` in its top sixteen bits or this returns -1 with
// nothing written**: a bitstream older than the audit answers
// `RO_NO_MEMORY` at that selector, an undriven path answers all ones or all
// zeros, and none of the three may be read as "no faults".  Returns 0, or -1
// with `*mark` set to the marker of the first word that was wrong.
int ro_audit(struct readout *r, struct cadr_audit *a, unsigned *mark);

#endif
