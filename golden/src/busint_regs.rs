// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the bus interface's own Unibus registers, out of
//! muir's `busint::register` and `Machine::interface_read` and
//! `interface_write`.
//!
//! **What these are.** The 74S133 at UBCYC 0E08 decodes `0o766000` to
//! `0o766176` and the 74S139 at 0E07 splits it four ways on address bits 6
//! and 5: the diagnostic block, the interrupt block, the debug block and the
//! Unibus map. MIT's `unaddr.text` lists them the same way --- "CADR UNIBUS
//! interrupt status" at `766040`, "CADR XBUS error status" at `766044`,
//! "Debuggee's selected UNIBUS location" from `766100`, and "`XBUS<->
//! UNIBUS` mapping registers" at `766140`-`766176`.
//!
//! The diagnostic block is `rtl/machine/cadr_spy_registers.sv` and has been
//! since the console. The debug block is a cycle on the other machine's bus
//! and is answered over the cable, which is not built and is not decoded
//! here: `busint::register` gives it `None`. What this trace is for is the
//! other two, `rtl/machine/cadr_busint_regs.sv`.
//!
//! **Why a scripted program and not a reference program.** MIT's boot PROM
//! reaches the interface block once in 600,000 microcycles, and that once is
//! the mode register in the DIAGNOSTIC group. A System 100 band reaches
//! `0o766040` 240 times in 2,800,000 microcycles and neither `0o766044` nor
//! any map register at all --- and the band trace runs against
//! `Vcadr_microcycle`, where the memory path is stimulus, so it could not
//! compare a register on the far side of it in any case. So this program is
//! the only reference, in the shape `iob.rs` is for the card.
//!
//! **What the trace carries.**
//!
//! - `IFACENONE` and `IFACE`, the whole of `busint::register` over the
//!   18-bit Unibus space: a run for each stretch it answers nothing in, one
//!   row an address for the rest. The decode is worth checking exhaustively
//!   for one reason above all: within the interrupt block the 74S138 at
//!   0E03 looks only at address bits 2 and 1, so the four registers repeat
//!   every eight bytes through `0o766076`, and an aliasing decode is
//!   exactly the thing a hand transcription gets wrong.
//! - `OP`, one register cycle: the address, the direction, the word
//!   written, the word read, and the three lines the interface's own
//!   registers are a function of besides their own state --- `XBUS INTR
//!   IN`, and the card's request and its vector.
//! - `LINES`, the three wires moving. They move on no other row, which is
//!   what lets the fabric hold them for the whole of a cycle, as levels on
//!   a backplane and on a cable are held; every `OP` row asserts that its
//!   own cycle left all three where it found them.
//! - `ERR`, a bus cycle of the interface's own that timed out, which is
//!   what sets the error status register's two NXM bits. `which` is 0 for
//!   an Xbus cycle and 1 for a Unibus one.
//!
//! **Every row ends with the same face**, sampled after whatever the row
//! did: the interrupt status register and the error status register as a
//! read of `0o766040` and `0o766044` gives them, the Unibus interrupt the
//! interface has taken, and `LM INT` --- which is `SINTR`, the one line
//! these registers put into the processor.
//!
//! The face is read back over the bus rather than taken out of muir's
//! fields, so every column of it is a thing the fabric can be asked for at
//! the same seam. `Machine::interface_read` has no side effects, which is
//! what makes reading it on every row free.
//!
//! **And the mapped window, `0o140000`-`0o177777`.**
//!
//! - `MAPA` and `MAPANONE`, `busint::map_access` over the same eighteen
//!   bits: a row an address inside the window giving `UBA<13:10>`,
//!   `UBA<9:2>` and `UBA1`, and a run for each stretch outside it.
//! - `MAPSWEEP`, sixteen map entries and the physical page
//!   `Machine::map_entry` reads out of each, so that the exhaustive sweep
//!   of the window has muir's own translation to compare against rather
//!   than the testbench's arithmetic.
//! - `MAP`, one mapped cycle: `Machine::mapped_read` or
//!   `Machine::mapped_write`, with the responder `Rtl::try_debug_request`
//!   makes for it, the physical address and the thirty-two bits that cross
//!   the Xbus, and the word the master gets.
//! - `MAPMD`, one mapped write that goes into the processor's `MD` instead
//!   of the Xbus: `busint::map_to_md`, CC's `CC-WRITE-MD`. It carries the
//!   thirty-two bits `Machine::mapped_write` put there and `MD` itself
//!   afterwards, which no `MAP` row has a column for.
//!
//! **Main memory is poisoned injectively in the physical address** before
//! any of it, so a read the map sent to the wrong page takes a word muir
//! never had. The testbench's modeled memory computes the same function
//! from the address the FABRIC puts out and the trace carries muir's own
//! answer, so the two meet only if the translation is right.
//!
//! **THE ONE MASTER muir HAS FOR A MAPPED CYCLE IS THE DEBUG CABLE'S, AND
//! THIS PROGRAM IS NOT IT.** It calls `Machine::mapped_read` and
//! `mapped_write` directly, as it calls `Machine::bus_read` for the
//! register cycles rather than running a processor, and
//! `rtl/machine/cadr_dbgin.sv` is not composed into `cadr_machine` at all.
//! What that costs is the timing, which comes out of
//! `Busint::debug_set_master` and `debug_xbus_edge` as constants in this
//! header rather than out of a trace of a real master; and it costs the
//! coverage a program would give, there being no program.
//!
//! **What is deliberately not here.**
//!
//! - A mapped page that is not main memory. `Busint::debug_xbus_edge` says
//!   in its own words that "a mapped page nothing answers" is **not
//!   modeled**, so no row asks for one and the fabric's arbiter refuses
//!   such a page the bus rather than guessing at its timing.
//! - A read through a page whose high five bits are ones. `MD` is
//!   write-only through the map: `Rtl::try_debug_request` tests
//!   `req.write` before `map_to_md`, so the odd word of a read is the
//!   page's read buffer and the even word is a mapped Xbus cycle at
//!   page `0o37000`, which is the Unibus and not main memory --- and
//!   `Busint::debug_xbus_edge` says a mapped page nothing answers is not
//!   modeled. Both halves of a read through CC's own entry are here, the
//!   even one through a real page, and neither touches `MD`.
//! - The debug block at `0o766100`-`0o766136`. `busint::register` decodes
//!   it to `None` and this trace says so in its `IFACENONE` runs, which is
//!   the claim the fabric has to hold: those four registers are no register
//!   of this board's and answer over the cable or not at all.
//!
//! - `DBGREG`, `DBGTMO` and `DBGOUT`, the debug block itself, APPENDED at the
//!   end of the trace so that every row above them stays byte for byte what
//!   it was.  They are the DBGOUT page --- this machine as somebody else's
//!   debugger --- and they come out of `busint::Busint` rather than out of
//!   `Machine`, which has no cable in it at all: `Machine::device` gives
//!   `Responder::Debug(_)` no word and no error and says why.

use muir::busint::{self, Busint, DebugOut, Register, Responder, error_status, interrupt_status};
use muir::ioboard::{self, csr};
use muir::tv::mode;
use muir::machine::{self, Machine};

/// The Unibus is 18 bits and byte-addressed.
const UB_ADDRESSES: u32 = 1 << 18;

/// `ffffffff` in a column that can be absent: no register at this address,
/// no word on a write, no interrupt taken.
const NONE: u32 = 0xffff_ffff;

/// Which of the six the decode makes of an address. The numbers are the
/// trace's own and the testbench's `enum` follows them.
fn kind(r: Register) -> (u32, u32) {
    match r {
        Register::Diagnostic(n) => (0, n as u32),
        Register::InterruptControl => (1, 0),
        Register::InterruptControl2 => (2, 0),
        Register::ErrorStatus => (3, 0),
        Register::Unused => (4, 0),
        Register::Map(n) => (5, n as u32),
    }
}

/// The card's registers this program drives, as Unibus addresses.
const CSR: u32 = 0o764112;

/// `busint::debug_register`'s range: the debug block, whose four registers
/// repeat through it because bits 4 and 1 are not decoded.
const DBG_LOW: u32 = 0o766100;
const DBG_HIGH: u32 = 0o766137;

/// What `Rtl::try_debug_request` answered, in the trace's own numbering:
/// `Responder::MapBuffer`, `MapXbus`, `MapRefused` and `MapMd`. The last two
/// are never acknowledged and the testbench's `enum` follows these numbers.
const RESP_BUFFER: u32 = 0;
const RESP_XBUS: u32 = 1;
const RESP_REFUSED: u32 = 2;
const RESP_MD: u32 = 3;

/// The map registers this program programs, and the physical pages it points
/// them at. `MAP_WT` is above `0o10` because that is where write-through
/// bites, and `MAP_MD` is `0o16` because that is the one CC uses:
/// "`CC-WRITE-MD` loads map register `16` with `177000`".
const MAP_RW: u32 = 0o0;
const MAP_RO: u32 = 0o1;
const MAP_BAD: u32 = 0o2;
const MAP_BADHI: u32 = 0o13;
const MAP_WT: u32 = 0o12;
const MAP_MD: u32 = 0o16;
const PAGE_RW: u32 = 0o0123;
const PAGE_RO: u32 = 0o2525;
const PAGE_WT: u32 = 0o1357;

/// A word injective in the physical address: multiplication by an odd
/// constant is a bijection on 32 bits, so no two words of main memory hold
/// the same poison and a read the map sent one page wide takes a word muir
/// never had. `tb/cadr_busint_regs_tb.cpp` computes the same function from
/// the address the FABRIC puts out, and every `MAP` row carries muir's own
/// answer beside it, so the two are compared rather than assumed equal.
fn mpoison(phys: u32) -> u32 {
    ((phys ^ 0x0015_5555).wrapping_mul(0x9E37_7969)) ^ 0x5A5A_5A5A
}

/// The Unibus address of one word of one mapped page: `busint::map_access`
/// read backwards, and asserted against it at every use.
fn uw(page: u32, word: u32, high: bool) -> u32 {
    let u = 0o140000 + (page << 10) + (word << 2) + (u32::from(high) << 1);
    let a = busint::map_access(u).expect("inside the window");
    assert_eq!((a.page as u32, a.word, a.high), (page, word, high));
    u
}

/// The outcome muir gives a mapped cycle. `Rtl::try_debug_request` is the one
/// place in muir that makes a map responder and it publishes the answer
/// nowhere, so this is a READING of that function rather than a call of it.
/// `Gen::mapped` then asserts every branch of it against what
/// `Machine::mapped_read` and `mapped_write` themselves did, and the
/// generator writes no trace where the two disagree --- which is the
/// derivation and the check that CLAUDE.md says settle a number between them.
fn responder(m: &Machine, a: busint::MapAccess, write: bool) -> (u32, Option<u32>) {
    if a.high != write && !(write && m.write_through && a.page >= 0o10) {
        return (RESP_BUFFER, None);
    }
    match m.map_entry(a.page) {
        Some((p, true)) if write && busint::map_to_md(p) => (RESP_MD, None),
        Some((p, w)) if !write || w => (RESP_XBUS, Some((p << 8) | a.word)),
        _ => (RESP_REFUSED, None),
    }
}

