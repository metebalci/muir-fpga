// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Where the CADR's memory lives in the processing system's DDR.
//
// This is the one map in the project that is expensive to change, so it is
// settled early and in one place.  The fabric constants below can be moved any
// afternoon --- the address decode is checked at every address, so a mistake
// shows at once --- but the DDR layout is shared with the Linux side: a
// reserved-memory node in the device tree, whatever loads a band, and anything
// that reads the frame buffer all agree on these offsets.  Moving it later is a
// change on both sides at once.
//
// So the regions are reserved at the size the machine could one day want, not
// the size it can reach today.  Reserving costs nothing: the Arty Z7-20 has
// 512 MB and this takes a quarter of it, leaving Linux 384 MB.
//
//   base          size    words       what
//   0x1800_0000   64 MB   16,777,216  main memory
//   0x1C00_0000    8 MB    2,097,152  display
//   0x1C80_0000   56 MB               spare
//
// The display's 8 MB holds BOTH display boards' frame buffers, the normal
// TV's at its base and the color TV's 128 KB above it, which is the first
// board's own 32,768 words.  Neither board grows and the region does not:
// what was reserved for one display is room for a dozen.
//
// WHAT THE MACHINE CAN ACTUALLY REACH TODAY, which is much less:
//
//   Main memory is 3,932,160 words --- 15 MB of the 64 reserved.  The CADR's
//   physical address is 22 bits: the level-2 map entry carries a 14-bit page
//   frame (`Translation::page`) and `VMA<7:0>` is the offset, so `-PMA21..8`
//   and `-VMA7..0` are all that cross the cables and all the Xbus carries.
//   The 64 MB is room for a machine whose physical address had been widened to
//   24 bits, which the map RAM has the spare bits for --- the level-2 word is
//   24 bits wide and only 16 are used --- but which would need new lines out
//   of VMEMDR, new cable wires, new `-XADDR`s and microcode that writes the
//   wider frame.  That is a fork of the machine and not a change here.
//
//   The display is 32,768 words --- 128 KB of the 8 MB reserved --- which is
//   `tv::BUFFER_WORDS`, the 64 4116s on the board.  The 8 MB is room for
//   1920 x 1080 at 32 bits a pixel.  The CADR's own screen is 768 x 963 at one
//   bit, and 32bpp is not a size its window system could drive; the room is
//   for a display that is not the CADR's.
//
// The reserved region sits at the top of DDR so that Linux's own memory starts
// at zero and needs no hole in it.
//
// **THE BASE IS THE BOARD'S, AND THE LAYOUT UNDER IT IS NOT.**  The DE25-Nano's
// processor has 1 GB of LPDDR4 at `0x8000_0000` to `0xBFFF_FFFF`, and the fabric
// sees it at those same addresses through the FPGA-to-SDRAM bridge.  Its
// 128 MB are reserved at `0xB000_0000`, the second 128 MB from the top, and
// not at the top: U-Boot on this part relocates itself to the top of DDR
// without looking at a reserved-memory node, so the top 128 MB is U-Boot's
// until Linux runs, and the fabric's gate is opened by U-Boot.
//
//   board          RESERVED_BASE   main memory    display
//   Arty, Cora     0x1800_0000     0x1800_0000    0x1C00_0000
//   DE25-Nano      0xB000_0000     0xB000_0000    0xB400_0000
//
// **ONE DEFINE CHOOSES**, `CADR_DDR_MAP_DE25_NANO`, which the DE25-Nano's
// flows set and no other flow does.  A package cannot take a parameter, and
// the base is read deep inside `cadr_machine`, where a parameter would have to
// be carried through two modules of the machine that are MIT's and not the
// board's.  The define is not trusted on its own:
// `boards/de25-nano/cadr_de25.sv` states its own base and stops elaboration
// when this package disagrees, so a flow that forgot the define builds nothing
// rather than a board that writes the Zynq's addresses into the processor's
// address map.

