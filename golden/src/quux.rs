// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! Where QUUX differs from the CADR, as programs in the boot PROM, traced on
//! muir's `rtl` engine on either machine.
//!
//!     quux --program <name> [--machine cadr|quux]          the trace
//!     quux --program <name> --prom                         the PROM image
//!
//! MIT's boot PROM reaches QUUX's map and PDL buffer and nothing else of it:
//! it never reads functional source 16, never reads the feature page, never
//! multiplies, never divides and never touches the tick.  So each of QUUX's
//! differences is a short program here, assembled with muir's own
//! `isa::asm`, run from reset in place of the boot PROM, and written in
//! `golden/src/trace.rs`'s columns, which `tb/cadr_machine_tb.cpp` compares
//! row for row against the whole machine built with the same PROM image.
//!
//! **THE SAME PROGRAM IS TRACED ON BOTH MACHINES**, and the CADR's trace is
//! the one that holds the CADR's side of each difference: sources 15, 16
//! and 17 reading all ones, the feature page's read timing out with the Xbus
//! NXM bit, `MAP(MD)<29>` reading 0 and `VMA<24>` reaching no map write, a
//! PDL pointer of ten bits, and ALU functions 42 and 43 being the 74S181's.
//! A CADR build is held to it by `make check`, a QUUX build to QUUX's by
//! `make check MACHINE=quux`.
//!
//! **NOTHING IS PRESET.**  muir's own tests (`tests/quux.rs`) put their
//! operands in M memory and their map entries in the arrays before the
//! engine starts; a fabric comes out of reset with nothing in either, so
//! these programs make every constant themselves.  A DISPATCH that writes the
//! dispatch memory (`DMEM_WRITE`) loads the dispatch constant, `IR<41:32>`,
//! which functional source 0 reads back; four of them and three `DPB`s make a
//! word.  Every map entry is stored through `WRITE-MAP`, exactly as microcode
//! does it.
//!
//! **EACH PROGRAM SAYS WHAT IT REACHED.**  At the end of the run the
//! generator reads the machine's own state --- the A memory the program
//! stored its results in, the map, the PDL buffer, the bus error register ---
//! and asserts the values muir's own tests hold, on each machine.  A program
//! that stopped reaching what it is for fails here, before it can make a
//! trace that compares nothing.

mod machine_axis;
mod trace;

use machine_axis::Which;
use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::*;
use muir::machine::{PROM_WORDS, bus_error};

/// A program being assembled into the PROM, from word 0.
struct Prog {
    words: Vec<u64>,
}

/// A functional destination, with the harmless M word 37 written beside it
/// as `isa::asm`'s own destinations do.
fn fdest(d: u64) -> u64 {
    (d << 19) | (0o37 << 14)
}

impl Prog {
    fn new() -> Self {
        Prog { words: Vec::new() }
    }

    fn at(&self) -> u64 {
        self.words.len() as u64
    }

    fn i(&mut self, raw: u64) {
        self.words.push(raw);
    }

    fn fill(&mut self, n: usize) {
        for _ in 0..n {
            self.words.push(filler().raw());
        }
    }

    /// `A[a]` = `v`, made from the dispatch constant: ten bits, ten bits, ten
    /// bits and two, each loaded by a dispatch-memory write and deposited.
    fn konst(&mut self, a: u64, v: u32) {
        let parts = [(0u64, 10u64), (10, 10), (20, 10), (30, 2)];
        for (k, &(pos, w)) in parts.iter().enumerate() {
            let piece = ((v as u64) >> pos) & ((1 << w) - 1);
            self.i(DISPATCH | DMEM_WRITE | a_src(piece));
            if k == 0 {
                self.i(ALU | SETM | src(0) | a_dest(a));
            } else {
                self.i(BYTE | DPB | src(0) | a_src(a) | width(w) | rot(pos) | a_dest(a));
            }
        }
    }

    /// Reads functional source `s` into `A[a]`.
    fn source(&mut self, s: u64, a: u64) {
        self.i(ALU | SETM | src(s) | a_dest(a));
    }

    /// `A[from]` onto the output bus into functional destination `d`.
    fn to(&mut self, from: u64, d: u64) {
        self.i(ALU | SETA | a_src(from) | d);
    }

    /// A read of the virtual address in `A[va]`, its word into `A[a]`.  The
    /// cycle goes out at the master clock that ends the instruction after
    /// the start, so that instruction still sees the old `MD`, and the one
    /// after it hangs for the word.
    fn read(&mut self, va: u64, a: u64) {
        self.to(va, START_READ);
        self.fill(1);
        self.i(ALU | SETM | SRC_MD | a_dest(a));
    }

    /// Stops: a jump to itself, the instruction after it inhibited.
    fn park(&mut self) {
        let here = self.at();
        self.i(JUMP | target(here) | ALWAYS | N);
        self.fill(1);
    }

