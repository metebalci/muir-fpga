// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's block-disk with a pack** (contract G2 §4.2; G3 revision
//! 15, A15b.5, A15b.6, A15b.12, A15b.13), as runs
//! of `golden/src/quux15.rs`'s kind on muir's pipeline with a pack attached
//! to its `BlockDisk`, whose blocks start as a rule both sides know
//! ([`pack_word`]).  muir moves a START's pages at once, after landing every
//! queued write, and clears the set of every line a read wrote; the fabric
//! walks them over the blocks' time (`rtl/machine/quux15_block_walk.sv`), its
//! words on revision 15's port.  So:
//!
//!   bdisk     **CLOCK FOR CLOCK BUT THE TRANSFER'S WINDOW** (A15b.5): the
//!             processor touches no port from START to the walk's last
//!             answered write, polling block-disk's registers or counting,
//!             and `tb/quux15_core_tb.cpp` holds every row to muir's, the
//!             queue's and the in-flight list's depths (the processor's
//!             entries) outside the window; the late model off; at P = 17
//!             and 36, where 200,000 / P is not whole, so that DONE rounded
//!             per block shows.  Each run ends with main memory's pages and
//!             the pack's blocks it names held to muir's.
//!     read      a packed read, its entry and a write of its page queued at
//!               START (the transfer's word wins); the four-line probe
//!               before DONE and after it: a line of the page read (it
//!               misses), a line of another page in a cleared set (it
//!               misses), a line of a set untouched (it hits), and muir's
//!               cache at DONE (`Cache15::holds`) checked here for three
//!               more lines no probe reads before it
//!     write     a 4-byte write and a packed one, a line of the first's page
//!               cached before (it still hits) and one not (it misses: the
//!               transfer's reads allocate nothing)
//!     ends      a read through the pack's last block into the block past
//!               it; an entry whose page main memory has not, and an entry
//!               past main memory; the status, the disk address and the
//!               last memory address after each
//!     reset     RESET-DEVICES while the walk runs: not active at once, the
//!               page whole all the same
//!     midckpt   a checkpoint taken while the walk runs, which the board's
//!               writer refuses (A15b.13)
//!     donephase a 4-byte read of four blocks polled until not active, its
//!               poll moved a clock at a time until one reads the status at
//!               the first clock at or after DONE, chosen on muir for each
//!               bubble count, so that a DONE even a clock late shows
//!               whatever the port's timing puts START at
//!   bdmix     **JUDGED BY THE RESULTS**: the processor uses the port while the walk runs, so no
//!             row is held to muir's; the pages and the blocks named are, and
//!             the processor's reads after DONE, which the program writes
//!             into a page of results.  The testbench's memory answers a
//!             read with the words as they stood when its address was taken
//!             (`# read-at-ar`), so that a read let past a write reads the
//!             old words.
//!     heldr     the processor's fills of the page being read held 400 clocks
//!               each, so that the transfer writes a line whose fill is in
//!               flight: it must wait for the fill (A15b.5)
//!     slowb     writes answered 600 clocks after their accept: the entry
//!               written just before START, and the processor's fills of the
//!               page being read, swept again and again while the walk
//!               writes it, wait for the transfer's queued and in-flight
//!               writes (A15b.5's read rule)
//!     ahead     a second START over blocks the store holds, eight writes of
//!               its page's first words queued 40 clocks apart: the
//!               transfer's words land after them (Q11)
//!     starve    the processor writing every chance it has until DONE: the
//!               transfer is let in after its patience, or DONE never comes
//!     mixed     the processor reading and writing other pages, and the
//!               page being read, while a two-page read walks

use muir::disk_image::Disk;
use muir::engine::Engine;
use muir::isa::asm::{ALU, JUMP, MD, N, SETA, SETM, SRC_MD, START_READ, START_WRITE, a_src, m_dest, m_src, target};
use muir::machine::Word;
use muir::pipeline::{Pipeline, PortTiming};

use super::quux15_console::Act;
use super::quux15_preset::Preset;

