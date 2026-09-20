// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine's main memory on the Agilex 5's FPGA-to-SDRAM bridge: the
// DE25-Nano's counterpart of what the Zynq boards wire to `S_AXI_HP0`.
//
// It is the Zynq path with one piece changed and two added, and it is a module
// rather than a generate block in `boards/de25-nano/cadr_de25.sv` for the
// reason `cadr_axi_widen.sv` gives: the top level instantiates Altera's
// generated processor system, which nothing here can simulate, so anything
// written there is held by lint and the fitter and nothing else.  Here it is
// held by `tb/cadr_f2sdram_tb.cpp`, which runs the machine through this very
// module, and the top level only wires it.
//
//   `cadr_axi_master.sv`   unchanged: one 32-bit word a transaction, AXI4.
//   `cadr_axi_widen.sv`    unchanged: the word in a full 64-bit beat, with
//                          the strobes choosing its half.  The bridge refuses
//                          a narrow transfer, and this never makes one.
//   `cadr_f2sdram_share.sv`  new: the bridge's one port shared by burst, the
//                          machine on port 0 and first, the AXI3 shape made
//                          AXI4, and the bridge's own attributes.
//   `cadr_f2sdram_gate.sv` new: the port shut until software opens it on
//                          `h2f_gp_out[0]`, and the warm-reset handshake.
//   `cadr_mem_count.sv`    unchanged: the tally of what the machine asked and
//                          what the bridge answered, counted at the bridge's
//                          own handshakes, and only those carrying the
//                          machine's ID.
//
// **THE OTHER TWO PORTS OF THE SHARE COME OUT HERE**, the disk pack side's,
// read and write, and the display's, read only, in the AXI3 shape their
// modules already have.  Both are tied off at the top level today.
//
// **THE TALLY IS READ ON `h2f_gp_in`**, the system manager's GPI register at
// `0x10D1_20E8`, which software reads with nobody at the board.  That is 32
// bits where the Zynq's EMIO had 64, so `h2f_gp_out[1]` chooses the half:
// low for the answers, `cadr_mem_count.sv`'s bits 31 to 0, and high for the
// requests, its bits 63 to 32.  Each half carries the module's marker, bit 15
// set and bit 31 clear, so a register nothing drives is not read as a count.
// The two halves read alike when every request was answered, which is the
// whole of a good run; a run with the port shut is where they part, and it is
// the control that says the select works.
//
// **THE TALLY IS CLEARED BY THE FABRIC'S RESET AND NOT BY THE PORT'S**, for the
// reason the Zynq boards give: a tally the port's reset cleared would erase
// itself when software opened the port, and would read "nothing asked" on a
// port that was never opened.

