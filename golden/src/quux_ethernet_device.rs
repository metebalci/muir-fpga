// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! QUUX's Ethernet device (the Ethernet contract, §2; revision 16) as
//! muir's own `ethernet_device::EthernetDevice` answers a script of ring
//! operations and Ethernet frames. The same script is run through
//! `quux-ethernet-device`'s own step, face and §2.4 rules by that package's
//! `qed_test`, over a model of the fabric's page, and the two transcripts
//! must agree byte for byte.
//!
//! One operation a line, numbers decimal or `0x` hexadecimal, a register
//! octal:
//!
//! ```text
//! memory WORDS          main memory's size, zeroed, 40-bit words
//! host MAC A.B.C.D/N G  253-257: --ethernet-mac, --ip-address, --ip-gateway
//! rings TB TL RB RL     242, 243, 246 and 247
//! enable IE             240 = 1 | IE << 8
//! disable               240 = 0
//! reset                 RESET-DEVICES
//! write REG VALUE       a register written, REG in octal
//! word ADDR VALUE       a word of main memory, its tag in <39:32>
//! fill ADDR N VALUE     N words of main memory from ADDR
//! bytes ADDR HEX [TAG]  bytes into memory from word ADDR, the last word padded
//!                       with 0, each word tagged TAG (0 if none)
//! arrive HEX            an Ethernet frame arrives from the host side
//! run                   what the device did since the last `run`
//! ```
//!
//! Each operation is 10 ms after the one before, and the device is advanced
//! to its time before it, as an engine advances it before every register
//! access: so every transmit posted, at 20 µs an entry and at most 256 of
//! them, is sent before the next operation, and every Ethernet frame that
//! arrived is delivered or dropped before it.
//!
//! After each `run` the transcript has, in order: every line
//! `--ethernet-trace` printed since the last, without its time, as `trace`;
//! every Ethernet frame sent, as `sent` and its hex; registers 240 to 257,
//! as `regs` and sixteen words in hex on one line; and a 64-bit FNV-1a of
//! the whole of main memory, packed storage's 5 bytes a word, so that a word
//! written anywhere is seen.
//!
//! `--flags FILE` instead runs each line of FILE through muir's own parsers
//! of `--ethernet-mac`, `--ip-address` and `--ip-gateway`, and the gateway's
//! check, and prints muir's answer, so that the program's flags refuse what
//! muir's refuse in muir's words:
//!
//! ```text
//! mac ARG               --ethernet-mac ARG
//! address ARG           --ip-address ARG
//! gateway ARG           --ip-gateway ARG
//! pair A G              both given, then the check; `-` for one not given
//! ```

use std::fmt::Write as _;
use std::fs;
use std::sync::{Arc, Mutex};

use muir::clock::TimeBase;
use muir::ethernet_device::{
    CONTROL, EthernetDevice, GATEWAY, Host, RX_BASE, RX_SIZE, Script, TX_BASE, TX_SIZE,
};
use muir::ethernet_socket::{
    check_gateway, ipv4_text, mac_text, parse_ip_address, parse_ip_gateway, parse_mac,
    prefix_length,
};
use muir::machine::MemoryWord;

/// Revision 16's time base: units of 0.5 ns, at muir's default period.
const TIME: TimeBase = TimeBase::half_ns(muir::clock::PERIOD_15);

/// The time from one operation to the next, in units: 10 ms.
const STEP: u64 = 20_000_000;

fn num(s: &str) -> u64 {
    match s.strip_prefix("0x") {
        Some(h) => u64::from_str_radix(h, 16),
        None => s.parse(),
    }
    .unwrap_or_else(|_| panic!("not a number: {s}"))
}

fn oct(s: &str) -> u32 {
    u32::from_str_radix(s, 8).unwrap_or_else(|_| panic!("not an octal register: {s}"))
}

fn hex_bytes(s: &str) -> Vec<u8> {
    assert!(s.len().is_multiple_of(2), "odd hex: {s}");
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn fnv(words: &[u64]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for w in words {
        for b in &(w & 0xff_ffff_ffff).to_le_bytes()[..5] {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100_0000_01b3);
        }
    }
    h
}

/// `ethernet {time}: ` taken off a trace line.
fn untimed(line: &str) -> String {
    let rest = line.strip_prefix("ethernet ").expect("a trace line begins `ethernet `");
    let (_, text) = rest.split_once(": ").expect("a trace line has its time");
    text.to_string()
}

