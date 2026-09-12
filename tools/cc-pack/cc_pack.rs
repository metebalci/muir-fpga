// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later

//! **The debugger's disk pack: System 304 with CC compiled into the band.**
//!
//! muir on the board is the far end of the debug cable, and the debugger
//! is not muir --- it is CC, running on the CADR muir simulates. So muir
//! needs a band to boot and that band needs CC on it. muir's own
//! `tests/cc_304.rs` gets CC by compiling it over the Chaosnet FILE
//! service from a host on the model network, which on the board would
//! mean standing a file host up beside muir before the debugger could
//! exist at all. This compiles CC once, on the build host, and saves the
//! world back into a partition of the pack, so that on the board the
//! debugger is a pack you boot.
//!
//! This file is muir-fpga's and runs as one of muir's own integration
//! tests: the Chaosnet server that serves the release as `SYS:` lives in
//! muir's `tests/support/`, not in its library, so nothing outside a test
//! binary can compile a Lisp file on a simulated CADR.
//! `tools/make-cc-pack.sh` is the thing to run; it copies this beside
//! muir's own tests and drives the stages below.
//!
//! **The mechanism for saving a band is MIT's own `SI:DISK-SAVE`**
//! (`sys/qmisc.lisp:1157`), whose second argument is `NO-QUERY`: with it
//! true the routine asks the keyboard nothing at all, takes the version
//! string from `SYSTEM-VERSION-INFO`, writes the partition's comment, and
//! ends in the `%DISK-SAVE` microcode operation.
//!
//! **The form never returns, and what happens instead is worth knowing.**
//! `%DISK-SAVE` swaps every page out, finds the partition it was given,
//! writes the world into it region by region, and ends at `COLD-SWAP-IN`
//! --- "Physical core now clobbered, so re-swap-in"
//! (`ucadr/uc-cold-disk.lisp:174-176`). The world comes back **out of the
//! band it has just written**, with `A-DISK-OFFSET` now pointing there and
//! the cold initializations reset, so the machine carries on with a fresh
//! herald reading `band 3 of AMS-LISPM-1` and a who-line saying it
//! cold-booted. It does not go back to the band the label calls current,
//! and it does not touch the label's current-band word at all: that is
//! `diskpack`'s to set afterwards, off the machine.
//!
//! Everything the save writes reaches the file because the pack is opened
//! with `Unit::open_rw`, which is what `muir --disk-pack` does and what
//! muir's own tests deliberately do not: they open the vendored packs
//! read-only so that fetched material stays as fetched. The pack this
//! writes is a copy the script made, never the vendored one.
//!
//! Five tests, each run on its own, so that a cheap one can be had
//! without the expensive one.  Only `builds_the_cc_pack` and
//! `the_saved_band_has_cc` are what `tools/make-cc-pack.sh` runs; the
//! other three are measurements:
//!
//!   `boots_system_304`              the band reaches its listener.
//!   `saves_a_band`                  the saving mechanism with nothing
//!                                   loaded, which is the cheap way to
//!                                   ask whether the plan works at all.
//!   `builds_the_cc_pack`            compile CC, load it, save the band.
//!   `the_saved_band_has_cc`         boot the saved band, ask for
//!                                   `CADR:CC`.
//!   `the_saved_band_with_no_network` what a user at the board sees, muir
//!                                   there having no file or time host.
//!
//! The environment says where: `CC_PACK` is the pack to work on --- the
//! copy, written in place --- and `CC_PACK_ROOT` the Chaosnet FILE
//! service's root, whose `sys` is the release's sources. `CC_PACK_BAND`
//! is the partition the world is saved into, `LOD3` by default, and
//! `CC_PACK_FORCE` lets it be one that already holds a band.

#![allow(dead_code)]

mod support;

use std::path::{Path, PathBuf};

use muir::disk_unit::{Geometry, Unit};
use muir::engine::Engine;
use muir::machine::Machine;
use muir::rtl::Rtl;
use muir::simpletv::WIDTH;
use muir::terminal::keyboard::{Keyboard, keysym};

use support::{ChaosServer, time};

/// A path the environment names, and whether there is anything there.
fn env(name: &str) -> Option<PathBuf> {
    let p = PathBuf::from(std::env::var_os(name)?);
    if p.exists() {
        Some(p)
    } else {
        eprintln!("{name} is {} and there is nothing there", p.display());
        None
    }
}

