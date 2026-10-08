// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's memory side, as muir's own programs** (contract G3
//! revision 15, A15b.3, A15b.5, A15b.6; A14.4-A14.8 for the TLB): muir's
//! `tests/revision_15_rtl.rs` written again as runs of
//! `golden/src/quux15.rs`'s kind, each a `Preset` with main memory's
//! words and, where the test has one, muir's seeded memory model.
//!
//!   ports     the port's rows: a hit two clocks after its grant and a miss
//!             its fill later; a register and nothing there; an empty's
//!             sweep; the late squash after a start that faults; a squashed
//!             start; a start right after a map write; the read rule under
//!             the seeded model; word 225 and an error response; a write
//!             carrying `MD` as its start's microcycle left it; the
//!             word after a read start reading the old `MD`; forty writes to
//!             consecutive words, half of them two data beats, under a
//!             model that answers up to 200 clocks late
//!   walk      the TLB and the walk: words read through page tables, a
//!             walk of each depth, the write-back of the accessed and the
//!             modified bits and its refusal, the `WRITE-MAP` operations,
//!             `MAP(MD)` and a map-bit dispatch, and a wrong-path `MAP(MD)`
//!             that evicts nothing; no word right after a start reads the
//!             map (A15b.2's rule)
//!
//! `randmem` and `matrixmem` are `quux15_preset.rs`'s random programs and
//! matrix with their memory starts.  Every run takes -RESET's sweep of the
//! TLB as done, as muir's tests do; `memory`, a program in the PROM, waits
//! for it.

use muir::isa::asm::{
    ALU, HINT, JUMP, LDB, MD, N, P, POPJ, SETA, SETM, SRC_MD, START_READ, START_WRITE,
    a_src, filler, m_dest, m_src, src, target,
};
use muir::machine::Word;
use muir::pipeline::port::LateModel;

use super::quux15_preset::Preset;

/// How many random programs with memory starts `randmem` runs.
pub const RANDOM_MEMORY_SEEDS: u64 = 600;

const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const M_ZERO: u64 = 0o34;
const M_ONE: u64 = 0o35;

/// The register page's virtual address on revisions 14 and 15.
const REGISTER_PAGE: Word = 0o35777777400;

/// The physical memory window: main memory at `VA<27:0>`.
const PHYS: Word = 0o36000000000;

/// The subroutines' addresses, as muir's random programs have them.
const SUBS: [u64; 4] = [0o700, 0o720, 0o740, 0o760];

/// A functional destination, M 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}

/// A BYTE word.
fn byte(func: u64, rotate: u64, len: u64) -> u64 {
    muir::isa::asm::BYTE | func | (len - 1) << 6 | rotate
}

/// A JUMP on condition `code`.
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// A DISPATCH at `IR<23:12>`, no bits of M.
fn disp(addr: u64) -> u64 {
    muir::isa::asm::DISPATCH | addr << 12
}

/// A page entry of status 4, read and write access, the accessed and the
/// modified bits set, at `frame`.
const fn rw_entry(frame: u64) -> Word {
    0b11 << 28 | 0o1460 << 18 | frame
}

/// The same entry without the accessed and modified bits: a reference
/// through it writes them back.
const fn rw_entry_clean(frame: u64) -> Word {
    0o1460 << 18 | frame
}

/// muir's seeded memory model, answering each write 1 to 50 clocks late.
fn late(seed: u64) -> LateModel {
    LateModel { seed, most: 50, errors: 0 }
}

/// A run of the memory side: -RESET's sweep taken as done.
fn run() -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p
}

impl Preset {
    /// M `slot` <- the word at the virtual address `va` (muir's `read`).
    pub(crate) fn read(&mut self, va: Word, slot: u64) -> &mut Self {
        let a = self.k(va);
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.fill(1);
        self.op(ALU | SETM | SRC_MD | m_dest(slot))
    }

    /// The word `word` to the virtual address `va` (muir's `write`).
    pub(crate) fn write(&mut self, word: Word, va: Word) -> &mut Self {
        let (wa, aa) = (self.k(word), self.k(va));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.fill(2)
    }

    /// Word 220, the directory base, at frame 8 (muir's `set_directory`).
    fn set_directory(&mut self) -> &mut Self {
        self.write(8, REGISTER_PAGE | 0o220)
    }

