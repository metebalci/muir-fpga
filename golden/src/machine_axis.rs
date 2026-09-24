// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! Which machine a reference trace is taken on: the CADR, MIT's, or QUUX,
//! the evolved CADR.  `--machine cadr|quux` on a generator's command line,
//! `cadr` when it is not given, as every sibling project selects it.
//!
//! **QUUX IS BUILT HERE AS muir'S LIBRARY BUILDS IT, AND AS muir'S OWN
//! `machine()` IN `src/main.rs` DOES**: the geometry set on the machine before
//! the engine is made, QUUX's boot PROM (`prom::quux_boot_prom`, muir's
//! `data/quux-promh.mcr`), and MONO TV fitted as the display.  One thing is
//! this project's and not muir's default: **MONO TV IS 1280 BY 1024**, the
//! size the bitstreams build, set explicitly with `Tv::set_mono_tv_size`
//! where muir's default is 1920 by 1080.  1280 bits is 40 words a line and
//! the buffer is 40,960 words, `17000000` to `17117777`; muir's own
//! `check_mono_tv_size` is asked whether the size is one it accepts.
//!
//! The CADR is `Machine::new` untouched, so a generator given no flag writes
//! exactly the trace it wrote before this module existed.

// Each generator takes what it needs of this, and not all of it.
#![allow(dead_code)]

use muir::isa::Insn;
use muir::machine::{Geometry, Machine};
use muir::tv::{Board, check_mono_tv_size};

/// MONO TV's size in every QUUX bitstream: 1280 by 1024, one bit a pixel.
pub const MONO_TV_WIDTH: usize = 1280;
pub const MONO_TV_HEIGHT: usize = 1024;

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

    /// The machine's own boot PROM: MIT's, or QUUX's version 1000.
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
            if let Err(e) = check_mono_tv_size(MONO_TV_WIDTH, MONO_TV_HEIGHT, false) {
                panic!("MONO TV at {MONO_TV_WIDTH} by {MONO_TV_HEIGHT}: {e}");
            }
            m.tv.set_mono_tv_size(MONO_TV_WIDTH, MONO_TV_HEIGHT);
            m.tv.set_board(Board::MonoTv);
            assert_eq!(m.tv.buffer_words(), 40_960, "MONO TV's buffer at 1280 by 1024");
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
