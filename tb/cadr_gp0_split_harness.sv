// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `M_AXI_GP0` as the board has it: the splitter, the four slaves behind it,
// and the I/O board on the far side of the two new faces' seams.
//
// **THE HARNESS IS THE ATTACHMENT, and that is the point.**  What the check
// has to demonstrate is not that `cadr_gp0_split.sv` routes --- routing is
// twenty lines --- but that **every address on the port is answered in both
// directions**, which is a property of the splitter AND of what is wired
// behind it.  A read nothing answers on GP0 does not fault the Arm, it hangs
// both cores at one PC each, measured on this board.  So this instantiates
// the real four: `cadr_disk_pack.sv` on the first page, `cadr_chaos_cable.sv`
// on the second, `cadr_serial_line.sv` on the third and
// `cadr_gp0_default.sv` for the rest of the gigabyte, exactly as
// `boards/arty-z7-20/cadr_arty.sv` does, and the testbench sweeps the window.
//
// Each answers word 0 or word 7 with something only it can answer --- "PACK",
// "CHAO", "SERI", "NONE" --- so which slave took a transaction is READ OFF
// the reply rather than assumed.
//
// **AND `cadr_io_board.sv` IS HERE TOO, WHICH IS WHAT MAKES IT READ-BACK.**
// The two new faces are the far ends of the card's two cables, so the only
// way to hold them to anything is to put the card on the other side and
// carry a frame and a character across in both directions.  The card is
// driven through its Unibus exactly as `tb/cadr_io_board_tb.cpp` drives it,
// and the register faces are reached through the splitter --- so a
// transaction crosses the decode, the AXI3 face and the seam before anything
// is compared.  `build/iob.pass` is what holds the card itself to muir; this
// holds the two halves meeting.
//
// The pack side's own two ports are tied off: its `S_AXI_HP2` master never
// runs, because nothing here commands a move, and `disk_pack.pass` is what
// holds that half of it.  What is exercised here is its GP0 face, which is
// the half this check is about --- including the SLVERR it gives outside its
// own sixteen words, which is a real answer and not a hang.

