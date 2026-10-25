// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! QUUX's checkpoint as muir itself writes it, for a known machine: the
//! file `cadr-checkpoint`'s host check writes from its modeled window is
//! compared with it BYTE FOR BYTE (`build/checkpoint.quux.pass`).
//!
//!     quux_checkpoint FILE
//!
//! **THE MACHINE IS DESCRIBED TWICE, HERE IN muir'S TERMS AND IN
//! `checkpoint_test.c`'s `fill_quux` IN THE FABRIC'S, AND THE FILE IS WHAT
//! SAYS THE TWO AGREE.**  Here every device is driven through the register
//! page, `Machine::bus_write` and `Machine::bus_read` at the machine's
//! clock, as the processor drives it: the devices reset, the interval timers
//! written and turned on, the file device's rings set up and a command
//! answered, block-disk started on a read that runs off the end of its pack,
//! keys pressed and read, the mouse moved, and the Ethernet device's rings
//! set up with Ethernet frames sent, refused, received and dropped through a
//! scripted peer.  There the same history is what the fabric's registers and
//! counters would hold after it, read through a modeled window.  A field
//! written wrong on the C side, crossed with another, taken from the wrong
//! readout word or converted wrongly from the fabric's words to muir's makes
//! the two files differ.
//!
//! The processor's registers and memories are `Machine`'s own fields,
//! written here as the old revisions' generator wrote them; the console's
//! registers and the debug IR go through `Machine::spy_write`, as the
//! console writes them.  **The pipeline's state between microcycles is
//! private to muir**, so it is composed here in `Pipeline::save`'s order with
//! muir's `Writer` --- the machine, the period, the port, then the
//! pipeline's fields --- and the file is then loaded into a fresh pipeline
//! and saved again, which must give the same bytes: muir's own reader and
//! writer are what say the composed fields are the ones it keeps.
//!
//! Every value is `checkpoint_test.c`'s, under the same name, and `poison`
//! is its own, injective in the memory and the address.  A field of the
//! pipeline that the fabric packs into one readout word with others is
//! poisoned here alone, by its own address, and packed there.

use muir::block_disk::{self, BlockDisk};
use muir::checkpoint::Writer;
use muir::disk_image::Disk;
use muir::engine::Engine;
use muir::ethernet_device::{self as eth, Host, Script};
use muir::file_device as fd;
use muir::isa::Insn;
use muir::machine::{Geometry, IntervalTimer, Machine, QUUX_PROM_BASE, Word};
use muir::pipeline::{CACHE_WORDS, Pipeline, PortTiming};
use muir::quux_input::{self as input, KeyboardMouse};
use muir::spy;
use muir::tv::Board;

/// `checkpoint_test.c`'s poison.
fn poison(sel: u64, addr: u64, bits: u32) -> u64 {
    let h = (sel + 1)
        .wrapping_mul(0x9E37_79B9_7F4A_7C15)
        .wrapping_add((addr + 1).wrapping_mul(0xC2B2_AE3D_27D4_EB4F));
    if bits >= 64 { h } else { h & ((1u64 << bits) - 1) }
}

// The readout's selectors and entries the poison is keyed by
// (`cadr_image.h`).
const SEL_IMEM: u64 = 0;
const SEL_PROM: u64 = 1;
const SEL_AMEM: u64 = 2;
const SEL_MMEM: u64 = 3;
const SEL_PDL: u64 = 4;
const SEL_SPC: u64 = 5;
const SEL_DMEM: u64 = 6;
const SEL_REGS: u64 = 10;
const SEL_MACRO: u64 = 13;
const SEL_TAIL: u64 = 14;

