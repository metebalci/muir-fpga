// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE LAST SIMULATABLE SEAM: THE PACK SIDE AS FABRIC, NOT AS A TESTBENCH.
//
// WHAT THIS EXISTS FOR.  CLAUDE.md's hunt for the board's page-hash-table word
// has cleared `rtl/machine/` over 171,000,000 microcycles (`make hash-watch`)
// and the adapter and the widening over 13,000,000 onto a real 64-bit AXI3
// port (`make band-axi`).  What is left is the PS7 and its DDR3 controller,
// which cannot be modelled; board-only causes; and THE DISK SEAM ---
// `rtl/plumbing/cadr_disk_pack.sv`, `S_AXI_HP2` and the `cadr-disk-packs`
// program --- which **no whole-machine check in this tree has ever
// contained**.  `disk_pack.pass` holds that module to properties on a directed
// stimulus with no machine behind it; `tb/cadr_band_axi_harness.sv` brings the
// block store's seam OUT and lets a testbench play the drive.
//
// So this harness is `tb/cadr_band_axi_harness.sv` with `cadr_disk_pack`
// INSTANTIATED between the machine and the testbench, exactly as
// `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr` instantiates it.  The seam that
// was twenty-odd driven ports is now module-to-module wire, and what the
// testbench drives instead is the two AXI faces the board's own processing
// system drives: `M_AXI_GP0`, where Linux writes the block's address, and
// `S_AXI_HP2`, where the pack's records live in DDR.
//
// **THE WIRING IS `cadr_arty.sv`'s, NAME FOR NAME**, and this check is only
// worth anything while it stays so.  In particular `moving`/`moving_slot` are
// the controller's `store_busy`/`store_busy_slot`, and `deny` is its
// `store_deny`: the pack side's words for the same wires.  That rename is the
// modules' own and is kept rather than smoothed over, so that a reader of
// either file finds the other's name at the port.
//
// **WHY THE TWO PORTS COME OUT SEPARATELY AND THE MEMORY BEHIND THEM NEED
// NOT.**  On the board `S_AXI_HP0` and `S_AXI_HP2` are two doors into ONE
// DRAM: UG585's port table puts HP{0,1} on DDR port 3 and HP{2,3} on port 2,
// and both reach the same cells.  A testbench is free to model them as one
// array, and should --- because then a pack-side master that wandered into the
// machine's own region is VISIBLE, which is precisely the shape of fault being
// hunted.  Two arrays would make that fault unreachable by construction.
//
// **THE SEAM STILL COMES OUT, AS OBSERVATION AND NEVER AS STIMULUS.**  Every
// `store_*`, `req_*` and `ch_*` port below is an OUTPUT here where
// `tb/cadr_band_axi_harness.sv` had half of them as inputs.  That is
// deliberate and is CLAUDE.md's `md` trap taken seriously: a port that stops
// being stimulus must stop being writable, or a testbench line left driving it
// goes on working and the module under test is unchecked.  Verilator lets you
// write an output, so the rename of `store_busy` to an output of THIS module
// is not enough on its own --- but a testbench that assigns one is assigning
// to something the pack side overwrites every eval, which fails loudly rather
// than silently.
//
// IT IS IN `tb/` for `tb/cadr_arty_stubs.sv`'s reason: both Vivado scripts
// read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`, so a wiring
// harness under `rtl/` would join the bitstream as a second copy of the memory
// path that nothing on the board would ever reach.
//
// `boards` is HARDWIRED to 32, as every harness here hardwires it and as
// `cadr_arty.sv` sets it: CLAUDE.md records that System 100 cannot cold-boot
// with 40 or more, so it is not a knob.

