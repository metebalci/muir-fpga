// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's console** (contract G3 revision 15, A15b.13): runs that a
//! console halts, steps, resumes, reads and boots through the diagnostic
//! registers, as `muir::spy` names them, at the clocks the trace's lines
//! give.
//!
//!   console   halts mid-run and resumes; two halts; single steps from a
//!             halt, each a microcycle; the debug IR's four halves, a word
//!             of the console's run in place of the one at PC, its
//!             extension through strobe 6 and its alias 14 (7 and 15
//!             loading nothing); `-RESET` and `-BOOT` from the mode
//!             register; a HALT word under ERROR-STOP-ENABLE, which drains
//!             and holds until the enable is cleared
//!             (and OA-OUTSIDE-FIELDS's freeze: the machine stopped
//!             mid-clock, the word in EX, read as it stands)
//!   halts     a halt at every clock of five programs, of a write start in
//!             a mispredicted jump's delay slot, a read's word landing
//!             around it, and of a write started by a read start's
//!             successor, and at every third clock of two of muir's
//!             programs at random with memory, each resumed at once and run
//!             to its park
//!
//! **THE TRACE SAYS WHAT THE CONSOLE DID AND WHAT IT READ**:
//!
//! ```text
//! # spy <clock> <register> <word>       written before that clock
//! # read <clock> <register> <word>      read as that clock ends, halted
//! # halted <clock> <bytes>              halted, drained, as that clock ends
//! ```
//!
//! `<bytes>` are the end of muir's own checkpoint of the halted pipeline
//! (`Pipeline::save`, revision 15's version 51): what `save_15` writes after
//! the machine, the period and the port, the state between two microcycles
//! the halt leaves (A15b.13). The testbench reads the same fields from the
//! core and writes them in muir's order, and the two must be the same bytes.

use muir::checkpoint::Writer;
use muir::engine::Engine;
use muir::isa::asm::{ADD, ALU, OA_HIGH_SELECT, SETA, a_src, m_dest, m_src};
use muir::machine::Word;
use muir::pipeline::Pipeline;
use muir::spy;

use super::quux15_preset::Preset;
use super::{Case, program};

/// A console's action, in a script's order.
#[derive(Clone, Copy, Debug)]
pub enum Act {
    /// Clocks run.
    Wait(u64),
    /// A diagnostic register written, and the clock after it run: one
    /// write a clock, as a console's bus cycles are, from the second clock
    /// on (a fabric's write lands at an edge, and the first clock has none
    /// before it).
    Spy(u8, u16),
    /// Clocks run until the machine is halted, drained; the halted state
    /// recorded.
    UntilHalted,
    /// The sixteen registers read.
    Reads,
    /// Clocks of a machine stopped at the error its case ends at, frozen
    /// mid-clock as muir's pipeline stops (OA-OUTSIDE-FIELDS, A15b.15).
    Frozen(u64),
}

use Act::*;

/// The end of muir's checkpoint of `e`, halted: `save_15`'s fields after
/// the machine, the period and the port, in hexadecimal.
pub fn tail_hex(e: &Pipeline) -> String {
    let mut all = Writer::new();
    e.save(&mut all);
    let all = all.finish();
    let mut head = Writer::new();
    e.machine().save(&mut head);
    head.u64(e.period());
    e.port.save(&mut head);
    let n = head.finish().len();
    let mut tail = all[n..].to_vec();
    // **The micro stack's pending word at the stack's 19 bits**: muir keeps a
    // data push's 32 (`exec.rs`'s `push_spc(data)`) and reads 19 back, as
    // `SPC<18:0>` holds; the core keeps 19. The fields before it, walked.
    let mut at = 2;
    at += if tail[at] == 1 { 3 } else { 1 };
    at += 2;
    at += if tail[at] == 1 { 8 } else { 1 };
    at += if tail[at] == 1 { 6 } else { 1 };
    at += 2 + 16 + 2 + 4 + 1;
    if tail[at] == 1 {
        let w = u32::from_le_bytes([tail[at + 2], tail[at + 3], tail[at + 4], tail[at + 5]]) & 0o1777777;
        tail[at + 2..at + 6].copy_from_slice(&w.to_le_bytes());
    }
    tail.iter().map(|b| format!("{b:02x}")).collect()
}

/// The run halted at the start of clock `at`, 2 or later, its halt read,
/// and resumed.
fn halt_at(at: u64) -> Vec<Act> {
    assert!(at >= 2, "a console's write lands from the second clock on");
    vec![Wait(at - 1), Spy(spy::CLK, 0), UntilHalted, Wait(2), Spy(spy::CLK, 1)]
}

/// RUN cleared, the halt waited for, the registers read.
fn halt_and_read() -> Vec<Act> {
    vec![Spy(spy::CLK, 0), UntilHalted, Wait(2), Reads]
}

