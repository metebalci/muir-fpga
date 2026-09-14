// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on an Arty A7-100: a top level with real pins and no processing
// system at all.
//
// **THIS IS THE FIRST BOARD IN THIS REPOSITORY WITH NO PROCESSING SYSTEM.**
// The part is an XC7A100T, an Artix-7, so there are no ARM cores, no DDR
// controller, no gigabit Ethernet, no SD host and no Linux.  Everything the
// Arty Z7-20 reaches through the Zynq --- main memory, the disk, the screen,
// the console, Chaosnet, the serial line and the debugger --- is absent here
// and every one of them is tied off below with a comment naming what it
// would take to answer it in fabric.  `boards/arty-a7-100/README.md` is the
// plan and this file is the part of it that builds.
//
// WHAT DOES RUN.  The whole of `rtl/machine/` is plain SystemVerilog and does
// not know what part it is on, so the machine itself is unchanged: the
// processor, the bus interface, the map, the disk controller's register face,
// the display block, the I/O board and the clock generator are all here and
// all agree with muir exactly as they do on the other board.  What is missing
// is what is behind the memory port.
//
// **AND SO, BY DEFAULT, THIS IS NOT A WORKING CADR AND IS NOT MEANT TO BE.**
// `mem_done` is tied low, so nothing answers the boot PROM's main-memory
// cycles.  That is exactly the Arty Z7-20's own memory-off board, which is
// the configuration this project has built and measured from the beginning.
//
// **AND THE MACHINE DOES NOT STOP THERE, WHICH IS WORTH KNOWING BEFORE
// READING THE LAMPS.**  An unanswered cycle is not a stall: it ends on the
// 4.25 us non-existent-memory timer, and the machine goes on.  Measured by
// `make nomem`, which runs this exact configuration --- `mem_done` low,
// `mem_rdata` zero, no Xbus device outside the machine --- over 200 ms of the
// machine's own time:
//
//     microcycles           852,515
//     first `mem_req`       microcycle 536,303, tick 23,597,357
//     NXM timeouts          514 in the 82 ms after it
//     after that cycle      0.26 us a microcycle, against 0.22 normal
//     `beat[19]`            toggles every 0.14 s of machine time
//
// So the board is not stuck; it runs about a fifth slower once it reaches
// main memory, and 514 is the parity loop's own 512 cycles plus the two to
// empty Xbus space --- the disk controller's registers answer the boot PROM's
// 16,951 polls in 140 ns and those do not time out.  **That paragraph exists
// because the prediction was wrong once**: this design's other top level said
// the machine "stalls there for ever", the board said otherwise by blinking,
// and `tb/cadr_nomem_tb.cpp` was written to measure rather than to reason
// again.  The figures above are that testbench's, re-run at this commit.
//
// What the board can show, then, is that the fabric runs: the clock generator
// ticking, microcycles retiring, the boot PROM executing --- and, with
// `PROBE_DEPTH` set, the first 1,024 microcycles read back over JTAG and
// diffed against muir column for column.
//
// THE TICK IS 10 ns, AND EVERY TICK COUNT IN THE MACHINE IS UNCHANGED.
// `CLKOUT0_DIVIDE_F` below is the only place the length of a tick is decided.
// `cadr_phase_gen.sv`'s `TICK_NS` is still 5, because that constant is the
// conversion from MIT's drawings --- whose instants are five nanoseconds
// apart --- into tick counts, and the seven read taps are still 15, 17, 20,
// 23, 25, 28 and 32 ticks of whatever a tick costs.  Making every tick longer
// by the same factor scales the machine and does not distort it; redescribing
// MIT's instants on a coarser grid would be a different machine that still
// lights LEDs.  `boards/arty-z7-20/cadr_arty.sv`'s header has the whole of
// that argument and it is the same argument here.
//
// **THE BOARD'S CLOCK IS ALREADY 100 MHz, AND THE MMCM STAYS ANYWAY.**  A
// single oscillator on pin E3 gives exactly the frequency the machine wants,
// so a wire would work.  Three things say otherwise.  The `LOCKED` output is
// the fabric's reset term and a wire has none, so the machine would start
// before its clock was real.  The tick would then be a property of the board
// crystal rather than something this file decides, and the first person who
// wanted a different one would have to change the board.  And
// `boards/arty-z7-20/vivado/tick.tcl`'s contract --- one `MMCME2_BASE` in the
// top level, four parameters, the period computed from them, and that file
// takes the top level to parse as an argument so both boards use it --- is what
// stops a constraint file describing a different machine from the one being
// built; a board with no MMCM would have to be exempted from it, and an
// exemption is what this project spends its time regretting.  So: 100 MHz in,
// 100 MHz out, **VCO 1000 MHz exactly, so the output divider reads literally
// as the tick in nanoseconds**, which is the property the other board's clock
// was chosen for and which survives the input frequency moving.
//
// **Every output has to reach a pin or synthesis will delete the machine.**
// `cadr_machine` brings out the whole datapath for the testbenches to compare
// --- PC, IR, the A and M buses, the ALU, twenty-odd more --- and a top level
// that left them unconnected would synthesise to almost nothing, place and
// route in seconds, and write a perfectly good bitstream of an empty part.
// So the wide outputs are reduced into one register, `witness`, which costs
// a handful of LUTs and keeps every one of them load-bearing.
//
// THE LAMPS, AND THE ONE THING ABOUT THEM THAT IS PECULIAR TO THIS BOARD.
// The six lamps this project assigns are the same six the other board
// carries, by MEANING.  What differs is the silkscreen: the Arty Z7-20 numbers
// its four plain green LEDs LD0 to LD3 and its two tricolour ones LD4 and
// LD5, and the Arty A7-100 numbers its four TRICOLOUR ones LD0 to LD3 and its
// four plain green ones LD4 to LD7.  So the numbers on the two boards do not
// line up and the meanings do:
//
//   meaning                        this project   port here      A7 silkscreen
//   MACHRUN, as a level            LD0            led[0]         LD4
//   the fabric is clocked          LD1            led[1]         LD5
//   microcycles retiring           LD2            led[2]         LD6
//   disk activity                  LD3            led[3]         LD7
//   `ERRHALT`, red and only red    LD4            led0_{r,g,b}   LD0
//   `-PROMDISABLE`, blue only      LD5            led1_{r,g,b}   LD1
//   nothing; dark                  ---            led2_*, led3_* LD2, LD3
//
// This board has eight lamps where the six-lamp assignment wants six, so two
// tricolour ones are dark.  They are in the port list and driven to zero
// rather than left out, so that the port list matches the board.
//
// THE BUTTONS ARE THE OTHER BOARD'S.  BTN0 is `-BOOT2`, the button MIT put on
// the CADR's light panel, debounced; BTN3 resets the fabric, at the far end
// of the row where it is hard to press by accident.  BTN1 and BTN2 are pins
// the board has and this design does not use.
//
// AND SW0 HOLDS THE MACHINE AT POWER-ON.  A CADR whose power has just come on
// has its clock stopped: `RUN` is clear, nothing is running, and the button on
// its light panel is what starts it.  This fabric comes up the other way by
// default, with `RUN` preset --- a board switched on runs its boot PROM ---
// which is what somebody switching a board on wants and what a board being
// brought up needs.  SW0 is how a board being worked on is asked for the other
// behaviour instead, and `-BOOT` is what takes the hold off.  It is a
// POWER-ON CONDITION and not a control: the level is read at the machine's own
// reset arms and nowhere else, so moving the switch under a running machine
// does nothing until the next reset.  SW1 to SW3 are pins the board has and
// this design has no opinion about.

