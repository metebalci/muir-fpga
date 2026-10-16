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
// **THE REGISTERS, THE TWO BUFFERS AND THE CHECKER ARE THIS MODULE'S AND
// THE CABLE IS NOT**, as on the CADR's card: the turn timer, the
// transceiver and the receiver's verdict on a frame are `cadr-chaosnet`'s
// on a board, behind `cadr_chaos_cable.sv`, whose seam this module keeps
// port for port (`chaos_*`), so that program runs unchanged.  **SO NOTHING
// HERE KEEPS TIME**: the network's times (MP2b ruling Q19) are the far
// end's, which says when a frame lands, when one is away and when the cable
// is busy.
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
// **5. BOTH BUFFERS GO ROUND** (muir's `chaos::board`, measured on the
// netlist board; `cadr_io_board.sv` has the long account).  Each is a 2147,
// 4K by 1, on a twelve-bit count that wraps: a word written past the 256th
// goes over the first, and START sends `(16n + 32) mod 4096` bits for `n`
// words written, the source and the check word put in at the count like
// the words --- nothing at all for 254.  A frame longer than the incoming
// buffer leaves its last 4,096 bits, the ones read first; reads go on round
// the buffer for ever, the bit count with them in twelve bits; CRC Error
// from the first read on is the check of the words read; and a run of 48
// bits or fewer lands nowhere and leaves its bits.
//
// **6. THE RECEIVE GATE IS THIS MODULE'S AND THE LINE THE FAR END'S**, as on
// the CADR's card (`cadr_io_board.sv` has the netlist's account): the far end
// gives a frame on the line from its first edge to its idle
// (`chaos_cbl_busy`), its `START^` and the bits stored so far, all before any
// gate; `RACT` takes Receive Done at `START^` and `RRESET` --- Clear Receiver,
// Reset, RESET-DEVICES --- takes it down.  Through it bit 14 is the line
// taken, as revision 15's interface keeps it (muir's `running_check` is the
// CADR board's alone), and the bit count the bits stored.  A frame taken and
// not landed leaves its bits, which the far end hands over with
// `chaos_rx_store`, and with Receive Done down a read of the buffer is the
// read register shifted, counting RBCT down inside a frame not taken.
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
    output var logic [8:0]  chaos_tx_len,   // how many words of it, 0 to 255
    output var logic        chaos_tx_valid, // one word of it, in order, from the clock after
    output var logic [15:0] chaos_tx_word,
    output var logic        chaos_tx_clear, // Clear Transmitter: drop a frame not yet away
    output var logic        chaos_reset,    // Reset, or RESET-DEVICES
    output var logic [15:0] chaos_csr,      // the CSR as a read assembles it
    input  var logic        chaos_rx_valid, // one word into the receive buffer
    input  var logic [15:0] chaos_rx_word,
    input  var logic        chaos_rx_done,  // that was the packet
    input  var logic [12:0] chaos_rx_bits,  // its length, from its first word to its done
    input  var logic        chaos_rx_crc,   // its check word failed
    input  var logic        chaos_rx_lost,  // a frame for this interface found the buffer busy
    input  var logic        chaos_tx_done,  // the frame is away
    input  var logic        chaos_tx_abort, // ...or a collision took it
    input  var logic        chaos_cbl_busy, // a frame on the line, from its first edge to its idle
    input  var logic        chaos_rx_start, // one clock: the frame's START^
    input  var logic [11:0] chaos_rx_stored, // the bits the receiver would have stored of it by now: RBCT
    input  var logic        chaos_rx_store, // with `chaos_rx_done`: store the bits, do not land them
    output var logic [11:0] chaos_bits      // the bit counter
);

  localparam int unsigned CH_WORDS = 256;
  localparam logic [2:0] K_CSR   = 3'd0;   // 140
  localparam logic [2:0] K_ADDR  = 3'd1;   // 141: MY ADDRESS read, the write buffer written
  localparam logic [2:0] K_RBUF  = 3'd2;   // 142
  localparam logic [2:0] K_BITS  = 3'd3;   // 143
  localparam logic [2:0] K_START = 3'd5;   // 145

  // The two checkers, Fairchild 9401s: the one at LMTBUF 0C09 makes the
  // check word as the words are written, the one at LMRBUF 0C07 checks the
  // read-out.  muir's
  // `packet::check_word`, CRC-16 `x^16 + x^15 + x^2 + 1` from a cleared
  // register, a word most significant bit first, stage k in bit k.  One
  // word a step, `check_on`'s step.
  localparam logic [15:0] CRC_TAPS = 16'h8005;   // 1 | 1<<2 | 1<<15
  function automatic logic [15:0] crc_word(input logic [15:0] crc_in, input logic [15:0] crc_w);
    logic [15:0] crc_q;
    logic        crc_fb;
    crc_q = crc_in;
    for (int crc_k = 15; crc_k >= 0; crc_k--) begin
      crc_fb = crc_w[crc_k] ^ crc_q[15];
      crc_q  = {crc_q[14:0], 1'b0};
      if (crc_fb) crc_q = crc_q ^ CRC_TAPS;
    end
    return crc_q;
  endfunction

  // The 2147s at LMTBUF 0C10 and LMRBUF 0C04: 256 words each, on counts that
  // wrap.  The incoming one comes up all ones, which is what the netlist's
  // RAM reads as never written (muir's `NEVER_WRITTEN`); what a real 2147
  // holds at power-up is not known.
  // On a board "power-up" is configuration: a reboot that does not load the
  // bitstream again keeps the old words, as muir's Reset keeps its buffer.
  logic [15:0] ch_xmit [CH_WORDS];
  logic [15:0] ch_rcv  [CH_WORDS];
  initial for (int ch_k = 0; ch_k < CH_WORDS; ch_k++) ch_rcv[ch_k] = 16'hFFFF;

  // --- the transmitter
  logic [7:0]  ch_xn;        // TBCT in words: the words written, mod 256
  logic [15:0] ch_xcheck;    // the check of every word written
  logic        ch_taken;     // START took them: the next write starts again at 0
  logic [7:0]  ch_out, ch_send;  // the frame's word going out, and its length
  logic [7:0]  ch_src_at;    // where the source is in it; the check word after
  logic [15:0] ch_tcheck;    // the check word START made
  logic        ch_sending;
  logic [15:0] ch_xq;        // the transmit buffer's word at `ch_out`
  logic        ch_q_src, ch_q_chk;   // ...or the source, or the check word, instead
  // --- the receiver
  logic [8:0]  ch_fill;      // words of the frame coming in so far, held at 257
  logic [7:0]  ch_top;       // the word its last bit is in: where read 0 is
  logic [15:0] ch_w0;        // its first word, as handed
  logic [15:0] ch_hi;        // its 257th, whose bits above a partial first word stay
  logic        ch_hi_set;
  logic [15:0] ch_tw;        // the first word as the buffer holds it once landed
  logic [3:0]  ch_rlow;      // the frame's bits mod 16: the first word's bits
  logic [7:0]  ch_rat;       // reads taken, mod 256: the 25LS193s at LMRBUF
  logic        ch_read;      // ...and whether any has been since it landed
  logic [11:0] ch_rbct;      // RBCT
  logic [15:0] ch_rcheck;    // the check of the words read
  logic [5:0]  ch_wbits;     // the five bits a write reaches, `chaos::board::WRITABLE`
  logic        ch_tdone, ch_tabort, ch_rdone, ch_crc;
  logic [3:0]  ch_lost;
  logic [15:0] ch_rd;        // the buffer's word at the pointer
  logic        ch_drop;      // the stream coming in is dropped: its done commits nothing
  // --- the receive gate and the read path with Receive Done down
  logic        ch_ract;      // RACT: set at START^ with Receive Done down, down at RRESET
  logic        ch_started;   // the frame on the line has had its START^
  logic [15:0] ch_sr;        // the read register
  logic        ch_down;      // reads count RBCT down inside the frame on the line
  logic [11:0] ch_dhw;       // ...RBCT as they leave it
  logic [15:0] ch_dcheck;    // ...and the check of the bits they read

  // Where the next word of a packet goes, and the check it carries on.
  logic [7:0]  ch_wn;
  logic [15:0] ch_wcheck;
  assign ch_wn     = ch_taken ? 8'd0 : ch_xn;
  assign ch_wcheck = ch_taken ? 16'd0 : ch_xcheck;

  // The word the frame's stream gives: the buffer's, or in their places the
  // source and the check word, which on the board go in at the count.
  assign chaos_tx_word = ch_q_src ? chaos_address : (ch_q_chk ? ch_tcheck : ch_xq);

  // The gate: the frame on the line taken, its `START^` still to come
  // counting as taken (muir's `taking`); and the reads' count-down inside the
  // frame it began in, no packet in the buffer (`down_here`).
  logic ch_taking, ch_down_here;
  assign ch_taking    = chaos_cbl_busy && (!ch_started || ch_ract);
  assign ch_down_here = ch_down && chaos_cbl_busy && !ch_rdone;

  // The CSR as read: bits 13, 8 and 3 are write-only commands and read 0;
  // bit 14 is the check word's verdict, and the line while the receiver
  // takes a frame, and inside a frame the reads count down through the check
  // of the bits read (muir's `csr()` on revision 15).
  assign chaos_csr = {ch_rdone, ch_crc || ch_taking || (ch_down_here && ch_dcheck != 16'd0),
                      1'b0, ch_lost, 1'b0, ch_tdone, ch_tabort, ch_wbits};

  // "The number of bits in the incoming packet buffer, minus one": RBCT
  // less one in twelve bits (muir's `bit_count`); with Receive Done down
  // RBCT as it stands, the bits stored so far of a frame taken, the
  // count-down's inside one not taken, and 0 otherwise.
  assign chaos_bits = ch_rdone     ? ch_rbct - 12'd1 :
                      ch_taking    ? chaos_rx_stored :
                      ch_down_here ? ch_dhw : 12'd0;

  // The first word's bits, the rest above them: what the first read shows.
  logic [15:0] ch_low;
  assign ch_low = (ch_rlow == 4'd0) ? 16'hFFFF : ~(16'hFFFF << ch_rlow);

  // The word a read of the buffer gives: the first with zeros above the
  // frame's last bit, each after it the buffer's own, round and round; with
  // Receive Done down the read register shifted (muir's `read_down`): with
  // the line idle the last word read up a bit and RBCT 0's bit below it,
  // inside a frame not taken the count-down's, its first read RBCT 0's bit
  // and each after a whole word.  A read while the receiver takes a frame is
  // outside muir's model; the script never makes one, and the module
  // shifts as on an idle line.
  logic [15:0] ch_word;
  assign ch_word = ch_rdone     ? (!ch_read ? (ch_tw & ch_low) : ch_rd) :
                   ch_down_here ? ch_rd : {ch_sr[14:0], ch_rd[0]};

  // The word a read gives.
  always_comb begin
    unique case (rd_k)
      K_CSR:          rd_word = chaos_csr;
      K_ADDR, K_START: rd_word = chaos_address;
      K_RBUF:         rd_word = ch_word;
      K_BITS:         rd_word = {4'd0, chaos_bits};
      default:        rd_word = 16'd0;
    endcase
  end

  // This clock's access.
  logic csr_w, buf_w, start_r, rbuf_r, reset_now;
  assign csr_w     = wr && wr_k == K_CSR;
  assign buf_w     = wr && wr_k == K_ADDR;
  assign start_r   = rd && rd_k == K_START;
  assign rbuf_r    = rd && rd_k == K_RBUF && ch_rdone;
  logic down_r;
  assign down_r    = rd && rd_k == K_RBUF && !ch_rdone;
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
  logic [7:0] ch_rat_n;
  always_comb begin
    ch_rat_n = ch_rat;
    if (rbuf_r) ch_rat_n = ch_rat + 8'd1;
    if ((csr_w && wdata[3]) || reset_now) ch_rat_n = 8'd0;
  end
  // And the count-down the edge leaves: a read of the buffer with Receive
  // Done down inside a frame not taken counts RBCT down from where the last
  // left it, from 0 the first time; the line idle, a clear or a Reset ends
  // it.
  logic        ch_down_n;
  logic [11:0] ch_dhw_n;
  always_comb begin
    ch_down_n = ch_down && chaos_cbl_busy;
    ch_dhw_n  = ch_dhw;
    if (down_r) begin
      if (!chaos_cbl_busy) begin
        ch_down_n = 1'b0;
      end else if (!ch_taking) begin
        ch_down_n = 1'b1;
        ch_dhw_n  = ch_down_here ? ch_dhw - 12'd16 : 12'hFFF;
      end
    end
    if ((csr_w && wdata[3]) || reset_now) ch_down_n = 1'b0;
  end

  // **A FRAME COMES IN A WORD A CLOCK IN THE ORDER THE SOFTWARE READS IT,
  // ITS LENGTH ON `chaos_rx_bits` FROM THE FIRST WORD**, and the words go
  // where the board's RBCT puts their bits.  On the cable the check word
  // comes first and the bits go in at RBCT from 0, so word k of a frame of
  // `bits` bits lands at the buffer's word `top - k`, `top` the word its last
  // bit is in; past the 4,096th bit the count wraps and the newer bits go
  // over the older.  So the first 256 words read are the frame's first 256
  // and every one past them is older and gone, but for the 257th's bits
  // above a partial first word, which share its place (muir's `land`).  The
  // first word goes in last, merged over what the place held, at the done.
  logic        rx_in, rx_first, taken_now, commit, rx_mid;
  logic [11:0] rx_top_bit;    // the frame's last bit, in twelve bits
  logic [15:0] rx_low, rx_merged;
  // **A CLEAR RECEIVER OR A RESET LANDING WHILE A FRAME STREAMS IN DROPS THE
  // REST OF THE STREAM AND ITS DONE**, as `cadr_io_board.sv`'s card does,
  // for the netlist's reason given there and with the same two limits: a
  // clear or Reset between the far end's commit and the first word on the
  // seam lands before the stream, and what a read round the buffer shows of
  // a dropped stream's words is held by nothing.  A Clear Receiver sets
  // `ch_drop`, and the done that ends the stream commits nothing; a Reset's
  // `chaos_reset` ends the far end's stream with no done, so nothing that
  // comes in the clock it is up is taken, and a drop ends with it.
  assign rx_mid     = (chaos_rx_valid || ch_fill != 9'd0) && !chaos_rx_done;
  assign rx_in      = chaos_rx_valid && !ch_rdone && !chaos_reset;
  assign rx_first   = rx_in && ch_fill == 9'd0;
  assign rx_top_bit = chaos_rx_bits[11:0] - 12'd1;
  // A run of 48 bits or fewer --- the check, source and destination words
  // and nothing after them --- lands nowhere, its destination matching or
  // not: no Receive Done and no Lost Count (muir's `arrive`).
  assign taken_now  = chaos_rx_done && !ch_drop && !chaos_reset && !chaos_rx_store && (chaos_rx_bits > 13'd48);
  assign commit     = taken_now && !ch_rdone;
  // A frame taken and not landed leaves its bits: stored as a frame's, with
  // no Receive Done and no Lost Count; a run of 48 bits or fewer is judged
  // by its length.
  logic store_now;
  assign store_now  = chaos_rx_done && !ch_drop && !chaos_reset && !ch_rdone &&
                      (chaos_rx_store || chaos_rx_bits <= 13'd48);
  assign rx_low     = (chaos_rx_bits[3:0] == 4'd0) ? 16'hFFFF : ~(16'hFFFF << chaos_rx_bits[3:0]);
  assign rx_merged  = ((ch_hi_set ? ch_hi : ch_rd) & ~rx_low) | (ch_w0 & rx_low);

  // The incoming buffer's one write: a word of the frame at its place, or
  // the first word merged at the done.
  logic        rcv_we;
  logic [7:0]  rcv_wa, rcv_ra;
  logic [15:0] rcv_wd;
  always_comb begin
    rcv_we = 1'b0;
    rcv_wa = ch_top - ch_fill[7:0];
    rcv_wd = chaos_rx_word;
    if (commit || store_now) begin
      rcv_we = 1'b1;
      rcv_wa = ch_top;
      rcv_wd = rx_merged;
    end else if (rx_in && ch_fill != 9'd0 && ch_fill < 9'd256) begin
      rcv_we = 1'b1;
    end
  end
  // The read a clock ahead: the word at the pointer, or the one a frame
  // streaming in has its first word go over; with Receive Done down and no
  // stream, the word the read register takes from, RBCT 0's or the
  // count-down's.
  logic       ch_rdone_n;
  logic [7:0] ch_top_n;
  assign ch_rdone_n = (ch_rdone || commit) && !(csr_w && wdata[3]) && !reset_now;
  assign ch_top_n   = rx_first ? rx_top_bit[11:4] : ch_top;
  assign rcv_ra = (ch_rdone_n || ch_fill != 9'd0 || rx_in) ? ch_top_n - ch_rat_n :
                  ch_down_n ? ch_dhw_n[11:4] : 8'd0;

  // The two buffers' own processes, nothing but an address and a datum.
  always_ff @(posedge clk) begin
    if (rcv_we) ch_rcv[rcv_wa] <= rcv_wd;
    ch_rd <= ch_rcv[rcv_ra];
  end
  always_ff @(posedge clk) begin
    if (buf_w) ch_xmit[ch_wn] <= wdata;
    ch_xq <= ch_xmit[ch_out];
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
      ch_xn       <= 8'd0;
      ch_xcheck   <= 16'd0;
      ch_taken    <= 1'b0;
      ch_fill     <= 9'd0;
      ch_drop     <= 1'b0;
      ch_ract     <= 1'b0;
      ch_started  <= 1'b0;
      ch_sr       <= 16'd0;
      ch_down     <= 1'b0;
      ch_dhw      <= 12'd0;
      ch_dcheck   <= 16'd0;
      ch_top      <= 8'd0;
      ch_w0       <= 16'd0;
      ch_hi       <= 16'd0;
      ch_hi_set   <= 1'b0;
      ch_tw       <= 16'd0;
      ch_rlow     <= 4'd0;
      ch_rat      <= 8'd0;
      ch_read     <= 1'b0;
      ch_rbct     <= 12'd0;
      ch_rcheck   <= 16'd0;
      ch_out      <= 8'd0;
      ch_send     <= 8'd0;
      ch_src_at   <= 8'd0;
      ch_tcheck   <= 16'd0;
      ch_q_src    <= 1'b0;
      ch_q_chk    <= 1'b0;
      ch_sending  <= 1'b0;
      chaos_tx_go    <= 1'b0;
      chaos_tx_len   <= 9'd0;
      chaos_tx_valid <= 1'b0;
      chaos_tx_clear <= 1'b0;
      chaos_reset    <= 1'b0;
    end else begin
      chaos_tx_go    <= 1'b0;
      chaos_tx_clear <= 1'b0;
      chaos_reset    <= 1'b0;
      chaos_tx_valid <= 1'b0;

      // --- the far end, first: what a write in this clock does stands.
      // The frame streams out from the clock after START, a word a clock.
      if (ch_sending) begin
        chaos_tx_valid <= 1'b1;
        ch_q_src       <= ch_out == ch_src_at;
        ch_q_chk       <= ch_out == ch_src_at + 8'd1;
        ch_out         <= ch_out + 8'd1;
        if (ch_out + 8'd1 == ch_send) ch_sending <= 1'b0;
      end
      // The frame coming in.  **A COMMIT LEAVES THE POINTER WHERE IT IS, AT
      // 0**: with Receive Done down the pointer is 0, since only power-on,
      // Clear Receiver and Reset take Receive Done down and each zeroes it,
      // and a read steps it only with Receive Done up.  The module's
      // testbench holds that at every clock.
      if (rx_in) begin
        if (rx_first) begin
          ch_top <= rx_top_bit[11:4];
          ch_w0  <= chaos_rx_word;
        end
        if (ch_fill == 9'd256) begin
          ch_hi     <= chaos_rx_word;
          ch_hi_set <= 1'b1;
        end
        if (ch_fill != 9'd257) ch_fill <= ch_fill + 9'd1;
      end
      if (chaos_rx_done) begin
        ch_fill   <= 9'd0;
        ch_hi_set <= 1'b0;
      end
      if (chaos_rx_done || chaos_reset) ch_drop <= 1'b0;
      if (taken_now) begin
        // A packet committed on a full buffer is dropped whole and counted.
        if (ch_rdone) begin
          ch_lost <= ch_lost + 4'd1;
        end else begin
          ch_rdone  <= 1'b1;
          ch_crc    <= chaos_rx_crc;
          ch_rbct   <= chaos_rx_bits[11:0];
          ch_rlow   <= chaos_rx_bits[3:0];
          ch_tw     <= rx_merged;
          ch_read   <= 1'b0;
          ch_rcheck <= 16'd0;
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
      // The line: `RACT` takes Receive Done at the frame's `START^`; the
      // `START^` is over with the frame, and the count-down as the edge
      // leaves it.  A frame landing clears the read register.
      if (!chaos_cbl_busy) ch_started <= 1'b0;
      if (chaos_rx_start) begin
        ch_started <= 1'b1;
        ch_ract    <= !ch_rdone;
      end
      ch_down <= ch_down_n;
      ch_dhw  <= ch_dhw_n;
      if (commit) ch_sr <= 16'd0;

      // --- this clock's access
      if (wr) begin
        unique case (wr_k)
          K_CSR: begin
            ch_wbits <= {wdata[5:4], 1'b0, wdata[2:0]};
            if (wdata[3]) begin   // Clear Receiver
              ch_rdone  <= 1'b0;
              ch_crc    <= 1'b0;
              ch_rat    <= 8'd0;
              ch_read   <= 1'b0;
              ch_rbct   <= 12'd0;
              ch_rcheck <= 16'd0;
              ch_fill   <= 9'd0;
              ch_hi_set <= 1'b0;
              ch_lost   <= 4'd0;
              ch_ract   <= 1'b0;
              if (rx_mid) ch_drop <= 1'b1;
            end
            if (wdata[8]) begin   // Clear Transmitter
              ch_xn          <= 8'd0;
              ch_xcheck      <= 16'd0;
              ch_taken       <= 1'b0;
              ch_sending     <= 1'b0;
              ch_tdone       <= 1'b1;
              ch_tabort      <= 1'b0;
              chaos_tx_clear <= 1'b1;
            end
          end
          K_ADDR: begin
            // "A word into the outgoing packet buffer.  The last word
            // written is the destination address."  It goes in at TBCT,
            // which goes round: a word past the 256th goes over the first.
            // The transmit 9401 takes it as it goes in.
            ch_xn     <= ch_wn + 8'd1;
            ch_xcheck <= crc_word(ch_wcheck, wdata);
            ch_taken  <= 1'b0;
            ch_tdone  <= 1'b0;
            ch_tabort <= 1'b0;
          end
          default: ;   // 142-147 take no write
        endcase
      end
      if (start_r) begin
        // START: the source and the check word go in at the count after
        // the words, the check of every word written and the source, and
        // the frame is what the buffer holds below the count, `(n + 2) mod
        // 256` words for `n` written: the words, the source and the check
        // up to 253, nothing for 254, and from 255 the check word and what
        // the wrap left below it (muir's `Interface::start`).  The words
        // go with it, and the next write starts a new packet.  **A START
        // AFTER A START SENDS AN EMPTY BUFFER**, the source and the check
        // word.  **AND IT LOWERS TRANSMIT DONE** (MIT's TRESET); the far
        // end's `chaos_tx_done` raises it again, for a frame of nothing
        // too.
        chaos_tx_go  <= 1'b1;
        ch_tdone     <= 1'b0;
        chaos_tx_len <= {1'b0, ch_wn + 8'd2};
        ch_send      <= ch_wn + 8'd2;
        ch_src_at    <= ch_wn;
        ch_tcheck    <= crc_word(ch_wcheck, chaos_address);
        ch_out       <= 8'd0;
        ch_sending   <= (ch_wn + 8'd2 != 8'd0);
        ch_taken     <= 1'b1;
      end
      if (rd && rd_k == K_RBUF) ch_sr <= ch_word;
      if (down_r && chaos_cbl_busy && !ch_taking)
        ch_dcheck <= ch_down_here ? crc_word(ch_dcheck, ch_rd) : (ch_rd[0] ? CRC_TAPS : 16'd0);
      if (rbuf_r) begin
        // A word out of the incoming buffer, through the receive 9401: CRC
        // Error is from now the check of the words read, up partway
        // through a good frame and down at its end (muir's `read`).  RBCT
        // comes down to the word boundary below the frame's last bit at
        // the first read and sixteen a read after, round and round.
        ch_rat    <= ch_rat + 8'd1;
        ch_read   <= 1'b1;
        ch_rcheck <= crc_word(ch_rcheck, ch_word);
        ch_crc    <= crc_word(ch_rcheck, ch_word) != 16'd0;
        ch_rbct   <= ch_read ? ch_rbct - 12'd16 : {ch_top, 4'd0};
      end

      // --- Reset, last: it subsumes both clears.
      if (reset_now) begin
        // Lost Count stays, as on the CADR's card: its 74LS161 clears on
        // Clear Receiver alone.
        ch_wbits    <= 6'd0;
        ch_tdone    <= 1'b1;
        ch_tabort   <= 1'b0;
        ch_rdone    <= 1'b0;
        ch_crc      <= 1'b0;
        ch_ract     <= 1'b0;
        ch_xn       <= 8'd0;
        ch_xcheck   <= 16'd0;
        ch_taken    <= 1'b0;
        ch_fill     <= 9'd0;
        ch_hi_set   <= 1'b0;
        ch_rat      <= 8'd0;
        ch_read     <= 1'b0;
        ch_rbct     <= 12'd0;
        ch_rcheck   <= 16'd0;
        ch_sending  <= 1'b0;
        chaos_reset <= 1'b1;
      end
    end
  end

  // The last bit's place inside its word names no word of the buffer.
  logic unused;
  assign unused = ^rx_top_bit[3:0] ^ ch_sr[15];

endmodule

`default_nettype wire
