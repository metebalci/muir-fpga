// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The display output behind the DE25-Nano's share of the FPGA-to-SDRAM
// bridge: `rtl/plumbing/cadr_display_out.sv` on the third port of
// `rtl/plumbing/cadr_f2sdram_share.sv`, as `boards/de25-nano/cadr_de25.sv`
// wires it, with the bridge brought out for `tb/cadr_display_out_tb.cpp` to be.
//
// **WHY THE TWO TOGETHER.**  `build/display_out.pass` holds the display against
// a port of its own, which is the Zynq boards' `S_AXI_HP3`.  On the DE25-Nano
// the port is shared, and what the share lets through is what the display
// gets: a rotated picture is fetched as single-beat reads with several in
// flight, because one at a time does not finish a band in the time the
// raster gives it at any real memory latency (`docs/display-output.md`).  So
// the question "does the rotated picture keep up on this board" is a question
// about the two modules together, against a memory whose latency is
// pipelined as a real one is, and this is where it is asked.
//
// The port list is `cadr_display_out`'s own, so the same testbench drives
// either; the machine's port and the pack side's are idle, and the hold is
// down, as they are between the machine's cycles on the board.  The read ID
// the bridge answers with is the display's, 2, tied here, since nothing else
// reads.  The bridge's AXI4 length and size come back out at the AXI3 widths
// the testbench's slave checks, which the share zero-extends in the first
// place.  It is in `tb/` for the reason `tb/cadr_f2sdram_harness.sv` gives.

`default_nettype none

module cadr_display_share_harness (
    input  var logic        clk,
    input  var logic        rst,
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
    output var logic        m_rready,
    input  var logic [1:0]  out_sel,
    input  var logic [1:0]  rotate,
    input  var logic        sleep_set,
    input  var logic [14:0] sleep_secs,
    input  var logic        wake,
    output var logic [14:0] sleep_setting,
    output var logic        sleep_due,
    output var logic        asleep,
    input  var logic        pclk,
    input  var logic        prst,
    output var logic [3:0]  map_a,
    input  var logic [23:0] map_q,
    output var logic        mute,
    output var logic        de,
    output var logic        hsync,
    output var logic        vsync,
    output var logic [7:0]  red,
    output var logic [7:0]  green,
    output var logic [7:0]  blue,
    output var logic        underrun,
    output var logic        rd_error
);

  // The display's own port.
  logic [31:0] d_araddr;
  logic [3:0]  d_arlen;
  logic [1:0]  d_arsize, d_arburst, d_rresp;
  logic        d_arvalid, d_arready, d_rlast, d_rvalid, d_rready;
  logic [63:0] d_rdata;

  cadr_display_out u_display (
      .clk(clk), .rst(rst),
      .m_araddr(d_araddr), .m_arlen(d_arlen), .m_arsize(d_arsize),
      .m_arburst(d_arburst), .m_arvalid(d_arvalid), .m_arready(d_arready),
      .m_rdata(d_rdata), .m_rresp(d_rresp), .m_rlast(d_rlast),
      .m_rvalid(d_rvalid), .m_rready(d_rready),
      .out_sel(out_sel), .rotate(rotate),
      .sleep_set(sleep_set), .sleep_secs(sleep_secs), .wake(wake),
      .sleep_setting(sleep_setting), .sleep_due(sleep_due), .asleep(asleep),
      .pclk(pclk), .prst(prst),
      .map_a(map_a), .map_q(map_q),
      .mute(mute), .de(de), .hsync(hsync), .vsync(vsync),
      .red(red), .green(green), .blue(blue),
      .underrun(underrun), .rd_error(rd_error)
  );

  // The share, three ports as on the board: the machine, the pack side, the
  // display.  The first two ask for nothing.
  logic [2:0][31:0] s_awaddr, s_araddr;
  logic [2:0][3:0]  s_awlen, s_arlen;
  logic [2:0][1:0]  s_awsize, s_awburst, s_arsize, s_arburst, s_bresp, s_rresp;
  logic [2:0]       s_awvalid, s_awready, s_wlast, s_wvalid, s_wready;
  logic [2:0]       s_bvalid, s_bready, s_arvalid, s_arready;
  logic [2:0]       s_rlast, s_rvalid, s_rready;
  logic [2:0][63:0] s_wdata, s_rdata;
  logic [2:0][7:0]  s_wstrb;

  assign s_awaddr  = '0;
  assign s_awlen   = '0;
  assign s_awsize  = {3{2'b11}};
  assign s_awburst = {3{2'b01}};
  assign s_awvalid = '0;
  assign s_wdata   = '0;
  assign s_wstrb   = '0;
  assign s_wlast   = '0;
  assign s_wvalid  = '0;
  assign s_bready  = '1;
  assign s_araddr  = {d_araddr, 32'd0, 32'd0};
  assign s_arlen   = {d_arlen, 4'd0, 4'd0};
  assign s_arsize  = {d_arsize, 2'b11, 2'b11};
  assign s_arburst = {d_arburst, 2'b01, 2'b01};
  assign s_arvalid = {d_arvalid, 2'b00};
  assign s_rready  = {d_rready, 2'b11};
  assign d_arready = s_arready[2];
  assign d_rdata   = s_rdata[2];
  assign d_rresp   = s_rresp[2];
  assign d_rlast   = s_rlast[2];
  assign d_rvalid  = s_rvalid[2];

  logic [7:0]  b_arlen;
  logic [2:0]  b_arsize;
  logic [4:0]  b_arid;
  logic        idle;

  /* verilator lint_off PINCONNECTEMPTY */
  cadr_f2sdram_share #(.N(3)) u_share (
      .clk(clk), .rst(rst), .hold(1'b0), .idle(idle),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
      .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize),
      .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
      .s_rvalid(s_rvalid), .s_rready(s_rready),
      .m_awid(), .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(),
      .m_awlock(), .m_awcache(), .m_awprot(), .m_awqos(), .m_awregion(),
      .m_awuser(), .m_awvalid(), .m_awready(1'b0),
      .m_wdata(), .m_wstrb(), .m_wlast(), .m_wuser(), .m_wvalid(),
      .m_wready(1'b0),
      .m_bid(5'd0), .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready(),
      .m_arid(b_arid), .m_araddr(m_araddr), .m_arlen(b_arlen),
      .m_arsize(b_arsize), .m_arburst(m_arburst),
      .m_arlock(), .m_arcache(), .m_arprot(), .m_arqos(), .m_arregion(),
      .m_aruser(), .m_arvalid(m_arvalid), .m_arready(m_arready),
      .m_rid(5'd2), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
      .m_rvalid(m_rvalid), .m_rready(m_rready)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign m_arlen  = b_arlen[3:0];
  assign m_arsize = b_arsize[1:0];

  // What the testbench's slave does not look at: the top bits of the length
  // and the size, which the share zero-extends; the ID, which is the
  // display's whenever the display is the only master asking; the other two
  // ports' answers; and whether the share is idle.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{b_arlen[7:4], b_arsize[2], b_arid, idle, s_awready,
                    s_wready, s_bresp, s_bvalid, s_rdata[1:0], s_rresp[1:0],
                    s_rlast[1:0], s_rvalid[1:0], s_arready[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
