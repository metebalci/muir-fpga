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

use muir::clock::TimingModel;
use muir::engine::Engine;
use muir::machine::{Halt, Machine};
use muir::rtl::Rtl;

/// MIT's grid, the master clock's period: the step a stall is drained in,
/// small enough to land on the grid every instant of it is a multiple of.
pub const TICK_NS: u64 = 10;

/// Whose time the engine keeps: muir's model of this fabric's grid, under
/// which every instant `rtl` reaches is a multiple of [`TICK_NS`].
#[allow(dead_code)]
pub const TIMING: TimingModel = TimingModel::Fpga;

/// The engine a trace is taken from: `machine` under `rtl`, on [`TIMING`],
/// which has to be chosen before the machine runs.
#[allow(dead_code)]
pub fn engine(machine: Machine) -> Rtl {
    engine_on(machine, TIMING)
}

/// The same, on `timing`: [`TIMING`] for the CADR, and for QUUX its
/// synchronous microcycle, `TimingModel::Sync`, which keeps the same grid
/// (`machine_axis::take_timing` says which).
pub fn engine_on(machine: Machine, timing: TimingModel) -> Rtl {
    assert_eq!(TICK_NS, muir::clock::GRID_NS, "the trace's grid is not the one muir's fpga model keeps");
    assert!(
        matches!(timing, TimingModel::Fpga | TimingModel::Sync { .. }),
        "a trace for the fabric is taken on its grid, fpga or sync, not {timing:?}"
    );
    let mut e = Rtl::new(machine);
    e.set_timing_model(timing);
    e
}

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
    /// QUUX's memory port, whose `ack` and `gnt` are derived: [`QuuxPort`].
    quux: Option<QuuxPort>,
}

/// **THE COMMIT OF muir THE DERIVATION BELOW IS CORRECT FOR, AND ONLY FOR.**
/// See [`QuuxPort`].  A later muir (its Q7) changes QUUX's device timing, so
/// the generator refuses to run against any other commit rather than derive
/// the wrong instants silently.
pub const QUUX_PORT_DERIVED_FOR: &str = "0ba4e233a3e211e7a25eba952f4b6d97b03f757e";

