// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The readout window, driven.  `readout.h` says what it is.

#include "readout.h"

#include <stdio.h>
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

// QUUX's: the same, the face's word 12 carrying `<63:32>` whole.
// **THE ECHO MOVES WHEN THE WORD IS THERE**, some clocks after the address
// (`quux15_face.sv`), and a read can reach the face before the write that
// asked: so the echo is read again, each read latching the halves anew,
// until it names the address, `RO_ECHO_TRIES` times at most.
#define RO_ECHO_TRIES 64
int ro_word64(struct readout *r, unsigned sel, unsigned addr, uint64_t *word)
{
	const uint32_t asked = ((uint32_t)(sel & 0xFu) << 14) |
			       (uint32_t)(addr & 0x3FFFu);
	r->write(r, RO_ADDR, asked);
	++r->writes;
	for (int tries = 0; tries < RO_ECHO_TRIES; ++tries) {
		const uint32_t echo = r->read(r, RO_ADDR);
		++r->reads;
		if (echo != asked)
			continue;
		const uint32_t lo = r->read(r, RO_DATA_LO);
		const uint32_t hi = r->read(r, RO_DATA_HI);
		r->reads += 2;
		*word = (uint64_t)lo | ((uint64_t)hi << 32);
		return 0;
	}
	++r->stale;
	return -1;
}

static int ro_block64(struct readout *r, unsigned sel, unsigned n, uint64_t *into)
{
	for (unsigned i = 0; i < n; ++i)
		if (ro_word64(r, sel, i, &into[i]) != 0)
			return -1;
	return 0;
}

int ro_block(struct readout *r, unsigned sel, unsigned n, uint64_t *into)
{
	for (unsigned i = 0; i < n; ++i)
		if (ro_word(r, sel, i, &into[i]) != 0)
			return -1;
	return 0;
}

