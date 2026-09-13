// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The serial half of the display output: the pixel clock, four 10:1
// serialisers and four differential output buffers.
//
// **EVERYTHING XILINX-SPECIFIC IN THE DISPLAY OUTPUT IS IN THIS FILE, AND
// NOTHING ELSE IS.**  `rtl/plumbing/cadr_display_out.sv` and
// `rtl/plumbing/cadr_hdmi_tx.sv` are plain SystemVerilog and are checked by
// simulation; this is four primitives and a clock, is held by lint and by
// the fitter, and is checked by nothing.  Saying so is the point: an
// `OSERDESE2` cannot be simulated here, a stub of one would model nothing,
// and a check written against a stub would confirm rather than compare ---
// which this repository has met before and refuses.  What the fitter says
// about it is in `docs/display-output.md`.
//
// THE SECOND MMCM IS HERE AND NOT IN THE TOP LEVEL, AND THAT IS A RULE
// RATHER THAN A PREFERENCE.  `boards/arty-z7-20/vivado/tick.tcl` reads the
// machine's tick out of `cadr_arty.sv` by finding exactly one
// `MMCME2_BASE`'s four parameters there, and stops the whole flow if it
// finds two --- "the honest answer to an ambiguous question is to stop".
// That is right: the machine's tick is the machine's, and the pixel clock is
// not a tick and must never be mistaken for one.  So the pixel clock is
// generated in the block that uses it, the top level keeps its one MMCM, and
// `tick.tcl` goes on answering the question it was asked.  The probe's
// `BSCANE2` sits in the top level for the opposite reason --- so that
// `cadr_probe` can be simulated --- and the difference is that nothing below
// this module needs simulating that is not already in its own file.
//
// THE CLOCKS.  One `MMCME2_BASE` off the board's 125 MHz makes two outputs
// from one voltage-controlled oscillator: the serial clock at five times the
// pixel rate, and the pixel clock itself.  Ten bits leave a serialiser for
// every pixel, and a serialiser clocked on both edges moves two bits a
// period, so five times the pixel rate is exactly right and the two are
// phase-aligned by construction, being divisions of one oscillator.
//
// **THE SERIAL CLOCK RIDES A `BUFIO` AND NOT A `BUFG`, AND THAT IS A
// MEASURED LIMIT OF THE PART RATHER THAN A PREFERENCE.**  Asked for the
// minimum period each buffer's input will accept on this speed grade,
// Vivado's own speed file answers `BUFG` 2.155 ns and `BUFIO` 1.666 ns ---
// 464 MHz against 600 MHz.  The serial clock for the mode
// `docs/display-output.md` chose is 540 MHz, so a global buffer cannot
// carry it and a regional one can.  Nothing about that is visible in a
// schematic; it shows up as a minimum-period violation on a net a reader
// would assume was fine.
//
// **AND A `BUFIO` REACHES ONLY ITS OWN CLOCK REGION, WHICH IS WHY THIS
// WORKS AT ALL.**  All eight of the connector's pins are in bank 35 and,
// measured, all eight are in clock region X1Y2, which has four `BUFIO`
// sites.  Had Digilent spread the four pairs across two regions the
// serialisers could not have shared one regional clock and this would be a
// different design.  A board that moves those pins has to check this again.
//
// The pixel clock stays on a `BUFG`, because everything upstream --- the
// raster, the line buffer's read side, the encoders --- is ordinary fabric
// and must be reachable from anywhere on the die.  So the two clocks a
// serialiser sees arrive by different networks, which is the one thing in
// this file the fitter has to be asked about rather than assumed: the
// answer is in `docs/display-output.md` with the report it came from.
//
// The parameters are defaults rather than constants because the video mode
// is a decision recorded in `docs/display-output.md` and a second board may
// make it differently; `cadr_display_out.sv` carries the raster figures for
// the same mode and the two must be set together.
//
// **THEY ARE DELIBERATELY NOT SPELT AS `MMCME2_BASE` SPELLS THEM**, which
// was the first draft and was wrong.  `boards/arty-z7-20/vivado/tick.tcl`
// reads the machine's tick by counting occurrences of `DIVCLK_DIVIDE` and
// `CLKFBOUT_MULT_F` in `boards/arty-z7-20/cadr_arty.sv`, and stops the flow
// if it finds either twice.  An override of a parameter of THIS module named
// the same way puts that name in that file --- the MMCM is here, but the
// text is there --- and the whole board flow dies saying the tick is
// ambiguous.  It did, at the first bitstream.  So the VCO's two numbers are
// named for what they do to the VCO and the collision cannot recur.
//
// THE SERIALISER.  An `OSERDESE2` does at most 8:1 alone, so ten bits needs
// a master and a slave with the slave's `SHIFTOUT` into the master's
// `SHIFTIN` --- the cascade UG471 describes, and the reason the slave takes
// the top two bits on `D3` and `D4` rather than on `D1` and `D2`.  Getting
// that pair of pins wrong is the classic way to build a transmitter that
// sends nine of its ten bits and locks on nothing.
//
// **THE RESET IS RELEASED SYNCHRONOUSLY TO THE PIXEL CLOCK, AND BOTH
// SERIALISERS OF A PAIR SEE THE SAME RELEASE.**  A master and a slave that
// come out of reset on different cycles are ten bits that never align again
// until the next reset, which on a display is a picture that is stable,
// wrong, and looks like a wiring error.
//
// **THE OUTPUT BUFFERS ARE NOT HERE, AND THAT IS FOR THE SAME REASON THE
// `BSCANE2` IS IN THE TOP LEVEL.**  This module exists only when the display
// is built, and the connector's eight pins exist on every board.  A pin
// with no driver cannot be placed and a pin constrained `TMDS_33` cannot be
// driven single-ended, so the four `OBUFDS` are in
// `boards/arty-z7-20/cadr_arty.sv`, where they are instantiated whatever
// `HDMI` says and fed either from this module's four serial outputs or from
// zero.  A board built without the display therefore holds its connector at
// a direct-current level, which a monitor reads as no signal.
//
// The pins themselves and the `TMDS_33` standard are in
// `boards/arty-z7-20/cadr_arty.xdc` with the rest of the board's pins, taken
// from Digilent's published master file with its provenance; this block's own
// timing constraints are in `rtl/plumbing/xilinx7/cadr_hdmi.xdc`, which is
// read only when the display is built.  `TMDS_33` on a high-range bank is Xilinx's
// emulation of TMDS out of a 3.3 V driver and a resistor network on the
// board, which is how every Zynq board without a dedicated transmitter
// drives HDMI.