// The machine, in the terms `checkpoint_test.c` repeats: every constant
// below is there under the same name.
/// The clock's period, units of 0.5 ns: 10 ns.
const Q_PERIOD: u64 = 20;
const Q_VIDEO_W: usize = 1920;
const Q_VIDEO_H: usize = 1080;
/// Main memory in 64K-word units: 1MW.
const Q_UNITS: usize = 16;
const Q_DISK_BLOCKS: u32 = 8192;
const Q_CYCLES: u64 = 0x12_3456_7890;
/// The snapshot's instant, units of 0.5 ns.
const Q_NS: u64 = 0x98_7654_3210;
const Q_KEYS: u64 = 70;
const Q_KEYS_READ: u64 = 59;
const Q_MOUSE_X: i32 = 0x5a3;
const Q_MOUSE_Y: i32 = 0x2c7;
const Q_BUTTONS: u8 = 5;
const Q_FD_CMD_BASE: u32 = 0x000_1000;
const Q_FD_CMD_LOG2: u32 = 2;
const Q_FD_RESP_BASE: u32 = 0x000_1108;
const Q_FD_RESP_LOG2: u32 = 1;
const Q_MAC: [u8; 6] = [0x02, 0x5a, 0x11, 0x22, 0x33, 0x44];
const Q_IP_ADDRESS: u32 = u32::from_be_bytes([169, 254, 101, 2]);
const Q_IP_NETMASK: u32 = 0xFFFF_FFFC;
const Q_IP_GATEWAY: u32 = u32::from_be_bytes([169, 254, 101, 1]);

/// When the devices were last reset (word 104), which is the video
/// controller's last RESET-DEVICES.
const Q_RESET_AT: u64 = Q_NS - 20_000_001;
/// Timer 0: periodic with its interrupt enable, 6,000 us, turned on at this
/// instant, so that its deadline is 12,000,000 units later.
const Q_T0_PERIOD: u32 = 6000;
const Q_T0_ON: u64 = Q_NS - 11_000_001;
/// Timer 1: one-shot without it, 16,667 us.
const Q_T1_PERIOD: u32 = 16_667;
const Q_T1_ON: u64 = Q_NS - 19_000_003;
/// Timer 2: off with its interrupt enable, a period written.
const Q_T2_PERIOD: u32 = 0x5A_3C7E;
/// The file device's history begins here.
const Q_FD_AT: u64 = Q_NS - 15_000_000;
/// Block-disk: a read of two pages, four-byte, with the done interrupt
/// enabled, from block `Q_BD_DA`, which the second page runs off the end of
/// the pack at its third block: six blocks moved, past the end.
const Q_BD_CMD: u32 = 0x1234_5800;
const Q_BD_CLP: u32 = 0x000A_BCDE;
const Q_BD_PAGE0: u32 = 0x2_0000;
const Q_BD_PAGE1: u32 = 0x3_0000;
const Q_BD_DA: u32 = Q_DISK_BLOCKS - 6;
const Q_BD_START: u64 = Q_NS - 5_000_777;
/// Block-disk's last word read, which is the instant it was last told.
const Q_BD_NOW: u64 = Q_NS - 555;
/// The keyboard and mouse's history begins here.
const Q_INPUT_AT: u64 = Q_NS - 2_000_000;
/// The Ethernet device's: rings of 4 and 8 entries.
const Q_ETH_AT: u64 = Q_NS - 9_000_000;
const Q_ETH_TX_BASE: u32 = 0x000_3000;
const Q_ETH_TX_LOG2: u32 = 2;
const Q_ETH_RX_BASE: u32 = 0x000_2000;
const Q_ETH_RX_LOG2: u32 = 3;
const Q_ETH_FRAME: u32 = 0x000_4000;
const Q_ETH_BUFFERS: u32 = 0x000_5000;
const Q_ETH_TYPE_DROPS: u64 = 6;
const Q_ETH_IPV4_DROPS: u64 = 9;
const Q_ETH_RX_DROPS: u64 = 3;

/// Block-disk's first register, the register page's word 200
/// (`block_disk::REGS`).
const BD: u32 = 0o200;

/// The register page's word `k` on the bus.
fn page(k: u32) -> u32 {
    muir::tlb::REGISTER_PAGE_BUS | k
}

/// QUUX at revision 16 as `quux`'s command line builds it for the resume
/// `build/checkpoint.quux.pass` runs: 1MW of main memory, block-disk with a
/// disk of `Q_DISK_BLOCKS` blocks and none written, the Kria KR260's video
/// controller, and the host's words of `--ethernet-mac`, `--ip-address` and
/// `--ip-gateway`.
fn machine() -> Machine {
    let mut m = Machine::with_geometry(Geometry::QUUX, Q_UNITS);
    let mut bd = BlockDisk::new(block_disk::BLOCK_NS);
    bd.attach(Disk::blank(Q_DISK_BLOCKS));
    m.block_disk = Some(bd);
    m.tv.set_video_size(Q_VIDEO_W, Q_VIDEO_H);
    m.tv.set_board(Board::Video);
    m.ethernet.host =
        Host { mac: Q_MAC, address: Q_IP_ADDRESS, netmask: Q_IP_NETMASK, gateway: Q_IP_GATEWAY };
    m
}

