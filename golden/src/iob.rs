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
//! - `CBL`, `CST`, `CLV`, `CTD`, `CLS`, `CRX` and `CTX`, the Chaosnet's far
//!   end: a frame on the line, its `START^`, the bits stored so far and the
//!   check over them, all before the card's receive gate; Transmit Done, a
//!   frame counted lost, a packet landing or bits stored, and the transmit
//!   buffer handed over (`Gen::far` and the rows' own notes).
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
//! **The grid, and the three places the card is not on it.** Every instant
//! the fabric can act at is a multiple of `TICK_NS`, and every answer here
//! is muir's `IoBoardTiming` under `TimingModel::Fpga`, which puts a
//! triggered delay on the grid from its own start and takes a free-running
//! edge at the first tick at or after it. The microsecond clock's edges are
//! at 890 + 1,000k, the keyboard and mouse group answers 1,250 ns after the
//! second edge past `-MSYN`, and the clocks and the GPIO answer 250 ns after
//! `-MSYN` itself: all on the grid. **Three are not on the board**:
//! `busint`'s `IOB_USEC_LOW_NS` is 313 ns past the edge, measured on the
//! netlist, so the board answers at 1,203 + 1,000k and the grid at 1,210;
//! the serial port's group answers 750 ns after a half-microsecond edge at
//! 203 + 500k; and the Chaosnet receive buffer answers 250 ns after an
//! `FCLK^` edge, a multiple of 125 and so off the grid on every odd one.
//! `slip` says how far the grid moved each such row rather than hiding it
//! in a tolerance, and nothing downstream sees it: `-LMACK` is 150 ns and
//! the MD strobe 100 ns past `-UB SSYN`, both on the grid, so a bus
//! interface counting from the tick it *sees* `-SSYN` lands where muir's
//! does.
//!
//! **The sixty-cycle counter is off the grid too, and it does not matter.**
//! `SIXTY_CYCLE_NS` is 1,000,000,000/60 = 16,666,666, which is not a
//! multiple of the grid, so most mains edges fall between ticks. A fabric
//! that counts nanoseconds by the tick and subtracts the period ---
//! `disk_unit`'s spindle trick --- increments at the first tick at or after
//! each edge, and the window in which it disagrees with `ns /
//! SIXTY_CYCLE_NS` is `[B, B + (TICK_NS - B mod TICK_NS))`, which contains
//! no tick at all. So the two agree at every instant the fabric can be
//! looked at, and the program reads the register at fourteen boundaries,
//! alternating between the last grid instant before one --- which must
//! still say `k-1` --- and the first at or after it, which must already say
//! `k`. A fabric that instead reloads a down-counter with a whole number of
//! ticks loses the remainder a period and is caught by the first of them.
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

mod chaos_state;

use chaos_state::{State, handed, state};
use muir::busint::{IOB_CHAOS_BUFFER_NS, IoBoardTiming, UNIBUS_STROBE_NS};
use muir::clock::{self, TimingModel};
use muir::ioboard::{
    self, BEEP, CLOCK, CLOCK_VECTOR, CSR, FIRST_USEC_EDGE_NS, GPIO, INTERVAL_TICK_NS, IoBoard,
    KB_CLK_NS, KBD_HIGH, KBD_LOW, KBD_VECTOR, MOUSE_X, MOUSE_Y, SERIAL_VECTOR, SIXTY_CYCLE_NS,
    SERIAL_FIRST, SERIAL_LAST, USEC_HIGH, USEC_LOW, answers, csr, mouse, usec_at,
};
use muir::chaos::board::Interface as ChaosInterface;
use muir::chaos::ether::{BUSY_ABORT_NS, Ether, RACT_NS};
use muir::chaos::interface::{self as chaos, csr as ccsr};
use muir::chaos::packet::{check_on, check_word, line as cells_of};
use muir::chaos::wire::CELL_NS;
use muir::clock::TimeBase;
use muir::serial;
use muir::terminal::keyboard::{self, RETURN, RUBOUT, all_keys_up, up_down};
use muir::terminal::mouse::MOUSE_STEP_NS;

/// The two switch bodies at LMMYNM D10 and D12, as this trace sets them.
/// `chaos::interface::switches` is how they are closed; what the fabric
/// takes is the word they read back, and it is a PORT of the card and not
/// a constant inside it, so a module ignoring it fails here.  Subnet 6,
/// host 0o101: a legal address --- muir's own default 0o177001 is subnet
/// 255, which traps in `RESET-ROUTING-TABLE` --- with both bytes
/// different and neither 0 nor 0o377.
const CHAOS_ADDRESS: u16 = 0o003101;
/// Another station's address, for a frame that goes nowhere: no cable is
/// plugged in.
const CHAOS_PEER: u16 = 0o003040;

/// MIT's grid, the master clock's period. Every instant the trace hands the
/// fabric is a multiple of this; `slip` says where the board's own is not.
/// muir's `clock::GRID_NS` is the grid its `fpga` timing model keeps, and
/// `main` asserts the two equal.
const TICK_NS: u64 = 10;

/// **How wide the card's own `-BOOT*` is**, which is the one thing about the
/// boot decode muir's behavioral board has no time for.  The comparator's
/// enable is `EOC.KBD^`, low while `KB CLK^` is low with the start marker at
/// `SR0`: the half clock before the rising edge that latches the word into
/// the 74LS374s and sets `KBD READY`.  So the pulse is half a keyboard clock
/// --- muir measures it on the netlist board in `tests/keyboard_boot.rs` ---
/// and the fabric, which takes a word as one strobe with no clock under it,
/// makes a pulse of that width at the instant the word lands.
const BOOT_PULSE_NS: u64 = KB_CLK_NS / 2;

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
    /// The card's answers on the grid, muir's `fpga` timing model: what the
    /// fabric is held to.
    io: IoBoardTiming,
    /// And on the board's own nanoseconds, only to say how far the grid
    /// moved each answer: the `slip` column.
    board: IoBoardTiming,
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
    sre_rows: u64,
    sout_rows: u64,
    spl_rows: u64,
    /// Instants of the far end's own that the grid cannot reach: the
    /// 2651's baud-rate crystal is 5.0688 MHz and the Chaosnet's turn timer
    /// runs on the I/O board's own 8 MHz, so neither lands on fives.
    far_slips: u64,
    /// Of [`Gen::slips`], the ones at the serial port's group.
    serial_slips: u64,
    /// WRITE BUFFERs and STARTs the transmitter's shift register held past
    /// their free answer, and of [`Gen::slips`] the ones among them.
    tsr_held: u64,
    tsr_slips: u64,
    /// Every Unibus ADDRESS a cycle was run at, which is not the same set as
    /// [`Gen::reads`]'s keys: those are the REGISTERS `answers` takes them
    /// to, and this card's two new groups have four aliases between them.
    addrs: BTreeSet<u32>,
    /// The `KBOOT` rows, and the words they pressed. Kept apart from
    /// [`Gen::keys`] and [`Gen::codes`] so that the assertions on those ---
    /// injective scan codes covering all twenty-four bits --- go on being
    /// about the words the keyboard section pressed.
    boot_rows: u64,
    boot_codes: BTreeSet<u32>,
    /// Of those rows, the ones muir's board answered with a request.
    boots: u64,
    // --- the Chaosnet line, as the far end says it (`chaos_state.rs`) ----
    /// The instant the last row's face was sampled at.
    last_row: u64,
    /// The far end's own instants are said up to here.
    far_upto: u64,
    /// The frame on the line as the rows have put it.
    on_line: Option<OnLine>,
    /// The bits stored so far and the check over them, as last said.
    lv: (usize, bool),
    /// The cells of the frame the last START made ready.
    sent: Option<Vec<bool>>,
    /// A cable is plugged in: the far end's instants are found on the board
    /// itself, a tick at a time, a copy having no cable.
    cable: bool,
    cst_rows: u64,
    clv_rows: u64,
    cls_rows: u64,
    cls_aborts: u64,
    stored_rows: u64,
    /// Rows inside a frame muir takes, where the levels are held to its
    /// face; reads of the buffer and the bit count inside a frame it does
    /// not take; and frames a clear dropped.
    taken_rows: u64,
    down_reads: u64,
    drops: u64,
    down_parts: u64,
    run_bits: u64,
}

/// The frame on the line, from its first edge to its idle, as the far end
/// says it: its `START^` if it has one --- under Loop Back the looped
/// frame's, off a cable the receiver's; a frame into the void, no cable and
/// no Loop Back, has none --- and its cells when they are this interface's
/// own.
struct OnLine {
    s: u64,
    start: Option<u64>,
    started: bool,
    cells: Option<Vec<bool>>,
}

/// The far end's events, in the order they are said at one instant.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Far {
    End,
    Start,
    Begin(u64, u16),
}

impl Gen {
    fn new() -> Gen {
        Gen {
            b: IoBoard::default(),
            io: IoBoardTiming::with_timing_model(TimingModel::Fpga),
            board: IoBoardTiming::with_timing_model(TimingModel::Cadr),
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
            sre_rows: 0,
            sout_rows: 0,
            spl_rows: 0,
            far_slips: 0,
            serial_slips: 0,
            tsr_held: 0,
            tsr_slips: 0,
            addrs: BTreeSet::new(),
            boot_rows: 0,
            boot_codes: BTreeSet::new(),
            boots: 0,
            last_row: 0,
            far_upto: 0,
            on_line: None,
            lv: (0, false),
            sent: None,
            cable: false,
            cst_rows: 0,
            clv_rows: 0,
            cls_rows: 0,
            cls_aborts: 0,
            stored_rows: 0,
            taken_rows: 0,
            down_reads: 0,
            drops: 0,
            down_parts: 0,
            run_bits: 0,
        }
    }

    /// Time passes. Monotonic, and always on the fabric's grid.
    fn at(&mut self, now: u64) {
        assert!(now >= self.now, "time runs backwards: {} to {now}", self.now);
        assert!(now % TICK_NS == 0, "{now} is not on the {TICK_NS} ns grid");
        self.now = now;
    }

    /// Time passes by `ns`, rounded up to the grid.
    fn wait(&mut self, ns: u64) {
        let t = grid_at(self.now + ns);
        self.at(t);
    }

