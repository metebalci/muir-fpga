// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// /dev/mem, and the guard that must run before anything on a GP port.
//
// **THE GUARD IS NOT OPTIONAL AND NO SOFTWARE CAN CATCH ITS FAILURE.**  A
// read on `M_AXI_GP0` or `M_AXI_GP1` that nothing in the fabric answers does
// not fault the Arm: it hangs both cores at one PC each, measured on the
// board (CLAUDE.md, and `rtl/cadr_gp0_default.sv` says it at length).  So the
// one thing a program may read first is somewhere the processing system can
// always reach --- the EMIO tally at 0xE000A068 and 0xE000A06C, `DATA_2_RO`
// and `DATA_3_RO`, which report the pin whatever the direction registers say
// and whose clock `ps7_init` has already turned on (bit 22 of the write to
// APER_CLK_CTRL at 0xF800012C).
//
// **AND THE TALLY CARRIES MARKER BITS, because a value that means nothing
// must not be a value the instrument can mean.**  `docs/board.md` measured
// both ends of the negative control: with the level shifters on and nothing
// in the fabric driving the pins the processing system reads 0xFFFFFFFF, and
// with them off it reads 0x00000000 --- so an absent instrument reads exactly
// like four saturated counters.  `rtl/cadr_mem_count.sv` therefore counts in
// fifteen bits and sets bit 15 of each half, and the pattern
// `(w & 0x80008000) == 0x00008000` is one neither reading can produce.  The
// test is that pattern and not "not all ones" and not "not zero": a tally
// whose top bit came up for some third reason would pass either of those and
// mean nothing.
//
// A board somebody knows --- a bitstream without the counters, say --- is
// reached with the program's own `--no-guard`, never by weakening this.

#ifndef CADR_MEM_H
#define CADR_MEM_H

#include <stddef.h>
#include <stdint.h>

// The EMIO tally.
#define CADR_GPIO_BASE     0xE000A000u
#define CADR_GPIO_DATA2_RO 0x68u
#define CADR_GPIO_DATA3_RO 0x6Cu
#define CADR_TALLY_MASK    0x80008000u
#define CADR_TALLY_MARK    0x00008000u

// "NONE": what `rtl/cadr_gp0_default.sv` answers, the proving boards' default
// slave --- a board with a GP port and nothing of ours behind it.  It belongs
// to neither program: the pack side looks for "PACK" and the console for
// "CONS", and both meet this instead.
#define CADR_IDENT_NONE    0x4E4F4E45u

// `open("/dev/mem", O_RDWR | O_SYNC)`.  O_SYNC is what makes every mapping
// off this descriptor uncached: registers must be, and a word the fabric
// reads or writes must not sit in a cache an HP port cannot see.  Returns
// the descriptor, or -1 having said why.
int cadr_open_mem(void);

// One uncached mapping.  `what` names it in the failure line.  NULL on
// failure, having said why.
void *cadr_map(int fd, uint32_t phys, size_t bytes, const char *what);

// The whole guard: map the GPIO block, read the two words, apply the test,
// say what was found.  0 if the fabric may be touched, -1 if it may not.
int cadr_guard(int fd, const char *port);

// The test alone, on two words already in hand: 1 if they carry the marker
// bits.  Split out so that it can be checked without /dev/mem, and so that
// the pattern is written once.
int cadr_tally_ok(uint32_t w2, uint32_t w3);

#endif
