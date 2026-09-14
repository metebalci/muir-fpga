// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system's load-store seam across two clocks: the core's
// own clock on one side, the machine's tick on the other.
//
// WHY THERE ARE TWO CLOCKS AT ALL, AND WHY NEITHER MAY MOVE.  The machine's
// tick is 10 ns and every instant in `rtl/machine/` is a count of them, so the
// machine's clock is not negotiable.  Ibex computes a load or a store's
// address in the cycle it uses it --- the decoder, the operand multiplexers
// and the main ALU's adder between the instruction register and the memory's
// address pin --- and on an `xc7a100tcsg324-1` that arc is about 12.9 ns of
// logic and routing.  At the machine's tick it misses by three, and it is not
// a path a constraint may relax: it is one cycle of a processor and it is
// meant to be.  So the soft system runs slower than the machine and the seam
// between them is a clock domain crossing.
//
// WHY THE CROSSING IS AT THIS SEAM AND NOT AT THE AXI PORTS.  The bridge
// `rtl/plumbing/cadr_soc_axi.sv` speaks to four faces over five AXI channels,
// which is some hundred and forty wires and ten handshakes; this seam is one
// request and one answer.  So the bridge is put on the MACHINE's clock, where
// the faces already are, and what crosses is this: a request with its payload
// going out, an answer coming back.  Nothing in `rtl/plumbing/` or
// `rtl/machine/` changed for it, and the faces do not know there are two
// clocks at all.
//
// THE SHAPE IS `rtl/plumbing/cadr_mem_cross.sv`'s, deliberately: that file
// carries the machine's memory port to the memory controller's user clock,
// and this carries the core's data port to the machine's.  A four-phase
// handshake, a payload that has stopped moving before the level that points
// at it, and two flip-flops on each level.  The argument is the same one and
// is made good by construction rather than assumed:
//
//   * the payload is REGISTERED ON THE ASKING SIDE at the edge that raises
//     the request, and the far side does not look at it until the request has
//     come through two of its own flip-flops --- so the payload has been
//     standing still for a full period of the far side's clock, plus the
//     resolution time of the first flop, before anything reads it;
//   * the answer is REGISTERED ON THE ANSWERING SIDE at the edge that raises
//     the acknowledgement, and comes back by the same argument.
//
// `rtl/plumbing/xilinx7/cadr_soc.xdc` is where that argument is told to the
// fitter, as a maximum delay on everything that crosses and NOT as a clock
// group --- a grouped path is not timed at all, and a payload that is not
// timed at all is a payload the fitter may route through a swamp.  **A
// crossing whose reasoning is only in a comment is a crossing the fitter will
// happily route through a swamp**, which is `cadr_a7_ddr.xdc`'s own sentence
// one seam along.
//
// **THE ANSWER IS NOT HANDED BACK UNTIL THE HANDSHAKE HAS CLOSED, AND THAT IS
// THE ONE THING THIS DOES THAT `cadr_mem_cross` DOES NOT HAVE TO.**  A
// four-phase handshake is not finished when the acknowledgement arrives: the
// request has still to be dropped, the far side has still to see it go and
// drop its acknowledgement, and that has still to come back.  The requester in
// front of this one --- `rtl/plumbing/cadr_soc.sv`'s data seam --- clears its
// own busy flag the instant it is answered and may offer the next request one
// clock later, which is INSIDE that window.  So the answer is held until the
// fourth phase is over: at the edge `a_done` rises this module is idle again,
// and a requester that asks on the very next clock is taken.  `cadr_mem_cross`
// escapes the question because `cadr_xbus_ddr` holds its request up until it
// has taken the word, so the fourth phase runs while the machine is still
// asking.  The cost is four of the core's clocks on an access that already
// takes a dozen, on a firmware that polls.
//
// WHAT IT COSTS.  About two clocks each way on the request, two each way on
// the answer, and the drain: some ten of the core's clocks on top of the
// bridge's own dozen.  A register face read from this firmware is therefore
// about a fifth of a microsecond, and what reads them is a program polling a
// status bit.

