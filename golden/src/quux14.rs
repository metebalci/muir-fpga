// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **QUUX revision 14** (contract G3 revision 14, with its appendix A14), as
//! programs in the boot PROM, traced on muir's `rtl` engine on
//! `Geometry::QUUX_14`.
//!
//!     quux14 --program <name> --sync-cycle-ticks K [--sync-ilong-ticks L]
//!     quux14 --program <name> --prom
//!
//! Each program is a group of the scenarios muir's own
//! `tests/revision_14.rs` holds revision 14 to, written again here without
//! presets, in `golden/src/trace.rs`'s columns, which `tb/cadr_machine_tb.cpp`
//! compares row for row against the whole machine built at `WORD_BITS` 40
//! and `REVISION` 14 with the same PROM image:
//!
//!   windows   the physical memory window, which never touches the TLB and
//!             aliases a translated frame coherently, and sets no bit in a
//!             page's entry where the translated references set accessed
//!             and modified
//!   space     the device window: frame buffer 0, the register page and its
//!             feature words 0, 1, 2 and 13; nothing past main memory and in
//!             the reserved slices; A memory's window, status 7
//!   walk      two pages sharing an index, pages either side of 2^31, a
//!             stale entry kept until its invalidation, a direct write and
//!             an empty, a revision-13 map-write word and an operation at a
//!             window address doing nothing
//!   noentry   no directory (base 0), and the no-entry results: a missing
//!             directory entry, a status-0 entry, a frame past main memory,
//!             status 7 in a table, the retired status 3 loaded as in core;
//!             a not-in-core entry loaded, `MAP(MD)` reading it unwalked
//!   empty, empty8k
//!             the sweep: the reset's and an empty's, N ticks each, at 4,096
//!             entries and at 8,192 (`TLB_ENTRIES`)
//!   mapmd     `MAP(MD)` on a fixnum and on every fixed entry; a dispatch on
//!             map bits that looks up for a pointer type only
//!   lc        LC at 34 bits and its adder (L1-L7, across 2^31) and
//!             condition 12
//!   fetch     the stepper's carry and a fetch's `VMA`, `LC<33:2>` (L8),
//!             with the prefetch fitted
//!   words     register-page words 220-224, the program setting the
//!             directory base and reading through it
//!   writeback accessed by the first reference, modified by the first
//!             write, the write-back an OR that keeps the table's bits, the
//!             guard and word 224
//!   setter, setter0
//!             the ephemeral-reference setter, its enable 1 and 0
//!   wbhold    a write-back that holds the reference behind the write buffer
//!   redirect  the PDL buffer redirect at off 0, n - 1, n and n + 1, its
//!             copies snooped from A 430 and 431 a microcycle before a
//!             start, an access-11 fiddle that goes to memory, across 2^31,
//!             and a second inside read's held microcycle
//!   fiddle    E1 and E2: a port-B fill evicting a direct write at status 5
//!             and at status 6, `MAP(MD)` and a dispatch, and the fixnum's
//!             control
//!   double    port A and port B missing at one index in one microcycle,
//!             and port A's fill evicting a direct write
//!
//! **NOTHING IS PRESET**, as in `golden/src/quux13.rs`: every constant is
//! made by the program from the dispatch constant, and every table word,
//! data word, PDL buffer word and register-page word is written by the
//! program, the tables through the physical memory window.  **EACH PROGRAM
//! SAYS WHAT IT REACHED**: the results land in A memory from `200` up, and
//! the generator asserts each against the value muir's test holds, and the
//! model's counts (walks, write-backs, refusals, redirects, evictions,
//! double misses) against the test's, before it writes a trace.

mod machine_axis;
mod trace;

use machine_axis::Which;
use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::{
    ADD, ALU, ALWAYS, BYTE, CARRY_IN, DISPATCH, DMEM_WRITE, DPB, JUMP, LDB, M_PLUS_C, MD, N,
    OB_LEFT, POPJ, SETA, SETM, SRC_MD, START_READ, START_WRITE, SUB, a_dest, a_src, filler, m_dest,
    m_src, src, target,
};
use muir::machine::{Geometry, Machine, PROM_WORDS, QUUX_PROM_BASE, Word};
use muir::tlb;

/// Revision 14.
const REV14: Geometry = Geometry::QUUX_14;

/// A memory's constants: 0, 1 and 2.
const ZERO: u64 = 0o40;
const ONE: u64 = 0o41;
const TWO: u64 = 0o42;
/// M memory's 0 and 1, which [`Prog::taken`] writes its results from with
/// BYTE words, so that no ALU word loads the overflow flag between a test
/// and its jump.
const M_ZERO: u64 = 0o34;
const M_ONE: u64 = 0o35;
/// M memory: the physical memory window's base, `36000000000`, which a
/// poke adds its physical address to.
const M_PW: u64 = 0o26;
/// The A memory words constants are made in, used round in turn: each is
/// made right before the word that reads it.
const K_FIRST: u64 = 0o60;
const K_WORDS: u64 = 0o20;
/// The A memory word a constant bound for M is made in.
const SCRATCH: u64 = 0o77;
/// The first A memory word a result lands in.
const RESULT: u64 = 0o200;
/// The dispatch memory's table the map-bit dispatches use, `{type, bit}`
/// from here: away from entry 0, which [`Prog::a`] writes as it goes.
const TRANSPORT_TABLE: u64 = 0o2000;

/// A 40-bit word from its tag `<39:32>` and field `<31:0>`.
const fn w(tag: u64, field: u64) -> Word {
    tag << 32 | (field & 0xffff_ffff)
}

/// A functional destination, with M's address 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}
/// Destination 1, LOCATION-COUNTER; 15, the SPC push; 23, `VMA` with the
/// `WRITE-MAP` operation a microcycle later; 12, the PDL buffer at
/// PDL-INDEX; 13, PDL-INDEX; 14, the PDL pointer.
const LC: u64 = fd(1);
const SPC_PUSH: u64 = fd(0o15);
const WRITE_MAP: u64 = fd(0o23);
const PDL_AT_INDEX: u64 = fd(0o12);
const PDL_INDEX: u64 = fd(0o13);
const PDL_POINTER: u64 = fd(0o14);

/// Functional sources: 11 `MAP(MD)`, 13 the location counter.
const SRC_MAP: u64 = src(0o11);
const SRC_LC: u64 = src(0o13);

/// `M-1`: the 74S181's function 15 with no carry, `IR<8:3>` 23.
const M_MINUS_1: u64 = 0o23 << 3;

/// The fixnum's data type, `005`, and a list pointer's, `016`; NULL's is 0.
const FIX: Word = 0o005 << 32;
const LIST: Word = 0o016 << 32;

/// A BYTE word: function, rotate `IR<5:0>` and length - 1 `IR<11:6>`.
fn byte(func: u64, rotate: u64, len: u64) -> u64 {
    BYTE | func | (len - 1) << 6 | rotate
}
/// A JUMP on condition `code`, `IR<4:0>` with `IR<5>` (A1.3).
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}
/// A DISPATCH: address `IR<23:12>`, length `IR<7:5>`, rotate `{IR<47>,
/// IR<4:0>}`.
fn disp(addr: u64, len: u64, r: u64) -> u64 {
    DISPATCH | addr << 12 | len << 5 | (r >> 5) << 47 | (r & 0o37)
}
/// The oldspace map bit of a DISPATCH, `IR<9>`, the entry's `<23>`.
const MAP_23: u64 = 2 << 8;

// ------------------------------------------------------------- the tables

/// The directory's first frame: frames 4-7, a multiple of 4 (A14.3).
const DIR: u32 = 4;
/// Page-table pages from frame 10 up.
const FIRST_TABLE: u32 = 0o10;
/// Main memory: QUUX's 32 boards, 2M words, 2,048 frames.
const BOARDS: u32 = 32;
const MAIN: u32 = BOARDS << 16;

/// A page entry (A14.2), a fixnum: status 4, access `11`, not oldspace and
/// not extra PDL (`<23:22>` 11), at `frame`.
const fn rw(frame: u32) -> Word {
    FIX | 1 << 27 | 1 << 26 | 3 << 22 | frame as Word
}
/// Status 4 with access `11` and `<23:22>` as `meta`.
const fn rw_meta(frame: u32, meta: u64) -> Word {
    FIX | 1 << 27 | 1 << 26 | meta << 22 | frame as Word
}
/// A page entry of status `status` and access code `access`, `<23:22>` 11,
/// the frame or slot `frame`.
const fn entry(status: u64, access: u64, frame: u32) -> Word {
    FIX | access << 26 | status << 24 | 3 << 22 | frame as Word
}
/// A status-5 page entry: access `01`, every reference faulting.
const fn pdl_entry(frame: u32) -> Word {
    entry(5, 1, frame)
}
/// Accessed, modified and ephemeral-reference as page-entry bits.
const A: Word = tlb::ACCESSED as Word;
const M: Word = tlb::MODIFIED as Word;
const E: Word = tlb::EPHEMERAL as Word;
/// The page entry's `<29:0>`, what the TLB holds.
const ENTRY: Word = tlb::ENTRY_BITS as Word;

/// The physical memory window's address of main memory's word `phys`.
const fn phys_va(phys: u32) -> Word {
    (tlb::PHYSICAL_WINDOW | phys) as Word
}
/// The register page's word `k` through the device window.
const fn reg(k: u32) -> Word {
    (tlb::REGISTER_PAGE + k) as Word
}

/// The tables as a program writes them: the directory entry for each 1M
/// words a page lies in, a page-table page for each, taken from frame 10
/// up in the order the pages are named, and each page's entry.  The words
/// and where they go, in main memory's physical addresses.
#[derive(Default)]
struct Tables {
    dirs: Vec<(u32, u32)>,
    words: Vec<(u32, Word)>,
}

impl Tables {
    /// The page-table frame for `va`'s 1M words, made if new.
    fn table_for(&mut self, va: u32) -> u32 {
        let d = va >> 20;
        if let Some(&(_, f)) = self.dirs.iter().find(|&&(x, _)| x == d) {
            return f;
        }
        let f = FIRST_TABLE + self.dirs.len() as u32;
        self.dirs.push((d, f));
        self.words.push(((DIR & !3) << 10 | d, FIX | 1 << 26 | f as Word));
        f
    }

    /// Where `va`'s page entry is.
    fn entry_at(&mut self, va: u32) -> u32 {
        let f = self.table_for(va);
        f << 10 | (va >> 10 & 0o1777)
    }

