// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Whether the FPGA-to-SDRAM port may be used, and the fabric's half of the
// processor's warm-reset handshake.
//
// **THE PORT IS SHUT UNTIL SOFTWARE OPENS IT.**  On the Zynq boards
// `S_AXI_HP0` is dead until `ps7_post_config` turns the level shifters on, and
// the processing system says so on `SAXIHP0ARESETN`.  The Agilex 5 has no such
// signal.  Before its bridge can carry a transaction, the first-stage loader
// must calibrate the LPDDR4 and open the bridge's DDR firewall, and the
// secure firmware must release the bridge from reset when U-Boot runs
// `bridge enable` (the research note's section 1c, from U-Boot's
// `sdram_soc64.c` and the secure firmware's `socfpga_reset_manager.c`).
// `h2f_reset` falls long before that, so it cannot say the port is live.  So
// software says it, on bit 0 of `h2f_gp_out`, the system manager's GPO
// register at `0x10D1_20E4`.  The Agilex 5 HPS Technical Reference Manual
// (document 814346) describes exactly this use of those bits in its appendix
// A.4: software sets them "after the 'bridge enable' command is done", they
// are driven low by the hardware during every processor reset, and they must
// be set to zero before the fabric is reconfigured from the processor.
//
// So the port is open while `h2f_gp_out[0]` is high and `h2f_reset` is low.
// Until then the AXI adapter and `cadr_f2sdram_share.sv` are held in reset,
// exactly as `hp0_aresetn` holds the Zynq's adapter, and every memory cycle
// the machine makes ends on the bus interface's NXM timer, as on a board with
// no memory.
//
// **SHUTTING THE PORT DOES NOT CUT A TRANSACTION IN HALF.**  A master that has
// put a valid address to the bridge may not take it back, and a bridge that
// has taken one will answer it.  So when the port is shut, when the processor
// asks the fabric to be quiet, or when the FABRIC's own reset comes (KEY1, or
// the PLL losing lock), the share is told to grant nothing new (`hold`), and
// the adapter and the share go into reset only once the share says nothing
// is granted or outstanding (`idle`).  Only the processor's own reset puts
// them into reset at once, because it resets the bridge with them.
//
// **THE FABRIC'S RESET IS LATCHED, BECAUSE IT MAY BE SHORTER THAN THE DRAIN.**
// `drain` is set by `rst` and cleared only once the port has been in reset
// with `rst` gone, so a pulse of one tick still takes the port through
// hold, idle and reset.  The fabric's reset once cut the port at once: a
// read the machine had outstanding left its beat in the bridge's read
// channel, the machine's next read took that beat as its own answer, and
// every read after it was one word late for good.
// `tb/cadr_f2sdram_reset_tb.cpp` pulses the fabric's reset under an
// outstanding read, a write and a burst of the pack side's, and requires
// every later read to return its own word.  The masters must keep running while
// they drain, so the pack side takes the fabric's reset at its own
// `fabric_rst`, which finishes a burst before it resets anything, and the
// display takes `live` and not the fabric's reset.
//
// **THE WARM-RESET HANDSHAKE.**  Enabling the FPGA-to-SDRAM bridge brings out
// `h2f_warm_reset_handshake`, and the user must drive its acknowledgment (the
// HPS Component Reference Manual, document 813752, section 2.2.2).  The
// generated system names the pair `reset_req` and `reset_ack`, and connects
// them to the processor's `h2f_pending_rst_req_n` and `f2h_pending_rst_ack_n`,
// so both are LOW when asserted, as the TRM's reset-signal table in appendix
// A.4 gives them.  The TRM's F2SDRAM bridge reset sequence, section 8.7.4,
// says what the request asks for: "the FPGA logic must ensure that all traffic
// toward the HPS, the SDRAM, or either one is quiescent (inactive)", and then
// acknowledge.  The same request is what the secure firmware raises when U-Boot
// runs `bridge enable`, polling for the acknowledgment for 300 ms.  So a
// request is `hold`, and the acknowledgment is given once the adapter is in
// reset, which is once nothing is in flight.  It follows the request back up.
//
// **AND THE MACHINE WAITS FOR THE PORT, WHICH IS AN ORDERING AND NOT A
// PRECAUTION.**  `may_start` is low from the fabric's reset until the port has
// been live once, and the DE25-Nano's top level holds the machine in reset
// while it is low.  The reason is measured rather than argued: the boot PROM's
// only traffic to main memory is PAGE-0-PARITY-FIX, 512 bus cycles some 118 ms
// after the machine's own reset and none before or after, while the port is
// opened by software in U-Boot, seconds after the fabric was configured.  A
// machine released at the fabric's reset therefore spends its one memory pass
// against a shut port EVERY time, ends all 512 cycles on the bus interface's
// NXM timer, and carries on with nothing stored --- on a board whose memory
// works perfectly.  The Zynq boards do not have the fault because there the
// processing system is configured before the fabric is, so the port is live
// before the machine's first tick; holding the machine here is how this board
// arrives at the same order.
//
// It is a LATCH and not the level: once the machine is running, software
// lowering the bit or the processor resetting must not reset the machine, any
// more than `SAXIHP0ARESETN` falling resets the Zynq's.  What a shut port does
// to a running machine is what a board with no memory does, which is the whole
// of `cadr_f2sdram_share.sv`'s and this module's other business.  The fabric's
// own reset re-arms it, and it is not set again until the drain above has
// put the port through its reset, so KEY1 restarts the machine and it waits
// for the port again --- the drain and a handful of ticks, the port being
// open already.  **That is also what keeps a drained answer from reaching
// the restarted machine**: the adapter is in reset between the old
// transaction's end and the machine's first new one.
//
// All three inputs from the processor are asynchronous to this clock and are
// synchronized in, three stages each, as the Zynq boards synchronize theirs.

