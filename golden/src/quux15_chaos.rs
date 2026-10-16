// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! Revision 15's Chaosnet interface (contracts Q4 and Q13) as muir's
//! `chaos::board::Interface` answers a script: reads and writes of the
//! register page's words 140-147, RESET-DEVICES, and what its cable did
//! between them --- frames put on it by a far end, frames this interface
//! sent, Loop Back --- at instants that move on by up to 300 us an
//! operation.  Each line is one thing, with the interrupt's state after it
//! where it has one:
//!
//! ```text
//! r K VALUE IRQ           a read of word K, and what it gave
//! w K VALUE IRQ           a write of VALUE to word K
//! x IRQ                   RESET-DEVICES
//! f BITS CRC N WORDS IRQ  the far end put a frame in the buffer: its words
//!                         as the software reads them, the source and the
//!                         check word last (see [`handed`])
//! k BITS N WORDS IRQ      the far end stored a frame's bits without landing
//!                         it: one taken and not for this interface, or the
//!                         bits a frame dropped by a clear left
//! l IRQ                   the far end counted a frame lost
//! d ABORT IRQ             the far end says the frame is away, or aborted
//! b LEVEL                 a frame is on the line, or not, from here
//! a                       the frame's `START^`, where the receive gate takes
//!                         Receive Done
//! c BITS                  the bits the receiver would have stored of the
//!                         frame by now, gate or no gate, from here
//! s N WORDS               the frame the last START sent, as its transmit
//!                         buffer plays it out: the words, the source and
//!                         the check word, or what a buffer written past its
//!                         end leaves (muir's `packet::line`)
//! ```
//!
//! **The line's three are the cable's facts and not muir's face**
//! (`golden/src/chaos_state.rs`): the frame from its first edge to the line
//! idle, its `START^`, and the bits stored so far as if taken. The card
//! keeps its own receive gate from them --- `RACT` set at `START^` with
//! Receive Done down, taken down by a Clear Receiver, a Reset or
//! RESET-DEVICES --- and shows the cable through it: bit 14 the check word's
//! verdict or the line taken, the bit count the bits stored. Every look
//! asserts that gate equal to muir's own (`Interface::taking`) and the bit
//! count to muir's wherever it takes the frame. **Revision 15's rules are
//! muir's on revision 15's time base**, units of 0.5 ns on an 8.5 ns clock:
//! with none muir keeps the CADR board's.
//!
//! **BOTH BUFFERS GO ROUND** (muir's `ebb3c41`, measured on the netlist
//! board). Words written past the 256th go over the first, so the frame a
//! START sends is `(16n + 32) mod 4096` bits for `n` words written, nothing
//! at all for 254; a frame longer than the receive buffer leaves its last
//! 4,096 bits, the ones the software reads first; reads go on round the
//! buffer; and CRC Error from the first read on is the check of the words
//! read. A run of 48 bits or fewer lands nowhere and leaves its bits with
//! Receive Done down: every frame of 1 to 3 words this interface sends is
//! handed back to it as an `f` line after the line goes idle, and the card
//! judges it by its length.
//!
//! **THE WORDS ARE MAPPED AS `Machine::bus_read` AND `bus_write` MAP THEM**
//! (muir's `network_register`, which is private there, so its table is
//! written again below): 140 the CSR, 141 MY ADDRESS read and the write
//! buffer written, 142 the read buffer, 143 the bit count and 145 START,
//! each read only; the rest read 0 and take no write.  The core's `network`
//! group goes through muir's own map, clock for clock.
//!
//! The cable's events are found as `golden/src/quux15_network.rs` finds
//! them: the interface looked at before each operation, at its instant, and
//! what moved since the last look is the cable's.  Every value is
//! hexadecimal.  `quux15_chaos.sv` is held to it line for line
//! (`tb/quux15_chaos_tb.cpp`).

mod chaos_state;

use chaos_state::{State, handed, state};
use muir::chaos::board::Interface;
use muir::chaos::ether::{Ether, RACT_NS};
use muir::chaos::interface as chaos;
use muir::chaos::packet::check_word;
use muir::chaos::wire::CELL_NS;
use muir::clock::TimeBase;