/// The pack, and how a run is judged.
#[derive(Clone, Default)]
pub struct DiskRun {
    /// The pack's blocks, each [`pack_word`]'s at first.
    pub blocks: u32,
    /// The testbench's pack side: clocks from a request to its fill.
    pub latency: u32,
    /// Main memory's 1024-word pages held to muir's at the end, by their
    /// first word.
    pub pages: Vec<u32>,
    /// The pack's blocks held to muir's at the end.
    pub disk_blocks: Vec<u32>,
    /// No row held to muir's: the pages and blocks alone.
    pub results_only: bool,
    /// The testbench's memory answers a read with the words as they stood
    /// when its address was taken.
    pub read_at_ar: bool,
    /// The run's clocks at most, past the generator's 200,000.
    pub max_clocks: u64,
    /// muir's cache at DONE: whether it holds each line (`Cache15::holds`).
    pub holds: Vec<(u32, bool)>,
    /// A checkpoint the run ends in is taken while the transfer is in
    /// flight, which the board's writer refuses (A15b.13).
    pub refuse: bool,
}

/// A block's word at first: a function of the block and the word, so that
/// no wrong block and no wrong offset reads right (`tb/quux13_block_disk_tb.cpp`'s
/// rule, which `tb/quux15_core_tb.cpp` keeps).
pub fn pack_word(lba: u32, w: u32) -> u32 {
    let rot = (lba << 23) | (lba >> 9);
    (lba << 12) ^ (w << 1) ^ 0x5a00_0001 ^ rot
}

/// The pack: `blocks` blocks of [`pack_word`].
pub fn pack(blocks: u32) -> Disk {
    let mut d = Disk::blank(blocks);
    for lba in 0..blocks {
        let words: [u32; 256] = std::array::from_fn(|w| pack_word(lba, w as u32));
        assert!(d.write_block(lba, &words), "block {lba} of a pack of {blocks}");
    }
    d
}

/// FNV-1a over words of `bytes` bytes each, least significant first.
pub fn fnv(words: impl Iterator<Item = u64>, bytes: usize) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for w in words {
        for b in 0..bytes {
            h ^= ((w >> (8 * b)) & 0xff) as u32;
            h = h.wrapping_mul(0x0100_0193);
        }
    }
    h
}

impl DiskRun {
    /// The trace's lines before the rows: the pack and its pack side, and
    /// the memory's read model.
    pub fn lines(&self) -> Vec<String> {
        let mut out = vec![format!("# pack {:x} {:x}", self.blocks, self.latency)];
        if self.read_at_ar {
            out.push("# read-at-ar".to_string());
        }
        out
    }

    /// The run's end as muir leaves it: each page named, five bytes a word,
    /// and each block, by their hashes; and for a run judged by its results,
    /// where it parks and the clocks muir took.
    pub fn end_lines(&self, e: &Pipeline, park: u64) -> Vec<String> {
        let m = e.machine();
        let mut out = Vec::new();
        for &p in &self.pages {
            let at = p as usize;
            out.push(format!("# endpage {p:x} {:x}", fnv(m.main[at..at + 1024].iter().copied(), 5)));
        }
        let mut bd = m.block_disk.clone().expect("block-disk");
        let disk = bd.disk_mut().expect("a pack");
        for &b in &self.disk_blocks {
            let words = disk.read_block(b).expect("a block of the pack");
            out.push(format!("# endblock {b:x} {:x}", fnv(words.iter().map(|&w| u64::from(w)), 4)));
        }
        if self.results_only {
            out.push(format!("# results-only {park:x} {:x}", e.clock()));
        }
        out
    }
}

/// **muir's cache at DONE**: armed while block-disk is active, it reads
/// `Cache15::holds` for each line at the first clock after that whose
/// instant is DONE's or later, and refuses a run whose cache is not as the
/// run says.
#[derive(Default)]
pub struct Watch {
    holds: Vec<(u32, bool)>,
    armed: bool,
    done: bool,
    pub lines: Vec<String>,
}

impl Watch {
    pub fn new(d: Option<&DiskRun>) -> Watch {
        Watch { holds: d.map_or(Vec::new(), |d| d.holds.clone()), ..Watch::default() }
    }

