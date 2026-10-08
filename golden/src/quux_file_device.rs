// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! QUUX's file device (contract Q9) as muir's own `file_device::FileDevice`
//! answers a script of ring operations over a folder of the host.  The same
//! script is run through `quux-file-device`'s protocol core by that
//! package's `qfd_test`, and the two transcripts, and the two folders after,
//! must agree byte for byte.
//!
//! One operation a line, numbers decimal or `0x` hexadecimal:
//!
//! ```text
//! revision 13           first, always: a revision-13 machine's device and main
//!                       memory, 40-bit words (contract G2 §4.3, appendix A1.10);
//!                       revision 12, whose words were 32 bits, is retired
//! memory WORDS          main memory's size, zeroed
//! root SPEC             a --file-root value, `@` standing for the folder
//! describe              the mounts as the start lists them
//! rings CB CL RB RL     the rings' bases and log2 sizes (registers 162-167)
//! enable IE             160 = 1 | IE << 8
//! disable               160 = 0
//! reset                 a machine reset
//! fill ADDR N WORD      N words of main memory from ADDR set to WORD
//! bytes ADDR HEX [TAG]  bytes into memory from word ADDR, the last word padded with 0,
//!                       each word tagged TAG on revision 13 (0 if none)
//! cmd W0 ... W7         a command entry at the producer's slot, and the producer + 1
//! post                  164 written with the producer
//! consume N             171 written with 171 + N
//! nowat I               response I's word 4 is the host's clock: printed as NOW if it
//!                       is, and then zeroed in memory, so the digest does not see it
//! run                   the device runs everything it can, and the transcript says what
//! hostwrite REL HEX     the host writes a file itself (a file that appeared meanwhile)
//! hostrm REL            the host removes a file itself
//! utime REL SECS        the host sets a file's modification time
//! chmod REL OCTAL       the host sets a file's or a folder's permissions
//! ```
//!
//! After each `run` the transcript has, in order: each new response as
//! `resp I` and its eight words; the words of the buffer B its command named,
//! as `b I` (where that buffer is one); every line LOG printed, as muir's
//! `log_line` gives it; the handles open and the commands queued; muir's
//! checkpoint refusal; and a 64-bit FNV-1a of the whole of main memory, so
//! that a word written anywhere else is seen.
//!
//! **ON REVISION 13** every word is written in ten hex digits, its tag first,
//! and the digest is over main memory as packed storage holds it, 5 bytes a
//! word, `<7:0>` first and the tag last (G1 §4.1): the bytes
//! `quux-file-device` writes into DDR.  A `cmd` or `fill` word may carry a
//! tag, which the device must not read.  Then every directory under the
//! folder has its modification time set to 1000000000, because a directory's
//! time moves with every entry made in it and that is the host's, not the
//! device's.
//!
//! `--errno-table` prints muir's status for every errno from 1 to 133
//! instead, `errno status` a line.

use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use muir::file_device::{
    CMD_BASE, CMD_PROD, CMD_SIZE, CONTROL, FileDevice, Mounts, RESP_BASE, RESP_CONS, RESP_SIZE,
    host_status, log_line,
};
use muir::machine::MemoryWord;

/// The device's time in nanoseconds, a unit to the ns: QUUX revision 13's
/// and 14's time base (muir's `TimeBase::NS`; revision 15 counts 0.5 ns).
const NS: muir::clock::TimeBase = muir::clock::TimeBase::NS;

fn num(s: &str) -> u64 {
    match s.strip_prefix("0x") {
        Some(h) => u64::from_str_radix(h, 16),
        None => s.parse(),
    }
    .unwrap_or_else(|_| panic!("not a number: {s}"))
}

