// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's network** (contracts Q4 and Q13; G3 revision 15, A15b.3,
//! §9; MP2b rulings Q4 and Q19): runs of `golden/src/quux15.rs`'s kind with
//! frames put on muir's Chaosnet cable as the run goes, and the far end's
//! side of what muir's interface did written down for the testbench, which
//! plays that far end on the core's cable seam (`quux15_chaos.sv`).
//!
//!   rxpoll    a frame landing at every clock of a polling loop on the
//!             CSR's Receive Done, then read out: the bit count, the words,
//!             the source and the check word, past the end, Clear Receiver
//!   rx100     the same on word 100's `<6>`, the receive interrupt enabled
//!             with interrupts off
//!   rxirq     a frame landing at every clock of an interrupt-driven loop,
//!             condition 5 calling a handler that reads it out and clears
//!             the receiver
//!   tx        a frame written and sent, START at a clock further on each
//!             run, and Transmit Done at the clocks of a polling loop that
//!             follow
//!   txirq     the same with the transmit interrupt enabled, condition 5
//!             calling the handler
//!   lost      a frame waiting unread, and another for this interface at
//!             every clock of a polling loop on the lost count, read and
//!             cleared
//!   lostwrap  seventeen broadcasts lost, the count wrapped to 1
//!   loop      a frame sent under Loop Back and read back
//!   words     the words that take no write and read 0, the CSR's bits
//!             written and read back, Clear Transmitter
//!   reset     the CSR's Reset and RESET-DEVICES with a frame waiting and the
//!             enables set
//!
//! **A FRAME IS PUT ON THE CABLE AT A CLOCK'S INSTANT** (`Ether::send_now`,
//! in whole ns, which is the instant halved on revision 15): muir's
//! `Interface` and `Ether` keep whole ns, so a frame cannot start at an odd
//! unit, and need not --- the far end's instant is this harness's to pick,
//! and every clock's span of units holds a whole ns at the periods here.
//! Where it **lands** is muir's: measured on an interface of its own, and
//! the frame is put on the cable so many clocks before the clock it is to
//! land at, which is placed by the program, `plus` clocks after the `nth`
//! commit of a control store address (found by running the case up to it
//! first), so that a sweep over a loop's clocks is the same sweep at every
//! period and with one bubble or two.  A lost frame is placed the same way
//! by the instant the busy receiver counts it, `ether::BUSY_ABORT_NS` into
//! it.  The run then checks that each landed, or was counted, at its clock.
//!
//! **WHAT THE TESTBENCH IS TOLD IS WHAT muir's INTERFACE DID, BY CLOCK.**
//! Before each clock the interface is taken to that clock's instant, as the
//! pipeline's own first step in the clock does, and looked at; after the
//! clock it is looked at again.  A change between the two looks before a
//! clock is the cable's, at that clock; a change inside a clock is the
//! cable's too when the clock granted a register read --- muir reads a
//! register at `instant(grant + 1)`, taking the interface there --- and the
//! write's own when it took one.  So `<clock>` below is the first row whose
//! registers have it, and the testbench puts it on the seam in the clock
//! before (`chaos_rx_done`, `chaos_rx_lost`, `chaos_tx_done`), a frame's
//! words in the clocks before that:
//!
//!   # chaos-address <address>                 the switches
//!   # chaos-busy <clock> <level>              the cable busy from that row
//!   # chaos-rx <clock> <bits> <crc> <n> <words>  a frame in the buffer
//!   # chaos-lost <clock>                      a frame counted lost
//!   # chaos-txdone <clock> <abort>            Transmit Done
//!   # chaos-tx <clock> <n> <words>            START taken at that clock:
//!                                             the buffer the fabric sends
//!
//! The busy level is bit 14 of muir's CSR, which its model raises while a
//! frame is on the cable; every frame here has a good check word, so the
//! bit is the cable's alone.  `micro` is not run: what a run ends with
//! depends on the cable's instants, which `micro` keeps otherwise.

