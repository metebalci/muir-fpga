// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's main memory on a 64-bit AXI port: the Arty Z7-20's `S_AXI_HP0` and
// the DE25-Nano's FPGA-to-SDRAM bridge through `cadr_f2sdram_share.sv`.
// It is `cadr_axi_master.sv` and `cadr_axi_widen.sv` in one, for QUUX alone,
// with the one thing QUUX's memory port asks that the CADR's never does: a
// LINE FILL, four words at a 16-byte boundary in two full-width beats, the
// cache's miss (contract Q6, `rtl/machine/quux_mem_port.sv`).  The CADR keeps
// its own pair, untouched.
//
//   a word read     ARLEN 0, a 64-bit beat, the half `A[2]` selects;
//   a line read     ARLEN 1, INCR, two 64-bit beats at the line's address,
//                   the first beat words 0 and 1, the second 2 and 3, the
//                   answer on the LAST beat and not on the word's own ---
//                   muir's fill time does not depend on where the word is;
//   a word write    AWLEN 0, the word in both halves of the beat and the
//                   strobes on the half `A[2]` selects, so the other word of
//                   the beat is left as it was.
//
// **REVISION 13 ASKS MORE OF IT** (contract G2 §3, G1 §4.1; `WORD_BITS` 40):
// main memory in packed storage, five bytes a word.
//
//   a line read     `mem_beats` beats from `mem_addr`, an 8-byte address:
//                   five for a line of main memory, four for one of the
//                   frame buffer window; beat k in `mem_rline[64k +: 64]`;
//   a wide write    five bytes of `mem_wdata` from `mem_addr`, any byte,
//                   `<7:0>` first: one beat with five strobes, or two beats
//                   when the word runs past the first (offsets 4 to 7);
//   a word write    four bytes, as above: the window, and the uncached
//                   requester.
//
// **AN AXI BURST MAY NOT CROSS A 4 KiB BOUNDARY**, and both kinds can: a
// 40-byte line at `40L mod 4096` from 4064 to 4088, 4 lines in 512, and a
// 5-byte word whose second beat starts a 4 KiB page, 1 word in 1,024 (4096
// is 1 mod 5).  Each is issued as two bursts, the first up to the boundary
// and the second from it, and a line's second address goes out as soon as
// the first is taken rather than after the first's data: measured on both
// boards (contract G2's M6, D5), back to back the split costs nothing on
// the Arty and one or two ticks on the DE25-Nano, and one after the other
// 22 and 38.  The words come back in order, one ID, and the answer is the
// last beat of the second burst.  A write's two bursts are one beat each,
// the second's address after the first's, and the answer the second B.
// **THE FIRST BURST'S B IS TAKEN AS SOON AS IT COMES**, while the second
// address still waits: the DE25-Nano's shared port takes no write address
// while another write is owed its response (`cadr_f2sdram_share.sv`), so a
// master that took no B until both addresses were in would wait on the port
// while the port waited on it.  Seen on the board, revision 13's PROM
// stopped at its fourth block, whose words cross a 4 KiB boundary;
// `tb/quux13_axi_master_tb.cpp` keeps that port's rule for half its run.
// The rule is taken on the byte address itself, whatever the base.
//
// Every transfer is the port's full width: the bridge refuses a narrow one,
// and the Zynq's `ps7_init` is used unmodified at 64 bits
// (`cadr_axi_widen.sv` has the argument).  Both ports are AXI3 here, four
// bits of length, which is what the Zynq's AFI port is and what the DE25's
// share takes.
//
// The protocol toward the machine is `cadr_axi_master.sv`'s: `mem_req` a
// level held until `mem_done`, `mem_done` held until the request falls, and
// a transaction whose request fell before its answer came is finished on
// the port and its answer thrown away --- ABANDONED, never withdrawn,
// because a port that has taken an address will answer it and the answer
// must not be taken for the next request's.  One transaction at a time, of
// one or two bursts.

