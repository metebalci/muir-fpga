// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The checkpoint program's core, against a model of the fabric, on the build
// host --- no board, no Vivado, nothing but a C compiler.
//
// **WHAT THIS PROVES AND WHAT muir PROVES.**  This file holds the parts that
// can be decided here: that the packer is muir's packer, that the program
// compares the echo and refuses a word that came back for another address,
// and that every memory and every register the window reports reaches the
// body at the offset muir's format puts it.  **It cannot prove the format is
// right**, because a self-consistent writer and a self-consistent reader of
// the same wrong format agree perfectly.  What proves that is muir itself,
// and `build/checkpoint.pass` does it: this program writes a file, muir
// resumes it and writes its own, and the two are compared BYTE FOR BYTE.
// That is muir's own round-trip property --- `tests/checkpoint.rs`'s
// "the checkpoint loads and saves as itself" --- and it is the only evidence
// available here that every field went where it was meant to.
//
// The machine behind the model is a poison, injective in the memory and the
// address, for the reason every stimulus in this repository is: a machine of
// zeros would let a program that wrote the same field twice, or skipped one,
// or crossed two, agree with muir at every byte.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cadr/cadr_mem.h"
#include "cadr_image.h"
#include "chk.h"
#include "chaos_face.h"
#include "chk_rtl.h"
#include "pack_bind.h"
#include "sha256.h"
#include "readout.h"

static long bad;
static void fail(const char *what, unsigned long long got, unsigned long long want)
{
	fprintf(stderr, "%s is 0x%llx, the reference says 0x%llx\n", what, got, want);
	++bad;
}

// --- the model -------------------------------------------------------------

struct model {
	uint64_t imem[IMG_IMEM_WORDS], prom[IMG_PROM_WORDS];
	uint64_t amem[IMG_AMEM_WORDS], mmem[IMG_MMEM_WORDS];
	uint64_t pdl[IMG_PDL_WORDS];
	uint32_t spc[IMG_SPC_WORDS];
	uint32_t dmem[IMG_DMEM_WORDS], l1[IMG_L1_WORDS], l2[IMG_L2_WORDS];
	uint16_t opcs[IMG_OPCS];
	uint64_t regs[21];
	uint32_t ro_addr;
	uint64_t latched;
	uint32_t hi_latch_cycles, hi_latch_ticks;
	uint64_t cycles, ticks;
	int running;
	// **THE ECHO, DELIBERATELY STALE FOR THE FIRST `stale_for` READS.**  A
	// program that did not compare it would take a word for the address
	// before the one it asked for and never know; this is how the check
	// asks whether it does.
	int stale_for;
};

static uint64_t model_word(struct model *m, unsigned sel, unsigned a)
{
	switch (sel) {
	case IMG_SEL_IMEM: return a < IMG_IMEM_WORDS ? m->imem[a] : 0;
	case IMG_SEL_PROM: return a < IMG_PROM_WORDS ? m->prom[a] : 0;
	case IMG_SEL_AMEM: return a < IMG_AMEM_WORDS ? m->amem[a] : 0;
	case IMG_SEL_MMEM: return a < IMG_MMEM_WORDS ? m->mmem[a] : 0;
	case IMG_SEL_PDL:  return a < IMG_PDL_WORDS ? m->pdl[a] : 0;
	case IMG_SEL_SPC:  return a < IMG_SPC_WORDS ? m->spc[a] : 0;
	case IMG_SEL_DMEM: return a < IMG_DMEM_WORDS ? m->dmem[a] : 0;
	case IMG_SEL_MAP1: return a < IMG_L1_WORDS ? m->l1[a] : 0;
	case IMG_SEL_MAP2: return a < IMG_L2_WORDS ? m->l2[a] : 0;
	case IMG_SEL_OPCS: return a < IMG_OPCS ? m->opcs[a] : 0;
	case IMG_SEL_REGS: return a < 21 ? m->regs[a] : RO_NO_MEMORY;
	default: return RO_NO_MEMORY;
	}
}

static uint32_t model_read(struct readout *r, unsigned word)
{
	struct model *m = r->ctx;
	const unsigned sel = (m->ro_addr >> 14) & 0xFu;
	const unsigned a = m->ro_addr & 0x3FFFu;
	switch (word) {
	case RO_IDENT: return RO_IDENT_WORD;
	case RO_STAT: return 0;
	case RO_CYCLES:
		m->hi_latch_cycles = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case RO_CYCLESH: return m->hi_latch_cycles;
	case RO_TICKS:
		m->hi_latch_ticks = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case RO_TICKSH: return m->hi_latch_ticks;
	case RO_ADDR:
		// A read of word 10 latches the word beside it, as the console
		// does, so the two halves are of one instant.
		m->latched = model_word(m, sel, a);
		if (m->stale_for > 0) {
			--m->stale_for;
			// One address short: the word for the one before it.
			return (m->ro_addr - 1u) & 0x3FFFFu;
		}
		return m->ro_addr;
	case RO_DATA_LO: return (uint32_t)m->latched;
	case RO_DATA_HI: return (uint32_t)(m->latched >> 32) & 0xFFFFu;
	default: return RO_UNMAPPED;
	}
}

static void model_write(struct readout *r, unsigned word, uint32_t v)
{
	struct model *m = r->ctx;
	if (word == RO_ADDR)
		m->ro_addr = v & 0x3FFFFu;
	else if (word == RO_SPY(RO_SPY_CLK_W))
		m->running = (v & RO_CLK_RUN) != 0;
}

// The poison, `tb/cadr_readout_tb.cpp`'s, so that the two checks disagree
// about nothing.
static uint64_t poison(unsigned sel, unsigned addr, unsigned bits)
{
	const uint64_t h = (uint64_t)(sel + 1) * 0x9E3779B97F4A7C15ull +
			   (uint64_t)(addr + 1) * 0xC2B2AE3D27D4EB4Full;
	return bits >= 64 ? h : (h & ((1ull << bits) - 1ull));
}

static void fill(struct model *m)
{
	memset(m, 0, sizeof *m);
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		m->imem[i] = poison(IMG_SEL_IMEM, i, 48);
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		m->prom[i] = poison(IMG_SEL_PROM, i, 48);
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		m->amem[i] = (uint32_t)poison(IMG_SEL_AMEM, i, 32);
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		m->mmem[i] = (uint32_t)poison(IMG_SEL_MMEM, i, 32);
	for (unsigned i = 0; i < IMG_PDL_WORDS; ++i)
		m->pdl[i] = (uint32_t)poison(IMG_SEL_PDL, i, 32);
	for (unsigned i = 0; i < IMG_SPC_WORDS; ++i)
		m->spc[i] = (uint32_t)poison(IMG_SEL_SPC, i, 19);
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		m->dmem[i] = (uint32_t)poison(IMG_SEL_DMEM, i, 17);
	for (unsigned i = 0; i < IMG_L1_WORDS; ++i)
		m->l1[i] = (uint32_t)poison(IMG_SEL_MAP1, i, 5);
	for (unsigned i = 0; i < IMG_L2_WORDS; ++i)
		m->l2[i] = (uint32_t)poison(IMG_SEL_MAP2, i, 24);
	for (unsigned i = 0; i < IMG_OPCS; ++i)
		m->opcs[i] = (uint16_t)poison(IMG_SEL_OPCS, i, 14);

	// The register table.  **Every entry is masked to the width the
	// machine's own register has**, because muir refuses a pointer wider
	// than its register by name --- `spcptr > 0o37` and the two PDL
	// pointers past ten bits are three of its four range checks.
	static const unsigned bits[21] = { 14, 14, 48, 48, 32, 32, 32, 32,
					   32, 26, 10, 10, 10, 5, 14, 10,
					   24, 32, 22, 6, 33 };
	for (unsigned i = 0; i < 21; ++i)
		m->regs[i] = poison(IMG_SEL_REGS, i, bits[i]);
	m->cycles = 0x1234567890ull;
	m->ticks = 0x9876543210ull;
	m->running = 0;
}

// --- QUUX's machine ----------------------------------------------------------
//
// **QUUX'S WINDOW, `quux15_core.sv`'s readout, MODELED**: the memories at
// their 64 or 40 bits, the register table of `img_rg15`, the devices of
// `img_dv15` with the Ethernet device's words after them and the keyboard's
// FIFO at 64, and the halted pipeline's words of `img_tl15`; the face's word
// 12 carries a word's `<63:32>` whole, and a write of selector 15 takes the
// snapshot.  The processor's registers and memories behind it are a poison
// at every field's width, with the few values a resume holds to the flags
// given it set as those flags say: the clock's period, the video
// controller's size, the host's words of the Ethernet device and
// block-disk's pack.
//
// **THE DEVICES ARE WHAT A HISTORY LEAVES, AND THE SAME HISTORY IS RUN IN
// muir.**  `golden/src/quux_checkpoint.rs` drives muir's machine through its
// register page at its clock --- the devices reset, the timers written and
// turned on, the file device's command answered, block-disk's read run off
// the end of its pack, keys pressed and read, the mouse moved, Ethernet
// frames sent, refused, received and dropped --- and these are the words
// the fabric's devices would hold after it, each constant below there under
// the same name.  `build/checkpoint.quux.pass` holds the file this writes to
// the file that generator writes, BYTE FOR BYTE, and has muir's `quux`
// resume this one and save it back; the package's own check holds the
// transport and the refusals here.  A field of the pipeline the core packs
// into one readout word with others is poisoned by its own address on both
// sides and packed here, so that a field taken from the wrong bits of its
// word differs.
//
// The constants are the resume line's: the Kria KR260's 1920 by 1080 and a
// period of 10 ns; the host's words of `ethernet_host_check`; and muir's
// own QUUX disk of 8,192 blocks, which the Makefile gives as the pack.
#define Q_PERIOD     20u		/* entry 21's <31:24>, units of 0.5 ns */
#define Q_VIDEO_W    1920u
#define Q_VIDEO_H    1080u
#define Q_UNITS      16u		/* 1MW of main memory */
#define Q_DISK_BLOCKS 8192u
#define Q_CYCLES     0x1234567890ull
#define Q_NS         0x9876543210ull	/* the snapshot's instant, units of 0.5 ns */
#define Q_KEYS_READ  59u
#define Q_KEYS_WAITING 5u
#define Q_MOUSE_X    0x5a3u
#define Q_MOUSE_Y    0x2c7u
#define Q_BUTTONS    5u
#define Q_FD_CMD_BASE  0x0001000u
#define Q_FD_CMD_LOG2  2u
#define Q_FD_RESP_BASE 0x0001108u
#define Q_FD_RESP_LOG2 1u
#define Q_MAC_HI     0x025au		/* 02:5a:11:22:33:44 */
#define Q_MAC_LO     0x11223344u
#define Q_IP_ADDRESS (169u << 24 | 254u << 16 | 101u << 8 | 2u)
#define Q_IP_NETMASK 0xFFFFFFFCu
#define Q_IP_GATEWAY (169u << 24 | 254u << 16 | 101u << 8 | 1u)
// The history's instants, units of 0.5 ns, and what it leaves.
#define Q_PER_US     2000u		/* units a microsecond */
#define Q_RESET_AT   (Q_NS - 20000001u)	/* word 104, every device reset */
#define Q_T0_PERIOD  6000u		/* periodic, with its enable */
#define Q_T0_ON      (Q_NS - 11000001u)
#define Q_T1_PERIOD  16667u		/* one-shot, without */
#define Q_T1_ON      (Q_NS - 19000003u)
#define Q_T2_PERIOD  0x5A3C7Eu		/* never on, with its enable */
// Block-disk: a read of two pages, four bytes a word, with the done
// interrupt enabled, from six blocks before the end of the pack: the first
// page moves four, the second two and then runs past the end, so DA is the
// block that failed, the last memory address is the command list's second
// word, and DONE is six blocks' time after START.
#define Q_BD_CMD     0x12345800u
#define Q_BD_CLP     0x000ABCDEu
#define Q_BD_DA      (Q_DISK_BLOCKS - 6u)
#define Q_BD_MOVED   6u
#define Q_BD_START   (Q_NS - 5000777u)
#define Q_BD_NOW     (Q_NS - 555u)	/* its status, the last read of it */
#define Q_BLOCK_UNITS 200000u		/* `block_disk::BLOCK_NS`, in units */
// The Ethernet device: rings of four and eight entries; five transmits, two
// refused; six Ethernet frames of another type and nine IPv4 frames too
// short dropped by the rules; two into the two buffers given and three with
// none; one taken back, six more given and two more received; and a take
// past 251, its index fault.
#define Q_ETH_TX_BASE 0x0003000u
#define Q_ETH_TX_LOG2 2u
#define Q_ETH_RX_BASE 0x0002000u
#define Q_ETH_RX_LOG2 3u
#define Q_ETH_TX      5u
#define Q_ETH_TX_REFUSED 2u
#define Q_ETH_RX_GIVEN 7u
#define Q_ETH_RX_FILLED 4u
#define Q_ETH_RX_TAKEN 1u
#define Q_ETH_TYPE_DROPS 6u
#define Q_ETH_IPV4_DROPS 9u
#define Q_ETH_RX_DROPS 3u

struct qmodel {
	uint64_t imem[IMG_IMEM_WORDS], prom[IMG_PROM_WORDS];
	uint64_t amem[IMG_AMEM_WORDS], mmem[IMG_MMEM_WORDS];
	uint64_t pdl[IMG_QUUX_PDL_WORDS];
	uint32_t spc[IMG_SPC_WORDS], dmem[IMG_DMEM_WORDS_13];
	uint16_t opcs[IMG_OPCS];
	uint32_t macro[IMG_QUUX_MACRO_ENTRIES];
	uint64_t regs[IMG_RG15_COUNT];
	uint64_t dv[IMG_DV15_ETH + IMG_DV15_ETH_COUNT];
	uint32_t fifo[IMG_QUUX_FIFO_WORDS];
	uint64_t tail[IMG_TL15_COUNT];
	uint32_t ro_addr;
	uint64_t latched;
	uint32_t hi_latch_cycles, hi_latch_ticks;
	uint64_t cycles, ticks;
	int snaps;
};

static uint64_t qmodel_word(struct qmodel *m, unsigned sel, unsigned a)
{
	switch (sel) {
	case IMG_SEL_IMEM: return a < IMG_IMEM_WORDS ? m->imem[a] : RO_NO_MEMORY;
	case IMG_SEL_PROM: return a < IMG_PROM_WORDS ? m->prom[a] : RO_NO_MEMORY;
	case IMG_SEL_AMEM: return a < IMG_AMEM_WORDS ? m->amem[a] : RO_NO_MEMORY;
	case IMG_SEL_MMEM: return a < IMG_MMEM_WORDS ? m->mmem[a] : RO_NO_MEMORY;
	case IMG_SEL_PDL:  return a < IMG_QUUX_PDL_WORDS ? m->pdl[a] : RO_NO_MEMORY;
	case IMG_SEL_SPC:  return a < IMG_SPC_WORDS ? m->spc[a] : RO_NO_MEMORY;
	case IMG_SEL_DMEM: return a < IMG_DMEM_WORDS_13 ? m->dmem[a] : RO_NO_MEMORY;
	case IMG_SEL_OPCS: return a < IMG_OPCS ? m->opcs[a] : RO_NO_MEMORY;
	case IMG_SEL_MACRO: return a < IMG_QUUX_MACRO_ENTRIES ? m->macro[a] : RO_NO_MEMORY;
	case IMG_SEL_REGS: return a < IMG_RG15_COUNT ? m->regs[a] : RO_NO_MEMORY;
	case IMG_SEL_QUUX_PAGE:
		if (a >= IMG_DV15_FIFO && a < IMG_DV15_FIFO + IMG_QUUX_FIFO_WORDS)
			return m->fifo[a - IMG_DV15_FIFO];
		return a < IMG_DV15_ETH + IMG_DV15_ETH_COUNT ? m->dv[a] : RO_NO_MEMORY;
	case IMG_SEL_TAIL: return a < IMG_TL15_COUNT ? m->tail[a] : RO_NO_MEMORY;
	case IMG_SEL_SNAP: ++m->snaps; return 0;
	default: return RO_NO_MEMORY;
	}
}

static uint32_t qmodel_read(struct readout *r, unsigned word)
{
	struct qmodel *m = r->ctx;
	switch (word) {
	case RO_IDENT: return RO_IDENT_WORD;
	case RO_CYCLES:
		m->hi_latch_cycles = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case RO_CYCLESH: return m->hi_latch_cycles;
	case RO_TICKS:
		m->hi_latch_ticks = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case RO_TICKSH: return m->hi_latch_ticks;
	case RO_ADDR:
		m->latched = qmodel_word(m, (m->ro_addr >> 14) & 0xFu, m->ro_addr & 0x3FFFu);
		return m->ro_addr;
	case RO_DATA_LO: return (uint32_t)m->latched;
	case RO_DATA_HI: return (uint32_t)(m->latched >> 32);
	default: return RO_UNMAPPED;
	}
}

