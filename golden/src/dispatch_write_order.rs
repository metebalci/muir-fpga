// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! Writes that land in the microcycle that reads the same memory, and writes
//! whose microcycle is held, out of muir's own `rtl` engine.
//!
//! The programs are muir's `tests/dispatch_write_order.rs`, built here from
//! the same library calls, so the fabric runs what muir's own test runs.
//! That test runs each program on `chip` (MIT's netlist), `rtl` and `micro`
//! under the board's own nanoseconds and compares the end states. This takes
//! `rtl` alone, under the fabric's grid ([`trace::TIMING`]), and writes every
//! microcycle and the end state, which `tb/cadr_dispatch_write_order_tb.cpp`
//! holds the whole machine to.
//!
//! **What the programs hold**, each against muir's rule:
//!
//! - **`-WAIT` fires no write pulse.** `TPWP` is `NOR(latch, -MACHRUNA)` at
//!   CLOCK2 1C10 and `-WAIT` drops `MACHRUN`, so a write pending across a
//!   held generator cycle lands once, when the cycle runs.
//!   `dispatch-held-by-wait-1` to `-3` are this file's own programs, not
//!   muir's: a dispatch write addressed by `MD` that a `-WAIT` holds while
//!   the read lands, so a pulse in a held cycle would write a second word at
//!   the `MD` before the read. `-0` is the same write with no gap, which
//!   nothing holds; its fetch loads VMA under the read in flight, so it also
//!   holds where the bus address takes `VMA<7:0>` from, as
//!   `map-write-into-hang` does. muir's PDL and SPC programs write at a register's
//!   address, where a repeated pulse lands on the same word, so they hold
//!   that the machine gets there and cannot see a repeat.
//! - **`-HANG` runs the hung cycle's write pulse**, and the pending writes
//!   and a dispatch write take their address and data as the pulse ends, at
//!   the cycle's boundary, with `MD` as the bus has left it then.
//!   `map-write-into-hang` and `dispatch-on-md-gap-0` to `-3`.
//! - **The bus cycle takes the VMA and the MD the edge that starts it has
//!   just loaded**, as `Rtl::clock_edge` loads both before
//!   `Rtl::start_bus_cycle`: `map-write-into-hang` and
//!   `dispatch-held-by-wait-0` load VMA there, and
//!   `md-loaded-as-a-write-starts` loads MD.
//! - **A read in the microcycle that writes the same memory gets the NEW
//!   word on the CADR and the OLD word on QUUX**: on the CADR the board's
//!   race settled as muir's netlist model settles it, and on QUUX as QUUX
//!   defines it (`Geometry::old_word_while_written`).  A `POPJ` in a dispatch
//!   write (`popj-0` to `-3`, and `x-popj-*` and QUUX's `q-popj-*`, whose
//!   read finishes inside the microcycle or which wait for it), `MAP(MD)`
//!   after a map write (`map-source-after-write`), and a dispatch on a map
//!   bit after one (`map-dispatch-after-write`).
//! - **QUUX has no hung microcycle**: a microcycle that reads `MD` with a
//!   read in flight waits whole cycles and runs once, whole, so its writes
//!   take their addresses from the word read (`dispatch-on-md-gap-*` and
//!   `map-write-into-hang` on QUUX).
//!
//! **The format**, one program after another:
//!
//! ```text
//! program NAME ROWS          a program and how many microcycles it runs
//! prom ADDR WORD             the boot PROM, every word the program has;
//!                            on QUUX a jump to 0, the PROM being at 36000
//! imem ADDR WORD             on QUUX, the program, in the control store's RAM
//! l2 IDX WORD                the level-2 map before the boot
//! dmem IDX WORD              the dispatch memory before the boot
//! main PHYS WORD             main memory before the boot
//! r COLUMNS                  one microcycle, in `trace.rs`'s columns
//! end mmem W0 .. W31         the M memory at the end
//! end spc W0 .. W31          the micro-stack at the end
//! end spcptr P               its pointer
//! end dmem IDX WORD          each nonzero dispatch word at the end
//! end l1 IDX WORD            each nonzero level-1 entry
//! end l2 IDX WORD            each nonzero level-2 entry: the CADR's 1024, QUUX's 2048
//! end pdl IDX WORD           each nonzero PDL word: the CADR's 1024, QUUX's 16384
//! done
//! ```
//!
//! Every value is hexadecimal. A memory the lists name no entry of is zero
//! everywhere, and the testbench checks every word of it.

mod machine_axis;
mod trace;

use muir::engine::Engine;
use muir::isa::Insn;
use muir::isa::asm::*;

// --- the programs, as muir's test builds them -------------------------------

