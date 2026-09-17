// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console's register face, as `rtl/plumbing/cadr_console.sv` defines it and as
// Linux drives it over `M_AXI_GP1`, and the vocabulary built on it.
//
// That file's header is the reference and this repeats only what a driver
// needs.  Thirty-two words at `CONS_REG_BASE`, two pages of sixteen:
//
//   page 0, +0x00, the console's own, read-only:
//     0  IDENT    "CONS"
//     1  STAT     bit 0 busy, 1 gnt, 2 answered, 3 lost (sticky since reset),
//                 4 the no-auto-boot switch held the machine at the last
//                 reset, 5 where that switch is now
//     2  CYCLES   microcycles retired since reset, bits 31:0
//     3  CYCLESH  bits 63:32, **latched when CYCLES was read**
//     4  TICKS    100 MHz ticks since reset, bits 31:0
//     5  TICKSH   bits 63:32, latched when TICKS was read
//     6  RESET    the machine's reset: a write of "RSET" and of nothing else
//                 pulses it.  This program does not write it; the read-back
//                 carries a marker and a count of resets
//     7  VMA      the virtual address register, all 32 bits, as of the last
//                 microcycle boundary.  **Reading it LATCHES Q AND MD beside
//                 it**
//     8  Q        the Q register, all 32 bits, latched when VMA was read
//     9  MD       the memory data register, all 32 bits, latched when VMA
//                 was read
//     10-13       the readout and the light panel's button
//     14 DEBUG    **THE DEBUG CABLE'S ROLE**, Pmod JA: a write of
//                 `CONS_DEBUG_CONNECT_KEY` asks this board to be the debugger
//                 on the connector and `CONS_DEBUG_DISCONNECT_KEY` gives the
//                 role back.  It reads a marker, a count of connects, and the
//                 role this board HAS beside the one it ASKED for
//     15 FRAMES   the cable's two counts: frames heard and frames refused,
//                 behind a marker byte
//
//   page 1, +0x40, word k IS diagnostic register `EADR` k:
//     read   a diagnostic READ cycle: `SPY<15:0>` in bits 15:0 with 31:16
//            zero, or bit 16 set meaning the cycle was not answered
//     write  a diagnostic WRITE cycle with `SPY<15:0>` from bits 15:0
//
//   page 2, +0x80, what the FABRIC is rather than what the machine is doing:
//     32 BUILD    which build this bitstream is, read-only.  Everything else
//                 on pages 2 and 3 reads `CONS_UNMAPPED`
//
// **THE HIGH HALF IS LATCHED BY THE LOW HALF'S READ**, so a 64-bit counter is
// read low then high and the pair names one instant across the carry.  A
// program that reads the high word alone gets whatever the last low read
// latched.  `cons_cycles` and `cons_ticks` are the only readers of the high
// words here, and they are in that order for that reason.
//
// **EVERY ADDRESS ON GP1 IS ANSWERED, WITH OKAY**, and an address on no page
// reads `CONS_UNMAPPED`, the complement of IDENT.  Neither zero nor all
// ones: zero is what a dead bus reads and all ones what an undriven one
// reads, so a value that means nothing is not a value the instrument can
// mean.
//
// **THE REGISTERS ARE muir's, ../muir/src/spy.rs, WHICH IS THE AUTHORITY.**
// Reads and writes at one `EADR` are uncorrelated --- `cadr/busint.erface`
// says so --- and `spy::write_strobe(eadr) = eadr & 7`, the write decoder's
// `G1` being `HI1` and not `EADR3`, so 0..7 name the write strobes and 8..15
// alias onto them (Y6 and Y7 are not connected, so 6, 7, 14 and 15 load
// nothing).  The names below are CC's, as muir's are.
//
// **THE FACE IS REACHED THROUGH TWO FUNCTION POINTERS** so that the host test
// can put a model of the RTL behind them and the board puts /dev/mem.  That
// seam is `pack_side.h`'s, copied deliberately: same shape, same reason, and
// a third program should copy it too rather than invent a third.

#ifndef CONSOLE_FACE_H
#define CONSOLE_FACE_H

#include <stddef.h>
#include <stdint.h>

// `M_AXI_GP1` decodes 0x80000000 - 0xBFFFFFFF to the fabric, as `M_AXI_GP0`
// decodes 0x40000000 - 0x7FFFFFFF.  Not from memory: Xilinx's own
// `processing_system7_v5_5/bd/bd.tcl` says it in the CRITICAL WARNING it
// raises for an address segment outside the range --- line 125 for a design
// with both ports and line 135 for one with GP1 alone.  The console sits at
// the bottom of GP1's gigabyte.
#define CONS_REG_BASE    0x80000000u
// Six pages of sixteen words.  It was two and 128 bytes until the build
// stamp wanted a word of its own and page 0 had none left, and four until the
// two display boards' color maps wanted sixteen words each; nothing maps this
// (the program maps the 4 KB page GP1's split gives the console), so it is
// the face's size and not an argument to `mmap`.
#define CONS_REG_BYTES   384u
#define CONS_IDENT_WORD  0x434F4E53u	/* "CONS" */
#define CONS_UNMAPPED    0xBCB0B1ACu	/* ~IDENT */

// How many TICKS go by in one REAL microsecond, which is the one number in
// this program that is about the wall clock rather than about the machine.
//
// The fabric's clock is the MMCM in `boards/arty-z7-20/cadr_arty.sv`: a
// 1000 MHz VCO divided by `CLKOUT0_DIVIDE_F`, which is 10.000, so a tick is
// 10 ns and 1,000 / 10 = 100 of them fit in a real microsecond --- a hundred
// exactly, the way it was a hundred and sixty exactly at 6.25 ns and two
// hundred at 5.  Every tick this board has ever been built with divides 1,000
// without remainder, which is why this constant has never needed to be
// anything but an integer.
//
// **THE MACHINE'S OWN TIME IS NOT WHAT THIS CONVERTS.**  A microcycle is 15
// ticks of MIT's grid whatever a tick costs, and `status` measures
// microcycles against a wall-clock wait, so the only place the two meet is
// here and in `console_test.c`'s model.  Getting it wrong prints a
// wrong duration; it cannot corrupt anything.
#define CONS_TICKS_PER_US  100u

// Page 0.
enum cons_p0 { CONS_IDENT = 0, CONS_STAT = 1, CONS_CYCLES = 2, CONS_CYCLESH = 3,
	       CONS_TICKS = 4, CONS_TICKSH = 5, CONS_RESET = 6, CONS_VMA = 7,
	       CONS_Q = 8, CONS_MD = 9, CONS_RO = 10, CONS_RO_LO = 11,
	       CONS_RO_HI = 12, CONS_BOOT = 13, CONS_DEBUG = 14,
	       CONS_DEBUG_FRAMES = 15 };