const ME: u16 = 0o177001;
const PEER: u16 = 0o3040;

/// **Revision 15's time base**, which is what makes muir's interface keep
/// revision 15's rules: units of 0.5 ns on a clock of `PERIOD` of them, 8.5
/// ns, muir's default. With no time base set muir counts nanoseconds and
/// keeps the CADR board's rules --- CRC Error the running check register
/// while a frame is taken, the line idle at the fourth `FCLK^` rise --- which
/// are not this interface's.
const PERIOD: u64 = 17;
const TIME: TimeBase = TimeBase::half_ns(PERIOD);

/// The script's instant `ns` in the interface's units, on the clock.
fn u(ns: u64) -> u64 {
    TIME.grid(TIME.ns(ns))
}

/// A register page's word, read or written, as `network_register` maps it.
fn register(word: u32, write: bool) -> Option<u32> {
    match (word, write) {
        (0o140, _) => Some(chaos::CSR),
        (0o141, false) => Some(chaos::MY_ADDRESS),
        (0o141, true) => Some(chaos::WRITE_BUFFER),
        (0o142, false) => Some(chaos::READ_BUFFER),
        (0o143, false) => Some(chaos::BIT_COUNT),
        (0o145, false) => Some(chaos::START),
        _ => None,
    }
}

/// The incoming buffer by its places, `RBCT / 16`, rather than in the order
/// a frame in it is read: what a frame stored over it changes. Never
/// written, all ones.
fn places(s: &State) -> Vec<u16> {
    if s.rcv.is_empty() {
        return vec![0o177777; 256];
    }
    let top = (s.bits as usize + 4095) % 4096 / 16;
    (0..256).map(|p| s.rcv[(top + 256 - p) % 256]).collect()
}

/// The frame a START made ready, as the checkpoint writes it (muir's
/// `Turn::save`): the words written when it is a frame of them, its source
/// and check word left to be made again; otherwise the line itself and 512
/// words more, which no buffer of words written ever was.
fn line_of(mut v: Vec<u16>) -> Vec<u16> {
    if v.len() >= 512 {
        v.truncate(v.len() - 512);
    } else {
        v.push(ME);
        v.push(check_word(&v));
    }
    v
}

fn irq(i: &Interface) -> u8 {
    i.interrupt_request().is_some() as u8
}

fn words(w: &[u16]) -> String {
    w.iter().map(|w| format!("{w:x}")).collect::<Vec<_>>().join(" ")
}

struct Script {
    i: Interface,
    last: State,
    /// The instant the interface was last taken to, in its units.
    now: u64,
    /// The line as the lines so far have put it: a frame on it, its first
    /// edge, and whether its `START^` and the bits stored so far have been
    /// said.
    busy: Option<u64>,
    started: bool,
    stored: usize,
    /// The receive gate as the far end's lines make it, which is the card's
    /// own: `RACT` set at `START^` with Receive Done down and taken down by
    /// `RRESET`; a frame whose `START^` is still to come counts as taken.
    ract: bool,
    counts: [u64; 24],
    /// The frame the last START sent, until it is over, and whether its
    /// Transmit Done has come.
    sent: Option<Vec<u16>>,
    sent_done: bool,
}

impl Script {
    /// What the card's receive gate makes of the frame on the line.
    fn gate_open(&self) -> bool {
        !self.started || self.ract
    }

    /// The incoming buffer moved without Receive Done, from `a` to `s`: the
    /// far end streams what was stored, to store and not land. A run of 48
    /// bits or fewer this interface sent is one of these, and goes as an
    /// `f` line, the card judging it by its length.
    fn stored_lines(&mut self, a: &State, s: &State, irq: u8) {
        if s.rdone || places(a) == places(s) {
            return;
        }
        let h = handed(&s.rcv, s.bits);
        if let Some(line) = self.sent.as_ref().filter(|l| (1..=3).contains(&l.len()) && s.bits == 16 * l.len() as u64) {
            assert_eq!(&h, line, "a run of this interface's own stored as other bits");
            println!("f {:x} 0 {:x} {} {irq:x}", s.bits, h.len(), words(&h));
            self.counts[6] += 1;
            self.sent = None;
        } else {
            println!("k {:x} {:x} {} {irq:x}", s.bits, h.len(), words(&h));
            self.counts[11] += 1;
        }
    }

