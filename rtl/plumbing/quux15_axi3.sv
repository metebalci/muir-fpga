// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S MEMORY MASTER ON A ZYNQ-7000 HIGH-PERFORMANCE PORT**:
// `quux15_axi_master.sv`, an AXI4 master of 64 bits, onto `S_AXI_HP0` of the
// Arty Z7-20's processing system, which is AXI3 at the same 64 bits
// (`boards/arty-z7-20/cadr_ps7.sv`).  The width is the port's, so nothing is
// narrowed or widened, as `quux_axi_narrow128.sv` must on the Kria KR260; what
// differs is the protocol's fields:
//
//   - **THE LENGTH, FOUR BITS FOR EIGHT.**  The master's bursts are at most
//     five beats (a line, `quux15_axi_master.sv`'s header), so `AxLEN<7:4>`
//     is always zero and the low four bits are the same length in AXI3.
//   - **THE SIZE, TWO BITS FOR THREE.**  Every beat is eight bytes, `AxSIZE`
//     3, which AXI3's two bits hold.
//   - **THE IDS ARE THE PORT'S ZERO.**  The wrapper ties `AWID`, `WID` and
//     `ARID` to zero (`cadr_ps7.sv`), which is the master's one write ID
//     (A15b.5, `ONE_WRITE_ID`): every write carries ID 0, so each burst's
//     `WID` is its `AWID` and the responses come in order, one a burst.  The
//     master's `BID` is that zero.
//
// **A PORT MAY TAKE A WRITE'S DATA BEFORE ITS ADDRESS**, and the HP port does
// either; nothing here holds a beat back, as the 128-bit narrowing does.  The
// master offers the two each on its own and remembers which was taken
// (`hd_aw_done`, `hd_w_done`), so `tb/quux15_axi3_tb.cpp` holds the pair, as
// `boards/arty-z7-20/quux15_arty.sv` builds it, against a port that takes the
// address first, one that takes the beat first, and one whose every ready is
// its own.  Every valid, ready, last, response and data bit passes through.

`default_nettype none

module quux15_axi3 (
    // The master's side, AXI4 (`quux15_axi_master.sv`).
    input  var logic [31:0] s_awaddr,
    input  var logic [7:0]  s_awlen,
    input  var logic [2:0]  s_awsize,
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
    input  var logic [7:0]  s_arlen,
    input  var logic [2:0]  s_arsize,
    input  var logic [1:0]  s_arburst,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [63:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // The port's side, AXI3 (`cadr_ps7.sv`'s `hp0_*`).
    output var logic [31:0] m_awaddr,
    output var logic [3:0]  m_awlen,
    output var logic [1:0]  m_awsize,
    output var logic [1:0]  m_awburst,
    output var logic        m_awvalid,
    input  var logic        m_awready,
    output var logic [63:0] m_wdata,
    output var logic [7:0]  m_wstrb,
    output var logic        m_wlast,
    output var logic        m_wvalid,
    input  var logic        m_wready,
    input  var logic [1:0]  m_bresp,
    input  var logic        m_bvalid,
    output var logic        m_bready,
    output var logic [31:0] m_araddr,
    output var logic [3:0]  m_arlen,
    output var logic [1:0]  m_arsize,
    output var logic [1:0]  m_arburst,
    output var logic        m_arvalid,
    input  var logic        m_arready,
    input  var logic [63:0] m_rdata,
    input  var logic [1:0]  m_rresp,
    input  var logic        m_rlast,
    input  var logic        m_rvalid,
    output var logic        m_rready
);

  // The write address: AXI3's fields.
  assign m_awaddr  = s_awaddr;
  assign m_awlen   = s_awlen[3:0];
  assign m_awsize  = s_awsize[1:0];
  assign m_awburst = s_awburst;
  assign m_awvalid = s_awvalid;
  assign s_awready = m_awready;

  // The write data and its response, unchanged.
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign m_wlast   = s_wlast;
  assign m_wvalid  = s_wvalid;
  assign s_wready  = m_wready;
  assign s_bresp   = m_bresp;
  assign s_bvalid  = m_bvalid;
  assign m_bready  = s_bready;

  // The read address: AXI3's fields.
  assign m_araddr  = s_araddr;
  assign m_arlen   = s_arlen[3:0];
  assign m_arsize  = s_arsize[1:0];
  assign m_arburst = s_arburst;
  assign m_arvalid = s_arvalid;
  assign s_arready = m_arready;

  // The read data, unchanged.
  assign s_rdata   = m_rdata;
  assign s_rresp   = m_rresp;
  assign s_rlast   = m_rlast;
  assign s_rvalid  = m_rvalid;
  assign m_rready  = s_rready;

  // The fields' high bits, zero on every burst the master asks for; the
  // harness holds that the port's lengths are the master's.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{s_awlen[7:4], s_arlen[7:4], s_awsize[2], s_arsize[2]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