/// The display's mode register, `tv::CONTROL` --- the one thing in
/// this process that can raise `XBUS INTR IN`, the disk having no drive.
const TV_MODE: u32 = 0o17377760;

struct Gen {
    m: Machine,
    out: Vec<String>,
    line: u64,
    ops: u64,
    errs: u64,
    lines_rows: u64,
    /// Every `(kind, reg)` an `OP` row has reached, so that the program can
    /// assert it left none of the interface's registers alone.
    reached: Vec<(u32, u32)>,
    /// Whether `XBUS INTR IN` and `UB INT` were each seen both ways.
    xint_seen: [bool; 2],
    ubint_seen: [bool; 2],
    err_bits: u16,
    /// Mapped cycles, and which of the four responders each reached.
    maps: u64,
    resp_seen: [u64; 4],
    /// `MAPMD` rows: mapped writes muir loaded `MD` with.
    md_writes: u64,
}

impl Gen {
    fn new() -> Gen {
        let mut m = Machine::new();
        // The card is on the Unibus from power-on; nothing is typed until
        // this program types.
        m.ns = 0;
        Gen {
            m,
            out: Vec::with_capacity(1 << 10),
            line: 0,
            ops: 0,
            errs: 0,
            lines_rows: 0,
            reached: Vec::new(),
            xint_seen: [false; 2],
            ubint_seen: [false; 2],
            err_bits: 0,
            maps: 0,
            resp_seen: [0; 4],
            md_writes: 0,
        }
    }

    /// The physical address a Unibus location is reached at, which is what
    /// `Machine::bus_read` and `bus_write` take.
    fn phys(uaddr: u32) -> u32 {
        busint::unibus_physical(uaddr)
    }

    /// `XBUS INTR IN`, and the card's request with its vector: the three
    /// wires the interrupt status register reads that are not its own.
    fn lines(&mut self) -> (u32, u32, u32) {
        let x = u32::from(self.m.xbus_interrupt());
        let req = self.m.ioboard.interrupt_request(self.m.ns);
        (x, u32::from(req.is_some()), req.unwrap_or(0) as u32)
    }

    /// The face: the two registers as a read of them gives them, the Unibus
    /// interrupt taken, and `LM INT`.
    fn face(&mut self) -> String {
        let ctl = self.m.bus_read(Self::phys(0o766040));
        let err = self.m.bus_read(Self::phys(0o766044));
        let ub = self.m.unibus_interrupt();
        let int = u32::from(self.m.interrupt());
        self.xint_seen[usize::from(ctl & interrupt_status::XBUS_INTR as u32 != 0)] = true;
        self.ubint_seen[usize::from(ub.is_some())] = true;
        self.err_bits |= (err as u16) & 0o77;
        format!("{ctl:x} {err:x} {:x} {int}", ub.map_or(NONE, u32::from))
    }

    fn say(&mut self, tag: &str, head: String) {
        let n = self.line;
        self.line += 1;
        let face = self.face();
        self.out.push(format!("{tag} {n} {head} {face}"));
    }

    /// The three wires the interface's registers read and do not hold ---
    /// `XBUS INTR IN`, and the card's own request with its vector --- moved
    /// to where the model now has them, with the face after.
    ///
    /// **They move only here.** Every `OP` row asserts that its cycle left
    /// all three where it found them, so the fabric can drive them from the
    /// row's own columns and hold them for the whole cycle, which is what
    /// the board does: they are levels on a backplane and on a cable.
    fn lines_row(&mut self) {
        let (x, req, vec) = self.lines();
        self.say("LINES", format!("{x} {req} {vec:x}"));
        self.lines_rows += 1;
    }

    /// One register cycle. The word read is compared by the testbench and
    /// the write's effect shows in the face of this row and every row after.
    fn cyc(&mut self, uaddr: u32, write: bool, wdata: u16) -> u32 {
        let before = self.lines();
        let rdata = if write {
            self.m.bus_write(Self::phys(uaddr), wdata as u32);
            NONE
        } else {
            self.m.bus_read(Self::phys(uaddr)) & 0xffff
        };
        assert_eq!(before, self.lines(), "the cycle at {uaddr:o} moved a wire; use a LINES row");
        if let Some(r) = busint::register(uaddr) {
            let k = kind(r);
            if !self.reached.contains(&k) {
                self.reached.push(k);
            }
        }
        let (x, req, vec) = before;
        let w = u32::from(write);
        self.say("OP", format!("{w} {uaddr:o} {wdata:x} {x} {req} {vec:x} {rdata:x}"));
        self.ops += 1;
        rdata
    }

    fn read(&mut self, uaddr: u32) -> u32 {
        self.cyc(uaddr, false, 0)
    }

    fn write(&mut self, uaddr: u32, v: u16) {
        self.cyc(uaddr, true, v);
    }

    /// A bus cycle of the interface's own that nothing answered: the NXM
    /// timeout, which sets one of the error status register's two bits.
    /// muir sets the bit at the decode, where it can see there is no
    /// responder; the board sets it when the timer runs out, and the two
    /// agree because a cycle nothing answers always runs the timer out.
    fn nxm(&mut self, phys: u32, unibus: bool) {
        let want = busint::decode(phys, self.m.memory_boards() << 16);
        assert!(
            matches!(want, busint::Responder::NoXbus | busint::Responder::NoUnibus),
            "{phys:o} answers {want:?}, so no timeout would happen there"
        );
        assert_eq!(
            unibus,
            matches!(want, busint::Responder::NoUnibus),
            "{phys:o} is on the other bus"
        );
        let before = self.lines();
        self.m.bus_read(phys);
        assert_eq!(before, self.lines(), "a timeout moved a wire");
        let which = u32::from(unibus);
        self.say("ERR", format!("{which}"));
        self.errs += 1;
    }


    /// The card, the display and the clock, reached without a row of their
    /// own: what these change is one of the three wires, and a `LINES` row
    /// is how the trace says so.  A cycle at one of their addresses is an
    /// `OP` row only where it changes nothing, and the assertion in `cyc`
    /// is what holds that.
    fn card_write(&mut self, uaddr: u32, v: u16) {
        self.m.bus_write(Self::phys(uaddr), v as u32);
        self.lines_row();
    }

    fn card_read(&mut self, uaddr: u32) -> u32 {
        let v = self.m.bus_read(Self::phys(uaddr)) & 0xffff;
        self.lines_row();
        v
    }

    /// Fill a physical page with the poison, straight into muir's own memory
    /// so that no bus cycle and no row goes with it.
    fn poison_page(&mut self, page: u32) {
        assert!(
            (((page as usize) + 1) << 8) <= self.m.main.len(),
            "{page:o} is not a page of main memory"
        );
        for w in 0..256u32 {
            let phys = (page << 8) | w;
            self.m.main[phys as usize] = mpoison(phys);
        }
    }

    /// One mapped cycle, `0o140000`-`0o177777`: `Machine::mapped_read` or
    /// `Machine::mapped_write`, which is what a Unibus master that is not
    /// this board reaches through the map. Returns the word the master got,
    /// or `NONE` for a write and for a cycle nothing ever answers.
    ///
    /// **Every branch here asserts `responder`'s reading against what muir's
    /// own two functions then did.** The trace is not written at all if the
    /// two disagree, which is what stops a reading of `Rtl` rotting quietly.
    fn mapped(&mut self, uaddr: u32, write: bool, v: u16) -> u32 {
        let a = busint::map_access(uaddr).expect("the address is inside the window");
        let k = a.page as usize;
        let before = self.lines();
        let (resp, phys) = responder(&self.m, a, write);
        if let Some(p) = phys {
            assert!(
                (p as usize) < self.m.main.len(),
                "{p:o} is not main memory, and Busint::debug_xbus_edge does not model one"
            );
        }
        let err0 = self.m.bus_error;
        let md0 = self.m.md;
        let rb0 = self.m.read_buffer;
        let wb0 = self.m.write_buffer;
        let mem0 = phys.map(|p| self.m.main[p as usize]);

        let (rdata, took) = if write {
            let ok = self.m.mapped_write(a, v);
            (NONE, ok)
        } else {
            match self.m.mapped_read(a) {
                Some(w) => (w as u32, true),
                None => (NONE, false),
            }
        };
        assert_eq!(before, self.lines(), "the mapped cycle at {uaddr:o} moved a wire");

        // The thirty-two bits that crossed the Xbus, where any did --- and
        // the cross-check of `responder` against muir itself.
        let whole = |high: bool| -> u32 {
            if high { ((v as u32) << 16) | wb0[k] as u32 } else { v as u32 }
        };
        let xword = match resp {
            RESP_BUFFER => {
                assert!(took, "a buffer cycle is always taken");
                assert_eq!(self.m.bus_error, err0, "a buffer cycle set an error bit");
                assert_eq!(self.m.md, md0, "a buffer cycle moved MD");
                if write {
                    assert_eq!(self.m.write_buffer[k], v, "the write buffer took the word");
                    assert_eq!(self.m.read_buffer, rb0, "a buffer write moved the read buffer");
                } else {
                    assert_eq!(rdata, rb0[k] as u32, "the read buffer answered");
                    assert_eq!(self.m.read_buffer, rb0, "a buffer read moved the read buffer");
                    assert_eq!(self.m.write_buffer, wb0, "a buffer read moved the write buffer");
                }
                NONE
            }
            RESP_XBUS => {
                let p = phys.expect("an Xbus access has a physical address");
                assert!(took, "an Xbus access the map allows is taken");
                assert_eq!(self.m.bus_error, err0, "an allowed Xbus access set an error bit");
                assert_eq!(self.m.md, md0, "an Xbus access moved MD");
                let w = self.m.main[p as usize];
                if write {
                    assert_eq!(w, whole(a.high), "the word muir wrote at {p:o}");
                    // The even word of a write-through is the only write that
                    // touches the buffer AND the Xbus.
                    if !a.high {
                        assert_eq!(self.m.write_buffer[k], v, "write-through left the buffer");
                    }
                } else {
                    assert_eq!(Some(w), mem0, "a read wrote main memory");
                    assert_eq!(rdata, w & 0xffff, "the low half is the answer");
                    assert_eq!(self.m.read_buffer[k] as u32, w >> 16, "the high half is the buffer");
                }
                w
            }
            RESP_REFUSED => {
                assert!(!took, "a refused access is not taken");
                assert_eq!(
                    self.m.bus_error,
                    err0 | machine::bus_error::UB_MAP_ERROR,
                    "a refused access sets UB MAP ERROR and nothing else"
                );
                assert_eq!(self.m.md, md0, "a refused access moved MD");
                assert_eq!(self.m.read_buffer, rb0, "a refused access moved the read buffer");
                // The one refusal that still writes the write buffer is
                // write-through's even word: `Machine::mapped_write` puts the
                // word in the buffer BEFORE it looks at the map at all.
                if write && !a.high {
                    assert_eq!(self.m.write_buffer[k], v, "write-through's buffer write");
                } else {
                    assert_eq!(self.m.write_buffer, wb0, "a refused access moved the write buffer");
                }
                NONE
            }
            _ => {
                assert!(took, "a write of MD is taken");
                assert_eq!(self.m.bus_error, err0, "a write of MD set an error bit");
                assert_eq!(self.m.md, whole(a.high), "the word muir put in MD");
                NONE
            }
        };

        let (x, req, vec) = before;
        let w = u32::from(write);
        let p = phys.unwrap_or(NONE);
        self.say(
            "MAP",
            format!("{w} {uaddr:o} {:x} {x} {req} {vec:x} {resp} {p:x} {xword:x} {rdata:x}", v),
        );
        self.maps += 1;
        self.resp_seen[resp as usize] += 1;
        rdata
    }

