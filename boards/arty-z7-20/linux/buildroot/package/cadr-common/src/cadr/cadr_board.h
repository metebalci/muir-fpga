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
//   the machine's memory    reserved at 0x1B00_0000  reserved at 0xB300_0000
//                           for 17.125 MB            for 17.125 MB
//     main memory           + 0, 16 MB               + 0, 16 MB
//     the display           + 16 MB, 1 MB            + 16 MB, 1 MB
//     the color display     the display + 128 KB     the display + 128 KB
//     the spare: the        + 17 MB, 128 KB          + 17 MB, 128 KB
//     records, and no more
//   QUUX revision 13's      its own reservation      its own reservation
//     memory                0x1200_0000 to           0xA000_0000 to
//                           0x1C11_FFFF              0xB411_FFFF
//     main memory, packed   0x1200_0000, 160 MB      0xA000_0000, 320 MB
//     the display, and      the CADR's               the CADR's
//     the records           the CADR's               the CADR's
//   the memory's port       S_AXI_HP0 (the machine)  F2SDRAM, the
//                           and HP2 (the pack side)  FPGA-to-SDRAM bridge,
//                                                    for both
//   the guard's tally       EMIO, 0xE000_A068 and    the system manager's GPI,
//                           0xE000_A06C, two words   0x10D1_20E8, one word
//
// The debug window is the fourth: 0x8000_1000 and 0x2000_1000, one page above
// the console behind the same split.  No program here maps it --- muir is given
// it on its command line (`--debug-cable-connect`), by the card's cadrrc ---
// so it is the card script's to know and not this header's.
//
// WHERE THE DE25-Nano's NUMBERS COME FROM.  The two bridges' windows are the
// Agilex 5 HPS Technical Reference Manual's (814346, Table 322): the
// lightweight bridge at 0x2000_0000 for 512 MB and the HPS-to-FPGA bridge at
// 0x4000_0000 for 1 GB.  The fabric sees an offset into each window, so the
// faces keep their Zynq offsets from 0x4000_0000 and the console and the
// debug window move to the lightweight bridge, 0x8000_0000 being memory on
// this part.  The processor's memory is 1 GB at 0x8000_0000, which the fabric
// reaches at the same addresses (Table 323), and the machine's reservation
// ends below 0xB800_0000 rather than at the top because U-Boot relocates
// itself to the top 128 MB on this part (`boards/de25-nano/linux/
// cadr-reserved.dtsi` says why).
// The system manager is at 0x10D1_2000 and GPI is its register 0xE8
// (TF-A's plat/intel/soc/agilex5/include/socfpga_plat_def.h:78 and
// agilex5_system_manager.h:54).  Those are this project's decisions for the
// board, and the board runs on them.  The fabric's side of every one of them
// is the DE25-Nano's top level's, and two checks hold the sides together:
// `tools/de25_faces_check.py` for the faces and `tools/mem_map_check.py` for
// the memory, the reserved-memory node and U-Boot's GPO register.
//
// **THE GUARD ON THE DE25-Nano READS ONE WORD WHERE THE ZYNQ READS TWO.**  The
// tally the fabric presents is `rtl/plumbing/cadr_mem_count.sv`'s, sixty-four
// bits of counters that the Zynq boards carry to the processor on EMIO.  The
// Agilex 5 has thirty-two lines from the fabric that the processor can read
// with nothing else running, `h2f_gp_in`, which the system manager's GPI
// reports.  So the guard asks one word of the tally and the same thing of it
// as of each of the Zynq's two: bit 15 set and bit 31 clear, a pattern neither
// an absent instrument nor a saturated one produces (`cadr_mem.h`).  **The
// fabric meets that contract**: `rtl/plumbing/cadr_f2sdram_port.sv` drives
// `h2f_gp_in` from the same counters, with `h2f_gp_out[1]` choosing which half
// of them a read sees, so a program needs no `--no-guard` on this board any
// more than on a Zynq one.
//
// THE KR260's NUMBERS (the AMD Kria KR260, a Zynq UltraScale+ part).  The
// faces are behind M_AXI_HPM0_FPD, whose window is 0xA000_0000 for 256 MB
// when the video codec is not mapped, and the console and the debug window
// behind M_AXI_HPM1_FPD at 0xB000_0000 (UG1085, table 10-1); the faces keep
// their Zynq offsets in the first.  The machine's reservation is at
// 0x6300_0000 in the low 2 GB, clear of every address the factory U-Boot
// uses, which loads below it and relocates itself above 0x7B80_0000 (`bdinfo`
// on the board),
// and QUUX revision 13's packed 160 MiB sit directly below its display at
// 0x5A00_0000, as on the Arty.  The tally is two words on EMIO, as on a
// Zynq-7000 board: banks 3 and 4 of the GPIO block at 0xFF0A_0000, read
// through DATA_3_RO and DATA_4_RO (UG1087; banks 0 to 2 are the MIO's).
// The board's top level is to drive the tally there; the card's reservation
// is `boards/kria-kr260/linux/cadr-reserved.dtsi`.
//
// HOW THE CHOICE ARRIVES.  One define, `CADR_BOARD_DE25_NANO` or
// `CADR_BOARD_KR260`, and no define is a Zynq-7000 board.  Under Buildroot
// the board's defconfig names its map (`BR2_CADR_BOARD_*`,
// package/cadr-common/Config.in); cadr-common's own
// build compiles the library with the define and the copy of this header it
// stages begins with it, so every program that includes it from the staging
// tree is built for that board with no flag of its own.  The host checks
// include this file from the source tree, with no define, and so build the
// Zynq map their models were written against; `make check` also compiles
// every program for the DE25-Nano (`de25_linux.pass`) and for the KR260
// (`kr260_linux.pass`).
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
#if defined(CADR_BOARD_KR260) && (defined(CADR_BOARD_DE25_NANO) || defined(CADR_BOARD_ZYNQ7000))
#error "cadr_board.h: two boards named; a program is built for one"
#endif

