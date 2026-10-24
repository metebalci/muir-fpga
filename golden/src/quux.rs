// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! Where QUUX differs from the CADR, as programs in the boot PROM, traced on
//! muir's `rtl` engine on the CADR.
//!
//!     quux --program <name>          the CADR's trace
//!     quux --program <name> --prom   the PROM image
//!
//! MIT's boot PROM reaches QUUX's map and PDL buffer and nothing else of it:
//! it never reads functional source 16, never reads the feature page, never
//! multiplies, never divides and never touches the tick.  So each of QUUX's
//! differences is a short program here, assembled with muir's own
//! `isa::asm`, run from reset in place of the boot PROM, and written in
//! `golden/src/trace.rs`'s columns, which `tb/cadr_machine_tb.cpp` compares
//! row for row against the whole machine built with the same PROM image.
//!
//! **THE CADR'S TRACE HOLDS THE CADR'S SIDE OF EACH DIFFERENCE**: sources
//! 15, 16 and 17 reading all ones, the feature page's read timing out with
//! the Xbus NXM bit, `MAP(MD)<29>` reading 0 and `VMA<24>` reaching no map
//! write, a PDL pointer of ten bits, and ALU functions 42 and 43 being the
//! 74S181's.  A CADR build is held to it by `make check`.  QUUX's own
//! programs are `golden/src/quux15.rs`'s.
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
//! and asserts the values muir's own tests hold on the CADR.  A program
//! that stopped reaching what it is for fails here, before it can make a
//! trace that compares nothing.

mod fused;
mod trace;

use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::*;
use muir::machine::{PROM_WORDS, bus_error};

/// `INTERRUPT-CONTROL`'s `INT.ENABLE`, `<27>`, and its `SEQUENCE.BREAK`,
/// `<26>`.
const INT_ENABLE: u64 = 1 << 27;
pub const SEQUENCE_BREAK: u64 = 1 << 26;

/// The pieces of ten bits a constant is made from: three and two of the
/// word's 32 bits.
const KONST_PARTS: [(u64, u64); 4] = [(0, 10), (10, 10), (20, 10), (30, 2)];

/// A constant of any of the widths the programs write them in.
trait WordValue {
    fn value(self) -> u64;
}
impl WordValue for u64 {
    fn value(self) -> u64 {
        self
    }
}
impl WordValue for u32 {
    fn value(self) -> u64 {
        self as u64
    }
}
impl WordValue for i32 {
    fn value(self) -> u64 {
        u32::try_from(self).expect("a constant is not negative") as u64
    }
}

/// A constant, checked against the word.
fn word_value(v: impl WordValue) -> u64 {
    let v = v.value();
    assert!(v >> 32 == 0, "a constant wider than the word: {v:o}");
    v
}

/// The machine a program runs on: the CADR with `prom` as its boot PROM.
fn machine(prom: &[Insn]) -> muir::machine::Machine {
    let mut m = muir::machine::Machine::new();
    m.load_prom(prom);
    m
}

/// All ones in the word.
const ONES: u64 = 0xffff_ffff;

/// A program being assembled into the PROM, from its first word, control
/// store 0.
struct Prog {
    words: Vec<u64>,
    /// Where [`Prog::park`] put the park, the program's end.
    parked: Option<u64>,
}

/// A functional destination, with the harmless M word 37 written beside it
/// as `isa::asm`'s own destinations do.
fn fdest(d: u64) -> u64 {
    (d << 19) | (0o37 << 14)
}

impl Prog {
    fn new() -> Self {
        Prog { words: Vec::new(), parked: None }
    }