`default_nettype none

module cadr_soc_cross (
    // ------------------------------------------------- the core's own clock
    //
    // `a_req` is a PULSE, one clock, offered only when this module is idle ---
    // which `cadr_soc.sv`'s data seam guarantees, because it holds its own
    // busy flag from the grant until `a_done`.  `a_done` is a pulse too, and
    // `a_rdata`/`a_err` stand with it and after it.
    input  var logic        a_clk,
    input  var logic        a_rst,
    input  var logic        a_req,
    input  var logic        a_we,
    input  var logic [3:0]  a_be,
    input  var logic [31:0] a_addr,
    input  var logic [31:0] a_wdata,
    output var logic        a_done,
    output var logic [31:0] a_rdata,
    output var logic        a_err,

    // --------------------------------------------------- the machine's tick
    //
    // The bridge's own seam, unchanged: `b_req` stands until `b_gnt`, and
    // `b_done` is one clock and carries the answer.
    input  var logic        b_clk,
    input  var logic        b_rst,
    output var logic        b_req,
    output var logic        b_we,
    output var logic [3:0]  b_be,
    output var logic [31:0] b_addr,
    output var logic [31:0] b_wdata,
    input  var logic        b_gnt,
    input  var logic        b_done,
    input  var logic [31:0] b_rdata,
    input  var logic        b_err
);

  // ------------------------------------------------------------ the A side

  typedef enum logic [1:0] {
      A_IDLE,   // nothing out; a request may be taken
      A_ASK,    // the request is out, waiting for the acknowledgement
      A_DRAIN   // the request is withdrawn, waiting for the acknowledgement
                // to go with it --- the handshake's fourth phase
  } a_state_e;

  a_state_e    st_a;
  logic        req_a;
  logic        we_q;
  logic [3:0]  be_q;
  logic [31:0] addr_q, wdata_q;

  // The far side's acknowledgement, synchronised back.  Two flip-flops: the
  // first may go metastable and the second is what anything reads.
  logic [1:0] ack_sync;
  logic       ack_a;
  assign ack_a = ack_sync[1];

  logic        ack_b;
  logic [31:0] rdata_b;
  logic        err_b;

  always_ff @(posedge a_clk) begin
    if (a_rst) begin
      st_a     <= A_IDLE;
      req_a    <= 1'b0;
      we_q     <= 1'b0;
      be_q     <= 4'd0;
      addr_q   <= 32'd0;
      wdata_q  <= 32'd0;
      ack_sync <= 2'b00;
      a_done   <= 1'b0;
      a_rdata  <= 32'd0;
      a_err    <= 1'b0;
    end else begin
      ack_sync <= {ack_sync[0], ack_b};
      a_done   <= 1'b0;
      case (st_a)
        A_IDLE: begin
          if (a_req) begin
            // **THE PAYLOAD IS TAKEN HERE AND NOWHERE ELSE.**  `a_addr` is
            // the core's live load-store address and is not guaranteed to
            // stand after the grant --- `cadr_soc.sv` says so at its own
            // multiplexer --- so a far side reading it through the crossing
            // would read whatever the core had moved on to, at a moment two
            // of its clocks later.  Registering it is also what makes the
            // maximum delay in the constraints file mean anything: it bounds
            // the route from THESE registers, which have stopped moving.
            we_q    <= a_we;
            be_q    <= a_be;
            addr_q  <= a_addr;
            wdata_q <= a_wdata;
            req_a   <= 1'b1;
            st_a    <= A_ASK;
          end
        end

        A_ASK: begin
          if (ack_a) begin
            // The answer was registered on the far side at the same edge
            // that raised the acknowledgement, and the acknowledgement has
            // come through two of this side's flip-flops since --- so it has
            // been standing still for a full period of this clock, plus the
            // first flop's resolution time, before anything here reads it.
            a_rdata <= rdata_b;
            a_err   <= err_b;
            req_a   <= 1'b0;
            st_a    <= A_DRAIN;
          end
        end

        default: begin  // A_DRAIN
          // **THE FOURTH PHASE, AND ANSWERING BEFORE IT IS OVER IS A
          // CORRECTNESS BUG AND NOT A LATENCY ONE.**  The far side does not
          // drop its acknowledgement until it has seen the request go, and
          // that then takes two more clocks to come back here.  A requester
          // told it was answered inside that window would raise the next
          // request while `ack_a` still stood from the last one, and this
          // side would hand it the previous answer at once.
          //
          // **AND THE CHECK CANNOT SEE IT, WHICH IS MEASURED AND NOT
          // ASSUMED.**  Delete this wait and `build/soc.pass` stays green at
          // every ratio, because `cadr_soc.sv` takes one clock to clear its
          // own busy flag and that is one clock more than the window needs.
          // How much more was measured by instrumenting the mutant: of 273
          // requests, **129 arrive while the acknowledgement still stands at
          // the SECOND flip-flop of the synchroniser and NONE while it stands
          // at the first**.  One clock.  `mutations/list.txt` records that
          // beside the crossing's records rather than filing a hole, so that
          // a reader who deletes this finds the measurement and not a green
          // run.
          if (!ack_a) begin
            a_done <= 1'b1;
            st_a   <= A_IDLE;
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------ the B side

  logic [1:0] req_sync;
  logic       req_b;
  assign req_b = req_sync[1];

  // Whether the bridge has taken this request.  The bridge's `gnt` is
  // `(st == IDLE) && req`, so a request left standing after the grant would be
  // taken a SECOND time the moment the bridge came back to idle --- one of the
  // core's loads becoming two AXI transactions at a face whose registers may
  // have side effects.
  logic taken;

  always_ff @(posedge b_clk) begin
    if (b_rst) begin
      req_sync <= 2'b00;
      ack_b    <= 1'b0;
      taken    <= 1'b0;
      rdata_b  <= 32'd0;
      err_b    <= 1'b0;
    end else begin
      req_sync <= {req_sync[0], req_a};
      if (!req_b) begin
        // The request has gone: let the acknowledgement go with it, which is
        // what lets the asking side out of its drain.
        ack_b <= 1'b0;
        taken <= 1'b0;
      end else if (!ack_b) begin
        if (b_req && b_gnt) taken <= 1'b1;
        if (taken && b_done) begin
          // Register the answer and raise the level that points at it at the
          // same edge.  The level then takes two of the asking side's
          // flip-flops to arrive, which is what gives the answer a full
          // period of that clock to have stopped moving in.
          rdata_b <= b_rdata;
          err_b   <= b_err;
          ack_b   <= 1'b1;
        end
      end
    end
  end

  assign b_req   = req_b && !taken && !ack_b;
  assign b_we    = we_q;
  assign b_be    = be_q;
  assign b_addr  = addr_q;
  assign b_wdata = wdata_q;

endmodule

`default_nettype wire
