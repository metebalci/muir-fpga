// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's register-page devices and its time** (contract G3
//! revision 15, A15b.1, A15b.12; contracts Q9, Q11, Q13), as runs of
//! `golden/src/quux15.rs`'s kind: programs from control store 0, written
//! as muir's `tests/revision_15_rtl.rs` writes its own.
//!
//!   timers    the three interval timers: periodic, its flag cleared at
//!             each rise and once late, after periods missed, on the start's
//!             grid; one-shot, a clear that starts nothing, off and on again;
//!             a period written while on; word 100 under each enable; the
//!             microsecond clock (source 15) and the real-time clock (word
//!             103); RESET-DEVICES (word 104).  Traced at A15b.12's periods
//!   interrupt conditions 5 and 6 with a timer's flag up under its enable,
//!             the flag rising at every clock across a run of checks, plain
//!             and with the first check held on `MD`, its delay slot run or
//!             not; a register write's interrupt seen by the check after the
//!             next, and a write that lowers it; a register read right after
//!             a register write
//!   blockdisk block-disk's registers with no pack fitted, as every trace
//!             here has it: the command, the command list pointer, the disk
//!             address, START, the status and its done interrupt
//!   filedev   the file device's registers, its rings set up, enabled,
//!             refused and faulted; muir's LOG of "hello" behind a slow port,
//!             CMD_PROD waiting for every earlier write and the response read
//!             over a line the cache held, which the completion's sweep
//!             clears; two commands in a ring of two, one unknown, their
//!             responses consumed, word 100 `<7>` under the enable; and the
//!             host's part, muir's `FileDevice`, recorded for the testbench
//!   window    the frame buffer's window through the cache: a word written
//!             and read back, its tag dropped in the buffer and kept in a
//!             line the cache holds, a line evicted and filled again, odd and
//!             even words, an offset past the buffer (nothing there, the
//!             bus error), and the video controller's mode, word 210
//!
//! **THE END IS EACH ENGINE'S OWN AND THE SAME**: `micro` runs a microcycle
//! where the pipeline runs a clock or more, so a timer rises at another
//! microcycle on each.  Each program leaves nothing of its time behind: a
//! word read from a clock is put in M and cleared before the stop, a wait is
//! a loop on a flag, and an interrupt is taken once whichever check takes
//! it.  The words read and the clocks each is read at are the trace's,
//! which the testbench holds the core to.

use muir::isa::asm::{
    ADD, ALU, AND, JUMP, N, P, POPJ, SETA, SETM, SRC_MD, START_READ, a_dest, a_src, filler, m_dest,
    m_src, src, target,
};
use muir::machine::Word;

use super::quux15_preset::Preset;

/// The register page's virtual address.
const REGISTER_PAGE: Word = 0o35777777400;
/// The physical memory window.
const PHYS: Word = 0o36000000000;

const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;

/// The A word a poll tests.
const TESTED: u64 = 0o1710;
/// The handler a check calls.
const HANDLER: u64 = 0o700;

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

/// A run: -RESET's sweep of the TLB taken as done.
fn run() -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p
}

/// The register page's word `k`.
const fn reg(k: u64) -> Word {
    REGISTER_PAGE | k
}

impl Preset {
    /// Waits until register-page word `k` has a bit of `bits` set: a read,
    /// a word, the test, and back.
    fn poll(&mut self, k: u64, bits: Word) -> &mut Self {
        let (at, b) = (self.k(reg(k)), self.k(bits));
        let top = self.at();
        self.op(ALU | SETA | a_src(at) | START_READ);
        self.fill(1);
        self.op(ALU | AND | SRC_MD | a_src(b) | a_dest(TESTED));
        self.op(jcond(3) | a_src(TESTED) | m_src(M_ZERO) | target(top) | N);
        self.fill(1)
    }

    /// Counts M `m` down from `n` to 0: a delay whose end is the same on
    /// every engine.
    fn delay(&mut self, m: u64, n: u64) -> &mut Self {
        let k = self.k(n);
        self.op(ALU | SETA | a_src(k) | m_dest(m));
        let top = self.at();
        self.op(ALU | muir::isa::asm::SUB | a_src(ONE) | m_src(m) | m_dest(m));
        self.op(jcond(3) | 1 << 6 | a_src(ZERO) | m_src(m) | target(top) | N);
        self.fill(1)
    }

    /// M `m` <- 0: a word read from a clock, cleared before the stop.
    fn clear(&mut self, m: u64) -> &mut Self {
        self.op(ALU | SETA | a_src(ZERO) | m_dest(m))
    }