use muir::chaos::board::Interface;
use muir::chaos::ether::{BUSY_ABORT_NS, Ether};
use muir::engine::Engine;
use muir::isa::asm::{
    ADD, ALU, AND, JUMP, MD, N, P, POPJ, SETA, SETM, SRC_MD, START_READ, START_WRITE, SUB, a_dest,
    a_src, filler, m_dest, m_src, target,
};
use muir::machine::Word;
use muir::pipeline::{Event, Pipeline};

use super::Case;
use super::quux15_input::At;
use super::quux15_preset::Preset;

/// This interface's address, muir's default switches
/// (`chaos::Config::default`), and the far end's.
pub const ME: u16 = 0o177001;
const PEER: u16 = 0o3040;

/// The register page's virtual address and its bus address.
const REGISTER_PAGE: Word = 0o35777777400;
const PAGE_BUS: u32 = muir::tlb::REGISTER_PAGE_BUS;
/// A memory's 0 and 1, and M memory's 0 (`quux15_preset.rs`'s).
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;
/// The A word a poll tests, and the handler a check calls.
const TESTED: u64 = 0o1710;
const HANDLER: u64 = 0o700;

/// The CSR's bits (`chaos::interface::csr`).
const RDONE: u64 = 0o100000;
const TDONE: u64 = 0o200;
const LOST: u64 = 0o17000;
const CLEAR_RECEIVER: u64 = 0o10;
const RIE: u64 = 0o20;
const TIE: u64 = 0o40;
const CLEAR_TRANSMITTER: u64 = 0o400;
const LOOP_BACK: u64 = 0o2;
const RESET: u64 = 0o20000;

/// Where a frame is placed: the clock it lands at, the clock the busy
/// receiver counts it at, or the clock it starts at.
#[derive(Clone, Copy, Debug)]
pub enum Anchor {
    Land(At),
    Lost(At),
    Start(At),
}

/// A frame for the cable: its words as the far end's software writes them,
/// destination last, and its source.
#[derive(Clone, Debug)]
pub struct Frame {
    pub anchor: Anchor,
    pub words: Vec<u16>,
    pub source: u16,
}

/// The run's frames.
#[derive(Clone, Debug, Default)]
pub struct NetRun {
    pub frames: Vec<Frame>,
}

/// **muir's interface as the far end sees it**: the CSR's bits, the
/// incoming buffer, and the frame START made ready.
#[derive(Clone, Debug, PartialEq, Default)]
struct Seen {
    rdone: bool,
    tdone: bool,
    tabort: bool,
    crc: bool,
    lost: u8,
    busy: bool,
    rcv: Vec<u16>,
    bits: u64,
    ready: Option<Vec<u16>>,
}

/// The interface, read through its checkpoint (`Interface::save`, the order
/// `Interface::load` reads).
fn seen(i: &Interface) -> Seen {
    let mut w = muir::checkpoint::Writer::new();
    i.save(&mut w);
    let b = w.finish();
    let mut r = muir::checkpoint::Reader::new(&b);
    let parse = |r: &mut muir::checkpoint::Reader| -> std::io::Result<Seen> {
        r.u16()?;
        r.u16()?;
        let tdone = r.bool()?;
        let tabort = r.bool()?;
        let rdone = r.bool()?;
        let crc = r.bool()?;
        let lost = r.u8()?;
        r.u16s()?;
        let rcv = r.u16s()?;
        r.u64()?;
        let bits = r.u64()?;
        r.opt(muir::checkpoint::Reader::u64)?;
        for _ in 0..r.u64()? {
            r.u64()?;
            r.u16s()?;
            r.u16()?;
            r.u16()?;
            r.bool()?;
            r.u64()?;
        }
        r.u64()?;
        r.u64()?;
        r.bool()?;
        r.u8()?;
        for _ in 0..r.u64()? {
            r.u64()?;
            r.u16()?;
            r.u64()?;
        }
        let ready = if r.bool()? {
            r.u64()?;
            Some(r.u16s()?)
        } else {
            None
        };
        Ok(Seen { rdone, tdone, tabort, crc, lost, busy: false, rcv, bits, ready })
    };
    let mut s = parse(&mut r).expect("the Chaosnet interface's checkpoint, as Interface::load reads it");
    s.busy = i.csr() & 0o40000 != 0 && !s.crc;
    s
}