    fn prom(&self) -> Vec<Insn> {
        assert!(
            self.words.len() <= PROM_WORDS,
            "the program is {} words and the PROM {PROM_WORDS}",
            self.words.len()
        );
        self.words.iter().map(|&w| Insn::new(w)).collect()
    }
}

// ------------------------------------------------------------------ map

/// Where a result lands: `A[RESULT + k]`.
const RESULT: u64 = 0o200;

/// The virtual address the map program reads through: level-1 index 7,
/// level-2 slot 2, word 0.
const VADDR: u32 = (7 << 13) | (2 << 8);
/// And slot 3 of the same region, which is mapped past the feature page.
const VADDR_PAST: u32 = (7 << 13) | (3 << 8);

/// A store of level-1 entry `entry` as QUUX takes it: bits 4:0 in
/// `VMA<31:27>`, bit 5 in `VMA<24>`, `VMA<26>` enabling.
fn level_1_store(entry: u32) -> u32 {
    ((entry & 0o37) << 27) | (1 << 26) | (((entry >> 5) & 1) << 24)
}

/// A store of a level-2 entry, read and write permitted, on physical page
/// `page`.
fn level_2_store(page: u32) -> u32 {
    (1 << 25) | (1 << 23) | (1 << 22) | page
}

/// The feature page, and the page below it where nothing answers.
const FEATURE_PAGE: u32 = 0o36776;
const BELOW_FEATURE_PAGE: u32 = 0o36775;

/// The words of the feature page the map program reads.
const FEATURE_WORDS: [u32; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 0o10, 0o11, 0o12, 0o13, 0o14, 0o100, 0o377, 0o200];

/// **The six-bit map, MACHINE-ID, the feature page and the 16K PDL buffer**
/// --- QUUX revisions 1 and 2, and the three sources the CADR leaves open.
///
/// Results, `A[200 + k]`:
///
///   0-3    sources 15, 16, 36 and 17
///   4      `MAP(MD)` after the level-1 store of entry 41
///   5      `MAP(MD)` with `MD` in a region no store touched
///   6      the PDL pointer after a push from 1777
///   7      the word the push put there, read back at the pointer
///   10     the PDL index after a write of 177777
///   11     the word at index 12345, after 2345 was written second
///   12     the PDL pointer after a push from 37777
///   13     the PDL pointer after a pop from 0
///   14     `MAP(MD)` after a store of both levels, entry 0 then entry 45
///   20-37  the feature page's words, `FEATURE_WORDS`, in order
///   40     the word below the feature page
///   41     word 0 of the feature page after a write of it
///   42     the word at `17377770`, which nothing answers
fn map_program() -> Prog {
    let mut p = Prog::new();

    // Sources 15, 16, 36 and 17.
    for (k, s) in [0o15u64, 0o16, 0o36, 0o17].iter().enumerate() {
        p.source(*s, RESULT + k as u64);
    }

    // Level-1 entry 41 at index 7, through `VMA<24>`: `MD` names the
    // index, the store's `VMA` the entry.
    p.konst(0o300, VADDR);
    p.konst(0o301, level_1_store(0o41));
    p.konst(0o302, level_2_store(FEATURE_PAGE));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    // Level 2 through the entry just stored: block 41 on QUUX, 01 on the
    // CADR, slot 2 either way.
    p.to(0o302, fdest(0o23));
    p.fill(2);
    // `MAP(MD)` for the region: the entry in <29:24> on QUUX, <28:24> with
    // 29 zero on the CADR.
    p.source(0o11, RESULT + 4);

    // Slot 3 of the same region onto the page below the feature page.
    p.konst(0o303, VADDR_PAST);
    p.konst(0o304, level_2_store(BELOW_FEATURE_PAGE));
    p.to(0o303, MD);
    p.to(0o304, fdest(0o23));
    p.fill(2);

    // `MAP(MD)` of a region nothing stored: index 6.
    p.konst(0o305, 6 << 13);
    p.to(0o305, MD);
    p.fill(1);
    p.source(0o11, RESULT + 5);

    // The feature page, word by word. Each read waits for its word.
    for (k, &w) in FEATURE_WORDS.iter().enumerate() {
        p.konst(0o306, VADDR | w);
        p.read(0o306, RESULT + 0o20 + k as u64);
    }
    // And the page below it, which times out on both machines.
    p.read(0o303, RESULT + 0o40);
    // And the words of page 36777 between the display's registers and the
    // disk's, `17377770`, which are nothing's on either machine.
    p.konst(0o323, (7 << 13) | (4 << 8) | 0o370);
    p.konst(0o324, level_2_store(0o36777));
    p.to(0o323, MD);
    p.to(0o324, fdest(0o23));
    p.fill(2);
    p.read(0o323, RESULT + 0o42);
    // A write of word 0: QUUX's page takes it and keeps nothing, so word 0
    // reads the MACHINE-ID after it; on the CADR the write times out.
    p.konst(0o307, 0o7654321);
    p.to(0o307, MD);
    p.to(0o300, START_WRITE);
    p.fill(2);
    p.read(0o300, RESULT + 0o41);

    // The PDL buffer. Pointer to 1777, push the constant, read the pointer
    // back and the word at it.
    p.konst(0o310, 0o1777);
    p.konst(0o311, 0o13572466);
    p.to(0o310, fdest(0o14));
    p.to(0o311, fdest(0o11));
    p.fill(2);
    p.source(0o2, RESULT + 6);
    p.source(0o25, RESULT + 7);
    // The index written with all ones in its low sixteen bits.
    p.konst(0o312, 0o177777);
    p.to(0o312, fdest(0o13));
    p.fill(1);
    p.source(0o3, RESULT + 0o10);
    // Two words at indexes 12345 and 2345, which are one word on the CADR.
    p.konst(0o313, 0o12345);
    p.konst(0o314, 0o2345);
    p.konst(0o315, 0o11111111);
    p.konst(0o316, 0o22222222);
    p.to(0o313, fdest(0o13));
    p.to(0o315, fdest(0o12));
    p.to(0o314, fdest(0o13));
    p.to(0o316, fdest(0o12));
    p.to(0o313, fdest(0o13));
    p.fill(2);
    p.source(0o5, RESULT + 0o11);
    // The wrap at the buffer's own size: a push from 37777.
    p.konst(0o317, 0o37777);
    p.to(0o317, fdest(0o14));
    p.to(0o311, fdest(0o11));
    p.fill(1);
    p.source(0o2, RESULT + 0o12);
    // And a pop from 0.
    p.i(ALU | SETM | src(0o24) | a_dest(0o320));
    p.fill(1);
    p.source(0o2, RESULT + 0o13);

    // A store of both levels at once: level 1 at index 5 takes entry 45,
    // and level 2 is written in block 0, the level-1 bits zero.
    p.konst(0o321, 5 << 13);
    p.konst(0o322, level_1_store(0o45) | level_2_store(FEATURE_PAGE));
    p.to(0o321, MD);
    p.to(0o322, fdest(0o23));
    p.fill(2);
    p.source(0o11, RESULT + 0o14);

    p.park();
    p
}

