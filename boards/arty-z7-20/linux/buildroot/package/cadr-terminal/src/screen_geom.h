// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The CADR's screen: where it is in DDR, how big it is, and which bit of
// which word is which pixel.
//
// **EVERY NUMBER HERE WAS READ OUT OF A SOURCE, AND THE SOURCE IS NAMED
// BESIDE IT.**  A picture served upside down, mirrored, or in the wrong
// colors is this program's classic failure, and it is cheap to get right
// by reading: muir's `src/tv.rs` is the model the fabric is checked
// against and `rtl/machine/cadr_tv.sv` and `rtl/plumbing/cadr_ddr_map.sv` are the fabric.
// The line numbers are muir at the commit `muir.commit` pins, bfba7f3, and
// this repository at the commit that added this file; a citation is worth
// what its commit is worth, so both are given rather than neither.
//
//   768 pixels across             muir src/tv.rs:100, `WIDTH`, from
//                                   `(DEFVAR MAIN-SCREEN-WIDTH (:CADR 768.))`
//   963 lines                     muir src/tv.rs:104, `HEIGHT`, from
//                                   `(:CADR 963.)`, "was 896. for CPT"
//   24 words to a line            muir src/tv.rs:108, `WORDS_PER_LINE`,
//                                   from `MAIN-SCREEN-LOCATIONS-PER-LINE`;
//                                   24 words of 32 bits is 768 pixels
//   one bit a pixel               muir src/tv.rs:7 and docs/tv.md
//   32,768 words in the window    muir src/tv.rs:78, `BUFFER_WORDS`,
//                                   `MAIN-SCREEN-BUFFER-LENGTH #o100000`;
//                                   rtl/plumbing/cadr_ddr_map.sv:71
//   23,112 of them are the screen muir src/terminal/mod.rs:88, `visible()`;
//                                   963 x 24, and the rest is not drawn
//   0x1C00_0000 in DDR            rtl/plumbing/cadr_ddr_map.sv:67, `DISPLAY_BASE`;
//                                   a Zynq board's, and <cadr/cadr_board.h>
//                                   has every board's
//   word n at base + 4n           rtl/plumbing/cadr_ddr_map.sv:83, `display_byte_address`,
//                                   the offset being the low fifteen bits of
//                                   the physical address and nothing
//                                   subtracted; rtl/plumbing/cadr_xbus_ddr.sv:87
//   a frame is 15,456,000 ns      muir src/tv.rs:331, `FRAME_NS`, 966
//                                   lines of 16.000 us measured on the
//                                   netlist board; rtl/machine/cadr_tv.sv:123
//
// **WHICH BIT IS WHICH PIXEL.**  muir `src/tv.rs:599-602`:
//
//     pub fn pixel(&self, x: usize, y: usize) -> bool {
//         let bit = y * WORDS_PER_LINE * 32 + x;
//         self.buffer[bit / 32] >> (bit % 32) & 1 != 0
//     }
//
// So a line is 24 consecutive words, the first line first; within a line the
// pixels run from the LOW end of the first word, and **bit 0 of a word is
// the LEFTMOST of the 32 pixels that word carries**.  muir's terminal says
// the same in its own words at `src/terminal/mod.rs:216` --- "entry `b` is
// the frame-buffer byte `b`, its bit 0 first, bit 0 being the leftmost
// pixel" --- and restates the whole rule at `src/terminal/mod.rs:97`, which
// is the one place two expressions of it are held to each other
// (`tests/terminal.rs`, pixel for pixel).  This is the third expression and
// `screen_test.c` anchors it on hand-computed pixels rather than on a round
// trip, because a round trip through a reader and a writer that are wrong
// the same way agrees with itself.
//
// **WHICH WAY ROUND BLACK AND WHITE ARE.**  muir `src/tv.rs:592-595`
// and `:607-609`: a lit bit shows WHITE unless `MODE BOW` --- `MODE<2>`,
// `tv.rs:260`, "display one bits as black and zeros as white" --- is
// set in the display's mode register, and the other way round when it is.
// So a screen of zeros with BOW clear is BLACK, and that is what a real
// machine looks like: muir drawing MIT's System 100 band at microcycle
// 200,000,000 has mode 0 and 7,572 of its 739,584 pixels lit --- white text
// on black, one per cent of the screen.
//
// **AND THIS PROGRAM CANNOT READ THAT BIT.**  The mode register is four
// flops in the fabric (`rtl/machine/cadr_tv.sv:141`, cleared to zero at `:195`) and
// nothing carries it to the processing system: `M_AXI_GP0` is the disk's
// and `M_AXI_GP1` the console's, and neither has a word for it.  So BOW is
// this program's `--bow` and its default is the fabric's own power-on
// state, zero, which is also muir's `Tv::default` and the mode both
// reference programs leave it in (docs/tv.md, "the mode register stays 0
// ... for the whole run").  docs/terminal.md says what it would take to read
// it instead of assuming it.

