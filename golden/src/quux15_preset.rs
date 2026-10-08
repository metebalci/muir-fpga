// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's programs of muir's own kind**: words from control store
//! 0, the PROM's first word jumping there, A, M and dispatch memory preset,
//! as muir's `tests/revision_15_rtl.rs` builds its programs, written again
//! here for `golden/src/quux15.rs` to trace and `tb/quux15_core_tb.cpp` to
//! hold the core to.  A trace carries the presets as its `# image` lines,
//! which the testbench writes into the core's memories before its reset
//! ends, as a bitstream would hold them.
//!
//!   matrix    the speculation matrix: jump, call, POPJ, a conditional jump
//!             hinted each way and taken each way, a dispatch of each entry
//!             under each prediction, and an SL jump, each with N and
//!             without, and a dispatch's return under N with LPC, with a
//!             delay slot of each kind but a start or `MAP(MD)`, which wait
//!             for the memory side (muir's
//!             `the_speculation_matrix_ends_as_on_micro`)
//!   random    programs at random that keep MIT's microcode rules (muir's
//!             `random_program`), without memory starts: data words,
//!             forward jumps hinted at random, calls, dispatches predicted
//!             each way, data pushes and pops, the PDL address field, the OA
//!             selects, MUL and DIV, dispatch-memory writes
//!   dispatch  dispatches predicted as each of A15b.2's rows, right and wrong
//!             (muir's `dispatches_predicted_each_way_end_as_on_micro`)
//!   predict   a dispatch predicted at its entry's address with another P or
//!             R, which EX's check of P and R squashes and restores
//!   imem      WRITE-I-MEM in MIT's form: words written and run later
//!   imemorder WRITE-I-MEM going on at the word after it in execution
//!             order: the word right after it written, the word two after
//!             it, and in a jump's delay slot another word and the target
//!
//! Each run ends at the stop, a jump to itself at 1000, and its machine
//! must end as `micro`'s; these programs leave no results of their own.

use muir::isa::Insn;
use muir::isa::asm::{
    ADD, ALU, ALWAYS, AND, DISPATCH, HINT, IOR, JUMP, LDB, N, OA_HIGH_SELECT, OA_LOW_SELECT, P,
    POPJ, Q_LOAD, R, SETA, SETM, XOR, a_dest, a_src, filler, m_dest, m_src, predicted, src, target,
};
use muir::machine::Word;

use super::Case;

/// A memory's constants 0 and 1, and M memory's.
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;
const M_ONE: u64 = 0o35;

/// The program's last word, a jump to itself.
const STOP: u64 = 0o1000;

/// How many random programs `random` runs.
pub const RANDOM_SEEDS: u64 = 200;

/// A functional destination, M 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}

/// A BYTE word.
fn byte(func: u64, rotate: u64, len: u64) -> u64 {
    muir::isa::asm::BYTE | func | (len - 1) << 6 | rotate
}

/// A JUMP on condition `code`, `IR<4:0>` with `IR<5>`.
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// A DISPATCH at `IR<23:12>`, no bits of M.
fn disp(addr: u64) -> u64 {
    DISPATCH | addr << 12
}

/// A program: 64-bit words from control store 0, and the A, M and dispatch
/// memories' words.
#[derive(Default, Clone)]
pub struct Preset {
    pub(crate) words: Vec<u64>,
    pub(crate) amem: Vec<(u64, Word)>,
    pub(crate) mmem: Vec<(u64, Word)>,
    pub(crate) dmem: Vec<(usize, u32)>,
    next_a: u64,
    /// `micro`'s OA select check; off for the matrix, as in muir's test.
    pub(crate) select_check: bool,
    /// Main memory's presets, the seeded memory model, and -RESET's sweep
    /// taken as done (the memory side's programs, `quux15_memside.rs`).
    pub main: Vec<(usize, Word)>,
    pub late: Option<muir::pipeline::port::LateModel>,
    pub skip_sweep: bool,
    pub beyond_micro: Vec<(usize, Word)>,
}

impl Preset {
    pub(crate) fn new() -> Self {
        Preset { select_check: true, ..Preset::default() }
    }
    pub(crate) fn op(&mut self, w: u64) -> &mut Self {
        self.words.push(w);
        self
    }
    pub(crate) fn at(&self) -> u64 {
        self.words.len() as u64
    }
    pub(crate) fn fill(&mut self, n: usize) -> &mut Self {
        for _ in 0..n {
            self.op(filler().raw());
        }
        self
    }
    pub(crate) fn fill_to(&mut self, to: u64) -> &mut Self {
        while self.at() < to {
            self.fill(1);
        }
        self
    }
    /// An A-memory constant, from 101 up: its address.
    pub(crate) fn k(&mut self, v: Word) -> u64 {
        let a = 0o101 + self.next_a;
        assert!(a < 0o1700, "A memory's constants run into the scratch words");
        self.next_a += 1;
        self.amem.push((a, v));
        a
    }
    /// M `slot` <- the A constant `v`.
    pub(crate) fn set(&mut self, v: Word, slot: u64) -> &mut Self {
        let a = self.k(v);
        self.op(ALU | SETA | a_src(a) | m_dest(slot))
    }
    /// Jumps to the stop.
    pub(crate) fn stop(&mut self) -> &mut Self {
        self.op(JUMP | target(STOP) | ALWAYS | N);
        self.op(filler().raw())
    }