// **THE LIGHT PANEL'S BUTTON, page 0's word 13.**  A write of this key and of
// nothing else holds `-BOOT2` down for a few hundred nanoseconds and lets it
// go; the fabric's own key, `rtl/plumbing/cadr_console.sv`'s `BOOT_KEY`, is
// the same four bytes.  It reads back the key's top half, the presses so far
// and whether the line is down now.
//
// **IT IS `-BOOT2` AND NOT `PROG.BOOT`, AND THE DIFFERENCE IS WHOSE BUTTON IT
// IS.**  `MODE_BOOT` below is bit 7 of the mode register and reaches the same
// gate at OLORD2 1A07, so a console could boot the machine with it; that line
// is the DEBUG CABLE'S, the other machine's way in, and a console pressing it
// would be a console pretending to be a debugger.  `-BOOT2` is the button a
// person at the machine presses, which is what a console is.  muir's prompt
// makes the same choice: its `boot` presses `-BOOT2`.
#define CONS_BOOT_KEY     0x424F4F54u	/* "BOOT" */
// **THE NO-AUTO-BOOT SWITCH IS TWO BITS AND NOT ONE.**  SW0 on the board says
// whether the machine comes out of reset with `RUN` clear, as a CADR is when
// the power comes on with nobody at it, or preset.  The fabric reads it at the
// machine's own reset arms and at no other instant, so moving it under a
// running machine does nothing until the next reset --- which is why the value
// that HELD the machine and the level TODAY are both reported.  A person who
// moved the switch after the board came up sees them differ, and that is the
// thing they need to be told.
enum cons_stat_bit { CONS_ST_BUSY = 1u << 0, CONS_ST_GNT = 1u << 1,
		     CONS_ST_ANSWERED = 1u << 2, CONS_ST_LOST = 1u << 3,
		     CONS_ST_HELD_AT_RESET = 1u << 4, CONS_ST_SWITCH_NOW = 1u << 5 };

// **THE DEBUG CABLE'S ROLE, page 0's word 14.**  MIT's cable is one Pmod
// header, JA, carrying both directions, and a board is a debugger or a
// debuggee on it and never both at once.  **A BOARD COMES UP A DEBUGGEE AND
// NOTHING HAS TO BE SET FOR THAT**: it answers a debugger that plugs in,
// exactly as MIT's board answers one on its DBGIN.  A write of the connect key
// asks for the other role and the DISCONNECT key --- which is the same value
// complemented, so that no partial write of either can be the other --- gives
// it back.  `rtl/plumbing/cadr_console.sv`'s `DEBUG_KEY` is the same four
// bytes.  `docs/debug-cable.md` has the cable.
//
// **THE DBGIN PAGE IS NEVER SWITCHED OFF BY ANY OF THIS.**  Only the connector
// changes hands, so a board debugging somebody else is still debuggable
// through its own register window, which is what a real CADR's two live
// connectors give it.
#define CONS_DEBUG_CONNECT_KEY     0x44424752u	/* "DBGR" */
#define CONS_DEBUG_DISCONNECT_KEY  (~CONS_DEBUG_CONNECT_KEY)

// **AND WHICH WAY ROUND THE RIBBON WAS MADE, the same word and three more
// keys.**  A Pmod ribbon is supposed to join pin one to pin one.  One made
// from two host sockets mirrors the header's two rows instead, so each board's
// pins 1 to 4 reach the other's 7 to 10 --- and a debugger then drives four
// pins the far board never listens to.  Two boards were found on exactly such
// a cable, and it was a manufactured extension that could not be re-crimped.
//
// **ONLY THE DEBUGGER APPLIES THE SETTING.**  A debuggee always drives the
// high four and listens on the low four; a debugger swaps its two groups when
// the cable is crossed.  One end compensating is what straightens a mirrored
// ribbon and two would cross it again.
//
// `auto` is the default and looks for the answer: the board drives nothing
// while it listens on both groups, and then --- two freshly reset boards being
// two silent debuggees whatever the cable is --- assumes straight and tries
// the other wiring in turn until something answers.  The other two take the
// looking out of the way when somebody is diagnosing a cable.
//
// **A SETTING MAY NOT MOVE UNDER A BOARD THAT IS ALREADY THE DEBUGGER**, so a
// write is dropped while this board holds the role.  Write and then READ, as
// with the role itself.
#define CONS_DEBUG_WIRE_AUTO_KEY       0x4155544Fu	/* "AUTO" */
#define CONS_DEBUG_WIRE_STRAIGHT_KEY   0x53545241u	/* "STRA" */
#define CONS_DEBUG_WIRE_CROSSOVER_KEY  0x43524F53u	/* "CROS" */

// Word 14's bits.  **BIT 0 AND BIT 1 ARE TWO FACTS AND NOT ONE**, for the
// reason the switch's two bits are: the fabric may REFUSE the role, because a
// board that can see a debugger already on the connector holds its own
// engagement down.  A console that reported one of them would be lying about
// the other.
//
// **AND BIT 8 IS A CROSSED CABLE, NAMED FROM THE END THAT CANNOT COMPENSATE.**
// A debuggee listens on the low four and answers on the high four, so on a
// straight cable nothing but this board ever drives the high four and it hears
// nothing there, ever.  Frames arriving on them can only be the far board's
// low four reaching the wrong pins: the two ends disagree about the cable.
enum cons_debug_bit { CONS_DBG_ENGAGED = 1u << 0, CONS_DBG_ASKED = 1u << 1,
		      CONS_DBG_FOREIGN = 1u << 2, CONS_DBG_ACTIVE = 1u << 3,
		      CONS_DBG_LIVE = 1u << 4, CONS_DBG_PEER_FAR = 1u << 8 };

// **AND WORD 15 IS THE CABLE'S TWO COUNTS.**  The pins of a Pmod row are
// routed as coupled pairs; this link drives one signal a pair, the strobe and
// one data line, with the partner pin held low as a guard, and the counts are
// what says whether an edge still couples into the strobe and misaligns the
// frame it lands in.  A misaligned frame fails its marker or its parity, moves
// nothing, and the next one carries the levels again --- so what crosstalk
// costs is REFUSED FRAMES and never wrong values, unless it is frequent.  How
// frequent is a number nobody has, and these two are it.
//
// Both saturate and neither can be cleared except by resetting the fabric.  A
// marker of one byte, `0x44`, because twenty-four bits of count leave eight:
// neither an undriven bus's ones nor a dead one's zeros can be it.
#define CONS_DEBUG_FRAMES_MARK  0x44u
#define CONS_DEBUG_FRAMES_HEARD(w)    (((w) >> 8) & 0xFFFFu)
#define CONS_DEBUG_FRAMES_REFUSED(w)  ((w) & 0xFFu)

// Bits 7:5, one value a meaning.  `rtl/plumbing/cadr_dbg_cable.sv` names the
// same eight and its header has the table they come out of.
#define CONS_DBG_WIRE_SHIFT  5
#define CONS_DBG_WIRE_MASK   7u
enum cons_debug_wire {
	CONS_DBG_WIRE_AUTO_IDLE = 0,	/* auto, and not the debugger */
	CONS_DBG_WIRE_STRAIGHT = 1,	/* straight, set */
	CONS_DBG_WIRE_CROSSOVER = 2,	/* crossover, set */
	CONS_DBG_WIRE_LISTENING = 3,	/* auto, listening, driving nothing */
	CONS_DBG_WIRE_ST_FOUND = 4,	/* auto, straight, heard */
	CONS_DBG_WIRE_CR_FOUND = 5,	/* auto, crossover, heard */
	CONS_DBG_WIRE_ST_ASSUMED = 6,	/* auto, nothing heard, trying straight */
	CONS_DBG_WIRE_CR_ASSUMED = 7	/* auto, nothing heard, trying crossover */
};