/// The memory timing a Kria KR260's checkpoint declares, muir's own preset
/// for the board, and the resume line's `--memory-timing kria`.
const Q_TIMING: PortTiming = PortTiming::KRIA;

/// The pipeline on it, at the period, that memory timing and the default
/// cache: `--microcycle-ns 10 --memory-timing kria`.
fn pipeline(m: Machine) -> Pipeline {
    let mut p = Pipeline::new(m);
    p.configure(Q_PERIOD, Q_TIMING, CACHE_WORDS);
    p
}

/// A write of the register page's word `k` at `t`.  **The flag that a
/// device wrote main memory is the engine's to take**: the pipeline sweeps
/// its cache and clears it after a register write and at every clock, so a
/// machine between microcycles never holds it, and nor does this one.
fn put(m: &mut Machine, t: u64, k: u32, v: u32) {
    assert!(t >= m.ns, "the history runs forward");
    m.ns = t;
    m.bus_write(page(k), Word::from(v));
    m.dma_written = false;
}

/// A read of it at `t`, the flag taken as after a write.
fn get(m: &mut Machine, t: u64, k: u32) -> u32 {
    assert!(t >= m.ns, "the history runs forward");
    m.ns = t;
    let v = m.bus_read(page(k)) as u32;
    m.dma_written = false;
    v
}

/// An Ethernet frame to the broadcast address of type `ty`, `len` bytes.
fn frame(ty: u16, len: usize) -> Vec<u8> {
    let mut f = vec![0u8; len];
    f[..6].copy_from_slice(&eth::BROADCAST);
    f[6..12].copy_from_slice(&[0x02, 0, 0, 0, 0, 0x02]);
    f[12..14].copy_from_slice(&ty.to_be_bytes());
    for (k, b) in f.iter_mut().enumerate().skip(14) {
        *b = k as u8;
    }
    f
}

/// An ARP frame, which the device's rules take both ways.
fn arp() -> Vec<u8> {
    frame(0x0806, 42)
}

