// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the SECOND display board --- MIT's color TV,
//! muir's `tv::Tv::color()` --- on a backplane that also carries the first,
//! driven through muir's own `busint::Busint` in `golden/src/tv.rs`'s shape.
//!
//! **WHAT THE COLOR TV IS.**  `cadrtv/lmtv.order`: "Note: For the normal TV,
//! x is 6.  For the color TV, x is 5", so the board is a LISPM TV strapped
//! elsewhere --- `tv::COLOR_TV`, the frame buffer at `0o17200000` and the
//! eight control words at `0o17377750` --- with a color monitor on it.
//! `sys/window/color.lisp`'s `COLOR:MAKE-SCREEN` draws 576 by 454 at four
//! bits a pixel there, 72 words a line, each pixel an address into the
//! sixteen-entry color map register 4 writes.
//!
//! **WHY A TRACE OF ITS OWN AND NOT A COLUMN IN `tv.golden`.**  The two
//! boards are two machines as far as the bus is concerned: one backplane has
//! a second board and one has none, and `busint::decode_with` answers the
//! color ranges only on the first.  So `build/tv.pass` is the machine
//! `busint::decode` describes --- one display, which is every trace in this
//! repository and every check written before the second board was built ---
//! and this is the other one.
//!
//! **THE THREE THINGS THIS HOLDS THAT NOTHING ELSE CAN.**
//!
//! - **Two boards answer on one backplane and neither answers for the
//!   other.**  Every cycle here is decoded by muir and the trace carries
//!   which board gave the word, so a fabric whose second instance answered
//!   the first board's addresses, or whose first answered the second's,
//!   disagrees on the very first read.
//! - **The color map.**  It is write only on the bus --- `color.lisp` keeps
//!   `HARDWARE-COLOR-MAP` in the band because "the hardware does not allow
//!   reading back of the color map" --- so no bus cycle can check it and the
//!   trace carries the map muir holds in its header instead.  The testbench
//!   reads the fabric's own map port and compares all forty-eight bytes of
//!   each board.  **Both boards keep one**: the write strobes are the same
//!   circuit on each, measured on both netlists, so muir's model writes
//!   either and so does the fabric.
//! - **The vertical interrupt is the OR of two boards.**  `-XBUS.INTR` is
//!   open collector and every board on it pulls the one line, which is
//!   muir's `Machine::xbus_interrupt`.  The program raises the interrupt on
//!   the color board alone, then on the first board alone, then on both,
//!   and the column is compared at every tick.
//!
//! The columns, the instants and the rules are `golden/src/tv.rs`'s and that
//! file has the argument for each: a write lands one tick after `-XBUS.RQ`,
//! a read is made at the request's own instant, and a read of a mode
//! register may not straddle a `-TVMA CLR` or a sync-bit change or fall
//! inside the first instruction of a run.

use std::collections::{BTreeMap, BTreeSet};

