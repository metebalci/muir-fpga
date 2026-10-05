// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for `rtl/machine/quux_mem_port.sv` at revision 13
//! (`WORD_BITS` 40): QUUX's memory port with contract G2 §3's cache and
//! packed storage, out of muir's own `memory_port::MemoryPort` as
//! `MemoryPort::new` makes it, revision 13's, tick by tick.
//!
//!     quux13_port --machine quux --sync-cycle-ticks K
//!
//! What revision 13 changed from revision 12's port (G1 §3-§4, G2 §3):
//!
//! - **40-bit words and 28-bit physical addresses**: main memory is 64M
//!   words, the most a board holds (G1 §4.5), and its sets are visited by
//!   tags up to `phys<25>`; the frame buffer window is at `1760000000`, 4
//!   bytes a word, a write storing the field and a read giving it with the
//!   unboxed tag `005` (G1 §4.2); the register page at `1777777400`.
//! - **The cache's 8-word lines**, 256 sets, and a fill in muir's nominal
//!   380 ns and a tick for each beat past two: 410 ns in main memory, 400
//!   in the window (`MemoryPort::fill_ns`).
//! - **The prefetch with the page's reach** (`Reach::Page`): the processor
//!   marks some reads as the stream's fetch of a 28-bit virtual address,
//!   drops the buffer now and then, and stores to the word it holds; the
//!   trace carries the buffer as muir's port leaves it each tick.
//!
//! Each row is one tick of MIT's grid: the stimulus --- `-MEMRQ`, `WRCYC`,
//! which of the three the held decode calls the address, the address and
//! the word, the master clock, the invalidation pulse, the word a device
//! register gives when asked, whether the request is the stream's fetch and
//! of which virtual address, and the processor's drop of the buffer --- and
//! what muir's port does with it: `-MEMGRANT`, `-MEMACK`, `-LOADMD`,
//! `NXM TIMEOUT`, whether the cycle is the memory bus's, the word a read
//! brings, and the prefetch's buffer: whether it holds a word, and its
//! virtual and physical addresses and the word.
//!
//! **THE WORDS ARE THIS PROGRAM'S**, muir's port holding none: every word
//! of main memory starts as [`initial`], which the testbench's memory lays
//! out in packed storage from the same function, and the window's as its
//! `<31:0>`; a write changes one from its acknowledgment.  The prefetch's
//! word is main memory's as muir's port reads it at the answer, from the
//! same words.
//!
//! **THE PROCESSOR'S DROPS COME AT MASTER CLOCK EDGES**, as a write of the
//! location counter or a map write lands there, and muir's order within a
//! tick is kept: an answer, then the drops, then a request and the grant.
//! The invalidation pulse, a block-disk register written, drops the buffer
//! where it lands (`Rtl::clock_edge`'s `dma_written`), and the whole cache
//! at the next request.
//!
//! Every choice is a seeded generator's, so the trace is the same every
//! run.  The generator asserts that it reached every case of the page's
//! reach: a word in the fetch's line, in the next line held, not held, and
//! a page's end.

mod machine_axis;

use std::collections::HashMap;

use muir::busint::{self, Responder};
use muir::cache::MemoryTiming;
use muir::clock::TimingModel;
use muir::machine::Word;
use muir::memory_port::{Drop, MemoryPort, Reach};

const TICK_NS: u64 = 10;

const TICKS: u64 = 600_000;

/// Main memory: 64M words, 1,024 of muir's 64K-word boards (G1 §4.5's
/// largest), `0`-`377777777`.
const MAIN_WORDS: u32 = 64 << 20;

/// The frame buffer window (G1 §3.2) and the video controller's buffer in
/// it, 40,960 words at the bitstreams' 1280 by 1024.
const WINDOW: u32 = 0o1760000000;
const FB_WORDS: u32 = 1280 * 1024 / 32;

/// The register page (G1 §3.2).
const PAGE: u32 = 0o1777777400;

/// The unboxed tag a window's word reads with.
const FIX: Word = 0o005 << 32;
const MASK40: Word = (1 << 40) - 1;

/// A word of main memory before anything writes it, the same function the
/// testbench's memory starts from: a multiplicative hash of the address to
/// 40 bits, so that no two nearby words agree in any byte, the tag
/// included, and a word from the wrong line, beat or byte reads wrong.
pub fn initial(phys: u32) -> Word {
    let x = u64::from(phys).wrapping_add(1).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    ((x >> 20) ^ 0x3C_5AA5_C3A5) & MASK40
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
    fn word(&mut self) -> Word {
        (u64::from(self.next()) << 8 ^ u64::from(self.next())) & MASK40
    }
}

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
    fn responder(self) -> Responder {
        match self {
            Kind::Memory => Responder::Memory(0),
            Kind::Device => Responder::Device,
            Kind::Nothing => Responder::NoXbus,
        }
    }
}

