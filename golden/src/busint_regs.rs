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
//! **What is deliberately not here.**
//!
//! - `UB MAP ERROR`, bit 5 of the error status register. muir sets it in
//!   `Machine::mapped_read` and `mapped_write` alone, which are the DEBUG
//!   master's cycles through the Unibus map; the processor's own Unibus
//!   cycles are not mapped and `busint::decode` never makes a map
//!   responder for them. With no debug cable there is no master that can
//!   set it, so nothing here does and the module says the same.
//! - The map's read and write buffers, the 29701s at RBUF and WBUF. They
//!   are the mapped cycle's own state and have the same one master.
//! - The debug block at `0o766100`-`0o766136`. `busint::register` decodes
//!   it to `None` and this trace says so in its `IFACENONE` runs, which is
//!   the claim the fabric has to hold: those four registers answer over the
//!   cable or not at all, and a slave here that answered them would be
//!   answering for a machine that is not there.

use muir::busint::{self, Register, error_status, interrupt_status};
use muir::ioboard::{self, csr};
use muir::simpletv::mode;
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

/// The display's mode register, `simpletv::CONTROL` --- the one thing in
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

    /// Time passes with no cycle: the card's clocks run, which is what makes
    /// `CLOCK READY` and so a clock interrupt possible.
    fn wait(&mut self, ns: u64) {
        self.m.ns += ns;
        self.m.ioboard.advance(self.m.ns);
        self.lines_row();
    }
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
        machine::bus_error::XBUS_NXM | machine::bus_error::UNIBUS_NXM,
        "both NXM bits were reached and no third bit was"
    );
    assert!(g.ops >= 200, "only {} register cycles", g.ops);
    assert!(g.errs >= 8, "only {} timeouts", g.errs);
    assert!(g.lines_rows >= 8, "only {} wire rows", g.lines_rows);

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
    println!("# iface_rows {iface_rows}");
    println!("# none_runs {none_runs}");
    println!("# ops {}", g.ops);
    println!("# errs {}", g.errs);
    println!("# lines_rows {}", g.lines_rows);
    println!("# rows {}", g.line);
    for d in &dec {
        println!("{d}");
    }
    for r in &g.out {
        println!("{r}");
    }

    eprintln!(
        "busint_regs: {} rows, {} register cycles, {} timeouts, {} wire rows, {iface_rows} decode rows",
        g.line, g.ops, g.errs, g.lines_rows
    );
}
