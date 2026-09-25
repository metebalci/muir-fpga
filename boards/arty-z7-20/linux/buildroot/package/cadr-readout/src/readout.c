// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The readout window, driven.  `readout.h` says what it is.

#include "readout.h"

#include <stdlib.h>
#include <string.h>

int ro_ident_ok(struct readout *r, uint32_t *got)
{
	uint32_t v = r->read(r, RO_IDENT);
	++r->reads;
	if (got)
		*got = v;
	return v == RO_IDENT_WORD ? 0 : -1;
}

int ro_word(struct readout *r, unsigned sel, unsigned addr, uint64_t *word)
{
	const uint32_t asked = ((uint32_t)(sel & 0xFu) << 14) |
			       (uint32_t)(addr & 0x3FFFu);
	r->write(r, RO_ADDR, asked);
	++r->writes;
	// **THE ECHO IS READ FIRST AND IT IS WHAT ARMS THE OTHER TWO.**  A
	// read of word 10 latches the echo and both halves together, so the
	// three name one instant of the pipeline; reading the halves without
	// it would give whatever the last read of word 10 left.
	const uint32_t echo = r->read(r, RO_ADDR);
	const uint32_t lo = r->read(r, RO_DATA_LO);
	const uint32_t hi = r->read(r, RO_DATA_HI);
	r->reads += 3;
	if (echo != asked) {
		++r->stale;
		return -1;
	}
	*word = (uint64_t)lo | ((uint64_t)(hi & 0xFFFFu) << 32);
	return 0;
}

int ro_block(struct readout *r, unsigned sel, unsigned n, uint64_t *into)
{
	for (unsigned i = 0; i < n; ++i)
		if (ro_word(r, sel, i, &into[i]) != 0)
			return -1;
	return 0;
}

int ro_block32(struct readout *r, unsigned sel, unsigned n, uint32_t *into)
{
	for (unsigned i = 0; i < n; ++i) {
		uint64_t w = 0;
		if (ro_word(r, sel, i, &w) != 0)
			return -1;
		into[i] = (uint32_t)w;
	}
	return 0;
}

void ro_halt(struct readout *r)
{
	r->write(r, RO_SPY(RO_SPY_CLK_W), 0);
	++r->writes;
}

void ro_start(struct readout *r)
{
	r->write(r, RO_SPY(RO_SPY_CLK_W), RO_CLK_RUN);
	++r->writes;
}

// SRUN as the master clock registered it, FLAG-1 bit 8.  A halted machine has
// it down; a machine `HALT-CONS` stopped under ERRSTOP has it UP with ERR up
// beside it, which is why this asks the microcycle counter as well.
int ro_is_halted(struct readout *r)
{
	const uint64_t a = ro_cycles(r);
	// Two reads with a little work between them.  Nothing here sleeps ---
	// the program has no reason to and a board that is running retires
	// thousands of microcycles in the time an AXI round trip takes.
	for (int i = 0; i < 16; ++i)
		(void)r->read(r, RO_STAT);
	r->reads += 16;
	const uint64_t b = ro_cycles(r);
	return a == b;
}

int ro_mem_drained(struct readout *r)
{
	uint64_t w = 0;
	if (ro_word(r, IMG_SEL_REGS, IMG_RG_FLAGS, &w) != 0)
		return -1;
	return (int)((w >> IMG_F_MEM_DRAINED) & 1u);
}

uint64_t ro_cycles(struct readout *r)
{
	const uint32_t lo = r->read(r, RO_CYCLES);
	const uint32_t hi = r->read(r, RO_CYCLESH);
	r->reads += 2;
	return (uint64_t)lo | ((uint64_t)hi << 32);
}

int ro_color_map(struct readout *r, int board,
		 uint8_t map[RO_MAP_COLORS][RO_MAP_CHANNELS])
{
	int any = 0;
	for (int c = 0; c < RO_MAP_COLORS; ++c) {
		const uint32_t w = r->read(r, RO_COLOR_MAP_WORD(board, c));
		map[c][0] = (uint8_t)((w >> 16) & 0xFFu);
		map[c][1] = (uint8_t)((w >> 8) & 0xFFu);
		map[c][2] = (uint8_t)(w & 0xFFu);
		if (map[c][0] || map[c][1] || map[c][2])
			any = 1;
	}
	return any;
}

uint64_t ro_ticks(struct readout *r)
{
	const uint32_t lo = r->read(r, RO_TICKS);
	const uint32_t hi = r->read(r, RO_TICKSH);
	r->reads += 2;
	return (uint64_t)lo | ((uint64_t)hi << 32);
}