`default_nettype none

// A package of constants is declared before its consumers exist --- the DDR
// bridge is the next slice --- so most of these are unused today, and will be
// again whenever a region is reserved ahead of the thing that fills it.
/* verilator lint_off UNUSEDPARAM */
package cadr_ddr_map;

`ifdef CADR_DDR_MAP_DE25_NANO
  // The second 128 MB from the top of the DE25-Nano's 1 GB: see the header.
  localparam logic [31:0] RESERVED_BASE = 32'hB000_0000;
`else
  // The top 128 MB of the Arty Z7-20's 512 MB.
  localparam logic [31:0] RESERVED_BASE = 32'h1800_0000;
`endif
  localparam int unsigned RESERVED_MB   = 128;

  // Main memory. A word is 32 bits, so the byte address is the CADR's word
  // address shifted left by two.
`ifdef CADR_DDR_MAP_DE25_NANO
  localparam logic [31:0] MAIN_BASE  = 32'hB000_0000;
`else
  localparam logic [31:0] MAIN_BASE  = 32'h1800_0000;
`endif
  localparam int unsigned MAIN_WORDS = 16 * 1024 * 1024;  // 64 MB reserved

  // What the machine can address today: 60 boards of 64K words, the top four
  // slots of the 22-bit space being the display, the disk controller and the
  // Unibus. muir's `--main-memory-boards` has the same ceiling.
  localparam int unsigned MAIN_WORDS_REACHABLE = 3_932_160;

  // The display.
`ifdef CADR_DDR_MAP_DE25_NANO
  localparam logic [31:0] DISPLAY_BASE  = 32'hB400_0000;
`else
  localparam logic [31:0] DISPLAY_BASE  = 32'h1C00_0000;
`endif
  localparam int unsigned DISPLAY_WORDS = 2 * 1024 * 1024;  // 8 MB reserved

  // tv::BUFFER_WORDS, 0o100000: the 64 4116s on the SIMPLE TV.
  localparam int unsigned DISPLAY_WORDS_REACHABLE = 32768;

  // The second display board, the color TV, at the first board's own size
  // above it: 0x1C02_0000.  Its buffer is `tv::BUFFER_WORDS` like the first's
  // --- the board answers all 32,768 words whatever the picture uses --- and
  // `sys/window/color.lisp`'s `COLOR:MAKE-SCREEN` draws 576 by 454 at four
  // bits a pixel in the bottom 32,688 of them, 72 words a line.
  //
  // **NOTHING ON THE LINUX SIDE HAS TO GROW FOR IT.**  The reserved-memory
  // node in the device tree reserves all 128 MB from RESERVED_BASE, and this
  // is inside the display's 8 MB, so the board's two screens are two windows
  // of a region Linux already keeps its hands off.
  localparam logic [31:0] COLOR_DISPLAY_BASE =
      DISPLAY_BASE + 32'(DISPLAY_WORDS_REACHABLE << 2);

  // A CADR word address into a byte address in the region.
  function automatic logic [31:0] main_byte_address(input logic [21:0] phys);
    return MAIN_BASE + (32'(phys) << 2);
  endfunction

  // A word of the display's window into a byte address in its region.  The
  // window is `tv::BUFFER_WORDS` long and aligned to its own size, so
  // its offset is the low fifteen bits of the address and nothing is
  // subtracted; `rtl/machine/cadr_tv.sv` decodes the window and `rtl/plumbing/cadr_xbus_ddr.sv`
  // answers it at this base.
  function automatic logic [31:0] display_byte_address(input logic [14:0] offset);
    return DISPLAY_BASE + (32'(offset) << 2);
  endfunction

  // And a word of the color TV's window, the same arithmetic at the other
  // base.  `rtl/machine/cadr_tv.sv` decodes the window --- the second
  // instance, strapped to `tv::COLOR_TV` --- and
  // `rtl/plumbing/cadr_xbus_ddr.sv` answers it here.
  function automatic logic [31:0] color_display_byte_address(input logic [14:0] offset);
    return COLOR_DISPLAY_BASE + (32'(offset) << 2);
  endfunction

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
