// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's keyboard and mouse** (contract Q3; G3 revision 15,
//! A15b.3; MP2b rulings Q4 and rulings 2 Q1): runs of `golden/src/quux15.rs`'s
//! kind with key words and mouse moves handed to muir's `QuuxInput` at
//! clocks, as a host hands them over, between two of the pipeline's clocks.
//!
//!   poll      a key word at every clock of a polling loop on word 120, then
//!             read from 121
//!   poll100   the same on word 100's `<4>`, the keyboard's interrupt
//!             enabled with interrupts off
//!   intr      a key word at every clock of an interrupt-driven loop: the
//!             keyboard's interrupt enabled, condition 5 calling a handler
//!             that reads 121
//!   overflow  sixty-six words into the FIFO's sixty-four, the overflow read,
//!             a word taken and one more put in, the overflow read again and
//!             cleared by a write
//!   mouse     a move, a step of each count and a button, at every clock
//!             from before a read of word 122 to after the read of 123 that
//!             follows it
//!   mouseirq  a move under the mouse's interrupt enable, condition 5
//!             calling a handler that reads 122
//!   boot      the keyboard's boot word at every clock of a loop: the machine
//!             halts and boots, and its program, run again from the PROM,
//!             reads the word from the FIFO
//!   ckpt      a checkpoint of the halted machine with key words waiting,
//!             the FIFO's head moved, the counts and the buttons changed and
//!             both enables set, at clocks spread over the run
//!
//! **AN INJECTION IS PLACED BY THE PROGRAM, NOT BY A CLOCK**: `plus` clocks
//! after the `nth` commit of a control store address, so that a sweep over
//! a loop's clocks is the same sweep at every period and with one bubble or
//! two.  It is made before the clock it is for, as muir's terminal hands a
//! word to `QuuxInput` between two steps, and the trace says so for the
//! testbench, which puts it on the core's cable in the clock before:
//!
//!   # key <clock> <word>                   a key word, `QuuxInput::press`
//!   # mouse <clock> <x> <y> <buttons>      the counts and buttons after
//!                                          `mouse_move` and `mouse_buttons`
//!
//! **A MOVE IS A STEP OF EACH COUNT AT MOST**, which is what the board's face
//! makes in a clock: `cadr_input_cables.sv` turns a host's deltas into phases
//! a step at a time, and the core counts them as they come.
//!
//! **`micro` IS GIVEN THE SAME INJECTIONS BY MICROCYCLE**, before the
//! microcycle after the commits the pipeline had made when it took each, so
//! that a run's end can be held to `micro`'s.  The two do not take a word at
//! the same point of a microcycle, so a run held to `micro` is one whose end
//! does not depend on that point: a poll that waits, a handler that runs
//! once.  The mouse's sweep across two reads and the boot are not held to
//! `micro`; their trace is muir's pipeline's alone, as the console's runs
//! are.
//!
//! **THE BOOT WORD HALTS THE MACHINE, THEN BOOTS IT**, as the core builds it:
//! RUN cleared in the clock after the word comes in, and `-BOOT` in the clock
//! after the halt, as a console's writes would make them (`quux15_core.sv`'s
//! `kbd_boot`).  muir's own run loop boots at once between two microcycles
//! (`Engine::keyboard_boot`), at a point its host's poll chooses; here muir's
//! pipeline is driven through its console's RUN and `-BOOT` instead, at the
//! clocks the core makes them, and the trace carries no console line for
//! the testbench, since the core makes them itself.

use std::collections::HashMap;

use muir::engine::Engine;
use muir::isa::asm::{
    ADD, ALU, ALWAYS, AND, JUMP, MD, N, P, POPJ, SETA, SETM, SRC_MD, START_READ, START_WRITE, SUB,
    a_dest, a_src, filler, m_dest, m_src, target,
};
use muir::machine::Word;
use muir::pipeline::Pipeline;
use muir::quux_input::KeyboardMouse;
use muir::spy;

use super::Case;
use super::quux15_console::Act;
use super::quux15_preset::Preset;

/// The register page's virtual address.
const REGISTER_PAGE: Word = 0o35777777400;
/// A memory's 0 and 1, and M memory's 0 (`quux15_preset.rs`'s).
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;
/// The A word a poll tests, and the handler a check calls.
const TESTED: u64 = 0o1710;
const HANDLER: u64 = 0o700;