    /// The tables for `va`: its directory entry at frame 8 names the page
    /// table at frame `table`, whose entry for `va` is `entry`.
    fn table(&mut self, va: Word, table: u64, entry: Word) -> &mut Self {
        self.main.push(((8 << 10) + (va >> 20) as usize, rw_entry(table)));
        self.main.push((((table as usize) << 10) + ((va >> 10) & 0o1777) as usize, entry));
        self
    }

    /// A `WRITE-MAP` operation's direct write of `va`'s entry (muir's
    /// `direct_write`).
    fn direct_write(&mut self, va: Word, entry: Word) -> &mut Self {
        let (a, e) = (self.k(va), self.k(1 << 32 | entry));
        self.op(ALU | SETA | a_src(a) | MD);
        self.op(ALU | SETA | a_src(e) | fd(0o23))
    }
}

/// Counts in M `m`.
fn mark(m: u64) -> u64 {
    ALU | muir::isa::asm::ADD | a_src(ONE) | m_src(m) | m_dest(m)
}

/// A start that faults, or not, and its check with N or not, calling a
/// handler that counts in M 26 (muir's `fault_check`).
fn fault_check(write: bool, n: bool, faults: bool) -> Preset {
    let mut p = run();
    let va = p.k(if faults { 0o1000 } else { PHYS | 0o20 });
    if write {
        p.op(ALU | SETM | m_src(M_ONE) | MD);
    }
    p.op(ALU | SETA | a_src(va) | if write { START_WRITE } else { START_READ });
    p.op(jcond(4) | P | target(SUBS[0]) | if n { N } else { 0 });
    p.op(mark(0o21));
    p.op(mark(0o22));
    p.stop();
    p.fill_to(SUBS[0]);
    p.op(mark(0o26));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    p
}

