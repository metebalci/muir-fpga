// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The channel walking a command list of more than one CCW, over a **real
//! System 100 pack**, with the blocks fetched on demand.
//!
//! **Why this exists, and it is not a second `disk.rs`.** `golden/src/disk.rs`
//! is a timed trace on the 5 ns grid against a *blank* pack the program
//! formats itself, with every block the walk will need already in the
//! fabric's store before the START that needs it --- "a Linux of no
//! latency", which is what keeps every row on its instant. `tb/cadr_disk
//! _pack_tb.cpp` is the other half: the store filled on demand, but every
//! command list in it is ONE CCW long bar a single chained pair whose first
//! block is already resident. So the two checks between them had never run
//! **a list of more than one CCW whose blocks the store has to ask Linux
//! for**, which is the whole of what a cold boot does, and no check in this
//! repository had ever moved a block of a real pack into main memory and
//! compared it.
//!
//! On 2026-09-10 the board booted, loaded its microcode from the pack, ran,
//! and halted itself at microcode PC `0o5163` on `ILLOP-IF-PAGE-FAULT`. The
//! cause was in that hole: the cold boot's first `COLD-DISK-READ` is one
//! list of three CCWs into physical pages 0, 1 and 2, and only page 0
//! arrived. Every earlier transfer of the boot --- the PROM's microcode load
//! and the label reads --- is a list of one, which is why the machine got as
//! far as it did.
//!
//! **What the trace carries.** The same discipline as `disk.rs`:
//!
//! - `BLK`, a block as it lies on the pack: 256 data words, the header, its
//!   checkword and the data's, with the address in DDR the testbench is to
//!   put the record at. **Stimulus.** The address is the generator's, spread
//!   across the address bits, so a fetch that landed one record over reads
//!   something else.
//! - `MEMPAGE` and `MEMW`, main memory as the *program* sets it: the
//!   command lists, and the poison the destination pages carry before the
//!   transfer. Never as the controller leaves it.
//! - `XFER`, the four register stores that make one transfer.
//! - `PAGE` and `RES`, what muir's `Controller::transfer` left behind: every
//!   word of every page it moved, and the status, disk address and memory
//!   address afterwards. **Expected output.**
//! - `WB`, a block a Write put on the pack: the 259 words the fabric's own
//!   store must hold, written back to a fresh address. **Expected output.**
//!
//! **The first two transfers are the cold boot's own, taken from the boot
//! and not transcribed.** This generator runs muir's `rtl` engine on MIT's
//! boot PROM with the pack attached until the first command list of more
//! than one CCW, and takes the command, the disk address and the pages from
//! it --- then replays that transfer on a fresh `Controller` over a fresh
//! view of the same pack. The list's own CLP is asserted rather than
//! assumed: `START-DISK-N-PAGES` builds the list at `A-DISK-CLP`, which
//! `COLD-DISK-READ` sets to `COPY-BUFFER-CCW-ORIGIN`, `0o40000`, and the
//! three words found there are required to be the three CCWs the pages
//! imply.

use std::collections::BTreeMap;

use muir::disk_controller::Controller;
use muir::disk_unit::{BLOCK_WORDS, Geometry, Unit};
use muir::engine::Engine;
use muir::machine::Machine;
use muir::rtl::Rtl;

/// The drive: a T-300, which is what a System 100 band runs on.
const G: Geometry = Geometry::T300;

/// How many 64K-word memory boards, as `busint_xbus.rs` and
/// `Machine::with_memory_boards` have it.
const BOARDS: u32 = 32;
const MEMORY_WORDS: u32 = BOARDS * (1 << 16);

/// A block's record in DDR: the 259 words, and the alignment
/// `rtl/cadr_disk_pack.sv` refuses an address without.
const RECORD_BYTES: u32 = (BLOCK_WORDS as u32 + 3) * 4;
const RECORD_ALIGN: u32 = 128;

/// Where the k'th record goes. `0x9E37` is odd, so the low sixteen bits are
/// injective in `k` and no two records can land on one another; a page apart,
/// so a fetch that ran off the end of one lands on nothing that was put
/// there. The generator asserts both anyway.
fn record_at(k: u32) -> u32 {
    0x0100_0000 | ((k.wrapping_mul(0x9E37) & 0xFFFF) << 12)
}

