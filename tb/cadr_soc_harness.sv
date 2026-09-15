// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system, the machine and the four faces, wired as
// `boards/arty-a7-100/cadr_arty_a7.sv` wires them --- and running the firmware
// the board runs.
//
// **WHY THERE IS A HARNESS AT ALL.**  Verilator has no `MMCME2_BASE`, so the
// Arty A7's top level cannot be simulated; what it gets is lint, and this is
// what gets simulated instead.  Everything below the clock is the top level's,
// instance for instance and wire for wire: `cadr_soc`, `cadr_machine` with
// MIT's boot PROM, `cadr_disk_pack`, `cadr_console`, `cadr_gp0_default` and
// `cadr_dbg_join`, at the same parameters and the same addresses.  What is
// left out is the MMCM, the lamps, the buttons, the probe and the debug
// cable's connector, none of which a firmware can see.
//
// **AND THE DEBUG CABLE'S REGISTER WINDOW IS NOT HERE BECAUSE IT IS NOT ON
// THE BOARD.**  `rtl/plumbing/cadr_debug_window.sv` is how muir, on a Zynq
// board's own ARM cores, plays the far end of MIT's debug cable in software.
// There is no such program on an Arty A7-100: its debugger is a SECOND BOARD
// on the Pmod, which reaches the machine's DBGIN page through the cable's own
// carrier.  So the soft system masters three faces here and not four,
// `0x8000_1000` is an address the catch-all answers "NONE", and
// `rtl/plumbing/cadr_dbg_join.sv` has one arm empty --- all three of which
// `tb/cadr_soc_tb.cpp` asserts rather than takes on trust.
//
// **AND THIS IS A SECOND DESCRIPTION OF ONE COMPOSITION, WHICH IS A HAZARD
// AND IS NAMED HERE RATHER THAN HIDDEN.**  `tb/cadr_console_harness.sv` and
// `tb/cadr_probe_harness.sv` are in the same position and say so.  What keeps
// the two honest: `make build/arty_a7.pass` lints the REAL top level in all
// three of its configurations, so a port added to `cadr_machine` or to
// `cadr_soc` and connected in only one of the two files is a Verilator
// PINMISSING in the other.  What that does NOT catch is a wire crossed the
// same way in both, and a crossing which leaves every signal read is caught by
// nothing, anywhere, by any tool.  The answer to that is the firmware: it
// reads an identifier at every face and holds it to the constant the face's
// own header gives, so a face wired where another should be says so on the
// wire.
//
// **THE MACHINE IS THE REAL ONE AND NOTHING ANSWERS ITS MEMORY PORT**, which
// is the Arty A7-100's own memory-off configuration --- `mem_done` low,
// `mem_rdata` zero, every main-memory cycle ending on the 4.25 us
// non-existent-memory timer.  So the machine runs MIT's boot PROM for ever,
// which is exactly what a console is for: it is running, it can be halted, it
// can be stepped, and it can be started again.
//
// WHAT THIS ADDS THAT THE BOARD HAS NOT GOT.  Only observation, and all of it
// is output:
//
//   `clock_edge_o`  the machine's own microcycle boundary, one tick high per
//                   microcycle.  **This is how the check knows the machine
//                   really halted and really stepped**, independently of
//                   anything the firmware says about itself: a halted machine
//                   retires none of these and a stepped one retires exactly
//                   one.  A check that believed the firmware's own arithmetic
//                   would be a check written to confirm rather than to compare
//   `machrun_o`     `MACHRUN` as a level, beside it
//   `aw_v_o`, `ar_v_o`  which of the four slaves the bridge is speaking to.
//                   Exactly one bit may be up at a time and a read and a write
//                   may never be in flight together --- the seriality
//                   `cadr_soc_axi.sv` rests its single held selection on, and
//                   a property stated in a header is not a property until
//                   something looks every tick
//   `hs_o`          the five channels' handshakes, so the check can count
//                   transactions rather than infer them