#ifndef SCREEN_GEOM_H
#define SCREEN_GEOM_H

#include <stdint.h>

#include <cadr/cadr_board.h>

#define SCREEN_WIDTH            768u
#define SCREEN_HEIGHT           963u
#define SCREEN_WORDS_PER_LINE   24u
#define SCREEN_WINDOW_WORDS     32768u
#define SCREEN_VISIBLE_WORDS    (SCREEN_HEIGHT * SCREEN_WORDS_PER_LINE)
#define SCREEN_WINDOW_BYTES     (SCREEN_WINDOW_WORDS * 4u)
// The display's base is the board's (<cadr/cadr_board.h>): 0x1C000000 on the
// Zynq boards and 0xB4000000 on the DE25-Nano, 64 MB into the reservation on
// both.
#define SCREEN_BASE             CADR_BOARD_DISPLAY_BASE
// The display board's own frame, in the machine's nanoseconds: muir's
// `FRAME_NS`, 966 lines of 16.000 us, which `rtl/machine/cadr_tv.sv` makes as
// 1,545,600 ticks of MIT's 10 ns grid.  This one is held to muir and never
// moves.
#define SCREEN_FRAME_NS         15456000u

// AND THE SAME FRAME IN REAL TIME, WHICH IS THE SAME NUMBER AGAIN.  A tick
// is 10 ns on this board --- `boards/arty-z7-20/cadr_arty.sv`'s MMCM --- and
// MIT's grid is 10 ns too, so the fabric takes 1,545,600 x 10 = 15,456,000
// real nanoseconds over a frame and the vertical interrupt arrives at the
// display board's own 64.70 Hz.  This program compares against
// `CLOCK_MONOTONIC`, so it is the real frame it needs.  At the 5 ns grid the
// board ran at half speed and this was 30,912,000.
//
// **THE TWO ARE KEPT APART RATHER THAN MERGED**, because they are different
// quantities that only coincide while the grid and the board's tick do: a
// board built with a different tick moves this one and not the machine's.
#define SCREEN_FRAME_REAL_NS    15456000u

// `MODE<2>`, `MODE BOW`, for whoever quotes the number: muir tv.rs:260.
#define SCREEN_MODE_BOW         0004u

