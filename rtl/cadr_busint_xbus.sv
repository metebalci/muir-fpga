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
// The NXM timeout is here too.  The 74LS124 at REQTIM 0A01 has run since
// power-on and the grant only *opens* its output --- `INT BUSY` rises with the
// grant --- so where the timeout falls depends on the oscillator's phase at
// the grant and not on the grant alone.  The output takes its first fall at the
// oscillator's first fall strictly after the grant (an enable landing exactly
// on one misses it: the sheet's 30 ns says the part cannot pass an edge it has
// not yet seen), and `NXM TIMEOUT` is registered on the sixth rise of the
// output after that --- busint::nxm_timeout_at, which is the first rise plus
// TIMEOUT_NS.
//
// One place this is closer to the board than the model is: `busint.rs` decides
// at the grant whether a cycle will be answered or will time out, because it
// can see which responder is at the address.  The board cannot; the timer runs
// on every cycle and whichever comes first wins.  They agree wherever the model
// is exercised, real devices answering far inside 4.25 us.
//
// NOT HERE YET: the Unibus path and its arbitration, the interface's own
// registers, and the debug cable.  Each is its own slice.

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
    output var logic timed_out,    // NXM TIMEOUT: nothing answered this cycle

    // The Xbus slave.
    output var logic dev_rq,       // -XBUS.RQ, as a positive level
    output var logic dev_write,
    input  var logic dev_ack,      // the slave has given or taken the word

    // The Unibus. `unibus` is the decode's: this address is up there rather
    // than on the Xbus, so the cycle arbitrates for the bus before it runs.
    input  var logic unibus,
    output var logic ub_msyn,      // -UB MSYN, as a positive level
    output var logic ub_write,
    input  var logic ub_ssyn,      // -UB SSYN: a slave has answered
    output var logic [2:0] arb_stage
);

  // "it is the responsibility of the bus master to assert good address, write,
  // and data lines 80 ns. prior to asserting -XBUS.RQ" --- busint::SETUP_NS.
  localparam int unsigned SETUP_T = 80 / 5;

  // The board's own deskew on a read: the 74S64 at REQLM 0C11 makes XACK from
  // XBUS ACK IN at once for a write and through the 60 ns tap of the TD100 at
  // 0C09 for a read --- busint::XBUS_ACK_NS.
  localparam int unsigned DESKEW_T = 60 / 5;

  // The request-timing oscillator at REQTIM 0A01: 850 ns, so 425 ns a half
  // period --- chip::VCO_PERIOD. It free-runs from power-on, high first.
  localparam int unsigned VCO_HALF_T = 425 / 5;

  // `NXM TIMEOUT` on the sixth rise of the gated output: the first rise plus
  // busint::TIMEOUT_NS, which is five whole periods.
  localparam int unsigned NXM_RISES = 6;

  // --- the Unibus, busint::UNIBUS_* ---
  //
  // ARBITRATION IS FIVE STAGES AND ONLY BECAUSE THERE IS ONE MASTER.
  // `Busint::mclk_edge`'s state machine looks large --- stage 7,
  // `debug_holds_bbsy`, `LMUB MASTER` waiting behind somebody else --- and
  // every one of those branches belongs to the *debug cable*, a second master
  // on this Unibus.  This fabric has no debug cable, so what is left is a
  // fixed sequence advancing one stage a master clock: 1, 2, 3 with a 200 ns
  // `SACK` wait, 4, 5, and then the transfer.
  //
  // And it runs *once*.  `LMUB MASTER` is set at stage 3 and is only ever
  // cleared by another master taking the bus, so from the second Unibus cycle
  // on the machine is already the master and starts at stage 4.  Stages 1 to
  // 3 happen once in the life of the machine.
  localparam int unsigned UB_SELECT_T  = 200 / 5;   // -SACK to the grant
  localparam int unsigned UB_ADDRESS_T = 100 / 5;   // the grant to -UB MSYN
  localparam int unsigned UB_ACK_T     = 150 / 5;   // -UB SSYN to -LMACK
  localparam int unsigned UB_STROBE_T  = 100 / 5;   // -UB SSYN to the MD strobe

  typedef enum logic [2:0] {
    IDLE,       // no cycle; -MEMRQ is high
    REQUESTED,  // -MEMRQ is low and the priority logic has not sampled it yet
    ARB,        // arbitrating for the Unibus
    UB,         // the Unibus transfer is running
    GRANTED,    // the processor has the bus and the cycle is running
    ACKED       // -MEMACK is up and the word is on the bus
  } state_e;

  // The oscillator, free-running from reset and independent of any cycle.
  logic [6:0] vco_count;
  logic       vco;
  logic       vco_toggle;
  assign vco_toggle = (vco_count == 7'(VCO_HALF_T - 1));

  logic       nxm;        // this cycle was ended by the timer, not a slave
  logic       tmr_fell;   // the gated output has taken its first fall
  logic [2:0] tmr_rises;  // rises of the gated output since then

  state_e     state;
  logic [2:0] stage;
  assign arb_stage = 3'(state);            // where the arbitration has got to
  logic [8:0] arb_t;            // ticks since -SACK went out
  logic       ub_master;        // LMUB MASTER: this machine has the Unibus
  logic       ssyn_seen;
  logic [9:0] ssyn_at;
  logic       write;            // WRCYC latched for the cycle being run
  logic [9:0] elapsed;          // ticks since the grant
  logic       answered;         // the slave has answered; the deskew is running
  logic [9:0] answered_at;      // `elapsed` when it did

  // SETUP_T after the grant the request goes out, and it stays out until the
  // cpu lifts -MEMRQ, which lifts -XBUS.RQ with it.
  assign dev_rq    = (state == GRANTED && elapsed >= 10'(SETUP_T)) || state == ACKED;
  assign dev_write = write;

  // The Unibus master's own strobe, UNIBUS_ADDRESS_NS after the grant.
  assign ub_msyn  = (state == UB && elapsed >= 10'(UB_ADDRESS_T));
  assign ub_write = write;

  // "MSYN OUT drops at SSYN T100 and -LOADMD rises with it, so the word lands
  // 50 ns *before* the acknowledgement, where an Xbus word lands with it."
  logic ub_acked, ub_loadmd;
  assign ub_acked  = ssyn_seen && (elapsed >= ssyn_at + 10'(UB_ACK_T));
  assign ub_loadmd = ssyn_seen && (elapsed >= ssyn_at + 10'(UB_STROBE_T));

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
              || (state == GRANTED && ((write && answering) || deskewed))
              || (state == UB && ub_acked);

  assign n_memgrant = !(state == GRANTED || state == UB || state == ACKED);
  assign n_memack   = !acked;
  // On the Xbus the word lands with the acknowledgement, which the deskew has
  // already accounted for, so -LOADMD and -MEMACK coincide. They do not on the
  // Unibus, where the word comes UNIBUS_STROBE_NS after -UB SSYN and so
  // *before* the acknowledgement, which is why this is a port of its own.
  assign n_loadmd   = !(acked || (state == UB && ub_loadmd));
  // The flag belongs to the cycle standing, as `Ack::timed_out` does: it goes
  // when the cpu lifts -MEMRQ and the cycle is over. What outlives the cycle is
  // the NXM bit in the bus error register at REQERR, which is not this slice.
  assign timed_out  = (state == ACKED) && nxm;

  always_ff @(posedge clk) begin
    // The oscillator runs whatever the cycle is doing, and reset only sets its
    // phase: on the board it has been running since the power came up.
    if (rst) begin
      vco_count <= 7'd0;
      vco       <= 1'b1;
    end else if (vco_toggle) begin
      vco_count <= 7'd0;
      vco       <= !vco;
    end else begin
      vco_count <= vco_count + 7'd1;
    end

    if (rst) begin
      state       <= IDLE;
      stage       <= 3'd0;
      arb_t       <= 9'd0;
      ub_master   <= 1'b0;
      ssyn_seen   <= 1'b0;
      ssyn_at     <= 10'd0;
      write       <= 1'b0;
      elapsed     <= 10'd0;
      answered    <= 1'b0;
      answered_at <= 10'd0;
      tmr_fell    <= 1'b0;
      tmr_rises   <= 3'd0;
      nxm         <= 1'b0;
    end else begin
      // The gated output, while a cycle is granted. Its first fall is the
      // oscillator's first fall *strictly after* the grant, so a grant landing
      // on one misses it --- which falls out of the ordering here, the grant's
      // own clear of `tmr_fell` below coming after this.
      if (arb_t != 9'h1FF) arb_t <= arb_t + 9'd1;

      if (state == GRANTED || state == UB) begin
        if (vco_toggle) begin
          if (!tmr_fell && vco) begin
            tmr_fell <= 1'b1;
          end else if (tmr_fell && !vco) begin
            tmr_rises <= tmr_rises + 3'd1;
            if (tmr_rises + 3'd1 == 3'(NXM_RISES)) begin
              state <= ACKED;
              nxm   <= 1'b1;
            end
          end
        end
      end

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
              elapsed     <= 10'd0;
              answered    <= 1'b0;
              answered_at <= 10'd0;
              ssyn_seen   <= 1'b0;
              ssyn_at     <= 10'd0;
              tmr_fell    <= 1'b0;
              tmr_rises   <= 3'd0;
              nxm         <= 1'b0;
              if (unibus) begin
                state <= ARB;
                stage <= ub_master ? 3'd4 : 3'd1;
              end else begin
                state <= GRANTED;
              end
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
            elapsed     <= 10'd0;
            answered    <= 1'b0;
            answered_at <= 10'd0;
            ssyn_seen   <= 1'b0;
            ssyn_at     <= 10'd0;
            tmr_fell    <= 1'b0;
            tmr_rises   <= 3'd0;
            nxm         <= 1'b0;
            if (unibus) begin
              state <= ARB;
              stage <= ub_master ? 3'd4 : 3'd1;
            end else begin
              state <= GRANTED;
            end
          end
        end

        // One stage a master clock, as `Busint::mclk_edge` advances them.
        ARB: begin
          if (mclk) begin
            unique case (stage)
              3'd1: stage <= 3'd2;
              // The priority PROM grants, and -SACK goes out: the wait is
              // UNIBUS_SELECT_NS from here, and stage 3 is where it is spent.
              3'd2: begin
                stage <= 3'd3;
                arb_t <= 9'd0;
              end
              // "SACKD withdraws the grant" --- strictly after, so a master
              // clock landing exactly on the wait does not take it.
              3'd3: if (arb_t > 9'(UB_SELECT_T)) begin
                stage     <= 3'd4;
                ub_master <= 1'b1;
              end
              3'd4: stage <= 3'd5;
              default: begin
                state   <= UB;
                elapsed <= 10'd0;
              end
            endcase
          end
        end

        // -UB MSYN is out and a slave will answer with -UB SSYN, or nothing
        // will and the timer above ends it.
        UB: begin
          if (elapsed != 10'h3FF) elapsed <= elapsed + 10'd1;
          if (acked) begin
            state <= ACKED;
          end else if (ub_msyn && ub_ssyn && !ssyn_seen) begin
            ssyn_seen <= 1'b1;
            ssyn_at   <= elapsed;
          end
        end

        GRANTED: begin
          // Saturating, not wrapping. `elapsed` gates -XBUS.RQ through
          // SETUP_T and the read deskew through `answered_at`, and both are
          // "has this long passed" rather than "how long": once past, past.
          // Wrapping made -XBUS.RQ fall for sixteen ticks in the middle of
          // any cycle that reached 1,024 of them, which on the board is a
          // level and cannot. Only a cycle nothing answers runs that long ---
          // the NXM timer ends it at about 935 ticks plus the oscillator's
          // phase --- so no slave was ever listening when it happened, which
          // is why every output agreed and nothing caught it.
          if (elapsed != 10'h3FF) elapsed <= elapsed + 10'd1;
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