// A run of words at `bits`, the rest of the window's 48 dropped: 32 on the
// CADR, and 40 on QUUX.
static int ro_block_words(struct readout *r, unsigned sel, unsigned n, unsigned bits,
			  uint64_t *into)
{
	if (ro_block(r, sel, n, into) != 0)
		return -1;
	for (unsigned i = 0; i < n; ++i)
		into[i] &= ((uint64_t)1 << bits) - 1u;
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

// Not SRUN, FLAG-1 bit 8: a machine `HALT-CONS` stopped under ERRSTOP has it
// UP with ERR up beside it.  The microcycle counter standing still is what
// halted means: for `RO_HALT_SETTLE_TICKS` together, at some point within
// `RO_HALT_WITHIN_TICKS` (readout.h says why).
int ro_is_halted(struct readout *r)
{
	uint64_t c = ro_cycles(r);
	const uint64_t t0 = ro_ticks(r);
	uint64_t since = t0;
	for (unsigned n = 0; n < RO_HALT_MAX_READS; ++n) {
		const uint64_t now_c = ro_cycles(r);
		const uint64_t now_t = ro_ticks(r);
		if (now_c != c) {
			c = now_c;
			since = now_t;
		} else if (now_t - since >= RO_HALT_SETTLE_TICKS) {
			return 1;
		}
		if (now_t - t0 >= RO_HALT_WITHIN_TICKS)
			return 0;
	}
	return 0;
}

int ro_halt_to_read(struct readout *r, int *was_running)
{
	*was_running = !ro_is_halted(r);
	if (*was_running)
		ro_halt(r);
	if (ro_is_halted(r))
		return 0;
	if (*was_running)
		ro_start(r);
	return -1;
}

// `readout.h` says what halted means here and why CYCLES alone is not it.
int ro_found(struct readout *r, int rev15, struct ro_stand *s)
{
	memset(s, 0, sizeof *s);
	s->drained = -1;
	if (!ro_is_halted(r))
		return RO_FOUND_RUNNING;
#if CHK_MUTATE == 49
	// A checkpoint mutant: a counter standing still taken as a halt.
	(void)rev15;
	return RO_FOUND_HALTED;
#else
	s->cycles = ro_cycles(r);
	const uint32_t f1 = r->read(r, RO_SPY(RO_SPY_FLAG_1));
	const uint32_t pc = r->read(r, RO_SPY(RO_SPY_PC));
	const uint32_t opc = r->read(r, RO_SPY(RO_SPY_OPC));
	r->reads += 3;
	// Bit 16 is the whole answer when it is up: a diagnostic cycle the
	// register block did not answer, with no data under it.
	if ((f1 | pc | opc) & RO_LOST_BIT)
		return RO_FOUND_LOST;
	s->read = 1;
	s->flag1 = (uint16_t)f1;
	// `cons_flag1_of`'s senses: -WAIT and -STATHALT are active low.
	s->wait = !(f1 & (1u << 15));
	s->stathalt = !(f1 & (1u << 11));
	s->err = !!(f1 & (1u << 10));
	s->srun = !!(f1 & (1u << 8));
	s->pc = (uint16_t)(pc & 0x3FFFu);
	s->opc = (uint16_t)(opc & 0x3FFFu);
	if (rev15) {
		uint64_t w = 0;
		if (ro_word64(r, IMG_SEL_TAIL, IMG_TL15_HALTED, &w) != 0)
			return RO_FOUND_LOST;
		s->drained = (int)(w & 1u);
#if CHK_MUTATE == 50
		// A checkpoint mutant: QUUX's halt read off SRUN, which
		// follows RUN whether or not the drain ends.
		return !s->srun ? RO_FOUND_HALTED : RO_FOUND_STUCK;
#else
		return s->drained ? RO_FOUND_HALTED : RO_FOUND_STUCK;
#endif
	}
	return (!s->srun || s->err || s->stathalt) ? RO_FOUND_HALTED : RO_FOUND_STUCK;
#endif
}

void ro_stand_text(const struct ro_stand *s, int rev15, char *out, size_t n)
{
	if (!s->read) {
		snprintf(out, n, "CYCLES stood still for 2 ms, and FLAG-1, PC and OPC were "
			 "not answered");
		return;
	}
	const int at = snprintf(out, n, "CYCLES stood at %llu for 2 ms with SRUN %s, ERR %s, "
				"-STATHALT %s, -WAIT %s (FLAG-1 0x%04x), PC %o, OPC %o",
				(unsigned long long)s->cycles, s->srun ? "up" : "down",
				s->err ? "up" : "down", s->stathalt ? "low" : "high",
				s->wait ? "low" : "high", s->flag1, s->pc, s->opc);
	if (at < 0 || (size_t)at >= n)
		return;
	if (rev15)
		snprintf(out + at, n - (size_t)at, "; the pipeline has its halted bit %s%s",
			 s->drained == 1 ? "up" : s->drained == 0 ? "down: it has not drained" : "unread",
			 s->drained == 0 ? ", which a pipeline stopped at an error (OA-OUTSIDE-FIELDS, "
					   "PDL-FIELD-MISMATCH) shows too" : "");
	else
		snprintf(out + at, n - (size_t)at, "; with SRUN up, FLAG-1 names no halt%s",
			 s->wait ? ", and -WAIT low is a bus cycle that has not ended" : "");
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
	// QUUX's window is its own (`ro_read_quux15`).
	if (img->quux)
		return ro_read_quux15(r, img);
	if (ro_block(r, IMG_SEL_PROM, IMG_PROM_WORDS, img->prom) != 0)
		return -1;
	if (ro_block(r, IMG_SEL_IMEM, IMG_IMEM_WORDS, img->imem) != 0)
		return -1;
	const unsigned wb = img->word_bits;
	const uint64_t word = ((uint64_t)1 << wb) - 1u;
	if (ro_block_words(r, IMG_SEL_AMEM, IMG_AMEM_WORDS, wb, img->amem) != 0)
		return -1;
	if (ro_block_words(r, IMG_SEL_MMEM, IMG_MMEM_WORDS, wb, img->mmem) != 0)
		return -1;
	if (ro_block_words(r, IMG_SEL_PDL, img->pdl_words, wb, img->pdl) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_SPC, IMG_SPC_WORDS, img->spc) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_DMEM, img->dmem_words, img->dmem) != 0)
		return -1;
	if (ro_block32(r, IMG_SEL_MAP1, img->l1_words, img->l1_map) != 0)
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
	img->l = v[IMG_RG_L] & word;
	img->q = v[IMG_RG_Q] & word;
	img->vma = v[IMG_RG_VMA] & word;
	img->md = v[IMG_RG_MD] & word;
	img->st = (uint32_t)v[IMG_RG_ST];
	img->lc = (uint32_t)v[IMG_RG_LC];
	img->wadr = (uint16_t)v[IMG_RG_WADR];
	img->pdl_ptr = (uint16_t)v[IMG_RG_PDLPTR];
	img->pdl_idx = (uint16_t)v[IMG_RG_PDLIDX];
	img->spcptr = (uint8_t)v[IMG_RG_SPCPTR];
	img->reta = (uint16_t)v[IMG_RG_RETA];
	img->dc = (uint16_t)v[IMG_RG_DC];
	img->lvmo = (uint32_t)v[IMG_RG_LVMO];
	img->md_held = v[IMG_RG_MDHELD] & word;
	img->phys_r = (uint32_t)v[IMG_RG_PHYS];
	img->speed = (uint8_t)(v[IMG_RG_SPEED] & 3u);
	img->speed_a = (uint8_t)((v[IMG_RG_SPEED] >> 2) & 3u);
	img->mode_speed = (uint8_t)((v[IMG_RG_SPEED] >> 4) & 3u);
	img->flags = v[IMG_RG_FLAGS];

	img->cycles = ro_cycles(r);
	img->ticks = ro_ticks(r);
	return 0;
}

