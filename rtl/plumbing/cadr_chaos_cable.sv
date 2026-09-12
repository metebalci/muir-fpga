// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet interface's CABLE: the far end of the card's two packet
// buffers, as a mailbox for whole frames that Linux reaches over
// `M_AXI_GP0`.
//
// **WHICH HALF OWNS WHAT.**  AIM-628 section 7's five registers, the 2147s
// at LMTBUF 0C10 and LMRBUF 0C04, the bit counter, the lost count and the
// priority chain are `rtl/machine/cadr_io_board.sv`'s and are held to
// `muir::chaos::interface`.  The turn timer at LMTURN, the transceiver and
// the ether are `cadr-chaosnet`'s.  What is between them is this: the card
// bursts a frame out on `chaos_tx_*` when the machine reads START and takes
// one in on `chaos_rx_*`, and neither of those is anything a program can be
// handed directly --- the burst is 256 words at one word a tick with no
// backpressure at all.  So this holds one frame each way and presents them
// as two windows.
//
// **THE FRAME ON THIS SEAM CARRIES THE HARDWARE TRAILER, AND THAT IS THE
// DECISION `chaos_face.h` ASKED FOR.**  It assumed "that the fabric appends
// the source address and the check word on transmit, as the board's
// Fairchild 9401 at LMTBUF C09 does, and takes them as given on receive",
// and said the alternative was a three-line change on its side.  Measured,
// the card does NOT append them: `chaos_tx_*` is the buffer the software
// wrote and nothing else, while `chaos_rx_*` must be given the buffer AND
// the source AND the check word, because that is what the machine reads back
// (AIM-628: "the last three words read are the destination address, the
// source address, and the checksum").  **The receive direction therefore
// settles it**: the trailer has to be on the seam there, because the source
// of an arriving frame is the PEER's address and the fabric cannot know it.
// A seam that carried the trailer one way and not the other would be a seam
// with two frame formats, so this appends the two words on transmit and the
// assumption stands with nothing in the program changing.
//
// So the check word is computed here, which is what the 9401 is:
// `muir::chaos::packet::check_word`, CRC-16 `x^16 + x^15 + x^2 + 1` from a
// cleared register over the buffer's words and then the source, each word
// most significant bit first --- "not read off a document; it is the one
// arrangement that reproduces the word the netlist board itself produced".
// One word a tick, a sixteen-step linear function in `crc_word` below, which
// is what the burst's rate demands: there is nowhere to put back-pressure.
//
// **A FRAME TOO LONG FOR THE WINDOW IS OFFERED AND REFUSED, NOT
// TRUNCATED.**  The card's buffer holds 256 words, so `TXLEN` can read 258
// with the trailer while the window is 256 and `CHAOS_MAX_WORDS` is 255.
// `chaos_face_take` already answers that case --- it drops such a frame, says
// which half is at fault and lets the machine's transmitter go --- so
// `TXLEN` reports the true length and the words past 255 are simply not
// readable.  Reporting a length that fits would be the worse failure: a
// frame silently missing its check word.
//
// **A COMMIT IS REFUSED BY LOOKING AT THE CARD'S OWN Receive Done, AND THE
// REFUSAL IS COUNTED IN `LOST`.**  `chaos_face_give` tells a stored frame
// from a refused one by `LOST` moving and by nothing else, because `RX_BUSY`
// is up either way; so `LOST` is this module's own count, it saturates
// rather than wraps, and **it survives a reset** --- a counter that went
// backwards would make the program read a store as a refusal.
//
// **AND A REFUSED COMMIT DOES NOT TOUCH THE SEAM, WHICH COSTS THE MACHINE
// ITS OWN LOST COUNT.**  The card counts a lost frame when `chaos_rx_done`
// arrives with Receive Done already up, so the faithful thing would be to
// pulse it and let the card count.  Measured against the card's own source,
// that is a race this module cannot win: Receive Done is sampled a tick
// before the pulse could go out, and the machine may read the buffer out in
// between --- and then a `chaos_rx_done` with no words behind it commits a
// packet of ZERO words, whose bit counter underflows (`ch_top` is
// `ch_rbits - {(ch_rlen - 1), 4'd0}`).  A garbage bit counter in front of
// the machine is worse than a diagnostic the machine cannot see, so a
// refusal is counted here and the card's four-bit Lost Count stays at zero
// on this board.  **Bringing Clear Receiver out as a seam pulse would close
// this properly**, and that is a one-line change on the card rather than
// anything here.
//
// **`-CBLBSY` IS HELD LOW, DELIBERATELY.**  The card ORs it with the CRC
// error into CSR bit 14, and nothing in the card is gated on it.  On the real
// board it is up while a frame is on the wire --- microseconds --- and the
// tempting thing is to raise it while a frame waits for Linux.  That wait is
// however long Linux takes to poll, which is not a cable time, and bit 14
// would read as a CRC error in front of the machine for milliseconds at a
// stretch.  AIM-628 says the CRC error is only valid at two instants and
// both of them can fall inside such a wait.  So the cable here is never
// busy, which is what a cable with no other station on it looks like, and
// bit 14 then reads the CRC error alone --- more informative than the board,
// not less.
//
// **AND `chaos_rx_crc` IS HELD LOW FOR WANT OF A BIT TO CARRY IT.**  A frame
// whose check word failed is Linux's to verify --- the trailer is on the seam
// precisely so that it can be --- and `chaos_ctl` has no bit that says
// "commit this one with the check word marked bad".  So a committed frame is
// a good frame, and a bad one is dropped by the program rather than shown to
// the machine.  One more `CTL` bit would carry it if that is wanted; it is
// named in the report rather than invented here.
//
// **`chaos_tx_abort` IS HELD LOW BECAUSE THERE IS NO COLLISION DOMAIN.**
// Abort is "a collision, or the receiver was busy" on a shared ether; this
// cable is one program and a socket.  The card samples it only on the tick
// `chaos_tx_done` is high, so it is a qualifier of the done and not an event
// of its own.
//
// ## The registers
//
// Sixteen words and two windows in the 4 KB page `cadr_gp0_split.sv` gives
// this, and `chaos_face.h` is the other half of the table:
//
//    0  IDENT   reads `IDENT`, "CHAO"
//    1  STAT    bit 0 a frame the machine transmitted is waiting
//                bit 1 the incoming buffer still holds a packet the machine
//                      has not read out: a frame given now is refused
//                bit 2 the receiver will take a frame now
//                bit 3 the interface is in Loop Back
//               **and the card's own CSR in bits 31:16**, where
//               `chaos_face.h` says nothing --- the program masks it off.
//               The card brings `chaos_csr` out and this face reads two of
//               its sixteen bits; the other fourteen (the lost count, Spy,
//               the two interrupt enables, Transmit Done) would otherwise
//               be folded away unread, and a status word with sixteen spare
//               bits is the right place for them
//    2  MYADDR  the sixteen address switches at LMMYNM D10 and D12: what
//               the machine reads at `MY_ADDRESS` and the source word this
//               module inserts.  Written by Linux, there being no switch
//    3  TXLEN   read only: words in the waiting frame, the trailer counted,
//               or 0 when none waits
//    4  RXLEN   how many words the frame about to be committed has.  Read
//               back so a driver can check it
//    5  CTL     written: bit 0 the frame `TXLEN` counted has been taken ---
//                        drop it and let Transmit Done come up
//                        bit 1 the `RXLEN` words in the RX window are a
//                        whole frame: store it and raise Receive Done, or
//                        refuse it and count it in `LOST`
//                        bit 2 throw away what is in the RX window
//               read:    the number of times the machine has Reset its
//               interface, in bits 31:8.  The three command bits read zero,
//               being commands and not state --- the card's own CSR reads
//               its three write-only bits the same way --- so a write of 0
//               is a harmless probe
//    6  LOST    read only, saturating: frames refused because the machine
//               had not emptied the incoming buffer
//    7  IRQ     bit 0 a frame is waiting to be taken, bit 1 the machine
//               emptied the incoming buffer.  A 1 written clears the bit
//    8  IRQEN   the mask over IRQ; `IRQ_F2P` is the OR under it
//  +0x400      TX window, 256 words: word k of the waiting frame at +4k,
//              read only, bits 15:0.  Word `TXLEN-2` is the source this
//              module inserted and `TXLEN-1` the check word it computed
//  +0x800      RX window, 256 words: word k of the frame being built,
//              written, bits 15:0.  Readable too, except while a commit is
//              streaming, when the word a read gives is whichever the
//              stream has reached --- one read port serves both and the
//              stream has it
//
// **THE TWO WINDOWS TAKE WHOLE WORDS.**  The byte strobes are honoured on
// the registers and not inside the buffers: a read-modify-write in a RAM's
// own process is not a template Vivado infers --- `Synth 8-2914 Unsupported
// RAM template`, which this project has already met once and which Verilator
// lints and simulates happily --- and no program writes half a Chaosnet
// word.
//
// Every other word in the page reads zero and ignores writes, and every
// address in it is answered: `cadr_gp_regs.sv` is the AXI3 face and is where
// the protocol lives.
//
// **WHAT `RX_ARMED` MEANS HERE, WHICH IS A CORRECTION TO `chaos_face.h`'S
// COMMENT AND TO NOTHING ELSE.**  That file reads the bit as "Clear Receiver
// has been written since the last packet"; the card does not bring Clear
// Receiver out, so the fabric cannot see it.  What it can see is Receive
// Done, and "the receiver will take a frame now" is `!Receive Done`.  The
// bit therefore reads as the complement of `RX_BUSY`, which is what the one
// caller wants --- `chaos_face.c` says a give "does not gate on it and lets
// the fabric refuse and count".
//
// NO muir REFERENCE EXISTS FOR THE REGISTER FACE, as none exists for
// `cadr_axi_master.sv`: nothing in MIT's drawings is an AXI slave.  The
// CABLE has one and this is held to it: `packet::check_word` for the check
// word, `packet::frame`'s `buffer ++ [source] ++ [check]` for the frame's
// word order, and `board::Interface::arrive` for a frame refused on a full
// buffer.  `tb/cadr_gp0_split_tb.cpp` drives the card through the Unibus on
// one side and this face through the splitter on the other: the frame the
// machine transmitted must come out of the TX window with the source and
// check word muir computes, and the frame written into the RX window must
// come back out of the card word for word with the bit counter AIM-628
// names.  That is read-back across the whole seam, which no check in the
// tree had before.

