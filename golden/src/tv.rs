// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the display controller --- MIT's TV, muir's
//! `simpletv::SimpleTv` --- driven register by register through muir's own
//! `busint::Busint`, in the shape `busint_xbus.rs` drives the bus interface.
//!
//! **What muir's TV is.**  `src/simpletv.rs`: a 32,768-word frame buffer at
//! `BUFFER` (`0o17000000`), eight control words at `CONTROL` (`0o17377760`),
//! and a vertical flag.  Register 0 is the mode register: four writable bits
//! (`CLOCK<1:0>`, `BOW`, `INTR ENB`), bit 4 the vertical flag --- a flop of
//! its own, **preset once every [`FRAME_NS`]** by the sync program's start of
//! frame and **clocked by a write of the register with the written bit 4 as
//! its data** --- and bits 5 to 7 read as zero.  Registers 1 to 3 are the
//! sync program RAM's data, pointer and enable; 4 to 7 "respond but don't do
//! anything".  `SEND INTR`, what the board puts on `-XBUS.INTR`, is the flag
//! with the enable up.  The device answers in no time of its own
//! (`IDEAL_DEVICE_NS`), so a read acknowledges 140 ns after the grant and a
//! write at 80, exactly as the disk's registers do.
//!
//! **Why a scripted program and not the band.**  Measured on muir's `rtl`
//! engine: MIT's boot PROM never addresses the TV in its 600,000
//! microcycles, and the System 100 band never touches a control register in
//! its 2,200,000 --- the mode register stays zero and the sync RAM empty,
//! `tests/vertical.rs` saying why: the cold boot's `LISP-REINITIALIZE` skips
//! `SETUP-CPT`.  What the band does reach is the frame buffer, from
//! microcycle 1,422,272: the microcode's run lights, two words at the bottom
//! of the screen (`0o51763` and `0o51765`) written all ones and cleared
//! again around every disk transfer.  That is a handful of words of one
//! value, and nothing at all of the register face or the interrupt, so a
//! check driven by either program would test nothing, and this program is
//! the only reference.
//!
//! **The shape of the trace.**  One row a tick wherever anything moves, in
//! `busint_xbus.golden`'s columns with three more: the stimulus (`-MEMRQ`,
//! `WRCYC`, the address, the word, `MCLK`, `-XBUS INIT`) and what muir says
//! the fabric must show (`-MEMGRANT`, `-MEMACK`, `-LOADMD`, `NXM TIMEOUT`,
//! the word a read gives `MD`, and `-XBUS.INTR`).  Between two rows nothing
//! changes: every input holds and every output must hold, which is how a
//! frame of 3,091,200 ticks costs one line.  The columns are what the
//! testbench compares **at every tick**, rows and gaps alike.
//!
//! **Three instants, and where the fabric parts from muir on them.**
//!
//! - A write **lands one tick after `-XBUS.RQ` rises.**  muir's `Rtl` hands
//!   the word to the slave at `answered_at`, the request's own instant; a
//!   register in fabric takes it at the clock edge after the request is
//!   first seen, and on the board the 25LS2519 clocks on `-LOAD MODE`, a
//!   gate or two behind `XBUS RQ`.  So the reference writes the model at
//!   `answered_at + 5`, and says so here rather than hiding a tick in a
//!   tolerance.  It is the same 5 ns the disk controller's `STORE_HOLD_NS`
//!   carries, one tick instead of two because nothing here decodes a START.
//! - A read is made **at `answered_at`**, muir's own instant, while the
//!   fabric's MD takes the lines at the 60 ns deskew tap, twelve ticks on.
//!   The one thing that can move in between is the vertical flag at a frame
//!   boundary --- so the generator refuses to place a read of the mode
//!   register with a boundary inside those twelve ticks.  The board reads
//!   the flop live through the 74LS244 at NXBCTL 0F11, so where they
//!   differ the fabric is the board and muir samples early; the trace
//!   simply never asks.
//! - `-XBUS INIT` is a stimulus column: the tick it is up is the tick the
//!   flag clears, and muir's `xbus_init(ns)` is called at that instant.
//!
//! **The frame is counted from power-on**, `ns / FRAME_NS`, and so is the
//! fabric's: tick 0 is the reset tick and [`FRAME_NS`] is a multiple of five,
//! 3,091,200 ticks exactly, so the two never drift and no pre-roll is needed
//! --- unlike the disk's spindle, whose revolution is coprime with five.
//!
//! **The store beats the preset, and the preset beats nothing else.**  A
//! write landing on the very tick a frame begins: muir's `written_at` is
//! that instant and `vert_flag` asks for a frame *strictly* since, so the
//! written bit stands.  Reaching that tick needs the grant edge, the setup
//! and the landing tick to add up to a frame boundary, and with a frame
//! 3 mod 29 ticks long that first happens at frame 25 --- which is why the
//! trace is as long as it is.  Frames 6 and 15 put the landing one tick
//! either side.  `-XBUS INIT` is not tied to the master clock and is put on
//! a boundary and either side of one directly.
//!
//! **The frame buffer is DDR**, on the fabric: a write to the window is a
//! write to the display's region of PS DDR3 through main memory's bridge,
//! and a read the same.  The trace carries the word and the address of every
//! such cycle and the testbench holds the memory port to them --- the
//! shadow is the stimulus's, never the DUT's.  muir's buffer starts as
//! zeros and the fabric's DDR holds whatever it holds, so **no word is read
//! that the program did not first write**, and the generator asserts it.
//! The words are injective in the offset and in the order written, so a
//! write to the wrong word, or of the wrong word, cannot read back right.