// ---- THE SECOND SCREEN, the color TV --------------------------------------
//
// MIT's second display board, `cadrtv/lmtv.order`'s "For the normal TV, x is
// 6.  For the color TV, x is 5": a LISPM TV strapped to 0o17200000 with its
// control words at 0o17377750, carrying a color monitor of its own.  Its
// numbers, each read out of a source as the first screen's were:
//
//   576 pixels across             muir src/tv.rs, `COLOR_WIDTH`, from
//                                   `COLOR:MAKE-SCREEN`'s `(:WIDTH 576.)`
//   454 lines                     muir src/tv.rs, `COLOR_HEIGHT`, from
//                                   `(:HEIGHT 454.)`, the 227 picture lines
//                                   of each of COLOR:SYNC's two NTSC fields
//   four bits a pixel             muir src/tv.rs, `COLOR_BITS_PER_PIXEL`,
//                                   from `(:BITS-PER-PIXEL 4)`: a pixel is a
//                                   color, an address into the sixteen the
//                                   color map holds
//   72 words to a line            muir src/tv.rs, `COLOR_WORDS_PER_LINE`,
//                                   576 * 4 / 32
//   32,768 words in the window    the same `BUFFER_WORDS` as the first
//                                   board: the board answers all of them
//                                   whatever the picture uses
//   0x1C02_0000 in memory         rtl/plumbing/cadr_ddr_map.sv,
//                                   `COLOR_DISPLAY_BASE`: the first board's
//                                   own 32,768 words above it, in the same
//                                   reserved region
//
// **WHICH NIBBLE IS WHICH PIXEL.**  muir `src/tv.rs`'s `Tv::color`:
//
//     let at = y * COLOR_WORDS_PER_LINE + x / 8;
//     (self.buffer[at] >> (x % 8 * COLOR_BITS_PER_PIXEL)) as u8 & 0o17
//
// So a line is 72 consecutive words, the first line first; within a word the
// pixels run from the LOW nibble, and the low nibble is the LEFTMOST of the
// eight pixels that word carries --- which is the first screen's rule with
// four bits where it has one.
//
// **AND `MODE BOW` DOES NOT REACH IT.**  A four-bit pixel is an address into
// the map and there is no bit to invert; `Tv::color` takes no notice of the
// mode register, and neither does this.  A color screen's "black" is
// whatever color 0 is in the map the machine wrote.
#define SCREEN_COLOR_WIDTH          576u
#define SCREEN_COLOR_HEIGHT         454u
#define SCREEN_COLOR_WORDS_PER_LINE 72u
#define SCREEN_COLOR_BPP            4u
#define SCREEN_COLORS               16u
#define SCREEN_COLOR_VISIBLE_WORDS  (SCREEN_COLOR_HEIGHT * SCREEN_COLOR_WORDS_PER_LINE)
#define SCREEN_COLOR_BASE           CADR_BOARD_COLOR_BASE

// The larger of the two screens, in frame-buffer words: 963 x 24 = 23,112
// against 454 x 72 = 32,688.  **The color screen is the bigger one**, which
// is worth knowing before sizing anything by the first board's figure.
#if SCREEN_COLOR_VISIBLE_WORDS > SCREEN_VISIBLE_WORDS
#define SCREEN_MAX_VISIBLE_WORDS SCREEN_COLOR_VISIBLE_WORDS
#else
#define SCREEN_MAX_VISIBLE_WORDS SCREEN_VISIBLE_WORDS
#endif
#if SCREEN_COLOR_HEIGHT > SCREEN_HEIGHT
#define SCREEN_MAX_HEIGHT SCREEN_COLOR_HEIGHT
#else
#define SCREEN_MAX_HEIGHT SCREEN_HEIGHT
#endif

// Whether the bit at `x`, `y` is set --- muir's `Tv::pixel`.
static inline int screen_lit(const uint32_t *words, unsigned x, unsigned y)
{
	const unsigned bit = y * SCREEN_WORDS_PER_LINE * 32u + x;
	return (int)((words[bit / 32u] >> (bit % 32u)) & 1u);
}

// Whether the monitor shows it white --- muir's `Tv::shows_white`.
static inline int screen_shows_white(const uint32_t *words, unsigned x, unsigned y, int bow)
{
	return screen_lit(words, x, y) != (bow != 0);
}

// The color at `x`, `y` on the second screen --- muir's `Tv::color` --- as
// an index into the sixteen the map holds.
static inline unsigned screen_color_index(const uint32_t *words, unsigned x, unsigned y)
{
	const unsigned at = y * SCREEN_COLOR_WORDS_PER_LINE + x / 8u;
	return (words[at] >> (x % 8u * SCREEN_COLOR_BPP)) & 0xFu;
}

#endif