    pub fn watch(&mut self, e: &Pipeline) -> Result<(), String> {
        if self.holds.is_empty() || self.done {
            return Ok(());
        }
        let Some(bd) = e.machine().block_disk.as_ref() else { return Ok(()) };
        // Command <11> is up in these runs, so the interrupt is DONE: armed
        // once the command has it and DONE is still to come.
        if !bd.interrupt_at(e.clock() * e.period()) {
            self.armed |= bd.interrupt_at(u64::MAX);
            return Ok(());
        }
        if !self.armed {
            return Ok(());
        }
        self.done = true;
        for &(bus, want) in &self.holds {
            let got = e.port.cache.holds(bus);
            self.lines.push(format!("# holds {:x} {bus:x} {}", e.clock(), u8::from(got)));
            if got != want {
                return Err(format!(
                    "at DONE, clock {}, muir's cache {} the line of {bus:o}, which the run says it {}",
                    e.clock(),
                    if got { "holds" } else { "does not hold" },
                    if want { "holds" } else { "does not" }
                ));
            }
        }
        Ok(())
    }

    /// Whether every line was checked, if any was to be.
    pub fn finished(&self) -> bool {
        self.holds.is_empty() || self.done
    }
}

// --- The programs ------------------------------------------------------------

/// The register page's virtual address.
const REGISTER_PAGE: Word = 0o35777777400;
/// The physical memory window: main memory at `VA<27:0>`.
const PHYS: Word = 0o36000000000;
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;
/// The A word a poll tests.
const TESTED: u64 = 0o1710;

/// The command list; a page a read writes; another page of its sets (32K
/// words on, a way of the Kria's 4,096 sets of 8 words, and a whole number
/// of ways of every smaller cache); a page of sets the transfers leave; a
/// page a write reads, and a second; the results' page.
const CL: u32 = 0o3000;
const T: u32 = 0o40000;
const O: u32 = T + 0o100000;
const U: u32 = T + 0o4000;
/// The read's page of sets the transfers leave: `U`, or half a way of the
/// board's cache past T where a way is smaller than 4,096 words (the Arty's
/// 4K words, 256 sets of 8 words a way, where `U` falls in T's sets).
fn u_read() -> u32 {
    T + (super::cache_words() / 4).min(U - T)
}
const S: u32 = 0o150000;
const S2: u32 = S + 0o2000;
const RES: u32 = 0o160000;
/// The pack's size.
const BLOCKS: u32 = 64;
/// Block-disk's commands: a read, a write; `<12>` the 4-byte transfer,
/// `<11>` the done interrupt's enable.
const READ: Word = 0;
const WRITE: Word = 0o11;
const FOUR: Word = 1 << 12;
const IE: Word = 1 << 11;

const fn reg(k: u64) -> Word {
    REGISTER_PAGE | k
}
const fn phys(a: u32) -> Word {
    PHYS | a as Word
}

/// A JUMP on condition `code`.
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// A run with -RESET's sweep of the TLB taken as done and the pack fitted.
fn run(d: DiskRun) -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p.disk = Some(DiskRun { blocks: BLOCKS, latency: 40, ..d });
    p
}

impl Preset {
    /// Waits until block-disk's status reads not active: a read, a word,
    /// the test, and back.
    fn bd_wait(&mut self) -> &mut Self {
        let (at, b) = (self.k(reg(0o200)), self.k(1));
        let top = self.at();
        self.op(ALU | SETA | a_src(at) | START_READ);
        self.fill(1);
        self.op(ALU | muir::isa::asm::AND | SRC_MD | a_src(b) | muir::isa::asm::a_dest(TESTED));
        self.op(jcond(3) | a_src(TESTED) | m_src(M_ZERO) | target(top) | N);
        self.fill(1)
    }

    /// Counts M `m` down from `n` to 0, touching no port.
    fn bd_delay(&mut self, m: u64, n: u64) -> &mut Self {
        let k = self.k(n);
        self.op(ALU | SETA | a_src(k) | m_dest(m));
        let top = self.at();
        self.op(ALU | muir::isa::asm::SUB | a_src(ONE) | m_src(m) | m_dest(m));
        self.op(jcond(3) | 1 << 6 | a_src(ZERO) | m_src(m) | target(top) | N);
        self.fill(1)
    }

