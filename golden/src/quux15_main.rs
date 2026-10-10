// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's main loop: the fused return and D** (contract G3
//! revision 15, A15.2, A15b.9, A15b.16), as muir's
//! `d_and_the_fused_return_end_as_on_micro` and
//! `the_main_loop_s_paths_end_as_on_micro` build their machines: the main
//! loop at 100 made as microcode 2001's `QMLP` is, an opcode table in
//! dispatch memory and the MACRO DISPATCH MEMORY's entries from it,
//! macroinstructions in the physical memory window, and the
//! MACRO-DISPATCH register written by destination 5 at the start.
//!
//!   mainloop  opcode 1 eleven times, then 7; a sequence break; a fetch
//!             that faults; an entry with P; opcode 10's operand address,
//!             LOCAL and ARG; each with D off, the returns that need no fetch
//!             fused on M 31; and a PDL address field on M-AP and on
//!             A-LOCALP written by the word right before it, or the one
//!             before that (muir's
//!             `a_pdl_field_reads_a_base_the_word_before_wrote`)
//!
//! **D ON WAITS FOR THE REFERENCE**: D's effects that need the fetched word
//! happen at its arrival (A15b.9); until muir does so, the core stops at
//! such a return, naming it (`unbuilt`).  `machines(&[true])` builds those
//! runs.

use muir::isa::asm::{
    ALU, ALWAYS, CARRY_IN, DISPATCH, JUMP, M_PLUS_C, N, P, POPJ, SETA, SETM, SRC_MD, START_READ,
    a_dest, a_src, filler, m_dest, m_src, pdl_field, src, target,
};
use muir::machine::Word;
use muir::machine::macro_dispatch;

use super::Case;
use super::quux15_preset::Preset;

/// The main loop, at an address with `<1:0>` clear, made as microcode
/// 2001's `QMLP` is: the condition-6 call, `M-INST-BUFFER <- MD`, the
/// dispatch on the halfword's `<13:9>` with the push of the main loop's
/// return in its slot.
const QMLP: u64 = 0o100;
/// Condition 6's call: counts in M 10.
const COND_6: u64 = 0o110;
/// The opcode table in dispatch memory.
const OPDTB: u64 = 0o2300;
/// The main loop's return, `<14>` and its address.
const MAIN: u32 = 1 << 14 | QMLP as u32;
/// Opcode 1's handler, counting in M 1; opcode 6's, whose entry has P and
/// N, counting in M 6; opcode 7's, a jump to itself, the run's park;
/// opcode 10's, which pushes M 31 and PDL-INDEX as its first two words find
/// them.
const OP_1: u64 = 0o204;
const OP_6: u64 = 0o120;
const OP_7: u64 = 0o177;
const OP_10: u64 = 0o230;
/// Opcode 2's handler: a return at its first word, so that the word before
/// the return is the microcycle after the last return, which steps LC.
const OP_2: u64 = 0o240;
/// Opcode 3's handler: words planted before its return.
const OP_3: u64 = 0o250;
/// Where the register names `A-LOCALP` and `M-AP`, and what they hold.
const LOCALP_AT: u64 = 0o432;
const AP_AT: u64 = 0o21;
const LOCALP: Word = 0o1000;
/// PDL-INDEX at the start, where no operand address is loaded.
const SENTINEL: u64 = 0o3777;
/// The macroinstructions, in the physical memory window: word 400.
const CODE: Word = 0o36000000400;
/// A paged address with no page table, where a fetch faults.
const UNMAPPED: Word = 0o1000;

/// A halfword: `<13:9>` the opcode, `<8:6>` the register, `<5:0>` delta.
const fn hw(op: u32, reg: u32, delta: u32) -> u32 {
    op << 9 | reg << 6 | delta
}

/// Opcode 1 eleven times, then 7: five returns need a fetch.
const ONES: [u32; 12] = [
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(1, 0, 0),
    hw(7, 0, 0),
];

/// Opcodes 1, 2 and 3 in turn, then 7.
const TWOS_THREES: [u32; 10] = [
    hw(1, 0, 0),
    hw(2, 0, 0),
    hw(3, 0, 0),
    hw(2, 0, 0),
    hw(1, 0, 0),
    hw(3, 0, 0),
    hw(2, 0, 0),
    hw(3, 0, 0),
    hw(1, 0, 0),
    hw(7, 0, 0),
];

