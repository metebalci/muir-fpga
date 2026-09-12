// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! The reference trace for the I/O board --- MIT's own name for the card,
//! muir's `ioboard::IoBoard` --- driven register by register over the
//! Unibus, in the shape `disk.rs` drives the disk controller.
//!
//! **What the card is.** `src/ioboard.rs` names its sources and this is
//! that file, the keyboard, the mouse, the two clocks and the status
//! register they share: three 74LS164s shifting the keyboard's twenty-four
//! bits in, the 74LS374s and 74LS569s of IOBMSE and IOBMS2 counting the
//! mouse, the 74S163 chain of IOBCLK dividing a microsecond out of the
//! 32 MHz crystal, the two 74393s of CLKTOD counting mains cycles, the
//! four 74LS193s of CLKTIM counting an interval down, and the 74LS175 at
//! IOBCSR 0D27 holding four interrupt enables that the 74LS244 at 0D29
//! reads back beside three ready bits.
//!
//! **Why a scripted program and not a reference program.** Measured with a
//! throwaway probe against muir's `rtl` engine, every microcycle whose
//! `VMA` translates onto this card counted:
//!
//! - **MIT's boot PROM, 600,000 microcycles and 17,466 bus cycles: the card
//!   is never addressed, not once.** Its one Unibus cycle is the diagnostic
//!   block, the mode-register write that turns the PROM off.
//! - **A System 100 band, 2,200,000 microcycles and 141,849 bus cycles:
//!   271 bus cycles on three registers and nothing else.** One read of the
//!   status register at microcycle 1,410,551 --- `uc-cadr.lisp`'s `(LOC 6)`,
//!   five hundred microcycles after the machine leaves the PROM ---
//!   deciding between a warm and a cold boot; then, from 2,087,405, 135
//!   reads of the microsecond counter's low half each followed by one of
//!   its high half, MIT's own order (`tests/cadrio_netlist.rs` names that
//!   first read at 2,087,406, one sampling convention apart); and one write
//!   of the status register, `0o4`, `KBD INT ENABLE`, at 2,168,062. No
//!   mouse register, no keyboard data register, no interval timer, no beep,
//!   no GPIO, and not one interrupt taken --- nothing types, so `KBD READY`
//!   never comes up.
//!
//! So a check driven by either program would test the decode, two reads and
//! one write, which is the control-store-writes-one-constant shape again,
//! and this program is the only reference.
//!
//! **The seam this trace is written at is the Unibus, not `-MEMRQ`.**
//! `cadr_busint_xbus.sv` is already held to `busint::Busint` tick for tick
//! and already drives `-UB MSYN`, `ub_write` and `ub_addr` and takes
//! `-UB SSYN` back; `cadr_spy_registers.sv` is the slave that answers them
//! today. The I/O board is the second slave on that seam and its check
//! belongs there, one module and one testbench, exactly as the disk
//! controller's does at its four registers. Composing it under
//! `cadr_memory_path` is the next slice's business and `busint_xbus.golden`
//! is the trace for that.
//!
//! **What the trace carries.**
//!
//! - `DECNONE` and `DEC`, the whole of `ioboard::answers` over the 18-bit
//!   Unibus space, read and written: a run for each stretch nothing answers
//!   --- there are thirty-two, because the odd address between two answered
//!   words is a stretch of its own --- and one row an address, per
//!   direction, for the thirty-one that do. The card's decode is a DM8136
//!   block select and three sheets of 74LS138s, and is worth checking
//!   exhaustively as `cadr_xbus_decode` is.
//! - `CYC`, one Unibus cycle: `-UB MSYN` up at `msyn`, `-UB SSYN` back at
//!   `ssyn`, `-UB MSYN` down at `off`, with the address, the direction, the
//!   word written and the word read. `ssyn` is **the fabric's grid instant**
//!   and `slip` is how many nanoseconds before it muir's own answer falls;
//!   see the note on the grid below.
//! - `KEY`, `MOVE`, `BTN` and `SER`, the four things that reach the card
//!   from outside the machine: a scan code off the keyboard's pair, the
//!   mouse's motion and switches, and the serial port's ready line.
//! - `INIT`, `-UB INIT`.
//! - `FACE`, a sample with no cycle, so that the free-running clocks and
//!   the mouse's own 125 kHz sampling are checked between cycles and not
//!   only where a read happens to look.
//!
//! **Every row ends with the same face**, sampled after whatever the row
//! did: the status register's flip-flops, the two mouse counters, the
//! switches as the mouse holds them, `CLOCK READY`, the interval last
//! loaded, the interrupt vector the card is asking for, `AUDIO`, and the
//! serial port's ready line. Each is a register or a wire on the card, so
//! none is a column invented for the trace.
//!
//! **The 5 ns grid, and the one place the card is not on it.** Every
//! instant the fabric can act at is a multiple of five nanoseconds. The
//! microsecond clock's edges are at 890 + 1,000k, the keyboard and mouse
//! group answers 1,250 ns after the second edge past `-MSYN`, and the
//! clocks and the GPIO answer 250 ns after `-MSYN` itself: all multiples of
//! five. **The microsecond counter's low half is not**: `busint`'s
//! `IOB_USEC_LOW_NS` is 313 ns past the edge, measured on the netlist, so
//! muir answers at 1,203 + 1,000k and the fabric can only answer at 1,205.
//! `slip` says so on every such row rather than hiding two nanoseconds in a
//! tolerance, and nothing downstream sees it: `-LMACK` is 150 ns and the
//! MD strobe 100 ns past `-UB SSYN`, both multiples of five, so a bus
//! interface counting from the tick it *sees* `-SSYN` lands where muir's
//! does.
//!
//! **The sixty-cycle counter is off the grid too, and it does not matter.**
//! `SIXTY_CYCLE_NS` is 1,000,000,000/60 = 16,666,666, which is 1 mod 5, so
//! the k'th mains edge is on the grid only for k a multiple of five. A
//! fabric that counts nanoseconds by five and subtracts the period ---
//! `disk_unit`'s spindle trick --- increments at the first tick at or after
//! each edge, and the window in which it disagrees with `ns /
//! SIXTY_CYCLE_NS` is `[B, B + (5 - B mod 5))`, which contains no multiple
//! of five at all. So the two agree at every instant the fabric can be
//! looked at, and the program reads the register at fourteen boundaries,
//! alternating between the last grid instant before one --- which must
//! still say `k-1` --- and the first at or after it, which must already say
//! `k`. A fabric that instead reloads a down-counter with 3,333,333 ticks
//! loses a nanosecond a period and is caught by the first of them.
//!
//! **Where a write lands.** muir applies a Unibus write to this card at
//! `-UB SSYN`, not at the card's own write pulse: `busint.rs`'s
//! `Responder::Unibus` arm makes `answered` equal to `ssyn` for every
//! register, where `Responder::Interface` --- the diagnostic block ---
//! lands at `REGISTER_STROBE_NS` past `-MSYN`. On the card the pulses are
//! earlier than that (`-LOAD INTERVAL` is `Y2` of the 74LS138 at CLK60H
//! 0B21, gated by `-WRITE` while `-MSYN` is up). Nothing on the card can
//! see the difference --- the only state a write starts is the interval
//! timer, whose counts are 16 us apart --- but the *instant* is a choice
//! and the fabric must make muir's, or `CLOCK READY` comes up early by up
//! to a microsecond. Written here, not left to be found.
//!
//! **What no trace against this model can reach**, said here rather than
//! given a column:
//!
//! - **The Chaosnet interface's vector, `0o270`.** `interrupt_request`
//!   consults `self.chaos`, which is `None` unless an interface is plugged
//!   in, and plugging one in drags the whole Chaosnet board into this
//!   trace. The priority chain is exercised clock over serial over
//!   keyboard-and-mouse; the Chaosnet's place in it, between the first two,
//!   is `SERIAL_VECTOR`'s doc and the Chaosnet slice's to check.
//! - **The Chaosnet and serial register groups**, `0o764140`-`0o764176`.
//!   `DEC` carries what the decode makes of them, because the decode is one
//!   sheet; no `CYC` goes near them, because the parts behind them are two
//!   other slices. The serial port is reached only through `SER`, which is
//!   its ready line at the card's priority encoder and is a wire this
//!   card has whoever drives it.
//! - **`take_beep` and `AUDIO_QUIET_NS`.** muir's own comment says they are
//!   the far end's arithmetic and not the board's; the card has the
//!   74LS74 at IOBKBD 0C27 and nothing else, so `AUDIO` is the column and
//!   the beep is not.
//! - **A cycle whose master drops `-MSYN` before the card answers.** The
//!   bus interface never does it and muir's model has no state for it.
//! - **`KBD READY` cleared by anything but a read of the low half.** The
//!   74LS74 at IOBKBD 0B30 has `-READ.KBD.LOW` on its clear pin and
//!   nothing else; the program reads the high half with the bit set and
//!   shows it standing, which is the check that a fabric clearing on
//!   either half fails.
//!
//! **The content rule.** Scan codes are injective and between them cover
//! all twenty-four bits; the mouse's motion is varied in both directions on
//! both axes, wraps the twelve-bit counters both ways and leaves them at
//! over two hundred distinct values each; the status register is written
//! with every one of its five writable bits alone and together and with all
//! sixteen bits set; and the interval timer is loaded with ten different
//! intervals including the longest there is. A register whose only exercise
//! writes one constant tests nothing, and the counters and the clocks are
//! where that trap lives on this card.
//!
//! **And the two mouse registers are read while they are moving, not only
//! after.** `NEW` and `OLD` are the same seven bits two clocks running
//! wherever nothing has changed, so a card that puts the wrong one of them
//! on `UBO12`-`UBO15` agrees with muir on every read taken at rest. The
//! program reads the X register in six successive clocks and then the Y
//! register in six more, in the middle of a move --- six of each and not
//! six alternating, because the mouse holds a phase for two of the card's
//! clocks and an alternating burst puts every read of one register on the
//! same parity, which can be the parity where nothing moved. Measured: with
//! the alternating burst the mistake survives; with six in a row it is
//! caught. The switches take the same treatment, each mask read inside the
//! very clock the latch takes it on.

use std::collections::{BTreeMap, BTreeSet};

use muir::busint::{IoBoardTiming, UNIBUS_STROBE_NS};
use muir::ioboard::{
    self, BEEP, CLOCK, CLOCK_VECTOR, CSR, FIRST_USEC_EDGE_NS, GPIO, INTERVAL_TICK_NS, IoBoard,
    KB_CLK_NS, KBD_HIGH, KBD_LOW, KBD_VECTOR, MOUSE_X, MOUSE_Y, SERIAL_VECTOR, SIXTY_CYCLE_NS,
    SERIAL_FIRST, SERIAL_LAST, USEC_HIGH, USEC_LOW, answers, csr, mouse, usec_at,
};
use muir::chaos::board::Interface as ChaosInterface;
use muir::chaos::interface::{self as chaos, csr as ccsr};
use muir::serial;
use muir::terminal::mouse::MOUSE_STEP_NS;

/// The two switch bodies at LMMYNM D10 and D12, as this trace sets them.
/// `chaos::interface::switches` is how they are closed; what the fabric
/// takes is the word they read back, and it is a PORT of the card and not
/// a constant inside it, so a module ignoring it fails here.  Subnet 6,
/// host 0o101: a legal address --- CLAUDE.md records what muir's own
/// default 0o177001 costs, subnet 255 trapping in `RESET-ROUTING-TABLE`
/// --- with both bytes different and neither 0 nor 0o377.
const CHAOS_ADDRESS: u16 = 0o003101;

/// Five nanoseconds, the master clock's period. Every instant the trace
/// hands the fabric is a multiple of this; `slip` says where muir's own
/// is not.
const TICK_NS: u64 = 5;

/// The whole of the Unibus address the bus interface can put out:
/// `cadr_memory_path.sv` makes eighteen bits of it.
const UB_ADDRESS_BITS: u32 = 18;
const UB_ADDRESSES: u32 = 1 << UB_ADDRESS_BITS;

/// What `reg` reads as on a cycle the card's decoder takes nowhere.
const NO_REG: u32 = 0xFFFF_FFFF;

/// How long a master holds `-UB MSYN` up on a cycle nothing answers before
/// giving up. The card's business is that `-UB SSYN` never comes; the
/// number is the trace's, chosen well past the longest answer the card
/// gives (2,250 ns, the keyboard group at the worst phase) so that a card
/// answering late is caught rather than let through.
const UNANSWERED_HOLD_NS: u64 = 6_000;

/// The smallest multiple of [`TICK_NS`] at or after `t`, and the largest
/// strictly before it.
fn grid_at(t: u64) -> u64 {
    t.div_ceil(TICK_NS) * TICK_NS
}
fn grid_before(t: u64) -> u64 {
    (t - 1) / TICK_NS * TICK_NS
}

/// A scan code, injective in `k` and between them covering all
/// twenty-four bits the three 74LS164s shift in. Bit 23 down to bit 0; the
/// keyboard's own encoding is `terminal::keyboard`'s business and none of
/// this card's.
fn scancode(k: u32) -> u32 {
    (k.wrapping_mul(0x0045_D9F3) ^ 0x00A5_5A3C ^ (k << 19)) & 0x00FF_FFFF
}