int ro_machine_is_quux(struct readout *r, unsigned *k, unsigned *l)
{
	uint64_t w = 0;
	if (ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_ID, &w) != 0)
		return -1;
	if (w == RO_NO_MEMORY)
		return 0;
	// MACHINE-ID's <15:0>: 0, revision 12's, or a revision over the
	// processor type 4.
	const unsigned id = (unsigned)(w & 0xFFFFu);
	if (((w >> 32) & 0xFFFFu) != IMG_QUUX_MARK ||
	    (id != 0 && ((id & 0xFu) != IMG_QUUX_ID_TYPE || ((id >> 4) & 0xFFu) == 0)))
		return -1;
	if (k)
		*k = (unsigned)((w >> 24) & 0xFFu);
	if (l)
		*l = (unsigned)((w >> 16) & 0xFFu);
	return 1;
}

int ro_quux_revision(struct readout *r)
{
	uint64_t w = 0;
	const int is = ro_machine_is_quux(r, NULL, NULL);
	if (is != 1)
		return is;
	if (ro_word(r, IMG_SEL_REGS, IMG_RG_QUUX_ID, &w) != 0)
		return -1;
	// MACHINE-ID's revision, <11:4>, as the identity line reads it; 0
	// there was revision 12's.
	return (w & 0xFFFFu) == 0 ? 12 : (int)((w >> 4) & 0xFFu);
}

const char *const ro_machine_names[RO_MACHINES] = { "the CADR", "QUUX" };

int ro_machine_of(int rev)
{
	if (rev == 0)
		return RO_M_CADR;
	if (rev == IMG_QUUX_REVISION)
		return RO_M_QUUX15;
	return -1;
}