// **PAGE 2's WORD 32: WHICH BUILD THE FABRIC IS.**
//
// `tools/build_stamp.tcl` writes eight hex digits into
// `BITSTREAM.CONFIG.USR_ACCESS` before every `write_bitstream` --- the
// commit's first seven and a nibble saying how the tree stood --- the part
// loads them at configuration, and
// `rtl/plumbing/xilinx7/cadr_usr_access.sv` reads them back from inside the
// fabric.  So a board that has been running for hours can still say which
// build it is carrying, which this project has twice not known and twice
// been bitten by: once when an image was built from a mid-change tree and
// the bay looked empty, and once when a partial commit left a port
// unconnected and a register read zero into a diagnosis.
//
// The same eight digits go into `BITSTREAM.CONFIG.USERID`, which the JTAG
// USERCODE register holds and `boards/*/vivado/program.tcl` reads back.
// **Two registers loaded from one value and read over paths that share
// nothing**, so a session that reads both has compared them rather than
// asked twice.
//
// **ALL ONES MEANS THERE IS NO STAMP.**  That is what an unprogrammed part
// reads and what a bitstream built before the flows stamped them leaves in
// the register, and `build_stamp_pack` makes sure no build can ever be
// called it --- the one value the format reserves.  A program that printed
// it as a commit would be inventing one.
#define CONS_PAGE2        32u
#define CONS_BUILD        (CONS_PAGE2 + 0u)
#define CONS_BUILD_NONE   0xFFFFFFFFu

// **WHICH DISPLAY BOARDS THE BACKPLANE HAS, page 2's word 33.**
//
// A CADR carries one display board or two.  `--tv-board` says which the first
// one is --- MIT's SIMPLE TV, which System 100 drives, or the LISPM TV that
// replaced it in December 1980 --- and the two differ in ONE bit a bus cycle
// can see, mode bit 7, which the LISPM TV reads the sync enable back through
// and the SIMPLE TV grounds.  `--color-tv` fits the second board, the color
// TV: `cadrtv/lmtv.order`'s "For the normal TV, x is 6.  For the color TV, x
// is 5", a LISPM TV strapped to `0o17200000` with its control words at
// `0o17377750`, carrying a color monitor of its own.
//
// **A MACHINE WITH NO COLOR BOARD MUST GIVE THE NXM AT THOSE ADDRESSES**,
// because that is how `COLOR-EXISTS-P` in `sys/window/color.lisp` finds out:
// it writes into the first buffer word with the error stop off and reads it
// back.  So the board is off by default, and a card that wants one says so.
//
// **IT IS ON PAGE 2 BECAUSE IT IS WHAT THE BACKPLANE IS**, the same kind of
// fact as the build stamp beside it, and not what the machine is doing.  Page
// 0 is the machine's and has been full since the debug cable took word 14.
//
// Three keys for word 6's reason --- a value that means nothing must not
// change what a machine has fitted --- and the color board's two are a value
// and its complement, so that no partial write of one can be the other.
#define CONS_DISPLAY        (CONS_PAGE2 + 1u)
#define CONS_TV_SIMPLE_KEY  0x534D504Cu	/* "SMPL" */
#define CONS_TV_LISPM_KEY   0x4C53504Du	/* "LSPM" */
#define CONS_COLOR_TV_KEY   0x434F4C52u	/* "COLR" */
#define CONS_NO_COLOR_TV_KEY (~CONS_COLOR_TV_KEY)
// The word's own marker, "TV": three keys and no one of them is the word's,
// so it is named rather than borrowed, and it is a marker for words 6, 13 and
// 14's reason --- a word reading zero when nothing has been set cannot be
// told from a window pointed somewhere else.
#define CONS_TV_MARK        0x5456u
#define CONS_TV_MARK_OF(w)  ((w) >> 16)
enum cons_display_bit { CONS_TV_LISPM = 1u << 0, CONS_TV_COLOR = 1u << 1 };

// **AND THE TWO BOARDS' COLOR MAPS, pages 4 and 5.**  Word 64 + c is the
// first display's color c and word 80 + c is the color board's: red in bits
// 23 to 16, green in 15 to 8 and blue in 7 to 0, which is
// `WRITE-COLOR-MAP`'s own channel order.  Read only.
//
// **THE MAP IS WRITE ONLY ON THE BUS AND THE PICTURE CANNOT BE DRAWN WITHOUT
// IT.**  A pixel of the color screen is four bits, an address into these
// sixteen, so an RFB server has to be told what a color is; and a checkpoint
// has to carry the map muir would have kept, `tv::Tv::color_map`.  The RAMs
// and their converters are off the board, so nothing on the Xbus can read one
// back and this port is the only way to ask.
// **AND WHAT THE BOARD'S OWN DISPLAY OUTPUT SHOWS, page 2's word 34.**
//
// The display output scans the display's region of DDR at a monitor's rate and
// drives the HDMI connector, with no software in the path.  What it SHOWS is a
// setting: the first display, the color board, or both --- and which way up,
// for a monitor stood on its side.  Both are written at boot by the disk pack
// program's init step, as `--tv-board` and `--color-tv` are.
//
// **THE MODE IS READ ONLY, AND THAT IS A FACT ABOUT AN MMCM RATHER THAN A
// DECISION.**  A video mode is a pixel clock; the pixel clock comes from an
// MMCM whose dividers are fixed in the bitstream; and moving one at run time
// means rewriting the lock and filter registers that go with them, which are
// Xilinx's own empirical values with no arithmetic behind them.  So three
// bitstreams carry the three modes and this word says which one is loaded.
// `docs/display-output.md` has the measurement.
//
// Six keys, on word 33's argument: three values and not two, so three keys and
// no complement, each four printable bytes and none of them zero, all ones,
// `IDENT`, `UNMAPPED` or what the word reads back.  The two settings are two
// facts on one word, so each key leaves the other alone.
#define CONS_HDMI           (CONS_PAGE2 + 2u)
#define CONS_HDMI_TV_KEY    0x48545631u	/* "HTV1" */
#define CONS_HDMI_COLOR_KEY 0x48545632u	/* "HTV2" */
#define CONS_HDMI_BOTH_KEY  0x48545642u	/* "HTVB" */
#define CONS_HDMI_UP_KEY    0x48555052u	/* "HUPR" */
#define CONS_HDMI_CW_KEY    0x48524357u	/* "HRCW" */
#define CONS_HDMI_CCW_KEY   0x48524343u	/* "HRCC" */
#define CONS_HDMI_MARK      0x4844u	/* "HD" */
#define CONS_HDMI_MARK_OF(w) ((w) >> 16)
enum cons_hdmi_bit { CONS_HDMI_FIRST = 1u << 0, CONS_HDMI_COLOR = 1u << 1 };
#define CONS_HDMI_ROT_SHIFT   2
#define CONS_HDMI_ROT_MASK    3u
#define CONS_HDMI_MODE_SHIFT  4
#define CONS_HDMI_MODE_MASK   3u
enum cons_hdmi_rot { CONS_HDMI_UPRIGHT = 0, CONS_HDMI_CW = 1, CONS_HDMI_CCW = 2 };
// The three modes a bitstream can carry, in the order `HDMI_MODE` names them.
enum cons_hdmi_mode { CONS_HDMI_1280 = 0, CONS_HDMI_1400 = 1, CONS_HDMI_1920 = 2 };