    /// `MD` <- MACHINE-ID, a word of no time, before the stop.
    fn quiet_md(&mut self) -> &mut Self {
        self.read(reg(0), 0o37)
    }
}

/// **The interval timers, the microsecond clock and the real-time clock.**
pub fn timers() -> Vec<(String, Preset)> {
    let mut v = Vec::new();
    // Periodic, timer 1 at 1 us: three rises each cleared, then one cleared
    // late, after periods missed, and the rise after it on the start's grid.
    let mut p = run();
    p.write(1, reg(0o113)).write(1, reg(0o112));
    for _ in 0..3 {
        p.poll(0o112, 2).write(1 | 2, reg(0o112));
    }
    p.poll(0o112, 2).delay(0o27, 300).write(1 | 2, reg(0o112));
    p.poll(0o112, 2).write(1 | 2, reg(0o112));
    p.read(reg(0o112), 0o20).read(reg(0o113), 0o21);
    p.write(0, reg(0o112)).quiet_md().clear(0o20);
    p.stop();
    v.push(("periodic".to_string(), p));
    // One-shot, timer 2 at 2 us: it rises once; a clear starts nothing; off
    // and on again starts it.
    let mut p = run();
    p.write(2, reg(0o115)).write(1 | 4, reg(0o114));
    p.poll(0o114, 2).write(1 | 2 | 4, reg(0o114));
    p.read(reg(0o114), 0o20).delay(0o27, 300).read(reg(0o114), 0o21);
    p.write(0, reg(0o114)).write(1 | 4, reg(0o114));
    p.poll(0o114, 2).read(reg(0o114), 0o22);
    p.write(0, reg(0o114)).quiet_md();
    p.stop();
    v.push(("one-shot".to_string(), p));
    // A period written while on, timer 0: from 5 us to 1 us, counted from the
    // write; and a period written while off starts nothing.
    let mut p = run();
    p.write(5, reg(0o111)).write(1, reg(0o110));
    p.delay(0o27, 40).write(1, reg(0o111));
    p.poll(0o110, 2).write(1 | 2, reg(0o110)).write(0, reg(0o110));
    p.write(3, reg(0o111)).delay(0o27, 300).read(reg(0o110), 0o20);
    p.quiet_md();
    p.stop();
    v.push(("period-write".to_string(), p));
    // Word 100 under the enables: timer 0 enabled, timer 1 not, both at
    // 1 us; the bits read with both flags up, then timer 0's cleared.
    let mut p = run();
    p.write(1, reg(0o111)).write(1, reg(0o113));
    p.write(1 | 1 << 8, reg(0o110)).write(1, reg(0o112));
    p.poll(0o112, 2).poll(0o110, 2).read(reg(0o100), 0o20);
    p.write(0, reg(0o112)).write(1 << 8, reg(0o110)).read(reg(0o100), 0o21);
    p.quiet_md();
    p.stop();
    v.push(("word-100".to_string(), p));
    // The microsecond clock, read at the start and after delays; and the
    // real-time clock, which reads its start throughout a trace.
    let mut p = run();
    p.op(ALU | SETM | src(0o15) | m_dest(0o20));
    for (k, n) in [(1, 30), (2, 100), (3, 300)] {
        p.delay(0o27, n);
        p.op(ALU | SETM | src(0o15) | m_dest(0o20 + k));
    }
    p.read(reg(0o103), 0o25);
    // Read at every clock across microseconds' edges: a block of words that
    // read the clock, one a clock.
    for _ in 0..2 {
        p.delay(0o27, 40);
        for _ in 0..130 {
            p.op(ALU | SETM | src(0o15) | m_dest(0o24));
        }
    }
    for k in 0..5 {
        p.clear(0o20 + k);
    }
    p.quiet_md();
    p.stop();
    v.push(("clocks".to_string(), p));
    // RESET-DEVICES: timer 0 running with its enable, block-disk's done
    // enabled; word 100 before and after, the timer's and block-disk's
    // words after.
    let mut p = run();
    p.write(1, reg(0o111)).write(1 | 1 << 8, reg(0o110)).write(1 << 11, reg(0o200));
    p.poll(0o110, 2).read(reg(0o100), 0o20);
    p.write(1, reg(0o104)).read(reg(0o100), 0o21);
    p.read(reg(0o110), 0o22).read(reg(0o111), 0o23).read(reg(0o200), 0o24).read(reg(0o104), 0o25);
    p.quiet_md();
    p.stop();
    v.push(("reset-devices".to_string(), p));
    v
}

/// Interrupts enabled: INTERRUPT-CONTROL `<27>`, destination 2.
fn enable_interrupts(p: &mut Preset) {
    let v = p.k(1 << 35);
    p.op(ALU | SETA | a_src(v) | fd(0o2));
}

