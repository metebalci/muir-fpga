// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The I/O board --- MIT's own name for the card, muir's `ioboard::IoBoard` ---
// as a Unibus slave: the keyboard, the mouse, the two clocks and the status
// register they share.
//
// **`IOB` in this repository is not this card.**  `IOB<47:0>` on IREG is the
// bus that merges `I` with `OB` into the instruction register, and stays that.
// muir's `src/ioboard.rs` makes the same distinction in its own header.
//
// WHAT IS HERE, from `docs/io-board.md` and the sheets it names
// (`cadrio/iobcsr.drw`, `iobmse.drw`, `iobms2.drw`, and `data/CADRIO.netlist`):
//
//   0o764100  KBD LOW     the low sixteen bits of a twenty-four-bit scan code
//   0o764102  KBD HIGH    the high eight, with a floating upper byte
//   0o764104  MOUSE Y     the Y count with the three switches above it
//   0o764106  MOUSE X     the X count with the raw quadrature above it
//   0o764110  BEEP        no value in it: a reference toggles AUDIO
//   0o764112  KBD CSR     four enables, three ready bits, a floating byte
//   0o764114  0o764116    answered, with nothing behind them
//   0o764120  USEC LOW    the microsecond counter, and MIT's latch
//   0o764122  USEC HIGH   that latch, not the counter
//   0o764124  written the interval timer, read the sixty-cycle clock
//   0o764126  GPIO        answered, nothing wired to it
//
// `A3` is not decoded in the clock group, so `0o76413x` is `0o76412x`; the
// microsecond counter's two halves take no write.
//
// **WHAT IS NOT HERE, AND WHY THE CARD DOES NOT ANSWER IT.**  The Chaosnet
// interface (`0o764140`-`0o764156`) and the serial port (`0o764160`-`0o764176`)
// are two other slices.  `ioboard::answers` decodes them, because the decode
// is one sheet, and the card as MIT built it answers them whether or not the
// LMU chips and the 2651 are fitted --- their `-SSYN` comes from this card's
// own synchronisers, not from the parts.  **This module decodes the whole
// block and answers only the two groups it implements**, rather than invent
// the transmitter's, the receive buffer's and the half-microsecond clock's
// timings (`busint::IOB_CHAOS_BUFFER_NS`, `IOB_RBUF_SETUP_NS`,
// `IOB_SERIAL_NS`) for parts nothing can exercise.  `tb/cadr_io_board_tb.cpp`
// exempts exactly those fifteen addresses from the exhaustive decode sweep,
// counts them, and prints the count; whoever builds either slice makes the
// card answer its group and moves that line.
//
// **THE SEAM IS THE UNIBUS AND NOT `-MEMRQ`.**  `cadr_busint_xbus.sv` already
// drives `-UB MSYN`, `ub_write` and `ub_addr` and takes `-UB SSYN` back, and
// `cadr_spy_registers.sv` is the slave that answers today at `0o766000`.  This
// is the second slave on that seam, and it is composed under
// `cadr_memory_path.sv` now --- both slaves hang off the seam
// `cadr_console_bus.sv` presents, `-UB SSYN` is the OR of theirs and the word
// is a mux on which answered.  Nothing here knows about `phys`, the map or the
// microcycle even so: `build/iob.pass` still drives this module alone and is
// the only thing that holds it to muir, and `build/unibus.pass` holds the
// composition.
//
// **THE MATCH IS HELD, NEVER COMPUTED, AND IT COSTS NOTHING HERE.**  The disk
// controller's first draft matched `phys` combinationally and carried the
// map's ripple into `-MEMACK`/`-LOADMD` and so into the countdowns' clock
// enables: `memstart_reg/C -> mfinish_t_reg[0]/CE`, thirteen logic levels,
// -6.195 ns on 1,065 endpoints.  So `sel`, `kbm`, `clkgrp`, `which` and
// `wr` below are taken from `ub_addr` into registers every tick and nothing
// downstream ever sees the address itself.  **The earliest answer this card
// can give is fifty ticks after `-UB MSYN`** --- 250 ns through the TD250 at
// IOBADR 0E09, and the keyboard-and-mouse group waits two edges of the
// microsecond clock on top of that --- so a match a tick behind the strobe is
// a match 49 ticks early, and the hold is free.  That is why the counters
// below start on `ub_msyn` alone and the held match only gates what they
// decide: `-UB MSYN` and the address arrive on the same tick in the reference
// trace, which is a master with no setup at all, and a card that needed the
// address at the strobe would have to compute it.
//
// THE TIMING IS `busint::IoBoardTiming`, a behavioural twin measured on the
// netlist board, and it is not one number:
//
//   - the clocks and the GPIO answer 250 ns after `-UB MSYN` (`IOB_STRAIGHT_NS`);
//   - the keyboard, mouse, status and beep registers select through TWO stages
//     of the microsecond clock, so they answer 250 ns after the second edge
//     STRICTLY past `-MSYN` --- between 1,250 and 2,250 ns, depending on where
//     the request fell in the card's microsecond;
//   - the counter's low half takes ONE edge and `IOB_USEC_LOW_NS` = 313 ns,
//     measured on the netlist.  **This is the one place this card is off the
//     5 ns grid**: muir answers at 1,203 + 1,000k and the fabric can only
//     answer at 1,205.  The trace carries a `slip` column saying so on those
//     208 rows and no others, rather than hiding two nanoseconds in a
//     tolerance, and nothing downstream sees it --- `-LMACK` is 150 ns and the
//     MD strobe 100 ns past `-UB SSYN`, both multiples of five, so a bus
//     interface counting from the tick it SEES `-SSYN` lands where muir's does.
//
// **A WRITE LANDS AT `-UB SSYN`, WHERE muir PUTS IT**, and not at the card's
// own load pulse.  `busint.rs`'s `Responder::Unibus` arm makes `answered`
// equal to `ssyn` for every register of this card, where `Responder::Interface`
// --- the diagnostic block --- lands at `REGISTER_STROBE_NS` past `-MSYN`.  On
// the card the pulses are earlier (`-LOAD INTERVAL` is `Y2` of the 74LS138 at
// CLK60H 0B21, gated by `-WRITE` while `-MSYN` is up), and nothing on the card
// can see the difference: the only state a write starts is the interval timer,
// whose counts are 16 us apart.  But the instant is a choice, and a fabric
// loading the timer at its own write pulse brings `CLOCK READY` up by as much
// as 2,250 ns early against this trace.
//
// **AND THE COUNTER'S LOW HALF IS READ AT `-UB MSYN`, NOT AT `-UB SSYN`.**
// muir's `busint.rs` says why: "the board latches it on the way to answering,
// before the edge that answers has counted".  Every other register is read or
// written at `-SSYN`.
//
// **THE SIXTY-CYCLE COUNTER ACCUMULATES AND SUBTRACTS; IT DOES NOT RELOAD.**
// `SIXTY_CYCLE_NS` is 16,666,666, which is 1 modulo 5, so the k'th mains edge
// is on the 5 ns grid only for k a multiple of five.  A counter that adds five
// nanoseconds a tick and subtracts the period --- `cadr_disk_controller.sv`'s
// spindle trick, which is exactly `now mod REVOLUTION_NS` --- increments at the
// first tick at or after each edge, and the window in which it disagrees with
// `ns / SIXTY_CYCLE_NS` is `[B, B + (5 - B mod 5))`, which contains no multiple
// of five at all.  A down-counter reloaded with 3,333,333 ticks instead loses a
// nanosecond a period; the trace reads the register at fourteen boundaries on
// alternating sides and catches it at the first.
//
// **THE MOUSE'S ENCODERS ARE NOT ON THIS CARD.**  What crosses its edge is the
// seven lines MIT's mouse drives --- four quadrature and three switches --- and
// the 74LS14s at IOBMSE 0A25 and 0A27 invert them, which is why `lines` is
// `~mouse_lines`.  Decided for slice two: the card takes the lines, as MIT's
// does, and whatever turns a USB mouse's deltas into quadrature phases is
// fabric beside it.  A card taking ready-made deltas would be a different card
// and `build/iob.golden` would stop being a reference for the mouse half.
//
// **`-UB INIT` REACHES FIVE FLIP-FLOPS AND THE 2651, AND NOTHING ELSE.**
// `-INIT*` into the 8837 at IOBXCV 0F06 is `RESET`, the 2651's own reset pin
// --- which is why `ser_reset` leaves this module --- and `-RESET` off the
// 74S37 at 0E07 clears the 74LS175's four enables and the 74LS74's serial
// enable.  `KBD READY`, `MOUSE READY`, the mouse counters, the interval timer
// and the microsecond counter have no pin on it and count on.