/// The partition the world is saved into: `LOD3` unless told otherwise.
/// The System 304 pack has LOD3 to LOD6 empty at 24,225 blocks each and
/// LOD9 empty at 51,067, with LOD1 the cold load and LOD2 the release.
fn band() -> String {
    std::env::var("CC_PACK_BAND").unwrap_or_else(|_| "LOD3".to_string())
}

/// System 304's own Chaosnet numbers: the band is `AMS-LISPM-1` at 4401
/// and calls its file and time host `OZ` at 4403. At any other pair the
/// machine boots and reaches no server at all.
const CHAOS: (u16, u16) = (0o4401, 0o4403);

/// One machine with the boot PROM, the pack **read-write** on unit 0, and
/// the Chaosnet server on its cable.
fn machine(pack: &Path, root: PathBuf) -> Machine {
    let mut m = bare_machine(pack);
    ChaosServer::new(CHAOS.1)
        .named("OZ")
        .serving(root)
        .at_time(time::TEST_UNIVERSAL)
        .plug(&mut m, 0);
    m.ioboard.chaos.as_mut().unwrap().ether_mut().unwrap().keep_log(true);
    m
}

/// The same with nothing on the Chaosnet cable, which is what muir on the
/// board is: a CADR with no file host and no time host anywhere.
fn bare_machine(pack: &Path) -> Machine {
    let mut m = Machine::new();
    m.load_prom(&muir::prom::boot_prom());
    m.disk.attach(0, Unit::open_rw(pack, Geometry::T300).expect("the pack, read-write"));
    m.chaos.address = CHAOS.0;
    m.chaos.trace = std::env::var_os("MUIR_CHAOS_TRACE").is_some();
    m
}

/// A booted machine and what it needs to be typed at.
struct Cadr {
    e: Rtl,
    k: Keyboard,
    root: PathBuf,
    steps: u64,
    /// Microcycles with nothing moving after which a form is given up on.
    stall: u64,
}

impl Cadr {
    /// A minute and a half of the machine's time, as muir's own harness
    /// has it: right for a form that runs.
    const STALL: u64 = 600_000_000;
    /// A file is read over the network, compiled with nothing to say to
    /// it and written back, so one file's compilation is a long quiet
    /// stretch: about twenty-four minutes of the machine's time.
    const COMPILING: u64 = 8_000_000_000;

    fn new(pack: &Path, root: PathBuf) -> Cadr {
        Cadr::of(machine(pack, root.clone()), root)
    }

    fn of(m: Machine, root: PathBuf) -> Cadr {
        let mut e = Rtl::new(m);
        e.boot();
        Cadr { e, k: Keyboard::new(), root, steps: 0, stall: Self::STALL }
    }

    fn run(&mut self, n: u64) {
        for _ in 0..n {
            self.e.step().expect("the machine halted");
        }
        self.steps += n;
    }

    /// Lit pixels in rows `rows`.
    fn lit(&self, rows: std::ops::Range<usize>) -> usize {
        let tv = &self.e.machine().simpletv;
        rows.flat_map(|y| (0..WIDTH).map(move |x| (x, y))).filter(|&(x, y)| tv.pixel(x, y)).count()
    }

    /// Whether the listener is reading: the `;Reading at top level` line,
    /// in the band of rows muir's own tests watch for it.
    fn at_the_listener(&self) -> bool {
        self.lit(84..130) > 400
    }

    /// The screen, folded to a number: changed when it has.
    fn screen_hash(&self) -> u64 {
        self.e
            .machine()
            .simpletv
            .buffer()
            .iter()
            .fold(0xcbf2_9ce4_8422_2325u64, |h, &w| (h ^ w as u64).wrapping_mul(0x100_0000_01b3))
    }

    /// Where the heads are, as a block from the start of the pack.
    fn head_block(&self) -> u32 {
        match &self.e.machine().disk.units[0] {
            Some(u) => {
                let (c, h, b) = u.position();
                c * u.geometry.blocks_per_cylinder() + h * u.geometry.blocks_per_track + b
            }
            None => 0,
        }
    }

