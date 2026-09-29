// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! A QUUX checkpoint as muir itself writes it, for a known machine: the
//! reference `cadr-checkpoint --machine quux` is compared with BYTE FOR BYTE.
//!
//!     quux_checkpoint FILE --machine quux --sync-cycle-ticks K [--sync-ilong-ticks L]
//!
//! **THE MACHINE IS DESCRIBED TWICE, HERE IN muir'S TERMS AND IN
//! `checkpoint_test.c` IN THE FABRIC'S, AND THE FILE IS WHAT SAYS THE TWO
//! AGREE.**  Here the timers are turned on at an instant and periods written,
//! the keyboard is pressed and read, the mouse moved, block-disk written and
//! started, through muir's own calls; there the same history is what the
//! fabric's counters and registers would hold after it, read through a
//! modeled window.  A field written wrong on the C side, crossed with
//! another, taken from the wrong readout word or converted wrongly from the
//! fabric's counters to muir's instants makes the two files differ.
//!
//! What is NOT described twice: the `Rtl` engine's own registers --- `IR`,
//! `PC`, the flags and the rest of the tail --- which muir keeps private, so
//! the machine here has them as a fresh `Rtl` holds them and the C side's
//! modeled register table does the same.  They are the CADR's code, held by
//! `build/checkpoint.pass`'s digest and mutants.  Every field of `Machine`
//! that the fabric has a reading for is poisoned, `poison` being
//! `checkpoint_test.c`'s own, injective in the memory and the address.

mod machine_axis;
mod trace;

use muir::block_disk::{self, BlockDisk};
use muir::disk_image::Disk;
use muir::engine::Engine;
use muir::isa::Insn;
use muir::machine::{Geometry, IntervalTimer, Machine, QUUX_PROM_BASE, Timers};
use muir::quux_input::{KeyboardMouse, QuuxInput};
use muir::tv::Board;

/// `checkpoint_test.c`'s poison.
fn poison(sel: u64, addr: u64, bits: u32) -> u64 {
    let h = (sel + 1)
        .wrapping_mul(0x9E37_79B9_7F4A_7C15)
        .wrapping_add((addr + 1).wrapping_mul(0xC2B2_AE3D_27D4_EB4F));
    if bits >= 64 { h } else { h & ((1u64 << bits) - 1) }
}

// The machine, in the terms `checkpoint_test.c` repeats: every constant
// below is there under the same name.
/// Ticks of MIT's grid since power-on at the checkpoint's instant: past 2^32
/// microseconds, so the microsecond clock has wrapped and the C side's
/// unwrapping is in the path.
const M0: u64 = 0x98_7654_3210;
/// When timers 0 and 1 were turned on, in ticks.
const ENABLED: u64 = M0 - 1_000_037;
/// Timer 1's period, written before the turn-on, in microseconds: periodic,
/// its flag has risen once by `M0` and not twice.
const PERIOD_US: u32 = 6000;
/// Timer 0's, one-shot: not risen by `M0`.
const ONE_SHOT_US: u32 = 16_667;
/// Timer 2's, one-shot with its interrupt enable clear, turned on this long
/// before `M0` less a tick so that it rises a tick before `M0`: a one-shot's
/// count stops at its rise, so the fabric cannot say how long ago a one-shot
/// rose, and the checkpoint writes such a rise at the latest tick it can
/// have been, the one before the timer's word was read (`chk_rtl.c`).
const SHOT_AT_M0_US: u32 = 3000;
const CYCLES: u64 = 0x12_3456_7890;
/// Block-disk's registers as written: a command it does not do, with the
/// done interrupt enabled, so START stops by error and moves nothing.
const DISK_CMD: u32 = 0x1234_5805;
const DISK_CLP: u32 = 0x00AB_CDEF;
const DISK_DA: u32 = 0x3FED_CBA9;
/// Key words pressed: seventy, six past the FIFO, and fifty-nine read back.
const KEYS: u64 = 70;
const KEYS_READ: u64 = 59;
const MOUSE_X: i32 = 0x5a3;
const MOUSE_Y: i32 = 0x2c7;
const MOUSE_BUTTONS: u8 = 5;
/// Block-disk's disk, in blocks: the pack file's size in 1,024-byte blocks,
/// which the C side declares as its geometry's product and
/// `build/checkpoint.quux.pass` makes a file of for muir's resume.
const DISK_BLOCKS: u32 = 16 * 1 * 16;
/// The file device's rings (revision 9): the command ring's base and the
/// log2 of its entries, the response ring's.
const FD_CMD_BASE: u32 = 0x00_1000;
const FD_CMD_LOG2: u32 = 2;
const FD_RESP_BASE: u32 = 0x00_1100;
const FD_RESP_LOG2: u32 = 1;