struct Gen {
    b: IoBoard,
    io: IoBoardTiming,
    now: u64,
    /// The instant the last answered cycle's word crossed: `-UB SSYN`, and
    /// where a write's effect is dated. `now` is a hundred nanoseconds
    /// past it, `-UB MSYN` having come down.
    landed: u64,
    out: Vec<String>,
    line: u64,
    // --- coverage, counted as the program runs ------------------------
    reads: BTreeMap<u32, u64>,
    writes: BTreeMap<u32, u64>,
    unanswered: u64,
    slips: u64,
    phases: BTreeSet<u64>,
    vectors: BTreeMap<u16, u64>,
    x_seen: BTreeSet<u16>,
    y_seen: BTreeSet<u16>,
    codes: BTreeSet<u32>,
    buttons: BTreeSet<u8>,
    csr_seen: BTreeSet<u16>,
    latched_switches: BTreeSet<u16>,
    latched_quadrature: BTreeSet<u16>,
    usec_high: BTreeSet<u16>,
    sixty: BTreeSet<u16>,
    clock_ready_both: [u64; 2],
    audio_both: [u64; 2],
    keys: u64,
    moves: u64,
    inits: u64,
    faces: u64,
    // --- the Chaosnet interface and the serial port
    ccsr_seen: BTreeSet<u16>,
    sstat_seen: BTreeSet<u8>,
    /// The buffers, printed ahead of the rows as the decode is: `(dir, seq,
    /// words)` with dir 0 the receive buffer a `CRX` row lands and 1 the
    /// transmit buffer a `CTX` row hands over.
    bufs: Vec<(u8, u64, Vec<u16>)>,
    ctx_rows: u64,
    crx_rows: u64,
    ctd_rows: u64,
    cbl_rows: u64,
    stk_rows: u64,
    sdn_rows: u64,
    srx_rows: u64,
    sout_rows: u64,
    spl_rows: u64,
    /// Instants of the far end's own that the 5 ns grid cannot reach: the
    /// 2651's baud-rate crystal is 5.0688 MHz and the Chaosnet's turn timer
    /// runs on the I/O board's own 8 MHz, so neither lands on fives.
    far_slips: u64,
    /// Of [`Gen::slips`], the ones at the serial port's group.
    serial_slips: u64,
    /// Every Unibus ADDRESS a cycle was run at, which is not the same set as
    /// [`Gen::reads`]'s keys: those are the REGISTERS `answers` takes them
    /// to, and this card's two new groups have four aliases between them.
    addrs: BTreeSet<u32>,
}

impl Gen {
    fn new() -> Gen {
        Gen {
            b: IoBoard::default(),
            io: IoBoardTiming::default(),
            now: 0,
            landed: 0,
            out: Vec::with_capacity(1 << 12),
            line: 0,
            reads: BTreeMap::new(),
            writes: BTreeMap::new(),
            unanswered: 0,
            slips: 0,
            phases: BTreeSet::new(),
            vectors: BTreeMap::new(),
            x_seen: BTreeSet::new(),
            y_seen: BTreeSet::new(),
            codes: BTreeSet::new(),
            buttons: BTreeSet::new(),
            csr_seen: BTreeSet::new(),
            latched_switches: BTreeSet::new(),
            latched_quadrature: BTreeSet::new(),
            usec_high: BTreeSet::new(),
            sixty: BTreeSet::new(),
            clock_ready_both: [0; 2],
            audio_both: [0; 2],
            keys: 0,
            moves: 0,
            inits: 0,
            faces: 0,
            ccsr_seen: BTreeSet::new(),
            sstat_seen: BTreeSet::new(),
            bufs: Vec::new(),
            ctx_rows: 0,
            crx_rows: 0,
            ctd_rows: 0,
            cbl_rows: 0,
            stk_rows: 0,
            sdn_rows: 0,
            srx_rows: 0,
            sout_rows: 0,
            spl_rows: 0,
            far_slips: 0,
            serial_slips: 0,
            addrs: BTreeSet::new(),
        }
    }

    /// Time passes. Monotonic, and always on the fabric's grid.
    fn at(&mut self, now: u64) {
        assert!(now >= self.now, "time runs backwards: {} to {now}", self.now);
        assert!(now % TICK_NS == 0, "{now} is not on the 5 ns grid");
        self.now = now;
    }

    /// Time passes by `ns`, rounded up to the grid.
    fn wait(&mut self, ns: u64) {
        let t = grid_at(self.now + ns);
        self.at(t);
    }

    /// To the next instant at or after now whose place in the microsecond
    /// clock's period is `phase` nanoseconds. The edges are at 890 modulo
    /// 1,000, so `phase` 890 is an edge and 885 is five nanoseconds short
    /// of one; what the card's answer depends on is exactly this.
    fn at_phase(&mut self, phase: u64) {
        assert!(phase < 1_000 && phase % TICK_NS == 0, "phase {phase} is not on the grid");
        let mut t = self.now - self.now % 1_000 + phase;
        if t < self.now {
            t += 1_000;
        }
        self.at(t);
    }

    fn say(&mut self, s: String) {
        self.out.push(s);
    }

    /// The whole observable face of the card, sampled after an event: the
    /// status register's flip-flops as they stand, the two counters, the
    /// switches the mouse holds, `CLOCK READY`, the interval last loaded,
    /// the vector the card is requesting, `AUDIO`, and the serial port's
    /// ready line.
    fn face(&mut self) -> String {
        let now = self.now;
        self.b.advance(now);
        let c = self.b.csr();
        let x = self.b.mouse_x();
        let y = self.b.mouse_y();
        let held = self.b.mouse_buttons_held();
        let ready = self.b.clock_ready(now);
        let interval = self.b.interval_timer();
        let intr = self.b.interrupt_request(now);
        let audio = self.b.audio();
        let ser = self.b.serial.rx_ready_at(now) || self.b.serial.tx_ready_at(now);
        // The Chaosnet interface's own face: the CSR as `csr()` assembles it,
        // read-only bits and all, and the bit count the receive buffer's
        // pointer makes.  Both are what the software sees; the buffers
        // themselves are compared word for word where they move.
        let ci = self.b.chaos.as_ref().expect("no Chaosnet interface is plugged in");
        let cc = ci.csr();
        let cb = ci.bit_count();
        // The 2651's three registers and the status byte it assembles.
        let sm1 = self.b.serial.mode1();
        let sm2 = self.b.serial.mode2();
        let scmd = self.b.serial.command();
        let sst = self.b.serial.status();

        self.csr_seen.insert(c);
        self.x_seen.insert(x);
        self.y_seen.insert(y);
        self.buttons.insert(held);
        self.clock_ready_both[ready as usize] += 1;
        self.audio_both[audio as usize] += 1;
        if let Some(v) = intr {
            *self.vectors.entry(v).or_default() += 1;
        }
        self.ccsr_seen.insert(cc);
        self.sstat_seen.insert(sst);
        format!(
            "{c:x} {x:x} {y:x} {held:x} {} {interval:x} {:x} {} {} \
             {cc:x} {cb:x} {sm1:x} {sm2:x} {scmd:x} {sst:x}",
            u8::from(ready),
            intr.unwrap_or(0),
            u8::from(audio),
            u8::from(ser)
        )
    }

    /// One row: the tag, its number, the instant the row is *about*, the
    /// row's own fields, and the face sampled where time now stands. For
    /// every row but a cycle those are the same instant; a cycle's row is
    /// about `-UB MSYN` and its face is at `off`, which is a column of it.
    fn row_at(&mut self, tag: &str, ns: u64, head: String) {
        let n = self.line;
        self.line += 1;
        let face = self.face();
        self.say(format!("{tag} {n} {ns}{head} {face}"));
    }

    fn row(&mut self, tag: &str, head: String) {
        let now = self.now;
        self.row_at(tag, now, head);
    }

    /// One Unibus cycle, `-UB MSYN` at the current instant.
    ///
    /// A cycle the decoder answers ends with `-UB SSYN` at the card's own
    /// time and `-UB MSYN` down [`UNIBUS_STROBE_NS`] after it; one it does
    /// not is held for [`UNANSWERED_HOLD_NS`] and given up.
    fn cyc(&mut self, uaddr: u32, write: bool, wdata: u16) -> u16 {
        let msyn = self.now;
        self.phases.insert(msyn % 1_000);
        self.addrs.insert(uaddr);
        let mut rdata = 0u16;
        let (ssyn, slip, off, reg) = match answers(uaddr, write) {
            None => {
                self.unanswered += 1;
                (0, 0, msyn + UNANSWERED_HOLD_NS, NO_REG)
            }
            Some(r) => {
                let exact = self.io.answer(r, write, msyn);
                assert!(exact > msyn, "the card answered at or before -MSYN");
                let ssyn = grid_at(exact);
                let slip = ssyn - exact;
                if slip != 0 {
                    // **TWO REGISTERS ANSWER OFF THE GRID AND NO OTHERS.**  The
                    // microsecond counter's low half takes `IOB_USEC_LOW_NS` =
                    // 313 past its edge, and EVERY address of the serial port's
                    // group answers 750 ns after a half-microsecond clock whose
                    // phase `busint::IOB_HALF_USEC_PHASE_NS` measures at 203 ---
                    // so 953 + 500k, which is 3 modulo 5.  Both are counted
                    // apart, and rounding UP is the same argument in both
                    // places: a register can only be read at a grid instant, so
                    // nothing falls between muir's answer and the tick.
                    self.slips += 1;
                    if (SERIAL_FIRST..=SERIAL_LAST).contains(&r) {
                        self.serial_slips += 1;
                        assert_eq!(slip, 2, "the serial port's answer is not two short of a tick");
                    } else {
                        assert_eq!(
                            r, USEC_LOW,
                            "an answer off the 5 ns grid at a register the module does not expect: {r:o}"
                        );
                    }
                }
                // The counter's low half is the count as it stood at
                // `-MSYN`; everything else is read or written at `-SSYN`.
                let made = if r == USEC_LOW { msyn } else { ssyn };
                self.landed = ssyn;
                self.b.advance(made);
                if write {
                    *self.writes.entry(r).or_default() += 1;
                    self.b.write(uaddr, wdata, made);
                } else {
                    *self.reads.entry(r).or_default() += 1;
                    rdata = self.b.read(uaddr, made);
                    match r {
                        USEC_HIGH => {
                            self.usec_high.insert(rdata);
                        }
                        CLOCK => {
                            self.sixty.insert(rdata);
                        }
                        MOUSE_Y => {
                            self.latched_switches.insert(rdata >> 12);
                        }
                        MOUSE_X => {
                            self.latched_quadrature.insert(rdata >> 12);
                        }
                        _ => {}
                    }
                }
                (ssyn, slip, ssyn + UNIBUS_STROBE_NS, r)
            }
        };
        self.at(off);
        self.row_at(
            "CYC",
            msyn,
            format!(
                " {ssyn} {slip} {off} {uaddr:x} {reg:x} {} {wdata:x} {rdata:x}",
                u8::from(write)
            ),
        );
        rdata
    }

    fn read(&mut self, uaddr: u32) -> u16 {
        self.cyc(uaddr, false, 0)
    }

    fn write(&mut self, uaddr: u32, v: u16) {
        self.cyc(uaddr, true, v);
    }

    /// A word off the keyboard's pair: the three 74LS164s have it and
    /// `KBD READY` is up.
    fn key(&mut self, code: u32) {
        let now = self.now;
        self.b.advance(now);
        self.b.press(code);
        self.codes.insert(code);
        self.keys += 1;
        self.row("KEY", format!(" {code:x}"));
    }

    /// The mouse moves: `dx` counts to the right and `dy` down, stepped out
    /// down the quadrature lines a phase every [`MOUSE_STEP_NS`] and
    /// counted by the card on its own `KB CLK^`.
    fn moved(&mut self, dx: i32, dy: i32) {
        let now = self.now;
        self.b.advance(now);
        self.b.mouse_move(dx, dy);
        self.moves += 1;
        self.row("MOVE", format!(" {dx} {dy}"));
    }

    /// The three switches as the mouse now holds them.
    fn btn(&mut self, mask: u8) {
        let now = self.now;
        self.b.advance(now);
        self.b.mouse_buttons(mask);
        self.row("BTN", format!(" {mask:x}"));
    }

    /// `-UB INIT`.
    fn init(&mut self) {
        let now = self.now;
        self.b.advance(now);
        self.b.unibus_init();
        self.inits += 1;
        self.row("INIT", String::new());
    }

    /// The serial port's ready line at the card's priority encoder, moved
    /// THROUGH THE 2651'S OWN REGISTERS.
    ///
    /// It used to be moved by writing the chip directly, because the chip
    /// was another slice's and `ser_ready` was a port of this card; the chip
    /// is on the card now, so the only way to move that line is the way a
    /// program moves it, and a trace that reached past the registers would
    /// be testing nothing. The row itself stays, and what it says is what
    /// the card's own `SER.IREQ` must then be.
    fn ser(&mut self, on: bool) {
        if on {
            // The pointers first: a read of the command register puts the
            // mode pointer back to register 1 whatever it was.
            self.read(serial::COMMAND);
            // Asynchronous 16X, eight bits, one stop; the internal transmit
            // clock at rate 14, the receiver's left external so that only
            // `-TxRDY` moves; and the transmitter enabled in normal mode.
            // With nothing in the holding register `SR0` is up.
            self.write(serial::MODE, 0o116);
            self.write(serial::MODE, 0o56);
            self.write(serial::COMMAND, u16::from(serial::command::TX_ENABLE));
        } else {
            self.write(serial::COMMAND, 0);
        }
        let now = self.now;
        self.b.advance(now);
        let got = self.b.serial.rx_ready_at(now) || self.b.serial.tx_ready_at(now);
        assert_eq!(got, on, "the serial port's ready line did not move to {on}");
        self.row("SER", format!(" {}", u8::from(on)));
    }