    /// The control store address the next word lands at.
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
    fn konst(&mut self, a: u64, v: impl WordValue) {
        let v = word_value(v);
        for (k, &(pos, w)) in KONST_PARTS.iter().enumerate() {
            let piece = (v >> pos) & ((1 << w) - 1);
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
        self.parked = Some(here);
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
/// And slot 3 of the same region, which is mapped onto the page below the
/// register page.
const VADDR_PAST: u32 = (7 << 13) | (3 << 8);

/// A store of level-1 entry `entry` as QUUX takes it: bits 4:0 in
/// `VMA<31:27>`, bit 5 in `VMA<24>`, `VMA<26>` enabling.
fn level_1_store(entry: u32) -> u64 {
    (((entry & 0o37) << 27) | (1 << 26) | (((entry >> 5) & 1) << 24)) as u64
}

/// A store of a level-2 entry, read and write permitted, on physical page
/// `page`.
fn level_2_store(page: u32) -> u64 {
    ((1 << 25) | (1 << 23) | (1 << 22) | page) as u64
}

/// The register page, the feature page with it, at the last page of the
/// physical space, `17777400` (contract Q13); and the page below it,
/// `17777000`, where nothing answers on QUUX.  On the CADR both are in the
/// Unibus window, Unibus `776000` and `777000`, where nothing answers either
/// and a read times out with the Unibus NXM bit.
const FEATURE_PAGE: u32 = 0o37777;
const BELOW_FEATURE_PAGE: u32 = 0o37776;

/// The words of the feature page the map program reads: 220 is the first of
/// the words kept free for later devices (contract Q13), reserved.
const FEATURE_WORDS: [u32; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 0o10, 0o11, 0o12, 0o13, 0o14, 0o100, 0o377, 0o220];

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
///   40     the word below the register page, `17777000`
///   41     word 0 of the feature page after a write of it
///   42     the word at `17377770`, which nothing answers on either machine
///
/// On the CADR the register page and the page below it are the Unibus
/// window's last two pages, where nothing answers: each read times out with
/// the Unibus NXM bit, and the read at `17377770` with the Xbus one.
fn map_program() -> Prog {
    let mut p = Prog::new();
    let (vaddr, vaddr_past) = (VADDR, VADDR_PAST);
    let region = |r: u32| r << 13;

    // Sources 15, 16, 36 and 17.
    for (k, s) in [0o15u64, 0o16, 0o36, 0o17].iter().enumerate() {
        p.source(*s, RESULT + k as u64);
    }

    // Level-1 entry 41 at index 7, through `VMA<24>`: `MD` names the
    // index, the store's `VMA` the entry.
    p.konst(0o300, vaddr);
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

    // Slot 3 of the same region onto the page below the register page.
    p.konst(0o303, vaddr_past);
    p.konst(0o304, level_2_store(BELOW_FEATURE_PAGE));
    p.to(0o303, MD);
    p.to(0o304, fdest(0o23));
    p.fill(2);

    // `MAP(MD)` of a region nothing stored: index 6.
    p.konst(0o305, region(6));
    p.to(0o305, MD);
    p.fill(1);
    p.source(0o11, RESULT + 5);

    // The feature page, word by word. Each read waits for its word.
    for (k, &w) in FEATURE_WORDS.iter().enumerate() {
        p.konst(0o306, vaddr | w);
        p.read(0o306, RESULT + 0o20 + k as u64);
    }
    // And the page below it, which nothing answers on either machine.
    p.read(0o303, RESULT + 0o40);
    // And the words of page 36777 between the CADR display's registers and
    // its disk's, `17377770`, which are nothing's on either machine: QUUX
    // has neither there (contract Q13).
    p.konst(0o323, (7 << 13) | (4 << 8) | 0o370);
    p.konst(0o324, level_2_store(0o36777));
    p.to(0o323, MD);
    p.to(0o324, fdest(0o23));
    p.fill(2);
    p.read(0o323, RESULT + 0o42);
    // A write of word 0: QUUX's page takes it and keeps nothing, so word 0
    // reads the MACHINE-ID after it; on the CADR the write times out on the
    // Unibus.
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
    p.konst(0o321, region(5));
    p.konst(0o322, level_1_store(0o45) | level_2_store(FEATURE_PAGE));
    p.to(0o321, MD);
    p.to(0o322, fdest(0o23));
    p.fill(2);
    p.source(0o11, RESULT + 0o14);

    p.park();
    p
}

// -------------------------------------------------------------------- tv

/// The CADR display's registers, as a word address in page 36777.
const TV_CONTROL: u32 = 0o360;

/// The first program constant written to the buffer, and the second.
const TV_FIRST: u32 = 0o12345670;
const TV_LAST: u32 = 0o76543210;

/// **THE DISPLAY** --- on QUUX the video controller, in place of the SIMPLE
/// and LISPM TV.
///
/// A region of level 1, entry 2, carries five pages of level 2: the
/// buffer's first page, the page of its last word (`17117777`), the page
/// one past its end (`17120000`), the page past the CADR boards' 32K words
/// (`17100000`), and the page of the display's registers: on the CADR page
/// 36777, the eight at `17377760`; on QUUX the register page, the video
/// controller's mode at word 210 and the seven reserved words after it,
/// `17777610`-`17777617`.  Results, `A[200 + k]`:
///
///   0      word 0 of the buffer after a write of it
///   1      the buffer's last word after a write of it
///   2      the word past the CADR's 32K
///   3      the word one past the buffer
///   4      register 0 after a write of all ones in its low eight bits
///   5-14   registers 0 to 7 after a write of ones to 1 to 7: on QUUX 211
///          to 217 are reserved and read 0
///   15     register 0 after a write of the vertical flag and its interrupt
///
/// On the CADR the registers are page 36777's, at word 360.
fn tv_program() -> Prog {
    let (reg_page, control) = (0o36777, TV_CONTROL);
    let mut p = Prog::new();
    let pages = [(0u32, 0o36000u32), (1, 0o36237), (2, 0o36240), (3, 0o36200), (4, reg_page)];
    let va = |slot: u32, word: u32| (7 << 13) | (slot << 8) | word;
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(2));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    for (slot, page) in pages {
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
    write(&mut p, va(4, control), 0o377);
    read(&mut p, va(4, control), RESULT + 4);
    for r in 1..8u32 {
        write(&mut p, va(4, control + r), 0o177777);
    }
    for r in 0..8u32 {
        read(&mut p, va(4, control + r), RESULT + 5 + r as u64);
    }
    // The vertical flag with its interrupt enable: the CADR's board raises
    // `-XBUS.INTR` and the video controller has neither.
    write(&mut p, va(4, control), 0o30);
    read(&mut p, va(4, control), RESULT + 0o15);
    p.park();
    p
}

fn check_tv(m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize] as u32;
    assert_eq!(m.tv.read_buffer(0), TV_FIRST, "CADR: the buffer's first word");
    assert_eq!(r(0), TV_FIRST, "CADR: the buffer's first word, read back");
    assert_ne!(m.bus_error & bus_error::XBUS_NXM, 0, "CADR: one past the buffer times out");
    assert!(m.interrupt(), "CADR: the board's vertical flag, enabled, interrupts");
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
    p.konst(0o703, INT_ENABLE);
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

fn check_tick(m: &muir::machine::Machine) {
    let reads: Vec<u32> = (0..134 + TICK_CLEARED_READS).map(|k| m.amem[(RESULT + k) as usize] as u32).collect();
    assert!(reads.iter().all(|&w| w == !0), "CADR: source 17 reads all ones");
}

// ---------------------------------------------------------------- clocks

/// Functional destinations 2, 3 and 4: `INTERRUPT-CONTROL`, and 3 and 4,
/// which on QUUX since revision 10, as on the CADR, write only M (contract
/// Q11): Q1's tick control and interval timer are gone.
const DEST_INTCTL: u64 = 2;
const DEST_CLOCKS: u64 = 3;
const DEST_PERIOD: u64 = 4;
/// Destination 3's bits as Q1's tick control had them, its on and its clear,
/// and `<3:2>` its interval timer's: since revision 10 destination 3 writes
/// only M, and these are the words written to it to show that.
const TICK_ON: u32 = 1;
const TICK_CLEAR: u32 = 2;
/// The PDL buffer's push and its pointer, functional destinations 11 and
/// 14: where the timer programs keep what they read.
const DEST_PDL_PUSH: u64 = 0o11;
const DEST_PDL_POINTER: u64 = 0o14;
/// Marks an address for [`Tp`]'s `_at` calls as M memory's, not A's.
const M_ADDR: u64 = 1 << 20;

/// **QUUX's interval timers on the register page** (revision 10, contract
/// Q11): words 110 + 2k and 111 + 2k, timer k's control and status and its
/// period; word 104, `<0>` `RESET-DEVICES`; word 100 `<0>`, `<1>` and `<2>`
/// (contract Q13; `<7>` for timer 2 until revision 11).
const RESET_DEVICES_WORD: u32 = 0o104;
const fn tctl(k: u32) -> u32 {
    0o110 + 2 * k
}
const fn tper(k: u32) -> u32 {
    0o111 + 2 * k
}
/// The control word: `<0>` on, `<1>` the flag (a write with it set clears
/// it), `<2>` the mode, one-shot, `<8>` the interrupt enable.
const T_ON: u32 = 1;
const T_FLAG: u32 = 2;
const T_ONE_SHOT: u32 = 4;
const T_IE: u32 = 1 << 8;

/// A jump on condition 5 to two words on, the word between inhibited when
/// taken: an observation of the interrupt `SINTR` took at the edge before
/// it, two microcycles whichever way it goes.
fn observe(p: &mut Prog) {
    let here = p.at();
    p.i(JUMP | target(here + 2) | PGF_OR_INT | N);
    p.fill(1);
}

/// **A PROGRAM OF THE TIMERS**: the register page mapped at region 7's slot
/// `slot`, the constants in a [`Pool`], and every word read pushed on the PDL
/// buffer from its word 1, so that a loop can read a word many times and the
/// generator still see each value.  `pushes` counts them as they are
/// assembled; every loop's count is fixed, so the log's layout is the
/// program's.
struct Tp {
    c: Pool,
    slot: u32,
    pushes: u64,
}

impl Tp {
    fn new(slot: u32) -> Tp {
        Tp { c: Pool::new(), slot, pushes: 0 }
    }

    fn va(&self, w: u32) -> u32 {
        r7(self.slot, w)
    }

    /// The PDL pointer at 0, and `INTERRUPT-CONTROL<27>`, the interrupt
    /// enabled, so that condition 5 tests every timer's word 100 bit.
    fn start(&mut self, p: &mut Prog) {
        let (zero, int) = (self.c.c(p, 0), self.c.c(p, INT_ENABLE));
        p.to(zero, fdest(DEST_PDL_POINTER));
        p.to(int, fdest(DEST_INTCTL));
    }

    /// Word `w` read and pushed, and an observation.
    fn rd(&mut self, p: &mut Prog, w: u32) {
        let a = self.c.c(p, self.va(w));
        p.to(a, START_READ);
        p.fill(1);
        p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
        self.pushes += 1;
        observe(p);
    }

    /// Word `w` read `n` times, a loop of [`Tp::rd`] counted in `M[6]`.
    fn rdn(&mut self, p: &mut Prog, w: u32, n: u32) {
        let (a, count, one, zero) = (self.c.c(p, self.va(w)), self.c.c(p, n), self.c.c(p, 1), self.c.c(p, 0));
        p.i(ALU | SETA | a_src(count) | m_dest(6));
        let top = p.at();
        p.to(a, START_READ);
        p.fill(1);
        p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
        observe(p);
        p.i(ALU | SUB | CARRY_IN | m_src(6) | a_src(one) | m_dest(6));
        p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(6) | N);
        p.fill(1);
        self.pushes += n as u64;
    }

    fn wr(&mut self, p: &mut Prog, w: u32, v: u32) {
        let va = self.va(w);
        self.c.wr(p, va, v);
    }

    /// The address's word onto the output bus: `M[m]` for `M_ADDR | m`,
    /// else `A[a]`.
    fn out(a: u64) -> u64 {
        if a & M_ADDR != 0 { ALU | SETM | m_src(a & 0o37) } else { ALU | SETA | a_src(a) }
    }

    /// [`Tp::rd`] of the address held at `a` (see [`Tp::out`]).
    fn rd_at(&mut self, p: &mut Prog, a: u64) {
        p.i(Self::out(a) | START_READ);
        p.fill(1);
        p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
        self.pushes += 1;
        observe(p);
    }

    /// [`Tp::rdn`] of the address held at `a`.
    fn rdn_at(&mut self, p: &mut Prog, a: u64, n: u32) {
        let (count, one, zero) = (self.c.c(p, n), self.c.c(p, 1), self.c.c(p, 0));
        p.i(ALU | SETA | a_src(count) | m_dest(6));
        let top = p.at();
        p.i(Self::out(a) | START_READ);
        p.fill(1);
        p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
        observe(p);
        p.i(ALU | SUB | CARRY_IN | m_src(6) | a_src(one) | m_dest(6));
        p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(6) | N);
        p.fill(1);
        self.pushes += n as u64;
    }

    /// A write of `v` at the address held at `a`.
    fn wr_at(&mut self, p: &mut Prog, a: u64, v: u32) {
        let av = self.c.c(p, v);
        p.to(av, MD);
        p.i(Self::out(a) | START_WRITE);
        p.fill(2);
    }

    /// Destination 3, which writes only M, written with `v`.
    fn dest3(&mut self, p: &mut Prog, v: u32) {
        let a = self.c.c(p, v);
        p.to(a, fdest(DEST_CLOCKS));
    }

    /// `n` turns of a loop three microcycles long, counted in `M[5]`.
    fn delay(&mut self, p: &mut Prog, n: u32) {
        let (count, one, zero) = (self.c.c(p, n), self.c.c(p, 1), self.c.c(p, 0));
        p.i(ALU | SETA | a_src(count) | m_dest(5));
        let top = p.at();
        p.i(ALU | SUB | CARRY_IN | m_src(5) | a_src(one) | m_dest(5));
        p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(5) | N);
        p.fill(1);
    }
}

