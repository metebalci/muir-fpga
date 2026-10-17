// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **QUUX revision 16's Ethernet device, its machine's side** (QUUX's
//! Ethernet contract, §2.2, §2.3, §2.7), as muir's own
//! `ethernet_device::EthernetDevice` answers a script of the processor's
//! register writes and of Ethernet frames arriving, for
//! `tb/quux16_ethernet_tb.cpp` to hold `rtl/machine/quux16_ethernet.sv` to,
//! through `rtl/machine/quux15_devices.sv` and `rtl/plumbing/quux_ed_face.sv`.
//!
//! **WHAT muir's DEVICE DOES WITH A FRAME IS THE BOARD PROGRAM'S**: it reads
//! the entries and the frames, sends, writes the buffers and checks §2.4, and
//! moves 245 and 251 and the four counters through the face.  So after each
//! operation muir's device is advanced 10 ms, every transmit posted sent and
//! every frame arrived delivered or dropped, and what it moved is written
//! down as the host's moves, which the testbench makes through the face as
//! `quux-ethernet-device`'s `qed_face_fabric.c` makes them.  Then every
//! register 240-257 as muir reads it.  The trace:
//!
//! ```text
//! # memory N                  main memory's words, the harness's MAIN_WORDS
//! w K V                       the processor writes word 240 + K (K octal), V
//!                             hex; 244 and 250 come as the core's held write
//! reset                       RESET-DEVICES
//! host H L A M G              the host writes 253-257 (hex)
//! counts C                    the host's COUNTS, 241's counters in their places
//! tx I                        the host moves 245 to I under the epoch
//! rx I                        the host moves 251 to I under the epoch, one
//!                             delivery: the cache made coherent
//! = W0 ... W15                240-257 as muir reads them now (hex)
//! ```
//!
//! The scripts: the rules one by one (`rules`), each with the case just
//! outside it --- the configuration and its refusal at the enable for a base
//! off a line, a size over 8 and a ring one line past main memory, the
//! indexes reading 0 while disabled, every index fault, the wraps at rings
//! of 1, 2 and 256 entries and across 2^16, a full receive ring, each
//! counter past its width, the interrupt enable and status `<8>`, the
//! disable and RESET-DEVICES; and programs at random (`random`), which keep
//! no rule, among rings whose entries are good, off a line, past main
//! memory and too short.

use muir::clock::TimeBase;
use muir::ethernet_device::{EthernetDevice, Host, Script};

/// Revision 16's time base: units of 0.5 ns, at muir's default period.
const TIME: TimeBase = TimeBase::half_ns(muir::clock::PERIOD_15);
/// From one operation to the next, in units: 10 ms, so that every transmit
/// posted, 20 us an entry and at most 256 of them, is sent before the next.
const STEP: u64 = 20_000_000;
/// Main memory's words: small enough that a ring of 256 entries reaches its
/// end from half way.
pub const WORDS: usize = 4096;

/// A frame each kind: ARP, which the type filter takes; IPv6, which it
/// drops; an IPv4 header with a bad checksum, which the IPv4 checks drop.
fn frame(kind: u64, len: usize, to_me: bool) -> Vec<u8> {
    let mut f = vec![0u8; len.max(14)];
    let dst: [u8; 6] = if to_me { Host::default().mac } else { [0xff; 6] };
    f[..6].copy_from_slice(&dst);
    f[6..12].copy_from_slice(&[0x02, 0, 0, 0, 0, 0x02]);
    match kind {
        0 => f[12..14].copy_from_slice(&[0x08, 0x06]),
        1 => f[12..14].copy_from_slice(&[0x86, 0xdd]),
        _ => {
            f[12..14].copy_from_slice(&[0x08, 0x00]);
            if f.len() >= 34 {
                f[14] = 0x45;
                let total = (f.len() - 14) as u16;
                f[16..18].copy_from_slice(&total.to_be_bytes());
                f[22] = 64;
                f[23] = 17;
                f[24..26].copy_from_slice(&[0xde, 0xad]);
            }
        }
    }
    for (k, b) in f.iter_mut().enumerate().skip(34) {
        *b = (k * 7) as u8;
    }
    f.truncate(len);
    f
}

