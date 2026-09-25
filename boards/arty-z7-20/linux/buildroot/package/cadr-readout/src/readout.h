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

#include <cadr/cadr_board.h>

#include "cadr_image.h"

// `M_AXI_GP1` decodes 0x80000000 upwards to the fabric; the console sits at
// the bottom of it, sixty-four words, four pages of sixteen.  This program
// reads two of page 0's words and nothing above them, so the 128 bytes below
// are all it maps: a readout that mapped the whole face would be claiming an
// interest in words it never touches.  The console's address is the board's
// (<cadr/cadr_board.h>): the bottom of the lightweight bridge on the DE25-Nano.
#define RO_REG_BASE   CADR_BOARD_CONSOLE_BASE
// **384 AND NOT 128 SINCE THE TWO DISPLAY BOARDS' COLOR MAPS TOOK PAGES 4
// AND 5.**  A checkpoint has to carry the map muir would have kept ---
// `tv::Tv::color_map` --- and register 4 is write only on the Xbus, the RAMs
// being off the board, so this window is the only way to ask.  Everything
// else here still reads page 0 and page 1 alone.
#define RO_REG_BYTES  384u
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

// **THE TWO DISPLAY BOARDS' COLOR MAPS, pages 4 and 5.**  Word 64 + c is the
// first display's color c and word 80 + c the color TV's: red in bits 23 to
// 16, green in 15 to 8 and blue in 7 to 0, which is `WRITE-COLOR-MAP`'s own
// channel order.  Read only.
//
// The map is write only on the Xbus, so nothing a bus cycle can do reads one
// back and the fabric keeps the sixteen entries for exactly this.  Which
// board's map a caller wants depends on what it is for: a CHECKPOINT carries
// the machine's `tv`, which is the first board, and a screen server drawing
// the color picture wants the second.
#define RO_PAGE4      64u
#define RO_PAGE5      80u
#define RO_MAP_COLORS   IMG_MAP_COLORS
#define RO_MAP_CHANNELS IMG_MAP_CHANNELS
#define RO_COLOR_MAP_WORD(board, color) \
	(((board) ? RO_PAGE5 : RO_PAGE4) + (unsigned)(color))
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
// QUUX's memory port idle and its write buffer empty (the flag word's
// `IMG_F_MEM_DRAINED`), asked of the machine as it stands: 1, 0, or -1 when
// the window answered for another address.  Always 0 on the CADR.
int ro_mem_drained(struct readout *r);

// The machine's own counters, low half then high: the high word is latched by
// the low word's read, which is the rule for the whole of page 0.
uint64_t ro_cycles(struct readout *r);
uint64_t ro_ticks(struct readout *r);

// One display board's color map, `[color][channel]` with red first: board 0
// the first display and board 1 the color TV.  Returns 1 if any of the
// forty-eight bytes is not zero, which is what says the machine has written
// one --- an unwritten map is every gun at zero.
int ro_color_map(struct readout *r, int board,
		 uint8_t map[RO_MAP_COLORS][RO_MAP_CHANNELS]);

// Everything the window can say, into `img`.  Main memory and the display are
// not here --- they are DDR and come through /dev/mem.  Returns 0, or -1.  On
// an image allocated as QUUX's this reads QUUX's sizes and `ro_read_quux`.
int ro_read_machine(struct readout *r, struct cadr_image *img);

// **WHICH MACHINE THE BITSTREAM IS**, asked of the fabric: the register
// table's entry 21 carries QUUX's signature, `0x5155`, over K and L, and the
// CADR answers `RO_NO_MEMORY` there.  Returns 1 for QUUX with `*k` and `*l`
// set, 0 for the CADR, and -1 for a stale echo or a word that is neither.
int ro_machine_is_quux(struct readout *r, unsigned *k, unsigned *l);

// QUUX's own state, into `img->qx`: the clocks, the keyboard and mouse,
// block-disk and the page.  **THE CLOCKS RUN WHILE THEY ARE READ**, so each
// timer's word carries the microsecond clock's low bits of its own tick; the
// clock is read whole before and after them and the two must be within
// `RO_QUUX_SPAN` ticks, so that those bits name one tick.  A read that took
// longer is tried again, `RO_QUUX_TRIES` times.  Returns 0, or -1.
#define RO_QUUX_SPAN  6400u	/* 64 us: half of the 128 the low bits span */
#define RO_QUUX_TRIES 8
int ro_read_quux(struct readout *r, struct cadr_image *img);

// The transaction audit at selector 11, unpacked.  **Every one of its nine
// words must carry `B05A` in its top sixteen bits or this returns -1 with
// nothing written**: a bitstream older than the audit answers
// `RO_NO_MEMORY` at that selector, an undriven path answers all ones or all
// zeros, and none of the three may be read as "no faults".  Returns 0, or -1
// with `*mark` set to the marker of the first word that was wrong.
int ro_audit(struct readout *r, struct cadr_audit *a, unsigned *mark);

#endif