/// The devices' history, at the machine's clock, through the register page.
fn devices(m: &mut Machine) {
    let per_us = m.time_base().per_us();
    assert_eq!(per_us, 2000, "the machine counts 0.5 ns");

    // Every device reset, word 104; the video controller's instant.
    put(m, Q_RESET_AT, 0o104, 1);
    // Black-on-white, word 210.
    put(m, Q_RESET_AT + 1000, 0o210, 0o4);

    // The interval timers (contract Q11), each period written first: timer
    // 0 periodic with its interrupt enable, timer 1 one-shot without it,
    // timer 2 with a period and its interrupt enable and never turned on.
    put(m, Q_RESET_AT + 2000, 0o111, Q_T0_PERIOD);
    put(m, Q_RESET_AT + 3000, 0o113, Q_T1_PERIOD);
    put(m, Q_RESET_AT + 4000, 0o115, Q_T2_PERIOD);
    put(m, Q_RESET_AT + 5000, 0o114, IntervalTimer::INTERRUPT_ENABLE);
    put(m, Q_T1_ON, 0o112, IntervalTimer::ON | IntervalTimer::ONE_SHOT);

    // The file device (contract Q9): its rings set up and enabled with the
    // interrupt enable, one command posted --- an opcode muir lacks, which
    // reads no buffer and touches no host file --- answered and its
    // response consumed, and a response consumer written past the
    // producer, which leaves the index fault standing.
    put(m, Q_FD_AT, fd::CMD_BASE, Q_FD_CMD_BASE);
    put(m, Q_FD_AT + 10, fd::CMD_SIZE, Q_FD_CMD_LOG2);
    put(m, Q_FD_AT + 20, fd::RESP_BASE, Q_FD_RESP_BASE);
    put(m, Q_FD_AT + 30, fd::RESP_SIZE, Q_FD_RESP_LOG2);
    put(m, Q_FD_AT + 40, fd::CONTROL, 0x101);
    m.main[Q_FD_CMD_BASE as usize] = Word::from(0x1234u32 | 0o77 << 16);
    put(m, Q_FD_AT + 50, fd::CMD_PROD, 1);
    assert_eq!(get(m, Q_FD_AT + 1_000_000, fd::RESP_PROD), 1, "the command answered");
    put(m, Q_FD_AT + 1_000_010, fd::RESP_CONS, 1);
    put(m, Q_FD_AT + 1_000_020, fd::RESP_CONS, 5);
    assert_eq!(get(m, Q_FD_AT + 1_000_030, fd::STATUS), 1 | 1 << 3, "the file device's status");

    // Timer 0 turned on.
    put(m, Q_T0_ON, 0o110, IntervalTimer::ON | IntervalTimer::INTERRUPT_ENABLE);
    let t = m.timers.timer;
    assert_eq!(t[0].deadline_ns, Q_T0_ON + Q_T0_PERIOD as u64 * per_us);
    assert_eq!(t[1].deadline_ns, Q_T1_ON + Q_T1_PERIOD as u64 * per_us);
    assert!(!t[2].on && t[2].interrupt_enable && t[2].deadline_ns == u64::MAX);

    // The Ethernet device (QUUX's Ethernet contract): the rings set up and
    // enabled with the interrupt enable.  Five transmits, two refused by
    // their length; Ethernet frames of another type and IPv4 frames too
    // short dropped by the rules; two ARP frames into the two buffers
    // given, three with none and dropped; one taken back and six more
    // given, two more received; and a take past 251, the index fault.
    let script = Script::default();
    m.attach_ethernet_peer(Box::new(script.clone()));
    let e0 = Q_ETH_AT;
    put(m, e0, eth::TX_BASE, Q_ETH_TX_BASE);
    put(m, e0 + 10, eth::TX_SIZE, Q_ETH_TX_LOG2);
    put(m, e0 + 20, eth::RX_BASE, Q_ETH_RX_BASE);
    put(m, e0 + 30, eth::RX_SIZE, Q_ETH_RX_LOG2);
    put(m, e0 + 40, eth::CONTROL, 0x101);
    let f = arp();
    for (k, c) in f.chunks(4).enumerate() {
        let mut w = [0u8; 4];
        w[..c.len()].copy_from_slice(c);
        m.main[Q_ETH_FRAME as usize + k] = Word::from(u32::from_le_bytes(w));
    }
    let tx = |m: &mut Machine, slot: u32, len: u32| {
        let e = (Q_ETH_TX_BASE + 8 * slot) as usize;
        m.main[e] = Word::from(Q_ETH_FRAME);
        m.main[e + 1] = Word::from(len);
    };
    tx(m, 0, f.len() as u32);
    tx(m, 1, 0);
    tx(m, 2, f.len() as u32);
    tx(m, 3, 2000);
    for j in 0..1u32 << Q_ETH_RX_LOG2 {
        let e = (Q_ETH_RX_BASE + 8 * j) as usize;
        m.main[e] = Word::from(Q_ETH_BUFFERS + 0x200 * j);
        m.main[e + 1] = Word::from(eth::MAX_FRAME);
    }
    put(m, e0 + 50, eth::TX_PROD, 3);
    get(m, e0 + 200_000, eth::STATUS);
    put(m, e0 + 200_010, eth::TX_PROD, 5);
    get(m, e0 + 400_000, eth::STATUS);
    put(m, e0 + 400_010, eth::RX_PROD, 2);
    for i in 0..Q_ETH_TYPE_DROPS {
        script.arrive(e0 + 500_000 + 100 * i, frame(0x86DD, 60));
    }
    for i in 0..Q_ETH_IPV4_DROPS {
        script.arrive(e0 + 510_000 + 100 * i, frame(0x0800, 20));
    }
    for i in 0..2 + Q_ETH_RX_DROPS {
        script.arrive(e0 + 520_000 + 100 * i, arp());
    }
    get(m, e0 + 600_000, eth::STATUS);
    put(m, e0 + 600_010, eth::RX_TAKEN, 1);
    put(m, e0 + 600_020, eth::RX_PROD, 7);
    for i in 0..2 {
        script.arrive(e0 + 700_000 + 100 * i, arp());
    }
    get(m, e0 + 800_000, eth::STATUS);
    put(m, e0 + 800_010, eth::RX_TAKEN, 9);
    assert_eq!(script.sent().len(), 3, "three Ethernet frames sent");
    assert_eq!(script.waiting(), 0, "every Ethernet frame arrived");
    let status = get(m, e0 + 800_020, eth::STATUS);
    assert_eq!(
        status,
        1 | 1 << 3 | (Q_ETH_TYPE_DROPS as u32) << 4 | 1 << 8 | (Q_ETH_IPV4_DROPS as u32) << 9
            | (Q_ETH_RX_DROPS as u32) << 16 | 2 << 24,
        "the Ethernet device's status"
    );

    // Block-disk (contract Q13): the command list of two pages, the second
    // its last, and START; it runs off the end of the pack in the second.
    m.main[Q_BD_CLP as usize] = Word::from(Q_BD_PAGE0 | 1);
    m.main[Q_BD_CLP as usize + 1] = Word::from(Q_BD_PAGE1);
    put(m, Q_BD_START - 30, BD + block_disk::COMMAND, Q_BD_CMD);
    put(m, Q_BD_START - 20, BD + block_disk::CLP, Q_BD_CLP);
    put(m, Q_BD_START - 10, BD + block_disk::DA, Q_BD_DA);
    put(m, Q_BD_START, BD + block_disk::START, 0);

    // The keyboard and mouse, through the calls muir's terminal makes and
    // the register page's: the keyboard's enable, seventy key words pressed
    // into sixty-four slots and fifty-nine read, the mouse moved and its
    // buttons pressed, and the mouse's enable.
    put(m, Q_INPUT_AT, input::KBD_STATUS, input::ENABLE);
    for i in 0..Q_KEYS {
        m.quux_input.press(poison(20, i, 24) as u32);
    }
    for i in 0..Q_KEYS_READ {
        assert_eq!(get(m, Q_INPUT_AT + 10 + i, input::KBD_DATA), poison(20, i, 24) as u32);
    }
    m.quux_input.mouse_move(Q_MOUSE_X, Q_MOUSE_Y);
    m.quux_input.mouse_buttons(Q_BUTTONS);
    put(m, Q_INPUT_AT + 1000, input::MOUSE_STATUS, input::ENABLE);

    // A read of a bus address nothing answers: word 101's NXM.
    m.ns = Q_NS - 1000;
    m.bus_read(0o1_0000_0000);
    assert_eq!(m.bus_error, 1, "word 101's NXM");

    // Block-disk's status read, the last thing told it: not active, an
    // error, past the end.
    let st = get(m, Q_BD_NOW, BD + block_disk::STATUS);
    assert_eq!(st & (1 | 1 << 13 | 1 << 17 | 1 << 20), 1 | 1 << 13 | 1 << 17, "block-disk's status");
    m.ns = Q_NS;
    assert!(m.checkpoint_refusal().is_none(), "a checkpoint may be taken");
}

