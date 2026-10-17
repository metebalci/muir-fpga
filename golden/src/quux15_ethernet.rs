// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 16's Ethernet device on the core** (QUUX's Ethernet contract,
//! §2, §10): runs of `golden/src/quux15.rs`'s kind on muir's pipeline at
//! revision 16 (`--revision 16`), with Ethernet frames arriving from a
//! scripted host side, muir's `ethernet_device::Script`, and the host's
//! side of what muir's device did written down for the testbench, which
//! plays `quux-ethernet-device` on the core's Ethernet host side.
//!
//!   registers  MACHINE-ID and feature word 15; every word 240-257 at
//!              power-on, 253-257 at muir's defaults; the rings written while
//!              disabled; the enable refused for a base off a line and a size
//!              over 8; a size written while enabled going nowhere; 244 past
//!              the ring, 250 past the ring and 252 past 251, each a fault; a
//!              write of 240 clearing them; a disable, the indexes reading 0;
//!              RESET-DEVICES; word 100 with nothing waiting
//!   transmit   two entries posted behind a write the port answers in 25 us,
//!              244 waiting for it (§2.5); one sent, one refused for its
//!              length, 245 passing both 20 us apart and the refusal counted
//!   receive    three buffers given, the first's line read before, so that
//!              the cache holds it; an ARP frame delivered, its line read
//!              again after the sweep, its length, status <8> and word 100
//!              <8> under the interrupt enable, 252 taking it back; a second
//!              delivered; an IPv6 frame dropped by the type filter, an IPv4
//!              frame by the IPv4 checks and one too long for its buffer
//!              dropped, each counted
//!   held       244 held behind a slow write, a second 244 replacing it, 250
//!              waiting behind it, and CMD_PROD's 164 held before another 244,
//!              the file device enabled beside the Ethernet device
//!   irq        a frame arriving under the interrupt enable with interrupts
//!              on: condition 5 calling the handler, which takes the entry
//!              back and lowers the level
//!   hostwords  253-257 other than muir's defaults, read, and a frame to
//!              that MAC address delivered; the checkpoints group at
//!              revision 16 halts each of these runs at points across it
//!
//! **WHAT THE TESTBENCH IS TOLD IS WHAT muir's DEVICE DID, BY CLOCK**, each
//! `<clock>` the first after the tick whose machine has it, as the file
//! device's host is recorded (`golden/src/quux15.rs`'s `FileHost`):
//!
//!   # edprod <clock> <244> <250>   244 and 250 as the host's side reads them
//!                                  from that clock: the testbench holds the
//!                                  core's `eth_tx_prod` and `eth_rx_prod`
//!                                  to them at every clock
//!   # edtx <clock> <index>         245 moved: TX_CONS written in the clock
//!                                  before
//!   # edrx <clock> <index>         251 moved by one, a delivery: RX_CONS
//!                                  written in the clock before
//!   # edword <clock> <addr> <word> a word the delivery wrote, put into main
//!                                  memory at that clock, before anything
//!                                  reads it
//!   # edcounts <clock> <counts>    241's counters: COUNTS written at that
//!                                  clock, which lands at its edge
//!   # edhost <253> ... <257>       253-257 when not muir's defaults: written
//!                                  through the host's side while the
//!                                  machine is held in its reset
//!
//! `micro` is not run: what a run ends with depends on the device's
//! instants, which `micro` keeps otherwise.

use muir::engine::Engine;
use muir::ethernet_device::{Host, RX_BASE, RX_CONS, RX_PROD, RX_SIZE, STATUS, Script, TX_CONS, TX_PROD};
use muir::isa::asm::{
    ADD, ALU, JUMP, N, P, POPJ, SETA, START_READ, SUB, a_src, filler, m_dest, m_src, target,
};
use muir::machine::Word;
use muir::pipeline::{Pipeline, PortTiming};

use super::Case;
use super::quux15_preset::Preset;

