// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Where the CADR's memory lives in the processing system's DDR.
//
// This is the one map in the project that is expensive to change, so it is
// settled in one place.  The fabric constants below can be moved any
// afternoon --- the address decode is checked at every address, so a mistake
// shows at once --- but the DDR layout is shared with the Linux side: a
// reserved-memory node in the device tree, whatever loads a band, and anything
// that reads the frame buffer all agree on these offsets.  Moving it is a
// change on both sides at once.
//
// THE RESERVATION HOLDS WHAT THE MACHINE CAN REACH, AND NO MORE; everything
// else is Linux's.  On the Arty Z7-20, the Cora Z7-07S and the Kria KR260 the
// layout is
//
//   offset        size     words       what
//   + 0           16 MB    4,194,304   main memory
//   + 16 MB        1 MB      262,144   the display: both TV boards' buffers
//   + 17 MB      128 KB                the disk pack program's records
//   + 17.125 MB                        the end of the reservation
//
// and on the DE25-Nano the same.  The three areas abut, and the reservation
// is their sum, `RESERVED_BYTES`, 17.125 MB.
//
// Main memory is 4M words at 4 bytes a word.  The CADR's physical address is
// 22 bits, 4M words: the level-2 map entry carries a 14-bit page frame
// (`Translation::page`) and `VMA<7:0>` is the offset, so `-PMA21..8` and
// `-VMA7..0` are all that cross the cables and all the Xbus carries.  Of those
// 4M words the machine can fit 60 boards of 64K words, 3,932,160 words or
// 15 MB (`MAIN_WORDS_REACHABLE`); the top four slots are the display, the
// disk controller and the Unibus.  So every 22-bit address `main_byte_address`
// can make is inside the 16 MB, whatever the map holds.  QUUX to revision 12
// has the same 22-bit space and the same 60 boards' ceiling, and its main
// memory is here too.
//
// The display's 1 MB holds BOTH display boards' frame buffers, the normal
// TV's at its base and the color TV's 128 KB above it, which is the first
// board's own 32,768 words: 256 KB in use.  QUUX's video controller (to
// revision 13) has one buffer of up to 64K words from the same base,
// `VIDEO_WORDS_MAX`, 256 KB, 64,800 words at 1920 by 1080.
//
// The records are the disk pack program's: one area per slot for a fetch and
// one for a write-back, all 24 slots (`pack_feeder.h`, `FEEDER_MAP_BYTES`).
// Nothing else is in the reservation.  U-Boot loads and relocates outside it
// on every board (`tools/reserved_check.py` models where), and the programs
// that map it map main memory, the display and the records alone.
//
// **THE DISPLAY STAYS WHERE IT WAS, AND MAIN MEMORY SITS DIRECTLY BELOW IT.**
// The reservation was 128 MB with main memory at its base and the display
// 64 MB up; it is now the 17.125 MB around the same display, so that QUUX
// revision 13's main memory, which fills the room below the display, did not
// move, and so that every board's new reservation is inside its old one.  A
// card whose loader still carries the old reservation in its own tree keeps
// its relocation clear of the new one.
//
// **THE BASE IS THE BOARD'S, AND THE LAYOUT UNDER IT IS NOT.**  The DE25-Nano's
// processor has 1 GB of LPDDR4 at `0x8000_0000` to `0xBFFF_FFFF`, and the fabric
// sees it at those same addresses through the FPGA-to-SDRAM bridge.  Its
// reservation ends below `0xB800_0000`: U-Boot on this part relocates itself
// to the top 128 MB of DDR without looking at a reserved-memory node, so that
// is U-Boot's until Linux runs, and the fabric's gate is opened by U-Boot.
//
// The Kria KR260's 4 GB start at zero, and its reservation is in the low
// 2 GB, below `0x6800_0000`: its factory U-Boot loads below that and
// relocates itself above `0x7B80_0000` (`bdinfo` on the board), and `boot.scr`
// loads the bitstream last, so nothing of the loader's is in the region when
// the machine starts writing it.
//
//   board          RESERVED_BASE   main memory    display        records
//   Arty, Cora     0x1B00_0000     0x1B00_0000    0x1C00_0000    0x1C10_0000
//   DE25-Nano      0xB300_0000     0xB300_0000    0xB400_0000    0xB410_0000
//   Kria KR260     0x6300_0000     0x6300_0000    0x6400_0000    0x6410_0000
//
// **ONE DEFINE CHOOSES**, `CADR_DDR_MAP_DE25_NANO` or `CADR_DDR_MAP_KR260`,
// which that board's flows set and no other flow does.  A package cannot take a parameter, and
// the base is read deep inside `cadr_machine`, where a parameter would have to
// be carried through two modules of the machine that are MIT's and not the
// board's.  The define is not trusted on its own:
// `boards/de25-nano/cadr_de25.sv` and `boards/kria-kr260/cadr_kr260.sv`
// each state their own base and stop elaboration when this package disagrees, so a flow that forgot the define builds nothing
// rather than a board that writes the Zynq's addresses into the processor's
// address map.

