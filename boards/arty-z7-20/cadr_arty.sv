// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on an Arty Z7-20: a top level with real pins.
//
// The machine under it is checked against muir, and the plumbing around the
// machine against the properties it is held to.  This file is what puts both
// on a real part with real package pins --- synthesized, placed, routed and
// written to a bitstream --- which is a different question from whether they
// are correct.
//
// **BY DEFAULT THIS IS NOT A WORKING CADR AND IS NOT MEANT TO BE.**  With
// `DDR` zero there is no memory behind it: `mem_done` is tied low, so every
// cycle the boot PROM runs to main memory --- the first at microcycle 536,303
// --- is ended by the bus interface's NXM timer rather than by a slave, and
// the machine carries on with nothing stored.  What it can show is that the
// fabric runs: the clock generator ticking, microcycles retiring, the PROM
// executing.
//
// `DDR` set puts the Zynq processing system and its DDR3 behind `mem_*`.  It
// is off for the same reason `PROBE_DEPTH` is, and the note beside that
// parameter is the whole argument: the design this file describes by default
// is the machine and nothing else, so what the machine costs and what the
// memory costs stay two questions.
//
// `PROVE` set builds one of the two boards that answer whether that memory
// works at all, and neither of them is the machine running out of it.  The
// machine is still in the design and its memory port still gets nothing,
// exactly as on the default board; what changes is that `rtl/plumbing/cadr_prove.sv`
// drives that port instead, with one word and one address, and somebody
// outside the design says whether the word arrived.  `PROVE=1` writes a word
// for a debugger to read; `PROVE=2` reads one a debugger wrote and WRITES IT
// BACK to a second address, so the comparing is done outside the design there
// too.  Neither needs anybody at the board.  That module's header is the
// whole argument for the two steps and for their order.
//
// THREE THINGS THIS FILE HAS TO GET RIGHT THAT ARE NOT OBVIOUS.
//
// **THE TICK IS 10 ns, AND SO IS MIT'S GRID.**  `CLKOUT0_DIVIDE_F` below is
// the only place the length of a tick is decided.  It went from 5 to 6.25 on
// 2026-09-11 and from 6.25 to 10 the same afternoon, when a one-character
// change to a multiplexer cost a third of a nanosecond and the memory-on board
// stopped closing again.  A design sitting near zero turns every edit into a
// timing question, and the longer tick buys that off.
//
// **THE GRID IS A DIFFERENT NUMBER THAT HAPPENS TO BE EQUAL.**
// `cadr_tick_pkg::TICK_NS` is the conversion from MIT's drawings into tick
// counts, not the length of a tick.  For a while it stayed 5 under a 10 ns
// tick: every count was unchanged, and the machine ran at half the original
// speed with nothing inside it able to tell.  It is 10 now as well, so every
// instant on MIT's drawings rounds UP to the next 10 ns.  A normal microcycle
// is 15 ticks, 150 ns against MIT's 145, and the machine runs at about 97% of
// the original speed.  Eleven instants move, eight by 5 ns and three by 7,
// and none earlier; `docs/timing.md` lists every one.  muir generates the
// reference traces under the same grid with `--timing-model fpga`, so every
// check still compares tick counts on both sides.
//
// What must never happen is an instant rounded DOWN or placed by a plain
// division, which at 10 ns collapses MIT's 5 ns edge to zero ticks and puts
// SELECT on top of a read tap --- the "different machine that still lights
// LEDs" this project keeps meeting.  `cadr_tick_pkg::ticks` rounds up and is
// the one place the conversion is made.
//
// **The board's clock is 125 MHz and the machine's is 100.**  The 100 MHz
// comes from an MMCM: 125 x 8 = 1000 MHz at the VCO, divided by 10.  **The
// VCO is 1000 MHz exactly, so the output divider reads literally as the tick
// in nanoseconds**, which is what lets `boards/arty-z7-20/vivado/tick.tcl` read
// the number back out of this file and hand it to `create_clock` and to the
// constraint assertions --- so no constraint can describe a different machine
// from the one being built.  A primitive rather than a generated IP core,
// because a primitive is one instantiation in a file somebody can read and an
// IP core is a directory of generated XML.
//
// **THE MACHINE'S TWO CLOCKS KEEP THE TIME OF DAY**, because the grid and the
// tick are the same 10 ns and a free-running clock keeps its true period in
// nanoseconds on any grid:
//
//   - `rtl/machine/cadr_io_board.sv`'s microsecond clock is 100 ticks, one
//     real microsecond, and a CADR wall clock run off it keeps real time.
//   - `rtl/machine/cadr_tv.sv`'s sync program makes a frame of 15,456,000 ns,
//     1,545,600 ticks, so the vertical interrupt arrives every 15.456 real ms
//     --- 64.70 Hz, the rate the display board scanned at.  MIT's microcode
//     uses that interrupt as its roughly-sixty-cycle clock for mouse tracking
//     and the scheduler's sequence break.
//
// While the grid was 5 ns under a 10 ns tick both ran at half rate, and that
// was recorded as a deliberate disagreement with the wall.  A board whose tick
// differs from the grid brings it back at the ratio of the two, which is one
// reason a tick has to divide a thousand nanoseconds: at 10 ns a real
// microsecond is exactly 100 ticks.
//
// **Every output has to reach a pin or synthesis will delete the machine.**
// `cadr_machine` brings out the whole datapath for the testbenches to compare
// --- PC, IR, the A and M buses, the ALU, twenty-odd more --- and a top level
// that left them unconnected would synthesize to almost nothing, place and
// route in seconds, and write a perfectly good bitstream of an empty part.
// That is the failure this project keeps meeting: not an error, but a
// plausible artifact.  So the wide outputs are reduced into one LED through a
// register, which costs four LUTs and keeps every one of them load-bearing.
// `boards/arty-z7-20/vivado/bitstream.tcl` checks the utilization against what the design is
// known to cost rather than trusting that the file exists.

