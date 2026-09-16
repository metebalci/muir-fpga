// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console program, held on the build host to a MODEL of the slave: no
// board, no fabric, nothing but a C compiler.
//
//     console_test
//
// **A MODEL AND NOT THE RTL.**  What follows `rtl/plumbing/cadr_console.sv` at this
// slice is the two pages of sixteen words, the latch of each counter's high
// half by the read of its low half, UNMAPPED for an address in neither page,
// the sticky lost bit in STAT and bit 16 of a page-1 read meaning the
// diagnostic cycle was not answered; and behind the diagnostic bus a modeled
// machine whose CYCLES counter advances only while RUN is set.  What it holds
// the program to is the face's CONTRACT, and the RTL is held to the same
// contract by `tb/cadr_console_tb.cpp`.  `feeder_test.c` says the same of
// itself at its lines 51-62 and this is the same seam one program along.
//
// **THE MODELED REGISTER BLOCK DROPS BITS 4:1 OF A CLOCK CONTROL WRITE**,
// because `cadr_spy_registers.sv` does and `cadr_microcycle.sv` has neither
// `SSTEP` nor `SSDONE`.  So `step` cannot move the modeled machine either,
// and the test's job there is to hold that the program SAYS the machine did
// not move rather than returning quietly.
//
// **WHAT IS CHECKED.**  IDENT, and the two other words a wrong board answers
// with.  The EMIO tally guard rejecting all ones and all zeros and taking
// only the marker bits.  `halt` then `status` reporting halted with SRUN
// down; `start` then `status` reporting running, with CYCLES having moved and
// the report saying so because it moved and not because a flag said it would.
// `step` reporting that the machine did not move and why.  The FLAG-1 and
// FLAG-2 decoders against known words, including FLAG-1's low byte through
// its inverting driver and FLAG-2's four floating ones.  The CYCLES/CYCLESH
// order --- that the low read latches the high half, that the pair is one
// instant across a carry, and that reading the high word alone gets a stale
// latch.  All sixteen registers read back as the model holds them, so that a
// register index off by one has nowhere to hide.  And a lost cycle reported
// as lost and never mistaken for data.

#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "console_face.h"
#include "console_host.h"

static int bad;
static unsigned checks;

static void fail(int line, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void fail(int line, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "console_test.c:%d: FAIL: ", line);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++bad;
}

#define CHECK(cond, ...)                                  \
	do {                                              \
		++checks;                                 \
		if (!(cond))                              \
			fail(__LINE__, __VA_ARGS__);      \
	} while (0)

// ---- the model of the slave --------------------------------------------

// A microcycle is 15 ticks at normal speed: 145 ns on MIT's drawings, the
// read tap and the restart each rounded up to MIT's 10 ns grid, which this
// board spends 150 ns of real time on at its 10 ns tick.  The COUNT is what
// the model needs, and it moves with the grid and not with the tick.
#define TICKS_PER_MICROCYCLE 15u
// A diagnostic cycle is DIAGNOSTIC_NS = 250 ns = 25 ticks; the module holds
// the bus for that plus the drop, 260 ns.
#define TICKS_PER_DIAGNOSTIC 26u

struct model {
	// The modeled machine.
	int run;			/* the clock control register's bit 0 */
	uint64_t cycles, ticks;
	uint16_t ir[3], opc, pc, ob[2], m[2], a[2], st[2];
	// Page 0's words 7, 8 and 9, which are not on the diagnostic bus at
	// all.  `q_latch` and `md_latch` are the model of the RTL's own: the
	// read of word 7 takes all three, and words 8 and 9 read what it took.
	uint32_t vma, q, md, q_latch, md_latch;
	struct cons_flag1 f1;
	struct cons_flag2 f2;
	uint16_t mode, opc_control;	/* what the write strobes loaded */
	uint16_t clk_written;		/* the last CLK write AS ASKED, bits and all */
	int sstep, ssdone;		/* STEP registered once and twice, OLORD1 1A10 */
	// The face.
	uint32_t ident;			/* what word 0 answers: a wrong board is a wrong IDENT */
	uint32_t cycles_hi_latch, ticks_hi_latch;
	int answered, lost_ever;
	int grant;			/* 0: nothing answers, every cycle is lost */
	int freeze;			/* the counters stand: for a check that reads them */
	int deaf_to_step;		/* a register block that takes bit 0 and drops the rest */
	int step_is_a_level;		/* STEP taken as a level: the opposite defect */
	// Page 0's word 13, the light panel's button.  `boots` counts the
	// presses as the fabric's saturating counter does; `boot_pressed` is
	// what the last write did, so a test can say whether a wrong key was
	// dropped.  The modeled press does what -BOOT does: it presets RUN,
	// forces the PC to zero and clears PROMDISABLE.
	unsigned boots;
	int boot_pressed;
	int boot_deaf_to_the_key;	/* a fabric that boots on any value */
	// SW0, the no-auto-boot switch: what it did at the last reset and where
	// it is now.  Two bits of STAT, and two rather than one because the
	// fabric reads the switch only at the reset, so a switch moved since
	// then has changed nothing and the pair is what says so.
	int held_at_reset, switch_now;
	// Page 0's word 14, the debug cable's role on Pmod JA.  `asked` is what
	// the console last told the connector and `engaged` is what the
	// connector did about it, and the model keeps them APART so that a
	// check can put them out of step: a board that can see a debugger
	// already on the connector refuses, and that is the one case the two
	// bits exist for.  `connects` counts as the fabric's saturating counter
	// does.
	int dbg_asked, dbg_engaged, dbg_foreign, dbg_active, dbg_live;
	int dbg_peer_far;	/* what arrives is on the pins this board answers on */
	int dbg_wiring;		/* the setting this console holds: auto, straight, crossover */
	int dbg_wire_state;	/* and what the connector made of it */
	unsigned dbg_heard, dbg_refused;   /* the cable's two counts, word 15 */
	unsigned connects;
	int debug_deaf_to_the_key;	/* a fabric that takes any value */
	int debug_frames_unmapped;	/* a fabric older than word 15's counts */
	unsigned long diag_reads, diag_writes;
	// **WHICH BUILD THE FABRIC SAYS IT IS**, page 2's word 32.  On a board
	// a primitive reads the part's AXSS register; here the test sets it,
	// so that a read is a comparison against a value the check chose.
	uint32_t build;
	// **WHICH DISPLAY BOARDS THE BACKPLANE HAS**, page 2's word 33, and
	// the two boards' color maps on pages 4 and 5.  The fabric holds the
	// two bits and the maps; here the test sets them, so that a read is a
	// comparison against a value the check chose.
	int tv_lispm, color_tv;
	int display_deaf_to_the_key;	/* a fabric that takes any value */
	int display_unmarked;		/* a fabric older than word 33 */
	// **AND WHAT THE DISPLAY OUTPUT SHOWS**, page 2's word 34: which
	// screens go to the monitor and which way up, and the mode the
	// bitstream carries, which nothing here can move.
	int hdmi_first, hdmi_color, hdmi_rot, hdmi_mode;
	int hdmi_unmarked;		/* a fabric older than word 34 */
	// **AND WHETHER THE LAMPS BLINK**, page 2's word 35.
	int lamps_steady;
	int lamps_deaf_to_the_key;	/* a fabric that takes any value */
	int lamps_unmarked;		/* a fabric older than word 35 */
	uint8_t map[2][CONS_MAP_COLORS][CONS_MAP_CHANNELS];
};

static void model_advance(struct model *m, uint64_t t)
{
	if (m->freeze)
		return;
	// TICKS runs whether or not the machine does; CYCLES only while RUN.
	m->ticks += t;
	if (m->run)
		m->cycles += t / TICKS_PER_MICROCYCLE;
}

static uint16_t model_spy_read(struct model *m, unsigned eadr)
{
	m->f1.srun = m->run;
	switch (eadr) {
	case SPY_IR_LOW: return m->ir[0];
	case SPY_IR_MED: return m->ir[1];
	case SPY_IR_HIGH: return m->ir[2];
	// No read select is decoded at 3: the floating bus, all ones.
	case SPY_OPEN: return SPY_OPEN_READ;
	case SPY_OPC: return m->opc;
	case SPY_PC: return m->pc;
	case SPY_OB_LOW: return m->ob[0];
	case SPY_OB_HIGH: return m->ob[1];
	case SPY_FLAG_1: return cons_flag1_word(&m->f1);
	case SPY_FLAG_2: return cons_flag2_word(&m->f2);
	case SPY_M_LOW: return m->m[0];
	case SPY_M_HIGH: return m->m[1];
	case SPY_A_LOW: return m->a[0];
	case SPY_A_HIGH: return m->a[1];
	case SPY_STAT_LOW: return m->st[0];
	default: return m->st[1];
	}
}

static void model_spy_write(struct model *m, unsigned eadr, uint16_t v)
{
	// spy::write_strobe: EADR<2:0>, the decoder's G1 being HI1.
	switch (eadr & 7u) {
	case 0: case 1: case 2:
		m->ir[eadr & 3u] = v;	/* the debug IR's three halves */
		break;
	case 3:
		// The clock control register is five bits.  Only RUN and STEP
		// change anything a console can see from here: NOP11, IDEBUG
		// and LDSTAT steer the datapath, which this model does not
		// have, and `build/sstep.pass` is what holds them.
		//
		// **STEP IS AN EDGE AND NOT A LEVEL.**  SSTEP and SSDONE are
		// STEP registered once and twice on MCLK5A, and MACHRUN's
		// first term is SSTEP AND -SSDONE, so the machine runs for
		// exactly the one master clock in which the first is set and
		// the second is not.  Modeling it as a level would let a
		// console that wrote 2 and never wrote 0 look correct here
		// and run away on the board.
		m->clk_written = v;
		m->run = v & CLK_RUN ? 1 : 0;
		if (m->deaf_to_step) {
			/* bits 4:1 reach nothing, which is what this console
			   was written against */
		} else if (m->step_is_a_level) {
			if (v & CLK_STEP) {
				m->cycles += 4;
				m->ssdone = 1;
				m->f1.ssdone = 1;
			}
		} else {
			const int step = v & CLK_STEP ? 1 : 0;
			if (step && !m->sstep && !m->ssdone) {
				// The one microcycle the step buys.  `freeze`
				// holds off the free-running advance so that a
				// check can read the counter; it does not hold
				// off a step, which is the thing being counted.
				++m->cycles;
				m->ssdone = 1;
			}
			m->sstep = step;
			if (!step)
				m->ssdone = 0;
			m->f1.ssdone = m->ssdone;
		}
		break;
	case 4: m->opc_control = v; break;
	case 5: m->mode = v; break;
	default: break;		/* Y6 and Y7 are not connected */
	}
}

static uint32_t model_read(struct console *c, unsigned word)
{
	struct model *m = c->ctx;
	// Time passes over a register read whatever it names.
	model_advance(m, 8);
	// Page 2's word 32, which is the only word of pages 2 and 3 that is a
	// word: everything else up there reads `UNMAPPED`, as an address
	// outside the face does.
	if (word == CONS_BUILD)
		return m->build;
	// Page 2's word 33: the backplane's display boards, with a marker so
	// that a fabric older than the word is not read as a machine with
	// nothing set.
	if (word == CONS_DISPLAY)
		return m->display_unmarked
			   ? 0u
			   : ((uint32_t)CONS_TV_MARK << 16)
				 | (m->color_tv ? CONS_TV_COLOR : 0u)
				 | (m->tv_lispm ? CONS_TV_LISPM : 0u);
	// Page 2's word 34: what the display output shows, with a marker of its
	// own for word 33's reason.
	if (word == CONS_HDMI)
		return m->hdmi_unmarked
			   ? 0u
			   : ((uint32_t)CONS_HDMI_MARK << 16)
				 | ((uint32_t)m->hdmi_mode << CONS_HDMI_MODE_SHIFT)
				 | ((uint32_t)m->hdmi_rot << CONS_HDMI_ROT_SHIFT)
				 | (m->hdmi_color ? CONS_HDMI_COLOR : 0u)
				 | (m->hdmi_first ? CONS_HDMI_FIRST : 0u);
	// Page 2's word 35: whether the lamps blink, marked for word 33's reason.
	if (word == CONS_LAMPS)
		return m->lamps_unmarked
			   ? 0u
			   : ((uint32_t)CONS_LAMP_MARK << 16)
				 | (m->lamps_steady ? CONS_LAMP_STEADY : 0u);
	// Pages 4 and 5: the two color maps, one word a color.
	if (word >= CONS_PAGE4 && word < CONS_PAGE5 + CONS_MAP_COLORS) {
		const int board = word >= CONS_PAGE5;
		const unsigned k = word - (board ? CONS_PAGE5 : CONS_PAGE4);
		return ((uint32_t)m->map[board][k][0] << 16)
		     | ((uint32_t)m->map[board][k][1] << 8)
		     | (uint32_t)m->map[board][k][2];
	}
	if (word >= CONS_PAGE1 + 16u)
		return CONS_UNMAPPED;
	if (word >= CONS_PAGE1) {
		const unsigned eadr = word - CONS_PAGE1;
		++m->diag_reads;
		model_advance(m, TICKS_PER_DIAGNOSTIC);
		if (!m->grant) {
			m->answered = 0;
			m->lost_ever = 1;
			return CONS_LOST_BIT;
		}
		m->answered = 1;
		return model_spy_read(m, eadr);
	}
	switch (word) {
	case CONS_IDENT: return m->ident;
	case CONS_STAT:
		return (m->lost_ever ? CONS_ST_LOST : 0u) | (m->answered ? CONS_ST_ANSWERED : 0u)
		     | (m->grant ? CONS_ST_GNT : 0u)
		     | (m->held_at_reset ? CONS_ST_HELD_AT_RESET : 0u)
		     | (m->switch_now ? CONS_ST_SWITCH_NOW : 0u);
	case CONS_CYCLES:
		// The low half's read latches the high half beside it.
		m->cycles_hi_latch = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case CONS_CYCLESH: return m->cycles_hi_latch;
	case CONS_TICKS:
		m->ticks_hi_latch = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case CONS_TICKSH: return m->ticks_hi_latch;
	// The machine's reset.  This program does not write it; what it reads
	// is the key's own top half as a marker and the count of resets, and
	// the model carries it so that the sweep below can say which page-0
	// words really are UNMAPPED and which are registers.
	case CONS_RESET: return 0x52530000u;
	// **THE READ OF WORD 7 LATCHES Q AND MD BESIDE IT**, exactly as
	// CONS_CYCLES latches CONS_CYCLESH, so the three a program reads name
	// one microcycle of the machine.  Words 8 and 9 do not arm it, or a
	// read of 7 then 8 then 9 would be three instants.
	case CONS_VMA:
		m->q_latch = m->q;
		m->md_latch = m->md;
		return m->vma;
	case CONS_Q: return m->q_latch;
	case CONS_MD: return m->md_latch;
	// The light panel's button: the key's top half as a marker, the
	// presses, and the line itself --- which is always back up by the time
	// a read can happen, the fabric holding the write's answer off for the
	// length of the pulse.
	case CONS_BOOT: return (CONS_BOOT_KEY & 0xFFFF0000u) | ((m->boots & 0xFFu) << 8);
	// The debug cable's role: the key's top half as a marker, the connects
	// (seven bits, the eighth having gone to the crossed-cable bit),
	// and the connector --- what was asked for and what happened.
	case CONS_DEBUG:
		return (CONS_DEBUG_CONNECT_KEY & 0xFFFF0000u) |
		       ((unsigned)(m->connects & 0x7Fu) << 9) |
		       (m->dbg_peer_far ? CONS_DBG_PEER_FAR : 0u) |
		       (((unsigned)m->dbg_wire_state & CONS_DBG_WIRE_MASK)
			<< CONS_DBG_WIRE_SHIFT) |
		       (m->dbg_live ? CONS_DBG_LIVE : 0u) |
		       (m->dbg_active ? CONS_DBG_ACTIVE : 0u) |
		       (m->dbg_foreign ? CONS_DBG_FOREIGN : 0u) |
		       (m->dbg_asked ? CONS_DBG_ASKED : 0u) |
		       (m->dbg_engaged ? CONS_DBG_ENGAGED : 0u);
	// The cable's two counts, and a marker of one byte: twenty-four bits of
	// count leave eight, and `0x44` is neither `0x00` nor `0xFF`.
	case CONS_DEBUG_FRAMES:
		if (m->debug_frames_unmapped) return CONS_UNMAPPED;
		return ((uint32_t)CONS_DEBUG_FRAMES_MARK << 24) |
		       ((m->dbg_heard & 0xFFFFu) << 8) | (m->dbg_refused & 0xFFu);
	default: return CONS_UNMAPPED;	/* words 10-12 */
	}
}

