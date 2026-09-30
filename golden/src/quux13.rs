// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **QUUX revision 13's processor** (contract G2 §2, with its appendix A1),
//! as programs in the boot PROM, traced on muir's `rtl` engine on
//! `Geometry::QUUX_13`.
//!
//!     quux13 --program <name> --sync-cycle-ticks K [--sync-ilong-ticks L]
//!     quux13 --program <name> --prom
//!
//! Each program is a group of the scenarios muir's own
//! `tests/revision_13.rs` holds revision 13's datapath to, written again
//! here without presets, in `golden/src/trace.rs`'s columns, which
//! `tb/cadr_machine_tb.cpp` compares row for row against the whole machine
//! built at `WORD_BITS` 40 with the same PROM image:
//!
//!   alu       the ALU on tags, A=M on 40 bits, M < A and M <= A on the
//!             fields, the overflow flag and condition 10, condition 11,
//!             the numeric sources and zero-extended constants, and a word
//!             with `<39:32>` set through every register the processor has
//!             that is not memory
//!   byte      LDB in the ring of 40, DPB and selective deposit at 40 bits,
//!             LC byte mode by `IR<24>` on halfwords and on bytes, a BYTE
//!             word's `IR<11:10>` as length bits under ERRSTOP, ALU output
//!             select 0, and a JUMP's bit test with `IR<47>` and in LC byte
//!             mode
//!   dispatch  DISPATCH into entries above 2,047 on the type, the byte at 5
//!             and the cdr code, from the address alone, in LC byte mode on
//!             both halfwords, and the write and fall-through at `7777`
//!   map       the map at 8,192 x 7 and 4,096 x 28 through `MAP(MD)`: the
//!             level indices, `<39:32>` and `<9:8>` outside them, the
//!             `<31:28>` gate on a lookup, a write and a read, the round trip
//!             at level 1 `177` and level 2 `7777`, a store with both
//!             enables, a (type, map bit) dispatch above 2,047, and a page
//!             fault on `<31:28>`
//!   devices   the feature page's words 0 to 17 at revision 13, and the file
//!             device's rings at 28-bit addresses on 8-word lines
//!   disk      block-disk's packed and 4-byte transfers through the channel,
//!             the memory port and the cache, on a pack the testbench serves
//!
//! **NO PROGRAM TOUCHES MAIN MEMORY.**  Revision 13's memory port, with its
//! 8-word lines, its page reach and its packed storage (G2 §3; muir's
//! `MemoryPort::for_geometry`), is not the fabric's yet, and every cycle to
//! main memory would be timed by a port the fabric does not have.  So the
//! map is read through `MAP(MD)` and a refused read, and the tests of muir's
//! that need main memory --- a translation to a word, and the fused return,
//! whose main loop fetches --- wait for that port.  The register page is
//! reached once, to set ERRSTOP: it is a device on both revisions' ports,
//! at `1777777400` on revision 13, which the fabric's 22-bit cables carry as
//! `17777400`.
//!
//! **NOTHING IS PRESET**, as in `golden/src/quux.rs`: every constant is made
//! by the program from the dispatch constant, and every map entry and
//! dispatch-memory entry is written by the program.  **EACH PROGRAM SAYS
//! WHAT IT REACHED**: the results land in A memory from `200` up, and the
//! generator asserts each against the value muir's test holds, before it
//! writes a trace.

mod machine_axis;
mod trace;

use machine_axis::Which;
use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::{
    ADD, ALU, ALWAYS, AND, BYTE, CARRY_IN, DEP, DISPATCH, DMEM_WRITE, DPB, INVERT, IOR, JUMP, LDB,
    M_PLUS_C, MD, N, OB_RIGHT, Q_LOAD, SETA, SETCM, SETM, SETO, SRC_MD, SRC_Q, START_READ,
    POPJ, START_WRITE, SUB, VMA, XOR, a_dest, a_src, filler, m_dest, m_src, src, target,
};
use muir::machine::{Geometry, Machine, PROM_WORDS, QUUX_PROM_BASE, Word, macro_dispatch};

/// Revision 13.
const REV13: Geometry = Geometry::QUUX_13;

/// A memory's constants: 0, 1 and 2.
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const TWO: u64 = 0o42;
/// M memory's 0 and 1, which [`Prog::taken`] writes its results from with
/// BYTE words, so that no ALU word loads the overflow flag between a test
/// and its jump.
const M_ZERO: u64 = 0o34;
const M_ONE: u64 = 0o35;
/// The A memory word a constant bound for M is made in.
const SCRATCH: u64 = 0o77;
/// The first A memory word a result lands in.
const RESULT: u64 = 0o200;

/// A 40-bit word from its tag `<39:32>` and field `<31:0>`.
const fn w(tag: u64, field: u64) -> Word {
    tag << 32 | (field & 0xffff_ffff)
}
/// All 40 bits.
const ONES: Word = (1 << 40) - 1;

/// A functional destination, with M's address 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}
/// Destination 1, LOCATION-COUNTER; 2, INTERRUPT-CONTROL; 11, the PDL
/// buffer at the pointer after a push; 14, the PDL pointer; 23, `VMA` with
/// the map write a microcycle later.
const LC: u64 = fd(1);
const INTCTL: u64 = fd(2);
const PDL_PUSH: u64 = fd(0o11);
const PDL_POINTER: u64 = fd(0o14);
const WRITE_MAP: u64 = fd(0o23);

/// Functional sources: 0 the dispatch constant, 2 the PDL pointer, 5 the
/// PDL buffer at the pointer, 10 `VMA`, 11 `MAP(MD)`, 13 the location
/// counter, 16 MACHINE-ID, 17 unassigned.
const SRC_DC: u64 = src(0);
const SRC_PDLP: u64 = src(2);
const SRC_PDLTOP: u64 = src(5);
const SRC_VMA: u64 = src(0o10);
const SRC_MAP: u64 = src(0o11);
const SRC_LC: u64 = src(0o13);
const SRC_ID: u64 = src(0o16);
const SRC_17: u64 = src(0o17);

/// A BYTE word: function, rotate `IR<5:0>` and length - 1 `IR<11:6>`
/// (A1.1).
fn byte(func: u64, rotate: u64, len: u64) -> u64 {
    BYTE | func | (len - 1) << 6 | rotate
}
/// `IR<24>` on an LDB: LC byte mode (A1.2).
const LC_MODE: u64 = 1 << 24;
/// `IR<11:10>` = 3 on a JUMP or DISPATCH: LC byte mode.
const MISC_LC: u64 = 3 << 10;
/// A rotate of JUMP or DISPATCH, `{IR<47>, IR<4:0>}` (A1.1).
fn rot6(r: u64) -> u64 {
    (r >> 5) << 47 | (r & 0o37)
}
/// A JUMP that tests bit 0 of M rotated by `r`.
fn jbit(r: u64) -> u64 {
    JUMP | rot6(r)
}
/// A JUMP on condition `code`, `IR<4:0>` with `IR<5>` (A1.3).
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}
/// A DISPATCH: address `IR<23:12>`, length `IR<7:5>`, rotate.
fn disp(addr: u64, len: u64, r: u64) -> u64 {
    DISPATCH | addr << 12 | len << 5 | rot6(r)
}
/// The map bits of a DISPATCH, `IR<9:8>`: 1 takes the level-2 entry's
/// `<22>`, 2 its `<23>` (A1.7).
const MAP_22: u64 = 1 << 8;
const MAP_23: u64 = 2 << 8;

/// `<39:0>` of `v` rotated left by `n` mod 40 (G2 §2.3).
fn ring(v: Word, n: u64) -> Word {
    let n = n % 40;
    if n == 0 { v } else { ((v << n) | (v >> (40 - n))) & ONES }
}

/// A program being assembled into QUUX's PROM, from its first word at
/// `QUUX_PROM_BASE`, and the results it is to leave in A memory.
struct Prog {
    words: Vec<u64>,
    results: Vec<(u64, Word, String)>,
}

impl Prog {
    fn new() -> Self {
        Prog { words: Vec::new(), results: Vec::new() }
    }

    /// The control store address the next word lands at.
    fn at(&self) -> u64 {
        QUUX_PROM_BASE as u64 + self.words.len() as u64
    }

    fn op(&mut self, raw: u64) -> &mut Self {
        self.words.push(raw);
        self
    }

    fn fill(&mut self, n: usize) -> &mut Self {
        for _ in 0..n {
            self.words.push(filler().raw());
        }
        self
    }

    /// `A[a]` = `v`, 40 bits, made from the dispatch constant: ten bits at
    /// a time, each loaded by a dispatch-memory write (which writes entry 0
    /// as it goes) and deposited at its place by a DPB of revision 13's
    /// fields.
    fn a(&mut self, a: u64, v: Word) -> &mut Self {
        for k in 0..4u64 {
            let piece = (v >> (10 * k)) & 0o1777;
            if k > 0 && piece == 0 {
                continue;
            }
            self.op(DISPATCH | DMEM_WRITE | a_src(piece));
            if k == 0 {
                self.op(ALU | SETM | SRC_DC | a_dest(a));
            } else {
                self.op(byte(DPB, 10 * k, 10) | SRC_DC | a_src(a) | a_dest(a));
            }
        }
        self
    }

    /// M `m` = `v`, and the A word it shadows.
    fn m(&mut self, m: u64, v: Word) -> &mut Self {
        self.a(SCRATCH, v);
        self.op(ALU | SETA | a_src(SCRATCH) | m_dest(m))
    }

    /// The next result's A address, which is to hold `want`.
    fn result(&mut self, want: Word, what: &str) -> u64 {
        let a = RESULT + self.results.len() as u64;
        assert!(a < 0o1000, "the results run past A 777");
        self.results.push((a, want, what.to_string()));
        a
    }

    /// A result `want` of the word `raw`, whose destination this adds.
    fn put(&mut self, raw: u64, want: Word, what: &str) -> &mut Self {
        let a = self.result(want, what);
        self.op(raw | a_dest(a))
    }