// The KR260's map is the outer else branch at the end, so that the two older
// maps keep the shape the checks that read this file as text look for: the
// DE25-Nano's half first, ended by the Zynq boards' else branch.
#if !defined(CADR_BOARD_KR260)

#if defined(CADR_BOARD_DE25_NANO)

#define CADR_BOARD_NAME          "de25-nano"
#define CADR_BOARD_FACES_PORT    "H2F"
#define CADR_BOARD_CONSOLE_PORT  "LWH2F"
#define CADR_BOARD_MEMORY_PORT   "F2SDRAM"
#define CADR_BOARD_MEMORY_OPENED "one where U-Boot did not open the bridges"
#define CADR_BOARD_PACK_PORT     "F2SDRAM"
#define CADR_BOARD_TALLY         "the GPI tally"
// MIT's debug cable: no Pmod on this board, so eight of JP1's pins
// (docs/debug-cable.md).
#define CADR_BOARD_DEBUG_CONNECTOR "JP1's pins 31 to 38"

#define CADR_BOARD_PACK_HEX      40000000
#define CADR_BOARD_CHAOS_HEX     40001000
#define CADR_BOARD_SERIAL_HEX    40002000
#define CADR_BOARD_INPUT_HEX     40003000
#define CADR_BOARD_FD_HEX        40004000
#define CADR_BOARD_CONSOLE_HEX   20000000
#define CADR_BOARD_RESERVED_HEX  B3000000
#define CADR_BOARD_MAIN_HEX      B3000000
#define CADR_BOARD_DISPLAY_HEX   B4000000
#define CADR_BOARD_COLOR_HEX     B4020000
#define CADR_BOARD_SPARE_HEX     B4100000
#define CADR_BOARD_QUUX13_MAIN_HEX A0000000
#define CADR_BOARD_QUUX13_MAIN_WORDS_MAX (64u * 1024u * 1024u)

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
// MIT's debug cable, on one Pmod (docs/debug-cable.md).
#define CADR_BOARD_DEBUG_CONNECTOR "Pmod JA"

#define CADR_BOARD_PACK_HEX      40000000
#define CADR_BOARD_CHAOS_HEX     40001000
#define CADR_BOARD_SERIAL_HEX    40002000
#define CADR_BOARD_INPUT_HEX     40003000
#define CADR_BOARD_FD_HEX        40004000
#define CADR_BOARD_CONSOLE_HEX   80000000
#define CADR_BOARD_RESERVED_HEX  1B000000
#define CADR_BOARD_MAIN_HEX      1B000000
#define CADR_BOARD_DISPLAY_HEX   1C000000
#define CADR_BOARD_COLOR_HEX     1C020000
#define CADR_BOARD_SPARE_HEX     1C100000
#define CADR_BOARD_QUUX13_MAIN_HEX 12000000
#define CADR_BOARD_QUUX13_MAIN_WORDS_MAX (32u * 1024u * 1024u)

// The tally: the GPIO block's DATA_2_RO and DATA_3_RO, two words.
#define CADR_BOARD_TALLY_PAGE    0xE000A000u
#define CADR_BOARD_TALLY_WORDS   2u
#define CADR_BOARD_TALLY_OFF0    0x68u
#define CADR_BOARD_TALLY_OFF1    0x6Cu

#endif

#else  // CADR_BOARD_KR260: the AMD Kria KR260 (Zynq UltraScale+)