/// The handler: it lowers the flag (timer 0 cleared, a one-shot, so that
/// nothing rises again), counts in M 26 once its write has landed, and
/// returns.
fn handler(p: &mut Preset) {
    p.fill_to(HANDLER);
    p.write(1 | 2 | 4 | 1 << 8, reg(0o110));
    p.fill(2);
    p.op(mark(0o26));
    p.op(filler().raw() | POPJ);
    p.fill(1);
}

/// **A timer's interrupt at every clock across a run of checks** (muir's
/// `an_interrupt_at_every_clock_around_a_check`, with the timer itself
/// raising it): timer 0, one-shot at 1 us with its enable, started; `d`
/// words; six checks of condition 5 with P calling the handler, N or not,
/// the first held on `MD` when `held`; then a loop of the same check until
/// the handler has run, so that it runs once whichever check takes it.
fn around(d: u64, n: bool, held: bool) -> Preset {
    let mut p = run();
    enable_interrupts(&mut p);
    p.write(1, reg(0o111)).write(1 | 4 | 1 << 8, reg(0o110));
    p.fill(d as usize);
    let nb = if n { N } else { 0 };
    if held {
        let a = p.k(PHYS | 0o20);
        p.op(ALU | SETA | a_src(a) | START_READ);
        p.fill(1);
    }
    for k in 0..6 {
        let md = if held && k == 0 { SRC_MD } else { 0 };
        p.op(jcond(5) | P | target(HANDLER) | nb | md);
        p.fill(1);
    }
    let top = p.at();
    p.op(jcond(5) | P | target(HANDLER) | N);
    p.fill(1);
    p.op(jcond(3) | a_src(ZERO) | m_src(0o26) | target(top) | N);
    p.fill(1);
    // The return address the call pushed, whichever check took it, written
    // over with a word of no time.
    let w = p.k(0o1234);
    p.op(ALU | SETA | a_src(w) | fd(0o15));
    // The word after a push reads the stack's old word: one between.
    p.fill(1);
    p.op(ALU | SETM | src(0o14) | m_dest(0o25));
    p.quiet_md();
    p.stop();
    handler(&mut p);
    p
}

/// **Conditions 5 and 6 and the register writes' interrupt**, at the
/// period `period` (the timer's rise falls at its clock across the checks).
pub fn interrupt(period: u64) -> Vec<(String, Preset)> {
    let mut v = Vec::new();
    // The rise, 2,000 units after the timer's start, is this many clocks
    // after it; the checks start about a dozen words after the fill.
    let rise = 2000_u64.div_ceil(period);
    for held in [false, true] {
        for n in [false, true] {
            for d in rise.saturating_sub(34)..rise.saturating_sub(10) {
                v.push((
                    format!("timer-h{}-n{}-d{d}", held as u8, n as u8),
                    around(d, n, held),
                ));
            }
        }
    }
    // A register write's interrupt is seen by the check after the next
    // (muir's `a_register_write_s_interrupt_is_seen_by_the_check_after_the_next`
    // and its reverse), and a read right
    // after the write reads the device as it left it.
    let command = |p: &mut Preset, value: Word| {
        let (w, at) = (p.k(value), p.k(reg(0o200)));
        p.op(ALU | SETA | a_src(w) | muir::isa::asm::MD);
        p.op(ALU | SETA | a_src(at) | muir::isa::asm::START_WRITE);
    };
    let checks = |p: &mut Preset| {
        p.op(jcond(5) | P | N | target(0o700));
        p.op(jcond(5) | P | N | target(0o720));
    };
    let handlers = |p: &mut Preset| {
        for (at, slot) in [(0o700, 0o26), (0o720, 0o27)] {
            p.fill_to(at);
            p.op(mark(slot));
            p.op(filler().raw() | POPJ);
            p.fill(1);
        }
    };
    let mut p = run();
    enable_interrupts(&mut p);
    command(&mut p, 1 << 11);
    checks(&mut p);
    p.fill(2);
    // Lowered before the stop, so that nothing more is taken.
    command(&mut p, 0);
    p.fill(3);
    p.stop();
    handlers(&mut p);
    v.push(("register-write-raises".to_string(), p));
    let mut p = run();
    enable_interrupts(&mut p);
    command(&mut p, 1 << 11);
    p.fill(4);
    command(&mut p, 0);
    checks(&mut p);
    p.fill(2);
    p.stop();
    handlers(&mut p);
    v.push(("register-write-lowers".to_string(), p));
    let mut p = run();
    command(&mut p, 1 << 11);
    let w100 = p.k(reg(0o100));
    p.op(ALU | SETA | a_src(w100) | START_READ);
    p.fill(1);
    p.op(ALU | SETM | SRC_MD | m_dest(0o26));
    command(&mut p, 0);
    p.fill(3);
    p.stop();
    v.push(("register-read-after-write".to_string(), p));
    v
}

