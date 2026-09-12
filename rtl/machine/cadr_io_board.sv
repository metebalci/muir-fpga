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
//   0o764140  CHAOS CSR   AIM-628 section 7's command and status register
//   0o764142  read MY ADDRESS, written a word into the outgoing packet buffer
//   0o764144  READ BUFFER a word out of the incoming packet buffer, read only
//   0o764146  BIT COUNT   its bits less one, read only
//   0o764152  read START, which is MY ADDRESS again and sends the buffer
//   0o764154  the one address of the whole block that answers NEITHER way
//   0o764160  the 2651: received data read, transmit data written
//   0o764162  read the status register, written the SYN and DLE registers
//   0o764164  mode register 1, then mode register 2
//   0o764166  the command register; a read of it puts the pointers back
//
// `A3` is decoded in the Chaosnet's group for exactly two things --- START
// against MY ADDRESS, and disabling the receive buffer's read --- and NOT AT
// ALL at the 2651, so `0o76417x` is `0o76416x`.
//
// **WHAT IS NOT HERE: THE PROTOCOL, WHICH IS LINUX'S.**  The Chaosnet's
// cable, its turn timer at LMTURN, the frame, the check word and the
// transceiver are the `cadr-chaosnet` program's; the 2651's baud-rate
// generator at IOBSER 0A15 and its line are `cadr-serial`'s, the line being a
// TCP socket as muir's `--serial` offers it.  **The generator is left out
// deliberately**: it divides the 5.0688 MHz can to instants that are not
// multiples of five --- one bit at 9,600 baud is 104,166 ns --- so the 5 ns
// grid cannot carry them, and what the card has instead is a seam.
// `docs/io-board.md`'s "What slice five built" says what each program owes
// the card at the register face.  The SYN registers, the parity and framing
// flags, the two echoing modes and the Chaosnet's timer interrupt are not
// built either, and it says why: nothing in muir or on this board can tell a
// card that has them from one that does not.
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

    // --- THE SERIAL PORT, the Signetics 2651 at IOBSER 0A12.
    //
    // **THE REGISTERS ARE THIS CARD'S AND THE LINE IS NOT.**  The chip's
    // four registers, its two pointers, its status byte and its holding
    // registers are here; the baud-rate generator at 0A15 is not, because
    // the 5.0688 MHz can divides to instants that are not multiples of five
    // --- one bit at 9,600 baud is 104,166 ns --- and because the line on
    // this board is a TCP socket `cadr-serial` paces.  So the shift
    // register's two edges come in on the seam: `ser_tx_take` is the
    // character leaving the holding register at the first 16X clock, and
    // `ser_tx_done` is its frame ending.  `docs/io-board.md` says what the
    // program owes the card.
    output var logic        ser_reset,    // `-INIT*` IS the chip's RESET pin
    output var logic [7:0]  ser_mode1,    // what the software set: the frame
    output var logic [7:0]  ser_mode2,    // ...and the baud rate, `MR23`-`MR20`
    output var logic [7:0]  ser_cmd,      // the command register, `-DTR` and `-RTS` in it
    output var logic        ser_tx_strobe,// a character reaches the cable
    output var logic [7:0]  ser_tx_data,
    input  var logic        ser_tx_take,  // the shift register takes the holding register
    input  var logic        ser_tx_done,  // its frame ends
    input  var logic        ser_rx_strobe,// a character reaches the receive path
    input  var logic [7:0]  ser_rx_data,
    // `-DSR`, `-DCD` and `-CTS` off the MC1489 at IOBSER 0B16.  Open, the
    // sheet's `V_OH` row gives the chip all three high and it stops.
    input  var logic        ser_plugged,
    output var logic [7:0]  ser_status,   // `SR7`-`SR0` as a read assembles them

    // --- THE CHAOSNET INTERFACE, the `lm*` pages of `data/CADRIO.netlist`.
    //
    // **THE REGISTERS AND THE TWO BUFFERS ARE THIS CARD'S AND THE CABLE IS
    // NOT.**  AIM-628 section 7's five registers, the 2147s at LMTBUF 0C10
    // and LMRBUF 0C04 as 256 words each, the bit counter's arithmetic, the
    // lost count and the priority chain are here; the turn timer at LMTURN,
    // the frame, the check word and the transceiver are the `cadr-chaosnet`
    // program's.  A frame goes out as a burst on `chaos_tx_*` when START is
    // read and comes in as a burst on `chaos_rx_*`.
    input  var logic [15:0] chaos_address,  // the switches at LMMYNM D10 and D12
    output var logic        chaos_tx_go,    // START was read: this frame is to go
    output var logic [8:0]  chaos_tx_len,   // how many words of it, 0 to 256
    output var logic        chaos_tx_valid, // one word of it, in order, from the tick after
    output var logic [15:0] chaos_tx_word,
    output var logic        chaos_tx_clear, // Clear Transmitter: drop a frame not yet away
    output var logic        chaos_reset,    // Reset, or `-UB INIT`
    output var logic [15:0] chaos_csr,      // the CSR as a read assembles it
    input  var logic        chaos_rx_valid, // one word into the receive buffer
    input  var logic [15:0] chaos_rx_word,
    input  var logic        chaos_rx_done,  // that was the packet
    input  var logic [12:0] chaos_rx_bits,  // its length, what the bit counter loads
    input  var logic        chaos_rx_crc,   // its check word failed
    input  var logic        chaos_tx_done,  // the frame is away
    input  var logic        chaos_tx_abort, // ...or a collision took it
    input  var logic        chaos_cbl_busy, // `-CBLBSY`, which bit 14 reads out beside the CRC
    output var logic [11:0] chaos_bits,     // the bit counter, for the check

    // --- the Unibus interrupt: `-UB INTR` and `-UB BR5` on the backplane.
    // Nothing in `rtl/` runs a Unibus interrupt cycle yet, so the vector
    // goes to `cadr_busint_regs.sv` on a wire, as muir's does.
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
  localparam logic [2:0]  GROUP_CHAOS    = 3'd6;
  localparam logic [2:0]  GROUP_SERIAL   = 3'd7;

  // `busint::IOB_CHAOS_BUFFER_NS` = 350: the transmit buffer's write and
  // START, through the transmitter's `-TSR.SSYN`, measured at every phase of
  // the board's clocks.
  localparam int unsigned CHAOS_BUF_T    = 350 / 5;

  // The Chaosnet receive buffer's read: `-MSYN` taken at the first `FCLK^`
  // edge AT LEAST `busint::IOB_RBUF_SETUP_NS` = 33 ns after it, the word out
  // of the buffer's RAM and `-SSYN` a TD250 later.  `FCLK^` is 8 MHz off the
  // 74S163 at LMTCLK 0B03, an edge every 125 ns at multiples of 125 from
  // power-on --- 25 ticks --- so the condition is the first edge at a tick
  // at or after `-UB MSYN` plus 33 ns, which on the grid is seven ticks.
  localparam int unsigned FCLK_T         = 125 / 5;
  localparam int unsigned RBUF_SETUP_T   = (33 + 4) / 5;

  // The serial port's select is synchronised to a half-microsecond clock
  // whose phase `busint::IOB_HALF_USEC_PHASE_NS` measures at 203 ns on the
  // netlist board, through the two 74LS74s at IOBSER 0F29; the answer is
  // `busint::IOB_SERIAL_NS` = 750 after the first edge STRICTLY after
  // `-MSYN`.  **THIS IS THE SECOND PLACE THIS CARD IS OFF THE 5 ns GRID AND
  // THE ONLY ONE THAT IS ALWAYS OFF IT**: 203 + 500k + 750 is 953 + 500k,
  // which is 3 modulo 5, so the answer is two nanoseconds past a tick on
  // EVERY cycle of the group and the trace carries a `slip` of 2 on all of
  // them.  Rounding up is exact, and the edges are counted on the grid at
  // 205 + 500k for the same reason: no multiple of five lies between 203 and
  // 205 modulo 500, so an edge is strictly after `-MSYN` on the grid exactly
  // where it is strictly after it on the netlist.
  localparam int unsigned HU_PERIOD_T    = 500 / 5;
  localparam int unsigned HU_FIRST_T     = (203 + 4) / 5;
  localparam int unsigned SERIAL_T       = 750 / 5;

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
  assign clkgrp_c   = in_block_c && (ub_addr[6:4] == GROUP_CLOCK);

  // The Chaosnet's group, the 74LS138 at LMUCON 0C18: `A<2:1>` AND READ
  // AGAINST WRITE.  `0o764140` is the CSR both ways; `0o764142` is MY
  // ADDRESS read and the transmit buffer written, and with `A3` up START
  // read and the transmit buffer written again; `0o764144` is the receive
  // buffer READ ONLY and `0o764154` is nothing at all, `A3` disabling it;
  // `0o764146` is the bit count read only.  Five of the group's sixteen
  // directions are answered by nothing, where the serial port's sixteen are
  // all answered.
  logic chgrp_c, sergrp_c, ch_sel_c;
  assign chgrp_c  = in_block_c && (ub_addr[6:4] == GROUP_CHAOS);
  assign sergrp_c = in_block_c && (ub_addr[6:4] == GROUP_SERIAL);
  assign ch_sel_c = chgrp_c && ((ub_addr[2:1] == 2'd0)
                                || (ub_addr[2:1] == 2'd1)
                                || (ub_addr[2:1] == 2'd2 && !ub_write && !ub_addr[3])
                                || (ub_addr[2:1] == 2'd3 && !ub_write));

  // `answers` refuses a WRITE of the microsecond counter's two halves, which
  // are `A<2:1>` 0 and 1; the interval timer and the GPIO take one.
  assign sel_c      = kbm_c || (clkgrp_c && (!ub_write || ub_addr[2]))
                      || ch_sel_c || sergrp_c;

  // **HELD, NOT COMPUTED**: see the header.  These follow `ub_addr` a tick
  // behind, always, and every use of them below is at least fifty ticks after
  // `-UB MSYN` rose, so the tick is free.  They are the registers a scoped
  // XDC would name if this card ever needed one; nothing else here is more
  // than a tick deep.
  logic       sel, kbm, clkgrp, chgrp, sergrp, wr;
  logic [2:0] which;

  // --------------------------------------------------------- the clocks

  logic [31:0] usec;        // the 74S163 chain at IOBCLK, free-running
  logic [31:0] usec_latch;  // MIT's latch: what a read of the low half takes
  logic [7:0]  usec_t;      // ticks to the next edge of `1 USEC CLK`
  logic        usec_now;
  assign usec_now = (usec_t == 8'd0);
  logic [31:0] usec_next;
  assign usec_next = usec_now ? usec + 32'd1 : usec;

  logic [6:0]  hu_t;        // ticks to the next edge of the half-microsecond clock
  logic        hu_now;
  assign hu_now = (hu_t == 7'd0);

  logic [4:0]  fclk_t;      // ticks to the next edge of `FCLK^`
  logic        fclk_now;
  assign fclk_now = (fclk_t == 5'd0);

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

  // ============================ THE SERIAL PORT ============================
  //
  // The Signetics 2651 at IOBSER 0A12 as `serial::Pci` has it: `A1` and `A0`
  // are `UBADDR2` and `UBADDR1`, so `which[1:0]` picks the register, and `A3`
  // IS NOT DECODED --- `764170`-`764176` are the same four again.  The chip
  // drives `D0`..`D7` alone, so the upper byte floats.

  logic [7:0] s_mode1, s_mode2, s_cmd;
  logic       s_second;      // the mode pointer: register 2 next
  logic [7:0] s_rhr, s_thr, s_shift;
  logic       s_rx_ready, s_thr_full, s_shifting, s_tx_empty, s_dschg;
  logic [2:0] s_errors;      // framing, overrun, parity: `SR5`-`SR3`
  logic       s_dsr_was, s_dcd_was;

  // Table 5 and Table 6, and the command register's own four modes.
  logic [1:0] s_mode;
  logic       s_local, s_dsr, s_dcd, s_cts, s_txclk, s_rxclk;
  logic       s_tx_on, s_rx_on, s_rx_runs, s_tx_ready, s_tx_empty_vis;
  assign s_mode   = s_cmd[7:6];        // 0 normal, 1 auto echo, 2 local, 3 remote
  assign s_local  = (s_mode == 2'd2);
  assign s_dsr    = ser_plugged;
  assign s_dcd    = s_local ? s_cmd[1] : ser_plugged;   // `-DTR`'s in local loop back
  assign s_cts    = s_local ? s_cmd[5] : ser_plugged;   // `-RTS`'s in local loop back
  // Asynchronous, on the internal clock, which on this board is the only one
  // the chip can have: `-TxC` and `-RxC` are not connected.
  assign s_txclk  = (s_mode1[1:0] != 2'd0) && s_mode2[5];
  assign s_rxclk  = (s_mode1[1:0] != 2'd0) && s_mode2[4];
  // Auto echo and remote loop back cut "the CPU to transmitter link".
  assign s_tx_on  = s_cmd[0] && s_txclk && (s_mode == 2'd0 || s_mode == 2'd2);
  // "CR2 (RxEN) is ignored" in local loop back.
  assign s_rx_on  = (s_cmd[2] || s_local) && s_rxclk;
  assign s_rx_runs = s_rx_on && s_dcd;
  assign s_tx_ready = s_tx_on && !s_thr_full;
  assign s_tx_empty_vis = s_cmd[0] && s_tx_empty;

  assign ser_status = {s_dsr, s_dcd, s_errors, s_tx_empty_vis || s_dschg, s_rx_ready, s_tx_ready};
  assign ser_mode1 = s_mode1;
  assign ser_mode2 = s_mode2;
  assign ser_cmd   = s_cmd;

  // "If the character length is less than 8 bits, the high order unused bits
  // in the Holding Register are set to zero": `Framing::mask`, `MR13 MR12`
  // choosing 5 to 8.
  logic [7:0] s_mask;
  assign s_mask = 8'hff >> (2'd3 - s_mode1[3:2]);

  // What a read of the group gives, before the floating byte.
  logic [7:0] s_byte;
  always_comb begin
    unique case (which[1:0])
      2'd0:    s_byte = s_rhr;
      2'd1:    s_byte = ser_status;
      2'd2:    s_byte = s_second ? s_mode2 : s_mode1;
      default: s_byte = s_cmd;
    endcase
  end

  // ========================= THE CHAOSNET INTERFACE =========================
  //
  // The 74LS138 at LMUCON 0C18 decodes `A<2:1>` AND READ AGAINST WRITE, so
  // the same address is a different register in the two directions, and `A3`
  // is decoded for exactly two things: a read of `764152` is START where
  // `764142` is MY ADDRESS, and the receive buffer's read is disabled at
  // `764154`, which then answers nothing.  `which[1:0]` is `A<2:1>` and
  // `which[2]` is `A3`.

  localparam int unsigned CH_WORDS = 256;
  // The 2147 at LMTBUF 0C10 and its twin at LMRBUF 0C04: 4,096 bits each on
  // `TBCT<11:0>` and `RBCT<11:0>`, so 256 sixteen-bit words and a word past
  // that has nowhere to go.
  logic [15:0] ch_xmit [CH_WORDS];
  logic [15:0] ch_rcv  [CH_WORDS];
  logic [8:0]  ch_xn;        // words in the transmit buffer, 0 to 256
  logic        ch_taken;     // START took it: the next write starts again at 0
  logic [8:0]  ch_fill;      // words the far end has put in for the next packet
  logic [8:0]  ch_rlen;      // words the packet in the buffer has
  logic [8:0]  ch_rat;       // the read pointer, the 25LS193s at LMRBUF
  logic [12:0] ch_rbits;     // what the bit counter was loaded with
  logic [12:0] ch_left;      // bits not yet read out
  logic [5:0]  ch_wbits;     // the five bits a write reaches, `chaos::board::WRITABLE`
  logic        ch_tdone, ch_tabort, ch_rdone, ch_crc;
  logic [3:0]  ch_lost;
  logic [15:0] ch_rd;        // the buffer's word at `ch_rat`, a tick behind
  logic [8:0]  ch_out, ch_send;
  logic        ch_sending;

  // Where the next word of a packet goes.  **ONE WRITE PORT, AND THE MUX IS
  // ON ITS ADDRESS RATHER THAN IN THE PROCESS.**  A read of START takes the
  // buffer (`Interface::start`'s `mem::take`), so the next word written
  // starts a new packet at word zero; written as two stores at two addresses
  // that is two write ports on one array, which Vivado refuses the way it
  // refuses a mux on a RAM's read --- `Synth 8-2914`, a hard stop this
  // project has already met once at the disk's block store.
  logic [8:0] ch_wn;
  assign ch_wn = ch_taken ? 9'd0 : ch_xn;

  // "All read/write bits are initialized to zero on power-up", and the ten
  // the hardware makes up: Receive Done, the CRC error --- which is one net
  // with `-CBLBSY` on the board and two things to the software --- the lost
  // count, Transmit Done and Transmit Abort.  Bits 13, 8 and 3 are the three
  // write-only commands and read as zero.
  assign chaos_csr = {ch_rdone, ch_crc || chaos_cbl_busy, 1'b0, ch_lost, 1'b0,
                      ch_tdone, ch_tabort, ch_wbits};

  // "The number of bits in the incoming packet buffer, minus one.  After the
  // whole packet has been read out, it will contain 7777."  `ch_left` is
  // `rcv_bits - read` kept incrementally, so the subtraction never lands in
  // the read path: the first read takes the partial word wreckage puts at
  // the top and every one after it takes sixteen.
  logic [12:0] ch_top, ch_step;
  logic [11:0] ch_less;
  assign ch_top  = ch_rbits - {(ch_rlen - 9'd1), 4'd0};
  assign ch_step = (ch_rat == 9'd0) ? ch_top : 13'd16;
  // `(left - 1) & 0o7777` in twelve bits: the subtraction wraps the same way.
  assign ch_less = ch_left[11:0] - 12'd1;
  assign chaos_bits = !ch_rdone          ? 12'd0
                    : (ch_left == 13'd0) ? 12'o7777
                                         : ch_less;

  logic ch_buf, ch_rbuf;
  // The transmit buffer's write and START go through the transmitter's
  // `-TSR.SSYN`; the receive buffer's read comes off its RAM on `FCLK^`.
  // **GATED ON THE GROUP.**  `which` is `A<3:1>` and says nothing about which
  // of the eight groups the 74LS138 at IOBADR 0E20 picked, so an ungated
  // match here reaches the clock group's own registers --- `0o764124` has
  // `A<2:1>` = 2 and read it is the sixty-cycle clock, not a packet buffer.
  assign ch_buf  = chgrp && (which[1:0] == 2'd1) && (wr || which[2]);
  assign ch_rbuf = chgrp && (which[1:0] == 2'd2) && !wr && !which[2];

  logic [15:0] ch_now;
  always_comb begin
    unique case (which[1:0])
      2'd0:    ch_now = chaos_csr;
      // MY ADDRESS, and START, which "the value read is the network address
      // of this interface ... makes it easier for the hardware to get the
      // source address into the packet".
      2'd1:    ch_now = chaos_address;
      // "The last three words read are the destination address, the source
      // address, and the checksum", and past them the buffer reads zero:
      // `self.rcv.get(self.rcv_at).copied().unwrap_or(0)`.  A slave that gave
      // back the word its RAM still held would hand the software the last
      // packet again --- the DDR bridge's lesson at a second buffer.
      2'd2:    ch_now = (ch_rat < ch_rlen) ? ch_rd : 16'd0;
      default: ch_now = {4'd0, chaos_bits};
    endcase
  end

  // **THE WORD IS HELD FOR THE WHOLE CYCLE ONCE `-UB SSYN` IS UP.**  Both of
  // these groups have reads that change what the next read of the same
  // address gives --- the buffer's pointer, the mode pointer, the
  // data-set-change latch --- and `cadr_busint_xbus.sv` strobes MD
  // `UNIBUS_STROBE_NS` = 100 ns AFTER `-UB SSYN`, twenty ticks later.  A
  // slave whose lines moved in between would hand the machine the next word.
  logic [15:0] new_now, new_held;
  assign new_now = chgrp ? ch_now : (FLOATING | {8'd0, s_byte});

  logic ch_req;
  assign ch_req = (ch_rdone && ch_wbits[4]) || (ch_tdone && ch_wbits[5]);

  // Whether the receiver would still be on under the word being stored into
  // the command register: `RxRDY` clears "when the receiver is disabled by
  // CR2", and the test is against the NEW command and not the old one.
  logic cmd_rx_on;
  assign cmd_rx_on = (ub_wdata[2] || (ub_wdata[7:6] == 2'd2)) && s_rxclk;


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
  logic       hu_edge1;  // a half-microsecond edge has fallen strictly after `-UB MSYN`
  logic [7:0] t_hu;      // ticks since it, saturating
  logic       fc_edge1;  // an `FCLK^` edge has fallen at or after `-MSYN` + 33 ns
  logic [6:0] t_fclk;    // ticks since it, saturating

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
    end else if (clkgrp && which[1:0] == C_USEC_LOW) begin
      // One edge, and 313 ns rounded up to the grid.
      answer_now = (edges >= 2'd1) && (t_edge >= 7'(USEC_LOW_T));
    end else if (sergrp) begin
      // The first half-microsecond edge strictly after `-MSYN`, then 750 ns.
      answer_now = hu_edge1 && (t_hu >= 8'(SERIAL_T));
    end else if (ch_rbuf) begin
      // The first `FCLK^` edge at or after `-MSYN` plus 33 ns, then a TD250.
      answer_now = fc_edge1 && (t_fclk >= 7'(STRAIGHT_T));
    end else if (ch_buf) begin
      // Through the transmitter's `-TSR.SSYN`.
      answer_now = (t_msyn >= 7'(CHAOS_BUF_T));
    end else begin
      answer_now = (t_msyn >= 7'(STRAIGHT_T));
    end
  end

  // The tick the word crosses: `-UB SSYN` rises here and a write lands here,
  // where muir puts it.  One tick, because `ub_ssyn` stands for the rest of
  // the cycle.
  logic land;
  assign land = ub_msyn && answer_now && !ub_ssyn;

  // Reset: AIM-628's "completely resets the interface, just as at power up
  // and Unibus Initialize", which is the write-only bit 13 of the CSR and
  // `-INIT*` into the 8837 at IOBXCV 0F06 alike.  It subsumes Clear Receiver
  // and Clear Transmitter, so it is applied at the foot of the block where
  // `-UB INIT` already is and the order inside a store costs nothing.
  logic ch_reset_now;
  assign ch_reset_now = ub_init
      || (land && chgrp && wr && (which[1:0] == 2'd0) && ub_wdata[13]);

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
    end else if (clkgrp) begin
      unique case (which[1:0])
        C_USEC_LOW:  word = usec_latch[15:0];
        C_USEC_HIGH: word = usec_latch[31:16];
        C_CLOCK:     word = mains;
        default:     word = OPEN_BUS;   // the GPIO: nothing is wired to it
      endcase
    end else begin
      word = ub_ssyn ? new_held : new_now;
    end
  end

  // **A SLAVE DRIVES THE LINES ONLY WHILE IT IS SELECTED.**  The DDR bridge
  // held the last word it returned and an unanswered cycle strobed MD with it;
  // the register is a stand-in for a driver, not a place to keep a word.
  assign ub_rdata = (sel && !wr) ? word : 16'd0;

  // ------------------------------------------------------------- the interrupt

  // `SER.IREQ` is the 2651's `-RxRDY` and, by ECO 10 of `cadrio/iob.eco`,
  // its `-TxRDY` on the same net, through the 74LS02 at IOBSER 0E11 ---
  // which is why System 100's `sys/io1/serial.lisp` runs an output channel
  // and an input channel on one vector.  **IT IS NO LONGER A PORT**: the
  // chip is on this card now, so a testbench line left driving it fails to
  // compile rather than quietly supplying the answer, which is the `md` trap
  // this project records.  `CHAOS.IREQ` went the same way.
  logic clock_req, ser_req, kbm_req;
  assign clock_req = en175[3] && clock_ready;
  assign ser_req   = ser_en && (s_rx_ready || s_tx_ready);
  assign kbm_req   = (kbd_ready && en175[2]) || (mouse_ready && en175[1]);

  assign intr_request = clock_req || ch_req || ser_req || kbm_req;
  assign intr_vector  = clock_req ? CLOCK_VECTOR
                      : ch_req    ? CHAOS_VECTOR
                      : ser_req   ? SERIAL_VECTOR
                      : kbm_req   ? KBD_VECTOR
                                  : 8'd0;

  // `-INIT*` into the 8837 at IOBXCV 0F06 IS the 2651's `RESET` pin.
  assign ser_reset = ub_init;

  // ----------------------------------------------------------------- the card

  always_ff @(posedge clk) begin
    if (rst) begin
      sel         <= 1'b0;
      kbm         <= 1'b0;
      clkgrp      <= 1'b0;
      chgrp       <= 1'b0;
      sergrp      <= 1'b0;
      wr          <= 1'b0;
      which       <= 3'd0;
      new_held    <= 16'd0;

      usec        <= 32'd0;
      usec_latch  <= 32'd0;
      usec_t      <= 8'(FIRST_EDGE_T - 1);
      hu_t        <= 7'(HU_FIRST_T - 1);
      fclk_t      <= 5'(FCLK_T - 1);
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
      hu_edge1    <= 1'b0;
      t_hu        <= 8'd0;
      fc_edge1    <= 1'b0;
      t_fclk      <= 7'd0;

      // The Chaosnet interface as at power-up: "all read/write bits are
      // initialized to zero", Transmit Done up so that the first
      // transmission may start --- `CHAOS-XMT-INTR` waits for it --- and the
      // receiver ready for a packet.
      ch_wbits    <= 6'd0;
      ch_tdone    <= 1'b1;
      ch_tabort   <= 1'b0;
      ch_rdone    <= 1'b0;
      ch_crc      <= 1'b0;
      ch_lost     <= 4'd0;
      ch_xn       <= 9'd0;
      ch_taken    <= 1'b0;
      ch_fill     <= 9'd0;
      ch_rlen     <= 9'd0;
      ch_rat      <= 9'd0;
      ch_rbits    <= 13'd0;
      ch_left     <= 13'd0;
      ch_rd       <= 16'd0;
      ch_out      <= 9'd0;
      ch_send     <= 9'd0;
      ch_sending  <= 1'b0;
      chaos_tx_go    <= 1'b0;
      chaos_tx_len   <= 9'd0;
      chaos_tx_valid <= 1'b0;
      chaos_tx_word  <= 16'd0;
      chaos_tx_clear <= 1'b0;
      chaos_reset    <= 1'b0;

      // The 2651 as its `RESET` pin leaves it: every register zero, which is
      // synchronous mode and so both halves stopped.
      s_mode1     <= 8'd0;
      s_mode2     <= 8'd0;
      s_cmd       <= 8'd0;
      s_second    <= 1'b0;
      s_rhr       <= 8'd0;
      s_thr       <= 8'd0;
      s_shift     <= 8'd0;
      s_rx_ready  <= 1'b0;
      s_thr_full  <= 1'b0;
      s_shifting  <= 1'b0;
      s_tx_empty  <= 1'b0;
      s_dschg     <= 1'b0;
      s_errors    <= 3'd0;
      // `Pci::reset` takes the modem lines as they stand, so a reset is not
      // itself a data-set change.
      s_dsr_was   <= ser_plugged;
      s_dcd_was   <= ser_plugged;
      ser_tx_strobe <= 1'b0;
      ser_tx_data   <= 8'd0;
    end else begin
      // --- the held match ------------------------------------------------
      sel    <= sel_c;
      kbm    <= kbm_c;
      clkgrp <= clkgrp_c;
      chgrp  <= chgrp_c;
      sergrp <= sergrp_c;
      wr     <= ub_write;
      which  <= ub_addr[3:1];

      // --- the two far ends, which are Linux's ---------------------------
      //
      // BEFORE the bus cycle's own work, because muir's `Interface::write`
      // and `Pci::write` both advance to the instant FIRST and apply the
      // store after: with non-blocking assignments the later statement is
      // the one that stands, so a store landing on the same tick as
      // something off the cable wins, as it does there.
      chaos_tx_go    <= 1'b0;
      chaos_tx_clear <= 1'b0;
      chaos_reset    <= 1'b0;
      chaos_tx_valid <= 1'b0;
      ser_tx_strobe  <= 1'b0;

      // The transmit buffer streams out from the tick after START, a word a
      // tick, and `cadr-chaosnet` frames it.
      if (ch_sending) begin
        chaos_tx_valid <= 1'b1;
        chaos_tx_word  <= ch_xmit[ch_out[7:0]];
        ch_out         <= ch_out + 9'd1;
        if (ch_out + 9'd1 == ch_send) ch_sending <= 1'b0;
      end

      // The receive buffer fills a word at a time and commits whole.  A
      // packet arriving on a buffer nobody emptied is DROPPED WHOLE and
      // counted, which is what the four bits of `LOST COUNT` are for; muir's
      // `arrive` does the same and says so.
      if (chaos_rx_valid && !ch_rdone && ch_fill != 9'd256) begin
        ch_rcv[ch_fill[7:0]] <= chaos_rx_word;
        ch_fill              <= ch_fill + 9'd1;
      end
      if (chaos_rx_done) begin
        ch_fill <= 9'd0;
        if (ch_rdone) begin
          if (ch_lost != 4'd15) ch_lost <= ch_lost + 4'd1;
        end else begin
          ch_rlen  <= ch_fill;
          ch_rbits <= chaos_rx_bits;
          ch_left  <= chaos_rx_bits;
          ch_rat   <= 9'd0;
          ch_crc   <= chaos_rx_crc;
          ch_rdone <= 1'b1;
        end
      end
      if (chaos_tx_done) begin
        ch_tdone  <= 1'b1;
        ch_tabort <= chaos_tx_abort;
      end
      // The buffer's word at the pointer, a tick behind it.  The pointer
      // moves only at `-UB SSYN`, so this is a synchronous read of an
      // address constant for the whole cycle --- the same fact that makes
      // the control store and the scratchpads legitimate.
      ch_rd <= ch_rcv[ch_rat[7:0]];

      // The 2651's modem lines.  `Pci::advance` raises the data-set-change
      // latch wherever `-DSR` or `-DCD` is not where it was, and in local
      // loop back `-DCD` is the chip's own `-DTR`, so a store into the
      // command register can move it.
      if (s_dsr != s_dsr_was || s_dcd != s_dcd_was) begin
        s_dschg   <= 1'b1;
        s_dsr_was <= s_dsr;
        s_dcd_was <= s_dcd;
      end
      // Its shift register's two edges, which are the baud-rate generator's
      // and so the far end's.  `Pci::transmit`, written out.
      if (ser_tx_done && s_shifting) begin
        s_shifting <= 1'b0;
        if (s_local) begin
          if (s_rx_ready) s_errors[1] <= 1'b1;
          s_rhr      <= s_shift & s_mask;
          s_rx_ready <= 1'b1;
        end else begin
          ser_tx_strobe <= 1'b1;
          ser_tx_data   <= s_shift & s_mask;
        end
        if (!(s_thr_full && s_tx_on && s_cts)) s_tx_empty <= 1'b1;
      end
      if (ser_tx_take && s_thr_full && s_tx_on && s_cts && (!s_shifting || ser_tx_done)) begin
        s_shifting <= 1'b1;
        s_shift    <= s_thr;
        s_thr_full <= 1'b0;
      end
      // A character in, `Pci::receive`.  **THE TWO ECHOING MODES ARE NOT
      // BUILT**: auto echo and remote loop back put the character back on the
      // line, and muir does it at the END of the received frame, which is a
      // second instant this seam does not carry --- `Pci::rx_times` gives
      // two, the middle of the stop bit and the frame's end, and only the
      // first reaches the card.  Nothing in System 100 sets either mode, and
      // a card that echoed where no check could look would be a claim nothing
      // exercises.  What IS built and held is `tx_on`'s refusal to run the
      // transmitter in both of them, which is what a driver meets first.
      if (ser_rx_strobe && s_rx_runs) begin
        // "An overrun if the last is still there."
        if (s_rx_ready) s_errors[1] <= 1'b1;
        s_rhr      <= ser_rx_data & s_mask;
        s_rx_ready <= 1'b1;
      end

      // --- the microsecond clock, which no reset moves --------------------
      usec <= usec_next;
      usec_t <= usec_now ? 8'(USEC_PERIOD_T - 1) : usec_t - 8'd1;
      // The half-microsecond clock the serial port's select waits on and
      // `FCLK^` the Chaosnet's receive buffer reads on, both free-running
      // off the same 32 MHz crystal and neither moved by a reset.
      hu_t   <= hu_now   ? 7'(HU_PERIOD_T - 1) : hu_t - 7'd1;
      fclk_t <= fclk_now ? 5'(FCLK_T - 1)      : fclk_t - 5'd1;

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
        ub_ssyn  <= 1'b0;
        busy     <= 1'b0;
        first    <= 1'b0;
        edges    <= 2'd0;
        t_msyn   <= 7'd0;
        t_edge   <= 7'd0;
        hu_edge1 <= 1'b0;
        t_hu     <= 8'd0;
        fc_edge1 <= 1'b0;
        t_fclk   <= 7'd0;
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

        // The half-microsecond clock, STRICTLY after `-UB MSYN` as the
        // microsecond clock is, and `FCLK^` AT OR AFTER `-MSYN` plus 33 ns,
        // which is seven ticks.  Each counts only its first edge: what
        // follows is a delay line and not a second synchroniser.
        if (busy && hu_now && !hu_edge1) begin
          hu_edge1 <= 1'b1;
          t_hu     <= 8'd1;
        end else if (t_hu != 8'd0 && t_hu != 8'd255) begin
          t_hu <= t_hu + 8'd1;
        end
        if (fclk_now && !fc_edge1 && t_msyn >= 7'(RBUF_SETUP_T)) begin
          fc_edge1 <= 1'b1;
          t_fclk   <= 7'd1;
        end else if (t_fclk != 7'd0 && t_fclk != T_MAX) begin
          t_fclk <= t_fclk + 7'd1;
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
        // See the note at `new_now`: the two new groups have reads that move
        // what the next read of the same address gives, and the MD strobe is
        // twenty ticks past `-UB SSYN`.
        if (land && (chgrp || sergrp)) new_held <= new_now;

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
          end else if (clkgrp && wr && which[1:0] == C_CLOCK) begin
            // `-LOAD INTERVAL` loads the four 74LS193s from `UBI0`..`UBI15` and
            // clears the 74LS279's latch.  An interval of zero is over the
            // moment it is loaded.
            interval    <= ub_wdata;
            iv_count    <= ub_wdata;
            iv_t        <= 12'(INTERVAL_T);
            iv_run      <= (ub_wdata != 16'd0);
            clock_ready <= (ub_wdata == 16'd0);
          end else if (chgrp) begin
            // --- the Chaosnet interface --------------------------------
            if (wr) begin
              unique case (which[1:0])
                2'd0: begin
                  // "All read/write bits are initialized to zero on
                  // power-up", and the three write-only commands above them.
                  // Reset is handled at the foot of this block, where
                  // `-UB INIT`'s is: AIM-628 makes them the same thing, and
                  // a Reset subsumes both clears, so the order costs nothing.
                  ch_wbits <= {ub_wdata[5:4], 1'b0, ub_wdata[2:0]};
                  if (ub_wdata[3]) begin   // Clear Receiver
                    ch_rdone <= 1'b0;
                    ch_crc   <= 1'b0;
                    ch_rlen  <= 9'd0;
                    ch_rat   <= 9'd0;
                    ch_left  <= 13'd0;
                    ch_rbits <= 13'd0;
                    ch_fill  <= 9'd0;
                    ch_lost  <= 4'd0;
                  end
                  if (ub_wdata[8]) begin   // Clear Transmitter
                    ch_xn          <= 9'd0;
                    ch_taken       <= 1'b0;
                    ch_sending     <= 1'b0;
                    ch_tdone       <= 1'b1;
                    ch_tabort      <= 1'b0;
                    chaos_tx_clear <= 1'b1;
                  end
                end
                2'd1: begin
                  // "A word into the outgoing packet buffer.  The last word
                  // written is the destination address."  A 257th has
                  // nowhere to go: the 2147 at LMTBUF 0C10 is 4,096 bits.
                  if (ch_wn != 9'd256) begin
                    ch_xmit[ch_wn[7:0]] <= ub_wdata;
                    ch_xn               <= ch_wn + 9'd1;
                  end else begin
                    ch_xn <= ch_wn;
                  end
                  ch_taken  <= 1'b0;
                  ch_tdone  <= 1'b0;
                  ch_tabort <= 1'b0;
                end
                default: ;   // the read buffer and the bit count take none
              endcase
            end else if (which[1:0] == 2'd1 && which[2]) begin
              // START: "initiates transmission of the packet in the outgoing
              // packet buffer", and the buffer goes with it.
              chaos_tx_go  <= 1'b1;
              chaos_tx_len <= ch_xn;
              ch_send      <= ch_xn;
              ch_out       <= 9'd0;
              ch_sending   <= (ch_xn != 9'd0);
              ch_taken     <= 1'b1;
            end else if (ch_rbuf && ch_rat != ch_rlen) begin
              // A word out of the incoming packet buffer, and the bit
              // counter down by what the read took.
              ch_rat  <= ch_rat + 9'd1;
              ch_left <= (ch_left > ch_step) ? (ch_left - ch_step) : 13'd0;
            end
          end else if (sergrp) begin
            // --- the serial port, `serial::Pci`'s own four registers -----
            if (wr) begin
              unique case (which[1:0])
                2'd0: begin
                  s_thr      <= ub_wdata[7:0];
                  s_thr_full <= 1'b1;
                  s_tx_empty <= 1'b0;
                end
                // The SYN1, SYN2 and DLE registers are answered and nothing
                // more; see the header for why they are not built.
                2'd1: ;
                2'd2: begin
                  if (s_second) s_mode2 <= ub_wdata[7:0];
                  else          s_mode1 <= ub_wdata[7:0];
                  s_second <= !s_second;
                end
                default: begin
                  // `RESET ERROR` is a command and not a bit: it clears the
                  // three error flags and is not stored.
                  if (ub_wdata[4]) s_errors <= 3'd0;
                  s_cmd <= ub_wdata[7:0] & 8'hef;
                  // "The receiver will terminate operation immediately",
                  // and `RxRDY` clears "when the receiver is disabled by
                  // CR2".
                  if (!cmd_rx_on) s_rx_ready <= 1'b0;
                  if (!ub_wdata[0]) s_tx_empty <= 1'b0;
                end
              endcase
            end else begin
              unique case (which[1:0])
                2'd0: s_rx_ready <= 1'b0;
                2'd1: s_dschg    <= 1'b0;
                2'd2: s_second   <= !s_second;
                // "The pointers are reset ... by performing a `Read Command
                // Register` operation."
                default: s_second <= 1'b0;
              endcase
            end
          end
        end
      end

      // --- `-UB INIT`, last, because a clear is a pin and not a clock -------
      if (ub_init) begin
        en175  <= 4'd0;
        ser_en <= 1'b0;
        // `-INIT*` into the 8837 at IOBXCV 0F06 IS the 2651's `RESET` pin.
        // `Pci::reset` takes the modem lines as they stand, so the reset is
        // not itself a data-set change --- and the lines it takes are the
        // ones the CLEARED command register makes, which is the cable's.
        s_mode1     <= 8'd0;
        s_mode2     <= 8'd0;
        s_cmd       <= 8'd0;
        s_second    <= 1'b0;
        s_rhr       <= 8'd0;
        s_thr       <= 8'd0;
        s_shift     <= 8'd0;
        s_rx_ready  <= 1'b0;
        s_thr_full  <= 1'b0;
        s_shifting  <= 1'b0;
        s_tx_empty  <= 1'b0;
        s_dschg     <= 1'b0;
        s_errors    <= 3'd0;
        s_dsr_was   <= ser_plugged;
        s_dcd_was   <= ser_plugged;
      end

      // Reset, which AIM-628 makes the same thing for the Chaosnet
      // interface: the write-only bit 13 of the CSR, and `-UB INIT`.
      if (ch_reset_now) begin
        ch_wbits    <= 6'd0;
        ch_tdone    <= 1'b1;
        ch_tabort   <= 1'b0;
        ch_rdone    <= 1'b0;
        ch_crc      <= 1'b0;
        ch_lost     <= 4'd0;
        ch_xn       <= 9'd0;
        ch_taken    <= 1'b0;
        ch_fill     <= 9'd0;
        ch_rlen     <= 9'd0;
        ch_rat      <= 9'd0;
        ch_rbits    <= 13'd0;
        ch_left     <= 13'd0;
        ch_sending  <= 1'b0;
        chaos_reset <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
