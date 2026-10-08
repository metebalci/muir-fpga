// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **Revision 15's trace, a row a clock** (contract G3 revision 15, §12.3,
//! appendix A15b): what muir's pipeline (`muir::pipeline::Pipeline`, the
//! `rtl` engine on revision 15) does in each clock, in the columns
//! `tb/quux15_core_tb.cpp` holds the fabric's core to.
//!
//! Revisions 13 and 14 are traced a microcycle a row (`trace.rs`).  Revision
//! 15 runs a microcycle through four stages of a clock each, CS, RD, EX and
//! WB, and a word can wait in a stage, so its trace is a row a clock: what
//! stands in each stage and what happened in that clock.
//!
//! **ROW `k` IS THE MACHINE AS CLOCK `k` ENDS**: the stages' words after the
//! clock's edge, and the events of the clock.  Row 0 is the machine after
//! its boot, before any clock.  The columns:
//!
//!   clock     `k`
//!   cs rd ex wb
//!             each stage's word: `<15>` a word stands there, `<14>` it is
//!             nopped, `<13:0>` its address; 0 for a nopped word, whose
//!             address muir does not give
//!   commit    the microcycle EX committed in this clock, in the same form
//!   pdlptr pdlidx spcptr q vma md lc ic
//!             the eight registers EX writes as the last commit left them
//!             (`muir::pipeline::registers_of`): PDL pointer and index, the
//!             micro stack's pointer, Q, VMA, MD, LC, INTERRUPT-CONTROL
//!   oalow oahigh
//!             OA-REG-LOW and OA-REG-HIGH as the clock ends
//!   grant     a start granted at WB in this clock: 1 a read, 3 a write, 0
//!             none
//!   gaddr     its bus address, 0 with none
//!   mdl       1 when a read's word landed in MD in this clock
//!   mdword    that word, 0 with none
//!   reg       1 when a device register was taken in this clock
//!   raddr     its bus address, 0 with none
//!   queue     the writes the port's queue holds, as the clock ends
//!   inflight  the writes accepted and not yet answered, as the clock ends
//!             (`muir::pipeline::Port::depths`), so that the queue's and
//!             the in-flight list's limits are held each clock and not only
//!             by results
//!   halted    1 when the machine is halted, drained
//!
//! What the testbench compares of each is its own business and is written
//! there: a nopped word's address, the registers on a row with no commit,
//! and an event's address or word with no event are not compared.
//!
//! **ONE EVENT OF A KIND A CLOCK.**  A clock commits one microcycle, grants
//! one start, lands one word and takes one register at most; a second of a
//! kind in one clock would need a column this format does not have, so the
//! trace refuses it rather than dropping one.

use muir::engine::Engine;
use muir::pipeline::{Event, Pipeline, registers_of};

/// The columns, in order.
pub const COLUMNS: &str = "# clock cs rd ex wb commit pdlptr pdlidx spcptr q vma md lc ic \
     oalow oahigh grant gaddr mdl mdword reg raddr queue inflight halted";

/// The radix, said once so no reader has to guess.
pub const RADIX: &str = "# every value hexadecimal; row k is the machine as clock k ends";

/// A stage's word, or a commit, as the columns write it.
pub fn slot(s: Option<Option<u16>>) -> u64 {
    match s {
        None => 0,
        Some(None) => 0xc000,
        Some(Some(pc)) => 0x8000 | u64::from(pc & 0x3fff),
    }
}

/// The trace being taken: where the pipeline's records were read up to, and
/// the registers as the last commit left them.
pub struct Trace15 {
    events: usize,
    commits: usize,
    regs: Option<[u64; 8]>,
}

/// One row, and the microcycle committed in its clock, if any.
pub struct Row {
    pub line: String,
    pub commit: Option<Option<u16>>,
}

impl Trace15 {
    /// Turns on the pipeline's records the rows are made of: before its
    /// boot, so that nothing the boot records is missed.
    pub fn start(e: &mut Pipeline) -> Self {
        e.events = Some(Vec::new());
        e.registers = Some(Vec::new());
        Trace15 { events: 0, commits: 0, regs: None }
    }

    /// The row of the clock the pipeline has just run, or of its boot.
    pub fn row(&mut self, e: &Pipeline) -> Row {
        let clock = e.clock();
        let regs = *self.regs.get_or_insert_with(|| registers_of(e.machine()));
        let mut regs_now = regs;
        let (mut commit, mut committed) = (0u64, None);
        let (mut grant, mut gaddr) = (0u64, 0u64);
        let (mut mdl, mut mdword) = (0u64, 0u64);
        let (mut reg, mut raddr) = (0u64, 0u64);
        let events = e.events.as_ref().expect("the trace's records are on");
        for &(at, ev) in &events[self.events..] {
            assert_eq!(at, clock, "trace15: an event of clock {at} read at clock {clock}");
            match ev {
                Event::Commit(pc) => {
                    assert!(committed.is_none(), "trace15: two commits in clock {clock}");
                    committed = Some(pc);
                    commit = slot(Some(pc));
                    let recorded = e.registers.as_ref().expect("the trace's records are on");
                    regs_now = recorded[self.commits];
                    self.commits += 1;
                }
                Event::Grant(bus, write) => {
                    assert_eq!(grant, 0, "trace15: two grants in clock {clock}");
                    grant = 1 | u64::from(write) << 1;
                    gaddr = u64::from(bus);
                }
                Event::Md(word) => {
                    assert_eq!(mdl, 0, "trace15: two words landed in MD in clock {clock}");
                    mdl = 1;
                    mdword = word;
                }
                Event::Register(bus) => {
                    assert_eq!(reg, 0, "trace15: two registers taken in clock {clock}");
                    reg = 1;
                    raddr = u64::from(bus);
                }
            }
        }
        self.events = events.len();
        assert_eq!(
            self.commits,
            e.registers.as_ref().map_or(0, Vec::len),
            "trace15: the registers recorded and the commits disagree at clock {clock}"
        );
        self.regs = Some(regs_now);
        let [cs, rd, ex, wb] = e.stages();
        let (oalow, oahigh) = e.oa_registers();
        let (queue, inflight) = e.port.depths();
        let r = regs_now;
        let line = format!(
            "{clock:x} {:04x} {:04x} {:04x} {:04x} {commit:04x} {:x} {:x} {:x} {:x} {:x} {:x} {:x} {:x} \
             {oalow:x} {oahigh:x} {grant:x} {gaddr:x} {mdl:x} {mdword:x} {reg:x} {raddr:x} {queue:x} {inflight:x} {:x}",
            slot(cs),
            slot(rd),
            slot(ex),
            slot(wb),
            r[0],
            r[1],
            r[2],
            r[3],
            r[4],
            r[5],
            r[6],
            r[7],
            u8::from(e.is_halted()),
        );
        Row { line, commit: committed }
    }
}
