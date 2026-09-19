// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The probe's JTAG side on an Altera part: one node of the SLD hub, reached
// through Altera's Virtual JTAG IP.
//
// **THE CAPTURE IS `rtl/plumbing/cadr_probe.sv` AND IS THE SAME ON EVERY
// PART.**  What differs between vendors is only how a JTAG scan reaches its
// shift register.  On the Zynq boards a `BSCANE2` in the top level hands it a
// user data register of the part's own TAP.  An Agilex 5 has no such
// primitive for fabric logic: every user scan goes through the SLD hub, which
// Quartus builds whenever a design has a node, and a node is one instance of
// the Virtual JTAG IP.  `boards/de25-nano/quartus/build.sh` generates that IP
// as `cadr_de25_vjtag`, the top level instantiates it beside the PLL and the
// Reset Release, and this module is what stands between it and the probe.
//
// WHAT THE IP GIVES, from Altera's Virtual JTAG IP Core User Guide
// (UG-SLDVRTL, 683705, 2021.08.12), tables 3 to 5 and its design-flow
// section:
//
//   tck                the device's TCK, shared by every node and running in
//                      every TAP state, where `BSCANE2`'s DRCK runs only in
//                      Capture-DR and Shift-DR.
//   tdi                the device's TDI, "used when virtual_state_sdr is
//                      high".
//   ir_in              the node's virtual instruction, "available and latched
//                      when virtual_state_uir is high".
//   virtual_state_cdr  this node in its virtual Capture-DR: "if you load a
//                      value to be shifted out of the JTAG port, you would do
//                      so when the virtual_state_cdr signal is asserted".
//   virtual_state_sdr  this node in its virtual Shift-DR, when "this instance
//                      is required to establish the JTAG chain".
//   tdo, ir_out        what the node gives back: the bit a DR scan reads, and
//                      the value a virtual IR scan captures.
//
// So the probe's five inputs are the IP's own signals, one each.  DRCK
// becomes TCK, and that is safe because the probe's shift register acts only
// while `jtag_capture` or `jtag_shift` is high, so the edges a free-running
// clock adds in every other state do nothing.  SEL becomes the virtual
// instruction.
//
// THE VIRTUAL INSTRUCTION IS ONE BIT, AND BOTH VALUES MEAN SOMETHING.
//
//   1   the sample register: one DR scan of the probe's 454 bits returns one
//       sample and moves the read pointer, as `cadr_probe.sv` describes.
//   0   a one-bit bypass register, which captures 0.  The guide asks that
//       every instruction code map to a register "to maintain connectivity
//       in the TDI-to-TDO datapath", and recommends a bypass register for
//       the codes a node does not use.
//
// **AND BOTH ARE READ BACK.**  A virtual IR scan captures `ir_out`, which is
// the instruction the node holds, so the reader can see that the value it
// shifted in is the value the node took.  And a DR scan in bypass returns a
// known pattern one bit late behind the captured 0, which is the one
// measurement of this path's bit order and alignment that owes nothing to
// the probe.  `boards/de25-nano/quartus/probe.tcl` asks both before it reads
// a sample.  A virtual instruction of 0 is also what the hub holds before
// anything has been shifted, so a node nobody has selected is a bypass bit.
//
// THE CLOCK DOMAINS ARE THE PROBE'S.  Everything here is combinational, or
// in the TCK domain, which `boards/de25-nano/quartus/cadr_de25.sdc` declares
// and makes asynchronous to the machine's clock, for the reason
// `cadr_probe.sv` gives about its own crossing.
//
// WHAT HOLDS IT.  `tb/cadr_probe_tb.cpp` reads a second probe through this
// module, wired as `boards/de25-nano/cadr_de25.sv` wires it, with TCK
// running in every state as the guide says it does, and compares every
// sample with `build/rtl.golden` as it does the Zynq boards' path.  Its model
// of the hub is the guide's words and nothing more; the silicon is the
// check on that.

`default_nettype none

module cadr_probe_vjtag (
    // ------------------------------------------ the Virtual JTAG IP's side
    input  var logic tck,
    input  var logic tdi,
    input  var logic ir_in,
    input  var logic virtual_state_cdr,
    input  var logic virtual_state_sdr,
    output var logic tdo,
    output var logic ir_out,

    // ------------------------------------------------------- the probe's
    output var logic jtag_drck,
    output var logic jtag_sel,
    output var logic jtag_shift,
    output var logic jtag_capture,
    output var logic jtag_tdi,
    input  var logic jtag_tdo
);

  // The probe's side, one signal each.  See the header for why TCK can stand
  // where DRCK stands on the Zynq boards.
  assign jtag_drck    = tck;
  assign jtag_sel     = ir_in;
  assign jtag_capture = virtual_state_cdr;
  assign jtag_shift   = virtual_state_sdr;
  assign jtag_tdi     = tdi;

  // The bypass register, for the instruction that is not the sample's.  It
  // captures 0, as IEEE 1149.1's does, so the first bit a bypass scan reads
  // is known.
  logic bypass;
  always_ff @(posedge tck) begin
    if (virtual_state_cdr) begin
      bypass <= 1'b0;
    end else if (virtual_state_sdr) begin
      bypass <= tdi;
    end
  end

  assign tdo = ir_in ? jtag_tdo : bypass;

  // The instruction the node holds, captured by every virtual IR scan.
  assign ir_out = ir_in;

endmodule

`default_nettype wire
