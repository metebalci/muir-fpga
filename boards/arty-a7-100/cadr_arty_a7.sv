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
// that left them unconnected would synthesize to almost nothing, place and
// route in seconds, and write a perfectly good bitstream of an empty part.
// So the wide outputs are reduced into one register, `witness`, which costs
// a handful of LUTs and keeps every one of them load-bearing.
//
// THE LAMPS, AND THE ONE THING ABOUT THEM THAT IS PECULIAR TO THIS BOARD.
// The six lamps this project assigns are the same six the other board
// carries, by MEANING.  What differs is the silkscreen: the Arty Z7-20 numbers
// its four plain green LEDs LD0 to LD3 and its two tricolor ones LD4 and
// LD5, and the Arty A7-100 numbers its four TRICOLOR ones LD0 to LD3 and its
// four plain green ones LD4 to LD7.  So the numbers on the two boards do not
// line up and the meanings do:
//
//   meaning                        this project   port here      A7 silkscreen
//   MACHRUN, as a level            LD0            led[0]         LD4
//   the fabric is clocked          LD1            led[1]         LD5
//   microcycles retiring           LD2            led[2]         LD6
//   disk activity                  LD3            led[3]         LD7
//   `ERRHALT`, red and only red    LD4            led0_{r,g,b}   LD0
//   `PROMENABLE`, blue only        LD5            led1_{r,g,b}   LD1
//   nothing; dark                  ---            led2_*, led3_* LD2, LD3
//
// This board has eight lamps where the six-lamp assignment wants six, so two
// tricolor ones are dark.  They are in the port list and driven to zero
// rather than left out, so that the port list matches the board.
//
// THE BUTTONS ARE THE SAME TWO ON EVERY BOARD HERE.  BTN0 is `-BOOT2`, the
// button MIT put on the CADR's light panel, debounced; BTN1 resets the
// fabric.  BTN2 and BTN3 are pins the board has and this design does not
// use.
//
// AND SW0 HOLDS THE MACHINE AT POWER-ON.  A CADR whose power has just come on
// has its clock stopped: `RUN` is clear, nothing is running, and the button on
// its light panel is what starts it.  This fabric comes up the other way by
// default, with `RUN` preset --- a board switched on runs its boot PROM ---
// which is what somebody switching a board on wants and what a board being
// brought up needs.  SW0 is how a board being worked on is asked for the other
// behavior instead, and `-BOOT` is what takes the hold off.  It is a
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
    // MIT's TV sync PROM, for the display: `rtl/machine/cadr_tv.sv`.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex",
    parameter int unsigned PROBE_DEPTH = 0,
    // ---------------------------------------------------- MAIN MEMORY
    //
    // `DDR` puts the board's own 256 MB of DDR3L behind the machine's memory
    // port, through the controller `boards/arty-a7-100/cadr_a7_memory.sv`
    // wraps.  Off by default, because the measured board this directory
    // describes is the memory-off one and because a memory controller is much
    // the largest thing in the design.
    //
    // `PROVE` is the proving witness in place of the machine, and it is the
    // Arty Z7-20's own two steps ported: 1 writes a known word at a known
    // address and 2 reads it and echoes it somewhere else.  On that board the
    // observer was the debugger reading DDR through the processing system; on
    // this one there is no such door, so the observer is the JTAG window
    // `rtl/plumbing/cadr_jtag_mem.sv`, whose header says what that costs and
    // what makes the instrument sharp anyway.  A `PROVE` board is a `DDR`
    // board with the machine's own port answered by nothing.
    parameter int unsigned DDR   = 0,
    parameter int unsigned PROVE = 0,
    // **THE SOFT PROCESSING SYSTEM.**  With it, `rtl/plumbing/cadr_soc.sv` is
    // in the design and masters the register faces the Zynq's ARM cores
    // master on the other two boards: the console, the disk pack side and the
    // default slave, at the addresses the Linux programs already use.  **NOT
    // the debug cable's register window**, which is the one face of the four
    // this board does not have: it is how a PROGRAM plays the far end of MIT's
    // cable, and this board's debugger is a second board on the Pmod instead.
    // `rtl/plumbing/cadr_soc_axi.sv`'s parameter list has the argument, and
    // the catch-all answers that page "NONE" like any other address nothing
    // implements.  Without `SOC` this is the machine and its tie-offs,
    // which is what every figure in `boards/arty-a7-100/README.md` was
    // measured on.
    //
    // **OFF BY DEFAULT, AND BOTH WAYS ARE LINTED.**  A branch only one build
    // reaches is a branch only one build checks --- this file's own note about
    // `PROBE_DEPTH` says so --- so `make build/arty_a7.pass` runs a pass with
    // it on as well as the two without.
    parameter int unsigned SOC = 0,
    parameter string FIRMWARE_HEX = "build/soc_firmware.hex",
    // 32 KB.  See `cadr_soc_ram.sv`; it must agree with `LENGTH` in
    // `boards/arty-a7-100/firmware/link.ld`, and `tools/bin2hex.py` is what
    // refuses an image that does not fit.
    parameter int unsigned SOC_RAM_WORDS = 8192,
    parameter int unsigned SOC_BAUD = 115_200,

    // **THE SECOND DISPLAY BOARD, THE COLOR TV**, `lmtv.order`'s "for the
    // color TV, x is 5": a LISPM TV strapped to 0o17200000 with its control
    // words at 0o17377750, carrying a color monitor of its own.  One means
    // the fabric has the slot; whether a machine HAS the board is the
    // console's page 2 word 33, which `fpgarc`'s `--color-tv` writes at
    // boot, and a machine with none gives the NXM at those addresses ---
    // which is how `COLOR-EXISTS-P` finds out.  Zero leaves the slot out of
    // the fabric entirely, for a part with no room for it.
    parameter int unsigned LMTV = 1
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
    // The four tricolor LEDs, Digilent's names and the board's silkscreen
    // LD0 to LD3.  Driven high to light, one pin a color.  The first two
    // carry this project's LD4 and LD5; the other two are dark.
    output var logic       led0_r, led0_g, led0_b,
    output var logic       led1_r, led1_g, led1_b,
    output var logic       led2_r, led2_g, led2_b,
    output var logic       led3_r, led3_g, led3_b,

    // ------------------------------------------------------ the DDR3L
    //
    // **THESE ARE IN THE PORT LIST WHATEVER `DDR` SAYS**, which is the Arty
    // Z7-20's rule for its HDMI pairs, said there as "a port that exists only
    // in one configuration is a port list that differs between two builds of
    // one file".  With `DDR` off they are driven to the state that holds the
    // memory part in reset and does nothing, and
    // `boards/arty-a7-100/cadr_a7_ddr_off.xdc` is what constrains them then.
    // With `DDR` on the controller drives them and the generated
    // `cadr_mig_a7.xdc` constrains them, which is where their slew rates,
    // input terminations and the two clock pins' bufferless treatment come
    // from --- none of which is meaningful without the controller's own
    // physical layer behind it, and which is why there are two files and not
    // one.
    //
    // The names are the generator's, so that this port list can be checked
    // against `boards/arty-a7-100/mig/gen/.../cadr_mig_a7.veo` by eye.
    inout  wire  [15:0]    ddr3_dq,
    inout  wire  [1:0]     ddr3_dqs_p,
    inout  wire  [1:0]     ddr3_dqs_n,
    output var logic [13:0] ddr3_addr,
    output var logic [2:0] ddr3_ba,
    output var logic       ddr3_ras_n,
    output var logic       ddr3_cas_n,
    output var logic       ddr3_we_n,
    output var logic       ddr3_reset_n,
    output var logic [0:0] ddr3_ck_p,
    output var logic [0:0] ddr3_ck_n,
    output var logic [0:0] ddr3_cke,
    output var logic [0:0] ddr3_cs_n,
    output var logic [1:0] ddr3_dm,
    output var logic [0:0] ddr3_odt,
    // **THE BOARD's USB-UART BRIDGE, AND THE NAMES READ BACKWARDS.**  They are
    // Digilent's and they are from the HOST's point of view:
    // `uart_rxd_out` (D10) is what the FPGA drives and the bridge receives,
    // `uart_txd_in` (A9) is what the bridge drives and the FPGA receives.  So
    // the soft processing system's transmitter leaves on the first and its
    // receiver listens on the second.  **The Arty Z7-20 constrains no UART
    // pins at all**: there the serial hardware is the processing system's.
    //
    // They are in the port list whether or not `SOC` is set, so that the port
    // list matches the board rather than the configuration, which is the rule
    // the two dark tricolor lamps above are here by.  With the soft system
    // absent the transmitter idles high, which is a line with nothing on it.
    output var logic       uart_rxd_out,
    input  var logic       uart_txd_in,

    // **MIT'S DEBUG CABLE ON ONE PMOD HEADER, AND ON THIS BOARD IT IS JB.**  A
    // board is a debugger or a debuggee on this cable and never both at once,
    // so one connector is enough; the other three headers carry nothing of
    // this design's, and JD is where the card this board has no slot for is to
    // go.
    //
    // **JB RATHER THAN THE JA THE TWO ZYNQ BOARDS USE, AND THE BOARD DECIDES
    // IT.**  This is the only board here with four Pmod headers and the only
    // one where they are not all alike.  Digilent publishes JB and JC as this
    // board's HIGH-SPEED Pmod ports and JA and JD as STANDARD ones, which is a
    // series resistor in line with every signal; that half is the vendor's own
    // description of the board and is not measured here.  **What IS checkable
    // here is in the pin file, and it agrees twice over.**  That file names
    // JB's and JC's pins `jb_p[1]`..`jb_n[4]` and `jc_p[1]`..`jc_n[4]`, which
    // is how it names a coupled pair, and names JA's and JD's plain
    // `ja[1]`..`ja[10]` and `jd[1]`..`jd[10]`.  And the pins bear it out: all
    // four of JB's header rows --- pins 1 and 2, 3 and 4, 7 and 8, 9 and 10 ---
    // are true differential pairs of bank 15, two of them clock-capable
    // (`SRCC` on the first, `MRCC` on the second), while NOT ONE of JA's four
    // rows is a pair at all, its differential pairs straddling the rows
    // instead.
    //
    // The strobe at the far end of a ribbon is what this link rests on, so it
    // goes on a high-speed port.  **The card stays on JD**, the other standard
    // port, and is right there: a microSD module plugs straight into the
    // header with no ribbon between it and the part, and SPI at tens of
    // megahertz over an inch of board does not care about a series resistor.
    //
    // Eight pins, four each way, and only TWO of each four carry signals: the
    // header's rows are coupled pairs, so each pair takes one signal --- a
    // strobe on the first, one data line on the second --- and the other line
    // of each is a GUARD driven low beside it.
    // `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` under
    // `rtl/plumbing/cadr_dbg_cable.sv`, which owns the map.
    // A straight Pmod ribbon joins pin one to pin one, so the LOW four are
    // the debugger's at both ends and the HIGH four the debuggee's.  The
    // eighth wire is a STROBE and not a clock: nothing on either side is
    // clocked by it.
    //
    // **THEY ARE BIDIRECTIONAL PADS AND THEY HAVE TO BE**, because the role
    // is not fixed at synthesis.  They are in the port list whether or not
    // `SOC` is set, for the reason the UART's two are: a board is always a
    // DEBUGGEE and answers a debugger that plugs in, which needs no soft
    // processing system at all.  `boards/arty-a7-100/cadr_arty_a7.xdc` has
    // the pins, from Digilent's own published file.
    inout  wire  [7:0]     jb
);

  // ------------------------------------------------------------ the clock
  //
  // 100 MHz in, 100 MHz out, through an MMCM rather than a wire --- the
  // header says why.  The VCO must sit between 600 and 1200 MHz on a -1 part:
  // 100 x 10 is 1000, in the middle of the range, and 1000 / 10 is the tick.
  logic clk_fb, clk_raw, clk, mmcm_locked;

  // **AND ONE MORE OUTPUT, FOR THE MEMORY CONTROLLER, OFF THE SAME MANAGER.**
  // The generated DDR3L controller wants a system clock and a 200 MHz
  // reference for its input delay calibration, and it is configured "No
  // Buffer" for both --- it is given clocks rather than pins.  Digilent's own
  // published project file takes E3 for its system clock, which cannot be done
  // here: this manager already has that pad, and two input buffers on one pad
  // is an error.  `boards/arty-a7-100/mig/README.md` records that as one of the
  // three changes made to their file.
  //
  // The voltage-controlled oscillator is 1000 MHz exactly, so the divider
  // reads as a frequency: 5 is 200 MHz.
  //
  // **AND THE CONTROLLER'S SYSTEM CLOCK IS THE MACHINE'S OWN 100 MHz**, not a
  // fourth output of its own.  It is the same frequency either way, the
  // controller's phase-locked loop is one more load on a global clock net that
  // already drives some thousands of registers, and a second net at the same
  // frequency would be a second thing to keep in step.  What the controller
  // makes from it is its own business: 100 x 13 = 1300 MHz, over four for a
  // 325 MHz memory clock, over four again for its 81.25 MHz user clock.
  //
  // `boards/arty-z7-20/vivado/tick.tcl` reads four parameters out of this
  // instantiation and computes the period the constraints are written
  // against.  `CLKOUT1_DIVIDE` is not among them and cannot move the tick; the
  // file matches `CLKOUT0_DIVIDE_F` by name.
  logic clk_ref_raw, clk_ref;

  // **AND A THIRD OUTPUT, FOR THE SOFT PROCESSING SYSTEM, WHICH IS SLOWER
  // THAN THE MACHINE ON PURPOSE.**  Ibex computes a load or a store's address
  // in the cycle it uses it --- the decoder, the operand multiplexers and the
  // main ALU's adder between the instruction register and the memory's address
  // pin --- and on this part that arc is about 12.9 ns.  At the machine's
  // 10 ns tick it misses by three, and it is not a path a constraint may
  // relax: it is one cycle of a processor and it is meant to be.  The
  // machine's tick cannot move, every instant in `rtl/machine/` being a count
  // of them, so the soft system gets a clock of its own and the seam between
  // the two becomes a clock domain crossing ---
  // `rtl/plumbing/cadr_soc_cross.sv`, with `rtl/plumbing/xilinx7/cadr_soc.xdc`
  // telling the fitter the same thing.
  //
  // **THE ONE PLACE THE SOFT SYSTEM'S CLOCK IS DECIDED.**  The voltage
  // controlled oscillator is 1000 MHz exactly, so this divider reads literally
  // as the frequency in megahertz: 20 is 50 MHz.  `boards/arty-a7-100/README.md`
  // carries what was measured at which divider and why this is the number.
  // It is NOT one of the four `boards/arty-z7-20/vivado/tick.tcl` reads: it
  // cannot move the machine's tick, and that file matches `CLKOUT0_DIVIDE_F`
  // by name.
  localparam int unsigned SOC_CLK_DIVIDE = 20;
  localparam int unsigned SOC_CLK_HZ     = 1_000_000_000 / SOC_CLK_DIVIDE;
  logic clk_soc_raw, clk_soc;

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
      .CLKOUT0_DIVIDE_F(10.000),  // 100 MHz, one tick = 10 ns
      .CLKOUT1_DIVIDE  (5),       // 200 MHz, the controller's IDELAY reference
      .CLKOUT2_DIVIDE  (SOC_CLK_DIVIDE)  // the soft processing system's own
  ) u_mmcm (
      .CLKIN1  (sysclk),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_raw),
      .CLKOUT1 (clk_ref_raw),
      .CLKOUT2 (clk_soc_raw),
      .LOCKED  (mmcm_locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .CLKFBOUTB()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  BUFG u_bufg (.I(clk_raw), .O(clk));

  // The controller's reference, on a global buffer of its own.  With `DDR`
  // off nothing reads it and the fitter takes the whole branch out, buffer and
  // clock manager output together.
  BUFG u_bufg_ref (.I(clk_ref_raw), .O(clk_ref));

  // The soft system's, likewise: with `SOC` clear nothing reads it and the
  // buffer and the manager's output go with the generate block.
  BUFG u_bufg_soc (.I(clk_soc_raw), .O(clk_soc));

  // ------------------------------------------------------------- the buttons
  //
  // **BTN0 BOOTS THE MACHINE AND BTN1 RESETS THE FABRIC**, which is every
  // board's assignment here.  The CADR's own way to restart is the boot
  // button on its light panel, and a person at this board pressing the button
  // nearest to hand should get what a person at a CADR pressing the button
  // gets --- the machine back at the boot PROM with its memory intact --- and
  // not the fabric reconfigured out from under them.  So BTN0 is `-BOOT2`,
  // and BTN1 beside it is the one control that throws away the machine's
  // whole state.  BTN2 and BTN3 are pins the board has and this design does
  // not use.
  //
  // **AND ON THIS BOARD THE FABRIC RESET IS THE ONLY RESET THERE IS.**  It
  // resets the logic in the fabric --- the machine, the register faces and
  // the lamps --- and it does not reload the bitstream.  On the Zynq boards
  // that distinction matters, because the processing system and Linux keep
  // running across it and the programs under Linux are then out of step with
  // the fabric until they are restarted; there, `rst -srst` over JTAG is the
  // reset to reach for.  Here there is no processing system, nothing else can
  // reset the fabric, and this button is it.
  //
  // Pins: `btn[0]` is D9 and `btn[1]` is C9, both `LVCMOS33`, from Digilent's
  // `Arty-A7-100-Master.xdc`.  `cadr_arty_a7.xdc` carries them and false-paths
  // all four, a human's finger being no timing constraint.
  //
  // Reset while the MMCM has not locked, and on BTN1.  Synchronized out of the
  // 100 MHz domain: `LOCKED` is asynchronous to it by construction.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked || btn[1]};
  assign rst = rst_sync[3];

  // ------------------------------------------------------ BTN0, DEBOUNCED
  //
  // **A RESET DOES NOT NEED DEBOUNCING AND A BOOT DOES.**  BTN1's four
  // synchronizer stages are all its job wants: a reset asserted for a
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
  // Three synchronizer stages, because the switch is asynchronous to this
  // clock like every other pin.  No debounce: `-BOOT2` needs one because a
  // bounce on the RELEASE is another press, and this is a level read once, at
  // an instant a slide switch is not being moved at.
  //
  // Pin: `sw[0]` is A8, `LVCMOS33`, `IO_L12N_T1_MRCC_16`, Sch=sw[0], from
  // Digilent's `Arty-A7-100-Master.xdc`.  `cadr_arty_a7.xdc` carries it and
  // false-paths all four switches, a slide switch being no timing constraint.
  //
  // **AND THE VALUE THE MACHINE ACTUALLY CAME UP WITH IS FROZEN**, so that a
  // console can report it.  `sw0_held` follows the synchronized level at every
  // edge `mach_rst` is up and freezes at the last of them --- the same edge,
  // off the same signal, as the two reset arms inside the machine --- so the
  // two cannot disagree.  The comment above used to say this register was not
  // built here because there was no console to report it to; there is one now.
  logic [2:0] sw0_sync;
  logic       sw0_level;
  logic       sw0_held;
  always_ff @(posedge clk) sw0_sync <= {sw0_sync[1:0], sw[0]};
  assign sw0_level = sw0_sync[2];
  always_ff @(posedge clk) if (mach_rst) sw0_held <= sw0_level;

  // ------------------------------------------- the proving board's three
  //
  // **THE OTHER BOARD'S, UNCHANGED, AND THAT IS THE POINT.**
  // `boards/arty-z7-20/cadr_arty.sv` chose them and its header says why each
  // one: an address that is not the region's base, whose bit 2 is set so the
  // word is not the first lane of its beat, and whose bits alternate so a
  // dropped one moves it somewhere unrelated; a word of four distinct bytes,
  // neither half a rotation of the other; and an echo address seven beats away
  // with bit 2 clear, so a read takes a high lane and the write-back opens a
  // low one.  Every one of those arguments is about the arithmetic between a
  // byte address and a memory's own word, which is what this board's
  // `cadr_mig_ui` does and the other board's `cadr_axi_widen` did.
  localparam logic [31:0] PROVE_ADDR = cadr_ddr_map::main_byte_address(22'o12345671);
  localparam logic [31:0] PROVE_WORD = 32'h8A5C_36E1;
  localparam logic [31:0] PROVE_ECHO = cadr_ddr_map::main_byte_address(22'o12345706);

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
  logic        soc_uart_tx, hp_fold;
  // The join's other arm, which on the two Zynq boards is the debug cable's
  // register window and on this board is nobody at all.  It is tied idle
  // below, whatever `SOC` says; see the tie-off.
  logic        dbg_in_req, dbg_in_wr;
  logic [1:0]  dbg_in_a;
  logic [15:0] dbd_to_machine;
  // The console's half of the diagnostic bus.
  logic        con_req, con_gnt, con_msyn, con_write, con_ssyn;

  // **WHICH DISPLAY BOARDS THE BACKPLANE HAS**, out of the console's page 2
  // word 33, and the two boards' color maps coming back on pages 4 and 5.
  // A board with no console is a machine with one SIMPLE TV and no color TV,
  // which is muir's own default and the backplane every reference trace
  // taken before the second board was built was taken on.
  logic        con_tv_lispm, con_color_tv;
  logic [3:0]  con_tv_map_a;
  logic [23:0] con_tv_map_q, con_tv_color_map_q;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  // MIT's debug cable, the DBGIN connector's twenty-one wires.
  logic        dbg_in_ack;
  logic [1:0]  dbd_oe;
  logic [15:0] dbd_from_machine;
  // And the same cable again, as Pmod JB carries it.  `cab_*` is a second
  // board's debugger arriving at this machine's DBGIN page, through
  // `rtl/plumbing/cadr_dbg_join.sv` whose other arm is empty on this board;
  // `dbgout_*` is this machine's
  // own DBGOUT page going the other way, which is CC on this board debugging
  // a second one.  `dbg_connect` is what the console asks for and the four
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
  logic [7:0]  jb_o, jb_t;
  logic        mdbg_req, mdbg_wr;
  logic [1:0]  mdbg_a;
  logic [15:0] mdbg_dbd;
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
  //
  // **AND IT IS NO LONGER THE ONLY ANSWER.**  With `DDR` set the board's own
  // 256 MB of DDR3L answers it, through Xilinx's Memory Interface Generator in
  // the fabric.  The wiring is in "main memory, and the observer that can
  // reach it" below, after the machine's reset, because it needs that reset;
  // `mem_done`, `mem_rdata` and the audit's two port pulses are driven there
  // and are deliberately not driven here.

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
  //
  // **AND WITH `SOC` SET THE PACK SIDE IS HERE AND THESE ARE NOT TIED OFF.**
  // The register face answers, so a firmware can read its IDENT and post a
  // block's address; what is still missing is a memory for it to fetch the
  // block FROM, which is the memory controller this board does not have yet.
  // The generate below the machine is where both halves are.

  // THE CONSOLE.  On the other board it is sixteen diagnostic registers on
  // `M_AXI_GP1` and a program that halts, steps and inspects the machine, and
  // this note used to say that what a console would be here was undecided.
  // **IT IS DECIDED AND IT IS BUILT**: `rtl/plumbing/cadr_console.sv` is the
  // same module at the same `REG_BASE`, and what masters it is
  // `rtl/plumbing/cadr_soc.sv` instead of a Zynq --- so `console_face.h`'s
  // `0x8000_0000` is as true of this board as of that one, and the firmware
  // compiles the very same driver.  With `SOC` clear it is not in the design
  // and the lines below are the tie-offs; the generate under the machine has
  // both halves.

  // THE DEBUGGER.  MIT's debug cable reaches the machine's DBGIN page, and on
  // the two Zynq boards there are two ways to it: a register window on
  // `M_AXI_GP1`, with muir on the ARM cores playing the debugger in software,
  // and a Pmod carrier that takes a second board's cable.  **THIS BOARD HAS
  // ONLY THE SECOND, AND THAT IS A DECISION AND NOT A GAP.**  The window is
  // there so that a PROGRAM can be the far end of the cable, and the only
  // program on this board is the firmware, which is the console.  Its
  // debugger is another board over the Pmod --- which is the whole of what
  // the connector is for, and which needs no `SOC` at all, a CADR being
  // always a debuggee.
  //
  // So `rtl/plumbing/cadr_debug_window.sv` is not instantiated here in any
  // configuration, `0x8000_1000` is an address the catch-all answers "NONE"
  // like any other, and the join below has the connector for its only master.
  // `rtl/plumbing/cadr_soc_axi.sv`'s parameter list carries the argument and
  // `tb/cadr_soc_tb.cpp` asserts both halves of it.
  //
  // The cable is levels and not pulses, so holding `-DEBUG IN REQ` UP --- which
  // is `dbg_in_req` low, the sense the whole transport uses --- is exactly
  // what the SIP at DBGIN 0A22 does to an unplugged connector.
  // `cadr_dbgin.sv` then makes no strobe and never asks for the bus.

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
  assign chaos_rx_lost  = 1'b0;
  assign chaos_tx_done  = 1'b0;
  assign chaos_tx_abort = 1'b0;
  assign chaos_cbl_busy = 1'b0;
  assign kbd_strobe     = 1'b0;
  assign kbd_code       = 24'd0;
  assign mouse_lines    = 7'h7F;

  // ------------------------------------------------- the machine's reset
  //
  // `rst` above is the MMCM's lock and BTN1.  The debug cable's modifier bit
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
  // synchronizer stages deep.
  //
  // **AND IT MUST NOT REACH THE DBGIN PAGE THAT MAKES IT**: a modifier
  // register cleared by its own bit 1 clears the bit that is clearing it, and
  // MIT's sequence could not be written at all.  That page takes `rst`
  // instead, one level down, at `.dbg_rst` below.
  //
  // **AND A THIRD TERM ON THE MEMORY BOARD**, `window_mach_reset`, which is
  // the debugger holding the machine still while it poisons memory through
  // the JTAG window.  It resets the MACHINE and not the memory controller, so
  // what is in DDR survives it --- which is the whole reason it exists, and
  // "main memory, and the observer that can reach it" below is where it comes
  // from.  With no window in the design it is a constant and folds.
  //
  // **AND THE CONSOLE's WORD 6 IS A FOURTH.**  It is a pulse of
  // `RESET_T` ticks made inside `cadr_console.sv` and it joins the others rather
  // than replacing any: a board has a reset button and a debugger has a
  // cable and a console has a register, and all three are the same reset.
  // Zero when there is no soft processing system, so the term folds.
  logic mach_rst;
  logic window_mach_reset;
  always_ff @(posedge clk)
      mach_rst <= rst || debuggee_reset || window_mach_reset || con_mach_rst;

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
  //
  // **AND THE CONSOLE's WORD 13 IS A SECOND FINGER ON IT**, which is what the
  // other board has and this one did not.  `-BOOT2` is a pulled-up line and
  // two drivers may take it low; what the console brings out is "the button is
  // down", so the inversion is here at the gate and not there.  This is a
  // light panel with two buttons on it now, one of them on the network.
  logic n_boot2;
  assign n_boot2 = !(btn0_level || con_boot);

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
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX),
      .LMTV(LMTV)
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
      // And which display boards are in it, from the console face.
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
      .tv_map_a(con_tv_map_a), .tv_map_q(con_tv_map_q),
      .tv_color_map_q(con_tv_color_map_q),
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
      // MIT's debug cable, arriving at this machine's DBGIN page through
      // `rtl/plumbing/cadr_dbg_join.sv`.  On the two Zynq boards that join has
      // two arms, the register window and the connector; here it has one, Pmod
      // JB, which is a second board.  The window's arm is tied idle below in
      // every configuration, this board having no program that could be a
      // debugger.
      .dbg_in_req(mdbg_req), .dbg_in_wr(mdbg_wr), .dbg_in_a(mdbg_a),
      .dbd_in(mdbg_dbd),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      // And the other end of the same cable: the DBGOUT page, this machine
      // as somebody else's debugger.  `rtl/plumbing/cadr_dbg_cable.sv` below
      // puts it on Pmod JB when this board has the role, and answers it with
      // the pull-ups when nothing is plugged in.
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(dbgout_ack),
      .dbgout_dbd_in(dbgout_dbd_in), .dbgout_live(dbgout_live),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset: the BOARD's --- MMCM lock and BTN1 ---
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
      .chaos_rx_lost(chaos_rx_lost),
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

  // ========== main memory, and the observer that can reach it ==============
  //
  // **THIS IS THE FIRST MAIN MEMORY IN THIS REPOSITORY THAT IS NOT A
  // PROCESSING SYSTEM'S.**  On the Arty Z7-20 the machine's `mem_*` goes into
  // `cadr_axi_master`, then `cadr_axi_widen`, then `S_AXI_HP0` and the Zynq's
  // own DDR controller.  Here the DDR3L is on the fabric's pins and the
  // controller is Xilinx's Memory Interface Generator, generated in batch from
  // a project file in the repository --- this project's one generated-IP
  // exception, and `boards/arty-a7-100/mig/README.md` is the argument for it.
  //
  // Everything above `mem_*` is unchanged.  `cadr_xbus_ddr` asks for a word at
  // a byte address and waits, `cadr_ddr_map`'s constants are the ones they
  // have always been, and nothing in `rtl/machine/` knows which board it is
  // on.  What is new is three modules, each with a testbench:
  // `cadr_jtag_mem` in front of the port, `cadr_mem_cross` across the two
  // clocks and `cadr_mig_ui` onto the controller's user interface.
  //
  // **WHERE THE MACHINE'S 128 MB LANDS, AND WHY THE MAP DOES NOT MOVE.**
  // `cadr_ddr_map` reserves 0x1800_0000 upwards --- 64 MB of main memory and
  // 8 MB of display inside a 128 MB reservation --- which is a Zynq layout,
  // where the bottom 384 MB is Linux's.  This board has 256 MB and no Linux,
  // so the same reservation goes at the TOP of the chip, which is where it is
  // on the other board too, and the translation is one constant bit rather
  // than a subtraction: `cadr_mig_ui` does it and its header has the
  // arithmetic.  Main memory is therefore the sixteen megabytes at DDR byte
  // 0x0800_0000 and the display's window the eight at 0x0C00_0000, of which
  // the machine can reach 15 MB and 128 KB.  **The bottom 128 MB is nobody's
  // yet** and is where a soft processor beside the machine would live.
  //
  // **AND THE OBSERVER IS A JTAG REGISTER BECAUSE THERE IS NOTHING ELSE.**
  // Every claim this project has made about a memory path on silicon rests on
  // an observer outside the design: on the other board, a debugger reading DDR
  // through a different port of the same controller.  An Artix-7 has no debug
  // access port onto memory and no second master anywhere, so the debugger is
  // given a path instead --- one data register on a second `BSCANE2` user
  // chain, in front of the port, taking it when the machine is not using it.
  // `rtl/plumbing/cadr_jtag_mem.sv`'s header says plainly what that costs in
  // evidence and what makes the instrument sharp anyway, and the three things
  // that do are all the host's: an injective poison, all four lanes of a
  // sixteen-byte block written differently, and a tally that is not on this
  // path at all.
  if (DDR == 0 && PROVE == 0) begin : g_no_memory

    assign mem_done       = 1'b0;
    assign mem_rdata      = 32'd0;
    // No port to answer anything, so the transaction audit's port clause is
    // silent by construction and its word 8 reads zero, which here is true.
    assign port_read_ack  = 1'b0;
    assign port_write_ack = 1'b0;

    // The memory part held in reset and doing nothing: clock enable low, chip
    // not selected, reset asserted, and the bidirectional lines let go.  This
    // is the state a board with no controller should present to a DDR3 part,
    // and it is not merely "zero everywhere" --- `ddr3_cs_n` and
    // `ddr3_reset_n` are the two that are active low and the two that matter.
    assign ddr3_addr    = 14'd0;
    assign ddr3_ba      = 3'd0;
    assign ddr3_ras_n   = 1'b1;
    assign ddr3_cas_n   = 1'b1;
    assign ddr3_we_n    = 1'b1;
    assign ddr3_reset_n = 1'b0;
    assign ddr3_ck_p    = 1'b0;
    assign ddr3_ck_n    = 1'b0;
    assign ddr3_cke     = 1'b0;
    assign ddr3_cs_n    = 1'b1;
    assign ddr3_dm      = 2'b11;
    assign ddr3_odt     = 1'b0;
    assign ddr3_dq      = 16'dz;
    assign ddr3_dqs_p   = 2'bz;
    assign ddr3_dqs_n   = 2'bz;

    // No window, so nothing out here holds the machine still.
    assign window_mach_reset = 1'b0;

    // And the reference clock the controller would have calibrated its input
    // delays against.  Named rather than left dangling; the fitter takes the
    // whole branch out, the buffer and the clock manager's output with it.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_clk;
    assign unused_clk = &{1'b0, clk_ref};
    /* verilator lint_on UNUSEDSIGNAL */

  end else begin : g_memory

    // The port behind the window: one 32-bit word a request, in the machine's
    // own clock.  `cadr_a7_memory` is what carries it across into the
    // controller's.
    logic        port_req, port_write, port_done, port_error;
    logic [31:0] port_addr, port_wdata, port_rdata;
    logic [63:0] tally;
    logic        calib_done, prove_arm;
    logic        prove_has_run, prove_matched;

    // ...and the window's machine-side face, which is whatever is driving the
    // port today: the machine itself, or the proving witness in its place.
    logic        w_req, w_write, w_done;
    logic [31:0] w_addr, w_wdata, w_rdata;
    logic        w_error;

    // ------------------------------------------------- who drives the port
    //
    // THE MACHINE, or the witness that goes ahead of it.  `cadr_prove`'s
    // header has the argument for the two steps; what belongs here is only
    // that the witness drives `mem_*`'s own wires into the same window, the
    // same crossing, the same user interface and the same controller that the
    // machine will --- a witness with a path of its own would prove that path
    // and say nothing about this one.
    if (PROVE == 0) begin : g_machine_drives

      assign w_req    = mem_req;
      assign w_write  = mem_write;
      assign w_addr   = mem_addr;
      assign w_wdata  = mem_wdata;
      assign mem_done  = w_done;
      assign mem_rdata = w_rdata;

      assign prove_has_run = 1'b0;
      assign prove_matched = 1'b0;

      // THE AUDIT'S TWO PORT PULSES.  `cadr_machine`'s transaction audit wants
      // one pulse per transaction the port answered, in the machine's clock,
      // so that it can say whether the port answered anything the machine did
      // not ask for.  The port answers in ANOTHER clock here, and a pulse does
      // not survive a clock crossing --- but a LEVEL does, and `mem_done` is
      // the far side's acknowledgment carried back by `cadr_mem_cross`, one
      // rise per transaction and no more.  So the rise is the pulse.
      logic done_q;
      always_ff @(posedge clk) done_q <= w_done;
      assign port_read_ack  = w_done && !done_q && !w_write;
      assign port_write_ack = w_done && !done_q &&  w_write;

    end else begin : g_prove

      // A LEVEL, AND WHAT HOLDS IT UP DECIDES WHETHER ANYBODY HAS TO BE HERE.
      // `cadr_prove` runs one sequence per rise of `go` and needs it to fall
      // before another, so a `go` tied high is exactly one sequence when the
      // reset lets go.
      //
      // **AND ON THIS BOARD THE RESET IS THE DEBUGGER'S**, where on the Arty
      // Z7-20 it was the processing system raising `SAXIHP0ARESETN`.  That is
      // not a convenience: the debugger must poison the neighborhood BEFORE
      // the witness writes into it, and poisoning goes through the same window
      // the witness's port does.  So the witness is held until the `arm` bit
      // is scanned in, and every later rise of that bit runs the whole
      // sequence again with no reprogramming --- which is exactly what
      // toggling `LVL_SHFTR_EN` bought on the other board.
      logic [3:0] arm_t;
      logic       armed;
      always_ff @(posedge clk) begin
        if (rst) begin
          armed <= 1'b0;
          arm_t <= 4'd0;
        end else if (prove_arm) begin
          armed <= 1'b1;
          arm_t <= 4'hF;
        end else if (arm_t != 4'd0) begin
          arm_t <= arm_t - 4'd1;
        end
      end

      cadr_prove u_prove (
          // The three constants the whole exercise is about, tied here
          // because this is the file that chose them --- and they are the
          // other board's, unchanged, so that the two boards' proving steps
          // are one exercise and not two.
          .addr     (PROVE_ADDR),
          .word     (PROVE_WORD),
          .echo_addr(PROVE_ECHO),
          .writes   (PROVE == 1),
          .clk(clk),
          .rst(rst || !calib_done || !armed || (arm_t != 4'd0)),
          .go (1'b1),
          .mem_req(w_req), .mem_write(w_write),
          .mem_addr(w_addr), .mem_wdata(w_wdata),
          .mem_done(w_done), .mem_rdata(w_rdata), .mem_error(w_error),
          .has_run(prove_has_run), .matched(prove_matched)
      );

      // THE MACHINE GETS NOTHING, exactly as on the board with no memory at
      // all.  It reaches its first main-memory cycle at microcycle 536,303,
      // the bus's timer ends it at about 4.25 us, and it carries on --- so
      // every lamp reads on a `PROVE` board as `README.md` tabulates them for
      // a board with no memory.
      assign mem_done  = 1'b0;
      assign mem_rdata = 32'd0;

      // And the audit is told the machine asked for nothing, because it did:
      // every transaction the port answers on a proving board is the
      // witness's, and fed in they would read as the port answering what the
      // machine never asked --- which is the fault that clause exists to name.
      assign port_read_ack  = 1'b0;
      assign port_write_ack = 1'b0;

    end

    // --------------------------------------------- the debugger's window
    //
    // The scan chain it lives on.  USER2 --- IR 000011 on a seven-series part
    // --- where `cadr_probe` has USER1, so the two instruments can be in one
    // bitstream and are told apart by the instruction and not by a mode.
    //
    // RESET, RUNTEST, TCK and TMS are left empty because nothing here reads
    // them.  UPDATE is NOT: this register takes a command as well as giving an
    // answer, and UPDATE is when a command has arrived.
    logic jm_drck, jm_sel, jm_shift, jm_capture, jm_update, jm_tdi, jm_tdo;
    /* verilator lint_off PINCONNECTEMPTY */
    BSCANE2 #(
        .JTAG_CHAIN(2)
    ) u_bscan_mem (
        .CAPTURE(jm_capture),
        .DRCK   (jm_drck),
        .SEL    (jm_sel),
        .SHIFT  (jm_shift),
        .UPDATE (jm_update),
        .TDI    (jm_tdi),
        .TDO    (jm_tdo),
        .RESET(), .RUNTEST(), .TCK(), .TMS()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    cadr_jtag_mem u_window (
        .clk(clk), .rst(rst),
        .m_req(w_req), .m_write(w_write),
        .m_addr(w_addr), .m_wdata(w_wdata),
        .m_done(w_done), .m_rdata(w_rdata), .m_error(w_error),
        .p_req(port_req), .p_write(port_write),
        .p_addr(port_addr), .p_wdata(port_wdata),
        .p_done(port_done), .p_rdata(port_rdata), .p_error(port_error),
        .tally(tally), .calib_done(calib_done),
        .prove_has_run(prove_has_run), .prove_matched(prove_matched),
        .arm(prove_arm), .mach_reset(window_mach_reset),
        .jtag_drck(jm_drck), .jtag_sel(jm_sel), .jtag_shift(jm_shift),
        .jtag_capture(jm_capture), .jtag_update(jm_update),
        .jtag_tdi(jm_tdi), .jtag_tdo(jm_tdo)
    );

    // ------------------------------------------------------ and the memory
    //
    // **THE RESET IS THE FABRIC'S AND NOT THE MACHINE'S.**  Pressing the boot
    // button on a CADR does not erase its memory, and a controller reset would
    // both erase it and cost a millisecond of retraining.  So this takes
    // `rst`, which is the clock manager not locked or BTN3, where
    // `cadr_machine` above takes `mach_rst`.
    cadr_a7_memory u_memory (
        .clk(clk), .rst(rst),
        .sys_clk(clk), .ref_clk(clk_ref),
        .mem_req(port_req), .mem_write(port_write),
        .mem_addr(port_addr), .mem_wdata(port_wdata),
        .mem_done(port_done), .mem_rdata(port_rdata), .mem_error(port_error),
        .tally(tally), .calib_done(calib_done),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    // `w_error` is the proving witness's alone; with the machine driving, the
    // machine has no wire for it.  `prove_arm` is the witness's release and
    // there is no witness on a `DDR` board.  Both named rather than left
    // dangling --- and both are read on a `PROVE` board, where this fold is a
    // second reader and costs nothing.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_mem;
    assign unused_mem = &{1'b0, w_error, prove_arm};
    /* verilator lint_on UNUSEDSIGNAL */

  end

  // ============== THE SOFT PROCESSING SYSTEM AND THE FACES =================
  //
  // **THIS IS THE ARTIX's ANSWER TO THE ZYNQ's PS7 BLOCK, AND IT IS WIRED THE
  // SAME WAY ON PURPOSE.**  On `boards/arty-z7-20/cadr_arty.sv` the processing
  // system brings out `M_AXI_GP0` and `M_AXI_GP1` and this file hangs four
  // slaves off them --- the disk pack side, the console, the debug cable's
  // window, and a default answering everything else.  Here
  // `rtl/plumbing/cadr_soc.sv` brings out the same four ports and the same
  // three of the same four slaves hang off them --- all but the window ---
  // with the same parameters, at the same
  // addresses, from the same files.  **Nothing in `rtl/plumbing/` changed for
  // this board and nothing in `rtl/machine/` knows which processor is in
  // front of it.**
  //
  // The addresses are `console_face.h`'s and `pack_side.h`'s, which is the
  // point: the firmware in `boards/arty-a7-100/firmware/` compiles those very
  // headers and those very drivers, so the soft core and the Linux programs
  // share one map and one set of register definitions.
  //
  // **AND EVERY ADDRESS IS ANSWERED.**  `cadr_soc_axi.sv`'s last port is a
  // catch-all and `cadr_gp0_default.sv` sits behind it, so a load from an
  // address nothing implements completes with "NONE".  That is the GP0-hang
  // rule this project measured on silicon, kept on a board whose core has no
  // interconnect to give it an error response at all.
  if (SOC != 0) begin : g_soc

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
        // **THE SOFT SYSTEM'S OWN CLOCK IN HERTZ, WHICH IS NOT THE
        // MACHINE'S.**  The transmitter's rate and the timer's microsecond
        // are both computed from it and both are on the soft side of the
        // crossing.  `SOC_CLK_DIVIDE` beside the clock manager above is the
        // one place the number is decided, and this is that same number said
        // in hertz.
        .CLK_HZ      (SOC_CLK_HZ),
        .BAUD        (SOC_BAUD)
    ) u_soc (
        // **THE BOARD's RESET AND NOT THE MACHINE's.**  A firmware reset by
        // the machine's reset could not make one: the store to the console's
        // word 6 would be in flight while the core holding it was being
        // cleared.  `cadr_console.sv`'s header has the same argument for the
        // console's own registers.
        //
        // **AND TWO CLOCKS.**  `clk_soc` is the core's, its memory's, its
        // UART's and its timer's; `clk` is the machine's, which the AXI
        // bridge inside and the three faces outside all run on.  What crosses
        // is one request and one answer, at the narrowest seam there is ---
        // `rtl/plumbing/cadr_soc_cross.sv` --- and not a hundred and forty
        // wires of AXI.  The reset is the board's either way and `cadr_soc`
        // synchronizes it onto the soft clock itself, in the one place that
        // has to know.
        .clk(clk_soc), .rst(rst),
        .axi_clk(clk), .axi_rst(rst),
        .uart_tx(soc_uart_tx), .uart_rx(uart_txd_in),
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
        // The backplane's display boards, page 2's word 33, and the two
        // color maps on pages 4 and 5.
        .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
        .tv_map_a(con_tv_map_a), .tv_map_q(con_tv_map_q),
        .tv_color_map_q(con_tv_color_map_q),
        .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
        .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
        .clock_edge(clock_edge),
        .mach_vma(con_vma), .mach_q(con_q), .mach_md(con_md),
        // **WHICH BUILD THIS FABRIC IS**, page 2's word 32, out of the
        // part's own AXSS register.
        .build(con_build),
        .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
        .mach_rst(con_mach_rst), .mach_boot(con_boot),
        .no_auto_boot_held(sw0_held), .no_auto_boot_now(sw0_level),
        // **THE DEBUG CABLE'S ROLE**, page 0's word 14: `cadr-console
        // debug-cable-connect` and its opposite, and the four the connector
        // answers with.  The cable itself is at the top level and not in
        // here, because a board is always a debuggee and a board with no soft
        // processing system still has a connector.
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

  end else begin : g_nosoc

    // The board without a processing system: the machine and its tie-offs,
    // which is what every figure in `boards/arty-a7-100/README.md` was
    // measured on and what the probe flow builds.
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
    assign pack_irq        = 1'b0;
    assign hp_fold         = 1'b0;

    assign con_req     = 1'b0;
    assign con_msyn    = 1'b0;
    // And no way to say what the backplane has, so it is the default one:
    // a SIMPLE TV and no color board.
    assign con_tv_lispm = 1'b0;
    assign con_color_tv = 1'b0;
    assign con_tv_map_a = 4'd0;
    assign con_write   = 1'b0;
    assign con_addr    = 18'd0;
    assign con_wdata   = 16'd0;
    assign con_ro_addr = 18'h3FFFF;
    assign con_mach_rst = 1'b0;
    assign con_boot     = 1'b0;

    // Nobody to ask for the debugger's role, there being no console.
    // **The connector is still there and this board is still a DEBUGGEE** ---
    // it answers a debugger that plugs into JB, which is the power-on state
    // of any CADR and needs nothing set.
    assign dbg_connect   = 1'b0;
    // And the wiring stands at `auto`, which is what the fabric comes up
    // with: a board with no console still finds a crossed cable, it just has
    // nobody to tell.
    assign dbg_wiring    = 2'd0;

    // A line with nothing driving it idles high.
    assign soc_uart_tx = 1'b1;

    // And the clock the soft system would have run on.  Named rather than
    // left dangling, exactly as the memory controller's reference is one
    // branch above; the fitter takes the whole thing out, the buffer and the
    // clock manager's output with it.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_soc_clk;
    assign unused_soc_clk = &{1'b0, clk_soc};
    /* verilator lint_on UNUSEDSIGNAL */

  end

  // What leaves on the pin.  One line and not a generate, so that the pin is
  // driven in exactly one place whichever board this is.
  assign uart_rxd_out = soc_uart_tx;

  // --------------------------------------- the debug cable, on Pmod JB
  //
  // MIT's whole cable on ONE connector, both directions, four pins each way.
  // `rtl/plumbing/cadr_dbg_cable.sv` is the connector and the role;
  // `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` under it are the carrier.
  //
  // **IT IS INSTANTIATED WHATEVER `SOC` SAYS, NOT ONLY ON A BOARD WITH A SOFT
  // PROCESSING SYSTEM.**  A board is always a DEBUGGEE: it answers a debugger
  // on the connector exactly as MIT's board answers one on its DBGIN, and
  // nothing has to be set for that.  The pins are the top level's besides,
  // where an output nothing drives is a PINMISSING.  With no soft system
  // `dbg_connect` is tied low above and this board is a debuggee and nothing
  // else, which is what a CADR with one cable in it is --- and with the soft
  // system it is the same, there being no window on this board for the other
  // arm of the join.
  //
  // **AND IT TAKES THE BOARD'S RESET AND NOT THE MACHINE'S**, for the reason
  // the DBGIN page gives about its own: modifier bit 1 resets this machine
  // over this very cable, and a carrier reset by it would forget the request
  // that asked for it.
  cadr_dbg_cable u_dbg_cable (
      .clk(clk), .rst(rst),
      .connect(dbg_connect), .engaged(dbg_engaged), .foreign(dbg_foreign),
      .peer_far(dbg_peer_far), .live(dbg_live), .active(dbg_active),
      // Which way round the cable was made, and what the board found.
      .wiring(dbg_wiring), .wire_state(dbg_wire_state),
      // Frames heard and frames refused: the crosstalk instrument, page 0's
      // word 15.
      .frames(dbg_frames),
      .out_req(dbgout_req), .out_wr(dbgout_wr), .out_a(dbgout_a),
      .out_dbd(dbgout_dbd), .out_ack(dbgout_ack),
      .out_dbd_in(dbgout_dbd_in), .out_live(dbgout_live),
      .in_req(cab_req), .in_wr(cab_wr), .in_a(cab_a), .in_dbd(cab_dbd),
      .in_ack(dbg_in_ack), .in_dbd_out(dbd_from_machine), .in_dbd_oe(dbd_oe),
      .pin_o(jb_o), .pin_t(jb_t), .pin_i(jb)
  );

  // The eight pads.  `pin_t` is Xilinx's sense --- HIGH is not driven --- so
  // the group this board does not own is high-impedance and the far end has
  // it.
  for (genvar i = 0; i < 8; i = i + 1) begin : g_jb
    assign jb[i] = jb_t[i] ? 1'bz : jb_o[i];
  end

  // **ONE DEBUGGER AT THE DBGIN PAGE ON THIS BOARD, WHERE THE ZYNQ BOARDS HAVE
  // TWO.**  `rtl/plumbing/cadr_dbg_join.sv` exists because those boards can be
  // reached from two directions at once: the Pmod connector, which is a second
  // board, and `rtl/plumbing/cadr_debug_window.sv`, which is muir on their own
  // Arm cores playing the far end of the cable in software.  **There is no
  // window here and there is no muir here**: the only processor on this board
  // is the soft one, which is the console and not a debugger, so the
  // connector is the whole of it.
  //
  // The join stays, and it is the same module those boards use, so that this
  // board is the same composition with one arm empty rather than a second
  // wiring of the DBGIN page.  What an empty arm IS is the join's own word for
  // an unplugged cable: `a_req` low --- which is `-DEBUG IN REQ` UP, the sense
  // the whole transport uses --- with the levels beside it at zero, exactly as
  // the SIP at DBGIN 0A22 holds a connector with nothing on it.  A request can
  // then never be pending on that arm, so the connector holds the page
  // whenever it asks for it and `holder` is 1 from the first tick after reset.
  //
  // **AND THAT IS ASSERTED RATHER THAN STATED.**  `tb/cadr_soc_tb.cpp` watches
  // the join every tick: the window's arm never asserts, the holder never
  // names it, and the request reaching `cadr_dbgin.sv` never rises while
  // nothing is on the connector.  `soc-the-window-arm-of-the-join-asks-for-the-page`
  // is the record.
  assign dbg_in_req     = 1'b0;
  assign dbg_in_wr      = 1'b0;
  assign dbg_in_a       = 2'd0;
  assign dbd_to_machine = 16'd0;

  cadr_dbg_join u_dbg_join (
      .clk(clk), .rst(rst),
      .a_req(dbg_in_req), .a_wr(dbg_in_wr), .a_a(dbg_in_a),
      .a_dbd(dbd_to_machine),
      .b_req(cab_req), .b_wr(cab_wr), .b_a(cab_a), .b_dbd(cab_dbd),
      .req(mdbg_req), .wr(mdbg_wr), .a(mdbg_a), .dbd(mdbg_dbd),
      .holder(dbg_holder)
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
        // The probe re-arms on a machine reset, which on this board is BTN1
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
  // `clock_edge`, `promenable`, `timed_out`, `machrun` drive lamps as well
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
                   dbg_in_ack, dbd_from_machine, dbd_oe, timeout_inhibit,
                   // The debug cable's connector: who holds the DBGIN page,
                   // and the four that say what the connector is doing rather
                   // than what crosses it.  On a board with no console they
                   // reach nobody; with one, page 0's word 14 reports them
                   // and this is a second reader.
                   dbg_holder, dbg_engaged, dbg_foreign, dbg_live, dbg_active, dbg_peer_far, dbg_frames,
                   dbg_wire_state,
                   // The two display boards' color maps, which the console
                   // reads on pages 4 and 5.
                   con_tv_map_q, con_tv_color_map_q,
                   // The pack side's unanswered memory port, folded one level
                   // down, and the switch value the console reports.
                   hp_fold, sw0_held};
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
  // OR RED.**  No other color and no other meaning ever reaches it --- not at
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
  // **`PROMENABLE`, AND THAT IS THE NAME OF THE SIGNAL ON THE PIN.**  The
  // lamps are named by the machine's own signals --- LD0 is `MACHRUN` and LD4
  // is `ERRHALT` --- and this one is MIT's `-PROMENABLE` at PCTL 1C19, the
  // PROM's own select, driven from the net itself out of the processor.  Lit
  // while the machine fetches its microinstructions from the boot PROM, dark
  // once it runs the microcode it loaded from the disk.
  //
  // **IT IS THE SELECT AND NOT THE MODE BIT, AND THE EYE CAN SEE THE
  // DIFFERENCE.**  `-PROMENABLE` is `BOTTOM.1K` with `PROMDISABLED`,
  // `IWRITEDA` and `-IDEBUG`, so it says whether THIS microinstruction is
  // coming out of the PROM: it is up on every fetch and down on the
  // control-store write cycles, which is why the lamp sits a little under
  // full brightness while the PROM loads the store.  The mode register's own
  // bit is `promdisable`, which drives no lamp here --- the probe's sample
  // carries it and nothing else does.
  //
  // Blue, and blue only, for the one state it carries.  A color lamp showing
  // one thing is still the right lamp for it: this is the answer to "has it
  // finished booting", which is worth telling apart from the four plain green
  // ones at a glance.
  assign led1_r = 1'b0;
  assign led1_g = 1'b0;
  assign led1_b = promenable;

  // The two tricolor lamps this board has and the assignment does not use.
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
  // is optimized away is a hole in the fold.
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

  // btn[3:2] and sw[3:1] are pins the board has and this design does not use.
  // BTN0 is the machine's boot button, BTN1 the fabric's reset and SW0 the
  // no-auto-boot switch; the rest have no meaning here.  They are read here
  // only to keep them legal without inventing behavior for them.
  //
  // **AND TWO MORE WHEN THERE IS NO SOFT PROCESSING SYSTEM.**  `uart_txd_in`
  // is what a host types and `pack_irq` is the disk pack side's interrupt;
  // with `SOC` clear neither has a reader, and a port that is in the list
  // because the BOARD has it must still be legal.  They are read here as well
  // as there rather than inside the generate, so that this one line is the
  // whole of the answer for every configuration.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, btn[3:2], sw[3:1], uart_txd_in, pack_irq};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