/// **QUUX's interval timers** (revision 10, contract Q11), and the codes Q1
/// had: F1 of the contract.
///
/// On both machines first: destination 4 written, which writes only M on
/// both since revision 10 (`M[37]` read back into `A[202]`), source 17 read
/// into `A[200]`, all ones on both, and source 15 into `A[201]`, QUUX's
/// microsecond clock.  The CADR parks there, its source 16 reading all ones.
///
/// Then QUUX, each word read pushed on the PDL buffer ([`Tp`]), with the
/// interrupt enabled so that the observation after every read tests word
/// 100's bits.  For each timer k, [`timer_section`]: its two words at
/// reset; the period written while it is off; turned on periodic with its
/// interrupt enable and read across rises; cleared; its interrupt enable
/// cleared with it on, word 100 read; a turn-on's mode bit written while it
/// is on, which takes no mode; periods written while it runs, one of 5 and
/// one of 0, which stops it; a period of 1 cleared at every read; turned off;
/// then one-shot: one rise, left up across a wait, cleared, no rise after;
/// restarted by a period written; turned off and on again without the mode
/// bit, periodic.  Then the three at once, [`independence`], with
/// `RESET-DEVICES` written with 0, which does nothing; destination 3
/// writing only M, [`destination_3`]; the reserved words; and the shared
/// edge, [`shared_edge`].
fn clocks_program() -> Prog {
    let mut p = Prog::new();
    let mut t = Tp::new(0);
    // The codes, on both machines.
    let v = t.c.c(&mut p, 0o52525);
    p.to(v, fdest(DEST_PERIOD));
    p.source(0o17, RESULT);
    p.source(0o15, RESULT + 1);
    p.i(ALU | SETM | m_src(0o37) | a_dest(RESULT + 2));
    let ones = t.c.c(&mut p, ONES);
    let guard = p.words.len();
    p.i(0);
    p.fill(1);
    // QUUX, which the CADR's guard jumps over to the park.
    map_region_7(&mut p, &mut t.c, &[FEATURE_PAGE, WAIT_PAGE]);
    t.start(&mut p);
    timer_sections(&mut p, &mut t);
    independence(&mut p, &mut t);
    destination_3(&mut p, &mut t);
    for w in [RESET_DEVICES_WORD, 0o105, 0o106, 0o107, 0o116, 0o117] {
        t.rd(&mut p, w);
    }
    shared_edge(&mut p, &mut t);
    let park = p.at();
    p.park();
    p.words[guard] = JUMP | target(park) | AEQM | a_src(ones) | src(0o16) | N;
    p
}

/// Where [`timer_sections`] keeps the virtual addresses of the timer it is
/// on: `M[10]` its control word, `M[11]` its period.  Its loop counts in
/// `M[7]`.
const TS_CTL: u64 = 10;
const TS_PER: u64 = 11;

/// **Each timer alone, one after the other**, the others off throughout:
/// the section below assembled once and run three times, timer k's two
/// words' addresses in `M[10]` and `M[11]` and moved two words on after
/// each; 159 reads a timer.
fn timer_sections(p: &mut Prog, t: &mut Tp) {
    let (ctl0, per0, two, three, one, zero) =
        (t.c.c(p, t.va(tctl(0))), t.c.c(p, t.va(tper(0))), t.c.c(p, 2), t.c.c(p, 3), t.c.c(p, 1), t.c.c(p, 0));
    p.i(ALU | SETA | a_src(ctl0) | m_dest(TS_CTL));
    p.i(ALU | SETA | a_src(per0) | m_dest(TS_PER));
    p.i(ALU | SETA | a_src(three) | m_dest(7));
    let top = p.at();
    timer_section(p, t);
    p.i(ALU | ADD | m_src(TS_CTL) | a_src(two) | m_dest(TS_CTL));
    p.i(ALU | ADD | m_src(TS_PER) | a_src(two) | m_dest(TS_PER));
    p.i(ALU | SUB | CARRY_IN | m_src(7) | a_src(one) | m_dest(7));
    p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(7) | N);
    p.fill(1);
    // The loop assembled the section once; its reads are three timers'.
    t.pushes += 2 * 159;
}

/// One timer's section, its words' addresses in `M[10]` and `M[11]`.
fn timer_section(p: &mut Prog, t: &mut Tp) {
    let (ctl, per) = (M_ADDR | TS_CTL, M_ADDR | TS_PER);
    let from = t.pushes;
    t.rd_at(p, ctl);
    t.rd_at(p, per);
    // The period written with the timer off: it starts nothing.
    t.wr_at(p, per, 3);
    t.rd_at(p, ctl);
    t.rd_at(p, per);
    // On, periodic, its interrupt enable: rises every 3 us.
    t.wr_at(p, ctl, T_ON | T_IE);
    t.rdn_at(p, ctl, 16);
    t.rd(p, 0o100);
    // A clear, left on.
    t.wr_at(p, ctl, T_ON | T_FLAG | T_IE);
    t.rdn_at(p, ctl, 4);
    // Its interrupt enable cleared, left on: the flag rises in the word and
    // not in word 100.
    t.wr_at(p, ctl, T_ON);
    t.rdn_at(p, ctl, 12);
    t.rdn(p, 0o100, 6);
    // The mode bit in a write that leaves it on: no mode is taken.
    t.wr_at(p, ctl, T_ON | T_ONE_SHOT | T_IE);
    t.rd_at(p, ctl);
    // A period of 5 written while it runs, which starts one from the write.
    t.wr_at(p, per, 5);
    t.rdn_at(p, ctl, 16);
    // A period of 0 written while it runs, which stops it, on.
    t.wr_at(p, per, 0);
    t.rdn_at(p, ctl, 12);
    // A period of 1, cleared at every read.
    t.wr_at(p, per, 1);
    let (clear, count, one, zero) = (t.c.c(p, T_ON | T_FLAG | T_IE), t.c.c(p, 30), t.c.c(p, 1), t.c.c(p, 0));
    p.i(ALU | SETA | a_src(count) | m_dest(6));
    let top = p.at();
    p.to(clear, MD);
    p.i(ALU | SETM | m_src(TS_CTL) | START_WRITE);
    p.fill(2);
    p.i(ALU | SETM | m_src(TS_CTL) | START_READ);
    p.fill(1);
    p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
    observe(p);
    p.i(ALU | SUB | CARRY_IN | m_src(6) | a_src(one) | m_dest(6));
    p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(6) | N);
    p.fill(1);
    t.pushes += 30;
    // Off: the flag down and the interrupt enable taken as 0.
    t.wr_at(p, ctl, 0);
    t.rd_at(p, ctl);
    t.rd_at(p, per);
    t.rd(p, 0o100);
    // One-shot at 2 us: one rise.
    t.wr_at(p, per, 2);
    t.wr_at(p, ctl, T_ON | T_ONE_SHOT | T_IE);
    t.rdn_at(p, ctl, 16);
    // Left up across two periods more.
    t.delay(p, 40);
    t.rd_at(p, ctl);
    t.rd(p, 0o100);
    // Cleared: nothing rises after.
    t.wr_at(p, ctl, T_ON | T_FLAG | T_ONE_SHOT | T_IE);
    t.rdn_at(p, ctl, 16);
    // A period written while it is on starts it again: one rise.
    t.wr_at(p, per, 1);
    t.rdn_at(p, ctl, 12);
    // Off, and on again without the mode bit: periodic.
    t.wr_at(p, ctl, 0);
    t.wr_at(p, ctl, T_ON | T_IE);
    t.rdn_at(p, ctl, 8);
    t.wr_at(p, ctl, 0);
    assert_eq!(t.pushes - from, 159, "clocks: a timer's reads counted");
}

