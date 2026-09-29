// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **QUUX's fused return** (revision 12, contract H8a), as programs in the
//! boot PROM for `golden/src/quux.rs`: the MACRO-DISPATCH register
//! (functional destination 5), the MACRO DISPATCH MEMORY (6, its index, and
//! 7, the entry at it), the fused return, the operand address and the
//! cache-only prefetch, each on hand-made microcode whose main loop is made
//! as microcode 2000's `QMLP` is (`uc-macrocode.lisp:9-13`): the call on
//! condition 6, `M-INST-BUFFER <- MD`, `(DISPATCH-XCT-NEXT M-INST-OP
//! OPDTB)` on the halfword's `<13:9>`, and the push of `A-MAIN-DISPATCH`
//! back.  muir-sim's `tests/macro_dispatch.rs` is the model.  Nothing is
//! preset: the map, the code in main memory, the dispatch memory and the
//! MACRO DISPATCH MEMORY are all written by the program itself.
//!
//! A program is a list of phases.  Each phase writes the register, the
//! entries for the halfwords it runs, the location counter and
//! INTERRUPT-CONTROL, pushes the main loop's word and returns into the main
//! loop; its last halfword's handler, opcode 7, dispatches on a phase count
//! into the next phase's setup, and the last into a park.
//!
//! On the CADR destinations 5 to 7 write only M, so the same programs run
//! today's main loop throughout there, and that trace is the CADR's side.

use super::*;

/// The main loop's offset from the program's base: `<1:0>` clear, as the
/// stream hardware requires (`uc-macrocode.lisp:6`).
const QMLP: u64 = 0o4;
/// Condition 6's call, counted in `M[10]`: back to `QMLP + 1`.
const COND6: u64 = 10;
/// The opcode table in the dispatch memory; a table whose two entries
/// return (R), as `QMDTBD`'s `D-PDL` does for `QIMOVE1`; and the phases'
/// setups, on the phase count's low two bits.
const OPDTB: u64 = 0o2300;
const RETURNS: u64 = 0o2200;
const PHASES: u64 = 0o2340;
/// The main loop's `<13:9>` rotate, `IR<4:0>` = 23.
const OP_ROTATE: u64 = 32 - 9;

/// Where the register names `A-LOCALP` and `M-AP`: A memory 732 (clear of
/// the constant pool's 400-677) and M memory 21.
const LOCALP_AT: u64 = 0o732;
const AP_AT: u64 = 0o21;

/// A memory the programs keep their words in.
const A_MAIN: u64 = 0o50;
const A_REGISTER: u64 = 0o51;
const A_LC: u64 = 0o52;
const A_INTCTL: u64 = 0o53;
const A_ZERO: u64 = 0o54;
/// A word with `<14>` that is not the main loop's.
const A_OTHER: u64 = 0o55;
/// `A-LOCALP`'s second value, which SETLOCALP writes.
const A_LOCALP_2: u64 = 0o56;
/// The word INDEX_WRITE and PUSHES_AFTER write in the microcycle after
/// their returns.
const A_WORD: u64 = 0o57;
/// PDL-INDEX where no operand address has been loaded.
const A_SENTINEL: u64 = 0o60;
/// `M-AP`'s value at a phase's start, and scratch words for the setup.
const A_AP: u64 = 0o62;
const A_SCRATCH: u64 = 0o63;
/// The PDL pointer at phase n's start, each phase's pushes in a block of
/// their own.
const A_PDL_POINTER: u64 = 0o64;
/// INTERRUPT-CONTROL with sequence break, and without; the stores' words
/// and addresses; the map's; block-disk's command list pointer; LC's jump.
const A_SB_ON: u64 = 0o65;
const A_SB_OFF: u64 = 0o66;
const A_STORE_W: u64 = 0o67;
const A_STORE_VA: u64 = 0o70;
const A_START_W: u64 = 0o71;
const A_START_VA: u64 = 0o72;
const A_MAP_VA: u64 = 0o73;
const A_MAP_W: u64 = 0o74;
const A_CLP_VA: u64 = 0o75;
const A_LC_JUMP: u64 = 0o76;
const A_STORE2_W: u64 = 0o77;
/// Not 0o100, which `isa::filler` writes: STORE_EARLY's store went to
/// virtual address 0 and faulted there, so it tested nothing.
const A_STORE2_VA: u64 = 0o101;
pub fn pdl_pointer(n: usize) -> u32 {
    0o100 * (n as u32 + 1)
}

/// M memory: `M[1]`-`M[7]` count opcodes 1-7 and `M[11]`-`M[22]` the
/// rest ([`counter`]); these the others.
const M_COND6: u64 = 0o10;
const M_OTHER_ROUTINE: u64 = 0o23;
const M_ZERO: u64 = 0o24;
const M_ILLOP: u64 = 0o25;
const M_PHASE: u64 = 0o26;
const M_TOP: u64 = 0o27;
const M_OTHERS: u64 = 0o30;
const M_SPECIAL: u64 = 0o32;

/// The code's pages: region 7's slots 0 and 1 onto physical 120 and 121.
const CODE_PAGE: u32 = 0o120;

/// The bases at a phase's start: `A-LOCALP` near the top of PDL-INDEX's
/// fourteen bits, so that a large delta wraps.
const LOCALP: u32 = 0o37760;
const AP: u32 = 0o200;
const LOCALP_2: u32 = 0o1000;
const SENTINEL: u32 = 0o3777;
const WORD: u32 = 0x5aa5_0f0f;

/// Where the stale phase's control-store write lands: below the PROM.
const STALE_WRITE_AT: u64 = 0o35000;