/// The register page's virtual address, and the physical memory window.
const REGISTER_PAGE: Word = 0o35777777400;
const PHYS: Word = 0o36000000000;
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
/// The handler a check calls.
const HANDLER: u64 = 0o700;

/// The rings, the frames and the buffers, each on a line.
const TX_RING: u64 = 0o4000;
const RX_RING: u64 = 0o4100;
const FRAME: u64 = 0o6000;
const BUF0: u64 = 0o10000;
const BUF1: u64 = 0o12000;
const BUF2: u64 = 0o14000;

/// 241's counters' places.
const COUNTS_MASK: u32 = 0xFFFF_FEF0;

/// The frames that arrive, each at a clock: the instant `clock` times the
/// period.
#[derive(Clone, Debug, Default)]
pub struct EthRun {
    pub frames: Vec<(u64, Vec<u8>)>,
    /// 253-257 when not muir's defaults: the host's flags, which the
    /// testbench writes through the host's side in the run's first clocks.
    pub host: Option<Host>,
}

/// An Ethernet frame: ARP or IPv6 (`kind`), `len` bytes, to the device's
/// MAC address.
fn frame(ipv6: bool, len: usize) -> Vec<u8> {
    let mut f = vec![0u8; len];
    f[..6].copy_from_slice(&muir::ethernet_device::Host::default().mac);
    f[6..12].copy_from_slice(&[0x02, 0, 0, 0, 0, 0x02]);
    f[12..14].copy_from_slice(if ipv6 { &[0x86, 0xdd] } else { &[0x08, 0x06] });
    for (k, b) in f.iter_mut().enumerate().skip(14) {
        *b = (k as u8).wrapping_mul(13).wrapping_add(5);
    }
    f
}

/// An IPv4 Ethernet frame whose header's checksum is wrong, which the IPv4
/// checks drop.
fn ipv4_bad(len: usize) -> Vec<u8> {
    let mut f = frame(false, len);
    f[12..14].copy_from_slice(&[0x08, 0x00]);
    f[14] = 0x45;
    f[16..18].copy_from_slice(&((len - 14) as u16).to_be_bytes());
    f[22] = 64;
    f[23] = 17;
    f[24..26].copy_from_slice(&[0xde, 0xad]);
    f
}

/// The words of `f` in the file device's byte order.
fn words(f: &[u8]) -> Vec<Word> {
    f.chunks(4)
        .map(|c| {
            let mut w = [0u8; 4];
            w[..c.len()].copy_from_slice(c);
            Word::from(u32::from_le_bytes(w))
        })
        .collect()
}

/// The host side behind the run's device: its frames at their clocks.
pub fn attach(e: &mut Pipeline, run: &EthRun) {
    let period = e.period();
    let s = Script::default();
    for (clock, f) in &run.frames {
        s.arrive(clock * period, f.clone());
    }
    e.machine_mut().attach_ethernet_peer(Box::new(s));
    if let Some(h) = run.host {
        e.machine_mut().ethernet.host = h;
    }
}

/// **muir's device as the host's side saw it**, by clock.
#[derive(Default)]
pub struct Watch {
    told_host: bool,
    prod: (u32, u32),
    tx: u32,
    rx: u32,
    counts: u32,
    pub lines: Vec<String>,
}