/// **The three at once**: timer 0 periodic at 2 us with its interrupt
/// enable, timer 1 one-shot at 3 us with its, and timer 2 periodic at 5 us
/// without; then writes of timer 1's words alone --- `RESET-DEVICES` written
/// with 0 first, which does nothing --- with every word and word 100 read
/// between.
fn independence(p: &mut Prog, t: &mut Tp) {
    let all = |p: &mut Prog, t: &mut Tp| {
        for w in 0o110..=0o115 {
            t.rd(p, w);
        }
        t.rd(p, 0o100);
    };
    t.wr(p, tper(0), 2);
    t.wr(p, tper(1), 3);
    t.wr(p, tper(2), 5);
    t.wr(p, tctl(0), T_ON | T_IE);
    t.wr(p, tctl(1), T_ON | T_ONE_SHOT | T_IE);
    t.wr(p, tctl(2), T_ON);
    t.rdn(p, 0o100, 8);
    all(p, t);
    t.wr(p, RESET_DEVICES_WORD, 0);
    all(p, t);
    t.wr(p, tctl(1), T_ON | T_FLAG | T_ONE_SHOT | T_IE);
    all(p, t);
    t.wr(p, tper(1), 7);
    all(p, t);
    t.wr(p, tctl(1), 0);
    t.rdn(p, 0o100, 8);
    all(p, t);
    t.wr(p, tctl(0), 0);
    t.wr(p, tctl(2), 0);
    all(p, t);
}

/// **Destination 3 writes only M** (revision 10, contract Q11 as amended):
/// Q1's tick control is gone, and every timer is reached through the page
/// alone.  Timer 0 at 2 us through the page's period, left off one-shot
/// with its interrupt enable clear; destination 3 written with 1, Q1's
/// turn-on, and with 1 and `<3:2>` set, each followed by timer 0's word
/// read four times and `M[37]` read back: off, one-shot, no enable, and M
/// the word written.  Then timer 0 turned on through the page, periodic
/// with its interrupt enable, and read until its flag is up; destination 3
/// written with 3, Q1's clear, at twelve phases, each followed at once by
/// an observation, which takes `SINTR` at the write's own edge, and a read:
/// the flag stays up; then with 0, Q1's turn-off, and with 1, each read:
/// on, its flag up; word 100 read; and turned off through the page.
fn destination_3(p: &mut Prog, t: &mut Tp) {
    let m37 = |p: &mut Prog, t: &mut Tp| {
        p.fill(1);
        p.i(ALU | SETM | m_src(0o37) | fdest(DEST_PDL_PUSH));
        t.pushes += 1;
    };
    t.wr(p, tper(0), 2);
    t.wr(p, tctl(0), T_ON | T_ONE_SHOT);
    t.wr(p, tctl(0), 0);
    t.dest3(p, TICK_ON);
    m37(p, t);
    t.rdn(p, tctl(0), 4);
    t.dest3(p, TICK_ON | T_ONE_SHOT | 8);
    m37(p, t);
    t.rdn(p, tctl(0), 4);
    t.wr(p, tctl(0), T_ON | T_IE);
    t.rdn(p, tctl(0), 12);
    let (clear, count, one, zero) = (t.c.c(p, TICK_ON | TICK_CLEAR), t.c.c(p, 12), t.c.c(p, 1), t.c.c(p, 0));
    let va = t.c.c(p, t.va(tctl(0)));
    p.i(ALU | SETA | a_src(count) | m_dest(6));
    let top = p.at();
    p.to(clear, fdest(DEST_CLOCKS));
    observe(p);
    p.to(va, START_READ);
    p.fill(1);
    p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
    observe(p);
    p.fill(3);
    p.i(ALU | SUB | CARRY_IN | m_src(6) | a_src(one) | m_dest(6));
    p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(6) | N);
    p.fill(1);
    t.pushes += 12;
    t.dest3(p, 0);
    t.rd(p, tctl(0));
    t.dest3(p, TICK_ON);
    t.rd(p, tctl(0));
    t.rd(p, 0o100);
    t.rd(p, tctl(1));
    t.rd(p, tctl(2));
    t.wr(p, tctl(0), 0);
}

/// **THE SHARED EDGE** (the contract's M13): a write or a read of the page
/// whose cycle is taken at the edge ending a destination 3 write, the one
/// microinstruction after the start.  Destination 3 writes only M since
/// revision 10, so at that edge the page's cycle alone moves timer 0.
/// Timer 0 at 100 us:
///
///   - destination 3 with 0, Q1's turn-off, at the edge that takes a write
///     of word 110 with `401`: on after it;
///   - destination 3 with 1, Q1's turn-on, against a write of 0: off after
///     it;
///   - a read of word 110 at the edge of destination 3 with 1, timer 0 off
///     one-shot with its interrupt enable clear: as it was.
///
/// Then at 1 us, its flag up, and into `A[203]` and `A[204]` a mark the
/// observation right after skips when `SINTR` at the shared edge is up:
///
///   - destination 3 with 3, Q1's clear, at the edge that takes a write of
///     `401`: the flag stays in that edge's `SINTR`;
///   - destination 3 with 1: the same.
///
/// And reads, of word 100 and of word 110, whose cycle is taken at the edge
/// of a destination 3 write, with 3 and with 1: the flag up in both.
fn shared_edge(p: &mut Prog, t: &mut Tp) {
    let ctl = t.c.c(p, t.va(tctl(0)));
    let w100 = t.c.c(p, t.va(0o100));
    let (v401, zero, one, three) = (t.c.c(p, T_ON | T_IE), t.c.c(p, 0), t.c.c(p, 1), t.c.c(p, 3));
    t.wr(p, tper(0), 100);
    // A write of word 110 against destination 3 at its edge.
    let pair = |p: &mut Prog, word: u64, d3: u64| {
        p.to(word, MD);
        p.to(ctl, START_WRITE);
        p.to(d3, fdest(DEST_CLOCKS));
        p.fill(2);
    };
    // On first, so that a destination 3 turn-off, were it one, would meet
    // the page's write.
    t.wr(p, tctl(0), T_ON | T_IE);
    pair(p, v401, zero);
    t.rd(p, tctl(0));
    pair(p, zero, one);
    t.rd(p, tctl(0));
    // A read of word 110 whose cycle is taken at the edge of destination 3
    // with 1, Q1's turn-on, timer 0 off one-shot with its interrupt enable
    // clear: as it was.
    t.wr(p, tctl(0), T_ON | T_ONE_SHOT);
    t.wr(p, tctl(0), 0);
    p.to(ctl, START_READ);
    p.to(one, fdest(DEST_CLOCKS));
    p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
    t.pushes += 1;
    observe(p);
    t.wr(p, tctl(0), 0);
    // `SINTR` at the shared edge.
    t.wr(p, tper(0), 1);
    t.wr(p, tctl(0), T_ON | T_IE);
    for (d3, at) in [(three, RESULT + 3), (one, RESULT + 4)] {
        p.i(ALU | SETA | a_src(zero) | a_dest(at));
        t.delay(p, 12);
        p.to(v401, MD);
        p.to(ctl, START_WRITE);
        p.to(d3, fdest(DEST_CLOCKS));
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N);
        p.i(ALU | SETA | a_src(one) | a_dest(at));
        p.fill(2);
    }
    // Reads at the shared edge.
    for word in [w100, ctl] {
        for d3 in [three, one] {
            t.delay(p, 12);
            p.to(word, START_READ);
            p.to(d3, fdest(DEST_CLOCKS));
            p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
            t.pushes += 1;
            observe(p);
        }
    }
    // **A READ TAKEN AT A HELD EDGE**: a read of word 110 with a second
    // start right behind it, a write of the page's word 105, which QUUX
    // holds until the first cycle has gone out, so that the read is taken at
    // an edge that runs no microcycle.  Timer 0 at 1 us, cleared after each
    // read; the loop is 640 ns, sixteen microcycles, which is prime to the
    // period's twenty-five, so over twenty-five turns the rise falls on each
    // edge of the period once, the held edge included.
    let (behind, count, v403) = (t.c.c(p, t.va(0o105)), t.c.c(p, 25), t.c.c(p, T_ON | T_FLAG | T_IE));
    p.i(ALU | SETA | a_src(count) | m_dest(6));
    let top = p.at();
    p.to(ctl, START_READ);
    p.to(behind, START_WRITE);
    p.fill(1);
    p.i(ALU | SETM | SRC_MD | fdest(DEST_PDL_PUSH));
    p.to(v403, MD);
    p.to(ctl, START_WRITE);
    p.fill(3);
    p.i(ALU | SUB | CARRY_IN | m_src(6) | a_src(one) | m_dest(6));
    p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(6) | N);
    p.fill(1);
    t.pushes += 25;
    t.wr(p, tctl(0), 0);
}