/// A halfword: `<13:9>` the opcode, `<8:6>` the register, `<5:0>` delta.
pub const fn hw(op: u32, reg: u32) -> u32 {
    op << 9 | reg << 6
}
pub const fn hwd(op: u32, reg: u32, delta: u32) -> u32 {
    hw(op, reg) | delta
}

/// Increments `M[k]`.
fn count(k: u64) -> u64 {
    ALU | M_PLUS_C | CARRY_IN | m_src(k) | m_dest(k)
}

/// The opcodes.  Each handler counts in its own `M` word and returns its
/// own way:
///
///   1  a POPJ
///   2  a jump with R
///   3  a dispatch whose entry has R
///   4  an entry with N: the handler pushes the return back itself
///   5  an entry with R and P, which falls through to `QMLP + 4`
///   6  an entry with P and N, which pushes and jumps, as a trap's does
///   7  the end of a phase
///
/// and the returns that are not fused: 10 a POPJ that writes M 31, 11 a
/// POPJ that pushes too, 12 a POPJ that writes INTERRUPT-CONTROL, 13 a
/// dispatch with R and `IR<24>`, which steps the location counter itself,
/// 14 a POPJ whose microcycle before popped a word with `<14>` (`NEXT
/// INSTR`), 17 a call with POPJ whose condition is true, which pushes; and
/// fused, 15 a jump-false with R whose condition is false, and 16 a call
/// with POPJ whose condition is false, which pushes nothing.
///
/// The operand programs': 20 RECORD pushes PDL-INDEX as its first
/// microinstruction finds it, sets it to the sentinel and returns by a POPJ
/// whose microcycle after pushes PDL-INDEX again; 21 steps `M-AP` in its
/// POPJ; 22 writes `A-LOCALP` in its POPJ; 23 LOAD pushes the word at
/// PDL-INDEX first; 24 writes the PDL buffer by PDL-INDEX in the microcycle
/// after its return; 25 pushes in the microcycle after its return; 26 TOP
/// reads the top of the stack in its first microinstruction.  Every other
/// opcode counts in `M[30]` and returns by a POPJ.
pub mod op {
    /// An entry with R alone: the main loop's dispatch returns through it,
    /// popping the main loop's word, which steps the counter, so the
    /// halfword is passed over.
    pub const R_ONLY: u32 = 0;
    pub const POPJ: u32 = 1;
    pub const JUMP_R: u32 = 2;
    pub const DISPATCH_R: u32 = 3;
    pub const N: u32 = 4;
    pub const RP: u32 = 5;
    pub const PN: u32 = 6;
    pub const END: u32 = 7;
    pub const WRITES_M31: u32 = 0o10;
    pub const PUSHES: u32 = 0o11;
    pub const WRITES_INTCTL: u32 = 0o12;
    pub const ADVANCES: u32 = 0o13;
    pub const AFTER_NEXT_INSTR: u32 = 0o14;
    pub const JUMP_FALSE_R: u32 = 0o15;
    pub const CALL_POPJ_FALSE: u32 = 0o16;
    pub const CALL_POPJ_TRUE: u32 = 0o17;
    pub const RECORD: u32 = 0o20;
    pub const SETAP: u32 = 0o21;
    pub const SETLOCALP: u32 = 0o22;
    pub const LOAD: u32 = 0o23;
    pub const INDEX_WRITE: u32 = 0o24;
    pub const PUSHES_AFTER: u32 = 0o25;
    pub const TOP: u32 = 0o26;
    pub const OTHER: u32 = 0o27;
    /// The prefetch program's: sequence break set, and cleared with A 31
    /// written alone; a store of the next code word (the same word) some
    /// microcycles before the return, and one started in the microcycle
    /// before it; a map write (the same entry); a write of block-disk's
    /// command list pointer, a transfer's invalidation; a write of the
    /// location counter; and a POPJ whose microcycle after pushes M 31.
    pub const SEQ_ON: u32 = 0o30;
    pub const SEQ_OFF: u32 = 0o31;
    pub const STORE_NEXT: u32 = 0o32;
    pub const STORE_START: u32 = 0o33;
    pub const MAPW: u32 = 0o34;
    pub const DMA: u32 = 0o35;
    pub const JUMPLC: u32 = 0o36;
    pub const RET_READ31: u32 = 0o37;
    pub const LAST: u32 = 0o37;
}

/// Each opcode's counter.
fn counter(o: u32) -> u64 {
    match o {
        1..=7 => o as u64,
        op::WRITES_M31..=op::CALL_POPJ_TRUE => (o - op::WRITES_M31) as u64 + 0o11,
        _ => M_OTHERS,
    }
}