    /// `body` run `n` times, M `m` counting, touching what it touches.
    fn bd_sweeps(&mut self, m: u64, n: u64, body: impl Fn(&mut Preset)) -> &mut Self {
        let k = self.k(n);
        self.op(ALU | SETA | a_src(k) | m_dest(m));
        let top = self.at();
        body(self);
        self.op(ALU | muir::isa::asm::SUB | a_src(ONE) | m_src(m) | m_dest(m));
        self.op(jcond(3) | 1 << 6 | a_src(ZERO) | m_src(m) | target(top) | N);
        self.fill(1)
    }

    /// M `m` written to main memory's word `a`.
    fn bd_store(&mut self, m: u64, a: u32) -> &mut Self {
        let va = self.k(phys(a));
        self.op(ALU | SETM | m_src(m) | MD);
        self.op(ALU | SETA | a_src(va) | START_WRITE);
        self.fill(2)
    }

    /// The registers for a transfer: the command list pointer, the disk
    /// address and the command, none of them behind a queued write (muir
    /// lands the queue at any of block-disk's words).
    fn bd_setup(&mut self, clp: u32, da: u32, cmd: Word) -> &mut Self {
        self.write(Word::from(clp), reg(0o201)).write(Word::from(da), reg(0o202)).write(cmd, reg(0o200))
    }

    /// START.
    fn bd_start(&mut self) -> &mut Self {
        self.write(0, reg(0o203))
    }

    /// The disk address, the last memory address and the status into M
    /// `m` up.
    fn bd_registers(&mut self, m: u64) -> &mut Self {
        self.read(reg(0o202), m).read(reg(0o201), m + 1).read(reg(0o200), m + 2)
    }
}

/// A page's words: 40 bits each, every byte a function of the address.
fn page_words(page: u32) -> Vec<(usize, Word)> {
    (0..1024u32)
        .map(|w| {
            let a = page + w;
            let x = (u64::from(a) + 1).wrapping_mul(0x9e37_79b9_7f4a_7c15);
            (a as usize, ((x >> 17) ^ 0x5a_c3a5_3c0f) & 0xff_ffff_ffff)
        })
        .collect()
}

/// The delay from START to the probe before DONE: past the walk's end on
/// the testbench's pack side, before DONE at 17 and at 36.
const AFTER_WALK: u64 = 5000;
/// A count past a five-block transfer's DONE at P = 17, 58,824 clocks: two
/// clocks a count at the least.
const PAST_DONE: u64 = 31_000;

