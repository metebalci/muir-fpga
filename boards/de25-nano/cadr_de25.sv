// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on a DE25-Nano: a top level with real pins, and the first one
// built with Quartus rather than Vivado.
//
// **WITHOUT `DDR` THIS IS THE MEMORY-OFF BOARD, THE ARTY Z7-20's DEFAULT ONE
// MOVED TO A SECOND VENDOR.**  `cadr_machine` with nothing behind its memory
// port: every cycle the boot PROM runs to main memory --- the first at
// microcycle 536,303 --- is ended by the bus interface's NXM timer, and the
// machine carries on with nothing stored.  What it can show is that the fabric
// runs on this part: the clock ticking, microcycles retiring, the PROM
// executing.  Every seam the processor's side would plug into is tied off
// below as the cable a CADR has with nothing on the far end of it.
//
// **WITH `DDR` IT IS THE WHOLE BOARD**: the processor, its LPDDR4 behind the
// machine's memory port, and on the two processor-to-fabric bridges the
// disk's pack side, the Chaosnet cable, the serial line, the keyboard's cable
// and the mouse's, the console and the debug cable's carrier.
//
// **AND MIT'S DEBUG CABLE ON JP1, ON EVERY BOARD AND NOT ONLY A `DDR` ONE.**
// A board is always a DEBUGGEE --- it answers a debugger that plugs into the
// connector exactly as MIT's board answers one on its DBGIN, and nothing has
// to be set for that --- so the connector cannot live inside the generate
// block that holds the processor.  The pins are this top level's besides,
// where an output nothing drives is a PINMISSING.  The connector section near
// the end of this file has the pin map and `docs/debug-cable.md` the design.
//
// **WHAT IS CHECKED HERE AND WHAT IS ONLY BUILT.**  Every module under the
// connector is held by a check that runs it: `build/dbg_pmod.pass` for the
// carrier, `build/dbg_cable.pass` for two boards on one ribbon with the
// testbench as the cable, and `build/dbgin.pass`, `build/gp1_split.pass` and
// `build/unibus.pass` for the page, the window and a debug cycle.  None of
// those is this board's: they are the modules', and this board instantiates
// the same modules.  What is this board's ALONE is the adapter below --- which
// header pin carries which of the carrier's eight lines, and which nets join
// the connector, the join, the window and the machine --- and what holds the
// adapter is lint and `tools/de25_faces_check.py`, which reads the pin map and
// the nets alike.  This file IS simulated, by `build/de25.pass` after its
// lints, around shells of the PLLs, the processor and the machine
// (`tb/cadr_de25_sim_stubs.sv` and `tb/cadr_de25_top_tb.cpp`); that holds the
// memory port's wiring, the resets, the keys, the switch, the lamps and the
// video and two-wire pins, and it does not drive JP1.
// **NOTHING OF THIS CONNECTOR HAS RUN ON SILICON.**  The Zynq boards' two ends
// have run on a real ribbon; no cable from a 2x20 header to a Pmod exists, so
// this one has crossed nothing.
//
// **AND WITH `HDMI` BESIDE `DDR`, THE DISPLAY OUTPUT.**  The CADR's screens
// out of the machine's memory and onto the board's HDMI connector, which is
// the Arty Z7-20's display with one stage of it moved off the fabric: there
// the fabric encodes DVI and serializes it, here an ADV7513 on the board
// does both and the fabric hands it a raster on a parallel bus.  The display
// section near the end of this file has the whole of it, and
// `docs/display-output.md` is the design it is built to.  `HDMI` needs `DDR`,
// because the picture is read out of the machine's memory and a board with
// no memory has no picture.
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
// **AND THE MACHINE WAITS FOR ITS MEMORY ON THIS BOARD, WHICH THE ZYNQ
// BOARDS DO NOT HAVE TO.**  There the processing system is configured before
// the fabric is, so the memory port is live before the machine's first tick.
// Here the fabric is configured first and the bridge is opened by software in
// U-Boot, seconds later, while the boot PROM's ONLY traffic to main memory is
// 512 bus cycles 118 ms after the machine's own reset and none before or
// after: a machine released at the fabric's reset spends that one pass
// against a shut port every time, on a board whose memory works.  So the
// machine's reset is held until the port has been live once.  The reset
// section below has the whole of it, `rtl/plumbing/cadr_f2sdram_gate.sv`
// holds the hold, and `tb/cadr_f2sdram_tb.cpp`'s OPEN and NEVER are its two
// halves.
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
// error lamp and blue PROM lamp are two green ones here.  LEDR1 and LEDR2
// blink until the console's word 35 asks for steady, which is
// `--no-blinking-leds`, and a board without a console blinks for ever.
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
    parameter int unsigned PROBE_DEPTH = 0,
    // **WHICH MACHINE**: "cadr", MIT's, or "quux", the evolved CADR, each a
    // bitstream of its own on this board.  A parameter and not a define,
    // because it changes nothing in the port list.  Handed to `cadr_machine`
    // as it stands, which refuses a name it does not know; `make de25
    // MACHINE=quux` sets it, and `build/machine_param.pass` holds that it
    // arrives.
    parameter string MACHINE = "cadr",

    // **QUUX'S MICROCYCLE ON THIS BOARD**: four ticks, 40 ns, and no more
    // for an `ILONG` instruction (H1a, muir's `--timing-model sync
    // --sync-cycle-ticks 4`).  Four is QUUX's least (`quux_phase_gen.sv`),
    // so the three the plan hoped for here is not a K this machine takes.
    // The fit at this K is what entitles it, against the counts
    // `quartus/quux_de25.sdc` states.  The CADR reads neither.
    parameter int unsigned SYNC_K = 4,
    parameter int unsigned SYNC_L = 0
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
    output var logic [7:0] led,
    // **MIT'S DEBUG CABLE, ON EIGHT OF JP1's PINS**, which is what this board
    // has in place of the Zynq boards' Pmod JA.  One port a header pin, named
    // by the header pin, because that is how `de25_nano_pins.tcl` names every
    // pin of both headers and choosing pins for a cable is then a matter of
    // naming them.  **NOT A BUS**: a bus would be a name that says nothing
    // about which pin each bit is, and which pin each bit is on is the whole
    // of what this adapter decides.
    //
    // Bidirectional, and they have to be: the role is not fixed at synthesis,
    // so the group this board does not own is high-impedance and the far end
    // has it.  The connector section near the end of this file has the map,
    // the reason for it and what a cable to a Pmod must leave open.
    inout  wire  logic     jp1_pin31,
    inout  wire  logic     jp1_pin32,
    inout  wire  logic     jp1_pin33,
    inout  wire  logic     jp1_pin34,
    inout  wire  logic     jp1_pin35,
    inout  wire  logic     jp1_pin36,
    inout  wire  logic     jp1_pin37,
    inout  wire  logic     jp1_pin38
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
`ifdef CADR_DE25_HDMI
    ,
    // **THE ADV7513's SIDE OF THE BOARD**, the manual's Table 3-13 as
    // `boards/de25-nano/de25_nano_pins.tcl` transcribes it.  The video is a
    // 24-bit bus with its own clock, a data enable and two syncs; the
    // transmitter's registers are written over the two-wire bus beside it,
    // which on this board goes to the fabric and not to the processor.
    output var logic [23:0] hdmi_d,
    output var logic        hdmi_pclk,
    output var logic        hdmi_de,
    output var logic        hdmi_hsync,
    output var logic        hdmi_vsync,
    // Open drain, both of them, with the board's resistors pulling up.
    inout  wire  logic      hdmi_scl,
    inout  wire  logic      hdmi_sda
    //
    // **AND FIVE PINS THE BOARD HAS THAT THIS DESIGN LEAVES OUT**, which is
    // a decision and not an oversight, recorded here as the Arty Z7-20's top
    // level records the four it leaves out of its own connector.
    // `HDMI_TX_INT` is the transmitter's interrupt, and nothing here changes
    // its behavior on anything the part could report, so reading it would be
    // a signal with no consumer.  `HDMI_I2S`, `HDMI_MCLK`, `HDMI_LRCLK` and
    // `HDMI_SCLK` are the audio interface, and this machine has no audio:
    // `docs/display-output.md` says the same of the Arty's data islands.  A
    // port with no pin cannot be placed, so leaving them out of the list is
    // how they stay off the part.
`endif
);

`ifdef CADR_DE25_HDMI
`ifndef CADR_DE25_DDR
  if (1) begin : g_hdmi_without_ddr
    $error("CADR_DE25_HDMI needs CADR_DE25_DDR: the display reads the machine's memory");
  end
