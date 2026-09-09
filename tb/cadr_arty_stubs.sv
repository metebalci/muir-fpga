// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The two Xilinx primitives `rtl/cadr_arty.sv` instantiates, as empty shells,
// so that Verilator can elaborate the top level and lint it.
//
// **THIS FILE MUST NEVER MOVE TO `rtl/`.**  `vivado/fit.tcl` and
// `vivado/bitstream.tcl` both read `[glob rtl/*.sv]`, so a stub `MMCME2_BASE`
// there would be handed to synthesis alongside --- and in place of --- the real
// primitive, and the board would get a wire where its clock generator belongs.
// That builds, programs, and runs the machine at 125 MHz with 8 ns taps: a
// different machine that still lights LEDs, which is the failure this project
// keeps meeting.  Nothing globs `tb/`, which is the whole reason this is here.
// CLAUDE.md and `docs/pending-rules.md` both say the same.
//
// **AND NOTHING HERE MODELS ANYTHING.**  `rtl/cadr_arty.sv` cannot be
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

// One file, two primitives, and neither is named after it. Xilinx chose the
// module names and this file is where they both belong.
/* verilator lint_off DECLFILENAME */

module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD   = 0.000,
    parameter int  DIVCLK_DIVIDE   = 1,
    parameter real CLKFBOUT_MULT_F = 5.000,
    parameter real CLKOUT0_DIVIDE_F = 1.000
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
                    CLKFBOUT_MULT_F != 0.0, CLKOUT0_DIVIDE_F != 0.0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

module BUFG (
    output var logic O,
    input  var logic I
);
  assign O = I;
endmodule

// The third primitive, and the one `rtl/cadr_arty.sv` only instantiates when
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

/* verilator lint_on DECLFILENAME */

`default_nettype wire