// -------------------------------------------------------------------- tv

/// The display's registers, as a word address in page 36777.
const TV_CONTROL: u32 = 0o360;

/// The first program constant written to the buffer, and the second.
const TV_FIRST: u32 = 0o12345670;
const TV_LAST: u32 = 0o76543210;

/// **MONO TV** --- QUUX's display in place of the SIMPLE and LISPM TV.
///
/// A region of level 1, entry 2, carries five pages of level 2: the
/// buffer's first page, the page of its last word (`17117777`), the page
/// one past its end (`17120000`), the page past the CADR boards' 32K words
/// (`17100000`), and the page of the display's registers.  Results,
/// `A[200 + k]`:
///
///   0      word 0 of the buffer after a write of it
///   1      the buffer's last word after a write of it
///   2      the word past the CADR's 32K
///   3      the word one past the buffer
///   4      register 0 after a write of all ones in its low eight bits
///   5-13   registers 0 to 7 after a write of ones to 1 to 7: on QUUX 1 to 3
///          and 5 to 7 time out, and 4 answers and reads 0
///   14     register 0 after a write of the vertical flag and its interrupt
fn tv_program() -> Prog {
    let mut p = Prog::new();
    let va = |slot: u32, word: u32| (7 << 13) | (slot << 8) | word;
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(2));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    for (slot, page) in [(0u32, 0o36000u32), (1, 0o36237), (2, 0o36240), (3, 0o36200), (4, 0o36777)] {
        p.konst(0o302, va(slot, 0));
        p.konst(0o303, level_2_store(page));
        p.to(0o302, MD);
        p.to(0o303, fdest(0o23));
        p.fill(2);
    }
    // A write, then a read, of the buffer's first word and of its last.
    let write = |p: &mut Prog, addr: u32, value: u32| {
        p.konst(0o304, value);
        p.konst(0o305, addr);
        p.to(0o304, MD);
        p.to(0o305, START_WRITE);
        p.fill(2);
    };
    let read = |p: &mut Prog, addr: u32, a: u64| {
        p.konst(0o305, addr);
        p.read(0o305, a);
    };
    write(&mut p, va(0, 0), TV_FIRST);
    read(&mut p, va(0, 0), RESULT);
    write(&mut p, va(1, 0o377), TV_LAST);
    read(&mut p, va(1, 0o377), RESULT + 1);
    read(&mut p, va(3, 0), RESULT + 2);
    read(&mut p, va(2, 0), RESULT + 3);
    // The registers.
    write(&mut p, va(4, TV_CONTROL), 0o377);
    read(&mut p, va(4, TV_CONTROL), RESULT + 4);
    for r in 1..8u32 {
        write(&mut p, va(4, TV_CONTROL + r), 0o177777);
    }
    for r in 0..8u32 {
        read(&mut p, va(4, TV_CONTROL + r), RESULT + 5 + r as u64);
    }
    // The vertical flag with its interrupt enable: the CADR's board raises
    // `-XBUS.INTR` and MONO TV has neither.
    write(&mut p, va(4, TV_CONTROL), 0o30);
    read(&mut p, va(4, TV_CONTROL), RESULT + 0o15);
    p.park();
    p
}

