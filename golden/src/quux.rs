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
        assert!(!m.tick.enabled, "QUUX: the tick is off at the end");
        let cleared = &reads[130..130 + cleared_reads as usize];
        let up = cleared.iter().filter(|&&w| w == 3).count();
        assert!(up >= 3 && up < cleared.len() / 2, "QUUX: the cleared segment saw {up} rises");
    } else {
        assert!(reads.iter().all(|&w| w == !0), "CADR: source 17 reads all ones");
    }
}

// ---------------------------------------------------------------- clocks

/// Functional destinations 2, 3 and 4: `INTERRUPT-CONTROL`, the clocks'
/// control and the interval timer's period.
const DEST_INTCTL: u64 = 2;
const DEST_CLOCKS: u64 = 3;
const DEST_PERIOD: u64 = 4;
/// Destination 3's bits: the tick's enable and clear, the interval timer's.
const TICK_ON: u32 = 1;
const TICK_CLEAR: u32 = 2;
const INTERVAL_ON: u32 = 4;
const INTERVAL_CLEAR: u32 = 8;

/// The interval timer's cleared segment's reads, as `ticksync` had them.
const CLOCKS_CLEARED_READS: u64 = 120;
/// Where the microsecond clock's reads land, over and over.
const USEC_AT: u64 = 0o710;

/// **QUUX's clocks in the processor** (revision 5, contract Q1).
///
/// Source 17 is read into `A[200 + k]` and source 15 into `A[710]` at every
/// step, and between the reads a jump on condition 5 to the next word puts
/// the interrupt either timer raises on `JCOND`: the interval timer's period
/// written while it is off, the timer enabled, running across rises, a
/// clear with its flag up, the interrupt enabled, periods written while it
/// runs --- one of 5, one of 3, and 0, which stops it --- a period of 1
/// cleared every third microcycle, and the timer turned off.  Then the tick,
/// fixed at 60 Hz: enabled, waited for with source 17 read in a loop until
/// its flag is up, 16,667 us later, read, cleared and turned off.  So the
/// trace runs 16.7 ms of QUUX's time.  On the CADR the same program reads
/// all ones from both sources and its writes of destinations 3 and 4 write
/// M alone, so the loop that waits for the tick's flag leaves at once.
fn clocks_program() -> Prog {
    let mut p = Prog::new();
    let mut k = 0u64;
    let reads = |p: &mut Prog, k: &mut u64, n: u32| {
        for _ in 0..n {
            p.source(0o17, RESULT + *k);
            *k += 1;
            p.source(0o15, USEC_AT);
            let here = p.at();
            p.i(JUMP | target(here + 1) | PGF_OR_INT);
        }
    };
    let control = |p: &mut Prog, a: u64, v: u32| {
        p.konst(a, v);
        p.to(a, fdest(DEST_CLOCKS));
    };
    reads(&mut p, &mut k, 2);
    // The period written with the timer off: it starts nothing.
    p.konst(0o700, TICK_US);
    p.to(0o700, fdest(DEST_PERIOD));
    reads(&mut p, &mut k, 2);
    control(&mut p, 0o701, INTERVAL_ON);
    reads(&mut p, &mut k, 24);
    // A clear, the enable kept: the flag is up by now.
    control(&mut p, 0o702, INTERVAL_ON | INTERVAL_CLEAR);
    reads(&mut p, &mut k, 6);
    // The interrupt enabled, `INTERRUPT-CONTROL<27>`.
    p.konst(0o703, 1 << 27);
    p.to(0o703, fdest(DEST_INTCTL));
    reads(&mut p, &mut k, 12);
    // A period of 5 written while it runs: the next rise from now.
    p.konst(0o705, 5);
    p.to(0o705, fdest(DEST_PERIOD));
    reads(&mut p, &mut k, 24);
    // A period of 3 written while it runs, then 0, which stops it with its
    // flag down whatever it was.
    p.konst(0o704, TICK_ON_A_BOUNDARY_US);
    p.to(0o704, fdest(DEST_PERIOD));
    reads(&mut p, &mut k, 30);
    p.konst(0o711, 0);
    p.to(0o711, fdest(DEST_PERIOD));
    reads(&mut p, &mut k, 30);
    // A period of 1 cleared at every third microcycle and read two after, so
    // that a read sees a rise only in the ticks after the clear lands.
    p.konst(0o706, 1);
    p.to(0o706, fdest(DEST_PERIOD));
    p.konst(0o707, INTERVAL_ON | INTERVAL_CLEAR);
    for _ in 0..CLOCKS_CLEARED_READS {
        p.to(0o707, fdest(DEST_CLOCKS));
        p.fill(1);
        p.source(0o17, RESULT + k);
        k += 1;
    }
    // Turned off.
    control(&mut p, 0o712, 0);
    reads(&mut p, &mut k, 4);
    // The tick, at 60 Hz: enabled, and waited for.
    control(&mut p, 0o713, TICK_ON);
    reads(&mut p, &mut k, 2);
    let wait = p.at();
    p.i(ALU | SETM | src(0o17) | m_dest(2));
    p.i(JUMP | target(wait + 3) | bit(0) | m_src(2) | N);
    p.i(JUMP | target(wait) | ALWAYS | N);
    reads(&mut p, &mut k, 4);
    control(&mut p, 0o714, TICK_ON | TICK_CLEAR);
    reads(&mut p, &mut k, 4);
    control(&mut p, 0o715, 0);
    reads(&mut p, &mut k, 2);
    assert_eq!(k, CLOCKS_READS, "clocks: the reads counted");
    p.park();
    p
}