    /// To an instant at least 1,500 ns before the next edge of `KB CLK^`,
    /// so that a change made now is latched at that edge and a read placed
    /// with [`Gen::read_in_clock`] is answered inside the clock that edge
    /// begins.
    fn before_edge(&mut self) {
        let e = (self.now / KB_CLK_NS + 1) * KB_CLK_NS;
        if e - self.now < 2_000 {
            self.at(e + 100);
        }
    }

    /// A read placed so that `-UB SSYN` falls inside the very clock of
    /// `KB CLK^` that the 74LS374 at IOBMSE 0A24 last moved on: `NEW` is
    /// what that edge took and `OLD` is the edge before it, so a card
    /// reading the wrong one of the two is caught here and nowhere else.
    /// The keyboard-and-mouse group answers between 1,250 and 2,250 ns
    /// after `-UB MSYN`, so a request a microsecond before an edge is
    /// answered inside the clock that edge begins.
    fn read_in_clock(&mut self, uaddr: u32) -> u16 {
        let mut edge = (self.now / KB_CLK_NS + 1) * KB_CLK_NS;
        if edge - self.now < 1_000 {
            edge += KB_CLK_NS;
        }
        self.at(edge - 1_000);
        let v = self.read(uaddr);
        assert!(self.now < edge + KB_CLK_NS, "the read ran past the clock it was placed in");
        v
    }

    /// A sample with no cycle: the free-running clocks and the mouse's own
    /// sampling, where nothing on the bus is looking.
    fn look(&mut self) {
        self.faces += 1;
        self.row("FACE", String::new());
    }

    // --- the two far ends, which are Linux's -----------------------------
    //
    // **THE FABRIC HOLDS THE REGISTERS AND NOT THE PROTOCOL.**  The
    // Chaosnet's cable, its turn timer, the frame and the check word are the
    // `cadr-chaosnet` program's, and the 2651's baud-rate generator and its
    // line are `cadr-serial`'s.  What the card has instead is a seam, and
    // what this trace records is the instants the far end acts at --- so
    // every register the software reads is the fabric's own and every
    // instant it depends on is stimulus.  Under Loop Back muir's own
    // interface IS that far end, which is what makes the register face
    // checkable against muir at all rather than against a property.

    /// An instant of the far end's, brought onto the fabric's grid: the
    /// first tick at or after it.  The 2651's crystal is 5.0688 MHz and the
    /// Chaosnet's turn timer counts the I/O board's 8 MHz, so neither lands
    /// on a multiple of five.  Rounding UP is the argument
    /// `IOB_USEC_LOW_NS` already makes on this card: a register can only be
    /// read at a grid instant, so no read falls between muir's instant and
    /// the tick the fabric acts at.
    fn far_at(&mut self, t: u64) {
        let g = grid_at(t);
        if g != t {
            self.far_slips += 1;
        }
        self.at(g);
    }

    /// The transmit buffer the card has handed over since the last such row:
    /// `seq` names the word list printed ahead of the rows.  An assertion and
    /// not a stimulus --- the words came over the bus and the card must give
    /// them back.
    fn ctx(&mut self, words: &[u16]) {
        // The card hands the buffer over a word a tick from the tick after
        // START, and 256 words is 1.28 us, so the assertion waits for the
        // longest one there is rather than for this one.
        self.wait(2_000);
        let seq = self.ctx_rows;
        self.ctx_rows += 1;
        self.bufs.push((1, seq, words.to_vec()));
        self.row("CTX", format!(" {seq} {}", words.len()));
    }

    /// A packet lands in the receive buffer at this instant: `bits` is what
    /// the bit counter is loaded with, `crc` the check word's verdict, and
    /// `seq` names the words.  Stimulus.
    fn crx(&mut self, at: u64, bits: u64, crc: bool, busy: bool, words: &[u16]) {
        self.far_at(at);
        let seq = self.crx_rows;
        self.crx_rows += 1;
        self.bufs.push((0, seq, words.to_vec()));
        self.row(
            "CRX",
            format!(" {seq} {bits:x} {} {} {}", words.len(), u8::from(crc), u8::from(busy)),
        );
    }

    /// Transmit Done off the far end, with or without an abort.  Stimulus.
    fn ctd(&mut self, at: u64, abort: bool) {
        self.far_at(at);
        self.ctd_rows += 1;
        self.row("CTD", format!(" {}", u8::from(abort)));
    }

    /// `-CBLBSY`, the cable's own busy line, which `Interface::csr` reads
    /// out on bit 14 beside the CRC error.  Stimulus, and a level.
    fn cbl(&mut self, at: u64, busy: bool) {
        self.far_at(at);
        self.cbl_rows += 1;
        self.row("CBL", format!(" {}", u8::from(busy)));
    }

    /// The 2651's shift register takes the holding register's character:
    /// the first 16X clock at or after it was loaded and the transmitter
    /// could take it (`Pci::thr_start`).  Stimulus.
    fn stk(&mut self, at: u64) {
        self.far_at(at);
        self.stk_rows += 1;
        self.row("STK", String::new());
    }

    /// The shift register finishes its frame.  Stimulus; what it delivers
    /// is the `SOUT` row at the same instant.
    fn sdn(&mut self, at: u64) {
        self.far_at(at);
        self.sdn_rows += 1;
        self.row("SDN", String::new());
    }

    /// A character is in the receive path at this instant --- the middle of
    /// its stop bit, `Pci::rx_times` --- carrying `data`.  Stimulus.
    fn srx(&mut self, at: u64, data: u8) {
        self.far_at(at);
        self.srx_rows += 1;
        self.row("SRX", format!(" {data:x}"));
    }

    /// A character reaches the far end's cable: the transmitter's, or the
    /// receiver's own in auto echo and remote loop back.  An assertion.
    fn sout(&mut self, at: u64, data: u8) {
        self.far_at(at);
        self.sout_rows += 1;
        self.row("SOUT", format!(" {data:x}"));
    }

    /// Something is on the far end of the RS-232 cable, or is not: `-DSR`,
    /// `-DCD` and `-CTS`.  Stimulus.
    fn spl(&mut self, on: bool) {
        let now = self.now;
        self.b.advance(now);
        if on {
            self.b.serial.cable.plug(now);
        } else {
            self.b.serial.cable.unplug();
        }
        self.spl_rows += 1;
        self.row("SPL", format!(" {}", u8::from(on)));
    }

    /// To an instant at which the 2651's next 16X clock is at least `room`
    /// nanoseconds off.  The shift register takes the holding register's
    /// character at the first such clock (`Pci::thr_start`), and a write's
    /// own bus cycle is about a microsecond long, so without this the `STK`
    /// row would sometimes fall INSIDE the cycle that loaded it and the
    /// trace could not place it.  The clock's instants are the crystal's and
    /// do not move, so stepping finds one.
    fn before_16x(&mut self, room: u64) {
        for _ in 0..16 {
            let now = self.now;
            if self.b.serial.clock_at_or_after(now) >= now + room {
                return;
            }
            self.wait(500);
        }
        panic!("no gap in the 2651's 16X clock");
    }

    /// Whatever the port has put on the cable by now, each as a `SOUT` row
    /// at the instant its last stop bit ended.  `Cable::take` is the far
    /// end taking them, which is what a far end does.
    fn drain_serial(&mut self) {
        let mut got: Vec<(u64, u8)> = Vec::new();
        while let Some(p) = self.b.serial.cable.take() {
            got.push(p);
        }
        got.sort_by_key(|&(t, _)| t);
        for (t, byte) in got {
            self.sout(t, byte);
        }
    }
}

/// When the far end next does something, found on a COPY: `IoBoard::advance`
/// mutates, and `chaos::board::Interface` copies its registers and not its
/// cable, which is exactly what a probe wants.  Coarse to 500 ns and then to
/// the nanosecond, because the predicate is not monotone over a whole run and
/// a bisection would land on the wrong edge.
fn when(b: &IoBoard, from: u64, limit: u64, f: &dyn Fn(&IoBoard) -> bool) -> u64 {
    const STEP: u64 = 500;
    let mut t = from;
    while t <= from + limit {
        let mut c = b.clone();
        c.advance(t);
        if f(&c) {
            let mut u = if t > from + STEP { t - STEP } else { from };
            while u < t {
                let mut c2 = b.clone();
                c2.advance(u);
                if f(&c2) {
                    return u;
                }
                u += 1;
            }
            return t;
        }
        t += STEP;
    }
    panic!("the far end did nothing within {limit} ns of {from}");
}

/// The Chaosnet interface's CSR as the software reads it.
fn cs(b: &IoBoard) -> u16 {
    b.chaos.as_ref().expect("no Chaosnet interface is plugged in").csr()
}

/// The words a packet will give back, read out of a COPY so that the
/// program's own board keeps its packet: what the fabric's receive buffer is
/// to be filled with, and what the reads below must give.
fn read_out(b: &IoBoard, at: u64, n: usize) -> Vec<u16> {
    let mut c = b.clone();
    c.advance(at);
    (0..n).map(|_| c.read(chaos::READ_BUFFER, at)).collect()
}

/// The first instant in `[from, from + limit]` at which a monotone predicate
/// of the 2651's own --- `tx_ready_at`, `rx_ready_at`, both pure --- is true.
fn first_true(from: u64, limit: u64, f: &dyn Fn(u64) -> bool) -> u64 {
    assert!(f(from + limit), "the 2651 did nothing within {limit} ns of {from}");
    let (mut lo, mut hi) = (from, from + limit);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if f(mid) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    lo
}

