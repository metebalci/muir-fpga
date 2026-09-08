// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for `rtl/cadr_busint_xbus.sv`: the processor's Xbus
//! memory cycle, out of muir's own `busint::Busint`.
//!
//! The cycle, from `cadr1/xspec.text.3` by way of `busint.rs`:
//!
//! 1. the cpu drops `-MEMRQ` with `WRCYC` and the address already up;
//! 2. "the bus interface only looks at it towards the end of the cycle" ---
//!    the priority logic samples `-MEMRQ` at the master clock edge, which is
//!    the microcycle boundary, and grants: `-MEMGRANT` goes low;
//! 3. `-XBUS.RQ` follows `SETUP_NS` --- 80 ns --- after the grant, and the
//!    slave gives or takes the word when it answers;
//! 4. a write is acknowledged at once, a read `XBUS_ACK_NS` --- 60 ns ---
//!    later, which is the 60 ns tap of the TD100 at REQLM 0C09 deskewing the
//!    word into `MD`;
//! 5. `-MEMACK` stays low until the cpu lifts `-MEMRQ`, which it does
//!    `MFINISHD_NS` --- 30 ns --- after the acknowledgement.
//!
//! The responder here is `Responder::Device` and not `Responder::Memory`.
//! That is the target's shape and not a simplification: `MemoryBoard` models
//! a board of 4116s refreshing itself, and on the Arty Z7 main memory is PS
//! DDR3 behind an Xbus bridge, which answers in its own time and refreshes on
//! its own account. A device that answers `device_ns` after `-XBUS.RQ` is
//! exactly what the bridge is.
//!
//! The addresses are real ones, so the fabric's own decode can be driven from
//! the same trace: a main-memory word for a cycle that is answered, and Xbus
//! space with nothing in it for one that is not. Note the reference calls the
//! first `Responder::Device` where the fabric's decode calls it `memory` --- on
//! this board main memory *is* a device that answers in its own time, and
//! `Responder::Memory` would bring the 4116 refresh model of a board nobody is
//! building. The two names are the same behaviour.
//!
//! The NXM timeout is here too, on `Responder::NoXbus` --- "Xbus I/O with
//! nothing at that address: the cycle times out and sets the Xbus NXM bit".
//! The 74LS124 at REQTIM 0A01 has run since power-on and the grant only opens
//! its output, so where the timeout falls depends on the oscillator's phase at
//! the grant and not on the grant alone: `nxm_timeout_at` is the first rise of
//! the gated output plus `TIMEOUT_NS`, which is the sixth.
//!
//! Note the model pre-decides at the grant --- a responder that answers gets
//! its device time and no timer, one that does not gets the timeout --- where
//! the board runs the timer either way and takes whichever comes first. They
//! agree wherever the model is exercised, so `device_ns` here stays well
//! inside the timeout; see the README.

use muir::busint::{self, Busint, Responder};

/// Five nanoseconds, as in the phase generator: one master-clock tick.
const TICK_NS: u64 = 5;

/// A microcycle at normal speed with no ILONG, which is when `mclk_edge`
/// falls --- `rtl.rs` calls it once a microcycle, at the boundary, because
/// "the bus interface only looks at it towards the end of the cycle".
const MICROCYCLE_TICKS: u64 = 29;

const TICKS: u64 = 40_000;

/// How long the device takes to answer, from `-XBUS.RQ`. Varied so the
/// trace covers a device faster than the setup, one slower than a
/// microcycle, and the ordinary case.
fn device_ns(cycle: u64) -> u64 {
    match cycle % 6 {
        0 => 0,   // answers the instant -XBUS.RQ goes out
        1 => 25,
        2 => 60,
        3 => 115, // longer than the 80 ns of setup
        4 => 200, // longer than a microcycle: the machine hangs over an edge
        _ => 355,
    }
}

/// Read or write, which decides whether the acknowledgement is deskewed.
fn writing(cycle: u64) -> bool {
    cycle % 3 == 2
}

/// What is at the address. Every fifth cycle there is nothing, which is the
/// only way to reach the timeout.
fn responder(cycle: u64) -> Responder {
    if cycle % 5 == 4 { Responder::NoXbus } else { Responder::Device }
}

/// How many 64K-word memory boards the machine has, muir's default.
const BOARDS: u32 = 32;

/// Main memory's top with that many boards.
const MEMORY_WORDS: u32 = BOARDS * (1 << 16);

/// Addresses that are answered: spread over main memory, and few enough that
/// a read comes back to a word some earlier write put something in. The ends
/// and the board boundaries are here because a bridge that dropped an address
/// bit would still pass on a huddle of low addresses.
///
/// **The count has to be coprime with the read/write period**, or the two
/// never meet and the integrity half of the check is vacuous while still
/// passing every timing comparison. With fifteen addresses and a write every
/// third cycle, writes land only on the five indices at 2 mod 3 and reads only
/// on the other ten. `main` asserts the coprimality rather than trusting this
/// comment.
const ADDRS: &[u32] = &[
    0,
    1,
    2,
    3,
    0o777,
    65_535,       // the top of board 0
    65_536,       // the bottom of board 1
    65_537,
    131_071,
    1_000_000,
    2_000_000,
    1_048_576,    // 2^20: one address bit alone
    2_031_616,    // the bottom of board 31, the last one fitted
    2_031_617,
    MEMORY_WORDS - 2,
    MEMORY_WORDS - 1,  // the top of main memory
];

