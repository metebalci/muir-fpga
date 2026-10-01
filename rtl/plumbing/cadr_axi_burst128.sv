// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A 64-bit burst master on a 128-bit port: the disk pack's bursts on the
// Kria KR260's `S_AXI_HP2_FPD`.
//
// **THE PORT IS 128 BITS WIDE AND THE PACK SIDE'S MASTER IS 64**, for the
// reason `cadr_axi_widen128.sv` gives about the memory port: the part comes
// up at 128 and the fabric is built for what it comes up at.
// `rtl/plumbing/cadr_disk_pack.sv` keeps its 64-bit beats, its record layout
// and its checks; this puts its bursts on the wider port.
//
// **AS NARROW BURSTS, BY AXI'S OWN RULES.**  Each burst goes out unchanged
// in length with `AxSIZE` eight bytes, so beat k of a burst at address A is
// at A + 8k and lives in the half of the 128-bit beat that bit 3 of that
// address selects: the low half when it is clear, the high half when it is
// set.  The two halves therefore alternate beat by beat, starting from bit 3
// of the burst's address.  On a write the doubleword goes into both halves
// and the strobes open the half its address selects; on a read the doubleword
// comes out of that half.  UG1085's AFI takes narrow commands ("all other
// command-types are expanded", chapter 35), and with `AxCACHE[1]` clear it
// does not try to upsize them.
//
// **WHICH HALF A BEAT IS IN IS COUNTED, AND THE COUNT RESTS ON ONE PROPERTY
// OF THE MASTER**: it holds its address on the channel from the address
// handshake to the burst's last beat, and has one burst in flight at a time
// in each direction.  `cadr_disk_pack.sv` does both --- `m_awaddr` and
// `m_araddr` are one register, `burst_addr`, that moves only once a burst's
// last beat has gone, and the next burst's address goes out only after that.
// So the half is bit 3 of the channel's address now, flipped once for every
// beat of the burst already taken; each count goes back to zero on its
// burst's last beat.  `tb/cadr_axi_burst128_tb.cpp` holds it with bursts
// starting in either half and of odd and even lengths.
//
// AND THE HANDSHAKES PASS THROUGH: every valid, ready, last and response is
// the master's or the port's unchanged.  The length widens from AXI3's four
// bits to AXI4's eight with zeros, which means the same length.

`default_nettype none

module cadr_axi_burst128 (
    input  var logic         clk,
    // The port's own reset: the counts must start from zero on the first
    // burst the port is live for.
    input  var logic         rst,

    input  var logic [31:0]  s_awaddr,
    input  var logic [3:0]   s_awlen,
    input  var logic [1:0]   s_awsize,
    input  var logic [63:0]  s_wdata,
    input  var logic [7:0]   s_wstrb,
    input  var logic         s_wlast,
    input  var logic         s_wvalid,
    input  var logic         s_wready,   // the port's WREADY, as the master sees it
    input  var logic [31:0]  s_araddr,
    input  var logic [3:0]   s_arlen,
    input  var logic [1:0]   s_arsize,
    output var logic [63:0]  s_rdata,
    input  var logic         s_rlast,
    input  var logic         s_rvalid,   // the port's RVALID
    input  var logic         s_rready,   // the master's RREADY

    output var logic [31:0]  m_awaddr,
    output var logic [7:0]   m_awlen,
    output var logic [2:0]   m_awsize,
    output var logic [127:0] m_wdata,
    output var logic [15:0]  m_wstrb,
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic [2:0]   m_arsize,
    input  var logic [127:0] m_rdata
);

  assign m_awaddr = s_awaddr;
  assign m_araddr = s_araddr;
  assign m_awlen  = {4'd0, s_awlen};
  assign m_arlen  = {4'd0, s_arlen};
  // The master's own size: eight bytes, AXI's code 3, and narrower than the
  // port's sixteen.
  assign m_awsize = {1'b0, s_awsize};
  assign m_arsize = {1'b0, s_arsize};

  // Odd beats of the burst so far, in each direction.
  logic w_odd, r_odd;
  always_ff @(posedge clk) begin
    if (rst) begin
      w_odd <= 1'b0;
      r_odd <= 1'b0;
    end else begin
      if (s_wvalid && s_wready) w_odd <= s_wlast ? 1'b0 : !w_odd;
      if (s_rvalid && s_rready) r_odd <= s_rlast ? 1'b0 : !r_odd;
    end
  end

  logic w_high, r_high;
  assign w_high = s_awaddr[3] ^ w_odd;
  assign r_high = s_araddr[3] ^ r_odd;

  assign m_wdata = {s_wdata, s_wdata};
  assign m_wstrb = w_high ? {s_wstrb, 8'h00} : {8'h00, s_wstrb};
  assign s_rdata = r_high ? m_rdata[127:64] : m_rdata[63:0];

endmodule

`default_nettype wire