    /// `va` unmapped, its directory entry or its page entry zero as main
    /// memory comes up in muir: the program writes the word a walk of `va`
    /// reads, as it writes every word it reads.  After every page is mapped.
    fn unmapped(&mut self, va: u32) {
        let d = va >> 20;
        if let Some(&(_, f)) = self.dirs.iter().find(|&&(x, _)| x == d) {
            self.words.push((f << 10 | (va >> 10 & 0o1777), 0));
        } else {
            self.words.push(((DIR & !3) << 10 | d, 0));
        }
    }

    /// `va`'s page with the entry `e`.
    fn map(&mut self, va: u32, e: Word) -> u32 {
        let at = self.entry_at(va);
        self.words.push((at, e));
        at
    }
}

// --------------------------------------------------------------- programs

/// A program being assembled into QUUX's PROM, from its first word at
/// `QUUX_PROM_BASE`, and the results it is to leave in A memory: each the
/// value muir's test holds, under a mask, or `None`, a word the trace holds
/// and the test says nothing of.
struct Prog {
    words: Vec<u64>,
    results: Vec<(u64, Option<Word>, Word, String)>,
    next_k: u64,
}

impl Prog {
    fn new() -> Self {
        Prog { words: Vec::new(), results: Vec::new(), next_k: 0 }
    }

    /// The control store address the next word lands at.
    fn at(&self) -> u64 {
        QUUX_PROM_BASE as u64 + self.words.len() as u64
    }

    fn op(&mut self, raw: u64) -> &mut Self {
        self.words.push(raw);
        self
    }

    fn fill(&mut self, n: usize) -> &mut Self {
        for _ in 0..n {
            self.words.push(filler().raw());
        }
        self
    }

    /// `A[a]` = `v`, 40 bits, made from the dispatch constant: ten bits at
    /// a time, each loaded by a dispatch-memory write (which writes entry 0
    /// as it goes) and deposited at its place by a DPB.
    fn a(&mut self, a: u64, v: Word) -> &mut Self {
        let mut first = true;
        for k in 0..4u64 {
            let piece = (v >> (10 * k)) & 0o1777;
            if !first && piece == 0 {
                continue;
            }
            self.op(DISPATCH | DMEM_WRITE | a_src(piece));
            if first {
                // The first piece, at its place: k is 0, or the pieces below
                // it are zero and a DPB of it into 0 places it.
                if k == 0 {
                    self.op(ALU | SETM | src(0) | a_dest(a));
                } else {
                    self.op(ALU | SETA | a_src(ZERO) | a_dest(a));
                    self.op(byte(DPB, 10 * k, 10) | src(0) | a_src(a) | a_dest(a));
                }
                first = false;
            } else {
                self.op(byte(DPB, 10 * k, 10) | src(0) | a_src(a) | a_dest(a));
            }
        }
        self
    }

    /// A constant, made in the next of A's round of constant words: its
    /// address.
    fn k(&mut self, v: Word) -> u64 {
        let a = K_FIRST + self.next_k % K_WORDS;
        self.next_k += 1;
        self.a(a, v);
        a
    }

    /// M `m` = `v`, and the A word it shadows.
    fn m(&mut self, m: u64, v: Word) -> &mut Self {
        self.a(SCRATCH, v);
        self.op(ALU | SETA | a_src(SCRATCH) | m_dest(m))
    }

    /// The next result's A address, which is to hold `want` under `mask`.
    fn result(&mut self, want: Option<Word>, mask: Word, what: &str) -> u64 {
        let a = RESULT + self.results.len() as u64;
        assert!(a < 0o1000, "the results run past A 777");
        self.results.push((a, want, mask, what.to_string()));
        a
    }

    /// A result of the word `raw`, whose destination this adds.
    fn put(&mut self, raw: u64, want: Option<Word>, what: &str) -> &mut Self {
        let a = self.result(want, !0, what);
        self.op(raw | a_dest(a))
    }

    /// A result under a mask.
    fn put_masked(&mut self, raw: u64, want: Word, mask: Word, what: &str) -> &mut Self {
        let a = self.result(Some(want), mask, what);
        self.op(raw | a_dest(a))
    }

    /// A result, 1 if the JUMP `jump` is taken and 0 if not: the jump goes
    /// to the word after the next with `N`, which the jump inhibits when
    /// taken and runs when not.  The two writes are BYTE words, which leave
    /// the overflow flag.
    fn taken(&mut self, jump: u64, want: Option<Word>, what: &str) -> &mut Self {
        let a = self.result(want, !0, what);
        self.op(byte(LDB, 0, 40) | m_src(M_ONE) | a_dest(a));
        let next = self.at() + 2;
        self.op(jump | target(next) | N);
        self.op(byte(LDB, 0, 40) | m_src(M_ZERO) | a_dest(a))
    }

    /// The word at the virtual address `va`, a read as muir's test makes
    /// it: the start, the fault test in the microcycle after it, and `MD`
    /// in the one after that, which waits for the word.  A result of the
    /// fault and one of `MD`.
    fn read(&mut self, va: Word, want: Option<Word>, fault: Option<Word>, what: &str) -> &mut Self {
        let a = self.k(va);
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.taken(jcond(4), fault, &format!("{what}: the fault"));
        self.put(ALU | SETM | SRC_MD, want, what)
    }

    /// The word `word` to the virtual address `va`, a write as muir's test
    /// makes it; a result of the fault.
    fn write(&mut self, word: Word, va: Word, fault: Option<Word>, what: &str) -> &mut Self {
        let (wa, aa) = (self.k(word), self.k(va));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.taken(jcond(4), fault, &format!("{what}: the fault"));
        self.fill(1)
    }

    /// A `WRITE-MAP` operation `op` (A14.4) at `MD` = `va` with `VMA`'s
    /// `<29:0>` `entry`, landed by the time the next word runs.
    fn tlb_op(&mut self, op: u64, va: Word, entry: Word) -> &mut Self {
        let (aa, oa) = (self.k(va), self.k(op << 32 | entry));
        self.op(ALU | SETA | a_src(aa) | MD);
        self.op(ALU | SETA | a_src(oa) | WRITE_MAP);
        self.fill(2)
    }

    /// A result of `MAP(MD)` with `MD` = `va`: the entry `<29:0>` as
    /// `want`, the fault bits `<31:30>`, the last memory cycle's, unasked.
    fn map(&mut self, va: Word, want: Option<Word>, what: &str) -> &mut Self {
        let a = self.k(va);
        self.op(ALU | SETA | a_src(a) | MD);
        match want {
            Some(want) => self.put_masked(ALU | SETM | SRC_MAP, want, ENTRY, what),
            None => self.put(ALU | SETM | SRC_MAP, None, what),
        }
    }

    /// Main memory's word `phys` <- `word`, through the physical memory
    /// window: `MD` first, then the start at M `M_PW` plus the address.
    /// The word after the start leaves `MD` alone (the next poke's
    /// constants are A's), so the word written is `word`.
    fn poke(&mut self, phys: u32, word: Word) -> &mut Self {
        let wa = self.k(word);
        self.op(ALU | SETA | a_src(wa) | MD);
        let oa = self.k(phys as Word);
        self.op(ALU | ADD | m_src(M_PW) | a_src(oa) | START_WRITE)
    }

    /// The tables' words and the directory base, word 220.
    fn tables(&mut self, t: &Tables) -> &mut Self {
        for &(at, word) in &t.words {
            self.poke(at, word);
        }
        self.base(DIR)
    }

    /// Register-page word 220, the directory base.
    fn base(&mut self, frame: u32) -> &mut Self {
        let (wa, aa) = (self.k(frame as Word), self.k(reg(0o220)));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.fill(2)
    }

    /// A result of main memory's word `phys`, read through the physical
    /// memory window: a table's entry after the write-backs.
    fn peek(&mut self, phys: u32, want: Word, what: &str) -> &mut Self {
        self.read(phys_va(phys), Some(want), Some(0), what)
    }

    /// The redirect's copies: A 430 <- `base`, A 431 <- `head`.
    fn copies(&mut self, base: u32, head: u64) -> &mut Self {
        let (b, h) = (self.k(base as Word), self.k(head));
        self.op(ALU | SETA | a_src(b) | a_dest(tlb::A_PDL_BUFFER_VIRTUAL_ADDRESS as u64));
        self.op(ALU | SETA | a_src(h) | a_dest(tlb::A_PDL_BUFFER_HEAD as u64))
    }

    /// The PDL buffer's word `k` <- `word`, through PDL-INDEX.
    fn pdl(&mut self, k: u64, word: Word) -> &mut Self {
        let (ka, wa) = (self.k(k), self.k(word));
        self.op(ALU | SETA | a_src(ka) | PDL_INDEX);
        self.op(ALU | SETA | a_src(wa) | PDL_AT_INDEX)
    }

    /// The PDL pointer <- `pp`.
    fn pdl_pointer(&mut self, pp: u64) -> &mut Self {
        let a = self.k(pp);
        self.op(ALU | SETA | a_src(a) | PDL_POINTER)
    }

    /// Dispatch-memory entry `e` = `word`, through A memory `SCRATCH`, in
    /// words of a fixed length, so that an entry whose value is an address
    /// further on can be written before that address is known: the index of
    /// its first word, for [`Prog::patch_dmem`].
    fn dmem(&mut self, e: u64, word: u32) -> usize {
        let at = self.words.len();
        self.words.extend(Self::dmem_words(e, word));
        at
    }

    fn dmem_words(e: u64, word: u32) -> Vec<u64> {
        let mut v = Vec::new();
        for k in 0..4u64 {
            let piece = (word as u64 >> (10 * k)) & 0o1777;
            v.push(DISPATCH | DMEM_WRITE | a_src(piece));
            if k == 0 {
                v.push(ALU | SETM | src(0) | a_dest(SCRATCH));
            } else {
                v.push(byte(DPB, 10 * k, 10) | src(0) | a_src(SCRATCH) | a_dest(SCRATCH));
            }
        }
        v.push(disp(e, 0, 0) | DMEM_WRITE | a_src(SCRATCH));
        v
    }

    /// The entry [`Prog::dmem`] wrote at `at`, rewritten to `word`.
    fn patch_dmem(&mut self, at: usize, e: u64, word: u32) {
        let v = Self::dmem_words(e, word);
        self.words[at..at + v.len()].copy_from_slice(&v);
    }