/// Where an injection lands: `plus` clocks after the `nth` commit (from 1)
/// of control store address `pc`.
#[derive(Clone, Copy, Debug)]
pub struct At {
    pub pc: u16,
    pub nth: u32,
    pub plus: u64,
}

/// What is injected: a key word, or a move of a step of each count at most
/// and the buttons as they then stand.
#[derive(Clone, Copy, Debug)]
pub enum What {
    Key(u32),
    Mouse { dx: i32, dy: i32, buttons: u8 },
}

#[derive(Clone, Copy, Debug)]
pub struct Inject {
    pub at: At,
    pub what: What,
}

/// The keyboard's boot as the core makes it: RUN cleared, the halt waited
/// for, `-BOOT` the clock after.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Boot {
    Idle,
    Halting,
    Booting(u64),
}

/// **A run's injections as it goes**: each placed when its anchor commits,
/// made before its clock; the trace's lines; what `micro` is given.
pub struct Feed {
    list: Vec<(Inject, Option<u64>, bool)>,
    seen: HashMap<u16, u32>,
    commits: u64,
    boot: Boot,
    pub lines: Vec<String>,
    pub micro: Vec<(u64, What)>,
}

impl Feed {
    pub fn new(list: &[Inject]) -> Feed {
        Feed {
            list: list.iter().map(|&i| (i, None, false)).collect(),
            seen: HashMap::new(),
            commits: 0,
            boot: Boot::Idle,
            lines: Vec::new(),
            micro: Vec::new(),
        }
    }

    /// Before the clock after `e`'s last: what is due in it, handed over.
    pub fn before(&mut self, e: &mut Pipeline) {
        let clock = e.clock() + 1;
        for (inj, due, made) in self.list.iter_mut() {
            if *made || *due != Some(clock) {
                continue;
            }
            *made = true;
            let q = &mut e.machine_mut().quux_input;
            match inj.what {
                What::Key(w) => {
                    q.press(w);
                    self.lines.push(format!("# key {clock:x} {w:x}"));
                }
                What::Mouse { dx, dy, buttons } => {
                    assert!(dx.abs() <= 1 && dy.abs() <= 1, "a move is a step of each count at most");
                    q.mouse_move(dx, dy);
                    q.mouse_buttons(buttons);
                    let mut w = muir::checkpoint::Writer::new();
                    q.save(&mut w);
                    let b = w.finish();
                    // `QuuxInput::save`: the FIFO's count and words, the
                    // overflow and the enable, then X, Y and the buttons.
                    let at = 4 + 4 * u32::from_le_bytes(b[0..4].try_into().expect("the count")) as usize + 2;
                    let x = u16::from_le_bytes([b[at], b[at + 1]]);
                    let y = u16::from_le_bytes([b[at + 2], b[at + 3]]);
                    let held = b[at + 4];
                    self.lines.push(format!("# mouse {clock:x} {x:x} {y:x} {held:x}"));
                }
            }
            self.micro.push((self.commits, inj.what));
        }
    }

    /// After a clock of `e`'s, whose row committed `commit`: the injections
    /// it anchors placed, and the keyboard's boot carried on.
    pub fn after(&mut self, e: &mut Pipeline, commit: Option<Option<u16>>) -> Result<(), String> {
        let clock = e.clock();
        if let Some(c) = commit {
            self.commits += 1;
            if let Some(pc) = c {
                let n = self.seen.entry(pc).or_insert(0);
                *n += 1;
                for (inj, due, _) in self.list.iter_mut() {
                    if due.is_none() && inj.at.pc == pc && inj.at.nth == *n {
                        if inj.at.plus == 0 || clock + inj.at.plus < 2 {
                            return Err(format!("an injection at {:?} lands before the clock after its anchor", inj.at));
                        }
                        *due = Some(clock + inj.at.plus);
                    }
                }
            }
        }
        let booted = e.machine_mut().quux_input.take_boot();
        match self.boot {
            Boot::Idle if booted => {
                e.spy_write(spy::CLK, 0);
                self.boot = Boot::Halting;
                if e.is_halted() {
                    self.boot = Boot::Booting(clock + 1);
                }
            }
            Boot::Idle => {}
            _ if booted => return Err(format!("a second boot word at clock {clock}, the first not yet taken")),
            Boot::Halting => {
                if e.is_halted() {
                    self.boot = Boot::Booting(clock + 1);
                }
            }
            Boot::Booting(at) => {
                if clock == at {
                    e.spy_write(spy::MODE, spy::MODE_BOOT);
                    self.boot = Boot::Idle;
                }
            }
        }
        Ok(())
    }