static void qmodel_write(struct readout *r, unsigned word, uint32_t v)
{
	struct qmodel *m = r->ctx;
	if (word == RO_ADDR)
		m->ro_addr = v & 0x3FFFFu;
}

static void fill_quux(struct qmodel *m)
{
	memset(m, 0, sizeof *m);
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		m->imem[i] = poison(IMG_SEL_IMEM, i, 64);	/* under the PROM too */
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		m->prom[i] = poison(IMG_SEL_PROM, i, 64);
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		m->amem[i] = poison(IMG_SEL_AMEM, i, 40);
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		m->mmem[i] = poison(IMG_SEL_MMEM, i, 40);
	for (unsigned i = 0; i < IMG_QUUX_PDL_WORDS; ++i)
		m->pdl[i] = poison(IMG_SEL_PDL, i, 40);
	for (unsigned i = 0; i < IMG_SPC_WORDS; ++i)
		m->spc[i] = (uint32_t)poison(IMG_SEL_SPC, i, 19);
	for (unsigned i = 0; i < IMG_DMEM_WORDS_13; ++i)
		m->dmem[i] = (uint32_t)poison(IMG_SEL_DMEM, i, 17);
	for (unsigned i = 0; i < IMG_OPCS; ++i)
		m->opcs[i] = (uint16_t)poison(IMG_SEL_OPCS, i, 14);
	for (unsigned i = 0; i < IMG_QUUX_MACRO_ENTRIES; ++i)
		m->macro[i] = (uint32_t)poison(IMG_SEL_MACRO, i, 18);

	// The register table, each entry at its field's width.
	uint64_t *g = m->regs;
	g[IMG_RG15_Q] = poison(IMG_SEL_REGS, IMG_RG15_Q, 40);
	g[IMG_RG15_VMA] = poison(IMG_SEL_REGS, IMG_RG15_VMA, 40);
	g[IMG_RG15_MD] = poison(IMG_SEL_REGS, IMG_RG15_MD, 40);
	g[IMG_RG15_LC] = poison(IMG_SEL_REGS, IMG_RG15_LC, 34) | 1ull << 40;
	g[IMG_RG15_PDLPTR] = poison(IMG_SEL_REGS, IMG_RG15_PDLPTR, 14);
	g[IMG_RG15_PDLIDX] = poison(IMG_SEL_REGS, IMG_RG15_PDLIDX, 14);
	g[IMG_RG15_SPCPTR] = poison(IMG_SEL_REGS, IMG_RG15_SPCPTR, 5);
	g[IMG_RG15_INTCTL] = poison(IMG_SEL_REGS, IMG_RG15_INTCTL, 4) << 26;
	g[IMG_RG15_DC] = poison(IMG_SEL_REGS, IMG_RG15_DC, 10);
	g[IMG_RG15_FLAGS] = 7u;		/* overflow, VMAOK and word 101's NXM */
	g[IMG_RG15_OPC] = poison(IMG_SEL_REGS, IMG_RG15_OPC, 14);
	g[IMG_RG15_MACRO] = poison(IMG_SEL_REGS, IMG_RG15_MACRO, 32) & ~(3ull << 29);
	g[IMG_RG15_MACRO_IX] = poison(IMG_SEL_REGS, IMG_RG15_MACRO_IX, 10);
	g[IMG_RG15_BASES] = poison(IMG_SEL_REGS, 113, 14) << 16 | poison(IMG_SEL_REGS, IMG_RG15_BASES, 14);
	g[IMG_RG15_ARMED] = 1u << 8 | 1u << 7 | poison(IMG_SEL_REGS, IMG_RG15_ARMED, 6);
	g[IMG_RG15_DIRECTORY] = 1u << 18 | (poison(IMG_SEL_REGS, IMG_RG15_DIRECTORY, 18) & ~3ull);
	g[IMG_RG15_TYPES] = poison(IMG_SEL_REGS, IMG_RG15_TYPES, 64);
	g[IMG_RG15_REFUSED] = poison(IMG_SEL_REGS, IMG_RG15_REFUSED, 32);
	g[IMG_RG15_COPIES] = poison(IMG_SEL_REGS, 118, 14) << 32 | poison(IMG_SEL_REGS, IMG_RG15_COPIES, 32);
	g[IMG_RG15_POSTED] = poison(IMG_SEL_REGS, IMG_RG15_POSTED, 32);
	g[IMG_RG15_CLOCKS] = poison(IMG_SEL_REGS, IMG_RG15_CLOCKS, 40);
	g[IMG_RG15_ID] = (uint64_t)IMG_QUUX_MARK << 32 | (uint64_t)Q_PERIOD << 24 | IMG_QUUX_ID_16;
	g[IMG_RG15_COMMITTED] = Q_CYCLES;

	// The devices: timer 0 on and periodic with its enable, timer 1 on and
	// one-shot, each due a period after its turn-on, and timer 2 off with
	// its enable, a period and no deadline; the file device on with its
	// enable and an index fault, nothing open and nothing queued; block-disk
	// with a pack, its read past the end done; black-on-white; the
	// snapshot's instant.
	uint64_t *v = m->dv;
	v[IMG_DV15_TIMER + 0] = (uint64_t)Q_T0_PERIOD << 8 | 4u | 1u;
	v[IMG_DV15_TIMER + 1] = (uint64_t)Q_T1_PERIOD << 8 | 2u | 1u;
	v[IMG_DV15_TIMER + 2] = (uint64_t)Q_T2_PERIOD << 8 | 4u;
	v[IMG_DV15_DEADLINE + 0] = Q_T0_ON + (uint64_t)Q_T0_PERIOD * Q_PER_US;
	v[IMG_DV15_DEADLINE + 1] = Q_T1_ON + (uint64_t)Q_T1_PERIOD * Q_PER_US;
	v[IMG_DV15_DEADLINE + 2] = ~0ull;
	v[IMG_DV15_FD] = 1u << 3 | 1u << 1 | 1u;
	v[IMG_DV15_FD_CBASE] = Q_FD_CMD_BASE;
	v[IMG_DV15_FD_RBASE] = Q_FD_RESP_BASE;
	v[IMG_DV15_FD_LOGS] = Q_FD_RESP_LOG2 << 4 | Q_FD_CMD_LOG2;
	v[IMG_DV15_FD_INDEXES] = 1ull << 32 | 1ull << 16 | 1u;
	v[IMG_DV15_BD_CMD] = Q_BD_CMD;
	v[IMG_DV15_BD_CLP] = Q_BD_CLP;
	v[IMG_DV15_BD_DA] = Q_BD_DA + Q_BD_MOVED;
	v[IMG_DV15_BD_LMA] = Q_BD_CLP + 1u;
	v[IMG_DV15_BD_FLAGS] = 1u << 5 | 1u << 1;	/* a pack on unit 0; past the end */
	v[IMG_DV15_BD_DONE] = Q_BD_START + (uint64_t)Q_BD_MOVED * Q_BLOCK_UNITS;
	v[IMG_DV15_BD_NOW] = Q_BD_NOW;
	v[IMG_DV15_BOW] = 1u;
	v[IMG_DV15_NS] = Q_NS;
	v[IMG_DV15_RTC] = 0;
	v[IMG_DV15_US] = Q_NS / 2000u;
	v[IMG_DV15_TV_AT] = Q_RESET_AT;
	// Seventy key words pressed into sixty-four slots, the overflow set,
	// and fifty-nine read: five waiting from slot 59, the FIFO's wrap
	// among them.
	for (unsigned i = 0; i < IMG_QUUX_FIFO_WORDS; ++i)
		m->fifo[i] = (uint32_t)poison(20, i, 24);
	v[IMG_DV15_INPUT] = (uint64_t)Q_KEYS_READ << 38 | (uint64_t)Q_KEYS_WAITING << 31 |
			    1ull << 30 | 1ull << 29 | 1ull << 28 | 1ull << 27 |
			    (uint64_t)Q_BUTTONS << 24 | (uint64_t)Q_MOUSE_Y << 12 | Q_MOUSE_X;
	// The Ethernet device: on, with its enable and an index fault, its
	// rings and indexes, its counters, and the host's words, 253-257.
	uint64_t *e = &v[IMG_DV15_ETH];
	e[0] = Q_ETH_RX_LOG2 << 8 | Q_ETH_TX_LOG2 << 4 | 1u << 3 | 1u << 1 | 1u;
	e[1] = (uint64_t)Q_ETH_RX_BASE << 32 | Q_ETH_TX_BASE;
	e[2] = (uint64_t)Q_ETH_RX_FILLED << 48 | (uint64_t)Q_ETH_RX_GIVEN << 32 | Q_ETH_TX << 16 | Q_ETH_TX;
	e[3] = Q_ETH_RX_TAKEN;
	e[4] = (uint64_t)Q_MAC_HI << 32 | Q_ETH_TX_REFUSED << 24 | Q_ETH_RX_DROPS << 16 |
	       Q_ETH_IPV4_DROPS << 9 | Q_ETH_TYPE_DROPS << 4;
	e[5] = (uint64_t)Q_MAC_LO << 32 | Q_IP_ADDRESS;
	e[6] = (uint64_t)Q_IP_NETMASK << 32 | Q_IP_GATEWAY;

	// The halted pipeline.  The micro stack's pending write, the OPCs and
	// the console's three registers are each fields of muir's of their own,
	// poisoned by their own address and packed into their word here.
	uint64_t *t = m->tail;
	t[IMG_TL15_NPC] = poison(IMG_SEL_TAIL, IMG_TL15_NPC, 14);
	t[IMG_TL15_NPC_AFTER] = 1u << 14 | poison(IMG_SEL_TAIL, IMG_TL15_NPC_AFTER, 14);
	t[IMG_TL15_NOPS] = 2u;
	t[IMG_TL15_PDL_PENDING] = 1u << 14 | poison(IMG_SEL_TAIL, IMG_TL15_PDL_PENDING, 14);
	t[IMG_TL15_PDL_WORD] = poison(IMG_SEL_TAIL, IMG_TL15_PDL_WORD, 40);
	t[IMG_TL15_MD_OLD] = 1u;
	t[IMG_TL15_MD_OLD_WORD] = poison(IMG_SEL_TAIL, IMG_TL15_MD_OLD_WORD, 40);
	t[IMG_TL15_D_WAIT] = 2u;
	t[IMG_TL15_OA_LOW] = poison(IMG_SEL_TAIL, IMG_TL15_OA_LOW, 64);
	t[IMG_TL15_OA_HIGH] = poison(IMG_SEL_TAIL, IMG_TL15_OA_HIGH, 64);
	t[IMG_TL15_NEXT_INSTRD] = 1u;
	t[IMG_TL15_LVMO] = poison(IMG_SEL_TAIL, IMG_TL15_LVMO, 32);
	t[IMG_TL15_WRCYC] = 1u;
	t[IMG_TL15_SPC_WRITE] = 1u << 24 | poison(IMG_SEL_TAIL, 113, 5) << 19 |
				poison(IMG_SEL_TAIL, IMG_TL15_SPC_WRITE, 19);
	t[IMG_TL15_MAP_WRITE] = 1u;
	t[IMG_TL15_MAP_VMA] = poison(IMG_SEL_TAIL, IMG_TL15_MAP_VMA, 40);
	t[IMG_TL15_MAP_MD] = poison(IMG_SEL_TAIL, IMG_TL15_MAP_MD, 40);
	t[IMG_TL15_OPC_LOW] = t[IMG_TL15_OPC_HIGH] = 0;
	for (unsigned k = 0; k < IMG_OPCS; ++k)
		t[k < 4 ? IMG_TL15_OPC_LOW : IMG_TL15_OPC_HIGH] |=
			poison(IMG_SEL_TAIL, 0200u + k, 14) << (14u * (k % 4u));
	t[IMG_TL15_HALTED] = 1u;
	t[IMG_TL15_COMMITTED] = Q_CYCLES;
	t[IMG_TL15_NPC_PREV] = poison(IMG_SEL_TAIL, IMG_TL15_NPC_PREV, 14);
	// The mode without the speed bits, which QUUX's has not; the clock
	// control with RUN clear, a halted machine's; the OPC control.
	t[IMG_TL15_CONSOLE] = (poison(IMG_SEL_TAIL, IMG_TL15_CONSOLE, 6) & ~3ull) |
			      (poison(IMG_SEL_TAIL, 100u + IMG_TL15_CONSOLE, 5) & ~1ull) << 6 |
			      poison(IMG_SEL_TAIL, 200u + IMG_TL15_CONSOLE, 3) << 11;
	t[IMG_TL15_DEBUG_IR] = poison(IMG_SEL_TAIL, IMG_TL15_DEBUG_IR, 64);
	m->cycles = Q_CYCLES;
	m->ticks = Q_NS / 20u;
}

// --- the packer, against its own inverse -----------------------------------

static int unpack_equals(const uint8_t *raw, size_t len)
{
	size_t plen = 0;
	uint8_t *p = chk_pack(raw, len, &plen);
	if (!p)
		return 0;
	uint8_t *out = malloc(len ? len : 1);
	size_t o = 0, at = 0;
	int ok = 1;
	while (at < plen) {
		uint64_t zeros = 0, lit = 0;
		unsigned shift = 0;
		while (at < plen) {
			uint8_t b = p[at++];
			zeros |= (uint64_t)(b & 0x7f) << shift;
			shift += 7;
			if (!(b & 0x80))
				break;
		}
		shift = 0;
		while (at < plen) {
			uint8_t b = p[at++];
			lit |= (uint64_t)(b & 0x7f) << shift;
			shift += 7;
			if (!(b & 0x80))
				break;
		}
		if (o + zeros + lit > len) { ok = 0; break; }
		memset(out + o, 0, zeros);
		o += zeros;
		memcpy(out + o, p + at, lit);
		o += lit;
		at += lit;
	}
	if (ok)
		ok = (o == len) && (len == 0 || memcmp(out, raw, len) == 0);
	free(out);
	free(p);
	return ok;
}

// The body of `img` as it would be written, into `out` (freed by the caller).
static void body_of(const struct cadr_image *img, const struct chk_declared *d, struct chk *out)
{
	chk_init(out);
	chk_rtl_body(out, img, d);
}

// The one byte at which two bodies differ, or -1 when they differ at none or
// at more than one, or in length.
static long one_byte_apart(const struct chk *a, const struct chk *b)
{
	if (a->len != b->len)
		return -1;
	long at = -1;
	for (size_t i = 0; i < a->len; ++i) {
		if (a->p[i] == b->p[i])
			continue;
		if (at >= 0)
			return -1;
		at = (long)i;
	}
	return at;
}

// **THE RUN STATE, HELD ON THE TWO SLOTS muir READS IT FROM.**  `found` is a
// machine as the window read it; returns 0, or -1 having said why.
static int run_state_check(const struct cadr_image *found, const struct chk_declared *d,
			   const char *which)
{
	const uint64_t both = (1ull << IMG_F_RUN) | (1ull << IMG_F_SRUN);
	struct cadr_image halted = *found, run_only = *found, srun_only = *found;
	halted.flags &= ~both;
	run_only.flags = (found->flags & ~both) | (1ull << IMG_F_RUN);
	srun_only.flags = (found->flags & ~both) | (1ull << IMG_F_SRUN);
	struct chk b0, br, bs, bw, bh;
	body_of(&halted, d, &b0);
	body_of(&run_only, d, &br);
	body_of(&srun_only, d, &bs);
	const long at_run = one_byte_apart(&b0, &br), at_srun = one_byte_apart(&b0, &bs);
	int bad_here = 0;
	if (at_run < 0 || at_srun < 0 || at_run == at_srun ||
	    b0.p[at_run] != 0 || br.p[at_run] != 1 || b0.p[at_srun] != 0 || bs.p[at_srun] != 1) {
		fprintf(stderr, "%s: RUN and SRUN are not one byte each, 0 and 1 (%ld, %ld)\n",
			which, at_run, at_srun);
		bad_here = 1;
	}
	// Found running and halted for the read: both set, and nothing else moved.
	struct cadr_image ran = halted;
	chk_rtl_run_state(&ran, 1);
	body_of(&ran, d, &bw);
	if (!bad_here) {
		int ok = bw.len == b0.len && bw.p[at_run] == 1 && bw.p[at_srun] == 1;
		for (size_t i = 0; ok && i < b0.len; ++i)
			if ((long)i != at_run && (long)i != at_srun && bw.p[i] != b0.p[i])
				ok = 0;
		if (!ok) {
			fprintf(stderr, "%s: a machine found running is not written with RUN %u and "
				"SRUN %u set and the rest as read\n", which,
				bw.len > (size_t)at_run ? bw.p[at_run] : 9u,
				bw.len > (size_t)at_srun ? bw.p[at_srun] : 9u);
			bad_here = 1;
		}
	}
	// Found halted: written exactly as read.
	struct cadr_image stood = halted;
	chk_rtl_run_state(&stood, 0);
	body_of(&stood, d, &bh);
	if (bh.len != b0.len || memcmp(bh.p, b0.p, b0.len) != 0) {
		fprintf(stderr, "%s: a machine found halted is not written as it was read\n", which);
		bad_here = 1;
	}
	chk_free(&b0);
	chk_free(&br);
	chk_free(&bs);
	chk_free(&bw);
	chk_free(&bh);
	if (bad_here) {
		fprintf(stderr, "checkpoint: FAIL: %s's run state before the halt\n", which);
		++bad;
		return -1;
	}
	printf("checkpoint: %s's run state: RUN at byte %ld and SRUN at byte %ld of the body, "
	       "both set for a machine found running and as read for one found halted\n",
	       which, at_run, at_srun);
	return 0;
}