    /// One mapped write that `Rtl::try_debug_request` answers
    /// `Responder::MapMd`: the word is not written to the Xbus but loaded
    /// into the processor's `MD`. `busint::map_to_md`, CC's `CC-WRITE-MD`.
    ///
    /// It is a `MAPMD` row rather than a `MAP` row because it carries two
    /// columns no other mapped cycle has: the thirty-two bits
    /// `Machine::mapped_write` put in `MD`, and `MD` itself afterwards. The
    /// responder is not a column at all --- every row of this tag is
    /// `MapMd`, which the assertion below is what makes true.
    ///
    /// **A read never reaches here.** `Rtl::try_debug_request` tests
    /// `req.write` before it tests `map_to_md`, so the odd word of a read
    /// is the page's read buffer and the even word is a mapped Xbus cycle
    /// at a page that is not main memory --- which `Busint::debug_xbus_edge`
    /// says in its own words is **not modeled**. So `MD` is write-only
    /// through the map, and this generator cannot ask for the other half.
    fn mapped_md(&mut self, uaddr: u32, v: u16) -> u32 {
        let a = busint::map_access(uaddr).expect("the address is inside the window");
        let k = a.page as usize;
        let before = self.lines();
        let (resp, phys) = responder(&self.m, a, true);
        assert_eq!(resp, RESP_MD, "the cycle at {uaddr:o} is not a write of MD");
        assert_eq!(phys, None, "a write of MD makes no Xbus cycle");
        let err0 = self.m.bus_error;
        let rb0 = self.m.read_buffer;
        let wb0 = self.m.write_buffer;
        let main0 = self.m.main.clone();

        // `Machine::mapped_write`: the odd word carries the page's write
        // buffer under it, and write-through's even word puts ground above
        // the Unibus word. The same two halves the Xbus would have taken.
        let md32 = if a.high { ((v as u32) << 16) | wb0[k] as u32 } else { v as u32 };
        let took = self.m.mapped_write(a, v);
        assert!(took, "a write of MD is taken");
        assert_eq!(before, self.lines(), "the mapped cycle at {uaddr:o} moved a wire");
        assert_eq!(self.m.md, md32, "the word muir put in MD");
        assert_eq!(self.m.bus_error, err0, "a write of MD set an error bit");
        assert_eq!(self.m.read_buffer, rb0, "a write of MD moved the read buffer");
        // The even word is a buffer write as well, write-through sending it
        // to the map afterwards; the odd word leaves the buffer alone.
        if a.high {
            assert_eq!(self.m.write_buffer, wb0, "the odd word moved the write buffer");
        } else {
            assert_eq!(self.m.write_buffer[k], v, "write-through's own buffer write");
        }
        assert!(
            self.m.main.iter().zip(main0.iter()).all(|(x, y)| x == y),
            "a write of MD reached main memory"
        );

        let (x, req, vec) = before;
        self.say("MAPMD", format!("1 {uaddr:o} {v:x} {x} {req} {vec:x} {md32:x} {:x}", self.m.md));
        self.maps += 1;
        self.md_writes += 1;
        self.resp_seen[RESP_MD as usize] += 1;
        md32
    }

    /// Time passes with no cycle: the card's clocks run, which is what makes
    /// `CLOCK READY` and so a clock interrupt possible.
    fn wait(&mut self, ns: u64) {
        self.m.ns += ns;
        self.m.ioboard.advance(self.m.ns);
        self.lines_row();
    }
}

/// One cycle of the debugger's own into the debug block, run through muir's
/// `busint::Busint` at `rtl` fidelity.  `cable` is whether a board is at the
/// far end; `answer_after` is how long after the request on the cable that
/// board's `DEBUG ACK` comes back, or `None` for one that never answers.
///
/// What comes out is every instant the fabric can be held to: the grant,
/// `-UB MSYN`, the request on the cable, the acknowledgement, `-UB SSYN` and
/// `-LMACK`, with whether the interface gave up.
struct DbgCycle {
    grant_ns: u64,
    msyn_ns: u64,
    req_ns: Option<u64>,
    ans_ns: Option<u64>,
    ssyn_ns: u64,
    memack_ns: u64,
    timed_out: bool,
    taken: bool,
}

fn dbg_cycle(strobe: u8, write: bool, cable: bool, answer_after: Option<u64>) -> DbgCycle {
    // The tick and the microcycle, as `golden/src/busint_xbus.rs` has them:
    // MIT's 5 ns grid and 29 ticks at normal speed.
    const TICK_NS: u64 = 5;
    const MICRO: u64 = 29;

    let mut bi = Busint::new(1);
    if cable {
        bi.attach_debug_cable();
    }
    let resp = Responder::Debug(strobe);
    let mut grant_ns = None;
    let mut req_ns = None;
    let mut ans_ns = None;
    let mut taken = false;
    bi.request(write);

    for tick in 0..40_000u64 {
        let now = tick * TICK_NS;
        if tick % MICRO == 0 {
            bi.mclk_edge(now, resp);
        }
        if grant_ns.is_none() && bi.granted() {
            grant_ns = Some(now);
        }
        // What this side has put on the cable.  A `Release` is the interface
        // giving up, and it carries no new instant this trace needs.
        match bi.debug_out_take() {
            Some(DebugOut::Request { at, strobe: s }) => {
                assert_eq!(s, strobe, "the cable carries the strobe the address decoded to");
                req_ns = Some(at);
            }
            Some(DebugOut::Release { .. }) | None => {}
        }
        // The other machine's `DEBUG ACK`, at the instant this stimulus says.
        if let (Some(r), Some(d)) = (req_ns, answer_after)
            && ans_ns.is_none()
            && now >= r + d
        {
            ans_ns = Some(r + d);
            taken = bi.debug_out_answer(r + d);
        }
        if let Some(ack) = bi.poll(now, resp) {
            let grant = grant_ns.expect("a cycle is acknowledged only after it is granted");
            let msyn = grant + busint::UNIBUS_ADDRESS_NS;
            if let Some(r) = req_ns {
                assert_eq!(
                    r - msyn,
                    busint::DEBUG_OUT_REQUEST_NS,
                    "the request follows -UB MSYN by DEBUG_OUT_REQUEST_NS"
                );
            }
            assert_eq!(cable, req_ns.is_some(), "a cable and a request on it are the same thing");
            return DbgCycle {
                grant_ns: grant,
                msyn_ns: msyn,
                req_ns,
                ans_ns,
                ssyn_ns: ack.answered_at,
                memack_ns: ack.at,
                timed_out: ack.timed_out,
                taken,
            };
        }
    }
    panic!("a debug cycle that neither answered nor timed out in 200 us");
}