`default_nettype none

// `PROBE_DEPTH` is zero here, so the design this file describes by default is
// the machine and nothing else.  Setting it instantiates
// `rtl/plumbing/xilinx7/cadr_probe.sv`, which records one sample a microcycle
// into block RAM and hands it back over JTAG;
// `boards/arty-a7-100/vivado/probe.tcl` builds the readout and
// `tools/probe_check.py` diffs it against muir.  Off by default because an
// instrument in every bitstream is an instrument nobody measures the cost of,
// and because the two questions --- does the machine fit, and what does
// watching it cost --- are worth keeping apart.
module cadr_arty_a7 #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    parameter int unsigned PROBE_DEPTH = 0
) (
    input  var logic       sysclk,   // 100 MHz, pin E3
    input  var logic [3:0] btn,
    // The four slide switches.  **SW0 IS THE NO-AUTO-BOOT SWITCH** --- see the
    // note below the buttons --- and SW1 to SW3 are pins the board has that
    // this design has no opinion about, brought out so the port list matches
    // the board rather than the design, as BTN1 and BTN2 are.
    input  var logic [3:0] sw,
    // The four plain green LEDs.  Digilent's file calls them `led[0]` to
    // `led[3]` and the board's own silkscreen calls them LD4 to LD7.
    output var logic [3:0] led,
    // The four tricolour LEDs, Digilent's names and the board's silkscreen
    // LD0 to LD3.  Driven high to light, one pin a colour.  The first two
    // carry this project's LD4 and LD5; the other two are dark.
    output var logic       led0_r, led0_g, led0_b,
    output var logic       led1_r, led1_g, led1_b,
    output var logic       led2_r, led2_g, led2_b,
    output var logic       led3_r, led3_g, led3_b
);

  // ------------------------------------------------------------ the clock
  //
  // 100 MHz in, 100 MHz out, through an MMCM rather than a wire --- the
  // header says why.  The VCO must sit between 600 and 1200 MHz on a -1 part:
  // 100 x 10 is 1000, in the middle of the range, and 1000 / 10 is the tick.
  logic clk_fb, clk_raw, clk, mmcm_locked;

  // The eleven clock outputs this design does not take are left empty on
  // purpose --- that is how the primitive is written and what Xilinx's own
  // templates do --- so the style warning about it is turned off here rather
  // than answered with eleven wires nothing reads.
  /* verilator lint_off PINCONNECTEMPTY */
  MMCME2_BASE #(
      .CLKIN1_PERIOD  (10.000),   // 100 MHz, the board's own oscillator
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(10.000),   // 1000 MHz at the VCO
      // THE TICK, AND THE ONLY PLACE IT IS DECIDED.  The VCO is 1000 MHz
      // exactly, so this number IS the tick in nanoseconds: 10.000 ns, which
      // is 100 MHz.  `boards/arty-z7-20/vivado/tick.tcl` --- which is shared
      // between the boards and takes the file to parse as an argument ---
      // reads these four
      // parameters out of this file and computes the period the constraints
      // are written against, so the fabric and its timing cannot describe two
      // different machines.  See the header for why every tick COUNT in the
      // design stays exactly as it was.
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
  // **BTN0 BOOTS THE MACHINE AND BTN3 RESETS THE FABRIC**, which is the other
  // board's assignment carried over unchanged.  The CADR's own way to restart
  // is the boot button on its light panel, and a person at this board
  // pressing the button nearest to hand should get what a person at a CADR
  // pressing the button gets --- the machine back at the boot PROM with its
  // memory intact --- and not the fabric reconfigured out from under them.
  // So BTN0 is `-BOOT2`, and the one control that throws away the machine's
  // whole state is at the far end of the row.
  //
  // Pins: `btn[0]` is D9 and `btn[3]` is B8, both `LVCMOS33`, from Digilent's
  // `Arty-A7-100-Master.xdc`.  `cadr_arty_a7.xdc` carries them and false-paths
  // all four, a human's finger being no timing constraint.
  //
  // Reset while the MMCM has not locked, and on BTN3.  Synchronised out of the
  // 100 MHz domain: `LOCKED` is asynchronous to it by construction.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked || btn[3]};
  assign rst = rst_sync[3];

  // ------------------------------------------------------ BTN0, DEBOUNCED
  //
  // **A RESET DOES NOT NEED DEBOUNCING AND A BOOT DOES.**  BTN3's four
  // synchroniser stages are all its job wants: a reset asserted for a
  // millisecond of contact bounce is a reset, and the bounces land inside it.
  // `-BOOT2` is a level the machine READS THE END OF --- it runs the PROM from
  // word 0 when the button is let go --- so every bounce on the release is
  // another press, and a machine booted five times in two milliseconds is a
  // machine whose first four boots ran four microcycles each.  The light
  // panel's own switch is debounced by the hysteresis of the 74LS14 Schmitt
  // inverter at OLORD2 1A20 that takes it; this is that inverter.
  //
  // The rule: the line must read the same for `DEBOUNCE_T` ticks together
  // before the debounced level follows it.  At the 10 ns tick 400,000 ticks is
  // 4 ms, which is past the 1 to 2 ms a tactile switch of this kind settles in
  // and far short of the shortest press a person can make.
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

  // --------------------------------------- SW0, THE NO-AUTO-BOOT SWITCH
  //
  // **IT IS A POWER-ON CONDITION AND NOT A CONTROL, WHICH IS WHY IT IS READ AT
  // THE RESET AND NOWHERE ELSE.**  `cadr_spy_registers.sv`'s reset arm is the
  // one place `RUN` is decided and `cadr_microcycle.sv`'s is the one place
  // `SRUN` is, so the level goes to both and to nothing else: moving the
  // switch under a running machine does nothing until the next fabric reset,
  // and moving it back under a held machine starts nothing.  Only `-BOOT`
  // takes the hold off, which is what a button is for.
  //
  // **THE OTHER BOARD ALSO FREEZES THE VALUE THE MACHINE CAME UP WITH**, so
  // that its console can report what the machine actually started with rather
  // than where the switch is now.  There is no console on this board to report
  // it to, so that register is not built here: a register nothing reads is
  // trimmed, and a lamp or a port is what would earn it back.
  //
  // Three synchroniser stages, because the switch is asynchronous to this
  // clock like every other pin.  No debounce: `-BOOT2` needs one because a
  // bounce on the RELEASE is another press, and this is a level read once, at
  // an instant a slide switch is not being moved at.
  //
  // Pin: `sw[0]` is A8, `LVCMOS33`, `IO_L12N_T1_MRCC_16`, Sch=sw[0], from
  // Digilent's `Arty-A7-100-Master.xdc`.  `cadr_arty_a7.xdc` carries it and
  // false-paths all four switches, a slide switch being no timing constraint.
  logic [2:0] sw0_sync;
  logic       sw0_level;
  always_ff @(posedge clk) sw0_sync <= {sw0_sync[1:0], sw[0]};
  assign sw0_level = sw0_sync[2];

  // ---------------------------------------------------------- the machine
  //
  // The datapath the golden traces carry, brought out of `cadr_machine` for
  // the testbenches and folded into `witness` below so that synthesis cannot
  // delete what computes it.
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
  logic device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
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
  // The console's half of the diagnostic bus.
  logic        con_req, con_gnt, con_msyn, con_write, con_ssyn;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  // MIT's debug cable, the DBGIN connector's twenty-one wires.
  logic        dbg_in_ack;
  logic [1:0]  dbd_oe;
  logic [15:0] dbd_from_machine;
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

  // ============ WHAT THIS BOARD HAS NOT GOT, AND WHAT WOULD ANSWER IT ======
  //
  // Every line below is a seam whose far end is a program on the Arty Z7-20's
  // ARM cores or a port of its processing system.  There is neither here, so
  // each is tied to the value a cable with nothing on the end of it presents,
  // and each names what a fabric answer would have to be.  Nothing in this
  // block is a decision: `boards/arty-a7-100/README.md` is where the open
  // ones are written down, and this file only records that they are open.
  //
  // **A TIE-OFF IS NOT FREE AND THAT IS THE POINT.**  Tied off, the drive
  // constant-folds, the 2651 constant-folds with `ser_plugged` down, the
  // Chaosnet interface folds with its address switches at zero, and the
  // mouse's two counters and comparator fold because nothing on the seven
  // lines ever changes.  So the fit this board reports is the register face,
  // the decode and the machine --- and the fitter does not test the drive,
  // the serial chip or the mouse here any more than it does on the other
  // board's memory-off configuration.

  // MAIN MEMORY.  On the other board this is `S_AXI_HP0` into the Zynq's own
  // DDR3 controller.  Here the board's 256 MB of DDR3L is on the FABRIC's
  // pins, so answering this means a memory controller in fabric --- which is
  // the largest single piece of work this board needs and the one open
  // decision the README puts first.  Until then every main-memory cycle ends
  // on the 4.25 us non-existent-memory timer instead of on a slave, and the
  // machine goes on running about a fifth slower; the header has the figures
  // and `make nomem` is what measured them.
  assign mem_done      = 1'b0;
  assign mem_rdata     = 32'd0;
  // And no port to answer anything, so the transaction audit's port clause is
  // silent by construction and its word 8 reads zero, which here is the truth.
  assign port_read_ack  = 1'b0;
  assign port_write_ack = 1'b0;

  // THE DISK.  On the other board a Linux program reads a pack file off the
  // card and fills the block store over `S_AXI_HP2`, and the card there is
  // wired only to the processing system.  **Digilent's master file for this
  // board constrains no card pins at all**, so answering this means an SD host
  // in fabric reading a card through one of the Pmod headers, with the pack at
  // a raw offset rather than as a file --- and that reopens who computes the
  // block headers and checkwords, which this project settled once for a board
  // that has Linux.
  // With `drive_present` at zero the status register answers `0x2321` --- not
  // on line, not on cylinder, no unit selected --- for every one of the boot
  // PROM's 11,301 polls, which is exactly what `build/machine.pass` compares.
  assign drive_present   = 8'd0;
  assign drive_read_only = 8'd0;
  assign drive_timed     = 1'b0;
  assign store_we        = 1'b0;
  assign store_slot      = 5'd0;
  assign store_addr      = 9'd0;
  assign store_wdata     = 32'd0;
  assign store_busy      = 1'b0;
  assign store_busy_slot = 5'd0;
  assign store_deny      = 1'b0;

  // THE CONSOLE.  On the other board it is sixteen diagnostic registers on
  // `M_AXI_GP1` and a program that halts, steps and inspects the machine.
  // There is no general-purpose port here and no program to put on one, so
  // what the console would be is undecided --- the README says so rather than
  // guessing.  With `con_req` and `con_msyn` down the arbiter inside
  // `cadr_memory_path` never grants, the mux folds to the processor's own
  // half, and the register block is what `build/machine.pass` compares.
  assign con_req   = 1'b0;
  assign con_msyn  = 1'b0;
  assign con_write = 1'b0;
  assign con_addr  = 18'd0;
  assign con_wdata = 16'd0;
  // And nothing asks the readout anything: the address stands at the reserved
  // selector, the machine answers `RO_NO_MEMORY` for ever, and both answers
  // fold below.
  assign con_ro_addr = 18'h3FFFF;

  // THE DEBUGGER.  MIT's debug cable reaches the machine's DBGIN page, and on
  // the other board there are two ways to it: a register window on
  // `M_AXI_GP1` with muir on the ARM cores playing the debugger, and a Pmod
  // carrier that takes a second board's cable.  **The carrier is pure fabric
  // and carries over to this board unchanged**; it is not built here because
  // a debugger with no debuggee at the other end is not worth a connector
  // yet, and this board's first question is whether the machine builds at
  // all.  The cable is levels and not pulses, so holding `-DEBUG IN REQ` UP
  // --- which is `dbg_in_req` low, the sense the whole transport uses --- is
  // exactly what the SIP at DBGIN 0A22 does to an unplugged connector.
  // `cadr_dbgin.sv` then makes no strobe, never asks for the bus, and the
  // whole arm of the arbiter folds.

  // THE I/O BOARD'S FOUR CABLES.  The keyboard, the mouse, the serial line
  // and the Chaosnet interface are all on the card inside `cadr_machine`, and
  // all four of their far ends are Linux programs on the other board.  A
  // fabric answer is a different thing for each: a UART on the board's own
  // USB-UART pins for the serial line, a MAC in fabric for Chaosnet, and a
  // USB host in fabric for the keyboard and mouse --- which this board has no
  // controller for at all, the other one's being the processing system's.
  //
  // **ALL ONES AND NOT ZERO ON THE MOUSE**: the seven lines are what the
  // MOUSE drives, each switch pulled to ground when pressed and each
  // quadrature line high at rest, so all ones is a cable with nothing moving
  // on it and zero would be three buttons held down for ever.
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

  // ------------------------------------------------- the machine's reset
  //
  // `rst` above is the MMCM's lock and BTN3.  The debug cable's modifier bit
  // 1 is the second term: MIT calls it "resets the debuggee's Unibus and bus
  // interface", it crosses the debuggee's own cables to OLORD2 and is that
  // processor's power-on reset, so a debugger's reset goes down the cable and
  // needs nothing else.  It is a LEVEL --- "write a 1 here then write a 0".
  // Nothing drives it on this board and the whole term folds; it is here so
  // that the day a debugger arrives, nothing in this file changes.
  //
  // **A REGISTER AND NOT A GATE.**  This lands on some two thousand registers
  // spread across `cadr_machine`, and a LUT between the term and that fanout
  // is a LUT on every one of their reset pins.  One tick later on a reset
  // costs nothing that anything counts, `rst` itself already being four
  // synchroniser stages deep.
  //
  // **AND IT MUST NOT REACH THE DBGIN PAGE THAT MAKES IT**: a modifier
  // register cleared by its own bit 1 clears the bit that is clearing it, and
  // MIT's sequence could not be written at all.  That page takes `rst`
  // instead, one level down, at `.dbg_rst` below.
  logic mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || debuggee_reset;

  // ------------------------------------------------- `-BOOT2`, the button
  //
  // On a CADR `-BOOT2` is a pulled-up line taken low by the momentary switch
  // on the light panel, through a section of the 74LS14 at OLORD2 1A20.  This
  // board has no panel and BTN0 is that switch.  **It is the only driver
  // here**, where the other board has a second one in the console's word 13,
  // so this is a light panel with one button on it.
  //
  // It is NOT registered, where `mach_rst` is: that register buys a shorter
  // path onto some two thousand reset pins, and `-BOOT2` reaches one gate
  // inside `cadr_machine`.
  logic n_boot2;
  assign n_boot2 = !btn0_level;

  // --------------------------------------------------- and the machine itself
  //
  // **THE PORT LIST IS THE OTHER BOARD'S, SIGNAL FOR SIGNAL.**  That is the
  // whole claim this file makes about the machine: nothing in `rtl/machine/`
  // knows which part it is on, so a second board is a second set of things
  // AROUND it and not a second machine.  An output left off this
  // instantiation is a Verilator PINMISSING, which is how `dev_wdata` was
  // found missing from the other board's, so `make build/arty_a7.pass` is
  // what holds the two lists together.
  cadr_machine #(
      .PROM_HEX(PROM_HEX)
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
      // The absence of a memory: see the tie-offs above.
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
      .timed_out(timed_out),
      .con_req(con_req), .con_gnt(con_gnt), .con_msyn(con_msyn),
      .con_write(con_write), .con_addr(con_addr), .con_wdata(con_wdata),
      .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      // MIT's debug cable.  The request side is the unplugged connector ---
      // see the tie-off block above --- and what the machine answers with is
      // folded, because a page that never asks never answers.
      .dbg_in_req(1'b0), .dbg_in_wr(1'b0), .dbg_in_a(2'd0), .dbd_in(16'd0),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset: the BOARD's --- MMCM lock and BTN3 ---
      // and not `mach_rst`, which `debuggee_reset` is one term of.  See the
      // reset above for why that distinction is not tidiness.
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code), .n_boot2(n_boot2),
      // SW0, synchronised, read at the machine's own reset arms and nowhere
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

  // ------------------------------------------------------------ the probe
  //
  // One sample a microcycle of the columns `build/rtl.golden` carries, held in
  // block RAM and shifted out over JTAG, so that what the *board* computes can
  // be diffed against what muir computes.  `rtl/plumbing/xilinx7/cadr_probe.sv`
  // is the whole of it and its header says why it is not an ILA.
  //
  // **IT CARRIES OVER TO THIS PART UNCHANGED.**  `BSCANE2` is a seven-series
  // primitive and the Artix-7 has it, with the same USER1 instruction ---
  // 000010, six bits --- that the Zynq's PL TAP has.  What differs is the
  // chain: this board presents ONE device where a Zynq presents the part and
  // the ARM debug access port, so the readout's padding is different and
  // `boards/arty-a7-100/vivado/probe.tcl` computes it from the chain it finds
  // rather than from a constant.
  //
  // **THE COLUMN LIST AND THE BIT LAYOUT ARE THAT FILE'S**, one port a column,
  // so that this file does not hold a second copy of them to drift.  What is
  // here is the two things only a top level can say: which net is which
  // column, and that `-VMAOK` is the trace's polarity where `cadr_machine`
  // brings out the logical one the jump conditions take.
  if (PROBE_DEPTH > 0) begin : g_probe
    // The JTAG scan chain the readout uses.  USER1 --- IR 000010 on a
    // seven-series part --- which `probe.tcl` selects by name and by code.
    //
    // RESET, RUNTEST, TCK, TMS and UPDATE are left empty because nothing here
    // reads them: the pointer moves on CAPTURE, so UPDATE is not needed, and
    // that is the point of moving it there.  See `cadr_probe.sv`.
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
        // The probe re-arms on a machine reset, which on this board is BTN3
        // or the boot button's own path --- its words are that it "fills from
        // the first microcycle after reset and freezes", so a machine that has
        // been restarted has new first microcycles and the probe must be
        // looking at those.
        .clk(clk), .rst(mach_rst),
        // ONE SAMPLE A MICROCYCLE, on the machine's own boundary.  A
        // free-running probe at 100 MHz would mostly record a machine standing
        // still and would line up with no row of anything.
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
  // `witness` is what keeps the machine alive through synthesis.  Every output
  // of `cadr_machine` folds into it, so none of them is dead, and it is
  // registered so the fold is not a combinational path across the design.  It
  // is not meant to be readable --- it is a load, and what it shows is that
  // the datapath is moving at all.
  //
  // **All of them, including the ones something else already reads** ---
  // `clock_edge`, `promdisable`, `timed_out`, `machrun` drive lamps as well
  // and are still here, because the rule the comment states is the whole
  // specification and a fold with exceptions in it is not a rule anybody can
  // check.  What checks it is `make build/arty_a7.pass`: an output left off
  // the instantiation is a Verilator PINMISSING.
  //
  // **AND IT DRIVES NO LAMP, SO IT SAYS SO TO THE TOOLS INSTEAD.**  Every one
  // of this board's lamp pins carries a meaning of the machine's and there is
  // no spare one to hang a load on.  A register nothing reads is trimmed, and
  // the whole machine behind it with it --- and then every fit and timing
  // figure this board reports is a figure for a design that is not there,
  // which is the loudest trap this project records.  `DONT_TOUCH` is the one
  // thing that keeps it without inventing a meaning for a lamp; it propagates
  // through the cone, which is exactly what is wanted.  The Verilator waiver
  // is beside it because lint's complaint is correct --- nothing reads this
  // --- and the answer is that nothing is meant to.  `cadr_arty_a7.xdc`
  // false-paths the register by name.
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
                   wrcyc, device, dev_rq, dev_write, promdisable,
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
                   dbg_in_ack, dbd_from_machine, dbd_oe, timeout_inhibit};
    end
  end

  // A microcycle is 29 ticks at normal speed and 44 at extra slow, which is
  // what the boot PROM runs at: 440 ns of real time at a 10 ns tick.  Bit 19
  // is 524,288 microcycles, 231 ms, about 2.2 Hz: fast enough to be obviously
  // alive and slow enough to count.
  logic [23:0] beat;
  always_ff @(posedge clk) begin
    if (mach_rst) beat <= 24'd0;
    else if (clock_edge) beat <= beat + 24'd1;
  end

  // AND A HEARTBEAT THAT DOES NOT DEPEND ON THE MACHINE.  Without it a dark
  // board means "not programmed", "the MMCM never locked" or "the machine
  // stalled", and those are three different problems that look the same.  This
  // counts the master clock and nothing else, so it blinks whenever the fabric
  // is clocked at all --- about 1.5 times a second at 100 MHz --- and it is
  // deliberately not reset by `rst`, because `rst` is held while the MMCM is
  // unlocked and a heartbeat that stopped during reset would lose the one case
  // it exists to distinguish.
  logic [25:0] tick;
  always_ff @(posedge clk) tick <= tick + 26'd1;

  // ================================== THE SIX LAMPS ==========================
  //
  // **THEY READ AS THE MACHINE'S OWN PROGRESS, AND NOT AS THE FABRIC'S
  // BRING-UP.**  The header's table says which pin each lands on, because
  // this board's silkscreen numbers its lamps the other way round from the
  // one this project's numbering was written against.
  //
  //   LD0  MACHRUN          the machine's own run signal as a LEVEL: lit means
  //                         it should be running.  `MACHRUN` is `(SSTEP AND
  //                         -SSDONE) OR (SRUN AND -ERRHALT AND -WAIT AND
  //                         -STATHALT)` at OLORD1 1A15, so it drops during
  //                         every memory stall --- which makes the lamp's
  //                         BRIGHTNESS the fraction of time the machine
  //                         computes rather than waits.  **On this board, with
  //                         nothing behind the memory port, it DIMS from
  //                         microcycle 536,303 onwards** --- every main-memory
  //                         cycle spends 4.25 us on the timer instead of 140 ns
  //                         on a slave --- which is the board saying what is
  //                         missing without stopping.
  //   LD1  the clock        `tick[25]`, the slow blink: the fabric is clocked.
  //                         Always blinking, on any board that is alive at
  //                         all, and it says nothing about the machine.
  //   LD2  microcycles      `beat[19]`, the fast blink: the machine is
  //                         executing.  It FREEZES when the machine stops,
  //                         which is the thing a level cannot say --- motion
  //                         cannot be faked, where a frozen fabric would still
  //                         hold a level high.  **It does not freeze on this
  //                         board**: with no memory the machine runs on, and
  //                         the lamp toggles every 0.14 s of machine time,
  //                         which is 0.28 s at the board's own 10 ns tick.
  //   LD3  disk activity    lit while the controller moves a block.  Dark for
  //                         ever here: there is no drive.
  //   LD4  ERRHALT          the machine halted ITSELF under ERRSTOP, which is
  //                         `(si:%halt)` and nothing else.  Dark normally, red
  //                         when it happens, and cleared by the boot button or
  //                         a reset.  See below.
  //   LD5  -PROMDISABLE     the mode register's own bit, inverted: LIT while
  //                         the machine runs its microcode out of the boot
  //                         PROM and DARK once it has loaded microcode from the
  //                         disk and set `PROMDISABLE`.  So lit means BOOTING
  //                         and dark means BOOTED, which is the way round a
  //                         lamp should be: the interesting state is the one
  //                         that ends.  **Lit for ever here**, for the same
  //                         reason LD3 is dark.  It is NOT `PROMENABLE`, which
  //                         is a different net; see below.
  //
  // LD0's level and LD2's blink say different things on purpose, and neither
  // replaces the other.
  //
  // ---------------------------------------------------------------- LD4
  //
  // **LD4 IS THE MACHINE'S OWN ERROR HALT AND NOTHING ELSE: IT IS EITHER OFF
  // OR RED.**  No other colour and no other meaning ever reaches it --- not at
  // power-on, not during the PROM, not while halted by a console.  Its green
  // and blue channels are tied off, so there is nothing for a later meaning to
  // be put on.
  //
  // `ERRHALT` is `ERRSTOP AND HALTED` at OLORD1 and is one of `MACHRUN`'s own
  // terms: the machine executed a halt with the console's error-stop bit set
  // and stopped itself.  On microcode 323 that is `(si:%halt)` reached through
  // `ILLOP`, `%HALT` and `ZERO`; MIT's own boards reach the same line from the
  // memory parity checkers, which this fabric does not have.
  //
  // **AND DARK IS THE GOOD STATE**, which is the whole argument for it: this
  // is the one lamp nobody should have to watch, and a lamp that means one
  // thing is read faster than one that means four.  It makes LD2's freeze
  // readable --- LD2 stopped with LD4 dark means somebody halted the machine,
  // LD2 stopped with LD4 red means it fell over.
  //
  // **AND THAT IS WHY A BUS TIMEOUT IS NOT ON IT, WHICH MATTERS MORE ON THIS
  // BOARD THAN ON ANY OTHER.**  The lamp used to be lit by a
  // non-existent-memory timeout as well, and on a board with no memory behind
  // the port EVERY main-memory cycle times out --- so the lamp would be red
  // within a second of every power-on, on a fabric that is doing exactly what
  // this board is built to do.  A lamp whose normal state is red says nothing.
  // The statistics halt and the disk store's silent denial came off it for the
  // reasons `rtl/plumbing/cadr_lamp_errhalt.sv` gives; the denial is a defect
  // of `rtl/machine/cadr_disk_controller.sv` and is open there.
  //
  // **CLEARED BY THE BUTTON AS WELL AS BY A RESET**, which is why `-BOOT`
  // comes out of the machine: a board booted at the button starts with a clean
  // lamp, and nothing out here has to know which source booted it.
  //
  // **THE LATCH IS A MODULE AND THE WIRING IS NOT, AND THAT SPLIT IS
  // DELIBERATE.**  `rtl/plumbing/cadr_lamp_errhalt.sv` is held by
  // `build/errhalt_lamp.pass`, because lint cannot tell a lamp that latches
  // from one that does not.  WHICH signal reaches its input is the line below,
  // and that line is reached by `build/arty_a7.pass`'s lint and by nothing
  // else --- so a second term ORed in here would be caught by nobody, and the
  // reason it is not there is this paragraph.
  logic errhalt_lit;
  cadr_lamp_errhalt u_lamp_errhalt (
      .clk(clk), .rst(mach_rst), .errhalt(errhalt), .n_boot(n_boot),
      .lit(errhalt_lit)
  );
  assign led0_r = errhalt_lit;
  assign led0_g = 1'b0;
  assign led0_b = 1'b0;

  // ---------------------------------------------------------------- LD5
  //
  // **`-PROMDISABLE`, AND THAT IS THE NAME OF THE SIGNAL ON THE PIN.**  The
  // lamps are named by the machine's own signals --- LD0 is `MACHRUN` and LD4
  // is `ERRHALT` --- and this one is `PROMDISABLE` inverted: bit 5 of the mode
  // register at OLORD1 1A08, which the machine sets itself once it has loaded
  // its microcode off the disk.
  //
  // **IT IS NOT `PROMENABLE`, AND THE TWO ARE DIFFERENT NETS.**  MIT's
  // `-PROMENABLE` at PCTL 1C19 is `BOTTOM.1K` with `PROMDISABLED`, `IWRITEDA`
  // and `-IDEBUG`, which is `cadr_microcycle.sv`'s `promenable` --- it says
  // whether THIS microinstruction is coming out of the PROM, so it follows the
  // PC and changes many times a boot.  What reaches this pin is the mode
  // register's own bit and nothing else.
  //
  // Blue, and blue only, for the one state it carries.  A colour lamp showing
  // one thing is still the right lamp for it: this is the answer to "has it
  // finished booting", which is worth telling apart from the four plain green
  // ones at a glance.
  assign led1_r = 1'b0;
  assign led1_g = 1'b0;
  assign led1_b = !promdisable;

  // The two tricolour lamps this board has and the assignment does not use.
  // Driven rather than left out of the port list, so that the port list
  // matches the board: a lamp with no meaning is dark, and a lamp with no
  // driver is a pin that cannot be placed.
  assign {led2_r, led2_g, led2_b} = 3'b000;
  assign {led3_r, led3_g, led3_b} = 3'b000;

  // **LD0 IS REGISTERED AND LD3 IS STRETCHED, AND NEITHER IS A CONVENIENCE.**
  //
  // `MACHRUN` is a six-input gate with `-WAIT`'s whole cone behind it, and a
  // pad is the one place in this design where a long combinational path buys
  // nothing: an LED is not sampled by anything, so a tick of delay is free and
  // the cone stops at a flip flop.  What the eye reads is unchanged --- the
  // lamp's brightness is still the fraction of ticks `MACHRUN` is up.
  //
  // **AND A DISK LIGHT NOBODY CAN SEE IS NOT A DISK LIGHT.**  `ch_active` is
  // up while the channel moves a block, which is 256 bus cycles of about
  // 150 ns --- some 38 us --- and a drive at thirty blocks a second lights it
  // for about a thousandth of the time.  That integrates to nothing.  So the
  // lamp is a one-shot: `DISK_LIT_T` ticks, about 42 ms of real time, re-armed
  // by every block.  Steady means the disk is busy, flickering means it is
  // being touched, and dark means it is idle, which is the light every
  // computer has had.  It is dark for ever on this board and the one-shot is
  // still built, because a lamp that is built and dark is a lamp, and one that
  // is optimised away is a hole in the fold.
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

  assign led[0] = machrun_lamp;  // the machine should be running; dim = stalling
  assign led[1] = tick[25];      // the fabric is clocked --- the slow blink
  assign led[2] = beat[19];      // microcycles retiring --- the fast blink
  assign led[3] = disk_lit;      // the disk controller is moving a block

  // btn[2:1] and sw[3:1] are pins the board has and this design does not use.
  // BTN0 is the machine's boot button, BTN3 the fabric's reset and SW0 the
  // no-auto-boot switch; the rest have no meaning here.  They are read here
  // only to keep them legal without inventing behaviour for them.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, btn[2:1], sw[3:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
