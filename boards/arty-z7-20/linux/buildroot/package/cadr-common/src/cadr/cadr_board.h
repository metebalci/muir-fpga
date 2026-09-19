// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Where the fabric is, board by board: the one header that knows which board
// these programs were built for.
//
// Every address a program here maps is a fact about the BOARD and not about
// the program: which port of the processor the faces sit behind, where that
// port's window starts, where the machine's memory was reserved, and what the
// guard reads before anything else.  So every one of them is here, once, for
// every board, and each program's own header names its face's address as the
// board's (`PS_REG_BASE` is `CADR_BOARD_PACK_BASE`, and so on).
//
//                           Zynq-7000 boards         DE25-Nano
//                           (Arty Z7-20, Cora)       (Agilex 5)
//
//   the faces' port         M_AXI_GP0                H2F, the HPS-to-FPGA
//                                                    bridge
//     the pack side         0x4000_0000              0x4000_0000
//     the Chaosnet          0x4000_1000              0x4000_1000
//     the serial line       0x4000_2000              0x4000_2000
//     keyboard and mouse    0x4000_3000              0x4000_3000
//   the console's port      M_AXI_GP1                LWH2F, the lightweight
//                                                    HPS-to-FPGA bridge
//     the console           0x8000_0000              0x2000_0000
//   the machine's memory    reserved at 0x1800_0000  reserved at 0xB000_0000
//     main memory           + 0                      + 0
//     the display           + 64 MB                  + 64 MB
//     the color display     the display + 128 KB     the display + 128 KB
//     the spare             + 72 MB                  + 72 MB
//   the memory's port       S_AXI_HP0 (the machine)  F2SDRAM, the
//                           and HP2 (the pack side)  FPGA-to-SDRAM bridge,
//                                                    for both
//   the guard's tally       EMIO, 0xE000_A068 and    the system manager's GPI,
//                           0xE000_A06C, two words   0x10D1_20E8, one word
//
// The debug window is the fourth: 0x8000_1000 and 0x2000_1000, one page above
// the console behind the same split.  No program here maps it --- muir is given
// it on its command line (`--debug-cable-connect`), by the card's muirrc ---
// so it is the card script's to know and not this header's.
//
// WHERE THE DE25-Nano's NUMBERS COME FROM.  The two bridges' windows are the
// Agilex 5 HPS Technical Reference Manual's (814346, Table 322): the
// lightweight bridge at 0x2000_0000 for 512 MB and the HPS-to-FPGA bridge at
// 0x4000_0000 for 1 GB.  The fabric sees an offset into each window, so the
// faces keep their Zynq offsets from 0x4000_0000 and the console and the
// debug window move to the lightweight bridge, 0x8000_0000 being memory on
// this part.  The processor's memory is 1 GB at 0x8000_0000, which the fabric
// reaches at the same addresses (Table 323), and the machine's 128 MB is at
// 0xB000_0000 rather than at the top because U-Boot relocates itself to the
// top on this part (`boards/de25-nano/linux/cadr-reserved.dtsi` says why).
// The system manager is at 0x10D1_2000 and GPI is its register 0xE8
// (TF-A's plat/intel/soc/agilex5/include/socfpga_plat_def.h:78 and
// agilex5_system_manager.h:54).  Those are this project's decisions for the
// board, PROVISIONAL until the board is up; the fabric's side of every one of
// them is the DE25-Nano's top level's.
//
// **THE GUARD ON THE DE25-Nano READS ONE WORD WHERE THE ZYNQ READS TWO.**  The
// tally the fabric presents is `rtl/plumbing/cadr_mem_count.sv`'s, sixty-four
// bits of counters that the Zynq boards carry to the processor on EMIO.  The
// Agilex 5 has thirty-two lines from the fabric that the processor can read
// with nothing else running, `h2f_gp_in`, which the system manager's GPI
// reports.  So the guard asks one word of the tally and the same thing of it
// as of each of the Zynq's two: bit 15 set and bit 31 clear, a pattern neither
// an absent instrument nor a saturated one produces (`cadr_mem.h`).  **This is
// the contract the DE25-Nano's fabric has to meet, and it does not yet**: what
// drives `h2f_gp_in` is the fabric's decision, still open.  Until it is made,
// a program here refuses the fabric unless told `--no-guard`, which is the
// safe way to be wrong.
//
// HOW THE CHOICE ARRIVES.  One define, `CADR_BOARD_DE25_NANO`, and no define
// is a Zynq-7000 board.  Under Buildroot the board's defconfig names its map
// (`BR2_CADR_BOARD_*`, package/cadr-common/Config.in); cadr-common's own
// build compiles the library with the define and the copy of this header it
// stages begins with it, so every program that includes it from the staging
// tree is built for that board with no flag of its own.  The host checks
// include this file from the source tree, with no define, and so build the
// Zynq map their models were written against; `make check` also compiles
// every program for the DE25-Nano (`de25_linux.pass`).
//
// EACH ADDRESS IS WRITTEN ONCE, AS HEX DIGITS, and becomes both the number a
// program maps and the string its `--help` prints, so the two cannot part
// company.  The layout inside the reservation is the machine's and not the
// board's, and the assertions at the end hold every board's numbers to it.