    /// The interface at `t` ns, or later if a busy receiver's abort is
    /// standing then: what its cable did since the last look.
    fn look(&mut self, t: u64) {
        let mut t = u(t).max(self.now);
        loop {
            self.i.advance(t);
            let s = state(&self.i);
            // **Transmit Abort before Transmit Done** is a looped frame the
            // busy receiver aborted at its destination word, Transmit Done
            // `TDONE_AFTER_ABORT_NS` on. The seam carries the abort with the
            // done, so nothing is looked at in between.
            match s.tdone_at.filter(|_| s.tabort && !s.tdone) {
                Some(td) => {
                    t = t.max(td);
                    self.counts[12] += 1;
                }
                None => break,
            }
        }
        self.now = t;
        let s = state(&self.i);
        let a = self.last.clone();
        assert!(!(a.rdone && !s.rdone) && !(a.tdone && !s.tdone), "Receive or Transmit Done fell by itself");
        // The interrupt after each line, the lines in this order: the frame
        // in or stored, the losses, Transmit Done; then the line.
        let csr = self.i.csr();
        let (rie, tie) = (csr & chaos::csr::RECEIVE_INT_ENABLE != 0, csr & chaos::csr::TRANSMIT_INT_ENABLE != 0);
        let irq_of = |rdone: bool, tdone: bool| ((rdone && rie) || (tdone && tie)) as u8;
        if !a.rdone && s.rdone {
            assert!(s.bits > 48, "a run of 48 bits or fewer landed");
            let h = handed(&s.rcv, s.bits);
            println!("f {:x} {:x} {:x} {} {:x}", s.bits, s.crc as u8, h.len(), words(&h), irq_of(true, a.tdone));
            self.counts[0] += 1;
            if s.bits > 4_096 {
                self.counts[7] += 1;
            }
            if s.bits % 16 != 0 {
                self.counts[8] += 1;
            }
        } else {
            self.stored_lines(&a, &s, irq_of(false, a.tdone));
        }
        let lost = s.lost.wrapping_sub(a.lost) & 0o17;
        for _ in 0..lost {
            println!("l {:x}", irq_of(s.rdone, a.tdone));
            self.counts[1] += 1;
        }
        if !a.tdone && s.tdone {
            println!("d {:x} {:x}", s.tabort as u8, irq_of(s.rdone, true));
            assert_eq!(irq_of(s.rdone, true), irq(&self.i));
            self.counts[2] += 1;
            self.sent_done = self.sent.is_some();
        } else if a.tdone && s.tdone && !a.tabort && s.tabort {
            // **Transmit Abort after Transmit Done**: a frame of this
            // interface's shorter than the busy receiver's destination word,
            // `BUSY_ABORT_NS` in, its Transmit Done before it; the abort
            // comes as a second Transmit Done, which is how the seam carries
            // an abort.
            println!("d 1 {:x}", irq_of(s.rdone, true));
            self.counts[18] += 1;
        } else {
            assert_eq!(a.tabort, s.tabort, "Transmit Abort moved apart from Transmit Done at {t}");
        }
        // The line: a frame on it from its first edge to its idle, its
        // `START^`, and the bits the receiver would have stored of it.
        let now = s.frame_now(t);
        if self.busy.is_some() && self.busy != now.map(|f| f.0) {
            println!("b 0");
            self.busy = None;
        }
        if let Some((first, _)) = now {
            if self.busy.is_none() {
                println!("b 1");
                self.busy = Some(first);
                self.started = false;
                self.stored = 0;
                self.counts[13] += 1;
            }
            // `START^`: the receiver's, off the cable, and the looped
            // frame's under Loop Back; a frame with neither goes nowhere and
            // has none.
            let start = if s.loop_back() {
                Some(TIME.after(first, TIME.ns(RACT_NS)))
            } else {
                self.i.ether().map(|_| first + TIME.ns(RACT_NS))
            };
            if !self.started && start.is_some_and(|at| at <= t) {
                println!("a");
                self.started = true;
                self.ract = !s.rdone;
                self.counts[14] += 1;
            }
            let k = s.stored(&self.i, t, TIME);
            if k != self.stored {
                println!("c {:x}", k % 4096);
                self.stored = k;
                self.counts[15] += 1;
            }
            // muir's own gate where the far end's lines put the card's.
            let taking = s.taking(&self.i, t);
            assert_eq!(self.gate_open(), taking, "the receive gate at {t}: muir takes the frame, or does not");
            if taking && !s.rdone {
                assert_eq!(self.i.bit_count() as usize, k % 4096, "the bit count while a frame is taken");
            }
        }
        // A run of 48 bits or fewer this interface sent that stored nothing
        // --- Receive Done up, or the bits the buffer already held --- is
        // handed back all the same once the line is idle: the card must
        // land none of it, and store it only where muir did.
        if self.sent_done && self.busy.is_none() {
            if let Some(line) = self.sent.take().filter(|l| (1..=3).contains(&l.len())) {
                println!("f {:x} 0 {:x} {} {:x}", line.len() * 16, line.len(), words(&line), irq(&self.i));
                self.counts[6] += 1;
            }
            self.sent_done = false;
        }
        let down = s.down_here(t).is_some_and(|(_, _, check)| check != 0);
        let taking = now.is_some() && self.gate_open();
        assert_eq!(csr & 0o40000 != 0, s.crc || taking || down, "the CSR's bit 14: the check, the line taken, the count-down");
        self.last = s;
    }