    fn screenshot(&self, name: &str) {
        let p = self.root.join(format!("{name}.png"));
        std::fs::write(&p, self.e.machine().simpletv.png()).unwrap();
        eprintln!("  screen at {}", p.display());
    }

    /// Runs to the listener, or says how far it got.
    fn to_the_listener(&mut self, limit: u64) {
        let from = self.steps;
        while !self.at_the_listener() {
            self.run(500_000);
            if self.steps - from > limit {
                self.screenshot("cc-pack-no-listener");
                panic!(
                    "the listener never began reading: {} microcycles, PC {:o}",
                    self.steps - from,
                    self.e.pc()
                );
            }
        }
        self.run(2_000_000);
    }

    /// Types `keys` a key at a time, each taken off the keyboard by the
    /// microcode and then echoed by Lisp before the next goes.  Timing
    /// alone will not do: the microcode's buffer holds 64 characters and
    /// Lisp empties it only when its process runs, so a long line typed
    /// as fast as the microcode takes it wraps the buffer and arrives
    /// garbled.  A key Lisp does not echo within a while goes on anyway,
    /// so that typing at something that shows nothing still ends.
    fn type_keys(&mut self, keys: Vec<u32>) {
        for sym in keys {
            let before = self.screen_hash();
            self.k.key(sym, true);
            self.k.key(sym, false);
            let mut waited = 0;
            while self.k.pending() > 0 || self.e.machine().ioboard.keyboard_ready() {
                self.k.deliver(&mut self.e.machine_mut().ioboard);
                self.run(1_000);
                waited += 1_000;
                assert!(waited < 50_000_000, "the machine never read the keyboard");
            }
            let mut echoed = 0;
            while self.screen_hash() == before && echoed < 20_000_000 {
                self.run(50_000);
                echoed += 50_000;
            }
        }
    }

    /// Types a line and Return.
    fn type_line(&mut self, text: &str) {
        self.type_keys(text.bytes().map(|b| b as u32).chain([keysym::RETURN]).collect());
    }

    /// Types a form with no Return: the listener runs it as soon as its
    /// last parenthesis is in, and a Return after it stays in the buffer
    /// as typeahead.
    fn type_form(&mut self, form: &str) {
        self.type_keys(form.bytes().map(|b| b as u32).collect());
    }

    /// Data frames over the Chaosnet so far: the file service moving.
    fn frames(&self) -> usize {
        use muir::chaos::ether::Event;
        use muir::chaos::packet::{Packet, op};
        let ether = self.e.machine().ioboard.chaos.as_ref().unwrap().ether().unwrap();
        ether
            .log
            .iter()
            .filter(|e| {
                let buffer = match e {
                    Event::Sent(_, _, buffer) => buffer,
                    Event::Heard(_, f) => &f.buffer,
                    Event::Collision(_) => return false,
                };
                Packet::from_buffer(buffer).is_ok_and(|(p, _)| op::is_data(p.opcode))
            })
            .count()
    }

    /// Types `form` with its output on the screen and on a file the
    /// Chaosnet server keeps, and runs until that file is closed; what
    /// was printed comes back.  muir's own harness's `ask`, with the
    /// debug cable --- which this run has none of --- left out of the
    /// progress test.
    fn ask(&mut self, name: &str, form: &str, limit: u64) -> String {
        let tmp = self.root.join("tmp");
        std::fs::create_dir_all(&tmp).unwrap();
        let file = tmp.join(format!("{name}.text"));
        let _ = std::fs::remove_file(&file);
        let before: std::collections::HashSet<PathBuf> = temp_files(&tmp).into_iter().collect();
        let line = format!(
            "(with-open-file (f \"OZ://tmp//{name}.text\" :direction :output) \
             (let* ((both (make-broadcast-stream terminal-io f)) \
             (standard-output both) (*standard-output* both)) {form}) \
             (format f \"~%~%*DONE*~%\"))"
        );
        self.type_form(&line);
        let from = self.steps;
        let done = |tmp: &PathBuf, file: &PathBuf| -> Option<Vec<u8>> {
            let fresh = temp_files(tmp).into_iter().filter(|t| !before.contains(t));
            for path in [file.clone()].into_iter().chain(fresh) {
                if let Ok(b) = std::fs::read(&path)
                    && ends_with_marker(&b)
                {
                    return Some(b);
                }
            }
            None
        };
        let (mut moved, mut moved_at) = (self.frames(), from);
        let mut reported = 0;
        let bytes = loop {
            if let Some(b) = done(&tmp, &file) {
                break b;
            }
            self.run(5_000_000);
            let gone = self.steps - from;
            let now = self.frames();
            if now != moved {
                (moved, moved_at) = (now, self.steps);
            }
            if gone / 1_000_000_000 > reported {
                reported = gone / 1_000_000_000;
                eprintln!("  {name}: {gone} microcycles on, {now} data frames");
            }
            if self.steps - moved_at > self.stall || gone > limit {
                self.screenshot(&format!("cc-pack-{name}-timeout"));
                panic!(
                    "{name}: no answer; nothing on the cable for {} microcycles, {gone} on",
                    self.steps - moved_at
                );
            }
        };
        eprintln!("  {name}: answered after {} microcycles", self.steps - from);
        let text: String = bytes
            .iter()
            .map(|&b| if b == 0o215 || b == b'\n' { '\n' } else { (b & 0x7f) as char })
            .collect();
        match text.rfind("*DONE*") {
            Some(i) => text[..i].trim_end().to_string(),
            None => text,
        }
    }

