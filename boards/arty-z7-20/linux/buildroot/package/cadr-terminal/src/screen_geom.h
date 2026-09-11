// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The CADR's screen: where it is in DDR, how big it is, and which bit of
// which word is which pixel.
//
// **EVERY NUMBER HERE WAS READ OUT OF A SOURCE, AND THE SOURCE IS NAMED
// BESIDE IT.**  A picture served upside down, mirrored, or in the wrong
// colours is this program's classic failure, and it is cheap to get right
// by reading: muir's `src/simpletv.rs` is the model the fabric is checked
// against and `rtl/machine/cadr_tv.sv` and `rtl/plumbing/cadr_ddr_map.sv` are the fabric.
// The line numbers are muir at the commit `muir.commit` pins, dad7249, and
// this repository at the commit that added this file; a citation is worth
// what its commit is worth, so both are given rather than neither.
//
//   768 pixels across             muir src/simpletv.rs:65, `WIDTH`, from
//                                   `(DEFVAR MAIN-SCREEN-WIDTH (:CADR 768.))`
//   963 lines                     muir src/simpletv.rs:69, `HEIGHT`, from
//                                   `(:CADR 963.)`, "was 896. for CPT"
//   24 words to a line            muir src/simpletv.rs:73, `WORDS_PER_LINE`,
//                                   from `MAIN-SCREEN-LOCATIONS-PER-LINE`;
//                                   24 words of 32 bits is 768 pixels
//   one bit a pixel               muir src/simpletv.rs:7 and docs/tv.md
//   32,768 words in the window    muir src/simpletv.rs:43, `BUFFER_WORDS`,
//                                   `MAIN-SCREEN-BUFFER-LENGTH #o100000`;
//                                   rtl/plumbing/cadr_ddr_map.sv:71
//   23,112 of them are the screen muir src/terminal/mod.rs:88, `visible()`;
//                                   963 x 24, and the rest is not drawn
//   0x1C00_0000 in DDR            rtl/plumbing/cadr_ddr_map.sv:67, `DISPLAY_BASE`
//   word n at base + 4n           rtl/plumbing/cadr_ddr_map.sv:83, `display_byte_address`,
//                                   the offset being the low fifteen bits of
//                                   the physical address and nothing
//                                   subtracted; rtl/plumbing/cadr_xbus_ddr.sv:87
//   a frame is 15,456,000 ns      muir src/simpletv.rs:145, `FRAME_NS`, 966
//                                   lines of 16.000 us measured on the
//                                   netlist board; rtl/machine/cadr_tv.sv:123
//
// **WHICH BIT IS WHICH PIXEL.**  muir `src/simpletv.rs:254-257`:
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
// **WHICH WAY ROUND BLACK AND WHITE ARE.**  muir `src/simpletv.rs:247-250`
// and `:268-270`: a lit bit shows WHITE unless `MODE BOW` --- `MODE<2>`,
// `simpletv.rs:100`, "display one bits as black and zeros as white" --- is
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
// state, zero, which is also muir's `SimpleTv::default` and the mode both
// reference programs leave it in (docs/tv.md, "the mode register stays 0
// ... for the whole run").  docs/terminal.md says what it would take to read
// it instead of assuming it.

#ifndef SCREEN_GEOM_H
#define SCREEN_GEOM_H

#include <stdint.h>

#define SCREEN_WIDTH            768u
#define SCREEN_HEIGHT           963u
#define SCREEN_WORDS_PER_LINE   24u
#define SCREEN_WINDOW_WORDS     32768u
#define SCREEN_VISIBLE_WORDS    (SCREEN_HEIGHT * SCREEN_WORDS_PER_LINE)
#define SCREEN_WINDOW_BYTES     (SCREEN_WINDOW_WORDS * 4u)
#define SCREEN_BASE             0x1C000000u
#define SCREEN_FRAME_NS         15456000u

// `MODE<2>`, `MODE BOW`, for whoever quotes the number: muir simpletv.rs:100.
#define SCREEN_MODE_BOW         0004u

// Whether the bit at `x`, `y` is set --- muir's `SimpleTv::pixel`.
static inline int screen_lit(const uint32_t *words, unsigned x, unsigned y)
{
	const unsigned bit = y * SCREEN_WORDS_PER_LINE * 32u + x;
	return (int)((words[bit / 32u] >> (bit % 32u)) & 1u);
}

// Whether the monitor shows it white --- muir's `SimpleTv::shows_white`.
static inline int screen_shows_white(const uint32_t *words, unsigned x, unsigned y, int bow)
{
	return screen_lit(words, x, y) != (bow != 0);
}

#endif