    /// After an operation: what it stored, and its own state.
    fn after(&mut self) {
        let s = state(&self.i);
        let a = self.last.clone();
        let irq = irq(&self.i);
        if s.dropped != a.dropped {
            self.counts[20] += 1;
        }
        self.stored_lines(&a, &s, irq);
        self.last = s;
    }

    fn read(&mut self, t: u64, k: u32) {
        self.look(t);
        // **Never the buffer while the receiver takes a frame**: muir does
        // not model that read (`Interface::read_down`), so the bit count is
        // read in its place.
        let k = if k == 0o142 && !self.last.rdone && self.busy.is_some() && self.gate_open() {
            self.counts[16] += 1;
            0o143
        } else {
            k
        };
        let v = match register(k, false) {
            Some(r) => self.i.read(r, self.now),
            None => 0,
        };
        println!("r {k:x} {v:x} {:x}", irq(&self.i));
        if k == 0o145 {
            let w = line_of(state(&self.i).ready.expect("START made a frame ready"));
            println!("s {:x} {}", w.len(), words(&w));
            self.counts[3] += 1;
            if w.is_empty() {
                self.counts[9] += 1;
            }
            self.sent = Some(w);
            self.sent_done = false;
        }
        if k == 0o142 && v != 0 {
            self.counts[4] += 1;
        }
        // A count-down's word read where the check of every bit read and the
        // check of that word alone part: what tells a check carried from
        // read to read from one begun again at each.
        if k == 0o142
            && let Some((_, hw, check)) = state(&self.i).down_here(self.now)
            && hw % 16 == 15
            && hw != 0o7777
            && (check == 0) != (muir::chaos::packet::check_on(0, &[v]) == 0)
        {
            self.counts[21] += 1;
        }
        if (k == 0o142 || k == 0o143) && !self.last.rdone && self.busy.is_some() {
            self.counts[17] += 1;
            if k == 0o142 {
                self.counts[19] += 1;
            }
        }
        self.after();
    }

    fn write(&mut self, t: u64, k: u32, v: u16) {
        self.look(t);
        if let Some(r) = register(k, true) {
            self.i.write(r, v, self.now);
        }
        if k == 0o140 && v & (chaos::csr::CLEAR_TRANSMITTER | chaos::csr::RESET) != 0 {
            self.sent = None;
        }
        if k == 0o140 && v & (chaos::csr::CLEAR_RECEIVER | chaos::csr::RESET) != 0 {
            self.ract = false;
        }
        println!("w {k:x} {v:x} {:x}", irq(&self.i));
        self.after();
    }

    fn reset_devices(&mut self, t: u64) {
        self.look(t);
        self.i.reset();
        self.sent = None;
        self.ract = false;
        println!("x {:x}", irq(&self.i));
        self.counts[5] += 1;
        self.after();
    }

