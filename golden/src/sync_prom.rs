// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! MIT's TV sync PROM as a `$readmemh` image, out of muir's own
//! `tv::sync::prom`.
//!
//! One byte a line, two hex digits, [`CHIP_WORDS`] of them --- the 74S472 at
//! NSYRAM that the board runs its sync program out of until the software
//! loads the RAM and selects it. MIT burned 297 of the chip's 512 words
//! (`mit/cadrtv/cpt.prom`, "PROM ;for TV SYNC" of 5 May 1980) and muir sizes
//! its image to the highest address burned, so the tail reads as zero here,
//! exactly as `golden/src/prom.rs` leaves the boot PROM's unburned tail.
//!
//! Generated into `build/` and not committed, for the reason the boot PROM's
//! image is: MIT's material is muir's to carry, as the netlists are.

use muir::tv::sync;

/// Words of the 74S472 the program lives in. The image is the chip and the
/// program is the 297 words of it MIT burned --- `cadr_tv.sv`'s
/// `SYNC_PROM_WORDS`, which is where a fetch runs off the end of the program.
const CHIP_WORDS: usize = 512;

fn main() {
    let prom = sync::prom();
    assert!(
        prom.len() <= CHIP_WORDS,
        "the sync PROM image is {} words and the 74S472 has {CHIP_WORDS}",
        prom.len()
    );
    // The program's length goes out beside the image, so that the module's
    // own constant can be held to muir's rather than transcribed.
    eprintln!("sync_prom: {} words of MIT's program in {CHIP_WORDS} of chip", prom.len());
    for i in 0..CHIP_WORDS {
        println!("{:02x}", prom.get(i).copied().unwrap_or(0));
    }
}
