// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the clock control register, out of muir's own
//! `rtl` engine: halting, single-stepping, and forcing a microinstruction in
//! through the debug IR --- which is what CC does and the one thing a
//! debugger over MIT's cable cannot do without.
//!
//! **The register, and where the five bits come from.** `spy::CLK` is EADR 3,
//! Unibus `0o766006`, and MIT's `mit/cadr/ir.bits` lists it under "Writable
//! diagnostic registers":
//!
//! ```text
//! 06  Clock control:
//!       1  Run
//!       2  Step (raising step clocks the machine once)
//!       4  NOP (prevents side-effects from instruction in IR)
//!      10  IDEBUG (causes IR to load from DEBUG-IR instead of control memory)
//!      20  LDSTAT (causes Statistics counter to load from IWR)
//! ```
//!
//! **Those numbers are OCTAL**, MIT's whole table being octal, and the same
//! goes for CC's own writes: `CC-CLOCK` writes `2`, `CC-DEBUG-CLOCK` `12` and
//! `CC-NOOP-DEBUG-CLOCK` `16` --- so the noop debug clock is `STEP` with
//! `NOP11` and `IDEBUG`, bits 3:1, and not `LDSTAT`, which is `20` octal and
//! bit 4. Reading `16` as decimal gives bit 4 alone, which loads the
//! statistics counter and clocks nothing at all. `spy::ClockControl` in muir
//! has the bits and the three writes named together.
//!
//! **What a step is.** `STEP` is registered once into `SSTEP` and again into
//! `SSDONE`, both on `MCLK5A` at OLORD1 1A10 (`../muir/src/rtl.rs`, the
//! master clock edge), and `MACHRUN`'s first term is `SSTEP AND -SSDONE`
//! (the 9S42 at OLORD1 1A15). So `MACHRUN` is up for exactly the one master
//! clock in which `SSTEP` is set and `SSDONE` is not: raising `STEP` runs one
//! microcycle, and it must be lowered again before the next. MIT says the
//! same thing in four words --- "raising step clocks the machine once".
//!
//! **And a step's `MACHRUN` does not go through `-WAIT`.** The gate's other
//! term is `SRUN AND -ERRHALT AND -WAIT AND -STATHALT`; `-WAIT` is in that
//! one only, so a single step runs its microcycle with the bus still busy.
//! `-HANG` parks the generator itself and is not bypassed. This program never
//! reaches a memory cycle, so neither is exercised here; it is written down
//! because the fabric's `machrun` has `-WAIT` in it and the term must go
//! outside.
//!
//! **Why a scripted program and not a reference program.** MIT's boot PROM
//! never writes the clock control register at all and no band does either:
//! the register is the console's, and a machine running its own microcode has
//! no console. So this is the only reference there can be, in the shape
//! `iob.rs` and `busint_regs.rs` are for their cards.
//!
//! **The stimulus is two columns and the rest is the answer.** `clk` is the
//! clock control register as it stands over the master clock the row
//! describes, and `dbgir` is the 48-bit debug IR --- both of them written by
//! `Machine::spy_write` and both, in the fabric, ports of
//! `rtl/machine/cadr_microcycle.sv`. Everything after them is read back the
//! way a console reads it, through `Engine::spy_read`, so every compared
//! column is a word that crosses the diagnostic bus and none is a field
//! reached into.
//!
//! **What the script does**, in CC's own order:
//!
//! 1. Boots and runs, so that the machine has a history and the A memory has
//!    words in it.
//! 2. Halts with a write of 0, and stands still for several master clocks:
//!    `CYCLES` frozen, `SRUN` down, the clock running on.
//! 3. `CC-CLOCK` three times --- `2` then `0` --- one microcycle each, with
//!    `SSDONE` rising a master clock behind and falling two behind the write.
//! 4. Holds `STEP` up over several master clocks, which must run ONE
//!    microcycle and not a stream of them.
//! 5. `CC-EXECUTE`'s own sequence: the debug IR loaded in three halves, then
//!    `CC-NOOP-DEBUG-CLOCK` (`16` octal) --- which loads `IR` from the debug
//!    IR and shows the console the operands and the result on the A, M and O
//!    buses WITHOUT executing it. That read of `OB` is
//!    `(cadr:cc-read-a-mem 1)` exactly.
//! 6. `CC-DEBUG-CLOCK` (`12` octal), which executes the forced instruction,
//!    and one more noop debug clock, "which finishes writes" --- a scratchpad
//!    write lands a microcycle late.
//! 7. Reads the written location back through the debug IR, which is the
//!    whole round trip a debugger makes.
//! 8. `LDSTAT`, which loads the statistics counter from `IWR`.
//! 9. Starts again, and the machine goes on from where the steps left it.

