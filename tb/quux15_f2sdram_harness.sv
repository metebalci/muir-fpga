// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 15's memory master in front of the DE25-Nano's memory port,
// wired as `boards/de25-nano/quux15_de25.sv` wires them: the port's side of
// `rtl/plumbing/quux15_axi_master.sv` (its line reads and word writes) at
// the DE25-Nano's bases, through `rtl/plumbing/quux15_f2sdram_port.sv` onto
// the FPGA-to-SDRAM bridge, with the processor's own side brought out for
// `tb/quux15_f2sdram_tb.cpp` to be.
//
// **THE MASTER'S RESET IS THE TESTBENCH'S `mach_rst`**, given as the core
// gives its own (`quux15_core.sv`'s `rq_*`): a request drains the master
// through the port, then resets it.  The testbench plays the core's port
// side, so it plays that rule too; the port's reset of its own is the
// fabric's `rst`, as the clock's lock on the board.  The other two masters are the testbench's,
// in the AXI3 shape `cadr_disk_pack.sv` and `cadr_display_out.sv` have.
//
// In `tb/` for the reason `tb/cadr_f2sdram_harness.sv` gives.

`default_nettype none

module quux15_f2sdram_harness (
    input  var logic         clk,
    input  var logic         rst,
    input  var logic         mach_rst,
    // --- the master's port side (`quux15_port.sv`'s seam) ------------------
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
    // --- the processor's side ----------------------------------------------
    input  var logic         h2f_reset,
    input  var logic         gp_open,
    input  var logic         gp_half,
    input  var logic         warm_req_n,
    output var logic         warm_ack_n,
    output var logic [31:0]  gp_in,
    output var logic         live,
    output var logic         may_start,
    // --- the disk pack side's port ------------------------------------------
    input  var logic [31:0]  p_awaddr,
    input  var logic [3:0]   p_awlen,
    input  var logic [1:0]   p_awsize,
    input  var logic [1:0]   p_awburst,
    input  var logic         p_awvalid,
    output var logic         p_awready,
    input  var logic [63:0]  p_wdata,
    input  var logic [7:0]   p_wstrb,
    input  var logic         p_wlast,
    input  var logic         p_wvalid,
    output var logic         p_wready,
    output var logic [1:0]   p_bresp,
    output var logic         p_bvalid,
    input  var logic         p_bready,
    input  var logic [31:0]  p_araddr,
    input  var logic [3:0]   p_arlen,
    input  var logic [1:0]   p_arsize,
    input  var logic [1:0]   p_arburst,
    input  var logic         p_arvalid,
    output var logic         p_arready,
    output var logic [63:0]  p_rdata,
    output var logic [1:0]   p_rresp,
    output var logic         p_rlast,
    output var logic         p_rvalid,
    input  var logic         p_rready,
    // --- the display's port, read only --------------------------------------
    input  var logic [31:0]  d_araddr,
    input  var logic [3:0]   d_arlen,
    input  var logic [1:0]   d_arsize,
    input  var logic [1:0]   d_arburst,
    input  var logic         d_arvalid,
    output var logic         d_arready,
    output var logic [63:0]  d_rdata,
    output var logic [1:0]   d_rresp,
    output var logic         d_rlast,
    output var logic         d_rvalid,
    input  var logic         d_rready,
    // --- the bridge, which the testbench is ---------------------------------
    output var logic [4:0]   f2s_awid,
    output var logic [31:0]  f2s_awaddr,
    output var logic [7:0]   f2s_awlen,
    output var logic [2:0]   f2s_awsize,
    output var logic [1:0]   f2s_awburst,
    output var logic         f2s_awlock,
    output var logic [3:0]   f2s_awcache,
    output var logic [2:0]   f2s_awprot,
    output var logic [3:0]   f2s_awqos,
    output var logic [3:0]   f2s_awregion,
    output var logic [7:0]   f2s_awuser,
    output var logic         f2s_awvalid,
    input  var logic         f2s_awready,
    output var logic [63:0]  f2s_wdata,
    output var logic [7:0]   f2s_wstrb,
    output var logic         f2s_wlast,
    output var logic [7:0]   f2s_wuser,
    output var logic         f2s_wvalid,
    input  var logic         f2s_wready,
    input  var logic [4:0]   f2s_bid,
    input  var logic [1:0]   f2s_bresp,
    input  var logic         f2s_bvalid,
    output var logic         f2s_bready,
    output var logic [4:0]   f2s_arid,
    output var logic [31:0]  f2s_araddr,
    output var logic [7:0]   f2s_arlen,
    output var logic [2:0]   f2s_arsize,
    output var logic [1:0]   f2s_arburst,
    output var logic         f2s_arlock,
    output var logic [3:0]   f2s_arcache,
    output var logic [2:0]   f2s_arprot,
    output var logic [3:0]   f2s_arqos,
    output var logic [3:0]   f2s_arregion,
    output var logic [7:0]   f2s_aruser,
    output var logic         f2s_arvalid,
    input  var logic         f2s_arready,
    input  var logic [4:0]   f2s_rid,
    input  var logic [63:0]  f2s_rdata,
    input  var logic [1:0]   f2s_rresp,
    input  var logic         f2s_rlast,
    input  var logic         f2s_rvalid,
    output var logic         f2s_rready
);

  logic [3:0]  awid;
  logic [31:0] awaddr, araddr;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [1:0]  awburst, arburst, bresp, rresp;
  logic        awvalid, awready, wvalid, wready, wlast, arvalid, arready;
  logic        bvalid, bready, rvalid, rready, rlast;
  logic [63:0] wdata, rdata;
  logic [7:0]  wstrb;
  logic        one_write_id;
  logic [3:0]  read_clocks, write_clocks;

  // The DE25-Nano's bases (`cadr_ddr_map.sv` with its map), as the top's.
  quux15_axi_master #(.MAIN_BASE(32'hA000_0000), .DISPLAY_BASE(32'hB400_0000)) u_master (
      .clk(clk), .rst(mach_rst),
      .ar_req(ar_req), .ar_line(ar_line), .ar_taken(ar_taken), .rd_last(rd_last), .rd_data(rd_data),
      .w_req(w_req), .w_bus(w_bus), .w_word(w_word), .w_id(w_id), .w_free(w_free),
      .w_taken(w_taken), .b_done(b_done), .b_id(b_id), .b_err(b_err),
      .one_write_id(one_write_id), .read_fabric_clocks(read_clocks),
      .write_fabric_clocks(write_clocks),
      .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
      .m_bid(4'd0), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
      .m_rready(rready)
  );

  quux15_f2sdram_port u_memory (
      .clk(clk), .rst(rst), .lock_rst(rst),
      .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize), .s_awburst(awburst),
      .s_awvalid(awvalid), .s_awready(awready),
      .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
      .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
      .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
      .s_arvalid(arvalid), .s_arready(arready),
      .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
      .h2f_reset(h2f_reset), .gp_open(gp_open), .gp_half(gp_half),
      .warm_req_n(warm_req_n), .warm_ack_n(warm_ack_n),
      .gp_in(gp_in), .live(live), .may_start(may_start),
      .p_awaddr(p_awaddr), .p_awlen(p_awlen), .p_awsize(p_awsize),
      .p_awburst(p_awburst), .p_awvalid(p_awvalid), .p_awready(p_awready),
      .p_wdata(p_wdata), .p_wstrb(p_wstrb), .p_wlast(p_wlast),
      .p_wvalid(p_wvalid), .p_wready(p_wready),
      .p_bresp(p_bresp), .p_bvalid(p_bvalid), .p_bready(p_bready),
      .p_araddr(p_araddr), .p_arlen(p_arlen), .p_arsize(p_arsize),
      .p_arburst(p_arburst), .p_arvalid(p_arvalid), .p_arready(p_arready),
      .p_rdata(p_rdata), .p_rresp(p_rresp), .p_rlast(p_rlast),
      .p_rvalid(p_rvalid), .p_rready(p_rready),
      .d_araddr(d_araddr), .d_arlen(d_arlen), .d_arsize(d_arsize),
      .d_arburst(d_arburst), .d_arvalid(d_arvalid), .d_arready(d_arready),
      .d_rdata(d_rdata), .d_rresp(d_rresp), .d_rlast(d_rlast),
      .d_rvalid(d_rvalid), .d_rready(d_rready),
      .f2s_awid(f2s_awid), .f2s_awaddr(f2s_awaddr), .f2s_awlen(f2s_awlen),
      .f2s_awsize(f2s_awsize), .f2s_awburst(f2s_awburst),
      .f2s_awlock(f2s_awlock), .f2s_awcache(f2s_awcache),
      .f2s_awprot(f2s_awprot), .f2s_awqos(f2s_awqos),
      .f2s_awregion(f2s_awregion), .f2s_awuser(f2s_awuser),
      .f2s_awvalid(f2s_awvalid), .f2s_awready(f2s_awready),
      .f2s_wdata(f2s_wdata), .f2s_wstrb(f2s_wstrb), .f2s_wlast(f2s_wlast),
      .f2s_wuser(f2s_wuser), .f2s_wvalid(f2s_wvalid), .f2s_wready(f2s_wready),
      .f2s_bid(f2s_bid), .f2s_bresp(f2s_bresp), .f2s_bvalid(f2s_bvalid),
      .f2s_bready(f2s_bready),
      .f2s_arid(f2s_arid), .f2s_araddr(f2s_araddr), .f2s_arlen(f2s_arlen),
      .f2s_arsize(f2s_arsize), .f2s_arburst(f2s_arburst),
      .f2s_arlock(f2s_arlock), .f2s_arcache(f2s_arcache),
      .f2s_arprot(f2s_arprot), .f2s_arqos(f2s_arqos),
      .f2s_arregion(f2s_arregion), .f2s_aruser(f2s_aruser),
      .f2s_arvalid(f2s_arvalid), .f2s_arready(f2s_arready),
      .f2s_rid(f2s_rid), .f2s_rdata(f2s_rdata), .f2s_rresp(f2s_rresp),
      .f2s_rlast(f2s_rlast), .f2s_rvalid(f2s_rvalid), .f2s_rready(f2s_rready)
  );

  // The master's write ID, its constants and its mode, which the port's
  // one ID makes no use of.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{awid, one_write_id, read_clocks, write_clocks};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