/// The poison a destination page carries before a transfer: a function of
/// **both** the page and the offset in it, so neither a page that was never
/// written nor a word taken from the wrong offset reads back as the right
/// word. A page of zeros would read back after a transfer that never
/// happened exactly as it reads back after one that did --- the control
/// store's lesson, and this check is the one place it bites hardest,
/// because the board's own symptom was a page of zeros.
fn mem_word(page: u32, i: u32) -> u32 {
    page.wrapping_mul(0x27D4_EB2F) ^ i.wrapping_mul(0x1656_67B1) ^ 0xA5A5_5A5A
}

/// The block's address as `DCDA` holds it.
fn da_of(unit: u32, c: u32, h: u32, b: u32) -> u32 {
    (unit & 7) << 28 | (c & 0o7777) << 16 | (h & 0xff) << 8 | (b & 0xff)
}

fn split_da(da: u32) -> (u32, u32, u32) {
    ((da >> 16) & 0o7777, (da >> 8) & 0xff, da & 0xff)
}

/// "0 following block on same track, 1 block 0 on next track (next head), 2
/// block 0 on head 0 of next cylinder" --- `Unit::next_block`'s own rule,
/// walked here so that the trace can name the blocks a list will reach
/// before it reaches them.
fn next_block(c: u32, h: u32, b: u32) -> (u32, u32, u32) {
    let (mut c, mut h, mut b) = (c, h, b + 1);
    if b == G.blocks_per_track {
        b = 0;
        h += 1;
        if h == G.heads {
            h = 0;
            c += 1;
        }
    }
    (c, h, b)
}

fn fail(m: &str) -> ! {
    eprintln!("disk_boot: {m}");
    std::process::exit(2);
}

/// One transfer the trace runs.
struct Xfer {
    name: &'static str,
    cmd: u32,
    da: u32,
    /// The pages the command list names, in order. The last CCW carries no
    /// More flag; every other does.
    pages: Vec<u32>,
    /// Where the command list goes.
    clp: u32,
    /// Whether the pages are filled with poison before the transfer (a
    /// read's destination) or with the words a write is to put on the pack.
    fill: bool,
}

struct Gen {
    d: Controller,
    main: Vec<u32>,
    out: Vec<String>,
    placed: Vec<u32>,
    /// Every block whose record the trace has put in DDR, and where.
    known: BTreeMap<(u32, u32, u32), u32>,
    // coverage
    xfers: u64,
    ccws: u64,
    pages_moved: u64,
    blk_rows: u64,
    wb_rows: u64,
    longest_list: usize,
    track_crossings: u64,
    cylinder_crossings: u64,
    words_compared: u64,
}

impl Gen {
    fn new(pack: &str) -> Gen {
        let unit = Unit::open(pack, G).unwrap_or_else(|e| fail(&format!("{pack}: {e}")));
        let mut d = Controller::default();
        d.attach(0, unit);
        Gen {
            d,
            main: vec![0u32; MEMORY_WORDS as usize],
            out: Vec::new(),
            placed: Vec::new(),
            known: BTreeMap::new(),
            xfers: 0,
            ccws: 0,
            pages_moved: 0,
            blk_rows: 0,
            wb_rows: 0,
            longest_list: 0,
            track_crossings: 0,
            cylinder_crossings: 0,
            words_compared: 0,
        }
    }

    fn say(&mut self, s: String) {
        self.out.push(s);
    }

    /// A fresh record address, asserted apart from every other.
    fn fresh(&mut self) -> u32 {
        let at = record_at(self.placed.len() as u32);
        assert_eq!(at % RECORD_ALIGN, 0, "record {at:#x} is not aligned");
        for &other in &self.placed {
            assert!(
                other.abs_diff(at) >= RECORD_BYTES.next_multiple_of(RECORD_ALIGN),
                "records at {other:#x} and {at:#x} overlap"
            );
        }
        self.placed.push(at);
        at
    }