use muir::clock::TimingModel;
use muir::engine::Engine;
use muir::isa::asm::{ALU, SETA, a_dest, a_src, m_src};
use muir::machine::Machine;
use muir::rtl::Rtl;
use muir::spy;

/// How far into MIT's boot PROM the console arrives.
///
/// It has to be past the boot and clear of any memory cycle, because a stall
/// is several master clocks where every other row here is one and the fabric
/// side compares row for row. The PROM's first memory cycle is at microcycle
/// 536,303, so anywhere early is clear; two thousand is enough for the A
/// memory to hold words the forced instructions can read.
const WARMUP: u64 = 2_000;

/// The clock control register's five bits, `spy::ClockControl`'s own order.
const RUN: u16 = 1 << 0;
const STEP: u16 = 1 << 1;
const NOP11: u16 = 1 << 2;
const IDEBUG: u16 = 1 << 3;
const LDSTAT: u16 = 1 << 4;

/// CC's three clock writes, in CC's own octal.
const CC_CLOCK: u16 = STEP; // 2
const CC_DEBUG_CLOCK: u16 = STEP | IDEBUG; // 12 octal
const CC_NOOP_DEBUG_CLOCK: u16 = STEP | NOP11 | IDEBUG; // 16 octal

/// The A memory location `(cadr:cc-read-a-mem 1)` asks for --- the call that
/// came back wrong on the board --- and the one the script writes it into and
/// reads back.
///
/// A memory 1 is the source because it holds a word at `WARMUP` and A memory
/// 5, the obvious choice, holds zero there: a round trip of zero into a
/// scratchpad reading zero passes against a fabric that never wrote anything.
/// The guard below asserts the pair rather than trusting this comment.
const SRC_A: u64 = 1;
const DEST_A: u64 = 0o101;

/// One row of the trace: the two stimulus columns, and what a console reads
/// back after the master clock the row describes.
struct Row {
    what: &'static str,
    clk: u16,
    dbgir: u64,
    cycles: u64,
    pc: u16,
    ir: u64,
    flag1: u16,
    flag2: u16,
    ob: u32,
    a: u32,
    m: u32,
    st: u32,
    ns: u64,
}

fn word32(e: &dyn Engine, low: u8, high: u8) -> u32 {
    (e.spy_read(high) as u32) << 16 | e.spy_read(low) as u32
}

fn ir48(e: &dyn Engine) -> u64 {
    (e.spy_read(spy::IR_HIGH) as u64) << 32
        | (e.spy_read(spy::IR_MED) as u64) << 16
        | e.spy_read(spy::IR_LOW) as u64
}

/// One master clock, and the row it makes.
///
/// `clk` and the debug IR are already in the machine: this is the edge that
/// samples them, exactly as `mclk_edge` does on the board.
fn tick(e: &mut Rtl, what: &'static str, clk: u16, before_ns: u64) -> Row {
    if let Err(h) = e.step() {
        eprintln!("sstep: the machine halted at {what}: {h:?}");
        std::process::exit(1);
    }
    Row {
        what,
        clk,
        dbgir: e.machine().debug_ir,
        cycles: e.machine().cycles,
        pc: e.spy_read(spy::PC),
        ir: ir48(e),
        flag1: e.spy_read(spy::FLAG_1),
        flag2: e.spy_read(spy::FLAG_2),
        ob: word32(e, spy::OB_LOW, spy::OB_HIGH),
        a: word32(e, spy::A_LOW, spy::A_HIGH),
        m: word32(e, spy::M_LOW, spy::M_HIGH),
        st: word32(e, spy::STAT_LOW, spy::STAT_HIGH),
        ns: e.ns() - before_ns,
    }
}

