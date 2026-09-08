// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Where the CADR's memory lives in PS DDR3.
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
//   `simpletv::BUFFER_WORDS`, the 64 4116s on the board.  The 8 MB is room for
//   1920 x 1080 at 32 bits a pixel.  The CADR's own screen is 768 x 963 at one
//   bit, and 32bpp is not a size its window system could drive; the room is
//   for a display that is not the CADR's.
//
// The reserved region sits at the top of DDR so that Linux's own memory starts
// at zero and needs no hole in it.

`default_nettype none

// A package of constants is declared before its consumers exist --- the DDR
// bridge is the next slice --- so most of these are unused today, and will be
// again whenever a region is reserved ahead of the thing that fills it.
/* verilator lint_off UNUSEDPARAM */
package cadr_ddr_map;

  // The top 128 MB of the Arty Z7-20's 512 MB.
  localparam logic [31:0] RESERVED_BASE = 32'h1800_0000;
  localparam int unsigned RESERVED_MB   = 128;

  // Main memory. A word is 32 bits, so the byte address is the CADR's word
  // address shifted left by two.
  localparam logic [31:0] MAIN_BASE  = 32'h1800_0000;
  localparam int unsigned MAIN_WORDS = 16 * 1024 * 1024;  // 64 MB reserved

  // What the machine can address today: 60 boards of 64K words, the top four
  // slots of the 22-bit space being the display, the disk controller and the
  // Unibus. muir's `--main-memory-boards` has the same ceiling.
  localparam int unsigned MAIN_WORDS_REACHABLE = 3_932_160;

  // The display.
  localparam logic [31:0] DISPLAY_BASE  = 32'h1C00_0000;
  localparam int unsigned DISPLAY_WORDS = 2 * 1024 * 1024;  // 8 MB reserved

  // simpletv::BUFFER_WORDS, 0o100000: the 64 4116s on the SIMPLE TV.
  localparam int unsigned DISPLAY_WORDS_REACHABLE = 32768;

  // A CADR word address into a byte address in the region.
  function automatic logic [31:0] main_byte_address(input logic [21:0] phys);
    return MAIN_BASE + (32'(phys) << 2);
  endfunction

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
