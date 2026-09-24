// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the processor, out of muir's own `rtl` engine
//! running MIT's boot PROM.
//!
//! One line per microcycle.  `Rtl::signals()` returns the datapath of the
//! microcycle just executed under the drawings' own net names --- `PC IR Q A
//! M ALU R OB DC OPC ST LC` --- and its own doc calls that "the only
//! vocabulary the two engines share", so it is the vocabulary here too.
//! `Rtl::spy()` adds the twelve flags the console reads.
//!
//! Unlike every other trace in this directory the stimulus is not scripted:
//! it is MIT's boot PROM, a real program, and the only thing driven in is the
//! machine coming up.  Which columns a testbench takes as stimulus and which
//! it compares is the testbench's business, and it narrows as the slices
//! land; the trace is the whole microcycle either way.
//!
//! Six columns are the machine's own *inputs* rather than its datapath, and
//! they are here because nothing outside muir can recover them:
//!
//! - `lpc`, `Rtl::lpc()` as the read phase sees it, the 25S07s at LPC
//!   4F06-4F08: the PC of the microcycle before this one.
//! - `md` and `vma`, the 74S374s on pages MD and VMA, sampled before the
//!   step for the same reason `lpc` is: they reach the M bus as functional
//!   sources, `MD` on 284,000 of these microcycles and `VMA` on 6,000, and
//!   the memory path that makes them is a later slice.
//! - `promdis`, `errstop`, `stathenb`, `speed1` and `speed0`, the mode
//!   register's bits at OLORD1 1A09.  The speed reaches the generator through the synchronizer at
//!   1A01, clocked by `SPEEDCLK` 60 ns into the cycle, so the register
//!   stands one stage ahead of the microcycle it lengthens.  The fabric has
//!   that synchronizer; what it has no console to write is the register.
//! - `stall`, the nanoseconds this microcycle spent held off before it ran,
//!   and `halted`, the nanoseconds spent with `MACHRUN` down and no
//!   microcycle run at all.  Both come from the bus, and until the memory
//!   path is under the processor the fabric has nothing to make them from.
//! - `bus`, memory cycles started, which says which microcycles those were.
//!
//! **What this program does not exercise.**  It boots at `Speed::ExtraSlow`
//! and never writes the speed bits, and at extra slow both taps of the
//! 74S151 are `-TPR160` --- so every microcycle here is 220 ns and `ILONG`
//! changes nothing.  It never sets `IR<46>`, so the statistics counter never
//! counts.  It never halts.  The scripted trace behind `cadr_phase_gen.sv`
//! is what covers the seven taps and the two ways the generator is held;
//! this one covers the microcycle riding on them.

mod machine_axis;
mod trace;

use muir::engine::Engine;

/// How many microcycles the trace runs for.
///
/// The shape of the run, measured: 393,222 microcycles go round a
/// six-instruction loop at 0o240 65,537 times; the control store is then
/// loaded a word at a time --- 16,384 `WRITE-I-MEM`s, each a jump to the
/// address being written, a nopped cycle that lands the word, and a pop back
/// --- and at microcycle 418,007 the machine jumps to 0o2000 and runs out of
/// what it has just written.  The first memory cycle is at 535,791.
///
/// It reaches `DISK-RECALIBRATE` at 0o541 --- where the PROM spins on a drive
/// that is not there, which is as far as it goes without a pack --- at
/// microcycle 413,310.  Six hundred thousand is that and sixty thousand
/// microcycles of the wait, which is where the memory cycles are; running on
/// only lengthens the file.
const CYCLES: u64 = 600_000;

/// **QUUX's trace is MIT's run moved on by the extra clearing, and as long.**
/// QUUX's boot PROM clears a 16K-word PDL buffer where MIT's clears 1K, and
/// 64 blocks of level-2 map where MIT's clears 32; measured, its first memory
/// cycle is at microcycle 667,375 against the CADR's 536,302, exactly 131,073
/// (`0x20001`) later.  So QUUX's trace runs that much longer than the CADR's,
/// through the memory sizing, its NXM cycles and the disk's polling, as MIT's
/// does.  It used to stop at 668,911, before the sizing's first read of empty
/// space, whose `MBUSY` clear fell on a master clock edge that the fabric then
/// took a tick late; a change on an edge counts as before it now, on both
/// machines, and the cut is gone.
const QUUX_CYCLES: u64 = CYCLES + 0x20001;

fn main() {
    // `--machine quux` takes the trace on QUUX, from QUUX's own boot PROM,
    // with MONO TV at the bitstreams' size (`machine_axis.rs`).  Without it
    // this is the CADR's trace, byte for byte what it always was.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    // QUUX's trace is taken on its synchronous microcycle at the board's K.
    let timing = machine_axis::take_timing(which, &mut args);
    if let Some(a) = args.first() {
        eprintln!(
            "rtl: unknown argument `{a}`; usage: rtl [--machine cadr|quux] \
             [--sync-cycle-ticks K [--sync-ilong-ticks L]]"
        );
        std::process::exit(2);
    }
    let m = which.machine(&which.boot_prom());
    let mut e = trace::engine_on(m, timing);
    e.boot();

    println!("{}", trace::COLUMNS);
    match which {
        machine_axis::Which::Cadr => println!(
            "# generated by golden/src/rtl.rs from muir's rtl engine on MIT's boot PROM"
        ),
        machine_axis::Which::Quux => println!(
            "# generated by golden/src/rtl.rs from muir's rtl engine on QUUX's boot PROM, \
             machine: quux, MONO TV {}x{}, timing: {}",
            machine_axis::MONO_TV_WIDTH,
            machine_axis::MONO_TV_HEIGHT,
            machine_axis::timing_name(timing)
        ),
    }
    println!("{}", trace::RADIX);

    let cycles = match which {
        machine_axis::Which::Cadr => CYCLES,
        machine_axis::Which::Quux => QUUX_CYCLES,
    };
    let mut t = trace::Trace::new(&e);
    for cycle in 0..cycles {
        match t.row(&mut e, cycle) {
            Ok(line) => println!("{line}"),
            Err(h) => {
                eprintln!("rtl: stopped at microcycle {cycle}: {h:?}");
                std::process::exit(1);
            }
        }
    }

    eprintln!(
        "rtl: {cycles} microcycles, {} ns ({} stalled, {} halted), \
         {} bus cycles, PC {:o}",
        e.ns(),
        e.stalled_ns(),
        e.halted_ns(),
        e.bus_cycles(),
        e.pc()
    );
}