static void model_write(struct console *c, unsigned word, uint32_t v)
{
	struct model *m = c->ctx;
	model_advance(m, 8);
	// Page 0's word 13 is written and the rest of the page is not.  The
	// key is what makes it a press: a value that means nothing --- zero off
	// a dead bus, all ones off an undriven one --- must not stop a machine.
	if (word == CONS_BOOT) {
		m->boot_pressed = (v == CONS_BOOT_KEY) || m->boot_deaf_to_the_key;
		if (!m->boot_pressed)
			return;
		if (m->boots != 0xFFu)
			++m->boots;
		// What `-BOOT` does: RUN preset, the boot trap forcing the PC
		// to zero, and the mode register cleared with PROMDISABLE in
		// it.  Not memory, not the control store, not the scratchpads.
		m->run = 1;
		m->f1.srun = 1;
		m->pc = 0;
		m->mode = 0;
		m->f1.promdisable = 0;
		return;
	}
	// Page 2's word 33, the backplane's display boards.  Three keys, and
	// the color board's two are a value and its complement.
	if (word == CONS_DISPLAY) {
		if (v == CONS_TV_SIMPLE_KEY)
			m->tv_lispm = 0;
		else if (v == CONS_TV_LISPM_KEY)
			m->tv_lispm = 1;
		else if (v == CONS_COLOR_TV_KEY)
			m->color_tv = 1;
		else if (v == CONS_NO_COLOR_TV_KEY)
			m->color_tv = 0;
		else if (m->display_deaf_to_the_key)
			m->color_tv = 1;
		return;
	}
	// Page 2's word 34, what the display output shows.  Six keys, three for
	// the screens and three for the rotation, and each leaves the other
	// alone.
	if (word == CONS_HDMI) {
		if (v == CONS_HDMI_TV_KEY)         { m->hdmi_first = 1; m->hdmi_color = 0; }
		else if (v == CONS_HDMI_COLOR_KEY) { m->hdmi_first = 0; m->hdmi_color = 1; }
		else if (v == CONS_HDMI_BOTH_KEY)  { m->hdmi_first = 1; m->hdmi_color = 1; }
		else if (v == CONS_HDMI_UP_KEY)    m->hdmi_rot = CONS_HDMI_UPRIGHT;
		else if (v == CONS_HDMI_CW_KEY)    m->hdmi_rot = CONS_HDMI_CW;
		else if (v == CONS_HDMI_CCW_KEY)   m->hdmi_rot = CONS_HDMI_CCW;
		return;
	}
	// Page 2's word 35, whether the lamps blink: the key and its complement.
	if (word == CONS_LAMPS) {
		if (v == CONS_LAMP_STEADY_KEY)
			m->lamps_steady = 1;
		else if (v == CONS_LAMP_BLINK_KEY)
			m->lamps_steady = 0;
		else if (m->lamps_deaf_to_the_key)
			m->lamps_steady = 1;
		return;
	}
	// Page 0's word 14, the debug cable's role.  Two keys and nothing else,
	// and the second is the first complemented, so no partial write of
	// either can be the other.  **THE ROLE IS NOT THE ASK**: the connector
	// takes it only where nothing else has it, which is what `dbg_foreign`
	// stands for here.
	if (word == CONS_DEBUG) {
		if (v == CONS_DEBUG_CONNECT_KEY || m->debug_deaf_to_the_key) {
			m->dbg_asked = 1;
			if (m->connects != 0xFFu)
				++m->connects;
			if (!m->dbg_foreign)
				m->dbg_engaged = 1;
		} else if (v == CONS_DEBUG_DISCONNECT_KEY) {
			m->dbg_asked = 0;
			m->dbg_engaged = 0;
			m->dbg_live = 0;
			m->dbg_wire_state = m->dbg_wiring;
		} else if (v == CONS_DEBUG_WIRE_AUTO_KEY ||
			   v == CONS_DEBUG_WIRE_STRAIGHT_KEY ||
			   v == CONS_DEBUG_WIRE_CROSSOVER_KEY) {
			// **AND THE SETTING IS REFUSED WHILE THIS BOARD IS THE
			// DEBUGGER**, because the wiring decides which four pins
			// it drives and moving them inside a session would take
			// the pins out from under a standing cycle.
			if (!m->dbg_engaged) {
				m->dbg_wiring = (v == CONS_DEBUG_WIRE_STRAIGHT_KEY)
						    ? CONS_DBG_WIRE_STRAIGHT
						: (v == CONS_DEBUG_WIRE_CROSSOVER_KEY)
						    ? CONS_DBG_WIRE_CROSSOVER
						    : CONS_DBG_WIRE_AUTO_IDLE;
				m->dbg_wire_state = m->dbg_wiring;
			}
		}
		return;
	}
	if (word >= 32 || word < CONS_PAGE1)
		return;			/* the rest of page 0 is read-only */
	++m->diag_writes;
	model_advance(m, TICKS_PER_DIAGNOSTIC);
	if (!m->grant) {
		m->answered = 0;
		m->lost_ever = 1;
		return;
	}
	m->answered = 1;
	model_spy_write(m, word - CONS_PAGE1, (uint16_t)v);
}

// The wall clock, modeled: a real microsecond of waiting is that many ticks
// of the fabric.  `CONS_TICKS_PER_US` rather than a literal, so this and the
// program's own printing cannot come apart --- 100 at the 10 ns tick, 200
// while it was 5 ns.
static void model_pause(struct console *c, unsigned us)
{
	model_advance(c->ctx, (uint64_t)us * CONS_TICKS_PER_US);
}

static void attach(struct console *c, struct model *m)
{
	cons_init(c);
	c->read = model_read;
	c->write = model_write;
	c->pause = model_pause;
	c->ctx = m;
}

static void model_init(struct model *m)
{
	memset(m, 0, sizeof *m);
	m->ident = CONS_IDENT_WORD;
	m->grant = 1;
	// Sixteen distinct words, so that a register index off by one lands on
	// a word it cannot be mistaken for.  Registers 3, 8 and 9 are the
	// board's own and are not settable here.
	m->ir[0] = 0x1111; m->ir[1] = 0x2222; m->ir[2] = 0x3333;
	m->opc = 0x0444; m->pc = 0x0555;
	m->ob[0] = 0x6666; m->ob[1] = 0x7777;
	m->m[0] = 0xAAAA; m->m[1] = 0xBBBB;
	m->a[0] = 0xCCCC; m->a[1] = 0xDDDD;
	m->st[0] = 0xEEEE; m->st[1] = 0xFFF0;
	// A virtual address and a `Q` that are neither equal nor the same
	// page, so that the pair is evidence from the start: page 0o2467 and
	// page 0o1234, which differ in more than their low eight bits.  The
	// low byte differs too, so a word taken for a page or a page for a
	// word cannot read right by accident.
	m->vma = 0x00152735u;		/* page 0x1527 = 0o12447 */
	m->q = 0x00129C42u;		/* page 0x129C = 0o11234 */
	// A word that shares no page with either, so that a crossing shows.
	m->md = 0x0038B10Fu;		/* page 0x38B1 = 0o34261 */
	// Which build the fabric says it is: commit `c0ffee2` with a tree that
	// had a modified file.  Not a commit of this repository, so a check
	// that reads it back knows it is reading the model; not `0xFFFFFFFF`,
	// which is the value the stamp's format reserves for a bitstream that
	// names no build at all.
	m->build = 0xC0FFEE21u;
	// A backplane with one SIMPLE TV and no color board, which is muir's
	// own default and what every reference trace was taken on.  The two
	// maps are filled with values injective in the board, the color and
	// the channel, so that a read of the wrong word cannot come back
	// right --- and none of them is zero, which is what a fabric keeping
	// nothing would answer with.
	m->tv_lispm = 0;
	m->color_tv = 0;
	// A board comes up showing the first display, upright, and this model
	// is a bitstream built for the middle mode --- which is not the
	// fabric's default, so that a program printing "1280x1024" from a
	// constant rather than from the word would be caught.
	m->hdmi_first = 1;
	m->hdmi_color = 0;
	m->hdmi_rot = CONS_HDMI_UPRIGHT;
	m->hdmi_mode = CONS_HDMI_1400;
	m->hdmi_unmarked = 0;
	// And the lamps blink, which is what every board comes up with.
	m->lamps_steady = 0;
	m->lamps_deaf_to_the_key = 0;
	m->lamps_unmarked = 0;
	for (int b = 0; b < 2; ++b)
		for (int k = 0; k < CONS_MAP_COLORS; ++k)
			for (int ch = 0; ch < CONS_MAP_CHANNELS; ++ch)
				m->map[b][k][ch] =
					(uint8_t)(1u + (unsigned)(b * 61 + k * 7 + ch * 29) % 250u);
	m->q_latch = 0;
	m->md_latch = 0;
}

// ---- capturing what the program says ------------------------------------

static char *cap_buf;
static size_t cap_len;
static FILE *cap;

static void capture_start(void)
{
	if (cap)
		fclose(cap);
	free(cap_buf);
	cap_buf = NULL;
	cap_len = 0;
	cap = open_memstream(&cap_buf, &cap_len);
	cadr_log_init("cadr-console: ", cap);
}

static const char *capture_end(void)
{
	fflush(cap);
	return cap_buf ? cap_buf : "";
}

// ---- the checks ---------------------------------------------------------

static void check_ident(void)
{
	struct model m;
	struct console c;
	uint32_t got = 0;
	model_init(&m);
	attach(&c, &m);
	CHECK(cons_ident_ok(&c, &got) == 0 && got == CONS_IDENT_WORD,
	      "IDENT reads 0x%08x, wanting 0x%08x (\"CONS\")", got, CONS_IDENT_WORD);

	// The proving boards' default slave, and this module's own UNMAPPED:
	// two wrong boards that must not read as a console.
	m.ident = CADR_IDENT_NONE;
	CHECK(cons_ident_ok(&c, &got) == -1 && got == CADR_IDENT_NONE,
	      "\"NONE\" is taken for a console");
	m.ident = CONS_UNMAPPED;
	CHECK(cons_ident_ok(&c, &got) == -1 && got == CONS_UNMAPPED,
	      "UNMAPPED is taken for a console");
	m.ident = 0;
	CHECK(cons_ident_ok(&c, &got) == -1, "a bus reading zeros is taken for a console");
	m.ident = 0xFFFFFFFFu;
	CHECK(cons_ident_ok(&c, &got) == -1, "a bus reading ones is taken for a console");
	m.ident = CONS_IDENT_WORD;

	// The ten words of page 0 that name nothing, and an address past the
	// window: UNMAPPED, which is neither zero nor all ones.
	CHECK(CONS_UNMAPPED == ~CONS_IDENT_WORD, "UNMAPPED is not the complement of IDENT");
	CHECK(CONS_UNMAPPED != 0 && CONS_UNMAPPED != 0xFFFFFFFFu,
	      "UNMAPPED is a value a dead or undriven bus could produce");
	// 6 is the machine's reset, 7, 8 and 9 are VMA, Q and MD, 13 is the
	// light panel's button, 14 is the debug cable's role and 15 its two
	// frame counts: registers, each of which must read as something a dead
	// bus could not produce.
	//
	// **10, 11 and 12 ARE THE READOUT AND THIS MODEL DOES NOT CARRY
	// THEM**, so they read UNMAPPED here and are registers on the fabric.
	// `build/readout.pass` is what holds them; said out loud rather than
	// left as a gap, because a sweep that called a register unmapped and
	// was believed would be this file agreeing with itself.
	CHECK(c.read(&c, CONS_DEBUG_FRAMES) != CONS_UNMAPPED,
	      "page 0 word 15 reads UNMAPPED, and it is the cable's two counts");
	CHECK((c.read(&c, CONS_DEBUG_FRAMES) >> 24) == CONS_DEBUG_FRAMES_MARK,
	      "word 15 does not carry its marker byte");
	CHECK(c.read(&c, CONS_DEBUG) != CONS_UNMAPPED,
	      "page 0 word 14 reads UNMAPPED, and it is the debug cable's role");
	CHECK((c.read(&c, CONS_DEBUG) & 0xFFFF0000u) ==
		      (CONS_DEBUG_CONNECT_KEY & 0xFFFF0000u),
	      "word 14 does not carry the key's own top half as a marker");
	for (unsigned k = 6; k < 10; ++k)
		CHECK(c.read(&c, k) != CONS_UNMAPPED,
		      "page 0 word %u reads UNMAPPED, and it is a register", k);
	CHECK(c.read(&c, CONS_BOOT) != CONS_UNMAPPED,
	      "page 0 word 13 reads UNMAPPED, and it is the light panel's button");
	CHECK((c.read(&c, CONS_BOOT) & 0xFFFF0000u) == (CONS_BOOT_KEY & 0xFFFF0000u),
	      "word 13 does not carry the key's own top half as a marker");
	CHECK(c.read(&c, 40) == CONS_UNMAPPED, "an address past the window is not UNMAPPED");
	CHECK(c.read(&c, CONS_BUILD) != CONS_UNMAPPED,
	      "page 2 word 32 reads UNMAPPED, and it is which build the fabric is");
}

// The guard, on words already in hand, so that no /dev/mem is needed.  The
// two readings the negative control on the board measured must both be
// refused, and the test must be the marker pattern and not "not zero".
static void check_guard(void)
{
	CHECK(cadr_tally_ok(0xFFFFFFFFu, 0xFFFFFFFFu) == 0,
	      "all ones passes the guard: an undriven EMIO pin reads exactly like four saturated counters");
	CHECK(cadr_tally_ok(0x00000000u, 0x00000000u) == 0,
	      "all zeros passes the guard: the level shifters off read the same as a dead instrument");
	CHECK(cadr_tally_ok(0x01008100u, 0x01008100u) == 1,
	      "the marker bits of a passing run are refused");
	// A tally with SOME top bit set is not a tally: only the pattern is.
	CHECK(cadr_tally_ok(0x81008100u, 0x01008100u) == 0, "bit 31 set passes the guard");
	CHECK(cadr_tally_ok(0x01008100u, 0x01000100u) == 0, "a half with bit 15 clear passes the guard");
	CHECK(cadr_tally_ok(0x0100FFFFu, 0x01008100u) == 1, "a full low field is refused");
	CHECK(CADR_TALLY_MARK == 0x00008000u && CADR_TALLY_MASK == 0x80008000u,
	      "the marker pattern has moved from what rtl/plumbing/cadr_mem_count.sv writes");
}

static void check_halt_and_start(void)
{
	struct model m;
	struct console c;
	struct cons_status st;
	model_init(&m);
	attach(&c, &m);

	// Running first, so that the halt is a change and not the start state.
	cons_start(&c);
	CHECK(m.run == 1, "start did not set RUN");
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a running machine");
	CHECK(st.running, "a machine with RUN set and CYCLES moving is not reported running");
	CHECK(st.cycles_second > st.cycles_first,
	      "CYCLES did not move over the settle: %llu then %llu",
	      (unsigned long long)st.cycles_first, (unsigned long long)st.cycles_second);
	CHECK(st.f1.srun, "FLAG-1 bit 8 is down on a running machine");
	CHECK(st.why == NULL, "a running machine was given a reason for being stopped: %s", st.why ? st.why : "");
	cons_say_status(&st);
	CHECK(strstr(capture_end(), "RUNNING") != NULL, "status did not say RUNNING");

	// CC's first act on a debuggee: 0 into the clock control register.
	cons_halt(&c);
	CHECK(m.run == 0, "halt did not clear RUN");
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a halted machine");
	CHECK(!st.running, "a machine with RUN clear is reported running");
	CHECK(st.cycles_second == st.cycles_first,
	      "CYCLES moved on a halted machine: Machine::cycles does not advance on a halted master clock");
	CHECK(!st.f1.srun, "FLAG-1 bit 8 is up on a halted machine");
	CHECK(st.why && strstr(st.why, "SRUN is down") != NULL,
	      "the halt was not attributed to the console: %s", st.why ? st.why : "(nothing)");
	cons_say_status(&st);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "NOT RUNNING") != NULL, "status did not say NOT RUNNING");
		CHECK(strstr(out, "SRUN down") != NULL, "status did not print SRUN down");
	}

	// **A MACHINE THAT STOPPED ITSELF**: RUN still set and the counter
	// standing, which is MACHRUN low under a set RUN --- what `HALT-CONS`
	// does, MIT's `(si:%halt)`.  muir's `machrun_low` tells this from the
	// console's halt and so must this.
	m.run = 1;
	m.freeze = 1;			/* MACHRUN is low: no microcycle retires */
	m.f1.err = 1;
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a self-halted machine");
	CHECK(!st.running, "a machine whose CYCLES stands is reported running");
	CHECK(st.f1.srun && st.f1.err, "FLAG-1 does not carry SRUN up with ERR up");
	CHECK(st.why && strstr(st.why, "HALT-CONS") != NULL,
	      "a self-halt was not told from the console's halt: %s", st.why ? st.why : "(nothing)");
	CHECK(strstr(st.why, "ERRSTOP itself cannot be read back") != NULL,
	      "status claimed to know ERRSTOP, which is write-only");
	cons_say_status(&st);
	CHECK(strstr(capture_end(), "SRUN up") != NULL, "status did not print SRUN up on a self-halt");

	// The statistics halt, the other self-halt, and the bus wait, which is
	// neither: a machine comes out of a bus wait by itself.
	m.f1.err = 0;
	m.f1.stathalt = 1;
	cons_status(&c, 0, &st);
	CHECK(st.why && strstr(st.why, "statistics counter") != NULL,
	      "the statistics halt was not named: %s", st.why ? st.why : "(nothing)");
	m.f1.stathalt = 0;
	m.f1.wait = 1;
	cons_status(&c, 0, &st);
	CHECK(st.why && strstr(st.why, "-WAIT") != NULL,
	      "a bus wait was not named: %s", st.why ? st.why : "(nothing)");
	CHECK(strstr(st.why, "transient") != NULL, "a bus wait was reported as a halt");
	m.f1.wait = 0;
	m.freeze = 0;

	// And the decode itself, which is what the reason turns on.
	{
		struct cons_flag1 f = { 0 };
		f.srun = 1;
		f.err = 1;
		const uint16_t w = cons_flag1_word(&f);
		const struct cons_flag1 back = cons_flag1_of(w);
		CHECK(back.srun && back.err && !back.stathalt && !back.wait,
		      "SRUN up with ERR up did not survive FLAG-1's polarities: 0x%04x", w);
	}
}

