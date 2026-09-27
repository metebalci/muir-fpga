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
use muir::quux_input::KeyboardMouse;

/// **WHERE THE PROM SITS IN THE CONTROL STORE**, which is where a program is
/// assembled: MIT's overlay at 0 on the CADR, and on QUUX its own addresses
/// from 36000 (revision 6, contract Q2; `Machine::reset_pc`).  Every jump a
/// program makes is to an absolute address, so the same program is two
/// images, one a machine; `main` sets this before anything is assembled.
static BASE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn prom_base(which: Which) -> u64 {
    match which {
        Which::Cadr => 0,
        Which::Quux => muir::machine::QUUX_PROM_BASE as u64,
    }
}

/// A program being assembled into the PROM, from its first word, which is
/// control store [`BASE`].
struct Prog {
    base: u64,
    words: Vec<u64>,
}

/// A functional destination, with the harmless M word 37 written beside it
/// as `isa::asm`'s own destinations do.
fn fdest(d: u64) -> u64 {
    (d << 19) | (0o37 << 14)
}

impl Prog {
    fn new() -> Self {
        Prog { base: BASE.load(std::sync::atomic::Ordering::Relaxed), words: Vec::new() }
    }

    /// The control store address the next word lands at.
    fn at(&self) -> u64 {
        self.base + self.words.len() as u64
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

/// **The same on QUUX's synchronous microcycle, `ticksync`**: a read a
/// clear and a filler after it is three microcycles, twelve ticks at a K of
/// four and nine at three, so a rise a microsecond apart falls in the one
/// filler's window about one time in three, and forty reads see one or none.
/// A hundred and twenty see several at either K.  `tick` itself is the
/// CADR's side and QUUX's at the CADR's microcycle, and is left as it is so
/// that the CADR's trace does not move.
const TICKSYNC_CLEARED_READS: u64 = 120;

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
    tick_program_with(TICK_CLEARED_READS)
}

fn tick_program_with(cleared_reads: u64) -> Prog {
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
    for _ in 0..cleared_reads {
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

fn check_tick(which: Which, m: &muir::machine::Machine, cleared_reads: u64) {
    let reads: Vec<u32> = (0..134 + cleared_reads).map(|k| m.amem[(RESULT + k) as usize]).collect();
    if which == Which::Quux {
        assert!(reads.contains(&3), "QUUX: the flag was seen up while enabled");
        assert!(reads.contains(&2), "QUUX: the flag was seen down while enabled");
        assert_eq!(&reads[..4], &[0, 0, 0, 0], "QUUX: the tick off reads 0");
        assert_eq!(reads[reads.len() - 1], 0, "QUUX: turned off, it reads 0 again");
        assert!(!m.timers.timer[0].on, "QUUX: the tick, timer 0, is off at the end");
        let cleared = &reads[130..130 + cleared_reads as usize];
        let up = cleared.iter().filter(|&&w| w == 3).count();
        assert!(up >= 3 && up < cleared.len() / 2, "QUUX: the cleared segment saw {up} rises");
    } else {
        assert!(reads.iter().all(|&w| w == !0), "CADR: source 17 reads all ones");
    }
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
/// Where the microsecond clock's reads land, over and over.
const USEC_AT: u64 = 0o710;

/// **QUUX's interval timers on the register page** (revision 10, contract
/// Q11): words 110 + 2k and 111 + 2k, timer k's control and status and its
/// period; word 104, `<0>` `RESET-DEVICES`; word 100 `<0>`, `<1>` and `<7>`.
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
/// Word 100's bit for each timer.
const T_BIT: [u32; 3] = [1, 2, 1 << 7];

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
        let (zero, int) = (self.c.c(p, 0), self.c.c(p, 1 << 27));
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

/// The log a timer program left: the PDL buffer from word 1, `n` words.
fn pdl_log(m: &muir::machine::Machine, n: u64) -> Vec<u32> {
    (1..=n).map(|i| m.pdl[i as usize]).collect()
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
    clocks_program_layout().0
}

/// The program, and where each part's reads sit in the log: a name, the
/// first push, and how many.
fn clocks_program_layout() -> (Prog, Vec<(&'static str, u64, u64)>) {
    let mut p = Prog::new();
    let mut t = Tp::new(0);
    let mut marks: Vec<(&'static str, u64, u64)> = Vec::new();
    // The codes, on both machines.
    let v = t.c.c(&mut p, 0o52525);
    p.to(v, fdest(DEST_PERIOD));
    p.source(0o17, RESULT);
    p.source(0o15, RESULT + 1);
    p.i(ALU | SETM | m_src(0o37) | a_dest(RESULT + 2));
    let ones = t.c.c(&mut p, !0);
    let guard = p.words.len();
    p.i(0);
    p.fill(1);
    // QUUX.
    map_region_7(&mut p, &mut t.c, &[FEATURE_PAGE, WAIT_PAGE]);
    t.start(&mut p);
    let from = t.pushes;
    timer_sections(&mut p, &mut t);
    for (k, name) in ["timer 0", "timer 1", "timer 2"].into_iter().enumerate() {
        marks.push((name, from + 159 * k as u64, 159));
    }
    let mut mark = |t: &Tp, name: &'static str, from: u64| marks.push((name, from, t.pushes - from));
    let from = t.pushes;
    independence(&mut p, &mut t);
    mark(&t, "independence", from);
    let from = t.pushes;
    destination_3(&mut p, &mut t);
    mark(&t, "destination 3", from);
    let from = t.pushes;
    for w in [RESET_DEVICES_WORD, 0o105, 0o106, 0o107, 0o116, 0o117] {
        t.rd(&mut p, w);
    }
    mark(&t, "reserved", from);
    let from = t.pushes;
    shared_edge(&mut p, &mut t);
    mark(&t, "shared edge", from);
    let park = p.at();
    p.park();
    p.words[guard] = JUMP | target(park) | AEQM | a_src(ones) | src(0o16) | N;
    (p, marks)
}

/// Where [`timer_sections`] keeps the virtual addresses of the timer it is
/// on: `M[10]` its control word, `M[11]` its period.  Its loop counts in
/// `M[7]`.
const TS_CTL: u64 = 10;
const TS_PER: u64 = 11;

/// **Each timer alone, one after the other**, the others off throughout:
/// the section below assembled once and run three times, timer k's two
/// words' addresses in `M[10]` and `M[11]` and moved two words on after
/// each; 159 reads a timer, which [`check_timer_section`] slices.
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

fn check_timer_section(k: usize, r: &[u32]) {
    let base = T_ON | T_IE;
    let bit = T_BIT[k];
    let s = |a: usize, b: usize| &r[a..b];
    let has = |v: &[u32], w: u32| v.contains(&w);
    assert_eq!(s(0, 4), &[0, 0, 0, 3], "timer {k}: at reset, and a period written while off");
    let on = s(4, 20);
    assert!(on.iter().all(|&v| v & !T_FLAG == base), "timer {k}: on, periodic, its enable: {on:?}");
    assert!(has(on, base) && has(on, base | T_FLAG), "timer {k}: its flag seen both ways: {on:?}");
    assert_eq!(r[20] & bit, bit, "timer {k}: word 100's bit");
    assert!(s(21, 25).iter().all(|&v| v & !T_FLAG == base), "timer {k}: cleared, on");
    assert_eq!(r[21] & T_FLAG, 0, "timer {k}: the flag down after its clear");
    let no_ie = s(25, 37);
    assert!(no_ie.iter().all(|&v| v & !T_FLAG == T_ON), "timer {k}: its enable clear: {no_ie:?}");
    assert!(has(no_ie, T_ON | T_FLAG), "timer {k}: the flag rises with its enable clear: {no_ie:?}");
    assert!(s(37, 43).iter().all(|&v| v & bit == 0), "timer {k}: no bit in word 100 without its enable");
    assert_eq!(r[43] & !T_FLAG, base, "timer {k}: no mode from a write that leaves it on");
    let five = s(44, 60);
    assert_eq!(five[0], base, "timer {k}: a period written takes the flag down");
    assert!(has(five, base | T_FLAG), "timer {k}: and rises a period on: {five:?}");
    assert!(s(60, 72).iter().all(|&v| v == base), "timer {k}: a period of 0 never rises");
    let cleared = s(72, 102);
    let up = cleared.iter().filter(|&&v| v == base | T_FLAG).count();
    assert!(up >= 3 && up < 27, "timer {k}: the cleared segment saw {up} rises: {cleared:?}");
    assert_eq!(s(102, 105), &[0, 1, 0], "timer {k}: off, its period kept, no bit in 100");
    let one = base | T_ONE_SHOT;
    let shot = s(105, 121);
    assert_eq!(shot[0], one, "timer {k}: one-shot, on");
    assert_eq!(shot[15], one | T_FLAG, "timer {k}: one-shot, risen: {shot:?}");
    assert_eq!(r[121], one | T_FLAG, "timer {k}: one-shot, left up");
    assert_eq!(r[122] & bit, bit, "timer {k}: one-shot, word 100");
    assert!(s(123, 139).iter().all(|&v| v == one), "timer {k}: one-shot cleared, nothing more");
    let again = s(139, 151);
    assert_eq!((again[0], again[11]), (one, one | T_FLAG), "timer {k}: one-shot restarted by a period: {again:?}");
    let periodic = s(151, 159);
    assert!(periodic.iter().all(|&v| v & !T_FLAG == base), "timer {k}: periodic again: {periodic:?}");
    assert!(has(periodic, base | T_FLAG), "timer {k}: periodic again, rising: {periodic:?}");
    assert_eq!(r.len(), 159, "timer {k}: the reads counted");
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

fn check_independence(r: &[u32]) {
    assert_eq!(r.len(), 8 + 5 * 7 + 8 + 7, "independence: the reads counted");
    let all = |i: usize| &r[i..i + 7];
    for (i, what) in [(8, "at the start"), (15, "after RESET-DEVICES written with 0"), (22, "after timer 1 cleared"),
                      (29, "after timer 1's period"), (44, "after timer 1 off")] {
        let w = all(i);
        assert_eq!(w[0] & !T_FLAG, T_ON | T_IE, "independence: timer 0 {what}");
        assert_eq!(w[1], 2, "independence: timer 0's period {what}");
        assert_eq!(w[4] & !T_FLAG, T_ON, "independence: timer 2 {what}");
        assert_eq!(w[5], 5, "independence: timer 2's period {what}");
        assert_eq!(w[6] & T_BIT[2], 0, "independence: timer 2 raises no bit {what}");
    }
    assert_eq!(all(8)[2] & !T_FLAG, T_ON | T_ONE_SHOT | T_IE, "independence: timer 1 one-shot");
    assert_eq!(all(8)[3], 3, "independence: timer 1's period");
    assert_eq!(all(29)[3], 7, "independence: timer 1's period written");
    assert_eq!(all(44)[2..4], [T_ONE_SHOT, 7], "independence: timer 1 off, its mode reading as it was");
    assert!(r[..8].iter().any(|&v| v & T_BIT[0] != 0), "independence: timer 0's bit in 100: {r:?}");
    assert!(r.iter().any(|&v| v == T_ON | T_FLAG), "independence: timer 2's flag seen, no enable");
    assert_eq!(all(51), &[0, 2, T_ONE_SHOT, 7, 0, 5, 0], "independence: all off");
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

fn check_destination_3(r: &[u32]) {
    assert_eq!(r.len(), 1 + 4 + 1 + 4 + 12 + 12 + 5, "destination 3: the reads counted");
    assert_eq!(r[0], TICK_ON, "destination 3: its 1 written to M");
    assert_eq!(&r[1..5], &[T_ONE_SHOT; 4], "destination 3: its 1 leaves timer 0 off: {r:?}");
    assert_eq!(r[5], TICK_ON | T_ONE_SHOT | 8, "destination 3: its 15 written to M");
    assert_eq!(&r[6..10], &[T_ONE_SHOT; 4], "destination 3: its 15 leaves timer 0 off: {r:?}");
    let on = T_ON | T_IE;
    let (before, cleared) = (&r[10..22], &r[22..34]);
    assert!(before.iter().all(|&v| v & !T_FLAG == on), "destination 3: on through the page: {r:?}");
    assert!(before.contains(&(on | T_FLAG)), "destination 3: its flag rose: {r:?}");
    assert_eq!(cleared, &[on | T_FLAG; 12], "destination 3: its 3 leaves the flag up: {r:?}");
    assert_eq!(&r[34..36], &[on | T_FLAG; 2], "destination 3: its 0 and its 1 leave timer 0 on, its flag up: {r:?}");
    assert_eq!(r[36] & T_BIT[0], T_BIT[0], "destination 3: timer 0's bit in word 100");
    assert_eq!(&r[37..39], &[T_ONE_SHOT, 0], "destination 3: timers 1 and 2 untouched, off");
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

fn check_shared_edge(m: &muir::machine::Machine, r: &[u32]) {
    assert_eq!(r.len(), 7 + 25, "shared edge: the reads counted");
    assert_eq!(r[0] & !T_FLAG, T_ON | T_IE, "shared edge: word 110's 401 against destination 3's 0, on");
    assert_eq!(r[1], 0, "shared edge: word 110's 0 against destination 3's 1, off");
    assert_eq!(r[2], T_ONE_SHOT, "shared edge: word 110 read at destination 3's 1, as it was");
    let r = &r[1..];
    assert_eq!(m.amem[(RESULT + 3) as usize], 0, "shared edge: the flag in SINTR at destination 3's 3");
    assert_eq!(m.amem[(RESULT + 4) as usize], 0, "shared edge: the flag in SINTR at destination 3's 1");
    assert_eq!(&[r[2] & 1, r[3] & 1], &[1, 1], "shared edge: word 100 at destination 3's 3 and 1, up");
    assert_eq!(&[r[4] & T_FLAG, r[5] & T_FLAG], &[T_FLAG, T_FLAG], "shared edge: word 110 at destination 3's 3 and 1, up");
    let held = &r[6..];
    assert!(held.iter().all(|&v| v & !T_FLAG == T_ON | T_IE), "shared edge: reads at a held edge: {held:?}");
    assert!(held.contains(&(T_ON | T_IE)) && held.contains(&(T_ON | T_FLAG | T_IE)),
            "shared edge: reads at a held edge saw the flag both ways: {held:?}");
}

fn check_clocks(which: Which, m: &muir::machine::Machine) {
    assert_eq!(m.amem[(RESULT + 2) as usize], 0o52525, "{which:?}: destination 4 writes M");
    if which != Which::Quux {
        assert_eq!(m.amem[RESULT as usize], !0, "CADR: source 17 reads all ones");
        assert_eq!(m.amem[(RESULT + 1) as usize], !0, "CADR: source 15 reads all ones");
        return;
    }
    assert_eq!(m.amem[RESULT as usize], !0, "QUUX: source 17 reads all ones since revision 10");
    let (_, marks) = clocks_program_layout();
    let n = marks.iter().map(|&(_, from, len)| from + len).max().unwrap();
    let log = pdl_log(m, n);
    for (name, from, len) in marks {
        let r = &log[from as usize..(from + len) as usize];
        match name {
            "timer 0" => check_timer_section(0, r),
            "timer 1" => check_timer_section(1, r),
            "timer 2" => check_timer_section(2, r),
            "independence" => check_independence(r),
            "destination 3" => check_destination_3(r),
            "reserved" => assert_eq!(r, &[0; 6], "QUUX: word 104 and the reserved words read 0"),
            "shared edge" => check_shared_edge(m, r),
            _ => unreachable!(),
        }
    }
    assert!(m.timers.timer.iter().all(|t| !t.on), "QUUX: every timer off at the end");
}

/// **THE WINDOW BETWEEN A FLAG'S RISE AND THE EDGE `SINTR` IS TAKEN AT**
/// (muir's `fdc0319`, `a_flag_rising_during_a_wait_is_seen_by_the_jump_after`):
/// `SINTR` is registered at the edge that ends each executed microcycle,
/// waiting or not, with the flags as they stand at that edge.  At a K of four
/// and an L of zero every edge and every rise is on a multiple of 40 ns, so a
/// rise is never strictly inside a microcycle and a fabric that took the
/// flags a tick or two before the edge could not be told apart.  An `ILONG`
/// microcycle at an L of one is 50 ns, so a program of `ILONG`s and plain
/// microcycles moves the edges 10 ns at a time against the rise.
///
/// Every timer's period is 1 us, written through the register page (revision
/// 10, contract Q11), and a timer's start is the edge that takes a page
/// write: each trial turns one timer on with its interrupt enable, or writes
/// its period while it is on, which starts it again from that edge; then:
///
///   - `TICKWIN_PLAIN`: `f` observations made `ILONG` and then fourteen plain
///     ones, `f` from 0 to 3, which puts the rise 0, 30, 20 and 10 ns before
///     an edge at an L of one, on timers 0, 1, 2 and 0, each turned on and
///     off again;
///   - `TICKWIN_WAITS`: `g` observations, `s` of them `ILONG`, a read's start,
///     an observation, a read of `MD`, which waits for the word, and three
///     observations; `g` slides the wait over the rise and `s` the edges; each
///     trial on timer `(trial) mod 3`, grouped by timer, each group's timer
///     on for it and each trial started by its period written.
///
/// **AN OBSERVATION IS TWO MICROCYCLES, WHICHEVER WAY IT GOES**: a jump on
/// condition 5 to two words on, `N` inhibiting the word between, which is a
/// filler; taken, the filler is nopped, and not taken it runs, so the path
/// is as long either way and the trial's timing never depends on the flag it
/// measures.  The filler is never `ILONG`, a nopped `ILONG` being short.  So
/// `JCOND` on every jump says whether the interrupt was up at the edge before
/// it, and the testbench compares it and `SINTR` on every row.
const TICKWIN_PLAIN: std::ops::Range<usize> = 0..4;
const TICKWIN_PLAIN_JUMPS: usize = 14;
const TICKWIN_WAIT_GAPS: [usize; 5] = [3, 5, 7, 9, 11];
const TICKWIN_WAIT_SHIFTS: usize = 4;

/// Region 7's level-2 slot 1 onto the register page, beside `wait_setup`'s
/// slot 0 on main memory.
fn map_page_at_slot_1(p: &mut Prog, t: &mut Tp) {
    let (a, v) = (t.c.c(p, r7(1, 0)), t.c.c(p, level_2_store(FEATURE_PAGE)));
    p.to(a, MD);
    p.to(v, fdest(0o23));
    p.fill(2);
}

fn tickwin_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    let mut t = Tp::new(1);
    map_page_at_slot_1(&mut p, &mut t);
    t.start(&mut p);
    for k in 0..3 {
        t.wr(&mut p, tper(k), 1);
    }
    let cj = |p: &mut Prog, ilong: bool| {
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N | if ilong { 1 << 45 } else { 0 });
        p.fill(1);
    };
    for f in TICKWIN_PLAIN {
        let k = (f % 3) as u32;
        t.wr(&mut p, tctl(k), T_ON | T_IE);
        for _ in 0..f {
            cj(&mut p, true);
        }
        for _ in 0..TICKWIN_PLAIN_JUMPS {
            cj(&mut p, false);
        }
        t.wr(&mut p, tctl(k), 0);
    }
    let trials: Vec<(usize, usize)> =
        TICKWIN_WAIT_GAPS.iter().flat_map(|&g| (0..TICKWIN_WAIT_SHIFTS).map(move |s| (g, s))).collect();
    for k in 0..3u32 {
        t.wr(&mut p, tctl(k), T_ON | T_IE);
        for (i, &(g, s)) in trials.iter().enumerate() {
            if i % 3 != k as usize {
                continue;
            }
            t.wr(&mut p, tper(k), 1);
            for j in 0..g {
                cj(&mut p, j < s);
            }
            p.to(0o305, START_READ);
            cj(&mut p, false);
            p.i(ALU | SETM | SRC_MD | a_dest(0o720));
            for _ in 0..3 {
                cj(&mut p, false);
            }
        }
        t.wr(&mut p, tctl(k), 0);
    }
    p.park();
    p
}

/// **THE PAGE READ IN THE TICKS AROUND ITS EDGE**, QUUX's alone, at an L of
/// zero and one; and the microsecond clock read between the edges.
///
///   - `CLOCKWAIT_USEC` pairs of an `ILONG` filler and a read of source 15:
///     at a K of four and an L of zero every microcycle starts on a multiple
///     of 40 ns and every microsecond is 25 of them, so a microsecond clock a
///     tick or two off never crosses a boundary where a read can see it; with
///     `ILONG`s at an L of one the reads start 10 ns apart against it;
///   - [`clockwait_trials`]: trial `t` on timer `t mod 3`, turned on at 1 us
///     with its interrupt enable, which starts it at the write's edge; a
///     wait of `CLOCKWAIT_DELAY` turns; `g` fillers, `s` of them `ILONG`; and
///     a read of word 100, or in the second sweep of the timer's word
///     110 + 2k, into `A[200 + t]`, whose cycle is taken near the rise.  A
///     read gives the flags as they stood at the edge that takes its cycle
///     (contract Q11, rule 10): a rise on that edge is in it, one a tick
///     after it is not.  Measured at an L of one: gap 5 with 3 `ILONG`s
///     takes the read 10 ns before the rise and reads the flag down, with 4
///     on the rise and reads it up.
const CLOCKWAIT_USEC: usize = 150;
const CLOCKWAIT_DELAY: u32 = 5;
const CLOCKWAIT_GAPS: std::ops::RangeInclusive<usize> = 4..=6;
const CLOCKWAIT_SHIFTS: usize = 5;

/// Each trial's word, 100 or the timer's own, and its gap and shift: the
/// whole sweep once for each word.
fn clockwait_trials() -> Vec<(bool, usize, usize)> {
    [true, false]
        .into_iter()
        .flat_map(|w100| CLOCKWAIT_GAPS.flat_map(move |g| (0..CLOCKWAIT_SHIFTS.min(g + 1)).map(move |s| (w100, g, s))))
        .collect()
}

fn clockwait_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    for _ in 0..CLOCKWAIT_USEC {
        p.i(filler().raw() | 1 << 45);
        p.source(0o15, USEC_AT);
    }
    let mut t = Tp::new(1);
    map_page_at_slot_1(&mut p, &mut t);
    t.start(&mut p);
    for k in 0..3 {
        t.wr(&mut p, tper(k), 1);
    }
    for (i, (w100, g, s)) in clockwait_trials().into_iter().enumerate() {
        let k = (i % 3) as u32;
        let word = if w100 { 0o100 } else { tctl(k) };
        let va = t.c.c(&mut p, t.va(word));
        t.wr(&mut p, tctl(k), T_ON | T_IE);
        t.delay(&mut p, CLOCKWAIT_DELAY);
        for j in 0..g {
            p.i(filler().raw() | if j < s { 1 << 45 } else { 0 });
        }
        p.to(va, START_READ);
        p.fill(1);
        p.i(ALU | SETM | SRC_MD | a_dest(RESULT + i as u64));
        t.wr(&mut p, tctl(k), 0);
    }
    p.park();
    p
}

fn check_clockwait(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    let trials = clockwait_trials();
    let flags: Vec<(bool, bool)> = trials
        .iter()
        .enumerate()
        .map(|(i, &(w100, _, _))| {
            let (k, w) = (i % 3, m.amem[RESULT as usize + i]);
            (w100, if w100 { w & T_BIT[k] != 0 } else { w & T_FLAG != 0 })
        })
        .collect();
    for word in [true, false] {
        let seen: Vec<bool> = flags.iter().filter(|f| f.0 == word).map(|f| f.1).collect();
        assert!(seen.contains(&true) && seen.contains(&false),
                "QUUX: the page's reads of word {} saw the flag both ways: {seen:?}", if word { "100" } else { "110 + 2k" });
    }
    assert!(m.amem[USEC_AT as usize] > 0, "QUUX: the microsecond clock was read");
    assert!(m.timers.timer.iter().all(|t| !t.on), "QUUX: every timer off at the end");
}

fn check_tickwin(which: Which, m: &muir::machine::Machine) {
    if which == Which::Quux {
        assert!(m.timers.timer.iter().all(|t| !t.on), "QUUX: every timer off at the end");
        assert_eq!(m.amem[0o720], 0o777, "QUUX: the word read");
    }
}

// ------------------------------------------------------------------ page

/// The key words pressed on the keyboard's cable, and where: the first three
/// when the program reaches [`PAGE_KEYS_1`]'s mark, and sixty-five more at
/// the second, one past the FIFO's sixty-four.
const PAGE_KEYS_1: [u32; 3] = [0o123456, 0o7654321, 0o40];
const PAGE_KEYS_2: usize = 65;
fn page_key_2(k: usize) -> u32 {
    0o10000 + k as u32
}

/// The page's words the program reads through region 7's slot 0.
const PAGE_UNIBUS_CHAOS: u32 = 0o17772060;

/// **QUUX's register page** (revision 6, contracts Q2, Q3 and Q4): words
/// 100-102, the keyboard and the mouse at 120-123, the Chaosnet interface
/// at 140-147.  Region 7 maps slot 0 onto the page, slot 1 onto the page
/// below it, where nothing answers, and slot 2 onto the Unibus page with the
/// Chaosnet interface's registers.  In order, each read into `A[200 + k]`:
///
///   - words 100, 101 and 102 as the machine comes up: all zero;
///   - the keyboard's interrupt enabled, and `INTERRUPT-CONTROL<27>`, three
///     key words pressed at a mark ([`PAGE_KEYS_1`]); 120, 100, the three
///     words and a fourth read of 121 on an empty FIFO, 120 and 100 again;
///   - sixty-five words at a second mark, one past the FIFO: 120 with the
///     overflow, a write of 120 that clears it and keeps the enable, 120;
///   - the mouse's interrupt enabled: 122 and 123 with the mouse at rest;
///   - a read of the page below, which times out: 101 with the Xbus NXM,
///     a write of 101, 101 again;
///   - error stop written through 102, read, and cleared;
///   - timers 1 and 2 at 2 us with their interrupt enables, each waited
///     for: 100 with `<1>` and `<7>`, and their two words; then 110, 111,
///     104 (`RESET-DEVICES`, which reads 0), feature word 16 and the
///     MACHINE-ID (revision 10, contract Q11);
///   - the Chaosnet interface: 140 written with Clear Transmitter and the
///     transmit interrupt enabled, which raises its request, then 140, the
///     same register on the Unibus at `764140`, 100 with `<5>`, 141, 142,
///     143, 144 and 146; a word into the transmit buffer through 141, which
///     takes the request down; 140 and 100 again; 140 written with 0;
///   - the Unibus window, which QUUX does not have (contract Q5): the same
///     register read at Unibus `764140` through slot 2, and written there,
///     each an Xbus NXM in 101, the write reaching nothing.
///
/// Jump conditions 5 test the interrupt all the way, which the keyboard, the
/// timers and the network raise here, so `SINTR` moves on the rows
/// the testbench compares it on.
fn page_program() -> Prog {
    page_program_marks().0
}

/// The program, and the addresses of its two marks.
fn page_program_marks() -> (Prog, u64, u64) {
    let mut p = Prog::new();
    let va = |slot: u32, w: u32| (7 << 13) | (slot << 8) | w;
    let mut k = 0u64;
    // The map: level 1 entry 3 at region 7; level 2 slots 0, 1 and 2.
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(3));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    for (slot, page) in [(0u32, FEATURE_PAGE), (1, BELOW_FEATURE_PAGE), (2, PAGE_UNIBUS_CHAOS >> 8)] {
        p.konst(0o302, va(slot, 0));
        p.konst(0o303, level_2_store(page));
        p.to(0o302, MD);
        p.to(0o303, fdest(0o23));
        p.fill(2);
    }
    // Each address and value made once, in a [`Pool`]: made where each is
    // used, as the program did up to revision 9, they no longer fit the
    // PROM with revision 10's timers.
    let mut c = Pool::new();
    let rd = |p: &mut Prog, c: &mut Pool, k: &mut u64, w: u32| {
        let a = c.c(p, va(0, w));
        p.read(a, RESULT + *k);
        *k += 1;
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N);
        p.fill(1);
    };
    let wr = |p: &mut Prog, c: &mut Pool, addr: u32, v: u32| c.wr(p, addr, v);
    for w in [0o100, 0o101, 0o102] {
        rd(&mut p, &mut c, &mut k, w);
    }
    // The keyboard.
    p.konst(0o703, 1 << 27);
    p.to(0o703, fdest(DEST_INTCTL));
    wr(&mut p, &mut c, va(0, 0o120), 1 << 8);
    let mark_1 = p.at();
    p.fill(8);
    for w in [0o120, 0o100, 0o121, 0o121, 0o121, 0o121, 0o120, 0o100] {
        rd(&mut p, &mut c, &mut k, w);
    }
    let mark_2 = p.at();
    p.fill(40);
    rd(&mut p, &mut c, &mut k, 0o120);
    wr(&mut p, &mut c, va(0, 0o120), 1 << 8);
    rd(&mut p, &mut c, &mut k, 0o120);
    // The mouse, at rest.
    wr(&mut p, &mut c, va(0, 0o123), 1 << 8);
    rd(&mut p, &mut c, &mut k, 0o122);
    rd(&mut p, &mut c, &mut k, 0o123);
    // A bus error, and its clear.
    p.konst(0o306, va(1, 0));
    p.read(0o306, 0o306);
    rd(&mut p, &mut c, &mut k, 0o101);
    wr(&mut p, &mut c, va(0, 0o101), 0o7777);
    rd(&mut p, &mut c, &mut k, 0o101);
    // Error stop.
    wr(&mut p, &mut c, va(0, 0o102), 1);
    rd(&mut p, &mut c, &mut k, 0o102);
    wr(&mut p, &mut c, va(0, 0o102), 0);
    rd(&mut p, &mut c, &mut k, 0o102);
    // The interval timers (revision 10, contract Q11): timer 1 at 2 us with
    // its interrupt enable, waited for: 100 with `<1>`, 112 and 113; then
    // timer 2 the same: 100 with `<7>`, 114 and 115.  Then 110 and 111, word
    // 104, `RESET-DEVICES`, which reads 0, feature word 16 and the MACHINE-ID.
    for tk in [1, 2] {
        wr(&mut p, &mut c, va(0, tper(tk)), 2);
        wr(&mut p, &mut c, va(0, tctl(tk)), T_ON | T_IE);
        for _ in 0..30 {
            observe(&mut p);
        }
        for w in [0o100, tctl(tk), tper(tk)] {
            rd(&mut p, &mut c, &mut k, w);
        }
        wr(&mut p, &mut c, va(0, tctl(tk)), 0);
    }
    for w in [tctl(0), tper(0), RESET_DEVICES_WORD, 0o16, 0] {
        rd(&mut p, &mut c, &mut k, w);
    }
    // The keyboard's and the mouse's interrupts off, so that the network's
    // request is the only thing up on `SINTR` below (muir's `1f6f5fb`).
    wr(&mut p, &mut c, va(0, 0o120), 0);
    wr(&mut p, &mut c, va(0, 0o123), 0);
    // The network: Clear Transmitter, `<8>`, and the transmit interrupt
    // enable, `<5>`.
    wr(&mut p, &mut c, va(0, 0o140), (1 << 8) | (1 << 5));
    rd(&mut p, &mut c, &mut k, 0o140);
    for w in [0o100, 0o141, 0o142, 0o143, 0o144, 0o146] {
        rd(&mut p, &mut c, &mut k, w);
    }
    wr(&mut p, &mut c, va(0, 0o141), 0o52525);
    rd(&mut p, &mut c, &mut k, 0o140);
    rd(&mut p, &mut c, &mut k, 0o100);
    wr(&mut p, &mut c, va(0, 0o140), 0);
    // **QUUX HAS NO UNIBUS** (contract Q5): the same register at Unibus
    // `764140`, through slot 2, times out as empty Xbus space and sets the
    // Xbus NXM bit, and a write there changes nothing: 101 after the read,
    // cleared, a write of the CSR's Clear Transmitter and its enable there,
    // 101 and 100 after it.
    wr(&mut p, &mut c, va(0, 0o101), 0);
    p.konst(0o307, va(2, PAGE_UNIBUS_CHAOS & 0o377));
    p.read(0o307, RESULT + k);
    k += 1;
    rd(&mut p, &mut c, &mut k, 0o101);
    wr(&mut p, &mut c, va(0, 0o101), 0);
    wr(&mut p, &mut c, va(2, PAGE_UNIBUS_CHAOS & 0o377), (1 << 8) | (1 << 5));
    rd(&mut p, &mut c, &mut k, 0o101);
    rd(&mut p, &mut c, &mut k, 0o100);
    // Reserved words: 103 was one until revision 9 made it the real-time
    // clock, which `rtc` reads, and 104 until revision 10 made it
    // `RESET-DEVICES`, so the next word up stands in for them.
    rd(&mut p, &mut c, &mut k, 0o105);
    rd(&mut p, &mut c, &mut k, 0o150);
    assert_eq!(k, PAGE_READS, "page: the reads counted");
    p.park();
    (p, mark_1, mark_2)
}

const PAGE_READS: u64 = 3 + 8 + 2 + 2 + 2 + 2 + 6 + 5 + 1 + 6 + 2 + 4 + 2;

fn check_page(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    let r: Vec<u32> = (0..PAGE_READS).map(|k| m.amem[(RESULT + k) as usize]).collect();
    assert_eq!(&r[0..3], &[0, 0, 0], "QUUX: 100, 101 and 102 at the start");
    assert_eq!(r[3], 0o401, "QUUX: 120, a word waiting and the enable");
    assert_eq!(r[4], 1 << 3, "QUUX: 100, the keyboard");
    assert_eq!(&r[5..8], &PAGE_KEYS_1, "QUUX: the three words, oldest first");
    assert_eq!(r[8], 0, "QUUX: 121 with the FIFO empty");
    assert_eq!(r[9], 0o400, "QUUX: 120, nothing waiting");
    assert_eq!(r[10], 0, "QUUX: 100, no keyboard");
    assert_eq!(r[11], 0o403, "QUUX: 120 after 65 words, the overflow");
    assert_eq!(r[12], 0o401, "QUUX: 120, the overflow cleared");
    assert_eq!(&r[13..15], &[0, 0o400], "QUUX: the mouse at rest");
    assert_eq!(r[15], 1, "QUUX: 101, the Xbus NXM");
    assert_eq!(r[16], 0, "QUUX: 101 cleared");
    assert_eq!(&r[17..19], &[1, 0], "QUUX: error stop through 102");
    assert_eq!(r[19] & 0o202, 2, "QUUX: 100, timer 1");
    assert_eq!(&r[20..22], &[T_ON | T_FLAG | T_IE, 2], "QUUX: 112 and 113, timer 1 risen");
    assert_eq!(r[22] & 0o202, 0o200, "QUUX: 100, timer 2");
    assert_eq!(&r[23..25], &[T_ON | T_FLAG | T_IE, 2], "QUUX: 114 and 115, timer 2 risen");
    let id = which.geometry().machine_id.unwrap();
    assert_eq!(&r[25..30], &[0, 0, 0, 3, id], "QUUX: 110, 111, 104, feature word 16 and the MACHINE-ID");
    assert_eq!(id >> 4 & 0o7777, 10, "QUUX: revision 10");
    let r = &r[10..];
    assert_eq!(r[20] & 0o240, 0o240, "QUUX: 140, Transmit Done and its interrupt enable");
    assert_eq!(r[21] & (1 << 5), 1 << 5, "QUUX: 100, the network");
    assert_eq!(r[22], 0o177001, "QUUX: 141, my address");
    assert_eq!(r[26], 0, "QUUX: 146 answers nothing");
    assert_eq!(r[28] & (1 << 5), 0, "QUUX: 100, the request down after a word written");
    assert_eq!(r[29], 0, "QUUX: the Unibus's 764140 reads nothing");
    assert_eq!(r[30], 1, "QUUX: 101, the Xbus NXM of a read of the Unibus window");
    assert_eq!(r[31], 1, "QUUX: 101, the Xbus NXM of a write there");
    assert_eq!(r[32] & (1 << 5), 0, "QUUX: 100, the write there reached no Chaosnet interface");
    assert_eq!(&r[33..35], &[0, 0], "QUUX: reserved words");
}

// ------------------------------------------------------------ the checks

fn check_map(which: Which, m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    let quux = which == Which::Quux;
    let id = which.geometry().machine_id;
    let ones = !0u32;
    // Sources 15, 16, 36, 17: the CADR drives nothing on any of them; QUUX
    // answers its microsecond clock on 15, read in the first microsecond,
    // and its MACHINE-ID on 16 and 36; 17, Q1's clocks' status until
    // revision 10, reads all ones there too (contract Q11).
    let want = if quux {
        let id = id.unwrap();
        [0, id, id, ones]
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
            1,
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
/// point at revision 4, settled by muir's `b054c61`).  QUUX has no hung
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
/// **`divmdsync`: the same, at QUUX's synchronous microcycle**, where every
/// microcycle is K ticks and a read's word therefore lands at the same tick
/// of a microcycle whatever the fillers before it.  The read's word comes
/// about 620 ns after the read goes out, so the gaps put the `DIV`'s own
/// edge across the last few microcycles before it, and each gap is taken
/// again with one and with two fillers of `ILONG` after the one that sends
/// the read out, which at an L of one move the `DIV` a tick and two against
/// the word: some trial then lands the word in the ticks between a `DIV`'s
/// edge and its load, where the divider takes the word strobed and not `MD`
/// (`div_word` in `cadr_microcycle.sv`).  At an L of zero the `ILONG`
/// fillers are fillers.  Each trial keeps the output bus, the remainder.
const DIVMDSYNC_GAPS: std::ops::RangeInclusive<usize> = 12..=22;
const DIVMDSYNC_SHIFTS: usize = 3;

fn divmdsync_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, DIVMD_M);
    p.konst(0o306, DIVMD_A);
    p.konst(0o307, DIVMD_Q);
    p.konst(0o310, MD_BEFORE_READ);
    let mut k = 0u64;
    for gap in DIVMDSYNC_GAPS {
        for shift in 0..DIVMDSYNC_SHIFTS {
            p.i(ALU | SETA | a_src(0o307) | Q_LOAD);
            p.to(0o310, MD);
            p.to(0o305, START_READ);
            p.fill(1);
            for _ in 0..shift {
                p.i(filler().raw() | 1 << 45);
            }
            p.fill(gap);
            p.i(DIV_CODE | SRC_MD | a_src(0o306) | a_dest(RESULT + k));
            k += 1;
        }
    }
    p.park();
    p
}

fn check_divmdsync(which: Which, m: &muir::machine::Machine) {
    use muir::muldiv;
    if which != Which::Quux {
        return;
    }
    let trials = DIVMDSYNC_GAPS.count() * DIVMDSYNC_SHIFTS;
    let (ob, _) = muldiv::run(muldiv::Op::Div, DIVMD_M, DIVMD_A, DIVMD_Q);
    for k in 0..trials as u64 {
        assert_eq!(m.amem[(RESULT + k) as usize], ob, "QUUX: DIV {k} divides the word read");
    }
}

// ------------------------------------------------------------- pdlsync

/// **A push into the PDL buffer and a pop of it straight after**, QUUX's
/// alone, at its synchronous microcycle.  A push's write lands on the edge
/// that ends the microcycle after it, the pop reads at the pointer the push
/// moved, and with no filler between them the pop is that very microcycle,
/// which reads the word from before, the buffer having no pass-around; with
/// a filler the pop reads the word pushed.  So a write that landed a tick
/// before its edge, or a latch that took the word before the edge had
/// written it, reads the wrong word on some trial.
const PDLSYNC_TRIALS: u64 = 12;

/// The word at the index, and the reads of it beside a push.
const PDLSYNC_AT_INDEX: u32 = 0x3c5a_a5c3;
const PDLSYNC_INDEX_TRIALS: u64 = 4;

fn pdlsync_program() -> Prog {
    let mut p = Prog::new();
    p.konst(0o320, 0o100);
    p.to(0o320, fdest(0o14));
    for k in 0..PDLSYNC_TRIALS {
        p.konst(0o330 + k, 0o1001 * (k as u32 + 1) + 0x5a00_0000);
    }
    for k in 0..PDLSYNC_TRIALS {
        p.to(0o330 + k, fdest(0o11));
        p.fill((k % 4) as usize);
        p.source(0o24, RESULT + k);
    }
    // And a read of the buffer at the index, not the pointer, in the very
    // microcycle whose edge lands a push: the one port is the push's write
    // and the index's read in the same microcycle, and the read must be the
    // index's word.
    p.konst(0o321, 0o40);
    p.to(0o321, fdest(0o13));
    p.konst(0o322, PDLSYNC_AT_INDEX);
    p.to(0o322, fdest(0o12));
    p.fill(1);
    for k in 0..PDLSYNC_INDEX_TRIALS {
        p.to(0o330 + k, fdest(0o11));
        p.source(0o05, RESULT + PDLSYNC_TRIALS + k);
    }
    p.park();
    p
}

fn check_pdlsync(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    // With a filler between them the pop reads the word pushed; with none
    // it is the microcycle whose edge lands the push, and it reads what the
    // location held before, the PDL buffer having no pass-around: the word
    // the trial before left there, or zero.
    let word = |k: u64| 0o1001 * (k as u32 + 1) + 0x5a00_0000;
    for k in 0..PDLSYNC_TRIALS {
        let want = if k % 4 != 0 { word(k) } else if k == 0 { 0 } else { word(k - 1) };
        assert_eq!(m.amem[(RESULT + k) as usize], want, "QUUX: pop {k}, {} fillers after its push", k % 4);
    }
    for k in 0..PDLSYNC_INDEX_TRIALS {
        assert_eq!(m.amem[(RESULT + PDLSYNC_TRIALS + k) as usize], PDLSYNC_AT_INDEX,
                   "QUUX: the index's word, read beside push {k}");
    }
}

// ------------------------------------------------------------ imemsync

/// **A word written into the control store and executed**, QUUX's alone, at
/// its synchronous microcycle.  QUUX's store is written on the edge that
/// ends the microcycle after the `WRITE-I-MEM` (a tick after it, in the
/// fabric, through the port the read uses), and IR takes the word written
/// from `IWR` and not from the store, so the boot PROM's loading of the
/// store --- a `WRITE-I-MEM` and a pop back, sixteen thousand times --- never
/// reads a word back and cannot tell a write that went nowhere.  Here each
/// trial writes three words above the PROM, an ALU instruction that stores a
/// marker, a jump back and a filler after it, and runs them, some straight
/// after the writes and some after fillers.
const IMEMSYNC_TRIALS: u64 = 6;
const IMEMSYNC_AT: u64 = 0o4000;

/// **AND QUUX'S PROM, WHICH NOTHING WRITES** (revision 6, contract Q2).  Two
/// trials more, the same three words each: written into the RAM's last
/// words below the PROM, 35775 to 35777, and run, the RAM answering there
/// from the first microcycle with no disable bit; and written over three
/// words of the PROM itself and run, where the PROM's own words run and the
/// store keeps nothing.  The PROM's three are laid down after the park, a
/// store of [`IMEMSYNC_PROM_WORD`] and a jump back, where only the jump
/// reaches them.  Each keeps its marker at `A[200 + IMEMSYNC_TRIALS + j]`.
const IMEMSYNC_BELOW_PROM: u64 = 0o35775;
const IMEMSYNC_PROM_WORD: u32 = 0x6200_0001;
const IMEMSYNC_WRITTEN_WORD: u32 = 0x6300_0002;
const IMEMSYNC_BELOW_WORD: u32 = 0x6400_0003;

fn imemsync_program() -> Prog {
    // Where the PROM's three words and the two jumps back land depends on
    // the program's length and not on those addresses, so it is laid down
    // once to find them and again with them.
    let probe = imemsync_program_at(0, 0, 0);
    let (block, back_prom, back_below) = probe.imemsync_marks;
    let p = imemsync_program_at(block, back_prom, back_below);
    assert_eq!(p.imemsync_marks, (block, back_prom, back_below), "imemsync: the addresses held");
    p.prog
}

struct ImemsyncProg {
    prog: Prog,
    imemsync_marks: (u64, u64, u64),
}

fn imemsync_program_at(block: u64, back_prom: u64, back_below: u64) -> ImemsyncProg {
    let mut p = Prog::new();
    // `A[a]`'s low sixteen bits and `M[m]` are the word a `WRITE-I-MEM`
    // with those sources writes: `IWR` is `{A<15:0>, M<31:0>}`.
    let write = |p: &mut Prog, at: u64, word: u64, k: u64| {
        p.konst(0o350, (word >> 32) as u32);
        p.konst(0o351, (word & 0xffff_ffff) as u32);
        p.i(ALU | SETA | a_src(0o351) | m_dest(1));
        p.fill(1);
        p.i(JUMP | R | P | ALWAYS | target(at) | a_src(0o350) | m_src(1));
        p.fill(1 + (k % 3) as usize);
    };
    for k in 0..IMEMSYNC_TRIALS {
        p.konst(0o352, 0x6100_0000 + k as u32);
        let at = IMEMSYNC_AT + 3 * k;
        let store = ALU | SETA | a_src(0o352) | a_dest(RESULT + k);
        // The jump back is to the word after the jump that runs the pair,
        // which is two on from here once the two writes are laid down; the
        // writes are the same length whatever the word, so it is counted.
        let here = p.at();
        let mut probe = Prog::new();
        write(&mut probe, at, 0, k);
        write(&mut probe, at + 1, 0, k);
        write(&mut probe, at + 2, 0, k);
        let back = here + (probe.at() - probe.base) + (k % 2) + 1;
        write(&mut p, at, store, k);
        write(&mut p, at + 1, JUMP | target(back) | ALWAYS | N, k);
        // And the word after the jump back, which the jump fetches and does
        // not run: written, so that no word is fetched that was never
        // written, the control store's power-on contents being a convention
        // this fabric and muir do not share (all ones here, zero there).
        write(&mut p, at + 2, filler().raw(), k);
        p.fill((k % 2) as usize);
        p.i(JUMP | target(at) | ALWAYS | N);
        assert_eq!(p.at(), back, "imemsync: the jump back lands where it was aimed");
        p.fill(1);
    }
    // Below the PROM, and over it.
    p.konst(0o353, IMEMSYNC_BELOW_WORD);
    p.konst(0o354, IMEMSYNC_WRITTEN_WORD);
    p.konst(0o355, IMEMSYNC_PROM_WORD);
    write(&mut p, IMEMSYNC_BELOW_PROM, ALU | SETA | a_src(0o353) | a_dest(RESULT + IMEMSYNC_TRIALS), 0);
    write(&mut p, IMEMSYNC_BELOW_PROM + 1, JUMP | target(back_below) | ALWAYS | N, 0);
    write(&mut p, IMEMSYNC_BELOW_PROM + 2, filler().raw(), 0);
    p.i(JUMP | target(IMEMSYNC_BELOW_PROM) | ALWAYS | N);
    let got_back_below = p.at();
    p.fill(1);
    // Over the PROM's own three: a store of the other marker into the same
    // A word, and a jump to the park, neither of which may land.
    let wrong = ALU | SETA | a_src(0o354) | a_dest(RESULT + IMEMSYNC_TRIALS + 1);
    write(&mut p, block, wrong, 1);
    let start = p.base;
    write(&mut p, block + 1, JUMP | target(start) | ALWAYS | N, 1);
    write(&mut p, block + 2, filler().raw(), 1);
    p.i(JUMP | target(block) | ALWAYS | N);
    let got_back_prom = p.at();
    p.fill(1);
    p.park();
    let got_block = p.at();
    p.i(ALU | SETA | a_src(0o355) | a_dest(RESULT + IMEMSYNC_TRIALS + 1));
    p.i(JUMP | target(back_prom) | ALWAYS | N);
    p.fill(1);
    ImemsyncProg { prog: p, imemsync_marks: (got_block, got_back_prom, got_back_below) }
}

fn check_imemsync(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    for k in 0..IMEMSYNC_TRIALS {
        assert_eq!(m.amem[(RESULT + k) as usize], 0x6100_0000 + k as u32,
                   "QUUX: the word written into the control store ran, trial {k}");
    }
    assert_eq!(m.amem[(RESULT + IMEMSYNC_TRIALS) as usize], IMEMSYNC_BELOW_WORD,
               "QUUX: the words written below the PROM ran");
    assert_eq!(m.amem[(RESULT + IMEMSYNC_TRIALS + 1) as usize], IMEMSYNC_PROM_WORD,
               "QUUX: the PROM's own words ran over the words written there");
}

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
        assert!(!m.timers.timer[0].on, "QUUX: the tick, timer 0, is off at the end");
        assert_eq!(m.amem[0o720], 0o777, "QUUX: the word read");
    }
}

// ------------------------------------------------------------------- main

/// How many microcycles each program's trace runs: to its end and some way
/// round the loop it parks in.

// ------------------------------------------------ QUUX's memory port, Q6

/// **THE WRITE BUFFER, BACK TO BACK, AND WHAT A READ AFTER IT FINDS**, QUUX's
/// alone (contract Q6).  A write is answered after the hit time by a buffer
/// of one word, or when the buffer's last write is done, 290 ns after it
/// began; a read that misses waits for main memory and fills its line in
/// 380.  So writes two instructions apart each wait for the one before, and
/// their answers fall 290 ns apart: at a K of four, a quarter of a
/// microcycle on from each other, one of every four on a master clock edge,
/// where the next write's start is waiting for MBUSY.SYNC to fall.  (Three
/// instructions apart at the closest: the one after a start must leave MD
/// alone, the word going out at the edge that ends it.)  Then
/// every word is read back, the first of each line a miss behind the last
/// write and the second read of it a hit, and the words are held to what was
/// written.
/// Four rounds, with none to three fillers between the writes to turn the
/// phase.
///
/// **AND THEN READS NOTHING ANSWERS**, of the page below the feature page,
/// each ended by the CADR's timeout, whose instant follows the free-running
/// oscillator and so falls at every phase of the microcycle, each word read
/// by the instruction after the start.  Main memory's cycles release on
/// their acknowledgment, so these are what hold the wait for `MD` to READ
/// IN PROGRESS's fall 140 ns after an Xbus acknowledgment: a wait that
/// ended at an edge in the two ticks before the fall ends a microcycle
/// early.  None to seven fillers before each, to turn the phase.
const MEMEDGE_WRITES: u64 = 6;
const MEMEDGE_ROUNDS: u64 = 4;
const MEMEDGE_NXM_READS: u64 = 8;

fn memedge_word(k: u64) -> u32 {
    0x5A00_0000u32.wrapping_add((k as u32).wrapping_mul(0x0101_0101))
}

fn memedge_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    let va = |w: u64| ((7u32 << 13) | (w as u32 & 0o377)) as u32;
    for r in 0..MEMEDGE_ROUNDS {
        // The words and their addresses first, so the writes stand two
        // instructions apart.
        for j in 0..MEMEDGE_WRITES {
            let k = r * MEMEDGE_WRITES + j;
            p.konst(0o310 + 2 * j, memedge_word(k));
            p.konst(0o311 + 2 * j, va(0o20 + 4 * k));
        }
        for j in 0..MEMEDGE_WRITES {
            p.to(0o310 + 2 * j, MD);
            p.to(0o311 + 2 * j, START_WRITE);
            // The word goes out at the edge that ends the instruction after
            // the start, so that one must leave MD alone.
            p.fill(1 + r as usize);
        }
        for j in 0..MEMEDGE_WRITES {
            let k = r * MEMEDGE_WRITES + j;
            p.read(0o311 + 2 * j, RESULT + k);
            // And again, from the line the first read filled: a hit.
            p.read(0o311 + 2 * j, RESULT + 0o40 + k);
            p.fill(r as usize);
        }
    }
    // Level-2 slot 1 of the region onto the page nothing answers.
    p.konst(0o302, ((7u32 << 13) | (1 << 8)) as u32);
    p.konst(0o303, level_2_store(BELOW_FEATURE_PAGE));
    p.to(0o302, MD);
    p.to(0o303, fdest(0o23));
    p.fill(2);
    p.konst(0o304, ((7u32 << 13) | (1 << 8) | 0o17) as u32);
    for n in 0..MEMEDGE_NXM_READS {
        p.konst(RESULT + 0o70 + n, 0xDEAD_0000 + n as u32);
    }
    for n in 0..MEMEDGE_NXM_READS {
        p.fill(n as usize);
        p.read(0o304, RESULT + 0o70 + n);
    }
    p.park();
    p
}

fn check_memedge(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    for k in 0..MEMEDGE_ROUNDS * MEMEDGE_WRITES {
        assert_eq!(m.amem[(RESULT + k) as usize], memedge_word(k), "QUUX: word {k} read back");
        assert_eq!(m.amem[(RESULT + 0o40 + k) as usize], memedge_word(k), "QUUX: word {k} hit");
    }
    assert_ne!(m.bus_error & bus_error::XBUS_NXM, 0, "QUUX: the reads of the empty page time out");
    // Each timed-out read took a word into A over the marker set before it.
    for n in 0..MEMEDGE_NXM_READS {
        assert_ne!(m.amem[(RESULT + 0o70 + n) as usize], 0xDEAD_0000 + n as u32,
                   "QUUX: timed-out read {n} reached A");
    }
}

// ------------------------------------------------------- the bus reset

/// The page of the display's registers and the disk's, `17377400`: the
/// display's at word 360, the disk's four at 374-377.
const DEVICE_PAGE: u32 = 0o36777;
/// The Unibus as the Xbus sees it, `17772000`: the I/O board's KBD CSR,
/// Unibus `764112`, at word 45, and the Chaosnet interface's CSR, `764140`,
/// at word 60.
const UNIBUS_PAGE: u32 = 0o37764;
/// The disk's registers, as words of [`DEVICE_PAGE`].
const DISK_STATUS: u32 = 0o374;
const DISK_CLP: u32 = 0o375;
const DISK_DA: u32 = 0o376;
const DISK_START: u32 = 0o377;
/// The reads the program makes on each side of the reset: seven, and on the
/// CADR an eighth, the interface's interrupt status; on QUUX eight more,
/// the timers' six words and the file device's 160 and 161.
fn busreset_reads(quux: bool) -> u64 {
    if quux { 15 } else { 8 }
}
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
/// command and errors (`Controller::xbus_init` on the CADR,
/// `BlockDisk::xbus_init` on QUUX), and the I/O board's interrupt enables,
/// its Chaosnet interface and its serial line (`IoBoard::unibus_init`).
/// muir's `Rtl` does it as the `INTERRUPT-CONTROL` write that raises the bit
/// lands.
///
/// Each device is left with something the reset clears: the disk's command
/// with its done interrupt enabled --- on QUUX a command block-disk does not
/// have, STARTed, so that the transfer stops by error with `<13>` --- the
/// display's vertical flag with its interrupt enabled, and the Chaosnet
/// interface's Clear Transmitter and transmit interrupt enable, through the
/// register page's word 140 on QUUX and at Unibus `764140` on the CADR.  On
/// the CADR the I/O board's clock interrupt is enabled too, at the KBD CSR,
/// `764112` --- `CLOCK READY` is up from power-on, no interval having been
/// loaded --- and the bus interface's `ENABLE UB INTS` at `766040`, so that
/// the Unibus interrupt, `UB INT`, is up with the Xbus line when the reset
/// comes and the microcycle that raises the bit takes both down.  Then the
/// bit is raised and lowered, and everything is read again.  In order, each
/// read into `A[200 + k]` and again into `A[200 + n + k]` after the reset,
/// `n` being [`busreset_reads`]:
///
///   0-2   the disk's status, its last memory address and its disk address
///   3     the display's register 0
///   4     the Chaosnet interface's CSR
///   5     QUUX: the register page's word 100, who is interrupting; the
///         CADR: the KBD CSR
///   6     the disk's status again, after the others
///   7     the CADR alone: the interface's interrupt status, `766040`
///
/// And on the CADR a second reset with `UB INT` written by hand at `766042`,
/// which the reset does not reach: `766040` read after it, into
/// `A[200 + 2n]`, and again after the bit is written clear.
///
/// **ON QUUX SINCE REVISION 10 `<28>` RESETS NOTHING AND WORD 104 DOES**
/// (contract Q11 and the Q9 amendment).  The same devices, and the three
/// interval timers --- timers 0 and 1 turned on through their words, timer 2
/// one-shot without its interrupt enable --- and
/// the file device enabled with an index fault standing; read before, and
/// again, as `A[200 + n + k]`, after `<28>` raised and lowered, which leaves
/// every one as it was and holds nothing off `SINTR`; then `RESET-DEVICES`
/// written with 0, which does nothing, and with 1, observed at the edges
/// around its write, and everything read a third time into `A[200 + 2n + k]`:
/// the disk, the network, the file device and the timers reset, the
/// keyboard and mouse not.  Eight more reads a side on QUUX: 110-115, 160
/// and 161.
///
/// Every read is followed by a jump on condition 5, which tests the
/// interrupt all the way, so that `SINTR` moves on rows the testbench
/// compares it on.
fn busreset_program() -> Prog {
    let quux = BASE.load(std::sync::atomic::Ordering::Relaxed) != 0;
    let mut p = Prog::new();
    let va = |slot: u32, w: u32| (7 << 13) | (slot << 8) | w;
    let mut k = 0u64;
    let reads = busreset_reads(quux);
    // The map: level 1 entry 3 at region 7; level 2 slot 0 the devices,
    // slot 1 the register page, slot 2 the Unibus, and on the CADR slot 3
    // the interface's own registers.
    p.konst(0o300, va(0, 0));
    p.konst(0o301, level_1_store(3));
    p.to(0o300, MD);
    p.to(0o301, fdest(0o23));
    p.fill(2);
    let slots: &[(u32, u32)] = if quux {
        &[(0, DEVICE_PAGE), (1, FEATURE_PAGE), (2, UNIBUS_PAGE)]
    } else {
        &[(0, DEVICE_PAGE), (1, FEATURE_PAGE), (2, UNIBUS_PAGE), (3, INTERFACE_PAGE)]
    };
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
    // The Chaosnet interface is on the register page on QUUX and on the
    // Unibus on the CADR, with the I/O board; the wire it resets is the same
    // one.
    let chaos = if quux { va(1, 0o140) } else { va(2, CHAOS_CSR_WORD) };
    let fifth = if quux { va(1, 0o100) } else { va(2, KBD_CSR_WORD) };
    // The disk: the done interrupt enabled, and on QUUX a transfer started
    // with a command block-disk does not have.
    wr(&mut p, va(0, DISK_STATUS), (1 << 11) | if quux { 0o17 } else { 0 });
    if quux {
        wr(&mut p, va(0, DISK_CLP), 0o1234);
        wr(&mut p, va(0, DISK_DA), 0o5670);
        wr(&mut p, va(0, DISK_START), 0);
        // **`<28>` WITH THE DISK'S REQUEST ALONE UP**, before the network's
        // and the timers' are: on QUUX since revision 10 it resets nothing
        // and holds nothing off `SINTR`, so the line stays up through the
        // write's edge.  (Later, with the network's and the timers' terms up
        // too, a hold-off of the disk's term alone would not show.)
        // The two words are made here once, and the reset below reuses them.
        p.fill(4);
        p.konst(0o306, 1 << 28);
        p.konst(0o307, 0);
        p.to(0o306, fdest(DEST_INTCTL));
        p.fill(4);
        p.to(0o307, fdest(DEST_INTCTL));
        p.fill(2);
    }
    // The display's vertical flag and its interrupt enable.
    wr(&mut p, va(0, TV_CONTROL), 0o30);
    // The Chaosnet interface: Clear Transmitter, `<8>`, and the transmit
    // interrupt enable, `<5>`.
    wr(&mut p, chaos, (1 << 8) | (1 << 5));
    // On the CADR the I/O board's clock interrupt, and the interface's
    // enable, which takes the board's request as `UB INT`.
    if !quux {
        wr(&mut p, va(2, KBD_CSR_WORD), CLOCK_INT_ENABLE);
        wr(&mut p, va(3, INTERRUPT_STATUS_WORD), ENABLE_UB_INTS);
    }
    // On QUUX the interval timers (revision 10, contract Q11), each through
    // its words: timers 0 and 1 at 1 us, periodic with their interrupt
    // enables; timer 2 one-shot at 2 us without it.  The second of each
    // pair of equal words is written from the word the first left in
    // `A[305]`, which keeps the program inside the PROM.  And the file device (revision 9)
    // enabled with its interrupt enable on the rings' reset bases, and an
    // index fault made: a command producer past the ring's one entry.
    if quux {
        let again = |p: &mut Prog, addr: u32| {
            p.konst(0o304, addr);
            p.to(0o305, MD);
            p.to(0o304, START_WRITE);
            p.fill(2);
        };
        wr(&mut p, va(1, tper(0)), 1);
        again(&mut p, va(1, tper(1)));
        wr(&mut p, va(1, tctl(1)), T_ON | T_IE);
        again(&mut p, va(1, tctl(0)));
        wr(&mut p, va(1, tper(2)), 2);
        wr(&mut p, va(1, tctl(2)), T_ON | T_ONE_SHOT);
        wr(&mut p, va(1, 0o160), 0x101);
        wr(&mut p, va(1, 0o164), 5);
    }
    let mut order = vec![va(0, DISK_STATUS), va(0, DISK_CLP), va(0, DISK_DA), va(0, TV_CONTROL), chaos, fifth,
                         va(0, DISK_STATUS)];
    if !quux {
        order.push(va(3, INTERRUPT_STATUS_WORD));
    } else {
        for w in [tctl(0), tper(0), tctl(1), tper(1), tctl(2), tper(2), 0o160, 0o161] {
            order.push(va(1, w));
        }
    }
    assert_eq!(order.len() as u64, reads, "busreset: the reads a side");
    // The reset: `INTERRUPT-CONTROL<28>` raised, then lowered, the other
    // three bits held at zero.
    let reset = |p: &mut Prog| {
        if !quux {
            p.konst(0o306, 1 << 28);
            p.konst(0o307, 0);
        }
        p.to(0o306, fdest(DEST_INTCTL));
        p.fill(4);
        p.to(0o307, fdest(DEST_INTCTL));
        p.fill(2);
    };
    // **ON QUUX, `<28>` DRIVES NOTHING AND WORD 104 RESETS THE DEVICES**
    // (revision 10, contract Q11): the bit raised and lowered, the devices
    // read again, then `RESET-DEVICES` written with 0, which does nothing, and
    // with 1, observed at the edges around the write --- the edge that takes
    // it, whose `SINTR` still has the terms the reset takes down, and the
    // next --- and everything read a third time.
    let sides = if quux { 3 } else { 2 };
    for side in 0..sides {
        for &addr in &order {
            rd(&mut p, &mut k, addr);
        }
        if side == 0 {
            reset(&mut p);
        } else if side == 1 && quux {
            wr(&mut p, va(1, RESET_DEVICES_WORD), 0);
            p.konst(0o305, 1);
            p.konst(0o304, va(1, RESET_DEVICES_WORD));
            p.to(0o305, MD);
            p.to(0o304, START_WRITE);
            for _ in 0..4 {
                observe(&mut p);
            }
        }
    }
    // **AND ON THE CADR A SECOND RESET, WITH `UB INT` WRITTEN BY HAND**, at
    // `766042` with a vector of its own: a bus reset reaches the I/O board and
    // not the interface, so that bit stands through it, and `SINTR` with it,
    // until it is written clear.  Read after the reset, `A[200 + 2n]`, and
    // after the clear, `A[200 + 2n + 1]`.
    if !quux {
        wr(&mut p, va(3, INTERRUPT_CONTROL_2_WORD), UB_INT_BY_HAND);
        reset(&mut p);
        rd(&mut p, &mut k, va(3, INTERRUPT_STATUS_WORD));
        wr(&mut p, va(3, INTERRUPT_CONTROL_2_WORD), 0);
        rd(&mut p, &mut k, va(3, INTERRUPT_STATUS_WORD));
    }
    assert_eq!(k, if quux { 3 * reads } else { 2 * reads + 2 }, "busreset: the reads counted");
    p.park();
    p
}

fn check_busreset(which: Which, m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    let n = busreset_reads(which == Which::Quux);
    // On QUUX the reset is reset devices, the third side; `<28>`'s side,
    // the second, is held to the first below.
    let after = |k: u64| if which == Which::Quux { r(2 * n + k) } else { r(n + k) };
    // Before: the disk's done interrupt requested, the Chaosnet
    // interface's transmit interrupt enabled.
    assert_ne!(r(0) & (1 << 3), 0, "{which:?}: the disk's done interrupt, before the reset");
    // After: the command's enable gone and with it the request, the
    // network's enable gone, the disk address standing.
    assert_eq!(after(0) & (1 << 3), 0, "{which:?}: the disk's done interrupt, after the reset");
    assert_eq!(after(6), after(0), "{which:?}: the disk's status, read twice after the reset");
    assert!(!m.interrupt(), "{which:?}: nothing interrupts after the reset: {:o} {:?}", m.interrupt_sources(), m.timers);
    if which == Which::Quux {
        assert_eq!(r(0), 0o21011, "QUUX: block-disk stopped by error, its interrupt requested, no pack");
        assert_eq!(after(0), 0o1001, "QUUX: block-disk not active, no pack, the error cleared");
        assert_eq!((r(2), after(2)), (0o5670, 0o5670), "QUUX: the disk address has no pin on -XBUS INIT");
        assert_eq!((r(5) & !0o3, after(5)), (0o44, 0), "QUUX: word 100, the disk, the network and timers 0 and 1, then nothing");
        assert_eq!(r(5) & 0o3, 0o3, "QUUX: word 100, timers 0 and 1 before the reset");
        assert_ne!(r(4) & (1 << 5), 0, "QUUX: the network's enable, before the reset");
        assert_eq!(after(4) & (1 << 5), 0, "QUUX: the network's enable, after the reset");
        // `<28>` reset nothing: the disk, the network and the file device
        // as they were, the timers on.
        let mid = |k: u64| r(n + k);
        assert_eq!((mid(0), mid(4) & (1 << 5), mid(5) & 0o44), (0o21011, 1 << 5, 0o44), "QUUX: <28> reset nothing");
        // The timers before: timers 0 and 1 periodic with their enables;
        // timer 2 one-shot.
        let (on, one) = (T_ON | T_IE, T_ON | T_ONE_SHOT);
        assert_eq!([r(7) & !T_FLAG, r(8), r(9) & !T_FLAG, r(10), r(11) & !T_FLAG, r(12)], [on, 1, on, 1, one, 2],
                   "QUUX: the timers before the reset");
        assert_eq!([mid(7) & !T_FLAG, mid(9) & !T_FLAG, mid(11) & !T_FLAG], [on, on, one], "QUUX: the timers after <28>");
        assert_eq!((r(13), r(14) & 8, mid(13), mid(14) & 8), (0x101, 8, 0x101, 8), "QUUX: the file device before, and after <28>");
        // After reset devices: every timer at its reset state, the file
        // device disabled, its index fault cleared, quiet.
        assert_eq!([after(7), after(8), after(9), after(10), after(11), after(12)], [0; 6], "QUUX: the timers reset");
        assert_eq!((after(13), after(14)), (0, 2), "QUUX: the file device disabled, the fault cleared, quiet");
        assert!(m.timers.timer.iter().all(|t| *t == muir::machine::IntervalTimer::RESET), "QUUX: every timer reset");
    } else {
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
}

// ------------------------------------------------- a start after a start

/// The words `startstart` seeds and writes, each its own.
fn startstart_word(k: u32) -> u32 {
    0x5C00_0000u32.wrapping_add(k.wrapping_mul(0x0101_0101))
}

/// The mode register's one bit that reads back, black-on-white.
const STARTSTART_MODE: u32 = 4;

/// **A MEMORY START IN THE MICROCYCLE RIGHT AFTER A START** (muir's
/// `b1e710c`).  `MBUSY.SYNC` is `MEMRQ` registered at the edge that ends the
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
/// Region 7's slot 0 is main memory's page `WAIT_PAGE`, on QUUX slot 1 the
/// display's registers and slot 2 the feature page.  Every word a read
/// takes was written before on its own, and a line is cached only when a
/// read has filled it, since a write allocates nothing.
///
/// On QUUX, each pair in consecutive microcycles, into `A[200 + k]`:
///
///   0      a write then a read, both lines missing: the word read
///   1      the same, both lines cached
///   2      a read then a write, missing: `MD` after them
///   3      the same, cached
///   4      a read then a read, missing: `MD` after them
///   5      the same, cached
///   6      a write of the mode register, then a read of main memory
///   7      a write of main memory, then a read of the mode register
///   10     a write of MACHINE-ID, which goes nowhere, then a read
///   20-    every word written and every word read, read back in turn
///
/// A write then a write, with `MD` loaded in the microcycle after the
/// second start, and the two single writes with `MD` loaded one and two
/// microcycles after the start, are among the words read back.
///
/// On the CADR, only the two single writes with `MD` after the start, read
/// back into `A[200]` and `A[201]`: the back-to-back pair is not traced
/// there (see the CADR's branch below).
fn startstart_program() -> Prog {
    let quux = BASE.load(std::sync::atomic::Ordering::Relaxed) != 0;
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    // `A[300]` is `va(0, 0)`, so `A[a]` = `va(0, w)` is two instructions.
    let addr = |p: &mut Prog, a: u64, w: u64| {
        p.i(DISPATCH | DMEM_WRITE | a_src(w));
        p.i(ALU | ADD | src(0) | a_src(0o300) | a_dest(a));
    };
    let va = |slot: u32, w: u32| (7 << 13) | (slot << 8) | w;
    // A write on its own: the word in `A[d]` at the address in `A[a]`.
    let write = |p: &mut Prog, d: u64, a: u64| {
        p.to(d, MD);
        p.to(a, START_WRITE);
        p.fill(2);
    };
    // Scratch: the address, and the data words.
    const X: u64 = 0o360;
    const D: u64 = 0o370;
    let mut back: Vec<u64> = Vec::new();
    let mut k = 0u64;
    let result = |k: &mut u64| {
        let r = RESULT + *k;
        *k += 1;
        r
    };
    let read_md = |p: &mut Prog, r: u64| {
        p.fill(1);
        p.i(ALU | SETM | SRC_MD | a_dest(r));
    };
    if quux {
        // Level-2 slots 1 and 2: the display's registers and the feature page.
        for (slot, page) in [(1u32, DEVICE_PAGE), (2, FEATURE_PAGE)] {
            p.konst(0o302, va(slot, 0));
            p.konst(0o303, level_2_store(page));
            p.to(0o302, MD);
            p.to(0o303, fdest(0o23));
            p.fill(2);
        }
        // Addresses: A[320 + n] is word 20 + 4n, a line each.
        for n in 0..16u64 {
            addr(&mut p, 0o320 + n, 0o20 + 4 * n);
        }
        let line = |n: u64| 0o320 + n;
        // Seeds: the word at line n is `startstart_word(n)`.
        let seeded = [1u64, 3, 4, 6, 8, 9, 10, 11, 14, 15];
        for &n in &seeded {
            p.konst(D, startstart_word(n as u32));
            write(&mut p, D, line(n));
            back.push(line(n));
        }
        // Data words, D + j = `startstart_word(40 + j)`.
        for j in 0..6u32 {
            p.konst(D + j as u64, startstart_word(0o40 + j));
        }
        // Lines 2, 3, 6, 7, 10, 11 cached, by a read of each.
        for n in [2u64, 3, 6, 7, 10, 11] {
            p.read(line(n), 0o377);
        }
        // A write then a read: missing, then cached.
        for (a, b) in [(0u64, 1u64), (2, 3)] {
            p.to(D, MD);
            p.to(line(a), START_WRITE);
            p.to(line(b), START_READ);
            let r = result(&mut k);
            read_md(&mut p, r);
            back.push(line(a));
            p.fill(2);
        }
        // A read then a write: the write takes `MD` as the read left it.
        for (a, b) in [(4u64, 5u64), (6, 7)] {
            p.to(D + 1, MD);
            p.to(line(a), START_READ);
            p.to(line(b), START_WRITE);
            let r = result(&mut k);
            read_md(&mut p, r);
            back.push(line(b));
            p.fill(2);
        }
        // A read then a read.
        for (a, b) in [(8u64, 9u64), (10, 11)] {
            p.to(D + 1, MD);
            p.to(line(a), START_READ);
            p.to(line(b), START_READ);
            let r = result(&mut k);
            read_md(&mut p, r);
            p.fill(2);
        }
        // The display's mode register, then main memory; main memory, then
        // the mode register.
        p.konst(D + 6, STARTSTART_MODE);
        p.konst(X, va(1, TV_CONTROL));
        p.to(D + 6, MD);
        p.to(X, START_WRITE);
        p.to(line(14), START_READ);
        let r = result(&mut k);
        read_md(&mut p, r);
        p.fill(2);
        p.to(D + 2, MD);
        p.to(line(12), START_WRITE);
        p.to(X, START_READ);
        let r = result(&mut k);
        read_md(&mut p, r);
        back.push(line(12));
        p.fill(2);
        // MACHINE-ID, word 0 of the feature page, written, then a read.
        p.konst(X, va(2, 0));
        p.to(D + 3, MD);
        p.to(X, START_WRITE);
        p.to(line(15), START_READ);
        let r = result(&mut k);
        read_md(&mut p, r);
        p.fill(2);
        // A write then a write, `MD` loaded in the microcycle after the
        // second start, at words 120 and 124.
        addr(&mut p, X, 0o120);
        addr(&mut p, X + 1, 0o124);
        p.to(D + 4, MD);
        p.to(X, START_WRITE);
        p.to(X + 1, START_WRITE);
        p.to(D + 5, MD);
        p.fill(2);
        back.push(X);
        back.push(X + 1);
    } else {
        // **NOT THE BOARD'S PROGRAM**, a write and a read back to back: the
        // board loses the write, and muir's `rtl` gets the board's words only
        // by asking its bus interface for a second cycle while the first
        // runs, which its own debug assertion refuses.  The fabric's CADR
        // does not follow it there (its bus audit finds a request at the
        // second's address in the direction the cycle does not name, and
        // the read brings 0), and the reference is not one muir defines, so
        // the CADR runs only the writes below.
        p.konst(D + 4, startstart_word(0o44));
        p.konst(D + 5, startstart_word(0o45));
    }
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
    // Everything read back, into `A[220 + n]` on QUUX and on after the
    // read on the CADR.
    let mut at = if quux { RESULT + 0o20 } else { RESULT + k };
    for a in back {
        p.read(a, at);
        at += 1;
    }
    p.park();
    p
}

fn check_startstart(which: Which, m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    let w = startstart_word;
    if which == Which::Cadr {
        assert_eq!([r(0), r(1)], [w(0o45), w(0o44)], "CADR: MD a microcycle after the start, and two");
        return;
    }
    assert_eq!(r(0), w(1), "QUUX: a write then a read, missing: the word read");
    assert_eq!(r(1), w(3), "QUUX: a write then a read, cached");
    assert_eq!(r(2), w(4), "QUUX: a read then a write, missing: MD");
    assert_eq!(r(3), w(6), "QUUX: a read then a write, cached");
    assert_eq!(r(4), w(9), "QUUX: a read then a read, missing");
    assert_eq!(r(5), w(11), "QUUX: a read then a read, cached");
    assert_eq!(r(6), w(14), "QUUX: the mode register, then main memory");
    assert_eq!(r(7), STARTSTART_MODE, "QUUX: main memory, then the mode register");
    assert_eq!(r(8), w(15), "QUUX: MACHINE-ID, then main memory");
    let back = |n: u64| r(0o20 + n);
    // The seeds, in `seeded`'s order: lines 1, 3, 4, 6, 8, 9, 10, 11, 14, 15.
    for (n, line) in [1u32, 3, 4, 6, 8, 9, 10, 11, 14, 15].iter().enumerate() {
        assert_eq!(back(n as u64), w(*line), "QUUX: line {line} as seeded");
    }
    assert_eq!([back(10), back(11)], [w(0o40), w(0o40)], "QUUX: each write before a read landed");
    assert_eq!([back(12), back(13)], [w(4), w(6)], "QUUX: each write after a read wrote the word read");
    assert_eq!(back(14), w(0o42), "QUUX: the write before the mode register's read landed");
    assert_eq!([back(15), back(16)], [w(0o44), w(0o45)],
               "QUUX: a write then a write, the second with MD of the microcycle after its start");
    assert_eq!([back(17), back(18)], [w(0o45), w(0o44)], "QUUX: MD a microcycle after the start, and two");
    assert_eq!(m.bus_error & bus_error::XBUS_NXM, 0, "QUUX: every cycle answered");
}

// ----------------------------------- revision 9: the clock and the file device

/// **CONSTANTS IN A MEMORY, EACH MADE ONCE**, from `A[400]` up: the two
/// programs below name some fifty words, and made where each is used, as the
/// other programs make theirs, they would not fit the PROM's 1,024.  A value
/// takes as many ten-bit pieces of the dispatch constant as it has, where
/// `Prog::konst` always takes four.
struct Pool {
    at: std::collections::HashMap<u32, u64>,
    next: u64,
}

impl Pool {
    const FIRST: u64 = 0o400;
    const LAST: u64 = 0o677;

    fn new() -> Pool {
        Pool { at: std::collections::HashMap::new(), next: Self::FIRST }
    }

    /// The A address holding `v`, made here the first time it is asked.
    fn c(&mut self, p: &mut Prog, v: u32) -> u64 {
        if let Some(&a) = self.at.get(&v) {
            return a;
        }
        let a = self.next;
        assert!(a <= Self::LAST, "the constant pool is full");
        self.next += 1;
        let parts = [(0u64, 10u64), (10, 10), (20, 10), (30, 2)];
        let n = parts.iter().rposition(|&(pos, _)| (v as u64) >> pos != 0).map_or(1, |i| i + 1);
        for (k, &(pos, w)) in parts[..n].iter().enumerate() {
            let piece = ((v as u64) >> pos) & ((1 << w) - 1);
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

    /// A read of `va` into `A[RESULT + *k]`, then a jump on condition 5, so
    /// that `SINTR` moves on rows the testbench compares it on.
    fn rd(&mut self, p: &mut Prog, k: &mut u64, va: u32) {
        let a = self.c(p, va);
        p.read(a, RESULT + *k);
        *k += 1;
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N);
        p.fill(1);
    }

    /// A write of `v` at `va`.
    fn wr(&mut self, p: &mut Prog, va: u32, v: u32) {
        let (av, aa) = (self.c(p, v), self.c(p, va));
        p.to(av, MD);
        p.to(aa, START_WRITE);
        p.fill(2);
    }

    /// A write of `v1` at `va1` and, two microcycles after its start, one of
    /// `v2` at `va2`: as close as a write may follow a write without its
    /// `MD` being the second's.
    fn wr_wr(&mut self, p: &mut Prog, va1: u32, v1: u32, va2: u32, v2: u32) {
        let (a1v, a1a, a2v, a2a) = (self.c(p, v1), self.c(p, va1), self.c(p, v2), self.c(p, va2));
        p.to(a1v, MD);
        p.to(a1a, START_WRITE);
        p.fill(1);
        p.to(a2v, MD);
        p.to(a2a, START_WRITE);
        p.fill(2);
    }

    /// Reads `va` until it reads `want`.
    fn poll(&mut self, p: &mut Prog, va: u32, want: u32) {
        let (aa, aw) = (self.c(p, va), self.c(p, want));
        let top = p.at();
        p.to(aa, START_READ);
        p.fill(1);
        p.i(JUMP | target(top) | AEQM | INVERT | a_src(aw) | SRC_MD | N);
        p.fill(1);
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

/// The seconds the host sets the clock to at each of the `rtc` program's
/// marks: an ordinary second, and the last one, which the clock holds.
const RTC_SET: [u32; 2] = [0x7b5c_2e19, 0xffff_ffff];
/// What the program writes at word 103, which goes nowhere.
const RTC_WRITTEN: u32 = 0x1234_5678;
const RTC_READS: u64 = 9;

/// **QUUX's real-time clock and the revision it came with** (revision 9,
/// contract Q9): word 103 of the register page, unsigned Unix seconds, read
/// only to the machine and kept by the host.  Region 7's slot 0 is the
/// register page.  Into `A[200 + k]`:
///
///   0  word 0, MACHINE-ID, revision 9
///   1  word 15, the devices of revision 9: 3
///   2  word 103, the clock at the start: `RTC_START`
///   3  word 103 after the host set it, at the first mark, to `RTC_SET[0]`
///   4  word 103 after the machine wrote `RTC_WRITTEN` there: unchanged
///   5  word 104, reserved until revision 10 and `RESET-DEVICES` since: 0
///   6  word 103 after the host set it, at the second mark, to 2^32 - 1
///   7  word 102, error stop, after the write of 103 changed nothing there
///   8  word 101, the bus errors: none
///
/// The host's setting is the fabric's host side on a board, which Linux
/// writes; here it is muir's `Rtc::Counted` restarted at the mark, and the
/// testbench writes the same seconds at the same microcycle.  A second of
/// the machine's time does not pass inside a trace, so the count across a
/// second is `build/quux_rtc_unit.pass`'s, against the same arithmetic.
fn rtc_program() -> Prog {
    rtc_program_marks().0
}

fn rtc_program_marks() -> (Prog, [u64; 2]) {
    let mut p = Prog::new();
    let mut c = Pool::new();
    let mut k = 0u64;
    map_region_7(&mut p, &mut c, &[FEATURE_PAGE]);
    let reg = |w| r7(0, w);
    c.rd(&mut p, &mut k, reg(0));
    c.rd(&mut p, &mut k, reg(0o15));
    c.rd(&mut p, &mut k, reg(0o103));
    let mark_1 = p.at();
    p.fill(4);
    c.rd(&mut p, &mut k, reg(0o103));
    c.wr(&mut p, reg(0o103), RTC_WRITTEN);
    c.rd(&mut p, &mut k, reg(0o103));
    c.rd(&mut p, &mut k, reg(0o104));
    let mark_2 = p.at();
    p.fill(4);
    c.rd(&mut p, &mut k, reg(0o103));
    c.rd(&mut p, &mut k, reg(0o102));
    c.rd(&mut p, &mut k, reg(0o101));
    assert_eq!(k, RTC_READS, "rtc: the reads counted");
    p.park();
    (p, [mark_1, mark_2])
}

fn check_rtc(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    let r: Vec<u32> = (0..RTC_READS).map(|k| m.amem[(RESULT + k) as usize]).collect();
    let id = which.geometry().machine_id.unwrap();
    assert!((id >> 4) & 0xfff >= 9, "QUUX: revision 9 or later");
    assert_eq!(r[0], id, "QUUX: MACHINE-ID on the page");
    assert_eq!(r[1], 3, "QUUX: word 15, the clock and the file device");
    assert_eq!(r[2], machine_axis::RTC_START, "QUUX: the clock at the start");
    assert_eq!(r[3], RTC_SET[0], "QUUX: the clock the host set");
    assert_eq!(r[4], RTC_SET[0], "QUUX: a write of 103 goes nowhere");
    assert_eq!(r[5], 0, "QUUX: word 104, reserved until revision 10 and RESET-DEVICES since, reads 0");
    assert_eq!(r[6], RTC_SET[1], "QUUX: the last second");
    assert_eq!((r[7], r[8]), (0, 0), "QUUX: nothing else moved");
}

/// The file device's pages: the rings in one, the buffers in the next.
const FD_RING_PAGE: u32 = 0o102;
const FD_BUF_PAGE: u32 = 0o103;
/// The command ring, two entries; the response ring, one, at the next line
/// pair but one.
const FD_CMD: u32 = FD_RING_PAGE << 8;
const FD_RESP: u32 = (FD_RING_PAGE << 8) + 0o40;
/// Buffer A's name, READ's buffer B, and LOG's line.
const FD_NAME: u32 = FD_BUF_PAGE << 8;
const FD_B: u32 = (FD_BUF_PAGE << 8) + 0o20;
const FD_LOG: u32 = (FD_BUF_PAGE << 8) + 0o40;
/// The one file in the scratch folder, `/f`, and its modification time.
const FD_FILE: &[u8] = b"QUUX file device";
const FD_MTIME: u32 = 1_700_000_000;
const FD_READS: u64 = 57;

/// A command's first word: its tag, opcode and flags.
fn fd_word0(tag: u32, opcode: u32, flags: u32) -> u32 {
    tag | opcode << 16 | flags << 24
}

/// Writes a command into slot `slot` of the command ring, words 1 to 6 and
/// then word 0, and with `then_prod` the command producer right behind word
/// 0.  Word 0 is last because it is never zero --- the tag and the opcode ---
/// and differs from whatever the slot held before, so a host shown the
/// producer before that word has left the write buffer finds the slot's old
/// word 0 in main memory, which the testbench compares.
fn fd_command(p: &mut Prog, c: &mut Pool, slot: u32, words: [u32; 7], then_prod: Option<u32>) {
    for i in (1..7).chain(0..1) {
        let va = r7(1, 8 * slot + i as u32);
        match then_prod {
            Some(n) if i == 0 => c.wr_wr(p, va, words[i], r7(0, 0o164), n),
            _ => c.wr(p, va, words[i]),
        }
    }
}

/// **QUUX's file device** (revision 9, contract Q9): registers 160-171 of
/// the register page, word 100 `<6>`, and commands and responses in two
/// rings in main memory.  The host's side --- the commands run against a
/// folder and their answers written into main memory --- is muir's device
/// here and, on a board, Linux's server; the testbench plays it from the
/// `# fd` lines this generator writes, each a command's completion with the
/// words it wrote.  What the fabric builds is the rest: the registers and
/// their refusals, the indexes, the interrupt, the disable and the reset,
/// the command producer shown to the host only once the write buffer has
/// drained, and the cache invalidated before a response index moves.
///
/// Region 7: slot 0 the register page, slot 1 the rings' page, slot 2 the
/// buffers'.  Into `A[200 + k]`:
///
///   0-1    160 and 161 at the start: disabled and quiet
///   2-3    161 and 160 after an enable with a base off a line: refused
///   4-13   160-171 after an enable with the interrupt enable
///   14     162 after a write while enabled: unchanged
///   15-17  161 after a producer claiming three of two, after a write of
///          160 clears it, and after a consumer past the producer
///   18     the response slot's word 0, read to cache its line
///   19     165 at once after the producer: nothing within the write
///   20-21  100 and 161 when OPEN of `/f` is answered: `<6>`, a handle
///   22-26  the response's words 0-4, through the line cached before it
///   27-28  100 and 161 after 171 is written up to 170
///   29     READ's buffer B's first word, read to cache its line
///   30-35  READ's response words 0 and 1, and B's four words
///   36-37  165 and 161 with two commands posted and the one response slot
///          full: nothing taken
///   38-39  the LOG's response, and an opcode muir lacks: UOP
///   40     161 before the disable, a handle open
///   41-46  160, 161, 164, 165, 170 and 171 after it
///   47-48  100 and 161 after a command answered with the interrupt enable
///          off: `<8>` without `<6>`
///   49     100 with the interrupt enable turned on and the response waiting
///   50-51  160 and 161 after `INTERRUPT-CONTROL<28>` raised and lowered
///          with a command queued and the interrupt up: nothing on QUUX
///          since revision 10 (contract Q11)
///   52-55  160, 161, 165 and 100 after `RESET-DEVICES`, word 104 (the Q9
///          amendment)
///   56     161 again, long after that command's time
fn files_program() -> Prog {
    use muir::file_device::op;
    let mut p = Prog::new();
    let mut c = Pool::new();
    let mut k = 0u64;
    map_region_7(&mut p, &mut c, &[FEATURE_PAGE, FD_RING_PAGE, FD_BUF_PAGE]);
    let reg = |w| r7(0, w);
    let resp = |w| r7(1, (FD_RESP & 0o377) + w);
    let buf = |w| r7(2, w);
    c.rd(&mut p, &mut k, reg(0o160));
    c.rd(&mut p, &mut k, reg(0o161));
    // An enable refused: the command ring's base off a line.
    c.wr(&mut p, reg(0o162), FD_CMD + 1);
    c.wr(&mut p, reg(0o163), 1);
    c.wr(&mut p, reg(0o166), FD_RESP);
    c.wr(&mut p, reg(0o167), 0);
    c.wr(&mut p, reg(0o160), 1);
    c.rd(&mut p, &mut k, reg(0o161));
    c.rd(&mut p, &mut k, reg(0o160));
    // Enabled, with the interrupt enable.
    c.wr(&mut p, reg(0o162), FD_CMD);
    c.wr(&mut p, reg(0o160), 0x101);
    for w in [0o160, 0o161, 0o162, 0o163, 0o164, 0o165, 0o166, 0o167, 0o170, 0o171] {
        c.rd(&mut p, &mut k, reg(w));
    }
    c.wr(&mut p, reg(0o162), 0o77);
    c.rd(&mut p, &mut k, reg(0o162));
    // The index faults.
    c.wr(&mut p, reg(0o164), 3);
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(0o160), 0x101);
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(0o171), 1);
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(0o160), 0x101);
    // OPEN `/f` for reading.
    c.wr(&mut p, buf(0), u32::from_le_bytes([b'/', b'f', 0, 0]));
    c.rd(&mut p, &mut k, resp(0));
    fd_command(&mut p, &mut c, 0, [fd_word0(0x1234, op::OPEN, 0), 0, FD_NAME, 2, 0, 0, 0], Some(1));
    c.rd(&mut p, &mut k, reg(0o165));
    c.poll(&mut p, reg(0o170), 1);
    c.rd(&mut p, &mut k, reg(0o100));
    c.rd(&mut p, &mut k, reg(0o161));
    for w in 0..5 {
        c.rd(&mut p, &mut k, resp(w));
    }
    c.wr(&mut p, reg(0o171), 1);
    c.rd(&mut p, &mut k, reg(0o100));
    c.rd(&mut p, &mut k, reg(0o161));
    // READ sixteen bytes of it into B, whose line is cached first.
    c.rd(&mut p, &mut k, buf(FD_B & 0o377));
    fd_command(&mut p, &mut c, 1, [fd_word0(0x2345, op::READ, 0), 1, 0, 0, FD_B, 16, 0], Some(2));
    c.poll(&mut p, reg(0o170), 2);
    c.rd(&mut p, &mut k, resp(0));
    c.rd(&mut p, &mut k, resp(1));
    for w in 0..4 {
        c.rd(&mut p, &mut k, buf((FD_B & 0o377) + w));
    }
    // Two commands with the one response slot still holding READ's answer:
    // neither is taken until 171 frees it, and then one at a time.
    c.wr(&mut p, buf(FD_LOG & 0o377), u32::from_le_bytes([b'h', b'i', 0, 0]));
    fd_command(&mut p, &mut c, 0, [fd_word0(0x3456, op::LOG, 0), 0, FD_LOG, 2, 0, 0, 0], None);
    fd_command(&mut p, &mut c, 1, [fd_word0(0x4567, 0o77, 0), 0, 0, 0, 0, 0, 0], Some(4));
    p.fill(8);
    c.rd(&mut p, &mut k, reg(0o165));
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(0o171), 2);
    c.poll(&mut p, reg(0o170), 3);
    c.rd(&mut p, &mut k, resp(0));
    c.wr(&mut p, reg(0o171), 3);
    c.poll(&mut p, reg(0o170), 4);
    c.rd(&mut p, &mut k, resp(0));
    c.wr(&mut p, reg(0o171), 4);
    // The disable, with the handle open.
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(0o160), 0);
    for w in [0o160, 0o161, 0o164, 0o165, 0o170, 0o171] {
        c.rd(&mut p, &mut k, reg(w));
    }
    // Enabled again, the bases kept and the interrupt enable off.
    c.wr(&mut p, reg(0o160), 1);
    fd_command(&mut p, &mut c, 0, [fd_word0(0x5678, op::OPEN, 0), 0, FD_NAME, 2, 0, 0, 0], Some(1));
    c.poll(&mut p, reg(0o170), 1);
    c.rd(&mut p, &mut k, reg(0o100));
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(0o160), 0x101);
    c.rd(&mut p, &mut k, reg(0o100));
    // With a command queued, a handle open and the interrupt up:
    // `INTERRUPT-CONTROL<28>` raised and lowered, which on QUUX since
    // revision 10 drives nothing (contract Q11): 160 and 161 read, the
    // device still enabled.  Then `RESET-DEVICES`, word 104 (the Q9
    // amendment), which disables it.
    fd_command(&mut p, &mut c, 1, [fd_word0(0x6789, op::OPEN, 0), 0, FD_NAME, 2, 0, 0, 0], Some(2));
    let (on, off) = (c.c(&mut p, 1 << 28), c.c(&mut p, 0));
    p.to(on, fdest(DEST_INTCTL));
    p.fill(4);
    p.to(off, fdest(DEST_INTCTL));
    p.fill(2);
    c.rd(&mut p, &mut k, reg(0o160));
    c.rd(&mut p, &mut k, reg(0o161));
    c.wr(&mut p, reg(RESET_DEVICES_WORD), 1);
    for w in [0o160, 0o161, 0o165, 0o100] {
        c.rd(&mut p, &mut k, reg(w));
    }
    // Past the dropped command's time: `M[5]` counted down from 400, three
    // microcycles a turn, some 30 us at a K of four.
    let (count, one, zero) = (c.c(&mut p, 0o400), c.c(&mut p, 1), c.c(&mut p, 0));
    p.i(ALU | SETA | a_src(count) | m_dest(5));
    let top = p.at();
    p.i(ALU | SUB | CARRY_IN | m_src(5) | a_src(one) | m_dest(5));
    p.i(JUMP | target(top) | AEQM | INVERT | a_src(zero) | m_src(5) | N);
    p.fill(1);
    c.rd(&mut p, &mut k, reg(0o161));
    assert_eq!(k, FD_READS, "files: the reads counted");
    p.park();
    p
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