    /// **The run** (muir's tests' `machine`): the words in the control store
    /// from 0, fillers to the stop at 1000, the PROM's first word a jump to 0;
    /// A 40 and 41 zero and one, M 34 and 35 too; the presets.
    pub fn case(&self, name: &str) -> Case {
        assert!(self.words.len() <= STOP as usize, "the program runs into its stop");
        let mut imem: Vec<(usize, u64)> = self.words.iter().copied().enumerate().collect();
        for k in self.words.len()..STOP as usize {
            imem.push((k, filler().raw()));
        }
        imem.push((STOP as usize, Insn::new(JUMP | target(STOP) | ALWAYS | N).raw()));
        let mut amem = vec![(ZERO as usize, 0), (ONE as usize, 1)];
        let mut mmem = Vec::new();
        for (k, v) in [(M_ZERO, 0), (M_ONE, 1)] {
            mmem.push((k as usize, v));
            amem.push((k as usize, v));
        }
        amem.extend(self.amem.iter().map(|&(a, v)| (a as usize, v)));
        for &(k, v) in &self.mmem {
            mmem.push((k as usize, v));
            amem.push((k as usize, v));
        }
        Case {
            name: name.to_string(),
            prom: vec![Insn::new(JUMP | target(0) | ALWAYS | N).raw()],
            imem,
            amem,
            mmem,
            dmem: self.dmem.clone(),
            park: STOP,
            halts: None,
            select_check: self.select_check,
            results: Vec::new(),
            main: self.main.clone(),
            late: self.late,
            skip_sweep: self.skip_sweep,
            beyond_micro: self.beyond_micro.clone(),
        }
    }
}

// --- Programs made at random, rule-abiding -----------------------------------

/// A fixed sequence of numbers per seed: xorshift64*.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0.max(1);
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 16
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn chance(&mut self, k: u64, of: u64) -> bool {
        self.below(of) < k
    }
}

/// The subroutines' addresses.
const SUBS: [u64; 4] = [0o700, 0o720, 0o740, 0o760];