use muir::busint::{self, Busint, MFINISHD_NS, Responder};
use muir::tv::{
    BUFFER_WORDS, CHANNELS, COLORS, COLOR_TV, CONTROL_WORDS, FRAME_NS, NORMAL_TV, Tv, mode, sync,
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

const SETUP_TICKS: u64 = busint::SETUP_NS / TICK_NS;
const DESKEW_TICKS: u64 = busint::XBUS_ACK_NS / TICK_NS;

/// The two straps, as addresses.
const C_BUFFER: u32 = COLOR_TV.buffer;
const C_CONTROL: u32 = COLOR_TV.control;
const N_BUFFER: u32 = NORMAL_TV.buffer;
const N_CONTROL: u32 = NORMAL_TV.control;

/// The edges of the color board's window, and the eight words between the
/// two boards' control blocks: Xbus space with nothing in it on either
/// backplane.
const C_ABOVE_WINDOW: u32 = C_BUFFER + BUFFER_WORDS;
const C_BELOW_WINDOW: u32 = C_BUFFER - 1;

/// A word for a frame-buffer offset, injective in the offset, in which
/// board's window it is and in how many times it has been written.
fn fb_word(board: u32, off: u32, nth: u32) -> u32 {
    (off.wrapping_mul(0x9E37_79B1) ^ nth.wrapping_mul(0x85EB_CA6B) ^ board.wrapping_mul(0x1000_0001)
        ^ 0x3C5A_7E11)
        .rotate_left((off ^ board) & 31)
}

/// A word of main memory, from another family.
fn main_word(phys: u32) -> u32 {
    phys.wrapping_mul(0xC2B2_AE35) ^ 0xA5A5_0F0F
}

/// The byte a color and a channel are given: injective in both and in the
/// board, none of them zero, and none of them all ones.
fn map_byte(board: u32, color: u32, channel: u32) -> u32 {
    let v = (color.wrapping_mul(0o23) ^ (channel << 5) ^ (board << 3) ^ 0o125) & 0xFF;
    if v == 0 || v == 0xFF { v ^ 0o52 } else { v }
}

/// The word register 4 takes: `lmtv.order`'s "15-8 Value to write into color
/// map, 7-6 Select which color map (up to 4 channels), 3-0 Color (i.e.
/// address into color map)".
fn color_word(color: u32, channel: u32, value: u32) -> u32 {
    (value << 8) | (channel << 6) | (color & 0o17)
}

#[derive(Clone, Copy)]
enum Op {
    Cycle { write: bool, phys: u32, wdata: u32 },
    Init,
    Pause(u64),
}

struct Event {
    at: u64,
    op: Op,
}

struct Prog {
    ev: Vec<Event>,
    cursor: u64,
}

impl Prog {
    fn at(&mut self, tick: u64) {
        assert!(tick >= self.cursor, "the program runs backwards: {} to {tick}", self.cursor);
        self.cursor = tick;
    }
    fn pause(&mut self, ticks: u64) {
        self.ev.push(Event { at: self.cursor, op: Op::Pause(ticks) });
    }
    fn read(&mut self, phys: u32) {
        self.ev.push(Event { at: self.cursor, op: Op::Cycle { write: false, phys, wdata: 0 } });
    }
    fn write(&mut self, phys: u32, wdata: u32) {
        self.ev.push(Event { at: self.cursor, op: Op::Cycle { write: true, phys, wdata } });
    }
    fn init(&mut self) {
        self.ev.push(Event { at: self.cursor, op: Op::Init });
    }
}

fn gap_ticks(cycle: u64) -> u64 {
    [1, 2, 3, 7, 13, 29, 31][(cycle % 7) as usize]
}

/// Which board and which register an address names, if it is a control word.
fn which_register(phys: u32) -> Option<(bool, u32)> {
    if let Some(r) = NORMAL_TV.control_register(phys) {
        return Some((false, r));
    }
    COLOR_TV.control_register(phys).map(|r| (true, r))
}

fn main() {
    assert_eq!(FRAME_NS % TICK_NS, 0, "FRAME_NS is not on the 5 ns grid");
    assert_eq!(FRAME_TICKS, 3_091_200);
    assert_eq!(CONTROL_WORDS, 8);
    assert_eq!(COLORS, 16);
    assert_eq!(CHANNELS, 3);
    // The two straps, out of muir rather than transcribed.
    assert_eq!(C_BUFFER, 0o17200000);
    assert_eq!(C_CONTROL, 0o17377750);
    // **AND THE TWO BOARDS DO NOT OVERLAP ANYWHERE**, which is what lets one
    // `device` line carry both: the eight words below the first board's
    // control block are the second's, and the two windows are two of the
    // sixty-four 32,768-word slots.
    for a in [C_BUFFER, C_BUFFER + BUFFER_WORDS - 1, C_CONTROL, C_CONTROL + CONTROL_WORDS - 1] {
        assert!(NORMAL_TV.buffer_offset(a).is_none() && NORMAL_TV.control_register(a).is_none());
    }

    let f = FRAME_TICKS;
    let mut p = Prog { ev: Vec::new(), cursor: 200 };

    // ---------------------------------------------------------------
    // The two faces at power-on, each board reading its own registers.
    // ---------------------------------------------------------------
    for r in 0..CONTROL_WORDS {
        p.read(C_CONTROL + r);
    }
    for r in 0..CONTROL_WORDS {
        p.read(N_CONTROL + r);
    }
    // The eight words between the two control blocks --- `0o17377740` --- and
    // the four above the first board's, which are the disk's and not this
    // check's; only the eight below are read here.
    p.read(C_CONTROL - 8);
    p.read(C_CONTROL - 1);
    p.write(C_CONTROL - 4, 0xDEAD_BEEF);

    // ---------------------------------------------------------------
    // **`COLOR-EXISTS-P`**, which is how System 100 finds out it has the
    // board: `sys/window/color.lisp` writes into the first buffer word with
    // the error stop off and reads it back.  Here it reads back, because the
    // board is fitted; configuration B of the testbench is the same two
    // cycles on a backplane with none, where they must time out.
    // ---------------------------------------------------------------
    p.write(C_BUFFER, 1);
    p.read(C_BUFFER);

    // ---------------------------------------------------------------
    // The color map, register 4 on both boards.  Write only: nothing here
    // reads one back, and the header carries what muir holds.
    // ---------------------------------------------------------------
    for color in 0..COLORS as u32 {
        for channel in 0..CHANNELS as u32 {
            p.write(C_CONTROL + 4, color_word(color, channel, map_byte(1, color, channel)));
        }
    }
    // **A WRITE NAMING THE FOURTH CHANNEL STROBES NOTHING**: the 74S139 at
    // 0E10 decodes `XDI7` and `XDI6` into three write strobes and leaves its
    // fourth output unconnected.  Written with a value no entry has, so a
    // fabric that took it would show in the map.
    p.write(C_CONTROL + 4, color_word(5, 3, 0o333));
    // **AND THE COLOR IS FOUR BITS.**  `lmtv.order` gives it 3-0 and
    // `WRITE-COLOR-MAP` writes `(LOGAND LOC 17)`; `XDI4` and `XDI5` leave the
    // board on `COLOR 4` and `COLOR 5`, where a 64-entry map would take them
    // as address, and what an off-board map does with them is unverified.
    // muir masks them off and so does the fabric, so this write lands on
    // color 3 and the read-back of the map says so.
    p.write(C_CONTROL + 4, 0o60 << 0 | color_word(3, 1, map_byte(1, 3, 1)) | 0o60);
    // Three entries of the FIRST board's map, which nothing in MIT's
    // software ever writes and which muir keeps all the same.
    for color in [0u32, 7, 15] {
        for channel in 0..CHANNELS as u32 {
            p.write(N_CONTROL + 4, color_word(color, channel, map_byte(0, color, channel)));
        }
    }
    p.read(C_CONTROL + 4); // write only: zero
    p.read(N_CONTROL + 4); // and on the other board too

    // ---------------------------------------------------------------
    // The color board's frame buffer: across the window, its two edges, and
    // the words just outside it, which nothing answers on either backplane.
    // The offsets reach past the picture's own 32,688 words, because the
    // board answers all 32,768 whatever the picture uses.
    // ---------------------------------------------------------------
    let offsets: Vec<u32> = vec![
        0, 1, 2, 71, 72, 73, 0x0100, 0x1000, 0x2AAA, 0x4000, 0x5555, 0x7FAF, 0x7FB0, 0x7FFE, 0x7FFF,
    ];
    for &o in &offsets {
        p.write(C_BUFFER + o, fb_word(1, o, 0));
    }
    for &o in offsets.iter().rev() {
        p.read(C_BUFFER + o);
    }
    p.write(C_BUFFER + 72, fb_word(1, 72, 1));
    p.read(C_BUFFER + 72);
    p.read(C_BUFFER + 71);
    p.read(C_BUFFER + 73);
    p.read(C_ABOVE_WINDOW);
    p.write(C_BELOW_WINDOW, 0xFACE_FEED);
    p.read(C_BELOW_WINDOW);

    // **AND THE FIRST BOARD'S WINDOW, ON THE SAME BACKPLANE AND AT THE SAME
    // OFFSETS**, so that a fabric answering one window out of the other's
    // memory reads back the wrong word rather than agreeing.  The words are
    // injective in the board.
    for &o in &offsets {
        p.write(N_BUFFER + o, fb_word(0, o, 0));
    }
    for &o in offsets.iter().rev() {
        p.read(N_BUFFER + o);
    }
    for &o in &offsets {
        p.read(C_BUFFER + o);
    }

    // A few words of main memory, so the bridge's third base is in the trace.
    for &a in &[0u32, 0o777, 2_031_617] {
        p.write(a, main_word(a));
    }
    for &a in &[0u32, 0o777, 2_031_617] {
        p.read(a);
    }

    // ---------------------------------------------------------------
    // The two boards' register faces, apart.  A write of one board's mode
    // register may not move the other's, and the sync programs are two.
    // ---------------------------------------------------------------
    p.write(C_CONTROL, 0o4); // BOW on the color board; clock mode 0 unchanged
    p.pause(150);
    p.read(C_CONTROL);
    p.read(N_CONTROL); // and the first board untouched
    p.write(N_CONTROL, 0o1); // clock mode 1 on the first board: a restart
    p.pause(150);
    p.read(N_CONTROL);
    p.read(C_CONTROL); // and the color board untouched
    // The sync program RAM.  **A PROGRAM IS LOADED INTO EACH BEFORE EITHER
    // IS SELECTED**, as MIT's software loads one --- `color.lisp` calls
    // `SI:STOP-SYNC`, `SI:FILL-SYNC` and `SI:START-SYNC` in that order ---
    // and for `golden/src/tv.rs`'s own reason: an empty RAM is a program
    // that makes no frame, which muir calls dead at the restart and a
    // clocked generator finds out by fetching.  The program is a loop of two
    // carrying no special function but its End of Program, so it makes a
    // frame and never presets the vertical flag, which leaves the flag
    // entirely to the writes below.
    p.write(C_CONTROL + 2, 0o17); // the pointer
    p.read(C_CONTROL + 1); // MIT's PROM's word at 0o17
    p.write(C_CONTROL + 1, 0xFFFF_FF5A); // into the RAM at the pointer
    p.read(C_CONTROL + 1); // still the PROM's: the RAM is not selected
    p.read(N_CONTROL + 1); // and the first board's pointer is its own, zero
    for board in [C_CONTROL, N_CONTROL] {
        for (ptr, byte) in [(0u32, 2u32), (1, 0), (2, 0o300), (3, 0)] {
            p.write(board + 2, ptr);
            p.write(board + 1, byte);
        }
    }
    p.write(C_CONTROL + 2, 0o17);
    // **AND BIT 7 OF THE MODE REGISTER, THE TWO BOARDS SIDE BY SIDE.**  The
    // color board is a LISPM TV whatever the first board is --- `Tv::color`
    // is one --- so it reads the sync enable back through the 74LS244 at
    // XBCTL 0F11; the first board here is a SIMPLE TV and the same pin is
    // ground, by ECO 2 of `cadrtv/lmtv.eco`.  So the two are read with the
    // enable on, on one backplane, and they differ.
    //
    // The mode register is written with bit 4 clear immediately before each
    // enable write, because muir's restart forgets the fields counted before
    // it where the board's flop keeps them: the flag has to be down when a
    // restart lands.
    p.write(C_CONTROL, 0o4);
    p.write(C_CONTROL + 3, 0x80 | 0o65); // the RAM selected on the color board
    p.pause(150);
    p.read(C_CONTROL); // 0o204: the enable read back
    p.read(C_CONTROL + 1); // 0x5A, the RAM's word at the pointer
    p.write(N_CONTROL, 0o1);
    p.write(N_CONTROL + 3, 0x80 | 0o65); // and on the first board
    p.pause(150);
    p.read(N_CONTROL); // 0o1: ground, whatever the enable is

    // ---------------------------------------------------------------
    // **`-XBUS.INTR` IS THE OR OF TWO BOARDS.**  The color board's
    // interrupt alone, then the first board's alone, then both, then
    // neither.  The flag is written set by the write itself, so each edge is
    // at a known instant and the column is compared at every tick between
    // them.
    // ---------------------------------------------------------------
    p.at(f + 100_000);
    p.write(C_CONTROL, 0o34); // the color board: INTR ENB and the flag set
    p.read(C_CONTROL); // and the interrupt is up
    p.write(C_CONTROL, 0o14); // the flag cleared: down
    p.write(N_CONTROL, 0o35); // the first board, clock mode 1 kept
    p.read(N_CONTROL); // up again, from the other board
    p.write(C_CONTROL, 0o34); // and both at once
    p.write(N_CONTROL, 0o15); // the first board down, the color board still up
    p.read(C_CONTROL);
    p.write(C_CONTROL, 0o14); // and now neither
    p.read(C_CONTROL);

    // ---------------------------------------------------------------
    // `-XBUS INIT` is a bused line and reaches every board on it.  Both
    // flags are set by writes, one pulse, and both go.
    // ---------------------------------------------------------------
    p.at(f + 200_000);
    p.write(C_CONTROL, 0o34);
    p.write(N_CONTROL, 0o35);
    p.read(C_CONTROL);
    p.read(N_CONTROL);
    p.init();
    p.at(f + 210_000);
    p.read(C_CONTROL); // 0o14
    p.read(N_CONTROL); // 0o15
    p.read(C_CONTROL + 1); // the sync RAM and its enable survived the reset

    // ---------------------------------------------------------------
    // And the color board's own `-TVMA CLR`, two whole frames of it with
    // nothing else on the bus: the one place the color board's sync
    // program is compared tick by tick.  MIT's PROM is selected again for
    // it --- the loaded program has no `-TVMA CLR` in it at all --- and the
    // first board's interrupt is turned off, so every edge past here is the
    // color board's.
    // ---------------------------------------------------------------
    p.at(f + 300_000);
    p.write(N_CONTROL, 0o1); // the first board's interrupt off
    p.write(C_CONTROL, 0o14); // INTR ENB on the color board, the flag clear
    p.write(C_CONTROL + 3, 0o65); // the enable off: MIT's PROM, and a restart
    p.pause(150);
    p.read(C_CONTROL); // 0o14: no preset yet, 16,000 ns into the run
    let end = p.cursor + 2 * f;

    // ---------------------------------------------------------------
    // The run.
    // ---------------------------------------------------------------
    let mut bi = Busint::new(1);
    bi.device_ns = 0;
    let mut tv = Tv::default();
    let mut ctv = Tv::color();
    let mut main: BTreeMap<u32, u32> = BTreeMap::new();
    let mut fb_written: BTreeSet<(bool, u32)> = BTreeSet::new();

    let mut ev = p.ev.into_iter().peekable();
    let mut cycle: u64 = 0;
    let mut memrq = false;
    let mut wrcyc = false;
    let mut phys: u32 = 0;
    let mut word: u32 = 0;
    let mut resp = Responder::Device;
    let mut release_at: Option<u64> = None;
    let mut next_ok: u64 = 0;
    let mut landed = true;
    let mut read_done = true;
    let mut rdata: u32 = 0;

    // coverage
    let mut n_rows = 0u64;
    let mut c_reg_reads = [0u64; 8];
    let mut c_reg_writes = [0u64; 8];
    let mut n_reg_reads = 0u64;
    let mut n_reg_writes = 0u64;
    let mut c_fb_reads = 0u64;
    let mut c_fb_writes = 0u64;
    let mut n_fb_reads = 0u64;
    let mut n_fb_writes = 0u64;
    let mut main_reads = 0u64;
    let mut main_writes = 0u64;
    let mut nxm_cycles = 0u64;
    let mut inits = 0u64;
    let mut intr_rises = 0u64;
    let mut intr_falls = 0u64;
    let mut intr_was = false;
    // Ticks the two boards disagreed about the interrupt: what says the OR
    // is an OR and not one board's line.
    let mut only_color = 0u64;
    let mut only_normal = 0u64;
    let mut both = 0u64;

    let mut out: Vec<String> = Vec::with_capacity(1 << 16);
    let mut prev: Option<(u8, u8, u32, u32, u8, u8, u8, u8, u32, u8)> = None;

    for tick in 0..=end {
        let now = tick * TICK_NS;
        let mclk = tick % MICROCYCLE_TICKS == 0;
        let mut xinit = false;

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

        // A write lands one tick after `-XBUS.RQ`: `golden/src/tv.rs` has the
        // argument.
        if memrq && wrcyc && !landed
            && let Some(answered) = bi.answered_at()
            && now == answered + TICK_NS
        {
            landed = true;
            if let Some((color, r)) = which_register(phys) {
                let board = if color { &mut ctv } else { &mut tv };
                let will_restart = match r {
                    0 => (word ^ board.mode()) & mode::CLOCK != 0,
                    1 => board.sync.enabled(),
                    3 => ((word as u8) & 0o200 != 0) != board.sync.enabled(),
                    _ => false,
                };
                assert!(
                    !(will_restart && r != 0 && board.vert_flag(now)),
                    "tick {tick}: the write of register {r} restarts a sync program with the \
                     vertical flag standing, and muir's restart forgets it where the board's flop \
                     keeps it; clear the flag first"
                );
                board.write_control(r, word, now);
                assert!(
                    board.timeline().is_some(),
                    "tick {tick}: the write left a program that makes no frame standing"
                );
            } else if let Some(off) = COLOR_TV.buffer_offset(phys) {
                ctv.write_buffer(off, word);
                fb_written.insert((true, off));
            } else if let Some(off) = NORMAL_TV.buffer_offset(phys) {
                tv.write_buffer(off, word);
                fb_written.insert((false, off));
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
            rdata = if let Some((color, r)) = which_register(phys) {
                let board = if color { &ctv } else { &tv };
                let v = board.read_control(r, now);
                if r == 0 {
                    let ack = bi.ack_at().expect("a read has an acknowledgment");
                    assert_eq!(
                        board.vert_flag(now),
                        board.vert_flag(ack),
                        "tick {tick}: a -TVMA CLR falls inside the deskew of a mode-register read"
                    );
                    assert_eq!(
                        board.sync_at(now),
                        board.sync_at(ack),
                        "tick {tick}: VSYNC or HSYNC moves inside the deskew of a mode-register read"
                    );
                    let step = sync::INSTRUCTION_NS[(board.mode() & mode::CLOCK) as usize];
                    assert!(
                        now >= board.origin() + step,
                        "tick {tick}: a mode-register read inside the first instruction of a run, \
                         where muir's sync bits are its guess at what the program leaves behind"
                    );
                }
                v
            } else if let Some(off) = COLOR_TV.buffer_offset(phys) {
                assert!(fb_written.contains(&(true, off)), "tick {tick}: reading color word {off:#x} nothing wrote");
                ctv.read_buffer(off)
            } else if let Some(off) = NORMAL_TV.buffer_offset(phys) {
                assert!(fb_written.contains(&(false, off)), "tick {tick}: reading window word {off:#x} nothing wrote");
                tv.read_buffer(off)
            } else if resp == Responder::Device {
                *main.get(&phys).unwrap_or_else(|| panic!("tick {tick}: reading main {phys:#o} nothing wrote"))
            } else {
                0
            };
        }

        if !memrq && release_at.is_none() {
            if let Some(e) = ev.peek() {
                match e.op {
                    Op::Pause(t) if now >= e.at * TICK_NS => {
                        next_ok = now + t * TICK_NS;
                        ev.next();
                    }
                    Op::Init if now >= e.at * TICK_NS => {
                        // A bused line: every board on it takes the pulse.
                        tv.xbus_init(now);
                        ctv.xbus_init(now);
                        xinit = true;
                        inits += 1;
                        ev.next();
                    }
                    Op::Cycle { write, phys: a, wdata } if now >= (e.at * TICK_NS).max(next_ok) => {
                        wrcyc = write;
                        phys = a;
                        word = wdata;
                        // **THE BACKPLANE HAS THE SECOND BOARD**, which is
                        // `decode_with`'s own argument and the whole
                        // difference between this trace and `tv.golden`.
                        let decoded = busint::decode_with(phys, MEMORY_WORDS as usize, true);
                        resp = match decoded {
                            Responder::NoXbus => Responder::NoXbus,
                            Responder::Device | Responder::Memory(_) => Responder::Device,
                            other => panic!("tick {tick}: {phys:#o} decodes as {other:?}, which this trace does not run"),
                        };
                        if let Some((color, r)) = which_register(phys) {
                            if color {
                                if write { c_reg_writes[r as usize] += 1 } else { c_reg_reads[r as usize] += 1 }
                            } else if write {
                                n_reg_writes += 1
                            } else {
                                n_reg_reads += 1
                            }
                        } else if COLOR_TV.buffer_offset(phys).is_some() {
                            if write { c_fb_writes += 1 } else { c_fb_reads += 1 }
                        } else if NORMAL_TV.buffer_offset(phys).is_some() {
                            if write { n_fb_writes += 1 } else { n_fb_reads += 1 }
                        } else if resp == Responder::NoXbus {
                            nxm_cycles += 1;
                        } else if write {
                            main_writes += 1
                        } else {
                            main_reads += 1
                        }
                        landed = !write;
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
        // `Machine::xbus_interrupt`: the two boards' lines on the one
        // open-collector wire.
        let ci = ctv.interrupt(now);
        let ni = tv.interrupt(now);
        let intr = ci || ni;
        if ci && ni { both += 1 } else if ci { only_color += 1 } else if ni { only_normal += 1 }
        if intr && !intr_was { intr_rises += 1 }
        if !intr && intr_was { intr_falls += 1 }
        intr_was = intr;

        let b = |v: bool| u8::from(v);
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
    // The last rise is the color board's own `-TVMA CLR` at the end and
    // nothing clears it, so there is one fall fewer than there are rises.
    assert!(intr_rises >= 4, "too few interrupt rises: {intr_rises}");
    assert_eq!(intr_falls, intr_rises - 1, "the trace does not end with the interrupt up");
    // The OR has to be an OR: each board alone, and the two together.
    assert!(only_color > 0, "the color board never raised the interrupt alone");
    assert!(only_normal > 0, "the first board never raised the interrupt alone");
    assert!(both > 0, "the two boards never raised the interrupt together");
    // The map has to have been reached: every color and every channel of
    // the color board's, and three colors of the first board's.
    for color in 0..COLORS {
        for channel in 0..CHANNELS {
            assert_eq!(
                ctv.color_map()[color][channel] as u32,
                map_byte(1, color as u32, channel as u32),
                "the color board's map at {color}/{channel}"
            );
        }
    }
    assert!(tv.color_map()[7][1] != 0, "the first board's map was never written");

    println!("# tick n_memrq wrcyc phys wdata mclk xinit | n_memgrant n_memack n_loadmd timed_out rdata intr");
    println!("# generated by golden/src/color_tv.rs from muir's tv::Tv::color() through busint::Busint");
    println!("# one row a tick wherever anything moves; between rows every column holds");
    println!("# every value decimal; rdata is the word MD takes on a read, 0 otherwise");
    println!("# frame_ns {FRAME_NS}");
    println!("# frame_ticks {FRAME_TICKS}");
    println!("# microcycle_ticks {MICROCYCLE_TICKS}");
    println!("# setup_ticks {SETUP_TICKS}");
    println!("# deskew_ticks {DESKEW_TICKS}");
    println!("# boards {BOARDS}");
    println!("# color_buffer {C_BUFFER}");
    println!("# color_control {C_CONTROL}");
    println!("# buffer {N_BUFFER}");
    println!("# control {N_CONTROL}");
    println!("# buffer_words {BUFFER_WORDS}");
    // The two maps as the machine holds them, `[color][channel]` with red
    // first: forty-eight bytes a board, the first board's then the color
    // board's.  The testbench reads the fabric's own map port and compares
    // every one of them.
    for (what, m) in [("normal", tv.color_map()), ("color", ctv.color_map())] {
        for (color, guns) in m.iter().enumerate() {
            println!("# map_{what} {color} {} {} {}", guns[0], guns[1], guns[2]);
        }
    }
    println!("# last_tick {end}");
    println!("# rows {n_rows}");
    println!("# cycles {cycle}");
    println!("# color_register_reads {} {} {} {} {} {} {} {}", c_reg_reads[0], c_reg_reads[1], c_reg_reads[2], c_reg_reads[3], c_reg_reads[4], c_reg_reads[5], c_reg_reads[6], c_reg_reads[7]);
    println!("# color_register_writes {} {} {} {} {} {} {} {}", c_reg_writes[0], c_reg_writes[1], c_reg_writes[2], c_reg_writes[3], c_reg_writes[4], c_reg_writes[5], c_reg_writes[6], c_reg_writes[7]);
    println!("# normal_register_reads {n_reg_reads}");
    println!("# normal_register_writes {n_reg_writes}");
    println!("# color_buffer_reads {c_fb_reads}");
    println!("# color_buffer_writes {c_fb_writes}");
    println!("# buffer_reads {n_fb_reads}");
    println!("# buffer_writes {n_fb_writes}");
    println!("# main_reads {main_reads}");
    println!("# main_writes {main_writes}");
    println!("# nxm_cycles {nxm_cycles}");
    println!("# inits {inits}");
    println!("# intr_rises {intr_rises}");
    println!("# intr_falls {intr_falls}");
    println!("# intr_only_color {only_color}");
    println!("# intr_only_normal {only_normal}");
    println!("# intr_both {both}");
    for l in &out {
        println!("{l}");
    }
    eprintln!(
        "color_tv: {cycle} cycles over {end} ticks, {n_rows} rows; the interrupt up {intr_rises} times, \
         {only_color} ticks from the color board alone and {only_normal} from the first; {nxm_cycles} timeouts"
    );
}
