// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! One microcycle of the processor's reference trace: the columns, and the
//! sampling that makes them honest.
//!
//! Two programs write this format --- `rtl.rs` from MIT's boot PROM and
//! `rtl_sys.rs` from a System pack --- and one testbench reads both, so the
//! header line and the sampling have to agree exactly.  Kept in two copies
//! they did not: `rtl_sys.rs` took `ack` after the step where `rtl.rs`
//! watches it through the stall, which silently loses the one bus cycle in
//! seventeen thousand that arbitrates for the Unibus before it is granted.
//! That divergence is what this module exists to prevent, and it had already
//! happened by the time the module was written.
//!
//! **Everything here is sampled after the stall, not before it.**  A stall is
//! usually a wait for `MD`: `-LOADMD` strobes it while the clock is held off,
//! so the read phase that actually runs sees the new word and a sample taken
//! before the stall is the word the cycle was waiting to be rid of.  Measured
//! on the boot PROM: wrong on 5,652 of 600,000 microcycles.  The same goes
//! for `LPC`, `VMA`, and for when `-MEMACK` is due.
//!
//! [`Rtl::step_until`] is muir's own way of running a stall without the
//! microcycle behind it --- "the microcycle runs, at the same instant it
//! would have, on a later step" --- so the stall is drained a tick at a time,
//! resampling as it goes, and the sample that survives is the one the
//! microcycle ran on.  The trace is otherwise identical to one taken with
//! plain [`Engine::step`], which is worth checking column by column after any
//! change here: only `md` and `ack` may move, and only on stalled rows.

use muir::engine::Engine;
use muir::machine::Halt;
use muir::rtl::Rtl;

/// Five nanoseconds, the master clock's period: the step a stall is drained
/// in, small enough to land on the grid every instant of it is a multiple of.
pub const TICK_NS: u64 = 5;

/// The columns, in order. `cycle` is the absolute microcycle rather than the
/// line number, so a row says where in the run it came from.
pub const COLUMNS: &str = "# cycle pc ir q a m alu r ob dc opc st lc \
     wmapd destspcd iwrited imodd pdlwrited spushd nop n_vmaok jcond pcs1 pcs0 srun \
     lpc md vma promdis errstop stathenb speed1 speed0 stall halted bus ack gnt \
     sintr ns";

/// The radix, said once so no reader has to guess.
pub const RADIX: &str = "# every value hexadecimal; stall, halted and ns in nanoseconds";

/// How many microcycles a stall may be drained for before it is a bug in this
/// engine rather than something the board would do. `Rtl::step_body` says the
/// same thing with the same reasoning.
const DRAIN_LIMIT: u32 = 100_000;

/// The running totals a row's deltas are taken against.
pub struct Trace {
    last_stalled: u64,
    last_halted: u64,
    last_bus: u64,
    line: String,
}

impl Trace {
    pub fn new(e: &Rtl) -> Self {
        Trace {
            last_stalled: e.stalled_ns(),
            last_halted: e.halted_ns(),
            last_bus: e.bus_cycles(),
            line: String::with_capacity(256),
        }
    }