    /// A result, 1 if the JUMP `jump` is taken and 0 if not: the jump goes
    /// to the word after the next with `N`, which the jump inhibits when
    /// taken and runs when not. The two writes are LDBs of the whole word,
    /// BYTE words, which leave the overflow flag.
    fn taken(&mut self, jump: u64, want: Word, what: &str) -> &mut Self {
        let a = self.result(want, what);
        self.op(byte(LDB, 0, 40) | m_src(M_ONE) | a_dest(a));
        let next = self.at() + 2;
        self.op(jump | target(next) | N);
        self.op(byte(LDB, 0, 40) | m_src(M_ZERO) | a_dest(a))
    }

    /// Dispatch-memory entry `e` = `word`, through A memory `SCRATCH`, in
    /// words of a fixed length, so that an entry whose value is an address
    /// further on can be written before that address is known: the index of
    /// its first word, for [`Prog::patch_dmem`].
    fn dmem(&mut self, e: u64, word: u32) -> usize {
        let at = self.words.len();
        self.words.extend(Self::dmem_words(e, word));
        at
    }

    fn dmem_words(e: u64, word: u32) -> Vec<u64> {
        let mut v = Vec::new();
        for k in 0..4u64 {
            let piece = (word as u64 >> (10 * k)) & 0o1777;
            v.push(DISPATCH | DMEM_WRITE | a_src(piece));
            if k == 0 {
                v.push(ALU | SETM | SRC_DC | a_dest(SCRATCH));
            } else {
                v.push(byte(DPB, 10 * k, 10) | SRC_DC | a_src(SCRATCH) | a_dest(SCRATCH));
            }
        }
        v.push(disp(e, 0, 0) | DMEM_WRITE | a_src(SCRATCH));
        v
    }

    /// The entry [`Prog::dmem`] wrote at `at`, rewritten to `word`.
    fn patch_dmem(&mut self, at: usize, e: u64, word: u32) {
        let v = Self::dmem_words(e, word);
        self.words[at..at + v.len()].copy_from_slice(&v);
    }

    /// A dispatch `raw` whose entry `e` has N and sends the machine to the
    /// word after the next, where a result of 1 marks that it landed.
    fn lands(&mut self, e: u64, raw: u64, what: &str) -> &mut Self {
        self.lands_over(e, &[], raw, what)
    }

    /// [`Prog::lands`], with each of the entries `decoys` written after
    /// `e`'s to send the machine to 0, in the control store nobody wrote: a
    /// dispatch memory that aliased `e` with a decoy would go there.
    fn lands_over(&mut self, e: u64, decoys: &[u64], raw: u64, what: &str) -> &mut Self {
        let entry = self.dmem(e, 0);
        for &d in decoys {
            self.dmem(d, 1 << 14);
        }
        let landing = self.at() + 2;
        self.patch_dmem(entry, e, 1 << 14 | landing as u32);
        self.op(raw);
        self.fill(1);
        let a = self.result(1, what);
        self.op(ALU | SETA | a_src(ONE) | a_dest(a))
    }

    /// A map store: `MD` <- the address `addr`, then the word `word` into
    /// `VMA` with the map write, which lands a microcycle later.
    fn map_store(&mut self, addr: Word, word: Word) -> &mut Self {
        self.a(0o70, addr);
        self.a(0o71, word);
        self.op(ALU | SETA | a_src(0o70) | MD);
        self.op(ALU | SETA | a_src(0o71) | WRITE_MAP);
        self.fill(2)
    }

    /// Stops: a jump to itself, the instruction after it inhibited.
    fn park(&mut self) -> u64 {
        let here = self.at();
        self.op(JUMP | target(here) | ALWAYS | N);
        self.fill(1);
        here
    }

    fn prom(&self) -> Vec<Insn> {
        assert!(self.words.len() <= PROM_WORDS, "the program is {} words and the PROM {PROM_WORDS}", self.words.len());
        self.words.iter().map(|&w| Insn::new(w)).collect()
    }

    /// The constants every program starts from.
    fn start(&mut self) -> &mut Self {
        self.a(ZERO, 0).a(ONE, 1).a(TWO, 2);
        self.m(M_ZERO, 0).m(M_ONE, 1)
    }
}

// ------------------------------------------------------------------ alu

/// **The ALU on tags, the conditions, the sources and the registers.**
fn alu_program() -> Prog {
    let mut p = Prog::new();
    p.start();

    // The ALU on tags (G2 §2.2): a logical function acts on all 40 bits; an
    // arithmetic one on `<31:0>`, the result's `<39:32>` M's; the output
    // bus's right shift on `<31:0>`, M's tag above.
    let x = w(0o245, 0x8000_00f0);
    let y = w(0o012, 0x7fff_ff0f);
    p.m(1, x).a(0o50, y);
    for (f, want, what) in [
        (AND, x & y, "AND on 40 bits"),
        (IOR, x | y, "IOR on 40 bits"),
        (XOR, x ^ y, "XOR on 40 bits"),
        (SETCM, !x & ONES, "SETCM on 40 bits"),
        (SETO, ONES, "SETO on 40 bits"),
        (ADD, w(0o245, 0x8000_00f0 + 0x7fff_ff0f), "ADD keeps M's tag"),
        (SUB, w(0o245, 0x8000_00f0u64.wrapping_sub(0x7fff_ff0f + 1)), "SUB keeps M's tag"),
    ] {
        p.put(ALU | f | m_src(1) | a_src(0o50), want, what);
    }
    p.m(0o20, w(0o377, 0xffff_ffff));
    p.put(ALU | M_PLUS_C | CARRY_IN | m_src(0o20), w(0o377, 0), "M + 1 wraps the field, keeps the tag");
    p.put(OB_RIGHT | ADD | m_src(1) | a_src(0o50), w(0o245, 0xffff_ffff), "the right shift keeps M's tag");

    // A=M sees the tag; M < A and M <= A compare the fields, signed (A1.3).
    p.m(1, w(0o005, 7)).a(0o50, w(0o003, 7)).a(0o51, w(0o005, 7)).a(0o52, w(0o001, 8));
    p.m(2, w(0o377, 0xffff_ffff)).a(0o53, 0);
    p.taken(jcond(3) | m_src(1) | a_src(0o50), 0, "A=M on equal fields, different tags");
    p.taken(jcond(3) | m_src(1) | a_src(0o51), 1, "A=M on the same 40 bits");
    p.taken(jcond(1) | m_src(1) | a_src(0o50), 0, "M<A on equal fields, different tags");
    p.taken(jcond(2) | m_src(1) | a_src(0o50), 1, "M<=A on equal fields, different tags");
    p.taken(jcond(1) | m_src(1) | a_src(0o52), 1, "M<A by field though M's tag is higher");
    p.taken(jcond(1) | m_src(2) | a_src(0o53), 1, "M<A signed: -1 < 0 whatever the tags");
    p.taken(jcond(1) | INVERT | m_src(1) | a_src(0o52), 0, "inverted M<A");

    // The fixnum overflow flag and condition 10 (A1.3). The operands are
    // made first: the constants' own ALU words load the flag.
    p.m(1, w(0o005, 0x7fff_ffff)).m(2, w(0o005, 0x8000_0000)).m(3, w(0o005, 5));
    p.a(0o54, w(0o005, 0x7fff_ffff));
    // The dispatch below lands on entry 5 of its own table, at 7000, which
    // goes to the word after the next with N: written before the flag's
    // tests, its value filled in at the dispatch.
    let entry = p.dmem(0o7005, 0);
    // ADD 2^31 - 1 + 1: overflow.
    p.op(ALU | ADD | m_src(1) | a_src(ONE) | a_dest(0o100));
    p.taken(jcond(0o10), 1, "ADD 2^31 - 1 + 1");
    // AND: clear.
    p.op(ALU | AND | m_src(1) | a_src(ONE) | a_dest(0o100));
    p.taken(jcond(0o10), 0, "AND");
    // SUB -2^31 - 1: overflow.
    p.op(ALU | SUB | CARRY_IN | m_src(2) | a_src(ONE) | a_dest(0o100));
    p.taken(jcond(0o10), 1, "SUB -2^31 - 1");
    // ADD 5 + 1: clear.
    p.op(ALU | ADD | m_src(3) | a_src(ONE) | a_dest(0o100));
    p.taken(jcond(0o10), 0, "ADD 5 + 1");
    // ADD 2^31 - 1 + 1 again, then an inhibited AND: still set.
    p.op(ALU | ADD | m_src(1) | a_src(ONE) | a_dest(0o100));
    let over = p.at() + 2;
    p.op(JUMP | ALWAYS | target(over) | N);
    p.op(ALU | AND | m_src(1) | a_src(ONE) | a_dest(0o100));
    p.taken(jcond(0o10), 1, "an inhibited AND loads nothing");
    // A JUMP and a DISPATCH leave it: a jump on bit 1 of 5, not taken, and a
    // dispatch on 5's low three bits to entry 7005.
    p.op(jbit(39) | m_src(3) | target(0) | N);
    let landing = p.at() + 2;
    p.patch_dmem(entry, 0o7005, 1 << 14 | landing as u32);
    p.op(disp(0o7000, 3, 0) | m_src(3));
    p.fill(1);
    p.taken(jcond(0o10), 1, "a JUMP and a DISPATCH load nothing");
    // The logical functions of 40-bit words never set it.
    p.op(ALU | XOR | m_src(1) | a_src(0o54) | a_dest(0o100));
    p.taken(jcond(0o10), 0, "XOR");
    // Nor do the special functions (40-77): a multiply step with `Q<0>` set
    // adds, 2^31 - 1 + 1 over the field, and clears the flag the ADD before
    // it set.
    p.op(ALU | SETA | a_src(ONE) | Q_LOAD);
    p.op(ALU | ADD | m_src(1) | a_src(ONE) | a_dest(0o100));
    p.op(ALU | 0o40 << 3 | m_src(1) | a_src(ONE) | a_dest(0o100));
    p.taken(jcond(0o10), 0, "a multiply step");

    // Condition 11, M < A unsigned on the fields (A1.3).
    p.m(1, w(0o005, 0)).a(0o50, w(0, 0xffff_ffff)).m(2, w(0o005, 0xffff_ffff));
    p.a(0o51, w(0o377, 0));
    p.taken(jcond(0o11) | m_src(1) | a_src(0o50), 1, "0 <u 37777777777");
    p.taken(jcond(1) | m_src(1) | a_src(0o50), 0, "0 < -1 signed");
    p.taken(jcond(0o11) | m_src(2) | a_src(0o51), 0, "37777777777 <u 0");
    p.taken(jcond(0o11) | INVERT | m_src(2) | a_src(0o51), 1, "37777777777 >=u 0");
    p.taken(jcond(0o11) | m_src(1) | a_src(ZERO), 0, "0 <u 0");
    // A reserved number decodes as its `IR<2:0>`: 17 as 7, always; and 12 as
    // 2, M <= A.
    p.taken(jcond(0o17) | m_src(1) | a_src(ZERO), 1, "condition 17 decodes as 7");
    p.taken(jcond(0o12) | m_src(1) | a_src(ZERO), 1, "condition 12 decodes as 2");
    p.taken(jcond(0o12) | m_src(M_ONE) | a_src(ZERO), 0, "condition 12 decodes as 2: 1 <= 0 is false");

    // Numeric sources read `<39:32>` as 0, an unassigned one all 40 bits as
    // ones, MACHINE-ID says revision 13; a 32-bit constant is zero-extended
    // (G2 §2.5, A1.5, A1.6).
    p.m(1, w(0, 0xffff_ffff)).a(0o50, w(0o005, 0x10)).a(0o51, 0o37777);
    p.op(ALU | SETA | a_src(0o51) | PDL_POINTER);
    p.lands(0, disp(0, 0, 0) | 0o1777 << 32, "a dispatch with the constant 1777");
    p.put(ALU | SETM | SRC_DC, 0o1777, "the dispatch constant");
    p.put(ALU | SETM | SRC_PDLP, 0o37777, "the PDL pointer");
    p.put(ALU | SETM | SRC_ID, (0x5155 << 16) | (13 << 4) | 4, "MACHINE-ID");
    p.put(ALU | SETM | SRC_17, ONES, "source 17");
    p.put(ALU | ADD | m_src(1) | a_src(0o50), 0xf, "-1 zero-extended as M: tag 000");
    p.op(ALU | SETO | m_dest(7));
    p.put(ALU | ADD | m_src(7) | a_src(0o50), w(0o377, 0xf), "SETO's ones as M: tag 377");

    // A word with `<39:32>` set, and `<31>`, through the registers: `Q`,
    // `MD`, `VMA`, the PDL buffer, the A and M pass-arounds, M into A.
    let (w1, w2) = (w(0o245, 0x8000_0001), w(0o303, 0x8765_4321));
    p.a(0o60, w1).a(0o61, w2);
    p.op(ALU | SETA | a_src(0o60) | Q_LOAD);
    p.put(ALU | SETM | SRC_Q, w1, "Q");
    p.op(ALU | SETA | a_src(0o61) | MD);
    p.put(ALU | SETM | SRC_MD, w2, "MD");
    p.op(ALU | SETA | a_src(0o60) | VMA);
    p.put(ALU | SETM | SRC_VMA, w1, "VMA");
    // The push's write lands a microcycle on, and the PDL buffer has no
    // pass-around.
    p.op(ALU | SETA | a_src(0o61) | PDL_PUSH);
    p.fill(1);
    p.put(ALU | SETM | SRC_PDLTOP, w2, "the PDL buffer");
    p.op(ALU | SETA | a_src(0o60) | a_dest(0o62));
    p.put(ALU | SETA | a_src(0o62), w1, "A's pass-around");
    p.op(ALU | SETA | a_src(0o61) | m_dest(4));
    p.put(ALU | SETM | m_src(4), w2, "M's pass-around");
    p.put(ALU | SETM | m_src(4), w2, "M memory");
    p.park();
    p
}

