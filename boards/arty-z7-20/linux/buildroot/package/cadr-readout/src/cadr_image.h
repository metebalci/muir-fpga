// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A CADR as the readout window can be asked about it.
//
// **THE WINDOW REACHES THE PROCESSOR'S MEMORIES AND REGISTERS AND NOTHING
// ELSE**, and it is worth saying what that leaves out, because somebody will
// want it: the disk controller, whole, with its command, its command-list
// pointer and its eight drives; the I/O board, whole, including the
// microsecond clock that is the CADR's timebase; the bus interface's own
// registers --- the Unibus map, its read and write buffers, the error
// register and the interrupt status --- none of which is in the fabric at
// all; and the display's mode register and sync generator, though the picture
// is in DDR where Linux can read it.  None of that is a defect of this
// struct: it is the shape of what the window can say, and the debugger that
// will say the rest is CC over the debug cable, which reads the scratchpads
// by forcing a microinstruction into the instruction register rather than by
// adding a port beside the machine.

#ifndef CADR_IMAGE_H
#define CADR_IMAGE_H

#include <stdint.h>

// The arrays, at the sizes muir's `Machine` declares them.
#define IMG_PROM_WORDS  1024u
#define IMG_IMEM_WORDS  16384u
#define IMG_AMEM_WORDS  1024u
#define IMG_MMEM_WORDS  32u
#define IMG_DMEM_WORDS  2048u
#define IMG_PDL_WORDS   1024u
#define IMG_SPC_WORDS   32u
#define IMG_L1_WORDS    2048u
#define IMG_L2_WORDS    1024u
#define IMG_OPCS        8u
// simpletv::BUFFER_WORDS, 0o100000.
#define IMG_TV_WORDS    32768u
// A memory board is 64K words and `boards(7'd32)` is what
// `boards/arty-z7-20/cadr_arty.sv` gives the machine.
#define IMG_BOARD_WORDS 65536u

// The readout's selectors, `cadr_microcycle.sv`'s `RO_*`.
enum img_sel {
	IMG_SEL_IMEM = 0, IMG_SEL_PROM = 1, IMG_SEL_AMEM = 2, IMG_SEL_MMEM = 3,
	IMG_SEL_PDL = 4, IMG_SEL_SPC = 5, IMG_SEL_DMEM = 6, IMG_SEL_MAP1 = 7,
	IMG_SEL_MAP2 = 8, IMG_SEL_OPCS = 9, IMG_SEL_REGS = 10
};

// The register table's entries, `cadr_microcycle.sv`'s `RG_*`.
enum img_reg {
	IMG_RG_PC = 0, IMG_RG_LPC = 1, IMG_RG_IR = 2, IMG_RG_IWR = 3,
	IMG_RG_L = 4, IMG_RG_Q = 5, IMG_RG_VMA = 6, IMG_RG_MD = 7,
	IMG_RG_ST = 8, IMG_RG_LC = 9, IMG_RG_WADR = 10, IMG_RG_PDLPTR = 11,
	IMG_RG_PDLIDX = 12, IMG_RG_SPCPTR = 13, IMG_RG_RETA = 14,
	IMG_RG_DC = 15, IMG_RG_LVMO = 16, IMG_RG_MDHELD = 17,
	IMG_RG_PHYS = 18, IMG_RG_SPEED = 19, IMG_RG_FLAGS = 20
};

// The flag word's bits, `ro_flags`'s concatenation read from bit 0 up.  **The
// order here and the order there are one thing said twice**, which is a thing
// this project otherwise refuses; there is no third place to put it, the
// fabric having no way to name a bit and C having no way to read Verilog.  A
// bit moved in one and not the other is caught by `build/readout.pass`, which
// compares the whole word against the machine's own registers.
enum img_flag {
	IMG_F_DESTD = 0, IMG_F_DESTMD, IMG_F_PWIDX, IMG_F_PDLWRITED,
	IMG_F_INOP, IMG_F_IWRITED, IMG_F_NEWLC, IMG_F_SINTR,
	IMG_F_NEXT_INSTRD, IMG_F_LC_BYTE_MODE, IMG_F_INT_ENABLE,
	IMG_F_SEQUENCE_BREAK, IMG_F_PROG_UNIBUS_RESET, IMG_F_TRAP,
	IMG_F_PROMDISABLED, IMG_F_SRUN, IMG_F_STATSTOP, IMG_F_HALTED,
	IMG_F_MEMSTART, IMG_F_MBUSY, IMG_F_RDCYC, IMG_F_WRCYC,
	IMG_F_MBUSY_SYNC, IMG_F_RD_IN_PROGRESS, IMG_F_WMAPD, IMG_F_SPUSHD,
	IMG_F_DESTSPCD, IMG_F_IMODD, IMG_F_VMAOK, IMG_F_MD_PENDING,
	IMG_F_RUN, IMG_F_ERRSTOP, IMG_F_STATHENB
};

struct cadr_image {
	// --- what the readout window gives
	uint64_t *prom;			/* IMG_PROM_WORDS, 48 bits each */
	uint64_t *imem;			/* IMG_IMEM_WORDS, 48 bits each */
	uint32_t *amem, *mmem, *pdl;
	uint32_t *spc;			/* 21 bits */
	uint32_t *dmem;			/* 17 bits */
	uint32_t *l1_map;		/* 5 bits */
	uint32_t *l2_map;		/* 24 bits */
	uint16_t opcs[IMG_OPCS];	/* 14 bits, newest first */

	// --- the register table
	uint16_t pc, lpc, wadr, pdl_ptr, pdl_idx, reta, dc;
	uint64_t ir, iwr;
	uint32_t l, q, vma, md, st, lc, lvmo, md_held, phys_r;
	uint8_t spcptr;
	uint8_t speed, speed_a, mode_speed;
	uint64_t flags;

	// --- the console's own page 0
	uint64_t cycles;	/* microcycles retired since the machine's reset */
	uint64_t ticks;		/* fabric ticks since the same instant */

	// --- main memory and the display, which are DDR and not the window's:
	// --- Linux maps them at `cadr_ddr_map.sv`'s bases.  They are here so
	// --- that a reader of this struct is not left wondering where they
	// --- went, and `cadr-readout` does not fill them.
	uint32_t *main;		/* boards * IMG_BOARD_WORDS */
	unsigned boards;
	uint32_t *tv;		/* IMG_TV_WORDS */

};

int img_alloc(struct cadr_image *img, unsigned boards);
void img_free(struct cadr_image *img);

static inline int img_flag(const struct cadr_image *img, enum img_flag b)
{
	return (img->flags >> (unsigned)b) & 1u;
}

#endif