/// muir's device and its host side, run as the script goes.
struct Run {
    d: EthernetDevice,
    main: Vec<u64>,
    peer: Script,
    now: u64,
    out: Vec<String>,
    /// What the host last moved: 245, 251 and the counters.
    tx: u16,
    rx: u16,
    counts: u32,
}

const COUNTS_MASK: u32 = 0xFFFF_FEF0;

impl Run {
    fn new() -> Run {
        let mut d = EthernetDevice::new();
        let peer = Script::default();
        d.attach(Box::new(peer.clone()));
        let mut main = vec![0u64; WORDS];
        // Every line an entry either ring may name: a buffer or a frame at
        // 3072 of 64 bytes; a few off a line, past main memory or short.
        for l in 0..WORDS / 8 {
            let (addr, len) = match l % 37 {
                5 => (3073, 64),
                11 => (4090, 64),
                17 => (3072, 20),
                23 => (3072, 10),
                29 => (3072, 1600),
                _ => (3072, 64),
            };
            main[8 * l] = 0o005 << 32 | addr;
            main[8 * l + 1] = 0o005 << 32 | len;
        }
        // An ARP frame to send, in the file device's byte order.
        let f = frame(0, 64, false);
        for (k, c) in f.chunks(4).enumerate() {
            let mut w = [0u8; 4];
            w[..c.len()].copy_from_slice(c);
            main[3072 + k] = u64::from(u32::from_le_bytes(w));
        }
        Run { d, main, peer, now: 0, out: vec![format!("# memory {WORDS}")], tx: 0, rx: 0, counts: 0 }
    }

    /// The device advanced to the next operation's time: what it moved is
    /// the host's moves, then every register.
    fn settle(&mut self) {
        self.now += STEP;
        self.d.advance(self.now, &mut self.main, TIME);
        let on = self.d.enabled();
        let counts = self.d.read(0o241) & COUNTS_MASK;
        if counts != self.counts {
            self.out.push(format!("counts {counts:x}"));
            self.counts = counts;
        }
        let (tx, rx) = (self.d.read(0o245) as u16, self.d.read(0o251) as u16);
        if on && tx != self.tx {
            self.out.push(format!("tx {tx:x}"));
        }
        if on {
            // One move a delivery, as the program makes them.
            let mut r = self.rx;
            while r != rx {
                r = r.wrapping_add(1);
                self.out.push(format!("rx {r:x}"));
            }
        }
        self.tx = tx;
        self.rx = rx;
        let words: Vec<String> = (0o240..=0o257).map(|k| format!("{:x}", self.d.read(k))).collect();
        self.out.push(format!("= {}", words.join(" ")));
    }

    fn write(&mut self, k: u32, v: u32) {
        self.out.push(format!("w {:o} {v:x}", k - 0o240));
        self.d.write(k, v, self.now, TIME, &self.main);
        self.settle();
    }

    fn reset(&mut self) {
        self.out.push("reset".to_string());
        self.d.reset();
        self.settle();
    }

    fn host(&mut self, h: Host) {
        self.d.host = h;
        let m = h.mac;
        self.out.push(format!(
            "host {:x} {:x} {:x} {:x} {:x}",
            u32::from_be_bytes([0, 0, m[0], m[1]]),
            u32::from_be_bytes([m[2], m[3], m[4], m[5]]),
            h.address,
            h.netmask,
            h.gateway
        ));
        self.settle();
    }

    /// Frames arriving now, each delivered or dropped in the 10 ms after.
    fn arrive(&mut self, frames: &[Vec<u8>]) {
        for f in frames {
            self.peer.arrive(self.now + 1, f.clone());
        }
        self.settle();
    }
}