`default_nettype none

module cadr_f2sdram_gate (
    input  var logic clk,
    // The fabric's reset.
    input  var logic rst,

    // --- from the processor, asynchronous ---------------------------------
    input  var logic h2f_reset,   // high while the processor is in reset
    input  var logic gp_open,     // `h2f_gp_out[0]`: software opened the port
    input  var logic req_n,       // the warm-reset handshake's request, low

    // --- from the share ----------------------------------------------------
    input  var logic idle,        // nothing granted and nothing outstanding

    // --- to the share, the adapter and the processor -------------------------
    output var logic hold,        // grant nothing new
    output var logic port_rst,    // the adapter and the share in reset
    output var logic ack_n,       // the handshake's acknowledgment, low
    output var logic live,        // the port is open and out of reset
    output var logic may_start    // the port has been live: the machine may run
);

  logic [2:0] rst_s, open_s, req_s;
  always_ff @(posedge clk) begin
    rst_s  <= {rst_s[1:0], h2f_reset};
    open_s <= {open_s[1:0], gp_open};
    req_s  <= {req_s[1:0], !req_n};
  end

  logic hps_rst, opened, pending;
  assign hps_rst = rst_s[2];
  assign opened  = open_s[2];
  assign pending = req_s[2];

  // The fabric's reset, held until the port has been through its reset.
  logic drain;
  always_ff @(posedge clk) begin
    if (rst) drain <= 1'b1;
    else if (port_rst) drain <= 1'b0;
  end

  assign hold = hps_rst || !opened || pending || drain;

  // Registered, so that the reset the adapter and the share see is a
  // register's output and no longer a function of three synchronizers.
  //
  // **THE PORT'S RESET TAKES NO TERM OF THE FABRIC'S RESET DIRECTLY.**  The
  // fabric's reset reaches it through `drain` and `hold`, and so only once
  // the share is idle: see the header.  So it has no reset value of its own,
  // and powers up low; the port is shut at configuration (`h2f_gp_out[0]` is
  // low), so `hold` is up and it rises a tick later, the share powering up
  // idle.  **The acknowledgment keeps the safe
  // value at the fabric's reset**, which is also the value it powers up at,
  // the board being built with no power-up don't care: NOT acknowledged.  An
  // acknowledgment is the fabric saying it has gone quiet, and a register
  // that says so before it has run is a fabric answering for a machine it
  // has not seen.
  always_ff @(posedge clk) begin
    port_rst <= hps_rst || (hold && idle);
  end

  always_ff @(posedge clk) begin
    if (rst) ack_n <= 1'b1;
    else     ack_n <= !(pending && port_rst);
  end

  assign live = !port_rst;

  // The machine's hold, latched: see the header.  Set by the port becoming
  // live and cleared only by the fabric's reset and the drain it starts, so
  // a port shut under a running machine leaves the machine running.
  always_ff @(posedge clk) begin
    if (rst || drain) may_start <= 1'b0;
    else if (live) may_start <= 1'b1;
  end

endmodule

`default_nettype wire