fn flags(path: &str) -> String {
    let text = fs::read_to_string(path).expect("the flags file");
    let mut t = String::new();
    let d = Host::default();
    for line in text.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (what, arg) = line.split_once(' ').unwrap_or((line, ""));
        let answer = match what {
            "mac" => parse_mac(arg).map(mac_text),
            "address" => parse_ip_address(arg)
                .map(|(a, m)| format!("{}/{}", ipv4_text(a), prefix_length(m))),
            "gateway" => parse_ip_gateway(arg).map(ipv4_text),
            "pair" => {
                let (a, g) = arg.split_once(' ').expect("pair A G");
                let address = if a == "-" { Ok((d.address, d.netmask)) } else { parse_ip_address(a) };
                let gateway = if g == "-" { Ok(d.gateway) } else { parse_ip_gateway(g) };
                match (address, gateway) {
                    (Err(e), _) | (_, Err(e)) => Err(e),
                    (Ok((a, m)), Ok(g_)) => check_gateway(a, m, g_, g == "-").map(|()| {
                        format!("{}/{} {}", ipv4_text(a), prefix_length(m), ipv4_text(g_))
                    }),
                }
            }
            w => panic!("{path}: {w} is not a question"),
        };
        match answer {
            Ok(v) => writeln!(t, "{line} => ok {v}").unwrap(),
            Err(e) => writeln!(t, "{line} => refused {e}").unwrap(),
        }
    }
    t
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (mut script, mut out, mut flag_file) = (None, None, None);
    let mut i = 1;
    while i < args.len() {
        let v = args.get(i + 1).cloned();
        match args[i].as_str() {
            "--script" => script = v,
            "--out" => out = v,
            "--flags" => flag_file = v,
            a => panic!("unknown argument {a}"),
        }
        i += 2;
    }
    let out = out.expect("--out");
    let t = match (script, flag_file) {
        (Some(s), None) => run(&s, &fs::read_to_string(&s).expect("the script")),
        (None, Some(f)) => flags(&f),
        _ => panic!("--script S or --flags F, and --out O"),
    };
    fs::write(&out, t).expect("the transcript");
}

fn run(script: &str, text: &str) -> String {
    let mut t = String::new();
    let mut dev = EthernetDevice::new();
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let keep = lines.clone();
    dev.trace = Some(Arc::new(move |l: &str| keep.lock().unwrap().push(untimed(l))));
    let peer = Script::default();
    dev.attach(Box::new(peer.clone()));
    let mut main: Vec<u64> = Vec::new();
    let mut now: u64 = 0;
    let mut sent_before = 0usize;

    for (n, line_text) in text.lines().enumerate() {
        let w: Vec<&str> = line_text.split_whitespace().collect();
        if w.is_empty() || w[0].starts_with('#') {
            continue;
        }
        now += STEP;
        dev.advance(now, &mut main, TIME);
        let at = |k: usize| -> &str {
            w.get(k).unwrap_or_else(|| panic!("{script}:{}: {} wants more", n + 1, w[0]))
        };
        match w[0] {
            "memory" => main = vec![0u64; num(at(1)) as usize],
            "host" => {
                let mac = parse_mac(at(1)).expect("a script's MAC address");
                let (address, netmask) = parse_ip_address(at(2)).expect("a script's address");
                let gateway = parse_ip_gateway(at(3)).expect("a script's gateway");
                dev.host = Host { mac, address, netmask, gateway };
            }
            "rings" => {
                for (k, reg) in [TX_BASE, TX_SIZE, RX_BASE, RX_SIZE].into_iter().enumerate() {
                    dev.write(reg, num(at(1 + k)) as u32, now, TIME, &main);
                }
            }
            "enable" => dev.write(CONTROL, 1 | (num(at(1)) as u32) << 8, now, TIME, &main),
            "disable" => dev.write(CONTROL, 0, now, TIME, &main),
            "reset" => dev.reset(),
            "write" => dev.write(oct(at(1)), num(at(2)) as u32, now, TIME, &main),
            "word" => main[num(at(1)) as usize] = num(at(2)) & 0xff_ffff_ffff,
            "fill" => {
                let (a, k, v) = (num(at(1)) as usize, num(at(2)) as usize, num(at(3)));
                main[a..a + k].fill(v & 0xff_ffff_ffff);
            }
            "bytes" => {
                let a = num(at(1)) as usize;
                let tag = w.get(3).map_or(0, |x| num(x) as u8);
                for (k, c) in hex_bytes(at(2)).chunks(4).enumerate() {
                    let mut b = [0u8; 4];
                    b[..c.len()].copy_from_slice(c);
                    main[a + k] = u64::tagged(u32::from_le_bytes(b), tag);
                }
            }
            "arrive" => {
                let f = if at(1) == "-" { Vec::new() } else { hex_bytes(at(1)) };
                peer.arrive(now, f);
            }
            "run" => {
                for l in lines.lock().unwrap().drain(..) {
                    writeln!(t, "trace {l}").unwrap();
                }
                let sent = peer.sent();
                for (_, f) in &sent[sent_before..] {
                    writeln!(t, "sent {}", hex(f)).unwrap();
                }
                sent_before = sent.len();
                let regs: Vec<String> =
                    (CONTROL..=GATEWAY).map(|r| format!("{:08x}", dev.read(r))).collect();
                writeln!(t, "regs {}", regs.join(" ")).unwrap();
                writeln!(t, "memory {:016x}", fnv(&main)).unwrap();
            }
            op => panic!("{script}:{}: {op} is not an operation", n + 1),
        }
    }
    t
}