/// **The rules, one by one.**
fn rules() -> Vec<String> {
    let mut r = Run::new();
    // Power-on: every word, 253-257 at muir's defaults.
    r.settle();
    // The rings written while disabled and read back, the bases to 28 bits
    // and the sizes to 4; the enable refused for a base off a line, a size
    // over 8, a ring one line past main memory; a write of 240 clearing the
    // refusal; the enable taken at a ring reaching exactly to the end.
    r.write(0o242, 0xFFFF_FFF8);
    r.write(0o243, 0xFFFF_FFFF);
    r.write(0o246, 0x1234_5679);
    r.write(0o247, 0x13);
    for (tb, tl, rb, rl) in [
        (0, 0, 1, 0),
        (4, 0, 0, 0),
        (0, 9, 0, 0),
        (0, 0, 0, 9),
        (2048 + 8, 8, 0, 0),
        (0, 0, 4096 - 8 * 255, 8),
        (0, 0, 4096 - 8, 0),
    ] {
        r.write(0o242, tb);
        r.write(0o243, tl);
        r.write(0o246, rb);
        r.write(0o247, rl);
        r.write(0o240, 1 | 1 << 8);
        r.write(0o240, 0);
    }
    r.write(0o242, 2048);
    r.write(0o243, 8);
    r.write(0o246, 0);
    r.write(0o247, 0);
    r.write(0o240, 1);
    // While enabled: the bases and sizes go nowhere; the interrupt enable
    // set and cleared by a write that keeps the enable.
    r.write(0o242, 8);
    r.write(0o247, 3);
    r.write(0o240, 1 | 1 << 8);
    r.write(0o240, 1);
    // A receive ring of one: a buffer given, a second refused (the fault),
    // a frame delivered, 252 past 251 refused, 252 taken; status <8> and
    // the interrupt enable; a frame with no buffer counted.
    r.write(0o250, 1);
    r.write(0o250, 2);
    r.write(0o240, 1 | 1 << 8);
    r.arrive(&[frame(0, 42, true)]);
    r.write(0o252, 2);
    r.write(0o252, 1);
    r.arrive(&[frame(0, 42, true)]);
    r.write(0o250, 0);
    r.write(0o244, 0);
    // The transmit ring of 256: one posted and sent, then 256, then one
    // more than the ring (the fault), then a write moving 244 backwards.
    r.write(0o244, 1);
    r.write(0o244, 257);
    r.write(0o244, 258);
    r.write(0o244, 256);
    r.write(0o244, 257);
    // A disable: the indexes and the interrupt enable to 0, the bases and
    // sizes kept, every index write going nowhere; then RESET-DEVICES with
    // the faults up.
    r.write(0o240, 0);
    r.write(0o244, 1);
    r.write(0o250, 1);
    r.write(0o252, 1);
    r.write(0o240, 1);
    r.write(0o244, 0xFFFF);
    r.reset();
    // The writes of the read-only words go nowhere.
    for k in [0o241, 0o245, 0o251, 0o253, 0o254, 0o255, 0o256, 0o257] {
        r.write(k, 0xFFFF_FFFF);
    }
    // A receive ring of two across 2^16: given and taken around the top,
    // frames of each kind, each counter past its width, the ring full.
    r.write(0o242, 0);
    r.write(0o243, 1);
    r.write(0o246, 64);
    r.write(0o247, 1);
    r.write(0o240, 1 | 1 << 8);
    // Started near the top, so that the indexes cross 2^16.
    let mut taken = 0u32;
    for round in 0..40u32 {
        let given = (r.d.read(0o252) + 2) & 0xFFFF;
        r.write(0o250, given);
        let mut f = vec![frame(round as u64 % 3, 42 + (round as usize % 30), round % 4 != 0)];
        f.push(frame(0, 42 + round as usize % 20, true));
        if round % 5 == 0 {
            f.push(frame(0, 60, true));
            f.push(frame(0, 60, true));
        }
        r.arrive(&f);
        let cons = r.d.read(0o251);
        taken = cons.max(taken);
        // Taken back, all but one now and then, so the ring fills.
        r.write(0o252, if round % 3 == 2 { cons.wrapping_sub(1) & 0xFFFF } else { cons });
        // A transmit that is refused, for its counter: length 10.
        if round % 2 == 0 {
            let t = r.d.read(0o244);
            r.write(0o244, (t + 1) & 0xFFFF);
        }
    }
    let _ = taken;
    // The receive side across 2^16: a ring of 64 good entries at 2048, its
    // buffers given, filled and taken back 1,025 times over, 250, 251 and
    // 252 each crossing the top.
    for l in 256..320 {
        r.main[8 * l] = 0o005 << 32 | 3072;
        r.main[8 * l + 1] = 0o005 << 32 | 64;
    }
    r.write(0o240, 0);
    r.write(0o246, 2048);
    r.write(0o247, 6);
    r.write(0o240, 1);
    for _ in 0..1025 {
        let given = (r.d.read(0o252) + 64) & 0xFFFF;
        r.write(0o250, given);
        let f: Vec<Vec<u8>> = (0..64).map(|_| frame(0, 42, true)).collect();
        r.arrive(&f);
        let cons = r.d.read(0o251);
        r.write(0o252, cons);
    }
    // Each counter past its width: with no buffer given (a disable puts the
    // indexes at 0), 300 frames each of IPv6 (the type filter, mod 16), of
    // IPv4 with a bad header checksum (the IPv4 checks, mod 128) and of ARP
    // (no buffer, mod 256).
    r.write(0o240, 0);
    r.write(0o240, 1);
    for kind in [1, 2, 0] {
        for _ in 0..10 {
            let f: Vec<Vec<u8>> = (0..30).map(|k| frame(kind, 42 + k, true)).collect();
            r.arrive(&f);
        }
    }
    // Across 2^16 on the transmit side: 245 walked to the top by whole rings.
    r.write(0o240, 0);
    r.write(0o242, 0);
    r.write(0o243, 8);
    r.write(0o240, 1);
    let mut p = 0u32;
    while p < 0x1_0100 {
        p += 256;
        r.write(0o244, p & 0xFFFF);
    }
    r.write(0o244, (p + 1) & 0xFFFF);
    r.write(0o244, (p + 0x101) & 0xFFFF);
    // 253-257 the host's.
    r.host(Host { mac: [0x02, 0x11, 0x22, 0x33, 0x44, 0x55], address: 0xA9FE_6502, netmask: 0xFFFF_FFFC, gateway: 0xA9FE_6501 });
    r.arrive(&[frame(0, 42, true), frame(0, 42, false)]);
    r.out
}

