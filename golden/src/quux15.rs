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
//!
//! **NOTHING IS PRESET**, as in `golden/src/quux14.rs`: every constant is
//! made by the program from the dispatch constant, and every data word is
//! written by the program.  **EACH PROGRAM SAYS WHAT IT REACHED**: its
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
mod trace15;

use machine_axis::Which;
use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::{
    ADD, ALU, ALWAYS, AND, BYTE, DISPATCH, DMEM_WRITE, DPB, HINT, INVERT, JUMP, LDB, MD, N, OA_HIGH_SELECT, P,
    POPJ, R, SETA, SETM, SETO, SETZ, SRC_MD, START_READ, START_WRITE, a_dest, a_src, filler, m_dest, m_src,
    src, target,
};
use muir::machine::{Geometry, Machine, PROM_WORDS, QUUX_PROM_BASE, Word};
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
}

impl Prog {
    fn new() -> Self {
        Prog { words: Vec::new(), results: Vec::new(), next_k: 0, park: None }
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

fn program(name: &str, period: u64) -> Prog {
    match name {
        "alu" => alu_program(),
        "transfer" => transfer_program(),
        "memory" => memory_program(),
        "time" => time_program(period),
        _ => {
            eprintln!("quux15: no program `{name}`; alu, transfer, memory or time");
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

/// The machine for `prom`: QUUX as the fabric builds it, at revision 15,
/// with QUUX's main memory.
fn machine(prom: &[Insn]) -> Machine {
    let mut m = Which::Quux.machine(prom);
    m.geometry = REV15;
    m.main = vec![0; MAIN];
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
    if e.posted_write_errors != 0 {
        d.push(format!("word 225, the posted writes' errors, is {}", e.posted_write_errors));
    }
    d
}

/// `micro` run to the park and 16 microcycles on.
fn micro(prom: &[Insn], period: u64, park: u64, name: &str) -> Micro {
    let mut u = Micro::new(machine(prom));
    u.period = period;
    u.boot();
    let mut n = 0u64;
    while u64::from(u.machine().opc) != park {
        assert!(n < 400_000, "quux15: {name} never reached its park on micro");
        if let Err(h) = u.step() {
            panic!("quux15: {name} stopped on micro at microcycle {n}: {h:?}");
        }
        n += 1;
    }
    for _ in 0..16 {
        u.step().unwrap_or_else(|h| panic!("quux15: {name} stopped on micro at its park: {h:?}"));
    }
    u
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
    let prog = program(&name, period.unwrap_or(20));
    let prom = prog.prom();
    if prom_only {
        for k in 0..PROM_WORDS {
            println!("{:016x}", prom.get(k).map_or(0, |w| w.raw()));
        }
        return;
    }
    let park = prog.park.expect("every program parks");
    let Some(period) = period else {
        eprintln!("quux15: a trace is taken at a period: --period <P>, in units of 0.5 ns");
        std::process::exit(2);
    };

    // The pipeline, a row a clock: to the park's first commit, then on until
    // the memory side is quiet and 32 clocks more.
    let mut e = Pipeline::new(machine(&prom));
    e.configure(period, TIMING, CACHE_WORDS);
    if let Some(f) = planted {
        e.mutation = f;
    }
    let mut t = trace15::Trace15::start(&mut e);
    e.boot();
    let mut rows = vec![t.row(&e).line];
    let mut parked_at = None;
    loop {
        if let Some(at) = parked_at
            && e.clock() >= at + 32
            && e.quiet()
        {
            break;
        }
        if e.clock() >= 200_000 {
            eprintln!("quux15: {name} never reached its park in 200,000 clocks");
            std::process::exit(1);
        }
        if let Err(h) = e.tick() {
            eprintln!("quux15: {name} stopped at clock {}: {h:?}", e.clock());
            std::process::exit(1);
        }
        let row = t.row(&e);
        if parked_at.is_none() && row.commit == Some(Some(park as u16)) {
            parked_at = Some(e.clock());
        }
        rows.push(row.line);
    }

    // The machine it ends with, against micro's, and the results.
    let u = micro(&prom, period, park, &name);
    let d = differences(e.machine(), u.machine());
    if !d.is_empty() {
        for x in &d {
            eprintln!("quux15: {name}: {x}");
        }
        eprintln!("quux15: {name}: the pipeline differs from micro in {} places", d.len());
        std::process::exit(3);
    }
    let mut bad = 0;
    for (a, want, mask, what) in &prog.results {
        let got = e.machine().amem[*a as usize];
        if got & mask != *want {
            eprintln!("quux15: {name}: A {a:o}, {what}: {got:#012x}, not {want:#012x}");
            bad += 1;
        }
    }
    if bad > 0 {
        eprintln!("quux15: {name}: {bad} of {} results wrong", prog.results.len());
        std::process::exit(1);
    }

    println!("{}", trace15::COLUMNS);
    println!(
        "# generated by golden/src/quux15.rs from muir's pipeline: program {name}, machine: quux, revision 15, \
         period {period} units of 0.5 ns ({}.{} ns), memory {:?}, cache {CACHE_WORDS} words{}",
        period / 2,
        if period % 2 == 1 { 5 } else { 0 },
        TIMING,
        planted.map_or(String::new(), |f| format!(", WITH THE PLANTED FAULT {f:?}"))
    );
    println!("{}", trace15::RADIX);
    for r in &rows {
        println!("{r}");
    }
    let mt = &e.meters;
    eprintln!(
        "quux15: {name}: {} clocks, {} microcycles, {} results equal micro's, park {:o} committed at clock {}; \
         {} squashed, mispredicted {:?}, {} OA-hold clocks, {} start waits, {} MD waits; {} words",
        e.clock() + 1,
        mt.retired,
        prog.results.len(),
        park,
        parked_at.unwrap_or(0),
        mt.squashed,
        mt.mispredicted,
        mt.oa_hold,
        mt.start_wait,
        mt.md_wait,
        prog.words.len(),
    );
}