// `readout.h` says what each column is.  QUUX's: `quux15_core.sv`'s
// `rm_word`, the control store and the PROM 64 bits, A, M and the PDL buffer
// `{24'd0, word}`, the micro-stack 19 bits, dispatch memory 17 over 4,096
// entries, the OPCs 14, the register table `reg_field`'s 23 entries, and
// `RO_NO_MEMORY` at the map levels' and the audit's selectors.
#define SAME(v) { v, v }
const struct ro_mem ro_mems[] = {
	{ "imem",  IMG_SEL_IMEM, SAME(IMG_IMEM_WORDS), { 48, 64 }, "the control store" },
	{ "prom",  IMG_SEL_PROM, SAME(IMG_PROM_WORDS), { 48, 64 }, "the boot PROM" },
	{ "amem",  IMG_SEL_AMEM, SAME(IMG_AMEM_WORDS), { 32, 40 }, "the A memory" },
	{ "mmem",  IMG_SEL_MMEM, SAME(IMG_MMEM_WORDS), { 32, 40 }, "the M memory" },
	{ "pdl",   IMG_SEL_PDL, { IMG_PDL_WORDS, IMG_QUUX_PDL_WORDS }, { 32, 40 },
	  "the pushdown buffer" },
	{ "spc",   IMG_SEL_SPC,  SAME(IMG_SPC_WORDS), SAME(19), "the micro-stack" },
	{ "dmem",  IMG_SEL_DMEM, { IMG_DMEM_WORDS, IMG_DMEM_WORDS_13 }, SAME(17),
	  "the dispatch memory" },
	{ "map1",  IMG_SEL_MAP1, { IMG_L1_WORDS, 0 }, { 5, 0 }, "the level-1 map" },
	{ "map2",  IMG_SEL_MAP2, { IMG_L2_WORDS, 0 }, { 24, 0 }, "the level-2 map" },
	{ "opcs",  IMG_SEL_OPCS, SAME(IMG_OPCS), SAME(14), "the OPC shift register" },
	{ "regs",  IMG_SEL_REGS, { 21, IMG_RG15_COUNT }, { 48, 64 },
	  "the register table below" },
	{ "audit", IMG_SEL_AUDIT, { IMG_AUDIT_WORDS, 0 }, { 48, 0 },
	  "the transaction audit; --audit decodes it" },
};
#undef SAME
const unsigned ro_mem_count = sizeof ro_mems / sizeof ro_mems[0];

const struct ro_mem *ro_mem_by_name(const char *name)
{
	for (unsigned i = 0; i < ro_mem_count; ++i)
		if (!strcmp(name, ro_mems[i].name))
			return &ro_mems[i];
	return NULL;
}

int ro_mem_word(struct readout *r, int machine, const struct ro_mem *m, unsigned addr,
		uint64_t *word)
{
	if (machine == RO_M_QUUX15)
		return ro_word64(r, m->sel, addr, word);
	return ro_word(r, m->sel, addr, word);
}

// The CADR's order, `cadr_microcycle.sv`'s, and QUUX's,
// `quux15_core.sv`'s `reg_field`.
static const char *const kRegNames[21] = {
	"PC", "LPC", "IR", "IWR", "L", "Q", "VMA", "MD", "ST", "LC",
	"WADR", "PDL-POINTER", "PDL-INDEX", "SPCPTR", "RETA", "DC", "LVMO",
	"MD-HELD", "PHYS", "SPEED", "FLAGS"
};
static const char *const kRegNames15[IMG_RG15_COUNT] = {
	"Q", "VMA", "MD", "LC", "PDL-POINTER", "PDL-INDEX", "SPCPTR",
	"INT-CONTROL", "DC", "FLAGS", "OPC", "MACRO-DISPATCH", "MACRO-INDEX",
	"BASES", "ARMED", "DIRECTORY", "TYPES", "REFUSED", "COPIES", "POSTED",
	"CLOCKS", "ID", "COMMITTED"
};

const char *const *ro_reg_names(int machine)
{
	return machine == RO_M_QUUX15 ? kRegNames15 : kRegNames;
}

int ro_video(struct readout *r, struct cadr_video *v)
{
	return cadr_video_decode(r->read(r, RO_VIDEO), v);
}

