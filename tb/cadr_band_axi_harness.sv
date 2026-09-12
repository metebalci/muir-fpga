// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE WHOLE PATH FROM THE MICROCODE TO THE 64-BIT BEAT, WITH THE DISK SEAM
// BROUGHT OUT SO THAT A REAL PROGRAM CAN RUN THROUGH IT.
//
// WHAT THIS EXISTS FOR.  CLAUDE.md's account of the board's page-hash-table
// word ends with a bounded suspect list.  `make hash-watch` runs `cadr_machine`
// from reset off a real pack with a modelled DDR and reaches 171,000,000
// microcycles without the board's fingerprint, so the defect is not in
// `rtl/machine/`.  What that harness replaces with a model is what is left:
// between `cadr_machine`'s `mem_*` port and the DRAM the board has
// `cadr_axi_master`, `cadr_axi_widen`, the PS7 and the DDR3 controller.
//
// `tb/cadr_mem_count_harness.sv` and `tb/cadr_bus_audit_harness.sv` already
// wire those three modules together, and both are deliberately kept to MIT's
// boot PROM with NO DRIVE ON THE CABLE --- 512 identity memory cycles, no
// channel, no pack.  So the composition has never carried a real program and
// has never had a second master on it.  **This harness is those three modules
// with the disk seam brought out as well**, which is what lets the boot PROM
// reach the pack, the channel run as the second Xbus master, and the band's
// own microcode load cross the widening a word at a time.
//
// IT IS IN `tb/` FOR THE REASON `tb/cadr_arty_stubs.sv` GIVES.  Both Vivado
// scripts read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`, so a
// wiring harness in `rtl/` would join the bitstream --- a second copy of the
// memory path, in the synthesised design, that nothing on the board would ever
// reach.
//
// **THE WIRING IS `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr` EXACTLY**, and
// this check is only worth anything if it stays so:  `cadr_machine`'s
// `mem_req`/`mem_write`/`mem_addr`/`mem_wdata` into `cadr_axi_master`, its
// 32-bit AXI4 side into `cadr_axi_widen`, and the widening's 64-bit AXI3 side
// out as the port `S_AXI_HP0` is the far end of.  No port reset is brought out
// here: a dead port is `tb/cadr_mem_count_harness.sv`'s question, and a dead
// port issues no transaction at all, which is the one configuration everything
// this harness is for has nothing to say about.
//
// **WHAT IS BROUGHT OUT AND WHY EACH ONE.**
//
//   The disk seam --- `store_*`, `req_*`, `ch_*`, `drive_*` --- because the
//   pack is what carries a program into the machine.  `cadr_disk_pack.sv` is
//   the board's far end of it and the Linux program drives that; here the
//   testbench plays both, at the same order and the same interlock.
//
//   The processor's own bus cycle: `mbusy_o`, `wrcyc`, `nxm`, `unibus`,
//   `device`, `phys`.  CLAUDE.md's shadow-memory rule says a check keyed by
//   the thing under test moves with the bug, and the bug being hunted is a
//   duplicated or invented transaction at exactly the boundary below.  So the
//   anchor is the processor's cycle and never the bridge's.
//
//   `ch_active`, because the channel is a SECOND master on the same bridge and
//   the accounting above is the processor's.  Where `tb/cadr_bus_audit_tb.cpp`
//   asserts that the channel never ran, here it runs, and each transaction has
//   to be attributed to one owner or the other.
//
//   The whole datapath --- PC, IR, the buses, VMA, MD --- so that a run can be
//   compared against muir's own `rtl` engine microcycle for microcycle, and so
//   that a watchpoint at the port can say which microinstruction was executing.
//
//   The console's readout window, which is how `map2[777]` --- the entry the
//   board gets wrong --- is read out of a machine that has stopped.
//
// `boards` is HARDWIRED to 32, as `tb/cadr_mem_count_harness.sv` hardwires it
// and as `boards/arty-z7-20/cadr_arty.sv` sets it: CLAUDE.md records that
// System 100 cannot cold-boot with 40 or more, so it is not a knob.