/// `v` into M memory `r`: zero, then one doubling a bit, with the bit as the
/// carry in.
fn constant(v: u32, r: u64, out: &mut Vec<Insn>) {
    out.push(Insn::new(ALU | SETZ | m_dest(r)));
    for b in (0..32).rev() {
        let c = if (v >> b) & 1 != 0 { CARRY_IN } else { 0 };
        out.push(Insn::new(ALU | M_PLUS_M | c | m_src(r) | a_src(r) | m_dest(r)));
    }
}

fn copy(from: u64, to: u64) -> Insn {
    Insn::new(ALU | SETM | m_src(from) | a_src(3) | m_dest(to))
}

fn halt_here(at: usize) -> Insn {
    Insn::new(JUMP | target(at as u64) | ALWAYS)
}

/// Functional destination 23, `VMA-WRITE-MAP`, also into M 37.
const WRITE_MAP: u64 = (0o23 << 19) | (0o37 << 14);
/// Functional source 11, `MAP(MD)`.
const SRC_MAP: u64 = src(0o11);

/// A program, the state it starts from, and how long it runs.
struct Program {
    name: String,
    prom: Vec<Insn>,
    l2: Vec<(usize, u32)>,
    dmem: Vec<(usize, u32)>,
    main: Vec<(u32, u32)>,
    rows: u64,
    /// `{SPEED1, SPEED0}` of the mode register at the boot, as a console
    /// leaves it; zero, extra slow, unless a program says otherwise.
    speed: u16,
}

fn program(name: &str, p: Vec<Insn>, rows: u64) -> Program {
    let mut p = p;
    p.resize(512, filler());
    Program { name: name.into(), prom: p, l2: vec![], dmem: vec![], main: vec![], rows, speed: 0 }
}

// Q3: a dispatch memory write in the instruction that also pops.
const D: u64 = 0o1200;
const DR: u32 = 1 << 16;
const DP: u32 = 1 << 15;
const DN: u32 = 1 << 14;
const RETURNED: u32 = 0o1111;
const AT_OLD_DPC: u32 = 0o2222;
const AT_NEW_DPC: u32 = 0o3333;
const SUB: usize = 0o400;
const OLD_DPC: u32 = 0o440;
const NEW_DPC: u32 = 0o460;

fn popj_program(name: &str, old: u32, new: u32) -> Program {
    let mut p = vec![filler()];
    constant(old, 1, &mut p);
    constant(new, 2, &mut p);
    constant(RETURNED, 6, &mut p);
    constant(AT_OLD_DPC, 7, &mut p);
    constant(AT_NEW_DPC, 8, &mut p);
    p.push(Insn::new(ALU | SETZ | m_dest(5)));
    p.push(Insn::new(DISPATCH | DMEM_WRITE | a_src(1) | d_addr(D)));
    p.push(filler());
    p.push(filler());
    p.push(Insn::new(JUMP | P | ALWAYS | target(SUB as u64)));
    p.push(filler());
    p.push(copy(6, 5));
    let here = p.len();
    p.push(halt_here(here));
    assert!(p.len() < SUB);
    p.resize(512, filler());
    p[SUB] = Insn::new(DISPATCH | DMEM_WRITE | POPJ | a_src(2) | d_addr(D));
    for (at, from) in [(OLD_DPC as usize, 7), (NEW_DPC as usize, 8)] {
        p[at] = copy(from, 5);
        p[at + 1] = halt_here(at + 1);
    }
    program(name, p, 240)
}

const POPJ_CASES: [(u32, u32); 4] = [
    (DR | OLD_DPC, NEW_DPC),
    (OLD_DPC, DR | NEW_DPC),
    (OLD_DPC, NEW_DPC),
    (DR | DP | OLD_DPC, DR | DN | NEW_DPC),
];

// Q3b: a map write, and the instruction straight after it.
const MAP_MD: u32 = (0o100 << 13) | (3 << 8) | 2;
const OLD_L2: u32 = 0o1234567 & !(1 << 18);
const NEW_L2: u32 = 0o7654321;
const MAP_STORE: u32 = (1 << 25) | NEW_L2;

fn map_write_then(name: &str, then: Vec<Insn>) -> Program {
    map_store_then(name, MAP_STORE, then)
}

/// A level-1 store: entry 15 at the level-1 index `MAP_MD` names.
const MAP_STORE_L1: u32 = (0o15 << 27) | (1 << 26);

