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
//   LEDR6  memory port      lit while the processor's memory port is open,
//                           on the memory board; dark on the board without
//   LEDR7                   dark
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

// **AND THE MEMORY BOARD, `DDR=1`**, which is the define `CADR_DE25_DDR`: the
// Agilex 5's processor, its LPDDR4 and its FPGA-to-SDRAM bridge behind the
// machine's memory port, as `DDR=1` puts the Zynq's processing system behind
// it on the Arty Z7-20.  A define and not a parameter because it changes the
// port list: that board has the processor's memory bank and peripherals as
// pins of this top level, and the board without it must not, or the fitter
// would place them.  `make de25 DDR=1` sets it, and `build/de25.pass` lints
// both.  The pieces are Altera's generated processor system,
// `cadr_de25_hps`, which `boards/de25-nano/quartus/hps.tcl` describes and
// `build.sh` generates at every build, and `rtl/plumbing/cadr_f2sdram_port.sv`,
// whose header is the argument for the memory path; see the memory section
// below for what is wired where.
//
// **THE BOARD'S MEMORY IS AT `0xB000_0000` AND THIS FILE SAYS SO.**
// `rtl/plumbing/cadr_ddr_map.sv` takes its base from a define the DE25-Nano's
// flows set, and elaboration stops below if the package disagrees with the
// base written here, with or without the processor: the machine's addresses
// are the board's on every build of it.
//
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
`ifdef CADR_DE25_DDR
    ,
    // The processor's LPDDR4 bank, LPDDR4A, which its memory controller
    // drives.  The names are the pin file's, which are the manual's; the
    // controller's own names for each are beside the connection below.
    output var logic [5:0]  lpddr4a_ca,
    output var logic        lpddr4a_cs_n,
    output var logic        lpddr4a_cke,
    output var logic        lpddr4a_ck,
    output var logic        lpddr4a_ck_n,
    inout  wire  logic [31:0] lpddr4a_dq,
    inout  wire  logic [3:0]  lpddr4a_dqs,
    inout  wire  logic [3:0]  lpddr4a_dqs_n,
    inout  wire  logic [3:0]  lpddr4a_dm,
    output var logic        lpddr4a_reset_n,
    input  var logic        lpddr4a_rzq,
    input  var logic        lpddr4a_refclk_p,
    // The processor's own pins: its 25 MHz clock and the peripherals of the
    // manual's section 3.8, as `boards/de25-nano/quartus/hps.tcl` muxes them.
    input  var logic        hps_clk_25,
    inout  wire  logic      hps_key,
    inout  wire  logic      hps_led,
    output var logic        hps_enet_tx_clk,
    output var logic        hps_enet_tx_ctl,
    output var logic [3:0]  hps_enet_tx_data,
    input  var logic        hps_enet_rx_clk,
    input  var logic        hps_enet_rx_ctl,
    input  var logic [3:0]  hps_enet_rx_data,
    inout  wire  logic      hps_enet_mdio,
    output var logic        hps_enet_mdc,
    output var logic        hps_uart_tx,
    input  var logic        hps_uart_rx,
    output var logic        hps_sd_clk,
    inout  wire  logic      hps_sd_cmd,
    inout  wire  logic [3:0] hps_sd_data,
    input  var logic        hps_usb_clk,
    output var logic        hps_usb_stp,
    input  var logic        hps_usb_dir,
    input  var logic        hps_usb_nxt,
    inout  wire  logic [7:0] hps_usb_data,
    inout  wire  logic      hps_gsensor_int,
    inout  wire  logic      hps_i2c_scl,
    inout  wire  logic      hps_i2c_sda
`endif
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
  logic        mem_done;
  logic [31:0] mem_rdata;

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
      // THE MEMORY, OR NONE.  With `DDR` off nothing ever answers, so the
      // NXM timer ends every main-memory cycle; with it on, the memory
      // section below answers through the processor's bridge.  No port
      // answers the transaction audit on either board: it has no register on
      // a board with no console to read it.
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata),
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

  // ----------------------------------------------------------- the memory
  //
  // **WHERE THIS BOARD'S MEMORY IS**, which is the second 128 MB from the top
  // of the processor's 1 GB at `0x8000_0000`: `rtl/plumbing/cadr_ddr_map.sv`
  // gives the reason, and the reserved-memory node on the Linux side reserves
  // the same 128 MB.  Written here as well as there, so that a flow that left
  // out the define choosing the board's map stops at elaboration instead of
  // building a machine that puts the Zynq's addresses on this processor's
  // bus, where `0x1800_0000` is not memory at all.
  localparam logic [31:0] MAIN_BASE = 32'hB000_0000;
  if (cadr_ddr_map::MAIN_BASE != MAIN_BASE) begin : g_wrong_map
    $error("cadr_ddr_map::MAIN_BASE is %h, and the DE25-Nano's is %h: define CADR_DDR_MAP_DE25_NANO",
           cadr_ddr_map::MAIN_BASE, MAIN_BASE);
  end

  // The lamp that says the memory port is open, LEDR6: lit on the memory
  // board once software has opened the port and while it stays open, and
  // dark on the board without memory.
  logic port_live;

