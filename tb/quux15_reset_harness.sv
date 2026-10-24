// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S CORE BEHIND A BOARD'S MEMORY ADAPTER, WITH THE CONSOLE
// FACE**, for `tb/quux15_reset_axi_tb.cpp`: the core (`quux15_core.sv`),
// its master put on the port the way one board's top level puts it
// (`BOARD`), and the console face (`quux15_face.sv`) wired to the core's
// reset request and its answer as every revision 15 top level wires them.
//
//   BOARD 0  the core's own port: AXI4, 64 bits, as the core's testbench
//            answers it
//   BOARD 1  the Arty Z7-20's: `quux15_axi3.sv`, AXI3's fields, 64 bits
//   BOARD 2  the Kria KR260's: `quux_axi_narrow128.sv`, narrow bursts of
//            eight bytes on a 128-bit port, its queues on the port's reset
//
// and the core's cache at a board's size (`CACHE_WORDS`), which the
// Makefile builds board 0 at the DE25-Nano's, board 1 at the Arty Z7-20's
// and board 2 at the Kria KR260's.
//
// The port's side is 128 bits wide whatever the board, its upper half
// unused below BOARD 2.  The testbench drives the two resets as a top level
// does (`hard`: the clock's lock and the port's own reset; `req`: BTN1 or
// KEY1) and the face's page as the processing system does.  `OLD_RESET`
// builds the core as revision 15 had it before the request: one reset, the
// request straight onto it, and no face.
//
// **NONE OF THIS MAY MOVE TO `rtl/`**: the board flows glob that tree.

`default_nettype none

// A board's adapter leaves fields of the core's unread, and the narrower
// boards half of the port's data.
/* verilator lint_off UNUSEDSIGNAL */
module quux15_reset_harness #(
    parameter int unsigned BOARD = 0,
    // The core's cache, the board's: 16K words on the DE25-Nano, 4K on the
    // Arty Z7-20, 64K (the core's default) on the Kria KR260.
    parameter int unsigned CACHE_WORDS = 65536
) (
    input  var logic         clk,
    input  var logic         hard,
    input  var logic         req,
    output var logic         core_on,
    output var logic         core_pend,
    output var logic         core_cut,
    // The face's page, as `cadr_gp_regs.sv` takes it: one beat a write.
    input  var logic [11:0]  f_awaddr,
    input  var logic         f_awvalid,
    output var logic         f_awready,
    input  var logic [31:0]  f_wdata,
    input  var logic         f_wvalid,
    output var logic         f_wready,
    output var logic         f_bvalid,
    input  var logic         f_bready,
    input  var logic [11:0]  f_araddr,
    input  var logic         f_arvalid,
    output var logic         f_arready,
    output var logic [31:0]  f_rdata,
    output var logic         f_rvalid,
    input  var logic         f_rready,
    // The memory port.
    output var logic [31:0]  m_awaddr,
    output var logic [7:0]   m_awlen,
    output var logic         m_awvalid,
    input  var logic         m_awready,
    output var logic [127:0] m_wdata,
    output var logic [15:0]  m_wstrb,
    output var logic         m_wlast,
    output var logic         m_wvalid,
    input  var logic         m_wready,
    input  var logic         m_bvalid,
    output var logic         m_bready,
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic         m_arvalid,
    input  var logic         m_arready,
    input  var logic [127:0] m_rdata,
    input  var logic         m_rlast,
    input  var logic         m_rvalid,
    output var logic         m_rready,
    // The core's observation the testbench reads.
    output var logic [15:0]  obs_commit,
    output var logic [3:0]   obs_queue,
    output var logic [4:0]   obs_inflight
);

  // The core's master.
  logic [3:0]  c_awid;
  logic [31:0] c_awaddr, c_araddr;
  logic [7:0]  c_awlen, c_arlen;
  logic [2:0]  c_awsize, c_arsize;
  logic [1:0]  c_awburst, c_arburst, c_rresp, c_bresp;
  logic        c_awvalid, c_awready, c_wlast, c_wvalid, c_wready, c_bvalid, c_bready;
  logic        c_arvalid, c_arready, c_rlast, c_rvalid, c_rready;
  logic [63:0] c_wdata, c_rdata;
  logic [7:0]  c_wstrb;

  logic face_req, rst_pend, rst_on, rst_cut;

  /* verilator lint_off PINCONNECTEMPTY */
  quux15_core #(.CACHE_WORDS(CACHE_WORDS)) u_core (
      .clk(clk),
`ifdef OLD_RESET
      .rst(hard || req),