#define CADR_BOARD_NAME          "kria-kr260"
#define CADR_BOARD_FACES_PORT    "M_AXI_HPM0_FPD"
#define CADR_BOARD_CONSOLE_PORT  "M_AXI_HPM1_FPD"
#define CADR_BOARD_MEMORY_PORT   "S_AXI_HP0_FPD"
#define CADR_BOARD_MEMORY_OPENED "one whose load did not release the fabric's isolation"
#define CADR_BOARD_PACK_PORT     "HP2"
#define CADR_BOARD_TALLY         "the EMIO tally"
// MIT's debug cable, on the carrier's first Pmod (docs/debug-cable.md).
#define CADR_BOARD_DEBUG_CONNECTOR "PMOD1"

#define CADR_BOARD_PACK_HEX      A0000000
#define CADR_BOARD_CHAOS_HEX     A0001000
#define CADR_BOARD_SERIAL_HEX    A0002000
#define CADR_BOARD_INPUT_HEX     A0003000
#define CADR_BOARD_FD_HEX        A0004000
#define CADR_BOARD_CONSOLE_HEX   B0000000
#define CADR_BOARD_RESERVED_HEX  63000000
#define CADR_BOARD_MAIN_HEX      63000000
#define CADR_BOARD_DISPLAY_HEX   64000000
#define CADR_BOARD_COLOR_HEX     64020000
#define CADR_BOARD_SPARE_HEX     64100000
#define CADR_BOARD_QUUX13_MAIN_HEX 5A000000
#define CADR_BOARD_QUUX13_MAIN_WORDS_MAX (32u * 1024u * 1024u)

// The tally: the GPIO block's DATA_3_RO and DATA_4_RO, EMIO banks 3 and 4.
#define CADR_BOARD_TALLY_PAGE    0xFF0A0000u
#define CADR_BOARD_TALLY_WORDS   2u
#define CADR_BOARD_TALLY_OFF0    0x6Cu
#define CADR_BOARD_TALLY_OFF1    0x70u

// **THE DISPLAY OUTPUT'S LINK IS THE PROCESSING SYSTEM'S DISPLAYPORT**, which
// `cadr-displayport` brings up and keeps: the controller's registers (UG1087,
// DISPLAY_PORT module) and the PS-GTR transceivers' (UG1087, SERDES module),
// whose lane 1 carries the link on this carrier.
#define CADR_BOARD_DISPLAYPORT_HEX FD4A0000
#define CADR_BOARD_DISPLAYPORT_BYTES 0x0000D000u
#define CADR_BOARD_SERDES_HEX      FD400000
#define CADR_BOARD_SERDES_BYTES    0x00020000u

#endif  // CADR_BOARD_KR260

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
// QUUX's real-time clock and file device (revision 9), on a QUUX
// bitstream; a CADR's answers the default's "NONE" there
// (`docs/file-device.md`).
#define CADR_BOARD_FD_BASE           CADR_BOARD_NUM(CADR_BOARD_FD_HEX)
#define CADR_BOARD_FD_BASE_STR       CADR_BOARD_STR(CADR_BOARD_FD_HEX)
#define CADR_BOARD_CONSOLE_BASE      CADR_BOARD_NUM(CADR_BOARD_CONSOLE_HEX)
#define CADR_BOARD_CONSOLE_BASE_STR  CADR_BOARD_STR(CADR_BOARD_CONSOLE_HEX)
#define CADR_BOARD_RESERVED_BASE     CADR_BOARD_NUM(CADR_BOARD_RESERVED_HEX)
#define CADR_BOARD_MAIN_BASE         CADR_BOARD_NUM(CADR_BOARD_MAIN_HEX)
#define CADR_BOARD_DISPLAY_BASE      CADR_BOARD_NUM(CADR_BOARD_DISPLAY_HEX)
#define CADR_BOARD_DISPLAY_BASE_STR  CADR_BOARD_STR(CADR_BOARD_DISPLAY_HEX)
#define CADR_BOARD_COLOR_BASE        CADR_BOARD_NUM(CADR_BOARD_COLOR_HEX)
#define CADR_BOARD_COLOR_BASE_STR    CADR_BOARD_STR(CADR_BOARD_COLOR_HEX)
#define CADR_BOARD_SPARE_BASE        CADR_BOARD_NUM(CADR_BOARD_SPARE_HEX)
#if defined(CADR_BOARD_KR260)
#define CADR_BOARD_DISPLAYPORT_BASE  CADR_BOARD_NUM(CADR_BOARD_DISPLAYPORT_HEX)
#define CADR_BOARD_SERDES_BASE       CADR_BOARD_NUM(CADR_BOARD_SERDES_HEX)
#endif
// **QUUX REVISION 13's MEMORY, AND ITS OWN RESERVATION** (contract G2 §3):
// main memory in packed storage, word w at byte `CADR_BOARD_QUUX13_MAIN_BASE +
// 5w` (G1 §4.1), with room for `CADR_BOARD_QUUX13_MAIN_WORDS_MAX` words
// directly below the display; the display and the disk pack program's records
// where the CADR's are.  Revision 13's device tree reserves from its main
// memory to the records' end, which is where the CADR's reservation ends too.
// The CADR's and revision 12's trees reserve from `CADR_BOARD_RESERVED_BASE`
// to the same end, `CADR_BOARD_RESERVED_BYTES`.
#define CADR_BOARD_QUUX13_MAIN_BASE      CADR_BOARD_NUM(CADR_BOARD_QUUX13_MAIN_HEX)
#define CADR_BOARD_QUUX13_MAIN_BASE_STR  CADR_BOARD_STR(CADR_BOARD_QUUX13_MAIN_HEX)
#define CADR_BOARD_RECORDS_BYTES         0x00020000u
#define CADR_BOARD_QUUX13_RESERVED_END   (CADR_BOARD_SPARE_BASE + CADR_BOARD_RECORDS_BYTES)
// The CADR's reservation: main memory, the display and the records.
#define CADR_BOARD_RESERVED_BYTES        0x01120000u