/// The handlers' offsets from the base.
mod at {
    // Packed one after another, each with a filler after its return for
    // the microinstruction a return runs after it; only `OTHER_R` is
    // aligned, to four, so that `SPCMUNG`'s `<1>` makes it `OTHER_R + 2`.
    pub const H1: u64 = 12;
    pub const H2: u64 = 15;
    pub const H3: u64 = 18;
    pub const H4: u64 = 21;
    pub const H6: u64 = 25;
    pub const H7: u64 = 31;
    pub const SPECIAL: u64 = 34;
    pub const H10: u64 = 36;
    pub const H11: u64 = 39;
    pub const H12: u64 = 42;
    pub const H13: u64 = 45;
    pub const H14: u64 = 48;
    /// Where opcode 14's `<14>` word returns: here or two on, as
    /// `SPCMUNG` has it; the same count at both.
    pub const OTHER_R: u64 = 56;
    pub const H15: u64 = 60;
    pub const H16: u64 = 63;
    pub const H17: u64 = 66;
    pub const RECORD: u64 = 69;
    pub const SETAP: u64 = 73;
    pub const SETLOCALP: u64 = 75;
    pub const LOAD: u64 = 77;
    pub const INDEX_WRITE: u64 = 81;
    pub const PUSHES_AFTER: u64 = 85;
    pub const TOP: u64 = 89;
    pub const OTHER: u64 = 92;
    /// Where a stale entry sends a return: a count and a park.
    pub const ILLOP: u64 = 94;
    pub const SEQ_ON: u64 = 97;
    pub const SEQ_OFF: u64 = 100;
    pub const STORE_NEXT: u64 = 104;
    pub const STORE_START: u64 = 110;
    pub const MAPW: u64 = 114;
    pub const DMA: u64 = 120;
    pub const JUMPLC: u64 = 126;
    pub const RET_READ31: u64 = 129;
    /// A specialised handler that pushes M 31 and A 31 first.
    pub const READ31: u64 = 132;
    /// A specialised handler of STORE_NEXT that returns a microcycle sooner,
    /// in the microcycle the store's grant begins.
    pub const STORE_EARLY: u64 = 135;
    /// The first word of the setup.
    pub const SETUP: u64 = 140;
}

/// The MACRO DISPATCH MEMORY's operand bit, `<17>`.
const OPERAND: u32 = 1 << 17;

/// A phase: its halfwords, in the order they are laid in main memory (a
/// word's `<15:0>`, then its `<31:16>`), and what it sets up.
pub struct Phase {
    pub halfwords: Vec<u32>,
    /// The register's enable, and the main loop it names: `QMLP`, or not.
    pub enable: bool,
    pub other_main: bool,
    /// Sequence break in INTERRUPT-CONTROL: condition 6 true throughout,
    /// so that every return on the fetch path runs `QMLP` and its call.
    pub sequence_break: bool,
    /// Entries in place of OPDTB's generic one, by index.
    pub specialised: Vec<(u32, u32)>,
    /// The operand bit on every entry of these opcodes.
    pub operand_ops: Vec<u32>,
    /// Every entry the phase uses names [`at::ILLOP`], and a control-store
    /// write comes between the register's write and the first return.
    pub stale: bool,
    /// PDL buffer words written before the phase, at these addresses.
    pub pdl: Vec<(u32, u32)>,
    /// The code words, by index in the phase, that STORE_NEXT and
    /// STORE_START store back, and JUMPLC's target word.
    pub store_next: Option<usize>,
    pub store_start: Option<usize>,
    /// The code word STORE_EARLY stores back.
    pub store_early: Option<usize>,
    pub jump_to: Option<usize>,
}

impl Phase {
    pub fn new(halfwords: &[u32]) -> Phase {
        Phase {
            halfwords: halfwords.to_vec(),
            enable: true,
            other_main: false,
            sequence_break: true,
            specialised: vec![],
            operand_ops: vec![],
            stale: false,
            pdl: vec![],
            store_next: None,
            store_start: None,
            store_early: None,
            jump_to: None,
        }
    }
}

/// A built program.
pub struct Built {
    pub prog: Prog,
    /// Each phase's setup address, and the park's.
    pub marks: Vec<u64>,
}

/// Each opcode's entry in OPDTB: `<16>` R, `<15>` P, `<14>` N, `<13:0>` the
/// handler.
fn opdtb(base: u64, o: u32) -> u32 {
    let h = |off: u64| (base + off) as u32;
    match o {
        op::R_ONLY => 1 << 16,
        op::POPJ => h(at::H1),
        op::JUMP_R => h(at::H2),
        op::DISPATCH_R => h(at::H3),
        op::N => 1 << 14 | h(at::H4),
        op::RP => 1 << 16 | 1 << 15,
        op::PN => 1 << 15 | 1 << 14 | h(at::H6),
        op::END => h(at::H7),
        op::WRITES_M31 => h(at::H10),
        op::PUSHES => h(at::H11),
        op::WRITES_INTCTL => h(at::H12),
        op::ADVANCES => h(at::H13),
        op::AFTER_NEXT_INSTR => h(at::H14),
        op::JUMP_FALSE_R => h(at::H15),
        op::CALL_POPJ_FALSE => h(at::H16),
        op::CALL_POPJ_TRUE => h(at::H17),
        op::RECORD => h(at::RECORD),
        op::SETAP => h(at::SETAP),
        op::SETLOCALP => h(at::SETLOCALP),
        op::LOAD => h(at::LOAD),
        op::INDEX_WRITE => h(at::INDEX_WRITE),
        op::PUSHES_AFTER => h(at::PUSHES_AFTER),
        op::TOP => h(at::TOP),
        op::SEQ_ON => h(at::SEQ_ON),
        op::SEQ_OFF => h(at::SEQ_OFF),
        op::STORE_NEXT => h(at::STORE_NEXT),
        op::STORE_START => h(at::STORE_START),
        op::MAPW => h(at::MAPW),
        op::DMA => h(at::DMA),
        op::JUMPLC => h(at::JUMPLC),
        op::RET_READ31 => h(at::RET_READ31),
        _ => h(at::OTHER),
    }
}

/// The specialised handler's entry: counts in `M[32]` and returns.
pub fn special(base: u64) -> u32 {
    (base + at::SPECIAL) as u32
}

/// The specialised handler that pushes M 31 and then A 31.
pub fn read31(base: u64) -> u32 {
    (base + at::READ31) as u32
}

/// The specialised handler that stores the next code word and returns in
/// the microcycle the store's grant begins.
pub fn store_early(base: u64) -> u32 {
    (base + at::STORE_EARLY) as u32
}