fn check_tv(which: Which, m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    assert_eq!(m.tv.read_buffer(0), TV_FIRST, "{which:?}: the buffer's first word");
    assert_eq!(r(0), TV_FIRST, "{which:?}: the buffer's first word, read back");
    assert_ne!(m.bus_error & bus_error::XBUS_NXM, 0, "{which:?}: one past the buffer times out");
    if which == Which::Quux {
        assert_eq!(m.tv.read_buffer(40_959), TV_LAST, "QUUX: the buffer's last word");
        assert_eq!(r(1), TV_LAST, "QUUX: the last word, read back");
        assert_eq!(r(4), 4, "QUUX: register 0 keeps black-on-white alone");
        // Registers 0 and 4 answer, 0 with black-on-white and 4 with zero;
        // 1 to 3 and 5 to 7 are not there, and time out (`tests/mono_tv.rs`).
        assert_eq!(r(5), 4, "QUUX: register 0 reads");
        assert_eq!(r(9), 0, "QUUX: register 4 reads 0 and took no write");
        assert_eq!(m.tv.control_registers(), 0b0001_0001, "QUUX: MONO TV's registers");
        assert_eq!(r(0o15), 0, "QUUX: register 0 after the flag and its enable");
        assert!(!m.interrupt(), "QUUX: MONO TV has no interrupt");
    } else {
        assert!(m.interrupt(), "CADR: the board's vertical flag, enabled, interrupts");
    }
}

// ---------------------------------------------------------------- muldiv

/// ALU functions 42 and 43, `IR<8:3>`: QUUX's `MUL` and `DIV`.
const MUL_CODE: u64 = 0o42 << 3;
const DIV_CODE: u64 = 0o43 << 3;

/// One multiply or divide: the operation, M, A and `Q` before, and the
/// output selector `IR<13:12>` and Q control `IR<1:0>` it is written with,
/// which QUUX ignores and the CADR does not.
struct Op {
    code: u64,
    m: u32,
    a: u32,
    q: u32,
    osel: u64,
    qctl: u64,
    ilong: bool,
    /// `IR<7:5>`, which neither decode looks at.
    ir75: u64,
}

const fn op(code: u64, m: u32, a: u32, q: u32, osel: u64, qctl: u64) -> Op {
    Op { code, m, a, q, osel, qctl, ilong: false, ir75: 0 }
}

/// The operands: signs, zero, the extremes, a zero divisor and an overflow,
/// and every output selector and Q control.
const MULDIV_OPS: [Op; 16] = [
    op(MUL_CODE, 0, 7, 6, 1, 0),
    op(MUL_CODE, 0, 0xffff_fffd, 5, 0, 3),
    op(MUL_CODE, 1, 0x7fff_ffff, 0xffff_ffff, 2, 1),
    op(MUL_CODE, 0x1234_5678, 0x9abc_def0, 0x0fed_cba9, 3, 2),
    op(MUL_CODE, 0xffff_ffff, 0xffff_ffff, 0x8000_0000, 1, 3),
    op(MUL_CODE, 5, 0x8000_0000, 3, 0, 0),
    op(DIV_CODE, 0, 7, 100, 1, 0),
    op(DIV_CODE, 0, 0xffff_fff9, 100, 0, 3),
    op(DIV_CODE, 0xffff_ffff, 7, 0xffff_ff9c, 2, 1),
    op(DIV_CODE, 1, 3, 0, 3, 2),
    op(DIV_CODE, 0, 0, 5, 1, 3),
    op(DIV_CODE, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff, 0, 1),
    op(DIV_CODE, 0x0012_3456, 0x789a_bcde, 0xf012_3456, 1, 0),
    op(DIV_CODE, 0, 0x0001_0000, 0x7fff_ffff, 1, 1),
    Op { ir75: 7, ..op(MUL_CODE, 3, 0xffff_fff0, 0x1234_5678, 1, 0) },
    Op { ir75: 7, ..op(DIV_CODE, 0, 13, 0x0002_0000, 1, 0) },
];

