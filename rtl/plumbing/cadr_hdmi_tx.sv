// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A DVI transmitter: three TMDS channels and the clock channel, as ten-bit
// words for a serializer.
//
// NO muir REFERENCE EXISTS, as none exists for `cadr_tmds_encode.sv` below
// it or for `cadr_axi_master.sv`.  This is held to DVI 1.0 and to nothing
// else.
//
// **DVI AND NOT HDMI, DELIBERATELY.**  What goes out of this module is a DVI
// 1.0 signal: video periods and control periods and nothing between them ---
// no data islands, no preambles, no guard bands, no audio and no
// InfoFrames.  Every HDMI monitor accepts it, because HDMI's own
// specification requires a sink to accept DVI, and it is what every monitor
// with a DVI input has always taken.  What it costs is that the sink chooses
// its own colorimetry and cannot be told the picture is full-range; for a
// picture that is black and white and nothing else, that costs nothing.
// Building the data islands would mean a packet scheduler, BCH ECC and the
// audio clock regeneration, for a machine that has no audio.
//
// THE CHANNEL ASSIGNMENT IS THE SPECIFICATION'S AND IS NOT A CHOICE.  DVI
// 1.0 section 3.3: channel 0 carries blue and, in its control period, HSYNC
// as C0 and VSYNC as C1; channels 1 and 2 carry green and red with both
// control bits zero.  A transmitter that put the syncs on another channel
// would drive a monitor that never locks, and the fault would look like a
// cable.
//
// THE CLOCK CHANNEL IS A CONSTANT WORD AND NOT AN ENCODER.  It carries a
// square wave at the pixel rate: ten bits sent least significant bit first,
// and since the word is `0000011111` its low five bits go out first, so the
// line is high for five bit times and then low for five --- one period a
// pixel.  Writing the word in binary and the order it leaves in is the only
// way this is readable; as `0x01F` it says nothing.  It is not 8b/10b
// encoded --- there is nothing to encode --- and it is written here rather
// than in the serializer so that everything the monitor receives comes out
// of one module and one clock domain.
//
// WHAT THE CHECK HOLDS THIS TO.  `tb/cadr_hdmi_tx_tb.cpp` carries a second
// encoder written from the specification's own pseudocode, and compares all
// three channels against it: over every one of the 256 byte values in every
// disparity state the encoder can reach, over all four control tokens, and
// over a long pseudorandom stream of pixels and blanking.  What it cannot
// hold is the serializer, which is Xilinx primitives --- see
// `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv`.

`default_nettype none

module cadr_hdmi_tx (
    input  var logic       pclk,
    input  var logic       prst,

    // The pixel, and the raster's own signals.  `de` low is a control
    // period and the color is ignored there.
    input  var logic [7:0] red,
    input  var logic [7:0] green,
    input  var logic [7:0] blue,
    input  var logic       de,
    input  var logic       hsync,
    input  var logic       vsync,

    // The four channels, bit 0 onto the wire first.
    output var logic [9:0] tmds0,     // blue, and the two syncs
    output var logic [9:0] tmds1,     // green
    output var logic [9:0] tmds2,     // red
    output var logic [9:0] tmds_clk
);

  // Channel 0: blue, with HSYNC as C0 and VSYNC as C1.
  cadr_tmds_encode u_ch0 (
      .clk(pclk), .rst(prst),
      .d(blue), .c({vsync, hsync}), .de(de), .q(tmds0)
  );

  // Channels 1 and 2 have no control bits of their own; DVI 1.0 says they
  // send the C1C0 = 00 token throughout the control period.
  cadr_tmds_encode u_ch1 (
      .clk(pclk), .rst(prst),
      .d(green), .c(2'b00), .de(de), .q(tmds1)
  );

  cadr_tmds_encode u_ch2 (
      .clk(pclk), .rst(prst),
      .d(red), .c(2'b00), .de(de), .q(tmds2)
  );

  // Bit 0 leaves first, so the low five bits are the first half of the
  // period: five bit times high, then five low, one period a pixel.  A
  // constant and not a register, and the reason is worth one
  // line: the word is the same every pixel, so a register would hold a
  // constant, and delaying a waveform whose period is exactly one pixel
  // clock by exactly one pixel clock leaves it where it was.  It therefore
  // needs no alignment with the three encoded channels and keeps running
  // through reset, which is what a monitor wants to lock to.
  assign tmds_clk = 10'b0000011111;

endmodule

`default_nettype wire