    /// The block as the pack has it, put in DDR for the fabric to fetch.
    /// Emitted again after anything changes it, at a new address, so that a
    /// read after a write is served from muir's pack and never from the
    /// fabric's own write-back.
    fn blk(&mut self, c: u32, h: u32, b: u32) {
        let at = self.fresh();
        let u = self.d.units[0].as_mut().expect("a drive on unit 0");
        let hdr = u.header_at(c, h, b).unwrap_or_else(|| fail("an address off the pack"));
        let dck = u.data_checkword_at(c, h, b).expect("an address on the pack");
        let data = u.block_at(c, h, b).expect("an address on the pack");
        let mut row = format!(
            "BLK {at:x} {c:x} {h:x} {b:x} {:x} {:x} {:x}",
            hdr.word,
            u32::from_le_bytes(hdr.checkword),
            u32::from_le_bytes(dck)
        );
        for w in &data {
            row.push_str(&format!(" {w:x}"));
        }
        self.blk_rows += 1;
        self.known.insert((c, h, b), at);
        self.say(row);
    }

    /// One word of main memory, set by the program.
    fn poke(&mut self, at: u32, v: u32) {
        self.main[at as usize] = v;
        self.say(format!("MEMW {at:x} {v:x}"));
    }

    /// A page of main memory as the program leaves it: poison for a read's
    /// destination, the same words for a write's source.
    fn fill(&mut self, page: u32) {
        let base = page as usize * BLOCK_WORDS;
        let mut row = format!("MEMPAGE {page:x}");
        for i in 0..BLOCK_WORDS {
            let w = mem_word(page, i as u32);
            self.main[base + i] = w;
            row.push_str(&format!(" {w:x}"));
        }
        self.say(row);
    }

    /// The command list: one CCW a page, the last without the More flag,
    /// counting only in `<15:0>` as `DCCLP` does.
    fn ccws(&mut self, clp: u32, pages: &[u32]) {
        for (k, &page) in pages.iter().enumerate() {
            let at = clp & !0xffff | (clp.wrapping_add(k as u32)) & 0xffff;
            let ccw = page << 8 | u32::from(k + 1 < pages.len());
            self.poke(at, ccw);
        }
    }

    /// Every block a list from `da` of `n` CCWs will reach, put on the pack.
    fn place_blocks(&mut self, da: u32, n: usize) {
        let (mut c, mut h, mut b) = split_da(da);
        for _ in 0..n {
            if !self.known.contains_key(&(c, h, b)) {
                self.blk(c, h, b);
            }
            let (c2, h2, b2) = next_block(c, h, b);
            if h2 != h {
                self.track_crossings += 1;
            }
            if c2 != c {
                self.cylinder_crossings += 1;
            }
            (c, h, b) = (c2, h2, b2);
        }
    }

    /// One transfer: the blocks put on the pack, the pages filled, the list
    /// written, the four register stores, and what muir left behind.
    fn xfer(&mut self, x: &Xfer) {
        self.place_blocks(x.da, x.pages.len());
        for &p in &x.pages {
            if x.fill {
                self.fill(p);
            }
        }
        self.ccws(x.clp, &x.pages);
        self.xfers += 1;
        self.ccws += x.pages.len() as u64;
        self.longest_list = self.longest_list.max(x.pages.len());
        self.say(format!(
            "XFER {} {} {:x} {:x} {:x} {}",
            self.xfers,
            x.name,
            x.cmd,
            x.clp,
            x.da,
            x.pages.len()
        ));
        self.d.write(0, x.cmd, &mut self.main);
        self.d.write(1, x.clp, &mut self.main);
        self.d.write(2, x.da, &mut self.main);
        self.d.dma_written.clear();
        self.d.write(3, 0, &mut self.main);
        let moved = self.d.dma_written.clone();
        for page in &moved {
            self.pages_moved += 1;
            let mut row = format!("PAGE {:x}", page >> 8);
            for w in &self.main[*page..*page + BLOCK_WORDS] {
                self.words_compared += 1;
                row.push_str(&format!(" {w:x}"));
            }
            self.say(row);
        }
        let s = self.d.status();
        self.say(format!(
            "RES {s:x} {:x} {:x} {}",
            self.d.read(2),
            self.d.read(1),
            moved.len()
        ));
    }