/// **The clock-for-clock runs.**
pub fn bdisk() -> Vec<(String, Preset)> {
    let mut v = Vec::new();

    // A packed read of page T from blocks 3-7.  Before it the cache holds
    // T+8 and O+8, both ways of one set, u+8 (`u_read`, a page of sets T
    // has not on every board's cache), and three more lines like them,
    // T+16, O+16 and u+16, which only DONE's check reads before the probe
    // after it.
    let u = u_read();
    let mut p = run(DiskRun {
        pages: vec![T, O, u, CL & !0o1777, 0],
        disk_blocks: (3..8).collect(),
        holds: vec![(T + 16, false), (O + 16, false), (u + 16, true)],
        ..DiskRun::default()
    });
    p.main.extend(page_words(O));
    p.main.extend(page_words(u));
    for (k, a) in [T + 8, O + 8, u + 8, T + 16, O + 16, u + 16].into_iter().enumerate() {
        p.read(phys(a), 0o20 + k as u64);
    }
    p.bd_setup(CL, 3, READ | IE);
    // The entry and a word of the page, queued at START.
    p.write(Word::from(T), phys(CL)).write(0o1234567, phys(T + 5));
    p.bd_start();
    p.bd_delay(0o26, AFTER_WALK);
    for (k, a) in [T + 8, O + 8, u + 8].into_iter().enumerate() {
        p.read(phys(a), 0o20 + k as u64);
    }
    p.bd_wait();
    for (k, a) in [T + 8, O + 8, u + 8, T + 16, O + 16, u + 16, T + 5].into_iter().enumerate() {
        p.read(phys(a), 0o20 + k as u64);
    }
    p.bd_registers(0o27);
    p.stop();
    v.push(("read".to_string(), p));

    // A 4-byte write of page S to blocks 20-23, S+8 cached before and S+16
    // not; then a packed write of page S2 to blocks 30-34.
    let mut p = run(DiskRun {
        pages: vec![S, S2],
        disk_blocks: (20..24).chain(30..35).collect(),
        holds: vec![(S + 8, true), (S + 16, false)],
        ..DiskRun::default()
    });
    p.main.extend(page_words(S));
    p.main.extend(page_words(S2));
    p.read(phys(S + 8), 0o20);
    p.bd_setup(CL, 20, WRITE | FOUR | IE);
    p.write(Word::from(S), phys(CL));
    p.bd_delay(0o26, 40);
    p.bd_start();
    p.bd_delay(0o26, AFTER_WALK);
    p.read(phys(S + 8), 0o20);
    p.bd_wait();
    p.read(phys(S + 8), 0o21).read(phys(S + 16), 0o22).read(phys(S + 24), 0o23);
    p.bd_registers(0o27);
    p.bd_setup(CL + 1, 30, WRITE | IE);
    p.write(Word::from(S2), phys(CL + 1));
    p.bd_delay(0o26, 40);
    p.bd_start();
    p.bd_delay(0o26, AFTER_WALK);
    p.bd_wait();
    p.bd_registers(0o27);
    p.stop();
    v.push(("write".to_string(), p));

    // The pack's last block and the one past it: blocks 59-63 into page T,
    // then 64, past the end, for page O, which stays as it was.  Then an
    // entry whose page is past main memory, and an entry past it, each
    // read after the walk has found it, where muir has it at START.
    let mut p = run(DiskRun { pages: vec![T, O, CL & !0o1777], ..DiskRun::default() });
    p.main.extend(page_words(O));
    p.main.push((CL as usize, Word::from(T) | 1));
    p.main.push((CL as usize + 1, Word::from(O)));
    p.main.push((CL as usize + 2, 0o10000000));
    p.bd_setup(CL, 59, READ | IE);
    p.bd_start();
    // Past DONE at either period, by count: a poll would read the errors,
    // which muir has at START and the fabric at the walk's end.
    p.bd_delay(0o26, PAST_DONE);
    p.bd_registers(0o27);
    p.bd_setup(CL + 2, 10, READ | IE);
    p.bd_start();
    p.bd_delay(0o26, 1000);
    p.bd_registers(0o27);
    p.bd_setup(0o10000000, 11, WRITE | IE);
    p.bd_start();
    p.bd_delay(0o26, 1000);
    p.bd_registers(0o27);
    p.stop();
    v.push(("ends".to_string(), p));

    // RESET-DEVICES while the walk fetches its blocks.
    let mut p = run(DiskRun { pages: vec![T], ..DiskRun::default() });
    p.main.push((CL as usize, Word::from(T)));
    p.bd_setup(CL, 10, READ | IE);
    p.bd_start();
    p.bd_delay(0o26, 100);
    p.write(1, reg(0o104));
    p.read(reg(0o200), 0o27);
    p.bd_delay(0o26, AFTER_WALK);
    p.bd_registers(0o27);
    p.read(phys(T + 100), 0o20);
    p.stop();
    v.push(("reset".to_string(), p));
    v
}

/// **The checkpoint taken while a transfer is in flight**, which the board's
/// writer refuses (A15b.13): a halt shortly after START.
pub fn midckpt() -> super::Case {
    let mut p = run(DiskRun { refuse: true, ..DiskRun::default() });
    p.main.push((CL as usize, Word::from(T)));
    p.bd_setup(CL, 10, READ | IE);
    p.bd_start();
    p.bd_wait();
    p.stop();
    let mut c = p.case("midckpt");
    // The START's grant is near clock 30: halted 60 clocks in, the walk is
    // still fetching its blocks.
    c.script = vec![
        Act::Wait(59),
        Act::Spy(muir::spy::CLK, 0),
        Act::UntilHalted,
        Act::CheckpointEnd,
    ];
    c.micro_check = false;
    c
}