    /// Boots to the listener, logs in, and stops the window hanging at
    /// **MORE**, which a diagnostic's typeout would otherwise reach with
    /// nobody to press a key.
    fn login(&mut self) {
        self.to_the_listener(200_000_000);
        eprintln!("at the listener after {} microcycles", self.steps);
        self.type_line("(login 'lispm)");
        let from = self.steps;
        while self.lit(142..170) == 0 {
            self.run(1_000_000);
            assert!(self.steps - from < 60_000_000, "the login printed nothing");
        }
        self.run(5_000_000);
        self.type_line("(setq tv:more-processing-global-enable nil)");
        self.run(2_000_000);
    }
}

/// The FILE service's temporary files in `dir`: `#name#`, a write in
/// flight or interrupted.
fn temp_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('#')))
        .collect()
}

fn ends_with_marker(bytes: &[u8]) -> bool {
    let text: String =
        bytes.iter().map(|&b| if b == 0o215 { '\n' } else { (b & 0x7f) as char }).collect();
    text.trim_end().ends_with("*DONE*")
}

/// Where a partition of the pack is, read off the label: the first block
/// and how many.  The partition must be there and must be empty of a band
/// we would be overwriting by accident --- an empty comment is what the
/// label editor leaves and what `DISK-SAVE` fills in.
fn partition(pack: &Path, name: &str) -> (u32, u32) {
    let label = muir::band::Label::open(pack).expect("the pack's label");
    let p =
        label.partition(name).unwrap_or_else(|| panic!("{name} is not a partition of the pack"));
    eprintln!("{name} is at block {}, {} blocks long, comment {:?}", p.start, p.blocks, p.comment);
    // A partition with a comment in it has a band in it: `make-cold` and
    // `DISK-SAVE` both write one and the label editor leaves it empty.
    // Saving over the release's own band would still only spoil a copy,
    // but it would spoil it silently.
    assert!(
        p.comment.trim().is_empty() || std::env::var_os("CC_PACK_FORCE").is_some(),
        "{name} says {:?}, so there is a band in it; CC_PACK_FORCE=1 to write over it anyway",
        p.comment
    );
    (p.start, p.blocks)
}

/// What the environment says, or a word about what is missing.
fn setup() -> Option<(PathBuf, PathBuf)> {
    let (Some(pack), Some(root)) = (env("CC_PACK"), env("CC_PACK_ROOT")) else {
        eprintln!("skipped: CC_PACK and CC_PACK_ROOT say what to work on");
        return None;
    };
    Some((pack, root))
}

/// **Stage one.** The band boots and reaches its listener.
#[test]
#[ignore = "boots System 304: minutes; run with --ignored"]
fn boots_system_304() {
    let Some((pack, root)) = setup() else { return };
    let started = std::time::Instant::now();
    let mut c = Cadr::new(&pack, root);
    c.to_the_listener(200_000_000);
    eprintln!(
        "System 304 reached its listener at microcycle {} in {:.1} s",
        c.steps,
        started.elapsed().as_secs_f64()
    );
    c.screenshot("cc-pack-listener");
}

