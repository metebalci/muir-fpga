// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S MAIN MEMORY ON THE AGILEX 5'S FPGA-TO-SDRAM BRIDGE**:
// the DE25-Nano's counterpart of what `boards/kria-kr260/quux15_kr260.sv`
// and `boards/arty-z7-20/quux15_arty.sv` wire to their memory ports.  It is
// `cadr_f2sdram_port.sv` with the machine's own master in place of the
// CADR's adapter, and a module rather than wiring in
// `boards/de25-nano/quux15_de25.sv` for the reason that file gives: the top
// level instantiates Altera's generated processor system, and here
// `tb/quux15_f2sdram_tb.cpp` runs revision 15's master through this very
// module.
//
//   `quux15_axi_master.sv` inside the core's port: AXI4 at 64 bits, line
//                          fills of five beats, posted word writes with one
//                          AXI ID, the bursts split at 4 KiB.  It comes in
//                          here on `s_*`.
//   `quux15_axi3.sv`       its fields in the share's AXI3 shape: four bits of
//                          length, two of size (the bursts are five beats at
//                          most and every beat eight bytes).
//   `cadr_f2sdram_share.sv` the bridge's one port, shared by burst, the
//                          machine on port 0 and first, the pack side on 1
//                          and the display on 2, the share's port number
//                          the bridge's transaction ID.
//   `cadr_f2sdram_gate.sv` the port shut until software opens it on
//                          `h2f_gp_out[0]`, and the warm-reset handshake.
//   `cadr_mem_count.sv`    the tally, at the bridge's own handshakes carrying
//                          the machine's ID, on `h2f_gp_in` by halves.
//
// **ONE WRITE IN FLIGHT ON PORT 0.**  The share grants a master its next
// write once the last has its response (`cadr_f2sdram_share.sv`'s header),
// so the master's posted writes go to the bridge one at a time; their IDs
// are the share's 0, in order, and the master's one write ID answers them in
// order.  Whether port 0 should carry more is MP8 step 3's.
//
// **THE MACHINE'S RESET IS THE CORE'S OWN, AS ON THE OTHER BOARDS.**  On the
// CADR the adapter is this module's and the gate resets it only once the
// share has drained.  Revision 15's master is inside the core, and the core
// drains its own port before a reset the board asks for (`quux15_core.sv`'s
// `rst_req`): its queued and in-flight writes land and its fills come in,
// through the share, which keeps granting while it does.  So nothing here
// holds the share for the machine's reset, and the top level gives the core
// its two resets: the request (KEY1, the console's RESET key, and the port
// not yet live, below) and the hard reset (the processor's, which resets the
// bridge, and the clock's lock), taken at once.
//
// **AND THE MACHINE WAITS FOR ITS MEMORY**, as the CADR does on this board:
// the top level asks for the core's reset from the fabric's configuration
// until the port has been live once (`may_start`, the gate's latch), so its
// first line fill meets an open port.  It is a request and never a hard
// reset; the port is empty then, so the core is in reset at once.  Revision
// 15 has no memory timeout, so a fill at a shut port would only wait; the
// hold is what makes the boot meet the port's order on every board, as the
// Zynq boards meet it by their processing system coming up first.
// `tb/quux15_f2sdram_tb.cpp`'s OPEN holds it.
//
// **THE CLOCK'S LOCK RESETS THE SHARE AT ONCE** (`lock_rst`), as it resets
// the core: the gate drains on it and re-arms `may_start`, and the share and
// the adapter take it directly, so that a core reset mid-transaction cannot
// leave the share waiting for its beats.  KEY1 does not reach the share:
// the pack side takes it at its own `fabric_rst` and the display `!live`.
//
// **THE TALLY IS READ ON `h2f_gp_in`** as `cadr_f2sdram_port.sv` has it:
// `h2f_gp_out[1]` low for the answers, `cadr_mem_count.sv`'s bits 31 to 0,
// high for the requests, its bits 63 to 32, each half carrying the module's
// marker.  An ask is a read or a write address the bridge took with the
// machine's ID, counted at its rise as the Zynq boards count theirs; an
// answer is the bridge's B or last R with the machine's ID.  It is cleared by
// the fabric's reset and not by the port's.