unsigned ro_main_boards(struct readout *r)
{
	const uint32_t w = r->read(r, RO_BOARDS);
	if ((w >> 16) != RO_BOARDS_MARK)
		return 0;
	const unsigned n = w & 0xFFFFu;
	return (n >= 1u && n <= RO_BOARDS_MAX) ? n : 0u;	/* bits 15:11 clear below 1,024 */
}

void ro_main_amount(unsigned units, char *out, size_t n)
{
	if (units % RO_MW_UNITS == 0)
		snprintf(out, n, "%uMW", units / RO_MW_UNITS);
	else
		snprintf(out, n, "%lluKW", (unsigned long long)units * (IMG_BOARD_WORDS / 1024u));
}

int ro_parse_megawords(const char *text, unsigned *units)
{
	if (!text || !units)
		return -1;
	const size_t n = strlen(text);
	if (n < 3 || strcmp(text + n - 2, "MW") != 0)
		return -1;
	uint64_t mw = 0;
	for (size_t i = 0; i < n - 2; ++i) {
		if (text[i] < '0' || text[i] > '9')
			return -1;
		mw = mw * 10u + (uint64_t)(text[i] - '0');
		if (mw * RO_MW_UNITS > 0xFFFFFFFFu)
			return -1;	/* no count of units this is */
	}
	*units = (unsigned)(mw * RO_MW_UNITS);
	return 0;
}

