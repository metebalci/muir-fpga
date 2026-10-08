// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **QUUX revision 15** (contract G3 revision 15, appendix A15b), as programs
//! in the boot PROM, traced a clock a row on muir's pipeline
//! (`muir::pipeline::Pipeline`, the `rtl` engine on revision 15) with the
//! Kria KR260's memory timing and cache, at a period of `P` units of 0.5 ns.
//!
//!     quux15 --program <name> --period <P> [--mutation <fault>]
//!     quux15 --program <name> --prom
//!
//! Each program is written in `golden/src/trace15.rs`'s columns, which
//! `tb/quux15_core_tb.cpp` compares clock for clock against revision 15's
//! core.  `--prom` writes the program's PROM image, a 64-bit word a line,
//! which is one image at every period.
//!
//! **THE PERIOD IS THE TRACE'S**: 20 (10 ns) is the Kria's design period,
//! its bound, and 17 (8.5 ns) a shorter one it may close at, where the
//! memory's clocks round differently.  A program that reads time is traced
//! at A15b.12's periods too, 7, 8, 8.5, 11 and 19 ns, where the half-ns
//! rules and the accumulators at an odd period show.
//!
//!   alu       straight-line ALU words, each reading the word before's result
//!             (the d1, d2 and d3 bypasses, as muir's
//!             `straight_line_alu_words_end_as_on_micro`), and an
//!             OA-REG-HIGH write with the word that selects it right after
//!   transfer  conditional jumps hinted each way, taken and not, with and
//!             without N; calls with and without N, a nested call, POPJ
//!             after the next word, a return by a jump with R (muir's
//!             `conditional_jumps_hinted_each_way_end_as_on_micro` and
//!             `calls_and_returns_end_as_on_micro`)
//!   memory    main memory written and read back through the physical memory
//!             window, a word of the same line, and the register page's
//!             MACHINE-ID: grants, words landing in MD, a register taken,
//!             and the boot's TLB sweep holding the first start
//!   time      word 25, the period (A15b.1), and timer 0 at 1 us polled
//!             through three rises, each acted on at the first clock at or
//!             after it (A15b.12)
//!   oa, oaout the OA registers, their selects, the hold, and
//!             OA-OUTSIDE-FIELDS
//!   pdl       the PDL buffer: its forwards, its wait, its wrap
//!   muldiv    MUL and DIV
//!   stack     the micro stack's word a microcycle after its push, and the
//!             guard
//!   pdlfield, pdlfieldout
//!             the PDL address field, and PDL-FIELD-MISMATCH
//!   dconst    the dispatch constant, loaded by every DISPATCH, a
//!             dispatch-memory write included
//!
//! and muir's own kind of program, `golden/src/quux15_preset.rs`: the
//! speculation matrix (`matrix`) and programs at random (`random`), each a
//! trace of many runs, a `# run` line naming each; `dispatch`, `predict`
//! and `imem`.  **A TRACE CARRIES ITS MEMORIES**: every run's PROM, and a
//! preset program's control store, A, M and dispatch memory, as
//! `# image <memory> <address> <word>` lines, which the testbench writes into
//! the core before its reset ends, as a bitstream would hold them.
//!
//! **NOTHING IS PRESET** in this file's programs, as in
//! `golden/src/quux14.rs`: every constant is made by the program from the
//! dispatch constant, and every data word is written by the program.  The
//! preset programs are muir's tests', presets and all.  **EACH PROGRAM SAYS
//! WHAT IT REACHED**: its
//! results land in A memory from `200` up.  Before it writes a row, the
//! generator runs the same machine on `micro`, muir's specification, and
//! refuses a trace whose machine ends otherwise than `micro`'s (A, M, the
//! micro stack, the PDL buffer, dispatch memory, main memory and the
//! registers), or whose results are not the program's.
//!
//! **`--mutation` PLANTS ONE OF MUIR'S FAULTS IN THE PIPELINE**
//! (`muir::pipeline::Mutation`, by its name), for the checks that show this
//! generator and the testbench catch a pipeline that is wrong: one that
//! changes results is refused here, and one that changes only the clocks,
//! such as `HintInverted`, passes here and is caught by the testbench.  The
//! trace says it carries the fault in its second line.

mod machine_axis;
mod quux15_preset;
mod trace15;

use machine_axis::Which;
use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::{
    ADD, ALU, ALWAYS, AND, BYTE, DISPATCH, DMEM_WRITE, DPB, HINT, INVERT, JUMP, LDB, MD, N, OA_HIGH_SELECT,
    OA_LOW_SELECT, P,
    POPJ, R, SETA, SETM, SETO, SETZ, SRC_MD, START_READ, START_WRITE, a_dest, a_src, filler, m_dest, m_src,
    src, target,
};
use muir::machine::{Geometry, Halt, Machine, PROM_WORDS, QUUX_PROM_BASE, Word};
use muir::micro::Micro;
use muir::pipeline::{CACHE_WORDS, Mutation, Pipeline, PortTiming};
use muir::tlb;

/// Revision 15.
const REV15: Geometry = Geometry::QUUX_15;

/// The board's memory and cache: the Kria's.
const TIMING: PortTiming = PortTiming::KRIA;

/// Main memory: QUUX's 32 boards, 2M words.
const MAIN: usize = 32 << 16;

/// A memory's constants: 0, 1 and 2.
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const TWO: u64 = 0o42;
/// M memory's 0 and 1.
const M_ZERO: u64 = 0o34;
const M_ONE: u64 = 0o35;
/// M memory: the physical memory window's base, which a poke adds its
/// physical address to.
const M_PW: u64 = 0o26;
/// The A memory words constants are made in, used round in turn.
const K_FIRST: u64 = 0o60;
const K_WORDS: u64 = 0o20;
/// The A memory word a constant bound for M is made in.
const SCRATCH: u64 = 0o77;
/// The first A memory word a result lands in.
const RESULT: u64 = 0o200;
/// M memory: all ones, which [`Prog::start`] makes [`DFALL`]'s entry of.
const M_ONES: u64 = 0o33;
/// M memory: 3, the rises the time program waits for.
const M_THREE: u64 = 0o32;
/// A memory: the word a polling loop tests.
const TESTED: u64 = 0o76;
/// **THE DISPATCH CONSTANT IS LOADED BY A DISPATCH THAT FALLS THROUGH**,
/// this dispatch-memory entry's, R and P (`DFALL`, page CONTRL), and not by
/// a dispatch-memory write as `golden/src/quux14.rs` loads it: muir's `micro`
/// and its pipeline leave the dispatch constant on a write, where its `rtl`
/// loads it (page DSPCTL), so a constant made by a write would read 0 in the
/// reference this trace is taken from.
const DFALL: u64 = 0o3777;

/// A 40-bit word from its tag `<39:32>` and field `<31:0>`.
const fn w(tag: u64, field: u64) -> Word {
    tag << 32 | (field & 0xffff_ffff)
}