/// The processor's registers and memories, at their widths.
fn processor(m: &mut Machine) {
    for (i, w) in m.prom.iter_mut().enumerate() {
        *w = Insn::extended(poison(SEL_PROM, i as u64, 64));
    }
    // The control store under QUUX's PROM is held zero, as
    // `Machine::write_imem` leaves it.
    for (i, w) in m.imem.iter_mut().enumerate() {
        *w = Insn::extended(if i < QUUX_PROM_BASE as usize { poison(SEL_IMEM, i as u64, 64) } else { 0 });
    }
    for (i, w) in m.amem.iter_mut().enumerate() {
        *w = poison(SEL_AMEM, i as u64, 40);
    }
    for (i, w) in m.mmem.iter_mut().enumerate() {
        *w = poison(SEL_MMEM, i as u64, 40);
    }
    for (i, w) in m.pdl.iter_mut().enumerate() {
        *w = poison(SEL_PDL, i as u64, 40);
    }
    for (i, w) in m.spc.iter_mut().enumerate() {
        *w = poison(SEL_SPC, i as u64, 19) as u32;
    }
    let dmem = m.geometry.dmem_words();
    for (i, w) in m.dmem.iter_mut().take(dmem).enumerate() {
        *w = poison(SEL_DMEM, i as u64, 17) as u32;
    }
    // The register table's entries, by their number in `img_rg15`.
    m.q = poison(SEL_REGS, 0, 40);
    m.vma = poison(SEL_REGS, 1, 40);
    m.md = poison(SEL_REGS, 2, 40);
    m.lc = poison(SEL_REGS, 3, 34) | m.geometry.need_fetch();
    m.pdl_pointer = poison(SEL_REGS, 4, 14) as u16;
    m.pdl_index = poison(SEL_REGS, 5, 14) as u16;
    m.spcptr = poison(SEL_REGS, 6, 5) as u8;
    m.interrupt_control = (poison(SEL_REGS, 7, 4) as u32) << 26;
    m.dispatch_constant = poison(SEL_REGS, 8, 10) as u16;
    m.overflow = true;
    m.vmaok = true;
    m.opc = poison(SEL_REGS, 10, 14) as u16;
    // The fused return (contract H8a): the register, the index, every
    // entry, the base copies and an operand address armed; M 31's word is
    // not the readout's, and a halted core holds none.
    let md = &mut m.macro_dispatch;
    md.register = poison(SEL_REGS, 11, 32) as u32 & !(3 << 29);
    md.index = poison(SEL_REGS, 12, 10) as u16;
    for (i, e) in md.entries.iter_mut().enumerate() {
        *e = poison(SEL_MACRO, i as u64, 18) as u32;
    }
    md.localp = poison(SEL_REGS, 13, 14) as u32;
    md.ap = poison(SEL_REGS, 113, 14) as u32;
    md.operand = Some(muir::machine::Operand { arg: true, delta: poison(SEL_REGS, 14, 6) as u8 });
    md.m31 = None;
    // The memory system's words (A14.9), the directory and the pointer
    // types written on the page, the refused count and the redirect's
    // copies as they stand, and word 225.
    let at = m.ns;
    put(m, at, 0o220, poison(SEL_REGS, 15, 18) as u32 & !3);
    put(m, at, 0o221, 1);
    let types = poison(SEL_REGS, 16, 64);
    put(m, at, 0o222, types as u32);
    put(m, at, 0o223, (types >> 32) as u32);
    m.memory_words.refused = poison(SEL_REGS, 17, 32) as u32;
    m.pdl_copies = muir::tlb::PdlCopies {
        base: poison(SEL_REGS, 18, 32) as u32,
        head: poison(SEL_REGS, 118, 14) as u16,
    };
    m.posted_write_errors = poison(SEL_REGS, 19, 32) as u32;
    m.cycles = Q_CYCLES;

    // The console's registers, as the console writes them: the mode (QUUX's
    // has no speed bits), the clock control with RUN clear, a halted
    // machine's, and the OPC control; and the debug IR's four halves.
    m.spy_write(spy::MODE, poison(SEL_TAIL, 22, 6) as u16 & !3);
    m.spy_write(spy::CLK, poison(SEL_TAIL, 122, 5) as u16 & !1);
    m.spy_write(spy::OPC_CONTROL, poison(SEL_TAIL, 222, 3) as u16);
    let ir = poison(SEL_TAIL, 23, 64);
    for (half, eadr) in [spy::IR_LOW, spy::IR_MED, spy::IR_HIGH, spy::LDDBIRX].into_iter().enumerate() {
        m.spy_write(eadr, (ir >> (16 * half)) as u16);
    }

    // Main memory and the picture, over everything the devices left there.
    for (i, w) in m.main.iter_mut().enumerate() {
        *w = poison(12, i as u64, 40);
    }
    for i in 0..m.tv.buffer_words() {
        m.tv.write_buffer(i, poison(13, i as u64, 32) as u32);
    }
}