/// **The port's rows** (muir's tests of A15b.3, A15b.5 and A15b.6).
pub fn ports() -> Vec<(String, Preset)> {
    let mut v: Vec<(String, Preset)> = Vec::new();
    // A hit lands two clocks after its grant, a miss its fill later.
    let mut p = run();
    p.read(PHYS | 0o100, 0o20).read(PHYS | 0o101, 0o21).stop();
    v.push(("miss-then-hit".into(), p));
    // A register a clock more than nothing there.
    let mut p = run();
    p.read(REGISTER_PAGE, 0o20).read(PHYS | 0o17777777, 0o21).stop();
    v.push(("register-then-nothing".into(), p));
    // An empty sweeps the TLB one entry a clock: the start after it waits.
    let mut p = run();
    let empty = p.k(3 << 32);
    p.op(ALU | SETA | a_src(empty) | fd(0o23));
    p.fill(1);
    p.read(PHYS | 3, 0o20).stop();
    v.push(("empty-then-start".into(), p));
    // The late squash after a start that faults, and none after one that
    // does not.
    for write in [false, true] {
        for n in [false, true] {
            for faults in [false, true] {
                v.push((
                    format!("fault-check-w{}-n{}-f{}", write as u8, n as u8, faults as u8),
                    fault_check(write, n, faults),
                ));
            }
        }
    }
    // A wrong-path start leaves nothing.
    let mut p = run();
    let (va, word) = (p.k(PHYS | 0o30), p.k(0o4321));
    p.op(ALU | SETA | a_src(word) | MD);
    let to = p.at() + 4;
    p.op(jcond(3) | m_src(M_ONE) | a_src(ZERO) | target(to) | HINT);
    p.fill(1);
    p.stop();
    p.op(ALU | SETA | a_src(va) | START_WRITE);
    p.fill(2);
    p.stop();
    v.push(("squashed-start".into(), p));
    // A start right after a map write translates through the new entry,
    // held a clock; a word later, not held.
    for gap in [0, 1] {
        let mut p = run();
        let x: Word = 0o4000;
        p.main.push(((3 << 10) + 5, 0o777));
        p.direct_write(x, rw_entry(3));
        p.fill(gap);
        let a = p.k(x + 5);
        p.op(ALU | SETA | a_src(a) | START_READ);
        p.fill(2);
        p.op(ALU | SETM | SRC_MD | m_dest(0o26));
        p.stop();
        v.push((format!("map-write-then-start-gap{gap}"), p));
    }
    // The read rule: a write, then a read miss of its line, the word and its
    // neighbour, under the seeded model.
    for seed in 1..=8 {
        let mut p = run();
        p.main.push((0o41, 0o1111));
        p.write(0o5252, PHYS | 0o40);
        p.read(PHYS | 0o40, 0o26);
        p.read(PHYS | 0o41, 0o27);
        p.stop();
        p.late = Some(late(seed));
        v.push((format!("read-rule-seed{seed}"), p));
    }
    // Word 225: an error response counted, read, and cleared by a write.
    for errors in [0, 1] {
        let mut p = run();
        for k in 0..4 {
            p.write(0o100 + k, PHYS | (0o200 + 8 * k));
        }
        p.fill(40);
        p.read(REGISTER_PAGE | 0o225, 0o26);
        p.write(0, REGISTER_PAGE | 0o225);
        p.read(REGISTER_PAGE | 0o225, 0o27);
        p.stop();
        p.late = Some(LateModel { errors, ..late(7) });
        if errors > 0 {
            p.beyond_micro.push((0o26, errors as Word));
        }
        v.push((format!("word-225-errors{errors}"), p));
    }
    // A write carries MD as its start's microcycle leaves it, whatever the
    // next word loads (A15b.3); a start right after it
    // is held and the write carries the MD before it.
    let mut p = run();
    // The word right after a start writes MD: `micro`'s MD-after-start
    // check, under its OA select check, would stop it.
    p.select_check = false;
    let (a, b, v1, v2) = (p.k(PHYS | 0o50), p.k(PHYS | 0o60), p.k(0o1111), p.k(0o2222));
    p.op(ALU | SETA | a_src(v1) | MD);
    p.op(ALU | SETA | a_src(a) | START_WRITE);
    p.op(ALU | SETA | a_src(v2) | MD);
    p.fill(2);
    p.op(ALU | SETA | a_src(v1) | MD);
    p.op(ALU | SETA | a_src(b) | START_WRITE);
    p.op(ALU | SETA | a_src(v2) | fd(0o31));
    p.fill(2);
    p.op(ALU | SETM | SRC_MD | m_dest(0o26));
    p.stop();
    v.push(("write-carries-its-start-s-md".into(), p));
    // The word right after a read start reads MD as the start found it: read,
    // written and through MAP(MD), at gaps 0 to 2, a miss and a hit.
    for hit in [false, true] {
        for gap in 0..3 {
            for k in 0..3 {
                // `MAP(MD)` right after the start breaks A15b.2's rule (no
                // word right after a start reads the map), which revision
                // 15's core relies on: not a program it runs.
                if gap == 0 && k == 2 {
                    continue;
                }
                let mut p = run();
                // MD written right after the start: `micro`'s MD-after-start
                // check, under its OA select check, would stop it.
                p.select_check = !(gap == 0 && k == 1);
                p.main.push((0o40, 5));
                let (two, a) = (p.k(2), p.k(PHYS | 0o40));
                if hit {
                    p.op(ALU | SETA | a_src(a) | START_READ);
                    p.fill(3);
                }
                p.op(ALU | SETA | a_src(two) | MD);
                p.op(ALU | SETA | a_src(a) | START_READ);
                p.fill(gap);
                let nine = p.k(0o11);
                match k {
                    0 => p.op(ALU | SETM | SRC_MD | m_dest(0o26)),
                    1 => p.op(ALU | SETA | a_src(nine) | MD),
                    _ => p.op(ALU | SETM | src(0o11) | m_dest(0o26)),
                };
                p.op(ALU | SETM | SRC_MD | m_dest(0o27));
                p.fill(2);
                p.stop();
                v.push((format!("old-md-hit{}-gap{gap}-use{k}", hit as u8), p));
            }
        }
    }
    // Forty writes to consecutive words, half of them two data beats, under
    // a model that answers up to 200 clocks late, so that the in-flight list
    // fills, the queue behind it, and a write start waits for an entry.
    for seed in 1..=3 {
        let mut p = run();
        for k in 0..40 {
            p.write(0o1000 + k, PHYS | (0o2000 + k));
        }
        p.read(PHYS | 0o2047, 0o26);
        p.stop();
        p.late = Some(LateModel { seed, most: 200, errors: 0 });
        v.push((format!("forty-writes-seed{seed}"), p));
    }
    // The register page's feature words, 0 to 17 (G2 §6.4): constants of
    // the board, each a register's read.
    let mut p = run();
    for k in 0..0o20 {
        p.read(REGISTER_PAGE | k, 0o20 + (k % 8));
    }
    p.stop();
    v.push(("feature-words".into(), p));
    // A register's read right after a register's write, the read held until
    // the write is taken (A15b.3, "a start right after a start"): word 222
    // written and read back, and word 220.
    let mut p = run();
    let (val, at, at2) = (p.k(0o1234), p.k(REGISTER_PAGE | 0o222), p.k(REGISTER_PAGE | 0o220));
    p.op(ALU | SETA | a_src(val) | MD);
    p.op(ALU | SETA | a_src(at) | START_WRITE);
    p.op(ALU | SETA | a_src(at) | START_READ);
    p.fill(1);
    p.op(ALU | SETM | SRC_MD | m_dest(0o20));
    p.op(ALU | SETA | a_src(at2) | START_WRITE);
    p.op(ALU | SETA | a_src(at2) | START_READ);
    p.fill(1);
    p.op(ALU | SETM | SRC_MD | m_dest(0o21));
    p.stop();
    v.push(("register-write-then-read".into(), p));
    // LC's fetch (`step_lc`): LC written with NEEDFETCH, then dispatches that
    // step it, the first fetching the word LC names, the third the next.
    let mut p = run();
    p.main.push((0o100, 0o4444));
    p.main.push((0o101, 0o5555));
    let lcv = p.k((PHYS | 0o100) << 2);
    p.op(ALU | SETA | a_src(lcv) | fd(0o1));
    p.fill(1);
    p.dmem.push((0o40, 1 << 16 | 1 << 15));
    for k in 0..3 {
        p.op(disp(0o40) | 1 << 24);
        p.fill(2);
        p.op(ALU | SETM | SRC_MD | m_dest(0o20 + k));
    }
    p.stop();
    v.push(("lc-fetch".into(), p));
    // Nine writes back to back on lines of their own, answered at once.
    let mut p = run();
    for k in 0..9 {
        p.write(0o300 + k, PHYS | (0o400 + 8 * k));
    }
    for k in 0..9 {
        p.read(PHYS | (0o400 + 8 * k), 0o20 + (k % 8));
    }
    p.stop();
    v.push(("nine-writes".into(), p));
    v
}

