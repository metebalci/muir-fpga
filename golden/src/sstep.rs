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
//! 10. Halts again and writes both levels of the map through the debug IR,
//!     reading the map back through `SRCMAP` as `CC-SAVE-MEM-STATUS` does.
//! 11. Steps a `VMA-START-READ` and reads the map while the machine stands
//!     halted after it.
//! 12. Sets normal speed, forces a long, counted instruction into `IR`, and
//!     boots: the trap cycle.
//!
//! **What 10 to 12 hold, and why they are here.**  Three of muir's `rtl`
//! rules that no reference program reaches, each measured by muir against the
//! netlist (`dc2a474` and `229ffe3`):
//!
//! - **A store writing both levels of the map writes level 2 with its top
//!   five address bits zero**, not at the entry level 1 held before the
//!   store (`Machine::write_map`).  MIT's boot PROM writes both levels in
//!   one store only while level 1 is still all zeros, where the two
//!   addresses agree, and microcode 323 never does.  So the script first
//!   gives level 1 a nonzero entry, then writes both levels through it, and
//!   asserts that the old address and the new one hold different words.
//! - **`MEMSTART` is clocked by the master clock**, so a cycle a step
//!   prepared goes out at the next master clock with the cpu clock held, and
//!   `MEMSTART` falls there (`Rtl::start_bus_cycle`).  The map is addressed
//!   by `VMA` while `MEMSTART` is up and by `MD` once it has fallen, so a
//!   `SRCMAP` standing in `IR` reads a different word the moment it falls.
//!   The read is to a page the map refuses, so no bus cycle is made and the
//!   check needs no memory behind it.
//! - **The trap is not `NOPA`**: `ILONG` and `STATBIT` are gated by `-NOPA`,
//!   so the trap cycle after a boot is long, and counted, when `IR` asks.
//!   The length shows at normal speed only, where the 74S151's two taps
//!   differ, so the mode register is written first; the boot clears it, and
//!   the speed synchronizer carries normal speed into the trap cycle.

use muir::clock::TimingModel;
use muir::engine::Engine;
use muir::isa::asm::{
    ALU, BYTE, DPB, MD, SETA, SETM, SETO, SETZ, START_READ, a_dest, a_src, m_dest, m_src, rot,
    src, width,
};
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

