// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The two things `tb/cadr_probe_tb.cpp` has to ask `rtl/plumbing/xilinx7/cadr_probe.sv`,
// under one top so that Verilator can build them together.
//
// **`u_real` is the probe wired to the machine exactly as `cadr_arty.sv`
// wires it**, and it answers the question that matters: does sample j hold
// what row j of `build/rtl.golden` holds? Nothing about the alignment is
// asserted here or derived on paper --- it is compared against the same
// reference every other check in this repository uses. The boot PROM's first
// memory cycle is at microcycle 535,791, so the first thousand microcycles
// need no stimulus at all: no bus, no stall, no device. That is why this
// harness drives nothing.
//
// **`u_synth` is the same core with the testbench in place of the machine**,
// and it exists for the one property the window above cannot reach. A stall
// is the clock held off, so a stalled microcycle is a long gap between
// qualifying edges with the datapath moving inside it --- `-LOADMD` strobes
// MD while the clock is stopped --- and the sample has to be the *last* value
// before the boundary and not something from the middle of the gap. There is
// no stall in the first thousand microcycles of the boot PROM, so the gap is
// made here instead, and made much wider than the machine's own.
//
// THIS FILE MUST NEVER MOVE TO `rtl/`, for the reason `tb/cadr_arty_stubs.sv`
// gives at length: both Vivado flows read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`.

`default_nettype none

module cadr_probe_harness #(
    parameter string       PROM_HEX   = "build/boot_prom.hex",
    parameter int unsigned REAL_DEPTH = 1024,
    // Small, so that the synthetic side fills, freezes and wraps inside a
    // testbench rather than inside a machine.
    parameter int unsigned SYNTH_DEPTH = 8
) (
    input  var logic clk,
    input  var logic rst,

    // What the machine is doing, for the testbench to count microcycles by.
    output var logic clock_edge,

    // The synthetic side: one port a column, as the probe takes them.
    input  var logic        s_qualify,
    input  var logic [13:0] s_pc,
    input  var logic [47:0] s_ir,
    input  var logic [31:0] s_q, s_a, s_m, s_alu, s_r, s_ob,
    input  var logic [9:0]  s_dc,
    input  var logic [13:0] s_opc,
    input  var logic [31:0] s_st,
    input  var logic [25:0] s_lc,
    input  var logic        s_iwrited, s_nop, s_n_vmaok, s_jcond, s_pcs1,
    input  var logic        s_pcs0,
    input  var logic [13:0] s_lpc,
    input  var logic [31:0] s_md, s_vma,
    input  var logic        s_promdis,

    // One JTAG stimulus, two shift registers. Only one of them is selected at
    // a time in the testbench, which is what a real chain would do.
    input  var logic jtag_drck,
    input  var logic jtag_shift,
    input  var logic jtag_capture,
    input  var logic jtag_tdi,
    input  var logic real_sel,
    input  var logic synth_sel,
    output var logic real_tdo,
    output var logic synth_tdo
);

  logic [13:0] pc, lpc, opc;
  logic [31:0] st, a, m, alu, r, ob, q, vma, md;
  logic [47:0] ir;
  logic [9:0]  dc;
  logic [25:0] lc;
  logic [21:0] phys;
  logic [17:0] ub_addr;
  logic [15:0] ub_rdata;
  logic [2:0]  arb_stage;
  logic [31:0] mem_addr, mem_wdata, dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, wrcyc;
  logic device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, timed_out, mbusy, mbusy_sync;
  logic mem_req, mem_write;
  logic sintr;   // -XBUS.INTR, the machine's own; read by nothing here

  cadr_machine #(
      .PROM_HEX(PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(rst),
      // `device_ack` low is not "no disk controller": the disk's four
      // registers are inside `cadr_machine` and answer for themselves. This
      // port is for a slave that is still outside --- the display, the I/O
      // board --- and there is none.
      // -XBUS.INTR is the machine's own line now --- the display's vertical
      // interrupt ORed with the disk's request, both inside --- and comes out
      // as an observation output.  Nothing here reads it; this harness's
      // program never enables either.
      .sintr_o(sintr),
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
      .con_vma(con_vma), .con_q(con_q),
      .device_ack(1'b0), .device_rdata(32'd0),
      .boards(7'd32),
      .mem_done(1'b0), .mem_rdata(32'd0),
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

  // WIRED AS `cadr_arty.sv` WIRES IT, including the inversion --- the two
  // instantiations are the same instantiation and the check below is only
  // worth anything if they stay so.
  cadr_probe #(
      .DEPTH(REAL_DEPTH)
  ) u_real (
      .clk(clk), .rst(rst), .qualify(clock_edge),
      .pc(pc), .ir(ir), .q(q), .a(a), .m(m), .alu(alu), .r(r), .ob(ob),
      .dc(dc), .opc(opc), .st(st), .lc(lc),
      .iwrited(iwrited), .nop(nop), .n_vmaok(!vmaok), .jcond(jcond),
      .pcs1(pcs1), .pcs0(pcs0),
      .lpc(lpc), .md(md), .vma(vma), .promdis(promdisable),
      .jtag_drck(jtag_drck), .jtag_sel(real_sel),
      .jtag_shift(jtag_shift), .jtag_capture(jtag_capture),
      .jtag_tdi(jtag_tdi), .jtag_tdo(real_tdo)
  );

  cadr_probe #(
      .DEPTH(SYNTH_DEPTH)
  ) u_synth (
      .clk(clk), .rst(rst), .qualify(s_qualify),
      .pc(s_pc), .ir(s_ir), .q(s_q), .a(s_a), .m(s_m), .alu(s_alu),
      .r(s_r), .ob(s_ob), .dc(s_dc), .opc(s_opc), .st(s_st), .lc(s_lc),
      .iwrited(s_iwrited), .nop(s_nop), .n_vmaok(s_n_vmaok),
      .jcond(s_jcond), .pcs1(s_pcs1), .pcs0(s_pcs0),
      .lpc(s_lpc), .md(s_md), .vma(s_vma), .promdis(s_promdis),
      .jtag_drck(jtag_drck), .jtag_sel(synth_sel),
      .jtag_shift(jtag_shift), .jtag_capture(jtag_capture),
      .jtag_tdi(jtag_tdi), .jtag_tdo(synth_tdo)
  );

  // The machine brings out more than the probe takes. Nothing here reads
  // the rest, and saying so is what keeps lint honest about it.
  // The block store's read-back and the disk's two interlock signals, which
  // `cadr_machine` brings out for the pack side and nothing here drives.
  logic [31:0] store_rdata;
  logic        store_miss, ch_active;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit;
  logic [30:0] req_tag;
  logic [4:0]  ch_slot;
  logic        con_gnt, con_ssyn;
  logic [15:0] con_rdata;
  // Page 0's words 7 and 8, which no console on this harness reads: folded
  // below with the rest, the way every other output of `cadr_machine` is.
  logic [31:0] con_vma, con_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, phys, ub_addr, ub_rdata, arb_stage, mem_addr,
                    store_rdata, store_miss, ch_active,
                    req_valid, req_tag, req_post, ch_waiting, ch_slot,
                    ch_wrote, ch_hit,
                    con_gnt, con_ssyn, con_rdata, con_vma, con_q,
                    mem_wdata, dev_wdata, wrcyc, device, dev_rq, dev_write,
                    ub_msyn, ub_ssyn, n_memrq, n_memack, n_memgrant,
                    n_loadmd, rdcyc, nxm, unibus, memstart, timed_out,
                    mbusy, mbusy_sync, mem_req, mem_write, sintr};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
