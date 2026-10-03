// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 13's memory master behind `rtl/plumbing/quux_axi_narrow128.sv`,
// wired as `boards/kria-kr260/cadr_kr260.sv` wires them: the machine's side of
// `quux_axi_master.sv` and the 128-bit port's side of the narrowing, with
// every handshake passing between the two.  `tb/quux_axi_narrow128_tb.cpp`
// drives it.

`default_nettype none

module quux_axi_narrow128_harness (
    input  var logic         clk,
    input  var logic         rst,
    input  var logic         mem_req,
    input  var logic         mem_write,
    input  var logic         mem_line,
    input  var logic [2:0]   mem_beats,
    input  var logic         mem_wide,
    input  var logic [31:0]  mem_addr,
    input  var logic [39:0]  mem_wdata,
    output var logic         mem_done,
    output var logic [31:0]  mem_rdata,
    output var logic [319:0] mem_rline,
    output var logic         mem_error,
    output var logic [31:0]  m_awaddr,
    output var logic [7:0]   m_awlen,
    output var logic [2:0]   m_awsize,
    output var logic [1:0]   m_awburst,
    output var logic         m_awvalid,
    input  var logic         m_awready,
    output var logic [127:0] m_wdata,
    output var logic [15:0]  m_wstrb,
    output var logic         m_wlast,
    output var logic         m_wvalid,
    input  var logic         m_wready,
    input  var logic [1:0]   m_bresp,
    input  var logic         m_bvalid,
    output var logic         m_bready,
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic [2:0]   m_arsize,
    output var logic [1:0]   m_arburst,
    output var logic         m_arvalid,
    input  var logic         m_arready,
    input  var logic [127:0] m_rdata,
    input  var logic [1:0]   m_rresp,
    input  var logic         m_rlast,
    input  var logic         m_rvalid,
    output var logic         m_rready
);

  logic [31:0] awaddr, araddr;
  logic [3:0]  awlen, arlen;
  logic [1:0]  awsize, arsize;
  logic        awvalid, awready, wvalid, wready, wlast, arvalid, arready;
  logic [63:0] wdata, rdata;
  logic [7:0]  wstrb;

  quux_axi_master #(.WORD_BITS(40)) u_master (
      .clk(clk), .rst(rst),
      .mem_req(mem_req), .mem_write(mem_write), .mem_line(mem_line),
      .mem_beats(mem_beats), .mem_wide(mem_wide), .mem_addr(mem_addr),
      .mem_wdata(mem_wdata), .mem_done(mem_done), .mem_rdata(mem_rdata),
      .mem_rline(mem_rline), .mem_error(mem_error),
      .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(m_awburst),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast),
      .m_wvalid(wvalid), .m_wready(wready),
      .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(m_arburst),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
      .m_rvalid(m_rvalid), .m_rready(m_rready)
  );

  quux_axi_narrow128 u_narrow (
      .clk(clk), .rst(rst),
      .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
      .s_awvalid(awvalid), .s_awready(awready),
      .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
      .s_wvalid(wvalid), .s_wready(wready),
      .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
      .s_arvalid(arvalid), .s_arready(arready),
      .s_rdata(rdata), .s_rready(m_rready),
      .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
      .m_awvalid(m_awvalid), .m_awready(m_awready),
      .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
      .m_wvalid(m_wvalid), .m_wready(m_wready),
      .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
      .m_arvalid(m_arvalid), .m_arready(m_arready),
      .m_rdata(m_rdata), .m_rlast(m_rlast), .m_rvalid(m_rvalid)
  );

endmodule

`default_nettype wire