/// `map_write_then` with the store word `store`.
fn map_store_then(name: &str, store: u32, then: Vec<Insn>) -> Program {
    let mut p = vec![filler()];
    constant(MAP_MD, 1, &mut p);
    constant(store, 2, &mut p);
    constant(AT_OLD_DPC, 7, &mut p);
    constant(AT_NEW_DPC, 8, &mut p);
    p.push(Insn::new(ALU | SETZ | m_dest(5)));
    p.push(Insn::new(ALU | SETM | m_src(1) | a_src(3) | MD));
    p.push(filler());
    p.push(filler());
    p.push(Insn::new(ALU | SETM | m_src(2) | a_src(3) | WRITE_MAP));
    p.extend(then);
    let here = p.len();
    p.push(halt_here(here));
    assert!(p.len() < OLD_DPC as usize);
    p.resize(512, filler());
    for (at, from) in [(OLD_DPC as usize, 7), (NEW_DPC as usize, 8)] {
        p[at] = copy(from, 5);
        p[at + 1] = halt_here(at + 1);
    }
    let mut prog = program(name, p, 240);
    prog.l2.push((3, OLD_L2));
    prog
}

// Q4: writes pending across a held microcycle.
const VADDR: u32 = (1 << 8) | 5;
const PHYS: u32 = (0o100 << 8) | 5;
const READ_WORD: u32 = (0o100 << 13) | (7 << 8) | 5;
const MD_BEFORE: u32 = MAP_MD;
const HELD_CYCLES: u64 = 400;
const PDL_POINTER: u64 = (0o14 << 19) | (0o37 << 14);
const PDL_TOP: u64 = (0o10 << 19) | (0o37 << 14);
const SPC_PUSH: u64 = (0o15 << 19) | (0o37 << 14);
const E: u64 = 0o1300;
const DISPATCH_WORD: u32 = 0o123456;

fn read_then(name: &str, setup: &[(u32, u64)], then: Vec<Insn>) -> Program {
    read_then_pre(name, 0, setup, then)
}

/// `read_then` with `pre` fillers before the read, which move it against
/// the grid and the NXM timer's oscillator.
fn read_then_pre(name: &str, pre: usize, setup: &[(u32, u64)], then: Vec<Insn>) -> Program {
    let mut p = vec![filler()];
    constant(MD_BEFORE, 1, &mut p);
    constant(VADDR, 12, &mut p);
    constant(0o20, 14, &mut p);
    for &(v, r) in setup {
        constant(v, r, &mut p);
    }
    for _ in 0..pre {
        p.push(filler());
    }
    p.push(Insn::new(ALU | SETM | m_src(1) | a_src(3) | MD));
    p.push(Insn::new(ALU | SETM | m_src(14) | a_src(3) | PDL_POINTER));
    p.push(filler());
    p.push(Insn::new(ALU | SETM | m_src(12) | a_src(3) | START_READ));
    p.extend(then);
    for _ in 0..4 {
        p.push(filler());
    }
    let here = p.len();
    p.push(halt_here(here));
    let mut prog = program(name, p, HELD_CYCLES);
    prog.l2.push((1, (1 << 23) | (1 << 22) | 0o100));
    prog.main.push((PHYS, READ_WORD));
    prog
}

// This file's own: a hung dispatch write that the boundary ending its hang
// reads back, at the two nearest distances the fabric allows.
//
// muir's `rtl` runs a hung cycle's write pulse and then takes the read phase
// again (`Rtl::step_body`, the `pulsed` write before `stall_for`), so the
// boundary that ends the hang reads the word the pulse wrote: a `POPJ` in a
// dispatch write addressed by MD returns through the new word's `DR`, where
// in a cycle that runs it reads the old one (`popj-0` to `-3`).  These run at
// normal speed, fifteen ticks a microcycle and nineteen under `ILONG`, so
// that the read's acknowledgment can be put on any tick of the hung cycle.
// Where the fabric writes the memory is `mw` in `cadr_microcycle.sv`: two
// ticks from any move of MD and two before the boundary.  These are the
// programs that bring a write to each bound --- MD strobed off the bus in
// the cycle's last tick or the one before it, so the write lands a tick
// late, and a hang that ends on the edge after the pulse, so it lands a tick
// early and the boundary reads it two edges on ---
// and `tb/cadr_dispatch_write_order_tb.cpp` fails unless all three were met.
const RET_PC: u32 = 0o500;
/// `{SPEED1, SPEED0}` = normal: 85 ns read taps, nine ticks, fifteen a cycle.
const NORMAL_SPEED: u16 = 2;

fn ilong(i: Insn) -> Insn {
    Insn::new(i.raw() | (1 << 45))
}

