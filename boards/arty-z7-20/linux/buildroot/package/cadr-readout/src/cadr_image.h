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
// register and the interrupt status, of which only the read and write
// buffers are absent from the fabric, the rest being
// `rtl/machine/cadr_busint_regs.sv`; and the display's mode register and sync
// generator, though the picture is in DDR where Linux can read it.  None of that is a defect of this
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
// tv::BUFFER_WORDS, 0o100000.
#define IMG_TV_WORDS    32768u
// The color map a display board keeps: `tv::COLORS` by `tv::CHANNELS`,
// sixteen colors of red, green and blue.
#define IMG_MAP_COLORS   16
#define IMG_MAP_CHANNELS 3
// A memory board is 64K words, and how many the CADR has is the console's
// page 2 word 37 (`ro_main_boards`), 32 unless the card says otherwise.
// QUUX has no boards: the same word holds its main memory as an amount in
// units of this size, sixteen a megaword (`ro_main_amount`).
#define IMG_BOARD_WORDS 65536u

// **REVISION 13'S** (contract G2 §2, appendix A1; muir's `Geometry::QUUX`):
// words of 40 bits --- A, M, the PDL buffer, Q, VMA, MD, L and main memory
// --- read out whole, the tag in <39:32>; a dispatch memory of 4,096
// entries; a level-1 map of 8,192 seven-bit entries and a level-2 map of
// 4,096 28-bit ones; the location counter 30 bits; and the fixnum overflow
// flag, the flag word's <35>.  `img_alloc_revision` sizes the arrays by
// these, and the largest of each is what the arrays are declared for.
#define IMG_DMEM_WORDS_13 4096u
#define IMG_L1_WORDS_13   8192u
#define IMG_L2_WORDS_13   4096u
#define IMG_WORD_BITS_13  40u
// **WHICH REVISION**: the register table's entry 21, QUUX's signature over K
// and L, carries MACHINE-ID's <15:0> in its own <15:0> on revision 13, 0x00D4
// (`cadr_machine.sv`'s MACHINE_ID, revision 13 in <11:4>, the processor type
// 4 in <3:0>); revision 12's bitstreams answer 0 there.  **The fabric's side
// of this is not built yet**: it is what this program asks of it.
#define IMG_QUUX_ID_13    0x00D4u
// Revision 14's (contract G3 revision 14, appendix A14), 0x00E4: revision 13's
// words, sizes and packed storage, no map levels, and the memory system's
// words in the register table's entries 41 to 45 (A14.14).
#define IMG_QUUX_ID_14    0x00E4u
// Revision 15's (contract G3 revision 15, A15b.13), 0x00F4: the pipelined
// core (`quux15_core.sv`) behind its own console face (`quux15_face.sv`),
// revision 14's words, sizes and packed storage, the control store at 64
// bits, and a register table of its own (`img_rg15`).  Entry 21's <31:24>
// is the clock's period in units of 0.5 ns, not K, and <23:16> is 0.
#define IMG_QUUX_ID_15    0x00F4u

// **QUUX'S SIZES**, muir's `Geometry::QUUX`: a PDL buffer of 16K words with a
// fourteen-bit pointer, a level-1 map entry of six bits and so 2,048 level-2
// entries, the boot PROM at control store 36000 and never written there, and
// the video controller's buffer, 1280 by 1024 at one bit a pixel unless the
// bitstream says another size (`cadr/cadr_video.h`; `img_alloc_video`).
// `img_alloc_machine` sizes the arrays by these on QUUX.
#define IMG_QUUX_PDL_WORDS  16384u
#define IMG_QUUX_L2_WORDS   2048u
#define IMG_QUUX_TV_WORDS   40960u
#define IMG_QUUX_PROM_BASE  036000u
#define IMG_QUUX_FIFO_WORDS 64u