fn check_clocks(m: &muir::machine::Machine) {
    assert_eq!(m.amem[(RESULT + 2) as usize], 0o52525, "CADR: destination 4 writes M");
    assert_eq!(m.amem[RESULT as usize] as u32, !0, "CADR: source 17 reads all ones");
    assert_eq!(m.amem[(RESULT + 1) as usize] as u32, !0, "CADR: source 15 reads all ones");
}

// ------------------------------------------------------------ the checks

fn check_map(m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize] as u32;
    // Sources 15, 16, 36, 17: the CADR drives nothing on any of them.
    assert_eq!([r(0), r(1), r(2), r(3)], [!0u32; 4], "CADR: sources 15, 16, 36 and 17");
    // The level-1 entry, five bits on the CADR.
    let entry = 0o01;
    assert_eq!(m.l1_map[7], entry, "CADR: the level-1 entry stored");
    assert_eq!((r(4) >> 24) & 0o77, entry, "CADR: MAP(MD)<29:24>");
    let l2 = ((entry << 5) | 2) as usize;
    assert_eq!(m.l2_map[l2] & 0o77777, FEATURE_PAGE, "CADR: level 2 in the entry's block");
    assert_eq!((r(5) >> 24) & 0o77, 0, "CADR: a region nothing stored");
    // The Xbus NXM of `17377770`, and the Unibus NXM of the feature page's
    // reads.
    assert_ne!(m.bus_error & bus_error::XBUS_NXM, 0, "CADR: the Xbus NXM");
    assert_ne!(m.bus_error & bus_error::UNIBUS_NXM, 0, "CADR: the Unibus NXM of the register page's addresses");
    // The PDL buffer, of ten bits.
    assert_eq!(r(6), 0, "CADR: the pointer after a push from 1777");
    assert_eq!(r(7), 0o13572466, "CADR: the word pushed, read at the pointer");
    assert_eq!(r(0o10), 0o1777, "CADR: the index after a write of 177777");
    assert_eq!(r(0o11), 0o22222222, "CADR: the word at index 12345");
    assert_eq!(r(0o12), 0, "CADR: the pointer after a push from 37777");
    assert_eq!(r(0o13), 0o1777, "CADR: the pointer after a pop from 0");
    // Both levels at once: level 1 takes the entry, level 2 lands in block 0.
    assert_eq!(m.l1_map[5], 0o05, "CADR: level 1 of a store of both");
    assert_eq!((r(0o14) >> 24) & 0o77, 0o05, "CADR: MAP(MD) after a store of both");
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
    let va = r7;
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
/// point at revision 4, settled by muir's `b4efcc8`).  QUUX has no hung
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
    p.konst(0o703, INT_ENABLE);
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

// ------------------------------------------------------- the bus reset

/// The CADR's page of the display's registers and the disk's, `17377400`:
/// the display's at word 360, the disk's four at 374-377.
const DEVICE_PAGE: u32 = 0o36777;
/// The Unibus as the Xbus sees it, `17772000`: the I/O board's KBD CSR,
/// Unibus `764112`, at word 45, and the Chaosnet interface's CSR, `764140`,
/// at word 60.
const UNIBUS_PAGE: u32 = 0o37764;
/// The disk's registers, as words of [`DEVICE_PAGE`].
const DISK_STATUS: u32 = 0o374;
const DISK_CLP: u32 = 0o375;
const DISK_DA: u32 = 0o376;
/// The reads the program makes on each side of the reset: seven, and an
/// eighth, the interface's interrupt status.
const BUSRESET_READS: u64 = 8;
/// The I/O board's KBD CSR and the Chaosnet interface's CSR, as words of
/// [`UNIBUS_PAGE`], and the interface's interrupt status as a word of
/// [`INTERFACE_PAGE`].
const KBD_CSR_WORD: u32 = 0o45;
const CHAOS_CSR_WORD: u32 = 0o60;
const INTERRUPT_STATUS_WORD: u32 = 0o20;
/// The KBD CSR's clock interrupt enable, and the interface's
/// `ENABLE UB INTS` (`busint::interrupt_status`).
const CLOCK_INT_ENABLE: u32 = 1 << 3;
const ENABLE_UB_INTS: u32 = 0o2000;
/// The interface's second interrupt register, `766042`, and a `UB INT`
/// written there by hand with a vector no board on this machine asks with.
const INTERRUPT_CONTROL_2_WORD: u32 = 0o21;
const UB_INT_BY_HAND: u32 = 0o100000 | 0o300;

