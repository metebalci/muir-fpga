// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_mem_count` with the machine in front of it and the port behind it.
//
// The tally's claim is not about a counter.  It is "the number a debugger
// reads out of EMIO is the number of transactions the processing system
// answered, and reads zero when it answered none" --- and that claim has the
// machine, the bridge, the adapter and the widening in it.  So the check has
// them in it: this wires them exactly as `rtl/cadr_arty.sv`'s `g_ddr` does
// and brings out the 64-bit AXI3 port `cadr_ps7.sv` would be on the far end
// of, together with the sixty-four EMIO bits the tally puts out and the
// machine's own request.
//
// IT IS IN `tb/` FOR THE REASON `tb/cadr_arty_stubs.sv` GIVES.  Both Vivado
// scripts read `[glob rtl/*.sv]`, so a wiring harness in `rtl/` would join
// the bitstream --- a second copy of the memory path, in the synthesised
// design, that nothing on the board would ever reach.
//
// **`hp0_aresetn` IS AN INPUT HERE AND IT IS THE POINT OF THE SECOND
// CONFIGURATION.**  On the board it comes out of the PS when software writes
// LVL_SHFTR_EN, and until then `S_AXI_HP0` answers nothing at all.  Held low,
// this harness is a board whose port is dead: the machine still runs, still
// reaches its 512 main-memory cycles and still times every one of them out,
// and the tally must read 512 asked and NOTHING answered.  That is the
// reading the whole instrument exists to make possible, and a counter of the
// fabric's own intentions would read 256 and 256 there.
//
// AND IT IS SYNCHRONISED IN, three stages, exactly as the top level does it:
// the release is asynchronous to this clock by construction.
//
// The mutations are aimed at `rtl/cadr_mem_count.sv`; everything else here is
// in the runner's `extra`, having checks of its own.