int ro_read_machine(struct readout *r, struct cadr_image *img)
{
	if (ro_block(r, IMG_SEL_PROM, IMG_PROM_WORDS, img->prom) != 0)
		return -1;
	if (ro_block(r, IMG_SEL_IMEM, IMG_IMEM_WORDS, img->imem) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_AMEM, IMG_AMEM_WORDS, img->amem) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_MMEM, IMG_MMEM_WORDS, img->mmem) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_PDL, img->pdl_words, img->pdl) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_SPC, IMG_SPC_WORDS, img->spc) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_DMEM, IMG_DMEM_WORDS, img->dmem) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_MAP1, IMG_L1_WORDS, img->l1_map) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_MAP2, img->l2_words, img->l2_map) != 0)
		return -1;
	for (unsigned i = 0; i < IMG_OPCS; ++i) {
		uint64_t w = 0;
		if (ro_word(r, IMG_SEL_OPCS, i, &w) != 0)
			return -1;
		img->opcs[i] = (uint16_t)w;
	}

	uint64_t v[21];
	for (unsigned i = 0; i < 21; ++i)
		if (ro_word(r, IMG_SEL_REGS, i, &v[i]) != 0)
			return -1;
	img->pc = (uint16_t)v[IMG_RG_PC];
	img->lpc = (uint16_t)v[IMG_RG_LPC];
	img->ir = v[IMG_RG_IR];
	img->iwr = v[IMG_RG_IWR];
	img->l = (uint32_t)v[IMG_RG_L];
	img->q = (uint32_t)v[IMG_RG_Q];
	img->vma = (uint32_t)v[IMG_RG_VMA];
	img->md = (uint32_t)v[IMG_RG_MD];
	img->st = (uint32_t)v[IMG_RG_ST];
	img->lc = (uint32_t)v[IMG_RG_LC];
	img->wadr = (uint16_t)v[IMG_RG_WADR];
	img->pdl_ptr = (uint16_t)v[IMG_RG_PDLPTR];
	img->pdl_idx = (uint16_t)v[IMG_RG_PDLIDX];
	img->spcptr = (uint8_t)v[IMG_RG_SPCPTR];
	img->reta = (uint16_t)v[IMG_RG_RETA];
	img->dc = (uint16_t)v[IMG_RG_DC];
	img->lvmo = (uint32_t)v[IMG_RG_LVMO];
	img->md_held = (uint32_t)v[IMG_RG_MDHELD];
	img->phys_r = (uint32_t)v[IMG_RG_PHYS];
	img->speed = (uint8_t)(v[IMG_RG_SPEED] & 3u);
	img->speed_a = (uint8_t)((v[IMG_RG_SPEED] >> 2) & 3u);
	img->mode_speed = (uint8_t)((v[IMG_RG_SPEED] >> 4) & 3u);
	img->flags = v[IMG_RG_FLAGS];

	img->cycles = ro_cycles(r);
	img->ticks = ro_ticks(r);
	if (img->quux)
		return ro_read_quux(r, img);
	return 0;
}

int ro_machine_is_quux(struct readout *r, unsigned *k, unsigned *l)
{
	uint64_t w = 0;
	if (ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_ID, &w) != 0)
		return -1;
	if (w == RO_NO_MEMORY)
		return 0;
	if (((w >> 32) & 0xFFFFu) != IMG_QUUX_MARK || (w & 0xFFFFu) != 0)
		return -1;
	if (k)
		*k = (unsigned)((w >> 24) & 0xFFu);
	if (l)
		*l = (unsigned)((w >> 16) & 0xFFu);
	return 1;
}

// muir's clock at a word of the microsecond clock: ticks since power-on,
// `usec * 100 + 99 - usec_t` (`quux_clocks.sv`), the thirty-two bits of
// microseconds unwrapped against `ticks`, the console's count since the
// machine's reset, which is two ticks ahead of power-on
// (`cadr_tick_pkg::POWER_ON_EDGES`) and a little behind the word.
#define RO_TICKS_A_US 100u
#define RO_USEC_WRAP  (((uint64_t)1 << 32) * RO_TICKS_A_US)
static uint64_t quux_m(uint64_t time_word, uint64_t ticks)
{
	const uint64_t usec = time_word & 0xFFFFFFFFull;
	const uint64_t usec_t = (time_word >> 32) & 0x7Fu;
	const uint64_t low = usec * RO_TICKS_A_US + (RO_TICKS_A_US - 1u) - usec_t;
	uint64_t n = 0;
	if (ticks > low)
		n = (ticks - low + RO_USEC_WRAP / 2u) / RO_USEC_WRAP;
	return low + n * RO_USEC_WRAP;
}

