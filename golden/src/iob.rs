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
    USEC_HIGH, USEC_LOW, answers, csr, mouse, usec_at,
};
use muir::serial;
use muir::terminal::mouse::MOUSE_STEP_NS;

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

        self.csr_seen.insert(c);
        self.x_seen.insert(x);
        self.y_seen.insert(y);
        self.buttons.insert(held);
        self.clock_ready_both[ready as usize] += 1;
        self.audio_both[audio as usize] += 1;
        if let Some(v) = intr {
            *self.vectors.entry(v).or_default() += 1;
        }
        format!(
            "{c:x} {x:x} {y:x} {held:x} {} {interval:x} {:x} {} {}",
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
                    self.slips += 1;
                    assert_eq!(
                        r, USEC_LOW,
                        "an answer off the 5 ns grid at a register the module does not expect: {r:o}"
                    );
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
    /// by writing the 2651 directly rather than over the bus: the chip is
    /// the serial slice's and only its `-RxRDY`/`-TxRDY` reaches this card.
    fn ser(&mut self, on: bool) {
        let now = self.now;
        self.b.advance(now);
        if on {
            // Asynchronous 16X, eight bits, one stop; the internal
            // transmit clock at rate 14; and the transmitter enabled in
            // normal mode. With nothing in the holding register `SR0` is
            // up, which is `-TxRDY`.
            self.b.serial.write(serial::MODE, 0o116, now);
            self.b.serial.write(serial::MODE, 0o56, now);
            self.b.serial.write(serial::COMMAND, serial::command::TX_ENABLE, now);
        } else {
            self.b.serial.write(serial::COMMAND, 0, now);
        }
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
    assert_eq!(g.vectors.len(), 3, "not every reachable vector was asked for");
    for v in [KBD_VECTOR, SERIAL_VECTOR, CLOCK_VECTOR] {
        assert!(g.vectors.contains_key(&v), "{v:o} was never asked for");
    }
    assert!(g.usec_high.len() >= 2, "the microsecond counter's high half never moved");
    assert!(g.sixty.len() >= 8, "the mains counter took {} values", g.sixty.len());
    assert!(g.clock_ready_both[0] > 0 && g.clock_ready_both[1] > 0, "CLOCK READY never moved");
    assert!(g.audio_both[0] > 0 && g.audio_both[1] > 0, "AUDIO never moved");
    assert!(g.unanswered >= 9, "too few cycles nothing answered");
    assert!(g.slips > 0, "no read landed off the grid, which the low half always does");
    assert_eq!(g.inits, 3, "the program made a different number of -UB INIT pulses");

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
    println!("# <face> = csr x y held clkrdy interval intr audio serrdy");
    println!("#     csr       the status register's flip-flops, before the floating byte");
    println!("#               and CLOCK READY are made up on a read");
    println!("#     x y       the two twelve-bit counters");
    println!("#     held      the switches as the mouse holds them, not as latched");
    println!("#     clkrdy    CLOCK READY, the interval timer's latch");
    println!("#     interval  what the interval timer was last loaded with");
    println!("#     intr      the Unibus vector the card is requesting, or 0");
    println!("#     audio     AUDIO, the beep's flip-flop");
    println!("#     serrdy    the serial port's -RxRDY or -TxRDY");
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
