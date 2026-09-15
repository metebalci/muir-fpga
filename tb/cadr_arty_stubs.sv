// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Xilinx primitives the board instantiates, as empty shells, so that the
// top level can be elaborated and linted.  `boards/arty-z7-20/cadr_arty.sv` has the
// MMCM, the global buffer and the probe's scan primitive;
// `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` has a second MMCM, a regional clock
// buffer, the two serializers of each channel and the four differential
// output buffers.
//
// **THIS FILE MUST NEVER MOVE TO `rtl/`.**  `boards/arty-z7-20/vivado/fit.tcl` and
// `boards/arty-z7-20/vivado/bitstream.tcl` both read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`, so a stub `MMCME2_BASE`
// there would be handed to synthesis alongside --- and in place of --- the real
// primitive, and the board would get a wire where its clock generator belongs.
// That builds, programs, and runs the machine at 125 MHz with 8 ns taps: a
// different machine that still lights LEDs, which is the failure this project
// keeps meeting.  Nothing globs `tb/`, which is the whole reason this is here.
// `docs/pending-rules.md` said the same.
//
// **AND NOTHING HERE MODELS ANYTHING.**  `boards/arty-z7-20/cadr_arty.sv` cannot be
// simulated and this does not make it simulable: the MMCM below multiplies
// nothing, so `CLKOUT0` is the input clock and a model built on it would run
// the machine at 125 MHz with 8 ns taps --- the very design error the
// paragraph above is about, moved from the bitstream into the simulation.  The
// only thing this file is for is `--lint-only`, and `build/arty.pass` is the
// only rule that reads it.  The port lists are Xilinx's, restricted to the
// pins `cadr_arty.sv` names; the parameters are the four it overrides, so an
// override of a fifth is an elaboration error here rather than a silent
// difference from the real primitive's default.