/// A functional destination, with M's address 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}
/// Destination 17, OA-REG-HIGH.
const OA_HIGH: u64 = fd(0o17);

/// A BYTE word: function, rotate `IR<5:0>` and length - 1 `IR<11:6>`.
fn byte(func: u64, rotate: u64, len: u64) -> u64 {
    BYTE | func | (len - 1) << 6 | rotate
}
/// A JUMP on condition `code`, `IR<4:0>` with `IR<5>` (A1.3).
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// The physical memory window's address of main memory's word `phys`.
const fn phys_va(phys: u32) -> Word {
    (tlb::PHYSICAL_WINDOW | phys) as Word
}
/// The register page's word `k` through the device window.
const fn reg(k: u32) -> Word {
    (tlb::REGISTER_PAGE + k) as Word
}

// --------------------------------------------------------------- programs

/// A program being assembled into QUUX's PROM, from its first word at
/// `QUUX_PROM_BASE`, and the results it is to leave in A memory, each under
/// a mask.
struct Prog {
    words: Vec<u64>,
    results: Vec<(u64, Word, Word, String)>,
    next_k: u64,
    park: Option<u64>,
    /// `micro`'s OA select check (A15b.15) on: off for a program that reads
    /// an OA register at a distance, or before any write, as muir's tests
    /// of the hold do.
    select_check: bool,
    /// The program ends at an error halt at this word, not at its park: the
    /// word and the trace's `errhalt` code, 1 OA-OUTSIDE-FIELDS and 2
    /// PDL-FIELD-MISMATCH.
    halts_at: Option<(u64, u8)>,
}

impl Prog {
    fn new() -> Self {
        Prog {
            words: Vec::new(),
            results: Vec::new(),
            next_k: 0,
            park: None,
            select_check: true,
            halts_at: None,
        }
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

    /// Fillers up to the control store address `to`.
    fn fill_to(&mut self, to: u64) -> &mut Self {
        assert!(self.at() <= to, "the program runs past {to:o}");
        while self.at() < to {
            self.fill(1);
        }
        self
    }

    /// `A[a]` = `v`, 40 bits, made from the dispatch constant: ten bits at
    /// a time, each loaded by a DISPATCH through [`DFALL`], which falls
    /// through, and deposited at its place by a DPB.
    fn a(&mut self, a: u64, v: Word) -> &mut Self {
        let mut first = true;
        for k in 0..4u64 {
            let piece = (v >> (10 * k)) & 0o1777;
            if !first && piece == 0 {
                continue;
            }
            self.op(DISPATCH | DFALL << 12 | a_src(piece));
            if first {
                if k == 0 {
                    self.op(ALU | SETM | src(0) | a_dest(a));
                } else {
                    self.op(ALU | SETA | a_src(ZERO) | a_dest(a));
                    self.op(byte(DPB, 10 * k, 10) | src(0) | a_src(a) | a_dest(a));
                }
                first = false;
            } else {
                self.op(byte(DPB, 10 * k, 10) | src(0) | a_src(a) | a_dest(a));
            }
        }
        self
    }

    /// A constant, made in the next of A's round of constant words: its
    /// address.
    fn k(&mut self, v: Word) -> u64 {
        let a = K_FIRST + self.next_k % K_WORDS;
        self.next_k += 1;
        self.a(a, v);
        a
    }

    /// M `m` = `v`, and the A word it shadows.
    fn m(&mut self, m: u64, v: Word) -> &mut Self {
        self.a(SCRATCH, v);
        self.op(ALU | SETA | a_src(SCRATCH) | m_dest(m))
    }

    /// The next result's A address, which is to hold `want` under `mask`.
    fn result(&mut self, want: Word, mask: Word, what: &str) -> u64 {
        let a = RESULT + self.results.len() as u64;
        assert!(a < 0o1000, "the results run past A 777");
        self.results.push((a, want, mask, what.to_string()));
        a
    }

    /// A result of the word `raw`, whose destination this adds.
    fn put(&mut self, raw: u64, want: Word, what: &str) -> &mut Self {
        let a = self.result(want, !0, what);
        self.op(raw | a_dest(a))
    }

    /// A result, 1 if the JUMP `jump` is taken and 0 if not: the jump goes
    /// to the word after the next with `N`, which the jump inhibits when
    /// taken and runs when not.  The two writes are BYTE words, which leave
    /// the overflow flag.
    fn taken(&mut self, jump: u64, want: Word, what: &str) -> &mut Self {
        let a = self.result(want, !0, what);
        self.op(byte(LDB, 0, 40) | m_src(M_ONE) | a_dest(a));
        let next = self.at() + 2;
        self.op(jump | target(next) | N);
        self.op(byte(LDB, 0, 40) | m_src(M_ZERO) | a_dest(a))
    }

    /// The word at the virtual address `va`: the start, the fault test in
    /// the microcycle after it, and `MD` in the one after that.  A result of
    /// the fault and one of `MD`.
    fn read(&mut self, va: Word, want: Word, what: &str) -> &mut Self {
        let a = self.k(va);
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.taken(jcond(4), 0, &format!("{what}: no fault"));
        self.put(ALU | SETM | SRC_MD, want, what)
    }

    /// The word `word` to the virtual address `va`, and two words after.
    fn store(&mut self, word: Word, va: Word) -> &mut Self {
        let (wa, aa) = (self.k(word), self.k(va));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.fill(2)
    }

    /// Main memory's word `phys` <- `word`, through the physical memory
    /// window: `MD` first, then the start at M `M_PW` plus the address.
    fn poke(&mut self, phys: u32, word: Word) -> &mut Self {
        let wa = self.k(word);
        self.op(ALU | SETA | a_src(wa) | MD);
        let oa = self.k(phys as Word);
        self.op(ALU | ADD | m_src(M_PW) | a_src(oa) | START_WRITE)
    }

    /// Stops: a jump to itself, the word after it inhibited.
    fn park(&mut self) -> &mut Self {
        let here = self.at();
        self.op(JUMP | target(here) | ALWAYS | N);
        self.fill(1);
        self.park = Some(here);
        self
    }

    /// The PROM image: revision 15's 64-bit words.
    fn prom(&self) -> Vec<Insn> {
        assert!(self.words.len() <= PROM_WORDS, "the program is {} words and the PROM {PROM_WORDS}", self.words.len());
        self.words.iter().map(|&w| Insn::extended(w)).collect()
    }

    /// The constants every program starts from, after [`DFALL`]'s entry:
    /// R and P, `300000`, made of M all ones by a DPB, with no constant.
    fn start(&mut self) -> &mut Self {
        self.op(ALU | SETO | m_dest(M_ONES));
        self.op(ALU | SETZ | a_dest(SCRATCH));
        self.op(byte(DPB, 15, 2) | m_src(M_ONES) | a_src(SCRATCH) | a_dest(SCRATCH));
        self.op(DISPATCH | DFALL << 12 | DMEM_WRITE | a_src(SCRATCH));
        self.a(ZERO, 0).a(ONE, 1).a(TWO, 2);
        self.m(M_ZERO, 0).m(M_ONE, 1).m(M_PW, tlb::PHYSICAL_WINDOW as Word)
    }
}

/// **Straight-line ALU words** (muir's
/// `straight_line_alu_words_end_as_on_micro`): each word reads the word
/// before's result, in M and through the A word M shadows, so that the d1,
/// d2 and d3 bypasses each carry one; and OA-REG-HIGH written by one word
/// and read into the next's A and M sources (A15b.15), the select right
/// after its writer as `micro` requires, the hold of two clocks between.
fn alu_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    p.m(0o20, 5).m(0o21, 7);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o21) | m_dest(0o22));
    p.op(ALU | ADD | a_src(0o22) | m_src(0o22) | m_dest(0o23));
    p.op(ALU | ADD | a_src(0o22) | m_src(0o23) | m_dest(0o24));
    p.op(ALU | ADD | a_src(0o22) | m_src(0o24) | m_dest(0o25));
    p.put(ALU | ADD | a_src(0o23) | m_src(0o25), 16 + 32, "A 23 + M 25, a word after its M source's writer");
    let last = RESULT + p.results.len() as u64 - 1;
    p.put(ALU | SETA | a_src(last), 16 + 32, "the result before, read through A at once");
    for (m, want) in [(0o22, 8), (0o23, 16), (0o24, 24), (0o25, 32)] {
        p.put(ALU | SETM | m_src(m), want, &format!("M {m:o}"));
    }
    // OA-REG-HIGH: A 1700 | 3, M 20 | 4, the select right after the writer.
    p.a(0o1703, 0o33);
    let v = p.k(3 << 6 | 4);
    p.op(ALU | SETA | a_src(v) | OA_HIGH);
    p.put(ALU | ADD | a_src(0o1700) | m_src(0o20) | OA_HIGH_SELECT, 0o33 + 24, "A 1703 + M 24 through OA-REG-HIGH");
    p.park();
    p
}

