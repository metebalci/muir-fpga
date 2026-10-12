// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **A register read's side effect and the halt** (G3 revision 15, A15b.3's
//! row "A device register" and A15b.13's "The halt"; the register read
//! ruling and its halt release): runs of `golden/src/quux15.rs`'s kind over
//! a read of word 121 with a key word waiting under the keyboard's enable, a
//! read of word 122 with the mouse moved under its enable, and a write of
//! block-disk's command, word 200, whose `<11>` with the disk idle raises
//! word 100 `<3>`; interrupts enabled, and each access followed by two
//! checks of condition 5 that call handlers counting in M 26 and M 27
//! (muir's `two_checks`).
//!
//!   slot-<w>-<hint>
//!             the read in the delay slot of a conditional jump decided in
//!             EX, taken, hinted right or wrong; its target the two checks.
//!             With two bubbles and a wrong hint the target reaches EX after
//!             the read's grant (muir's
//!             `a_register_read_in_a_mispredicted_slot_holds_the_level_for_the_target`)
//!   oa-<w>    the first check selects OA-REG-HIGH written two words
//!             before, so CS holds it a clock and it reaches EX after the
//!             grant (muir's
//!             `a_register_read_holds_the_level_for_the_word_after_its_start_held_in_cs`)
//!   gap0-<w>, gap1-<w>
//!             the checks right after the read's start, and a word later
//!             (muir's `a_register_read_s_side_effect_is_seen_from_the_clock_after_its_grant`)
//!   write     the write of 200, the checks right after its start
//!   oamove-<d>
//!             `oa-122` with a second move handed over `d` clocks after the
//!             read's start commits, across the clocks between its grant and
//!             its release; 123 and 122 read after the checks.  A move that
//!             comes after the grant stays seen: the clear is made at the
//!             grant, not deferred to the release (the ruling's rejected
//!             alternative)
//!   oafull-<d>
//!             `oa-121` with the FIFO full, sixty-four key words waiting,
//!             and one more handed over `d` clocks after the read's start
//!             commits; 120 and 121 read after the checks.  A word that
//!             comes after the grant finds the room the pop made there
//!   halt-<access>-<clock>
//!             each of `gap0-121`, `gap0-122` and `write` halted at every
//!             clock of its run and resumed (muir's
//!             `a_halt_between_a_register_access_s_start_and_the_next_instruction_sends_it_out`)
//!   haltoa-<w>-<clock>, haltslot-<w>-<hint>-<clock>
//!             `oa-<w>` and `slot-<w>-<hint>` halted at every clock: with
//!             two bubbles and a wrong hint the halt can begin after the
//!             read's grant with its next word not yet in EX
//!
//! **WHAT EACH RUN MUST END WITH** is the two calls, M 26 and M 27, and the
//! generator refuses a trace whose runs end otherwise: (1, 0) for a read
//! whose next word is the first check, however late that word reaches EX;
//! (0, 0) a word later; (0, 1) for the write.  Every run but one point of
//! each halted access ends as `micro` does unhalted.  **AT EXACTLY ONE HALT
//! POINT OF EACH ACCESS**, the one between its start and the next
//! instruction, the halt sends the access out (A15b.13): the read's change
//! counts and the write is taken, so the check right after the start sees
//! the level as the access leaves it, (0, 0) for the reads and (1, 1) for
//! the write.  The generator counts those points, by the microcycles
//! completed at the halt as muir's test does, and refuses a trace with none
//! or more than one; a next word held in CS gives the one point more than
//! one clock.
//!
//! The key word and the move are handed to muir's `QuuxInput` two clocks
//! after the first word commits (`quux15_input.rs`'s injections), long
//! before the read.

use muir::isa::asm::{ALU, HINT, JUMP, MD, N, OA_HIGH_SELECT, P, POPJ, SETA, START_READ, START_WRITE};
use muir::isa::asm::{ADD, a_src, filler, m_dest, m_src, target};
use muir::machine::Word;