/// **`ack` AND `gnt` ON QUUX ARE A DERIVATION, PENDING muir's ACCESSORS.**
///
/// At muir `0ba4e23` (contract Q6) QUUX has no bus interface, so
/// `Rtl::busint()` is `None` and the memory port's own `ack_at()` and
/// `granted()` are not public; `Rtl::bus_answered_at()` is.  The port
/// (`src/memory_port.rs`) sets them so:
///
/// - `granted()` is `Granted | Acked`, exactly the states that carry an
///   answer, so it is `bus_answered_at().is_some()` --- an identity, not a
///   derivation;
/// - `ack_at()` is the answer, except for a DEVICE's READ, which is
///   acknowledged `busint::XBUS_ACK_NS` after it: main memory's cycles (the
///   cache's hit, a line fill, a buffered or unbuffered write) and a
///   timeout have `ack == answered`.
///
/// So the only thing derived is whether the cycle is a device's read.  It is
/// taken from what muir says, never from the fabric:
///
/// - the direction is `MEMWR` of the microcycle that started the cycle ---
///   the row before the one whose step requests it, decoded from its `IR` as
///   `Rtl::read_phase` decodes it (`destmem`, `IR<20:19>`), and a read where
///   that row starts nothing explicitly, which is the macroinstruction fetch;
/// - a main memory read is exactly a cycle the cache looked up: muir's
///   `hits + misses` moves by one at the grant, and by nothing otherwise;
/// - the grant is the edge the request is taken at, the engine's time after
///   the step that counted the cycle.
///
/// **And every piece of it is checked against muir, loudly**: a lookup on a
/// cycle derived as a write, a hit not answered `hit_ns` after the grant, a
/// miss answered sooner than a line fill, and a read the cache did not look
/// up that is neither answered `SETUP_NS + IDEAL_DEVICE_NS` after the grant
/// (a device) nor at muir's own `nxm_timeout_at` (nothing answers) each stop
/// the generator.  When muir adds `Rtl::bus_ack_at()` and `bus_granted()`
/// this goes, and the pin with it.
///
/// **AND THE ACKNOWLEDGMENT ITSELF IS HELD TO WHAT THE PROCESSOR DID WITH
/// IT.**  A read's acknowledgment is when `READ IN PROGRESS` starts to
/// fall: at once for main memory's (`Ack::cached`), 140 ns later for any
/// other (`Rtl`'s `RD_FINISH_NS`, `rtl.rs`, private there and so written
/// here).  QUUX has no hung microcycle: one that reads `MD` with the read
/// in flight holds until then and runs at the next master clock edge.  So
/// a microcycle that reads `MD`, held, and held for nothing else --- it
/// starts no memory cycle, it is no `DIV` or `MUL`, and nothing it does
/// fetches a macroinstruction --- must start at the first edge at or after
/// that fall: at or after it, and less than a microcycle after it.  A
/// derived acknowledgment off by a tick either way is off that interval on
/// every such microcycle whose edge falls where the tick is, which on the
/// boot PROM's thousands of device reads is many of them.  Checked on every
/// one, and the count said on stderr.
struct QuuxPort {
    bus_cycles: u64,
    lookups: u64,
    hits: u64,
    /// The last read's acknowledgment and whether it was main memory's.
    read_ack: Option<(u64, bool)>,
    /// Microcycles whose start was held to a read's fall, and those whose
    /// hold was checked exactly.
    fall_checks: [u64; 2],
    /// The previous row's explicit start: `Some(true)` a write, `Some(false)`
    /// a read, `None` none.
    started: Option<bool>,
    ack: Option<u64>,
    /// What was derived, said on stderr when the trace ends: `[reads the
    /// cache looked up, writes, device reads, other reads timed out]`.
    counts: [u64; 4],
}

impl Drop for QuuxPort {
    fn drop(&mut self) {
        let [looked, writes, device, timeouts] = self.counts;
        eprintln!(
            "trace: QUUX's ack derived for {} cycles: {looked} reads the cache looked up, \
             {writes} writes, {device} device reads, {timeouts} reads timed out; \
             {} microcycles reading MD held to a read's fall, {} of them exactly",
            looked + writes + device + timeouts,
            self.fall_checks[0],
            self.fall_checks[1]
        );
    }
}

/// Refuses a muir other than [`QUUX_PORT_DERIVED_FOR`].
fn refuse_other_muir() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../muir");
    let head = std::process::Command::new("git")
        .args(["-C", dir, "rev-parse", "HEAD"])
        .output()
        .expect("git, to read muir's commit");
    let head = String::from_utf8_lossy(&head.stdout).trim().to_string();
    assert_eq!(
        head, QUUX_PORT_DERIVED_FOR,
        "QUUX's ack and gnt are derived for muir {QUUX_PORT_DERIVED_FOR} only (golden/src/trace.rs, \
         QuuxPort); {dir} is at {head}: take them from muir's own accessors instead"
    );
    let clean = std::process::Command::new("git")
        .args(["-C", dir, "diff", "--quiet", "HEAD", "--", "src"])
        .status()
        .expect("git, to read muir's tree");
    assert!(clean.success(), "muir's src/ differs from {QUUX_PORT_DERIVED_FOR}: the derivation is for that tree");
}

/// `MEMWR` and `MEMRD` of a row, as `Rtl::read_phase` decodes them from `IR`
/// (`destmem`, then `IR<20:19>`: 1 a read, 2 a write), `None` when the row
/// starts nothing explicitly.  A nopped row has no destination.
fn explicit_start(ir: u64, nop: bool) -> Option<bool> {
    let bit = |n: u32| (ir >> n) & 1 != 0;
    let dest = !nop && matches!((ir >> 43) & 3, 0 | 3);
    let destmem = dest && !bit(25) && bit(23);
    match (destmem, (ir >> 19) & 3) {
        (true, 1) => Some(false),
        (true, 2) => Some(true),
        _ => None,
    }
}

