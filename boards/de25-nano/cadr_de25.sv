// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on a DE25-Nano: a top level with real pins, and the first one
// built with Quartus rather than Vivado.
//
// **THIS IS THE MEMORY-OFF BOARD, THE ARTY Z7-20's DEFAULT ONE MOVED TO A
// SECOND VENDOR.**  `cadr_machine` with nothing behind its memory port: every
// cycle the boot PROM runs to main memory --- the first at microcycle 536,303
// --- is ended by the bus interface's NXM timer, and the machine carries on
// with nothing stored.  What it can show is that the fabric runs on this part:
// the clock ticking, microcycles retiring, the PROM executing.  The processing
// system, its memory, the disk's pack side, the console, the debug cable and
// the display output are later slices, and each seam they will plug into is
// tied off below as the cable a CADR has with nothing on the far end of it.
//
// **THE MACHINE DOES NOT CHANGE FOR THIS BOARD.**  It does not know what part
// it is on, and the two Zynq boards already keep that promise.  Its three
// asynchronously read memories become MLABs by an assignment in the flow and
// not by anything in `rtl/`; the check that holds the one tick that costs is
// a define only Verilator ever sets.
//
// THE CLOCK, AND THE TWO VENDOR PIECES.
//
// **The board's clock is 50 MHz and the machine's is 100.**  `clock50_0` is
// `CLOCK0_50`, the one 50 MHz input on a 1.1 V bank, and an I/O PLL on that
// bank multiplies it to the 10 ns tick.  The PLL is `cadr_de25_pll`, which
// `boards/de25-nano/quartus/build.sh` generates from Altera's I/O PLL IP at
// every build, from a parameter list in that file.  It is generated rather
// than written as a primitive, unlike the Arty's `MMCME2_BASE`, because the
// Agilex 5 PLL primitive, `tennm_ph2_iopll`, takes 94 parameters and the IP is
// what chooses them: for this PLL a 3.2 GHz VCO, a feedback divider of 64 and
// an output divider of 32.  Written by hand they would be this project's claim
// about which settings the part accepts, with nothing but the fitter to hold
// it.  It is generated per build rather than committed, because the IP's
// output carries Altera's license terms and nothing in it is this project's.  The
// flow reads the period back out of the timing analyzer and refuses a build
// whose machine clock is not the tick, so no constraint can describe a
// different machine from the one being built.
//
// **The Reset Release is Altera's IP too, generated the same way.**  An
// Agilex 5 part does not enter user mode everywhere at once, and the Reset
// Release's `nINIT_DONE`, high until the whole fabric is running, is the
// signal that says it has.  For this family the IP's generator writes one
// instance of the primitive `altera_agilex_config_reset_release_endpoint` and
// nothing else, and instantiating that primitive here directly was tried
// first.  It elaborates and works, and Quartus refuses to see it: synthesis
// reports critical warning 20759 and its design assistant fails rule
// RES-10204, "No reset release IP detected in project, exactly 1 required",
// because both look for the IP in the project and not for the primitive in
// the design.  So the IP is taken, as `cadr_de25_reset_release`, and a build
// has no critical warning to explain away.  It holds the PLL in reset, which
// is one of the uses the IP's own port description gives, so no clock reaches
// the machine until the device is fully configured, and the fabric reset then
// waits for the PLL's lock.
//
// THE BUTTONS AND THE SWITCH, AS THE OTHER BOARDS HAVE THEM.
//
// `KEY0` is `-BOOT2`, the light panel's boot button, and `KEY1` resets the
// fabric, which is the pair every board here uses.  `SW0` is the no-auto-boot
// switch, read at the machine's reset and nowhere else.  **The buttons are
// debounced on the board, by a Schmitt trigger** (the user manual's section
// 3.7.1 and its Figure 3-15), which is exactly the 74LS14 at OLORD2 1A20 that
// the Arty Z7-20's top level builds out of a counter.  So `KEY0` gets a
// synchronizer and no debounce here.  Both buttons read low while pressed.
//
// THE LAMPS, WHICH ARE THE ARTY Z7-20's SIX IN THE SAME ORDER.
//
//   LEDR0  MACHRUN          the machine's own run signal, registered
//   LEDR1  the clock        the slow blink off the tick counter: the fabric is
//                           clocked
//   LEDR2  microcycles      the fast blink, which freezes when the machine
//                           stops
//   LEDR3  disk activity    a 42 ms one-shot per block the channel moves; dark
//                           here, where no drive is ever present
//   LEDR4  ERRHALT          the machine halted itself, held until a boot or a
//                           reset
//   LEDR5  PROMENABLE       lit while the machine runs out of the boot PROM
//   LEDR6, LEDR7            dark
//
// The eight are single green LEDs, lit when their pin is driven LOW (manual
// section 3.7.1), so the whole row is inverted at the pin.  The Arty's red
// error lamp and blue PROM lamp are two green ones here.  There is no console
// on this board yet, so nobody can ask for steady lamps and LEDR1 and LEDR2
// blink, which is what a board with a console comes up doing too.
//
// **EVERY OUTPUT OF THE MACHINE REACHES THE FOLD, OR SYNTHESIS DELETES IT.**
// `cadr_machine` brings its whole datapath out for the testbenches, and a top
// level that left those unconnected would synthesize to almost nothing and
// write a perfectly good bitstream of an empty part.  So every output is XORed
// into `witness`, a register nothing reads, which `noprune` keeps and with it
// the whole cone behind it.  Lint holds the port list and the fold: an output
// left off the instance is a PINMISSING and one left out of the fold an
// UNUSEDSIGNAL (`build/de25.pass`).  The flow holds the rest, by refusing a
// fit that is smaller than the machine is known to be.

