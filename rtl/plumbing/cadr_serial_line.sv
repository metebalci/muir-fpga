// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The serial port's LINE: the far end of the 2651 on the I/O board, as eight
// registers Linux reaches over `M_AXI_GP0`.
//
// **WHAT THE SEAM IS, AND WHICH HALF OWNS WHAT.**  The chip is
// `rtl/machine/cadr_io_board.sv`'s --- its four registers, its two pointers,
// its status byte and its holding registers --- and that module deliberately
// leaves out the baud-rate generator at IOBSER 0A15, because the 5.0688 MHz
// can divides to instants that are not multiples of five and the drawings'
// grid cannot carry them.  What it has instead is a seam: `ser_tx_take` is
// the character leaving the holding register at the first 16X clock and
// `ser_tx_done` is its frame ending, and something outside the card has to
// produce both.  `cadr-serial`'s own header says the other half of it ---
// "the chip is the fabric's and its timing stays there ... this program does
// not model a baud rate, and must not, because two models of one chip is the
// failure this project keeps meeting".
//
// **SO THE GENERATOR IS HERE.**  It is the one thing on this seam that has
// nowhere else to live: the card refuses it because of the grid, the program
// refuses it because it would be a second model of the chip, and without it
// the machine's transmitter never empties --- `ser_tx_take` is the ONLY thing
// that clears the holding register, so a line side that never pulsed it
// would stop the CADR's serial output at the first character, for ever.
// Built as a rational-rate divider rather than a division: 5,068,800 crystal
// periods in every 100,000,000 fabric ticks, by adding the first and
// subtracting the second, which is exact on the average and needs no real
// arithmetic in a parameter.  A 16X clock is `DIVISORS[MR2 bits 3:0]`
// crystal periods and a character's frame is `half_bits * 8` of those 16X
// clocks, which is `muir::serial::Framing::frame_ns` with the nanoseconds
// cancelled out.
//
// **THE DERIVATIONS ARE TRANSCRIBED FROM THE CARD, AND THAT IS THE DESIGN
// AND NOT A DUPLICATION.**  The card brings out `ser_mode1`, `ser_mode2`,
// `ser_cmd` and `ser_status` and nothing else; there is no "the holding
// register is full" output and no "the receiver has room" output.
// `docs/io-board.md` states the contract in those words --- the line side
// "reads the frame out of `ser_mode1` and the rate out of `ser_mode2`, takes
// a character on `ser_tx_strobe`, and paces `ser_tx_take` and `ser_tx_done`
// at the rate those registers name" --- so recomputing `tx_on`, `rx_on`,
// `cts` and `dcd` from the registers is what the seam asks for.  The nine
// lines below are `cadr_io_board.sv:521-534` verbatim, and
// `serial-line-forgets-local-loop-back` is the record that holds them.
// **The consequence worth knowing: a change to those nine lines on the card
// has to be made here too, and nothing but that record would say so.**
//
// **THE ORDER OF THE TWO EDGES, WHICH IS `muir::serial::Pci::transmit`.**
// A character the software writes sits in the holding register with TxRDY
// down.  `ser_tx_take` goes out on the first 16X clock at or after that ---
// muir's `thr_start` --- and TxRDY comes back up, so the software may load
// the next.  One frame later `ser_tx_done` goes out, and **on the tick after
// it** the card raises `ser_tx_strobe` with the character that was on the
// wire, masked to the frame's data length.  If the holding register has
// filled again by then, the take goes out on the SAME tick as the done,
// which is the back-to-back case muir resolves the same way and which the
// card's own `always_ff` is written to take (`cadr_io_board.sv:988`, the
// later non-blocking assignment standing).
//
// **AND THE TAKE IS GATED ON `-CTS`, WHICH IS WHY A CABLE THAT IS NOT
// PLUGGED IN STOPS THE TRANSMITTER AND NOT THIS MODULE.**  The card's take
// needs `s_thr_full && s_tx_on && s_cts`; with `CTL` zero --- which is what
// this comes up with, so a board before Linux starts is a board with the
// cable out, exactly as the tie-off it replaces was --- nothing is taken and
// a written character stands.  Local loop back is the exception the card
// makes and this makes too: there `-CTS` is the command register's own RTS,
// so the port runs with no cable at all.
//
// **A CHARACTER INTO THE MACHINE TAKES ITS FRAME TIME.**  `WDATA` is
// accepted only while `TX_ROOM` is up --- the card's receiver running and its
// holding register empty, and no character already on its way --- and
// `ser_rx_strobe` goes out one frame later.  That is what makes
// `serial_face.h`'s claim true, that "a burst read off the socket in one
// turn is still received one frame at a time by the machine": the rate
// limiting is here and not in the program, and a program that offered a
// thousand characters in one turn would have 999 of them refused rather than
// dropped.  Where this is coarser than muir: muir hands the character over
// at the middle of the stop bit (`Pci::rx_times`' first instant) and this
// waits the whole frame, which is under one bit time later and which nothing
// on either side of the seam can observe.
//
// ## The registers
//
// Eight words at the base `cadr_gp0_split.sv` gives this page, and
// `serial_face.h` is the other half of this table:
//
//    0  IDENT    reads `IDENT`, "SERI", so that the first read can tell the
//                face from a bus that answers zeros or from the default
//                slave's "NONE"
//    1  STAT     bit 0 a character the machine transmitted is waiting
//                bit 1 the machine's receiver can take one now
//                bit 2 the machine has its transmitter enabled
//                bit 3 ...and its receiver
//    2  RDATA    bits 7:0 the character, bit 8 that there was one.  **THE
//                READ CONSUMES IT**, once a beat, so a burst of reads takes
//                a burst of characters
//    3  WDATA    written: bits 7:0 a character into the machine's receiver.
//                Dropped unless `STAT`'s bit 1 is up.  Reads back the
//                character on its way and bit 8 while one is
//    4  CTL       the three modem lines this end asserts: bit 0 DSR, bit 1
//                DCD, bit 2 CTS.  The card has ONE wire for the three ---
//                they come off one MC1489 at IOBSER 0B16 and one connector
//                --- so the cable is in when all three are up, which is the
//                only thing `SER_CTL_PLUGGED` ever writes.  Read back
//    5  MODE     read only: `{ser_status, ser_cmd, ser_mode2, ser_mode1}`,
//                so `(MODE >> 8) & 0xF` is the rate the software chose,
//                which is what `serial_face_rate` reads.  **The chip's own
//                status byte is in bits 31:24, where `serial_face.h` says
//                nothing** --- the program masks it off and never sees it.
//                It is there because the card brings `ser_status` out and
//                this face reads two of its eight bits: the other six ---
//                DSR, DCD and the overrun in particular --- would otherwise
//                have to be folded away unread, and a diagnostic word with
//                eight spare bits is the right place for them
//    6  DROPPED  read only, saturating: characters the machine transmitted
//                that nobody took, because `RDATA` still held the last one
//    7  IRQ      bit 0 a character is waiting, bit 1 the machine's receiver
//                has room.  A 1 written clears the bit; `IRQ_F2P` is the OR
//
// Every other word in the page reads zero and ignores writes, and every
// address in it is answered: see `cadr_gp_regs.sv`, which is the AXI3 face
// and is where the protocol lives.
//
// NO muir REFERENCE EXISTS FOR THE REGISTER FACE --- nothing in MIT's
// drawings is an AXI slave --- but the CHIP's far end has one, and this is
// held to it: `muir::serial::Pci::transmit` for the two edges,
// `Framing::half_bits` and `DIVISORS` for the frame's length, `Pci::reset`
// for what a reset keeps, and `serial::Cable` for the shape of the far end
// (one character each way and one plugged flag).
// `tb/cadr_gp0_split_tb.cpp` drives the card through the Unibus on one side
// and this face through the splitter on the other, and requires the
// character the machine transmitted to come out of `RDATA` and the character
// written to `WDATA` to come back out of the card --- read-back across the
// whole seam, which no check in the tree had before.