    /// Whether every injection was made, and the boot finished.
    pub fn finished(&self) -> Result<(), String> {
        if let Some((inj, _, _)) = self.list.iter().find(|(_, _, made)| !made) {
            return Err(format!("the injection at {:?} was never made", inj.at));
        }
        if self.boot != Boot::Idle {
            return Err("the keyboard's boot never ended".to_string());
        }
        Ok(())
    }
}

/// `micro`'s injections before microcycle `n` (from 0): those the pipeline
/// took after `n` commits.
pub fn micro_feed(m: &mut muir::machine::Machine, feed: &[(u64, What)], n: u64) {
    for &(at, what) in feed {
        if at != n {
            continue;
        }
        let q = &mut m.quux_input;
        match what {
            What::Key(w) => q.press(w),
            What::Mouse { dx, dy, buttons } => {
                q.mouse_move(dx, dy);
                q.mouse_buttons(buttons);
            }
        }
    }
}

// ------------------------------------------------------------- programs

/// A functional destination, M 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}

/// A JUMP on condition `code`.
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// Counts in M `m`.
fn mark(m: u64) -> u64 {
    ALU | ADD | a_src(ONE) | m_src(m) | m_dest(m)
}

/// The register page's word `k`.
const fn reg(k: u64) -> Word {
    REGISTER_PAGE | k
}

/// A run: -RESET's sweep of the TLB taken as done.
fn run() -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p
}

impl Preset {
    /// M `slot` <- register-page word `k`: the start, a word, `MD`.
    fn page_read(&mut self, k: u64, slot: u64) -> &mut Self {
        let a = self.k(reg(k));
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.fill(1);
        self.op(ALU | SETM | SRC_MD | m_dest(slot))
    }

    /// Register-page word `k` <- `v`, and two words after.
    fn page_write(&mut self, v: Word, k: u64) -> &mut Self {
        let (wa, aa) = (self.k(v), self.k(reg(k)));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.fill(2)
    }

    /// Waits until register-page word `k` has a bit of `bits` set: its
    /// first word's address.
    fn page_poll(&mut self, k: u64, bits: Word) -> u64 {
        let (at, b) = (self.k(reg(k)), self.k(bits));
        let top = self.at();
        self.op(ALU | SETA | a_src(at) | START_READ);
        self.fill(1);
        self.op(ALU | AND | SRC_MD | a_src(b) | a_dest(TESTED));
        self.op(jcond(3) | a_src(TESTED) | m_src(M_ZERO) | target(top) | N);
        self.fill(1);
        top
    }

    /// Counts M `m` down from `n` to 0: its loop's first word's address.
    fn count_down(&mut self, m: u64, n: u64) -> u64 {
        let k = self.k(n);
        self.op(ALU | SETA | a_src(k) | m_dest(m));
        let top = self.at();
        self.op(ALU | SUB | a_src(ONE) | m_src(m) | m_dest(m));
        self.op(jcond(3) | 1 << 6 | a_src(ZERO) | m_src(m) | target(top) | N);
        self.fill(1);
        top
    }
}

/// Interrupts enabled: INTERRUPT-CONTROL `<27>`, destination 2.
fn enable_interrupts(p: &mut Preset) {
    let v = p.k(1 << 35);
    p.op(ALU | SETA | a_src(v) | fd(0o2));
}

/// A key word with no boot in it: `<13:6>` not `0o360`.
fn key(k: u32) -> u32 {
    0o40000 | k
}

/// The keyboard's boot word: `<13:6>` 0o360, and the low six bits of a cold
/// boot, 0o46.
const BOOT_WORD: u32 = 0o360 << 6 | 0o46;

fn with(mut p: Preset, input: Vec<Inject>) -> Preset {
    p.input = input;
    p
}

/// **A key word at every clock of a polling loop**: the loop on 120's
/// `<0>`, then 121 read and 120 again.
fn poll(d: u64) -> Preset {
    let mut p = run();
    let top = p.page_poll(0o120, 1);
    p.page_read(0o121, 0o26).page_read(0o120, 0o27);
    p.stop();
    with(p, vec![Inject { at: At { pc: top as u16, nth: 1, plus: d }, what: What::Key(key(0o1234)) }])
}