    /// A dispatch on `MD`'s data type and the oldspace map bit (`IR<9>`,
    /// the entry's `<23>`), muir's test's `transport`: the address is
    /// `{type, map bit}`, `MD<37:32>` rotated to `<6:1>`, in the table at
    /// [`TRANSPORT_TABLE`].  A result, 1 at entry `{type, 0}` and 2 at
    /// `{type, 1}`.
    fn transport(&mut self, md: Word, want: Option<Word>, what: &str) -> &mut Self {
        let ty = md >> 32 & 0o77;
        let e0 = self.dmem(TRANSPORT_TABLE + (ty << 1), 0);
        let e1 = self.dmem(TRANSPORT_TABLE + (ty << 1 | 1), 0);
        let a = self.k(md);
        self.op(ALU | SETA | a_src(a) | MD);
        // Rotate 9: <37:32> to <6:1>; 7 bits.
        self.op(disp(TRANSPORT_TABLE, 7, 9) | MAP_23 | SRC_MD);
        self.fill(1);
        let r = self.result(want, !0, what);
        let after = self.at() + 6;
        let mut at = [0u64; 2];
        for (k, value) in [M_ONE, TWO].into_iter().enumerate() {
            at[k] = self.at();
            if k == 0 {
                self.op(byte(LDB, 0, 40) | m_src(value) | a_dest(r));
            } else {
                self.op(ALU | SETA | a_src(value) | a_dest(r));
            }
            self.op(JUMP | ALWAYS | target(after) | N);
            self.fill(1);
        }
        self.patch_dmem(e0, TRANSPORT_TABLE + (ty << 1), 1 << 14 | at[0] as u32);
        self.patch_dmem(e1, TRANSPORT_TABLE + (ty << 1 | 1), 1 << 14 | at[1] as u32);
        self
    }

    /// Stops: a jump to itself, the instruction after it inhibited.
    fn park(&mut self) -> u64 {
        let here = self.at();
        self.op(JUMP | target(here) | ALWAYS | N);
        self.fill(1);
        here
    }

    fn prom(&self) -> Vec<Insn> {
        assert!(self.words.len() <= PROM_WORDS, "the program is {} words and the PROM {PROM_WORDS}", self.words.len());
        self.words.iter().map(|&w| Insn::new(w)).collect()
    }

    /// The constants every program starts from.
    fn start(&mut self) -> &mut Self {
        self.a(ZERO, 0).a(ONE, 1).a(TWO, 2);
        self.m(M_ZERO, 0).m(M_ONE, 1).m(M_PW, tlb::PHYSICAL_WINDOW as Word)
    }
}

// --------------------------------------------------------------- windows

/// **The windows never touch the TLB, and the physical memory window
/// aliases a translated frame** (A14.1; muir's
/// `the_windows_never_touch_the_tlb` and
/// `the_physical_memory_window_aliases_a_translated_frame`): a direct write
/// at a window address does nothing, and the window's word and the register
/// page's MACHINE-ID are read with nothing walked; a word written through a
/// translated page reads back through the window at its frame, and the
/// reverse; a frame reached through the window alone; and the tables read
/// back, the window having set no bit and the translated references
/// accessed and modified.
fn windows_program() -> (Prog, Expect) {
    const WORD: u32 = 0o2000 + 7;
    const VA: u32 = 0o12345 << 10;
    const FRAME: u32 = 0o200;
    const OTHER_VA: u32 = 0o12346 << 10;
    const OTHER: u32 = 0o201;
    let mut t = Tables::default();
    let va_at = t.map(VA, rw(FRAME));
    let other_at = t.map(OTHER_VA, rw(OTHER));
    let mut p = Prog::new();
    p.start().tables(&t);
    p.poke(WORD, w(0o031, 0x600d)).poke(0o3000 + 7, w(0o031, 0xbad));
    // A direct write at each window address, to frame 3: an operation at a
    // window does nothing (A14.4), so the TLB holds neither.
    p.tlb_op(1, phys_va(WORD), rw(3) & ENTRY);
    p.tlb_op(1, reg(0), rw(3) & ENTRY);
    p.read(phys_va(WORD), Some(w(0o031, 0x600d)), Some(0), "the physical memory window's word");
    p.read(reg(0), Some((0x5155 << 16) | (14 << 4) | 4), Some(0), "MACHINE-ID through the device window");
    // Aliasing.
    p.write(w(0o025, 0x1111), (VA | 5) as Word, Some(0), "the translated write");
    p.read(phys_va(FRAME << 10 | 5), Some(w(0o025, 0x1111)), Some(0), "read through the window");
    p.write(w(0o025, 0x2222), phys_va(FRAME << 10 | 6), Some(0), "the window's write");
    p.read((VA | 6) as Word, Some(w(0o025, 0x2222)), Some(0), "read through the page");
    p.write(w(0o025, 0x3333), phys_va(OTHER << 10 | 7), Some(0), "the other frame's write");
    p.read(phys_va(OTHER << 10 | 7), Some(w(0o025, 0x3333)), Some(0), "the other frame through the window");
    p.peek(other_at, rw(OTHER), "the window set no bit in its entry");
    p.peek(va_at, rw(FRAME) | A | M, "the translated page's entry, accessed and modified");
    p.park();
    (p, Expect { walks: Some(1), ..Expect::default() })
}

// ----------------------------------------------------------------- space

/// The device window's frame buffer, slice 0.
const FRAME_BUFFER: u32 = tlb::DEVICE_WINDOW;

/// **The device window, nothing there, and A memory's window** (A14.1,
/// A14.5, A14.9; muir's `the_device_window_and_its_register_page`,
/// `nothing_there_past_main_memory_and_in_the_reserved_slices` and
/// `a_memory_s_window_faults_with_status_7`): frame buffer 0 stores the
/// field and reads it with tag `005`; the register page's feature words 0,
/// 1, 2 and 13 at revision 14; the physical memory window past main memory,
/// slices 1-3 and 4-14, the gap past A memory's window and the reserved
/// register pages, each nothing there with word 101's NXM bit, and main
/// memory's last word through the window no NXM; a read and a write of A
/// memory's window faulting, and `MAP(MD)` there its fixed entry, status 7.
fn space_program(entries: u32) -> (Prog, Expect) {
    let mut p = Prog::new();
    p.start();
    p.write(w(0o025, 0x1234_5678), (FRAME_BUFFER + 7) as Word, Some(0), "the frame buffer's write");
    p.read((FRAME_BUFFER + 7) as Word, Some(w(0o005, 0x1234_5678)), Some(0), "the frame buffer: the field, tag 005");
    for (word, want, what) in [
        (0u32, (0x5155 << 16) | (14 << 4) | 4, "word 0, MACHINE-ID revision 14"),
        (1, 0, "word 1, no level-1 map"),
        (2, entries as Word, "word 2, the TLB's entries"),
        (0o13, 0o34000000000, "word 13, the buffer's device-window address"),
    ] {
        p.read(reg(word), Some(want), Some(0), what);
    }
    p.poke(MAIN - 1, w(0o031, 0o777));
    let places = [
        phys_va(MAIN),
        0o34100000000,
        0o34377777777,
        0o34400000000,
        0o35677777777,
        0o35700002000,
        0o35777600000,
        phys_va(MAIN - 1),
    ];
    for (k, va) in places.into_iter().enumerate() {
        let last = k == places.len() - 1;
        p.write(0, reg(0o101), Some(0), "word 101 cleared");
        let want = if last { w(0o031, 0o777) } else { 0 };
        p.read(va, Some(want), Some(0), if last { "main memory's last word" } else { "nothing there reads 0" });
        p.read(reg(0o101), Some(if last { 0 } else { 1 }), Some(0), "word 101's NXM bit");
    }
    p.read(0o35700000017, None, Some(1), "A memory's window: a read faults");
    p.write(w(0o025, 1), 0o35700000017, Some(1), "A memory's window: a write faults");
    p.map(0o35700000017, Some(tlb::A_MEMORY_WINDOW_ENTRY as Word), "MAP(MD) of A memory's window, status 7, access 01");
    p.park();
    (p, Expect { walks: Some(0), ..Expect::default() })
}

// ------------------------------------------------------------------ walk

/// **The walk and the TLB** (A14.4, A14.6; muir's
/// `two_pages_sharing_an_index_translate_to_their_own_frames`,
/// `pages_either_side_of_2_31_translate_to_their_own_frames`,
/// `a_stale_entry_is_kept_until_it_is_invalidated` and
/// `a_direct_write_loads_and_an_empty_clears`).
fn walk_program() -> (Prog, Expect) {
    // Two pages at one index.
    const IA: u32 = 0o5 << 10;
    const IB: u32 = IA | 1 << 22;
    // Either side of 2^31.
    const BELOW: u32 = 0o17777776000;
    const ABOVE: u32 = 0o20000000000;
    const SAME_INDEX: u32 = 0o27777776000;
    // The stale entry.
    const STALE: u32 = 0o4321 << 10;
    // The direct write and the empty.
    const DIRECT: u32 = 0o7654 << 10;
    let mut t = Tables::default();
    t.map(IA, rw(0o200));
    t.map(IB, rw(0o201));
    t.map(BELOW, rw(0o202));
    t.map(ABOVE, rw(0o203));
    t.map(SAME_INDEX, rw(0o204));
    let stale_at = t.map(STALE, rw(0o205));
    t.unmapped(DIRECT);
    let mut p = Prog::new();
    p.start().tables(&t);
    for (frame, word) in [
        (0o200 << 10 | 3, w(0o025, 0xa)),
        (0o201 << 10 | 3, w(0o025, 0xb)),
        (0o202 << 10, w(0o025, 1)),
        (0o203 << 10, w(0o025, 2)),
        (0o204 << 10, w(0o025, 3)),
        (0o205 << 10, w(0o025, 0o51)),
        (0o206 << 10, w(0o025, 0o52)),
        (0o207 << 10, w(0o025, 7)),
    ] {
        p.poke(frame, word);
    }
    // Two pages at one index, in turn twice: four walks.
    for _ in 0..2 {
        p.read((IA | 3) as Word, Some(w(0o025, 0xa)), Some(0), "A");
        p.read((IB | 3) as Word, Some(w(0o025, 0xb)), Some(0), "B, same index");
    }
    // Either side of 2^31, in turn twice: BELOW, ABOVE and SAME_INDEX,
    // BELOW and SAME_INDEX sharing an index: five walks.
    for _ in 0..2 {
        p.read(BELOW as Word, Some(w(0o025, 1)), Some(0), "below 2^31");
        p.read(ABOVE as Word, Some(w(0o025, 2)), Some(0), "above 2^31");
        p.read(SAME_INDEX as Word, Some(w(0o025, 3)), Some(0), "above 2^31, the same index as below");
    }
    // The stale entry: two walks.
    p.read(STALE as Word, Some(w(0o025, 0o51)), Some(0), "the old frame");
    p.write(rw(0o206), phys_va(stale_at), Some(0), "the entry moved, no invalidation");
    p.read(STALE as Word, Some(w(0o025, 0o51)), Some(0), "the stale entry: still the old frame");
    p.tlb_op(2, STALE as Word, 0);
    p.read(STALE as Word, Some(w(0o025, 0o52)), Some(0), "after the invalidation, the new frame");
    // A revision-13 map write does nothing: a walk, no entry.
    p.tlb_op(0, DIRECT as Word, (1 << 29 | 1 << 28 | rw(0o207)) & 0o7777777777);
    p.read(DIRECT as Word, None, Some(1), "a revision-13 map write loads nothing: a fault");
    // A direct write at a window address does nothing; at DIRECT it loads.
    p.tlb_op(1, phys_va(0), rw(0o207) & ENTRY);
    p.tlb_op(1, DIRECT as Word, rw(0o207) & ENTRY);
    p.read(DIRECT as Word, Some(w(0o025, 7)), Some(0), "through the directly written entry");
    // The empty: the next read walks and finds no entry.
    p.tlb_op(3, 0, 0);
    p.read(DIRECT as Word, None, Some(1), "after the empty: no entry, a fault");
    p.park();
    (p, Expect { walks: Some(4 + 5 + 2 + 2), sweeps: Some(2), ..Expect::default() })
}