// A timer's word, and the tick it was taken at: the word's own seven low
// bits of the microsecond count and its prescaler, unwrapped against the
// whole count `m0` read just before it.
static void quux_timer(uint64_t w, uint64_t m0, struct quux_timer *t)
{
	const uint64_t u0 = m0 / RO_TICKS_A_US;
	const uint64_t low = (w >> 41) & 0x7Fu;
	const uint64_t usec_t = (w >> 34) & 0x7Fu;
	const uint64_t u = u0 + ((low - u0) & 0x7Fu);
	t->m = u * RO_TICKS_A_US + (RO_TICKS_A_US - 1u) - usec_t;
	t->en = (int)((w >> 33) & 1u);
	t->sticky = (int)((w >> 32) & 1u);
	t->live = (int)((w >> 31) & 1u);
	t->pre = (unsigned)((w >> 24) & 0x7Fu);
	t->us = (uint32_t)(w & 0xFFFFFFu);
}

int ro_read_quux(struct readout *r, struct cadr_image *img)
{
	struct quux_state *q = &img->qx;
	uint64_t t0 = 0, t1 = 0, wt = 0, wi = 0, w = 0;
	int held = 0;
	// Which machine, and its K and L: a CADR's bitstream answers none of
	// what follows, and its absence is not a machine of zeros.
	if (ro_machine_is_quux(r, &q->k, &q->l) != 1)
		return -1;
	for (int i = 0; i < RO_QUUX_TRIES && !held; ++i) {
		const uint64_t ticks = ro_ticks(r);
		if (ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_TIME, &t0) != 0 ||
		    ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_TICK, &wt) != 0 ||
		    ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_INTERVAL, &wi) != 0 ||
		    ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_TIME, &t1) != 0)
			return -1;
		const uint64_t m0 = quux_m(t0, ticks), m1 = quux_m(t1, ticks);
		if (m1 >= m0 && m1 - m0 <= RO_QUUX_SPAN) {
			held = 1;
			q->m = m0;
		}
	}
	if (!held)
		return -1;
	quux_timer(wt, q->m, &q->timer[0]);
	quux_timer(wi, q->m, &q->timer[1]);
	if (ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_PERIOD, &w) != 0)
		return -1;
	q->interval_us = (uint32_t)(w & 0xFFFFFFu);

	if (ro_word(r, IMG_SEL_QUUX_PAGE, IMG_QP_INPUT, &w) != 0)
		return -1;
	q->head = (unsigned)((w >> 38) & 0x3Fu);
	q->count = (unsigned)((w >> 31) & 0x7Fu);
	q->overflowed = (int)((w >> 30) & 1u);
	q->kbd_enable = (int)((w >> 29) & 1u);
	q->mouse_changed = (int)((w >> 28) & 1u);
	q->mouse_enable = (int)((w >> 27) & 1u);
	q->buttons = (unsigned)((w >> 24) & 7u);
	q->y = (unsigned)((w >> 12) & 0xFFFu);
	q->x = (unsigned)(w & 0xFFFu);
	if (q->count > IMG_QUUX_FIFO_WORDS)
		return -1;
	// The words waiting, `count` of them from `head`; a key word that
	// arrives meanwhile lands at the tail, past them.
	for (unsigned i = 0; i < q->count; ++i) {
		const unsigned at = (q->head + i) % IMG_QUUX_FIFO_WORDS;
		if (ro_word(r, IMG_SEL_QUUX_PAGE, IMG_QP_FIFO + at, &w) != 0)
			return -1;
		q->fifo[at] = (uint32_t)(w & 0xFFFFFFu);
	}

	uint64_t d[4];
	for (unsigned i = 0; i < 4; ++i)
		if (ro_word(r, IMG_SEL_QUUX_PAGE, IMG_QP_CMD + i, &d[i]) != 0)
			return -1;
	q->cmd = (uint32_t)d[0];
	q->clp = (uint32_t)d[1];
	q->da = (uint32_t)d[2];
	q->lma = (uint32_t)d[3];
	if (ro_word(r, IMG_SEL_QUUX_PAGE, IMG_QP_DISK, &w) != 0)
		return -1;
	q->since_done = (int32_t)(uint32_t)w;
	q->walking = (int)((w >> 38) & 1u);
	q->walked = (int)((w >> 37) & 1u);
	q->not_active = (int)((w >> 36) & 1u);
	q->past_end = (int)((w >> 35) & 1u);
	q->nxm = (int)((w >> 34) & 1u);
	q->bad_command = (int)((w >> 33) & 1u);
	q->present = (int)((w >> 32) & 1u);

	if (ro_word(r, IMG_SEL_QUUX_PAGE, IMG_QP_PAGE, &w) != 0)
		return -1;
	q->bus_error = (unsigned)(w & 077u);
	q->bow = (int)((w >> 8) & 1u);
	return 0;
}