`default_nettype none

// A package of constants is declared before its consumers exist --- the DDR
// bridge is the next slice --- so most of these are unused today, and will be
// again whenever a region is reserved ahead of the thing that fills it.
/* verilator lint_off UNUSEDPARAM */
package cadr_ddr_map;

`ifdef CADR_DDR_MAP_DE25_NANO
  // Below the DE25-Nano's top 128 MB, which is U-Boot's: see the header.
  localparam logic [31:0] RESERVED_BASE = 32'hB300_0000;
`else
`ifdef CADR_DDR_MAP_KR260
  // The Kria KR260's low 2 GB: clear of every address its factory U-Boot
  // loads to and below its relocation (see the header).
  localparam logic [31:0] RESERVED_BASE = 32'h6300_0000;
`else
  // The Zynq-7000 boards' 512 MB, 16 MB below the display.
  localparam logic [31:0] RESERVED_BASE = 32'h1B00_0000;
`endif
`endif
  // Main memory's 16 MB, the display's 1 MB and the records' 128 KB, which
  // abut in that order (see the header).
  localparam int unsigned RESERVED_BYTES = 32'h0112_0000;

  // Main memory. A word is 32 bits, so the byte address is the CADR's word
  // address shifted left by two.
`ifdef CADR_DDR_MAP_DE25_NANO
  localparam logic [31:0] MAIN_BASE  = 32'hB300_0000;
`else
`ifdef CADR_DDR_MAP_KR260
  localparam logic [31:0] MAIN_BASE  = 32'h6300_0000;
`else
  localparam logic [31:0] MAIN_BASE  = 32'h1B00_0000;
`endif
`endif
  // The whole 22-bit space, 4M words, 16 MB reserved.
  localparam int unsigned MAIN_WORDS = 4 * 1024 * 1024;

  // What the machine can address today: 60 boards of 64K words, the top four
  // slots of the 22-bit space being the display, the disk controller and the
  // Unibus. muir's `--main-memory-boards` has the same ceiling.
  localparam int unsigned MAIN_WORDS_REACHABLE = 3_932_160;

  // The display.
`ifdef CADR_DDR_MAP_DE25_NANO
  localparam logic [31:0] DISPLAY_BASE  = 32'hB400_0000;
`else
`ifdef CADR_DDR_MAP_KR260
  localparam logic [31:0] DISPLAY_BASE  = 32'h6400_0000;
`else
  localparam logic [31:0] DISPLAY_BASE  = 32'h1C00_0000;
`endif
`endif
  localparam int unsigned DISPLAY_WORDS = 256 * 1024;  // 1 MB reserved

  // tv::BUFFER_WORDS, 0o100000: the 64 4116s on the SIMPLE TV.
  localparam int unsigned DISPLAY_WORDS_REACHABLE = 32768;

  // The second display board, the color TV, at the first board's own size
  // above it: 0x1C02_0000.  Its buffer is `tv::BUFFER_WORDS` like the first's
  // --- the board answers all 32,768 words whatever the picture uses --- and
  // `sys/window/color.lisp`'s `COLOR:MAKE-SCREEN` draws 576 by 454 at four
  // bits a pixel in the bottom 32,688 of them, 72 words a line.
  //
  // **NOTHING ON THE LINUX SIDE HAS TO GROW FOR IT.**  The reserved-memory
  // node in the device tree reserves the whole reservation from
  // RESERVED_BASE, and this is inside the display's 1 MB, so the board's two
  // screens are two windows of a region Linux already keeps its hands off.
  localparam logic [31:0] COLOR_DISPLAY_BASE =
      DISPLAY_BASE + 32'(DISPLAY_WORDS_REACHABLE << 2);

  // QUUX's video controller: one buffer of up to 64K words from
  // `DISPLAY_BASE` (`mono_display_byte_address`), 256 KB.
  localparam int unsigned VIDEO_WORDS_MAX = 65536;

  // **QUUX REVISION 13's MEMORY, AND ITS OWN RESERVATION** (contract G2 §3,
  // G1 §4.1).  Main memory is packed storage, word w at byte
  // `QUUX13_MAIN_BASE + 5w`, directly below the display; the display and the
  // disk pack program's records stay where the CADR's are, so they are at the
  // same addresses on every machine and only main memory moves.
  //
  //   board        main memory                 room               display
  //   Arty, Cora   0x1200_0000-0x1BFF_FFFF     160 MB, 32M words  0x1C00_0000
  //   DE25-Nano    0xA000_0000-0xB3FF_FFFF     320 MB, 64M words  0xB400_0000
  //   Kria KR260   0x5A00_0000-0x63FF_FFFF     160 MB, 32M words  0x6400_0000
  //
  // **EACH MACHINE HAS ITS OWN DEVICE TREE**, beside its bitstream: the
  // CADR's and revision 12's reserve `RESERVED_BASE` for `RESERVED_BYTES`, as
  // above, since revision 12's main memory and its video controller's buffer
  // are the CADR's own areas; and revision 13's from `QUUX13_MAIN_BASE` to
  // `QUUX13_RESERVED_END`, the end of the records, which is the end of the
  // CADR's reservation too.
  // The CADR's main memory at `MAIN_BASE` is inside revision 13's; the two are
  // two bitstreams, never one.  `quux_mem_port.sv` takes `QUUX13_MAIN_BASE`.
`ifdef CADR_DDR_MAP_DE25_NANO
  localparam logic [31:0] QUUX13_MAIN_BASE      = 32'hA000_0000;
  localparam int unsigned QUUX13_MAIN_WORDS_MAX = 64 * 1024 * 1024;