// ------------------------------------------------------------------ byte

/// The word the byte tests take apart: cdr code 2, type 25 (octal), and a
/// field whose bytes are all different.
const T: Word = 2 << 38 | 0o25 << 32 | 0x8765_4321;

/// ERRSTOP, the register page's word 102, through a virtual page of its
/// own: page 1, which level 1's power-on entry 0 puts in block 0, mapped to
/// the register page's physical page, `1777777400 >> 10`.
const REGISTER_VPAGE: u64 = 1;
const REGISTER_PAGE_13: u64 = 0o1777777400;
const ERRSTOP_WORD: u64 = 0o102;

/// **The rotator, the masker, LC byte mode, the misc decode and the bit
/// test.**
fn byte_program() -> Prog {
    let mut p = Prog::new();
    p.start();

    // ERRSTOP, so that a BYTE word decoded as misc 1 would halt the machine.
    let page = REGISTER_PAGE_13 >> 10;
    p.map_store((REGISTER_VPAGE << 10) as Word, (1 << 28 | 1 << 27 | 1 << 26 | page) as Word);
    p.a(0o72, (REGISTER_VPAGE << 10 | (REGISTER_PAGE_13 & 0o1777) | ERRSTOP_WORD) as Word);
    p.op(ALU | SETA | a_src(ONE) | MD);
    p.op(ALU | SETA | a_src(0o72) | START_WRITE);
    p.fill(4);

    // LDB in the ring of 40: the type is rotate 8, length 6; the byte at 8
    // is rotate 32; the ring carries the tag into the field and back.
    let a = w(0o111, 0x1111_1111);
    p.m(1, T).a(0o50, a);
    for (r, len, v, what) in [
        (8, 6, 0o25, "the type, the byte at 32"),
        (2, 2, 2, "the cdr code, the byte at 38"),
        (32, 8, 0x43, "the byte at 8"),
        (35, 8, (0x8765_4321 >> 5) & 0xff, "the byte at 5, rotate 35"),
        (39, 8, (0x8765_4321 >> 1) & 0xff, "the byte at 1, rotate 39"),
        (8, 40, ring(T, 8), "the whole word rotated by 8"),
        (0, 40, T, "length 40 takes every bit"),
        (0o50, 40, T, "rotate 40 is 0"),
        (0o77, 40, ring(T, 23), "rotate 63 is 23"),
        (4, 33, ring(T, 4) & ((1 << 33) - 1), "length 33"),
        (0, 41, a, "length 41 fits nowhere: A"),
    ] {
        let mask: Word = if len > 40 { 0 } else { (1 << len) - 1 };
        let want = if len > 40 { a } else { (v & mask) | (a & !mask & ONES) };
        p.put(byte(LDB, r, len) | m_src(1) | a_src(0o50), want, what);
    }

    // DPB and selective deposit at 40 bits: the mask is rotate to rotate +
    // length - 1 if that fits in 0-39, and none otherwise.
    p.m(1, w(0, 0xa5)).m(0o30, T);
    for (r, len) in [(32, 8), (33, 8), (0o50, 1), (0o77, 1), (38, 2), (0, 40), (1, 40)] {
        let want = if r + len > 40 {
            a
        } else {
            let mask: Word = ((1 << len) - 1) << r;
            (ring(w(0, 0xa5), r) & mask) | (a & !mask)
        };
        p.put(byte(DPB, r, len) | m_src(1) | a_src(0o50), want, "DPB");
    }
    p.put(byte(DEP, 32, 8) | m_src(0o30) | a_src(0o50), (a & !(0xff << 32)) | (T & 0xff << 32), "selective deposit at 32");
    p.put(byte(DEP, 33, 8) | m_src(0o30) | a_src(0o50), a, "selective deposit at 33, length 8: A");

    // LC byte mode by `IR<24>`, on an LDB: rotate 1 for halfword 0 (`LC<1>`
    // = 1) and 25 for halfword 1; a DPB with `IR<24>` ignores LC.
    let word: Word = 2 << 38 | 0o25 << 32 | 0o123456 << 16 | 0o100765;
    let (hw0, hw1): (Word, Word) = (0o100765, 0o123456);
    p.m(1, word).a(0o50, 0).a(0o51, 2).a(0o52, 0);
    p.op(ALU | SETA | a_src(0o51) | LC);
    p.put(byte(LDB, 1, 10) | LC_MODE | m_src(1) | a_src(ZERO), (hw0 & 0o777) << 1 | 1, "halfword 0, bit 39 in <0>");
    p.put(byte(LDB, 1, 10) | m_src(1) | a_src(ZERO), (hw0 & 0o777) << 1 | 1, "no LC byte mode: rotate 1");
    p.put(byte(DPB, 1, 10) | LC_MODE | m_src(1) | a_src(ZERO), (word & 0o1777) << 1, "DPB at rotate 1, halfword 0's LC");
    p.op(ALU | SETA | a_src(0o52) | LC);
    p.put(byte(LDB, 1, 10) | LC_MODE | m_src(1) | a_src(ZERO), (hw1 & 0o777) << 1 | (hw0 >> 15), "halfword 1, bit 15 in <0>");
    p.put(byte(DPB, 1, 10) | LC_MODE | m_src(1) | a_src(ZERO), (word & 0o1777) << 1, "DPB at rotate 1, halfword 1's LC");

    // LC byte mode's bytes: in byte mode LC = 1, 2, 3, 0 take bytes 0, 1, 2,
    // 3. The flag is INTERRUPT-CONTROL's `<37>`, and the location counter
    // reads it back at `<37>` with the counter in `<29:0>` (A1.6).
    const LC_HIGH: Word = 0o1_234_000_000;
    p.m(1, w(0o005, 0x4433_2211)).a(0o50, 1 << 37).a(0o51, 0);
    for (k, lc) in [1u64, 2, 3, 0].into_iter().enumerate() {
        p.a(0o60 + k as u64, LC_HIGH | lc);
    }
    p.op(ALU | SETA | a_src(0o50) | INTCTL);
    for (k, want) in [0x11, 0x22, 0x33, 0x44].into_iter().enumerate() {
        p.op(ALU | SETA | a_src(0o60 + k as u64) | LC);
        p.put(byte(LDB, 0, 8) | LC_MODE | m_src(1) | a_src(ZERO), want, "a byte in stream order");
    }
    p.put(ALU | SETM | SRC_LC, 1 << 39 | 1 << 37 | LC_HIGH, "LC in byte mode");
    p.op(ALU | SETA | a_src(0o51) | INTCTL);
    p.put(ALU | SETM | SRC_LC, 1 << 39 | LC_HIGH, "LC in halfword mode");

    // A BYTE word's `IR<11:10>` are length bits, not misc: lengths 17, 33
    // and 49 run on under ERRSTOP. Output select 0 takes `IR<9:6>` and no
    // LC byte mode.
    p.m(1, T).a(0o50, a);
    p.op(ALU | SETA | a_src(ZERO) | LC);
    let ldb = |r: u64, len: u64| {
        let mask: Word = (1 << len) - 1;
        (ring(T, r) & mask) | (a & !mask)
    };
    p.put(byte(LDB, 0, 17) | m_src(1) | a_src(0o50), ldb(0, 17), "length 17 does not halt");
    p.put(byte(LDB, 4, 33) | m_src(1) | a_src(0o50), ldb(4, 33), "length 33");
    p.put(byte(LDB, 4, 49) | m_src(1) | a_src(0o50), a, "length 49 fits nowhere");
    let mask: Word = 0o17 << 36;
    p.put(36 | 3 << 6 | 3 << 10 | m_src(1) | a_src(0o50), (ring(T, 36) & mask) | (a & !mask), "output select 0, 4 bits at 36");

    // A JUMP's bit test with `IR<47>` as its rotate's bit 5.
    p.m(1, 1 << 5).m(2, 1 << 37);
    p.taken(jbit(35) | m_src(1), 1, "bit 5 of a word with bit 5");
    p.taken(jbit(3) | m_src(1), 0, "bit 37 of a word with bit 5");
    p.taken(jbit(35) | m_src(2), 0, "bit 5 of a word with bit 37");
    p.taken(jbit(3) | m_src(2), 1, "bit 37 of a word with bit 37");
    p.taken(jbit(0o50 + 5) | m_src(2), 0, "rotate 45");
    p.taken(jbit(0o75) | m_src(1), 0, "rotate 61");

    // LC byte mode on a JUMP: 24 more for halfword 1.
    p.m(1, 1 << 19).a(0o50, 2).a(0o51, 0);
    p.op(ALU | SETA | a_src(0o50) | LC);
    p.taken(jbit(37) | MISC_LC | m_src(1), 0, "halfword 0's bit 3");
    p.op(ALU | SETA | a_src(0o51) | LC);
    p.taken(jbit(37) | MISC_LC | m_src(1), 1, "halfword 1's bit 3");
    p.park();
    p
}