`default_nettype none

module cadr_chaos_cable #(
    // "CHAO", so that a read of word 0 can be told from a bus of zeros.
    parameter logic [31:0] IDENT = 32'h4348_414F
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

    // --- the card's cable seam, as `cadr_io_board.sv` presents it --------
    output var logic [15:0] chaos_address,  // the switches at LMMYNM
    input  var logic        chaos_tx_go,    // one tick: START was read
    input  var logic [8:0]  chaos_tx_len,   // words of it, 0 to 256
    input  var logic        chaos_tx_valid, // one word a tick, from the tick after
    input  var logic [15:0] chaos_tx_word,
    input  var logic        chaos_tx_clear, // Clear Transmitter
    input  var logic        chaos_reset,    // Reset, or `-UB INIT`
    input  var logic [15:0] chaos_csr,
    output var logic        chaos_rx_valid, // one word into the receive buffer
    output var logic [15:0] chaos_rx_word,
    output var logic        chaos_rx_done,  // one tick, AFTER the last word
    output var logic [12:0] chaos_rx_bits,  // the bit count the counter loads
    output var logic        chaos_rx_crc,
    output var logic        chaos_tx_done,  // one tick: the frame is away
    output var logic        chaos_tx_abort,
    output var logic        chaos_cbl_busy,

    // --- to the processing system's `IRQ_F2P` -----------------------------
    output var logic        irq
);

  // ------------------------------------------------------------------------
  // The check word: `muir::chaos::packet::check_word`, a word at a time.
  // Stage k of the 9401's register in bit k, the word shifted in most
  // significant bit first, the taps at 0, 2 and 15.  Sixteen steps of a
  // linear function, so every output bit is an exclusive-or of at most
  // thirty-two inputs --- two levels of LUT6 --- and the burst can be
  // absorbed at its own rate of one word a tick.
  // ------------------------------------------------------------------------
  localparam logic [15:0] CRC_TAPS = 16'h8005;   // 1 | 1<<2 | 1<<15

  function automatic logic [15:0] crc_word(input logic [15:0] r0,
                                           input logic [15:0] w);
    logic [15:0] r;
    logic        fb;
    r = r0;
    for (int k = 15; k >= 0; k--) begin
      fb = w[k] ^ r[15];
      r = {r[14:0], 1'b0};
      if (fb) r = r ^ CRC_TAPS;
    end
    return r;
  endfunction

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

  // Which register, and which window.  The page is 1,024 words: 0 to 8 the
  // registers, 0x100 to 0x1FF the transmit window, 0x200 to 0x2FF the
  // receive window.
  logic in_tx_win, in_rx_win;
  assign in_tx_win = (r_word[9:8] == 2'b01);
  assign in_rx_win = (r_word[9:8] == 2'b10);

  // ------------------------------------------------------------------------
  // The two buffers, 256 words each: the card's own two 2147s have their
  // mirror here.
  // ------------------------------------------------------------------------
  logic [15:0] tx_buf [256];
  logic [15:0] rx_buf [256];
  logic [15:0] tx_q, rx_q;
  // Where the receive buffer is read: the stream's own counter while a
  // commit runs, and the face's word otherwise.  **A MUX ON THE ADDRESS AND
  // NOT ON THE DATA**, which is the difference between a RAM Vivado infers
  // and `Synth 8-2914`; and the face's word goes in DIRECTLY rather than
  // through a register of its own, because `cadr_gp_regs` samples `rd_data`
  // on the tick after `rd` and a register in front of the address would put
  // the word one address behind --- measured, as an off-by-one on every beat
  // of a read of this window.
  logic [7:0]  rx_rd_sel;
  logic [7:0]  stream_at;

  // ------------------------------------------------------------------------
  // The registers this face keeps
  // ------------------------------------------------------------------------
  logic [15:0] r_myaddr;
  logic [8:0]  r_rxlen;
  logic [8:0]  tx_held;        // words the card handed over
  logic [15:0] tx_check;       // the check word over them and the source
  logic        tx_valid;       // a frame is waiting for Linux
  logic [31:0] lost;
  logic [23:0] resets;
  logic [1:0]  irq_q, irqen;
  logic        rdone_was;      // the card's Receive Done a tick ago
  logic        txv_was;

  // The transmit capture, and the receive stream.
  typedef enum logic [1:0] { C_IDLE, C_WORDS, C_SRC } cstate_e;
  typedef enum logic [2:0] { X_IDLE, X_PRIME, X_STREAM, X_GAP, X_DONE } xstate_e;
  cstate_e cst;
  xstate_e xst;
  logic [8:0]  cap_at, cap_len;
  logic [15:0] crc;
  logic [8:0]  sent;

  assign chaos_address  = r_myaddr;
  assign chaos_cbl_busy = 1'b0;      // see the header
  assign chaos_tx_abort = 1'b0;      // see the header
  assign chaos_rx_crc   = 1'b0;      // see the header

  // The stream: one word a tick while `X_STREAM`, then an idle tick, then
  // one tick of `chaos_rx_done`.  The idle tick is not tidiness --- the card
  // takes `ch_rlen` from `ch_fill` on the done tick, so a done on the last
  // word's own tick stores that word and does not count it.
  assign chaos_rx_valid = (xst == X_STREAM);
  assign chaos_rx_word  = rx_q;
  assign chaos_rx_done  = (xst == X_DONE);
  assign chaos_rx_bits  = {r_rxlen, 4'b0000};   // sixteen bits a word

  assign irq = |(irq_q & irqen);

  // ------------------------------------------------------------------------
  // What a read gives.  The two buffers answer from their read registers,
  // which `cadr_gp_regs` samples on the tick after `rd` --- exactly the tick
  // a synchronous read is out.
  // ------------------------------------------------------------------------
  logic [31:0] stat_word, ctl_word;
  assign stat_word = {chaos_csr, 12'd0, chaos_csr[1], !chaos_csr[15],
                      chaos_csr[15], tx_valid};
  assign ctl_word  = {resets, 8'd0};

  // Where the trailer sits in the transmit window: the source at `tx_held`
  // and the check word after it.
  logic [8:0] win_at;
  assign win_at = {1'b0, r_word[7:0]};
  always_comb begin
    if (in_tx_win) begin
      if (!tx_valid) rd_data = 32'd0;
      else if (win_at < tx_held) rd_data = {16'd0, tx_q};
      else if (win_at == tx_held) rd_data = {16'd0, r_myaddr};
      else if (win_at == tx_held + 9'd1) rd_data = {16'd0, tx_check};
      else rd_data = 32'd0;
    end else if (in_rx_win) begin
      rd_data = {16'd0, rx_q};
    end else begin
      unique case (r_word)
        10'd0:   rd_data = IDENT;
        10'd1:   rd_data = stat_word;
        10'd2:   rd_data = {16'd0, r_myaddr};
        10'd3:   rd_data = tx_valid ? {22'd0, {1'b0, tx_held} + 10'd2} : 32'd0;
        10'd4:   rd_data = {23'd0, r_rxlen};
        10'd5:   rd_data = ctl_word;
        10'd6:   rd_data = lost;
        10'd7:   rd_data = {30'd0, irq_q};
        10'd8:   rd_data = {30'd0, irqen};
        default: rd_data = 32'd0;
      endcase
    end
  end

  // A write into one of the two windows, and the three commands.
  logic win_wr, cmd_wr;
  assign win_wr = wr && (w_word[9:8] == 2'b10);
  assign cmd_wr = wr && (w_word == 10'd5);

  // Whether a commit may be taken: the card's buffer empty, nothing already
  // streaming, and a length that is a frame.  The card's Receive Done is a
  // register and can only be CLEARED by the machine, so a commit allowed
  // here stays allowed for the whole stream --- see the header for the
  // window that leaves and who closes it.
  logic commit_ok;
  assign commit_ok = cmd_wr && wr_data[1] && wr_mask[1] &&
                     !chaos_csr[15] && (xst == X_IDLE) &&
                     (r_rxlen != 9'd0) && (r_rxlen <= 9'd256);

  // The two buffers' own processes, kept pure: nothing but an address and a
  // datum, because Vivado refuses a RAM process with a mux on its read
  // (`Synth 8-2914`) and Verilator lints and simulates one happily.
  assign rx_rd_sel = (xst == X_PRIME || xst == X_STREAM) ? stream_at : r_word[7:0];

  always_ff @(posedge clk) begin
    if (win_wr) rx_buf[w_word[7:0]] <= wr_data[15:0];
    rx_q <= rx_buf[rx_rd_sel];
  end

  always_ff @(posedge clk) begin
    if ((cst == C_WORDS) && chaos_tx_valid) tx_buf[cap_at[7:0]] <= chaos_tx_word;
    tx_q <= tx_buf[r_word[7:0]];
  end

  // ------------------------------------------------------------------------
  // The cable
  // ------------------------------------------------------------------------
  logic [1:0] irq_set, irq_clr;
  assign irq_set = {rdone_was && !chaos_csr[15],     // the machine emptied it
                    tx_valid && !txv_was};           // a frame is waiting
  assign irq_clr = (wr && w_word == 10'd7) ? (wr_data[1:0] & wr_mask[1:0]) : 2'd0;

  always_ff @(posedge clk) begin
    if (rst) begin
      r_myaddr    <= 16'd0;
      r_rxlen     <= 9'd0;
      tx_held     <= 9'd0;
      tx_check    <= 16'd0;
      tx_valid    <= 1'b0;
      lost        <= 32'd0;
      resets      <= 24'd0;
      irq_q       <= 2'd0;
      irqen       <= 2'd0;
      rdone_was   <= 1'b0;
      txv_was     <= 1'b0;
      cst         <= C_IDLE;
      xst         <= X_IDLE;
      cap_at      <= 9'd0;
      cap_len     <= 9'd0;
      crc         <= 16'd0;
      sent        <= 9'd0;
      stream_at   <= 8'd0;
      chaos_tx_done <= 1'b0;
    end else begin
      // One tick, always: the card samples this level every tick with no
      // gate of its own, and a second tick of it would raise Transmit Done
      // for a frame that never went.
      chaos_tx_done <= 1'b0;
      rdone_was <= chaos_csr[15];
      txv_was   <= tx_valid;
      irq_q     <= (irq_q & ~irq_clr) | irq_set;

      // --- the frame the machine transmits
      unique case (cst)
        C_IDLE: ;
        C_WORDS: if (chaos_tx_valid) begin
          crc <= crc_word(crc, chaos_tx_word);
          if (cap_at + 9'd1 == cap_len) cst <= C_SRC;
          else cap_at <= cap_at + 9'd1;
        end
        // The source the hardware adds, stepped into the check word on its
        // own tick: the burst has ended, so the tick is free, and chaining
        // two word-steps into one tick would double the depth of the only
        // arithmetic here.
        C_SRC: begin
          tx_check <= crc_word(crc, r_myaddr);
          tx_held  <= cap_len;
          tx_valid <= 1'b1;
          cst      <= C_IDLE;
        end
        default: cst <= C_IDLE;
      endcase

      if (chaos_tx_go) begin
        cap_len <= chaos_tx_len;
        cap_at  <= 9'd0;
        crc     <= 16'd0;
        if (chaos_tx_len == 9'd0) begin
          // START on an empty buffer: nothing goes on the cable, and the
          // machine is let go at once rather than waiting for a Transmit
          // Done that would never come.
          cst           <= C_IDLE;
          chaos_tx_done <= 1'b1;
        end else begin
          cst <= C_WORDS;
        end
      end

      // --- the frame Linux gives the machine
      unique case (xst)
        X_IDLE: if (commit_ok) begin
          stream_at <= 8'd0;
          sent      <= 9'd0;
          xst       <= X_PRIME;
        end
        // One tick for the buffer's read of word 0 to reach `rx_q`.
        X_PRIME: begin
          stream_at <= 8'd1;
          xst       <= X_STREAM;
        end
        X_STREAM: begin
          stream_at <= stream_at + 8'd1;
          if (sent + 9'd1 == r_rxlen) xst <= X_GAP;
          else sent <= sent + 9'd1;
        end
        X_GAP:  xst <= X_DONE;
        X_DONE: xst <= X_IDLE;
        default: xst <= X_IDLE;
      endcase

      // --- what Linux writes
      if (wr) begin
        unique case (w_word)
          10'd2: r_myaddr <= (r_myaddr & ~wr_mask[15:0]) | (wr_data[15:0] & wr_mask[15:0]);
          10'd4: r_rxlen  <= (r_rxlen & ~wr_mask[8:0]) | (wr_data[8:0] & wr_mask[8:0]);
          10'd8: irqen    <= (irqen & ~wr_mask[1:0]) | (wr_data[1:0] & wr_mask[1:0]);
          default: ;
        endcase
      end

      // The three commands.  Taking the frame is what lets the machine's
      // Transmit Done come up, and it is gated on there being one: a done
      // pulse with nothing outstanding would raise Transmit Done for a
      // frame the machine never sent.
      if (cmd_wr) begin
        if (wr_data[0] && wr_mask[0] && tx_valid) begin
          tx_valid      <= 1'b0;
          chaos_tx_done <= 1'b1;
        end
        if (wr_data[1] && wr_mask[1] && !commit_ok && lost != 32'hFFFF_FFFF) begin
          lost <= lost + 32'd1;
        end
        // Throw away what is in the RX window: the length goes, which is
        // what a commit needs, and the words are overwritten next time.
        if (wr_data[2] && wr_mask[2]) r_rxlen <= 9'd0;
      end

      // --- Clear Transmitter: the frame is dropped and the card raises its
      // own Transmit Done, so nothing goes out on the seam.
      if (chaos_tx_clear) begin
        tx_valid <= 1'b0;
        cst      <= C_IDLE;
      end

      // --- Reset, or `-UB INIT`.  `LOST` is NOT cleared: `chaos_face_give`
      // reads it before and after a commit and treats any change as a
      // refusal, so a count that went backwards would read a stored frame
      // as a refused one.  The address switches are not cleared either ---
      // a reset of the interface does not move a switch.
      if (chaos_reset) begin
        tx_valid <= 1'b0;
        cst      <= C_IDLE;
        xst      <= X_IDLE;
        r_rxlen  <= 9'd0;
        if (resets != 24'hFFFFFF) resets <= resets + 24'd1;
      end
    end
  end

  // The upper half of a write beat reaches no register here: the widest
  // word this face takes is the sixteen-bit address switches.  And `rd` is
  // the face saying a read is owed, which matters only to a register whose
  // read has an effect --- the serial line's `RDATA` --- and no word here
  // has one.  Read so that lint's bit granularity has nothing to say, which
  // is what catches a mutation that drops a bit.
  logic unused_s;
  assign unused_s = ^{wr_data[31:16], wr_mask[31:16], rd};

endmodule

`default_nettype wire