/// Six blocks spread through a partition, folded to one number: what the
/// dump changes, read back out of the pack file while the machine writes
/// it.  The last of the six is near the end of the partition, so a dump
/// that writes the band in order changes it last.
fn band_digest(pack: &Path, start: u32, blocks: u32) -> u64 {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(pack).expect("the pack");
    let mut h = 0xcbf2_9ce4_8422_2325u64;
    for at in [0, blocks / 10, blocks / 4, blocks / 2, blocks * 3 / 4, blocks - 1] {
        let mut b = [0u8; 1024];
        f.seek(SeekFrom::Start((start + at) as u64 * 1024)).unwrap();
        f.read_exact(&mut b).unwrap();
        for &x in &b {
            h = (h ^ x as u64).wrapping_mul(0x100_0000_01b3);
        }
    }
    h
}

/// The save itself, shared by the stage that loads CC first and the
/// stage that proves the mechanism without it.
///
/// `NO-QUERY` true, so nothing is asked at the keyboard; the version
/// string comes from `SYSTEM-VERSION-INFO` and the partition's comment is
/// written from it.  The form never returns: `%DISK-SAVE` ends by swapping
/// the world back in --- **out of the band it has just written**, measured,
/// and not out of whatever the label calls the current band --- so the
/// label is left for `diskpack` to set afterwards.
///
/// **Neither the screen nor the heads are the signal, and both were tried.**
/// `DISK-SAVE` deexposes every screen before it dumps, so the obvious
/// thing to wait for is the screen going black and the herald coming back
/// --- and a deexposed sheet leaves its bits where they were, so it never
/// goes black; worse, the rebooted herald lights 18,299 pixels where the
/// screen before the save lit 18,301, which is a coincidence that would
/// have read as "nothing happened" for ever.  The drive's head position is
/// no better: muir's controller moves a whole command list in one call, so
/// `Unit::position` is where the last list ended and a sampler never saw
/// it inside the partition at all.
///
/// **The pack itself is the signal**, which is right in principle as well
/// as in practice: the pack is the artefact this whole run exists to make.
/// Six blocks spread through the partition are read back out of the file
/// while the machine writes it; when they have changed from what they were
/// and then stayed put for a good while, the dump is over.  The reboot
/// that follows only reads.
fn save_the_band(c: &mut Cadr, pack: &Path, band: &str, start: u32, blocks: u32) {
    /// Microcycles the band must go unchanged before the save is called
    /// done: about two minutes of the machine's time, against a bare
    /// save measured at under 500,000,000 from the form to the herald.
    const QUIET: u64 = 600_000_000;
    eprintln!("saving the world into {band}, blocks {start} to {} ...", start + blocks);
    let was = band_digest(pack, start, blocks);
    let from = c.steps;
    c.type_form(&format!("(si:disk-save \"{band}\" t)"));
    let (mut digest, mut changed_at, mut moved) = (was, c.steps, false);
    let mut reported = 0;
    loop {
        c.run(1_000_000);
        let gone = c.steps - from;
        let now = band_digest(pack, start, blocks);
        if now != digest {
            if !moved {
                eprintln!("  save: the dump reached {band} at {gone} microcycles");
            }
            (digest, changed_at, moved) = (now, c.steps, true);
        }
        if moved && c.steps - changed_at > QUIET {
            break;
        }
        if gone / 500_000_000 > reported {
            reported = gone / 500_000_000;
            eprintln!(
                "  save: {gone} microcycles on, {} lit, band {}",
                c.lit(0..muir::simpletv::HEIGHT),
                if moved { "written" } else { "untouched" }
            );
            // One file, overwritten, so that somebody watching a run that
            // is going nowhere can see what the machine is showing.
            c.screenshot("cc-pack-saving");
        }
        // A save that has written nothing after this long has not started
        // and is not going to: `DISK-SAVE` reaches the partition inside
        // eight million microcycles on a bare world, measured, and what
        // stops it is an error in one of the `BEFORE-COLD` initializations
        // it runs first, which leaves the machine sitting in the error
        // handler for ever.  Fail there, with the screen, rather than
        // forty billion microcycles later with nothing to look at.
        if !moved && gone > 2_000_000_000 {
            c.screenshot("cc-pack-save-never-started");
            panic!(
                "the save wrote nothing to {band} in {gone} microcycles; \
                 read the screen --- an initialization that errors stops it here"
            );
        }
        if gone > 40_000_000_000 {
            c.screenshot("cc-pack-save-timeout");
            panic!("the save never finished: {band} was touched and did not settle");
        }
    }
    assert!(
        digest != was,
        "{band} is exactly as it was: nothing was written and this is not a save"
    );
    eprintln!(
        "{band} was written and settled {} microcycles after the form was typed",
        changed_at - from
    );
    // The swap-in: given its head, so that the run ends with a machine
    // that is alive rather than one last seen writing.
    c.run(40_000_000);
    eprintln!(
        "  after the swap-in: {} lit, at the listener {}",
        c.lit(0..muir::simpletv::HEIGHT),
        c.at_the_listener()
    );
    c.screenshot("cc-pack-after-save");
}