`default_nettype none

module quux15_f2sdram_port (
    input  var logic clk,
    // The fabric's reset: the tally's.
    input  var logic rst,
    // The clock's lock: the gate's reset, and the share's at once.
    input  var logic lock_rst,

    // --- the machine's master, AXI4 at 64 bits (`quux15_axi_master.sv`) ----
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

    // --- the processor, asynchronous to this clock ------------------------
    input  var logic        h2f_reset,
    input  var logic        gp_open,       // `h2f_gp_out[0]`
    input  var logic        gp_half,       // `h2f_gp_out[1]`: which half
    input  var logic        warm_req_n,
    output var logic        warm_ack_n,
    output var logic [31:0] gp_in,         // `h2f_gp_in`
    // The port is open and out of reset, for a lamp and the display's reset.
    output var logic        live,
    // The port has been live at least once since the fabric's reset.
    output var logic        may_start,

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

  // **THE SHARE'S PORT NUMBERS**, which are the bridge's transaction IDs:
  // the machine's 0 is what the tally counts and what `cadr_mem.c`'s guard
  // and the machine's one write ID take for granted.
  localparam int unsigned MACHINE = 0, PACK = 1, DISPLAY = 2;

  // ------------------------------------------------------------ the gate
  logic port_rst, gate_hold, idle;
  cadr_f2sdram_gate u_gate (
      .clk(clk), .rst(lock_rst),
      .h2f_reset(h2f_reset), .gp_open(gp_open), .req_n(warm_req_n),
      .idle(idle),
      .hold(gate_hold), .port_rst(port_rst), .ack_n(warm_ack_n), .live(live),
      .may_start(may_start)
  );

  // The share's reset: the gate's, or the clock's lock at once.
  logic share_rst;
  assign share_rst = port_rst || lock_rst;

  // --------------------------------------------- the master's AXI3 shape
  logic [31:0] b_awaddr, b_araddr;
  logic [3:0]  b_awlen, b_arlen;
  logic [1:0]  b_awsize, b_arsize, b_awburst, b_arburst, b_bresp, b_rresp;
  logic [63:0] b_wdata, b_rdata;
  logic [7:0]  b_wstrb;
  logic        b_awvalid, b_awready, b_wlast, b_wvalid, b_wready, b_bvalid, b_bready;
  logic        b_arvalid, b_arready, b_rlast, b_rvalid, b_rready;

  quux15_axi3 u_axi3 (
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize), .s_awburst(s_awburst),
      .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst),
      .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid),
      .s_rready(s_rready),
      .m_awaddr(b_awaddr), .m_awlen(b_awlen), .m_awsize(b_awsize), .m_awburst(b_awburst),
      .m_awvalid(b_awvalid), .m_awready(b_awready),
      .m_wdata(b_wdata), .m_wstrb(b_wstrb), .m_wlast(b_wlast),
      .m_wvalid(b_wvalid), .m_wready(b_wready),
      .m_bresp(b_bresp), .m_bvalid(b_bvalid), .m_bready(b_bready),
      .m_araddr(b_araddr), .m_arlen(b_arlen), .m_arsize(b_arsize), .m_arburst(b_arburst),
      .m_arvalid(b_arvalid), .m_arready(b_arready),
      .m_rdata(b_rdata), .m_rresp(b_rresp), .m_rlast(b_rlast), .m_rvalid(b_rvalid),
      .m_rready(b_rready)
  );

  // ----------------------------------------------------------- the share
  //
  // Each port's fields at its number.  The display never writes, so its
  // write port is tied off here: its address and data never valid, and a
  // response to it taken and dropped, though none can come.
  logic [2:0][31:0] h_awaddr, h_araddr;
  logic [2:0][3:0]  h_awlen, h_arlen;
  logic [2:0][1:0]  h_awsize, h_arsize, h_awburst, h_arburst;
  logic [2:0][63:0] h_wdata, h_rdata;
  logic [2:0][7:0]  h_wstrb;
  logic [2:0][1:0]  h_bresp, h_rresp;
  logic [2:0]       h_awvalid, h_awready, h_wlast, h_wvalid, h_wready, h_bvalid, h_bready;
  logic [2:0]       h_arvalid, h_arready, h_rlast, h_rvalid, h_rready;

  always_comb begin
    h_awaddr[MACHINE]  = b_awaddr;
    h_awlen[MACHINE]   = b_awlen;
    h_awsize[MACHINE]  = b_awsize;
    h_awburst[MACHINE] = b_awburst;
    h_awvalid[MACHINE] = b_awvalid;
    h_wdata[MACHINE]   = b_wdata;
    h_wstrb[MACHINE]   = b_wstrb;
    h_wlast[MACHINE]   = b_wlast;
    h_wvalid[MACHINE]  = b_wvalid;
    h_bready[MACHINE]  = b_bready;
    h_araddr[MACHINE]  = b_araddr;
    h_arlen[MACHINE]   = b_arlen;
    h_arsize[MACHINE]  = b_arsize;
    h_arburst[MACHINE] = b_arburst;
    h_arvalid[MACHINE] = b_arvalid;
    h_rready[MACHINE]  = b_rready;

    h_awaddr[PACK]  = p_awaddr;
    h_awlen[PACK]   = p_awlen;
    h_awsize[PACK]  = p_awsize;
    h_awburst[PACK] = p_awburst;
    h_awvalid[PACK] = p_awvalid;
    h_wdata[PACK]   = p_wdata;
    h_wstrb[PACK]   = p_wstrb;
    h_wlast[PACK]   = p_wlast;
    h_wvalid[PACK]  = p_wvalid;
    h_bready[PACK]  = p_bready;
    h_araddr[PACK]  = p_araddr;
    h_arlen[PACK]   = p_arlen;
    h_arsize[PACK]  = p_arsize;
    h_arburst[PACK] = p_arburst;
    h_arvalid[PACK] = p_arvalid;
    h_rready[PACK]  = p_rready;

    h_awaddr[DISPLAY]  = 32'd0;
    h_awlen[DISPLAY]   = 4'd0;
    h_awsize[DISPLAY]  = 2'd0;
    h_awburst[DISPLAY] = 2'd0;
    h_awvalid[DISPLAY] = 1'b0;
    h_wdata[DISPLAY]   = 64'd0;
    h_wstrb[DISPLAY]   = 8'd0;
    h_wlast[DISPLAY]   = 1'b0;
    h_wvalid[DISPLAY]  = 1'b0;
    h_bready[DISPLAY]  = 1'b1;
    h_araddr[DISPLAY]  = d_araddr;
    h_arlen[DISPLAY]   = d_arlen;
    h_arsize[DISPLAY]  = d_arsize;
    h_arburst[DISPLAY] = d_arburst;
    h_arvalid[DISPLAY] = d_arvalid;
    h_rready[DISPLAY]  = d_rready;
  end

  cadr_f2sdram_share #(.N(3)) u_share (
      .clk(clk), .rst(share_rst), .hold(gate_hold), .idle(idle),
      .s_awaddr(h_awaddr), .s_awlen(h_awlen), .s_awsize(h_awsize), .s_awburst(h_awburst),
      .s_awvalid(h_awvalid), .s_awready(h_awready),
      .s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
      .s_wready(h_wready),
      .s_bresp(h_bresp), .s_bvalid(h_bvalid), .s_bready(h_bready),
      .s_araddr(h_araddr), .s_arlen(h_arlen), .s_arsize(h_arsize), .s_arburst(h_arburst),
      .s_arvalid(h_arvalid), .s_arready(h_arready),
      .s_rdata(h_rdata), .s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid),
      .s_rready(h_rready),
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

  assign b_awready = h_awready[MACHINE];
  assign b_wready  = h_wready[MACHINE];
  assign b_bvalid  = h_bvalid[MACHINE];
  assign b_bresp   = h_bresp[MACHINE];
  assign b_arready = h_arready[MACHINE];
  assign b_rvalid  = h_rvalid[MACHINE];
  assign b_rdata   = h_rdata[MACHINE];
  assign b_rresp   = h_rresp[MACHINE];
  assign b_rlast   = h_rlast[MACHINE];

  assign p_awready = h_awready[PACK];
  assign p_wready  = h_wready[PACK];
  assign p_bvalid  = h_bvalid[PACK];
  assign p_bresp   = h_bresp[PACK];
  assign p_arready = h_arready[PACK];
  assign p_rvalid  = h_rvalid[PACK];
  assign p_rdata   = h_rdata[PACK];
  assign p_rresp   = h_rresp[PACK];
  assign p_rlast   = h_rlast[PACK];

  assign d_arready = h_arready[DISPLAY];
  assign d_rvalid  = h_rvalid[DISPLAY];
  assign d_rdata   = h_rdata[DISPLAY];
  assign d_rresp   = h_rresp[DISPLAY];
  assign d_rlast   = h_rlast[DISPLAY];

  // ----------------------------------------------------------- the tally
  //
  // The bridge's own handshakes carrying the machine's ID, each copied on
  // one edge: an address taken (read or write) is an ask, counted at its
  // rise; a B or a last R is an answer.
  logic count_req, count_write;
  logic count_bvalid, count_bready, count_rvalid, count_rready, count_rlast;
  always_ff @(posedge clk) begin
    count_req    <= (f2s_arvalid && f2s_arready && f2s_arid == 5'(MACHINE))
                 || (f2s_awvalid && f2s_awready && f2s_awid == 5'(MACHINE));
    count_write  <= f2s_awvalid && f2s_awready && f2s_awid == 5'(MACHINE);
    count_bvalid <= f2s_bvalid && (f2s_bid == 5'(MACHINE));
    count_bready <= f2s_bready;
    count_rvalid <= f2s_rvalid && (f2s_rid == 5'(MACHINE));
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

  // Which half software reads, synchronized in as the gate's three are.
  logic [2:0] half_s;
  always_ff @(posedge clk) begin
    half_s <= {half_s[1:0], gp_half};
    gp_in  <= half_s[2] ? tally[63:32] : tally[31:0];
  end

  // The display's write response, which no write of its asks for.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{h_bresp[DISPLAY], h_bvalid[DISPLAY], h_awready[DISPLAY], h_wready[DISPLAY]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