// **AND WHETHER THE BOARD'S ACTIVITY LAMPS BLINK, page 2's word 35.**
//
// Two lamps on the Arty Z7-20 --- LD1, the fabric's clock, and LD2, the
// microcycles --- and one on the Cora Z7-07S, LD1's green, blink by default.
// `--no-blinking-leds` makes them hold a level instead: the clock lamp is the
// clock generator's lock, and the microcycle lamp is lit for a moment after
// every microcycle, so it is solid while the machine runs and goes dark when
// it stops.  What the lamps say does not change, only how.  It is written at
// boot by the disk pack program's init step, as the display output's settings
// are, and the fabric comes up blinking.
//
// A key and its complement, on the debug cable's argument: the two are
// opposite operations, so no partial write of one can be the other.
#define CONS_LAMPS            (CONS_PAGE2 + 3u)
#define CONS_LAMP_STEADY_KEY  0x53544459u	/* "STDY" */
#define CONS_LAMP_BLINK_KEY   (~CONS_LAMP_STEADY_KEY)
#define CONS_LAMP_MARK        0x4C44u	/* "LD" */
#define CONS_LAMP_MARK_OF(w)  ((w) >> 16)
#define CONS_LAMP_STEADY      (1u << 0)

// **AND WHETHER THE BOARD'S OWN DISPLAY OUTPUT SLEEPS A MONITOR, page 2's word
// 36.**
//
// A digital link has no power management of its own, so the display output puts
// a monitor to sleep by stopping the link: the four lanes are held at one level
// and the monitor sees no signal.  It does that after `--hdmi-sleep` seconds with
// nobody at the board, and a key or the mouse AT THE BOARD --- which only
// `cadr-terminal` can tell from a viewer's --- wakes it and starts the timer
// over.  Zero never sleeps.
//
// **THE SETTING IS THE DISPLAY OUTPUT'S AND NOT THE CONSOLE'S.**  A write whose
// top half is `CONS_HDMI_SLEEP_KEY` carries a setting in its bottom fifteen bits
// to `rtl/plumbing/cadr_display_out.sv`, which holds it and starts its timer over
// from the write, and the word reads back what that block holds: the marker, the
// lanes muted in bit 15, the setting in bits 14 to 0.  **A BOARD WITH NO DISPLAY
// OUTPUT READS `CONS_UNMAPPED`**, which carries no marker: there is no timer to
// report.  A setting is written with all four lanes strobed, which a 32-bit
// store is.
//
// A write of `CONS_HDMI_WAKE_KEY` is a wake.  **THIS PROGRAM NEVER WRITES IT**:
// the rule is that only a person at the board wakes the monitor, and a console
// command that woke it would be a second way.  `cadr-terminal` writes it, and its
// `display_wake.h` copies these numbers.
#define CONS_HDMI_SLEEP          (CONS_PAGE2 + 4u)
#define CONS_HDMI_SLEEP_KEY      0x4853u	/* "HS", the top half of a setting */
#define CONS_HDMI_WAKE_KEY       0x57414B45u	/* "WAKE" */
#define CONS_HDMI_SLEEP_MARK     0x5A5Au	/* "ZZ" */
#define CONS_HDMI_SLEEP_MARK_OF(w) ((w) >> 16)
#define CONS_HDMI_ASLEEP         (1u << 15)
#define CONS_HDMI_SLEEP_SECONDS  0x7FFFu
#define CONS_HDMI_SLEEP_MAX      32767u
// What the fabric comes up with, `--hdmi-sleep`'s own default.
#define CONS_HDMI_SLEEP_DEFAULT  300u

#define CONS_PAGE4        64u
#define CONS_PAGE5        80u
#define CONS_COLOR_MAP_WORD(board, color) \
	(((board) ? CONS_PAGE5 : CONS_PAGE4) + (unsigned)(color))
#define CONS_MAP_COLORS   16
#define CONS_MAP_CHANNELS 3
#define CONS_MAP_RED(w)   (((w) >> 16) & 0xFFu)
#define CONS_MAP_GREEN(w) (((w) >> 8) & 0xFFu)
#define CONS_MAP_BLUE(w)  ((w) & 0xFFu)

// The nibble, `tools/build_stamp.tcl`'s five values and no others.  The flows
// write nothing else; a word carrying anything else came from somewhere that
// is not this project's, and `cons_build_of` says so rather than guessing.
enum cons_build_tree {
	CONS_BUILD_CLEAN     = 0x0,	/* every tracked file matched HEAD */
	CONS_BUILD_MODIFIED  = 0x1,	/* a tracked file differed */
	CONS_BUILD_UNTRACKED = 0x2,	/* an untracked file was present, and the
					   flows build from a glob and not the index */
	CONS_BUILD_BOTH      = 0x3,
	CONS_BUILD_NO_TREE   = 0xF	/* git could not say how the tree stood */
};

struct cons_build {
	uint32_t word;		/* the register, as read */
	int      stamped;	/* 0 when the word is CONS_BUILD_NONE */
	uint32_t commit;	/* 28 bits: the commit's first seven hex digits */
	unsigned tree;		/* the nibble, as read */
	int      known;		/* the nibble is one of the five above */
	int      modified;	/* and what it says, when it is */
	int      untracked;
	// **A COMMIT OF ZERO WITH THE TREE UNKNOWN IS `0000000f`**, which the
	// stamp writes when git answered nothing at all: a build from a
	// directory that is not a checkout.  It is a different thing from a
	// known commit whose tree could not be read, and a program that ran
	// them together would print `commit 0000000`.
	int      no_git;
};

// Pure: no bus, no system, and it is in this file rather than in the console
// program so that anything holding the word can print it, with or without an
// operating system under it.
struct cons_build cons_build_of(uint32_t w);
// "clean", "modified", "untracked", "modified and untracked", or a phrase
// saying the nibble is not one the format defines.  Never NULL.
const char *cons_build_tree_words(const struct cons_build *b);
// One line, through `say`, so that everything printing this prints the same
// words and they cannot drift apart.
void cons_say_build(const struct cons_build *b);

// Page 1: word 16 + k is diagnostic register k.
#define CONS_PAGE1        16u
#define CONS_SPY_WORD(k)  (CONS_PAGE1 + (unsigned)(k))
// Bit 16 of a page-1 read: the diagnostic cycle was not answered.  Nothing
// else is set, so a word with it up carries no data and must never be masked
// down to sixteen bits and believed.
#define CONS_LOST_BIT     0x00010000u

// The sixteen registers, muir's names (`spy.rs`).  Reads:
enum cons_spy_read {
	SPY_IR_LOW = 0, SPY_IR_MED = 1, SPY_IR_HIGH = 2, SPY_OPEN = 3,
	SPY_OPC = 4, SPY_PC = 5, SPY_OB_LOW = 6, SPY_OB_HIGH = 7,
	SPY_FLAG_1 = 8, SPY_FLAG_2 = 9, SPY_M_LOW = 10, SPY_M_HIGH = 11,
	SPY_A_LOW = 12, SPY_A_HIGH = 13, SPY_STAT_LOW = 14, SPY_STAT_HIGH = 15
};
// Register 3 has no read select --- Y3 of the 74S138 at SPY0 1F01 is not
// connected --- so no buffer drives the bus and it reads all ones.
#define SPY_OPEN_READ     0xFFFFu
// Writes: the three halves of the debug IR, then the three control registers.
enum cons_spy_write { SPY_CLK = 3, SPY_OPC_CONTROL = 4, SPY_MODE = 5 };
// The clock control register, CC's `SPY-CLK`.
enum cons_clk_bit { CLK_RUN = 1u << 0, CLK_STEP = 1u << 1, CLK_NOP11 = 1u << 2,
		    CLK_IDEBUG = 1u << 3, CLK_LDSTAT = 1u << 4 };