/// The read of `read_then` with `pre` fillers before it, which move the
/// request against the memory board's own oscillator; `n` fillers after it,
/// the first `i` of them under `ILONG`, then the hung `DISPATCH | DMEM_WRITE
/// | POPJ` addressed by `MD<2:0>`, under `ILONG` if `long`.  The word written has `DR`, so the `POPJ` returns
/// to `RET_PC` if the boundary reads it and falls through if it reads the old
/// word, zero; M 5 says which (`AT_NEW_DPC` returned, `AT_OLD_DPC` fell).
fn popj_into_hang(name: &str, pre: usize, n: usize, i: usize, long: bool) -> Program {
    let mut p = vec![filler()];
    constant(MD_BEFORE, 1, &mut p);
    constant(VADDR, 12, &mut p);
    constant(AT_OLD_DPC, 7, &mut p);
    constant(AT_NEW_DPC, 8, &mut p);
    constant(DR | 0o1234, 2, &mut p);
    constant(RET_PC, 15, &mut p);
    p.push(Insn::new(ALU | SETM | m_src(15) | a_src(3) | SPC_PUSH));
    p.push(Insn::new(ALU | SETZ | m_dest(5)));
    for _ in 0..pre {
        p.push(filler());
    }
    p.push(Insn::new(ALU | SETM | m_src(1) | a_src(3) | MD));
    p.push(filler());
    p.push(Insn::new(ALU | SETM | m_src(12) | a_src(3) | START_READ));
    for k in 0..n {
        p.push(if k < i { ilong(filler()) } else { filler() });
    }
    let x = Insn::new(DISPATCH | DMEM_WRITE | POPJ | SRC_MD | d_len(3) | a_src(2) | d_addr(E));
    p.push(if long { ilong(x) } else { x });
    p.push(filler());
    p.push(copy(7, 5));
    let here = p.len();
    p.push(halt_here(here));
    assert!(p.len() < RET_PC as usize);
    p.resize(512, filler());
    p[RET_PC as usize] = copy(8, 5);
    p[RET_PC as usize + 1] = halt_here(RET_PC as usize + 1);
    let mut prog = program(name, p, HELD_CYCLES);
    prog.speed = NORMAL_SPEED;
    prog.l2.push((1, (1 << 23) | (1 << 22) | 0o100));
    prog
}

// muir's `hung_popj`, as this project's sessions first built it and muir's
// `tests/dispatch_write_order.rs` took it up: a return address pushed, `MD`
// set to `MD_BEFORE`, `pre` fillers, a read of `VADDR`, `n` fillers (the first
// `i` under `ILONG`), then the `POPJ` in a dispatch write addressed by
// `MD<2:0>` (under `ILONG` if `xl`), at normal speed.  Words 1300 and 1301 go
// to `OLD_DPC` and `NEW_DPC`, and the read brings back 0, so a write that
// takes the word read writes 1300 and the `POPJ` reads what it wrote there.
// On the CADR muir takes the word written in every shape
// (`a_popj_dispatch_write_whose_read_finishes_inside_its_hung_microcycle_takes_the_new_word`).
fn hung_popj(name: &str, pre: usize, n: usize, i: usize, xl: bool) -> Program {
    let mut p = vec![filler()];
    constant(MD_BEFORE, 1, &mut p);
    constant(VADDR, 12, &mut p);
    constant(AT_OLD_DPC, 7, &mut p);
    constant(AT_NEW_DPC, 8, &mut p);
    constant(DR | 0o1234, 2, &mut p);
    constant(RET_PC, 15, &mut p);
    p.push(Insn::new(ALU | SETM | m_src(15) | a_src(3) | SPC_PUSH));
    p.push(Insn::new(ALU | SETZ | m_dest(5)));
    for _ in 0..pre {
        p.push(filler());
    }
    p.push(Insn::new(ALU | SETM | m_src(1) | a_src(3) | MD));
    p.push(filler());
    p.push(Insn::new(ALU | SETM | m_src(12) | a_src(3) | START_READ));
    for k in 0..n {
        p.push(if k < i { ilong(filler()) } else { filler() });
    }
    let x = Insn::new(DISPATCH | DMEM_WRITE | POPJ | SRC_MD | d_len(3) | a_src(2) | d_addr(E));
    p.push(if xl { ilong(x) } else { x });
    p.push(filler());
    p.push(copy(7, 5));
    let here = p.len();
    p.push(halt_here(here));
    assert!(p.len() < RET_PC as usize);
    p.resize(512, filler());
    p[RET_PC as usize] = copy(8, 5);
    p[RET_PC as usize + 1] = halt_here(RET_PC as usize + 1);
    p[NEW_DPC as usize] = copy(8, 5);
    p[NEW_DPC as usize + 1] = halt_here(NEW_DPC as usize + 1);
    p[OLD_DPC as usize] = copy(7, 5);
    p[OLD_DPC as usize + 1] = halt_here(OLD_DPC as usize + 1);
    let mut prog = program(name, p, HELD_CYCLES);
    prog.speed = NORMAL_SPEED;
    prog.l2.push((1, (1 << 23) | (1 << 22) | 0o100));
    prog.dmem.push((E as usize, OLD_DPC));
    prog.dmem.push((E as usize + 1, NEW_DPC));
    prog
}