`default_nettype none

module cadr_f2sdram_port (
    input  var logic clk,
    // The fabric's reset.
    input  var logic rst,

    // --- the machine's memory port ----------------------------------------
    input  var logic        mem_req,
    input  var logic        mem_write,
    input  var logic [31:0] mem_addr,
    input  var logic [31:0] mem_wdata,
    output var logic        mem_done,
    output var logic [31:0] mem_rdata,
    output var logic        mem_error,

    // --- the processor, asynchronous to this clock ------------------------
    input  var logic        h2f_reset,
    input  var logic        gp_open,       // `h2f_gp_out[0]`
    input  var logic        gp_half,       // `h2f_gp_out[1]`: which half
    input  var logic        warm_req_n,
    output var logic        warm_ack_n,
    output var logic [31:0] gp_in,         // `h2f_gp_in`
    // The port is open and out of reset, for a lamp.
    output var logic        live,
    // **THE MACHINE MAY RUN**: the port has been live at least once since the
    // fabric's reset.  The top level holds the machine in reset until it is
    // up, so that the boot PROM's one pass over main memory meets a port that
    // is open; `cadr_f2sdram_gate.sv`'s header has the measurement.
    output var logic        may_start,
    // **WHAT THE BRIDGE ITSELF ANSWERED THE MACHINE**, the two handshakes
    // `cadr_machine`'s transaction audit is given: the last beat of a read
    // and a write's response, both carrying the machine's ID, off the same
    // registered copies the tally counts, so the tally and the audit cannot
    // disagree about what the port did.  The Zynq boards make the same pair
    // in their top level; here the copies are in this module, so it makes
    // them.
    output var logic        port_read_ack,
    output var logic        port_write_ack,

    // --- the disk pack side's port, AXI3 at 64 bits -----------------------
    input  var logic [31:0] p_awaddr,
    input  var logic [3:0]  p_awlen,
    input  var logic [1:0]  p_awsize,
    input  var logic [1:0]  p_awburst,
    input  var logic        p_awvalid,
    output var logic        p_awready,
    input  var logic [63:0] p_wdata,
    input  var logic [7:0]  p_wstrb,
    input  var logic        p_wlast,
    input  var logic        p_wvalid,
    output var logic        p_wready,
    output var logic [1:0]  p_bresp,
    output var logic        p_bvalid,
    input  var logic        p_bready,
    input  var logic [31:0] p_araddr,
    input  var logic [3:0]  p_arlen,
    input  var logic [1:0]  p_arsize,
    input  var logic [1:0]  p_arburst,
    input  var logic        p_arvalid,
    output var logic        p_arready,
    output var logic [63:0] p_rdata,
    output var logic [1:0]  p_rresp,
    output var logic        p_rlast,
    output var logic        p_rvalid,
    input  var logic        p_rready,

    // --- the display's port, AXI3 at 64 bits, read only ---------------------
    input  var logic [31:0] d_araddr,
    input  var logic [3:0]  d_arlen,
    input  var logic [1:0]  d_arsize,
    input  var logic [1:0]  d_arburst,
    input  var logic        d_arvalid,
    output var logic        d_arready,
    output var logic [63:0] d_rdata,
    output var logic [1:0]  d_rresp,
    output var logic        d_rlast,
    output var logic        d_rvalid,
    input  var logic        d_rready,

    // --- the FPGA-to-SDRAM bridge, AXI4 at 64 bits --------------------------
    output var logic [4:0]  f2s_awid,
    output var logic [31:0] f2s_awaddr,
    output var logic [7:0]  f2s_awlen,
    output var logic [2:0]  f2s_awsize,
    output var logic [1:0]  f2s_awburst,
    output var logic        f2s_awlock,
    output var logic [3:0]  f2s_awcache,
    output var logic [2:0]  f2s_awprot,
    output var logic [3:0]  f2s_awqos,
    output var logic [3:0]  f2s_awregion,
    output var logic [7:0]  f2s_awuser,
    output var logic        f2s_awvalid,
    input  var logic        f2s_awready,
    output var logic [63:0] f2s_wdata,
    output var logic [7:0]  f2s_wstrb,
    output var logic        f2s_wlast,
    output var logic [7:0]  f2s_wuser,
    output var logic        f2s_wvalid,
    input  var logic        f2s_wready,
    input  var logic [4:0]  f2s_bid,
    input  var logic [1:0]  f2s_bresp,
    input  var logic        f2s_bvalid,
    output var logic        f2s_bready,
    output var logic [4:0]  f2s_arid,
    output var logic [31:0] f2s_araddr,
    output var logic [7:0]  f2s_arlen,
    output var logic [2:0]  f2s_arsize,
    output var logic [1:0]  f2s_arburst,
    output var logic        f2s_arlock,
    output var logic [3:0]  f2s_arcache,
    output var logic [2:0]  f2s_arprot,
    output var logic [3:0]  f2s_arqos,
    output var logic [3:0]  f2s_arregion,
    output var logic [7:0]  f2s_aruser,
    output var logic        f2s_arvalid,
    input  var logic        f2s_arready,
    input  var logic [4:0]  f2s_rid,
    input  var logic [63:0] f2s_rdata,
    input  var logic [1:0]  f2s_rresp,
    input  var logic        f2s_rlast,
    input  var logic        f2s_rvalid,
    output var logic        f2s_rready
);

  // ------------------------------------------------------------ the gate
  logic port_rst, hold, idle;
  cadr_f2sdram_gate u_gate (
      .clk(clk), .rst(rst),
      .h2f_reset(h2f_reset), .gp_open(gp_open), .req_n(warm_req_n),
      .idle(idle),
      .hold(hold), .port_rst(port_rst), .ack_n(warm_ack_n), .live(live),
      .may_start(may_start)
  );

  // --------------------------------------------- the adapter and the beat
  logic [31:0] awaddr, araddr, wdata, rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [3:0]  wstrb;
  logic [1:0]  awburst, arburst, bresp, rresp;
  logic        awvalid, awready, wlast, wvalid, wready;
  logic        bvalid, bready, arvalid, arready, rlast, rvalid, rready;

  cadr_axi_master u_axi (
      .clk(clk), .rst(port_rst),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(mem_error),
      .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awvalid(awvalid),
      .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
      .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
      .m_axi_arburst(arburst), .m_axi_arvalid(arvalid),
      .m_axi_arready(arready),
      .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
      .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  logic [31:0] b_awaddr, b_araddr;
  logic [3:0]  b_awlen, b_arlen;
  logic [1:0]  b_awsize, b_arsize;
  logic [63:0] b_wdata, b_rdata;
  logic [7:0]  b_wstrb;

  cadr_axi_widen u_widen (
      .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
      .s_wdata(wdata), .s_wstrb(wstrb),
      .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
      .s_rdata(rdata),
      .m_awaddr(b_awaddr), .m_awlen(b_awlen), .m_awsize(b_awsize),
      .m_wdata(b_wdata), .m_wstrb(b_wstrb),
      .m_araddr(b_araddr), .m_arlen(b_arlen), .m_arsize(b_arsize),
      .m_rdata(b_rdata)
  );

  // ----------------------------------------------------------- the share
  //
  // Port 0 the machine, port 1 the pack side, port 2 the display.  The
  // display never writes, so its write port is tied off here and not at the
  // top level: its address and data are never valid, and a response to it
  // would be taken and dropped, though none can come.
  logic [2:0][63:0] s_rdata;
  logic [2:0][1:0]  s_bresp, s_rresp;
  logic [2:0]       s_awready, s_wready, s_bvalid, s_arready;
  logic [2:0]       s_rlast, s_rvalid;

  cadr_f2sdram_share #(.N(3)) u_share (
      .clk(clk), .rst(port_rst), .hold(hold), .idle(idle),
      .s_awaddr ({32'd0,  p_awaddr,  b_awaddr}),
      .s_awlen  ({4'd0,   p_awlen,   b_awlen}),
      .s_awsize ({2'd0,   p_awsize,  b_awsize}),
      .s_awburst({2'd0,   p_awburst, awburst}),
      .s_awvalid({1'b0,   p_awvalid, awvalid}),
      .s_awready(s_awready),
      .s_wdata  ({64'd0,  p_wdata,   b_wdata}),
      .s_wstrb  ({8'd0,   p_wstrb,   b_wstrb}),
      .s_wlast  ({1'b0,   p_wlast,   wlast}),
      .s_wvalid ({1'b0,   p_wvalid,  wvalid}),
      .s_wready (s_wready),
      .s_bresp  (s_bresp),
      .s_bvalid (s_bvalid),
      .s_bready ({1'b1,   p_bready,  bready}),
      .s_araddr ({d_araddr,  p_araddr,  b_araddr}),
      .s_arlen  ({d_arlen,   p_arlen,   b_arlen}),
      .s_arsize ({d_arsize,  p_arsize,  b_arsize}),
      .s_arburst({d_arburst, p_arburst, arburst}),
      .s_arvalid({d_arvalid, p_arvalid, arvalid}),
      .s_arready(s_arready),
      .s_rdata  (s_rdata),
      .s_rresp  (s_rresp),
      .s_rlast  (s_rlast),
      .s_rvalid (s_rvalid),
      .s_rready ({d_rready,  p_rready,  rready}),
      .m_awid(f2s_awid), .m_awaddr(f2s_awaddr), .m_awlen(f2s_awlen),
      .m_awsize(f2s_awsize), .m_awburst(f2s_awburst), .m_awlock(f2s_awlock),
      .m_awcache(f2s_awcache), .m_awprot(f2s_awprot), .m_awqos(f2s_awqos),
      .m_awregion(f2s_awregion), .m_awuser(f2s_awuser),
      .m_awvalid(f2s_awvalid), .m_awready(f2s_awready),
      .m_wdata(f2s_wdata), .m_wstrb(f2s_wstrb), .m_wlast(f2s_wlast),
      .m_wuser(f2s_wuser), .m_wvalid(f2s_wvalid), .m_wready(f2s_wready),
      .m_bid(f2s_bid), .m_bresp(f2s_bresp), .m_bvalid(f2s_bvalid),
      .m_bready(f2s_bready),
      .m_arid(f2s_arid), .m_araddr(f2s_araddr), .m_arlen(f2s_arlen),
      .m_arsize(f2s_arsize), .m_arburst(f2s_arburst), .m_arlock(f2s_arlock),
      .m_arcache(f2s_arcache), .m_arprot(f2s_arprot), .m_arqos(f2s_arqos),
      .m_arregion(f2s_arregion), .m_aruser(f2s_aruser),
      .m_arvalid(f2s_arvalid), .m_arready(f2s_arready),
      .m_rid(f2s_rid), .m_rdata(f2s_rdata), .m_rresp(f2s_rresp),
      .m_rlast(f2s_rlast), .m_rvalid(f2s_rvalid), .m_rready(f2s_rready)
  );

  assign awready = s_awready[0];
  assign wready  = s_wready[0];
  assign bvalid  = s_bvalid[0];
  assign bresp   = s_bresp[0];
  assign arready = s_arready[0];
  assign rvalid  = s_rvalid[0];
  assign b_rdata = s_rdata[0];
  assign rresp   = s_rresp[0];
  assign rlast   = s_rlast[0];

  assign p_awready = s_awready[1];
  assign p_wready  = s_wready[1];
  assign p_bvalid  = s_bvalid[1];
  assign p_bresp   = s_bresp[1];
  assign p_arready = s_arready[1];
  assign p_rvalid  = s_rvalid[1];
  assign p_rdata   = s_rdata[1];
  assign p_rresp   = s_rresp[1];
  assign p_rlast   = s_rlast[1];

  assign d_arready = s_arready[2];
  assign d_rvalid  = s_rvalid[2];
  assign d_rdata   = s_rdata[2];
  assign d_rresp   = s_rresp[2];
  assign d_rlast   = s_rlast[2];

  // ----------------------------------------------------------- the tally
  //
  // The machine's request, and the bridge's own answers carrying the
  // machine's ID, each copied on one edge as the Zynq boards copy theirs:
  // the tally counts rises and handshakes, and a copy a tick late counts the
  // same ones a tick late.
  logic count_req, count_write;
  logic count_bvalid, count_bready, count_rvalid, count_rready, count_rlast;
  always_ff @(posedge clk) begin
    count_req    <= mem_req;
    count_write  <= mem_write;
    count_bvalid <= f2s_bvalid && (f2s_bid == 5'd0);
    count_bready <= f2s_bready;
    count_rvalid <= f2s_rvalid && (f2s_rid == 5'd0);
    count_rready <= f2s_rready;
    count_rlast  <= f2s_rlast;
  end

  logic [63:0] tally;
  cadr_mem_count u_count (
      .clk(clk), .rst(rst),
      .req(count_req), .req_write(count_write),
      .bvalid(count_bvalid), .bready(count_bready),
      .rvalid(count_rvalid), .rready(count_rready), .rlast(count_rlast),
      .gpio(tally)
  );

  assign port_read_ack  = count_rvalid && count_rready && count_rlast;
  assign port_write_ack = count_bvalid && count_bready;

  // Which half software reads, synchronized in as the other three are.
  logic [2:0] half_s;
  always_ff @(posedge clk) begin
    half_s <= {half_s[1:0], gp_half};
    gp_in  <= half_s[2] ? tally[63:32] : tally[31:0];
  end

  // The display's write response and the unread fields of the machine's
  // adapter: see the share above and `cadr_axi_master.sv`.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{s_bresp[2], s_bvalid[2], s_awready[2], s_wready[2]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