`default_nettype none

// One file, several primitives, and none is named after it. Xilinx chose the
// module names and this file is where they all belong.
/* verilator lint_off DECLFILENAME */

module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD   = 0.000,
    parameter int  DIVCLK_DIVIDE   = 1,
    parameter real CLKFBOUT_MULT_F = 5.000,
    parameter real CLKOUT0_DIVIDE_F = 1.000,
    // The fifth, and it arrived with the display output: the machine's MMCM
    // uses one output and the pixel clock's uses two, the serial clock on
    // CLKOUT0 and the pixel clock on CLKOUT1.  Listed here for the reason
    // the header gives --- an override of a parameter this stub does not
    // name must be an elaboration error and not a silent default.
    parameter int  CLKOUT1_DIVIDE  = 1,
    // The sixth, and it arrived with the Arty A7-100's soft processing
    // system: that board's one manager makes the machine's tick on CLKOUT0,
    // the memory controller's delay reference on CLKOUT1 and the soft
    // system's own clock on CLKOUT2, which is slower than the machine's
    // because a RISC-V core's load-store address does not settle in a 10 ns
    // tick.  Listed for the same reason as the fifth.
    parameter int  CLKOUT2_DIVIDE  = 1
) (
    output var logic CLKOUT0,
    output var logic CLKOUT0B,
    output var logic CLKOUT1,
    output var logic CLKOUT1B,
    output var logic CLKOUT2,
    output var logic CLKOUT2B,
    output var logic CLKOUT3,
    output var logic CLKOUT3B,
    output var logic CLKOUT4,
    output var logic CLKOUT5,
    output var logic CLKOUT6,
    output var logic CLKFBOUT,
    output var logic CLKFBOUTB,
    output var logic LOCKED,
    input  var logic CLKIN1,
    input  var logic CLKFBIN,
    input  var logic PWRDWN,
    input  var logic RST
);

  // Not a multiplier. See the header: passing the input through is what makes
  // this lint-only, and `CLKFBOUT` comes off `CLKIN1` rather than `CLKFBIN`
  // because the top level ties those two together and the feedback would be a
  // combinational loop.
  assign CLKOUT0   = CLKIN1;
  assign CLKFBOUT  = CLKIN1;
  assign LOCKED    = !RST && !PWRDWN;

  assign CLKOUT0B  = 1'b0;
  assign CLKOUT1   = 1'b0;
  assign CLKOUT1B  = 1'b0;
  assign CLKOUT2   = 1'b0;
  assign CLKOUT2B  = 1'b0;
  assign CLKOUT3   = 1'b0;
  assign CLKOUT3B  = 1'b0;
  assign CLKOUT4   = 1'b0;
  assign CLKOUT5   = 1'b0;
  assign CLKOUT6   = 1'b0;
  assign CLKFBOUTB = 1'b0;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, CLKFBIN, CLKIN1_PERIOD != 0.0, DIVCLK_DIVIDE[0],
                    CLKFBOUT_MULT_F != 0.0, CLKOUT0_DIVIDE_F != 0.0,
                    CLKOUT1_DIVIDE[0], CLKOUT2_DIVIDE[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

module BUFG (
    output var logic O,
    input  var logic I
);
  assign O = I;
endmodule

// The third primitive, and the one `boards/arty-z7-20/cadr_arty.sv` only instantiates when
// `PROBE_DEPTH` is set. Same rule as the two above: this models nothing.
// The JTAG side is dead here --- SEL low, DRCK low --- which is exactly what
// a board with nobody scanning it looks like, and it is all lint needs. What
// the readout logic actually does is checked by `tb/cadr_probe_tb.cpp`,
// which drives `cadr_probe`'s JTAG ports directly rather than through a
// primitive: that is why the primitive is in the top level and the shift
// register is not.
//
// The port list is Xilinx's, restricted to the pins `cadr_arty.sv` names, and
// `JTAG_CHAIN` is the one parameter it overrides.
module BSCANE2 #(
    parameter int JTAG_CHAIN = 1
) (
    output var logic CAPTURE,
    output var logic DRCK,
    output var logic RESET,
    output var logic RUNTEST,
    output var logic SEL,
    output var logic SHIFT,
    output var logic TCK,
    output var logic TDI,
    output var logic TMS,
    output var logic UPDATE,
    input  var logic TDO
);
  assign CAPTURE = 1'b0;
  assign DRCK    = 1'b0;
  assign RESET   = 1'b0;
  assign RUNTEST = 1'b0;
  assign SEL     = 1'b0;
  assign SHIFT   = 1'b0;
  assign TCK     = 1'b0;
  assign TDI     = 1'b0;
  assign TMS     = 1'b0;
  assign UPDATE  = 1'b0;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_bscan;
  assign unused_bscan = &{1'b0, TDO, JTAG_CHAIN != 0};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

// The serializer, and the one primitive in this project whose absence from
// the checks is stated rather than worked around.  Ten bits a pixel needs a
// master and a slave cascaded, `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` has
// the wiring, and NOTHING HERE SHIFTS ANYTHING: the output is tied low, so a
// simulation built on this would show a dark connector whatever the encoder
// did.  That is the point.  What is checked is the encoder above it, which
// is plain SystemVerilog in `rtl/plumbing/`, and what is not checked is
// said so in `docs/display-output.md` rather than covered by a model that
// could only agree with itself.
//
// The port list is Xilinx's restricted to the pins the phy names, and the
// five parameters are the five it overrides.
module OSERDESE2 #(
    parameter string DATA_RATE_OQ   = "DDR",
    parameter string DATA_RATE_TQ   = "DDR",
    parameter int    DATA_WIDTH     = 4,
    parameter string SERDES_MODE    = "MASTER",
    parameter int    TRISTATE_WIDTH = 4
) (
    output var logic OFB,
    output var logic OQ,
    output var logic SHIFTOUT1,
    output var logic SHIFTOUT2,
    output var logic TBYTEOUT,
    output var logic TFB,
    output var logic TQ,
    input  var logic CLK,
    input  var logic CLKDIV,
    input  var logic D1,
    input  var logic D2,
    input  var logic D3,
    input  var logic D4,
    input  var logic D5,
    input  var logic D6,
    input  var logic D7,
    input  var logic D8,
    input  var logic OCE,
    input  var logic RST,
    input  var logic SHIFTIN1,
    input  var logic SHIFTIN2,
    input  var logic T1,
    input  var logic T2,
    input  var logic T3,
    input  var logic T4,
    input  var logic TBYTEIN,
    input  var logic TCE
);

  assign OFB       = 1'b0;
  assign OQ        = 1'b0;
  assign SHIFTOUT1 = 1'b0;
  assign SHIFTOUT2 = 1'b0;
  assign TBYTEOUT  = 1'b0;
  assign TFB       = 1'b0;
  assign TQ        = 1'b0;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_oserdes;
  assign unused_oserdes = &{1'b0, CLK, CLKDIV, D1, D2, D3, D4, D5, D6, D7, D8,
                            OCE, RST, SHIFTIN1, SHIFTIN2, T1, T2, T3, T4,
                            TBYTEIN, TCE,
                            DATA_RATE_OQ != "", DATA_RATE_TQ != "",
                            DATA_WIDTH != 0, SERDES_MODE != "",
                            TRISTATE_WIDTH != 0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

// The differential output buffer.  Two pins out of one bit, and on the
// high-range bank this board's HDMI connector sits on it is `TMDS_33`, which
// `boards/arty-z7-20/cadr_hdmi.xdc` sets on the ports rather than here ---
// the real primitive takes an `IOSTANDARD` parameter and Vivado takes the
// constraint file's word over it, so naming it in two places is one more
// thing that can disagree.
module OBUFDS (
    output var logic O,
    output var logic OB,
    input  var logic I
);
  assign O  = 1'b0;
  assign OB = 1'b0;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_obufds;
  assign unused_obufds = &{1'b0, I};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

// The regional clock buffer.  `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv`
// carries the serial clock on one of these because a global buffer on this
// speed grade will not take 540 MHz; see that file's header for the measured
// numbers.  As a stub it is a wire, like `BUFG` above it.
module BUFIO (
    output var logic O,
    input  var logic I
);
  assign O = I;
endmodule

/* verilator lint_on DECLFILENAME */

`default_nettype wire
