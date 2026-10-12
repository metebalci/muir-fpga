// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S CHAOSNET INTERFACE** (contracts Q4 and Q13; G3 revision 15,
// A15b.3, §9; MP2b rulings Q4 and Q19; the MP5a review's finding 5):
// AIM-628 section 7's five registers on the register page's words 140-147,
// cut from `cadr_io_board.sv`'s Chaosnet interface and put on revision 15's
// register timing.  muir's `chaos::board::Interface` behind `Machine`'s
// `network_register` is the reference:
//
//     140   the CSR, read and written
//     141   read: MY ADDRESS; written: a word into the outgoing buffer
//     142   read: a word out of the incoming buffer
//     143   read: the bit count
//     145   read: START, which is MY ADDRESS again and sends the buffer
//     144, 146, 147   read 0; a write of any word but 140 and 141 goes
//                     nowhere (`network_register`: only the five decode,
//                     where the CADR's board aliases 764150, 764156 and a
//                     write of 764152)
//
// **THE REGISTERS AND THE TWO BUFFERS ARE THIS MODULE'S AND THE CABLE IS
// NOT**, as on the CADR's card: the turn timer, the frame, the check word
// and the transceiver are `cadr-chaosnet`'s on a board, behind
// `cadr_chaos_cable.sv`, whose seam this module keeps port for port
// (`chaos_*`), so that program runs unchanged.  **SO NOTHING HERE KEEPS
// TIME**: the network's times (MP2b ruling Q19) are the far end's, which
// says when a frame lands, when one is away and when the cable is busy.
// The CADR's card times only its Unibus answers (`CHAOS_BUF_T` and the
// receive buffer's `FCLK^`), which revision 15 does not have.
//
// **1. A READ IS THE PAGE AT THE CLOCK AFTER ITS GRANT, AND SO IS ITS SIDE
// EFFECT** (`quux15_devices.sv`'s rule; MP2b ruling Q4): `rd` is that clock,
// `rd_word` the word as the registers stand in it, before the read does
// anything, and the read's effect --- the incoming buffer's pointer and the
// bit count stepped, START's buffer sent --- is made at that clock's edge.
// muir reads at `instant(grant + 1)` and makes the effect there.
//
// **2. A WRITE IS TAKEN IN ITS CLOCK, AFTER WHAT CAME OFF THE CABLE BEFORE
// IT**: muir's `Interface::write` advances to the instant first and applies
// the store after, so a Clear Receiver in the clock a frame was committed
// in leaves the buffer empty.  What the far end does in a clock (`chaos_rx_*`,
// `chaos_tx_done`, `chaos_rx_lost`) is in the registers from the next.
//
// **3. THE INTERRUPT, WORD 100's `<6>`, IS THE PAGE AS THIS CLOCK'S WRITE
// LEAVES IT** (`irq`; A15b.3's row "A device register"), the cable's events
// of this clock not in it; `irq_state` is the page as the clock began, which
// word 100's read gives.  `(Receive Done AND its enable) OR (Transmit Done
// AND its enable)`, as `chaos::board::Interface::interrupt_request` and the
// 74S51 at LMUCON 0E05; the timer enable, CSR `<0>`, stores and reads back
// and reaches no gate.
//
// **4. RESET**, the CSR's write-only `<13>` and RESET-DEVICES (word 104
// `<0>`, `dev_reset`; muir's `reset_devices` reaches the I/O board's
// `-UB INIT`), both AIM-628's "as at power up", and `chaos_reset` tells the
// far end.  The console's `-RESET` and `-BOOT` do not reach it, as muir's
// pipeline's do not.
//
// The receive buffer's word is read off its RAM a clock ahead, at the
// pointer the edge leaves, so that a read in any clock after a commit or a
// step gives the word at the pointer.
//
// What holds it: `build/quux15_chaos_module.quux.pass`, the module against
// muir's `chaos::board::Interface` over `golden/src/quux15_chaos.rs`'s
// script; and `build/quux15_network.quux.pass`, the core's `network` group
// (`golden/src/quux15_network.rs`), clock for clock on muir's pipeline with
// frames put on muir's cable and the testbench playing the far end as muir's
// interface saw it.