/// The register's word: the main loop at `QMLP`, the bases, enabled, and
/// D's enable as `d` says.
fn d_register(d: bool) -> u32 {
    let d = if d { macro_dispatch::D_ENABLE } else { 0 };
    macro_dispatch::word(QMLP as u16, LOCALP_AT as u16, AP_AT as u8) | d
}

/// The main loop's machine running the halfwords `program` from `code`,
/// the register `register`, a sequence break as `sequence_break` says;
/// condition 6's call returns, or with `fault_stops` jumps to opcode 7.
/// muir's `d_machine`, PDL-INDEX loaded by the first word rather than
/// preset.
fn d_machine(register: u32, program: &[u32], code: Word, sequence_break: bool, fault_stops: bool) -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    let fd = |c: u64| c << 19 | 0o37 << 14;
    let inc = |m: u64| ALU | M_PLUS_C | CARRY_IN | m_src(m) | m_dest(m);
    let mut put = |at: u64, w: u64| {
        p.fill_to(at);
        assert_eq!(p.at(), at, "the machine's words in order");
        p.op(w);
    };
    put(0, ALU | SETA | a_src(0o54) | fd(0o13));
    // A read of main memory first, which takes down the `-VMAOK` the boot
    // leaves, so that condition 6 is false at the first return.
    put(1, ALU | SETA | a_src(0o55) | START_READ);
    put(2, ALU | SETA | a_src(0o51) | fd(5));
    put(3, ALU | SETA | a_src(0o52) | fd(1));
    put(4, ALU | SETA | a_src(0o53) | fd(2));
    put(5, ALU | SETA | a_src(0o50) | fd(0o15));
    put(6, ALU | SETA | a_src(LOCALP_AT) | a_dest(LOCALP_AT));
    put(7, ALU | SETM | m_src(AP_AT) | m_dest(AP_AT) | POPJ);
    put(QMLP, JUMP | target(COND_6) | P | 1 << 5 | 6);
    put(QMLP + 1, ALU | SETM | SRC_MD | m_dest(0o31));
    put(QMLP + 2, DISPATCH | m_src(0o31) | 3 << 10 | 31 | 5 << 5 | OPDTB << 12);
    put(QMLP + 3, ALU | SETA | a_src(0o50) | fd(0o15));
    if fault_stops {
        put(COND_6, inc(0o10));
        put(COND_6 + 1, JUMP | target(OP_7) | ALWAYS | N);
    } else {
        put(COND_6, inc(0o10) | POPJ);
    }
    put(OP_6, ALU | SETM | src(0o14) | m_dest(0o20));
    put(OP_6 + 1, inc(6));
    put(OP_6 + 2, ALU | SETA | a_src(0o50) | fd(0o15));
    put(OP_6 + 4, filler().raw() | POPJ);
    put(OP_7, JUMP | target(OP_7) | ALWAYS | N);
    put(OP_1, inc(1));
    put(OP_1 + 1, filler().raw() | POPJ);
    // The microcycle after its return pushes M 31 as it finds it.
    put(OP_1 + 2, ALU | SETM | m_src(0o31) | fd(0o11));
    put(OP_10, ALU | SETM | m_src(0o31) | fd(0o11));
    put(OP_10 + 1, ALU | SETM | src(3) | fd(0o11));
    put(OP_10 + 2, ALU | SETA | a_src(0o54) | fd(0o13) | POPJ);
    let table = [(1u64, OP_1), (6, 1 << 15 | 1 << 14 | OP_6), (7, OP_7), (0o10, OP_10)];
    for &(op, at) in &table {
        p.dmem.push(((OPDTB + op) as usize, at as u32));
    }
    for k in 0..macro_dispatch::ENTRIES {
        let op = (k >> 3 & 0o37) as u64;
        let mut e = table.iter().find(|t| t.0 == op).map_or(0, |t| t.1 as u32);
        if op == 0o10 {
            e |= macro_dispatch::OPERAND;
        }
        if e != 0 {
            p.mdmem.push((k, e));
        }
    }
    p.amem.push((0o50, Word::from(MAIN)));
    p.amem.push((0o51, Word::from(register)));
    p.amem.push((0o52, code * 4));
    p.amem.push((0o53, if sequence_break { 1 << 34 } else { 0 }));
    p.amem.push((0o54, SENTINEL));
    p.amem.push((0o55, 0o36000000000));
    p.amem.push((LOCALP_AT, LOCALP));
    let base = (code & 0o1777777777) as usize;
    if code == CODE {
        for (k, pair) in program.chunks(2).enumerate() {
            p.main.push((base + k, Word::from(pair[0] | pair.get(1).copied().unwrap_or(0) << 16)));
        }
    }
    p
}

