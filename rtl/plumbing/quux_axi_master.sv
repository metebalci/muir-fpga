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
// A line never crosses a 4 KB boundary, being 16 bytes at a 16-byte one, and
// every transfer is the port's full width: the bridge refuses a narrow one,
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
// must not be taken for the next request's.  One transaction at a time.

`default_nettype none

module quux_axi_master (
    input  var logic         clk,
    input  var logic         rst,

    input  var logic         mem_req,
    input  var logic         mem_write,
    input  var logic         mem_line,    // a read of the line, four words
    input  var logic [31:0]  mem_addr,    // byte address, word-aligned
    input  var logic [31:0]  mem_wdata,
    output var logic         mem_done,
    output var logic [31:0]  mem_rdata,
    output var logic [127:0] mem_rline,
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

  logic aw_sent, w_sent, abandoned, line, half, beat;
  logic still_asked;
  assign still_asked = mem_req && !abandoned;

  assign m_awlen   = 4'd0;
  assign m_awsize  = SIZE_BEAT;
  assign m_awburst = BURST_INCR;
  assign m_arsize  = SIZE_BEAT;
  assign m_arburst = BURST_INCR;
  assign m_arlen   = line ? 4'd1 : 4'd0;
  assign m_wlast   = 1'b1;

  assign m_bready  = (state == WRESP);
  assign m_rready  = (state == RDATA);
  assign m_awvalid = (state == WRITE) && !aw_sent;
  assign m_wvalid  = (state == WRITE) && !w_sent;
  assign m_arvalid = (state == READ);
  assign mem_done  = (state == DONE);

  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= IDLE;
      aw_sent   <= 1'b0;
      w_sent    <= 1'b0;
      abandoned <= 1'b0;
      line      <= 1'b0;
      half      <= 1'b0;
      beat      <= 1'b0;
      mem_rdata <= 32'd0;
      mem_rline <= 128'd0;
      mem_error <= 1'b0;
      m_awaddr  <= 32'd0;
      m_araddr  <= 32'd0;
      m_wdata   <= 64'd0;
      m_wstrb   <= 8'd0;
    end else begin
      unique case (state)
        IDLE: begin
          if (mem_req) begin
            mem_error <= 1'b0;
            abandoned <= 1'b0;
            half      <= mem_addr[2];
            beat      <= 1'b0;
            if (mem_write) begin
              line     <= 1'b0;
              m_awaddr <= {mem_addr[31:3], 3'b000};
              m_wdata  <= {mem_wdata, mem_wdata};
              m_wstrb  <= mem_addr[2] ? 8'hF0 : 8'h0F;
              aw_sent  <= 1'b0;
              w_sent   <= 1'b0;
              state    <= WRITE;
            end else begin
              line     <= mem_line;
              m_araddr <= mem_line ? {mem_addr[31:4], 4'b0000} : {mem_addr[31:3], 3'b000};
              state    <= READ;
            end
          end
        end

        WRITE: begin
          if (m_awvalid && m_awready) aw_sent <= 1'b1;
          if (m_wvalid && m_wready) w_sent <= 1'b1;
          if ((aw_sent || (m_awvalid && m_awready)) && (w_sent || (m_wvalid && m_wready)))
            state <= WRESP;
        end

        WRESP: begin
          if (m_bvalid) begin
            if (still_asked) begin
              if (m_bresp[1]) mem_error <= 1'b1;
              state <= DONE;
            end else begin
              state <= IDLE;
            end
          end
        end

        READ: begin
          if (m_arready) state <= RDATA;
        end

        RDATA: begin
          if (m_rvalid) begin
            if (m_rresp[1]) mem_error <= 1'b1;
            if (line) begin
              if (beat) mem_rline[127:64] <= m_rdata;
              else      mem_rline[63:0]   <= m_rdata;
            end else begin
              mem_rdata <= half ? m_rdata[63:32] : m_rdata[31:0];
            end
            beat <= 1'b1;
            // The answer is the last beat's; a port that ends the burst
            // early is answered as it says, and the words not sent are
            // what the register held.
            if (m_rlast) state <= still_asked ? DONE : IDLE;
          end
        end

        DONE: begin
          if (!mem_req) state <= IDLE;
        end

        default: state <= IDLE;
      endcase

      if (!mem_req && (state == WRITE || state == WRESP || state == READ || state == RDATA))
        abandoned <= 1'b1;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{m_bresp[0], m_rresp[0], mem_addr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
