// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S MAIN MEMORY ON A 64-BIT AXI PORT** (contract G3
// revision 15, A15b.5): the line fills and the posted writes
// of `rtl/machine/quux15_port.sv`, on separate read and write channels,
// with up to 16 writes outstanding.  Main memory is in packed storage, five
// bytes a word: word `w` at byte `5w`, line `L` at byte `40L`.
//
//   a line read   five beats from `40L`, INCR, one burst; or two when the
//                 line runs past a 4 KiB boundary (`40L mod 4096` from 4064
//                 to 4088), the second address the clock after the first;
//                 the line's 40 bytes come with its last beat
//   a word write  five bytes from `5w`: one beat with five strobes, or two
//                 beats when the word runs past its first 8-byte beat
//                 (offsets 4 to 7, half of all words); two bursts of a beat
//                 each when that second beat starts a 4 KiB page.  The write
//                 is ACCEPTED when its address and its first beat are taken
//                 (the port's accept, `w_taken`); its second beat or second
//                 burst follows the next clock, and the write channel takes
//                 no other write until then (muir's `port::beats`).
//
// **ONE AXI ID A WRITE SLOT** (`w_id`, the port's in-flight slot): the
// responses may come in any order between slots, and the port retires the
// writes in order whatever order they come in.  muir's port lands, at one
// clock, every write at the in-flight list's front that is answered by
// then, several at once when a later one was answered before an earlier
// one; one B a clock with one ID could not land two writes in one clock.
// A split write's two bursts share their slot's ID, and its answer is the
// second B.
//
// **THE DECLARED CONSTANTS INSIDE r AND w** (A15b.5): a fill lands
// in the port the clock after its last beat (`READ_FABRIC_CLOCKS`, counted
// from the first address taken by the testbench's responder, which answers
// the last beat `⌈r/P⌉ − 1` clocks after it); a write lands the clock after
// its B (`WRITE_FABRIC_CLOCKS`, the responder answering `⌈w/P⌉ − 1` clocks
// after the accept, plus its seeded lateness).  The addresses and the
// first beat go out in the clock the port decides them, with no register
// between.