// This file's own: an asynchronous change that falls exactly on a clock
// edge.  muir's `Rtl` carries the bus to an edge before it takes the edge
// (`after_memack` runs at `now >= at`), so a change on the edge counts as
// before it, which is what MIT's board does too:
//
//   - `-LOADMD` on a boundary: the edge clocks the OLD `MD`, and the
//     microcycle the edge starts reads the NEW one from its first instant;
//   - `MFINISHD`, the acknowledgment plus 30 ns, on a master clock edge:
//     `MBUSY.SYNC` takes `MBUSY` already clear there, and a `-WAIT` on it
//     ends at that edge.
//
// `pre` fillers before the read (the first `il` under `ILONG`), then `n`
// fillers and a `DESTMEM` that waits on `MBUSY.SYNC`: `VMA<-` alone, or
// `VMA-WRITE-MAP<-` and `M13<-MD` after it.  With `nxm` the read goes to a
// page past the end of main memory, so the NXM timer ends it.  The
// parameters are the ones a sweep found the tie at on this grid; each
// program's name says which tie it is.
fn edge_tie(name: &str, speed: u16, pre: usize, n: usize, il: usize, nxm: bool, map: bool) -> Program {
    let mut then = vec![filler(); n];
    if map {
        then.push(Insn::new(ALU | SETM | m_src(2) | a_src(3) | WRITE_MAP));
        then.push(Insn::new(ALU | SETM | SRC_MD | a_src(3) | m_dest(13)));
    } else {
        then.push(Insn::new(ALU | SETM | m_src(12) | a_src(3) | VMA));
    }
    let setup: &[(u32, u64)] = if map { &[(MAP_STORE, 2)] } else { &[] };
    let mut prog = read_then_pre(name, pre, setup, then);
    let first = prog.prom.iter().position(|w| w.raw() == (ALU | SETM | m_src(1) | a_src(3) | MD)).unwrap() - pre;
    for k in 0..il.min(pre) {
        prog.prom[first + k] = ilong(prog.prom[first + k]);
    }
    prog.speed = speed;
    if nxm {
        prog.l2[0] = (1, (1 << 23) | (1 << 22) | 0o20000);
        prog.main.clear();
    }
    prog
}

// This file's own: the processor writing the mode register's speed bits.
// Unibus `0o766012` is physical `0o17773005`, reached here from VMA `0o1005`
// through level-2 entry 2, as MIT's boot PROM reaches it (`promh.text`).
const MODE_VADDR: u32 = 0o1005;
const MODE_PAGE: u32 = (1 << 23) | (1 << 22) | 0o37766;
/// `SPY<1:0>` = `{SPEED1, SPEED0}` = normal.
const MODE_NORMAL: u32 = 2;

/// Writes the speed bits and runs on at the new speed; `pad` fillers between
/// loading MD and starting the write move the write against the generator.
fn speed_written(name: &str, pad: usize) -> Program {
    speed_written_from(name, 0, MODE_NORMAL, pad, None)
}

/// `speed_written` from the speed `from`, writing `word`, with the filler
/// `long` after the write's start under `ILONG` if one is named.
fn speed_written_from(name: &str, from: u16, word: u32, pad: usize, long: Option<usize>) -> Program {
    let mut p = vec![filler()];
    constant(MODE_VADDR, 20, &mut p);
    constant(word, 21, &mut p);
    p.push(Insn::new(ALU | SETM | m_src(21) | a_src(3) | MD));
    for _ in 0..pad {
        p.push(filler());
    }
    p.push(Insn::new(ALU | SETM | m_src(20) | a_src(3) | START_WRITE));
    for k in 0..40 {
        p.push(if Some(k) == long { ilong(filler()) } else { filler() });
    }
    let here = p.len();
    p.push(halt_here(here));
    let mut prog = program(name, p, 200);
    prog.l2.push((2, MODE_PAGE));
    prog.speed = from;
    prog
}