// ---- the halt: a machine that has stopped retiring is not a halted one ------
//
// **A CHECKPOINT IS OF A HALTED MACHINE, AND A COUNTER STANDING STILL IS NOT
// ONE.**  A board stopped retiring with SRUN up --- ERR down, FLAG-1 naming no
// halt, the pipeline undrained --- and the program took it as halted and
// wrote a file of it.  This model is the console's window as `ro_found` reads
// it: CYCLES and TICKS on page 0, FLAG-1, PC and OPC on page 1, and on
// QUUX the halted pipeline's word 19 through the readout, each machine's
// halt as its fabric makes it.  The CADR's SRUN is RUN registered, lowered
// by a write of zero whatever the machine is doing; QUUX's SRUN follows RUN
// too, and its halted bit rises only when the drain ends
// (`quux15_core.sv`), which on a stuck pipeline it never does.

struct hmodel {
	int rev15;
	uint64_t cycles, ticks;
	uint32_t hi_cycles, hi_ticks;
	int retiring;		/* CYCLES moves */
	int srun, err, stathalt, wait;
	int halted, x_halted;	/* QUUX's tail word 19 */
	int drains;		/* a write of zero stops it, and on QUUX drains it */
	int lost;		/* the diagnostic registers do not answer */
	uint16_t pc, opc;
	uint32_t ro_addr;
	uint64_t latched;
	int clk_writes;
};

static uint16_t hmodel_flag1(const struct hmodel *m)
{
	if (m->rev15)	/* `spy_rdata` at 8: PROMDISABLE, ERR the HALT bit, SSDONE, SRUN */
		return (uint16_t)(0xe800u | (unsigned)m->x_halted << 10 | (unsigned)m->srun << 8);
	return (uint16_t)((unsigned)!m->wait << 15 | 1u << 14 | 1u << 13 | (unsigned)!m->stathalt << 11 |
			  (unsigned)m->err << 10 | (unsigned)m->srun << 8);
}

static uint32_t hmodel_read(struct readout *r, unsigned word)
{
	struct hmodel *m = r->ctx;
	m->ticks += 16u;
	switch (word) {
	case RO_IDENT: return RO_IDENT_WORD;
	case RO_CYCLES:
		if (m->retiring)
			m->cycles += 1000u;
		m->hi_cycles = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case RO_CYCLESH: return m->hi_cycles;
	case RO_TICKS:
		m->hi_ticks = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case RO_TICKSH: return m->hi_ticks;
	case RO_ADDR:
		m->latched = RO_NO_MEMORY;
		if (m->rev15 && m->ro_addr == ((IMG_SEL_TAIL << 14) | IMG_TL15_HALTED))
			m->latched = (uint64_t)m->x_halted << 1 | (uint64_t)m->halted;
		return m->ro_addr;
	case RO_DATA_LO: return (uint32_t)m->latched;
	case RO_DATA_HI: return (uint32_t)(m->latched >> 32);
	default:
		if (word >= RO_SPY(0) && word <= RO_SPY(15)) {
			if (m->lost)
				return RO_LOST_BIT;
			switch (word - RO_SPY(0)) {
			case RO_SPY_FLAG_1: return hmodel_flag1(m);
			case RO_SPY_PC: return m->pc;
			case RO_SPY_OPC: return m->opc;
			default: return 0xFFFFu;
			}
		}
		return RO_UNMAPPED;
	}
}

static void hmodel_write(struct readout *r, unsigned word, uint32_t v)
{
	struct hmodel *m = r->ctx;
	m->ticks += 16u;
	if (word == RO_ADDR) {
		m->ro_addr = v & 0x3FFFFu;
	} else if (word == RO_SPY(RO_SPY_CLK_W)) {
		const int run = (v & RO_CLK_RUN) != 0;
		++m->clk_writes;
		m->srun = run;
		if (!run && m->drains) {
			m->retiring = 0;
			m->halted = 1;
		} else if (run && m->halted) {
			m->retiring = 1;
			m->halted = 0;
		}
	}
}

// QUUX at the board's stuck instant: SRUN up, ERR down, FLAG-1
// 0xe900, CYCLES standing at 2389615962 with PC 2173 and OPC 2112.
static void hmodel_stuck15(struct hmodel *m)
{
	memset(m, 0, sizeof *m);
	m->rev15 = 1;
	m->cycles = 2389615962ull;
	m->ticks = 5101618753ull;
	m->srun = 1;
	m->pc = 02173;
	m->opc = 02112;
}

static void halt_fail(const char *what, int got, int want)
{
	static const char *const name[] = { "lost", "running", "halted", "stuck" };
	fprintf(stderr, "checkpoint: FAIL: the halt: %s reads %s, wanting %s\n", what,
		got >= -1 && got <= 2 ? name[got + 1] : "?", want >= -1 && want <= 2 ? name[want + 1] : "?");
	++bad;
}

static int halt_found(struct hmodel *m, struct ro_stand *s)
{
	struct readout r;
	memset(&r, 0, sizeof r);
	r.read = hmodel_read;
	r.write = hmodel_write;
	r.ctx = m;
	const int writes = m->clk_writes;
	const int got = ro_found(&r, m->rev15, s);
	if (m->clk_writes != writes) {
		fprintf(stderr, "checkpoint: FAIL: the halt: asking wrote the clock control register\n");
		++bad;
	}
	return got;
}

static void halt_text_has(const struct ro_stand *s, int rev15, const char *what, const char *want)
{
	char text[512];
	ro_stand_text(s, rev15, text, sizeof text);
	if (!strstr(text, want)) {
		fprintf(stderr, "checkpoint: FAIL: the halt: %s's words [%s] do not say [%s]\n", what, text,
			want);
		++bad;
	}
}

static void halt_check(void)
{
	struct hmodel m;
	struct ro_stand s;
	struct readout r;
	memset(&r, 0, sizeof r);
	r.read = hmodel_read;
	r.write = hmodel_write;
	r.ctx = &m;
	const long bad_before = bad;
	int got;

	// ---- the board's: QUUX stuck with SRUN up, as found.
	hmodel_stuck15(&m);
	if ((got = halt_found(&m, &s)) != RO_FOUND_STUCK)
		halt_fail("QUUX stuck, SRUN up and its halted bit down", got, RO_FOUND_STUCK);
	if (s.flag1 != 0xe900u || !s.srun || s.err || s.drained != 0)
		fail("the halt: QUUX stuck: FLAG-1, SRUN, ERR and the halted bit as read",
		     ((uint64_t)s.flag1 << 12) | (unsigned)s.srun << 8 | (unsigned)s.err << 4 | (unsigned)(s.drained & 0xF),
		     (0xe900ull << 12) | 1u << 8);
	halt_text_has(&s, 1, "QUUX stuck", "SRUN up");
	halt_text_has(&s, 1, "QUUX stuck", "2389615962");
	halt_text_has(&s, 1, "QUUX stuck", "PC 2173");
	halt_text_has(&s, 1, "QUUX stuck", "OPC 2112");
	halt_text_has(&s, 1, "QUUX stuck", "FLAG-1 0xe900");
	halt_text_has(&s, 1, "QUUX stuck", "halted bit down");

	// ---- and the same machine after a write of zero: SRUN follows RUN
	// ---- down, and the drain never ends.
	hmodel_stuck15(&m);
	ro_halt(&r);
	if ((got = halt_found(&m, &s)) != RO_FOUND_STUCK)
		halt_fail("QUUX stuck, RUN cleared and the drain not ended", got, RO_FOUND_STUCK);
	halt_text_has(&s, 1, "QUUX stuck and RUN cleared", "SRUN down");

	// ---- QUUX running, halted by the console, drained: halted.
	hmodel_stuck15(&m);
	m.retiring = 1;
	m.drains = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_RUNNING)
		halt_fail("QUUX retiring", got, RO_FOUND_RUNNING);
	ro_halt(&r);
	if ((got = halt_found(&m, &s)) != RO_FOUND_HALTED)
		halt_fail("QUUX halted by a write of zero and drained", got, RO_FOUND_HALTED);
	// ---- and found so, which is what `--already-halted` takes.
	if ((got = halt_found(&m, &s)) != RO_FOUND_HALTED)
		halt_fail("QUUX found halted", got, RO_FOUND_HALTED);

	// ---- QUUX halted by its own HALT word under ERROR-STOP-ENABLE:
	// ---- drained, SRUN down, ERR up.
	hmodel_stuck15(&m);
	m.srun = 0;
	m.x_halted = 1;
	m.halted = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_HALTED)
		halt_fail("QUUX halted by a HALT word", got, RO_FOUND_HALTED);

	// ---- the CADR stuck: SRUN up, nothing in
	// ---- FLAG-1 naming a halt, once with -WAIT low.
	hmodel_stuck15(&m);
	m.rev15 = 0;
	if ((got = halt_found(&m, &s)) != RO_FOUND_STUCK)
		halt_fail("the CADR stuck, SRUN up and FLAG-1 naming no halt", got, RO_FOUND_STUCK);
	if (s.drained != -1)
		fail("the halt: the CADR's halted bit, which it has not got", (unsigned)s.drained, (uint64_t)-1);
	halt_text_has(&s, 0, "the CADR stuck", "SRUN up");
	halt_text_has(&s, 0, "the CADR stuck", "PC 2173");
	halt_text_has(&s, 0, "the CADR stuck", "names no halt");
	hmodel_stuck15(&m);
	m.rev15 = 0;
	m.wait = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_STUCK)
		halt_fail("the CADR stuck in a bus wait", got, RO_FOUND_STUCK);
	halt_text_has(&s, 0, "the CADR stuck in a bus wait", "-WAIT low");

	// ---- the CADR's three halts: the console's, HALT-CONS's under
	// ---- ERRSTOP and the statistics counter's.
	hmodel_stuck15(&m);
	m.rev15 = 0;
	m.retiring = 1;
	m.drains = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_RUNNING)
		halt_fail("the CADR retiring", got, RO_FOUND_RUNNING);
	ro_halt(&r);
	if ((got = halt_found(&m, &s)) != RO_FOUND_HALTED)
		halt_fail("the CADR halted by a write of zero", got, RO_FOUND_HALTED);
	hmodel_stuck15(&m);
	m.rev15 = 0;
	m.err = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_HALTED)
		halt_fail("the CADR halted with ERR up", got, RO_FOUND_HALTED);
	hmodel_stuck15(&m);
	m.rev15 = 0;
	m.stathalt = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_HALTED)
		halt_fail("the CADR halted by the statistics counter", got, RO_FOUND_HALTED);

	// ---- a standing machine whose registers do not answer is not halted
	// ---- either: nothing can be said of it.
	hmodel_stuck15(&m);
	m.rev15 = 0;
	m.srun = 0;
	m.lost = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_LOST)
		halt_fail("a standing CADR whose diagnostic registers are not answered", got, RO_FOUND_LOST);
	hmodel_stuck15(&m);
	m.halted = 1;
	m.srun = 0;
	m.lost = 1;
	if ((got = halt_found(&m, &s)) != RO_FOUND_LOST)
		halt_fail("a standing QUUX whose diagnostic registers are not answered", got,
			  RO_FOUND_LOST);

	if (bad != bad_before)
		return;
	printf("checkpoint: the halt: a machine standing with SRUN up and no halt named, or on QUUX "
	       "undrained, is stuck and not halted; the console's, HALT-CONS's, the statistics counter's "
	       "and QUUX's drained halt are halts\n");
}

// ---- QUUX's main memory in its own words ----------------------------------

static void memory_fail(const char *what, const char *got, const char *want)
{
	fprintf(stderr, "checkpoint: FAIL: main memory: %s: [%s], wanting [%s]\n", what, got, want);
	++bad;
}

// How many lines of the sidecar at `side` are `line` (`whole` 1) or begin
// with it (`whole` 0).
// The resume line of `b` with its checkpoint named `chk`: what the checks of
// the line's flags compare, whatever the binding's own name for the file.
// The name itself is held by `sidecar_line_check`, on the binding's own.
static void resume_of(const struct binding *b, const char *chk, char *out, size_t n)
{
	static struct binding named;
	named = *b;
	snprintf(named.checkpoint, sizeof named.checkpoint, "%s", chk);
	bind_resume_command(&named, out, n);
}

static int sidecar_has(const char *side, const char *line, int whole)
{
	FILE *f = fopen(side, "r");
	char buf[8192];
	int n = 0;
	while (f && fgets(buf, sizeof buf, f)) {
		buf[strcspn(buf, "\n")] = '\0';
		n += whole ? strcmp(buf, line) == 0 : strncmp(buf, line, strlen(line)) == 0;
	}
	if (f)
		fclose(f);
	return n;
}