use super::Case;
use super::quux15_console::Act;
use super::quux15_input::{At, Inject, What};
use super::quux15_preset::Preset;

/// The register page's virtual address.
const REGISTER_PAGE: Word = 0o35777777400;
/// A memory's 0 and 1, and M memory's 0 (`quux15_preset.rs`'s).
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;
/// The handlers the two checks call, counting in M 26 and M 27.
const SUBS: [u64; 2] = [0o700, 0o720];
/// The slot's jump's target.
const SLOT_TARGET: u64 = 0o200;

/// A functional destination, M 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}

/// A JUMP on condition `code`.
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// The register page's word `k`.
const fn reg(k: u64) -> Word {
    REGISTER_PAGE | k
}

/// Which access.
#[derive(Clone, Copy, PartialEq)]
enum Access {
    /// A read of 121, a key word waiting under 120's enable.
    Key,
    /// A read of 122, the mouse moved under 123's enable.
    Mouse,
    /// The write of block-disk's command.
    Write,
}

impl Access {
    fn tag(self) -> &'static str {
        match self {
            Access::Key => "121",
            Access::Mouse => "122",
            Access::Write => "write",
        }
    }
    fn word(self) -> u64 {
        match self {
            Access::Key => 0o121,
            Access::Mouse => 0o122,
            Access::Write => 0o200,
        }
    }
}

/// The run's start: -RESET's sweep taken as done, interrupts enabled, and
/// for a read the device's interrupt enabled and its level raised by a key
/// word or a move handed over two clocks after the first word commits.
fn prelude(a: Access) -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    let v = p.k(1 << 35);
    p.op(ALU | SETA | a_src(v) | fd(0o2));
    let what = match a {
        Access::Key => {
            p.write(1 << 8, reg(0o120));
            Some(What::Key(0o40101))
        }
        Access::Mouse => {
            p.write(1 << 8, reg(0o123));
            Some(What::Mouse { dx: 1, dy: 0, buttons: 0 })
        }
        Access::Write => None,
    };
    if let Some(what) = what {
        p.input = vec![Inject { at: At { pc: 0, nth: 1, plus: 2 }, what }];
    }
    p
}

/// The access's start: a read's, or the write's of `<11>`.
fn start(p: &mut Preset, a: Access) {
    let at = p.k(reg(a.word()));
    if a == Access::Write {
        let w = p.k(1 << 11);
        p.op(ALU | SETA | a_src(w) | MD);
        p.op(ALU | SETA | a_src(at) | START_WRITE);
    } else {
        p.op(ALU | SETA | a_src(at) | START_READ);
    }
}

/// The two checks of condition 5, N set.
fn two_checks(p: &mut Preset) {
    p.op(jcond(5) | P | N | target(SUBS[0]));
    p.op(jcond(5) | P | N | target(SUBS[1]));
}

/// The handlers, after the stop: each counts in its M word and returns.
fn handlers(p: &mut Preset) {
    for (k, slot) in [(0, 0o26), (1, 0o27)] {
        p.fill_to(SUBS[k]);
        p.op(ALU | ADD | a_src(ONE) | m_src(slot) | m_dest(slot));
        p.op(filler().raw() | POPJ);
        p.fill(1);
    }
}

/// The access, `gap` words, the two checks.
fn then_checks(a: Access, gap: usize) -> Preset {
    let mut p = prelude(a);
    p.fill(4);
    start(&mut p, a);
    p.fill(gap);
    two_checks(&mut p);
    p.fill(2);
    p.stop();
    handlers(&mut p);
    p
}

/// The read in the delay slot of a taken conditional jump decided in EX,
/// hinted by `hint`; its target the two checks.
fn in_a_slot(a: Access, hint: u64) -> Preset {
    let mut p = prelude(a);
    // The register page's word 120 read first, as muir's test does.
    p.read(reg(0o120), 0o25);
    p.fill(3);
    let at = p.k(reg(a.word()));
    p.op(jcond(3) | m_src(M_ZERO) | a_src(ZERO) | target(SLOT_TARGET) | hint);
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.stop();
    p.fill_to(SLOT_TARGET);
    two_checks(&mut p);
    p.fill(2);
    p.stop();
    handlers(&mut p);
    p
}

