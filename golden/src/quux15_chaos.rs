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
//! l IRQ                   the far end counted a frame lost
//! d ABORT IRQ             the far end says the frame is away
//! b LEVEL                 the cable is busy, or not, from here
//! s N WORDS               the frame the last START sent, as its transmit
//!                         buffer plays it out: the words, the source and
//!                         the check word, or what a buffer written past its
//!                         end leaves (muir's `packet::line`)
//! ```
//!
//! **BOTH BUFFERS GO ROUND** (muir's `ebb3c41`, measured on the netlist
//! board). Words written past the 256th go over the first, so the frame a
//! START sends is `(16n + 32) mod 4096` bits for `n` words written, nothing
//! at all for 254; a frame longer than the receive buffer leaves its last
//! 4,096 bits, the ones the software reads first; reads go on round the
//! buffer; and CRC Error from the first read on is the check of the words
//! read. A run of 48 bits or fewer is taken by no receiver: every frame of
//! 1 to 3 words this interface sends is handed back to it as an `f` line
//! after its Transmit Done, and the interface must take none of them.
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

use muir::chaos::board::Interface;
use muir::chaos::ether::Ether;
use muir::chaos::interface as chaos;
use muir::chaos::packet::check_word;
use muir::chaos::wire::CELL_NS;

const ME: u16 = 0o177001;
const PEER: u16 = 0o3040;

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

/// What the far end sees of the interface (`quux15_network.rs`'s `Seen`).
#[derive(Clone, Debug, Default, PartialEq)]
struct Seen {
    rdone: bool,
    tdone: bool,
    tabort: bool,
    crc: bool,
    lost: u8,
    busy: bool,
    xmit: Vec<u16>,
    rcv: Vec<u16>,
    bits: u64,
    ready: Option<Vec<u16>>,
}

/// The interface as of `t`, the instant it was last taken to: its cable
/// busy as its `csr()` reckons it, from the frames its turn timer keeps
/// (`Turn::busy_at`), so that the bit's two halves are apart.
fn seen(i: &Interface, t: u64) -> Seen {
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
        let xmit = r.u16s()?;
        // The incoming buffer whole, its 256 words in the order the frame
        // in it is read, or empty while never written.
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
        let mut busy = false;
        for _ in 0..r.u64()? {
            let s = r.u64()?;
            r.u16()?;
            let e = r.u64()?;
            busy |= s <= t && t < e + muir::chaos::board::CBLBSY_OFF_NS;
        }
        let ready = if r.bool()? {
            r.u64()?;
            Some(line_of(r.u16s()?))
        } else {
            None
        };
        Ok(Seen { rdone, tdone, tabort, crc, lost, busy, xmit, rcv, bits, ready })
    };
    let s = parse(&mut r).expect("the interface's checkpoint");
    assert_eq!(i.csr() & 0o40000 != 0, s.crc || s.busy, "the CSR's bit 14 as its two halves");
    s
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

/// A word the far end hands the card past the 256th: one the card must not
/// keep, the buffer holding newer bits there.  Distinct for every place, so
/// that a card which stored one would read back something muir never has.
fn stand_in(k: usize) -> u16 {
    0o155000 ^ (k as u16).wrapping_mul(0o4321)
}

/// **THE FRAME AS THE FAR END HANDS IT TO THE CARD**, a word a clock in the
/// order the software reads them, `bits` with every word: muir's buffer
/// after the frame landed, `rcv`, cut to the frame's `ceil(bits / 16)`
/// words.  The first word, partial when `bits` is not a whole number of
/// words, comes with zeros above its bits, as a receiver hands it over; the
/// bits above them in the buffer are what was there before, which the card
/// keeps and the first read does not show.  Past the 256th word the frame's
/// bits are gone from the buffer, a frame coming check word first: the
/// 257th shares the first word's place, and its bits above the partial word
/// are muir's (`rcv[0]`'s) and the rest a stand-in, and every word after
/// it is a stand-in the card must drop.
fn handed(rcv: &[u16], bits: u64) -> Vec<u16> {
    assert_eq!(rcv.len(), 256, "a frame landed and the buffer is not whole");
    let n = bits.div_ceil(16) as usize;
    let low = u16::MAX >> ((16 - bits % 16) % 16);
    (0..n)
        .map(|k| match k {
            0 => rcv[0] & low,
            1..=255 => rcv[k],
            256 => (rcv[0] & !low) | (stand_in(k) & low),
            _ => stand_in(k),
        })
        .collect()
}

fn irq(i: &Interface) -> u8 {
    i.interrupt_request().is_some() as u8
}

struct Script {
    i: Interface,
    last: Seen,
    now: u64,
    busy: bool,
    counts: [u64; 12],
    /// The frame the last START sent, until its Transmit Done.
    sent: Option<Vec<u16>>,
}

