// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference for `rtl/machine/cadr_xbus_decode.sv`: which side of the bus a
//! physical address is on and whether anything lives there, out of muir's own
//! `busint::decode`.
//!
//! The Xbus carries 22 address bits --- `-XADDR0` to `-XADDR21` in
//! `data/busint-connectors.txt` --- so the whole space is 4,194,304 words and
//! can be checked address by address rather than sampled. That is what this
//! is for: the decode is piecewise constant over long runs, so the runs are
//! what gets written out, and the testbench expands them and walks every
//! address.
//!
//! The four answers, and where the boundaries come from:
//!
//! - **memory**, below `0o36000` pages and below the boards fitted. A board is
//!   64K words, so `phys[21:16] < boards`;
//! - **device**, Xbus I/O with something built at the address: the display's
//!   frame buffer at `0o17000000` for `0o100000` words, its eight control
//!   registers at `0o17377760`, and the disk controller's four at
//!   `0o17377774` --- and, on a machine that has a SECOND display board, the
//!   color TV's frame buffer at `0o17200000` and its control registers at
//!   `0o17377750`;
//! - **nxm**, Xbus space with nothing there --- "the cycle times out and sets
//!   the Xbus NXM bit";
//! - **unibus**, at or above page `0o37000`. Out of this slice: the Unibus
//!   path, the interface's own registers and the debug block are their own.
//!
//! The board count is swept because it is the one thing meant to change ---
//! going from two million words to the ceiling is this constant and no extra
//! fabric.  **And the color board is swept for a sharper reason**: its two
//! ranges must answer when it is fitted and must give the NXM when it is
//! not, because that is how `COLOR-EXISTS-P` in `sys/window/color.lisp`
//! finds out whether a machine has one.  muir's `busint::decode_with` takes
//! the same fact and `busint::decode` is it with none.

mod machine_axis;

use muir::busint::{self, Responder};
use muir::machine::Machine;

/// The Xbus address space: 22 bits.
const WORDS: u32 = 1 << 22;

/// A board is 64K words.
const WORDS_PER_BOARD: u32 = 1 << 16;

/// Board counts to sweep. One and sixty are the ends of muir's own
/// `--main-memory-boards`; 32 is its default, the two million words; 33 is
/// one board past it, the first count the boards' own `--main-memory-boards`
/// can give that a bitstream with 32 fixed never could; 2 is small enough
/// that the boundary sits well inside the space.
const BOARDS: &[u32] = &[1, 2, 32, 33, 60];

fn kind(r: Responder) -> &'static str {
    if r.on_unibus() {
        return "unibus";
    }
    match r {
        Responder::Memory(_) => "memory",
        Responder::Device => "device",
        _ => "nxm",
    }
}

/// **QUUX's decode is muir's own question asked on QUUX**, `busint::decode_quux`
/// (contracts Q5, Q7 and Q13), which `Rtl::start_bus_cycle` and
/// `Machine::bus_read` both take on QUUX: the register page,
/// `17777400`-`17777777`, a device; the video controller's frame buffer from
/// `17000000` at the bitstreams' size, `Tv::buffer_words`; main memory below
/// `17000000`; and nothing else.  The old register page at `17377000`, the
/// CADR's display and disk registers after it and the rest of the old Unibus
/// window are nothing there, and **QUUX has no color board**, so the color
/// input changes nothing on QUUX.  The machine is built by `machine_axis.rs`,
/// so the size is the one every other QUUX trace has.
///
/// **THE FRAME BUFFER IS NAMED A DEVICE HERE, AS THE FABRIC'S DECODE NAMES
/// IT**: muir answers it `Responder::Memory(0)`, the memory bus, and the
/// fabric takes it to the memory port the same way, but by the video
/// controller's own held match (`cadr_memory_path.sv`'s `video_fb`) inside
/// the decode's `device`, which is how the port tells the buffer from a
/// register.  So an address muir puts on the memory bus at or above
/// `tv::BUFFER`, which is only ever the buffer, is written `device`; every
/// boundary is still muir's, and what the buffer's cycles do is held on the
/// whole machine by `quux_tv` and `quux_port`.
fn decode(m: &Machine, phys: u32, words: usize) -> Responder {
    match busint::decode_quux(phys, words, m.tv.buffer_words()) {
        // The fabric's decode names the buffer a device and its port takes it as memory by `video_fb`; every boundary is still muir's.
        Responder::Memory(_) if phys >= muir::tv::BUFFER => Responder::Device,
        r => r,
    }
}