/// **Transfers** (muir's `conditional_jumps_hinted_each_way_end_as_on_micro`
/// and `calls_and_returns_end_as_on_micro`): a jump on `A = M`, taken when M
/// is 0, hinted not taken and taken, with and without N, each counting the
/// words it ran into a result; then two calls of a subroutine, with N (the
/// return comes back to the delay slot) and without, a nested call, POPJ
/// after the next word, and a return by a jump with R.
fn transfer_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    for hint in [0, HINT] {
        for m in [M_ZERO, M_ONE] {
            for n in [0, N] {
                // Taken: the slot unless N, the target; not taken: all three.
                let want = match (m == M_ZERO, n != 0) {
                    (true, false) => 3,
                    (true, true) => 2,
                    (false, _) => 4,
                };
                let what = format!(
                    "a jump hinted {}, M {}, {}",
                    if hint != 0 { "taken" } else { "not taken" },
                    if m == M_ZERO { 0 } else { 1 },
                    if n != 0 { "N" } else { "no N" }
                );
                let r = p.result(want, !0, &what);
                p.op(byte(LDB, 0, 40) | m_src(M_ONE) | a_dest(r));
                let to = p.at() + 3;
                p.op(jcond(3) | m_src(m) | a_src(ZERO) | target(to) | hint | n);
                for _ in 0..3 {
                    p.op(ALU | ADD | m_src(M_ONE) | a_src(r) | a_dest(r));
                }
            }
        }
    }
    let sub1 = QUUX_PROM_BASE as u64 + 0o1700;
    let sub2 = QUUX_PROM_BASE as u64 + 0o1720;
    let main = p.result(3, !0, "the caller's count: the slot after the return of a call with N");
    let in_sub1 = p.result(6, !0, "the subroutine's count, two words a call, three calls");
    let in_sub2 = p.result(1, !0, "the nested caller's count");
    for r in [main, in_sub1, in_sub2] {
        p.op(ALU | SETA | a_src(ZERO) | a_dest(r));
    }
    let count = |r: u64| ALU | ADD | m_src(M_ONE) | a_src(r) | a_dest(r);
    p.op(JUMP | ALWAYS | P | N | target(sub1));
    p.op(count(main));
    p.op(JUMP | ALWAYS | P | target(sub1));
    p.op(count(main));
    p.op(count(main));
    p.op(JUMP | ALWAYS | P | N | target(sub2));
    p.fill(1);
    p.park();
    p.fill_to(sub1);
    p.op(count(in_sub1) | POPJ);
    p.op(count(in_sub1));
    p.fill_to(sub2);
    p.op(JUMP | ALWAYS | P | N | target(sub1));
    p.fill(1);
    p.op(count(in_sub2));
    p.op(JUMP | ALWAYS | R | N);
    p.fill(1);
    p
}

/// **Main memory and a register** through the windows, which never touch the
/// TLB: a word written and read back, a word of its line never written, and
/// the register page's word 0, MACHINE-ID at revision 15.  The first start
/// waits behind the boot's sweep of the TLB.
fn memory_program() -> Prog {
    const WORD: u32 = 0o2007;
    let mut p = Prog::new();
    p.start();
    p.poke(WORD, w(0o025, 0x1234_5678));
    p.read(phys_va(WORD), w(0o025, 0x1234_5678), "the word written");
    p.read(phys_va(WORD - 1), 0, "a word of its line, never written");
    p.read(reg(0), (0x5155 << 16) | (15 << 4) | 4, "MACHINE-ID, revision 15");
    p.park();
    p
}

/// **Time** at the period `period` (A15b.1, A15b.12): word 25 reads it; then
/// timer 0, its period 1 us, enabled, and its flag polled through the
/// register page, cleared at each rise, until it has risen three times.  The
/// results are the period and the count; the clocks the rises are acted on
/// at are the trace's, at each period.
fn time_program(period: u64) -> Prog {
    let mut p = Prog::new();
    p.start();
    p.m(M_THREE, 3);
    p.read(reg(0o25), period, "word 25, the period in units of 0.5 ns");
    p.store(1, reg(0o111)).store(1, reg(0o110));
    let count = p.result(3, !0, "the timer's rises waited for");
    p.op(ALU | SETA | a_src(ZERO) | a_dest(count));
    let (ctl, clear) = (p.k(reg(0o110)), p.k(1 | 2));
    let poll = p.at();
    p.op(ALU | SETA | a_src(ctl) | START_READ);
    p.fill(1);
    p.op(ALU | AND | SRC_MD | a_src(TWO) | a_dest(TESTED));
    p.op(jcond(3) | a_src(TESTED) | m_src(M_ZERO) | target(poll) | N);
    p.fill(1);
    p.op(ALU | SETA | a_src(clear) | MD);
    p.op(ALU | SETA | a_src(ctl) | START_WRITE);
    p.fill(1);
    p.op(ALU | ADD | m_src(M_ONE) | a_src(count) | a_dest(count));
    p.op(jcond(3) | INVERT | a_src(count) | m_src(M_THREE) | target(poll) | N);
    p.fill(1);
    p.park();
    p
}

