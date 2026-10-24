// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! MIT's boot PROM as a `$readmemh` image, out of muir's own `prom::boot_prom`;
//! and with `--machine quux`, QUUX's, PROM 2002, out of muir's
//! `data/quux-promh.mcr` (`prom::quux_boot_prom`), one 64-bit word a line,
//! sixteen hex digits, the extension in `<63:48>`, which `quux15_store.sv`
//! takes.
//!
//! The CADR's is one 48-bit word a line, twelve hex digits, [`PROM_WORDS`]
//! of them --- the bottom 1K of the control store, which is what
//! `-PROMENABLE` at PCTL 1C19 overlays. The words are `Insn::raw()`, which is what `rtl.rs` fetches:
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
    if let Some(a) = args.first() {
        eprintln!("prom: unknown argument `{a}`; usage: prom [--machine cadr|quux]");
        std::process::exit(2);
    }
    let prom = which.boot_prom();
    for i in 0..PROM_WORDS {
        // The unburned tail of the PROM reads as zero, as `Machine::load_prom`
        // leaves it.
        let w = prom.get(i).map_or(0, |insn| insn.raw());
        match which {
            Which::Cadr => println!("{w:012x}"),
            Which::Quux => println!("{w:016x}"),
        }
    }
}