// **QUUX'S MACHINE** (A15b.13), out of `quux15_core.sv`'s window:
// the devices' snapshot taken first, so that every time word names one
// instant, then the memories, the register table, the devices and the halted
// pipeline.  Main memory and the display are DDR and the caller's.
int ro_read_quux15(struct readout *r, struct cadr_image *img)
{
	const uint64_t word = ((uint64_t)1 << 40) - 1u;
	uint64_t v[IMG_RG15_COUNT], dv[IMG_DV15_COUNT], w = 0;
	struct quux_state *q = &img->qx;
	struct quux15_state *x = &img->q15;
	if (ro_word64(r, IMG_SEL_SNAP, 0, &w) != 0)
		return -1;
	if (ro_block64(r, IMG_SEL_PROM, IMG_PROM_WORDS, img->prom) != 0 ||
	    ro_block64(r, IMG_SEL_IMEM, IMG_IMEM_WORDS, img->imem) != 0 ||
	    ro_block64(r, IMG_SEL_AMEM, IMG_AMEM_WORDS, img->amem) != 0 ||
	    ro_block64(r, IMG_SEL_MMEM, IMG_MMEM_WORDS, img->mmem) != 0 ||
	    ro_block64(r, IMG_SEL_PDL, img->pdl_words, img->pdl) != 0)
		return -1;
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		img->amem[i] &= word;
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		img->mmem[i] &= word;
	for (unsigned i = 0; i < img->pdl_words; ++i)
		img->pdl[i] &= word;
	for (unsigned i = 0; i < IMG_SPC_WORDS; ++i) {
		if (ro_word64(r, IMG_SEL_SPC, i, &w) != 0)
			return -1;
		img->spc[i] = (uint32_t)(w & 0x7FFFFu);
	}
	for (unsigned i = 0; i < img->dmem_words; ++i) {
		if (ro_word64(r, IMG_SEL_DMEM, i, &w) != 0)
			return -1;
		img->dmem[i] = (uint32_t)(w & 0x1FFFFu);
	}
	for (unsigned i = 0; i < IMG_OPCS; ++i) {
		if (ro_word64(r, IMG_SEL_OPCS, i, &w) != 0)
			return -1;
		img->opcs[i] = (uint16_t)(w & 0x3FFFu);
	}
	for (unsigned i = 0; i < IMG_QUUX_MACRO_ENTRIES; ++i) {
		if (ro_word64(r, IMG_SEL_MACRO, i, &w) != 0)
			return -1;
		q->macro_entries[i] = (uint32_t)(w & 0x3FFFFu);
	}
	if (ro_block64(r, IMG_SEL_REGS, IMG_RG15_COUNT, v) != 0 ||
	    ro_block64(r, IMG_SEL_QUUX_PAGE, IMG_DV15_COUNT, dv) != 0 ||
	    ro_block64(r, IMG_SEL_TAIL, IMG_TL15_COUNT, x->tail) != 0)
		return -1;

	img->q = v[IMG_RG15_Q] & word;
	img->vma = v[IMG_RG15_VMA] & word;
	img->md = v[IMG_RG15_MD] & word;
	x->lc = v[IMG_RG15_LC];
	img->pdl_ptr = (uint16_t)(v[IMG_RG15_PDLPTR] & 0x3FFFu);
	img->pdl_idx = (uint16_t)(v[IMG_RG15_PDLIDX] & 0x3FFFu);
	img->spcptr = (uint8_t)(v[IMG_RG15_SPCPTR] & 0x1Fu);
	x->intctl = (uint32_t)v[IMG_RG15_INTCTL];
	img->dc = (uint16_t)(v[IMG_RG15_DC] & 0x3FFu);
	x->overflow = (int)(v[IMG_RG15_FLAGS] & 1u);
	x->vmaok = (int)((v[IMG_RG15_FLAGS] >> 1) & 1u);
	x->bus_nxm = (int)((v[IMG_RG15_FLAGS] >> 2) & 1u);
	x->opc = (uint16_t)(v[IMG_RG15_OPC] & 0x3FFFu);
	q->macro_reg = (uint32_t)v[IMG_RG15_MACRO];
	q->macro_index = (uint32_t)(v[IMG_RG15_MACRO_IX] & 0x3FFu);
	q->localp = (uint32_t)(v[IMG_RG15_BASES] & 0x3FFFu);
	q->ap = (uint32_t)((v[IMG_RG15_BASES] >> 16) & 0x3FFFu);
	q->opr_v = (int)((v[IMG_RG15_ARMED] >> 8) & 1u);
	q->opr_arg = (int)((v[IMG_RG15_ARMED] >> 7) & 1u);
	q->opr_delta = (unsigned)(v[IMG_RG15_ARMED] & 0x3Fu);
	q->m31_v = 0;
	q->directory = (uint32_t)(v[IMG_RG15_DIRECTORY] & 0x3FFFFu);
	q->ephemeral = (int)((v[IMG_RG15_DIRECTORY] >> 18) & 1u);
	q->pointer_types = v[IMG_RG15_TYPES];
	q->refused = (uint32_t)v[IMG_RG15_REFUSED];
	q->pdl_base = (uint32_t)v[IMG_RG15_COPIES];
	q->pdl_head = (uint16_t)((v[IMG_RG15_COPIES] >> 32) & 0x3FFFu);
	x->posted = (uint32_t)v[IMG_RG15_POSTED];
	x->clocks = v[IMG_RG15_CLOCKS];
	x->period = (unsigned)((v[IMG_RG15_ID] >> 24) & 0xFFu);
	x->committed = v[IMG_RG15_COMMITTED];
	img->cycles = x->committed;

	for (unsigned k = 0; k < IMG_QUUX_TIMERS; ++k) {
		x->timer_ctl[k] = (uint32_t)dv[IMG_DV15_TIMER + k];
		x->deadline[k] = dv[IMG_DV15_DEADLINE + k];
	}
	q->fd_enabled = (int)(dv[IMG_DV15_FD] & 1u);
	q->fd_ie = (int)((dv[IMG_DV15_FD] >> 1) & 1u);
	q->fd_refused = (int)((dv[IMG_DV15_FD] >> 2) & 1u);
	q->fd_fault = (int)((dv[IMG_DV15_FD] >> 3) & 1u);
	q->fd_handles = (unsigned)((dv[IMG_DV15_FD] >> 8) & 0xFFu);
	q->fd_cmd_base = (uint32_t)dv[IMG_DV15_FD_CBASE];
	q->fd_resp_base = (uint32_t)dv[IMG_DV15_FD_RBASE];
	q->fd_cmd_log2 = (uint32_t)(dv[IMG_DV15_FD_LOGS] & 0xFu);
	q->fd_resp_log2 = (uint32_t)((dv[IMG_DV15_FD_LOGS] >> 4) & 0xFu);
	q->fd_cmd_prod = (uint16_t)(dv[IMG_DV15_FD_INDEXES] & 0xFFFFu);
	q->fd_cmd_cons = (uint16_t)((dv[IMG_DV15_FD_INDEXES] >> 16) & 0xFFFFu);
	q->fd_resp_cons = (uint16_t)((dv[IMG_DV15_FD_INDEXES] >> 32) & 0xFFFFu);
	x->bd_cmd = (uint32_t)dv[IMG_DV15_BD_CMD];
	x->bd_clp = (uint32_t)dv[IMG_DV15_BD_CLP];
	x->bd_da = (uint32_t)dv[IMG_DV15_BD_DA];
	x->bd_lma = (uint32_t)dv[IMG_DV15_BD_LMA];
	x->bd_flags = (uint32_t)dv[IMG_DV15_BD_FLAGS];
	// <4> a transfer in flight, its walk running or its words on the
	// port; <5> a pack on unit 0 (`quux15_devices.sv`'s word 15).
	q->walking = (int)((x->bd_flags >> 4) & 1u);
	q->present = (int)((x->bd_flags >> 5) & 1u);
	x->bd_done = dv[IMG_DV15_BD_DONE];
	x->bd_now = dv[IMG_DV15_BD_NOW];
	q->bow = (int)(dv[IMG_DV15_BOW] & 1u);
	x->ns = dv[IMG_DV15_NS];
	x->tv_at = dv[IMG_DV15_TV_AT];
	// The keyboard and the mouse (`quux15_input.sv`), one word, and the words waiting, `count` of them from `head`; a key word
	// that arrives meanwhile lands at the tail, past them.
	w = dv[IMG_DV15_INPUT];
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
	for (unsigned i = 0; i < q->count; ++i) {
		const unsigned at = (q->head + i) % IMG_QUUX_FIFO_WORDS;
		if (ro_word64(r, IMG_SEL_QUUX_PAGE, IMG_DV15_FIFO + at, &w) != 0)
			return -1;
		q->fifo[at] = (uint32_t)(w & 0xFFFFFFu);
	}
	// Revision 16's Ethernet device (`quux16_ethernet.sv`'s readout words).
	if (img->rev16) {
		uint64_t e[IMG_DV15_ETH_COUNT];
		for (unsigned k = 0; k < IMG_DV15_ETH_COUNT; ++k)
			if (ro_word64(r, IMG_SEL_QUUX_PAGE, IMG_DV15_ETH + k, &e[k]) != 0)
				return -1;
		x->eth.on = (int)(e[0] & 1u);
		x->eth.ie = (int)((e[0] >> 1) & 1u);
		x->eth.refused = (int)((e[0] >> 2) & 1u);
		x->eth.fault = (int)((e[0] >> 3) & 1u);
		x->eth.tx_log2 = (uint32_t)((e[0] >> 4) & 0xFu);
		x->eth.rx_log2 = (uint32_t)((e[0] >> 8) & 0xFu);
		x->eth.tx_base = (uint32_t)(e[1] & 0x0FFFFFFFu);
		x->eth.rx_base = (uint32_t)((e[1] >> 32) & 0x0FFFFFFFu);
		x->eth.tx_prod = (uint16_t)e[2];
		x->eth.tx_cons = (uint16_t)(e[2] >> 16);
		x->eth.rx_prod = (uint16_t)(e[2] >> 32);
		x->eth.rx_cons = (uint16_t)(e[2] >> 48);
		x->eth.rx_taken = (uint16_t)e[3];
		x->eth.counts = (uint32_t)e[4];
		const uint32_t hi = (uint32_t)((e[4] >> 32) & 0xFFFFu), lo = (uint32_t)(e[5] >> 32);
		x->eth.mac[0] = (uint8_t)(hi >> 8);
		x->eth.mac[1] = (uint8_t)hi;
		for (unsigned k = 0; k < 4; ++k)
			x->eth.mac[2 + k] = (uint8_t)(lo >> (24 - 8 * k));
		x->eth.address = (uint32_t)e[5];
		x->eth.netmask = (uint32_t)(e[6] >> 32);
		x->eth.gateway = (uint32_t)e[6];
	}
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
	return img_alloc_revision(img, boards, 0, 0);
}