// The layout inside the reservation, which is `rtl/plumbing/cadr_ddr_map.sv`'s
// and the same on every board: main memory at the base, 16 MB, the whole
// 22-bit space at 4 bytes a word; the display 16 MB up, 1 MB, with the color
// TV's window 128 KB above the display's (the first board's own 32,768
// words); the spare 1 MB above the display, which is the records' 128 KB and
// no more; and nothing past the records.  A board whose numbers break it does
// not compile.
_Static_assert(CADR_BOARD_MAIN_BASE == CADR_BOARD_RESERVED_BASE,
	       "main memory is at the base of the reservation");
_Static_assert(CADR_BOARD_DISPLAY_BASE == CADR_BOARD_RESERVED_BASE + 0x01000000u,
	       "the display is 16 MB above the base of the reservation");
_Static_assert(CADR_BOARD_COLOR_BASE == CADR_BOARD_DISPLAY_BASE + 0x00020000u,
	       "the color display is 128 KB above the display");
_Static_assert(CADR_BOARD_SPARE_BASE == CADR_BOARD_DISPLAY_BASE + 0x00100000u,
	       "the spare is 1 MB above the display");
_Static_assert(CADR_BOARD_RESERVED_BYTES
		       == 0x01000000u + 0x00100000u + CADR_BOARD_RECORDS_BYTES,
	       "the reservation is main memory, the display and the records");
_Static_assert(CADR_BOARD_SPARE_BASE + CADR_BOARD_RECORDS_BYTES
		       == CADR_BOARD_RESERVED_BASE + CADR_BOARD_RESERVED_BYTES,
	       "the records end the reservation");
_Static_assert(CADR_BOARD_RESERVED_BASE % 0x00100000u == 0u,
	       "the reservation is on a 1 MB boundary");
_Static_assert(CADR_BOARD_RESERVED_BASE <= 0xFFFFFFFFu - (CADR_BOARD_RESERVED_BYTES - 1u),
	       "the reservation is below 4 GB, because every address here is 32 bits");
// And revision 13's: its main memory fills the room below the display, on a
// 1 MB boundary (so a 4 KB one, G1 4.1).
_Static_assert((unsigned long long)CADR_BOARD_QUUX13_MAIN_BASE
		       + 5ull * CADR_BOARD_QUUX13_MAIN_WORDS_MAX == CADR_BOARD_DISPLAY_BASE,
	       "revision 13's main memory fills the room below the display, 5 bytes a word");
_Static_assert(CADR_BOARD_QUUX13_MAIN_BASE % 0x00100000u == 0u,
	       "revision 13's main memory is on a 1 MB boundary");
// And the faces: five 4 KB pages from the port's first, in the order the
// fabric's split decodes them (`rtl/plumbing/cadr_gp0_split.sv`).
_Static_assert(CADR_BOARD_CHAOS_BASE == CADR_BOARD_PACK_BASE + 0x1000u,
	       "the Chaosnet is one page above the pack side");
_Static_assert(CADR_BOARD_SERIAL_BASE == CADR_BOARD_PACK_BASE + 0x2000u,
	       "the serial line is two pages above the pack side");
_Static_assert(CADR_BOARD_INPUT_BASE == CADR_BOARD_PACK_BASE + 0x3000u,
	       "the keyboard and mouse are three pages above the pack side");
_Static_assert(CADR_BOARD_FD_BASE == CADR_BOARD_PACK_BASE + 0x4000u,
	       "QUUX's clock and file device are four pages above the pack side");

#endif