fn hex_bytes(s: &str) -> Vec<u8> {
    if s == "-" {
        return Vec::new();
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

/// A word of main memory as this program keeps it: 40 bits, revision 13's,
/// and how it is printed and stored.
trait Cell: MemoryWord + Default {
    /// Hex digits in the transcript.
    const DIGITS: usize;
    /// Bytes as main memory stores it: 4, or 5 of packed storage.
    const BYTES: usize;
    fn wide(self) -> u64;
    /// A script's number: `<31:0>` and, where the word has it, the tag.
    fn from_script(v: u64) -> Self {
        Self::tagged(v as u32, (v >> 32) as u8)
    }
}

impl Cell for u64 {
    const DIGITS: usize = 10;
    const BYTES: usize = 5;
    fn wide(self) -> u64 {
        self & 0xff_ffff_ffff
    }
}

fn fnv<W: Cell>(words: &[W]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for w in words {
        for b in &w.wide().to_le_bytes()[..W::BYTES] {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100_0000_01b3);
        }
    }
    h
}

/// Every directory under `dir`, itself included, to 1000000000; symlinks
/// are not followed.
fn settle_dirs(dir: &Path) {
    let Ok(m) = fs::symlink_metadata(dir) else { return };
    if !m.is_dir() {
        return;
    }
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            settle_dirs(&e.path());
        }
    }
    let t = UNIX_EPOCH + Duration::from_secs(1_000_000_000);
    // One the device cannot enter (a test of ACC) keeps its time: nothing
    // in it changes.
    if let Ok(f) = fs::File::open(dir) {
        f.set_modified(t).expect("a directory's time is set");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--errno-table") {
        for e in 1..=133 {
            println!("{e} {}", host_status(&io::Error::from_raw_os_error(e)));
        }
        return;
    }
    let (mut script, mut tree, mut out) = (None, None, None);
    let mut i = 1;
    while i < args.len() {
        let v = args.get(i + 1).cloned();
        match args[i].as_str() {
            "--script" => script = v,
            "--tree" => tree = v,
            "--out" => out = v,
            a => panic!("unknown argument {a}"),
        }
        i += 2;
    }
    let script = script.expect("--script");
    let tree = PathBuf::from(tree.expect("--tree"));
    let out = out.expect("--out");
    let text = fs::read_to_string(&script).expect("the script");
    // `revision 13` is the first operation: revision 12 is retired.
    let first = text.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with('#'));
    assert!(
        first == Some("revision 13"),
        "{script}: `revision 13` is the first operation; revision 12 is retired"
    );
    let t = run::<u64>(&script, &text, &tree, true);
    fs::write(&out, t).expect("the transcript");
}