fn interface(e: &Pipeline) -> &Interface {
    e.machine().ioboard.chaos.as_ref().expect("the Chaosnet interface")
}

/// From a frame's first edge on the cable to its Receive Done, on a quiet
/// cable: measured on an interface of its own.
fn landing_ns(words: &[u16], source: u16) -> u64 {
    let start = 10_000;
    let mut solo = Interface::new(ME, Some(Ether::new()), 0, false);
    solo.advance(start);
    solo.ether_mut().expect("its cable").send_now(start, source, words.to_vec());
    let bits = muir::chaos::packet::frame(words, source).len() as u64;
    let mut t = start + bits * muir::chaos::wire::CELL_NS - 1_000;
    solo.advance(t);
    assert_eq!(solo.csr() & 0o100000, 0, "the frame landed before its last bit");
    while solo.csr() & 0o100000 == 0 {
        t += 1;
        solo.advance(t);
        assert!(t < start + 10 * bits * muir::chaos::wire::CELL_NS, "the frame never landed");
    }
    t - start
}

/// The clock whose instant is the first at or after `ns` (MP2b ruling Q19).
fn clock_at(ns: u64, period: u64, per_ns: u64) -> u64 {
    (ns * per_ns).div_ceil(period)
}

/// The whole ns a frame put on the cable before clock `k` starts at.
fn start_ns(k: u64, period: u64, per_ns: u64) -> u64 {
    k * period / per_ns
}

/// **The run's network as it goes**: the frames with their clocks, the
/// interface as last seen, and the testbench's lines.
pub struct Net {
    /// Each frame, the clock it goes on the cable before, the clock it is
    /// to land or be counted at, and whether it has gone.
    frames: Vec<(Frame, u64, Option<u64>, bool)>,
    period: u64,
    per_ns: u64,
    last: Seen,
    pre: Seen,
    busy: bool,
    events: usize,
    /// Clocks a write of the CSR or of RESET-DEVICES was taken in.
    writes: Vec<u64>,
    rx: Vec<(u64, usize)>,
    lost: Vec<u64>,
    pub lines: Vec<String>,
}

/// Runs `case` to the clock `at` names, with `frames` put on the cable at
/// their clocks: that clock.
fn anchor_clock(case: &Case, period: u64, bubbles: u8, frames: &[(Frame, u64)], at: At) -> Result<u64, String> {
    let mut e = Pipeline::new(super::machine(case));
    e.configure(period, case.timing.unwrap_or(super::TIMING), super::CACHE_WORDS);
    e.bubbles = bubbles;
    e.port.model = case.late;
    let mut t = super::trace15::Trace15::start(&mut e);
    e.boot();
    if case.skip_sweep {
        e.skip_sweep();
    }
    let _ = t.row(&e);
    let per_ns = e.machine().time_base().per_ns;
    let mut seen = 0u32;
    while e.clock() < 200_000 {
        let k = e.clock() + 1;
        let ns = start_ns(k, period, per_ns);
        e.machine_mut().ioboard.advance(ns);
        for (f, i) in frames {
            if *i == k {
                let ether = e.machine_mut().ioboard.chaos.as_mut().and_then(|c| c.ether_mut());
                ether.expect("the cable").send_now(ns, f.source, f.words.clone());
            }
        }
        e.tick().map_err(|h| format!("{}: stopped at clock {} finding its frames' clocks: {h:?}", case.name, e.clock()))?;
        let row = t.row(&e);
        if row.commit == Some(Some(at.pc)) {
            seen += 1;
            if seen == at.nth {
                return Ok(e.clock() + at.plus);
            }
        }
    }
    Err(format!("{}: the anchor {at:?} was never reached by clock {}, halted {}, pc {:o}", case.name, e.clock(), e.is_halted(), e.machine().opc))
}