// The mode register, CC's `SPY-MODE`.  Bits 6 and 7 are PULSES and not
// settings: `-PROG.RESET` and `PROG.BOOT` are gated with the write strobe on
// OLORD2, so a write with them set is a pulse at the strobe's leading edge,
// 100 ns before the register loads at its trailing one.
enum cons_mode_bit { MODE_SPEED0 = 1u << 0, MODE_SPEED1 = 1u << 1,
		     MODE_ERRSTOP = 1u << 2, MODE_STATHENB = 1u << 3,
		     MODE_TRAPENB = 1u << 4, MODE_PROMDISABLE = 1u << 5,
		     MODE_RESET = 1u << 6, MODE_BOOT = 1u << 7 };

// --- FLAG-1, register 8 -------------------------------------------------
//
// Every field is in its logical sense --- true means the machine is waiting,
// the error is present, the halt is on --- and `cons_flag1_of` applies the
// board's polarities.  **THE LOW BYTE COMES THROUGH AN INVERTING DRIVER**, so
// it reads HIGH for an error; CC's `CC-PRINT-ERROR-STATUS` says so in as many
// words.  That byte is easy to get upside down and the inverting driver is
// what decides it.
struct cons_flag1 {
	int wait;		/* bit 15, -WAIT: the cpu clock is stopped for the bus */
	int v1pe;		/* bit 14, -V1PE: level-2 map parity error */
	int v0pe;		/* bit 13, -V0PE: level-1 map parity error */
	int promdisable;	/* bit 12, off the mode register */
	int stathalt;		/* bit 11, -STATHALT: halted by the statistics counter */
	int err;		/* bit 10, ERR: any of the ten parity errors, or -HALTED */
	int ssdone;		/* bit 9, SSDONE: the single step asked for has run */
	int srun;		/* bit 8, SRUN: RUN as the master clock registered it */
	int higherr;		/* bit 7, -HIGHERR: the A-memory address parity checks */
	int mempe;		/* bit 6, -MEMPE */
	int ipe;		/* bit 5, -IPE: control store */
	int dpe;		/* bit 4, -DPE: dispatch memory */
	int spe;		/* bit 3, -SPE: microcode stack */
	int pdlpe;		/* bit 2, -PDLPE: PDL buffer */
	int mpe;		/* bit 1, -MPE: M memory */
	int ape;		/* bit 0, -APE: A memory */
};
struct cons_flag1 cons_flag1_of(uint16_t w);
uint16_t cons_flag1_word(const struct cons_flag1 *f);

// --- FLAG-2, register 9 -------------------------------------------------
//
// The four `NC` inputs of the two 74LS244s float, and a floating TTL input is
// a one, so bits 15, 14, 7 and 6 read as ones on the board.  Reading them as
// zeros is the natural assumption and is wrong.  `-VMAOK` is low when the
// access is permitted, so `vmaok` here is the logical sense and the word
// inverts it.
#define CONS_FLAG2_OPEN 0xC0C0u
struct cons_flag2 {
	int wmapd;		/* bit 13 */
	int destspcd;		/* bit 12 */
	int iwrited;		/* bit 11 */
	int imodd;		/* bit 10 */
	int pdlwrited;		/* bit 9 */
	int spushd;		/* bit 8 */
	int ir48;		/* bit 5: the control store's parity bit as IR holds it */
	int nop;		/* bit 4 */
	int vmaok;		/* bit 3, logical: the last mapped access was permitted */
	int jcond;		/* bit 2 */
	int pcs1;		/* bit 1 */
	int pcs0;		/* bit 0 */
};
struct cons_flag2 cons_flag2_of(uint16_t w);
uint16_t cons_flag2_word(const struct cons_flag2 *f);

// --- the face ------------------------------------------------------------

struct console {
	uint32_t (*read)(struct console *c, unsigned word);
	void (*write)(struct console *c, unsigned word, uint32_t v);
	// Wait, in microseconds.  The board sleeps; the model advances its
	// machine.  `pack_side.h`'s `pause` one seam along.
	void (*pause)(struct console *c, unsigned us);
	void *ctx;
	// The tally.  `lost` counts diagnostic cycles that came back with bit
	// 16 up: a grant that never came or a register block that never
	// answered, bounded by the module's own LOST_T and not by the Arm.
	unsigned long reads, writes, lost;
};

void cons_init(struct console *c);

// IDENT reads "CONS".  0 if it does, -1 with `*got` otherwise.
int cons_ident_ok(struct console *c, uint32_t *got);
uint32_t cons_stat(struct console *c);
// Page 2's word 32, read.  Declared here and not beside `cons_build_of`
// above because that block is above `struct console`, the constants having
// to sit with the other words' constants.
uint32_t cons_build_word(struct console *c);

// The two counters, low half then high, which is what latches the pair.
uint64_t cons_cycles(struct console *c);
uint64_t cons_ticks(struct console *c);