/// **`PROG.UNIBUS.RESET`, `INTERRUPT-CONTROL<28>`, AND WHAT IT CLEARS**
/// (muir's `Machine::bus_reset`): the interface puts it on the backplane as
/// `-XBUS INIT` and `-UB INIT`, and each board clears what its own reset pin
/// clears --- the display's vertical flag (`Tv::xbus_init`), the disk's
/// command and errors (`Controller::xbus_init`), and the I/O board's interrupt enables,
/// its Chaosnet interface and its serial line (`IoBoard::unibus_init`).
/// muir's `Rtl` does it as the `INTERRUPT-CONTROL` write that raises the bit
/// lands.
///
/// Each device is left with something the reset clears: the disk's command
/// with its done interrupt enabled, the display's vertical flag with its
/// interrupt enabled, and the Chaosnet interface's Clear Transmitter and
/// transmit interrupt enable, at Unibus `764140`.  The I/O board's clock
/// interrupt is enabled too, at the KBD CSR,
/// `764112` --- `CLOCK READY` is up from power-on, no interval having been
/// loaded --- and the bus interface's `ENABLE UB INTS` at `766040`, so that
/// the Unibus interrupt, `UB INT`, is up with the Xbus line when the reset
/// comes and the microcycle that raises the bit takes both down.  Then the
/// bit is raised and lowered, and everything is read again.  In order, each
/// read into `A[200 + k]` and again into `A[200 + n + k]` after the reset,
/// `n` being [`BUSRESET_READS`]:
///
///   0-2   the disk's status, its last memory address and its disk address
///   3     the display's register 0
///   4     the Chaosnet interface's CSR
///   5     the KBD CSR
///   6     the disk's status again, after the others
///   7     the interface's interrupt status, `766040`
///
/// And a second reset with `UB INT` written by hand at `766042`,
/// which the reset does not reach: `766040` read after it, into
/// `A[200 + 2n]`, and again after the bit is written clear.
///
/// Every read is followed by a jump on condition 5, which tests the
/// interrupt all the way, so that `SINTR` moves on rows the testbench
/// compares it on.
fn busreset_program() -> Prog {
    let mut p = Prog::new();
    let va = |slot: u32, w: u32| (7 << 13) | (slot << 8) | w;
    let mut k = 0u64;
    let reads = BUSRESET_READS;
    // The map: level 1 entry 3 at region 7; level 2 slot 0 the devices,
    // slot 1 the register page, slot 2 the Unibus and slot 3 the
    // interface's own registers.
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(3));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    let slots: &[(u32, u32)] = &[(0, DEVICE_PAGE), (1, FEATURE_PAGE), (2, UNIBUS_PAGE), (3, INTERFACE_PAGE)];
    for &(slot, page) in slots {
        p.konst(0o302, va(slot, 0));
        p.konst(0o303, level_2_store(page));
        p.to(0o302, MD);
        p.to(0o303, fdest(0o23));
        p.fill(2);
    }
    let rd = |p: &mut Prog, k: &mut u64, addr: u32| {
        p.konst(0o304, addr);
        p.read(0o304, RESULT + *k);
        *k += 1;
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N);
        p.fill(1);
    };
    let wr = |p: &mut Prog, addr: u32, v: u32| {
        p.konst(0o305, v);
        p.konst(0o304, addr);
        p.to(0o305, MD);
        p.to(0o304, START_WRITE);
        p.fill(2);
    };
    // The Chaosnet interface is on the Unibus, with the I/O board.
    let chaos = va(2, CHAOS_CSR_WORD);
    let fifth = va(2, KBD_CSR_WORD);
    // The disk's registers and the display's register 0.
    let disk = |w: u32| va(0, w);
    let display = va(0, TV_CONTROL);
    // The disk: the done interrupt enabled.
    wr(&mut p, disk(DISK_STATUS), 1 << 11);
    // The display's vertical flag and its interrupt enable.
    wr(&mut p, display, 0o30);
    // The Chaosnet interface: Clear Transmitter, `<8>`, and the transmit
    // interrupt enable, `<5>`.
    wr(&mut p, chaos, (1 << 8) | (1 << 5));
    // The I/O board's clock interrupt, and the interface's enable, which
    // takes the board's request as `UB INT`.
    wr(&mut p, va(2, KBD_CSR_WORD), CLOCK_INT_ENABLE);
    wr(&mut p, va(3, INTERRUPT_STATUS_WORD), ENABLE_UB_INTS);
    let order = vec![disk(DISK_STATUS), disk(DISK_CLP), disk(DISK_DA), display, chaos, fifth,
                     disk(DISK_STATUS), va(3, INTERRUPT_STATUS_WORD)];
    assert_eq!(order.len() as u64, reads, "busreset: the reads a side");
    // The reset: `INTERRUPT-CONTROL<28>` raised, then lowered, the other
    // three bits held at zero.
    let reset = |p: &mut Prog| {
        p.konst(0o306, 1 << 28);
        p.konst(0o307, 0);
        p.to(0o306, fdest(DEST_INTCTL));
        p.fill(4);
        p.to(0o307, fdest(DEST_INTCTL));
        p.fill(2);
    };
    for side in 0..2 {
        for &addr in &order {
            rd(&mut p, &mut k, addr);
        }
        if side == 0 {
            reset(&mut p);
        }
    }
    // **AND A SECOND RESET, WITH `UB INT` WRITTEN BY HAND**, at `766042`
    // with a vector of its own: a bus reset reaches the I/O board and not the
    // interface, so that bit stands through it, and `SINTR` with it, until
    // it is written clear.  Read after the reset, `A[200 + 2n]`, and after
    // the clear, `A[200 + 2n + 1]`.
    wr(&mut p, va(3, INTERRUPT_CONTROL_2_WORD), UB_INT_BY_HAND);
    reset(&mut p);
    rd(&mut p, &mut k, va(3, INTERRUPT_STATUS_WORD));
    wr(&mut p, va(3, INTERRUPT_CONTROL_2_WORD), 0);
    rd(&mut p, &mut k, va(3, INTERRUPT_STATUS_WORD));
    assert_eq!(k, 2 * reads + 2, "busreset: the reads counted");
    p.park();
    p
}

fn check_busreset(m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize] as u32;
    let n = BUSRESET_READS;
    let after = |k: u64| r(n + k);
    // Before: the disk's done interrupt requested, the Chaosnet
    // interface's transmit interrupt enabled.
    assert_ne!(r(0) & (1 << 3), 0, "CADR: the disk's done interrupt, before the reset");
    // After: the command's enable gone and with it the request, the
    // network's enable gone, the disk address standing.
    assert_eq!(after(0) & (1 << 3), 0, "CADR: the disk's done interrupt, after the reset");
    assert_eq!(after(6), after(0), "CADR: the disk's status, read twice after the reset");
    assert!(!m.interrupt(), "CADR: nothing interrupts after the reset: {:o} {:?}", m.interrupt_sources(), m.timers);
    assert_eq!(after(0), r(0) & !(1 << 3), "CADR: the controller's status loses the request alone");
    assert_ne!(r(3) & 0o20, 0, "CADR: the display's vertical flag, before the reset");
    assert_eq!(after(3), r(3) & !0o20, "CADR: the display's vertical flag, after the reset");
    // The Chaosnet interface: its transmit interrupt enable and Transmit
    // Done before, the enable gone after and Transmit Done set again by
    // `-UB INIT`.
    assert_eq!(r(4) & 0o240, 0o240, "CADR: the Chaosnet CSR's enable and Transmit Done, before");
    assert_eq!(after(4) & 0o240, 0o200, "CADR: the Chaosnet CSR, after the reset");
    // The KBD CSR: the clock's enable and `CLOCK READY` before; the
    // enable cleared by `-UB INIT` and `CLOCK READY`, which has no pin on
    // it, standing.
    assert_eq!(r(5) & 0o117, 0o110, "CADR: the KBD CSR's clock enable and CLOCK READY, before");
    assert_eq!(after(5) & 0o117, 0o100, "CADR: the KBD CSR, after the reset");
    // The interface: `UB INT` with the clock's vector before, and after
    // the reset `ENABLE UB INTS` standing --- the bus reset is not the
    // interface's --- and nothing taken.
    assert_eq!(r(7) & 0o103774, 0o102274, "CADR: UB INT, the clock's vector and the enable, before");
    assert_eq!(after(7) & 0o103774, 0o2000, "CADR: the enable alone, after the reset");
    // The second reset: `UB INT` by hand stands through it, and goes when
    // it is written clear.
    assert_eq!(r(2 * n) & 0o103774, 0o102300, "CADR: UB INT by hand, after the second reset");
    assert_eq!(r(2 * n + 1) & 0o103774, 0o2000, "CADR: UB INT written clear");
}

// ------------------------------------------------- a start after a start

/// The words `startstart` seeds and writes, each its own.
fn startstart_word(k: u32) -> u32 {
    0x5C00_0000u32.wrapping_add(k.wrapping_mul(0x0101_0101))
}

/// **A MEMORY START IN THE MICROCYCLE RIGHT AFTER A START** (muir's
/// `9016088`).  `MBUSY.SYNC` is `MEMRQ` registered at the edge that ends the
/// first start, so nothing holds the second on the CADR: the cycle that
/// goes out takes the second start's direction and `VMA<7:0>`, and the first
/// is lost, as the board does (`on_the_board_a_start_right_after_a_start_
/// loses_the_first` in muir's `tests/chip.rs`).  QUUX holds the second start
/// with a `-WAIT` term of its own, `MEMSTART AND MEMOP`, until the first
/// cycle has gone out and ended, and both land
/// (`a_start_right_after_a_start_waits_for_it`).  And **a write carries the
/// `MD` of the microcycle after its start**, on both machines
/// (`chip_and_rtl_write_the_md_of_the_microcycle_after_the_start`).
///
/// Region 7's slot 0 is main memory's page `WAIT_PAGE`.  The CADR runs the
/// two single writes with `MD` loaded one and two microcycles after the
/// start, read back into `A[200]` and `A[201]`; the back-to-back pairs are
/// not traced there (see below).
fn startstart_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    // `A[300]` is `va(0, 0)`, so `A[a]` = `va(0, w)` is two instructions.
    let addr = |p: &mut Prog, a: u64, w: u64| {
        p.i(DISPATCH | DMEM_WRITE | a_src(w));
        p.i(ALU | ADD | src(0) | a_src(0o300) | a_dest(a));
    };
    // Scratch: the address, and the data words.
    const X: u64 = 0o360;
    const D: u64 = 0o370;
    let mut back: Vec<u64> = Vec::new();
    // **NOT THE BOARD'S PROGRAM**, a write and a read back to back: the
    // board loses the write, and muir's `rtl` gets the board's words only by
    // asking its bus interface for a second cycle while the first runs,
    // which its own debug assertion refuses.  The fabric's CADR does not
    // follow it there (its bus audit finds a request at the second's address
    // in the direction the cycle does not name, and the read brings 0), and
    // the reference is not one muir defines, so the CADR runs only the
    // writes below.
    p.konst(D + 4, startstart_word(0o44));
    p.konst(D + 5, startstart_word(0o45));
    // The two single writes, `MD` loaded one microcycle after the start and
    // two: the first writes the new word, the second the old.
    addr(&mut p, X + 2, 0o130);
    addr(&mut p, X + 3, 0o134);
    p.to(D + 4, MD);
    p.to(X + 2, START_WRITE);
    p.to(D + 5, MD);
    p.fill(2);
    p.to(D + 4, MD);
    p.to(X + 3, START_WRITE);
    p.fill(1);
    p.to(D + 5, MD);
    p.fill(2);
    back.push(X + 2);
    back.push(X + 3);
    // Both read back, into `A[200]` on.
    let mut at = RESULT;
    for a in back {
        p.read(a, at);
        at += 1;
    }
    p.park();
    p
}