/// OA-REG-LOW, destination 16.
const OA_LOW: u64 = fd(0o16);
/// The PDL buffer's destinations: 10 at the pointer, 11 pushed, 12 at
/// PDL-INDEX; 13 PDL-INDEX and 14 the pointer.
const PDL_AT_POINTER: u64 = fd(0o10);
const PDL_PUSH: u64 = fd(0o11);
const PDL_AT_INDEX: u64 = fd(0o12);
const PDL_INDEX: u64 = fd(0o13);
const PDL_POINTER: u64 = fd(0o14);
/// Its sources: 24 popped by the pointer, 25 at the pointer, 5 at
/// PDL-INDEX.
const PDL_POP: u64 = src(0o24);
const PDL_TOP: u64 = src(0o25);
const PDL_AT_IDX: u64 = src(0o5);

/// `v` rotated left `k` places in the ring of 40 (`rol40`).
fn rol40(v: Word, k: u32) -> Word {
    let v = v & ((1 << 40) - 1);
    match k % 40 {
        0 => v,
        k => (v << k | v >> (40 - k)) & ((1 << 40) - 1),
    }
}

/// **The OA registers and selects** (A15b.15; muir's
/// `the_oa_high_hold_is_2_1_0_clocks` and its fields): OA-REG-HIGH as
/// -RESET leaves it, 0, read by an SH word with no writer before it; an SH
/// word 1, 2 and 3 words after its writer, CS holding it 2, 1 and 0 clocks;
/// SH on a BYTE word; and SL into each field it reaches but a JUMP's: an ALU
/// word's A destination, its M destination and its function, a BYTE word's
/// destination and its rotate and length, a dispatch-memory write's
/// address.  `micro`'s select check is off, as for muir's test of the hold.
fn oa_program() -> Prog {
    let mut p = Prog::new();
    p.select_check = false;
    p.start();
    p.a(0o1700, 0o11).a(0o1701, 0o770000).a(0o1703, 0o33);
    p.m(0o20, 0o100).m(0o21, 0o300).m(0o24, 0o200).m(0o25, 0o12345670);
    p.put(ALU | ADD | a_src(0o1700) | m_src(0o20) | OA_HIGH_SELECT, 0o11 + 0o100, "SH at power-on: A 1700 + M 20");
    for before in 1..=3 {
        // A 1700 | 3 and M 20 | 4.
        let v = p.k(3 << 6 | 4);
        p.op(ALU | SETA | a_src(v) | OA_HIGH);
        p.fill(before - 1);
        p.put(
            ALU | ADD | a_src(0o1700) | m_src(0o20) | OA_HIGH_SELECT,
            0o33 + 0o200,
            &format!("SH {before} words after its writer: A 1703 + M 24"),
        );
    }
    // SH on a BYTE word: A 1701 and M 21, the low 12 bits of M into A.
    let v = p.k(1 << 6 | 1);
    p.op(ALU | SETA | a_src(v) | OA_HIGH);
    p.put(byte(LDB, 0, 12) | a_src(0o1700) | m_src(0o20) | OA_HIGH_SELECT, 0o770300, "SH on LDB: M 21 into A 1701");
    // SL into an ALU word's A destination: A 300 | 5.
    let (word, v) = (p.k(0o12345), p.k(0o5 << 14));
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.op(ALU | SETA | a_src(word) | a_dest(0o300) | OA_LOW_SELECT);
    p.put(ALU | SETA | a_src(0o305), 0o12345, "SL into an A destination: A 305");
    // Into an M destination: M 20 | 3.
    let (word, v) = (p.k(0o54321), p.k(0o3 << 14));
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.op(ALU | SETA | a_src(word) | m_dest(0o20) | OA_LOW_SELECT);
    p.put(ALU | SETM | m_src(0o23), 0o54321, "SL into an M destination: M 23");
    // Into the ALU function: SETZ made SETA.
    let (word, v) = (p.k(0o666), p.k(SETA));
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.put(ALU | SETZ | a_src(word) | OA_LOW_SELECT, 0o666, "SL into the function: SETZ made SETA");
    // Into a BYTE word's destination: A 310 | 2.
    let v = p.k(0o2 << 14);
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.op(byte(LDB, 0, 12) | m_src(0o21) | a_src(ZERO) | a_dest(0o310) | OA_LOW_SELECT);
    p.put(ALU | SETA | a_src(0o312), 0o300, "SL into a BYTE destination: A 312");
    // Into its rotate and length: LDB of one bit made eight, rotated 32.
    let v = p.k(32 | 7 << 6);
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.put(
        byte(LDB, 0, 1) | m_src(0o25) | a_src(ZERO) | OA_LOW_SELECT,
        rol40(0o12345670, 32) & 0xff,
        "SL into a BYTE's rotate and length",
    );
    // Into a dispatch-memory write's address: entry 2000 | 12, falling
    // through with N, which the dispatch through it then shows: the word
    // after it does not run.
    let count = p.result(2, !0, "a dispatch through the entry SL wrote, N inhibiting one count");
    p.op(ALU | SETA | a_src(ONE) | a_dest(count));
    let (entry, v) = (p.k(0o340000), p.k(0o12 << 12));
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.op(DISPATCH | 0o2000 << 12 | DMEM_WRITE | a_src(entry) | OA_LOW_SELECT);
    p.op(DISPATCH | 0o2012 << 12);
    for _ in 0..2 {
        p.op(ALU | ADD | m_src(M_ONE) | a_src(count) | a_dest(count));
    }
    p.park();
    p
}

/// **OA-OUTSIDE-FIELDS** (A15b.15): OA-REG-LOW with `<13>`, the output
/// select, which no field of an ALU word's SL takes; the machine stops at
/// the word that selects it, before it commits.  The register is written
/// twice, so that the word in WB when the machine stops, whose write the
/// pipeline leaves unlanded, writes what is already there.
fn oaout_program() -> Prog {
    let mut p = Prog::new();
    p.select_check = false;
    p.start();
    p.put(ALU | SETA | a_src(TWO), 2, "a word before the stop");
    let v = p.k(1 << 13);
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.op(ALU | SETA | a_src(v) | OA_LOW);
    p.halts_at = Some((p.at(), 1));
    p.op(ALU | SETA | a_src(ONE) | a_dest(0o300) | OA_LOW_SELECT);
    p.fill(4);
    p.park();
    p
}