fn run<W: Cell>(script: &str, text: &str, tree: &Path, revision_13: bool) -> String {
    let tree_s = tree.to_str().unwrap().to_string();
    let (address, line) = if revision_13 { (0o1777777777u32, 7usize) } else { (0xff_ffff, 3) };
    let mut t = String::new();
    let mut dev = FileDevice::new();
    dev.log = Some(Vec::new());
    let mut mounts = Mounts::default();
    let mut main: Vec<W> = Vec::new();
    let mut now: u64 = 1;
    let (mut cb, mut cl, mut rb, mut rl) = (0u32, 0u32, 0u32, 0u32);
    let (mut prod, mut rcons, mut seen) = (0u16, 0u16, 0u16);
    let mut nowat: Vec<u16> = Vec::new();
    let mut logged = 0usize;
    settle_dirs(tree);

    for (n, line_text) in text.lines().enumerate() {
        let w: Vec<&str> = line_text.split_whitespace().collect();
        if w.is_empty() || w[0].starts_with('#') {
            continue;
        }
        now += 1_000_000;
        let host = |rel: &str| tree.join(rel);
        match w[0] {
            "revision" => assert!(
                revision_13 && w.get(1) == Some(&"13"),
                "{script}:{}: `revision 13` is the first operation and the only revision",
                n + 1
            ),
            "memory" => main = vec![W::default(); num(w[1]) as usize],
            "root" => {
                let spec = w[1].replace('@', &tree_s);
                let r = mounts.add(&spec);
                writeln!(t, "root {} {}", w[1], if r.is_ok() { "ok" } else { "refused" }).unwrap();
                dev.mounts = mounts.clone();
            }
            "describe" => {
                for l in dev.mounts.describe() {
                    writeln!(t, "mount {}", l.replace(&tree_s, "@")).unwrap();
                }
            }
            "rings" => {
                (cb, cl, rb, rl) = (num(w[1]) as u32, num(w[2]) as u32, num(w[3]) as u32, num(w[4]) as u32);
                dev.write(CMD_BASE, cb, (now, NS), now, &main);
                dev.write(CMD_SIZE, cl, (now, NS), now, &main);
                dev.write(RESP_BASE, rb, (now, NS), now, &main);
                dev.write(RESP_SIZE, rl, (now, NS), now, &main);
                // The script's own copies, as the device took them.
                (cb, rb) = (cb & address, rb & address);
            }
            "enable" => {
                dev.write(CONTROL, 1 | (num(w[1]) as u32) << 8, (now, NS), now, &main);
                (prod, rcons, seen) = (0, 0, 0);
            }
            "disable" => {
                dev.write(CONTROL, 0, (now, NS), now, &main);
                (prod, rcons, seen) = (0, 0, 0);
            }
            "reset" => {
                dev.reset();
                (prod, rcons, seen) = (0, 0, 0);
            }
            "fill" => {
                let (a, k, v) = (num(w[1]) as usize, num(w[2]) as usize, num(w[3]));
                main[a..a + k].fill(W::from_script(v));
            }
            "bytes" => {
                let a = num(w[1]) as usize;
                let tag = w.get(3).map_or(0, |t| num(t) as u8);
                for (k, c) in hex_bytes(w[2]).chunks(4).enumerate() {
                    let mut b = [0u8; 4];
                    b[..c.len()].copy_from_slice(c);
                    main[a + k] = W::tagged(u32::from_le_bytes(b), tag);
                }
            }
            "cmd" => {
                let slot = cb as usize + 8 * (prod as usize % (1usize << cl));
                for k in 0..8 {
                    main[slot + k] = W::from_script(num(w[1 + k]));
                }
                prod = prod.wrapping_add(1);
            }
            "post" => dev.write(CMD_PROD, prod as u32, (now, NS), now, &main),
            "consume" => {
                rcons = rcons.wrapping_add(num(w[1]) as u16);
                dev.write(RESP_CONS, rcons as u32, (now, NS), now, &main);
            }
            "nowat" => nowat.push(num(w[1]) as u16),
            "run" => {
                now += 1 << 50;
                dev.advance(now, &mut main, NS);
                let upto = dev.response_producer();
                let clock = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
                let digits = W::DIGITS;
                while seen != upto {
                    let r = rb as usize + 8 * (seen as usize % (1usize << rl));
                    write!(t, "resp {seen}").unwrap();
                    for k in 0..8 {
                        let v = main[r + k];
                        if k == 4 && nowat.contains(&seen) && (v.low() as u64).abs_diff(clock) <= 10 {
                            write!(t, " NOW").unwrap();
                            // The host's clock is not the device's to agree
                            // on, so it leaves the memory's digest too.
                            main[r + k] = W::default();
                        } else {
                            write!(t, " {:0digits$x}", v.wide()).unwrap();
                        }
                    }
                    writeln!(t).unwrap();
                    let c = cb as usize + 8 * (seen as usize % (1usize << cl));
                    let (at, len) =
                        ((main[c + 4].low() & address) as usize, main[c + 5].low() as usize);
                    if at & line == 0 && len <= 65_536 && at + len.div_ceil(4) <= main.len() {
                        write!(t, "b {seen}").unwrap();
                        for v in &main[at..at + len.div_ceil(4)] {
                            write!(t, " {:0digits$x}", v.wide()).unwrap();
                        }
                        writeln!(t).unwrap();
                    }
                    seen = seen.wrapping_add(1);
                }
                let log = dev.log.as_ref().unwrap();
                for l in &log[logged..] {
                    writeln!(t, "{}", log_line(l)).unwrap();
                }
                logged = log.len();
                writeln!(t, "state handles {} queued {}", dev.handles_open(), dev.queued()).unwrap();
                writeln!(t, "refusal {}", dev.checkpoint_refusal().unwrap_or_else(|| "none".into()))
                    .unwrap();
                writeln!(t, "mem {:016x}", fnv(&main)).unwrap();
                settle_dirs(tree);
            }
            "hostwrite" => fs::write(host(w[1]), hex_bytes(w[2])).expect("hostwrite"),
            "hostrm" => fs::remove_file(host(w[1])).expect("hostrm"),
            "utime" => {
                let f = fs::File::open(host(w[1])).expect("utime");
                f.set_modified(UNIX_EPOCH + Duration::from_secs(num(w[2]))).expect("utime");
            }
            "chmod" => {
                use std::os::unix::fs::PermissionsExt;
                let mode = u32::from_str_radix(w[2], 8).expect("an octal mode");
                fs::set_permissions(host(w[1]), fs::Permissions::from_mode(mode)).expect("chmod");
            }
            op => panic!("{script}:{}: unknown operation {op}", n + 1),
        }
    }
    // The run is over: what muir leaves behind when it exits.
    drop(dev);
    settle_dirs(tree);
    t
}