fn main() {
    // The machine and its timing as every trace takes them
    // (`machine_axis.rs`), K the board's and never guessed.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let timing = machine_axis::take_timing(which, &mut args);
    if which != machine_axis::Which::Quux || args.len() != 1 {
        eprintln!("usage: quux_checkpoint FILE --machine quux --sync-cycle-ticks K [--sync-ilong-ticks L]");
        std::process::exit(2);
    }
    let path = args[0].clone();

    // `main.rs`'s `machine` for `--machine quux`: block-disk and the video
    // controller at the bitstreams' 1280 by 1024, one memory board, and a
    // disk of `DISK_BLOCKS` blocks with none written (contract Q8a, format
    // 41).
    let mut m = Machine::with_memory_boards(1);
    m.geometry = Geometry::QUUX;
    let mut bd = BlockDisk::new(block_disk::BLOCK_NS);
    bd.attach(Disk::blank(DISK_BLOCKS));
    m.block_disk = Some(bd);
    m.tv.set_video_size(1280, 1024);
    m.tv.set_board(Board::Video);
    m.plug_chaos(0);

    // The file device, through muir's own calls: the rings configured and
    // enabled with the interrupt enable, one command posted --- an opcode
    // muir lacks, which reads no buffer and touches no host file --- taken,
    // answered and its response consumed, and a response consumer written
    // past the producer, which leaves the index fault standing.  No handle is
    // open and nothing is queued, so the checkpoint may be taken; main
    // memory is poisoned below, over the ring's words.  The board's clock is
    // the host's, `Rtc::Host`, as `Machine::new` has it.
    {
        use muir::file_device as fd;
        let dev = &mut m.file_device;
        let t0 = 1_000_000;
        dev.write(fd::CMD_BASE, FD_CMD_BASE, t0, 0, &m.main);
        dev.write(fd::CMD_SIZE, FD_CMD_LOG2, t0, 0, &m.main);
        dev.write(fd::RESP_BASE, FD_RESP_BASE, t0, 0, &m.main);
        dev.write(fd::RESP_SIZE, FD_RESP_LOG2, t0, 0, &m.main);
        dev.write(fd::CONTROL, 0x101, t0, 0, &m.main);
        m.main[FD_CMD_BASE as usize] = 0x1234 | 0o77 << 16;
        dev.write(fd::CMD_PROD, 1, t0, 0, &m.main);
        dev.advance(t0 + 1_000_000, &mut m.main);
        dev.write(fd::RESP_CONS, 1, t0 + 1_000_000, 0, &m.main);
        dev.write(fd::RESP_CONS, 5, t0 + 1_000_000, 0, &m.main);
        assert_eq!(dev.read(fd::STATUS, t0 + 1_000_000), 1 | 1 << 3, "the file device's status");
        assert_eq!(dev.read(fd::RESP_PROD, t0 + 1_000_000), 1, "the command answered");
        assert!(m.checkpoint_refusal().is_none(), "a checkpoint may be taken");
    }

    // The memories the readout window reaches.  The control store under
    // QUUX's PROM is held zero, as `Machine::write_imem` leaves it.
    for (i, w) in m.prom.iter_mut().enumerate() {
        *w = Insn::new(poison(1, i as u64, 48));
    }
    for (i, w) in m.imem.iter_mut().enumerate() {
        *w = Insn::new(if i < QUUX_PROM_BASE as usize { poison(0, i as u64, 48) } else { 0 });
    }
    for (i, w) in m.amem.iter_mut().enumerate() {
        *w = poison(2, i as u64, 32);
    }
    for (i, w) in m.mmem.iter_mut().enumerate() {
        *w = poison(3, i as u64, 32);
    }
    for (i, w) in m.pdl.iter_mut().enumerate() {
        *w = poison(4, i as u64, 32);
    }
    for (i, w) in m.spc.iter_mut().enumerate() {
        *w = poison(5, i as u64, 21) as u32;
    }
    for (i, w) in m.dmem.iter_mut().enumerate() {
        *w = poison(6, i as u64, 17) as u32;
    }
    for (i, w) in m.l1_map.iter_mut().enumerate() {
        *w = poison(7, i as u64, 6) as u32;
    }
    for (i, w) in m.l2_map.iter_mut().enumerate() {
        *w = poison(8, i as u64, 24) as u32;
    }
    for (i, w) in m.main.iter_mut().enumerate() {
        *w = poison(12, i as u64, 32);
    }
    // The register table's entries that are `Machine`'s, at their widths.
    m.spcptr = poison(10, 13, 5) as u8;
    m.pdl_pointer = poison(10, 11, 14) as u16;
    m.pdl_index = poison(10, 12, 14) as u16;
    m.q = poison(10, 5, 32);
    m.vma = poison(10, 6, 32);
    m.md = poison(10, 7, 32);
    m.dispatch_constant = poison(10, 15, 10) as u16;
    // The console's registers the table's flags carry, and the page's.
    m.mode.errstop = true;
    m.mode.stathenb = true;
    m.clock_control.run = true;
    m.bus_error = 0o41;

    // The video controller: the picture, and black-on-white written with every other bit.
    for i in 0..m.tv.buffer_words() {
        m.tv.write_buffer(i, poison(13, i as u64, 32) as u32);
    }
    m.tv.write_control(0, 0xFFFF_FFFF, 0);

    // The interval timers (revision 10, contract Q11), through the register
    // page's calls: each period written, then each turned on --- timer 0
    // one-shot with its interrupt enable, not yet risen; timer 1 periodic
    // with its, risen once; timer 2 one-shot without it, risen a tick before `M0`.
    let mut t = Timers::new();
    let (on, one_shot, ie) = (IntervalTimer::ON, IntervalTimer::ONE_SHOT, IntervalTimer::INTERRUPT_ENABLE);
    t.write(0o111, ONE_SHOT_US, (ENABLED - 5) * 10);
    t.write(0o113, PERIOD_US, (ENABLED - 5) * 10);
    t.write(0o110, on | one_shot | ie, ENABLED * 10);
    t.write(0o112, on | ie, ENABLED * 10);
    let shot = (M0 - 1) * 10 - SHOT_AT_M0_US as u64 * 1000;
    t.write(0o115, SHOT_AT_M0_US, shot - 50);
    t.write(0o114, on | one_shot, shot);
    assert!(!t.timer[0].flag(M0 * 10) && t.timer[1].flag(M0 * 10) && t.timer[2].flag(M0 * 10));
    m.timers = t;

    // The keyboard and mouse, through the calls muir's terminal and the
    // register page make.
    let q: &mut QuuxInput = &mut m.quux_input;
    q.write(0o120, 1 << 8);
    for i in 0..KEYS {
        q.press(poison(20, i, 24) as u32);
    }
    for _ in 0..KEYS_READ {
        q.read(0o121);
    }
    q.mouse_move(MOUSE_X, MOUSE_Y);
    q.mouse_buttons(MOUSE_BUTTONS);
    q.write(0o123, 1 << 8);

    // Block-disk, written and started at the checkpoint's instant.
    {
        let ns = M0 * 10;
        let mut main = std::mem::take(&mut m.main);
        let d = m.block_disk.as_mut().unwrap();
        d.advance(ns);
        d.write(block_disk::COMMAND, DISK_CMD, &mut main);
        d.write(block_disk::CLP, DISK_CLP, &mut main);
        d.write(block_disk::DA, DISK_DA, &mut main);
        d.write(block_disk::START, 0, &mut main);
        m.main = main;
    }

    // **Revision 12's fused return** (contract H8a): the register, the
    // index and every entry poisoned at their widths, the base copies, and
    // an operand address and an M 31 word armed, as `checkpoint_test.c`
    // models the register table's entries 29 to 33 and selector 13.  The
    // prefetch's word and a fetch in flight are the engine's own, which a
    // fresh engine holds none of, and neither does the model.
    {
        let md = &mut m.macro_dispatch;
        md.register = poison(10, 29, 32) as u32 & !(3 << 29);
        md.index = poison(10, 30, 10) as u16;
        for (i, e) in md.entries.iter_mut().enumerate() {
            *e = poison(13, i as u64, 18) as u32;
        }
        md.localp = poison(10, 31, 14) as u32;
        md.ap = poison(10, 131, 14) as u32;
        md.operand = Some(muir::machine::Operand { arg: true, delta: poison(10, 32, 6) as u8 });
        md.m31 = Some(poison(10, 33, 32));
    }

    // The engine on the fabric's grid, as every trace takes it.
    // QUUX's memory port as a fresh engine holds it, its cache always fitted
    // and empty (contract Q6): what `chk_rtl.c` writes for a halted board.
    let mut e = trace::engine_on(m, timing);
    e.set_clock(M0 * 10);
    e.m.cycles = CYCLES;

    let mut w = muir::checkpoint::Writer::new();
    e.save(&mut w);
    let body = w.finish();
    let n = muir::checkpoint::write(std::path::Path::new(&path), "rtl", 1, e.m.geometry.word_bits, &body)
        .expect("the checkpoint");
    println!(
        "quux_checkpoint: {} bytes of body, {n} bytes of file, timing {}, at {} ns",
        body.len(),
        machine_axis::timing_name(timing),
        M0 * 10
    );
}