/// The debug IR's four halves, `IR<15:0>` up, the extension through strobe
/// `ext` (6 or its alias 14), then one step with `IDEBUG` up, as CC's
/// `CC-EXECUTE` makes it.
fn execute(ir: u64, ext: u8) -> Vec<Act> {
    let half = |k: u32| (ir >> (16 * k)) as u16;
    vec![
        Spy(spy::IR_LOW, half(0)),
        Spy(spy::IR_MED, half(1)),
        Spy(spy::IR_HIGH, half(2)),
        Spy(ext, half(3)),
        Spy(spy::CLK, 0o12),
        Spy(spy::CLK, 0o10),
        UntilHalted,
        Spy(spy::CLK, 0),
        Wait(2),
        Reads,
    ]
}

/// A case of `name`'s program with `script`.
fn scripted(name: &str, prog: &str, period: u64, script: Vec<Act>, micro_check: bool) -> Case {
    let mut c = Case::of_prog(name, &program(prog, period));
    c.script = script;
    c.micro_check = micro_check;
    c
}

/// **The console's runs.**
pub fn console(period: u64) -> Vec<Case> {
    let mut v = Vec::new();
    // A halt mid-run: CS and RD squashed, EX and WB done, the port empty;
    // read; resumed.
    let mut s = vec![Wait(29)];
    s.extend(halt_and_read());
    s.push(Spy(spy::CLK, 1));
    v.push(scripted("halt-resume", "transfer", period, s, true));
    // Two halts.
    let mut s = vec![Wait(19), Spy(spy::CLK, 0), UntilHalted, Wait(1), Spy(spy::CLK, 1), Wait(30)];
    s.extend(halt_and_read());
    s.push(Spy(spy::CLK, 1));
    v.push(scripted("halt-twice", "stack", period, s, true));
    // Single steps from a halt: STEP raised and lowered, a microcycle each.
    let mut s = vec![Wait(24), Spy(spy::CLK, 0), UntilHalted];
    for _ in 0..8 {
        s.extend([Spy(spy::CLK, 2), Spy(spy::CLK, 0), UntilHalted, Wait(2), Reads]);
    }
    s.push(Spy(spy::CLK, 1));
    v.push(scripted("steps", "transfer", period, s, true));
    // The debug IR, as muir's `the_pipeline_runs_the_debug_ir_s_64_bits_as_
    // micro_does`: OA-REG-HIGH written, then an ADD whose SH, in the
    // extension, ORs it into A 1700 and M 20, making them A 1703 and M 24:
    // M 25 the sum, 33 + 22. Strobes 7 and 15 load nothing.
    let mut p = Preset::new();
    p.amem.push((0o1703, 0o33));
    p.mmem.push((0o24, 0o22));
    let oa = p.k(3 << 6 | 4);
    p.fill(200);
    p.stop();
    let words = [
        ALU | SETA | a_src(oa) | super::fd(0o17),
        ALU | ADD | a_src(0o1700) | m_src(0o20) | m_dest(0o25) | OA_HIGH_SELECT,
    ];
    let mut s = vec![Wait(39)];
    s.extend(halt_and_read());
    s.extend([Spy(7, 0xffff), Spy(15, 0xffff)]);
    s.extend(execute(words[0], spy::LDDBIRX));
    s.extend(execute(words[1], 14));
    s.push(Spy(spy::CLK, 1));
    let mut c = p.case("debug-ir");
    c.script = s;
    c.micro_check = false;
    v.push(c);
    // -RESET and then -BOOT from the mode register, halted: the reset leaves
    // RUN as it was; the boot sets it and starts the PROM again.
    let mut s = vec![Wait(39)];
    s.extend(halt_and_read());
    s.extend([Spy(spy::MODE, spy::MODE_RESET), Wait(2), Reads, Spy(spy::MODE, spy::MODE_BOOT)]);
    v.push(scripted("reset-boot", "transfer", period, s, false));
    // A HALT word under ERROR-STOP-ENABLE (the mode register's bit 2): the
    // machine drains and halts, the word after it run as the drain runs
    // it. Then a HALT word through the debug IR, the last microcycle: FLAG-1's
    // ERR up, and RUN does not resume the machine while the enable stands;
    // cleared, it does.
    let mut p = Preset::new();
    p.fill(20);
    p.op(ALU | SETA | a_src(super::ONE) | m_dest(0o20) | 1 << 10);
    p.fill(20);
    p.stop();
    let mut s = vec![Wait(1), Spy(spy::MODE, 4), UntilHalted, Wait(2), Reads];
    s.extend(execute(ALU | SETA | a_src(super::ONE) | m_dest(0o21) | 1 << 10, spy::LDDBIRX));
    s.extend([Spy(spy::CLK, 1), Wait(3), Reads, Spy(spy::MODE, 0), Spy(spy::CLK, 1)]);
    let mut c = p.case("halt-word");
    c.script = s;
    c.micro_check = false;
    v.push(c);
    // OA-OUTSIDE-FIELDS's freeze: `oaout` stops before the word commits, the
    // word in EX, and a console reads it there: PC the word's, IR its word.
    v.push(scripted("freeze", "oaout", period, vec![Wait(1000), Frozen(3), Reads], true));
    v
}