    /// A block a Write put on the pack: the 259 words the fabric's store
    /// must now hold, and a fresh address to write them back to.
    fn wb(&mut self, c: u32, h: u32, b: u32) {
        let at = self.fresh();
        let u = self.d.units[0].as_mut().expect("a drive on unit 0");
        let hdr = u.header_at(c, h, b).expect("an address on the pack");
        let dck = u.data_checkword_at(c, h, b).expect("an address on the pack");
        let data = u.block_at(c, h, b).expect("an address on the pack");
        let mut row = format!(
            "WB {at:x} {c:x} {h:x} {b:x} {:x} {:x} {:x}",
            hdr.word,
            u32::from_le_bytes(hdr.checkword),
            u32::from_le_bytes(dck)
        );
        for w in &data {
            row.push_str(&format!(" {w:x}"));
        }
        self.wb_rows += 1;
        self.say(row);
    }
}

/// The cold boot's own first command lists, taken from the boot.
///
/// muir's `rtl` engine on MIT's boot PROM with the pack attached, run until
/// `Controller::transfer` has moved more than one page in one START. What
/// comes back is the command, the disk address the list started at, the
/// pages it named, and the microcycle it happened at.
struct FromBoot {
    at: u64,
    da: u32,
    pages: Vec<u32>,
    /// The command list as the microcode built it, read out of main memory
    /// at `COPY-BUFFER-CCW-ORIGIN`.
    clp: u32,
    ccws: Vec<u32>,
}

fn from_boot(pack: &str, want: usize, limit: u64) -> Vec<FromBoot> {
    // `COLD-DISK-READ`'s own CLP: `uc-cold-disk.lisp` sets `M-C` to
    // `COPY-BUFFER-CCW-ORIGIN` before every call, and `START-DISK-N-PAGES`
    // builds the list at `A-DISK-CLP`.
    const COPY_BUFFER_CCW_ORIGIN: u32 = 0o40000;
    let unit = Unit::open(pack, G).unwrap_or_else(|e| fail(&format!("{pack}: {e}")));
    let mut m = Machine::with_memory_boards(BOARDS as usize);
    m.load_prom(&muir::prom::boot_prom());
    m.disk.attach(0, unit);
    let mut e = Rtl::new(m);
    e.boot();
    let mut found = Vec::new();
    let mut last: Vec<usize> = Vec::new();
    for n in 0..limit {
        let da = e.machine().disk.read(2);
        let ccws: Vec<u32> = (0..16)
            .map(|k| e.machine().main[COPY_BUFFER_CCW_ORIGIN as usize + k])
            .collect();
        if e.step().is_err() {
            fail("the boot stopped before it read three pages in one list");
        }
        let now = e.machine().disk.dma_written.clone();
        if now.len() > 1 && now != last {
            let pages: Vec<u32> = now.iter().map(|p| (*p >> 8) as u32).collect();
            // The CLP is asserted, not assumed: the words at
            // `COPY-BUFFER-CCW-ORIGIN` before the store into START must be
            // exactly the CCWs these pages imply.
            for (k, &page) in pages.iter().enumerate() {
                let want = page << 8 | u32::from(k + 1 < pages.len());
                assert_eq!(
                    ccws[k], want,
                    "the boot's transfer at microcycle {n} moved page {page:#x} as CCW {k}, \
                     but 0o40000+{k} holds {:#x} and not {want:#x} --- the command list is \
                     not where COLD-DISK-READ puts it",
                    ccws[k]
                );
            }
            found.push(FromBoot {
                at: n,
                da,
                pages,
                clp: COPY_BUFFER_CCW_ORIGIN,
                ccws: ccws[..now.len()].to_vec(),
            });
            if found.len() == want {
                return found;
            }
        }
        last = now;
    }
    fail("the boot never walked a command list of more than one CCW")
}