/// The read, the first check selecting OA-REG-HIGH written the word before
/// the start, so that CS holds it a clock.
fn oa_held(a: Access) -> Preset {
    let mut p = prelude(a);
    p.fill(4);
    // The select check of `micro` would stop the word right after a start
    // that selects an OA register; muir's test turns it off too.
    p.select_check = false;
    let (at, z) = (p.k(reg(a.word())), p.k(0));
    p.op(ALU | SETA | a_src(z) | fd(0o17));
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.op(jcond(5) | P | N | target(SUBS[0]) | OA_HIGH_SELECT);
    p.op(jcond(5) | P | N | target(SUBS[1]));
    p.fill(2);
    p.stop();
    handlers(&mut p);
    p
}

/// `oa-<w>` with an injection `d` clocks after the read's start commits,
/// and two registers read after the checks into M 30 and M 31.  With
/// `full`, the FIFO filled first: sixty-four key words, a clock apart.
fn oa_window(a: Access, d: u64, full: bool, what: What, after: [u64; 2]) -> Preset {
    let mut p = prelude(a);
    if full {
        p.input = (1..=64)
            .map(|k| Inject { at: At { pc: 0, nth: 1, plus: 1 + k }, what: What::Key(0o40000 | k as u32) })
            .collect();
        p.fill(80);
    } else {
        p.fill(4);
    }
    p.select_check = false;
    let (at, z) = (p.k(reg(a.word())), p.k(0));
    p.op(ALU | SETA | a_src(z) | fd(0o17));
    let start_pc = p.at();
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.op(jcond(5) | P | N | target(SUBS[0]) | OA_HIGH_SELECT);
    p.op(jcond(5) | P | N | target(SUBS[1]));
    p.fill(2);
    p.read(reg(after[0]), 0o30).read(reg(after[1]), 0o31);
    p.stop();
    handlers(&mut p);
    p.input.push(Inject { at: At { pc: start_pc as u16, nth: 1, plus: d }, what });
    p
}

/// The read, a word that tests no interrupt and selects OA-REG-HIGH
/// written the word before the start, so that CS holds it and it leaves EX
/// after the grant; then the two checks, right behind it.
fn oa_gap(a: Access) -> Preset {
    let mut p = prelude(a);
    p.fill(4);
    p.select_check = false;
    let (at, z) = (p.k(reg(a.word())), p.k(0));
    p.op(ALU | SETA | a_src(z) | fd(0o17));
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.op(ALU | SETA | a_src(ZERO) | m_dest(0o25) | OA_HIGH_SELECT);
    two_checks(&mut p);
    p.fill(2);
    p.stop();
    handlers(&mut p);
    p
}

/// The read in a taken jump's delay slot, hinted by `hint`; its target a
/// word that tests no interrupt, then the two checks.
fn slot_gap(a: Access, hint: u64) -> Preset {
    let mut p = prelude(a);
    p.read(reg(0o120), 0o25);
    p.fill(3);
    let at = p.k(reg(a.word()));
    p.op(jcond(3) | m_src(M_ZERO) | a_src(ZERO) | target(SLOT_TARGET) | hint);
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.stop();
    p.fill_to(SLOT_TARGET);
    p.fill(1);
    two_checks(&mut p);
    p.fill(2);
    p.stop();
    handlers(&mut p);
    p
}

/// What a run must end with in M 26 and M 27.
fn must(p: &Preset, name: &str, calls: (Word, Word)) -> Case {
    let mut c = p.case(name);
    c.calls = Some(super::Calls { family: None, unhalted: calls, sent: None });
    c
}

