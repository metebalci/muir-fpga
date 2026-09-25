// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on the DE25-Nano's memory port: `cadr_machine` in front of
// `rtl/plumbing/cadr_f2sdram_port.sv`, with the processor's own side brought
// out for `tb/cadr_f2sdram_tb.cpp` to be.
//
// **THE PATH IS THE BOARD'S**, because the path is the module:
// `boards/de25-nano/cadr_de25.sv` instantiates the same `cadr_f2sdram_port`
// with the same four signals from the processor and the same two other
// master ports.  What this harness adds is the processor's end of those
// wires, so that a testbench can open the port, shut it, ask for quiet, reset
// the processor, read the tally, and answer AXI.  How the top level wires the
// port is not held here: `build/de25.pass` simulates the top level itself.
//
// **THE OTHER TWO MASTERS ARE INPUTS HERE**, driven from the testbench in the
// AXI3 shape `cadr_disk_pack.sv` and `cadr_display_out.sv` have.  On the board
// those two modules drive them; here the testbench does, so that what they
// cost the machine can be measured and what reaches them can be compared
// with what the bridge model sent.
//
// **THE MACHINE'S RESET IS AN INPUT, AND IT IS THE TESTBENCH'S STIMULUS.**
// The board holds the machine in reset until the port has been live once,
// and that line is the board's own: a copy of it here would be a check of the
// copy.  So this harness brings `may_start` out, the port's own report, and
// takes the machine's reset in; `tb/cadr_f2sdram_tb.cpp` holds `may_start`
// to what the port says it means, and the board's use of it is held where
// the board's own line is, by the simulation of the top level in
// `build/de25.pass`.
//
// IT IS IN `tb/` FOR THE REASON `tb/cadr_de25_stubs.sv` GIVES: the Quartus
// flow builds the board from a list the Makefile names, and a harness in
// `rtl/` would be a second copy of the memory path in the bitstream.
//
// The mutations are aimed at `rtl/plumbing/cadr_f2sdram_share.sv` and
// `rtl/plumbing/cadr_f2sdram_gate.sv`; everything else here is in the
// runner's `extra`, having checks of its own.