/// `A[a]` = `v` in as few dispatch-constant pieces as `v` needs, which is a
/// fixed count for a fixed `v`.
fn konst_short(p: &mut Prog, a: u64, v: u32) {
    let parts = [(0u64, 10u64), (10, 10), (20, 10), (30, 2)];
    let n = parts.iter().rposition(|&(pos, _)| (v as u64) >> pos != 0).map_or(1, |i| i + 1);
    for (k, &(pos, w)) in parts[..n].iter().enumerate() {
        let piece = ((v as u64) >> pos) & ((1 << w) - 1);
        p.i(DISPATCH | DMEM_WRITE | a_src(piece));
        if k == 0 {
            p.i(ALU | SETM | src(0) | a_dest(a));
        } else {
            p.i(BYTE | DPB | src(0) | a_src(a) | width(w) | rot(pos) | a_dest(a));
        }
    }
}

/// The fixed part: the jump over it, the main loop and every handler.
fn lay_fixed(p: &mut Prog) {
    let base = p.base;
    let pad = |p: &mut Prog, off: u64| {
        assert!(p.at() <= base + off, "fused: {:o} runs into {:o}", p.at(), base + off);
        while p.at() < base + off {
            p.i(filler().raw());
        }
    };
    p.i(JUMP | target(base + at::SETUP) | ALWAYS | N);
    p.fill(1);
    pad(p, QMLP);
    // The main loop.
    p.i(JUMP | target(base + COND6) | P | (1 << 5) | 6);
    p.i(ALU | SETM | SRC_MD | m_dest(0o31));
    p.i(DISPATCH | m_src(0o31) | 3 << 10 | rot(OP_ROTATE) | d_len(5) | d_addr(OPDTB));
    p.i(ALU | SETA | a_src(A_MAIN) | fdest(0o15));
    // Opcode 5's entry falls through (R and P) to here, after the push.
    p.i(count(counter(op::RP)) | POPJ);
    pad(p, COND6);
    p.i(count(M_COND6) | POPJ);
    pad(p, at::H1);
    p.i(count(counter(op::POPJ)));
    p.i(ALU | SETA | a_src(3) | m_dest(0o36) | POPJ);
    pad(p, at::H2);
    p.i(count(counter(op::JUMP_R)));
    p.i(JUMP | R | ALWAYS);
    // On `M[2]`'s low bit; both entries return.
    pad(p, at::H3);
    p.i(count(counter(op::DISPATCH_R)));
    p.i(DISPATCH | m_src(2) | d_len(1) | d_addr(RETURNS));
    // Its entry has N, so the main loop's push is not run.
    pad(p, at::H4);
    p.i(count(counter(op::N)));
    p.i(ALU | SETA | a_src(A_MAIN) | fdest(0o15));
    p.i(filler().raw() | POPJ);
    // Its entry pushes and jumps (P and N): drop the pushed word, count,
    // and put the main loop's return back.
    pad(p, at::H6);
    p.i(ALU | SETM | src(0o14) | m_dest(0o20));
    p.i(count(counter(op::PN)));
    p.i(ALU | SETA | a_src(A_MAIN) | fdest(0o15));
    p.fill(1);
    p.i(filler().raw() | POPJ);
    // The end of a phase: counted, and a dispatch on the phase count into
    // the next phase's setup, the count stepped in its XCT-NEXT.
    pad(p, at::H7);
    p.i(count(counter(op::END)));
    p.i(DISPATCH | m_src(M_PHASE) | d_len(2) | d_addr(PHASES));
    p.i(count(M_PHASE));
    pad(p, at::SPECIAL);
    p.i(count(M_SPECIAL) | POPJ);
    // A POPJ that writes M 31 with the word it holds.
    pad(p, at::H10);
    p.i(count(counter(op::WRITES_M31)));
    p.i(ALU | SETM | m_src(0o31) | m_dest(0o31) | POPJ);
    // A POPJ that pushes the main loop's word too.
    pad(p, at::H11);
    p.i(count(counter(op::PUSHES)));
    p.i(ALU | SETA | a_src(A_MAIN) | fdest(0o15) | POPJ);
    // A POPJ that writes INTERRUPT-CONTROL, as it stands.
    pad(p, at::H12);
    p.i(count(counter(op::WRITES_INTCTL)));
    p.i(ALU | SETA | a_src(A_INTCTL) | fdest(DEST_INTCTL) | POPJ);
    // A dispatch with R that steps the location counter itself.
    pad(p, at::H13);
    p.i(count(counter(op::ADVANCES)));
    p.i(DISPATCH | 1 << 24 | m_src(2) | d_len(1) | d_addr(RETURNS));
    // A POPJ of another `<14>` word, and in its microcycle after a POPJ of
    // the main loop's, whose counter `NEXT INSTR` steps in it.
    pad(p, at::H14);
    p.i(count(counter(op::AFTER_NEXT_INSTR)));
    p.i(ALU | SETA | a_src(A_OTHER) | fdest(0o15));
    p.i(filler().raw() | POPJ);
    p.i(filler().raw() | POPJ);
    pad(p, at::OTHER_R);
    p.i(count(M_OTHER_ROUTINE));
    p.fill(1);
    p.i(count(M_OTHER_ROUTINE));
    p.fill(1);
    // A jump-false with R whose condition, `M[1]` = `A[54]`, is false.
    pad(p, at::H15);
    p.i(count(counter(op::JUMP_FALSE_R)));
    p.i(JUMP | R | INVERT | AEQM | a_src(A_ZERO) | m_src(1));
    // A call with POPJ whose condition is false: no push, and the POPJ
    // returns.
    pad(p, at::H16);
    p.i(count(counter(op::CALL_POPJ_FALSE)));
    p.i(JUMP | P | target(base + at::ILLOP) | AEQM | a_src(A_ZERO) | m_src(1) | POPJ);
    p.fill(1);
    // The same with a true condition, `M[24]` = `A[54]`: it pushes its
    // return, and the POPJ returns to the main loop.
    pad(p, at::H17);
    p.i(count(counter(op::CALL_POPJ_TRUE)));
    p.i(JUMP | P | target(base + at::ILLOP) | AEQM | a_src(A_ZERO) | m_src(M_ZERO) | POPJ);
    p.fill(1);
    let push_index = ALU | SETM | src(3) | fdest(0o11);
    pad(p, at::RECORD);
    p.i(push_index);
    p.i(ALU | SETA | a_src(A_SENTINEL) | fdest(0o13));
    p.i(filler().raw() | POPJ);
    p.i(push_index);
    pad(p, at::SETAP);
    p.i(ALU | M_PLUS_C | CARRY_IN | m_src(AP_AT) | m_dest(AP_AT) | POPJ);
    pad(p, at::SETLOCALP);
    p.i(ALU | SETA | a_src(A_LOCALP_2) | a_dest(LOCALP_AT) | POPJ);
    // The word at PDL-INDEX, pushed by the first microinstruction.
    pad(p, at::LOAD);
    p.i(ALU | SETM | src(0o05) | fdest(0o11));
    p.i(ALU | SETA | a_src(A_SENTINEL) | fdest(0o13));
    p.i(filler().raw() | POPJ);
    p.fill(1);
    // The PDL buffer written by PDL-INDEX in the microcycle after the
    // return: it lands at the next operand's address.
    pad(p, at::INDEX_WRITE);
    p.i(push_index);
    p.i(ALU | SETA | a_src(A_SENTINEL) | fdest(0o13));
    p.i(filler().raw() | POPJ);
    p.i(ALU | SETA | a_src(A_WORD) | fdest(0o12));
    // A push in the microcycle after the return.
    pad(p, at::PUSHES_AFTER);
    p.i(push_index);
    p.i(ALU | SETA | a_src(A_SENTINEL) | fdest(0o13));
    p.i(filler().raw() | POPJ);
    p.i(ALU | SETA | a_src(A_WORD) | fdest(0o11));
    // The top of the stack read by the first microinstruction.
    pad(p, at::TOP);
    p.i(ALU | SETM | src(0o25) | m_dest(M_TOP));
    p.i(ALU | SETM | m_src(M_TOP) | fdest(0o11) | POPJ);
    p.fill(1);
    pad(p, at::OTHER);
    p.i(count(M_OTHERS) | POPJ);
    pad(p, at::ILLOP);
    p.i(count(M_ILLOP));
    p.i(JUMP | target(base + at::ILLOP + 1) | ALWAYS | N);
    p.fill(1);
    pad(p, at::SEQ_ON);
    p.i(ALU | SETA | a_src(A_SB_ON) | fdest(DEST_INTCTL));
    p.i(count(M_OTHERS) | POPJ);
    pad(p, at::SEQ_OFF);
    p.i(ALU | SETA | a_src(A_SB_OFF) | fdest(DEST_INTCTL));
    p.i(ALU | SETA | a_src(A_ZERO) | a_dest(0o31));
    p.i(count(M_OTHERS) | POPJ);
    pad(p, at::STORE_NEXT);
    p.to(A_STORE_W, MD);
    p.to(A_STORE_VA, START_WRITE);
    p.fill(2);
    p.i(count(M_OTHERS) | POPJ);
    pad(p, at::STORE_START);
    p.to(A_START_W, MD);
    p.to(A_START_VA, START_WRITE);
    p.i(filler().raw() | POPJ);
    p.fill(1);
    pad(p, at::MAPW);
    p.to(A_MAP_VA, MD);
    p.to(A_MAP_W, fdest(0o23));
    p.fill(2);
    p.i(count(M_OTHERS) | POPJ);
    pad(p, at::DMA);
    p.to(A_ZERO, MD);
    p.to(A_CLP_VA, START_WRITE);
    p.fill(2);
    p.i(count(M_OTHERS) | POPJ);
    pad(p, at::JUMPLC);
    p.to(A_LC_JUMP, fdest(1));
    p.i(filler().raw() | POPJ);
    p.fill(1);
    pad(p, at::RET_READ31);
    p.i(count(M_OTHERS));
    p.i(filler().raw() | POPJ);
    p.i(ALU | SETM | m_src(0o31) | fdest(0o11));
    pad(p, at::READ31);
    p.i(ALU | SETM | m_src(0o31) | fdest(0o11));
    p.i(ALU | SETA | a_src(0o31) | fdest(0o11) | POPJ);
    p.fill(1);
    pad(p, at::STORE_EARLY);
    p.to(A_STORE2_W, MD);
    p.to(A_STORE2_VA, START_WRITE);
    p.fill(1);
    p.i(count(M_SPECIAL) | POPJ);
    pad(p, at::SETUP);
}