// -------------------------------------------------------------- dispatch

/// **The dispatch memory at 4,096 entries.**
fn dispatch_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    // On the type, the byte at 32, rotate 8, length 6, into 4025.
    p.m(1, T);
    // 0025, written after it, is 4025 without `IR<23>`.
    p.lands_over(0o4025, &[0o0025], disp(0o4000, 6, 8) | m_src(1), "the type's entry at 4025");
    // The last entry, 7777, from the address alone.
    p.lands(0o7777, disp(0o7777, 0, 0), "entry 7777");
    // The byte at 5, rotate 35, `IR<47>` set; rotate 3 would take 37-39.
    p.m(1, 2 << 38 | 5 << 5);
    p.lands(0o6005, disp(0o6000, 3, 35) | m_src(1), "the byte at 5's entry at 6005");
    // The cdr code, the byte at 38, rotate 2, length 2, at 7774.
    p.m(1, T);
    p.lands(0o7776, disp(0o7774, 2, 2) | m_src(1), "the cdr code's entry at 7776");
    // LC byte mode on both halfwords: the field at `<13:9>`, rotate 31 for
    // halfword 0 and 55 for halfword 1.
    p.m(1, w(0, 0o21 << 25 | 0o13 << 9)).a(0o50, 2).a(0o51, 0);
    p.op(ALU | SETA | a_src(0o50) | LC);
    p.lands(0o5013, disp(0o5000, 5, 31) | MISC_LC | m_src(1), "LC 2: opcode 13");
    p.op(ALU | SETA | a_src(0o51) | LC);
    p.lands(0o5021, disp(0o5000, 5, 31) | MISC_LC | m_src(1), "LC 0: opcode 21");
    // A write at 7777 of P and R, then a dispatch there, which falls
    // through to the next word.
    p.a(0o52, 1 << 16 | 1 << 15);
    p.op(disp(0o7777, 0, 0) | DMEM_WRITE | a_src(0o52));
    p.fill(1);
    p.op(disp(0o7777, 0, 0));
    p.put(ALU | SETA | a_src(ONE), 1, "the fall-through ran the next word");
    p.park();
    p
}

// ------------------------------------------------------------------- map

/// A 28-bit virtual address whose every level-1 and level-2 bit matters:
/// `VA<27:15>` 12345, `VA<14:10>` 26, `VA<9:0>` 1234; block 123, page 1357.
const VA: u64 = 0o12345 << 15 | 0o26 << 10 | 0o1234;
const BLOCK: u64 = 0o123;
const PAGE_ENTRY: u64 = 1 << 27 | 1 << 26 | 0o1357;

/// **The map through `MAP(MD)`.**  `MAP(MD)<31:30>` are the fault bits of
/// the last memory cycle's latched entry; the results take all 40 bits, as
/// the trace does.
fn map_program() -> (Prog, Vec<(u64, Word, Word)>) {
    let mut p = Prog::new();
    // Each `MAP(MD)` result's want, less its fault bits, which the generator
    // takes from muir: (A address, address, want).
    let mut maps = Vec::new();
    p.start();
    let mut map_md = |p: &mut Prog, addr: Word, want: Word, what: &str| {
        p.a(0o73, addr);
        p.op(ALU | SETA | a_src(0o73) | MD);
        p.fill(1);
        let a = p.result(want, what);
        maps.push((a, addr, want));
        p.op(ALU | SETM | SRC_MAP | a_dest(a));
    };

    // Level 1 at `VA<27:15>` <- block 123; level 2 at {123, `VA<14:10>`}.
    p.map_store(VA as Word, (BLOCK << 32 | 1 << 29) as Word);
    p.map_store(VA as Word, (1 << 28 | PAGE_ENTRY) as Word);
    // Level 1 at `VA<26:15>`, `VA<27>` clear, another block: an index that
    // lost `VA<27>` would find it.
    p.map_store((VA & !(1 << 27)) as Word, 0o55 << 32 | 1 << 29);
    map_md(&mut p, VA as Word, BLOCK << 32 | PAGE_ENTRY, "MAP(MD) of VA");
    map_md(&mut p, w(0o245, VA), BLOCK << 32 | PAGE_ENTRY, "MAP(MD) of VA with <39:32> set");
    map_md(&mut p, (VA & !0o1400) as Word, BLOCK << 32 | PAGE_ENTRY, "MAP(MD) of VA with <9:8> clear");
    map_md(&mut p, (1 << 28 | VA) as Word, 0o177 << 32, "MAP(MD) of VA with <28> set: block 177");
    map_md(&mut p, (0o7 << 29 | VA) as Word, 0o177 << 32, "MAP(MD) of VA with <31:29> set: block 177");

    // The round trip at level 1 177 and level 2 7777 (A1.7): `MD<27:15>`
    // 7777, `MD<14:10>` 37.
    let addr: Word = 0o7777 << 15 | 0o37 << 10;
    let l2: Word = 1 << 27 | 1 << 26 | 0o7654321;
    p.map_store(addr, 0o177 << 32 | 1 << 29);
    p.map_store(addr, 1 << 28 | l2);
    map_md(&mut p, addr, 0o177 << 32 | l2, "MAP(MD) after the writes");
    // An address with <31:28> set: MAP(MD) reads block 177, and a write
    // there, both enables and level 2 alone, writes nothing.
    map_md(&mut p, addr | 1 << 28, 0o177 << 32 | l2, "MAP(MD) of <31:28> set: block 177");
    p.map_store(addr | 1 << 28, 0o55 << 32 | 1 << 29 | 1 << 28 | 0o1111);
    p.map_store(addr | 1 << 30, 1 << 28 | 0o4444);
    map_md(&mut p, addr, 0o177 << 32 | l2, "level 1 at 7777 and level 2 at {177, 37} kept");
    // Both enables at 1234 << 15: level 1 only, and nothing at block 22 or 0.
    p.map_store(0o1234 << 15, 0o22 << 32 | 1 << 29 | 1 << 28 | 0o3333);
    map_md(&mut p, 0o1234 << 15, 0o22 << 32, "both enables: level 1, and not level 2");
    map_md(&mut p, 0, 0, "and not level 2 at block 0");

    // A (type, map bit) dispatch above 2,047 (G2 §2.4, A1.7): `MD` a type-25
    // pointer to word 3 of virtual page 5, whose level-2 entry, block 0's
    // fifth, has `<23>` set and `<22>` clear. The field is the type and the
    // bit below it, the byte at 31, rotate 9, length 7, with the map bit in
    // place of its bit 0.
    p.map_store(5 << 10, (1 << 28 | 1 << 27 | 1 << 23 | 7) as Word);
    p.a(0o74, w(0o25, 5 << 10 | 3));
    p.op(ALU | SETA | a_src(0o74) | MD);
    p.fill(1);
    p.lands(0o7400 + (0o25 << 1 | 1), disp(0o7400, 7, 9) | MAP_23 | SRC_MD, "(type, <23>) at 7453");
    p.op(ALU | SETA | a_src(0o74) | MD);
    p.fill(1);
    p.lands(0o7400 + (0o25 << 1), disp(0o7400, 7, 9) | MAP_22 | SRC_MD, "(type, <22>) at 7452");

    // `<31:28>` set on a read: refused, and condition 4, page fault, holds;
    // no memory cycle goes out.
    p.a(0o75, (1 << 28 | VA) as Word);
    p.op(ALU | SETA | a_src(0o75) | START_READ);
    p.taken(jcond(4), 1, "<31:28> set: a page fault");
    // The access bits are the entry's `<27:26>` (A1.7): a read of a page
    // whose `<27>` is clear and `<23>`, revision 12's read bit, set is
    // refused, and so is a write of one whose `<26>` is clear and `<22>` set.
    // Neither sends a cycle to memory; a machine that took the old bits
    // would.
    p.map_store(6 << 10, (1 << 28 | 1 << 26 | 1 << 23 | 0o11) as Word);
    p.map_store(7 << 10, (1 << 28 | 1 << 27 | 1 << 22 | 0o12) as Word);
    p.a(0o76, 6 << 10);
    p.op(ALU | SETA | a_src(0o76) | START_READ);
    p.taken(jcond(4), 1, "a read of a page without <27>: a page fault");
    p.a(0o76, 7 << 10);
    p.op(ALU | SETA | a_src(0o76) | START_WRITE);
    p.taken(jcond(4), 1, "a write of a page without <26>: a page fault");
    p.park();
    (p, maps)
}

