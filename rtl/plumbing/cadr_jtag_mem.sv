// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The debugger's own way into main memory, and the port's tally beside it.
//
// WHY THIS EXISTS, AND IT IS NOT A CONVENIENCE.  Everything this project has
// ever claimed about a memory path on silicon rests on an observer OUTSIDE the
// design under test.  On the Arty Z7-20 that observer is the JTAG debugger
// reading DDR through the processing system: `vivado/prove_write.tcl` poisons
// a neighborhood, the fabric writes one word into it, and the debugger reads
// it back --- and the two never share a wire, because UG585's own port table
// puts the debug access port on a different DDR controller port from the one
// the fabric uses.
//
// **ON THIS BOARD THERE IS NO SUCH DOOR.**  An Artix-7 has no processing
// system, no debug access port onto memory and no second master anywhere: the
// DDR3L is on the fabric's pins and the only thing that can reach it is the
// fabric.  So the observer has to be given a path, and this is it --- a
// register the JTAG chain can read and write, and a request onto the shared
// memory port behind it.
//
// WHAT THAT COSTS IN EVIDENCE, SAID PLAINLY.  The debugger's words now travel
// the same `cadr_mem_cross` and `cadr_mig_ui` and the same controller that the
// machine's do, so a fault common to both directions --- always the wrong
// lane, always the same dropped address bit --- would write wrongly and read
// wrongly and agree with itself.  That is this repository's oldest trap: a
// shadow memory keyed off the design under test moves with the bug.  Three
// things are what make the instrument sharp anyway, and all three are the
// HOST's and not the fabric's:
//
//   * **The poison is injective in the address and computed on the host.**  A
//     dropped address bit makes two host addresses land on one word, so the
//     first one read back carries the second one's poison.
//   * **All four lanes of a sixteen-byte block are written with different
//     words and read back.**  A lane select stuck at one value collapses the
//     four into one, and the read-back shows the last word written four times.
//   * **The tally is not on this path at all.**  It counts what the memory
//     controller's own user interface accepted and returned, which a fabric
//     that issued nothing cannot fabricate, and it is read out through this
//     register without ever going near it.
//
// **IT ASKS AND DOES NOT ARBITRATE.**  This module used to sit in front of the
// port and give it to the machine first.  The port has more masters now --- the
// disk pack face's and the soft processing system's --- and
// `rtl/plumbing/cadr_mem_share.sv` is the one arbiter in front of all of them,
// with the machine first and one word in flight at a time.  A second arbiter
// here would have let a machine cycle wait for a debugger's transaction that
// was itself waiting for a disk word, which is two accesses where the bound is
// one.  So a command raises a request, holds it until the answer comes, takes
// the word and lets go, like every other master on the port.  A transaction
// that has begun runs to the end, because a request half made to a DDR3
// controller cannot be taken back.
//
// THE SCAN.  One data register of `DR_BITS` bits on a `BSCANE2` user chain ---
// chain 2, which is IR 000011 on a seven-series part, where `cadr_probe` has
// chain 1.  A scan does both halves at once, which is what a JTAG data
// register is for: what shifts OUT was captured at the start of the scan, and
// what shifts IN takes effect at UPDATE.  So a read is two scans --- one to
// ask, one to collect --- and the fabric has done the work in between, in
// microseconds, while the host was deciding to scan again.
//
// **THE COMMAND RUNS ON A CHANGE OF `go` AND NOT ON ITS LEVEL**, so that a
// host that scans the same word twice does not perform the transaction twice.
// That matters because the natural way to poll for an answer is to re-scan,
// and a re-scan must be harmless.
//
// **AND THE REGISTER SAYS WHAT IT IS.**  The top thirty-two bits read
// `0x4D454D57`, `MEMW`, which is this project's idiom --- `CONS`, `PACK`,
// `DBUG`, and `NONE` for a window pointed at nothing.  A chain that is not
// selected, a part that is not configured and a bitstream without this module
// in it all read as zeros or ones, and neither of those is `MEMW`.