/// A halt at clock `at`, resumed two clocks after the drain
/// (`quux15_console.rs`'s `halt_at`).
fn halt_at(at: u64) -> Vec<Act> {
    assert!(at >= 2, "a console's write lands from the second clock on");
    vec![Act::Wait(at - 1), Act::Spy(muir::spy::CLK, 0), Act::UntilHalted, Act::Wait(2), Act::Spy(muir::spy::CLK, 1)]
}

/// **The runs.**
pub fn regread(period: u64) -> Vec<Case> {
    let mut v = Vec::new();
    for a in [Access::Key, Access::Mouse] {
        for (hinted, hint) in [("right", HINT), ("wrong", 0)] {
            v.push(must(&in_a_slot(a, hint), &format!("slot-{}-{hinted}", a.tag()), (1, 0)));
        }
        v.push(must(&oa_held(a), &format!("oa-{}", a.tag()), (1, 0)));
        // The next word late and testing nothing: the check right behind it
        // sees the level lowered.
        v.push(must(&oa_gap(a), &format!("oagap-{}", a.tag()), (0, 0)));
        for (hinted, hint) in [("right", HINT), ("wrong", 0)] {
            v.push(must(&slot_gap(a, hint), &format!("slotgap-{}-{hinted}", a.tag()), (0, 0)));
        }
        v.push(must(&then_checks(a, 0), &format!("gap0-{}", a.tag()), (1, 0)));
        v.push(must(&then_checks(a, 1), &format!("gap1-{}", a.tag()), (0, 0)));
    }
    v.push(must(&then_checks(Access::Write, 0), "write", (0, 1)));
    // The window between a read's grant and its release: muir's ends, clock
    // for clock, not `micro`'s, which takes an injection at another point of
    // a microcycle.
    for d in 1..=6 {
        let mv = What::Mouse { dx: -1, dy: 0, buttons: 0 };
        let mut c = oa_window(Access::Mouse, d, false, mv, [0o123, 0o122]).case(&format!("oamove-{d}"));
        c.micro_check = false;
        v.push(c);
        let key = What::Key(0o40777);
        let mut c = oa_window(Access::Key, d, true, key, [0o120, 0o121]).case(&format!("oafull-{d}"));
        c.micro_check = false;
        v.push(c);
    }
    // Each access halted at every clock; and the reads with the next word
    // held in CS, and in a mispredicted slot, where with two bubbles the
    // read is granted before the halt begins and its next word not yet in
    // EX, so that the halt releases a read it did not see granted.
    let halted = [
        (format!("halt-{}", Access::Key.tag()), then_checks(Access::Key, 0), (1, 0), (0, 0)),
        (format!("halt-{}", Access::Mouse.tag()), then_checks(Access::Mouse, 0), (1, 0), (0, 0)),
        (format!("halt-{}", Access::Write.tag()), then_checks(Access::Write, 0), (0, 1), (1, 1)),
        (format!("haltoa-{}", Access::Key.tag()), oa_held(Access::Key), (1, 0), (0, 0)),
        (format!("haltoa-{}", Access::Mouse.tag()), oa_held(Access::Mouse), (1, 0), (0, 0)),
        (format!("haltslot-{}-wrong", Access::Key.tag()), in_a_slot(Access::Key, 0), (1, 0), (0, 0)),
        (format!("haltslot-{}-wrong", Access::Mouse.tag()), in_a_slot(Access::Mouse, 0), (1, 0), (0, 0)),
        (format!("haltslot-{}-right", Access::Key.tag()), in_a_slot(Access::Key, HINT), (1, 0), (0, 0)),
    ];
    for (family, p, unhalted, sent) in halted {
        let base = p.case("x");
        let end = super::quux15_input::park_clock(&base, period);
        for at in 2..=end {
            let mut c = p.case(&format!("{family}-{at}"));
            c.script = halt_at(at);
            c.calls = Some(super::Calls { family: Some(family.clone()), unhalted, sent: Some(sent) });
            v.push(c);
        }
    }
    v
}
