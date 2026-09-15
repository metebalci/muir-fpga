// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the display controller --- MIT's TV, muir's
//! `tv::Tv` --- driven register by register through muir's own
//! `busint::Busint`, in the shape `busint_xbus.rs` drives the bus interface.
//!
//! **THE SYNC PROGRAM IS RUN, ON BOTH SIDES, SINCE `bfba7f3`.**  Two of this
//! trace's columns are the program's: `rdata` on the mode register, whose
//! bits 5 and 6 are the program's own `VSYNC` and `HSYNC`, and `intr`, whose
//! rises are where the program's `-TVMA CLR` falls --- which is 16,000 ns
//! into a run of MIT's `cpt.prom` and not the frame boundary.  A run starts
//! where the program is restarted, so this trace PINS that instant and works
//! its `-TVMA CLR`s out from it; see `ORIGIN_T` below.
//!
//! **ONE PROGRAM, TWO BOARDS.**  muir has one display model and `--tv-board`
//! says which board it is playing; this takes the same word as its argument
//! and writes the board into the header, and `tb/cadr_tv_tb.cpp` reads it
//! back and straps the fabric to match.  The two boards differ in ONE bit a
//! bus cycle can see --- mode bit 7, `SYNC PROM ENB`, which the LISPM TV
//! reads the sync enable back through and the SIMPLE TV grounds by ECO 2 of
//! `cadrtv/lmtv.eco` --- so the two traces are the same program and part only
//! on reads of the mode register with the sync RAM selected.  The last
//! section is three such reads, put there so that the bit is exercised
//! deliberately rather than by accident of what the rest of the program
//! happened to leave the enable at.
//!
//! **What muir's TV is.**  `src/tv.rs`: a 32,768-word frame buffer at
//! `BUFFER` (`0o17000000`), eight control words at `CONTROL` (`0o17377760`),
//! and a vertical flag.  Register 0 is the mode register: four writable bits
//! (`CLOCK<1:0>`, `BOW`, `INTR ENB`), bit 4 the vertical flag --- a flop of
//! its own, **preset by the sync program's `-TVMA CLR`**, which for
//! `cpt.prom` in clock mode 0 is 16,000 ns into a run and once every
//! [`FRAME_NS`] thereafter, and **clocked by a write of the register with
//! the written bit 4 as its data** --- and bit 7 reads as zero because the
//! board grounds it, while bits 5 and 6 are the sync program's own `VSYNC`
//! and `HSYNC`.
//! Registers 1 to 3 are the sync program RAM's data, pointer and enable;
//! register 4 is the Color register, whose map is not on the board; and only
//! 5 to 7 "respond but don't do anything".  `SEND INTR`, what the board puts
//! on `-XBUS.INTR`, is the flag with the enable up.  The device answers in no
//! time of its own (`IDEAL_DEVICE_NS`), so a read acknowledges 140 ns after
//! the grant and a write at 80, exactly as the disk's registers do.
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
//!   Two things can move in between: the vertical flag, at a `-TVMA CLR`,
//!   and the two sync bits, at any instruction boundary --- so the generator
//!   refuses to place a read of the mode register with either inside those
//!   twelve ticks.  The board reads both live through the 74LS244 at NXBCTL
//!   0F11, so where they differ the fabric is the board and muir samples
//!   early; the trace simply never asks.  That is one assert, at the read.
//!   A read inside the first instruction of a run used to be refused too,
//!   because `Timeline::sync_at` answered the bits the program leaves at the
//!   END of a run where the board's register holds what it held;
//!   `Timeline::sync_at_since_start` answers the held bits now and the
//!   refusal is gone, though nothing places such a read yet.
//! - `-XBUS INIT` is a stimulus column: the tick it is up is the tick the
//!   flag clears, and muir's `xbus_init(ns)` is called at that instant.
//!
//! **Every instant is on MIT's 5 ns grid and nothing is rounded.**  A sync
//! instruction is 500 ns in clock modes 0 and 1 and 625 in 2 and 3, which is
//! 100 and 125 ticks exactly; [`FRAME_NS`] is 3,091,200 ticks; so the
//! fabric's generator and muir's timeline never drift and no pre-roll is
//! needed --- unlike the disk's spindle, whose revolution is coprime with
//! five.
//!
//! **The store beats the preset, and the preset beats nothing else.**  A
//! write landing on the very tick a `-TVMA CLR` falls: muir's `written_at`
//! is that instant and `vert_flag` asks for a field *strictly* since, so the
//! written bit stands.  Reaching that tick needs the grant edge, the setup
//! and the landing tick to add up to the preset's own instant, and the
//! arithmetic at `ORIGIN_T` below says the three cases --- one tick before a
//! preset, on one, and one tick after --- are first reachable at the
//! twenty-sixth, sixteenth and sixth preset.  **That is why the trace is
//! twenty-seven frames long.**  `-XBUS INIT` is not tied to the master clock
//! and is put on a preset and either side of one directly.
//!
//! **And the sync RAM is loaded and selected at the END**, after all three,
//! because every write in that section restarts the program and moves the
//! instant the presets fall.  Up to there the program is MIT's PROM with one
//! known origin.
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
use muir::tv::{
    BUFFER, BUFFER_WORDS, Board, CONTROL, CONTROL_WORDS, FRAME_NS, SYNC_RAM_WORDS, Tv, mode, sync,
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
    /// Ticks of quiet before the next cycle may begin, measured from the end
    /// of the last one.
    Pause(u64),
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
    /// Room for the sync program to reach its next instruction boundary: a
    /// read of the mode register inside the first instruction of a run reads
    /// sync bits muir has guessed, so a write that restarts the program is
    /// followed by one of these before the register is read back.  125 ticks
    /// is the longest instruction, clock modes 2 and 3; this is more.
    fn pause(&mut self, ticks: u64) {
        self.ev.push(Event { at: self.cursor, op: Op::Pause(ticks) });
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
    muir::tv::control_register(phys)
}

fn main() {
    // Which board this trace is of, `--tv-board`'s own two words.
    let board = match std::env::args().nth(1).as_deref() {
        None | Some("simple-tv") => Board::SimpleTv,
        Some("lispm-tv") => Board::LispmTv,
        Some(other) => panic!("tv: `{other}` is not a board; simple-tv or lispm-tv"),
    };

    assert_eq!(FRAME_NS % TICK_NS, 0, "FRAME_NS is not on the 5 ns grid");
    assert_eq!(FRAME_TICKS, 3_091_200);
    assert_eq!(FRAME_TICKS % MICROCYCLE_TICKS, 3, "the boundary arithmetic below assumes a frame is 3 mod 29 ticks");
    assert_eq!(CONTROL_WORDS, 8);

    let f = FRAME_TICKS;

    // **WHERE THE SYNC PROGRAM'S `-TVMA CLR` FALLS, AND WHY THE TRACE IS AS
    // LONG AS IT IS.**  The vertical flag's preset is not the frame boundary
    // any more: it is `TVMA_CLR_NS` into a run of MIT's `cpt.prom` in clock
    // mode 0, and once a frame thereafter.  A run starts where the program
    // is restarted, so the trace pins that instant --- `ORIGIN_T`, the tick
    // frame 1's clock-mode write lands at --- and the presets are then
    // arithmetic.
    //
    // A write can only LAND on ticks the grant reaches: `write_landing_at`
    // needs `tick - SETUP_TICKS - 1` on a master clock edge, which is
    // `tick == 17 (mod 29)`.  `ORIGIN_T` is one of those, so every preset is
    // `27 + 3k (mod 29)`, and the three instants a store has to be put at
    // --- one tick before a preset, on one, and one tick after --- are
    // reachable at `k = 26`, `16` and `6` and at no smaller k.  **That is
    // why the trace runs to twenty-seven frames**: the `before` case is the
    // twenty-sixth preset and there is no earlier one it can be placed at.
    const ORIGIN_T: u64 = 3_091_330;
    // `sync::prom()` in clock mode 0: 32 instructions of 500 ns.
    const TVMA_CLR_T: u64 = 3_200;
    let preset = |k: u64| ORIGIN_T + TVMA_CLR_T + k * f;
    assert_eq!(ORIGIN_T % MICROCYCLE_TICKS, 17, "the origin is not a tick a store can land on");
    for (k, want) in [(6u64, 1i64), (16, 0), (26, -1)] {
        let tick = (preset(k) as i64 + want) as u64;
        assert_eq!(
            (tick - SETUP_TICKS - 1) % MICROCYCLE_TICKS,
            0,
            "a store cannot be placed at {want:+} ticks of preset {k}"
        );
    }

    // **THE PROGRAM STARTS AFTER THE SYNC PROGRAM'S FIRST INSTRUCTION**, at
    // 500 ns, because a read of the mode register before it is a read of
    // sync bits muir has guessed --- the assert at the read says why.  It
    // cost the trace's first seventy ticks and nothing else.
    let mut p = Prog { ev: Vec::new(), cursor: 80 };

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
    p.pause(150); // the clock mode moved, so the sync program restarted
    p.read(CONTROL);
    p.write(CONTROL, 0o37); // mode 0o17, the flag SET by the write: -XBUS.INTR up
    p.pause(150); // and again: 0o17 is clock mode 3, where an instruction is 125 ticks
    p.read(CONTROL);
    p.write(CONTROL, 0o17); // the flag cleared: down again
    p.read(CONTROL);
    // **AND THEN WAIT FOR CLOCK MODE 3'S OWN `-TVMA CLR`.**  The write above
    // restarted the program in clock mode 3, where an instruction is 625 ns
    // and `cpt.prom`'s `-TVMA CLR` falls 20,000 ns in rather than 16,000.
    // With `MODE INTR ENB` standing, that preset raises -XBUS.INTR at an
    // instant only the slow rate puts there --- which is the one thing in
    // the trace that tells the two rates apart, and `MODE<1:0>` is otherwise
    // a number the register hands back.
    p.pause(4_500);
    p.read(CONTROL); // 0o37: the flag set by the slow rate's preset
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
    // Frame 1: the preset with the enable off, and **THE INSTANT THE SYNC
    // PROGRAM'S ORIGIN IS PINNED TO**.
    //
    // Everything below that has to land on a `-TVMA CLR` needs to know where
    // one falls, and where one falls is the program's start plus 16,000 ns
    // and a frame thereafter.  The start is where this write lands, because
    // it changes `CLOCK MODE<1:0>` from 3 back to 0; so the write is placed
    // at an exact tick and nothing between here and the sync RAM section at
    // the end restarts the program again.
    // ---------------------------------------------------------------
    p.at(ORIGIN_T - 2_000);
    p.read(CONTROL); // 0o27
    // BOW and INTR ENB; the flag cleared by the write; the program restarted.
    p.write_landing_at(ORIGIN_T, CONTROL, 0o14);
    p.pause(150); // past the first instruction of the run it just started
    p.read(CONTROL); // 0o14: no interrupt until the next -TVMA CLR

    // ---------------------------------------------------------------
    // Frames 2 to 5: the microcode's INTRX0 --- read the register, find
    // bit 4, write it back clear --- at four offsets into the frame: a
    // tick, a microcycle, deep into the frame, and just before the next.
    // ---------------------------------------------------------------
    let offsets = [1u64, 29, 100_017, f / 2];
    for (k, off) in (2u64..).zip(offsets) {
        p.at(k * f + off);
        p.read(CONTROL); // 0o34
        p.write(CONTROL, 0o14); // and the interrupt falls with the landing
    }

    // ---------------------------------------------------------------
    // A write landing one tick AFTER a `-TVMA CLR`: the flag is up for a
    // tick and the write takes it down.
    // ---------------------------------------------------------------
    p.at(preset(6) - 2_000);
    p.read(CONTROL); // 0o14: the last INTRX0 cleared it
    p.write(CONTROL, 0o14); // and clear it again, so the preset is an edge
    p.read(CONTROL); // 0o14
    p.write_landing_at(preset(6) + 1, CONTROL, 0o14);
    p.at(preset(6) + 200);
    p.read(CONTROL); // 0o14


    // Frame 8: the frame buffer.  Writes across the window and its edges,
    // reads back, one word rewritten with its neighbors checked, and the
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
    // -XBUS INIT.  Off a `-TVMA CLR` with the interrupt up; then on one and
    // a tick either side of one.  Init is not tied to the master clock, so
    // unlike a store it can be put at any tick at all.
    // ---------------------------------------------------------------
    p.at(preset(8) + 40_000);
    p.read(CONTROL); // 0o34: the interrupt is up
    p.at(preset(8) + 50_000);
    p.init(); // the flag goes, the mode stands
    p.at(preset(8) + 50_005);
    p.read(CONTROL); // 0o14
    p.read(CONTROL + 1); // the PROM's word at the pointer, the RAM not selected
    p.at(preset(8) + 60_000);
    p.write(CONTROL, 0o34); // the flag set again by a write: up
    p.at(preset(9) - 1); // the tick before a preset: down for one tick
    p.init();
    p.at(preset(10)); // on one
    p.init();
    p.at(preset(11) + 1); // the tick after one
    p.init();
    p.at(preset(11) + 100);
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
    // A write landing ON a `-TVMA CLR`.  The store wins.
    // ---------------------------------------------------------------
    p.at(preset(16) - 2_000);
    p.read(CONTROL); // 0o30: the last preset
    p.write_landing_at(preset(16), CONTROL, 0o10);
    p.at(preset(16) + 200);
    p.read(CONTROL); // 0o10: no field has begun since the write
    p.read(BUFFER + 0x7FFF); // the buffer still holds its word

    // ---------------------------------------------------------------
    // And a write landing one tick BEFORE one: the flag is clear for a
    // tick and the preset sets it again.
    // ---------------------------------------------------------------
    p.at(preset(26) - 2_000);
    p.read(CONTROL); // 0o10
    p.write(CONTROL, 0o30); // the flag SET by the write, so there is something to clear
    p.read(CONTROL); // 0o30
    p.write_landing_at(preset(26) - 1, CONTROL, 0o10);
    p.at(preset(26) + 200);
    p.read(CONTROL); // 0o30: the preset put it back a tick after the write

    // ---------------------------------------------------------------
    // Frame 7: the sync program RAM.
    //
    // **THE RAM IS LOADED WITH THE ENABLE OFF, AS MIT'S SOFTWARE LOADS IT**
    // --- `color.lisp` calls `SI:STOP-SYNC`, `SI:FILL-SYNC` and
    // `SI:START-SYNC` in that order --- and there are two reasons rather
    // than one.  It is what the machine does; and a write of a RAM word
    // while the RAM is selected runs the program afresh, so loading it
    // selected leaves a half-written program standing between one word and
    // the next.  `Timeline::of` answers None for such a program AT THE
    // RESTART, while a clocked generator finds out by fetching, and the two
    // part as soon as one instruction of it lands.  The assert at the write
    // holds the program to it: a program that makes no frame may not stand
    // for longer than one instruction.
    // ---------------------------------------------------------------
    p.at(preset(26) + 5_000);
    p.read(CONTROL); // 0o30
    p.write(CONTROL + 3, 0); // the enable off: the PROM is selected
    p.write(CONTROL + 2, 0x1FFF); // the pointer takes twelve bits: 0xFFF
    p.write(CONTROL + 1, 0x1234_56A5); // and the data eight: 0xA5
    p.read(CONTROL + 1); // the PROM's word at 0xFFF, past MIT's program: zero
    p.read(CONTROL + 2); // write only: zero
    p.read(CONTROL + 3); // write only: zero
    // Pointers spread over the twelve bits, a byte at each.
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
    // **AND A ZERO AT LOCATION 0, WHICH IS A LOOP OF 256.**  `lmtv.order`:
    // "Each loop is executed a fixed number of times between 1 and 256.  A
    // loop starts with a word containing the number of times it is to be
    // executed" --- eight bits, so the 256 is a zero.  MIT's own `cpt.prom`
    // has counts of 1, 53, 8, 255, 255, 255, 131, 7 and 1 and never a zero,
    // so the program this trace loads is the only place the rule is
    // exercised.  Written last, over `sync_byte(0)`, and the read-back below
    // and the assertion at the end of the run both know it.
    p.write(CONTROL + 2, 0);
    p.write(CONTROL + 1, 0xFFFF_FF00);
    // **THE FLAG IS CLEARED BEFORE THE FIRST RESTART OF THE SYNC PROGRAM**,
    // and the write's own assert says why: muir's restart forgets the fields
    // counted before it, where the board's flop is a preset that stands.
    // Everything from here to the end of this frame restarts the program.
    p.write(CONTROL, 0o14);
    p.write(CONTROL + 3, 0x80 | 0o65); // the enable, over a spacing
    // **AND WAIT FOR THE PROGRAM THE ENABLE JUST SELECTED TO REACH ITS FIRST
    // `-TVMA CLR`.**  Where that falls is the whole of what the restart did:
    // this program's is 603,000 ns --- 120,600 ticks --- after its start, and
    // a machine that did not run it afresh here is running something else
    // entirely.  Compared at every tick on -XBUS.INTR, `MODE INTR ENB`
    // standing and the flag written clear a cycle ago.
    p.pause(130_000);
    p.read(CONTROL); // 0o34: the flag set by this program's first -TVMA CLR
    // And now read them all back, in another order, with the RAM selected.
    for &ptr in pointers.iter().rev() {
        p.write(CONTROL + 2, ptr);
        p.read(CONTROL + 1);
    }
    p.write(CONTROL + 2, 0xFFF);
    p.read(CONTROL + 1); // 0xA5 still, under the others
    // A write of a RAM word WITH THE RAM SELECTED, which is the third thing
    // that runs the program afresh.  The word written is the one already
    // there, so the program is the same program and still makes a frame ---
    // muir restarts on the write and not on the word changing.
    //
    // **AND THEN THE TRACE WAITS FOR THE PROGRAM'S FIRST `-TVMA CLR`**, with
    // `MODE INTR ENB` standing and the flag clear.  Where that falls is the
    // whole of what the restart changed: the program is identical either
    // way, so if the write did not restart it the preset comes at some other
    // instant entirely, and -XBUS.INTR is compared at every tick.  The first
    // `-TVMA CLR` of this program is 603,000 ns --- 120,600 ticks --- after
    // its start, and the wait is longer than that.
    p.write(CONTROL, 0o14); // the flag clear before a restart, as above
    p.write(CONTROL + 2, pointers[1]);
    p.write(CONTROL + 1, 0xFFFF_FF00 | sync_byte(pointers[1]));
    p.read(CONTROL + 1);
    p.pause(130_000);
    p.read(CONTROL); // 0o34: the flag set by this run's first -TVMA CLR
    p.write(CONTROL, 0o14); // and clear again, before the restarts below
    // The three that respond and do nothing.
    for r in 4..CONTROL_WORDS {
        p.write(CONTROL + r, 0xFFFF_FFFF);
    }
    for r in 4..CONTROL_WORDS {
        p.read(CONTROL + r);
    }
    p.read(CONTROL); // the mode register untouched by all of that: 0o14
    p.write(CONTROL + 3, 0o65); // the enable off again, the spacing kept
    p.read(CONTROL + 1); // the PROM's word at 0xFFF: zero
    p.write(CONTROL + 3, 0x80 | 0o65);
    p.read(CONTROL + 1); // 0xA5
    // ---------------------------------------------------------------
    // And one more `-XBUS INIT`, after all of that: the sync RAM and its
    // enable stand, because `-RESET` reaches one flop on this board and it
    // is the flag's.  The 74LS273 at NTVINC 0A07 clears on `-POWER RESET`.
    // ---------------------------------------------------------------
    p.init();
    p.pause(150); // past the first instruction of the run the enable started
    p.read(CONTROL); // the flag gone, the mode standing
    p.read(CONTROL + 1); // 0xA5: the RAM and its enable survived the reset

    // ---------------------------------------------------------------
    // **AND THE ONE BIT THE TWO BOARDS DIFFER IN**, deliberately rather than
    // by accident.  Mode bit 7, `SYNC PROM ENB`: on the LISPM TV the 74LS244
    // at XBCTL 0F11 takes it from pin 19 of the 74LS273 at TVINC 0A07, which
    // is the sync enable, and on the SIMPLE TV the same pin is ground.  So
    // the enable is turned off and on again with a read of the mode register
    // at each, and the two traces part on exactly those reads and nowhere
    // else.  The flag is clear here --- the `-XBUS INIT` above took it and
    // the pause since is a few hundred ticks against a frame --- so neither
    // enable write restarts the program with it standing.
    // ---------------------------------------------------------------
    p.write(CONTROL + 3, 0o65); // the enable off, the spacing kept
    p.pause(150); // past the first instruction of the run it started
    p.read(CONTROL); // 0o14 on both boards
    p.write(CONTROL + 3, 0x80 | 0o65); // and on again
    p.pause(150);
    p.read(CONTROL); // 0o14 on a SIMPLE TV, 0o214 on a LISPM TV
    let end = p.cursor + 500_000;

    // ---------------------------------------------------------------
    // The run.
    // ---------------------------------------------------------------
    let mut bi = Busint::new(1);
    bi.device_ns = 0;
    let mut tv = Tv::default();
    tv.set_board(board);
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
    // The sync program's restarts, and when one left a program that makes no
    // frame: both are asserted at the write above.
    let mut restarts = 0u64;
    let mut no_frame_since: Option<u64> = None;

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
    // `-TVMA CLR`s that found the vertical flag already set: a preset that
    // moves nothing, which is the ordinary case on a machine whose microcode
    // is not taking the interrupt.  Counted from muir's own timeline rather
    // than from a frame boundary, because the preset is not on one.
    let mut presets_on_a_set_flag = 0u64;
    let mut clrs_was = 0u64;
    let mut origin_was = 0u64;
    let mut flag_was = false;

    let mut out: Vec<String> = Vec::with_capacity(1 << 16);
    let mut prev: Option<(u8, u8, u32, u32, u8, u8, u8, u8, u32, u8)> = None;

    for tick in 0..=end {
        let now = tick * TICK_NS;
        let mclk = tick % MICROCYCLE_TICKS == 0;
        let mut xinit = false;

        // The cpu lifts -MEMRQ MFINISHD_NS after the acknowledgment.
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
                // **A RESTART CARRIES THE VERTICAL FLAG AND THE SYNC BITS
                // OVER, IN muir AS ON THE BOARD.**  The flag is the 74LS74 at
                // NXBCTL 0E14, preset by `-TVMA CLR` and cleared only by
                // `-LOAD MODE` or `-RESET`; the sync bits are the 74LS175 at
                // NSYREG 0D02, whose clear is a pull-up.  The sync program's
                // start reaches none of those pins, so both stand.  `Tv::restart`
                // carries them now, so a write that restarts the program with
                // the flag up is comparable and this generator no longer
                // refuses to place one.
                tv.write_control(r, word, now);
                if tv.origin() == now {
                    restarts += 1;
                    if let Some(at) = no_frame_since {
                        assert!(
                            now - at < sync::INSTRUCTION_NS[(tv.mode() & mode::CLOCK) as usize],
                            "tick {tick}: a program that makes no frame ran for {} ns before the \
                             next restart replaced it; muir calls it dead at the restart and the \
                             fabric finds out by fetching, so they part as soon as one \
                             instruction of it lands",
                            now - at
                        );
                    }
                    no_frame_since = if tv.timeline().is_none() { Some(now) } else { None };
                }
            } else if let Some(off) = muir::tv::buffer_offset(phys) {
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
                    // Neither the flag nor the sync bits may move between
                    // muir's read and the fabric's strobe: see the top.
                    let ack = bi.ack_at().expect("a read has an acknowledgment");
                    assert_eq!(
                        tv.vert_flag(now),
                        tv.vert_flag(ack),
                        "tick {tick}: a -TVMA CLR falls inside the deskew of a mode-register read; move it"
                    );
                    assert_eq!(
                        tv.sync_at(now),
                        tv.sync_at(ack),
                        "tick {tick}: VSYNC or HSYNC moves inside the deskew of a mode-register \
                         read; the board reads them live through the 74LS244 at NXBCTL 0F11 and \
                         muir samples at the request, so move the read"
                    );
                }
                v
            } else if let Some(off) = muir::tv::buffer_offset(phys) {
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
                    Op::Pause(t) if now >= e.at * TICK_NS => {
                        next_ok = now + t * TICK_NS;
                        ev.next();
                    }
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
                        } else if muir::tv::buffer_offset(phys).is_some() {
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
        let origin_now = tv.origin();
        let clrs_now = tv
            .timeline()
            .filter(|_| now >= origin_now)
            .map_or(0, |t| t.tvma_clrs_by(now - origin_now));
        if origin_now == origin_was && clrs_now > clrs_was && flag_was {
            presets_on_a_set_flag += 1;
        }
        (clrs_was, origin_was, flag_was) = (clrs_now, origin_now, tv.vert_flag(now));
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
    assert!(
        no_frame_since.is_none(),
        "the trace ends with a program that makes no frame standing; muir calls it dead at the \
         restart and the fabric finds out by fetching"
    );
    assert!(restarts >= 4, "only {restarts} restarts of the sync program: too few to hold one");

    // Every one of the sync RAM's written bytes reads back through the trace
    // is a property of the program; assert the words are what the reference
    // model holds, so a change to `sync_byte` shows here.
    for &ptr in &pointers {
        // Location 0 was written last, with the zero that means 256.
        let want = if ptr == 0 { 0 } else { sync_byte(ptr) };
        assert_eq!(tv.sync.words()[ptr as usize] as u32, want);
    }
    assert!(intr_rises >= 12 && intr_falls >= 12, "too few interrupt edges: {intr_rises} up, {intr_falls} down");
    assert!(presets_on_a_set_flag >= 1, "no `-TVMA CLR` presets a flag already set");
    assert_eq!(SYNC_RAM_WORDS, 4096);

    println!("# tick n_memrq wrcyc phys wdata mclk xinit | n_memgrant n_memack n_loadmd timed_out rdata intr");
    println!("# generated by golden/src/tv.rs from muir's tv::Tv through busint::Busint");
    println!("# one row a tick wherever anything moves; between rows every column holds");
    println!("# every value decimal; rdata is the word MD takes on a read, 0 otherwise");
    println!("# board {}", board.name());
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
    println!("# sync_prom_words {}", sync::prom().len());
    println!("# sync_instruction_ns {} {}", sync::INSTRUCTION_NS[0], sync::INSTRUCTION_NS[2]);
    println!("# sync_restarts {restarts}");
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
    println!("# presets_on_a_set_flag {presets_on_a_set_flag}");
    for l in &out {
        println!("{l}");
    }
    eprintln!(
        "tv {}: {cycle} cycles over {end} ticks ({} frames), {n_rows} rows; interrupt up {intr_rises} times and down {intr_falls}; {inits} inits, {nxm_cycles} timeouts",
        board.name(),
        end / f
    );
}
