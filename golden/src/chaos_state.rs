// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The Chaosnet interface as muir's checkpoint writes it, and what its line
//! offers the receiver before the receiver's own gate: shared by
//! `golden/src/iob.rs` (the CADR's card) and `golden/src/quux15_chaos.rs`
//! (revision 15's interface).
//!
//! **The state is read as `Interface::load` reads it** (`Interface::save`,
//! checkpoint versions 54 to 57): the registers, both buffers, the frames
//! due, the turn timer's frames, and after `polled` the five fields 2b1b0b4
//! appended --- a looped frame's `START^` to come, the busy receiver's
//! decision at a looped frame's destination word, the read register, the
//! reads' count-down inside a frame not taken, and the last frame dropped.
//!
//! **The levels are the cable's facts as if the receiver took the frame**:
//! the bits it would have stored so far and whether the 9401 at LMRBUF 0C07
//! would be non-zero over them. muir keeps them private (`stored_now`,
//! `running_check`) and its `csr()` and `bit_count()` show them only through
//! its gate, so they are made again here from its public face --- the turn
//! timer's frames, `Ether::board_bits` and `board_open_cell`, the frame's own
//! cells --- with muir's constants, and each generator asserts them equal to
//! muir's `csr()` and `bit_count()` wherever muir's receiver takes the frame
//! ([`State::taking`]). Where it does not, they are what the card must gate
//! away, and no witness is wanted.

#![allow(dead_code)]

use muir::chaos::board::Interface;
use muir::chaos::ether::RACT_NS;
use muir::chaos::interface::csr as ccsr;
use muir::chaos::wire::CELL_NS;
use muir::clock::TimeBase;

/// The interface's state, field by field as `Interface::save` writes it.
#[derive(Clone, Debug, PartialEq)]
pub struct State {
    pub csr: u16,
    pub tdone: bool,
    pub tabort: bool,
    pub rdone: bool,
    pub crc: bool,
    pub lost: u8,
    pub xmit: Vec<u16>,
    /// The incoming buffer whole, its 256 words in the order the frame in it
    /// is read, or empty while never written.
    pub rcv: Vec<u16>,
    pub rcv_at: u64,
    pub bits: u64,
    pub tdone_at: Option<u64>,
    /// Frames due to land: when, and their bits.
    pub incoming: Vec<(u64, u64)>,
    /// The turn timer's frames: first edge, source, and the instant the
    /// line goes idle after it.
    pub frames: Vec<(u64, u16, u64)>,
    /// The frame a START made ready, as `Turn::save` writes it.
    pub ready: Option<Vec<u16>>,
    pub looped_start: Option<(u64, u64)>,
    pub looped_busy: Option<(u64, u16)>,
    /// The read register, the two 74164s at LMRBUF 0A07 and 0B07.
    pub rd: u16,
    /// The reads' count-down inside a frame not taken: its first edge,
    /// `RBCT`, and the check of the bits read.
    pub down: Option<(u64, u16, u16)>,
    /// The last frame dropped: when, and how many of its bits stayed.
    pub dropped: Option<(u64, u64)>,
}

pub fn state(i: &Interface) -> State {
    let mut w = muir::checkpoint::Writer::new();
    i.save(&mut w);
    let bytes = w.finish();
    let mut r = muir::checkpoint::Reader::new(&bytes);
    let parse = |r: &mut muir::checkpoint::Reader| -> std::io::Result<State> {
        r.u16()?;
        let csr = r.u16()?;
        let tdone = r.bool()?;
        let tabort = r.bool()?;
        let rdone = r.bool()?;
        let crc = r.bool()?;
        let lost = r.u8()?;
        let xmit = r.u16s()?;
        let rcv = r.u16s()?;
        let rcv_at = r.u64()?;
        let bits = r.u64()?;
        let tdone_at = r.opt(muir::checkpoint::Reader::u64)?;
        let mut incoming = Vec::new();
        for _ in 0..r.u64()? {
            let at = r.u64()?;
            r.u16s()?;
            r.u16()?;
            r.u16()?;
            r.bool()?;
            incoming.push((at, r.u64()?));
        }
        // `Turn::save`: powered at, counts taken, `Q`, the low byte.
        r.u64()?;
        r.u64()?;
        r.bool()?;
        r.u8()?;
        let mut frames = Vec::new();
        for _ in 0..r.u64()? {
            let s = r.u64()?;
            let source = r.u16()?;
            frames.push((s, source, r.u64()?));
        }
        let ready = if r.bool()? {
            r.u64()?;
            Some(r.u16s()?)
        } else {
            None
        };
        r.u64()?; // polled
        let looped_start = r.opt(|r: &mut muir::checkpoint::Reader| Ok((r.u64()?, r.u64()?)))?;
        let looped_busy = r.opt(|r: &mut muir::checkpoint::Reader| Ok((r.u64()?, r.u16()?)))?;
        let rd = r.u16()?;
        let down = r.opt(|r: &mut muir::checkpoint::Reader| Ok((r.u64()?, r.u16()?, r.u16()?)))?;
        let dropped = r.opt(|r: &mut muir::checkpoint::Reader| {
            let at = r.u64()?;
            r.opt(muir::checkpoint::Reader::u16)?;
            r.opt(muir::checkpoint::Reader::u64)?;
            Ok((at, r.u64()?))
        })?;
        Ok(State {
            csr,
            tdone,
            tabort,
            rdone,
            crc,
            lost,
            xmit,
            rcv,
            rcv_at,
            bits,
            tdone_at,
            incoming,
            frames,
            ready,
            looped_start,
            looped_busy,
            rd,
            down,
            dropped,
        })
    };
    let s = parse(&mut r).expect("the Chaosnet interface's checkpoint, as Interface::load reads it");
    r.done().expect("the Chaosnet interface's checkpoint, every field of it read");
    s
}