`default_nettype none

module quux15_axi_master #(
    parameter int unsigned ID_BITS = 4,
    // The declared constants inside r and w (A15b.5): the clocks
    // from a line's last beat to its fill landing in the port, and from a
    // write's B to its landing.
    localparam int unsigned READ_FABRIC_CLOCKS  = 1,
    localparam int unsigned WRITE_FABRIC_CLOCKS = 1
) (
    input  var logic               clk,
    input  var logic               rst,

    // --- A line read: the port asks, the first address is taken, the line's
    // --- 40 bytes come with its last beat.
    input  var logic               ar_req,
    input  var logic [25:0]        ar_line,
    output var logic               ar_taken,
    output var logic               rd_last,
    output var logic [319:0]       rd_data,

    // --- A word write: the queue's head offered while `w_free`, accepted.
    input  var logic               w_req,
    input  var logic [28:0]        w_bus,
    input  var logic [39:0]        w_word,
    input  var logic [ID_BITS-1:0] w_id,
    output var logic               w_free,
    output var logic               w_taken,
    // A write answered: its slot, and whether either B was an error.
    output var logic               b_done,
    output var logic [ID_BITS-1:0] b_id,
    output var logic               b_err,
    // The constants, for the testbench's responder.
    output var logic [3:0]         read_fabric_clocks,
    output var logic [3:0]         write_fabric_clocks,

    // --- The AXI4 master port, 64 bits.
    output var logic [ID_BITS-1:0] m_awid,
    output var logic [31:0]        m_awaddr,
    output var logic [7:0]         m_awlen,
    output var logic [2:0]         m_awsize,
    output var logic [1:0]         m_awburst,
    output var logic               m_awvalid,
    input  var logic               m_awready,
    output var logic [63:0]        m_wdata,
    output var logic [7:0]         m_wstrb,
    output var logic               m_wlast,
    output var logic               m_wvalid,
    input  var logic               m_wready,
    input  var logic [ID_BITS-1:0] m_bid,
    input  var logic [1:0]         m_bresp,
    input  var logic               m_bvalid,
    output var logic               m_bready,
    output var logic [31:0]        m_araddr,
    output var logic [7:0]         m_arlen,
    output var logic [2:0]         m_arsize,
    output var logic [1:0]         m_arburst,
    output var logic               m_arvalid,
    input  var logic               m_arready,
    input  var logic [63:0]        m_rdata,
    input  var logic [1:0]         m_rresp,
    input  var logic               m_rlast,
    input  var logic               m_rvalid,
    output var logic               m_rready
);

  assign read_fabric_clocks  = 4'(READ_FABRIC_CLOCKS);
  assign write_fabric_clocks = 4'(WRITE_FABRIC_CLOCKS);

  localparam logic [2:0] SIZE_8 = 3'd3;
  localparam logic [1:0] INCR   = 2'b01;
  localparam int unsigned SLOTS = 1 << ID_BITS;

  // ================================================================ reads

  // The line's byte address, and where it crosses 4 KiB: the first burst's
  // beats, 1 to 4, when it does.
  logic [31:0] line_byte;
  logic [11:0] line_off;
  logic        line_split;
  logic [2:0]  first_beats;
  always_comb begin
    line_byte   = {ar_line, 5'd0} + {2'd0, ar_line, 3'd0};   // 40L
    line_off    = line_byte[11:0];
    line_split  = line_off > 12'd4056;
    first_beats = 3'((13'd4096 - {1'b0, line_off}) >> 3);
  end

  typedef enum logic [1:0] {R_IDLE, R_SECOND, R_DATA} rstate_e;
  rstate_e     rstate;
  logic [31:0] second_addr;
  logic [7:0]  second_len;
  logic [2:0]  beat;
  logic [63:0] beats [4];

  always_comb begin
    m_arsize  = SIZE_8;
    m_arburst = INCR;
    m_arvalid = 1'b0;
    m_araddr  = line_byte;
    m_arlen   = line_split ? {5'd0, first_beats - 3'd1} : 8'd4;
    ar_taken  = 1'b0;
    unique case (rstate)
      R_IDLE: begin
        m_arvalid = ar_req;
        ar_taken  = ar_req && m_arready;
      end
      R_SECOND: begin
        m_arvalid = 1'b1;
        m_araddr  = second_addr;
        m_arlen   = second_len;
      end
      default: ;
    endcase
    m_rready = 1'b1;
    rd_last  = rstate != R_IDLE && m_rvalid && beat == 3'd4;
    rd_data  = {m_rdata, beats[3], beats[2], beats[1], beats[0]};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rstate <= R_IDLE;
      beat  <= 3'd0;
    end else begin
      unique case (rstate)
        R_IDLE: if (ar_taken) begin
          rstate       <= line_split ? R_SECOND : R_DATA;
          second_addr <= {line_byte[31:12] + 20'd1, 12'd0};
          second_len  <= {5'd0, 3'd4 - first_beats};
          beat        <= 3'd0;
        end
        R_SECOND: if (m_arready) rstate <= R_DATA;
        default: ;
      endcase
      if (rstate != R_IDLE && m_rvalid) begin
        if (beat < 3'd4) beats[beat[1:0]] <= m_rdata;
        beat <= beat + 3'd1;
        if (beat == 3'd4) rstate <= R_IDLE;
      end
    end
  end

  // =============================================================== writes

  // The word's first beat: its byte address `5w`, the beat's address, the
  // offset in it, and whether it runs into a second beat, and that beat
  // into another 4 KiB page.
  logic [31:0] wb_byte, beat_addr;
  logic [2:0]  off;
  logic        two, split;
  logic [63:0] data1, data2;
  logic [7:0]  strb1, strb2;
  logic [103:0] shifted;
  always_comb begin
    wb_byte   = {1'b0, w_bus, 2'd0} + {3'd0, w_bus};          // 5w
    beat_addr = {wb_byte[31:3], 3'd0};
    off       = wb_byte[2:0];
    two       = off >= 3'd4;
    split     = two && (beat_addr[11:3] == 9'h1ff);
    shifted   = {64'd0, w_word} << (8 * off);
    data1     = shifted[63:0];
    data2     = {24'd0, shifted[103:64]};
    strb1     = 8'(16'h001f << off);
    strb2     = 8'((16'h001f << off) >> 8);
  end

  // The continuation of the last write accepted: its second beat, and for
  // a split its second address too.
  logic        cont_v, cont_aw, cont_aw_done, cont_w_done;
  logic [31:0] cont_addr;
  logic [63:0] cont_data;
  logic [7:0]  cont_strb;
  logic [ID_BITS-1:0] cont_id;
  // Each slot's write is split, its first B to be held.
  logic [SLOTS-1:0] split_q, first_b_q, err_q;
  logic        w_hs;

  always_comb begin
    w_free    = !cont_v;
    m_awburst = INCR;
    m_awsize  = SIZE_8;
    m_bready  = 1'b1;
    if (cont_v) begin
      m_awvalid = cont_aw && !cont_aw_done;
      m_awid    = cont_id;
      m_awaddr  = cont_addr;
      m_awlen   = 8'd0;
      m_wvalid  = !cont_w_done;
      m_wdata   = cont_data;
      m_wstrb   = cont_strb;
      m_wlast   = 1'b1;
    end else begin
      m_awvalid = w_req;
      m_awid    = w_id;
      m_awaddr  = beat_addr;
      m_awlen   = (two && !split) ? 8'd1 : 8'd0;
      m_wvalid  = w_req;
      m_wdata   = data1;
      m_wstrb   = strb1;
      m_wlast   = !(two && !split);
    end
    // The accept: the address and the first beat taken together.  A port
    // that takes them apart is held to both, here as on the bus.
    w_hs    = !cont_v && w_req && m_awready && m_wready;
    w_taken = w_hs;
    // A write's answer: its last B.
    b_done = m_bvalid && !(split_q[m_bid] && !first_b_q[m_bid]);
    b_id   = m_bid;
    b_err  = m_bresp[1] || err_q[m_bid];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cont_v    <= 1'b0;
      split_q   <= '0;
      first_b_q <= '0;
      err_q     <= '0;
    end else begin
      if (w_hs) begin
        cont_v       <= two;
        cont_aw      <= split;
        cont_aw_done <= 1'b0;
        cont_w_done  <= 1'b0;
        cont_addr    <= beat_addr + 32'd8;
        cont_data    <= data2;
        cont_strb    <= strb2;
        cont_id      <= w_id;
        split_q[w_id]   <= split;
        first_b_q[w_id] <= 1'b0;
        err_q[w_id]     <= 1'b0;
      end else if (cont_v) begin
        if (m_awvalid && m_awready) cont_aw_done <= 1'b1;
        if (m_wvalid && m_wready) cont_w_done <= 1'b1;
        if ((!cont_aw || cont_aw_done || (m_awvalid && m_awready))
            && (cont_w_done || (m_wvalid && m_wready)))
          cont_v <= 1'b0;
      end
      if (m_bvalid) begin
        if (split_q[m_bid] && !first_b_q[m_bid]) begin
          first_b_q[m_bid] <= 1'b1;
          err_q[m_bid]     <= m_bresp[1];
        end
      end
    end
  end

  // What nothing reads: the responses' other bits.
  logic unused;
  assign unused = ^{m_rresp, m_rlast, data1[0], m_bresp[0]};

endmodule

`default_nettype wire