/// **DONE AT THE CLOCK IT FALLS IN, POLLED THERE.**  A 4-byte read of
/// blocks 40-43 into page T, polled until not active from START with `j`
/// fillers before the poll.  DONE is START's instant plus four blocks'
/// 100 us, rounded to the clock once: at P = 17 the first clock at or after
/// it is 47,059 clocks on, where each block rounded on its own gives 47,060,
/// and at P = 36 22,223 against 22,224.  The other runs' polls fall where
/// START does, which the port's timing moves, so whether one of them reads
/// the status in that clock is chance.  Here each filler moves the poll a
/// clock later, the loop's exit moving with it, until the poll a whole loop
/// later is the one that sees not active: the run after that drop polls at
/// DONE's own clock.  That run is chosen on muir, for one bubble and for
/// two, and the trace carries both.
pub fn done_phase(period: u64) -> Vec<super::Case> {
    let program = |j: usize| {
        let mut p = run(DiskRun { pages: vec![T], ..DiskRun::default() });
        p.main.push((CL as usize, Word::from(T)));
        p.bd_setup(CL, 40, READ | FOUR);
        p.bd_start();
        p.fill(j);
        p.bd_wait();
        p.bd_registers(0o27);
        p.stop();
        p
    };
    let mut picked: Vec<usize> = Vec::new();
    for bubbles in [1u8, 2] {
        let mut last: Option<usize> = None;
        let mut found = None;
        for j in 0..32 {
            let clocks = super::run_case(&program(j).case("donephase"), period, bubbles, None)
                .unwrap_or_else(|(_, x)| panic!("donephase: {x}"))
                .lines
                .len();
            if let Some(l) = last {
                if clocks < l {
                    found = Some(j);
                    break;
                }
                assert_eq!(clocks, l + 1, "donephase: a filler moves the poll's exit by one clock, at {j}");
            }
            last = Some(clocks);
        }
        let j = found.expect("donephase: no poll fell at DONE's clock within 32 fillers");
        if !picked.contains(&j) {
            picked.push(j);
        }
    }
    picked.into_iter().map(|j| program(j).case(&format!("donephase-{j}"))).collect()
}

/// A results-only run at the Kria's memory timing but for `timing`.
fn mixed_run(d: DiskRun, timing: Option<PortTiming>) -> Preset {
    let mut p = run(DiskRun { results_only: true, read_at_ar: true, max_clocks: 1_500_000, ..d });
    p.timing = timing;
    p
}

/// At P = 36 (18 ns), the clocks `n` as the port's nanoseconds.
const fn ns36(n: u64) -> u64 {
    n * 18
}