fn main() {
    assert_eq!(SIXTY_CYCLE_NS, 16_666_666);
    assert_eq!(FIRST_USEC_EDGE_NS, 890);
    assert_eq!(KB_CLK_NS, 8_000);
    assert_eq!(MOUSE_STEP_NS, 2 * KB_CLK_NS);
    assert_eq!(INTERVAL_TICK_NS, 16_000);
    assert_eq!(csr::WRITABLE, 0o217);
    assert_eq!(csr::FLOATING, 0o177400);
    assert_eq!(mouse::COUNT, 0o7777);
    assert_eq!(UNIBUS_STROBE_NS % TICK_NS, 0);
    // The derivation at the top: the mains counter's boundaries lie off the
    // grid but never inside a tick the fabric can be looked at.
    assert_eq!(SIXTY_CYCLE_NS % TICK_NS, 1);

    let mut g = Gen::new();
    // The Chaosnet interface, plugged in with its address switches set and
    // NO CABLE: the cable is `cadr-chaosnet`'s and Loop Back is how this
    // trace makes a frame come back without one.  It is plugged in from
    // power-on so that every row of the run carries its face, which is what
    // says the keyboard, the mouse and the clocks reach none of it.
    g.b.chaos = Some(ChaosInterface::new(CHAOS_ADDRESS, None, 0, false));

    // ------------------------------------------------------------------
    // The decode, over the whole of the Unibus address the interface can
    // put out. Two runs for the space nothing answers, one row an address
    // for the rest, read and written.
    // ------------------------------------------------------------------
    let mut dec: Vec<String> = Vec::new();
    let mut dec_rows = 0u64;
    let mut dec_none_runs = 0u64;
    let mut answering = 0u64;
    let mut run_from: Option<u32> = None;
    for u in 0..UB_ADDRESSES {
        let r = answers(u, false);
        let w = answers(u, true);
        if r.is_none() && w.is_none() {
            run_from.get_or_insert(u);
            continue;
        }
        if let Some(first) = run_from.take() {
            dec.push(format!("DECNONE {first:x} {:x}", u - 1));
            dec_none_runs += 1;
        }
        answering += 1;
        for (write, got) in [(0u8, r), (1u8, w)] {
            dec.push(format!("DEC {u:x} {write} {:x}", got.unwrap_or(NO_REG)));
            dec_rows += 1;
        }
    }
    if let Some(first) = run_from.take() {
        dec.push(format!("DECNONE {first:x} {:x}", UB_ADDRESSES - 1));
        dec_none_runs += 1;
    }
    // `ioboard::register` is `answers` with `write` false, and the module
    // says so; if it ever stops being, this trace's `DEC` rows would be a
    // reference for one of them and not the other.
    for u in 0..UB_ADDRESSES {
        assert_eq!(ioboard::register(u), answers(u, false), "register and answers part at {u:o}");
    }

    // ------------------------------------------------------------------
    // The face at power-on, and every register the keyboard-and-mouse and
    // clock groups name, read once before anything has been written.
    // ------------------------------------------------------------------
    g.at(0);
    g.look();
    g.at_phase(100);
    // The status register with nothing in it: the floating upper byte and
    // `CLOCK READY`, which the 74LS279 at CLKTIM 0D09 reads set from reset
    // because no interval has been loaded.
    let v = g.read(CSR);
    assert_eq!(v, csr::FLOATING | csr::CLOCK_READY, "the status register at power-on");
    // The counter's high half before its low half has ever been read: the
    // latch is what it came up with, and MIT's own note is that the
    // hardware synchronises only if the low half is read first.
    assert_eq!(g.read(USEC_HIGH), 0, "the microsecond latch before any read of the low half");
    for a in [KBD_LOW, KBD_HIGH, MOUSE_Y, MOUSE_X, CSR, USEC_LOW, USEC_HIGH, CLOCK, GPIO] {
        g.read(a);
    }
    // The two slots of the keyboard group with nothing behind them, and the
    // beep, which clicks on a read as it does on a write.
    for a in [0o764114u32, 0o764116, BEEP] {
        let v = g.read(a);
        assert_eq!(v, 0o177777, "nothing drives the lines at {a:o}");
    }
    // `A3` is not decoded in the clock group: `76413x` is `76412x`.
    for a in [0o764130u32, 0o764132, 0o764134, 0o764136] {
        g.read(a);
    }
    // Cycles the card does not answer: below the block, above it, an odd
    // address inside it, and the two writes the clock group refuses.
    for (a, w) in [
        (0o764000u32, false),
        (0o764076, false),
        (0o764076, true),
        (0o764200, false),
        (0o764101, false),
        (0o763776, false),
        (USEC_LOW, true),
        (USEC_HIGH, true),
        (0o764130, true),
    ] {
        g.cyc(a, w, 0x5A5A);
    }

    // ------------------------------------------------------------------
    // The keyboard. The bit microcode 323 tests at `(LOC 6)`, set by a
    // word off the pair and cleared by a read of the LOW half alone.
    // ------------------------------------------------------------------
    g.wait(3_000);
    g.key(scancode(1));
    let v = g.read(CSR);
    assert_eq!(v & csr::KBD_READY, csr::KBD_READY, "a press did not set KBD READY");
    // The high half first, as the Unibus channel reads it
    // (`uc-interrupt.lisp`, "needs to read the high-order word first"), and
    // the bit stands: the 74LS74 at IOBKBD 0B30 clears on `-READ.KBD.LOW`
    // and on nothing else.
    let hi = g.read(KBD_HIGH);
    assert_eq!(hi, csr::FLOATING | ((scancode(1) >> 16) as u16 & 0xff));
    let v = g.read(CSR);
    assert_eq!(v & csr::KBD_READY, csr::KBD_READY, "reading the high half cleared KBD READY");
    let lo = g.read(KBD_LOW);
    assert_eq!(lo, scancode(1) as u16);
    let v = g.read(CSR);
    assert_eq!(v & csr::KBD_READY, 0, "reading the low half did not clear KBD READY");
    // The high half after the low: the word stands until it is replaced.
    assert_eq!(g.read(KBD_HIGH), csr::FLOATING | ((scancode(1) >> 16) as u16 & 0xff));
    // A word landing on one not yet read replaces it, as the shift
    // registers put the next word in over the last.
    g.wait(1_000);
    g.key(scancode(2));
    g.wait(500);
    g.key(scancode(3));
    assert_eq!(g.read(KBD_LOW), scancode(3) as u16);
    assert_eq!(g.read(CSR) & csr::KBD_READY, 0);
    // Eight more, the low half taken each time, so that all twenty-four
    // bits move and no two words are alike.
    for k in 4..12u32 {
        g.wait(700 + 130 * u64::from(k));
        g.key(scancode(k));
        let hi = g.read(KBD_HIGH);
        let lo = g.read(KBD_LOW);
        assert_eq!(
            (u32::from(hi & 0xff) << 16) | u32::from(lo),
            scancode(k),
            "the two halves did not give the word back"
        );
    }
    // A read of the low half with nothing waiting: the bit is already
    // clear and the last word stands.
    assert_eq!(g.read(KBD_LOW), scancode(11) as u16);

    // ------------------------------------------------------------------
    // The mouse. Both axes, both directions, the twelve-bit wrap either
    // way, the three switches, and `MOUSE READY` cleared by a read of Y
    // and by nothing else.
    // ------------------------------------------------------------------
    g.wait(3_000);
    // A single count down from zero wraps the counter at once: 0 to
    // 0o7777, which is the cheapest exercise of the wrap there is.
    g.moved(-1, 0);
    for _ in 0..4 {
        g.wait(KB_CLK_NS);
        g.look();
    }
    let x = g.read(MOUSE_X);
    assert_eq!(x & mouse::COUNT, mouse::COUNT, "one count down from zero did not wrap X");
    assert_eq!(g.read(CSR) & csr::MOUSE_READY, csr::MOUSE_READY, "the step set no MOUSE READY");
    // Reading X leaves it, reading the status register leaves it, and
    // reading Y clears it: the 74LS109 at IOBCSR 0C26 has `-READ.MOUSE.Y`
    // on its clear.
    let y = g.read(MOUSE_Y);
    assert_eq!(y & mouse::COUNT, 0, "Y moved on a step of X alone");
    assert_eq!(g.read(CSR) & csr::MOUSE_READY, 0, "reading Y did not clear MOUSE READY");
    // And one count up from the wrap brings it back to zero.
    g.moved(1, 0);
    for _ in 0..4 {
        g.wait(KB_CLK_NS);
        g.look();
    }
    assert_eq!(g.read(MOUSE_X) & mouse::COUNT, 0, "one count up did not unwrap X");
    // Y down from zero, the same way, and then up.
    g.moved(0, -1);
    g.wait(4 * KB_CLK_NS);
    assert_eq!(g.read(MOUSE_Y) & mouse::COUNT, mouse::COUNT, "one count down did not wrap Y");
    g.moved(0, 1);
    g.wait(4 * KB_CLK_NS);
    assert_eq!(g.read(MOUSE_Y) & mouse::COUNT, 0, "one count up did not unwrap Y");
    // Motion of many sizes, both axes at once and one at a time, with the
    // counters looked at while they run. The pairs are chosen so that
    // neither counter holds one value for long and neither ends where it
    // started.
    let mut want_x: i64 = 0;
    let mut want_y: i64 = 0;
    for (dx, dy) in [
        (7i32, 0i32),
        (0, 11),
        (-3, 5),
        (137, -89),
        (-200, 0),
        (0, -450),
        (400, 300),
        (-61, -701),
        (23, 23),
    ] {
        g.moved(dx, dy);
        want_x += i64::from(dx);
        want_y += i64::from(dy);
        // **Looked at on every edge of `KB CLK^`, not only at the ends.**
        // A count is two edges --- the mouse holds a phase for 16 us and
        // the card samples every 8 --- and a trace that saw only where the
        // motion started and stopped could not tell a counter that got
        // there by another route, or one that arrived early. Ninety edges
        // is 720 us and 45 counts; the rest of a long move is skipped and
        // its end compared.
        let steps = dx.unsigned_abs().max(dy.unsigned_abs()) as u64;
        for _ in 0..(2 * steps + 4).min(90) {
            let next = g.now - g.now % KB_CLK_NS + KB_CLK_NS;
            g.at(next);
            g.look();
        }
        // Six reads at six successive clocks WHILE the counters run. The
        // mouse holds a phase for two of the card's clocks, so about half
        // of these are answered inside a clock the latch moved on, and it
        // is only there that `NEW` and `OLD` differ --- a card reading the
        // register off the wrong one of the two agrees everywhere else.
        //
        // SIX OF EACH REGISTER, NOT SIX ALTERNATING, and the difference was
        // measured: the mouse holds a phase for two clocks, so the clocks
        // the latch moves on are every other one, and six reads alternating
        // between the two registers put every read of a given register on
        // one parity --- which can be the parity where nothing moved. Six
        // in a row covers both.
        if steps >= 8 {
            for _ in 0..6u32 {
                g.read_in_clock(MOUSE_X);
            }
            for _ in 0..6u32 {
                g.read_in_clock(MOUSE_Y);
            }
        }
        g.wait(MOUSE_STEP_NS * (steps + 2));
        let x = g.read(MOUSE_X);
        let y = g.read(MOUSE_Y);
        assert_eq!(
            u32::from(x & mouse::COUNT),
            want_x.rem_euclid(4096) as u32,
            "X is not where the motion put it"
        );
        assert_eq!(
            u32::from(y & mouse::COUNT),
            want_y.rem_euclid(4096) as u32,
            "Y is not where the motion put it"
        );
    }
    // The three switches: every one of the eight masks, each read back
    // through the Y register's top three bits, and each a `MOUSE STATUS
    // CHANGE` of its own. The first read is close behind the change, so
    // the latch's lag is in the trace; the second is a clock later.
    for mask in [1u8, 3, 2, 6, 4, 5, 7, 0] {
        g.before_edge();
        g.btn(mask);
        // Read inside the very clock the latch takes the mask on, where
        // `NEW` has it and `OLD` has the mask before it.
        let y = g.read_in_clock(MOUSE_Y);
        assert_eq!(
            (y >> mouse::SHIFT) as u8 & mouse::BUTTONS,
            mask,
            "the switches did not reach the Y register in the clock they were latched"
        );
        assert_eq!(y & 0x8000, 0, "bit 15 of the Y register is ground");
        // And again two clocks later, where `OLD` has caught up.
        g.wait(2 * KB_CLK_NS);
        let y = g.read(MOUSE_Y);
        assert_eq!((y >> mouse::SHIFT) as u8 & mouse::BUTTONS, mask);
        assert_eq!(g.read(CSR) & csr::MOUSE_READY, 0, "the read of Y left MOUSE READY up");
    }
    // A switch change with no motion still sets the bit: the 25LS2521 at
    // IOBMSE 0A21 compares all seven lines.
    g.btn(5);
    g.wait(2 * KB_CLK_NS);
    assert_eq!(
        g.read(CSR) & csr::MOUSE_READY,
        csr::MOUSE_READY,
        "a switch alone set no MOUSE READY"
    );
    g.read(MOUSE_Y);
    g.btn(0);
    g.wait(2 * KB_CLK_NS);
    g.read(MOUSE_Y);

    // ------------------------------------------------------------------
    // The status register: five writable bits out of sixteen, a floating
    // upper byte, and two ready bits a write cannot touch.
    // ------------------------------------------------------------------
    g.wait(2_000);
    g.write(CSR, 0xFFFF);
    let v = g.read(CSR);
    assert_eq!(v & csr::WRITABLE, csr::WRITABLE, "all sixteen bits written did not set the five");
    assert_eq!(v & csr::FLOATING, csr::FLOATING, "the upper byte does not float high");
    g.write(CSR, 0);
    assert_eq!(g.read(CSR) & csr::WRITABLE, 0, "a write of zero left an enable up");
    // Each of the five alone.
    for bit in [
        csr::REMOTE_MOUSE_ENABLE,
        csr::MOUSE_INT_ENABLE,
        csr::KBD_INT_ENABLE,
        csr::CLOCK_INT_ENABLE,
        csr::SER_INT_ENABLE,
    ] {
        g.write(CSR, bit);
        let v = g.read(CSR);
        assert_eq!(v & csr::WRITABLE, bit, "writing one enable set another");
    }
    // The two bits above the enables that a write may not reach, with both
    // ready bits up: `KBD READY` from a press and `MOUSE READY` from a
    // step, and a write of zero leaving both.
    g.key(scancode(31));
    g.moved(3, -3);
    g.wait(8 * KB_CLK_NS);
    g.write(CSR, 0);
    let v = g.read(CSR);
    assert_eq!(
        v & (csr::KBD_READY | csr::MOUSE_READY),
        csr::KBD_READY | csr::MOUSE_READY,
        "a write of the status register cleared a ready bit"
    );
    g.read(KBD_LOW);
    g.read(MOUSE_Y);

    // ------------------------------------------------------------------
    // The answer's phase. The keyboard and mouse group selects through two
    // stages of the microsecond clock and the counter's low half through
    // one, so what the card answers at depends on where `-UB MSYN` falls in
    // that microsecond. Every one of the two hundred instants a 200 MHz
    // fabric can raise `-MSYN` at inside a microsecond is used, at three
    // registers: one that waits two edges, one that waits one, and one
    // that waits none.
    // ------------------------------------------------------------------
    g.wait(5_000);
    for k in 0..200u64 {
        // 61 and 200 are coprime, so this reaches all two hundred.
        let phase = 5 * ((k * 61) % 200);
        g.at_phase(phase);
        g.read(CSR);
        g.at_phase(phase);
        g.read(USEC_LOW);
        g.at_phase(phase);
        g.read(CLOCK);
    }
    assert_eq!(g.phases.len(), 200, "the phase sweep missed one: {} seen", g.phases.len());

    // ------------------------------------------------------------------
    // The microsecond counter, and MIT's latch. The low half is the count
    // as it stood at `-UB MSYN` and latches the whole thirty-two bits; the
    // high half is that latch and not the counter, which is what makes a
    // read of the pair consistent across a carry.
    // ------------------------------------------------------------------
    g.wait(3_000);
    let lo = g.read(USEC_LOW);
    let hi = g.read(USEC_HIGH);
    let msyn_of_low = g.now; // only used in the message below
    assert_eq!(hi, 0, "the counter has not reached 65,536 microseconds yet: {msyn_of_low}");
    assert!(lo > 0, "the microsecond counter has not moved");
    // The carry into the high half is at microsecond 65,536, which is
    // 65,535,890 ns from power-on. Read the low half five nanoseconds
    // before it and the high half well after: the latch must still be the
    // count from before the carry.
    let carry = FIRST_USEC_EDGE_NS + 65_536 * 1_000 - 1_000;
    assert_eq!(usec_at(carry), 65_536);
    assert_eq!(usec_at(carry - TICK_NS), 65_535);
    g.at(carry - TICK_NS);
    let lo = g.read(USEC_LOW);
    assert_eq!(lo, 0xFFFF, "the low half five nanoseconds before the carry");
    g.wait(2_000);
    let hi = g.read(USEC_HIGH);
    assert_eq!(hi, 0, "the high half came from the counter and not from the latch");
    // And now the pair taken in MIT's own order, after the carry.
    let lo = g.read(USEC_LOW);
    let hi = g.read(USEC_HIGH);
    assert_eq!(hi, 1, "the latch did not take the carry");
    assert!(lo < 100, "the low half is not just past the carry: {lo:#x}");
    // The high half again with no read of the low half in between: still
    // the latch, though the counter has moved on.
    g.wait(50_000);
    assert_eq!(g.read(USEC_HIGH), 1);
    // A write of either half is refused by the decoder, and the latch and
    // the counter are untouched by the attempt.
    g.cyc(USEC_LOW, true, 0xDEAD);
    g.cyc(USEC_HIGH, true, 0xBEEF);
    assert_eq!(g.read(USEC_HIGH), 1, "a refused write reached the latch");
    // The aliases: `0o764130` is the low half and `0o764132` the high.
    let lo = g.read(0o764130);
    let hi = g.read(0o764132);
    assert_eq!(hi, 1);
    assert!(lo > 0);

    // ------------------------------------------------------------------
    // The interval timer and `CLOCK READY`. Down from what was written, at
    // one count every 16 us, which is `iob.wlr`'s wiring and MIT's own
    // `doc/iob.text`; microcode 323 believes the opposite and
    // `ioboard::csr::CLOCK_READY` carries that discrepancy.
    // ------------------------------------------------------------------
    g.wait(3_000);
    // Loaded with zero: ready at once.
    g.write(CLOCK, 0);
    assert_eq!(g.read(CSR) & csr::CLOCK_READY, csr::CLOCK_READY, "an interval of zero is ready");
    // Seven intervals, each looked at before it runs out and after.
    for interval in [1u16, 2, 3, 0x10, 0x100, 0x400, 0x1234] {
        g.wait(1_000);
        g.write(CLOCK, interval);
        let loaded = g.landed;
        let v = g.read(CSR);
        assert_eq!(v & csr::CLOCK_READY, 0, "the load did not clear CLOCK READY");
        assert_eq!(g.b.interval_timer(), interval);
        // A look inside the interval, then one either side of its end. The
        // end is a multiple of 16,000 ns from the load, which is on the
        // grid, so both sides are reachable.
        let over = loaded + u64::from(interval) * INTERVAL_TICK_NS;
        assert_eq!(over % TICK_NS, 0);
        if over > g.now + 2 * TICK_NS {
            g.at(grid_before(loaded + (over - loaded) / 2).max(g.now));
            g.look();
            g.at(over - TICK_NS);
            g.look();
            assert!(!g.b.clock_ready(g.now), "CLOCK READY came up a tick early");
        }
        g.at(over);
        g.look();
        assert!(g.b.clock_ready(g.now), "CLOCK READY did not come up when the interval ran out");
        let v = g.read(CSR);
        assert_eq!(v & csr::CLOCK_READY, csr::CLOCK_READY, "the interval ran out and the bit is down");
    }
    // The longest interval there is, loaded and never waited out: 65,535
    // counts is 1.048 seconds and the trace is a fifth of that. A counter
    // too narrow, or one counting the wrong way, comes up inside the run.
    g.wait(1_000);
    g.write(CLOCK, 0xFFFF);
    let long_from = g.now;

    // ------------------------------------------------------------------
    // The sixty-cycle clock, which shares an address with the interval
    // timer: written it is the timer, read it is the two 74393s at CLKTOD
    // counting mains cycles since power-on. Read on both sides of twelve
    // boundaries, at the two grid instants that straddle each; see the
    // note at the top about why a fabric can meet them all.
    // ------------------------------------------------------------------
    // The interval timer's own tests have already carried the program past
    // several boundaries; start at the next one and take fourteen.
    //
    // ONE READ A BOUNDARY, ALTERNATING SIDES, because a cycle is 350 ns
    // long and the two grid instants that straddle a boundary are five
    // apart: both sides of one boundary cannot be read. Alternating gives
    // the same bound from the two directions --- a boundary read five
    // nanoseconds early must still say k-1, so a period a nanosecond short
    // is caught by the k'th of them once k exceeds five; a boundary read at
    // the first grid instant at or after it must already say k, so a period
    // a nanosecond long is caught the same way. A fabric that reloads a
    // down-counter with 3,333,333 ticks instead of subtracting the period
    // from an accumulator is exactly a nanosecond short a period.
    let first = g.now / SIXTY_CYCLE_NS + 2;
    for k in first..first + 14 {
        let boundary = k * SIXTY_CYCLE_NS;
        // `-SSYN` for this register is 250 ns past `-UB MSYN`, so the
        // instant the count is taken at is exactly chosen.
        let (at, want) = if k % 2 == 0 {
            (grid_at(boundary) - 250, k)
        } else {
            (grid_before(boundary) - 250, k - 1)
        };
        assert!(at > g.now, "the sixty-cycle boundaries have run past the program");
        g.at(at);
        let v = g.read(CLOCK);
        assert_eq!(u64::from(v), want, "the mains counter at boundary {k}");
        assert!(!g.b.clock_ready(g.now), "the long interval ran out at {}", g.now);
    }
    assert!(
        g.now - long_from > 190_000_000,
        "the long interval was not held for long enough to mean anything"
    );

    // ------------------------------------------------------------------
    // The interrupt. Four enables and three ready bits make three
    // requests; the card's own latch names them in one order, and the two
    // equations on page IOBINT put the clock first and the keyboard and
    // mouse last.
    // ------------------------------------------------------------------
    g.wait(2_000);
    g.init(); // a clean face: every enable down
    assert_eq!(g.b.interrupt_request(g.now), None, "the card is asking with no enable up");
    // The interval timer is still where the long load left it, so the
    // clock is NOT ready; enable it and nothing happens.
    g.write(CSR, csr::CLOCK_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None, "the clock asked before its interval ran out");
    // Run the interval out, and it asks.
    g.write(CLOCK, 1);
    g.wait(INTERVAL_TICK_NS);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(CLOCK_VECTOR));
    // The keyboard: ready with the enable down asks nothing.
    g.write(CSR, csr::KBD_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None, "the keyboard asked with nothing waiting");
    g.key(scancode(41));
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(KBD_VECTOR));
    // The mouse shares that vector.
    g.read(KBD_LOW);
    g.write(CSR, csr::MOUSE_INT_ENABLE);
    g.moved(0, 4);
    g.wait(4 * KB_CLK_NS);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(KBD_VECTOR));
    // The serial port, whose enable is not one of the 74LS175's four but
    // the second half of the 74LS74 at IOBSER 0D21.
    g.ser(true);
    g.look();
    assert_eq!(
        g.b.interrupt_request(g.now),
        Some(KBD_VECTOR),
        "the serial port asked with its enable down"
    );
    g.write(CSR, csr::MOUSE_INT_ENABLE | csr::SER_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(SERIAL_VECTOR), "the serial port did not win");
    // All three at once: the clock is named first.
    g.write(CSR, csr::MOUSE_INT_ENABLE | csr::SER_INT_ENABLE | csr::CLOCK_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(CLOCK_VECTOR), "the clock did not win");
    // Take them away one at a time and watch the vector fall through.
    g.write(CSR, csr::MOUSE_INT_ENABLE | csr::SER_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(SERIAL_VECTOR));
    g.write(CSR, csr::MOUSE_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(KBD_VECTOR));
    // And the mouse's ready bit taken away with the enable left up.
    g.read(MOUSE_Y);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None, "the mouse asked with its bit cleared");
    // The remote-mouse enable asks for nothing on its own: it is the first
    // of the 74LS175's four and reaches no interrupt gate.
    g.write(CSR, csr::REMOTE_MOUSE_ENABLE);
    g.key(scancode(42));
    g.moved(1, 0);
    g.wait(4 * KB_CLK_NS);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None, "the remote-mouse enable asked for something");

    // ------------------------------------------------------------------
    // `-UB INIT`. It clears the five interrupt enables and resets the
    // serial port; `KBD READY`, `MOUSE READY`, the mouse counters, the
    // interval timer and the microsecond counter have no pin on it.
    // ------------------------------------------------------------------
    g.wait(2_000);
    g.write(CSR, csr::WRITABLE);
    g.ser(true);
    g.write(CLOCK, 0x2000);
    g.key(scancode(43));
    g.moved(-9, 6);
    g.wait(16 * KB_CLK_NS);
    let before = g.read(CSR);
    let x_before = g.b.mouse_x();
    let y_before = g.b.mouse_y();
    let interval_before = g.b.interval_timer();
    assert_eq!(before & csr::WRITABLE, csr::WRITABLE);
    assert_eq!(before & csr::KBD_READY, csr::KBD_READY);
    assert_eq!(before & csr::MOUSE_READY, csr::MOUSE_READY);
    assert_eq!(before & csr::CLOCK_READY, 0);
    g.init();
    let after = g.read(CSR);
    assert_eq!(after & csr::WRITABLE, 0, "-UB INIT left an enable up");
    assert_eq!(after & csr::KBD_READY, csr::KBD_READY, "-UB INIT cleared KBD READY");
    assert_eq!(after & csr::MOUSE_READY, csr::MOUSE_READY, "-UB INIT cleared MOUSE READY");
    assert_eq!(after & csr::CLOCK_READY, 0, "-UB INIT reloaded the interval timer");
    assert_eq!(g.b.interval_timer(), interval_before, "-UB INIT changed the interval");
    assert_eq!(g.b.mouse_x(), x_before, "-UB INIT cleared the X counter");
    assert_eq!(g.b.mouse_y(), y_before, "-UB INIT cleared the Y counter");
    assert!(
        !(g.b.serial.rx_ready_at(g.now) || g.b.serial.tx_ready_at(g.now)),
        "-UB INIT did not reset the serial port"
    );
    // The word off the keyboard stands too: the shift registers have no
    // pin on `-RESET` either.
    assert_eq!(g.read(KBD_LOW), scancode(43) as u16, "-UB INIT dropped the keyboard's word");
    g.read(MOUSE_Y);
    // And the microsecond counter runs on: `the_microsecond_clock_runs_free_of_the_reset`.
    let before = g.read(USEC_LOW);
    g.wait(20_000);
    g.init();
    let after = g.read(USEC_LOW);
    assert!(after > before, "-UB INIT stopped the microsecond counter");

    // ------------------------------------------------------------------
    // The beep. `-CLICK.AUDIO` is `Y4` of the 74LS138 at IOBKBD 0C22 and
    // is not gated by `-WRITE`, so a read clicks as a write does; the
    // 74LS74 at 0C27 is wired as a toggle and one reference is one edge.
    // ------------------------------------------------------------------
    g.wait(2_000);
    let was = g.b.audio();
    g.write(BEEP, 0);
    assert_ne!(g.b.audio(), was, "a write of the beep did not toggle AUDIO");
    g.read(BEEP);
    assert_eq!(g.b.audio(), was, "a read of the beep did not toggle AUDIO");
    // A run of them at MIT's own half-wavelength, `uc-hacks.lisp`'s
    // `BEEP-WAVELENGTH` of `1350` octal, 744 microseconds.
    for k in 0..6u64 {
        g.wait(744_000 - (g.now % TICK_NS));
        g.write(BEEP, u16::try_from(k).unwrap());
    }
    // The interval timer's last state cleared, so the trace does not end
    // holding a bit nobody looked at.
    g.write(CLOCK, 0);
    g.look();

    // ------------------------------------------------------------------
    // THE CHAOSNET INTERFACE, `0o764140`-`0o764156`.  AIM-628 section 7 and
    // `chaos::interface`: the decode is the 74LS138 at LMUCON 0C18 on
    // `A<2:1>` AND ON READ AGAINST WRITE, so the same address is a different
    // register in the two directions.  `A3` is decoded for exactly two
    // things --- a read of `764152` is START where `764142` is MY ADDRESS,
    // and the receive buffer's read is disabled at `764154` --- and for
    // nothing else, so `764150` and `764152` written reach the CSR and the
    // transmit buffer as `764140` and `764142` do.
    //
    // **WHAT IS CHECKED HERE IS THE REGISTER FACE AND NOT THE PROTOCOL.**
    // The cable, the turn timer, the frame and the check word are the
    // `cadr-chaosnet` program's; under Loop Back muir's own interface plays
    // that far end and its instants are recorded as `CBL`, `CTD` and `CRX`
    // rows for the fabric's seam.  Everything the software reads --- the
    // CSR's ten made-up bits, the bit counter's arithmetic, the read
    // buffer's pointer, the lost count, the 256-word cap --- is the card's
    // own and is compared.
    // ------------------------------------------------------------------
    g.wait(5_000);

    // Every register of the group read once before anything is written.
    // NOT `764152`, which is START and would launch the empty buffer.
    assert_eq!(g.read(chaos::CSR), ccsr::TRANSMIT_DONE, "the Chaosnet CSR at power-on");
    assert_eq!(g.read(chaos::MY_ADDRESS), CHAOS_ADDRESS, "the address switches at LMMYNM");
    assert_eq!(g.read(chaos::READ_BUFFER), 0, "the read buffer with no packet in it");
    assert_eq!(g.read(chaos::BIT_COUNT), 0, "the bit count with no packet in it");
    // The aliases `A3` does not separate: `764150` is the CSR again and
    // `764156` the bit count again.
    assert_eq!(g.read(0o764150), ccsr::TRANSMIT_DONE, "0o764150 is not the CSR");
    assert_eq!(g.read(0o764156), 0, "0o764156 is not the bit count");
    // And the five directions of the group the decoder takes nowhere: the
    // read buffer and the bit count take no write, and `764154` --- the
    // receive buffer with `A3` up --- answers neither way.
    for (a, w) in [
        (chaos::READ_BUFFER, true),
        (chaos::BIT_COUNT, true),
        (0o764154u32, false),
        (0o764154, true),
        (0o764156, true),
    ] {
        g.cyc(a, w, 0x5A5A);
    }

    // The five bits of the CSR a write reaches and a read gives back, each
    // alone: `chaos::board::WRITABLE`.  The other eleven are read-only, or
    // are the three write-only commands below.
    const C_WRITABLE: u16 = ccsr::TIMER_INT_ENABLE
        | ccsr::LOOP_BACK
        | ccsr::SPY
        | ccsr::RECEIVE_INT_ENABLE
        | ccsr::TRANSMIT_INT_ENABLE;
    for bit in [
        ccsr::TIMER_INT_ENABLE,
        ccsr::LOOP_BACK,
        ccsr::SPY,
        ccsr::RECEIVE_INT_ENABLE,
        ccsr::TRANSMIT_INT_ENABLE,
    ] {
        g.write(chaos::CSR, bit);
        let v = g.read(chaos::CSR);
        assert_eq!(v & C_WRITABLE, bit, "writing one bit of the Chaosnet CSR set another");
        assert_eq!(v & ccsr::TRANSMIT_DONE, ccsr::TRANSMIT_DONE, "Transmit Done fell on a write");
    }
    // A write of all sixteen: the five stand, then Reset takes them away
    // again, then Clear Receiver and Clear Transmitter run.  muir's order,
    // and the board's, is exactly that.
    g.write(chaos::CSR, 0xFFFF);
    assert_eq!(g.read(chaos::CSR), ccsr::TRANSMIT_DONE, "a write of all ones did not reset");
    // The alias takes a write as the CSR does.
    g.write(0o764150, ccsr::SPY);
    assert_eq!(g.read(chaos::CSR) & C_WRITABLE, ccsr::SPY, "0o764150 written is not the CSR");
    g.write(chaos::CSR, ccsr::RESET);

    // --- a packet out and, under Loop Back, the same packet in ----------
    //
    // The words are injective and cover the sixteen bits between them; the
    // last written is the destination, which is this interface's own
    // address so that the frame comes back to it.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::RECEIVE_INT_ENABLE | ccsr::TRANSMIT_INT_ENABLE);
    // Transmit Done is up and its enable is now on, so the card is asking
    // for `0o270` --- the vector no trace could reach before this slice.
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(0o270), "the Chaosnet is not asking");
    let packet: Vec<u16> = vec![0o125252, 0o052525, 0o177400, 0o000377, 0o007417, CHAOS_ADDRESS];
    for (k, w) in packet.iter().enumerate() {
        // The transmit buffer takes a write at `764142` and at `764152`
        // alike; alternate, so that both are exercised on the same buffer.
        let a = if k % 2 == 0 { chaos::WRITE_BUFFER } else { 0o764152 };
        g.write(a, *w);
        assert_eq!(g.read(chaos::CSR) & ccsr::TRANSMIT_DONE, 0, "a buffer write left Transmit Done");
    }
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None, "the Chaosnet asked with Transmit Done down");

    let t0 = g.now;
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS, "START does not read the address back");
    // What the card must have handed the far end: the words that were
    // written, in order, and nothing else.  The check collects them off the
    // seam and compares here.
    g.ctx(&packet);
    let busy_on = when(&g.b, t0, 1_000_000, &|b| cs(b) & ccsr::CRC_ERROR != 0);
    let tdone = when(&g.b, t0, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    let landed = when(&g.b, t0, 1_000_000, &|b| cs(b) & ccsr::RECEIVE_DONE != 0);
    assert!(busy_on < tdone && tdone < landed, "the far end's three instants are out of order");
    // The cable goes busy: bit 14 is the CRC error OR `-CBLBSY`, which is
    // one net on the board and two things to the software.  Read the CSR
    // while it stands, so that the seam's own input is live here.
    g.cbl(busy_on, true);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::CRC_ERROR, ccsr::CRC_ERROR, "bit 14 is down while the cable is busy");
    assert_eq!(v & ccsr::RECEIVE_DONE, 0, "the packet landed before the cable was idle");
    g.ctd(tdone, false);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(0o270), "Transmit Done asked for nothing");
    // The packet lands, and `RDONE` rises with `-CBLBSY` lifting: muir's
    // `land` is `end + CBLBSY_OFF_NS`, so the two are one instant by
    // construction and the row carries the cable's level.
    let words = read_out(&g.b, landed, packet.len() + 2);
    let bits = ((packet.len() + 2) * 16) as u64;
    g.crx(landed, bits, false, false, &words);
    assert_eq!(words[packet.len()], CHAOS_ADDRESS, "the source word is not this interface");
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, ccsr::RECEIVE_DONE, "the packet did not land");
    assert_eq!(v & ccsr::CRC_ERROR, 0, "the check word failed on a frame this interface sent");
    // The bit count is the packet's bits less one, and comes down by a word
    // at every read of the buffer until the whole packet is out, where it
    // reads `7777` --- AIM-628's "a 12-bit minus-one".
    assert_eq!(u64::from(g.read(chaos::BIT_COUNT)), bits - 1, "the bit count on arrival");
    for (k, want) in words.iter().enumerate() {
        // The buffer at `764144`; `764154` is the same address with `A3` up
        // and is not answered, which the cycles above showed.
        assert_eq!(g.read(chaos::READ_BUFFER), *want, "word {k} of the packet");
        let left = bits - ((k as u64 + 1) * 16);
        let want_count = if left == 0 { 0o7777 } else { (left - 1) as u16 & 0o7777 };
        assert_eq!(g.read(0o764156), want_count, "the bit count after word {k}");
    }
    // Past the end: the buffer reads zero, the pointer STANDS and the count
    // stays at `7777`.
    //
    // **AND IT IS READ PAST THE END MORE TIMES THAN ITS POINTER IS WIDE.**
    // The 25LS193s at LMRBUF stop where the packet does; a pointer that ran on
    // instead reads zero for a while and then WRAPS, and from there it is
    // inside the packet again and hands the software words it has read. That
    // wrap is the only thing that tells a pointer which stops from one which
    // does not, so the program goes round it: 520 reads past a packet of
    // eight words, which is past 512 whatever the pointer's width up to nine
    // bits.
    for k in 0..520u32 {
        assert_eq!(g.read(chaos::READ_BUFFER), 0, "the buffer {k} reads past the packet");
    }
    assert_eq!(g.read(chaos::BIT_COUNT), 0o7777, "the bit count past the end of the packet");

    // --- a second packet on a buffer nobody emptied: the lost count -----
    //
    // Receive Done still stands, so the next frame is counted lost and
    // dropped whole.  Four bits of it, at `0o17000`.
    g.wait(2_000);
    for k in 0..3u16 {
        let one: Vec<u16> = vec![0o070707 ^ u16::from(k), CHAOS_ADDRESS];
        let t = g.now;
        for w in &one {
            g.write(chaos::WRITE_BUFFER, *w);
        }
        assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
        g.ctx(&one);
        let busy = when(&g.b, t, 1_000_000, &|b| cs(b) & ccsr::CRC_ERROR != 0);
        g.cbl(busy, true);
        let td = when(&g.b, busy, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
        g.ctd(td, false);
        // The frame lands and is dropped; `RDONE` still rises with the
        // cable going idle, so the row is where the busy level falls.
        let land = when(&g.b, td, 1_000_000, &|b| cs(b) & ccsr::CRC_ERROR == 0);
        let lost_words = read_out(&g.b, land, one.len() + 2);
        g.crx(land, ((one.len() + 2) * 16) as u64, false, false, &lost_words);
        let v = g.read(chaos::CSR);
        assert_eq!(
            (v & ccsr::LOST_COUNT) >> 9,
            k + 1,
            "the lost count did not go up on a frame the buffer had no room for"
        );
        assert_eq!(v & ccsr::RECEIVE_DONE, ccsr::RECEIVE_DONE);
    }
    // The first packet is still what the buffer holds: a dropped frame does
    // not disturb it.  The pointer is past the end, so the count is `7777`.
    assert_eq!(g.read(chaos::BIT_COUNT), 0o7777, "a lost frame moved the buffer's pointer");

    // Clear Receiver takes the packet, the lost count and the CRC verdict
    // away, and leaves the five writable bits where the same word puts them.
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER | ccsr::SPY | ccsr::LOOP_BACK);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, 0, "Clear Receiver left Receive Done up");
    assert_eq!(v & ccsr::LOST_COUNT, 0, "Clear Receiver left the lost count");
    assert_eq!(v & C_WRITABLE, ccsr::SPY | ccsr::LOOP_BACK, "Clear Receiver took the enables too");
    assert_eq!(g.read(chaos::BIT_COUNT), 0, "the bit count after Clear Receiver");
    assert_eq!(g.read(chaos::READ_BUFFER), 0, "the buffer after Clear Receiver");

    // --- the buffer's own size, which is 256 words ----------------------
    //
    // The 2147 at LMTBUF 0C10 is 4,096 bits on `TBCT<11:0>`, so a 257th
    // word has nowhere to go and is dropped.  Written 300 and handed 256.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_TRANSMITTER);
    let long: Vec<u16> = (0..300u16).map(|k| k.wrapping_mul(0o2731) ^ 0o52525).collect();
    for w in &long {
        g.write(chaos::WRITE_BUFFER, *w);
    }
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    g.ctx(&long[..256]);
    // Clear Transmitter stops it before the turn ever comes: the buffer
    // goes, Transmit Done comes back up and no frame is ever launched.
    g.wait(20_000);
    g.write(chaos::CSR, ccsr::CLEAR_TRANSMITTER | ccsr::LOOP_BACK);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::TRANSMIT_DONE, ccsr::TRANSMIT_DONE, "Clear Transmitter left it down");
    g.wait(400_000);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, 0, "a cleared transmitter still sent its frame");
    // And an empty buffer started: there is nothing to send, so nothing
    // comes back, and Transmit Done stands throughout.
    g.write(chaos::CSR, ccsr::LOOP_BACK);
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    g.ctx(&[]);
    g.wait(400_000);
    assert_eq!(g.read(chaos::CSR) & ccsr::RECEIVE_DONE, 0, "an empty buffer arrived as a packet");

    // --- `-UB INIT` reaches the interface -------------------------------
    //
    // `-INIT*` is AIM-628's "just as at power up and Unibus Initialize":
    // `Interface::reset` in muir, the 74LS174 at LMUCON 0B20's clear and the
    // 74S08s at LMMODU 0B10 and LMRCTL 0E10 on the board.
    g.wait(2_000);
    g.write(chaos::CSR, C_WRITABLE);
    assert_eq!(g.read(chaos::CSR) & C_WRITABLE, C_WRITABLE);
    g.init();
    let v = g.read(chaos::CSR);
    assert_eq!(v & C_WRITABLE, 0, "-UB INIT left a Chaosnet enable up");
    assert_eq!(v & ccsr::TRANSMIT_DONE, ccsr::TRANSMIT_DONE, "-UB INIT left Transmit Done down");
    assert_eq!(v & ccsr::RECEIVE_DONE, 0);

    // ------------------------------------------------------------------
    // THE SERIAL PORT, `0o764160`-`0o764176`: the Signetics 2651 at IOBSER
    // 0A12 on `A<2:1>` under `-SELECT.764160`, with `A3` NOT DECODED, so
    // `764170`-`764176` are the same four registers again.  Every address
    // of the group is answered, read and written, which is why the group
    // has no unanswered direction where the Chaosnet's has five.
    //
    // **THE BAUD-RATE GENERATOR IS NOT IN THE FABRIC AND THIS IS WHERE
    // THAT IS SAID.**  The 5.0688 MHz can at IOBSER 0A15 divides to a 16X
    // clock at instants that are not multiples of five --- one bit at 9,600
    // baud is 104,166 ns and a frame 1,041,666 --- so the grid cannot carry
    // them, and the line itself is a TCP socket that `cadr-serial` paces.
    // What the card has instead is a seam: `STK` is the shift register
    // taking the holding register's character, `SDN` is the frame ending
    // and `SRX` is a character arriving, each at muir's own instant rounded
    // up to the grid.  Every register the software reads is still the
    // card's --- the two pointers, the status byte, the overrun, the
    // command register's own bits --- and every one of them is compared.
    // ------------------------------------------------------------------
    g.wait(5_000);
    // The upper byte nothing drives, which a serial read carries over the
    // 2651's own eight bits.
    const FLOATING: u16 = csr::FLOATING;

    // Every register of the group read once, out of the reset `-UB INIT`
    // above left.  The upper byte floats, the 2651 driving `UBO0`..`UBO7`
    // alone through the 74LS244 at IOBSER 0E29.
    assert_eq!(g.read(serial::DATA), FLOATING, "the receive holding register after a reset");
    assert_eq!(g.read(serial::STATUS), FLOATING, "the status register with nothing plugged in");
    // The mode pointer: the first read is mode register 1 and the second
    // mode register 2, and a read of the command register puts it back.
    assert_eq!(g.read(serial::MODE), FLOATING, "mode register 1 after a reset");
    assert_eq!(g.read(serial::MODE), FLOATING, "mode register 2 after a reset");
    assert_eq!(g.read(serial::COMMAND), FLOATING, "the command register after a reset");

    // The mode registers, written and read back, with the pointer walked
    // both ways.  `0o116` is asynchronous 16X, eight bits, no parity, one
    // stop bit; `0o177` is 19,200 baud with both halves on the internal
    // clock.
    g.write(serial::MODE, 0o116);
    g.write(serial::MODE, 0o177);
    assert_eq!(g.b.serial.mode1(), 0o116, "mode register 1 did not take the first write");
    assert_eq!(g.b.serial.mode2(), 0o177, "mode register 2 did not take the second");
    // A read of the command register resets the pointer, so the next read
    // of the mode address is register 1 again.
    g.read(serial::COMMAND);
    assert_eq!(g.read(serial::MODE), FLOATING | 0o116, "the pointer did not go back to mode 1");
    assert_eq!(g.read(serial::MODE), FLOATING | 0o177, "the second read is not mode 2");
    // And the aliases `A3` does not decode: `764174` is the mode address
    // again, and `764176` the command address.
    g.read(0o764176);
    assert_eq!(g.read(0o764174), FLOATING | 0o116, "0o764174 is not the mode address");

    // The three SYN registers behind the status address, three deep and
    // wrapping, with the same read of the command register putting the
    // pointer back.  Nothing on this board uses synchronous mode; what is
    // checked is that a write goes somewhere and the pointer counts.
    for v in [0o252u16, 0o125, 0o377, 0o001] {
        g.write(serial::STATUS, v);
    }
    g.read(serial::COMMAND);

    // --- the cable, and a character out ---------------------------------
    g.wait(2_000);
    g.spl(true);
    let v = g.read(serial::STATUS);
    assert_eq!(
        v & u16::from(serial::status::DSR | serial::status::DCD),
        u16::from(serial::status::DSR | serial::status::DCD),
        "plugging the cable in did not raise -DSR and -DCD"
    );
    assert_eq!(
        v & u16::from(serial::status::TX_EMPTY_OR_DSCHG),
        u16::from(serial::status::TX_EMPTY_OR_DSCHG),
        "the modem lines moved and SR2 did not say so"
    );
    // Reading the status register clears the data-set-change latch.
    assert_eq!(
        g.read(serial::STATUS) & u16::from(serial::status::TX_EMPTY_OR_DSCHG),
        0,
        "a read of the status register left the data-set-change latch up"
    );
    // The transmitter and the receiver on, in normal mode.
    let on = serial::command::TX_ENABLE | serial::command::RX_ENABLE | serial::command::DTR
        | serial::command::RTS;
    g.write(serial::COMMAND, u16::from(on));
    assert_eq!(g.read(serial::COMMAND), FLOATING | u16::from(on), "the command register");
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::TX_READY), u16::from(serial::status::TX_READY),
               "the transmitter is enabled and the holding register empty");

    // A character into the holding register.  `SR0` falls at once and comes
    // back at the first 16X clock the shift register can take it on, which
    // is the `STK` row; the frame ends a `frame_ns` later, which is `SDN`,
    // and the byte reaches the far end there.
    let frame = g.b.serial.framing().frame_ns(g.b.serial.rate());
    assert!(frame > 400_000 && frame < 600_000, "the frame at 19,200 baud is {frame} ns");
    g.before_16x(3_000);
    g.write(serial::DATA, 0o325);
    let loaded = g.landed;
    assert!(!g.b.serial.tx_ready_at(loaded), "the holding register is full and SR0 is still up");
    let take = first_true(loaded, 4 * frame, &|t| g.b.serial.tx_ready_at(t));
    assert!(take >= g.now, "the 16X clock came inside the cycle that loaded the character");
    g.stk(take);
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::TX_READY),
               u16::from(serial::status::TX_READY), "SR0 did not come back when the shifter took it");
    g.sdn(take + frame);
    g.drain_serial();
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::TX_EMPTY_OR_DSCHG),
               u16::from(serial::status::TX_EMPTY_OR_DSCHG), "SR2 is down with both registers empty");

    // Two characters back to back: the second is loaded while the first is
    // still shifting, so the holding register is full through the frame and
    // the shift register takes it the moment the frame ends.
    g.before_16x(3_000);
    g.write(serial::DATA, 0o101);
    let take1 = first_true(g.landed, 4 * frame, &|t| g.b.serial.tx_ready_at(t));
    assert!(take1 >= g.now, "the 16X clock came inside the cycle that loaded the character");
    g.stk(take1);
    g.write(serial::DATA, 0o102);
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::TX_READY), 0,
               "the holding register took a second character and still says ready");
    // The first frame ends and the second starts at that instant, with no
    // 16X clock in between: muir's `transmit` hands it straight over.
    g.sdn(take1 + frame);
    g.stk(take1 + frame);
    g.drain_serial();
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::TX_READY),
               u16::from(serial::status::TX_READY), "the second character did not leave the holding register");
    g.sdn(take1 + 2 * frame);
    g.drain_serial();

    // --- a character in, and the overrun --------------------------------
    g.wait(2_000);
    {
        let now = g.now;
        g.b.serial.cable.send(0o252, now);
    }
    let got = first_true(g.now, 4 * frame, &|t| g.b.serial.rx_ready_at(t));
    g.srx(got, 0o252);
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::RX_READY), u16::from(serial::status::RX_READY),
               "the character arrived and SR1 is down");
    assert_eq!(g.read(serial::DATA), FLOATING | 0o252, "the receive holding register");
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::RX_READY), 0,
               "a read of the holding register left SR1 up");
    // A second character on one nobody read: the overrun bit, which is the
    // only error muir's 2651 ever sets.
    {
        let now = g.now;
        g.b.serial.cable.send(0o146, now);
        g.b.serial.cable.send(0o271, now + frame);
    }
    let a = first_true(g.now, 4 * frame, &|t| g.b.serial.rx_ready_at(t));
    g.srx(a, 0o146);
    // The second lands where the overrun appears, which is a probe on a copy:
    // `rx_ready_at` is already true and cannot tell the two apart.
    let b2 = when(&g.b, a + 1, 4 * frame, &|b| b.serial.status() & serial::status::OVERRUN != 0);
    g.srx(b2, 0o271);
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::OVERRUN), u16::from(serial::status::OVERRUN),
               "a character landed on one nobody read and there is no overrun");
    assert_eq!(g.read(serial::DATA), FLOATING | 0o271, "the overrun leaves the LATER character");
    // `RESET ERROR` in the command register takes it away, and is not
    // stored: the register reads back without it.
    g.write(serial::COMMAND, u16::from(on | serial::command::RESET_ERROR));
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::OVERRUN), 0,
               "RESET ERROR left the overrun bit up");
    assert_eq!(g.read(serial::COMMAND), FLOATING | u16::from(on),
               "RESET ERROR is stored in the command register");

    // --- the card's own interrupt off the 2651's ready lines -------------
    //
    // `SER.IREQ` is `-RxRDY` and, by ECO 10 of `cadrio/iob.eco`, `-TxRDY`
    // on the same net, through the 74LS02 at IOBSER 0E11 with `SER INT
    // ENABLE`.  The I/O board's own status register carries that enable.
    g.write(CSR, csr::SER_INT_ENABLE);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(SERIAL_VECTOR),
               "the transmitter is ready and the card is not asking");
    g.write(serial::COMMAND, 0);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None, "the port is off and the card is still asking");
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::TX_READY), 0);
    g.write(serial::COMMAND, u16::from(on));
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(SERIAL_VECTOR));
    g.write(CSR, 0);

    // --- the cable pulled out -------------------------------------------
    //
    // "The 2651 is conditioned to transmit data when the -CTS input is
    // low"; open, the MC1489 gives the chip all three high and the port
    // stops.  The data-set-change latch says the lines moved.
    g.wait(2_000);
    g.spl(false);
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::DSR | serial::status::DCD), 0,
               "the cable is out and the modem lines are still up");
    assert_eq!(v & u16::from(serial::status::TX_EMPTY_OR_DSCHG),
               u16::from(serial::status::TX_EMPTY_OR_DSCHG), "the lines moved and SR2 is down");

    // --- local loop back -------------------------------------------------
    //
    // "CR2 (RxEN) is ignored" and the chip's own `-DTR` and `-RTS` become
    // its `-DCD` and `-CTS`, so the port runs with nothing on the cable and
    // a character transmitted arrives at its own receiver.
    g.wait(2_000);
    let loopb = serial::command::LOCAL_LOOP_BACK | serial::command::TX_ENABLE
        | serial::command::DTR | serial::command::RTS;
    g.write(serial::COMMAND, u16::from(loopb));
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::DCD), u16::from(serial::status::DCD),
               "local loop back does not make -DTR the chip's own -DCD");
    assert_eq!(v & u16::from(serial::status::DSR), 0, "-DSR is the cable's and the cable is out");
    g.before_16x(3_000);
    g.write(serial::DATA, 0o063);
    let take2 = first_true(g.landed, 4 * frame, &|t| g.b.serial.tx_ready_at(t));
    assert!(take2 >= g.now, "the 16X clock came inside the cycle that loaded the character");
    g.stk(take2);
    g.sdn(take2 + frame);
    g.drain_serial();
    let v = g.read(serial::STATUS);
    assert_eq!(v & u16::from(serial::status::RX_READY), u16::from(serial::status::RX_READY),
               "local loop back did not put the character into the receiver");
    assert_eq!(g.read(serial::DATA), FLOATING | 0o063, "the character that came back round");
    g.write(serial::COMMAND, 0);

    // --- a frame shorter than eight bits ---------------------------------
    //
    // "If the character length is less than 8 bits, the high order unused
    // bits in the Holding Register are set to zero."  `0o102` is asynchronous
    // 16X with FIVE data bits and one stop bit, so a character of all ones
    // reaches the far end as `0o37`.
    g.wait(2_000);
    g.spl(true);
    g.read(serial::COMMAND);
    g.write(serial::MODE, 0o102);
    g.write(serial::MODE, 0o177);
    g.write(serial::COMMAND, u16::from(on));
    let frame5 = g.b.serial.framing().frame_ns(g.b.serial.rate());
    assert!(frame5 < frame, "a five-bit frame is not shorter than an eight-bit one");
    g.before_16x(3_000);
    g.write(serial::DATA, 0o377);
    let take5 = first_true(g.landed, 4 * frame5, &|t| g.b.serial.tx_ready_at(t));
    assert!(take5 >= g.now, "the 16X clock came inside the cycle that loaded the character");
    g.stk(take5);
    g.sdn(take5 + frame5);
    g.drain_serial();

    // --- the two modes that cut the CPU off from the transmitter ---------
    //
    // "Auto echo mode ... the CPU to transmitter link is disabled", and the
    // same for remote loop back: `SR0` is down in both however `CR0` stands,
    // so a driver that set either and went on writing characters would be
    // writing into a register nothing empties.  **The echo itself is not
    // built and the module's header says why**, so nothing is sent here.
    for m in [serial::command::AUTO_ECHO, serial::command::REMOTE_LOOP_BACK] {
        g.write(serial::COMMAND, u16::from(m | on));
        let v = g.read(serial::STATUS);
        assert_eq!(v & u16::from(serial::status::TX_READY), 0,
                   "the transmitter runs in mode {m:o}");
        assert_eq!(g.read(serial::COMMAND), FLOATING | u16::from(m | on),
                   "the command register did not take the mode");
    }
    g.write(serial::COMMAND, u16::from(on));

    // --- a character waiting when the receiver is turned off --------------
    //
    // "`RxRDY` ... is cleared when the receiver is disabled by CR2", and the
    // test is against the word being STORED and not the one already there.
    g.wait(2_000);
    g.read(serial::COMMAND);
    g.write(serial::MODE, 0o116);
    g.write(serial::MODE, 0o177);
    g.write(serial::COMMAND, u16::from(on));
    {
        let now = g.now;
        g.b.serial.cable.send(0o317, now);
    }
    let waiting = first_true(g.now, 4 * frame, &|t| g.b.serial.rx_ready_at(t));
    g.srx(waiting, 0o317);
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::RX_READY),
               u16::from(serial::status::RX_READY), "the character did not arrive");
    // The transmitter left on, so that what falls is the receiver's own bit
    // and not everything at once.
    g.write(serial::COMMAND, u16::from(serial::command::TX_ENABLE | serial::command::DTR
                                       | serial::command::RTS));
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::RX_READY), 0,
               "turning the receiver off left SR1 up");
    assert_eq!(g.read(serial::STATUS) & u16::from(serial::status::TX_READY),
               u16::from(serial::status::TX_READY), "the transmitter went off with it");
    g.write(serial::COMMAND, u16::from(on));

    // --- `-UB INIT` is the 2651's own RESET pin --------------------------
    g.wait(2_000);
    g.spl(true);
    g.write(serial::MODE, 0o116);
    g.write(serial::MODE, 0o177);
    g.write(serial::COMMAND, u16::from(on));
    g.init();
    assert_eq!(g.b.serial.mode1(), 0, "-UB INIT left mode register 1");
    assert_eq!(g.b.serial.mode2(), 0, "-UB INIT left mode register 2");
    assert_eq!(g.b.serial.command(), 0, "-UB INIT left the command register");
    assert_eq!(g.read(serial::MODE), FLOATING, "-UB INIT did not put the mode pointer back");
    g.spl(false);

    // ------------------------------------------------------------------
    // What the program covered.
    // ------------------------------------------------------------------
    let end = g.now;
    let registers: Vec<u32> =
        vec![KBD_LOW, KBD_HIGH, MOUSE_Y, MOUSE_X, BEEP, CSR, 0o764114, 0o764116, USEC_LOW,
             USEC_HIGH, CLOCK, GPIO];
    for r in &registers {
        assert!(g.reads.contains_key(r), "{r:o} was never read");
    }
    for r in [CSR, CLOCK, BEEP] {
        assert!(g.writes.contains_key(&r), "{r:o} was never written");
    }
    assert_eq!(g.buttons.len(), 8, "not every mouse switch mask was held");
    assert_eq!(g.latched_switches.len(), 8, "not every switch mask reached the Y register");
    assert!(g.latched_quadrature.len() >= 4, "the X register's quadrature bits barely moved");
    assert!(g.x_seen.len() > 150, "the X counter took {} values", g.x_seen.len());
    assert!(g.y_seen.len() > 150, "the Y counter took {} values", g.y_seen.len());
    assert!(g.x_seen.contains(&0) && g.x_seen.contains(&mouse::COUNT), "X did not wrap");
    assert!(g.y_seen.contains(&0) && g.y_seen.contains(&mouse::COUNT), "Y did not wrap");
    assert_eq!(g.codes.len() as u64, g.keys, "two presses shared a scan code");
    assert_eq!(
        g.codes.iter().fold(0u32, |a, c| a | c),
        0x00FF_FFFF,
        "the scan codes do not cover all twenty-four bits"
    );
    // **ALL FOUR VECTORS ARE REACHABLE NOW.**  `0o270` was the one no trace
    // against this model could ask for, because `interrupt_request` consults
    // `self.chaos` and nothing was plugged in; the Chaosnet slice plugs one
    // in, so the priority chain is compared against muir end to end rather
    // than held to page IOBINT's equations in the testbench.
    assert_eq!(g.vectors.len(), 4, "not every reachable vector was asked for");
    for v in [KBD_VECTOR, SERIAL_VECTOR, 0o270u16, CLOCK_VECTOR] {
        assert!(g.vectors.contains_key(&v), "{v:o} was never asked for");
    }
    assert!(g.usec_high.len() >= 2, "the microsecond counter's high half never moved");
    assert!(g.sixty.len() >= 8, "the mains counter took {} values", g.sixty.len());
    assert!(g.clock_ready_both[0] > 0 && g.clock_ready_both[1] > 0, "CLOCK READY never moved");
    assert!(g.audio_both[0] > 0 && g.audio_both[1] > 0, "AUDIO never moved");
    assert!(g.unanswered >= 9, "too few cycles nothing answered");
    assert!(g.slips > 0, "no read landed off the grid, which the low half always does");
    assert_eq!(g.inits, 5, "the program made a different number of -UB INIT pulses");
    // The two groups this slice added, and what they were asked to do.
    for r in [chaos::CSR, chaos::MY_ADDRESS, chaos::READ_BUFFER, chaos::BIT_COUNT, chaos::START] {
        assert!(g.reads.contains_key(&r), "the Chaosnet register {r:o} was never read");
    }
    for r in [chaos::CSR, chaos::WRITE_BUFFER] {
        assert!(g.writes.contains_key(&r), "the Chaosnet register {r:o} was never written");
    }
    for r in [serial::DATA, serial::STATUS, serial::MODE, serial::COMMAND] {
        assert!(g.reads.contains_key(&r), "the serial register {r:o} was never read");
        assert!(g.writes.contains_key(&r), "the serial register {r:o} was never written");
    }
    // The aliases `A3` does not separate are cycles of their own, so that a
    // decode that took `A3` where it must not is caught by a read and not
    // only by the sweep.
    for a in [0o764150u32, 0o764152, 0o764154, 0o764156, 0o764174, 0o764176] {
        assert!(g.addrs.contains(&a), "{a:o} was never used");
    }
    assert!(g.ctx_rows >= 5, "too few transmit buffers handed over: {}", g.ctx_rows);
    assert!(g.crx_rows >= 4, "too few packets landed: {}", g.crx_rows);
    assert!(g.stk_rows >= 4 && g.sdn_rows >= 4, "the 2651 sent too little");
    assert!(g.srx_rows >= 3, "the 2651 received too little");
    assert!(g.sout_rows >= 3, "too few characters reached the cable");
    assert!(g.spl_rows >= 4, "the RS-232 cable never moved both ways");
    assert!(g.serial_slips > 0, "no answer of the serial port's fell off the grid, and all do");
    assert!(g.far_slips > 0, "no far-end instant fell off the grid");
    assert!(g.ccsr_seen.len() >= 12, "the Chaosnet CSR took {} values", g.ccsr_seen.len());
    assert!(g.sstat_seen.len() >= 8, "the 2651's status took {} values", g.sstat_seen.len());

    let total_reads: u64 = g.reads.values().sum();
    let total_writes: u64 = g.writes.values().sum();

    println!("# the I/O board's reference trace, from muir's ioboard::IoBoard over the Unibus");
    println!("# generated by golden/src/iob.rs");
    println!("#");
    println!("# DECNONE  first last");
    println!("#     every address in [first,last] is answered by nothing, read or written");
    println!("# DEC      uaddr write reg");
    println!("#     ioboard::answers(uaddr, write); reg {NO_REG:x} is none");
    println!("# CYC      n msyn ssyn slip off uaddr reg write wdata rdata <face>");
    println!("#     one Unibus cycle: -UB MSYN up at msyn, -UB SSYN at ssyn, -UB MSYN down");
    println!("#     at off.  ssyn 0 is a cycle nothing answers and -UB SSYN never comes.");
    println!("#     slip is how many ns before ssyn muir's own answer falls: the fabric's");
    println!("#     grid cannot reach it and nothing downstream can see the difference.");
    println!("# KEY      n ns scancode <face>          a word off the keyboard's pair");
    println!("# MOVE     n ns dx dy <face>             the mouse moved, right and down");
    println!("# BTN      n ns mask <face>              the three switches, left 1 middle 2 right 4");
    println!("# SER      n ns ready <face>             the serial port's ready line at the card");
    println!("# INIT     n ns <face>                   -UB INIT");
    println!("# FACE     n ns <face>                   a sample with no cycle");
    println!("#");
    println!("# The Chaosnet interface's far end and the serial port's, which are the");
    println!("# `cadr-chaosnet` and `cadr-serial` programs' on the board and muir's own");
    println!("# models here.  Every instant is rounded UP to the 5 ns grid, as the");
    println!("# microsecond counter's low half is, and `far_offgrid` counts how many.");
    println!("#");
    println!("# CBUF     dir seq k word            dir 0 a packet landing, 1 a buffer handed over");
    println!("# CTX      n ns seq len <face>       the transmit buffer the card handed over");
    println!("#     since the last such row: an ASSERTION, the words having come over the bus");
    println!("# CRX      n ns seq bits len crc busy <face>  a packet lands in the receive buffer");
    println!("#     stimulus; -CBLBSY lifts with RDONE, so the row is the cable going idle too");
    println!("# CTD      n ns abort <face>         Transmit Done off the far end");
    println!("# CBL      n ns busy <face>          -CBLBSY, which bit 14 reads out");
    println!("# STK      n ns <face>               the shift register takes the holding register");
    println!("# SDN      n ns <face>               the shift register finishes its frame");
    println!("# SRX      n ns data <face>          a character reaches the receive path");
    println!("# SOUT     n ns data <face>          a character reaches the cable: an ASSERTION");
    println!("# SPL      n ns plugged <face>       something on the far end of the RS-232 cable");
    println!("#");
    println!("# <face> = csr x y held clkrdy interval intr audio serrdy ccsr cbits sm1 sm2 scmd sstat");
    println!("#     csr       the status register's flip-flops, before the floating byte");
    println!("#               and CLOCK READY are made up on a read");
    println!("#     x y       the two twelve-bit counters");
    println!("#     held      the switches as the mouse holds them, not as latched");
    println!("#     clkrdy    CLOCK READY, the interval timer's latch");
    println!("#     interval  what the interval timer was last loaded with");
    println!("#     intr      the Unibus vector the card is requesting, or 0");
    println!("#     audio     AUDIO, the beep's flip-flop");
    println!("#     serrdy    the serial port's -RxRDY or -TxRDY");
    println!("#     ccsr      the Chaosnet interface's CSR as a read assembles it");
    println!("#     cbits     its bit counter, the RBCT 25LS193s at LMRBUF");
    println!("#     sm1 sm2   the 2651's two mode registers");
    println!("#     scmd      its command register");
    println!("#     sstat     its status register");
    println!("#");
    println!("# n and every instant are decimal nanoseconds; every other value hexadecimal");
    println!("# except dx and dy, which are signed decimal");
    println!("#");
    println!("# tick_ns {TICK_NS}");
    println!("# ub_address_bits {UB_ADDRESS_BITS}");
    println!("# first_usec_edge_ns {FIRST_USEC_EDGE_NS}");
    println!("# kb_clk_ns {KB_CLK_NS}");
    println!("# mouse_step_ns {MOUSE_STEP_NS}");
    println!("# interval_tick_ns {INTERVAL_TICK_NS}");
    println!("# sixty_cycle_ns {SIXTY_CYCLE_NS}");
    println!("# unibus_strobe_ns {UNIBUS_STROBE_NS}");
    println!("# unanswered_hold_ns {UNANSWERED_HOLD_NS}");
    println!("# csr_writable {:o}", csr::WRITABLE);
    println!("# csr_floating {:o}", csr::FLOATING);
    println!("# mouse_count {:o}", mouse::COUNT);
    println!("# kbd_vector {KBD_VECTOR:o}");
    println!("# serial_vector {SERIAL_VECTOR:o}");
    println!("# clock_vector {CLOCK_VECTOR:o}");
    println!("# chaos_address {CHAOS_ADDRESS}");   // decimal, as the fabric takes it
    println!("# chaos_first {:o}", chaos::CSR);
    println!("# chaos_last {:o}", 0o764156u32);
    println!("# serial_first {:o}", serial::DATA);
    println!("# serial_last {:o}", 0o764176u32);
    println!("# chaos_writable {:o}", 0o67u16);
    println!("# chaos_vector {:o}", 0o270u16);
    println!("# chaos_buffer_words {}", 256);
    println!("# ctx_rows {}", g.ctx_rows);
    println!("# ctx_words {}", g.bufs.iter().filter(|b| b.0 == 1).map(|b| b.2.len()).sum::<usize>());
    println!("# crx_words {}", g.bufs.iter().filter(|b| b.0 == 0).map(|b| b.2.len()).sum::<usize>());
    println!("# crx_rows {}", g.crx_rows);
    println!("# ctd_rows {}", g.ctd_rows);
    println!("# cbl_rows {}", g.cbl_rows);
    println!("# stk_rows {}", g.stk_rows);
    println!("# sdn_rows {}", g.sdn_rows);
    println!("# srx_rows {}", g.srx_rows);
    println!("# sout_rows {}", g.sout_rows);
    println!("# spl_rows {}", g.spl_rows);
    println!("# far_offgrid {}", g.far_slips);
    println!("# offgrid_serial {}", g.serial_slips);
    println!("# ccsr_values {}", g.ccsr_seen.len());
    println!("# sstat_values {}", g.sstat_seen.len());
    println!("# last_ns {end}");
    println!("# last_tick {}", end / TICK_NS);
    println!("# rows {}", g.line);
    println!("# dec_rows {dec_rows}");
    println!("# dec_none_runs {dec_none_runs}");
    println!("# answering_addresses {answering}");
    println!("# reads {total_reads}");
    println!("# writes {total_writes}");
    println!("# unanswered {}", g.unanswered);
    println!("# offgrid_answers {}", g.slips);
    println!("# msyn_phases {}", g.phases.len());
    println!("# presses {}", g.keys);
    println!("# moves {}", g.moves);
    println!("# inits {}", g.inits);
    println!("# faces {}", g.faces);
    println!("# x_values {}", g.x_seen.len());
    println!("# y_values {}", g.y_seen.len());
    println!("# csr_values {}", g.csr_seen.len());
    println!("# sixty_values {}", g.sixty.len());
    for (r, n) in &g.reads {
        println!("# read {r:o} {n}");
    }
    for (r, n) in &g.writes {
        println!("# write {r:o} {n}");
    }
    for (v, n) in &g.vectors {
        println!("# vector {v:o} {n}");
    }
    for l in &dec {
        println!("{l}");
    }
    for (dir, seq, words) in &g.bufs {
        for (k, w) in words.iter().enumerate() {
            println!("CBUF {dir} {seq} {k:x} {w:x}");
        }
    }
    for l in &g.out {
        println!("{l}");
    }
    eprintln!(
        "iob: {} rows over {end} ns ({} ticks), {total_reads} reads and {total_writes} writes on \
         {} registers, {} cycles nothing answered, {} presses, {} moves, {} inits; \
         {dec_rows} decode rows and {dec_none_runs} empty runs over {UB_ADDRESSES} addresses",
        g.line,
        end / TICK_NS,
        g.reads.len(),
        g.unanswered,
        g.keys,
        g.moves,
        g.inits
    );
}