impl Watch {
    pub fn watch(&mut self, e: &Pipeline) {
        let m = e.machine();
        if !m.geometry.ethernet() {
            return;
        }
        let d = &m.ethernet;
        let clock = e.clock();
        // 253-257 when they are not muir's defaults, once: the testbench
        // writes them in the run's first clocks.
        if !self.told_host && d.host != Host::default() {
            let w: Vec<String> = (0o253..=0o257).map(|k| format!("{:x}", d.read(k))).collect();
            self.lines.push(format!("# edhost {}", w.join(" ")));
        }
        self.told_host = true;
        let prod = (d.read(TX_PROD), d.read(RX_PROD));
        if prod != self.prod {
            self.lines.push(format!("# edprod {clock:x} {:x} {:x}", prod.0, prod.1));
            self.prod = prod;
        }
        let on = d.enabled();
        let counts = d.read(STATUS) & COUNTS_MASK;
        if counts != self.counts {
            self.lines.push(format!("# edcounts {clock:x} {counts:x}"));
            self.counts = counts;
        }
        let (tx, rx) = (d.read(TX_CONS), d.read(RX_CONS));
        if on && tx != self.tx {
            self.lines.push(format!("# edtx {clock:x} {tx:x}"));
        }
        if on && rx != self.rx {
            assert_eq!(rx, (self.rx + 1) & 0xFFFF, "two deliveries in one clock");
            self.lines.push(format!("# edrx {clock:x} {rx:x}"));
            let (base, log2) = (d.read(RX_BASE) as usize, d.read(RX_SIZE));
            let e_at = base + 8 * (self.rx % (1 << log2)) as usize;
            let buf = (m.main[e_at] as u32 & 0o1777777777) as usize;
            let n = m.main[e_at + 2] as u32 as usize;
            for a in (buf..buf + n.div_ceil(4)).chain([e_at + 2]) {
                self.lines.push(format!("# edword {clock:x} {a:x} {:x}", m.main[a]));
            }
        }
        self.tx = tx;
        self.rx = rx;
    }
}

/// A run: -RESET's sweep of the TLB taken as done.
fn run() -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p
}

const fn reg(k: u64) -> Word {
    REGISTER_PAGE | k
}

fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// Waits until register-page word `k` reads `v`.
fn wait_for(p: &mut Preset, k: u64, v: Word) {
    let (at, want) = (p.k(reg(k)), p.k(v));
    let round = p.at();
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.fill(1);
    p.op(jcond(3) | 1 << 6 | muir::isa::asm::SRC_MD | a_src(want) | target(round));
    p.fill(1);
}

/// Counts M `m` down from `n`: a delay whose end is the same on every
/// engine.
fn delay(p: &mut Preset, m: u64, n: u64) {
    let k = p.k(n);
    p.op(ALU | SETA | a_src(k) | m_dest(m));
    let top = p.at();
    p.op(ALU | SUB | a_src(ONE) | m_src(m) | m_dest(m));
    p.op(jcond(3) | 1 << 6 | a_src(ZERO) | m_src(m) | target(top) | N);
    p.fill(1);
}

/// The rings: the transmit ring of 2^`tl` and the receive ring of 2^`rl`.
fn rings(p: &mut Preset, tl: Word, rl: Word, control: Word) {
    p.write(TX_RING, reg(0o242)).write(tl, reg(0o243)).write(RX_RING, reg(0o246));
    p.write(rl, reg(0o247)).write(control, reg(0o240));
}

fn finish(name: &str, p: &Preset, frames: Vec<(u64, Vec<u8>)>) -> Case {
    let mut c = p.case(name);
    c.micro_check = false;
    c.eth = Some(EthRun { frames, host: None });
    c
}

