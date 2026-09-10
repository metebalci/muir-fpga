// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the disk controller with a drive and a pack:
//! `disk_controller::Controller` driven register by register, in the shape
//! `busint_xbus.rs` drives `busint::Busint`.
//!
//! **Why a scripted program and not the band.** `docs/disk-controller.md`
//! measured what the two reference programs ask of the controller: MIT's
//! boot PROM writes no command at all, and a System 100 band reaches six
//! of sixteen command codes and sets no error bit, ever. So a check driven
//! by either tests the happy path and nothing else --- the same shape as
//! the control store whose only exercise wrote zero to all 16,384 words.
//! This program is the primary reference and the band is the second one.
//!
//! **What the trace carries.** Everything the fabric needs and nothing it
//! could get from the DUT:
//!
//! - `BLK`, a block as it lies on the pack: 256 data words, the header
//!   word, its checkword and the data's. That is the drive's side of the
//!   seam --- the 259 words `S_AXI_HP2` will one day fetch --- and it is
//!   emitted at load and again whenever a transfer changes it, so the
//!   testbench's store and muir's pack cannot drift apart.
//! - `MEMPAGE` and `MEMW`, main memory as the *program* sets it, never as
//!   the controller leaves it. CLAUDE.md's rule twice over: a shadow
//!   filled from the DUT moves with the bug.
//! - `CYC`, one bus cycle on one of the four registers, with the whole
//!   observable face of the controller sampled after it.
//! - `PAGE`, a page the transfer put into main memory, with its content.
//!
//! **The content rule.** Every block's data is a function of *both* the
//! block number and the offset within it, and so is every page of memory
//! the program fills. A pack of zeros, or of one constant, reads back
//! after a transfer that never happened exactly as it reads back after one
//! that did. Read destinations are filled with the memory function before
//! the read, so a page nothing wrote holds poison rather than zeros.
//!
//! **What is left out, and why.**
//!
//! - `STATUS<23>` internal parity, `<19>` memory parity, `<12>` start
//!   block and `<4>` multiple units: `Controller` never sets them, so
//!   nothing here can reach them. `<21>` CCW cycle is set and cleared
//!   inside one store to START, so no read can see it.
//! - All but one hang is ended with a Reset rather than run out to
//!   `TIMEOUT_NS`. 2.56 s is 512,000,000 ticks of the fabric's 200 MHz
//!   clock; one of those is affordable and eight are not.
//!   `docs/disk-controller.md` reached the same figure before any of this
//!   was written.
//! - The three undocumented codes `0o01`, `0o03` and `0o12` are run for
//!   their *status* only. muir models no data for them --- the words the
//!   board's channel moves are its fifo's own contents cycling --- and
//!   `disk_controller.rs` says at length why inventing them would be
//!   worse than leaving them.
//! - `Ecc::trap`'s burst location is here, because the model has it; the
//!   note in `docs/disk-controller.md` that it is not going into fabric is
//!   about the fabric and not about the reference.

use std::collections::BTreeMap;

use muir::disk_controller::{Controller, TIMEOUT_NS};
use muir::disk_unit::{
    self, BLOCK_WORDS, Ecc, Geometry, Header, INDEX_PULSE_NS, REVOLUTION_NS, SECTOR_NS, Unit,
    format, seek_ns,
};

/// The drive: a T-300, which is what a System 100 band runs on.
const G: Geometry = Geometry::T300;

/// How many 64K-word memory boards the machine has, as `busint_xbus.rs`
/// has it. The controller is a bus master and reaches physical memory
/// directly, so what is off the end of this is what `STATUS<20>`, NXM, is
/// made of.
const BOARDS: u32 = 32;
const MEMORY_WORDS: u32 = BOARDS * (1 << 16);

/// Where the command list lives for most of the program: out of the pages
/// being transferred, and a physical address, as the boot PROM's `0o777`
/// is.
const CLP: u32 = 0o4000;

/// A second command list, placed so that walking it carries out of the low
/// sixteen bits: "Only bits `<15:0>` of the CLP can count; if you attempt
/// to carry into the high 8 bits you will wrap around."
const CLP_WRAP: u32 = 0x2_FFFE;

/// Five nanoseconds, the master clock's period. Every instant the trace
/// samples at is a multiple of this, because the fabric can only look at
/// its own clock edges.
const TICK_NS: u64 = 5;

/// A word of a block, as a function of **both** the block and the offset
/// within it. Neither a wrong block nor a wrong offset reads back as the
/// right word.
fn pack_word(lba: u32, i: u32) -> u32 {
    lba.wrapping_mul(0x9E37_79B1) ^ i.wrapping_mul(0x85EB_CA6B) ^ (lba ^ i).wrapping_mul(0xC2B2_AE35)
}

/// A word of a page of main memory, likewise a function of both. Used to
/// fill the pages a write reads from *and* the pages a read writes to: a
/// destination that nothing wrote holds this rather than zeros, so a
/// transfer that did not happen cannot read back like one that did.
fn mem_word(page: u32, i: u32) -> u32 {
    page.wrapping_mul(0x27D4_EB2F) ^ i.wrapping_mul(0x1656_67B1) ^ 0xA5A5_5A5A
}