#ifndef CADR_BOARD_H
#define CADR_BOARD_H

#if defined(CADR_BOARD_DE25_NANO) && defined(CADR_BOARD_ZYNQ7000)
#error "cadr_board.h: two boards named; a program is built for one"
#endif

#if defined(CADR_BOARD_DE25_NANO)

#define CADR_BOARD_NAME          "de25-nano"
#define CADR_BOARD_FACES_PORT    "H2F"
#define CADR_BOARD_CONSOLE_PORT  "LWH2F"
#define CADR_BOARD_MEMORY_PORT   "F2SDRAM"
#define CADR_BOARD_MEMORY_OPENED "one where U-Boot did not open the bridges"
#define CADR_BOARD_PACK_PORT     "F2SDRAM"
#define CADR_BOARD_TALLY         "the GPI tally"

#define CADR_BOARD_PACK_HEX      40000000
#define CADR_BOARD_CHAOS_HEX     40001000
#define CADR_BOARD_SERIAL_HEX    40002000
#define CADR_BOARD_INPUT_HEX     40003000
#define CADR_BOARD_CONSOLE_HEX   20000000
#define CADR_BOARD_RESERVED_HEX  B0000000
#define CADR_BOARD_MAIN_HEX      B0000000
#define CADR_BOARD_DISPLAY_HEX   B4000000
#define CADR_BOARD_COLOR_HEX     B4020000
#define CADR_BOARD_SPARE_HEX     B4800000

// The tally: the system manager's GPI, one word.
#define CADR_BOARD_TALLY_PAGE    0x10D12000u
#define CADR_BOARD_TALLY_WORDS   1u
#define CADR_BOARD_TALLY_OFF0    0xE8u
#define CADR_BOARD_TALLY_OFF1    0xE8u

#else  // the Zynq-7000 boards: the Arty Z7-20 and the Cora Z7-07S

#define CADR_BOARD_NAME          "zynq-7000"
#define CADR_BOARD_FACES_PORT    "M_AXI_GP0"
#define CADR_BOARD_CONSOLE_PORT  "M_AXI_GP1"
#define CADR_BOARD_MEMORY_PORT   "S_AXI_HP0"
#define CADR_BOARD_MEMORY_OPENED "one where ps7_post_config has not run"
#define CADR_BOARD_PACK_PORT     "HP2"
#define CADR_BOARD_TALLY         "the EMIO tally"

#define CADR_BOARD_PACK_HEX      40000000
#define CADR_BOARD_CHAOS_HEX     40001000
#define CADR_BOARD_SERIAL_HEX    40002000
#define CADR_BOARD_INPUT_HEX     40003000
#define CADR_BOARD_CONSOLE_HEX   80000000
#define CADR_BOARD_RESERVED_HEX  18000000
#define CADR_BOARD_MAIN_HEX      18000000
#define CADR_BOARD_DISPLAY_HEX   1C000000
#define CADR_BOARD_COLOR_HEX     1C020000
#define CADR_BOARD_SPARE_HEX     1C800000

// The tally: the GPIO block's DATA_2_RO and DATA_3_RO, two words.
#define CADR_BOARD_TALLY_PAGE    0xE000A000u
#define CADR_BOARD_TALLY_WORDS   2u
#define CADR_BOARD_TALLY_OFF0    0x68u
#define CADR_BOARD_TALLY_OFF1    0x6Cu

#endif

// Hex digits into a number and into a string.  Two levels, so that the
// argument is expanded before it is pasted or quoted.
#define CADR_BOARD_NUM_(h)       0x##h##u
#define CADR_BOARD_NUM(h)        CADR_BOARD_NUM_(h)
#define CADR_BOARD_STR_(h)       "0x" #h
#define CADR_BOARD_STR(h)        CADR_BOARD_STR_(h)

