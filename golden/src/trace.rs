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
//! change here: only `md` and `ack` may move.
//!
//! **`md` is the one column the drain cannot get right, and it is taken off
//! the `M` bus instead.**  See [`Trace::row`]: a hang that costs no time is
//! still a hang, `MD` is still strobed before the read phase, and no number of
//! ticks of draining will separate it from the microcycle it precedes.  So
//! `md` may move on an unstalled row, where every other column may not.

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
        let mut md = e.machine().md as u64;
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
            md = e.machine().md as u64;
            vma = e.machine().vma;
            if let Some(at) = e.busint().ack_at() {
                ack = at;
            }
        }
        if ack == 0 {
            ack = e.busint().ack_at().unwrap_or(0);
        }
        // `MD` INSIDE A MICROCYCLE, AND WHY NO AMOUNT OF DRAINING FINDS IT.
        //
        // `MD` moves inside a microcycle under one gate: `-HANG`, which is
        // `NAND(RD.IN.PROGRESS, USE.MD, -CLK3G)` at VCTL1 3F17.  The hang
        // holds the read phase off until `-RDFINISH`, so the word is in `MD`
        // *before* the phase that reads it --- "the word is in MD for the read
        // phase", which is what the stretch is for.  Everything else that
        // writes `MD` --- `DESTMDR` at VCTL2 1D27, and the fabric's commit of
        // a word held over a cycle that did not hang --- lands on the cpu
        // clock edge, after the sample the testbench compares.
        //
        // **A hang that costs no time is still a hang.**  [`Rtl::stall_for`]
        // charges `max(finish, ns + cycle) - cycle`, so a read acknowledged
        // early enough that `-RDFINISH` falls inside the microcycle's own
        // length stretches it by nothing --- MIT's "may be just barely in time
        // to avoid a HANG" --- and `Rtl::step_body` then runs the microcycle
        // in the same `step_until` call.  The drain above sees no extra call
        // and no nanosecond of stall, so `drained` and the `stall` column are
        // both zero on a row whose `MD` has moved.  Draining at a finer grain
        // cannot help: the stretch is not a length to subdivide.  Measured on
        // the band: this is microcycle 2,247,076, PC `0o5414`, where the
        // acknowledgement lands two nanoseconds into a 185 ns microcycle.
        //
        // So `MD` is not read back at all.  It is taken off the **`M` bus**,
        // which muir records in the read phase that ran and which *is* `MD`
        // whenever the instruction reads it: `mfenb` is on for any `IR<31>`
        // source that is neither SPC nor PDL, and the `MF` mux answers
        // `self.m.md` for `SRCMD` (`Rtl::read_phase`).  That is an identity in
        // muir rather than an inference about which stall happened when, and
        // it needs no `NOPA` and no `DESTMDR` test: a nopped `SRCMD` cannot
        // hang, so the bus still reads the word `MD` came in with, and a
        // `DESTMDR` writes at the edge, after the read phase has driven it.
        //
        // Where `SRCMD` is not encoded, `USE.MD` is down, `-HANG` cannot be
        // taken, and `MD` cannot move inside the microcycle --- so the sample
        // above stands: taken before the step, and carried forward by the
        // drain, which is where a `-WAIT`'s master clock edges commit a word.
        //
        // The two rows that used to hold the read-back's own conditions still
        // hold this, and were re-measured for it.  Microcycle 1,418,019 both
        // reads `MD` and writes it: the bus word is 0 and `OB` is `0o20000`,
        // so reading `MD` back after the step gives the instruction's own
        // store --- which is where the next row's column starts, and not what
        // this one's read phase saw.  Microcycle 1,062,761 hangs 528 ns on a
        // read of the pack's label: `MD` came in holding 7 and the bus hands
        // over `LABL`, so not reading back at all gives 7.  The `M` bus gives
        // 0 and `LABL`, which is right both times.
        //
        // `MD` alone: `VMA` moves on the cpu clock edge, which a stall holds
        // off, so reading it back would be the *next* microcycle's address.
        let signals = e.signals();
        assert_eq!(signals[1].0, "IR", "muir reordered Rtl::signals()");
        assert_eq!(signals[4].0, "M", "muir reordered Rtl::signals()");
        let row_ir = signals[1].1;
        let srcmd = (row_ir >> 31) & 1 != 0
            && (row_ir >> 29) & 1 != 0
            && (row_ir >> 26) & 7 == 2;
        if srcmd {
            md = signals[4].1;
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