impl QuuxPort {
    fn new(e: &Rtl) -> QuuxPort {
        refuse_other_muir();
        let c = e.cache().expect("QUUX always has its cache (contract Q6)");
        QuuxPort {
            bus_cycles: e.bus_cycles(),
            lookups: c.hits + c.misses,
            hits: c.hits,
            started: None,
            ack: None,
            counts: [0; 4],
            read_ack: None,
            fall_checks: [0; 2],
        }
    }

    /// After every step: a cycle counted since the last is derived here.
    fn observe(&mut self, e: &Rtl) {
        let c = e.cache().expect("QUUX's cache");
        let lookups = c.hits + c.misses;
        let cycles = e.bus_cycles() - self.bus_cycles;
        assert!(cycles <= 1, "two bus cycles inside one step at {} ns", e.ns());
        let looked = lookups - self.lookups;
        let hit = c.hits - self.hits;
        self.lookups = lookups;
        self.hits = c.hits;
        if cycles == 0 {
            assert_eq!(looked, 0, "a cache lookup with no bus cycle at {} ns", e.ns());
            return;
        }
        self.bus_cycles = e.bus_cycles();
        let grant = e.ns();
        let answered = e.bus_answered_at().expect("a cycle counted is granted at its edge");
        let write = self.started == Some(true);
        let gap = answered.checked_sub(grant).unwrap_or_else(|| {
            panic!("QUUX's cycle answered at {answered} ns, before its grant at {grant} ns")
        });
        let hit_ns = c.config.hit_ns;
        let fill_ns = e.memory_timing().expect("QUUX's memory timing").read_ns;
        let device_ns = muir::busint::SETUP_NS + muir::busint::IDEAL_DEVICE_NS;
        let device_read = if looked == 1 {
            assert!(!write, "the cache looked up a cycle derived as a write, at {grant} ns");
            if hit == 1 {
                assert_eq!(gap, hit_ns, "a hit answered {gap} ns after its grant at {grant} ns");
            } else {
                assert!(gap >= fill_ns, "a miss answered {gap} ns after its grant at {grant} ns");
            }
            false
        } else if write {
            false
        } else {
            let timeout = e.timing_model().free_running(muir::busint::nxm_timeout_at(grant));
            assert!(
                gap == device_ns || answered == timeout,
                "a read the cache did not look up, answered {gap} ns after its grant at {grant} ns, \
                 is neither a device's ({device_ns}) nor a timeout (at {timeout})"
            );
            gap == device_ns
        };
        self.counts[if looked == 1 {
            0
        } else if write {
            1
        } else if device_read {
            2
        } else {
            3
        }] += 1;
        let ack = answered + if device_read { muir::busint::XBUS_ACK_NS } else { 0 };
        self.ack = Some(ack);
        self.read_ack = (!write).then_some((ack, looked == 1));
    }

    /// After a row: what it starts, for the cycle the next row requests; and
    /// if it read `MD`, its start against the last read's fall.
    fn row_done(&mut self, e: &Rtl, ir: u64, nop: bool, stall: u64, srcmd: bool) {
        self.started = explicit_start(ir, nop);
        let Some((ack, cached)) = self.read_ack else { return };
        if !srcmd || nop {
            return;
        }
        // `RD_FINISH_NS` (`rtl.rs`), and none for a cycle of main memory's.
        let fall = ack + if cached { 0 } else { 140 };
        let ilong = (ir >> 45) & 1 != 0;
        let cycle = u64::from(e.timing_model().cycle_ns(muir::clock::Speed::Normal, ilong));
        let start = e.ns() - cycle;
        if start >= ack {
            // The read had been answered before this microcycle was asked
            // about; it constrains the next read's microcycles, not this one's.
            assert!(
                start >= fall,
                "a microcycle reading MD started at {start} ns, before the fall at {fall} ns of \
                 the read acknowledged at {ack} ns (derived: golden/src/trace.rs, QuuxPort)"
            );
            self.fall_checks[0] += 1;
        }
        // Held for this read alone: it waited, and starts nothing, and is no
        // multiply or divide (a `-WAIT` of its own), and no fetch.
        let dest = !nop && matches!((ir >> 43) & 3, 0 | 3);
        let destmem = dest && (ir >> 25) & 1 == 0 && (ir >> 23) & 1 != 0;
        let muldiv = !nop && matches!((ir >> 43) & 3, 0) && muir::muldiv::decode(ir).is_some();
        if stall > 0 && !destmem && !muldiv && start >= ack {
            assert!(
                start < fall + cycle,
                "a microcycle reading MD, held for the read acknowledged at {ack} ns, started at \
                 {start} ns, a microcycle or more after its fall at {fall} ns (derived: \
                 golden/src/trace.rs, QuuxPort)"
            );
            self.fall_checks[1] += 1;
        }
        self.read_ack = None;
    }
}

