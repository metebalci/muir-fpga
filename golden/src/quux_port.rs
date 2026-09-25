// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for `rtl/machine/quux_mem_port.sv`: QUUX's memory
//! port and register decode (contracts Q6 and Q7, revision 8), out of muir's
//! own `memory_port::MemoryPort`, tick by tick.
//!
//! The port is the processor's cycle on QUUX, where there is no bus
//! interface and no device bus.  The memory bus: main memory and MONO TV's
//! frame buffer, through the cache --- 4K words in lines of 4, 2-way, a hit
//! in 20 ns --- to main memory at its nominal timing, a line fill in 380 ns
//! and a write in 290, one operation at a time, a write acknowledged after
//! the hit time by the write buffer.  A device register, taken at the edge
//! that grants the cycle and acknowledged a microcycle on, never cached.
//! And an address nothing answers, which fails at once, in the edge that
//! takes it, with the NXM bit: no timer.
//!
//! Each row is one tick of MIT's grid: the stimulus the processor puts on
//! the port --- `-MEMRQ`, `WRCYC`, which of the three the held decode calls
//! the address, the address and the word, the master clock, the block-
//! disk's pulse that invalidates the cache, and the word a device register
//! gives when it is asked --- and what muir's port does with it:
//! `-MEMGRANT`, `-MEMACK`, `-LOADMD`, `NXM TIMEOUT`, whether the cycle is
//! the memory bus's, and the word a read brings.
//!
//! **THE WORD IS THIS PROGRAM'S, MUIR'S PORT HOLDING NONE.**  muir's cache
//! holds tags only (`cache.rs`: "rtl takes a read's word from main memory
//! when the cycle ends"), so what a read returns is the memory as the
//! processor has left it: every word, main memory's and the frame buffer's,
//! starts as [`initial`], which the testbench's memory computes the same
//! way, and a write changes it from its grant.  The fabric's cache holds
//! data, and this is what it must hand back, hit or miss.  A device's word
//! is a fresh one for each cycle, which the testbench's register hands the
//! port only in the tick it is asked, so a word taken at any other tick
//! reads wrong.
//!
//! **THE TIMES ARE MUIR'S AND THE MEMORY'S ARE A FLOOR.**  The testbench
//! plays main memory answering sooner than the nominal figures, as a board
//! faster than them does, and the port must still answer at muir's instant:
//! the Arty holds its answers back to the nominal count.  A slower memory,
//! the DE25's tail, waits; that is not muir's instant and is not held here.
//!
//! **THE INVALIDATION IS muir's RULE, THE WHOLE CACHE AT THE NEXT REQUEST**
//! after a block-disk register is written (`Machine::dma_written`,
//! `Rtl::start_bus_cycle`).  The pulse comes between cycles, as a register
//! write of the processor's own ends one.
//!
//! Every choice is a seeded generator's, so the trace is the same every
//! run; the addresses gather into a few sets with more tags than ways, so
//! lines are evicted, refilled and hit in every order the two ways allow,
//! the frame buffer's among main memory's.

mod machine_axis;

use muir::busint::{self, Responder};
use muir::cache::{CacheConfig, MemoryTiming};
use muir::clock::TimingModel;
use muir::memory_port::MemoryPort;

const TICK_NS: u64 = 10;


const TICKS: u64 = 400_000;

/// Main memory's end, QUUX's 2M words (`Machine::new`).
const MAIN_WORDS: u32 = 32 << 16;

/// MONO TV's frame buffer, on the memory bus (contract Q7): `tv::BUFFER`,
/// 40,960 words at the bitstreams' 1280 by 1024.
const FB: u32 = muir::tv::BUFFER;
const FB_WORDS: u32 = 1280 * 1024 / 32;

/// Main memory's word before anything writes it, the same function the
/// testbench's memory starts from.  A multiplicative hash of the address,
/// so no two nearby words agree and a word from the wrong line or the
/// wrong half of a beat reads wrong.
pub fn initial(phys: u32) -> u32 {
    phys.wrapping_add(1).wrapping_mul(0x9E37_79B1) ^ 0x3C5A_A5C3
}

/// A small linear congruential generator: the trace is a function of its
/// seed alone.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) as u32
    }
    fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
}

/// Which of the three the held decode calls an address: the memory bus
/// (main memory or the frame buffer, told apart by the address), a device
/// register, or nothing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Memory,
    Device,
    Nothing,
}

impl Kind {
    fn code(self) -> u8 {
        match self {
            Kind::Memory => 0,
            Kind::Device => 1,
            Kind::Nothing => 2,
        }
    }
    /// As `Rtl::start_bus_cycle` gives it: the frame buffer is
    /// `Responder::Memory(0)`, the port reading no board number.
    fn responder(self, phys: u32) -> Responder {
        match self {
            Kind::Memory if phys >= FB => Responder::Memory(0),
            Kind::Memory => Responder::Memory((phys >> 16) as u8),
            Kind::Device => Responder::Device,
            Kind::Nothing => Responder::NoXbus,
        }
    }
}

