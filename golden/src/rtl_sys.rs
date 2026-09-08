// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The processor's second reference trace: muir's `rtl` engine running a
//! System release off a disk pack, in the same columns as `rtl.rs`.
//!
//! `rtl.rs` runs MIT's boot PROM, which is a real program and the right
//! primary reference --- but it is a program with a fixed path, and it stops
//! at `DISK-RECALIBRATE` spinning on a drive that is not there.  Measured
//! over its 600,000 microcycles it never reads the dispatch memory, never
//! runs microcode out of the control store, never shifts `Q`, and reads the
//! map exactly once.  This is the same engine and the same columns with a
//! pack under it, and it reaches all of those.
//!
//! **This trace is secondary and optional.**  `rtl.golden` stays primary: it
//! needs nothing but muir, and a checkout without the release still runs
//! every check that matters.  What this adds is coverage of the parts of the
//! processor the boot PROM cannot reach, and it is skipped --- and says so
//! --- when the release is not there.
//!
//! **THE PACK MUST BE A COPY, AND A FRESH ONE.**  A drive writes its pack:
//! muir opens the image read-write and a written block goes into the file.
//! A trace taken against a pack it is itself rewriting is not reproducible,
//! and would edit vendored material besides.  So this is given a path to a
//! copy that the Makefile decompresses out of the release archive in this
//! repository's own `vendor/`, whose SHA-256 the rule checks before using
//! it, and the starting state is the same every run.  The archive is
//! gitignored, so that check is the only thing that would notice it being
//! replaced --- which is why it is there and not merely tidy.
//!
//! Attaching the pack read-only is *not* the answer and was measured: the
//! drive's own read-only switch presents MIT's write fault, the band halts
//! on it, `PROMDISABLE` is never set and there is no boot to trace.
//!
//! **The shape of the run, measured.**  The machine leaves the boot PROM at
//! microcycle 1,410,035 and has first touched everything reachable by
//! 2,084,537.  So the interesting part is a *window* well after the boot,
//! and not the boot: at one line a microcycle the whole thing would be 4 GB
//! at thirty million and 14 GB at a hundred million, while 200,000
//! microcycles taken from 3,000,000 is 27 MB --- a third of the boot PROM's
//! own trace --- and holds, against that trace's whole 600,000:
//!
//!   MAP as the M bus source                1  ->    1,819
//!   the stack RAM changed                  2  ->    9,958
//!   Q shifted left / right             0 / 0  ->  2,310 / 128
//!   the dispatch memory read               0  ->   30,768
//!   PROMDISABLE set                        0  ->  all 200,000
//!   -ILONG where it lengthens the cycle    0  ->   30,768
//!
//! Every one of them inside the first 1,200 microcycles of the window.  The
//! boot is a second and a half, so it is run rather than checkpointed:
//! `muir::checkpoint` would save that second and a half and cost a second
//! artifact and a format to keep in step with.
//!
//! **What no trace reaches.**  `IR<46>`, the statistics counter, and
//! `MACHRUN` down: neither occurs in a hundred million microcycles here or
//! in six hundred thousand on the boot PROM.  Those are not a longer trace
//! away and this does not close them.
//!
//! **The columns are `rtl.rs`'s, and the stall drain with them.**  Two
//! programs write one format, which is a thing to keep an eye on: they are
//! meant to be read by one testbench, so the header line below and the
//! sampling of `LPC`, `MD` and `VMA` through a stall are copied from
//! `rtl.rs` deliberately and must move with it.  Worth factoring out when
//! the testbench that reads both is written.
//!
//! The first column is the *absolute* microcycle, so a line says where in
//! the run it came from rather than where in the file.

/// Five nanoseconds, the master clock's period: the step a stall is drained
/// in, small enough to land on the grid every instant of it is a multiple of.
const TICK_NS: u64 = 5;

/// Microcycles run before anything is written: the boot, which `rtl.golden`
/// already covers and which reaches none of what this trace is for.
const SKIP: u64 = 3_000_000;

/// Microcycles written. See the table above for what fits in them.
const CYCLES: u64 = 200_000;

use muir::disk_unit::{Geometry, Unit};
use muir::engine::Engine;
use muir::machine::Machine;
use muir::rtl::Rtl;

