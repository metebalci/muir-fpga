// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's 64-bit memory master on a 128-bit port: `quux_axi_master.sv` on the
// Kria KR260's `S_AXI_HP0_FPD`.
//
// **THE PORT IS 128 BITS WIDE AND QUUX'S MASTER IS 64**, for the reason
// `cadr_axi_widen128.sv` gives: the part comes up at 128 and the fabric is
// built for what it comes up at.  `quux_axi_master.sv` keeps its 64-bit
// beats, its packed storage and its 4 KiB splits, which its own check holds;
// this puts its bursts on the wider port.
//
// **AS NARROW BURSTS, BY AXI'S OWN RULES**, as `cadr_axi_burst128.sv` puts
// the pack side's: each burst goes out unchanged in length with `AxSIZE`
// eight bytes, so beat k of a burst at address A is at A + 8k and lives in
// the half of the 128-bit beat that bit 3 of that address selects.  On a
// write the doubleword goes into both halves and the strobes open that half;
// on a read the doubleword comes out of it.
//
// **WHICH BURST A BEAT BELONGS TO IS QUEUED, NOT READ OFF THE CHANNEL**,
// and this is where it differs from `cadr_axi_burst128.sv`.  QUUX's master
// does not hold an address on its channel until the burst's last beat: a
// line split at 4 KiB puts its second read address out as soon as the first
// is taken, while the first burst's beats are still to come, and a split
// write puts its second write address out while the first burst's beat may
// still wait.  So each channel keeps the start addresses of the bursts it
// has taken and not finished, two deep, which is all QUUX's master ever has
// in flight in one direction: an address is queued when it is taken, the
// burst's beats count their half from the head of the queue, and the head
// goes when the burst's last beat does.
//
// **AND NO WRITE BEAT GOES BEFORE ITS ADDRESS**: the master may offer a
// beat before the address is taken, and its own check lets it; here the beat
// waits until there is an address in the queue for it.  A port may take a
// write's data before its address, but nothing obliges it to, and a beat
// whose half is not yet known cannot be put in a half.  A third address
// waits too, with two bursts still owed their beats, which QUUX's master
// never asks for.
//
// The handshakes pass through but for those two holds: every valid, ready,
// last and response is the master's or the port's.  The length widens from
// AXI3's four bits to AXI4's eight with zeros, which means the same length.
// `tb/quux_axi_narrow128_tb.cpp` holds the pair, QUUX's master behind this,
// against a port that keeps AXI's narrow rule, beat by beat.