/// **The PDL buffer** (A15b.3, A15b.10; muir's
/// `the_pdl_buffer_across_its_wrap`): a read through the pointer right after
/// its write from the ALU, which waits a clock, and the index's likewise;
/// pushes across the wrap, each read one, two and three words after (the old
/// word, WB's forward, and the forward that replaces a read of the address
/// written in that clock); pops back across it; a write at the pointer and
/// at the index, read back; and a word that reads and pushes each clock.
fn pdl_program() -> Prog {
    let top: Word = 0o37777;
    let mut p = Prog::new();
    p.start();
    let start = p.k(top - 2);
    p.op(ALU | SETA | a_src(start) | PDL_POINTER);
    p.put(ALU | SETM | PDL_TOP, 0, "at the pointer right after its write: waits, then the old word");
    for k in 0..5u64 {
        let v = p.k(0o1000 + k);
        p.op(ALU | SETA | a_src(v) | PDL_PUSH);
        for (j, want) in [(1, 0), (2, 0o1000 + k), (3, 0o1000 + k)] {
            p.put(ALU | SETM | PDL_TOP, want, &format!("push {k}, read {j} words after"));
        }
    }
    for k in 0..6u64 {
        let want = if k < 5 { 0o1004 - k } else { 0 };
        p.put(ALU | SETM | PDL_POP, want, &format!("pop {k}"));
    }
    let i = p.k(0o123);
    p.op(ALU | SETA | a_src(i) | PDL_INDEX);
    p.put(ALU | SETM | PDL_AT_IDX, 0, "at the index right after its write: waits");
    let v = p.k(0o4444);
    p.op(ALU | SETA | a_src(v) | PDL_AT_INDEX);
    for (j, want) in [(1, 0), (2, 0o4444), (3, 0o4444)] {
        p.put(ALU | SETM | PDL_AT_IDX, want, &format!("the write at the index, read {j} words after"));
    }
    let v = p.k(0o7070);
    p.op(ALU | SETA | a_src(v) | PDL_AT_POINTER);
    p.fill(1);
    p.put(ALU | SETM | PDL_TOP, 0o7070, "the write at the pointer, read two words after");
    p.op(ALU | SETA | a_src(start) | PDL_POINTER);
    p.fill(2);
    // Each push writes the word it read plus one, a word up; the read right
    // after it takes the old word there, the first pushes' across the wrap.
    for (k, want) in [0o1000, 0o1001, 0o1002, 0o1003, 0o1004, 0].into_iter().enumerate() {
        p.op(ALU | ADD | a_src(ONE) | PDL_TOP | PDL_PUSH);
        p.put(ALU | SETM | PDL_TOP, want, &format!("read and push {k}, then the old word"));
    }
    p.put(ALU | SETM | src(0o2), (top - 2 + 6) & top, "the pointer, wrapped");
    // A word that waits in RD while a DIV holds EX keeps the PDL buffer's
    // word it read, whatever the word behind it in CS reads.
    let (n, d) = (p.k(1000), p.k(7));
    p.op(ALU | SETA | a_src(n) | m_dest(0o20));
    p.op(ALU | 0o43 << 3 | m_src(0o20) | a_src(d) | m_dest(0o21));
    p.put(ALU | SETM | PDL_TOP, 6, "at the pointer, read while a DIV held EX");
    p.put(ALU | SETM | PDL_AT_IDX, 0o4444, "at the index, behind it");
    p.park();
    p
}

/// **MUL and DIV** (A15b.3: DIV 18 clocks in EX, MUL 5): each right after
/// its M operand's writer (d1), its output and `Q` read right after it, and
/// the two back to back; operands of both signs, a divisor of zero, and Q
/// as the M operand.
fn muldiv_program() -> Prog {
    use muir::muldiv::{Op as MD_OP, run};
    let mut p = Prog::new();
    p.start();
    let mut q: u32 = 0;
    let cases: [(u32, u32, u32); 5] =
        [(1_000_000, 7, 0), (0xffff_cfc7, 67, 12), (0x7fff_ffff, 0xffff_ffff, 99), (5, 0, 3), (123_456, 789, 0x8000_0001)];
    for (k, &(m, a, q0)) in cases.iter().enumerate() {
        let (km, ka, kq) = (p.k(Word::from(m)), p.k(Word::from(a)), p.k(Word::from(q0)));
        p.op(ALU | SETA | a_src(kq) | muir::isa::asm::Q_LOAD | m_dest(0o30));
        q = q0;
        p.op(ALU | SETA | a_src(km) | m_dest(0o20));
        let op = if k % 2 == 0 { MD_OP::Div } else { MD_OP::Mul };
        let f = if op == MD_OP::Div { 0o43 } else { 0o42 };
        let (out, nq) = run(op, m, a, q);
        p.put(ALU | f << 3 | m_src(0o20) | a_src(ka), Word::from(out), &format!("case {k}: {op:?}'s output, read in the next word"));
        q = nq;
        p.put(ALU | SETM | muir::isa::asm::SRC_Q, Word::from(q), &format!("case {k}: Q"));
        // The other, back to back, Q as its M operand.
        let op2 = if op == MD_OP::Div { MD_OP::Mul } else { MD_OP::Div };
        let f2 = if op2 == MD_OP::Div { 0o43 } else { 0o42 };
        let (out2, nq2) = run(op2, q, a, q);
        p.put(ALU | f2 << 3 | muir::isa::asm::SRC_Q | a_src(ka), Word::from(out2), &format!("case {k}: {op2:?} of Q"));
        q = nq2;
        p.put(ALU | SETM | muir::isa::asm::SRC_Q, Word::from(q), &format!("case {k}: Q after both"));
    }
    let _ = q;
    p.park();
    p
}

/// Destinations 2, INTERRUPT-CONTROL, and 15, the micro stack pushed with
/// data.
const INTERRUPT_CONTROL: u64 = fd(0o2);
const SPC_PUSH: u64 = fd(0o15);