/// **Revision 13's decode is muir's `busint::decode_quux_13`** (contract G1
/// §3.2, G2 §4.1), over its 28-bit space: the register page at
/// `1777777400`, a device; the frame buffer window at `1760000000`, the video
/// controller's buffer long, and main memory below the window up to its end,
/// both the memory bus; nothing else.  The fabric's decode names the window
/// memory, as muir does, and its port tells the two apart by the address.
/// Every one of the 268,435,456 addresses is written as runs, for three board
/// counts: one, 65 --- main memory past 22 bits, over revision 12's frame
/// buffer and register page --- and 127, the most seven bits count.
const WORDS_13: u32 = 1 << 28;
const BOARDS_13: &[u32] = &[1, 65, 127];

fn revision_13(m: &Machine, channel: bool) {
    println!("# boards color first last kind");
    println!("# generated by golden/src/xbus_decode.rs from muir's busint::decode_quux_13 on QUUX revision 13, with its register page");
    if channel {
        println!("# the channel's view: main memory alone");
    }
    // **Block-disk's channel** (`--channel`): muir's transfer takes a
    // command list word and a page from main memory alone, `main.get` and
    // `page + PAGE > main.len()` (`BlockDisk::write_40`), so of what
    // `decode_quux_13` answers only main memory is memory to it, the words
    // below the window, and everything else is nothing.
    let kind13 = |phys: u32, words: usize| match busint::decode_quux_13(phys, words, m.tv.buffer_words()) {
        Responder::Memory(_) if channel && phys >= muir::machine::WINDOW_13 => "nxm",
        Responder::Device if channel => "nxm",
        r => kind(r),
    };
    let mut runs = 0;
    for &boards in BOARDS_13 {
        for color in [false, true] {
            let c = u8::from(color);
            let words = (boards * WORDS_PER_BOARD) as usize;
            let mut first = 0u32;
            let mut held = kind13(0, words);
            for phys in 1..WORDS_13 {
                let k = kind13(phys, words);
                if k != held {
                    println!("{boards} {c} {first} {} {held}", phys - 1);
                    runs += 1;
                    first = phys;
                    held = k;
                }
            }
            println!("{boards} {c} {first} {} {held}", WORDS_13 - 1);
            runs += 1;
        }
    }
    eprintln!("xbus_decode: revision 13: {runs} runs over {} board counts and both backplanes", BOARDS_13.len());
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let rev13 = args.first().is_some_and(|a| a == "--revision-13");
    if rev13 {
        args.remove(0);
    }
    let channel = rev13 && args.first().is_some_and(|a| a == "--channel");
    if channel {
        args.remove(0);
    }
    if let Some(a) = args.first() {
        eprintln!("xbus_decode: unknown argument `{a}`; usage: xbus_decode [--machine cadr|quux] [--revision-13 [--channel]]");
        std::process::exit(2);
    }
    if rev13 {
        if which != machine_axis::Which::Quux {
            eprintln!("xbus_decode: --revision-13 is QUUX's");
            std::process::exit(2);
        }
        revision_13(&which.machine(&[]), channel);
        return;
    }
    let quux = which == machine_axis::Which::Quux;
    let m = which.machine(&[]);
    println!("# boards color first last kind");
    if quux {
        println!("# generated by golden/src/xbus_decode.rs from muir's busint::decode_quux on QUUX, with its register page");
    } else {
        println!("# generated by golden/src/xbus_decode.rs from muir's busint::decode_with");
    }

    let mut runs = 0;
    for &boards in BOARDS {
        for color in [false, true] {
            let c = u8::from(color);
            let words = (boards * WORDS_PER_BOARD) as usize;
            let mut first = 0u32;
            let mut held = kind(if quux { decode(&m, 0, words) } else { busint::decode_with(0, words, color) });
            for phys in 1..WORDS {
                let k = kind(if quux { decode(&m, phys, words) } else { busint::decode_with(phys, words, color) });
                if k != held {
                    println!("{boards} {c} {first} {} {held}", phys - 1);
                    runs += 1;
                    first = phys;
                    held = k;
                }
            }
            println!("{boards} {c} {first} {} {held}", WORDS - 1);
            runs += 1;
        }
    }

    eprintln!("xbus_decode: {runs} runs over {} board counts and both backplanes", BOARDS.len());
}