    /// To the next instant at or after now whose place in the microsecond
    /// clock's period is `phase` nanoseconds. The edges are at 890 modulo
    /// 1,000, so `phase` 890 is an edge and 880 is a tick short of one;
    /// what the card's answer depends on is exactly this.
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
        let now = self.now;
        self.far(now);
        self.levels(now);
        self.row_raw(tag, ns, head);
    }

    /// A row as it stands, the far end's instants already said.
    fn row_raw(&mut self, tag: &str, ns: u64, head: String) {
        let n = self.line;
        self.line += 1;
        self.last_row = self.last_row.max(self.now);
        let face = self.face();
        self.say(format!("{tag} {n} {ns}{head} {face}"));
    }

    // --- the Chaosnet line, as the far end says it -----------------------
    //
    // **THE SEAM CARRIES THE CABLE'S FACTS AND THE CARD KEEPS ITS OWN GATE.**
    // A frame on the line from its first edge to its idle (`CBL`), its
    // `START^` (`CST`), and the bits the receiver would have stored so far
    // with whether the 9401 is non-zero over them (`CLV`), all before any
    // gate (`golden/src/chaos_state.rs`): the card takes Receive Done at
    // `START^` into its own `RACT`, takes it down at a clear, and shows the
    // line through it --- CRC Error the running check, the bit count the
    // bits stored. They are found on copies of the board, which keep the
    // turn timer's frames, and said at the first tick at or after each; the
    // levels wherever a row or a read looks inside a frame and they moved,
    // and held to muir's `csr()` and `bit_count()` there whenever muir's
    // receiver takes the frame.

    fn chaos(&self) -> &ChaosInterface {
        self.b.chaos.as_ref().expect("no Chaosnet interface is plugged in")
    }

    /// The far end's instants up to `upto`, each said as a row at the first
    /// tick at or after it, in their order.
    fn far(&mut self, upto: u64) {
        if !self.cable {
            self.far_events(upto);
            return;
        }
        // On a cable the board itself is taken a tick at a time, its frames
        // being the cable's, which a copy has not.
        let mut t = grid_at(self.far_upto + 1);
        while t <= upto {
            self.b.advance(t);
            self.far_events(t);
            t += TICK_NS;
        }
        self.far_events(upto);
    }

    /// The far end's instants up to `upto`, found on a copy taken there or,
    /// on a cable, on the board itself, which is there.
    fn far_events(&mut self, upto: u64) {
        while upto > self.far_upto {
            let lo = self.far_upto;
            let st = if self.cable {
                state(self.chaos())
            } else {
                let mut c = self.b.clone();
                c.advance(upto);
                state(c.chaos.as_ref().unwrap())
            };
            let mut next: Option<(u64, Far)> = None;
            let mut cand = |at: u64, ev: Far| {
                if next.is_none_or(|(t, e)| (at, ev) < (t, e)) {
                    next = Some((at, ev));
                }
            };
            if let Some(l) = &self.on_line {
                // A frame heard of late off a cable can have its `START^`
                // behind it already, which is said with it.
                if let Some(a) = l.start.filter(|_| !l.started).map(|a| a.max(lo + 1)).filter(|&a| a <= upto) {
                    cand(a, Far::Start);
                }
                let idle = match st.frames.iter().find(|f| f.0 == l.s) {
                    Some(f) => f.2,
                    None => self.idle_of(l.s, lo, upto),
                };
                if idle <= upto {
                    assert!(idle > lo, "the frame from {} went idle at {idle}, before {lo}", l.s);
                    cand(idle, Far::End);
                }
            }
            for &(s, source, idle) in &st.frames {
                let new = self.on_line.as_ref().is_none_or(|l| s > l.s);
                if new && s <= upto && idle > lo.max(s) {
                    // Off a cable the interface hears of a frame at the
                    // cable's next instant it is taken to, which can be a
                    // tick after the frame's first edge: until then its face
                    // has no frame on the line, and the frame is said where
                    // it has.
                    assert!(s > lo || lo == 0 || self.cable, "a frame from {s} on the line was never said, at {lo}");
                    cand(if s > lo { s } else { upto }, Far::Begin(s, source));
                }
            }
            let Some((at, ev)) = next else {
                self.far_upto = upto;
                break;
            };
            self.far_upto = at;
            self.say_far(at, ev);
        }
    }

    /// The largest instant in `[lo, hi]` at which a copy of the board still
    /// keeps the frame that began at `s`, and its idle there: where it went
    /// idle, the turn timer having let it go before it was looked at.
    fn idle_of(&self, s: u64, lo: u64, hi: u64) -> u64 {
        let has = |y: u64| {
            let mut c = self.b.clone();
            c.advance(y);
            state(c.chaos.as_ref().unwrap()).frames.iter().find(|f| f.0 == s).map(|f| f.2)
        };
        let (mut a, mut b) = (lo, hi);
        let mut best = has(lo).expect("the frame on the line was gone before it was last looked at");
        while a < b {
            let m = a + (b - a).div_ceil(2);
            match has(m) {
                Some(i) => {
                    a = m;
                    best = i;
                }
                None => b = m - 1,
            }
        }
        best
    }

    /// One of the far end's instants, as its row.
    fn say_far(&mut self, at: u64, ev: Far) {
        let g = grid_at(at);
        if g != at {
            self.far_slips += 1;
        }
        let keep = self.now;
        self.now = g;
        match ev {
            Far::Begin(s, source) => {
                let loop_back = state(self.chaos()).loop_back();
                let start = (loop_back || self.cable).then_some(s + RACT_NS);
                let cells = (source == CHAOS_ADDRESS).then(|| self.sent.clone()).flatten();
                self.on_line = Some(OnLine { s, start, started: false, cells });
                self.levels(g);
                self.cbl_rows += 1;
                self.row_raw("CBL", g, " 1".into());
            }
            Far::Start => {
                self.on_line.as_mut().unwrap().started = true;
                self.levels(g);
                self.cst_rows += 1;
                self.row_raw("CST", g, String::new());
            }
            Far::End => {
                self.on_line = None;
                self.cbl_rows += 1;
                self.row_raw("CBL", g, " 0".into());
            }
        }
        self.now = keep.max(g);
    }

    /// The levels at `x`, said if they moved, with the board taken there:
    /// and wherever muir takes the frame, held to its face.
    fn levels(&mut self, x: u64) {
        let Some(l) = &self.on_line else { return };
        if x < l.s {
            return;
        }
        let cells = l.cells.clone();
        self.b.advance(x);
        let c = self.chaos();
        let st = state(c);
        if st.frame_now(x).is_none() {
            return;
        }
        let k = st.stored(c, x, TimeBase::NS);
        let nz = st.check_nz(c, x, TimeBase::NS, cells.as_deref());
        if st.taking(c, x) && !st.rdone {
            assert_eq!(c.bit_count() as usize, k % 4096, "the bit count at {x}, a frame taken");
            let down = st.down_here(x).is_some_and(|(_, _, check)| check != 0);
            assert_eq!(c.csr() & ccsr::CRC_ERROR != 0, st.crc || nz || down, "CRC Error at {x}, a frame taken");
            self.taken_rows += 1;
        }
        if (k, nz) != self.lv {
            self.lv = (k, nz);
            self.clv_rows += 1;
            self.row_raw("CLV", x, format!(" {:x} {}", k % 4096, u8::from(nz)));
        }
    }

    /// To `t` with the far end's instants up to it said: a row after a run of
    /// the line the program waited through.
    fn settle(&mut self, t: u64) {
        self.far(t);
        self.at(t.max(self.now));
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
                // The answer on the grid is muir's own, `IoBoardTiming` under
                // `TimingModel::Fpga`; the board's is only to say how far the
                // grid moved it, and that it moved it UP to the first tick.
                // **Cycles run one after another**, `answer_cycle`: a WRITE
                // BUFFER or a START is held while the transmitter's shift
                // register is busy with the last (muir's `37cf490`).
                let free = self.io.answer(r, write, msyn);
                let ssyn = self.io.answer_cycle(r, write, msyn);
                let exact = self.board.answer_cycle(r, write, msyn);
                if ssyn != free {
                    assert!(ssyn > free, "a held answer came before the free one at {r:o}");
                    self.tsr_held += 1;
                }
                assert!(exact > msyn, "the card answered at or before -MSYN");
                assert_eq!(ssyn % TICK_NS, 0, "muir's fpga model answered off the grid at {r:o}");
                assert_eq!(ssyn, grid_at(exact), "the grid is not the board's answer rounded up at {r:o}");
                let slip = ssyn - exact;
                if slip != 0 {
                    // **FOUR REGISTERS ANSWER OFF THE GRID AND NO OTHERS.**  The
                    // microsecond counter's low half takes `IOB_USEC_LOW_NS` =
                    // 313 past its edge; EVERY address of the serial port's
                    // group answers 750 ns after a half-microsecond clock whose
                    // phase `busint::IOB_HALF_USEC_PHASE_NS` measures at 203 ---
                    // so 953 + 500k, which is 3 modulo 10; and the Chaosnet
                    // receive buffer answers 250 ns after an `FCLK^` edge, which
                    // is a multiple of 125 and so off the grid on every odd
                    // one, and so do the transmit buffer's write and START
                    // when the shift register held them, 350 ns after its
                    // `TSREMPTY`, which is an `FCLK^` edge and 2,000 ns a
                    // word.  All are counted apart, and rounding UP is the same
                    // argument in each place: a register can only be read at a
                    // grid instant, so nothing falls between the board's answer
                    // and the tick.
                    self.slips += 1;
                    if (SERIAL_FIRST..=SERIAL_LAST).contains(&r) {
                        self.serial_slips += 1;
                        assert_eq!(slip, 7, "the serial port's answer is not seven short of a tick");
                    } else if r == USEC_LOW {
                        assert_eq!(slip, 7, "the counter's low half is not seven short of a tick");
                    } else if ssyn != free && (r == chaos::START || (r == chaos::WRITE_BUFFER && write)) {
                        self.tsr_slips += 1;
                        assert_eq!(slip, 5, "a held transmit buffer answer is not five short of a tick");
                    } else {
                        assert_eq!(
                            r, chaos::READ_BUFFER,
                            "an answer off the grid at a register the module does not expect: {r:o}"
                        );
                        assert_eq!(slip, 5, "the receive buffer's answer is not five short of a tick");
                    }
                }
                // The counter's low half is the count as it stood at
                // `-MSYN`; everything else is read or written at `-SSYN`.
                let made = if r == USEC_LOW { msyn } else { ssyn };
                // The far end's instants before the tick the cycle lands
                // in, with the faces they had before it; those at that tick
                // and after carry it.
                self.far(made - TICK_NS);
                self.landed = ssyn;
                self.b.advance(made);
                if (chaos::CSR..=0o764156).contains(&r) {
                    let st = state(self.chaos());
                    let inside = st.frame_now(made).is_some() && !st.rdone;
                    // **NEVER THE BUFFER WHILE muir's RECEIVER TAKES A
                    // FRAME**: muir does not model that read
                    // (`Interface::read_down`), so a row of it would hold the
                    // card to an artefact.
                    if r == chaos::READ_BUFFER && !write && inside {
                        assert!(!st.taking(self.chaos(), made), "the program read the buffer at {made}, a frame taken");
                        self.down_reads += 1;
                    }
                    if r == chaos::BIT_COUNT && !write && inside && !st.taking(self.chaos(), made) {
                        self.down_reads += 1;
                    }
                }
                if write {
                    *self.writes.entry(r).or_default() += 1;
                    self.b.write(uaddr, wdata, made);
                } else {
                    *self.reads.entry(r).or_default() += 1;
                    rdata = self.b.read(uaddr, made);
                    if r == chaos::START {
                        self.sent = Some(cells_of(&ready_line(&self.b)));
                    }
                    // A count-down's word read where the check of every bit
                    // read and the check of that word alone part: what
                    // tells a check carried from read to read from one
                    // begun again at each.
                    if r == chaos::READ_BUFFER {
                        let s = state(self.chaos());
                        if let Some((_, hw, check)) = s.down_here(made)
                            && hw % 16 == 15
                            && hw != 0o7777
                            && (check == 0) != (check_on(0, &[rdata]) == 0)
                        {
                            self.down_parts += 1;
                        }
                    }
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
                // The levels at the tick the cycle lands in, with its face:
                // the card's at that tick is after the cycle.
                self.levels(made);
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

    /// A word off the keyboard's pair that the card is asked to DECODE: the
    /// same press, with what the 25LS2521 at IOBCSR 0A20 made of it beside
    /// it.
    ///
    /// **The request fires at the instant the word arrives**, which is what
    /// `IoBoard::press` does: it sets `KBD READY` and, for a word the
    /// comparator matches, raises the request `IoBoard::take_boot` hands out
    /// once.  The board's own `-BOOT*` is a pulse ENDING on that edge, the
    /// comparator's enable being the half clock of `KB CLK^` before it, and
    /// the model has no time for that half clock: what it and the fabric
    /// must agree on is the instant the word lands and whether the card
    /// asked.  The pulse's width is the card's and is stated in the header
    /// as `boot_pulse_ns`.
    ///
    /// `expect` is what the row is FOR --- the program says what each word
    /// should do and the model is asked whether it agrees --- so a muir that
    /// changed its decode fails here rather than writing a new trace.
    fn key_boot(&mut self, code: u32, expect: bool, why: &str) {
        let now = self.now;
        self.b.advance(now);
        self.b.press(code);
        let boot = self.b.take_boot();
        assert_eq!(boot, expect, "{why}: {code:o} decodes as {boot}, the program wanted {expect}");
        assert!(!self.b.take_boot(), "{why}: the request was handed out twice");
        assert!(self.b.keyboard_ready(), "{why}: the word did not reach the register");
        self.boot_rows += 1;
        self.boots += u64::from(boot);
        self.boot_codes.insert(code);
        self.row("KBOOT", format!(" {code:x} {}", u8::from(boot)));
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
        self.far(now);
        self.levels(now);
        self.b.advance(now);
        self.b.unibus_init();
        self.inits += 1;
        self.row("INIT", String::new());
        // `-UB INIT` takes Loop Back off with the CSR, and a frame looped
        // back is over for the receiver at once (muir's `reset_from`).
        if self.on_line.is_some() && state(self.chaos()).frame_now(now).is_none() {
            self.say_far(now, Far::End);
        }
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
    /// on the grid.  Rounding UP is the argument
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
        // START --- a tick of the board, the seam's own rate and not MIT's
        // --- so 256 words is 256 ticks, and the assertion waits for the
        // longest one there is and 144 ticks more rather than for this one.
        self.wait(400 * TICK_NS);
        let seq = self.ctx_rows;
        self.ctx_rows += 1;
        self.bufs.push((1, seq, words.to_vec()));
        self.row("CTX", format!(" {seq} {}", words.len()));
    }

    /// A packet lands in the receive buffer at this instant: `bits` is what
    /// the bit counter is loaded with, `crc` the check word's verdict, and
    /// `seq` names the words. With `store` the far end hands the bits to be
    /// stored and not landed: a frame taken and not for this interface, or
    /// what a clear left of a frame it dropped. A run of 48 bits or fewer is
    /// handed without it, and the card judges it by its length. Stimulus.
    fn crx(&mut self, at: u64, bits: u64, crc: bool, store: bool, words: &[u16]) {
        // The far end's instants before it, said first; the words stream in
        // on the ticks before the row, where nothing else may be.
        let g = grid_at(at);
        self.far(g - TICK_NS);
        assert!(
            self.line == 0 || self.last_row + (words.len() as u64 + 1) * TICK_NS < g,
            "a row at {} inside the stream of {} words landing at {g}",
            self.last_row,
            words.len()
        );
        self.far_at(at);
        let seq = self.crx_rows;
        self.crx_rows += 1;
        self.stored_rows += u64::from(store);
        self.bufs.push((0, seq, words.to_vec()));
        let now = self.now;
        // The line as it stands at the row, before the far end's instants
        // there, which come after it: a frame landing goes idle with it.
        let busy = state(self.chaos()).frame_now(now).is_some();
        self.row_raw(
            "CRX",
            now,
            format!(" {seq} {bits:x} {} {} {} {}", words.len(), u8::from(crc), u8::from(busy), u8::from(store)),
        );
        self.far(now);
        self.levels(now);
    }

    /// The bits muir's buffer took without Receive Done since `before`, as
    /// the far end hands them to be stored: at `at`, or after the row before
    /// it with room for their stream, so that after a drop nothing comes
    /// between the clear and the end of the stream.
    fn stored(&mut self, at: u64, before: &State) {
        // The far end's instants up to it first --- the line going idle as
        // the frame is stored --- so that the stream has room after them.
        self.far(grid_at(at));
        let mut c = self.b.clone();
        c.advance(at);
        let st = state(c.chaos.as_ref().unwrap());
        assert!(!st.rdone && places(&st) != places(before), "nothing was stored to hand over");
        let words = handed(&st.rcv, st.bits);
        // Room for the stream after the row before it, and two ticks more:
        // a mutating row is placed a tick on, and a Reset's `chaos_reset`
        // is up the tick after it, when the far end takes nothing.
        let at = at.max(self.last_row + (words.len() as u64 + 5) * TICK_NS);
        self.crx(at, st.bits, false, true, &words);
        assert_eq!(handed_now(&self.b), (words, st.bits), "the bits stored moved before they were handed over");
    }

    /// Transmit Done off the far end, with or without an abort.  Stimulus.
    fn ctd(&mut self, at: u64, abort: bool) {
        self.far_at(at);
        self.ctd_rows += 1;
        self.row("CTD", format!(" {}", u8::from(abort)));
    }

    /// A frame the far end counted lost, the buffer full at its `START^`:
    /// its destination word went by, `BUSY_ABORT_NS` into it, with `RACT`
    /// off.  `chaos_rx_lost`; and `abort`, a frame of this interface's to its
    /// own address, whose Transmit Abort the busy receiver sets there,
    /// Transmit Done `TDONE_AFTER_ABORT_NS` on (muir's `busy_looped`).
    /// Stimulus.
    fn cls(&mut self, at: u64) {
        self.far_at(at);
        self.cls_rows += 1;
        let now = self.now;
        // The far end's instants before it said with their own faces first.
        self.far(now);
        self.b.advance(now);
        let s = state(self.chaos());
        let abort = s.tabort && !s.tdone;
        self.cls_aborts += u64::from(abort);
        self.row("CLS", format!(" {}", u8::from(abort)));
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

    /// The received frame's own end --- `Pci::rx_times`' SECOND instant,
    /// the last stop bit over --- where the first is the `SRX` row.  It is
    /// what the echoing modes put the echoed character on the cable at, so
    /// a seam carrying only `SRX` could not place the echo and the card
    /// could not have the two modes.  Stimulus.
    ///
    /// **The instant is read off the cable rather than computed**, because
    /// `Pci::rx_times` is muir's own and private: the character the echo
    /// puts on the cable carries exactly this time, so `Gen::taken` is where
    /// it comes from and there is no second arithmetic to get wrong.
    fn sre(&mut self, at: u64) {
        self.far_at(at);
        self.sre_rows += 1;
        self.row("SRE", String::new());
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
    /// **It steps to just past the offending clock rather than by a fixed
    /// amount.**  Stepping by 500 ns and giving up after sixteen tries was a
    /// search for a window about 150 ns wide in a period of about 3,150, and
    /// whether it found one depended on the phase the rest of the program
    /// happened to leave: adding four bus cycles anywhere earlier made it
    /// fail.  The next clock after a clock is a whole period away, which is
    /// wider than any `room` this program asks for, so one step is enough
    /// and the bound is there to fail rather than hang.
    fn before_16x(&mut self, room: u64) {
        for _ in 0..4 {
            let now = self.now;
            let c = self.b.serial.clock_at_or_after(now);
            if c >= now + room {
                return;
            }
            self.at(grid_at(c + TICK_NS));
        }
        panic!("no gap in the 2651's 16X clock");
    }

    /// Whatever the port has put on the cable by now, taken off it in the
    /// order it arrived: each character and the instant its last stop bit
    /// ended.  `Cable::take` is the far end taking them, which is what a far
    /// end does.
    fn taken(&mut self) -> Vec<(u64, u8)> {
        let mut got: Vec<(u64, u8)> = Vec::new();
        while let Some(p) = self.b.serial.cable.take() {
            got.push(p);
        }
        got.sort_by_key(|&(t, _)| t);
        got
    }

    /// The same, each as a `SOUT` row where it ended.
    fn drain_serial(&mut self) {
        for (t, byte) in self.taken() {
            self.sout(t, byte);
        }
    }
}

/// When the far end next does something, found on a COPY: `IoBoard::advance`
/// mutates, and `chaos::board::Interface` copies its registers and not its
/// cable, which is exactly what a probe wants.  Coarse to 500 ns and then to
/// the nanosecond, because the predicate is not monotone over a whole run and
/// a bisection would land on the wrong edge.  The predicate is given the
/// copy and the instant it was taken to.
fn when_t(b: &IoBoard, from: u64, limit: u64, f: &dyn Fn(&IoBoard, u64) -> bool) -> u64 {
    const STEP: u64 = 500;
    let mut t = from;
    while t <= from + limit {
        let mut c = b.clone();
        c.advance(t);
        if f(&c, t) {
            let mut u = if t > from + STEP { t - STEP } else { from };
            while u < t {
                let mut c2 = b.clone();
                c2.advance(u);
                if f(&c2, u) {
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

fn when(b: &IoBoard, from: u64, limit: u64, f: &dyn Fn(&IoBoard) -> bool) -> u64 {
    when_t(b, from, limit, &|c, _| f(c))
}

fn st(b: &IoBoard) -> State {
    state(b.chaos.as_ref().expect("no Chaosnet interface is plugged in"))
}

/// The incoming buffer by its places, `RBCT / 16`, rather than in the order
/// a frame in it is read: what a frame stored over it changes. Never
/// written, all ones.
fn places(s: &State) -> Vec<u16> {
    if s.rcv.is_empty() {
        return vec![0o177777; 256];
    }
    let top = (s.bits as usize + 4095) % 4096 / 16;
    (0..256).map(|p| s.rcv[(top + 256 - p) % 256]).collect()
}

/// **The next frame the turn timer puts on the line from `from`**, found on
/// copies: its first edge and the idle it was put there with. The turn
/// timer keeps a frame from the terminal count that launches it, its first
/// edge `TURN_START_NS` on.
fn next_frame(b: &IoBoard, from: u64) -> (u64, u64) {
    let t = when(b, from, 2_000_000, &|c| st(c).frames.iter().any(|f| f.0 >= from));
    let mut c = b.clone();
    c.advance(t);
    let s = st(&c);
    let f = s.frames.iter().find(|f| f.0 >= from).unwrap();
    (f.0, f.2)
}

/// When the line goes idle after the frame that began at `s`: the frame
/// gone from the turn timer's reckoning, found on copies.
fn idle_after(b: &IoBoard, s: u64) -> u64 {
    when_t(b, s, 2_000_000, &|c, t| st(c).frame_now(t).is_none_or(|f| f.0 != s))
}

/// **An empty START's frame as the far end times it** (muir's
/// `an_empty_start_lowers_transmit_done_until_its_frame_ends`, held to the
/// netlist board): on the line from its first edge, Transmit Done back
/// `TDONE_BEFORE_END_NS` before its nominal end, the line idle after it.
/// `t` is the instant START was read. Under Loop Back its 32 bits are a run
/// no receiver lands, which leaves them in the buffer.
fn empty_frame(g: &mut Gen, t: u64) -> u64 {
    let (s, _) = next_frame(&g.b, t);
    let td = when(&g.b, s, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    let idle = idle_after(&g.b, s);
    g.settle(grid_before(grid_at(idle)).max(g.now));
    assert_eq!(cs(&g.b) & ccsr::RECEIVE_DONE, 0, "an empty frame landed as a packet");
    idle
}

/// To the first microsecond from now at which a START would put its frame
/// on the line no sooner than `gap` after its answer: found on copies, as
/// [`when`] finds the far end's instants.
fn quiet_turn(g: &mut Gen, gap: u64) {
    for _ in 0..1_000 {
        let mut b = g.b.clone();
        let mut io = g.io.clone();
        let a = io.answer_cycle(chaos::START, false, g.now);
        b.advance(a);
        b.read(chaos::START, a);
        let (busy, _) = next_frame(&b, a);
        if busy >= a + gap {
            return;
        }
        g.wait(1_000);
    }
    panic!("no START within a millisecond leaves {gap} ns before its turn");
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

/// The frame the last START made ready: what the card must hand the far
/// end, the source and the check word in it (`Turn::save`: the words written
/// when the frame is a frame of them, its source and check word to be made
/// again; otherwise the line itself and 512 words more).
fn ready_line(b: &IoBoard) -> Vec<u16> {
    let mut v = st(b).ready.expect("START made a frame ready");
    if v.len() >= 512 {
        v.truncate(v.len() - 512);
    } else {
        v.push(CHAOS_ADDRESS);
        v.push(check_word(&v));
    }
    v
}

/// The frame in the buffer as the far end hands it to the card
/// (`chaos_state::handed`), and its bits.
fn handed_now(b: &IoBoard) -> (Vec<u16>, u64) {
    let s = st(b);
    (handed(&s.rcv, s.bits), s.bits)
}

/// **START READ NOW UNDER LOOP BACK, AND WHAT THE FAR END DOES WITH IT.**
/// The frame the card must hand over, as muir's transmit buffer plays it
/// out; the cable's instants for it, or for a frame of nothing only
/// Transmit Done; and what comes back.  A frame of more than 48 bits lands
/// as a `CRX` row, its words as the far end hands them; a run of 48 bits or
/// fewer lands nowhere (muir's `arrive`) and leaves its bits in the buffer,
/// handed to the card as the line goes idle, which it must store and not
/// land.  The bits that landed, if any did.
fn loop_start(g: &mut Gen) -> Option<u64> {
    let t = g.now;
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    let line = ready_line(&g.b);
    g.ctx(&line);
    if line.is_empty() {
        // Nothing goes: Transmit Done `EMPTY_TDONE_NS` after the turn, the
        // line never busy.
        let td = when(&g.b, t, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
        g.ctd(td, false);
        assert_eq!(cs(&g.b) & (ccsr::CRC_ERROR | ccsr::RECEIVE_DONE), 0, "a frame of nothing was on the line");
        assert!(st(&g.b).frames.iter().all(|f| f.0 < t), "a frame of nothing went on the line");
        return None;
    }
    let (s, _) = next_frame(&g.b, t);
    let td = when(&g.b, s, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    let bits = 16 * line.len() as u64;
    let land = idle_after(&g.b, s);
    if bits > 48 {
        assert_eq!(land, when(&g.b, td, 1_000_000, &|b| cs(b) & ccsr::RECEIVE_DONE != 0), "the frame landed off its idle");
        let mut c = g.b.clone();
        c.advance(land);
        let crc = cs(&c) & ccsr::CRC_ERROR != 0;
        let words = read_out(&g.b, land, line.len());
        assert_eq!(words, line, "the frame did not come back as it went");
        g.crx(land, bits, crc, false, &words);
        Some(bits)
    } else {
        hand_back_run(g, land, &line);
        None
    }
}

/// A run of 48 bits or fewer the card's own frame made, handed to it as the
/// line goes idle at `land`: no receiver lands it, so Receive Done, Lost
/// Count and CRC Error stay where they were; with Receive Done down its bits
/// go into the buffer as they came, as muir's do.
fn hand_back_run(g: &mut Gen, land: u64, line: &[u16]) {
    assert!(line.len() <= 3);
    let before = cs(&g.b);
    let was = st(&g.b);
    g.settle(grid_before(grid_at(land)).max(g.now));
    g.crx(land, 16 * line.len() as u64, false, false, line);
    let now = st(&g.b);
    assert_eq!(cs(&g.b) & !ccsr::CRC_ERROR, before & !ccsr::CRC_ERROR, "a run of {} bits moved the interface", 16 * line.len());
    if !now.rdone {
        assert_eq!(handed(&now.rcv, now.bits), line, "the run's bits are not what the buffer took");
        assert!(was.rdone || now.bits == 16 * line.len() as u64);
    }
}

/// The buffer read `reads` times, each read with the bit count before it
/// and the CSR after it, as muir's `read_round` reads the netlist board:
/// round the buffer past the frame's end, CRC Error the check of the words
/// read so far.
fn read_round(g: &mut Gen, reads: usize) {
    let mut words = Vec::new();
    for k in 0..reads {
        g.read(chaos::BIT_COUNT);
        words.push(g.read(chaos::READ_BUFFER));
        let v = g.read(chaos::CSR);
        assert_eq!(v & ccsr::CRC_ERROR != 0, check_word(&words) != 0, "CRC Error after read {k}");
    }
}

/// A read of the buffer with Receive Done down and the line idle: the read
/// register shifted once, the buffer's bit at `RBCT` 0 coming in at the
/// bottom (muir's `Interface::read_down`).
fn idle_read(g: &mut Gen) -> u16 {
    let s = st(&g.b);
    assert!(!s.rdone, "an idle read with a packet in the buffer");
    let want = s.rd << 1 | u16::from(s.ram_bit(0));
    let v = g.read(chaos::READ_BUFFER);
    assert_eq!(v, want, "a read with Receive Done down, the line idle");
    v
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
    assert_eq!(TICK_NS, clock::GRID_NS, "the trace's grid is not the one muir's fpga model keeps");
    assert_eq!(UNIBUS_STROBE_NS % TICK_NS, 0);
    // The derivation at the top: the mains counter's boundaries lie off the
    // grid but never inside a tick the fabric can be looked at.
    assert_ne!(SIXTY_CYCLE_NS % TICK_NS, 0);

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
    // hardware synchronizes only if the low half is read first.
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
    // that microsecond. Every one of the instants the fabric can raise
    // `-MSYN` at inside a microsecond is used --- a hundred at the 10 ns
    // grid --- at three registers: one that waits two edges, one that waits
    // one, and one that waits none.
    // ------------------------------------------------------------------
    let instants = 1_000 / TICK_NS;
    g.wait(5_000);
    for k in 0..instants {
        // 61 is prime and divides no power of ten, so this reaches them all.
        let phase = TICK_NS * ((k * 61) % instants);
        g.at_phase(phase);
        g.read(CSR);
        g.at_phase(phase);
        g.read(USEC_LOW);
        g.at_phase(phase);
        g.read(CLOCK);
    }
    assert_eq!(g.phases.len() as u64, instants, "the phase sweep missed one: {} seen", g.phases.len());

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
    // 65,535,890 ns from power-on. Read the low half a tick
    // before it and the high half well after: the latch must still be the
    // count from before the carry.
    let carry = FIRST_USEC_EDGE_NS + 65_536 * 1_000 - 1_000;
    assert_eq!(usec_at(carry), 65_536);
    assert_eq!(usec_at(carry - TICK_NS), 65_535);
    g.at(carry - TICK_NS);
    let lo = g.read(USEC_LOW);
    assert_eq!(lo, 0xFFFF, "the low half a tick before the carry");
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
    // long and the two grid instants that straddle a boundary are a tick
    // apart: both sides of one boundary cannot be read. Alternating gives
    // the same bound from the two directions --- a boundary read a tick
    // early must still say k-1, so a period a nanosecond short is caught by
    // the k'th of them once k exceeds a tick's nanoseconds; a boundary read at
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
    // The cable, the turn timer and the receiver's verdict on a frame are
    // the `cadr-chaosnet` program's; under Loop Back muir's own interface
    // plays that far end and its instants are recorded as `CBL`, `CST`,
    // `CLV`, `CTD`, `CLS` and `CRX` rows for the fabric's seam.  Everything the software reads ---
    // the CSR's ten made-up bits, the bit counter's arithmetic, the read
    // buffer's pointer, the lost count, the two buffers going round, the
    // check word the card makes and the check of the read-out --- is the
    // card's own and is compared.
    // ------------------------------------------------------------------
    g.wait(5_000);

    // Every register of the group read once before anything is written.
    // NOT `764152`, which is START and would launch the empty buffer.
    assert_eq!(g.read(chaos::CSR), ccsr::TRANSMIT_DONE, "the Chaosnet CSR at power-on");
    assert_eq!(g.read(chaos::MY_ADDRESS), CHAOS_ADDRESS, "the address switches at LMMYNM");
    // A read of the buffer with no packet shifts the read register: the
    // buffer's bit at `RBCT` 0, never written, is 1 (muir's `read_down`).
    assert_eq!(g.read(chaos::READ_BUFFER), 1, "the read buffer with no packet in it");
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
    // written, in order, then the source and the check word, which the
    // board's 9401 makes.  The check collects them off the seam and
    // compares here.
    let line = ready_line(&g.b);
    assert_eq!(&line[..packet.len()], &packet[..], "the frame is not the words written");
    assert_eq!(line[packet.len()..], [CHAOS_ADDRESS, check_word(&line[..=packet.len()])], "the trailer");
    g.ctx(&line);
    let (busy_on, idle) = next_frame(&g.b, t0);
    let tdone = when(&g.b, busy_on, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    let landed = when(&g.b, busy_on, 1_000_000, &|b| cs(b) & ccsr::RECEIVE_DONE != 0);
    assert!(busy_on < tdone && tdone < landed, "the far end's three instants are out of order");
    assert_eq!(landed, idle, "Receive Done is not the line going idle");
    // **CRC ERROR AND THE BIT COUNT WHILE THE FRAME COMES IN** (muir's
    // `40b86d1` and `4647f6b`, measured on the netlist board): CRC Error is
    // the receive check register, the 9401 at LMRBUF 0C07, over the bits
    // stored so far, and the bit count is `RBCT`, those bits, stepping
    // `RACT_NS` after each cell's opening edge. Read at cells spread across
    // the frame and at phases across a cell, from before `START^` on; never
    // the buffer, which muir does not model while its receiver takes a
    // frame.
    let mut crc_both = [0u32; 2];
    let mut counts = BTreeSet::new();
    for k in 0..8u64 {
        g.at(grid_at(busy_on + 3_300 * k + 40 * k).max(g.now));
        let v = g.read(chaos::CSR);
        assert_eq!(v & ccsr::RECEIVE_DONE, 0, "the packet landed before the line was idle");
        crc_both[usize::from(v & ccsr::CRC_ERROR != 0)] += 1;
        counts.insert(g.read(chaos::BIT_COUNT));
    }
    assert!(crc_both[0] > 0 && crc_both[1] > 0, "CRC Error inside the frame never moved: {crc_both:?}");
    assert!(counts.len() >= 6, "the bit count inside the frame: {counts:?}");
    g.ctd(tdone, false);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(0o270), "Transmit Done asked for nothing");
    // The packet lands, and `RDONE` rises with the line going idle: the
    // busy one-shot's fourth `FCLK^` rise after the last edge, 250 or 375
    // ns after the frame's nominal end by its last bit (muir's `2b1b0b4`).
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

    // --- frames on a buffer nobody emptied: the lost count ---------------
    //
    // Receive Done still stands, so at each frame's `START^` `RACT` takes it
    // and stays off: nothing of the frame is stored, and as its destination
    // word goes by, `BUSY_ABORT_NS` in, the busy receiver's gates find
    // `-RACT` up (muir's `4647f6b`, `busy_looped`, measured on the netlist
    // board under Loop Back). Lost Count steps for `DEST MATCH` --- this
    // address, zero, or Spy --- and a frame to this address by name is
    // aborted, Transmit Done `TDONE_AFTER_ABORT_NS` on with Transmit Abort:
    // three to this interface, a broadcast counted and not aborted, and
    // another station's neither.
    g.wait(2_000);
    for (k, dest) in [CHAOS_ADDRESS, CHAOS_ADDRESS, CHAOS_ADDRESS, 0, CHAOS_PEER].into_iter().enumerate() {
        let one: Vec<u16> = vec![0o070707 ^ k as u16, dest];
        let t = g.now;
        for w in &one {
            g.write(chaos::WRITE_BUFFER, *w);
        }
        assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
        let line = ready_line(&g.b);
        g.ctx(&line);
        let (s, _) = next_frame(&g.b, t);
        let lost_before = (cs(&g.b) & ccsr::LOST_COUNT) >> 9;
        let counted = dest != CHAOS_PEER;
        if counted {
            let lost = when(&g.b, s, 1_000_000, &|b| (cs(b) & ccsr::LOST_COUNT) >> 9 != lost_before);
            assert_eq!(lost, s + BUSY_ABORT_NS, "the busy receiver counted off the destination word");
            g.cls(lost);
        }
        let td = when(&g.b, s, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
        let mut c = g.b.clone();
        c.advance(td);
        let abort = cs(&c) & ccsr::TRANSMIT_ABORT != 0;
        assert_eq!(abort, dest == CHAOS_ADDRESS, "Transmit Abort for a frame to {dest:o}");
        g.ctd(td, abort);
        let idle = idle_after(&g.b, s);
        g.settle(grid_at(idle));
        let v = g.read(chaos::CSR);
        let want = lost_before + u16::from(counted);
        assert_eq!((v & ccsr::LOST_COUNT) >> 9, want, "the lost count for a frame to {dest:o} the buffer had no room for");
        assert_eq!(v & ccsr::RECEIVE_DONE, ccsr::RECEIVE_DONE);
    }
    // The first packet is still what the buffer holds: a lost frame does
    // not disturb it.  The pointer is at the end, so the count is `7777`.
    assert_eq!(g.read(chaos::BIT_COUNT), 0o7777, "a lost frame moved the buffer's pointer");

    // Past the end the reads GO ROUND THE BUFFER (muir's `ebb3c41`, measured
    // on the netlist board): nothing stops RBCT at the packet's end, so it
    // keeps coming down sixteen a read in twelve bits past `7777`, and the
    // words are what the buffer holds there --- never written, what the
    // netlist's RAM reads as, all ones --- and from read 256 the packet
    // again.  520 reads past a packet of eight words, round the buffer
    // twice, with the count after each.
    let mut all = words.clone();
    for k in 0..520usize {
        all.push(g.read(chaos::READ_BUFFER));
        let left = (bits as usize + 4096 - 16 * ((k + words.len() + 1) % 256)) % 4096;
        assert_eq!(usize::from(g.read(0o764156)), (left + 4095) % 4096, "the bit count {k} reads past the packet");
    }
    for k in 0..all.len() - 256 {
        assert_eq!(all[k + 256], all[k], "read {} is not read {k} round the buffer", k + 256);
    }
    assert_eq!(all[words.len()], 0o177777, "never written, the buffer reads as ones");

    // --- Timer Interrupt Enable reaches no gate, and this is the check --
    //
    // AIM-628 calls bit 0 "Timer Interrupt Enable ... for the interval timer
    // present in SOME VERSIONS of the interface", and `data/CADRIO.netlist`
    // says this is not one of them: `TIMER.IEN` has exactly two pins on the
    // whole board, the Q of the 74LS174 at LMUCON 0B20 a CSR write loads and
    // the input of the 74LS244 at LMDATP 0D16 that reads it back, and
    // `CHAOS.IREQ` is the 74S51 at LMUCON 0E05 computing `(RDONE AND RIEN)
    // OR (TDONE AND TIEN)` with no third term.  muir's
    // `Interface::interrupt_request` is those two terms and no more.
    //
    // So the bit is set here with **both done bits up and both interrupt
    // enables clear**, which is the one arrangement in which a card that let
    // the timer enable reach the gate asks for `0o270` where this one asks
    // for nothing.  Without it, "the bit reaches no gate" would be an
    // absence rather than a claim.
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, ccsr::RECEIVE_DONE, "Receive Done is down for the timer");
    assert_eq!(v & ccsr::TRANSMIT_DONE, ccsr::TRANSMIT_DONE, "Transmit Done is down for the timer");
    g.write(chaos::CSR, ccsr::TIMER_INT_ENABLE | ccsr::LOOP_BACK);
    let v = g.read(chaos::CSR);
    assert_eq!(v & C_WRITABLE, ccsr::TIMER_INT_ENABLE | ccsr::LOOP_BACK,
               "the timer enable did not store");
    assert_eq!(v & (ccsr::RECEIVE_DONE | ccsr::TRANSMIT_DONE),
               ccsr::RECEIVE_DONE | ccsr::TRANSMIT_DONE, "a done bit fell");
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), None,
               "the Chaosnet's timer enable asked for an interrupt");
    // And the same arrangement with Receive Interrupt Enable set instead,
    // which MUST ask, so that "nothing asks" above is not a card whose
    // request is broken altogether.
    g.write(chaos::CSR, ccsr::RECEIVE_INT_ENABLE | ccsr::LOOP_BACK);
    g.look();
    assert_eq!(g.b.interrupt_request(g.now), Some(0o270),
               "Receive Done with its own enable asked for nothing");

    // **LOST COUNT STAYS THROUGH A RESET AND `-UB INIT`** (muir's `4647f6b`,
    // `a_reset_leaves_lost_count_where_it_was_on_both_alike`): its 74LS161
    // at LMMYNM 0F04 clears on Clear Receiver's `-11.SAYS.GO` alone, and
    // `-INIT` reaches only `-CLR RCV BUSY` and Transmit Done. A Reset and
    // then `-UB INIT` with four frames counted: Receive Done and the
    // enables go and the count stays; Clear Receiver below takes it away.
    let lost = (g.read(chaos::CSR) & ccsr::LOST_COUNT) >> 9;
    assert_eq!(lost, 4, "the frames counted before the Reset");
    g.write(chaos::CSR, ccsr::RESET);
    let v = g.read(chaos::CSR);
    assert_eq!((v & ccsr::LOST_COUNT) >> 9, lost, "a Reset took the lost count");
    assert_eq!(v & (ccsr::RECEIVE_DONE | C_WRITABLE), 0, "a Reset left Receive Done or an enable");
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::RECEIVE_INT_ENABLE);
    g.init();
    let v = g.read(chaos::CSR);
    assert_eq!((v & ccsr::LOST_COUNT) >> 9, lost, "-UB INIT took the lost count");
    assert_eq!(v & C_WRITABLE, 0, "-UB INIT left an enable");

    // Clear Receiver takes the packet, the lost count and the CRC verdict
    // away, and leaves the five writable bits where the same word puts them.
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER | ccsr::SPY | ccsr::LOOP_BACK);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, 0, "Clear Receiver left Receive Done up");
    assert_eq!(v & ccsr::LOST_COUNT, 0, "Clear Receiver left the lost count");
    assert_eq!(v & C_WRITABLE, ccsr::SPY | ccsr::LOOP_BACK, "Clear Receiver took the enables too");
    assert_eq!(g.read(chaos::BIT_COUNT), 0, "the bit count after Clear Receiver");
    // **A READ OF THE BUFFER WITH RECEIVE DONE DOWN SHIFTS THE READ
    // REGISTER** (muir's `4647f6b`, `read_down`): with the line idle `RRESET`
    // holds `RBCT` at 0, so each read is the last word read moved up a bit
    // with the buffer's bit at `RBCT` 0 below it --- the packet's check
    // word's lowest bit here --- and the card's own register, not 0.
    for _ in 0..3 {
        idle_read(&mut g);
    }

    // --- the buffer's own size, which is 256 words, and goes round -------
    //
    // The 2147 at LMTBUF 0C10 is 4,096 bits on `TBCT<11:0>`, and the count
    // goes round: a word past the 256th goes over the first.  Written 300,
    // so the frame is the last 44, the source and the check of all 300:
    // `(16 * 300 + 32) mod 4096` bits.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_TRANSMITTER);
    let long: Vec<u16> = (0..300u16).map(|k| k.wrapping_mul(0o2731) ^ 0o52525).collect();
    for w in &long {
        g.write(chaos::WRITE_BUFFER, *w);
    }
    // The turn must not come before Clear Transmitter does, which with the
    // shift register's hold on the 300 writes is a matter of the turn
    // timer's phase, so START waits for one that leaves room.
    quiet_turn(&mut g, 30_000);
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    let line = ready_line(&g.b);
    assert_eq!(line.len(), 46, "300 words written make a frame of 46");
    assert_eq!(&line[..44], &long[256..], "the words the wrap left");
    assert_eq!(line[45], check_word(&[&long[..], &[CHAOS_ADDRESS]].concat()), "the check of every word written");
    g.ctx(&line);
    // Clear Transmitter stops it before the turn ever comes: the buffer
    // goes, Transmit Done comes back up and no frame is ever launched.
    g.wait(20_000);
    g.write(chaos::CSR, ccsr::CLEAR_TRANSMITTER | ccsr::LOOP_BACK);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::TRANSMIT_DONE, ccsr::TRANSMIT_DONE, "Clear Transmitter left it down");
    g.wait(400_000);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, 0, "a cleared transmitter still sent its frame");

    // **FRAMES WRITTEN PAST THE BUFFER'S END, SENT**, under Loop Back, each
    // read round the buffer as muir reads the netlist board: 254 words send
    // nothing at all, 255 to 257 send 16 to 48 bits that no receiver lands
    // and that leave their bits in the buffer, and 258 and 300 land, 64 and
    // 736 bits of what the wrap left, with the check of every word written,
    // which the read-out then fails; reading round shows the runs before
    // them.
    for n in [254usize, 255, 256, 257, 258, 300] {
        g.wait(2_000);
        g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
        // A read of the buffer with no packet moves no pointer (the read
        // register shifts), so the frame that lands next reads from its
        // first word.
        idle_read(&mut g);
        for k in 0..n {
            g.write(chaos::WRITE_BUFFER, if k + 1 == n { CHAOS_ADDRESS } else { 0o100000 | k as u16 });
        }
        let landed = loop_start(&mut g);
        assert_eq!(landed.is_some(), n >= 258, "a frame of {n} words written landed or did not");
        if landed.is_some() {
            read_round(&mut g, 262);
        }
    }
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER | ccsr::LOOP_BACK);

    // And an empty buffer started: no word was written since the last
    // START, so Transmit Done is up and the read of START takes it down
    // (MIT's TRESET, the 74S00s at LMTBFC 0C15 clearing the 74S74 at LMMODU
    // 0D08).  The frame still goes, the source and its check word, and
    // Transmit Done comes back `TDONE_BEFORE_END_NS` before its nominal
    // end; 32 bits is no packet, so nothing lands, and its bits stay.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK);
    let t = g.now;
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    assert_eq!(g.read(chaos::CSR) & ccsr::TRANSMIT_DONE, 0, "an empty START left Transmit Done up");
    let line = ready_line(&g.b);
    assert_eq!(line, [CHAOS_ADDRESS, check_word(&[CHAOS_ADDRESS])], "an empty START's frame");
    g.ctx(&line);
    let idle = empty_frame(&mut g, t);
    hand_back_run(&mut g, idle, &line);
    g.wait(400_000);
    assert_eq!(g.read(chaos::CSR) & ccsr::RECEIVE_DONE, 0, "an empty buffer arrived as a packet");
    idle_read(&mut g);

    // --- START again with nothing written: the first START took the buffer
    //
    // `Interface::start` is `mem::take`, so a packet started leaves the
    // buffer empty, and a second read of START with no word written in
    // between hands the far end nothing.  MIT's board agrees that nothing
    // of the first packet goes again: the 25LS193s at LMTBUF 0C11-0C13
    // count `TBCT` up as words are written and down as the frame goes out,
    // and muir's `data/CADRIO.netlist` driven this way puts a frame with no
    // data words on the cable at the second START.  A card that kept the
    // length re-sends the first packet here.  No Clear Transmitter, Reset or
    // `-UB INIT` comes between the two, since each empties the buffer.
    g.wait(2_000);
    let again: Vec<u16> = vec![0o143021, 0o034756, 0o000001, CHAOS_ADDRESS];
    let t = g.now;
    for w in &again {
        g.write(chaos::WRITE_BUFFER, *w);
    }
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    let line = ready_line(&g.b);
    g.ctx(&line);
    let (busy, _) = next_frame(&g.b, t);
    let td = when(&g.b, busy, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    let land = when(&g.b, td, 1_000_000, &|b| cs(b) & ccsr::RECEIVE_DONE != 0);
    let again_words = read_out(&g.b, land, again.len() + 2);
    g.crx(land, ((again.len() + 2) * 16) as u64, false, false, &again_words);
    assert_eq!(&again_words[..again.len()], &again[..], "the packet did not come back as written");
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, ccsr::RECEIVE_DONE, "the packet did not land");
    assert_eq!(v & ccsr::TRANSMIT_DONE, ccsr::TRANSMIT_DONE, "Transmit Done did not come back");
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER | ccsr::LOOP_BACK);
    g.wait(2_000);
    let t = g.now;
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    // Transmit Done was up again, and this START takes it down too.
    assert_eq!(g.read(chaos::CSR) & ccsr::TRANSMIT_DONE, 0, "the second START left Transmit Done up");
    let line = ready_line(&g.b);
    assert_eq!(line.len(), 2, "a second START sent the first packet again");
    g.ctx(&line);
    let idle = empty_frame(&mut g, t);
    hand_back_run(&mut g, idle, &line);
    g.wait(400_000);
    let v = g.read(chaos::CSR);
    assert_eq!(v & ccsr::RECEIVE_DONE, 0, "a second START sent the first packet again");

    // **A RUN OF 48 BITS OR FEWER LEAVES ITS BITS**, and the idle read shows
    // the one at RBCT 0. 255 words written send 16 bits, the check word of
    // all of them and the source alone, which goes in at the run's done, over
    // what the place held: a packet landed first whose own check word's
    // lowest bit is the other, then the receiver cleared, the run stored over
    // it, and an idle read either side.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER | ccsr::CLEAR_TRANSMITTER);
    let words255: Vec<u16> = (0..255u16).map(|k| 0o60000 ^ k.wrapping_mul(0o1453)).collect();
    let run_word = check_word(&[&words255[..], &[CHAOS_ADDRESS]].concat());
    let p = (0..64u16)
        .map(|k| vec![0o1000 + k, CHAOS_ADDRESS])
        .find(|p| check_word(&[&p[..], &[CHAOS_ADDRESS]].concat()) & 1 != run_word & 1)
        .expect("a packet whose check word's lowest bit is not the run's");
    for w in &p {
        g.write(chaos::WRITE_BUFFER, *w);
    }
    assert!(loop_start(&mut g).is_some(), "the packet under the run did not land");
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    let below = idle_read(&mut g);
    g.wait(2_000);
    for w in &words255 {
        g.write(chaos::WRITE_BUFFER, *w);
    }
    let t = g.now;
    assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
    let line = ready_line(&g.b);
    assert_eq!(line, [run_word], "255 words written send the check word alone");
    g.ctx(&line);
    let (s, _) = next_frame(&g.b, t);
    let td = when(&g.b, s, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    let idle = idle_after(&g.b, s);
    hand_back_run(&mut g, idle, &line);
    g.wait(2_000);
    let above = idle_read(&mut g);
    assert_ne!(above & 1, below & 1, "the run's bit at RBCT 0 is the packet's");
    g.run_bits += 1;


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

    // --- FRAMES THE RECEIVER TAKES AND DOES NOT LAND, AND CLEARS INSIDE ONE
    //
    // muir's `b338042` and `4647f6b`, measured on the netlist board: the
    // receiver stores every frame it takes from `RBCT` 0 as it comes, and
    // the destination word decides only whether it lands. A frame for
    // another station leaves its bits in the buffer, and so does one a
    // Clear Receiver, a Reset or `-UB INIT` drops; the far end hands the
    // card those bits to store and not land, and after a drop right after
    // the clear, with no row between. Inside a frame the receiver is not
    // taking --- refused at `START^` or cleared off it --- `RRESET` is not
    // held, and reads of the buffer count `RBCT` down from 0, the bit count
    // showing it and CRC Error the check of the bits read. Each is read
    // round afterwards over a frame landed short, which shows what the
    // buffer kept.
    let numbered = |n: usize, dest: u16| -> Vec<u16> {
        let mut v: Vec<u16> = (0..n - 1).map(|k| 0o140000 ^ (k as u16).wrapping_mul(0o3517)).collect();
        v.push(dest);
        v
    };
    // Sends `words` and returns the frame's first edge, its line handed.
    fn send(g: &mut Gen, words: &[u16]) -> u64 {
        let t = g.now;
        for w in words {
            g.write(chaos::WRITE_BUFFER, *w);
        }
        assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
        let line = ready_line(&g.b);
        g.ctx(&line);
        next_frame(&g.b, t).0
    }
    // Reads inside the frame on the line, the bit count, the buffer if the
    // receiver is not taking it, and the CSR, `n` times a few cells apart.
    fn inside(g: &mut Gen, n: usize) {
        for k in 0..n {
            g.wait(900 + 130 * k as u64);
            g.read(chaos::BIT_COUNT);
            let s = st(&g.b);
            let now = g.now;
            if !s.taking(g.chaos(), now) && !s.rdone {
                g.read(chaos::READ_BUFFER);
            }
            g.read(chaos::CSR);
        }
    }
    // A short frame to this interface landed over what the buffer holds,
    // read round, and the receiver cleared.
    fn land_short(g: &mut Gen) {
        g.wait(2_000);
        let landed = loop_start(g);
        assert!(landed.is_some(), "a short frame did not land");
        read_round(g, 262);
        g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    }
    // (a) A frame for another station, taken, stored, and not landed.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    let s = send(&mut g, &numbered(20, CHAOS_PEER));
    g.at(grid_at(s + 5_000));
    inside(&mut g, 4);
    let td = when(&g.b, g.now, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    let idle = idle_after(&g.b, s);
    let before = st(&g.b);
    g.stored(idle, &before);
    assert_eq!(cs(&g.b) & ccsr::RECEIVE_DONE, 0, "a frame for another station landed");
    for _ in 0..3 {
        idle_read(&mut g);
    }
    for w in [0o12345u16, 0o54321, CHAOS_ADDRESS] {
        g.write(chaos::WRITE_BUFFER, w);
    }
    land_short(&mut g);
    // (b) A Clear Receiver inside a frame taken, after its destination word:
    // dropped, the bits stored so far kept, and reads counting down through
    // the rest of it.
    g.wait(2_000);
    let s = send(&mut g, &numbered(40, CHAOS_ADDRESS));
    g.at(grid_at(s + BUSY_ABORT_NS + 20_000));
    inside(&mut g, 2);
    let before = st(&g.b);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    let d = st(&g.b).dropped.expect("the Clear Receiver dropped nothing");
    assert!(d.1 > 64, "the drop kept {} bits", d.1);
    g.drops += 1;
    let at = g.now;
    g.stored(at, &before);
    inside(&mut g, 6);
    let td = when(&g.b, g.now, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    g.settle(grid_at(idle_after(&g.b, s)));
    assert_eq!(cs(&g.b) & ccsr::RECEIVE_DONE, 0, "a frame cleared off landed");
    idle_read(&mut g);
    for w in [0o23456u16, 0o65432, 0o1, CHAOS_ADDRESS] {
        g.write(chaos::WRITE_BUFFER, w);
    }
    land_short(&mut g);
    // (c) A Clear Receiver before the destination word: dropped, and as the
    // word goes by the busy receiver counts the frame and aborts it, being
    // this interface's own address.
    g.wait(2_000);
    let s = send(&mut g, &numbered(40, CHAOS_ADDRESS));
    g.at(grid_at(s + 4_000));
    inside(&mut g, 1);
    let before = st(&g.b);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    assert!(st(&g.b).dropped != before.dropped, "the Clear Receiver dropped nothing");
    g.drops += 1;
    let at = g.now;
    g.stored(at, &before);
    let lost = when(&g.b, g.now, 1_000_000, &|b| cs(b) & ccsr::LOST_COUNT != 0);
    assert_eq!(lost, s + BUSY_ABORT_NS, "the busy receiver counted off the destination word");
    g.cls(lost);
    let td = when(&g.b, lost, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    assert!(cs(&{ let mut c = g.b.clone(); c.advance(td); c }) & ccsr::TRANSMIT_ABORT != 0, "no abort");
    g.ctd(td, true);
    inside(&mut g, 2);
    g.settle(grid_at(idle_after(&g.b, s)));
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    // A frame of zeros for another station, stored, for (d)'s reads to
    // count down through: where the check of the bits read and the check of
    // one word alone part.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    let mut zeros = vec![0u16; 252];
    zeros.push(CHAOS_PEER);
    let s = send(&mut g, &zeros);
    let td = when(&g.b, s, 2_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    let idle = idle_after(&g.b, s);
    let before = st(&g.b);
    g.stored(idle, &before);
    // (d) A frame refused at its `START^`, Receive Done up, the receiver
    // then cleared inside it: never taken, so nothing stored and reads
    // counting down from 0; counted and aborted at its destination word.
    g.wait(2_000);
    for w in [0o34567u16, 0o76543, CHAOS_ADDRESS] {
        g.write(chaos::WRITE_BUFFER, w);
    }
    assert!(loop_start(&mut g).is_some(), "the packet to refuse on did not land");
    g.wait(2_000);
    let s = send(&mut g, &numbered(40, CHAOS_ADDRESS));
    g.at(grid_at(s + 3_000));
    inside(&mut g, 1);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    inside(&mut g, 2);
    let lost = when(&g.b, g.now, 1_000_000, &|b| cs(b) & ccsr::LOST_COUNT != 0);
    assert_eq!(lost, s + BUSY_ABORT_NS, "the busy receiver counted off the destination word");
    g.cls(lost);
    let td = when(&g.b, lost, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, true);
    inside(&mut g, 5);
    g.settle(grid_at(idle_after(&g.b, s)));
    idle_read(&mut g);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    // (d') The same for a frame for another station, which no busy receiver
    // counts and which goes on to its end: the reads count down through the
    // stored zeros.
    g.wait(2_000);
    for w in [0o35670u16, 0o76541, CHAOS_ADDRESS] {
        g.write(chaos::WRITE_BUFFER, w);
    }
    assert!(loop_start(&mut g).is_some(), "the packet to refuse on did not land");
    g.wait(2_000);
    let s = send(&mut g, &numbered(40, CHAOS_PEER));
    g.at(grid_at(s + 3_000));
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    inside(&mut g, 10);
    let td = when(&g.b, g.now, 1_000_000, &|b| cs(b) & ccsr::TRANSMIT_DONE != 0);
    g.ctd(td, false);
    g.settle(grid_at(idle_after(&g.b, s)));
    idle_read(&mut g);
    g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
    // (e) A Reset inside a frame taken, and (f) `-UB INIT`: each drops it as
    // a Clear Receiver does, and takes Loop Back off with the CSR, so the
    // frame looped back is over for the receiver at once.
    for by_init in [false, true] {
        g.wait(2_000);
        let s = send(&mut g, &numbered(40, CHAOS_PEER));
        g.at(grid_at(s + 6_000));
        inside(&mut g, 2);
        let before = st(&g.b);
        if by_init {
            g.init();
        } else {
            g.write(chaos::CSR, ccsr::RESET);
        }
        assert!(st(&g.b).dropped != before.dropped, "the reset dropped nothing");
        assert!(st(&g.b).frame_now(g.now).is_none(), "the frame went on past the reset");
        g.drops += 1;
        let at = g.now;
        g.stored(at, &before);
        g.wait(2_000);
        idle_read(&mut g);
        g.write(chaos::CSR, ccsr::LOOP_BACK | ccsr::CLEAR_RECEIVER);
        for w in [0o45670u16 ^ u16::from(by_init), 0o7, CHAOS_ADDRESS] {
            g.write(chaos::WRITE_BUFFER, w);
        }
        land_short(&mut g);
    }
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER);

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
    // pointer back.  Nothing on this board uses synchronous mode and nothing
    // anywhere reads these three back, so **muir has no column for them and
    // this trace carries none**: what holds them is the check's own model of
    // Table 4, compared against `ser_syn_face`, and the module's header says
    // so.  What the program owes that model is the exercise --- four writes,
    // so the pointer wraps at three and lands somewhere other than where it
    // started; then a read of the command register; then a fifth write,
    // which must land in SYN1 and nowhere else.  Without the fifth, a card
    // that never put the pointer back would differ only in the pointer and
    // not in any register.
    for v in [0o252u16, 0o125, 0o377, 0o001] {
        g.write(serial::STATUS, v);
    }
    g.read(serial::COMMAND);
    g.write(serial::STATUS, 0o316);

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

    // --- the two echoing modes, and the echo itself ----------------------
    //
    // "Auto echo mode ... the CPU to transmitter link is disabled", and the
    // same for remote loop back: `SR0` is down in both however `CR0` stands,
    // so a driver that set either and went on writing characters would be
    // writing into a register nothing empties.
    //
    // **AND THE ECHO IS BUILT NOW.**  Both modes put the received character
    // back on the line, and muir puts it there at the END of the received
    // frame rather than at the middle of the stop bit where the CPU gets it
    // --- `Pci::rx_times`' two instants.  The seam carries both now, `SRX`
    // and `SRE`, so the card can place it.  What separates the two modes at
    // the register face is `SR1`: auto echo gives the character to the CPU
    // as well and remote loop back keeps it, "received data is not sent to
    // the local CPU".
    //
    // **The echo's instant is read off the cable and not computed.**
    // `Pci::rx_times` is private and the character muir echoes carries
    // exactly that time, so `Gen::taken` is the only arithmetic here.
    g.wait(2_000);
    g.spl(true);
    g.read(serial::COMMAND);
    g.write(serial::MODE, 0o116);
    g.write(serial::MODE, 0o177);
    let frame_e = g.b.serial.framing().frame_ns(g.b.serial.rate());
    for (m, sent) in [
        (serial::command::AUTO_ECHO, 0o265u8),
        (serial::command::REMOTE_LOOP_BACK, 0o152u8),
    ] {
        g.write(serial::COMMAND, u16::from(m | on));
        let v = g.read(serial::STATUS);
        assert_eq!(v & u16::from(serial::status::TX_READY), 0,
                   "the transmitter runs in mode {m:o}");
        assert_eq!(v & u16::from(serial::status::RX_READY), 0,
                   "a character is left over from before mode {m:o}");
        assert_eq!(g.read(serial::COMMAND), FLOATING | u16::from(m | on),
                   "the command register did not take the mode");
        // The far end sends one character.  The instant the receiver is
        // done with it is the instant the echo is pushed, which is visible
        // on a copy through `Cable::sent` in BOTH modes --- `SR1` is not,
        // because remote loop back never raises it, and a predicate that
        // worked for one mode and not the other would need two programs.
        g.wait(2_000);
        let started = g.now;
        g.b.serial.cable.send(sent, started);
        let done = when(&g.b, started, 4 * frame_e, &|b| b.serial.cable.sent().count() > 0);
        g.srx(done, sent);
        let got = g.taken();
        assert_eq!(got.len(), 1, "mode {m:o} put {} characters on the cable", got.len());
        let (ends, back) = got[0];
        assert_eq!(back, sent, "mode {m:o} echoed the wrong character");
        assert!(ends > done, "mode {m:o} ended the frame at or before the character arrived");
        g.sre(ends);
        g.sout(ends, back);
        // The one thing that tells the two modes apart at the register face.
        let v = g.read(serial::STATUS);
        if m == serial::command::AUTO_ECHO {
            assert_eq!(v & u16::from(serial::status::RX_READY),
                       u16::from(serial::status::RX_READY),
                       "auto echo did not give the character to the CPU");
            assert_eq!(g.read(serial::DATA), FLOATING | u16::from(sent),
                       "auto echo's receive holding register");
        } else {
            assert_eq!(v & u16::from(serial::status::RX_READY), 0,
                       "remote loop back gave the character to the CPU");
        }
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
    // THE KEYBOARD'S BOOT WORD, which the card decodes for itself.
    //
    // `ukbd.lisp`'s `check-boot` sends this word when both Controls and both
    // Metas are held with Rubout or Return, and the card boots the machine
    // off it without the processor being asked.  The 25LS2521 at IOBCSR 0A20
    // compares `SR7`-`SR10` against ground and `SR11`-`SR14` against the
    // pull-up `HI4`, and `SR<n>` is bit `n-1` of the word, so what it looks
    // at is BITS 13-6 AND NOTHING ELSE: ones in 13-10 over zeros in 9-6.
    // Bit 16, which `ukbd.lisp`'s own prose names, is qualified upstream by
    // `REMOTE MOUSE ENABLE` and is not one of the comparator's inputs.
    //
    // So the rows come in four kinds, and the third is the one that says the
    // comparator is eight bits wide and not nine:
    //
    //   - the two boot words themselves, cold and warm;
    //   - the cold word with ONE of the eight compared bits flipped, eight
    //     rows, none of which may boot;
    //   - the cold word with one of the SIXTEEN bits the comparator cannot
    //     see flipped, every one of which must still boot;
    //   - ordinary words off the same keyboard, which must not boot.
    //
    // A card comparing a ninth bit passes the first two kinds and fails the
    // third; a card comparing seven fails the second.  The `boot` column is
    // what muir's board made of each word, and the fabric's `-BOOT*` is
    // compared against it.
    //
    // **The word must still be in the register afterwards**, because
    // microcode 323 reads it at `(LOC 6)` to choose cold from warm.  Both
    // halves are read back after each of the two boot words, in the
    // microcode's own order, and nothing between the press and the read
    // flushes it.
    // ------------------------------------------------------------------
    g.wait(20_000);
    assert!(!g.b.take_boot(), "the card asked to boot before anything was typed");
    let cold = keyboard::boot(true);
    let warm = keyboard::boot(false);
    // `terminal::keyboard`'s own frame: bits 23-19 "Reserved, must be 1's"
    // and the new keyboard's source `001` in 18-16, over `ukbd.lisp`'s
    // "15-10 1, 9-6 0, 5-0 46 if cold, 62 if warm".
    assert_eq!(cold, 0o76376046, "the cold boot word");
    assert_eq!(warm, 0o76376062, "the warm boot word");
    assert_eq!((cold >> 6) & 0o377, 0o360, "ones in 13-10 over zeros in 9-6");
    assert_eq!((warm >> 6) & 0o377, 0o360, "the warm word matches the same eight bits");
    assert_eq!(cold & !0o77, warm & !0o77, "the two differ in the low six bits alone");

    for (word, low6, what) in [(cold, 0o46u32, "cold"), (warm, 0o62, "warm")] {
        g.key_boot(word, true, what);
        // `(LOC 6)` reads the high half first and the low half second, and
        // it is the low half's read that takes `KBD READY` down.
        let high = g.read(KBD_HIGH);
        let low = g.read(KBD_LOW);
        assert_eq!((u32::from(high & 0xff) << 16) | u32::from(low), word, "{what}: reads back");
        assert_eq!(u32::from(low) & 0o77, low6, "{what}: and says which boot it is");
        g.wait(20_000);
    }

    // The eight bits the comparator compares, each flipped alone: four ones
    // made zero and four zeros made one.
    for bit in 6..14u32 {
        g.wait(8_000);
        g.key_boot(cold ^ (1 << bit), false, "a compared bit flipped");
    }
    // The sixteen it cannot see, each flipped alone.  Bits 5-0 are the cold
    // and warm codes themselves; 15 and 14 are the top of the run of ones
    // `ukbd.lisp` describes, above the comparator's window; 18-16 are the
    // keyboard's source identifier, bit 16 among them; and 23-19 are the
    // rest of the frame.
    for bit in (0..6u32).chain(14..24) {
        g.wait(8_000);
        g.key_boot(cold ^ (1 << bit), true, "a bit the comparator cannot see");
    }
    // Ordinary words off the same keyboard.  The boot sequence's own keys
    // are among them: a Control going down is not a boot, only the word the
    // firmware sends after the last of them is.
    for (word, what) in [
        (up_down(RUBOUT, false), "Rubout down"),
        (up_down(RUBOUT, true), "Rubout up"),
        (up_down(0o20, false), "the left Control down"),
        (up_down(0o26, false), "the right Control down"),
        (up_down(0o45, false), "the left Meta down"),
        (up_down(0o165, false), "the right Meta down"),
        (up_down(RETURN, false), "Return down"),
        (all_keys_up(1 << 4 | 1 << 5), "all keys up, Control and Meta still down"),
        (all_keys_up(0o3777), "all keys up with every shifting key held"),
        (all_keys_up(0), "all keys up"),
    ] {
        g.wait(8_000);
        g.key_boot(word, false, what);
    }
    g.wait(8_000);
    g.look();

    // ------------------------------------------------------------------
    // THE TRANSMITTER'S SHIFT REGISTER HOLDS THE BUS (muir's `37cf490`,
    // `IoBoardTiming::answer_cycle`, measured on the netlist board).  Each
    // word written, and at START the source and check words, reaches the
    // buffer through the shift register: it loads at the first `FCLK^` at
    // least `TSR_LOAD_NS` = 101 ns after the cycle's answer and shifts a
    // word in `TSR_WORD_NS` = 2,000 ns, and a WRITE BUFFER or START that
    // comes while it is busy is answered `IOB_CHAOS_BUFFER_NS` = 350 ns
    // after `TSREMPTY` rises.  The earlier sections hold many cycles
    // already; this one places them: a free answer at each of the 25 grid
    // phases of `FCLK^`'s two periods with a word right behind it, so that
    // the held answer names the edge the register loaded on; the word
    // behind swept across the instant the register empties; and a START
    // behind a word and a word behind a START, two words a load.
    // ------------------------------------------------------------------
    const FCLK2: u64 = 250;
    g.wait(5_000);
    g.write(chaos::CSR, ccsr::CLEAR_TRANSMITTER);
    // To the next instant at or after now plus `room` whose answer, free,
    // falls `p` nanoseconds into `FCLK^`'s two periods.
    fn aim_answer(g: &mut Gen, room: u64, p: u64) {
        let from = g.now + room;
        let a = from + IOB_CHAOS_BUFFER_NS;
        let t = from + (p + FCLK2 - a % FCLK2) % FCLK2;
        g.at(t);
    }
    let mut phases = BTreeSet::new();
    for p in (0..FCLK2).step_by(TICK_NS as usize) {
        aim_answer(&mut g, 5_000, p);
        g.write(chaos::WRITE_BUFFER, 0o100000 | p as u16);
        phases.insert(g.landed % FCLK2);
        let before = g.tsr_held;
        g.write(chaos::WRITE_BUFFER, 0o40000 | p as u16);
        assert_eq!(g.tsr_held, before + 1, "the word right behind another was not held");
    }
    assert_eq!(phases.len(), 25, "the free answers missed a phase of FCLK^");
    g.write(chaos::CSR, ccsr::CLEAR_TRANSMITTER);
    // The word behind, swept across the instant the register empties: held
    // before it, free from it on.
    let mut sides = [0u64; 2];
    for p in [0u64, 30, 90, 150, 200] {
        for k in 0..6u64 {
            aim_answer(&mut g, 5_000, p);
            g.write(chaos::WRITE_BUFFER, 0o20000 | (p as u16) << 3 | k as u16);
            // The first instant from which a word is answered free.
            let probe = g.io.clone();
            let mut m0 = g.now;
            while probe.clone().answer_cycle(chaos::WRITE_BUFFER, true, m0)
                != m0 + IOB_CHAOS_BUFFER_NS
            {
                m0 += TICK_NS;
            }
            let m = m0 - 30 + TICK_NS * k;
            g.at(m.max(g.now));
            let before = g.tsr_held;
            g.write(chaos::WRITE_BUFFER, 0o10000 | (p as u16) << 3 | k as u16);
            sides[usize::from(g.tsr_held == before)] += 1;
        }
        g.write(chaos::CSR, ccsr::CLEAR_TRANSMITTER);
    }
    assert!(sides[0] >= 10 && sides[1] >= 10, "the sweep did not cross the register's emptying: {sides:?}");
    // START behind a word, and a word behind START: the source and check
    // words are two loads' worth, 4,000 ns.  The frame goes into the void
    // with no cable and no Loop Back, so the far end has only its busy cable
    // and its Transmit Done to give.  A phase whose turn would come before
    // the rows below have run is moved on by two periods of `FCLK^` until
    // one does not.
    for (j, p) in [0u64, 60, 120, 180, 240].into_iter().enumerate() {
        let words: Vec<u16> = vec![0o1000 + j as u16, CHAOS_PEER];
        let mut room = 20_000;
        loop {
            aim_answer(&mut g, room, p);
            let mut b = g.b.clone();
            let mut io = g.io.clone();
            let mut m = g.now;
            for w in &words {
                let a = io.answer_cycle(chaos::WRITE_BUFFER, true, m);
                b.advance(a);
                b.write(chaos::WRITE_BUFFER, *w, a);
                m = a + UNIBUS_STROBE_NS;
            }
            let a = io.answer_cycle(chaos::START, false, m);
            b.advance(a);
            b.read(chaos::START, a);
            let behind = io.answer_cycle(chaos::WRITE_BUFFER, true, a + UNIBUS_STROBE_NS);
            let (busy, _) = next_frame(&b, a);
            if busy > behind + 8_000 {
                break;
            }
            room = FCLK2;
        }
        let t = g.now;
        for w in &words {
            g.write(chaos::WRITE_BUFFER, *w);
        }
        let before = g.tsr_held;
        assert_eq!(g.read(chaos::START), CHAOS_ADDRESS);
        assert_eq!(g.tsr_held, before + 1, "START right behind a word was not held");
        g.write(chaos::WRITE_BUFFER, 0o2000 + j as u16);
        assert_eq!(g.tsr_held, before + 2, "a word right behind START was not held");
        let line = ready_line(&g.b);
        assert_eq!(&line[..words.len()], &words[..], "the frame is not the words written before START");
        g.ctx(&line);
        let _ = empty_frame(&mut g, t);
        g.write(chaos::CSR, ccsr::CLEAR_TRANSMITTER);
    }
    g.wait(8_000);
    g.look();

    // --- frames from another station, on a cable -----------------------
    //
    // Last, because a copy of the interface has no cable and every probe
    // above ([`when`]) runs on copies.  A cable plugged in now, and frames put on it by another station, as
    // muir reads the netlist board in `tests/chaos_rtl.rs`: of 256, 257 and
    // 258 words with the source and check, of which the buffer keeps the
    // last 4,096 bits, the words read first; and wreckage, another
    // station's frame put over one going, whose top word is partial --- 12
    // words over an earlier frame of ones left unread, and 270 words, past
    // 4,096 bits.  Each is read round the buffer.  Nothing else is on the
    // cable, and nothing is read or written while a frame is on it, so the
    // cable's busy line has no row to make.
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER);
    g.b.chaos.as_mut().expect("the interface").plug(Ether::new());
    // From here the far end's instants are found on the board itself, a
    // tick at a time: a copy has no cable.
    g.cable = true;
    fn cable(g: &mut Gen) -> &mut Ether {
        g.b.chaos.as_mut().and_then(|c| c.ether_mut()).expect("the cable")
    }
    let numbered = |n: usize| -> Vec<u16> {
        let mut v: Vec<u16> = (0..n - 1).map(|k| 0o100000 | k as u16).collect();
        v.push(CHAOS_ADDRESS);
        v
    };
    let mut ones = vec![0o177777u16; 252];
    ones.push(CHAOS_ADDRESS);
    let other = vec![0o1234u16, 0o4321, 0o17777, 0o3070];
    let (mut long_frames, mut partial) = (0, 0);
    for (words, over, read) in [
        (numbered(254), None, true),
        (numbered(255), None, true),
        (numbered(256), None, true),
        (ones, None, false),
        (numbered(12), Some(64u64), true),
        (numbered(270), Some(4_105), true),
    ] {
        // The receiver cleared first, so the frame of ones lands and is left
        // unread under the wreckage after it.
        g.wait(2_000);
        g.write(chaos::CSR, ccsr::CLEAR_RECEIVER);
        g.wait(2_000);
        let t = g.now;
        cable(&mut g).send_now(t, CHAOS_PEER, words);
        // **THE BOARD ITSELF IS TAKEN ON A TICK AT A TIME**, not a copy as
        // [`when`] probes: a copy of the interface has no cable.  Nothing
        // else happens on the board meanwhile, and the far end's instants
        // are said at the tick each falls in.
        let mut land = g.now;
        loop {
            land += TICK_NS;
            if let Some(cells) = over
                && land == grid_at(t + cells * CELL_NS)
            {
                g.b.advance(t + cells * CELL_NS);
                cable(&mut g).send_now(t + cells * CELL_NS, 0o3061, other.clone());
            }
            g.b.advance(land);
            if cs(&g.b) & ccsr::RECEIVE_DONE != 0 {
                break;
            }
            g.far(land);
            assert!(land < t + 3_000_000, "the frame from another station never landed");
        }
        let at = st(&g.b);
        let (h, bits) = handed_now(&g.b);
        g.crx(land, bits, at.crc, false, &h);
        // The line still busy with the frame put over it: it goes idle where
        // the interface's reckoning says, a row of its own.
        let mut idle = land;
        while st(&g.b).frame_now(idle).is_some() {
            idle += TICK_NS;
            g.b.advance(idle);
            g.far(idle);
        }
        g.at(idle);
        long_frames += u32::from(bits > 4_096);
        partial += u32::from(bits % 16 != 0);
        if read {
            read_round(&mut g, if over == Some(64) { 300 } else { 262 });
        }
    }
    assert_eq!((long_frames, partial), (3, 2), "frames past 4,096 bits, and partial ones");
    // **A RESET INSIDE A FRAME OFF THE CABLE** (muir's `b338042`): a frame
    // from another station to this interface, taken, and a Reset written
    // after its destination word.  The receiver is dropped off it --- `RRESET`
    // takes `RACT` down, and only `START^` sets it --- the bits stored so far
    // stay and are handed over to be stored, and the frame goes on on the
    // cable with the reads counting down through it, the bit count showing
    // `RBCT` and CRC Error the check of the bits read; Lost Count stays.
    g.wait(2_000);
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER);
    g.wait(2_000);
    let t = g.now;
    cable(&mut g).send_now(t, CHAOS_PEER, numbered(60));
    g.at(grid_at(t + BUSY_ABORT_NS + 15_000));
    inside(&mut g, 2);
    let before = st(&g.b);
    g.write(chaos::CSR, ccsr::RESET);
    assert!(st(&g.b).dropped != before.dropped, "the Reset dropped nothing off the cable");
    let now = g.now;
    assert!(st(&g.b).frame_now(now).is_some(), "the frame off the cable ended with the Reset");
    g.drops += 1;
    let at = g.now;
    g.stored(at, &before);
    inside(&mut g, 6);
    let mut idle = g.now;
    while st(&g.b).frame_now(idle).is_some() {
        idle += TICK_NS;
        g.b.advance(idle);
        g.far(idle);
    }
    g.at(idle);
    assert_eq!(cs(&g.b) & ccsr::RECEIVE_DONE, 0, "a frame dropped by a Reset landed");
    idle_read(&mut g);
    g.write(chaos::CSR, ccsr::CLEAR_RECEIVER);

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
    assert_eq!(BOOT_PULSE_NS, 4_000, "the card's -BOOT* is four microseconds wide");
    assert_eq!(g.boot_codes.len() as u64, g.boot_rows, "two KBOOT rows shared a word");
    assert_eq!(g.boots, 18, "the cold and warm words and the sixteen bits nothing compares");
    assert_eq!(g.boot_rows - g.boots, 18, "eight compared bits flipped and ten ordinary words");
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
    assert_eq!(g.inits, 7, "the program made a different number of -UB INIT pulses");
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
    // What the line's three and the far end's new rows reached: frames on
    // the line and their `START^`s, levels said, rows held to muir's face
    // inside a frame it takes, reads counting down inside one it does not,
    // frames counted lost, bits stored and not landed, and drops.
    assert!(g.cbl_rows >= 20 && g.cst_rows >= 10 && g.clv_rows >= 50, "the line: {} {} {}", g.cbl_rows, g.cst_rows, g.clv_rows);
    assert!(g.taken_rows >= 20 && g.down_reads >= 10, "inside frames: {} taken, {} counting down", g.taken_rows, g.down_reads);
    assert!(g.cls_rows >= 5 && g.stored_rows >= 5 && g.drops >= 4, "lost {}, stored {}, drops {}", g.cls_rows, g.stored_rows, g.drops);
    assert!(g.down_parts >= 1 && g.run_bits >= 1, "count-down checks parting {}, runs' bits shown {}", g.down_parts, g.run_bits);
    assert!(g.stk_rows >= 4 && g.sdn_rows >= 4, "the 2651 sent too little");
    assert!(g.srx_rows >= 3, "the 2651 received too little");
    // One a mode: a card that echoed in one and not the other would pass a
    // trace that only ever set one of them.
    assert!(g.sre_rows >= 2, "neither echoing mode ran a character through");
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
    println!("# KBOOT    n ns scancode boot <face>     the same press, DECODED: boot 1 is the");
    println!("#     25LS2521 at IOBCSR 0A20 matching bits 13-6 --- ones in 13-10 over zeros in");
    println!("#     9-6 --- and the card pulsing -BOOT*, boot_pulse_ns wide, onto CP1.  The");
    println!("#     word stays in the register with KBD READY up, for (LOC 6) to read.");
    println!("# MOVE     n ns dx dy <face>             the mouse moved, right and down");
    println!("# BTN      n ns mask <face>              the three switches, left 1 middle 2 right 4");
    println!("# SER      n ns ready <face>             the serial port's ready line at the card");
    println!("# INIT     n ns <face>                   -UB INIT");
    println!("# FACE     n ns <face>                   a sample with no cycle");
    println!("#");
    println!("# The Chaosnet interface's far end and the serial port's, which are the");
    println!("# `cadr-chaosnet` and `cadr-serial` programs' on the board and muir's own");
    println!("# models here.  Every instant is rounded UP to the grid, as the");
    println!("# microsecond counter's low half is, and `far_offgrid` counts how many.");
    println!("#");
    println!("# CBUF     dir seq k word            dir 0 a packet landing, 1 a buffer handed over");
    println!("# CTX      n ns seq len <face>       the transmit buffer the card handed over");
    println!("#     since the last such row: an ASSERTION, the words having come over the bus");
    println!("# CRX      n ns seq bits len crc busy store <face>  a packet lands in the receive buffer");
    println!("#     stimulus, its words streamed in on the ticks before; busy the line after it;");
    println!("#     store 1 the bits stored and not landed: a frame taken and not for this");
    println!("#     interface, or what a clear left of a frame it dropped.  A run of 48 bits or");
    println!("#     fewer lands nowhere, judged by its length");
    println!("# CTD      n ns abort <face>         Transmit Done off the far end");
    println!("# CLS      n ns abort <face>         a frame counted lost, the buffer full at its START^,");
    println!("#     abort 1 a frame of this interface's to its own address, aborted there, its");
    println!("#     Transmit Done after");
    println!("# CBL      n ns busy <face>          a frame on the line, from its first edge to its idle");
    println!("# CST      n ns <face>               its START^, where the receive gate takes Receive Done");
    println!("# CLV      n ns stored nz <face>     the bits the receiver would have stored of it so far,");
    println!("#     RBCT in twelve bits,");
    println!("#     and whether the 9401 is non-zero over them, gate or no gate, from here");
    println!("# STK      n ns <face>               the shift register takes the holding register");
    println!("# SDN      n ns <face>               the shift register finishes its frame");
    println!("# SRX      n ns data <face>          a character reaches the receive path");
    println!("# SRE      n ns <face>               ...and its frame ends, which is where");
    println!("#     the two echoing modes put the echoed character on the cable");
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
    println!("# boot_pulse_ns {BOOT_PULSE_NS}");
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
    println!("# cst_rows {}", g.cst_rows);
    println!("# clv_rows {}", g.clv_rows);
    println!("# cls_rows {}", g.cls_rows);
    println!("# cls_aborts {}", g.cls_aborts);
    println!("# crx_stored {}", g.stored_rows);
    println!("# taken_rows {}", g.taken_rows);
    println!("# down_reads {}", g.down_reads);
    println!("# drops {}", g.drops);
    println!("# down_parts {}", g.down_parts);
    println!("# run_bits {}", g.run_bits);
    println!("# stk_rows {}", g.stk_rows);
    println!("# sdn_rows {}", g.sdn_rows);
    println!("# srx_rows {}", g.srx_rows);
    println!("# sre_rows {}", g.sre_rows);
    println!("# sout_rows {}", g.sout_rows);
    println!("# spl_rows {}", g.spl_rows);
    println!("# far_offgrid {}", g.far_slips);
    println!("# offgrid_serial {}", g.serial_slips);
    println!("# tsr_held {}", g.tsr_held);
    println!("# offgrid_tsr {}", g.tsr_slips);
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
    println!("# boot_rows {}", g.boot_rows);
    println!("# boots {}", g.boots);
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