/// **MUL and DIV, and the divider's hold** (revision 3).
///
/// Each operation's M operand is M memory 1, its A operand A memory 301 and
/// `Q` is loaded before it; the output bus goes to `A[200 + 2k]` and `Q` to
/// `A[201 + 2k]`.  Then one `DIV` nopped by the jump before it and one with
/// `ILONG`.  QUUX runs it all at its one rate; the CADR at its boot's extra
/// slow speed.
fn muldiv_program() -> Prog {
    let mut p = Prog::new();
    let run = |p: &mut Prog, o: &Op, result: u64| {
        p.konst(0o300, o.m);
        p.konst(0o301, o.a);
        p.konst(0o302, o.q);
        p.i(ALU | SETA | a_src(0o300) | m_dest(1));
        p.i(ALU | SETA | a_src(0o302) | Q_LOAD);
        let ilong = if o.ilong { 1 << 45 } else { 0 };
        p.i(o.code | (o.ir75 << 5) | (o.osel << 12) | o.qctl | m_src(1) | a_src(0o301) | a_dest(result) | ilong);
        p.i(ALU | SETM | SRC_Q | a_dest(result + 1));
    };
    for (k, o) in MULDIV_OPS.iter().enumerate() {
        run(&mut p, o, RESULT + 2 * k as u64);
    }
    // A `DIV` nopped by the jump before it: no hold and no result.
    let here = p.at();
    p.i(JUMP | target(here + 2) | ALWAYS | N);
    p.i(DIV_CODE | m_src(1) | a_src(0o301) | a_dest(0o270));
    p.fill(1);
    // And one with `ILONG`.
    let long = Op { ilong: true, ..op(DIV_CODE, 0, 7, 100, 1, 0) };
    run(&mut p, &long, 0o272);
    p.park();
    p
}

fn check_muldiv(which: Which, m: &muir::machine::Machine) {
    use muir::muldiv;
    if which != Which::Quux {
        return;
    }
    let r = |k: u64| m.amem[k as usize];
    for (k, o) in MULDIV_OPS.iter().enumerate() {
        let what = if o.code == MUL_CODE { muldiv::Op::Mul } else { muldiv::Op::Div };
        let (ob, q) = muldiv::run(what, o.m, o.a, o.q);
        assert_eq!((r(RESULT + 2 * k as u64), r(RESULT + 2 * k as u64 + 1)), (ob, q),
                   "QUUX: operation {k}");
    }
    let (ob, q) = muldiv::run(muldiv::Op::Div, 0, 7, 100);
    assert_eq!((r(0o272), r(0o273)), (ob, q), "QUUX: the DIV with ILONG");
    assert_eq!(r(0o270), 0, "QUUX: the nopped DIV stored nothing");
}

// ------------------------------------------------------------------ tick

/// The period the tick program runs the tick at, in microseconds: short
/// enough that a few hundred microcycles see several rises.
const TICK_US: u32 = 3;

/// The reads of the cleared segment, each after a clear.
const TICK_CLEARED_READS: u64 = 40;

/// A period whose rises land on QUUX's microcycle boundaries: 300 ticks is
/// twenty of its one rate's 15-tick microcycles.
const TICK_ON_A_BOUNDARY_US: u32 = 3;

/// Jump condition 5, `PAGE.FAULT OR INTERRUPT`, as an internal condition.
const PGF_OR_INT: u64 = (1 << 5) | 5;

/// **The processor's tick** (revision 4).
///
/// Source 17 is read into `A[200 + k]` every microcycle through each phase,
/// and between the reads a jump on condition 5 to the next word, taken or
/// not, puts the interrupt the tick raises on `JCOND`: the period written
/// with the tick off, the tick enabled, running across rises; a clear with
/// the flag up; the interrupt enabled in `INTERRUPT-CONTROL`; a new period
/// written while it runs; and the tick turned off.
fn tick_program() -> Prog {
    let mut p = Prog::new();
    let mut k = 0u64;
    let reads = |p: &mut Prog, k: &mut u64, n: u32| {
        for _ in 0..n {
            p.source(0o17, RESULT + *k);
            *k += 1;
            let here = p.at();
            p.i(JUMP | target(here + 1) | PGF_OR_INT);
        }
    };
    reads(&mut p, &mut k, 2);
    p.konst(0o700, TICK_US);
    p.to(0o700, fdest(4));
    reads(&mut p, &mut k, 2);
    p.konst(0o701, 1);
    p.to(0o701, fdest(3));
    reads(&mut p, &mut k, 24);
    // A clear, the enable kept: the flag is up by now.
    p.konst(0o702, 3);
    p.to(0o702, fdest(3));
    reads(&mut p, &mut k, 6);
    // The interrupt enabled, `INTERRUPT-CONTROL<27>`.
    p.konst(0o703, 1 << 27);
    p.to(0o703, fdest(2));
    reads(&mut p, &mut k, 12);
    // A period of 5 written while it runs: the next rise from now, landing
    // 16 ticks into a microcycle, so a flag read as it stands rather than
    // as it stood at the microcycle's start is seen a microcycle early.
    p.konst(0o705, 5);
    p.to(0o705, fdest(4));
    reads(&mut p, &mut k, 24);
    // A period of 3 written while it runs: the next rise from now, and
    // every rise then on a microcycle's own start --- 300 ticks is twenty of
    // QUUX's 15-tick microcycles --- so a period a tick long or short moves
    // the rise into the microcycle before or after.
    p.konst(0o704, TICK_ON_A_BOUNDARY_US);
    p.to(0o704, fdest(4));
    reads(&mut p, &mut k, 60);
    // A period of 1 cleared at every third microcycle and read two after, so
    // that a read sees a rise only in the fifteen ticks after the clear
    // lands: 100 ticks is six and two-thirds of QUUX's 15-tick microcycles,
    // so the rises walk across those windows, and a count of the period a
    // tick long or short, however it accumulates, moves one in or out.
    p.konst(0o706, 1);
    p.konst(0o707, 3);
    p.to(0o706, fdest(4));
    for _ in 0..TICK_CLEARED_READS {
        p.to(0o707, fdest(3));
        p.fill(1);
        p.source(0o17, RESULT + k);
        k += 1;
    }
    // Turned off.
    p.konst(0o705, 0);
    p.to(0o705, fdest(3));
    reads(&mut p, &mut k, 4);
    p.park();
    p
}