fn main() {
    let mut pack: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--pack" => pack = args.next(),
            _ => fail(&format!("unknown argument {a}\nusage: disk_boot --pack <image>")),
        }
    }
    let Some(pack) = pack else {
        fail("--pack <image> is required: a copy of the release pack, not the vendored one")
    };

    let boot = from_boot(&pack, 2, 4_000_000);
    let mut g = Gen::new(&pack);

    // ------------------------------------------------------------------
    // The cold boot's own first two multi-CCW transfers, replayed.
    // ------------------------------------------------------------------
    // `DISK-READ-COMMAND` with the interrupt enable the microcode sets is
    // not what is replayed here: the command's low four bits are what the
    // sequencer runs, and the trace holds the transfer and not the
    // interrupt.  `<11>` is asserted to be what the boot had.
    for (k, b) in boot.iter().enumerate() {
        let name = if k == 0 { "cold-boot-first-list" } else { "cold-boot-second-list" };
        g.say(format!(
            "# from the boot: microcycle {} da {:x} pages {:?} clp {:o} ccws {:x?}",
            b.at, b.da, b.pages, b.clp, b.ccws
        ));
        let x = Xfer {
            name,
            cmd: 0o00,
            da: b.da,
            pages: b.pages.clone(),
            clp: b.clp,
            fill: true,
        };
        g.xfer(&x);
    }

    // ------------------------------------------------------------------
    // A list of one: what every transfer of the boot before the one above
    // is, and what the board did get right.  The control.
    // ------------------------------------------------------------------
    g.xfer(&Xfer {
        name: "one-ccw",
        cmd: 0o00,
        da: da_of(0, 400, 3, 5),
        pages: vec![0x80],
        clp: 0o4000,
        fill: true,
    });

    // ------------------------------------------------------------------
    // A list that walks off the end of a track, and one that walks off the
    // end of a cylinder: `next_block`'s two carries, which a list of one can
    // never reach.
    // ------------------------------------------------------------------
    g.xfer(&Xfer {
        name: "across-a-track",
        cmd: 0o00,
        da: da_of(0, 401, 3, G.blocks_per_track - 2),
        pages: vec![0x90, 0x91, 0x92, 0x93],
        clp: 0o4000,
        fill: true,
    });
    g.xfer(&Xfer {
        name: "across-a-cylinder",
        cmd: 0o00,
        da: da_of(0, 402, G.heads - 1, G.blocks_per_track - 2),
        pages: vec![0xA0, 0xA1, 0xA2, 0xA3],
        clp: 0o4000,
        fill: true,
    });

    // ------------------------------------------------------------------
    // A long list: sixteen CCWs, more than the store has slots for a
    // prefetch to hide behind, and enough that a channel stopping after any
    // fixed number of pages is caught by the count and not only by the
    // content.
    // ------------------------------------------------------------------
    {
        let pages: Vec<u32> = (0..16).map(|k| 0xB0 + k).collect();
        g.xfer(&Xfer {
            name: "sixteen-ccws",
            cmd: 0o00,
            da: da_of(0, 500, 0, 0),
            pages,
            clp: 0o4000,
            fill: true,
        });
    }

    // ------------------------------------------------------------------
    // The command list walked out of the low sixteen bits: "Only bits
    // <15:0> of the CLP can count; if you attempt to carry into the high 8
    // bits you will wrap around."  Three CCWs from `0x2FFFE`.
    // ------------------------------------------------------------------
    g.xfer(&Xfer {
        name: "the-list-wraps",
        cmd: 0o00,
        da: da_of(0, 501, 1, 1),
        pages: vec![0xC0, 0xC1, 0xC2],
        clp: 0x2_FFFE,
        fill: true,
    });

    // ------------------------------------------------------------------
    // A read-compare over the pages the first list filled: no difference,
    // and then one word changed, which "does not stop the transfer".
    // ------------------------------------------------------------------
    {
        let first = &boot[0];
        g.say("# read-compare against the pages the cold boot's first list left".to_string());
        g.xfer(&Xfer {
            name: "read-compare-agrees",
            cmd: 0o10,
            da: first.da,
            pages: first.pages.clone(),
            clp: 0o4000,
            fill: false,
        });
        let p = first.pages[first.pages.len() - 1];
        let at = p * BLOCK_WORDS as u32 + 100;
        let was = g.main[at as usize];
        g.poke(at, !was);
        g.xfer(&Xfer {
            name: "read-compare-differs",
            cmd: 0o10,
            da: first.da,
            pages: first.pages.clone(),
            clp: 0o4000,
            fill: false,
        });
        g.poke(at, was);
    }

    // ------------------------------------------------------------------
    // A Write of three pages onto the pack and the read back into three
    // others.  The write's own blocks are `WB` rows --- the 259 words the
    // fabric's store must hold, written back --- and the read is served
    // from `BLK` rows taken from muir's pack afterwards, never from the
    // fabric's write-back, so the two halves cannot agree on a shared
    // mistake.
    // ------------------------------------------------------------------
    {
        let da = da_of(0, 600, 2, 3);
        let src = vec![0xD0u32, 0xD1, 0xD2];
        let dst = vec![0xE0u32, 0xE1, 0xE2];
        g.xfer(&Xfer { name: "write-three", cmd: 0o11, da, pages: src, clp: 0o4000, fill: true });
        let (mut c, mut h, mut b) = split_da(da);
        for _ in 0..3 {
            g.wb(c, h, b);
            (c, h, b) = next_block(c, h, b);
        }
        // The pack has changed, so the records the testbench serves must
        // change with it: fresh `BLK` rows, at fresh addresses.
        let (mut c, mut h, mut b) = split_da(da);
        for _ in 0..3 {
            g.blk(c, h, b);
            (c, h, b) = next_block(c, h, b);
        }
        g.xfer(&Xfer { name: "read-three-back", cmd: 0o00, da, pages: dst, clp: 0o4000, fill: true });
    }

    // ------------------------------------------------------------------
    let mut head = Vec::new();
    head.push("# the disk controller's channel over a real System 100 pack:".to_string());
    head.push("# muir's disk_controller::Controller::transfer walking command lists".to_string());
    head.push("# of more than one CCW --- generated by golden/src/disk_boot.rs".to_string());
    head.push("#".to_string());
    head.push("# every value hexadecimal except the row number and the counts".to_string());
    head.push("#".to_string());
    head.push("# BLK      at cyl head blk header hck dck w0..w255".to_string());
    head.push("#          STIMULUS: the pack holds this block; the testbench puts the".to_string());
    head.push("#          259 words at `at` in DDR for the fabric to fetch".to_string());
    head.push("# MEMPAGE  page w0..w255           main memory, as the program fills it".to_string());
    head.push("# MEMW     addr word               one word of it".to_string());
    head.push("# XFER     n name cmd clp da nccw  the four register stores of one transfer".to_string());
    head.push("# PAGE     page w0..w255           EXPECTED: a page the transfer moved".to_string());
    head.push("# RES      status da lma npages    EXPECTED: the face after it".to_string());
    head.push("# WB       at cyl head blk header hck dck w0..w255".to_string());
    head.push("#          EXPECTED: a block a Write put on the pack, written back to `at`".to_string());
    head.push("#".to_string());
    head.push(format!("# geometry {} {} {}", G.cylinders, G.heads, G.blocks_per_track));
    head.push(format!("# memory_words {MEMORY_WORDS}"));
    head.push(format!("# block_words {BLOCK_WORDS}"));
    head.push(format!("# record_bytes {RECORD_BYTES}"));
    head.push(format!("# record_align {RECORD_ALIGN}"));
    head.push("#".to_string());
    head.push("# coverage".to_string());
    head.push(format!(
        "# transfers {} ccws {} longest_list {} pages_moved {} words_compared {}",
        g.xfers, g.ccws, g.longest_list, g.pages_moved, g.words_compared
    ));
    head.push(format!(
        "# blocks placed {} written_back {} track_crossings {} cylinder_crossings {}",
        g.blk_rows, g.wb_rows, g.track_crossings, g.cylinder_crossings
    ));
    for b in &boot {
        head.push(format!(
            "# the cold boot's list at microcycle {}: {} pages from disk address {:x}",
            b.at,
            b.pages.len(),
            b.da
        ));
    }
    assert!(g.longest_list >= 16, "the longest list is {}", g.longest_list);
    assert!(g.track_crossings >= 1 && g.cylinder_crossings >= 1, "a carry was never reached");

    for l in &head {
        println!("{l}");
    }
    for l in &g.out {
        println!("{l}");
    }
    for l in &head {
        eprintln!("{l}");
    }
}
