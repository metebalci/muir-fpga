// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on an Arty Z7-20: a top level with real pins.
//
// Everything else here is checked against muir and none of it has been near a
// chip.  This exists to find out whether the design can be built at all ---
// synthesised, placed, routed and written to a bitstream against a real part
// with real package pins --- which is a different question from whether it is
// correct, and one nothing in this repository has ever asked.
//
// **BY DEFAULT THIS IS NOT A WORKING CADR AND IS NOT MEANT TO BE.**  With
// `DDR` zero there is no memory behind it: `mem_done` is tied low, so the
// first cycle the boot PROM runs to main memory --- microcycle 536,303 of
// 600,000 --- never completes, and the machine stalls there for ever.  What
// it can show is that the fabric runs: the clock generator ticking,
// microcycles retiring, the PROM executing.
//
// `DDR` set puts the Zynq processing system and its DDR3 behind `mem_*`.  It
// is off for the same reason `PROBE_DEPTH` is, and the note beside that
// parameter is the whole argument: the design this file describes by default
// is the machine and nothing else, so what the machine costs and what the
// memory costs stay two questions.
//
// `PROVE` set builds one of the two boards that answer whether that memory
// works at all, and neither of them is the machine running out of it.  The
// machine is still in the design and still stalls on its own memory port
// exactly as the default board does; what changes is that `rtl/plumbing/cadr_prove.sv`
// drives that port instead, with one word and one address, and somebody
// outside the design says whether the word arrived.  `PROVE=1` writes a word
// for a debugger to read; `PROVE=2` reads one a debugger wrote and WRITES IT
// BACK to a second address, so the comparing is done outside the design there
// too.  Neither needs anybody at the board.  That module's header is the
// whole argument for the two steps and for their order.
//
// THREE THINGS THIS FILE HAS TO GET RIGHT THAT ARE NOT OBVIOUS.
//
// **THE TICK IS 10 ns, AND EVERY TICK COUNT IN THE MACHINE IS UNCHANGED.**
// `CLKOUT0_DIVIDE_F` below is the only place the length of a tick is decided,
// and it is the only thing that moved when Mete decided on 2026-09-11 to stop
// treating timing closure as something to chase.  It went from 5 to 6.25 that
// morning and from 6.25 to 10 that afternoon, when a one-character change to
// a multiplexer cost a third of a nanosecond and the memory-on board stopped
// closing again: Mete's words were "if you have timing concern, we can even
// increase the tick to 10ns".  Nothing under `rtl/machine/` changed:
// `cadr_phase_gen.sv`'s `TICK_NS` is still 5, because that constant
// is the conversion from MIT's drawings --- whose instants are five
// nanoseconds apart --- into tick counts, and the seven read taps are still
// 15, 17, 20, 23, 25, 28 and 32 ticks of whatever a tick costs.
//
// **SO THE MACHINE IS SCALED AND NOT DISTORTED**, and that distinction is the
// whole argument.  It is also the one this file has to state carefully, now
// that the tick is 10 ns, because an old note in these sources argued against
// exactly that number and meant something else.  What must never happen is
// REDESCRIBING MIT's instants on a 10 ns grid: the 5, 25, 45, 65, 85 and
// 145 ns instants would become half-ticks and six of the machine's own edges,
// the microcycle's length among them, simply could not be expressed --- the
// "different machine that still lights LEDs" this project keeps meeting.
// That is a property of `cadr_phase_gen.sv`'s `TICK_NS`, which is 5 for ever.
// Making every tick LONGER by the same factor is a different operation: the
// counts are untouched, so every instant keeps its exact ratio to every other,
// a microcycle is 29 ticks whatever a tick costs, and the machine's own clock
// is the only clock it has.  The machine therefore runs at 50% of the speed
// the hardware ran and **nothing inside it can tell**.  Every check in this
// repository compares tick counts on both sides, so not one of them moves
// either.
//
// The two places where that is visible from outside are recorded, not fixed:
// see "THE TWO CLOCKS THAT NOW DISAGREE WITH THE WALL" below.
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
// **THE TWO CLOCKS THAT NOW DISAGREE WITH THE WALL, DELIBERATELY.**  Two
// things the machine owns are clocks in the ordinary sense, and they cannot
// both agree with muir tick for tick and agree with the time of day once a
// tick stops being 5 ns.  Mete's decision is that **for now they keep
// agreeing with muir**, because the checks are the backbone of this project
// and nothing built yet needs the time of day:
//
//   - `rtl/machine/cadr_io_board.sv`'s microsecond clock is 200 ticks, so it
//     counts one per 2.0 real microseconds and a CADR wall clock run off it
//     loses half a day in a day.  The card is not composed into
//     `cadr_machine` yet, so nothing on this board reads it.
//   - `rtl/machine/cadr_tv.sv`'s frame is 3,091,200 ticks, so the vertical
//     interrupt arrives every 30.912 real ms --- 32.35 Hz where the display
//     board scanned at 64.70.  MIT's microcode uses that interrupt as its
//     roughly-sixty-cycle clock for mouse tracking and the scheduler's
//     sequence break, so the machine's idea of a second is 50% of one.
//
// **10 ns keeps the property 6.25 was partly chosen for: undoing this is one
// constant each.**  A real microsecond is exactly 100 ticks and a real frame
// exactly 1,545,600, both whole numbers, so restoring real time later means
// changing `USEC_PERIOD_T` and `FRAME_T` and nothing else --- not a rewrite,
// and not a second clock domain.  The argument that chose 6.25 was that
// 1,000 / 6.25 is 160 exactly; at 10 ns it is 100 exactly, so the argument
// survives the number moving.  Doing it would put those two modules out of
// agreement with muir, which is why it has not been done.
//
// **Every output has to reach a pin or synthesis will delete the machine.**
// `cadr_machine` brings out the whole datapath for the testbenches to compare
// --- PC, IR, the A and M buses, the ALU, twenty-odd more --- and a top level
// that left them unconnected would synthesise to almost nothing, place and
// route in seconds, and write a perfectly good bitstream of an empty part.
// That is the failure this project keeps meeting: not an error, but a
// plausible artefact.  So the wide outputs are reduced into one LED through a
// register, which costs four LUTs and keeps every one of them load-bearing.
// `boards/arty-z7-20/vivado/bitstream.tcl` checks the utilisation against what the design is
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
    parameter int unsigned PROBE_DEPTH = 0,
    parameter int unsigned DDR = 0,
    // 0 the machine, 1 the fabric writes a word, 2 the fabric reads one back
    // and writes what it read to a second address.
    // See the note above the memory below: a `PROVE` board is a `DDR` board
    // by construction, because proving the port needs the port.
    parameter int unsigned PROVE = 0
) (
    input  var logic       sysclk,   // 125 MHz, pin H16
    input  var logic [3:0] btn,
    output var logic [3:0] led,
    // The two tricolour LEDs. Driven high to light, one pin a colour.
    output var logic       led4_r, led4_g, led4_b,
    output var logic       led5_r, led5_g, led5_b
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

  // Reset while the MMCM has not locked, and on BTN0. Synchronised out of
  // the 100 MHz domain: `locked` is asynchronous to it by construction.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked || btn[0]};
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
  // MEM<31:0> on its way to an Xbus slave. No slave exists, so nothing
  // reads it --- but it is an output of `cadr_machine` and the fold below
  // is what keeps it from being deleted along with whatever computes it.
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge, wrcyc;
  logic device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
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
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
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
  //                   side is done --- `evtest` printed Mete's name off a USB
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
  // program to reach them on.  The keyboard and the mouse stay tied off
  // everywhere: `cadr-usb-input` is last in the order of work.
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
  assign kbd_strobe     = 1'b0;
  assign kbd_code       = 24'd0;
  assign mouse_lines    = 7'd0;
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
  // **THE CONSOLE CAN RESTART THE CADR, AND IT JOINS BTN0 RATHER THAN
  // REPLACING IT.**  `rst` above is the MMCM's lock and the button; a write of
  // `RESET_KEY` to the console's word 6 pulses `con_mach_rst` for 64 ticks,
  // and this is the OR.  Mete asked for a soft reboot from the processing
  // system --- the board runs Linux beside the machine, and restarting the
  // CADR had meant a finger on a board nobody is sitting at, or a fresh
  // bitstream.  `rtl/plumbing/cadr_console.sv`'s header has the key, the length and
  // why it is a pulse and not a level.
  //
  // **A REGISTER AND NOT A GATE**, for the reason `pack_rst` below gives at
  // the same shape: this lands on some two thousand registers spread across
  // `cadr_machine`, and a LUT between the countdown and that fanout is a LUT
  // on every one of their reset pins.  One tick later on a reset costs
  // nothing that anything counts, `rst` itself already being four
  // synchroniser stages deep.
  //
  // **AND THE RULE FOR WHAT TAKES IT: `mach_rst` replaces `rst` wherever
  // `rst` means "since the MACHINE started", and `rst` stays wherever it
  // means "since the FABRIC was configured".**  Written down because the
  // alternative --- folding `con_mach_rst` into `rst_sync` beside BTN0, which
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
  //   - **It would reset `cadr_axi_master` mid-transaction**, through
  //     `axi_rst`, which is an AXI protocol violation the PS7 cannot recover
  //     from --- VALID dropped without READY, or R beats returned to a master
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
  logic con_mach_rst;
  logic mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || con_mach_rst;
  // A write or read that came back SLVERR or DECERR, held. Zero when there is
  // no memory, so LD5's blue is dark on the board this file builds by default.
  logic ddr_error;

  // LD4's three colours, as {red, green, blue}. It is a wire and not three
  // assignments because WHAT LD4 SAYS DEPENDS ON THE BOARD: on the machine it
  // is where the boot has got to, and on a `PROVE` board it is the witness's
  // verdict. Driven from exactly one of two generate blocks, one down in the
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
  localparam int unsigned PORT = ((DDR != 0) || (PROVE != 0)) ? 1 : 0;

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
  //                  0x18A7_2EE4's neighbour is the one a strobe pattern that
  //                  opens both halves would destroy. Reading that neighbour
  //                  is what makes the check able to fail.
  //
  //   the word       0x8A5C_36E1. Four different bytes, none of them 0x00 or
  //                  0xFF, each with three or four bits set, so a lane stuck
  //                  either way shows in every lane. Its halves differ and
  //                  neither is a rotation of the other, so a lane swap
  //                  shows. Bit 0 and bit 31 are both set, so a shift either
  //                  way shows. Reversed byte for byte it is 0xE1365C8A, so
  //                  an endianness swap shows. And it is not the address, nor
  //                  the address shifted, which is CLAUDE.md's
  //                  bridge-writes-the-address-instead-of-the-data in the one
  //                  place here where it could happen.
  //
  // THE FILLER IS ITS COMPLEMENT, 0x75A3_C91E, and that is not decoration.
  // The neighbourhood is filled with it from the debugger before the port is
  // released, so every word that should not have changed differs from `WORD`
  // in every bit. CLAUDE.md's "a stimulus that poisons cannot move with the
  // bug": against a neighbourhood of zeros, a word that half-landed reads as
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
  //                  lands on this address's neighbour instead.
  //
  //                  **INSIDE THE POISONED BLOCK, WITH ITS OWN NEIGHBOUR IN
  //                  IT TOO.** 0x18A7_2F1C is the other half of this beat
  //                  and carries the filler like everything else, so a
  //                  strobe pattern that opened both halves of the
  //                  write-back destroys a word the debugger prints.
  //
  //                  **NOT THE BASE, AND NOT THE READ'S ADDRESS SHIFTED.**
  //                  It differs from `PROVE_ADDR` in bits 2 through 8, so a
  //                  dropped or doubled bit among the low nine moves the
  //                  write-back somewhere the block still shows.
  localparam logic [31:0] PROVE_ADDR = cadr_ddr_map::main_byte_address(22'o12345671);
  localparam logic [31:0] PROVE_WORD = 32'h8A5C_36E1;
  localparam logic [31:0] PROVE_ECHO = cadr_ddr_map::main_byte_address(22'o12345706);

  cadr_machine #(
      .PROM_HEX(PROM_HEX)
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
      // The memory, or the absence of one: see the `DDR` generate below.
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
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      // The I/O board's cables, tied off above with the slice that will
      // drive each, and what the card shows.
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
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
    // is synchronised in, the same way `mmcm_locked` is.
    logic       hp0_aresetn;
    logic [2:0] port_rst_sync;
    always_ff @(posedge clk) begin
      port_rst_sync <= {port_rst_sync[1:0], hp0_aresetn};
    end

    logic axi_rst;
    assign axi_rst = rst || !port_rst_sync[2];

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
          .rst(axi_rst),
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
      // LD0, LD1, LD2 and LD3 read on a `PROVE` board exactly as
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
    // exactly as unchanged.  Nor can any lamp: measured, LD2 reads the same
    // with DDR and without, because the 16,951 disk polls time out either
    // way.  This is the positive witness, and it is four counters because
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
    // it does with `DDR` off. Synchronised in as `hp0_aresetn` is.
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
      // registers to reset, and made as `rst || !pack_rst_sync[2]` the
      // machine's synchroniser was on every one of their reset pins across
      // the distance between the two.  One tick later on a reset the PS
      // releases at a moment of software's choosing, which nothing counts.
      logic pack_rst;
      always_ff @(posedge clk) begin
        pack_rst_sync <= {pack_rst_sync[1:0], hp2_aresetn && gp0_aresetn};
        pack_rst      <= rst || !pack_rst_sync[2];
      end

      cadr_disk_pack u_pack (
          .clk(clk), .rst(pack_rst),
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
      // `gp0_rst_s` is the port's own reset synchronised, made once in the
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
    // Reset by the port's own reset, synchronised, as the pack side and the
    // console are: before Linux is up the faces read zero, so the serial
    // port's `CTL` is zero and its cable is out, and the Chaosnet's address
    // switches read zero --- which is exactly what the tie-off did.
    logic [2:0] gp0_rst_sync;
    logic gp0_rst_s;
    always_ff @(posedge clk) begin
      gp0_rst_sync <= {gp0_rst_sync[1:0], gp0_aresetn};
      gp0_rst_s    <= rst || !gp0_rst_sync[2];
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
        .clk(clk), .rst(gp0_rst_s),
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
        .chaos_tx_done(chaos_tx_done), .chaos_tx_abort(chaos_tx_abort),
        .chaos_cbl_busy(chaos_cbl_busy),
        .irq(chaos_irq)
    );

    cadr_serial_line u_serial (
        .clk(clk), .rst(gp0_rst_s),
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
    // Reset by the port's own reset, synchronised, as the pack side is ---
    // and the machine is NOT reset with it: a console that reset the machine
    // when Linux came up would be a console that could never be attached to
    // a running machine, which is the only time it is wanted.
    logic [2:0] gp1_rst_sync;
    logic gp1_rst;
    always_ff @(posedge clk) begin
      gp1_rst_sync <= {gp1_rst_sync[1:0], gp1_aresetn};
      gp1_rst      <= rst || !gp1_rst_sync[2];
    end

    cadr_console u_console (
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
        .dbg_req(con_req), .dbg_gnt(con_gnt),
        .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
        .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
        .clock_edge(clock_edge),
        // The virtual address register, `Q` and `MD`, page 0's words 7, 8
        // and 9.
        .mach_vma(con_vma), .mach_q(con_q), .mach_md(con_md),
        // The readout, page 0's words 10, 11 and 12.
        .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
        // The machine's reset, ORed with the board's own at the declaration
        // above.  **Not `gp1_rst` and not this instance's own `rst`**: see
        // the rule there and `rtl/plumbing/cadr_console.sv`'s header.
        .mach_rst(con_mach_rst)
    );

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

    // NO MEMORY, which is what this top level has always been. The machine
    // stalls at the boot PROM's first main-memory cycle and stays there, and
    // `mem_req`, `mem_write`, `mem_addr` and `mem_wdata` reach nothing but
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
    assign con_write = 1'b0;
    assign con_addr = 18'd0;
    assign con_wdata = 16'd0;
    // And nothing asks the readout anything: the address stands at the
    // reserved selector, the machine answers `RO_NO_MEMORY` for ever, and
    // both answers fold below.
    assign con_ro_addr = 18'h3FFFF;
    // And no console reset either, so `mach_rst` is `rst` a tick late on
    // this board and the whole of the OR folds away.
    assign con_mach_rst = 1'b0;
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
    assign chaos_tx_done  = 1'b0;
    assign chaos_tx_abort = 1'b0;
    assign chaos_cbl_busy = 1'b0;

  end

  // ------------------------------------------------------------ the probe
  //
  // One sample a microcycle of the columns `build/rtl.golden` carries, held
  // in block RAM and shifted out over JTAG, so that what the *board* computes
  // can be diffed against what muir computes. `rtl/plumbing/xilinx7/cadr_probe.sv` is the
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
  // **All seventy-six of them, including the ones something else already
  // reads** --- `clock_edge`, `promdisable`, `timed_out`, `n_memack` drive
  // LEDs as well and are still here, because the rule the comment states is
  // the whole specification and a fold with exceptions in it is not a rule
  // anybody can check. What checks it is `make build/arty.pass`: an output
  // left off the instantiation is a Verilator PINMISSING, which is how
  // `dev_wdata` was found missing from both.
  logic witness;
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
                   sintr};
    end
  end

  // A microcycle is 29 ticks at normal speed and 44 at extra slow, which is
  // what the boot PROM runs at: 440 ns of real time at a 10 ns tick. Bit 23
  // of a count of them is 3.7 s a half-period --- a 7.4 s cycle, which reads
  // as a light that is on or off rather than one that blinks. Bit 19 is
  // 524,288 microcycles, 231 ms, about 2.2 Hz: fast enough to be obviously
  // alive and slow enough to count.
  logic [23:0] beat;
  always_ff @(posedge clk) begin
    if (mach_rst) beat <= 24'd0;
    else if (clock_edge) beat <= beat + 24'd1;
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

  // LD0 is the heartbeat and the other three are status. The heartbeat gets
  // the first LED because it is the one to look at first: it answers "is this
  // thing running at all", and every other light is meaningless until it says
  // yes. A dark LD0 means the board is not programmed or the MMCM never
  // locked; a blinking LD0 with the rest dark means the fabric is clocked and
  // the machine is not retiring microcycles, which is a different fault
  // entirely.
  // LD2 counts NXM timeouts rather than showing the flag. `timed_out` is a
  // level that stands only while an unanswered cycle is up --- a sliver at the
  // end of each 4.25 us timeout --- so at the measured rate it integrates
  // to a light too faint to read, which is what the board showed. Counting the
  // rising edges and lighting a bit of the count turns it into a rate: the
  // 168 kHz measured at a 5 ns tick is 84 kHz at 10, and bit 16 is 65,536
  // timeouts, about 0.78 s a half-period at that rate.
  //
  // The rate is the point. Faster means cycles are timing out more often.
  // An earlier version of this comment said dark would mean memory is
  // working. Measured, it does not: memory answers only the boot PROM's 512
  // page-0 cycles, once, and the 16,951 disk-controller polls time out
  // regardless, so this lamp reads the same with DDR and without. See
  // docs/board.md. The memory path is checked by the debugger reading DDR
  // from outside, not by any lamp here.
  logic timed_out_q;
  logic [16:0] nxm_count;
  always_ff @(posedge clk) begin
    timed_out_q <= timed_out;
    if (mach_rst) nxm_count <= 17'd0;
    else if (timed_out && !timed_out_q) nxm_count <= nxm_count + 17'd1;
  end

  // ------------------------------------------------- the tricolour LEDs
  //
  // LD4 is where the machine is in its own boot, and it starts red because
  // "nothing has happened yet" must not look like "running".
  //
  //   red    the fabric is not running --- reset held or the MMCM unlocked
  //   blue   running out of the boot PROM, which is where it is today
  //   green  PROMDISABLE is set: running microcode out of the control store
  //
  // Blue is the honest colour for now. The boot PROM clears the control store
  // and never sets PROMDISABLE --- issue #1 lists it as unreached --- because
  // the microcode comes off a disk pack and there is no disk. So green is the
  // day a pack is readable, and this light will not change before then.
  //
  // ON A `PROVE` BOARD LD4 SAYS SOMETHING ELSE ENTIRELY --- the witness's
  // verdict, driven from `g_ddr.g_prove` where the numbers are. It is this
  // lamp and not LD5 because LD4's inputs are all read somewhere else as
  // well (`mmcm_locked` by the reset synchroniser, `promdisable` by the
  // `witness` fold), so overriding it leaves nothing undriven and nothing
  // unread; LD5's `bus_nxm` has no other reader and overriding that one would
  // have meant moving its counter into a generate to keep lint quiet.
  //
  // The colours are one axis either way: red is "nothing yet", and the two
  // boards disagree only about what would count as something.
  assign {led4_r, led4_g, led4_b} = lamp4;
  if (PROVE == 0) begin : g_lamp_boot
    assign lamp4 = {!mmcm_locked || mach_rst,
                    mmcm_locked && !mach_rst &&  promdisable,
                    mmcm_locked && !mach_rst && !promdisable};
  end

  // LD5 is the bus, latched on each acknowledgement: red if that cycle was a
  // non-existent-memory reference, green if something answered it. It starts
  // red because before the first cycle nothing has answered, which is the
  // same distinction LD4 makes.
  //
  // `timed_out` and not the decode's `nxm`: there are two signals of that name
  // and they mean opposite kinds of thing. The decode's says the *address* is
  // Xbus space with nothing built there; the interface's register, which
  // `timed_out` carries out, says *this cycle* ended on the timer rather than
  // on a slave. Latching the decode's showed green on a board with no memory,
  // because the disk registers at 0o17377774 are in the decode's map and so
  // are not empty space --- they are simply unanswered.
  //
  // Today it is red and stays red: every cycle is the boot PROM polling a
  // disk controller that is not there. **It goes green the first time a real
  // slave answers**, which is what step 2 is for --- so this is the light to
  // watch when the PS block and DDR3 land.
  //
  // AND IT STAYS RED ON A `PROVE` BOARD TOO, which is not a fault. The
  // witness has the port and the machine's `mem_done` is tied low, so the
  // machine's own cycles still end on the timer. This lamp is about the
  // machine's memory and there is not one yet; LD4 is the one to read there.
  logic memack_q, bus_nxm;
  always_ff @(posedge clk) begin
    memack_q <= !n_memack;
    if (mach_rst) begin
      bus_nxm <= 1'b1;                       // nothing has answered yet
    end else if (!n_memack && !memack_q) begin
      bus_nxm <= timed_out;                  // latch the outcome at the ack
    end
  end
  assign led5_r =  bus_nxm;
  assign led5_g = !bus_nxm;
  // Blue is the AXI answer, held once it has ever been an error: SLVERR or
  // DECERR from `S_AXI_HP0` is a cycle that reached the port and was refused,
  // which is a different fault from a cycle nothing answered and must not
  // look like one. Constant zero when `DDR` is off, so this is dark on the
  // board this file builds by default and the light means what it says.
  assign led5_b = ddr_error;

  assign led[0] = tick[25];      // the fabric is clocked          --- heartbeat
  assign led[1] = beat[19];      // microcycles are retiring, ~3.5 Hz
  assign led[2] = nxm_count[16]; // NXM timeouts, blinking at their rate
  assign led[3] = witness;       // the datapath is not optimised away

  // btn[3:1] are pins the board has and this design does not use. BTN1 was
  // a `PROVE=2` board's start button until the witness learned to write back
  // what it read; nothing presses anything now, and the pins are read here
  // only to keep them legal without inventing behaviour for them.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, btn[3:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