static void memory_words_check(const char *side)
{
	char got[128], err[512];
	// What a person reads: the CADR's boards, QUUX's amount.
	{
		const struct { int quux; unsigned units; const char *want; } t[] = {
			{0, 32, "32 memory boards"}, {0, 60, "60 memory boards"}, {0, 1, "1 memory board"},
			{1, 512, "32MW of main memory"}, {1, 1024, "64MW of main memory"},
			{1, 32, "2MW of main memory"}, {1, 60, "3840KW of main memory"}};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			bind_memory_words(t[i].quux, t[i].units, got, sizeof got);
			if (strcmp(got, t[i].want) != 0)
				memory_fail("said", got, t[i].want);
		}
	}
	// What the flags take: each machine's own, and the other's refused by
	// name; QUUX's in whole megawords with the unit, within the board's room.
	{
		const struct {
			int quux; const char *boards, *size; int rc; unsigned units; const char *says;
		} t[] = {
			{0, NULL, NULL, 0, 0, NULL},
			{1, NULL, NULL, 0, 0, NULL},
			{0, "32", NULL, 0, 32, NULL},
			{0, "60", NULL, 0, 60, NULL},
			{0, "1", NULL, 0, 1, NULL},
			{0, "61", NULL, 2, 0, "1 to 60"},
			{0, "0", NULL, 2, 0, "1 to 60"},
			{0, "32x", NULL, 2, 0, "1 to 60"},
			{0, NULL, "2MW", 2, 0, "--main-memory-size is QUUX's"},
			{1, "512", NULL, 2, 0, "--boards is the CADR's"},
			{1, "512", NULL, 2, 0, "--main-memory-size <n>MW, such as --main-memory-size 32MW"},
			{1, NULL, "32MW", 0, 512, NULL},
			{1, NULL, "1MW", 0, 16, NULL},
			{1, NULL, "33MW", 2, 0, "1MW to 32MW"},
			{1, NULL, "0MW", 2, 0, "1MW to 32MW"},
			{1, NULL, "32", 2, 0, "main memory is given in megawords, with the unit MW, such as 32MW"},
			{1, NULL, "32M", 2, 0, "main memory is given in megawords, with the unit MW, such as 32MW"},
			{1, NULL, "2048KW", 2, 0, "main memory is given in megawords, with the unit MW, such as 32MW"},
			{1, "512", "32MW", 2, 0, "--boards is the CADR's"},
		};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			unsigned units = 0xDEADu;
			err[0] = '\0';
			const int rc = bind_memory_asked(t[i].quux, t[i].boards, t[i].size, 512u, &units,
							 err, sizeof err);
			char what[160];
			snprintf(what, sizeof what, "%s with --boards %s --main-memory-size %s",
				 t[i].quux ? "QUUX" : "the CADR", t[i].boards ? t[i].boards : "-",
				 t[i].size ? t[i].size : "-");
			if (rc != t[i].rc) {
				snprintf(got, sizeof got, "%d, %s", rc, err);
				memory_fail(what, got, t[i].rc ? "refused" : "taken");
			} else if (rc == 0 && units != t[i].units) {
				char w[32];
				snprintf(got, sizeof got, "%u units", units);
				snprintf(w, sizeof w, "%u units", t[i].units);
				memory_fail(what, got, w);
			} else if (t[i].says && !strstr(err, t[i].says)) {
				memory_fail(what, err, t[i].says);
			}
		}
	}
	// What the sidecar records: QUUX's amount under muir's flag's name, and
	// the CADR's boards; read back to the same units either way.
	{
		const struct { int quux; unsigned units; const char *line, *not; } t[] = {
			{1, 512, "main-memory-size: 32MW", "boards:"},
			{1, 60, "main-memory-size: 3840KW", "boards:"},
			{0, 32, "boards: 32", "main-memory-size:"}};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			struct binding b, rd;
			bind_init(&b);
			b.quux = t[i].quux;
			b.boards = t[i].units;
			b.revision = t[i].quux ? 16u : 0u;
			b.sync_k = t[i].quux ? 20u : 0u;
			snprintf(b.checkpoint, sizeof b.checkpoint, "m.chk");
			if (bind_write(&b, side, NULL, 0, err, sizeof err) != 0) {
				memory_fail("a sidecar written", err, "written");
				continue;
			}
			if (sidecar_has(side, t[i].line, 1) != 1)
				memory_fail("the sidecar's memory line", "absent", t[i].line);
			if (sidecar_has(side, t[i].not, 0) != 0)
				memory_fail("the other machine's memory line in the sidecar", t[i].not, "none");
			bind_init(&rd);
			if (bind_read(&rd, side, err, sizeof err) != 0 || rd.boards != t[i].units) {
				snprintf(got, sizeof got, "%u units %s", rd.boards, err);
				memory_fail("the sidecar's memory read back", got, t[i].line);
			}
		}
		// A sidecar written before QUUX's line was says boards, and is read.
		FILE *f = fopen(side, "w");
		if (f) {
			fprintf(f, "format: %s\nmachine: quux\nboards: 512\n", BIND_FORMAT);
			fclose(f);
		}
		struct binding rd;
		bind_init(&rd);
		if (bind_read(&rd, side, err, sizeof err) != 0 || rd.boards != 512u)
			memory_fail("an older QUUX sidecar's boards", err, "512 units");
		// An amount the sidecar cannot be held to is refused, not guessed.
		static const char *const badv[] = {"32", "32M", "2.5MW", "100KW", "MW"};
		for (unsigned i = 0; i < sizeof badv / sizeof badv[0]; ++i) {
			f = fopen(side, "w");
			if (f) {
				fprintf(f, "format: %s\nmachine: quux\nmain-memory-size: %s\n",
					BIND_FORMAT, badv[i]);
				fclose(f);
			}
			bind_init(&rd);
			if (bind_read(&rd, side, err, sizeof err) == 0)
				memory_fail("a sidecar's amount that is no amount", badv[i], "refused");
		}
		remove(side);
	}
}

// ---- the CADR's Chaosnet address, the interface's own --------------------
//
// **THE ADDRESS IS READ OFF THE INTERFACE, AS `cadr-chaosnet` READS IT.**  The
// board's interface holds the switches `cadr-chaosnet` set, and muir refuses
// to resume a checkpoint at any address but the one its switches carry: a
// checkpoint written at muir's default on a board at 177201, and a resume
// line naming no address, was refused on the board ("switches read 177201,
// this machine's 177001").  So the face below is the interface's register
// table as `chaos_face.h` gives it, and the checkpoint, the sidecar and its
// resume line are each held to carry the address it holds.  Every failure
// prints one line under one prefix, which mutants 54 and 55 are judged by.

struct chaos_model {
	uint32_t ident, myaddr;
	unsigned reads;
};

static uint32_t chaos_model_read(struct chaos_face *f, unsigned word)
{
	struct chaos_model *m = f->ctx;
	++m->reads;
	if (word == CHAOS_IDENT)
		return m->ident;
	if (word == CHAOS_MYADDR)
		return m->myaddr;
	return 0;
}

static void chaos_model_write(struct chaos_face *f, unsigned word, uint32_t v)
{
	(void)f;
	(void)word;
	(void)v;
}

static void chaos_fail(const char *what, unsigned long long got, unsigned long long want)
{
	fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: %s is %llo, wanting %llo\n",
		what, got, want);
	++bad;
}

static unsigned chaos_resolve(uint32_t ident, uint32_t myaddr, int asked, unsigned asked_address,
			      char *msg, size_t n)
{
	struct chaos_model m = { ident, myaddr, 0 };
	struct chaos_face f = { chaos_model_read, chaos_model_write, &m };
	return bind_chaos_address(&f, asked, asked_address, msg, n);
}

// **EVERY NAME IS THE PACK FOLDER's, WHATEVER FORM THE CAPTURE WAS GIVEN**
// (`bind_relative`): the bay's default `--pack-dir`, absolute, and `--pack-dir
// .` in the pack folder write one line, `./disk-pack-0.img` and
// `checkpoints/x.chk`; a checkpoint or a pack outside the pack folder, a
// folder beside it whose name begins with its name, and a checkpoint whose
// folder is not there are refused, with the binding left as it was.  Every
// failure prints one line under one prefix, naming its leg.
static void folder_fail(const char *leg, const char *detail)
{
	fprintf(stderr, "checkpoint: FAIL: the pack folder: %s: [%s]\n", leg, detail);
	++bad;
}

static void folder_binding(struct binding *b, const char *pack, const char *chk)
{
	bind_init(b);
	b->quux = 1;
	b->boards = 512;
	b->revision = 16;
	b->sync_k = 38;
	b->u[0].present = 1;
	snprintf(b->u[0].path, sizeof b->u[0].path, "%s", pack);
	b->present = 1;
	snprintf(b->checkpoint, sizeof b->checkpoint, "%s", chk);
}

// 1 when the binding of `pack` and `chk` under `dir` is refused and left as it
// was, 0 when it is taken, -1 when it is refused and changed.
static int folder_refused(const char *dir, const char *pack, const char *chk, char *err,
			  size_t n)
{
	static struct binding b;
	folder_binding(&b, pack, chk);
	if (bind_relative(&b, dir, chk, err, n) == 0)
		return 0;
	return strcmp(b.u[0].path, pack) == 0 && strcmp(b.checkpoint, chk) == 0 ? 1 : -1;
}

static void folder_check(const char *work)
{
	static const char want[] = "quux --rtl --microcycle-ns 19 --disk-pack ./disk-pack-0.img,0 "
		"--resume checkpoints/x.chk";
	char top[300], packs[320], chks[340], beside[340], away[340];
	char pack[400], chk[400], dir[400], line[4096], err[1024];
	snprintf(top, sizeof top, "%s/folders", work);
	snprintf(packs, sizeof packs, "%s/packs", top);
	snprintf(chks, sizeof chks, "%s/checkpoints", packs);
	snprintf(beside, sizeof beside, "%s/packs-beside", top);
	snprintf(away, sizeof away, "%s/away", top);
	mkdir(top, 0755);
	mkdir(packs, 0755);
	mkdir(chks, 0755);
	mkdir(beside, 0755);
	mkdir(away, 0755);
	static struct binding b;

	// The bay's default, absolute, and the same with a trailing slash and
	// a `./` in the checkpoint's path: one relative line.
	for (int form = 0; form < 2; ++form) {
		snprintf(dir, sizeof dir, form ? "%s/" : "%s", packs);
		snprintf(pack, sizeof pack, "%s/disk-pack-0.img", packs);
		snprintf(chk, sizeof chk, form ? "%s/./checkpoints/x.chk" : "%s/checkpoints/x.chk",
			 packs);
		folder_binding(&b, pack, chk);
		err[0] = '\0';
		if (bind_relative(&b, dir, chk, err, sizeof err) != 0) {
			folder_fail("an absolute --pack-dir does not write a relative line", err);
			continue;
		}
		bind_resume_command(&b, line, sizeof line);
		if (strcmp(line, want) != 0)
			folder_fail("an absolute --pack-dir does not write a relative line", line);
	}
	// `--pack-dir .` in the pack folder, as the Kria's capture ran: the same.
	{
		char here[4096];
		if (getcwd(here, sizeof here) && chdir(packs) == 0) {
			folder_binding(&b, "./disk-pack-0.img", "checkpoints/x.chk");
			err[0] = '\0';
			if (bind_relative(&b, ".", "checkpoints/x.chk", err, sizeof err) != 0) {
				folder_fail("--pack-dir . does not write the same line", err);
			} else {
				bind_resume_command(&b, line, sizeof line);
				if (strcmp(line, want) != 0)
					folder_fail("--pack-dir . does not write the same line", line);
			}
			if (chdir(here) != 0)
				folder_fail("the test's own folder, not found again", here);
		} else {
			folder_fail("the pack folder, not entered", packs);
		}
	}
	// Refused, and left as it was.
	snprintf(pack, sizeof pack, "%s/disk-pack-0.img", packs);
	snprintf(chk, sizeof chk, "%s/x.chk", top);
	err[0] = '\0';
	int r = folder_refused(packs, pack, chk, err, sizeof err);
	if (r != 1 || !strstr(err, "is not in the pack folder"))
		folder_fail("a checkpoint outside the pack folder is taken", r ? err : chk);
	snprintf(chk, sizeof chk, "%s/x.chk", beside);
	r = folder_refused(packs, pack, chk, err, sizeof err);
	if (r != 1)
		folder_fail("a folder beside the pack folder is taken as in it", r ? err : chk);
	snprintf(chk, sizeof chk, "%s/checkpoints/x.chk", packs);
	snprintf(pack, sizeof pack, "%s/disk-pack-0.img", away);
	r = folder_refused(packs, pack, chk, err, sizeof err);
	if (r != 1 || !strstr(err, "is not in the pack folder"))
		folder_fail("a pack outside the pack folder is taken", r ? err : pack);
	snprintf(pack, sizeof pack, "%s/disk-pack-0.img", packs);
	snprintf(chk, sizeof chk, "%s/nowhere/x.chk", packs);
	r = folder_refused(packs, pack, chk, err, sizeof err);
	if (r != 1)
		folder_fail("a checkpoint whose folder is not there is taken", r ? err : chk);
	rmdir(chks);
	rmdir(packs);
	rmdir(beside);
	rmdir(away);
	rmdir(top);
}

// **THE SIDECAR'S RESUME LINE IS THE LINE `cadr-checkpoint` PRINTS, AND BOTH
// RUN FROM THE PACK FOLDER.**  The card's layout: the program run in the pack
// folder with `--pack-dir .` and `-o checkpoints/x.chk` names the pack
// `./disk-pack-0.img` and the checkpoint `checkpoints/x.chk`, and writes the
// sidecar beside the checkpoint.  The line written, the line given back to
// print and the line `--verify` gives from the sidecar read back must be one
// line, the one written out here by hand, with no path in it absolute.  It
// once named the checkpoint `./x.chk`, beside the sidecar, while its pack
// stayed relative to the pack folder, so no one folder ran it.  Every failure
// prints one line under one prefix, naming its leg.
static void line_fail(const char *leg, const char *line)
{
	fprintf(stderr, "checkpoint: FAIL: the sidecar's resume line: %s: [%s]\n", leg, line);
	++bad;
}

static void sidecar_line_check(const char *work)
{
	static const char want[] = "quux --rtl --microcycle-ns 19 --disk-pack ./disk-pack-0.img,0 "
		"--resume checkpoints/x.chk";
	char card[300], chks[320], side[360], printed[4096] = "", written[8192] = "", line[8192];
	char err[1024] = "";
	snprintf(card, sizeof card, "%s/card", work);
	snprintf(chks, sizeof chks, "%s/checkpoints", card);
	snprintf(side, sizeof side, "%s/x.chk%s", chks, BIND_SUFFIX);
	mkdir(card, 0755);
	mkdir(chks, 0755);
	struct binding xb, rd;
	bind_init(&xb);
	xb.quux = 1;
	xb.boards = 512;
	xb.revision = 16;
	xb.sync_k = 38;
	xb.u[0].present = 1;
	snprintf(xb.u[0].path, sizeof xb.u[0].path, "./disk-pack-0.img");
	xb.present = 1;
	snprintf(xb.checkpoint, sizeof xb.checkpoint, "checkpoints/x.chk");
	if (bind_write(&xb, side, printed, sizeof printed, err, sizeof err) != 0) {
		line_fail("not written", err);
		return;
	}
	int resumes = 0, kept = 0;
	FILE *sf = fopen(side, "r");
	while (sf && fgets(line, sizeof line, sf)) {
		line[strcspn(line, "\n")] = '\0';
		kept += strcmp(line, "checkpoint: checkpoints/x.chk") == 0;
		if (strncmp(line, "resume: ", 8) == 0 && ++resumes == 1)
			snprintf(written, sizeof written, "%s", line + 8);
	}
	if (sf)
		fclose(sf);
	if (resumes != 1)
		line_fail("not one resume line in the sidecar", written);
	if (kept != 1)
		line_fail("the checkpoint line does not keep the name the capture gave", side);
	if (strcmp(printed, written) != 0)
		line_fail("the printed line is not the sidecar's", printed);
	if (strcmp(written, want) != 0)
		line_fail("it does not run from the pack folder", written);
	if (strstr(written, " /") || strstr(written, ",/") || strstr(printed, " /") ||
	    strstr(printed, ",/"))
		line_fail("a path in it is absolute", written);
	bind_init(&rd);
	if (bind_read(&rd, side, err, sizeof err) != 0) {
		line_fail("the sidecar not read back", err);
	} else {
		char verify[4096];
		bind_resume_command(&rd, verify, sizeof verify);
		if (strcmp(verify, written) != 0)
			line_fail("the line --verify gives is not the sidecar's", verify);
	}
	remove(side);
	rmdir(chks);
	rmdir(card);
}

// ---- QUUX's 253-257, the host's flags --------------------------------------
//
// **muir REFUSES A RESUME UNDER OTHER `--ethernet-mac`, `--ip-address` OR
// `--ip-gateway` THAN THE CHECKPOINT'S** (QUUX's Ethernet contract, section
// 2.9), given or by default, so the resume line names the three the board's
// device holds, in muir's own spellings, and the sidecar records them and
// gives the same line back.  Every failure prints one line under one prefix.
static void ethernet_host_check(const char *work)
{
	struct binding b, rd;
	bind_init(&b);
	b.quux = 1;
	b.revision = 16;
	b.sync_k = 20;
	b.boards = 512;
	b.running = 0;
	b.eth = 1;
	static const uint8_t mac[6] = { 0x02, 0x5a, 0x11, 0x22, 0x33, 0x44 };
	memcpy(b.eth_mac, mac, 6);
	b.eth_address = 169u << 24 | 254u << 16 | 101u << 8 | 2u;
	b.eth_netmask = 0xFFFFFFFCu;
	b.eth_gateway = 169u << 24 | 254u << 16 | 101u << 8 | 1u;
	snprintf(b.checkpoint, sizeof b.checkpoint, "/mnt/card/q.chk");
	static const char want[] = "quux --rtl --microcycle-ns 10 "
		"--ethernet-mac 02:5a:11:22:33:44 --ip-address 169.254.101.2/30 --ip-gateway 169.254.101.1 "
		"--resume q.chk";
	char cmd[4096], side[400];
	resume_of(&b, "q.chk", cmd, sizeof cmd);
	if (strcmp(cmd, want) != 0) {
		fprintf(stderr, "checkpoint: FAIL: the host's flags: the resume line is [%s], wanting [%s]\n",
			cmd, want);
		++bad;
	}
	snprintf(side, sizeof side, "%s/eth.chk%s", work, BIND_SUFFIX);
	char err[1024] = "";
	bind_init(&rd);
	if (bind_write(&b, side, NULL, 0, err, sizeof err) != 0 || bind_read(&rd, side, err, sizeof err) != 0) {
		fprintf(stderr, "checkpoint: FAIL: the host's flags: the sidecar: %s\n", err);
		++bad;
	} else {
		resume_of(&rd, "q.chk", cmd, sizeof cmd);
		if (strcmp(cmd, want) != 0) {
			fprintf(stderr, "checkpoint: FAIL: the host's flags: the resume line from the sidecar read "
				"back is [%s], wanting [%s]\n", cmd, want);
			++bad;
		}
		if (sidecar_has(side, "ethernet-mac: 02:5a:11:22:33:44", 1) != 1 ||
		    sidecar_has(side, "ip-address: 169.254.101.2/30", 1) != 1 ||
		    sidecar_has(side, "ip-gateway: 169.254.101.1", 1) != 1) {
			fprintf(stderr, "checkpoint: FAIL: the host's flags: the sidecar's three lines\n");
			++bad;
		}
	}
	remove(side);
	// A sidecar written before the device's lines names none of them.
	b.eth = 0;
	resume_of(&b, "q.chk", cmd, sizeof cmd);
	if (strstr(cmd, "--ethernet-mac") || strstr(cmd, "--ip-")) {
		fprintf(stderr, "checkpoint: FAIL: the host's flags: a resume line without the device's "
			"words is [%s]\n", cmd);
		++bad;
	}
}