impl Net {
    /// The run's frames placed: each found by running the case to its
    /// anchor with the frames before it on the cable.
    pub fn new(case: &Case, period: u64, bubbles: u8) -> Result<Net, String> {
        let per_ns = super::machine(case).time_base().per_ns;
        let mut placed: Vec<(Frame, u64)> = Vec::new();
        let mut frames = Vec::new();
        for f in case.net.as_ref().map_or(&[][..], |n| &n.frames[..]) {
            let (inject, target) = match f.anchor {
                Anchor::Start(at) => (anchor_clock(case, period, bubbles, &placed, at)?, None),
                Anchor::Land(at) | Anchor::Lost(at) => {
                    let target = anchor_clock(case, period, bubbles, &placed, at)?;
                    let d = match f.anchor {
                        Anchor::Land(_) => landing_ns(&f.words, f.source),
                        _ => BUSY_ABORT_NS,
                    };
                    // The latest clock whose frame lands by the target.
                    let mut i = target;
                    while i > 1 && clock_at(start_ns(i, period, per_ns) + d, period, per_ns) > target {
                        i -= 1;
                    }
                    let lands = clock_at(start_ns(i, period, per_ns) + d, period, per_ns);
                    if lands != target {
                        return Err(format!(
                            "{}: no clock puts a frame on the cable to land at clock {target}: from {i}, {lands}",
                            case.name
                        ));
                    }
                    (i, Some(target))
                }
            };
            if inject < 2 {
                return Err(format!("{}: a frame would go on the cable before clock 2", case.name));
            }
            placed.push((f.clone(), inject));
            frames.push((f.clone(), inject, target, false));
        }
        let mut lines = Vec::new();
        if case.net.is_some() {
            lines.push(format!("# chaos-address {ME:x}"));
        }
        Ok(Net {
            frames,
            period,
            per_ns,
            last: Seen { tdone: true, ..Seen::default() },
            pre: Seen::default(),
            busy: false,
            events: 0,
            writes: Vec::new(),
            rx: Vec::new(),
            lost: Vec::new(),
            lines,
        })
    }

    fn on(&self) -> bool {
        !self.lines.is_empty()
    }

    /// The cable's events between `a` and `b`, at clock `k`.
    fn events(&mut self, k: u64, a: &Seen, b: &Seen) -> Result<(), String> {
        if b.crc {
            return Err(format!("clock {k}: a frame with a bad check word, which no frame here has"));
        }
        if a.rdone && !b.rdone || a.tdone && !b.tdone {
            return Err(format!("clock {k}: Receive Done or Transmit Done fell with no write"));
        }
        if !a.rdone && b.rdone {
            let words: Vec<String> = b.rcv.iter().map(|w| format!("{w:x}")).collect();
            self.lines.push(format!(
                "# chaos-rx {k:x} {:x} {:x} {:x} {}",
                b.bits,
                b.crc as u8,
                b.rcv.len(),
                words.join(" ")
            ));
            self.rx.push((k, b.rcv.len()));
        }
        let lost = b.lost.wrapping_sub(a.lost) & 0o17;
        if lost > 1 {
            return Err(format!("clock {k}: {lost} frames lost in one clock"));
        }
        if lost == 1 {
            self.lines.push(format!("# chaos-lost {k:x}"));
            self.lost.push(k);
        }
        if !a.tdone && b.tdone {
            self.lines.push(format!("# chaos-txdone {k:x} {:x}", b.tabort as u8));
        } else if a.tabort != b.tabort {
            return Err(format!("clock {k}: Transmit Abort moved apart from Transmit Done"));
        }
        Ok(())
    }

    /// Before the clock after `e`'s last: the interface taken to its
    /// instant, as the clock's first step would, and looked at; the frames
    /// due put on the cable.
    pub fn before(&mut self, e: &mut Pipeline) -> Result<(), String> {
        if !self.on() {
            return Ok(());
        }
        let k = e.clock() + 1;
        let ns = start_ns(k, self.period, self.per_ns);
        e.machine_mut().ioboard.advance(ns);
        let s = seen(interface(e));
        let last = self.last.clone();
        self.events(k, &last, &s)?;
        if s.busy != self.busy {
            self.busy = s.busy;
            self.lines.push(format!("# chaos-busy {k:x} {:x}", s.busy as u8));
        }
        self.pre = s;
        for (f, i, _, made) in self.frames.iter_mut() {
            if *i == k {
                *made = true;
                let ether = e.machine_mut().ioboard.chaos.as_mut().and_then(|c| c.ether_mut());
                ether.expect("the cable").send_now(ns, f.source, f.words.clone());
            }
        }
        Ok(())
    }