/// **The TLB and the walk** (A14.4-A14.8 on revision 15; A15b.3).
pub fn walk() -> Vec<(String, Preset)> {
    let mut v: Vec<(String, Preset)> = Vec::new();
    let x: Word = 0o4000;
    // A word read through the tables: the directory's and the page table's
    // reads, each a miss, then the word's; a second word of the page, the
    // TLB's hit and the cache's; a page of the same table, one table read.
    let mut p = run();
    p.table(x, 9, rw_entry(3));
    p.table(x + 0o2000, 9, rw_entry(4));
    p.main.push(((3 << 10) + 5, 0o777));
    p.main.push(((3 << 10) + 6, 0o666));
    p.main.push(((4 << 10) + 7, 0o555));
    p.set_directory();
    p.read(x + 5, 0o20).read(x + 6, 0o21).read(x + 0o2007, 0o22).read(x + 5, 0o23);
    p.stop();
    v.push(("read-through-tables".into(), p));
    // The write-back: an entry without the accessed bit, read; one without
    // the modified bit, written; the tables read back through the physical
    // window show the bits.
    let mut p = run();
    p.table(x, 9, rw_entry_clean(3));
    p.table(x + 0o2000, 9, 0b01 << 28 | 0o1460 << 18 | 4);
    p.main.push(((3 << 10) + 5, 0o777));
    p.set_directory();
    p.read(x + 5, 0o20);
    p.write(0o4444, x + 0o2006);
    p.write(0o3333, x + 6);
    p.read(PHYS | ((9 << 10) + ((x >> 10) & 0o1777)), 0o21);
    p.read(PHYS | ((9 << 10) + (((x + 0o2000) >> 10) & 0o1777)), 0o22);
    p.read(x + 0o2006, 0o23);
    p.read(PHYS | ((4 << 10) + 6), 0o24);
    p.stop();
    v.push(("write-back".into(), p));
    // The write-back refused: no directory, an entry written directly
    // without the accessed bit; word 224 counts it, a write clears it.
    let mut p = run();
    p.main.push(((3 << 10) + 5, 0o777));
    p.direct_write(x, rw_entry_clean(3));
    p.fill(1);
    p.read(x + 5, 0o20);
    p.read(REGISTER_PAGE | 0o224, 0o21);
    p.write(0, REGISTER_PAGE | 0o224);
    p.read(REGISTER_PAGE | 0o224, 0o22);
    p.stop();
    v.push(("write-back-refused".into(), p));
    // A page entry the tables do not agree with: the write-back refused.
    let mut p = run();
    p.table(x, 9, rw_entry_clean(5));
    p.main.push(((3 << 10) + 5, 0o777));
    p.set_directory();
    p.direct_write(x, rw_entry_clean(3));
    p.fill(1);
    p.read(x + 5, 0o20);
    p.read(REGISTER_PAGE | 0o224, 0o21);
    p.stop();
    v.push(("write-back-frame-differs".into(), p));
    // Walks that find nothing: no directory entry, a directory entry of
    // another status, a page entry of status 0; each start faults.
    let mut p = run();
    p.main.push(((8 << 10) + 1, 2 << 24 | 9));
    p.main.push(((8 << 10) + 2, rw_entry(10)));
    p.set_directory();
    for (k, va) in [x, 1 << 20, 2 << 20].into_iter().enumerate() {
        let a = p.k(va);
        p.op(ALU | SETA | a_src(a) | START_READ);
        p.op(byte(LDB, 0, 40) | m_src(M_ONE) | m_dest(0o20 + k as u64));
        let next = p.at() + 2;
        p.op(jcond(4) | target(next) | N);
        p.op(byte(LDB, 0, 40) | m_src(M_ZERO) | m_dest(0o20 + k as u64));
    }
    p.stop();
    v.push(("walks-find-nothing".into(), p));
    // MAP(MD) of the same addresses: port B's walk finds nothing, the word
    // holds the clock it ends and takes the TLB as it stands in the next,
    // no entry there.
    let mut p = run();
    p.main.push(((8 << 10) + 1, 2 << 24 | 9));
    p.main.push(((8 << 10) + 2, rw_entry(10)));
    p.set_directory();
    for (k, va) in [x, 1 << 20, 2 << 20].into_iter().enumerate() {
        let a = p.k(va);
        p.op(ALU | SETA | a_src(a) | MD);
        p.op(ALU | SETM | src(0o11) | m_dest(0o20 + k as u64));
    }
    p.stop();
    v.push(("map-md-finds-nothing".into(), p));
    // The WRITE-MAP operations: a direct write, MAP(MD) of it at once and
    // after; an invalidation; an empty, and MAP(MD) after it.
    let mut p = run();
    p.table(x, 9, rw_entry(6));
    p.set_directory();
    p.direct_write(x, rw_entry(3));
    p.op(ALU | SETM | src(0o11) | m_dest(0o26));
    p.op(ALU | SETM | src(0o11) | m_dest(0o27));
    let inv = p.k(2 << 32);
    p.op(ALU | SETA | a_src(inv) | fd(0o23));
    p.fill(1);
    p.op(ALU | SETM | src(0o11) | m_dest(0o25));
    p.direct_write(x, rw_entry(3));
    let empty = p.k(3 << 32);
    p.op(ALU | SETA | a_src(empty) | fd(0o23));
    p.fill(1);
    p.op(ALU | SETM | src(0o11) | m_dest(0o24));
    p.stop();
    v.push(("map-operations".into(), p));
    // An entry, the TLB emptied, and the next page's entry made first in
    // its group of 64: the entry before the empty stays gone, and MAP(MD)
    // walks for it.
    let mut p = run();
    let y: Word = x + 0o2000;
    p.table(x, 9, rw_entry(6));
    p.table(y, 9, rw_entry(7));
    p.set_directory();
    p.direct_write(x, rw_entry(3));
    p.fill(1);
    p.op(ALU | SETM | src(0o11) | m_dest(0o24));
    let empty = p.k(3 << 32);
    p.op(ALU | SETA | a_src(empty) | fd(0o23));
    p.fill(1);
    let ya = p.k(y);
    p.op(ALU | SETA | a_src(ya) | MD);
    p.op(ALU | SETM | src(0o11) | m_dest(0o25));
    let xa = p.k(x);
    p.op(ALU | SETA | a_src(xa) | MD);
    p.op(ALU | SETM | src(0o11) | m_dest(0o26));
    p.stop();
    v.push(("empty-then-a-neighbour".into(), p));
    // A map-bit dispatch on a pointer: word 222 makes DTP-LIST one, and X's
    // entry's map bit 1 picks the entry; on a word not a pointer both bits
    // read 1.  Each entry calls a landing that counts and returns.
    let mut p = run();
    const LIST: Word = 0o016 << 32;
    p.table(x, 9, rw_entry(3) & !(1 << 22));
    p.set_directory();
    p.write(1 << 0o16, REGISTER_PAGE | 0o222);
    let landing = 0o400;
    for k in 0..2u64 {
        p.dmem.push((0o40 + k as usize, (landing + 0o10 * k) as u32 | 1 << 15));
    }
    for (k, md) in [LIST | x, x].into_iter().enumerate() {
        let a = p.k(md);
        p.op(ALU | SETA | a_src(a) | MD);
        p.op(disp(0o40) | 1 << 8 | SRC_MD);
        p.fill(1);
        p.op(mark(0o20 + k as u64));
    }
    p.stop();
    for k in 0..2u64 {
        p.fill_to(landing + 0o10 * k);
        p.op(mark(0o24 + k) | POPJ);
        p.fill(1);
    }
    v.push(("map-dispatch".into(), p));
    // **NOT HERE, PORT B RIGHT AFTER A START** (muir's row of A15b.3's `MD`
    // row, `MAP(MD)` or a map-bit dispatch in the word right after a read
    // start, and its walk keeping its address): A15b.2's rule, the
    // micro-assembler's, refuses a word right after a start that reads the
    // map, and revision 15's core relies on it.
    // MAP(MD) in a delay slot N inhibits: its lookup is not made, and the
    // entry written directly at its TLB index stays.
    let mut p = run();
    let y: Word = x + (4096 << 10);
    p.main.push(((3 << 10) + 5, 0o777));
    p.table(y, 9, rw_entry(5));
    p.set_directory();
    p.direct_write(x, rw_entry(3));
    p.fill(1);
    let ya = p.k(y);
    p.op(ALU | SETA | a_src(ya) | MD);
    let t = p.at() + 2;
    p.op(JUMP | 1 << 5 | 7 | target(t) | N);
    p.op(ALU | SETM | src(0o11) | m_dest(0o25));
    let a = p.k(x + 5);
    p.op(ALU | SETA | a_src(a) | START_READ);
    p.fill(2);
    p.op(ALU | SETM | SRC_MD | m_dest(0o26));
    p.stop();
    v.push(("nopped-map-md".into(), p));
    // The ephemeral bit (A14.8): with word 221 set and DTP-LIST a pointer
    // type, a write of a list pointer into the ephemeral space through an
    // entry without the modified bit writes back the modified and the
    // ephemeral bits; a fixnum's write, the modified bit alone.
    let mut p = run();
    p.table(x, 9, 0b01 << 28 | 0o1460 << 18 | 3);
    p.table(x + 0o2000, 9, 0b01 << 28 | 0o1460 << 18 | 4);
    p.set_directory();
    p.write(1, REGISTER_PAGE | 0o221);
    p.write(1 << 0o16, REGISTER_PAGE | 0o222);
    p.write(LIST | 0o15 << 28 | 0o123, x + 5);
    p.write(0o123, x + 0o2005);
    p.read(PHYS | ((9 << 10) + ((x >> 10) & 0o1777)), 0o20);
    p.read(PHYS | ((9 << 10) + (((x + 0o2000) >> 10) & 0o1777)), 0o21);
    p.stop();
    v.push(("ephemeral".into(), p));
    // The PDL buffer redirect outside the buffer (A14.7): a page entry of
    // status 5 that faults a read and a write proceeds as if its access
    // code were 11, through memory.
    let mut p = run();
    p.table(x, 9, 0b11 << 28 | 5 << 24 | 3);
    p.main.push(((3 << 10) + 5, 0o777));
    p.set_directory();
    p.read(x + 5, 0o20);
    p.write(0o1234, x + 6);
    p.read(PHYS | ((3 << 10) + 6), 0o21);
    p.stop();
    v.push(("redirect-outside".into(), p));
    // A wrong-path MAP(MD) evicts nothing.
    let mut p = run();
    let y: Word = x + (4096 << 10);
    p.main.push(((3 << 10) + 5, 0o777));
    p.table(y, 9, rw_entry(5));
    p.set_directory();
    p.direct_write(x, rw_entry(3));
    p.fill(1);
    let ya = p.k(y);
    p.op(ALU | SETA | a_src(ya) | MD);
    let t = p.at() + 8;
    p.op(jcond(3) | m_src(M_ONE) | a_src(ZERO) | target(t) | HINT);
    p.fill(1);
    let a = p.k(x + 5);
    p.op(ALU | SETA | a_src(a) | START_READ);
    p.fill(2);
    p.op(ALU | SETM | SRC_MD | m_dest(0o26));
    p.stop();
    p.fill_to(t);
    p.op(ALU | SETM | src(0o11) | m_dest(0o25));
    p.stop();
    v.push(("wrong-path-map-md".into(), p));
    v
}

#[allow(dead_code)]
fn _uses() {
    let _ = (P, M_ZERO);
}