// --- the virtual address register, Q and MD, page 0's words 7, 8 and 9 ---
//
// **NONE OF THE THREE IS ON THE DIAGNOSTIC BUS.**  ../muir/src/spy.rs is the
// whole vocabulary of MIT's sixteen --- IR in three halves, OPC, PC, OB, the
// two flag words, M, A and ST, and the open bus at 3 --- and neither the
// virtual address register nor Q nor MD is among them, so `cons_read_regs`
// above cannot show any of them and no console on that bus alone ever could.
// They come out of
// `cadr_machine` on wires of their own and land on page 0 beside CYCLES and
// TICKS, which are also the machine's and are also not on that bus.
//
// **WHY THEY ARE WORTH READING.**  On 2026-09-10 the board ran a System 100
// band for 351 million microcycles and halted inside PDL-BUFFER-REFILL, where
// the microcode reads a second-level map entry, writes it back with
// read/write access ORed in, and then reads THROUGH the entry it has just
// hacked --- and that read took a page fault, which muir on the same pack
// does not.  Two suspects: the map write did not take, or the address read is
// not the page the map was hacked for.  Three faults injected into muir
// reproduce the board's readout bit for bit --- same PC, same OPC, same
// FLAG-1 and FLAG-2, same IR, A, M and OB --- so the sixteen cannot separate
// them.  These two can, and the whole of it is in one comparison: **the
// map-side faults leave VMA and Q equal, and the wrong-address fault leaves
// them one page apart.**  A CADR page is 256 words and VMA<23:8> is the page
// number the map is indexed by, which is why the page numbers are carried
// here beside the raw words.
//
// **AND THE BOARD ANSWERED THAT COMPARISON ON 2026-09-11, WHICH IS WHY THERE
// IS A THIRD WORD.**  With the halt reproduced at 05:35 the virtual address
// register read 0o2640010 and Q read 0o600000000, and 0o2640010 is exactly
// what muir shows for the two MAP-SIDE injections --- the wrong-address
// injection puts 0o2640410 there.  So the machine asked for the page it meant
// to ask for and what is left is the map.  MD is where the next evidence is,
// and the paragraph below says why.
//
// **AND MD IS THE THIRD, page 0's word 9.**  MD is the memory data register:
// the word a completed read left there, as of the last microcycle boundary.
// It is not on the diagnostic bus either.  Two things make it worth reading
// beside the other two, and the second is the one that matters:
//
//   - **It is what the last read RETURNED.**  A reference the map refuses
//     starts no bus cycle at all --- the cycle is armed by MEMSTART AND
//     VMAOK --- so a faulting read never strobes -LOADMD and MD still holds
//     the word before it.  Compared with muir's md column for the same
//     microcycle, that says whether the machine had read what muir read.
//   - **MD IS ITSELF A MAP INDEX.**  `cadr_microcycle.sv:1006`: MAPI is
//     VMA<23:8> while MEMSTART is up and MD<23:8> otherwise --- the 74S258s
//     at VMAS 1C20, whose select is -MEMSTART.  So the entry a SRCMAP read
//     looks at is the one MD<23:8> selects, and the entry a memory reference
//     goes through is the one VMA<23:8> selects.  In PDL-BUFFER-REFILL the
//     microcode reads an entry, hacks it, and then reads through one, and
//     these two page numbers are which entry each of those was.
//
// **READ VMA FIRST.**  The read of word 7 latches Q and MD beside it, so the
// three name one microcycle; a program that reads word 8 or word 9 alone gets
// whatever the last read of word 7 latched.  Same rule as CYCLES then CYCLESH
// and the same reason: separate loads of a running machine are separate
// instants, and a comparison across the gap would answer a question nobody
// asked.  `cons_read_machine_words` is in that order for that reason, and it
// is the only reader of these three offered here --- **there is deliberately
// no way to fetch one of them on its own**, because the order is the rule and
// a rule a caller can get wrong is a rule that will be got wrong.
//
// It was `struct cons_vmaq` while there were two.  A name that lists what it
// covers rots the day the list grows, which is why this one describes them
// instead.
//
// Halt the machine first if the answer is to mean anything: on a halted
// machine these are exact, MCLK running whether or not MACHRUN does.
struct cons_machine_words {
	uint32_t vma, q, md;
	/* bits 23:8: the page, which is what the two levels of the map are
	   indexed by.  md_page is the entry a SRCMAP read looks at and
	   vma_page the entry a memory reference goes through. */
	uint32_t vma_page, q_page, md_page;
	int unmapped;			/* all three read UNMAPPED: a fabric without them */
};
void cons_read_machine_words(struct console *c, struct cons_machine_words *v);
void cons_say_machine_words(const struct cons_machine_words *v);

// One diagnostic cycle.  `cons_spy_read` returns 0 with `*v` set, or -1 when
// the cycle was not answered --- in which case `*v` is untouched and there is
// no data, bit 16 being the whole of the answer.
int cons_spy_read(struct console *c, unsigned eadr, uint16_t *v);
void cons_spy_write(struct console *c, unsigned eadr, uint16_t v);

// --- the vocabulary ------------------------------------------------------

// `halt`: 0 into the clock control register.  CC's first act on a debuggee,
// ../muir/tests/lashup.rs:152-157.
void cons_halt(struct console *c);
// `start`: RUN.  ../muir/tests/lashup.rs:311-315.
void cons_start(struct console *c);

// `boot`: the light panel's button, page 0's word 13 with `CONS_BOOT_KEY` on
// it.  ../muir/src/prompt.rs's `Command::Boot` --- "the boot button, which is
// what starts a machine: it presets RUN, and the machine runs from the PROM
// at 0".
//
// **WHAT THE BUTTON DOES, AND IT IS THE SAME ON A HALTED MACHINE AND A
// RUNNING ONE.**  `-BOOT` presets RUN at the 74S74 at OLORD1 1A14, clears the
// boot trap's 74LS109 at 1A18 so the next microcycle is nopped and the PC is
// forced to zero, and is one of the three inputs of RESET at the 74S10 at
// 1C08, which clears the console's own registers --- PROMDISABLE among them,
// which is what puts the boot PROM back over the control store.  So:
//
//   - a RUNNING machine stops what it was doing and runs the PROM from 0;
//   - a HALTED machine, its RUN clear, STARTS: the button presets RUN, which
//     is the one thing that starts a CADR and the reason muir's `continue`
//     and `step` send you here.
//
// It does not clear main memory, the control store, the scratchpads or the
// map.  A boot is not a reset.
void cons_boot(struct console *c);

// What `boot` reports: the machine either side of the press.  The button is
// let go before the write is answered --- `cadr_console.sv` holds `BVALID`
// off for the length of the pulse --- so `after` is a machine already running
// the PROM again and not one with a finger on it.
struct cons_boot_report {
	uint64_t cycles_before, cycles_after;
	uint16_t pc_before, pc_after;
	int lost_before, lost_after;	/* a diagnostic cycle was not answered */
	uint32_t word;			/* word 13 read back after the press */
	unsigned presses;		/* its count, saturating at 255 */
	int held;			/* the line was still down when read */
	int running;			/* CYCLES moved over the settle */
	int promdisable;		/* FLAG-1's bit, which a boot clears */
};
int cons_boot_and_report(struct console *c, unsigned settle_us, struct cons_boot_report *r);
void cons_say_boot(const struct cons_boot_report *r);

// --- THE HELD MACHINE ----------------------------------------------------
//
// **`--no-auto-boot` LEAVES THE BUTTON UNPRESSED, AND THERE ARE TWO WAYS TO
// ASK FOR IT.**  muir's own flag leaves a CADR as it is when the power comes
// on: RUN clear, nothing run, and only the button starts it.
//
//   the switch   SW0 on the board.  The FABRIC holds the machine: it comes out
//                of reset with `RUN` clear and has never run a microcycle.
//                `cons_switch` reads it back, and the init step writes the
//                marker without halting anything, there being nothing to halt.
//   the flag     `--no-auto-boot` in `fpgarc` on the card.  Nothing in the
//                fabric changes for it: the init step halts the machine
//                before the disk pack program presents a drive, so the PROM
//                has run for a few hundred milliseconds and got as far as
//                waiting for a drive.
//
// Either way the marker at `CONS_HELD_PATH` is what THIS program knows it by,
// and its first line names which of the two it was.  The two are an OR and the
// flag can never turn the switch off.
//
// While the marker exists, `start` and `step` refuse and say what muir says;
// `boot` presses the button and removes it, because the button is what takes
// the hold off, whichever way the hold was asked for.  A marker that is not
// there is the ordinary case and costs one `access` per command.
#define CONS_HELD_PATH    "/var/run/cadr-held"

// muir's own sentence for a machine whose RUN is clear, ../muir/src/main.rs's
// `say_halted`, which is what its `continue` and `step` print.
#define CONS_HELD_SAYING  \
	"the machine is halted, its RUN clear: boot presses the button that starts it"

// Whether the marker is there.  `path` is `CONS_HELD_PATH` on the board and
// its own file in the host test.
int cons_held(const char *path);
// Take the hold off: remove the marker.  Returns 0 if it is gone afterwards,
// whether or not it was there to begin with.
int cons_release_held(const char *path);