static void check_step(void)
{
	struct model m;
	struct console c;
	struct cons_step s;
	model_init(&m);
	attach(&c, &m);
	cons_halt(&c);

	m.diag_writes = 0;
	m.freeze = 1;		/* only the step may move the counter */
	capture_start();
	cons_step(&c, 3, &s);
	cons_say_step(&s);
	const char *out = capture_end();

	CHECK(s.asked == 3, "step did not ask for three");
	// **ONE MICROCYCLE A STEP, AND EXACTLY ONE.**  MIT's own words for the
	// bit are "raising step clocks the machine once".  Nothing moving is
	// the fabric this console was written against, where the clock control
	// register took bit 0 and dropped the rest; more than one a step is
	// STEP taken as a level, which runs the machine away under a debugger.
	CHECK(s.moved == 3, "three steps retired %llu microcycle(s), not three",
	      (unsigned long long)s.moved);
	CHECK(s.after == s.before + 3, "CYCLES was not sampled either side of the step");
	// The write went out as CC's CC-CLOCK writes it, and the register
	// block took the whole of it.
	CHECK(m.diag_writes == 6, "three steps are six diagnostic writes, not %lu", m.diag_writes);
	CHECK(m.diag_reads == 1, "the one FLAG-1 read is not %lu", m.diag_reads);
	CHECK(m.clk_written == 0, "the last clock control write was 0x%04x, not the 0 of `2 then 0`", m.clk_written);
	CHECK(m.run == 0, "the step left the machine running");
	// SSDONE is read while STEP is still up, where it must be set: it
	// falls two master clocks after the bit is lowered, so reading it
	// afterwards would report a fault that is the console's own ordering.
	CHECK(s.ssdone, "SSDONE is down after a step that moved the machine");
	// **AND IT MUST SAY WHAT HAPPENED.**  A silent no-op is the failure
	// this project keeps meeting, so the count is always printed.
	CHECK(strstr(out, "CYCLES") != NULL, "step did not report CYCLES either side");
	CHECK(strstr(out, "SSDONE up") != NULL, "step did not report SSDONE");
	CHECK(strstr(out, "THE MACHINE DID NOT MOVE") == NULL,
	      "step reported that the machine did not move, and it did");

	// **A STEP THAT CLOCKS NOTHING MUST BE NAMED.**  The fabric this
	// console was written against did exactly that, so the words are held
	// as well as the number: a register block that takes bit 0 and drops
	// the rest is modeled by refusing STEP.
	struct model dead;
	struct console dc;
	model_init(&dead);
	attach(&dc, &dead);
	cons_halt(&dc);
	dead.freeze = 1;
	dead.deaf_to_step = 1;
	capture_start();
	cons_step(&dc, 1, &s);
	cons_say_step(&s);
	out = capture_end();
	CHECK(s.moved == 0, "the deaf model moved %llu microcycle(s)",
	      (unsigned long long)s.moved);
	CHECK(strstr(out, "THE MACHINE DID NOT MOVE") != NULL,
	      "a step that clocked nothing was not reported as such");
	CHECK(strstr(out, "SSTEP") != NULL, "step did not name SSTEP as the missing thing");

	// **AND SO MUST A STEP THAT CLOCKS TOO MANY.**  STEP taken as a level
	// rather than as an edge is the opposite failure and is just as silent.
	struct model loose;
	struct console lc;
	model_init(&loose);
	attach(&lc, &loose);
	cons_halt(&lc);
	loose.freeze = 1;
	loose.step_is_a_level = 1;
	capture_start();
	cons_step(&lc, 1, &s);
	cons_say_step(&s);
	out = capture_end();
	CHECK(s.moved > 1, "the level model retired %llu microcycle(s), not more than one",
	      (unsigned long long)s.moved);
	CHECK(strstr(out, "MICROCYCLES FOR") != NULL,
	      "a step that ran away was not reported as such");

	// A step on a RUNNING machine moves the counter for the ordinary
	// reason and must not be reported as a step having worked.
	cons_start(&c);
	cons_step(&c, 1, &s);
	CHECK(m.run == 0, "`2 then 0` left RUN set: the second write is what clears it");
}

static void check_flags(void)
{
	// FLAG-1, all clear in the logical sense.  The four active-low bits of
	// the high byte read as ones and the low byte reads as zeros, the
	// driver being inverting.
	// A quiet machine: the four active-low bits of the high byte read as
	// ones (bits 15, 14, 13 and 11) and everything else reads as zero.
	#define QUIET1 0xE800u
	struct cons_flag1 f = { 0 };
	uint16_t w = cons_flag1_word(&f);
	CHECK(w == QUIET1, "a quiet FLAG-1 reads 0x%04x, wanting 0x%04x "
	      "(-WAIT, -V1PE, -V0PE and -STATHALT high, everything else low)", w, QUIET1);

	// A machine running with no error: SRUN up.
	f.srun = 1;
	w = cons_flag1_word(&f);
	CHECK(w == (QUIET1 | 0x0100u), "running with no error reads 0x%04x, wanting 0x%04x", w, QUIET1 | 0x0100u);
	CHECK(cons_flag1_of(w).srun, "bit 8 is not SRUN");
	CHECK(!cons_flag1_of(QUIET1).srun, "SRUN is up in a word with bit 8 clear");
	// Bit 9 is SSDONE and bit 8 is SRUN, and neither is the other.
	CHECK(cons_flag1_of(QUIET1 | 0x0200u).ssdone && !cons_flag1_of(QUIET1 | 0x0200u).srun,
	      "bit 9 is read as SRUN");
	CHECK(cons_flag1_of(QUIET1 | 0x0100u).srun && !cons_flag1_of(QUIET1 | 0x0100u).ssdone,
	      "bit 8 is read as SSDONE");

	// **THE LOW BYTE THROUGH ITS INVERTING DRIVER.**  All ones there is
	// every parity error at once; all zeros is a quiet machine.  Reading
	// that byte upside down is the mistake CC's own comment warns of.
	{
		const struct cons_flag1 hot = cons_flag1_of(QUIET1 | 0x00FFu);
		CHECK(hot.ape && hot.mpe && hot.pdlpe && hot.spe && hot.dpe && hot.ipe && hot.mempe && hot.higherr,
		      "a low byte of ones is not eight errors");
		const struct cons_flag1 cold = cons_flag1_of(QUIET1);
		CHECK(!cold.ape && !cold.mpe && !cold.pdlpe && !cold.spe && !cold.dpe && !cold.ipe
		      && !cold.mempe && !cold.higherr, "a low byte of zeros is read as errors");
		// bit 0 is A-memory parity and bit 7 is HIGH-ERR, in CC's order.
		CHECK(cons_flag1_of(QUIET1 | 1u).ape && !cons_flag1_of(QUIET1 | 1u).higherr, "bit 0 is not -APE");
		CHECK(cons_flag1_of(QUIET1 | 0x80u).higherr && !cons_flag1_of(QUIET1 | 0x80u).ape, "bit 7 is not -HIGHERR");
	}
	// The four active-low bits of the high byte: a ZERO is the condition.
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 15)).wait && !cons_flag1_of(QUIET1).wait, "bit 15 is not -WAIT");
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 11)).stathalt && !cons_flag1_of(QUIET1).stathalt,
	      "bit 11 is not -STATHALT");
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 14)).v1pe && !cons_flag1_of(QUIET1).v1pe, "bit 14 is not -V1PE");
	CHECK(cons_flag1_of(QUIET1 & ~(1u << 13)).v0pe && !cons_flag1_of(QUIET1).v0pe, "bit 13 is not -V0PE");
	CHECK(cons_flag1_of(QUIET1 | (1u << 12)).promdisable && !cons_flag1_of(QUIET1).promdisable,
	      "bit 12 is not PROMDISABLE");
	CHECK(cons_flag1_of(QUIET1 | (1u << 10)).err && !cons_flag1_of(QUIET1).err, "bit 10 is not ERR");
	#undef QUIET1

	// FLAG-2.  **BITS 15, 14, 7 AND 6 ARE FOUR FLOATING TTL INPUTS AND
	// READ AS ONES**; reading them as zeros is the natural assumption and
	// is wrong.  A quiet FLAG-2 is therefore 0xC0C8, the 8 being -VMAOK
	// high for an access that was not permitted.
	{
		struct cons_flag2 g = { 0 };
		uint16_t v = cons_flag2_word(&g);
		CHECK((v & CONS_FLAG2_OPEN) == CONS_FLAG2_OPEN,
		      "FLAG-2 0x%04x does not carry the four floating ones", v);
		CHECK(v == 0xC0C8u, "a quiet FLAG-2 reads 0x%04x, wanting 0xC0C8", v);
		g.vmaok = 1;
		v = cons_flag2_word(&g);
		CHECK(v == 0xC0C0u, "a permitted access reads 0x%04x, wanting 0xC0C0 --- -VMAOK is LOW when it is permitted", v);
		CHECK(cons_flag2_of(0xC0C0u).vmaok, "-VMAOK low is read as not permitted");
		CHECK(!cons_flag2_of(0xC0C8u).vmaok, "-VMAOK high is read as permitted");
		const struct cons_flag2 all = cons_flag2_of(0xFFFFu);
		CHECK(all.wmapd && all.destspcd && all.iwrited && all.imodd && all.pdlwrited && all.spushd
		      && all.ir48 && all.nop && all.jcond && all.pcs1 && all.pcs0 && !all.vmaok,
		      "a FLAG-2 of all ones does not set every field");
		CHECK(cons_flag2_of(0xC0C1u).pcs0 && !cons_flag2_of(0xC0C1u).pcs1, "bit 0 is not PCS0");
		CHECK(cons_flag2_of(0xC0C2u).pcs1 && !cons_flag2_of(0xC0C2u).pcs0, "bit 1 is not PCS1");
		CHECK(cons_flag2_of(0xC0C0u).wmapd == 0, "bit 13 is read as set in a word that has it clear");
		CHECK(cons_flag2_of(0xC0C0u | (1u << 13)).wmapd, "bit 13 is not WMAPD");
	}
}

// The two counters, and the rule that makes them one instant.
static void check_counters(void)
{
	struct model m;
	struct console c;
	model_init(&m);
	attach(&c, &m);
	m.run = 0;
	m.freeze = 1;			/* nothing may move under the test, its own reads included */

	// Distinct halves, so that a swap is visible.
	m.cycles = 0x0000000700000009ull;
	m.ticks = 0x0000000A0000000Bull;
	// Read once into a variable: a second call to report the first one's
	// answer would find the latch populated and print a word the failing
	// call never saw.
	const uint64_t cy = cons_cycles(&c), ti = cons_ticks(&c);
	CHECK(cy == 0x0000000700000009ull,
	      "the FIRST read of CYCLES gave 0x%016llx, wanting 0x0000000700000009 --- the halves are swapped, "
	      "or the high half was read before the low one that latches it", (unsigned long long)cy);
	CHECK(ti == 0x0000000A0000000Bull,
	      "the first read of TICKS gave 0x%016llx, wanting 0x0000000A0000000B", (unsigned long long)ti);

	// **THE LOW READ LATCHES THE HIGH HALF**: read the pair, move the
	// counter, and the high word alone still answers the latch.
	CHECK(cons_cycles(&c) == 0x0000000700000009ull, "the pair changed under a still machine");
	m.cycles = 0x000000080000000Bull;
	CHECK(c.read(&c, CONS_CYCLESH) == 7,
	      "the high word alone gave 0x%08x: it is a LATCH, and a program that reads it without the low "
	      "word first gets whatever the last low read latched", c.read(&c, CONS_CYCLESH));
	CHECK(cons_cycles(&c) == 0x000000080000000Bull, "the low read did not re-latch the high half");

	// And the carry the rule exists for.  A reader that took the high half
	// first would pair a high word from before the carry with a low word
	// from after it and name a time 4,294,967,296 microcycles away.
	m.cycles = 0x00000007FFFFFFFFull;
	CHECK(cons_cycles(&c) == 0x00000007FFFFFFFFull, "the pair just below the carry is wrong");
	const uint32_t hi_first = c.read(&c, CONS_CYCLESH);	/* 7, and right at this instant */
	m.cycles = 0x0000000800000000ull;			/* the carry lands */
	const uint32_t lo_after = c.read(&c, CONS_CYCLES);
	const uint64_t wrong = (uint64_t)hi_first << 32 | lo_after;
	CHECK(wrong != m.cycles, "the wrong order happened to be right, so this check proves nothing");
	CHECK(cons_cycles(&c) == 0x0000000800000000ull, "the right order did not give the right pair");
}

// All sixteen registers, so that an index off by one lands somewhere it can
// be seen.
static void check_regs(void)
{
	struct model m;
	struct console c;
	struct cons_regs r;
	model_init(&m);
	attach(&c, &m);
	m.run = 0;
	m.freeze = 1;
	cons_read_regs(&c, &r);
	CHECK(r.lost == 0, "a register's cycle was lost with the grant up: 0x%04x", r.lost);

	const uint16_t want[16] = {
		0x1111, 0x2222, 0x3333, SPY_OPEN_READ,
		0x0444, 0x0555, 0x6666, 0x7777,
		cons_flag1_word(&m.f1), cons_flag2_word(&m.f2),
		0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD, 0xEEEE, 0xFFF0
	};
	for (unsigned k = 0; k < 16; ++k)
		CHECK(r.v[k] == want[k], "register %u (%s) read 0x%04x, the model holds 0x%04x",
		      k, cons_reg_name(k), r.v[k], want[k]);
	// Register 3 is the open bus and not a register: no read select is
	// decoded there, so the bus interface's 8304s read all ones.
	CHECK(r.v[SPY_OPEN] == 0xFFFFu, "register 3 is not the open bus");
	// And the one read the vocabulary makes by name lands on the same word.
	{
		uint16_t pc = 0;
		CHECK(cons_spy_read(&c, SPY_PC, &pc) == 0 && pc == 0x0555,
		      "SPY_PC read 0x%04x, the model holds 0x0555", pc);
	}
	// A write goes to the strobe muir's write_strobe names, and 8..15
	// alias onto 0..7 because EADR3 does not reach the write decoder.
	cons_spy_write(&c, SPY_MODE, MODE_ERRSTOP | MODE_PROMDISABLE);
	CHECK(m.mode == (MODE_ERRSTOP | MODE_PROMDISABLE), "the mode register took 0x%04x", m.mode);
	cons_spy_write(&c, SPY_MODE + 8, MODE_TRAPENB);
	CHECK(m.mode == MODE_TRAPENB, "EADR 13 did not alias onto the mode register's strobe");
}

