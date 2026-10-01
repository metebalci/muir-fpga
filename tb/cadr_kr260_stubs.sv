// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The UltraScale+ primitive the Kria KR260's top level names and the
// Zynq-7000's do not, as a shell for Verilator: `MMCME4_BASE`.  The rest of
// what that top level names --- `BUFG`, `USR_ACCESSE2` --- is the same
// primitive on both families and comes from `tb/cadr_arty_stubs.sv` and
// `tb/cadr_usr_access_stub.sv`, and `PS8` from `tb/cadr_ps8_stub.sv`.
//
// **IT IS NOT A MULTIPLIER**, exactly as `cadr_arty_stubs.sv`'s
// `MMCME2_BASE` is not: the input passes through, which is all lint needs.
// And it names only the parameters the top level sets, so an override of one
// it does not name is an elaboration error and not a silent default.
//
// **THIS FILE MUST NEVER MOVE TO `rtl/` OR `boards/`**: the Vivado flows glob
// those, and a stub there would be synthesized in place of the primitive.

`default_nettype none

/* verilator lint_off DECLFILENAME */
module MMCME4_BASE #(
    parameter real CLKIN1_PERIOD    = 0.000,
    parameter int  DIVCLK_DIVIDE    = 1,
    parameter real CLKFBOUT_MULT_F  = 5.000,
    parameter real CLKOUT0_DIVIDE_F = 1.000
) (
    output var logic CLKFBOUT,
    output var logic CLKFBOUTB,
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
    output var logic LOCKED,
    input  var logic CLKFBIN,
    input  var logic CLKIN1,
    input  var logic PWRDWN,
    input  var logic RST
);

  // `CLKFBOUT` comes off `CLKIN1` rather than `CLKFBIN`, because the top
  // level ties those two together and the feedback would be a loop.
  assign CLKOUT0   = CLKIN1;
  assign CLKFBOUT  = CLKIN1;
  assign LOCKED    = !RST && !PWRDWN;

  assign CLKFBOUTB = 1'b0;
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

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, CLKFBIN, CLKIN1_PERIOD != 0.0, DIVCLK_DIVIDE[0],
                    CLKFBOUT_MULT_F != 0.0, CLKOUT0_DIVIDE_F != 0.0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
/* verilator lint_on DECLFILENAME */

`default_nettype wire
