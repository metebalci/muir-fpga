// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Main memory: an Xbus slave in front of PS DDR3.
//
// The first module here with no reference behind it.  Everything else is a
// port of muir, held to it tick for tick; there is nothing in MIT's drawings
// that is a DDR controller, and `busint::MemoryBoard` models a board of 4116s
// refreshing itself, which is not what this is.  So this is checked instead by
// what it has to be true of: a read returns what a write put there, and the
// cycle around it still keeps the Xbus timing.
//
// The bridge is deliberately **thin**.  It adds no ticks of its own: `mem_req`
// follows `-XBUS.RQ` and `dev_ack` follows `mem_done`, both without a register
// in the way, so the whole of the latency belongs to the AXI adapter behind it
// and shows up as the device's answer time.  That is what keeps it comparable
// with the model, whose device answers `device_ns` after `-XBUS.RQ` and not
// `device_ns` plus whatever the slave costs.  If timing closure ever wants a
// register here, the cost is not correctness --- the bus interface simply waits
// longer, as it does for any slow slave --- but it is a change to measure.
//
// Address and data are taken as they stand rather than latched, which the bus
// specification is what makes safe: "it is the responsibility of the bus master
// to assert good address, write, and data lines 80 ns. prior to asserting
// -XBUS.RQ".  Read data is latched, because the cpu takes it at `-LOADMD` and
// the word has to still be there --- and it is cleared when the cycle ends,
// because a slave drives MEM<31:0> only while it is answering and an
// unanswered read gives MD zero.  The note at the register says why that
// matters more than it sounds like it does.
//
// NOT HERE YET: the AXI adapter itself.  `mem_*` is a plain request/response
// port, and what turns it into AXI4 --- which Vivado's converter then turns
// into the AXI3 the Zynq-7000 PS ports actually speak --- is its own slice.

`default_nettype none

module cadr_xbus_ddr
  import cadr_ddr_map::*;
(
    input  var logic        clk,
    input  var logic        rst,

    // The Xbus slave side.
    input  var logic        sel,        // the decode says this address is ours
    input  var logic        dev_rq,     // -XBUS.RQ, as a positive level
    input  var logic        dev_write,
    input  var logic [21:0] phys,       // -XADDR21..0, a word address
    input  var logic [31:0] wdata,      // MEM<31:0> from the cpu
    output var logic        dev_ack,    // -XBUS.ACK
    output var logic [31:0] rdata,      // MEM<31:0> to the cpu

    // The memory behind it. One 32-bit word a request; the AXI adapter is the
    // next slice.
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,   // a byte address in PS DDR3
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata
);

  // Whether this slave is being asked for anything at all.
  logic asked;
  assign asked = sel && dev_rq;

  // The answer, once given, stands until the master lifts the request ---
  // "-XBUS.ACK ... remains asserted until the -XBUS.RQ signal is removed by the
  // master". `mem_done` is or'd in live so that the bridge adds no tick.
  logic done;
  assign dev_ack = asked && (done || mem_done);

  assign mem_req   = asked && !done;
  assign mem_write = dev_write;

  // A CADR word address into a byte address in the reserved region: a word is
  // 32 bits, so two places left. cadr_ddr_map has the region.
  assign mem_addr  = main_byte_address(phys);
  assign mem_wdata = wdata;

  always_ff @(posedge clk) begin
    if (rst) begin
      done  <= 1'b0;
      rdata <= 32'd0;
    end else if (!asked) begin
      // The cycle is over; the next one starts fresh.
      //
      // **AND THE WORD GOES WITH IT.**  `rdata` is this slave's driver onto
      // MEM<31:0>, and a slave drives the data lines only while it is
      // selected and answering; the register is a stand-in for that driver
      // and not a place to keep a word.  Held across cycles it was one:
      // `cadr_memory_path.sv` falls through to `memory_rdata` when nothing
      // acknowledges, and -LOADMD is asserted on every acknowledgement
      // including the NXM timer's, so every cycle nothing answered strobed MD
      // with whatever this slave last returned.  On the DDR board that is the
      // last word of page 0, and bit 0 of it is what the boot PROM's
      // JUMP-IF-BIT-CLEAR reads as a ready disk controller --- so what
      // happened to be in main memory decided where the machine went.
      // **An unanswered read gives MD zero**, and this is where that is made
      // true: there is always a gap with `asked` low between two bus cycles,
      // because a cycle ends by the master lifting -XBUS.RQ, so the word is
      // gone before the next cycle can be acknowledged.
      //
      // It cannot take the word away from a cycle that DID get an answer.
      // -XBUS.ACK "remains asserted until the -XBUS.RQ signal is removed by
      // the master", so `dev_rq` stands through the whole of `acked` --- it
      // is a term of `dev_rq` in the ACKED state --- and -LOADMD is `acked`.
      // MD has taken the word before `asked` can fall.
      //
      // The alternative was to gate `memory_rdata` in `cadr_memory_path.sv`
      // on whether the cycle was answered.  That puts bus resolution in the
      // path rather than in the slave, needs a signal that does not exist
      // yet, and leaves the bridge still holding a word it has no business
      // holding for anything else that ever reads it.
      done  <= 1'b0;
      rdata <= 32'd0;
    end else if (mem_done && !done) begin
      done <= 1'b1;
      // Held for the cpu, which takes the word at -LOADMD.
      if (!dev_write) rdata <= mem_rdata;
    end
  end

endmodule

`default_nettype wire