/// The block's address, as `DCDA` holds it: `<27:16>` cylinder, `<15:8>`
/// head, `<7:0>` block, with the unit in `<30:28>`.
fn da_of(unit: u32, c: u32, h: u32, b: u32) -> u32 {
    (unit & 7) << 28 | (c & 0o7777) << 16 | (h & 0xff) << 8 | (b & 0xff)
}

fn lba_of(c: u32, h: u32, b: u32) -> u32 {
    c * G.blocks_per_cylinder() + h * G.blocks_per_track + b
}

/// The smallest multiple of [`TICK_NS`] at or after `t`, and the largest
/// strictly before it: where the fabric can look on either side of an
/// instant muir puts between two of its clock edges.
fn grid_at(t: u64) -> u64 {
    t.div_ceil(TICK_NS) * TICK_NS
}
fn grid_before(t: u64) -> u64 {
    (t - 1) / TICK_NS * TICK_NS
}

/// A block as it lies on the pack: what the fabric's block store holds,
/// and what `S_AXI_HP2` will one day fetch into it.
#[derive(Clone, PartialEq, Eq)]
struct Image {
    header: u32,
    header_checkword: u32,
    data_checkword: u32,
    data: [u32; BLOCK_WORDS],
}

struct Gen {
    d: Controller,
    main: Vec<u32>,
    now: u64,
    /// The blocks the fabric's store holds, in slot order.
    watch: Vec<(u32, u32, u32)>,
    shadow: BTreeMap<u32, Image>,
    out: Vec<String>,
    line: u64,
    // --- coverage, counted as the program runs -----------------------
    cmds: BTreeMap<u32, u64>,
    reads: [u64; 4],
    writes: [u64; 4],
    status_seen: u32,
    /// Blocks a transfer put on the pack, counted from the store rather
    /// than by hand: a `BLK` row emitted by a store into START.
    blocks_to_pack: u64,
    pages_moved: u64,
    blk_rows: u64,
    starts: u64,
    counters_seen: std::collections::BTreeSet<u32>,
    hangs: u64,
    full_timeouts: u64,
}

impl Gen {
    fn new() -> Gen {
        Gen {
            d: Controller::default(),
            main: vec![0u32; MEMORY_WORDS as usize],
            now: 0,
            watch: Vec::new(),
            shadow: BTreeMap::new(),
            out: Vec::new(),
            line: 0,
            cmds: BTreeMap::new(),
            reads: [0; 4],
            writes: [0; 4],
            status_seen: 0,
            blocks_to_pack: 0,
            pages_moved: 0,
            blk_rows: 0,
            starts: 0,
            counters_seen: std::collections::BTreeSet::new(),
            hangs: 0,
            full_timeouts: 0,
        }
    }

    fn say(&mut self, s: String) {
        self.out.push(s);
    }

    /// Time passes. Monotonic, and always on the fabric's grid.
    fn at(&mut self, now: u64) {
        assert!(now >= self.now, "time runs backwards: {} to {now}", self.now);
        assert!(now % TICK_NS == 0, "{now} is not on the 5 ns grid");
        self.now = now;
    }

    /// Time passes by `ns`, rounded up to the grid.
    fn wait(&mut self, ns: u64) {
        let t = grid_at(self.now + ns);
        self.at(t);
    }

    /// The whole observable face of the controller, sampled after an event.
    fn face(&mut self) -> (u32, u32, u32, u32, u8) {
        self.d.advance(self.now);
        let s = self.d.status();
        self.status_seen |= s;
        self.counters_seen.insert(s >> 24);
        (s, self.d.read(2), self.d.read(1), self.d.read(3), u8::from(self.d.interrupt()))
    }

    fn cyc(&mut self, reg: u32, write: bool, wdata: u32, rdata: u32, pages: usize) {
        let (s, da, lma, ecc, intr) = self.face();
        let n = self.line;
        self.line += 1;
        self.say(format!(
            "CYC {n} {} {reg} {} {wdata:x} {rdata:x} {s:x} {da:x} {lma:x} {ecc:x} {intr} {pages}",
            self.now,
            u8::from(write)
        ));
    }

    /// One read cycle on one of the four registers.
    fn read(&mut self, reg: u32) -> u32 {
        self.d.advance(self.now);
        let v = self.d.read(reg);
        self.reads[(reg & 3) as usize] += 1;
        self.cyc(reg, false, 0, v, 0);
        assert_eq!(self.emit_blocks("read"), 0, "a read changed the pack");
        v
    }

    /// One write cycle. A store into register 3 is a START, and the pages
    /// the transfer put into memory follow the row.
    fn write(&mut self, reg: u32, v: u32) {
        self.d.advance(self.now);
        if reg & 3 == 0 {
            *self.cmds.entry(v & 0o17).or_default() += 1;
        }
        self.d.write(reg, v, &mut self.main);
        self.writes[(reg & 3) as usize] += 1;
        let pages: Vec<usize> = if reg & 3 == 3 {
            self.starts += 1;
            let p = self.d.dma_written.clone();
            self.d.dma_written.clear();
            p
        } else {
            Vec::new()
        };
        self.cyc(reg, true, v, 0, pages.len());
        for page in pages {
            self.pages_moved += 1;
            let mut row = format!("PAGE {page:x}");
            for w in &self.main[page..page + BLOCK_WORDS] {
                row.push_str(&format!(" {w:x}"));
            }
            self.say(row);
        }
        // Only a store into START can reach the pack: the other three are
        // register stores, and a `BLK` row after one of them would mean the
        // model had moved something no bus cycle asked it to.
        let laid = self.emit_blocks("write");
        if reg & 3 == 3 {
            self.blocks_to_pack += laid;
        } else {
            assert_eq!(laid, 0, "a store into register {reg} changed the pack");
        }
    }