// The readout's selectors, `cadr_microcycle.sv`'s `RO_*`, and the one
// `cadr_machine.sv` joins into the same window beside them.
enum img_sel {
	IMG_SEL_IMEM = 0, IMG_SEL_PROM = 1, IMG_SEL_AMEM = 2, IMG_SEL_MMEM = 3,
	IMG_SEL_PDL = 4, IMG_SEL_SPC = 5, IMG_SEL_DMEM = 6, IMG_SEL_MAP1 = 7,
	IMG_SEL_MAP2 = 8, IMG_SEL_OPCS = 9, IMG_SEL_REGS = 10,
	IMG_SEL_AUDIT = 11, IMG_SEL_QUUX_PAGE = 12,
	// QUUX's MACRO DISPATCH MEMORY, 1,024 entries of 18 bits (revision 12).
	IMG_SEL_MACRO = 13
};
#define IMG_QUUX_MACRO_ENTRIES 1024u

// --- QUUX'S OWN, which the CADR's bitstream answers `RO_NO_MEMORY` at.
//
// The register table's entries 21 to 28, `cadr_microcycle.sv`'s `RG_QUUX_*`:
// which machine this is, and the processor's clocks.  Entry 21 is QUUX's
// signature over K and L, the microcycle the bitstream was built at; 22 the
// microsecond clock; 23 + k interval timer k's count and 26 + k its
// interrupt enable, mode and period (revision 10, contract Q11).
enum img_quux_reg {
	IMG_RG_QUUX_ID = 21, IMG_RG_QUUX_TIME = 22, IMG_RG_QUUX_COUNT = 23,
	IMG_RG_QUUX_CONF = 26,
	// Revision 12's fused return (contract H8a), `RG_QUUX_MACRO` and on:
	// the MACRO-DISPATCH register; the memory's index; the base copies,
	// `M-AP`'s in 27:14 and `A-LOCALP`'s in 13:0; what a fused return armed
	// (`<8>` the operand address, `<7>` ARG, `<5:0>` delta, `<9>` M 31's
	// word, `<10>` A 31 reading M 31's register); M 31's armed word; the
	// fused returns, the operand addresses loaded and the prefetched words
	// taken, counted; and the cache-only prefetch as the processor sees it:
	// `<24>` held and its virtual word address, its physical word address,
	// the word, and a fetch yet to be answered, `<24>` and its address.
	IMG_RG_QUUX_MACRO = 29, IMG_RG_QUUX_MACRO_IX = 30, IMG_RG_QUUX_BASES = 31,
	IMG_RG_QUUX_ARMED = 32, IMG_RG_QUUX_M31_W = 33, IMG_RG_QUUX_FUSED_N = 34,
	IMG_RG_QUUX_OPR_N = 35, IMG_RG_QUUX_PF_N = 36, IMG_RG_QUUX_PF = 37,
	IMG_RG_QUUX_PF_PHYS = 38, IMG_RG_QUUX_PF_WORD = 39, IMG_RG_QUUX_PF_FETCH = 40,
	// Revision 14's memory system (A14.9, A14.14): `<18>` word 221's
	// ephemeral-reference enable over word 220, the directory base, in
	// `<17:0>`; words 222 and 223, the pointer-type register; word 224, the
	// refused write-backs; and the redirect's copies, the head's 14 bits
	// in `<45:32>` over the base's 32.
	IMG_RG_QUUX_MS = 41, IMG_RG_QUUX_TYPES0 = 42, IMG_RG_QUUX_TYPES1 = 43,
	IMG_RG_QUUX_REFUSED = 44, IMG_RG_QUUX_COPIES = 45
};
#define IMG_QUUX_TIMERS 3
#define IMG_QUUX_MARK 0x5155u
// Selector 12, `cadr_machine.sv`'s register page readout: the keyboard and
// mouse, block-disk, the page's bus errors and the video controller's black-on-white, the
// file device's rings, indexes and flags (revision 9), and the keyboard
// FIFO's words at 64 + their index.
enum img_quux_page {
	IMG_QP_INPUT = 0, IMG_QP_CMD = 1, IMG_QP_CLP = 2, IMG_QP_DA = 3,
	IMG_QP_LMA = 4, IMG_QP_DISK = 5, IMG_QP_PAGE = 6,
	IMG_QP_FD_BASES = 7, IMG_QP_FD_INDEXES = 8, IMG_QP_FD_FLAGS = 9,
	// Revision 13's ring bases are 28 bits and two no longer fit one
	// word: word 7 holds the command ring's in <27:0>, and word 10 the
	// response ring's (contract G2 §4.3, appendix A1.10).  The fabric's
	// side is not built yet.
	IMG_QP_FD_RESP_BASE_13 = 10,
	IMG_QP_FIFO = 64
};