/// The clock `case` parks at, run on its own.
fn park_clock(case: &Case, period: u64) -> u64 {
    let mut e = Pipeline::new(super::machine(case));
    e.configure(period, case.timing.unwrap_or(super::TIMING), super::CACHE_WORDS);
    e.port.model = case.late;
    e.boot();
    if case.skip_sweep {
        e.skip_sweep();
    }
    while u64::from(e.machine().opc) != case.park && e.clock() < 100_000 {
        e.tick().expect("the run reaches its park");
    }
    e.clock()
}

/// **A write start in a mispredicted jump's delay slot**: EX's redirect
/// leaves the slot alone in the pipeline, so a halt in the clock after it
/// commits finds RD and CS empty behind a write whose word no word will
/// fix, and fixes it itself, MD as it stands (`clock_once`'s end), as the
/// write is granted or later. A read started `gap` words before the jump,
/// if any, lands its word in MD around then.
fn write_in_slot(gap: Option<usize>) -> Preset {
    use muir::isa::asm::{AEQM, JUMP, SETM, SRC_MD, START_READ, START_WRITE, target};
    const PHYS: Word = 0o36000000000;
    let mut p = Preset::new();
    p.skip_sweep = true;
    p.main.push((0o10, 0o123321));
    let (r, w) = (p.k(PHYS | 0o10), p.k(PHYS | 0o20));
    if let Some(gap) = gap {
        p.op(ALU | SETA | a_src(r) | START_READ);
        p.fill(gap);
    }
    p.op(JUMP | AEQM | a_src(super::ZERO) | m_src(super::M_ZERO) | target(0o100));
    p.op(ALU | SETA | a_src(w) | START_WRITE);
    p.fill_to(0o100);
    p.fill(2);
    p.op(ALU | SETM | SRC_MD | m_dest(0o21));
    p.stop();
    p
}

/// **A write started right after a read start, its word fixed by a halt**:
/// MD-START-WRITE as the read's successor waits in EX for the read to land
/// and leaves the read's word in MD, whatever it wrote (A15b.3); it writes
/// M 31 too, so the return behind it waits in RD under the guard while it
/// is in EX and WB. A halt in its first clock in WB finds EX empty and
/// fixes the write's word with MD as it stands, the read's, as the write is
/// granted (`clock_once`'s end); a read of the word after the resume shows
/// which word was written. Run unhalted, muir's pipeline writes the word
/// the successor wrote to MD, and `micro` the read's: these runs are held to
/// muir's pipeline alone.
fn write_after_read() -> Preset {
    use muir::isa::asm::{POPJ, SETM, SRC_MD, START_READ};
    const PHYS: Word = 0o36000000000;
    let mut p = Preset::new();
    p.skip_sweep = true;
    p.main.push((0o10, 0o123321));
    let ret = 0o100;
    let (back, r, x) = (p.k(ret), p.k(PHYS | 0o10), p.k(0o4444));
    p.op(ALU | SETA | a_src(back) | super::fd(0o15));
    p.fill(3);
    p.op(ALU | SETA | a_src(r) | START_READ);
    p.op(ALU | SETA | a_src(x) | 0o32 << 19 | 0o31 << 14);
    p.op(ALU | ADD | a_src(super::ONE) | m_src(0o20) | m_dest(0o20) | POPJ);
    p.fill(1);
    p.fill_to(ret);
    p.op(ALU | SETA | a_src(r) | START_READ);
    p.fill(1);
    p.op(ALU | SETM | SRC_MD | m_dest(0o22));
    p.stop();
    p
}

/// **A halt at every clock**: each a run of its own, halted at the start
/// of that clock, its halted state recorded, resumed at once.
pub fn halts(period: u64) -> Vec<Case> {
    let mut v = Vec::new();
    for prog in ["transfer", "stack", "pdl", "oa", "muldiv"] {
        let base = Case::of_prog(prog, &program(prog, period));
        let end = park_clock(&base, period);
        for at in 2..=end {
            v.push(scripted(&format!("{prog}-{at}"), prog, period, halt_at(at), true));
        }
    }
    for gap in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
        let p = write_in_slot(gap);
        let end = park_clock(&p.case("x"), period);
        let tag = gap.map_or("alone".to_string(), |g| g.to_string());
        for at in 2..=end {
            let mut c = p.case(&format!("slotwrite-{tag}-{at}"));
            c.script = halt_at(at);
            v.push(c);
        }
    }
    let p = write_after_read();
    let end = park_clock(&p.case("x"), period);
    for at in 2..=end {
        let mut c = p.case(&format!("readwrite-{at}"));
        c.script = halt_at(at);
        c.micro_check = false;
        v.push(c);
    }
    for seed in [1u64, 2] {
        let p = super::quux15_preset::random_program(seed, true);
        let end = park_clock(&p.case("x"), period);
        for at in (2..=end).step_by(3) {
            let mut c = p.case(&format!("randmem-{seed}-{at}"));
            c.script = halt_at(at);
            v.push(c);
        }
    }
    v
}