/// The memory bus's words: main memory's, 40 bits, and the window's
/// fields, each [`initial`] until written.
struct Words {
    main: HashMap<u32, Word>,
    window: HashMap<u32, u32>,
}

impl Words {
    fn read(&self, phys: u32) -> Word {
        if phys >= WINDOW {
            FIX | Word::from(*self.window.get(&phys).unwrap_or(&(initial(phys) as u32)))
        } else {
            *self.main.get(&phys).unwrap_or(&initial(phys))
        }
    }
    fn write(&mut self, phys: u32, w: Word) {
        if phys >= WINDOW {
            self.window.insert(phys, w as u32);
        } else {
            self.main.insert(phys, w);
        }
    }
}

/// An address of the memory bus the cache will fight over: half the time
/// a word of the line last used, as a program walks its data; now and then
/// the word after the last, which walks lines and pages; else one of ten
/// sets --- 127 and 255 end a page at their lines' last word --- each
/// visited by six tags up to `phys<25>`, so one line of every set is out at
/// any time; now and then a word anywhere in main memory; and the window.
fn memory_address(rng: &mut Rng, last: u32) -> u32 {
    if rng.below(2) == 0 {
        return (last & !7) | rng.below(8);
    }
    if rng.below(4) == 0 && last < MAIN_WORDS - 1 {
        return last + 1;
    }
    if rng.below(8) == 0 {
        return rng.below(MAIN_WORDS);
    }
    if rng.below(6) == 0 {
        return match rng.below(4) {
            0 => WINDOW + rng.below(8),
            1 => WINDOW + FB_WORDS - 8 + rng.below(8),
            2 => WINDOW + (127 << 3) + rng.below(8),
            _ => WINDOW + rng.below(FB_WORDS),
        };
    }
    const SETS: [u32; 10] = [0, 1, 2, 7, 64, 126, 127, 128, 254, 255];
    // Tags a bit apart, one past 22 bits, and one with every bit main
    // memory has.
    const TAGS: [u32; 6] = [0, 1, 0o1777, 0o2000, 0o40000, 0o77777];
    let set = SETS[rng.below(SETS.len() as u32) as usize];
    let tag = TAGS[rng.below(TAGS.len() as u32) as usize];
    // The line's last word, which looks past it, a third of the time.
    let word = if rng.below(3) == 0 { 7 } else { rng.below(8) };
    (tag << 11) | (set << 3) | word
}