// One of QUUX's three interval timers as its two words read, and the tick
// of muir's clock (ticks since power-on) its count was taken at.
struct quux_timer {
	int en, sticky, live;
	unsigned pre;		/* ticks left in the microsecond, less one */
	uint32_t us;		/* microseconds left, counted down to one */
	uint64_t m;		/* the tick the count was taken at */
	int one_shot, ie;	/* its mode and its interrupt enable */
	uint32_t period_us;	/* its period, as last written */
};

// What a QUUX bitstream says of itself that a CADR's does not.
struct quux_state {
	unsigned k, l;		/* the microcycle: K ticks, and L more for ILONG */
	// The checkpoint's instant: muir's clock, ticks of MIT's grid since
	// power-on, off the microsecond clock and its prescaler, unwrapped
	// against the console's TICKS.
	uint64_t m;
	struct quux_timer timer[IMG_QUUX_TIMERS];	/* timers 0, 1 and 2 */
	// The keyboard and mouse, `QuuxInput`.
	unsigned head, count;
	int overflowed, kbd_enable, mouse_changed, mouse_enable;
	unsigned buttons, x, y;
	uint32_t fifo[IMG_QUUX_FIFO_WORDS];	/* by index; `count` from `head` */
	// Block-disk.
	uint32_t cmd, clp, da, lma;
	int walking, walked, not_active, past_end, nxm, bad_command, present;
	int32_t since_done;	/* ticks since the blocks' time ran out */
	// The page's bus errors, as word 101 reads them, and the video controller's mode.
	unsigned bus_error;
	int bow;
	// The file device (revision 9), muir's `FileDevice::save`: its four
	// flags, the rings' bases and sizes and the three indexes; and the
	// handles open and the host's claim, which a checkpoint is refused on.
	int fd_enabled, fd_ie, fd_refused, fd_fault, fd_busy;
	unsigned fd_handles;
	uint32_t fd_cmd_base, fd_cmd_log2, fd_resp_base, fd_resp_log2;
	uint16_t fd_cmd_prod, fd_cmd_cons, fd_resp_cons;
	// Revision 12's fused return, muir's `MacroDispatch`, and the prefetch,
	// `MemoryPort`'s `prefetched` and `fetch_vaddr`; and three counts no
	// checkpoint carries.
	uint32_t macro_reg, macro_index, localp, ap;
	uint32_t macro_entries[IMG_QUUX_MACRO_ENTRIES];
	int opr_v, opr_arg, m31_v;
	unsigned opr_delta;
	uint64_t m31_w;
	int pf_v, fetch_v;
	uint32_t pf_vaddr, pf_phys, fetch_vaddr;
	uint64_t pf_word;
	uint32_t fused_n, opr_n, pf_n;
	// Revision 14's memory system, muir's `tlb::Words` and `PdlCopies`.
	uint32_t directory, refused, pdl_base;
	int ephemeral;
	uint64_t pointer_types;
	uint16_t pdl_head;
};


// --- THE TRANSACTION AUDIT, `rtl/plumbing/cadr_bus_audit.sv`.
//
// Nine words at selector 11, each carrying `B05A` in its top sixteen bits.
// The marker is not decoration: with the level shifters on, an undriven path
// reads all ones and with them off it reads all zeros, and the readout window
// answers `A5A5_5A5A_A5A5` for a selector the fabric does not map --- so
// without it a reading of "no faults" and a reading of "no instrument" would
// be the same word.  This program refuses a word whose marker is not this.
#define IMG_AUDIT_WORDS 9u
#define IMG_AUDIT_MARK  0xB05Au