`default_nettype none

// AND ONE THING IT DOES NOT DO BY DEFAULT, AS ON THE ZYNQ BOARDS.
// `PROBE_DEPTH` is zero here, so the design is the machine and nothing else.
// Setting it instantiates `rtl/plumbing/cadr_probe.sv`, which records one
// sample a microcycle from the machine's reset, behind Altera's Virtual JTAG:
// `make de25 PROBE_DEPTH=1024` builds that bitstream and
// `boards/de25-nano/quartus/probe.tcl` reads it.  Off by default for the
// reason `boards/arty-z7-20/cadr_arty.sv` gives: an instrument in every
// bitstream is an instrument nobody measures the cost of.
module cadr_de25 #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    // MIT's TV sync PROM, for the display: `rtl/machine/cadr_tv.sv`.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex",
    parameter int unsigned PROBE_DEPTH = 0
) (
    // `CLOCK0_50`, 50 MHz, on the 1.1 V bank with the switches and the LEDs.
    input  var logic       clock50_0,
    // `KEY[1:0]`, debounced on the board and low while pressed.
    input  var logic [1:0] btn,
    // `SW[3:0]`, low in the down position.  SW0 is the no-auto-boot switch,
    // and SW1 to SW3 are pins the board has and this design has no opinion
    // about, brought out so that the port list matches the board.
    input  var logic [3:0] sw,
    // `LEDR[7:0]`, lit when driven low.
    output var logic [7:0] led
);

  // ------------------------------------------------------------ the clock
  //
  // `ninit_done` is high while the device is still entering user mode and
  // falls once, when the whole fabric is running; nothing ever raises it
  // again.  It holds the PLL in reset until then.
  logic ninit_done;
  cadr_de25_reset_release u_reset_release (
      .ninit_done(ninit_done)
  );

  // 50 MHz in, 100 MHz out: one tick is 10 ns.  The parameters are in
  // `boards/de25-nano/quartus/build.sh`, and that flow checks the period the
  // timing analyzer derives from them against the tick.
  logic clk, pll_locked;
  cadr_de25_pll u_pll (
      .refclk  (clock50_0),
      .rst     (ninit_done),
      .outclk_0(clk),
      .locked  (pll_locked)
  );

  // ------------------------------------------------------------ the reset
  //
  // Reset while the PLL has not locked, and on KEY1.  Synchronized into the
  // 100 MHz domain, since `locked` and the button are both asynchronous to it.
  // The PLL cannot lock before `ninit_done` falls, so the fabric reset follows
  // the device's own initialization through the lock.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !pll_locked || !btn[1]};
  assign rst = rst_sync[3];

  // The machine's reset: the fabric's, and the debug cable's modifier bit 1,
  // which is this processor's power-on reset when a debugger asks for it.
  // No debugger can reach this board yet, so the second term folds away, and
  // the register stays so that the reset keeps the shape it has on the other
  // boards.  There is no console, so there is no console reset to join.
  logic debuggee_reset;
  logic mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || debuggee_reset;

  // ------------------------------------------------- KEY0 and SW0
  //
  // `-BOOT2` is the light panel's line, held down while the button is.  The
  // board's Schmitt trigger has already debounced it, so two synchronizer
  // stages are all it needs.  SW0 is a level read at the machine's reset arms
  // and nowhere else, so moving it under a running machine does nothing until
  // the next reset; three stages, as the other boards give it.
  logic [1:0] btn0_sync;
  logic [2:0] sw0_sync;
  logic       n_boot2;
  always_ff @(posedge clk) begin
    btn0_sync <= {btn0_sync[0], !btn[0]};
    sw0_sync  <= {sw0_sync[1:0], sw[0]};
  end
  assign n_boot2 = !btn0_sync[1];

  // ---------------------------------------------------------- the machine
  //
  // Every output, named as `cadr_machine` names it.
  logic        sintr;
  logic [31:0] store_rdata;
  logic        store_miss, ch_active;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit;
  logic [30:0] req_tag;
  logic [4:0]  ch_slot;
  logic        ser_reset, ser_tx_strobe;
  logic [7:0]  ser_mode1, ser_mode2, ser_cmd, ser_tx_data, ser_status;
  logic [25:0] ser_syn_face;
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;
  logic        iob_intr, audio, clock_ready;
  logic [7:0]  iob_vector, csr_face;
  logic [11:0] mouse_x, mouse_y;
  logic [15:0] interval;
  logic [23:0] tv_map_q, tv_color_map_q, disp_color_map_q;
  logic [13:0] pc, lpc, opc;
  logic [31:0] st, a, m, alu, r, ob, q, vma, md;
  logic [47:0] ir;
  logic [9:0]  dc;
  logic [25:0] lc;
  logic        vmaok, jcond, nop, pcs1, pcs0, iwrited, promenable, clock_edge;
  logic        wrcyc, device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
  logic [21:0] phys;
  logic [31:0] dev_wdata;
  logic [2:0]  arb_stage, ub_ssyn_by;
  logic        n_memrq, n_memack, n_memgrant, mbusy, mbusy_sync;
  logic [17:0] ub_addr;
  logic [15:0] ub_rdata;
  logic        n_loadmd, rdcyc, nxm, unibus, memstart, timed_out;
  logic        machrun, errhalt, stathalt, n_boot;
  logic        con_gnt, con_ssyn;
  logic [15:0] con_rdata;
  logic        dbg_in_ack;
  logic [15:0] dbd_out;
  logic [1:0]  dbd_oe;
  logic        dbgout_req, dbgout_wr;
  logic [1:0]  dbgout_a;
  logic [15:0] dbgout_dbd;
  logic        timeout_inhibit;
  logic [31:0] con_vma, con_q, con_md;
  logic [47:0] con_ro_data;
  logic [17:0] con_ro_echo;
  logic        mem_req, mem_write;
  logic [31:0] mem_addr, mem_wdata;

  cadr_machine #(
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(mach_rst),
      .sintr_o(sintr),
      // NO DRIVE AND NO PACK.  With `drive_present` at zero the status
      // register answers `0x2321` for every one of the boot PROM's polls, and
      // tied off the whole drive constant-folds, so this fit counts the
      // register face and the decode and not the spindle.
      .drive_present(8'd0), .drive_read_only(8'd0), .drive_timed(1'b0),
      .store_we(1'b0), .store_slot(5'd0), .store_addr(9'd0),
      .store_wdata(32'd0), .store_rdata(store_rdata),
      .store_miss(store_miss), .ch_active(ch_active),
      .store_busy(1'b0), .store_busy_slot(5'd0), .store_deny(1'b0),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit),
      // THE I/O BOARD'S CABLES, WITH NOTHING ON THEIR FAR ENDS.  No strobe
      // means no scan code.  The mouse's seven lines are ALL ONES and not
      // zero: each switch pulls to ground when pressed and each quadrature
      // line is high at rest, so all ones is a mouse nobody is touching.
      .kbd_strobe(1'b0), .kbd_code(24'd0), .mouse_lines(7'h7F),
      .n_boot2(n_boot2), .no_auto_boot(sw0_sync[2]),
      // The serial line unplugged: with `ser_plugged` down the 2651's sheet
      // holds both halves stopped.  And the Chaosnet with its address
      // switches at zero and no frame ever arriving.
      .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
      .ser_cmd(ser_cmd), .ser_tx_strobe(ser_tx_strobe),
      .ser_tx_data(ser_tx_data),
      .ser_tx_take(1'b0), .ser_tx_done(1'b0), .ser_rx_strobe(1'b0),
      .ser_rx_data(8'd0), .ser_rx_end(1'b0), .ser_rx_parity(1'b0),
      .ser_rx_framing(1'b0), .ser_plugged(1'b0),
      .ser_status(ser_status), .ser_syn_face(ser_syn_face),
      .chaos_address(16'd0), .chaos_tx_go(chaos_tx_go),
      .chaos_tx_len(chaos_tx_len), .chaos_tx_valid(chaos_tx_valid),
      .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(1'b0), .chaos_rx_word(16'd0), .chaos_rx_done(1'b0),
      .chaos_rx_bits(13'd0), .chaos_rx_crc(1'b0), .chaos_rx_lost(1'b0),
      .chaos_tx_done(1'b0), .chaos_tx_abort(1'b0), .chaos_cbl_busy(1'b0),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      // 32 boards of 64K words, muir's default, and the backplane with no
      // console to say otherwise: one SIMPLE TV and no color board.
      .boards(7'd32),
      .tv_lispm(1'b0), .color_tv(1'b0),
      .tv_map_a(4'd0), .tv_map_q(tv_map_q), .tv_color_map_q(tv_color_map_q),
      .disp_map_a(4'd0), .disp_color_map_q(disp_color_map_q),
      .pc(pc), .lpc(lpc), .opc(opc), .st(st), .ir(ir), .a(a), .m(m),
      .alu(alu), .r(r), .ob(ob), .q(q), .dc(dc), .lc(lc), .vma(vma),
      .md(md), .vmaok(vmaok), .jcond(jcond), .nop(nop), .pcs1(pcs1),
      .pcs0(pcs0), .iwrited(iwrited), .promenable(promenable),
      .clock_edge(clock_edge),
      .wrcyc(wrcyc), .device(device), .dev_rq(dev_rq),
      .dev_write(dev_write), .phys(phys), .dev_wdata(dev_wdata),
      // No Xbus slave but main memory and the disk exists anywhere yet.
      .device_ack(1'b0), .device_rdata(32'd0),
      .promdisable(promdisable),
      .ub_msyn(ub_msyn), .ub_ssyn_o(ub_ssyn), .arb_stage(arb_stage),
      .n_memrq_o(n_memrq), .n_memack_o(n_memack),
      .n_memgrant_o(n_memgrant), .mbusy_o(mbusy), .mbusy_sync_o(mbusy_sync),
      .ub_addr_o(ub_addr), .ub_rdata_o(ub_rdata), .ub_ssyn_by(ub_ssyn_by),
      .n_loadmd_o(n_loadmd), .rdcyc_o(rdcyc),
      .nxm(nxm), .unibus(unibus), .memstart(memstart),
      .timed_out(timed_out),
      .machrun(machrun), .errhalt(errhalt), .stathalt(stathalt),
      .n_boot_o(n_boot),
      // NO CONSOLE.  With `con_req` and `con_msyn` down the arbiter never
      // grants, and the register block keeps its one master.
      .con_req(1'b0), .con_gnt(con_gnt), .con_msyn(1'b0),
      .con_write(1'b0), .con_addr(18'd0), .con_wdata(16'd0),
      .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      // NO DEBUG CABLE.  `-DEBUG IN REQ` held UP, which is `dbg_in_req` low,
      // is what the SIP at DBGIN 0A22 makes of an unplugged connector, and the
      // DBGIN page folds to its idle state.  The DBGOUT page's far end is a
      // bare connector as `cadr_machine` describes one: not live, never
      // acknowledging, and every data line reading one.
      .dbg_in_req(1'b0), .dbg_in_wr(1'b0), .dbg_in_a(2'd0), .dbd_in(16'd0),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_out), .dbd_oe(dbd_oe),
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(1'b0),
      .dbgout_dbd_in(16'hFFFF), .dbgout_live(1'b0),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset is the fabric's and not `mach_rst`, for
      // the reason `cadr_machine` gives: a modifier register cleared by its
      // own bit 1 could never be written.
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      // Nothing asks the readout anything: the address stands at the
      // reserved selector and the machine answers `RO_NO_MEMORY` for ever.
      .con_ro_addr(18'h3FFFF), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      // NO MEMORY.  Nothing ever answers, so the NXM timer ends every
      // main-memory cycle, and no port answers the transaction audit either.
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(1'b0), .mem_rdata(32'd0),
      .port_read_ack(1'b0), .port_write_ack(1'b0)
  );

  // ---------------------------------------------------------- the fold
  //
  // Every output of `cadr_machine`, including the ones a lamp already reads,
  // because a fold with exceptions in it is not a rule anybody can check.
  // Nothing reads `witness`.  `noprune` is Quartus's attribute for a register
  // with no fanout that must stay, and the logic feeding it stays with it.
  // The Verilator waiver is beside it because lint's complaint is correct and
  // the answer is that nothing is meant to read it.
  /* verilator lint_off UNUSEDSIGNAL */
  (* noprune *)
  logic witness;
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge clk) begin
    if (mach_rst) begin
      witness <= 1'b0;
    end else begin
      witness <= ^{pc, lpc, opc, st, ir, a, m, alu, r, ob, q, dc, lc,
                   vma, md, phys, ub_addr, ub_rdata, arb_stage,
                   mem_addr, mem_wdata, dev_wdata, store_rdata,
                   vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge,
                   wrcyc, device, dev_rq, dev_write, promdisable, promenable,
                   ub_msyn, ub_ssyn,
                   n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc,
                   nxm, unibus, memstart, timed_out, mbusy, mbusy_sync,
                   mem_req, mem_write, store_miss, ch_active,
                   machrun, errhalt, stathalt, n_boot,
                   req_valid, req_tag, req_post, ch_waiting, ch_slot,
                   ch_wrote, ch_hit, con_gnt, con_ssyn, con_rdata,
                   con_vma, con_q, con_md, con_ro_data, con_ro_echo,
                   ser_mode1, ser_mode2, ser_cmd, ser_tx_strobe, ser_tx_data,
                   ser_status, chaos_tx_go, chaos_tx_len, chaos_tx_valid,
                   chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                   chaos_bits,
                   ser_syn_face,
                   ser_reset, iob_intr, iob_vector, audio, csr_face,
                   mouse_x, mouse_y, clock_ready, interval, ub_ssyn_by,
                   sintr,
                   dbg_in_ack, dbd_out, dbd_oe,
                   dbgout_req, dbgout_wr, dbgout_a, dbgout_dbd,
                   debuggee_reset, timeout_inhibit,
                   tv_map_q, tv_color_map_q, disp_color_map_q};
    end
  end

  // ------------------------------------------------------------ the probe
  //
  // One sample a microcycle of the columns `build/rtl.golden` carries, read
  // out over JTAG so that what this part computes can be compared with what
  // muir computes.  The capture is the Zynq boards' own module, wired to the
  // machine as `boards/arty-z7-20/cadr_arty.sv` wires it, with `-VMAOK` in
  // the trace's polarity.  Only the JTAG side is this vendor's: the Virtual
  // JTAG IP, which `boards/de25-nano/quartus/build.sh` generates as
  // `cadr_de25_vjtag` when the probe is asked for, and the node in
  // `rtl/plumbing/agilex5/cadr_probe_vjtag.sv` between it and the probe.
  //
  // The IP's other outputs are the rest of the node's virtual states, which
  // the probe does not need: it moves its pointer on Capture-DR, so it needs
  // no Update-DR, and the node reads its instruction as a level.
  if (PROBE_DEPTH > 0) begin : g_probe
    logic vj_tck, vj_tdi, vj_tdo, vj_ir_in, vj_ir_out, vj_cdr, vj_sdr;
    /* verilator lint_off PINCONNECTEMPTY */
    cadr_de25_vjtag u_vjtag (
        .tck(vj_tck), .tdi(vj_tdi), .tdo(vj_tdo),
        .ir_in(vj_ir_in), .ir_out(vj_ir_out),
        .virtual_state_cdr(vj_cdr), .virtual_state_sdr(vj_sdr),
        .virtual_state_e1dr(), .virtual_state_pdr(), .virtual_state_e2dr(),
        .virtual_state_udr(), .virtual_state_cir(), .virtual_state_uir()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic jtag_drck, jtag_sel, jtag_shift, jtag_capture, jtag_tdi, jtag_tdo;
    cadr_probe_vjtag u_node (
        .tck(vj_tck), .tdi(vj_tdi), .ir_in(vj_ir_in),
        .virtual_state_cdr(vj_cdr), .virtual_state_sdr(vj_sdr),
        .tdo(vj_tdo), .ir_out(vj_ir_out),
        .jtag_drck(jtag_drck), .jtag_sel(jtag_sel),
        .jtag_shift(jtag_shift), .jtag_capture(jtag_capture),
        .jtag_tdi(jtag_tdi), .jtag_tdo(jtag_tdo)
    );

    cadr_probe #(
        .DEPTH(PROBE_DEPTH)
    ) u_probe (
        // Re-armed by the machine's reset, which on this board is KEY1 or a
        // fresh configuration: a restarted machine has new first microcycles.
        .clk(clk), .rst(mach_rst),
        .qualify(clock_edge),
        .pc(pc), .ir(ir), .q(q), .a(a), .m(m), .alu(alu), .r(r), .ob(ob),
        .dc(dc), .opc(opc), .st(st), .lc(lc),
        .iwrited(iwrited), .nop(nop), .n_vmaok(!vmaok), .jcond(jcond),
        .pcs1(pcs1), .pcs0(pcs0),
        .lpc(lpc), .md(md), .vma(vma), .promdis(promdisable),
        .jtag_drck(jtag_drck), .jtag_sel(jtag_sel),
        .jtag_shift(jtag_shift), .jtag_capture(jtag_capture),
        .jtag_tdi(jtag_tdi), .jtag_tdo(jtag_tdo)
    );
  end

  // ---------------------------------------------------------- the lamps
  //
  // The heartbeat counts the machine's clock and nothing else, and is not
  // reset, because `rst` is held while the PLL is unlocked and a heartbeat
  // that stopped during reset would lose the one case it exists for.
  logic [25:0] tick;
  always_ff @(posedge clk) tick <= tick + 26'd1;

  // LEDR0 is registered, because `MACHRUN` has `-WAIT`'s whole cone behind it
  // and a pad is the one place a long path buys nothing.  LEDR3 is stretched,
  // because a block moves in some 38 us and a lamp lit for that long is a
  // lamp nobody sees: `DISK_LIT_T` ticks, re-armed by every block.
  localparam int unsigned DISK_LIT_T = 1 << 22;   // 41.9 ms at the 10 ns tick

  logic        machrun_lamp;
  logic [21:0] disk_lit_t;
  logic        disk_lit;
  always_ff @(posedge clk) begin
    if (mach_rst) begin
      machrun_lamp <= 1'b0;
      disk_lit     <= 1'b0;
      disk_lit_t   <= 22'd0;
    end else begin
      machrun_lamp <= machrun;
      if (disk_lit_t != 22'd0) disk_lit_t <= disk_lit_t - 22'd1;
      else disk_lit <= 1'b0;
      if (ch_active) begin
        disk_lit   <= 1'b1;
        disk_lit_t <= 22'(DISK_LIT_T - 1);
      end
    end
  end

  // LEDR1 and LEDR2, blinking.  They are the modules the Zynq boards use and
  // `build/blink_lamps.pass` holds; with no console `steady` is tied low.
  logic clock_lamp, cycle_lamp;
  cadr_lamp_clock u_lamp_clock (
      .steady(1'b0), .locked(pll_locked), .blink(tick[25]),
      .lit(clock_lamp)
  );
  cadr_lamp_microcycle u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(1'b0),
      .retired(clock_edge), .lit(cycle_lamp)
  );

  // LEDR4, the machine's own error halt and nothing else, cleared by `-BOOT`
  // and by a reset.  `build/errhalt_lamp.pass` holds the latch.
  logic errhalt_lit;
  cadr_lamp_errhalt u_lamp_errhalt (
      .clk(clk), .rst(mach_rst), .errhalt(errhalt), .n_boot(n_boot),
      .lit(errhalt_lit)
  );

  // Lit low.  LEDR5 is `-PROMENABLE`'s net itself, as on the Zynq boards,
  // and LEDR6 and LEDR7 are dark.
  assign led = ~{1'b0, 1'b0, promenable, errhalt_lit,
                 disk_lit, cycle_lamp, clock_lamp, machrun_lamp};

  // SW1 to SW3 are pins this board has and this design gives no meaning.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, sw[3:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
