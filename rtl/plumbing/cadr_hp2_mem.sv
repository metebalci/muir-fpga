// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk pack face's own memory master, on a board with no processing system
// to answer it: sixty-four bit AXI3 bursts onto a one-word memory port.
//
// WHAT IT STANDS IN FOR.  On the Arty Z7-20 `cadr_disk_pack.sv` masters
// `S_AXI_HP2`, a port of the Zynq's own DDR controller, and moves a block as
// nine bursts: eight of sixteen beats and one of two, each beat eight bytes.
// This board has no Zynq.  Its DDR3L is behind the generated controller, which
// has one user interface, and `cadr_mem_share.sv` is where that interface is
// shared.  So the face keeps its master unchanged and this module is the slave
// it talks to.
//
// ONE BEAT IS TWO WORDS.  Word 2k of the record is the low half of beat k, at
// the burst's address plus 8k, and word 2k+1 is the high half, four bytes on.
// That is how `cadr_disk_pack.sv`'s header lays the record out and how AXI lays
// out a little-endian beat.  So a read beat is two word requests and a write
// beat is up to two.  Every word is a request of its own to the arbiter, which
// is what lets the machine step in between any two of them.
//
// **FOUR STROBES WRITE A WORD AND NO STROBES SKIP IT.**  The memory port writes
// whole words.  The face's last beat has its low half strobed and its high half
// not, because the word after the data checkword is never written, and that
// skip is honored.  A half with some of its four strobes set and some not is
// refused with SLVERR and not written.  The face never sends one, and a
// partial write rounded up to a word would overwrite bytes nobody asked for.
//
// WHAT COMES BACK AS SLVERR.  A burst that is not eight-byte incrementing, a
// word the memory refused, a write burst whose WLAST is not where its length
// says, and a partially strobed half.  `cadr_disk_pack.sv` reads the high bit
// of RRESP and BRESP and reports a move that met either as an error, and
// `cadr_mig_ui.sv` refuses every address outside the machine's reservation, so
// a record placed outside it fails its move rather than landing somewhere else.
//
// ONE BURST AT A TIME.  The face issues one burst, waits for its last beat or
// its response, and only then issues the next.  So the address channels are
// ready only when nothing is in flight, and a read address wins a tie with a
// write address.
//
// NO muir REFERENCE EXISTS FOR ANY OF THIS, as none exists for the face's
// master.  It is held to the AXI protocol and to read-back: a record written
// through another master and fetched by the face must be the words that land
// in the store, and a slot the face writes back must be the words the other
// master reads.  `tb/cadr_a7_mem_tb.cpp` does both with the real face.