    /// A frame from the far end, if the cable is quiet and no frame of
    /// this interface's is waiting to go: the seam has no collision.
    fn frame(&mut self, t: u64, words: Vec<u16>, source: u16) -> bool {
        self.look(t);
        if self.busy.is_some() || self.last.ready.is_some() || !self.last.tdone {
            return false;
        }
        let now = self.now;
        self.i.ether_mut().expect("the cable").send_now(now, source, words);
        true
    }

    /// Another station's frame put on the cable `cells` bit cells after the
    /// last frame from the far end began, whatever is on it, so that it
    /// lands over that one: wreckage. The instant is the cable's and not on
    /// the clock, as another station's are.
    fn over(&mut self, cells: u64, words: Vec<u16>, source: u16) {
        let at = self.now + TIME.ns(cells * CELL_NS);
        self.i.advance(at);
        self.i.ether_mut().expect("the cable").send_now(at, source, words);
    }

    /// The buffer read `reads` times, each read with the bit count before
    /// it and the CSR after it, as muir's `read_round` reads the netlist
    /// board: round the buffer past the frame's end.
    fn read_round(&mut self, t: &mut u64, reads: usize) {
        for _ in 0..reads {
            for k in [0o143, 0o142, 0o140] {
                self.read(*t, k);
                *t += 100;
            }
        }
        self.counts[10] += reads as u64;
    }
}

/// A buffer of `n` words to `dest`, each numbered (muir's `numbered`).
fn numbered(n: usize, dest: u16) -> Vec<u16> {
    let mut v: Vec<u16> = (0..n - 1).map(|k| 0o100000 | k as u16).collect();
    v.push(dest);
    v
}

