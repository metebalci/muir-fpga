// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine, the bridge, the adapter and the widening, with every signal the
// transaction audit needs brought out as a port.
//
// WHAT THIS EXISTS FOR.  CLAUDE.md records a board bug whose shape is now
// established: a word in MIT's page hash table is the faulting virtual address
// rather than a page table word, MD has been exonerated by measurement, and so
// main memory already held the wrong word --- which means the corruption is a
// WRITE that should not have happened.  And `cadr_microcycle.sv` loads `wdata`
// from MD at MEMGO REGARDLESS OF DIRECTION, so on every read the whole of the
// memory data register is standing on `mem_wdata` at the bridge.  One unwanted
// write therefore replaces a memory word with MD, at the read's own address,
// and nothing downstream can tell that from a legitimate store.
//
// The shape that fits is an EXTRA transaction beside a correct one, and
// nothing in this repository counted transactions per bus cycle.
// `tb/cadr_axi_master_tb.cpp` counts handshakes per transaction, which is one
// level down: it does catch an extra transaction born inside the adapter, and
// it is structurally unable to see one born above it --- its stimulus is the
// requests --- or to say anything about WRCYC or about which cycles the decode
// called main memory, having no processor and no decode.
//
// SO THE DUT HAS TO BE THE WHOLE PATH, and it is wired here as
// `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr` wires it: `cadr_machine`, then
// `cadr_axi_master`, then `cadr_axi_widen` onto the 64-bit AXI3 port
// `S_AXI_HP0` is the far end of.  `tb/cadr_mem_count_harness.sv` is the same
// three modules for a different question --- how many transactions the
// processing system ANSWERED --- and the two are deliberately separate: the
// tally's check drives `hp0_aresetn` to make a dead port, and a dead port
// issues no transactions at all, which is the one configuration an audit of
// transactions per cycle has nothing to say about.
//
// IT IS IN `tb/` FOR THE REASON `tb/cadr_arty_stubs.sv` GIVES.  Both Vivado
// scripts read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`, so a
// wiring harness in `rtl/` would join the bitstream --- a second copy of the
// memory path, in the synthesised design, that nothing on the board would ever
// reach.
//
// **WHAT IS BROUGHT OUT AND WHY EACH ONE.**  The audit's anchor is the
// PROCESSOR'S own bus cycle and never the bridge's: CLAUDE.md's shadow-memory
// rule says a check keyed by the thing under test moves with the bug, and the
// bug being hunted here is a duplicated request at exactly that boundary.  So
// the cycle is counted at `mbusy`, which `cadr_microcycle.sv` sets at MEMGO
// and clears MFINISHD_T ticks after -MEMACK, and its direction is read from
// `wrcyc`, the 74S175 at 1C23 that holds the STARTING instruction's direction
// for the whole cycle.  What the decode made of the address --- `nxm`,
// `unibus`, `device` --- says whether the cycle should have reached main
// memory at all, which is the other half of the property: a cycle that is not
// main memory's must issue NO transaction.
//
// `ch_active` is here because the channel is a second master on the same
// bridge and the accounting above is the processor's.  No drive is attached
// on this harness, so the channel never runs; the testbench asserts that
// rather than assuming it, because an audit that silently stopped applying
// would read exactly like one that passed.