`default_nettype none

module quux_axi_master #(
    // 32, QUUX to revision 12; 40, revision 13's five-byte words.
    parameter int unsigned WORD_BITS = 32,
    localparam bit          WIDE       = WORD_BITS > 32,
    localparam int unsigned RLINE_BITS = WIDE ? 320 : 128
) (
    input  var logic         clk,
    input  var logic         rst,

    input  var logic         mem_req,
    input  var logic         mem_write,
    input  var logic         mem_line,    // a read of a line, `mem_beats` beats
    input  var logic [2:0]   mem_beats,   // 2; on revision 13 4 or 5
    input  var logic         mem_wide,    // a write of five bytes, revision 13
    input  var logic [31:0]  mem_addr,    // byte address
    input  var logic [WORD_BITS-1:0] mem_wdata,
    output var logic         mem_done,
    output var logic [31:0]  mem_rdata,
    output var logic [RLINE_BITS-1:0] mem_rline,
    output var logic         mem_error,   // SLVERR or DECERR came back

    output var logic [31:0]  m_awaddr,
    output var logic [3:0]   m_awlen,
    output var logic [1:0]   m_awsize,
    output var logic [1:0]   m_awburst,
    output var logic         m_awvalid,
    input  var logic         m_awready,
    output var logic [63:0]  m_wdata,
    output var logic [7:0]   m_wstrb,
    output var logic         m_wlast,
    output var logic         m_wvalid,
    input  var logic         m_wready,
    input  var logic [1:0]   m_bresp,
    input  var logic         m_bvalid,
    output var logic         m_bready,
    output var logic [31:0]  m_araddr,
    output var logic [3:0]   m_arlen,
    output var logic [1:0]   m_arsize,
    output var logic [1:0]   m_arburst,
    output var logic         m_arvalid,
    input  var logic         m_arready,
    input  var logic [63:0]  m_rdata,
    input  var logic [1:0]   m_rresp,
    input  var logic         m_rlast,
    input  var logic         m_rvalid,
    output var logic         m_rready
);

  localparam logic [1:0] SIZE_BEAT  = 2'b11;  // 8 bytes, the port's width
  localparam logic [1:0] BURST_INCR = 2'b01;

  typedef enum logic [2:0] {IDLE, WRITE, WRESP, READ, RDATA, DONE} state_e;
  state_e state;

  logic abandoned, line, half;  // `half`: the word's half of its beat
  logic still_asked;
  assign still_asked = mem_req && !abandoned;

  // The request, taken whole in IDLE, and the transaction made of it: one or
  // two bursts, `split`, at `addr0` and `addr1` of `len0` and `len1` beats
  // less one; `ai` the next address to put out, `wi` the next write beat,
  // and `bi` the bursts answered.  **WHAT A TRANSACTION IS, IS WORKED OUT
  // FROM THE REQUEST ONCE IT IS HELD**, never from the request's own wires:
  // they are the uncached requester's where the memory port lets it
  // through, and its bridge has a tick of its own already.
  logic [31:0] a_q;               // the byte address
  logic [2:0]  beats_q;
  logic        wide_q;
  logic [WORD_BITS-1:0] wd_q;
  logic        split;
  logic [31:0] addr0, addr1;
  logic [3:0]  len0, len1;
  logic        ai, wi, bi;
  logic        wtwo;              // a write of two beats
  logic [63:0] wbeat0, wbeat1;
  logic [7:0]  wstrb0, wstrb1;
  logic [2:0]  beat;              // the read beat next to come

  assign m_awsize  = SIZE_BEAT;
  assign m_awburst = BURST_INCR;
  assign m_arsize  = SIZE_BEAT;
  assign m_arburst = BURST_INCR;
  assign m_awaddr  = ai ? addr1 : addr0;
  assign m_awlen   = ai ? len1 : len0;
  assign m_araddr  = ai ? addr1 : addr0;
  assign m_arlen   = ai ? len1 : len0;
  assign m_wdata   = wi ? wbeat1 : wbeat0;
  assign m_wstrb   = wi ? wstrb1 : wstrb0;
  // Each burst's last beat: the second of two in one burst, and each of a
  // split write's.
  assign m_wlast   = wi || !wtwo || split;

  // Every address of the transaction taken, and every write beat; and the
  // last of each taken at this edge.
  logic a_out, w_out;
  logic aw_last_take, w_last_take;
  assign aw_last_take = m_awvalid && m_awready && (!split || ai);
  assign w_last_take  = m_wvalid && m_wready && (!wtwo || wi);
  assign m_awvalid = (state == WRITE) && !a_out;
  assign m_wvalid  = (state == WRITE) && !w_out;
  assign m_bready  = (state == WRESP) || (state == WRITE && split && !bi);
  assign m_arvalid = (state == READ) && !a_out;
  // A split line's first beats may come while its second address is still
  // waiting to be taken.
  assign m_rready  = (state == RDATA) || (state == READ && ai);
  assign mem_done  = (state == DONE);

  // The 4 KiB rule, from the request's own byte address.
  logic [12:0] line_end;          // where a line's last byte ends, in its page
  logic [3:0]  first_beats;       // a split line's beats before the boundary
  logic [7:0]  wide_off;          // the word's byte in its first beat
  logic [127:0] wide_data;
  logic [15:0] wide_strb;
  logic        wide, wide_two, wide_cross;
  assign line_end    = {1'b0, a_q[11:0]} + {7'd0, beats_q, 3'b000};
  assign first_beats = 4'((13'h1000 - {1'b0, a_q[11:0]}) >> 3);
  assign wide_off    = {5'd0, a_q[2:0]};
  assign wide_data   = 128'(wd_q) << (wide_off << 3);
  assign wide_strb   = 16'h001F << wide_off;
  assign wide        = WIDE && wide_q;
  assign wide_two    = a_q[2:0] > 3'd3;
  assign wide_cross  = wide_two && (a_q[11:3] == 9'h1FF);

  // A line of revision 12 is 16 bytes at a 16-byte boundary; revision 13's
  // start on an 8-byte one, and one that runs over a 4 KiB boundary is two
  // bursts.  A five-byte word: a second beat when it runs past the first,
  // and a second burst when that beat starts a 4 KiB page.
  always_comb begin
    addr0 = {a_q[31:3], 3'b000};
    addr1 = {a_q[31:3], 3'b000} + 32'd8;
    len0  = 4'd0;
    len1  = 4'd0;
    split = 1'b0;
    wtwo  = 1'b0;
    if (line) begin
      if (!WIDE) addr0 = {a_q[31:4], 4'b0000};
      if (WIDE && line_end > 13'h1000) begin
        split = 1'b1;
        len0  = first_beats - 4'd1;
        len1  = 4'(beats_q) - first_beats - 4'd1;
        addr1 = {a_q[31:12], 12'h000} + 32'h1000;
      end else begin
        len0  = 4'(beats_q) - 4'd1;
      end
    end else if (wide) begin
      wtwo  = wide_two;
      split = wide_cross;
      len0  = (wide_two && !wide_cross) ? 4'd1 : 4'd0;
    end
  end
  assign wbeat0 = wide ? wide_data[63:0] : {wd_q[31:0], wd_q[31:0]};
  assign wbeat1 = wide_data[127:64];
  assign wstrb0 = wide ? wide_strb[7:0] : a_q[2] ? 8'hF0 : 8'h0F;
  assign wstrb1 = wide_strb[15:8];
  assign half   = a_q[2];

  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= IDLE;
      abandoned <= 1'b0;
      line      <= 1'b0;
      a_q       <= 32'd0;
      beats_q   <= 3'd0;
      wide_q    <= 1'b0;
      wd_q      <= '0;
      ai        <= 1'b0;
      wi        <= 1'b0;
      bi        <= 1'b0;
      beat      <= 3'd0;
      a_out     <= 1'b0;
      w_out     <= 1'b0;
      mem_rdata <= 32'd0;
      mem_rline <= '0;
      mem_error <= 1'b0;
    end else begin
      unique case (state)
        IDLE: begin
          if (mem_req) begin
            mem_error <= 1'b0;
            abandoned <= 1'b0;
            beat      <= 3'd0;
            ai        <= 1'b0;
            wi        <= 1'b0;
            bi        <= 1'b0;
            a_out     <= 1'b0;
            w_out     <= 1'b0;
            a_q       <= mem_addr;
            beats_q   <= mem_beats;
            wide_q    <= mem_write && mem_wide;
            wd_q      <= mem_wdata;
            line      <= !mem_write && mem_line;
            state     <= mem_write ? WRITE : READ;
          end
        end

        WRITE: begin
          // The addresses in order, the second after the first is taken;
          // the beats in order, the first burst's before the second's.
          if (m_awvalid && m_awready) begin
            if (aw_last_take) a_out <= 1'b1;
            else ai <= 1'b1;
          end
          if (m_wvalid && m_wready) begin
            if (w_last_take) w_out <= 1'b1;
            else wi <= 1'b1;
          end
          // A split write's first B, while its second address waits.
          if (m_bvalid && m_bready) begin
            if (m_bresp[1]) mem_error <= 1'b1;
            bi <= 1'b1;
          end
          if ((a_out || aw_last_take) && (w_out || w_last_take)) state <= WRESP;
        end

        WRESP: begin
          if (m_bvalid) begin
            if (m_bresp[1]) mem_error <= 1'b1;
            if (split && !bi) begin
              bi <= 1'b1;
            end else if (still_asked) begin
              state <= DONE;
            end else begin
              state <= IDLE;
            end
          end
        end

        READ: begin
          if (m_arready) begin
            if (split && !ai) begin
              ai <= 1'b1;
            end else begin
              a_out <= 1'b1;
              state <= RDATA;
            end
          end
        end

        default: ;
      endcase

      // The read beats, which may start while a split line's second address
      // waits, and the answer on the last beat of the last burst.
      if (m_rready && m_rvalid) begin
        if (m_rresp[1]) mem_error <= 1'b1;
        if (line) begin
          mem_rline[64*beat +: 64] <= m_rdata;
        end else begin
          mem_rdata <= half ? m_rdata[63:32] : m_rdata[31:0];
        end
        beat <= beat + 3'd1;
        // A port that ends the burst early is answered as it says, and the
        // words not sent are what the register held.
        if (m_rlast) begin
          if (split && !bi) bi <= 1'b1;
          else if (state == RDATA) state <= still_asked ? DONE : IDLE;
        end
      end

      if (state == DONE && !mem_req) state <= IDLE;

      if (!mem_req && (state == WRITE || state == WRESP || state == READ || state == RDATA))
        abandoned <= 1'b1;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{m_bresp[0], m_rresp[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