fn main() {
    assert_eq!(TICK_NS, muir::clock::GRID_NS, "the trace's grid is not muir's");
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let timing: TimingModel = machine_axis::take_timing(which, &mut args);
    let TimingModel::Sync { cycle_ticks, .. } = timing else {
        eprintln!("quux13_port is QUUX's: --machine quux --sync-cycle-ticks K");
        std::process::exit(2);
    };
    if which != machine_axis::Which::Quux || !args.is_empty() {
        eprintln!("quux13_port is QUUX's: --machine quux --sync-cycle-ticks K, and nothing else");
        std::process::exit(2);
    }
    let k = u64::from(cycle_ticks);

    let mut port = MemoryPort::new();
    port.keep_timing_model(timing);
    let config = port.cache().config;
    let memory = port.memory_timing();
    assert_eq!(
        (config.words, config.line_words, config.ways, config.hit_ns, config.write_buffer),
        (4096, 8, 2, 20, true),
        "revision 13's cache is not the shape quux_cache.sv is built to"
    );
    assert_eq!(memory, MemoryTiming::NOMINAL, "revision 13's port is not at the nominal timing");
    assert_eq!((memory.read_ns, memory.write_ns), (380, 290), "QUUX's nominal timing moved");
    assert_eq!(port.prefetch(), Some(Reach::Page), "revision 13's prefetch is not the page's reach");

    let mut words = Words { main: HashMap::new(), window: HashMap::new() };
    // What muir's port reads the prefetch's word from: main memory's words
    // as a slice.  Its length is main memory's; only the words the port
    // reads are written into it, before each answer, so the pages nobody
    // reads stay the zero pages the allocation gives.
    let mut main_view: Vec<Word> = vec![0; MAIN_WORDS as usize];
    let mut rng = Rng(0x0013_1ED6_C0FF_EE13);

    let mut cycle: u64 = 0;
    let mut memrq = false;
    let mut write = false;
    let mut kind = Kind::Memory;
    let mut phys: u32 = 0;
    let mut wdata: Word = 0;
    let mut dev_word: u32 = 0;
    let mut fetch: Option<u32> = None;
    let mut next_request_at: u64 = 12 * TICK_NS;
    let mut release_at: Option<u64> = None;
    let mut acked_at: Option<u64> = None;
    let mut word: Word = 0;
    let mut invalidate_owed = false;
    let mut pulse_at: Option<u64> = None;
    let mut granted_at: u64 = 0;
    let mut last_memory: u32 = 0;
    let mut last_fetch: u32 = 0;
    // The main memory words read lately, whose lines the cache may hold.
    let mut recent = [0u32; 8];
    let mut recent_at = 0usize;

    let (mut hits, mut misses, mut writes, mut devices, mut nothings, mut pulses) = (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
    let (mut buffer_waits, mut fill_waits, mut fb_cycles, mut high) = (0u64, 0u64, 0u64, 0u64);
    let (mut drops, mut stores_to_word, mut spanning, mut fetch_reads) = (0u64, 0u64, 0u64, 0u64);

    println!(
        "# quux13_port: muir's memory_port::MemoryPort on Geometry::QUUX, golden/src/quux13_port.rs, timing: {}",
        machine_axis::timing_name(timing)
    );
    println!("# initial(phys) = (((phys + 1) * 0x9E3779B97F4A7C15) >> 20 ^ 0x3C5AA5C3A5) mod 2^40");
    println!(
        "# tick mclk n_memrq wrcyc kind phys wdata inval dev_word fetch vaddr drop | n_memgrant n_memack n_loadmd timed_out cached word pf_v pf_vaddr pf_phys pf_word"
    );
    println!("# kind: 0 the memory bus (main memory, or the window at {WINDOW} up), 1 a device register, 2 nothing; every value decimal");

    for tick in 0..TICKS {
        let now = tick * TICK_NS;
        let mclk = tick % k == 0;

        if let Some(at) = release_at
            && now >= at
        {
            port.finish();
            release_at = None;
            acked_at = None;
            memrq = false;
            fetch = None;
            next_request_at = now + TICK_NS * (1 + u64::from(rng.below(4)) * k + u64::from(rng.below(3)));
            cycle += 1;
            if rng.below(60) == 0 {
                pulse_at = Some(now + TICK_NS);
            }
        }

        let mut timed_out = false;
        let mut acked = false;
        // An answer comes first in the tick, then the drops, then a grant.
        // The word of a cycle acknowledged, taken once, and the prefetch's
        // look past a read: muir's `Rtl` reads the word and calls
        // `read_answered` at the acknowledgment.
        macro_rules! answer {
            () => {
                port.poll(now, kind.responder()).map(|ack| {
                    if acked_at.is_none() {
                        acked_at = Some(ack.at);
                        match kind {
                            Kind::Memory if write => words.write(phys, wdata),
                            Kind::Memory => word = words.read(phys),
                            Kind::Device => word = Word::from(dev_word),
                            Kind::Nothing => word = 0,
                        }
                        if !write {
                            // muir's port reads the next word off main
                            // memory as the machine holds it now.
                            let next = phys.wrapping_add(1);
                            if (next as usize) < main_view.len() {
                                main_view[next as usize] = words.read(next);
                            }
                            port.read_answered(&main_view);
                        }
                        release_at = Some(ack.at + if kind == Kind::Memory { TICK_NS } else { busint::MFINISHD_NS });
                        match kind {
                            Kind::Memory if write => {
                                writes += 1;
                                if ack.at > granted_at + 20 {
                                    buffer_waits += 1;
                                }
                            }
                            Kind::Memory if ack.at > granted_at + 410 => fill_waits += 1,
                            Kind::Device => devices += 1,
                            Kind::Nothing => nothings += 1,
                            _ => {}
                        }
                        if kind == Kind::Memory && phys >= WINDOW {
                            fb_cycles += 1;
                        }
                    }
                    ack.timed_out
                })
            };
        }
        if let Some(t) = answer!() {
            acked = true;
            timed_out = t;
        }

        // The processor's drop, at a master clock edge, and a block-disk
        // register written between cycles.
        let pf_drop = mclk && rng.below(40) == 0;
        if pf_drop {
            if port.prefetched().is_some() {
                drops += 1;
            }
            port.drop_prefetched(Drop::LcWrite);
        }
        let inval = pulse_at == Some(now);
        if inval {
            invalidate_owed = true;
            pulses += 1;
            port.drop_prefetched(Drop::Dma);
        }

        if !memrq && release_at.is_none() && now >= next_request_at && pulse_at.is_none_or(|p| p < now) {
            pulse_at = None;
            kind = match rng.below(100) {
                0..=79 => Kind::Memory,
                80..=95 => Kind::Device,
                _ => Kind::Nothing,
            };
            write = rng.below(100) < 35;
            fetch = None;
            phys = match kind {
                Kind::Memory => {
                    let held = port.prefetched();
                    if write && held.is_some() && rng.below(4) == 0 {
                        // A store to the word the buffer holds.
                        stores_to_word += 1;
                        held.unwrap().phys
                    } else if !write && rng.below(3) == 0 {
                        // The stream's next fetch, or a fetch elsewhere.
                        let p = match rng.below(8) {
                            // The word before a line lately read, which
                            // the cache is likely to hold: the next line's
                            // word, looked up beside the fetch's.
                            0..=2 if recent.iter().any(|&r| r & !7 != 0) => {
                                let r = recent[rng.below(recent.len() as u32) as usize];
                                (r & !7).max(1) - 1
                            }
                            0..=5 if last_fetch < MAIN_WORDS - 1 => last_fetch + 1,
                            _ => memory_address(&mut rng, last_memory),
                        };
                        let v = (rng.next() << 4 ^ p) & 0x0fff_ffff;
                        fetch = Some(v);
                        last_fetch = p;
                        p
                    } else {
                        last_memory = memory_address(&mut rng, last_memory);
                        if !write && last_memory < WINDOW {
                            recent[recent_at % recent.len()] = last_memory;
                            recent_at += 1;
                        }
                        last_memory
                    }
                }
                Kind::Device => match rng.below(3) {
                    0 => PAGE + 0o200 + rng.below(4),
                    1 => PAGE + rng.below(0o400),
                    _ => PAGE + 0o210,
                },
                // Past main memory's end, past the window's buffer, and
                // the rest of the space below the register page; and
                // revision 12's page and window, which are main memory
                // only where there is that much of it, and here are.
                Kind::Nothing => match rng.below(3) {
                    0 => MAIN_WORDS + rng.below(WINDOW - MAIN_WORDS),
                    1 => WINDOW + FB_WORDS + rng.below(0o1000),
                    _ => 0o1777776000 + rng.below(0o1400),
                },
            };
            if kind == Kind::Memory && phys < WINDOW && phys >= 1 << 22 {
                high += 1;
            }
            if kind == Kind::Memory && write && phys < WINDOW && [1, 3, 4, 6].contains(&(phys & 7)) {
                spanning += 1;
            }
            wdata = rng.word();
            dev_word = rng.next();
            if invalidate_owed {
                port.invalidate_cache();
                invalidate_owed = false;
            }
            port.request_at(write, phys);
            if let Some(v) = fetch {
                port.mark_fetch(v);
                fetch_reads += 1;
            }
            memrq = true;
        }

        if mclk {
            let before = (port.cache().hits, port.cache().misses);
            let was = port.granted();
            port.mclk_edge(now, kind.responder());
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
            // An address nothing answers is answered at the edge.
            if !acked && let Some(t) = answer!() {
                acked = true;
                timed_out = t;
            }
        }

        let granted = port.granted();
        let b = |v: bool| u8::from(v);
        let cached = acked && kind == Kind::Memory;
        let pf = port.prefetched();
        println!(
            "{tick} {} {} {} {} {phys} {wdata} {} {dev_word} {} {} {} {} {} {} {} {} {} {} {} {} {}",
            b(mclk),
            b(!memrq),
            b(write),
            kind.code(),
            b(inval),
            b(fetch.is_some()),
            fetch.unwrap_or(0),
            b(pf_drop),
            b(!granted),
            b(!acked),
            b(!acked),
            b(timed_out),
            b(cached),
            if acked && !write { word } else { 0 },
            b(pf.is_some()),
            pf.map_or(0, |p| p.vaddr),
            pf.map_or(0, |p| p.phys),
            pf.map_or(0, |p| p.word),
        );
    }

    let c = port.prefetch_counts;
    eprintln!(
        "quux13_port: {cycle} cycles over {TICKS} ticks: {hits} read hits, {misses} read misses, \
         {writes} writes ({spanning} of words across two beats), {fb_cycles} of the window's cycles, \
         {high} above 22 bits, {devices} device register cycles, {nothings} addresses nothing \
         answers, {pulses} invalidations, {buffer_waits} writes the full buffer held, {fill_waits} \
         fills behind a draining write; prefetch: {fetch_reads} fetches, {} answered from memory, \
         {} words in the line, {} in the next line, {} past a page's end, {} not held, {drops} \
         dropped by the processor, {stores_to_word} stores to the word",
        c.fetches, c.same_line, c.next_line, c.page_end, c.not_held
    );
    assert!(buffer_waits > 100 && fill_waits > 100, "the trace never waited on main memory's timing");
    assert!(hits > 1000 && misses > 1000 && writes > 1000, "the trace reached too little of the cache");
    assert!(fb_cycles > 1000 && high > 1000 && spanning > 300, "the trace reached too little of the space");
    assert!(devices > 100 && nothings > 20 && pulses > 20, "the trace reached too little of the registers");
    assert!(
        c.same_line > 300 && c.next_line > 100 && c.page_end > 50 && c.not_held > 100,
        "the trace reached too little of the page's reach"
    );
    assert!(drops > 30 && stores_to_word > 30, "the trace dropped the buffer too seldom");
}