/// A run of `p` that parks at opcode 7's handler.
pub fn parked(p: &Preset) -> Case {
    let mut c = p.case("x");
    c.park = OP_7;
    c
}

/// **The main loop's runs**, D off: the machines, and the planted pairs.
pub fn main_loop() -> Vec<(String, Case)> {
    let mut v: Vec<(String, Case)> = machines(&[false]).into_iter().map(|(n, p)| (n, parked(&p))).collect();
    v.extend(planted_pairs().into_iter().map(|(n, p)| (n, parked(&p))));
    v
}

/// muir's `ml_machine`: the main loop's machine with opcode 2's handler, a
/// return at its first word, and opcode 3's, `body` before its return; each
/// pushes M 31 as the microcycle after its return finds it.
fn ml_machine(program: &[u32], body: &[u64]) -> Preset {
    let mut p = d_machine(d_register(false), program, CODE, false, false);
    let fd = |c: u64| c << 19 | 0o37 << 14;
    let mut put = |at: u64, w: u64| {
        p.fill_to(at);
        assert_eq!(p.at(), at, "the machine's words in order");
        p.op(w);
    };
    put(OP_2, filler().raw() | POPJ);
    put(OP_2 + 1, ALU | SETM | m_src(0o31) | fd(0o11));
    let n = body.len() as u64;
    for (k, &w) in body.iter().enumerate() {
        put(OP_3 + k as u64, w);
    }
    put(OP_3 + n, filler().raw() | POPJ);
    put(OP_3 + n + 1, ALU | SETM | m_src(0o31) | fd(0o11));
    p.dmem.push(((OPDTB + 2) as usize, OP_2 as u32));
    p.dmem.push(((OPDTB + 3) as usize, OP_3 as u32));
    for k in 0..macro_dispatch::ENTRIES {
        match k >> 3 & 0o37 {
            2 => p.mdmem.push((k, OP_2 as u32)),
            3 => p.mdmem.push((k, OP_3 as u32)),
            _ => {}
        }
    }
    p
}

/// **RD's return inputs and the guard on planted pairs** (A15b.16; muir's
/// `rd_s_lc_copy_on_planted_pairs` and `each_case_of_the_guard_on_planted_pairs`),
/// D off: a return right after the microcycle that steps LC, and right
/// after a write of LC; right after a word that writes INTERRUPT-CONTROL,
/// M 31, the MACRO-DISPATCH register or an entry, or pushes SPC data; M 31
/// written two words before and three; a control-store write before a
/// return, which clears the register's enable (`write_imem`); an entry
/// written by destinations 6 and 7 that the next fused return reads; and
/// opcode 6, whose entry has P, in a word's second halfword, where the
/// return before it would fuse but for the entry.
fn planted_pairs() -> Vec<(String, Preset)> {
    use muir::isa::asm::R;
    let fd = |c: u64| c << 19 | 0o37 << 14;
    let f = filler().raw();
    let mut v = Vec::new();
    v.push(("pair-step".to_string(), ml_machine(&TWOS_THREES, &[])));
    v.push(("pair-lc".to_string(), ml_machine(&TWOS_THREES, &[ALU | SETM | src(0o13) | fd(1)])));
    // Each case's constants first, in a machine of its own.
    type Body = fn(&mut Preset, &dyn Fn(u64) -> u64, u64) -> Vec<u64>;
    let cases: [(&str, Body); 9] = [
        ("guard-ic", |_, fd, _| vec![ALU | SETA | a_src(0o53) | fd(2)]),
        ("guard-m31", |p, _, _| {
            let sevens = p.k(Word::from(hw(7, 0, 0) | hw(7, 0, 0) << 16));
            vec![ALU | SETA | a_src(sevens) | m_dest(0o31)]
        }),
        ("guard-register", |p, fd, _| {
            let disabled = p.k(Word::from(d_register(false) & !macro_dispatch::ENABLE));
            vec![ALU | SETA | a_src(disabled) | fd(5)]
        }),
        ("guard-entry", |p, fd, _| {
            let entry_7 = p.k(OP_7);
            vec![ALU | SETA | a_src(0o40) | fd(6), ALU | SETA | a_src(entry_7) | fd(7)]
        }),
        ("guard-push", |p, fd, _| {
            let to_7 = p.k(OP_7);
            vec![ALU | SETA | a_src(to_7) | fd(0o15)]
        }),
        ("guard-m31-two", |p, _, f| {
            let sevens = p.k(Word::from(hw(7, 0, 0) | hw(7, 0, 0) << 16));
            vec![ALU | SETA | a_src(sevens) | m_dest(0o31), f]
        }),
        ("guard-m31-three", |p, _, f| {
            let sevens = p.k(Word::from(hw(7, 0, 0) | hw(7, 0, 0) << 16));
            vec![ALU | SETA | a_src(sevens) | m_dest(0o31), f, f]
        }),
        ("imem-disables", |_, _, f| vec![JUMP | P | R | N | ALWAYS | target(0o700), f]),
        // An entry written by destinations 6 and 7 two words before a
        // return that fuses on it: opcode 2's, index 20, goes to 7's stop.
        ("entry-written", |p, fd, f| {
            let (index, entry_7) = (p.k(0o20), p.k(OP_7));
            vec![ALU | SETA | a_src(index) | fd(6), ALU | SETA | a_src(entry_7) | fd(7), f]
        }),
    ];
    // Opcode 6, whose entry has P, in a word's second halfword, where the
    // return before it fuses but for the entry.
    let mut program = ONES;
    program[5] = hw(6, 0, 0);
    v.push(("entry-p-second".to_string(), d_machine(d_register(false), &program, CODE, false, false)));
    for (name, body) in cases {
        // The constants the body asks for, then the machine around it.
        let mut scratch = Preset::new();
        let words = body(&mut scratch, &fd, f);
        let mut p = ml_machine(&TWOS_THREES, &words);
        // A constant's address is the same from the machine's first `k`.
        p.amem.extend(scratch.amem.iter().copied());
        v.push((name.to_string(), p));
    }
    v
}