// --------------------------------------------------------------- noentry

/// **No directory, the no-entry results, and status 1** (A14.3, A14.6;
/// muir's `no_entry_faults_and_loads_nothing`,
/// `a_walk_with_no_directory_reads_nothing` and
/// `a_not_in_core_entry_faults_and_map_md_reads_it_without_a_walk`): a
/// paged read before the directory base is written faults, having read
/// nothing; then a missing directory entry, a status-0 entry, an in-core
/// entry past main memory and a status 7 in a table each fault, twice, the
/// second walking again; a status 3 loads as in core; a status-1 entry
/// faults, and `MAP(MD)` reads it with no further walk.
fn noentry_program() -> (Prog, Expect) {
    const NO_DIR: u32 = 0o1 << 20 | 0o5 << 10;
    const ZERO_ENTRY: u32 = 0o2 << 20 | 0o5 << 10;
    const PAST: u32 = 0o2 << 20 | 0o6 << 10;
    const SEVEN: u32 = 0o2 << 20 | 0o7 << 10;
    const THREE: u32 = 0o2 << 20 | 0o10 << 10;
    const OUT: u32 = 0o3333 << 10;
    let out = FIX | 1 << 24 | 2 << 22 | 0o123456;
    let mut t = Tables::default();
    t.map(ZERO_ENTRY, FIX);
    t.map(PAST, rw(4096));
    t.map(SEVEN, entry(7, 3, 0o200));
    // Status 3 shares `<26>` with the access code: read-only, `10`.
    t.map(THREE, entry(3, 2, 0o200));
    t.map(OUT, out);
    t.unmapped(NO_DIR);
    let mut p = Prog::new();
    p.start();
    // Base 0: a walk that reads nothing, and a fault.
    p.read(ZERO_ENTRY as Word, None, Some(1), "base 0: a fault");
    p.tables(&t);
    p.poke(0o200 << 10, w(0o025, 3));
    for (va, what) in [
        (NO_DIR, "no directory entry"),
        (ZERO_ENTRY, "a status-0 entry"),
        (PAST, "a frame past main memory"),
        (SEVEN, "status 7 in a table"),
    ] {
        for _ in 0..2 {
            p.read(va as Word, None, Some(1), what);
        }
    }
    p.read(THREE as Word, Some(w(0o025, 3)), Some(0), "status 3 loads as in core");
    p.read(OUT as Word, None, Some(1), "status 1: a fault");
    p.map(OUT as Word, Some(out & ENTRY), "MAP(MD) reads the status-1 entry");
    p.park();
    (p, Expect { walks: Some(1 + 8 + 1 + 1), ..Expect::default() })
}

// ----------------------------------------------------------------- empty

/// **An empty takes N ticks** (A14.4; muir's `an_empty_takes_n_ticks_on_rtl`):
/// a read through the window, which waits for the reset's sweep; an empty;
/// and the read again, which waits for its sweep.  Taken at 4,096 entries
/// (`empty`) and at 8,192 (`empty8k`), where each sweep is 4,096 ticks
/// longer.
fn empty_program() -> (Prog, Expect) {
    let mut p = Prog::new();
    p.start();
    p.poke(0, 0);
    p.read(phys_va(0), Some(0), Some(0), "the window, after the reset's sweep");
    p.tlb_op(3, 0, 0);
    p.read(phys_va(0), Some(0), Some(0), "the window, after the empty's sweep");
    p.park();
    (p, Expect { walks: Some(0), sweeps: Some(2), ..Expect::default() })
}

// ----------------------------------------------------------------- mapmd

/// **`MAP(MD)` and the dispatches on map bits** (A14.5; muir's
/// `map_md_reads_the_entry_and_the_fixed_entries` and
/// `a_transport_on_a_fixnum_walks_nothing`): `MAP(MD)` on a fixnum walks
/// and reads the entry; the physical memory window's, the device window's
/// and no entry's fixed words; a TRANSPORT dispatch on a fixnum naming an
/// unmapped page walks nothing and takes map bit 1; on a list pointer, its
/// type in the pointer-type register, it walks and takes the page's
/// oldspace bit, 0; on a NULL, in the register too, the same with no walk.
fn mapmd_program() -> (Prog, Expect) {
    const VA: u32 = 0o2222 << 10;
    const OLD: u32 = 0o4444 << 10;
    const UNMAPPED: u32 = 0o5555 << 10;
    let mut t = Tables::default();
    t.map(VA, rw_meta(0o300, 1));
    t.map(OLD, rw_meta(0o301, 1));
    t.unmapped(0o1111 << 10);
    let rw_4: Word = 0b11 << 28 | 0o1460 << 18;
    let mut p = Prog::new();
    p.start().tables(&t);
    p.map(FIX | VA as Word, Some(rw_meta(0o300, 1) & ENTRY), "the entry");
    p.map(phys_va(0o1234567), Some(rw_4 | 0o1234567 >> 10), "the physical window");
    p.map(0o34000000123, Some(rw_4), "the device window");
    p.map(0o1111 << 10, Some(0o60 << 18), "no entry");
    // The pointer-type register: LIST and NULL.
    p.write(1 << 0o16 | 1, reg(0o222), Some(0), "word 222");
    p.transport(FIX | UNMAPPED as Word, Some(2), "fixnum: map bit 1, not oldspace");
    p.transport(LIST | OLD as Word, Some(1), "list: the page's oldspace bit, 0");
    p.transport((OLD | 1) as Word, Some(1), "NULL: the same page, oldspace");
    p.park();
    (p, Expect { walks: Some(2 + 1), ..Expect::default() })
}

// -------------------------------------------------------------------- lc

/// The location counter's 34 bits.
const COUNTER: Word = (1 << 34) - 1;
const TWO_32: Word = 1 << 32;
const TWO_33: Word = 1 << 33;

impl Prog {
    /// LC <- `lc`, a 34-bit byte address, by a logical write, which takes
    /// the word's `<33:32>`.
    fn set_lc(&mut self, lc: Word) -> &mut Self {
        let a = self.k(lc);
        self.op(ALU | SETA | a_src(a) | LC)
    }
    /// A result of LC's counter, `<33:0>` of the source.
    fn read_lc(&mut self, want: Word, what: &str) -> &mut Self {
        self.put_masked(ALU | SETM | SRC_LC, want, COUNTER, what)
    }
}

/// **LC at 34 bits and condition 12** (A14.10, A14.11; muir's
/// `lc_s_adder_carries_branches_across_2_30_and_2_31_words`,
/// `lc_rebuilt_from_a_relative_pc_and_an_fef_address`,
/// `qlenx_s_shifted_write_takes_the_sum_s_carry` and
/// `condition_12_is_m_at_most_a_unsigned`).
fn lc_program() -> (Prog, Expect) {
    let mut p = Prog::new();
    p.start();
    let cases: [(Word, u64, Word, Word, &str); 9] = [
        (TWO_32 - 2, ADD, 4, TWO_32 + 2, "L1: a carry"),
        (TWO_32 + 2, ADD, 0xffff_fffc, TWO_32 - 2, "L2: a borrow, short"),
        (TWO_32 + 2, ADD, (1u64 << 32) - (1 << 20), TWO_32 + 2 - (1 << 20), "L2: long"),
        (TWO_33, SUB | CARRY_IN, 2, TWO_33 - 2, "L3: SUB 2 at <31:0> 0"),
        (TWO_33 - 2, ADD, 4, TWO_33 + 2, "2^31: a carry into <33>"),
        (TWO_33 + 2, ADD, 0xffff_fffc, TWO_33 - 2, "2^31: and back"),
        (3 * TWO_32 - 1, M_PLUS_C | CARRY_IN, 0, 3 * TWO_32, "M+1 carries"),
        (3 * TWO_32, M_MINUS_1, 0, 3 * TWO_32 - 2, "M-1 borrows, bit 0 cleared"),
        (COUNTER - 1, ADD, 4, 2, "mod 2^34"),
    ];
    for &(from, op, offset, want, what) in &cases {
        if op == M_PLUS_C | CARRY_IN || op == M_MINUS_1 {
            p.m(0o20, from);
            p.op(ALU | op | m_src(0o20) | LC);
        } else {
            p.set_lc(from);
            let a = p.k(offset);
            p.op(ALU | op | SRC_LC | a_src(a) | LC);
        }
        p.read_lc(want, what);
    }
    // L7: a logical write of LC from LC.
    p.set_lc(3 * TWO_32 + 0o100);
    p.op(ALU | SETM | SRC_LC | LC);
    p.read_lc(3 * TWO_32 + 0o100, "L7: a logical write keeps <33:32>");
    // L4 and L6.
    const FEF: Word = TWO_32 - 8;
    const PC: Word = TWO_32 + 8;
    const HIGH_FEF: Word = 3 * TWO_32;
    p.m(0o20, FEF);
    p.set_lc(PC);
    let fef = p.k(FEF);
    let rel = p.result(Some(16), 0xffff_ffff, "L4: the relative PC, 16 bytes");
    p.op(ALU | SUB | CARRY_IN | SRC_LC | a_src(fef) | a_dest(rel));
    p.op(ALU | ADD | m_src(0o20) | a_src(rel) | LC);
    p.read_lc(PC, "L4: LC rebuilt across 2^30 words");
    p.m(0o22, HIGH_FEF).m(0o23, 0o40);
    let (high, small) = (p.k(HIGH_FEF), p.k(0o40));
    p.op(ALU | ADD | m_src(0o22) | a_src(small) | LC);
    p.read_lc(HIGH_FEF + 0o40, "L6: the address on M");
    p.op(ALU | ADD | m_src(0o23) | a_src(high) | LC);
    p.read_lc(0o40, "L6: the address on A, <33:32> 00");
    // L5: QLENX's left-shifted write.
    const START_PC: Word = 0o24;
    for (fef, want, what) in [(1u64 << 31, TWO_33 + 2 * START_PC, "L5: an FEF at 2^31 words"), (1 << 30, TWO_32 + 2 * START_PC, "L5: at 2^30")] {
        p.m(0o24, 2 * fef);
        let a = p.k(START_PC);
        p.op(ALU | OB_LEFT | ADD | m_src(0o24) | a_src(a) | LC);
        p.read_lc(want, what);
    }
    // Condition 12, M <= A on the fields, unsigned.
    let pairs: [(Word, Word, Word); 7] = [
        (0, 0o37777777777, 1),
        (0o37777777777, 0, 0),
        (w(0o005, 7), w(0o003, 7), 1),
        (0o17777777777, 0o20000000000, 1),
        (0o20000000000, 0o17777777777, 0),
        (5, 5, 1),
        (6, 5, 0),
    ];
    for &(m, a, want) in &pairs {
        p.m(0o25, m);
        let a = p.k(a);
        p.taken(jcond(0o12) | m_src(0o25) | a_src(a), Some(want), "condition 12: M <= A unsigned");
    }
    p.park();
    (p, Expect::default())
}