`default_nettype none

module cadr_f2sdram_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex"
) (
    input  var logic clk,
    input  var logic rst,
    // The machine's reset: see the header.
    input  var logic mach_rst,

    // --- the processor's side of the port ---------------------------------
    input  var logic        h2f_reset,
    input  var logic        gp_open,
    input  var logic        gp_half,
    input  var logic        warm_req_n,
    output var logic        warm_ack_n,
    output var logic [31:0] gp_in,
    output var logic        live,
    output var logic        may_start,

    // --- what the machine is doing ----------------------------------------
    output var logic        clock_edge,
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    output var logic        mem_done,
    output var logic        timed_out,
    output var logic        n_memack,
    output var logic [13:0] pc,

    // --- the disk pack side's port, driven by the testbench ----------------
    input  var logic [31:0] p_awaddr,
    input  var logic [3:0]  p_awlen,
    input  var logic [1:0]  p_awsize,
    input  var logic [1:0]  p_awburst,
    input  var logic        p_awvalid,
    output var logic        p_awready,
    input  var logic [63:0] p_wdata,
    input  var logic [7:0]  p_wstrb,
    input  var logic        p_wlast,
    input  var logic        p_wvalid,
    output var logic        p_wready,
    output var logic [1:0]  p_bresp,
    output var logic        p_bvalid,
    input  var logic        p_bready,
    input  var logic [31:0] p_araddr,
    input  var logic [3:0]  p_arlen,
    input  var logic [1:0]  p_arsize,
    input  var logic [1:0]  p_arburst,
    input  var logic        p_arvalid,
    output var logic        p_arready,
    output var logic [63:0] p_rdata,
    output var logic [1:0]  p_rresp,
    output var logic        p_rlast,
    output var logic        p_rvalid,
    input  var logic        p_rready,

    // --- the display's port, read only -------------------------------------
    input  var logic [31:0] d_araddr,
    input  var logic [3:0]  d_arlen,
    input  var logic [1:0]  d_arsize,
    input  var logic [1:0]  d_arburst,
    input  var logic        d_arvalid,
    output var logic        d_arready,
    output var logic [63:0] d_rdata,
    output var logic [1:0]  d_rresp,
    output var logic        d_rlast,
    output var logic        d_rvalid,
    input  var logic        d_rready,

    // --- the bridge, which the testbench is -------------------------------
    output var logic [4:0]  f2s_awid,
    output var logic [31:0] f2s_awaddr,
    output var logic [7:0]  f2s_awlen,
    output var logic [2:0]  f2s_awsize,
    output var logic [1:0]  f2s_awburst,
    output var logic        f2s_awlock,
    output var logic [3:0]  f2s_awcache,
    output var logic [2:0]  f2s_awprot,
    output var logic [3:0]  f2s_awqos,
    output var logic [3:0]  f2s_awregion,
    output var logic [7:0]  f2s_awuser,
    output var logic        f2s_awvalid,
    input  var logic        f2s_awready,
    output var logic [63:0] f2s_wdata,
    output var logic [7:0]  f2s_wstrb,
    output var logic        f2s_wlast,
    output var logic [7:0]  f2s_wuser,
    output var logic        f2s_wvalid,
    input  var logic        f2s_wready,
    input  var logic [4:0]  f2s_bid,
    input  var logic [1:0]  f2s_bresp,
    input  var logic        f2s_bvalid,
    output var logic        f2s_bready,
    output var logic [4:0]  f2s_arid,
    output var logic [31:0] f2s_araddr,
    output var logic [7:0]  f2s_arlen,
    output var logic [2:0]  f2s_arsize,
    output var logic [1:0]  f2s_arburst,
    output var logic        f2s_arlock,
    output var logic [3:0]  f2s_arcache,
    output var logic [2:0]  f2s_arprot,
    output var logic [3:0]  f2s_arqos,
    output var logic [3:0]  f2s_arregion,
    output var logic [7:0]  f2s_aruser,
    output var logic        f2s_arvalid,
    input  var logic        f2s_arready,
    input  var logic [4:0]  f2s_rid,
    input  var logic [63:0] f2s_rdata,
    input  var logic [1:0]  f2s_rresp,
    input  var logic        f2s_rlast,
    input  var logic        f2s_rvalid,
    output var logic        f2s_rready
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
  logic n_memrq, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, mbusy, mbusy_sync;

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
  logic        sintr;   // -XBUS.INTR, the machine's own; read by nothing here
  logic [31:0] mem_rdata;

  // The DDR=1 board's configuration exactly: no interrupt, no Xbus device,
  // 32 boards of memory declared.
  // QUUX's line fill and its port's idle (contract Q6): the CADR this
  // harness builds never asks a line, so the line is zeros.
  logic h_mem_line, h_mem_drained;
  logic [127:0] h_port_rline;
  cadr_machine #(
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(mach_rst),
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
      .dbg_in_req(1'b0), .dbg_in_wr(1'b0), .dbg_in_a(2'd0), .dbd_in(16'd0),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_out), .dbd_oe(dbd_oe),
      // The DBGOUT page, which is this machine as somebody else's debugger.
      // No connector here, so it is tied as an unplugged cable: nothing at
      // the far end, the lines carried by the pull-ups, and the page answers
      // its own machine at `-UB MSYN`.  That is muir's `debug_cable` false.
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(1'b0),
      .dbgout_dbd_in(16'hFFFF), .dbgout_live(1'b0),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      // The readout window on the machine's memories.  No console on this
      // harness asks it anything, so the address stands at the reserved
      // selector and the two answers fold below with every other output.
      .con_ro_addr(18'h3FFFF), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      .device_ack(1'b0), .device_rdata(32'd0),
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'd0),
      // `-BOOT2`, the light panel's button, released: nothing here presses
      // any of the three boot lines.  **Active low**, so a pin left off is a
      // machine held at the boot trap and not a machine that runs.
      .n_boot2(1'b1),
      // The board's no-auto-boot switch, which this harness has none of: the
      // machine comes up as the fabric's reset leaves it, with the boot
      // button just let go.
      .no_auto_boot(1'b0),
      // OLORD1's three and `-BOOT` itself, which this harness has no lamps for.
      // `-PROMENABLE` goes to a lamp on a board and there is no lamp here.
      /* verilator lint_off PINCONNECTEMPTY */
      .n_boot_o(),
      .machrun(), .errhalt(), .stathalt(), .promenable(),
      /* verilator lint_on PINCONNECTEMPTY */
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
      .chaos_rx_lost(1'b0),
      .chaos_tx_done(1'b0), .chaos_tx_abort(1'b0), .chaos_cbl_busy(1'b0),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      .ub_ssyn_by(ub_ssyn_by),
      .boards(7'd32),
      // **THE BACKPLANE THIS CHECK RUNS ON: one SIMPLE TV and no color TV**,
      // which is muir's own default and what `busint::decode` describes.  The
      // second display board has `build/color_tv.pass` of its own.
      .tv_lispm(1'b0), .color_tv(1'b0), .tv_map_a(4'd0),
      .tv_map_q(tv_map_q), .tv_color_map_q(tv_color_map_q),
      // The color board's map on its second port, which on the board
      // is the display output's.  There is none here, so the index is
      // tied and the word is folded with the rest.
      .disp_map_a(4'd0), .disp_color_map_q(disp_color_map_q),
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      .mem_line(h_mem_line), .mem_rline(128'd0), .mem_drained(h_mem_drained),
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
      // The port's own answers, for the transaction audit inside the
      // machine, as `boards/de25-nano/cadr_de25.sv` wires them: the bridge's
      // own handshakes and nothing the fabric decides for itself.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack)
  );

  // The path itself, wired as `boards/de25-nano/cadr_de25.sv` wires it.
  logic mem_error;
  logic port_read_ack, port_write_ack;
  cadr_f2sdram_port u_memory (
      .clk(clk), .rst(rst),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(mem_error),
      .mem_line(1'b0), .mem_rline(h_port_rline),
      .h2f_reset(h2f_reset), .gp_open(gp_open), .gp_half(gp_half),
      .warm_req_n(warm_req_n), .warm_ack_n(warm_ack_n),
      .gp_in(gp_in), .live(live), .may_start(may_start),
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack),
      .p_awaddr(p_awaddr), .p_awlen(p_awlen), .p_awsize(p_awsize),
      .p_awburst(p_awburst), .p_awvalid(p_awvalid), .p_awready(p_awready),
      .p_wdata(p_wdata), .p_wstrb(p_wstrb), .p_wlast(p_wlast),
      .p_wvalid(p_wvalid), .p_wready(p_wready),
      .p_bresp(p_bresp), .p_bvalid(p_bvalid), .p_bready(p_bready),
      .p_araddr(p_araddr), .p_arlen(p_arlen), .p_arsize(p_arsize),
      .p_arburst(p_arburst), .p_arvalid(p_arvalid), .p_arready(p_arready),
      .p_rdata(p_rdata), .p_rresp(p_rresp), .p_rlast(p_rlast),
      .p_rvalid(p_rvalid), .p_rready(p_rready),
      .d_araddr(d_araddr), .d_arlen(d_arlen), .d_arsize(d_arsize),
      .d_arburst(d_arburst), .d_arvalid(d_arvalid), .d_arready(d_arready),
      .d_rdata(d_rdata), .d_rresp(d_rresp), .d_rlast(d_rlast),
      .d_rvalid(d_rvalid), .d_rready(d_rready),
      .f2s_awid(f2s_awid), .f2s_awaddr(f2s_awaddr), .f2s_awlen(f2s_awlen),
      .f2s_awsize(f2s_awsize), .f2s_awburst(f2s_awburst),
      .f2s_awlock(f2s_awlock), .f2s_awcache(f2s_awcache),
      .f2s_awprot(f2s_awprot), .f2s_awqos(f2s_awqos),
      .f2s_awregion(f2s_awregion), .f2s_awuser(f2s_awuser),
      .f2s_awvalid(f2s_awvalid), .f2s_awready(f2s_awready),
      .f2s_wdata(f2s_wdata), .f2s_wstrb(f2s_wstrb), .f2s_wlast(f2s_wlast),
      .f2s_wuser(f2s_wuser), .f2s_wvalid(f2s_wvalid), .f2s_wready(f2s_wready),
      .f2s_bid(f2s_bid), .f2s_bresp(f2s_bresp), .f2s_bvalid(f2s_bvalid),
      .f2s_bready(f2s_bready),
      .f2s_arid(f2s_arid), .f2s_araddr(f2s_araddr), .f2s_arlen(f2s_arlen),
      .f2s_arsize(f2s_arsize), .f2s_arburst(f2s_arburst),
      .f2s_arlock(f2s_arlock), .f2s_arcache(f2s_arcache),
      .f2s_arprot(f2s_arprot), .f2s_arqos(f2s_arqos),
      .f2s_arregion(f2s_arregion), .f2s_aruser(f2s_aruser),
      .f2s_arvalid(f2s_arvalid), .f2s_arready(f2s_arready),
      .f2s_rid(f2s_rid), .f2s_rdata(f2s_rdata), .f2s_rresp(f2s_rresp),
      .f2s_rlast(f2s_rlast), .f2s_rvalid(f2s_rvalid), .f2s_rready(f2s_rready)
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
  // MIT's debug cable out of the machine, tied off at the far end: with
  // `-DEBUG IN REQ` UP --- which is `dbg_in_req` LOW, the sense the whole
  // transport uses --- `cadr_dbgin.sv` makes no strobe, never asks for the
  // diagnostic bus, and its whole arm of the arbiter folds.  That is what an
  // unplugged DBGIN connector is: the SIP at 0A22 pulling the line up.
  // `build/dbgin.pass` is where the cable is driven and held.
  logic        dbg_in_ack, debuggee_reset, timeout_inhibit;
  logic [15:0] dbd_out;
  logic [1:0]  dbd_oe;
  logic        dbgout_req, dbgout_wr;
  logic [1:0]  dbgout_a;
  logic [15:0] dbgout_dbd;
  // Page 0's words 7 and 8, which no console on this harness reads: folded
  // below with the rest, the way every other output of `cadr_machine` is.
  logic [31:0] con_vma, con_q, con_md;
  logic [47:0] con_ro_data;
  logic [17:0] con_ro_echo;
  /* verilator lint_off UNUSEDSIGNAL */
  // The two display boards' color maps, which go to the console face on the
  // board and to nobody here; folded below with everything else this harness
  // does not read.
  logic [23:0] tv_map_q, tv_color_map_q, disp_color_map_q;

  logic unused;
  assign unused = &{1'b0, h_mem_line, h_mem_drained, h_port_rline, tv_map_q, tv_color_map_q, disp_color_map_q, lpc, opc, st, a, m, alu, r, ob, q, ir, dc, lc, vma,
                    store_rdata, store_miss, ch_active,
                    req_valid, req_tag, req_post, ch_waiting, ch_slot,
                    ch_wrote, ch_hit,
                    con_gnt, con_ssyn, con_rdata, con_vma, con_q, con_md,
                    dbg_in_ack, dbd_out, dbd_oe, debuggee_reset,
                    dbgout_req, dbgout_wr, dbgout_a, dbgout_dbd,
                    timeout_inhibit,
                    con_ro_data, con_ro_echo,
                    md, phys, ub_addr, ub_rdata, arb_stage, dev_wdata,
                    vmaok, jcond, nop, pcs1, pcs0, iwrited, wrcyc, device,
                    dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn,
                    n_memrq, n_memgrant, n_loadmd, rdcyc, nxm,
                    unibus, memstart, mbusy, mbusy_sync, mem_error, sintr,
                    ser_mode1, ser_mode2, ser_cmd, ser_tx_strobe, ser_tx_data,
                    ser_status, ser_syn_face,
                    chaos_tx_go, chaos_tx_len, chaos_tx_valid,
                    chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                    chaos_bits, 
                    ser_reset, iob_intr, iob_vector, audio, csr_face,
                    mouse_x, mouse_y, clock_ready, interval, ub_ssyn_by};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
