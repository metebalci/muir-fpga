// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A 64-bit read master with several bursts in flight on a 128-bit port: the
// display output's reads on the Kria KR260's `S_AXI_HP3_FPD`.
//
// **THE PORT IS 128 BITS WIDE AND THE DISPLAY READS 64**, for the reason
// `cadr_axi_widen128.sv` gives about the memory port: the part comes up at
// 128 and the fabric is built for what it comes up at.
// `rtl/plumbing/cadr_display_out.sv` keeps its 64-bit beats; this puts its
// bursts on the wider port as narrow bursts, by AXI's own rules, as
// `cadr_axi_burst128.sv` does for the pack side: beat k of a burst at A is
// at A + 8k and lives in the half of the 128-bit beat that bit 3 of that
// address selects, so the halves alternate beat by beat from bit 3 of A.
//
// **WHAT `cadr_axi_burst128.sv` CANNOT DO, AND WHY THIS IS A MODULE OF ITS
// OWN.**  That one reads the half from the channel's address, which its
// master holds until the burst's last beat.  The display does not: it has up
// to `OUTSTANDING` reads out at once, and its address has moved on long
// before the first one is answered.  So the half each burst starts in is
// remembered here, in the order the addresses were taken, and the data
// channel takes them in that order: one ID, so the port answers in order.
// The queue is `DEPTH` deep and the address channel is held while it is full,
// so a master with more in flight than that is slowed, never misread.
//
// AND THE HANDSHAKES PASS THROUGH but for that hold: every valid, ready, last
// and response is the master's or the port's.  The length widens from AXI3's
// four bits to AXI4's eight with zeros, which means the same length.  Nothing
// here writes.

`default_nettype none

module cadr_axi_rd128 #(
    parameter int unsigned DEPTH = 8
) (
    input  var logic         clk,
    input  var logic         rst,       // the port's reset: the queue empty
    // The 64-bit master.
    input  var logic [31:0]  s_araddr,
    input  var logic [3:0]   s_arlen,
    input  var logic [1:0]   s_arsize,
    input  var logic         s_arvalid,
    output var logic         s_arready,
    output var logic [63:0]  s_rdata,
    output var logic         s_rvalid,
    input  var logic         s_rready,
    output var logic         s_rlast,
    // The 128-bit port.
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic [2:0]   m_arsize,
    output var logic         m_arvalid,
    input  var logic         m_arready,
    input  var logic [127:0] m_rdata,
    input  var logic         m_rvalid,
    output var logic         m_rready,
    input  var logic         m_rlast
);

  localparam int unsigned AW = $clog2(DEPTH);

  logic [DEPTH-1:0] half_q;          // bit 3 of each burst's address, in order
  logic [AW-1:0]    wp, rp;
  logic [AW:0]      count;
  logic             parity;          // beats of the oldest burst taken, mod 2

  wire full  = count == (AW+1)'(DEPTH);
  wire take  = s_arvalid && m_arready && !full;
  wire beat  = m_rvalid && s_rready;
  wire done  = beat && m_rlast;

  assign m_araddr  = s_araddr;
  assign m_arlen   = {4'd0, s_arlen};
  assign m_arsize  = {1'b0, s_arsize};
  assign m_arvalid = s_arvalid && !full;
  assign s_arready = m_arready && !full;

  wire half = half_q[rp] ^ parity;
  assign s_rdata  = half ? m_rdata[127:64] : m_rdata[63:0];
  assign s_rvalid = m_rvalid;
  assign s_rlast  = m_rlast;
  assign m_rready = s_rready;

  always_ff @(posedge clk) begin
    if (rst) begin
      wp     <= '0;
      rp     <= '0;
      count  <= '0;
      parity <= 1'b0;
    end else begin
      if (take) begin
        half_q[wp] <= s_araddr[3];
        wp         <= (wp == AW'(DEPTH - 1)) ? '0 : wp + AW'(1);
      end
      if (done) begin
        rp     <= (rp == AW'(DEPTH - 1)) ? '0 : rp + AW'(1);
        parity <= 1'b0;
      end else if (beat) begin
        parity <= !parity;
      end
      count <= count + (AW+1)'(take) - (AW+1)'(done);
    end
  end

endmodule

`default_nettype wire