// The clause codes, as the module names them.  Zero IS "nothing was latched":
// there is no separate valid bit for it to disagree with.
enum img_audit_clause {
	IMG_AUD_NONE = 0, IMG_AUD_TWICE = 1, IMG_AUD_TWO_REQS = 2,
	IMG_AUD_DIRECTION = 3, IMG_AUD_NO_CYCLE = 4, IMG_AUD_NOT_MEMORY = 5,
	IMG_AUD_LOOSE_ANS = 6, IMG_AUD_PORT_EXTRA = 7
};

struct cadr_audit {
	unsigned faults;	/* saturating at 32,767; any reading but zero is the finding */
	unsigned stalled;	/* requests that fell with no answer at all */
	unsigned seen;		/* which clauses ever fired, bit (clause - 1) */
	unsigned clause;	/* the FIRST fault's, and the latch's own valid bit */
	uint32_t phys;		/* what the master asked for, 22 bits */
	uint32_t addr;		/* what went out on the port, a byte address */
	uint32_t data;		/* what stood on the write-data lines: the corruption */
	uint32_t vma, md, micro;
	unsigned pc, opc;
	// The port's own answers, `cadr_mem_count.sv`'s layout.  Zero with the
	// fault count zero says the two wires are dead rather than that all was
	// well, which is the one thing the clause alone cannot say.
	unsigned port_reads, port_writes;
};

// --- REVISION 15'S WINDOW, `quux15_core.sv`'s readout ------------------
//
// The selectors are the console's (`img_sel`) for the memories, the control
// store's 64 bits whole; the register table at selector 10 is revision 15's
// own (`img_rg15`); selector 12 is the devices' (`img_dv15`), selector 14 the
// halted pipeline's (`save_15`'s fields, `img_tl15`), and a write of
// selector 15 takes the devices' snapshot, the instant and the timers, which
// the time words then read, so that a checkpoint names one instant however
// long its reads take.  Word 12 of the face carries a word's <63:32> whole.
#define IMG_SEL_TAIL 14u
#define IMG_SEL_SNAP 15u
enum img_rg15 {
	IMG_RG15_Q = 0, IMG_RG15_VMA = 1, IMG_RG15_MD = 2,
	IMG_RG15_LC = 3,	/* <33:0> the counter, <40> NEED-FETCH */
	IMG_RG15_PDLPTR = 4, IMG_RG15_PDLIDX = 5, IMG_RG15_SPCPTR = 6,
	IMG_RG15_INTCTL = 7,	/* as muir holds it, <29:26> */
	IMG_RG15_DC = 8,
	IMG_RG15_FLAGS = 9,	/* <0> overflow, <1> VMAOK, <2> word 101's NXM */
	IMG_RG15_OPC = 10,	/* muir's `Machine::opc` */
	IMG_RG15_MACRO = 11, IMG_RG15_MACRO_IX = 12,
	IMG_RG15_BASES = 13,	/* <13:0> A-LOCALP's copy, <29:16> M-AP's */
	IMG_RG15_ARMED = 14,	/* <8> armed, <7> ARG, <5:0> delta */
	IMG_RG15_DIRECTORY = 15,	/* <17:0> word 220, <18> word 221's enable */
	IMG_RG15_TYPES = 16, IMG_RG15_REFUSED = 17,
	IMG_RG15_COPIES = 18,	/* <31:0> A 430's copy, <45:32> A 431's */
	IMG_RG15_POSTED = 19,	/* word 225 */
	IMG_RG15_CLOCKS = 20,
	IMG_RG15_ID = 21,	/* QUUX's signature, the period, MACHINE-ID's <15:0> */
	IMG_RG15_COMMITTED = 22,
	IMG_RG15_COUNT = 23
};
enum img_dv15 {
	IMG_DV15_TIMER = 0,	/* + k: <0> on, <1> one-shot, <2> enable, <31:8> period */
	IMG_DV15_DEADLINE = 3,	/* + k: in units of 0.5 ns, all ones for none */
	IMG_DV15_FD = 6,	/* <0> on, <1> enable, <2> refused, <3> fault, <15:8> handles */
	IMG_DV15_FD_CBASE = 7, IMG_DV15_FD_RBASE = 8,
	IMG_DV15_FD_LOGS = 9,	/* <3:0> command, <7:4> response */
	IMG_DV15_FD_INDEXES = 10,	/* <15:0> producer, <31:16> consumer, <47:32> response consumer */
	IMG_DV15_BD_CMD = 11, IMG_DV15_BD_CLP = 12, IMG_DV15_BD_DA = 13, IMG_DV15_BD_LMA = 14,
	IMG_DV15_BD_FLAGS = 15,	/* <0> bad command, <1> past the end, <2> NXM, <3> active */
	IMG_DV15_BD_DONE = 16, IMG_DV15_BD_NOW = 17,
	IMG_DV15_BOW = 18,
	IMG_DV15_NS = 19,	/* the snapshot's instant, muir's `Machine::ns` */
	IMG_DV15_RTC = 20, IMG_DV15_US = 21,
	IMG_DV15_TV_AT = 22,	/* the last RESET-DEVICES's instant */
	IMG_DV15_COUNT = 23
};
// The halted pipeline's words, `ro_sel` 0 to 23 (`quux15_core.sv`).
enum img_tl15 {
	IMG_TL15_NPC = 0, IMG_TL15_NPC_AFTER = 1, IMG_TL15_NOPS = 2, IMG_TL15_PDL_PENDING = 3,
	IMG_TL15_PDL_WORD = 4, IMG_TL15_MD_OLD = 5, IMG_TL15_MD_OLD_WORD = 6, IMG_TL15_D_WAIT = 7,
	IMG_TL15_OA_LOW = 8, IMG_TL15_OA_HIGH = 9, IMG_TL15_NEXT_INSTRD = 10, IMG_TL15_LVMO = 11,
	IMG_TL15_WRCYC = 12, IMG_TL15_SPC_WRITE = 13, IMG_TL15_MAP_WRITE = 14,
	IMG_TL15_MAP_VMA = 15, IMG_TL15_MAP_MD = 16, IMG_TL15_OPC_LOW = 17, IMG_TL15_OPC_HIGH = 18,
	IMG_TL15_HALTED = 19, IMG_TL15_COMMITTED = 20, IMG_TL15_NPC_PREV = 21,
	IMG_TL15_CONSOLE = 22,	/* <5:0> mode, <10:6> clock control, <13:11> OPC control */
	IMG_TL15_DEBUG_IR = 23,
	IMG_TL15_COUNT = 24
};