`default_nettype none

// AND ONE THING IT DOES NOT DO BY DEFAULT.  `PROBE_DEPTH` is zero here, so
// the design this file describes is the machine and nothing else --- the same
// LUTs, the same registers, the same 28 block RAM tiles `boards/arty-z7-20/vivado/bitstream.tcl`
// measures.  Setting it instantiates `cadr_probe.sv`, which records one
// sample a microcycle and hands it back over JTAG; `boards/arty-z7-20/vivado/probe.tcl` builds
// that bitstream and reads it.  Off by default because an instrument in every
// bitstream is an instrument nobody measures the cost of, and because the two
// questions --- does the machine fit, and what does watching it cost --- are
// worth keeping apart.
//
// AND THE SAME FOR `DDR`, which is zero here, so nothing below instantiates
// `cadr_ps7.sv` or `cadr_axi_master.sv` and `mem_done` is tied low exactly as
// it has always been tied.  Setting it puts the processing system and DDR3
// behind the machine's memory port --- the piece with no muir reference of
// any kind --- and `boards/arty-z7-20/vivado/bitstream.tcl` builds that board with `DDR=1`.
module cadr_arty #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    // MIT's TV sync PROM, for the display: `rtl/machine/cadr_tv.sv`.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex",
    parameter int unsigned PROBE_DEPTH = 0,
    parameter int unsigned DDR = 0,
    // 0 the machine, 1 the fabric writes a word, 2 the fabric reads one back
    // and writes what it read to a second address.
    // See the note above the memory below: a `PROVE` board is a `DDR` board
    // by construction, because proving the port needs the port.
    parameter int unsigned PROVE = 0,
    // The display output: the CADR's screen out of DDR over `S_AXI_HP3` and
    // onto the HDMI connector, with no software in the path.  It needs the
    // processing system for that port, so like `PROVE` it turns `PORT` on by
    // itself.  `docs/display-output.md` is the design.
    parameter int unsigned HDMI = 0,

    // **THE SECOND DISPLAY BOARD, THE COLOR TV**, `lmtv.order`'s "for the
    // color TV, x is 5": a LISPM TV strapped to 0o17200000 with its control
    // words at 0o17377750, carrying a color monitor of its own.  One means
    // the fabric has the slot; whether a machine HAS the board is the
    // console's page 2 word 33, which `fpgarc`'s `--color-tv` writes at
    // boot, and a machine with none gives the NXM at those addresses ---
    // which is how `COLOR-EXISTS-P` finds out.  Zero leaves the slot out of
    // the fabric entirely, for a part with no room for it.
    parameter int unsigned LMTV = 1,

    // **WHICH MACHINE**: "cadr", MIT's, or "quux", the evolved CADR, each a
    // bitstream of its own on this board.  Handed to `cadr_machine` as it
    // stands, which refuses a name it does not know; the flow's `MACHINE`
    // sets it, and `build/machine_param.pass` holds that it arrives.
    parameter string MACHINE = "cadr",

    // **QUUX'S MICROCYCLE ON THIS BOARD**: four ticks, 40 ns, and no more for
    // an `ILONG` instruction (H1a, muir's `--timing-model sync
    // --sync-cycle-ticks 4`).  The fit at this K is what entitles it: its
    // longest path, the map into the next address, and the multiplier out of
    // the A memory, settle inside the four ticks and the three that the
    // constraint file `quux_machine.xdc` states for them.  The CADR reads
    // neither.
    parameter int unsigned SYNC_K = 4,
    parameter int unsigned SYNC_L = 0
) (
    input  var logic       sysclk,   // 125 MHz, pin H16
    input  var logic [3:0] btn,
    // The board's two slide switches.  **SW0 IS THE NO-AUTO-BOOT SWITCH** ---
    // see the note below the buttons --- and SW1 is a pin the board has that
    // this design has no opinion about, brought out so the port list matches
    // the board rather than the design, as BTN2 and BTN3 are.
    input  var logic [1:0] sw,
    output var logic [3:0] led,
    // The two tricolor LEDs. Driven high to light, one pin a color.
    output var logic       led4_r, led4_g, led4_b,
    output var logic       led5_r, led5_g, led5_b,
    // **MIT'S DEBUG CABLE ON ONE PMOD HEADER, JA, AND JB CARRIES NOTHING.**
    // A board is a debugger or a debuggee on this cable and never both at
    // once, so a second connector bought only a chain of three machines ---
    // and the register window already covers the case it looked like it
    // bought, muir on this board's own Arm cores reaching the DBGIN page
    // whatever the connector is doing.
    //
    // Eight pins, four each way, and only TWO of each four carry signals: the
    // header's rows are coupled pairs, so each pair takes one signal --- a
    // strobe on the first, one data line on the second --- and the other line
    // of each is a GUARD driven low beside it.
    // `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` under
    // `rtl/plumbing/cadr_dbg_cable.sv`, which owns the map.
    // A straight Pmod ribbon joins pin one to pin one, so the LOW four are
    // the debugger's at both ends and the HIGH four the debuggee's, and which
    // end drives which group follows the role. The eighth wire is a STROBE
    // and not a clock: nothing on either side is clocked by it.
    //
    // **THEY ARE BIDIRECTIONAL PADS AND THEY HAVE TO BE**, because the role
    // is not fixed at synthesis: the same four pins are driven on a debugger
    // and listened to on a debuggee, and `cadr_dbg_cable.sv` hands out
    // `pin_t` --- high is not driven --- for exactly that.
    // `boards/arty-z7-20/cadr_arty.xdc` has the pins, from Digilent's own
    // published file.
    inout  wire  [7:0]     ja,
    // The HDMI transmitter's four differential pairs.  **THEY ARE IN THE
    // PORT LIST AND CONSTRAINED ON EVERY BOARD, NOT ONLY AN `HDMI` ONE**,
    // because a pin with no driver cannot be placed and a pin constrained
    // `TMDS_33` cannot be driven single-ended.  With `HDMI` clear the four
    // buffers are fed from zero and the connector sits at a direct-current
    // level, which a monitor reads as no signal.  Pins from Digilent's
    // published master file; `boards/arty-z7-20/cadr_hdmi.xdc` has them.
    output var logic       hdmi_tx_clk_p,
    output var logic       hdmi_tx_clk_n,
    output var logic [2:0] hdmi_tx_d_p,
    output var logic [2:0] hdmi_tx_d_n
);

  // ------------------------------------------------------------ the clock
  //
  // 125 MHz in, 100 MHz out. The VCO must sit between 600 and 1200 MHz on a
  // -1 part: 125 x 8 is 1000, comfortably inside, and 1000 / 10 is the tick.
  logic clk_fb, clk_raw, clk, mmcm_locked;

  // The eleven clock outputs this design does not take are left empty on
  // purpose --- that is how the primitive is written and what Xilinx's own
  // templates do --- so the style warning about it is turned off here rather
  // than answered with eleven wires nothing reads.
  /* verilator lint_off PINCONNECTEMPTY */
  MMCME2_BASE #(
      .CLKIN1_PERIOD  (8.000),   // 125 MHz
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(8.000),   // 1000 MHz at the VCO
      // THE TICK, AND THE ONLY PLACE IT IS DECIDED.  The VCO is 1000 MHz
      // exactly, so this number IS the tick in nanoseconds: 10.000 ns, which
      // is 100 MHz.  `boards/arty-z7-20/vivado/tick.tcl` parses these four
      // parameters out of this file and computes the period the constraints
      // are written against, so the fabric and its timing cannot describe
      // two different machines.  See the header for why every tick COUNT in
      // the design stays exactly as it was.
      .CLKOUT0_DIVIDE_F(10.000)   // 100 MHz, one tick = 10 ns
  ) u_mmcm (
      .CLKIN1  (sysclk),
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

  // ------------------------------------------------------------- the buttons
  //
  // **BTN0 BOOTS THE MACHINE AND BTN1 RESETS THE FABRIC.**  Both assignments
  // are facts of this board and neither is the one this file started with.
  //
  // BTN0 was the fabric's reset, which was a bring-up convenience: the CADR's
  // own way to restart is the boot button on its light panel, and a person at
  // this board pressing the button nearest to hand should get what a person
  // at a CADR pressing the button gets --- the machine back at the boot PROM
  // with its memory intact --- and not the fabric reconfigured out from under
  // Linux.  So BTN0 is `-BOOT2`, the light panel's button.
  //
  // **THE FABRIC'S PUSH-BUTTON RESET IS BTN1 ON EVERY BOARD IN THIS
  // REPOSITORY**, so that a board is two buttons and nothing else: BTN0 boots
  // the machine and BTN1 resets the fabric.  The reset was on BTN3 here for a
  // while, on the argument that the one control which throws the machine's
  // whole state away should be at the far end of the row where it is hard to
  // press by accident.  That argument is a real one and it loses to the
  // uniformity: the Cora Z7-07S has two buttons and no more, so there is no
  // far end to put it at there, and a control that is the same button on
  // every board is worth more than a control that is BTN3 on the boards with
  // four buttons and BTN1 on the board with two.  BTN2 and BTN3 are pins this
  // board has and this design does not use.  The other reset term, the MMCM's
  // lock, is unchanged: the fabric is held in reset until its clock is real.
  //
  // **WHAT THE FABRIC RESET IS, AND WHAT IT IS NOT.**  It resets the logic in
  // the fabric --- the machine, the console's and the disk pack's register
  // faces, and the lamps --- while the processing system and Linux keep
  // running, and it does not reload the bitstream.  So on a board with a
  // processing system the programs under Linux keep the view of those faces
  // they had before, and after BTN1 the disk pack program and the console are
  // out of step with the fabric until they are restarted.  `rst -srst` over
  // JTAG resets everything, and on a Zynq board that is the reset to reach
  // for.  BTN1 exists for uniformity across the boards, and for a part with no
  // processing system and nothing else to reset it with.
  //
  // Pins: `btn[0]` is D19 and `btn[1]` is D20, both `LVCMOS33`, from
  // Digilent's `Arty-Z7-20-Master.xdc`.  `boards/arty-z7-20/cadr_arty.xdc`
  // carries them and false-paths all four, a human's finger being no timing
  // constraint.
  //
  // Reset while the MMCM has not locked, and on BTN1. Synchronized out of
  // the 100 MHz domain: `locked` is asynchronous to it by construction.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked || btn[1]};
  assign rst = rst_sync[3];

  // ------------------------------------------------------ BTN0, DEBOUNCED
  //
  // **A RESET DOES NOT NEED DEBOUNCING AND A BOOT DOES.**  BTN1's four
  // synchronizer stages are all its job wants: a reset asserted for a
  // millisecond of contact bounce is a reset, and the bounces land inside it.
  // `-BOOT2` is a level the machine READS the end of --- it runs the PROM
  // from word 0 when the button is let go --- so every bounce on the release
  // is another press, and a machine booted five times in two milliseconds is
  // a machine whose first four boots ran four microcycles each.  The light
  // panel's own switch is debounced by the hysteresis of the 74LS14 Schmitt
  // inverter at OLORD2 1A20 that takes it; this is that inverter.
  //
  // The rule: the line must read the same for `DEBOUNCE_T` ticks together
  // before the debounced level follows it.  At the 10 ns tick 400,000 ticks
  // is 4 ms, which is past the 1 to 2 ms a tactile switch of this kind
  // settles in and far short of the shortest press a person can make.  It
  // costs one 19-bit counter.
  //
  // **PRESS AND HOLD AND THE MACHINE STAYS AT THE BOOT TRAP; LET GO AND IT
  // RUNS.**  That is what the level means at the 74S02 at OLORD2 1A07 and it
  // is what muir's own press and release do (`tests/keyboard_boot.rs`).  No
  // simulation check in this repository reaches a pin, so what holds this
  // wiring is `make build/arty.pass`, which lints every board configuration
  // and would report a pin left unconnected or a signal nothing reads.
  localparam int unsigned DEBOUNCE_T = 400_000;   // 4 ms at the 10 ns tick

  logic [1:0]  btn0_sync;
  logic [18:0] btn0_t;
  logic        btn0_level;
  always_ff @(posedge clk) begin
    if (rst) begin
      // A button nobody is pressing: the pin is pulled down and the machine
      // is not being booted by anything at the board.
      btn0_sync  <= 2'b00;
      btn0_level <= 1'b0;
      btn0_t     <= 19'(DEBOUNCE_T - 1);
    end else begin
      btn0_sync <= {btn0_sync[0], btn[0]};
      if (btn0_sync[1] == btn0_level) begin
        btn0_t <= 19'(DEBOUNCE_T - 1);
      end else if (btn0_t == 19'd0) begin
        btn0_level <= btn0_sync[1];
        btn0_t     <= 19'(DEBOUNCE_T - 1);
      end else begin
        btn0_t <= btn0_t - 19'd1;
      end
    end
  end

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
  // MEM<31:0> on its way to an Xbus slave. No slave exists, so nothing
  // reads it --- but it is an output of `cadr_machine` and the fold below
  // is what keeps it from being deleted along with whatever computes it.
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge, wrcyc;
  logic device, dev_rq, dev_write, promdisable, promenable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, timed_out, mbusy, mbusy_sync;
  logic mem_req, mem_write;
  // The answer, from whatever is behind the memory port. Driven in one of the
  // two arms of the `DDR` generate below and nowhere else.
  logic mem_done;
  // The port's own answers, for the transaction audit inside the machine:
  // driven from `g_ddr` where the `PS7` is and tied low where there is none.
  logic port_read_ack, port_write_ack;
  logic [31:0] mem_rdata;
  // The disk's two seams, likewise driven from one arm or the other: the
  // drive --- which units have a pack, the read-only switch, whether the
  // drive's time is charged --- and the block store's fill port. With `DDR`
  // off both are tied off here and the whole drive constant-folds; with it
  // on, `rtl/plumbing/cadr_disk_pack.sv` drives them from registers Linux writes and
  // from the pack in DDR.
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
  // error lamp is cleared by it and nothing out here can otherwise tell that
  // a keyboard chord or the debug cable booted the machine.
  logic        n_boot;
  // -XBUS.INTR, the display's vertical interrupt ORed with the disk's
  // request inside `cadr_machine`.  Nothing on this board reads it but the
  // fold: it is the machine's own line to its own processor, and what it is
  // doing out here is being kept alive, like every other output.
  logic        sintr;
  // The request path and the cache's bookkeeping, likewise: the block the
  // walk lacks and its posting, the wait, Linux's denial, the slot the walk
  // is on and what it did to it.  `rtl/machine/cadr_disk_controller.sv` says what
  // each is; here they cross from the machine to the pack side, or are tied
  // off and folded with the rest of the machine's outputs.
  logic [4:0]  store_busy_slot, ch_slot;
  logic [30:0] req_tag;
  logic        req_valid, req_post, ch_waiting, ch_wrote, ch_hit, store_deny;
  // The console's half of the diagnostic bus.  `rtl/plumbing/cadr_console.sv` in
  // `g_ddr` drives it from `M_AXI_GP1`; tied off, the arbiter inside
  // `cadr_memory_path` folds to a constant and the register block keeps its
  // one master, which is the board this file builds by default.
  logic        con_req, con_gnt, con_msyn, con_write, con_ssyn;

  // **WHICH DISPLAY BOARDS THE BACKPLANE HAS**, out of the console's page 2
  // word 33, and the two boards' color maps coming back on pages 4 and 5.
  // A board with no console is a machine with one SIMPLE TV and no color TV,
  // which is muir's own default and the backplane every reference trace
  // taken before the second board was built was taken on.
  logic        con_tv_lispm, con_color_tv;
  logic [3:0]  con_tv_map_a;
  logic [23:0] con_tv_map_q, con_tv_color_map_q;
  // **AND THE COLOR BOARD'S MAP ON ITS SECOND PORT**, which is the display
  // output's: `lmtv.order` puts the map RAMs and their converters off the TV
  // board, so the block that turns a four-bit pixel into three channels is that
  // hardware and this is the cable to it.  `disp_map_a` is driven from the pixel
  // clock's domain and the word comes back combinationally, which
  // `rtl/plumbing/xilinx7/cadr_hdmi.xdc` bounds.
  logic [3:0]  disp_map_a;
  logic [23:0] con_disp_color_map_q;
  // What the display output shows and which way up, page 2's word 34.
  logic [1:0]  con_hdmi_out, con_hdmi_rotate;
  // Whether LD1 and LD2 blink or hold a level, page 2's word 35.
  logic        con_steady_lamps;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  // MIT's debug cable, the twenty-one wires of the DBGIN connector.
  // `rtl/plumbing/cadr_debug_window.sv` in `g_ddr` is the carrier that puts
  // them on `M_AXI_GP1` beside the console, behind
  // `rtl/plumbing/cadr_gp1_split.sv`; with no carrier `dbg_in_req` is held
  // low and `rtl/machine/cadr_dbgin.sv` inside the machine folds to its idle
  // state, which is the board this file builds by default.  `docs/debug-
  // cable.md` is the whole of it.
  logic        dbg_in_req, dbg_in_wr, dbg_in_ack;
  logic [1:0]  dbg_in_a, dbd_oe;
  logic [15:0] dbd_to_machine, dbd_from_machine;
  // And the same cable again, as Pmod JA carries it. `cab_*` is a second
  // board's debugger arriving at this machine's DBGIN page and joins the
  // window's at `rtl/plumbing/cadr_dbg_join.sv`; `dbgout_*` is this machine's
  // own DBGOUT page going the other way, which is CC on this board debugging
  // a second one. `dbg_connect` is what the console asks for and the four
  // beside it are what the connector says back.
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
  // And which way round the ribbon was made: 0 auto, 1 straight, 2 crossover,
  // from the console's word 14, with what came of it coming back.  Only a
  // DEBUGGER applies it; see `rtl/plumbing/cadr_dbg_cable.sv`'s table.
  logic [1:0]  dbg_wiring;
  logic [2:0]  dbg_wire_state;
  logic [7:0]  ja_o, ja_t;
  logic        mdbg_req, mdbg_wr;
  logic [1:0]  mdbg_a;
  logic [15:0] mdbg_dbd;
  // The modifier register's two effects.  `debuggee_reset` is bit 1 and is
  // this processor's power-on reset, so it joins the OR below; MIT's own note
  // is "write a 1 here then write a 0", which makes it a LEVEL.
  // `timeout_inhibit` is bit 2 and nothing consumes it yet, so it folds ---
  // `rtl/machine/cadr_memory_path.sv` says at the instance why it exists
  // anyway.
  logic        debuggee_reset, timeout_inhibit;
  // The virtual address register, `Q` and `MD` on their own wires, page 0's
  // words 7, 8 and 9.  They are NOT on the diagnostic bus --- MIT's sixteen
  // have no register for any of them --- and they leave `cadr_machine`
  // already captured at
  // the microcycle boundary, `rtl/machine/cadr_console_state.sv` being instantiated
  // inside it so that `rtl/plumbing/xilinx7/cadr_machine.xdc` can reach the capture.  On a
  // board with no console they still exist and fold into `witness` with the
  // other outputs, because a fold with exceptions in it is not a rule anybody
  // can check.  **`con_md` is not the `md` port above**: that one is the
  // datapath wire, this one is the same register taken at the boundary for a
  // reader outside the machine's constraints.
  logic [31:0] con_vma, con_q, con_md;
  // And the readout of the machine's memories, page 0's words 10, 11 and 12.
  // The address goes in and the word and its echo come back; the window is
  // `rtl/plumbing/cadr_console.sv`'s and the second read ports are the last
  // section of `rtl/machine/cadr_microcycle.sv`.  On a board with no console
  // the address is tied off and the two answers fold into `witness` with
  // every other output, because a fold with exceptions in it is not a rule
  // anybody can check.
  logic [17:0] con_ro_addr, con_ro_echo;
  logic [47:0] con_ro_data;

  // ------------------------------------------------- the I/O board's cables
  //
  // The card is a Unibus slave inside `cadr_machine` and these are the things
  // MIT plugged into it.  **TWO OF THE FOUR HAVE FAR ENDS NOW**, and the day
  // they arrived one line in this file changed and nothing in the machine
  // did, which is the reason a seam is a port rather than a constant inside.
  // The keyboard and the mouse are still tied off, and each names the slice
  // that will drive it.
  //
  //   the keyboard    `cadr-usb-input`, last in the order of work.  The kernel
  //                   side is done --- `evtest` printed keystrokes off a USB
  //                   keyboard on this board on 10 Sep --- and what is missing
  //                   is the program that carries those events across and the
  //                   register face it writes them through.  No strobe means
  //                   no scan code and `KBD READY` never rises.
  //   the mouse       the same program.  Seven lines and not two deltas: the
  //                   card takes quadrature as MIT's mouse drives it, so
  //                   whatever turns a USB mouse's movement into phases is
  //                   fabric beside the card and is not built.  Held at zero
  //                   the card's latches agree with the lines from reset and
  //                   nothing is ever a change, so the two counters and the
  //                   comparator constant-fold --- which is the drive seam's
  //                   own lesson and means the FITTER DOES NOT TEST THE MOUSE
  //                   on this board.
  //   the serial port the 2651 is on the card and its LINE is
  //                   `rtl/plumbing/cadr_serial_line.sv`, a page of
  //                   `M_AXI_GP0` below.  That module runs the baud-rate
  //                   generator the card leaves out and paces the shift
  //                   register's two edges; `cadr-serial` puts the line on a
  //                   TCP socket.  **ON A BOARD WITH NO PROCESSING SYSTEM it
  //                   is still tied off**, in the `PORT` generate's other
  //                   arm, and with the cable out the sheet's own `V_OH` row
  //                   keeps both halves stopped, so the whole chip
  //                   constant-folds --- which is the drive seam's lesson and
  //                   means the fitter does not test the 2651 on that board.
  //   the Chaosnet    the interface is on the card --- AIM-628's five
  //                   registers, both 256-word packet buffers, the bit
  //                   counter and the lost count --- and its CABLE is
  //                   `rtl/plumbing/cadr_chaos_cable.sv`, the page below it.
  //                   That module holds one frame each way and appends the
  //                   source address and the check word the 9401 would have;
  //                   the turn timer, the transceiver and the ether are
  //                   `cadr-chaosnet`'s.  Tied off on a board with no
  //                   processing system, where the address switches read zero
  //                   and the card's receive buffer constant-folds with them.
  // **AND THE TWO CABLES ARE NO LONGER TIED OFF WHEREVER THERE IS A
  // PROCESSING SYSTEM.**  `rtl/plumbing/cadr_chaos_cable.sv` and
  // `rtl/plumbing/cadr_serial_line.sv` are the far ends of them, on
  // `M_AXI_GP0` behind `rtl/plumbing/cadr_gp0_split.sv`, and they are driven
  // from the `PORT` generate below --- so this file's tie-off is now only
  // for the board that has no PS at all, where there is no port for a
  // program to reach them on.
  // **AND THE KEYBOARD AND THE MOUSE HAVE JOINED THEM.**
  // `rtl/plumbing/cadr_input_cables.sv` is the far end of the card's other
  // two cables, on the fourth page of `M_AXI_GP0`, and `cadr-terminal`
  // carries a viewer's keys and pointer to it.  They were tied off
  // everywhere until this; they are tied off in `g_nomem` now, with the
  // other two, for the same reason --- a cable with nothing on the end of
  // it is a cable nobody has plugged in.
  logic        kbd_strobe;
  logic [23:0] kbd_code;
  logic [6:0]  mouse_lines;
  logic        ser_tx_take, ser_tx_done, ser_rx_strobe, ser_plugged;
  logic [7:0]  ser_rx_data;
  logic        ser_rx_end, ser_rx_parity, ser_rx_framing;
  logic [15:0] chaos_address, chaos_rx_word;
  logic        chaos_rx_valid, chaos_rx_done, chaos_rx_crc, chaos_rx_lost;
  logic [12:0] chaos_rx_bits;
  logic        chaos_tx_done, chaos_tx_abort, chaos_cbl_busy;
  // What the card gives back.  Nothing on this board reads any of it: the
  // speaker has no pin, the 2651 is not fitted, and `iob_intr` and
  // `iob_vector` leave the machine as observations, the request itself going
  // to `cadr_busint_regs.sv` INSIDE the machine, where `ENABLE UB INTS`
  // decides whether the interface takes it.  They fold into `witness` with
  // every other output of the machine.
  // Which slave is pulling `-UB SSYN`: bit 0 the register block, bit 1 the
  // card, bit 2 the bus interface's own registers.  An observation output,
  // folded like the rest.
  logic [2:0]  ub_ssyn_by;
  logic        ser_reset, iob_intr, audio, clock_ready;
  // What the two chips on the card hand their far ends.  Nothing on this
  // board takes any of it yet, so it folds into `witness` with the rest.
  logic [7:0]  ser_mode1, ser_mode2, ser_cmd, ser_tx_data, ser_status;
  // The 2651's SYN1, SYN2 and DLE registers and their pointer: nothing
  // reads them back, so the fold below is what keeps synthesis from
  // trimming the registers away.
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
  // **THE CONSOLE CAN RESTART THE CADR, AND IT JOINS BTN1 RATHER THAN
  // REPLACING IT.**  `rst` above is the MMCM's lock and the reset button; a write of
  // `RESET_KEY` to the console's word 6 pulses `con_mach_rst` for 64 ticks,
  // and this is the OR.  A soft reboot from the processing system is wanted
  // because the board runs Linux beside the machine, and restarting the CADR
  // had otherwise meant a finger on a board nobody is sitting at, or a fresh
  // bitstream.  `rtl/plumbing/cadr_console.sv`'s header has the key, the length and
  // why it is a pulse and not a level.
  //
  // **A REGISTER AND NOT A GATE**, for the reason `pack_rst` below gives at
  // the same shape: this lands on some two thousand registers spread across
  // `cadr_machine`, and a LUT between the countdown and that fanout is a LUT
  // on every one of their reset pins.  One tick later on a reset costs
  // nothing that anything counts, `rst` itself already being four
  // synchronizer stages deep.
  //
  // **AND THE RULE FOR WHAT TAKES IT: `mach_rst` replaces `rst` wherever
  // `rst` means "since the MACHINE started", and `rst` stays wherever it
  // means "since the FABRIC was configured".**  Written down because the
  // alternative --- folding `con_mach_rst` into `rst_sync` beside BTN1, which
  // is tidier and looks right --- is wrong in three places at once, and each
  // of the three is worth having on the record:
  //
  //   - **It would reset the console itself**, through `gp1_rst`.  The AXI
  //     write that asked for the reset is IN FLIGHT while the pulse is up, so
  //     `wst` would drop back to `W_ADDR` with no `BVALID` ever offered ---
  //     and a GP write nothing answers hangs both Arm cores at one PC each,
  //     measured on this board.  The console would freeze the machine it was
  //     written to un-freeze.
  //   - **It would reset the pack side**, through `pack_rst`, and Linux's
  //     mounted pack with it: `cadr_disk_pack.sv`'s registers are the disk
  //     pack program's state, not the machine's, and a restart of the CADR is
  //     not a reason to forget which file is in the drive.
  //   - **It would reset `cadr_axi_master` mid-transaction**, as BTN1 did
  //     through `axi_rst` until the adapter was given the port's reset alone,
  //     which is an AXI protocol violation the PS7 cannot recover from --- VALID dropped without READY, or R beats returned to a master
  //     with RREADY low.  It is also unnecessary: the machine drops `mem_req`
  //     at reset, `cadr_axi_master` finishes its transaction and returns to
  //     IDLE when it sees that (its `DONE` state), and `cadr_xbus_ddr`'s
  //     `dev_ack` is `asked && (done || mem_done)` with `asked = sel &&
  //     dev_rq` --- so a transaction that completes into a machine which is
  //     no longer asking is ignored by construction and not by luck.  That is
  //     a structural argument and not "the boot PROM does not touch memory
  //     for 118 ms", which would be a claim about what a program happens to
  //     do.
  //
  // The tally `u_count` also keeps `rst`, and for its own reason: it counts
  // the PS7's handshakes at the boundary, on the port's side of the seam, and
  // it is the one instrument `boards/arty-z7-20/vivado/ddr_run.tcl` reads with nobody at the
  // board.  So its counts are cumulative across a console reset, which is
  // stated rather than fixed --- an instrument a program can clear from Linux
  // is an instrument whose reading depends on who has been at the console.
  //
  // **AND THE DEBUG CABLE'S MODIFIER BIT 1 IS THE THIRD TERM**, for the same
  // reason and with the same rule.  MIT calls it "Resets the debuggee's
  // Unibus and bus interface"; it crosses the debuggee's own cables to OLORD2
  // and is that processor's power-on reset, so CC's reset of a debuggee goes
  // down the cable and needs nothing else.  It is a LEVEL, not a pulse ---
  // "write a 1 here then write a 0" --- and it must NOT reach the DBGIN page
  // that makes it: a modifier register cleared by its own bit 1 clears the
  // bit that is clearing it, and MIT's sequence could not be written at all.
  // `tb/cadr_dbgin_harness.sv` measured that before it was understood, and
  // the page therefore takes `rst` inside `cadr_machine`, one level below
  // this.  Nor does it reach the carrier, for the reason the console gives
  // about its own: a carrier reset by the machine's reset would abandon the
  // request that asked for it.
  logic con_mach_rst;
  logic mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || con_mach_rst || debuggee_reset;

  // ------------------------------------------------- `-BOOT2`, the button
  //
  // **THE LIGHT PANEL'S LINE HAS TWO DRIVERS HERE AND NEITHER OWNS IT.**  On
  // a CADR `-BOOT2` is a pulled-up line taken low by the momentary switch on
  // the panel, through a section of the 74LS14 at OLORD2 1A20.  This board
  // has no panel, so it gives the line the two things a panel would be: a
  // push-button under somebody's finger (BTN0, debounced above) and a write
  // of `BOOT_KEY` to the console's word 13, which is the same button pressed
  // from Linux or over the network.  Either one holds it down; it comes back
  // up when both let go, which is the pull-up.
  //
  // It is NOT registered, where `mach_rst` is.  That register buys a shorter
  // path onto some two thousand reset pins; `-BOOT2` reaches one gate inside
  // `cadr_machine`, and a tick of skew between the two drivers of a line a
  // person holds for milliseconds is not worth a register.
  logic con_mach_boot;
  logic n_boot2;
  assign n_boot2 = !(btn0_level || con_mach_boot);

  // --------------------------------------- SW0, THE NO-AUTO-BOOT SWITCH
  //
  // **A CADR WHOSE POWER HAS JUST COME ON HAS ITS CLOCK STOPPED**: `RUN` is
  // clear, nothing is running, and the button on its light panel is what
  // starts it.  This fabric comes up the other way by default, with `RUN`
  // preset --- a board switched on runs its boot PROM, waits for a drive and
  // boots its band, which is what somebody switching a board on wants and what
  // every bring-up board here needs.  SW0 is how a board being worked on is
  // asked for the other behavior instead.  muir's `--no-auto-boot` is the
  // same state by the same argument, and the card's `fpgarc` has that flag;
  // the two are an OR and the flag can never turn the switch off.
  //
  // **IT IS A POWER-ON CONDITION AND NOT A CONTROL, WHICH IS WHY IT IS READ
  // AT THE RESET AND NOWHERE ELSE.**  `cadr_spy_registers.sv`'s reset arm is
  // the one place `RUN` is decided and `cadr_microcycle.sv`'s is the one place
  // `SRUN` is, so the level goes to both and to nothing else: moving the
  // switch under a running machine does nothing until the next fabric reset,
  // and moving it back under a held machine starts nothing.  Only `-BOOT`
  // takes the hold off, which is what a button is for.
  //
  // **AND WHAT THE CONSOLE REPORTS IS THE VERY VALUE THE MACHINE USED.**
  // `sw0_held` follows the synchronized level at every edge `mach_rst` is up
  // and freezes at the last of them --- the same edge, off the same signal, as
  // the two reset arms inside the machine --- so the two cannot disagree, and
  // a person reading `cadr-console status` is told what the machine actually
  // came up with rather than what the switch says now.  Both go out: the value
  // that held it and the level today, because a switch moved since the reset
  // is exactly the thing somebody will want to see.
  //
  // Three synchronizer stages, because the switch is asynchronous to this
  // clock like every other pin.  No debounce: `-BOOT2` needs one because a
  // bounce on the RELEASE is another press, and this is a level read once, at
  // an instant a slide switch is not being moved at.
  //
  // Pin: `sw[0]` is M20, `LVCMOS33`, `IO_L7N_T1_AD2N_35`, Sch=SW0, from
  // Digilent's `Arty-Z7-20-Master.xdc`.  `boards/arty-z7-20/cadr_arty.xdc`
  // carries it and false-paths both switches, a slide switch being no timing
  // constraint.
  logic [2:0] sw0_sync;
  logic       sw0_level;
  logic       sw0_held;
  always_ff @(posedge clk) sw0_sync <= {sw0_sync[1:0], sw[0]};
  assign sw0_level = sw0_sync[2];
  always_ff @(posedge clk) if (mach_rst) sw0_held <= sw0_level;
  // A write or read that came back SLVERR or DECERR, held. Zero when there is
  // no memory, so LD5's blue is dark on the board this file builds by default.
  logic ddr_error;

  // LD4's three colors, as {red, green, blue}. It is a wire and not three
  // assignments because WHAT LD4 SAYS DEPENDS ON THE BOARD: on the machine it
  // is the machine's own error halt and nothing else, dark or red, and on a
  // `PROVE` board it is the witness's verdict, which is a board with no
  // machine behind the memory port and so no halt to report.
  // Driven from exactly one of two generate blocks, one down in the
  // memory and one beside the other lamps, so that neither configuration
  // leaves a signal the other one reads. Getting that wrong is an
  // UNUSEDSIGNAL and `build/arty.pass` says so.
  logic [2:0] lamp4;

  // A `PROVE` board is a `DDR` board: the whole of what it proves is that the
  // processing system's memory answers, and there is nothing to prove without
  // the port. Written as one localparam rather than left to whoever sets the
  // generics, because `PROVE=1` alone silently building the default board is
  // the shape of failure this project keeps meeting --- a switch that reads as
  // set and does nothing.
  // The display output needs `S_AXI_HP3`, which needs the processing
  // system, so it turns the port on for the same reason `PROVE` does.
  localparam int unsigned PORT = ((DDR != 0) || (PROVE != 0) || (HDMI != 0))
                                 ? 1 : 0;

  // What goes down the connector's four pairs.  Driven from inside the
  // memory generate when the display is built, and from zero when it is
  // not; the buffers that turn it differential are at the bottom of this
  // file, where every configuration reaches them.
  logic [3:0] hdmi_ser;

  // The heartbeat's counter. Declared here and counted down in the lamps
  // where its comment is, because a `PROVE` board's LD4 blinks off it and the
  // memory generate above the lamps is where that lamp is driven from.
  logic [25:0] tick;

  // ------------------------------------------------ the witness's numbers
  //
  // WHERE, AND WHAT. One address in the region `rtl/plumbing/cadr_ddr_map.sv` reserves
  // for the machine's main memory, and one word to put there. Both are chosen
  // so that a WRONG one is visible to somebody reading DDR from outside, which
  // is the only property that matters here --- the observer cannot be fooled
  // by a fabric that is consistently wrong, but it can be fooled by a value
  // that a broken bus would have produced anyway.
  //
  //   the address    `main_byte_address(22'o12345671)`, which is word
  //                  2,739,129 of the 3,932,160 the machine can reach ---
  //                  0x18A7_2EE4. Not the base: a bus stuck at zero, or one
  //                  that lost its high bits, lands on the base, so the base
  //                  is the one address that cannot tell you anything. Its
  //                  bits alternate, so a dropped or doubled address bit
  //                  moves it somewhere unrelated and the word is simply not
  //                  there. And **bit 2 is set**, which is the sharp part:
  //                  `cadr_axi_widen.sv` puts the word in the HIGH half of
  //                  the 64-bit beat at 0x18A7_2EE0, so the word at
  //                  0x18A7_2EE4's neighbor is the one a strobe pattern that
  //                  opens both halves would destroy. Reading that neighbor
  //                  is what makes the check able to fail.
  //
  //   the word       0x8A5C_36E1. Four different bytes, none of them 0x00 or
  //                  0xFF, each with three or four bits set, so a lane stuck
  //                  either way shows in every lane. Its halves differ and
  //                  neither is a rotation of the other, so a lane swap
  //                  shows. Bit 0 and bit 31 are both set, so a shift either
  //                  way shows. Reversed byte for byte it is 0xE1365C8A, so
  //                  an endianness swap shows. And it is not the address, nor
  //                  the address shifted, which is the mutation named
  //                  bridge-writes-the-address-instead-of-the-data, in the one
  //                  place here where it could happen.
  //
  // THE FILLER IS ITS COMPLEMENT, 0x75A3_C91E, and that is not decoration.
  // The neighborhood is filled with it from the debugger before the port is
  // released, so every word that should not have changed differs from `WORD`
  // in every bit. The rule "a stimulus that poisons cannot move with the
  // bug": against a neighborhood of zeros, a word that half-landed reads as
  // plausible. `docs/board.md` will carry the procedure; the numbers live
  // here, once.
  //
  //   the second     `main_byte_address(22'o12345706)`, 0x18A7_2F18. A
  //   address        `PROVE=2` board reads `PROVE_ADDR` and writes WHAT CAME
  //                  BACK here, so that the debugger and not the fabric does
  //                  the comparing. Chosen the same way as the first, and for
  //                  four reasons:
  //
  //                  **A DIFFERENT BEAT.** Its beat is 0x18A7_2F18 and the
  //                  read's is 0x18A7_2EE0, seven beats apart, so the
  //                  write-back cannot touch the word it just read --- and
  //                  the read's beat is checked to be unchanged afterwards,
  //                  which is what says so.
  //
  //                  **BIT 2 CLEAR, WHERE THE READ'S IS SET.** The read
  //                  takes the HIGH half of its beat and the write-back
  //                  opens the LOW half of its own, so a widening stuck on
  //                  one half is caught in one direction or the other: stuck
  //                  low, the read brings back filler; stuck high, the word
  //                  lands on this address's neighbor instead.
  //
  //                  **INSIDE THE POISONED BLOCK, WITH ITS OWN NEIGHBOR IN
  //                  IT TOO.** 0x18A7_2F1C is the other half of this beat
  //                  and carries the filler like everything else, so a
  //                  strobe pattern that opened both halves of the
  //                  write-back destroys a word the debugger prints.
  //
  //                  **NOT THE BASE, AND NOT THE READ'S ADDRESS SHIFTED.**
  //                  It differs from `PROVE_ADDR` in bits 2 through 8, so a
  //                  dropped or doubled bit among the low nine moves the
  //                  write-back somewhere the block still shows.
  // ------------------------------------------- the pixel clock's dividers
  //
  // The MMCM dividers that make the video mode's pixel clock out of the
  // board's 125 MHz: 125 x 8.625 is a VCO of 1078.125 MHz and the phy's fixed
  // divide of ten gives 107.8125 MHz, where VESA DMT asks 108.  That is 0.17
  // per cent out and a monitor takes far more; `docs/display-output.md` has
  // the arithmetic.
  //
  // **THE RASTER'S OWN FIGURES ARE NOT HERE**, they are in
  // `rtl/plumbing/cadr_display_out.sv`.  What IS here is the pair of dividers,
  // because those are about the BOARD's 125 MHz crystal rather than about the
  // mode, and a board with another crystal needs others.
  localparam int          HM_VCO_DIV   = 1;
  localparam real         HM_VCO_MULT  = 8.625;

  localparam logic [31:0] PROVE_ADDR = cadr_ddr_map::main_byte_address(22'o12345671);
  localparam logic [31:0] PROVE_WORD = 32'h8A5C_36E1;
  localparam logic [31:0] PROVE_ECHO = cadr_ddr_map::main_byte_address(22'o12345706);

  cadr_machine #(
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX),
      .LMTV(LMTV),
      .MACHINE(MACHINE),
      .SYNC_K(SYNC_K),
      .SYNC_L(SYNC_L)
  ) u_machine (
      .clk(clk), .rst(mach_rst),
      // **-XBUS.INTR IS THE MACHINE'S OWN NOW AND USED TO BE TIED TO ZERO
      // HERE.**  The display and the disk controller are both inside
      // `cadr_machine` and their two requests are ORed there; what comes out
      // is the level, folded below like every other output.  The tie-off was
      // the bug the board found on 2026-09-10: the band restored and the
      // machine spun for ever in `AWAIT-DISK`, because the one thing that
      // clears `A-DISK-BUSY` is the Xbus interrupt handler and no interrupt
      // could reach the processor through this line.  Nothing answers a
      // device cycle from outside still: the Xbus slaves that are not the
      // disk are their own slices and none of them exists.
      .sintr_o(sintr), .device_ack(1'b0), .device_rdata(32'd0),
      // THE DRIVE, AND THE PACK. With `DDR` off there is no drive on the
      // disk's cable, which is what `build/machine.pass` compares against:
      // with `drive_present` at zero the status register answers `0x2321`
      // --- not on line, not on cylinder, no unit selected --- for every one
      // of the boot PROM's 11,301 polls, and **tied off, the whole drive
      // constant-folds**, so that fit counts the register face and the
      // decode and not the spindle, the seek arithmetic or the eight
      // attention counters. With `DDR` on, `rtl/plumbing/cadr_disk_pack.sv` in
      // `g_ddr` drives all of it: a unit is present when Linux writes that
      // it has a pack mounted, and the block store is filled over
      // `S_AXI_HP2` from the pack in DDR at the block's address Linux writes
      // over `M_AXI_GP0`. That is what stops the drive, the store, the
      // command list's walk, the two checkwords and the channel's bus master
      // folding, and why the two fits differ by more than the adapter.
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
      // trace in this repository was taken with.
      .boards(7'd32),
      // And which display boards are in it, from the console face.
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
      .tv_map_a(con_tv_map_a), .tv_map_q(con_tv_map_q),
      .tv_color_map_q(con_tv_color_map_q),
      .disp_map_a(disp_map_a), .disp_color_map_q(con_disp_color_map_q),
      // The memory, or the absence of one: see the `DDR` generate below.
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
      // MIT's debug cable, out of the machine as twenty-one wires.  What is
      // on the other end of them is two debuggers joined by
      // `rtl/plumbing/cadr_dbg_join.sv`: `rtl/plumbing/cadr_debug_window.sv`
      // in `g_ddr`, a whole-port AXI3 slave behind the GP1 split, and the
      // Pmod connector JB.  On a board with no processing system
      // `dbg_in_req` is held low below, and with nothing in JB the connector
      // presents zeros too, so the DBGIN page folds.
      .dbg_in_req(mdbg_req), .dbg_in_wr(mdbg_wr), .dbg_in_a(mdbg_a),
      .dbd_in(mdbg_dbd),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      // And the other end of the same cable: the DBGOUT page, this machine
      // as somebody else's debugger. `rtl/plumbing/cadr_dbg_cable.sv` below
      // puts it on the connector when this board has the role, and answers
      // it with the pull-ups when nothing is plugged in.
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(dbgout_ack),
      .dbgout_dbd_in(dbgout_dbd_in), .dbgout_live(dbgout_live),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset: the BOARD's --- MMCM lock and BTN1 ---
      // and not `mach_rst`, which `debuggee_reset` is one term of.  A
      // modifier register cleared by its own bit 1 clears the bit that is
      // clearing it, and MIT's "write a 1 here then write a 0" could not be
      // written.  The carrier a level up takes the port's reset for the
      // neighboring reason.
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      // The I/O board's cables, tied off above with the slice that will
      // drive each, and what the card shows.
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
      .chaos_rx_lost(chaos_rx_lost),
      .chaos_tx_abort(chaos_tx_abort), .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      .ub_ssyn_by(ub_ssyn_by),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      // WHAT THE PROCESSING SYSTEM ITSELF ANSWERED, for the transaction audit
      // inside the machine. `rtl/plumbing/cadr_bus_audit.sv` sits under
      // `cadr_machine` and `rtl/plumbing/cadr_axi_master.sv` sits out here, so
      // a transaction born in the adapter raises no second `mem_req` and every
      // clause anchored on one is blind to it. These two are not: they are the
      // port's own handshakes, at the same boundary and off the same
      // registered copies `rtl/plumbing/cadr_mem_count.sv` counts, so the two
      // instruments cannot disagree about what the port did.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack)
  );

  // --------------------------------------- the debug cable, on Pmod JA
  //
  // MIT's whole cable on ONE connector, both directions, four pins each way.
  // `rtl/plumbing/cadr_dbg_cable.sv` is the connector and the role;
  // `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` under it are the
  // carrier and say why four
  // and four rather than the "one clock and seven data" this was drawn as.
  // The frame is twenty-four beats, which is twenty-one signals, a two-bit
  // marker and a parity bit over ONE data line --- one signal a coupled pair,
  // with the other line of each pair driven low.
  //
  // **IT IS INSTANTIATED ON EVERY BOARD, NOT ONLY A `DDR` ONE.** A board is
  // always a DEBUGGEE: it answers a debugger on the connector exactly as
  // MIT's board answers one on its DBGIN, and nothing has to be set for that.
  // So the connector cannot live inside `g_ddr` with the window --- and the
  // pins are the top level's besides, where an output nothing drives is a
  // PINMISSING. With no processing system `dbg_connect` is tied low below and
  // this board is a debuggee and nothing else, which is what a CADR with one
  // cable in it is.
  //
  // **AND IT TAKES THE BOARD'S RESET AND NOT THE MACHINE'S**, for the reason
  // the window and the DBGIN page give about theirs: modifier bit 1 resets
  // this machine over this very cable, and a carrier reset by it would forget
  // the request that asked for it.
  cadr_dbg_cable u_dbg_cable (
      .clk(clk), .rst(rst),
      // The role. `connect` is the console's word 14 and the `fpgarc` line
      // behind it; `engaged` is whether this board took it, which is not the
      // same question --- a board that can see a debugger on the forward
      // group refuses, and `foreign` is how the console says why.
      .connect(dbg_connect), .engaged(dbg_engaged), .foreign(dbg_foreign),
      .peer_far(dbg_peer_far), .live(dbg_live), .active(dbg_active),
      // Which way round the cable was made, and what the board found.
      .wiring(dbg_wiring), .wire_state(dbg_wire_state),
      // Frames heard and frames refused: the crosstalk instrument, page 0's
      // word 15.
      .frames(dbg_frames),
      // This machine's own DBGOUT page: CC on this board, writing
      // `0o766100`-`0o766137`, debugging the board at the far end.
      .out_req(dbgout_req), .out_wr(dbgout_wr), .out_a(dbgout_a),
      .out_dbd(dbgout_dbd), .out_ack(dbgout_ack),
      .out_dbd_in(dbgout_dbd_in), .out_live(dbgout_live),
      // And a second board's debugger arriving here, which joins the
      // window's cable at the page below.
      .in_req(cab_req), .in_wr(cab_wr), .in_a(cab_a), .in_dbd(cab_dbd),
      .in_ack(dbg_in_ack), .in_dbd_out(dbd_from_machine), .in_dbd_oe(dbd_oe),
      .pin_o(ja_o), .pin_t(ja_t), .pin_i(ja)
  );

  // The eight pads. `pin_t` is Xilinx's sense --- HIGH is not driven --- so
  // the group this board does not own is high-impedance and the far end has
  // it. Written as one continuous assignment a pad rather than eight `IOBUF`
  // primitives, because a tri-state assignment is what every tool infers a
  // buffer from and this file is meant to read as SystemVerilog.
  for (genvar i = 0; i < 8; i = i + 1) begin : g_ja
    assign ja[i] = ja_t[i] ? 1'bz : ja_o[i];
  end

  // Two debuggers at one DBGIN page, which MIT's board cannot have and this
  // one can. The near arm is the window and the far arm the connector, the
  // first to assert holds until it lifts, and a tie goes to the window ---
  // `rtl/plumbing/cadr_dbg_join.sv` has the argument. An unplugged connector
  // presents zeros, so with nothing in JA this is the window's cable
  // unchanged.
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
  // `DDR` puts the Zynq processing system behind the machine's memory port:
  // `cadr_axi_master.sv` turning a request into a transaction, the generated
  // `cadr_ps7.sv` carrying it to `S_AXI_HP0`, and `cadr_axi_widen.sv` between
  // them.
  // **This is the piece with no muir reference at all** --- nothing in MIT's
  // drawings is an AXI master --- so what holds it is the protocol, the
  // read-back, and eventually the board.
  //
  // THE PORT IS DEAD UNTIL SOFTWARE SAYS OTHERWISE, and that is what lets
  // this work with nobody at the board. `ps7_post_config` writes
  // `LVL_SHFTR_EN` and clears `FPGA_RST_CTRL`; until it has, the PS-PL level
  // shifters are off and `S_AXI_HP0` answers nothing at all. `hp0_aresetn` is
  // the PS7 output that says the port is live, and the adapter is held in
  // reset by it --- so before Linux is up the machine hangs on its first
  // memory cycle, which is exactly what it does with `DDR` off, and after
  // Linux is up it does not. Nobody has to arm anything.
  //
  // THE FABRIC CLOCK STAYS ON THE PIN. `hp0_aclk` is a PS7 *input* and takes
  // the MMCM's 100 MHz: the fabric clocks the port rather than the other way
  // round. Driving the fabric from `FCLK_CLK0` is the obvious move now that
  // the PS is in the design and it is wrong --- programming a `.bit` over
  // JTAG does not start the PS, so the board would be dark until somebody
  // booted it, and nothing in this slice needs FCLK.
  //
  // ONE WORD A TRANSACTION, IN A FULL-WIDTH BEAT. `cadr_axi_master` speaks 32
  // bits and `S_AXI_HP0` is used at its native 64; the beat is the port's
  // full width, with the byte strobes choosing which half of it the word
  // belongs in and a lane select on the way back. That conversion is
  // `rtl/plumbing/cadr_axi_widen.sv` and its header is the argument for all of it ---
  // including why it is a module: this file cannot be simulated, so anything
  // written here is held by lint and the fitter and nothing else, and a lane
  // selected from the wrong channel is neither a lint error nor a fitter
  // one.
  if (PORT != 0) begin : g_ddr

    // The port's reset, out of the PS at whatever moment software runs
    // post-config, and asynchronous to this clock by construction --- so it
    // is synchronized in, the same way `mmcm_locked` is.
    logic       hp0_aresetn;
    logic [2:0] port_rst_sync;
    always_ff @(posedge clk) begin
      port_rst_sync <= {port_rst_sync[1:0], hp0_aresetn};
    end

    // **THE ADAPTER TAKES THE PORT'S RESET AND NOT BTN1.**  `S_AXI_HP0` is
    // reset only by the processing system, so a read it has taken it will
    // answer and a write whose address it has taken it will wait for the data
    // of.  An adapter reset by BTN1 dropped its valids and left the answer in
    // the port, where the machine's next read took it as its own.  Not
    // resetting it is the argument the note at `mach_rst` already makes for
    // the console's reset: the machine drops `mem_req` in reset, the adapter
    // finishes the transaction in hand and goes back to IDLE from DONE, and
    // the machine's first memory cycle after a reset is PAGE-0-PARITY-FIX,
    // 118 ms later.  `tb/cadr_board_reset_tb.cpp` holds a read and a write
    // across the button.  The witness of a `PROVE` board is not an AXI master
    // and keeps BTN1, as it did.
    logic axi_rst;
    assign axi_rst = !port_rst_sync[2];

    // WHAT THE ADAPTER IS ASKED FOR, which is the machine's request on the
    // board this file exists to build and the witness's on a `PROVE` one.
    // Named apart from `mem_*` deliberately: `mem_*` is what `cadr_machine`
    // brings out and it keeps meaning that in every configuration, including
    // the one where nothing downstream is listening to it.
    logic        port_req, port_write;
    logic [31:0] port_addr, port_wdata;
    logic        port_done, port_error;
    logic [31:0] port_rdata;

    // The adapter's AXI4 side, 32 bits wide.
    logic [31:0] awaddr, araddr, wdata;
    logic [7:0]  awlen, arlen;
    logic [2:0]  awsize, arsize;
    logic [1:0]  awburst, arburst, bresp, rresp;
    logic [3:0]  wstrb;
    logic        awvalid, awready, wvalid, wready, wlast;
    logic        bvalid, bready, arvalid, arready, rvalid, rready, rlast;
    logic [31:0] rdata;

    // The port's side, 64 bits wide.
    logic [31:0] hp0_awaddr, hp0_araddr;
    logic [3:0]  hp0_awlen, hp0_arlen;
    logic [1:0]  hp0_awsize, hp0_arsize;
    logic [63:0] hp0_wdata, hp0_rdata;
    logic [7:0]  hp0_wstrb;

    // ------------------------------------------------- who drives the port
    //
    // THE MACHINE, or the witness that goes ahead of it. `rtl/plumbing/cadr_prove.sv`
    // has the argument for the two steps; what belongs here is only that it
    // drives `mem_*`'s own wires into the same adapter, the same widening and
    // the same PS7 that the machine will drive --- a witness with a path of
    // its own would prove that path and say nothing about this one.
    if (PROVE == 0) begin : g_machine_drives

      assign port_req   = mem_req;
      assign port_write = mem_write;
      assign port_addr  = mem_addr;
      assign port_wdata = mem_wdata;
      assign mem_done   = port_done;
      assign mem_rdata  = port_rdata;

    end else begin : g_prove

      // A LEVEL, AND WHAT HOLDS IT UP DECIDES WHETHER ANYBODY HAS TO BE
      // HERE. `cadr_prove` runs one sequence per rise of `go` and needs it
      // to fall before another, so a `go` tied high is exactly one sequence
      // at the moment the port comes live --- which is both steps' whole
      // requirement: it must happen with nobody at the board, because the
      // board is on the end of a JTAG cable and the port comes live whenever
      // software says so.
      //
      // AND THE NEXT ONE IS A RESET AND NOT A FINGER. `SAXIHP0ARESETN`
      // follows `LVL_SHFTR_EN` at 0xF8000900 --- measured at 700b98a --- so
      // writing that register 0x0 then 0xF drops `axi_rst` and raises it,
      // the witness returns to IDLE and runs the whole sequence again. Step
      // three's first draft tied this to BTN1 and answered on LD4, which
      // needed somebody in the room for both halves; the write-back to
      // `PROVE_ECHO` and this re-arm are what took the person out.
      logic prove_go;
      assign prove_go = 1'b1;

      logic prove_has_run, prove_matched;

      cadr_prove u_prove (
          // The three constants the whole exercise is about, tied here
          // because this is the file that chose them.
          .addr  (PROVE_ADDR),
          .word  (PROVE_WORD),
          // Where a read puts what came back. A write board never reads it.
          .echo_addr(PROVE_ECHO),
          .writes(PROVE == 1),
          .clk(clk),
          // Held while the port is dead, so nothing goes out before
          // `SAXIHP0ARESETN` says `S_AXI_HP0` can answer it.
          .rst(rst || axi_rst),
          .go(prove_go),
          .mem_req(port_req), .mem_write(port_write),
          .mem_addr(port_addr), .mem_wdata(port_wdata),
          .mem_done(port_done), .mem_rdata(port_rdata),
          .mem_error(port_error),
          .has_run(prove_has_run), .matched(prove_matched)
      );

      // THE MACHINE GETS NOTHING, exactly as on the board with no memory at
      // all. It reaches its first main-memory cycle at microcycle 536,303,
      // the NXM timer ends it at about 4.25 us, and it carries on --- so
      // LD0, LD1, LD2, LD3 and LD5 read on a `PROVE` board exactly as
      // `docs/board.md` tabulates them for a board with no memory, and the
      // one lamp that changes is LD4.
      assign mem_done  = 1'b0;
      assign mem_rdata = 32'd0;

      // LD4 IS A LAMP HERE AND NO LONGER THE OBSERVER. Red until something
      // has completed, and it BLINKS while the port is still dead, because
      // "nobody has run ps7_post_config" and "the port swallowed the
      // transaction" are two different faults and a steady red would be
      // both of them. Green is the sequence that completed and was right;
      // blue is one that completed and was wrong --- a word that came back
      // different, or a SLVERR or DECERR on either transaction. Nothing
      // else can light it.
      //
      // WHAT SAYS WHETHER THE READ IS RIGHT IS `PROVE_ECHO` AND NOT THIS.
      // `matched` compares what came back against a constant this fabric
      // holds, so a witness that read the wrong lane and one that held the
      // wrong constant agree with each other and both light green. The
      // write-back puts the word itself where a debugger can read it, and
      // that is what `boards/arty-z7-20/vivado/prove_read.tcl` asserts. This lamp costs
      // nothing and is for whoever happens to be at the board.
      assign lamp4 = {!prove_has_run && (port_rst_sync[2] || tick[24]),
                      prove_has_run &&  prove_matched,
                      prove_has_run && !prove_matched};

    end

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

    // The widening: `rtl/plumbing/cadr_axi_widen.sv`, and it is a module rather than
    // the six assignments it used to be here because this file cannot be
    // simulated and a module can. Its header has the whole of the conversion;
    // what belongs here is only that the payload goes through it and every
    // handshake does not.
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

    // ------------------------------------------------ the port's own tally
    //
    // WHAT THE MACHINE ASKED FOR AND WHAT THE PROCESSING SYSTEM ANSWERED,
    // carried out of the design on EMIO GPIO so a debugger can read it with
    // nobody at the board.  `rtl/plumbing/cadr_mem_count.sv`'s header is the whole
    // argument; what belongs here is only where the numbers go.
    //
    // **THE BOOT PROM LEAVES NO OTHER TRACE.**  Its only main-memory traffic
    // is an identity copy of page 0, so page 0 reading back unchanged says
    // the path did no harm and cannot tell a machine that ran from one whose
    // port was dead --- which times out all 512 cycles and leaves page 0
    // exactly as unchanged.  Nor can any lamp: memory removes exactly 512
    // timeouts out of the boot PROM's 17,466 bus cycles, the other 16,951
    // being disk polls that end on the timer either way, so the lamps read
    // the same with DDR and without.  That was measured when LD2 carried a
    // count of those timeouts, and is why it no longer does.
    // This is the positive witness, and it is four counters because
    // the processing system ships nothing that can see `S_AXI_HP0` traffic
    // --- the DDR controller has no performance monitors, and Xilinx's own
    // performance tooling puts a counter IP in the fabric for this reason.
    //
    // WHERE THE DEBUGGER READS IT.  `DATA_2_RO` at 0xE000A068 carries EMIO
    // 31:0 and `DATA_3_RO` at 0xE000A06C carries EMIO 63:32; both report the
    // pin whatever the direction registers say, `DIRM` comes up input, and
    // `ps7_init` has already turned the GPIO clock on --- bit 22 of the
    // 0x01DC044D it writes to APER_CLK_CTRL. So nothing has to be configured
    // for the tally to be readable, which is what makes it a witness that
    // needs nobody at the board.
    //
    // **THE LAYOUT IS THE MODULE'S AND NOT THIS FILE'S**, marker bits and
    // all. It used to be four counters packed here, which put a bit offset
    // in the one file nothing can simulate; its header has the table and
    // `tb/cadr_mem_count_tb.cpp` reads the same sixty-four bits back.
    //
    // AND IT IS CLEARED BY `rst` AND NOT BY `axi_rst`.  A tally the port's
    // reset cleared would erase itself the moment anybody wrote LVL_SHFTR_EN,
    // and would read "nothing was asked" on a dead port --- which is the one
    // reading that has to mean something else.
    logic [63:0] gpio_i;

    // The request a tick behind, for the counter alone: `mem_req` is the bus
    // interface's tick counter through the bridge's gate, and into the
    // tally's enables across the board it was -1.4 ns.  The tally counts
    // rises, so a copy one tick late counts the same rises one tick late,
    // and a debugger reads it two hundred milliseconds on.
    // The PS7's handshakes the same: its outputs leave the hard block late
    // in the tick, and the tally counts a handshake --- valid and ready
    // together --- so both halves of each are copied on the same edge and
    // the count is the same count.
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
        .gpio(gpio_i)
    );

    // AND THE SAME TWO HANDSHAKES INTO THE MACHINE'S OWN AUDIT, off the same
    // registered copies so that the tally on EMIO and the record in the
    // console's window cannot disagree about what the port did.
    //
    // **NOT ON A `PROVE` BOARD.** There the witness owns the port and the
    // machine's `mem_done` is tied low, so every transaction the port answers
    // is the witness's and none of them is the machine's: fed in, they would
    // read as the port answering what the machine never asked, which is
    // exactly the fault this clause exists to name. The whole point of a
    // `PROVE` board is that the machine is not driving the port, and the audit
    // is told so by being given nothing.
    assign port_read_ack  = (PROVE == 0) && count_rvalid && count_rready &&
                            count_rlast;
    assign port_write_ack = (PROVE == 0) && count_bvalid && count_bready;

    // ------------------------------------------------------ the pack side
    //
    // `rtl/plumbing/cadr_disk_pack.sv`: the block's address and the drive's presence,
    // registers Linux writes over `M_AXI_GP0`, and the master on `S_AXI_HP2`
    // that fetches a block from the pack in DDR into the controller's store
    // and writes one back. Its header has the record, the registers and the
    // interlock; what belongs here is only the wiring and the reset.
    //
    // **ONLY WITH `DDR` SET, NOT ON A `PROVE` BOARD.** The two proving boards
    // were passed on silicon at `51bc74a` and are about the memory port; the
    // disk's ports have no place in them, so on those the PS7's HP2 and GP0
    // pins are tied here and the drive seam is tied off as on the default
    // board.
    //
    // THE RESET IS BOTH PORTS' AND THE MACHINE'S. `MAXIGP0ARESETN` and
    // `SAXIHP2ARESETN` are the PS saying each port is live, and until Linux
    // is up neither is: held in reset, the pack side's registers read zero,
    // so `drive_present` is zero and the CADR sees an empty cable exactly as
    // it does with `DDR` off. Synchronized in as `hp0_aresetn` is.
    logic        hp2_aresetn, gp0_aresetn;
    logic [31:0] hp2_awaddr, hp2_araddr;
    logic [3:0]  hp2_awlen, hp2_arlen;
    logic [1:0]  hp2_awsize, hp2_arsize, hp2_awburst, hp2_arburst;
    logic        hp2_awvalid, hp2_awready, hp2_wlast, hp2_wvalid, hp2_wready;
    logic        hp2_bvalid, hp2_bready, hp2_arvalid, hp2_arready;
    logic        hp2_rlast, hp2_rvalid, hp2_rready;
    logic [63:0] hp2_wdata, hp2_rdata;
    logic [7:0]  hp2_wstrb;
    logic [1:0]  hp2_bresp, hp2_rresp;
    logic [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
    logic [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb;
    logic [11:0] gp0_awid, gp0_arid, gp0_bid, gp0_rid;
    logic        gp0_awvalid, gp0_awready, gp0_wlast, gp0_wvalid, gp0_wready;
    logic        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
    logic        gp0_rlast, gp0_rvalid, gp0_rready;
    logic [1:0]  gp0_bresp, gp0_rresp;
    // `M_AXI_GP1`, the console's own port.  A second `M_AXI_GP` and not a
    // share of GP0's window, because the slave that owns a GP port must
    // answer the WHOLE of it --- a read nothing answers hangs both Arm cores
    // at one PC each, measured --- and GP0 is already answered end to end,
    // by `rtl/plumbing/cadr_gp0_split.sv` and the four slaves behind it.
    // (A fifth page would take the console too, and `docs/debug-cable.md`
    // is where that decision is written down.)  `0x8000_0000` to
    // `0xBFFF_FFFF` is its window, which Vivado states itself in
    // `data/ip/xilinx/processing_system7_v5_5/bd/bd.tcl` at lines 125 and 135.
    logic        gp1_aresetn;
    logic [31:0] gp1_awaddr, gp1_araddr, gp1_wdata, gp1_rdata;
    logic [3:0]  gp1_awlen, gp1_arlen, gp1_wstrb;
    logic [11:0] gp1_awid, gp1_arid, gp1_bid, gp1_rid;
    logic        gp1_awvalid, gp1_awready, gp1_wlast, gp1_wvalid, gp1_wready;
    logic        gp1_bvalid, gp1_bready, gp1_arvalid, gp1_arready;
    logic        gp1_rlast, gp1_rvalid, gp1_rready;
    logic [1:0]  gp1_bresp, gp1_rresp;
    // ---------------------------------------- and what GP1 is split three ways
    //
    // `rtl/plumbing/cadr_gp1_split.sv` decodes the port into two 4 KB pages
    // and a third port for the rest of the gigabyte.  **THE THIRD PORT IS
    // WHAT KEEPS THE RULE**: a read nothing answers on a general-purpose port
    // does not fault the Arm, it hangs both cores at one PC each, measured on
    // this board, so every address in the window reaches a slave that
    // completes it.  Before the split the console answered the whole
    // gigabyte by itself; now it answers `0x8000_0000`, the debug cable's
    // carrier answers `0x8000_1000`, and `cadr_gp0_default.sv` answers the
    // other 262,142 pages.
    //
    // The console keeps its own `REG_BASE` default, so `cadr-console` does
    // not move and `build/console.pass` is unchanged.  muir is told
    // `--debug-cable-connect 0x80001000`.
    //
    // **THE DEFAULT SLAVE IS `cadr_gp0_default.sv` AND ITS NAME SAYS GP0.**
    // It is a whole-port slave with no address on it at all --- every read
    // gives `WORD` and OKAY, every write completes and is dropped --- so it
    // is the same thing on either port and a second copy would be two
    // descriptions of one thing.  The name is the port it was written for;
    // renaming it moves that port's check, its Makefile lists and two
    // mutation records, which is a change worth making on its own and not
    // inside this one.
    logic [31:0] gp1c_awaddr, gp1c_araddr, gp1c_wdata, gp1c_rdata;
    logic [3:0]  gp1c_awlen, gp1c_arlen, gp1c_wstrb;
    logic [11:0] gp1c_awid, gp1c_arid, gp1c_bid, gp1c_rid;
    logic        gp1c_awvalid, gp1c_awready, gp1c_wlast, gp1c_wvalid, gp1c_wready;
    logic        gp1c_bvalid, gp1c_bready, gp1c_arvalid, gp1c_arready;
    logic        gp1c_rlast, gp1c_rvalid, gp1c_rready;
    logic [1:0]  gp1c_bresp, gp1c_rresp;
    logic [31:0] gp1d_awaddr, gp1d_araddr, gp1d_wdata, gp1d_rdata;
    logic [3:0]  gp1d_awlen, gp1d_arlen, gp1d_wstrb;
    logic [11:0] gp1d_awid, gp1d_arid, gp1d_bid, gp1d_rid;
    logic        gp1d_awvalid, gp1d_awready, gp1d_wlast, gp1d_wvalid, gp1d_wready;
    logic        gp1d_bvalid, gp1d_bready, gp1d_arvalid, gp1d_arready;
    logic        gp1d_rlast, gp1d_rvalid, gp1d_rready;
    logic [1:0]  gp1d_bresp, gp1d_rresp;
    logic [31:0] gp1x_rdata;
    logic [3:0]  gp1x_arlen;
    logic [11:0] gp1x_awid, gp1x_arid, gp1x_bid, gp1x_rid;
    logic        gp1x_awvalid, gp1x_awready, gp1x_wlast, gp1x_wvalid, gp1x_wready;
    logic        gp1x_bvalid, gp1x_bready, gp1x_arvalid, gp1x_arready;
    logic        gp1x_rlast, gp1x_rvalid, gp1x_rready;
    logic [1:0]  gp1x_bresp, gp1x_rresp;
    // The disk's interrupt into the processing system, `IRQ_F2P` bit 0:
    // the pack side's, or nothing on a board without one.
    logic        pack_irq;

    // ------------------------------------------- what GP0 is split four ways
    //
    // `rtl/plumbing/cadr_gp0_split.sv` decodes the port into three 4 KB
    // pages and a fourth port for the rest of the gigabyte.  **THE FOURTH
    // PORT IS WHAT KEEPS THE RULE**: a read nothing answers on GP0 does not
    // fault the Arm, it hangs both cores at one PC each, measured on this
    // board, so every address in the window reaches a slave that completes
    // it.  The pack side keeps `0x4000_0000` --- its own `REG_BASE` default,
    // so the disk pack program does not move --- and the two new faces take
    // the pages `chaos_face.h` and `serial_face.h` already assume.
    logic [31:0] gp0p_awaddr, gp0p_araddr, gp0p_wdata, gp0p_rdata;
    logic [3:0]  gp0p_awlen, gp0p_arlen, gp0p_wstrb;
    logic [11:0] gp0p_awid, gp0p_arid, gp0p_bid, gp0p_rid;
    logic        gp0p_awvalid, gp0p_awready, gp0p_wlast, gp0p_wvalid, gp0p_wready;
    logic        gp0p_bvalid, gp0p_bready, gp0p_arvalid, gp0p_arready;
    logic        gp0p_rlast, gp0p_rvalid, gp0p_rready;
    logic [1:0]  gp0p_bresp, gp0p_rresp;
    logic [11:0] gp0c_awaddr, gp0c_araddr;
    logic [31:0] gp0c_wdata, gp0c_rdata;
    logic [3:0]  gp0c_awlen, gp0c_arlen, gp0c_wstrb;
    logic [11:0] gp0c_awid, gp0c_arid, gp0c_bid, gp0c_rid;
    logic        gp0c_awvalid, gp0c_awready, gp0c_wlast, gp0c_wvalid, gp0c_wready;
    logic        gp0c_bvalid, gp0c_bready, gp0c_arvalid, gp0c_arready;
    logic        gp0c_rlast, gp0c_rvalid, gp0c_rready;
    logic [1:0]  gp0c_bresp, gp0c_rresp;
    logic [11:0] gp0s_awaddr, gp0s_araddr;
    logic [31:0] gp0s_wdata, gp0s_rdata;
    logic [3:0]  gp0s_awlen, gp0s_arlen, gp0s_wstrb;
    logic [11:0] gp0s_awid, gp0s_arid, gp0s_bid, gp0s_rid;
    logic        gp0s_awvalid, gp0s_awready, gp0s_wlast, gp0s_wvalid, gp0s_wready;
    logic        gp0s_bvalid, gp0s_bready, gp0s_arvalid, gp0s_arready;
    logic        gp0s_rlast, gp0s_rvalid, gp0s_rready;
    logic [1:0]  gp0s_bresp, gp0s_rresp;
    logic [11:0] gp0i_awaddr, gp0i_araddr;
    logic [31:0] gp0i_wdata, gp0i_rdata;
    logic [3:0]  gp0i_awlen, gp0i_arlen, gp0i_wstrb;
    logic [11:0] gp0i_awid, gp0i_arid, gp0i_bid, gp0i_rid;
    logic        gp0i_awvalid, gp0i_awready, gp0i_wlast, gp0i_wvalid, gp0i_wready;
    logic        gp0i_bvalid, gp0i_bready, gp0i_arvalid, gp0i_arready;
    logic        gp0i_rlast, gp0i_rvalid, gp0i_rready;
    logic [1:0]  gp0i_bresp, gp0i_rresp;
    logic [31:0] gp0d_rdata;
    logic [3:0]  gp0d_arlen;
    logic [11:0] gp0d_awid, gp0d_arid, gp0d_bid, gp0d_rid;
    logic        gp0d_awvalid, gp0d_awready, gp0d_wlast, gp0d_wvalid, gp0d_wready;
    logic        gp0d_bvalid, gp0d_bready, gp0d_arvalid, gp0d_arready;
    logic        gp0d_rlast, gp0d_rvalid, gp0d_rready;
    logic [1:0]  gp0d_bresp, gp0d_rresp;
    // The two cables' interrupts into the processing system.
    logic        chaos_irq, ser_irq;

    if (DDR != 0) begin : g_pack

      logic [2:0] pack_rst_sync;
      // A register, not a gate: the pack side has some three hundred
      // registers to reset, and made as a gate the synchronizer was on every
      // one of their reset pins across the distance between the two.  One
      // tick later on a reset the PS releases at a moment of software's
      // choosing, which nothing counts.
      //
      // **THE PORT'S RESET ONLY, AND THE FABRIC'S GOES IN AT `fabric_rst`.**
      // The face's AXI state machines take `pack_rst` and nothing else, so a
      // register read the processor has started is answered whether BTN1
      // comes before it, during it or across it; the registers and the
      // master take BTN1 as well, the master once its burst on `S_AXI_HP2`
      // has ended.  `rtl/plumbing/cadr_disk_pack.sv` has both halves.
      logic pack_rst;
      always_ff @(posedge clk) begin
        pack_rst_sync <= {pack_rst_sync[1:0], hp2_aresetn && gp0_aresetn};
        pack_rst      <= !pack_rst_sync[2];
      end

      // `port_live` is the memory port's own liveness, which here is the half
      // of `pack_rst` the processing system drives: `SAXIHP2ARESETN` and
      // `MAXIGP0ARESETN` come and go together, so this level is high whenever
      // the face is out of reset and no command can be written while it is
      // low.  On a board where the two are NOT the same level, the face takes
      // the bridge's reset alone and this level does the rest, which
      // `rtl/plumbing/cadr_disk_pack.sv`'s header sets out.
      cadr_disk_pack u_pack (
          .clk(clk), .rst(pack_rst), .fabric_rst(rst),
          .port_live(pack_rst_sync[2]),
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

    end else begin : g_nopack

      // A `PROVE` board: no drive, no pack, the PS7's HP2 pins quiet ---
      // **AND GP0 ANSWERED ALL THE SAME.**  A read nothing answers on GP0
      // hangs both Arm cores at one PC each, measured on the board when the
      // pack feeder read the register face on a bitstream without the pack
      // side; so every board that brings the port out answers every address
      // on it.  `rtl/plumbing/cadr_gp0_default.sv` answers "NONE" to every read and
      // OKAY to every write, and its own check holds that it answers.
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
      assign pack_irq = 1'b0;
      assign hp2_awaddr = 32'd0;
      assign hp2_awlen = 4'd0;
      assign hp2_awsize = 2'd0;
      assign hp2_awburst = 2'd0;
      assign hp2_awvalid = 1'b0;
      assign hp2_wdata = 64'd0;
      assign hp2_wstrb = 8'd0;
      assign hp2_wlast = 1'b0;
      assign hp2_wvalid = 1'b0;
      assign hp2_bready = 1'b0;
      assign hp2_araddr = 32'd0;
      assign hp2_arlen = 4'd0;
      assign hp2_arsize = 2'd0;
      assign hp2_arburst = 2'd0;
      assign hp2_arvalid = 1'b0;
      assign hp2_rready = 1'b0;

      // The splitter's first page, which is the pack side's on every other
      // board, still has to be answered: a read nothing answers there hangs
      // both Arm cores at one PC each and there is no software guard for it.
      // `gp0_rst_s` is the port's own reset synchronized, made once in the
      // enclosing scope where the splitter and the other three slaves take
      // it --- a second one here would shadow the name.
      cadr_gp0_default u_gp0_default (
          .clk(clk), .rst(gp0_rst_s),
          .s_awvalid(gp0p_awvalid), .s_awid(gp0p_awid), .s_awready(gp0p_awready),
          .s_wlast(gp0p_wlast), .s_wvalid(gp0p_wvalid), .s_wready(gp0p_wready),
          .s_bresp(gp0p_bresp), .s_bid(gp0p_bid), .s_bvalid(gp0p_bvalid),
          .s_bready(gp0p_bready),
          .s_arlen(gp0p_arlen), .s_arid(gp0p_arid), .s_arvalid(gp0p_arvalid),
          .s_arready(gp0p_arready),
          .s_rdata(gp0p_rdata), .s_rresp(gp0p_rresp), .s_rid(gp0p_rid),
          .s_rlast(gp0p_rlast), .s_rvalid(gp0p_rvalid), .s_rready(gp0p_rready)
      );

      // Read here, so that a board without the pack side leaves nothing of
      // the PS7's disk pins unread: the address, length, data and strobes
      // the splitter hands the first page, which the default slave answers
      // without looking at.
      logic unused_pack;
      assign unused_pack = ^{hp2_aresetn, hp2_awready,
                             hp2_wready, hp2_bresp, hp2_bvalid, hp2_arready,
                             hp2_rdata, hp2_rresp, hp2_rlast, hp2_rvalid,
                             gp0p_awaddr, gp0p_awlen, gp0p_wdata, gp0p_wstrb,
                             gp0p_araddr, store_rdata, store_miss, ch_active};

    end

    // ------------------------------------------- the splitter and two cables
    //
    // Outside `g_pack` for the reason the console is: every board with a PS7
    // has a GP0 to answer and an I/O board whose two cables have far ends.
    // On a `PROVE` board the first page is the default slave (see
    // `g_nopack`); the other three are the same here as on the disk board.
    //
    // **THIS BLOCK AND THE TIE-OFFS ABOVE GOING ARE ONE CHANGE**, because a
    // seam with two drivers does not elaborate and a seam with none is a
    // cable that is never plugged in.  `build/gp0_split.pass` is what holds
    // the arrangement; `build/arty.pass` holds the wiring, and an
    // unconnected port here is a PINMISSING on the passes that elaborate it
    // --- which is the only thing standing between "the default port is
    // connected" and the frozen cores.
    //
    // Reset by the port's own reset, synchronized, as the pack side and the
    // console are: before Linux is up the faces read zero, so the serial
    // port's `CTL` is zero and its cable is out, and the Chaosnet's address
    // switches read zero --- which is exactly what the tie-off did.
    //
    // **AND BY NOTHING ELSE, BECAUSE A GENERAL-PURPOSE PORT'S TRANSACTION IS
    // THE PROCESSOR'S.**  `gp0_rst_s` was once `rst ||` the port's reset, so
    // BTN1 held the splitter and every face in their address states with
    // AWREADY and ARREADY high: an address taken then, or one in flight when
    // the button went down, was never answered, and both Arm cores hung.  So
    // the splitter and the default slave take the port's reset alone, and
    // the three faces take BTN1 at `fabric_rst`, which resets their registers
    // and never their AXI state.  `docs/board.md` has the rule, and
    // `tb/cadr_board_reset_tb.cpp` presses the button under reads and writes
    // on every page of both ports.
    logic [2:0] gp0_rst_sync;
    logic gp0_rst_s;
    always_ff @(posedge clk) begin
      gp0_rst_sync <= {gp0_rst_sync[1:0], gp0_aresetn};
      gp0_rst_s    <= !gp0_rst_sync[2];
    end

    cadr_gp0_split u_gp0_split (
        .clk(clk), .rst(gp0_rst_s),
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

    cadr_chaos_cable u_chaos (
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

    cadr_serial_line u_serial (
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

    // The keyboard's cable and the mouse's, which `cadr-terminal` drives
    // with what a viewer types and where it points.  **`mach_rst` AND NOT
    // `gp0_rst_s` FOR THE QUEUE'S FLUSH**, which is the whole reason that
    // port exists: the console can restart the CADR while Linux runs, and
    // the restarted microcode asks whether anybody is typing four
    // instructions in --- so a key queued before the restart would send it
    // down the warm-boot path.  The face's own reset stays the PORT's,
    // because resetting an AXI state machine mid-transaction is how
    // `con_mach_rst` would have frozen both Arm cores, which the note at
    // `mach_rst` above sets out at length.
    cadr_input_cables u_input (
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

    cadr_gp0_default u_gp0_rest (
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
    // The sixteen diagnostic registers on `M_AXI_GP1`, so that a program in
    // Linux can halt the machine, read its state and start it again.  It is
    // outside `g_pack` because every board with a PS7 has one: the console
    // is what says whether the machine is running, and a board that can only
    // be watched through its lamps cannot answer that.
    //
    // Reset by the port's own reset, synchronized, as the pack side is ---
    // and the machine is NOT reset with it: a console that reset the machine
    // when Linux came up would be a console that could never be attached to
    // a running machine, which is the only time it is wanted.  **And BTN1
    // reaches the console and the window only at `fabric_rst`**, their
    // registers and never their AXI state, for the reason `gp0_rst_s` gives.
    logic [2:0] gp1_rst_sync;
    logic gp1_rst;
    always_ff @(posedge clk) begin
      gp1_rst_sync <= {gp1_rst_sync[1:0], gp1_aresetn};
      gp1_rst      <= !gp1_rst_sync[2];
    end

    cadr_gp1_split u_gp1_split (
        .clk(clk), .rst(gp1_rst),
        .s_awaddr(gp1_awaddr), .s_awlen(gp1_awlen), .s_awid(gp1_awid),
        .s_awvalid(gp1_awvalid), .s_awready(gp1_awready),
        .s_wdata(gp1_wdata), .s_wstrb(gp1_wstrb), .s_wlast(gp1_wlast),
        .s_wvalid(gp1_wvalid), .s_wready(gp1_wready),
        .s_bresp(gp1_bresp), .s_bid(gp1_bid), .s_bvalid(gp1_bvalid),
        .s_bready(gp1_bready),
        .s_araddr(gp1_araddr), .s_arlen(gp1_arlen), .s_arid(gp1_arid),
        .s_arvalid(gp1_arvalid), .s_arready(gp1_arready),
        .s_rdata(gp1_rdata), .s_rresp(gp1_rresp), .s_rid(gp1_rid),
        .s_rlast(gp1_rlast), .s_rvalid(gp1_rvalid), .s_rready(gp1_rready),
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

    // -------------------------------------------- the debug cable's carrier
    //
    // `rtl/plumbing/cadr_debug_window.sv` is MIT's twenty-one wires as
    // sixteen words on the port, and the far end of them is
    // `rtl/machine/cadr_dbgin.sv` inside `cadr_machine`.  The debugger is
    // muir on this board's own Arm cores, reaching this through `/dev/mem`
    // with `--debug-cable-connect 0x80001000`.
    //
    // **IT TAKES THE PORT'S RESET AND NOT THE MACHINE'S**, for the reason
    // the console gives about its own: a carrier reset by the machine's
    // reset would abandon the request that asked for it, and the debugger
    // would be left waiting for an acknowledgment from a cable that had
    // forgotten the request.  Modifier bit 1 resets the machine and this is
    // deliberately outside that.
    //
    // `WATCHDOG_T` stays at the module's own one second here.  It is a floor
    // with margin and not derived from anything --- `docs/debug-cable.md`
    // has the argument --- and what it recovers is a wedged Unibus after
    // muir is killed with a request standing, not the machine, which an NXM
    // has already hit 4.25 us in.
    cadr_debug_window #(
        .REG_BASE(32'h8000_1000)
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

    cadr_gp0_default u_gp1_rest (
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

    // **WHICH BUILD THIS FABRIC IS**, page 2's word 32.  One primitive and one
    // wire: `tools/build_stamp.tcl` writes the commit and the tree's state
    // into `BITSTREAM.CONFIG.USR_ACCESS` before every `write_bitstream`, the
    // part loads it at configuration, and this reads it back from inside.
    // The same eight digits go into `BITSTREAM.CONFIG.USERID`, which JTAG's
    // USERCODE register holds --- so a board with a cable on it and a program
    // on the processing system are asking two registers loaded from one
    // value, over paths that share nothing.
    //
    // It is beside the console because the console is the only thing that
    // reads it; a board built without one has no reader and instantiates no
    // primitive.
    logic [31:0] con_build;
    cadr_usr_access u_usr_access (.build(con_build));

    // **WHETHER THE DISPLAY OUTPUT SLEEPS**, page 2's word 36.  The console
    // carries a setting and a wake to the display output below and reads back
    // what it holds; on a board built without the display there is nothing to
    // read, and `disp_sleep_fitted` low makes the word `UNMAPPED`.
    logic        con_hdmi_sleep_set, con_hdmi_wake;
    logic [14:0] con_hdmi_sleep_secs, disp_sleep_setting;
    logic        disp_asleep, disp_sleep_fitted;

    cadr_console u_console (
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
        // The backplane's display boards, page 2's word 33, and the two
        // color maps on pages 4 and 5.
        .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
        .tv_map_a(con_tv_map_a), .tv_map_q(con_tv_map_q),
        .tv_color_map_q(con_tv_color_map_q),
        // What the display output shows and which way up, page 2's word 34.
        .hdmi_out(con_hdmi_out), .hdmi_rotate(con_hdmi_rotate),
        // Whether LD1 and LD2 blink or hold a level, page 2's word 35:
        // `cadr-console blinking-leds` and `--no-blinking-leds`.
        .steady_lamps(con_steady_lamps),
        // Whether the display output sleeps, page 2's word 36: a setting and a
        // wake out to it, and what it holds back.
        .hdmi_sleep_set(con_hdmi_sleep_set), .hdmi_sleep_secs(con_hdmi_sleep_secs),
        .hdmi_wake(con_hdmi_wake), .hdmi_sleep_fitted(disp_sleep_fitted),
        .hdmi_sleep_q(disp_sleep_setting), .hdmi_asleep(disp_asleep),
        .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
        .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
        .clock_edge(clock_edge),
        // The virtual address register, `Q` and `MD`, page 0's words 7, 8
        // and 9.
        .mach_vma(con_vma), .mach_q(con_q), .mach_md(con_md),
        // **WHICH BUILD THIS FABRIC IS**, page 2's word 32, out of the
        // part's own AXSS register.
        .build(con_build),
        // The readout, page 0's words 10, 11 and 12.
        .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
        // The machine's reset, ORed with the board's own at the declaration
        // above.  **Not `gp1_rst` and not this instance's own `rst`**: see
        // the rule there and `rtl/plumbing/cadr_console.sv`'s header.
        .mach_rst(con_mach_rst),
        .mach_boot(con_mach_boot),
        // SW0, both halves of it: the value the machine actually came out of
        // reset with, and where the switch is now.  `cadr-console status`
        // prints both, and the init step that holds the machine at boot asks
        // the first of them.
        .no_auto_boot_held(sw0_held),
        .no_auto_boot_now(sw0_level),
        // **THE DEBUG CABLE'S ROLE**, page 0's word 14: `cadr-console
        // debug-cable-connect` and its opposite, and the four the connector
        // answers with. The cable itself is at the top level and not in here,
        // because a board is always a debuggee and a board with no processing
        // system still has a connector.
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

    // ================================================= the display output
    //
    // `rtl/plumbing/cadr_display_out.sv` reads the CADR's bitmap out of the
    // display's own region of DDR over `S_AXI_HP3` and puts it on a raster;
    // `rtl/plumbing/cadr_hdmi_tx.sv` encodes that as DVI; and
    // `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` makes the pixel clock and
    // serializes the four channels.  `docs/display-output.md` is the whole
    // design and the measurements behind it.
    //
    // THE PORT IS BROUGHT OUT WHETHER OR NOT THE DISPLAY IS BUILT, because
    // an exposed PS7 pin that nobody connects is a PINMISSING that stops
    // `build/arty.pass` and an unconnected PS7 INPUT is silent --- so the
    // read channels are driven and the write channels are tied off in both
    // arms below rather than left to the default board's luck.
    logic        hp3_aresetn;
    logic [31:0] hp3_awaddr, hp3_araddr;
    logic [3:0]  hp3_awlen, hp3_arlen;
    logic [1:0]  hp3_awsize, hp3_arsize, hp3_awburst, hp3_arburst;
    logic [63:0] hp3_wdata, hp3_rdata;
    logic [7:0]  hp3_wstrb;
    logic        hp3_awvalid, hp3_awready, hp3_wvalid, hp3_wready, hp3_wlast;
    logic [1:0]  hp3_bresp, hp3_rresp;
    logic        hp3_bvalid, hp3_bready, hp3_arvalid, hp3_arready;
    logic        hp3_rvalid, hp3_rready, hp3_rlast;

    // Nothing here ever writes memory: the display reads the bitmap and the
    // machine owns it.  The write channels are tied off in one place for
    // both arms so that a reader does not have to check two.
    assign hp3_awaddr  = 32'd0;
    assign hp3_awlen   = 4'd0;
    assign hp3_awsize  = 2'b11;
    assign hp3_awburst = 2'b01;
    assign hp3_awvalid = 1'b0;
    assign hp3_wdata   = 64'd0;
    assign hp3_wstrb   = 8'd0;
    assign hp3_wlast   = 1'b0;
    assign hp3_wvalid  = 1'b0;
    assign hp3_bready  = 1'b1;

    // And nothing reads what the write channels answer, because nothing
    // ever writes.  Folded here beside the tie-off rather than in either
    // arm below, since it is true of both: a signal nobody reads is a
    // signal lint reports, and the honest answer is to say once that this
    // half of the port is not used.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_hp3_write;
    assign unused_hp3_write = ^{hp3_awready, hp3_wready, hp3_bresp, hp3_bvalid};
    /* verilator lint_on UNUSEDSIGNAL */

    if (HDMI != 0) begin : g_hdmi

      // The port's own reset, synchronized as HP0's and HP2's are, and
      // nothing else: BTN1 reaches the display at `fabric_rst`, which resets
      // its sleep setting at once and its fetch once the reads it has out on
      // `S_AXI_HP3` are answered.  `rtl/plumbing/cadr_display_out.sv` has it.
      logic [2:0] disp_rst_sync;
      logic       disp_rst;
      always_ff @(posedge clk) begin
        disp_rst_sync <= {disp_rst_sync[1:0], hp3_aresetn};
        disp_rst      <= !disp_rst_sync[2];
      end

      logic pclk, prst;
      logic disp_de, disp_hsync, disp_vsync, disp_mute, disp_sleep_due;
      logic [7:0] disp_red, disp_green, disp_blue;
      logic disp_underrun, disp_rd_error;
      logic [9:0] tmds0, tmds1, tmds2, tmds_clk;
      logic [3:0] ser;

      cadr_display_out #(
          .BASE(cadr_ddr_map::DISPLAY_BASE),
          .COLOR_BASE(cadr_ddr_map::COLOR_DISPLAY_BASE),
          // QUUX shows MONO TV, 1280 by 1024 at 40 words a line, filling the
          // raster; the CADR its first board's 768 by 963 at 24.
          .PIC_W         (MACHINE == "quux" ? 1280 : 768),
          .PIC_H         (MACHINE == "quux" ? 1024 : 963),
          .WORDS_PER_LINE(MACHINE == "quux" ? 40 : 24)
      ) u_display (
          .clk(clk), .rst(disp_rst), .fabric_rst(rst),
          .m_araddr(hp3_araddr), .m_arlen(hp3_arlen), .m_arsize(hp3_arsize),
          .m_arburst(hp3_arburst), .m_arvalid(hp3_arvalid),
          .m_arready(hp3_arready),
          .m_rdata(hp3_rdata), .m_rresp(hp3_rresp), .m_rlast(hp3_rlast),
          .m_rvalid(hp3_rvalid), .m_rready(hp3_rready),
          // What is shown and which way up, out of the console face.
          .out_sel(con_hdmi_out), .rotate(con_hdmi_rotate),
          // Whether it sleeps: a setting and a wake out of the console face,
          // one of them from `cadr-terminal` for a key or the mouse at the
          // board, and what it holds going back.
          .sleep_set(con_hdmi_sleep_set), .sleep_secs(con_hdmi_sleep_secs),
          .wake(con_hdmi_wake), .sleep_setting(disp_sleep_setting),
          .sleep_due(disp_sleep_due), .asleep(disp_asleep),
          .pclk(pclk), .prst(prst),
          // The color board's map, an entry a raster line.
          .map_a(disp_map_a), .map_q(con_disp_color_map_q),
          .mute(disp_mute),
          .de(disp_de), .hsync(disp_hsync), .vsync(disp_vsync),
          .red(disp_red), .green(disp_green), .blue(disp_blue),
          .underrun(disp_underrun), .rd_error(disp_rd_error)
      );
      assign disp_sleep_fitted = 1'b1;

      // **THE THREE CHANNELS COME OUT OF THE DISPLAY NOW AND ARE NOT MADE
      // HERE.**  They were one bit spread over three bytes while the block drew
      // one black-and-white screen; the color board's pixels are map entries of
      // three different bytes, so the lookup is the display's and what arrives
      // here is already a color.
      cadr_hdmi_tx u_tx (
          .pclk(pclk), .prst(prst),
          .red(disp_red), .green(disp_green), .blue(disp_blue),
          .de(disp_de), .hsync(disp_hsync), .vsync(disp_vsync),
          // Asleep, the four lanes held at one level: a monitor with no
          // signal, which is the only way a digital link sleeps one.
          .mute(disp_mute),
          .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2), .tmds_clk(tmds_clk)
      );

      // The mode's own clock arithmetic: 125 MHz times 8.625 is a VCO of
      // 1078.125 MHz, which halves to the 539.0625 MHz serial clock and
      // tenths to the 107.8125 MHz pixel clock.  `docs/display-output.md`
      // says why no multiple of an eighth gives 108 exactly and why 0.17
      // per cent low does not matter.
      // **THE PARAMETER NAMES ARE NOT THE PRIMITIVE'S, AND THAT IS WHY.**
      // `boards/arty-z7-20/vivado/tick.tcl` reads the machine's tick by
      // counting `DIVCLK_DIVIDE` and `CLKFBOUT_MULT_F` in THIS file and
      // stops the whole flow if it finds either twice.  The display's MMCM
      // is in `cadr_hdmi_phy.sv`, but an override written here with the
      // primitive's own names puts the text in this file and the flow dies
      // saying the tick is ambiguous --- which it did, at the first
      // bitstream.  `VCO_DIVIDE` and `VCO_MULT_F` say the same thing and
      // cannot collide.
      cadr_hdmi_phy #(
          .CLKIN_PERIOD_NS(8.000),
          .VCO_DIVIDE     (HM_VCO_DIV),
          .VCO_MULT_F     (HM_VCO_MULT),
          .SERIAL_DIVIDE_F(2.000),
          .PIXEL_DIVIDE   (10)
      ) u_phy (
          .sysclk(sysclk), .pclk(pclk), .prst(prst),
          .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2), .tmds_clk(tmds_clk),
          .ser(ser)
      );

      assign hdmi_ser = ser;

      // The two sticky reports are not on any path and nothing reads them.
      // They go into the fold for the reason every other output of the
      // machine does: a signal with no consumer is a signal synthesis is
      // free to delete, and then the register that made it is gone and the
      // check on the board would be measuring a different design.
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_disp;
      // The timer's verdict too, which the mute is already made of: the console
      // reads whether the lanes ARE muted, and that is `disp_asleep`.
      assign unused_disp = ^{disp_underrun, disp_rd_error, disp_sleep_due};
      /* verilator lint_on UNUSEDSIGNAL */

    end else begin : g_no_hdmi

      // No display: the port is brought out and answered with nothing, and
      // the connector is held at a level.
      assign hp3_araddr  = 32'd0;
      assign hp3_arlen   = 4'd0;
      assign hp3_arsize  = 2'b11;
      assign hp3_arburst = 2'b01;
      assign hp3_arvalid = 1'b0;
      assign hp3_rready  = 1'b1;
      assign hdmi_ser    = 4'd0;
      // No display output: nothing reads the color board's second map port and
      // nothing shows the two settings.  The console still answers word 34 with
      // what it would show, which is what a console is for.
      assign disp_map_a  = 4'd0;
      // And no display output to sleep: the console's word 36 reads `UNMAPPED`,
      // and what it would carry goes nowhere.
      assign disp_sleep_fitted  = 1'b0;
      assign disp_sleep_setting = 15'd0;
      assign disp_asleep        = 1'b0;

      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_hp3;
      assign unused_hp3 = ^{hp3_aresetn, hp3_arready, hp3_rdata, hp3_rresp,
                            hp3_rlast, hp3_rvalid,
                            con_hdmi_sleep_set, con_hdmi_sleep_secs, con_hdmi_wake};
      /* verilator lint_on UNUSEDSIGNAL */

    end

    cadr_ps7 u_ps7 (
        .hp0_aclk(clk),
        .gpio_i(gpio_i),
        .hp0_aresetn(hp0_aresetn),
        .hp0_awaddr(hp0_awaddr),
        // AXI3 at the port: four bits of length, two of size. One beat, and
        // the beat is the port's whole width.
        .hp0_awlen(hp0_awlen),
        .hp0_awsize(hp0_awsize),
        .hp0_awburst(awburst),
        .hp0_awvalid(awvalid), .hp0_awready(awready),
        .hp0_wdata(hp0_wdata), .hp0_wstrb(hp0_wstrb),
        .hp0_wlast(wlast), .hp0_wvalid(wvalid), .hp0_wready(wready),
        .hp0_bresp(bresp), .hp0_bvalid(bvalid), .hp0_bready(bready),
        .hp0_araddr(hp0_araddr),
        .hp0_arlen(hp0_arlen),
        .hp0_arsize(hp0_arsize),
        .hp0_arburst(arburst),
        .hp0_arvalid(arvalid), .hp0_arready(arready),
        .hp0_rdata(hp0_rdata), .hp0_rresp(rresp), .hp0_rlast(rlast),
        .hp0_rvalid(rvalid), .hp0_rready(rready),
        // The disk's two ports, both clocked by the fabric as HP0 is.
        .hp2_aclk(clk), .hp2_aresetn(hp2_aresetn),
        .hp2_awaddr(hp2_awaddr), .hp2_awlen(hp2_awlen),
        .hp2_awsize(hp2_awsize), .hp2_awburst(hp2_awburst),
        .hp2_awvalid(hp2_awvalid), .hp2_awready(hp2_awready),
        .hp2_wdata(hp2_wdata), .hp2_wstrb(hp2_wstrb), .hp2_wlast(hp2_wlast),
        .hp2_wvalid(hp2_wvalid), .hp2_wready(hp2_wready),
        .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid), .hp2_bready(hp2_bready),
        .hp2_araddr(hp2_araddr), .hp2_arlen(hp2_arlen),
        .hp2_arsize(hp2_arsize), .hp2_arburst(hp2_arburst),
        .hp2_arvalid(hp2_arvalid), .hp2_arready(hp2_arready),
        .hp2_rdata(hp2_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
        .hp2_rvalid(hp2_rvalid), .hp2_rready(hp2_rready),
        // The display's port, clocked by the fabric as HP0 and HP2 are.
        .hp3_aclk(clk), .hp3_aresetn(hp3_aresetn),
        .hp3_awaddr(hp3_awaddr), .hp3_awlen(hp3_awlen),
        .hp3_awsize(hp3_awsize), .hp3_awburst(hp3_awburst),
        .hp3_awvalid(hp3_awvalid), .hp3_awready(hp3_awready),
        .hp3_wdata(hp3_wdata), .hp3_wstrb(hp3_wstrb), .hp3_wlast(hp3_wlast),
        .hp3_wvalid(hp3_wvalid), .hp3_wready(hp3_wready),
        .hp3_bresp(hp3_bresp), .hp3_bvalid(hp3_bvalid), .hp3_bready(hp3_bready),
        .hp3_araddr(hp3_araddr), .hp3_arlen(hp3_arlen),
        .hp3_arsize(hp3_arsize), .hp3_arburst(hp3_arburst),
        .hp3_arvalid(hp3_arvalid), .hp3_arready(hp3_arready),
        .hp3_rdata(hp3_rdata), .hp3_rresp(hp3_rresp), .hp3_rlast(hp3_rlast),
        .hp3_rvalid(hp3_rvalid), .hp3_rready(hp3_rready),
        .gp1_aclk(clk), .gp1_aresetn(gp1_aresetn),
        .gp1_awaddr(gp1_awaddr), .gp1_awlen(gp1_awlen), .gp1_awid(gp1_awid),
        .gp1_awvalid(gp1_awvalid), .gp1_awready(gp1_awready),
        .gp1_wdata(gp1_wdata), .gp1_wstrb(gp1_wstrb), .gp1_wlast(gp1_wlast),
        .gp1_wvalid(gp1_wvalid), .gp1_wready(gp1_wready),
        .gp1_bresp(gp1_bresp), .gp1_bid(gp1_bid), .gp1_bvalid(gp1_bvalid),
        .gp1_bready(gp1_bready),
        .gp1_araddr(gp1_araddr), .gp1_arlen(gp1_arlen), .gp1_arid(gp1_arid),
        .gp1_arvalid(gp1_arvalid), .gp1_arready(gp1_arready),
        .gp1_rdata(gp1_rdata), .gp1_rresp(gp1_rresp), .gp1_rid(gp1_rid),
        .gp1_rlast(gp1_rlast), .gp1_rvalid(gp1_rvalid), .gp1_rready(gp1_rready),
        .gp0_aclk(clk), .gp0_aresetn(gp0_aresetn),
        .gp0_awaddr(gp0_awaddr), .gp0_awlen(gp0_awlen), .gp0_awid(gp0_awid),
        .gp0_awvalid(gp0_awvalid), .gp0_awready(gp0_awready),
        .gp0_wdata(gp0_wdata), .gp0_wstrb(gp0_wstrb), .gp0_wlast(gp0_wlast),
        .gp0_wvalid(gp0_wvalid), .gp0_wready(gp0_wready),
        .gp0_bresp(gp0_bresp), .gp0_bid(gp0_bid), .gp0_bvalid(gp0_bvalid),
        .gp0_bready(gp0_bready),
        .gp0_araddr(gp0_araddr), .gp0_arlen(gp0_arlen), .gp0_arid(gp0_arid),
        .gp0_arvalid(gp0_arvalid), .gp0_arready(gp0_arready),
        .gp0_rdata(gp0_rdata), .gp0_rresp(gp0_rresp), .gp0_rid(gp0_rid),
        .gp0_rlast(gp0_rlast), .gp0_rvalid(gp0_rvalid), .gp0_rready(gp0_rready),
        // The disk's interrupt on bit 0, the other nineteen lines low.
        // `IRQ_F2P` bit 0 the disk's, bit 1 the Chaosnet cable's, bit 2 the
        // serial line's.  Neither program uses its interrupt yet --- both
        // poll, and each face's own `IRQ` register says why a program
        // without one can --- so this is the wire being there before it is
        // wanted, which costs no pin: `IRQF2P` is already connected.
        .irqf2p({17'b0, ser_irq, chaos_irq, pack_irq})
    );

    // Held once it has ever happened: an error is a fault to find, not a
    // state to watch flicker past.
    logic error_seen;
    always_ff @(posedge clk) begin
      if (rst) error_seen <= 1'b0;
      else if (port_error) error_seen <= 1'b1;
    end
    assign ddr_error = error_seen;

  end else begin : g_nomem

    // NO MEMORY, which is what this top level has always been. The machine's
    // main-memory cycles are ended by the NXM timer, from the boot PROM's
    // first at microcycle 536,303, and `mem_req`, `mem_write`, `mem_addr` and
    // `mem_wdata` reach nothing but
    // the `witness` fold below --- which is the only thing keeping them, and
    // whatever computes them, out of the bin.
    assign mem_done  = 1'b0;
    assign mem_rdata = 32'd0;
    assign ddr_error = 1'b0;
    // And no port to answer anything, so the audit's port clause is silent by
    // construction. Its word 8 reads zero, which on this board is the truth.
    assign port_read_ack  = 1'b0;
    assign port_write_ack = 1'b0;
    // And no drive and no pack: see the machine's instantiation.
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
    // And no console: there is no `M_AXI_GP1` to put one on.  With `con_req`
    // and `con_msyn` down the arbiter inside `cadr_memory_path` never grants,
    // the mux folds to the processor's own half, and the register block is
    // what `build/machine.pass` compares.
    assign con_req = 1'b0;
    assign con_msyn = 1'b0;
    // And no way to say what the backplane has, so it is the default one:
    // a SIMPLE TV and no color board.
    assign con_tv_lispm = 1'b0;
    assign con_color_tv = 1'b0;
    assign con_hdmi_out    = 2'b01;
    assign con_hdmi_rotate = 2'd0;
    // And nobody to ask for steady lamps, so they blink, which is what a
    // board with a console comes up with too.
    assign con_steady_lamps = 1'b0;
    assign disp_map_a      = 4'd0;
    assign con_tv_map_a = 4'd0;
    assign con_write = 1'b0;
    assign con_addr = 18'd0;
    assign con_wdata = 16'd0;
    // And nothing asks the readout anything: the address stands at the
    // reserved selector, the machine answers `RO_NO_MEMORY` for ever, and
    // both answers fold below.
    assign con_ro_addr = 18'h3FFFF;
    // And no console reset either, so `mach_rst` is `rst` a tick late on
    // this board and the whole of the OR folds away.  Nor a console press of
    // the boot button --- BTN0 is the only driver of `-BOOT2` on a board with
    // no processing system, which is a light panel with one button on it.
    assign con_mach_rst  = 1'b0;
    assign con_mach_boot = 1'b0;
    // And no debug cable: there is no general-purpose port to put its
    // carrier on.  The cable is levels and not pulses, so holding
    // `-DEBUG IN REQ` UP --- which is `dbg_in_req` low, the sense the whole
    // transport uses --- is exactly what the SIP at DBGIN 0A22 does to an
    // unplugged connector.  `cadr_dbgin.sv` then makes no strobe, never asks
    // for the bus, and the whole arm of the arbiter folds.
    assign dbg_in_req     = 1'b0;
    assign dbg_in_wr      = 1'b0;
    assign dbg_in_a       = 2'd0;
    assign dbd_to_machine = 16'd0;
    // And nobody to ask for the debugger's role, there being no console.
    // **The connector is still there and this board is still a DEBUGGEE** ---
    // it answers a debugger that plugs into JA, which is the power-on state
    // of any CADR and needs nothing set. What is missing is only the way to
    // ask for the other role.
    assign dbg_connect    = 1'b0;
    // And the wiring stands at `auto`, which is what the fabric comes up
    // with: a board with no console still finds a crossed cable, it just has
    // nobody to tell.
    assign dbg_wiring     = 2'd0;
    // And no port for the I/O board's two cables, so their far ends are
    // tied off: this is the board that has no processing system at all, and
    // a program is what is on the other end of either cable.  With
    // `ser_plugged` down the 2651's sheet holds both halves stopped, and
    // with the Chaosnet's address switches at zero and nothing giving it a
    // frame the interface has no cable --- which is what the whole of this
    // file did until the splitter landed.
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
    // The keyboard's cable and the mouse's, on the same argument.  **ALL
    // ONES AND NOT ZERO on the mouse**: the seven lines are what the MOUSE
    // drives, each switch pulled to ground when pressed and each quadrature
    // line high at rest, so all ones is a cable with nothing moving on it
    // and zero would be three buttons held down for ever.  It is also what
    // `muir::terminal::mouse`'s `Encoders::default` sits at, and what the
    // card's own `mnew` comes up holding.
    assign kbd_strobe     = 1'b0;
    assign kbd_code       = 24'd0;
    assign mouse_lines    = 7'h7F;

  end

  // ------------------------------------------------------------ the probe
  //
  // One sample a microcycle of the columns `build/rtl.golden` carries, held
  // in block RAM and shifted out over JTAG, so that what the *board* computes
  // can be diffed against what muir computes. `rtl/plumbing/cadr_probe.sv` is the
  // whole of it and its header says why it is not an ILA.
  //
  // **THE COLUMN LIST AND THE BIT LAYOUT ARE THAT FILE'S**, one port a
  // column, so that this file does not hold a second copy of them to drift.
  // What is here is the two things only a top level can say: which net is
  // which column, and that `-VMAOK` is the trace's polarity where
  // `cadr_machine` brings out the logical one the jump conditions take.
  if (PROBE_DEPTH > 0) begin : g_probe
    // The JTAG scan chain the readout uses.  USER1 --- IR 0x02 on a 7-series
    // part --- which `boards/arty-z7-20/vivado/probe.tcl` selects by name and by code.
    //
    // RESET, RUNTEST, TCK, TMS and UPDATE are left empty because nothing here
    // reads them: the pointer moves on CAPTURE, so UPDATE is not needed, and
    // that is the point of moving it there. See `cadr_probe.sv`.
    logic bscan_drck, bscan_sel, bscan_shift, bscan_capture, bscan_tdi;
    logic bscan_tdo;
    /* verilator lint_off PINCONNECTEMPTY */
    BSCANE2 #(
        .JTAG_CHAIN(1)
    ) u_bscan (
        .CAPTURE(bscan_capture),
        .DRCK   (bscan_drck),
        .SEL    (bscan_sel),
        .SHIFT  (bscan_shift),
        .TDI    (bscan_tdi),
        .TDO    (bscan_tdo),
        .RESET(), .RUNTEST(), .TCK(), .TMS(), .UPDATE()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    cadr_probe #(
        .DEPTH(PROBE_DEPTH)
    ) u_probe (
        // **AND THE PROBE RE-ARMS ON A CONSOLE RESET**, which is a capability
        // and not a side effect.  Its own words are that it "fills from the
        // first microcycle after reset and freezes", so a machine that has
        // been restarted has new first microcycles and the probe must be
        // looking at those.  Until now re-arming meant BTN0 or a fresh
        // bitstream; it is a store from Linux now.  The price is that a
        // console reset spoils a readout in progress --- which BTN0 already
        // did, and which is the same instrument either way.
        .clk(clk), .rst(mach_rst),
        // ONE SAMPLE A MICROCYCLE, on the machine's own boundary. A
        // free-running probe at 100 MHz would mostly record a machine
        // standing still and would line up with no row of anything.
        .qualify(clock_edge),
        .pc(pc), .ir(ir), .q(q), .a(a), .m(m), .alu(alu), .r(r), .ob(ob),
        .dc(dc), .opc(opc), .st(st), .lc(lc),
        .iwrited(iwrited), .nop(nop), .n_vmaok(!vmaok), .jcond(jcond),
        .pcs1(pcs1), .pcs0(pcs0),
        .lpc(lpc), .md(md), .vma(vma), .promdis(promdisable),
        .jtag_drck(bscan_drck), .jtag_sel(bscan_sel),
        .jtag_shift(bscan_shift), .jtag_capture(bscan_capture),
        .jtag_tdi(bscan_tdi), .jtag_tdo(bscan_tdo)
    );
  end

  // ------------------------------------------------------------- the LEDs
  //
  // `witness` is what keeps the machine alive through synthesis. Every output
  // of `cadr_machine` folds into it, so none of them is dead, and it is
  // registered so the fold is not a combinational path across the design.
  // It is not meant to be readable --- it is a load, and what it shows is
  // that the datapath is moving at all.
  //
  // **Every one of them, including the ones something else already
  // reads** --- `clock_edge`, `promenable`, `timed_out`, `n_memack` drive
  // LEDs as well and are still here, because the rule the comment states is
  // the whole specification and a fold with exceptions in it is not a rule
  // anybody can check. What checks it is `make build/arty.pass`: an output
  // left off the instantiation is a Verilator PINMISSING, which is how
  // `dev_wdata` was found missing from both.
  //
  // The debug cable's ONE connector puts five more in it: which of the two
  // debuggers has the DBGIN page, and the connector's own four --- the role
  // this board has, whether somebody else is driving the header, and whether
  // it is driven at all and carrying good frames. On a board with a console
  // the four are page 0's word 14 as well and this is a second reader; on a
  // board without one this is the only reader, and a fold with exceptions in
  // it is not a rule anybody can check.
  // **AND IT NO LONGER DRIVES A LAMP, SO IT SAYS SO TO THE TOOLS INSTEAD.**
  // `witness` was LD3 until the six lamps were reassigned and LD3 became the
  // disk's; every one of the ten lamp pins now carries a meaning of the
  // machine's, and there is no spare one to hang a load on.  A register
  // nothing reads is trimmed, and the whole machine behind it with it --- and
  // then every fit and timing figure this board reports is a figure for a
  // design that is not there, which is the loudest trap this project has met.
  //
  // `DONT_TOUCH` is the one thing that keeps it without inventing a meaning
  // for a lamp.  It propagates through the cone, which is exactly what is
  // wanted: the fold and everything feeding it survive.  The Verilator waiver
  // is beside it because lint's complaint is correct --- nothing reads this
  // --- and the answer is that nothing is meant to.
  //
  // `cadr_arty.xdc` already false-paths `witness_reg` by name and goes on
  // doing so; the register is still there, it simply has no reader.
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
                   // The debug cable's own four, which say what the connector
                   // is doing rather than what crosses it. On a board with no
                   // console they reach nobody and are folded here; with one,
                   // page 0's word 14 reports them and this is a second
                   // reader.
                   dbg_engaged, dbg_foreign, dbg_live, dbg_active, dbg_peer_far, dbg_frames,
                   // The two display boards' color maps, which the console
                   // reads on pages 4 and 5. On a board with no console they
                   // reach nobody and are folded here.
                   con_tv_map_q, con_tv_color_map_q, con_disp_color_map_q,
                   con_hdmi_out, con_hdmi_rotate,
                   dbg_wire_state};
    end
  end

  // AND A HEARTBEAT THAT DOES NOT DEPEND ON THE MACHINE. Without it a dark
  // board means "not programmed", "the MMCM never locked" or "the machine
  // stalled", and those are three different problems that look the same. This
  // counts the master clock and nothing else, so it blinks whenever the
  // fabric is clocked at all --- about 1.5 times a second at 100 MHz --- and
  // it is deliberately not reset by `rst`, because `rst` is held while the
  // MMCM is unlocked and a heartbeat that stopped during reset would lose the
  // one case it exists to distinguish.
  always_ff @(posedge clk) tick <= tick + 26'd1;

  // **THE HEARTBEAT IS LD1 NOW AND NOT LD0.**  It answers "is this thing
  // clocked at all", which is the first question on a dark board and the last
  // one on a working machine; the machine's own run signal is LD0.  `tick`
  // is deliberately not reset by `rst`, because `rst` is held while the MMCM
  // is unlocked and a heartbeat that stopped during reset would lose the one
  // case it exists to distinguish.
  //
  // **AND THE NXM COUNTER IS GONE WITH THE LAMP THAT READ IT.**  LD2 used to
  // light a bit of a count of timeouts, on the argument that `timed_out` is a
  // sliver too faint to read; the lamp it was for is the microcycle blink
  // now, and the timeouts reach LD4, where what matters is that one ever
  // happened and not how often.  Measured, the rate said nothing anyway: the
  // boot PROM's 16,951 disk polls time out with memory and without, so the
  // lamp read the same either way.  `docs/board.md` has that account.

  // ================================== THE SIX LAMPS ==========================
  //
  // **THEY READ LEFT TO RIGHT AS THE MACHINE'S OWN PROGRESS, AND NOT AS THE
  // FABRIC'S BRING-UP.**  The assignment this file carried until now was the
  // one the bring-up wanted --- a heartbeat, a witness that the datapath had
  // not been optimized away, a counter of timeouts --- and every one of those
  // answers a question nobody asks of a working machine.  The CADR's own
  // light panel carried a run lamp and a parity-error lamp beside the boot
  // button, and BTN0 is that button now.
  //
  //   LD0  MACHRUN          the machine's own run signal as a LEVEL: lit
  //                         means it should be running.  `MACHRUN` is
  //                         `(SSTEP AND -SSDONE) OR (SRUN AND -ERRHALT AND
  //                         -WAIT AND -STATHALT)` at OLORD1 1A15, so it drops
  //                         during every memory stall --- which makes the
  //                         lamp's BRIGHTNESS the fraction of time the
  //                         machine computes rather than waits.  Dim means it
  //                         is thrashing.
  //   LD1  the clock        `tick[25]`, the slow blink: the fabric is clocked.
  //                         Always blinking, on any board that is alive at
  //                         all, and it says nothing about the machine.
  //                         Steady, it is the MMCM's lock instead.
  //   LD2  microcycles      bit 19 of a count of them, the fast blink: the
  //                         machine is executing.  It FREEZES when the
  //                         machine stops, which is the thing a level cannot
  //                         say --- motion cannot be faked, where a frozen
  //                         fabric would still hold a level high.  Steady,
  //                         it is lit for a moment after every microcycle
  //                         instead, which goes out when the machine stops.
  //   LD3  disk activity    lit while the controller moves a block.  The
  //                         light every computer has had, and it answers
  //                         whether a pause is the disk or the program.
  //   LD4  ERRHALT          the machine halted ITSELF under ERRSTOP, which is
  //                         `(si:%halt)` and nothing else.  Dark normally,
  //                         red when it happens, and cleared by the boot
  //                         button or a reset.  See below.
  //   LD5  PROMENABLE       the PROM's own select: LIT while the machine
  //                         fetches its microcode out of the boot PROM and
  //                         DARK once it runs the microcode it loaded from
  //                         the disk.  So lit means BOOTING and dark means
  //                         BOOTED, which is the way round a lamp should be:
  //                         the interesting state is the one that ends.  See
  //                         below for why it is the select and not the mode
  //                         register's bit.
  //
  // LD0's level and LD2's blink say different things on purpose, and neither
  // replaces the other.
  //
  // **AND LD1 AND LD2 CAN HOLD A LEVEL INSTEAD OF BLINKING**, which is
  // `--no-blinking-leds` and the console's page 2 word 35.  A blink is bright
  // and moving, and a board left running on a desk is a board somebody wants
  // to stop looking at.  What the two lamps SAY does not change, only how, and
  // each steady form is chosen so that it still goes OUT when the thing it
  // reports stops: LD1 is the MMCM's lock, because logic clocked by a stopped
  // clock cannot turn its own lamp off, and LD2 is lit for a moment after each
  // microcycle, because a hold that is not re-armed runs out.  The fabric comes
  // up blinking.  `rtl/plumbing/cadr_lamp_clock.sv` and
  // `rtl/plumbing/cadr_lamp_microcycle.sv` are the two, held by
  // `build/blink_lamps.pass`; which nets reach them is this file's and its
  // lint's.
  //
  // ---------------------------------------------------------------- LD4
  //
  // **LD4 IS THE MACHINE'S OWN ERROR HALT AND NOTHING ELSE: IT IS EITHER OFF
  // OR RED.**  No other color and no other meaning ever reaches it --- not at
  // power-on, not during the PROM, not while halted by a console.  Its green
  // and blue channels are tied off, so there is nothing for a later meaning to
  // be put on.
  //
  // `ERRHALT` is `ERRSTOP AND HALTED` at OLORD1 and is one of `MACHRUN`'s own
  // terms: the machine executed a halt with the console's error-stop bit set
  // and stopped itself.  On microcode 323 that is `(si:%halt)` reached through
  // `ILLOP`, `%HALT` and `ZERO`; MIT's own boards reach the same line from the
  // memory parity checkers, which this fabric does not have.  A console halt
  // is not it --- that clears `RUN` --- so stopping the machine to look at it
  // leaves the lamp dark.
  //
  // **AND DARK IS THE GOOD STATE**, which is the whole argument for it: this
  // is the one lamp nobody should have to watch, and a lamp that means one
  // thing is read faster than one that means four.  It makes LD2's freeze
  // readable --- LD2 stopped with LD4 dark means somebody halted the machine,
  // LD2 stopped with LD4 red means it fell over.
  //
  // **THE THREE OTHER THINGS THAT USED TO LIGHT IT ARE GONE.**  A
  // non-existent-memory timeout is not a fault: the boot PROM makes two cycles
  // to empty Xbus space on every boot, so the lamp came up red on a machine
  // that was perfectly well, and a lamp whose normal state is red says
  // nothing.  A statistics halt is something the console asked for.  And
  // `store_miss` --- a block the disk's store could not supply --- is a real
  // defect and this was never the place for it: the controller ends that
  // transfer with a clean status, so the microcode believes it read a page
  // that was never written and nothing the CADR can read says otherwise.  That
  // is `rtl/machine/cadr_disk_controller.sv`'s to answer, with a transfer
  // error the machine can see, and it is open there.  A board lamp was not a
  // fix for it and showing it here only made this lamp mean two things.
  //
  // **CLEARED BY THE BUTTON AS WELL AS BY A RESET**, which is why `-BOOT`
  // comes out of the machine: a board booted at the button, at the keyboard's
  // chord or over the debug cable starts with a clean lamp, and nothing out
  // here has to know which of the three it was.
  //
  // **THE LATCH IS A MODULE AND THE WIRING IS NOT, AND THAT SPLIT IS
  // DELIBERATE.**  `rtl/plumbing/cadr_lamp_errhalt.sv` is held by
  // `build/errhalt_lamp.pass`, because lint cannot tell a lamp that latches
  // from one that does not.  WHICH signal reaches its input is this line, and
  // this line is reached by `build/arty.pass`'s lint and by nothing else ---
  // so a second term ORed in here would be caught by nobody, and the reason it
  // is not there is this paragraph.
  //
  // **AND ON A `PROVE` BOARD LD4 SAYS SOMETHING ELSE ENTIRELY** --- the
  // witness's verdict, driven from `g_ddr.g_prove` where the numbers are.
  // That is a board with no machine behind the memory port at all, so it has
  // no halt to report and the lamp is not built there.
  assign {led4_r, led4_g, led4_b} = lamp4;
  if (PROVE == 0) begin : g_lamp_errhalt
    logic errhalt_lit;
    cadr_lamp_errhalt u_lamp_errhalt (
        .clk(clk), .rst(mach_rst), .errhalt(errhalt), .n_boot(n_boot),
        .lit(errhalt_lit)
    );
    assign lamp4 = {errhalt_lit, 1'b0, 1'b0};
  end

  // ---------------------------------------------------------------- LD5
  //
  // **`PROMENABLE`, AND THAT IS THE NAME OF THE SIGNAL ON THE PIN.**  The
  // lamps are named by the machine's own signals --- LD0 is `MACHRUN` and LD4
  // is `ERRHALT` --- and this one is MIT's `-PROMENABLE` at PCTL 1C19, the
  // PROM's own select, driven from the net itself out of the processor.  So
  // the lamp is LIT while the machine fetches its microinstructions from the
  // boot PROM and DARK once it runs the microcode it loaded from the disk,
  // which is the way round a lamp should be: the interesting state is the one
  // that ends.
  //
  // **IT IS THE SELECT AND NOT THE MODE BIT, AND THE EYE CAN SEE THE
  // DIFFERENCE.**  `-PROMENABLE` is `BOTTOM.1K` with `PROMDISABLED`,
  // `IWRITEDA` and `-IDEBUG`, so it says whether THIS microinstruction is
  // coming out of the PROM: it is up on every fetch and down on the
  // control-store write cycles, which is why the lamp is blue and a little
  // under full brightness while the PROM loads the store rather than blue at
  // full.  Once `PROMDISABLE` is set it is dark for good.  The mode
  // register's own bit is `promdisable`, which drives no lamp here --- the
  // probe's sample carries it and nothing else does.
  //
  // Blue, and blue only, for the one state it carries.  A color lamp showing
  // one thing is still the right lamp for it: this is the answer to "has it
  // finished booting", which is worth telling apart from the four plain green
  // ones at a glance.
  assign led5_r = 1'b0;
  assign led5_g = 1'b0;
  assign led5_b = promenable;

  // **LD0 IS REGISTERED AND LD3 IS STRETCHED, AND NEITHER IS A CONVENIENCE.**
  //
  // `MACHRUN` is a six-input gate with `-WAIT`'s whole cone behind it, and a
  // pad is the one place in this design where a long combinational path buys
  // nothing: an LED is not sampled by anything, so a tick of delay is free
  // and the cone stops at a flip flop.  It is the reason `mach_rst` is a
  // register and not a gate, one lamp along.  What the eye reads is unchanged
  // --- the lamp's brightness is still the fraction of ticks `MACHRUN` is up,
  // which is the fraction of time the machine computes rather than waits.
  //
  // **AND A DISK LIGHT NOBODY CAN SEE IS NOT A DISK LIGHT.**  `ch_active` is
  // up while the channel moves a block, which is 256 bus cycles of about
  // 150 ns --- some 38 us --- and a drive at thirty blocks a second lights it
  // for about a thousandth of the time.  That integrates to nothing, which is
  // exactly what the old LD2 did with `timed_out` and what `docs/board.md`
  // records measuring.  So the lamp is a one-shot: `DISK_LIT_T` ticks, about
  // 42 ms of real time, re-armed by every block.  Steady means the disk is
  // busy, flickering means it is being touched, and dark means it is idle,
  // which is the light every computer has had.
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

  // **LD1 AND LD2, BLINKING OR STEADY.**  The clock lamp takes the MMCM's
  // lock straight off the primitive and has no clock of its own, which is the
  // whole of its point; the microcycle lamp counts `clock_edge`, the
  // processor's own boundary, and is reset with the machine, which retires
  // nothing while it is held there.
  logic clock_lamp, cycle_lamp;
  cadr_lamp_clock u_lamp_clock (
      .steady(con_steady_lamps), .locked(mmcm_locked), .blink(tick[25]),
      .lit(clock_lamp)
  );
  cadr_lamp_microcycle u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(con_steady_lamps),
      .retired(clock_edge), .lit(cycle_lamp)
  );

  assign led[0] = machrun_lamp;  // the machine should be running; dim = stalling
  assign led[1] = clock_lamp;    // the fabric is clocked --- the slow blink, or the lock
  assign led[2] = cycle_lamp;    // microcycles retiring --- the fast blink, or a hold
  assign led[3] = disk_lit;      // the disk controller is moving a block

  // On a board with no processing system there is no `S_AXI_HP3` and so no
  // display; the connector is held at a level exactly as it is on a board
  // that has the port and does not use it.
  if (PORT == 0) begin : g_no_port_hdmi
    assign hdmi_ser = 4'd0;
  end

  // ---------------------------------------------------- the HDMI connector
  //
  // The four differential pairs, made here rather than inside
  // `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` for the reason that file's
  // header gives: the pins exist on every board and the phy does not.  Bit 3
  // is the clock channel.  This is the same rule the `BSCANE2` follows ---
  // the primitive goes where every configuration can see it, and the module
  // below it stays a module.
  OBUFDS u_hdmi_d0  (.I(hdmi_ser[0]), .O(hdmi_tx_d_p[0]), .OB(hdmi_tx_d_n[0]));
  OBUFDS u_hdmi_d1  (.I(hdmi_ser[1]), .O(hdmi_tx_d_p[1]), .OB(hdmi_tx_d_n[1]));
  OBUFDS u_hdmi_d2  (.I(hdmi_ser[2]), .O(hdmi_tx_d_p[2]), .OB(hdmi_tx_d_n[2]));
  OBUFDS u_hdmi_clk (.I(hdmi_ser[3]), .O(hdmi_tx_clk_p), .OB(hdmi_tx_clk_n));

  // btn[3:2] and sw[1] are pins the board has and this design does not use.
  // BTN0 is the machine's boot button and BTN1 the fabric's reset; BTN2 and
  // BTN3 have no meaning here, and neither has SW1. SW0 is the no-auto-boot
  // switch. The unused pins are read here only to keep them legal without
  // inventing behavior for them.
  //
  // **AND `sw0_held` IS READ HERE FOR A DIFFERENT REASON**, which is worth
  // keeping apart from theirs: it has a reader, the console, and the console
  // exists only on a board with a general-purpose port. On the boards that
  // have none it would be a signal nothing reads, which lint reports and is
  // right to --- and tying it off inside the `DDR` generate's `else` arm would
  // put a board's own pin behind the memory's parameter. It is read twice on a
  // board that has a console, which is legal and is the honest arrangement.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, btn[3:2], sw[1], sw0_held};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