// ----------------------------------------------------------------- fetch

impl Prog {
    /// The program's halfword return into the next word, `SPC<14>` set: a
    /// POPJ that steps the counter and, NEED-FETCH up, fetches.
    fn step_and_fetch(&mut self) -> &mut Self {
        let next = self.at() + 2 + self.k_cost(1 << 14 | 0);
        let a = self.k(1 << 14 | next);
        self.op(ALU | SETA | a_src(a) | SPC_PUSH);
        self.op(filler().raw() | POPJ)
    }

    /// The words [`Prog::a`] makes `v` in.
    fn k_cost(&self, v: Word) -> u64 {
        let mut n = 0;
        let mut first = true;
        for k in 0..4u64 {
            let piece = (v >> (10 * k)) & 0o1777;
            if !first && piece == 0 {
                continue;
            }
            n += if first && k > 0 { 3 } else { 2 };
            first = false;
        }
        n
    }
}

/// **L8: the stepper carries, and a fetch's `VMA` is `LC<33:2>`** (A14.11;
/// muir's `the_stepper_carries_and_a_fetch_reads_lc_33_2`): LC written at
/// 2^32 - 2 bytes fetches the word at 2^30 - 1 and steps to 2^32; the next
/// step fetches the word at 2^30 words; across 2^31 words the same from
/// 2^33 - 2, reading the word at 2^31; with the prefetch fitted.
fn fetch_program() -> (Prog, Expect) {
    const W30: u32 = 1 << 30;
    const W31: u32 = 1 << 31;
    let mut t = Tables::default();
    for (k, base) in [W30, W31].into_iter().enumerate() {
        let k = k as u32;
        t.map(base - 1024, rw(0o200 + 2 * k));
        t.map(base, rw(0o201 + 2 * k));
    }
    let mut p = Prog::new();
    p.start().tables(&t);
    for k in 0..2u32 {
        p.poke((0o200 + 2 * k) << 10 | 0o1777, w(0o025, 0x10 + k as u64));
        p.poke((0o201 + 2 * k) << 10, w(0o025, 0x20 + k as u64));
    }
    for (k, lc) in [TWO_32 - 2, TWO_33 - 2].into_iter().enumerate() {
        let k = k as u64;
        p.set_lc(lc);
        p.step_and_fetch();
        p.fill(2);
        p.put(ALU | SETM | SRC_MD, Some(w(0o025, 0x10 + k)), "the word below the boundary");
        p.step_and_fetch();
        p.fill(2);
        p.put(ALU | SETM | SRC_MD, Some(w(0o025, 0x20 + k)), "the word at the boundary");
        p.read_lc([TWO_32 + 2, TWO_33 + 2][k as usize], "stepped across the boundary");
    }
    p.park();
    (p, Expect { walks: Some(4), ..Expect::default() })
}

// ----------------------------------------------------------------- words

/// **Words 220-224** (A14.9; muir's
/// `the_memory_system_words_read_back_and_set_the_directory`): the directory
/// base, the enable and the pointer-type register read back as written;
/// word 224 reads its count, cleared by its write; 225 reads 0; and a paged
/// read through the directory the program set.
fn words_program() -> (Prog, Expect) {
    const VA: u32 = 0o6543 << 10;
    let mut t = Tables::default();
    t.map(VA, rw(0o200));
    let mut p = Prog::new();
    p.start();
    for &(at, word) in &t.words {
        p.poke(at, word);
    }
    p.poke(0o200 << 10, w(0o025, 0o42));
    p.write(DIR as Word, reg(0o220), Some(0), "220");
    p.write(0o777777777777, reg(0o221), Some(0), "221");
    p.write(0o12345670123, reg(0o222), Some(0), "222");
    p.write(0o32101234567, reg(0o223), Some(0), "223");
    p.write(0, reg(0o224), Some(0), "224");
    for (word, want, what) in [
        (0o220u32, DIR as Word, "220, the directory base"),
        (0o221, 1, "221, the enable's <0>"),
        (0o222, 0o12345670123, "222"),
        (0o223, 0o32101234567, "223"),
        (0o224, 0, "224, cleared by its write"),
        (0o225, 0, "225, reserved"),
    ] {
        p.read(reg(word), Some(want), Some(0), what);
    }
    p.read(VA as Word, Some(w(0o025, 0o42)), Some(0), "the page through the directory the program set");
    p.park();
    (p, Expect { walks: Some(1), ..Expect::default() })
}

// ------------------------------------------------------------- writeback

/// **The write-backs** (A14.6; muir's
/// `accessed_is_set_by_the_first_reference_that_does_not_fault`,
/// `modified_is_set_by_the_first_write_and_the_table_keeps_its_bits` and
/// `the_guard_refuses_a_write_through_a_stale_entry`).
fn writeback_program() -> (Prog, Expect) {
    const PAGE: u32 = 0o1001 << 10;
    const RO: u32 = 0o1002 << 10;
    const PAGE2: u32 = 0o1011 << 10;
    const PLANTED: u32 = 0o1012 << 10;
    const FORCED: u32 = 0o1013 << 10;
    const SWAPPED: u32 = 0o1021 << 10;
    const MOVED: u32 = 0o1022 << 10;
    let table_18 = rw(0o202) | 1 << 18;
    let read_only = entry(2, 2, 0o203);
    let not_in_core = FIX | 1 << 24 | 3 << 22 | 0o12345;
    let moved = rw(0o207);
    let mut t = Tables::default();
    let page_at = t.map(PAGE, rw(0o200));
    let ro_at = t.map(RO, entry(2, 2, 0o201));
    let page2_at = t.map(PAGE2, rw(0o204));
    let planted_at = t.map(PLANTED, table_18);
    let forced_at = t.map(FORCED, read_only);
    let swapped_at = t.map(SWAPPED, rw(0o205));
    let moved_at = t.map(MOVED, rw(0o206));
    let mut p = Prog::new();
    p.start().tables(&t);
    // The words the reads take, written first: a word nothing wrote is the
    // testbench's poison, never data.
    for f in [0o200u32, 0o204, 0o205, 0o206] {
        p.poke(f << 10, w(0o025, f as u64));
    }
    // Accessed by the first reference that does not fault.
    p.map(PAGE as Word, None, "MAP(MD) after its walk");
    p.read(PAGE as Word, Some(w(0o025, 0o200)), Some(0), "the first read");
    p.map(PAGE as Word, None, "MAP(MD) after the read");
    p.read(PAGE as Word, Some(w(0o025, 0o200)), Some(0), "the second read");
    p.write(w(0o025, 1), RO as Word, Some(1), "a write to a read-only page faults");
    // Modified by the first write; an OR.
    p.read(PAGE2 as Word, Some(w(0o025, 0o204)), Some(0), "a read");
    p.map(PAGE2 as Word, Some(rw(0o204) & ENTRY | A), "the read set accessed alone");
    p.write(w(0o025, 1), PAGE2 as Word, Some(0), "the first write");
    p.write(w(0o025, 2), PAGE2 as Word, Some(0), "the second write");
    p.tlb_op(1, PLANTED as Word, rw(0o202) & ENTRY);
    p.write(w(0o025, 3), PLANTED as Word, Some(0), "through a planted entry");
    p.tlb_op(1, FORCED as Word, (read_only | 3 << 26) & ENTRY);
    p.write(w(0o025, 4), FORCED as Word, Some(0), "through a forced entry");
    // The guard.
    p.read(SWAPPED as Word, Some(w(0o025, 0o205)), Some(0), "SWAPPED read");
    p.read(MOVED as Word, Some(w(0o025, 0o206)), Some(0), "MOVED read");
    p.write(not_in_core, phys_va(swapped_at), Some(0), "SWAPPED made status 1, no invalidation");
    p.write(moved, phys_va(moved_at), Some(0), "MOVED to another frame, no invalidation");
    p.write(w(0o025, 1), SWAPPED as Word, Some(0), "a write through the stale entry");
    p.read(reg(0o224), Some(1), Some(0), "word 224: one refused");
    p.write(w(0o025, 2), MOVED as Word, Some(0), "a write through the other stale entry");
    p.read(reg(0o224), Some(2), Some(0), "word 224: two refused");
    p.write(0, reg(0o224), Some(0), "word 224 written");
    p.read(reg(0o224), Some(0), Some(0), "word 224 cleared by its write");
    // The tables.
    p.peek(page_at, rw(0o200) | A, "accessed written back");
    p.peek(ro_at, entry(2, 2, 0o201), "nothing for the faulting write");
    p.peek(page2_at, rw(0o204) | A | M, "accessed, then modified");
    p.peek(planted_at, table_18 | A | M, "the table's <18> kept");
    p.peek(forced_at, read_only | A | M, "the table's access code kept");
    p.peek(swapped_at, not_in_core, "the status-1 entry untouched");
    p.peek(moved_at, moved, "the moved entry untouched");
    p.park();
    (p, Expect { write_backs: Some(1 + 4 + 2 + 2), refusals: Some(2), ..Expect::default() })
}