int ro_audit(struct readout *r, struct cadr_audit *a, unsigned *mark)
{
	uint64_t w[IMG_AUDIT_WORDS];
	if (mark)
		*mark = 0;
	for (unsigned i = 0; i < IMG_AUDIT_WORDS; ++i) {
		if (ro_word(r, IMG_SEL_AUDIT, i, &w[i]) != 0)
			return -1;
		// **THE MARKER IS CHECKED BEFORE ANYTHING IS BELIEVED.**  A
		// bitstream with no audit in it answers the window's own
		// `A5A5_5A5A_A5A5` here, and an undriven path answers all
		// ones or all zeros; each of the three would otherwise read
		// as a clean instrument.
		if (((w[i] >> 32) & 0xFFFFu) != IMG_AUDIT_MARK) {
			if (mark)
				*mark = (unsigned)((w[i] >> 32) & 0xFFFFu);
			return -1;
		}
	}
	a->faults = (unsigned)(w[0] & 0x7FFFu);
	a->stalled = (unsigned)((w[0] >> 16) & 0x7FFFu);
	a->phys = (uint32_t)(w[1] & 0x3FFFFFu);
	a->clause = (unsigned)((w[1] >> 22) & 7u);
	a->seen = (unsigned)((w[1] >> 25) & 0x7Fu);
	a->addr = (uint32_t)w[2];
	a->data = (uint32_t)w[3];
	a->vma = (uint32_t)w[4];
	a->md = (uint32_t)w[5];
	a->micro = (uint32_t)w[6];
	a->opc = (unsigned)(w[7] & 0x3FFFu);
	a->pc = (unsigned)((w[7] >> 16) & 0x3FFFu);
	a->port_reads = (unsigned)(w[8] & 0x7FFFu);
	a->port_writes = (unsigned)((w[8] >> 16) & 0x7FFFu);
	return 0;
}

int img_alloc(struct cadr_image *img, unsigned boards)
{
	return img_alloc_machine(img, boards, 0);
}

int img_alloc_machine(struct cadr_image *img, unsigned boards, int quux)
{
	memset(img, 0, sizeof *img);
	img->boards = boards;
	img->quux = quux != 0;
	img->pdl_words = quux ? IMG_QUUX_PDL_WORDS : IMG_PDL_WORDS;
	img->l2_words = quux ? IMG_QUUX_L2_WORDS : IMG_L2_WORDS;
	img->tv_words = quux ? IMG_QUUX_TV_WORDS : IMG_TV_WORDS;
	img->prom = calloc(IMG_PROM_WORDS, sizeof *img->prom);
	img->imem = calloc(IMG_IMEM_WORDS, sizeof *img->imem);
	img->amem = calloc(IMG_AMEM_WORDS, sizeof *img->amem);
	img->mmem = calloc(IMG_MMEM_WORDS, sizeof *img->mmem);
	img->pdl = calloc(img->pdl_words, sizeof *img->pdl);
	img->spc = calloc(IMG_SPC_WORDS, sizeof *img->spc);
	img->dmem = calloc(IMG_DMEM_WORDS, sizeof *img->dmem);
	img->l1_map = calloc(IMG_L1_WORDS, sizeof *img->l1_map);
	img->l2_map = calloc(img->l2_words, sizeof *img->l2_map);
	img->main = calloc((size_t)boards * IMG_BOARD_WORDS, sizeof *img->main);
	img->tv = calloc(img->tv_words, sizeof *img->tv);
	if (!img->prom || !img->imem || !img->amem || !img->mmem || !img->pdl ||
	    !img->spc || !img->dmem || !img->l1_map || !img->l2_map ||
	    !img->main || !img->tv) {
		img_free(img);
		return -1;
	}
	return 0;
}

void img_free(struct cadr_image *img)
{
	free(img->prom);
	free(img->imem);
	free(img->amem);
	free(img->mmem);
	free(img->pdl);
	free(img->spc);
	free(img->dmem);
	free(img->l1_map);
	free(img->l2_map);
	free(img->main);
	free(img->tv);
	memset(img, 0, sizeof *img);
}
