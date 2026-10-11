// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 15's memory master behind `rtl/plumbing/quux_axi_narrow128.sv`,
// wired as `boards/kria-kr260/quux15_kr260.sv` wires them: the port's side of
// `rtl/plumbing/quux15_axi_master.sv` (its line reads and word writes) and
// the 128-bit port's side of the narrowing, every handshake passing between
// the two.  `tb/quux15_axi_narrow128_tb.cpp` drives it.

`default_nettype none

module quux15_axi_narrow128_harness (
    input  var logic         clk,
    input  var logic         rst,
    input  var logic         ar_req,
    input  var logic [25:0]  ar_line,
    output var logic         ar_taken,
    output var logic         rd_last,
    output var logic [319:0] rd_data,
    input  var logic         w_req,
    input  var logic [28:0]  w_bus,
    input  var logic [39:0]  w_word,
    input  var logic [3:0]   w_id,
    output var logic         w_free,
    output var logic         w_taken,
    output var logic         b_done,
    output var logic [3:0]   b_id,
    output var logic         b_err,
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
    input  var logic [1:0]   m_bresp,
    input  var logic         m_bvalid,
    output var logic         m_bready,
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic [2:0]   m_arsize,
    output var logic         m_arvalid,
    input  var logic         m_arready,
    input  var logic [127:0] m_rdata,
    input  var logic         m_rlast,
    input  var logic         m_rvalid,
    output var logic         m_rready
);

  logic [31:0] awaddr, araddr;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [1:0]  awburst, arburst;
  logic [3:0]  awid;
  logic        awvalid, awready, wvalid, wready, wlast, arvalid, arready;
  logic [63:0] wdata, rdata;
  logic [7:0]  wstrb;
  logic        one_write_id;
  logic [3:0]  read_clocks, write_clocks;

  quux15_axi_master #(.MAIN_BASE(32'h5A00_0000), .DISPLAY_BASE(32'h6400_0000)) u_master (
      .clk(clk), .rst(rst),
      .ar_req(ar_req), .ar_line(ar_line), .ar_taken(ar_taken), .rd_last(rd_last), .rd_data(rd_data),
      .w_req(w_req), .w_bus(w_bus), .w_word(w_word), .w_id(w_id), .w_free(w_free),
      .w_taken(w_taken), .b_done(b_done), .b_id(b_id), .b_err(b_err),
      .one_write_id(one_write_id), .read_fabric_clocks(read_clocks),
      .write_fabric_clocks(write_clocks),
      .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
      .m_bid(4'd0), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata), .m_rresp(2'b00), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
      .m_rready(m_rready)
  );

  // The machine's bursts are at most five beats of eight bytes: AXI3's four
  // bits of length and two of size hold them, as the board passes them.
  quux_axi_narrow128 u_narrow (
      .clk(clk), .rst(rst),
      .s_awaddr(awaddr), .s_awlen(awlen[3:0]), .s_awsize(awsize[1:0]),
      .s_awvalid(awvalid), .s_awready(awready),
      .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
      .s_wvalid(wvalid), .s_wready(wready),
      .s_araddr(araddr), .s_arlen(arlen[3:0]), .s_arsize(arsize[1:0]),
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

  logic unused;
  assign unused = ^{awid, awlen[7:4], arlen[7:4], awsize[2], arsize[2], awburst, arburst,
                    one_write_id, read_clocks, write_clocks};

endmodule

`default_nettype wire