/// The address a cycle runs at. One that is answered is main memory; one that
/// is not is Xbus space above the boards fitted, where the decode says NXM.
fn address(cycle: u64) -> u32 {
    if responder(cycle) == Responder::NoXbus {
        // Above the boards fitted and below Xbus I/O space: nothing there.
        MEMORY_WORDS + (cycle as u32 % 4096) * 37
    } else {
        ADDRS[(cycle as usize) % ADDRS.len()]
    }
}

/// The word a write puts there. Deterministic, and not a function of the
/// address alone, so a bridge that wrote the address instead of the data
/// would be caught.
fn wdata(cycle: u64) -> u32 {
    (cycle as u32).wrapping_mul(0x9E37_79B9) ^ 0x5A5A_1234
}

/// When the cpu asks for its next cycle, in ticks after the last one ended.
///
/// Never zero: `-MEMRQ` has to rise between cycles or the interface never
/// sees the first one end, and on the board it does --- `MEMRQ` off the 9S42
/// at VCTL1 1E25 is `MEMSTART AND VMAOK OR MBUSY`, and `MBUSY` clears
/// `MFINISHD_NS` after the acknowledgement, before any new `MEMSTART`. The
/// gaps then put the next request at every offset against the master clock
/// edge, which is the only place the priority logic looks at it.
fn gap_ticks(cycle: u64) -> u64 {
    [1, 2, 3, 7, 13, 29, 31][(cycle % 7) as usize]
}

/// The greatest common divisor, for the coverage assertion below.
fn gcd(a: usize, b: usize) -> usize {
    if b == 0 { a } else { gcd(b, a % b) }
}

fn main() {
    // Writes happen every third cycle and every fifth is unanswered, so the
    // address set has to be coprime with both or reads and writes never meet
    // at an address and the integrity check passes while testing nothing.
    assert_eq!(gcd(ADDRS.len(), 3), 1, "ADDRS.len() shares a factor with the write period");
    assert_eq!(gcd(ADDRS.len(), 5), 1, "ADDRS.len() shares a factor with the unanswered period");

    // One board is enough: nothing here addresses memory boards.
    let mut bi = Busint::new(1);

    let mut cycle: u64 = 0;
    // The responder is fixed for the cycle being run, as the address is.
    let mut resp = responder(0);
    let mut next_request_at: u64 = 10 * TICK_NS;
    let mut memrq = false;
    let mut wrcyc = false;
    let mut phys: u32 = address(0);
    let mut word: u32 = wdata(0);
    let mut release_at: Option<u64> = None;

    println!("# tick n_memrq wrcyc device_ns present phys wdata boards mclk | n_memgrant n_memack n_loadmd timed_out");
    println!("# generated by golden/src/busint_xbus.rs from muir's busint::Busint");

    for tick in 0..TICKS {
        let now = tick * TICK_NS;
        let mclk = tick % MICROCYCLE_TICKS == 0;

        // The cpu lifts -MEMRQ MFINISHD_NS after the acknowledgement, and
        // the interface lifts -XBUS RQ with it. `rtl.rs` does exactly this.
        if let Some(at) = release_at
            && now >= at
        {
            bi.released(at);
            bi.finish();
            release_at = None;
            memrq = false;
            next_request_at = now + gap_ticks(cycle) * TICK_NS;
            cycle += 1;
        }

        // A new cycle. -MEMRQ is a level the cpu holds up until the ack.
        if !memrq && release_at.is_none() && now >= next_request_at {
            wrcyc = writing(cycle);
            bi.device_ns = device_ns(cycle);
            resp = responder(cycle);
            phys = address(cycle);
            word = wdata(cycle);
            // The address and the responder have to say the same thing, or the
            // reference and the fabric's own decode are answering different
            // questions --- and the fabric's decode is `busint::decode`, so
            // ask it. An address one past the boards fitted looks like memory
            // and is not.
            let answered = !matches!(
                busint::decode(phys, MEMORY_WORDS as usize),
                Responder::NoXbus | Responder::NoUnibus
            );
            assert_eq!(
                answered,
                resp != Responder::NoXbus,
                "cycle {cycle}: address {phys} is {:?}, but the cycle is run as {resp:?}",
                busint::decode(phys, MEMORY_WORDS as usize)
            );
            bi.request(wrcyc);
            memrq = true;
        }

        // The master clock edge: the priority logic samples -MEMRQ here.
        if mclk {
            bi.mclk_edge(now, resp);
        }

        // -MEMACK is asynchronous to the clock, so the cpu sees it whenever
        // it looks. Polling every tick is looking as often as it can.
        let mut timed_out = false;
        if let Some(ack) = bi.poll(now, resp) {
            timed_out = ack.timed_out;
            if release_at.is_none() {
                release_at = Some(ack.at + busint::MFINISHD_NS);
            }
        }

        let granted = bi.granted();
        let acked = bi.ack_at().is_some_and(|at| now >= at);
        let loadmd = bi.loadmd_at().is_some_and(|at| now >= at);

        let b = |v: bool| u8::from(v);
        println!(
            "{tick} {} {} {} {} {} {} {} {} {} {} {} {}",
            b(!memrq), // -MEMRQ, active low
            b(wrcyc),
            bi.device_ns,
            // Whether anything is at the address. Part of the stimulus: it is
            // what the bus has on it, not something the interface knows.
            b(resp != Responder::NoXbus),
            phys,
            word,
            BOARDS,
            b(mclk),
            b(!granted),  // -MEMGRANT
            b(!acked),    // -MEMACK
            b(!loadmd),   // -LOADMD
            b(timed_out),
        );
    }

    eprintln!("busint_xbus: {cycle} cycles over {TICKS} ticks");
}