/// The machines, D on as `ds` says: D off alone until the core builds D.
pub fn machines(ds: &[bool]) -> Vec<(String, Preset)> {
    let mut v = Vec::new();
    for &d in ds {
        let on = if d { "d" } else { "nod" };
        let r = d_register(d);
        v.push((format!("ones-{on}"), d_machine(r, &ONES, CODE, false, false)));
        v.push((format!("break-{on}"), d_machine(r, &ONES, CODE, true, false)));
        v.push((format!("fault-{on}"), d_machine(r, &ONES, UNMAPPED, false, true)));
        let mut program = ONES;
        program[4] = hw(6, 0, 0);
        v.push((format!("entry-p-{on}"), d_machine(r, &program, CODE, false, false)));
        let program = [hw(1, 0, 0), hw(1, 0, 0), hw(0o10, 5, 5), hw(7, 0, 0)];
        v.push((format!("operand-{on}"), d_machine(r, &program, CODE, false, false)));
        let program = [hw(0o10, 5, 5), hw(0o10, 6, 3), hw(1, 0, 0), hw(0o10, 5, 1), hw(7, 0, 0)];
        v.push((format!("operands-{on}"), d_machine(r, &program, CODE, false, false)));
    }
    v
}

/// **A PDL address field reads M-AP and A-LOCALP as the word finds them**
/// (A15b.2), the word right before it, or the one before that, having
/// written them: the register's M-AP M 0 and A-LOCALP A 0, written 40 and
/// 60, read by a field whose index is 40 + 5 and 60 − 3, and the PDL buffer
/// read through the index in the next word (muir's
/// `a_pdl_field_reads_a_base_the_word_before_wrote`).
pub fn field_macro() -> Vec<(String, Preset)> {
    let fd = |c: u64| c << 19 | 0o36 << 14;
    let mut v = Vec::new();
    for gap in [0, 1] {
        let mut p = Preset::new();
        let (k40, k60, k45, k55) = (p.k(0o40), p.k(0o60), p.k(0o45), p.k(0o55));
        for (at, val) in [(k45, 0o4545), (k55, 0o5555)] {
            let kv = p.k(val);
            p.op(ALU | SETA | a_src(at) | fd(0o13));
            p.op(ALU | SETA | a_src(kv) | fd(0o12));
        }
        p.fill(2);
        p.op(ALU | SETA | a_src(k40) | m_dest(0));
        p.fill(gap);
        p.op(ALU | SETA | a_src(k45) | fd(0o13) | pdl_field(0, 5));
        p.op(ALU | SETM | src(0o5) | m_dest(0o26));
        p.op(ALU | SETA | a_src(k60) | a_dest(0));
        p.fill(gap);
        p.op(ALU | SETA | a_src(k55) | fd(0o13) | pdl_field(1, -3));
        p.op(ALU | SETM | src(0o5) | m_dest(0o27));
        p.fill(1);
        p.stop();
        v.push((format!("gap{gap}"), p));
    }
    v
}
