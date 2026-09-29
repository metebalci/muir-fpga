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
    START_WRITE, SUB, VMA, XOR, a_dest, a_src, filler, m_dest, m_src, src, target,
};
use muir::machine::{Geometry, Machine, PROM_WORDS, QUUX_PROM_BASE, Word};

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

// ------------------------------------------------------------------ main

fn program(name: &str) -> Prog {
    match name {
        "alu" => alu_program(),
        "byte" => byte_program(),
        "dispatch" => dispatch_program(),
        "map" => map_program().0,
        _ => {
            eprintln!("quux13: no program `{name}`; they are alu, byte, dispatch and map");
            std::process::exit(2);
        }
    }
}

/// Revision 13's machine with `prom` in QUUX's PROM, as `machine_axis`
/// builds QUUX, at the 40-bit geometry.
fn machine(prom: &[Insn]) -> Machine {
    let mut m = Which::Quux.machine(prom);
    m.geometry = REV13;
    m
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
    let n = {
        let mut probe = trace::engine_on(machine(&prom), timing);
        probe.boot();
        let mut t = trace::Trace::new(&probe);
        let mut cycle = 0u64;
        while probe.pc() as u64 != park {
            assert!(cycle < 200_000, "quux13: {name} never reached its park");
            if let Err(h) = t.row(&mut probe, cycle) {
                panic!("quux13: {name} stopped at microcycle {cycle}: {h:?}");
            }
            cycle += 1;
        }
        cycle + 16
    };

    let mut e = trace::engine_on(machine(&prom), timing);
    e.boot();
    println!("{}", trace::COLUMNS);
    println!(
        "# generated by golden/src/quux13.rs from muir's rtl engine: program {name}, machine: quux, revision 13{}",
        machine_axis::timing_suffix(Which::Quux, timing)
    );
    println!("{}", trace::RADIX);
    println!("# rtc {:x}", machine_axis::RTC_START);
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
    eprintln!(
        "quux13: {name}: {n} microcycles, {} ns ({} stalled), {} bus cycles, {} results, PC {:o}",
        e.ns(),
        e.stalled_ns(),
        e.bus_cycles(),
        prog.results.len(),
        e.pc()
    );
}