fn check_tick(which: Which, m: &muir::machine::Machine) {
    let reads: Vec<u32> = (0..134 + TICK_CLEARED_READS).map(|k| m.amem[(RESULT + k) as usize]).collect();
    if which == Which::Quux {
        assert!(reads.contains(&3), "QUUX: the flag was seen up while enabled");
        assert!(reads.contains(&2), "QUUX: the flag was seen down while enabled");
        assert_eq!(&reads[..4], &[0, 0, 0, 0], "QUUX: the tick off reads 0");
        assert_eq!(reads[reads.len() - 1], 0, "QUUX: turned off, it reads 0 again");
        assert!(!m.tick.enabled, "QUUX: the tick is off at the end");
        let cleared = &reads[130..130 + TICK_CLEARED_READS as usize];
        let up = cleared.iter().filter(|&&w| w == 3).count();
        assert!(up >= 3 && up < cleared.len() / 2, "QUUX: the cleared segment saw {up} rises");
    } else {
        assert!(reads.iter().all(|&w| w == !0), "CADR: source 17 reads all ones");
    }
}

// ------------------------------------------------------------ the checks

fn check_map(which: Which, m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    let quux = which == Which::Quux;
    let id = which.geometry().machine_id;
    let ones = !0u32;
    // Sources 15, 16, 36, 17: the CADR drives nothing on any of them; QUUX
    // answers its MACHINE-ID on 16 and 36 and its tick on 17, off.
    let want = if quux {
        let id = id.unwrap();
        [ones, id, id, 0]
    } else {
        [ones; 4]
    };
    assert_eq!([r(0), r(1), r(2), r(3)], want, "{which:?}: sources 15, 16, 36 and 17");
    // The level-1 entry, six bits on QUUX and five on the CADR.
    let entry = if quux { 0o41 } else { 0o01 };
    assert_eq!(m.l1_map[7], entry, "{which:?}: the level-1 entry stored");
    assert_eq!((r(4) >> 24) & 0o77, entry, "{which:?}: MAP(MD)<29:24>");
    let l2 = ((entry << 5) | 2) as usize;
    assert_eq!(m.l2_map[l2] & 0o77777, FEATURE_PAGE, "{which:?}: level 2 in the entry's block");
    assert_eq!((r(5) >> 24) & 0o77, 0, "{which:?}: a region nothing stored");
    // The feature page: its words on QUUX, a timeout on the CADR.
    if quux {
        let words: Vec<u32> = (0..FEATURE_WORDS.len()).map(|k| r(0o20 + k as u64)).collect();
        let screen = ((machine_axis::MONO_TV_WIDTH as u32) << 16) | machine_axis::MONO_TV_HEIGHT as u32;
        let want = [
            id.unwrap(),
            6,
            2048,
            16384,
            16384,
            1024,
            2048,
            3,
            1,
            screen,
            (1 << 16) | 40,
            0o17000000,
            0,
            0,
            0,
            0,
        ];
        assert_eq!(words, want, "QUUX: the feature page");
        assert_eq!(r(0o41), id.unwrap(), "QUUX: word 0 after a write of it");
    }
    assert_ne!(m.bus_error & bus_error::XBUS_NXM, 0, "{which:?}: the NXM below the feature page");
    // The PDL buffer.
    let (after_1777, index, wrap, pop) =
        if quux { (0o2000, 0o37777, 0, 0o37777) } else { (0, 0o1777, 0, 0o1777) };
    assert_eq!(r(6), after_1777, "{which:?}: the pointer after a push from 1777");
    assert_eq!(r(7), 0o13572466, "{which:?}: the word pushed, read at the pointer");
    assert_eq!(r(0o10), index, "{which:?}: the index after a write of 177777");
    let at_12345 = if quux { 0o11111111 } else { 0o22222222 };
    assert_eq!(r(0o11), at_12345, "{which:?}: the word at index 12345");
    assert_eq!(r(0o12), wrap, "{which:?}: the pointer after a push from 37777");
    assert_eq!(r(0o13), pop, "{which:?}: the pointer after a pop from 0");
    // Both levels at once: level 1 takes the entry, level 2 lands in block 0.
    let both_entry = if quux { 0o45 } else { 0o05 };
    assert_eq!(m.l1_map[5], both_entry, "{which:?}: level 1 of a store of both");
    assert_eq!((r(0o14) >> 24) & 0o77, both_entry, "{which:?}: MAP(MD) after a store of both");
}