/// **The micro stack and the guard** (A15b.3, A15b.16): a word pushed as
/// data, read through functional source 1 in the word after it (the old
/// word, its push landing a microcycle on) and two after (the new), and
/// popped by source 14; a return address pushed as data and a POPJ right
/// after it, which RD holds a clock for, its copy of the top not yet
/// written; and returns right after a write of INTERRUPT-CONTROL and of M
/// 31, and two after a write of M 31, each held a clock by the guard; a POPJ
/// on a word that pops by its source, which EX decides.
fn stack_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    let word = p.k(0o12345);
    p.op(ALU | SETA | a_src(word) | SPC_PUSH);
    p.put(ALU | SETM | src(0o1), 1 << 24, "the stack's word in the word after its push: the old one");
    p.put(ALU | SETM | src(0o1), 1 << 24 | 0o12345, "two words after: the new one");
    p.put(ALU | SETM | src(0o14), 1 << 24 | 0o12345, "popped by the source");
    // A return address pushed as data, and a POPJ right after it.
    let count = p.result(4, !0, "the delay slots that ran: one past a return, three after calls with N");
    p.op(ALU | SETA | a_src(ZERO) | a_dest(count));
    let to = p.at() + 16;
    let ret = p.k(to);
    p.op(ALU | SETA | a_src(ret) | SPC_PUSH);
    p.op(filler().raw() | POPJ);
    p.op(ALU | ADD | m_src(M_ONE) | a_src(count) | a_dest(count));
    p.fill_to(to);
    // Calls to subroutines whose returns follow a write the guard holds for.
    let subs = [QUUX_PROM_BASE as u64 + 0o1600, QUUX_PROM_BASE as u64 + 0o1620, QUUX_PROM_BASE as u64 + 0o1640];
    for &sub in &subs {
        p.op(JUMP | ALWAYS | P | N | target(sub));
        p.op(ALU | ADD | m_src(M_ONE) | a_src(count) | a_dest(count));
    }
    // A POPJ on a word that pops by its source: EX decides where it goes.
    let to = p.at() + 16;
    let ret = p.k(to);
    p.op(ALU | SETA | a_src(ret) | SPC_PUSH);
    p.op(ALU | SETA | a_src(ret) | SPC_PUSH);
    p.fill(1);
    p.put(ALU | SETM | src(0o14) | POPJ, 2 << 24 | to, "popped by the source, on a POPJ");
    p.fill(1);
    p.fill_to(to);
    p.park();
    // INTERRUPT-CONTROL written, then the return.
    p.fill_to(subs[0]);
    p.op(ALU | SETA | a_src(ZERO) | INTERRUPT_CONTROL);
    p.op(filler().raw() | POPJ);
    p.fill(1);
    // M 31 written, then the return.
    p.fill_to(subs[1]);
    p.op(ALU | SETA | a_src(ONE) | m_dest(0o31));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    // M 31 written two words before the return.
    p.fill_to(subs[2]);
    p.op(ALU | SETA | a_src(TWO) | m_dest(0o31));
    p.fill(1);
    p.op(filler().raw() | POPJ);
    p.fill(1);
    p
}

/// **The PDL address field** (A15b.2): PDL-INDEX written as the pointer or
/// the index plus a displacement the field carries too, read through at once
/// without a wait, RD having formed the index; and with its base written
/// from the ALU in the word before, where RD cannot form it and the read
/// waits a clock.
fn pdlfield_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    let words: Vec<u64> = (0..6).map(|k| p.k(0o4000 + k)).collect();
    let ptr = p.k(0o77);
    p.op(ALU | SETA | a_src(ptr) | PDL_POINTER);
    p.fill(2);
    for &w in &words {
        p.op(ALU | SETA | a_src(w) | PDL_PUSH);
    }
    // The pointer is 105: the index 105 - 3, read at once.
    let (minus3, two, one, ptr2) = (p.k((!2u64) & 0o7777777777777), p.k(2), p.k(1), p.k(0o101));
    p.op(ALU | ADD | src(0o2) | a_src(minus3) | PDL_INDEX | muir::isa::asm::pdl_field(2, -3));
    p.put(ALU | SETM | PDL_AT_IDX, 0o4002, "the index the field formed on the pointer, read at once");
    p.op(ALU | ADD | src(0o3) | a_src(two) | PDL_INDEX | muir::isa::asm::pdl_field(3, 2));
    p.put(ALU | SETM | PDL_AT_IDX, 0o4004, "on the index, read at once");
    // The pointer written from the ALU right before: RD cannot form it.
    p.op(ALU | SETA | a_src(ptr2) | PDL_POINTER);
    p.op(ALU | ADD | src(0o2) | a_src(one) | PDL_INDEX | muir::isa::asm::pdl_field(2, 1));
    p.put(ALU | SETM | PDL_AT_IDX, 0o4002, "its base written the word before: the read waits");
    p.park();
    p
}

/// **PDL-FIELD-MISMATCH** (A15b.2): a field whose displacement is not the
/// constant the word adds; the word commits and the machine stops.  The
/// same sum is written once before without the field, so that the stopping
/// word's write, which the pipeline leaves in WB, writes what is there.
fn pdlfieldout_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    p.put(ALU | SETA | a_src(TWO), 2, "a word before the stop");
    let five = p.k(5);
    p.op(ALU | ADD | src(0o2) | a_src(five) | PDL_INDEX);
    p.halts_at = Some((p.at(), 2));
    p.op(ALU | ADD | src(0o2) | a_src(five) | PDL_INDEX | muir::isa::asm::pdl_field(2, 4));
    p.fill(4);
    p.park();
    p
}

/// **The dispatch constant** (page DSPCTL): every DISPATCH loads it from its
/// `IR<41:32>`, a dispatch-memory write included, and functional source 0
/// reads it in the next word.
fn dconst_program() -> Prog {
    let mut p = Prog::new();
    p.start();
    p.a(0o525, 0o300000);
    p.op(DISPATCH | 0o2100 << 12 | DMEM_WRITE | a_src(0o525));
    p.put(ALU | SETM | src(0), 0o525, "after a dispatch-memory write: its IR<41:32>");
    p.op(DISPATCH | 0o2100 << 12 | a_src(0o252));
    p.put(ALU | SETM | src(0), 0o252, "after a dispatch through the entry it wrote, which falls through");
    p.park();
    p
}

fn program(name: &str, period: u64) -> Prog {
    match name {
        "alu" => alu_program(),
        "transfer" => transfer_program(),
        "memory" => memory_program(),
        "time" => time_program(period),
        "oa" => oa_program(),
        "oaout" => oaout_program(),
        "pdl" => pdl_program(),
        "muldiv" => muldiv_program(),
        "stack" => stack_program(),
        "pdlfield" => pdlfield_program(),
        "pdlfieldout" => pdlfieldout_program(),
        "dconst" => dconst_program(),
        _ => {
            eprintln!("quux15: no program `{name}`");
            std::process::exit(2);
        }
    }
}

/// The faults `--mutation` takes, by their names in muir.
fn mutation(name: &str) -> Option<Mutation> {
    use Mutation::*;
    [
        NoD3,
        NoSpcRestore,
        NoLcRestore,
        LcNotStepped,
        LcNotMarked,
        NoGuard,
        SquashedStart,
        SquashedLookup,
        NoLandAtStart,
        NoPdlWait,
        NoD1,
        NoD2,
        SpcWriteAtOnce,
        MapSeenNew,
        NoImemRefetch,
        WriteMdAtStart,
        SuccessorWaitsForMd,
        NoCmdProdWait,
        SweepMissesASet,
        NoClearSet,
        FirstReadDropped,
        NopCountedTwice,
        NoOaHold,
        OaHoldShort,
        SquashedOaLoads,
        NoLateSquash,
        HintInverted,
        NoPdlForward,
        InterruptSampledInRd,
    ]
    .into_iter()
    .find(|m| format!("{m:?}") == name)
}

