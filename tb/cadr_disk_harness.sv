// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk controller with its pack side underneath it.
//
// `rtl/cadr_disk_controller.sv` is the controller --- the register face, the
// drive, the channel, the track --- and `rtl/cadr_disk_pack.sv` is what fills
// its block store: the block's address written over `M_AXI_GP0`, the master on
// `S_AXI_HP2` that fetches the record and writes it back.  The seam between
// them is 260 words a slot and a tag, and until this harness the testbench
// drove it directly from the reference trace's `BLK` rows.  Now nothing does:
// the store is reachable only through the two AXI faces this brings out, and
// the drive's presence, its read-only switch and whether its time is charged
// are register bits Linux writes, here written by the testbench over the same
// GP0 face.
//
// IT IS IN `tb/` FOR THE REASON `tb/cadr_arty_stubs.sv` GIVES.  Both Vivado
// scripts read `[glob rtl/*.sv]`, so a wiring harness in `rtl/` would join the
// bitstream.  `rtl/cadr_arty.sv`'s `g_ddr` wires the same two modules the same
// way, with `cadr_ps7.sv` on the far end of both faces.
//
// AND IT IS A HARNESS AND NOT THE THING CHECKED.  Two checks build it:
// `disk`, the reference trace, whose records are aimed at the controller; and
// `disk_pack`, a property check, whose records are aimed at the pack side.
// What the harness can get wrong is a crossing in its own wiring --- and the
// top level can get the same one, which `build/arty.pass`'s `DDR=1` lint is
// for.
//
// `store_miss` and `ch_active` are brought out as well as read back through
// the pack side's status word, because `tb/cadr_disk_tb.cpp` requires the
// first low at every tick and waits on the second at every START, and neither
// is a thing a bus cycle should be spent on in a testbench that is placing
// rows on a 5 ns grid.