/// `Pipeline::save`'s fields after the machine, the period and the port, in
/// its order: the halted pipeline's, each poisoned at its own width.
fn tail(w: &mut Writer) {
    let p = |k: u64, bits: u32| poison(SEL_TAIL, k, bits);
    w.u16(p(0, 14) as u16); // npc
    w.opt(Some(p(1, 14) as u16), Writer::u16); // npc_after
    w.bool(true); // pre_nop_next
    w.bool(false); // nop_next
    w.opt(Some((p(3, 14) as u16, p(4, 40))), |w, (a, v)| {
        w.u16(a);
        w.word(v);
    }); // pdl_pending
    w.opt(Some(p(6, 40)), Writer::word); // md_old
    w.bool(false); // d_wait
    w.bool(true); // d_slot_pending
    w.u64(p(8, 64)); // oa_low
    w.u64(p(9, 64)); // oa_high
    w.bool(false); // next_instr: taken between microcycles
    w.bool(true); // next_instrd
    w.u32(p(11, 32) as u32); // lvmo
    w.bool(true); // wrcyc
    w.opt(Some((p(113, 5) as u8, p(13, 19) as u32)), |w, (s, v)| {
        w.u8(s);
        w.u32(v);
    }); // spc_write
    w.opt(Some((p(15, 40), p(16, 40))), |w, (a, b)| {
        w.word(a);
        w.word(b);
    }); // map_write_d
    let opc: Vec<u16> = (0..8).map(|k| p(0o200 + k, 14) as u16).collect();
    w.u16s(&opc); // opc
    w.bool(false); // x.halted
    w.bool(true); // halted
    w.u64(Q_CYCLES); // committed
    w.u16(p(21, 14) as u16); // npc_prev
}