use std::collections::{BTreeMap, BTreeSet};

use muir::busint::{self, Busint, MFINISHD_NS, Responder};
use muir::simpletv::{
    BUFFER, BUFFER_WORDS, CONTROL, CONTROL_WORDS, FRAME_NS, SYNC_RAM_WORDS, SimpleTv, mode,
};

/// Five nanoseconds, the master clock's period.
const TICK_NS: u64 = 5;

/// A microcycle at normal speed with no ILONG: where `mclk` falls.
const MICROCYCLE_TICKS: u64 = 29;

/// How many 64K-word memory boards the machine has, muir's default.
const BOARDS: u32 = 32;
const MEMORY_WORDS: u32 = BOARDS << 16;

/// One frame, in ticks: 3,091,200.
const FRAME_TICKS: u64 = FRAME_NS / TICK_NS;

/// The bus interface's own figures, as `cadr_busint_xbus.sv` has them.
const SETUP_TICKS: u64 = busint::SETUP_NS / TICK_NS;
const DESKEW_TICKS: u64 = busint::XBUS_ACK_NS / TICK_NS;

/// The four words between the display's registers and the disk's, which
/// answer to nothing.
const DEAD: u32 = 0o17377770;

/// One word past the top of the window, and one below its bottom: both Xbus
/// space with nothing there, and the two edges of the window's decode.
const ABOVE_WINDOW: u32 = BUFFER + BUFFER_WORDS;
const BELOW_WINDOW: u32 = BUFFER - 1;

/// The word the program puts at a frame-buffer offset, injective in the
/// offset AND in how many times that offset has been written, so that
/// neither a wrong offset nor a stale word reads back right.
fn fb_word(off: u32, nth: u32) -> u32 {
    (off.wrapping_mul(0x9E37_79B1) ^ nth.wrapping_mul(0x85EB_CA6B) ^ 0x5A5A_1234).rotate_left(off & 31)
}

/// A word of main memory, from another family.
fn main_word(phys: u32) -> u32 {
    phys.wrapping_mul(0xC2B2_AE35) ^ 0xA5A5_0F0F
}

/// A byte for the sync program RAM at a pointer: injective in the pointer.
fn sync_byte(p: u32) -> u32 {
    ((p.wrapping_mul(0x9E37) >> 4) ^ (p >> 8) ^ 0x5A) & 0xFF
}

#[derive(Clone, Copy)]
enum Op {
    Cycle { write: bool, phys: u32, wdata: u32, land_at: Option<u64> },
    Init,
}

struct Event {
    /// The earliest tick the operation may begin.
    at: u64,
    op: Op,
}

/// The program, as a list of events with instants.
struct Prog {
    ev: Vec<Event>,
    cursor: u64,
}