`default_nettype none

module cadr_hp2_mem (
    input  var logic        clk,
    input  var logic        rst,

    // --- the face's master: 64 bits, AXI3, incrementing bursts ------------
    input  var logic [31:0] s_awaddr,
    input  var logic [3:0]  s_awlen,
    input  var logic [1:0]  s_awsize,
    input  var logic [1:0]  s_awburst,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [63:0] s_wdata,
    input  var logic [7:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [31:0] s_araddr,
    input  var logic [3:0]  s_arlen,
    input  var logic [1:0]  s_arsize,
    input  var logic [1:0]  s_arburst,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [63:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- one word a request, the `mem_*` handshake -------------------------
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata,
    input  var logic        mem_error
);

  localparam logic [1:0] SIZE_BEAT  = 2'b11;   // 2^3 = 8 bytes
  localparam logic [1:0] BURST_INCR = 2'b01;
  localparam logic [1:0] OKAY       = 2'b00;
  localparam logic [1:0] SLVERR     = 2'b10;

  typedef enum logic [3:0] {
    IDLE,
    R_ASK,      // one of the beat's two words is asked for
    R_LET_GO,   // ...and answered; waiting for the answer to fall
    R_BEAT,     // the beat stands until it is taken
    W_BEAT,     // waiting for a write beat
    W_WORD,     // what this half's strobes say to do
    W_ASK,      // the half is written
    W_LET_GO,   // ...and answered; waiting for the answer to fall
    W_NEXT,     // the other half, the next beat, or the response
    W_RESP      // the response stands until it is taken
  } state_e;

  state_e      st;
  logic [31:0] at;        // the beat's first byte
  logic [31:0] word_at;   // the word being asked for, made a tick before
  logic [3:0]  len, beat;
  logic        bad;       // not an eight-byte incrementing burst
  logic        half;      // 0 the beat's low word, 1 its high word
  logic [31:0] lo, hi;
  logic        rerr, werr;
  logic [63:0] wbeat;
  logic [7:0]  wstrb_q;
  logic        wlast_q;

  // This half's four strobes.
  logic [3:0] nib;
  assign nib = half ? wstrb_q[7:4] : wstrb_q[3:0];

  assign s_arready = (st == IDLE);
  assign s_awready = (st == IDLE) && !s_arvalid;

  assign s_rvalid = (st == R_BEAT);
  assign s_rdata  = {hi, lo};
  assign s_rresp  = rerr ? SLVERR : OKAY;
  assign s_rlast  = (beat == len);

  assign s_wready = (st == W_BEAT);
  assign s_bvalid = (st == W_RESP);
  assign s_bresp  = werr ? SLVERR : OKAY;

  assign mem_req   = (st == R_ASK) || (st == W_ASK);
  assign mem_write = (st == W_ASK);
  assign mem_addr  = word_at;
  assign mem_wdata = half ? wbeat[63:32] : wbeat[31:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      st      <= IDLE;
      at      <= 32'd0;
      word_at <= 32'd0;
      len     <= 4'd0;
      beat    <= 4'd0;
      bad     <= 1'b0;
      half    <= 1'b0;
      lo      <= 32'd0;
      hi      <= 32'd0;
      rerr    <= 1'b0;
      werr    <= 1'b0;
      wbeat   <= 64'd0;
      wstrb_q <= 8'd0;
      wlast_q <= 1'b0;
    end else begin
      unique case (st)
        IDLE: begin
          if (s_arvalid) begin
            at      <= s_araddr;
            word_at <= s_araddr;
            len     <= s_arlen;
            beat    <= 4'd0;
            half    <= 1'b0;
            lo      <= 32'd0;
            hi      <= 32'd0;
            bad     <= (s_arsize != SIZE_BEAT) || (s_arburst != BURST_INCR);
            rerr    <= (s_arsize != SIZE_BEAT) || (s_arburst != BURST_INCR);
            st      <= ((s_arsize != SIZE_BEAT) || (s_arburst != BURST_INCR))
                       ? R_BEAT : R_ASK;
          end else if (s_awvalid) begin
            at      <= s_awaddr;
            len     <= s_awlen;
            beat    <= 4'd0;
            bad     <= (s_awsize != SIZE_BEAT) || (s_awburst != BURST_INCR);
            werr    <= (s_awsize != SIZE_BEAT) || (s_awburst != BURST_INCR);
            st      <= W_BEAT;
          end
        end

        // --- a read beat: the low word, then the high one, then the beat
        R_ASK: if (mem_done) begin
          if (half) hi <= mem_rdata;
          else      lo <= mem_rdata;
          if (mem_error) rerr <= 1'b1;
          st <= R_LET_GO;
        end
        R_LET_GO: if (!mem_done) begin
          if (!half) begin
            half    <= 1'b1;
            word_at <= at + 32'd4;
            st      <= R_ASK;
          end else begin
            st <= R_BEAT;
          end
        end
        R_BEAT: if (s_rready) begin
          if (beat == len) begin
            st <= IDLE;
          end else begin
            beat    <= beat + 4'd1;
            at      <= at + 32'd8;
            word_at <= at + 32'd8;
            half    <= 1'b0;
            lo      <= 32'd0;
            hi      <= 32'd0;
            rerr    <= bad;
            st      <= bad ? R_BEAT : R_ASK;
          end
        end

        // --- a write beat: each half by its strobes, then the next
        W_BEAT: if (s_wvalid) begin
          wbeat   <= s_wdata;
          wstrb_q <= s_wstrb;
          wlast_q <= s_wlast;
          half    <= 1'b0;
          word_at <= at;
          st      <= W_WORD;
        end
        W_WORD: begin
          if (bad) begin
            st <= W_NEXT;
          end else if (nib == 4'hF) begin
            st <= W_ASK;
          end else begin
            if (nib != 4'h0) werr <= 1'b1;
            st <= W_NEXT;
          end
        end
        W_ASK: if (mem_done) begin
          if (mem_error) werr <= 1'b1;
          st <= W_LET_GO;
        end
        W_LET_GO: if (!mem_done) st <= W_NEXT;
        W_NEXT: begin
          if (!half) begin
            half    <= 1'b1;
            word_at <= at + 32'd4;
            st      <= W_WORD;
          end else if (wlast_q) begin
            // The burst ends where the master says it does, and a master
            // whose WLAST and length disagree has sent the wrong number of
            // words: the response says so.
            if (beat != len) werr <= 1'b1;
            st <= W_RESP;
          end else begin
            if (beat == len) werr <= 1'b1;
            beat <= beat + 4'd1;
            at   <= at + 32'd8;
            st   <= W_BEAT;
          end
        end
        W_RESP: if (s_bready) st <= IDLE;

        default: st <= IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