static void chaos_address_check(const struct cadr_image *img, const struct chk_declared *decl,
				const char *work)
{
	char msg[512];

	// 1. The interface holds 177201 and no flag is given: 177201.
	const unsigned a = chaos_resolve(CHAOS_IDENT_WORD, 0177201u, 0, 0, msg, sizeof msg);
	if (a != 0177201u)
		chaos_fail("the interface's 177201 with no --chaos-address", a, 0177201u);

	// ... and the checkpoint carries it: the body at that address is one
	// byte apart from the body at muir's default, and that byte is the
	// switches' low byte, 0201.
	{
		struct chk_declared d = *decl;
		d.chaos_address = BIND_CHAOS_DEFAULT;
		struct chk b0, b1;
		body_of(img, &d, &b0);
		d.chaos_address = a;
		body_of(img, &d, &b1);
		const long at = one_byte_apart(&b0, &b1);
		if (at < 0 || b1.p[at] != 0201u || b0.p[at] != 0001u)
			chaos_fail("the checkpoint's switches, the byte apart from 177001's",
				   at < 0 ? 0 : b1.p[at], 0201u);
		chk_free(&b0);
		chk_free(&b1);
	}

	// ... and the resume line names it, on the board and from the sidecar
	// read back, as `--verify` prints it.
	{
		struct binding b, rd;
		bind_init(&b);
		b.boards = 32;
		b.chaos_address = a;
		b.running = 1;
		snprintf(b.checkpoint, sizeof b.checkpoint, "/mnt/card/c.chk");
		char cmd[4096], side[400];
		static const char want[] = "cadr --rtl --timing-model fpga --main-memory-boards 32 "
			"--chaos-address 177201 --resume c.chk";
		resume_of(&b, "c.chk", cmd, sizeof cmd);
		if (strcmp(cmd, want) != 0) {
			fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: the resume line is [%s], "
				"wanting [%s]\n", cmd, want);
			++bad;
		}
		snprintf(side, sizeof side, "%s/chaos.chk%s", work, BIND_SUFFIX);
		char err[1024] = "";
		bind_init(&rd);
		if (bind_write(&b, side, NULL, 0, err, sizeof err) != 0 || bind_read(&rd, side, err, sizeof err) != 0) {
			fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: the sidecar: %s\n", err);
			++bad;
		} else {
			// The read back goes down `chk_chaos_address`, which mutant 8
			// replaces; that mutant is judged by the file muir refuses,
			// and the parser's own spellings are skipped under it too.
#if CHK_MUTATE != 8
			if (rd.chaos_address != 0177201u)
				chaos_fail("the sidecar's address read back", rd.chaos_address, 0177201u);
			resume_of(&rd, "c.chk", cmd, sizeof cmd);
			if (strcmp(cmd, want) != 0) {
				fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: the resume line "
					"from the sidecar read back is [%s], wanting [%s]\n", cmd, want);
				++bad;
			}
#endif
			if (sidecar_has(side, "chaos-address: 177201", 1) != 1)
				chaos_fail("the sidecar's chaos-address lines", 0, 1);
			if (sidecar_has(side, "resume: cadr --rtl --timing-model fpga --main-memory-boards 32 "
					"--chaos-address 177201 --resume /mnt/card/c.chk", 1) != 1)
				chaos_fail("the sidecar's resume line with the address", 0, 1);
		}
		remove(side);
		// A sidecar written before the line names no address.
		bind_init(&rd);
		FILE *sf = fopen(side, "w");
		if (sf) {
			fprintf(sf, "format: %s\nmachine: cadr\nboards: 32\n", BIND_FORMAT);
			fclose(sf);
		}
		if (bind_read(&rd, side, err, sizeof err) != 0 || rd.chaos_address != 0)
			chaos_fail("an old sidecar's address", rd.chaos_address, 0);
		remove(side);
		// QUUX's line is as it was: QUUX has no Chaosnet.
		b.quux = 1;
		b.revision = 16;
		b.sync_k = 0;
		resume_of(&b, "q.chk", cmd, sizeof cmd);
		if (strstr(cmd, "--chaos-address")) {
			fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: QUUX's resume line "
				"names one: [%s]\n", cmd);
			++bad;
		}
	}

	// 2. --chaos-address the interface's own: that, and nothing to say of
	// a disagreement.
	unsigned got = chaos_resolve(CHAOS_IDENT_WORD, 0177201u, 1, 0177201u, msg, sizeof msg);
	if (got != 0177201u)
		chaos_fail("--chaos-address 177201 on an interface at 177201", got, 0177201u);
	if (strstr(msg, "177001") || strstr(msg, "refuse")) {
		fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: an agreeing flag said [%s]\n", msg);
		++bad;
	}

	// 3. --chaos-address another: the flag wins, and the program says the
	// two disagree, naming both.
	got = chaos_resolve(CHAOS_IDENT_WORD, 0177201u, 1, 0177100u, msg, sizeof msg);
	if (got != 0177100u)
		chaos_fail("--chaos-address 177100 on an interface at 177201", got, 0177100u);
	if (!strstr(msg, "177100") || !strstr(msg, "177201")) {
		fprintf(stderr, "checkpoint: FAIL: the Chaosnet address: a disagreeing flag said [%s], "
			"which names not both 177100 and 177201\n", msg);
		++bad;
	}

	// 4. An interface that is not there, or whose switches nothing set:
	// the flag, or else muir's default, and said.
	got = chaos_resolve(CADR_IDENT_NONE, 0177201u, 0, 0, msg, sizeof msg);
	if (got != BIND_CHAOS_DEFAULT || !msg[0])
		chaos_fail("no interface (\"NONE\") and no flag", got, BIND_CHAOS_DEFAULT);
	got = chaos_resolve(CHAOS_IDENT_WORD, 0, 0, 0, msg, sizeof msg);
	if (got != BIND_CHAOS_DEFAULT || !msg[0])
		chaos_fail("switches at 0 and no flag", got, BIND_CHAOS_DEFAULT);
	got = chaos_resolve(CHAOS_IDENT_WORD, 0, 1, 0177100u, msg, sizeof msg);
	if (got != 0177100u)
		chaos_fail("switches at 0 and --chaos-address 177100", got, 0177100u);
	got = bind_chaos_address(NULL, 0, 0, msg, sizeof msg);
	if (got != BIND_CHAOS_DEFAULT || !msg[0])
		chaos_fail("no face at all and no flag", got, BIND_CHAOS_DEFAULT);

	printf("checkpoint: the CADR's Chaosnet address is the interface's own, 177201 in the "
	       "checkpoint and on the resume line, and a flag that disagrees is said\n");
}

