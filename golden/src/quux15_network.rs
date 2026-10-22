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
//!   txempty   a START with no word written: Transmit Done down at the read
//!             and up again as the empty frame ends
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
//! **ON REVISION 16 THERE IS NO NETWORK** (QUUX's Ethernet contract, section
//! 8 R4): no interface and no cable, 140-157 reserved and never reused, word
//! 100 `<6>` never set.  The group's runs there are two, with nothing on a
//! cable:
//!
//!   reserved-reads   every word of 140-157 read, word 100, RESET-DEVICES
//!   reserved-writes  the words revision 15's interface acts on written as
//!                    it acts on them, interrupts enabled, condition 5
//!                    checked after each step, every word of 140-157
//!                    written all ones and read back
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
//!   # chaos-busy <clock> <level>              a frame on the line, from its
//!                                             first edge to its idle, from
//!                                             that row
//!   # chaos-start <clock>                     the frame's `START^`
//!   # chaos-stored <clock> <bits>             the bits the receiver would
//!                                             have stored of it so far,
//!                                             from that row
//!   # chaos-rx <clock> <bits> <crc> <n> <words>  a frame in the buffer, its
//!                                             words as the far end hands
//!                                             them (`quux15_chaos.rs`'s
//!                                             `handed`)
//!   # chaos-lost <clock>                      a frame counted lost
//!   # chaos-txdone <clock> <abort>            Transmit Done
//!   # chaos-tx <clock> <n> <words>            START taken at that clock:
//!                                             the frame the fabric sends,
//!                                             the source and the check
//!                                             word with it
//!
//! The line's three are the cable's facts and not muir's face, read off
//! its turn timer's frames and its cable (`golden/src/chaos_state.rs`):
//! the card keeps its own receive gate from them, as the netlist board's
//! `RACT` is, and shows them through it --- bit 14 the line taken, the bit
//! count the bits stored. Every frame here lands with a good check word,
//! and CRC Error after is the check of the words read, which the interface
//! makes itself.  `micro` is not run: what a run ends with
//! depends on the cable's instants, which `micro` keeps otherwise.

use muir::chaos::board::Interface;
use muir::chaos::ether::{BUSY_ABORT_NS, Ether, RACT_NS};
use muir::chaos::packet::check_word;
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
        // The frame START made ready, as `Turn::save` writes it: the words
        // written when it is a frame of them, its source and check word to
        // be made again; otherwise the line itself and 512 words more.
        let ready = if r.bool()? {
            r.u64()?;
            let mut v = r.u16s()?;
            if v.len() >= 512 {
                v.truncate(v.len() - 512);
            } else {
                v.push(ME);
                v.push(check_word(&v));
            }
            Some(v)
        } else {
            None
        };
        Ok(Seen { rdone, tdone, tabort, crc, lost, rcv, bits, ready })
    };
    parse(&mut r).expect("the Chaosnet interface's checkpoint, as Interface::load reads it")
}

fn interface(e: &Pipeline) -> &Interface {
    e.machine().ioboard.chaos.as_ref().expect("the Chaosnet interface")
}

/// The clock a frame put on a quiet cable at clock `i`'s instant lands at,
/// its Receive Done first up: measured on an interface of its own, on
/// revision 15's time base and grid at `period`, taken from clock to clock
/// as the pipeline takes its own.
fn landing_clock(words: &[u16], source: u16, i: u64, period: u64) -> u64 {
    let mut solo = Interface::new(ME, Some(Ether::new()), 0, false);
    solo.set_time_base(muir::clock::TimeBase::half_ns(period));
    solo.advance(i * period);
    solo.ether_mut().expect("its cable").send_now(i * period, source, words.to_vec());
    let mut k = i;
    while solo.csr() & 0o100000 == 0 {
        k += 1;
        solo.advance(k * period);
        assert!(k < i + 1_000_000, "the frame never landed");
    }
    k
}

/// The clock whose instant is the first at or after `units` (MP2b ruling
/// Q19).
fn clock_at(units: u64, period: u64) -> u64 {
    units.div_ceil(period)
}

/// Takes the I/O board to clock `k`'s instant, as the pipeline's own first
/// step in the clock does (`Machine::advance_ioboard` at `instant(k)`).
fn advance_to(e: &mut Pipeline, k: u64) {
    let at = k * e.period();
    let m = e.machine_mut();
    let keep = m.ns;
    m.ns = at;
    m.advance_ioboard();
    m.ns = keep;
}

/// Puts `f` on the cable at clock `k`'s instant, in the machine's units.
fn send(e: &mut Pipeline, k: u64, f: &Frame) {
    let at = k * e.period();
    let ether = e.machine_mut().ioboard.chaos.as_mut().and_then(|c| c.ether_mut());
    ether.expect("the cable").send_now(at, f.source, f.words.clone());
}

