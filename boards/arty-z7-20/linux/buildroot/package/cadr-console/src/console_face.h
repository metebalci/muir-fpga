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
//     1  STAT     bit 0 busy, 1 gnt, 2 answered, 3 lost (sticky since reset)
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
//     10-15       UNMAPPED
//
//   page 1, +0x40, word k IS diagnostic register `EADR` k:
//     read   a diagnostic READ cycle: `SPY<15:0>` in bits 15:0 with 31:16
//            zero, or bit 16 set meaning the cycle was not answered
//     write  a diagnostic WRITE cycle with `SPY<15:0>` from bits 15:0
//
// **THE HIGH HALF IS LATCHED BY THE LOW HALF'S READ**, so a 64-bit counter is
// read low then high and the pair names one instant across the carry.  A
// program that reads the high word alone gets whatever the last low read
// latched.  `cons_cycles` and `cons_ticks` are the only readers of the high
// words here, and they are in that order for that reason.
//
// **EVERY ADDRESS ON GP1 IS ANSWERED, WITH OKAY**, and an address in neither
// page reads `CONS_UNMAPPED`, the complement of IDENT.  Neither zero nor all
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
#define CONS_REG_BYTES   128u
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
// **THE MACHINE'S OWN TIME DID NOT CHANGE AND THIS IS NOT A CONVERSION FOR
// IT.**  A microcycle is 29 ticks whatever a tick costs, and `status`
// measures microcycles against a wall-clock wait, so the only place the two
// meet is here and in `console_test.c`'s model.  Getting it wrong prints a
// wrong duration; it cannot corrupt anything.
#define CONS_TICKS_PER_US  100u

// Page 0.
enum cons_p0 { CONS_IDENT = 0, CONS_STAT = 1, CONS_CYCLES = 2, CONS_CYCLESH = 3,
	       CONS_TICKS = 4, CONS_TICKSH = 5, CONS_RESET = 6, CONS_VMA = 7,
	       CONS_Q = 8, CONS_MD = 9 };
enum cons_stat_bit { CONS_ST_BUSY = 1u << 0, CONS_ST_GNT = 1u << 1,
		     CONS_ST_ANSWERED = 1u << 2, CONS_ST_LOST = 1u << 3 };

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

// `step N`: CC's `CC-CLOCK`, `2` then `0`, N times (../muir/src/spy.rs's
// ClockControl and ../muir/tests/spy.rs:743-761).
//
// **THE FABRIC DOES NOT HAVE THIS YET.**  `SSTEP` and `SSDONE` are two flip
// flops of the 74S174 at OLORD1 1A10 and `cadr_microcycle.sv` has neither;
// `cadr_spy_registers.sv` takes bit 0 of a CLK write and drops bits 4:1.  So
// the writes go out, land as a write of RUN=0, and the machine does not move.
// This measures that rather than assuming it: CYCLES before and after, and
// `moved` is the difference.  A silent no-op is the failure this project
// keeps meeting.
struct cons_step {
	unsigned asked;		/* how many steps were asked for */
	uint64_t before, after;	/* CYCLES either side */
	uint64_t moved;		/* after - before: 0 on today's fabric */
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
// (../muir/src/rtl.rs:2386) does not advance on a halted master clock cycle,
// so a machine that is not running cannot move it; and `Engine::step` goes on
// returning Ok on a stopped machine, which is why nothing but the counter can
// answer this.  The reason a stopped machine gives is FLAG-1's, decoded as
// ../muir/src/main.rs:2278-2305 (`machrun_low`) decodes it.
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
// somebody else's correct change**, which is exactly the rot CLAUDE.md
// records: the `@old` of a mutation rots loudly and prose rots silently.  It
// is cited to the commit that fixed it rather than left to read as true.
//
// The other route, CC's `CC-EXECUTE-R`, loads a microinstruction into the
// debug IR and clocks it --- and clocking it is `SSTEP`, the same two hunks
// `step` is waiting for.
//
// **SO EXAMINE AND DEPOSIT GO THROUGH /dev/mem ON THE MACHINE'S RESERVED DDR
// REGION, AND SAY SO IN THEIR OWN OUTPUT.**  What that reads is the memory
// the machine's bus cycles land in, not the machine's view of it: nothing is
// halted, nothing is synchronised, and a word read while the machine is
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