// ---------------------------------------------------------------- setter

/// The setter's pages.
const SET_PAGES: [u32; 5] = [0o1031 << 10, 0o1032 << 10, 0o1033 << 10, 0o1034 << 10, 0o1035 << 10];

/// **The ephemeral-reference setter** (A14.8; muir's
/// `the_setter_marks_a_store_of_an_ephemeral_pointer`): with the enable
/// `enable` and the list type in the pointer-type register, a list pointer
/// to `32000000000` stored, twice; a fixnum whose field is `32000000000`, a
/// list pointer to `31777777777` and one to `20000000000`, each to a page
/// of its own; and a store through the physical memory window to a mapped
/// page's frame.
fn setter_program(enable: Word) -> (Prog, Expect) {
    let mut t = Tables::default();
    let ats: Vec<u32> = SET_PAGES.iter().enumerate().map(|(k, &page)| t.map(page, rw(0o200 + k as u32))).collect();
    let mut p = Prog::new();
    p.start().tables(&t);
    p.write(enable, reg(0o221), Some(0), "221, the enable");
    p.write(1 << 0o16, reg(0o222), Some(0), "222, LIST");
    let young = LIST | 0o32000000000;
    for (word, page) in [
        (young, SET_PAGES[0]),
        (young | 7, SET_PAGES[0]),
        (FIX | 0o32000000000, SET_PAGES[1]),
        (LIST | 0o31777777777, SET_PAGES[2]),
        (LIST | 0o20000000000, SET_PAGES[3]),
    ] {
        p.write(word, page as Word, Some(0), "a store");
    }
    p.write(young, phys_va(0o204 << 10), Some(0), "a store through the window");
    let am = rw(0o200) | A | M;
    p.peek(ats[0], if enable != 0 { am | E } else { am }, "the young list pointer's page");
    for k in 1..4 {
        p.peek(ats[k], rw(0o200 + k as u32) | A | M, "marks nothing");
    }
    p.peek(ats[4], rw(0o204), "the window's store sets nothing");
    p.park();
    let bits = if enable != 0 { [4, 4, 1] } else { [4, 4, 0] };
    (p, Expect { write_backs: Some(4), written_bits: Some(bits), ..Expect::default() })
}

// ---------------------------------------------------------------- wbhold

/// **A write-back holds the reference** (A14.6; muir's
/// `a_write_back_holds_the_reference_on_rtl`): a page read once, its line
/// then in the cache, its table entry rewritten through the window with
/// accessed 0 and its TLB entry invalidated; a write to another word just
/// before, so that the write buffer is full when the write-back's write
/// comes; and the read again, whose walk is followed by a write-back, the
/// read waiting behind its write.
fn wbhold_program() -> (Prog, Expect) {
    const PAGE: u32 = 0o1041 << 10;
    let mut t = Tables::default();
    let at = t.map(PAGE, rw(0o200) | A);
    let mut p = Prog::new();
    p.start().tables(&t);
    p.poke(0o200 << 10, w(0o025, 0o77));
    p.read(PAGE as Word, Some(w(0o025, 0o77)), Some(0), "the first read");
    p.write(rw(0o200), phys_va(at), Some(0), "accessed 0 again");
    p.tlb_op(2, PAGE as Word, 0);
    let (junk, page) = (p.k(phys_va(0o300 << 10)), p.k(PAGE as Word));
    p.op(ALU | SETA | a_src(junk) | START_WRITE);
    p.op(ALU | SETA | a_src(page) | START_READ);
    p.fill(1);
    p.put(ALU | SETM | SRC_MD, Some(w(0o025, 0o77)), "the read behind its write-back");
    p.peek(at, rw(0o200) | A, "accessed written back");
    p.park();
    (p, Expect { write_backs: Some(1), ..Expect::default() })
}

// -------------------------------------------------------------- redirect

/// The PDL buffer's word `k` as the programs write it.
const fn pdl_word(k: u64) -> Word {
    w(0o031, 0o7000 + k)
}

/// **The PDL buffer redirect** (A14.7; muir's
/// `the_redirect_takes_the_buffer_up_to_the_word_past_pp`,
/// `a_start_right_after_a_write_of_a_431_uses_the_new_head`,
/// `an_access_11_status_5_entry_goes_to_memory`,
/// `the_redirect_across_2_31_words` and
/// `a_redirect_inside_holds_one_microcycle_on_rtl`).  With `am`, every entry
/// is accessed and modified already, so that nothing is written back: the
/// redirect alone, which `redirectam` holds while `redirect`'s write-backs
/// after a TLB hit wait on muir.
fn redirect_program(am: bool) -> (Prog, Expect) {
    let pdl_entry = |frame: u32| if am { pdl_entry(frame) | A | M } else { pdl_entry(frame) };
    let entry = |s: u64, a: u64, f: u32| if am { entry(s, a, f) | A | M } else { entry(s, a, f) };
    const PAGE: u32 = 0o2001 << 10;
    const BASE: u32 = PAGE | 0o20;
    const PAGE2: u32 = 0o2002 << 10;
    const PAGE3: u32 = 0o2003 << 10;
    const LOW: u32 = 0o17777776000;
    const HIGH: u32 = 0o20000000000;
    const BASE4: u32 = 0o17777777770;
    let mut t = Tables::default();
    let page_at = t.map(PAGE, pdl_entry(0o200));
    t.map(PAGE2, pdl_entry(0o201));
    t.map(PAGE3, pdl_entry(0o202));
    t.map(LOW, pdl_entry(0o203));
    t.map(HIGH, pdl_entry(0o204));
    let mut p = Prog::new();
    p.start().tables(&t);
    p.poke(0o200 << 10 | 0o31, w(0o025, 0x600d));
    p.poke(0o200 << 10 | 0o21, 0);
    p.poke(0o202 << 10, w(0o025, 0x600e));
    p.poke(0o204 << 10 | 4, w(0o025, 0x600f));
    for k in [0o100u64, 0o101, 0o107, 0o110, 0o112, 0o113, 0o200] {
        p.pdl(k, pdl_word(k));
    }
    p.pdl_pointer(0o107);
    // Off 0, n - 1, n inside; a write inside; n + 1 outside.
    p.copies(BASE, 0o100);
    for (off, k, what) in [(0u32, 0o100, "off 0: the head"), (7, 0o107, "off n - 1: PP"), (8, 0o110, "off n: the word one past PP")] {
        p.read((BASE + off) as Word, Some(pdl_word(k)), Some(0), what);
    }
    p.write(w(0o025, 0o111), (BASE + 1) as Word, Some(0), "a write inside");
    p.read((BASE + 1) as Word, Some(w(0o025, 0o111)), Some(0), "the inside write, in the buffer");
    p.map(BASE as Word, Some(pdl_entry(0o200) & ENTRY), "inside: no accessed, no modified");
    p.read((BASE + 9) as Word, Some(w(0o025, 0x600d)), Some(0), "off n + 1: memory");
    p.write(w(0o025, 0o222), (BASE + 9) as Word, Some(0), "a write outside");
    p.map(BASE as Word, Some((pdl_entry(0o200) | A | M) & ENTRY), "MAP(MD) as stored, with the outside bits");
    p.peek(0o200 << 10 | 0o21, 0, "the inside write not in memory");
    p.peek(0o200 << 10 | 0o31, w(0o025, 0o222), "the outside write in memory");
    p.peek(page_at, pdl_entry(0o200) | A | M, "outside: accessed, modified");
    // A start right after a write of A 431.
    p.copies(PAGE2, 0o100);
    p.fill(2);
    let (head, va) = (p.k(0o200), p.k(PAGE2 as Word));
    p.op(ALU | SETA | a_src(head) | a_dest(tlb::A_PDL_BUFFER_HEAD as u64));
    p.op(ALU | SETA | a_src(va) | START_READ);
    p.fill(2);
    p.put(ALU | SETM | SRC_MD, Some(pdl_word(0o200)), "the word at the new head");
    // An access-11 fiddle goes to memory.
    p.copies(PAGE3, 0o100);
    p.tlb_op(1, PAGE3 as Word, entry(5, 3, 0o202) & ENTRY);
    p.read(PAGE3 as Word, Some(w(0o025, 0x600e)), Some(0), "an access-11 status 5: memory");
    // Across 2^31: PP 12 past the head, n = 13.
    p.pdl_pointer(0o112);
    p.copies(BASE4, 0o100);
    for (off, want, what) in [
        (0u32, pdl_word(0o100), "off 0, below 2^31"),
        (10, pdl_word(0o112), "off n - 1, above"),
        (11, pdl_word(0o113), "off n"),
        (12, w(0o025, 0x600f), "off n + 1: memory"),
    ] {
        p.read(BASE4.wrapping_add(off) as Word, Some(want), Some(0), what);
    }
    // A second inside read, its entry held: one microcycle held.
    p.pdl_pointer(0o107);
    p.copies(PAGE2, 0o100);
    p.read(PAGE2 as Word, Some(pdl_word(0o100)), Some(0), "inside, the entry held");
    p.read(PAGE2 as Word, Some(pdl_word(0o100)), Some(0), "inside again");
    p.park();
    (p, Expect { redirects: Some([4 + 1 + 1 + 3 + 2, 2 + 1]), ..Expect::default() })
}

// ---------------------------------------------------------------- fiddle

/// The fiddles' pages: a stack page, and a page sharing its index in a TLB
/// of 4,096 entries.
const FIDDLED: [u32; 4] = [0o2005 << 10, 0o2006 << 10, 0o2007 << 10, 0o2010 << 10];
/// The word the test writes, one past the page's first word: inside the
/// copies' range, at the buffer's index 101.
const FIDDLE_WORD: Word = w(0o025, 0x5a5a);

