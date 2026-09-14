// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The memory port across two clocks: the machine's tick on one side, the
// memory controller's user clock on the other.
//
// WHY THERE ARE TWO CLOCKS AT ALL, AND WHY NEITHER MAY MOVE.  The machine's
// tick is 10 ns and every instant in `rtl/machine/` is a count of them, so the
// machine's clock is not negotiable.  The Memory Interface Generator's user
// clock is the DDR3L clock divided by the PHY ratio --- 325 MHz over four, so
// 81.25 MHz, a 12.3077 ns tick --- and that is not negotiable either: it
// belongs to the memory part's own timing.  Both are made from this board's
// one 100 MHz oscillator, but through two different clock managers, so their
// edges have no fixed relationship and the design must treat them as
// unrelated.  On the Arty Z7-20 this module has no counterpart because
// `S_AXI_HP0` is clocked by the fabric: the machine's own clock goes into the
// processing system's port and there is nothing to cross.
//
// WHY THE CROSSING IS CHEAP HERE, WHICH IS THE REASON IT IS AT THIS SEAM.
// `mem_*` is already a four-phase handshake and already one transaction at a
// time: `mem_req` is a LEVEL held up until `mem_done`, and `mem_done` stands
// until `mem_req` falls.  So the crossing is two levels through two
// synchronisers each, and the payload never needs one --- it is stable for
// two clocks of the far side before the level that announces it arrives, and
// stable again for two clocks before the level that announces the answer goes
// back.  That is the standard argument and it is made good by construction
// below rather than assumed:
//
//   * the request payload is REGISTERED ON THIS SIDE at the rise of
//     `a_mem_req`, and `req` does not go out until the cycle after, so the
//     payload has been standing still for at least one A clock plus the two B
//     clocks of the synchroniser before anything on the B side looks at it;
//   * the answer is REGISTERED ON THE FAR SIDE when `b_mem_done` rises, and
//     `ack` does not go back until the cycle after, by the same argument.
//
// `boards/arty-a7-100/cadr_a7_ddr.xdc` is where that argument is told to the
// fitter, as a maximum delay on the payload and a clock grouping on the two
// domains.  **A crossing whose reasoning is only in a comment is a crossing
// the fitter will happily route through a swamp**, and this project already
// records what an exception that reaches nothing looks like.
//
// WHAT IT COSTS.  About two clocks each way plus the far side's own latency:
// six to eight of the machine's ticks on top of the memory's own. The bus
// allows 4,250 ns before it calls a cycle a non-existent memory, and a DDR3
// read here is around 150 ns all told, so the margin is a factor of twenty.
// Nothing in `rtl/machine/` measures the memory's answer, by design ---
// `cadr_xbus_ddr`'s header has the argument, and muir's own model answers in
// `device_ns` of its own.

`default_nettype none

module cadr_mem_cross (
    // ---------------------------------------------------------- the machine
    input  var logic        a_clk,
    input  var logic        a_rst,
    input  var logic        a_mem_req,     // a level, held until a_mem_done
    input  var logic        a_mem_write,
    input  var logic [31:0] a_mem_addr,
    input  var logic [31:0] a_mem_wdata,
    output var logic        a_mem_done,
    output var logic [31:0] a_mem_rdata,
    output var logic        a_mem_error,

    // ----------------------------------------------------------- the memory
    input  var logic        b_clk,
    input  var logic        b_rst,
    output var logic        b_mem_req,
    output var logic        b_mem_write,
    output var logic [31:0] b_mem_addr,
    output var logic [31:0] b_mem_wdata,
    input  var logic        b_mem_done,
    input  var logic [31:0] b_mem_rdata,
    input  var logic        b_mem_error
);

  // -------------------------------------------------------- the A side
  //
  // The payload, held still while the request is out, and the level that says
  // it is there.  `req_a` rises one clock after the payload registers, which
  // is what gives the B side something that has already stopped moving.
  logic        req_a;
  logic        write_q;
  logic [31:0] addr_q, wdata_q;

  // The far side's answer, synchronised back.
  logic [1:0]  ack_sync;
  logic        ack_a;
  assign ack_a = ack_sync[1];

  always_ff @(posedge a_clk) begin
    if (a_rst) begin
      req_a    <= 1'b0;
      write_q  <= 1'b0;
      addr_q   <= 32'd0;
      wdata_q  <= 32'd0;
      ack_sync <= 2'b00;
    end else begin
      ack_sync <= {ack_sync[0], ack_b};
      if (!req_a && !ack_a) begin
        // Not asking, and the last answer has been taken back.  **BOTH TERMS
        // ARE NEEDED AND THE SECOND IS THE ONE THAT IS EASY TO LEAVE OUT.**
        // This is a four-phase handshake: the far side does not drop its
        // acknowledgement until it has seen the request go, and the
        // acknowledgement then takes two more clocks to come back here.  A
        // new request raised inside that window would find `ack_a` still
        // standing from the last one and would be answered before it had been
        // asked.
        //
        // Take the payload and ask on the next clock, so that the payload is
        // older than the level that points at it.
        write_q <= a_mem_write;
        addr_q  <= a_mem_addr;
        wdata_q <= a_mem_wdata;
        req_a   <= a_mem_req;
      end else if (!a_mem_req) begin
        // The requester has let go.  The handshake's fourth phase: drop the
        // level and wait for the far side to drop its acknowledgement.
        req_a <= 1'b0;
      end
    end
  end

  // `a_mem_done` is the far side's acknowledgement and nothing else.  It is
  // not gated on `a_mem_req`: the requester holds that up until it has taken
  // the word, which is what `cadr_xbus_ddr` does, and gating would make a
  // glitch on the request a lost answer.
  assign a_mem_done = ack_a && req_a;

  // -------------------------------------------------------- the B side
  logic [1:0] req_sync;
  logic       req_b;
  assign req_b = req_sync[1];

  logic        ack_b;
  logic [31:0] rdata_b;
  logic        error_b;
  logic        running;

  always_ff @(posedge b_clk) begin
    if (b_rst) begin
      req_sync <= 2'b00;
      ack_b    <= 1'b0;
      rdata_b  <= 32'd0;
      error_b  <= 1'b0;
      running  <= 1'b0;
    end else begin
      req_sync <= {req_sync[0], req_a};
      if (!req_b) begin
        // The request has gone: let the acknowledgement go with it.
        ack_b   <= 1'b0;
        running <= 1'b0;
      end else if (!ack_b) begin
        running <= 1'b1;
        if (running && b_mem_done) begin
          // Register the answer first and raise the level after it, so what
          // crosses back is older than the level that points at it.
          rdata_b <= b_mem_rdata;
          error_b <= b_mem_error;
          ack_b   <= 1'b1;
        end
      end
    end
  end

  // The far side is asked for exactly as long as the near side is asking and
  // has not been answered.  Dropping it at the acknowledgement is what makes
  // the far end's own `DONE` state let go.
  assign b_mem_req   = req_b && !ack_b;
  assign b_mem_write = write_q;
  assign b_mem_addr  = addr_q;
  assign b_mem_wdata = wdata_q;

  assign a_mem_rdata = rdata_b;
  assign a_mem_error = error_b;

endmodule

`default_nettype wire