    /// Runs one microcycle and returns its row.
    pub fn row(&mut self, e: &mut Rtl, cycle: u64) -> Result<&str, Halt> {
        let mut lpc = e.lpc();
        let mut md = e.machine().md;
        let mut vma = e.machine().vma;
        // When `-MEMACK` is due for the cycle in flight. Watched through the
        // stall as well as after it: a cycle that arbitrates for the Unibus
        // is granted, acknowledged and finished entirely inside the stall of
        // a later microcycle, and a sample taken only after the step never
        // sees it.
        let mut ack = e.busint().ack_at().unwrap_or(0);

        let mut drained = 0u32;
        loop {
            let before = e.machine().cycles;
            e.step_until(e.ns() + TICK_NS)?;
            if e.machine().cycles != before {
                break;
            }
            drained += 1;
            assert!(
                drained < DRAIN_LIMIT,
                "microcycle {cycle} never ran: the bus has not let go at PC {:o}",
                e.pc()
            );
            lpc = e.lpc();
            md = e.machine().md;
            vma = e.machine().vma;
            if let Some(at) = e.busint().ack_at() {
                ack = at;
            }
        }
        if ack == 0 {
            ack = e.busint().ack_at().unwrap_or(0);
        }
        // A hang that resolves and runs its microcycle inside one
        // `step_until` is the case the drain above cannot catch: `stall_for`
        // carries the bus to the end of the stretch, `-LOADMD` strobes `MD`
        // there, and the read phase is then taken again *in the same call*
        // and runs --- which is the point of the stretch, "the word is in MD
        // for the read phase".  So a stalled microcycle's `MD` is read back
        // after it, where an unstalled one's is read before.
        //
        // `MD` alone: `VMA` moves on the cpu clock edge, which a stall holds
        // off, so a read-back would be the *next* microcycle's address.
        //
        // And only for a **hang**, which is what `USE.MD` --- `NOR(-SRCMD,
        // NOPA)` at VCTL1 3F18 --- decides: a `-WAIT` lets the master clock
        // run and `MD` is strobed inside the drain where the loop above sees
        // it, so a read-back there would be the *next* microcycle's word.
        // Measured both ways on the pack trace: reading back on every stalled
        // row is wrong at microcycle 1,418,019, and never reading back is
        // wrong at 1,062,761.
        let signals = e.signals();
        let row_ir = signals[1].1;
        let row_nop = e.spy()[6].1 != 0;
        let srcmd = (row_ir >> 31) & 1 != 0 && (row_ir >> 29) & 1 != 0
            && (row_ir >> 26) & 7 == 2;
        // ...and not when the instruction writes `MD` itself.  `DESTMDR` is
        // `MDSEL AND -CLK2C` at VCTL2 1D27, taken at the edge, so a read-back
        // after such a microcycle is that instruction's own store and not the
        // word its read phase saw.  Measured: without this the pack trace
        // fails at microcycle 1,418,019, where `MD` is both read and written.
        let class = (row_ir >> 43) & 3;
        let dest = !row_nop && (class == 0 || class == 3);
        let destmdr = dest && (row_ir >> 25) & 1 == 0
            && (row_ir >> 23) & 1 != 0
            && (row_ir >> 22) & 1 != 0;
        if drained > 0 && srcmd && !row_nop && !destmdr {
            md = e.machine().md;
        }

        let stall = e.stalled_ns() - self.last_stalled;
        self.last_stalled = e.stalled_ns();
        let halted = e.halted_ns() - self.last_halted;
        self.last_halted = e.halted_ns();
        let bus = e.bus_cycles() - self.last_bus;
        self.last_bus = e.bus_cycles();
        let gnt = u8::from(e.busint().granted());
        // `SINTR` is `INT` off the cables, registered by the 74S175 at LCC
        // 3E12 on CLK3C --- so this is sampled *after* the step, at the edge
        // muir registers it on, and is the value the *next* microcycle's read
        // phase sees. The fabric registers it the same way, so a row's column
        // driven over that row lands where muir's does.
        let sintr = u8::from(e.machine().interrupt());

        self.line.clear();
        self.line.push_str(&format!("{cycle:x}"));
        for (_, v) in signals {
            self.line.push_str(&format!(" {v:x}"));
        }
        for (_, v) in e.spy() {
            self.line.push_str(&format!(" {v:x}"));
        }
        // The mode register as it stands at the end of this microcycle, which
        // is what the next one's SPEEDCLK takes into the synchroniser and
        // what its own fetch is gated by.
        let mode = &e.machine().mode;
        self.line.push_str(&format!(
            " {:x} {:x} {:x} {:x} {:x} {:x} {:x} {:x} \
             {stall:x} {halted:x} {bus:x} {ack:x} {gnt:x} {sintr:x} {:x}",
            lpc,
            md,
            vma,
            mode.prom_disable as u8,
            mode.errstop as u8,
            mode.stathenb as u8,
            mode.speed1 as u8,
            mode.speed0 as u8,
            e.ns()
        ));
        Ok(&self.line)
    }
}