/// **E1 and E2** (A14.4, A14.6, A14.7; muir's
/// `e1_a_port_b_fill_evicts_a_status_5_fiddle_and_the_write_is_redirected`
/// and `e2_a_port_b_fill_evicts_a_status_6_fiddle_and_the_write_faults`):
/// the table gives a page status 5 (or 6) with access `01`; a direct write
/// gives it access `11`; `MAP(MD)` of a list pointer to a page with the
/// same index, or a map-bit dispatch on one, misses and fills in its place;
/// and the write to the page then walks again and is redirected into the
/// buffer (status 5) or faults (status 6), memory unchanged.  The control,
/// a dispatch on a fixnum naming the other page, looks nothing up, and the
/// write reaches memory.  With `am`, every entry is accessed and modified
/// already, so that nothing is written back (`fiddleam`; see `redirectam`).
fn fiddle_program(am: bool) -> (Prog, Expect) {
    let entry = |s: u64, a: u64, f: u32| if am { entry(s, a, f) | A | M } else { entry(s, a, f) };
    let rw = |f: u32| if am { rw(f) | A | M } else { rw(f) };
    #[derive(Clone, Copy)]
    enum Lookup {
        MapMd,
        Dispatch,
        Fixnum,
    }
    let cases: [(u64, Lookup); 4] =
        [(5, Lookup::MapMd), (5, Lookup::Dispatch), (5, Lookup::Fixnum), (6, Lookup::MapMd)];
    let mut t = Tables::default();
    let mut frames = Vec::new();
    for (k, &(status, _)) in cases.iter().enumerate() {
        let k = k as u32;
        let same = FIDDLED[k as usize] + (4096 << 10);
        t.map(FIDDLED[k as usize], entry(status, 1, 0o200 + k));
        t.map(same, rw(0o300 + k));
        frames.push(0o200 + k);
    }
    let mut p = Prog::new();
    p.start().tables(&t);
    for &f in &frames {
        p.poke(f << 10 | 1, 0);
    }
    p.write(1 << 0o16, reg(0o222), Some(0), "222, LIST");
    p.pdl(0o101, pdl_word(0o101));
    p.pdl_pointer(0o107);
    for (k, &(status, lookup)) in cases.iter().enumerate() {
        let page = FIDDLED[k];
        let same = page + (4096 << 10);
        p.copies(page, 0o100);
        p.tlb_op(1, page as Word, entry(status, 3, frames[k]) & ENTRY);
        match lookup {
            Lookup::MapMd => {
                p.map(LIST | same as Word, None, "MAP(MD) of the same index");
            }
            Lookup::Dispatch => {
                p.transport(LIST | same as Word, None, "a dispatch on the same index");
            }
            Lookup::Fixnum => {
                p.transport(FIX | same as Word, None, "a dispatch on a fixnum");
            }
        }
        let fault = if status == 6 && !matches!(lookup, Lookup::Fixnum) { 1 } else { 0 };
        p.write(FIDDLE_WORD, (page + 1) as Word, Some(fault), "the fiddled write");
        let in_memory = matches!(lookup, Lookup::Fixnum);
        p.peek(frames[k] << 10 | 1, if in_memory { FIDDLE_WORD } else { 0 }, "memory's word");
        // The buffer's word 101, back through an inside read of status 5.
        if status == 5 {
            let want = if in_memory { pdl_word(0o101) } else { FIDDLE_WORD };
            p.tlb_op(2, page as Word, 0);
            p.read((page + 1) as Word, Some(want), Some(0), "the buffer's word 101");
            p.pdl(0o101, pdl_word(0o101));
        }
    }
    p.park();
    // Evictions: port B's of status 5 (MAP(MD), the dispatch) and 6.
    let mut evicted = [[0u64; 8]; 2];
    evicted[1][5] = 2;
    evicted[1][6] = 1;
    (p, Expect { evicted: Some(evicted), ..Expect::default() })
}

// ---------------------------------------------------------------- double

/// **A double miss at one index** (A14.4; muir's
/// `a_double_miss_at_one_index_and_a_port_a_eviction_are_counted`): a write
/// start to page P, its `MD` a list pointer to a page Q at P's index, and
/// in the next microcycle `MAP(MD)`: port A misses on P and port B on Q in
/// one microcycle, both walk, and P's fill replaces a direct write for a
/// third page R; the control, Q at another index, counts no double miss.
fn double_program() -> (Prog, Expect) {
    const P: [u32; 2] = [0o3001 << 10, 0o3002 << 10];
    let qs = [P[0] + (4096 << 10), P[1] + (1 << 10)];
    let mut t = Tables::default();
    for k in 0..2 {
        t.map(P[k], rw(0o300 + 2 * k as u32));
        t.map(qs[k], rw(0o301 + 2 * k as u32));
    }
    let mut p = Prog::new();
    p.start().tables(&t);
    for k in 0..2 {
        let r = P[k] + (8192 << 10);
        p.tlb_op(1, r as Word, rw(0o302) & ENTRY);
        let (qa, pa) = (p.k(LIST | qs[k] as Word), p.k(P[k] as Word));
        p.op(ALU | SETA | a_src(qa) | MD);
        p.op(ALU | SETA | a_src(pa) | START_WRITE);
        p.put(ALU | SETM | SRC_MAP, None, "MAP(MD) of Q");
        p.fill(2);
        p.peek((0o300 + 2 * k as u32) << 10, LIST | qs[k] as Word, "the write went out");
    }
    p.park();
    let mut evicted = [[0u64; 8]; 2];
    evicted[0][4] = 2;
    (p, Expect { walks: Some(2 + 2), double_misses: Some(1), evicted: Some(evicted), ..Expect::default() })
}

// --------------------------------------------------------------- inflight

/// The pages of the walks behind a cycle in flight, each the first of its
/// eight-entry line of page-table words; and a page beside each, in the
/// same line, whose walk brings the line into the cache first.
const INFLIGHT: [u32; 8] = [0o5000 << 10, 0o5010 << 10, 0o5020 << 10, 0o5030 << 10,
                            0o5040 << 10, 0o5050 << 10, 0o5060 << 10, 0o5070 << 10];
/// The page the write-back's read goes through (W4), accessed 0.
const INFLIGHT_V: u32 = 0o5200 << 10;
/// The frame buffer's word the second W1 reads, through the device window.
const INFLIGHT_FB: u32 = 0o34000000100;

/// **A walk's read behind the cycle in flight** (clarification 74, A14.6):
/// `MD` is loaded from a register, a start goes out, and `MAP(MD)` misses on
/// port B while the start's cycle is granted and not yet acknowledged; the
/// walk's reads are taken at the acknowledgment.  W1, the cycle a line
/// fill of another line, in main memory and in the frame buffer, whose
/// fills take a tick less, so the acknowledgment falls at two places in
/// the generator cycle; W2, a fill of the line the page entry is in; W3, a
/// read that hits, at two distances; W4, a read through a page whose entry
/// says accessed 0, so that the cycle waits for its write-back, `MAP(MD)`
/// at three distances from the start.  Every word read holds the pointer
/// the walk is for, so the walk's `MD` is that pointer whether the read's
/// word has landed or not.  W5, the control, is `inflight0`: the same walk
/// with no cycle in flight.  `inflightfb` is W1 on the frame buffer alone,
/// whose acknowledgment lands on a generator edge inside the walk's hold.
fn inflight_program(fb: bool) -> (Prog, Expect) {
    let q = INFLIGHT;
    let mut t = Tables::default();
    let mut frames = Vec::new();
    for (k, &page) in q.iter().enumerate() {
        t.map(page, rw(0o400 + 2 * k as u32));
        t.map(page + (1 << 10), rw(0o401 + 2 * k as u32));
        frames.push(0o400 + 2 * k as u32);
    }
    let v_at = t.map(INFLIGHT_V, rw(0o420));
    // W2's page: its entry's line is not brought in first; the word beside
    // the entry holds the pointer the read loads.
    let w2_at = t.entry_at(q[2]);
    t.words.push((w2_at + 1, LIST | q[2] as Word));
    // The words the reads take: the pointer each walk is for.
    let x = [0o430u32 << 10, 0o431 << 10, 0o432 << 10, 0o433 << 10];
    let mut p = Prog::new();
    p.start().tables(&t);
    p.poke(x[0], LIST | q[0] as Word);
    p.poke(x[2], LIST | q[3] as Word);
    p.poke(x[3], LIST | q[4] as Word);
    p.poke(0o420 << 10, LIST | q[5] as Word);
    p.write(LIST | q[1] as Word, INFLIGHT_FB as Word, Some(0), "the frame buffer's word");
    // Each walk's lines in the cache, by a walk of the page beside it (W2's
    // page entry's excepted); and V in the TLB, accessed 0, by port B's walk,
    // which sets nothing.
    for (k, &page) in q.iter().enumerate() {
        if k != 2 {
            p.map((page + (1 << 10)) as Word, Some(rw(0o401 + 2 * k as u32) & ENTRY), "the line, first");
        }
    }
    p.map(INFLIGHT_V as Word, Some(rw(0o420) & ENTRY), "V, accessed 0");
    // W3's line, in the cache.
    p.read(phys_va(x[2]), Some(LIST | q[3] as Word), Some(0), "W3's line, first");
    p.read(phys_va(x[3]), Some(LIST | q[4] as Word), Some(0), "W3's other line, first");
    // One scenario: `MD` the pointer, the start of a read of `va`, `gap`
    // fillers, then `MAP(MD)` of the page, and `MD` read back.
    // The frame buffer's words are 32 bits, and read back as fixnums.
    let scenario = |p: &mut Prog, page: u32, frame: u32, va: Word, gap: usize, what: &str| {
        let (pa, va_a) = (p.k(LIST | page as Word), p.k(va));
        p.op(ALU | SETA | a_src(pa) | MD);
        p.op(ALU | SETA | a_src(va_a) | START_READ);
        p.fill(gap);
        p.put_masked(ALU | SETM | SRC_MAP, rw(frame) & ENTRY, ENTRY, &format!("{what}: MAP(MD)"));
        let tag = if va == INFLIGHT_FB as Word { FIX } else { LIST };
        p.put(ALU | SETM | SRC_MD, Some(tag | page as Word), &format!("{what}: MD"));
    };
    if fb {
        scenario(&mut p, q[1], frames[1], INFLIGHT_FB as Word, 1, "W1, a frame buffer line");
        p.park();
        return (p, Expect::default());
    }
    scenario(&mut p, q[0], frames[0], phys_va(x[0]), 1, "W1, a main memory line");
    scenario(&mut p, q[2], frames[2], phys_va(w2_at + 1), 1, "W2, the page entry's line");
    scenario(&mut p, q[3], frames[3], phys_va(x[2]), 0, "W3, a hit, at once");
    scenario(&mut p, q[4], frames[4], phys_va(x[3]), 1, "W3, a hit, a microcycle on");
    for (gap, k) in [(0usize, 5usize), (1, 6), (2, 7)] {
        if k != 5 {
            p.poke(0o420 << 10, LIST | q[k] as Word);
            p.poke(v_at, rw(0o420));
            p.tlb_op(2, INFLIGHT_V as Word, 0);
            p.map(INFLIGHT_V as Word, Some(rw(0o420) & ENTRY), "V again, accessed 0");
        }
        scenario(&mut p, q[k], frames[k], INFLIGHT_V as Word, gap, &format!("W4, {gap} between"));
        p.map(INFLIGHT_V as Word, Some((rw(0o420) | A) & ENTRY), "W4: V's entry, accessed");
        p.peek(v_at, rw(0o420) | A, "W4: V's table word, accessed");
        p.read(reg(0o224), Some(0), Some(0), "W4: nothing refused");
    }
    p.park();
    (p, Expect::default())
}