// A diagnostic cycle nothing answered.  Bit 16 is the whole of the answer and
// there is no data under it.
static void check_lost(void)
{
	struct model m;
	struct console c;
	struct cons_regs r;
	struct cons_status st;
	uint16_t v = 0x5A5A;
	model_init(&m);
	attach(&c, &m);
	m.grant = 0;			/* the grant never comes */

	CHECK((c.read(&c, CONS_SPY_WORD(SPY_PC)) & CONS_LOST_BIT) != 0,
	      "the model did not set bit 16 on a cycle nothing answered");
	CHECK(cons_spy_read(&c, SPY_PC, &v) == -1, "a lost cycle was reported as data");
	CHECK(v == 0x5A5A, "a lost cycle overwrote the caller's word with 0x%04x --- there is no data under bit 16", v);
	CHECK(c.lost == 1, "the lost cycle was not counted: %lu", c.lost);
	CHECK((cons_stat(&c) & CONS_ST_LOST) != 0, "STAT's sticky lost bit is down after a lost cycle");

	cons_read_regs(&c, &r);
	CHECK(r.lost == 0xFFFFu, "all sixteen cycles were lost and the mask says 0x%04x", r.lost);
	for (unsigned k = 0; k < 16; ++k)
		CHECK(r.v[k] == 0, "register %u carries 0x%04x after a lost cycle: a lost cycle is not a zero",
		      k, r.v[k]);

	capture_start();
	CHECK(cons_status(&c, 100, &st) == -1, "status on a machine nothing answers did not fail");
	CHECK(st.lost, "status did not mark the reading lost");
	CHECK(st.why && strstr(st.why, "not answered") != NULL,
	      "status did not say the cycle was not answered: %s", st.why ? st.why : "(nothing)");
	cons_say_status(&st);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "not answered") != NULL, "status printed nothing about the lost cycle");
		CHECK(strstr(out, "RUNNING") == NULL,
		      "status called a machine nothing answered running or not running; it knows neither");
	}

	// And the guard against the other mistake: a program that masked bit
	// 16 away would read FLAG-1 as zero, whose decode is a machine that is
	// halted, waiting, and reporting a level-2 map parity error.  Nothing
	// may reach that decode from a lost cycle.
	{
		const struct cons_flag1 f = cons_flag1_of(0);
		CHECK(f.wait && f.v1pe && f.v0pe && f.stathalt && !f.srun,
		      "a FLAG-1 of zero does not decode as the alarming word it is");
	}
}

// --- the virtual address register, Q and MD, page 0's words 7, 8 and 9 ---
//
// **THE SET IS THE WHOLE POINT AND THE LATCH IS WHAT MAKES IT A SET.**  The
// read of word 7 takes Q and MD beside it, so what a program compares is one
// microcycle of the machine; a word 8 or word 9 read on its own is the last
// read of word 7's value and must be, or they would be separate instants and
// the difference between them could be the gap rather than the machine.
static void check_machine_words(void)
{
	struct model m;
	struct console c;
	struct cons_machine_words v;
	model_init(&m);
	attach(&c, &m);

	cons_read_machine_words(&c, &v);
	CHECK(v.vma == m.vma, "VMA reads 0x%08x, the model holds 0x%08x", v.vma, m.vma);
	CHECK(v.q == m.q, "Q reads 0x%08x, the model holds 0x%08x", v.q, m.q);
	CHECK(v.md == m.md, "MD reads 0x%08x, the model holds 0x%08x", v.md, m.md);
	CHECK(!v.unmapped, "a face that answered all three words called them unmapped");
	// Bits 23:8, which is what the two levels of the map are indexed by:
	// a CADR page is 256 words.
	CHECK(v.vma_page == ((m.vma >> 8) & 0xFFFFu), "VMA's page is 0%o, wanting 0%o",
	      v.vma_page, (m.vma >> 8) & 0xFFFFu);
	CHECK(v.q_page == ((m.q >> 8) & 0xFFFFu), "Q's page is 0%o, wanting 0%o",
	      v.q_page, (m.q >> 8) & 0xFFFFu);
	// MD<23:8> is a page number in the same sense and for a sharper
	// reason: cadr_microcycle.sv:1006 makes MAPI VMA<23:8> on a memory
	// reference and MD<23:8> otherwise, so this is the entry a SRCMAP
	// read looks at.
	CHECK(v.md_page == ((m.md >> 8) & 0xFFFFu), "MD's page is 0%o, wanting 0%o",
	      v.md_page, (m.md >> 8) & 0xFFFFu);
	// **AND THEY ARE NOT CROSSED**, which is the one mistake that would
	// make this instrument answer the question it exists for with the two
	// sides swapped.  The model holds two words that differ, so this is
	// evidence and not an accident; a check made where they read alike
	// would pass either way, which is `tb/cadr_console_tb.cpp`'s own
	// lesson about counting the discriminating samples.
	CHECK(m.vma != m.q, "the model's VMA and Q read alike, so nothing here can tell one from the other");
	CHECK(v.vma != v.q, "VMA and Q came back equal from a model holding two different words");
	// The same for MD, once against each of the two words it could be
	// handed back in place of.  A crossing is with one register at a time,
	// so this is two claims and not one.
	CHECK(m.md != m.vma && m.md != m.q,
	      "the model's MD reads alike with VMA or Q, so nothing here can tell one from the other");
	CHECK(v.md != v.vma, "MD and VMA came back equal from a model holding two different words");
	CHECK(v.md != v.q, "MD and Q came back equal from a model holding two different words");

	// **THE LATCH.**  Move Q and MD under the program without reading word
	// 7: words 8 and 9 alone must still be what the last read of word 7
	// took.
	const uint32_t was_q = v.q, was_md = v.md;
	m.q = 0x00077777u;
	m.md = 0x00066666u;
	CHECK(c.read(&c, CONS_Q) == was_q,
	      "word 8 read alone gave 0x%08x and not the 0x%08x the last read of word 7 latched",
	      c.read(&c, CONS_Q), was_q);
	CHECK(c.read(&c, CONS_MD) == was_md,
	      "word 9 read alone gave 0x%08x and not the 0x%08x the last read of word 7 latched",
	      c.read(&c, CONS_MD), was_md);
	cons_read_machine_words(&c, &v);
	CHECK(v.q == 0x00077777u, "reading VMA did not re-arm the latch: Q reads 0x%08x", v.q);
	CHECK(v.md == 0x00066666u, "reading VMA did not re-arm the latch: MD reads 0x%08x", v.md);

	// **AND THE ORDER IS THE RULE AND NOT THE ADVICE**: the wrong order
	// pairs a Q and an MD from the last read of word 7 with a VMA from
	// now, and this is what that looks like when it happens.
	{
		m.q = 0x00011111u;
		m.md = 0x00022222u;
		const uint32_t stale_q = c.read(&c, CONS_Q);
		const uint32_t stale_md = c.read(&c, CONS_MD);
		const uint32_t now = c.read(&c, CONS_VMA);
		CHECK(stale_q == 0x00077777u && stale_md == 0x00066666u && now == m.vma,
		      "Q and MD then VMA did not give stale words with a fresh VMA: 0x%08x, 0x%08x, 0x%08x",
		      stale_q, stale_md, now);
	}

	// What it says, which is part of the contract: the two values, what
	// each is, and what each reading points at.  No name for the
	// comparison --- the numbers and the sentence.
	m.q = m.vma;
	m.md = 0x0038B10Fu;
	capture_start();
	cons_read_machine_words(&c, &v);
	cons_say_machine_words(&v);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "VMA") && strstr(out, "Q ") && strstr(out, "MD "),
		      "the three were not printed by name");
		CHECK(strstr(out, "same word") != NULL,
		      "an equal pair was not reported as equal");
		CHECK(strstr(out, "map write not having taken") != NULL,
		      "an equal pair did not say what it points at");
		CHECK(strstr(out, "halt") != NULL,
		      "the output did not say the answer means nothing on a machine that was not halted");
		// **WHAT MD IS**, said every time and not only when a
		// comparison comes out one way: the faulting read never
		// completed, so what stands in MD is the word before it.
		CHECK(strstr(out, "last COMPLETED read") != NULL,
		      "the output did not say what word MD holds");
		CHECK(strstr(out, "muir's md") != NULL,
		      "the output did not say what MD is to be compared against");
		// And the reading that is a fact about the wiring: the map is
		// indexed by VMA<23:8> on a memory reference and by MD<23:8>
		// otherwise, so these two page numbers are the entry read
		// THROUGH and the entry a SRCMAP read LOOKED AT.
		CHECK(strstr(out, "MD and VMA name DIFFERENT pages, 34261") != NULL,
		      "MD and VMA on different pages was not reported as such");
		CHECK(strstr(out, "VMAS 1C20") != NULL,
		      "the output did not name where MD's half of the map index comes from");
	}
	// MD naming the page VMA does: a SRCMAP read here looks at the entry
	// the machine also reads through, which is the other reading and must
	// not print as the first.
	m.md = (m.vma & 0x00FFFF00u) | 0x44u;
	capture_start();
	cons_read_machine_words(&c, &v);
	cons_say_machine_words(&v);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "MD and VMA name the same page") != NULL,
		      "MD and VMA on one page was not reported as such");
		CHECK(strstr(out, "MD and VMA name DIFFERENT") == NULL,
		      "MD and VMA on one page were called different pages");
	}
	m.q = 0x00129C42u;
	m.md = 0x0038B10Fu;
	capture_start();
	cons_read_machine_words(&c, &v);
	cons_say_machine_words(&v);
	{
		const char *out = capture_end();
		// **NAMED, NOT A BARE SUBSTRING.**  Two sentences print the
		// words "DIFFERENT pages" now --- VMA against Q, and MD
		// against VMA --- so a test that only looked for the phrase
		// would pass on the wrong one.  It went red exactly once when
		// MD's sentence landed, which is the check doing its job.
		CHECK(strstr(out, "VMA and Q name DIFFERENT pages") != NULL,
		      "a pair a page apart was not reported as naming different pages");
		CHECK(strstr(out, "not the page the map was hacked for") != NULL,
		      "a pair a page apart did not say what it points at");
	}
	// Two words of one page: neither reading, and it must not be reported
	// as either.
	m.q = m.vma + 4u;
	capture_start();
	cons_read_machine_words(&c, &v);
	cons_say_machine_words(&v);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "VMA and Q differ but name the same page") != NULL,
		      "two words of one page were not reported as such");
		CHECK(strstr(out, "same word") == NULL, "two different words were called the same word");
		CHECK(strstr(out, "VMA and Q name DIFFERENT pages") == NULL,
		      "two words of one page were called different pages");
	}

	// **AND A FABRIC WITHOUT THESE WORDS MUST NOT READ AS A VIRTUAL
	// ADDRESS.**  An older bitstream answers UNMAPPED at both, and
	// UNMAPPED is a value that means nothing: the rule this project keeps
	// meeting is that it must not be a value the instrument can mean.
	m.vma = CONS_UNMAPPED;
	m.q = CONS_UNMAPPED;
	m.md = CONS_UNMAPPED;
	capture_start();
	cons_read_machine_words(&c, &v);
	cons_say_machine_words(&v);
	CHECK(v.unmapped, "all three words reading UNMAPPED was taken for a machine's state");
	CHECK(strstr(capture_end(), "not in this bitstream") != NULL,
	      "a fabric without these words was not named as one");
	// And two of three is NOT that: a machine really can hold UNMAPPED's
	// bit pattern in one register, and a face that called that a missing
	// bitstream would throw away a reading it had.
	m.md = 0x0038B10Fu;
	cons_read_machine_words(&c, &v);
	CHECK(!v.unmapped, "two words of UNMAPPED and one real one were called a missing bitstream");

	// They come back through `regs` and through `status` too, which is
	// where a person actually meets them.
	model_init(&m);
	{
		struct cons_regs r;
		capture_start();
		cons_read_regs(&c, &r);
		cons_say_regs(&r);
		const char *out = capture_end();
		CHECK(r.mw.vma == m.vma && r.mw.q == m.q && r.mw.md == m.md,
		      "`regs` did not read the three");
		CHECK(strstr(out, "on no diagnostic register") != NULL,
		      "`regs` printed them as though they were seventeenth registers");
	}
	{
		struct cons_status st;
		capture_start();
		cons_status(&c, 0, &st);
		cons_say_status(&st);
		CHECK(st.mw.vma == m.vma && st.mw.q == m.q && st.mw.md == m.md,
		      "`status` did not read the three");
		CHECK(strstr(capture_end(), "virtual address register") != NULL,
		      "`status` did not print them");
	}
}

// The address arithmetic examine and deposit use, which is
// cadr_ddr_map::main_byte_address and not a second description of it.
// **THE DEBUG CABLE'S ROLE**, page 0's word 14.  MIT's cable on one Pmod
// header, and a board is a debugger or a debuggee on it and never both at
// once.  What this holds is the program's half of it: the two keys and nothing
// else, and that the line it prints tells the three cases apart.
//
// **ASKED IS NOT HAD, AND THAT IS THE CASE THE TWO BITS EXIST FOR.**  A board
// that can see a debugger already on the connector holds its own engagement
// down, so a console that reported what it asked for would say this board was
// the debugger when the far one is.  The model can be put in that state and
// the words are asserted there.
static void check_debug_cable(void)
{
	struct model m;
	struct console c;
	model_init(&m);
	attach(&c, &m);

	// A board that has been told nothing is a DEBUGGEE, which is what a
	// CADR is with nothing set.
	struct cons_debug_cable d;
	cons_read_debug_cable(&c, &d);
	CHECK(!d.engaged, "a board told nothing says it is the debugger");
	CHECK(!d.asked, "a board told nothing says it asked for the role");
	CHECK(d.connects == 0, "connects counted before any was asked");
	CHECK((d.word >> 16) == (CONS_DEBUG_CONNECT_KEY >> 16),
	      "the debug register's marker");
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "DEBUGGEE") != NULL, "a debuggee is not called one");
	}

	// The key asks and is taken, with nothing else on the connector.
	m.dbg_live = 1;
	cons_debug_cable_connect(&c);
	cons_read_debug_cable(&c, &d);
	CHECK(d.engaged && d.asked, "the connect key did not take the role");
	CHECK(d.connects == 1, "the connect was not counted");
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "DEBUGGER") != NULL, "a debugger is not called one");
		CHECK(strstr(out, "far end is answering") != NULL,
		      "the far end answering is not said");
		// And the line says the window is a debugger of its own,
		// because somebody reading DEBUGGER could otherwise think this
		// board had stopped being debuggable.
		CHECK(strstr(out, "never switched off") != NULL,
		      "the page being always live is not said");
	}

	// The complement gives it back and counts nothing.
	cons_debug_cable_disconnect(&c);
	cons_read_debug_cable(&c, &d);
	CHECK(!d.engaged && !d.asked, "the disconnect key did not give the role back");
	CHECK(d.connects == 1, "a disconnect was counted as a connect");

	// **ASKED AND REFUSED.**  Somebody else is the debugger on this
	// connector, so the ask stands and the role does not.
	m.dbg_foreign = 1;
	m.dbg_active = 1;
	cons_debug_cable_connect(&c);
	cons_read_debug_cable(&c, &d);
	CHECK(d.asked, "the ask was not recorded");
	CHECK(!d.engaged, "the role was taken with a debugger already on the cable");
	CHECK(d.foreign, "the connector does not say why it refused");
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "ASKED") != NULL, "a refused ask is not said to be an ask");
		CHECK(strstr(out, "does not have the role") != NULL,
		      "a refused ask is not said to be refused");
		CHECK(strstr(out, "somebody else") != NULL,
		      "the reason for the refusal is not said");
		CHECK(strstr(out, "this board is the DEBUGGER") == NULL,
		      "a board that was refused is reported as the debugger");
	}
	m.dbg_foreign = 0;
	m.dbg_active = 0;
	cons_debug_cable_disconnect(&c);

	// **THE KEY.**  A write of anything else is dropped in silence, which
	// is what stops a stuck bus, a truncated store or a wild pointer from
	// taking a connector away from the machine using it.  The same shapes
	// word 13 is given, plus the other two keys.
	{
		const uint32_t wrong[] = {
			0u, 0xFFFFFFFFu, CONS_IDENT_WORD, CONS_UNMAPPED,
			c.read(&c, CONS_DEBUG), 0x52474244u,
			CONS_DEBUG_CONNECT_KEY ^ 1u,
			CONS_DEBUG_CONNECT_KEY ^ 0x80000000u,
			CONS_DEBUG_CONNECT_KEY & 0x00FFFFFFu,
			CONS_DEBUG_CONNECT_KEY & 0xFFFFFF00u,
			0x52534554u, CONS_BOOT_KEY,   /* "RSET" and "BOOT" */
		};
		const unsigned was = m.connects;
		for (unsigned k = 0; k < sizeof wrong / sizeof wrong[0]; ++k) {
			c.write(&c, CONS_DEBUG, wrong[k]);
			CHECK(!m.dbg_asked, "a write that is not a key asked for the role");
			CHECK(!m.dbg_engaged, "a write that is not a key took the role");
		}
		CHECK(m.connects == was, "a write that is not a key was counted");
	}

	// ---- WHICH WAY ROUND THE RIBBON WAS MADE ------------------------
	//
	// Three more keys on the same word, and one thing they may not do:
	// move under a board that is already the debugger.  A board with
	// nothing said is on `auto`, which is the fabric's own reset value and
	// what a card that says nothing leaves it at.
	cons_read_debug_cable(&c, &d);
	CHECK(d.wire == CONS_DBG_WIRE_AUTO_IDLE, "a board told nothing is not on auto");
	cons_debug_cable_wiring(&c, CONS_DBG_WIRE_CROSSOVER);
	cons_read_debug_cable(&c, &d);
	CHECK(d.wire == CONS_DBG_WIRE_CROSSOVER, "the crossover key did not take");
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "crossover") != NULL, "the wiring is not said");
	}
	cons_debug_cable_wiring(&c, CONS_DBG_WIRE_STRAIGHT);
	cons_read_debug_cable(&c, &d);
	CHECK(d.wire == CONS_DBG_WIRE_STRAIGHT, "the straight key did not take");
	// **AND NOT WHILE THIS BOARD IS THE DEBUGGER.**
	cons_debug_cable_connect(&c);
	cons_debug_cable_wiring(&c, CONS_DBG_WIRE_CROSSOVER);
	cons_read_debug_cable(&c, &d);
	CHECK(d.engaged, "the role was not taken before the setting was moved");
	CHECK(d.wire == CONS_DBG_WIRE_STRAIGHT,
	      "a setting moved under a board that was already the debugger");
	cons_debug_cable_disconnect(&c);
	cons_debug_cable_wiring(&c, CONS_DBG_WIRE_AUTO_IDLE);
	cons_read_debug_cable(&c, &d);
	CHECK(d.wire == CONS_DBG_WIRE_AUTO_IDLE, "the auto key did not take");
	// A spelling nothing names writes nothing.
	cons_debug_cable_wiring(&c, 99);
	cons_read_debug_cable(&c, &d);
	CHECK(d.wire == CONS_DBG_WIRE_AUTO_IDLE, "a wiring nobody names was written");

	// **AND THE CROSSED CABLE, NAMED FROM THE END THAT CANNOT COMPENSATE.**
	// A debuggee answers on the four pins it never hears anything on, so
	// frames arriving there say the two ends disagree about the cable.  It
	// is said BEFORE the plain `a debugger is on the connector`, both being
	// true at once, because it is the one that tells somebody what to do.
	m.dbg_peer_far = 1;
	m.dbg_foreign = 1;
	cons_read_debug_cable(&c, &d);
	CHECK(d.peer_far, "the far pins are not reported");
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "PINS THIS BOARD ANSWERS ON") != NULL,
		      "a crossed cable is not named from the debuggee's end");
		CHECK(strstr(out, "disagree") != NULL, "the diagnosis is not said");
	}
	m.dbg_peer_far = 0;
	m.dbg_foreign = 0;

	// **AND THE CABLE'S TWO COUNTS**, which are the instrument for the one
	// thing about these pins nobody has measured: a Pmod row is routed as
	// coupled pairs and this link drives one signal a pair with the partner
	// held low as a guard; an edge that still couples into the strobe beside
	// it misaligns a frame.  A
	// misaligned frame moves nothing and the next carries the levels again,
	// so what it costs is refused frames --- and how often is the number.
	m.dbg_heard = 40000;
	m.dbg_refused = 3;
	cons_read_debug_cable(&c, &d);
	CHECK(d.frames_ok, "word 15 did not carry its marker");
	CHECK(d.heard == 40000, "the frames heard");
	CHECK(d.refused == 3, "the frames refused");
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "40000 frame(s) heard, 3 refused") != NULL,
		      "the two counts are not said together");
		CHECK(strstr(out, "costs a frame and never a word") != NULL,
		      "what a refusal costs is not said");
	}
	// None refused is the ordinary case and says nothing more than the two
	// numbers: a line that explained a refusal every time would train
	// somebody to stop reading it.
	m.dbg_refused = 0;
	cons_read_debug_cable(&c, &d);
	capture_start();
	cons_say_debug_cable(&d);
	{
		const char *out = capture_end();
		CHECK(strstr(out, "40000 frame(s) heard, 0 refused") != NULL,
		      "a clean cable's counts are not said");
		CHECK(strstr(out, "costs a frame and never a word") == NULL,
		      "a clean cable is given the explanation of a refusal");
	}
	// And a fabric older than the counts is said to be, rather than read as
	// a cable that has heard nothing: the marker is what tells them apart.
	{
		struct model old;
		struct console oc;
		model_init(&old);
		attach(&oc, &old);
		old.debug_frames_unmapped = 1;
		struct cons_debug_cable od;
		cons_read_debug_cable(&oc, &od);
		CHECK(!od.frames_ok, "an unmapped word 15 was read as two counts");
		capture_start();
		cons_say_debug_cable(&od);
		{
			const char *out = capture_end();
			CHECK(strstr(out, "older than they are") != NULL,
			      "an unmapped word 15 is not called out");
		}
	}

	// And the check itself can fail: a modeled fabric that takes any value
	// is caught by the same twelve.
	{
		struct model any;
		struct console ac;
		model_init(&any);
		attach(&ac, &any);
		any.debug_deaf_to_the_key = 1;
		ac.write(&ac, CONS_DEBUG, 0u);
		CHECK(any.connects == 1,
		      "the wrong-key check cannot see a fabric that connects on any value");
	}
}