/// **A key word at every clock of a polling loop on word 100**: the
/// keyboard's interrupt enabled with interrupts off, the loop on word 100's
/// `<4>`, which is read as the grant finds it, then 121 read and 100 again.
fn poll100(d: u64) -> Preset {
    let mut p = run();
    p.page_write(1 << 8, 0o120);
    let top = p.page_poll(0o100, 1 << 4);
    p.page_read(0o121, 0o26).page_read(0o100, 0o27).page_write(0, 0o120);
    p.stop();
    with(p, vec![Inject { at: At { pc: top as u16, nth: 1, plus: d }, what: What::Key(key(0o2345)) }])
}

/// **A key word at every clock of an interrupt-driven loop**: the keyboard's
/// interrupt enabled, condition 5 calling the handler, which reads 121 and
/// counts, and the loop until it has.
fn intr(d: u64) -> Preset {
    let mut p = run();
    enable_interrupts(&mut p);
    p.page_write(1 << 8, 0o120);
    let top = p.at();
    p.op(jcond(5) | P | target(HANDLER) | N);
    p.fill(1);
    p.op(jcond(3) | a_src(ZERO) | m_src(0o26) | target(top) | N);
    p.fill(1);
    p.page_write(0, 0o120).page_read(0o120, 0o27);
    p.stop();
    p.fill_to(HANDLER);
    p.page_read(0o121, 0o30);
    p.op(mark(0o26));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    with(p, vec![Inject { at: At { pc: top as u16, nth: 1, plus: d }, what: What::Key(key(0o4321)) }])
}

/// **The FIFO overflowed**: sixty-six words, a clock apart, into a FIFO of
/// sixty-four while the program counts; 120 read, 121 read, a word more put
/// in, 120 read again (the overflow sticks), cleared by a write, read.
fn overflow() -> Preset {
    let mut p = run();
    let first = p.count_down(0o27, 70);
    p.page_read(0o120, 0o26).page_read(0o121, 0o30);
    let second = p.count_down(0o27, 10);
    p.page_read(0o120, 0o31).page_write(0, 0o120).page_read(0o120, 0o32).page_read(0o121, 0o33);
    p.stop();
    let mut v: Vec<Inject> = (1..=66)
        .map(|k| Inject { at: At { pc: first as u16, nth: 1, plus: k }, what: What::Key(key(k as u32)) })
        .collect();
    v.push(Inject { at: At { pc: second as u16, nth: 1, plus: 2 }, what: What::Key(key(0o777)) });
    with(p, v)
}

/// **A move between 122's read and 123's**: 122, 123 and 122 again read,
/// a move of a step right and up with the left button at clock `d` after
/// the first read's start.
fn mouse(d: u64) -> Preset {
    let mut p = run();
    // A move first, so that the counts are not at zero.
    p.page_read(0o122, 0o25);
    let start = p.at();
    p.page_read(0o122, 0o26).page_read(0o123, 0o27).page_read(0o122, 0o30).page_read(0o123, 0o31);
    p.stop();
    with(
        p,
        vec![
            Inject { at: At { pc: 0, nth: 1, plus: 2 }, what: What::Mouse { dx: -1, dy: 1, buttons: 0 } },
            Inject { at: At { pc: start as u16, nth: 1, plus: d }, what: What::Mouse { dx: 1, dy: -1, buttons: 1 } },
        ],
    )
}

/// **A move under the mouse's interrupt enable**: condition 5 calls the
/// handler, which reads 122 and counts; the buttons changed alone, then a
/// move.
fn mouseirq(d: u64, buttons_only: bool) -> Preset {
    let mut p = run();
    enable_interrupts(&mut p);
    p.page_write(1 << 8, 0o123);
    let top = p.at();
    p.op(jcond(5) | P | target(HANDLER) | N);
    p.fill(1);
    p.op(jcond(3) | a_src(ZERO) | m_src(0o26) | target(top) | N);
    p.fill(1);
    p.page_write(0, 0o123).page_read(0o123, 0o27);
    p.stop();
    p.fill_to(HANDLER);
    p.page_read(0o122, 0o30);
    p.op(mark(0o26));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    let what = if buttons_only {
        What::Mouse { dx: 0, dy: 0, buttons: 4 }
    } else {
        What::Mouse { dx: 1, dy: 1, buttons: 0 }
    };
    with(p, vec![Inject { at: At { pc: top as u16, nth: 1, plus: d }, what }])
}