// ---------------------------------------------------------------- memory
//
// Revision 13's memory port and cache (contract G2 §3), through the whole
// machine: packed storage, the window and the 28-bit space.  These run with
// main memory 65 boards, `20200000` words, so that it reaches past 22 bits
// and over revision 12's frame buffer and register page.

/// Main memory's boards for the memory programs, and its end.
const BOARDS_13: u32 = 65;
const MAIN_END: u64 = (BOARDS_13 as u64) << 16;
/// The physical space (G1 §3.2): the register page, the window, revision
/// 12's register page and a word its decode took for the diagnostic
/// registers, main memory past 22 bits.
const WINDOW_13: u64 = 0o1760000000;
const OLD_REGISTER_PAGE: u64 = 0o17777400;
const SPY_13: u64 = 0o17773000;
const HIGH_13: u64 = 0o20000000;
/// The window's buffer, the video controller's 40,960 words.
const FB_WORDS_13: u64 = 40960;

/// M memory the memory programs keep a rolling word and an address in.
const M_W: u64 = 0o10;
const M_VA: u64 = 0o11;
/// A memory: the rolling word's step, and the programs' own words.
const A_STEP: u64 = 0o102;

impl Prog {
    /// The virtual address through virtual page `vpage`, below 32 and so
    /// in level-1 block 0, onto physical `phys`: a level-2 entry, readable
    /// and writable, with the page `phys<27:10>` (A1.7).
    fn through(&mut self, vpage: u64, phys: u64) -> u64 {
        self.map_store((vpage << 10) as Word, (1 << 28 | 1 << 27 | 1 << 26 | phys >> 10) as Word);
        vpage << 10 | (phys & 0o1777)
    }

    /// A result: the word read at the virtual address in A `a`, taken from
    /// `MD` two microcycles after the start, which waits for it: in the
    /// microcycle after the start the cycle has not gone out, and `MD` is
    /// the last one's.
    fn read_a(&mut self, a: u64, want: Word, what: &str) -> &mut Self {
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.fill(1);
        self.put(ALU | SETM | SRC_MD, want, what)
    }

    /// The word in A `word` stored at the virtual address in A `addr`.  The
    /// cycle takes `MD` as the edge after the start leaves it, so the two
    /// words after the start leave `MD` alone.
    fn write_a(&mut self, word: u64, addr: u64) -> &mut Self {
        self.op(ALU | SETA | a_src(word) | MD);
        self.op(ALU | SETA | a_src(addr) | START_WRITE);
        self.fill(2)
    }

    /// `n` words stored from the virtual address `va` up: the rolling word
    /// in M `M_W`, from `first`, stepped after each store by a rotate of 8
    /// in the ring of 40 and an XOR with `step` (A `A_STEP`); the address
    /// in M `M_VA`.  The words, in order.
    fn store_run(&mut self, va: u64, first: Word, step: Word, n: usize) -> Vec<Word> {
        self.m(M_W, first).m(M_VA, va as Word).a(A_STEP, step);
        let mut w = first;
        let mut out = Vec::new();
        for _ in 0..n {
            out.push(w);
            self.op(ALU | SETM | m_src(M_W) | MD);
            self.op(ALU | SETM | m_src(M_VA) | START_WRITE);
            self.op(byte(LDB, 8, 40) | m_src(M_W) | a_src(ZERO) | m_dest(M_W));
            self.op(ALU | XOR | m_src(M_W) | a_src(A_STEP) | m_dest(M_W));
            self.op(ALU | ADD | m_src(M_VA) | a_src(ONE) | m_dest(M_VA));
            w = ring(w, 8) ^ step;
        }
        out
    }

    /// The words `want` read back from the virtual address `va` up, in the
    /// order `order` of their offsets, each a result.
    fn read_run(&mut self, va: u64, want: &[Word], order: &[usize], what: &str) -> &mut Self {
        for &k in order {
            self.m(M_VA, (va + k as u64) as Word);
            self.op(ALU | SETM | m_src(M_VA) | START_READ);
            self.fill(1);
            self.put(ALU | SETM | SRC_MD, want[k], &format!("{what}, word {k}"));
        }
        self
    }
}

/// **The 28-bit space** (G1 §3.2, G2 §4.1; muir's
/// `the_physical_space_is_28_bits`, `the_frame_buffer_window_holds_the_field`,
/// `revision_12s_addresses_are_nothing_on_revision_13`): the register page
/// at `1777777400`, its MACHINE-ID and its word 101; revision 12's page, `17777400`,
/// and `17773000`, main memory here; main memory past 22 bits whole, and
/// nothing past its end, which sets word 101's NXM bit, a write of 101
/// clearing it; the window at `1760000000`, which stores the field and reads
/// it with tag `005`, and nothing past its buffer; and nothing between main
/// memory and the window, or between the window and the page.
fn space_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    let reg = p.through(1, REGISTER_PAGE_13);
    let old = p.through(2, OLD_REGISTER_PAGE);
    let window = p.through(3, WINDOW_13);
    let high = p.through(4, HIGH_13);
    let past = p.through(5, MAIN_END);
    let spy = p.through(6, SPY_13);
    let window_2 = p.through(7, WINDOW_13 + 0o2000);
    let past_window = p.through(8, WINDOW_13 + FB_WORDS_13);
    let gap = p.through(9, 0o400000000);
    let below_page = p.through(10, 0o1777776000);

    // The register page at its revision 13 address: MACHINE-ID, word 0.
    // What its other words say of revision 13 is the devices' (A1.10); here
    // the page answers where the space puts it.
    p.a(0o103, reg as Word);
    p.read_a(0o103, (0x5155 << 16) | (13 << 4) | 4, "word 0, MACHINE-ID");
    // Revision 12's page: main memory, a whole word, and word 101 has no NXM.
    let r101 = 0o104;
    p.a(r101, (reg + 0o101) as Word);
    p.a(0o105, old as Word).a(0o106, w(0o031, 0o400));
    p.write_a(0o106, 0o105).read_a(0o105, w(0o031, 0o400), "17777400: main memory");
    p.read_a(r101, 0, "word 101: no NXM");
    // Main memory past 22 bits, a whole word; past its end nothing.
    p.a(0o107, (high + 5) as Word).a(0o110, w(0o025, 0x1357_9bdf)).a(0o111, past as Word);
    p.write_a(0o110, 0o107).read_a(0o107, w(0o025, 0x1357_9bdf), "main memory at 20000005");
    p.read_a(0o111, 0, "past main memory: nothing");
    p.read_a(r101, 1, "word 101: NXM");
    // A write of word 101 clears it.
    p.write_a(ZERO, r101).read_a(r101, 0, "word 101 cleared by its write");
    // The old Unibus window's diagnostic registers are main memory here.
    p.a(0o112, (spy + 5) as Word).a(0o113, w(0o031, 0xab_cdef));
    p.write_a(0o113, 0o112).read_a(0o112, w(0o031, 0xab_cdef), "main memory at 17773005");
    // The window: a write stores the field and drops the tag, a read gives
    // the field with tag 005; its word 1777, and the page after it.
    p.a(0o114, (window + 7) as Word).a(0o115, w(0o025, 0x1234_5678)).a(0o116, (window + 0o1777) as Word);
    p.a(0o117, (window_2 + 3) as Word);
    p.write_a(0o115, 0o114).read_a(0o114, w(0o005, 0x1234_5678), "the window: the field, tag 005");
    p.write_a(0o115, 0o116).read_a(0o116, w(0o005, 0x1234_5678), "the window's word 1777");
    p.write_a(0o115, 0o117).read_a(0o117, w(0o005, 0x1234_5678), "the window's second page");
    // Read again, each from the line the cache now holds (G2 §3: the window
    // and main memory past 22 bits are cached).
    p.read_a(0o114, w(0o005, 0x1234_5678), "the window's word 7 again, a hit");
    p.read_a(0o107, w(0o025, 0x1357_9bdf), "main memory at 20000005 again, a hit");
    // Nothing past the window's buffer, between main memory and the window,
    // and between the window and the register page; each sets the NXM bit,
    // cleared between.
    for (va, what) in [
        (past_window, "past the window's buffer"),
        (gap, "between main memory and the window"),
        (below_page, "between the window and the register page"),
    ] {
        p.a(0o120, va as Word);
        p.read_a(0o120, 0, what);
        p.read_a(r101, 1, &format!("{what}: NXM"));
        p.write_a(ZERO, r101);
    }
    p.park();
    p
}

// --------------------------------------------------------------- devices

/// The file device's rings in [`devices_program`]: above 22 bits, each on an
/// 8-word line, and a command ring's base off one by four words.
const FD_CMD_13: u64 = 0o20100000;
const FD_RESP_13: u64 = 0o20100100;