/// Writes the clock control register and runs `n` master clocks under it,
/// which is what a console does: the write lands, and the machine is watched.
fn under(e: &mut Rtl, rows: &mut Vec<Row>, what: &'static str, clk: u16, n: usize) {
    e.spy_write(spy::CLK, clk);
    for _ in 0..n {
        let before = e.ns();
        let row = tick(e, what, clk, before);
        rows.push(row);
    }
}

/// The debug IR in three halves, as `CC-EXECUTE-R` and `-W` load it.
fn load_debug_ir(e: &mut Rtl, insn: u64) {
    e.spy_write(spy::IR_LOW, insn as u16);
    e.spy_write(spy::IR_MED, (insn >> 16) as u16);
    e.spy_write(spy::IR_HIGH, (insn >> 32) as u16);
}

/// `cc_clock` in muir's own tests: the write, two master clocks, the write
/// back to zero, two more. Two is what the two flip flops need --- `SSTEP`
/// rises at the first and the microcycle runs at the second.
fn cc_clock(e: &mut Rtl, rows: &mut Vec<Row>, what: &'static str, clk: u16) {
    under(e, rows, what, clk, 2);
    under(e, rows, "clk-down", 0, 2);
}

fn main() {
    let mut m = Machine::new();
    m.load_prom(&muir::prom::boot_prom());
    let mut e = Rtl::new(m);
    // muir's model of this fabric's grid, chosen before the machine runs:
    // the `ns` column is a microcycle's length on the grid.
    assert_eq!(muir::clock::GRID_NS, 10, "the grid the fabric keeps");
    e.set_timing_model(TimingModel::Fpga);
    e.boot();

    // The machine runs on its own for a while, so that the console arrives at
    // a machine with a history rather than at one still in its first
    // microcycle.
    for _ in 0..WARMUP {
        if let Err(h) = e.step() {
            eprintln!("sstep: the boot PROM halted during the warm-up: {h:?}");
            std::process::exit(1);
        }
    }

    let mut rows: Vec<Row> = Vec::new();

    // ---- running, so that the rows either side of the halt are comparable.
    under(&mut e, &mut rows, "running", RUN, 4);

    // ---- HALT.  `SRUN` is one master clock behind `RUN`, so the microcycle
    // ---- in flight completes and then nothing moves while the clock runs on.
    under(&mut e, &mut rows, "halt", 0, 6);

    // ---- CC-CLOCK, three times: one microcycle each.
    cc_clock(&mut e, &mut rows, "cc-clock", CC_CLOCK);
    cc_clock(&mut e, &mut rows, "cc-clock", CC_CLOCK);
    cc_clock(&mut e, &mut rows, "cc-clock", CC_CLOCK);

    // ---- STEP held up over six master clocks: ONE microcycle, not six.
    // ---- `SSDONE` catches `SSTEP` at the second and holds the gate down.
    under(&mut e, &mut rows, "step-held", STEP, 6);
    under(&mut e, &mut rows, "step-down", 0, 3);

    // ---- CC-EXECUTE.  `((A-MEM 1) SETA A-MEM-1)` read with no destination:
    // ---- the OB shows A memory 1, which is `(cadr:cc-read-a-mem 1)` exactly,
    // ---- and is the call that came back with CC's own stale OBUS on the
    // ---- board because the machine never stepped.
    let read_src = ALU | SETA | a_src(SRC_A) | m_src(7);
    load_debug_ir(&mut e, read_src);
    cc_clock(&mut e, &mut rows, "cc-read-a-mem-1", CC_NOOP_DEBUG_CLOCK);
    let src_word = rows.last().expect("a row").ob;

    // ---- and the destination BEFORE the write, so that the round trip below
    // ---- is a word arriving somewhere it was not.
    let read_dest = ALU | SETA | a_src(DEST_A) | m_src(7);
    load_debug_ir(&mut e, read_dest);
    cc_clock(&mut e, &mut rows, "read-dest-before", CC_NOOP_DEBUG_CLOCK);
    let dest_before = rows.last().expect("a row").ob;

    // ---- A write through the debug IR: A memory 1 into A memory 0o101.
    let write = ALU | SETA | a_src(SRC_A) | m_src(7) | a_dest(DEST_A);
    load_debug_ir(&mut e, write);
    // Loaded but not executed: NOP11 is up.
    cc_clock(&mut e, &mut rows, "load-write", CC_NOOP_DEBUG_CLOCK);
    // Executed.  The scratchpad write is a microcycle behind, pending in L.
    cc_clock(&mut e, &mut rows, "execute-write", CC_DEBUG_CLOCK);
    // "Which finishes writes": one more clock in NOP and DEBUG mode.
    cc_clock(&mut e, &mut rows, "finish-write", CC_NOOP_DEBUG_CLOCK);

    // ---- and read the written location back, the whole round trip.
    load_debug_ir(&mut e, read_dest);
    cc_clock(&mut e, &mut rows, "read-back", CC_NOOP_DEBUG_CLOCK);
    let dest_after = rows.last().expect("a row").ob;

    // **THE ROUND TRIP MUST NOT BE A ROUND TRIP OF ZERO.**  A write of the
    // word the destination already held, or of zero into a scratchpad that
    // reads zero, passes against a fabric that never wrote anything at all
    // --- which is this project's control-store-comes-up-zero trap in a
    // scratchpad.  The source and destination are hard-coded, so whether
    // they are distinct is a property of the boot PROM at `WARMUP` and has
    // to be asserted here rather than hoped for.
    if src_word == 0 || src_word == dest_before || dest_after != src_word {
        eprintln!(
            "sstep: the debug IR round trip tests nothing: A {SRC_A:o} = {src_word:#010x}, \
             A {DEST_A:o} was {dest_before:#010x} and is {dest_after:#010x}"
        );
        std::process::exit(1);
    }

    // ---- LDSTAT.  The counter loads from `IWR<31:0>`, which is the M bus of
    // ---- the microcycle before, so the machine runs first to put something
    // ---- there: loading zero over a counter reading zero is the same
    // ---- untestable shape as the round trip above.
    under(&mut e, &mut rows, "run-for-iwr", RUN, 4);
    under(&mut e, &mut rows, "halt-for-iwr", 0, 3);
    let m_before_ldstat = rows.last().expect("a row").m;
    under(&mut e, &mut rows, "ldstat", LDSTAT | STEP, 2);
    under(&mut e, &mut rows, "ldstat-down", 0, 2);
    let st_after = rows.last().expect("a row").st;
    if st_after == 0 {
        eprintln!(
            "sstep: LDSTAT loaded {st_after:#010x} into a counter that already read zero, \
             with M {m_before_ldstat:#010x}: the row tests nothing"
        );
        std::process::exit(1);
    }

    // ---- START, and the machine goes on from where the steps left it.
    under(&mut e, &mut rows, "start", RUN, 8);

    println!(
        "# clk dbgir cycles pc ir flag1 flag2 ob a m st ns what"
    );
    println!(
        "# generated by golden/src/sstep.rs from muir's rtl engine on MIT's boot PROM"
    );
    println!(
        "# one row per master clock edge; every value hexadecimal, ns in nanoseconds"
    );
    println!("# warmup {WARMUP:x}");
    for r in &rows {
        println!(
            "{:04x} {:012x} {:x} {:04x} {:012x} {:04x} {:04x} {:08x} {:08x} {:08x} {:08x} {:x} {}",
            r.clk, r.dbgir, r.cycles, r.pc, r.ir, r.flag1, r.flag2, r.ob, r.a, r.m, r.st, r.ns,
            r.what
        );
    }

    let stepped = rows.iter().filter(|r| r.clk & STEP != 0).count();
    eprintln!(
        "sstep: {} rows, {} with STEP up, {} microcycles retired over the script, PC {:o}",
        rows.len(),
        stepped,
        rows.last().map_or(0, |r| r.cycles) - rows[0].cycles,
        e.pc()
    );
}