// ------------------------------------------------------ waiting for MD

/// The main-memory page the next two programs read, through level-1 entry 2
/// of region 7 and level-2 slot 0; and the word they read.
const WAIT_PAGE: u32 = 0o100;
const WAIT_WORD: u32 = 5;
/// What `MD` holds before each read, so that a microcycle reading the old
/// word and one reading the word read differ.
const MD_BEFORE_READ: u32 = 0o1234;

/// Maps region 7's slot 0 onto `WAIT_PAGE`, read and write permitted, and
/// writes `word` there at `WAIT_WORD`.  `A[305]` holds the virtual address.
fn wait_setup(p: &mut Prog, word: u32) {
    let va = |slot: u32, w: u32| (7 << 13) | (slot << 8) | w;
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(2));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    p.konst(0o303, level_2_store(WAIT_PAGE));
    p.to(0o300, MD);
    p.to(0o303, fdest(0o23));
    p.fill(2);
    p.konst(0o304, word);
    p.konst(0o305, va(0, WAIT_WORD));
    p.to(0o304, MD);
    p.to(0o305, START_WRITE);
    p.fill(2);
}

/// The dividend's high word, which the read brings into `MD`, the divisor
/// and the low word.
const DIVMD_M: u32 = 0x0012_3456;
const DIVMD_A: u32 = 0x0000_7777;
const DIVMD_Q: u32 = 0x89ab_cdef;
/// The fillers between the read's start and the `DIV`, each with and
/// without `ILONG`.
const DIVMD_GAPS: [usize; 4] = [0, 1, 2, 3];

/// **A `DIV` whose M source is `MD`, with a read in flight** (QUUX's open
/// point at revision 4, settled by muir's `ffbb76a`).  QUUX has no hung
/// microcycle: a microcycle reading `MD` with a read in flight waits, and
/// runs once, whole, with the word read in `MD`, so a `DIV` then divides
/// the word read.  The divider's own hold counts from the edge that loaded
/// `IR`, as always.  Each trial loads `Q`, puts `MD_BEFORE_READ` in `MD`,
/// starts a read of `DIVMD_M`, and after `gap` fillers divides `MD` by
/// `A[306]`; the output bus goes to `A[200 + 2k]` and `Q` to `A[201 + 2k]`.
/// Every one divides the word read: with no filler the `DIV` is the
/// instruction after the start and the read goes out while the divider holds
/// it, and from one filler on the read is out when it starts; either way it
/// then waits for the word, whole microcycles, and runs once.
fn divmd_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, DIVMD_M);
    p.konst(0o306, DIVMD_A);
    p.konst(0o307, DIVMD_Q);
    p.konst(0o310, MD_BEFORE_READ);
    let mut k = 0u64;
    for &gap in &DIVMD_GAPS {
        for ilong in [0u64, 1 << 45] {
            p.i(ALU | SETA | a_src(0o307) | Q_LOAD);
            p.to(0o310, MD);
            p.to(0o305, START_READ);
            p.fill(gap);
            p.i(DIV_CODE | SRC_MD | a_src(0o306) | a_dest(RESULT + 2 * k) | ilong);
            p.i(ALU | SETM | SRC_Q | a_dest(RESULT + 2 * k + 1));
            k += 1;
        }
    }
    p.park();
    p
}

fn check_divmd(which: Which, m: &muir::machine::Machine) {
    use muir::muldiv;
    if which != Which::Quux {
        return;
    }
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    let mut k = 0u64;
    for &gap in &DIVMD_GAPS {
        for _ in 0..2 {
            let want = muldiv::run(muldiv::Op::Div, DIVMD_M, DIVMD_A, DIVMD_Q);
            assert_eq!((r(2 * k), r(2 * k + 1)), want, "QUUX: DIV {k}, gap {gap}, divides the word read");
            k += 1;
        }
    }
}

/// The tick's periods, in microseconds, and the fillers between the period
/// written and the read's start, which slide the rise across the microcycle
/// that waits for the word.
const TICKWAIT_US: [u32; 2] = [1, 2];
const TICKWAIT_FILL: usize = 12;