`default_nettype none

module cadr_pack_axi_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic clk,
    input  var logic rst,

    // ---- M_AXI_GP0: the testbench is Linux, 32 bits, AXI3 ----------------
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

    // ---- S_AXI_HP2: the pack side masters this, 64 bits, AXI3 ------------
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
    output var logic        hp2_rready,

    // ---- what the seam is doing, for the report and never for the stimulus
    output var logic        store_we,
    output var logic [4:0]  store_slot,
    output var logic [8:0]  store_addr,
    output var logic [31:0] store_wdata,
    output var logic [31:0] store_rdata,
    output var logic        store_miss,
    output var logic        store_busy,
    output var logic [4:0]  store_busy_slot,
    output var logic        store_deny,
    output var logic        req_valid,
    output var logic [30:0] req_tag,
    output var logic        req_post,
    output var logic        ch_active,
    output var logic        ch_waiting,
    output var logic [4:0]  ch_slot,
    output var logic        ch_wrote,
    output var logic        ch_hit,
    output var logic        pack_irq,
    output var logic [7:0]  drive_present,
    output var logic [7:0]  drive_read_only,
    output var logic        drive_timed,

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
    // `r` is MIT's own name for this bus, and it is `r_bus` here for a
    // mechanical reason: `rtl/plumbing/cadr_disk_pack.sv` declares a local
    // `r` and Verilator's VARHIDDEN is an error under `-Wall`.  The
    // testbench reads `r_bus` and compares it against the trace's `R`
    // column, so nothing about the comparison moves.
    output var logic [31:0] r_bus,
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
  // and no Chaosnet interface, each its own slice.
  logic        ser_reset, iob_intr, audio, clock_ready;
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

  // `rvalid && rready && rlast` and `bvalid && bready` at the port, registered:
  // where `cadr_mem_count.sv` counts them, and for its reason --- a fabric that
  // never issued a transaction cannot fabricate a B or an R beat.
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

  logic [7:0]  ser_mode1, ser_mode2, ser_cmd, ser_tx_data, ser_status;
  logic        ser_tx_strobe;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;

  cadr_machine #(
      .PROM_HEX(PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(rst),
      // -XBUS.INTR is the machine's own line --- the display's vertical
      // interrupt ORed with the disk's request, both inside --- and comes out
      // as an observation output.
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
      // and the whole of it folds.
      .con_req(1'b0), .con_msyn(1'b0), .con_write(1'b0),
      .con_addr(18'd0), .con_wdata(16'd0),
      .con_gnt(con_gnt), .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      .device_ack(device_ack), .device_rdata(device_rdata),
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'd0),
      // `ser_ready` and `chaos_intr` are GONE as ports: the card computes
      // `SER.IREQ` and `CHAOS.IREQ` itself, which is why a line left driving
      // either fails to compile rather than quietly doing nothing.  What is
      // here instead is the seam `cadr-serial` and `cadr-chaosnet` drive, tied
      // off because this harness is about the disk and not the card.
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
      // The port's own acknowledgements, which `cadr_bus_audit` inside the
      // machine compares against what the machine asked for.  This harness has
      // a real port, so they are the real handshakes rather than tied low,
      // registered as `boards/arty-z7-20/cadr_arty.sv` registers them.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack),
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      .pc(pc), .lpc(lpc), .opc(opc), .st(st), .ir(ir), .a(a), .m(m),
      .alu(alu), .r(r_bus), .ob(ob), .q(q), .dc(dc), .lc(lc), .vma(vma),
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

  // THE PACK SIDE.  Reset is `rst` rather than `cadr_arty.sv`'s synchronised
  // `hp2_aresetn && gp0_aresetn`, for the reason `tb/cadr_band_axi_harness.sv`
  // gives for leaving `hp0_aresetn` out: a dead port is a configuration this
  // has nothing to say about, and modelling it here would add a reset the
  // testbench could get wrong without the machine noticing.
  cadr_disk_pack u_pack (
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
      .store_we(store_we), .store_slot(store_slot),
      .store_addr(store_addr), .store_wdata(store_wdata),
      .store_rdata(store_rdata), .store_miss(store_miss),
      .ch_active(ch_active), .moving(store_busy),
      .moving_slot(store_busy_slot),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit), .deny(store_deny), .irq(pack_irq),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed)
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
                    ser_status, chaos_tx_go, chaos_tx_len, chaos_tx_valid,
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