// What revision 15's window says that the others' do not.
struct quux15_state {
	unsigned period;		/* entry 21's <31:24>: units of 0.5 ns */
	uint64_t lc;			/* <33:0> and <40> NEED-FETCH */
	uint32_t intctl;
	int overflow, vmaok, bus_nxm;
	uint16_t opc;			/* muir's `Machine::opc` */
	uint64_t clocks, committed;
	uint64_t ns;			/* the snapshot's instant */
	uint32_t timer_ctl[IMG_QUUX_TIMERS];
	uint64_t deadline[IMG_QUUX_TIMERS];
	uint32_t bd_cmd, bd_clp, bd_da, bd_lma, bd_flags;
	uint64_t bd_done, bd_now;
	uint64_t tv_at;			/* muir's `Tv::written_at` */
	uint32_t posted;
	uint64_t tail[IMG_TL15_COUNT];
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
	IMG_F_RUN, IMG_F_ERRSTOP, IMG_F_STATHENB,
	// QUUX's memory port idle and its write buffer empty (contract Q6: a
	// halt drains the buffer before anything outside the machine reads
	// main memory).  Zero on the CADR, which has no buffer.
	IMG_F_MEM_DRAINED,
	// QUUX's `MEMSTART` cycle is the stream's instruction fetch (revision
	// 12's prefetch, muir's `Rtl::memstart_fetch`).  Zero on the CADR.
	IMG_F_MEMSTART_FETCH,
	// Revision 13's fixnum overflow flag, muir's `Machine::overflow`
	// (appendix A1.3).  Zero on every other machine.
	IMG_F_OVERFLOW
};