/// How many reads of source 17 the clocks program stores.
const CLOCKS_READS: u64 = 2 + 2 + 24 + 6 + 12 + 24 + 30 + 30 + CLOCKS_CLEARED_READS + 4 + 2 + 4 + 4 + 2;

fn check_clocks(which: Which, m: &muir::machine::Machine) {
    let reads: Vec<u32> = (0..CLOCKS_READS).map(|k| m.amem[(RESULT + k) as usize]).collect();
    if which != Which::Quux {
        assert!(reads.iter().all(|&w| w == !0), "CADR: source 17 reads all ones");
        assert_eq!(m.amem[USEC_AT as usize], !0, "CADR: source 15 reads all ones");
        return;
    }
    assert_eq!(&reads[..4], &[0, 0, 0, 0], "QUUX: both off read 0");
    assert!(reads.contains(&0b1100), "QUUX: the interval timer's flag was seen up");
    assert!(reads.contains(&0b1000), "QUUX: and down while enabled");
    let cleared = &reads[134..134 + CLOCKS_CLEARED_READS as usize];
    let up = cleared.iter().filter(|&&w| w == 0b1100).count();
    assert!(up >= 3 && up < cleared.len() / 2, "QUUX: the cleared segment saw {up} rises");
    let n = reads.len();
    assert_eq!(&reads[n - 16..n - 12], &[0, 0, 0, 0], "QUUX: the interval timer off");
    assert_eq!(&reads[n - 12..n - 10], &[2, 2], "QUUX: the tick enabled, its flag down");
    assert_eq!(reads[n - 10] & 3, 3, "QUUX: the tick's flag up after its wait");
    assert_eq!(reads[n - 6] & 3, 2, "QUUX: the tick's flag cleared");
    assert_eq!(&reads[n - 2..], &[0, 0], "QUUX: the tick off");
    assert!(!m.tick.enabled && !m.tick.interval_enabled, "QUUX: both off at the end");
    let us = m.amem[USEC_AT as usize];
    assert!(us >= 16_667, "QUUX: the microsecond clock read {us} after the tick");
}

/// **THE WINDOW BETWEEN A FLAG'S RISE AND THE EDGE `SINTR` IS TAKEN AT**
/// (muir's `1775bba`, `a_flag_rising_during_a_wait_is_seen_by_the_jump_after`):
/// `SINTR` is registered at the edge that ends each executed microcycle,
/// waiting or not, with the flags as they stand at that edge.  At a K of four
/// and an L of zero every edge and every rise is on a multiple of 40 ns, so a
/// rise is never strictly inside a microcycle and a fabric that took the
/// flags a tick or two before the edge could not be told apart.  An `ILONG`
/// microcycle at an L of one is 50 ns, so a program of `ILONG`s and plain
/// microcycles moves the edges 10 ns at a time against the rise.
///
/// The interval timer runs with the interrupt enabled, and every trial
/// writes its period, 1 us, which starts it again from that edge; then:
///
///   - `TICKWIN_PLAIN`: `f` observations made `ILONG` and then fourteen plain
///     ones, `f` from 0 to 3, which puts the rise 0, 30, 20 and 10 ns before
///     an edge at an L of one;
///   - `TICKWIN_WAITS`: `g` observations, `s` of them `ILONG`, a read's start,
///     an observation, a read of `MD`, which waits for the word, and three
///     observations; `g` slides the wait over the rise and `s` the edges.
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