int main(int argc, char **argv)
{
	// **THE SCRATCH DIRECTORY IS NOT OPTIONAL.**  Half of what this file
	// checks --- the sidecar written, read back and made to notice a pack
	// that has moved --- needs somewhere to put three small files, and a
	// check that quietly does less when an argument is missing is the
	// failure this repository keeps meeting.  So it is demanded.
	//
	// **AND NEITHER ARE QUUX'S DISKS.**  A QUUX disk is bound by its footers,
	// and the files that hold that to something are muir's `data/quux-disk*`,
	// made by qemu and never by this program; the directory holding them is
	// the second argument, and the Makefile checks their digests first.
	if (argc < 3) {
		fprintf(stderr, "usage: checkpoint_test <scratch directory> <QUUX's disks, "
			"muir's data/> [<CADR checkpoint to write> [<QUUX's to write>]]\n");
		return 2;
	}
	const char *work = argv[1];
	const char *q8 = argv[2];
	const char *out = argc > 3 ? argv[3] : NULL;
	const char *quux_out = argc > 4 ? argv[4] : NULL;

	if (chk_rtl_mutation())
		printf("checkpoint: THIS IS A MUTANT --- %s\n", chk_rtl_mutation());

	// ---- the halt a checkpoint is taken in ------------------------------
	halt_check();

	// ---- SHA-256, against the standard's own vectors ---------------------
	//
	// **A HASH THAT IS SELF-CONSISTENTLY WRONG AGREES WITH ITSELF PERFECTLY
	// AND WITH NOBODY ELSE**, and the whole point of the digest in a
	// sidecar is that somebody with `sha256sum` and no software of ours can
	// check it.  So it is held to FIPS 180-4's published values and not to
	// a second implementation of the same mistake.
	{
		struct { const char *in; unsigned long repeat; const char *want; } v[] = {
			{ "", 1,
			  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
			{ "abc", 1,
			  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
			{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 1,
			  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
			// A million 'a's, fed a thousand at a time: the vector that
			// exercises the length field and the buffering together.
			{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 20000,
			  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
		};
		for (unsigned i = 0; i < sizeof v / sizeof v[0]; ++i) {
			struct sha256 h;
			sha256_init(&h);
			for (unsigned long k = 0; k < v[i].repeat; ++k)
				sha256_feed(&h, v[i].in, strlen(v[i].in));
			uint8_t d[SHA256_BYTES];
			char hex[SHA256_HEX];
			sha256_end(&h, d);
			sha256_hex(d, hex);
			if (strcmp(hex, v[i].want) != 0) {
				fprintf(stderr, "SHA-256 vector %u is %s, the standard "
					"says %s\n", i, hex, v[i].want);
				++bad;
			}
		}
	}

	// ---- a pack's geometry, which is its size and nothing else -----------
	//
	// `Unit::load` REFUSES a checkpoint whose geometry is not the resuming
	// drive's, so a geometry guessed rather than measured turns into a
	// refusal at the far end.  It is measured the way `cadr-disk-packs`
	// measures it: from the file's length.
	{
		uint32_t c = 0, h = 0, b = 0;
		if (bind_geometry_of_size(269562880ull, &c, &h, &b) != 0 ||
		    c != 815 || h != 19 || b != 17)
			fail("the T-300's geometry", ((uint64_t)c << 32) | (h << 8) | b, 0);
		if (bind_geometry_of_size(70937600ull, &c, &h, &b) != 0 ||
		    c != 815 || h != 5 || b != 17)
			fail("the T-80's geometry", ((uint64_t)c << 32) | (h << 8) | b, 0);
		// One byte short is a pack still being copied in, and is no drive.
		if (bind_geometry_of_size(269562879ull, &c, &h, &b) == 0)
			fail("a file one byte short was taken for a pack", 1, 0);
	}

	// ---- the sidecar: written, read back, and made to notice ------------
	//
	// Two small files stand in for packs.  `bind_verify` digests whatever
	// path it is given and does not care what a pack's size is, so the
	// property under test --- that a pack which has moved since the
	// checkpoint is NAMED rather than passed over --- is reachable without
	// a quarter of a gigabyte.
	{
		// Short by construction: `struct binding` holds a checkpoint's name in
		// 512 bytes and a pack's in 1024, and a scratch name that could not
		// fit would be a warning here rather than a finding.
		char a[256], b2[256], side[320], stand[256];
		snprintf(a, sizeof a, "%s/stand-in-pack-0", work);
		snprintf(b2, sizeof b2, "%s/stand-in-pack-1", work);
		snprintf(stand, sizeof stand, "%s/stand-in.chk", work);
		snprintf(side, sizeof side, "%s%s", stand, BIND_SUFFIX);
		FILE *f = fopen(a, "wb");
		if (f) { fputs("the pack as it was", f); fclose(f); }
		f = fopen(b2, "wb");
		if (f) { fputs("the other pack", f); fclose(f); }
		f = fopen(stand, "wb");
		if (f) { fputs("a checkpoint, for the purposes of this check", f); fclose(f); }

		struct binding w;
		bind_init(&w);
		w.boards = 32;
		w.microcycles = 1234567890ull;
		w.ns = 9876543210ull;
		w.machine_halted_first = 1;
		snprintf(w.taken, sizeof w.taken, "2026-09-11T19:30:00+0300");
		snprintf(w.checkpoint, sizeof w.checkpoint, "%s", stand);
		if (sha256_file(stand, w.checkpoint_sha, &w.checkpoint_bytes) != 0)
			fail("the stand-in checkpoint could not be digested", 1, 0);
		w.u[0].present = 1;
		snprintf(w.u[0].path, sizeof w.u[0].path, "%s", a);
		w.u[0].bytes = strlen("the pack as it was");
		w.u[0].cylinders = 815; w.u[0].heads = 19; w.u[0].blocks_per_track = 17;
		w.u[3].present = 1;
		snprintf(w.u[3].path, sizeof w.u[3].path, "%s", b2);
		w.u[3].bytes = strlen("the other pack");
		w.u[3].cylinders = 815; w.u[3].heads = 5; w.u[3].blocks_per_track = 17;
		w.u[3].read_only = 1;
		w.present = 2;
		// A CADR pack is declared to the checkpoint as its geometry.
		{
			uint32_t dc = 0, dh = 0, db = 0;
			bind_declared(&w.u[3], &dc, &dh, &db);
			if (dc != 815 || dh != 5 || db != 17)
				fail("a CADR pack's declared geometry", (uint64_t)dc * dh * db, 815u * 5u * 17u);
		}
		char err[512] = "";
		if (bind_digest(&w, err, sizeof err) != 0)
			fail("the stand-in packs could not be digested", 1, 0);
		// **A DIGEST OF NOTHING IS NOT A DIGEST.**  Two different files
		// must have two different digests, or the check below would pass
		// against a binding that recorded one constant.
		if (strcmp(w.u[0].sha256, w.u[3].sha256) == 0)
			fail("two different packs digested the same", 1, 0);
		if (bind_write(&w, side, NULL, 0, err, sizeof err) != 0)
			fail("the sidecar could not be written", 1, 0);

		struct binding rd;
		if (bind_read(&rd, side, err, sizeof err) != 0) {
			fprintf(stderr, "reading the sidecar back: %s\n", err);
			++bad;
		} else {
			if (rd.present != 2)
				fail("the sidecar's pack count", rd.present, 2);
			if (!rd.u[0].present || !rd.u[3].present)
				fail("the sidecar lost a unit", 0, 1);
			if (strcmp(rd.u[0].sha256, w.u[0].sha256) != 0)
				fail("unit 0's digest did not survive the sidecar", 1, 0);
			if (strcmp(rd.u[0].path, a) != 0)
				fail("unit 0's path did not survive the sidecar", 1, 0);
			if (rd.u[3].heads != 5 || !rd.u[3].read_only)
				fail("unit 3's geometry or switch did not survive", 1, 0);
			if (rd.boards != 32 || rd.microcycles != 1234567890ull)
				fail("the sidecar's header did not survive", rd.boards, 32);
			int chk_moved = 0;
			const int moved = bind_verify(&rd, &chk_moved, err, sizeof err);
			if (moved != 0)
				fail("an unchanged pack was called moved", (unsigned)moved, 0);
			// Now move one, by one byte, and require that it is named.
			f = fopen(a, "ab");
			if (f) { fputc('!', f); fclose(f); }
			struct binding again;
			if (bind_read(&again, side, err, sizeof err) != 0)
				fail("the sidecar could not be read a second time", 1, 0);
			const int moved2 = bind_verify(&again, &chk_moved, err, sizeof err);
			if (moved2 != 1)
				fail("a pack that moved was not caught", (unsigned)moved2, 1);
			else if (!again.u[0].moved || again.u[3].moved)
				fail("the wrong unit was named as moved", 1, 0);
			// And a pack that is not there at all is a refusal and not
			// a verdict: nothing can be said about a file nobody has.
			remove(a);
			struct binding gone;
			if (bind_read(&gone, side, err, sizeof err) != 0)
				fail("the sidecar could not be read a third time", 1, 0);
			if (bind_verify(&gone, &chk_moved, err, sizeof err) >= 0)
				fail("a missing pack was given a verdict", 1, 0);
			remove(b2);
			remove(stand);
			remove(side);
		}

		// **A QUUX BINDING SAYS SO, AND ITS RESUME IS QUUX'S, WHOLE.**  The
		// line survives the file, and the command it prints is muir's
		// `quux` with everything muir needs to take the file as the board
		// ran it: the clock's period, which muir refuses a checkpoint of
		// another period at, the board's memory timing, which it refuses
		// another timing at, and the video controller's size.  No memory
		// flag: muir builds the machine with the checkpoint's own memory.
		// The CADR's
		// is `cadr` with its timing model and its boards.  Held whole,
		// every word, against the line a person pastes.
		struct binding qb;
		bind_init(&qb);
		qb.quux = 1;
		qb.boards = 512;
		qb.revision = 16;
		qb.sync_k = 20;
		qb.video_width = 1920;
		qb.video_height = 1080;
		qb.running = 1;
		// The board's memory timing is one name, the preset's: its figures
		// go into the declaration, its name into the binding.
		{
			struct chk_declared td;
			memset(&td, 0, sizeof td);
			const struct chk_memory_timing *kt = chk_memory_timing("kria");
			if (!kt || bind_memory_timing(&qb, &td, "kria") != 0)
				fail("the Kria's memory timing, no preset", 0, 1);
			else if (td.timing[0] != kt->read_ns || td.timing[1] != kt->write_ns ||
				 td.timing[2] != kt->occupancy_ns || strcmp(qb.memory_timing, "kria") != 0)
				fail("the Kria's memory timing, declared", td.timing[0], kt->read_ns);
			struct binding nb;
			bind_init(&nb);
			memset(&td, 0, sizeof td);
			if (bind_memory_timing(&nb, &td, "kr260") != -1 || nb.memory_timing[0] ||
			    td.timing[0] || td.timing[1] || td.timing[2])
				fail("a memory timing muir has no preset of, taken", 1, 0);
			// Every preset is named on the line by its own name.
			for (const struct chk_memory_timing *t = chk_memory_timings; t->name; ++t) {
				struct binding pb = qb;
				char line[4096], want[64];
				if (bind_memory_timing(&pb, &td, t->name) != 0)
					fail("a preset of the table, refused", 1, 0);
				resume_of(&pb, "q.chk", line, sizeof line);
				snprintf(want, sizeof want, " --memory-timing %s ", t->name);
				if (!strstr(line, want)) {
					fprintf(stderr, "the %s resume line is [%s]\n", t->name, line);
					fail("a resume line without its board's --memory-timing", 1, 0);
				}
			}
		}
		qb.u[0].present = 1;
		snprintf(qb.u[0].path, sizeof qb.u[0].path, "/mnt/card/packs/disk-pack-0.img");
		snprintf(qb.u[0].format, sizeof qb.u[0].format, "vhd-dynamic");
		qb.present = 1;
		snprintf(qb.checkpoint, sizeof qb.checkpoint, "%s", stand);
		char cmd[4096];
		static const char want16[] = "quux --rtl --microcycle-ns 10 --memory-timing kria "
			"--video-size 1920x1080 --disk-pack /mnt/card/packs/disk-pack-0.img,0 --resume q.chk";
		resume_of(&qb, "q.chk", cmd, sizeof cmd);
		if (strcmp(cmd, want16) != 0) {
			fprintf(stderr, "QUUX's resume line is [%s], wanting [%s]\n", cmd, want16);
			fail("QUUX's resume line", 1, 0);
		}
		if (bind_write(&qb, side, NULL, 0, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || !rd.quux)
			fail("the sidecar lost the machine", 0, 1);
		else if (rd.video_width != 1920 || rd.video_height != 1080)
			fail("the sidecar lost the video controller's size",
			     ((uint64_t)rd.video_width << 16) | rd.video_height, (1920u << 16) | 1080u);
		else if (rd.revision != 16 || rd.sync_k != 20 || rd.running != 1)
			fail("the sidecar lost the revision, the period or the run state",
			     ((uint64_t)rd.revision << 16) | (rd.sync_k << 8) | (unsigned)rd.running,
			     (16u << 16) | (20u << 8) | 1u);
		else if (strcmp(rd.memory_timing, "kria") != 0)
			fail("the sidecar lost the memory timing", 1, 0);
		else {
			// `--verify` prints the line from the sidecar it read.
			resume_of(&rd, "q.chk", cmd, sizeof cmd);
			if (strcmp(cmd, want16) != 0)
				fail("the resume line from the sidecar read back", 1, 0);
		}
		// And the file says it in words a person reads.
		{
			FILE *sf = fopen(side, "r");
			char line[8192];
			int saw_rev = 0, saw_k = 0, saw_run = 0, saw_resume = 0, saw_video = 0, saw_timing = 0;
			while (sf && fgets(line, sizeof line, sf)) {
				line[strcspn(line, "\n")] = '\0';
				saw_rev += strcmp(line, "revision: 16") == 0;
				saw_k += strcmp(line, "sync-cycle-ticks: 20") == 0;
				saw_video += strcmp(line, "video-size: 1920x1080") == 0;
				saw_timing += strcmp(line, "memory-timing: kria") == 0;
				saw_run += strcmp(line, "running: yes") == 0;
				saw_resume += strncmp(line, "resume: quux --rtl --microcycle-ns 10 ",
						      sizeof "resume: quux --rtl --microcycle-ns 10 " - 1) == 0;
			}
			if (sf)
				fclose(sf);
			if (saw_rev != 1 || saw_k != 1 || saw_run != 1 || saw_resume != 1 || saw_video != 1 ||
			    saw_timing != 1)
				fail("the sidecar's revision, period, running, resume, video size and timing lines",
				     (uint64_t)saw_timing * 100000 + saw_video * 10000 + saw_rev * 1000 +
				     saw_k * 100 + saw_run * 10 + saw_resume, 111111);
		}
		// A sidecar naming a timing muir has no preset of is refused.
		{
			FILE *sf = fopen(side, "w");
			if (sf) {
				fprintf(sf, "format: %s\nmachine: quux\nmemory-timing: 247,130,10\n", BIND_FORMAT);
				fclose(sf);
			}
			if (bind_read(&rd, side, err, sizeof err) != -1)
				fail("a sidecar's memory timing that is no preset, taken", 1, 0);
		}
		// A period of 9.5 ns names its half, and 1280 by 1024 its size.
		qb.sync_k = 19;
		qb.video_width = 1280;
		qb.video_height = 1024;
		qb.running = 0;
		resume_of(&qb, "q.chk", cmd, sizeof cmd);
		if (strcmp(cmd, "quux --rtl --microcycle-ns 9.5 --memory-timing kria --video-size 1280x1024 "
			   "--disk-pack /mnt/card/packs/disk-pack-0.img,0 --resume q.chk") != 0)
			fail("QUUX's resume line at 9.5 ns", 1, 0);
		// A sidecar of an older revision names no period: its file is
		// not one muir's `quux` resumes.
		qb.revision = 15;
		resume_of(&qb, "q.chk", cmd, sizeof cmd);
		if (strstr(cmd, "--microcycle-ns") || strstr(cmd, "--sync-cycle-ticks") ||
		    strstr(cmd, "MUIR_QUUX_REVISION"))
			fail("an older revision's resume line names a timing or a revision", 1, 0);
		qb.revision = 16;
		if (bind_write(&qb, side, NULL, 0, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || rd.running != 0)
			fail("a halted machine's sidecar read back as running", (unsigned)rd.running, 0);
		// A sidecar written before the lines were names neither, and its
		// run state is unknown rather than a guess.
		{
			FILE *sf = fopen(side, "w");
			if (sf) {
				fprintf(sf, "format: %s\nmachine: quux\nboards: 32\n", BIND_FORMAT);
				fclose(sf);
			}
			if (bind_read(&rd, side, err, sizeof err) != 0 || rd.running != -1 ||
			    rd.revision != 0 || rd.sync_k != 0 || rd.video_width != 0 || rd.memory_timing[0])
				fail("an old sidecar's run state, revision or K", (unsigned)rd.running, 0);
			resume_of(&rd, "q.chk", cmd, sizeof cmd);
			if (strcmp(cmd, "quux --rtl --resume q.chk") != 0)
				fail("an old sidecar's resume line", 1, 0);
		}
		qb.quux = 0;
		qb.revision = 0;
		qb.sync_k = 0;
		qb.boards = 32;
		qb.u[0].format[0] = '\0';
		resume_of(&qb, "c.chk", cmd, sizeof cmd);
		if (strcmp(cmd, "cadr --rtl --timing-model fpga --disk-pack "
			   "/mnt/card/packs/disk-pack-0.img,0 --main-memory-boards 32 --resume c.chk") != 0) {
			fprintf(stderr, "the CADR's resume line is [%s]\n", cmd);
			fail("the CADR's resume command", 1, 0);
		}
		if (bind_write(&qb, side, NULL, 0, err, sizeof err) != 0 ||
		    bind_read(&rd, side, err, sizeof err) != 0 || rd.quux)
			fail("a CADR sidecar read back as QUUX's", 1, 0);
		remove(side);

		// **THE SIDECAR'S RESUME LINE IS THE PRINTED ONE, AND RUNS FROM THE
		// PACK FOLDER.**
		sidecar_line_check(work);
		folder_check(work);

		// **QUUX's MAIN MEMORY IS AN AMOUNT, NEVER BOARDS; THE CADR KEEPS
		// ITS BOARDS.**  What the program says, what its flags take and what
		// its sidecar records, each machine in its own words.  Every
		// failure here prints one line under one prefix, which is what the
		// Makefile's memory mutants are judged by.
		memory_words_check(side);

		// **THE HALT `--halt` MADE**, which `--already-halted` takes as the
		// machine running before it only at the count it was made at.
		{
			char mark[320];
			snprintf(mark, sizeof mark, "%s/halted", work);
			remove(mark);
			if (bind_halted_here(mark, 77))
				fail("no mark taken as a halt this program made", 1, 0);
			if (bind_halt_mark(mark, 0x123456789ull) != 0)
				fail("the halt mark could not be written", 1, 0);
			if (!bind_halted_here(mark, 0x123456789ull))
				fail("the halt mark at its own count", 0, 1);
			if (bind_halted_here(mark, 0x12345678Aull))
				fail("a machine that ran on since the mark taken as halted there", 1, 0);
			bind_halt_unmark(mark);
			if (bind_halted_here(mark, 0x123456789ull))
				fail("a mark taken away and still taken", 1, 0);
		}
	}

	// ---- a QUUX disk, bound by its footers and never by its size -------
	//
	// QUUX's disk is block-disk's one pack, unit 0, of any size, raw, a
	// fixed VHD or a dynamic VHD (contract Q8).  So under `--machine quux`
	// the drive bay's `disk-pack-0.img` is a pack when `cadr-disk-packs`'s own
	// test says it is a QUUX disk --- the footers, the dynamic header, the
	// block count --- and the CADR's rule, a T-300's or a T-80's size, would
	// find none of them.  Each of muir's three is put in a bay of its own
	// under the same name, as the card holds it.
	{
		char bay[256], pack0[320], err[512];
		snprintf(bay, sizeof bay, "%s/q8-bay", work);
		snprintf(pack0, sizeof pack0, "%s/disk-pack-0.img", bay);
		mkdir(bay, 0755);
		static const struct { const char *file, *format; } disks[] = {
			{ "quux-disk.img", "raw" },
			{ "quux-disk-fixed.vhd", "fixed-vhd" },
			{ "quux-disk-dynamic.vhd", "dynamic-vhd" },
		};
		for (unsigned i = 0; i < sizeof disks / sizeof disks[0]; ++i) {
			char src[512];
			snprintf(src, sizeof src, "%s/%s", q8, disks[i].file);
			struct stat st;
			if (stat(src, &st) != 0) {
				fprintf(stderr, "no %s: QUUX's disks are muir's data/quux-disk*\n", src);
				++bad;
				continue;
			}
			remove(pack0);
			if (symlink(src, pack0) != 0) {
				fprintf(stderr, "%s: %s\n", pack0, strerror(errno));
				++bad;
				continue;
			}
			struct binding q;
			bind_init(&q);
			q.quux = 1;
			err[0] = '\0';
			const int n = bind_scan(&q, bay, err, sizeof err);
			if (n != 1 || !q.u[0].present || q.present != 1) {
				fprintf(stderr, "QUUX's %s was not bound as unit 0: %d found, %s\n",
					disks[i].file, n, err);
				++bad;
				continue;
			}
			if (strcmp(q.u[0].format, disks[i].format) != 0) {
				fprintf(stderr, "QUUX's %s was bound as \"%s\", and it is %s\n",
					disks[i].file, q.u[0].format, disks[i].format);
				++bad;
			}
			// Every one of the three holds the same disk of 8 MiB.
			if (q.u[0].blocks != 8192)
				fail("a QUUX disk's blocks", q.u[0].blocks, 8192);
			if (q.u[0].bytes != (uint64_t)st.st_size)
				fail("a QUUX disk's bytes, the file's", q.u[0].bytes, (uint64_t)st.st_size);
			// And it is declared to the checkpoint as its blocks, which is
			// the disk size muir holds the resuming disk to.
			{
				uint32_t dc = 0, dh = 0, db = 0;
				bind_declared(&q.u[0], &dc, &dh, &db);
				if ((uint64_t)dc * dh * db != 8192)
					fail("a QUUX disk's declared blocks", (uint64_t)dc * dh * db, 8192);
			}
			if (bind_digest(&q, err, sizeof err) != 0) {
				fprintf(stderr, "QUUX's %s could not be digested: %s\n", disks[i].file, err);
				++bad;
			}
			// The sidecar carries what the file is, and its resume is QUUX's
			// with the disk as unit 0.
			char side[400], cmd[4096];
			snprintf(side, sizeof side, "%s/q8.chk%s", work, BIND_SUFFIX);
			snprintf(q.checkpoint, sizeof q.checkpoint, "%s/q8.chk", work);
			struct binding rd;
			if (bind_write(&q, side, NULL, 0, err, sizeof err) != 0 ||
			    bind_read(&rd, side, err, sizeof err) != 0) {
				fprintf(stderr, "a QUUX sidecar: %s\n", err);
				++bad;
			} else if (!rd.quux || !rd.u[0].present ||
				   strcmp(rd.u[0].format, disks[i].format) != 0 ||
				   rd.u[0].blocks != 8192 ||
				   strcmp(rd.u[0].sha256, q.u[0].sha256) != 0) {
				fprintf(stderr, "a QUUX sidecar lost the disk's format, blocks or "
					"digest: \"%s\", %llu\n", rd.u[0].format,
					(unsigned long long)rd.u[0].blocks);
				++bad;
			}
			remove(side);
			resume_of(&q, "q8.chk", cmd, sizeof cmd);
			char want[400];
			snprintf(want, sizeof want, " --disk-pack %s,0 ", pack0);
			if (strncmp(cmd, "quux --rtl ", 11) != 0 || !strstr(cmd, want)) {
				fprintf(stderr, "QUUX's resume command: %s\n", cmd);
				++bad;
			}
			// Named by hand, the same.
			struct binding h;
			bind_init(&h);
			h.quux = 1;
			char spec[400];
			snprintf(spec, sizeof spec, "%s,0", pack0);
			if (bind_add(&h, spec, err, sizeof err) != 0 ||
			    strcmp(h.u[0].format, disks[i].format) != 0) {
				fprintf(stderr, "QUUX's %s named by hand: %s\n", disks[i].file, err);
				++bad;
			}
			// And the CADR's rule finds no pack in it: 8 MiB is no drive's.
			struct binding c;
			bind_init(&c);
			err[0] = '\0';
			if (bind_scan(&c, bay, err, sizeof err) != 0 || c.present != 0)
				fail("the CADR bound a QUUX disk", c.present, 0);
		}
		// A VHD whose footer does not check is no disk: the fixed one copied,
		// one byte of its footer changed.
		remove(pack0);
		{
			char src[512];
			snprintf(src, sizeof src, "%s/quux-disk-fixed.vhd", q8);
			FILE *in = fopen(src, "rb"), *o = fopen(pack0, "wb");
			int c;
			while (in && o && (c = fgetc(in)) != EOF)
				fputc(c, o);
			if (in)
				fclose(in);
			if (o) {
				fseek(o, -512 + 20, SEEK_END);
				fputc(0x5a, o);
				fclose(o);
			}
			struct binding q;
			bind_init(&q);
			q.quux = 1;
			err[0] = '\0';
			if (bind_scan(&q, bay, err, sizeof err) != 0 || q.present != 0)
				fail("a VHD whose footer does not check was bound", q.present, 0);
			else if (!strstr(err, "checksum"))
				fprintf(stderr, "a VHD whose footer does not check was refused "
					"without saying why: \"%s\"\n", err), ++bad;
		}
		remove(pack0);
		rmdir(bay);
	}

	// ---- the packer ----------------------------------------------------
	//
	// muir's `unpack` accepts any valid packing, so this does not prove the
	// packing is muir's; what proves that is the byte comparison against
	// muir's own re-save.  What this proves is that nothing is LOST, which
	// a round trip can say on its own.
	{
		static const uint8_t cases[][24] = {
			{ 0 },
			{ 1, 2, 3 },
			{ 0, 0, 0, 1 },			/* three zeros stay literal */
			{ 0, 0, 0, 0, 1 },		/* four end the run */
			{ 1, 0, 0, 2, 0, 0, 0, 0, 3 },
		};
		static const size_t lens[] = { 0, 3, 4, 5, 9 };
		for (unsigned i = 0; i < 5; ++i)
			if (!unpack_equals(cases[i], lens[i]))
				fail("a packed case does not unpack to itself", i, i);
		uint8_t big[4096];
		for (unsigned i = 0; i < sizeof big; ++i)
			big[i] = (i % 37u) < 30u ? 0u : (uint8_t)i;
		if (!unpack_equals(big, sizeof big))
			fail("a long packed case does not unpack to itself", 1, 0);
	}

	// ---- the echo, which the program must compare -----------------------
	{
		struct model m;
		fill(&m);
		m.stale_for = 1;
		struct readout r;
		memset(&r, 0, sizeof r);
		r.read = model_read;
		r.write = model_write;
		r.ctx = &m;
		uint64_t w = 0;
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) == 0)
			fail("a word came back for an address that was not asked "
			     "for and the program took it", 1, 0);
		if (r.stale != 1)
			fail("the stale read was not counted", r.stale, 1);
		// And the next read, with the echo honest, must succeed.
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) != 0)
			fail("an honest read was refused", 1, 0);
		if (w != poison(IMG_SEL_IMEM, 7, 48))
			fail("the word", w, poison(IMG_SEL_IMEM, 7, 48));
	}

	// ---- the whole machine through the window ---------------------------
	struct model *m = malloc(sizeof *m);
	if (!m) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	fill(m);
	struct readout r;
	memset(&r, 0, sizeof r);
	r.read = model_read;
	r.write = model_write;
	r.ctx = m;

	// One memory board: the file is then small enough to be diffed by hand
	// and muir resumes it at the header's own count.  Thirty-two is what
	// the board has and the field is the same field either way.
	struct cadr_image img;
	if (img_alloc(&img, 1) != 0) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	// **NO DRIVE, SO THE FILE muir RESUMES NEEDS NO PACK.**  The board
	// declares the units its drive bay holds; here there are none, which
	// is a state `Controller::load` accepts and is the one that makes the
	// round trip runnable with nothing but a muir.
	struct chk_declared decl;
	memset(&decl, 0, sizeof decl);
	// **THE ADDRESS IS PARSED AND NOT WRITTEN AS A LITERAL**, so that the
	// parser is in the path the checkpoint's own field comes down.  muir's
	// spelling for muir's default: a bare octal number.  A parser that read
	// it as decimal would put 0o131551 in the switches and muir would
	// refuse the file, which is exactly what happened on the board.
	if (chk_chaos_address("177001", &decl.chaos_address) != 0)
		fail("muir's own default address parsed", 1, 0);

	if (ro_read_machine(&r, &img) != 0) {
		fail("the window would not give the machine up", r.stale, 0);
		return 1;
	}

	// Every memory came back as the model holds it.  This is the program's
	// own transport, not muir's format: a selector read into the wrong
	// array, or a length off by one, shows here.
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		if (img.imem[i] != m->imem[i]) { fail("imem", img.imem[i], m->imem[i]); break; }
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		if (img.prom[i] != m->prom[i]) { fail("prom", img.prom[i], m->prom[i]); break; }
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		if (img.amem[i] != m->amem[i]) { fail("amem", img.amem[i], m->amem[i]); break; }
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		if (img.dmem[i] != m->dmem[i]) { fail("dmem", img.dmem[i], m->dmem[i]); break; }
	for (unsigned i = 0; i < IMG_L2_WORDS; ++i)
		if (img.l2_map[i] != m->l2[i]) { fail("l2_map", img.l2_map[i], m->l2[i]); break; }
	if (img.pc != (uint16_t)m->regs[IMG_RG_PC])
		fail("PC", img.pc, m->regs[IMG_RG_PC]);
	if (img.ir != m->regs[IMG_RG_IR])
		fail("IR", img.ir, m->regs[IMG_RG_IR]);
	if (img.spcptr != (uint8_t)m->regs[IMG_RG_SPCPTR])
		fail("SPCPTR", img.spcptr, m->regs[IMG_RG_SPCPTR]);
	if (img.cycles != m->cycles)
		fail("CYCLES", img.cycles, m->cycles);
	if (img.ticks != m->ticks)
		fail("TICKS", img.ticks, m->ticks);

	// Main memory and the display are DDR on the board and are poisoned
	// here, so that the two largest arrays in the file are not zeros.
	for (size_t i = 0; i < IMG_BOARD_WORDS; ++i)
		img.main[i] = (uint32_t)poison(12, (unsigned)i, 32);
	for (size_t i = 0; i < IMG_TV_WORDS; ++i)
		img.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);
	// **AND THE FIRST DISPLAY BOARD'S COLOR MAP, WHICH IS NOT DDR AND IS NOT
	// ZERO EITHER.**  It comes off the console face's page 4 on the board ---
	// register 4 is write only on the Xbus, so that page is the only way to
	// ask what a color is --- and a check that only ever ran it at zero
	// would pass a program that wrote zeros, which is what this one used to
	// do.  Poisoned in the color and the channel, none of the forty-eight
	// bytes zero, so a byte taken from the wrong slot cannot come back right.
	for (unsigned c = 0; c < IMG_MAP_COLORS; ++c)
		for (unsigned k = 0; k < IMG_MAP_CHANNELS; ++k)
			img.tv_map[c][k] =
				(uint8_t)(1u + (unsigned)poison(14, c * 4u + k, 8) % 250u);

	struct chk body;
	chk_init(&body);
	chk_rtl_body(&body, &img, &decl);
	if (body.broken) {
		fail("the body ran out of memory", 1, 0);
		return 1;
	}

	// **THE BODY'S LENGTH IS A FIXED NUMBER AND IT IS ASSERTED.**  Every
	// field in an `rtl` body is fixed-width and every array's length is
	// known, so the whole body is one arithmetic expression --- and a field
	// added, dropped or written at the wrong width moves it.  That is a
	// cheap, sharp check on a format with no framing in it: muir would
	// catch the same mistake, but only after the file reached a machine
	// with muir on it.
	//
	// Machine::save, one board:
	//   prom       8 + 1024*8         = 8200
	//   imem       8 + 16384*8        = 131080
	//   mode/clk/opc  6 + 5 + 3       = 14
	//   debug_ir + prog_reset + boot  = 10
	//   amem/mmem/dmem/pdl/spc  (8+4096)+(8+128)+(8+8192)+(8+65536)+(8+128) = 78120
	//                                            (the PDL is muir's largest
	//                                             machine's, 16K words, of
	//                                             which a CADR has 1K)
	//   spcptr..dispatch_constant     = 1+2+2+4+2+4+4+4+4+2 = 29
	//   l1_map     8 + 8192           = 8200
	//   geometry   1 + 1 + 1 + 1 + 1  = 5        (Geometry::CADR: 5, 10, no
	//                                             multiply and divide, no tick,
	//                                             no fused return: version 49)
	//   timers     3 * (1+1+1+4+8)    = 45       (Timers::new: three
	//                                             interval timers off,
	//                                             periodic, interrupt
	//                                             enable 0, period 0, no
	//                                             deadline; version 45)
	//   macro_dispatch 4 + 2 + (8+4096) + 4 + 4 + 1 + 1 = 4120
	//                                            (MacroDispatch::default:
	//                                             the register, the index,
	//                                             1,024 entries, the base
	//                                             copies, nothing armed:
	//                                             version 49)
	//   rtc        1                  = 1        (Rtc::Host, the option
	//                                             absent: version 42)
	//   file_device 4 + 4*4 + 3*2 + 1 = 27      (FileDevice::new: four
	//                                             flags, the rings, the
	//                                             indexes, no due time:
	//                                             version 43)
	//   dma_written 1
	//   l2_map     8 + 8192           = 8200     (2048 entries, QUUX's; a
	//                                             CADR has 1024)
	//   boards     4
	//   main       8 + 65536*4        = 262152
	//   bus_error..write_buffer  2+2+1+(8+32)*3 = 125
	//   vmaok      1
	//   disk       61 + 8             = 69       (no drives: 8 flag bytes)
	//   block_disk 1                  = 1        (none: the flag alone)
	//   tv         1+2+2+(8+131072)+4+(8+4096)+2+1+48+1+8+8+1+1 = 135263
	//                                            (the board's tag, the video size, the
	//                                             buffer, the mode, the
	//                                             sync RAM, the color map
	//                                             as 48 bare bytes, the
	//                                             flag, two instants, and the
	//                                             two held sync bits)
	//   color_tv   1                  = 1        (the flag alone: none is
	//                                             fitted, so no board
	//                                             follows it)
	//   ioboard    57 + 110 + 1 + 91  = 259      (its own, the serial port's
	//                                             Pci, the chaos flag, and
	//                                             the Chaosnet interface:
	//                                             85 bytes and the 6 of
	//                                             version 54 after them)
	//   quux_input 4+1+1+2+2+1+1+1    = 13       (QUUX's keyboard and mouse,
	//                                             empty: version 39)
	//   cycles+ns  16
	// Rtl tail:
	//   trace+flags  (8+96)*2         = 208
	//   ir..lc       8+8+2+1+1+4+2+2+4 = 32
	//   19 bools                       = 19
	//   halted_ns + ir_loaded_ns + pulsed + 4 bools = 21
	//   bus        1 + busint: which bus, `Bus::Cadr` (version 40), then
	//   busint     (1+1+8) + 42*1 + (1+8+1+1+8+1+1+1+1+8+8+1+2+2+8+8+8+1+1+1+8+8)
	//              + (1+4+1+8+1+8) = 163  (the cache and QUUX's memory
	//                                      timing, both absent, and the
	//                                      four fields beside them)
	//   mbusy_sync                     = 1
	//   bus_addr..bus_acked            = 4+4+1+1+1+1+2+1+8+8+1 = 32
	//   debug_*                        = 1+1+1+1+1+1+8+1+2+8 = 25
	//   wmapd..imodd                   = 1+4+8+8+1+1+2+1 = 26
	//   opc        8 + 16              = 24
	//   stat..executed                 = 4+1+1+1+8+4+8+1 = 28
	//   memstart_fetch                 = 1        (version 49)
	//
	// The arithmetic is written out rather than summed by hand so that a
	// reader can check one line instead of one number.
	{
		const size_t machine_part =
			8200 + 131080 + 14 + 10 + 78120 + 29 + 8200 + 5 + 45 + 4120 + 1 + 27 + 1 + 8200 + 4 +
			262152 + 125 + 1 + 69 + 1 + 135263 + 1 + 259 + 13 + 16;
		const size_t rtl_part =
			208 + 32 + 19 + 21 + 1 + 163 + 1 + 32 + 25 + 26 + 24 + 28 + 1;
		// **A MUTANT IS JUDGED BY muir AND NOT HERE.**  Six of the seven
		// keep the body's length and one does not, and the point of
		// building them is what the ROUND TRIP does with them, so this
		// assertion --- which belongs to the real thing --- stands down.
		if (!chk_rtl_mutation() && body.len != machine_part + rtl_part)
			fail("the body's length", body.len, machine_part + rtl_part);
	}

	// ---- the run state before the halt ----------------------------------
	//
	// **A MACHINE FOUND RUNNING IS WRITTEN RUNNING, AND ONE FOUND HALTED AS
	// IT WAS READ.**  The program halts a running machine to read it, so the
	// window gives RUN and SRUN clear; `chk_rtl_run_state` puts both back.
	// Where the two bytes are is found here independently of that function:
	// the image with each flag set alone against the image with neither,
	// each one byte apart --- so the assertion below is on the two slots muir
	// reads RUN and SRUN from, and not on whatever the function touched.
	if (run_state_check(&img, &decl, "the CADR") != 0)
		return 1;
	chaos_address_check(&img, &decl, work);
	ethernet_host_check(work);

	if (out) {
		if (chk_write_file(out, "rtl", 1, &body) != 0) {
			perror(out);
			return 1;
		}
	}

	printf("checkpoint: %zu bytes of body, %lu reads and %lu writes over a "
	       "modeled window, %lu of them refused for a stale echo\n",
	       body.len, r.reads, r.writes, r.stale);
	if (out)
		printf("checkpoint: wrote %s --- muir opening it is the proof, and "
		       "`make build/checkpoint.pass` is where that happens\n", out);
	chk_free(&body);

	// ---- QUUX -------------------------------------------------------------
	//
	// The machine `fill_quux` models, through QUUX's window, written as the
	// board writes it; the file goes where the fourth argument says, and
	// `build/checkpoint.quux.pass` has muir's `quux` resume it, save it back
	// byte for byte, and holds it to the digest recorded there.
	{
		unsigned k = 99, l = 99;
		if (ro_machine_is_quux(&r, &k, &l) != 0)
			fail("the CADR's window was taken for QUUX's", 1, 0);

		struct qmodel *q = malloc(sizeof *q);
		if (!q) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		fill_quux(q);
		struct readout qr;
		memset(&qr, 0, sizeof qr);
		qr.read = qmodel_read;
		qr.write = qmodel_write;
		qr.ctx = q;
		if (ro_machine_is_quux(&qr, &k, &l) != 1 || k != Q_PERIOD || l != 0)
			fail("QUUX's window, its period", ((uint64_t)k << 8) | l, Q_PERIOD << 8);
		if (ro_quux_revision(&qr) != 16)
			fail("QUUX's window read as another revision", (unsigned)ro_quux_revision(&qr), 16);
		// **AN OLDER QUUX IS NOT READ**: its image is refused, and the
		// program refuses its bitstream by the revision MACHINE-ID names.
		{
			struct cadr_image old;
			for (int rv = 13; rv <= 15; ++rv)
				if (img_alloc_video(&old, Q_UNITS, 1, rv, Q_VIDEO_W, Q_VIDEO_H) == 0) {
					fail("an image of QUUX at an older revision, taken", (unsigned)rv, 0);
					img_free(&old);
				}
		}
		struct cadr_image qi;
		if (img_alloc_video(&qi, Q_UNITS, 1, 16, Q_VIDEO_W, Q_VIDEO_H) != 0) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		if (ro_read_machine(&qr, &qi) != 0) {
			fail("the window would not give QUUX up", qr.stale, 0);
			return 1;
		}
		if (q->snaps != 1)
			fail("the devices' snapshot, taken", (unsigned)q->snaps, 1);
		// The transport, at QUUX's sizes and in its words.  **Not under a
		// mutant**, one of which is of the image (`readout.c`'s 39):
		// asserting here what the mutant took out would call it broken,
		// not caught.
		if (!chk_rtl_mutation()) {
			if (qi.tv_words != Q_VIDEO_H * (Q_VIDEO_W / 32u) || qi.video_width != Q_VIDEO_W ||
			    qi.video_height != Q_VIDEO_H)
				fail("the image's video controller at 1920 by 1080, in words", qi.tv_words,
				     Q_VIDEO_H * (Q_VIDEO_W / 32u));
			if (qi.amem[IMG_AMEM_WORDS - 1] != q->amem[IMG_AMEM_WORDS - 1] ||
			    qi.pdl[IMG_QUUX_PDL_WORDS - 1] != q->pdl[IMG_QUUX_PDL_WORDS - 1] ||
			    qi.imem[IMG_IMEM_WORDS - 1] != q->imem[IMG_IMEM_WORDS - 1] ||
			    qi.q != q->regs[IMG_RG15_Q] || qi.dmem[IMG_DMEM_WORDS_13 - 1] != q->dmem[IMG_DMEM_WORDS_13 - 1])
				fail("a QUUX word", qi.amem[IMG_AMEM_WORDS - 1], q->amem[IMG_AMEM_WORDS - 1]);
			if (qi.qx.head != Q_KEYS_READ || qi.qx.count != Q_KEYS_WAITING ||
			    qi.qx.fifo[(Q_KEYS_READ + 4u) % IMG_QUUX_FIFO_WORDS] !=
				    q->fifo[(Q_KEYS_READ + 4u) % IMG_QUUX_FIFO_WORDS])
				fail("the FIFO's head, count and last word", qi.qx.head, Q_KEYS_READ);
			if (qi.qx.x != Q_MOUSE_X || qi.qx.y != Q_MOUSE_Y || qi.qx.buttons != Q_BUTTONS)
				fail("the mouse", qi.qx.x, Q_MOUSE_X);
			if (!qi.qx.present || qi.qx.walking || !qi.qx.bow)
				fail("block-disk's pack and the video controller's mode", qi.qx.present, 1);
			if (qi.qx.fd_cmd_base != Q_FD_CMD_BASE || qi.qx.fd_resp_base != Q_FD_RESP_BASE ||
			    qi.qx.fd_cmd_log2 != Q_FD_CMD_LOG2 || qi.qx.fd_resp_log2 != Q_FD_RESP_LOG2)
				fail("the file device's rings", qi.qx.fd_resp_base, Q_FD_RESP_BASE);
			if (qi.qx.fd_cmd_prod != 1 || qi.qx.fd_cmd_cons != 1 || qi.qx.fd_resp_cons != 1 ||
			    !qi.qx.fd_enabled || !qi.qx.fd_ie || qi.qx.fd_refused || !qi.qx.fd_fault ||
			    qi.qx.fd_handles != 0)
				fail("the file device's indexes and flags", qi.qx.fd_cmd_prod, 1);
			if (qi.q15.period != Q_PERIOD || qi.q15.ns != Q_NS || qi.q15.committed != Q_CYCLES ||
			    qi.cycles != Q_CYCLES)
				fail("the period, the instant and the microcycles", qi.q15.ns, Q_NS);
			if (qi.q15.eth.address != Q_IP_ADDRESS || qi.q15.eth.netmask != Q_IP_NETMASK ||
			    qi.q15.eth.gateway != Q_IP_GATEWAY || qi.q15.eth.mac[0] != 0x02u ||
			    qi.q15.eth.mac[5] != 0x44u)
				fail("the Ethernet device's host words", qi.q15.eth.address, Q_IP_ADDRESS);
		}
		// **THE REFUSAL, muir's**: none for this machine; one for a handle
		// open, one for a command queued, one across the indexes' wrap, and
		// one for block-disk's transfer in flight.
		{
			char why[160];
			if (chk_rtl_refusal(&qi, why, sizeof why))
				fail("a checkpoint refused with no handle open and nothing queued", 1, 0);
			struct cadr_image t = qi;
			t.qx.fd_handles = 1;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with a handle open", 0, 1);
			t.qx.fd_handles = 0;
			t.qx.fd_cmd_prod = 2;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with a command queued", 0, 1);
			t.qx.fd_cmd_prod = 0;
			t.qx.fd_cmd_cons = 0xFFFFu;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with a command queued across the wrap", 0, 1);
			t.qx.fd_cmd_prod = 0x1234;
			t.qx.fd_cmd_cons = 0x1234;
			if (chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint refused with the indexes equal", 1, 0);
			t.qx.walking = 1;
			if (!chk_rtl_refusal(&t, why, sizeof why))
				fail("a checkpoint taken with block-disk's transfer in flight", 0, 1);
			struct cadr_image c = t;
			c.quux = 0;
			c.qx.fd_handles = 3;
			if (chk_rtl_refusal(&c, why, sizeof why))
				fail("a CADR's checkpoint refused on a file device it has not", 1, 0);
		}
		// Main memory, packed storage: word i at bytes 5i to 5i + 4.
		const size_t qwords = (size_t)Q_UNITS * IMG_BOARD_WORDS;
		uint8_t *packed = malloc(qwords * 5u);
		if (!packed) {
			fprintf(stderr, "out of memory\n");
			return 1;
		}
		for (size_t i = 0; i < qwords; ++i) {
			const uint64_t v = poison(12, (unsigned)i, 40);
			for (unsigned b = 0; b < 5; ++b)
				packed[5 * i + b] = (uint8_t)(v >> (8 * b));
		}
		qi.main13 = packed;
		for (size_t i = 0; i < qi.tv_words; ++i)
			qi.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);
		// The bay's pack is muir's own QUUX disk, 8,192 blocks.
		struct chk_declared qdecl;
		memset(&qdecl, 0, sizeof qdecl);
		qdecl.chaos_address = BIND_CHAOS_DEFAULT;
		qdecl.present = 1u;
		qdecl.cylinders[0] = Q_DISK_BLOCKS;
		qdecl.heads[0] = 1u;
		qdecl.blocks_per_track[0] = 1u;
		// **AND ITS SIDECAR, AS THE BOARD WRITES IT**: the Kria KR260's,
		// its memory timing that board's preset, the declaration's figures
		// and the resume line's name from the one call `cadr-checkpoint`
		// makes.  **AND IN THE CARD'S LAYOUT**: QUUX's file is written as
		// `<pack folder>/checkpoints/<name>.chk`, and `bind_relative`, given
		// the absolute paths the bay's default `--pack-dir` gives, names the
		// pack `./disk-pack-0.img` and the checkpoint `checkpoints/<name>.chk`
		// from the pack folder, as `cadr-checkpoint` does.  The pack is
		// muir's own QUUX disk, bound from muir's copy and named as the
		// copy in the pack folder that `build/checkpoint.quux.pass` resumes,
		// so that a resume never writes muir's own.
		struct binding fb;
		bind_init(&fb);
		fb.quux = 1;
		{
			char spec[512], err[512] = "";
			snprintf(spec, sizeof spec, "%s/quux-disk.img,0", q8);
			if (bind_add(&fb, spec, err, sizeof err) != 0)
				fail("QUUX's fixture's disk, bound", 0, 1);
			snprintf(fb.u[0].path, sizeof fb.u[0].path, "./" BIND_NAME_FMT, 0u);
		}
		fb.boards = Q_UNITS;
		fb.revision = 16;
		fb.sync_k = Q_PERIOD;
		fb.video_width = qi.video_width;
		fb.video_height = qi.video_height;
		fb.eth = 1;
		memcpy(fb.eth_mac, qi.q15.eth.mac, sizeof fb.eth_mac);
		fb.eth_address = qi.q15.eth.address;
		fb.eth_netmask = qi.q15.eth.netmask;
		fb.eth_gateway = qi.q15.eth.gateway;
		fb.running = 0;
		if (bind_memory_timing(&fb, &qdecl, "kria") != 0)
			fail("the Kria's memory timing, no preset", 0, 1);
		struct chk qb;
		chk_init(&qb);
		chk_rtl_body(&qb, &qi, &qdecl);
		if (qb.broken) {
			fail("QUUX's body ran out of memory", 1, 0);
			return 1;
		}
		if (!chk_rtl_mutation() && (qb.word_bytes != 5u || qb.version != CHK_VERSION_16 ||
					    qb.hole_len != qwords * 5u))
			fail("QUUX's body's words, version and main memory", qb.version, CHK_VERSION_16);
		// **THE RUN STATE**, QUUX's: RUN in the console word, set for a
		// machine found running and as read for one found halted.
		{
			struct cadr_image ran = qi, stood = qi;
			chk_rtl_run_state(&ran, 1);
			chk_rtl_run_state(&stood, 0);
			if (!((ran.q15.tail[IMG_TL15_CONSOLE] >> 6) & 1u) ||
			    stood.q15.tail[IMG_TL15_CONSOLE] != qi.q15.tail[IMG_TL15_CONSOLE])
				fail("QUUX's run state, the console word's RUN", ran.q15.tail[IMG_TL15_CONSOLE], 1u << 6);
		}
		if (quux_out && chk_write_file(quux_out, "rtl", Q_UNITS, &qb) != 0) {
			perror(quux_out);
			return 1;
		}
		// **EVERY BOARD'S FILE OF THE SAME MACHINE**, each beside its
		// sidecar: the Kria's as `quux_out`, `<name>.chk`, and each other
		// preset's as `<name>-<preset>.chk`, whose bodies differ from the
		// Kria's in the port's three figures alone.  muir's `quux` resumes
		// each under its sidecar's resume line and nothing else.
		if (quux_out) {
			char stem[400];
			if (snprintf(stem, sizeof stem, "%s", quux_out) >= (int)sizeof stem) {
				fprintf(stderr, "%s: too long a path\n", quux_out);
				return 1;
			}
			const size_t sl = strlen(stem);
			if (sl <= 4 || strcmp(stem + sl - 4, ".chk") != 0) {
				fprintf(stderr, "%s: QUUX's file is named <name>.chk\n", quux_out);
				return 1;
			}
			stem[sl - 4] = '\0';
			// `<pack folder>/checkpoints/<name>`, the card's layout, and the
			// binding names the files from the pack folder by `bind_relative`,
			// given them by their absolute paths as the bay's default
			// `--pack-dir` gives them.
			const char *base = strrchr(stem, '/');
			static const char folder[] = "/checkpoints/";
			const size_t fl = sizeof folder - 1;
			if (!base || (size_t)(base + 1 - stem) <= fl ||
			    strncmp(base + 1 - fl, folder, fl) != 0) {
				fprintf(stderr, "%s: QUUX's file is written as the card's, "
					"<pack folder>/checkpoints/<name>.chk\n", quux_out);
				return 1;
			}
			char packs_dir[sizeof stem];
			snprintf(packs_dir, sizeof packs_dir, "%.*s", (int)(base + 1 - fl - stem), stem);
			++base;
			for (const struct chk_memory_timing *t = chk_memory_timings; t->name; ++t) {
				const int kria = strcmp(t->name, "kria") == 0;
				char path[sizeof fb.checkpoint], side[sizeof path + sizeof BIND_SUFFIX];
				char err[1024] = "";
				if (kria)
					snprintf(path, sizeof path, "%s", stem);
				else
					snprintf(path, sizeof path, "%s-%s", stem, t->name);
				strcat(path, ".chk");
				struct binding pb = fb;
				struct chk_declared pd = qdecl;
				if (bind_memory_timing(&pb, &pd, t->name) != 0) {
					fail("a preset of the table, refused", 1, 0);
					continue;
				}
				if (!kria) {
					struct chk pbody;
					chk_init(&pbody);
					chk_rtl_body(&pbody, &qi, &pd);
					const int wrote = !pbody.broken &&
						chk_write_file(path, "rtl", Q_UNITS, &pbody) == 0;
					chk_free(&pbody);
					if (!wrote) {
						perror(path);
						return 1;
					}
				}
				snprintf(pb.u[0].path, sizeof pb.u[0].path, "%s/" BIND_NAME_FMT,
					 packs_dir, 0u);
				snprintf(pb.checkpoint, sizeof pb.checkpoint, "%s", path);
				if (bind_relative(&pb, packs_dir, path, err, sizeof err) != 0) {
					fprintf(stderr, "%s: %s\n", path, err);
					return 1;
				}
				snprintf(side, sizeof side, "%s%s", path, BIND_SUFFIX);
				if (bind_write(&pb, side, NULL, 0, err, sizeof err) != 0) {
					fprintf(stderr, "%s: %s\n", side, err);
					return 1;
				}
			}
		}
		// **AND THE HOLE IS READ WHERE IT STANDS**: the file written from
		// a body with main memory in its hole is the file written from the
		// same body with main memory copied in, byte for byte.
		{
			struct chk flat;
			chk_init(&flat);
			flat.word_bytes = qb.word_bytes;
			flat.version = qb.version;
			for (size_t i = 0; i < qb.hole_at; ++i)
				chk_u8(&flat, qb.p[i]);
			for (size_t i = 0; i < qb.hole_len; ++i)
				chk_u8(&flat, packed[i]);
			for (size_t i = qb.hole_at; i < qb.len; ++i)
				chk_u8(&flat, qb.p[i]);
			char a[320], b[320];
			snprintf(a, sizeof a, "%s/hole.chk", work);
			snprintf(b, sizeof b, "%s/flat.chk", work);
			if (chk_write_file(a, "rtl", Q_UNITS, &qb) != 0 ||
			    chk_write_file(b, "rtl", Q_UNITS, &flat) != 0)
				fail("the two QUUX files could not be written", 1, 0);
			else {
				FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
				int same = fa && fb;
				for (int ca = 0, cb = 0; same && (ca != EOF || cb != EOF);) {
					ca = fgetc(fa);
					cb = fgetc(fb);
					same = ca == cb;
				}
				if (fa)
					fclose(fa);
				if (fb)
					fclose(fb);
				if (!same)
					fail("the file with main memory in place and the one with it copied", 1, 0);
				remove(a);
				remove(b);
			}
			chk_free(&flat);
		}
		// And a size no QUUX has is refused.
		{
			struct cadr_image no;
			if (img_alloc_video(&no, 1, 1, 16, 1900u, 1080u) == 0) {
				fail("a video controller 1900 wide, taken", 1900, 0);
				img_free(&no);
			}
		}
		printf("checkpoint: QUUX, %zu bytes of body and %zu of main memory where it stands, "
		       "%lu reads over a modeled window%s%s\n", qb.len, qb.hole_len, qr.reads,
		       quux_out ? ", wrote " : "", quux_out ? quux_out : "");
		chk_free(&qb);
		qi.main13 = NULL;
		img_free(&qi);
		free(packed);
		free(q);
	}
	// ---- **AN ADDRESS IS OCTAL** ----------------------------------------
	//
	// `--chaos-address 177100` went through `strtoul(.., 0)` and put
	// 0o131714 --- the low sixteen bits of one hundred and seventy-seven
	// thousand --- into the checkpoint's switches, and muir refused the
	// file saying exactly that.  Only `0177100` worked.  muir's flag
	// "wants one address in octal or subnet:host", and
	// `chaos::parse_address` is the whole of what it takes; this is that
	// parser in C, so the spellings are compared against muir's rules and
	// not against this program's own habits.
	//
	// **SKIPPED UNDER A MUTANT, AND THAT IS NOT A CHECK LOOKING AWAY.**
	// Mutant 8 REPLACES this parser, so these vectors would be asserting
	// the thing the mutant took out: they fail by construction, the test
	// exits non-zero, and the loop that judges the mutants would call it
	// BROKEN rather than caught.  What holds the mutant is the file ---
	// the address in it comes down this parser, so a decimal reader puts
	// 0o131551 in the switches and muir refuses it by name, which is the
	// first leg of that loop and is exactly how the defect was found on
	// the board.  The two hold different halves: the vectors hold the
	// parser, the mutant holds that the FIELD comes through it.
	if (!chk_rtl_mutation()) {
		static const struct { const char *s; int ok; unsigned want; } t[] = {
			// The board's own, which is the spelling that was wrong.
			{ "177100", 1, 0177100u },
			// A leading zero changes nothing: the string is octal
			// already, and both spellings are the same address.
			{ "0177100", 1, 0177100u },
			{ "3050", 1, 03050u },
			{ "177001", 1, 0177001u },
			// subnet:host, muir's other form --- and `376:1` is the
			// same address as `177001` written the other way, which
			// is what says the two forms are one number.
			{ "376:1", 1, 0177001u },
			{ "1:1", 1, 0401u },
			// **A DIGIT 8 OR 9 IS NOT OCTAL.**  This is the whole of
			// the defect: a decimal reader takes these and an octal
			// one refuses them.
			{ "177108", 0, 0 },
			{ "9", 0, 0 },
			{ "18:1", 0, 0 },
			// No prefix of any kind, which muir has none of either.
			{ "0x1234", 0, 0 },
			{ "0o177100", 0, 0 },
			// Both halves non-zero, which is muir's `both`.
			{ "0", 0, 0 },
			{ "377", 0, 0 },
			{ "177000", 0, 0 },
			{ "1:0", 0, 0 },
			{ "0:1", 0, 0 },
			// A byte of a pair is at most 0o377.
			{ "400:1", 0, 0 },
			{ "1:400", 0, 0 },
			// And nothing at all is nothing.
			{ "", 0, 0 },
			{ ":", 0, 0 },
			{ "177100:", 0, 0 },
			{ "177777", 1, 0177777u },
			{ "200000", 0, 0 },
		};
		for (unsigned i = 0; i < sizeof t / sizeof t[0]; ++i) {
			unsigned got = 0xFFFFFFFFu;
			const int rc = chk_chaos_address(t[i].s, &got);
			if (t[i].ok) {
				if (rc != 0)
					fail("an address this program must take", 1, 0);
				else if (got != t[i].want)
					fail(t[i].s, got, t[i].want);
			} else if (rc == 0) {
				fail("an address this program must refuse", got, 1);
			}
		}
	}

	img_free(&img);
	free(m);

	if (bad) {
		fprintf(stderr, "FAIL: %ld mismatches\n", bad);
		return 1;
	}
	printf("PASS\n");
	return 0;
}