/// **A program at random** that keeps MIT's microcode rules, so that `micro`
/// and the pipeline must end alike (muir's `random_program` with every
/// feature): forward branches only, calls to subroutines that return.  With
/// `memory` clear, the constructs that start memory cycles are data words
/// instead, slice 2's start-free programs; set, they are muir's: a read and
/// `MD` two words after it at the soonest, a write, a register's read, a
/// start that faults and its check, and two starts in a row.
pub fn random_program(seed: u64, memory: bool) -> Preset {
    use muir::isa::asm::{MD, SRC_MD, START_READ, START_WRITE};
    const PHYS: Word = 0o36000000000;
    const REGISTER_PAGE: Word = 0o35777777400;
    let mut rng = Rng(seed);
    let mut p = Preset::new();
    p.skip_sweep = memory;
    // Scratch: M 20-27, A 1700-1707; constants in A 101 up.
    let consts: Vec<u64> = (0..8).map(|k| p.k(rng.next() & 0o7777777777 | (k << 32))).collect();
    for (k, &c) in consts.iter().enumerate().take(4) {
        p.op(ALU | SETA | a_src(c) | m_dest(0o20 + k as u64));
    }
    // The PDL buffer's registers somewhere in its middle.
    let pdl_base = p.k(0o1000);
    p.op(ALU | SETA | a_src(pdl_base) | fd(0o14));
    p.op(ALU | SETA | a_src(pdl_base) | fd(0o13));
    let body_end = 0o600;
    let funcs = [ADD, muir::isa::asm::SUB, AND, IOR, XOR, SETA, SETM];
    let m_srcs = |rng: &mut Rng| -> u64 {
        match rng.below(10) {
            0 => src(0o7),  // Q
            1 => src(0o3),  // PDL-INDEX
            2 => src(0o2),  // the PDL pointer
            3 => src(0o5),  // PDL by the index
            4 => src(0o25), // PDL by the pointer
            5 => src(0o24), // pop
            6 => src(0o10), // VMA
            _ => m_src(0o20 + rng.below(8)),
        }
    };
    let a_srcs = |rng: &mut Rng| -> u64 {
        if rng.chance(1, 2) { a_src(0o1700 + rng.below(8)) } else { a_src(consts[rng.below(8) as usize]) }
    };
    let dests = |rng: &mut Rng| -> u64 {
        match rng.below(12) {
            0 => fd(0o11),             // PDL push
            1 => fd(0o10),             // PDL top
            2 => fd(0o12),             // PDL by the index
            3 => fd(0o13) | 0o1 << 14, // PDL-INDEX, M 1
            4 => fd(0o20),             // VMA
            5 | 6 => a_dest(0o1700 + rng.below(8)),
            _ => m_dest(0o20 + rng.below(8)),
        }
    };
    let data = |rng: &mut Rng, p: &mut Preset| {
        let w = if rng.chance(1, 4) {
            byte(if rng.chance(1, 2) { LDB } else { muir::isa::asm::DPB }, rng.below(40), 1 + rng.below(39))
                | m_srcs(rng)
                | a_srcs(rng)
                | dests(rng)
        } else {
            ALU | funcs[rng.below(funcs.len() as u64) as usize]
                | m_srcs(rng)
                | a_srcs(rng)
                | dests(rng)
                | if rng.chance(1, 8) { Q_LOAD } else { 0 }
        };
        p.op(w);
    };
    let mut table = 0o200usize;
    let mut last_transfer = false;
    let mut boundaries = Vec::new();
    let mut jumps = Vec::new();
    let mut entries = Vec::new();
    let mut constants = Vec::new();
    while p.at() < body_end - 24 {
        let here = p.at();
        boundaries.push(here);
        let kind = rng.below(25);
        let fwd = |rng: &mut Rng| here + 3 + rng.below(8);
        match kind {
            // A conditional jump forward, hinted at random, N or not.
            0..=2 if !last_transfer => {
                let cond = match rng.below(4) {
                    0 => 1 << 5 | 3,
                    1 => 1 << 5 | 1,
                    2 => 1 << 5 | 2,
                    _ => rng.below(40) & 0o37,
                };
                let hint = if rng.chance(1, 2) { HINT } else { 0 };
                let n = if rng.chance(1, 2) { N } else { 0 };
                jumps.push(p.words.len());
                p.op(JUMP | cond | m_srcs(&mut rng) | a_srcs(&mut rng) | target(fwd(&mut rng)) | hint | n);
                last_transfer = true;
                continue;
            }
            // A call, a jump.
            3 if !last_transfer => {
                let sub = SUBS[rng.below(4) as usize];
                let n = if rng.chance(1, 2) { N } else { 0 };
                p.op(JUMP | ALWAYS | P | target(sub) | n);
                last_transfer = true;
                continue;
            }
            4 if !last_transfer => {
                let n = if rng.chance(1, 2) { N } else { 0 };
                jumps.push(p.words.len());
                p.op(JUMP | ALWAYS | target(fwd(&mut rng)) | n);
                last_transfer = true;
                continue;
            }
            // A dispatch on M's low two bits into a table of four.
            5 if !last_transfer => {
                for k in 0..4 {
                    let e = match rng.below(4) {
                        0 => 1 << 16 | 1 << 15,
                        1 => fwd(&mut rng) as u32,
                        2 => SUBS[rng.below(4) as usize] as u32 | 1 << 15,
                        _ => fwd(&mut rng) as u32 | 1 << 14,
                    };
                    if e & 1 << 15 == 0 {
                        entries.push(p.dmem.len());
                    }
                    p.dmem.push((table + k, e));
                }
                let pr = match rng.below(5) {
                    0 => predicted(0, false, false),
                    1 => predicted(fwd(&mut rng), false, false),
                    2 => predicted(SUBS[rng.below(4) as usize], true, false),
                    3 => predicted(0o777, false, false),
                    _ => 0,
                };
                p.op(disp(table as u64) | 2 << 5 | m_src(0o20 + rng.below(8)) | pr);
                table += 4;
                last_transfer = true;
                continue;
            }
            // A read: its start, a word, then MD.
            6 if !last_transfer && memory => {
                let a = p.k(PHYS | rng.below(64));
                p.op(ALU | SETA | a_src(a) | START_READ);
                data(&mut rng, &mut p);
                if rng.chance(1, 2) {
                    data(&mut rng, &mut p);
                }
                p.op(ALU | SETM | SRC_MD | m_dest(0o20 + rng.below(8)));
            }
            // A write: MD, its start, two words.
            7 if !last_transfer && memory => {
                let a = p.k(PHYS | rng.below(64));
                p.op(ALU | SETM | m_src(0o20 + rng.below(8)) | MD);
                p.op(ALU | SETA | a_src(a) | START_WRITE);
                data(&mut rng, &mut p);
                data(&mut rng, &mut p);
            }
            // A return address pushed as data, and a POPJ to it.
            8 if !last_transfer => {
                let k = rng.below(3);
                let popj_at = here + 1 + k;
                let to = popj_at + 2 + rng.below(3);
                let a = p.k(to);
                p.op(ALU | SETA | a_src(a) | fd(0o15));
                for _ in 0..k {
                    data(&mut rng, &mut p);
                }
                p.op(ALU | ADD | a_src(ONE) | m_src(0o27) | m_dest(0o27) | POPJ);
                data(&mut rng, &mut p);
                while p.at() < to {
                    p.fill(1);
                }
            }
            // A word pushed as data and popped by the functional source.
            9 if !last_transfer => {
                p.op(ALU | SETM | m_src(0o20 + rng.below(8)) | fd(0o15));
                if rng.chance(1, 2) {
                    data(&mut rng, &mut p);
                }
                p.op(ALU | SETM | src(0o14) | m_dest(0o20 + rng.below(8)));
            }
            // The PDL address field: PDL-INDEX <- the pointer or the index
            // plus a constant, read through at once.
            10 if !last_transfer => {
                let d = rng.below(40) as i64 - 20;
                let a = p.k((d as u64) & 0o377777777777);
                let (base, m) = if rng.chance(1, 2) { (2, src(0o2)) } else { (3, src(0o3)) };
                p.op(ALU | ADD | m | a_src(a) | fd(0o13) | muir::isa::asm::pdl_field(base, d as i8));
                p.op(ALU | SETM | src(0o5) | m_dest(0o20 + rng.below(8)));
            }
            // OA-REG-HIGH and a word that selects it into its sources.
            11 if !last_transfer => {
                let (aoff, moff) = (rng.below(8), rng.below(8));
                let a = p.k(aoff << 6 | moff);
                p.op(ALU | SETA | a_src(a) | fd(0o17));
                p.op(ALU | ADD | a_src(0o1700) | m_src(0o20) | m_dest(0o20 + rng.below(8)) | OA_HIGH_SELECT);
            }
            // OA-REG-LOW and a jump that takes its target from it.
            12 if !last_transfer => {
                let to = here + 4 + rng.below(6);
                let a = p.k(to << 12);
                constants.push((p.amem.len() - 1, 12));
                p.op(ALU | SETA | a_src(a) | fd(0o16));
                p.op(JUMP | ALWAYS | target(0) | if rng.chance(1, 2) { N } else { 0 } | OA_LOW_SELECT);
                last_transfer = true;
                continue;
            }
            // MUL and DIV.
            13 => {
                let f = if rng.chance(1, 2) { 0o42 << 3 } else { 0o43 << 3 };
                p.op(ALU | f | m_srcs(&mut rng) | a_srcs(&mut rng) | m_dest(0o20 + rng.below(8)));
            }
            // A register's read: MACHINE-ID, the microsecond clock's
            // feature word.
            14 if !last_transfer && memory => {
                let a = p.k(REGISTER_PAGE | if rng.chance(1, 2) { 0 } else { 0o14 });
                p.op(ALU | SETA | a_src(a) | START_READ);
                data(&mut rng, &mut p);
                p.op(ALU | SETM | SRC_MD | m_dest(0o20 + rng.below(8)));
            }
            // A start that faults, and the check right after it.
            15 if !last_transfer && memory => {
                let a = p.k(0o1000 + rng.below(64));
                let start = if rng.chance(1, 2) { START_READ } else { START_WRITE };
                if start == START_WRITE {
                    p.op(ALU | SETM | m_src(0o20) | MD);
                }
                p.op(ALU | SETA | a_src(a) | start);
                let n = if rng.chance(1, 2) { N } else { 0 };
                p.op(jcond(4) | P | target(SUBS[rng.below(4) as usize]) | n);
                last_transfer = true;
                continue;
            }
            // Two starts in a row: the second held until the first is
            // acknowledged.
            17 if !last_transfer && memory => {
                let (a, b) = (p.k(PHYS | rng.below(64)), p.k(PHYS | rng.below(64)));
                let first = if rng.chance(1, 2) { START_READ } else { START_WRITE };
                if first == START_WRITE {
                    p.op(ALU | SETM | m_src(0o20 + rng.below(8)) | MD);
                }
                p.op(ALU | SETA | a_src(a) | first);
                p.op(ALU | SETA | a_src(b) | START_READ);
                data(&mut rng, &mut p);
                p.op(ALU | SETM | SRC_MD | m_dest(0o20 + rng.below(8)));
            }
            // A dispatch-memory write, and a dispatch that reads it next.
            16 if !last_transfer => {
                let entry = if rng.chance(1, 2) { 1 << 16 | 1 << 15 } else { (here + 4 + rng.below(4)) as u32 };
                let a = p.k(entry as u64);
                if entry & 1 << 15 == 0 {
                    constants.push((p.amem.len() - 1, 0));
                }
                // A drop-through until written, for a branch past the write.
                p.dmem.push((table, 1 << 16 | 1 << 15));
                p.op(DISPATCH | muir::isa::asm::DMEM_WRITE | a_src(a) | (table as u64) << 12);
                p.op(disp(table as u64));
                table += 1;
                last_transfer = true;
                continue;
            }
            _ => data(&mut rng, &mut p),
        }
        last_transfer = false;
    }
    boundaries.push(p.at());
    while p.at() < body_end {
        p.fill(1);
    }
    p.op(ALU | SETA | a_src(ZERO) | m_dest(0o30));
    p.stop();
    // Forward targets moved to the next construct's first word.
    let to = |t: u64| boundaries.iter().copied().find(|&b| b >= t).unwrap_or(body_end);
    for k in jumps {
        let t = p.words[k] >> 12 & 0o37777;
        p.words[k] = p.words[k] & !(0o37777 << 12) | target(to(t));
    }
    for k in entries {
        let (adr, e) = p.dmem[k];
        p.dmem[k] = (adr, e & !0o37777 | to(u64::from(e & 0o37777)) as u32);
    }
    for (k, shift) in constants {
        let (adr, v) = p.amem[k];
        let t = (v >> shift) & 0o37777;
        p.amem[k] = (adr, v & !(0o37777 << shift) | to(t) << shift);
    }
    // The subroutines: a few words, POPJ after the next.
    for &sub in &SUBS {
        p.fill_to(sub);
        for _ in 0..rng.below(5) {
            data(&mut rng, &mut p);
        }
        match rng.below(4) {
            // A conditional return, hinted at random; then the POPJ.
            0 => {
                let hint = if rng.chance(1, 2) { HINT } else { 0 };
                p.op(jcond(rng.below(40) & 0o37)
                    | m_src(0o20 + rng.below(8))
                    | R
                    | hint
                    | if rng.chance(1, 2) { N } else { 0 });
                data(&mut rng, &mut p);
            }
            // A dispatch whose entries return or drop through.
            1 => {
                for k in 0..4 {
                    p.dmem.push((table + k, if rng.chance(1, 2) { 1 << 16 } else { 1 << 16 | 1 << 15 }));
                }
                let pr = if rng.chance(1, 2) { predicted(0, false, true) } else { 0 };
                p.op(disp(table as u64) | 2 << 5 | m_src(0o20 + rng.below(8)) | pr);
                table += 4;
                data(&mut rng, &mut p);
            }
            _ => {}
        }
        p.op(ALU | ADD | a_src(ONE) | m_src(0o27) | m_dest(0o27) | POPJ);
        data(&mut rng, &mut p);
    }
    p
}