fn tickwin_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    p.konst(0o703, 1 << 27);
    p.to(0o703, fdest(DEST_INTCTL));
    p.konst(0o704, 1);
    p.konst(0o700, INTERVAL_ON);
    p.to(0o700, fdest(DEST_CLOCKS));
    let cj = |p: &mut Prog, ilong: bool| {
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N | if ilong { 1 << 45 } else { 0 });
        p.fill(1);
    };
    for f in TICKWIN_PLAIN {
        p.to(0o704, fdest(DEST_PERIOD));
        for _ in 0..f {
            cj(&mut p, true);
        }
        for _ in 0..TICKWIN_PLAIN_JUMPS {
            cj(&mut p, false);
        }
    }
    for &g in &TICKWIN_WAIT_GAPS {
        for s in 0..TICKWIN_WAIT_SHIFTS {
            p.to(0o704, fdest(DEST_PERIOD));
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
    }
    p.konst(0o705, 0);
    p.to(0o705, fdest(DEST_CLOCKS));
    p.park();
    p
}

/// **THE CLOCKS READ IN THE TICKS BETWEEN THE EDGES**, QUUX's alone, at an L of
/// zero and one.  At a K of four and an L of zero every microcycle starts on
/// a multiple of 40 ns and every microsecond is 25 of them, so a microsecond
/// clock a tick or two off never crosses a boundary where a read can see it;
/// with `ILONG`s at an L of one the reads start 10 ns apart against it.
///
///   - `CLOCKWAIT_USEC` pairs of an `ILONG` filler and a read of source 15;
///   - the interval timer at 1 us, restarted each trial, a read's start after
///     `g` fillers, then source 17 written into `MD` by a microcycle that
///     `-WAIT` holds until the read is done, and `MD` kept in `A[200 + k]`:
///     the status a held microcycle reads is the one at the master clock edge
///     it finally runs from, so a rise during the wait is in it.
const CLOCKWAIT_USEC: usize = 150;
const CLOCKWAIT_GAPS: std::ops::RangeInclusive<usize> = 0..=14;

fn clockwait_program() -> Prog {
    let mut p = Prog::new();
    wait_setup(&mut p, 0o777);
    for _ in 0..CLOCKWAIT_USEC {
        p.i(filler().raw() | 1 << 45);
        p.source(0o15, USEC_AT);
    }
    p.konst(0o704, 1);
    p.konst(0o700, INTERVAL_ON);
    p.to(0o700, fdest(DEST_CLOCKS));
    let mut k = 0u64;
    for g in CLOCKWAIT_GAPS {
        // **A LINE OF ITS OWN FOR EACH READ**, so each misses the cache and
        // waits a line fill's 380 ns (contract Q6): the same word again would
        // hit in 20 ns, and a wait that short holds the microcycle over no
        // rise of a 1 us timer at any gap.
        p.konst(0o306, (7 << 13) | ((4 * (k as u32) + 4) & 0o377));
        p.to(0o704, fdest(DEST_PERIOD));
        p.fill(g);
        p.to(0o306, START_READ);
        p.fill(1);
        p.i(ALU | SETM | src(0o17) | MD);
        p.i(ALU | SETM | SRC_MD | a_dest(RESULT + k));
        k += 1;
    }
    p.konst(0o705, 0);
    p.to(0o705, fdest(DEST_CLOCKS));
    p.park();
    p
}

fn check_clockwait(which: Which, m: &muir::machine::Machine) {
    if which != Which::Quux {
        return;
    }
    let n = CLOCKWAIT_GAPS.count() as u64;
    let r: Vec<u32> = (0..n).map(|k| m.amem[(RESULT + k) as usize]).collect();
    assert!(r.contains(&0b1100) && r.contains(&0b1000), "QUUX: the held status saw the flag both ways: {r:?}");
    assert!(m.amem[USEC_AT as usize] > 0, "QUUX: the microsecond clock was read");
}