`default_nettype none

module cadr_disk_harness #(
    parameter int unsigned SLOTS = 24
) (
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        xbus_init,

    // --- the Xbus slave face, as `cadr_disk_controller` has it ----------
    input  var logic        sel,
    input  var logic        dev_rq,
    input  var logic        dev_write,
    input  var logic [21:0] phys,
    input  var logic [31:0] wdata,
    output var logic        dev_ack,
    output var logic [31:0] rdata,
    output var logic        drives,

    // --- the memory channel, the second master on the Xbus ---------------
    output var logic        ch_req,
    output var logic        ch_write,
    output var logic [21:0] ch_addr,
    output var logic [31:0] ch_wdata,
    input  var logic        ch_done,
    input  var logic        ch_nxm,
    input  var logic [31:0] ch_rdata,
    output var logic        ch_active,
    output var logic        store_miss,
    // The request path, brought out beside the two above for the same
    // reason: `tb/cadr_disk_tb.cpp` requires no request at any tick of the
    // trace, and `tb/cadr_disk_pack_tb.cpp` watches the wait tick by tick.
    output var logic        req_valid,
    output var logic [30:0] req_tag,
    output var logic        ch_waiting,
    output var logic        irq,

    // --- M_AXI_GP0: the PS is the master, 32 bits -------------------------
    input  var logic [31:0] gp0_awaddr,
    input  var logic [3:0]  gp0_awlen,
    input  var logic [11:0] gp0_awid,
    input  var logic        gp0_awvalid,
    output var logic        gp0_awready,
    input  var logic [31:0] gp0_wdata,
    input  var logic [3:0]  gp0_wstrb,
    input  var logic        gp0_wlast,
    input  var logic        gp0_wvalid,
    output var logic        gp0_wready,
    output var logic [1:0]  gp0_bresp,
    output var logic [11:0] gp0_bid,
    output var logic        gp0_bvalid,
    input  var logic        gp0_bready,
    input  var logic [31:0] gp0_araddr,
    input  var logic [3:0]  gp0_arlen,
    input  var logic [11:0] gp0_arid,
    input  var logic        gp0_arvalid,
    output var logic        gp0_arready,
    output var logic [31:0] gp0_rdata,
    output var logic [1:0]  gp0_rresp,
    output var logic [11:0] gp0_rid,
    output var logic        gp0_rlast,
    output var logic        gp0_rvalid,
    input  var logic        gp0_rready,

    // --- S_AXI_HP2: the pack side is the master, 64 bits ------------------
    output var logic [31:0] hp2_awaddr,
    output var logic [3:0]  hp2_awlen,
    output var logic [1:0]  hp2_awsize,
    output var logic [1:0]  hp2_awburst,
    output var logic        hp2_awvalid,
    input  var logic        hp2_awready,
    output var logic [63:0] hp2_wdata,
    output var logic [7:0]  hp2_wstrb,
    output var logic        hp2_wlast,
    output var logic        hp2_wvalid,
    input  var logic        hp2_wready,
    input  var logic [1:0]  hp2_bresp,
    input  var logic        hp2_bvalid,
    output var logic        hp2_bready,
    output var logic [31:0] hp2_araddr,
    output var logic [3:0]  hp2_arlen,
    output var logic [1:0]  hp2_arsize,
    output var logic [1:0]  hp2_arburst,
    output var logic        hp2_arvalid,
    input  var logic        hp2_arready,
    input  var logic [63:0] hp2_rdata,
    input  var logic [1:0]  hp2_rresp,
    input  var logic        hp2_rlast,
    input  var logic        hp2_rvalid,
    output var logic        hp2_rready
);

  // The seam, and the drive.
  logic        store_we;
  logic [4:0]  store_slot;
  logic [8:0]  store_addr;
  logic [31:0] store_wdata, store_rdata;
  logic [7:0]  drive_present, drive_read_only;
  logic        drive_timed;
  logic        store_busy;
  logic [4:0]  store_busy_slot, ch_slot;
  logic        req_post, ch_wrote, ch_hit, deny;

  cadr_disk_controller #(
      .SLOTS(SLOTS)
  ) u_disk (
      .clk(clk), .rst(rst), .xbus_init(xbus_init),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed),
      .sel(sel), .dev_rq(dev_rq), .dev_write(dev_write), .phys(phys),
      .wdata(wdata), .dev_ack(dev_ack), .rdata(rdata), .drives(drives),
      .store_we(store_we), .store_slot(store_slot), .store_addr(store_addr),
      .store_wdata(store_wdata), .store_rdata(store_rdata),
      .store_miss(store_miss),
      .ch_req(ch_req), .ch_write(ch_write), .ch_addr(ch_addr),
      .ch_wdata(ch_wdata), .ch_done(ch_done), .ch_nxm(ch_nxm),
      .ch_rdata(ch_rdata), .ch_active(ch_active), .store_busy(store_busy),
      .store_busy_slot(store_busy_slot),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .store_deny(deny), .ch_slot_o(ch_slot),
      .ch_wrote(ch_wrote), .ch_hit(ch_hit)
  );

  cadr_disk_pack #(
      .SLOTS(SLOTS)
  ) u_pack (
      .clk(clk), .rst(rst),
      .s_awaddr(gp0_awaddr), .s_awlen(gp0_awlen), .s_awid(gp0_awid),
      .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
      .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
      .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
      .s_bresp(gp0_bresp), .s_bid(gp0_bid), .s_bvalid(gp0_bvalid),
      .s_bready(gp0_bready),
      .s_araddr(gp0_araddr), .s_arlen(gp0_arlen), .s_arid(gp0_arid),
      .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
      .s_rdata(gp0_rdata), .s_rresp(gp0_rresp), .s_rid(gp0_rid),
      .s_rlast(gp0_rlast), .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
      .m_awaddr(hp2_awaddr), .m_awlen(hp2_awlen), .m_awsize(hp2_awsize),
      .m_awburst(hp2_awburst), .m_awvalid(hp2_awvalid),
      .m_awready(hp2_awready),
      .m_wdata(hp2_wdata), .m_wstrb(hp2_wstrb), .m_wlast(hp2_wlast),
      .m_wvalid(hp2_wvalid), .m_wready(hp2_wready),
      .m_bresp(hp2_bresp), .m_bvalid(hp2_bvalid), .m_bready(hp2_bready),
      .m_araddr(hp2_araddr), .m_arlen(hp2_arlen), .m_arsize(hp2_arsize),
      .m_arburst(hp2_arburst), .m_arvalid(hp2_arvalid),
      .m_arready(hp2_arready),
      .m_rdata(hp2_rdata), .m_rresp(hp2_rresp), .m_rlast(hp2_rlast),
      .m_rvalid(hp2_rvalid), .m_rready(hp2_rready),
      .store_we(store_we), .store_slot(store_slot), .store_addr(store_addr),
      .store_wdata(store_wdata), .store_rdata(store_rdata),
      .store_miss(store_miss), .ch_active(ch_active), .moving(store_busy),
      .moving_slot(store_busy_slot),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit), .deny(deny), .irq(irq),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed)
  );

endmodule

`default_nettype wire