/// **Block-disk's registers with no pack** (muir's `BlockDisk`): each
/// register written and read back; START of a read, of a write and of
/// another command, which stops by error; the done interrupt's enable.
pub fn blockdisk() -> Vec<(String, Preset)> {
    let mut v = Vec::new();
    let mut p = run();
    p.read(reg(0o200), 0o20);
    p.write(0o1234, reg(0o201)).write(0o7654321, reg(0o202));
    p.read(reg(0o201), 0o21).read(reg(0o202), 0o22).read(reg(0o203), 0o23);
    for (k, cmd) in [0o0, 0o11, 0o5].into_iter().enumerate() {
        p.write(cmd | 1 << 11, reg(0o200)).write(0, reg(0o203));
        p.read(reg(0o200), 0o24 + k as u64).read(reg(0o100), 0o27 + k as u64);
    }
    p.write(0, reg(0o200)).read(reg(0o200), 0o32);
    p.stop();
    v.push(("registers".to_string(), p));
    v
}

/// The file device's rings and buffer A, physical word addresses, each on a
/// line (muir's test's).
const CMD_RING: u64 = 0o1000;
const RESP_RING: u64 = 0o1100;
const BUF_A: u64 = 0o1200;
const LOG_TAG: u64 = 0o4321;

/// A command entry at the ring's slot `k`: word 0 last, as a processor
/// writes one.
fn command(p: &mut Preset, k: u64, words: [Word; 8]) {
    for (j, &w) in words.iter().enumerate().skip(1) {
        p.write(w, PHYS | (CMD_RING + 8 * k + j as u64));
    }
    p.write(words[0], PHYS | (CMD_RING + 8 * k));
}

/// Waits until register-page word `k` reads `v`.
fn wait_for(p: &mut Preset, k: u64, v: Word) {
    let (at, want) = (p.k(reg(k)), p.k(v));
    let round = p.at();
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.fill(1);
    p.op(jcond(3) | 1 << 6 | SRC_MD | a_src(want) | target(round));
    p.fill(1);
}

/// **The file device** (contract Q9; muir's
/// `the_file_device_reads_its_entry_whole_and_the_sweep_shows_its_response`).
pub fn filedev() -> Vec<(String, Preset)> {
    use muir::file_device::op;
    let mut v = Vec::new();
    // The registers: power-on; the rings written while off and read back;
    // enable refused for a base off a line; enabled; a ring size written
    // while on goes nowhere; a producer past the ring faults; a control
    // write clears the faults; disabled; and RESET-DEVICES.
    let mut p = run();
    for k in 0o160..=0o171 {
        p.read(reg(k), 0o20 + (k - 0o160) % 8);
    }
    p.write(CMD_RING + 3, reg(0o162)).write(2, reg(0o163)).write(RESP_RING, reg(0o166));
    p.write(1, reg(0o167)).write(1, reg(0o160));
    p.read(reg(0o161), 0o20).read(reg(0o162), 0o21);
    p.write(CMD_RING, reg(0o162)).write(1 | 1 << 8, reg(0o160));
    p.read(reg(0o161), 0o22).read(reg(0o160), 0o23).write(3, reg(0o163)).read(reg(0o163), 0o24);
    p.write(9, reg(0o164)).read(reg(0o161), 0o25).read(reg(0o164), 0o26);
    p.write(1 | 1 << 8, reg(0o160)).read(reg(0o161), 0o27);
    p.write(0, reg(0o160)).read(reg(0o161), 0o30);
    p.write(1, reg(0o160)).write(1, reg(0o104)).read(reg(0o161), 0o31).read(reg(0o162), 0o32);
    p.stop();
    v.push(("registers".to_string(), p));
    // LOG of "hello" behind a port that answers a write in 25 us: CMD_PROD
    // waits for the entry's writes, and the response is read over a line
    // read before the command, which the completion's sweep clears.
    let mut p = run();
    p.timing = Some(muir::pipeline::PortTiming { read_ns: 247, write_ns: 25_000, occupancy_ns: 10 });
    p.write(CMD_RING, reg(0o162)).write(0, reg(0o163)).write(RESP_RING, reg(0o166));
    p.write(0, reg(0o167)).write(1, reg(0o160));
    command(&mut p, 0, [LOG_TAG | Word::from(op::LOG) << 16, 0, BUF_A, 5, 0, 0, 0, 0]);
    p.write(Word::from(u32::from_le_bytes(*b"hell")), PHYS | BUF_A);
    p.write(Word::from(b'o'), PHYS | (BUF_A + 1));
    p.read(PHYS | RESP_RING, 0o25);
    p.write(1, reg(0o164));
    wait_for(&mut p, 0o170, 1);
    p.read(PHYS | RESP_RING, 0o26);
    // A response waits, the interrupt enable off: word 100 `<7>` clear.
    p.read(reg(0o100), 0o27).read(reg(0o161), 0o30);
    p.stop();
    v.push(("log".to_string(), p));
    // Two commands in a ring of two, the second's opcode unknown, under the
    // interrupt enable: word 100 while a response waits, the responses read
    // and consumed one by one.
    let mut p = run();
    p.write(CMD_RING, reg(0o162)).write(1, reg(0o163)).write(RESP_RING, reg(0o166));
    p.write(1, reg(0o167)).write(1 | 1 << 8, reg(0o160));
    p.write(Word::from(u32::from_le_bytes(*b"ab\0\0")), PHYS | BUF_A);
    command(&mut p, 0, [0o11 | Word::from(op::LOG) << 16, 0, BUF_A, 2, 0, 0, 0, 0]);
    command(&mut p, 1, [0o22 | 0o77 << 16, 0, 0, 0, 0, 0, 0, 0]);
    p.write(2, reg(0o164));
    wait_for(&mut p, 0o170, 2);
    p.read(reg(0o100), 0o20).read(reg(0o161), 0o21);
    p.read(PHYS | RESP_RING, 0o22).read(PHYS | (RESP_RING + 8), 0o23);
    p.write(1, reg(0o171)).read(reg(0o100), 0o24);
    p.write(2, reg(0o171)).read(reg(0o100), 0o25).read(reg(0o161), 0o26);
    p.stop();
    v.push(("two-commands".to_string(), p));
    v
}

