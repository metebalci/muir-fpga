// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on an AMD Kria KR260: a top level with real pins.
//
// **THIS IS THE CORA Z7-07S's TOP LEVEL ON A ZYNQ ULTRASCALE+, AND NOTHING IN
// `rtl/machine/` CHANGES BETWEEN THEM.**  A board is a top level, a pin file,
// a processing-system configuration and a device tree; the machine does not
// know what part it is on.  So this file is `boards/cora-z7-07s/cadr_cora.sv`
// with the differences below, each a fact of the board or of the part.  Where
// a choice carries over unchanged its argument is in that file and in
// `boards/arty-z7-20/cadr_arty.sv`, and is not repeated here.
//
//   - **THE CLOCK IS THE CARRIER'S 25 MHz, ON C3, THROUGH AN `MMCME4_BASE`.**
//     25 x 40 = 1000 MHz at the VCO, divided by 10: the tick is 10 ns and the
//     VCO is 1000 MHz exactly, so `CLKOUT0_DIVIDE_F` still reads as the tick
//     in nanoseconds and `boards/arty-z7-20/vivado/tick.tcl` reads it here as
//     it does on the other boards.  Not the processing system's `pl_clk0`:
//     the kernel gates `pl_clk0` and `pl_clk1` at late start-up because no
//     driver claims them (measured on the board), and a machine whose clock
//     depends on the processing system's software is not the machine the
//     other boards build.  Nothing here depends on any `pl_clk`.
//   - **THE PROCESSING SYSTEM IS A `PS8`**, `boards/kria-kr260/cadr_ps8.sv`,
//     generated from Xilinx's own primitive as the Zynq-7000's `PS7` wrapper
//     is.  The faces are on `M_AXI_HPM0_FPD` at 0xA000_0000 and the console
//     and debug window on `M_AXI_HPM1_FPD` at 0xB000_0000 (UG1085 table
//     10-1), with the same offsets as on the Zynq-7000's `M_AXI_GP0` and
//     `M_AXI_GP1`; main memory is on `S_AXI_HP0_FPD` and the pack side on
//     `S_AXI_HP2_FPD`.
//   - **EVERY PORT IS 128 BITS WIDE, AND THE FABRIC MEETS THEM AT THAT
//     WIDTH.**  The widths are registers of the processing system, and the
//     board's boot firmware leaves every one at its reset value, 128 bits;
//     loading a bitstream does not change them (read on the board).  Writing
//     them to 32 and 64 before each load would let the Zynq-7000's plumbing
//     carry over untouched, but would make the machine's memory depend on a
//     register write somebody has to remember on every path that loads a
//     bitstream, and a fabric built for one width on a port left at another
//     is not an error anywhere: words land in the wrong lanes.  So the
//     fabric is built for what the part comes up with, in three small
//     modules that each have a check: `rtl/plumbing/cadr_axi_lanes128.sv`
//     puts the 32-bit faces on the two master ports, `cadr_axi_widen128.sv`
//     puts the machine's word in a 128-bit beat, and `cadr_axi_burst128.sv`
//     puts the pack side's 64-bit bursts on its port.
//   - **THE PORTS ARE LIVE WHILE `pl_resetn0` IS HIGH.**  The `PS8` has no
//     per-port reset as the `PS7` has; the processing system's fabric reset
//     is EMIO GPIO 95, which Vivado's own PS IP brings out as `pl_resetn0`,
//     and the factory firmware's load releases it and the PS-PL isolation
//     together (the probe's signature read back through `M_AXI_HPM0_FPD`
//     right after `fpga loadb`, with it high).  It takes the place of each
//     port's `ARESETN` below, synchronized in as they were.
//   - **TWO LAMPS, UF1 AND UF2, AND NO BUTTON, NO SWITCH.**  UF1 is F8 and
//     UF2 is E8, both lit when driven high (seen on the board).  UF1 is the
//     microcycles; UF2 is the error halt, else a slow blink while the machine
//     runs out of its boot PROM.  See the lamps at the bottom.  With no
//     button `-BOOT2` is the console's alone and the fabric's reset is the
//     MMCM's lock alone; with no switch `no_auto_boot` is tied low and the
//     hold is `fpgarc`'s `--no-auto-boot`, as on the Cora.
//   - **THE FAN IS DRIVEN ON, EXPLICITLY.**  `fan_en_b` on A12: low runs the
//     SOM's fan and high stops it (measured on the board).  Every KR260
//     bitstream holds it low; one that left it to a pull would be one that
//     might cook the part.
//   - **NO DISPLAY OUTPUT YET.**  The KR260's only video connector is the
//     processing system's DisplayPort, and the display output's hookup to it
//     is its own slice; until then the screen is `cadr-terminal`'s, over the
//     network, as on the Cora.
//   - **THE CADR ALONE, FOR NOW.**  QUUX revision 13 is to be built for this
//     board too, and its top-level differences --- its own memory master,
//     the file device's page, and no debug cable (contract Q5) --- come with
//     it; until then any other `MACHINE` stops elaboration.
//
// **THE MEMORY MAP IS `CADR_DDR_MAP_KR260`'s**: main memory at 0x6300_0000,
// the display at 0x6400_0000.  The flow sets the define; this file states the
// base again and stops elaboration if the package disagrees, as the
// DE25-Nano's top does, so a flow that forgot the define builds nothing
// rather than a board that writes the Zynq-7000's addresses.