`else
`ifdef CADR_DDR_MAP_KR260
  localparam logic [31:0] QUUX13_MAIN_BASE      = 32'h5A00_0000;
  localparam int unsigned QUUX13_MAIN_WORDS_MAX = 32 * 1024 * 1024;
`else
  localparam logic [31:0] QUUX13_MAIN_BASE      = 32'h1200_0000;
  localparam int unsigned QUUX13_MAIN_WORDS_MAX = 32 * 1024 * 1024;
`endif
`endif
  // The disk pack program's records directly above the display's 1 MB, the
  // last area of the reservation: both areas for all 24 slots
  // (`pack_feeder.h`, `FEEDER_MAP_BYTES`).
  localparam int unsigned RECORDS_BYTES = 32'h0002_0000;
  localparam logic [31:0] QUUX13_RESERVED_END =
      DISPLAY_BASE + 32'(DISPLAY_WORDS << 2) + 32'(RECORDS_BYTES);

  // **HOW MANY 64K-WORD MEMORY BOARDS EACH MACHINE TAKES**, the console's
  // page 2 word 37 (`cadr_console.sv`), muir's `--main-memory-boards`: the
  // CADR and QUUX to revision 12 come up with 32 and take 1 to 60, below the
  // Xbus I/O space; revision 13 comes up with muir's 512, 32M words (contract
  // G2 §3), and takes 1 to what its reservation holds, `QUUX13_MAIN_WORDS_MAX`,
  // and never more than muir's 1,024: 512 on the Arty Z7-20 and the Kria
  // KR260, 1,024 on the DE25-Nano.  Each board's top level hands these to its
  // console, and `machine_param.pass` reads them back there.
  function automatic int unsigned mem_boards_default(input bit rev13);
    return rev13 ? 512 : 32;
  endfunction
  function automatic int unsigned mem_boards_max(input bit rev13);
    return !rev13 ? 60 : (QUUX13_MAIN_WORDS_MAX / 65536 > 1024 ? 1024 : QUUX13_MAIN_WORDS_MAX / 65536);
  endfunction

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
  // QUUX's video controller: one buffer of up to 64K words from the same base, 40,960
  // at the bitstreams' 1280 by 1024.  QUUX has no color board, so nothing
  // is placed after it.
  function automatic logic [31:0] mono_display_byte_address(input logic [15:0] offset);
    return DISPLAY_BASE + {14'd0, offset, 2'b00};
  endfunction

  function automatic logic [31:0] color_display_byte_address(input logic [14:0] offset);
    return COLOR_DISPLAY_BASE + (32'(offset) << 2);
  endfunction

  // QUUX's memory bus (contract Q7): main memory, and the video controller's frame
  // buffer from `17000000`, which is past main memory's reach
  // (`MAIN_WORDS_REACHABLE` is exactly `17000000`) and 64K-word aligned, so
  // its offset is the low sixteen bits.  The cache fills and writes through
  // at these addresses, and the display's scanout reads the buffer's.
  function automatic logic [31:0] quux_byte_address(input logic [21:0] phys);
    return (phys >= 22'o17000000) ? mono_display_byte_address(phys[15:0])
                                  : main_byte_address(phys);
  endfunction

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