/// Lays the program down; `marks`, from a first pass, are the phases'
/// setups and the park, which the phase table names.
fn lay(phases: &[Phase], marks: &[u64]) -> Built {
    let mut p = Prog::new();
    let base = p.base;
    lay_fixed(&mut p);
    let mut c = Pool::new();
    // Once: the map, and every phase's code, each phase starting on a line
    // of four, the words one after another.
    map_region_7(&mut p, &mut c, &[CODE_PAGE, CODE_PAGE + 1, FEATURE_PAGE]);
    let mut words: Vec<u32> = Vec::new();
    let mut starts = Vec::new();
    for (n, ph) in phases.iter().enumerate() {
        // A phase that runs another's halfwords runs its code.
        if let Some(k) = (0..n).find(|&k| phases[k].halfwords == ph.halfwords) {
            starts.push(starts[k]);
            continue;
        }
        while words.len() % 4 != 0 {
            words.push(hw(op::OTHER, 0) | hw(op::OTHER, 0) << 16);
        }
        starts.push(r7(0, words.len() as u32));
        for pair in ph.halfwords.chunks(2) {
            words.push(pair[0] | pair.get(1).copied().unwrap_or(0) << 16);
        }
    }
    assert!(words.len() <= 0o1000, "fused: the code is {} words", words.len());
    // The words: the address in `M[12]`, stepped; the word through `A[63]`.
    let first = c.c(&mut p, r7(0, 0));
    p.i(ALU | SETA | a_src(first) | m_dest(0o12));
    for &w in &words {
        konst_short(&mut p, A_SCRATCH, w);
        p.to(A_SCRATCH, MD);
        p.i(ALU | SETM | m_src(0o12) | START_WRITE);
        p.fill(1);
        p.i(count(0o12));
    }
    // The dispatch memory: OPDTB, the returning table and the phases.
    for o in 0..=op::LAST {
        let a = c.c(&mut p, opdtb(base, o));
        p.i(DISPATCH | DMEM_WRITE | d_addr(OPDTB + o as u64) | a_src(a));
    }
    for k in 0..2 {
        let a = c.c(&mut p, 1 << 16);
        p.i(DISPATCH | DMEM_WRITE | d_addr(RETURNS + k) | a_src(a));
    }
    for k in 0..phases.len() {
        let to = marks.get(k + 1).copied().unwrap_or(0);
        p.konst(A_SCRATCH, to as u32); // a fixed length whatever the mark
        p.i(DISPATCH | DMEM_WRITE | d_addr(PHASES + k as u64) | a_src(A_SCRATCH));
    }
    konst_short(&mut p, A_MAIN, (1 << 14) | (base + QMLP) as u32);
    konst_short(&mut p, A_ZERO, 0);
    konst_short(&mut p, A_OTHER, (1 << 14) | (base + at::OTHER_R) as u32);
    konst_short(&mut p, A_SENTINEL, SENTINEL);
    konst_short(&mut p, A_LOCALP_2, LOCALP_2);
    konst_short(&mut p, A_WORD, WORD);
    konst_short(&mut p, A_AP, AP);
    konst_short(&mut p, A_SB_ON, 1 << 26);
    konst_short(&mut p, A_SB_OFF, 0);
    konst_short(&mut p, A_MAP_VA, r7(0, 0));
    konst_short(&mut p, A_MAP_W, level_2_store(CODE_PAGE));
    konst_short(&mut p, A_CLP_VA, r7(2, 0o201));
    p.i(ALU | SETA | a_src(A_ZERO) | m_dest(M_ZERO));
    p.i(ALU | SETA | a_src(A_ZERO) | m_dest(M_PHASE));
    let mut got = Vec::new();
    for (n, ph) in phases.iter().enumerate() {
        got.push(p.at());
        if n > 0 {
            // The main loop's word the end handler returned with.
            p.i(ALU | SETM | src(0o14) | m_dest(0o20));
        }
        let mut idx: Vec<u32> = ph.halfwords.iter().map(|&h| h >> 6 & 0o1777).collect();
        idx.sort();
        idx.dedup();
        for &i in &idx {
            let o = i >> 3 & 0o37;
            let mut e = if ph.stale { (base + at::ILLOP) as u32 } else { opdtb(base, o) };
            if let Some(&(_, s)) = ph.specialised.iter().find(|&&(k, _)| k == i) {
                e = s;
            }
            if ph.operand_ops.contains(&o) {
                e |= OPERAND;
            }
            let (ai, ae) = (c.c(&mut p, i), c.c(&mut p, e));
            p.to(ai, fdest(6));
            p.to(ae, fdest(7));
        }
        for &(at, w) in &ph.pdl {
            let (aa, aw) = (c.c(&mut p, at), c.c(&mut p, w));
            p.to(aa, fdest(0o13));
            p.to(aw, fdest(0o12));
        }
        let main = base + QMLP + if ph.other_main { 0o40 } else { 0 };
        let register = (ph.enable as u32) << 31
            | (AP_AT as u32) << 24
            | (LOCALP_AT as u32) << 14
            | main as u32;
        // Four pieces whatever the enable, so that a program with the enable
        // clear is as long.
        p.konst(A_REGISTER, register);
        konst_short(&mut p, A_LC, starts[n] * 4);
        konst_short(&mut p, A_INTCTL, if ph.sequence_break { 1 << 26 } else { 0 });
        konst_short(&mut p, LOCALP_AT, LOCALP);
        konst_short(&mut p, A_PDL_POINTER, pdl_pointer(n));
        let word_at = |k: usize| (words[(starts[n] - r7(0, 0)) as usize + k], starts[n] + k as u32);
        if let Some(k) = ph.store_next {
            let (w, va) = word_at(k);
            konst_short(&mut p, A_STORE_W, w);
            konst_short(&mut p, A_STORE_VA, va);
        }
        if let Some(k) = ph.store_early {
            let (w, va) = word_at(k);
            konst_short(&mut p, A_STORE2_W, w);
            konst_short(&mut p, A_STORE2_VA, va);
        }
        if let Some(k) = ph.store_start {
            let (w, va) = word_at(k);
            konst_short(&mut p, A_START_W, w);
            konst_short(&mut p, A_START_VA, va);
        }
        if let Some(k) = ph.jump_to {
            konst_short(&mut p, A_LC_JUMP, (starts[n] + k as u32) * 4);
        }
        p.to(A_REGISTER, fdest(5));
        // `A-LOCALP` and `M-AP` written after destination 5, which loads
        // the base copies; PDL-INDEX at the sentinel.
        p.i(ALU | SETA | a_src(LOCALP_AT) | a_dest(LOCALP_AT));
        p.i(ALU | SETA | a_src(A_AP) | m_dest(AP_AT));
        p.to(A_SENTINEL, fdest(0o13));
        p.to(A_PDL_POINTER, fdest(0o14));
        if ph.stale {
            // A control-store write below the PROM, `WRITE-I-MEM` and its
            // return: it clears the enable.
            p.i(ALU | SETA | a_src(A_ZERO) | m_dest(1));
            p.fill(1);
            p.i(JUMP | R | P | ALWAYS | target(STALE_WRITE_AT) | a_src(A_ZERO) | m_src(1));
            p.fill(1);
        }
        p.to(A_LC, fdest(1));
        p.to(A_INTCTL, fdest(DEST_INTCTL));
        p.to(A_MAIN, fdest(0o15));
        p.fill(1);
        p.i(filler().raw() | POPJ);
        p.fill(1);
    }
    got.push(p.at());
    p.park();
    Built { prog: p, marks: got }
}

