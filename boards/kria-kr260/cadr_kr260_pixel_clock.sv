// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Kria KR260's pixel clock: 1920x1080 at 60 Hz out of the carrier's
// 25 MHz.
//
// **ITS OWN MMCM, BESIDE THE MACHINE'S, AND IN A FILE OF ITS OWN.**  The
// machine's tick comes from the MMCME4 in `cadr_kr260.sv`, which
// `boards/arty-z7-20/vivado/tick.tcl` reads by counting that file's MMCM
// parameters; a second MMCM written there would make the tick ambiguous and
// stop the flow, which is the trap `boards/arty-z7-20/cadr_arty.sv` records
// for its display's.  So this one is here.
//
// **THE ARITHMETIC.**  CEA-861's 1920x1080 at 60 Hz is 2200 x 1125 at
// 148.5 MHz.  25 x 47.5 = 1187.5 MHz at the VCO, inside the MMCME4's 800 to
// 1600, and 1187.5 / 8 = 148.4375 MHz, 0.04 per cent low: 59.975 frames a
// second, which the DisplayPort controller carries with its own M and N in
// asynchronous clock mode and the monitor takes (measured on the board in
// the K9 spike, 3599 frames in 60 s).  No multiple of an eighth of 25 MHz
// divides to 148.5 exactly.
//
// **NOT THE PROCESSING SYSTEM'S VIDEO REFERENCE CLOCK.**  That one is at the
// mode's rate only when Linux's display driver has reprogrammed the video
// PLL, and this board runs without one; at the boot firmware's settings it
// divides to 150 or 300 MHz (measured in the same spike).  A pixel clock that
// depended on software would not be the display the other boards build.
//
// The raster's reset: the fabric's, and this MMCM's lock, synchronized into
// the pixel domain because neither is of it.

`default_nettype none

module cadr_kr260_pixel_clock (
    input  var logic clk25,    // the carrier's 25 MHz, pin C3
    input  var logic rst,      // the fabric's reset, in the machine's domain
    output var logic pclk,
    output var logic prst
);

  logic pixel_raw, fb, locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME4_BASE #(
      .CLKIN1_PERIOD   (40.000),
      .DIVCLK_DIVIDE   (1),
      .CLKFBOUT_MULT_F (47.500),
      .CLKOUT0_DIVIDE_F(8.000)
  ) u_pixel_mmcm (
      .CLKIN1  (clk25),
      .CLKFBIN (fb),
      .CLKFBOUT(fb),
      .CLKOUT0 (pixel_raw),
      .LOCKED  (locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(),
      .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  BUFG u_bufg_pixel (.I(pixel_raw), .O(pclk));

  logic [3:0] prst_sync;
  always_ff @(posedge pclk) prst_sync <= {prst_sync[2:0], rst || !locked};
  assign prst = prst_sync[3];

endmodule

`default_nettype wire