// --- The speculation matrix -------------------------------------------------

/// The delay slot's kinds in the matrix: `matrix`'s seven, and
/// `matrixmem`'s two that wait for the memory side, a start and `MAP(MD)`.
#[derive(Clone, Copy, Debug)]
enum SlotKind {
    Plain,
    Popj,
    Call,
    Push,
    Pop,
    OaWrite,
    Transfer,
    Start,
    MapMd,
}

const SLOTS: [SlotKind; 7] =
    [SlotKind::Plain, SlotKind::Popj, SlotKind::Call, SlotKind::Push, SlotKind::Pop, SlotKind::OaWrite, SlotKind::Transfer];
const SLOTS_MEMORY: [SlotKind; 2] = [SlotKind::Start, SlotKind::MapMd];

/// The branch's kinds in the matrix.
#[derive(Clone, Copy, Debug)]
enum Branch {
    Jump,
    Call,
    Popj,
    Conditional { hint: bool, taken: bool },
    Dispatch { entry: u32, predicted: (u64, bool, bool) },
    Sl,
}

/// Where the matrix's pieces sit: the case at 100, its target at 200, a
/// subroutine at 300, the slot's call at 340, the landing at 400.
const CASE: u64 = 0o100;
const TARGET: u64 = 0o200;
const SUB: u64 = 0o300;
const SLOT_SUB: u64 = 0o340;
const LANDING: u64 = 0o400;

