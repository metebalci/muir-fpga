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
// has taken one will answer it.  So when the port is shut, or when the
// processor asks the fabric to be quiet, the share is told to grant nothing
// new (`hold`), and the adapter and the share go into reset only once the
// share says nothing is granted or outstanding (`idle`).  Only the
// processor's own reset puts them into reset at once, because it resets the
// bridge with them.
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
    output var logic live         // the port is open and out of reset
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

  assign hold = hps_rst || !opened || pending;

  // Registered, so that the reset the adapter and the share see is a
  // register's output and no longer a function of three synchronizers.
  //
  // **AND BOTH HAVE THE SAFE VALUE AT THE FABRIC'S RESET**, which is also the
  // value they power up at, the board being built with no power-up don't
  // care: the port in reset, and the handshake NOT acknowledged.  An
  // acknowledgment is the fabric saying it has gone quiet, and a register
  // that says so before it has run is a fabric answering for a machine it
  // has not seen.
  always_ff @(posedge clk) begin
    if (rst) begin
      port_rst <= 1'b1;
      ack_n    <= 1'b1;
    end else begin
      port_rst <= hps_rst || (hold && idle);
      ack_n    <= !(pending && port_rst);
    end
  end

  assign live = !port_rst;

endmodule

`default_nettype wire