/// The receive check register carried over one bit as it comes off the
/// line: division by `x^16 + x^14 + x + 1`, muir's `check_reverse_bit`.
pub fn check_reverse_bit(check: u16, bit: bool) -> u16 {
    let fb = bit ^ (check >> 15 != 0);
    let next = check << 1;
    if fb { next ^ (1 | 1 << 1 | 1 << 14) } else { next }
}

/// The 9401 over `bits`, from a cleared register.
pub fn running_check(bits: &[bool]) -> u16 {
    bits.iter().fold(0, |c, &b| check_reverse_bit(c, b))
}

impl State {
    pub fn loop_back(&self) -> bool {
        self.csr & ccsr::LOOP_BACK != 0
    }

    /// The frame on the line at `t`, as muir's `frame_now` finds it: the
    /// last to start of those whose first edge is past and whose line is
    /// not yet idle. Its first edge and its idle.
    pub fn frame_now(&self, t: u64) -> Option<(u64, u64)> {
        self.frames.iter().rev().find(|&&(s, _, idle)| s <= t && t < idle).map(|&(s, _, idle)| (s, idle))
    }

    /// Whether muir's receiver takes the frame on the line at `t`
    /// (`Interface::taking`): there is one, and it is not refused --- off
    /// the cable as the ether has it, looped back the frame still waiting
    /// to land. Its `START^` still to come counts as taken.
    pub fn taking(&self, i: &Interface, t: u64) -> bool {
        self.frame_now(t).is_some()
            && if self.loop_back() {
                !self.incoming.is_empty()
            } else {
                !i.ether().is_some_and(|e| e.board_refused())
            }
    }

    /// The bits the receiver would have stored of the frame on the line at
    /// `t` had it taken it (`Interface::stored_now`): off the cable the
    /// decoder's, but the open cell's, and the one before it until
    /// `RICLK^`, [`RACT_NS`] into its cell, has stored it; otherwise a cell
    /// for each `RICLK^` since the frame's first edge, two short of the
    /// cells to its idle.
    pub fn stored(&self, i: &Interface, t: u64, time: TimeBase) -> usize {
        let (cell, late) = (time.ns(CELL_NS), time.ns(RACT_NS));
        if !self.loop_back()
            && let Some((open, sampled)) = i.ether().and_then(|e| e.board_open_cell())
        {
            let n = i.ether().map_or(0, |e| e.board_bits().len());
            return if sampled || t < open + late { n.saturating_sub(1) } else { n };
        }
        self.frame_now(t).map_or(0, |(s, e)| {
            let k = if t >= s + late { (t - s - late) / cell } else { 0 };
            (k as usize).min((((e - s) / cell) as usize).saturating_sub(2))
        })
    }

    /// Whether the receive check register would read non-zero at `t` over
    /// the bits [`State::stored`] counts (`Interface::running_check` not
    /// `Some(0)`): off the cable over the decoder's bits, looped back over
    /// the frame's own `cells`, and with neither --- a frame into the void,
    /// no cable and no Loop Back, or revision 15, which keeps no check
    /// register --- unknown, which muir's `csr()` reads as non-zero once a
    /// bit is in.
    pub fn check_nz(&self, i: &Interface, t: u64, time: TimeBase, cells: Option<&[bool]>) -> bool {
        let k = self.stored(i, t, time);
        if k == 0 {
            return false;
        }
        if time.period != 0 {
            return true;
        }
        if self.loop_back() {
            return match cells {
                Some(c) => running_check(&c[..k.min(c.len())]) != 0,
                None => true,
            };
        }
        match i.ether() {
            Some(e) => e.board_bits().get(..k).is_none_or(|b| running_check(b) != 0),
            None => true,
        }
    }

    /// The reads' count-down inside the frame on the line at `t`, if that
    /// is where the last of them was (`Interface::down_here`).
    pub fn down_here(&self, t: u64) -> Option<(u64, u16, u16)> {
        let (s, _) = self.frame_now(t)?;
        self.down.filter(|&(at, _, _)| at == s && !self.rdone)
    }

    /// The incoming buffer's bit at `RBCT` value `at`, as the read path
    /// gives it (`Interface::ram_bit`): the buffer never written reads as
    /// ones.
    pub fn ram_bit(&self, at: usize) -> bool {
        if self.rcv.is_empty() {
            return true;
        }
        let top = (self.bits as usize + 4095) % 4096 / 16;
        let word = self.rcv[(top + 256 - at / 16) % 256];
        word >> (at % 16) & 1 != 0
    }
}

/// **The frame as the far end hands it to the card**: the buffer muir keeps
/// after the frame went in, in the order it is read, cut to the frame's
/// `ceil(bits / 16)` words. The first word, partial when the bits are not
/// whole words, comes with zeros above its bits; past the 256th the frame's
/// bits are gone from the buffer, so the 257th carries only the bits above a
/// partial first word, which share its place, and every word after it is a
/// stand-in the card must drop.
pub fn handed(rcv: &[u16], bits: u64) -> Vec<u16> {
    assert_eq!(rcv.len(), 256, "a frame went in and the buffer is not whole");
    let stand_in = |k: usize| 0o155000u16 ^ (k as u16).wrapping_mul(0o4321);
    let low = u16::MAX >> ((16 - bits % 16) % 16);
    (0..bits.div_ceil(16) as usize)
        .map(|k| match k {
            0 => rcv[0] & low,
            1..=255 => rcv[k],
            256 => (rcv[0] & !low) | (stand_in(k) & low),
            _ => stand_in(k),
        })
        .collect()
}
