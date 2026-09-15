// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `USR_ACCESSE2` as a shell, so that `rtl/plumbing/xilinx7/cadr_usr_access.sv`
// elaborates under Verilator and the three board lints reach the top levels
// that instantiate it.
//
// **IT IS IN `tb/` AND MUST NEVER MOVE TO `rtl/`**, for the reason
// `tb/cadr_arty_stubs.sv` gives at length: the board flows read
// `[glob rtl/*/*.sv rtl/*/*/*.sv boards/<board>/*.sv]`, so a stub here would
// be handed to synthesis alongside --- and in place of --- the real
// primitive, and the board would then report a build that was compiled in
// rather than the one in its own bitstream.  Nothing globs `tb/`.
//
// **IT IS ITS OWN FILE AND NOT ONE MORE MODULE IN `tb/cadr_arty_stubs.sv`**,
// because that file says of itself that nothing in it models anything and
// that lint is all it is for, and this one does model something: it returns a
// value, which is the only behavior the primitive has.  A check may want it,
// and a file whose header forbids simulation is the wrong place to put the
// one stub a simulation could use.
//
// The port list is Xilinx's --- `data/verilog/src/unisims/USR_ACCESSE2.v`,
// three outputs and no inputs --- and the real primitive's own simulation
// model does exactly what this does, returning a fixed word.  Xilinx's is
// `32'h12345678`; this one is a value with the shape of a build stamp so that
// a check reading it through the console exercises the decode rather than a
// number no stamp could be.
//
// **THE PARAMETER IS NOT ONE THE REAL PRIMITIVE HAS.**  `USR_ACCESSE2` takes
// only `LOC`, and that under `XIL_TIMING`.  So nothing in `rtl/` may override
// `SIM_DATA`: a wrapper that did would lint here and be refused by synthesis,
// which is the good direction but still a difference between the two builds.
// It is here for a testbench that instantiates the primitive directly and
// wants to choose what the fabric claims to be.

`default_nettype none

// Xilinx chose the module name and a file named after it would say nothing
// about what it is, which is the stub.
/* verilator lint_off DECLFILENAME */

module USR_ACCESSE2 #(
    // Seven hex digits and a tree nibble, `tools/build_stamp.tcl`'s format:
    // commit `5a1b2c3`, nibble 3, which is a tree that was both modified and
    // carrying an untracked file.  Not a commit of this repository and not a
    // value the flows could write for it, so a check that sees it knows it is
    // looking at the stub.
    parameter logic [31:0] SIM_DATA = 32'h5A1B_2C33
) (
    output var logic        CFGCLK,
    output var logic [31:0] DATA,
    output var logic        DATAVALID
);
  // The configuration clock stops when configuration ends, so a running part
  // holds it low; the register is loaded by the bitstream, so a configured
  // part always says the value is valid.
  assign CFGCLK    = 1'b0;
  assign DATA      = SIM_DATA;
  assign DATAVALID = 1'b1;
endmodule

/* verilator lint_on DECLFILENAME */

`default_nettype wire