impl Prog {
    fn at(&mut self, tick: u64) {
        assert!(tick >= self.cursor, "the program runs backwards: {} to {tick}", self.cursor);
        self.cursor = tick;
    }
    fn read(&mut self, phys: u32) {
        self.ev.push(Event { at: self.cursor, op: Op::Cycle { write: false, phys, wdata: 0, land_at: None } });
    }
    fn write(&mut self, phys: u32, wdata: u32) {
        self.ev.push(Event { at: self.cursor, op: Op::Cycle { write: true, phys, wdata, land_at: None } });
    }
    fn init(&mut self) {
        self.ev.push(Event { at: self.cursor, op: Op::Init });
    }
    /// A write whose word must LAND --- reach the register --- at exactly
    /// `tick`: the grant is SETUP_TICKS + 1 before it and must fall on a
    /// master clock edge, so not every tick is reachable.  The request goes
    /// out a few ticks before that edge, on an idle bus.
    fn write_landing_at(&mut self, tick: u64, phys: u32, wdata: u32) {
        let grant = tick - SETUP_TICKS - 1;
        assert_eq!(grant % MICROCYCLE_TICKS, 0, "a store cannot land at tick {tick}: the grant would be off the master clock");
        self.at(grant - 4);
        self.ev.push(Event { at: self.cursor, op: Op::Cycle { write: true, phys, wdata, land_at: Some(tick) } });
        self.cursor = tick;
    }
}

/// When the cpu asks for its next cycle, in ticks after the last one ended,
/// where the program has nothing scheduled: never zero, and varied so the
/// request lands at every phase of the master clock.
fn gap_ticks(cycle: u64) -> u64 {
    [1, 2, 3, 7, 13, 29, 31][(cycle % 7) as usize]
}

fn which_register(phys: u32) -> Option<u32> {
    muir::simpletv::control_register(phys)
}