static void check_main_address(void)
{
	CHECK(cons_main_byte_address(0) == 0x18000000u, "word 0 is not at the region's base");
	CHECK(cons_main_byte_address(1) == 0x18000004u, "a word is not four bytes");
	// The word the proving boards used: 0o12345671.
	CHECK(cons_main_byte_address(012345671u) == 0x18A72EE4u,
	      "main_byte_address(22'o12345671) is 0x%08x, wanting 0x18A72EE4 --- the address the proving "
	      "boards wrote on the board", cons_main_byte_address(012345671u));
	CHECK(cons_main_byte_address(0x3FFFFFu) == 0x18000000u + (0x3FFFFFu << 2),
	      "the top of the 22-bit physical space is not where the map puts it");
	CHECK(CONS_MAIN_WORDS_REACHABLE == 3932160u,
	      "the reachable words have moved from cadr_ddr_map.sv's 60 boards of 64K");
}


// **THE LIGHT PANEL'S BUTTON**, page 0's word 13, and the three things it has
// to do: press, take the key and nothing else, and take the hold off.
//
// muir's `Command::Boot` is the reference for what it means --- "the boot
// button, which is what starts a machine: it presets RUN, and the machine runs
// from the PROM at 0" --- and `say_halted` for what refuses while a machine is
// held.  The fabric half is `rtl/plumbing/cadr_console.sv`'s word 13 and
// `build/console.pass`; this is the program's half.
static void check_boot(void)
{
	struct model m;
	struct console c;
	struct cons_boot_report r;
	model_init(&m);
	attach(&c, &m);

	// A HALTED machine: the button is what starts one, which is the whole
	// reason `continue` and `step` send you here on muir.
	cons_halt(&c);
	CHECK(m.run == 0, "halt did not clear RUN");
	m.f1.promdisable = 1;
	m.pc = 05163;
	capture_start();
	CHECK(cons_boot_and_report(&c, 2000, &r) == 0, "boot lost a diagnostic cycle");
	cons_say_boot(&r);
	{
		const char *out = capture_end();
		CHECK(m.run == 1, "the button did not preset RUN on a halted machine");
		CHECK(m.pc == 0, "the button did not force the PC to zero");
		CHECK(m.f1.promdisable == 0, "the button did not clear PROMDISABLE");
		CHECK(r.presses == 1, "the press was not counted");
		CHECK(r.held == 0, "the line was still down when the write was answered");
		CHECK(r.pc_before == 05163, "the PC before the press is not what it was");
		CHECK(r.pc_after == 0, "the PC after the press is not zero");
		CHECK(r.running, "the machine did not run after the button");
		CHECK(strstr(out, "the boot PROM is running from word 0 again") != NULL,
		      "boot did not say the PROM is running from 0");
		CHECK(strstr(out, "1 press since") != NULL, "boot did not count the press");
	}

	// A RUNNING machine: the same button and the same result.  The
	// processor cannot tell one press from another and neither can this.
	m.pc = 04321;
	capture_start();
	CHECK(cons_boot_and_report(&c, 2000, &r) == 0, "boot lost a diagnostic cycle");
	cons_say_boot(&r);
	capture_end();
	CHECK(r.presses == 2, "the second press was not counted");
	CHECK(m.pc == 0, "the button did not force a running machine's PC to zero");

	// **THE KEY.**  A write of anything else is dropped in silence, which
	// is what stops a stuck bus, a truncated store or a wild pointer from
	// stopping the machine.  Twelve values that are not the key, the same
	// twelve shapes `console-resets-the-machine-on-any-value` names for
	// word 6: zero, all ones, IDENT, UNMAPPED, the word's own read-back,
	// the key byte-reversed, two single-bit neighbors, and the key with a
	// byte missing either end.
	{
		const uint32_t wrong[] = {
			0u, 0xFFFFFFFFu, CONS_IDENT_WORD, CONS_UNMAPPED,
			c.read(&c, CONS_BOOT), 0x544F4F42u,
			CONS_BOOT_KEY ^ 1u, CONS_BOOT_KEY ^ 0x80000000u,
			CONS_BOOT_KEY & 0x00FFFFFFu, CONS_BOOT_KEY & 0xFFFFFF00u,
			CONS_RESET, 0x52534554u,
		};
		const unsigned was = m.boots;
		m.pc = 01234;
		for (unsigned k = 0; k < sizeof wrong / sizeof wrong[0]; ++k) {
			c.write(&c, CONS_BOOT, wrong[k]);
			CHECK(!m.boot_pressed, "a write that is not the key pressed the button");
		}
		CHECK(m.boots == was, "a write that is not the key was counted as a press");
		CHECK(m.pc == 01234, "a write that is not the key moved the machine");
	}

	// And the check itself can fail: a modeled fabric that boots on any
	// value is caught by the same twelve.
	{
		struct model any;
		struct console ac;
		model_init(&any);
		attach(&ac, &any);
		any.boot_deaf_to_the_key = 1;
		ac.write(&ac, CONS_BOOT, 0u);
		CHECK(any.boots == 1,
		      "the wrong-key check cannot see a fabric that boots on any value");
	}
}

// **THE HELD MACHINE**, `--no-auto-boot`'s marker: `start` and `step` refuse
// while it is there, `boot` presses the button and removes it.  Nothing in the
// fabric knows about it --- RUN is still preset at reset --- so this is the
// whole of the contract and it is a file.
static void check_held(void)
{
	char path[] = "/tmp/cadr-held-testXXXXXX";
	const int fd = mkstemp(path);
	CHECK(fd >= 0, "could not make the marker file the test needs");
	if (fd >= 0)
		close(fd);

	CHECK(cons_held(path) == 1, "the marker was not seen");
	CHECK(cons_held("/tmp/cadr-held-test-that-is-not-there") == 0,
	      "a marker that is not there was seen");
	CHECK(cons_release_held(path) == 0, "the marker could not be removed");
	CHECK(cons_held(path) == 0, "the marker is still there after being removed");
	// Removing one that is not there is the ordinary machine, and must not
	// be an error: `boot` calls this on every press.
	CHECK(cons_release_held(path) == 0, "removing a marker that is not there failed");

	// The sentence is muir's own, `say_halted` in ../muir/src/main.rs, so
	// that somebody who knows one knows the other.  Held as a WORD and not
	// as a flag, which is the rule this program's printing already follows.
	CHECK(strcmp(CONS_HELD_SAYING,
		     "the machine is halted, its RUN clear: boot presses the button that starts it") == 0,
	      "the held machine's sentence is not muir's");
	CHECK(strcmp(CONS_HELD_PATH, "/var/run/cadr-held") == 0,
	      "the marker is not where the init step leaves it");
}

// **`trace-keys` AND `trace-chaos`, WHICH SIGNAL DAEMONS AND TOUCH NO
// REGISTER.**
//
// What is under check is the pid file and the signal: that the right one of
// the two goes, that a file which does not name a process is REFUSED rather
// than acted on, and that the line says which happened.  The daemons are
// played by this process itself --- it writes its own pid into the stub file
// and installs the two handlers --- which is the only honest way to see that
// a signal went at all.
//
// **THE PID FILE HOLDING `0` IS THE ONE THAT MATTERS.**  `kill(0, SIGUSR1)`
// signals the whole process GROUP, which at a prompt is the shell somebody
// typed in; a negative pid signals a group by number, and -1 signals every
// process the user may signal.  So the refusal is asserted by the handler NOT
// firing, which is the only assertion that could tell a refusal from a signal
// sent to everybody.
static volatile sig_atomic_t trace_seen_on, trace_seen_off;

static void trace_note(int sig)
{
	if (sig == SIGUSR1)
		++trace_seen_on;
	else
		++trace_seen_off;
}

static void check_trace_keys(void)
{
	char path[] = "/tmp/cadr-trace-testXXXXXX";
	const int fd = mkstemp(path);
	CHECK(fd >= 0, "could not make the pid file the test needs");
	if (fd < 0)
		return;
	close(fd);
	signal(SIGUSR1, trace_note);
	signal(SIGUSR2, trace_note);

	// A pid file naming this process: the signal must arrive, and it must
	// be the one the word asked for.
	FILE *f = fopen(path, "w");
	fprintf(f, "%ld\n", (long)getpid());
	fclose(f);

	struct cons_trace r;
	trace_seen_on = trace_seen_off = 0;
	capture_start();
	CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_KEYS, 1, &r) == CONS_TRACE_SIGNALLED,
	      "the signal did not go to a live process");
	CHECK(r.pid == (long)getpid(), "the pid read back is %ld and not this process's %ld",
	      r.pid, (long)getpid());
	CHECK(trace_seen_on == 1 && trace_seen_off == 0,
	      "`on` sent %d SIGUSR1 and %d SIGUSR2, wanting one and none",
	      (int)trace_seen_on, (int)trace_seen_off);
	cons_say_trace(&r, 1);
	CHECK(strstr(capture_end(), "turn its key trace ON") != NULL,
	      "the line for a program that was reached does not say the trace was turned on");

	trace_seen_on = trace_seen_off = 0;
	CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_KEYS, 0, &r) == CONS_TRACE_SIGNALLED,
	      "the off signal did not go");
	CHECK(trace_seen_off == 1 && trace_seen_on == 0,
	      "`off` sent %d SIGUSR2 and %d SIGUSR1, wanting one and none",
	      (int)trace_seen_off, (int)trace_seen_on);

	// **THE THREE FILES THAT NAME NO PROCESS**, and the handler must not
	// fire for any of them.  `0` and `-1` are the dangerous two; an empty
	// file is what `start-stop-daemon` leaves when nothing started.
	static const char *const bad[] = { "0\n", "-1\n", "", "not a number\n" };
	for (unsigned i = 0; i < sizeof bad / sizeof bad[0]; ++i) {
		f = fopen(path, "w");
		fputs(bad[i], f);
		fclose(f);
		trace_seen_on = trace_seen_off = 0;
		capture_start();
		CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_KEYS, 1, &r) == CONS_TRACE_NOT_RUNNING,
		      "a pid file holding \"%s\" was not refused", bad[i]);
		CHECK(trace_seen_on == 0 && trace_seen_off == 0,
		      "a pid file holding \"%s\" signaled something: %d on, %d off",
		      bad[i], (int)trace_seen_on, (int)trace_seen_off);
		cons_say_trace(&r, 1);
		CHECK(strstr(capture_end(), "is not running") != NULL,
		      "a pid file holding \"%s\" did not report the program as not running",
		      bad[i]);
	}

	// A pid file that is not there at all: the ordinary board with one of
	// the two programs stopped.
	unlink(path);
	trace_seen_on = trace_seen_off = 0;
	capture_start();
	CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_KEYS, 1, &r) == CONS_TRACE_NOT_RUNNING,
	      "a missing pid file was not reported as a program that is not running");
	CHECK(trace_seen_on == 0 && trace_seen_off == 0, "a missing pid file signaled something");
	cons_say_trace(&r, 1);
	CHECK(strstr(capture_end(), "is not running") != NULL,
	      "a missing pid file did not report the program as not running");
	signal(SIGUSR1, SIG_DFL);
	signal(SIGUSR2, SIG_DFL);

	// The three pid files are where the init scripts write them.  A word
	// that signaled the wrong file would say `not running` for ever on a
	// board where the programs are up.
	CHECK(strcmp(CONS_TRACE_TERMINAL_PID, "/var/run/cadr-terminal.pid") == 0,
	      "the terminal's pid file is not where S85cadr-terminal writes it");
	CHECK(strcmp(CONS_TRACE_USB_PID, "/var/run/cadr-usb-input.pid") == 0,
	      "the USB program's pid file is not where S88cadr-usb-input writes it");
	CHECK(strcmp(CONS_TRACE_CHAOS_PID, "/var/run/cadr-chaosnet.pid") == 0,
	      "the Chaosnet program's pid file is not where S87cadr-chaosnet writes it");
	CHECK(strcmp(CONS_TRACE_CHAOS, "cadr-chaosnet") == 0,
	      "the Chaosnet program is not named as the init script names it");
}