`default_nettype none

module quux15_chaos (
    input  var logic        clk,
    input  var logic        rst,
    // RESET-DEVICES, taken this clock.
    input  var logic        dev_reset,

    // A read landing this clock, the clock after its grant, at word 140 +
    // `rd_k`; and a write taken this clock.
    input  var logic        rd,
    input  var logic [2:0]  rd_k,
    input  var logic        wr,
    input  var logic [2:0]  wr_k,
    input  var logic [15:0] wdata,
    // The word the read gives, before what it does.
    output var logic [15:0] rd_word,

    // Word 100's <6>: as this clock's write leaves it, and as the clock
    // began.
    output var logic        irq,
    output var logic        irq_state,

    // --- the cable's seam, `cadr_io_board.sv`'s and `cadr_chaos_cable.sv`'s
    input  var logic [15:0] chaos_address,  // the switches: MY ADDRESS
    output var logic        chaos_tx_go,    // START was read: this frame is to go
    output var logic [8:0]  chaos_tx_len,   // how many words of it, 0 to 256
    output var logic        chaos_tx_valid, // one word of it, in order, from the clock after
    output var logic [15:0] chaos_tx_word,
    output var logic        chaos_tx_clear, // Clear Transmitter: drop a frame not yet away
    output var logic        chaos_reset,    // Reset, or RESET-DEVICES
    output var logic [15:0] chaos_csr,      // the CSR as a read assembles it
    input  var logic        chaos_rx_valid, // one word into the receive buffer
    input  var logic [15:0] chaos_rx_word,
    input  var logic        chaos_rx_done,  // that was the packet
    input  var logic [12:0] chaos_rx_bits,  // its length, what the bit counter loads
    input  var logic        chaos_rx_crc,   // its check word failed
    input  var logic        chaos_rx_lost,  // a frame for this interface found the buffer busy
    input  var logic        chaos_tx_done,  // the frame is away
    input  var logic        chaos_tx_abort, // ...or a collision took it
    input  var logic        chaos_cbl_busy, // the cable busy, which bit 14 shows as muir's model does
    output var logic [11:0] chaos_bits      // the bit counter
);

  localparam int unsigned CH_WORDS = 256;
  localparam logic [2:0] K_CSR   = 3'd0;   // 140
  localparam logic [2:0] K_ADDR  = 3'd1;   // 141: MY ADDRESS read, the write buffer written
  localparam logic [2:0] K_RBUF  = 3'd2;   // 142
  localparam logic [2:0] K_BITS  = 3'd3;   // 143
  localparam logic [2:0] K_START = 3'd5;   // 145

  // The 2147s at LMTBUF 0C10 and LMRBUF 0C04: 256 words each.
  logic [15:0] ch_xmit [CH_WORDS];
  logic [15:0] ch_rcv  [CH_WORDS];
  logic [8:0]  ch_xn;        // words in the transmit buffer, 0 to 256
  logic        ch_taken;     // START took it: the next write starts again at 0
  logic [8:0]  ch_fill;      // words the far end has put in for the next packet
  logic [8:0]  ch_rlen;      // words the packet in the buffer has
  logic [8:0]  ch_rat;       // the read pointer
  logic [12:0] ch_rbits;     // what the bit counter was loaded with
  logic [12:0] ch_left;      // bits not yet read out
  logic [5:0]  ch_wbits;     // the five bits a write reaches, `chaos::board::WRITABLE`
  logic        ch_tdone, ch_tabort, ch_rdone, ch_crc;
  logic [3:0]  ch_lost;
  logic [15:0] ch_rd;        // the buffer's word at the pointer
  logic [8:0]  ch_out, ch_send;
  logic        ch_sending;

  // Where the next word of a packet goes: one write port, the mux on its
  // address (`cadr_io_board.sv` says why).
  logic [8:0] ch_wn;
  assign ch_wn = ch_taken ? 9'd0 : ch_xn;

  // The CSR as read: bits 13, 8 and 3 are write-only commands and read 0;
  // bit 14 is the check word's verdict, with the cable's busy ORed in as
  // muir's `csr()` has it.
  assign chaos_csr = {ch_rdone, ch_crc || chaos_cbl_busy, 1'b0, ch_lost, 1'b0,
                      ch_tdone, ch_tabort, ch_wbits};

  // "The number of bits in the incoming packet buffer, minus one.  After the
  // whole packet has been read out, it will contain 7777."
  logic [12:0] ch_top, ch_step;
  logic [11:0] ch_less;
  assign ch_top  = ch_rbits - {(ch_rlen - 9'd1), 4'd0};
  assign ch_step = (ch_rat == 9'd0) ? ch_top : 13'd16;
  assign ch_less = ch_left[11:0] - 12'd1;
  assign chaos_bits = !ch_rdone          ? 12'd0
                    : (ch_left == 13'd0) ? 12'o7777
                                         : ch_less;

  // The word a read gives.
  always_comb begin
    unique case (rd_k)
      K_CSR:          rd_word = chaos_csr;
      K_ADDR, K_START: rd_word = chaos_address;
      // Past the packet's words the buffer reads 0, never the RAM's stale
      // word (`self.rcv.get(self.rcv_at).copied().unwrap_or(0)`).
      K_RBUF:         rd_word = (ch_rat < ch_rlen) ? ch_rd : 16'd0;
      K_BITS:         rd_word = {4'd0, chaos_bits};
      default:        rd_word = 16'd0;
    endcase
  end

  // This clock's access.
  logic csr_w, buf_w, start_r, rbuf_r, reset_now;
  assign csr_w     = wr && wr_k == K_CSR;
  assign buf_w     = wr && wr_k == K_ADDR;
  assign start_r   = rd && rd_k == K_START;
  assign rbuf_r    = rd && rd_k == K_RBUF && ch_rat != ch_rlen;
  assign reset_now = dev_reset || (csr_w && wdata[13]);

  // **THE INTERRUPT AS THIS CLOCK'S WRITE LEAVES IT.**
  logic n_rdone, n_tdone;
  logic [5:4] n_wbits;
  assign n_wbits   = csr_w ? wdata[5:4] : ch_wbits[5:4];
  assign n_rdone   = (csr_w && wdata[3]) ? 1'b0 : ch_rdone;
  assign n_tdone   = (csr_w && wdata[8]) ? 1'b1 : (buf_w ? 1'b0 : ch_tdone);
  assign irq       = !reset_now && ((n_rdone && n_wbits[4]) || (n_tdone && n_wbits[5]));
  assign irq_state = (ch_rdone && ch_wbits[4]) || (ch_tdone && ch_wbits[5]);

  // The pointer the edge leaves, for the buffer's read a clock ahead.
  logic [8:0] ch_rat_n;
  always_comb begin
    ch_rat_n = ch_rat;
    if (rbuf_r) ch_rat_n = ch_rat + 9'd1;
    if ((csr_w && wdata[3]) || reset_now) ch_rat_n = 9'd0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      // As at power-up: the read/write bits zero, Transmit Done up so that
      // the first transmission may start, the receiver ready.
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
    end else begin
      chaos_tx_go    <= 1'b0;
      chaos_tx_clear <= 1'b0;
      chaos_reset    <= 1'b0;
      chaos_tx_valid <= 1'b0;

      // --- the far end, first: what a write in this clock does stands.
      // The transmit buffer streams out from the clock after START, a word
      // a clock.
      if (ch_sending) begin
        chaos_tx_valid <= 1'b1;
        chaos_tx_word  <= ch_xmit[ch_out[7:0]];
        ch_out         <= ch_out + 9'd1;
        if (ch_out + 9'd1 == ch_send) ch_sending <= 1'b0;
      end
      // The receive buffer fills a word at a time and commits whole; a
      // packet committed on a full buffer is dropped whole and counted.
      // **A COMMIT LEAVES THE POINTER WHERE IT IS, AT 0**: with Receive
      // Done down the pointer and the length are 0, since only power-on,
      // Clear Receiver and Reset take Receive Done down and each zeroes
      // them, and a read steps the pointer only below the length.  The
      // module's testbench holds that at every clock.
      if (chaos_rx_valid && !ch_rdone && ch_fill != 9'd256) begin
        ch_rcv[ch_fill[7:0]] <= chaos_rx_word;
        ch_fill              <= ch_fill + 9'd1;
      end
      if (chaos_rx_done) begin
        ch_fill <= 9'd0;
        if (ch_rdone) begin
          ch_lost <= ch_lost + 4'd1;
        end else begin
          ch_rlen  <= ch_fill;
          ch_rbits <= chaos_rx_bits;
          ch_left  <= chaos_rx_bits;
          ch_crc   <= chaos_rx_crc;
          ch_rdone <= 1'b1;
        end
      end
      // A frame the far end had for this interface with the buffer busy:
      // counted, nothing else.  Lost Count wraps at sixteen (a 74LS161;
      // muir's `(self.lost + 1) & 0o17`).
      if (chaos_rx_lost) ch_lost <= ch_lost + 4'd1;
      if (chaos_tx_done) begin
        ch_tdone  <= 1'b1;
        ch_tabort <= chaos_tx_abort;
      end
      ch_rd <= ch_rcv[ch_rat_n[7:0]];

      // --- this clock's access
      if (wr) begin
        unique case (wr_k)
          K_CSR: begin
            ch_wbits <= {wdata[5:4], 1'b0, wdata[2:0]};
            if (wdata[3]) begin   // Clear Receiver
              ch_rdone <= 1'b0;
              ch_crc   <= 1'b0;
              ch_rlen  <= 9'd0;
              ch_rat   <= 9'd0;
              ch_left  <= 13'd0;
              ch_rbits <= 13'd0;
              ch_fill  <= 9'd0;
              ch_lost  <= 4'd0;
            end
            if (wdata[8]) begin   // Clear Transmitter
              ch_xn          <= 9'd0;
              ch_taken       <= 1'b0;
              ch_sending     <= 1'b0;
              ch_tdone       <= 1'b1;
              ch_tabort      <= 1'b0;
              chaos_tx_clear <= 1'b1;
            end
          end
          K_ADDR: begin
            // "A word into the outgoing packet buffer.  The last word
            // written is the destination address."  A 257th has nowhere
            // to go.
            if (ch_wn != 9'd256) begin
              ch_xmit[ch_wn[7:0]] <= wdata;
              ch_xn               <= ch_wn + 9'd1;
            end else begin
              ch_xn <= ch_wn;
            end
            ch_taken  <= 1'b0;
            ch_tdone  <= 1'b0;
            ch_tabort <= 1'b0;
          end
          default: ;   // 142-147 take no write
        endcase
      end
      if (start_r) begin
        // START: the buffer goes, and the next write starts a new packet.
        // **A START AFTER A START SENDS AN EMPTY BUFFER**, the words having
        // gone with the first (muir's `mem::take`), so its length is the
        // next write's place, not the count the first left.
        chaos_tx_go  <= 1'b1;
        chaos_tx_len <= ch_wn;
        ch_send      <= ch_wn;
        ch_out       <= 9'd0;
        ch_sending   <= (ch_wn != 9'd0);
        ch_taken     <= 1'b1;
      end
      if (rbuf_r) begin
        // A word out of the incoming buffer, and the bit counter down by
        // what the read took.
        ch_rat  <= ch_rat + 9'd1;
        ch_left <= (ch_left > ch_step) ? (ch_left - ch_step) : 13'd0;
      end

      // --- Reset, last: it subsumes both clears.
      if (reset_now) begin
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

  // The pointer's ninth bit names no word of the RAM.
  logic unused;
  assign unused = ch_rat_n[8];

endmodule

`default_nettype wire