`ifdef CADR_DE25_DDR
  // **THE PROCESSOR, ITS MEMORY AND ITS BRIDGES**, as `hps.tcl` generates
  // them.  Every clock the fabric gives the system is the machine's 100 MHz,
  // and every reset it gives the bridges' soft logic is the processor's own
  // `h2f_reset`, which the TRM's note to its F2SDRAM table requires of that
  // bridge and which serves the other two as well.
  logic        h2f_reset;
  logic [31:0] gp_out, gp_in;
  logic        warm_req_n, warm_ack_n;

  // `hps2fpga` and `lwhps2fpga`: AXI4, 32 bits, four bits of ID.
  logic [3:0]  h2f_awid, h2f_arid, h2f_bid, h2f_rid;
  logic [29:0] h2f_awaddr, h2f_araddr;
  logic [7:0]  h2f_awlen, h2f_arlen;
  logic [2:0]  h2f_awsize, h2f_arsize, h2f_awprot, h2f_arprot;
  logic [1:0]  h2f_awburst, h2f_arburst, h2f_bresp, h2f_rresp;
  logic        h2f_awlock, h2f_arlock;
  logic [3:0]  h2f_awcache, h2f_arcache, h2f_wstrb;
  logic [31:0] h2f_wdata, h2f_rdata;
  logic        h2f_awvalid, h2f_awready, h2f_wlast, h2f_wvalid, h2f_wready;
  logic        h2f_bvalid, h2f_bready, h2f_arvalid, h2f_arready;
  logic        h2f_rlast, h2f_rvalid, h2f_rready;
  logic [3:0]  lw_awid, lw_arid, lw_bid, lw_rid;
  logic [28:0] lw_awaddr, lw_araddr;
  logic [7:0]  lw_awlen, lw_arlen;
  logic [2:0]  lw_awsize, lw_arsize, lw_awprot, lw_arprot;
  logic [1:0]  lw_awburst, lw_arburst, lw_bresp, lw_rresp;
  logic        lw_awlock, lw_arlock;
  logic [3:0]  lw_awcache, lw_arcache, lw_wstrb;
  logic [31:0] lw_wdata, lw_rdata;
  logic        lw_awvalid, lw_awready, lw_wlast, lw_wvalid, lw_wready;
  logic        lw_bvalid, lw_bready, lw_arvalid, lw_arready;
  logic        lw_rlast, lw_rvalid, lw_rready;

  // `f2sdram`: AXI4, 64 bits, five bits of ID.
  logic [4:0]  f2s_awid, f2s_arid, f2s_bid, f2s_rid;
  logic [31:0] f2s_awaddr, f2s_araddr;
  logic [7:0]  f2s_awlen, f2s_arlen, f2s_awuser, f2s_aruser, f2s_wuser;
  logic [7:0]  f2s_buser, f2s_ruser, f2s_wstrb;
  logic [2:0]  f2s_awsize, f2s_arsize, f2s_awprot, f2s_arprot;
  logic [1:0]  f2s_awburst, f2s_arburst, f2s_bresp, f2s_rresp;
  logic        f2s_awlock, f2s_arlock;
  logic [3:0]  f2s_awcache, f2s_arcache, f2s_awqos, f2s_arqos;
  logic [3:0]  f2s_awregion, f2s_arregion;
  logic [63:0] f2s_wdata, f2s_rdata;
  logic        f2s_awvalid, f2s_awready, f2s_wlast, f2s_wvalid, f2s_wready;
  logic        f2s_bvalid, f2s_bready, f2s_arvalid, f2s_arready;
  logic        f2s_rlast, f2s_rvalid, f2s_rready;

  cadr_de25_hps u_hps (
      // LPDDR4A, by the controller's names.
      .emif_mem_0_mem_cs(lpddr4a_cs_n), .emif_mem_0_mem_ca(lpddr4a_ca),
      .emif_mem_0_mem_cke(lpddr4a_cke), .emif_mem_0_mem_dq(lpddr4a_dq),
      .emif_mem_0_mem_dqs_t(lpddr4a_dqs), .emif_mem_0_mem_dqs_c(lpddr4a_dqs_n),
      .emif_mem_0_mem_dmi(lpddr4a_dm),
      .emif_mem_ck_0_mem_ck_t(lpddr4a_ck), .emif_mem_ck_0_mem_ck_c(lpddr4a_ck_n),
      .emif_mem_reset_n_mem_reset_n(lpddr4a_reset_n),
      .emif_oct_0_oct_rzqin(lpddr4a_rzq), .emif_ref_clk_clk(lpddr4a_refclk_p),
      // The processor's pins.
      .hps_hps_io_hps_osc_clk(hps_clk_25),
      .hps_hps_io_sdmmc_data0(hps_sd_data[0]), .hps_hps_io_sdmmc_data1(hps_sd_data[1]),
      .hps_hps_io_sdmmc_cclk(hps_sd_clk),
      .hps_hps_io_sdmmc_data2(hps_sd_data[2]), .hps_hps_io_sdmmc_data3(hps_sd_data[3]),
      .hps_hps_io_sdmmc_cmd(hps_sd_cmd),
      .hps_hps_io_usb0_clk(hps_usb_clk), .hps_hps_io_usb0_stp(hps_usb_stp),
      .hps_hps_io_usb0_dir(hps_usb_dir),
      .hps_hps_io_usb0_data0(hps_usb_data[0]), .hps_hps_io_usb0_data1(hps_usb_data[1]),
      .hps_hps_io_usb0_nxt(hps_usb_nxt),
      .hps_hps_io_usb0_data2(hps_usb_data[2]), .hps_hps_io_usb0_data3(hps_usb_data[3]),
      .hps_hps_io_usb0_data4(hps_usb_data[4]), .hps_hps_io_usb0_data5(hps_usb_data[5]),
      .hps_hps_io_usb0_data6(hps_usb_data[6]), .hps_hps_io_usb0_data7(hps_usb_data[7]),
      .hps_hps_io_emac0_tx_clk(hps_enet_tx_clk), .hps_hps_io_emac0_tx_ctl(hps_enet_tx_ctl),
      .hps_hps_io_emac0_rx_clk(hps_enet_rx_clk), .hps_hps_io_emac0_rx_ctl(hps_enet_rx_ctl),
      .hps_hps_io_emac0_txd0(hps_enet_tx_data[0]), .hps_hps_io_emac0_txd1(hps_enet_tx_data[1]),
      .hps_hps_io_emac0_rxd0(hps_enet_rx_data[0]), .hps_hps_io_emac0_rxd1(hps_enet_rx_data[1]),
      .hps_hps_io_emac0_txd2(hps_enet_tx_data[2]), .hps_hps_io_emac0_txd3(hps_enet_tx_data[3]),
      .hps_hps_io_emac0_rxd2(hps_enet_rx_data[2]), .hps_hps_io_emac0_rxd3(hps_enet_rx_data[3]),
      .hps_hps_io_mdio0_mdio(hps_enet_mdio), .hps_hps_io_mdio0_mdc(hps_enet_mdc),
      .hps_hps_io_uart1_tx(hps_uart_tx), .hps_hps_io_uart1_rx(hps_uart_rx),
      .hps_hps_io_i2c1_sda(hps_i2c_sda), .hps_hps_io_i2c1_scl(hps_i2c_scl),
      .hps_hps_io_gpio28(hps_gsensor_int), .hps_hps_io_gpio40(hps_key),
      .hps_hps_io_gpio41(hps_led),
      // Resets and the two general-purpose words.
      .hps_h2f_reset_reset(h2f_reset),
      .hps_hps_gp_gp_in(gp_in), .hps_hps_gp_gp_out(gp_out),
      .hps_h2f_warm_reset_handshake_reset_req(warm_req_n),
      .hps_h2f_warm_reset_handshake_reset_ack(warm_ack_n),
      // The processor-to-fabric bridge.
      .hps_hps2fpga_axi_clock_clk(clk), .hps_hps2fpga_axi_reset_reset(h2f_reset),
      .hps_hps2fpga_awid(h2f_awid), .hps_hps2fpga_awaddr(h2f_awaddr),
      .hps_hps2fpga_awlen(h2f_awlen), .hps_hps2fpga_awsize(h2f_awsize),
      .hps_hps2fpga_awburst(h2f_awburst), .hps_hps2fpga_awlock(h2f_awlock),
      .hps_hps2fpga_awcache(h2f_awcache), .hps_hps2fpga_awprot(h2f_awprot),
      .hps_hps2fpga_awvalid(h2f_awvalid), .hps_hps2fpga_awready(h2f_awready),
      .hps_hps2fpga_wdata(h2f_wdata), .hps_hps2fpga_wstrb(h2f_wstrb),
      .hps_hps2fpga_wlast(h2f_wlast), .hps_hps2fpga_wvalid(h2f_wvalid),
      .hps_hps2fpga_wready(h2f_wready),
      .hps_hps2fpga_bid(h2f_bid), .hps_hps2fpga_bresp(h2f_bresp),
      .hps_hps2fpga_bvalid(h2f_bvalid), .hps_hps2fpga_bready(h2f_bready),
      .hps_hps2fpga_arid(h2f_arid), .hps_hps2fpga_araddr(h2f_araddr),
      .hps_hps2fpga_arlen(h2f_arlen), .hps_hps2fpga_arsize(h2f_arsize),
      .hps_hps2fpga_arburst(h2f_arburst), .hps_hps2fpga_arlock(h2f_arlock),
      .hps_hps2fpga_arcache(h2f_arcache), .hps_hps2fpga_arprot(h2f_arprot),
      .hps_hps2fpga_arvalid(h2f_arvalid), .hps_hps2fpga_arready(h2f_arready),
      .hps_hps2fpga_rid(h2f_rid), .hps_hps2fpga_rdata(h2f_rdata),
      .hps_hps2fpga_rresp(h2f_rresp), .hps_hps2fpga_rlast(h2f_rlast),
      .hps_hps2fpga_rvalid(h2f_rvalid), .hps_hps2fpga_rready(h2f_rready),
      // The lightweight bridge.
      .hps_lwhps2fpga_axi_clock_clk(clk), .hps_lwhps2fpga_axi_reset_reset(h2f_reset),
      .hps_lwhps2fpga_awid(lw_awid), .hps_lwhps2fpga_awaddr(lw_awaddr),
      .hps_lwhps2fpga_awlen(lw_awlen), .hps_lwhps2fpga_awsize(lw_awsize),
      .hps_lwhps2fpga_awburst(lw_awburst), .hps_lwhps2fpga_awlock(lw_awlock),
      .hps_lwhps2fpga_awcache(lw_awcache), .hps_lwhps2fpga_awprot(lw_awprot),
      .hps_lwhps2fpga_awvalid(lw_awvalid), .hps_lwhps2fpga_awready(lw_awready),
      .hps_lwhps2fpga_wdata(lw_wdata), .hps_lwhps2fpga_wstrb(lw_wstrb),
      .hps_lwhps2fpga_wlast(lw_wlast), .hps_lwhps2fpga_wvalid(lw_wvalid),
      .hps_lwhps2fpga_wready(lw_wready),
      .hps_lwhps2fpga_bid(lw_bid), .hps_lwhps2fpga_bresp(lw_bresp),
      .hps_lwhps2fpga_bvalid(lw_bvalid), .hps_lwhps2fpga_bready(lw_bready),
      .hps_lwhps2fpga_arid(lw_arid), .hps_lwhps2fpga_araddr(lw_araddr),
      .hps_lwhps2fpga_arlen(lw_arlen), .hps_lwhps2fpga_arsize(lw_arsize),
      .hps_lwhps2fpga_arburst(lw_arburst), .hps_lwhps2fpga_arlock(lw_arlock),
      .hps_lwhps2fpga_arcache(lw_arcache), .hps_lwhps2fpga_arprot(lw_arprot),
      .hps_lwhps2fpga_arvalid(lw_arvalid), .hps_lwhps2fpga_arready(lw_arready),
      .hps_lwhps2fpga_rid(lw_rid), .hps_lwhps2fpga_rdata(lw_rdata),
      .hps_lwhps2fpga_rresp(lw_rresp), .hps_lwhps2fpga_rlast(lw_rlast),
      .hps_lwhps2fpga_rvalid(lw_rvalid), .hps_lwhps2fpga_rready(lw_rready),
      // The fabric-to-SDRAM bridge.
      .hps_f2sdram_axi_clock_clk(clk), .hps_f2sdram_axi_reset_reset(h2f_reset),
      .hps_f2sdram_awid(f2s_awid), .hps_f2sdram_awaddr(f2s_awaddr),
      .hps_f2sdram_awlen(f2s_awlen), .hps_f2sdram_awsize(f2s_awsize),
      .hps_f2sdram_awburst(f2s_awburst), .hps_f2sdram_awlock(f2s_awlock),
      .hps_f2sdram_awcache(f2s_awcache), .hps_f2sdram_awprot(f2s_awprot),
      .hps_f2sdram_awqos(f2s_awqos), .hps_f2sdram_awregion(f2s_awregion),
      .hps_f2sdram_awuser(f2s_awuser),
      .hps_f2sdram_awvalid(f2s_awvalid), .hps_f2sdram_awready(f2s_awready),
      .hps_f2sdram_wdata(f2s_wdata), .hps_f2sdram_wstrb(f2s_wstrb),
      .hps_f2sdram_wlast(f2s_wlast), .hps_f2sdram_wuser(f2s_wuser),
      .hps_f2sdram_wvalid(f2s_wvalid), .hps_f2sdram_wready(f2s_wready),
      .hps_f2sdram_bid(f2s_bid), .hps_f2sdram_bresp(f2s_bresp),
      .hps_f2sdram_buser(f2s_buser),
      .hps_f2sdram_bvalid(f2s_bvalid), .hps_f2sdram_bready(f2s_bready),
      .hps_f2sdram_arid(f2s_arid), .hps_f2sdram_araddr(f2s_araddr),
      .hps_f2sdram_arlen(f2s_arlen), .hps_f2sdram_arsize(f2s_arsize),
      .hps_f2sdram_arburst(f2s_arburst), .hps_f2sdram_arlock(f2s_arlock),
      .hps_f2sdram_arcache(f2s_arcache), .hps_f2sdram_arprot(f2s_arprot),
      .hps_f2sdram_arqos(f2s_arqos), .hps_f2sdram_arregion(f2s_arregion),
      .hps_f2sdram_aruser(f2s_aruser),
      .hps_f2sdram_arvalid(f2s_arvalid), .hps_f2sdram_arready(f2s_arready),
      .hps_f2sdram_rid(f2s_rid), .hps_f2sdram_rdata(f2s_rdata),
      .hps_f2sdram_rresp(f2s_rresp), .hps_f2sdram_rlast(f2s_rlast),
      .hps_f2sdram_ruser(f2s_ruser),
      .hps_f2sdram_rvalid(f2s_rvalid), .hps_f2sdram_rready(f2s_rready)
  );

  // **THE MACHINE'S MEMORY PORT ON THE BRIDGE**: the gate, the adapter, the
  // beat, the share and the tally, all in `rtl/plumbing/cadr_f2sdram_port.sv`
  // where `tb/cadr_f2sdram_tb.cpp` runs the machine through them.  The pack
  // side's and the display's ports of the share are tied off: neither exists
  // on this board yet.  Their valids are low, so nothing is ever granted to
  // them, and their readies are high, so a response to them would be taken.
  /* verilator lint_off PINCONNECTEMPTY */
  cadr_f2sdram_port u_memory (
      .clk(clk), .rst(rst),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(),
      .h2f_reset(h2f_reset), .gp_open(gp_out[0]), .gp_half(gp_out[1]),
      .warm_req_n(warm_req_n), .warm_ack_n(warm_ack_n),
      .gp_in(gp_in), .live(port_live),
      .p_awaddr(32'd0), .p_awlen(4'd0), .p_awsize(2'd0), .p_awburst(2'd0),
      .p_awvalid(1'b0), .p_awready(),
      .p_wdata(64'd0), .p_wstrb(8'd0), .p_wlast(1'b0), .p_wvalid(1'b0),
      .p_wready(), .p_bresp(), .p_bvalid(), .p_bready(1'b1),
      .p_araddr(32'd0), .p_arlen(4'd0), .p_arsize(2'd0), .p_arburst(2'd0),
      .p_arvalid(1'b0), .p_arready(),
      .p_rdata(), .p_rresp(), .p_rlast(), .p_rvalid(), .p_rready(1'b1),
      .d_araddr(32'd0), .d_arlen(4'd0), .d_arsize(2'd0), .d_arburst(2'd0),
      .d_arvalid(1'b0), .d_arready(),
      .d_rdata(), .d_rresp(), .d_rlast(), .d_rvalid(), .d_rready(1'b1),
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
  /* verilator lint_on PINCONNECTEMPTY */

  // **EVERY ADDRESS OF BOTH PROCESSOR-TO-FABRIC BRIDGES IS ANSWERED**, by the
  // default slave the Zynq boards put on `M_AXI_GP0`, at these bridges' AXI4
  // shape: a read gets OKAY and "NONE" in every beat, and a write is taken and
  // dropped.  On the Zynq a read nothing answers froze both Arm cores; nothing
  // says these bridges are kinder, and the faces that will sit here are a
  // later slice's.  Its reset is the bridges' own, the processor's
  // `h2f_reset`, synchronized in.
  logic [2:0] h2f_rst_s;
  always_ff @(posedge clk) h2f_rst_s <= {h2f_rst_s[1:0], h2f_reset};

  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_h2f_default (
      .clk(clk), .rst(rst || h2f_rst_s[2]),
      .s_awvalid(h2f_awvalid), .s_awid(h2f_awid), .s_awready(h2f_awready),
      .s_wlast(h2f_wlast), .s_wvalid(h2f_wvalid), .s_wready(h2f_wready),
      .s_bresp(h2f_bresp), .s_bid(h2f_bid), .s_bvalid(h2f_bvalid),
      .s_bready(h2f_bready),
      .s_arlen(h2f_arlen), .s_arid(h2f_arid), .s_arvalid(h2f_arvalid),
      .s_arready(h2f_arready), .s_rdata(h2f_rdata), .s_rresp(h2f_rresp),
      .s_rid(h2f_rid), .s_rlast(h2f_rlast), .s_rvalid(h2f_rvalid),
      .s_rready(h2f_rready)
  );

  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_lw_default (
      .clk(clk), .rst(rst || h2f_rst_s[2]),
      .s_awvalid(lw_awvalid), .s_awid(lw_awid), .s_awready(lw_awready),
      .s_wlast(lw_wlast), .s_wvalid(lw_wvalid), .s_wready(lw_wready),
      .s_bresp(lw_bresp), .s_bid(lw_bid), .s_bvalid(lw_bvalid),
      .s_bready(lw_bready),
      .s_arlen(lw_arlen), .s_arid(lw_arid), .s_arvalid(lw_arvalid),
      .s_arready(lw_arready), .s_rdata(lw_rdata), .s_rresp(lw_rresp),
      .s_rid(lw_rid), .s_rlast(lw_rlast), .s_rvalid(lw_rvalid),
      .s_rready(lw_rready)
  );

  // What a default slave does not read, and what the bridge answers the
  // share with that AXI4 has and the share does not use: the user fields of
  // a response.  The upper thirty general-purpose output bits are software's,
  // for nothing yet.
  /* verilator lint_off UNUSEDSIGNAL */
  logic hps_unused;
  assign hps_unused = ^{h2f_awaddr, h2f_awlen, h2f_awsize, h2f_awburst,
                        h2f_awlock, h2f_awcache, h2f_awprot, h2f_wdata,
                        h2f_wstrb, h2f_araddr, h2f_arsize, h2f_arburst,
                        h2f_arlock, h2f_arcache, h2f_arprot,
                        lw_awaddr, lw_awlen, lw_awsize, lw_awburst, lw_awlock,
                        lw_awcache, lw_awprot, lw_wdata, lw_wstrb, lw_araddr,
                        lw_arsize, lw_arburst, lw_arlock, lw_arcache,
                        lw_arprot, f2s_buser, f2s_ruser, gp_out[31:2]};
  /* verilator lint_on UNUSEDSIGNAL */
`else
  // NO MEMORY: the machine's cycles to it end on the NXM timer.
  assign mem_done  = 1'b0;
  assign mem_rdata = 32'd0;
  assign port_live = 1'b0;
`endif

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
  // LEDR6 the memory port open, on the memory board, and LEDR7 is dark.
  assign led = ~{1'b0, port_live, promenable, errhalt_lit,
                 disk_lit, cycle_lamp, clock_lamp, machrun_lamp};

  // SW1 to SW3 are pins this board has and this design gives no meaning.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, sw[3:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
