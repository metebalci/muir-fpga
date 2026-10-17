// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 16's Ethernet device from both of its sides:
// `rtl/plumbing/quux_ed_face.sv`, the page Linux reaches over the
// processor's port, with revision 16's register-page devices behind it
// (`rtl/machine/quux15_devices.sv` with `ETHERNET`, and so
// `rtl/machine/quux16_ethernet.sv`), as a board's top joins them through the
// core.  The testbench drives the face over AXI through
// `quux-ethernet-device`'s own `qed_face_fabric.c`, and the devices as the
// core drives them: a register read granted, its word the clock after; a
// register write taken; and the held write of 244 or 250, which the core
// gives only once every write before it is answered.  The keyboard, the
// mouse, the network's cable and the file device's host sit still.
//
// **A FEW OF THE DEVICE'S OWN SIGNALS ARE BROUGHT OUT**, beside what the
// processor can read: the sweep, the interrupt as the clock's write leaves
// it, and 244 and 250 as the host's side reads them, so that each landing
// is measured by the clock.

`default_nettype none

module quux16_ethernet_harness #(
    parameter int unsigned MAIN_WORDS = 4096
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

    // --- the core's side: a register read granted (its word the clock
    // after), a register write taken, and the held write
    input  var logic        rd_v,
    input  var logic [7:0]  rd_k,
    output var logic [31:0] rd_word,
    output var logic        rd_built,
    input  var logic        wr_v,
    input  var logic [7:0]  wr_k,
    input  var logic [31:0] wr_data,
    output var logic        wr_built,
    input  var logic        prod_v,
    input  var logic [7:0]  prod_k,
    input  var logic [31:0] prod_data,

    // --- the device's own, measured by the clock
    output var logic        eth_sweep,
    output var logic        int_now,
    output var logic [15:0] eth_tx_prod,
    output var logic [15:0] eth_rx_prod,
    output var logic        fd_doorbell,
    output var logic        dbg_host_we,
    output var logic [4:0]  dbg_host_widx,
    output var logic [15:0] dbg_tx_cons,
    output var logic [15:0] dbg_rx_cons
);

  logic        host_we;
  logic [4:0]  host_widx, host_ridx;
  logic [31:0] host_wdata, host_rdata;

  quux_ed_face face (
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
  logic        fd_enabled, fd_complete, bd_start, kbd_boot, kbd_busy, bow;
  logic [15:0] fd_prod;
  logic [31:0] bd_st_cmd, microseconds, fd_rdata;
  logic [27:0] bd_st_clp, bd_st_da;
  logic [63:0] ro_dev;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;
  /* verilator lint_on UNUSEDSIGNAL */

  quux15_devices #(.MAIN_WORDS(MAIN_WORDS), .ETHERNET(1'b1)) dev (
      .clk(clk), .rst(mach_rst), .timers_rst(1'b0), .period(7'd34), .rtc_start(32'd0),
      .rd_v(rd_v), .rd_k(rd_k), .rd_word(rd_word), .rd_built(rd_built), .rd_release(1'b1),
      .wr_v(wr_v), .wr_k(wr_k), .wr_data(wr_data), .wr_built(wr_built),
      .prod_v(prod_v), .prod_k(prod_k), .prod_data(prod_data),
      .fd_doorbell(fd_doorbell), .fd_prod(fd_prod), .fd_enabled(fd_enabled),
      // The file device's host still.
      .host_we(1'b0), .host_widx(4'd0), .host_wdata(32'd0),
      .host_ridx(4'd2), .host_rdata(fd_rdata), .fd_complete(fd_complete),
      .eth_we(host_we), .eth_widx(host_widx), .eth_wdata(host_wdata), .eth_ridx(host_ridx),
      .eth_rdata(host_rdata), .eth_tx_prod(eth_tx_prod), .eth_rx_prod(eth_rx_prod), .eth_sweep(eth_sweep),
      .bd_present(1'b0), .bd_start(bd_start), .bd_st_cmd(bd_st_cmd), .bd_st_clp(bd_st_clp),
      .bd_st_da(bd_st_da), .bd_walking(1'b0), .bd_charge(1'b0), .bd_fin(1'b0),
      .bd_fin_lma(28'd0), .bd_fin_da(29'd0), .bd_fin_past_end(1'b0), .bd_fin_nxm(1'b0),
      .bd_flight(1'b0),
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'h7F), .kbd_boot(kbd_boot), .kbd_busy(kbd_busy),
      .chaos_address(16'd0), .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(1'b0), .chaos_rx_word(16'd0), .chaos_rx_done(1'b0), .chaos_rx_bits(13'd0),
      .chaos_rx_crc(1'b0), .chaos_rx_lost(1'b0), .chaos_tx_done(1'b0), .chaos_tx_abort(1'b0),
      .chaos_cbl_busy(1'b0), .chaos_rx_start(1'b0), .chaos_rx_stored(12'd0),
      .chaos_rx_store(1'b0), .chaos_bits(chaos_bits),
      .microseconds(microseconds), .int_now(int_now),
      .snap(1'b0), .ro_k(7'd0), .ro_dev(ro_dev), .bow(bow)
  );

  // The host's write each clock, and the indexes the processor's reads of
  // 245 and 251 are made from.
  assign dbg_host_we   = host_we;
  assign dbg_host_widx = host_widx;
  assign dbg_tx_cons   = dev.g_ethernet.eth_regs.tx_cons;
  assign dbg_rx_cons   = dev.g_ethernet.eth_regs.rx_cons;

endmodule

`default_nettype wire