/// One case: the driver calls the case (so that a POPJ has somewhere to
/// go), the case's branch and its delay slot, markers counting in M 20-27
/// on each path.
fn matrix_case(branch: Branch, n: bool, slot: SlotKind, lpc: bool) -> Preset {
    let mut p = Preset::new();
    p.select_check = false;
    let mark = |m: u64| ALU | ADD | a_src(ONE) | m_src(m) | m_dest(m);
    let nb = if n { N } else { 0 };
    let (pdl, here) = (p.k(0o2000), p.k(0o1000));
    // Spare returns to the landing, for the paths that pop more than they
    // push.
    let landing = p.k(LANDING);
    for _ in 0..4 {
        p.op(ALU | SETA | a_src(landing) | fd(0o15));
    }
    p.op(ALU | SETA | a_src(pdl) | fd(0o14));
    p.op(ALU | SETA | a_src(pdl) | fd(0o13));
    p.op(ALU | SETA | a_src(here) | muir::isa::asm::MD);
    // The driver: call the case; the case's paths come back to the landing.
    p.op(JUMP | ALWAYS | P | N | target(CASE - 1));
    p.fill(1);
    p.op(mark(0o27));
    p.op(JUMP | ALWAYS | N | target(LANDING));
    p.fill(1);
    p.fill_to(CASE);
    let oa = p.k(1 << 6 | 1);
    let to = p.k(TARGET << 12);
    if matches!(branch, Branch::Sl) {
        // SL's writer, right before the jump.
        let _ = p.words.pop();
        p.op(ALU | SETA | a_src(to) | fd(0o16));
    }
    match branch {
        Branch::Jump => p.op(JUMP | ALWAYS | target(TARGET) | nb),
        Branch::Call => p.op(JUMP | ALWAYS | P | target(SUB) | nb),
        Branch::Popj => p.op(mark(0o20) | POPJ),
        Branch::Conditional { hint, taken } => {
            let m = if taken { M_ZERO } else { M_ONE };
            p.op(jcond(3) | m_src(m) | a_src(ZERO) | target(TARGET) | nb | if hint { HINT } else { 0 })
        }
        Branch::Dispatch { entry, predicted: (addr, pp, rr) } => {
            p.dmem.push((0o100, entry | if n { 1 << 14 } else { 0 }));
            p.op(disp(0o100) | predicted(addr, pp, rr) | if lpc { 1 << 25 } else { 0 })
        }
        Branch::Sl => p.op(JUMP | ALWAYS | target(0) | nb | OA_LOW_SELECT),
    };
    // The delay slot.
    match slot {
        SlotKind::Plain => p.op(mark(0o21)),
        SlotKind::Popj => p.op(mark(0o21) | POPJ),
        SlotKind::Call => p.op(JUMP | ALWAYS | P | target(SLOT_SUB) | N),
        SlotKind::Push => p.op(ALU | SETA | a_src(here) | fd(0o15)),
        SlotKind::Pop => p.op(ALU | SETM | src(0o14) | m_dest(0o26)),
        SlotKind::OaWrite => p.op(ALU | SETA | a_src(oa) | fd(0o17)),
        SlotKind::Transfer => p.op(JUMP | ALWAYS | N | target(TARGET + 4)),
        SlotKind::Start => {
            let a = p.k(0o36000000010);
            p.op(ALU | SETA | a_src(a) | muir::isa::asm::START_READ)
        }
        SlotKind::MapMd => p.op(ALU | SETM | src(0o11) | m_dest(0o26)),
    };
    // The fall-through: a selecting word when the slot writes OA-REG-HIGH.
    let select = if matches!(slot, SlotKind::OaWrite) { OA_HIGH_SELECT } else { 0 };
    p.op(ALU | ADD | a_src(0o1700) | m_src(0o22) | m_dest(0o22) | select);
    p.op(mark(0o23) | POPJ);
    p.fill(1);
    p.fill_to(TARGET);
    // The target: a selecting word too.
    p.op(ALU | ADD | a_src(0o1700) | m_src(0o24) | m_dest(0o24) | select);
    p.op(mark(0o25) | POPJ);
    p.fill(2);
    p.op(mark(0o25) | POPJ);
    p.fill(1);
    let two = p.k(2);
    p.fill_to(SUB);
    // The subroutine: out to the landing the second time, for a return
    // under N with LPC, which comes back to its call.
    p.op(mark(0o20));
    p.op(jcond(3) | m_src(0o20) | a_src(two) | target(LANDING) | N);
    p.fill(1);
    p.op(filler().raw() | POPJ);
    p.fill(1);
    p.fill_to(SLOT_SUB);
    p.op(mark(0o26));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    p.fill_to(LANDING);
    p.op(mark(0o27));
    p.stop();
    p
}