int img_alloc_revision(struct cadr_image *img, unsigned boards, int quux, int revision)
{
	return img_alloc_video(img, boards, quux, revision, CADR_VIDEO_OLD_WIDTH, CADR_VIDEO_OLD_HEIGHT);
}

int img_alloc_video(struct cadr_image *img, unsigned boards, int quux, int revision,
		    unsigned width, unsigned height)
{
	memset(img, 0, sizeof *img);
	if (quux && (width == 0 || height == 0 || width % 32u != 0 ||
		     width > CADR_VIDEO_MAX_WIDTH || height > CADR_VIDEO_MAX_HEIGHT))
		return -1;
	// QUUX is revision 16; an older revision has a window this program
	// does not read.
	if (quux && revision != IMG_QUUX_REVISION)
		return -1;
	img->boards = boards;
	img->quux = quux != 0;
	img->rev13 = img->rev14 = img->rev15 = img->rev16 = img->quux;
	img->pdl_words = quux ? IMG_QUUX_PDL_WORDS : IMG_PDL_WORDS;
	img->l2_words = quux ? IMG_L2_WORDS_13 : IMG_L2_WORDS;
	img->video_width = quux ? width : 0u;
	img->video_height = quux ? height : 0u;
#if CHK_MUTATE == 39
	// A checkpoint mutant: the buffer at the old bitstreams' size.
	img->tv_words = quux ? IMG_QUUX_TV_WORDS : IMG_TV_WORDS;
#else
	img->tv_words = quux ? height * (width / 32u) : IMG_TV_WORDS;
#endif
	img->dmem_words = quux ? IMG_DMEM_WORDS_13 : IMG_DMEM_WORDS;
	img->l1_words = quux ? IMG_L1_WORDS_13 : IMG_L1_WORDS;
	img->word_bits = quux ? IMG_WORD_BITS_13 : 32u;
	img->prom = calloc(IMG_PROM_WORDS, sizeof *img->prom);
	img->imem = calloc(IMG_IMEM_WORDS, sizeof *img->imem);
	img->amem = calloc(IMG_AMEM_WORDS, sizeof *img->amem);
	img->mmem = calloc(IMG_MMEM_WORDS, sizeof *img->mmem);
	img->pdl = calloc(img->pdl_words, sizeof *img->pdl);
	img->spc = calloc(IMG_SPC_WORDS, sizeof *img->spc);
	img->dmem = calloc(img->dmem_words, sizeof *img->dmem);
	img->l1_map = calloc(img->l1_words, sizeof *img->l1_map);
	img->l2_map = calloc(img->l2_words, sizeof *img->l2_map);
	// QUUX's main memory is packed storage and is not copied (`main13`).
	img->main = quux ? NULL : calloc((size_t)boards * IMG_BOARD_WORDS, sizeof *img->main);
	img->tv = calloc(img->tv_words, sizeof *img->tv);
	if (!img->prom || !img->imem || !img->amem || !img->mmem || !img->pdl ||
	    !img->spc || !img->dmem || !img->l1_map || !img->l2_map ||
	    (!img->main && !quux) || !img->tv) {
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