struct cadr_image {
	// --- what the readout window gives
	uint64_t *prom;			/* IMG_PROM_WORDS, 48 bits each */
	uint64_t *imem;			/* IMG_IMEM_WORDS, 48 bits each */
	uint64_t *amem, *mmem, *pdl;	/* words: 32 bits, 40 on revision 13 */
	uint32_t *spc;			/* 19 bits */
	uint32_t *dmem;			/* 17 bits, `dmem_words` of them */
	uint32_t *l1_map;		/* 5 bits, 6 on QUUX, 7 on revision 13 */
	uint32_t *l2_map;		/* 24 bits, 28 on revision 13 */
	uint16_t opcs[IMG_OPCS];	/* 14 bits, newest first */

	// --- the register table
	uint16_t pc, lpc, wadr, pdl_ptr, pdl_idx, reta, dc;
	uint64_t ir, iwr;
	uint64_t l, q, vma, md, md_held;	/* words */
	uint32_t st, lc, lvmo, phys_r;
	uint8_t lc_hi;			/* revision 14's LC<33:32>, 0 before it */
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
	uint32_t *main;		/* boards * IMG_BOARD_WORDS; NULL on revision 13 */
	unsigned boards;	/* the CADR's boards, or QUUX's amount in 64K-word units */
	// --- revision 13's main memory is packed storage, 5 bytes a word
	// --- (G1 4.1), and is NOT copied: `main13` is the bytes where they
	// --- are --- on a board the DDR mapping itself, 160 MB at 32M words,
	// --- which a copy beside a body of the same size would not leave room
	// --- for --- and `chk_rtl_body` hands them to the file as they stand.
	const volatile uint8_t *main13;	/* boards * IMG_BOARD_WORDS * 5 bytes */
	uint32_t *tv;		/* tv_words: IMG_TV_WORDS, or the video controller's */

	// --- the first display board's color map, `[color][channel]` with
	// --- red first.  It is not DDR and it is not the readout window: it
	// --- is the console face's page 4, which is the only way to read a
	// --- map back at all --- register 4 is write only on the Xbus, the
	// --- RAMs being off the board.  A checkpoint carries it because
	// --- muir's `tv::Tv::color_map` is part of the machine.
	uint8_t tv_map[IMG_MAP_COLORS][IMG_MAP_CHANNELS];

	// --- which machine, and the arrays' sizes on it: the CADR's, or on
	// --- QUUX the PDL buffer's 16K, level 2's 2,048 and the video controller's buffer;
	// --- on revision 13 (`rev13`) the dispatch memory's 4,096, level 1's
	// --- 8,192 and level 2's 4,096, and words of 40 bits.
	// --- revision 14 (`rev14`) is revision 13's in all of these, `rev13`
	// --- set too, but has no map levels: both are written zero and not read.
	// --- revision 15 (`rev15`) is revision 14's in all of these, `rev13`
	// --- and `rev14` set too; its own state is `q15`.
	int quux, rev13, rev14, rev15;
	unsigned pdl_words, l2_words, tv_words, dmem_words, l1_words, word_bits;
	// --- QUUX's video controller's size, the bitstream's (console word
	// --- 39): `tv_words` is its height times its width over 32.  0 on the
	// --- CADR.
	unsigned video_width, video_height;
	struct quux_state qx;	/* QUUX's alone; zero on the CADR */
	struct quux15_state q15;	/* revision 15's alone */
};

// The CADR's machine.
int img_alloc(struct cadr_image *img, unsigned boards);
// Either machine's: `quux` non-zero sizes the arrays as QUUX's.
int img_alloc_machine(struct cadr_image *img, unsigned boards, int quux);
// And a QUUX of either revision, 12 or 13: revision 13's arrays at its sizes
// and no main memory, which is `main13`'s to point at.
int img_alloc_revision(struct cadr_image *img, unsigned boards, int quux, int revision);
// And with QUUX's video controller at `width` by `height`, which a QUUX
// bitstream says on its console (`ro_video`); the two above take 1280 by
// 1024.  Refused, -1, for a size `cadr/cadr_video.h` does not take.
int img_alloc_video(struct cadr_image *img, unsigned boards, int quux, int revision,
		    unsigned width, unsigned height);
void img_free(struct cadr_image *img);

static inline int img_flag(const struct cadr_image *img, enum img_flag b)
{
	return (img->flags >> (unsigned)b) & 1u;
}

#endif