#define CADR_BOARD_PACK_BASE         CADR_BOARD_NUM(CADR_BOARD_PACK_HEX)
#define CADR_BOARD_PACK_BASE_STR     CADR_BOARD_STR(CADR_BOARD_PACK_HEX)
#define CADR_BOARD_CHAOS_BASE        CADR_BOARD_NUM(CADR_BOARD_CHAOS_HEX)
#define CADR_BOARD_SERIAL_BASE       CADR_BOARD_NUM(CADR_BOARD_SERIAL_HEX)
#define CADR_BOARD_SERIAL_BASE_STR   CADR_BOARD_STR(CADR_BOARD_SERIAL_HEX)
#define CADR_BOARD_INPUT_BASE        CADR_BOARD_NUM(CADR_BOARD_INPUT_HEX)
#define CADR_BOARD_INPUT_BASE_STR    CADR_BOARD_STR(CADR_BOARD_INPUT_HEX)
#define CADR_BOARD_CONSOLE_BASE      CADR_BOARD_NUM(CADR_BOARD_CONSOLE_HEX)
#define CADR_BOARD_CONSOLE_BASE_STR  CADR_BOARD_STR(CADR_BOARD_CONSOLE_HEX)
#define CADR_BOARD_RESERVED_BASE     CADR_BOARD_NUM(CADR_BOARD_RESERVED_HEX)
#define CADR_BOARD_MAIN_BASE         CADR_BOARD_NUM(CADR_BOARD_MAIN_HEX)
#define CADR_BOARD_DISPLAY_BASE      CADR_BOARD_NUM(CADR_BOARD_DISPLAY_HEX)
#define CADR_BOARD_DISPLAY_BASE_STR  CADR_BOARD_STR(CADR_BOARD_DISPLAY_HEX)
#define CADR_BOARD_COLOR_BASE        CADR_BOARD_NUM(CADR_BOARD_COLOR_HEX)
#define CADR_BOARD_COLOR_BASE_STR    CADR_BOARD_STR(CADR_BOARD_COLOR_HEX)
#define CADR_BOARD_SPARE_BASE        CADR_BOARD_NUM(CADR_BOARD_SPARE_HEX)

// The layout inside the reservation, which is `rtl/plumbing/cadr_ddr_map.sv`'s
// and the same on every board: main memory at the base, the display 64 MB up,
// the color TV's window 128 KB above the display's (the first board's own
// 32,768 words), the spare 8 MB above the display, and all of it inside the
// 128 MB.  A board whose numbers break it does not compile.
_Static_assert(CADR_BOARD_MAIN_BASE == CADR_BOARD_RESERVED_BASE,
	       "main memory is at the base of the reservation");
_Static_assert(CADR_BOARD_DISPLAY_BASE == CADR_BOARD_RESERVED_BASE + 0x04000000u,
	       "the display is 64 MB above the base of the reservation");
_Static_assert(CADR_BOARD_COLOR_BASE == CADR_BOARD_DISPLAY_BASE + 0x00020000u,
	       "the color display is 128 KB above the display");
_Static_assert(CADR_BOARD_SPARE_BASE == CADR_BOARD_DISPLAY_BASE + 0x00800000u,
	       "the spare is 8 MB above the display");
_Static_assert(CADR_BOARD_RESERVED_BASE % 0x08000000u == 0u,
	       "the reservation is aligned to its own 128 MB");
_Static_assert(CADR_BOARD_RESERVED_BASE <= 0xFFFFFFFFu - 0x07FFFFFFu,
	       "the reservation is below 4 GB, because every address here is 32 bits");
// And the faces: four 4 KB pages from the port's first, in the order the
// fabric's split decodes them (`rtl/plumbing/cadr_gp0_split.sv`).
_Static_assert(CADR_BOARD_CHAOS_BASE == CADR_BOARD_PACK_BASE + 0x1000u,
	       "the Chaosnet is one page above the pack side");
_Static_assert(CADR_BOARD_SERIAL_BASE == CADR_BOARD_PACK_BASE + 0x2000u,
	       "the serial line is two pages above the pack side");
_Static_assert(CADR_BOARD_INPUT_BASE == CADR_BOARD_PACK_BASE + 0x3000u,
	       "the keyboard and mouse are three pages above the pack side");

#endif
