// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! A QUUX checkpoint as muir itself writes it, for a known machine: the
//! reference `cadr-checkpoint --machine quux` is compared with BYTE FOR BYTE.
//!
//!     quux_checkpoint FILE --machine quux --sync-cycle-ticks K [--sync-ilong-ticks L]
//!                     --revision 13
//!     quux_checkpoint --resume-and-save IN OUT --revision 13 --machine quux
//!                     --sync-cycle-ticks K [--sync-ilong-ticks L]
//!
//! **`--revision 13`** builds revision 13's machine (contract G2, appendix
//! A1.13; muir's `Geometry::QUUX`), the only QUUX since revision 12 was
//! retired: the same history, its words at 40 bits
//! with tags that are not zero, its dispatch memory, maps and main memory at
//! revision 13's sizes and widths, the overflow flag set, and block-disk and
//! the file device at 28-bit addresses; muir writes it as checkpoint version
//! 50.  **`--resume-and-save`** is muir's own round trip for it: the machine
//! built as for a checkpoint, the file loaded into it and saved again.
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

/// `main.rs`'s `machine` for `--machine quux`: block-disk and the video
/// controller at `video`, muir's default 1280 by 1024 unless `--video-size`
/// gives the Kria KR260's 1920 by 1080, one memory board, and a disk of
/// `DISK_BLOCKS` blocks with none written (contract Q8a, format 41), at
/// revision 13.
fn machine(video: (usize, usize)) -> Machine {
    let mut m = Machine::with_memory_boards(1);
    m.geometry = Geometry::QUUX;
    let mut bd = BlockDisk::new(block_disk::BLOCK_NS);
    bd.attach(Disk::blank(DISK_BLOCKS));
    m.block_disk = Some(bd);
    m.tv.set_video_size(video.0, video.1);
    m.tv.set_board(Board::Video);
    m.plug_chaos(0);
    m
}

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
const FD_RESP_LOG2: u32 = 1;
/// Revision 13's: block-disk's command list pointer is 28 bits, and the
/// file device's rings are on an 8-word line.
const DISK_CLP_13: u32 = 0x0ABC_DEF0;
const FD_RESP_BASE_13: u32 = 0x00_1108;

fn main() {
    // The machine and its timing as every trace takes them
    // (`machine_axis.rs`), K the board's and never guessed.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let timing = machine_axis::take_timing(which, &mut args);
    let mut rev13 = false;
    if let Some(i) = args.iter().position(|a| a == "--revision") {
        rev13 = args.get(i + 1).map(String::as_str) == Some("13");
        assert!(rev13, "--revision takes 13");
        args.drain(i..i + 2);
    }
    // The video controller's size, muir's `--video-size WxH`, as the
    // bitstream says it (contract HD).
    let mut video = (1280, 1024);
    if let Some(i) = args.iter().position(|a| a == "--video-size") {
        let size = args.get(i + 1).and_then(|v| v.split_once('x'))
            .and_then(|(w, h)| Some((w.parse().ok()?, h.parse().ok()?)))
            .expect("--video-size takes WxH");
        muir::tv::check_video_size(size.0, size.1, false).expect("a video controller muir takes");
        video = size;
        args.drain(i..i + 2);
    }
    let resume = args.first().map(String::as_str) == Some("--resume-and-save");
    if which != machine_axis::Which::Quux
        || args.len() != if resume { 3 } else { 1 }
        || !rev13
    {
        eprintln!(
            "usage: quux_checkpoint FILE --machine quux --sync-cycle-ticks K [--sync-ilong-ticks L] \
             --revision 13 [--video-size WxH]\n       quux_checkpoint --resume-and-save IN OUT --revision 13 ...\n\
             (revision 12 is retired)"
        );
        std::process::exit(2);
    }
    if resume {
        // muir's own round trip, as `resume_engine` does it: the engine of
        // the machine the checkpoint is of, loaded, and saved again.
        let c = muir::checkpoint::read(std::path::Path::new(&args[1])).expect("the checkpoint");
        let mut e = trace::engine_on(machine(video), timing);
        e.load(&mut c.reader()).expect("muir took the checkpoint");
        let mut w = muir::checkpoint::Writer::new();
        e.save(&mut w);
        let bits = e.m.geometry.word_bits;
        muir::checkpoint::write(std::path::Path::new(&args[2]), &c.engine, c.memory_boards, bits, &w.finish())
            .expect("the checkpoint saved again");
        println!(
            "resumed: version {} at {} microcycles, {} ns, {} memory boards, a video controller of {}x{}",
            c.version,
            e.m.cycles,
            e.m.ns,
            c.memory_boards,
            e.m.tv.screen().0,
            e.m.tv.screen().1
        );
        return;
    }
    let path = args[0].clone();
    let mut m = machine(video);
    assert!(m.geometry.wide(), "QUUX is revision 13's 40-bit word");
    // A word's bits, and a word poisoned at them: 40 with its tag.
    let word_bits = m.geometry.word_bits;
    let (clp, resp_base) = (DISK_CLP_13, FD_RESP_BASE_13);

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
        dev.write(fd::RESP_BASE, resp_base, t0, 0, &m.main);
        dev.write(fd::RESP_SIZE, FD_RESP_LOG2, t0, 0, &m.main);
        dev.write(fd::CONTROL, 0x101, t0, 0, &m.main);
        m.main[FD_CMD_BASE as usize] = (0x1234 | 0o77 << 16) as muir::machine::Word;
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
        *w = poison(2, i as u64, word_bits);
    }
    for (i, w) in m.mmem.iter_mut().enumerate() {
        *w = poison(3, i as u64, word_bits);
    }
    for (i, w) in m.pdl.iter_mut().enumerate() {
        *w = poison(4, i as u64, word_bits);
    }
    for (i, w) in m.spc.iter_mut().enumerate() {
        *w = poison(5, i as u64, 21) as u32;
    }
    // The dispatch memory and both map levels at the machine's own sizes
    // and widths: 4,096, 8,192 of 7 bits and 4,096 of 28 (A1.4, A1.7).
    let (dmem, l1, l1_bits, l2, l2_bits) = (4096, 8192, 7, 4096, 28);
    for (i, w) in m.dmem.iter_mut().take(dmem).enumerate() {
        *w = poison(6, i as u64, 17) as u32;
    }
    for (i, w) in m.l1_map.iter_mut().take(l1).enumerate() {
        *w = poison(7, i as u64, l1_bits) as u32;
    }
    for (i, w) in m.l2_map.iter_mut().take(l2).enumerate() {
        *w = poison(8, i as u64, l2_bits) as u32;
    }
    for (i, w) in m.main.iter_mut().enumerate() {
        *w = poison(12, i as u64, word_bits);
    }
    // The register table's entries that are `Machine`'s, at their widths.
    m.spcptr = poison(10, 13, 5) as u8;
    m.pdl_pointer = poison(10, 11, 14) as u16;
    m.pdl_index = poison(10, 12, 14) as u16;
    m.q = poison(10, 5, word_bits);
    m.vma = poison(10, 6, word_bits);
    m.md = poison(10, 7, word_bits);
    // Revision 13's fixnum overflow flag, the flag word's <35>.
    m.overflow = true;
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
        d.write(block_disk::CLP, clp, &mut main);
        d.write(block_disk::DA, DISK_DA, &mut main);
        d.write(block_disk::START, 0, &mut main);
        m.main = main;
    }

    // **The fused return** (contract H8a): the register, the
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
        md.m31 = Some(poison(10, 33, word_bits));
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
