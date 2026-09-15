// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE BUILD THE FABRIC WAS MADE FROM, READ BACK FROM INSIDE IT.
//
// `tools/build_stamp.tcl` writes eight hex digits into
// `BITSTREAM.CONFIG.USR_ACCESS` before every `write_bitstream`: the commit's
// first seven digits and a nibble saying how the tree stood.  That value goes
// into the part's AXSS register at configuration, and `USR_ACCESSE2` is the
// one way to read it without JTAG.  So a board that has been running for
// hours can still say which build it is carrying, which is the thing this
// project has twice not known and twice been bitten by.
//
// The same number goes into `BITSTREAM.CONFIG.USERID`, which the JTAG
// USERCODE register holds and `boards/*/vivado/program.tcl` reads.  **The two
// registers are loaded from one value and read by two different observers**:
// USERCODE by somebody with a cable, AXSS by the machine's own console over
// `M_AXI_GP1`.  They agree because one line sets both, and a board session
// that reads both has compared them.
//
// ------------------------------------------------------------------ the wire
//
// One primitive and one wire, which is why this file is in `xilinx7/` beside
// `cadr_probe.sv`'s scan primitive and `cadr_hdmi_phy.sv`'s serializers: it is
// the part's and not the machine's, and the promise that `rtl/machine/` is
// plain SystemVerilog is kept by keeping this out of it.
//
// **NOTHING SIMULATES THIS AND THAT IS STATED RATHER THAN WORKED AROUND**, as
// `cadr_hdmi_phy.sv` states the same for its serializers.  The three board
// lints elaborate it against `tb/cadr_usr_access_stub.sv`, which returns a
// value of its own; what the console does with the thirty-two bits is checked
// by `build/console.pass` and `build/soc.pass`, both of which drive the
// console's `build` input directly.  A check that instantiated this and then
// asserted what came out could only agree with the stub.
//
// `DATAVALID` and `CFGCLK` are not brought out.  `DATAVALID` says the AXSS
// register has been loaded, which on a configured part it always has --- the
// value is in the bitstream and arrives with it --- and `CFGCLK` is the
// configuration clock, which stops when configuration ends.  A console that
// reported `DATAVALID` would be reporting a constant, and this file's own
// rule is that a value which means nothing must not be a value an instrument
// can mean.  The word reading `ffffffff` is what says there is no stamp, and
// that comes from the register rather than from a validity pin.

`default_nettype none

module cadr_usr_access (
    // The eight hex digits `tools/build_stamp.tcl` put in the bitstream, or
    // all ones on a part configured with a bitstream built before the flows
    // stamped them.  `console_face.h`'s `cons_build_of` reads both.
    output var logic [31:0] build
);

  // Two outputs nobody reads, which lint would say so about; on the board
  // they are real pins of a real cell and leaving them open is the point.
  /* verilator lint_off UNUSEDSIGNAL */
  logic cfgclk, datavalid;
  /* verilator lint_on UNUSEDSIGNAL */

  USR_ACCESSE2 u_axss (
      .CFGCLK   (cfgclk),
      .DATA     (build),
      .DATAVALID(datavalid)
  );

endmodule

`default_nettype wire