/// **The register page's devices at revision 13** (contract G2 §4.1-§4.3,
/// appendix A1.10; muir's `revision_12s_addresses_are_nothing_on_revision_13`
/// and `the_file_device_takes_28_bit_addresses_and_writes_fixnums`): the
/// feature page's words 0 to 17 as muir's revision 13 reads them ---
/// MACHINE-ID 13, the level-1 entry's 7 bits, 4,096 level-2 and dispatch
/// memory entries, the frame buffer window at `1760000000` --- each read
/// through the map; and the file device's rings at 28-bit addresses: a
/// command ring on a 4-word line refused, on an 8-word line taken, the bases
/// read back at 28 bits whatever `<31:28>` was written and `<27:24>` kept,
/// and a ring past main memory's end refused and one to its last word
/// taken.  The words the
/// device writes are its server's, on the board Linux's, and are not here.
fn devices_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    let reg = p.through(1, REGISTER_PAGE_13);
    // muir's own answers, from a revision-13 machine of the same size.
    let mut m = machine(&[], BOARDS_13);
    for k in 0..0o20u64 {
        let want = m.bus_read((REGISTER_PAGE_13 + k) as u32);
        p.a(0o103, (reg + k) as Word);
        p.read_a(0o103, want, &format!("feature word {k:o}"));
    }
    assert_eq!(m.bus_read(REGISTER_PAGE_13 as u32), (0x5155 << 16) | (13 << 4) | 4, "MACHINE-ID 13");
    assert_eq!(m.bus_read((REGISTER_PAGE_13 + 0o13) as u32), 0o1760000000, "word 13: the window");

    // The file device, disabled, its registers written and read as muir's
    // device takes them.
    let r = |k: u64| (reg + k) as Word;
    let (control, status, cmd_base, cmd_size, resp_base, resp_size) = (0o160, 0o161, 0o162, 0o163, 0o166, 0o167);
    let wr = |p: &mut Prog, m: &mut Machine, k: u64, v: Word| {
        p.a(0o104, r(k)).a(0o105, v);
        p.write_a(0o105, 0o104);
        m.bus_write((REGISTER_PAGE_13 + k) as u32, v);
    };
    let rd = |p: &mut Prog, m: &mut Machine, k: u64, what: &str| {
        let want = m.bus_read((REGISTER_PAGE_13 + k) as u32);
        p.a(0o106, r(k));
        p.read_a(0o106, want, what);
        want
    };
    // A base keeps `<27:0>` of what is written, past main memory or not.
    wr(&mut p, &mut m, cmd_base, 0xff40_8000);
    let b = rd(&mut p, &mut m, cmd_base, "162: 28 bits of what was written");
    assert_eq!(b, 0x0f40_8000, "a base keeps 28 bits");
    // A command ring on a 4-word line: refused.
    wr(&mut p, &mut m, cmd_base, (FD_CMD_13 + 4) as Word);
    wr(&mut p, &mut m, cmd_size, 1);
    wr(&mut p, &mut m, resp_base, FD_RESP_13 as Word);
    wr(&mut p, &mut m, resp_size, 0);
    wr(&mut p, &mut m, control, 1);
    let st = rd(&mut p, &mut m, status, "161: a ring off an 8-word line refused");
    assert_eq!(st & 0b101, 0b100, "a ring on a 4-word line is refused");
    rd(&mut p, &mut m, control, "160: not enabled");
    // On an 8-word line, written with `<31:28>` set: taken, 28 bits.
    wr(&mut p, &mut m, cmd_base, (0xf000_0000 | FD_CMD_13) as Word);
    wr(&mut p, &mut m, control, 0x101);
    let st = rd(&mut p, &mut m, status, "161: enabled");
    assert_eq!(st & 0b101, 1, "enabled");
    let b = rd(&mut p, &mut m, cmd_base, "162: the command ring's base, 28 bits");
    assert_eq!(b, FD_CMD_13, "the base reads back, 28 bits");
    rd(&mut p, &mut m, resp_base, "166: the response ring's base");
    rd(&mut p, &mut m, control, "160: enabled, the interrupt enable");
    // Disabled; a response ring running a word past main memory's end,
    // refused; ending at its last word, taken.
    wr(&mut p, &mut m, control, 0);
    wr(&mut p, &mut m, resp_size, 1);
    wr(&mut p, &mut m, resp_base, (MAIN_END - 8) as Word);
    wr(&mut p, &mut m, control, 1);
    let st = rd(&mut p, &mut m, status, "161: a ring past main memory's end refused");
    assert_eq!(st & 0b101, 0b100, "a ring past main memory is refused");
    wr(&mut p, &mut m, resp_base, (MAIN_END - 16) as Word);
    wr(&mut p, &mut m, control, 1);
    let st = rd(&mut p, &mut m, status, "161: a ring to main memory's last word taken");
    assert_eq!(st & 0b101, 1, "a ring to main memory's end is taken");
    rd(&mut p, &mut m, resp_base, "166: the response ring's base, at main memory's end");
    rd(&mut p, &mut m, cmd_base, "162: the command ring's base, kept");
    p.park();
    p
}

// ------------------------------------------------------------------ disk

/// The pack of [`disk_program`]: 64 blocks, blocks 20 to 23 holding
/// `disk_pack_word`, the rest zero.
const DISK_BLOCKS: u32 = 64;
const DISK_PRELOADED: std::ops::Range<u32> = 20..24;
/// Its pages: A and B above 22 bits, C below, D above; and the command
/// list's page.
const DISK_A: u64 = 0o20002000;
const DISK_B: u64 = 0o20004000;
const DISK_C: u64 = 0o6000;
const DISK_D: u64 = 0o20006000;
const DISK_LIST: u64 = 0o20010000;

/// A preloaded block's words, as `tb/cadr_machine_tb.cpp` writes them too.
fn disk_pack_word(lba: u32, w: u32) -> u32 {
    (lba << 12) ^ (w << 1) ^ 0x5a00_0001 ^ lba.rotate_left(23)
}

/// The pack [`disk_program`] runs on, on block-disk's unit 0.
fn disk_pack(m: &mut Machine) {
    let mut d = muir::disk_image::Disk::blank(DISK_BLOCKS);
    for lba in DISK_PRELOADED {
        let b: [u32; 256] = std::array::from_fn(|w| disk_pack_word(lba, w as u32));
        assert!(d.write_block(lba, &b));
    }
    m.block_disk.as_mut().expect("QUUX's block-disk").attach(d);
}

/// **Block-disk's two transfers on the whole machine** (contract G2 §3 and
/// §4.2, appendix A1.11; muir's `the_packed_transfer_moves_a_page_as_5_blocks`
/// and `the_4_byte_transfer_moves_a_page_as_4_blocks`): the channel's words
/// through the memory path and the port into packed storage and out of it,
/// the cache coherent with them, and the processor reading the pages after.
///
///   1. page A's words 200-217, across its first two blocks, written, and
///      page A written to blocks 10-14 by the packed transfer;
///   2. page B's same words written and one of them read, so that its line
///      is in the cache, and blocks 10-14 read into page B by the packed
///      transfer: B's words 200-217 are A's, the cached line dropped;
///   3. blocks 20-23 read into page C by the 4-byte transfer, each word
///      the block's word with tag `005`;
///   4. page A written to blocks 30-33 by the 4-byte transfer, and blocks
///      30-34 read into page D by the packed transfer: D's words 160-171
///      are A's words 200-214 taken 4 bytes a word, 5 bytes to a word, the
///      tags dropped.
///
/// Each transfer is started through the register page and polled to
/// not-active, muir's instant, which the fabric's walk reaches before; its
/// status, word 201 and disk address are read after.
fn disk_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    let reg = p.through(1, REGISTER_PAGE_13);
    let va_a = p.through(2, DISK_A);
    let va_b = p.through(3, DISK_B);
    let va_c = p.through(4, DISK_C);
    let va_d = p.through(5, DISK_D);
    let va_l = p.through(6, DISK_LIST);
    // The registers' virtual addresses.
    let (a_cmd, a_clp, a_da, a_start) = (0o110u64, 0o111u64, 0o112u64, 0o113u64);
    p.a(a_cmd, (reg + 0o200) as Word).a(a_clp, (reg + 0o201) as Word);
    p.a(a_da, (reg + 0o202) as Word).a(a_start, (reg + 0o203) as Word);
    // The list: A, B, C, A, D, each alone.
    let list = [DISK_A, DISK_B, DISK_C, DISK_A, DISK_D];
    for (k, &page) in list.iter().enumerate() {
        p.a(0o114, (va_l + k as u64) as Word).a(0o115, page as Word);
        p.write_a(0o115, 0o114);
    }
    // A transfer: CLP the list's entry `k`, DA, the command, START; then
    // polled until not-active, and its registers read.
    let transfer = |p: &mut Prog, k: u64, da: u64, cmd: u64, last: u64, what: &str| {
        p.a(0o116, (DISK_LIST + k) as Word).write_a(0o116, a_clp);
        p.a(0o116, da as Word).write_a(0o116, a_da);
        p.a(0o116, cmd as Word).write_a(0o116, a_cmd);
        p.write_a(ZERO, a_start);
        let top = p.at();
        p.op(ALU | SETA | a_src(a_cmd) | START_READ);
        p.fill(1);
        p.op(jbit(0) | SRC_MD | INVERT | target(top) | N);
        p.fill(1);
        p.read_a(a_cmd, 1, &format!("{what}: not active, no error"));
        p.read_a(a_clp, (last + 1023) as Word, &format!("{what}: word 201 at the page's last word"));
    };
    const WRITE: u64 = 0o11;
    const FOUR: u64 = 1 << 12;

    // 1. Page A's words 200-217, and page A to blocks 10-14.
    let a_words = p.store_run(va_a + 200, w(0o211, 0x1b2c_3d4e), w(0o133, 0x6b5a_4938), 18);
    transfer(&mut p, 0, 10, WRITE, DISK_A, "the packed write of page A");
    p.read_a(a_da, 14, "the packed write: the disk address at block 14");
    // 2. B's same words, one read into the cache; blocks 10-14 into B.
    let b_bait = p.store_run(va_b + 200, w(0o057, 0x9a8b_7c6d), w(0o315, 0x2468_ace1), 18);
    p.a(0o117, (va_b + 200) as Word).read_a(0o117, b_bait[0], "page B's word 200, cached");
    transfer(&mut p, 1, 10, 0, DISK_B, "the packed read into page B");
    p.read_run(va_b + 200, &a_words, &(0..18).collect::<Vec<_>>(), "page B, A's words");
    // 3. Blocks 20-23 into C, 4 bytes a word.
    transfer(&mut p, 2, 20, FOUR, DISK_C, "the 4-byte read into page C");
    for wd in [0u64, 1, 255, 256, 511, 767, 1023] {
        let want = w(0o005, disk_pack_word(20 + (wd / 256) as u32, (wd % 256) as u32).into());
        p.a(0o117, (va_c + wd) as Word).read_a(0o117, want, &format!("page C's word {wd}, tag 005"));
    }
    // 4. Page A to blocks 30-33, 4 bytes a word; blocks 30-34 into D,
    //    packed.  D's words 160-171 were written first, one of them read.
    transfer(&mut p, 3, 30, WRITE | FOUR, DISK_A, "the 4-byte write of page A");
    let d_bait = p.store_run(va_d + 160, w(0o377, 0x5a69_7887), w(0o142, 0xf1e2_d3c4), 12);
    p.a(0o117, (va_d + 160) as Word).read_a(0o117, d_bait[0], "page D's word 160, cached");
    transfer(&mut p, 4, 30, 0, DISK_D, "the packed read into page D");
    let four: Vec<u8> = a_words.iter().flat_map(|&x| (x as u32).to_le_bytes()).collect();
    let d_words: Vec<Word> = (0..12)
        .map(|j| (0..5).fold(0, |x, b| x | Word::from(four[5 * j + b]) << (8 * b)))
        .collect();
    p.read_run(va_d + 160, &d_words, &(0..12).collect::<Vec<_>>(), "page D, A's fields packed");
    p.park();
    p
}