/// One row of the trace: the stimulus columns, and what a console reads
/// back after the master clock the row describes.
///
/// `mode` is the mode register's two speed bits, `{SPEED1, SPEED0}`, as they
/// stand over the row's master clock, and `boot` is whether `-BOOT` was
/// pressed and let go before it --- both stimulus, as `clk` is.
struct Row {
    what: &'static str,
    clk: u16,
    dbgir: u64,
    mode: u8,
    boot: bool,
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
    let mode = u8::from(e.machine().mode.speed1) << 1 | u8::from(e.machine().mode.speed0);
    if let Err(h) = e.step() {
        eprintln!("sstep: the machine halted at {what}: {h:?}");
        std::process::exit(1);
    }
    Row {
        what,
        clk,
        dbgir: e.machine().debug_ir,
        mode,
        boot: false,
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

    map_and_memstart(&mut e, &mut rows);
    trap_cycle(&mut e, &mut rows);

    println!(
        "# clk dbgir cycles pc ir flag1 flag2 ob a m st ns mode boot what"
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
            "{:04x} {:012x} {:x} {:04x} {:012x} {:04x} {:04x} {:08x} {:08x} {:08x} {:08x} {:x} {:x} {:x} {}",
            r.clk, r.dbgir, r.cycles, r.pc, r.ir, r.flag1, r.flag2, r.ob, r.a, r.m, r.st, r.ns,
            r.mode, u8::from(r.boot), r.what
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

/// Functional destination 23, `VMA-WRITE-MAP`: `IR<23>` with `IR<20:19>` = 3
/// and `IR<22>` clear, writing `VMA` and, a microcycle later, the map from it
/// at the address `MD` names (`mit/cadr/ir.bits`).  Like the others in
/// `isa::asm` it also lands in M memory 37.
const WRITE_MAP: u64 = (0o23 << 19) | (0o37 << 14);
/// Functional source 11, `MAP[MD]`: `IR<31>`, `IR<29>`, `IR<26>`.
const SRC_MAP: u64 = src(0o11);

/// The M memory word the script fills with ones, and the A memory word it
/// clears, so that a `DPB` of the first over the second is a field of ones
/// and nothing else: the byte masker's `(mask AND rotated M) OR (NOT mask
/// AND A)`, with an M of all ones that no rotation changes.
const M_ONES: u64 = 0o30;
const A_ZERO: u64 = 0o102;

/// A field of ones, `width` bits from bit `pos`, into `dest`.
fn field(pos: u64, bits: u64, dest: u64) -> u64 {
    BYTE | DPB | rot(pos) | width(bits) | a_src(A_ZERO) | m_src(M_ONES) | dest
}

/// `(MAP[MD])` read with no destination: the word a console's
/// `CC-SAVE-MEM-STATUS` reads.  It writes A memory 0o100, as the filler does.
fn read_map() -> u64 {
    ALU | SETM | SRC_MAP | a_dest(0o100)
}

/// CC's whole round for one forced instruction: loaded without executing,
/// executed, and one more noop debug clock "which finishes writes" --- the
/// map is written in the write phase of the microcycle AFTER the store.
fn force(e: &mut Rtl, rows: &mut Vec<Row>, what: &'static str, insn: u64) {
    load_debug_ir(e, insn);
    cc_clock(e, rows, what, CC_NOOP_DEBUG_CLOCK);
    cc_clock(e, rows, what, CC_DEBUG_CLOCK);
    cc_clock(e, rows, what, CC_NOOP_DEBUG_CLOCK);
}

/// Steps 10 and 11 of the header.
fn map_and_memstart(e: &mut Rtl, rows: &mut Vec<Row>) {
    under(e, rows, "halt-for-map", 0, 3);

    // The two constants every field is made of.
    force(e, rows, "m-ones", ALU | SETO | m_dest(M_ONES));
    force(e, rows, "a-zero", ALU | SETZ | a_dest(A_ZERO));

    // MD is the virtual address the map is written at: ones over
    // `MD<23:8>`, so level 1's entry `0o3777` and level 2's `0o37` in its
    // block.
    force(e, rows, "md-address", field(8, 16, MD));
    let md = e.machine().md;
    let l1_index = ((md >> 13) & 0o3777) as usize;
    let l2_low = ((md >> 8) & 0o37) as usize;

    // Level 1 alone: `VMA<26>` up, `VMA<25>` down, and `VMA<31:27>` all
    // ones, so the entry becomes 31.
    force(e, rows, "write-level-1", field(26, 6, WRITE_MAP));
    let old_l1 = e.machine().l1_map[l1_index] as usize;
    force(e, rows, "read-map-level-1", read_map());

    // Both levels: `VMA<26:22>` up, so level 1 takes `VMA<31:27>` = 0 and
    // level 2 takes `VMA<23:0>` = `0o60000000`, access code 3.  Written at
    // level-2 block 0 by muir's rule, and at block `old_l1` had the level-1
    // entry been read through.
    force(e, rows, "write-both-levels", field(22, 5, WRITE_MAP));
    let l2 = &e.machine().l2_map;
    let (new_at, old_at) = (l2_low, (old_l1 << 5) | l2_low);
    if old_l1 == 0 || l2[new_at] == l2[old_at] || e.machine().l1_map[l1_index] != 0 {
        eprintln!(
            "sstep: the both-levels store tests nothing: level 1 was {old_l1}, and level 2 \
             holds {:#x} at {new_at:o} and {:#x} at {old_at:o}",
            l2[new_at], l2[old_at]
        );
        std::process::exit(1);
    }
    force(e, rows, "read-map-both", read_map());

    // **AND THE OLD BLOCK IS READ BACK TOO, BECAUSE THE READ ABOVE CANNOT
    // TELL THE TWO RULES APART ON ITS OWN.**  CC's round runs the store twice
    // --- the debug clock executes it and leaves it in `IR`, and the noop
    // clock after it is nopped for everything but the map's write, which
    // `WMAPD` has already armed --- and the second time level 1 is already 0,
    // so a machine that addressed level 2 through level 1 lands the word in
    // block 0 as well.  What only the board's rule leaves empty is block
    // `old_l1`: so level 1 is pointed back at it, alone, and it is read.
    force(e, rows, "write-level-1-again", field(26, 6, WRITE_MAP));
    force(e, rows, "read-map-old-block", read_map());
    if e.machine().l2_map[old_at] != 0 || e.machine().l1_map[l1_index] as usize != old_l1 {
        eprintln!(
            "sstep: the old block is not empty after the both-levels store: level 2 holds \
             {:#x} at {old_at:o}, so the read back tests nothing",
            e.machine().l2_map[old_at]
        );
        std::process::exit(1);
    }

    // Step 11.  `VMA-START-READ` of zero: level 1's entry 0 is 0 and level
    // 2's word 0 is 0, so the access is refused, `VMAOK` is down and no bus
    // cycle is made --- but `MEMSTART` rises all the same.  The step that
    // runs it loads `(MAP[MD])` from the debug IR behind it, and the
    // console then reads that instruction's word with the machine halted:
    // the map at `VMA`, zero, while `MEMSTART` stands, and at `MD` once the
    // next master clock has taken it down.
    let start_read = ALU | SETA | a_src(A_ZERO) | START_READ;
    load_debug_ir(e, start_read);
    cc_clock(e, rows, "load-start-read", CC_NOOP_DEBUG_CLOCK);
    load_debug_ir(e, read_map());
    under(e, rows, "start-read", CC_DEBUG_CLOCK, 2);
    let at_vma = e.machine().l2_map[0];
    let at_md = e.machine().l2_map[new_at];
    under(e, rows, "halted-after-read", 0, 4);
    if at_vma == at_md || e.machine().vma != 0 {
        eprintln!(
            "sstep: the halted read tests nothing: the map reads {at_vma:#x} at VMA \
             {:#x} and {at_md:#x} at MD",
            e.machine().vma
        );
        std::process::exit(1);
    }
    under(e, rows, "halted-after-read", STEP, 2);
    under(e, rows, "step-down", 0, 2);
}

/// Step 12 of the header.
fn trap_cycle(e: &mut Rtl, rows: &mut Vec<Row>) {
    // `IR<45>` and `IR<46>`, long and counted, on an instruction that is
    // otherwise the filler's.  Loaded under NOP11, so it stands in `IR`
    // without running --- and loaded at extra slow, where `ILONG` changes
    // no cycle's length.  That is not a nicety: `NOP11` is in `-NOPA`, the
    // generator reads `-ILONG` early in its cycle, and a console write
    // reaches the fabric's check a tick before the edge it is sampled at,
    // so a cycle whose `NOP11` falls with a long instruction standing is
    // one the check cannot place.  Holding the speed down until `NOP11` has
    // gone keeps every row's length the rule's and not the check's.
    under(e, rows, "halt-for-boot", 0, 3);
    let long_counted = ALU | SETA | a_src(3) | a_dest(0o100) | 1 << 45 | 1 << 46;
    load_debug_ir(e, long_counted);
    cc_clock(e, rows, "load-long-counted", CC_NOOP_DEBUG_CLOCK);
    let st_before = e.stat();

    // Normal speed, written with the machine halted: the master clock runs
    // on, so the speed synchronizer on OLORD1 takes it up, and the halted
    // cycles grow long under the instruction standing in `IR`.
    e.spy_write(spy::MODE, 1 << 1);
    under(e, rows, "normal-speed", 0, 4);

    // The boot button, pressed and let go: `Engine::boot`, which raises
    // `RUN` and `SRUN` and the trap.  The first microcycle after it is the
    // trap cycle, with the long, counted instruction standing in `IR`.
    e.boot();
    e.spy_write(spy::CLK, RUN);
    let before = e.ns();
    let mut row = tick(e, "boot", RUN, before);
    row.boot = true;
    rows.push(row);
    if e.stat() == st_before {
        eprintln!("sstep: the trap cycle did not count, so the row tests nothing");
        std::process::exit(1);
    }
    under(e, rows, "after-boot", RUN, 6);
}