/// A machine's checkpoint in named sections, each its own bytes as muir
/// writes it, for `--compare` to say which differ.
fn sections(p: &Pipeline) -> Vec<(&'static str, Vec<u8>)> {
    let m = &p.m;
    let bytes = |f: &dyn Fn(&mut Writer)| {
        let mut w = Writer::new();
        w.set_word_bits(40);
        f(&mut w);
        w.finish()
    };
    let words = |v: &[u64]| bytes(&|w| w.words(v));
    let insns = |v: &[Insn]| bytes(&|w| w.u64s(&v.iter().map(|i| i.raw()).collect::<Vec<_>>()));
    let md = &m.macro_dispatch;
    let mut out = vec![
        ("the PROM", insns(&m.prom)),
        ("the control store", insns(&m.imem)),
        ("the console's registers", bytes(&|w| {
            m.mode.save(w);
            m.clock_control.save(w);
            m.opc_control.save(w);
            w.u64(m.debug_ir);
            w.bool(m.prog_reset);
            w.bool(m.prog_boot);
        })),
        ("A memory", words(&m.amem)),
        ("M memory", words(&m.mmem)),
        ("the dispatch memory", bytes(&|w| w.u32s(&m.dmem[..m.geometry.dmem_words()]))),
        ("the PDL buffer", words(&m.pdl)),
        ("the micro stack", bytes(&|w| w.u32s(&m.spc))),
        ("the registers", bytes(&|w| {
            w.u8(m.spcptr);
            w.u16(m.pdl_pointer);
            w.u16(m.pdl_index);
            w.word(m.q);
            w.u16(m.opc);
            w.u64(m.lc);
            w.word(m.vma);
            w.word(m.md);
            w.u32(m.interrupt_control);
            w.u16(m.dispatch_constant);
            w.bool(m.overflow);
            w.bool(m.vmaok);
            w.u16(m.bus_error);
            w.u16(m.interrupt_status);
            w.u64(m.cycles);
            w.u64(m.ns);
            w.bool(m.dma_written);
        })),
        ("the interval timers", bytes(&|w| m.timers.save(w))),
        ("the fused return", bytes(&|w| {
            w.u32(md.register);
            w.u16(md.index);
            w.u32s(&md.entries);
            w.u32(md.localp);
            w.u32(md.ap);
            w.opt(md.operand, |w, o| {
                w.bool(o.arg);
                w.u8(o.delta);
            });
            w.opt(md.m31, Writer::word);
        })),
        ("the real-time clock", bytes(&|w| m.rtc.save(w))),
        ("the file device", bytes(&|w| m.file_device.save(w))),
        ("main memory", words(&m.main)),
        ("the disk controller", bytes(&|w| m.disk.save(w))),
        ("block-disk", bytes(&|w| w.opt(m.block_disk.as_ref(), |w, d| d.save(w)))),
        ("the video controller", bytes(&|w| m.tv.save(w))),
        ("the I/O board", bytes(&|w| m.ioboard.save(w))),
        ("the keyboard and mouse", bytes(&|w| m.quux_input.save(w))),
        ("the memory system's words", bytes(&|w| {
            m.memory_words.save(w);
            w.u32(m.pdl_copies.base);
            w.u16(m.pdl_copies.head);
            w.u32(m.posted_write_errors);
        })),
        ("the Ethernet device", bytes(&|w| m.ethernet.save(w))),
    ];
    // The pipeline's own, after the machine: the period, the port and the
    // fields `tail` composes, as the saved body has them.
    let mut whole = Writer::new();
    p.save(&mut whole);
    let whole = whole.finish();
    let mut machine = Writer::new();
    m.save(&mut machine);
    let at = machine.finish().len();
    out.push(("the pipeline", whole[at..].to_vec()));
    out
}

