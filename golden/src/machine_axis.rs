// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! Which machine a reference trace is taken on: the CADR, MIT's, or QUUX,
//! the evolved CADR.  `--machine cadr|quux` on a generator's command line,
//! `cadr` when it is not given, as every sibling project selects it.
//!
//! **QUUX IS BUILT HERE AS muir'S LIBRARY BUILDS IT, AND AS muir'S OWN
//! `machine()` IN `src/main.rs` DOES**: the geometry set on the machine before
//! the engine is made, QUUX's boot PROM (PROM 2002, `prom::quux_boot_prom`,
//! muir's `data/quux-promh.mcr`), the video controller fitted as the
//! display, and
//! block-disk as the disk.  One thing is
//! this project's and not muir's default: **THE VIDEO CONTROLLER IS 1280 BY
//! 1024**, the size the bitstreams build, set explicitly with
//! `Tv::set_video_size` where muir's default is 1920 by 1080.  1280 bits is
//! 40 words a line and the buffer is 40,960 words, `17000000` to
//! `17117777`; muir's own `check_video_size` is asked whether the size is
//! one it accepts.
//!
//! The CADR is `Machine::new` untouched, so a generator given no flag writes
//! exactly the trace it wrote before this module existed.

// Each generator takes what it needs of this, and not all of it.
#![allow(dead_code)]

use muir::isa::Insn;
use muir::machine::{Geometry, Machine};
use muir::tv::{Board, check_video_size};

/// The second QUUX's real-time clock reads at power-on in every trace:
/// 2026-09-22 23:17:37 UTC, chosen for bits in every nibble.
pub const RTC_START: u32 = 1_790_119_057;

/// The video controller's size in every QUUX bitstream: 1280 by 1024, one
/// bit a pixel.
pub const VIDEO_WIDTH: usize = 1280;
pub const VIDEO_HEIGHT: usize = 1024;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Which {
    Cadr,
    Quux,
}

impl Which {
    pub fn name(self) -> &'static str {
        match self {
            Which::Cadr => "cadr",
            Which::Quux => "quux",
        }
    }

    pub fn geometry(self) -> Geometry {
        match self {
            Which::Cadr => Geometry::CADR,
            Which::Quux => Geometry::QUUX,
        }
    }

    /// The machine's own boot PROM: MIT's, or QUUX's, PROM 2002,
    /// `prom --machine quux`'s.
    pub fn boot_prom(self) -> Vec<Insn> {
        match self {
            Which::Cadr => muir::prom::boot_prom(),
            Which::Quux => muir::prom::quux_boot_prom(),
        }
    }

    /// A fresh machine of this kind with `prom` loaded, before any engine.
    pub fn machine(self, prom: &[Insn]) -> Machine {
        let mut m = Machine::new();
        m.load_prom(prom);
        if self == Which::Quux {
            m.geometry = Geometry::QUUX;
            if let Err(e) = check_video_size(VIDEO_WIDTH, VIDEO_HEIGHT, false) {
                panic!("the video controller at {VIDEO_WIDTH} by {VIDEO_HEIGHT}: {e}");
            }
            m.tv.set_video_size(VIDEO_WIDTH, VIDEO_HEIGHT);
            m.tv.set_board(Board::Video);
            assert_eq!(m.tv.buffer_words(), 40_960, "the video controller's buffer at 1280 by 1024");
            // **THE CONTROL STORE COMES UP ALL ONES, AS THE FABRIC'S DOES.**
            // What a RAM holds at power-on is a convention, and the fabric's
            // is all ones where muir's is zero (`cadr_microcycle.sv` says why
            // at the array).  On the CADR no trace ever fetches a word nobody
            // wrote, the PROM overlaying 0-1777 until the RAM is loaded.  On
            // QUUX it does, once: the PROM is at 36000 (contract Q2) and the
            // trap cycle after a boot fetches the RAM at the PC it comes up
            // with, 0, a word nobody wrote, nopped but compared.  So the
            // reference takes the fabric's convention, and every word read
            // before it is written reads the same in both.
            for w in m.imem.iter_mut() {
                *w = Insn::new(!0);
            }
            // **QUUX'S DISK IS BLOCK-DISK**, as muir's `machine()` fits it on
            // `--machine quux`, the CADR controller refused there: no pack on
            // it here, which is how the fabric's traces are taken too.
            m.block_disk = Some(muir::block_disk::BlockDisk::new(muir::block_disk::BLOCK_NS));
            // **THE REAL-TIME CLOCK IS COUNTED, NEVER LIVE, IN A TRACE**
            // (revision 9): muir's `--rtc <s>`, word 103 reading `RTC_START`
            // at power-on and a second more for each 10^9 ns of the
            // machine's own time.  Live, it would read the host's clock and
            // no two runs of a generator would agree.  A trace that reads the
            // word says so in a `# rtc` line, and the testbench loads the
            // same start into the fabric's counter through the machine's
            // host side, as Linux does on a board.
            m.rtc = muir::machine::Rtc::Counted { start: RTC_START, base_ns: 0 };
        }
        m
    }
}

/// `--machine cadr|quux` out of `args`, removed from it; `cadr` if absent.
pub fn take(args: &mut Vec<String>) -> Which {
    let mut which = Which::Cadr;
    while let Some(i) = args.iter().position(|a| a == "--machine") {
        let v = args.get(i + 1).cloned().unwrap_or_default();
        which = match v.as_str() {
            "cadr" => Which::Cadr,
            "quux" => Which::Quux,
            _ => {
                eprintln!("--machine is `{v}`; it is cadr, MIT's machine, or quux, the evolved CADR");
                std::process::exit(2);
            }
        };
        args.drain(i..(i + 2).min(args.len()));
    }
    which
}