/// Every case of the matrix, but its starts', each named.
pub fn matrix() -> Vec<(String, Preset)> {
    matrix_of(&SLOTS)
}

/// The matrix's cases with a start or `MAP(MD)` in the delay slot, -RESET's
/// sweep taken as done, as muir's test takes it.
pub fn matrix_memory() -> Vec<(String, Preset)> {
    let mut cases = matrix_of(&SLOTS_MEMORY);
    for (_, p) in &mut cases {
        p.skip_sweep = true;
    }
    cases
}

fn matrix_of(slots: &[SlotKind]) -> Vec<(String, Preset)> {
    let mut cases = Vec::new();
    let entries =
        [(TARGET as u32, "jump"), (SUB as u32 | 1 << 15, "call"), (1 << 16, "return"), (1 << 16 | 1 << 15, "drop")];
    let predictions = [
        ((0, true, true), "drop"),
        ((TARGET, false, false), "jump"),
        ((SUB, true, false), "call"),
        ((0, false, true), "return"),
        ((0o777, false, false), "elsewhere"),
    ];
    for &slot in slots {
        for n in [false, true] {
            let mut branches = vec![
                (Branch::Jump, "jump".to_string()),
                (Branch::Call, "call".into()),
                (Branch::Popj, "popj".into()),
                (Branch::Sl, "sl".into()),
            ];
            for hint in [false, true] {
                for taken in [false, true] {
                    branches.push((Branch::Conditional { hint, taken }, format!("cond-h{}-t{}", hint as u8, taken as u8)));
                }
            }
            for (entry, e) in entries {
                for (pr, pn) in predictions {
                    branches.push((Branch::Dispatch { entry, predicted: pr }, format!("disp-{e}-as-{pn}")));
                }
            }
            for (b, what) in branches {
                for lpc in [false, true] {
                    if lpc && !matches!(b, Branch::Dispatch { entry, .. } if entry & 1 << 15 != 0) {
                        continue;
                    }
                    let name = format!(
                        "{what}-n{}{}-{}",
                        n as u8,
                        if lpc { "-lpc" } else { "" },
                        format!("{slot:?}").to_lowercase()
                    );
                    cases.push((name, matrix_case(b, n, slot, lpc)));
                }
            }
        }
    }
    cases
}