`endif
`endif

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

  // The machine's reset: the fabric's, the console's `RESET_KEY`, the debug
  // cable's modifier bit 1 --- which is this processor's power-on reset when
  // a debugger asks for it --- and **the hold that makes the machine wait for
  // its memory**.
  //
  // **THE HOLD IS THE ONE PIECE THIS BOARD NEEDS AND THE ZYNQ BOARDS DO NOT.**
  // On a Zynq board the processing system is configured before the fabric is,
  // so `S_AXI_HP0` is live before the machine's first tick.  Here the fabric
  // is configured first and the bridge is opened by software in U-Boot,
  // seconds later, while the boot PROM's ONLY traffic to main memory ---
  // PAGE-0-PARITY-FIX, 512 bus cycles and no others --- is 118 ms after the
  // machine's own reset.  A machine released at the fabric's reset therefore
  // spends that one pass against a shut port every time and carries on with
  // nothing stored, on a board whose memory works.  So `mach_hold` is up
  // until the memory port has been live, and `rtl/plumbing/cadr_f2sdram_gate.sv`
  // holds it there; on the board without memory there is no port and no hold.
  // `tb/cadr_f2sdram_tb.cpp`'s OPEN and NEVER are the two halves of it.
  logic debuggee_reset;
  logic con_mach_rst;    // the console's word 6, `RESET_KEY`
  logic mach_hold;       // the machine waits for its memory port
  logic mach_rst;
  always_ff @(posedge clk)
    mach_rst <= rst || con_mach_rst || debuggee_reset || mach_hold;

  // ------------------------------------------------- KEY0 and SW0
  //
  // `-BOOT2` is the light panel's line, held down while the button is.  The
  // board's Schmitt trigger has already debounced it, so two synchronizer
  // stages are all it needs.  SW0 is a level read at the machine's reset arms
  // and nowhere else, so moving it under a running machine does nothing until
  // the next reset; three stages, as the other boards give it.
  //
  // `-BOOT2` is joined with the console's `BOOT_KEY`, as it is on the Zynq
  // boards: `cadr-console boot` is the same line as the button.  And SW0 is
  // read twice for the console --- the value the machine actually came out of
  // reset with, and where the switch is now --- because those are two
  // different facts and `cadr-console status` prints both.
  logic [1:0] btn0_sync;
  logic [2:0] sw0_sync;
  logic       n_boot2, con_mach_boot;
  logic       sw0_level, sw0_held;
  always_ff @(posedge clk) begin
    btn0_sync <= {btn0_sync[0], !btn[0]};
    sw0_sync  <= {sw0_sync[1:0], sw[0]};
  end
  assign n_boot2   = !(btn0_sync[1] || con_mach_boot);
  assign sw0_level = sw0_sync[2];
  always_ff @(posedge clk) if (mach_rst) sw0_held <= sw0_level;

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
  // **THE DISPLAY'S OWN SEAMS**, driven by the display section near the end
  // of this file on a board that has one and tied off there on a board that
  // does not: the color board's second map port, and what the console's word
  // 36 reads back of the sleep.
  logic [3:0]  disp_map_a;
  logic        disp_sleep_fitted, disp_asleep;
  logic [14:0] disp_sleep_setting;
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
  // **MIT'S DEBUG CABLE, THIS MACHINE'S TWO ENDS OF IT**, named as
  // `boards/arty-z7-20/cadr_arty.sv` names them so that a person who knows
  // that board knows this one.  `dbd_from_machine` is `DBD<15:0>` as this
  // machine's DBGIN page drives it, with `dbd_oe` saying which of its two
  // bytes, and it goes to BOTH ways in --- the register window and the
  // connector --- because the cable is one bus.  `dbgout_*` is the other end,
  // the DBGOUT page, which is CC on this machine debugging a second board.
  logic        dbg_in_ack;
  logic [15:0] dbd_from_machine;
  logic [1:0]  dbd_oe;
  logic        dbgout_req, dbgout_wr;
  logic [1:0]  dbgout_a;
  logic [15:0] dbgout_dbd;
  logic        dbgout_ack, dbgout_live;
  logic [15:0] dbgout_dbd_in;
  logic        timeout_inhibit;
  logic [31:0] con_vma, con_q, con_md;
  logic [47:0] con_ro_data;
  logic [17:0] con_ro_echo;
  logic        mem_req, mem_write;
  logic [31:0] mem_addr, mem_wdata;
  logic        mem_done;
  logic [31:0] mem_rdata;
  logic        port_read_ack, port_write_ack;

  // And the seams the register faces drive, which are `cadr_machine`'s inputs:
  // the disk's cable and its block store, the I/O board's four cables, the
  // console's Unibus port and the debug cable's near end.  They are declared
  // here and driven in ONE of the two arms below --- by the faces on the
  // memory board, and by the tie-offs of an unplugged cable on the board
  // without --- because the machine is instantiated once and does not know
  // which board it is on.
  logic [7:0]  drive_present, drive_read_only;
  logic        drive_timed;
  logic        store_we, store_busy, store_deny;
  logic [4:0]  store_slot, store_busy_slot;
  logic [8:0]  store_addr;
  logic [31:0] store_wdata;
  logic        kbd_strobe;
  logic [23:0] kbd_code;
  logic [6:0]  mouse_lines;
  logic        ser_tx_take, ser_tx_done, ser_rx_strobe;
  logic [7:0]  ser_rx_data;
  logic        ser_rx_end, ser_rx_parity, ser_rx_framing, ser_plugged;
  logic [15:0] chaos_address, chaos_rx_word;
  logic        chaos_rx_valid, chaos_rx_done, chaos_rx_crc, chaos_rx_lost;
  logic [12:0] chaos_rx_bits;
  logic        chaos_tx_done, chaos_tx_abort, chaos_cbl_busy;
  logic        con_req, con_msyn, con_write;
  logic [17:0] con_addr, con_ro_addr;
  logic [15:0] con_wdata;
  logic        con_tv_lispm, con_color_tv, con_steady_lamps;
  logic [3:0]  con_tv_map_a;
  // **THE DEBUG CABLE'S NEAR END HAS TWO ARMS ON THIS BOARD**, which MIT's
  // board cannot have, there being one DBGIN connector.  `dbg_in_*` and
  // `dbd_to_machine` are the register window's, muir on this board's own
  // cores; `cab_*` is the connector's, a second board's debugger arriving on
  // JP1.  `rtl/plumbing/cadr_dbg_join.sv` is what says which of the two holds
  // the page, and `mdbg_*` is its one cable into `rtl/machine/cadr_dbgin.sv`.
  // The window's arm is tied off on a board with no processor and the
  // connector's is live on every board, which is what "a debuggee always
  // listens" is as wiring.
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

  // And what the connector is: the role this board asks for and the role it
  // HAS, which are two facts, with which way round the ribbon was made and
  // what came of that.  `dbg_connect` and `dbg_wiring` come from the console's
  // page 0 word 14 on a board that has one and are tied off on a board that
  // does not; the seven the other way are what the console reports back.
  logic        dbg_connect, dbg_engaged, dbg_foreign, dbg_live, dbg_active;
  logic        dbg_peer_far;
  logic [1:0]  dbg_wiring;
  logic [2:0]  dbg_wire_state;
  logic [23:0] dbg_frames;
  // The eight pads, as the connector hands them out: the level, the tri-state
  // enable --- HIGH is NOT driven, which is the sense `cadr_dbg_cable.sv`
  // writes them in --- and what comes back off the header.
  logic [7:0]  dbg_pin_o, dbg_pin_t, dbg_pin_i;

  cadr_machine #(
      .PROM_HEX(PROM_HEX),
      .SYNC_PROM_HEX(SYNC_PROM_HEX),
      .MACHINE(MACHINE),
      .SYNC_K(SYNC_K),
      .SYNC_L(SYNC_L)
  ) u_machine (
      .clk(clk), .rst(mach_rst),
      .sintr_o(sintr),
      // **THE DISK'S CABLE AND ITS BLOCK STORE.**  On the memory board
      // `rtl/plumbing/cadr_disk_pack.sv` is the far end of them, with the
      // drives a program in Linux presents; on the board without, the cable
      // is empty and the status register answers `0x2321` for every one of
      // the boot PROM's polls.
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed),
      .store_we(store_we), .store_slot(store_slot), .store_addr(store_addr),
      .store_wdata(store_wdata), .store_rdata(store_rdata),
      .store_miss(store_miss), .ch_active(ch_active),
      .store_busy(store_busy), .store_busy_slot(store_busy_slot),
      .store_deny(store_deny),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit),
      // **THE I/O BOARD'S FOUR CABLES.**  On the memory board the far ends
      // are `cadr_input_cables.sv`, `cadr_serial_line.sv` and
      // `cadr_chaos_cable.sv` behind the bridge; on the board without, every
      // cable is unplugged.
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code), .mouse_lines(mouse_lines),
      .n_boot2(n_boot2), .no_auto_boot(sw0_level),
      .ser_reset(ser_reset), .ser_mode1(ser_mode1), .ser_mode2(ser_mode2),
      .ser_cmd(ser_cmd), .ser_tx_strobe(ser_tx_strobe),
      .ser_tx_data(ser_tx_data),
      .ser_tx_take(ser_tx_take), .ser_tx_done(ser_tx_done),
      .ser_rx_strobe(ser_rx_strobe),
      .ser_rx_data(ser_rx_data), .ser_rx_end(ser_rx_end),
      .ser_rx_parity(ser_rx_parity),
      .ser_rx_framing(ser_rx_framing), .ser_plugged(ser_plugged),
      .ser_status(ser_status), .ser_syn_face(ser_syn_face),
      .chaos_address(chaos_address), .chaos_tx_go(chaos_tx_go),
      .chaos_tx_len(chaos_tx_len), .chaos_tx_valid(chaos_tx_valid),
      .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word),
      .chaos_rx_done(chaos_rx_done),
      .chaos_rx_bits(chaos_rx_bits), .chaos_rx_crc(chaos_rx_crc),
      .chaos_rx_lost(chaos_rx_lost),
      .chaos_tx_done(chaos_tx_done), .chaos_tx_abort(chaos_tx_abort),
      .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits(chaos_bits),
      .iob_intr(iob_intr), .iob_vector(iob_vector), .audio(audio),
      .csr_face(csr_face), .mouse_x(mouse_x), .mouse_y(mouse_y),
      .clock_ready(clock_ready), .interval(interval),
      // 32 boards of 64K words, muir's default.  **THE BACKPLANE IS THE
      // CONSOLE'S TO SAY**, page 2's word 33, and with no console it is one
      // SIMPLE TV and no color board.
      .boards(7'd32),
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
      .tv_map_a(con_tv_map_a), .tv_map_q(tv_map_q),
      .tv_color_map_q(tv_color_map_q),
      // **THE COLOR BOARD'S SECOND MAP PORT IS THE DISPLAY'S**, an entry a
      // raster line, which is the cable to the off-board converters that
      // `docs/display-output.md` describes; tied to zero on a board with no
      // display, where nothing reads what comes back.
      .disp_map_a(disp_map_a), .disp_color_map_q(disp_color_map_q),
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
      // **THE CONSOLE'S UNIBUS PORT**, the second master on the diagnostic
      // bus: `rtl/plumbing/cadr_console.sv` on the lightweight bridge drives
      // it on the memory board.  With no console `con_req` and `con_msyn`
      // are down, the arbiter never grants, and the register block keeps its
      // one master.
      .con_req(con_req), .con_gnt(con_gnt), .con_msyn(con_msyn),
      .con_write(con_write), .con_addr(con_addr), .con_wdata(con_wdata),
      .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      // **THE DEBUG CABLE, BOTH OF THIS MACHINE'S ENDS OF IT.**  The DBGIN
      // page takes `mdbg_*`, which is the join's one cable: two debuggers
      // reach this page and only one holds it at a time.  The near arm is
      // `rtl/plumbing/cadr_debug_window.sv` on the lightweight bridge, muir
      // on this board's own cores, present on the memory board and tied off
      // on the board without; the far arm is the connector on JP1, present on
      // every board, because a CADR always answers a debugger that plugs in.
      // With BOTH quiet `-DEBUG IN REQ` stands UP, which is `mdbg_req` low:
      // what the SIP at DBGIN 0A22 makes of an unplugged connector, and the
      // page folds to its idle state.
      //
      // The DBGOUT page is the other way round --- CC on THIS machine
      // debugging a second board --- and it now reaches a real connector
      // instead of the bare one this board used to describe.  `dbgout_live`
      // says whether there is a board at the far end at all, and with none
      // `cadr_dbg_cable.sv` answers every data line as ones, which is what a
      // CADR with a bare connector reads.
      .dbg_in_req(mdbg_req), .dbg_in_wr(mdbg_wr), .dbg_in_a(mdbg_a),
      .dbd_in(mdbg_dbd),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      .dbgout_req(dbgout_req), .dbgout_wr(dbgout_wr), .dbgout_a(dbgout_a),
      .dbgout_dbd(dbgout_dbd), .dbgout_ack(dbgout_ack),
      .dbgout_dbd_in(dbgout_dbd_in), .dbgout_live(dbgout_live),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit),
      // The DBGIN page's own reset is the fabric's and not `mach_rst`, for
      // the reason `cadr_machine` gives: a modifier register cleared by its
      // own bit 1 could never be written.
      .dbg_rst(rst),
      .con_vma(con_vma), .con_q(con_q), .con_md(con_md),
      // The readout, page 0's words 10, 11 and 12 of the console.  With no
      // console the address stands at the reserved selector and the machine
      // answers `RO_NO_MEMORY` for ever.
      .con_ro_addr(con_ro_addr), .con_ro_data(con_ro_data),
      .con_ro_echo(con_ro_echo),
      // THE MEMORY, OR NONE.  With `DDR` off nothing ever answers, so the
      // NXM timer ends every main-memory cycle; with it on, the memory
      // section below answers through the processor's bridge.  No port
      // answers the transaction audit on either board: it has no register on
      // a board with no console to read it.
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      // **THE PORT'S OWN ANSWERS, FOR THE TRANSACTION AUDIT.**  The bridge's
      // handshakes and nothing the fabric decides for itself, which is what
      // makes the audit's word 8 able to tell a silent port from an answering
      // one.  `rtl/plumbing/cadr_f2sdram_port.sv` makes the pair off the same
      // registered copies the tally counts; on the board without memory
      // nothing answers and nothing is counted.
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack)
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
                   dbg_in_ack, dbd_from_machine, dbd_oe,
                   dbgout_req, dbgout_wr, dbgout_a, dbgout_dbd,
                   debuggee_reset, timeout_inhibit,
                   tv_map_q, tv_color_map_q, disp_color_map_q,
                   // **AND THE CONNECTOR'S OWN SEVEN**, which are not outputs
                   // of `cadr_machine` at all: they say what JP1 is doing
                   // rather than what crosses it.  On the memory board page
                   // 0's word 14 reports them and this is a second reader; on
                   // a board with no console the fold is the ONLY reader, and
                   // without it the fitter trims the role, the wiring
                   // detection and the frame counters away and leaves a pin
                   // count where a connector should be.  `dbg_holder` is the
                   // join's, and is here for the same reason.
                   dbg_engaged, dbg_foreign, dbg_peer_far, dbg_live,
                   dbg_active, dbg_wire_state, dbg_frames, dbg_holder};
    end
  end

  // ------------------------------------ MIT's debug cable, on JP1's pins
  //
  // **THE WHOLE CABLE ON ONE CONNECTOR, BOTH DIRECTIONS, FOUR PINS EACH WAY.**
  // `rtl/plumbing/cadr_dbg_cable.sv` is the connector and the role;
  // `cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` under it are the carrier, and
  // `docs/debug-cable.md` is the design.  The frame is twenty-four beats,
  // which is twenty-one signals, a two-bit marker and a parity bit over ONE
  // data line: one signal a pair, with the other line of the pair driven low
  // as a guard.
  //
  // **WHERE IT IS: JP1 PINS 31 TO 38, WITH THE HEADER'S OWN GROUND ON PIN 30
  // BESIDE THEM.**  The Zynq boards have Pmod headers and this board has none,
  // so a cable between this board and one of those is an ADAPTER and the
  // question the other boards answered by taking a whole Pmod has to be
  // answered again here.  It is answered by carrying the Pmod's own numbering
  // across: index k of the carrier is header pin 31 + k, and those eight land
  // on Pmod pins 1, 2, 3, 4, 7, 8, 9 and 10 in that order, which is exactly
  // the order `boards/arty-z7-20/cadr_arty.xdc` puts them in.
  //
  //   | index | JP1 pin | package | Pmod pin | what it carries          |
  //   |-------|---------|---------|----------|--------------------------|
  //   | 0     | 31      | H19     | 1        | debugger strobe          |
  //   | 1     | 32      | AH19    | 2        | guard, driven low        |
  //   | 2     | 33      | R19     | 3        | debugger data            |
  //   | 3     | 34      | R14     | 4        | guard, driven low        |
  //   | 4     | 35      | V19     | 7        | debuggee strobe          |
  //   | 5     | 36      | V14     | 8        | guard, driven low        |
  //   | 6     | 37      | AG31    | 9        | debuggee data            |
  //   | 7     | 38      | AL31    | 10       | guard, driven low        |
  //
  // The package pins are the user manual's Figure 3-18 on page 23, through
  // `boards/de25-nano/de25_nano_pins.tcl`, and are not written here: this file
  // names header pins and the pin file is the one place a package pin is
  // written.  `tools/de25_faces_check.py` is what holds the two together, and
  // holds the table above to being the one the connector itself describes.
  //
  // **SIGNALS ON THE ODD PINS, GUARDS ON THE EVEN.**  It falls out of `31 + k`
  // and it is the property that matters: a Pmod's own signal pins are 1, 3, 7
  // and 9 and its guards 2, 4, 8 and 10, so an adapter that joins pin to pin
  // puts each signal on its counterpart at the far end.  On this header it
  // also means no two signals are adjacent in the ribbon --- 31 signal, 32
  // guard, 33 signal, 34 guard and so on --- with the header's ground on pin
  // 30 at the end of the run.
  //
  // **AND THE SUPPLY PINS MUST BE OPEN AT BOTH ENDS.**  JP1 carries 5 V on pin
  // 11 and 3.3 V on pin 29; a Pmod carries 3.3 V on 6 and 12.  The grounds
  // must be joined and the supplies must not: two boards' regulators tied
  // together is not something either of them is built for.  Neither supply pin
  // is a fabric pin at all, so nothing here can drive one, and what the fabric
  // can promise ends there --- the rest is the person making the cable, and
  // `docs/debug-cable.md` says so for every board.
  //
  // **IT TAKES THE BOARD'S RESET AND NOT THE MACHINE'S.**  Modifier bit 1 of
  // this very cable resets this machine, so a connector reset by it would
  // forget the request that asked for it, and MIT's own "write a 1 here then
  // write a 0" could not be written at all.  That is the same reason the DBGIN
  // page takes `rst` at `.dbg_rst` above.
  cadr_dbg_cable u_dbg_cable (
      .clk(clk), .rst(rst),
      // The role.  `connect` is the console's word 14 and the `fpgarc` line
      // behind it; `engaged` is whether this board TOOK it, which is not the
      // same question --- a board that can see a debugger on the forward group
      // refuses, and `foreign` is how the console says why.
      .connect(dbg_connect), .engaged(dbg_engaged), .foreign(dbg_foreign),
      .peer_far(dbg_peer_far), .live(dbg_live), .active(dbg_active),
      // Which way round the ribbon was made, and what the board found.  Only
      // a DEBUGGER applies it; a debuggee always drives the high four.
      .wiring(dbg_wiring), .wire_state(dbg_wire_state),
      // Frames heard and frames refused, page 0's word 15.
      .frames(dbg_frames),
      // This machine's own DBGOUT page: CC on this board, writing
      // `0o766100`-`0o766137`, debugging the board at the far end.
      .out_req(dbgout_req), .out_wr(dbgout_wr), .out_a(dbgout_a),
      .out_dbd(dbgout_dbd), .out_ack(dbgout_ack),
      .out_dbd_in(dbgout_dbd_in), .out_live(dbgout_live),
      // And a second board's debugger arriving here, which joins the window's
      // cable at the page below.
      .in_req(cab_req), .in_wr(cab_wr), .in_a(cab_a), .in_dbd(cab_dbd),
      .in_ack(dbg_in_ack), .in_dbd_out(dbd_from_machine), .in_dbd_oe(dbd_oe),
      .pin_o(dbg_pin_o), .pin_t(dbg_pin_t), .pin_i(dbg_pin_i)
  );

  // The eight pads.  `pin_t` is HIGH for NOT DRIVEN, so the group this board
  // does not own is high-impedance and the far end has it; a pad driven
  // unconditionally is two drivers on one wire the moment a second board is
  // on the cable, which is the one failure this connector's whole design is
  // about.  Written as one continuous assignment a pad, and named by header
  // pin on both sides, so that the map above is read off these lines rather
  // than believed.
  assign jp1_pin31 = dbg_pin_t[0] ? 1'bz : dbg_pin_o[0];
  assign jp1_pin32 = dbg_pin_t[1] ? 1'bz : dbg_pin_o[1];
  assign jp1_pin33 = dbg_pin_t[2] ? 1'bz : dbg_pin_o[2];
  assign jp1_pin34 = dbg_pin_t[3] ? 1'bz : dbg_pin_o[3];
  assign jp1_pin35 = dbg_pin_t[4] ? 1'bz : dbg_pin_o[4];
  assign jp1_pin36 = dbg_pin_t[5] ? 1'bz : dbg_pin_o[5];
  assign jp1_pin37 = dbg_pin_t[6] ? 1'bz : dbg_pin_o[6];
  assign jp1_pin38 = dbg_pin_t[7] ? 1'bz : dbg_pin_o[7];
  // And what comes back off the header, most significant first: index 7 is
  // pin 38 and index 0 is pin 31, which is the same map the eight lines above
  // drive.  Driving one pin and listening on another is a board that hears
  // its own guard, and nothing that reads only one of the two halves can see
  // it, so both are written and `tools/de25_faces_check.py` compares them.
  assign dbg_pin_i = {jp1_pin38, jp1_pin37, jp1_pin36, jp1_pin35,
                      jp1_pin34, jp1_pin33, jp1_pin32, jp1_pin31};

  // Two debuggers at one DBGIN page, which MIT's board cannot have and this
  // one can.  The near arm is the register window and the far arm the
  // connector, the first to assert holds until it lifts, and a tie goes to
  // the window --- `rtl/plumbing/cadr_dbg_join.sv` has the argument.  With
  // nothing in JP1 the connector presents zeros, so this is the window's cable
  // unchanged; on a board with no processor the window's arm is tied off
  // below, so it is the connector's cable unchanged.
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
  // where `tb/cadr_f2sdram_tb.cpp` runs the machine through them.
  //
  // **THE SHARE'S SECOND PORT IS THE DISK PACK SIDE'S**, which is
  // `S_AXI_HP2`'s role on the Zynq boards: the master that fetches a block
  // from the pack in memory into the controller's store and writes one back.
  // It is the AXI3 shape `cadr_disk_pack.sv` already has, which is the shape
  // the share takes, so nothing is adapted between them.
  //
  // **AND ITS THIRD IS THE DISPLAY'S**, `S_AXI_HP3`'s role there: read only,
  // the same AXI3 shape, and the master `rtl/plumbing/cadr_display_out.sv`
  // already puts out.  The three ports the Zynq gives the machine, the disk
  // and the display are one bridge here, and the burst-level arbiter in
  // `rtl/plumbing/cadr_f2sdram_share.sv` is where they meet with the machine
  // first.  On a board built without the display its valid is low, so
  // nothing is ever granted to it, and its ready is high, so a response would
  // be taken.
  logic [31:0] dm_araddr;
  logic [3:0]  dm_arlen;
  logic [1:0]  dm_arsize, dm_arburst;
  logic        dm_arvalid, dm_arready;
  logic [63:0] dm_rdata;
  logic [1:0]  dm_rresp;
  logic        dm_rlast, dm_rvalid, dm_rready;

  logic [31:0] pm_awaddr, pm_araddr;
  logic [3:0]  pm_awlen, pm_arlen;
  logic [1:0]  pm_awsize, pm_arsize, pm_awburst, pm_arburst;
  logic        pm_awvalid, pm_awready, pm_wlast, pm_wvalid, pm_wready;
  logic        pm_bvalid, pm_bready, pm_arvalid, pm_arready;
  logic        pm_rlast, pm_rvalid, pm_rready;
  logic [63:0] pm_wdata, pm_rdata;
  logic [7:0]  pm_wstrb;
  logic [1:0]  pm_bresp, pm_rresp;

  logic may_start;
  assign mach_hold = !may_start;

  /* verilator lint_off PINCONNECTEMPTY */
  cadr_f2sdram_port u_memory (
      .clk(clk), .rst(rst),
      .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_done(mem_done), .mem_rdata(mem_rdata), .mem_error(),
      .h2f_reset(h2f_reset), .gp_open(gp_out[0]), .gp_half(gp_out[1]),
      .warm_req_n(warm_req_n), .warm_ack_n(warm_ack_n),
      .gp_in(gp_in), .live(port_live), .may_start(may_start),
      .port_read_ack(port_read_ack), .port_write_ack(port_write_ack),
      .p_awaddr(pm_awaddr), .p_awlen(pm_awlen), .p_awsize(pm_awsize),
      .p_awburst(pm_awburst), .p_awvalid(pm_awvalid), .p_awready(pm_awready),
      .p_wdata(pm_wdata), .p_wstrb(pm_wstrb), .p_wlast(pm_wlast),
      .p_wvalid(pm_wvalid), .p_wready(pm_wready),
      .p_bresp(pm_bresp), .p_bvalid(pm_bvalid), .p_bready(pm_bready),
      .p_araddr(pm_araddr), .p_arlen(pm_arlen), .p_arsize(pm_arsize),
      .p_arburst(pm_arburst), .p_arvalid(pm_arvalid), .p_arready(pm_arready),
      .p_rdata(pm_rdata), .p_rresp(pm_rresp), .p_rlast(pm_rlast),
      .p_rvalid(pm_rvalid), .p_rready(pm_rready),
      .d_araddr(dm_araddr), .d_arlen(dm_arlen), .d_arsize(dm_arsize),
      .d_arburst(dm_arburst),
      .d_arvalid(dm_arvalid), .d_arready(dm_arready),
      .d_rdata(dm_rdata), .d_rresp(dm_rresp), .d_rlast(dm_rlast),
      .d_rvalid(dm_rvalid), .d_rready(dm_rready),
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

  // ============================== the faces on the two processor-to-fabric
  //                                                                 bridges
  //
  // **EVERY ADDRESS OF BOTH BRIDGES IS ANSWERED**, which is this project's
  // oldest rule about a general-purpose port and the one it was taught by the
  // board: a read nothing answers on the Zynq's `M_AXI_GP0` does not fault
  // the Arm, it hangs BOTH cores at one PC each, measured.  Nothing says
  // these bridges are kinder, and Altera puts a default subordinate on both
  // of them in every design of its own.  So each bridge is split into its
  // pages and a last port for everything else, and `cadr_gp0_default.sv`
  // answers that: "NONE" to every read and OKAY to every write.
  //
  // **THE FABRIC SEES AN OFFSET INTO EACH WINDOW AND NOT THE PROCESSOR'S
  // ADDRESS**, which is why the bases below are not the ones a program uses.
  // The HPS-to-FPGA bridge's 1 GB window is at `0x4000_0000` and it hands the
  // fabric 30 bits; the lightweight bridge's 512 MB window is at
  // `0x2000_0000` and it hands the fabric 29.  So the pack side's page, which
  // a program reaches at `0x4000_0000`, is offset 0 here, and the console's,
  // which a program reaches at `0x2000_0000`, is offset 0 on the other
  // bridge.  The four faces keep their Zynq offsets from the window's base,
  // so `cadr_board.h` names the same four addresses on both boards.
  //
  //   the HPS-to-FPGA bridge        the lightweight bridge
  //     +0x0000  the pack side       +0x0000  the console
  //     +0x1000  the Chaosnet        +0x1000  the debug cable's window
  //     +0x2000  the serial line     everything else  the default slave
  //     +0x3000  keyboard and mouse
  //     everything else  the default slave
  //
  // **BOTH BRIDGES ARE AXI4 AND THE ZYNQ'S PORTS ARE AXI3**, so every module
  // here is built with four bits of ID where the Zynq boards give twelve, and
  // eight bits of burst length where they give four --- `ID_W` and `LEN_W`,
  // which `cadr_gp0_default.sv` already had and every face and both splitters
  // now take.  A read of up to 256 beats therefore ends where ARLEN says on
  // this board too, which is the same promise at a different width and not a
  // new one.  `build/gp0_split.pass` and `build/gp1_split.pass` run their
  // whole sweep twice, once at each shape and at each board's bases.
  //
  // THE RESET IS THE BRIDGES' OWN, `h2f_reset`, synchronized in: before
  // Linux is up the faces read zero, so the serial line's `CTL` is zero and
  // its cable is out, the Chaosnet's address switches read zero, and the
  // input face's queue is empty --- which is exactly what the tie-offs of the
  // board without a processor give the machine.
  //
  // **AND NOTHING ELSE, BECAUSE A TRANSACTION ON A BRIDGE IS THE
  // PROCESSOR'S.**  `h2f_rst` was once `rst ||` the bridges' reset, so KEY1
  // held both splitters and every face in their address states with AWREADY
  // and ARREADY high: an address taken then, or one in flight when the key
  // went down, was never answered.  So the splitters and the default slaves
  // take the bridges' reset alone, and every face takes KEY1 at `fabric_rst`,
  // which resets its registers and never its AXI state.  `docs/board.md`
  // has the rule, and `tb/cadr_board_reset_tb.cpp` presses KEY1 under reads
  // and writes on every page of both bridges.
  logic [2:0] h2f_rst_s;
  logic       h2f_rst;
  always_ff @(posedge clk) begin
    h2f_rst_s <= {h2f_rst_s[1:0], h2f_reset};
    h2f_rst   <= h2f_rst_s[2];
  end

  // ------------------------------------- the HPS-to-FPGA bridge, four faces
  logic [31:0] h2fp_awaddr, h2fp_araddr, h2fp_wdata, h2fp_rdata;
  logic [7:0]  h2fp_awlen, h2fp_arlen;
  logic [3:0]  h2fp_wstrb, h2fp_awid, h2fp_arid, h2fp_bid, h2fp_rid;
  logic        h2fp_awvalid, h2fp_awready, h2fp_wlast, h2fp_wvalid, h2fp_wready;
  logic        h2fp_bvalid, h2fp_bready, h2fp_arvalid, h2fp_arready;
  logic        h2fp_rlast, h2fp_rvalid, h2fp_rready;
  logic [1:0]  h2fp_bresp, h2fp_rresp;
  logic [11:0] h2fc_awaddr, h2fc_araddr;
  logic [31:0] h2fc_wdata, h2fc_rdata;
  logic [7:0]  h2fc_awlen, h2fc_arlen;
  logic [3:0]  h2fc_wstrb, h2fc_awid, h2fc_arid, h2fc_bid, h2fc_rid;
  logic        h2fc_awvalid, h2fc_awready, h2fc_wlast, h2fc_wvalid, h2fc_wready;
  logic        h2fc_bvalid, h2fc_bready, h2fc_arvalid, h2fc_arready;
  logic        h2fc_rlast, h2fc_rvalid, h2fc_rready;
  logic [1:0]  h2fc_bresp, h2fc_rresp;
  logic [11:0] h2fs_awaddr, h2fs_araddr;
  logic [31:0] h2fs_wdata, h2fs_rdata;
  logic [7:0]  h2fs_awlen, h2fs_arlen;
  logic [3:0]  h2fs_wstrb, h2fs_awid, h2fs_arid, h2fs_bid, h2fs_rid;
  logic        h2fs_awvalid, h2fs_awready, h2fs_wlast, h2fs_wvalid, h2fs_wready;
  logic        h2fs_bvalid, h2fs_bready, h2fs_arvalid, h2fs_arready;
  logic        h2fs_rlast, h2fs_rvalid, h2fs_rready;
  logic [1:0]  h2fs_bresp, h2fs_rresp;
  logic [11:0] h2fi_awaddr, h2fi_araddr;
  logic [31:0] h2fi_wdata, h2fi_rdata;
  logic [7:0]  h2fi_awlen, h2fi_arlen;
  logic [3:0]  h2fi_wstrb, h2fi_awid, h2fi_arid, h2fi_bid, h2fi_rid;
  logic        h2fi_awvalid, h2fi_awready, h2fi_wlast, h2fi_wvalid, h2fi_wready;
  logic        h2fi_bvalid, h2fi_bready, h2fi_arvalid, h2fi_arready;
  logic        h2fi_rlast, h2fi_rvalid, h2fi_rready;
  logic [1:0]  h2fi_bresp, h2fi_rresp;
  logic [31:0] h2fd_rdata;
  logic [7:0]  h2fd_arlen;
  logic [3:0]  h2fd_awid, h2fd_arid, h2fd_bid, h2fd_rid;
  logic        h2fd_awvalid, h2fd_awready, h2fd_wlast, h2fd_wvalid, h2fd_wready;
  logic        h2fd_bvalid, h2fd_bready, h2fd_arvalid, h2fd_arready;
  logic        h2fd_rlast, h2fd_rvalid, h2fd_rready;
  logic [1:0]  h2fd_bresp, h2fd_rresp;

  cadr_gp0_split #(
      .PACK_BASE (32'h0000_0000),
      .CHAOS_BASE(32'h0000_1000),
      .SER_BASE  (32'h0000_2000),
      .INPUT_BASE(32'h0000_3000),
      .ID_W(4), .LEN_W(8)
  ) u_h2f_split (
      .clk(clk), .rst(h2f_rst),
      .s_awaddr({2'b00, h2f_awaddr}), .s_awlen(h2f_awlen), .s_awid(h2f_awid),
      .s_awvalid(h2f_awvalid), .s_awready(h2f_awready),
      .s_wdata(h2f_wdata), .s_wstrb(h2f_wstrb), .s_wlast(h2f_wlast),
      .s_wvalid(h2f_wvalid), .s_wready(h2f_wready),
      .s_bresp(h2f_bresp), .s_bid(h2f_bid), .s_bvalid(h2f_bvalid),
      .s_bready(h2f_bready),
      .s_araddr({2'b00, h2f_araddr}), .s_arlen(h2f_arlen), .s_arid(h2f_arid),
      .s_arvalid(h2f_arvalid), .s_arready(h2f_arready),
      .s_rdata(h2f_rdata), .s_rresp(h2f_rresp), .s_rid(h2f_rid),
      .s_rlast(h2f_rlast), .s_rvalid(h2f_rvalid), .s_rready(h2f_rready),
      .pack_awaddr(h2fp_awaddr), .pack_awlen(h2fp_awlen), .pack_awid(h2fp_awid),
      .pack_awvalid(h2fp_awvalid), .pack_awready(h2fp_awready),
      .pack_wdata(h2fp_wdata), .pack_wstrb(h2fp_wstrb), .pack_wlast(h2fp_wlast),
      .pack_wvalid(h2fp_wvalid), .pack_wready(h2fp_wready),
      .pack_bresp(h2fp_bresp), .pack_bid(h2fp_bid), .pack_bvalid(h2fp_bvalid),
      .pack_bready(h2fp_bready),
      .pack_araddr(h2fp_araddr), .pack_arlen(h2fp_arlen), .pack_arid(h2fp_arid),
      .pack_arvalid(h2fp_arvalid), .pack_arready(h2fp_arready),
      .pack_rdata(h2fp_rdata), .pack_rresp(h2fp_rresp), .pack_rid(h2fp_rid),
      .pack_rlast(h2fp_rlast), .pack_rvalid(h2fp_rvalid),
      .pack_rready(h2fp_rready),
      .chaos_awaddr(h2fc_awaddr), .chaos_awlen(h2fc_awlen),
      .chaos_awid(h2fc_awid),
      .chaos_awvalid(h2fc_awvalid), .chaos_awready(h2fc_awready),
      .chaos_wdata(h2fc_wdata), .chaos_wstrb(h2fc_wstrb),
      .chaos_wlast(h2fc_wlast),
      .chaos_wvalid(h2fc_wvalid), .chaos_wready(h2fc_wready),
      .chaos_bresp(h2fc_bresp), .chaos_bid(h2fc_bid),
      .chaos_bvalid(h2fc_bvalid), .chaos_bready(h2fc_bready),
      .chaos_araddr(h2fc_araddr), .chaos_arlen(h2fc_arlen),
      .chaos_arid(h2fc_arid),
      .chaos_arvalid(h2fc_arvalid), .chaos_arready(h2fc_arready),
      .chaos_rdata(h2fc_rdata), .chaos_rresp(h2fc_rresp), .chaos_rid(h2fc_rid),
      .chaos_rlast(h2fc_rlast), .chaos_rvalid(h2fc_rvalid),
      .chaos_rready(h2fc_rready),
      .ser_awaddr(h2fs_awaddr), .ser_awlen(h2fs_awlen), .ser_awid(h2fs_awid),
      .ser_awvalid(h2fs_awvalid), .ser_awready(h2fs_awready),
      .ser_wdata(h2fs_wdata), .ser_wstrb(h2fs_wstrb), .ser_wlast(h2fs_wlast),
      .ser_wvalid(h2fs_wvalid), .ser_wready(h2fs_wready),
      .ser_bresp(h2fs_bresp), .ser_bid(h2fs_bid), .ser_bvalid(h2fs_bvalid),
      .ser_bready(h2fs_bready),
      .ser_araddr(h2fs_araddr), .ser_arlen(h2fs_arlen), .ser_arid(h2fs_arid),
      .ser_arvalid(h2fs_arvalid), .ser_arready(h2fs_arready),
      .ser_rdata(h2fs_rdata), .ser_rresp(h2fs_rresp), .ser_rid(h2fs_rid),
      .ser_rlast(h2fs_rlast), .ser_rvalid(h2fs_rvalid), .ser_rready(h2fs_rready),
      .in_awaddr(h2fi_awaddr), .in_awlen(h2fi_awlen), .in_awid(h2fi_awid),
      .in_awvalid(h2fi_awvalid), .in_awready(h2fi_awready),
      .in_wdata(h2fi_wdata), .in_wstrb(h2fi_wstrb), .in_wlast(h2fi_wlast),
      .in_wvalid(h2fi_wvalid), .in_wready(h2fi_wready),
      .in_bresp(h2fi_bresp), .in_bid(h2fi_bid), .in_bvalid(h2fi_bvalid),
      .in_bready(h2fi_bready),
      .in_araddr(h2fi_araddr), .in_arlen(h2fi_arlen), .in_arid(h2fi_arid),
      .in_arvalid(h2fi_arvalid), .in_arready(h2fi_arready),
      .in_rdata(h2fi_rdata), .in_rresp(h2fi_rresp), .in_rid(h2fi_rid),
      .in_rlast(h2fi_rlast), .in_rvalid(h2fi_rvalid), .in_rready(h2fi_rready),
      .dflt_awid(h2fd_awid), .dflt_awvalid(h2fd_awvalid),
      .dflt_awready(h2fd_awready),
      .dflt_wlast(h2fd_wlast), .dflt_wvalid(h2fd_wvalid),
      .dflt_wready(h2fd_wready),
      .dflt_bresp(h2fd_bresp), .dflt_bid(h2fd_bid), .dflt_bvalid(h2fd_bvalid),
      .dflt_bready(h2fd_bready),
      .dflt_arlen(h2fd_arlen), .dflt_arid(h2fd_arid),
      .dflt_arvalid(h2fd_arvalid), .dflt_arready(h2fd_arready),
      .dflt_rdata(h2fd_rdata), .dflt_rresp(h2fd_rresp), .dflt_rid(h2fd_rid),
      .dflt_rlast(h2fd_rlast), .dflt_rvalid(h2fd_rvalid),
      .dflt_rready(h2fd_rready)
  );

  // **THE PACK SIDE**, its register face on this bridge and its master on the
  // share's second port.  **ITS RESET IS THE BRIDGE'S AND THE BRIDGE'S
  // ALONE**, as every other face on both bridges takes, and the memory port's
  // liveness reaches it as a signal instead.  KEY1 reaches it at
  // `fabric_rst`: its registers at once, and its master once the burst it
  // has in flight on the share has ended, so that the gate's drain finds it
  // finishing rather than abandoned.
  //
  // The reason is a defect this board had and the Zynq boards cannot have.
  // The reset here was once the bridge's and the memory port's together, in
  // imitation of `MAXIGP0ARESETN` and `SAXIHP2ARESETN`; but on a Zynq board
  // the processing system drives both, so the pack's port is live whenever
  // the general-purpose port is, and there is no interval between them.  Here
  // the memory port is opened by SOFTWARE, seconds after the bridge comes up,
  // so the interval is every boot --- and through all of it the face sat in
  // reset, which on this page does not stall a read but SWALLOWS it: the read
  // state machine is held in its address state, `s_arready` is high there, so
  // the address is taken and no beat is ever returned.  Measured on the
  // board: a read of this page before the memory port was opened hung both
  // processor cores, once by hand at the boot monitor and once on the
  // ordinary path, where the disk pack program's first register read arrives
  // while the port is still shut.  The tally the programs read first cannot
  // see it --- it is answered by a face on the other bridge, and answering is
  // not evidence about this one.
  //
  // So the rule this board keeps is the rule the whole arrangement exists
  // for, with the half that was missing restored: every address of both
  // windows is answered, and at every time the bridge is out of reset.
  // `port_live` goes to `cadr_disk_pack.sv`'s own input of that name, where
  // it refuses a MOVE --- which is the thing that really has nowhere to put a
  // block while the memory is shut --- and touches nothing on the face.
  cadr_disk_pack #(
      .REG_BASE(32'h0000_0000), .ID_W(4), .LEN_W(8)
  ) u_pack (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst), .port_live(port_live),
      .s_awaddr(h2fp_awaddr), .s_awlen(h2fp_awlen), .s_awid(h2fp_awid),
      .s_awvalid(h2fp_awvalid), .s_awready(h2fp_awready),
      .s_wdata(h2fp_wdata), .s_wstrb(h2fp_wstrb), .s_wlast(h2fp_wlast),
      .s_wvalid(h2fp_wvalid), .s_wready(h2fp_wready),
      .s_bresp(h2fp_bresp), .s_bid(h2fp_bid), .s_bvalid(h2fp_bvalid),
      .s_bready(h2fp_bready),
      .s_araddr(h2fp_araddr), .s_arlen(h2fp_arlen), .s_arid(h2fp_arid),
      .s_arvalid(h2fp_arvalid), .s_arready(h2fp_arready),
      .s_rdata(h2fp_rdata), .s_rresp(h2fp_rresp), .s_rid(h2fp_rid),
      .s_rlast(h2fp_rlast), .s_rvalid(h2fp_rvalid), .s_rready(h2fp_rready),
      .m_awaddr(pm_awaddr), .m_awlen(pm_awlen), .m_awsize(pm_awsize),
      .m_awburst(pm_awburst), .m_awvalid(pm_awvalid), .m_awready(pm_awready),
      .m_wdata(pm_wdata), .m_wstrb(pm_wstrb), .m_wlast(pm_wlast),
      .m_wvalid(pm_wvalid), .m_wready(pm_wready),
      .m_bresp(pm_bresp), .m_bvalid(pm_bvalid), .m_bready(pm_bready),
      .m_araddr(pm_araddr), .m_arlen(pm_arlen), .m_arsize(pm_arsize),
      .m_arburst(pm_arburst), .m_arvalid(pm_arvalid), .m_arready(pm_arready),
      .m_rdata(pm_rdata), .m_rresp(pm_rresp), .m_rlast(pm_rlast),
      .m_rvalid(pm_rvalid), .m_rready(pm_rready),
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

  cadr_chaos_cable #(.ID_W(4), .LEN_W(8)) u_chaos (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst),
      .s_awaddr(h2fc_awaddr), .s_awlen(h2fc_awlen), .s_awid(h2fc_awid),
      .s_awvalid(h2fc_awvalid), .s_awready(h2fc_awready),
      .s_wdata(h2fc_wdata), .s_wstrb(h2fc_wstrb), .s_wlast(h2fc_wlast),
      .s_wvalid(h2fc_wvalid), .s_wready(h2fc_wready),
      .s_bresp(h2fc_bresp), .s_bid(h2fc_bid), .s_bvalid(h2fc_bvalid),
      .s_bready(h2fc_bready),
      .s_araddr(h2fc_araddr), .s_arlen(h2fc_arlen), .s_arid(h2fc_arid),
      .s_arvalid(h2fc_arvalid), .s_arready(h2fc_arready),
      .s_rdata(h2fc_rdata), .s_rresp(h2fc_rresp), .s_rid(h2fc_rid),
      .s_rlast(h2fc_rlast), .s_rvalid(h2fc_rvalid), .s_rready(h2fc_rready),
      .chaos_address(chaos_address),
      .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word),
      .chaos_tx_clear(chaos_tx_clear), .chaos_reset(chaos_reset),
      .chaos_csr(chaos_csr),
      .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word),
      .chaos_rx_done(chaos_rx_done), .chaos_rx_bits(chaos_rx_bits),
      .chaos_rx_crc(chaos_rx_crc), .chaos_rx_lost(chaos_rx_lost),
      .chaos_tx_done(chaos_tx_done), .chaos_tx_abort(chaos_tx_abort),
      .chaos_cbl_busy(chaos_cbl_busy),
      .irq(chaos_irq)
  );

  cadr_serial_line #(.ID_W(4), .LEN_W(8)) u_serial (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst),
      .s_awaddr(h2fs_awaddr), .s_awlen(h2fs_awlen), .s_awid(h2fs_awid),
      .s_awvalid(h2fs_awvalid), .s_awready(h2fs_awready),
      .s_wdata(h2fs_wdata), .s_wstrb(h2fs_wstrb), .s_wlast(h2fs_wlast),
      .s_wvalid(h2fs_wvalid), .s_wready(h2fs_wready),
      .s_bresp(h2fs_bresp), .s_bid(h2fs_bid), .s_bvalid(h2fs_bvalid),
      .s_bready(h2fs_bready),
      .s_araddr(h2fs_araddr), .s_arlen(h2fs_arlen), .s_arid(h2fs_arid),
      .s_arvalid(h2fs_arvalid), .s_arready(h2fs_arready),
      .s_rdata(h2fs_rdata), .s_rresp(h2fs_rresp), .s_rid(h2fs_rid),
      .s_rlast(h2fs_rlast), .s_rvalid(h2fs_rvalid), .s_rready(h2fs_rready),
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

  // The keyboard's cable and the mouse's.  **`mach_rst` AND NOT THE BRIDGE'S
  // RESET FOR THE QUEUE'S FLUSH**, which is the whole reason that port
  // exists: the console can restart the CADR while Linux runs, and the
  // restarted microcode asks whether anybody is typing four instructions in,
  // so a key queued before the restart would send it down the warm-boot path.
  // The face's own reset stays the BRIDGE'S, because resetting an AXI state
  // machine mid-transaction is how a console would hang a core.
  cadr_input_cables #(.ID_W(4), .LEN_W(8)) u_input (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst), .mach_rst(mach_rst),
      .s_awaddr(h2fi_awaddr), .s_awlen(h2fi_awlen), .s_awid(h2fi_awid),
      .s_awvalid(h2fi_awvalid), .s_awready(h2fi_awready),
      .s_wdata(h2fi_wdata), .s_wstrb(h2fi_wstrb), .s_wlast(h2fi_wlast),
      .s_wvalid(h2fi_wvalid), .s_wready(h2fi_wready),
      .s_bresp(h2fi_bresp), .s_bid(h2fi_bid), .s_bvalid(h2fi_bvalid),
      .s_bready(h2fi_bready),
      .s_araddr(h2fi_araddr), .s_arlen(h2fi_arlen), .s_arid(h2fi_arid),
      .s_arvalid(h2fi_arvalid), .s_arready(h2fi_arready),
      .s_rdata(h2fi_rdata), .s_rresp(h2fi_rresp), .s_rid(h2fi_rid),
      .s_rlast(h2fi_rlast), .s_rvalid(h2fi_rvalid), .s_rready(h2fi_rready),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
      .mouse_lines(mouse_lines),
      .card_csr(csr_face)
  );

  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_h2f_rest (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(h2fd_awvalid), .s_awid(h2fd_awid), .s_awready(h2fd_awready),
      .s_wlast(h2fd_wlast), .s_wvalid(h2fd_wvalid), .s_wready(h2fd_wready),
      .s_bresp(h2fd_bresp), .s_bid(h2fd_bid), .s_bvalid(h2fd_bvalid),
      .s_bready(h2fd_bready),
      .s_arlen(h2fd_arlen), .s_arid(h2fd_arid), .s_arvalid(h2fd_arvalid),
      .s_arready(h2fd_arready),
      .s_rdata(h2fd_rdata), .s_rresp(h2fd_rresp), .s_rid(h2fd_rid),
      .s_rlast(h2fd_rlast), .s_rvalid(h2fd_rvalid), .s_rready(h2fd_rready)
  );

  // -------------------------------- the lightweight bridge, two faces
  logic [31:0] lwc_awaddr, lwc_araddr, lwc_wdata, lwc_rdata;
  logic [7:0]  lwc_awlen, lwc_arlen;
  logic [3:0]  lwc_wstrb, lwc_awid, lwc_arid, lwc_bid, lwc_rid;
  logic        lwc_awvalid, lwc_awready, lwc_wlast, lwc_wvalid, lwc_wready;
  logic        lwc_bvalid, lwc_bready, lwc_arvalid, lwc_arready;
  logic        lwc_rlast, lwc_rvalid, lwc_rready;
  logic [1:0]  lwc_bresp, lwc_rresp;
  logic [31:0] lwd_awaddr, lwd_araddr, lwd_wdata, lwd_rdata;
  logic [7:0]  lwd_awlen, lwd_arlen;
  logic [3:0]  lwd_wstrb, lwd_awid, lwd_arid, lwd_bid, lwd_rid;
  logic        lwd_awvalid, lwd_awready, lwd_wlast, lwd_wvalid, lwd_wready;
  logic        lwd_bvalid, lwd_bready, lwd_arvalid, lwd_arready;
  logic        lwd_rlast, lwd_rvalid, lwd_rready;
  logic [1:0]  lwd_bresp, lwd_rresp;
  logic [31:0] lwx_rdata;
  logic [7:0]  lwx_arlen;
  logic [3:0]  lwx_awid, lwx_arid, lwx_bid, lwx_rid;
  logic        lwx_awvalid, lwx_awready, lwx_wlast, lwx_wvalid, lwx_wready;
  logic        lwx_bvalid, lwx_bready, lwx_arvalid, lwx_arready;
  logic        lwx_rlast, lwx_rvalid, lwx_rready;
  logic [1:0]  lwx_bresp, lwx_rresp;

  cadr_gp1_split #(
      .CON_BASE(32'h0000_0000),
      .DBG_BASE(32'h0000_1000),
      .ID_W(4), .LEN_W(8)
  ) u_lw_split (
      .clk(clk), .rst(h2f_rst),
      .s_awaddr({3'b000, lw_awaddr}), .s_awlen(lw_awlen), .s_awid(lw_awid),
      .s_awvalid(lw_awvalid), .s_awready(lw_awready),
      .s_wdata(lw_wdata), .s_wstrb(lw_wstrb), .s_wlast(lw_wlast),
      .s_wvalid(lw_wvalid), .s_wready(lw_wready),
      .s_bresp(lw_bresp), .s_bid(lw_bid), .s_bvalid(lw_bvalid),
      .s_bready(lw_bready),
      .s_araddr({3'b000, lw_araddr}), .s_arlen(lw_arlen), .s_arid(lw_arid),
      .s_arvalid(lw_arvalid), .s_arready(lw_arready),
      .s_rdata(lw_rdata), .s_rresp(lw_rresp), .s_rid(lw_rid),
      .s_rlast(lw_rlast), .s_rvalid(lw_rvalid), .s_rready(lw_rready),
      .con_awaddr(lwc_awaddr), .con_awlen(lwc_awlen), .con_awid(lwc_awid),
      .con_awvalid(lwc_awvalid), .con_awready(lwc_awready),
      .con_wdata(lwc_wdata), .con_wstrb(lwc_wstrb), .con_wlast(lwc_wlast),
      .con_wvalid(lwc_wvalid), .con_wready(lwc_wready),
      .con_bresp(lwc_bresp), .con_bid(lwc_bid), .con_bvalid(lwc_bvalid),
      .con_bready(lwc_bready),
      .con_araddr(lwc_araddr), .con_arlen(lwc_arlen), .con_arid(lwc_arid),
      .con_arvalid(lwc_arvalid), .con_arready(lwc_arready),
      .con_rdata(lwc_rdata), .con_rresp(lwc_rresp), .con_rid(lwc_rid),
      .con_rlast(lwc_rlast), .con_rvalid(lwc_rvalid), .con_rready(lwc_rready),
      .dbg_awaddr(lwd_awaddr), .dbg_awlen(lwd_awlen), .dbg_awid(lwd_awid),
      .dbg_awvalid(lwd_awvalid), .dbg_awready(lwd_awready),
      .dbg_wdata(lwd_wdata), .dbg_wstrb(lwd_wstrb), .dbg_wlast(lwd_wlast),
      .dbg_wvalid(lwd_wvalid), .dbg_wready(lwd_wready),
      .dbg_bresp(lwd_bresp), .dbg_bid(lwd_bid), .dbg_bvalid(lwd_bvalid),
      .dbg_bready(lwd_bready),
      .dbg_araddr(lwd_araddr), .dbg_arlen(lwd_arlen), .dbg_arid(lwd_arid),
      .dbg_arvalid(lwd_arvalid), .dbg_arready(lwd_arready),
      .dbg_rdata(lwd_rdata), .dbg_rresp(lwd_rresp), .dbg_rid(lwd_rid),
      .dbg_rlast(lwd_rlast), .dbg_rvalid(lwd_rvalid), .dbg_rready(lwd_rready),
      .dflt_awid(lwx_awid), .dflt_awvalid(lwx_awvalid),
      .dflt_awready(lwx_awready),
      .dflt_wlast(lwx_wlast), .dflt_wvalid(lwx_wvalid),
      .dflt_wready(lwx_wready),
      .dflt_bresp(lwx_bresp), .dflt_bid(lwx_bid), .dflt_bvalid(lwx_bvalid),
      .dflt_bready(lwx_bready),
      .dflt_arlen(lwx_arlen), .dflt_arid(lwx_arid),
      .dflt_arvalid(lwx_arvalid), .dflt_arready(lwx_arready),
      .dflt_rdata(lwx_rdata), .dflt_rresp(lwx_rresp), .dflt_rid(lwx_rid),
      .dflt_rlast(lwx_rlast), .dflt_rvalid(lwx_rvalid),
      .dflt_rready(lwx_rready)
  );

  // **WHICH BUILD THIS FABRIC IS**, page 2's word 32.  **ALL ONES, WHICH IS
  // THE CONSOLE'S WORD FOR "THIS FABRIC CANNOT SAY".**  On a Zynq board
  // `cadr_usr_access.sv` reads the stamp back out of the part's own AXSS
  // register, and this part has no equivalent the fabric can read; the same
  // commit IS in this bitstream's USERCODE, which `boards/de25-nano/quartus/
  // usercode.tcl` writes and a JTAG cable reads, so the fact is not lost, it
  // is only unreadable from inside.  Saying so is the point: the console
  // distinguishes "this is build X" from "this fabric cannot say", and a
  // number invented here would be a lie a program could not see through.
  localparam logic [31:0] NO_BUILD_STAMP = 32'hFFFF_FFFF;

  // The console's wires for the display's two settings and its sleep; what a
  // board built without the display answers is at those ports below.
  logic        con_hdmi_sleep_set, con_hdmi_wake;
  logic [14:0] con_hdmi_sleep_secs;
  logic [1:0]  con_hdmi_out, con_hdmi_rotate;
  cadr_console #(
      .REG_BASE(32'h0000_0000), .ID_W(4), .LEN_W(8)
  ) u_console (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst),
      .s_awaddr(lwc_awaddr), .s_awlen(lwc_awlen), .s_awid(lwc_awid),
      .s_awvalid(lwc_awvalid), .s_awready(lwc_awready),
      .s_wdata(lwc_wdata), .s_wstrb(lwc_wstrb), .s_wlast(lwc_wlast),
      .s_wvalid(lwc_wvalid), .s_wready(lwc_wready),
      .s_bresp(lwc_bresp), .s_bid(lwc_bid), .s_bvalid(lwc_bvalid),
      .s_bready(lwc_bready),
      .s_araddr(lwc_araddr), .s_arlen(lwc_arlen), .s_arid(lwc_arid),
      .s_arvalid(lwc_arvalid), .s_arready(lwc_arready),
      .s_rdata(lwc_rdata), .s_rresp(lwc_rresp), .s_rid(lwc_rid),
      .s_rlast(lwc_rlast), .s_rvalid(lwc_rvalid), .s_rready(lwc_rready),
      .dbg_req(con_req), .dbg_gnt(con_gnt),
      .tv_lispm(con_tv_lispm), .color_tv(con_color_tv),
      .tv_map_a(con_tv_map_a), .tv_map_q(tv_map_q),
      .tv_color_map_q(tv_color_map_q),
      // **THE DISPLAY'S TWO SETTINGS AND ITS SLEEP**, word 34 and word 36,
      // as `docs/display-output.md` and `docs/console.md` give them.  On a
      // board built with the display these reach it and it answers; on a
      // board built without, the sleep is not fitted and word 36 reads
      // `UNMAPPED`, and what a write to word 34 asks for is held and read
      // back with nothing behind it --- which is what the Cora Z7-07S does,
      // and a console is for saying so.
      .hdmi_out(con_hdmi_out), .hdmi_rotate(con_hdmi_rotate),
      .steady_lamps(con_steady_lamps),
      .hdmi_sleep_set(con_hdmi_sleep_set),
      .hdmi_sleep_secs(con_hdmi_sleep_secs),
      .hdmi_wake(con_hdmi_wake), .hdmi_sleep_fitted(disp_sleep_fitted),
      .hdmi_sleep_q(disp_sleep_setting), .hdmi_asleep(disp_asleep),
      .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
      .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
      .clock_edge(clock_edge),
      .mach_vma(con_vma), .mach_q(con_q), .mach_md(con_md),
      .build(NO_BUILD_STAMP),
      .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
      .mach_rst(con_mach_rst),
      .mach_boot(con_mach_boot),
      .no_auto_boot_held(sw0_held),
      .no_auto_boot_now(sw0_level),
      // **THE DEBUG CABLE'S ROLE AND ITS CONNECTOR**, page 0's words 14 and
      // 15.  Two go out --- the role this board asks for and which way round
      // the ribbon was made --- and seven come back, because what this board
      // ASKED FOR and what it HAS are two different facts: a board that can
      // see a debugger already on the connector refuses, and a console that
      // reported the ask alone would say this board was the debugger when the
      // far one is.  Every one of these nine was a constant while this board
      // had no connector, which was true then and would be a lie now.
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

  // **THE DEBUG CABLE'S CARRIER**, MIT's twenty-one wires as sixteen words on
  // the lightweight bridge, one page above the console.  Its far end is
  // `rtl/machine/cadr_dbgin.sv` inside `cadr_machine`, and the debugger is
  // muir on this board's own cores, reaching it through `/dev/mem` with
  // `--debug-cable-connect 0x20001000`.  **IT TAKES THE BRIDGE'S RESET AND
  // NOT THE MACHINE'S**: modifier bit 1 resets the machine over this very
  // cable, and a carrier reset by it would forget the request that asked for
  // it.
  cadr_debug_window #(
      .REG_BASE(32'h0000_1000), .ID_W(4), .LEN_W(8)
  ) u_debug_window (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst),
      .s_awaddr(lwd_awaddr), .s_awlen(lwd_awlen), .s_awid(lwd_awid),
      .s_awvalid(lwd_awvalid), .s_awready(lwd_awready),
      .s_wdata(lwd_wdata), .s_wstrb(lwd_wstrb), .s_wlast(lwd_wlast),
      .s_wvalid(lwd_wvalid), .s_wready(lwd_wready),
      .s_bresp(lwd_bresp), .s_bid(lwd_bid), .s_bvalid(lwd_bvalid),
      .s_bready(lwd_bready),
      .s_araddr(lwd_araddr), .s_arlen(lwd_arlen), .s_arid(lwd_arid),
      .s_arvalid(lwd_arvalid), .s_arready(lwd_arready),
      .s_rdata(lwd_rdata), .s_rresp(lwd_rresp), .s_rid(lwd_rid),
      .s_rlast(lwd_rlast), .s_rvalid(lwd_rvalid), .s_rready(lwd_rready),
      .dbg_in_req(dbg_in_req), .dbg_in_wr(dbg_in_wr), .dbg_in_a(dbg_in_a),
      .dbd_out(dbd_to_machine),
      .dbg_in_ack(dbg_in_ack), .dbd_in(dbd_from_machine), .dbd_oe(dbd_oe)
  );

  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_lw_rest (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(lwx_awvalid), .s_awid(lwx_awid), .s_awready(lwx_awready),
      .s_wlast(lwx_wlast), .s_wvalid(lwx_wvalid), .s_wready(lwx_wready),
      .s_bresp(lwx_bresp), .s_bid(lwx_bid), .s_bvalid(lwx_bvalid),
      .s_bready(lwx_bready),
      .s_arlen(lwx_arlen), .s_arid(lwx_arid), .s_arvalid(lwx_arvalid),
      .s_arready(lwx_arready),
      .s_rdata(lwx_rdata), .s_rresp(lwx_rresp), .s_rid(lwx_rid),
      .s_rlast(lwx_rlast), .s_rvalid(lwx_rvalid), .s_rready(lwx_rready)
  );

  // =========================================== the display output
  //
  // **THE SAME DISPLAY THE ARTY Z7-20 HAS, WITH ONE STAGE OF IT OFF THE
  // FABRIC.**  `rtl/plumbing/cadr_display_out.sv` reads the CADR's two
  // screens out of the machine's own memory and puts them on a raster, and
  // it is the same module, the same video mode, the same run-time output
  // selection, rotation and sleep.  What parts the two boards is what
  // happens to that raster afterwards.  There the fabric encodes it as DVI
  // in `cadr_hdmi_tx.sv` and serializes four lanes in
  // `xilinx7/cadr_hdmi_phy.sv`; here an Analog Devices ADV7513 on the board
  // does both, and the fabric hands it twenty-four bits of color with a
  // clock, a data enable and two syncs.  So THE ENCODER AND THE SERIALIZERS
  // HAVE NO COUNTERPART ON THIS BOARD, which is what
  // `boards/de25-nano/README.md` already said they would not have, and
  // nothing of them is built here.
  //
  // **AND THE PART DOES NOTHING UNTIL ITS REGISTERS ARE WRITTEN**, which is
  // the one thing this board needs that the Arty does not:
  // `rtl/plumbing/cadr_adv7513.sv` writes them over the two-wire bus, out of
  // reset and again at every wake.  It is fabric and not software, so a
  // picture needs no program, no face and no boot, which is what
  // `docs/display-output.md` means by no software in the path.
  //
  // THE MEMORY SIDE.  The display is the third master on
  // `cadr_f2sdram_share.sv`, which is `S_AXI_HP3`'s role on the Zynq boards.
  // It reads and never writes, it is behind the machine in the arbiter, and
  // it can be made to wait a long time without anything going wrong because
  // it runs ahead of its own raster --- the argument is in that module's
  // header and in `docs/display-output.md`'s arbitration section.  What it
  // costs the port is under two per cent of it with both screens shown.
  //
  // THE PIXEL CLOCK IS ITS OWN PLL, AND THAT IS DELIBERATE.  The machine's
  // 100 MHz and the mode's pixel clock have no common divider of the board's
  // 50 MHz that serves both, exactly as the Arty's 125 MHz serves neither
  // the machine's clock nor the pixel clock from one manager.  So there are
  // two I/O PLLs, `u_pll` for the tick and `u_pixel_clock` for the mode, and
  // `boards/de25-nano/quartus/build.sh` generates both from the frequencies
  // it asks for.  **THE INSTANCE IS NOT CALLED `u_pll` ANYTHING**, because
  // `boards/de25-nano/quartus/sta_check.tcl` finds the machine's clock by
  // that name and refuses a build in which it finds two --- the same trap
  // `boards/arty-z7-20/cadr_arty.sv` records against `tick.tcl`, which
  // stopped a whole board flow the first time the display's clock manager
  // appeared beside the machine's.
  //
  // **THE VIDEO IS LAUNCHED ON THE RISING EDGE OF THAT CLOCK AND THE SAME
  // CLOCK IS FORWARDED TO THE PART**, with `0xBA` written as no clock delay.
  // The data sheet in the board's resource package gives the setup and hold
  // its video inputs need, 1.8 ns and 1.3 ns, and does NOT say which edge of
  // its clock it samples on; the programming guide that would is not on this
  // machine.  So the arrangement is not derived here either: it is the one
  // the board vendor's own demonstration uses on this board, whose video
  // generator registers every output on the rising edge of the PLL output it
  // forwards, with the same `0xBA` value.  Inventing a half-period shift
  // instead would have been this project's theory about an edge no document
  // here names.  `boards/de25-nano/quartus/cadr_hdmi.sdc` constrains the
  // skew that is left.
  //
  // **AND SLEEP STOPS THE CLOCK, BECAUSE THE FABRIC NO LONGER MAKES THE
  // LINK.**  On the Arty, sleep holds all four lanes at one word: a monitor
  // sees no signal and goes into its own power save, and the clock lane is
  // held with the data lanes because a monitor locked to a running clock
  // stays awake and shows black.  Here the lanes are the ADV7513's, so what
  // this fabric can stop is the clock it hands the part --- which stops the
  // link at one remove and is the same act.  Everything in front of the gate
  // keeps running, as it does there: the pixel clock inside the fabric, the
  // raster, the fetch and both buffers, so a monitor that wakes locks onto a
  // picture that never stopped.  The gate takes its enable while the
  // forwarded clock is low, so the part is never handed a short pulse, and
  // `mute` moves only at a frame boundary, so the link stops and starts in
  // the blanking.
  //
  // **WHAT IS SHOWN AND WHAT IS NOT.**  A monitor on the board's HDMI
  // connector shows the machine's own screen, and what is typed at a keyboard
  // at the board appears on it, which ties the pixels at the connector to the
  // memory this block reads.  The sleep has been seen from both sides: the
  // monitor goes into its own standby and a key at the board brings it back.
  // What no monitor has seen here is either rotation, the output selection or
  // the color board.  `build/display_out.pass` and `build/display_sleep.pass`
  // hold the raster, the fetch, the compositor, both rotations and the sleep;
  // `build/adv7513.pass` holds what leaves the two-wire pins;
  // `build/de25.pass` holds this wiring; and the fitter holds the rest.  The
  // pixel clock's pin is answered in practice rather than in theory:
  // `de25_nano_pins.tcl` gives it the 1.1 V standard its bank allows, the
  // data sheet asks at least 1.35 V of the part's video inputs, the board
  // vendor's own demonstration drives it the same way, and there is no
  // schematic here to explain how the two meet.  `docs/board.md` has the
  // sessions and `boards/de25-nano/README.md` records the pin.
`ifdef CADR_DE25_HDMI

  // **THE DISPLAY'S RESET IS THE MEMORY PORT'S OWN**, `!port_live`: the
  // port in reset.  The processor's reset raises it at once, as it resets
  // the bridge, so a display waiting on beats the bridge will never send is
  // restarted rather than left waiting for ever; and the fabric's reset
  // raises it only once `cadr_f2sdram_gate.sv` has drained the share, so the
  // display finishes the reads it has in flight first.  It was the fabric's
  // reset alone, which did neither.  Until software opens the port the
  // display is held in reset, and shows black.  Its `fabric_rst` is tied low
  // here: the port's reset already follows KEY1, once the gate's drain has
  // let the display finish the reads it has out.
  logic        pixel_locked;
  logic        pclk;                    // the mode's pixel clock, in fabric
  logic [3:0]  prst_sync;
  logic        prst;
  logic        disp_de, disp_hsync, disp_vsync, disp_mute, disp_sleep_due;
  logic [7:0]  disp_red, disp_green, disp_blue;
  logic        disp_underrun, disp_rd_error;
  // A register, for the reason `mach_rst` is one: it lands on every
  // register of the display's fetch.
  logic        disp_rst;
  always_ff @(posedge clk) disp_rst <= !port_live;

  // 50 MHz in, the mode's pixel clock out.  `build.sh` asks the IP for the
  // frequency this mode wants and refuses a generator that cannot make it,
  // and `sta_check.tcl` reads the period back out of the timing analyzer, so
  // no constraint can describe a different mode from the one being built.
  cadr_de25_pixel_pll u_pixel_clock (
      .refclk  (clock50_0),
      .rst     (ninit_done),
      .outclk_0(pclk),
      .locked  (pixel_locked)
  );

  // The raster's reset: the fabric's, and the pixel PLL's lock, synchronized
  // into the pixel domain because neither is of it.
  always_ff @(posedge pclk) prst_sync <= {prst_sync[2:0], rst || !pixel_locked};
  assign prst = prst_sync[3];

  cadr_display_out #(
      .BASE(cadr_ddr_map::DISPLAY_BASE),
      .COLOR_BASE(cadr_ddr_map::COLOR_DISPLAY_BASE),
      // QUUX shows MONO TV, 1280 by 1024 at 40 words a line, filling the
      // raster; the CADR its first board's 768 by 963 at 24.
      .PIC_W         (MACHINE == "quux" ? 1280 : 768),
      .PIC_H         (MACHINE == "quux" ? 1024 : 963),
      .WORDS_PER_LINE(MACHINE == "quux" ? 40 : 24)
  ) u_display (
      .clk(clk), .rst(disp_rst), .fabric_rst(1'b0),
      .m_araddr(dm_araddr), .m_arlen(dm_arlen), .m_arsize(dm_arsize),
      .m_arburst(dm_arburst), .m_arvalid(dm_arvalid), .m_arready(dm_arready),
      .m_rdata(dm_rdata), .m_rresp(dm_rresp), .m_rlast(dm_rlast),
      .m_rvalid(dm_rvalid), .m_rready(dm_rready),
      // What is shown and which way up, out of the console face.
      .out_sel(con_hdmi_out), .rotate(con_hdmi_rotate),
      // Whether it sleeps: a setting and a wake out of the console face, one
      // of them from `cadr-terminal` for a key or the mouse at the board,
      // and what it holds going back.
      .sleep_set(con_hdmi_sleep_set), .sleep_secs(con_hdmi_sleep_secs),
      .wake(con_hdmi_wake), .sleep_setting(disp_sleep_setting),
      .sleep_due(disp_sleep_due), .asleep(disp_asleep),
      .pclk(pclk), .prst(prst),
      // The color board's map, an entry a raster line.
      .map_a(disp_map_a), .map_q(disp_color_map_q),
      .mute(disp_mute),
      .de(disp_de), .hsync(disp_hsync), .vsync(disp_vsync),
      .red(disp_red), .green(disp_green), .blue(disp_blue),
      .underrun(disp_underrun), .rd_error(disp_rd_error)
  );
  assign disp_sleep_fitted = 1'b1;

  // **THE VIDEO BUS, REGISTERED ON THE PIXEL CLOCK AND NOWHERE ELSE.**  One
  // register a pin, so what the part sees leaves a flip-flop rather than a
  // cone of logic, and the skew the constraints have to hold is between
  // twenty-seven pins that all launch from the same edge.  The bus's own
  // order is the transmitter's: red in the top byte, then green, then blue,
  // which is what `0x16` written as 24-bit 4:4:4 means by it.
  logic [23:0] vid_d;
  logic        vid_de, vid_hs, vid_vs;
  always_ff @(posedge pclk) begin
    vid_d  <= {disp_red, disp_green, disp_blue};
    vid_de <= disp_de;
    vid_hs <= disp_hsync;
    vid_vs <= disp_vsync;
  end
  assign hdmi_d     = vid_d;
  assign hdmi_de    = vid_de;
  assign hdmi_hsync = vid_hs;
  assign hdmi_vsync = vid_vs;

  // **THE FORWARDED CLOCK, AND ITS GATE.**  The enable is taken on the
  // falling edge, which is while the forwarded clock is low, so the part is
  // handed whole periods and never a fragment of one; a gate taken on the
  // rising edge would cut a period in half the first time it moved.
  // `disp_mute` is the display's own, and it moves only at a frame boundary.
  logic pclk_on;
  always_ff @(negedge pclk) pclk_on <= !disp_mute;
  assign hdmi_pclk = pclk && pclk_on;

  // **THE TRANSMITTER'S REGISTERS.**  Written once out of the fabric's
  // reset, and again whenever the display wakes: `asleep` is the mute
  // brought back into this clock by the display itself, so its fall is a
  // wake, in this domain, with no second synchronizer to disagree with the
  // first.
  logic asleep_q, hdmi_wake_edge;
  always_ff @(posedge clk) asleep_q <= rst ? 1'b0 : disp_asleep;
  assign hdmi_wake_edge = asleep_q && !disp_asleep;

  logic hdmi_scl_oe, hdmi_sda_oe, hdmi_configured, hdmi_failed;
  logic [5:0] hdmi_writes;
  cadr_adv7513 u_adv7513 (
      .clk(clk), .rst(rst),
      .restart(hdmi_wake_edge),
      .configured(hdmi_configured), .failed(hdmi_failed), .writes(hdmi_writes),
      .scl_i(hdmi_scl), .scl_oe(hdmi_scl_oe),
      .sda_i(hdmi_sda), .sda_oe(hdmi_sda_oe)
  );
  // Open drain: pulled low or released, never driven high, because the board
  // pulls both lines up and the part answers on SDA and may hold SCL.
  assign hdmi_scl = hdmi_scl_oe ? 1'b0 : 1'bz;
  assign hdmi_sda = hdmi_sda_oe ? 1'b0 : 1'bz;

  // The display's four reports have no register to be read in: this board's
  // console carries the sleep and what the output shows and nothing else of
  // it, as the Arty's does.  They go into a fold for the reason every output
  // of the machine does --- a signal with no consumer is one synthesis may
  // delete, and then the register behind it is gone and a check on the board
  // would be measuring another design.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_disp;
  assign unused_disp = ^{disp_underrun, disp_rd_error, disp_sleep_due,
                         hdmi_configured, hdmi_failed, hdmi_writes};
  /* verilator lint_on UNUSEDSIGNAL */

`else

  // NO DISPLAY.  Its port on the share asks for nothing and would take an
  // answer; the machine's second map port stands at entry zero and nothing
  // reads what comes back; the console still answers word 34 with what it
  // would show, which is what a console is for, and word 36 reads `UNMAPPED`,
  // which is what a board with no timer to report has to say.  The Cora
  // Z7-07S is the same board on the other vendor.
  assign dm_araddr   = 32'd0;
  assign dm_arlen    = 4'd0;
  assign dm_arsize   = 2'b11;
  assign dm_arburst  = 2'b01;
  assign dm_arvalid  = 1'b0;
  assign dm_rready   = 1'b1;
  assign disp_map_a  = 4'd0;
  assign disp_sleep_fitted  = 1'b0;
  assign disp_sleep_setting = 15'd0;
  assign disp_asleep        = 1'b0;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_nodisp;
  assign unused_nodisp = ^{dm_arready, dm_rdata, dm_rresp, dm_rlast, dm_rvalid,
                           disp_color_map_q,
                           con_hdmi_out, con_hdmi_rotate, con_hdmi_sleep_set,
                           con_hdmi_sleep_secs, con_hdmi_wake};
  /* verilator lint_on UNUSEDSIGNAL */

`endif

  // **THE THREE FACES' INTERRUPTS HAVE NOWHERE TO GO ON THIS BOARD YET.**
  // The Zynq boards carry them to `IRQ_F2P`; the Agilex 5's fabric-to-
  // processor interrupts are not brought out of the generated system, so the
  // programs poll, which is what they do by default and what their `--irq`
  // flag is the alternative to.
  //
  // AND WHAT NEITHER SPLITTER READS OF A TRANSACTION, which is every
  // attribute but the address, the length and the ID: the size, the burst
  // type, the lock, the cache hints and the protection bits.  A register face
  // answering one word at every address in its page answers the same word
  // whatever they say, and a byte within a word is the write strobes' business
  // and not AxSIZE's --- `cadr_gp0_default.sv` states that for its own
  // window and `cadr_gp_regs.sv` for a face's.  Read here so that lint holds
  // every one of them to being deliberately unused rather than accidentally
  // unconnected, which is the same rule the machine's fold keeps.
  /* verilator lint_off UNUSEDSIGNAL */
  logic pack_irq, chaos_irq, ser_irq;
  logic hps_unused;
  assign hps_unused = ^{f2s_buser, f2s_ruser, gp_out[31:2],
                        h2f_awsize, h2f_arsize, h2f_awprot, h2f_arprot,
                        h2f_awburst, h2f_arburst, h2f_awlock, h2f_arlock,
                        h2f_awcache, h2f_arcache,
                        lw_awsize, lw_arsize, lw_awprot, lw_arprot,
                        lw_awburst, lw_arburst, lw_awlock, lw_arlock,
                        lw_awcache, lw_arcache,
                        pack_irq, chaos_irq, ser_irq};
  /* verilator lint_on UNUSEDSIGNAL */
`else
  // NO PROCESSOR: no memory, and every cable out of the machine has nothing
  // on its far end.  These are the tie-offs the memory board's faces replace,
  // and they are what a CADR with an empty backplane connector is.
  //
  // NO MEMORY: the machine's cycles to it end on the NXM timer, and the
  // machine is not held, because there is no port for it to wait for.
  assign mem_done  = 1'b0;
  assign mem_rdata = 32'd0;
  assign port_live = 1'b0;
  assign mach_hold = 1'b0;
  assign port_read_ack  = 1'b0;
  assign port_write_ack = 1'b0;

  // NO DRIVE AND NO PACK.  With `drive_present` at zero the status register
  // answers `0x2321` for every one of the boot PROM's polls, and tied off the
  // whole drive constant-folds, so this fit counts the register face and the
  // decode and not the spindle.
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

  // THE I/O BOARD'S CABLES, WITH NOTHING ON THEIR FAR ENDS.  No strobe means
  // no scan code.  The mouse's seven lines are ALL ONES and not zero: each
  // switch pulls to ground when pressed and each quadrature line is high at
  // rest, so all ones is a mouse nobody is touching.  The serial line is
  // unplugged, so with `ser_plugged` down the 2651's sheet holds both halves
  // stopped; and the Chaosnet has its address switches at zero and no frame
  // ever arriving.
  assign kbd_strobe     = 1'b0;
  assign kbd_code       = 24'd0;
  assign mouse_lines    = 7'h7F;
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

  // NO CONSOLE, so nothing asks for the bus, nothing resets or boots the
  // machine, the backplane is one SIMPLE TV and no color board, the lamps
  // blink, and the readout's address stands at the reserved selector where
  // the machine answers `RO_NO_MEMORY` for ever.
  assign con_req          = 1'b0;
  assign con_msyn         = 1'b0;
  assign con_write        = 1'b0;
  assign con_addr         = 18'd0;
  assign con_wdata        = 16'd0;
  assign con_ro_addr      = 18'h3FFFF;
  assign con_mach_rst     = 1'b0;
  assign con_mach_boot    = 1'b0;
  assign con_tv_lispm     = 1'b0;
  assign con_color_tv     = 1'b0;
  assign con_tv_map_a     = 4'd0;
  assign con_steady_lamps = 1'b0;

  // NO DISPLAY, because there is no memory for it to read.  The machine's
  // second map port stands at entry zero and the console's word 36 reads
  // `UNMAPPED`.
  assign disp_map_a         = 4'd0;
  assign disp_sleep_fitted  = 1'b0;
  assign disp_sleep_setting = 15'd0;
  assign disp_asleep        = 1'b0;

  // **NO REGISTER WINDOW**, there being no bridge to put its carrier on, so
  // the join's near arm is empty.  `-DEBUG IN REQ` held UP, which is
  // `dbg_in_req` low, is what the SIP at DBGIN 0A22 makes of an unplugged
  // connector, and the join then carries the CONNECTOR's cable unchanged.
  assign dbg_in_req     = 1'b0;
  assign dbg_in_wr      = 1'b0;
  assign dbg_in_a       = 2'd0;
  assign dbd_to_machine = 16'd0;

  // And nobody to ask for the debugger's role, there being no console.
  // **THE CONNECTOR IS STILL THERE AND THIS BOARD IS STILL A DEBUGGEE**: it
  // answers a debugger that plugs into JP1, which is the power-on state of any
  // CADR and needs nothing set.  What is missing is only the way to ask for
  // the other role, and the way to be told what the connector found.
  assign dbg_connect = 1'b0;
  // And the wiring stands at `auto`, which is what the fabric comes up with:
  // a board with no console still finds a crossed cable, it just has nobody
  // to tell.
  assign dbg_wiring  = 2'd0;

  // And what the machine gives those cables, read here so that lint holds a
  // board with no far ends to reading every one of them.
  /* verilator lint_off UNUSEDSIGNAL */
  logic nopack_unused;
  assign nopack_unused = ^{store_rdata, store_miss, ch_active,
                           req_valid, req_tag, req_post,
                           ch_waiting, ch_slot, ch_wrote, ch_hit,
                           sw0_held, csr_face, disp_color_map_q,
                           disp_sleep_fitted, disp_sleep_setting,
                           disp_asleep};
  /* verilator lint_on UNUSEDSIGNAL */
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

  // LEDR1 and LEDR2, blinking or steady.  They are the modules the Zynq
  // boards use and `build/blink_lamps.pass` holds; the console's word 35 is
  // what asks for steady, and with no console they blink.
  logic clock_lamp, cycle_lamp;
  cadr_lamp_clock u_lamp_clock (
      .steady(con_steady_lamps), .locked(pll_locked), .blink(tick[25]),
      .lit(clock_lamp)
  );
  cadr_lamp_microcycle u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(con_steady_lamps),
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
