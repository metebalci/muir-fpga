// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the processor, out of muir's own `rtl` engine
//! running MIT's boot PROM; and with `--machine quux`, revision 13's whole
//! machine running its boot PROM, PROM 2001 (`QUUX_AWAIT_PACK` below).
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

/// **REVISION 13'S TRACE IS PROM 2001'S BOOT WITHOUT A PACK**, on QUUX at
/// its board's K and L: muir-sys's PROM at 36000, block-disk with no pack
/// on it, main memory's 32 boards and the video controller at the
/// bitstreams' 1280 by 1024 (`machine_axis.rs`), as `golden/src/quux13.rs`
/// builds revision 13.  Measured at the pin: the PROM's first memory cycle
/// is at microcycle 187,118, its block-disk registers written and its label
/// read, and at 187,132 it reaches `DISK-AWAIT-PACK` at 36611 (PROM 2001's
/// `promh.sym`), where it polls block-disk's status, one read in five
/// microcycles, for a pack that never comes.  The trace ends after
/// [`QUUX_POLLS`] of those polls, on the row before the next one starts, so
/// that no cycle is left in flight at its end; the generator fails if the
/// boot never gets there.
const QUUX_AWAIT_PACK: u16 = 0o36611;
const QUUX_POLLS: u64 = 256;
const QUUX_CAP: u64 = 1_000_000;

fn main() {
    // `--machine quux` takes the trace on QUUX, revision 13, from PROM 2001
    // (`--revision 13` may say so); without it this is the CADR's trace,
    // byte for byte what it always was.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    while let Some(i) = args.iter().position(|a| a == "--revision") {
        if which != machine_axis::Which::Quux || args.get(i + 1).map(String::as_str) != Some("13") {
            eprintln!("rtl: --revision is QUUX's, and 13 its one revision here");
            std::process::exit(2);
        }
        args.drain(i..(i + 2).min(args.len()));
    }
    // QUUX's trace is taken on its synchronous microcycle at the board's K.
    let timing = machine_axis::take_timing(which, &mut args);
    if let Some(a) = args.first() {
        eprintln!(
            "rtl: unknown argument `{a}`; usage: rtl [--machine cadr | --machine quux \
             [--revision 13] --sync-cycle-ticks K [--sync-ilong-ticks L]]"
        );
        std::process::exit(2);
    }
    let machine = || {
        let mut m = which.machine(&which.boot_prom());
        if which == machine_axis::Which::Quux {
            m.main = vec![0; 32 << 16];
            m.set_board_name("").expect("rtl: the board name");
        }
        m
    };
    let cycles = match which {
        machine_axis::Which::Cadr => CYCLES,
        machine_axis::Which::Quux => {
            let mut probe = trace::engine_on(machine(), timing);
            probe.boot();
            let mut t = trace::Trace::new(&probe);
            let mut n = 0u64;
            let mut polls = 0u64;
            loop {
                assert!(n < QUUX_CAP, "rtl: PROM 2001 never reached DISK-AWAIT-PACK at 36611");
                // The row about to run is the PC the last one left.
                if probe.pc() == QUUX_AWAIT_PACK {
                    if polls == QUUX_POLLS {
                        break;
                    }
                    polls += 1;
                }
                if let Err(h) = t.row(&mut probe, n) {
                    panic!("rtl: PROM 2001 stopped at microcycle {n}: {h:?}");
                }
                n += 1;
            }
            eprintln!("rtl: probe: {n} microcycles to PC {:o}", probe.pc());
            n
        }
    };
    let mut e = trace::engine_on(machine(), timing);
    e.boot();
    println!("{}", trace::COLUMNS);
    match which {
        machine_axis::Which::Cadr => {
            println!("# generated by golden/src/rtl.rs from muir's rtl engine on MIT's boot PROM")
        }
        machine_axis::Which::Quux => println!(
            "# generated by golden/src/rtl.rs from muir's rtl engine on QUUX's boot PROM 2001, \
             machine: quux, revision 13, video {}x{}, timing: {}",
            machine_axis::VIDEO_WIDTH,
            machine_axis::VIDEO_HEIGHT,
            machine_axis::timing_name(timing)
        ),
    }
    println!("{}", trace::RADIX);
    if which == machine_axis::Which::Quux {
        println!("# rtc {:x}", machine_axis::RTC_START);
    }

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

    // The file device's two bases as the run leaves them, which the
    // testbench reads through the readout's selector 12 on revision 13, as
    // `golden/src/quux13.rs` gives them.
    if which == machine_axis::Which::Quux {
        use muir::file_device as fd;
        let dev = &e.machine().file_device;
        println!("# fdbases {:x} {:x}", dev.read(fd::CMD_BASE, e.ns()), dev.read(fd::RESP_BASE, e.ns()));
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