// ---------------------------------------------------------------- machine

/// **A run**, of a program in the PROM or of muir's preset kind: the PROM's
/// words, the memories' words before it runs, where it parks or stops, and
/// what it is to leave in A.  A trace carries its memories as `# image`
/// lines, which `tb/quux15_core_tb.cpp` loads into the core as a bitstream
/// would hold them.
struct Case {
    name: String,
    prom: Vec<u64>,
    imem: Vec<(usize, u64)>,
    amem: Vec<(usize, Word)>,
    mmem: Vec<(usize, Word)>,
    dmem: Vec<(usize, u32)>,
    park: u64,
    halts: Option<(u64, u8)>,
    select_check: bool,
    results: Vec<(u64, Word, Word, String)>,
}

impl Case {
    fn of_prog(name: &str, p: &Prog) -> Case {
        let prom = p.prom().iter().map(|w| w.raw()).collect();
        Case {
            name: name.to_string(),
            prom,
            imem: Vec::new(),
            amem: Vec::new(),
            mmem: Vec::new(),
            dmem: Vec::new(),
            park: p.park.expect("every program parks"),
            halts: p.halts_at,
            select_check: p.select_check,
            results: p.results.clone(),
        }
    }

    /// The memories' words as the trace's `# image` lines say them.
    fn images(&self) -> Vec<String> {
        let mut out = Vec::new();
        for (k, &w) in self.prom.iter().enumerate() {
            if w != 0 {
                out.push(format!("# image prom {k:x} {w:x}"));
            }
        }
        for &(k, w) in &self.imem {
            out.push(format!("# image imem {k:x} {w:x}"));
        }
        for &(k, w) in &self.amem {
            out.push(format!("# image amem {k:x} {w:x}"));
        }
        for &(k, w) in &self.mmem {
            out.push(format!("# image mmem {k:x} {w:x}"));
        }
        for &(k, w) in &self.dmem {
            out.push(format!("# image dmem {k:x} {w:x}"));
        }
        out
    }
}

/// The machine for `case`: QUUX as the fabric builds it, at revision 15,
/// with QUUX's main memory, and the case's memories.
fn machine(case: &Case) -> Machine {
    let prom: Vec<Insn> = case.prom.iter().map(|&w| Insn::extended(w)).collect();
    let mut m = Which::Quux.machine(&prom);
    m.geometry = REV15;
    m.main = vec![0; MAIN];
    for &(k, w) in &case.imem {
        m.imem[k] = Insn::extended(w);
    }
    for &(k, w) in &case.amem {
        m.amem[k] = w;
    }
    for &(k, w) in &case.mmem {
        m.mmem[k] = w;
    }
    for &(k, w) in &case.dmem {
        m.dmem[k] = w;
    }
    m
}

/// The first place two machines' words differ, named.
fn first_difference<T: PartialEq + std::fmt::Debug>(what: &str, e: &[T], u: &[T]) -> Option<String> {
    if e.len() != u.len() {
        return Some(format!("{what}: {} words on the pipeline, {} on micro", e.len(), u.len()));
    }
    let k = (0..e.len()).find(|&k| e[k] != u[k])?;
    Some(format!("{what}[{k:o}]: the pipeline {:?}, micro {:?}", e[k], u[k]))
}

/// Where the pipeline's machine ends otherwise than `micro`'s.
fn differences(e: &Machine, u: &Machine) -> Vec<String> {
    let regs = |m: &Machine| {
        [
            u64::from(m.pdl_pointer),
            u64::from(m.pdl_index),
            u64::from(m.spcptr),
            m.q,
            m.vma,
            m.md,
            m.lc,
            u64::from(m.interrupt_control),
        ]
    };
    let names = ["the PDL pointer", "the PDL index", "the micro stack's pointer", "Q", "VMA", "MD", "LC", "INTERRUPT-CONTROL"];
    let (re, ru) = (regs(e), regs(u));
    let mut d: Vec<String> = (0..8)
        .filter(|&k| re[k] != ru[k])
        .map(|k| format!("{}: the pipeline {:#x}, micro {:#x}", names[k], re[k], ru[k]))
        .collect();
    d.extend(first_difference("A", &e.amem[..], &u.amem[..]));
    d.extend(first_difference("M", &e.mmem[..], &u.mmem[..]));
    d.extend(first_difference("the micro stack", &e.spc[..], &u.spc[..]));
    d.extend(first_difference("the PDL buffer", &e.pdl[..], &u.pdl[..]));
    d.extend(first_difference("dispatch memory", &e.dmem[..], &u.dmem[..]));
    d.extend(first_difference("main memory", &e.main[..], &u.main[..]));
    d.extend(first_difference("the control store", &e.imem[..], &u.imem[..]));
    if e.posted_write_errors != 0 {
        d.push(format!("word 225, the posted writes' errors, is {}", e.posted_write_errors));
    }
    d
}

/// The error halt a run may end at, as the trace's code.
fn halt_code(h: &Halt) -> Option<(u64, u8)> {
    match *h {
        Halt::OaOutsideFields { pc, .. } => Some((u64::from(pc), 1)),
        Halt::PdlFieldMismatch { pc, .. } => Some((u64::from(pc), 2)),
        _ => None,
    }
}

/// `micro` run to the park and 16 microcycles on, or to the stop the case
/// ends at.
fn micro(case: &Case, period: u64) -> Result<Micro, String> {
    let name = &case.name;
    let mut u = Micro::new(machine(case));
    u.period = period;
    u.oa_select_check = case.select_check;
    u.boot();
    let mut n = 0u64;
    while u64::from(u.machine().opc) != case.park {
        if n >= 400_000 {
            return Err(format!("{name} never reached its park on micro"));
        }
        if let Err(h) = u.step() {
            return match (halt_code(&h), case.halts) {
                (Some(a), Some(b)) if a == b => Ok(u),
                _ => Err(format!("{name} stopped on micro at microcycle {n}: {h:?}")),
            };
        }
        n += 1;
    }
    if case.halts.is_some() {
        return Err(format!("{name} reached its park on micro, not its stop"));
    }
    for _ in 0..16 {
        u.step().map_err(|h| format!("{name} stopped on micro at its park: {h:?}"))?;
    }
    Ok(u)
}

/// What a run shows: its trace's lines, its summary, and whether its
/// results were checked against `micro`.
struct Ran {
    lines: Vec<String>,
    summary: String,
}