impl Trace {
    pub fn new(e: &Rtl) -> Self {
        Trace {
            last_stalled: e.stalled_ns(),
            last_halted: e.halted_ns(),
            last_bus: e.bus_cycles(),
            line: String::with_capacity(256),
            quux: e.busint().is_none().then(|| QuuxPort::new(e)),
        }
    }

    /// `-MEMACK`'s instant for the cycle in flight: the bus interface's on the
    /// CADR, [`QuuxPort`]'s derivation on QUUX.
    fn ack_at(&self, e: &Rtl) -> Option<u64> {
        match &self.quux {
            None => e.busint().expect("the CADR's bus interface").ack_at(),
            Some(q) => e.bus_answered_at().and(q.ack),
        }
    }

    fn granted(&self, e: &Rtl) -> bool {
        match &self.quux {
            None => e.busint().expect("the CADR's bus interface").granted(),
            Some(_) => e.bus_answered_at().is_some(),
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
        let mut ack = self.ack_at(e).unwrap_or(0);

        let mut drained = 0u32;
        loop {
            let before = e.machine().cycles;
            e.step_until(e.ns() + TICK_NS)?;
            if let Some(q) = self.quux.as_mut() {
                q.observe(e);
            }
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
            if let Some(at) = self.ack_at(e) {
                ack = at;
            }
        }
        if ack == 0 {
            ack = self.ack_at(e).unwrap_or(0);
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
        // acknowledgment lands two nanoseconds into a 185 ns microcycle.
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
        let gnt = u8::from(self.granted(e));
        if let Some(q) = self.quux.as_mut() {
            let nop = e.spy().iter().any(|&(n, v)| n == "NOP" && v != 0);
            q.row_done(e, row_ir, nop, stall, srcmd);
        }
        // `SINTR` is `INT` off the cables, registered by the 74S175 at LCC
        // 3E12 on CLK3C --- so this is sampled *after* the step, at the edge
        // muir registers it on, and is the value the *next* microcycle's read
        // phase sees. The fabric registers it the same way, so a row's column
        // driven over that row lands where muir's does.
        //
        // **AT THE ENGINE'S OWN TIME, WHICH IS THE EDGE**: `Rtl::clock_edge`
        // registers `interrupt_at(self.ns)`, QUUX's clocks read at the edge
        // that ends the microcycle, waiting or not (muir's `1775bba`), where
        // `interrupt()` reads them at the machine's time, which a wait leaves
        // behind.  The CADR's devices keep the machine's time either way, so
        // its column is what it was.
        let sintr = u8::from(e.machine().interrupt_at(e.ns()));

        self.line.clear();
        self.line.push_str(&format!("{cycle:x}"));
        for (_, v) in signals {
            self.line.push_str(&format!(" {v:x}"));
        }
        for (_, v) in e.spy() {
            self.line.push_str(&format!(" {v:x}"));
        }
        // The mode register as it stands at the end of this microcycle, which
        // is what the next one's SPEEDCLK takes into the synchronizer and
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
