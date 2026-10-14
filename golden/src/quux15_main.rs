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
//!             fused on M 31, and with D on, the returns that need one
//!             decided at their word's arrival; the planted pairs, D off and
//!             on; D's own machines; and a PDL address field
//!             on M-AP and on A-LOCALP written by the word right before it,
//!             or the one before that (muir's
//!             `a_pdl_field_reads_a_base_the_word_before_wrote`)

use muir::isa::asm::{
    ALU, ALWAYS, CARRY_IN, DISPATCH, JUMP, M_PLUS_C, MD, N, P, POPJ, SETA, SETM, SRC_MD, START_READ,
    START_WRITE, a_dest, a_src, filler, m_dest, m_src, pdl_field, src, target,
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
/// Opcode 11's handler: reads the PDL buffer through PDL-INDEX as its first
/// word finds it, the operand address its return loaded.
const OP_11: u64 = 0o270;
/// Opcode 5's handler, whose entry has N alone: the popped word is not kept,
/// and the handler goes to the park without returning.
const OP_5: u64 = 0o300;
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
/// A memory's zero.
const ZERO: u64 = 0o40;
/// The physical memory window, and the register page.
const PHYSICAL_WINDOW: Word = 0o36000000000;
const REGISTER_PAGE: Word = 0o35777777400;

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

/// **The main loop's runs**: the machines, D off and on; the planted pairs,
/// D off and on; and D's own machines.
pub fn main_loop() -> Vec<(String, Case)> {
    let mut v: Vec<(String, Case)> =
        machines(&[false, true]).into_iter().map(|(n, p)| (n, parked(&p))).collect();
    for d in [false, true] {
        v.extend(planted_pairs(d).into_iter().map(|(n, p)| (n, parked(&p))));
    }
    v.extend(d_timing().into_iter().map(|(n, p)| (n, parked(&p))));
    for d in [false, true] {
        v.extend(byte_steps(d).into_iter().map(|(n, p)| (n, parked(&p))));
    }
    v
}

/// **Returns that fuse in LC byte mode** (INTERRUPT-CONTROL `<3>`), D as
/// `d` says, their runs' names ending `-d` when on.  Opcode 3 is the
/// program's first byte, M 31's `<15:0>` at LC's byte 1; `<23:8>` and
/// `<31:16>`, at bytes 2 and 3, hold opcodes 1 and 7; the next word is all
/// 7s.
///
///   byte-step-popj   opcode 3's handler a dispatch with `IR<24>` whose
///                    entry has R and P, so that it falls through and its
///                    POPJ returns at the microcycle's end: the step leaves
///                    LC at byte 2, no fetch due, and the return fuses on
///                    byte 3, opcode 7, through EX's read port of the MACRO
///                    DISPATCH MEMORY on LC as the step leaves it.  In
///                    halfword mode no such return fuses: a step inside the
///                    word leaves a fetch due, and one past it fetches into
///                    `MD`, which nothing moves to M 31.
///   byte-mode-clear  opcode 3's handler clears byte mode right before its
///                    return: RD plans the return while the write is in EX,
///                    from the copies EX leaves, halfword mode, where it
///                    fuses on `<15:0>`, opcode 3 again, whose return fuses
///                    on opcode 7.
fn byte_steps(d: bool) -> Vec<(String, Preset)> {
    // An entry of dispatch memory beyond the opcode table, R and P.
    const FALL: u64 = 0o2400;
    let program = [hw(3, 0, 0), hw(7, 0, 2), hw(7, 0, 0), hw(7, 0, 0)];
    let on = if d { "-d" } else { "" };
    // Byte mode from the start: A 53, which the machine's word 4 writes to
    // INTERRUPT-CONTROL.
    let byte_mode = |p: &mut Preset| {
        for e in p.amem.iter_mut().filter(|e| e.0 == 0o53) {
            e.1 = 1 << 37;
        }
    };
    let mut v = Vec::new();
    // The handler's first word steps nothing: the microcycle after a fused
    // return must not write LC (muir's `macro_dispatch`).
    let mut p = ml_machine(d, &program, &[filler().raw()]);
    byte_mode(&mut p);
    put_at(&mut p, OP_3 + 1, DISPATCH | 1 << 24 | POPJ | FALL << 12);
    p.dmem.push((FALL as usize, 1 << 16 | 1 << 15));
    v.push((format!("byte-step-popj{on}"), p));
    let mut p = ml_machine(d, &program, &[ALU | SETA | a_src(ZERO) | 2 << 19 | 0o37 << 14]);
    byte_mode(&mut p);
    v.push((format!("byte-mode-clear{on}"), p));
    v
}

/// The word `w` at `at` in `p`'s control store, the words before it as they
/// are or fillers.
fn put_at(p: &mut Preset, at: u64, w: u64) {
    p.fill_to(at + 1);
    p.words[at as usize] = w;
}

/// muir's `ml_machine`: the main loop's machine, D as `d` says, with opcode
/// 2's handler, a return at its first word, and opcode 3's, `body` before
/// its return; each pushes M 31 as the microcycle after its return finds it.
fn ml_machine(d: bool, program: &[u32], body: &[u64]) -> Preset {
    let mut p = d_machine(d_register(d), program, CODE, false, false);
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
/// D as `d` says, its runs' names ending `-d` when on: a return right after
/// the microcycle that steps LC, and right
/// after a write of LC; right after a word that writes INTERRUPT-CONTROL,
/// M 31, the MACRO-DISPATCH register or an entry, or pushes SPC data; M 31
/// written two words before and three; a control-store write before a
/// return, which clears the register's enable (`write_imem`); an entry
/// written by destinations 6 and 7 that the next fused return reads; and
/// opcode 6, whose entry has P, in a word's second halfword, where the
/// return before it would fuse but for the entry.
fn planted_pairs(d: bool) -> Vec<(String, Preset)> {
    use muir::isa::asm::R;
    let fd = |c: u64| c << 19 | 0o37 << 14;
    let f = filler().raw();
    let on = if d { "-d" } else { "" };
    let mut v = Vec::new();
    v.push((format!("pair-step{on}"), ml_machine(d, &TWOS_THREES, &[])));
    v.push((format!("pair-lc{on}"), ml_machine(d, &TWOS_THREES, &[ALU | SETM | src(0o13) | fd(1)])));
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
    v.push((format!("entry-p-second{on}"), d_machine(d_register(d), &program, CODE, false, false)));
    for (name, body) in cases {
        // The constants the body asks for, then the machine around it.
        let mut scratch = Preset::new();
        let words = body(&mut scratch, &fd, f);
        let mut p = ml_machine(d, &TWOS_THREES, &words);
        // A constant's address is the same from the machine's first `k`.
        p.amem.extend(scratch.amem.iter().copied());
        v.push((format!("{name}{on}"), p));
    }
    v
}

/// **D's own machines** (muir's tests of D at its word's
/// arrival), D off and on, their names ending `-nod` and `-d`:
///
/// - `store-*`: a store of two opcode-7 halfwords into the macroinstruction
///   word opcode 3's return's fetch reads, started by the word before the
///   return, by the return, and by its delay slot: D decides on its fetch's
///   own word, which the store wrote (`d_decides_on_the_fetch_s_own_word`);
/// - `slotstack`: the delay slot after opcode 3's return reads the micro
///   stack's pointer and word, popped, as the return left it
///   (`d_s_slot_sees_the_stack_popped`);
/// - `readret`: opcode 3's return starts a read of the program's third word,
///   which lands before the fetch its delay slot starts: D decides on its
///   fetch's word, not the read's;
/// - `opbase`: opcode 3's return right after a word that writes A-LOCALP,
///   fused or decided on opcode 11, LOCAL 2, whose handler reads the PDL
///   buffer through the operand address in its first word
///   (`an_operand_address_over_a_base_the_word_before_writes`);
/// - `ap31`: opcode 10's operand addresses, the register naming M-AP at M 31,
///   which D writes with its word: the address is formed from M-AP as it
///   stood before D's write;
/// - `nxm` and `device`: the macroinstructions where nothing answers, and in
///   the register page: each return's fetch ends D's wait at its WB, to
///   `QMLP`, whose dispatch parks;
/// - `entry-n`: opcode 5, whose entry has N alone, after a return that needs
///   a fetch: D takes it and does not keep the popped word;
/// - `earlier`: a return that needs a fetch while the sequence break stands
///   goes to the main loop without D, its fetch a miss still filling when
///   condition 6's call, taken with N, does what `SB-DEFER` does (the break
///   cleared, LC written back with NEEDFETCH) and returns to the main loop
///   again, where D waits: D decides on its slot's fetch, LC stepped, never
///   on the earlier fill that lands during its wait (muir's
///   `d_decides_on_its_slot_s_fetch_not_an_earlier_one`);
/// - `irq`: opcode 1 eleven times with an interrupt pending and enabled,
///   which a device register's write raises before the main loop: D's wait
///   never begins, and `QMLP`'s condition-6 call counts each return.
fn d_timing() -> Vec<(String, Preset)> {
    let mut v = Vec::new();
    let sevens = Word::from(hw(7, 0, 0) | hw(7, 0, 0) << 16);
    // The stored word at A 60, its address, the program's second word, at A 61.
    let (word_at, addr_at) = (0o60u64, 0o61u64);
    let program = [hw(1, 0, 0), hw(3, 0, 0), hw(1, 0, 0), hw(1, 0, 0), hw(7, 0, 0), hw(7, 0, 0)];
    for d in [false, true] {
        let on = if d { "d" } else { "nod" };
        for by in ["before", "return", "slot"] {
            let body = match by {
                "before" => vec![ALU | SETA | a_src(word_at) | MD, ALU | SETA | a_src(addr_at) | START_WRITE],
                _ => vec![ALU | SETA | a_src(word_at) | MD],
            };
            let n = body.len() as u64;
            let mut p = ml_machine(d, &program, &body);
            match by {
                "return" => put_at(&mut p, OP_3 + n, ALU | SETA | a_src(addr_at) | START_WRITE | POPJ),
                "slot" => put_at(&mut p, OP_3 + n + 1, ALU | SETA | a_src(addr_at) | START_WRITE),
                _ => {}
            }
            p.amem.push((word_at, sevens));
            p.amem.push((addr_at, CODE + 1));
            v.push((format!("store-{by}-{on}"), p));
        }
        // The slot: M 26 <- the stack's pointer and word.
        let mut p = ml_machine(d, &[hw(1, 0, 0), hw(3, 0, 0), hw(1, 0, 0), hw(7, 0, 0)], &[]);
        put_at(&mut p, OP_3 + 1, ALU | SETM | src(0o1) | m_dest(0o26));
        v.push((format!("slotstack-{on}"), p));
        // The return: a read of the program's third word.
        let mut p = ml_machine(d, &[hw(1, 0, 0), hw(3, 0, 0), hw(1, 0, 0), hw(1, 0, 0), hw(7, 0, 0)], &[]);
        put_at(&mut p, OP_3, ALU | SETA | a_src(addr_at) | START_READ | POPJ);
        p.amem.push((addr_at, CODE + 2));
        v.push((format!("readret-{on}"), p));
        // Opcode 11, LOCAL 2, after opcode 3's return, A-LOCALP written right
        // before it.
        let mut p = ml_machine(
            d,
            &[hw(3, 0, 0), hw(0o11, 5, 2), hw(1, 0, 0), hw(7, 0, 0)],
            &[ALU | SETA | a_src(LOCALP_AT) | a_dest(LOCALP_AT)],
        );
        let fd = |c: u64| c << 19 | 0o37 << 14;
        put_at(&mut p, OP_11, ALU | SETM | src(0o5) | m_dest(0o27));
        put_at(&mut p, OP_11 + 1, filler().raw() | POPJ);
        put_at(&mut p, OP_11 + 2, ALU | SETM | m_src(0o31) | fd(0o11));
        p.dmem.push(((OPDTB + 0o11) as usize, OP_11 as u32));
        for k in 0..macro_dispatch::ENTRIES {
            if k >> 3 & 0o37 == 0o11 {
                p.mdmem.push((k, OP_11 as u32 | macro_dispatch::OPERAND));
            }
        }
        v.push((format!("opbase-{on}"), p));
        // M-AP at M 31.
        let d_bit = if d { macro_dispatch::D_ENABLE } else { 0 };
        let r = macro_dispatch::word(QMLP as u16, LOCALP_AT as u16, 0o31) | d_bit;
        let program = [hw(0o10, 6, 5), hw(0o10, 6, 3), hw(1, 0, 0), hw(0o10, 6, 1), hw(0o10, 5, 2), hw(7, 0, 0)];
        v.push((format!("ap31-{on}"), d_machine(r, &program, CODE, false, false)));
        // Fetches nothing answers, and fetches of the register page: every
        // opcode's dispatch parks.
        for (what, code) in [("nxm", PHYSICAL_WINDOW + 0o1000000000), ("device", REGISTER_PAGE)] {
            let mut p = d_machine(d_register(d), &[], code, false, false);
            for op in 0..0o40u64 {
                if ![1, 6, 7, 0o10].contains(&op) {
                    p.dmem.push(((OPDTB + op) as usize, OP_7 as u32));
                }
            }
            v.push((format!("{what}-{on}"), p));
        }
        // Opcode 5, its entry N alone, in the second word's first halfword.
        let mut p = d_machine(d_register(d), &[hw(1, 0, 0), hw(1, 0, 0), hw(5, 0, 0), hw(7, 0, 0)], CODE, false, false);
        put_at(&mut p, OP_5, JUMP | target(OP_7) | ALWAYS | N);
        p.dmem.push(((OPDTB + 5) as usize, 1 << 14 | OP_5 as u32));
        for k in 0..macro_dispatch::ENTRIES {
            if k >> 3 & 0o37 == 5 {
                p.mdmem.push((k, macro_dispatch::N | OP_5 as u32));
            }
        }
        v.push((format!("entry-n-{on}"), p));
        // A fetch in flight from before the return D waits on.
        let fd = |c: u64| c << 19 | 0o37 << 14;
        let mut p = d_machine(d_register(d), &[hw(1, 0, 0), hw(7, 0, 0), hw(1, 0, 0), hw(7, 0, 0)], CODE, true, false);
        put_at(&mut p, QMLP, JUMP | target(COND_6) | P | N | 1 << 5 | 6);
        put_at(&mut p, COND_6, ALU | M_PLUS_C | CARRY_IN | m_src(0o10) | m_dest(0o10));
        put_at(&mut p, COND_6 + 1, ALU | SETA | a_src(ZERO) | fd(2));
        put_at(&mut p, COND_6 + 2, ALU | SETM | src(0o14) | m_dest(0o27));
        put_at(&mut p, COND_6 + 3, ALU | SETA | a_src(0o50) | fd(0o15));
        put_at(&mut p, COND_6 + 4, ALU | SETA | a_src(0o52) | fd(1));
        put_at(&mut p, COND_6 + 5, filler().raw() | POPJ);
        v.push((format!("earlier-{on}"), p));
        // An interrupt pending and enabled: word 0 goes to 40, which raises
        // it by a device register's write, and comes back.
        let mut p = d_machine(d_register(d), &ONES, CODE, false, false);
        let first = p.words[0];
        let (raise, command) = (p.k(1 << 11), p.k(REGISTER_PAGE | 0o200));
        p.words[0] = JUMP | target(0o40) | ALWAYS | N;
        put_at(&mut p, 0o40, first);
        put_at(&mut p, 0o41, ALU | SETA | a_src(raise) | MD);
        put_at(&mut p, 0o42, ALU | SETA | a_src(command) | START_WRITE);
        put_at(&mut p, 0o43, JUMP | target(1) | ALWAYS | N);
        // INTERRUPT-CONTROL's enable, `<27>`, which word 4 writes.
        p.amem.push((0o53, 1 << 35));
        v.push((format!("irq-{on}"), p));
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

/// **A store and its page check right before a fused return into an
/// operand's handler** (A15b.9, A15b.16), as microcode 2002's `QSANUM`
/// ends and `QIMOVE-PDL-OPERAND` begins, under the port's timings and
/// muir's seeded memory model: opcode 3's handler reads a word of main
/// memory (`VMA-START-READ`, `CHECK-PAGE-READ`, the word into A), stores
/// into it (`WRITE-MEMORY-DATA-START-WRITE`, `CHECK-PAGE-WRITE`) and
/// returns with N (`CPOPJ`), fused on opcode 11, ARG 0, whose handler
/// pushes the PDL buffer's word at PDL-INDEX in its first word, its return
/// after the next, and reads it again in that next: PDL-INDEX must hold
/// the operand address the return armed when the handler's first word
/// reads it.  D off and on; the port as the traces' period makes it and at
/// the Kria's, slower and faster; each with the memory model off and with
/// twelve seeds answering each write up to 50 clocks late.  The faster
/// port's fill and write are held to `FILL_FLOOR` and `WRITE_FLOOR` clocks
/// at the period: at a long period its 100 ns and 40 ns would be fewer
/// clocks than the fabric's port can fill a line or answer a write in.
pub fn store_return(period: u64) -> Vec<(String, Case)> {
    use muir::isa::asm::R;
    use muir::pipeline::PortTiming;
    use muir::pipeline::port::LateModel;
    let fd = |c: u64| c << 19 | 0o37 << 14;
    let program = [hw(3, 0, 0), hw(0o11, 6, 0), hw(1, 0, 0), hw(0o11, 6, 1), hw(7, 0, 0)];
    let (word_at, addr_at, tem) = (0o60u64, 0o61u64, 0o62u64);
    // The page fault's handler, which no run reaches: the park.
    const PGF: u64 = 0o320;
    let timings = [
        ("t0", None),
        ("kria", Some(PortTiming { read_ns: 247, write_ns: 130, occupancy_ns: 10 })),
        ("slow", Some(PortTiming { read_ns: 600, write_ns: 400, occupancy_ns: 40 })),
        ("fast", Some(PortTiming { read_ns: 100, write_ns: 40, occupancy_ns: 10 })),
    ];
    // A fill or a write under its floor at this period takes the floor:
    // its clocks times the period in ns, the period being in units of
    // 0.5 ns.
    let time = muir::clock::TimeBase::half_ns(period);
    let timings = timings.map(|(tn, t)| {
        (tn, t.map(|mut t| {
            if t.clocks(time).read < super::FILL_FLOOR {
                t.read_ns = super::FILL_FLOOR * period / 2;
                assert_eq!(t.clocks(time).read, super::FILL_FLOOR, "the fill's floor at period {period}");
            }
            if t.clocks(time).write < super::WRITE_FLOOR {
                t.write_ns = super::WRITE_FLOOR * period / 2;
                assert_eq!(t.clocks(time).write, super::WRITE_FLOOR, "the write's floor at period {period}");
            }
            t
        }))
    });
    let mut v = Vec::new();
    for d in [false, true] {
        let on = if d { "d" } else { "nod" };
        for (tn, timing) in timings {
            for seed in 0..=12u64 {
                let body = [
                    ALU | SETA | a_src(addr_at) | START_READ,
                    JUMP | target(PGF) | P | N | 1 << 5 | 5,
                    ALU | SETM | SRC_MD | a_dest(tem),
                    ALU | SETA | a_src(word_at) | fd(0o32),
                    JUMP | target(PGF) | P | N | 1 << 5 | 5,
                ];
                let n = body.len() as u64;
                let mut p = ml_machine(d, &program, &body);
                // The return as `CPOPJ` is: a jump with R and N, no slot.
                put_at(&mut p, OP_3 + n, JUMP | ALWAYS | R | N);
                put_at(&mut p, PGF, JUMP | target(OP_7) | ALWAYS | N);
                // `QIMOVE-PDL-OPERAND`: the push of the PDL buffer's word at
                // PDL-INDEX, its return after the next word, which reads it
                // again into M 27.
                put_at(&mut p, OP_11, ALU | SETM | src(0o5) | fd(0o11) | POPJ);
                put_at(&mut p, OP_11 + 1, ALU | SETM | src(0o5) | m_dest(0o27));
                p.dmem.push(((OPDTB + 0o11) as usize, OP_11 as u32));
                for k in 0..macro_dispatch::ENTRIES {
                    if k >> 3 & 0o37 == 0o11 {
                        p.mdmem.push((k, OP_11 as u32 | macro_dispatch::OPERAND));
                    }
                }
                p.amem.push((word_at, 0o0240003350000));
                p.amem.push((addr_at, PHYSICAL_WINDOW + 0o1030));
                // The PDL buffer's words at the operand address, M-AP + 1,
                // and at the index the machine starts with, apart: a read
                // at the index left standing reads the second.
                let first = p.words[0];
                let (one, operand, sentinel, stale) = (p.k(1), p.k(0o1111), p.k(SENTINEL), p.k(0o7777));
                p.words[0] = JUMP | target(0o340) | ALWAYS | N;
                put_at(&mut p, 0o340, ALU | SETA | a_src(one) | fd(0o13));
                put_at(&mut p, 0o341, ALU | SETA | a_src(operand) | fd(0o12));
                put_at(&mut p, 0o342, ALU | SETA | a_src(sentinel) | fd(0o13));
                put_at(&mut p, 0o343, ALU | SETA | a_src(stale) | fd(0o12));
                put_at(&mut p, 0o344, first);
                put_at(&mut p, 0o345, JUMP | target(1) | ALWAYS | N);
                p.timing = timing;
                if seed > 0 {
                    p.late = Some(LateModel { seed, most: 50, errors: 0 });
                }
                let mut c = parked(&p);
                c.name = format!("storeret-{on}-{tn}-{seed}");
                v.push((c.name.clone(), c));
            }
        }
    }
    v
}