/// **A run on the pipeline, a row a clock**: to the park's first commit,
/// then on until the memory side is quiet and 32 clocks more, or to the
/// error halt it ends at; its machine against `micro`'s, and its results.
fn run_case(case: &Case, period: u64, planted: Option<Mutation>) -> Result<Ran, (i32, String)> {
    let name = &case.name;
    let mut e = Pipeline::new(machine(case));
    e.configure(period, TIMING, CACHE_WORDS);
    if let Some(f) = planted {
        e.mutation = f;
    }
    let mut t = trace15::Trace15::start(&mut e);
    e.boot();
    let mut rows = vec![t.row(&e).line];
    let mut parked_at = None;
    let mut halted = false;
    loop {
        if let Some(at) = parked_at
            && e.clock() >= at + 32
            && e.quiet()
        {
            break;
        }
        if e.clock() >= 200_000 {
            return Err((1, format!("{name} never reached its park in 200,000 clocks")));
        }
        match e.tick() {
            Ok(()) => {}
            Err(h) => match (halt_code(&h), case.halts) {
                (Some((pc, code)), Some(want)) if (pc, code) == want => {
                    // The machine stops: the clock's row says so, and the
                    // trace ends.
                    rows.push(t.row_halting(&e, code).line);
                    parked_at = Some(e.clock());
                    halted = true;
                    break;
                }
                _ => return Err((1, format!("{name} stopped at clock {}: {h:?}", e.clock()))),
            },
        }
        let row = t.row(&e);
        if parked_at.is_none() && row.commit == Some(Some(case.park as u16)) {
            parked_at = Some(e.clock());
        }
        rows.push(row.line);
    }
    if case.halts.is_some() && !halted {
        return Err((1, format!("{name} reached its park, not the stop it ends at")));
    }
    // The machine it ends with, against micro's, and the results.
    let u = micro(case, period).map_err(|x| (1, x))?;
    let d = differences(e.machine(), u.machine());
    if !d.is_empty() {
        let mut x = d.join("; ");
        x.push_str(&format!("; {name}: the pipeline differs from micro in {} places", d.len()));
        return Err((3, x));
    }
    let mut bad = Vec::new();
    for (a, want, mask, what) in &case.results {
        let got = e.machine().amem[*a as usize];
        if got & mask != *want {
            bad.push(format!("A {a:o}, {what}: {got:#012x}, not {want:#012x}"));
        }
    }
    if !bad.is_empty() {
        return Err((1, format!("{name}: {} of {} results wrong: {}", bad.len(), case.results.len(), bad.join("; "))));
    }
    let mt = &e.meters;
    let summary = format!(
        "{name}: {} clocks, {} microcycles, {} results equal micro's, {} {:o} at clock {}; {} squashed, \
         mispredicted {:?}, {} guard holds, {} OA-hold clocks, {} PDL waits",
        e.clock() + 1,
        mt.retired,
        case.results.len(),
        if case.halts.is_some() { "stopped at" } else { "park" },
        case.halts.map_or(case.park, |(pc, _)| pc),
        parked_at.unwrap_or(0),
        mt.squashed,
        mt.mispredicted,
        mt.guard_hold,
        mt.oa_hold,
        mt.pdl_wait,
    );
    Ok(Ran { lines: rows, summary })
}

/// The runs a program name stands for: one, or a group's.
fn cases(name: &str, period: u64) -> Vec<Case> {
    match name {
        "matrix" => quux15_preset::matrix().into_iter().map(|(n, p)| p.case(&n)).collect(),
        "random" => (1..=quux15_preset::RANDOM_SEEDS)
            .map(|seed| quux15_preset::random_program(seed).case(&format!("seed-{seed}")))
            .collect(),
        "dispatch" => vec![quux15_preset::dispatches().case("dispatch")],
        "imem" => vec![quux15_preset::imem_program().case("imem")],
        "predict" => vec![quux15_preset::predict_program().case("predict")],
        _ => vec![Case::of_prog(name, &program(name, period))],
    }
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let given = args.iter().any(|a| a == "--machine");
    if given && machine_axis::take(&mut args) != Which::Quux {
        eprintln!("quux15: revision 15 is QUUX's; give --machine quux or no --machine");
        std::process::exit(2);
    }
    let (mut name, mut prom_only, mut planted, mut period) = (None, false, None, None);
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--program" => name = it.next(),
            "--prom" => prom_only = true,
            "--period" => {
                let v = it.next().unwrap_or_default();
                match v.parse::<u64>() {
                    Ok(p) if muir::clock::PERIOD_15_RANGE.contains(&p) => period = Some(p),
                    _ => {
                        eprintln!(
                            "quux15: --period is `{v}`; it is the period in units of 0.5 ns, {:?}",
                            muir::clock::PERIOD_15_RANGE
                        );
                        std::process::exit(2);
                    }
                }
            }
            "--mutation" => {
                let m = it.next().unwrap_or_default();
                let Some(f) = mutation(&m) else {
                    eprintln!("quux15: no fault `{m}` in muir::pipeline::Mutation");
                    std::process::exit(2);
                };
                planted = Some(f);
            }
            _ => {
                eprintln!("quux15: unknown argument `{a}`");
                std::process::exit(2);
            }
        }
    }
    let Some(name) = name else {
        eprintln!("usage: quux15 --program <name> --period <P> [--mutation <fault>] | --prom");
        std::process::exit(2);
    };
    // The PROM's image is one at every period: the time program's word 25
    // is a result, not a word of the program.
    let runs = cases(&name, period.unwrap_or(20));
    if prom_only {
        let prom = &runs[0].prom;
        for k in 0..PROM_WORDS {
            println!("{:016x}", prom.get(k).copied().unwrap_or(0));
        }
        return;
    }
    let Some(period) = period else {
        eprintln!("quux15: a trace is taken at a period: --period <P>, in units of 0.5 ns");
        std::process::exit(2);
    };
    let group = runs.len() > 1;
    let mut out = Vec::new();
    for case in &runs {
        let ran = match run_case(case, period, planted) {
            Ok(r) => r,
            Err((code, x)) => {
                eprintln!("quux15: {x}");
                std::process::exit(code);
            }
        };
        out.push(trace15::COLUMNS.to_string());
        out.push(format!(
            "# generated by golden/src/quux15.rs from muir's pipeline: program {name}, machine: quux, \
             revision 15, period {period} units of 0.5 ns ({}.{} ns), memory {:?}, cache {CACHE_WORDS} words{}",
            period / 2,
            if period % 2 == 1 { 5 } else { 0 },
            TIMING,
            planted.map_or(String::new(), |f| format!(", WITH THE PLANTED FAULT {f:?}"))
        ));
        if group {
            out.push(format!("# run {}", case.name));
        }
        out.push(trace15::RADIX.to_string());
        out.extend(case.images());
        out.extend(ran.lines);
        if !group {
            eprintln!("quux15: {}", ran.summary);
        }
    }
    if group {
        eprintln!("quux15: {name}: {} runs, each equal to micro's", runs.len());
    }
    let mut stdout = std::io::stdout().lock();
    for l in &out {
        use std::io::Write;
        writeln!(stdout, "{l}").expect("the trace is written");
    }
}