/// **Programs at random**: xorshift64* for the choices.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0.max(1);
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 16
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn random(seed: u64, ops: usize) -> Vec<String> {
    let mut g = Rng(seed);
    let mut r = Run::new();
    r.settle();
    for _ in 0..ops {
        let near = |g: &mut Rng, v: u32| -> u32 {
            match g.below(4) {
                0 => g.below(0x1_0000) as u32,
                1 => v.wrapping_sub(g.below(3) as u32) & 0xFFFF,
                _ => v.wrapping_add(g.below(4) as u32) & 0xFFFF,
            }
        };
        match g.below(16) {
            0 => {
                let v = (g.below(2) | g.below(2) << 8) as u32;
                r.write(0o240, v);
            }
            1 => {
                let k = [0o242, 0o243, 0o246, 0o247][g.below(4) as usize];
                let v = if k & 1 == 0 { (8 * g.below(512) + g.below(8) * (g.below(4) / 3)) as u32 } else { g.below(10) as u32 };
                r.write(k, v);
            }
            2..=4 => {
                let v = near(&mut g, r.d.read(0o244));
                r.write(0o244, v);
            }
            5..=7 => {
                let v = near(&mut g, r.d.read(0o250));
                r.write(0o250, v);
            }
            8..=10 => {
                let v = near(&mut g, r.d.read(0o251));
                r.write(0o252, v);
            }
            11..=13 => {
                let n = g.below(4) as usize;
                let f: Vec<Vec<u8>> = (0..n)
                    .map(|_| {
                        let kind = if g.below(3) == 0 { g.below(3) } else { 0 };
                        frame(kind, 30 + g.below(50) as usize, g.below(5) != 0)
                    })
                    .collect();
                r.arrive(&f);
            }
            14 => r.reset(),
            _ => {
                let k = 0o240 + g.below(16) as u32;
                let v = g.next() as u32;
                r.write(k, v);
            }
        }
    }
    r.out
}

fn main() {
    let which = std::env::args().nth(1).unwrap_or_default();
    let lines = match which.as_str() {
        "rules" => rules(),
        "random" => {
            let mut v = Vec::new();
            for seed in 1..=8 {
                v.push(format!("# seed {seed}"));
                v.extend(random(seed, 1500));
            }
            v
        }
        _ => {
            eprintln!("usage: quux16_ethernet rules|random");
            std::process::exit(2);
        }
    };
    println!("# generated by golden/src/quux16_ethernet.rs from muir's EthernetDevice: {which}");
    for l in lines {
        println!("{l}");
    }
}
