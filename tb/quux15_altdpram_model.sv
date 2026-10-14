// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **A MODEL OF ALTERA'S `altdpram`, OURS AND MINIMAL, FOR SIMULATION ONLY**:
// the one configuration `rtl/plumbing/agilex5/quux15_mdmem.sv` instantiates,
// so that the Agilex 5 version of the macro dispatch memory can be
// simulated (`tools/quux15_ram_eq_check.py`, and the core's goldens on the
// Agilex 5 RTL, `make quux15-a5`).  No vendor library file is used or
// carried; Quartus builds the real one.
//
// **WHAT IT MODELS**, the behavior the instance's parameters name:
//
// - `INDATA_REG`, `WRADDRESS_REG` and `WRCONTROL_REG` "INCLOCK": the write's
//   word, address and enable are taken at `inclock`'s rising edge.
// - `RDADDRESS_REG`, `RDCONTROL_REG` and `OUTDATA_REG` "UNREGISTERED": `q` is
//   the word at `rdaddress`, combinationally, with no clock.
// - `READ_DURING_WRITE_MODE_MIXED_PORTS` "DONT_CARE": a read of the address
//   being written is undefined.  The cell takes the write DURING THE CLOCK
//   AFTER the edge that took it (Quartus's own simulation model of `altdpram`
//   writes it at that clock's falling edge), so that clock is the write's
//   window: a read of the written address in it is given the new word's
//   complement here, so that a design relying on either word fails.  From the
//   clock after, the read is the new word.
// - Power-on: every word 0, as an MLAB comes up.
//
// Anything else is refused at elaboration rather than modelled wrongly.

`default_nettype none

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
module altdpram #(
    parameter int WIDTH = 1,
    parameter int WIDTHAD = 1,
    parameter int NUMWORDS = 2,
    parameter string INDATA_REG = "INCLOCK",
    parameter string WRADDRESS_REG = "INCLOCK",
    parameter string WRCONTROL_REG = "INCLOCK",
    parameter string RDADDRESS_REG = "UNREGISTERED",
    parameter string RDCONTROL_REG = "UNREGISTERED",
    parameter string OUTDATA_REG = "UNREGISTERED",
    parameter string RAM_BLOCK_TYPE = "MLAB",
    parameter string USE_EAB = "ON",
    parameter string INTENDED_DEVICE_FAMILY = "Agilex 5",
    parameter string READ_DURING_WRITE_MODE_MIXED_PORTS = "DONT_CARE"
) (
    input  var logic               inclock,
    input  var logic               wren,
    input  var logic [WIDTHAD-1:0] wraddress,
    input  var logic [WIDTH-1:0]   data,
    input  var logic [WIDTHAD-1:0] rdaddress,
    output var logic [WIDTH-1:0]   q
);
/* verilator lint_on UNUSEDPARAM */
  initial begin
    if (INDATA_REG != "INCLOCK" || WRADDRESS_REG != "INCLOCK" || WRCONTROL_REG != "INCLOCK"
        || RDADDRESS_REG != "UNREGISTERED" || RDCONTROL_REG != "UNREGISTERED"
        || OUTDATA_REG != "UNREGISTERED" || READ_DURING_WRITE_MODE_MIXED_PORTS != "DONT_CARE"
        || NUMWORDS > (1 << WIDTHAD))
      $fatal(1, "altdpram model: only a write on inclock, an unregistered read and DONT_CARE are modelled");
  end

  logic [WIDTH-1:0] mem[NUMWORDS] /* verilator public_flat_rw */;
  initial for (int k = 0; k < NUMWORDS; k++) mem[k] = '0;
  always_ff @(posedge inclock) if (wren) mem[wraddress] <= data;

  // The write's window, the clock after the edge that took it.
  logic               wren_q = 1'b0;
  logic [WIDTHAD-1:0] wraddress_q;
  always_ff @(posedge inclock) begin
    wren_q      <= wren;
    wraddress_q <= wraddress;
  end
  assign q = (wren_q && wraddress_q == rdaddress) ? ~mem[rdaddress] : mem[rdaddress];
endmodule
/* verilator lint_on DECLFILENAME */

`default_nettype wire