fn main() {
    // The masks are muir's, and both the module and its testbench take them
    // from this trace's header rather than transcribing MIT's note a second
    // time.
    assert_eq!(interrupt_status::CONTROL_MASK, 0o36001);
    assert_eq!(interrupt_status::CONTROL2_MASK, 0o101774);
    assert_eq!(interrupt_status::VECTOR_MASK, 0o1774);
    assert_eq!(interrupt_status::LOCAL_ENABLE, 0o2);
    assert_eq!(interrupt_status::XBUS_INTR, 0o40000);
    assert_eq!(interrupt_status::UB_INT, 0o100000);
    assert_eq!(error_status::NOT_FREE, 0o100);
    assert_eq!(error_status::WRITE_THROUGH, 0o200);
    assert_eq!(busint::DIAGNOSTIC_NS, 250);
    assert_eq!(busint::REGISTER_STROBE_NS, 150);
    assert_eq!(busint::UB_MD_ACK_NS, 100);

    // ------------------------------------------------------------------
    // The decode, over the whole of the Unibus address the interface can
    // put out.
    // ------------------------------------------------------------------
    let mut dec: Vec<String> = Vec::new();
    let mut iface_rows = 0u64;
    let mut none_runs = 0u64;
    let mut run_from: Option<u32> = None;
    let mut kinds = [0u64; 6];
    for u in 0..UB_ADDRESSES {
        match busint::register(u) {
            None => {
                run_from.get_or_insert(u);
            }
            Some(r) => {
                if let Some(first) = run_from.take() {
                    dec.push(format!("IFACENONE {first:x} {:x}", u - 1));
                    none_runs += 1;
                }
                let (k, n) = kind(r);
                kinds[k as usize] += 1;
                dec.push(format!("IFACE {u:x} {k} {n:x}"));
                iface_rows += 1;
            }
        }
    }
    if let Some(first) = run_from.take() {
        dec.push(format!("IFACENONE {first:x} {:x}", UB_ADDRESSES - 1));
        none_runs += 1;
    }

    // The four groups, said as counts of ADDRESSES, so that a decode which
    // lost one of them could not be written out quietly.  Two addresses an
    // register, because bit 0 is decoded nowhere in the block; the
    // interrupt block's four registers repeat every eight bytes, because
    // the 74S138 at 0E03 looks at address bits 2 and 1 alone.
    //
    // **Three addresses are odd ones out, and the reason is muir's ranges
    // rather than the drawings.**  `busint::register` matches
    // `0o766040..=0o766076` and `0o766140..=0o766176`, which stop at the
    // even address, so `0o766077` and `0o766177` are decoded by neither ---
    // where the diagnostic block's `BASE..BASE + 0o40` is a half-open range
    // and takes `0o766037`.  Nothing in either machine can tell: bit 0 of a
    // Unibus address is always zero, the master's `UAO<17:1>` dropping it,
    // so no cycle ever reaches one.  muir is the reference and the fabric
    // follows it here as everywhere; the counts below are what says so.
    assert_eq!(kinds[0], 32, "diagnostic registers");
    assert_eq!(kinds[1], 8, "interrupt control");
    assert_eq!(kinds[2], 8, "interrupt control 2");
    assert_eq!(kinds[3], 8, "error status");
    assert_eq!(kinds[4], 7, "the decoded and unwired one");
    assert_eq!(kinds[5], 31, "map registers");
    assert!(busint::register(0o766077).is_none() && busint::register(0o766177).is_none());
    assert!(busint::register(0o766037).is_some());
    // The debug block is answered over the cable and by nothing here, so it
    // has to fall inside a run of `IFACENONE`.  Asserted rather than
    // assumed: a decode that swallowed it would still write a trace.
    for u in 0o766100..=0o766137u32 {
        assert!(busint::register(u).is_none(), "{u:o} is the debug block's");
    }
    // Bit 0 of the address is not decoded anywhere in the block: the four
    // registers of the interrupt group are chosen by bits 2 and 1, the
    // diagnostic block's sixteen by bits 4 to 1, and the map's sixteen by
    // bits 4 to 1.  So an odd address is the even one below it.
    assert_eq!(busint::register(0o766041), busint::register(0o766040));
    assert_eq!(busint::register(0o766141), busint::register(0o766140));

    // ------------------------------------------------------------------
    // The mapped window, over the same eighteen bits: `busint::map_access`.
    // ------------------------------------------------------------------
    let mut win: Vec<String> = Vec::new();
    let mut win_rows = 0u64;
    let mut win_runs = 0u64;
    let mut run_from: Option<u32> = None;
    for u in 0..UB_ADDRESSES {
        match busint::map_access(u) {
            None => {
                run_from.get_or_insert(u);
            }
            Some(a) => {
                if let Some(first) = run_from.take() {
                    win.push(format!("MAPANONE {first:x} {:x}", u - 1));
                    win_runs += 1;
                }
                win.push(format!("MAPA {u:x} {:x} {:x} {}", a.page, a.word, u32::from(a.high)));
                win_rows += 1;
            }
        }
    }
    if let Some(first) = run_from.take() {
        win.push(format!("MAPANONE {first:x} {:x}", UB_ADDRESSES - 1));
        win_runs += 1;
    }
    // Sixteen pages of 256 words, each word two Unibus addresses.
    assert_eq!(win_rows, 16 * 256 * 2 * 2);

    // **THE WINDOW IS THE PROCESSOR'S NON-EXISTENT MEMORY, AND THAT IS THE
    // WHOLE OF WHY THE FABRIC NEEDS `ub_foreign`.**  `busint::decode` is what
    // a cycle of the machine's own goes through, and it answers
    // `Responder::NoUnibus` at every address of this window --- `register` is
    // `None` there, `debug_register` is `None` there and the I/O board
    // answers none of it.  The map responders are made in
    // `Rtl::try_debug_request` and nowhere else.  Asserted rather than
    // assumed, because the fabric gates a whole block of logic on it.
    for u in 0o140000..=0o177777u32 {
        assert!(busint::register(u).is_none(), "{u:o} is in the window AND a register");
        assert!(
            matches!(
                busint::decode(busint::unibus_physical(u), machine::MAIN_WORDS),
                busint::Responder::NoUnibus
            ),
            "{u:o} answers the processor's own cycle"
        );
    }
    // And nothing outside it is a mapped access: the two register groups
    // among the rest.
    assert!(busint::map_access(0o137776).is_none());
    assert!(busint::map_access(0o200000).is_none());
    assert!(busint::map_access(0o766140).is_none());

    let mut g = Gen::new();

    // ------------------------------------------------------------------
    // Power-on.  Every register of both groups read once, before anything
    // has been written: `LOCAL ENABLE` is a jumper and reads set, the map
    // comes up clear, and the error status register reads the pulled-up
    // high byte with `-FREE` alone below it.
    // ------------------------------------------------------------------
    g.lines_row();
    let ctl = g.read(0o766040);
    assert_eq!(
        ctl,
        interrupt_status::LOCAL_ENABLE as u32,
        "the interrupt status register at power-on is the jumper and nothing else"
    );
    assert_eq!(g.read(0o766042), 0, "766042 reads as nothing: it is a write strobe");
    assert_eq!(
        g.read(0o766044),
        0xff00 | error_status::NOT_FREE as u32,
        "the error status register at power-on"
    );
    assert_eq!(g.read(0o766046), 0, "766046 is decoded and wired to nothing");
    for k in 0..16u32 {
        assert_eq!(g.read(0o766140 + 2 * k), 0, "map register {k} at power-on");
    }

    // **Every `OP` row is an address the block answers, on purpose.**  A
    // cycle at one it does not is a cycle nothing answers, and in muir
    // that runs through `Machine::bus_read` and sets a bit of the error
    // status register --- so it is an `ERR` row, which says which bus it
    // was on, and never an `OP` row.  The refusals themselves are in the
    // `IFACE` and `IFACENONE` rows above, over the whole eighteen bits,
    // which is a stronger claim than any handful of cycles here.

    // ------------------------------------------------------------------
    // What a write of `766040` reaches: bits 0 and 10-13, mask 36001.
    // Written with every bit set, the read-back is that mask plus the
    // jumper, which is the whole claim in one row.
    // ------------------------------------------------------------------
    g.write(0o766040, 0xffff);
    let back = g.read(0o766040);
    assert_eq!(
        back,
        (interrupt_status::CONTROL_MASK | interrupt_status::LOCAL_ENABLE) as u32,
        "a write of all ones to 766040 reaches CONTROL_MASK and nothing else"
    );
    // Bit 14 is not stored even though the write covered it: it is
    // `XBUS INTR IN`, a wire, and a section below moves it.
    assert_eq!(back & interrupt_status::XBUS_INTR as u32, 0);
    g.write(0o766040, 0);
    assert_eq!(
        g.read(0o766040),
        interrupt_status::LOCAL_ENABLE as u32,
        "a write of zero left the jumper"
    );
    // Every bit of the mask alone, so that a stuck or crossed bit is one
    // row rather than an inference across a pattern.
    for b in 0..16u32 {
        let one = 1u16 << b;
        g.write(0o766040, one);
        let want = (one & interrupt_status::CONTROL_MASK) | interrupt_status::LOCAL_ENABLE;
        assert_eq!(g.m.interrupt_status, want, "bit {b} stored by a write of 766040");
        assert_eq!(g.read(0o766040), want as u32, "bit {b} read back from 766040");
    }
    g.write(0o766040, 0);

    // ------------------------------------------------------------------
    // What a write of `766042` reaches: bits 2-9 and 15, mask 101774 ---
    // the vector field and `UB INT`.  The microcode calls it
    // `CLEAR-INTERRUPT`, and `UB-INTR-RET-0` writes zero here to dismiss.
    // ------------------------------------------------------------------
    g.write(0o766042, 0xffff);
    assert_eq!(g.read(0o766042), 0, "766042 still reads as nothing after a write");
    let back = g.read(0o766040);
    assert_eq!(
        back,
        (interrupt_status::CONTROL2_MASK | interrupt_status::LOCAL_ENABLE) as u32,
        "a write of all ones to 766042 reaches CONTROL2_MASK"
    );
    // A `UB INT` written by hand is an interrupt taken, with the vector the
    // same write put there: the half of the register that needs no device.
    assert!(g.m.interrupt(), "a hand-written UB INT is an interrupt");
    assert_eq!(
        g.m.unibus_interrupt(),
        Some(interrupt_status::UB_INT | interrupt_status::VECTOR_MASK)
    );
    // Dismissed the way `UB-INTR-RET-0` dismisses it.
    g.write(0o766042, 0);
    assert!(!g.m.interrupt(), "a write of zero to 766042 dismissed it");
    //
    // **The vector field is stored and does not read back on its own.**
    // `Machine::interface_read` takes `VECTOR_MASK` out of what it shows of
    // the stored register and puts back the vector of the interrupt TAKEN,
    // which is the 74LS374 at UBINTC 0D17 being enabled by `UB INT`.  So a
    // walk of the sixteen bits is held to muir's own stored register, and
    // the read of `766040` beside it is recorded for the fabric to match
    // whatever it comes to.
    for b in 0..16u32 {
        let one = 1u16 << b;
        g.write(0o766042, one);
        assert_eq!(
            g.m.interrupt_status,
            (one & interrupt_status::CONTROL2_MASK) | interrupt_status::LOCAL_ENABLE,
            "bit {b} written to 766042"
        );
        g.read(0o766040);
    }
    g.write(0o766042, 0);

    // ------------------------------------------------------------------
    // `XBUS INTR IN`, bit 14: a wire and not a bit of the register.  The
    // display's vertical flag is the only thing in this process that can
    // raise it, the disk having no drive.
    // ------------------------------------------------------------------
    g.m.bus_write(TV_MODE, mode::VERT | mode::INTERRUPT_ENABLE);
    g.lines_row();
    assert!(g.m.xbus_interrupt(), "the display's vertical interrupt");
    assert!(g.m.interrupt(), "LM INT is UB INT OR XBUS INTR IN");
    let ctl = g.read(0o766040);
    assert_eq!(
        ctl & interrupt_status::XBUS_INTR as u32,
        interrupt_status::XBUS_INTR as u32
    );
    // A write of the register does not disturb a wire.
    g.write(0o766040, 0xffff);
    let ctl = g.read(0o766040);
    assert_eq!(
        ctl & interrupt_status::XBUS_INTR as u32,
        interrupt_status::XBUS_INTR as u32
    );
    g.write(0o766040, 0);
    g.m.bus_write(TV_MODE, 0);
    g.lines_row();
    assert!(!g.m.xbus_interrupt());
    assert_eq!(g.read(0o766040) & interrupt_status::XBUS_INTR as u32, 0);

    // ------------------------------------------------------------------
    // `ENABLE UB INTS`, bit 10, and the card's own request.  The microcode
    // writes `6000` here at the end of the cold boot and again at the end
    // of every interrupt, "Enable one more Unibus interrupt".
    // ------------------------------------------------------------------
    g.card_write(CSR, csr::KBD_INT_ENABLE);
    g.m.ioboard.press(0x9C_36E1);
    g.lines_row();
    assert!(g.m.ioboard.keyboard_ready());
    assert_eq!(g.m.ioboard.interrupt_request(g.m.ns), Some(ioboard::KBD_VECTOR));
    // With the enable clear the interface does not take it: the request is
    // on the bus, and this bit is the grant.
    assert!(!g.m.interrupt(), "a request with ENABLE UB INTS clear is not taken");
    let ctl = g.read(0o766040);
    assert_eq!(ctl & interrupt_status::UB_INT as u32, 0);
    assert_eq!(ctl & interrupt_status::VECTOR_MASK as u32, 0);
    // And with it set, it is: `UB INT` and the device's vector in place.
    g.write(0o766040, 0o6000);
    let ctl = g.read(0o766040);
    assert_eq!(
        ctl & interrupt_status::UB_INT as u32,
        interrupt_status::UB_INT as u32
    );
    assert_eq!(
        ctl & interrupt_status::VECTOR_MASK as u32,
        ioboard::KBD_VECTOR as u32
    );
    assert!(g.m.interrupt());
    // The one thing that clears `KBD READY` is the microcode reading the
    // low half of the keyboard's word, and the request goes with it.  MIT's
    // own order: the high half first.
    g.card_read(0o764102);
    assert!(g.m.ioboard.keyboard_ready(), "the high half does not clear it");
    g.card_read(0o764100);
    assert!(!g.m.ioboard.keyboard_ready());
    let ctl = g.read(0o766040);
    assert_eq!(ctl & interrupt_status::UB_INT as u32, 0, "the request went and UB INT with it");
    assert_eq!(ctl & interrupt_status::VECTOR_MASK as u32, 0);
    assert!(!g.m.interrupt());

    // The clock's vector, which is a different one: an interval that has
    // run out with `CLOCK INT ENABLE` set.
    g.card_write(CSR, 0);
    g.card_write(0o764124, 1);
    g.card_write(CSR, csr::CLOCK_INT_ENABLE);
    g.wait(3 * 16_000);
    assert_eq!(g.m.ioboard.interrupt_request(g.m.ns), Some(ioboard::CLOCK_VECTOR));
    let ctl = g.read(0o766040);
    assert_eq!(
        ctl & interrupt_status::VECTOR_MASK as u32,
        ioboard::CLOCK_VECTOR as u32
    );
    assert!(g.m.interrupt());
    // A hand-written `UB INT` wins over a live one: the stored bit is taken
    // first and reads its own vector field back, which is what a microcode
    // simulating an interrupt depends on.
    g.write(0o766042, interrupt_status::UB_INT | 0o0300);
    let ctl = g.read(0o766040);
    assert_eq!(ctl & interrupt_status::VECTOR_MASK as u32, 0o300);
    g.write(0o766042, 0);
    let ctl = g.read(0o766040);
    assert_eq!(
        ctl & interrupt_status::VECTOR_MASK as u32,
        ioboard::CLOCK_VECTOR as u32,
        "the live request is back once the hand-written one is dismissed"
    );
    // Put the card and the register back to rest.
    g.card_write(CSR, 0);
    g.write(0o766040, 0);
    assert!(!g.m.interrupt());

    // ------------------------------------------------------------------
    // The error status register, and `-RESET ERR`.
    // ------------------------------------------------------------------
    //
    // An Xbus cycle nothing answers, and a Unibus one.  `0o17300000` is
    // Xbus I/O space between the display's frame buffer and its registers;
    // `0o764200` is a Unibus address no slave decodes.
    assert_eq!(
        g.read(0o766044),
        0xff00 | 0o100,
        "nothing above this point has run a cycle that timed out"
    );
    g.nxm(0o17300000, false);
    let err = g.read(0o766044);
    assert_eq!(err & 0o377, 0o1 | 0o100, "XBUS NXM and -FREE");
    g.nxm(busint::unibus_physical(0o764200), true);
    let err = g.read(0o766044);
    assert_eq!(err & 0o377, 0o1 | 0o10 | 0o100, "both NXM bits stand until reset");
    // "Writing this location ignores the data written and clears the status
    // bits" --- all but the one the drawings clock from it.
    g.write(0o766044, 0);
    assert_eq!(g.read(0o766044), 0xff00 | 0o100, "-RESET ERR cleared them");
    // `WRITE THROUGH ENB` is bit 7, the 74S74 at UBCYC 0B08, clocked from
    // data bit 7 by that same write.  MIT: write-through mode "is turned on
    // by bit 7 (200) in the bus interface's Error Status register".
    g.write(0o766044, error_status::WRITE_THROUGH);
    assert_eq!(
        g.read(0o766044),
        0xff00 | 0o100 | 0o200,
        "WRITE THROUGH ENB is set and stands"
    );
    // It survives a set of the error bits and goes when a write says so.
    g.nxm(0o17300000, false);
    assert_eq!(g.read(0o766044), 0xff00 | 0o1 | 0o100 | 0o200);
    g.write(0o766044, 0);
    assert_eq!(
        g.read(0o766044),
        0xff00 | 0o100,
        "a write of zero clears the flop as well as the errors"
    );
    // And a write of anything but bit 7 leaves the flop clear while still
    // clearing the errors, so that the two halves of the write are told
    // apart rather than moving together.
    g.nxm(0o17300000, false);
    g.write(0o766044, 0xff7f);
    assert_eq!(g.read(0o766044), 0xff00 | 0o100, "every bit but 7 written");

    // ------------------------------------------------------------------
    // The aliasing.  Within the interrupt block the 74S138 at 0E03 looks
    // at address bits 2 and 1 alone, so the four repeat every eight bytes
    // through `0o766076`: `0o766050` is `0o766040` and `0o766064` is
    // `0o766044`.  The block is thirty-two bytes, so there are four copies
    // and every one of them is driven and read.
    // ------------------------------------------------------------------
    for copy in 0..4u32 {
        let base = 0o766040 + 8 * copy;
        g.write(base, 0o36001);
        assert_eq!(
            g.read(0o766040),
            (interrupt_status::CONTROL_MASK | interrupt_status::LOCAL_ENABLE) as u32,
            "the copy of the interrupt control register at {base:o}"
        );
        g.write(0o766040, 0);
        // The copy of `CLEAR-INTERRUPT`, two bytes up.
        g.write(base + 2, interrupt_status::UB_INT);
        assert!(g.m.interrupt(), "the copy of 766042 at {:o}", base + 2);
        g.write(0o766042, 0);
        // The copy of `-RESET ERR`, four bytes up.
        g.nxm(0o17300000, false);
        g.write(base + 4, 0);
        assert_eq!(
            g.read(0o766044),
            0xff00 | 0o100,
            "the copy of -RESET ERR at {:o}",
            base + 4
        );
        // And the read-back of each copy, so that a decode answering the
        // right word at the wrong address is seen.
        assert_eq!(g.read(base), interrupt_status::LOCAL_ENABLE as u32);
        assert_eq!(g.read(base + 2), 0);
        assert_eq!(g.read(base + 4), 0xff00 | 0o100);
        assert_eq!(g.read(base + 6), 0);
    }

    // ------------------------------------------------------------------
    // The Unibus map: sixteen 29701s at UBMAP 0E12-0E15, read back through
    // the 74LS244s at 0E16 and 0E17.  Nothing in this fabric walks them ---
    // the one master that does is the debug cable's --- so what the trace
    // holds is that all sixteen bits of all sixteen store and read back,
    // and that they are sixteen separate registers.
    //
    // The word is a poison injective in the register number, with a high
    // bit and a low bit both moving, so that an address off by one and a
    // word off by one do not look alike.
    // ------------------------------------------------------------------
    let poison = |k: u32| -> u16 { (0xC300u32 ^ (k * 0x1111) ^ (k << 12)) as u16 };
    for k in 0..16u32 {
        g.write(0o766140 + 2 * k, poison(k));
    }
    for k in 0..16u32 {
        assert_eq!(
            g.read(0o766140 + 2 * k),
            poison(k) as u32,
            "map register {k} read back"
        );
        // muir's own field, so that the trace and the model agree about
        // which register the address named.
        assert_eq!(g.m.unibus_map[k as usize], poison(k));
    }
    // Every bit of one register, walked, so that a stuck bit is caught at
    // one address rather than inferred across sixteen.
    for b in 0..16u32 {
        g.write(0o766140, 1u16 << b);
        assert_eq!(g.read(0o766140), 1u32 << b, "map register 0, bit {b}");
    }
    g.write(0o766140, poison(0));
    // The map and the interrupt block are not one another: a write into the
    // map leaves the interrupt status register where it was.
    let ctl = g.read(0o766040);
    assert_eq!(ctl, interrupt_status::LOCAL_ENABLE as u32);

    // ------------------------------------------------------------------
    // THE MAPPED WINDOW, `0o140000`-`0o177777`.  `Machine::mapped_read` and
    // `Machine::mapped_write`, which are the whole of what a Unibus master
    // that is not this board reaches through the sixteen registers above.
    // ------------------------------------------------------------------
    //
    // Main memory first, poisoned injectively in the physical address so
    // that a translation one page or one word out takes a word muir never
    // had.  Straight into `main`, so no bus cycle and no row goes with it.
    g.poison_page(PAGE_RW);
    g.poison_page(PAGE_RO);
    g.poison_page(PAGE_WT);

    // `-RESET ERR`, so that `UB MAP ERROR` starts from nothing and the rows
    // below say where it sets rather than inheriting it from the sweep above.
    g.write(0o766044, 0);
    assert_eq!(g.read(0o766044), 0xff00 | 0o100, "the error register before any mapped cycle");

    // The map, programmed the way the sections below read it.  `MAP_BAD`
    // carries `WRITEOK` with `MAPVALID` DOWN, so that its refusals cannot be
    // read as bit 14's doing; `MAP_RO` is the other way round.
    g.write(0o766140 + 2 * MAP_RW, (0x8000 | 0x4000 | PAGE_RW) as u16);
    g.write(0o766140 + 2 * MAP_RO, (0x8000 | PAGE_RO) as u16);
    g.write(0o766140 + 2 * MAP_BAD, (0x4000 | PAGE_RW) as u16);
    // The same, on an UPPER page, so that write-through has an invalid entry
    // to be refused by: the one case where the even word of a write refuses.
    g.write(0o766140 + 2 * MAP_BADHI, (0x4000 | PAGE_RO) as u16);
    g.write(0o766140 + 2 * MAP_WT, (0x8000 | 0x4000 | PAGE_WT) as u16);
    // CC's own: "CC-WRITE-MD loads map register 16 with 177000".
    g.write(0o766140 + 2 * MAP_MD, 0o177000);
    assert!(g.m.map_entry(MAP_BAD as u8).is_none(), "MAPVALID is bit 15 and it is down");
    assert_eq!(g.m.map_entry(MAP_RO as u8), Some((PAGE_RO, false)), "WRITEOK is bit 14");
    let (md_page, md_write) = g.m.map_entry(MAP_MD as u8).expect("CC's entry is valid");
    assert!(md_write && busint::map_to_md(md_page), "CC's entry is MD's");

    // ---- a read: the even word is the Xbus and the odd word the buffer ----
    //
    // "Each Lisp machine memory word is accessed as two unibus words; the low
    // half has the lower unibus address."  So the pair rebuilds the word.
    let lo = g.mapped(uw(MAP_RW, 0, false), false, 0);
    let hi = g.mapped(uw(MAP_RW, 0, true), false, 0);
    assert_eq!((hi << 16) | lo, mpoison(PAGE_RW << 8), "the first word of the mapped page");
    // The last word of the page, so that `UBA<9:2>` reaches the address and a
    // word dropped from the translation is one row rather than an inference.
    let lo = g.mapped(uw(MAP_RW, 0o377, false), false, 0);
    let hi = g.mapped(uw(MAP_RW, 0o377, true), false, 0);
    assert_eq!((hi << 16) | lo, mpoison((PAGE_RW << 8) | 0o377), "the last word");
    // A word in the middle of a DIFFERENT page, so that `UBA<13:10>` is
    // reached too and the two pages are told apart.
    let lo = g.mapped(uw(MAP_RO, 0o125, false), false, 0);
    assert_eq!(lo, mpoison((PAGE_RO << 8) | 0o125) & 0xffff, "a read-only page still READS");

    // ---- an invalid page: `UB MAP ERROR`, and no answer at all ----
    let e = g.read(0o766044);
    assert_eq!(e & machine::bus_error::UB_MAP_ERROR as u32, 0, "no map error yet");
    g.mapped(uw(MAP_BAD, 0o5, false), false, 0);
    let e = g.read(0o766044);
    assert_eq!(
        e & machine::bus_error::UB_MAP_ERROR as u32,
        machine::bus_error::UB_MAP_ERROR as u32,
        "a read through an invalid page set UB MAP ERROR"
    );
    // And the ODD word of the same page STILL ANSWERS, from the buffer, with
    // no look at the map at all: `Machine::mapped_read` returns the buffer
    // before it reads the entry.  muir's own asymmetry, and a fabric that
    // checked validity first would fail here.
    g.mapped(uw(MAP_BAD, 0o5, true), false, 0);
    g.write(0o766044, 0);
    assert_eq!(g.read(0o766044) & 0o77, 0, "-RESET ERR clears UB MAP ERROR with the rest");

    // ---- a write: the even word is the buffer and the odd word the Xbus ----
    let wlo = 0x1234u16;
    let whi = 0xABCDu16;
    g.mapped(uw(MAP_RW, 0o100, false), true, wlo);
    g.mapped(uw(MAP_RW, 0o100, true), true, whi);
    assert_eq!(
        g.m.main[((PAGE_RW << 8) | 0o100) as usize],
        ((whi as u32) << 16) | wlo as u32,
        "the two Unibus words made one Lisp machine word"
    );
    // Read back through the map, which is the property the whole window is
    // for: a Unibus master put a word in main memory and took it out again.
    let lo = g.mapped(uw(MAP_RW, 0o100, false), false, 0);
    let hi = g.mapped(uw(MAP_RW, 0o100, true), false, 0);
    assert_eq!((hi << 16) | lo, ((whi as u32) << 16) | wlo as u32);

    // ---- a write-protected page, and an invalid one ----
    let kept = g.m.main[((PAGE_RO << 8) | 0o7) as usize];
    g.mapped(uw(MAP_RO, 0o7, false), true, 0x5555);
    g.mapped(uw(MAP_RO, 0o7, true), true, 0xAAAA);
    assert_eq!(g.m.main[((PAGE_RO << 8) | 0o7) as usize], kept, "a protected page was written");
    assert_eq!(
        g.read(0o766044) & machine::bus_error::UB_MAP_ERROR as u32,
        machine::bus_error::UB_MAP_ERROR as u32
    );
    g.write(0o766044, 0);
    g.mapped(uw(MAP_BAD, 0o3, false), true, 0x0F0F);
    g.mapped(uw(MAP_BAD, 0o3, true), true, 0xF0F0);
    assert_eq!(
        g.read(0o766044) & machine::bus_error::UB_MAP_ERROR as u32,
        machine::bus_error::UB_MAP_ERROR as u32
    );
    g.write(0o766044, 0);

    // ---- write-through, bit 7 of the error status register ----
    //
    // "On the upper eight pages the even word's write is an Xbus write as
    // well, of the Unibus word with zeros above it" --- measured on the
    // netlist board, muir's `tests/chip.rs`.
    g.write(0o766044, error_status::WRITE_THROUGH);
    assert!(g.m.write_through);
    g.mapped(uw(MAP_WT, 0o21, false), true, 0x3C3C);
    assert_eq!(
        g.m.main[((PAGE_WT << 8) | 0o21) as usize],
        0x0000_3C3C,
        "write-through put the Unibus word on BUS<15:0> and ground above it"
    );
    // Read back through the map, which is where the ground above shows: a
    // write-through that carried the write buffer instead would put the last
    // word written there in the high half and this would see it.  A READ is
    // not a write-through cycle, so the bit being still set changes nothing.
    let lo = g.mapped(uw(MAP_WT, 0o21, false), false, 0);
    let hi = g.mapped(uw(MAP_WT, 0o21, true), false, 0);
    assert_eq!((hi << 16) | lo, 0x0000_3C3C, "write-through's zeros above the word");
    // And it is the UPPER eight pages alone: the same write on a low page is
    // the buffer and nothing else, which is what tells the exception from a
    // write-through that reached everywhere.
    let kept = g.m.main[((PAGE_RW << 8) | 0o22) as usize];
    g.mapped(uw(MAP_RW, 0o22, false), true, 0x2D2D);
    assert_eq!(g.m.main[((PAGE_RW << 8) | 0o22) as usize], kept, "a low page went through");
    // **AND THE EVEN WORD CAN NOW BE REFUSED, which it can at no other time.**
    // Write-through sends it to the map, so an invalid upper page turns a
    // buffer write into `UB MAP ERROR` --- and the buffer still takes the
    // word, because `Machine::mapped_write` writes it before it looks.
    g.write(0o766044, error_status::WRITE_THROUGH);
    g.mapped(uw(MAP_BADHI, 0o17, false), true, 0x9999);
    assert_eq!(g.m.write_buffer[MAP_BADHI as usize], 0x9999, "the buffer took it anyway");
    assert_eq!(
        g.read(0o766044) & machine::bus_error::UB_MAP_ERROR as u32,
        machine::bus_error::UB_MAP_ERROR as u32,
        "write-through's even word was refused"
    );
    // And a read of the same entry is refused too, for the ordinary reason.
    g.mapped(uw(MAP_BADHI, 0o17, false), false, 0);
    g.write(0o766044, 0);
    assert!(!g.m.write_through);
    // With the bit off the upper page is the buffer too.
    let kept = g.m.main[((PAGE_WT << 8) | 0o23) as usize];
    g.mapped(uw(MAP_WT, 0o23, false), true, 0x4E4E);
    assert_eq!(g.m.main[((PAGE_WT << 8) | 0o23) as usize], kept, "write-through was off");
    // The odd word then carries that buffer to the Xbus, as it always does.
    g.mapped(uw(MAP_WT, 0o23, true), true, 0x7B7B);
    assert_eq!(g.m.main[((PAGE_WT << 8) | 0o23) as usize], 0x7B7B_4E4E);
    let lo = g.mapped(uw(MAP_WT, 0o23, false), false, 0);
    let hi = g.mapped(uw(MAP_WT, 0o23, true), false, 0);
    assert_eq!((hi << 16) | lo, 0x7B7B_4E4E, "the pair the two writes made");

    // ---- `-UB TO MD`, decoded and never answered ----
    let md0 = g.m.md;
    g.mapped(uw(MAP_MD, 0o11, false), true, 0x6789);
    g.mapped(uw(MAP_MD, 0o11, true), true, 0xFEDC);
    assert_eq!(g.m.md, 0xFEDC_6789, "CC-WRITE-MD put the word in MD");
    assert_ne!(g.m.md, md0);
    assert_eq!(g.m.bus_error & machine::bus_error::UB_MAP_ERROR, 0, "MD is not a refusal");

    // ------------------------------------------------------------------
    // The sixteen entries the exhaustive sweep of the window runs against:
    // all valid, all writable, all pointing at DISTINCT main-memory pages, so
    // that the physical address a cycle puts out names the register it came
    // through.  `Machine::map_entry` reads the page out of each, so the
    // testbench compares against muir's own translation and not its own sum.
    // ------------------------------------------------------------------
    let mut sweep: Vec<String> = Vec::new();
    let mut pages: Vec<u32> = Vec::new();
    for k in 0..16u32 {
        let e = (0x8000 | 0x4000 | (0o0400 + k * 0o0101)) as u16;
        g.write(0o766140 + 2 * k, e);
        let (p, w) = g.m.map_entry(k as u8).expect("the sweep's entries are valid");
        assert!(w, "the sweep's entries are writable");
        assert!(!busint::map_to_md(p), "the sweep's pages are the Xbus, not MD");
        assert!(!pages.contains(&p), "the sweep's pages are distinct");
        assert!(((p as usize) + 1) << 8 <= g.m.main.len(), "the sweep's pages are main memory");
        pages.push(p);
        sweep.push(format!("MAPSWEEP {k:x} {e:x} {p:x}"));
    }

    // ------------------------------------------------------------------
    // `-UB TO MD`, BUILT: CC's `CC-WRITE-MD`.
    // ------------------------------------------------------------------
    //
    // **APPENDED AFTER THE SWEEP ON PURPOSE.**  Every row above keeps the
    // number it had, so the trace grew without renumbering anything ---
    // which is what makes "the old rows did not move" a `cmp` rather than an
    // argument.  The cost is that the sweep has just put a main-memory page
    // in all sixteen entries, so CC's own is programmed again here; the
    // testbench writes the sweep's entries back itself before it sweeps the
    // window, so nothing downstream depends on what this leaves behind.
    //
    // "if high 5 bits of page=1, writes MD register" --- `unaddr.text`, and
    // `busint::map_to_md` is that sentence.  The path is `UB MD LOAD`,
    // `NOR(-UB TO MD, -UBX GRANT)` at REQLM 0B17, a term of `-LOADMD` at
    // 0C10 and of `-LOADMD ACK` at 0A11 --- so the cycle IS acknowledged,
    // `busint::UB_MD_ACK_NS` after the edge that loads `MD`, and the trace
    // said it never was because the fabric had not built it.
    g.write(0o766140 + 2 * MAP_MD, 0o177000);
    let (md_page, md_write) = g.m.map_entry(MAP_MD as u8).expect("CC's entry is valid");
    assert!(md_write && busint::map_to_md(md_page), "CC's entry is MD's");

    // Five words, the halves differing in every byte in most of them, and
    // both all-zeros and all-ones reached in each half: a fabric that sent
    // the Unibus word to the wrong half, or swapped the two, cannot agree
    // with all five.  Each pair is at a DIFFERENT word of the page, which is
    // `UBA<9:2>` reaching the cycle and being ignored --- `MD` has no
    // address.
    let pairs: [(u16, u16); 5] = [
        (0x1234, 0xABCD),
        (0xAAAA, 0x5555),
        (0x00FF, 0xFF00),
        (0xFFFF, 0xFFFF),
        (0x0000, 0x0000),
    ];
    let mut md_before = g.m.md;
    for (i, &(lo, hi)) in pairs.iter().enumerate() {
        let w = 0o11 + i as u32;
        // The EVEN word of a write is the page's write buffer and nothing
        // else, with write-through off: no `MD`, no Xbus, no error.
        g.mapped(uw(MAP_MD, w, false), true, lo);
        assert_eq!(g.m.md, md_before, "the even word of the pair moved MD");
        // And the ODD word is the load, carrying that buffer under it.
        let md32 = g.mapped_md(uw(MAP_MD, w, true), hi);
        assert_eq!(md32, ((hi as u32) << 16) | lo as u32, "the halves, in muir's order");
        assert_eq!(g.m.md, md32);
        md_before = md32;
    }
    assert_eq!(g.m.md, 0, "the last pair wrote zero, which a held word would hide");

    // **AND WRITE-THROUGH SENDS THE EVEN WORD TO `MD` TOO**, on the upper
    // eight pages, with ground above it: `Machine::mapped_write` puts the
    // word in the buffer, does not return, and reaches `map_to_md` with
    // `word = v as u32`.  `MAP_MD` is `0o16` and so is one of those pages.
    g.write(0o766044, error_status::WRITE_THROUGH);
    assert!(g.m.write_through);
    let md32 = g.mapped_md(uw(MAP_MD, 0o25, false), 0x7E81);
    assert_eq!(md32, 0x0000_7E81, "write-through's even word put ground above the word");
    assert_eq!(g.m.write_buffer[MAP_MD as usize], 0x7E81, "and the buffer took it as well");
    // The odd word after it then carries that same buffer under its own half,
    // which is the one place the two rules meet.
    let md32 = g.mapped_md(uw(MAP_MD, 0o25, true), 0x39C6);
    assert_eq!(md32, 0x39C6_7E81);
    g.write(0o766044, 0);
    assert!(!g.m.write_through);

    // ---- and what a READ of the same window gives, which is NOT MD ----
    //
    // `Rtl::try_debug_request` tests `req.write` before `map_to_md`, so a
    // read through CC's entry is the ordinary pair: the ODD word is the
    // page's read buffer and the EVEN word a mapped Xbus cycle at physical
    // page `0o37000`, which is the Unibus and not main memory ---
    // `Busint::debug_xbus_edge` does not model one and no row here asks for
    // it.  So the buffer is filled through a real page first and read back
    // through CC's, which is the sharp form of the claim: the odd word
    // answers with the READ BUFFER and has nothing to do with `MD`'s high
    // half.
    let kept = g.m.md;
    g.write(0o766140 + 2 * MAP_MD, (0x8000 | 0x4000 | PAGE_RW) as u16);
    let lo = g.mapped(uw(MAP_MD, 0o7, false), false, 0);
    assert_eq!(lo, mpoison((PAGE_RW << 8) | 0o7) & 0xffff, "the low half off the Xbus");
    g.write(0o766140 + 2 * MAP_MD, 0o177000);
    let hi = g.mapped(uw(MAP_MD, 0o7, true), false, 0);
    assert_eq!(hi, mpoison((PAGE_RW << 8) | 0o7) >> 16, "the high half out of the read buffer");
    assert_ne!(hi, kept >> 16, "the buffer's word is not MD's high half");
    assert_eq!(g.m.md, kept, "a read through CC's entry moved MD");
    assert_eq!(
        g.read(0o766044) & machine::bus_error::UB_MAP_ERROR as u32,
        0,
        "nothing here was refused"
    );

    // ------------------------------------------------------------------
    // What the program reached.
    // ------------------------------------------------------------------
    let mut reached = g.reached.clone();
    reached.sort();
    reached.dedup();
    for k in 1..6u32 {
        assert!(
            reached.iter().any(|&(kk, _)| kk == k),
            "no cycle reached a register of kind {k}"
        );
    }
    for n in 0..16u32 {
        assert!(reached.contains(&(5, n)), "map register {n} was never addressed");
    }
    assert!(g.xint_seen[0] && g.xint_seen[1], "XBUS INTR IN was never seen both ways");
    assert!(g.ubint_seen[0] && g.ubint_seen[1], "UB INT was never seen both ways");
    assert_eq!(
        g.err_bits & !(error_status::NOT_FREE | error_status::WRITE_THROUGH),
        machine::bus_error::XBUS_NXM
            | machine::bus_error::UNIBUS_NXM
            | machine::bus_error::UB_MAP_ERROR,
        "all three error bits were reached and no fourth was"
    );
    assert!(g.ops >= 200, "only {} register cycles", g.ops);
    assert!(g.errs >= 8, "only {} timeouts", g.errs);
    assert!(g.lines_rows >= 8, "only {} wire rows", g.lines_rows);
    assert!(g.maps >= 20, "only {} mapped cycles", g.maps);
    for r in 0..4usize {
        assert!(g.resp_seen[r] > 0, "no mapped cycle reached responder {r}");
    }
    // Every one of the four both ways where muir has both ways: the buffer
    // and the Xbus are read and written, and a refusal comes of a read and of
    // a write.  `MapMd` is a write alone, a read never reaching it.
    assert!(g.resp_seen[RESP_BUFFER as usize] >= 8, "the buffers were barely touched");
    assert!(g.resp_seen[RESP_XBUS as usize] >= 8, "the Xbus half was barely touched");
    assert!(g.resp_seen[RESP_REFUSED as usize] >= 4, "the refusals were barely touched");
    assert!(g.md_writes >= 7, "only {} writes of MD", g.md_writes);

    println!("# the bus interface's own Unibus registers, from muir's busint::register");
    println!("# and Machine::interface_read / interface_write");
    println!("# generated by golden/src/busint_regs.rs");
    println!("#");
    println!("# IFACENONE  first last");
    println!("#     busint::register answers nothing in [first,last], read or written");
    println!("# IFACE      uaddr kind reg");
    println!("#     busint::register(uaddr): kind 0 diagnostic, 1 interrupt control,");
    println!("#     2 interrupt control 2, 3 error status, 4 decoded and unwired,");
    println!("#     5 Unibus map; reg is the number within the kind");
    println!("# OP         n write uaddr wdata xint ireq ivec rdata <face>");
    println!("#     one register cycle.  rdata {NONE:x} is a write, which gives no word.");
    println!("# LINES      n xint ireq ivec <face>");
    println!("#     the three wires the registers read and do not hold moved: XBUS INTR");
    println!("#     IN, and the card's own request with its vector.  They move on no");
    println!("#     other row, which is what lets a cycle hold them for its whole self.");
    println!("# ERR        n which <face>");
    println!("#     a bus cycle of the interface's own that nothing answered: which 0 an");
    println!("#     Xbus cycle, 1 a Unibus one.  This is what sets the error status");
    println!("#     register's two NXM bits.");
    println!("# MAPA       uaddr page word high");
    println!("#     busint::map_access(uaddr): the mapped window.  page is UBA<13:10>,");
    println!("#     which of the sixteen map registers; word is UBA<9:2>, the word within");
    println!("#     the mapped page; high is UBA1, the high half of the Lisp machine word.");
    println!("# MAPANONE   first last");
    println!("#     map_access answers nothing in [first,last]: not a mapped access.");
    println!("# MAPSWEEP   k entry physpage");
    println!("#     map register k holds entry, and Machine::map_entry reads physpage out");
    println!("#     of it.  The sixteen the exhaustive sweep of the window runs against.");
    println!("# MAP        n write uaddr wdata xint ireq ivec resp phys xword rdata <face>");
    println!("#     one mapped cycle: Machine::mapped_read or Machine::mapped_write.  resp");
    println!("#     is Rtl::try_debug_request's answer --- {RESP_BUFFER} the buffer,");
    println!("#     {RESP_XBUS} the Xbus, {RESP_REFUSED} refused, {RESP_MD} a write of MD");
    println!("#     --- a refusal is NEVER acknowledged and a write of MD is acknowledged");
    println!("#     ub_md_ack_ns after the edge that loads MD.  phys is the physical word");
    println!("#     address and xword the thirty-two bits that crossed the Xbus, both");
    println!("#     {NONE:x} where no Xbus cycle happened; rdata {NONE:x} is a write or a");
    println!("#     cycle nothing answered.");
    println!("# MAPMD      n write uaddr wdata xint ireq ivec md32 md <face>");
    println!("#     one mapped write that busint::map_to_md sends to the processor's MD");
    println!("#     rather than to the Xbus: CC's CC-WRITE-MD.  write is always 1, a read");
    println!("#     never reaching this responder.  md32 is the thirty-two bits");
    println!("#     Machine::mapped_write put in MD --- the Unibus word in the high half");
    println!("#     and the page's write buffer under it, or the word with ground above it");
    println!("#     for write-through's even word --- and md is MD itself afterwards.");
    println!("#     The cycle is acknowledged ub_md_ack_ns after the edge that loads MD.");
    println!("#");
    println!("# <face> = ctl err ubint int");
    println!("#     ctl    a read of 766040: the interrupt status register");
    println!("#     err    a read of 766044: the error status register");
    println!("#     ubint  the Unibus interrupt taken, UB INT and the vector, or {NONE:x}");
    println!("#     int    LM INT, which is UB INT OR XBUS INTR IN and reaches SINTR");
    println!("#");
    println!("# n is decimal; every other value hexadecimal except uaddr, which is octal");
    println!("#");
    println!("# ub_address_bits 18");
    println!("# diagnostic_ns {}", busint::DIAGNOSTIC_NS);
    println!("# register_strobe_ns {}", busint::REGISTER_STROBE_NS);
    println!("# control_mask {:o}", interrupt_status::CONTROL_MASK);
    println!("# control2_mask {:o}", interrupt_status::CONTROL2_MASK);
    println!("# vector_mask {:o}", interrupt_status::VECTOR_MASK);
    println!("# local_enable {:o}", interrupt_status::LOCAL_ENABLE);
    println!("# xbus_intr {:o}", interrupt_status::XBUS_INTR);
    println!("# ub_int {:o}", interrupt_status::UB_INT);
    println!("# not_free {:o}", error_status::NOT_FREE);
    println!("# write_through {:o}", error_status::WRITE_THROUGH);
    println!("# xbus_nxm {:o}", machine::bus_error::XBUS_NXM);
    println!("# unibus_nxm {:o}", machine::bus_error::UNIBUS_NXM);
    println!("# ub_map_error {:o}", machine::bus_error::UB_MAP_ERROR);
    println!("# ub_xbus_request_ns {}", busint::UB_XBUS_REQUEST_NS);
    println!("# ub_xbus_read_ack_ns {}", busint::UB_XBUS_READ_ACK_NS);
    println!("# ub_md_ack_ns {}", busint::UB_MD_ACK_NS);
    println!("# iface_rows {iface_rows}");
    println!("# none_runs {none_runs}");
    println!("# win_rows {win_rows}");
    println!("# win_runs {win_runs}");
    println!("# ops {}", g.ops);
    println!("# errs {}", g.errs);
    println!("# lines_rows {}", g.lines_rows);
    println!("# maps {}", g.maps);
    println!("# md_writes {}", g.md_writes);
    println!("# rows {}", g.line);
    for d in &dec {
        println!("{d}");
    }
    for d in &win {
        println!("{d}");
    }
    for d in &sweep {
        println!("{d}");
    }
    for r in &g.out {
        println!("{r}");
    }

    // ------------------------------------------------------------------
    // THE DEBUG BLOCK, APPENDED.
    //
    // Everything from here down was added after the trace above existed and
    // is written AT THE END for that reason: every byte above it is what it
    // was, which `cmp` says in one command and an argument does not.
    // ------------------------------------------------------------------
    assert_eq!(busint::DEBUG_OUT_REQUEST_NS, 100);
    assert_eq!(busint::DEBUG_TIMEOUT_NS, 11_050);
    assert_eq!(busint::UNIBUS_ADDRESS_NS, 100);
    // The debug block is 32 addresses and four strobes, and they repeat: bits
    // 4 and 1 are not decoded.
    let mut dbg_regs: Vec<String> = Vec::new();
    for u in DBG_LOW..=DBG_HIGH {
        let k = busint::debug_register(u).expect("inside the debug block");
        dbg_regs.push(format!("DBGREG {u:o} {k}"));
    }
    assert!(busint::debug_register(DBG_LOW - 1).is_none());
    assert!(busint::debug_register(DBG_HIGH + 1).is_none());
    assert_eq!(busint::debug_register(0o766100), Some(busint::DEBUG_CYCLE));
    assert_eq!(busint::debug_register(0o766104), Some(busint::DEBUG_STATUS));
    assert_eq!(busint::debug_register(0o766110), Some(busint::DEBUG_MODIFIER));
    assert_eq!(busint::debug_register(0o766114), Some(busint::DEBUG_ADDRESS));
    // And the four repeat, which is bits 4 and 1 going nowhere.
    assert_eq!(busint::debug_register(0o766102), busint::debug_register(0o766100));
    assert_eq!(busint::debug_register(0o766120), busint::debug_register(0o766100));

    // **THE TIMEOUT DEPENDS ON THE OSCILLATOR'S PHASE AT THE GRANT AND NOT ON
    // THE GRANT.**  The 74LS124 at REQTIM 0A01 has run since power-on and the
    // grant only opens its output, so the wait is between thirteen and
    // fourteen of its periods --- `busint::debug_timeout_at`.  One row a
    // phase, so a check can look its own grant up rather than take an
    // average, and so that a fabric restarting the oscillator at the grant
    // fails on all but the lucky ones.
    // **AND THE FIRST TABLE BESIDE IT, FOR THE SAME PHASES.**  A check with
    // only the second has to know how the fabric turns muir's instant into
    // `-MEMACK`, and would be asserting that convention rather than the
    // table.  With both, it can measure the convention on an ordinary cycle
    // nothing answers and apply it to a debug one: what is left is the count,
    // thirteen intervals against five, which is the whole of the claim.
    let mut nxm_tmo: Vec<String> = Vec::new();
    let mut dbg_tmo: Vec<String> = Vec::new();
    let period = muir::chip::VCO_PERIOD.0 / muir::chip::VCO_PERIOD.1;
    let mut phase = 0u64;
    while phase < period {
        let n = busint::nxm_timeout_at(phase) - phase;
        assert_eq!(
            n + busint::DEBUG_TIMEOUT_NS - busint::TIMEOUT_NS,
            busint::debug_timeout_at(phase) - phase,
            "the two tables differ by their counts alone"
        );
        nxm_tmo.push(format!("NXMTMO {phase} {n}"));
        // A grant a whole number of periods in, at this phase: the answer is
        // the same at every one of them, which is asserted rather than
        // assumed.
        let a = busint::debug_timeout_at(phase) - phase;
        let b = busint::debug_timeout_at(phase + 17 * period) - (phase + 17 * period);
        assert_eq!(a, b, "the timeout's delay is a function of the phase alone");
        dbg_tmo.push(format!("DBGTMO {phase} {a}"));
        phase += 5;
    }

    // The cycles themselves, out of `busint::Busint`.  The last two are the
    // instant either side of the interface's own giving up: an answer that
    // arrives before it is taken and one that arrives after is nothing,
    // `SELECT DEBUG` being down by then.
    let one = dbg_cycle(busint::DEBUG_CYCLE, false, true, Some(0));
    let tmo = one.grant_ns + busint::debug_timeout_at(one.grant_ns) - one.grant_ns;
    let late = tmo - one.req_ns.unwrap();
    let cases: [(u8, bool, bool, Option<u64>); 8] = [
        // strobe, write, cable, the far end's answer after the request
        (busint::DEBUG_STATUS, false, false, None),
        (busint::DEBUG_ADDRESS, true, false, None),
        (busint::DEBUG_ADDRESS, true, true, Some(200)),
        (busint::DEBUG_MODIFIER, true, true, Some(40)),
        (busint::DEBUG_CYCLE, false, true, Some(2_000)),
        (busint::DEBUG_CYCLE, false, true, None),
        (busint::DEBUG_STATUS, false, true, Some(late - 100)),
        (busint::DEBUG_STATUS, false, true, Some(late + 100)),
    ];
    let mut dbg_out: Vec<String> = Vec::new();
    let mut n = 0u32;
    let mut answered_rows = 0u32;
    let mut timeout_rows = 0u32;
    for (strobe, write, cable, after) in cases {
        let c = dbg_cycle(strobe, write, cable, after);
        let w = u32::from(write);
        let cab = u32::from(cable);
        let to = u32::from(c.timed_out);
        let tk = u32::from(c.taken);
        let req = c.req_ns.map_or(NONE as u64, |v| v);
        let ans = c.ans_ns.map_or(NONE as u64, |v| v);
        if c.timed_out {
            timeout_rows += 1;
        } else {
            answered_rows += 1;
        }
        // What the fabric is held to, said as the model's own relations: with
        // no cable `-UB SSYN` is `-UB MSYN`, and with one it is the far end's
        // acknowledgement, unless the interface gave up first.
        if !cable {
            assert_eq!(c.ssyn_ns, c.msyn_ns, "with no cable the pull-up answers at -UB MSYN");
        } else if !c.timed_out {
            assert_eq!(c.ssyn_ns, c.ans_ns.unwrap(), "-UB SSYN is the other machine's DEBUG ACK");
        }
        dbg_out.push(format!(
            "DBGOUT {n} {cab} {w} {strobe} {:x} {} {} {req} {ans} {} {} {to} {tk}",
            0xA5A5u32 ^ u32::from(strobe) << 8,
            c.grant_ns,
            c.msyn_ns,
            c.ssyn_ns,
            c.memack_ns
        ));
        n += 1;
    }
    assert!(answered_rows >= 5 && timeout_rows >= 2, "both outcomes are in the trace");

    println!("#");
    println!("# ---- APPENDED: the debug block, 0o766100-0o766137, page DBGOUT ----");
    println!("#");
    println!("# This machine as somebody else's DEBUGGER: the four registers CC writes,");
    println!("# whose cycles go out on the cable and are answered by the other machine.");
    println!("# busint::register gives them None because they are no register of this");
    println!("# board's, which is why the rows above say nothing about them and these");
    println!("# say all of it.  They are at the END of the file so that every row above");
    println!("# is byte for byte what it was before the cable's end was built.");
    println!("#");
    println!("# DBGREG     uaddr strobe");
    println!("#     busint::debug_register(uaddr): which of the four strobes this address");
    println!("#     puts on DEBUG OUT A<1:0>.  {} the cycle, {} the status, {} the",
             busint::DEBUG_CYCLE, busint::DEBUG_STATUS, busint::DEBUG_MODIFIER);
    println!("#     modifier register, {} the address register.  uaddr is octal.",
             busint::DEBUG_ADDRESS);
    println!("# NXMTMO     phase delay");
    println!("#     busint::nxm_timeout_at: an ORDINARY cycle granted at this phase of the");
    println!("#     REQTIM oscillator's period is given up on this long after the grant.");
    println!("#     The REQTIM PROM's first table, which is what every cycle but a debug");
    println!("#     one takes, and it is here so that a check can measure the fabric's own");
    println!("#     convention on a cycle it already holds and apply it to a debug cycle.");
    println!("# DBGTMO     phase delay");
    println!("#     busint::debug_timeout_at: a cycle granted at this phase of the REQTIM");
    println!("#     oscillator's period is given up on this long after the grant.  The");
    println!("#     oscillator free-runs from power-on, so the wait is not one number.");
    println!("# DBGOUT     n cable write strobe wdata grant msyn req ans ssyn memack timed_out taken");
    println!("#     one cycle of the debugger's own into the block, out of busint::Busint.");
    println!("#     cable is whether a board is at the far end; req is -DEBUG OUT REQ on");
    println!("#     the cable and ans the other machine's DEBUG ACK, both {NONE:x} where");
    println!("#     there was none; taken is whether the interface took that");
    println!("#     acknowledgement, which it does not after it has given up.  Every");
    println!("#     instant is in nanoseconds from the same power-on.");
    println!("#");
    println!("# debug_out_request_ns {}", busint::DEBUG_OUT_REQUEST_NS);
    println!("# debug_timeout_ns {}", busint::DEBUG_TIMEOUT_NS);
    println!("# unibus_address_ns {}", busint::UNIBUS_ADDRESS_NS);
    println!("# unibus_ack_ns {}", busint::UNIBUS_ACK_NS);
    println!("# unibus_strobe_ns {}", busint::UNIBUS_STROBE_NS);
    println!("# dbg_low {DBG_LOW:o}");
    println!("# dbg_high {DBG_HIGH:o}");
    println!("# dbg_regs {}", dbg_regs.len());
    println!("# dbg_tmo_rows {}", dbg_tmo.len());
    println!("# nxm_timeout_ns {}", busint::TIMEOUT_NS);
    println!("# dbg_cycles {n}");
    for d in &dbg_regs {
        println!("{d}");
    }
    for d in &nxm_tmo {
        println!("{d}");
    }
    for d in &dbg_tmo {
        println!("{d}");
    }
    for d in &dbg_out {
        println!("{d}");
    }

    eprintln!(
        "busint_regs: {} rows, {} register cycles, {} mapped cycles ({} of them writes of MD), \
         {} timeouts, {} wire rows, {iface_rows} decode rows, {win_rows} window rows, \
         {} debug addresses and {n} debug cycles",
        g.line, g.ops, g.maps, g.md_writes, g.errs, g.lines_rows, dbg_regs.len()
    );
}