/// **The keyboard's boot word at every clock of a loop**: M 27 counts the
/// passes; the first loops reading word 100, and the boot word, at clock
/// `d` of it, halts the machine and boots it; the second, from the PROM's
/// jump to 0, finds the word in the FIFO and reads it.
fn boot(d: u64) -> Preset {
    let mut p = run();
    p.op(mark(0o27));
    let first_at = 0o40;
    p.op(jcond(3) | a_src(ONE) | m_src(0o27) | target(first_at) | N);
    p.fill(1);
    p.page_poll(0o120, 1);
    p.page_read(0o121, 0o26);
    p.stop();
    p.fill_to(first_at);
    let top = p.at();
    p.page_read(0o100, 0o30);
    p.op(JUMP | target(top) | ALWAYS | N);
    p.fill(1);
    with(p, vec![Inject { at: At { pc: top as u16, nth: 2, plus: d }, what: What::Key(BOOT_WORD) }])
}

/// **The machine with input to checkpoint**: three key words, one read,
/// both enables set with interrupts off, moves and a button, then a count.
fn ckpt_program() -> Preset {
    let mut p = run();
    let first = p.count_down(0o27, 12);
    p.page_read(0o121, 0o26).page_write(1 << 8, 0o120).page_write(1 << 8, 0o123);
    let second = p.count_down(0o27, 12);
    p.count_down(0o27, 20);
    p.stop();
    let mut v: Vec<Inject> = (1..=3)
        .map(|k| Inject { at: At { pc: first as u16, nth: 1, plus: 2 * k }, what: What::Key(key(0o100 * k as u32)) })
        .collect();
    for (k, (dx, dy, b)) in [(1, 0, 0), (1, 1, 0), (0, -1, 2), (-1, -1, 2)].into_iter().enumerate() {
        v.push(Inject {
            at: At { pc: second as u16, nth: 1, plus: 3 + 2 * k as u64 },
            what: What::Mouse { dx, dy, buttons: b },
        });
    }
    with(p, v)
}

/// The clock `case` parks at on muir's pipeline, its injections made.
pub(crate) fn park_clock(case: &Case, period: u64) -> u64 {
    let mut e = Pipeline::new(super::machine(case));
    e.configure(period, case.timing.unwrap_or(super::TIMING), super::CACHE_WORDS);
    e.boot();
    if case.skip_sweep {
        e.skip_sweep();
    }
    let mut t = super::trace15::Trace15::start(&mut e);
    let _ = t.row(&e);
    let mut feed = Feed::new(&case.input);
    while u64::from(e.machine().opc) != case.park && e.clock() < 100_000 {
        feed.before(&mut e);
        e.tick().expect("the run reaches its park");
        let row = t.row(&e);
        feed.after(&mut e, row.commit).expect("the injections are made");
    }
    e.clock()
}

/// **The runs.**
pub fn input(period: u64) -> Vec<Case> {
    let mut v = Vec::new();
    for d in 1..=24 {
        v.push(poll(d).case(&format!("poll-{d}")));
    }
    for d in 1..=16 {
        v.push(poll100(d).case(&format!("poll100-{d}")));
    }
    for d in 1..=24 {
        v.push(intr(d).case(&format!("intr-{d}")));
    }
    v.push(overflow().case("overflow"));
    for d in 1..=16 {
        let mut c = mouse(d).case(&format!("mouse-{d}"));
        c.micro_check = false;
        v.push(c);
    }
    for buttons_only in [false, true] {
        for d in [1, 3, 5, 7] {
            v.push(mouseirq(d, buttons_only).case(&format!("mouseirq-{}{d}", if buttons_only { "b" } else { "m" })));
        }
    }
    for d in 1..=10 {
        let mut c = boot(d).case(&format!("boot-{d}"));
        c.micro_check = false;
        v.push(c);
    }
    let base = ckpt_program().case("ckpt");
    let end = park_clock(&base, period);
    for k in 1..=6 {
        let at = (end * k / 7).max(2);
        let mut c = base.clone();
        c.name = format!("ckpt-{at}");
        c.script = vec![Act::Wait(at - 1), Act::Spy(spy::CLK, 0), Act::UntilHalted, Act::CheckpointEnd];
        c.micro_check = false;
        v.push(c);
    }
    v
}
