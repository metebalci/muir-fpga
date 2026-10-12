// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 15's file device and real-time clock from both of their
// sides: `rtl/plumbing/quux_fd_face.sv`, the page Linux reaches over the
// processor's port, with revision 15's register-page devices behind it
// (`rtl/machine/quux15_devices.sv`), as `boards/kria-kr260/quux15_kr260.sv`
// joins them through the core.  The testbench drives the face over AXI as
// Linux's server does, and the devices as the core does: a register read
// granted, its word the clock after; a register write taken; CMD_PROD's
// write, which the core gives only once every write before it is answered.
// The keyboard and the mouse, on the same page, sit still.
//
// **A FEW OF THE FILE DEVICE'S OWN SIGNALS ARE BROUGHT OUT**, beside what
// the processor can read: the completion landing (the port's sweep), the
// interrupt as the clock's write leaves it, and the index and the handles
// the processor's reads are made from, so that the order the host's side
// promises is measured by the clock rather than inferred from a read that
// may fall on either side of it.

`default_nettype none

module quux15_fd_face_harness #(
    parameter int unsigned MAIN_WORDS = 32'h0020_0000
) (
    input  var logic        clk,
    // The port's reset, the face's; and the machine's, the devices'.
    input  var logic        rst,
    input  var logic        mach_rst,

    // --- the face, over AXI3 as a Zynq board's port gives it
    input  var logic [11:0] m_awaddr,
    input  var logic [3:0]  m_awlen,
    input  var logic [11:0] m_awid,
    input  var logic        m_awvalid,
    output var logic        m_awready,
    input  var logic [31:0] m_wdata,
    input  var logic [3:0]  m_wstrb,
    input  var logic        m_wlast,
    input  var logic        m_wvalid,
    output var logic        m_wready,
    output var logic [1:0]  m_bresp,
    output var logic [11:0] m_bid,
    output var logic        m_bvalid,
    input  var logic        m_bready,
    input  var logic [11:0] m_araddr,
    input  var logic [3:0]  m_arlen,
    input  var logic [11:0] m_arid,
    input  var logic        m_arvalid,
    output var logic        m_arready,
    output var logic [31:0] m_rdata,
    output var logic [1:0]  m_rresp,
    output var logic [11:0] m_rid,
    output var logic        m_rlast,
    output var logic        m_rvalid,
    input  var logic        m_rready,

    // --- the core's side: the period and the clock's start, a register
    // read granted (its word the clock after), a register write taken, and
    // CMD_PROD's write
    input  var logic [6:0]  period,
    input  var logic [31:0] rtc_start,
    input  var logic        rd_v,
    input  var logic [7:0]  rd_k,
    output var logic [31:0] rd_word,
    input  var logic        wr_v,
    input  var logic [7:0]  wr_k,
    input  var logic [31:0] wr_data,
    input  var logic        prod_v,
    input  var logic [31:0] prod_data,

    // --- the file device's own, measured by the clock
    output var logic        fd_complete,
    output var logic        int_now,
    output var logic [15:0] dbg_cons,
    output var logic [7:0]  dbg_handles,
    output var logic        dbg_host_we,
    output var logic [3:0]  dbg_host_widx
);

  logic        host_we;
  logic [3:0]  host_widx, host_ridx;
  logic [31:0] host_wdata, host_rdata;

  quux_fd_face #(.IDENT(32'h5146_3133)) face (
      .clk(clk), .rst(rst),
      .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awid(m_awid),
      .s_awvalid(m_awvalid), .s_awready(m_awready),
      .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
      .s_wvalid(m_wvalid), .s_wready(m_wready),
      .s_bresp(m_bresp), .s_bid(m_bid), .s_bvalid(m_bvalid), .s_bready(m_bready),
      .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arid(m_arid),
      .s_arvalid(m_arvalid), .s_arready(m_arready),
      .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rid(m_rid),
      .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
      .host_we(host_we), .host_widx(host_widx), .host_wdata(host_wdata),
      .host_ridx(host_ridx), .host_rdata(host_rdata)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic        rd_built, wr_built, fd_doorbell, fd_enabled, bd_start, kbd_boot, kbd_busy;
  logic [15:0] fd_prod;
  logic [31:0] bd_st_cmd, microseconds;
  logic [27:0] bd_st_clp, bd_st_da;
  logic [63:0] ro_dev;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;
  /* verilator lint_on UNUSEDSIGNAL */

  quux15_devices #(.MAIN_WORDS(MAIN_WORDS)) dev (
      .clk(clk), .rst(mach_rst), .timers_rst(1'b0), .period(period), .rtc_start(rtc_start),
      .rd_v(rd_v), .rd_k(rd_k), .rd_word(rd_word), .rd_built(rd_built),
      .wr_v(wr_v), .wr_k(wr_k), .wr_data(wr_data), .wr_built(wr_built),
      .prod_v(prod_v), .prod_data(prod_data),
      .fd_doorbell(fd_doorbell), .fd_prod(fd_prod), .fd_enabled(fd_enabled),
      .host_we(host_we), .host_widx(host_widx), .host_wdata(host_wdata),
      .host_ridx(host_ridx), .host_rdata(host_rdata), .fd_complete(fd_complete),
      .bd_present(1'b0), .bd_start(bd_start), .bd_st_cmd(bd_st_cmd), .bd_st_clp(bd_st_clp),
      .bd_st_da(bd_st_da), .bd_walking(1'b0), .bd_charge(1'b0), .bd_fin(1'b0),
      .bd_fin_lma(28'd0), .bd_fin_da(29'd0), .bd_fin_past_end(1'b0), .bd_fin_nxm(1'b0),
      .bd_flight(1'b0),
      // The keyboard and the mouse sit still.
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'h7F), .kbd_boot(kbd_boot), .kbd_busy(kbd_busy),
      // The network's cable quiet.
      .chaos_address(16'd0), .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(1'b0), .chaos_rx_word(16'd0), .chaos_rx_done(1'b0), .chaos_rx_bits(13'd0),
      .chaos_rx_crc(1'b0), .chaos_rx_lost(1'b0), .chaos_tx_done(1'b0), .chaos_tx_abort(1'b0),
      .chaos_cbl_busy(1'b0), .chaos_bits(chaos_bits),
      .microseconds(microseconds), .int_now(int_now),
      .snap(1'b0), .ro_k(7'd0), .ro_dev(ro_dev)
  );

  // The index and the count the processor's reads of 165 and 161 are made
  // from.
  assign dbg_cons      = dev.fd_ccons;
  assign dbg_handles   = dev.fd_hopen;
  assign dbg_host_we   = host_we;
  assign dbg_host_widx = host_widx;

endmodule

`default_nettype wire