`default_nettype none

module quux_axi_narrow128 (
    input  var logic         clk,
    // The port's own reset: the queues start empty on the first burst the
    // port is live for.
    input  var logic         rst,

    // The master's side, as `quux_axi_master.sv` drives it.
    input  var logic [31:0]  s_awaddr,
    input  var logic [3:0]   s_awlen,
    input  var logic [1:0]   s_awsize,
    input  var logic         s_awvalid,
    output var logic         s_awready,
    input  var logic [63:0]  s_wdata,
    input  var logic [7:0]   s_wstrb,
    input  var logic         s_wlast,
    input  var logic         s_wvalid,
    output var logic         s_wready,
    input  var logic [31:0]  s_araddr,
    input  var logic [3:0]   s_arlen,
    input  var logic [1:0]   s_arsize,
    input  var logic         s_arvalid,
    output var logic         s_arready,
    output var logic [63:0]  s_rdata,
    input  var logic         s_rready,

    // The port's side, 128 bits wide, AXI4.
    output var logic [31:0]  m_awaddr,
    output var logic [7:0]   m_awlen,
    output var logic [2:0]   m_awsize,
    output var logic         m_awvalid,
    input  var logic         m_awready,
    output var logic [127:0] m_wdata,
    output var logic [15:0]  m_wstrb,
    output var logic         m_wlast,
    output var logic         m_wvalid,
    input  var logic         m_wready,
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic [2:0]   m_arsize,
    output var logic         m_arvalid,
    input  var logic         m_arready,
    input  var logic [127:0] m_rdata,
    input  var logic         m_rlast,
    input  var logic         m_rvalid
);

  // ---------------------------------------------------------------- writes
  //
  // The start addresses' bit 3 is all a half needs, so that is all a queue
  // keeps: bit 3 of the burst's address, two deep.
  logic [1:0] aw_q;              // bit 3 of each queued burst's address
  logic [1:0] aw_n;              // how many are queued, 0 to 2
  logic       w_odd;             // the beats of the head burst so far, odd
  logic       aw_take, w_take, w_last_take;

  assign m_awaddr  = s_awaddr;
  assign m_awlen   = {4'd0, s_awlen};
  assign m_awsize  = {1'b0, s_awsize};
  assign m_awvalid = s_awvalid && (aw_n != 2'd2);
  assign s_awready = m_awready && (aw_n != 2'd2);
  assign aw_take   = m_awvalid && m_awready;

  assign m_wvalid  = s_wvalid && (aw_n != 2'd0);
  assign s_wready  = m_wready && (aw_n != 2'd0);
  assign m_wlast   = s_wlast;
  assign w_take    = m_wvalid && m_wready;
  assign w_last_take = w_take && s_wlast;

  logic w_high;
  assign w_high  = aw_q[0] ^ w_odd;
  assign m_wdata = {s_wdata, s_wdata};
  assign m_wstrb = w_high ? {s_wstrb, 8'h00} : {8'h00, s_wstrb};

  always_ff @(posedge clk) begin
    if (rst) begin
      aw_q  <= 2'b00;
      aw_n  <= 2'd0;
      w_odd <= 1'b0;
    end else begin
      // The queue: pushed at the tail when an address is taken, the head
      // gone when its burst's last beat is.  Both in one tick is a burst
      // finishing as the next one's address is taken.
      unique case ({aw_take, w_last_take})
        2'b10: begin
          if (aw_n == 2'd0) aw_q[0] <= s_awaddr[3];
          else aw_q[1] <= s_awaddr[3];
          aw_n <= aw_n + 2'd1;
        end
        2'b01: begin
          aw_q[0] <= aw_q[1];
          aw_n <= aw_n - 2'd1;
        end
        2'b11: begin
          // The head goes and the new one joins: with one queued it becomes
          // the head, with two it follows the one that was second.
          if (aw_n == 2'd1) aw_q[0] <= s_awaddr[3];
          else begin
            aw_q[0] <= aw_q[1];
            aw_q[1] <= s_awaddr[3];
          end
        end
        default: ;
      endcase
      if (w_take) w_odd <= s_wlast ? 1'b0 : !w_odd;
    end
  end

  // ----------------------------------------------------------------- reads
  logic [1:0] ar_q;
  logic [1:0] ar_n;
  logic       r_odd;
  logic       ar_take, r_take, r_last_take;

  assign m_araddr  = s_araddr;
  assign m_arlen   = {4'd0, s_arlen};
  assign m_arsize  = {1'b0, s_arsize};
  assign m_arvalid = s_arvalid && (ar_n != 2'd2);
  assign s_arready = m_arready && (ar_n != 2'd2);
  assign ar_take   = m_arvalid && m_arready;
  assign r_take    = m_rvalid && s_rready;
  assign r_last_take = r_take && m_rlast;

  logic r_high;
  assign r_high  = ar_q[0] ^ r_odd;
  assign s_rdata = r_high ? m_rdata[127:64] : m_rdata[63:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      ar_q  <= 2'b00;
      ar_n  <= 2'd0;
      r_odd <= 1'b0;
    end else begin
      unique case ({ar_take, r_last_take})
        2'b10: begin
          if (ar_n == 2'd0) ar_q[0] <= s_araddr[3];
          else ar_q[1] <= s_araddr[3];
          ar_n <= ar_n + 2'd1;
        end
        2'b01: begin
          ar_q[0] <= ar_q[1];
          ar_n <= ar_n - 2'd1;
        end
        2'b11: begin
          if (ar_n == 2'd1) ar_q[0] <= s_araddr[3];
          else begin
            ar_q[0] <= ar_q[1];
            ar_q[1] <= s_araddr[3];
          end
        end
        default: ;
      endcase
      if (r_take) r_odd <= m_rlast ? 1'b0 : !r_odd;
    end
  end

endmodule

`default_nettype wire