fn check_startstart(m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize] as u32;
    let w = startstart_word;
    assert_eq!([r(0), r(1)], [w(0o45), w(0o44)], "CADR: MD a microcycle after the start, and two");
}

// ---------------------------------------------------------- the constants

/// **CONSTANTS IN A MEMORY, EACH MADE ONCE**, from `A[400]` up: the timer
/// and fused programs name some fifty words, and made where each is used, as the
/// other programs make theirs, they would not fit the PROM's 1,024.  A value
/// takes as many ten-bit pieces of the dispatch constant as it has, where
/// `Prog::konst` always takes four.
struct Pool {
    at: std::collections::HashMap<u64, u64>,
    next: u64,
}

impl Pool {
    const FIRST: u64 = 0o400;
    const LAST: u64 = 0o677;

    fn new() -> Pool {
        Pool { at: std::collections::HashMap::new(), next: Self::FIRST }
    }

    /// The A address holding `v`, made here the first time it is asked.
    fn c(&mut self, p: &mut Prog, v: impl WordValue) -> u64 {
        let v = word_value(v);
        if let Some(&a) = self.at.get(&v) {
            return a;
        }
        let a = self.next;
        assert!(a <= Self::LAST, "the constant pool is full");
        self.next += 1;
        let parts = KONST_PARTS;
        let n = parts.iter().rposition(|&(pos, _)| v >> pos != 0).map_or(1, |i| i + 1);
        for (k, &(pos, w)) in parts[..n].iter().enumerate() {
            let piece = (v >> pos) & ((1 << w) - 1);
            p.i(DISPATCH | DMEM_WRITE | a_src(piece));
            if k == 0 {
                p.i(ALU | SETM | src(0) | a_dest(a));
            } else {
                p.i(BYTE | DPB | src(0) | a_src(a) | width(w) | rot(pos) | a_dest(a));
            }
        }
        self.at.insert(v, a);
        a
    }

    /// A write of `v` at `va`.
    fn wr(&mut self, p: &mut Prog, va: u32, v: u32) {
        let (av, aa) = (self.c(p, v), self.c(p, va));
        p.to(av, MD);
        p.to(aa, START_WRITE);
        p.fill(2);
    }

}

/// Region 7's virtual address of word `w` of slot `slot`.
fn r7(slot: u32, w: u32) -> u32 {
    (7 << 13) | (slot << 8) | w
}

/// Maps region 7: level 1 entry 3; level 2 slot k onto `pages[k]`.
fn map_region_7(p: &mut Prog, c: &mut Pool, pages: &[u32]) {
    let (a0, a1) = (c.c(p, r7(0, 0)), c.c(p, level_1_store(3)));
    p.to(a0, MD);
    p.to(a1, fdest(0o23));
    p.fill(2);
    for (slot, &page) in pages.iter().enumerate() {
        let (a, v) = (c.c(p, r7(slot as u32, 0)), c.c(p, level_2_store(page)));
        p.to(a, MD);
        p.to(v, fdest(0o23));
        p.fill(2);
    }
}

// ------------------------------------------------------------ the Unibus

/// The bus interface's own registers, `17773000`: Unibus `766000` on, the
/// interrupt status at word 20 and the error status at 22.
const INTERFACE_PAGE: u32 = 0o37766;

/// A Unibus access of [`unibus_program`]: the Unibus address, and the word
/// written, or `None` for a read.
const UNIBUS_ACCESSES: [(u32, Option<u32>); 30] = [
    (0o764112, None),         // KBD CSR
    (0o764112, Some(0)),      // ...written, every enable off
    (0o764100, None),         // KBD LOW
    (0o764102, None),         // KBD HIGH
    (0o764104, None),         // MOUSE Y
    (0o764106, None),         // MOUSE X
    (0o764110, None),         // BEEP, which a read clicks
    (0o764110, Some(0)),      // ...and a write
    (0o764114, None),         // answered, nothing behind it
    (0o764120, None),         // USEC LOW, which latches the count
    (0o764122, None),         // USEC HIGH, the latch
    (0o764120, Some(0)),      // no write is taken: the NXM timer ends it
    (0o764124, None),         // the sixty-cycle clock
    (0o764124, Some(0o100)),  // ...written, the interval timer loaded
    (0o764126, None),         // GPIO
    (0o764126, Some(0)),
    (0o764140, None),         // CHAOS CSR
    (0o764140, Some(0)),      // ...written, every enable off
    (0o764142, None),         // MY ADDRESS
    (0o764142, Some(0o1234)), // a word into the transmit buffer
    (0o764144, None),         // READ BUFFER, on `FCLK^`
    (0o764146, None),         // BIT COUNT
    (0o764154, None),         // answers neither way
    (0o764160, None),         // the 2651's received data
    (0o764162, None),         // its status
    (0o764164, None),         // its mode registers
    (0o764166, None),         // its command register, the pointers back
    (0o764166, Some(0)),      // ...written
    (0o766040, None),         // the interface's interrupt status
    (0o766044, None),         // and its error status
];

/// The passes [`unibus_program`] makes over [`UNIBUS_ACCESSES`], each
/// with its own fillers between the accesses.
const UNIBUS_PASSES: usize = 4;

/// The fillers after access `i` of pass `pass`: zero to four, so that the
/// accesses fall at many phases of the I/O board's clocks.
fn unibus_gap(i: usize, pass: usize) -> usize {
    (i * 3 + pass * 2 + pass * pass) % 5
}

/// The words written: the index into this of each write's.
const UNIBUS_WORDS: [u32; 3] = [0, 0o100, 0o1234];

/// **EVERY REGISTER OF THE I/O BOARD, AND THE INTERFACE'S TWO, OVER THE
/// UNIBUS**, read and written at many phases of the board's clocks: the
/// keyboard and mouse group, which waits two edges of the microsecond clock,
/// the clocks, the Chaosnet interface's registers and buffers, the serial
/// port on its half-microsecond clock, a write nothing takes, and the bus
/// interface's own registers.  The CADR's; QUUX has no Unibus.  Each read's
/// word lands in `A[200 + k]`, in order, the writes taking no slot.
fn unibus_program() -> Prog {
    let mut p = Prog::new();
    let va = |slot: u32, w: u32| (7 << 13) | (slot << 8) | w;
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(3));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    for (slot, page) in [(2u32, UNIBUS_PAGE), (3, INTERFACE_PAGE)] {
        p.konst(0o302, va(slot, 0));
        p.konst(0o303, level_2_store(page));
        p.to(0o302, MD);
        p.to(0o303, fdest(0o23));
        p.fill(2);
    }
    // Each access's virtual address in `A[400 + i]`, and the words written
    // in `A[500 + j]`.
    for (i, &(uaddr, _)) in UNIBUS_ACCESSES.iter().enumerate() {
        let word = (uaddr >> 1) & 0o377;
        let slot = if uaddr >= 0o766000 { 3 } else { 2 };
        p.konst(0o400 + i as u64, va(slot, word));
    }
    for (j, &w) in UNIBUS_WORDS.iter().enumerate() {
        p.konst(0o500 + j as u64, w);
    }
    let mut k = 0u64;
    for pass in 0..UNIBUS_PASSES {
        for (i, &(_, w)) in UNIBUS_ACCESSES.iter().enumerate() {
            let a = 0o400 + i as u64;
            if let Some(w) = w {
                let j = UNIBUS_WORDS.iter().position(|&x| x == w).expect("unibus: a word not in UNIBUS_WORDS");
                p.to(0o500 + j as u64, MD);
                p.to(a, START_WRITE);
                p.fill(2);
            } else {
                p.read(a, RESULT + k);
                k += 1;
            }
            p.fill(unibus_gap(i, pass));
        }
    }
    p.park();
    p
}