/// **The tick's flag, taken into the interrupt while a microcycle waits for
/// `MD`** (QUUX's second open point at revision 4).  muir takes `SINTR` at
/// the end of `Rtl::clock_edge` from `Machine::interrupt`, at `Machine::ns`,
/// which a step sets to its own start and a bus event it carries moves to
/// the event.  Under this generator's tick-bounded steps (`trace.rs`) every
/// generator cycle the microcycle waits is a step of its own, so the flag it
/// passes on is the flag at the master clock edge it finally runs from: a
/// rise while it waits is taken, and one in the cycle it runs is not.  That
/// is the fabric's `tk_flag_s`, taken at every held master clock edge.  The
/// interrupt is enabled; each trial clears the flag, writes the period, which
/// starts one, and after `f` fillers reads, waits for the word, and jumps on
/// condition 5 to the next word, which puts the interrupt the waiting
/// microcycle passed on in `JCOND`.  Measured on muir: the rises fall before
/// the wait, inside it and in the cycle it runs, all three.
///
/// **muir's own whole step gives another answer**: `Rtl::step` carries the
/// wait inside one step, and `Machine::ns` is then the read's answer, 60 ns
/// before its acknowledgment, so a rise between that answer and the last
/// held edge is not taken.  Which one QUUX means is muir's to say.
fn tickwait_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    p.konst(0o700, 1);
    p.to(0o700, fdest(3));
    p.konst(0o703, 1 << 27);
    p.to(0o703, fdest(2));
    p.konst(0o702, 3);
    for (j, &us) in TICKWAIT_US.iter().enumerate() {
        p.konst(0o704 + j as u64, us);
    }
    for j in 0..TICKWAIT_US.len() {
        for f in 0..TICKWAIT_FILL {
            p.to(0o702, fdest(3));
            p.to(0o704 + j as u64, fdest(4));
            p.fill(f);
            p.to(0o305, START_READ);
            p.fill(1);
            p.i(ALU | SETM | SRC_MD | a_dest(0o720));
            let here = p.at();
            p.i(JUMP | target(here + 1) | PGF_OR_INT);
        }
    }
    p.to(0o702, fdest(3));
    p.konst(0o705, 0);
    p.to(0o705, fdest(3));
    p.park();
    p
}

fn check_tickwait(which: Which, m: &muir::machine::Machine) {
    if which == Which::Quux {
        assert!(!m.tick.enabled, "QUUX: the tick is off at the end");
        assert_eq!(m.amem[0o720], 0o777, "QUUX: the word read");
    }
}

// ------------------------------------------------------------------- main

/// How many microcycles each program's trace runs: to its end and some way
/// round the loop it parks in.
fn cycles(name: &str) -> u64 {
    match name {
        "map" => 450,
        "tv" => 560,
        "muldiv" => 540,
        "tick" => 1350,
        "divmd" => 900,
        "tickwait" => 2600,
        _ => unreachable!(),
    }
}

fn program(name: &str) -> Prog {
    match name {
        "map" => map_program(),
        "tv" => tv_program(),
        "muldiv" => muldiv_program(),
        "tick" => tick_program(),
        "divmd" => divmd_program(),
        "tickwait" => tickwait_program(),
        _ => {
            eprintln!("quux: no program `{name}`; the programs are: map, tv, muldiv, tick, divmd, tickwait");
            std::process::exit(2);
        }
    }
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let mut name = None;
    let mut prom_only = false;
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--program" => name = it.next(),
            "--prom" => prom_only = true,
            _ => {
                eprintln!("quux: unknown argument `{a}`");
                std::process::exit(2);
            }
        }
    }
    let Some(name) = name else {
        eprintln!("usage: quux --program <name> [--machine cadr|quux] [--prom]");
        std::process::exit(2);
    };
    let prog = program(&name);
    let prom = prog.prom();

    if prom_only {
        // The PROM image, as `golden/src/prom.rs` writes MIT's: the words,
        // then zeros to the PROM's end.
        for k in 0..PROM_WORDS {
            println!("{:012x}", prom.get(k).map_or(0, |w| w.raw()));
        }
        return;
    }

    let mut e = trace::engine(which.machine(&prom));
    e.boot();
    println!("{}", trace::COLUMNS);
    println!(
        "# generated by golden/src/quux.rs from muir's rtl engine: program {name}, machine: {}",
        which.name()
    );
    println!("{}", trace::RADIX);
    let n = cycles(&name);
    let mut t = trace::Trace::new(&e);
    for cycle in 0..n {
        match t.row(&mut e, cycle) {
            Ok(line) => println!("{line}"),
            Err(h) => {
                eprintln!("quux: {name} stopped at microcycle {cycle}: {h:?}");
                std::process::exit(1);
            }
        }
    }
    match name.as_str() {
        "map" => check_map(which, e.machine()),
        "tv" => check_tv(which, e.machine()),
        "muldiv" => check_muldiv(which, e.machine()),
        "tick" => check_tick(which, e.machine()),
        "divmd" => check_divmd(which, e.machine()),
        "tickwait" => check_tickwait(which, e.machine()),
        _ => unreachable!(),
    }
    eprintln!(
        "quux: {name} on {}: {n} microcycles, {} ns ({} stalled), {} bus cycles, PC {:o}",
        which.name(),
        e.ns(),
        e.stalled_ns(),
        e.bus_cycles(),
        e.pc()
    );
}