`else
      .rst(hard), .rst_req(req || face_req),
      .rst_pend(rst_pend), .rst_on(rst_on), .rst_cut(rst_cut),
`endif
      .obs_cs(), .obs_rd(), .obs_ex(), .obs_wb(), .obs_commit(obs_commit),
      .obs_pdlptr(), .obs_pdlidx(), .obs_spcptr(), .obs_q(), .obs_vma(), .obs_md(),
      .obs_lc(), .obs_ic(), .obs_opnd(), .obs_ea(), .obs_em(), .obs_ob(), .obs_oalow(),
      .obs_oahigh(), .obs_grant(), .obs_gaddr(), .obs_mdl(), .obs_mdword(), .obs_reg(),
      .obs_raddr(), .obs_queue(obs_queue), .obs_inflight(obs_inflight), .obs_halted(),
      .obs_errhalt(),
      .m_awid(c_awid), .m_awaddr(c_awaddr), .m_awlen(c_awlen), .m_awsize(c_awsize),
      .m_awburst(c_awburst), .m_awvalid(c_awvalid), .m_awready(c_awready),
      .m_wdata(c_wdata), .m_wstrb(c_wstrb), .m_wlast(c_wlast), .m_wvalid(c_wvalid),
      .m_wready(c_wready), .m_bid(4'd0), .m_bresp(c_bresp), .m_bvalid(c_bvalid),
      .m_bready(c_bready),
      .m_araddr(c_araddr), .m_arlen(c_arlen), .m_arsize(c_arsize), .m_arburst(c_arburst),
      .m_arvalid(c_arvalid), .m_arready(c_arready), .m_rdata(c_rdata), .m_rresp(c_rresp),
      .m_rlast(c_rlast), .m_rvalid(c_rvalid), .m_rready(c_rready),
      .period(7'd20), .rtc_start(32'd0),
      .fd_doorbell(), .fd_prod(), .fd_enabled(),
      .host_we(1'b0), .host_widx(4'd0), .host_wdata(32'd0), .host_ridx(4'd2), .host_rdata(),
      .eth_we(1'b0), .eth_widx(5'd0), .eth_wdata(32'd0), .eth_ridx(5'd0), .eth_rdata(),
      .eth_tx_prod(), .eth_rx_prod(),
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'h7f), .kbd_busy(),
      .axi_one_write_id(), .axi_read_clocks(), .axi_write_clocks(),
      .spy_we(spy_we), .spy_eadr(spy_eadr), .spy_wdata(spy_wdata), .spy_raddr(spy_raddr),
      .spy_rdata(spy_rdata),
      .ro_sel(5'd0), .ro_word(),
      .rm_en(rm_en), .rm_snap(rm_snap), .rm_sel(rm_sel), .rm_addr(rm_addr), .rm_word(rm_word),
      .obs_committed(committed), .obs_clocks(clocks),
      .drive_present(1'b0),
      .store_we(1'b0), .store_slot(5'd0), .store_addr(9'd0), .store_wdata(32'd0), .store_rdata(),
      .store_miss(), .req_valid(), .req_tag(), .req_post(), .ch_waiting(), .store_deny(1'b0),
      .ch_slot(), .ch_wrote(), .ch_hit(), .ch_active(), .store_busy(1'b0), .store_busy_slot(5'd0),
      .obs_transfer(), .bow()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // The console face, as the Zynq boards' top levels wire it.
  logic        spy_we, rm_en, rm_snap;
  logic [3:0]  spy_eadr, spy_raddr, rm_sel;
  logic [15:0] spy_wdata, spy_rdata;
  logic [13:0] rm_addr;
  logic [63:0] rm_word, committed;
  logic [47:0] clocks;
`ifdef OLD_RESET
  assign face_req = 1'b0;
  assign rst_pend = 1'b0;
  assign rst_on   = hard || req;
  assign rst_cut  = 1'b0;
  assign spy_we = 1'b0; assign spy_eadr = '0; assign spy_wdata = '0; assign spy_raddr = '0;
  assign rm_en = 1'b0; assign rm_snap = 1'b0; assign rm_sel = '0; assign rm_addr = '0;
  assign f_awready = 1'b0; assign f_wready = 1'b0; assign f_bvalid = 1'b0;
  assign f_arready = 1'b0; assign f_rdata = '0; assign f_rvalid = 1'b0;
`else
  /* verilator lint_off PINCONNECTEMPTY */
  quux15_face u_face (
      .clk(clk), .rst(hard),
      .s_awaddr(f_awaddr), .s_awlen('0), .s_awid('0), .s_awvalid(f_awvalid), .s_awready(f_awready),
      .s_wdata(f_wdata), .s_wstrb(4'hF), .s_wlast(1'b1), .s_wvalid(f_wvalid), .s_wready(f_wready),
      .s_bresp(), .s_bid(), .s_bvalid(f_bvalid), .s_bready(f_bready),
      .s_araddr(f_araddr), .s_arlen('0), .s_arid('0), .s_arvalid(f_arvalid), .s_arready(f_arready),
      .s_rdata(f_rdata), .s_rresp(), .s_rid(), .s_rlast(), .s_rvalid(f_rvalid), .s_rready(f_rready),
      .build(32'd0),
      .mach_req(face_req), .mach_pend(rst_pend), .mach_on(rst_on), .mach_cut(rst_cut),
      .rtc_start(),
      .committed(committed), .clocks(clocks), .vma(40'd0), .q(40'd0), .md(40'd0),
      .spy_we(spy_we), .spy_eadr(spy_eadr), .spy_wdata(spy_wdata), .spy_raddr(spy_raddr),
      .spy_rdata(spy_rdata),
      .rm_en(rm_en), .rm_snap(rm_snap), .rm_sel(rm_sel), .rm_addr(rm_addr), .rm_word(rm_word),
      .disp_out(), .disp_rotate(), .sleep_set(), .sleep_secs(), .wake(),
      .disp_fitted(1'b0), .sleep_q(15'd0), .asleep(1'b0), .underrun(1'b0), .rd_error(1'b0),
      .err_clear(), .steady_lamps(),
      .probe_fitted(1'b0), .probe_state(3'd0), .probe_words('0), .probe_run(), .probe_stop()
  );
  /* verilator lint_on PINCONNECTEMPTY */
`endif
  assign core_on   = rst_on;
  assign core_pend = rst_pend;
  assign core_cut  = rst_cut;

  // The board's adapter.
  if (BOARD == 2) begin : g_kria
    /* verilator lint_off PINCONNECTEMPTY */
    quux_axi_narrow128 u_narrow (
        .clk(clk), .rst(hard),
        .s_awaddr(c_awaddr), .s_awlen(c_awlen[3:0]), .s_awsize(c_awsize[1:0]),
        .s_awvalid(c_awvalid), .s_awready(c_awready),
        .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wlast(c_wlast),
        .s_wvalid(c_wvalid), .s_wready(c_wready),
        .s_araddr(c_araddr), .s_arlen(c_arlen[3:0]), .s_arsize(c_arsize[1:0]),
        .s_arvalid(c_arvalid), .s_arready(c_arready),
        .s_rdata(c_rdata), .s_rready(c_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rlast(m_rlast), .m_rvalid(m_rvalid)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    assign c_rlast  = m_rlast;
    assign c_rvalid = m_rvalid;
    assign c_rresp  = 2'b00;
    assign c_bvalid = m_bvalid;
    assign c_bresp  = 2'b00;
    assign m_bready = c_bready;
    assign m_rready = c_rready;
  end else if (BOARD == 1) begin : g_arty
    logic [3:0] a_awlen, a_arlen;
    logic [1:0] a_awsize, a_arsize, a_awburst, a_arburst;
    logic [63:0] a_wdata;
    logic [7:0]  a_wstrb;
    quux15_axi3 u_axi3 (
        .s_awaddr(c_awaddr), .s_awlen(c_awlen), .s_awsize(c_awsize), .s_awburst(c_awburst),
        .s_awvalid(c_awvalid), .s_awready(c_awready),
        .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wlast(c_wlast),
        .s_wvalid(c_wvalid), .s_wready(c_wready),
        .s_bresp(c_bresp), .s_bvalid(c_bvalid), .s_bready(c_bready),
        .s_araddr(c_araddr), .s_arlen(c_arlen), .s_arsize(c_arsize), .s_arburst(c_arburst),
        .s_arvalid(c_arvalid), .s_arready(c_arready),
        .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rlast(c_rlast), .s_rvalid(c_rvalid),
        .s_rready(c_rready),
        .m_awaddr(m_awaddr), .m_awlen(a_awlen), .m_awsize(a_awsize), .m_awburst(a_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(a_wdata), .m_wstrb(a_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(2'b00), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arlen(a_arlen), .m_arsize(a_arsize), .m_arburst(a_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata[63:0]), .m_rresp(2'b00), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
        .m_rready(m_rready)
    );
    assign m_awlen = {4'd0, a_awlen};
    assign m_arlen = {4'd0, a_arlen};
    assign m_wdata = {64'd0, a_wdata};
    assign m_wstrb = {8'd0, a_wstrb};
  end else begin : g_core
    assign m_awaddr  = c_awaddr;
    assign m_awlen   = c_awlen;
    assign m_awvalid = c_awvalid;
    assign c_awready = m_awready;
    assign m_wdata   = {64'd0, c_wdata};
    assign m_wstrb   = {8'd0, c_wstrb};
    assign m_wlast   = c_wlast;
    assign m_wvalid  = c_wvalid;
    assign c_wready  = m_wready;
    assign c_bvalid  = m_bvalid;
    assign c_bresp   = 2'b00;
    assign m_bready  = c_bready;
    assign m_araddr  = c_araddr;
    assign m_arlen   = c_arlen;
    assign m_arvalid = c_arvalid;
    assign c_arready = m_arready;
    assign c_rdata   = m_rdata[63:0];
    assign c_rresp   = 2'b00;
    assign c_rlast   = m_rlast;
    assign c_rvalid  = m_rvalid;
    assign m_rready  = c_rready;
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