    /// After a clock of `e`'s: a register read's look ahead, a write's
    /// effect, START.
    pub fn after(&mut self, e: &mut Pipeline) -> Result<(), String> {
        if !self.on() {
            return Ok(());
        }
        let k = e.clock();
        let list = e.events.as_ref().expect("the trace's records are on");
        let (mut regs, mut reads) = (Vec::new(), Vec::new());
        while self.events < list.len() {
            let (c, ev) = &list[self.events];
            if *c > k {
                break;
            }
            if *c == k {
                match ev {
                    Event::Register(b) => regs.push(*b),
                    Event::Grant(b, false) => reads.push(*b),
                    _ => {}
                }
            }
            self.events += 1;
        }
        let read = regs.iter().any(|b| reads.contains(b));
        let write = regs.iter().any(|b| !reads.contains(b));
        for b in &regs {
            if !reads.contains(b) && b & !0o377 == PAGE_BUS && matches!(b & 0o377, 0o140 | 0o104) {
                self.writes.push(k);
            }
        }
        let s = seen(interface(e));
        let pre = self.pre.clone();
        if read {
            self.events(k, &pre, &s)?;
        } else if !write {
            let same = |x: &Seen| (x.rdone, x.tdone, x.tabort, x.lost, x.rcv.clone());
            if same(&pre) != same(&s) {
                return Err(format!("clock {k}: the interface changed with no register taken"));
            }
        }
        if reads.contains(&(PAGE_BUS | 0o145)) {
            let words = s.ready.clone().ok_or_else(|| format!("clock {k}: START with no frame made ready"))?;
            let w: Vec<String> = words.iter().map(|w| format!("{w:x}")).collect();
            self.lines.push(format!("# chaos-tx {:x} {:x} {}", k + 1, words.len(), w.join(" ")));
        }
        self.last = s;
        Ok(())
    }

    /// Whether every frame went, landed or was counted at its clock, and no
    /// write of the CSR came while one's words were streaming in.
    pub fn finished(&self) -> Result<(), String> {
        for (f, i, target, made) in &self.frames {
            if !made {
                return Err(format!("the frame for clock {i} never went on the cable"));
            }
            let Some(t) = *target else { continue };
            // At its clock, or the clock before when that clock granted a
            // register read, which takes muir's interface to the next
            // clock's instant.
            let at = |k: u64| k == t || k + 1 == t;
            let seen = match f.anchor {
                Anchor::Land(_) => self.rx.iter().any(|&(k, _)| at(k)),
                _ => self.lost.iter().any(|&k| at(k)),
            };
            if !seen {
                return Err(format!("the frame {:?} put on the cable before clock {i} did not land at {t}", f.anchor));
            }
        }
        for &(k, n) in &self.rx {
            let from = (k - 1).checked_sub(n as u64).filter(|&f| f >= 1);
            let Some(from) = from else {
                return Err(format!("the frame at clock {k}: its words would stream in before clock 1"));
            };
            if let Some(w) = self.writes.iter().find(|&&w| w >= from && w < k) {
                return Err(format!("a write of the CSR at clock {w}, while the frame landing at {k} streams in"));
            }
        }
        Ok(())
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

/// A run: -RESET's sweep of the TLB taken as done; micro not run.
fn run() -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p
}

impl Preset {
    /// M `slot` <- register-page word `k`.
    fn net_read(&mut self, k: u64, slot: u64) -> &mut Self {
        let a = self.k(reg(k));
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.fill(1);
        self.op(ALU | SETM | SRC_MD | m_dest(slot))
    }