fn check_files(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    use muir::file_device::{op, status};
    let r: Vec<u32> = (0..FD_READS).map(|k| m.amem[(RESULT + k) as usize]).collect();
    let file: Vec<u32> =
        FD_FILE.chunks(4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
    let resp0 = |tag: u32, st: u32, opcode: u32| tag | st << 16 | opcode << 24;
    assert_eq!(&r[0..2], &[0, 2], "QUUX: 160 and 161 at power-on: disabled, quiet");
    assert_eq!(&r[2..4], &[2 | 4, 0], "QUUX: an enable refused, a base off a line");
    assert_eq!(
        &r[4..14],
        &[0x101, 1, FD_CMD, 1, 0, 0, FD_RESP, 0, 0, 0],
        "QUUX: 160-171 enabled"
    );
    assert_eq!(r[14], FD_CMD, "QUUX: a base written while enabled is ignored");
    assert_eq!(&r[15..18], &[1 | 8, 1, 1 | 8], "QUUX: the index faults and their clear");
    assert_eq!(r[18], 0, "QUUX: the response slot before any response");
    assert_eq!(r[19], 0, "QUUX: nothing answered within the producer write");
    assert_eq!(&r[20..22], &[1 << 6, 1 | 0x100 | 1 << 16], "QUUX: OPEN answered, a handle open");
    assert_eq!(
        &r[22..27],
        &[resp0(0x1234, status::OK, op::OPEN), 0, 1, FD_FILE.len() as u32, FD_MTIME],
        "QUUX: OPEN's response, through a line cached before it"
    );
    assert_eq!(&r[27..29], &[0, 1 | 1 << 16], "QUUX: the response consumed");
    assert_eq!(r[29], 0, "QUUX: B before the READ");
    assert_eq!(&r[30..32], &[resp0(0x2345, status::OK, op::READ), 16], "QUUX: READ's response");
    assert_eq!(&r[32..36], &file[..], "QUUX: READ's bytes, through B's line cached before");
    assert_eq!(&r[36..38], &[2, 1 | 0x100 | 1 << 16], "QUUX: the response ring full: nothing taken");
    assert_eq!(r[38], resp0(0x3456, status::OK, op::LOG), "QUUX: LOG");
    assert_eq!(r[39], resp0(0x4567, status::UOP, 0o77), "QUUX: an opcode muir lacks");
    assert_eq!(r[40], 1 | 1 << 16, "QUUX: before the disable, a handle open");
    assert_eq!(&r[41..47], &[0, 2, 0, 0, 0, 0], "QUUX: the disable is the reset");
    assert_eq!(&r[47..49], &[0, 1 | 0x100 | 1 << 16], "QUUX: a response with the interrupt enable off");
    assert_eq!(r[49], 1 << 6, "QUUX: the interrupt enable turned on with a response waiting");
    assert_eq!(r[50], 0x101, "QUUX: <28> leaves it enabled");
    assert_ne!(r[51] >> 16 & 0xff, 0, "QUUX: <28> leaves its handle open");
    assert_eq!(&r[52..56], &[0, 2, 0, 0], "QUUX: reset devices disables it");
    assert_eq!(r[56], 2, "QUUX: the command the reset dropped never answers");
    assert_eq!(m.file_device.handles_open(), 0, "QUUX: every handle closed");
    assert_eq!(m.file_device.queued(), 0, "QUUX: nothing queued");
}

fn check_unibus(which: Which, m: &muir::machine::Machine) {
    assert_eq!(which, Which::Cadr, "unibus: the CADR's alone");
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

fn cycles(name: &str, which: Which) -> u64 {
    match name {
        "clocks" if which == Which::Cadr => 1600,
        "busreset" if which == Which::Quux => 1200,
        "map" => 450,
        "tv" => 560,
        "muldiv" => 540,
        "tick" => 1350,
        "ticksync" => 1350 + 3 * (TICKSYNC_CLEARED_READS - TICK_CLEARED_READS),
        "divmd" => 900,
        "divmdsync" => 3000,
        "pdlsync" => 300,
        "imemsync" => 800,
        "tickwait" => 2600,
        "clocks" => CLOCKS_ROWS,
        "page" => 1800,
        "clockwait" => 1400,
        "tickwin" => 2000,
        "memedge" => 2800,
        "busreset" => 700,
        "startstart" => 600,
        "rtc" => RTC_ROWS,
        "files" => FILES_ROWS,
        "unibus" => 3000,
        _ => unreachable!(),
    }
}

/// The two programs of revision 9, run to their park and a little past it.
const RTC_ROWS: u64 = 400;
const FILES_ROWS: u64 = 2800;

/// The clocks program on QUUX parks at microcycle 6,239 at a K of four; the
/// CADR parks after its first few words.
const CLOCKS_ROWS: u64 = 6_500;

fn program(name: &str) -> Prog {
    match name {
        "map" => map_program(),
        "tv" => tv_program(),
        "muldiv" => muldiv_program(),
        "tick" => tick_program(),
        "ticksync" => tick_program_with(TICKSYNC_CLEARED_READS),
        "divmd" => divmd_program(),
        "divmdsync" => divmdsync_program(),
        "pdlsync" => pdlsync_program(),
        "imemsync" => imemsync_program(),
        "tickwait" => tickwait_program(),
        "clocks" => clocks_program(),
        "page" => page_program(),
        "clockwait" => clockwait_program(),
        "tickwin" => tickwin_program(),
        "memedge" => memedge_program(),
        "busreset" => busreset_program(),
        "startstart" => startstart_program(),
        "rtc" => rtc_program(),
        "files" => files_program(),
        "unibus" => unibus_program(),
        _ => {
            eprintln!("quux: no program `{name}`; the programs are: map, tv, muldiv, tick, ticksync, divmd, divmdsync, pdlsync, imemsync, tickwait, clocks, tickwin, page, clockwait, memedge, busreset, startstart, unibus, rtc, files");
            std::process::exit(2);
        }
    }
}

/// The `files` program's folder: `/f`, sixteen bytes, with a fixed
/// modification time, under the generator's own build tree so that nothing
/// of it lands in `/tmp`.  One a process, removed at the end.
fn files_scratch() -> std::io::Result<std::path::PathBuf> {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join(format!("quux-files-scratch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    let f = dir.join("f");
    std::fs::write(&f, FD_FILE)?;
    let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(FD_MTIME as u64);
    std::fs::File::options().write(true).open(&f)?.set_modified(when)?;
    Ok(dir)
}

/// What the host did in the microcycle just run, for the testbench:
///
///   `# fdtake START INDEX`  the device took command INDEX, from START ns ---
///                           the later of its producer write landing with
///                           the write buffer empty, the previous
///                           command's completion, and a response slot free
///   `# fdc PHYS WORD`       and the command's entry as main memory held it,
///                           which the host reads once it sees the producer
///   `# fd DUE PROD HANDLES` a command completed at DUE ns: the response
///                           producer is PROD and HANDLES are open
///   `# fdw PHYS WORD`       and each word it wrote: the response entry, and
///                           buffer B's words for READ, DIRECTORY and COMPLETE
///
/// All hexadecimal.  muir runs a command at its due time and the fabric's
/// host runs it when it can; the testbench does it at the due time, so the
/// two agree to the tick.
fn fd_events(e: &muir::rtl::Rtl, prod_before: u16, due_before: Option<u64>, last_due: &mut Option<u64>) {
    use muir::file_device::{self as fd, op};
    let m = e.machine();
    let dev = &m.file_device;
    let ns = e.ns();
    let (cmd_base, cmd_n) = (dev.read(fd::CMD_BASE, ns), 1u32 << dev.read(fd::CMD_SIZE, ns));
    let (resp_base, resp_n) = (dev.read(fd::RESP_BASE, ns), 1u32 << dev.read(fd::RESP_SIZE, ns));
    let prod = dev.response_producer();
    // A disable or a machine reset puts the indexes back to 0, which is no
    // completion.
    if prod != prod_before && prod == 0 {
        assert_eq!(dev.read(fd::CONTROL, ns) & 1, 0, "files: the indexes went back to 0 only by a disable");
    } else if prod != prod_before {
        assert_eq!(prod, prod_before.wrapping_add(1), "files: one command completes a microcycle");
        let due = due_before.expect("files: a completion with no command taken");
        println!("# fd {due:x} {prod:x} {:x}", dev.handles_open());
        let i = prod.wrapping_sub(1) as u32;
        let r = resp_base + 8 * (i % resp_n);
        let c = cmd_base + 8 * (i % cmd_n);
        let entry = |a: u32| m.main[a as usize];
        for w in 0..8 {
            println!("# fdw {:x} {:x}", r + w, entry(r + w));
        }
        let (opcode, st) = ((entry(c) >> 16) & 0xff, (entry(r) >> 16) & 0xff);
        if st == 0 && matches!(opcode, op::READ | op::DIRECTORY | op::COMPLETE) {
            let b = entry(c + 4);
            for w in 0..entry(r + 1).div_ceil(4) {
                println!("# fdw {:x} {:x}", b + w, entry(b + w));
            }
        }
    }
    let due = dev.head_due();
    if due.is_some() && due != *last_due {
        let d = due.unwrap();
        let c = cmd_base + 8 * (prod as u32 % cmd_n);
        let start = d - (fd::due(0, m.main[c as usize + 3], m.main[c as usize + 5]));
        println!("# fdtake {start:x} {prod:x}");
        for w in 0..8 {
            println!("# fdc {:x} {:x}", c + w, m.main[(c + w) as usize]);
        }
    }
    *last_due = due;
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    BASE.store(prom_base(which), std::sync::atomic::Ordering::Relaxed);
    // A PROM image is the same at every timing, so it is asked for without one.
    let timing = if args.iter().any(|a| a == "--prom") && !args.iter().any(|a| a == "--sync-cycle-ticks") {
        muir::clock::TimingModel::Fpga
    } else {
        machine_axis::take_timing(which, &mut args)
    };
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
        eprintln!(
            "usage: quux --program <name> [--machine cadr|quux] \
             [--sync-cycle-ticks K [--sync-ilong-ticks L]] [--prom]"
        );
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

    let mut e = trace::engine_on(which.machine(&prom), timing);
    e.boot();
    println!("{}", trace::COLUMNS);
    println!(
        "# generated by golden/src/quux.rs from muir's rtl engine: program {name}, machine: {}{}",
        which.name(),
        machine_axis::timing_suffix(which, timing)
    );
    println!("{}", trace::RADIX);
    let n = cycles(&name, which);
    // **KEY WORDS ON THE CABLE**, pressed when the program first reaches
    // each mark, before the microcycle there: `# key` lines ahead of the
    // rows say at which microcycle, for the testbench to put the same words
    // on the fabric's cable (`tb/cadr_machine_tb.cpp`).  The page program
    // alone presses any.
    let mut presses: Vec<(u64, Vec<u32>)> = Vec::new();
    if name == "page" && which == Which::Quux {
        let (_, m1, m2) = page_program_marks();
        let mut probe = trace::engine_on(which.machine(&prom), timing);
        probe.boot();
        let mut pt = trace::Trace::new(&probe);
        let mut pending = vec![(m1, PAGE_KEYS_1.to_vec()), (m2, (0..PAGE_KEYS_2).map(page_key_2).collect())];
        for cycle in 0..n {
            if let Some(i) = pending.iter().position(|(at, _)| probe.pc() as u64 == *at) {
                let (_, words) = pending.remove(i);
                for &w in &words {
                    probe.machine_mut().quux_input.press(w);
                }
                presses.push((cycle, words));
            }
            if pt.row(&mut probe, cycle).is_err() {
                break;
            }
        }
        assert!(pending.is_empty(), "page: the program reached both marks");
        for (cycle, words) in &presses {
            for w in words {
                println!("# key {cycle:x} {w:x}");
            }
        }
    }
    // **THE REAL-TIME CLOCK'S START**, `machine_axis::RTC_START`, which the
    // testbench loads into the fabric's counter at reset as Linux sets it at
    // boot on a board.
    if which == Which::Quux {
        println!("# rtc {:x}", machine_axis::RTC_START);
    }
    // **THE HOST SETS THE CLOCK AT THE `rtc` PROGRAM'S MARKS**, before the
    // microcycle there: `# rtcset CYCLE SECONDS` for the testbench, which
    // writes the same seconds through the host side at the same microcycle.
    let rtc_marks = if name == "rtc" && which == Which::Quux { rtc_program_marks().1.to_vec() } else { vec![] };
    let mut rtc_sets = rtc_marks.iter().copied().zip(RTC_SET).collect::<Vec<_>>();
    // **THE FILE DEVICE'S HOST SIDE**, muir's device here: a folder with one
    // file in it, `/f`, and every command's completion written out for the
    // testbench, which plays Linux's server from it (`# fd` and `# fdw`).
    let files = name == "files" && which == Which::Quux;
    let scratch = files.then(|| files_scratch().expect("files: the scratch folder"));
    if let Some(dir) = &scratch {
        e.machine_mut().file_device.mounts.add(dir.to_str().unwrap()).expect("files: the mount");
    }
    let mut last_due: Option<u64> = None;
    let mut t = trace::Trace::new(&e);
    for cycle in 0..n {
        if let Some((_, words)) = presses.iter().find(|(c, _)| *c == cycle) {
            for &w in words {
                e.machine_mut().quux_input.press(w);
            }
        }
        if let Some(i) = rtc_sets.iter().position(|&(at, _)| e.pc() as u64 == at) {
            let (_, secs) = rtc_sets.remove(i);
            let ns = e.ns();
            e.machine_mut().rtc = muir::machine::Rtc::Counted { start: secs, base_ns: ns };
            println!("# rtcset {cycle:x} {secs:x}");
        }
        let (prod_before, due_before) = (e.machine().file_device.response_producer(), e.machine().file_device.head_due());
        match t.row(&mut e, cycle) {
            Ok(line) => println!("{line}"),
            Err(h) => {
                eprintln!("quux: {name} stopped at microcycle {cycle}: {h:?}");
                std::process::exit(1);
            }
        }
        if files {
            fd_events(&e, prod_before, due_before, &mut last_due);
        }
    }
    assert!(rtc_sets.is_empty(), "rtc: the program reached both marks");
    if let Some(dir) = scratch {
        let _ = std::fs::remove_dir_all(dir);
    }
    match name.as_str() {
        "map" => check_map(which, e.machine()),
        "tv" => check_tv(which, e.machine()),
        "muldiv" => check_muldiv(which, e.machine()),
        "tick" => check_tick(which, e.machine(), TICK_CLEARED_READS),
        "ticksync" => check_tick(which, e.machine(), TICKSYNC_CLEARED_READS),
        "divmd" => check_divmd(which, e.machine()),
        "divmdsync" => check_divmdsync(which, e.machine()),
        "pdlsync" => check_pdlsync(which, e.machine()),
        "imemsync" => check_imemsync(which, e.machine()),
        "tickwait" => check_tickwait(which, e.machine()),
        "clocks" => check_clocks(which, e.machine()),
        "page" => check_page(which, e.machine()),
        "clockwait" => check_clockwait(which, e.machine()),
        "tickwin" => check_tickwin(which, e.machine()),
        "memedge" => check_memedge(which, e.machine()),
        "busreset" => check_busreset(which, e.machine()),
        "startstart" => check_startstart(which, e.machine()),
        "rtc" => check_rtc(which, e.machine()),
        "files" => check_files(which, e.machine()),
        "unibus" => check_unibus(which, e.machine()),
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
