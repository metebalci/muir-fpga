// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The processor's Xbus memory cycle, as the bus interface runs it.
//
// This is the memory path of muir's `busint::Busint`, ported: the part that
// turns `-MEMRQ` from the cpu into a cycle on the Xbus and `-MEMACK` back.
// `cadr1/xspec.text.3` specifies the bus and `cadr/busint.erface` the cpu's
// side of it; `busint.rs` reads both and this follows it.
//
//   1. the cpu drops `-MEMRQ`, with `WRCYC` and the address already up;
//   2. "the bus interface only looks at it towards the end of the cycle" ---
//      the priority logic samples `-MEMRQ` at the master clock edge, which is
//      the microcycle boundary, and grants.  `-MEMGRANT` goes low;
//   3. `-XBUS.RQ` follows SETUP_T after the grant: "it is the responsibility
//      of the bus master to assert good address, write, and data lines 80 ns.
//      prior to asserting -XBUS.RQ";
//   4. the slave gives or takes the word when it answers.  A write is
//      acknowledged at once; a read is deskewed by DESKEW_T, the 60 ns tap of
//      the TD100 at REQLM 0C09, which is what puts the word in `MD`;
//   5. `-MEMACK` stays low until the cpu lifts `-MEMRQ` --- "the responding
//      device then asserts -XBUS.ACK, which remains asserted until the
//      -XBUS.RQ signal is removed by the master".
//
// Where this parts from the model, and it is not a simplification: `busint.rs`
// works out when the device will answer at the moment of the grant, because it
// can.  Hardware cannot see the future, so the request goes out and `dev_ack`
// comes back when it comes back.  The two agree tick for tick.
//
// The device is whatever is on the Xbus at that address.  On this board main
// memory is the DDR bridge, which is `Responder::Device`-shaped rather than
// `Responder::Memory`-shaped: muir's `MemoryBoard` models a board of 4116s
// refreshing itself, and PS DDR3 answers in its own time and refreshes on its
// own account.
//
// NOT HERE YET: the NXM timeout, the Unibus path and its arbitration, the
// interface's own registers, and the debug cable.  Each is its own slice.

`default_nettype none

module cadr_busint_xbus (
    input  var logic clk,          // 200 MHz, one tick = 5 ns
    input  var logic rst,          // synchronous, active high

    // MCLK7 across the cables, one tick wide: the microcycle boundary, which
    // is the only place the priority logic looks at -MEMRQ.
    input  var logic mclk,

    // The cpu's side, on the cables.
    input  var logic n_memrq,      // -MEMRQ, a level while it wants a cycle
    input  var logic wrcyc,        // WRCYC, high to write
    output var logic n_memgrant,   // -MEMGRANT, low when the processor has the bus
    output var logic n_memack,     // -MEMACK
    output var logic n_loadmd,     // -LOADMD, which strobes MD

    // The Xbus slave.
    output var logic dev_rq,       // -XBUS.RQ, as a positive level
    output var logic dev_write,
    input  var logic dev_ack       // the slave has given or taken the word
);

  // "it is the responsibility of the bus master to assert good address, write,
  // and data lines 80 ns. prior to asserting -XBUS.RQ" --- busint::SETUP_NS.
  localparam int unsigned SETUP_T = 80 / 5;

  // The board's own deskew on a read: the 74S64 at REQLM 0C11 makes XACK from
  // XBUS ACK IN at once for a write and through the 60 ns tap of the TD100 at
  // 0C09 for a read --- busint::XBUS_ACK_NS.
  localparam int unsigned DESKEW_T = 60 / 5;

  typedef enum logic [1:0] {
    IDLE,       // no cycle; -MEMRQ is high
    REQUESTED,  // -MEMRQ is low and the priority logic has not sampled it yet
    GRANTED,    // the processor has the bus and the cycle is running
    ACKED       // -MEMACK is up and the word is on the bus
  } state_e;

  state_e     state;
  logic       write;            // WRCYC latched for the cycle being run
  logic [9:0] elapsed;          // ticks since the grant
  logic       answered;         // the slave has answered; the deskew is running
  logic [9:0] answered_at;      // `elapsed` when it did

  // SETUP_T after the grant the request goes out, and it stays out until the
  // cpu lifts -MEMRQ, which lifts -XBUS.RQ with it.
  assign dev_rq    = (state == GRANTED && elapsed >= 10'(SETUP_T)) || state == ACKED;
  assign dev_write = write;

  // The slave is giving or taking the word this very tick.
  logic answering;
  assign answering = (state == GRANTED) && dev_rq && dev_ack;

  // XACK is made from XBUS ACK IN by the 74S64 at REQLM 0C11: at once for a
  // write, and through the 60 ns tap of the TD100 at 0C09 for a read. So the
  // write path is a gate and is combinational in `dev_ack`, and only the read
  // path waits. Registering the write path would put -MEMACK a tick late.
  logic deskewed;
  assign deskewed = answered && (elapsed >= answered_at + 10'(DESKEW_T));

  logic acked;
  assign acked = (state == ACKED)
              || (state == GRANTED && ((write && answering) || deskewed));

  assign n_memgrant = !(state == GRANTED || state == ACKED);
  assign n_memack   = !acked;
  // On the Xbus the word lands with the acknowledgement, which the deskew has
  // already accounted for, so -LOADMD and -MEMACK coincide. They do not on the
  // Unibus, where the word comes UNIBUS_STROBE_NS after -UB SSYN and so
  // *before* the acknowledgement, which is why this is a port of its own.
  assign n_loadmd   = !acked;

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= IDLE;
      write       <= 1'b0;
      elapsed     <= 10'd0;
      answered    <= 1'b0;
      answered_at <= 10'd0;
    end else begin
      unique case (state)
        // A request standing at the master clock edge is sampled at that
        // edge, however long it has been up: the priority logic registers
        // -MEMRQ and does not care when it fell. So a request that arrives on
        // the edge itself is granted there, and does not wait a microcycle
        // for the next. (The board has a setup window and the model has none;
        // in practice -MEMRQ "starts in the middle of a cycle" and is looked
        // at "towards the end", so the two never meet.)
        IDLE: begin
          if (!n_memrq) begin
            write <= wrcyc;
            if (mclk) begin
              state       <= GRANTED;
              elapsed     <= 10'd0;
              answered    <= 1'b0;
              answered_at <= 10'd0;
            end else begin
              state <= REQUESTED;
            end
          end
        end

        // The grant. -MEMRQ is sampled here and nowhere else --- "the bus
        // interface only looks at it towards the end of the cycle" --- so a
        // request made just after an edge waits a whole microcycle.
        REQUESTED: begin
          if (mclk) begin
            state       <= GRANTED;
            elapsed     <= 10'd0;
            answered    <= 1'b0;
            answered_at <= 10'd0;
          end
        end

        GRANTED: begin
          elapsed <= elapsed + 10'd1;
          if (acked) begin
            state <= ACKED;
          end else if (answering && !answered) begin
            // A read: remember when the slave answered and let the deskew run
            // from there. `elapsed` still holds that tick's value here.
            answered    <= 1'b1;
            answered_at <= elapsed;
          end
        end

        // -XBUS.ACK "remains asserted until the -XBUS.RQ signal is removed by
        // the master", and the cpu removes -MEMRQ MFINISHD_NS after the
        // acknowledgement. That delay is the cpu's, not the interface's.
        ACKED: begin
          if (n_memrq) begin
            state <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