/// **Stage zero.** The saving mechanism itself, with nothing loaded: boot
/// the release, log in, and save the world straight into the band.  A few
/// minutes, and it answers the one question the whole plan rests on
/// before an hour is spent on the compile.
#[test]
#[ignore = "boots and saves a band: minutes; run with --ignored"]
fn saves_a_band() {
    let Some((pack, root)) = setup() else { return };
    let band = band();
    let (start, blocks) = partition(&pack, &band);
    let started = std::time::Instant::now();
    let mut c = Cadr::new(&pack, root);
    c.login();
    save_the_band(&mut c, &pack, &band, start, blocks);
    c.screenshot("cc-pack-bare-save");
    eprintln!(
        "done at microcycle {} in {:.1} s of wall clock",
        c.steps,
        started.elapsed().as_secs_f64()
    );
}

/// **Stage two.** CC compiled, loaded, and the world saved into a band.
#[test]
#[ignore = "compiles CC on the machine and saves a band: the better part of an hour"]
fn builds_the_cc_pack() {
    let Some((pack, root)) = setup() else { return };
    let band = band();
    let (start, blocks) = partition(&pack, &band);
    let started = std::time::Instant::now();
    let mut c = Cadr::new(&pack, root);
    c.login();
    let who = c.ask("cc-pack-login", "(princ si:user-id)", 2_000_000_000);
    assert!(who.contains("LISPM"), "logged in: {who:?}");

    // System 304 ships the sources alone --- there is no `CC QFASL` in
    // the release --- so the sixteen files are compiled on the machine.
    c.stall = Cadr::COMPILING;
    let from = c.steps;
    let out = c.ask(
        "cc-pack-make-system",
        "(make-system 'cc :compile :noconfirm :nowarn)",
        40_000_000_000,
    );
    c.stall = Cadr::STALL;
    eprintln!("make-system took {} microcycles, printed {} bytes", c.steps - from, out.len());
    c.screenshot("cc-pack-make-system");
    assert!(
        !out.contains("not a known MAKE-ARRAY keyword"),
        "the old MAKE-ARRAY form is still in CC's sources:\n{}",
        &out[out.len().saturating_sub(2000)..]
    );

    let loaded = c.ask(
        "cc-pack-loaded",
        "(princ (if (fboundp 'cadr:cc) 'cc-loaded 'cc-missing))",
        2_000_000_000,
    );
    assert!(loaded.contains("CC-LOADED"), "CC did not load: {loaded:?}");
    eprintln!("CC is loaded at microcycle {}", c.steps);

    // **CC's own cold initialization has to be run before the save, and
    // this was found by the save falling over.**  `cc/cc.lisp:1400` adds
    // "Assure CC Symbols loaded" to the `BEFORE-COLD` list, and
    // `DISK-SAVE`'s first act is to run that list --- so a world with CC
    // freshly loaded in it cannot be saved at all: `CC-FILE-SYMBOLS-
    // LOADED-FROM` is `(DEFVAR ... :UNBOUND)` (`cc/cadld.lisp:5`) and
    // `ASSURE-CC-SYMBOLS-LOADED` reads it, so the save stops in the error
    // handler on `>>TRAP 8084 (TRANS-TRAP)` and never writes a block.
    //
    // Setting it to `NIL` is not a way round the initialization but the
    // way to make it do its job: with `NIL` there the version test fails,
    // and it loads `SYS: UBIN; UCADR SYM #323` over the file service ---
    // the microcode's own symbol table, the thing that lets CC name a
    // control-store address instead of printing a number.  Running it
    // here rather than leaving it to the save means the band carries
    // those symbols, and the save's own run of the list then finds the
    // right version loaded and does nothing.  **That is the file service
    // paying for itself twice**: CC compiled, and CC's symbols, neither
    // of which the board can fetch.
    let sym = c.ask(
        "cc-pack-symbols",
        "(progn (setq cadr:cc-file-symbols-loaded-from nil) \
         (cadr:assure-cc-symbols-loaded) \
         (princ (if cadr:cc-file-symbols-loaded-from 'symbols-loaded 'symbols-missing)))",
        4_000_000_000,
    );
    eprintln!("CC's microcode symbols: {sym:?}");
    assert!(sym.contains("SYMBOLS-LOADED"), "CC's symbols did not load: {sym:?}");

    save_the_band(&mut c, &pack, &band, start, blocks);
    c.screenshot("cc-pack-saved");
    eprintln!(
        "done at microcycle {} in {:.1} s of wall clock",
        c.steps,
        started.elapsed().as_secs_f64()
    );
}