fn main() {
    let mut args = std::env::args().skip(1);
    let mut pack: Option<String> = None;
    let mut skip = SKIP;
    let mut cycles = CYCLES;
    while let Some(a) = args.next() {
        let mut value = |what: &str| {
            args.next()
                .unwrap_or_else(|| fail(&format!("{what} wants a value")))
        };
        match a.as_str() {
            "--pack" => pack = Some(value("--pack")),
            "--skip" => skip = parse(&value("--skip"), "--skip"),
            "--cycles" => cycles = parse(&value("--cycles"), "--cycles"),
            _ => fail(&format!(
                "unknown flag `{a}`\n\
                 usage: rtl_sys --pack <image> [--skip <microcycles>] [--cycles <microcycles>]"
            )),
        }
    }

    // The path is required rather than defaulted. Any default would be a
    // path to somebody's working image --- muir's `vendor/run` is the
    // obvious one --- and that is the file the machine rewrites, which is
    // exactly what this must not open.
    let Some(pack) = pack else {
        fail("--pack <image> is required: a copy of the release pack, not the vendored one");
    };
    let path = std::path::Path::new(&pack);
    if !path.exists() {
        fail(&format!(
            "{pack}: no such pack.\n\
             It is made by decompressing vendor/system-100-0/disk-sys-100-0.img.gz;\n\
             `make` does that, and muir's tools/fetch-system-100.sh is what fetches\n\
             the release the archive is copied from."
        ));
    }

    let mut m = Machine::new();
    m.load_prom(&muir::prom::boot_prom());
    // Read-write, and on the copy: see the note at the top of this file for
    // why neither half of that is optional.
    let unit = Unit::open_rw(path, Geometry::T300)
        .unwrap_or_else(|e| fail(&format!("{pack}: {e}")));
    m.disk.attach(0, unit);

    let mut e = Rtl::new(m);
    e.boot();

    // The boot, run and not written. Plain `step` here rather than the
    // stall-draining loop below: the two advance the machine identically ---
    // `step_until` is a way of *sampling* through a stall, not a different
    // way of running --- and this is three million microcycles of it.
    for n in 0..skip {
        if let Err(h) = e.step() {
            fail(&format!("stopped at microcycle {n} of the boot: {h:?}"));
        }
    }

    println!(
        "# cycle pc ir q a m alu r ob dc opc st lc \
         wmapd destspcd iwrited imodd pdlwrited spushd nop n_vmaok jcond pcs1 pcs0 srun \
         lpc md vma promdis errstop stathenb speed1 speed0 stall halted bus ack gnt ns"
    );
    println!(
        "# generated by golden/src/rtl_sys.rs from muir's rtl engine on a System pack"
    );
    println!("# every value hexadecimal; stall, halted and ns in nanoseconds");
    println!(
        "# {cycles} microcycles from {skip}; cycle is the absolute microcycle, not the line"
    );
    println!("# pack: {pack}");

    let mut last_stalled = e.stalled_ns();
    let mut last_halted = e.halted_ns();
    let mut last_bus = e.bus_cycles();

    let mut line = String::with_capacity(256);
    for n in 0..cycles {
        let cycle = skip + n;
        // `LPC`, `MD` and `VMA` as the read phase of this microcycle sees
        // them, which is after any stall and not before it. Copied from
        // rtl.rs, whose comment says why: a stall is usually a wait for
        // `MD`, `-LOADMD` strobes it while the clock is held off, and a
        // sample taken before the stall is the word the cycle was waiting to
        // be rid of.
        let mut lpc = e.lpc();
        let mut md = e.machine().md;
        let mut vma = e.machine().vma;
        let mut drained = 0u32;
        loop {
            let before = e.machine().cycles;
            if let Err(h) = e.step_until(e.ns() + TICK_NS) {
                fail(&format!("stopped at microcycle {cycle}: {h:?}"));
            }
            if e.machine().cycles != before {
                break;
            }
            drained += 1;
            assert!(
                drained < 100_000,
                "microcycle {cycle} never ran: the bus has not let go at PC {:o}",
                e.pc()
            );
            lpc = e.lpc();
            md = e.machine().md;
            vma = e.machine().vma;
        }

        let stall = e.stalled_ns() - last_stalled;
        last_stalled = e.stalled_ns();
        let halted = e.halted_ns() - last_halted;
        last_halted = e.halted_ns();
        let bus = e.bus_cycles() - last_bus;
        last_bus = e.bus_cycles();
        let ack = e.busint().ack_at().unwrap_or(0);
        let gnt = u8::from(e.busint().granted());

        line.clear();
        line.push_str(&format!("{cycle:x}"));
        for (_, v) in e.signals() {
            line.push_str(&format!(" {v:x}"));
        }
        for (_, v) in e.spy() {
            line.push_str(&format!(" {v:x}"));
        }
        let mode = &e.machine().mode;
        line.push_str(&format!(
            " {:x} {:x} {:x} {:x} {:x} {:x} {:x} {:x} {stall:x} {halted:x} {bus:x} {ack:x} {gnt:x} {:x}",
            lpc,
            md,
            vma,
            mode.prom_disable as u8,
            mode.errstop as u8,
            mode.stathenb as u8,
            mode.speed1 as u8,
            mode.speed0 as u8,
            e.ns()
        ));
        println!("{line}");
    }

    eprintln!(
        "rtl_sys: {cycles} microcycles from {skip}, {} ns ({} stalled, {} halted), \
         {} bus cycles, PC {:o}",
        e.ns(),
        e.stalled_ns(),
        e.halted_ns(),
        e.bus_cycles(),
        e.pc()
    );
}

fn parse(s: &str, what: &str) -> u64 {
    s.parse().unwrap_or_else(|_| fail(&format!("{what}: `{s}` is not a number")))
}

fn fail(msg: &str) -> ! {
    eprintln!("rtl_sys: {msg}");
    std::process::exit(1)
}