`default_nettype none

module cadr_soc_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    // MIT's TV sync PROM, which `rtl/machine/cadr_tv.sv` reads at
    // elaboration; passed down beside the boot PROM's image for the same
    // reason, so that a model built anywhere finds it.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex",
    parameter string FIRMWARE_HEX = "build/soc_firmware.hex",
    parameter int unsigned SOC_RAM_WORDS = 8192,
    // **THE RATE IS A PARAMETER AND THE CHECK SETS IT.**  The board builds at
    // 115,200, where one bit is 868 ticks and the firmware's dozen lines are
    // some eight million of them; the check builds at a rate whose divisor is
    // small, so that the same firmware, byte for byte, says the same words in
    // a minute rather than in ten.  Nothing in the firmware knows the rate ---
    // it polls a ready bit --- so this changes what the check costs and not
    // what it checks.  `tb/cadr_soc_tb.cpp` decodes at whatever divisor it is
    // given and asserts the divisor it computed, so a rate that did not reach
    // the fabric is a failure and not a silent pass.
    parameter int unsigned SOC_BAUD = 115_200,
    // The soft system's own clock in hertz --- the board's `CLKOUT2` and not
    // its tick.  The UART's divisor and the timer's microsecond are both
    // computed from it, and both are on the soft side of the crossing.
    parameter int unsigned CLK_HZ = 50_000_000,
    // **WHICH BUILD THE FABRIC SAYS IT IS**, page 2's word 32.  On the board
    // this is `rtl/plumbing/xilinx7/cadr_usr_access.sv` reading the part's
    // AXSS register, which `tools/build_stamp.tcl` loaded from the bitstream;
    // there is no such primitive under Verilator, so the CHECK chooses it.
    //
    // **AND IT IS A VALUE THIS TREE'S STAMP COULD NOT BE**, on purpose: a
    // check that read back whatever the fabric happened to hold would be
    // confirming rather than comparing, which is the `md` trap this project
    // already records.  `tb/cadr_soc_tb.cpp` asserts the firmware's banner
    // against the number it passed in, so the whole road --- the port, the
    // console's page 2, the AXI bridge, the decode and the sentence --- is
    // held by one line.
    parameter logic [31:0] BUILD_STAMP = 32'h5A1B_2C33
) (
    // **TWO CLOCKS, AND THE CHECK DRIVES THEM AT A RATIO.**  `clk` is the
    // machine's tick and everything the board clocks with it --- the machine,
    // the four faces and the soft system's own AXI bridge.  `clk_soc` is the
    // soft processing system's, which on the board is `CLKOUT2` of the same
    // clock manager and is slower, because Ibex computes a load or a store's
    // address in the cycle it uses it and that arc does not fit in the
    // machine's tick.  `rtl/plumbing/cadr_soc_cross.sv` is the seam.
    //
    // There is no clock manager under Verilator, so the RATIO is the check's
    // to choose, and `tb/cadr_soc_tb.cpp` runs the whole firmware at
    // several --- the
    // board's own, and two that share no factor with it in either direction.
    // A crossing that worked only at the number the board happens to use
    // would be a crossing held to nothing.
    input  var logic        clk,
    input  var logic        clk_soc,
    input  var logic        rst,

    output var logic        uart_tx,
    input  var logic        uart_rx,

    output var logic        clock_edge_o,
    output var logic        machrun_o,
    output var logic        mach_rst_o,
    // Per slave: the pack side, the console, the default.  THREE and not
    // four: the debug cable's window is not on this board and the header
    // above says why.
    output var logic [2:0]  aw_v_o,
    output var logic [2:0]  ar_v_o,
    // {aw, w, b, ar, r} handshakes this tick, ORed over the three slaves.
    output var logic [4:0]  hs_o,
    // The join in front of the machine's DBGIN page.  `dbg_holder_o` is which
    // arm has it --- 0 the window's, 1 the connector's --- `dbg_win_req_o` is
    // the window's arm asking, and `dbg_req_o` is what comes out of the join
    // and reaches `cadr_dbgin.sv`.  All three are here so that the empty arm
    // is held to being empty every tick rather than by reading the tie-off.
    output var logic        dbg_holder_o,
    output var logic        dbg_win_req_o,
    output var logic        dbg_req_o
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
  logic [31:0] mem_addr, mem_wdata;
  // MEM<31:0> on its way to an Xbus slave.  No slave exists, so nothing reads
  // it --- but it is an output of `cadr_machine` and the fold below is what
  // keeps it from being deleted along with whatever computes it.
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge, wrcyc;
  logic device, dev_rq, dev_write, promdisable, promenable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, timed_out, mbusy, mbusy_sync;
  logic mem_req, mem_write;
  // The answer from whatever is behind the memory port.  There is nothing
  // behind it on this board: see the tie-offs below.
  logic mem_done;
  logic port_read_ack, port_write_ack;
  logic [31:0] mem_rdata;
  // The disk's two seams: the drive --- which units have a pack, the
  // read-only switch, whether the drive's time is charged --- and the block
  // store's fill port.
  logic [7:0]  drive_present, drive_read_only;
  logic        drive_timed;
  logic        store_we;
  logic [4:0]  store_slot;
  logic [8:0]  store_addr;
  logic [31:0] store_wdata, store_rdata;
  logic        store_miss, ch_active, store_busy;
  // OLORD1's three, for the lamps: the machine's own run signal as a level,
  // and the two ways it stops itself.
  logic        machrun, errhalt, stathalt;
  // `-BOOT`, the 74S02 at OLORD2 1A07's output, out of the machine because the
  // error lamp is cleared by it and nothing out here can otherwise tell that a
  // keyboard chord or the debug cable booted the machine.
  logic        n_boot;
  // -XBUS.INTR, the display's vertical interrupt ORed with the disk's request
  // inside `cadr_machine`.  Nothing on this board reads it but the fold.
  logic        sintr;
  // The request path and the cache's bookkeeping: the block the walk lacks
  // and its posting, the wait, the store's denial, the slot the walk is on
  // and what it did to it.
  logic [4:0]  store_busy_slot, ch_slot;
  logic [30:0] req_tag;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit, store_deny;
  // The console's own two effects on the machine: the reset its word 6 makes
  // and the light panel's button its word 13 presses.  Both are pulses of a
  // stated length made inside `cadr_console.sv`, and both join a term the
  // board already has rather than replacing it --- BTN3 for the first and
  // BTN0 for the second.  Zero with no soft processing system.
  logic        con_mach_rst, con_boot;
  // The disk pack side's interrupt.  On the Zynq it reaches `IRQ_F2P` and
  // Linux; here it reaches the soft core's external interrupt.
  logic        pack_irq;
  // What the soft processing system transmits, and the fold that keeps the
  // pack side's unanswered memory port from being trimmed.  See the
  // instantiation.
  logic        hp_fold;
  // The join's two arms, and what comes out of it at the machine's DBGIN page.
  // `dbg_in_*` is the arm the two Zynq boards give the register window and
  // this board gives nobody; `cab_*` is the arm the Pmod connector drives,
  // which is not in this harness either --- what is held here is that an
  // empty join never asks.  See the tie-offs below.
  logic        dbg_in_req, dbg_in_wr;
  logic [1:0]  dbg_in_a;
  logic [15:0] dbd_to_machine;
  logic        cab_req, cab_wr;
  logic [1:0]  cab_a;
  logic [15:0] cab_dbd;
  logic        mdbg_req, mdbg_wr;
  logic [1:0]  mdbg_a;
  logic [15:0] mdbg_dbd;
  logic        dbg_holder;
  // The console's half of the diagnostic bus.
  logic        con_req, con_gnt, con_msyn, con_write, con_ssyn;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  // MIT's debug cable, the DBGIN connector's twenty-one wires.
  logic        dbg_in_ack;
  logic [1:0]  dbd_oe;
  logic [15:0] dbd_from_machine;
  logic        dbg_connect;
  logic [1:0]  dbg_wiring;
  logic        dbgout_req, dbgout_wr;
  logic [1:0]  dbgout_a;
  logic [15:0] dbgout_dbd;
  // The modifier register's two effects.  `debuggee_reset` is bit 1 and is
  // this processor's power-on reset, so it joins the reset OR below;
  // `timeout_inhibit` is bit 2 and nothing consumes it yet, so it folds.
  logic        debuggee_reset, timeout_inhibit;
  // The virtual address register, `Q` and `MD` taken at the microcycle
  // boundary, and the readout of the machine's memories.  With no console
  // nothing asks and all of them fold.
  logic [31:0] con_vma, con_q, con_md;
  logic [17:0] con_ro_addr, con_ro_echo;
  logic [47:0] con_ro_data;
  // The I/O board's four cables and what the card shows.
  logic        kbd_strobe;
  logic [23:0] kbd_code;
  logic [6:0]  mouse_lines;
  logic        ser_tx_take, ser_tx_done, ser_rx_strobe, ser_plugged;
  logic [7:0]  ser_rx_data;
  logic        ser_rx_end, ser_rx_parity, ser_rx_framing;
  logic [15:0] chaos_address, chaos_rx_word;
  logic        chaos_rx_valid, chaos_rx_done, chaos_rx_crc;
  logic [12:0] chaos_rx_bits;
  logic        chaos_tx_done, chaos_tx_abort, chaos_cbl_busy;
  logic [2:0]  ub_ssyn_by;
  logic        ser_reset, iob_intr, audio, clock_ready;
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

  // ---------------------------------------------------------- the machine
  //
  // The tie-offs the top level makes for a board with no memory controller and
  // no I/O cables.  Every one is that file's, with its reasons; they are
  // repeated here and not explained again.
  assign mem_done      = 1'b0;
  assign mem_rdata     = 32'd0;
  assign port_read_ack  = 1'b0;
  assign port_write_ack = 1'b0;
  assign ser_tx_take    = 1'b0;
  assign ser_tx_done    = 1'b0;
  assign ser_rx_strobe  = 1'b0;
  assign ser_rx_data    = 8'd0;
  assign ser_rx_end     = 1'b0;
  assign ser_rx_parity  = 1'b0;
  assign ser_rx_framing = 1'b0;
  assign ser_plugged    = 1'b0;
  assign chaos_address  = 16'd0;
  assign chaos_rx_valid = 1'b0;
  assign chaos_rx_word  = 16'd0;
  assign chaos_rx_done  = 1'b0;
  assign chaos_rx_bits  = 13'd0;
  assign chaos_rx_crc   = 1'b0;
  assign chaos_tx_done  = 1'b0;
  assign chaos_tx_abort = 1'b0;
  assign chaos_cbl_busy = 1'b0;
  assign kbd_strobe     = 1'b0;
  assign kbd_code       = 24'd0;
  assign mouse_lines    = 7'h7F;

  // SW0 is not a pin here: the board's no-auto-boot switch is off, so the
  // machine comes out of reset running its boot PROM, which is the state a
  // console is interesting about.  `sw0_held` follows `mach_rst` as it does
  // on the board, off the same edge, so what the console reports is what the
  // machine came up with.
  logic sw0_level, sw0_held;
  assign sw0_level = 1'b0;
  always_ff @(posedge clk) if (mach_rst) sw0_held <= sw0_level;

  // The machine's reset as the top level makes it: this harness's own `rst`,
  // the debug cable's modifier bit, or the console's own pulse, registered.
  logic mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || debuggee_reset || con_mach_rst;

  // `-BOOT2` with no button on the board: the console's press is the only
  // driver, and the inversion is here because the line is pulled up and has
  // two drivers on a real panel.
  logic n_boot2;
  assign n_boot2 = !con_boot;

  logic        con_tv_lispm, con_color_tv;
  logic [3:0]  con_tv_map_a;
  logic [23:0] con_tv_map_q, con_tv_color_map_q;

  cadr_machine #(
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(mach_rst),
      // Nothing answers a device cycle from outside: the Xbus slaves that are
      // not the disk are their own slices and none of them exists on any
      // board.  `sintr_o` is the machine's own line to its own processor, the
      // display's vertical interrupt ORed with the disk's request, and it is
      // folded out here like every other output.
      .sintr_o(sintr), .device_ack(1'b0), .device_rdata(32'd0),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed),
      .store_we(store_we), .store_slot(store_slot), .store_addr(store_addr),
      .store_wdata(store_wdata), .store_rdata(store_rdata),
      .store_miss(store_miss), .ch_active(ch_active), .store_busy(store_busy),
      .store_busy_slot(store_busy_slot), .store_deny(store_deny),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit),
      // 32 boards of 64K words, which is muir's own default and what every
      // trace in this repository was taken with.  System 100 cannot cold-boot
      // with 40 or more, measured, so this number is not a knob.
      .boards(7'd32),
      // **THE BACKPLANE'S DISPLAY BOARDS, wired to the console as the board
      // wires them**, which is this harness's own rule: the whole point is to
      // be `boards/arty-a7-100/cadr_arty_a7.sv` instance for instance.  A
      // machine comes up with one SIMPLE TV and no color board and nothing
      // here writes word 33, so this is the default backplane throughout.
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv), .tv_map_a(con_tv_map_a),
      .tv_map_q(con_tv_map_q), .tv_color_map_q(con_tv_color_map_q),
      // The absence of a memory: see the tie-offs above.
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      .pc(pc), .lpc(lpc), .opc(opc), .st(st), .ir(ir), .a(a), .m(m),
      .alu(alu), .r(r), .ob(ob), .q(q), .dc(dc), .lc(lc), .vma(vma),
      .md(md), .vmaok(vmaok), .jcond(jcond), .nop(nop), .pcs1(pcs1),
      .pcs0(pcs0), .iwrited(iwrited), .clock_edge(clock_edge),
      .wrcyc(wrcyc), .device(device), .dev_rq(dev_rq),
      .dev_write(dev_write), .dev_wdata(dev_wdata),
      .phys(phys), .promdisable(promdisable), .promenable(promenable),
      .ub_msyn(ub_msyn), .ub_ssyn_o(ub_ssyn), .arb_stage(arb_stage),
      .n_memrq_o(n_memrq), .n_memack_o(n_memack),
      .n_memgrant_o(n_memgrant), .mbusy_o(mbusy), .mbusy_sync_o(mbusy_sync),
      .ub_addr_o(ub_addr),
      .ub_rdata_o(ub_rdata), .n_loadmd_o(n_loadmd), .rdcyc_o(rdcyc),
      .nxm(nxm), .unibus(unibus), .memstart(memstart),
      .timed_out(timed_out),
      .con_req(con_req), .con_gnt(con_gnt), .con_msyn(con_msyn),
      .con_write(con_write), .con_addr(con_addr), .con_wdata(con_wdata),
      .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      // MIT's debug cable, off `cadr_dbg_join.sv` below, exactly as the top
      // level takes it.  Both of the join's arms are idle here --- the window
      // that drives one of them on a Zynq is not on this board at all, and
      // there is no connector in a simulation of one board --- so nothing ever
      // asks, and what the machine would answer with is folded.
      .dbg_in_req(mdbg_req), .dbg_in_wr(mdbg_wr), .dbg_in_a(mdbg_a),
      .dbd_in(mdbg_dbd),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      // The DBGOUT page, which is this machine as somebody else's debugger.
      // No connector here, so it is tied as an unplugged cable: nothing at
      // the far end, the lines carried by the pull-ups, and the page answers
      // its own machine at `-UB MSYN`.  That is muir's `debug_cable` false.
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(1'b0),
      .dbgout_dbd_in(16'hFFFF), .dbgout_live(1'b0),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset: the BOARD's --- MMCM lock and BTN3 ---
      // and not `mach_rst`, which `debuggee_reset` is one term of.  See the
      // reset above for why that distinction is not tidiness.
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code), .n_boot2(n_boot2),
      // SW0, synchronized, read at the machine's own reset arms and nowhere
      // else --- the block above `cadr_machine` here says the whole of it ---
      // and `-BOOT` on its way back out, for the error lamp to be cleared by.
      .no_auto_boot(sw0_level), .n_boot_o(n_boot),
      .machrun(machrun), .errhalt(errhalt), .stathalt(stathalt),
      .mouse_lines(mouse_lines), .ser_reset(ser_reset),
      .ser_mode1(ser_mode1), .ser_mode2(ser_mode2), .ser_cmd(ser_cmd),
      .ser_tx_strobe(ser_tx_strobe), .ser_tx_data(ser_tx_data),
      .ser_tx_take(ser_tx_take), .ser_tx_done(ser_tx_done),
      .ser_rx_strobe(ser_rx_strobe), .ser_rx_data(ser_rx_data),
      .ser_rx_end(ser_rx_end), .ser_rx_parity(ser_rx_parity),
      .ser_rx_framing(ser_rx_framing),
      .ser_plugged(ser_plugged), .ser_status(ser_status),
      .ser_syn_face(ser_syn_face),
      .chaos_address(chaos_address), .chaos_tx_go(chaos_tx_go),
      .chaos_tx_len(chaos_tx_len), .chaos_tx_valid(chaos_tx_valid),
      .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word),
      .chaos_rx_done(chaos_rx_done), .chaos_rx_bits(chaos_rx_bits),
      .chaos_rx_crc(chaos_rx_crc), .chaos_tx_done(chaos_tx_done),
      .chaos_tx_abort(chaos_tx_abort), .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      .ub_ssyn_by(ub_ssyn_by),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      // What the port itself answered, for the transaction audit inside the
      // machine.  There is no port here, so both are low and the audit's port
      // clause says nothing --- which is the truth on this board rather than
      // a silence to be read as agreement.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack)
  );



  // The four AXI ports, as `cadr_soc.sv` drives them.  AXI3 in shape, single
  // beat in use; `cadr_soc_axi.sv`'s header says why that is what the faces
  // were written for.
  logic [31:0] pk_awaddr, pk_wdata, pk_araddr, pk_rdata;
  logic [3:0]  pk_awlen, pk_wstrb, pk_arlen;
  logic [11:0] pk_awid, pk_bid, pk_arid, pk_rid;
  logic [1:0]  pk_bresp, pk_rresp;
  logic        pk_awvalid, pk_awready, pk_wlast, pk_wvalid, pk_wready;
  logic        pk_bvalid, pk_bready, pk_arvalid, pk_arready;
  logic        pk_rlast, pk_rvalid, pk_rready;

  logic [31:0] cn_awaddr, cn_wdata, cn_araddr, cn_rdata;
  logic [3:0]  cn_awlen, cn_wstrb, cn_arlen;
  logic [11:0] cn_awid, cn_bid, cn_arid, cn_rid;
  logic [1:0]  cn_bresp, cn_rresp;
  logic        cn_awvalid, cn_awready, cn_wlast, cn_wvalid, cn_wready;
  logic        cn_bvalid, cn_bready, cn_arvalid, cn_arready;
  logic        cn_rlast, cn_rvalid, cn_rready;

  logic [31:0] df_rdata;
  logic [3:0]  df_arlen;
  logic [11:0] df_awid, df_bid, df_arid, df_rid;
  logic [1:0]  df_bresp, df_rresp;
  logic        df_awvalid, df_awready, df_wlast, df_wvalid, df_wready;
  logic        df_bvalid, df_bready, df_arvalid, df_arready;
  logic        df_rlast, df_rvalid, df_rready;

  // The pack side's own memory port.  On the Zynq it is `S_AXI_HP2` into the
  // DDR controller, and a block crosses it eight bursts at a time.
  // **THERE IS NO MEMORY BEHIND IT HERE AND THE READY LINES ARE LOW, WHICH
  // MEANS A BLOCK FETCH WOULD STAND FOR EVER.**  That is said plainly rather
  // than answered with a plausible completion: a port that accepted an
  // address and returned a word of nothing would let the pack side report a
  // block it had not moved, and this project's whole method is against
  // instruments that can mean something they have not measured.  The
  // firmware asks for no block, and the memory controller this board is
  // waiting for is what will connect these.
  logic [31:0] hp_awaddr, hp_araddr;
  logic [3:0]  hp_awlen, hp_arlen;
  logic [1:0]  hp_awsize, hp_awburst, hp_arsize, hp_arburst;
  logic [63:0] hp_wdata;
  logic [7:0]  hp_wstrb;
  logic        hp_awvalid, hp_wlast, hp_wvalid, hp_bready, hp_arvalid,
               hp_rready;

  // ------------------------------------------------- the processing system
  cadr_soc #(
      .RAM_WORDS   (SOC_RAM_WORDS),
      .FIRMWARE_HEX(FIRMWARE_HEX),
      // **THE SOFT SYSTEM'S OWN CLOCK IN HERTZ, WHICH IS NOT THE MACHINE'S.**
      // On the board it is what `CLKOUT2` of the one clock manager makes; here
      // it is a parameter, and `tb/cadr_soc_tb.cpp` decodes the wire at
      // `CLK_HZ / SOC_BAUD` and asserts the divisor it measures, so a value
      // that did not reach the fabric is a failure.  It is the SOFT clock's
      // frequency and not the tick's, because the transmitter and the timer
      // are both on the soft side of the crossing.
      .CLK_HZ      (CLK_HZ),
      .BAUD        (SOC_BAUD)
  ) u_soc (
      // **THE BOARD's RESET AND NOT THE MACHINE's.**  A firmware reset by
      // the machine's reset could not make one: the store to the console's
      // word 6 would be in flight while the core holding it was being
      // cleared.  `cadr_console.sv`'s header has the same argument for the
      // console's own registers.
      .clk(clk_soc), .rst(rst),
      // The bridge and the four faces are on the machine's tick: what crosses
      // is one request and one answer, inside `cadr_soc`.
      .axi_clk(clk), .axi_rst(rst),
      .uart_tx(uart_tx), .uart_rx(uart_rx),
      .ext_irq(pack_irq),

      .pack_awaddr(pk_awaddr), .pack_awlen(pk_awlen), .pack_awid(pk_awid),
      .pack_awvalid(pk_awvalid), .pack_awready(pk_awready),
      .pack_wdata(pk_wdata), .pack_wstrb(pk_wstrb), .pack_wlast(pk_wlast),
      .pack_wvalid(pk_wvalid), .pack_wready(pk_wready),
      .pack_bresp(pk_bresp), .pack_bid(pk_bid), .pack_bvalid(pk_bvalid),
      .pack_bready(pk_bready),
      .pack_araddr(pk_araddr), .pack_arlen(pk_arlen), .pack_arid(pk_arid),
      .pack_arvalid(pk_arvalid), .pack_arready(pk_arready),
      .pack_rdata(pk_rdata), .pack_rresp(pk_rresp), .pack_rid(pk_rid),
      .pack_rlast(pk_rlast), .pack_rvalid(pk_rvalid), .pack_rready(pk_rready),

      .con_awaddr(cn_awaddr), .con_awlen(cn_awlen), .con_awid(cn_awid),
      .con_awvalid(cn_awvalid), .con_awready(cn_awready),
      .con_wdata(cn_wdata), .con_wstrb(cn_wstrb), .con_wlast(cn_wlast),
      .con_wvalid(cn_wvalid), .con_wready(cn_wready),
      .con_bresp(cn_bresp), .con_bid(cn_bid), .con_bvalid(cn_bvalid),
      .con_bready(cn_bready),
      .con_araddr(cn_araddr), .con_arlen(cn_arlen), .con_arid(cn_arid),
      .con_arvalid(cn_arvalid), .con_arready(cn_arready),
      .con_rdata(cn_rdata), .con_rresp(cn_rresp), .con_rid(cn_rid),
      .con_rlast(cn_rlast), .con_rvalid(cn_rvalid), .con_rready(cn_rready),

      .dflt_awid(df_awid), .dflt_awvalid(df_awvalid),
      .dflt_awready(df_awready),
      .dflt_wlast(df_wlast), .dflt_wvalid(df_wvalid), .dflt_wready(df_wready),
      .dflt_bresp(df_bresp), .dflt_bid(df_bid), .dflt_bvalid(df_bvalid),
      .dflt_bready(df_bready),
      .dflt_arlen(df_arlen), .dflt_arid(df_arid), .dflt_arvalid(df_arvalid),
      .dflt_arready(df_arready),
      .dflt_rdata(df_rdata), .dflt_rresp(df_rresp), .dflt_rid(df_rid),
      .dflt_rlast(df_rlast), .dflt_rvalid(df_rvalid), .dflt_rready(df_rready)
  );

  // ------------------------------------------------------ the disk pack side
  cadr_disk_pack u_pack (
      .clk(clk), .rst(rst),
      .s_awaddr(pk_awaddr), .s_awlen(pk_awlen), .s_awid(pk_awid),
      .s_awvalid(pk_awvalid), .s_awready(pk_awready),
      .s_wdata(pk_wdata), .s_wstrb(pk_wstrb), .s_wlast(pk_wlast),
      .s_wvalid(pk_wvalid), .s_wready(pk_wready),
      .s_bresp(pk_bresp), .s_bid(pk_bid), .s_bvalid(pk_bvalid),
      .s_bready(pk_bready),
      .s_araddr(pk_araddr), .s_arlen(pk_arlen), .s_arid(pk_arid),
      .s_arvalid(pk_arvalid), .s_arready(pk_arready),
      .s_rdata(pk_rdata), .s_rresp(pk_rresp), .s_rid(pk_rid),
      .s_rlast(pk_rlast), .s_rvalid(pk_rvalid), .s_rready(pk_rready),
      .m_awaddr(hp_awaddr), .m_awlen(hp_awlen), .m_awsize(hp_awsize),
      .m_awburst(hp_awburst), .m_awvalid(hp_awvalid), .m_awready(1'b0),
      .m_wdata(hp_wdata), .m_wstrb(hp_wstrb), .m_wlast(hp_wlast),
      .m_wvalid(hp_wvalid), .m_wready(1'b0),
      .m_bresp(2'b00), .m_bvalid(1'b0), .m_bready(hp_bready),
      .m_araddr(hp_araddr), .m_arlen(hp_arlen), .m_arsize(hp_arsize),
      .m_arburst(hp_arburst), .m_arvalid(hp_arvalid), .m_arready(1'b0),
      .m_rdata(64'd0), .m_rresp(2'b00), .m_rlast(1'b0), .m_rvalid(1'b0),
      .m_rready(hp_rready),
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

  // The memory port's outputs reach nothing, and a signal nothing reads is
  // trimmed along with whatever computes it --- which here is the block
  // store's whole read path.  The fold is what keeps it, exactly as
  // `witness` keeps the machine's outputs, and `witness` takes this in turn.
  always_ff @(posedge clk) begin
    if (rst) hp_fold <= 1'b0;
    else hp_fold <= ^{hp_awaddr, hp_awlen, hp_awsize, hp_awburst, hp_awvalid,
                      hp_wdata, hp_wstrb, hp_wlast, hp_wvalid, hp_bready,
                      hp_araddr, hp_arlen, hp_arsize, hp_arburst, hp_arvalid,
                      hp_rready};
  end

  // ------------------------------------------------------------- the console
  cadr_console u_console (
      .clk(clk), .rst(rst),
      .s_awaddr(cn_awaddr), .s_awlen(cn_awlen), .s_awid(cn_awid),
      .s_awvalid(cn_awvalid), .s_awready(cn_awready),
      .s_wdata(cn_wdata), .s_wstrb(cn_wstrb), .s_wlast(cn_wlast),
      .s_wvalid(cn_wvalid), .s_wready(cn_wready),
      .s_bresp(cn_bresp), .s_bid(cn_bid), .s_bvalid(cn_bvalid),
      .s_bready(cn_bready),
      .s_araddr(cn_araddr), .s_arlen(cn_arlen), .s_arid(cn_arid),
      .s_arvalid(cn_arvalid), .s_arready(cn_arready),
      .s_rdata(cn_rdata), .s_rresp(cn_rresp), .s_rid(cn_rid),
      .s_rlast(cn_rlast), .s_rvalid(cn_rvalid), .s_rready(cn_rready),
      .dbg_req(con_req), .dbg_gnt(con_gnt),
      .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
      .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
      .clock_edge(clock_edge),
      .mach_vma(con_vma), .mach_q(con_q), .mach_md(con_md),
      .build(BUILD_STAMP),
      .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
      .mach_rst(con_mach_rst), .mach_boot(con_boot),
      .no_auto_boot_held(sw0_held), .no_auto_boot_now(sw0_level),
      // The debug cable's role, page 0's word 14.  No connector in this
      // harness, so the four come back as a bare header and what the console
      // asks for is folded.
      .dbg_connect(dbg_connect), .dbg_wiring(dbg_wiring),
      .dbg_wire_state(3'd0), .dbg_frames(24'd0),
      .dbg_engaged(1'b0), .dbg_foreign(1'b0), .dbg_peer_far(1'b0),
      .dbg_live(1'b0), .dbg_active(1'b0),
      // The backplane's display boards, page 2's word 33, and the two color
      // maps on pages 4 and 5, wired to the machine as the board wires them.
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv), .tv_map_a(con_tv_map_a),
      .tv_map_q(con_tv_map_q), .tv_color_map_q(con_tv_color_map_q)
  );

  // ------------------------------------------- the machine's DBGIN page
  //
  // **THE JOIN WITH BOTH ARMS EMPTY, WHICH IS WHAT THIS BOARD'S IS WITH
  // NOTHING IN THE CONNECTOR.**  On the two Zynq boards `cadr_dbg_join.sv`
  // has a register window on one arm and the Pmod carrier on the other; this
  // board has no window at all, so the connector is its only master, and the
  // connector is not in this harness --- the pins are the top level's and
  // there is no far end in a simulation of one board.
  //
  // What an empty arm IS is the join's own word for an unplugged cable:
  // `a_req` low, which is `-DEBUG IN REQ` UP --- the sense the whole transport
  // uses --- with the levels beside it at zero, exactly as the SIP at DBGIN
  // 0A22 holds a connector with nothing on it.  `cadr_dbgin.sv` then makes no
  // strobe and never asks for the bus.
  //
  // **AND THAT IS ASSERTED AND NOT STATED.**  `tb/cadr_soc_tb.cpp` watches
  // `dbg_win_req_o`, `dbg_holder_o` and `dbg_req_o` every tick of the whole
  // run: the window's arm never asks, the holder never names it, and nothing
  // ever reaches the machine's DBGIN page.  A join whose empty arm asked
  // would take the page and hold it, and the console's own diagnostic cycles
  // are on the other side of that arbiter.
  assign dbg_in_req     = 1'b0;
  assign dbg_in_wr      = 1'b0;
  assign dbg_in_a       = 2'd0;
  assign dbd_to_machine = 16'd0;

  assign cab_req = 1'b0;
  assign cab_wr  = 1'b0;
  assign cab_a   = 2'd0;
  assign cab_dbd = 16'd0;

  cadr_dbg_join u_dbg_join (
      .clk(clk), .rst(rst),
      .a_req(dbg_in_req), .a_wr(dbg_in_wr), .a_a(dbg_in_a),
      .a_dbd(dbd_to_machine),
      .b_req(cab_req), .b_wr(cab_wr), .b_a(cab_a), .b_dbd(cab_dbd),
      .req(mdbg_req), .wr(mdbg_wr), .a(mdbg_a), .dbd(mdbg_dbd),
      .holder(dbg_holder)
  );

  // -------------------------------------------------- and everything else
  cadr_gp0_default u_dflt (
      .clk(clk), .rst(rst),
      .s_awvalid(df_awvalid), .s_awid(df_awid), .s_awready(df_awready),
      .s_wlast(df_wlast), .s_wvalid(df_wvalid), .s_wready(df_wready),
      .s_bresp(df_bresp), .s_bid(df_bid), .s_bvalid(df_bvalid),
      .s_bready(df_bready),
      .s_arlen(df_arlen), .s_arid(df_arid), .s_arvalid(df_arvalid),
      .s_arready(df_arready),
      .s_rdata(df_rdata), .s_rresp(df_rresp), .s_rid(df_rid),
      .s_rlast(df_rlast), .s_rvalid(df_rvalid), .s_rready(df_rready)
  );


  // ------------------------------------------------------- what a check sees
  assign clock_edge_o = clock_edge;
  assign machrun_o    = machrun;
  assign mach_rst_o   = mach_rst;

  assign aw_v_o = {df_awvalid, cn_awvalid, pk_awvalid};
  assign ar_v_o = {df_arvalid, cn_arvalid, pk_arvalid};
  assign hs_o   = {
      (pk_awvalid && pk_awready) || (cn_awvalid && cn_awready) ||
      (df_awvalid && df_awready),
      (pk_wvalid && pk_wready) || (cn_wvalid && cn_wready) ||
      (df_wvalid && df_wready),
      (pk_bvalid && pk_bready) || (cn_bvalid && cn_bready) ||
      (df_bvalid && df_bready),
      (pk_arvalid && pk_arready) || (cn_arvalid && cn_arready) ||
      (df_arvalid && df_arready),
      (pk_rvalid && pk_rready) || (cn_rvalid && cn_rready) ||
      (df_rvalid && df_rready)
  };

  assign dbg_holder_o  = dbg_holder;
  assign dbg_win_req_o = dbg_in_req;
  assign dbg_req_o     = mdbg_req;

  // Everything `cadr_machine` brings out that nothing above reads, held so
  // that Verilator does not call it unused and so that this harness's port
  // list is about what a check watches rather than about what a module emits.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, pc, lpc, opc, st, ir, a, m, alu, r, ob, q, dc, lc,
                    vma, md, phys, ub_addr, ub_rdata, arb_stage, mem_addr,
                    mem_wdata, dev_wdata, vmaok, jcond, nop, pcs1, pcs0,
                    iwrited, wrcyc, device, dev_rq, dev_write, promdisable,
                    promenable,
                    ub_msyn, ub_ssyn, n_memrq, n_memack, n_memgrant, n_loadmd,
                    rdcyc, nxm, unibus, memstart, timed_out, mbusy, mbusy_sync,
                    mem_req, mem_write, errhalt, stathalt, n_boot, sintr,
                    timeout_inhibit, hp_fold, sw0_held, pack_irq,
                    ser_mode1, ser_mode2, ser_cmd, ser_tx_strobe, ser_tx_data,
                    ser_status, ser_syn_face, ser_reset, iob_intr, iob_vector,
                    audio, csr_face, mouse_x, mouse_y, clock_ready, interval,
                    ub_ssyn_by, chaos_tx_go, chaos_tx_len, chaos_tx_valid,
                    chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                    chaos_bits, store_rdata, store_miss, ch_active, con_gnt,
                    con_ssyn, con_rdata, con_vma, con_q, con_md, con_ro_data,
                    con_ro_echo, req_valid, req_tag, req_post, ch_waiting,
                    ch_slot, ch_wrote, ch_hit, dbg_in_ack, dbd_from_machine,
                    dbd_oe, dbgout_req, dbgout_wr, dbgout_a, dbgout_dbd,
                    dbg_connect, dbg_wiring};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