`default_nettype none

module cadr_jtag_mem #(
    // The data register.  Fixed, because the host script and this file must
    // agree bit for bit and a parameter is two descriptions of one layout.
    parameter int unsigned DR_BITS = 160
) (
    input  var logic        clk,
    input  var logic        rst,

    // ------------------------------------------- the request onto the port
    //
    // One of `cadr_mem_share.sv`'s masters.  `p_done` is up only while this
    // module owns the port and the answer stands.
    output var logic        p_req,
    output var logic        p_write,
    output var logic [31:0] p_addr,
    output var logic [31:0] p_wdata,
    input  var logic        p_done,
    input  var logic [31:0] p_rdata,
    input  var logic        p_error,

    // ----------------------------------------- what the register also carries
    input  var logic [63:0] tally,          // cadr_mem_count's sixty-four bits
    input  var logic        calib_done,     // the controller has trained DDR3L
    input  var logic        prove_has_run,
    input  var logic        prove_matched,
    // A pulse on the rise of the scanned `arm` bit: on a proving board it
    // releases the witness, which is what puts the poison before the witness's
    // write in time rather than in hope.
    output var logic        arm,
    // ...and a LEVEL that holds the machine in reset.
    //
    // **WITHOUT IT NOBODY COULD RUN THE MEMORY STEP WITH NOBODY AT THE
    // BOARD.**  The machine reaches its first main-memory cycle 118 ms after
    // its own reset and a debugger needs seconds to poison a neighborhood
    // through this register, so the poison would always arrive after the
    // machine had already read.  On the Arty Z7-20 the processing system's own
    // port gate did this --- poison, then `ps7_post_config`, then the fabric
    // --- and there is no such gate here.  It resets the MACHINE and not the
    // memory controller, so a held machine keeps every word in DDR.
    output var logic        mach_reset,

    // ------------------------------------------------- the BSCANE2's fabric
    // side.  The primitive is instantiated in the top level, beside the
    // probe's, so that this module is a module and can be simulated.
    input  var logic        jtag_drck,
    input  var logic        jtag_sel,
    input  var logic        jtag_shift,
    input  var logic        jtag_capture,
    input  var logic        jtag_update,
    input  var logic        jtag_tdi,
    output var logic        jtag_tdo
);

  localparam logic [31:0] IDENT = 32'h4D45_4D57;   // "MEMW"

  // ---------------------------------------------------------- the shift
  //
  // TDI enters at the top and TDO leaves from the bottom, so the bit the host
  // shifts first is the bit this register calls zero --- which is the
  // correspondence Vivado's own `scan_dr_hw_jtag` uses for both directions and
  // is what lets the host talk about bit numbers rather than about order.
  logic [DR_BITS-1:0] sr;
  logic [DR_BITS-1:0] capture_word;

  logic        busy;
  logic        have_run;
  logic        err_q;
  logic [31:0] rdata_q;
  logic        go_cmd, go_seen, arm_cmd, arm_seen, reset_cmd;

  always_comb begin
    capture_word               = '0;
    capture_word[31:0]         = rdata_q;
    capture_word[95:32]        = tally;
    capture_word[96]           = busy;
    capture_word[97]           = have_run;
    capture_word[98]           = err_q;
    capture_word[99]           = calib_done;
    capture_word[100]          = prove_has_run;
    capture_word[101]          = prove_matched;
    capture_word[102]          = go_cmd;
    capture_word[103]          = reset_cmd;
    capture_word[DR_BITS-1-:32] = IDENT;
  end

  always_ff @(posedge jtag_drck) begin
    if (jtag_sel) begin
      if (jtag_capture)     sr <= capture_word;
      else if (jtag_shift)  sr <= {jtag_tdi, sr[DR_BITS-1:1]};
    end
  end

  assign jtag_tdo = sr[0];

  // ------------------------------------------------- the command, brought over
  //
  // UPDATE is a pulse in the test access port's own clock and the shift
  // register has stopped moving before it --- the last shift is in EXIT1-DR,
  // and the next data-register clock is the following scan's CAPTURE.  So the
  // whole of `sr` is standing still by the time this sees the pulse two clocks
  // later, and it is sampled straight rather than through 160 synchronizers.
  // That is the same argument `cadr_mem_cross` makes for the payload it
  // carries, and it is the argument that has to be true for either to work.
  logic [2:0] upd_sync;
  logic       upd_rise;
  always_ff @(posedge clk) begin
    if (rst) upd_sync <= 3'b000;
    else     upd_sync <= {upd_sync[1:0], jtag_update && jtag_sel};
  end
  assign upd_rise = upd_sync[1] && !upd_sync[2];

  logic        cmd_write;
  logic [31:0] cmd_addr, cmd_wdata;

  // ------------------------------------------------------ the request
  always_ff @(posedge clk) begin
    if (rst) begin
      busy      <= 1'b0;
      have_run  <= 1'b0;
      err_q     <= 1'b0;
      rdata_q   <= 32'd0;
      go_cmd    <= 1'b0;
      go_seen   <= 1'b0;
      arm_cmd   <= 1'b0;
      arm_seen  <= 1'b0;
      reset_cmd <= 1'b0;
      cmd_write <= 1'b0;
      cmd_addr  <= 32'd0;
      cmd_wdata <= 32'd0;
    end else begin
      arm_seen <= arm_cmd;

      if (upd_rise) begin
        cmd_wdata <= sr[31:0];
        cmd_addr  <= sr[63:32];
        cmd_write <= sr[64];
        go_cmd    <= sr[65];
        arm_cmd   <= sr[66];
        reset_cmd <= sr[67];
      end

      // A change of `go` that has not been acted on is what starts one, and
      // the answer is what ends it.
      if (!busy && (go_cmd != go_seen)) begin
        busy <= 1'b1;
      end else if (busy && p_done) begin
        rdata_q  <= p_rdata;
        err_q    <= p_error;
        have_run <= 1'b1;
        busy     <= 1'b0;
        go_seen  <= go_cmd;
      end
    end
  end

  // The re-arm is one clock wide on the rise of the scanned bit.
  assign arm = arm_cmd && !arm_seen;

  // The machine's reset is a LEVEL and not a pulse, because holding it is the
  // whole point: the debugger writes it, poisons memory at its leisure, and
  // lets it go.
  assign mach_reset = reset_cmd;

  // ----------------------------------------------------------- the port
  assign p_req   = busy;
  assign p_write = cmd_write;
  assign p_addr  = cmd_addr;
  assign p_wdata = cmd_wdata;

endmodule

`default_nettype wire