/// The program for `phases`: laid down once to find its marks, and again
/// with them.
pub fn program(phases: &[Phase]) -> Built {
    assert!(phases.len() <= 4, "fused: four phases at most, the table's two bits");
    let probe = lay(phases, &[]);
    let b = lay(phases, &probe.marks);
    assert_eq!(b.marks, probe.marks, "fused: the marks held");
    b
}

// ------------------------------------------------------------ the programs

/// **The fused return, with no fetch** (contract H8a §6 items 2 and 3):
/// every kind of return, fused and not, with sequence break up so that no
/// return on the fetch path fuses (the prefetch's word is refused there);
/// then another main loop's word; then a stale memory after a
/// control-store write.
///
/// Phase 1, each opcode in a word's first halfword so that its return is
/// to the second, which needs no fetch: the three returns that fuse (POPJ,
/// jump with R, dispatch with R), N honoured, R and P and P and N entries
/// run today's path, a specialised entry, a jump-false with R and a call
/// with POPJ that pushes nothing (both fused), and the returns that are not
/// fused: one that writes M 31, one that pushes, one that writes
/// INTERRUPT-CONTROL, one that steps the counter itself (`IR<24>`), one in
/// a microcycle whose counter `NEXT INSTR` steps, a call with POPJ that
/// pushes.  Opcodes 13 and 14 step the counter twice, so the halfword after
/// each is skipped.
pub fn fused_phases() -> Vec<Phase> {
    use op::*;
    let base = BASE.load(std::sync::atomic::Ordering::Relaxed);
    let mut a = Phase::new(&[
        hw(POPJ, 0), hw(JUMP_R, 5),
        hw(DISPATCH_R, 1), hw(N, 0),
        hw(POPJ, 2), hw(JUMP_R, 0),
        hw(PN, 0), hw(RP, 0),
        hw(POPJ, 0), hw(POPJ, 0),
        hw(DISPATCH_R, 0), hw(PN, 0),
        hw(RP, 0), hw(JUMP_R, 5),
        hw(N, 3), hw(N, 0),
        hw(JUMP_R, 5), hw(DISPATCH_R, 7),
        hw(WRITES_M31, 0), hw(POPJ, 1),
        hw(PUSHES, 0), hw(POPJ, 1),
        hw(WRITES_INTCTL, 0), hw(POPJ, 1),
        hw(POPJ, 3), hw(ADVANCES, 0),
        hw(OTHER, 1), hw(POPJ, 4),
        hw(POPJ, 5), hw(AFTER_NEXT_INSTR, 0),
        hw(OTHER, 2), hw(POPJ, 6),
        hw(JUMP_FALSE_R, 0), hw(POPJ, 7),
        hw(CALL_POPJ_FALSE, 0), hw(POPJ, 1),
        hw(CALL_POPJ_TRUE, 0), hw(POPJ, 2),
        hw(POPJ, 3), hw(R_ONLY, 0),
        hw(DISPATCH_R, 2), hw(END, 0),
    ]);
    a.specialised = vec![(hw(JUMP_R, 5) >> 6, special(base))];
    let mut b = Phase::new(&[hw(POPJ, 0), hw(POPJ, 0), hw(JUMP_R, 5), hw(DISPATCH_R, 0), hw(POPJ, 1), hw(END, 0)]);
    b.other_main = true;
    let mut c = Phase::new(&[hw(POPJ, 0), hw(POPJ, 0), hw(JUMP_R, 0), hw(DISPATCH_R, 0), hw(POPJ, 1), hw(END, 0)]);
    c.stale = true;
    vec![a, b, c]
}