`default_nettype none

module cadr_bus_audit_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic clk,
    input  var logic rst,

    // --- THE CONSOLE'S READOUT WINDOW, which is how the audit inside the
    // machine is read on a halted board and is therefore how it is read here.
    // It used to be tied to the reserved selector on this harness; the audit
    // answers selector 11 of it, so the testbench asks for its words the way
    // `cadr-readout` does --- write the address, wait, compare the echo.
    input  var logic [17:0] ro_addr,
    output var logic [47:0] ro_data,
    output var logic [17:0] ro_echo,

    // --- what the machine is doing
    output var logic        clock_edge,
    output var logic [13:0] pc,
    output var logic [13:0] opc,
    output var logic        timed_out,

    // --- the processor's own bus cycle and its direction
    output var logic        mbusy,        // MBUSY: set at MEMGO, cleared after -MEMACK
    output var logic        mbusy_sync,
    output var logic        memstart,
    output var logic        wrcyc,        // the 74S175's held direction
    output var logic        rdcyc,
    output var logic        n_memack,
    output var logic        n_memgrant,

    // --- what the decode made of the address
    output var logic        device,       // an Xbus slave that is not memory
    output var logic        unibus,
    output var logic        nxm,          // Xbus space with nothing in it
    output var logic [21:0] phys,
    output var logic [31:0] vma,
    output var logic [31:0] md,

    // --- the channel, the second master on this bridge
    output var logic        ch_active,

    // --- the bridge's memory port, which is `cadr_machine`'s own boundary
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    output var logic        mem_done,
    output var logic [31:0] mem_rdata,

    // --- the port's side: AXI3, 64 bits, one beat.  `S_AXI_HP0` on the board.
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

  logic [13:0] lpc;
  logic [31:0] st, a, m, alu, r, ob, q;
  logic [47:0] ir;
  logic [9:0]  dc;
  logic [25:0] lc;
  logic [17:0] ub_addr;
  logic [15:0] ub_rdata;
  logic [2:0]  arb_stage;
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited;
  logic dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
  logic n_memrq, n_loadmd;

  // The I/O board's cables, tied off: no keyboard, no mouse, no serial chip
  // and no Chaosnet interface, each its own slice.
  logic        ser_reset, iob_intr, audio, clock_ready;
  // What the two chips on the card give their far ends, which are the
  // `cadr-serial` and `cadr-chaosnet` programs': folded below with every
  // other output of `cadr_machine`.
  logic [7:0]  ser_mode1, ser_mode2, ser_cmd, ser_tx_data, ser_status;
  logic        ser_tx_strobe;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;
  logic [7:0]  iob_vector, csr_face;
  logic [11:0] mouse_x, mouse_y;
  logic [15:0] interval;
  logic [2:0]  ub_ssyn_by;  // three slaves since cadr_busint_regs landed
  logic        mem_error;
  logic        sintr;
  logic [31:0] store_rdata;
  logic        store_miss;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit;
  logic [30:0] req_tag;
  logic [4:0]  ch_slot;
  logic        con_gnt, con_ssyn;
  logic [15:0] con_rdata;
  logic [31:0] con_vma, con_q, con_md;

  // The DDR=1 board's configuration exactly: no interrupt, no Xbus device
  // outside, no drive on the disk's cable, 32 boards of memory declared.
  cadr_machine #(
      .PROM_HEX(PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(rst),
      .sintr_o(sintr),
      .drive_present(8'd0), .drive_read_only(8'd0), .drive_timed(1'b0),
      .store_we(1'b0), .store_slot(5'd0), .store_addr(9'd0), .store_wdata(32'd0),
      .store_rdata(store_rdata), .store_miss(store_miss), .ch_active(ch_active),
      .store_busy(1'b0), .store_busy_slot(5'd0), .store_deny(1'b0),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit),
      .con_req(1'b0), .con_msyn(1'b0), .con_write(1'b0),
      .con_addr(18'd0), .con_wdata(16'd0),
      .con_gnt(con_gnt), .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(ro_addr), .con_ro_data(ro_data),
      .con_ro_echo(ro_echo),
      .device_ack(1'b0), .device_rdata(32'd0),
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'd0),
      .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
      .ser_cmd(ser_cmd), .ser_tx_strobe(ser_tx_strobe), .ser_tx_data(ser_tx_data),
      .ser_tx_take(1'b0), .ser_tx_done(1'b0), .ser_rx_strobe(1'b0),
      .ser_rx_data(8'd0), .ser_plugged(1'b0), .ser_status(ser_status),
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
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      // THE PORT'S OWN ANSWERS, WIRED AS THE BOARD WIRES THEM.  The audit is
      // inside `cadr_machine` now and one of its clauses compares the port's
      // handshakes against the machine's own requests by direction; feeding it
      // zero here would leave that clause with no stimulus at all over the
      // whole run, which is the "a check that lints one configuration says
      // nothing about the others" shape.  Registered on the way in exactly as
      // `boards/arty-z7-20/cadr_arty.sv` registers them, so that what this
      // check exercises is the arrangement the board has.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack)
  );

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

  // The adapter's AXI4 side, 32 bits wide.  No port reset here and that is
  // deliberate: `tb/cadr_mem_count_harness.sv` brings `hp0_aresetn` out
  // because a board before `ps7_post_config` is the reading its instrument
  // exists for, and a dead port is the one configuration this audit has
  // nothing to say about --- no transaction is issued at all.
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
  assign unused = &{1'b0, lpc, st, a, m, alu, r, ob, q, ir, dc, lc,
                    store_rdata, store_miss,
                    req_valid, req_tag, req_post, ch_waiting, ch_slot,
                    ch_wrote, ch_hit,
                    con_gnt, con_ssyn, con_rdata, con_vma, con_q, con_md,
                    ub_addr, ub_rdata, arb_stage, dev_wdata,
                    vmaok, jcond, nop, pcs1, pcs0, iwrited,
                    dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn,
                    n_memrq, n_loadmd, mem_error, sintr,
                    ser_mode1, ser_mode2, ser_cmd, ser_tx_strobe, ser_tx_data,
                    ser_status, chaos_tx_go, chaos_tx_len, chaos_tx_valid,
                    chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                    chaos_bits, 
                    ser_reset, iob_intr, iob_vector, audio, csr_face,
                    mouse_x, mouse_y, clock_ready, interval, ub_ssyn_by};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