    /// The command list at `clp`: one CCW a page, the last without the
    /// More flag. Written into memory as the program writes it, so the
    /// testbench's memory and muir's are filled from the same rows.
    fn ccws(&mut self, clp: u32, pages: &[u32]) {
        for (k, &page) in pages.iter().enumerate() {
            let at = clp & !0xffff | (clp.wrapping_add(k as u32)) & 0xffff;
            let ccw = page << 8 | u32::from(k + 1 < pages.len());
            self.poke(at, ccw);
        }
    }

    /// The same, with two bits above the page field set: `DCCCW` latches
    /// `XBI<21:8>` and nothing above, so a CCW carrying `<23:22>` names
    /// the page its lower bits name.
    fn ccws_wide(&mut self, clp: u32, pages: &[u32]) {
        for (k, &page) in pages.iter().enumerate() {
            let at = clp & !0xffff | (clp.wrapping_add(k as u32)) & 0xffff;
            let ccw = page << 8 | 3 << 22 | u32::from(k + 1 < pages.len());
            self.poke(at, ccw);
        }
    }

    /// One word of main memory, set by the program.
    fn poke(&mut self, at: u32, v: u32) {
        self.main[at as usize] = v;
        self.say(format!("MEMW {at:x} {v:x}"));
    }

    /// A page of main memory filled by the program: the source of a write,
    /// or the poison a read has to displace.
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

    /// The image of one watched block, as the drive would hand it over.
    fn image(&mut self, c: u32, h: u32, b: u32) -> Image {
        let u = self.d.units[0].as_mut().expect("a drive on unit 0");
        let hdr = u.header_at(c, h, b).expect("an address on the pack");
        let dck = u.data_checkword_at(c, h, b).expect("an address on the pack");
        let data = u.block_at(c, h, b).expect("an address on the pack");
        Image {
            header: hdr.word,
            header_checkword: u32::from_le_bytes(hdr.checkword),
            data_checkword: u32::from_le_bytes(dck),
            data,
        }
    }

    /// Every watched block whose 259 words have changed, said again.
    ///
    /// **The row says why it is there, and that is not decoration.** A block
    /// that changed because a *formatter* wrote it --- `ATTACH` or `LAY` ---
    /// is STIMULUS: the testbench loads it into the store and the DUT is not
    /// expected to have it. A block that changed because a *transfer* wrote
    /// it is an EXPECTED OUTPUT: the DUT's own store must already hold
    /// exactly these 259 words, and that is the whole of the check on the
    /// write path. Without the tag a reader has to infer which from the row
    /// before it, and the first model written against this trace got it
    /// wrong in exactly that way.
    fn emit_blocks(&mut self, why: &str) -> u64 {
        if self.d.units[0].is_none() {
            return 0;
        }
        let mut n = 0u64;
        for k in 0..self.watch.len() {
            let (c, h, b) = self.watch[k];
            let img = self.image(c, h, b);
            let lba = lba_of(c, h, b);
            if self.shadow.get(&lba) == Some(&img) {
                continue;
            }
            self.shadow.insert(lba, img.clone());
            self.blk_rows += 1;
            n += 1;
            let mut row = format!(
                "BLK {why} {k} {lba:x} {c:x} {h:x} {b:x} {:x} {:x} {:x}",
                img.header, img.header_checkword, img.data_checkword
            );
            for w in &img.data {
                row.push_str(&format!(" {w:x}"));
            }
            self.say(row);
        }
        n
    }

    /// The drive plugged in at unit 0, with the watched blocks written.
    fn attach(&mut self, watch: Vec<(u32, u32, u32)>) {
        let mut u = Unit::blank(G);
        for &(c, h, b) in &watch {
            let lba = lba_of(c, h, b);
            let data: [u32; BLOCK_WORDS] = std::array::from_fn(|i| pack_word(lba, i as u32));
            assert!(u.write_block_at(c, h, b, &data), "block {c}/{h}/{b} is off the pack");
        }
        self.d.attach(0, u);
        self.watch = watch;
        let n = self.line;
        self.line += 1;
        self.say(format!("ATTACH {n} {} 0 {}", self.now, self.watch.len()));
        self.emit_blocks("load");
    }

    /// The read-only switch on the drive: "the read-only switch only
    /// applies when the drive is not selected", and nothing models the
    /// switch, so it is stimulus.
    fn read_only(&mut self, v: bool) {
        self.d.units[0].as_mut().unwrap().read_only = v;
        let n = self.line;
        self.line += 1;
        self.say(format!("RO {n} {} {}", self.now, u8::from(v)));
    }