`default_nettype none

module cadr_band_axi_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic clk,
    input  var logic rst,

    // ---- the disk's cable, and the block store's seam
    input  var logic [7:0]  drive_present,
    input  var logic [7:0]  drive_read_only,
    input  var logic        drive_timed,
    input  var logic        store_we,
    input  var logic [4:0]  store_slot,
    input  var logic [8:0]  store_addr,
    input  var logic [31:0] store_wdata,
    output var logic [31:0] store_rdata,
    output var logic        store_miss,
    input  var logic        store_busy,
    input  var logic [4:0]  store_busy_slot,
    input  var logic        store_deny,
    output var logic        req_valid,
    output var logic [30:0] req_tag,
    output var logic        req_post,
    output var logic        ch_active,
    output var logic        ch_waiting,
    output var logic [4:0]  ch_slot,
    output var logic        ch_wrote,
    output var logic        ch_hit,

    // ---- the Xbus seam, for a slave that is still outside the machine
    input  var logic        device_ack,
    input  var logic [31:0] device_rdata,

    // ---- the console's readout window, the only way into a halted machine
    input  var logic [17:0] con_ro_addr,
    output var logic [47:0] con_ro_data,

    // ---- the machine's whole datapath, for the comparison against muir
    output var logic        clock_edge,
    output var logic [13:0] pc,
    output var logic [13:0] lpc,
    output var logic [13:0] opc,
    output var logic [31:0] st,
    output var logic [47:0] ir,
    output var logic [31:0] a,
    output var logic [31:0] m,
    output var logic [31:0] alu,
    output var logic [31:0] r,
    output var logic [31:0] ob,
    output var logic [31:0] q,
    output var logic [9:0]  dc,
    output var logic [25:0] lc,
    output var logic [31:0] vma,
    output var logic [31:0] md,
    output var logic        vmaok,
    output var logic        jcond,
    output var logic        nop,
    output var logic        pcs1,
    output var logic        pcs0,
    output var logic        iwrited,
    output var logic        promdisable,
    output var logic        sintr_o,

    // ---- the processor's own bus cycle, which is the audit's anchor
    output var logic        mbusy_o,
    output var logic        wrcyc,
    output var logic        device,
    output var logic        dev_rq,
    output var logic        dev_write,
    output var logic        nxm,
    output var logic        unibus,
    output var logic        memstart,
    output var logic [21:0] phys,
    output var logic        timed_out,

    // ---- the bridge's memory port, `cadr_machine`'s own boundary
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    output var logic        mem_done,
    output var logic [31:0] mem_rdata,

    // ---- the port's side: AXI3, 64 bits, one beat.  `S_AXI_HP0` on the board.
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

  // The I/O board's cables, tied off: no keyboard, no mouse, no serial chip
  // and no Chaosnet interface, each its own slice.  What the card gives back
  // is folded below with every other output of `cadr_machine`.
  logic        ser_reset, iob_intr, audio, clock_ready;
  // What the two chips on the card give their far ends, which are the
  // `cadr-serial` and `cadr-chaosnet` programs': folded below with every
  // other output of `cadr_machine`.
  logic [7:0]  ser_mode1, ser_mode2, ser_cmd, ser_tx_data, ser_status;
  logic [25:0] ser_syn_face;
  logic        ser_tx_strobe;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;
  logic [7:0]  iob_vector, csr_face;
  logic [11:0] mouse_x, mouse_y;
  logic [15:0] interval;
  logic [2:0]  ub_ssyn_by;
  logic [17:0] ub_addr;
  logic [15:0] ub_rdata;
  logic [2:0]  arb_stage;
  logic [31:0] dev_wdata;
  logic        ub_msyn, ub_ssyn;
  logic        n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, mbusy_sync;
  logic        mem_error;
  logic        con_gnt, con_ssyn;
  logic [15:0] con_rdata;
  logic [31:0] con_vma, con_q, con_md;
  logic [17:0] con_ro_echo;

  // The PS7 boundary's own acknowledgements: `rvalid && rready && rlast` and
  // `bvalid && bready`, registered, which is where `cadr_mem_count.sv` counts
  // them and for the same reason --- a fabric that never issued a transaction
  // cannot fabricate a B or an R beat.
  logic port_read_ack, port_write_ack;
  logic ack_rvalid, ack_rready, ack_rlast, ack_bvalid, ack_bready;
  always_ff @(posedge clk) begin
    ack_rvalid <= hp0_rvalid;
    ack_rready <= hp0_rready;
    ack_rlast  <= hp0_rlast;
    ack_bvalid <= hp0_bvalid;
    ack_bready <= hp0_bready;
  end
  assign port_read_ack  = ack_rvalid && ack_rready && ack_rlast;
  assign port_write_ack = ack_bvalid && ack_bready;

  cadr_machine #(
      .PROM_HEX(PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(rst),
      // -XBUS.INTR is the machine's own line --- the display's vertical
      // interrupt ORed with the disk's request, both inside --- and comes out
      // as an observation output.  With a drive on the cable the disk half of
      // it is what takes the boot PROM out of `AWAIT-DISK`.
      .sintr_o(sintr_o),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed),
      .store_we(store_we), .store_slot(store_slot), .store_addr(store_addr),
      .store_wdata(store_wdata),
      .store_rdata(store_rdata), .store_miss(store_miss), .ch_active(ch_active),
      .store_busy(store_busy), .store_busy_slot(store_busy_slot),
      .store_deny(store_deny),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit),
      // The console's Unibus port, tied off: `con_req` and `con_msyn` low
      // and the whole of it folds, as `cadr_machine`'s own port list says.
      .con_req(1'b0), .con_msyn(1'b0), .con_write(1'b0),
      .con_addr(18'd0), .con_wdata(16'd0),
      .con_gnt(con_gnt), .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      .device_ack(device_ack), .device_rdata(device_rdata),
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'd0),
      .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
      .ser_cmd(ser_cmd), .ser_tx_strobe(ser_tx_strobe), .ser_tx_data(ser_tx_data),
      .ser_tx_take(1'b0), .ser_tx_done(1'b0), .ser_rx_strobe(1'b0),
      .ser_rx_end(1'b0), .ser_rx_parity(1'b0), .ser_rx_framing(1'b0),
      .ser_rx_data(8'd0), .ser_plugged(1'b0), .ser_status(ser_status),
      .ser_syn_face(ser_syn_face),
      .chaos_address(16'd0), .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word),
      .chaos_tx_clear(chaos_tx_clear), .chaos_reset(chaos_reset),
      .chaos_csr(chaos_csr), .chaos_rx_valid(1'b0), .chaos_rx_word(16'd0),
      .chaos_rx_done(1'b0), .chaos_rx_bits(13'd0), .chaos_rx_crc(1'b0),
      .chaos_tx_done(1'b0), .chaos_tx_abort(1'b0), .chaos_cbl_busy(1'b0),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      .ub_ssyn_by(ub_ssyn_by),
      .boards(7'd32),
      // The port's own handshakes, which `cadr_bus_audit` compares against
      // the machine's own count of what it asked for.  This harness HAS a
      // real port, so they are the real thing rather than tied low, and
      // registered as `boards/arty-z7-20/cadr_arty.sv` registers them.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack),
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
      .n_memgrant_o(n_memgrant), .mbusy_o(mbusy_o), .mbusy_sync_o(mbusy_sync),
      .ub_addr_o(ub_addr),
      .ub_rdata_o(ub_rdata), .n_loadmd_o(n_loadmd), .rdcyc_o(rdcyc),
      .nxm(nxm), .unibus(unibus), .memstart(memstart),
      .timed_out(timed_out), .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata)
  );

  // The adapter's AXI4 side, 32 bits wide.
  logic [31:0] awaddr, araddr, wdata, rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [3:0]  wstrb;

  cadr_axi_master u_axi (
      .clk(clk), .rst(rst),
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

  // The machine brings out more than anything here reads, and saying so is
  // what keeps lint honest about it.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0,
                    ser_mode1, ser_mode2, ser_cmd, ser_tx_strobe, ser_tx_data,
                    ser_status, ser_syn_face,
                    chaos_tx_go, chaos_tx_len, chaos_tx_valid,
                    chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                    chaos_bits, 
                    ser_reset, iob_intr, iob_vector, audio, csr_face,
                    mouse_x, mouse_y, clock_ready, interval, ub_ssyn_by,
                    ub_addr, ub_rdata, arb_stage, dev_wdata,
                    ub_msyn, ub_ssyn, n_memrq, n_memack, n_memgrant,
                    n_loadmd, rdcyc, mbusy_sync, mem_error,
                    con_gnt, con_ssyn, con_rdata, con_vma, con_q, con_md,
                    con_ro_echo};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