fn main() {
    assert_eq!(FRAME_NS % TICK_NS, 0, "FRAME_NS is not on the 5 ns grid");
    assert_eq!(FRAME_TICKS, 3_091_200);
    assert_eq!(FRAME_TICKS % MICROCYCLE_TICKS, 3, "the boundary arithmetic below assumes a frame is 3 mod 29 ticks");
    assert_eq!(CONTROL_WORDS, 8);

    let f = FRAME_TICKS;
    let mut p = Prog { ev: Vec::new(), cursor: 10 };

    // ---------------------------------------------------------------
    // Phase 0, before the first frame: the face at power-on.
    // ---------------------------------------------------------------
    p.read(CONTROL); // the mode register, zero
    for r in 1..CONTROL_WORDS {
        p.read(CONTROL + r); // and seven more zeros
    }
    p.read(DEAD); // the four dead words: nothing answers
    p.read(DEAD + 3);
    p.write(DEAD + 1, 0xDEAD_BEEF);
    // What a write of the mode register can change: bits 3 to 0, and the
    // flag.  Everything above is dropped.
    p.write(CONTROL, 0xFFFF_FFE5); // mode 0o5, the flag clear
    p.read(CONTROL);
    p.write(CONTROL, 0o37); // mode 0o17, the flag SET by the write: -XBUS.INTR up
    p.read(CONTROL);
    p.write(CONTROL, 0o17); // the flag cleared: down again
    p.read(CONTROL);
    p.write(CONTROL, 0o7); // the enable off before the first frame
    // A few main-memory words, so the bridge's other base is in the trace.
    for &a in &[0u32, 0o777, 2_031_617] {
        p.write(a, main_word(a));
    }
    for &a in &[0u32, 0o777, 2_031_617] {
        p.read(a);
    }
    p.read(2_100_000); // above the boards fitted: nothing

    // ---------------------------------------------------------------
    // Frame 1: the preset with the enable off.  The flag sets and nothing
    // reaches the bus.
    // ---------------------------------------------------------------
    p.at(f + 40);
    p.read(CONTROL); // 0o27
    p.write(CONTROL, 0o14); // BOW and INTR ENB; the flag cleared by the write
    p.read(CONTROL); // 0o14: no interrupt until the next frame starts

    // ---------------------------------------------------------------
    // Frames 2 to 5: the microcode's INTRX0 --- read the register, find
    // bit 4, write it back clear --- at four offsets into the frame: a
    // tick, a microcycle, deep into the frame, and just before the next.
    // ---------------------------------------------------------------
    let offsets = [1u64, 29, 100_000, f / 2];
    for (k, off) in (2u64..).zip(offsets) {
        p.at(k * f + off);
        p.read(CONTROL); // 0o34
        p.write(CONTROL, 0o14); // and the interrupt falls with the landing
    }

    // ---------------------------------------------------------------
    // Frame 6: a write landing one tick BEFORE the boundary.  The flag is
    // clear for one tick and the preset sets it again.
    // ---------------------------------------------------------------
    p.at(6 * f - 300);
    p.read(CONTROL); // 0o14: frame 5's INTRX0 cleared it
    p.write(CONTROL, 0o34); // the flag SET by the write, so there is something to clear
    p.read(CONTROL); // 0o34
    p.write_landing_at(6 * f - 1, CONTROL, 0o14);

    // ---------------------------------------------------------------
    // Frame 7: the sync program RAM, with the interrupt standing the whole
    // time --- a frame nobody clears, so the boundary into frame 8 is a
    // preset on a flag already set and moves nothing.
    // ---------------------------------------------------------------
    p.at(7 * f + 5_000);
    p.read(CONTROL); // 0o34
    p.write(CONTROL + 3, 0); // the enable off: the PROM is selected
    p.write(CONTROL + 2, 0x1FFF); // the pointer takes twelve bits: 0xFFF
    p.write(CONTROL + 1, 0x1234_56A5); // and the data eight: 0xA5
    p.read(CONTROL + 1); // zero, the RAM not being selected
    p.write(CONTROL + 3, 0x80 | 0o65); // the enable, over a spacing
    p.read(CONTROL + 1); // 0xA5
    p.read(CONTROL + 2); // write only: zero
    p.read(CONTROL + 3); // write only: zero
    // Pointers spread over the twelve bits, a byte at each, then all of
    // them read back in another order.
    let mut pointers: Vec<u32> = vec![0, 1, 2, 0x7FF, 0x800, 0x801, 0xFFE];
    for i in 0..24u32 {
        pointers.push((i.wrapping_mul(0x9E37) ^ (i << 7)) & 0xFFF);
    }
    pointers.sort();
    pointers.dedup();
    for &ptr in &pointers {
        p.write(CONTROL + 2, ptr);
        p.write(CONTROL + 1, 0xFFFF_FF00 | sync_byte(ptr));
    }
    for &ptr in pointers.iter().rev() {
        p.write(CONTROL + 2, ptr);
        p.read(CONTROL + 1);
    }
    p.write(CONTROL + 2, 0xFFF);
    p.read(CONTROL + 1); // 0xA5 still, under the others
    // The three that respond and do nothing.
    for r in 4..CONTROL_WORDS {
        p.write(CONTROL + r, 0xFFFF_FFFF);
    }
    for r in 4..CONTROL_WORDS {
        p.read(CONTROL + r);
    }
    p.read(CONTROL); // the mode register untouched by all of that: 0o34
    p.write(CONTROL + 3, 0o65); // the enable off again, the spacing kept
    p.read(CONTROL + 1); // zero
    p.write(CONTROL + 3, 0x80 | 0o65);
    p.read(CONTROL + 1); // 0xA5

    // ---------------------------------------------------------------
    // Frame 8: the frame buffer.  Writes across the window and its edges,
    // reads back, one word rewritten with its neighbours checked, and the
    // two words just outside the window, which nothing answers.
    // ---------------------------------------------------------------
    p.at(8 * f + 777);
    let offsets_fb: Vec<u32> = vec![
        0, 1, 2, 23, 24, 25, 47, 48, 0x0100, 0x0800, 0x1000, 0x2000, 0x2AAA, 0x4000, 0x5555, 0x5A5A,
        0x7FFE, 0x7FFF,
    ];
    for &o in &offsets_fb {
        p.write(BUFFER + o, fb_word(o, 0));
    }
    for &o in offsets_fb.iter().rev() {
        p.read(BUFFER + o);
    }
    p.write(BUFFER + 24, fb_word(24, 1));
    p.read(BUFFER + 24);
    p.read(BUFFER + 23);
    p.read(BUFFER + 25);
    p.read(ABOVE_WINDOW);
    p.write(BELOW_WINDOW, 0xFACE_FEED);
    p.read(BELOW_WINDOW);
    p.read(CONTROL); // and the mode register, 0o34, untouched by the buffer
    p.write(CONTROL, 0o14); // the interrupt down for the tests below

    // ---------------------------------------------------------------
    // Frames 9 to 12: -XBUS INIT.  Off the boundary with the interrupt up;
    // then on a boundary and a tick either side of one.
    // ---------------------------------------------------------------
    p.at(9 * f + 50_000);
    p.read(CONTROL); // 0o34: the interrupt is up
    p.at(9 * f + 60_000);
    p.init(); // the flag goes, the mode stands
    p.at(9 * f + 60_005);
    p.read(CONTROL); // 0o14
    p.read(CONTROL + 1); // the sync RAM and its enable stand: 0xA5
    p.at(9 * f + 70_000);
    p.write(CONTROL, 0o34); // the flag set again by a write: up
    p.at(10 * f - 1); // the tick before a boundary: down for one tick
    p.init();
    p.at(11 * f); // on one
    p.init();
    p.at(12 * f + 1); // the tick after one
    p.init();
    p.at(12 * f + 100);
    p.read(CONTROL); // 0o14 after the last init

    // ---------------------------------------------------------------
    // Frame 13: interleaving --- buffer and sync cycles while the flag is
    // up, then the frame with the enable off and the flag toggled by writes
    // alone.
    // ---------------------------------------------------------------
    p.at(13 * f + 3);
    p.write(BUFFER + 0x3000, fb_word(0x3000, 0));
    p.read(BUFFER + 0x3000);
    p.read(CONTROL + 1);
    p.read(CONTROL); // 0o34
    p.write(CONTROL, 0o24); // the enable off, the flag written SET: no interrupt
    p.read(CONTROL); // 0o24
    p.write(CONTROL, 0o4); // the flag written clear
    p.read(CONTROL); // 0o4
    p.write(CONTROL, 0o30); // the enable on with the flag set: up at once
    p.read(CONTROL); // 0o30
    p.write(CONTROL, 0o10); // and down

    // ---------------------------------------------------------------
    // Frame 15: a write landing one tick AFTER the boundary: up for a tick.
    // ---------------------------------------------------------------
    p.at(15 * f - 2000);
    p.read(CONTROL); // 0o30: frame 14's preset
    p.write(CONTROL, 0o10); // cleared, so that the boundary's preset is an edge
    p.read(CONTROL); // 0o10
    p.write_landing_at(15 * f + 1, CONTROL, 0o10);
    p.at(15 * f + 200);
    p.read(CONTROL); // 0o10

    // ---------------------------------------------------------------
    // Frame 25: a write landing ON the boundary.  The store wins.
    // ---------------------------------------------------------------
    p.at(25 * f - 2000);
    p.read(CONTROL); // 0o30
    p.write_landing_at(25 * f, CONTROL, 0o10);
    p.at(25 * f + 200);
    p.read(CONTROL); // 0o10: no frame has started since the write
    p.read(BUFFER + 0x7FFF); // the buffer still holds its word
    p.read(CONTROL + 1); // and the sync RAM its byte
    let end = 25 * f + 10_000;

    // ---------------------------------------------------------------
    // The run.
    // ---------------------------------------------------------------
    let mut bi = Busint::new(1);
    bi.device_ns = 0;
    let mut tv = SimpleTv::default();
    let mut main: BTreeMap<u32, u32> = BTreeMap::new();
    let mut fb_written: BTreeSet<u32> = BTreeSet::new();

    let mut ev = p.ev.into_iter().peekable();
    let mut cycle: u64 = 0;
    let mut memrq = false;
    let mut wrcyc = false;
    let mut phys: u32 = 0;
    let mut word: u32 = 0;
    let mut resp = Responder::Device;
    let mut release_at: Option<u64> = None;
    let mut next_ok: u64 = 0;
    let mut landed = true; // the current write has reached the model
    let mut read_done = true;
    let mut rdata: u32 = 0;
    let mut land_at: Option<u64> = None;

    // coverage
    let mut n_rows = 0u64;
    let mut reads = [0u64; 8];
    let mut writes = [0u64; 8];
    let mut fb_reads = 0u64;
    let mut fb_writes = 0u64;
    let mut main_reads = 0u64;
    let mut main_writes = 0u64;
    let mut nxm_cycles = 0u64;
    let mut inits = 0u64;
    let mut intr_rises = 0u64;
    let mut intr_falls = 0u64;
    let mut intr_was = false;
    let mut boundaries_with_intr_up = 0u64;

    let mut out: Vec<String> = Vec::with_capacity(1 << 16);
    let mut prev: Option<(u8, u8, u32, u32, u8, u8, u8, u8, u32, u8)> = None;

    for tick in 0..=end {
        let now = tick * TICK_NS;
        let mclk = tick % MICROCYCLE_TICKS == 0;
        let mut xinit = false;

        // The cpu lifts -MEMRQ MFINISHD_NS after the acknowledgement.
        if let Some(at) = release_at
            && now >= at
        {
            assert!(landed && read_done, "cycle {cycle} ended before its word moved");
            bi.released(at);
            bi.finish();
            release_at = None;
            memrq = false;
            next_ok = now + gap_ticks(cycle) * TICK_NS;
            cycle += 1;
        }

        // A write lands one tick after -XBUS.RQ: see the top.
        if memrq && wrcyc && !landed
            && let Some(answered) = bi.answered_at()
            && now == answered + TICK_NS
        {
            landed = true;
            if let Some(want) = land_at {
                assert_eq!(tick, want, "a write meant to land at tick {want} landed at {tick}");
            }
            if let Some(r) = which_register(phys) {
                tv.write_control(r, word, now);
            } else if let Some(off) = muir::simpletv::buffer_offset(phys) {
                tv.write_buffer(off, word);
                fb_written.insert(off);
            } else if resp == Responder::Device {
                main.insert(phys, word);
            }
        }
        // A read is made at the request's own instant.
        if memrq && !wrcyc && !read_done
            && let Some(answered) = bi.answered_at()
            && now == answered
        {
            read_done = true;
            rdata = if let Some(r) = which_register(phys) {
                let v = tv.read_control(r, now);
                if r == 0 {
                    // The flag must not move between muir's read and the
                    // fabric's strobe: see the top.
                    let ack = bi.ack_at().expect("a read has an acknowledgement");
                    assert_eq!(
                        tv.vert_flag(now),
                        tv.vert_flag(ack),
                        "tick {tick}: a frame begins inside the deskew of a mode-register read; move it"
                    );
                }
                v
            } else if let Some(off) = muir::simpletv::buffer_offset(phys) {
                assert!(fb_written.contains(&off), "tick {tick}: reading buffer word {off:#x} nothing wrote");
                tv.read_buffer(off)
            } else if resp == Responder::Device {
                *main.get(&phys).unwrap_or_else(|| panic!("tick {tick}: reading main {phys:#o} nothing wrote"))
            } else {
                0
            };
        }

        // The next event, if it is due and the bus is free.
        if !memrq && release_at.is_none() {
            if let Some(e) = ev.peek() {
                match e.op {
                    Op::Init if now >= e.at * TICK_NS => {
                        tv.xbus_init(now);
                        xinit = true;
                        inits += 1;
                        ev.next();
                    }
                    Op::Cycle { write, phys: a, wdata, land_at: land } if now >= (e.at * TICK_NS).max(next_ok) => {
                        wrcyc = write;
                        phys = a;
                        word = wdata;
                        let decoded = busint::decode(phys, MEMORY_WORDS as usize);
                        resp = match decoded {
                            Responder::NoXbus => Responder::NoXbus,
                            Responder::Device | Responder::Memory(_) => Responder::Device,
                            other => panic!("tick {tick}: {phys:#o} decodes as {other:?}, which this trace does not run"),
                        };
                        if let Some(r) = which_register(phys) {
                            if write { writes[r as usize] += 1 } else { reads[r as usize] += 1 }
                        } else if muir::simpletv::buffer_offset(phys).is_some() {
                            if write { fb_writes += 1 } else { fb_reads += 1 }
                        } else if resp == Responder::NoXbus {
                            nxm_cycles += 1;
                        } else if write {
                            main_writes += 1
                        } else {
                            main_reads += 1
                        }
                        landed = !write;
                        land_at = land;
                        read_done = write || resp == Responder::NoXbus;
                        rdata = 0;
                        bi.request(wrcyc);
                        memrq = true;
                        ev.next();
                    }
                    _ => {}
                }
            }
        }

        if mclk {
            bi.mclk_edge(now, resp);
        }

        let mut timed_out = false;
        if let Some(ack) = bi.poll(now, resp) {
            timed_out = ack.timed_out;
            if release_at.is_none() {
                release_at = Some(ack.at + MFINISHD_NS);
            }
        }

        let granted = bi.granted();
        let acked = bi.ack_at().is_some_and(|at| now >= at);
        let loadmd = bi.loadmd_at().is_some_and(|at| now >= at);
        let intr = tv.interrupt(now);
        if intr && !intr_was { intr_rises += 1 }
        if !intr && intr_was { intr_falls += 1 }
        if tick > 0 && tick % f == 0 && intr && intr_was { boundaries_with_intr_up += 1 }
        intr_was = intr;

        let b = |v: bool| u8::from(v);
        // What has to be the same at the next tick for no row to be written:
        // everything but MCLK, which the testbench makes from the grid itself
        // and only cross-checks against the column on the rows that are there.
        // `timed_out` moves only while the bus is busy, and every busy tick is
        // a row.
        let row = (
            b(!memrq), b(wrcyc), phys, word, b(xinit),
            b(!granted), b(!acked), b(!loadmd), rdata, b(intr),
        );
        let busy = memrq || release_at.is_some() || bi.busy();
        let changed = prev.is_none_or(|q| q != row);
        if tick == 0 || busy || changed || xinit {
            out.push(format!(
                "{tick} {} {} {} {} {} {} {} {} {} {} {} {}",
                row.0, row.1, row.2, row.3, b(mclk), row.4,
                row.5, row.6, row.7, b(timed_out), row.8, row.9
            ));
            n_rows += 1;
        }
        prev = Some(row);
    }
    assert!(ev.peek().is_none(), "the program did not finish: {} events left", ev.count());

    // Every one of the sync RAM's written bytes reads back through the trace
    // is a property of the program; assert the words are what the reference
    // model holds, so a change to `sync_byte` shows here.
    for &ptr in &pointers {
        assert_eq!(tv.sync.words()[ptr as usize] as u32, sync_byte(ptr));
    }
    assert!(intr_rises >= 12 && intr_falls >= 12, "too few interrupt edges: {intr_rises} up, {intr_falls} down");
    assert!(boundaries_with_intr_up >= 1, "no boundary presets a flag already set");
    assert_eq!(SYNC_RAM_WORDS, 4096);

    println!("# tick n_memrq wrcyc phys wdata mclk xinit | n_memgrant n_memack n_loadmd timed_out rdata intr");
    println!("# generated by golden/src/tv.rs from muir's simpletv::SimpleTv through busint::Busint");
    println!("# one row a tick wherever anything moves; between rows every column holds");
    println!("# every value decimal; rdata is the word MD takes on a read, 0 otherwise");
    println!("# frame_ns {FRAME_NS}");
    println!("# frame_ticks {FRAME_TICKS}");
    println!("# microcycle_ticks {MICROCYCLE_TICKS}");
    println!("# setup_ticks {SETUP_TICKS}");
    println!("# deskew_ticks {DESKEW_TICKS}");
    println!("# boards {BOARDS}");
    println!("# buffer {BUFFER}");
    println!("# buffer_words {BUFFER_WORDS}");
    println!("# control {CONTROL}");
    println!("# writable {}", mode::WRITABLE);
    println!("# last_tick {end}");
    println!("# frames {}", end / f);
    println!("# rows {n_rows}");
    println!("# cycles {cycle}");
    println!("# register_reads {} {} {} {} {} {} {} {}", reads[0], reads[1], reads[2], reads[3], reads[4], reads[5], reads[6], reads[7]);
    println!("# register_writes {} {} {} {} {} {} {} {}", writes[0], writes[1], writes[2], writes[3], writes[4], writes[5], writes[6], writes[7]);
    println!("# buffer_reads {fb_reads}");
    println!("# buffer_writes {fb_writes}");
    println!("# main_reads {main_reads}");
    println!("# main_writes {main_writes}");
    println!("# nxm_cycles {nxm_cycles}");
    println!("# inits {inits}");
    println!("# intr_rises {intr_rises}");
    println!("# intr_falls {intr_falls}");
    println!("# boundaries_with_intr_up {boundaries_with_intr_up}");
    for l in &out {
        println!("{l}");
    }
    eprintln!(
        "tv: {cycle} cycles over {end} ticks ({} frames), {n_rows} rows; interrupt up {intr_rises} times and down {intr_falls}; {inits} inits, {nxm_cycles} timeouts",
        end / f
    );
}