fn main() {
    let mut i = Interface::new(ME, Some(Ether::new()), 0, false);
    i.set_time_base(TIME);
    let last = state(&i);
    let mut s = Script {
        i,
        last,
        now: 0,
        busy: None,
        started: false,
        stored: 0,
        ract: true,
        counts: [0; 24],
        sent: None,
        sent_done: false,
    };
    let mut seed: u64 = 0x5155_000f_0140_0145;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    println!("# generated by golden/src/quux15_chaos.rs from muir's chaos::board::Interface");
    let mut t: u64 = 1_000;
    // Directed: the words at power-on, a frame in and read out, one out.
    for k in [0o140, 0o141, 0o142, 0o143, 0o144, 0o146, 0o147] {
        s.read(t, k);
        t += 400;
    }
    assert!(s.frame(t, vec![0o1234, 0o5670, ME], PEER));
    t += 30_000;
    s.read(t, 0o140);
    s.read(t + 100, 0o143);
    for j in 0..7 {
        s.read(t + 200 + 100 * j, 0o142);
        s.read(t + 250 + 100 * j, 0o143);
    }
    t += 2_000;
    s.write(t, 0o140, (chaos::csr::CLEAR_RECEIVER | chaos::csr::RECEIVE_INT_ENABLE) as u16);
    for w in [0o1111u16, 0o2222, PEER] {
        t += 300;
        s.write(t, 0o141, w);
    }
    t += 300;
    s.read(t, 0o145);
    t += 300_000;
    s.read(t, 0o140);
    // A frame read partly, the receiver cleared, and the next read from its
    // first word.
    for (k, words) in [(0, vec![0o4444, 0o5555, 0o6666, ME]), (1, vec![0o7777, 0o1010, ME])] {
        s.write(t, 0o140, chaos::csr::CLEAR_RECEIVER as u16);
        assert!(s.frame(t + 100, words, PEER), "the cable is quiet");
        t += 40_000;
        s.read(t, 0o140);
        for j in 0..(2 + k) {
            s.read(t + 100 + 100 * j, 0o142);
        }
        s.read(t + 1_000, 0o143);
        t += 2_000;
    }
    s.write(t, 0o140, chaos::csr::CLEAR_RECEIVER as u16);
    t += 300;
    // **PAST THE BUFFERS' ENDS**, the netlist board's cases in muir's
    // `tests/chaos_rtl.rs`, each read round the buffer as it reads them.
    // This interface's own frames of 253 to 258 words written, under Loop
    // Back and on the cable to its own address: 253 goes whole, 254 sends
    // nothing, 255 to 258 send 16 to 64 bits of what the wrap left, of which
    // only 258's 64 land.
    let (cr, ct) = (chaos::csr::CLEAR_RECEIVER, chaos::csr::CLEAR_TRANSMITTER);
    for back in [chaos::csr::LOOP_BACK, 0] {
        for n in 253..=258usize {
            s.write(t, 0o140, cr | ct | back);
            t += 300;
            for w in numbered(n, ME) {
                s.write(t, 0o141, w);
                t += 300;
            }
            s.read(t, 0o145);
            t += 3_000_000;
            s.read(t, 0o140);
            s.read_round(&mut t, 262);
            t += 1_000;
        }
    }
    s.write(t, 0o140, cr);
    t += 1_000;
    // Frames from another station of 256, 257 and 258 words with the source
    // and check: the buffer keeps the last 4,096 bits, so the first 256
    // words read are the frame's first, and the rest are gone.
    for n in [254, 255, 256] {
        s.write(t, 0o140, cr);
        t += 300;
        assert!(s.frame(t, numbered(n, ME), PEER), "the cable is quiet");
        t += 3_000_000;
        s.read(t, 0o140);
        s.read_round(&mut t, 262);
    }
    // Wreckage over an earlier frame of ones left unread: the first read
    // takes the partial word with zeros above its bits, and reading on gives
    // the earlier frame's ones.
    s.write(t, 0o140, cr);
    t += 300;
    let mut ones = vec![0o177777u16; 252];
    ones.push(ME);
    assert!(s.frame(t, ones, PEER), "the cable is quiet");
    t += 3_000_000;
    s.read(t, 0o140);
    s.write(t + 300, 0o140, cr);
    t += 1_000;
    let other = vec![0o1234, 0o4321, 0o17777, 0o3070];
    for (n, cells, reads) in [(12usize, 64u64, 300usize), (270, 4_105, 262)] {
        let before = s.counts[8];
        assert!(s.frame(t, numbered(n, ME), PEER), "the cable is quiet");
        s.over(cells, other.clone(), 0o3061);
        t += 3_000_000;
        s.read(t, 0o140);
        assert_eq!(s.counts[8], before + 1, "the wreckage of {n} words landed with a partial word");
        s.read_round(&mut t, reads);
        s.write(t, 0o140, cr);
        t += 1_000;
    }
    assert!(s.counts[7] >= 3, "frames over 4,096 bits: {}", s.counts[7]);
    // **A FRAME FOR ANOTHER STATION LEAVES ITS BITS, AND A COUNT-DOWN READS
    // THEM** (muir's `4647f6b`): a frame of zeros to another station, taken
    // and stored; a short one to this interface landed over part of it and
    // read round, which shows the rest; then a frame refused at its `START^`,
    // the buffer full, and the receiver cleared inside it: the reads count
    // down through the stored zeros, where the check of the bits read and
    // the check of one word alone part.
    s.write(t, 0o140, cr);
    t += 300;
    let mut zeros = vec![0u16; 252];
    zeros.push(PEER);
    assert!(s.frame(t, zeros, PEER), "the cable is quiet");
    t += 3_000_000;
    s.read(t, 0o140);
    assert!(s.frame(t, vec![0o4321, 0o1234, ME], PEER), "the cable is quiet");
    t += 100_000;
    s.read(t, 0o140);
    s.read_round(&mut t, 262);
    t += 1_000;
    assert!(s.frame(t, numbered(40, PEER), PEER), "the cable is quiet");
    t += 5_000;
    s.write(t, 0o140, cr);
    for j in 0..12 {
        s.read(t + 300 + 600 * j, 0o142);
        s.read(t + 450 + 600 * j, 0o143);
        s.read(t + 600 + 600 * j, 0o140);
    }
    t += 3_000_000;
    s.read(t, 0o140);
    s.write(t + 300, 0o140, cr);
    t += 1_000;
    assert!(s.counts[21] > 0, "no count-down read where the check of the bits read and of one word part");
    // Random: reads, writes, frames in, time.
    let mut ops = 0;
    while ops < 6000 {
        ops += 1;
        t += 100 + next() % 2_000;
        match next() % 16 {
            0..=4 => {
                let k = 0o140 + (next() % 8) as u32;
                let k = if next() % 3 == 0 { 0o142 } else { k };
                s.read(t, k);
            }
            5 => {
                // The CSR, its commands now and then; Loop Back seldom.
                let mut v = (next() & 0o67) as u16;
                if next() % 4 != 0 {
                    v &= !(chaos::csr::LOOP_BACK);
                }
                if next() % 3 == 0 {
                    v |= chaos::csr::CLEAR_RECEIVER;
                }
                if next() % 8 == 0 {
                    v |= chaos::csr::CLEAR_TRANSMITTER;
                }
                if next() % 40 == 0 {
                    v |= chaos::csr::RESET;
                }
                // **Loop Back stays as it is while a frame is anywhere**:
                // ready, going or on the line. Turned over inside one, muir's
                // receiver takes a frame by a path it did not come by --- one
                // put on the cable looked for among the frames looped back,
                // and the other way round --- which no driver does and which
                // the card's gate, set at `START^`, does not follow.
                if s.busy.is_some() || s.last.ready.is_some() || !s.last.tdone || !s.last.frames.is_empty() {
                    v = (v & !chaos::csr::LOOP_BACK) | (s.last.csr & chaos::csr::LOOP_BACK);
                }
                s.write(t, 0o140, v | (next() as u16 & 0o152200));
            }
            6 | 7 => {
                // A frame's words, now and then past the buffer's 256.
                let long = 250 + next() % 12;
                let n = if next() % 30 == 0 { long } else { 1 + next() % 8 };
                for j in 0..n {
                    let w = if j + 1 == n { [PEER, ME, 0][(next() % 3) as usize] } else { next() as u16 };
                    s.write(t + 300 * j, 0o141, w);
                }
                t += 300 * n;
            }
            8 => s.read(t, 0o145),
            9 => {
                let k = 0o142 + (next() % 6) as u32;
                s.write(t, k, next() as u16);
            }
            10 | 11 => {
                // A frame from the far end: to this interface, a broadcast,
                // or another station's.
                let n = 1 + next() % 6;
                let mut w: Vec<u16> = (0..n).map(|_| next() as u16).collect();
                w.push([ME, 0, PEER][(next() % 3) as usize]);
                if s.frame(t, w, if next() % 2 == 0 { PEER } else { 0o37001 }) {
                    t += 15_000 + next() % 40_000;
                }
            }
            12 => t += next() % 300_000,
            13 => {
                if next() % 6 == 0 {
                    s.reset_devices(t);
                } else {
                    s.read(t, 0o140);
                }
            }
            _ => {
                // A frame read out whole.
                s.read(t, 0o140);
                for j in 0..(4 + next() % 8) {
                    s.read(t + 100 + 100 * j, if j % 3 == 2 { 0o143 } else { 0o142 });
                }
                t += 2_000;
            }
        }
    }
    s.look(t + 400_000);
    let c = s.counts;
    eprintln!(
        "quux15_chaos: {ops} operations: {} frames in, {} lost, {} Transmit Dones, {} STARTs, {} nonzero buffer reads, \
         {} RESET-DEVICES, {} runs of 48 bits or fewer handed back, {} frames over 4,096 bits, {} with a partial word, \
         {} STARTs sending nothing, {} reads round the buffer, {} frames stored and not landed, {} looks moved past an \
         abort, {} frames on the line, {} START^s, {} stored levels, {} buffer reads moved off a frame taken, {} reads \
         inside a frame, {} aborts after Transmit Done, {} buffer reads counting down inside a frame not taken, {} frames \
         dropped",
        c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12], c[13], c[14], c[15], c[16], c[17], c[18],
        c[19], c[20]
    );
    assert!(c[6] > 0 && c[9] > 0, "the script reached no run or no empty START");
    assert!(
        c[11] > 0 && c[14] > 0 && c[15] > 0 && c[17] > 0 && c[19] > 0 && c[20] > 0,
        "the script reached no stored frame, START^, stored level, read inside a frame, count-down or drop"
    );
}