// **`trace-chaos`, WHICH IS THE SAME PAIR OF FUNCTIONS TOLD A DIFFERENT
// TRACE.**  What is under check here is the half that differs: the signal
// still goes, and the line names the PACKET trace and the word somebody
// typed.  A line that said `key trace` to somebody who asked about the
// network would send them to the wrong log.
static void check_trace_chaos(void)
{
	char path[] = "/tmp/cadr-trace-chaos-testXXXXXX";
	const int fd = mkstemp(path);
	CHECK(fd >= 0, "could not make the pid file the test needs");
	if (fd < 0)
		return;
	close(fd);
	signal(SIGUSR1, trace_note);
	signal(SIGUSR2, trace_note);

	FILE *f = fopen(path, "w");
	fprintf(f, "%ld\n", (long)getpid());
	fclose(f);

	struct cons_trace r;
	trace_seen_on = trace_seen_off = 0;
	capture_start();
	CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_CHAOS, 1, &r) ==
		      CONS_TRACE_SIGNALLED,
	      "the signal did not go to a live process");
	CHECK(trace_seen_on == 1 && trace_seen_off == 0,
	      "`on` sent %d SIGUSR1 and %d SIGUSR2, wanting one and none",
	      (int)trace_seen_on, (int)trace_seen_off);
	cons_say_trace(&r, 1);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "turn its packet trace ON") != NULL,
		      "the line does not say the packet trace was turned on: %s", said);
		CHECK(strstr(said, "trace-chaos:") != NULL,
		      "the line does not name the word that was typed: %s", said);
		CHECK(strstr(said, "key trace") == NULL,
		      "the line for the packet trace mentions the key trace: %s", said);
	}

	// And off, which is the other signal.
	trace_seen_on = trace_seen_off = 0;
	capture_start();
	CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_CHAOS, 0, &r) ==
		      CONS_TRACE_SIGNALLED,
	      "the off signal did not go");
	CHECK(trace_seen_off == 1 && trace_seen_on == 0,
	      "`off` sent %d SIGUSR2 and %d SIGUSR1, wanting one and none",
	      (int)trace_seen_off, (int)trace_seen_on);
	cons_say_trace(&r, 0);
	CHECK(strstr(capture_end(), "turn its packet trace off") != NULL,
	      "the line does not say the packet trace was turned off");

	// A pid file naming no process is refused here as it is for the keys:
	// one function, so this asserts that the chaos word reaches it rather
	// than re-testing the refusal itself.
	f = fopen(path, "w");
	fputs("0\n", f);
	fclose(f);
	trace_seen_on = trace_seen_off = 0;
	capture_start();
	CHECK(cons_trace_signal("a program", path, CONS_TRACE_WHAT_CHAOS, 1, &r) ==
		      CONS_TRACE_NOT_RUNNING,
	      "a pid file holding 0 was not refused");
	CHECK(trace_seen_on == 0 && trace_seen_off == 0,
	      "a pid file holding 0 signaled something");
	cons_say_trace(&r, 1);
	CHECK(strstr(capture_end(), "trace-chaos:") != NULL,
	      "the refusal does not name the word that was typed");
	unlink(path);
	signal(SIGUSR1, SIG_DFL);
	signal(SIGUSR2, SIG_DFL);
}

// **SW0, AND WHAT A CONSOLE MUST SAY ABOUT A MACHINE THAT NEVER RAN.**
//
// A machine the switch held has SRUN down and reads EXACTLY like one somebody
// halted from the console: `status` says NOT RUNNING and attributes it to a
// cleared RUN, which is true and sends a person looking for whoever halted it.
// So the two bits are not a decoration --- they are the difference between a
// diagnosis and a wild goose chase, and what is asserted here is the WORDS, on
// this project's own rule that a check on a program asserts the line it prints.
static void check_switch(void)
{
	struct model m;
	struct console c;
	struct cons_switch sw;
	struct cons_status st;

	// 1.  A board that boots itself, switch never touched: no bit, and
	//     `status` says nothing about a switch at all.
	model_init(&m);
	attach(&c, &m);
	cons_read_switch(&c, &sw);
	CHECK(sw.held_at_reset == 0, "a board that boots itself reports a hold");
	CHECK(sw.now == 0, "a switch that is off reads on");
	capture_start();
	cons_say_switch(&sw);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "did not hold the machine") != NULL,
		      "switch did not say the machine was not held: %s", said);
		CHECK(strstr(said, "still OFF") != NULL,
		      "switch did not say where the switch is: %s", said);
	}
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a board that boots itself");
	cons_say_status(&st);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "SW0") == NULL,
		      "status talks about a switch nobody touched: %s", said);
	}

	// 2.  The switch held the machine.  It is stopped, and `status` must
	//     say it never ran rather than leaving the console's own halt as
	//     the only reason on offer.
	model_init(&m);
	m.held_at_reset = 1;
	m.switch_now = 1;
	m.run = 0;
	m.f1.srun = 0;
	attach(&c, &m);
	cons_read_switch(&c, &sw);
	CHECK(sw.held_at_reset == 1, "a held machine does not report the hold");
	CHECK(sw.now == 1, "a switch that is on reads off");
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a held machine");
	cons_say_status(&st);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "NOT RUNNING") != NULL, "status did not say NOT RUNNING");
		CHECK(strstr(said, "SW0 held this machine") != NULL,
		      "status did not say the switch held it: %s", said);
		CHECK(strstr(said, "has never run") != NULL,
		      "status did not say the machine never ran: %s", said);
	}

	// 3.  THE SWITCH MOVED SINCE THE RESET, which is the case one bit
	//     could not carry.  The machine is still held; the switch is off.
	//     Both must be said, and the second must say it changes nothing.
	model_init(&m);
	m.held_at_reset = 1;
	m.switch_now = 0;
	m.run = 0;
	m.f1.srun = 0;
	attach(&c, &m);
	cons_read_switch(&c, &sw);
	CHECK(sw.held_at_reset == 1 && sw.now == 0,
	      "a switch moved since the reset is not reported as moved");
	capture_start();
	cons_say_switch(&sw);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "somebody has moved it") != NULL,
		      "switch did not say the switch had moved: %s", said);
		CHECK(strstr(said, "changes nothing until the next reset") != NULL,
		      "switch did not say a moved switch changes nothing: %s", said);
	}
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a machine whose switch moved");
	cons_say_status(&st);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "SW0 held this machine") != NULL,
		      "status forgot the hold when the switch moved: %s", said);
		CHECK(strstr(said, "not what it was at the last reset") != NULL,
		      "status did not say the switch had moved: %s", said);
	}

	// 4.  AND THE OTHER WAY ROUND: the switch was off at the reset and is
	//     on now.  The machine is running, and the console must not say it
	//     is held --- a fabric that read the switch live would, which is
	//     the defect this pair exists to make visible.
	model_init(&m);
	m.held_at_reset = 0;
	m.switch_now = 1;
	attach(&c, &m);
	capture_start();
	CHECK(cons_status(&c, 2000, &st) == 0, "status failed on a running machine");
	cons_say_status(&st);
	{
		const char *said = capture_end();
		CHECK(strstr(said, "RUNNING") != NULL, "status did not say RUNNING");
		CHECK(strstr(said, "SW0 held this machine") == NULL,
		      "status says a running machine is held: %s", said);
		CHECK(strstr(said, "not what it was at the last reset") != NULL,
		      "status did not say the switch had moved: %s", said);
	}

	// 5.  The two bits are where the fabric puts them and nowhere else.
	//     A bit that moved would make every reading above agree with a
	//     console reading the wrong bit of the wrong word.
	CHECK(CONS_ST_HELD_AT_RESET == (1u << 4), "the held bit is not STAT bit 4");
	CHECK(CONS_ST_SWITCH_NOW == (1u << 5), "the switch bit is not STAT bit 5");
}

// ---- the logging: who a line is for, and where it goes --------------------
//
// **THE ROUTINE UNDER CHECK HERE IS `cadr-common`'s AND NOT THIS PACKAGE'S**,
// and it is checked from here for the reason `serial_mutations.txt` already
// aims records at `cadr-common/src/cadr_endpoint.c`: a shared file is held by
// the check that BUILDS it, and this check builds `cadr_log.c`.  Three
// properties, each of which cost this board something or could:
//
//   the prefix   a reply to a person is bare and a line that is kept names
//                its program.  `console_host.h` has the rule
//   two logs     `--log` may be given more than once and every line goes to
//                every destination, which is how the board's daemons write
//                to the serial console AND to a file somebody over ssh can
//                follow
//   the cap      a file destination is rotated at CADR_LOG_MAX, because the
//                root filesystem is a RAM disk and five unbounded logs are a
//                way to take the board down
//
// The scratch is beside this binary --- under ~/.cache either way, whether
// the Makefile built it or the mutation runner did --- and never /tmp, which
// on the build host is a RAM disk of its own.
static char log_dir[512];

static void log_scratch(const char *argv0)
{
	const char *slash = strrchr(argv0, '/');
	const size_t n = slash ? (size_t)(slash - argv0) : 1;
	snprintf(log_dir, sizeof log_dir, "%.*s/logs", (int)n, slash ? argv0 : ".");
	mkdir(log_dir, 0777);
}

static const char *log_path(const char *name)
{
	static char p[640];
	snprintf(p, sizeof p, "%s/%s", log_dir, name);
	return p;
}

static long file_size(const char *path)
{
	struct stat st;
	return stat(path, &st) == 0 ? (long)st.st_size : -1;
}

// The first line of a file, without its newline, or "" if there is none.
static const char *first_line(const char *path)
{
	static char line[256];
	FILE *f = fopen(path, "r");
	line[0] = 0;
	if (!f)
		return line;
	if (fgets(line, sizeof line, f))
		line[strcspn(line, "\n")] = 0;
	fclose(f);
	return line;
}

// ---- WHICH BUILD THE FABRIC IS, page 2's word 32 ------------------------
//
// `tools/build_stamp.tcl` is the authority on the format and this holds the
// decode to it: seven hex digits of commit and a nibble, the five nibbles the
// tcl writes and no others, and `0xFFFFFFFF` for a bitstream that names no
// build --- which is the value the tcl guarantees no build can ever be.
//
// **THE VALUES ARE THE CHECK'S AND NOT THE TREE'S.**  A test that read the
// repository's own stamp and then agreed with it would be confirming; these
// are commits this repository does not have, so every line is a comparison.
static void check_build(void)
{
	struct model m;
	struct console c;

	// 1.  All five nibbles the stamp's format defines, each with a commit
	//     of its own so that a decode which took the nibble from the wrong
	//     end would name a different commit as well as a different tree.
	static const struct {
		uint32_t word;
		uint32_t commit;
		unsigned tree;
		int modified, untracked, known, no_git;
		const char *words;
	} t[] = {
		{ 0xC0FFEE20u, 0x0C0FFEE2u, 0x0, 0, 0, 1, 0, "clean" },
		{ 0xC0FFEE21u, 0x0C0FFEE2u, 0x1, 1, 0, 1, 0, "modified" },
		{ 0x1234ABC2u, 0x01234ABCu, 0x2, 0, 1, 1, 0, "carrying an untracked file" },
		{ 0x5A1B2C33u, 0x05A1B2C3u, 0x3, 1, 1, 1, 0,
		  "modified and carrying an untracked file" },
		// A commit git could name with a tree it could not read.  Not
		// the same thing as the entry below, and the two must not be
		// run together: this one HAS a commit.
		{ 0x0ABCDEFFu, 0x00ABCDEFu, 0xF, 0, 0, 1, 0, "unknown --- git could not say" },
		// `0000000f`, which the tcl writes when git said nothing at
		// all: not a checkout, and there is no commit to print.
		{ 0x0000000Fu, 0x00000000u, 0xF, 0, 0, 1, 1, "unknown --- git could not say" },
		// A nibble the format does not define.  The flows write none
		// of these, so a word carrying one did not come from here and
		// the decode says so rather than guessing which half is true.
		{ 0xDEADBEE7u, 0x0DEADBEEu, 0x7, 0, 0, 0, 0,
		  "a state this program does not know" },
	};
	for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
		const struct cons_build b = cons_build_of(t[i].word);
		CHECK(b.word == t[i].word, "the build word is not what was read (%u)", i);
		CHECK(b.stamped == 1, "a stamped build reads as unstamped (%u)", i);
		CHECK(b.commit == t[i].commit, "commit %07x wanting %07x (%u)",
		      b.commit, t[i].commit, i);
		CHECK(b.tree == t[i].tree, "tree nibble %x wanting %x (%u)",
		      b.tree, t[i].tree, i);
		CHECK(b.modified == t[i].modified, "modified %d wanting %d (%u)",
		      b.modified, t[i].modified, i);
		CHECK(b.untracked == t[i].untracked, "untracked %d wanting %d (%u)",
		      b.untracked, t[i].untracked, i);
		CHECK(b.known == t[i].known, "known %d wanting %d (%u)",
		      b.known, t[i].known, i);
		CHECK(b.no_git == t[i].no_git, "no_git %d wanting %d (%u)",
		      b.no_git, t[i].no_git, i);
		CHECK(strcmp(cons_build_tree_words(&b), t[i].words) == 0,
		      "the tree in words is \"%s\" wanting \"%s\" (%u)",
		      cons_build_tree_words(&b), t[i].words, i);
	}

	// 2.  **ALL ONES IS NOT A BUILD**, and the line must not name a commit.
	//     It is what an unprogrammed part reads and what a bitstream built
	//     before the flows stamped them leaves in the register, and a
	//     console that printed `commit fffffff` would be inventing one.
	{
		const struct cons_build b = cons_build_of(CONS_BUILD_NONE);
		CHECK(b.stamped == 0, "all ones read as a build");
		capture_start();
		cons_say_build(&b);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "no build stamp") != NULL,
			      "the line did not say there is no stamp: %s", said);
			CHECK(strstr(said, "commit") == NULL,
			      "the line named a commit where there is none: %s", said);
		}
	}

	// 3.  The line a person reads, for a clean build and for a dirty one.
	//     **A DIRTY TREE IS SAID TWICE ON PURPOSE**: the commit then names
	//     where the build started and not what it is, and somebody reading
	//     the commit off the first line and checking out that commit would
	//     not get this fabric.
	{
		const struct cons_build clean = cons_build_of(0xC0FFEE20u);
		capture_start();
		cons_say_build(&clean);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "c0ffee2") != NULL,
			      "the line did not name the commit: %s", said);
			CHECK(strstr(said, "tree clean") != NULL,
			      "the line did not say the tree was clean: %s", said);
			CHECK(strstr(said, "STARTED") == NULL,
			      "a clean build was warned about as a dirty one: %s", said);
		}
	}
	{
		const struct cons_build dirty = cons_build_of(0x5A1B2C33u);
		capture_start();
		cons_say_build(&dirty);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "5a1b2c3") != NULL,
			      "the dirty line did not name the commit: %s", said);
			CHECK(strstr(said, "STARTED") != NULL,
			      "a dirty build was not said to be one: %s", said);
		}
	}
	{
		const struct cons_build nogit = cons_build_of(0x0000000Fu);
		capture_start();
		cons_say_build(&nogit);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "no git information") != NULL,
			      "a build from no checkout was not said to be one: %s", said);
			CHECK(strstr(said, "commit 0000000") == NULL,
			      "a build with no commit printed one anyway: %s", said);
		}
	}

	// 4.  Through the face: the word is read from page 2 and `status`
	//     carries it, so a console on a board answers the question with
	//     one command and not two.
	model_init(&m);
	attach(&c, &m);
	m.build = 0x1234ABC2u;
	CHECK(cons_build_word(&c) == 0x1234ABC2u,
	      "the build word did not come back off page 2");
	{
		struct cons_status st;
		capture_start();
		CHECK(cons_status(&c, 2000, &st) == 0, "status failed");
		cons_say_status(&st);
		{
			const char *said = capture_end();
			CHECK(st.build.word == 0x1234ABC2u,
			      "status did not carry the build word");
			CHECK(strstr(said, "1234abc") != NULL,
			      "status did not name the fabric's commit: %s", said);
		}
	}

	// 5.  **AND WHICH BUILD THE PROGRAM IS, WHICH IS THE OTHER HALF.**
	//     muir's shape is name, version, commit, build kind, and the
	//     commit is dropped rather than guessed when there is none.  What
	//     is asserted here is the shape and not the commit, since the
	//     commit is whatever compiled this.
	{
		const char *v = cons_version();
		CHECK(strncmp(v, "cadr-console ", 13) == 0,
		      "the version does not name the program: %s", v);
		CHECK(strstr(v, "-release") != NULL,
		      "the version does not say which kind of build it is: %s", v);
		CHECK(strchr(v, '\n') == NULL, "the version is more than one line: %s", v);
	}
}

