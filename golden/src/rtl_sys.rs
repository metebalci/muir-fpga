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
//! 2,084,537, so the trace runs from zero to 2,200,000 --- 297 MB, ten
//! seconds to write.  A *window* into the middle would be a fifth of that
//! and was tried first; it cannot be checked at all, because a fabric that
//! boots from reset does not have the machine's state at microcycle three
//! million and no column of the trace carries it.  Against `rtl.golden`'s
//! whole 600,000:
//!
//!   MAP as the M bus source                1  ->    1,125
//!   the dispatch memory read               0  ->   14,323
//!   Q shifted                              0  ->   26,765
//!   PROMDISABLE set                        0  ->  789,965
//!   -ILONG                                 0  ->   18,419
//!
//! The testbench asserts every one of them, so a trace that stops reaching
//! them stops earning its 297 MB.
//!
//! **What no trace reaches.**  `IR<46>`, the statistics counter, and
//! `MACHRUN` down: neither occurs in a hundred million microcycles here or
//! in six hundred thousand on the boot PROM.  Those are not a longer trace
//! away and this does not close them.
//!
//! **The columns are `golden/src/trace.rs`'s**, and so is the sampling
//! through a stall.  Two programs writing one format by hand is a thing that
//! drifts, and had: this one took `ack` after the step where `rtl.rs` watched
//! it through the stall, losing the bus cycle that arbitrates for the Unibus.
//! One `row` now serves both.
//!
//! The first column is the *absolute* microcycle, so a line says where in
//! the run it came from rather than where in the file.

/// Microcycles run before anything is written.
///
/// **Zero, and it has to be.**  A window into the middle of a run is not
/// checkable by a fabric that boots from reset: at microcycle three million
/// the machine has a control store, four scratchpads, a stack, two levels of
/// map and thirty registers full of state that no column of the trace
/// carries, and the fabric starting cold agrees with none of it.  Measured:
/// the check fails on PC and IR at the window's first row.
///
/// The alternative was to ship the window with the state it starts from ---
/// seven memories and every register, as files and elaboration parameters ---
/// which is a second format to keep in step with the RTL and a backdoor into
/// the registers besides.  Running from zero costs 297 MB and ten seconds and
/// needs neither.
const SKIP: u64 = 0;

/// Microcycles written.
///
/// The machine leaves the boot PROM at 1,410,035 and has first touched
/// everything reachable by 2,084,537, so this is that with room after it.
/// From zero the trace is a superset of `rtl.golden`'s coverage rather than a
/// disjoint window: it boots the PROM too.
const CYCLES: u64 = 2_200_000;

mod trace;

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

    println!("{}", trace::COLUMNS);
    println!("# generated by golden/src/rtl_sys.rs from muir's rtl engine on a System pack");
    println!("{}", trace::RADIX);
    println!(
        "# {cycles} microcycles from {skip}; cycle is the absolute microcycle, not the line"
    );
    println!("# pack: {pack}");

    let mut t = trace::Trace::new(&e);
    for n in 0..cycles {
        let cycle = skip + n;
        match t.row(&mut e, cycle) {
            Ok(line) => println!("{line}"),
            Err(h) => fail(&format!("stopped at microcycle {cycle}: {h:?}")),
        }
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