/// `--compare A B`: each file loaded into a fresh pipeline, and the
/// sections that differ named, with their first differing byte.
fn compare(a: &std::path::Path, b: &std::path::Path) -> bool {
    let load = |path: &std::path::Path| {
        let c = muir::checkpoint::read(path).expect("the checkpoint");
        let mut e = pipeline(machine());
        e.load(&mut c.reader()).expect("muir took the checkpoint");
        e
    };
    let (ea, eb) = (load(a), load(b));
    let body = |e: &Pipeline| {
        let mut w = Writer::new();
        e.save(&mut w);
        w.finish()
    };
    let (ba, bb) = (body(&ea), body(&eb));
    let mut same = ba == bb;
    if !same {
        let at = ba.iter().zip(&bb).position(|(p, q)| p != q).unwrap_or(ba.len().min(bb.len()));
        println!("quux_checkpoint: the two bodies differ from byte {at}, of {} and {}", ba.len(), bb.len());
    }
    for ((name, x), (_, y)) in sections(&ea).iter().zip(sections(&eb).iter()) {
        if x != y {
            same = false;
            let at = x.iter().zip(y).position(|(p, q)| p != q).unwrap_or(x.len().min(y.len()));
            let near = |v: &[u8]| {
                v.iter().skip(at.saturating_sub(4)).take(16).map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" ")
            };
            println!(
                "quux_checkpoint: {name} differ{} at its byte {at} of {} and {}: {} | {}",
                if name.ends_with('s') && !name.ends_with("ss") { "" } else { "s" },
                x.len(),
                y.len(),
                near(x),
                near(y)
            );
        }
    }
    same
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() == 3 && args[0] == "--compare" {
        let same = compare(std::path::Path::new(&args[1]), std::path::Path::new(&args[2]));
        std::process::exit(if same { 0 } else { 1 });
    }
    if args.len() != 1 {
        eprintln!("usage: quux_checkpoint FILE\n       quux_checkpoint --compare A B");
        std::process::exit(2);
    }
    let path = std::path::Path::new(&args[0]);

    let mut m = machine();
    m.period = Q_PERIOD;
    devices(&mut m);
    processor(&mut m);
    let p = pipeline(m);
    assert_eq!(p.m.ns, Q_NS);

    // The body, in `Pipeline::save`'s order: the machine, the period, the
    // port as a fresh one holds it, its cache empty, then the pipeline's.
    let mut w = Writer::new();
    p.m.save(&mut w);
    w.u64(p.period());
    p.port.save(&mut w);
    tail(&mut w);
    let body = w.finish();
    let bits = p.m.geometry.word_bits;
    muir::checkpoint::write(path, "rtl", Q_UNITS, bits, &body).expect("the checkpoint");

    // **muir's own round trip**: the file loaded into a fresh pipeline of
    // the same machine and saved again gives the same body, so every field
    // composed above is one muir's pipeline reads and keeps.
    let c = muir::checkpoint::read(path).expect("the checkpoint, read back");
    let mut e = pipeline(machine());
    e.load(&mut c.reader()).expect("muir took the checkpoint");
    let mut again = Writer::new();
    e.save(&mut again);
    let again = again.finish();
    if again != body {
        let at = again.iter().zip(&body).position(|(a, b)| a != b).unwrap_or(body.len().min(again.len()));
        eprintln!(
            "quux_checkpoint: muir's pipeline loaded the body and saved other bytes, from byte {at} \
             ({} and {} bytes)",
            body.len(),
            again.len()
        );
        std::process::exit(1);
    }
    let n = std::fs::metadata(path).map(|f| f.len()).unwrap_or(0);
    println!(
        "quux_checkpoint: {} bytes of body, {n} bytes of file, loaded and saved back by muir's \
         pipeline identically, at {} microcycles and {} units of 0.5 ns",
        body.len(),
        e.m.cycles,
        e.m.ns
    );
}