/// The first rolling words and steps of [`lines_program`]: every byte of
/// each word different, the tag included.
const LINE_FIRST: [Word; 5] = [
    w(0o211, 0x1b2c_3d4e),
    w(0o057, 0x9a8b_7c6d),
    w(0o315, 0x2468_ace1),
    w(0o142, 0xf1e2_d3c4),
    w(0o377, 0x5a69_7887),
];
const LINE_STEP: Word = w(0o133, 0x6b5a_4938);

/// **Packed storage through the cache** (G1 §4.1, G2 §3; muir's
/// `a_store_to_a_word_spanning_two_beats_is_whole`,
/// `a_40_bit_checkpoint_is_packed_and_round_trips`'s lines,
/// `on_rtl_high_memory_and_the_window_are_cached`, and
/// `revision_13s_port_has_8_word_lines_and_page_reach`'s fills): whole
/// 40-bit words stored at every offset of a line --- 1, 3, 4 and 6 each
/// across two of its five beats --- in line 0; in line 307, whose 40 bytes
/// cross a 4 KiB boundary (`40L mod 4096` = 4088); at word 819, whose five
/// bytes do; in a line past 22 bits; and in a line of the window, 4 bytes a
/// word.  Each read back, a line's first read filling its 8 words and the
/// rest hitting; a word written into a line the cache holds, read back from
/// it, then the line evicted by two others of its set and read back from
/// main memory.
fn lines_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    let low = p.through(2, 0);
    let l307 = p.through(3, 307 * 8 & !0o1777) + (307 * 8 & 0o1777);
    let high = p.through(4, HIGH_13 + 0o1230);
    let window = p.through(5, WINDOW_13 + 0o1000);
    let set0_a = p.through(6, 0o4000);
    let set0_b = p.through(7, 0o10000);

    let line0 = p.store_run(low, LINE_FIRST[0], LINE_STEP, 8);
    // A word in each of two other lines of line 0's set, 2K and 4K words on.
    let other_a = p.store_run(set0_a, w(0o066, 0x7777_1111), LINE_STEP, 1);
    let other_b = p.store_run(set0_b, w(0o077, 0x8888_2222), LINE_STEP, 1);
    let line307 = p.store_run(l307, LINE_FIRST[1], LINE_STEP, 8);
    let w819 = p.store_run(low + 819, LINE_FIRST[2], LINE_STEP, 1);
    let high_line = p.store_run(high, LINE_FIRST[3], LINE_STEP, 8);
    let window_line = p.store_run(window, LINE_FIRST[4], LINE_STEP, 8);

    p.read_run(low, &line0, &[0, 1, 2, 3, 4, 5, 6, 7], "line 0");
    p.read_run(l307, &line307, &[7, 0, 6, 1, 5, 2, 4, 3], "line 307, across 4 KiB");
    p.read_run(low + 819, &w819, &[0], "word 819, across 4 KiB");
    p.read_run(high, &high_line, &[3, 0, 1, 2, 4, 5, 6, 7], "a line past 22 bits");
    let fields: Vec<Word> = window_line.iter().map(|&x| w(0o005, x)).collect();
    p.read_run(window, &fields, &[5, 0, 1, 2, 3, 4, 6, 7], "the window's line, the fields with tag 005");

    // Word 3 of line 0 written while the line is held, read back from the
    // line; then two other lines of set 0 read, and word 3 read again from
    // main memory.
    let new3 = w(0o044, 0x3141_5926);
    p.a(0o103, new3).a(0o104, (low + 3) as Word);
    p.write_a(0o103, 0o104).read_a(0o104, new3, "line 0's word 3 written through the held line");
    p.a(0o105, set0_a as Word).a(0o106, set0_b as Word);
    p.read_a(0o105, other_a[0], "set 0's second line");
    p.read_a(0o106, other_b[0], "set 0's third line, which evicts line 0");
    p.read_a(0o104, new3, "line 0's word 3 again, from main memory");
    p.park();
    p
}

// ----------------------------------------------------------------- fused

/// A 28-bit virtual address whose every level-1 and level-2 bit matters, as
/// [`VA`] is, with its word the last of its line: `VA<27:15>` 12345,
/// `VA<14:10>` 26, `VA<9:0>` 1227.  Its page is physical 10000, at
/// `20000000`, past 22 bits.
const VA_F: u64 = 0o12345 << 15 | 0o26 << 10 | 0o1227;
const PAGE_F: u64 = HIGH_13 >> 10;
/// The fused return's main loop, handlers and `A-LOCALP`, as muir's
/// `the_fused_return_takes_the_halfword_in_the_ring_of_40` has them, in the
/// PROM: offsets from its base.
const QMLP_F: u64 = 0o1500;
const HANDLER_F: u64 = 0o1600;
const HANDLER_NEXT: u64 = 0o1700;
const LOCALP_AT_F: u64 = 0o732;
const LOCALP_F: u64 = 0o1000;

/// A halfword: `<13:9>` the opcode, `<8:6>` the register, `<5:0>` delta.
const fn half(op: u64, reg: u64, delta: u64) -> u64 {
    op << 9 | reg << 6 | delta
}

/// **Translation to a word, and the fused return through main memory** (G2
/// §2.6-§2.7, §3, A1.2, A1.7; muir's
/// `the_map_translates_28_bits_at_1024_word_pages` and
/// `the_fused_return_takes_the_halfword_in_the_ring_of_40`, with the
/// prefetch's page reach, `Reach::Page`): the map written for a 28-bit
/// virtual address, level 1 at `VA<27:15>` and level 2 at `{L1, VA<14:10>}`,
/// onto a page past 22 bits; a read through it, with `<39:32>` set, and with
/// `<9:8>` clear, which is another word of the page; one with `<31:28>` set,
/// refused.  Then the code at that address, the last word of its line, and
/// the next line read, so the cache holds it: the location counter set to
/// the code, `LC<29:2>` past 24 bits; a return that fetches, into the main
/// loop, which takes the word into M 31; a return that fuses on its halfword
/// 1 into a LOCAL handler, which records PDL-INDEX; and a return that needs
/// the next word, which the fetch left in the prefetch's buffer from the
/// next line, and fuses on it.
fn fused_program() -> Prog {
    let base = QUUX_PROM_BASE as u64;
    let mut p = Prog::new();
    p.start();
    // The map for VA_F: level 1 at 12345 <- block 123; level 2 at {123, 26}
    // <- page 20000, readable and writable.
    p.map_store(VA_F as Word, 0o123u64 << 32 | 1 << 29);
    p.map_store(VA_F as Word, (1 << 28 | 1 << 27 | 1 << 26 | PAGE_F) as Word);
    // The code: halfword 1 opcode 13, register 5 (LOCAL), delta 27; halfword
    // 0 another opcode with register 6; the word with a tag, which the index
    // never sees.  And the next word's two halfwords, and the word at VA_F
    // with <9:8> clear.
    let hw1 = half(0o13, 5, 0o27);
    let hw0 = half(0o21, 6, 0o11);
    let code = w(0o025, hw1 << 16 | hw0);
    let next_hw1 = half(0o15, 5, 0o3);
    let next_hw0 = half(0o17, 5, 0o5);
    let next = w(0o031, next_hw1 << 16 | next_hw0);
    let other = w(0o005, 0xbad);
    p.a(0o103, VA_F as Word).a(0o104, code);
    p.a(0o105, (VA_F + 1) as Word).a(0o106, next);
    p.a(0o107, (VA_F & !0o1400) as Word).a(0o110, other);
    p.write_a(0o104, 0o103).write_a(0o106, 0o105).write_a(0o110, 0o107);
    // Through the map: VA_F, VA_F with <39:32> set, VA_F with <9:8> clear.
    p.a(0o111, w(0o245, VA_F));
    p.read_a(0o103, code, "VA");
    p.read_a(0o111, code, "VA with <39:32> set");
    p.read_a(0o107, other, "VA with <9:8> clear");
    // <31:28> set: the read is refused, and condition 4, page fault, holds.
    p.a(0o112, (1 << 28 | VA_F) as Word);
    p.op(ALU | SETA | a_src(0o112) | START_READ);
    p.taken(jcond(4), 1, "<31:28> set: a page fault");
    // The next line, read, so the cache holds it; and the code's own line
    // read too, a hit when the fetch comes.
    p.read_a(0o105, next, "the next word, its line now held");

    // The fused return (A1.2, G2 §2.7).
    let main = 1 << 14 | (base + QMLP_F);
    p.a(0o113, macro_dispatch::word((base + QMLP_F) as u16, LOCALP_AT_F as u16, 0o21) as Word);
    p.a(0o114, hw1 >> 6).a(0o115, (macro_dispatch::OPERAND as u64 | (base + HANDLER_F)) as Word);
    p.a(0o116, LOCALP_F).a(0o117, (4 * VA_F) as Word).a(0o120, main as Word);
    // The next word's two halfwords, to the second handler.
    p.a(0o121, next_hw1 >> 6).a(0o122, next_hw0 >> 6);
    p.a(0o123, (macro_dispatch::OPERAND as u64 | (base + HANDLER_NEXT)) as Word);
    p.op(ALU | SETA | a_src(ZERO) | INTCTL);
    p.op(ALU | SETA | a_src(0o113) | fd(5));
    p.op(ALU | SETA | a_src(0o114) | fd(6));
    p.op(ALU | SETA | a_src(0o115) | fd(7));
    p.op(ALU | SETA | a_src(0o121) | fd(6));
    p.op(ALU | SETA | a_src(0o123) | fd(7));
    p.op(ALU | SETA | a_src(0o122) | fd(6));
    p.op(ALU | SETA | a_src(0o123) | fd(7));
    p.op(ALU | SETA | a_src(0o116) | a_dest(LOCALP_AT_F));
    p.op(ALU | SETA | a_src(0o117) | LC);
    p.op(ALU | SETA | a_src(0o120) | fd(0o15));
    // The first return: LC was written, so it fetches.
    p.op(filler().raw() | POPJ);
    assert!(p.at() <= base + QMLP_F, "fused: the setup runs into the main loop");
    while p.at() < base + QMLP_F {
        p.op(filler().raw());
    }
    // The main loop: M 31 <- the fetched word, the return pushed back, and
    // the return, which fuses.
    p.op(filler().raw()).op(filler().raw());
    p.op(ALU | SETM | SRC_MD | m_dest(0o31));
    p.op(ALU | SETA | a_src(0o120) | fd(0o15));
    p.op(filler().raw() | POPJ);
    assert!(p.at() <= base + HANDLER_F, "fused: the main loop runs into the handler");
    while p.at() < base + HANDLER_F {
        p.op(filler().raw());
    }
    // The handler: PDL-INDEX is A-LOCALP + delta, and M 31 the code; then
    // the return, which needs the next word.
    p.put(ALU | SETM | src(3), LOCALP_F + 0o27, "PDL-INDEX: A-LOCALP + delta");
    p.put(ALU | SETM | m_src(0o31), code, "M 31, the fetched word");
    p.op(ALU | SETA | a_src(0o120) | fd(0o15));
    p.op(filler().raw() | POPJ);
    assert!(p.at() <= base + HANDLER_NEXT, "fused: the handler runs into the next");
    while p.at() < base + HANDLER_NEXT {
        p.op(filler().raw());
    }
    // The next word's handler: M 31 is the next word, which the return took
    // from the prefetch's buffer.
    p.put(ALU | SETM | m_src(0o31), next, "M 31, the next word");
    p.park();
    p
}