// **THE BACKPLANE'S DISPLAY BOARDS**, page 2's word 33, and the two color
// maps on pages 4 and 5.
// **WHAT THE DISPLAY OUTPUT SHOWS, page 2's word 34.**
//
// Two settings on one word and six keys, as the display boards' three are, and
// a mode that is read only because a mode is a pixel clock.
static void check_hdmi(void)
{
	struct model m;
	struct console c;
	model_init(&m);
	attach(&c, &m);
	{
		struct cons_hdmi h;
		cons_read_hdmi(&c, &h);
		CHECK(h.mark_ok == 1, "the hdmi word did not carry its marker (0x%08x)", h.word);
		CHECK(h.first == 1, "a board came up not showing the first display");
		CHECK(h.color == 0, "a board came up showing the color board");
		CHECK(h.rotate == CONS_HDMI_UPRIGHT, "a board came up rotated");
		CHECK(h.mode == CONS_HDMI_1400, "the mode read %d, and the model is built for %d",
		      h.mode, CONS_HDMI_1400);
	}
	// The three screen keys, each leaving the rotation alone.
	cons_set_hdmi_rotate(&c, CONS_HDMI_CW);
	cons_set_hdmi_output(&c, 0, 1);
	{
		struct cons_hdmi h;
		cons_read_hdmi(&c, &h);
		CHECK(h.first == 0 && h.color == 1, "the color board alone was not set");
		CHECK(h.rotate == CONS_HDMI_CW, "setting the screens moved the rotation");
	}
	cons_set_hdmi_output(&c, 1, 1);
	{
		struct cons_hdmi h;
		cons_read_hdmi(&c, &h);
		CHECK(h.first == 1 && h.color == 1, "both screens were not set");
	}
	// And the three rotations, each leaving the screens alone.
	cons_set_hdmi_rotate(&c, CONS_HDMI_CCW);
	{
		struct cons_hdmi h;
		cons_read_hdmi(&c, &h);
		CHECK(h.rotate == CONS_HDMI_CCW, "the other quarter turn was not set");
		CHECK(h.first == 1 && h.color == 1, "setting the rotation moved the screens");
	}
	cons_set_hdmi_rotate(&c, CONS_HDMI_UPRIGHT);
	{
		struct cons_hdmi h;
		cons_read_hdmi(&c, &h);
		CHECK(h.rotate == CONS_HDMI_UPRIGHT, "upright was not set");
	}
	// **A MONITOR SHOWING NOTHING IS NOT A SETTING**, so a call that asks
	// for neither screen writes nothing and says so.
	CHECK(cons_set_hdmi_output(&c, 0, 0) == -1, "asking for neither screen was accepted");
	CHECK(cons_set_hdmi_rotate(&c, 3) == -1, "a rotation that is not one of three was accepted");
	{
		struct cons_hdmi h;
		cons_read_hdmi(&c, &h);
		CHECK(h.first == 1 && h.color == 1, "a refused call moved the screens");
	}
	// **AND A VALUE THAT MEANS NOTHING CHANGES NOTHING**, the same list
	// word 33 is held to and for the same reason.
	{
		const uint32_t nothing[] = {
			0u, 0xFFFFFFFFu, 0x434F4E53u /* IDENT */,
			CONS_TV_SIMPLE_KEY, CONS_COLOR_TV_KEY, CONS_HDMI_TV_KEY ^ 1u,
			CONS_HDMI_CW_KEY >> 8, ((uint32_t)CONS_HDMI_MARK << 16) | 7u};
		for (unsigned i = 0; i < sizeof(nothing) / sizeof(nothing[0]); ++i) {
			model_write(&c, CONS_HDMI, nothing[i]);
			struct cons_hdmi h;
			cons_read_hdmi(&c, &h);
			CHECK(h.first == 1 && h.color == 1 && h.rotate == CONS_HDMI_UPRIGHT,
			      "a value that means nothing moved what the monitor shows");
		}
	}
	// A fabric older than the word reads zero, and the marker is what says
	// so rather than a board showing nothing upright.
	{
		struct model old;
		struct console oc;
		model_init(&old);
		old.hdmi_unmarked = 1;
		attach(&oc, &old);
		struct cons_hdmi h;
		cons_read_hdmi(&oc, &h);
		CHECK(h.mark_ok == 0, "an unmarked word read as a setting");
	}
}

// **WHETHER THE LAMPS BLINK, page 2's word 35.**
//
// One setting and two keys, a key and its complement, and a line that says
// what the lamps are doing in words a person at the board would recognize.
static void check_lamps(void)
{
	struct model m;
	struct console c;
	model_init(&m);
	attach(&c, &m);
	{
		struct cons_lamps l;
		cons_read_lamps(&c, &l);
		CHECK(l.mark_ok == 1, "the lamps word did not carry its marker (0x%08x)", l.word);
		CHECK(l.steady == 0, "a board came up with steady lamps");
		capture_start();
		cons_say_lamps(&l);
		const char *said = capture_end();
		CHECK(strstr(said, "lamps: blinking") != NULL,
		      "blinking lamps were not said to blink: %s", said);
	}
	cons_set_lamps_steady(&c, 1);
	{
		struct cons_lamps l;
		cons_read_lamps(&c, &l);
		CHECK(l.steady == 1, "asking for steady lamps did not make them steady");
		CHECK(m.lamps_steady == 1, "the fabric was not told to make the lamps steady");
		capture_start();
		cons_say_lamps(&l);
		const char *said = capture_end();
		CHECK(strstr(said, "lamps: steady") != NULL,
		      "steady lamps were not said to be steady: %s", said);
		CHECK(strstr(said, "lock") != NULL,
		      "the line does not say the clock lamp is the lock: %s", said);
	}
	// A key is a setting and not a toggle: asked twice, still steady.
	cons_set_lamps_steady(&c, 1);
	{
		struct cons_lamps l;
		cons_read_lamps(&c, &l);
		CHECK(l.steady == 1, "asking for steady lamps twice made them blink");
	}
	cons_set_lamps_steady(&c, 0);
	{
		struct cons_lamps l;
		cons_read_lamps(&c, &l);
		CHECK(l.steady == 0, "asking for blinking lamps did not make them blink");
		CHECK(m.lamps_steady == 0, "the fabric was not told to make the lamps blink");
	}
	// **AND A VALUE THAT MEANS NOTHING CHANGES NOTHING**: zero off a dead
	// bus, all ones off an undriven one, the other words' keys and the word's
	// own read-back leave blinking lamps blinking.
	{
		const uint32_t nothing[] = {
			0u, 0xFFFFFFFFu, 0x434F4E53u /* IDENT */,
			CONS_HDMI_TV_KEY, CONS_COLOR_TV_KEY, CONS_LAMP_STEADY_KEY ^ 1u,
			CONS_LAMP_STEADY_KEY >> 8, ((uint32_t)CONS_LAMP_MARK << 16) | 1u};
		for (unsigned i = 0; i < sizeof(nothing) / sizeof(nothing[0]); ++i) {
			model_write(&c, CONS_LAMPS, nothing[i]);
			struct cons_lamps l;
			cons_read_lamps(&c, &l);
			CHECK(l.steady == 0, "a value that means nothing made the lamps steady");
		}
	}
	// And the check itself can fail: a modeled fabric that takes any value
	// is caught by the same values.
	{
		struct model any;
		struct console ac;
		model_init(&any);
		any.lamps_deaf_to_the_key = 1;
		attach(&ac, &any);
		ac.write(&ac, CONS_LAMPS, 0u);
		CHECK(any.lamps_steady == 1,
		      "the wrong-key check cannot see a fabric that takes any value");
	}
	// A fabric older than the word reads zero, and the marker is what says
	// so; such a fabric's lamps blink, and the line says that too.
	{
		struct model old;
		struct console oc;
		model_init(&old);
		old.lamps_unmarked = 1;
		attach(&oc, &old);
		struct cons_lamps l;
		cons_read_lamps(&oc, &l);
		CHECK(l.mark_ok == 0, "an unmarked lamps word read as a setting");
		capture_start();
		cons_say_lamps(&l);
		const char *said = capture_end();
		CHECK(strstr(said, "older") != NULL,
		      "an unmarked lamps word was not called an older fabric: %s", said);
	}
}

static void check_display(void)
{
	struct model m;
	struct console c;

	// 1.  A machine comes up with one SIMPLE TV and no color board, which
	//     is muir's own default, and the word says so with its marker on.
	model_init(&m);
	attach(&c, &m);
	{
		struct cons_display d;
		cons_read_display(&c, &d);
		CHECK(d.mark_ok == 1, "the display word did not carry its marker (0x%08x)", d.word);
		CHECK(d.lispm == 0, "a machine came up with a LISPM TV");
		CHECK(d.color == 0, "a machine came up with a color board fitted");
	}

	// 2.  The three keys, each leaving the other setting alone.  **THE
	//     SECOND BOARD AND THE FIRST BOARD'S STRAP ARE TWO FACTS ON ONE
	//     WORD**, so a write of either that moved the other would make a
	//     card's two lines fight.
	cons_set_tv_board(&c, 1);
	{
		struct cons_display d;
		cons_read_display(&c, &d);
		CHECK(d.lispm == 1, "the first board did not become a LISPM TV");
		CHECK(d.color == 0, "setting the board fitted a color board");
	}
	cons_set_color_tv(&c, 1);
	{
		struct cons_display d;
		cons_read_display(&c, &d);
		CHECK(d.lispm == 1, "fitting the color board changed the first board");
		CHECK(d.color == 1, "the color board was not fitted");
	}
	cons_set_tv_board(&c, 0);
	{
		struct cons_display d;
		cons_read_display(&c, &d);
		CHECK(d.lispm == 0, "the first board did not go back to a SIMPLE TV");
		CHECK(d.color == 1, "setting the board took the color board away");
	}
	cons_set_color_tv(&c, 0);
	{
		struct cons_display d;
		cons_read_display(&c, &d);
		CHECK(d.color == 0, "the color board was not taken away");
	}

	// 3.  **A VALUE THAT MEANS NOTHING CHANGES NOTHING.**  Twelve words
	//     written at the display register, none of them a key, and the
	//     backplane must stand: zero off a dead bus, all ones off an
	//     undriven one, the word's own read-back, and the other words'
	//     keys, which name other things entirely.
	cons_set_color_tv(&c, 1);
	cons_set_tv_board(&c, 1);
	{
		struct cons_display before, after;
		static const uint32_t nothing[] = {
			0u, 0xFFFFFFFFu, CONS_IDENT_WORD, CONS_UNMAPPED,
			CONS_BOOT_KEY, 0x52534554u /* "RSET" */, CONS_DEBUG_CONNECT_KEY,
			CONS_DEBUG_WIRE_AUTO_KEY, CONS_TV_SIMPLE_KEY ^ 1u,
			CONS_TV_LISPM_KEY >> 8, CONS_COLOR_TV_KEY + 1u,
			((uint32_t)CONS_TV_MARK << 16) | 3u,
		};
		cons_read_display(&c, &before);
		for (unsigned i = 0; i < sizeof nothing / sizeof nothing[0]; ++i) {
			c.write(&c, CONS_DISPLAY, nothing[i]);
			cons_read_display(&c, &after);
			CHECK(after.word == before.word,
			      "writing 0x%08x at the display register changed it to 0x%08x",
			      nothing[i], after.word);
		}
	}

	// 4.  **A FABRIC OLDER THAN THE WORD IS NOT A BACKPLANE WITH NOTHING
	//     SET**, and the marker is what tells them apart: both read zero
	//     in the two bits.
	{
		struct cons_display d;
		m.display_unmarked = 1;
		cons_read_display(&c, &d);
		CHECK(d.mark_ok == 0, "an unmarked word was read as a backplane");
		capture_start();
		cons_say_display(&d);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "older") != NULL,
			      "the line did not say the fabric is older than the word: %s", said);
		}
		m.display_unmarked = 0;
	}

	// 5.  The lines a person reads: both boards named, and the absence of
	//     the second said rather than left silent.
	{
		struct cons_display d;
		cons_set_tv_board(&c, 1);
		cons_set_color_tv(&c, 1);
		cons_read_display(&c, &d);
		capture_start();
		cons_say_display(&d);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "LISPM TV") != NULL,
			      "the line did not name the first board: %s", said);
			CHECK(strstr(said, "color TV is fitted") != NULL,
			      "the line did not say the color board is there: %s", said);
		}
		cons_set_color_tv(&c, 0);
		cons_read_display(&c, &d);
		capture_start();
		cons_say_display(&d);
		{
			const char *said = capture_end();
			CHECK(strstr(said, "no color TV") != NULL,
			      "the line did not say there is no color board: %s", said);
			CHECK(strstr(said, "NXM") != NULL,
			      "the line did not say what a machine with none does: %s", said);
		}
	}

	// 6.  **THE TWO COLOR MAPS, AND THEY ARE TWO.**  Sixteen colors of
	//     three channels each, out of pages 4 and 5; the values are
	//     injective in the board as well as the color, so a reader that
	//     took one board's page for the other's reads the wrong byte.
	{
		uint8_t got[2][CONS_MAP_COLORS][CONS_MAP_CHANNELS];
		int nonzero = 0, differ = 0;
		cons_read_color_map(&c, 0, got[0]);
		cons_read_color_map(&c, 1, got[1]);
		for (int b = 0; b < 2; ++b)
			for (int k = 0; k < CONS_MAP_COLORS; ++k)
				for (int ch = 0; ch < CONS_MAP_CHANNELS; ++ch) {
					CHECK(got[b][k][ch] == m.map[b][k][ch],
					      "the %s board's map at %d/%d is %u wanting %u",
					      b ? "color" : "first", k, ch,
					      got[b][k][ch], m.map[b][k][ch]);
					if (got[b][k][ch] != 0)
						++nonzero;
					if (b == 1 && got[1][k][ch] != got[0][k][ch])
						++differ;
				}
		// A map of zeros is what a face that answered nothing would
		// give, and two identical maps are what one store answering
		// both pages would give.
		CHECK(nonzero == 2 * CONS_MAP_COLORS * CONS_MAP_CHANNELS,
		      "only %d of the 96 map bytes came back non-zero", nonzero);
		CHECK(differ > 0, "the two boards' maps came back identical");
	}

	// 7.  And the channel order is red, green, blue --- `WRITE-COLOR-MAP`
	//     writes red on channel 0 --- which is the one thing about the map
	//     a renderer cannot get wrong quietly.
	{
		uint8_t got[CONS_MAP_COLORS][CONS_MAP_CHANNELS];
		const uint32_t w = ((uint32_t)0x11u << 16) | ((uint32_t)0x22u << 8) | 0x33u;
		m.map[1][5][0] = 0x11; m.map[1][5][1] = 0x22; m.map[1][5][2] = 0x33;
		CHECK(CONS_MAP_RED(w) == 0x11u, "CONS_MAP_RED is not the top byte");
		CHECK(CONS_MAP_GREEN(w) == 0x22u, "CONS_MAP_GREEN is not the middle byte");
		CHECK(CONS_MAP_BLUE(w) == 0x33u, "CONS_MAP_BLUE is not the bottom byte");
		cons_read_color_map(&c, 1, got);
		CHECK(got[5][0] == 0x11 && got[5][1] == 0x22 && got[5][2] == 0x33,
		      "the channels came back in another order: %u %u %u",
		      got[5][0], got[5][1], got[5][2]);
	}
}

static void check_log_prefix(void)
{
	// **THE RULE, AS A FUNCTION OF THE TWO THINGS IT IS ABOUT.**  A
	// terminal and no --log is a person, and only that.
	CHECK(strcmp(cons_log_prefix(0, 1), "") == 0,
	      "a reply to a terminal is not bare: it reads \"%s\"", cons_log_prefix(0, 1));
	CHECK(strcmp(cons_log_prefix(0, 0), CONS_LOG_PREFIX) == 0,
	      "a line to a pipe or a file does not name the program");
	CHECK(strcmp(cons_log_prefix(1, 1), CONS_LOG_PREFIX) == 0,
	      "a line written through --log does not name the program, though the caller "
	      "said where it was being kept");
	CHECK(strcmp(cons_log_prefix(2, 1), CONS_LOG_PREFIX) == 0,
	      "two --log destinations and a terminal gave a bare line");
	CHECK(strcmp(CONS_LOG_PREFIX, "cadr-console: ") == 0,
	      "the program's name in front of a kept line is not its own");

	// **AND THROUGH `say` ITSELF**, which is what the program calls: the
	// chooser and the routine together, since a chooser that is right and
	// a routine that ignores it would pass the four above.
	char *buf = NULL;
	size_t len = 0;
	FILE *m = open_memstream(&buf, &len);
	cadr_log_init(cons_log_prefix(0, 1), m);
	say("PC 0o5163");
	fflush(m);
	CHECK(buf && strcmp(buf, "PC 0o5163\n") == 0,
	      "a reply at a terminal came out as \"%s\", wanting the answer alone", buf ? buf : "");
	// The buffer belongs to the stream until it is closed, so the close
	// comes first.
	fclose(m);
	free(buf);
	buf = NULL;
	len = 0;

	m = open_memstream(&buf, &len);
	cadr_log_init(cons_log_prefix(0, 0), m);
	say("PC 0o5163");
	fflush(m);
	CHECK(buf && strcmp(buf, "cadr-console: PC 0o5163\n") == 0,
	      "a line into a pipe came out as \"%s\", wanting the program's name in front",
	      buf ? buf : "");
	fclose(m);
	free(buf);
	// Back to the capture the checks above use, so that nothing is left
	// pointing at a stream that has been closed.
	cadr_log_init("cadr-console: ", cap);
}