fn programs(which: machine_axis::Which) -> Vec<Program> {
    let mut all = Vec::new();
    for (k, (old, new)) in POPJ_CASES.into_iter().enumerate() {
        all.push(popj_program(&format!("popj-{k}"), old, new));
    }
    all.push(map_write_then(
        "map-source-after-write",
        vec![
            Insn::new(ALU | SETM | SRC_MAP | a_src(3) | m_dest(10)),
            Insn::new(ALU | SETM | SRC_MAP | a_src(3) | m_dest(11)),
        ],
    ));
    // And level 1: `MAP(MD)<28:24>` in the instruction after a level-1 store,
    // this file's own.  Level 2 is still read through the entry level 1
    // held, on both machines.
    all.push(map_store_then(
        "map-level-1-source-after-write",
        MAP_STORE_L1,
        vec![
            Insn::new(ALU | SETM | SRC_MAP | a_src(3) | m_dest(10)),
            Insn::new(ALU | SETM | SRC_MAP | a_src(3) | m_dest(11)),
        ],
    ));
    let mut p = map_write_then(
        "map-dispatch-after-write",
        vec![Insn::new(DISPATCH | (1 << 8) | a_src(3) | m_src(3) | d_addr(E)), filler()],
    );
    p.dmem.push((E as usize, OLD_DPC));
    p.dmem.push((E as usize + 1, NEW_DPC));
    all.push(p);
    for (name, dest) in [("pdl-across-wait", PDL_TOP), ("spc-across-wait", SPC_PUSH)] {
        all.push(read_then(
            name,
            &[(0o765432, 4)],
            vec![
                Insn::new(ALU | SETM | m_src(4) | a_src(3) | dest),
                Insn::new(ALU | SETM | m_src(12) | a_src(3) | VMA),
                Insn::new(ALU | SETM | SRC_MD | a_src(3) | m_dest(13)),
            ],
        ));
    }
    all.push(read_then(
        "map-store-held-by-wait",
        &[(MAP_STORE, 2)],
        vec![
            filler(),
            Insn::new(ALU | SETM | m_src(2) | a_src(3) | WRITE_MAP),
            Insn::new(ALU | SETM | SRC_MD | a_src(3) | m_dest(13)),
        ],
    ));
    all.push(read_then(
        "map-write-into-hang",
        &[(MAP_STORE, 2)],
        vec![
            Insn::new(ALU | SETM | m_src(2) | a_src(3) | WRITE_MAP),
            Insn::new(ALU | SETM | SRC_MD | a_src(3) | m_dest(13)),
        ],
    ));
    for gap in 0..4 {
        let mut then = vec![filler(); gap];
        then.push(Insn::new(DISPATCH | DMEM_WRITE | SRC_MD | d_len(3) | a_src(2) | d_addr(E)));
        all.push(read_then(&format!("dispatch-on-md-gap-{gap}"), &[(DISPATCH_WORD, 2)], then));
    }
    // This file's own: the same dispatch write, with `IR<24>` so that it also
    // asks for the next instruction word. From one filler on, `LCINC AND
    // NEEDFETCH AND MBUSY.SYNC`, `-WAIT`'s third term at VCTL1 3F16, holds it
    // until the read before it has finished --- and `MD` takes the read's
    // word inside that wait, so a write pulse in a held cycle would land at
    // `MD<2:0>` = 2 and the cycle that runs at 5. The fetch it asks for is at
    // `VMA` 0, which the map refuses, so no second cycle runs.
    for gap in 0..4 {
        let mut then = vec![filler(); gap];
        then.push(Insn::new(
            DISPATCH | DMEM_WRITE | SRC_MD | d_len(3) | a_src(2) | d_addr(E) | (1 << 24),
        ));
        all.push(read_then(&format!("dispatch-held-by-wait-{gap}"), &[(DISPATCH_WORD, 2)], then));
    }
    // This file's own as well: `MD` loaded by the instruction at whose edge a
    // prepared write goes out. `Rtl::clock_edge` loads `MD` before
    // `Rtl::start_bus_cycle` takes the word the cycle carries, so the word
    // written is the one this instruction stores. It is read back into M 13.
    let mut p = vec![filler()];
    constant(0o111111, 1, &mut p);
    constant(0o222222, 2, &mut p);
    constant(VADDR, 12, &mut p);
    p.push(Insn::new(ALU | SETM | m_src(1) | a_src(3) | MD));
    p.push(filler());
    p.push(Insn::new(ALU | SETM | m_src(12) | a_src(3) | START_WRITE));
    p.push(Insn::new(ALU | SETM | m_src(2) | a_src(3) | MD));
    for _ in 0..4 {
        p.push(filler());
    }
    p.push(Insn::new(ALU | SETZ | MD));
    p.push(Insn::new(ALU | SETM | m_src(12) | a_src(3) | START_READ));
    p.push(filler());
    p.push(Insn::new(ALU | SETM | SRC_MD | a_src(3) | m_dest(13)));
    for _ in 0..4 {
        p.push(filler());
    }
    let here = p.len();
    p.push(halt_here(here));
    let mut prog = program("md-loaded-as-a-write-starts", p, HELD_CYCLES);
    prog.l2.push((1, (1 << 23) | (1 << 22) | 0o100));
    all.push(prog);
    // Measured on the fabric with `CADR_GAP_MONITOR`, and muir's `rtl`
    // returns through the new word in all three (M 5 = `AT_NEW_DPC`).
    all.push(popj_into_hang("popj-into-hang-late", 1, 4, 0, true));
    all.push(popj_into_hang("popj-into-hang-on-time", 3, 4, 0, true));
    all.push(popj_into_hang("popj-into-hang-on-time-acked", 0, 4, 0, true));
    all.push(popj_into_hang("popj-into-hang-early", 3, 5, 0, false));
    for pad in 0..6 {
        all.push(speed_written(&format!("mode-speed-written-{pad}"), pad));
    }
    // A read acknowledged on the edge that ends a microcycle, at extra slow
    // speed: the next microcycle reads the word.
    all.push(edge_tie("md-acked-on-an-edge", 0, 11, 0, 0, false, false));
    // The same through the NXM timer, at normal speed.
    all.push(edge_tie("md-acked-on-an-edge-nxm", 2, 9, 0, 2, true, false));
    // MFINISHD on a master clock edge while `VMA<-` waits on MBUSY.SYNC.
    all.push(edge_tie("mfinishd-on-an-edge", 0, 2, 1, 0, false, false));
    all.push(edge_tie("mfinishd-on-an-edge-nxm", 2, 4, 1, 4, true, false));
    // And while `VMA-WRITE-MAP<-` waits on it.
    all.push(edge_tie("mfinishd-on-an-edge-write-map", 0, 1, 1, 0, false, true));
    // The NXM timer's first fall on the grant's own edge, which the board
    // does not count: an enable landing exactly on an edge misses it.
    all.push(edge_tie("nxm-fall-on-the-grant-edge", 0, 7, 0, 0, true, false));
    // A mode-register write strobed on SPEEDCLK, from normal speed with an
    // ILONG cycle after the grant (190 + 60 = 250 ns from the grant), and a
    // tick before it, from slow speed (200 + 50).  muir lands both at that
    // SPEEDCLK, so the next generator cycle already runs extra slow.
    all.push(speed_written_from("speed-written-on-speedclk", 2, 0, 0, Some(7)));
    all.push(speed_written_from("speed-written-before-speedclk", 1, 0, 0, Some(7)));
    // muir's shapes of a `POPJ` in a dispatch write whose read finishes
    // inside its hung microcycle, or on the pulse's end: the three the board
    // is measured on (`INSIDE`), the three on this grid
    // (`rtl_on_the_fpga_grid_takes_the_new_word_in_muir_fpgas_hung_popj_programs`),
    // and the five of the 240 whose acknowledgment falls on the hung cycle's
    // pulse end, which place the write two ticks late.
    for (pre, n, i, xl) in [
        (2, 6, 0, false), (2, 5, 3, false), (5, 5, 1, true),
        (2, 5, 2, false), (2, 5, 0, true),
        (2, 4, 0, true), (2, 4, 1, false), (4, 4, 0, true), (4, 4, 1, true), (4, 4, 2, false),
    ] {
        all.push(hung_popj(&format!("x-popj-{pre}-{n}-{i}-{}", xl as u8), pre, n, i, xl));
    }
    // **ON QUUX, THE SAME PROGRAMS AND muir's OWN OF QUUX**: every program
    // above runs on QUUX as well, where a RAM read in its own write cycle
    // gives the old word and a microcycle that reads MD with a read in
    // flight waits whole cycles and runs once (`on_quux_*` in muir's test).
    // And `quux_hung_popj_one_word`'s shapes: the read brings back a word
    // with `MD_BEFORE`'s low three bits, so the dispatch writes and reads
    // one word, which holds `OLD_DPC` with `R` clear; the old word goes
    // there and leaves the stack pointer at 1.
    if which == machine_axis::Which::Quux {
        let low = MD_BEFORE & 7;
        for pre in [0, 2, 4] {
            for n in 3..8 {
                for xl in [false, true] {
                    let mut p = hung_popj(&format!("q-popj-{pre}-{n}-0-{}", xl as u8), pre, n, 0, xl);
                    p.dmem = vec![(E as usize + low as usize, OLD_DPC)];
                    p.main = vec![(PHYS, low)];
                    all.push(p);
                }
            }
        }
    }
    all
}

