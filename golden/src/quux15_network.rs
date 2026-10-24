// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **The network group** (QUUX's Ethernet contract, section 8 R4): QUUX has
//! no Chaosnet interface and no cable, its 140-157 are reserved and never
//! reused, and word 100 `<6>` is never set.  The group's runs hold that, with
//! nothing on a cable:
//!
//!   reserved-reads   every word of 140-157 read, word 100, RESET-DEVICES
//!   reserved-writes  the words revision 15's interface acted on written as
//!                    it acted on them, interrupts enabled, condition 5
//!                    checked after each step, every word of 140-157
//!                    written all ones and read back

use muir::isa::asm::{
    ADD, ALU, JUMP, MD, N, P, POPJ, SETA, SETM, SRC_MD, START_READ, START_WRITE, a_src, filler, m_dest,
    m_src, target,
};
use muir::machine::Word;

use super::Case;
use super::quux15_preset::Preset;

/// This interface's address, muir's default switches
/// (`chaos::Config::default`): a word revision 15's interface took.
const ME: u16 = 0o177001;

/// The register page's virtual address.
const REGISTER_PAGE: Word = 0o35777777400;
/// A memory's 1 (`quux15_preset.rs`'s).
const ONE: u64 = 0o41;
/// The handler a check calls.
const HANDLER: u64 = 0o700;

/// The bits of revision 15's CSR the runs write (`chaos::interface::csr`).
const RIE: u64 = 0o20;
const TIE: u64 = 0o40;
const LOOP_BACK: u64 = 0o2;

/// A functional destination, M 36 as the scratch word.
const fn fd(code: u64) -> u64 {
    code << 19 | 0o36 << 14
}

/// A JUMP on condition `code`.
fn jcond(code: u64) -> u64 {
    JUMP | 1 << 5 | code
}

/// Counts in M `m`.
fn mark(m: u64) -> u64 {
    ALU | ADD | a_src(ONE) | m_src(m) | m_dest(m)
}

/// The register page's word `k`.
const fn reg(k: u64) -> Word {
    REGISTER_PAGE | k
}

/// A run: -RESET's sweep of the TLB taken as done; micro not run.
fn run() -> Preset {
    let mut p = Preset::new();
    p.skip_sweep = true;
    p
}

impl Preset {
    /// M `slot` <- register-page word `k`.
    fn net_read(&mut self, k: u64, slot: u64) -> &mut Self {
        let a = self.k(reg(k));
        self.op(ALU | SETA | a_src(a) | START_READ);
        self.fill(1);
        self.op(ALU | SETM | SRC_MD | m_dest(slot))
    }

    /// Register-page word `k` <- `v`, and two words after.
    fn net_write(&mut self, v: Word, k: u64) -> &mut Self {
        let (wa, aa) = (self.k(v), self.k(reg(k)));
        self.op(ALU | SETA | a_src(wa) | MD);
        self.op(ALU | SETA | a_src(aa) | START_WRITE);
        self.fill(2)
    }
}

/// Interrupts enabled: INTERRUPT-CONTROL `<27>`, destination 2.
fn enable_interrupts(p: &mut Preset) {
    let v = p.k(1 << 35);
    p.op(ALU | SETA | a_src(v) | fd(0o2));
}

/// **140-157 read**, each, and word 100: every one reserved,
/// a constant 0 (QUUX's Ethernet contract, section 8 R4), and RESET-DEVICES
/// changes none of them.
fn reserved_reads() -> Preset {
    let mut p = run();
    for (j, k) in (0o140..=0o157).enumerate() {
        p.net_read(k, 0o20 + j as u64 % 12);
    }
    p.net_read(0o100, 0o32);
    p.net_write(1, 0o104);
    p.net_read(0o140, 0o33).net_read(0o100, 0o32);
    p.stop();
    p
}

/// **140-157 written as revision 15's interface acted on them**, interrupts enabled: the CSR's two enables and Loop Back, a
/// frame's words and START's read, then every word of 140-157 written all
/// ones and read back, word 100 read, and condition 5 checked after each
/// step, calling a handler that counts in M 21.  Revision 15's interface
/// raises `<6>` at the first write, Transmit Done being up from power-on;
/// revision 16 has no interface, so nothing is taken, every word reads 0,
/// `<6>` is never set and the handler is never called.
fn reserved_writes() -> Preset {
    let mut p = run();
    enable_interrupts(&mut p);
    let check = |p: &mut Preset| {
        p.op(jcond(5) | P | target(HANDLER) | N);
        p.fill(1);
    };
    p.net_write(TIE | RIE | LOOP_BACK, 0o140);
    check(&mut p);
    for w in [0o1111, 0o2222, u64::from(ME)] {
        p.net_write(w, 0o141);
    }
    p.net_read(0o145, 0o20);
    check(&mut p);
    p.net_read(0o100, 0o22);
    for k in 0o140..=0o157 {
        p.net_write(0o177777, k);
    }
    check(&mut p);
    for (j, k) in (0o140..=0o157).enumerate() {
        p.net_read(k, 0o23 + j as u64 % 8);
    }
    p.net_read(0o100, 0o33);
    check(&mut p);
    p.stop();
    p.fill_to(HANDLER);
    p.op(mark(0o21));
    p.op(filler().raw() | POPJ);
    p.fill(1);
    p
}

/// **The runs.**
pub fn network(_period: u64) -> Vec<Case> {
    vec![reserved_reads().case("reserved-reads"), reserved_writes().case("reserved-writes")]
}