/// **The group.**
pub fn ethernet() -> Vec<Case> {
    let mut v = Vec::new();

    // ---------------------------------------------------------- registers
    let mut p = run();
    p.read(reg(0), 0o20).read(reg(0o15), 0o21);
    for k in 0o240..=0o257 {
        p.read(reg(k), 0o22);
    }
    p.write(TX_RING | 3, reg(0o242)).write(2, reg(0o243)).write(RX_RING, reg(0o246));
    p.write(2, reg(0o247)).write(1, reg(0o240));
    p.read(reg(0o241), 0o23).read(reg(0o242), 0o24);
    p.write(TX_RING, reg(0o242)).write(9, reg(0o243)).write(1, reg(0o240));
    p.read(reg(0o241), 0o23).read(reg(0o243), 0o24);
    p.write(2, reg(0o243)).write(1 | 1 << 8, reg(0o240));
    p.read(reg(0o240), 0o23).read(reg(0o241), 0o24);
    p.write(3, reg(0o243)).read(reg(0o243), 0o23);
    p.write(9, reg(0o244)).read(reg(0o241), 0o23).read(reg(0o244), 0o24);
    p.write(1 | 1 << 8, reg(0o240)).read(reg(0o241), 0o23);
    p.write(1, reg(0o252)).read(reg(0o241), 0o23);
    p.write(4, reg(0o250)).read(reg(0o250), 0o23).read(reg(0o100), 0o24);
    p.write(5, reg(0o250)).read(reg(0o241), 0o23);
    p.write(3, reg(0o244)).read(reg(0o244), 0o23);
    p.write(0, reg(0o240));
    for k in [0o240, 0o241, 0o244, 0o245, 0o250, 0o251, 0o252, 0o242, 0o243] {
        p.read(reg(k), 0o23);
    }
    p.write(1, reg(0o240)).write(1, reg(0o104));
    p.read(reg(0o240), 0o23).read(reg(0o241), 0o24).read(reg(0o242), 0o25);
    p.write(0xFFFF_FFFF, reg(0o253)).read(reg(0o253), 0o23);
    p.stop();
    v.push(finish("registers", &p, Vec::new()));

    // ----------------------------------------------------------- transmit
    let mut p = run();
    p.timing = Some(PortTiming { read_ns: 247, write_ns: 25_000, occupancy_ns: 10 });
    let arp = frame(false, 42);
    for (k, w) in words(&arp).into_iter().enumerate() {
        p.main.push((FRAME as usize + k, w));
    }
    p.main.push((TX_RING as usize, FRAME));
    p.main.push((TX_RING as usize + 1, 42));
    p.main.push((TX_RING as usize + 8, FRAME));
    p.main.push((TX_RING as usize + 9, 10));
    rings(&mut p, 1, 1, 1);
    // A word written to memory the port answers in 25 us, and 244 right
    // behind it.
    p.write(0o1234, PHYS | 0o20000);
    p.write(2, reg(0o244));
    p.read(reg(0o244), 0o23);
    wait_for(&mut p, 0o245, 1);
    p.read(reg(0o241), 0o23);
    wait_for(&mut p, 0o245, 2);
    p.read(reg(0o241), 0o23).read(reg(0o245), 0o24);
    p.stop();
    v.push(finish("transmit", &p, Vec::new()));

    // ------------------------------------------------------------ receive
    let mut p = run();
    for (k, (b, room)) in [(BUF0, 64), (BUF1, 64), (BUF2, 20)].into_iter().enumerate() {
        p.main.push((RX_RING as usize + 8 * k, b));
        p.main.push((RX_RING as usize + 8 * k + 1, room));
    }
    p.main.push((BUF0 as usize, 0o7777));
    rings(&mut p, 1, 2, 1 | 1 << 8);
    p.read(PHYS | BUF0, 0o23);
    p.write(3, reg(0o250));
    wait_for(&mut p, 0o251, 1);
    p.read(PHYS | BUF0, 0o23).read(PHYS | (BUF0 + 10), 0o24).read(PHYS | (RX_RING + 2), 0o25);
    p.read(reg(0o241), 0o23).read(reg(0o100), 0o24);
    p.write(1, reg(0o252)).read(reg(0o100), 0o23).read(reg(0o241), 0o24);
    wait_for(&mut p, 0o251, 2);
    p.read(PHYS | BUF1, 0o23).read(PHYS | (RX_RING + 10), 0o24);
    p.write(2, reg(0o252));
    // The type filter's drop, the IPv4 checks' and the short buffer's,
    // counted.
    wait_for(&mut p, 0o241, 0x0001_0211);
    p.read(reg(0o251), 0o23).read(reg(0o100), 0o24);
    p.stop();
    v.push(finish(
        "receive",
        &p,
        vec![
            (3000, frame(false, 42)),
            (6000, frame(false, 60)),
            (9000, frame(true, 42)),
            (10500, ipv4_bad(46)),
            (12000, frame(false, 42)),
        ],
    ));

    // --------------------------------------------------------------- held
    let mut p = run();
    p.timing = Some(PortTiming { read_ns: 247, write_ns: 25_000, occupancy_ns: 10 });
    for k in 0..4 {
        p.main.push((TX_RING as usize + 8 * k, FRAME));
        p.main.push((TX_RING as usize + 8 * k + 1, 42));
    }
    for (k, w) in words(&frame(false, 42)).into_iter().enumerate() {
        p.main.push((FRAME as usize + k, w));
    }
    rings(&mut p, 2, 2, 1);
    // The file device enabled beside it, so that a held write landing on the
    // wrong device shows.
    p.write(0o30000, reg(0o162)).write(1, reg(0o163)).write(0o30100, reg(0o166));
    p.write(1, reg(0o167)).write(1, reg(0o160));
    p.write(0o1234, PHYS | 0o20000);
    p.write(1, reg(0o244)).write(2, reg(0o244)).write(1, reg(0o250));
    p.read(reg(0o244), 0o23).read(reg(0o250), 0o24);
    p.write(0o4321, PHYS | 0o20001);
    p.write(1, reg(0o164)).write(3, reg(0o244));
    p.read(reg(0o244), 0o23).read(reg(0o161), 0o24).read(reg(0o164), 0o25);
    wait_for(&mut p, 0o245, 3);
    wait_for(&mut p, 0o170, 1);
    p.read(reg(0o164), 0o23).read(reg(0o250), 0o24).read(reg(0o241), 0o25);
    p.stop();
    v.push(finish("held", &p, Vec::new()));

    // ---------------------------------------------------------------- irq
    let mut p = run();
    p.main.push((RX_RING as usize, BUF0));
    p.main.push((RX_RING as usize + 1, 64));
    rings(&mut p, 0, 0, 1 | 1 << 8);
    p.write(1, reg(0o250));
    // Interrupts enabled: INTERRUPT-CONTROL <27>, destination 2.
    let on = p.k(1 << 35);
    p.op(ALU | SETA | a_src(on) | (0o2 << 19 | 0o36 << 14));
    let top = p.at();
    p.op(jcond(5) | P | target(HANDLER) | N);
    p.fill(1);
    p.op(jcond(3) | a_src(ZERO) | m_src(0o26) | target(top) | N);
    p.fill(1);
    p.read(reg(0o100), 0o23).read(reg(0o241), 0o24);
    delay(&mut p, 0o25, 40);
    p.stop();
    // The handler: 252 written up to 251, which lowers the level; a count in
    // M 26 once its write has landed; and back.
    p.fill_to(HANDLER);
    p.write(1, reg(0o252));
    p.fill(2);
    p.op(ALU | ADD | a_src(ONE) | m_src(0o26) | m_dest(0o26));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    v.push(finish("irq", &p, vec![(2500, frame(false, 42))]));

    // ---------------------------------------------------------- hostwords
    // 253-257 the host's, not muir's defaults: read after the testbench has
    // written them, and a frame to the host's MAC address delivered.
    let host = Host {
        mac: [0x02, 0x5a, 0x11, 0x22, 0x33, 0x44],
        address: u32::from_be_bytes([169, 254, 101, 2]),
        netmask: u32::MAX << 2,
        gateway: u32::from_be_bytes([169, 254, 101, 1]),
    };
    let mut p = run();
    p.main.push((RX_RING as usize, BUF0));
    p.main.push((RX_RING as usize + 1, 64));
    delay(&mut p, 0o25, 40);
    for k in 0o253..=0o257 {
        p.read(reg(k), 0o23);
    }
    rings(&mut p, 0, 0, 1 | 1 << 8);
    p.write(1, reg(0o250));
    wait_for(&mut p, 0o251, 1);
    p.read(PHYS | BUF0, 0o23).read(reg(0o241), 0o24);
    p.stop();
    let mut f = frame(false, 42);
    f[..6].copy_from_slice(&host.mac);
    let mut c = finish("hostwords", &p, vec![(3000, f), (3200, frame(false, 42))]);
    c.eth.as_mut().expect("the run's frames").host = Some(host);
    v.push(c);
    v
}