/// **Dispatches predicted as each of A15b.2's rows** (muir's
/// `dispatches_predicted_each_way_end_as_on_micro`): entries that jump,
/// call, drop through and return, each under each prediction, right and
/// wrong by address, by P and by R.
pub fn dispatches() -> Preset {
    let mut p = Preset::new();
    let sub = 0o600;
    let jump_to = 0o640;
    let back = 0o660;
    p.dmem.push((0o100, jump_to as u32));
    p.dmem.push((0o101, sub as u32 | 1 << 15));
    p.dmem.push((0o102, 1 << 16 | 1 << 15));
    p.dmem.push((0o103, 1 << 16));
    p.dmem.push((0o104, back as u32 | 1 << 14));
    p.set(0, 0o20);
    let preds = [(0u64, false, false), (jump_to, false, false), (sub, true, false), (0, true, true), (0, false, true), (0o777, false, false)];
    for (k, &(addr, pp, rr)) in preds.iter().enumerate() {
        for entry in 0o100..=0o102u64 {
            p.op(disp(entry) | predicted(addr, pp, rr));
            p.op(ALU | ADD | a_src(ONE) | m_src(0o20) | m_dest(0o20));
            if entry == 0o100 {
                p.dmem.push((0o110 + k, p.at() as u32));
            }
        }
    }
    p.stop();
    p.fill_to(sub);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o21) | m_dest(0o21) | POPJ);
    p.fill(1);
    p.fill_to(jump_to);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o22) | m_dest(0o22));
    p.op(JUMP | ALWAYS | N | target(STOP));
    p.fill(1);
    p
}

/// **A dispatch predicted at its entry's address with another P or R**
/// (A15b.2): an entry that jumps to X predicted as a call of X, and one
/// that calls X predicted as a jump to X.  The address is right and the
/// prediction wrong all the same: RD's copy of the micro stack took a push
/// the entry does not make, or missed one it does, and EX's check of P and
/// R squashes and restores it.  At X a POPJ, which RD resolves from that
/// copy.
pub fn predict_program() -> Preset {
    use muir::isa::asm::predicted;
    let mut p = Preset::new();
    let (x1, x2, y1, y2) = (0o300, 0o320, 0o400, 0o420);
    p.dmem.push((0o100, x1 as u32));
    p.dmem.push((0o101, x2 as u32 | 1 << 15));
    p.set(0, 0o20);
    // Call Y1, which dispatches through the jump predicted as a call.
    p.op(JUMP | ALWAYS | P | N | target(y1));
    p.op(ALU | ADD | a_src(ONE) | m_src(0o20) | m_dest(0o20));
    // Call Y2, which dispatches through the call predicted as a jump.
    p.op(JUMP | ALWAYS | P | N | target(y2));
    p.op(ALU | ADD | a_src(ONE) | m_src(0o20) | m_dest(0o20));
    p.stop();
    // X1: count, and return to the caller of Y1.
    p.fill_to(x1);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o21) | m_dest(0o21) | POPJ);
    p.fill(1);
    // X2: count, return to Y2's dispatch, which returns to its caller.
    p.fill_to(x2);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o22) | m_dest(0o22) | POPJ);
    p.fill(1);
    p.fill_to(y1);
    p.op(disp(0o100) | predicted(x1, true, false));
    p.fill(1);
    p.fill_to(y2);
    p.op(disp(0o101) | predicted(x2, false, false));
    p.fill(1);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o23) | m_dest(0o23) | POPJ);
    p.fill(1);
    p
}