`default_nettype none

module cadr_gp0_split_harness (
    input  var logic        clk,
    input  var logic        rst,

    // --- `M_AXI_GP0` as the PS would drive it -----------------------------
    input  var logic [31:0] m_awaddr,
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
    input  var logic [31:0] m_araddr,
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

    // --- the card's Unibus, as a master sees it ---------------------------
    input  var logic        ub_msyn,
    input  var logic        ub_write,
    input  var logic [17:0] ub_addr,
    input  var logic [15:0] ub_wdata,
    output var logic        ub_ssyn,
    output var logic [15:0] ub_rdata,
    input  var logic        ub_init,

    // --- what the two faces raise into `IRQ_F2P` --------------------------
    output var logic        chaos_irq,
    output var logic        ser_irq
);

  // ------------------------------------------------------- the four ports
  logic [31:0] p_awaddr, p_wdata, p_araddr, p_rdata;
  logic [3:0]  p_awlen, p_wstrb, p_arlen;
  logic [11:0] p_awid, p_arid, p_bid, p_rid;
  logic        p_awvalid, p_awready, p_wlast, p_wvalid, p_wready;
  logic        p_bvalid, p_bready, p_arvalid, p_arready;
  logic        p_rlast, p_rvalid, p_rready;
  logic [1:0]  p_bresp, p_rresp;

  logic [11:0] c_awaddr, c_araddr;
  logic [31:0] c_wdata, c_rdata;
  logic [3:0]  c_awlen, c_wstrb, c_arlen;
  logic [11:0] c_awid, c_arid, c_bid, c_rid;
  logic        c_awvalid, c_awready, c_wlast, c_wvalid, c_wready;
  logic        c_bvalid, c_bready, c_arvalid, c_arready;
  logic        c_rlast, c_rvalid, c_rready;
  logic [1:0]  c_bresp, c_rresp;

  logic [11:0] l_awaddr, l_araddr;
  logic [31:0] l_wdata, l_rdata;
  logic [3:0]  l_awlen, l_wstrb, l_arlen;
  logic [11:0] l_awid, l_arid, l_bid, l_rid;
  logic        l_awvalid, l_awready, l_wlast, l_wvalid, l_wready;
  logic        l_bvalid, l_bready, l_arvalid, l_arready;
  logic        l_rlast, l_rvalid, l_rready;
  logic [1:0]  l_bresp, l_rresp;

  logic [31:0] d_rdata;
  logic [3:0]  d_arlen;
  logic [11:0] d_awid, d_arid, d_bid, d_rid;
  logic        d_awvalid, d_awready, d_wlast, d_wvalid, d_wready;
  logic        d_bvalid, d_bready, d_arvalid, d_arready;
  logic        d_rlast, d_rvalid, d_rready;
  logic [1:0]  d_bresp, d_rresp;

  cadr_gp0_split u_split (
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
      .pack_awaddr(p_awaddr), .pack_awlen(p_awlen), .pack_awid(p_awid),
      .pack_awvalid(p_awvalid), .pack_awready(p_awready),
      .pack_wdata(p_wdata), .pack_wstrb(p_wstrb), .pack_wlast(p_wlast),
      .pack_wvalid(p_wvalid), .pack_wready(p_wready),
      .pack_bresp(p_bresp), .pack_bid(p_bid), .pack_bvalid(p_bvalid),
      .pack_bready(p_bready),
      .pack_araddr(p_araddr), .pack_arlen(p_arlen), .pack_arid(p_arid),
      .pack_arvalid(p_arvalid), .pack_arready(p_arready),
      .pack_rdata(p_rdata), .pack_rresp(p_rresp), .pack_rid(p_rid),
      .pack_rlast(p_rlast), .pack_rvalid(p_rvalid), .pack_rready(p_rready),
      .chaos_awaddr(c_awaddr), .chaos_awlen(c_awlen), .chaos_awid(c_awid),
      .chaos_awvalid(c_awvalid), .chaos_awready(c_awready),
      .chaos_wdata(c_wdata), .chaos_wstrb(c_wstrb), .chaos_wlast(c_wlast),
      .chaos_wvalid(c_wvalid), .chaos_wready(c_wready),
      .chaos_bresp(c_bresp), .chaos_bid(c_bid), .chaos_bvalid(c_bvalid),
      .chaos_bready(c_bready),
      .chaos_araddr(c_araddr), .chaos_arlen(c_arlen), .chaos_arid(c_arid),
      .chaos_arvalid(c_arvalid), .chaos_arready(c_arready),
      .chaos_rdata(c_rdata), .chaos_rresp(c_rresp), .chaos_rid(c_rid),
      .chaos_rlast(c_rlast), .chaos_rvalid(c_rvalid), .chaos_rready(c_rready),
      .ser_awaddr(l_awaddr), .ser_awlen(l_awlen), .ser_awid(l_awid),
      .ser_awvalid(l_awvalid), .ser_awready(l_awready),
      .ser_wdata(l_wdata), .ser_wstrb(l_wstrb), .ser_wlast(l_wlast),
      .ser_wvalid(l_wvalid), .ser_wready(l_wready),
      .ser_bresp(l_bresp), .ser_bid(l_bid), .ser_bvalid(l_bvalid),
      .ser_bready(l_bready),
      .ser_araddr(l_araddr), .ser_arlen(l_arlen), .ser_arid(l_arid),
      .ser_arvalid(l_arvalid), .ser_arready(l_arready),
      .ser_rdata(l_rdata), .ser_rresp(l_rresp), .ser_rid(l_rid),
      .ser_rlast(l_rlast), .ser_rvalid(l_rvalid), .ser_rready(l_rready),
      .dflt_awid(d_awid), .dflt_awvalid(d_awvalid), .dflt_awready(d_awready),
      .dflt_wlast(d_wlast), .dflt_wvalid(d_wvalid), .dflt_wready(d_wready),
      .dflt_bresp(d_bresp), .dflt_bid(d_bid), .dflt_bvalid(d_bvalid),
      .dflt_bready(d_bready),
      .dflt_arlen(d_arlen), .dflt_arid(d_arid), .dflt_arvalid(d_arvalid),
      .dflt_arready(d_arready),
      .dflt_rdata(d_rdata), .dflt_rresp(d_rresp), .dflt_rid(d_rid),
      .dflt_rlast(d_rlast), .dflt_rvalid(d_rvalid), .dflt_rready(d_rready)
  );

  // ------------------------------------------------- the pack side, page 0
  //
  // Its GP0 face is what this check reaches; its `S_AXI_HP2` master and its
  // block-store seam are tied off, nothing here commanding a move, and
  // `disk_pack.pass` is what holds them.
  logic [31:0] pk_m_awaddr, pk_m_araddr;
  logic [3:0]  pk_m_awlen, pk_m_arlen;
  logic [1:0]  pk_m_awsize, pk_m_arsize, pk_m_awburst, pk_m_arburst;
  logic        pk_m_awvalid, pk_m_wlast, pk_m_wvalid, pk_m_bready;
  logic        pk_m_arvalid, pk_m_rready;
  logic [63:0] pk_m_wdata;
  logic [7:0]  pk_m_wstrb;
  logic        pk_store_we, pk_moving;
  logic [4:0]  pk_store_slot, pk_moving_slot;
  logic [8:0]  pk_store_addr;
  logic [31:0] pk_store_wdata;
  logic        pk_deny, pk_irq;
  logic [7:0]  pk_present, pk_read_only;
  logic        pk_timed;

  cadr_disk_pack u_pack (
      .clk(clk), .rst(rst),
      .s_awaddr(p_awaddr), .s_awlen(p_awlen), .s_awid(p_awid),
      .s_awvalid(p_awvalid), .s_awready(p_awready),
      .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wlast(p_wlast),
      .s_wvalid(p_wvalid), .s_wready(p_wready),
      .s_bresp(p_bresp), .s_bid(p_bid), .s_bvalid(p_bvalid), .s_bready(p_bready),
      .s_araddr(p_araddr), .s_arlen(p_arlen), .s_arid(p_arid),
      .s_arvalid(p_arvalid), .s_arready(p_arready),
      .s_rdata(p_rdata), .s_rresp(p_rresp), .s_rid(p_rid),
      .s_rlast(p_rlast), .s_rvalid(p_rvalid), .s_rready(p_rready),
      .m_awaddr(pk_m_awaddr), .m_awlen(pk_m_awlen), .m_awsize(pk_m_awsize),
      .m_awburst(pk_m_awburst), .m_awvalid(pk_m_awvalid), .m_awready(1'b0),
      .m_wdata(pk_m_wdata), .m_wstrb(pk_m_wstrb), .m_wlast(pk_m_wlast),
      .m_wvalid(pk_m_wvalid), .m_wready(1'b0),
      .m_bresp(2'b00), .m_bvalid(1'b0), .m_bready(pk_m_bready),
      .m_araddr(pk_m_araddr), .m_arlen(pk_m_arlen), .m_arsize(pk_m_arsize),
      .m_arburst(pk_m_arburst), .m_arvalid(pk_m_arvalid), .m_arready(1'b0),
      .m_rdata(64'd0), .m_rresp(2'b00), .m_rlast(1'b0), .m_rvalid(1'b0),
      .m_rready(pk_m_rready),
      .store_we(pk_store_we), .store_slot(pk_store_slot),
      .store_addr(pk_store_addr), .store_wdata(pk_store_wdata),
      .store_rdata(32'd0), .store_miss(1'b0), .ch_active(1'b0),
      .moving(pk_moving), .moving_slot(pk_moving_slot),
      .req_valid(1'b0), .req_tag(31'd0), .req_post(1'b0),
      .ch_waiting(1'b0), .ch_slot(5'd0), .ch_wrote(1'b0), .ch_hit(1'b0),
      .deny(pk_deny), .irq(pk_irq),
      .drive_present(pk_present), .drive_read_only(pk_read_only),
      .drive_timed(pk_timed)
  );

  // --------------------------------------------- the Chaosnet cable, page 1
  logic [15:0] chaos_address, chaos_tx_word, chaos_rx_word, chaos_csr;
  logic [8:0]  chaos_tx_len;
  logic [12:0] chaos_rx_bits;
  logic [11:0] chaos_bits;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic        chaos_rx_valid, chaos_rx_done, chaos_rx_crc;
  logic        chaos_tx_done, chaos_tx_abort, chaos_cbl_busy;

  cadr_chaos_cable u_chaos (
      .clk(clk), .rst(rst),
      .s_awaddr(c_awaddr), .s_awlen(c_awlen), .s_awid(c_awid),
      .s_awvalid(c_awvalid), .s_awready(c_awready),
      .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wlast(c_wlast),
      .s_wvalid(c_wvalid), .s_wready(c_wready),
      .s_bresp(c_bresp), .s_bid(c_bid), .s_bvalid(c_bvalid), .s_bready(c_bready),
      .s_araddr(c_araddr), .s_arlen(c_arlen), .s_arid(c_arid),
      .s_arvalid(c_arvalid), .s_arready(c_arready),
      .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rid(c_rid),
      .s_rlast(c_rlast), .s_rvalid(c_rvalid), .s_rready(c_rready),
      .chaos_address(chaos_address),
      .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word),
      .chaos_tx_clear(chaos_tx_clear), .chaos_reset(chaos_reset),
      .chaos_csr(chaos_csr),
      .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word),
      .chaos_rx_done(chaos_rx_done), .chaos_rx_bits(chaos_rx_bits),
      .chaos_rx_crc(chaos_rx_crc),
      .chaos_tx_done(chaos_tx_done), .chaos_tx_abort(chaos_tx_abort),
      .chaos_cbl_busy(chaos_cbl_busy),
      .irq(chaos_irq)
  );

  // ------------------------------------------------ the serial line, page 2
  logic        ser_reset, ser_tx_strobe, ser_tx_take, ser_tx_done;
  logic        ser_rx_strobe, ser_plugged;
  logic [7:0]  ser_mode1, ser_mode2, ser_cmd, ser_status;
  logic [7:0]  ser_tx_data, ser_rx_data;

  cadr_serial_line u_serial (
      .clk(clk), .rst(rst),
      .s_awaddr(l_awaddr), .s_awlen(l_awlen), .s_awid(l_awid),
      .s_awvalid(l_awvalid), .s_awready(l_awready),
      .s_wdata(l_wdata), .s_wstrb(l_wstrb), .s_wlast(l_wlast),
      .s_wvalid(l_wvalid), .s_wready(l_wready),
      .s_bresp(l_bresp), .s_bid(l_bid), .s_bvalid(l_bvalid), .s_bready(l_bready),
      .s_araddr(l_araddr), .s_arlen(l_arlen), .s_arid(l_arid),
      .s_arvalid(l_arvalid), .s_arready(l_arready),
      .s_rdata(l_rdata), .s_rresp(l_rresp), .s_rid(l_rid),
      .s_rlast(l_rlast), .s_rvalid(l_rvalid), .s_rready(l_rready),
      .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
      .ser_cmd(ser_cmd), .ser_status(ser_status),
      .ser_tx_strobe(ser_tx_strobe), .ser_tx_data(ser_tx_data),
      .ser_tx_take(ser_tx_take), .ser_tx_done(ser_tx_done),
      .ser_rx_strobe(ser_rx_strobe), .ser_rx_data(ser_rx_data),
      .ser_plugged(ser_plugged),
      .irq(ser_irq)
  );

  // ------------------------------------------------- the rest of the window
  cadr_gp0_default u_dflt (
      .clk(clk), .rst(rst),
      .s_awvalid(d_awvalid), .s_awid(d_awid), .s_awready(d_awready),
      .s_wlast(d_wlast), .s_wvalid(d_wvalid), .s_wready(d_wready),
      .s_bresp(d_bresp), .s_bid(d_bid), .s_bvalid(d_bvalid), .s_bready(d_bready),
      .s_arlen(d_arlen), .s_arid(d_arid), .s_arvalid(d_arvalid),
      .s_arready(d_arready),
      .s_rdata(d_rdata), .s_rresp(d_rresp), .s_rid(d_rid),
      .s_rlast(d_rlast), .s_rvalid(d_rvalid), .s_rready(d_rready)
  );

  // ----------------------------------------------------- and the card itself
  logic [7:0]  iob_vector, iob_csr_face;
  logic [11:0] iob_mouse_x, iob_mouse_y;
  logic [15:0] iob_interval;
  logic        iob_intr, iob_audio, iob_clock_ready;

  cadr_io_board u_iob (
      .clk(clk), .rst(rst),
      .ub_msyn(ub_msyn), .ub_write(ub_write), .ub_addr(ub_addr),
      .ub_wdata(ub_wdata), .ub_ssyn(ub_ssyn), .ub_rdata(ub_rdata),
      .ub_init(ub_init),
      // No keyboard and no mouse on this check: the card's own is
      // `build/iob.pass`, and what is held here is the two cables.
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'h7F),
      .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
      .ser_cmd(ser_cmd), .ser_tx_strobe(ser_tx_strobe),
      .ser_tx_data(ser_tx_data), .ser_tx_take(ser_tx_take),
      .ser_tx_done(ser_tx_done), .ser_rx_strobe(ser_rx_strobe),
      .ser_rx_data(ser_rx_data), .ser_plugged(ser_plugged),
      .ser_status(ser_status),
      .chaos_address(chaos_address), .chaos_tx_go(chaos_tx_go),
      .chaos_tx_len(chaos_tx_len), .chaos_tx_valid(chaos_tx_valid),
      .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word),
      .chaos_rx_done(chaos_rx_done), .chaos_rx_bits(chaos_rx_bits),
      .chaos_rx_crc(chaos_rx_crc), .chaos_tx_done(chaos_tx_done),
      .chaos_tx_abort(chaos_tx_abort), .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits(chaos_bits),
      .intr_request(iob_intr), .intr_vector(iob_vector), .audio(iob_audio),
      .csr_face(iob_csr_face), .mouse_x(iob_mouse_x), .mouse_y(iob_mouse_y),
      .clock_ready(iob_clock_ready), .interval(iob_interval)
  );

  // What no part of this check reads: the pack side's idle master and store
  // seam, and the card's keyboard, mouse, clocks and interrupt, each of
  // which has a check of its own.  Folded rather than left dangling, so
  // that lint's bit granularity stays sharp here as it is in the modules.
  logic unused_h;
  assign unused_h = ^{pk_m_awaddr, pk_m_awlen, pk_m_awsize, pk_m_awburst,
                      pk_m_awvalid, pk_m_wdata, pk_m_wstrb, pk_m_wlast,
                      pk_m_wvalid, pk_m_bready, pk_m_araddr, pk_m_arlen,
                      pk_m_arsize, pk_m_arburst, pk_m_arvalid, pk_m_rready,
                      pk_store_we, pk_store_slot, pk_store_addr,
                      pk_store_wdata, pk_moving, pk_moving_slot, pk_deny,
                      pk_irq, pk_present, pk_read_only, pk_timed,
                      chaos_bits, iob_vector, iob_csr_face, iob_mouse_x,
                      iob_mouse_y, iob_interval, iob_intr, iob_audio,
                      iob_clock_ready};

endmodule

`default_nettype wire