fn nonzero(tag: &str, words: &[u32]) {
    for (k, &w) in words.iter().enumerate() {
        if w != 0 {
            println!("end {tag} {k:x} {w:x}");
        }
    }
}

fn main() {
    // `--machine quux` runs the programs on QUUX (`machine_axis.rs`), and the
    // testbench reads which machine from the header's `machine:` line.
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let which = machine_axis::take(&mut args);
    let timing = machine_axis::take_timing(which, &mut args);
    if let Some(a) = args.first() {
        eprintln!(
            "dispatch_write_order: unknown argument `{a}`; usage: dispatch_write_order \
             [--machine cadr|quux] [--sync-cycle-ticks K [--sync-ilong-ticks L]]"
        );
        std::process::exit(2);
    }
    let quux = which == machine_axis::Which::Quux;
    println!("{}", trace::COLUMNS);
    println!(
        "# generated by golden/src/dispatch_write_order.rs from muir's rtl engine, machine: {}{}",
        which.name(),
        machine_axis::timing_suffix(which, timing)
    );
    println!("{}", trace::RADIX);

    for p in programs(which) {
        // **ON QUUX THE PROGRAM RUNS OUT OF THE CONTROL STORE'S RAM**, from
        // 0, where every address it names was chosen, and the PROM at 36000
        // (contract Q2) is a jump to it.  So the program is written into the
        // RAM before the boot, as the memories below are, and the PROM is two
        // words; the trap cycle, the jump and the word after it it inhibits
        // are two rows more than the CADR's.
        let stub = [Insn::new(JUMP | target(0) | ALWAYS | N), filler()];
        let (prom, ram, rows) = if quux { (&stub[..], &p.prom[..], p.rows + 2) } else { (&p.prom[..], &[][..], p.rows) };
        let mut m = which.machine(prom);
        for (k, i) in ram.iter().enumerate() {
            m.imem[k] = *i;
        }
        for &(k, w) in &p.l2 {
            m.l2_map[k] = w;
        }
        for &(k, w) in &p.dmem {
            m.dmem[k] = w;
        }
        for &(a, w) in &p.main {
            m.main[a as usize] = w;
        }
        println!("program {} {:x}", p.name, rows);
        // QUUX has no speed bits: its programs run at its one rate.
        if p.speed != 0 && !quux {
            println!("speed {:x}", p.speed);
        }
        for (k, i) in prom.iter().enumerate() {
            println!("prom {k:x} {:x}", i.raw());
        }
        for (k, i) in ram.iter().enumerate() {
            println!("imem {k:x} {:x}", i.raw());
        }
        for &(k, w) in &p.l2 {
            println!("l2 {k:x} {w:x}");
        }
        for &(k, w) in &p.dmem {
            println!("dmem {k:x} {w:x}");
        }
        for &(a, w) in &p.main {
            println!("main {a:x} {w:x}");
        }

        let mut e = trace::engine_on(m, timing);
        e.boot();
        // The speed, as a console leaves the mode register once the boot has
        // let go of it (`Rtl::reset` clears the register).
        if !quux {
            e.machine_mut().mode.write(p.speed);
        }
        let mut t = trace::Trace::new(&e);
        for cycle in 0..rows {
            match t.row(&mut e, cycle) {
                Ok(line) => println!("r {line}"),
                Err(h) => {
                    eprintln!("dispatch_write_order: {} stopped at microcycle {cycle}: {h:?}", p.name);
                    std::process::exit(1);
                }
            }
        }

        let mm = e.machine();
        let words = |v: &[u32]| v.iter().map(|w| format!("{w:x}")).collect::<Vec<_>>().join(" ");
        println!("end mmem {}", words(&mm.mmem));
        let spc: Vec<u32> = mm.spc.iter().map(|&w| w & 0o1777777).collect();
        println!("end spc {}", words(&spc));
        println!("end spcptr {:x}", mm.spcptr);
        let dmem: Vec<u32> = mm.dmem.iter().map(|&w| w & 0o377777).collect();
        nonzero("dmem", &dmem);
        nonzero("l1", &mm.l1_map);
        // The machine's own sizes: the CADR's 1024 each, QUUX's 2048 entries
        // of level 2 and 16K words of PDL.
        let (l2_words, pdl_words) = if quux { (2048, 16384) } else { (1024, 1024) };
        nonzero("l2", &mm.l2_map[..l2_words]);
        nonzero("pdl", &mm.pdl[..pdl_words]);
        println!("done");
        eprintln!(
            "dispatch_write_order: {:<24} {} microcycles, {} ns ({} stalled), PC {:o}, M5 {:o} M13 {:o}",
            p.name,
            rows,
            e.ns(),
            e.stalled_ns(),
            e.pc(),
            mm.mmem[5],
            mm.mmem[13]
        );

    }
}