// ------------------------------------------------------------------ main

fn program(name: &str) -> Prog {
    match name {
        "alu" => alu_program(),
        "byte" => byte_program(),
        "dispatch" => dispatch_program(),
        "map" => map_program().0,
        "space" => space_program(),
        "lines" => lines_program(),
        "fused" => fused_program(),
        "devices" => devices_program(),
        "disk" => disk_program(),
        _ => {
            eprintln!("quux13: no program `{name}`; they are alu, byte, dispatch, map, space, lines, fused, devices and disk");
            std::process::exit(2);
        }
    }
}

/// Revision 13's machine with `prom` in QUUX's PROM, as `machine_axis`
/// builds QUUX, at the 40-bit geometry.
fn machine(prom: &[Insn], boards: u32) -> Machine {
    let mut m = Which::Quux.machine(prom);
    m.geometry = REV13;
    m.main = vec![0; (boards as usize) << 16];
    m
}

/// Main memory's 64K-word boards for program `name`: the memory programs'
/// and the devices' 65, past 22 bits, and QUUX's 32 for the rest.
fn boards(name: &str) -> u32 {
    if matches!(name, "space" | "lines" | "fused" | "devices" | "disk") { BOARDS_13 } else { 32 }
}

/// Every result the program was to leave, from the machine's A memory.
fn check(name: &str, p: &Prog, m: &Machine) {
    let maps = if name == "map" { map_program().1 } else { Vec::new() };
    let mut bad = 0;
    for (a, want, what) in &p.results {
        let got = m.amem[*a as usize];
        // `MAP(MD)`'s fault bits are the latched entry's; the rest is the
        // test's.
        let got_cmp = if maps.iter().any(|&(ma, _, _)| ma == *a) { got & !(3 << 30) } else { got };
        if got_cmp != *want {
            eprintln!("quux13: {name}: A {a:o}, {what}: {got:#012x}, not {want:#012x}");
            bad += 1;
        }
    }
    assert_eq!(bad, 0, "quux13: {name}: {bad} results are not muir's test's");
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    if which != Which::Quux {
        eprintln!("quux13: revision 13 is QUUX's; give --machine quux or no --machine");
    }
    let prom_only = args.iter().any(|a| a == "--prom");
    let timing = if prom_only && !args.iter().any(|a| a == "--sync-cycle-ticks") {
        muir::clock::TimingModel::Fpga
    } else {
        machine_axis::take_timing(Which::Quux, &mut args)
    };
    let mut name = None;
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--program" => name = it.next(),
            "--prom" => {}
            _ => {
                eprintln!("quux13: unknown argument `{a}`");
                std::process::exit(2);
            }
        }
    }
    let Some(name) = name else {
        eprintln!("usage: quux13 --program <name> [--sync-cycle-ticks K [--sync-ilong-ticks L]] [--prom]");
        std::process::exit(2);
    };
    let prog = program(&name);
    let prom = prog.prom();

    if prom_only {
        for k in 0..PROM_WORDS {
            println!("{:012x}", prom.get(k).map_or(0, |w| w.raw()));
        }
        return;
    }

    // The run's length: to the park, and sixteen microcycles on.
    let park = QUUX_PROM_BASE as u64 + prog.words.len() as u64 - 2;
    // The machine, and the disk program's pack on block-disk.
    let machine_for = |prom: &[Insn]| {
        let mut m = machine(prom, boards(&name));
        if name == "disk" {
            disk_pack(&mut m);
        }
        m
    };
    let n = {
        let mut probe = trace::engine_on(machine_for(&prom), timing);
        probe.boot();
        let mut t = trace::Trace::new(&probe);
        let mut cycle = 0u64;
        while probe.pc() as u64 != park {
            assert!(cycle < 400_000, "quux13: {name} never reached its park");
            if let Err(h) = t.row(&mut probe, cycle) {
                panic!("quux13: {name} stopped at microcycle {cycle}: {h:?}");
            }
            cycle += 1;
        }
        cycle + 16
    };

    let mut e = trace::engine_on(machine_for(&prom), timing);
    e.boot();
    println!("{}", trace::COLUMNS);
    println!(
        "# generated by golden/src/quux13.rs from muir's rtl engine: program {name}, machine: quux, revision 13{}",
        machine_axis::timing_suffix(Which::Quux, timing)
    );
    println!("{}", trace::RADIX);
    println!("# rtc {:x}", machine_axis::RTC_START);
    // Main memory's boards where they are not QUUX's 32, which
    // `tb/cadr_machine_tb.cpp` gives the machine.
    if boards(&name) != 32 {
        println!("# boards {}", boards(&name));
    }
    // The disk program's pack, which the testbench's pack side serves, and
    // the pages its transfers reach, whose words the channel moves.
    if name == "disk" {
        println!("# disk {DISK_BLOCKS:x}");
        for lba in DISK_PRELOADED {
            println!("# pack {lba:x}");
        }
        for page in [DISK_A, DISK_B, DISK_C, DISK_D, DISK_LIST] {
            println!("# dma {page:x}");
        }
    }
    let mut t = trace::Trace::new(&e);
    for cycle in 0..n {
        match t.row(&mut e, cycle) {
            Ok(line) => println!("{line}"),
            Err(h) => {
                eprintln!("quux13: {name} stopped at microcycle {cycle}: {h:?}");
                std::process::exit(1);
            }
        }
    }
    check(&name, &prog, e.machine());
    // The file device's two bases as the run leaves them, which the
    // testbench reads through the readout's selector 12, words 7 and 10
    // (`cadr_machine.sv`), with the register table's entry 21.
    {
        use muir::file_device as fd;
        let dev = &e.machine().file_device;
        println!("# fdbases {:x} {:x}", dev.read(fd::CMD_BASE, e.ns()), dev.read(fd::RESP_BASE, e.ns()));
    }
    let c = e.cache().expect("revision 13 has its cache");
    let pf = e.prefetch_counts().expect("revision 13 has its prefetch");
    eprintln!(
        "quux13: {name}: {n} microcycles, {} ns ({} stalled), {} bus cycles, {} results, PC {:o}; \
         the cache {} hits and {} misses; {} fused returns, the prefetch's words taken {} in the line \
         and {} in the next, {} used",
        e.ns(),
        e.stalled_ns(),
        e.bus_cycles(),
        prog.results.len(),
        e.pc(),
        c.hits,
        c.misses,
        e.machine().macro_dispatch.fused,
        pf.same_line,
        pf.next_line,
        pf.used,
    );
    // What each memory program is for, reached: the cache's hits and misses,
    // and the fused returns on a word the page's reach took from the next
    // line.
    if matches!(name.as_str(), "space" | "lines" | "fused") {
        assert!(c.hits > 0 && c.misses > 0, "quux13: {name}: the cache neither hit nor missed");
    }
    if name == "fused" {
        assert!(e.machine().macro_dispatch.fused >= 2, "quux13: fused: fewer than two fused returns");
        assert!(pf.next_line >= 1 && pf.used >= 1, "quux13: fused: no fused return on the next line's word");
    }
}