    /// `-XBUS INIT` on the backplane, which is not a bus cycle on these
    /// four registers.
    fn xbus_init(&mut self) {
        self.d.advance(self.now);
        self.d.xbus_init();
        let (s, da, lma, ecc, intr) = self.face();
        let n = self.line;
        self.line += 1;
        self.say(format!("INIT {n} {} {s:x} {da:x} {lma:x} {ecc:x} {intr}", self.now));
        assert_eq!(self.emit_blocks("init"), 0, "an init changed the pack");
    }

    /// Whether the run charges the drive's own time. Off is how muir runs
    /// and what every count this project quotes was measured with; on is
    /// the only way to reach a seek's length and a transfer's latency.
    fn timed(&mut self, v: bool) {
        self.d.timed = v;
        let n = self.line;
        self.line += 1;
        self.say(format!("TIMED {n} {} {}", self.now, u8::from(v)));
    }

    /// A sector laid down on the pack by something other than the
    /// controller: a formatter, or the vendor of the pack. The header word
    /// and both checkwords are given rather than computed, which is the
    /// only way a pack can disagree with itself.
    fn lay(&mut self, c: u32, h: u32, b: u32, header: u32, hck: [u8; 4], data: &[u32; BLOCK_WORDS],
           dck: [u8; 4]) {
        let u = self.d.units[0].as_mut().unwrap();
        assert!(
            u.write_sector_at(c, h, b, Header { word: header, checkword: hck }, data, dck),
            "sector {c}/{h}/{b} is off the pack"
        );
        let n = self.line;
        self.line += 1;
        self.say(format!("LAY {n} {} {c:x} {h:x} {b:x}", self.now));
        self.emit_blocks("lay");
    }

    /// A whole command: the four stores MIT's own sequence makes, and the
    /// status afterwards.
    fn command(&mut self, cmd: u32, clp: u32, da: u32) {
        self.write(0, cmd);
        self.write(1, clp);
        self.write(2, da);
        self.write(3, 0);
        self.read(0);
    }
}

/// The checkword over a block's data, as the board writes it after every
/// data field.
fn data_checkword(data: &[u32; BLOCK_WORDS]) -> [u8; 4] {
    let mut e = Ecc::default();
    for w in data {
        e.feed(&w.to_le_bytes());
    }
    e.checkword()
}