/// The device window: the frame buffer from its slice 0.
const fn win(off: u64) -> Word {
    0o34000000000 | off
}

/// **The frame buffer's window** (G1 §4.2; `busint::decode_quux_14`).
pub fn window() -> Vec<(String, Preset)> {
    const LIST: Word = 0o016 << 32;
    let mut v = Vec::new();
    // A word written and read back: a miss whose fill reads the buffer's
    // field with a fixnum's tag; a hit; a write of a word the cache holds;
    // the line evicted by two lines of main memory in its set, and filled
    // again with the field written.  **NOT READ WHILE THE LINE HOLDS IT**:
    // muir's pipeline keeps the word's tag in the line, a hit reading it
    // whole, where `micro` and a fill read the buffer's field with a
    // fixnum's tag, so no trace of that read can be taken until muir
    // settles which.
    let mut p = run();
    p.write(LIST | 0o12345, win(5)).read(win(5), 0o20).read(win(5), 0o21);
    p.write(LIST | 0o54321, win(6));
    p.read(PHYS | (32768 + 6), 0o23).read(PHYS | (65536 + 6), 0o24);
    p.read(win(6), 0o25).read(win(5), 0o26);
    p.stop();
    v.push(("write-read-evict".to_string(), p));
    // Sixteen words, two lines, each its offset in its field, written from
    // the last down so that a write that runs past its four bytes is seen,
    // and read back.
    let mut p = run();
    for k in (0..16).rev() {
        p.write(0o100 + k, win(0o2000 + k));
    }
    for k in 0..16 {
        p.read(win(0o2000 + k), 0o20 + (k % 8));
    }
    p.stop();
    v.push(("sixteen".to_string(), p));
    // Past the buffer: nothing there, MD 0 and the bus error; word 101
    // read and cleared.
    let mut p = run();
    p.read(win(40960), 0o20).read(win(0o777777), 0o21).read(reg(0o101), 0o22);
    p.write(0, reg(0o101)).read(reg(0o101), 0o23);
    p.write(1, win(40960)).read(reg(0o101), 0o24);
    p.stop();
    v.push(("nothing-there".to_string(), p));
    // The video controller's mode: black-on-white kept, nothing else.
    let mut p = run();
    p.read(reg(0o210), 0o20).write(0o7777, reg(0o210)).read(reg(0o210), 0o21);
    p.write(0o3, reg(0o210)).read(reg(0o210), 0o22);
    p.stop();
    v.push(("video-mode".to_string(), p));
    v
}

#[allow(dead_code)]
fn _uses() {
    let _ = (ADD, AND, JUMP, M_ZERO);
}