fn check_unibus(m: &muir::machine::Machine) {
    let reads = UNIBUS_ACCESSES.iter().filter(|a| a.1.is_none()).count();
    let r = |pass: usize, i: usize| m.amem[(RESULT + (pass * reads + i) as u64) as usize];
    for pass in 0..UNIBUS_PASSES {
        // The KBD CSR reads its floating byte, and the serial port's
        // received data the same, the chip having nothing.
        assert_eq!(r(pass, 0) & 0o177400, 0o177400, "CADR: the KBD CSR's floating byte, pass {pass}");
        assert_eq!(r(pass, 16), 0o177400, "CADR: the 2651's received data, pass {pass}");
    }
    // The Chaosnet CSR's Transmit Done, up from power-on and down after the
    // first word written into the transmit buffer.
    assert_eq!((r(0, 11), r(1, 11)), (0o200, 0), "CADR: the Chaosnet CSR's Transmit Done");
    // The microsecond counter's low half, latched, moving between passes.
    assert!(r(0, 7) < r(1, 7) && r(1, 7) < r(2, 7), "CADR: the microsecond counter's low half moved");
}

// ------------------------------------------------- the fused return

/// The CADR parks the `fused`, `operand` and `prefetch` programs inside
/// these.
const FUSED_ROWS: u64 = 1_350;
const OPERAND_ROWS: u64 = 1_000;
const PREFETCH_ROWS: u64 = 1_250;

/// The microcycles `phases` takes from reset to its park, and the machine
/// there.
fn fused_run(phases: &[fused::Phase]) -> (u64, muir::rtl::Rtl) {
    let b = fused::program(phases);
    let park = *b.marks.last().unwrap();
    let mut e = trace::engine(machine(&b.prog.prom()));
    e.boot();
    for _ in 0..200_000u64 {
        if e.machine().opc as u64 == park {
            // Microcycles, not steps: a step can end inside a wait.
            let n = e.machine().cycles;
            return (n, e);
        }
        e.step().expect("fused: the program runs");
    }
    panic!("fused: the program never reached its park at {park:o}");
}

/// **What the `fused` and `operand` programs reached** (contract H8a §6
/// items 2 to 5).  The trace's own run parked, no stale entry was taken and
/// every phase ended.  On the CADR, whose destinations 5 to 7 write only M,
/// nothing fused.
fn check_fused(e: &muir::rtl::Rtl, phases: Vec<fused::Phase>) {
    let b = fused::program(&phases);
    let park = *b.marks.last().unwrap();
    let m = e.machine();
    assert!((park..=park + 1).contains(&(m.opc as u64)), "fused: the trace ends in the park, OPC {:o}", m.opc);
    let mm = |k: u64| m.mmem[k as usize] as u32;
    let words: std::collections::BTreeMap<&str, u64> = fused::M_WORDS.iter().copied().collect();
    assert_eq!(mm(words["stale entries taken"]), 0, "fused: no stale entry was taken");
    assert_eq!(mm(words["phases ended"]), phases.len() as u32, "fused: every phase ended");
    let (on_cycles, on) = fused_run(&phases);
    let fused = on.machine().macro_dispatch.fused;
    assert_eq!(fused, 0, "CADR: nothing fused");
    eprintln!("quux: nothing fused on the CADR, {on_cycles} microcycles to the park");
}

/// **What the `prefetch` program reached** (contract H8a §3.5, §6 item 10):
/// parked, every phase ended, and on the CADR nothing fused.
fn check_prefetch(e: &muir::rtl::Rtl) {
    let phases = fused::prefetch_phases();
    let b = fused::program(&phases);
    let park = *b.marks.last().unwrap();
    let m = e.machine();
    assert!((park..=park + 1).contains(&(m.opc as u64)), "prefetch: the trace ends in the park, OPC {:o}", m.opc);
    let words: std::collections::BTreeMap<&str, u64> = fused::M_WORDS.iter().copied().collect();
    assert_eq!(m.mmem[words["stale entries taken"] as usize], 0, "prefetch: no stale entry was taken");
    assert_eq!(m.mmem[words["phases ended"] as usize], phases.len() as u64, "prefetch: every phase ended");
    let (on_cycles, on) = fused_run(&phases);
    let fused = on.machine().macro_dispatch.fused;
    assert_eq!(fused, 0, "CADR: nothing fused");
    eprintln!("quux: nothing fused on the CADR, {on_cycles} microcycles to the park");
}

/// **The operand program's pushes** (contract H8a §3.4): PDL-INDEX as each
/// RECORD's first microinstruction and the microcycle after its return find
/// it, and the word at PDL-INDEX that LOAD and TOP push, from the phase's
/// pointer on.  With the operand bit only a fused return into LOCAL or ARG
/// finds its address; every other push finds the sentinel.
fn check_operand(m: &muir::machine::Machine) {
    // The sentinel as PDL-INDEX holds it: ten bits on the CADR.
    let s = fused::PDL_SENTINEL & 0o1777;
    let log = |n: usize, k: usize| -> Vec<u32> {
        (0..k).map(|i| m.pdl[(fused::pdl_pointer(n) + 1 + i as u32) as usize] as u32).collect()
    };
    // The CADR fuses nothing, so every RECORD finds the sentinel.
    let records_off = vec![s; 20];
    assert_eq!(log(0, records_off.len()), records_off, "cadr: the operand bit's pushes");
    assert_eq!(log(1, records_off.len()), records_off, "cadr: the pushes with the operand bit clear");
}

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
        "clocks" => 1600,
        "busreset" => 700,
        "startstart" => 600,
        "unibus" => 3000,
        "fused" => FUSED_ROWS,
        "operand" => OPERAND_ROWS,
        "prefetch" => PREFETCH_ROWS,
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
        "clocks" => clocks_program(),
        "busreset" => busreset_program(),
        "startstart" => startstart_program(),
        "unibus" => unibus_program(),
        "fused" => fused::program(&fused::fused_phases()).prog,
        "operand" => fused::program(&fused::operand_phases()).prog,
        "prefetch" => fused::program(&fused::prefetch_phases()).prog,
        _ => {
            eprintln!("quux: no program `{name}`; the programs are: map, tv, muldiv, tick, divmd, tickwait, clocks, busreset, startstart, unibus, fused, operand, prefetch");
            std::process::exit(2);
        }
    }
}

fn main() {
    let mut name = None;
    let mut prom_only = false;
    let mut it = std::env::args().skip(1);
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
        eprintln!("usage: quux --program <name> [--prom]");
        std::process::exit(2);
    };
    let prom = program(&name).prom();

    if prom_only {
        // The PROM image, as `golden/src/prom.rs` writes MIT's: the words,
        // then zeros to the PROM's end.
        for k in 0..PROM_WORDS {
            println!("{:012x}", prom.get(k).map_or(0, |w| w.raw()));
        }
        return;
    }

    let mut e = trace::engine(machine(&prom));
    e.boot();
    println!("{}", trace::COLUMNS);
    println!("# generated by golden/src/quux.rs from muir's rtl engine: program {name}, machine: cadr");
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
        "map" => check_map(e.machine()),
        "tv" => check_tv(e.machine()),
        "tick" => check_tick(e.machine()),
        "clocks" => check_clocks(e.machine()),
        "busreset" => check_busreset(e.machine()),
        "startstart" => check_startstart(e.machine()),
        "unibus" => check_unibus(e.machine()),
        "fused" => check_fused(&e, fused::fused_phases()),
        "operand" => {
            check_fused(&e, fused::operand_phases());
            check_operand(e.machine());
        }
        "prefetch" => check_prefetch(&e),
        // The CADR's side of these is in the trace alone: what they compute
        // is QUUX's.
        "muldiv" | "divmd" | "tickwait" => {}
        _ => unreachable!(),
    }
    eprintln!(
        "quux: {name} on cadr: {n} microcycles, {} ns ({} stalled), {} bus cycles, PC {:o}",
        e.ns(),
        e.stalled_ns(),
        e.bus_cycles(),
        e.pc()
    );
}