/// **WRITE-I-MEM** (A15b.4), in MIT's form: a JUMP with P, R and N,
/// unconditional, `IR<9:0>` 1647, writes the control store at its address
/// from IWR, A's `<31:0>` over M's, pushes and pops the micro stack as the
/// CADR does, and the words behind it are fetched again.  Two words written
/// and each run later, called with N and without.
pub fn imem_program() -> Preset {
    let mut p = Preset::new();
    let word = |w: u64| (w >> 32, w & 0xffff_ffff);
    // The word written at 500: M 21 + 1, and back to the caller.
    let later = ALU | ADD | a_src(ONE) | m_src(0o21) | m_dest(0o21) | POPJ;
    let (hi, lo) = word(later);
    let ka = p.k(hi);
    p.set(lo, 0o20);
    p.op(write_i_mem(0o500) | a_src(ka) | m_src(0o20));
    p.fill(1);
    // At 510: M 22 + 1, and back.
    let other = ALU | ADD | a_src(ONE) | m_src(0o22) | m_dest(0o22) | POPJ;
    let (hi, lo) = word(other);
    let ka = p.k(hi);
    p.set(lo, 0o23);
    p.op(write_i_mem(0o510) | a_src(ka) | m_src(0o23));
    p.fill(1);
    // Run each word written, with N and without.
    for at in [0o500, 0o510] {
        p.op(JUMP | ALWAYS | P | N | target(at));
        p.fill(1);
        p.op(JUMP | ALWAYS | P | target(at));
        p.fill(2);
    }
    p.stop();
    p.fill_to(0o500);
    p.fill(2);
    p.fill_to(0o510);
    p.fill(2);
    p
}

/// A WRITE-I-MEM of the control store's word `at`, in MIT's form: R, P, N,
/// unconditional, not inverted, `IR<9:0>` 1647 (`cadsym.lisp`'s
/// `WRITE-I-MEM`, whose `JUMP-OP` carries N).
fn write_i_mem(at: u64) -> u64 {
    JUMP | P | R | N | ALWAYS | target(at)
}

/// **WRITE-I-MEM goes on at the word after it in execution order**
/// (A15b.3, A15b.4; muir's
/// `write_i_mem_goes_on_at_the_word_after_it_in_execution_order` and
/// `row_a_word_written_by_write_i_mem_runs_as_written`), each in MIT's form:
///
///   next          a write of the word right after it: the new word runs,
///                 fetched again in the clock the store is written (the
///                 store's forward, under the RAM's poison)
///   two-ahead     a write of the word two after it, already fetched: the
///                 new word runs
///   slot-other-micro-unchecked
///                 in a jump's delay slot, a write of another word: the
///                 machine goes on at the jump's target
///   slot-target-micro-unchecked
///                 in a jump's delay slot, a write of the jump's target: the
///                 target's new word runs
///
/// **THE TWO DELAY-SLOT RUNS ARE TAKEN WITH `micro`'S CHECKS OFF** (the
/// case's `select_check`, `micro`'s `oa_select_check`): `micro`'s
/// WRITE-I-MEM check refuses a write run as a delay slot, which only a word
/// written at run time can make, as muir's own test runs `micro` unchecked
/// for them.  The OA select check goes off with it; neither run selects.
pub fn imem_order() -> Vec<(String, Preset)> {
    let inc = |m: u64| ALU | ADD | a_src(ONE) | m_src(m) | m_dest(m);
    let word = inc(0o22);
    let wim = |p: &mut Preset, at: u64| {
        let hi = p.k(word >> 32);
        p.mmem.push((0o30, word & 0xffff_ffff));
        p.op(write_i_mem(at) | a_src(hi) | m_src(0o30));
    };
    let mut v = Vec::new();
    // The word right after it.
    let mut p = Preset::new();
    let at = p.at() + 1;
    wim(&mut p, at);
    p.op(inc(0o21));
    p.fill(1);
    p.stop();
    v.push(("next".to_string(), p));
    // The word two after it.
    let mut p = Preset::new();
    let (old, new) = (p.k(0o1111), p.k(0o2222));
    let at = p.at() + 2;
    let w2 = ALU | SETA | a_src(new) | m_dest(0o26);
    let hi = p.k(w2 >> 32);
    p.mmem.push((0o30, w2 & 0xffff_ffff));
    p.op(write_i_mem(at) | a_src(hi) | m_src(0o30));
    p.fill(1);
    p.op(ALU | SETA | a_src(old) | m_dest(0o26));
    p.fill(1);
    p.stop();
    v.push(("two-ahead".to_string(), p));
    // In a delay slot: another word, then the target.
    for other in [true, false] {
        let mut p = Preset::new();
        p.select_check = false;
        let jump = p.at();
        let t = jump + 0o10;
        let written = if other { jump + 0o20 } else { t };
        p.op(JUMP | ALWAYS | target(t));
        wim(&mut p, written);
        p.op(inc(0o21));
        p.stop();
        p.fill_to(t);
        p.op(inc(0o23));
        p.stop();
        p.fill_to(jump + 0o20);
        p.fill(2);
        p.stop();
        let name = if other { "slot-other-micro-unchecked" } else { "slot-target-micro-unchecked" };
        v.push((name.to_string(), p));
    }
    v
}