/// An address of main memory the cache will fight over: half the time a
/// word of the line last used, as a program walks its data; else one of
/// eight sets, each visited by three tags, so one line of every set is out
/// at any time; and now and then a word anywhere in main memory.
fn memory_address(rng: &mut Rng, last: u32) -> u32 {
    if rng.below(2) == 0 {
        return (last & !3) | rng.below(4);
    }
    if rng.below(8) == 0 {
        return rng.below(MAIN_WORDS);
    }
    // The frame buffer, now and then: its first and last lines, and one
    // whose set is among main memory's below, so the two fight for a way.
    if rng.below(6) == 0 {
        return match rng.below(4) {
            0 => FB + rng.below(4),
            1 => FB + FB_WORDS - 4 + rng.below(4),
            2 => FB + (7 << 2) + rng.below(4),
            _ => FB + rng.below(FB_WORDS),
        };
    }
    const SETS: [u32; 8] = [0, 1, 2, 7, 64, 255, 256, 511];
    // Two tags a bit apart, and one with every bit main memory has.
    const TAGS: [u32; 3] = [0, 1, 0o1777];
    let set = SETS[rng.below(8) as usize];
    let tag = TAGS[rng.below(3) as usize];
    (tag << 11) | (set << 2) | rng.below(4)
}