impl Script {
    /// The interface at `t`: what its cable did since the last look.
    fn look(&mut self, t: u64) {
        self.i.advance(t);
        self.now = t;
        let s = seen(&self.i, t);
        let a = self.last.clone();
        assert!(!(a.rdone && !s.rdone) && !(a.tdone && !s.tdone), "Receive or Transmit Done fell by itself");
        if s.busy != self.busy {
            self.busy = s.busy;
            println!("b {:x}", s.busy as u8);
        }
        // The interrupt after each line, the lines in this order: the
        // frame in, the losses, Transmit Done.
        let csr = self.i.csr();
        let (rie, tie) = (csr & chaos::csr::RECEIVE_INT_ENABLE != 0, csr & chaos::csr::TRANSMIT_INT_ENABLE != 0);
        let irq_of = |rdone: bool, tdone: bool| ((rdone && rie) || (tdone && tie)) as u8;
        if !a.rdone && s.rdone {
            assert!(s.bits > 48, "a run of 48 bits or fewer landed");
            let h = handed(&s.rcv, s.bits);
            let w: Vec<String> = h.iter().map(|w| format!("{w:x}")).collect();
            println!("f {:x} {:x} {:x} {} {:x}", s.bits, s.crc as u8, h.len(), w.join(" "), irq_of(true, a.tdone));
            self.counts[0] += 1;
            if s.bits > 4_096 {
                self.counts[7] += 1;
            }
            if s.bits % 16 != 0 {
                self.counts[8] += 1;
            }
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
            // **A RUN OF 48 BITS OR FEWER IS TAKEN BY NO RECEIVER**, the
            // check, source and destination words and nothing after them
            // (muir's `Interface::arrive`, measured on the netlist board).
            // The far end hands the card this interface's own such run as
            // it would a frame, and the card must take none of it: no
            // Receive Done, no Lost Count, nothing a read shows.  muir's
            // interface is unchanged by it, which the line's interrupt and
            // every later read hold.
            if let Some(line) = self.sent.take().filter(|l| (1..=3).contains(&l.len())) {
                let w: Vec<String> = line.iter().map(|w| format!("{w:x}")).collect();
                println!("f {:x} 0 {:x} {} {:x}", line.len() * 16, line.len(), w.join(" "), irq(&self.i));
                self.counts[6] += 1;
            }
        } else {
            assert_eq!(a.tabort, s.tabort, "Transmit Abort moved apart from Transmit Done");
        }
        self.last = s;
    }

    fn read(&mut self, t: u64, k: u32) {
        self.look(t);
        let v = match register(k, false) {
            Some(r) => self.i.read(r, t),
            None => 0,
        };
        println!("r {k:x} {v:x} {:x}", irq(&self.i));
        if k == 0o145 {
            let s = seen(&self.i, self.now);
            let w = s.ready.clone().expect("START made a frame ready");
            let ws: Vec<String> = w.iter().map(|w| format!("{w:x}")).collect();
            println!("s {:x} {}", w.len(), ws.join(" "));
            self.counts[3] += 1;
            if w.is_empty() {
                self.counts[9] += 1;
            }
            self.sent = Some(w);
        }
        if k == 0o142 && v != 0 {
            self.counts[4] += 1;
        }
        self.last = seen(&self.i, self.now);
    }

    fn write(&mut self, t: u64, k: u32, v: u16) {
        self.look(t);
        if let Some(r) = register(k, true) {
            self.i.write(r, v, t);
        }
        if k == 0o140 && v & (chaos::csr::CLEAR_TRANSMITTER | chaos::csr::RESET) != 0 {
            self.sent = None;
        }
        println!("w {k:x} {v:x} {:x}", irq(&self.i));
        self.last = seen(&self.i, self.now);
    }

    fn reset_devices(&mut self, t: u64) {
        self.look(t);
        self.i.reset();
        self.sent = None;
        println!("x {:x}", irq(&self.i));
        self.counts[5] += 1;
        self.last = seen(&self.i, self.now);
    }

    /// A frame from the far end, if the cable is quiet and no frame of
    /// this interface's is waiting to go: the seam has no collision.
    fn frame(&mut self, t: u64, words: Vec<u16>, source: u16) -> bool {
        self.look(t);
        if self.last.busy || self.last.ready.is_some() || !self.last.tdone {
            return false;
        }
        self.i.ether_mut().expect("the cable").send_now(t, source, words);
        true
    }

    /// Another station's frame put on the cable at `t` whatever is on it,
    /// so that it lands over a frame already going: wreckage.
    fn over(&mut self, t: u64, words: Vec<u16>, source: u16) {
        self.look(t);
        self.i.ether_mut().expect("the cable").send_now(t, source, words);
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
    let mut s = Script {
        i: Interface::new(ME, Some(Ether::new()), 0, false),
        last: Seen { tdone: true, ..Seen::default() },
        now: 0,
        busy: false,
        counts: [0; 12],
        sent: None,
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
        s.over(t + cells * CELL_NS, other.clone(), 0o3061);
        t += 3_000_000;
        s.read(t, 0o140);
        assert_eq!(s.counts[8], before + 1, "the wreckage of {n} words landed with a partial word");
        s.read_round(&mut t, reads);
        s.write(t, 0o140, cr);
        t += 1_000;
    }
    assert!(s.counts[7] >= 3, "frames over 4,096 bits: {}", s.counts[7]);
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
    eprintln!(
        "quux15_chaos: {ops} operations: {} frames in, {} lost, {} Transmit Dones, {} STARTs, {} nonzero buffer reads, {} RESET-DEVICES, {} runs of 48 bits or fewer handed back, {} frames over 4,096 bits, {} with a partial word, {} STARTs sending nothing, {} reads round the buffer",
        s.counts[0], s.counts[1], s.counts[2], s.counts[3], s.counts[4], s.counts[5], s.counts[6], s.counts[7], s.counts[8], s.counts[9], s.counts[10]
    );
    assert!(s.counts[6] > 0 && s.counts[9] > 0, "the script reached no run or no empty START");
}