static void check_log_destinations(void)
{
	const char a[] = "two-a.log", b[] = "two-b.log";
	char pa[640], pb[640];
	snprintf(pa, sizeof pa, "%s", log_path(a));
	snprintf(pb, sizeof pb, "%s", log_path(b));
	unlink(pa);
	unlink(pb);

	// **TWO DESTINATIONS, ONE LINE, BOTH RECEIVE IT.**  This is the board:
	// /dev/console for whoever is watching the boot and a file for
	// whoever has only ssh.
	cadr_log_dest(pa);
	cadr_log_dest(pb);
	CHECK(cadr_log_dests() == 2, "two --log destinations were counted as %u",
	      cadr_log_dests());
	CHECK(cadr_log_open("cadr-console: ") == 0, "two log files could not be opened");
	say("the machine is RUNNING");
	CHECK(strcmp(first_line(pa), "cadr-console: the machine is RUNNING") == 0,
	      "the first destination reads \"%s\"", first_line(pa));
	CHECK(strcmp(first_line(pb), "cadr-console: the machine is RUNNING") == 0,
	      "the SECOND destination reads \"%s\": a line went to one of the two, which is "
	      "the board writing to the console and not to the file over ssh", first_line(pb));

	// **AND A LOG IS APPENDED TO AND NEVER TRUNCATED.**  A program
	// restarted by hand must not take away what the one before it said.
	cadr_log_dest(pa);
	CHECK(cadr_log_open("cadr-console: ") == 0, "the log could not be reopened");
	say("and again");
	CHECK(strcmp(first_line(pa), "cadr-console: the machine is RUNNING") == 0,
	      "reopening a log threw away what was in it: the first line is now \"%s\"",
	      first_line(pa));

	// **A LOG NOBODY CAN WRITE IS NOT A LOG.**  The program returns 2 on
	// this, and the message goes to stderr under the prefix; stderr is put
	// aside for the one call so that a passing run says nothing.
	cadr_log_dest(log_path("no-such-directory/x.log"));
	const int saved = dup(2), nul = open("/dev/null", O_WRONLY);
	if (nul >= 0)
		dup2(nul, 2);
	const int refused = cadr_log_open("cadr-console: ");
	if (saved >= 0)
		dup2(saved, 2);
	if (nul >= 0)
		close(nul);
	if (saved >= 0)
		close(saved);
	CHECK(refused < 0, "a --log that could not be opened was accepted, so the program "
	      "would go on with a log it has not got");

	unlink(pa);
	unlink(pb);
}

// **THE STREAM SOMETHING ELSE WRITES ITS OWN LINES THROUGH.**  The disk pack
// program hands its feeder a `FILE *` and the feeder writes eighteen kinds of
// line through it, the denied block among them.  Handed the first destination
// it would put those on the console and not in the file somebody over ssh is
// reading, so the library has a stream that fans out, and what goes through it
// is counted against the cap like everything else.
static void check_log_stream(void)
{
	const char a[] = "fan-a.log", b[] = "fan-b.log";
	char pa[640], pb[640];
	snprintf(pa, sizeof pa, "%s", log_path(a));
	snprintf(pb, sizeof pb, "%s", log_path(b));
	char one[700];
	snprintf(one, sizeof one, "%s.1", pa);
	unlink(pa);
	unlink(pb);
	unlink(one);

	cadr_log_dest(pa);
	cadr_log_dest(pb);
	CHECK(cadr_log_open("cadr-disk-packs: ") == 0, "two log files could not be opened");
	FILE *fan = cadr_log_stream();
	CHECK(fan != NULL, "there is no fan-out stream at all");
	if (!fan)
		return;
	// The caller's own line, prefix and all: what the feeder writes.
	fprintf(fan, "cadr-disk-packs: denied block 281/17/1 on unit 0\n");
	fflush(fan);
	CHECK(strcmp(first_line(pa), "cadr-disk-packs: denied block 281/17/1 on unit 0") == 0,
	      "the first destination reads \"%s\"", first_line(pa));
	CHECK(strcmp(first_line(pb), "cadr-disk-packs: denied block 281/17/1 on unit 0") == 0,
	      "the SECOND destination reads \"%s\": a line written through the stream went "
	      "to the console and not to the file over ssh", first_line(pb));

	// **AND WHAT GOES THROUGH IT IS COUNTED AGAINST THE CAP.**  The
	// feeder's lines are the bulk of that program's log, so a road to the
	// file that the cap did not watch would be the RAM disk filling by the
	// back door.
	const char *filler = "................................................"
			     "................................................";
	unsigned n = 0;
	while (file_size(one) < 0 && n < 200000u) {
		fprintf(fan, "line %u %s\n", n++, filler);
		fflush(fan);
	}
	CHECK(file_size(one) >= 0,
	      "%u lines went through the stream and nothing was rotated: the cap does not "
	      "watch the road the feeder's lines take", n);

	cadr_log_init("cadr-console: ", cap);
	unlink(pa);
	unlink(pb);
	unlink(one);
	char also[700];
	snprintf(also, sizeof also, "%s.1", pb);
	unlink(also);
}

// **THE CAP, WRITTEN PAST FOR REAL.**  The constant is 1 MiB and the check
// writes more than that rather than asking the routine to use a smaller one:
// a cap a check can lower is a cap the check does not hold.
static void check_log_cap(void)
{
	const char *p = log_path("capped.log");
	char one[700];
	snprintf(one, sizeof one, "%s.1", p);
	char two[700];
	snprintf(two, sizeof two, "%s.2", p);
	unlink(p);
	unlink(one);
	unlink(two);

	// A line of about a hundred characters, numbered, so that the FIRST
	// line of `<name>.1` says which generation it holds --- which is how a
	// rotation that appends to `.1` is told from one that replaces it.
	const char *filler = "................................................"
			     "................................................";
	cadr_log_dest(p);
	CHECK(cadr_log_open("") == 0, "the capped log could not be opened");

	unsigned n = 0;
	while (file_size(one) < 0 && n < 200000u)
		say("line %u %s", n++, filler);
	CHECK(file_size(one) >= 0,
	      "%u lines went in and nothing was rotated: a log with no cap is what fills "
	      "the board's RAM disk", n);
	CHECK(file_size(one) >= (long)CADR_LOG_MAX,
	      "the rotated file holds %ld bytes, under the %u the cap is: it was rotated "
	      "early", file_size(one), CADR_LOG_MAX);
	CHECK(file_size(p) >= 0 && file_size(p) < (long)CADR_LOG_MAX,
	      "the fresh file holds %ld bytes", file_size(p));
	CHECK(file_size(two) < 0, "a third generation %s was made: the cap is two files a "
	      "program and no more", two);
	CHECK(strncmp(first_line(one), "line 0 ", 7) == 0,
	      "the rotated file starts \"%.20s\", not at the first line written",
	      first_line(one));

	// **A SECOND ROTATION REPLACES THE FIRST AND MAKES NOTHING NEW.**
	const unsigned was = n;
	while (file_size(p) > 0 && strncmp(first_line(one), "line 0 ", 7) == 0 && n < 400000u)
		say("line %u %s", n++, filler);
	CHECK(strncmp(first_line(one), "line 0 ", 7) != 0,
	      "the second rotation did not replace %s: it still starts at the first line "
	      "ever written", one);
	CHECK(file_size(two) < 0, "a third generation appeared at the second rotation");
	CHECK(file_size(one) >= (long)CADR_LOG_MAX,
	      "the second generation was rotated at %ld bytes, not at the cap: the size is "
	      "not being counted from the rotation", file_size(one));
	CHECK(n > was, "the second rotation was not reached");

	// **AND A DESTINATION THIS LIBRARY DID NOT OPEN IS NEVER ROTATED**,
	// which is the /dev/console case seen from the side a check can see:
	// there is no name to rename.  A megabyte into a memory stream, and
	// the only thing asserted is that it is all still there.
	char *buf = NULL;
	size_t len = 0;
	FILE *m = open_memstream(&buf, &len);
	cadr_log_init("cadr-console: ", m);
	for (unsigned k = 0; k < 12000u; ++k)
		say("%s", filler);
	fflush(m);
	CHECK(len > CADR_LOG_MAX, "a stream this library did not open was capped at %zu "
	      "bytes: the cap reached a destination that has no name to rename", len);
	cadr_log_init("cadr-console: ", cap);
	fclose(m);
	free(buf);

	unlink(p);
	unlink(one);
	unlink(two);
}

int main(int argc, char **argv)
{
	(void)argc;
	log_scratch(argv[0]);
	capture_start();		/* nothing may print to the terminal but the verdict */
	check_ident();
	check_guard();
	check_halt_and_start();
	check_boot();
	check_held();
	check_trace_keys();
	check_trace_chaos();
	check_switch();
	check_step();
	check_flags();
	check_counters();
	check_regs();
	check_lost();
	check_machine_words();
	check_main_address();
	check_debug_cable();
	check_build();
	check_display();
	check_hdmi();
	check_lamps();
	// The logging last: these take the destinations away from the capture
	// above and put them back on files of their own.
	check_log_prefix();
	check_log_destinations();
	check_log_stream();
	check_log_cap();
	fflush(cap);

	if (bad) {
		fprintf(stderr, "console_test: %d of %u checks FAILED\n", bad, checks);
		return 1;
	}
	printf("ok: the console program drives the register face rtl/plumbing/cadr_console.sv defines, and\n"
	       "    says what it found\n"
	       "    %u checks against a model of the slave --- four pages of sixteen, the high\n"
	       "      halves latched by the low reads, UNMAPPED outside, bit 16 for a cycle\n"
	       "      nothing answered --- with a modeled machine behind the diagnostic bus\n"
	       "    IDENT \"CONS\", and \"NONE\", UNMAPPED, zeros and ones all refused\n"
	       "    the EMIO tally guard refuses all ones and all zeros and takes only the\n"
	       "      marker pattern (w & 0x80008000) == 0x00008000\n"
	       "    halt then status: SRUN down, CYCLES standing, the halt attributed to the\n"
	       "      console; start then status: CYCLES MEASURED to have moved\n"
	       "    boot: page 0's word 13 with \"BOOT\" on it presses the light panel's button\n"
	       "      --- RUN preset, the PC forced to zero, PROMDISABLE cleared --- on a halted\n"
	       "      machine and on a running one alike, counted and reported with the PC and\n"
	       "      CYCLES either side; twelve values that are not the key press nothing, and\n"
	       "      a modeled fabric that boots on any value is caught by the same twelve\n"
	       "    trace-keys: the pid file read and the right signal sent --- SIGUSR1 for on\n"
	       "      and SIGUSR2 for off, this process playing the daemon --- and a file\n"
	       "      holding 0, -1, nothing or a word REFUSED with nothing signaled, since\n"
	       "      kill(0) signals the whole process group and kill(-1) signals everything\n"
	       "    trace-chaos: the same pair of functions told the packet trace instead, the\n"
	       "      signal still going and the line naming the packet trace and the word that\n"
	       "      was typed, so that nobody is sent to the wrong log\n"
	       "    the held machine: start and step refuse while /var/run/cadr-held exists and\n"
	       "      say muir's own sentence for it, and boot presses the button and removes it\n"
	       "    SW0, the no-auto-boot switch, as two bits of STAT and not one: what it did at\n"
	       "      the last reset and where it is now, so that a machine that NEVER RAN is not\n"
	       "      reported as one somebody halted --- the two read exactly alike off FLAG-1 ---\n"
	       "      and so that a switch moved since the reset is said to have changed nothing\n"
	       "    step: ONE microcycle a step and exactly one, with SSDONE up --- read\n"
	       "      while STEP is still up, where it must be, since it falls two master\n"
	       "      clocks after the bit is lowered.  Both opposite failures are held as\n"
	       "      words too: a register block deaf to bit 1 clocks nothing and says so,\n"
	       "      and a STEP taken as a level runs away and says that\n"
	       "    FLAG-1's low byte through its inverting driver and FLAG-2's four floating\n"
	       "      ones, field by field against known words\n"
	       "    CYCLES low then high: the pair is one instant across a carry, the high word\n"
	       "      alone is a stale latch, and the other order is measurably wrong\n"
	       "    all sixteen registers read back as the model holds them, register 3 the\n"
	       "      open bus, a write aliasing onto EADR<2:0> as spy::write_strobe says\n"
	       "    a lost cycle reported lost and never mistaken for data\n"
	       "    page 0's words 7, 8 and 9 --- the virtual address register, Q and MD,\n"
	       "      which are on NO diagnostic register and which MIT's sixteen have no room\n"
	       "      for: read in that order because word 7's read latches Q AND MD beside it,\n"
	       "      so the three name one microcycle; words 8 and 9 alone are stale latches\n"
	       "      and the wrong order is measurably wrong; the page numbers are VMA<23:8>,\n"
	       "      Q<23:8> and MD<23:8>, a CADR page being 256 words; and the readings each\n"
	       "      say what they point at --- the same word, two words of one page, or two\n"
	       "      pages --- with every value printed and no name given to any comparison\n"
	       "    MD besides: that it is the word the LAST COMPLETED read left, a reference\n"
	       "      the map refuses starting no bus cycle at all; that it is to be compared\n"
	       "      with muir's md column; and that MD<23:8> is the map's index when MEMSTART\n"
	       "      is down (cadr_microcycle.sv:1006, the 74S258s at VMAS 1C20), so MD's page\n"
	       "      against VMA's is the entry a SRCMAP read looked at against the entry the\n"
	       "      machine read through --- printed both ways round.  All three reading\n"
	       "      UNMAPPED is a bitstream without these words and is refused as machine\n"
	       "      state; two of three is NOT, a machine being able to hold that word\n"
	       "    the debug cable's role, page 0's word 14: a board told nothing is a\n"
	       "      DEBUGGEE, the connect key takes the role and is counted, and its\n"
	       "      COMPLEMENT gives it back and counts nothing.  **ASKED IS NOT HAD**: with\n"
	       "      a debugger already on the connector the ask stands and the role does\n"
	       "      not, and the line says so rather than calling this board the debugger,\n"
	       "      which is the one thing two bits buy over one.  Twelve values that are\n"
	       "      not a key take nothing, and a modeled fabric that connects on any value\n"
	       "      is caught by the same twelve\n"
	       "    WHICH BUILD THE FABRIC IS, page 2's word 32: the stamp's five tree\n"
	       "      nibbles and a sixth the format does not define, each with a commit\n"
	       "      of its own, and all ones --- which is what an unprogrammed part reads\n"
	       "      and the one value no build can be --- reported as no stamp and never\n"
	       "      as a commit.  A dirty build is said to be one TWICE, because its\n"
	       "      commit names where it started and not what it is.  The word comes\n"
	       "      back off page 2 and `status` carries it, so one command answers it\n"
	       "    WHETHER THE LAMPS BLINK, page 2's word 35: the key makes them steady and\n"
	       "      its complement makes them blink, asked twice is still steady, and the\n"
	       "      line says which in words; a word with no marker is an older fabric\n"
	       "    and WHICH BUILD THE PROGRAM IS, which is the other half: muir's shape,\n"
	       "      the commit dropped rather than guessed when there is none\n"
	       "    the logging, which is cadr-common's routine held by the check that builds\n"
	       "      it: a reply to a person at a terminal is BARE and a line that is kept ---\n"
	       "      a pipe, a file, an init script\'s --log --- names its program; --log given\n"
	       "      twice puts every line in both places, which is the board writing to the\n"
	       "      serial console and to a file somebody over ssh can follow; a log is\n"
	       "      appended to and never truncated, and one that cannot be opened is\n"
	       "      refused rather than carried on without; a stream handed to something\n"
	       "      that writes its own lines --- the disk pack program's feeder --- reaches\n"
	       "      every destination and is counted against the cap like everything else;\n"
	       "      and a file destination is\n"
	       "      rotated to <name>.1 at 1 MiB with no third generation ever made, written\n"
	       "      past for real, because the root filesystem is a RAM disk\n", checks);
	return 0;
}