// --- WHAT IS NOT IN THIS FILE, AND WHY ------------------------------------
//
// **`trace-keys` IS NOT HERE, BECAUSE THIS FILE WAS ALSO COMPILED FOR A
// MACHINE WITH NO OPERATING SYSTEM.**  `console_face.c` was built twice: once
// for Linux, and once for a bare-metal core with picolibc and no kernel under
// it.  A word that reads a pid file and calls `kill` had no meaning on the
// second, and it did not merely go unused --- `fopen` alone drags picolibc's
// stdio in, which wants `open`, `close`, `read`, `write` and `lseek`, and
// `sbrk` wants a `__heap_end` that build had not got, so it stopped LINKING.
// Measured: it did, the day `trace-keys` was written into this file, with
// nothing on that side calling it.  That second build is gone; the rule stays,
// because it is what keeps this file readable as the register face alone.
//
// So the rule this file is held to: **what is in `console_face.c` drives the
// register face and means the same thing on both hosts.**  Anything that
// opens a file, signals a process or otherwise asks an operating system for
// something belongs in `console_host.c`, which only the front end and the
// host test compile.  `console_host.h` has `trace-keys`.

// `switch`: what SW0 did and where it is.  The two STAT bits, read as one
// word, so that the pair names one instant.
//
// **THE EXIT STATUS IS THE ANSWER AND THE LINE IS THE EVIDENCE**, and both are
// there on purpose: the init step reads the status, and a person reads the
// line.  `cadr-console switch` exits 0 when the switch held the machine at the
// last reset and non-zero when it did not --- which is the same shape as
// `mountpoint -q` and as `fpgarc_has`, a question rather than a failure.  A
// console that could not reach the board at all exits non-zero too, and that
// is the safe direction: it means "no hold from the switch", and a board whose
// console cannot be reached is not a board anything is being held on.
struct cons_switch {
	int held_at_reset;	/* the machine came out of reset with RUN clear */
	int now;		/* where SW0 is today */
	uint32_t stat;		/* the word both came out of */
};
void cons_read_switch(struct console *c, struct cons_switch *s);
void cons_say_switch(const struct cons_switch *s);

// `debug-cable-connect` and `debug-cable-disconnect`: the role on Pmod JA.
// muir's own flag is `--debug-cable-connect` and takes no argument here,
// because the connector is fixed in the bitstream; there is no listen flag
// because listening is what a CADR always does.
//
// **ASKING IS NOT HAVING, and the caller is told both.**  The write completes
// at once --- a role is a level and not a pulse, and a write that waited for a
// role the fabric may refuse would hang the store that made it, which is the
// one failure this project has already had on a general-purpose port.  So a
// program writes and then READS, which is what `cons_read_debug_cable` is for.
struct cons_debug_cable {
	int engaged;		/* the role this board HAS */
	int asked;		/* the role it was last told to take */
	int foreign;		/* somebody else is the debugger on the connector */
	int peer_far;		/* and on the four pins this board answers on */
	int active;		/* the far end is driving its pin group */
	int live;		/* and what arrives is good frames */
	int wire;		/* enum cons_debug_wire: what came of the setting */
	unsigned connects;	/* how many connects since the console came up */
	unsigned heard;		/* frames that arrived, saturating at 65535 */
	unsigned refused;	/* and failed their marker, parity or fill, at 255 */
	int frames_ok;		/* word 15 carried its marker */
	uint32_t word;		/* the role's bits came out of this one */
	uint32_t frames;	/* and the two counts out of word 15 */
};
void cons_debug_cable_connect(struct console *c);
void cons_debug_cable_disconnect(struct console *c);
// The wiring, by `enum cons_debug_wire`'s first three values: auto, straight,
// crossover.  Anything else writes nothing.  Refused by the fabric while this
// board is the debugger, so write and then read.
void cons_debug_cable_wiring(struct console *c, int wire);
void cons_read_debug_cable(struct console *c, struct cons_debug_cable *d);
void cons_say_debug_cable(const struct cons_debug_cable *d);

// --- the backplane's display boards, page 2's word 33 and pages 4 and 5 ---

struct cons_display {
	uint32_t word;		/* word 33 as it read */
	int mark_ok;		/* it carried `CONS_TV_MARK` */
	int lispm;		/* the first display is a LISPM TV */
	int color;		/* a color TV is fitted */
};

void cons_read_display(struct console *c, struct cons_display *d);
void cons_say_display(const struct cons_display *d);
// Which board the first display is, and whether the second is there.  Each is
// a keyed write of word 33 and each leaves the other alone, so a caller that
// wants both writes twice.  Write and then READ: a wrong key is dropped in
// silence, which is what the key is for.
void cons_set_tv_board(struct console *c, int lispm);
void cons_set_color_tv(struct console *c, int on);
// One board's whole color map, `[color][channel]` with red first.  `board`
// is 0 for the first display and 1 for the color TV.
void cons_read_color_map(struct console *c, int board,
			 uint8_t map[CONS_MAP_COLORS][CONS_MAP_CHANNELS]);

// --- what the display output shows, page 2's word 34 ---------------------

struct cons_hdmi {
	uint32_t word;		/* word 34 as it read */
	int mark_ok;		/* it carried `CONS_HDMI_MARK` */
	int first;		/* the first display goes to the monitor */
	int color;		/* the color board does */
	int rotate;		/* `enum cons_hdmi_rot` */
	int mode;		/* `enum cons_hdmi_mode`, read only */
};

void cons_read_hdmi(struct console *c, struct cons_hdmi *h);
void cons_say_hdmi(const struct cons_hdmi *h);
// Which screens go to the monitor, and which way up.  Each is a keyed write of
// word 34 and each leaves the other alone, so a caller that wants both writes
// twice.  Write and then READ: a wrong key is dropped in silence, which is what
// the key is for.  `first` and `color` may not both be zero --- a monitor
// showing nothing is not a setting anybody asks for --- and a call that says so
// writes nothing and returns -1.
int cons_set_hdmi_output(struct console *c, int first, int color);
int cons_set_hdmi_rotate(struct console *c, int rot);
// The mode's own name, for a program printing what a bitstream carries.
const char *cons_hdmi_mode_name(int mode);

// --- whether the activity lamps blink, page 2's word 35 --------------------

struct cons_lamps {
	uint32_t word;		/* word 35 as it read */
	int mark_ok;		/* it carried `CONS_LAMP_MARK` */
	int steady;		/* the lamps hold a level rather than blink */
};

void cons_read_lamps(struct console *c, struct cons_lamps *l);
void cons_say_lamps(const struct cons_lamps *l);
// Steady or blinking, a keyed write of word 35.  Write and then READ: a wrong
// key is dropped in silence, which is what the key is for.
void cons_set_lamps_steady(struct console *c, int steady);

// --- whether the display output sleeps, page 2's word 36 ------------------

struct cons_hdmi_sleep {
	uint32_t word;		/* word 36 as it read */
	int mark_ok;		/* it carried `CONS_HDMI_SLEEP_MARK`: there is a display output */
	int asleep;		/* the lanes are stopped: a monitor on them sees no signal */
	unsigned seconds;	/* the setting; zero never sleeps */
};

void cons_read_hdmi_sleep(struct console *c, struct cons_hdmi_sleep *s);
void cons_say_hdmi_sleep(const struct cons_hdmi_sleep *s);
// A new setting in seconds, which starts the display output's timer over from
// the write and wakes a monitor asleep.  -1 and nothing written for a setting
// the word cannot carry.  Write and then READ: a board with no display output
// takes the write and holds nothing.
int cons_set_hdmi_sleep(struct console *c, unsigned seconds);
// A setting as a person or a card writes it: decimal digits and nothing else,
// no more than `CONS_HDMI_SLEEP_MAX`.  0, or -1 with `*seconds` untouched.
int cons_parse_hdmi_sleep(const char *text, unsigned *seconds);

