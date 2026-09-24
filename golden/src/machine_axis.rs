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

use muir::clock::TimingModel;
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

/// **THE TIMING A TRACE IS TAKEN UNDER**, out of `args` and removed from it:
/// the CADR on muir's grid (`TimingModel::Fpga`), and QUUX on its
/// synchronous microcycle (`TimingModel::Sync`), `--sync-cycle-ticks K` ticks
/// a microcycle and `--sync-ilong-ticks L` more for an `ILONG` instruction.
///
/// **K IS THE BOARD'S, SO IT IS NEVER GUESSED HERE.**  A trace on QUUX with no
/// `--sync-cycle-ticks` is refused rather than taken at muir's default, and
/// the CADR refuses both flags, as muir's own `--timing-model sync` does:
/// the CADR's microcycle is its delay line's.  L defaults to zero, which is
/// what muir's command line always gives; a nonzero L is reachable only
/// through the library, as it is here.
pub fn take_timing(which: Which, args: &mut Vec<String>) -> TimingModel {
    let mut k: Option<u8> = None;
    let mut l: u8 = 0;
    for flag in ["--sync-cycle-ticks", "--sync-ilong-ticks"] {
        while let Some(i) = args.iter().position(|a| a == flag) {
            let v = args.get(i + 1).cloned().unwrap_or_default();
            let n: u8 = match v.parse() {
                Ok(n) => n,
                Err(_) => {
                    eprintln!("{flag} is `{v}`; it is a count of ticks");
                    std::process::exit(2);
                }
            };
            if flag == "--sync-cycle-ticks" {
                k = Some(n);
            } else {
                l = n;
            }
            args.drain(i..(i + 2).min(args.len()));
        }
    }
    match which {
        Which::Cadr => {
            if k.is_some() || l != 0 {
                eprintln!("--sync-cycle-ticks and --sync-ilong-ticks are QUUX's; the CADR's microcycle is its delay line's");
                std::process::exit(2);
            }
            TimingModel::Fpga
        }
        Which::Quux => match k {
            Some(k) if k >= 2 => TimingModel::Sync { cycle_ticks: k, ilong_ticks: l },
            Some(k) => {
                eprintln!("--sync-cycle-ticks is {k}; a microcycle is at least two ticks");
                std::process::exit(2);
            }
            None => {
                eprintln!("a trace on QUUX needs --sync-cycle-ticks K, the board's microcycle in ticks");
                std::process::exit(2);
            }
        },
    }
}

/// The timing's name for a trace's header: `timing: fpga`, or `timing: sync
/// K L`.  The testbenches compare every microcycle's length against the
/// trace, so this is for the reader, not for them.
pub fn timing_name(t: TimingModel) -> String {
    match t {
        TimingModel::Sync { cycle_ticks, ilong_ticks } => format!("sync {cycle_ticks} {ilong_ticks}"),
        other => other.name().to_string(),
    }
}

/// `, timing: sync K L` for a header line on QUUX, and nothing on the CADR,
/// whose headers stay byte for byte what they were before QUUX had a timing.
pub fn timing_suffix(which: Which, t: TimingModel) -> String {
    match which {
        Which::Cadr => String::new(),
        Which::Quux => format!(", timing: {}", timing_name(t)),
    }
}