`default_nettype none

module cadr_serial_line #(
    // "SERI", so that a read of word 0 can be told from a bus of zeros.
    parameter logic [31:0] IDENT = 32'h5345_5249,
    // The fabric's clock, for the crystal's rational divider.  10 ns a tick.
    parameter int unsigned CLK_HZ = 100_000_000
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- the face: one 4 KB page of `M_AXI_GP0`, the offset only ---------
    input  var logic [11:0] s_awaddr,
    input  var logic [3:0]  s_awlen,
    input  var logic [11:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [11:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [11:0] s_araddr,
    input  var logic [3:0]  s_arlen,
    input  var logic [11:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [11:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- the card's line seam, as `cadr_io_board.sv` presents it ---------
    input  var logic        ser_reset,     // `-INIT*`, the chip's RESET pin
    input  var logic [7:0]  ser_mode1,
    input  var logic [7:0]  ser_mode2,
    input  var logic [7:0]  ser_cmd,
    input  var logic [7:0]  ser_status,
    input  var logic        ser_tx_strobe, // one tick: a character reached the cable
    input  var logic [7:0]  ser_tx_data,
    output var logic        ser_tx_take,   // one tick: the shift register takes the holding register
    output var logic        ser_tx_done,   // one tick: its frame ends
    output var logic        ser_rx_strobe, // one tick: a character reaches the receive path
    output var logic [7:0]  ser_rx_data,
    // **THE SAME TICK, ON THIS SIDE OF THE SEAM.**  The card wants two
    // instants of the receiver's, because `muir::serial::Pci::rx_times`
    // gives two --- the middle of the stop bit, where the character is in
    // the holding register, and the end of the frame, where the echoing
    // modes put the echoed character on the cable.  This module already
    // waits the WHOLE frame before `ser_rx_strobe`, which its header calls
    // out as coarser than muir by under one bit time, so the two instants
    // coincide here and this is that one tick again.  A line that placed
    // the strobe at the stop bit's middle would delay this by the rest of
    // the frame and nothing else would change.
    output var logic        ser_rx_end,
    // `SR3` and `SR5`: a parity bit that did not agree and a stop bit that
    // was low.  **HELD LOW, AND THE REASON IS THE FACE AND NOT THIS
    // MODULE.**  Both are properties of the frame's BITS, and what is on
    // the other end of this seam is a TCP socket carrying bytes: neither
    // this module nor `cadr-serial` has a bit to look at, so neither has
    // anything to report.  The card has the flags all the same, because the
    // 2651 has them.  What would make them live is one bit pair in the
    // character-in word of `serial_face.h` --- there is room in it --- and
    // passing them through here; nothing else on either side changes.
    output var logic        ser_rx_parity,
    output var logic        ser_rx_framing,
    output var logic        ser_plugged,   // `-DSR`, `-DCD` and `-CTS` together

    // --- to the processing system's `IRQ_F2P` -----------------------------
    output var logic        irq
);

  // The two error flags, held low: the note at the port says why, and it is
  // about what is on the far end of the socket and not about this module.
  assign ser_rx_parity  = 1'b0;
  assign ser_rx_framing = 1'b0;

  // ------------------------------------------------------------------------
  // The crystal at IOBSER 0A15, `muir::serial::BRCLK_HZ`, and Table 1's
  // sixteen divisors to the 16X clock --- 50 baud to 19,200.
  // ------------------------------------------------------------------------
  localparam int unsigned BRCLK_HZ = 5_068_800;

  function automatic logic [12:0] divisor(input logic [3:0] rate);
    unique case (rate)
      4'd0:  return 13'd6336;
      4'd1:  return 13'd4224;
      4'd2:  return 13'd2880;
      4'd3:  return 13'd2355;
      4'd4:  return 13'd2112;
      4'd5:  return 13'd1056;
      4'd6:  return 13'd528;
      4'd7:  return 13'd264;
      4'd8:  return 13'd176;
      4'd9:  return 13'd158;
      4'd10: return 13'd132;
      4'd11: return 13'd88;
      4'd12: return 13'd66;
      4'd13: return 13'd44;
      4'd14: return 13'd33;
      default: return 13'd16;
    endcase
  endfunction

  // ------------------------------------------------------------------------
  // `cadr_io_board.sv:521-534`, verbatim: what the card makes of its own
  // registers.  See the header for why this is transcribed rather than
  // brought out as ports.
  // ------------------------------------------------------------------------
  logic [1:0] s_mode;
  logic       s_local, s_dcd, s_cts, s_txclk, s_rxclk;
  logic       s_tx_on, s_rx_on, s_rx_runs;
  assign s_mode   = ser_cmd[7:6];
  assign s_local  = (s_mode == 2'd2);
  assign s_dcd    = s_local ? ser_cmd[1] : ser_plugged;
  assign s_cts    = s_local ? ser_cmd[5] : ser_plugged;
  assign s_txclk  = (ser_mode1[1:0] != 2'd0) && ser_mode2[5];
  assign s_rxclk  = (ser_mode1[1:0] != 2'd0) && ser_mode2[4];
  assign s_tx_on  = ser_cmd[0] && s_txclk && (s_mode == 2'd0 || s_mode == 2'd2);
  assign s_rx_on  = (ser_cmd[2] || s_local) && s_rxclk;
  assign s_rx_runs = s_rx_on && s_dcd;

  // The card has no "the holding register is full" output, and does not need
  // one: `SR0` is `s_tx_on && !s_thr_full`, so with the transmitter on, a
  // `SR0` that is down IS a full holding register.  With it off nothing may
  // be taken anyway.
  logic thr_full;
  assign thr_full = s_tx_on && !ser_status[0];
  // Nor a "the receiver has room" output: `SR1` is its holding register, and
  // a strobe is discarded unless the receiver runs.
  logic card_room;
  assign card_room = s_rx_runs && !ser_status[1];

  // ------------------------------------------------------------------------
  // The frame, `Framing::half_bits`: a start bit, five to eight data bits,
  // a parity bit if enabled, and one, one and a half or two stop bits, all
  // counted in halves.  Eight 16X clocks a half bit.
  // ------------------------------------------------------------------------
  logic [3:0] data_bits;
  logic [2:0] stop_halves;
  logic [5:0] half_bits;
  logic [8:0] frame_x16;
  assign data_bits = 4'd5 + {2'b0, ser_mode1[3:2]};
  always_comb begin
    unique case (ser_mode1[7:6])
      2'd2:    stop_halves = 3'd3;
      2'd3:    stop_halves = 3'd4;
      // `01`, and `00`, which the sheet calls invalid and which is what the
      // register holds from reset.
      default: stop_halves = 3'd2;
    endcase
  end
  assign half_bits = 6'd2 + {1'b0, data_bits, 1'b0} +
                     (ser_mode1[4] ? 6'd2 : 6'd0) + {3'b0, stop_halves};
  assign frame_x16 = {half_bits, 3'b000};

  // ------------------------------------------------------------------------
  // The baud-rate generator.  The crystal is a rational divider so that no
  // real arithmetic appears in a parameter: add `BRCLK_HZ` a tick, and a
  // crystal period has passed each time the sum reaches `CLK_HZ`.
  //
  // It runs while either half of the chip is on --- `muir::serial::Pci`'s own
  // `note_enables`, which is what makes `thr_start`'s phase reproducible ---
  // **and while a frame is in flight whatever the software has since done**,
  // because muir works a frame's end out at the take and a software that
  // disabled the transmitter mid-character does not stop the character.
  // ------------------------------------------------------------------------
  // Thirty-two bits and plain thirty-two-bit arithmetic, rather than the
  // four fewer `$clog2` would buy: the sum is nowhere near the top and a
  // width nobody has to check is worth four flip-flops.
  localparam logic [31:0] XTAL_ADD = BRCLK_HZ;
  localparam logic [31:0] XTAL_WRAP = CLK_HZ;
  logic [31:0] acc;
  logic        xtal;                 // a crystal period has passed
  logic [12:0] div_cnt;
  logic        x16;                  // a 16X clock
  logic        tx_busy, in_busy;
  logic        gen_on;
  assign gen_on = s_tx_on || s_rx_on || tx_busy || in_busy;
  assign xtal = gen_on && ((acc + XTAL_ADD) >= XTAL_WRAP);
  assign x16  = xtal && (({1'b0, div_cnt} + 14'd1) >= {1'b0, divisor(ser_mode2[3:0])});

  // ------------------------------------------------------------------------
  // The registers this face keeps
  // ------------------------------------------------------------------------
  logic [2:0]  r_ctl;                // DSR, DCD, CTS
  logic [7:0]  rx_char;              // what the machine transmitted
  logic        rx_valid;
  logic [31:0] dropped;
  logic [1:0]  irq_q;
  logic [31:0] rdata_hold;           // `RDATA`, registered at the read
  logic [7:0]  in_char;              // on its way into the machine
  logic [8:0]  tx_left, in_left;     // 16X clocks still owed on a frame
  logic        room_was;             // `TX_ROOM` a tick ago, for the event

  assign ser_plugged = r_ctl[0] && r_ctl[1] && r_ctl[2];
  assign ser_rx_data = in_char;
  assign irq = |irq_q;

  // A character may be offered when the card can take one and none is on its
  // way already.
  logic tx_room;
  assign tx_room = card_room && !in_busy;

  // The two events, and what a write clears.  `IRQ` bit 0 is a character
  // waiting and bit 1 the machine's receiver coming free.
  logic [1:0] irq_set, irq_clr;
  assign irq_set = {tx_room && !room_was,
                    ser_tx_strobe && !rx_valid};
  assign irq_clr = (wr && w_word == 10'd7) ? (wr_data[1:0] & wr_mask[1:0]) : 2'd0;

  // ------------------------------------------------------------------------
  // The AXI3 face
  // ------------------------------------------------------------------------
  logic [9:0]  w_word, r_word;
  logic        wr, rd;
  logic [31:0] wr_data, wr_mask, rd_data;

  cadr_gp_regs u_regs (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awid(s_awid),
      .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bresp(s_bresp), .s_bid(s_bid), .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arid(s_arid),
      .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rid(s_rid),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .w_word(w_word), .wr(wr), .wr_data(wr_data), .wr_mask(wr_mask),
      .r_word(r_word), .rd(rd), .rd_data(rd_data)
  );

  // The word a read gives.  `RDATA` is the registered one, because reading it
  // consumes the character and the answer has to outlive the consuming ---
  // which is the second of `cadr_gp_regs`'s two prep ticks.
  logic [31:0] stat_word;
  assign stat_word = {28'd0, s_rx_on, s_tx_on, tx_room, rx_valid};
  always_comb begin
    unique case (r_word)
      10'd0:   rd_data = IDENT;
      10'd1:   rd_data = stat_word;
      10'd2:   rd_data = rdata_hold;
      10'd3:   rd_data = {23'd0, in_busy, in_char};
      10'd4:   rd_data = {29'd0, r_ctl};
      10'd5:   rd_data = {ser_status, ser_cmd, ser_mode2, ser_mode1};
      10'd6:   rd_data = dropped;
      10'd7:   rd_data = {30'd0, irq_q};
      default: rd_data = 32'd0;
    endcase
  end

  // ------------------------------------------------------------------------
  // The line
  // ------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      acc        <= 32'd0;
      div_cnt    <= 13'd0;
      r_ctl      <= 3'd0;
      rx_char    <= 8'd0;
      rx_valid   <= 1'b0;
      dropped    <= 32'd0;
      irq_q      <= 2'd0;
      rdata_hold <= 32'd0;
      in_char    <= 8'd0;
      tx_left    <= 9'd0;
      in_left    <= 9'd0;
      tx_busy    <= 1'b0;
      in_busy    <= 1'b0;
      room_was   <= 1'b0;
      ser_tx_take   <= 1'b0;
      ser_tx_done   <= 1'b0;
      ser_rx_strobe <= 1'b0;
      ser_rx_end    <= 1'b0;
    end else begin
      // Every edge on the seam is one tick: the card samples each of them
      // level-high every tick with no gate of its own, so a level held two
      // ticks is two events --- a `ser_tx_done` held high while a take had
      // reloaded the shift register would strobe a character that was never
      // shifted.
      ser_tx_take   <= 1'b0;
      ser_tx_done   <= 1'b0;
      ser_rx_strobe <= 1'b0;
      ser_rx_end    <= 1'b0;

      // --- the crystal and the 16X clock
      if (!gen_on) begin
        acc     <= '0;
        div_cnt <= 13'd0;
      end else if (xtal) begin
        acc <= acc + XTAL_ADD - XTAL_WRAP;
        if (x16) div_cnt <= 13'd0;
        else div_cnt <= div_cnt + 13'd1;
      end else begin
        acc <= acc + XTAL_ADD;
      end

      // --- the character the machine transmitted, off the card
      if (ser_tx_strobe) begin
        if (!rx_valid) begin
          rx_char  <= ser_tx_data;
          rx_valid <= 1'b1;
        end else if (dropped != 32'hFFFF_FFFF) begin
          dropped <= dropped + 32'd1;
        end
      end

      // --- the transmitter's two edges
      if (tx_busy) begin
        if (x16) begin
          if (tx_left == 9'd1) begin
            ser_tx_done <= 1'b1;
            // Back to back if the software has already loaded the next
            // character: muir hands the shift register over at the same
            // instant, and so does the card.
            if (thr_full && s_cts) begin
              ser_tx_take <= 1'b1;
              tx_left     <= frame_x16;
            end else begin
              tx_busy <= 1'b0;
            end
          end else begin
            tx_left <= tx_left - 9'd1;
          end
        end
      end else if (thr_full && s_cts && x16) begin
        // `thr_start`: the first 16X clock at or after the load, with the
        // transmitter able to take it.
        ser_tx_take <= 1'b1;
        tx_left     <= frame_x16;
        tx_busy     <= 1'b1;
      end

      // --- a character into the machine, one frame long
      if (in_busy) begin
        if (!s_rx_runs) begin
          // The software stopped the receiver mid-character, and a line
          // loses what was arriving.  Not counted in `DROPPED`, which is
          // the other direction's.
          in_busy <= 1'b0;
        end else if (x16) begin
          if (in_left == 9'd1) begin
            ser_rx_strobe <= 1'b1;
            ser_rx_end    <= 1'b1;
            in_busy       <= 1'b0;
          end else begin
            in_left <= in_left - 9'd1;
          end
        end
      end

      // --- what Linux writes
      if (wr) begin
        unique case (w_word)
          10'd3: if (tx_room) begin
            in_char <= (in_char & ~wr_mask[7:0]) | (wr_data[7:0] & wr_mask[7:0]);
            in_left <= frame_x16;
            in_busy <= 1'b1;
          end
          10'd4: r_ctl <= (r_ctl & ~wr_mask[2:0]) | (wr_data[2:0] & wr_mask[2:0]);
          // `IRQ`'s clear is `irq_clr` above, resolved with the two
          // events in one assignment: a 1 clears and a 0 leaves, so a
          // program that read the word and wrote it back clears exactly
          // what it saw and nothing that happened since.
          default: ;
        endcase
      end

      // --- a read of `RDATA` takes the character
      if (rd && r_word == 10'd2) begin
        rdata_hold <= {23'd0, rx_valid, rx_char};
        rx_valid   <= 1'b0;
      end

      // --- the two interrupt events, and the clear, resolved in ONE
      // assignment with the SET winning.  Written as two statements, a
      // clear landing on the tick an event happened would swallow the
      // event: Linux reads the word, writes it back, and an event in
      // between would be lost with nothing to say so.
      room_was <= tx_room;
      irq_q <= (irq_q & ~irq_clr) | irq_set;

      // --- `-UB INIT` reached the chip: it abandons whatever was in flight
      // and keeps the cable, as `Pci::reset` keeps it.
      if (ser_reset) begin
        tx_busy <= 1'b0;
        in_busy <= 1'b0;
        tx_left <= 9'd0;
        in_left <= 9'd0;
      end
    end
  end

  // The upper three bytes of a write beat reach no register here: the
  // widest word this face takes is a character.  Read so that lint's bit
  // granularity has nothing to say --- and lint's bit granularity is what
  // catches a mutation that drops a bit, so it is worth keeping sharp.
  logic unused_s;
  assign unused_s = ^{wr_data[31:8], wr_mask[31:8]};

endmodule

`default_nettype wire