// `step N`: CC's `CC-CLOCK`, `2` then `0`, N times (../muir/src/spy.rs's
// ClockControl and ../muir/tests/spy.rs:743-761).
//
// **ONE MICROCYCLE A STEP, AND THE COUNT IS THE WITNESS.**  `SSTEP` and
// `SSDONE` are two flip flops of the 74S174 at OLORD1 1A10 and `MACHRUN`'s
// first term is `SSTEP AND -SSDONE`, so the machine runs for exactly the one
// master clock in which the first is set and the second is not --- MIT's
// `ir.bits` says "raising step clocks the machine once", and the bit must be
// lowered again before the next.  So `moved` must equal `asked`, and the
// caller is told both rather than being asked to trust one: a step that
// silently clocked nothing, or clocked a stream, is the failure this project
// keeps meeting and `cons_say_step` names either out loud.
struct cons_step {
	unsigned asked;		/* how many steps were asked for */
	uint64_t before, after;	/* CYCLES either side */
	uint64_t moved;		/* after - before: must equal `asked` */
	int ssdone;		/* FLAG-1 bit 9 after: the board's own witness */
};
void cons_step(struct console *c, unsigned n, struct cons_step *s);

// `regs`: all sixteen, read once each, in order.  `lost` has a bit per
// register whose cycle was not answered; those entries are not data.
struct cons_regs {
	uint16_t v[16];
	uint16_t lost;
	// Page 0's words 7, 8 and 9, read after the sixteen and printed with
	// them.  They are not diagnostic registers and the printing says so;
	// they are here because a person who typed `regs` wants the machine's
	// state and not a list of what happens to be on one bus.
	struct cons_machine_words mw;
};
void cons_read_regs(struct console *c, struct cons_regs *r);
// muir's name for a register on a read.
const char *cons_reg_name(unsigned eadr);

// `status`: is the machine running, where is its PC, is it halted and why.
//
// **RUNNING IS MEASURED AND NOT INFERRED.**  CYCLES is sampled twice
// `settle_us` apart and `running` is whether it moved.  `Machine::cycles`
// (../muir/src/rtl.rs:2404) does not advance on a halted master clock cycle,
// so a machine that is not running cannot move it; and `Engine::step` goes on
// returning Ok on a stopped machine, which is why nothing but the counter can
// answer this.  The reason a stopped machine gives is FLAG-1's, decoded as
// ../muir/src/main.rs:3048-3074 (`machrun_low`) decodes it.
struct cons_status {
	int lost;			/* a diagnostic cycle was not answered: nothing below is data */
	uint16_t flag1_word, flag2_word;
	struct cons_flag1 f1;
	struct cons_flag2 f2;
	uint16_t pc, opc;
	struct cons_machine_words mw;	/* page 0's words 7, 8 and 9; see above */
	uint64_t cycles_first, cycles_second, ticks;
	unsigned settle_us;
	int running;			/* CYCLES moved */
	const char *why;		/* NULL if running; else why it is not */
	// **AND SW0, BECAUSE A MACHINE THAT NEVER RAN LOOKS EXACTLY LIKE ONE
	// THAT STOPPED.**  `status` on a held machine says NOT RUNNING and
	// gives the reason FLAG-1 gives, which is "halted from the console:
	// SRUN is down" --- true, and misleading, because nobody halted it.
	// These two say which it is, and they cost no extra read: they are
	// bits of the STAT word this already has to look at.
	struct cons_switch sw;
	// **AND WHICH BUILD THE FABRIC IS**, for the reason SW0 is here: it is
	// one more read of page 0's neighbor and it answers the question a
	// person asking `status` usually has next, which is whether the board
	// is running what they think they served it.
	struct cons_build build;
};
int cons_status(struct console *c, unsigned settle_us, struct cons_status *st);

// What each of them prints.  The printing is part of the contract and not a
// convenience: `step` on today's fabric returns `moved = 0` and must SAY so,
// and only an assertion on the words catches a version that does not.
void cons_say_step(const struct cons_step *s);
void cons_say_status(const struct cons_status *st);
void cons_say_regs(const struct cons_regs *r);
void cons_say_flag1(uint16_t w);
void cons_say_flag2(uint16_t w);

// --- main memory, which does NOT come through the machine -----------------
//
// **CC REACHES MAIN MEMORY THROUGH THE DEBUGGEE'S UNIBUS MAP AND THIS FABRIC
// HAS HALF OF ONE.**  muir's route is `DBG-SETUP-UNIBUS-MAP`: a map register
// at `0o766140`-`0o766176` loaded with the Xbus page, then the word read or
// written half at a time through the mapped window at `0o140000`-`0o177777`,
// low half then high (../muir/src/lashup.rs:262-284,
// ../muir/src/machine.rs:518-580, ../muir/tests/lashup.rs:712-769).
//
// **The registers are there now** --- `rtl/machine/cadr_busint_regs.sv`
// answers `0o766140`-`0o766176` and the sixteen store and read back --- and
// **the window is not**.  Nothing on this Unibus answers
// `0o140000`-`0o177777`, and the 29701s at RBUF and WBUF that make a mapped
// cycle out of two Unibus words are not built either, because their one
// master is the debug cable's and that cable has no side here.  So the
// register half of CC's route exists and the cycle half does not, which is
// still not a route.
//
// **This paragraph said BOTH halves were absent and was made wrong by
// somebody else's correct change**, which is exactly the rot
// `docs/mutations.md` records: a record's reasoning ages faster than its
// text, so the `@old` of a mutation rots loudly and prose rots silently.
// It is cited to the commit that fixed it rather than left to read as true.
//
// The other route, CC's `CC-EXECUTE-R`, loads a microinstruction into the
// debug IR and clocks it --- and clocking it is `SSTEP`, the same two hunks
// `step` is waiting for.
//
// **SO EXAMINE AND DEPOSIT GO THROUGH /dev/mem ON THE MACHINE'S RESERVED DDR
// REGION, AND SAY SO IN THEIR OWN OUTPUT.**  What that reads is the memory
// the machine's bus cycles land in, not the machine's view of it: nothing is
// halted, nothing is synchronized, and a word read while the machine is
// running is a word from an instant nobody named.  The addresses are
// `rtl/plumbing/cadr_ddr_map.sv`'s and the arithmetic is its `main_byte_address`.
#define CONS_MAIN_BASE 0x18000000u
// What the machine can address today: 60 boards of 64K words.  The region
// reserves 64 MB for a machine whose physical address had been widened, which
// would be a fork of the machine and not a change here.
#define CONS_MAIN_WORDS_REACHABLE 3932160u
// `cadr_ddr_map::main_byte_address`: a word is 32 bits, so the byte address
// is the CADR's 22-bit physical word address shifted left by two.  Arithmetic
// and no state, so it is a header the way `pack_ecc.h` is.
static inline uint32_t cons_main_byte_address(uint32_t phys)
{
	return CONS_MAIN_BASE + ((phys & 0x3FFFFFu) << 2);
}

#endif
