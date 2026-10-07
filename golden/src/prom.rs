// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! MIT's boot PROM as a `$readmemh` image, out of muir's own `prom::boot_prom`;
//! and with `--machine quux --word-bits 40`, QUUX revision 13's, version
//! 2001, out of muir's `data/quux-promh.mcr` (`prom::quux_boot_prom`).
//! Revision 12 and its PROM 2000 are retired, so QUUX at 32 bits is
//! refused (contract G2).
//!
//! **And with `--revision 14 --mcr <file>`, revision 14's, PROM 2002**
//! (contract G3 revision 14), out of the MCR file muir-sys hands over, read
//! by muir's own reader at revision 14's geometry, `prom::parse_quux_mcr`,
//! which is what `quux --prom` runs.  muir carries no PROM 2002 of its own,
//! so the file is named; the Makefile holds it and the image to their
//! digests (`QUUX_PROM_2002`).
//!
//! One 48-bit word a line, twelve hex digits, [`PROM_WORDS`] of them --- the
//! bottom 1K of the control store, which is what `-PROMENABLE` at PCTL 1C19
//! overlays. The words are `Insn::raw()`, which is what `rtl.rs` fetches:
//! not `prom::boot_prom_image`, which is the *burned* representation with
//! `IR<47>` moved and the statistics bit dropped.
//!
//! Generated into `build/` and not committed. MIT's microcode is muir's to
//! carry; nothing here vendors a copy of it, as nothing here vendors the
//! netlists.

mod machine_axis;

use machine_axis::Which;
use muir::machine::PROM_WORDS;

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    // `--word-bits 40` is QUUX revision 13, the Makefile's and the flows'
    // `WORD_BITS`; 32, or nothing, is the CADR's word.
    let mut word_bits = 32;
    while let Some(i) = args.iter().position(|a| a == "--word-bits") {
        word_bits = match args.get(i + 1).map(String::as_str) {
            Some("32") => 32,
            Some("40") => 40,
            v => {
                eprintln!("prom: --word-bits is `{}`; it is 32, or 40 for QUUX revision 13", v.unwrap_or(""));
                std::process::exit(2);
            }
        };
        args.drain(i..(i + 2).min(args.len()));
    }
    let mut revision = 13;
    while let Some(i) = args.iter().position(|a| a == "--revision") {
        revision = match args.get(i + 1).map(String::as_str) {
            Some("13") => 13,
            Some("14") => 14,
            v => {
                eprintln!("prom: --revision is `{}`; it is 13, or 14", v.unwrap_or(""));
                std::process::exit(2);
            }
        };
        args.drain(i..(i + 2).min(args.len()));
    }
    let mut mcr = None;
    while let Some(i) = args.iter().position(|a| a == "--mcr") {
        mcr = args.get(i + 1).cloned();
        if mcr.is_none() {
            eprintln!("prom: --mcr wants a file");
            std::process::exit(2);
        }
        args.drain(i..(i + 2).min(args.len()));
    }
    if let Some(a) = args.first() {
        eprintln!(
            "prom: unknown argument `{a}`; usage: prom [--machine cadr|quux] [--word-bits 32|40] \
             [--revision 14 --mcr <file>]"
        );
        std::process::exit(2);
    }
    if revision == 14 || mcr.is_some() {
        // Revision 14's PROM 2002, out of the hand-over's file.
        let (Which::Quux, 40, 14, Some(path)) = (which, word_bits, revision, mcr.as_ref()) else {
            eprintln!("prom: PROM 2002 is QUUX's at revision 14: give --machine quux --word-bits 40 --revision 14 --mcr <file>");
            std::process::exit(2);
        };
        let bytes = std::fs::read(path).unwrap_or_else(|e| {
            eprintln!("prom: {path}: {e}");
            std::process::exit(2);
        });
        let prom = muir::prom::parse_quux_mcr(&bytes, muir::machine::Geometry::QUUX_14).unwrap_or_else(|e| {
            eprintln!("prom: {path}: {e}");
            std::process::exit(2);
        });
        for i in 0..PROM_WORDS {
            let w = prom.get(i).map_or(0, |insn| insn.raw());
            println!("{w:012x}");
        }
        return;
    }
    let prom = match (which, word_bits) {
        (Which::Quux, 40) => which.boot_prom(),
        (Which::Cadr, 40) => {
            eprintln!("prom: --word-bits 40 is QUUX revision 13; the CADR's word is 32 bits");
            std::process::exit(2);
        }
        (Which::Quux, _) => {
            eprintln!("prom: QUUX's word is 40 bits, --word-bits 40; revision 12 is retired");
            std::process::exit(2);
        }
        (Which::Cadr, _) => which.boot_prom(),
    };
    for i in 0..PROM_WORDS {
        // The unburned tail of the PROM reads as zero, as `Machine::load_prom`
        // leaves it.
        let w = prom.get(i).map_or(0, |insn| insn.raw());
        println!("{w:012x}");
    }
}