fn main() {
    let mut g = Gen::new();

    // ------------------------------------------------------------------
    // The blocks the fabric's store holds. Two windows, because the pack
    // is 263,245 blocks and the store is 259 words a block: a whole track
    // for Read All and Write All and the walk, three blocks over the head
    // boundary, two over the cylinder boundary, and the last block of the
    // pack, which is where a transfer runs off the end.
    // ------------------------------------------------------------------
    let mut watch: Vec<(u32, u32, u32)> = Vec::new();
    for b in 0..G.blocks_per_track {
        watch.push((0, 0, b));
    }
    for b in 0..3 {
        watch.push((0, 1, b));
    }
    watch.push((0, G.heads - 1, G.blocks_per_track - 1));
    watch.push((1, 0, 0));
    watch.push((G.cylinders - 1, G.heads - 1, G.blocks_per_track - 1));

    // ------------------------------------------------------------------
    // Phase 0: a board on the bus with nothing on its cable. This is what
    // MIT's boot PROM sees for 16,951 bus cycles, and the one place the
    // full-length timeout is paid for.
    // ------------------------------------------------------------------
    g.at(0);
    // Unit 7, which has no drive and never will here.
    g.write(2, da_of(7, 0, 0, 0));
    g.read(0);
    g.read(1);
    g.read(2);
    g.read(3);

    // A read stops before it starts: the disk lossage presets BUSY off.
    g.fill(2);
    g.ccws(CLP, &[2]);
    g.command(0o00, CLP, da_of(7, 0, 0, 0));

    // At ease, recalibrate and fault clear run to done with no error:
    // CMD2 masks the empty cable's lossage.
    for cmd in [0o5u32, 0o1005, 0o405] {
        g.command(cmd, CLP, da_of(7, 0, 0, 0));
    }

    // A seek waits at its first step for a drive that never answers, and
    // MIT's board with the timeout jumper in ends it 2.56 s on. **The one
    // full-length hang in the trace**: 512,000,000 ticks of the fabric's
    // clock, and `docs/disk-controller.md` says why there is only one.
    g.write(0, 0o4);
    g.write(3, 0);
    g.read(0); // active, no error
    g.hangs += 1;
    let hung_at = g.now;
    g.at(grid_before(hung_at + TIMEOUT_NS));
    g.read(0); // still waiting
    g.at(hung_at + TIMEOUT_NS);
    g.read(0); // timed out, and the transfer lossage with it
    g.full_timeouts += 1;
    g.write(0, 0o16);
    g.read(0);
    g.write(0, 0);
    g.read(0);

    // An offset clear does the same, and a Reset stops it clean rather
    // than waiting the timer out.
    g.wait(1_000);
    g.write(0, 0o6);
    g.write(3, 0);
    g.read(0);
    g.hangs += 1;
    g.wait(1_000_000);
    g.read(0);
    g.write(0, 0o16);
    g.read(0);
    g.write(0, 0);

    // `-XBUS INIT` with nothing on the cable.
    g.wait(1_000);
    g.xbus_init();
    g.read(0);

    // ------------------------------------------------------------------
    // Phase 1: a drive on unit 0, and the block counter.
    // ------------------------------------------------------------------
    g.wait(1_000);
    g.attach(watch);
    g.write(2, da_of(0, 0, 0, 0));
    g.read(0);

    // **The block counter, either side of all eighteen trailing edges.**
    // The count steps to `k` as region `k`'s pulse ends and holds the
    // region before it through the pulse, so an edge is the one instant
    // where a counter clocked on the other one differs. The spindle's
    // index is at time zero of the machine's clock, so the phase is taken
    // from a whole number of revolutions and the edges follow from it.
    //
    // Every sample is on the 5 ns grid; the edges themselves are not, and
    // that is the whole reason for sampling either side rather than at
    // them. A revolution is 16,666,667 ns and a sector 968,448, neither a
    // multiple of five.
    let turn = g.now.div_ceil(REVOLUTION_NS) * REVOLUTION_NS;
    for k in 0..=G.blocks_per_track {
        let began = turn + u64::from(k) * SECTOR_NS;
        let ends = began + if k == 0 { INDEX_PULSE_NS } else { disk_unit::SECTOR_PULSE_NS };
        g.at(grid_before(ends));
        g.read(0); // the region before, still
        g.at(grid_at(ends));
        g.read(0); // and now this one
        // A third sample well inside the region, which is what
        // `DCHECK-BLOCK-COUNTER` reads.
        g.at(grid_at(began + 100_000));
        g.read(0);
    }
    // The index closing the leftover: 17 through the pulse, 0 after it.
    let idx = turn + REVOLUTION_NS;
    g.at(grid_at(idx + 2_500));
    g.read(0);
    g.at(grid_at(idx + INDEX_PULSE_NS));
    g.read(0);

    // With no drive on the selected unit there are no pulses to count.
    g.write(2, da_of(7, 0, 0, 0));
    g.read(0);
    g.write(2, da_of(0, 0, 0, 0));
    g.read(0);

    // ------------------------------------------------------------------
    // Phase 2: transfers.
    // ------------------------------------------------------------------
    // The pages the program uses. Spread rather than huddled, so a bridge
    // that dropped an address bit would be caught, and every one filled by
    // the program before it is used.
    let src = [0x10u32, 0x11, 0x12];
    let dst = [0x40u32, 0x41, 0x42];
    for p in src.iter().chain(dst.iter()) {
        g.fill(*p);
    }

    // A write of three blocks from three pages, and the read back into
    // three others.
    g.ccws(CLP, &src);
    g.command(0o11, CLP, da_of(0, 0, 0, 0));
    g.read(1); // the last memory address: the last word of the last page
    g.read(2); // and the disk address of the last block transferred

    g.ccws(CLP, &dst);
    g.command(0o00, CLP, da_of(0, 0, 0, 0));
    g.read(1);
    g.read(2);

    // Read-compare against the pages the write came from: no difference.
    g.ccws(CLP, &src);
    g.command(0o10, CLP, da_of(0, 0, 0, 0));
    g.read(0);

    // One word changed, and the same compare reports the difference and
    // carries on: "This error does not stop the transfer."
    g.poke(src[1] * BLOCK_WORDS as u32 + 100, 0xDEAD_BEEF);
    g.ccws(CLP, &src);
    g.command(0o10, CLP, da_of(0, 0, 0, 0));
    g.read(0);
    // And put it back, so the pack and the pages agree again.
    g.poke(src[1] * BLOCK_WORDS as u32 + 100, mem_word(src[1], 100));

    // A CCW carrying `<23:22>`: the page is the twenty-two bits the Xbus
    // has and the two above go nowhere.
    let wide = 0x50u32;
    g.fill(wide);
    g.ccws_wide(CLP, &[wide]);
    g.command(0o00, CLP, da_of(0, 0, 0, 0));
    g.read(1);

    // The command list walked out of the low sixteen bits: "if you attempt
    // to carry into the high 8 bits you will wrap around."
    let wrapped = [0x60u32, 0x61, 0x62];
    for p in wrapped {
        g.fill(p);
    }
    g.ccws(CLP_WRAP, &wrapped);
    g.command(0o00, CLP_WRAP, da_of(0, 0, 0, 0));
    g.read(1);

    // A CCW naming a page past the end of memory: `STATUS<20>`, and it
    // stops the transfer.
    g.poke(CLP, 0x003F_FF00);
    g.command(0o00, CLP, da_of(0, 0, 0, 0));
    g.read(0);

    // A write to a read-only pack is a fault, and the fault clear takes it
    // away: `<13>` goes with the store, whose CMD2 masks the disk lossage,
    // and `<6>` with the START.
    g.read_only(true);
    g.ccws(CLP, &src);
    g.command(0o11, CLP, da_of(0, 0, 0, 0));
    g.read(0);
    g.write(0, 0o405);
    g.read(0);
    g.write(3, 0);
    g.read(0);
    g.read_only(false);

    // Read All: the track's own bytes, format and all, into the pages the
    // list names. Three pages is two sectors and a little, enough for a
    // testbench to parse one back.
    let all = [0x70u32, 0x71, 0x72];
    for p in all {
        g.fill(p);
    }
    g.ccws(CLP, &all);
    g.command(0o02, CLP, da_of(0, 0, 0, 0));
    g.read(0);

    // Write All: a two-sector track image built in memory, the second
    // sector claiming to be block 9 of cylinder 3. What a formatter lays
    // down is what the pack then carries, and the ordinary Read below
    // finds it.
    let liar = 3 << 16 | 9;
    let d0: [u32; BLOCK_WORDS] = std::array::from_fn(|i| pack_word(0xAAAA, i as u32));
    let d1: [u32; BLOCK_WORDS] = std::array::from_fn(|i| pack_word(0xBBBB, i as u32));
    let mut bytes = Vec::new();
    bytes.extend(disk_unit::sector_image_with_header(disk_unit::header_of(&G, 0, 0, 0), &d0));
    bytes.extend(disk_unit::sector_image_with_header(liar, &d1));
    let words: Vec<u32> =
        bytes.chunks_exact(4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
    let fmt = [0x80u32, 0x81, 0x82];
    for p in fmt {
        g.fill(p);
    }
    for (i, &w) in words.iter().enumerate() {
        let at = fmt[0] * BLOCK_WORDS as u32 + i as u32;
        g.poke(at, w);
    }
    g.ccws(CLP, &fmt);
    g.command(0o13, CLP, da_of(0, 0, 0, 0));
    g.read(0);

    // Block 0 is honest and reads back; block 1 says it is block 9 of
    // cylinder 3, and the compare stops the transfer with nothing moved.
    let probe = 0x90u32;
    g.fill(probe);
    g.ccws(CLP, &[probe]);
    g.command(0o00, CLP, da_of(0, 0, 0, 0));
    g.read(0);
    g.fill(probe);
    g.ccws(CLP, &[probe]);
    g.command(0o00, CLP, da_of(0, 0, 0, 1));
    g.read(0);

    // **The mask.** `<31:28>` of the header --- the next-block address
    // code and the two bits above the cylinder --- has no counterpart in
    // the disk address register and is not compared: on DCHDCM the first
    // of the four compares puts the read byte on both sides of the
    // 25LS2521. A header differing there alone is not an error, and the
    // block reads back.
    let d2: [u32; BLOCK_WORDS] = std::array::from_fn(|i| pack_word(0xCCCC, i as u32));
    let masked = disk_unit::header_of(&G, 0, 0, 2) ^ 0xF000_0000;
    g.lay(0, 0, 2, masked, Ecc::over(&masked.to_le_bytes()), &d2, data_checkword(&d2));
    g.fill(probe);
    g.ccws(CLP, &[probe]);
    g.command(0o00, CLP, da_of(0, 0, 0, 2));
    g.read(0);

    // A header that compares and does not check is `<17>`, header ECC ---
    // MIT's "most header ECC errors show up as header compare errors
    // instead" is the order the board asks the two questions in.
    let d3: [u32; BLOCK_WORDS] = std::array::from_fn(|i| pack_word(0xDDDD, i as u32));
    let right = disk_unit::header_of(&G, 0, 0, 3);
    let mut wrong = Ecc::over(&right.to_le_bytes());
    wrong[0] ^= 1;
    g.lay(0, 0, 3, right, wrong, &d3, data_checkword(&d3));
    g.fill(probe);
    g.ccws(CLP, &[probe]);
    g.command(0o00, CLP, da_of(0, 0, 0, 3));
    g.read(0);

    // A data checkword that does not check: `<15>` where `Ecc::trap` can
    // locate the burst and `<16>` where it cannot, and register 3 says
    // where. Eleven bits is the span the board's `-ECC=ZERO` leaves room
    // for, so five is soft and twenty is hard.
    for (block, width) in [(4u32, 5usize), (5, 20)] {
        let clean: [u32; BLOCK_WORDS] =
            std::array::from_fn(|i| pack_word(0xE000 + block, i as u32));
        let ck = data_checkword(&clean);
        let mut bad = clean;
        let at = 1000usize;
        for k in 0..width {
            if k == 0 || k == width - 1 || k % 3 == 0 {
                bad[(at + k) / 32] ^= 1 << ((at + k) % 32);
            }
        }
        let hdr = disk_unit::header_of(&G, 0, 0, block);
        g.lay(0, 0, block, hdr, Ecc::over(&hdr.to_le_bytes()), &bad, ck);
        g.fill(probe);
        g.ccws(CLP, &[probe]);
        g.command(0o00, CLP, da_of(0, 0, 0, block));
        g.read(0);
        g.read(3);
    }

    // The transfer order the format defines: "0 following block on same
    // track, 1 block 0 on next track (next head), 2 block 0 on head 0 of
    // next cylinder". Two CCWs from the last block of a track, and two
    // from the last block of a cylinder.
    let cross = [0xA0u32, 0xA1];
    for p in cross {
        g.fill(p);
    }
    g.ccws(CLP, &cross);
    g.command(0o00, CLP, da_of(0, 0, 0, G.blocks_per_track - 1));
    g.read(2);

    for p in cross {
        g.fill(p);
    }
    g.ccws(CLP, &cross);
    g.command(0o00, CLP, da_of(0, 0, G.heads - 1, G.blocks_per_track - 1));
    g.read(2);

    // "Header ECC Error also happens if an attempt is made to continue a
    // read or write operation past the end of the disk."
    for p in cross {
        g.fill(p);
    }
    g.ccws(CLP, &cross);
    g.command(0o00, CLP, da_of(0, G.cylinders - 1, G.heads - 1, G.blocks_per_track - 1));
    g.read(0);
    // And a transfer that *starts* off the pack is the other error: a seek
    // the drive refuses, `STATUS<10>`.
    g.ccws(CLP, &[cross[0]]);
    g.command(0o00, CLP, da_of(0, 0o7777, 0, 0));
    g.read(0);
    // Which only a recalibrate takes away: `-RESET ERR` does not reach the
    // drive's own flags.
    g.write(0, 0o1005);
    g.read(0);
    g.write(3, 0);
    g.read(0);

    // Codes 14 and 15 are the seek and the at-ease of their sectors: `<3>`
    // of the command steers the memory channel, and sectors 4 to 7 do not
    // use it.
    g.command(0o14, CLP, da_of(0, 0o7777, 0, 0));
    g.command(0o1015, CLP, da_of(0, 0, 0, 0));
    g.read(0);
    g.command(0o15, CLP, da_of(0, 0, 0, 0));

    // The interrupt, with each of its enables. "Done Interrupt Enable.
    // Enables not-active to cause an interrupt", and the attention enable
    // needs an attention: the controller here is never active, so the done
    // enable alone is the whole of the first.
    g.write(0, 1 << 11);
    g.read(0);
    g.write(0, 0);
    g.read(0);
    g.write(0, 1 << 10);
    g.read(0); // the attention enable with no attention: nothing
    // A seek raises one.
    g.command(0o4 | 1 << 10, CLP, da_of(0, 3, 0, 0));
    g.read(0);
    // And the at-ease takes it away, which drops the interrupt with it.
    g.command(0o5 | 1 << 10, CLP, da_of(0, 3, 0, 0));
    g.read(0);
    g.write(0, 0);

    // The three undocumented codes: the Write, Write All and Read All
    // sectors entered with the memory channel turned round. Held to their
    // status and not to their data, which is the board's fifo cycling and
    // is not in muir either.
    g.ccws(CLP, &[probe]);
    g.command(0o01, CLP, da_of(0, 0, 0, 6));
    g.command(0o03, CLP, da_of(0, 0, 0, 6));
    g.read(0);
    g.write(0, 0);
    g.read(0);
    g.command(0o12, CLP, da_of(0, 0, 0, 6));
    g.hangs += 1;
    g.wait(2_000_000);
    g.read(0);
    g.write(0, 0o16);
    g.read(0);
    g.write(0, 0);

    // Sector 7, which `newdsk.31` leaves unwritten: the sequencer starts
    // and never finishes.
    for cmd in [0o07u32, 0o17] {
        g.command(cmd, CLP, da_of(0, 0, 0, 6));
        g.hangs += 1;
        g.wait(3_000_000);
        g.read(0);
        g.write(0, 0o16);
        g.read(0);
        g.write(0, 0);
    }

    // `-XBUS INIT` after an error: the command register and the error
    // flops go, the disk address counters and the CLP stand.
    g.write(0, 0o17 | 1 << 11);
    g.write(3, 0);
    g.hangs += 1;
    g.read(0);
    g.xbus_init();
    g.read(0);
    g.read(2);
    // The command list pointer's own counters have no pin on `-XINIT` and
    // stand: a transfer started now with **no store into register 1** walks
    // the list it was given before, and register 1 then reads the last word
    // of the page that list named.
    g.write(2, da_of(0, 0, 0, 9));
    g.write(0, 0o00);
    g.write(3, 0);
    g.read(1);

    // ------------------------------------------------------------------
    // Phase 3: the drive's own time. `Controller::timed` off is how muir
    // runs and what every count this project quotes was measured with;
    // with it on, an operation takes what the drive takes and `STATUS<0>`
    // is clear for the whole of it, which is the thing a driver waits on.
    // ------------------------------------------------------------------
    g.wait(1_000);
    g.timed(true);

    // A seek of one cylinder from where the heads are, and one of two:
    // 6,000,000 ns exactly and 6,060,271, which is not on the grid.
    g.write(2, da_of(0, 0, 0, 0));
    g.command(0o1005, CLP, da_of(0, 0, 0, 0)); // heads home first
    g.wait(seek_ns(G.cylinders - 1) + 1_000);
    g.read(0);

    for (to, from) in [(1u32, 0u32), (3, 1)] {
        let ns = seek_ns(to.abs_diff(from));
        g.write(0, 0o4);
        g.write(2, da_of(0, to, 0, 0));
        g.write(3, 0);
        let began = g.now;
        g.read(0); // busy, and the attention not yet up
        g.at(grid_before(began + ns));
        g.read(0); // still busy
        g.at(grid_at(began + ns));
        g.read(0); // the heads have arrived, and the attention with them
        g.command(0o5, CLP, da_of(0, to, 0, 0)); // at ease
    }

    // A transfer with the drive's time charged: the heads' move, the wait
    // for the block to come round, and a sector a block.
    g.timed(false);
    g.command(0o1005, CLP, da_of(0, 0, 0, 0));
    g.timed(true);
    g.fill(dst[0]);
    g.ccws(CLP, &[dst[0]]);
    g.write(0, 0o00);
    g.write(1, CLP);
    g.write(2, da_of(0, 0, 0, 8));
    let began = g.now;
    g.write(3, 0);
    g.read(0); // active: the words have moved, the done has not
    // The length is muir's own arithmetic; the trace does not repeat it,
    // it walks up to it. `until` is a function of the instant the seek
    // ends, so the figure is read off the model rather than derived here.
    let mut span = 0u64;
    while span < 20 * REVOLUTION_NS {
        span += SECTOR_NS;
        g.at(grid_at(began + span));
        let s = g.read(0);
        if s & 1 != 0 {
            break;
        }
    }
    g.timed(false);
    g.read(0);

    // ------------------------------------------------------------------
    // The header, written last because the coverage is only known now.
    // ------------------------------------------------------------------
    let mut head = Vec::new();
    head.push("# the disk controller with a drive and a pack, out of muir's".to_string());
    head.push("# disk_controller::Controller --- generated by golden/src/disk.rs".to_string());
    head.push("#".to_string());
    head.push("# every value hexadecimal except the row number and the flags".to_string());
    head.push("#".to_string());
    head.push("# ATTACH   n now unit slots        a drive plugged in at a unit".to_string());
    head.push("# RO       n now v                 the drive's read-only switch".to_string());
    head.push("# TIMED    n now v                 whether the drive's time is charged".to_string());
    head.push("# LAY      n now cyl head blk      a sector laid down by a formatter".to_string());
    head.push("# BLK      why slot lba cyl head blk header hck dck w0..w255".to_string());
    head.push("#          why is load|lay --- stimulus, the store is filled --- or".to_string());
    head.push("#          write, an expected output: the DUT's own store must hold it".to_string());
    head.push("# MEMPAGE  page w0..w255           main memory, as the program fills it".to_string());
    head.push("# MEMW     addr word               one word of it".to_string());
    head.push("# CYC      n now reg write wdata rdata status da lma ecc intr pages".to_string());
    head.push("# PAGE     page w0..w255           a page the transfer moved".to_string());
    head.push("#".to_string());
    head.push(format!("# geometry {} {} {}", G.cylinders, G.heads, G.blocks_per_track));
    head.push(format!("# memory_words {MEMORY_WORDS}"));
    head.push(format!("# block_words {BLOCK_WORDS}"));
    head.push(format!("# timeout_ns {TIMEOUT_NS}"));
    head.push(format!("# revolution_ns {REVOLUTION_NS}"));
    head.push(format!("# sector_ns {SECTOR_NS}"));
    head.push(format!("# index_pulse_ns {INDEX_PULSE_NS}"));
    head.push(format!("# sector_pulse_ns {}", disk_unit::SECTOR_PULSE_NS));
    head.push(format!("# sector_bytes {}", format::SECTOR));
    head.push(format!("# slots {}", g.watch.len()));
    head.push(format!("# last_ns {}", g.now));
    head.push(format!("# ticks {}", g.now / TICK_NS));
    head.push("#".to_string());
    head.push("# coverage".to_string());
    let mut cmdline = String::from("# commands");
    for code in 0..0o20u32 {
        cmdline.push_str(&format!(" {code:02o}:{}", g.cmds.get(&code).copied().unwrap_or(0)));
    }
    head.push(cmdline);
    let bits: Vec<u32> = (0..24).filter(|b| g.status_seen >> b & 1 != 0).collect();
    let missing: Vec<u32> = (0..24).filter(|b| g.status_seen >> b & 1 == 0).collect();
    head.push(format!(
        "# status bits ever set below the counter: {} of 24 --- {:?}",
        bits.len(),
        bits
    ));
    // The five `Controller` cannot reach, named so that nobody goes looking:
    // `<4>` multiple units, `<12>` start block, `<19>` memory parity, `<21>`
    // CCW cycle --- set and cleared inside one store, so no read sees it ---
    // and `<23>` internal parity.  `docs/disk-controller.md` lists the same
    // five, and the netlist board raises two of them.
    head.push(format!(
        "# never set, and unreachable in this model: {missing:?} \
         --- 4 multiple units, 12 start block, 19 memory parity, \
         21 CCW cycle, 23 internal parity"
    ));
    assert_eq!(missing, vec![4, 12, 19, 21, 23], "a bit changed reachability");
    head.push(format!(
        "# block counter values seen: {} --- {:?}",
        g.counters_seen.len(),
        g.counters_seen
    ));
    head.push(format!(
        "# register cycles: reads {:?} writes {:?}",
        g.reads, g.writes
    ));
    head.push(format!(
        "# starts {} pages_to_memory {} blocks_to_pack {} block_rows {}",
        g.starts, g.pages_moved, g.blocks_to_pack, g.blk_rows
    ));
    head.push(format!("# hangs {} of which run to the timeout {}", g.hangs, g.full_timeouts));

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