/// **The operand address** (contract H8a §3.4, §6 items 4 and 5), sequence
/// break up as above: RECORD with LOCAL, ARG and another register, each in
/// a word's first halfword (a fetch, not fused) and its second (fused);
/// after SETAP's return, which steps `M-AP` itself, and SETLOCALP's, which
/// writes `A-LOCALP`; deltas from 0 to 77, one wrapping PDL-INDEX; LOAD,
/// which pushes its operand's word; a write by PDL-INDEX in the microcycle
/// after a fused return, which lands at the next operand's address; and a
/// push in the microcycle after a fused return whose next handler reads the
/// top of the stack first, which finds the word from before the push, the
/// PDL buffer having no pass-around.  Then the same halfwords with the
/// operand bit clear, which leave PDL-INDEX alone.
pub fn operand_phases() -> Vec<Phase> {
    use op::*;
    let halfwords = [
        hwd(RECORD, 5, 3), hwd(RECORD, 5, 7),
        hwd(RECORD, 6, 0), hwd(RECORD, 6, 5),
        hw(SETAP, 0), hwd(RECORD, 6, 2),
        hwd(RECORD, 4, 1), hwd(RECORD, 4, 1),
        hwd(RECORD, 5, 0o77), hwd(RECORD, 5, 0o77),
        hw(SETLOCALP, 0), hwd(RECORD, 5, 1),
        hwd(LOAD, 5, 2), hwd(LOAD, 6, 4),
        hwd(INDEX_WRITE, 5, 0), hwd(LOAD, 5, 6),
        hwd(RECORD, 6, 1), hwd(LOAD, 5, 6),
        hwd(PUSHES_AFTER, 5, 0), hwd(TOP, 5, 0),
        hw(POPJ, 0), hw(END, 0),
    ];
    let pdl = vec![
        (LOCALP_2 + 2, 0x1111_0002),
        (LOCALP_2 + 6, 0x1111_0006),
        (AP + 1 + 1 + 4, 0x2222_0006),
    ];
    let ops = vec![RECORD, LOAD, INDEX_WRITE, PUSHES_AFTER, TOP];
    let mut a = Phase::new(&halfwords);
    a.operand_ops = ops.clone();
    a.pdl = pdl.clone();
    let mut b = Phase::new(&halfwords);
    b.pdl = pdl;
    vec![a, b]
}