/// **Stage three.** The saved band boots and CC is in it.  The label's
/// current band must already be the one that was saved into, which
/// `tools/make-cc-pack.sh` sets with `diskpack` between the two stages.
#[test]
#[ignore = "boots the saved band: minutes; run with --ignored"]
fn the_saved_band_has_cc() {
    let Some((pack, root)) = setup() else { return };
    let started = std::time::Instant::now();
    let mut c = Cadr::new(&pack, root);
    c.login();
    let loaded = c.ask(
        "cc-pack-check",
        "(princ (if (fboundp 'cadr:cc) 'cc-loaded 'cc-missing))",
        2_000_000_000,
    );
    eprintln!("CADR:CC on the saved band: {loaded:?}");
    c.screenshot("cc-pack-check");
    assert!(loaded.contains("CC-LOADED"), "the saved band has no CC: {loaded:?}");
    eprintln!(
        "the saved band came up with CC in it at microcycle {} in {:.1} s",
        c.steps,
        started.elapsed().as_secs_f64()
    );
}

/// **What the board gets.** The saved band with nothing on the Chaosnet
/// cable at all, which is muir on the board: no file host, no time host,
/// nobody to ask.  The band's cold initializations ask the network for the
/// date, so this says what a user at the board's own terminal will be
/// looking at when muir comes up, and it is a measurement rather than a
/// pass or a fail.  What it writes is a screenshot; read it.
#[test]
#[ignore = "boots the saved band with no network: minutes; run with --ignored"]
fn the_saved_band_with_no_network() {
    let Some((pack, root)) = setup() else { return };
    let started = std::time::Instant::now();
    let mut c = Cadr::of(bare_machine(&pack), root);
    // No `to_the_listener`: a band that stops to ask for the date never
    // gets there, and being told how far it got is the point.
    for _ in 0..60 {
        c.run(1_000_000);
        if c.at_the_listener() {
            break;
        }
    }
    eprintln!(
        "with no network: {} microcycles, {} lit, at the listener {}, in {:.1} s",
        c.steps,
        c.lit(0..muir::simpletv::HEIGHT),
        c.at_the_listener(),
        started.elapsed().as_secs_f64()
    );
    c.screenshot("cc-pack-no-network");
    // And what a person at the terminal would do about it: the date, then
    // the confirmation it asks for.  **The band reads the date the British
    // way round** --- `09/12/26` came back as "the ninth of December,
    // 1926" --- so it is day, month, year, and the year wants all four
    // digits.
    c.type_line("12/09/2026 21:30:00");
    c.run(20_000_000);
    c.type_line("Y");
    for _ in 0..120 {
        c.run(1_000_000);
        if c.at_the_listener() {
            break;
        }
    }
    eprintln!(
        "after a date was typed: {} microcycles, at the listener {}",
        c.steps,
        c.at_the_listener()
    );
    c.screenshot("cc-pack-no-network-dated");
}
