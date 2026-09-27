// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's revision 9 from both of its sides: `rtl/plumbing/quux_fd_face.sv`,
// the page Linux reaches over the processor's port, with the machine's
// register page behind it (`rtl/machine/quux_feature_page.sv`, which holds
// the real-time clock and the file device), as `cadr_machine.sv` joins them.
// The testbench drives the face over AXI as Linux's server does and the page
// as the processor does, through the same held decode and `-XBUS.RQ` the
// machine gives it, so every rule of the host's side is held against what
// the processor then reads.
//
// The page's other devices are here because the page is: the keyboard and
// the mouse sit still, the clocks and the network ask nothing.
//
// **A FEW OF THE FILE DEVICE'S OWN SIGNALS ARE BROUGHT OUT**, beside what
// the processor can read: the invalidation, the interrupt, and the index the
// processor's reads are made from, so that the order the two orderings
// promise is measured by the tick rather than inferred from a read that may
// fall on either side of it.

`default_nettype none

module quux_fd_face_harness (
    input  var logic        clk,
    // The port's reset, the face's; and the machine's, the page's, which
    // is the board's `mach_rst` and never the port's.
    input  var logic        rst,
    input  var logic        mach_rst,
    input  var logic        xbus_init,

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

    // --- the processor's cycle at the page, as `cadr_machine.sv` gives it
    input  var logic        sel,
    input  var logic [21:0] phys,
    input  var logic        dev_write,
    input  var logic        dev_rq,
    input  var logic [31:0] wdata,
    output var logic        dev_ack,
    output var logic        drives,
    output var logic [31:0] rdata,
    output var logic        irq,

    // --- main memory, and the port's write buffer empty
    input  var logic [22:0] mem_words,
    input  var logic        drained,
    output var logic        fd_invalidate,

    // --- the file device's own, measured by the tick
    output var logic [15:0] dbg_cons,
    output var logic [7:0]  dbg_handles,
    output var logic        dbg_irq,
    output var logic        dbg_host_we,
    output var logic [3:0]  dbg_host_widx
);

  logic        host_we;
  logic [3:0]  host_widx, host_ridx;
  logic [31:0] host_wdata, host_rdata;

  quux_fd_face face (
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
  logic        n_boot_kbd, kbd_busy, err_clear, errstop_we, errstop_d;
  logic        ch_land, ch_wr;
  logic [2:0]  ch_which;
  logic [15:0] ch_wdata;
  logic [13:0] ro_in_state;
  logic [6:0]  ro_in_count;
  logic [23:0] ro_fifo_q;
  logic [47:0] ro_fd_bases, ro_fd_indexes, ro_fd_flags;
  logic        tm_we, reset_devices;
  logic [2:0]  tm_idx;
  logic [23:0] tm_wdata;
  /* verilator lint_on UNUSEDSIGNAL */

  quux_feature_page page (
      .clk          (clk),
      .rst          (mach_rst),
      .xbus_init    (xbus_init),
      .sel          (sel),
      .phys         (phys),
      .dev_write    (dev_write),
      .dev_rq       (dev_rq),
      .wdata        (wdata),
      .dev_ack      (dev_ack),
      .drives       (drives),
      .rdata        (rdata),
      .timer_pending(3'b000),
      .disk_irq     (1'b0),
      .chaos_ireq   (1'b0),
      .tm_we        (tm_we),
      .tm_idx       (tm_idx),
      .tm_wdata     (tm_wdata),
      .tm_rdata     (24'd0),
      .reset_devices(reset_devices),
      .err          (3'b000),
      .err_clear    (err_clear),
      .errstop      (1'b0),
      .errstop_we   (errstop_we),
      .errstop_d    (errstop_d),
      .ch_land      (ch_land),
      .ch_wr        (ch_wr),
      .ch_which     (ch_which),
      .ch_wdata     (ch_wdata),
      .ch_rdata     (16'd0),
      .kbd_strobe   (1'b0),
      .kbd_code     (24'd0),
      .mouse_x      (12'd0),
      .mouse_y      (12'd0),
      .mouse_buttons(3'b000),
      .irq          (irq),
      .n_boot_kbd   (n_boot_kbd),
      .kbd_busy     (kbd_busy),
      .ro_in_state  (ro_in_state),
      .ro_in_count  (ro_in_count),
      .ro_fifo_a    (6'd0),
      .ro_fifo_q    (ro_fifo_q),
      .mem_words    (mem_words),
      .drained      (drained),
      .fd_invalidate(fd_invalidate),
      .host_we      (host_we),
      .host_widx    (host_widx),
      .host_wdata   (host_wdata),
      .host_ridx    (host_ridx),
      .host_rdata   (host_rdata),
      .ro_fd_bases  (ro_fd_bases),
      .ro_fd_indexes(ro_fd_indexes),
      .ro_fd_flags  (ro_fd_flags)
  );

  // The readout's word 8 carries 165 in <31:16> and word 9 the handles in
  // <35:28>: the index and the count the processor's reads are made from.
  assign dbg_cons      = ro_fd_indexes[31:16];
  assign dbg_handles   = ro_fd_flags[35:28];
  assign dbg_irq       = irq;
  assign dbg_host_we   = host_we;
  assign dbg_host_widx = host_widx;

endmodule

`default_nettype wire
