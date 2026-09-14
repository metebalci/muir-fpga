// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system's own map, as `rtl/plumbing/cadr_soc.sv` decodes
// it, and the two faces that belong to the system rather than to the machine.
//
// **THE MACHINE's FACES ARE NOT HERE AND MUST NOT BE COPIED HERE.**  The
// console is `console_face.h`'s `CONS_REG_BASE` and the disk pack side is
// `pack_side.h`'s `PS_REG_BASE`, and this firmware includes those headers and
// uses those constants --- the same files the Linux programs on the Arty
// Z7-20 include.  That is the whole point of the exercise: one map, one set of
// register definitions, two kinds of processor in front of them.  A second
// copy of `0x8000_0000` in this file would be the beginning of two programs
// and the first place they would drift.
//
// What IS here is the two pages the Zynq has no equivalent of, because on that
// board the console line and the timer are the processing system's own
// hardware and here they are fabric.

#ifndef SOC_H
#define SOC_H

#include <stdint.h>

// ---------------------------------------------------------------- the UART
//
// `rtl/plumbing/cadr_soc_uart.sv`.  The board's USB-UART bridge, 8N1, at the
// rate the fabric was built with.
#define SOC_UART_BASE   0x10000000u
#define SOC_UART_IDENT  0x55415254u	/* "UART" */

enum soc_uart_reg {
	SOC_UART_R_IDENT = 0x00,
	SOC_UART_R_STAT  = 0x04,
	SOC_UART_R_TX    = 0x08,
	SOC_UART_R_RX    = 0x0C
};
enum soc_uart_stat {
	SOC_UART_TX_READY = 1u << 0,
	SOC_UART_RX_VALID = 1u << 1,
	SOC_UART_RX_OVER  = 1u << 2
};
// Bit 8 of the RX word, beside the byte, so that the test and the datum come
// out of one load.
#define SOC_UART_RX_HAS  0x100u

// --------------------------------------------------------------- the timer
//
// `rtl/plumbing/cadr_soc_timer.sv`.  A free-running count of the board's own
// ticks, and the comparator RISC-V calls `mtimecmp`.
#define SOC_TIMER_BASE  0x10001000u
#define SOC_TIMER_IDENT 0x54494D45u	/* "TIME" */

enum soc_timer_reg {
	SOC_TIMER_R_IDENT        = 0x00,
	SOC_TIMER_R_TICKS_PER_US = 0x04,
	SOC_TIMER_R_MTIME_LO     = 0x08,
	SOC_TIMER_R_MTIME_HI     = 0x0C,
	SOC_TIMER_R_MTIMECMP_LO  = 0x10,
	SOC_TIMER_R_MTIMECMP_HI  = 0x14
};

// --- the access layer ----------------------------------------------------
//
// **THIS IS WHAT REPLACES `mmap`.**  The Linux programs reach a face through
// `/dev/mem` and a mapping; a firmware with no operating system reaches it by
// being at the address already.  Everything above that seam --- the register
// numbers, the protocols, the vocabulary --- is the same C.

static inline uint32_t soc_rd(uint32_t a)
{
	return *(volatile uint32_t *)a;
}

static inline void soc_wr(uint32_t a, uint32_t v)
{
	*(volatile uint32_t *)a = v;
}

// One character out, and one in if there is one.  `soc_getc` returns -1 when
// nothing is waiting; it never blocks.
void soc_putc(char c);
int soc_getc(void);

// Ticks since the fabric's reset, as one 64-bit value: the low word is read
// first because that read latches the high one, which is the rule every
// 64-bit counter in this repository is read by.
uint64_t soc_ticks(void);
// How many ticks there are in a real microsecond, read out of the fabric
// rather than written down.  See `cadr_soc_timer.sv`'s header.
uint32_t soc_ticks_per_us(void);
void soc_delay_us(unsigned us);

#endif