`default_nettype none

module cadr_mem_count_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic clk,
    input  var logic rst,

    // The port's reset, out of the processing system on the board.
    input  var logic hp0_aresetn,

    // What the machine is doing, for the testbench to count microcycles and
    // requests by.  `mem_req` is here so that the testbench can say "512
    // cycles were asked for and none was answered" and mean two independent
    // measurements: the tally's own `asked_*`, and this.
    output var logic        clock_edge,
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    output var logic        timed_out,
    output var logic [13:0] pc,

    // The tally, as the sixty-four EMIO GPIO bits a debugger reads --- not as
    // four numbers, because the packing is part of what has to be right.
    output var logic [63:0] gpio,

    // The port's side: AXI3, 64 bits, one beat.  `S_AXI_HP0` on the board.
    output var logic [31:0] hp0_awaddr,
    output var logic [3:0]  hp0_awlen,
    output var logic [1:0]  hp0_awsize,
    output var logic [1:0]  hp0_awburst,
    output var logic        hp0_awvalid,
    input  var logic        hp0_awready,
    output var logic [63:0] hp0_wdata,
    output var logic [7:0]  hp0_wstrb,
    output var logic        hp0_wlast,
    output var logic        hp0_wvalid,
    input  var logic        hp0_wready,
    input  var logic [1:0]  hp0_bresp,
    input  var logic        hp0_bvalid,
    output var logic        hp0_bready,
    output var logic [31:0] hp0_araddr,
    output var logic [3:0]  hp0_arlen,
    output var logic [1:0]  hp0_arsize,
    output var logic [1:0]  hp0_arburst,
    output var logic        hp0_arvalid,
    input  var logic        hp0_arready,
    input  var logic [63:0] hp0_rdata,
    input  var logic [1:0]  hp0_rresp,
    input  var logic        hp0_rlast,
    input  var logic        hp0_rvalid,
    output var logic        hp0_rready
);

  logic [13:0] lpc, opc;
  logic [31:0] st, a, m, alu, r, ob, q, vma, md;
  logic [47:0] ir;
  logic [9:0]  dc;
  logic [25:0] lc;
  logic [21:0] phys;
  logic [17:0] ub_addr;
  logic [15:0] ub_rdata;
  logic [2:0]  arb_stage;
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, wrcyc;
  logic device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, mbusy, mbusy_sync;

  logic        mem_done, mem_error;
  logic [31:0] mem_rdata;

  // The DDR=1 board's configuration exactly: no interrupt, no Xbus device,
  // 32 boards of memory declared.
  cadr_machine #(
      .PROM_HEX(PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(rst),
      // `device_ack` low is not "no disk controller": the disk's four
      // registers are inside `cadr_machine` and answer for themselves. This
      // port is for a slave that is still outside --- the display, the I/O
      // board --- and there is none.
      .sintr(1'b0),
      // No drive on the disk's cable: this harness is the boot PROM, which
      // polls the status register and never writes a command.
      .drive_present(8'd0), .drive_read_only(8'd0), .drive_timed(1'b0),
      .store_we(1'b0), .store_slot(5'd0), .store_addr(9'd0), .store_wdata(32'd0),
      .store_rdata(store_rdata), .store_miss(store_miss), .ch_active(ch_active),
      .store_busy(1'b0), .store_busy_slot(5'd0), .store_deny(1'b0),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit),
      // The console's Unibus port, tied off: `con_req` and `con_msyn` low
      // and the whole of it folds, as `cadr_machine`'s own port list says.
      .con_req(1'b0), .con_msyn(1'b0), .con_write(1'b0),
      .con_addr(18'd0), .con_wdata(16'd0),
      .con_gnt(con_gnt), .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      .device_ack(1'b0), .device_rdata(32'd0),
      .boards(7'd32),
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      .pc(pc), .lpc(lpc), .opc(opc), .st(st), .ir(ir), .a(a), .m(m),
      .alu(alu), .r(r), .ob(ob), .q(q), .dc(dc), .lc(lc), .vma(vma),
      .md(md), .vmaok(vmaok), .jcond(jcond), .nop(nop), .pcs1(pcs1),
      .pcs0(pcs0), .iwrited(iwrited), .clock_edge(clock_edge),
      .wrcyc(wrcyc), .device(device), .dev_rq(dev_rq),
      .dev_write(dev_write), .dev_wdata(dev_wdata),
      .phys(phys), .promdisable(promdisable),
      .ub_msyn(ub_msyn), .ub_ssyn_o(ub_ssyn), .arb_stage(arb_stage),
      .n_memrq_o(n_memrq), .n_memack_o(n_memack),
      .n_memgrant_o(n_memgrant), .mbusy_o(mbusy), .mbusy_sync_o(mbusy_sync),
      .ub_addr_o(ub_addr),
      .ub_rdata_o(ub_rdata), .n_loadmd_o(n_loadmd), .rdcyc_o(rdcyc),
      .nxm(nxm), .unibus(unibus), .memstart(memstart),
      .timed_out(timed_out), .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata)
  );

  // The port's reset, synchronised in as the top level synchronises it.
  logic [2:0] port_rst_sync;
  always_ff @(posedge clk) begin
    port_rst_sync <= {port_rst_sync[1:0], hp0_aresetn};
  end

  logic axi_rst;
  assign axi_rst = rst || !port_rst_sync[2];

  // The adapter's AXI4 side, 32 bits wide.
  logic [31:0] awaddr, araddr, wdata, rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [3:0]  wstrb;

  cadr_axi_master u_axi (
      .clk(clk), .rst(axi_rst),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(mem_error),
      .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(hp0_awburst), .m_axi_awvalid(hp0_awvalid),
      .m_axi_awready(hp0_awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(hp0_wlast),
      .m_axi_wvalid(hp0_wvalid), .m_axi_wready(hp0_wready),
      .m_axi_bresp(hp0_bresp), .m_axi_bvalid(hp0_bvalid),
      .m_axi_bready(hp0_bready),
      .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
      .m_axi_arburst(hp0_arburst), .m_axi_arvalid(hp0_arvalid),
      .m_axi_arready(hp0_arready),
      .m_axi_rdata(rdata), .m_axi_rresp(hp0_rresp), .m_axi_rlast(hp0_rlast),
      .m_axi_rvalid(hp0_rvalid), .m_axi_rready(hp0_rready)
  );

  cadr_axi_widen u_widen (
      .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
      .s_wdata(wdata), .s_wstrb(wstrb),
      .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
      .s_rdata(rdata),
      .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize),
      .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb),
      .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize),
      .m_rdata(hp0_rdata)
  );

  // WIRED AS `cadr_arty.sv` WIRES IT, `rst` and not `axi_rst`, and the port's
  // own answers and not the adapter's intentions. The two instantiations are
  // the same instantiation and this check is only worth anything if they stay
  // so.
  cadr_mem_count u_count (
      .clk(clk), .rst(rst),
      .req(mem_req), .req_write(mem_write),
      .bvalid(hp0_bvalid), .bready(hp0_bready),
      .rvalid(hp0_rvalid), .rready(hp0_rready), .rlast(hp0_rlast),
      .gpio(gpio)
  );

  // The machine brings out more than anything here reads, and saying so is
  // what keeps lint honest about it.
  // The block store's read-back and the disk's two interlock signals, which
  // `cadr_machine` brings out for the pack side and nothing here drives.
  logic [31:0] store_rdata;
  logic        store_miss, ch_active;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit;
  logic [30:0] req_tag;
  logic [4:0]  ch_slot;
  logic        con_gnt, con_ssyn;
  logic [15:0] con_rdata;
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, lpc, opc, st, a, m, alu, r, ob, q, ir, dc, lc, vma,
                    store_rdata, store_miss, ch_active,
                    req_valid, req_tag, req_post, ch_waiting, ch_slot,
                    ch_wrote, ch_hit,
                    con_gnt, con_ssyn, con_rdata,
                    md, phys, ub_addr, ub_rdata, arb_stage, dev_wdata,
                    vmaok, jcond, nop, pcs1, pcs0, iwrited, wrcyc, device,
                    dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn,
                    n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm,
                    unibus, memstart, mbusy, mbusy_sync, mem_error};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