/// **The runs judged by their results.**
pub fn bdmix() -> Vec<(String, Preset)> {
    let mut v = Vec::new();
    let res = |k: u32| RES + k;

    // Fills held 400 clocks: the processor reads T's first sixteen lines in
    // turn while the walk writes them, then again after DONE into the
    // results.
    let mut p = mixed_run(
        DiskRun { pages: vec![T, RES], ..DiskRun::default() },
        Some(PortTiming { read_ns: ns36(400), write_ns: 130, occupancy_ns: 10 }),
    );
    p.main.push((CL as usize, Word::from(T)));
    p.bd_setup(CL, 3, READ | IE);
    p.bd_start();
    for l in 0..16u32 {
        p.read(phys(T + 8 * l + (l & 7)), 0o20);
    }
    p.bd_wait();
    for l in 0..16u32 {
        p.read(phys(T + 8 * l + (l & 7)), 0o20).bd_store(0o20, res(l));
    }
    p.stop();
    v.push(("heldr".to_string(), p));

    // Writes answered 600 clocks after their accept: the entry written just
    // before START, and fills of T while the transfer's writes are queued
    // and in flight.
    let mut p = mixed_run(
        DiskRun { pages: vec![T, 0, RES], ..DiskRun::default() },
        Some(PortTiming { read_ns: 247, write_ns: ns36(600), occupancy_ns: 10 }),
    );
    p.bd_setup(CL, 3, READ | IE);
    p.write(Word::from(T), phys(CL));
    p.bd_start();
    // T's first 32 lines read again and again while the walk writes them,
    // so that a read finds its line's write queued or in flight.
    p.bd_sweeps(0o26, 120, |p| {
        for l in 0..32u32 {
            p.read(phys(T + 8 * l + (l & 7)), 0o20);
        }
    });
    p.bd_wait();
    for l in 0..32u32 {
        p.read(phys(T + 8 * l + (l & 7)), 0o20).bd_store(0o20, res(l));
    }
    p.stop();
    v.push(("slowb".to_string(), p));

    // A second START over blocks the store holds, eight writes of its page
    // queued before it, the queue's accepts 40 clocks apart.
    let mut p = mixed_run(
        DiskRun { pages: vec![T, RES], ..DiskRun::default() },
        Some(PortTiming { read_ns: 247, write_ns: 130, occupancy_ns: ns36(40) }),
    );
    p.main.push((CL as usize, Word::from(T)));
    p.bd_setup(CL, 3, READ | IE);
    p.bd_start();
    p.bd_wait();
    p.bd_setup(CL, 3, READ | IE);
    // The page's first words, which the walk writes first, while these are
    // still queued.
    for k in 0..8u32 {
        p.write(0o7070707070 + Word::from(k), phys(T + k));
    }
    p.bd_start();
    p.bd_wait();
    for k in 0..8u32 {
        p.read(phys(T + k), 0o20).bd_store(0o20, res(k));
    }
    p.stop();
    v.push(("ahead".to_string(), p));

    // The processor writing as fast as the queue takes it, until DONE.
    let mut p = mixed_run(
        DiskRun { pages: vec![T, RES], ..DiskRun::default() },
        Some(PortTiming { read_ns: 247, write_ns: 130, occupancy_ns: ns36(30) }),
    );
    p.main.push((CL as usize, Word::from(T)));
    p.bd_setup(CL, 3, READ | IE);
    p.bd_start();
    {
        let (st, b, x, va) = (p.k(reg(0o200)), p.k(1), p.k(0o4444444444), p.k(phys(res(0))));
        let top = p.at();
        p.op(ALU | SETA | a_src(x) | MD);
        p.op(ALU | SETA | a_src(va) | START_WRITE);
        p.fill(2);
        p.op(ALU | SETA | a_src(st) | START_READ);
        p.fill(1);
        p.op(ALU | muir::isa::asm::AND | SRC_MD | a_src(b) | muir::isa::asm::a_dest(TESTED));
        p.op(jcond(3) | a_src(TESTED) | m_src(M_ZERO) | target(top) | N);
        p.fill(1);
    }
    p.stop();
    v.push(("starve".to_string(), p));

    // A two-page read while the processor reads and writes other pages and
    // reads the pages being read.
    let mut p = mixed_run(DiskRun { pages: vec![T, T + 0o2000, U, RES], ..DiskRun::default() }, None);
    p.main.extend(page_words(U));
    p.main.push((CL as usize, Word::from(T) | 1));
    p.main.push((CL as usize + 1, Word::from(T + 0o2000)));
    for l in 0..8u32 {
        p.read(phys(T + 8 * l), 0o20).read(phys(T + 0o2000 + 64 * l), 0o21);
    }
    p.bd_setup(CL, 3, READ | IE);
    p.bd_start();
    for l in 0..16u32 {
        p.read(phys(U + 64 * l), 0o20).bd_store(0o20, U + 64 * l + 1);
        p.read(phys(if l % 2 == 0 { T } else { T + 0o2000 } + 64 * l), 0o21);
    }
    p.bd_wait();
    for l in 0..12u32 {
        p.read(phys(T + 80 * l), 0o20).bd_store(0o20, res(2 * l));
        p.read(phys(T + 0o2000 + 80 * l), 0o20).bd_store(0o20, res(2 * l + 1));
    }
    p.stop();
    v.push(("mixed".to_string(), p));
    v
}