`default_nettype none

module cadr_io_board (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- the Unibus, as a slave sees it
    input  var logic        ub_msyn,      // -UB MSYN, the master's strobe
    input  var logic        ub_write,
    input  var logic [17:0] ub_addr,      // the Unibus address, in bytes
    input  var logic [15:0] ub_wdata,     // UBI0..UBI15 from the master
    output var logic        ub_ssyn,      // -UB SSYN: this slave answers
    output var logic [15:0] ub_rdata,     // UBO0..UBO15
    // `-UB INIT` on the backplane.
    input  var logic        ub_init,

    // --- the keyboard's cable, `terminal::cable` at the far end.  A word off
    // the three 74LS164s at IOBKBD, with `EOC.KBD^` as the strobe: what
    // crosses this card's edge is a twenty-four-bit word arriving, which is
    // the trace's `KEY` row.  A word landing on one not yet read replaces it.
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,

    // --- the mouse's seven lines, as the mouse drives them: bits 0 to 3
    // `HORA`, `HORB`, `VERA`, `VERB`, bits 4 to 6 the tail, middle and head
    // switches, each pulled to ground when pressed.  The 74LS14s invert all
    // seven on their way to the 74LS374 at IOBMSE 0A24.
    input  var logic [6:0]  mouse_lines,

    // --- the serial port.  `ser_ready` is the 2651's `-RxRDY` and, by ECO 10
    // of `cadrio/iob.eco`, its `-TxRDY` on the same net, at the priority
    // encoder through the 74LS02 at IOBSER 0E11.  The chip is the serial
    // slice's; what this card owes it is its reset pin.
    input  var logic        ser_ready,
    output var logic        ser_reset,

    // --- the Chaosnet interface's request, `CHAOS.IREQ` on page IOBINT.  The
    // interface is its own slice and nothing drives this yet; the priority
    // encoder needs the input regardless, and a card built without it would
    // have to have these equations derived a second time.
    input  var logic        chaos_intr,

    // --- the Unibus interrupt: `-UB INTR` and `-UB BR5` on the backplane.
    // Nothing in `rtl/` runs a Unibus interrupt cycle yet, so this is a port
    // with nothing on the other end --- the shape `tv_intr` had before
    // `f8c6d25`.
    output var logic        intr_request,
    output var logic [7:0]  intr_vector,

    // --- `AUDIO`, the 74LS74 at IOBKBD 0C27 through the 75118 at 0F30: the
    // level the speaker's pair is driven to.  One reference to the beep is
    // one edge of a square wave.
    output var logic        audio,

    // --- the card's own state, brought out for the check, as
    // `cadr_memory_path.sv` brings `ub_msyn_o` out.  Each is a register on the
    // card and not a column invented for the trace: the status register's
    // flip-flops before the floating byte and `CLOCK READY` are made up on a
    // read, the two 74LS569 counters, the 74LS279's latch at CLKTIM 0D09, and
    // what the four 74LS193s were last loaded with.
    output var logic [7:0]  csr_face,
    output var logic [11:0] mouse_x,
    output var logic [11:0] mouse_y,
    output var logic        clock_ready,
    output var logic [15:0] interval
);

  // ---------------------------------------------------------------- constants

  // `ioboard::FIRST_USEC_EDGE_NS` = 890 and a microsecond, in ticks: the
  // 74S163 at IOBCLK 0C21 dividing the 32 MHz crystal.  Its first rising edge
  // is 890 ns after power-on and they are 1,000 ns apart from there, and NO
  // UNIBUS RESET MOVES THEM.
  //
  // **AND THIS CLOCK IS 2.0 REAL MICROSECONDS LONG, DELIBERATELY.**  200
  // ticks is a microsecond of the MACHINE's time, which is MIT's grid; the
  // board clocks a tick at 10 ns rather than 5 (`cadr_arty.sv`, and its
  // header is the argument), so this counter advances once per 2,000 real
  // nanoseconds and a CADR wall clock run off it loses half a day in a day.
  // Mete decided on 2026-09-11 that the machine keeps agreeing with muir for
  // now: the checks are the backbone, `iob.golden` compares tick counts, and
  // nothing built yet needs the time of day.  The card is not composed into
  // `cadr_machine` at all, so nothing on the board reads it.
  //
  // **UNDOING THIS IS STILL ONE CONSTANT, WHICH IS WHY THE TICK IS A NUMBER
  // THAT DIVIDES 1,000.**  A real microsecond is exactly 100 ticks of 10 ns,
  // a whole number, so restoring real time here means writing 100 in place of
  // the division below and changing nothing else --- at the price of this
  // module no longer agreeing with muir, which is why it has not been done.
  // It was 160 while the tick was 6.25 ns and 200 while it was 5; every tick
  // this board has been built with leaves the constant whole.
  // `SIXTY_CYCLE_NS` below is the same family and slows in the same
  // proportion, so its 60 Hz is 30 Hz of real time.
  localparam int unsigned FIRST_EDGE_T   = 890 / 5;
  localparam int unsigned USEC_PERIOD_T  = 1000 / 5;

  // `ioboard::KB_CLK_NS` = 8,000: `QC` of the 74LS163 at IOBCLK 0D24 counting
  // `1 USEC CLK`, out through the 74S37 at 0C25.  muir counts these from
  // power-on at multiples of 8,000 rather than from the microsecond clock's
  // own 890 ns offset, and it is muir this is held to.
  localparam int unsigned KB_CLK_T       = 8_000 / 5;

  // `ioboard::INTERVAL_TICK_NS` = 16,000: one count of the four 74LS193s at
  // CLKTIM on `16 USEC CLK`.  muir counts from the LOAD --- `ns - loaded >=
  // interval * 16,000` --- and not off a free-running 16 us clock, which would
  // bring `CLOCK READY` up by up to 16 us early.
  localparam int unsigned INTERVAL_T     = 16_000 / 5;

  // `ioboard::SIXTY_CYCLE_NS`, in nanoseconds, and the tick.  See the header:
  // this one is accumulated, never reloaded.
  localparam logic [23:0] SIXTY_CYCLE_NS = 24'd16_666_666;
  localparam logic [23:0] TICK_NS        = 24'd5;

  // `busint::IOB_STRAIGHT_NS` = 250, the TD250 at IOBADR 0E09, and the
  // counter's low half, `IOB_USEC_LOW_NS` = 313 --- the next edge of the
  // 16 MHz `MCLK^` and then the TD250 --- rounded UP to the 5 ns grid, which
  // is the trace's `slip`.
  localparam int unsigned STRAIGHT_T     = 250 / 5;
  localparam int unsigned USEC_LOW_T     = (313 + 4) / 5;

  // Nothing drives `UBO8`..`UBO15` on a read of the status register, the two
  // unnamed slots of the keyboard group, the beep or the GPIO.
  localparam logic [15:0] FLOATING       = 16'o177400;
  localparam logic [15:0] OPEN_BUS       = 16'o177777;

  // The block, `0o764000`-`0o764176`: the DM8136s at IOBADR 0F08 and 0F09
  // match `A<17:7>`, and the 74LS138 at 0E20 splits it into eight groups on
  // `A<6:4>`.  Group 4 is the keyboard and mouse, 5 the clocks and the GPIO,
  // 6 the Chaosnet interface and 7 the serial port; the first four go nowhere.
  localparam logic [10:0] BLOCK          = 11'd2000;   // 0o764000 >> 7
  localparam logic [2:0]  GROUP_KBM      = 3'd4;
  localparam logic [2:0]  GROUP_CLOCK    = 3'd5;

  // The keyboard-and-mouse group's eight registers, `A<3:1>`.
  localparam logic [2:0]  R_KBD_LOW      = 3'd0;
  localparam logic [2:0]  R_KBD_HIGH     = 3'd1;
  localparam logic [2:0]  R_MOUSE_Y      = 3'd2;
  localparam logic [2:0]  R_MOUSE_X      = 3'd3;
  localparam logic [2:0]  R_BEEP         = 3'd4;
  localparam logic [2:0]  R_CSR          = 3'd5;

  // The clock group's four, `A<2:1>` --- `A3` is not decoded.
  localparam logic [1:0]  C_USEC_LOW     = 2'd0;
  localparam logic [1:0]  C_USEC_HIGH    = 2'd1;
  localparam logic [1:0]  C_CLOCK        = 2'd2;

  // Page IOBINT: the 74S175 at 0F14 latches the four requests on the grant and
  // the 74LS00s at 0E12 make `V2 = (SER AND NOT CHAOS) OR CLOCK` and
  // `V3 = CLOCK OR CHAOS`.  So with more than one up the clock is named before
  // the Chaosnet before the serial port before the keyboard and mouse, which
  // share one.
  localparam logic [7:0]  KBD_VECTOR     = 8'o260;
  localparam logic [7:0]  SERIAL_VECTOR  = 8'o264;
  localparam logic [7:0]  CHAOS_VECTOR   = 8'o270;
  localparam logic [7:0]  CLOCK_VECTOR   = 8'o274;

  // --------------------------------------------------- the decode, and its hold

  logic in_block_c, kbm_c, clkgrp_c, sel_c;
  assign in_block_c = (ub_addr[17:7] == BLOCK) && !ub_addr[0];
  assign kbm_c      = in_block_c && (ub_addr[6:4] == GROUP_KBM);
  // `answers` refuses a WRITE of the microsecond counter's two halves, which
  // are `A<2:1>` 0 and 1; the interval timer and the GPIO take one.
  assign clkgrp_c   = in_block_c && (ub_addr[6:4] == GROUP_CLOCK);
  assign sel_c      = kbm_c || (clkgrp_c && (!ub_write || ub_addr[2]));

  // **HELD, NOT COMPUTED**: see the header.  These follow `ub_addr` a tick
  // behind, always, and every use of them below is at least fifty ticks after
  // `-UB MSYN` rose, so the tick is free.  They are the registers a scoped
  // XDC would name if this card ever needed one; nothing else here is more
  // than a tick deep.
  logic       sel, kbm, clkgrp, wr;
  logic [2:0] which;

  // --------------------------------------------------------- the clocks

  logic [31:0] usec;        // the 74S163 chain at IOBCLK, free-running
  logic [31:0] usec_latch;  // MIT's latch: what a read of the low half takes
  logic [7:0]  usec_t;      // ticks to the next edge of `1 USEC CLK`
  logic        usec_now;
  assign usec_now = (usec_t == 8'd0);
  logic [31:0] usec_next;
  assign usec_next = usec_now ? usec + 32'd1 : usec;

  logic [10:0] kb_t;        // ticks to the next edge of `KB CLK^`
  logic        kb_now;
  assign kb_now = (kb_t == 11'd0);

  logic [23:0] mains_acc;   // nanoseconds into the current mains cycle
  logic [15:0] mains;       // the two 74393s at CLKTOD, since power-on
  logic [23:0] mains_next, mains_less;
  assign mains_next = mains_acc + TICK_NS;
  // **THE WRAP IS A REGISTER, COMPARED A TICK EARLY, AND THE TWO CANDIDATES
  // ARE ADDERS IN PARALLEL.**  Written as a gate --- `mains_acc + 5 >=
  // SIXTY_CYCLE_NS`, and then that sum less the period --- it puts an adder,
  // a 24-bit compare and a subtraction in series on the accumulator's own
  // data pins: eleven logic levels, **-0.702 ns** out of context, measured,
  // and the worst path in the module by a mile.  `mains_acc >=
  // SIXTY_CYCLE_NS - 10` at tick t is `mains_acc + 5 >= SIXTY_CYCLE_NS` at
  // t+1, which is `cadr_phase_gen.sv`'s trick for its taps and
  // `cadr_disk_controller.sv`'s for its spindle; after a wrap the count is
  // under five, so the tick after a wrap cannot wrap and that term is written
  // in.  `mains_less` is `mains_acc + 5 - SIXTY_CYCLE_NS` as one addition of
  // a constant, so the two candidates are one carry chain each and the mux
  // is what follows them.
  //
  // **THE ACCUMULATOR IS READ EVERY TICK, SO IT CANNOT BE HELD.**  Whoever
  // composes this card under `cadr_machine` inherits `rtl/plumbing/xilinx7/cadr_machine.xdc`'s
  // relaxed set, which is every register minus a name list --- and these two
  // count every tick, as `elapsed` in the bus interface does.  A fit figure
  // for this module under the machine is not a figure until something has
  // asked the routed design which of its paths carry the fifteen-cycle
  // exception.
  assign mains_less = mains_acc + TICK_NS - SIXTY_CYCLE_NS;
  logic        mains_wrap;

  // ------------------------------------------------------- the mouse interface

  // The seven lines as the 74LS374 at IOBMSE 0A24 latches them on `KB CLK^`,
  // `NEW`; the 74LS374 at 0A22 latches `NEW` on the same clock as `OLD`, so
  // `OLD` is `NEW` a clock ago and the 25LS2521 at 0A21 compares the two.
  //
  // **`OLD` NEEDS NO REGISTER HERE.**  `MouseInterface::sample` moves both
  // latches at the edge and then counts and compares with the pair the edge
  // has just produced --- `old` taking what `new` held, `new` taking the lines
  // --- so at the edge that pair is (`mnew` as it stands, `lines`), and a
  // second register would hold a copy nothing reads.  muir's model is what
  // `tests/mouse_cable.rs` holds to the netlist board, so this follows it and
  // not the drawing's clock count.
  logic [6:0] lines, mnew;
  assign lines = ~mouse_lines;

  // IOBMS2's decoder, in the 74LS86s at 0A26 and 0B23: `OLD A xor NEW B` is the
  // direction into the 74LS569s' `U/-D`, and the enable is low --- counting ---
  // when exactly one line of the pair changed.  Both moving, or neither, counts
  // nothing, and a mouse stepping faster than the clock loses counts.
  //
  // **THE COUNT IS `count` AND NOT `q`**, which it was until this card was
  // composed under `cadr_machine`: `q` is the machine's own Q register and an
  // argument of that name hides it, which Verilator reports as VARHIDDEN and
  // `make build/arty.pass` stops on.  A name that is free in one module is not
  // free in the machine.
  function automatic logic [11:0] step_count(input logic [11:0] count,
                                             input logic [1:0]  o,
                                             input logic [1:0]  n);
    logic moved, up;
    moved = (o[0] ^ n[0]) ^ (o[1] ^ n[1]);
    up    = o[0] ^ n[1];
    step_count = moved ? (up ? count + 12'd1 : count - 12'd1) : count;
  endfunction

  // ------------------------------------------------------- the status register

  logic [3:0] en175;   // REMOTE MOUSE, MOUSE INT, KBD INT, CLOCK INT ENABLE
  logic       ser_en;  // SER INT ENABLE, the 74LS74 at IOBSER 0D21
  logic       kbd_ready, mouse_ready;
  logic [23:0] scancode;

  assign csr_face = {ser_en, 1'b0, kbd_ready, mouse_ready, en175};

  // ------------------------------------------------------- the interval timer

  logic [15:0] iv_count;   // counts the loaded interval down
  logic [11:0] iv_t;       // ticks to the next `16 USEC CLK`
  logic        iv_run;

  // ------------------------------------------------------------ the bus cycle

  logic       busy;      // `-UB MSYN` has been up since at least last tick
  logic       first;     // it rose last tick, so the held match is now good
  logic [1:0] edges;     // edges of `1 USEC CLK` STRICTLY after `-UB MSYN`
  logic [6:0] t_msyn;    // ticks since `-UB MSYN`, saturating
  logic [6:0] t_edge;    // ticks since the last counted edge, saturating

  // **SATURATING, NEVER WRAPPING.**  `elapsed` in `cadr_busint_xbus.sv` was ten
  // bits and wrapped, and `-XBUS.RQ` fell for sixteen ticks in the middle of
  // any cycle that reached 1,024 of them; six checks and sixty-three mutations
  // passed over it.  **Here it is belt and braces and the equivalence is
  // recorded rather than left for somebody to file as a hole**: `ub_ssyn`
  // latches once `answer_now` has been true, and nothing clears it while
  // `-UB MSYN` stands, so a counter that wrapped would still cross its
  // threshold for the first time at the same tick.  Saturating costs nothing
  // and takes the whole class away.
  localparam logic [6:0] T_MAX = 7'd127;

  logic answer_now;
  always_comb begin
    if (!sel) begin
      answer_now = 1'b0;
    end else if (kbm) begin
      // Two stages of the microsecond clock, then the TD250.
      answer_now = (edges >= 2'd2) && (t_edge >= 7'(STRAIGHT_T));
    end else if (which[1:0] == C_USEC_LOW) begin
      // One edge, and 313 ns rounded up to the grid.
      answer_now = (edges >= 2'd1) && (t_edge >= 7'(USEC_LOW_T));
    end else begin
      answer_now = (t_msyn >= 7'(STRAIGHT_T));
    end
  end

  // The tick the word crosses: `-UB SSYN` rises here and a write lands here,
  // where muir puts it.  One tick, because `ub_ssyn` stands for the rest of
  // the cycle.
  logic land;
  assign land = ub_msyn && answer_now && !ub_ssyn;

  // ------------------------------------------------------------ the read side

  logic [15:0] word;
  always_comb begin
    if (kbm) begin
      unique case (which)
        R_KBD_LOW:  word = scancode[15:0];
        R_KBD_HIGH: word = FLOATING | {8'd0, scancode[23:16]};
        // The read buffer at IOBMS2 0C24: `NEW`'s switches over the Y count,
        // its four quadrature lines over the X count, bit 15 on ground.
        R_MOUSE_Y:  word = {1'b0, mnew[6:4], mouse_y};
        R_MOUSE_X:  word = {mnew[3:0], mouse_x};
        R_CSR:      word = FLOATING | {8'd0, ser_en, clock_ready, kbd_ready,
                                       mouse_ready, en175};
        // The beep has no value in it, and neither have `0o764114` and
        // `0o764116`: nothing drives the lines and they read as ones.
        default:    word = OPEN_BUS;
      endcase
    end else begin
      unique case (which[1:0])
        C_USEC_LOW:  word = usec_latch[15:0];
        C_USEC_HIGH: word = usec_latch[31:16];
        C_CLOCK:     word = mains;
        default:     word = OPEN_BUS;   // the GPIO: nothing is wired to it
      endcase
    end
  end

  // **A SLAVE DRIVES THE LINES ONLY WHILE IT IS SELECTED.**  The DDR bridge
  // held the last word it returned and an unanswered cycle strobed MD with it;
  // the register is a stand-in for a driver, not a place to keep a word.
  assign ub_rdata = (sel && !wr) ? word : 16'd0;

  // ------------------------------------------------------------- the interrupt

  logic clock_req, ser_req, kbm_req;
  assign clock_req = en175[3] && clock_ready;
  assign ser_req   = ser_en && ser_ready;
  assign kbm_req   = (kbd_ready && en175[2]) || (mouse_ready && en175[1]);

  assign intr_request = clock_req || chaos_intr || ser_req || kbm_req;
  assign intr_vector  = clock_req  ? CLOCK_VECTOR
                      : chaos_intr ? CHAOS_VECTOR
                      : ser_req    ? SERIAL_VECTOR
                      : kbm_req    ? KBD_VECTOR
                                   : 8'd0;

  // `-INIT*` into the 8837 at IOBXCV 0F06 IS the 2651's `RESET` pin.
  assign ser_reset = ub_init;

  // ----------------------------------------------------------------- the card

  always_ff @(posedge clk) begin
    if (rst) begin
      sel         <= 1'b0;
      kbm         <= 1'b0;
      clkgrp      <= 1'b0;
      wr          <= 1'b0;
      which       <= 3'd0;

      usec        <= 32'd0;
      usec_latch  <= 32'd0;
      usec_t      <= 8'(FIRST_EDGE_T - 1);
      kb_t        <= 11'(KB_CLK_T - 1);
      mains_acc   <= 24'd0;
      mains_wrap  <= 1'b0;
      mains       <= 16'd0;

      // A mouse at rest on a board at rest: the latches hold what the lines
      // say, as they do two clocks after power-up, so nothing is a change
      // until the mouse moves.  `MouseInterface::default` does exactly this.
      mnew        <= ~mouse_lines;
      mouse_x     <= 12'd0;
      mouse_y     <= 12'd0;

      en175       <= 4'd0;
      ser_en      <= 1'b0;
      kbd_ready   <= 1'b0;
      mouse_ready <= 1'b0;
      scancode    <= 24'd0;

      // The 74LS279's latch at CLKTIM 0D09 reads SET from reset, because no
      // interval has been loaded: `interval_loaded_at` is `None`.
      clock_ready <= 1'b1;
      interval    <= 16'd0;
      iv_count    <= 16'd0;
      iv_t        <= 12'd0;
      iv_run      <= 1'b0;

      audio       <= 1'b0;

      ub_ssyn     <= 1'b0;
      busy        <= 1'b0;
      first       <= 1'b0;
      edges       <= 2'd0;
      t_msyn      <= 7'd0;
      t_edge      <= 7'd0;
    end else begin
      // --- the held match ------------------------------------------------
      sel    <= sel_c;
      kbm    <= kbm_c;
      clkgrp <= clkgrp_c;
      wr     <= ub_write;
      which  <= ub_addr[3:1];

      // --- the microsecond clock, which no reset moves --------------------
      usec <= usec_next;
      usec_t <= usec_now ? 8'(USEC_PERIOD_T - 1) : usec_t - 8'd1;

      // --- the sixty-cycle clock ------------------------------------------
      mains_wrap <= !mains_wrap && (mains_acc >= SIXTY_CYCLE_NS - 24'd10);
      mains_acc  <= mains_wrap ? mains_less : mains_next;
      if (mains_wrap) mains <= mains + 16'd1;

      // --- `KB CLK^`, the mouse's latches and its counters -----------------
      kb_t <= kb_now ? 11'(KB_CLK_T - 1) : kb_t - 11'd1;
      if (kb_now) begin
        mnew    <= lines;
        mouse_x <= step_count(mouse_x, mnew[1:0], lines[1:0]);
        mouse_y <= step_count(mouse_y, mnew[3:2], lines[3:2]);
        // `MOUSE STATUS CHANGE` off the 25LS2521 at IOBMSE 0A21 compares all
        // seven lines, so a switch alone sets the bit as a step does.
        if (lines != mnew) mouse_ready <= 1'b1;
      end

      // --- the interval timer ---------------------------------------------
      if (iv_run) begin
        if (iv_t == 12'd1) begin
          iv_t <= 12'(INTERVAL_T);
          if (iv_count == 16'd1) begin
            clock_ready <= 1'b1;
            iv_run      <= 1'b0;
          end else begin
            iv_count <= iv_count - 16'd1;
          end
        end else begin
          iv_t <= iv_t - 12'd1;
        end
      end

      // --- the keyboard's cable -------------------------------------------
      if (kbd_strobe) begin
        scancode  <= kbd_code;
        kbd_ready <= 1'b1;
      end

      // --- the bus cycle ---------------------------------------------------
      if (!ub_msyn) begin
        ub_ssyn <= 1'b0;
        busy    <= 1'b0;
        first   <= 1'b0;
        edges   <= 2'd0;
        t_msyn  <= 7'd0;
        t_edge  <= 7'd0;
      end else begin
        busy  <= 1'b1;
        first <= !busy;
        if (t_msyn != T_MAX) t_msyn <= t_msyn + 7'd1;
        // STRICTLY after `-UB MSYN`: an edge on the tick the strobe arrives is
        // the edge muir's `usec_edge_after` steps past.
        if (busy && usec_now) begin
          if (edges != 2'd3) edges <= edges + 2'd1;
          t_edge <= 7'd1;
        end else if (t_edge != 7'd0 && t_edge != T_MAX) begin
          t_edge <= t_edge + 7'd1;
        end

        // **THE COUNTER'S LOW HALF IS THE COUNT AS IT STOOD AT `-UB MSYN`**,
        // and it latches the whole thirty-two bits on its way to answering.
        // Taken a tick after the strobe, which is where the held match first
        // says whose cycle this is and where `usec` holds what it held at the
        // strobe's own tick.
        if (first && sel && !wr && clkgrp && which[1:0] == C_USEC_LOW) begin
          usec_latch <= usec;
        end

        if (answer_now) ub_ssyn <= 1'b1;

        // --- what the cycle does, at `-UB SSYN` ---------------------------
        if (land) begin
          if (kbm) begin
            unique case (which)
              // The 74LS74 at IOBKBD 0B30 has `-READ.KBD.LOW` on its CLEAR pin
              // and nothing else: the high half's read leaves the bit standing,
              // which is why microcode 323's channel reads the high half first.
              R_KBD_LOW: if (!wr) kbd_ready <= 1'b0;
              // The 74LS109 at IOBCSR 0C26 has `-READ.MOUSE.Y` on its clear;
              // a read of X leaves it.  AFTER the `KB CLK^` edge above, because
              // muir samples the mouse and then clears, so a read landing on
              // the very edge that sets the bit clears it.
              R_MOUSE_Y: if (!wr) mouse_ready <= 1'b0;
              // `-CLICK.AUDIO` is `Y4` of the 74LS138 at IOBKBD 0C22 and is NOT
              // gated by `-WRITE`, so a read clicks as a write does.
              R_BEEP:    audio <= !audio;
              // `ioboard::csr::WRITABLE` is `0o217`: the 74LS175's four and
              // the serial enable, and nothing above them.  The two ready bits
              // stand through a write, which is what the trace's write of zero
              // with both up is there to say.
              R_CSR: if (wr) begin
                en175  <= ub_wdata[3:0];
                ser_en <= ub_wdata[7];
              end
              default: ;
            endcase
          end else if (wr && which[1:0] == C_CLOCK) begin
            // `-LOAD INTERVAL` loads the four 74LS193s from `UBI0`..`UBI15` and
            // clears the 74LS279's latch.  An interval of zero is over the
            // moment it is loaded.
            interval    <= ub_wdata;
            iv_count    <= ub_wdata;
            iv_t        <= 12'(INTERVAL_T);
            iv_run      <= (ub_wdata != 16'd0);
            clock_ready <= (ub_wdata == 16'd0);
          end
        end
      end

      // --- `-UB INIT`, last, because a clear is a pin and not a clock -------
      if (ub_init) begin
        en175  <= 4'd0;
        ser_en <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