`default_nettype none

// `DDR` IS ZERO BY DEFAULT, as on the other boards: the design this file
// describes by default is the machine and nothing else, with no processing
// system and `mem_done` tied low.  `boards/kria-kr260/vivado/bitstream.tcl`
// builds the board with `DDR=1`.
module cadr_kr260 #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    // MIT's TV sync PROM, for the display: `rtl/machine/cadr_tv.sv`.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex",
    parameter int unsigned DDR = 0,
    // The second display board, the color TV: as on the other boards.
    parameter int unsigned LMTV = 1,
    // Which machine.  See the header: the CADR alone, for now.
    parameter string MACHINE = "cadr"
) (
    input  var logic       clk25,      // the carrier's 25 MHz, pin C3
    // UF1 and UF2, the board's two user LEDs, lit when driven high.
    output var logic       uf1,
    output var logic       uf2,
    // The SOM's fan, on when LOW.
    output var logic       fan_en_b,
    // MIT's debug cable on PMOD1, in AMD's signal order: index k is AMD's
    // `pmod1_pin(k+1)`.  The same index is the same role as on the Zynq
    // boards' JA (`docs/debug-cable.md`); which header pins AMD's order
    // names is not checked against the carrier's schematic, which is not
    // obtainable, so a ribbon to this board is checked on the wire.
    inout  wire  [7:0]     pmod1
);

  if (MACHINE != "cadr") begin : g_cadr_only
    $error("cadr_kr260: MACHINE is \"%s\", and the Kria KR260 builds the CADR only for now", MACHINE);
  end

  // The base this board's region has, stated here and held against the
  // package the flow chose: see the header.
  localparam logic [31:0] MAIN_BASE = 32'h6300_0000;
  if (cadr_ddr_map::MAIN_BASE != MAIN_BASE) begin : g_map
    $error("cadr_ddr_map::MAIN_BASE is %h, and the Kria KR260's is %h: define CADR_DDR_MAP_KR260",
           cadr_ddr_map::MAIN_BASE, MAIN_BASE);
  end

  // ------------------------------------------------------------ the clock
  //
  // 25 MHz in, 100 MHz out.  The MMCME4's VCO runs between 800 and 1600 MHz
  // on this part: 25 x 40 is 1000, and 1000 / 10 is the tick.
  logic clk_fb, clk_raw, clk, mmcm_locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME4_BASE #(
      .CLKIN1_PERIOD  (40.000),  // 25 MHz
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(40.000),  // 1000 MHz at the VCO
      // THE TICK, AND THE ONLY PLACE IT IS DECIDED ON THIS BOARD.  The VCO
      // is 1000 MHz exactly, so this number IS the tick in nanoseconds;
      // `boards/arty-z7-20/vivado/tick.tcl` parses the four parameters out of
      // this file for the constraints.
      .CLKOUT0_DIVIDE_F(10.000)  // 100 MHz, one tick = 10 ns
  ) u_mmcm (
      .CLKIN1  (clk25),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_raw),
      .LOCKED  (mmcm_locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .CLKFBOUTB()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  BUFG u_bufg (.I(clk_raw), .O(clk));

  // ------------------------------------------------------------- the reset
  //
  // The MMCM's lock, synchronized: the fabric is held until its clock is
  // real.  There is no button, so that is the whole of the fabric's reset;
  // `rst -srst` over JTAG resets the whole board, processing system and all.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked};
  assign rst = rst_sync[3];

  // ---------------------------------------------------------- the machine

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
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge, wrcyc;
  logic device, dev_rq, dev_write, promdisable, promenable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, timed_out, mbusy, mbusy_sync;
  logic mem_req, mem_write;
  logic mem_done;
  logic port_read_ack, port_write_ack;
  logic [31:0] mem_rdata;
  // QUUX's line fill and its port's idle: the CADR never asks a line.
  logic         mem_line, mem_drained, mem_wide;
  logic [2:0]   mem_beats;
  logic [127:0] mem_rline;
  assign mem_rline = 128'd0;
  logic unused_quux_port;
  assign unused_quux_port = ^{mem_line, mem_beats, mem_wide, mem_drained};
  logic [7:0]  drive_present, drive_read_only;
  logic        drive_timed;
  logic        store_we;
  logic [4:0]  store_slot;
  logic [8:0]  store_addr;
  logic [31:0] store_wdata, store_rdata;
  logic        store_miss, ch_active, store_busy;
  logic        machrun, errhalt, stathalt;
  logic        n_boot;
  logic        sintr;
  logic [4:0]  store_busy_slot, ch_slot;
  logic [30:0] req_tag;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit, store_deny;
  logic        con_req, con_gnt, con_msyn, con_write, con_ssyn;
  logic        con_tv_lispm, con_color_tv;
  logic [3:0]  con_tv_map_a;
  logic [23:0] con_tv_map_q, con_tv_color_map_q, con_disp_color_map_q;
  logic [1:0]  con_hdmi_out, con_hdmi_rotate;
  logic        con_steady_lamps;
  // How many 64K-word memory boards the backplane has, page 2's word 37,
  // muir's `--main-memory-boards`: the machine's address decode and QUUX's
  // file device take it.  32 with no console.
  logic [6:0]  con_mem_boards;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  logic        dbg_in_req, dbg_in_wr, dbg_in_ack;
  logic [1:0]  dbg_in_a, dbd_oe;
  logic [15:0] dbd_to_machine, dbd_from_machine;
  logic        cab_req, cab_wr;
  logic [1:0]  cab_a;
  logic [15:0] cab_dbd;
  logic        dbg_holder;
  logic        dbgout_req, dbgout_wr;
  logic [1:0]  dbgout_a;
  logic [15:0] dbgout_dbd;
  logic        dbgout_ack, dbgout_live;
  logic [15:0] dbgout_dbd_in;
  logic        dbg_connect, dbg_engaged, dbg_foreign, dbg_live, dbg_active;
  logic        dbg_peer_far;
  logic [23:0] dbg_frames;
  logic [1:0]  dbg_wiring;
  logic [2:0]  dbg_wire_state;
  logic [7:0]  pmod1_o, pmod1_t;
  logic        mdbg_req, mdbg_wr;
  logic [1:0]  mdbg_a;
  logic [15:0] mdbg_dbd;
  logic        debuggee_reset, timeout_inhibit;
  logic [31:0] con_vma, con_q, con_md;
  logic [17:0] con_ro_addr, con_ro_echo;
  logic [47:0] con_ro_data;

  // The I/O board's cables: their far ends are faces on `M_AXI_HPM0_FPD`,
  // and tied off in `g_nomem` on the board with no processing system.
  logic        kbd_strobe;
  logic [31:0] host_rdata;
  logic [23:0] kbd_code;
  logic [6:0]  mouse_lines;
  logic        ser_tx_take, ser_tx_done, ser_rx_strobe, ser_plugged;
  logic [7:0]  ser_rx_data;
  logic        ser_rx_end, ser_rx_parity, ser_rx_framing;
  logic [15:0] chaos_address, chaos_rx_word;
  logic        chaos_rx_valid, chaos_rx_done, chaos_rx_crc, chaos_rx_lost;
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

  // ------------------------------------------------------ the machine's reset
  //
  // The board's reset, the console's restart and the debug cable's modifier
  // bit 1, ORed through a register: `cadr_cora.sv` has the rule for which of
  // `rst` and `mach_rst` each thing takes, and every line of it holds here.
  logic con_mach_rst;
  logic mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || con_mach_rst || debuggee_reset;

  // `-BOOT2`, the light panel's line, and this board has no button: the
  // console's word 13 is its one driver, the same button pressed from Linux.
  logic con_mach_boot;
  logic n_boot2;
  assign n_boot2 = !con_mach_boot;

  // A write or read that came back SLVERR or DECERR, held.
  logic ddr_error;

  // The heartbeat: counts the master clock, never reset.  Its top bit is
  // UF2's slow blink while the machine runs out of its boot PROM.
  logic [26:0] tick;
  always_ff @(posedge clk) tick <= tick + 27'd1;

  cadr_machine #(
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX),
      .LMTV(LMTV),
      .MACHINE(MACHINE)
  ) u_machine (
      .clk(clk), .rst(mach_rst),
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
      // The memory boards' count, page 2's word 37: 32 of 64K words, muir's
      // own default and what every trace in this repository was taken with,
      // unless the card says `--main-memory-boards`.
      .boards(con_mem_boards),
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
      .tv_map_a(con_tv_map_a), .tv_map_q(con_tv_map_q),
      .tv_color_map_q(con_tv_color_map_q),
      // The color board's map on its second port, which is the display
      // output's on a board that has one.  None here yet.
      .disp_map_a(4'd0), .disp_color_map_q(con_disp_color_map_q),
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      .mem_line(mem_line), .mem_beats(mem_beats), .mem_wide(mem_wide), .mem_rline(mem_rline), .mem_drained(mem_drained),
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
      .dbg_in_req(mdbg_req), .dbg_in_wr(mdbg_wr), .dbg_in_a(mdbg_a),
      .dbd_in(mdbg_dbd),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(dbgout_ack),
      .dbgout_dbd_in(dbgout_dbd_in), .dbgout_live(dbgout_live),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset is the board's: see `cadr_cora.sv`.
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code), .n_boot2(n_boot2),
      // No switch on this board: the machine always comes out of reset with
      // `RUN` and `SRUN` preset, and `fpgarc`'s `--no-auto-boot` is the hold.
      .no_auto_boot(1'b0), .n_boot_o(n_boot),
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
      .chaos_rx_lost(chaos_rx_lost),
      .chaos_tx_abort(chaos_tx_abort), .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      .ub_ssyn_by(ub_ssyn_by),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack),
      .host_we(1'b0), .host_widx(4'd0), .host_wdata(32'd0),
      .host_ridx(4'd0), .host_rdata(host_rdata)
  );

  // --------------------------------------- the debug cable, on PMOD1
  //
  // MIT's whole cable on one connector, as JA carries it on the Zynq boards:
  // `rtl/plumbing/cadr_dbg_cable.sv` is the connector and the role, and a
  // board is always a debuggee.  The board's reset, never the machine's.
  cadr_dbg_cable u_dbg_cable (
      .clk(clk), .rst(rst),
      .connect(dbg_connect), .engaged(dbg_engaged), .foreign(dbg_foreign),
      .peer_far(dbg_peer_far), .live(dbg_live), .active(dbg_active),
      .wiring(dbg_wiring), .wire_state(dbg_wire_state),
      .frames(dbg_frames),
      .out_req(dbgout_req), .out_wr(dbgout_wr), .out_a(dbgout_a),
      .out_dbd(dbgout_dbd), .out_ack(dbgout_ack),
      .out_dbd_in(dbgout_dbd_in), .out_live(dbgout_live),
      .in_req(cab_req), .in_wr(cab_wr), .in_a(cab_a), .in_dbd(cab_dbd),
      .in_ack(dbg_in_ack), .in_dbd_out(dbd_from_machine), .in_dbd_oe(dbd_oe),
      .pin_o(pmod1_o), .pin_t(pmod1_t), .pin_i(pmod1)
  );

  // `pin_t` is Xilinx's sense: HIGH is not driven.
  for (genvar i = 0; i < 8; i = i + 1) begin : g_pmod1
    assign pmod1[i] = pmod1_t[i] ? 1'bz : pmod1_o[i];
  end

  cadr_dbg_join u_dbg_join (
      .clk(clk), .rst(rst),
      .a_req(dbg_in_req), .a_wr(dbg_in_wr), .a_a(dbg_in_a),
      .a_dbd(dbd_to_machine),
      .b_req(cab_req), .b_wr(cab_wr), .b_a(cab_a), .b_dbd(cab_dbd),
      .req(mdbg_req), .wr(mdbg_wr), .a(mdbg_a), .dbd(mdbg_dbd),
      .holder(dbg_holder)
  );

  // ----------------------------------------------------------- the memory
  //
  // `DDR` puts the processing system behind the machine's memory port and
  // its faces: as on the Cora, with the `PS8` and its 128-bit ports.
  if (DDR != 0) begin : g_ddr

    // ------------------------------------------------- the ports' reset
    //
    // `pl_resetn0`, EMIO GPIO 95, synchronized: low while a load is under
    // way and until the processing system releases the fabric, high after.
    // Every port's logic below takes it where the Cora's takes that port's
    // own `ARESETN`, for the same reasons; one level here, because the
    // `PS8` has one.
    logic [95:0] gpio_o;
    logic        pl_resetn0;
    assign pl_resetn0 = gpio_o[95];
    logic [2:0]  port_rst_sync;
    always_ff @(posedge clk) port_rst_sync <= {port_rst_sync[1:0], pl_resetn0};

    // The memory master's reset: the port's alone, never the machine's, for
    // the reason `cadr_cora.sv` gives at its `axi_rst`.
    logic axi_rst;
    assign axi_rst = !port_rst_sync[2];

    // The machine drives the port.
    logic        port_req, port_write;
    logic [31:0] port_addr, port_wdata;
    logic        port_done, port_error;
    logic [31:0] port_rdata;
    assign port_req   = mem_req;
    assign port_write = mem_write;
    assign port_addr  = mem_addr;
    assign port_wdata = mem_wdata;
    assign mem_done   = port_done;
    assign mem_rdata  = port_rdata;

    // The adapter's AXI4 side, 32 bits wide.
    logic [31:0] awaddr, araddr, wdata;
    logic [7:0]  awlen, arlen;
    logic [2:0]  awsize, arsize;
    logic [1:0]  awburst, arburst, bresp, rresp;
    logic [3:0]  wstrb;
    logic        awvalid, awready, wvalid, wready, wlast;
    logic        bvalid, bready, arvalid, arready, rvalid, rready, rlast;
    logic [31:0] rdata;

    // The port's side, 128 bits wide.
    logic [31:0]  hp0_awaddr, hp0_araddr;
    logic [7:0]   hp0_awlen, hp0_arlen;
    logic [2:0]   hp0_awsize, hp0_arsize;
    logic [127:0] hp0_wdata, hp0_rdata;
    logic [15:0]  hp0_wstrb;

    cadr_axi_master u_axi (
        .clk(clk), .rst(axi_rst),
        .mem_req(port_req), .mem_write(port_write),
        .mem_addr(port_addr), .mem_wdata(port_wdata),
        .mem_done(port_done), .mem_rdata(port_rdata), .mem_error(port_error),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    // The word in a 128-bit beat: `rtl/plumbing/cadr_axi_widen128.sv`.
    cadr_axi_widen128 u_widen (
        .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
        .s_wdata(wdata), .s_wstrb(wstrb),
        .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
        .s_rdata(rdata),
        .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize),
        .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb),
        .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize),
        .m_rdata(hp0_rdata)
    );

    // ------------------------------------------------ the port's own tally
    //
    // What the machine asked for and what the processing system answered,
    // `rtl/plumbing/cadr_mem_count.sv`, on EMIO banks 3 and 4: `DATA_3_RO`
    // at 0xFF0A_006C carries EMIO 31:0 and `DATA_4_RO` at 0xFF0A_0070 EMIO
    // 63:32 (UG1087), which `cadr_board.h`'s KR260 map names.  Both report
    // the pin whatever the direction registers say.  Cleared by `rst` and
    // not by the port's reset, as on the Cora.
    logic [95:0] gpio_i;
    logic [63:0] tally;

    logic count_req, count_write;
    logic count_bvalid, count_bready, count_rvalid, count_rready, count_rlast;
    always_ff @(posedge clk) begin
      count_req    <= port_req;
      count_write  <= port_write;
      count_bvalid <= bvalid;
      count_bready <= bready;
      count_rvalid <= rvalid;
      count_rready <= rready;
      count_rlast  <= rlast;
    end

    cadr_mem_count u_count (
        .clk(clk), .rst(rst),
        .req(count_req), .req_write(count_write),
        .bvalid(count_bvalid), .bready(count_bready),
        .rvalid(count_rvalid), .rready(count_rready), .rlast(count_rlast),
        .gpio(tally)
    );

    assign port_read_ack  = count_rvalid && count_rready && count_rlast;
    assign port_write_ack = count_bvalid && count_bready;

    // **AND THE MACHINE'S CLOCK, COUNTED, ON BANK 5**: EMIO 94:64, at
    // `DATA_5_RO` 0xFF0A_0074, thirty-one bits of the 100 MHz tick, Gray
    // coded so that a load taken while it moves is off by one count and not
    // by a carry.  It is what measures the machine's clock against the
    // processing system's timer from Linux, with nobody at the board; it
    // wraps every 21.5 s.  EMIO 95 is `pl_resetn0`'s own bit and is left
    // low on the way in.
    logic [30:0] clk_count, clk_gray;
    always_ff @(posedge clk) begin
      clk_count <= clk_count + 31'd1;
      clk_gray  <= clk_count ^ (clk_count >> 1);
    end
    assign gpio_i = {1'b0, clk_gray, tally};

    // ------------------------------------------------------ the pack side
    //
    // `rtl/plumbing/cadr_disk_pack.sv`'s registers on `M_AXI_HPM0_FPD` at
    // 0xA000_0000 and its master on `S_AXI_HP2_FPD`, through
    // `cadr_axi_burst128.sv`.  Reset by the port's reset, synchronized, and
    // the fabric's at `fabric_rst`, as on the Cora.
    logic [31:0]  hp2_awaddr, hp2_araddr;
    logic [3:0]   hp2_awlen, hp2_arlen;
    logic [1:0]   hp2_awsize, hp2_arsize, hp2_awburst, hp2_arburst;
    logic         hp2_awvalid, hp2_awready, hp2_wlast, hp2_wvalid, hp2_wready;
    logic         hp2_bvalid, hp2_bready, hp2_arvalid, hp2_arready;
    logic         hp2_rlast, hp2_rvalid, hp2_rready;
    logic [63:0]  hp2_wdata, hp2_rdata;
    logic [7:0]   hp2_wstrb;
    logic [1:0]   hp2_bresp, hp2_rresp;
    // And the same port at its own width, through `cadr_axi_burst128.sv`.
    logic [31:0]  hp2w_awaddr, hp2w_araddr;
    logic [7:0]   hp2w_awlen, hp2w_arlen;
    logic [2:0]   hp2w_awsize, hp2w_arsize;
    logic [127:0] hp2w_wdata, hp2w_rdata;
    logic [15:0]  hp2w_wstrb;

    logic pack_rst;
    always_ff @(posedge clk) pack_rst <= !port_rst_sync[2];

    // `M_AXI_HPM0_FPD` at its own width, and the faces' 32-bit side.
    logic [39:0]  hpm0_awaddr, hpm0_araddr;
    logic [7:0]   hpm0_awlen, hpm0_arlen;
    logic [15:0]  hpm0_awid, hpm0_arid, hpm0_bid, hpm0_rid;
    logic         hpm0_awvalid, hpm0_awready, hpm0_wlast, hpm0_wvalid, hpm0_wready;
    logic         hpm0_bvalid, hpm0_bready, hpm0_arvalid, hpm0_arready;
    logic         hpm0_rlast, hpm0_rvalid, hpm0_rready;
    logic [127:0] hpm0_wdata, hpm0_rdata;
    logic [15:0]  hpm0_wstrb;
    logic [1:0]   hpm0_bresp, hpm0_rresp;
    logic [31:0]  gp0_wdata, gp0_rdata;
    logic [3:0]   gp0_wstrb;

    // The splitter's five ports, as on the Cora with sixteen bits of ID and
    // eight of length: AXI4 at the `PS8`'s master ports.
    logic [31:0] gp0p_awaddr, gp0p_araddr, gp0p_wdata, gp0p_rdata;
    logic [7:0]  gp0p_awlen, gp0p_arlen;
    logic [3:0]  gp0p_wstrb;
    logic [15:0] gp0p_awid, gp0p_arid, gp0p_bid, gp0p_rid;
    logic        gp0p_awvalid, gp0p_awready, gp0p_wlast, gp0p_wvalid, gp0p_wready;
    logic        gp0p_bvalid, gp0p_bready, gp0p_arvalid, gp0p_arready;
    logic        gp0p_rlast, gp0p_rvalid, gp0p_rready;
    logic [1:0]  gp0p_bresp, gp0p_rresp;
    logic [11:0] gp0c_awaddr, gp0c_araddr;
    logic [31:0] gp0c_wdata, gp0c_rdata;
    logic [7:0]  gp0c_awlen, gp0c_arlen;
    logic [3:0]  gp0c_wstrb;
    logic [15:0] gp0c_awid, gp0c_arid, gp0c_bid, gp0c_rid;
    logic        gp0c_awvalid, gp0c_awready, gp0c_wlast, gp0c_wvalid, gp0c_wready;
    logic        gp0c_bvalid, gp0c_bready, gp0c_arvalid, gp0c_arready;
    logic        gp0c_rlast, gp0c_rvalid, gp0c_rready;
    logic [1:0]  gp0c_bresp, gp0c_rresp;
    logic [11:0] gp0s_awaddr, gp0s_araddr;
    logic [31:0] gp0s_wdata, gp0s_rdata;
    logic [7:0]  gp0s_awlen, gp0s_arlen;
    logic [3:0]  gp0s_wstrb;
    logic [15:0] gp0s_awid, gp0s_arid, gp0s_bid, gp0s_rid;
    logic        gp0s_awvalid, gp0s_awready, gp0s_wlast, gp0s_wvalid, gp0s_wready;
    logic        gp0s_bvalid, gp0s_bready, gp0s_arvalid, gp0s_arready;
    logic        gp0s_rlast, gp0s_rvalid, gp0s_rready;
    logic [1:0]  gp0s_bresp, gp0s_rresp;
    logic [11:0] gp0i_awaddr, gp0i_araddr;
    logic [31:0] gp0i_wdata, gp0i_rdata;
    logic [7:0]  gp0i_awlen, gp0i_arlen;
    logic [3:0]  gp0i_wstrb;
    logic [15:0] gp0i_awid, gp0i_arid, gp0i_bid, gp0i_rid;
    logic        gp0i_awvalid, gp0i_awready, gp0i_wlast, gp0i_wvalid, gp0i_wready;
    logic        gp0i_bvalid, gp0i_bready, gp0i_arvalid, gp0i_arready;
    logic        gp0i_rlast, gp0i_rvalid, gp0i_rready;
    logic [1:0]  gp0i_bresp, gp0i_rresp;
    logic [31:0] gp0d_rdata;
    logic [7:0]  gp0d_arlen;
    logic [15:0] gp0d_awid, gp0d_arid, gp0d_bid, gp0d_rid;
    logic        gp0d_awvalid, gp0d_awready, gp0d_wlast, gp0d_wvalid, gp0d_wready;
    logic        gp0d_bvalid, gp0d_bready, gp0d_arvalid, gp0d_arready;
    logic        gp0d_rlast, gp0d_rvalid, gp0d_rready;
    logic [1:0]  gp0d_bresp, gp0d_rresp;
    logic        pack_irq, chaos_irq, ser_irq;

    cadr_disk_pack #(
        .REG_BASE(32'hA000_0000), .ID_W(16), .LEN_W(8)
    ) u_pack (
        .clk(clk), .rst(pack_rst), .fabric_rst(rst),
        .port_live(port_rst_sync[2]),
        .s_awaddr(gp0p_awaddr), .s_awlen(gp0p_awlen), .s_awid(gp0p_awid),
        .s_awvalid(gp0p_awvalid), .s_awready(gp0p_awready),
        .s_wdata(gp0p_wdata), .s_wstrb(gp0p_wstrb), .s_wlast(gp0p_wlast),
        .s_wvalid(gp0p_wvalid), .s_wready(gp0p_wready),
        .s_bresp(gp0p_bresp), .s_bid(gp0p_bid), .s_bvalid(gp0p_bvalid),
        .s_bready(gp0p_bready),
        .s_araddr(gp0p_araddr), .s_arlen(gp0p_arlen), .s_arid(gp0p_arid),
        .s_arvalid(gp0p_arvalid), .s_arready(gp0p_arready),
        .s_rdata(gp0p_rdata), .s_rresp(gp0p_rresp), .s_rid(gp0p_rid),
        .s_rlast(gp0p_rlast), .s_rvalid(gp0p_rvalid), .s_rready(gp0p_rready),
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

    // The pack side's bursts on the 128-bit port.
    cadr_axi_burst128 u_burst (
        .clk(clk), .rst(pack_rst),
        .s_awaddr(hp2_awaddr), .s_awlen(hp2_awlen), .s_awsize(hp2_awsize),
        .s_wdata(hp2_wdata), .s_wstrb(hp2_wstrb), .s_wlast(hp2_wlast),
        .s_wvalid(hp2_wvalid), .s_wready(hp2_wready),
        .s_araddr(hp2_araddr), .s_arlen(hp2_arlen), .s_arsize(hp2_arsize),
        .s_rdata(hp2_rdata), .s_rlast(hp2_rlast), .s_rvalid(hp2_rvalid),
        .s_rready(hp2_rready),
        .m_awaddr(hp2w_awaddr), .m_awlen(hp2w_awlen), .m_awsize(hp2w_awsize),
        .m_wdata(hp2w_wdata), .m_wstrb(hp2w_wstrb),
        .m_araddr(hp2w_araddr), .m_arlen(hp2w_arlen), .m_arsize(hp2w_arsize),
        .m_rdata(hp2w_rdata)
    );

    // ------------------------------------------- the faces on HPM0
    //
    // The port's 128-bit payload onto the faces' one word,
    // `rtl/plumbing/cadr_axi_lanes128.sv`; every handshake passes by.
    cadr_axi_lanes128 u_hpm0_lanes (
        .s_wdata(hpm0_wdata), .s_wstrb(hpm0_wstrb), .s_rdata(hpm0_rdata),
        .m_wdata(gp0_wdata), .m_wstrb(gp0_wstrb), .m_rdata(gp0_rdata)
    );

    // The splitter and the faces take the port's reset alone, the faces the
    // fabric's at `fabric_rst`: `cadr_cora.sv`'s `gp0_rst_s` has why.
    logic gp0_rst_s;
    always_ff @(posedge clk) gp0_rst_s <= !port_rst_sync[2];

    // The window is 0xA000_0000 to 0xAFFF_FFFF, so the address's top eight
    // bits are zero and the splitter takes the low thirty-two.
    logic unused_hpm0_addr;
    assign unused_hpm0_addr = ^{hpm0_awaddr[39:32], hpm0_araddr[39:32]};

    /* verilator lint_off PINCONNECTEMPTY */
    cadr_gp0_split #(
        .PACK_BASE(32'hA000_0000), .CHAOS_BASE(32'hA000_1000),
        .SER_BASE(32'hA000_2000), .INPUT_BASE(32'hA000_3000),
        .FD_BASE(32'hA000_4000), .HAS_FD(1'b0),
        .ID_W(16), .LEN_W(8)
    ) u_gp0_split (
        .clk(clk), .rst(gp0_rst_s),
        .s_awaddr(hpm0_awaddr[31:0]), .s_awlen(hpm0_awlen), .s_awid(hpm0_awid),
        .s_awvalid(hpm0_awvalid), .s_awready(hpm0_awready),
        .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(hpm0_wlast),
        .s_wvalid(hpm0_wvalid), .s_wready(hpm0_wready),
        .s_bresp(hpm0_bresp), .s_bid(hpm0_bid), .s_bvalid(hpm0_bvalid),
        .s_bready(hpm0_bready),
        .s_araddr(hpm0_araddr[31:0]), .s_arlen(hpm0_arlen), .s_arid(hpm0_arid),
        .s_arvalid(hpm0_arvalid), .s_arready(hpm0_arready),
        .s_rdata(gp0_rdata), .s_rresp(hpm0_rresp), .s_rid(hpm0_rid),
        .s_rlast(hpm0_rlast), .s_rvalid(hpm0_rvalid), .s_rready(hpm0_rready),
        .pack_awaddr(gp0p_awaddr), .pack_awlen(gp0p_awlen), .pack_awid(gp0p_awid),
        .pack_awvalid(gp0p_awvalid), .pack_awready(gp0p_awready),
        .pack_wdata(gp0p_wdata), .pack_wstrb(gp0p_wstrb), .pack_wlast(gp0p_wlast),
        .pack_wvalid(gp0p_wvalid), .pack_wready(gp0p_wready),
        .pack_bresp(gp0p_bresp), .pack_bid(gp0p_bid), .pack_bvalid(gp0p_bvalid),
        .pack_bready(gp0p_bready),
        .pack_araddr(gp0p_araddr), .pack_arlen(gp0p_arlen), .pack_arid(gp0p_arid),
        .pack_arvalid(gp0p_arvalid), .pack_arready(gp0p_arready),
        .pack_rdata(gp0p_rdata), .pack_rresp(gp0p_rresp), .pack_rid(gp0p_rid),
        .pack_rlast(gp0p_rlast), .pack_rvalid(gp0p_rvalid), .pack_rready(gp0p_rready),
        .chaos_awaddr(gp0c_awaddr), .chaos_awlen(gp0c_awlen), .chaos_awid(gp0c_awid),
        .chaos_awvalid(gp0c_awvalid), .chaos_awready(gp0c_awready),
        .chaos_wdata(gp0c_wdata), .chaos_wstrb(gp0c_wstrb), .chaos_wlast(gp0c_wlast),
        .chaos_wvalid(gp0c_wvalid), .chaos_wready(gp0c_wready),
        .chaos_bresp(gp0c_bresp), .chaos_bid(gp0c_bid), .chaos_bvalid(gp0c_bvalid),
        .chaos_bready(gp0c_bready),
        .chaos_araddr(gp0c_araddr), .chaos_arlen(gp0c_arlen), .chaos_arid(gp0c_arid),
        .chaos_arvalid(gp0c_arvalid), .chaos_arready(gp0c_arready),
        .chaos_rdata(gp0c_rdata), .chaos_rresp(gp0c_rresp), .chaos_rid(gp0c_rid),
        .chaos_rlast(gp0c_rlast), .chaos_rvalid(gp0c_rvalid), .chaos_rready(gp0c_rready),
        .ser_awaddr(gp0s_awaddr), .ser_awlen(gp0s_awlen), .ser_awid(gp0s_awid),
        .ser_awvalid(gp0s_awvalid), .ser_awready(gp0s_awready),
        .ser_wdata(gp0s_wdata), .ser_wstrb(gp0s_wstrb), .ser_wlast(gp0s_wlast),
        .ser_wvalid(gp0s_wvalid), .ser_wready(gp0s_wready),
        .ser_bresp(gp0s_bresp), .ser_bid(gp0s_bid), .ser_bvalid(gp0s_bvalid),
        .ser_bready(gp0s_bready),
        .ser_araddr(gp0s_araddr), .ser_arlen(gp0s_arlen), .ser_arid(gp0s_arid),
        .ser_arvalid(gp0s_arvalid), .ser_arready(gp0s_arready),
        .ser_rdata(gp0s_rdata), .ser_rresp(gp0s_rresp), .ser_rid(gp0s_rid),
        .ser_rlast(gp0s_rlast), .ser_rvalid(gp0s_rvalid), .ser_rready(gp0s_rready),
        .in_awaddr(gp0i_awaddr), .in_awlen(gp0i_awlen), .in_awid(gp0i_awid),
        .in_awvalid(gp0i_awvalid), .in_awready(gp0i_awready),
        .in_wdata(gp0i_wdata), .in_wstrb(gp0i_wstrb), .in_wlast(gp0i_wlast),
        .in_wvalid(gp0i_wvalid), .in_wready(gp0i_wready),
        .in_bresp(gp0i_bresp), .in_bid(gp0i_bid), .in_bvalid(gp0i_bvalid),
        .in_bready(gp0i_bready),
        .in_araddr(gp0i_araddr), .in_arlen(gp0i_arlen), .in_arid(gp0i_arid),
        .in_arvalid(gp0i_arvalid), .in_arready(gp0i_arready),
        .in_rdata(gp0i_rdata), .in_rresp(gp0i_rresp), .in_rid(gp0i_rid),
        .in_rlast(gp0i_rlast), .in_rvalid(gp0i_rvalid), .in_rready(gp0i_rready),
        // QUUX's fifth page is the default's on the CADR (`HAS_FD` down).
        .fd_awaddr(), .fd_awlen(), .fd_awid(), .fd_awvalid(), .fd_awready(1'b0),
        .fd_wdata(), .fd_wstrb(), .fd_wlast(), .fd_wvalid(), .fd_wready(1'b0),
        .fd_bresp(2'b00), .fd_bid('0), .fd_bvalid(1'b0), .fd_bready(),
        .fd_araddr(), .fd_arlen(), .fd_arid(), .fd_arvalid(), .fd_arready(1'b0),
        .fd_rdata(32'd0), .fd_rresp(2'b00), .fd_rid('0), .fd_rlast(1'b0),
        .fd_rvalid(1'b0), .fd_rready(),
        .dflt_awid(gp0d_awid), .dflt_awvalid(gp0d_awvalid),
        .dflt_awready(gp0d_awready),
        .dflt_wlast(gp0d_wlast), .dflt_wvalid(gp0d_wvalid),
        .dflt_wready(gp0d_wready),
        .dflt_bresp(gp0d_bresp), .dflt_bid(gp0d_bid), .dflt_bvalid(gp0d_bvalid),
        .dflt_bready(gp0d_bready),
        .dflt_arlen(gp0d_arlen), .dflt_arid(gp0d_arid),
        .dflt_arvalid(gp0d_arvalid), .dflt_arready(gp0d_arready),
        .dflt_rdata(gp0d_rdata), .dflt_rresp(gp0d_rresp), .dflt_rid(gp0d_rid),
        .dflt_rlast(gp0d_rlast), .dflt_rvalid(gp0d_rvalid),
        .dflt_rready(gp0d_rready)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    cadr_chaos_cable #(.ID_W(16), .LEN_W(8)) u_chaos (
        .clk(clk), .rst(gp0_rst_s), .fabric_rst(rst),
        .s_awaddr(gp0c_awaddr), .s_awlen(gp0c_awlen), .s_awid(gp0c_awid),
        .s_awvalid(gp0c_awvalid), .s_awready(gp0c_awready),
        .s_wdata(gp0c_wdata), .s_wstrb(gp0c_wstrb), .s_wlast(gp0c_wlast),
        .s_wvalid(gp0c_wvalid), .s_wready(gp0c_wready),
        .s_bresp(gp0c_bresp), .s_bid(gp0c_bid), .s_bvalid(gp0c_bvalid),
        .s_bready(gp0c_bready),
        .s_araddr(gp0c_araddr), .s_arlen(gp0c_arlen), .s_arid(gp0c_arid),
        .s_arvalid(gp0c_arvalid), .s_arready(gp0c_arready),
        .s_rdata(gp0c_rdata), .s_rresp(gp0c_rresp), .s_rid(gp0c_rid),
        .s_rlast(gp0c_rlast), .s_rvalid(gp0c_rvalid), .s_rready(gp0c_rready),
        .chaos_address(chaos_address),
        .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
        .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word),
        .chaos_tx_clear(chaos_tx_clear), .chaos_reset(chaos_reset),
        .chaos_csr(chaos_csr),
        .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word),
        .chaos_rx_done(chaos_rx_done), .chaos_rx_bits(chaos_rx_bits),
        .chaos_rx_crc(chaos_rx_crc),
        .chaos_rx_lost(chaos_rx_lost),
        .chaos_tx_done(chaos_tx_done), .chaos_tx_abort(chaos_tx_abort),
        .chaos_cbl_busy(chaos_cbl_busy),
        .irq(chaos_irq)
    );

    cadr_serial_line #(.ID_W(16), .LEN_W(8)) u_serial (
        .clk(clk), .rst(gp0_rst_s), .fabric_rst(rst),
        .s_awaddr(gp0s_awaddr), .s_awlen(gp0s_awlen), .s_awid(gp0s_awid),
        .s_awvalid(gp0s_awvalid), .s_awready(gp0s_awready),
        .s_wdata(gp0s_wdata), .s_wstrb(gp0s_wstrb), .s_wlast(gp0s_wlast),
        .s_wvalid(gp0s_wvalid), .s_wready(gp0s_wready),
        .s_bresp(gp0s_bresp), .s_bid(gp0s_bid), .s_bvalid(gp0s_bvalid),
        .s_bready(gp0s_bready),
        .s_araddr(gp0s_araddr), .s_arlen(gp0s_arlen), .s_arid(gp0s_arid),
        .s_arvalid(gp0s_arvalid), .s_arready(gp0s_arready),
        .s_rdata(gp0s_rdata), .s_rresp(gp0s_rresp), .s_rid(gp0s_rid),
        .s_rlast(gp0s_rlast), .s_rvalid(gp0s_rvalid), .s_rready(gp0s_rready),
        .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
        .ser_cmd(ser_cmd), .ser_status(ser_status),
        .ser_tx_strobe(ser_tx_strobe), .ser_tx_data(ser_tx_data),
        .ser_tx_take(ser_tx_take), .ser_tx_done(ser_tx_done),
        .ser_rx_strobe(ser_rx_strobe), .ser_rx_data(ser_rx_data),
        .ser_rx_end(ser_rx_end), .ser_rx_parity(ser_rx_parity),
        .ser_rx_framing(ser_rx_framing),
        .ser_plugged(ser_plugged),
        .irq(ser_irq)
    );

    // `mach_rst` for the queue's flush, as on the Cora.
    cadr_input_cables #(.ID_W(16), .LEN_W(8)) u_input (
        .clk(clk), .rst(gp0_rst_s), .fabric_rst(rst), .mach_rst(mach_rst),
        .s_awaddr(gp0i_awaddr), .s_awlen(gp0i_awlen), .s_awid(gp0i_awid),
        .s_awvalid(gp0i_awvalid), .s_awready(gp0i_awready),
        .s_wdata(gp0i_wdata), .s_wstrb(gp0i_wstrb), .s_wlast(gp0i_wlast),
        .s_wvalid(gp0i_wvalid), .s_wready(gp0i_wready),
        .s_bresp(gp0i_bresp), .s_bid(gp0i_bid), .s_bvalid(gp0i_bvalid),
        .s_bready(gp0i_bready),
        .s_araddr(gp0i_araddr), .s_arlen(gp0i_arlen), .s_arid(gp0i_arid),
        .s_arvalid(gp0i_arvalid), .s_arready(gp0i_arready),
        .s_rdata(gp0i_rdata), .s_rresp(gp0i_rresp), .s_rid(gp0i_rid),
        .s_rlast(gp0i_rlast), .s_rvalid(gp0i_rvalid), .s_rready(gp0i_rready),
        .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
        .mouse_lines(mouse_lines),
        .card_csr(csr_face)
    );

    cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp0_rest (
        .clk(clk), .rst(gp0_rst_s),
        .s_awvalid(gp0d_awvalid), .s_awid(gp0d_awid), .s_awready(gp0d_awready),
        .s_wlast(gp0d_wlast), .s_wvalid(gp0d_wvalid), .s_wready(gp0d_wready),
        .s_bresp(gp0d_bresp), .s_bid(gp0d_bid), .s_bvalid(gp0d_bvalid),
        .s_bready(gp0d_bready),
        .s_arlen(gp0d_arlen), .s_arid(gp0d_arid), .s_arvalid(gp0d_arvalid),
        .s_arready(gp0d_arready),
        .s_rdata(gp0d_rdata), .s_rresp(gp0d_rresp), .s_rid(gp0d_rid),
        .s_rlast(gp0d_rlast), .s_rvalid(gp0d_rvalid), .s_rready(gp0d_rready)
    );

    // ------------------------------------------------------- the console
    //
    // On `M_AXI_HPM1_FPD` at 0xB000_0000, with the debug window at
    // 0xB000_1000 and the default slave answering the rest of the window,
    // behind `rtl/plumbing/cadr_gp1_split.sv` as on the Cora.
    logic [39:0]  hpm1_awaddr, hpm1_araddr;
    logic [7:0]   hpm1_awlen, hpm1_arlen;
    logic [15:0]  hpm1_awid, hpm1_arid, hpm1_bid, hpm1_rid;
    logic         hpm1_awvalid, hpm1_awready, hpm1_wlast, hpm1_wvalid, hpm1_wready;
    logic         hpm1_bvalid, hpm1_bready, hpm1_arvalid, hpm1_arready;
    logic         hpm1_rlast, hpm1_rvalid, hpm1_rready;
    logic [127:0] hpm1_wdata, hpm1_rdata;
    logic [15:0]  hpm1_wstrb;
    logic [1:0]   hpm1_bresp, hpm1_rresp;
    logic [31:0]  gp1_wdata, gp1_rdata;
    logic [3:0]   gp1_wstrb;

    logic [31:0] gp1c_awaddr, gp1c_araddr, gp1c_wdata, gp1c_rdata;
    logic [7:0]  gp1c_awlen, gp1c_arlen;
    logic [3:0]  gp1c_wstrb;
    logic [15:0] gp1c_awid, gp1c_arid, gp1c_bid, gp1c_rid;
    logic        gp1c_awvalid, gp1c_awready, gp1c_wlast, gp1c_wvalid, gp1c_wready;
    logic        gp1c_bvalid, gp1c_bready, gp1c_arvalid, gp1c_arready;
    logic        gp1c_rlast, gp1c_rvalid, gp1c_rready;
    logic [1:0]  gp1c_bresp, gp1c_rresp;
    logic [31:0] gp1d_awaddr, gp1d_araddr, gp1d_wdata, gp1d_rdata;
    logic [7:0]  gp1d_awlen, gp1d_arlen;
    logic [3:0]  gp1d_wstrb;
    logic [15:0] gp1d_awid, gp1d_arid, gp1d_bid, gp1d_rid;
    logic        gp1d_awvalid, gp1d_awready, gp1d_wlast, gp1d_wvalid, gp1d_wready;
    logic        gp1d_bvalid, gp1d_bready, gp1d_arvalid, gp1d_arready;
    logic        gp1d_rlast, gp1d_rvalid, gp1d_rready;
    logic [1:0]  gp1d_bresp, gp1d_rresp;
    logic [31:0] gp1x_rdata;
    logic [7:0]  gp1x_arlen;
    logic [15:0] gp1x_awid, gp1x_arid, gp1x_bid, gp1x_rid;
    logic        gp1x_awvalid, gp1x_awready, gp1x_wlast, gp1x_wvalid, gp1x_wready;
    logic        gp1x_bvalid, gp1x_bready, gp1x_arvalid, gp1x_arready;
    logic        gp1x_rlast, gp1x_rvalid, gp1x_rready;
    logic [1:0]  gp1x_bresp, gp1x_rresp;

    logic gp1_rst;
    always_ff @(posedge clk) gp1_rst <= !port_rst_sync[2];

    cadr_axi_lanes128 u_hpm1_lanes (
        .s_wdata(hpm1_wdata), .s_wstrb(hpm1_wstrb), .s_rdata(hpm1_rdata),
        .m_wdata(gp1_wdata), .m_wstrb(gp1_wstrb), .m_rdata(gp1_rdata)
    );

    // 0xB000_0000 to 0xBFFF_FFFF: the top eight bits are zero here too.
    logic unused_hpm1_addr;
    assign unused_hpm1_addr = ^{hpm1_awaddr[39:32], hpm1_araddr[39:32]};

    cadr_gp1_split #(
        .CON_BASE(32'hB000_0000), .DBG_BASE(32'hB000_1000),
        .ID_W(16), .LEN_W(8)
    ) u_gp1_split (
        .clk(clk), .rst(gp1_rst),
        .s_awaddr(hpm1_awaddr[31:0]), .s_awlen(hpm1_awlen), .s_awid(hpm1_awid),
        .s_awvalid(hpm1_awvalid), .s_awready(hpm1_awready),
        .s_wdata(gp1_wdata), .s_wstrb(gp1_wstrb), .s_wlast(hpm1_wlast),
        .s_wvalid(hpm1_wvalid), .s_wready(hpm1_wready),
        .s_bresp(hpm1_bresp), .s_bid(hpm1_bid), .s_bvalid(hpm1_bvalid),
        .s_bready(hpm1_bready),
        .s_araddr(hpm1_araddr[31:0]), .s_arlen(hpm1_arlen), .s_arid(hpm1_arid),
        .s_arvalid(hpm1_arvalid), .s_arready(hpm1_arready),
        .s_rdata(gp1_rdata), .s_rresp(hpm1_rresp), .s_rid(hpm1_rid),
        .s_rlast(hpm1_rlast), .s_rvalid(hpm1_rvalid), .s_rready(hpm1_rready),
        .con_awaddr(gp1c_awaddr), .con_awlen(gp1c_awlen), .con_awid(gp1c_awid),
        .con_awvalid(gp1c_awvalid), .con_awready(gp1c_awready),
        .con_wdata(gp1c_wdata), .con_wstrb(gp1c_wstrb), .con_wlast(gp1c_wlast),
        .con_wvalid(gp1c_wvalid), .con_wready(gp1c_wready),
        .con_bresp(gp1c_bresp), .con_bid(gp1c_bid), .con_bvalid(gp1c_bvalid),
        .con_bready(gp1c_bready),
        .con_araddr(gp1c_araddr), .con_arlen(gp1c_arlen), .con_arid(gp1c_arid),
        .con_arvalid(gp1c_arvalid), .con_arready(gp1c_arready),
        .con_rdata(gp1c_rdata), .con_rresp(gp1c_rresp), .con_rid(gp1c_rid),
        .con_rlast(gp1c_rlast), .con_rvalid(gp1c_rvalid), .con_rready(gp1c_rready),
        .dbg_awaddr(gp1d_awaddr), .dbg_awlen(gp1d_awlen), .dbg_awid(gp1d_awid),
        .dbg_awvalid(gp1d_awvalid), .dbg_awready(gp1d_awready),
        .dbg_wdata(gp1d_wdata), .dbg_wstrb(gp1d_wstrb), .dbg_wlast(gp1d_wlast),
        .dbg_wvalid(gp1d_wvalid), .dbg_wready(gp1d_wready),
        .dbg_bresp(gp1d_bresp), .dbg_bid(gp1d_bid), .dbg_bvalid(gp1d_bvalid),
        .dbg_bready(gp1d_bready),
        .dbg_araddr(gp1d_araddr), .dbg_arlen(gp1d_arlen), .dbg_arid(gp1d_arid),
        .dbg_arvalid(gp1d_arvalid), .dbg_arready(gp1d_arready),
        .dbg_rdata(gp1d_rdata), .dbg_rresp(gp1d_rresp), .dbg_rid(gp1d_rid),
        .dbg_rlast(gp1d_rlast), .dbg_rvalid(gp1d_rvalid), .dbg_rready(gp1d_rready),
        .dflt_awid(gp1x_awid), .dflt_awvalid(gp1x_awvalid),
        .dflt_awready(gp1x_awready),
        .dflt_wlast(gp1x_wlast), .dflt_wvalid(gp1x_wvalid),
        .dflt_wready(gp1x_wready),
        .dflt_bresp(gp1x_bresp), .dflt_bid(gp1x_bid), .dflt_bvalid(gp1x_bvalid),
        .dflt_bready(gp1x_bready),
        .dflt_arlen(gp1x_arlen), .dflt_arid(gp1x_arid),
        .dflt_arvalid(gp1x_arvalid), .dflt_arready(gp1x_arready),
        .dflt_rdata(gp1x_rdata), .dflt_rresp(gp1x_rresp), .dflt_rid(gp1x_rid),
        .dflt_rlast(gp1x_rlast), .dflt_rvalid(gp1x_rvalid),
        .dflt_rready(gp1x_rready)
    );

    // The debug cable's carrier, at 0xB000_1000: muir on this board's own
    // cores is given `--debug-cable-connect 0xb0001000`.  The port's reset,
    // not the machine's, as on the Cora.
    cadr_debug_window #(
        .REG_BASE(32'hB000_1000), .ID_W(16), .LEN_W(8)
    ) u_debug_window (
        .clk(clk), .rst(gp1_rst), .fabric_rst(rst),
        .s_awaddr(gp1d_awaddr), .s_awlen(gp1d_awlen), .s_awid(gp1d_awid),
        .s_awvalid(gp1d_awvalid), .s_awready(gp1d_awready),
        .s_wdata(gp1d_wdata), .s_wstrb(gp1d_wstrb), .s_wlast(gp1d_wlast),
        .s_wvalid(gp1d_wvalid), .s_wready(gp1d_wready),
        .s_bresp(gp1d_bresp), .s_bid(gp1d_bid), .s_bvalid(gp1d_bvalid),
        .s_bready(gp1d_bready),
        .s_araddr(gp1d_araddr), .s_arlen(gp1d_arlen), .s_arid(gp1d_arid),
        .s_arvalid(gp1d_arvalid), .s_arready(gp1d_arready),
        .s_rdata(gp1d_rdata), .s_rresp(gp1d_rresp), .s_rid(gp1d_rid),
        .s_rlast(gp1d_rlast), .s_rvalid(gp1d_rvalid), .s_rready(gp1d_rready),
        .dbg_in_req(dbg_in_req), .dbg_in_wr(dbg_in_wr), .dbg_in_a(dbg_in_a),
        .dbd_out(dbd_to_machine),
        .dbg_in_ack(dbg_in_ack), .dbd_in(dbd_from_machine), .dbd_oe(dbd_oe)
    );

    cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp1_rest (
        .clk(clk), .rst(gp1_rst),
        .s_awvalid(gp1x_awvalid), .s_awid(gp1x_awid), .s_awready(gp1x_awready),
        .s_wlast(gp1x_wlast), .s_wvalid(gp1x_wvalid), .s_wready(gp1x_wready),
        .s_bresp(gp1x_bresp), .s_bid(gp1x_bid), .s_bvalid(gp1x_bvalid),
        .s_bready(gp1x_bready),
        .s_arlen(gp1x_arlen), .s_arid(gp1x_arid), .s_arvalid(gp1x_arvalid),
        .s_arready(gp1x_arready),
        .s_rdata(gp1x_rdata), .s_rresp(gp1x_rresp), .s_rid(gp1x_rid),
        .s_rlast(gp1x_rlast), .s_rvalid(gp1x_rvalid), .s_rready(gp1x_rready)
    );

    // Which build this fabric is, page 2's word 32: `USR_ACCESSE2`, the same
    // primitive on UltraScale+ as on the 7 series, so the same module.
    logic [31:0] con_build;
    cadr_usr_access u_usr_access (.build(con_build));

    // No display output on this board yet: word 36's setting goes nowhere
    // and the word reads `UNMAPPED`, as on the Cora.
    logic        con_hdmi_sleep_set, con_hdmi_wake;
    logic [14:0] con_hdmi_sleep_secs;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_hdmi_sleep;
    assign unused_hdmi_sleep = ^{con_hdmi_sleep_set, con_hdmi_sleep_secs, con_hdmi_wake};
    /* verilator lint_on UNUSEDSIGNAL */

    cadr_console #(
        .REG_BASE(32'hB000_0000), .ID_W(16), .LEN_W(8)
    ) u_console (
        .clk(clk), .rst(gp1_rst), .fabric_rst(rst),
        .s_awaddr(gp1c_awaddr), .s_awlen(gp1c_awlen), .s_awid(gp1c_awid),
        .s_awvalid(gp1c_awvalid), .s_awready(gp1c_awready),
        .s_wdata(gp1c_wdata), .s_wstrb(gp1c_wstrb), .s_wlast(gp1c_wlast),
        .s_wvalid(gp1c_wvalid), .s_wready(gp1c_wready),
        .s_bresp(gp1c_bresp), .s_bid(gp1c_bid), .s_bvalid(gp1c_bvalid),
        .s_bready(gp1c_bready),
        .s_araddr(gp1c_araddr), .s_arlen(gp1c_arlen), .s_arid(gp1c_arid),
        .s_arvalid(gp1c_arvalid), .s_arready(gp1c_arready),
        .s_rdata(gp1c_rdata), .s_rresp(gp1c_rresp), .s_rid(gp1c_rid),
        .s_rlast(gp1c_rlast), .s_rvalid(gp1c_rvalid), .s_rready(gp1c_rready),
        .dbg_req(con_req), .dbg_gnt(con_gnt),
        .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
        .tv_map_a(con_tv_map_a), .tv_map_q(con_tv_map_q),
        .tv_color_map_q(con_tv_color_map_q),
        .hdmi_out(con_hdmi_out), .hdmi_rotate(con_hdmi_rotate),
        .steady_lamps(con_steady_lamps),
        .mem_boards(con_mem_boards),
        .hdmi_sleep_set(con_hdmi_sleep_set), .hdmi_sleep_secs(con_hdmi_sleep_secs),
        .hdmi_wake(con_hdmi_wake), .hdmi_sleep_fitted(1'b0),
        .hdmi_sleep_q(15'd0), .hdmi_asleep(1'b0),
        .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
        .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
        .clock_edge(clock_edge),
        .mach_vma(con_vma), .mach_q(con_q), .mach_md(con_md),
        .build(con_build),
        .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
        .mach_rst(con_mach_rst),
        .mach_boot(con_mach_boot),
        // No switch on this board: both of SW0's report words read zero.
        .no_auto_boot_held(1'b0),
        .no_auto_boot_now(1'b0),
        .dbg_connect(dbg_connect),
        .dbg_wiring(dbg_wiring),
        .dbg_wire_state(dbg_wire_state),
        .dbg_frames(dbg_frames),
        .dbg_engaged(dbg_engaged),
        .dbg_foreign(dbg_foreign),
        .dbg_peer_far(dbg_peer_far),
        .dbg_live(dbg_live),
        .dbg_active(dbg_active)
    );

    // ------------------------------------------- the processing system
    //
    // Every port clocked by the machine's own 100 MHz: the fabric clocks
    // the ports, as on the Zynq-7000 boards.
    cadr_ps8 u_ps8 (
        .hpm0_aclk(clk),
        .hpm0_awaddr(hpm0_awaddr), .hpm0_awlen(hpm0_awlen), .hpm0_awid(hpm0_awid),
        .hpm0_awvalid(hpm0_awvalid), .hpm0_awready(hpm0_awready),
        .hpm0_wdata(hpm0_wdata), .hpm0_wstrb(hpm0_wstrb), .hpm0_wlast(hpm0_wlast),
        .hpm0_wvalid(hpm0_wvalid), .hpm0_wready(hpm0_wready),
        .hpm0_bresp(hpm0_bresp), .hpm0_bid(hpm0_bid), .hpm0_bvalid(hpm0_bvalid),
        .hpm0_bready(hpm0_bready),
        .hpm0_araddr(hpm0_araddr), .hpm0_arlen(hpm0_arlen), .hpm0_arid(hpm0_arid),
        .hpm0_arvalid(hpm0_arvalid), .hpm0_arready(hpm0_arready),
        .hpm0_rdata(hpm0_rdata), .hpm0_rresp(hpm0_rresp), .hpm0_rid(hpm0_rid),
        .hpm0_rlast(hpm0_rlast), .hpm0_rvalid(hpm0_rvalid), .hpm0_rready(hpm0_rready),
        .hpm1_aclk(clk),
        .hpm1_awaddr(hpm1_awaddr), .hpm1_awlen(hpm1_awlen), .hpm1_awid(hpm1_awid),
        .hpm1_awvalid(hpm1_awvalid), .hpm1_awready(hpm1_awready),
        .hpm1_wdata(hpm1_wdata), .hpm1_wstrb(hpm1_wstrb), .hpm1_wlast(hpm1_wlast),
        .hpm1_wvalid(hpm1_wvalid), .hpm1_wready(hpm1_wready),
        .hpm1_bresp(hpm1_bresp), .hpm1_bid(hpm1_bid), .hpm1_bvalid(hpm1_bvalid),
        .hpm1_bready(hpm1_bready),
        .hpm1_araddr(hpm1_araddr), .hpm1_arlen(hpm1_arlen), .hpm1_arid(hpm1_arid),
        .hpm1_arvalid(hpm1_arvalid), .hpm1_arready(hpm1_arready),
        .hpm1_rdata(hpm1_rdata), .hpm1_rresp(hpm1_rresp), .hpm1_rid(hpm1_rid),
        .hpm1_rlast(hpm1_rlast), .hpm1_rvalid(hpm1_rvalid), .hpm1_rready(hpm1_rready),
        // Main memory: the port's 49 address bits, of which the region
        // needs 31.
        .hp0_rclk(clk), .hp0_wclk(clk),
        .hp0_awaddr({17'd0, hp0_awaddr}), .hp0_awlen(hp0_awlen),
        .hp0_awsize(hp0_awsize), .hp0_awburst(awburst),
        .hp0_awvalid(awvalid), .hp0_awready(awready),
        .hp0_wdata(hp0_wdata), .hp0_wstrb(hp0_wstrb),
        .hp0_wlast(wlast), .hp0_wvalid(wvalid), .hp0_wready(wready),
        .hp0_bresp(bresp), .hp0_bvalid(bvalid), .hp0_bready(bready),
        .hp0_araddr({17'd0, hp0_araddr}), .hp0_arlen(hp0_arlen),
        .hp0_arsize(hp0_arsize), .hp0_arburst(arburst),
        .hp0_arvalid(arvalid), .hp0_arready(arready),
        .hp0_rdata(hp0_rdata), .hp0_rresp(rresp), .hp0_rlast(rlast),
        .hp0_rvalid(rvalid), .hp0_rready(rready),
        // The pack side.
        .hp2_rclk(clk), .hp2_wclk(clk),
        .hp2_awaddr({17'd0, hp2w_awaddr}), .hp2_awlen(hp2w_awlen),
        .hp2_awsize(hp2w_awsize), .hp2_awburst(hp2_awburst),
        .hp2_awvalid(hp2_awvalid), .hp2_awready(hp2_awready),
        .hp2_wdata(hp2w_wdata), .hp2_wstrb(hp2w_wstrb), .hp2_wlast(hp2_wlast),
        .hp2_wvalid(hp2_wvalid), .hp2_wready(hp2_wready),
        .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid), .hp2_bready(hp2_bready),
        .hp2_araddr({17'd0, hp2w_araddr}), .hp2_arlen(hp2w_arlen),
        .hp2_arsize(hp2w_arsize), .hp2_arburst(hp2_arburst),
        .hp2_arvalid(hp2_arvalid), .hp2_arready(hp2_arready),
        .hp2_rdata(hp2w_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
        .hp2_rvalid(hp2_rvalid), .hp2_rready(hp2_rready),
        .gpio_i(gpio_i), .gpio_o(gpio_o),
        // GIC SPIs 121 to 123: the disk's, the Chaosnet cable's and the
        // serial line's, as `IRQ_F2P` bits 0 to 2 on the Zynq-7000.
        .irq0({5'b0, ser_irq, chaos_irq, pack_irq})
    );

    // EMIO 94:0 out of the processing system are nobody's here.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_gpio_o;
    assign unused_gpio_o = ^gpio_o[94:0];
    /* verilator lint_on UNUSEDSIGNAL */

    logic error_seen;
    always_ff @(posedge clk) begin
      if (rst) error_seen <= 1'b0;
      else if (port_error) error_seen <= 1'b1;
    end
    assign ddr_error = error_seen;

  end else begin : g_nomem

    // No processing system: the machine alone, as the Cora's `g_nomem`.
    assign mem_done  = 1'b0;
    assign mem_rdata = 32'd0;
    assign ddr_error = 1'b0;
    assign port_read_ack  = 1'b0;
    assign port_write_ack = 1'b0;
    assign drive_present = 8'd0;
    assign drive_read_only = 8'd0;
    assign drive_timed = 1'b0;
    assign store_we = 1'b0;
    assign store_slot = 5'd0;
    assign store_addr = 9'd0;
    assign store_wdata = 32'd0;
    assign store_busy = 1'b0;
    assign store_busy_slot = 5'd0;
    assign store_deny = 1'b0;
    assign con_req = 1'b0;
    assign con_msyn = 1'b0;
    assign con_tv_lispm = 1'b0;
    assign con_color_tv = 1'b0;
    assign con_hdmi_out    = 2'b01;
    assign con_hdmi_rotate = 2'd0;
    assign con_steady_lamps = 1'b0;
    // And nobody to say how many memory boards there are, so it is 32,
    // muir's own default and what a board with a console comes up with.
    assign con_mem_boards = 7'd32;
    assign con_tv_map_a = 4'd0;
    assign con_write = 1'b0;
    assign con_addr = 18'd0;
    assign con_wdata = 16'd0;
    assign con_ro_addr = 18'h3FFFF;
    assign con_mach_rst  = 1'b0;
    assign con_mach_boot = 1'b0;
    assign dbg_in_req     = 1'b0;
    assign dbg_in_wr      = 1'b0;
    assign dbg_in_a       = 2'd0;
    assign dbd_to_machine = 16'd0;
    assign dbg_connect    = 1'b0;
    assign dbg_wiring     = 2'd0;
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
    assign chaos_rx_lost  = 1'b0;
    assign chaos_tx_done  = 1'b0;
    assign chaos_tx_abort = 1'b0;
    assign chaos_cbl_busy = 1'b0;
    // All ones on the mouse: a cable with nothing moving on it.
    assign kbd_strobe     = 1'b0;
    assign kbd_code       = 24'd0;
    assign mouse_lines    = 7'h7F;

  end

  // ------------------------------------------------------------ the fold
  //
  // `witness` keeps the machine alive through synthesis: every output of
  // `cadr_machine` folds into it, registered, and `DONT_TOUCH` keeps the
  // register, which no pin reads.  `cadr_cora.sv` has the argument.
  // MACHRUN and the disk have no lamp on this board and are here too.
  /* verilator lint_off UNUSEDSIGNAL */
  (* DONT_TOUCH = "true" *)
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
                   machrun, errhalt, stathalt, n_boot, ddr_error,
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
                   dbg_in_ack, dbd_from_machine, dbd_oe, timeout_inhibit,
                   dbg_holder,
                   dbg_engaged, dbg_foreign, dbg_live, dbg_active, dbg_peer_far, dbg_frames,
                   con_tv_map_q, con_tv_color_map_q, con_disp_color_map_q,
                   con_hdmi_out, con_hdmi_rotate,
                   dbg_wire_state, host_rdata};
    end
  end

  // ================================== THE TWO LAMPS ==========================
  //
  // **UF1 IS THE MICROCYCLES AND UF2 THE ERROR HALT, ELSE A SLOW BLINK WHILE
  // THE MACHINE RUNS OUT OF ITS BOOT PROM.**  The Cora's two lamps' meanings
  // on two single-color LEDs:
  //
  //   UF1  `rtl/plumbing/cadr_lamp_microcycle.sv`, the Cora's green: bit 19
  //        of a count of retired microcycles, so it flickers while the
  //        machine retires them and FREEZES when it stops; a level with
  //        `--no-blinking-leds`.
  //   UF2  lit for `ERRHALT`, latched by `rtl/plumbing/cadr_lamp_errhalt.sv`
  //        and cleared by any `-BOOT`, as the Cora's red; otherwise blinking
  //        slowly, 0.75 times a second off the heartbeat's top bit, while
  //        `-PROMENABLE` says the machine is fetching from its boot PROM, as
  //        the Cora's blue; otherwise dark.
  //
  // So a slow UF2 under a flickering UF1 is a boot, UF2 dark with UF1
  // flickering is a running machine, UF1 frozen with UF2 dark is a machine
  // somebody halted, and UF2 lit is a machine that fell over.  The fault
  // bitstream blinks both together twice a second, which none of these is.
  // MACHRUN, the fabric's heartbeat and the disk have no lamp: two lamps
  // cannot carry them as well, and the console reads all three.
  logic errhalt_lit;
  cadr_lamp_errhalt u_lamp_errhalt (
      .clk(clk), .rst(mach_rst), .errhalt(errhalt), .n_boot(n_boot),
      .lit(errhalt_lit)
  );

  logic cycle_lamp;
  cadr_lamp_microcycle u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(con_steady_lamps),
      .retired(clock_edge), .lit(cycle_lamp)
  );

  // Registered on the way to the pad: a lamp is sampled by nobody, so a
  // tick is free and the cones stop at a flip-flop.
  always_ff @(posedge clk) begin
    uf1 <= cycle_lamp;
    uf2 <= errhalt_lit || (promenable && tick[26]);
  end

  // The heartbeat's low bits read once, for lint: only the top one drives a
  // lamp.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_tick;
  assign unused_tick = ^tick[25:0];
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------- the fan
  //
  // Low runs it.  Every KR260 bitstream holds it so.
  assign fan_en_b = 1'b0;

endmodule

`default_nettype wire