`default_nettype none

module cadr_hdmi_phy #(
    // The board crystal, and the three dividers that turn it into the two
    // clocks.  See `docs/display-output.md` for how the mode chose them.
    parameter real       CLKIN_PERIOD_NS  = 8.000,   // 125 MHz
    parameter int        VCO_DIVIDE       = 1,
    parameter real       VCO_MULT_F       = 8.625,   // VCO 1078.125 MHz
    parameter real       SERIAL_DIVIDE_F  = 2.000,   // 539.0625 MHz
    parameter int        PIXEL_DIVIDE     = 10       // 107.8125 MHz
) (
    input  var logic       sysclk,     // the board's own 125 MHz, off the pin

    // The pixel clock and its reset, for everything upstream of here.
    output var logic       pclk,
    output var logic       prst,

    // The four ten-bit words, in the `pclk` domain, bit 0 onto the wire
    // first.
    input  var logic [9:0] tmds0,
    input  var logic [9:0] tmds1,
    input  var logic [9:0] tmds2,
    input  var logic [9:0] tmds_clk,

    // The four serial streams: 0, 1 and 2 the data channels, 3 the clock
    // channel.  The top level makes them differential.
    output var logic [3:0] ser
);

  // ------------------------------------------------------------ the clocks

  logic serial_raw, pixel_raw, fb, locked;

  MMCME2_BASE #(
      .CLKIN1_PERIOD   (CLKIN_PERIOD_NS),
      .DIVCLK_DIVIDE   (VCO_DIVIDE),
      .CLKFBOUT_MULT_F (VCO_MULT_F),
      .CLKOUT0_DIVIDE_F(SERIAL_DIVIDE_F),
      .CLKOUT1_DIVIDE  (PIXEL_DIVIDE)
  ) u_mmcm (
      .CLKIN1  (sysclk),
      .CLKFBIN (fb),
      .CLKFBOUT(fb),
      .CLKOUT0 (serial_raw),
      .CLKOUT1 (pixel_raw),
      .LOCKED  (locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      /* verilator lint_off PINCONNECTEMPTY */
      .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
      /* verilator lint_on PINCONNECTEMPTY */
  );

  logic serial_clk;
  BUFIO u_bufio_serial (.I(serial_raw), .O(serial_clk));
  BUFG  u_bufg_pixel   (.I(pixel_raw),  .O(pclk));

  // `LOCKED` is asynchronous to everything, so it is synchronised into the
  // pixel domain and only then released.  Three stages rather than two
  // because this reset reaches four serialiser pairs and the cost is three
  // flip-flops.
  logic [2:0] lock_sync;
  always_ff @(posedge pclk) begin
    lock_sync <= {lock_sync[1:0], locked};
  end
  assign prst = !lock_sync[2];

  // ------------------------------------------------------- the serialisers

  logic [9:0] word [4];
  assign word[0] = tmds0;
  assign word[1] = tmds1;
  assign word[2] = tmds2;
  assign word[3] = tmds_clk;

  for (genvar ch = 0; ch < 4; ch++) begin : g_ser
    logic shift1, shift2;

    // The master takes bits 0 to 7 and hands the pair over to the slave.
    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("SDR"),
        .DATA_WIDTH    (10),
        .SERDES_MODE   ("MASTER"),
        .TRISTATE_WIDTH(1)
    ) u_master (
        .OQ      (ser[ch]),
        .CLK     (serial_clk),
        .CLKDIV  (pclk),
        .D1      (word[ch][0]),
        .D2      (word[ch][1]),
        .D3      (word[ch][2]),
        .D4      (word[ch][3]),
        .D5      (word[ch][4]),
        .D6      (word[ch][5]),
        .D7      (word[ch][6]),
        .D8      (word[ch][7]),
        .OCE     (1'b1),
        .RST     (prst),
        .SHIFTIN1(shift1),
        .SHIFTIN2(shift2),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TCE(1'b0), .TBYTEIN(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .OFB(), .TFB(), .TQ(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // **BITS 8 AND 9 GO ON `D3` AND `D4` AND NOT ON `D1` AND `D2`.** The
    // cascade shifts the slave's pair in two positions up, so a slave fed
    // at the bottom sends two bits of nothing and the word arrives two
    // places short. UG471, "Serializer Cascade".
    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("SDR"),
        .DATA_WIDTH    (10),
        .SERDES_MODE   ("SLAVE"),
        .TRISTATE_WIDTH(1)
    ) u_slave (
        .SHIFTOUT1(shift1),
        .SHIFTOUT2(shift2),
        .CLK     (serial_clk),
        .CLKDIV  (pclk),
        .D1(1'b0), .D2(1'b0),
        .D3      (word[ch][8]),
        .D4      (word[ch][9]),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
        .OCE     (1'b1),
        .RST     (prst),
        .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TCE(1'b0), .TBYTEIN(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .OQ(), .OFB(), .TFB(), .TQ(), .TBYTEOUT()
        /* verilator lint_on PINCONNECTEMPTY */
    );
  end

endmodule

`default_nettype wire