/// **W5, the control**: the same walk with no cycle in flight, at two
/// distances from `MD`'s load.
fn inflight0_program() -> (Prog, Expect) {
    let q = [0o5100u32 << 10, 0o5110 << 10];
    let mut t = Tables::default();
    for (k, &page) in q.iter().enumerate() {
        t.map(page, rw(0o440 + 2 * k as u32));
        t.map(page + (1 << 10), rw(0o441 + 2 * k as u32));
    }
    let mut p = Prog::new();
    p.start().tables(&t);
    for (k, &page) in q.iter().enumerate() {
        p.map((page + (1 << 10)) as Word, Some(rw(0o441 + 2 * k as u32) & ENTRY), "the line, first");
    }
    for (k, gap) in [(0usize, 2usize), (1, 3)] {
        let pa = p.k(LIST | q[k] as Word);
        p.op(ALU | SETA | a_src(pa) | MD);
        p.fill(gap);
        p.put_masked(ALU | SETM | SRC_MAP, rw(0o440 + 2 * k as u32) & ENTRY, ENTRY,
                     &format!("W5, {gap} after MD: MAP(MD)"));
    }
    p.park();
    (p, Expect::default())
}

// ------------------------------------------------------------------ main

/// What muir's model is to have counted at the end of a program, as the
/// test asserts it; `None` is not asserted.
#[derive(Default)]
struct Expect {
    walks: Option<u64>,
    sweeps: Option<u64>,
    write_backs: Option<u64>,
    written_bits: Option<[u64; 3]>,
    refusals: Option<u64>,
    redirects: Option<[u64; 2]>,
    evicted: Option<[[u64; 8]; 2]>,
    double_misses: Option<u64>,
}

/// The TLB's entries a program is held at: 8,192 for `empty8k`, the
/// default 4,096 otherwise (`--tlb`, A14.4).
fn tlb_entries(name: &str) -> u32 {
    if name == "empty8k" { 8192 } else { 4096 }
}

fn program(name: &str) -> (Prog, Expect) {
    match name {
        "windows" => windows_program(),
        "space" => space_program(tlb_entries(name)),
        "walk" => walk_program(),
        "noentry" => noentry_program(),
        "empty" | "empty8k" => empty_program(),
        "mapmd" => mapmd_program(),
        "lc" => lc_program(),
        "fetch" => fetch_program(),
        "words" => words_program(),
        "writeback" => writeback_program(),
        "setter" => setter_program(1),
        "setter0" => setter_program(0),
        "wbhold" => wbhold_program(),
        "redirect" => redirect_program(false),
        "redirectam" => redirect_program(true),
        "fiddle" => fiddle_program(false),
        "fiddleam" => fiddle_program(true),
        "double" => double_program(),
        "inflight" => inflight_program(false),
        "inflightfb" => inflight_program(true),
        "inflight0" => inflight0_program(),
        _ => {
            eprintln!(
                "quux14: no program `{name}`; they are windows, space, walk, noentry, empty, empty8k, mapmd, lc, \
                 fetch, words, writeback, setter, setter0, wbhold, redirect, redirectam, fiddle, fiddleam, double, \
                 inflight, inflightfb and inflight0"
            );
            std::process::exit(2);
        }
    }
}

/// Revision 14's machine with `prom` in QUUX's PROM, as `machine_axis`
/// builds QUUX, at revision 14's geometry, 32 boards and `entries` TLB
/// entries.
fn machine(prom: &[Insn], entries: u32) -> Machine {
    let mut m = Which::Quux.machine(prom);
    m.geometry = REV14;
    m.main = vec![0; MAIN as usize];
    m.set_tlb_entries(entries as usize);
    m
}

/// Every result the program was to leave, from the machine's A memory, and
/// the model's counts.
fn check(name: &str, p: &Prog, x: &Expect, m: &Machine) {
    let mut bad = 0;
    for (a, want, mask, what) in &p.results {
        let got = m.amem[*a as usize];
        if let Some(want) = want
            && got & mask != *want
        {
            eprintln!("quux14: {name}: A {a:o}, {what}: {got:#012x}, not {want:#012x}");
            bad += 1;
        }
    }
    let t = &m.tlb;
    let mut count = |what: &str, got: String, want: Option<String>| {
        if let Some(want) = want
            && got != want
        {
            eprintln!("quux14: {name}: {what}: {got}, not {want}");
            bad += 1;
        }
    };
    count("walks", format!("{}", t.walks), x.walks.map(|v| format!("{v}")));
    count("sweeps", format!("{}", t.sweeps), x.sweeps.map(|v| format!("{v}")));
    count("write-backs", format!("{}", t.write_backs), x.write_backs.map(|v| format!("{v}")));
    count("bits written", format!("{:?}", t.written_bits), x.written_bits.map(|v| format!("{v:?}")));
    count("refusals", format!("{}", t.refusals), x.refusals.map(|v| format!("{v}")));
    count("redirects", format!("{:?}", t.redirects), x.redirects.map(|v| format!("{v:?}")));
    count("evictions", format!("{:?}", t.evicted), x.evicted.map(|v| format!("{v:?}")));
    count("double misses", format!("{}", t.double_misses), x.double_misses.map(|v| format!("{v}")));
    assert_eq!(bad, 0, "quux14: {name}: {bad} results or counts are not muir's test's");
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    if which != Which::Quux {
        eprintln!("quux14: revision 14 is QUUX's; give --machine quux or no --machine");
    }
    let prom_only = args.iter().any(|a| a == "--prom");
    let timing = if prom_only && !args.iter().any(|a| a == "--sync-cycle-ticks") {
        muir::clock::TimingModel::Fpga
    } else {
        machine_axis::take_timing(Which::Quux, &mut args)
    };
    let mut name = None;
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--program" => name = it.next(),
            "--prom" => {}
            _ => {
                eprintln!("quux14: unknown argument `{a}`");
                std::process::exit(2);
            }
        }
    }
    let Some(name) = name else {
        eprintln!("usage: quux14 --program <name> [--sync-cycle-ticks K [--sync-ilong-ticks L]] [--prom]");
        std::process::exit(2);
    };
    let (prog, expect) = program(&name);
    let prom = prog.prom();
    let entries = tlb_entries(&name);

    if prom_only {
        for k in 0..PROM_WORDS {
            println!("{:012x}", prom.get(k).map_or(0, |w| w.raw()));
        }
        return;
    }

    // The run's length: to the park, and sixteen microcycles on.
    let park = QUUX_PROM_BASE as u64 + prog.words.len() as u64 - 2;
    let n = {
        let mut probe = trace::engine_on(machine(&prom, entries), timing);
        probe.boot();
        let mut t = trace::Trace::new(&probe);
        let mut cycle = 0u64;
        while probe.pc() as u64 != park {
            assert!(cycle < 400_000, "quux14: {name} never reached its park");
            if let Err(h) = t.row(&mut probe, cycle) {
                panic!("quux14: {name} stopped at microcycle {cycle}: {h:?}");
            }
            cycle += 1;
        }
        cycle + 16
    };

    let mut e = trace::engine_on(machine(&prom, entries), timing);
    e.boot();
    println!("{}", trace::COLUMNS);
    println!(
        "# generated by golden/src/quux14.rs from muir's rtl engine: program {name}, machine: quux, revision 14{}",
        machine_axis::timing_suffix(Which::Quux, timing)
    );
    println!("{}", trace::RADIX);
    println!("# rtc {:x}", machine_axis::RTC_START);
    let mut t = trace::Trace::new(&e);
    for cycle in 0..n {
        match t.row(&mut e, cycle) {
            Ok(line) => {
                println!("{line}");
            }
            Err(h) => {
                eprintln!("quux14: {name} stopped at microcycle {cycle}: {h:?}");
                std::process::exit(1);
            }
        }
    }
    check(&name, &prog, &expect, e.machine());
    // The file device's two bases as the run leaves them, which the
    // testbench reads through the readout's selector 12, as for revision
    // 13's programs.
    {
        use muir::file_device as fd;
        let dev = &e.machine().file_device;
        println!("# fdbases {:x} {:x}", dev.read(fd::CMD_BASE, e.ns()), dev.read(fd::RESP_BASE, e.ns()));
    }
    // And the memory system's words and the redirect's copies as the run
    // leaves them, which the testbench reads through the readout's entries
    // 41 to 45 (A14.14).
    {
        let w = &e.machine().memory_words;
        let c = &e.machine().pdl_copies;
        println!("# mswords {:x} {:x} {:x}", w.directory | u32::from(w.ephemeral) << 18, w.pointer_types, w.refused);
        println!("# pdlcopies {:x} {:x}", c.base, c.head);
    }
    let tl = &e.machine().tlb;
    let c = e.cache().expect("revision 14 has its cache");
    eprintln!(
        "quux14: {name}: {n} microcycles, {} ns ({} stalled), {} bus cycles, {} results, PC {:o}, {} words; \
         the cache {} hits and {} misses; the TLB {} entries, {} walks, {} sweeps, {} write-backs {:?}, \
         {} refused, redirects {:?}, evictions {:?}, {} double misses, {} ns held",
        e.ns(),
        e.stalled_ns(),
        e.bus_cycles(),
        prog.results.len(),
        e.pc(),
        prog.words.len(),
        c.hits,
        c.misses,
        tl.len(),
        tl.walks,
        tl.sweeps,
        tl.write_backs,
        tl.written_bits,
        tl.refusals,
        tl.redirects,
        tl.evicted,
        tl.double_misses,
        tl.held_ns,
    );
}
