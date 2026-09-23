// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The DDR bridge and the AXI adapter behind it, joined as every board joins
// them, with the AXI slave left to the testbench.  `tb/cadr_xbus_axi_tb.cpp`
// says what this is for: a bus cycle the NXM timer ends while the slave has
// not answered.

`default_nettype none

module cadr_xbus_axi_harness (
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        dev_rq,
    input  var logic        dev_write,
    input  var logic [21:0] phys,
    input  var logic [31:0] wdata,
    output var logic        dev_ack,
    output var logic [31:0] rdata,
    output var logic [31:0] awaddr,
    output var logic        awvalid,
    input  var logic        awready,
    output var logic [31:0] wdata_o,
    output var logic        wvalid,
    input  var logic        wready,
    input  var logic        bvalid,
    output var logic        bready,
    output var logic [31:0] araddr,
    output var logic        arvalid,
    input  var logic        arready,
    input  var logic [31:0] rdata_i,
    input  var logic        rvalid,
    output var logic        rready
);
  logic        mem_req, mem_write, mem_done, mem_error;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [1:0]  awburst, arburst;
  logic [3:0]  wstrb;
  logic        wlast;

  cadr_xbus_ddr u_bridge (
      .clk(clk), .rst(rst), .sel(1'b1), .display(1'b0), .display_color(1'b0),
      .dev_rq(dev_rq), .dev_write(dev_write), .phys(phys), .wdata(wdata),
      .dev_ack(dev_ack), .rdata(rdata),
      .mem_req(mem_req), .mem_write(mem_write), .mem_addr(mem_addr),
      .mem_wdata(mem_wdata), .mem_done(mem_done), .mem_rdata(mem_rdata));

  cadr_axi_master u_axi (
      .clk(clk), .rst(rst),
      .mem_req(mem_req), .mem_write(mem_write), .mem_addr(mem_addr),
      .mem_wdata(mem_wdata), .mem_done(mem_done), .mem_rdata(mem_rdata),
      .mem_error(mem_error),
      .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata_o), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bresp(2'b00), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
      .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
      .m_axi_arburst(arburst), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rdata(rdata_i), .m_axi_rresp(2'b00), .m_axi_rlast(1'b1),
      .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  // The burst shape is `axi_master.pass`'s to hold, and the error path too.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{awlen, arlen, awsize, arsize, awburst, arburst, wstrb, wlast, mem_error};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