fn check_tickwin(which: Which, m: &muir::machine::Machine) {
    if which == Which::Quux {
        assert!(!m.tick.interval_enabled, "QUUX: the interval timer is off at the end");
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
///   - the interval timer at 2 us, waited for: 100 with `<1>`;
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
/// interval timer and the network raise here, so `SINTR` moves on the rows
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
    let rd = |p: &mut Prog, k: &mut u64, w: u32| {
        p.konst(0o304, va(0, w));
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
    for w in [0o100, 0o101, 0o102] {
        rd(&mut p, &mut k, w);
    }
    // The keyboard.
    p.konst(0o703, 1 << 27);
    p.to(0o703, fdest(DEST_INTCTL));
    wr(&mut p, va(0, 0o120), 1 << 8);
    let mark_1 = p.at();
    p.fill(8);
    for w in [0o120, 0o100, 0o121, 0o121, 0o121, 0o121, 0o120, 0o100] {
        rd(&mut p, &mut k, w);
    }
    let mark_2 = p.at();
    p.fill(40);
    rd(&mut p, &mut k, 0o120);
    wr(&mut p, va(0, 0o120), 1 << 8);
    rd(&mut p, &mut k, 0o120);
    // The mouse, at rest.
    wr(&mut p, va(0, 0o123), 1 << 8);
    rd(&mut p, &mut k, 0o122);
    rd(&mut p, &mut k, 0o123);
    // A bus error, and its clear.
    p.konst(0o306, va(1, 0));
    p.read(0o306, 0o306);
    rd(&mut p, &mut k, 0o101);
    wr(&mut p, va(0, 0o101), 0o7777);
    rd(&mut p, &mut k, 0o101);
    // Error stop.
    wr(&mut p, va(0, 0o102), 1);
    rd(&mut p, &mut k, 0o102);
    wr(&mut p, va(0, 0o102), 0);
    rd(&mut p, &mut k, 0o102);
    // The interval timer.
    p.konst(0o704, 2);
    p.to(0o704, fdest(DEST_PERIOD));
    p.konst(0o700, INTERVAL_ON);
    p.to(0o700, fdest(DEST_CLOCKS));
    for _ in 0..30 {
        let here = p.at();
        p.i(JUMP | target(here + 2) | PGF_OR_INT | N);
        p.fill(1);
    }
    rd(&mut p, &mut k, 0o100);
    p.konst(0o701, 0);
    p.to(0o701, fdest(DEST_CLOCKS));
    // The keyboard's and the mouse's interrupts off, so that the network's
    // request is the only thing up on `SINTR` below (muir's `3ceb4f7`).
    wr(&mut p, va(0, 0o120), 0);
    wr(&mut p, va(0, 0o123), 0);
    // The network: Clear Transmitter, `<8>`, and the transmit interrupt
    // enable, `<5>`.
    wr(&mut p, va(0, 0o140), (1 << 8) | (1 << 5));
    rd(&mut p, &mut k, 0o140);
    for w in [0o100, 0o141, 0o142, 0o143, 0o144, 0o146] {
        rd(&mut p, &mut k, w);
    }
    wr(&mut p, va(0, 0o141), 0o52525);
    rd(&mut p, &mut k, 0o140);
    rd(&mut p, &mut k, 0o100);
    wr(&mut p, va(0, 0o140), 0);
    // **QUUX HAS NO UNIBUS** (contract Q5): the same register at Unibus
    // `764140`, through slot 2, times out as empty Xbus space and sets the
    // Xbus NXM bit, and a write there changes nothing: 101 after the read,
    // cleared, a write of the CSR's Clear Transmitter and its enable there,
    // 101 and 100 after it.
    wr(&mut p, va(0, 0o101), 0);
    p.konst(0o307, va(2, PAGE_UNIBUS_CHAOS & 0o377));
    p.read(0o307, RESULT + k);
    k += 1;
    rd(&mut p, &mut k, 0o101);
    wr(&mut p, va(0, 0o101), 0);
    wr(&mut p, va(2, PAGE_UNIBUS_CHAOS & 0o377), (1 << 8) | (1 << 5));
    rd(&mut p, &mut k, 0o101);
    rd(&mut p, &mut k, 0o100);
    // Reserved words.
    rd(&mut p, &mut k, 0o103);
    rd(&mut p, &mut k, 0o150);
    assert_eq!(k, PAGE_READS, "page: the reads counted");
    p.park();
    (p, mark_1, mark_2)
}

const PAGE_READS: u64 = 3 + 8 + 2 + 2 + 2 + 2 + 1 + 1 + 6 + 2 + 4 + 2;

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
    assert_eq!(r[19] & 2, 2, "QUUX: 100, the interval timer");
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
    // its MACHINE-ID on 16 and 36, and its clocks' status on 17, both off.
    let want = if quux {
        let id = id.unwrap();
        [0, id, id, 0]
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
        assert!(!m.tick.enabled, "QUUX: the tick is off at the end");
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
/// CADR an eighth, the interface's interrupt status.
fn busreset_reads(quux: bool) -> u64 {
    if quux { 7 } else { 8 }
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
    let mut order = vec![va(0, DISK_STATUS), va(0, DISK_CLP), va(0, DISK_DA), va(0, TV_CONTROL), chaos, fifth,
                         va(0, DISK_STATUS)];
    if !quux {
        order.push(va(3, INTERRUPT_STATUS_WORD));
    }
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
    for _ in 0..2 {
        for &addr in &order {
            rd(&mut p, &mut k, addr);
        }
        if k == reads {
            reset(&mut p);
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
    assert_eq!(k, 2 * reads + if quux { 0 } else { 2 }, "busreset: the reads counted");
    p.park();
    p
}

fn check_busreset(which: Which, m: &muir::machine::Machine) {
    let r = |k: u64| m.amem[(RESULT + k) as usize];
    let n = busreset_reads(which == Which::Quux);
    let after = |k: u64| r(n + k);
    // Before: the disk's done interrupt requested, the Chaosnet
    // interface's transmit interrupt enabled.
    assert_ne!(r(0) & (1 << 3), 0, "{which:?}: the disk's done interrupt, before the reset");
    // After: the command's enable gone and with it the request, the
    // network's enable gone, the disk address standing.
    assert_eq!(after(0) & (1 << 3), 0, "{which:?}: the disk's done interrupt, after the reset");
    assert_eq!(after(6), after(0), "{which:?}: the disk's status, read twice after the reset");
    assert!(!m.interrupt(), "{which:?}: nothing interrupts after the reset");
    if which == Which::Quux {
        assert_eq!(r(0), 0o21011, "QUUX: block-disk stopped by error, its interrupt requested, no pack");
        assert_eq!(after(0), 0o1001, "QUUX: block-disk not active, no pack, the error cleared");
        assert_eq!((r(2), after(2)), (0o5670, 0o5670), "QUUX: the disk address has no pin on -XBUS INIT");
        assert_eq!((r(5), after(5)), (0o44, 0), "QUUX: word 100, the disk and the network, then nothing");
        assert_ne!(r(4) & (1 << 5), 0, "QUUX: the network's enable, before the reset");
        assert_eq!(after(4) & (1 << 5), 0, "QUUX: the network's enable, after the reset");
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
        "unibus" => 3000,
        _ => unreachable!(),
    }
}

/// The clocks program runs until the tick's first rise, 16,667 us in: at a K
/// of four that is 416,675 microcycles, and the CADR leaves its loop at once.
const CLOCKS_ROWS: u64 = 418_200;

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
        "unibus" => unibus_program(),
        _ => {
            eprintln!("quux: no program `{name}`; the programs are: map, tv, muldiv, tick, ticksync, divmd, divmdsync, pdlsync, imemsync, tickwait, clocks, tickwin, page, clockwait, memedge, busreset, unibus");
            std::process::exit(2);
        }
    }
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
    let mut t = trace::Trace::new(&e);
    for cycle in 0..n {
        if let Some((_, words)) = presses.iter().find(|(c, _)| *c == cycle) {
            for &w in words {
                e.machine_mut().quux_input.press(w);
            }
        }
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