    /// Register-page word `k` <- `v`, and two words after.
    fn net_write(&mut self, v: Word, k: u64) -> &mut Self {
        let (wa, aa) = (self.k(v), self.k(reg(k)));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.fill(2)
    }

    /// Waits until register-page word `k` has a bit of `bits` set: its
    /// first word's address.
    fn net_poll(&mut self, k: u64, bits: Word) -> u64 {
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
    fn net_wait(&mut self, m: u64, n: u64) -> u64 {
        let k = self.k(n);
        self.op(ALU | SETA | a_src(k) | m_dest(m));
        let top = self.at();
        self.op(ALU | SUB | a_src(ONE) | m_src(m) | m_dest(m));
        self.op(jcond(3) | 1 << 6 | a_src(ZERO) | m_src(m) | target(top) | N);
        self.fill(1);
        top
    }

    /// A frame's words read out of the incoming buffer into M `from` on:
    /// the bit count, the `n` words, the source and the check word, the
    /// bit count again, a read past the end.
    fn net_read_out(&mut self, n: u64, from: u64) -> &mut Self {
        self.net_read(0o143, from);
        for j in 0..n + 2 {
            self.net_read(0o142, from + 1 + j);
        }
        self.net_read(0o143, from + n + 3).net_read(0o142, from + n + 4)
    }
}

/// Interrupts enabled: INTERRUPT-CONTROL `<27>`, destination 2.
fn enable_interrupts(p: &mut Preset) {
    let v = p.k(1 << 35);
    p.op(ALU | SETA | a_src(v) | fd(0o2));
}

/// The count of the wait in which a frame crosses the cable before it
/// lands, at the period `period`: a three-word frame takes 20.75 us, and a
/// pass of `net_wait` four clocks, which takes two off the count (`SUB` is
/// M minus A minus one), so the count is even.
fn wait(period: u64) -> u64 {
    (22_000 / period + 100) & !1
}

/// A station whose frame loads this interface's turn counter with 1
/// (`ether::turn_byte`: the difference's bit 14), so that its turn comes two
/// counts after that frame, not up to a round of 256 us later.
const NEAR: u16 = 0o37001;

/// A frame of NEAR's for another station, which this interface hears and
/// does not take: its turn comes right after it.
fn near(at: At) -> Frame {
    Frame { anchor: Anchor::Start(at), words: vec![0o1, PEER], source: NEAR }
}

fn with(mut p: Preset, frames: Vec<Frame>) -> Preset {
    p.net = Some(NetRun { frames });
    p
}

/// A three-word frame from the far end to this interface.
fn frame(anchor: Anchor, a: u16, b: u16) -> Frame {
    Frame { anchor, words: vec![a, b, ME], source: PEER }
}

/// **A frame landing at every clock of a polling loop on the CSR**, then
/// read out and the receiver cleared.
fn rxpoll(d: u64, w: u64) -> Preset {
    let mut p = run();
    p.net_wait(0o20, w);
    let top = p.net_poll(0o140, RDONE);
    p.net_read(0o140, 0o21).net_read_out(3, 0o22);
    p.net_write(CLEAR_RECEIVER, 0o140).net_read(0o140, 0o32).net_read(0o143, 0o33);
    p.stop();
    with(p, vec![frame(Anchor::Land(At { pc: top as u16, nth: 1, plus: d }), 0o1234, 0o5670)])
}

/// **The same on word 100's `<6>`**: the receive interrupt enabled with
/// interrupts off.
fn rx100(d: u64, w: u64) -> Preset {
    let mut p = run();
    p.net_write(RIE, 0o140);
    p.net_wait(0o20, w);
    let top = p.net_poll(0o100, 1 << 6);
    p.net_read_out(3, 0o22);
    p.net_write(RIE | CLEAR_RECEIVER, 0o140).net_read(0o100, 0o32).net_write(0, 0o140).net_read(0o140, 0o33);
    p.stop();
    with(p, vec![frame(Anchor::Land(At { pc: top as u16, nth: 1, plus: d }), 0o2345, 0o6701)])
}

/// **A frame landing at every clock of an interrupt-driven loop**: the
/// receive interrupt enabled, condition 5 calling the handler, which reads
/// it out, clears the receiver and counts.
fn rxirq(d: u64, w: u64) -> Preset {
    let mut p = run();
    p.net_write(RIE, 0o140);
    enable_interrupts(&mut p);
    p.net_wait(0o20, w);
    let top = p.at();
    p.op(jcond(5) | P | target(HANDLER) | N);
    p.fill(1);
    p.op(jcond(3) | a_src(ZERO) | m_src(0o21) | target(top) | N);
    p.fill(1);
    p.net_write(0, 0o140).net_read(0o140, 0o33);
    p.stop();
    p.fill_to(HANDLER);
    p.net_read_out(3, 0o22);
    p.net_write(RIE | CLEAR_RECEIVER, 0o140);
    p.op(mark(0o21));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    with(p, vec![frame(Anchor::Land(At { pc: top as u16, nth: 1, plus: d }), 0o3456, 0o7012)])
}

/// **A frame sent**: three words written, START `d` clocks further on, the
/// CSR polled for Transmit Done, its cable busy meanwhile.  A frame of
/// NEAR's goes by first, so that this interface's turn comes after it.
fn tx(d: usize) -> Preset {
    let mut p = run();
    for w in [0o1111, 0o2222, u64::from(PEER)] {
        p.net_write(w, 0o141);
    }
    p.net_read(0o140, 0o21);
    p.fill(d);
    p.net_read(0o145, 0o22);
    p.net_poll(0o140, TDONE);
    p.net_read(0o140, 0o23);
    p.stop();
    with(p, vec![near(At { pc: 0, nth: 1, plus: 2 })])
}

/// **The same under the transmit interrupt**: enabled after the words are
/// written, condition 5 calling the handler, which reads the CSR, turns
/// the enable off and counts.
fn txirq(d: usize) -> Preset {
    let mut p = run();
    for w in [0o3333, 0o4444, u64::from(PEER)] {
        p.net_write(w, 0o141);
    }
    p.net_write(TIE, 0o140);
    enable_interrupts(&mut p);
    p.fill(d);
    p.net_read(0o145, 0o22);
    let top = p.at();
    p.op(jcond(5) | P | target(HANDLER) | N);
    p.fill(1);
    p.op(jcond(3) | a_src(ZERO) | m_src(0o21) | target(top) | N);
    p.fill(1);
    p.net_read(0o140, 0o23);
    p.stop();
    p.fill_to(HANDLER);
    p.net_read(0o140, 0o24);
    p.net_write(0, 0o140);
    p.op(mark(0o21));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    with(p, vec![near(At { pc: 0, nth: 1, plus: 2 })])
}

/// **A frame lost at every clock of a polling loop on the lost count**: one
/// frame lands and waits unread; another for this interface by name finds
/// the buffer busy; the count read, the receiver cleared, the count read
/// again.
fn lost(d: u64, w: u64) -> Preset {
    let mut p = run();
    let first = p.net_wait(0o20, w);
    p.net_poll(0o140, RDONE);
    p.net_wait(0o20, w);
    let top = p.net_poll(0o140, LOST);
    p.net_read(0o140, 0o21).net_write(CLEAR_RECEIVER, 0o140).net_read(0o140, 0o22);
    p.stop();
    with(
        p,
        vec![
            frame(Anchor::Start(At { pc: first as u16, nth: 1, plus: 2 }), 0o4567, 0o1023),
            frame(Anchor::Lost(At { pc: top as u16, nth: 1, plus: d }), 0o5670, 0o2134),
        ],
    )
}

/// **Seventeen broadcasts lost** behind a frame waiting: the four-bit count
/// wraps to 1.
fn lostwrap(w: u64) -> Preset {
    let mut p = run();
    let first = p.net_wait(0o20, w);
    p.net_poll(0o140, RDONE);
    let top = p.net_wait(0o20, 20_000);
    p.net_read(0o140, 0o21).net_write(CLEAR_RECEIVER, 0o140).net_read(0o140, 0o22);
    p.stop();
    let mut v = vec![frame(Anchor::Start(At { pc: first as u16, nth: 1, plus: 2 }), 0o1357, 0o2460)];
    for j in 0..17u64 {
        v.push(Frame {
            anchor: Anchor::Start(At { pc: top as u16 + 1, nth: 1, plus: 2 + 2_200 * j }),
            words: vec![0o100 + j as u16, 0],
            source: PEER,
        });
    }
    with(p, v)
}

/// **A frame sent under Loop Back** and read back: the cable unused, the
/// receiver on the transmitter.
fn loopback() -> Preset {
    let mut p = run();
    p.net_write(LOOP_BACK, 0o140);
    for w in [0o7070, 0o0707, u64::from(ME)] {
        p.net_write(w, 0o141);
    }
    p.net_read(0o145, 0o21);
    p.net_poll(0o140, RDONE);
    p.net_read(0o140, 0o22).net_read_out(3, 0o23);
    p.stop();
    with(p, Vec::new())
}

/// **The words that take no write, the CSR's bits, Clear Transmitter**:
/// 141, 144, 146 and 147 read; 142 to 147 written, which nothing takes;
/// the CSR's five read/write bits written and read back, then none; a word
/// written into the outgoing buffer, Transmit Done read down, Clear
/// Transmitter, read up.
fn words() -> Preset {
    let mut p = run();
    for (k, slot) in [(0o141, 0o20), (0o144, 0o21), (0o146, 0o22), (0o147, 0o23)] {
        p.net_read(k, slot);
    }
    for k in 0o142..=0o147 {
        p.net_write(0o177777, k);
    }
    p.net_read(0o140, 0o24).net_read(0o143, 0o25);
    p.net_write(0o67, 0o140).net_read(0o140, 0o26);
    p.net_write(0, 0o140).net_read(0o140, 0o27);
    p.net_write(0o4321, 0o141).net_read(0o140, 0o30);
    p.net_write(CLEAR_TRANSMITTER, 0o140).net_read(0o140, 0o31);
    p.stop();
    with(p, Vec::new())
}

/// **The CSR's Reset and RESET-DEVICES** with a frame waiting and both
/// enables set: each read back.
fn reset(devices: bool, w: u64) -> Preset {
    let mut p = run();
    p.net_write(TIE | RIE | 0o4, 0o140);
    let first = p.net_wait(0o20, w);
    p.net_poll(0o140, RDONE);
    p.net_write(0o5555, 0o141);
    p.net_read(0o140, 0o21).net_read(0o100, 0o22);
    if devices {
        p.net_write(1, 0o104);
    } else {
        p.net_write(RESET | RIE, 0o140);
    }
    p.net_read(0o140, 0o23).net_read(0o143, 0o24).net_read(0o142, 0o25).net_read(0o100, 0o26);
    p.stop();
    with(p, vec![frame(Anchor::Start(At { pc: first as u16, nth: 1, plus: 2 }), 0o6543, 0o3210)])
}

/// **The runs.**
pub fn network(period: u64) -> Vec<Case> {
    let w = wait(period);
    let mut v = Vec::new();
    for d in 1..=16 {
        v.push(rxpoll(d, w).case(&format!("rxpoll-{d}")));
    }
    for d in 1..=12 {
        v.push(rx100(d, w).case(&format!("rx100-{d}")));
    }
    for d in 1..=16 {
        v.push(rxirq(d, w).case(&format!("rxirq-{d}")));
    }
    for d in 0..=11 {
        v.push(tx(d).case(&format!("tx-{d}")));
    }
    for d in 0..=7 {
        v.push(txirq(d).case(&format!("txirq-{d}")));
    }
    for d in 1..=12 {
        v.push(lost(d, w).case(&format!("lost-{d}")));
    }
    v.push(lostwrap(w).case("lostwrap"));
    v.push(loopback().case("loopback"));
    v.push(words().case("words"));
    v.push(reset(false, w).case("reset-csr"));
    v.push(reset(true, w).case("reset-devices"));
    for c in v.iter_mut() {
        c.micro_check = false;
    }
    v
}