/// **The run's network as it goes**: the frames with their clocks, the
/// interface as last seen, and the testbench's lines.
pub struct Net {
    /// Each frame, the clock it goes on the cable before, the clock it is
    /// to land or be counted at, and whether it has gone.
    frames: Vec<(Frame, u64, Option<u64>, bool)>,
    period: u64,
    last: Seen,
    pre: Seen,
    /// The line as the lines so far have put it: the frame on it, by its
    /// first edge, whether its `START^` has been said and the receive gate
    /// as `START^` set it, and the bits stored so far as last said.
    busy: Option<u64>,
    started: bool,
    ract: bool,
    stored: usize,
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
    e.configure(period, case.timing.unwrap_or(super::timing()), super::cache_words());
    e.bubbles = bubbles;
    e.port.model = case.late;
    let mut t = super::trace15::Trace15::start(&mut e);
    e.boot();
    if case.skip_sweep {
        e.skip_sweep();
    }
    let _ = t.row(&e);
    let mut seen = 0u32;
    while e.clock() < 200_000 {
        let k = e.clock() + 1;
        advance_to(&mut e, k);
        for (f, i) in frames {
            if *i == k {
                send(&mut e, k, f);
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
        let mut placed: Vec<(Frame, u64)> = Vec::new();
        let mut frames = Vec::new();
        for f in case.net.as_ref().map_or(&[][..], |n| &n.frames[..]) {
            let (inject, target) = match f.anchor {
                Anchor::Start(at) => (anchor_clock(case, period, bubbles, &placed, at)?, None),
                Anchor::Land(at) | Anchor::Lost(at) => {
                    let target = anchor_clock(case, period, bubbles, &placed, at)?;
                    // A frame lands where an interface of its own says; a
                    // lost one is counted `BUSY_ABORT_NS` into it, at the
                    // first clock at or after.
                    let lands_at = |i: u64| match f.anchor {
                        Anchor::Land(_) => landing_clock(&f.words, f.source, i, period),
                        _ => clock_at(i * period + 2 * BUSY_ABORT_NS, period),
                    };
                    // The latest clock whose frame lands by the target.
                    let mut i = target;
                    while i > 1 && lands_at(i) > target {
                        i -= 1;
                    }
                    let lands = lands_at(i);
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
            last: Seen { tdone: true, ..Seen::default() },
            pre: Seen::default(),
            busy: None,
            started: false,
            ract: true,
            stored: 0,
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
        // CRC Error is the frame's verdict when it lands, and from the
        // first read on the check of the words read, which is up partway
        // through any good frame.
        if !a.rdone && b.rdone && b.crc {
            return Err(format!("clock {k}: a frame with a bad check word, which no frame here has"));
        }
        if a.rdone && !b.rdone || a.tdone && !b.tdone {
            return Err(format!("clock {k}: Receive Done or Transmit Done fell with no write"));
        }
        if !a.rdone && b.rdone {
            // The frame as the far end hands it: the buffer, which muir keeps
            // whole in the order it is read, cut to the frame's words; every
            // frame here is whole words and fits it.
            let n = b.bits.div_ceil(16) as usize;
            if b.rcv.len() != 256 || b.bits % 16 != 0 || n > 256 {
                return Err(format!("clock {k}: a frame of {} bits, which no frame here is", b.bits));
            }
            let words: Vec<String> = b.rcv[..n].iter().map(|w| format!("{w:x}")).collect();
            self.lines.push(format!("# chaos-rx {k:x} {:x} {:x} {n:x} {}", b.bits, b.crc as u8, words.join(" ")));
            self.rx.push((k, n));
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
        debug_assert_eq!(e.period(), self.period);
        advance_to(e, k);
        let s = seen(interface(e));
        let last = self.last.clone();
        self.events(k, &last, &s)?;
        self.line(e, k, &s);
        self.pre = s;
        for (f, i, _, made) in self.frames.iter_mut() {
            if *i == k {
                *made = true;
                send(e, k, f);
            }
        }
        Ok(())
    }

    /// **The line at clock `k`, the cable's facts before the receiver's
    /// gate** (`golden/src/chaos_state.rs`): a frame on it from its first
    /// edge to its idle, its `START^`, where the card's receive gate takes
    /// Receive Done, and the bits the receiver would have stored of it so
    /// far. The card shows them through its own gate; muir's `csr()` and
    /// `bit_count()` show them through muir's, which is asserted to let
    /// through no less than the card's: muir taking the frame, the card's
    /// gate is open. (A clear inside a frame closes both, which the far end
    /// does not see.)
    fn line(&mut self, e: &Pipeline, k: u64, s: &Seen) {
        let i = interface(e);
        let time = muir::clock::TimeBase::half_ns(self.period);
        let at = k * self.period;
        let st = super::chaos_state::state(i);
        let now = st.frame_now(at);
        if self.busy.is_some() && self.busy != now.map(|f| f.0) {
            self.lines.push(format!("# chaos-busy {k:x} 0"));
            self.busy = None;
        }
        let Some((first, _)) = now else { return };
        if self.busy.is_none() {
            self.lines.push(format!("# chaos-busy {k:x} 1"));
            self.busy = Some(first);
            self.started = false;
            self.stored = 0;
        }
        let start = if st.loop_back() {
            Some(time.after(first, time.ns(RACT_NS)))
        } else {
            i.ether().map(|_| first + time.ns(RACT_NS))
        };
        if !self.started && start.is_some_and(|u| u <= at) {
            self.lines.push(format!("# chaos-start {k:x}"));
            self.started = true;
            self.ract = !s.rdone;
        }
        let n = st.stored(i, at, time);
        if n != self.stored {
            self.lines.push(format!("# chaos-stored {k:x} {:x}", n % 4096));
            self.stored = n;
        }
        if st.taking(i, at) {
            assert!(!self.started || self.ract, "clock {k}: muir takes the frame and the card's gate is shut");
            if !st.rdone {
                assert_eq!(i.bit_count() as usize, n % 4096, "clock {k}: the bit count while a frame is taken");
            }
        }
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
        let start = reads.contains(&(PAGE_BUS | 0o145));
        // **NEVER THE BUFFER WHILE muir's RECEIVER TAKES A FRAME**: muir does
        // not model that read (`Interface::read_down`), so a run making one
        // would hold the core to an artefact.
        if reads.contains(&(PAGE_BUS | 0o142)) && !pre.rdone {
            let i = interface(e);
            let st = super::chaos_state::state(i);
            if st.taking(i, k * self.period) {
                return Err(format!("clock {k}: a read of the buffer while muir's receiver takes a frame"));
            }
        }
        if read {
            // A read of START takes Transmit Done down itself (MIT's
            // TRESET), after the cable's events up to the read's instant:
            // the fall is the read's, the fabric's own, and no line.
            let mut cable = s.clone();
            if start {
                cable.tdone = pre.tdone;
            }
            self.events(k, &pre, &cable)?;
        } else if !write {
            let same = |x: &Seen| (x.rdone, x.tdone, x.tabort, x.lost, x.rcv.clone());
            if same(&pre) != same(&s) {
                return Err(format!("clock {k}: the interface changed with no register taken"));
            }
        }
        if start {
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

/// **An empty START**: no word written, Transmit Done up from power-on; the
/// read of START takes it down (MIT's TRESET), the frame of the source and
/// its check word goes, and the CSR is polled until Transmit Done comes
/// back, `d` clocks further on each run.
fn txempty(d: usize) -> Preset {
    let mut p = run();
    p.net_read(0o140, 0o21);
    p.fill(d);
    p.net_read(0o145, 0o22);
    p.net_read(0o140, 0o23);
    p.net_poll(0o140, TDONE);
    p.net_read(0o140, 0o24);
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

/// **Revision 16's 140-157 read**, each, and word 100: every one reserved,
/// a constant 0 (QUUX's Ethernet contract, section 8 R4), and RESET-DEVICES
/// changes none of them.
fn reserved_reads() -> Preset {
    let mut p = run();
    for (j, k) in (0o140..=0o157).enumerate() {
        p.net_read(k, 0o20 + j as u64 % 12);
    }
    p.net_read(0o100, 0o32);
    p.net_write(1, 0o104);
    p.net_read(0o140, 0o33).net_read(0o100, 0o32);
    p.stop();
    p
}

/// **Revision 16's 140-157 written as revision 15's interface acts on
/// them**, interrupts enabled: the CSR's two enables and Loop Back, a
/// frame's words and START's read, then every word of 140-157 written all
/// ones and read back, word 100 read, and condition 5 checked after each
/// step, calling a handler that counts in M 21.  Revision 15's interface
/// raises `<6>` at the first write, Transmit Done being up from power-on;
/// revision 16 has no interface, so nothing is taken, every word reads 0,
/// `<6>` is never set and the handler is never called.
fn reserved_writes() -> Preset {
    let mut p = run();
    enable_interrupts(&mut p);
    let check = |p: &mut Preset| {
        p.op(jcond(5) | P | target(HANDLER) | N);
        p.fill(1);
    };
    p.net_write(TIE | RIE | LOOP_BACK, 0o140);
    check(&mut p);
    for w in [0o1111, 0o2222, u64::from(ME)] {
        p.net_write(w, 0o141);
    }
    p.net_read(0o145, 0o20);
    check(&mut p);
    p.net_read(0o100, 0o22);
    for k in 0o140..=0o157 {
        p.net_write(0o177777, k);
    }
    check(&mut p);
    for (j, k) in (0o140..=0o157).enumerate() {
        p.net_read(k, 0o23 + j as u64 % 8);
    }
    p.net_read(0o100, 0o33);
    check(&mut p);
    p.stop();
    p.fill_to(HANDLER);
    p.op(mark(0o21));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    p
}

/// **The runs.**  On revision 16 (QUUX's Ethernet contract, section 8
/// R4) there is no interface and no cable: its 140-157 are reserved and
/// never reused, word 100 `<6>` is never set, and the runs are the two
/// that hold that.
pub fn network(period: u64) -> Vec<Case> {
    if super::revision() == 16 {
        return vec![reserved_reads().case("reserved-reads"), reserved_writes().case("reserved-writes")];
    }
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
    for d in 0..=7 {
        v.push(txempty(d).case(&format!("txempty-{d}")));
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
