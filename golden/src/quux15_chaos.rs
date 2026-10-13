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
//! f BITS CRC N WORDS IRQ  the far end put a frame in the buffer: its words,
//!                         the source and the check word last
//! l IRQ                   the far end counted a frame lost
//! d ABORT IRQ             the far end says the frame is away
//! b LEVEL                 the cable is busy, or not, from here
//! s N WORDS               the frame the last START sent
//! ```
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
            Some(r.u16s()?)
        } else {
            None
        };
        Ok(Seen { rdone, tdone, tabort, crc, lost, busy, xmit, rcv, bits, ready })
    };
    let s = parse(&mut r).expect("the interface's checkpoint");
    assert_eq!(i.csr() & 0o40000 != 0, s.crc || s.busy, "the CSR's bit 14 as its two halves");
    s
}

fn irq(i: &Interface) -> u8 {
    i.interrupt_request().is_some() as u8
}

struct Script {
    i: Interface,
    last: Seen,
    now: u64,
    busy: bool,
    counts: [u64; 8],
    /// Until when a frame of more than 254 words this interface started
    /// may still be on the cable or landing: Spy and Loop Back are not set
    /// before then (see [`Script::read`]).
    long_until: u64,
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
            assert!(s.rcv.len() <= 256, "a frame longer than the buffer, which the seam refuses");
            let w: Vec<String> = s.rcv.iter().map(|w| format!("{w:x}")).collect();
            println!("f {:x} {:x} {:x} {} {:x}", s.bits, s.crc as u8, s.rcv.len(), w.join(" "), irq_of(true, a.tdone));
            self.counts[0] += 1;
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
        } else {
            assert_eq!(a.tabort, s.tabort, "Transmit Abort moved apart from Transmit Done");
        }
        self.last = s;
    }

    fn read(&mut self, t: u64, k: u32) {
        self.look(t);
        // **A FRAME THAT WOULD COME BACK LONGER THAN THE RECEIVE BUFFER IS
        // NOT STARTED.** Under Loop Back, and since muir's `792653c` also
        // off the cable when it is for this interface --- to its address,
        // to 0, or under Spy (DEST MATCH on the netlist board) --- the frame
        // comes back with its source and check word, so more than 254 words
        // would land as more than the buffer's 256, which the seam refuses.
        // The read is left out of the script.
        if k == 0o145 {
            let csr = self.i.csr();
            let x = &self.last.xmit;
            let back = csr & (chaos::csr::LOOP_BACK | chaos::csr::SPY) != 0
                || matches!(x.last(), Some(&ME) | Some(&0));
            if x.len() > 254 {
                if back {
                    self.counts[6] += 1;
                    return;
                }
                // Its frame takes about 1.1 ms and waits at most a round of
                // the turn timer: 3 ms is past its landing.
                self.long_until = t + 3_000_000;
            }
        }
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
        println!("w {k:x} {v:x} {:x}", irq(&self.i));
        self.last = seen(&self.i, self.now);
    }

    fn reset_devices(&mut self, t: u64) {
        self.look(t);
        self.i.reset();
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
}

fn main() {
    let mut s = Script {
        i: Interface::new(ME, Some(Ether::new()), 0, false),
        last: Seen { tdone: true, ..Seen::default() },
        now: 0,
        busy: false,
        counts: [0; 8],
        long_until: 0,
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
                // Not while a long frame of this interface's may still
                // land: it would come back past the buffer's 256 words.
                if t < s.long_until {
                    v &= !(chaos::csr::LOOP_BACK | chaos::csr::SPY);
                }
                s.write(t, 0o140, v | (next() as u16 & 0o152200));
            }
            6 | 7 => {
                // A frame's words, now and then past the buffer's 256.
                // Under Loop Back the frame comes back with its source and
                // check word, so at most 254 words fit the buffer; a frame
                // that comes back longer is not started (`Script::read`).
                let long = if s.i.csr() & chaos::csr::LOOP_BACK != 0 { 250 + next() % 5 } else { 250 + next() % 12 };
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
        "quux15_chaos: {ops} operations: {} frames in, {} lost, {} Transmit Dones, {} STARTs, {} nonzero buffer reads, {} RESET-DEVICES, {} STARTs left out",
        s.counts[0], s.counts[1], s.counts[2], s.counts[3], s.counts[4], s.counts[5], s.counts[6]
    );
}