/// **The cache-only prefetch** (contract H8a §3.5, §6 item 10), with
/// sequence break down: a return on the fetch path fuses on the buffered
/// word when the fetch before left the next word of its line there, and
/// its word is M 31's from the edge after the return's microcycle after,
/// which reads the old M 31 (RET_READ31's push) where the handler reads the
/// new one, in M 31 and in A 31 (READ31, the specialised entry of POPJ with
/// register 7).  Then everything that keeps it from fusing: sequence break
/// (condition 6), a word in the next line, a store to the word some
/// microcycles before the return and one started in the microcycle before
/// it, a map write, a write of block-disk's command list pointer, and a
/// write of LC, after which the wrong word's fetch fills the buffer again;
/// and a return on the fetch path, the next word held, in a microcycle whose
/// counter `NEXT INSTR` or a dispatch's `IR<24>` steps, each passing a
/// halfword over.  A 31 written alone after SEQ_OFF reads A memory again.
pub fn prefetch_phases() -> Vec<Phase> {
    use op::*;
    let base = BASE.load(std::sync::atomic::Ordering::Relaxed);
    let mut a = Phase::new(&[
        hw(POPJ, 0), hw(POPJ, 1),            // 0: entered by a fetch
        hw(POPJ, 2), hw(RET_READ31, 0),      // 1: fused on the buffer
        hw(POPJ, 7), hw(SEQ_ON, 0),          // 2: fused, READ31
        hw(SEQ_OFF, 0), hw(POPJ, 7),         // 3: refused, condition 6
        hw(POPJ, 7), hw(STORE_NEXT, 0),      // 4: the next line
        hw(POPJ, 3), hw(STORE_START, 0),     // 5: dropped by the store
        hw(POPJ, 4), hw(MAPW, 0),            // 6: refused, a store started
        hw(POPJ, 5), hw(POPJ, 6),            // 7: dropped by the map write
        hw(POPJ, 0), hw(DMA, 0),             // 8: the next line
        hw(POPJ, 1), hw(JUMPLC, 0),          // 9: dropped by the transfer
        hw(OTHER, 0), hw(OTHER, 1),          // 10: jumped over
        hw(OTHER, 2), hw(OTHER, 3),          // 11: jumped over
        hw(POPJ, 2), hw(STORE_NEXT, 1),      // 12: LC's target, a wrong word;
        hw(POPJ, 7), hw(POPJ, 4),            // 13: the buffer refilled, and the
                                             // store granted as the return
                                             // runs (STORE_EARLY)
        hw(RET_READ31, 1), hw(AFTER_NEXT_INSTR, 0), // 14: the next word held,
        hw(OTHER, 0), hw(POPJ, 7),           // 15: and `NEXT INSTR` stepping
        hw(POPJ, 1), hw(ADVANCES, 0),        // 16: the next word held, and
        hw(OTHER, 1), hw(POPJ, 2),           // 17: `IR<24>` stepping
        hw(POPJ, 3), hw(END, 0),             // 18
    ]);
    a.sequence_break = false;
    a.specialised = vec![(hw(POPJ, 7) >> 6, read31(base)), (hw(STORE_NEXT, 1) >> 6, store_early(base))];
    a.store_next = Some(5);
    a.store_early = Some(13);
    a.store_start = Some(6);
    a.jump_to = Some(12);
    let mut b = Phase::new(&a.halfwords);
    b.sequence_break = false;
    b.enable = false;
    b.store_next = Some(5);
    b.store_start = Some(6);
    b.store_early = Some(13);
    b.jump_to = Some(12);
    vec![a, b]
}

/// M words the checks read, by name.
pub const M_WORDS: [(&str, u64); 6] = [
    ("condition 6's calls", M_COND6),
    ("the <14> routine", M_OTHER_ROUTINE),
    ("stale entries taken", M_ILLOP),
    ("phases ended", M_PHASE),
    ("the specialised handler", M_SPECIAL),
    ("other opcodes", M_OTHERS),
];

pub const PDL_WORD: u32 = WORD;
pub const PDL_LOCALP: u32 = LOCALP;
pub const PDL_AP: u32 = AP;
pub const PDL_LOCALP_2: u32 = LOCALP_2;
pub const PDL_SENTINEL: u32 = SENTINEL;