fn main() {
    assert_eq!(TICK_NS, muir::clock::GRID_NS, "the trace's grid is not muir's");
    // QUUX's microcycle, K ticks: the master clock's edges, where the port
    // takes a request.  The board's K, from the command line
    // (`machine_axis.rs`), never guessed.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let timing: TimingModel = machine_axis::take_timing(which, &mut args);
    let TimingModel::Sync { cycle_ticks, .. } = timing else {
        eprintln!("quux_port is QUUX's: --machine quux --sync-cycle-ticks K");
        std::process::exit(2);
    };
    if which != machine_axis::Which::Quux || !args.is_empty() {
        eprintln!("quux_port is QUUX's: --machine quux --sync-cycle-ticks K, and nothing else");
        std::process::exit(2);
    }
    let k = u64::from(cycle_ticks);
    let config = CacheConfig::QUUX;
    let memory = MemoryTiming::NOMINAL;
    assert_eq!(
        (config.words, config.line_words, config.ways, config.hit_ns, config.write_buffer),
        (4096, 4, 2, 20, true),
        "QUUX's cache is not the shape quux_mem_port.sv is built to"
    );
    assert_eq!((memory.read_ns, memory.write_ns), (380, 290), "QUUX's nominal timing moved");

    let mut port = MemoryPort::new();
    port.keep_timing_model(timing);
    let mut main: Vec<u32> = (0..MAIN_WORDS).map(initial).collect();
    let mut fb: Vec<u32> = (FB..FB + FB_WORDS).map(initial).collect();
    // The memory bus's word at `phys`, main memory's or the frame buffer's.
    fn cell<'a>(main: &'a mut [u32], fb: &'a mut [u32], phys: u32) -> &'a mut u32 {
        if phys >= FB { &mut fb[(phys - FB) as usize] } else { &mut main[phys as usize] }
    }
    let mut rng = Rng(0x0005_1ED6_C0FF_EE01);

    let mut cycle: u64 = 0;
    let mut memrq = false;
    let mut write = false;
    let mut kind = Kind::Memory;
    let mut phys: u32 = 0;
    let mut wdata: u32 = 0;
    // The word a device register gives this cycle, when it is asked.
    let mut dev_word: u32 = 0;
    let mut next_request_at: u64 = 12 * TICK_NS;
    let mut release_at: Option<u64> = None;
    let mut acked_at: Option<u64> = None;
    let mut word: u32 = 0;
    let mut invalidate_owed = false;
    // An invalidation pulse this many ticks before the next request.
    let mut pulse_at: Option<u64> = None;

    // Coverage, asserted at the end: a trace that never evicted or never
    // waited for the write buffer would agree everywhere and mean little.
    let (mut hits, mut misses, mut writes, mut devices, mut nothings, mut pulses) = (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
    let (mut buffer_waits, mut fill_waits, mut fb_cycles) = (0u64, 0u64, 0u64);
    let mut granted_at: u64 = 0;
    let mut last_memory: u32 = 0;

    println!(
        "# quux_port: muir's memory_port::MemoryPort, golden/src/quux_port.rs, timing: {}",
        machine_axis::timing_name(timing)
    );
    println!("# initial(phys) = ((phys + 1) * 0x9E3779B1) ^ 0x3C5AA5C3, 32 bits");
    println!("# tick mclk n_memrq wrcyc kind phys wdata inval dev_word | n_memgrant n_memack n_loadmd timed_out cached word");
    println!("# kind: 0 the memory bus (main memory, or the frame buffer at {FB} up), 1 a device register, 2 nothing; every value decimal");

    for tick in 0..TICKS {
        let now = tick * TICK_NS;
        let mclk = tick % k == 0;

        // The processor lets the cycle go: main memory's at once, its MBUSY
        // falling on the acknowledgment's own edge and seen a tick later;
        // any other after MFINISHD.
        if let Some(at) = release_at
            && now >= at
        {
            port.finish();
            release_at = None;
            acked_at = None;
            memrq = false;
            next_request_at = now + TICK_NS * (1 + u64::from(rng.below(4)) * k + u64::from(rng.below(3)));
            cycle += 1;
            if rng.below(60) == 0 {
                // The pulse lands between two cycles, as a register write
                // of the processor's own ends one.
                pulse_at = Some(now + TICK_NS);
            }
        }

        let inval = pulse_at == Some(now);
        if inval {
            invalidate_owed = true;
            pulses += 1;
        }

        if !memrq && release_at.is_none() && now >= next_request_at && pulse_at.is_none_or(|p| p < now) {
            pulse_at = None;
            kind = match rng.below(100) {
                0..=79 => Kind::Memory,
                80..=97 => Kind::Device,
                _ => Kind::Nothing,
            };
            write = rng.below(100) < 35;
            phys = match kind {
                Kind::Memory => {
                    last_memory = memory_address(&mut rng, last_memory);
                    last_memory
                }
                // The addresses are the stimulus's; the decode is the held
                // one, which this check is given and `xbus_decode.quux`
                // holds over every address.  Block-disk's, the register
                // page's and MONO TV's mode register.
                Kind::Device => match rng.below(3) {
                    0 => 0o17377774 + rng.below(4),
                    1 => 0o17377000 + rng.below(0o400),
                    _ => 0o17377760,
                },
                // Past main memory's end, past the frame buffer's, and the
                // old Unibus window.
                Kind::Nothing => match rng.below(3) {
                    0 => MAIN_WORDS + rng.below(0o1000000),
                    1 => FB + FB_WORDS + rng.below(0o1000),
                    _ => 0o17400000 + rng.below(0o100000),
                },
            };
            wdata = rng.next();
            dev_word = rng.next();
            if invalidate_owed {
                port.invalidate_cache();
                invalidate_owed = false;
            }
            port.request_at(write, phys);
            memrq = true;
        }

        if mclk {
            let before = (port.cache().hits, port.cache().misses);
            let was = port.granted();
            port.mclk_edge(now, kind.responder(phys));
            if !was && port.granted() {
                granted_at = now;
            }
            let after = (port.cache().hits, port.cache().misses);
            if after != before && port.granted() {
                if after.0 > before.0 {
                    hits += 1;
                } else {
                    misses += 1;
                }
            }
        }

        let mut timed_out = false;
        let mut acked = false;
        if let Some(ack) = port.poll(now, kind.responder(phys)) {
            acked = true;
            timed_out = ack.timed_out;
            if acked_at.is_none() {
                acked_at = Some(ack.at);
                match kind {
                    Kind::Memory if write => {
                        writes += 1;
                        *cell(&mut main, &mut fb, phys) = wdata;
                    }
                    Kind::Memory => word = *cell(&mut main, &mut fb, phys),
                    Kind::Device => {
                        devices += 1;
                        word = dev_word;
                    }
                    Kind::Nothing => {
                        nothings += 1;
                        word = 0;
                    }
                }
                if kind == Kind::Memory && phys >= FB {
                    fb_cycles += 1;
                }
                if kind == Kind::Memory && write && ack.at > granted_at + 20 {
                    buffer_waits += 1;
                }
                if kind == Kind::Memory && !write && ack.at > granted_at + 380 {
                    fill_waits += 1;
                }
                release_at = Some(ack.at + if kind == Kind::Memory { TICK_NS } else { busint::MFINISHD_NS });
            }
        }
        let granted = port.granted();
        let b = |v: bool| u8::from(v);
        let cached = acked && kind == Kind::Memory;
        println!(
            "{tick} {} {} {} {} {phys} {wdata} {} {dev_word} {} {} {} {} {} {}",
            b(mclk),
            b(!memrq),
            b(write),
            kind.code(),
            b(inval),
            b(!granted),
            b(!acked),
            b(!acked),
            b(timed_out),
            b(cached),
            if acked && !write { word } else { 0 },
        );
    }

    eprintln!(
        "quux_port: {cycle} cycles over {TICKS} ticks: {hits} read hits, {misses} read misses, \
         {writes} writes, {fb_cycles} of the frame buffer's cycles, {devices} device register \
         cycles, {nothings} addresses nothing answers, {pulses} invalidations, \
         {buffer_waits} writes the full buffer held, {fill_waits} fills behind a draining write"
    );
    assert!(buffer_waits > 100 && fill_waits > 100, "the trace never waited on main memory's timing");
    assert!(hits > 1000 && misses > 1000 && writes > 1000, "the trace reached too little of the cache");
    assert!(fb_cycles > 1000, "the trace reached too little of the frame buffer");
    assert!(devices > 100 && nothings > 20 && pulses > 20, "the trace reached too little of the registers");
}
