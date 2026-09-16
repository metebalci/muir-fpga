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
// **THE REQTIM PROM HAS TWO TABLES AND BOTH ARE HERE.**  The counter above is
// the first, `busint::TIMEOUT_NS`, five whole periods after the gated output's
// first rise.  `select_debug` picks the second: `DEBUG REQUEST ACTIVE` ---
// `SELECT DEBUG` registered in the 74LS273 at REQTIM 0B01 --- raises
// `NXM TIMEOUT` at count 13 instead of count 5, which is
// `busint::DEBUG_TIMEOUT_NS` and is how long the debugger's own interface
// waits for the other machine before it gives up.  It is the SAME oscillator
// and the SAME counter, so a debug cycle's timeout depends on the phase at
// the grant exactly as any other cycle's does, and `rtl/machine/
// cadr_busint_regs.sv`'s DBGOUT page is what asserts the line.  Without it a
// debug cycle would end at 4.25 us, inside the window the far end is still
// allowed to answer in.
//
// NOT HERE YET: MIT's own Unibus arbitration for the DEBUG master --- `NPR`,
// `NPG1 IN`, `SACK` and `-UB BBSY`, the branches named above --- and the
// timeout inhibit that cable's modifier register carries, which wants a trace
// with a cable in it.
// `rtl/machine/cadr_dbgin.sv` says what this fabric puts in their place.  The
// Unibus path is here; the interface's own registers are
// `rtl/machine/cadr_busint_regs.sv`; the cable's end is `cadr_dbgin.sv`.

`default_nettype none

module cadr_busint_xbus (
    input  var logic clk,          // 100 MHz, one tick = 10 ns
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

    // `-FREE`, inverted: this interface has a cycle in flight.  It is
    // `Busint::busy`, which is `self.state != State::Idle` and nothing else,
    // and `Machine::debug_status` takes it for bit 6 of the byte the 8304 at
    // REQERR 0B15 puts on the debug cable --- `error_status::NOT_FREE`, the
    // wire that part's pin 7 carries.  On MIT's board `-FREE` arrives at
    // REQERR from the request logic rather than being a flop of that page's
    // own, which is why it leaves here and is joined to the error status
    // register's other seven bits in `rtl/machine/cadr_memory_path.sv`.
    //
    // A read of `0o766044` by the PROCESSOR always finds this up, the
    // interface being busy with that very read, which is why
    // `Machine::interface_read` writes the bit as a constant and
    // `cadr_busint_regs.sv` does the same.  The debugger's strobe is not a
    // cycle of this interface's at all, so it finds the bit as it stands.
    output var logic busy,

    // The Xbus slave.
    output var logic dev_rq,       // -XBUS.RQ, as a positive level
    output var logic dev_write,
    input  var logic dev_ack,      // the slave has given or taken the word

    // The Unibus. `unibus` is the decode's: this address is up there rather
    // than on the Xbus, so the cycle arbitrates for the bus before it runs.
    input  var logic unibus,
    // `SELECT DEBUG`: this cycle is the processor's own into the debug block,
    // so the timeout counter takes the REQTIM PROM's second table.  See the
    // header.  `rtl/machine/cadr_busint_regs.sv` makes it and
    // `rtl/machine/cadr_memory_path.sv` joins the two, as it joins `-FREE`.
    input  var logic select_debug,
    output var logic ub_msyn,      // -UB MSYN, as a positive level
    output var logic ub_write,
    input  var logic ub_ssyn,      // -UB SSYN: a slave has answered
    output var logic [2:0] arb_stage
);

  // "it is the responsibility of the bus master to assert good address, write,
  // and data lines 80 ns. prior to asserting -XBUS.RQ" --- busint::SETUP_NS.
  localparam int unsigned SETUP_T = cadr_tick_pkg::ticks(80);

  // The board's own deskew on a read: the 74S64 at REQLM 0C11 makes XACK from
  // XBUS ACK IN at once for a write and through the 60 ns tap of the TD100 at
  // 0C09 for a read --- busint::XBUS_ACK_NS.
  localparam int unsigned DESKEW_T = cadr_tick_pkg::ticks(60);

  // The request-timing oscillator at REQTIM 0A01: 850 ns, so 425 ns a half
  // period --- chip::VCO_PERIOD. It free-runs from power-on, high first.
  //
  // **THE PERIOD STAYS IN NANOSECONDS AND IS NOT A COUNT OF TICKS**, which
  // is what every other constant in this file is.  Everything else here is a
  // delay from an event, so rounding it to the grid moves one instant by
  // less than a tick and nothing accumulates.  This is an oscillator: the
  // grant only OPENS its output, it does not start it, so what the NXM timer
  // measures is the phase this counter happens to be at when a cycle is
  // granted.  Round the half period and that phase drifts further every
  // period, and the acknowledgment instant drifts with it.  The accumulator
  // below keeps the true period at any grid.  See `docs/timing.md`.
  localparam int unsigned VCO_HALF_NS = 425;

  // `NXM TIMEOUT` on the sixth rise of the gated output: the first rise plus
  // busint::TIMEOUT_NS, which is five whole periods.  The REQTIM PROM's
  // second table, which `DEBUG REQUEST ACTIVE` selects, is thirteen periods
  // and so the fourteenth rise --- busint::DEBUG_TIMEOUT_NS.
  localparam int unsigned NXM_RISES = 6;
  localparam int unsigned DBG_RISES = 14;

  // --- the Unibus, busint::UNIBUS_* ---
  //
  // ARBITRATION IS FIVE STAGES AND ONLY BECAUSE THIS MODULE ARBITRATES FOR
  // ONE MASTER.  `Busint::mclk_edge`'s state machine looks large --- stage 7,
  // `debug_holds_bbsy`, `LMUB MASTER` waiting behind somebody else --- and
  // every one of those branches belongs to the *debug cable*, a second master
  // on this Unibus.  **That cable is built now and this paragraph is not
  // stale:** `rtl/machine/cadr_dbgin.sv` is the debug master and
  // `rtl/machine/cadr_console_bus.sv` is where it and the processor are kept
  // apart, which is a simple arbiter rather than MIT's grant chain, and both
  // files say so at the parting.  What is left here is therefore still a
  // fixed sequence advancing one stage a master clock: 1, 2, 3 with a 200 ns
  // `SACK` wait, 4, 5, and then the transfer.
  //
  // And it runs *once*.  `LMUB MASTER` is set at stage 3 and is only ever
  // cleared by another master taking the bus, so from the second Unibus cycle
  // on the machine is already the master and starts at stage 4.  Stages 1 to
  // 3 happen once in the life of the machine.
  localparam int unsigned UB_SELECT_T  = cadr_tick_pkg::ticks(200);  // -SACK to the grant
  localparam int unsigned UB_ADDRESS_T = cadr_tick_pkg::ticks(100);  // the grant to -UB MSYN
  localparam int unsigned UB_ACK_T     = cadr_tick_pkg::ticks(150);  // -UB SSYN to -LMACK
  localparam int unsigned UB_STROBE_T  = cadr_tick_pkg::ticks(100);  // -UB SSYN to the MD strobe

  typedef enum logic [2:0] {
    IDLE,       // no cycle; -MEMRQ is high
    REQUESTED,  // -MEMRQ is low and the priority logic has not sampled it yet
    ARB,        // arbitrating for the Unibus
    UB,         // the Unibus transfer is running
    GRANTED,    // the processor has the bus and the cycle is running
    ACKED       // -MEMACK is up and the word is on the bus
  } state_e;

  // The oscillator, free-running from reset and independent of any cycle.
  //
  // **AN ACCUMULATOR IN NANOSECONDS, WRAPPED BY SUBTRACTING THE PERIOD AND
  // NEVER BY CLEARING.**  Clearing discards the remainder, and the remainder
  // is the whole of the difference: at a grid that does not divide 425 a
  // cleared counter loses a little every half period and the phase walks
  // away.  Subtracting carries it, so the average period is exact at any
  // grid.  `cadr_io_board.sv`'s sixty-cycle clock and `cadr_serial_line.sv`'s
  // crystal are the same shape.
  //
  // At the 5 ns grid the machine runs at, the remainder is always zero and
  // the toggle falls every 85 ticks --- exactly where the tick counter this
  // replaced put it.  At a 10 ns grid the half period is 42.5 ticks and the
  // accumulator alternates 43 and 42.
  //
  // The condition is `vco_acc >= VCO_HALF_NS - TICK_NS`, which is the same
  // test as `vco_acc + TICK_NS >= VCO_HALF_NS` with the adder off it; the
  // note at `mains_acc` in `cadr_io_board.sv` has that argument at length.
  // After a wrap the accumulator is under one tick, so the tick after a wrap
  // cannot wrap again.
  logic [8:0] vco_acc;     // nanoseconds into the current half period
  logic       vco;
  logic       vco_toggle;
  logic [8:0] vco_next, vco_less;
  assign vco_next   = vco_acc + 9'(cadr_tick_pkg::TICK_NS);
  assign vco_less   = vco_next - 9'(VCO_HALF_NS);
  assign vco_toggle = (vco_acc >= 9'(VCO_HALF_NS - cadr_tick_pkg::TICK_NS));

  logic       nxm;        // this cycle was ended by the timer, not a slave
  logic       tmr_fell;   // the gated output has taken its first fall
  logic [3:0] tmr_rises;  // rises of the gated output since then
  logic [3:0] tmr_want;   // and how many this cycle's table asks for
  assign tmr_want = select_debug ? 4'(DBG_RISES) : 4'(NXM_RISES);

  state_e     state;
  logic [2:0] stage;
  assign arb_stage = 3'(state);            // where the arbitration has got to
  logic [8:0] arb_t;            // ticks since -SACK went out
  logic       ub_master;        // LMUB MASTER: this machine has the Unibus
  logic       ssyn_seen;
  // **THE TWO UNIBUS INSTANTS ARE HELD, NOT ADDED TO A CAPTURED TIME.**  This
  // used to be `ssyn_at`, the value of `elapsed` when -UB SSYN came back, with
  // the two deadlines made as `elapsed >= ssyn_at + UB_*_T` where they are
  // read.  That put a ten-bit adder in front of the comparator on the path
  // that ends at `-MEMACK`, which leaves this module, crosses to the
  // processor and lands on `mfinish_t` and `rdfinish_t` --- counters, so
  // genuinely tick-rate and rightly outside the multicycle exception.  On the
  // board flow, where the machine's clock comes through an MMCM and carries its
  // uncertainty, that cost 198 ps:
  //
  //     busint/ssyn_at_reg[3]/C -> processor/mfinish_t_reg[3]/D
  //
  // Adding once, at the tick SSYN arrives, and comparing against the sum is
  // the same arithmetic with the adder moved off the path --- the move
  // `cadr_phase_gen.sv` makes for its taps, and for the same reason.  Nothing
  // else read `ssyn_at`, so it is gone rather than kept alongside.
  //
  // **AND THEY ARE HELD ONE TICK EARLY**, which is the rest of that move and
  // arrived later: the comparisons that read them are registers now, not
  // gates on the acknowledgment's path.  See the note at `ub_ack_due`.
  logic [9:0] ub_ack_at;      // when -LMACK is due
  logic [9:0] ub_md_at;       // when the MD strobe is due
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
  // 50 ns *before* the acknowledgment, where an Xbus word lands with it."
  //
  // Registers, compared one tick early, for the reason the read deskew below
  // is one: `ub_loadmd` is -LOADMD on a Unibus cycle and lands on the same two
  // clock enables in the processor.  With the deskew held and nothing else
  // changed it was the whole of what was left --- all 35 violated endpoints of
  // the DDR board, at -0.184 ns, every one of them
  //
  //     busint/elapsed_reg[2]_replica/C -> processor/md_reg[*]/CE
  //     4.777 ns over LUT5, CARRY4, CARRY4 and two more LUTs
  //
  // The two instants are held one tick early to pay for it, which is the same
  // subtraction `cadr_phase_gen.sv` makes on its taps and for the same reason:
  // `elapsed >= X` at tick t is `elapsed >= X - 1` at t-1.  The `state == UB`
  // term keeps the last cycle's comparison from standing through the first
  // tick of the next, the register lagging its input by one.
  logic ub_acked, ub_loadmd;
  logic ub_ack_due, ub_md_due;
  assign ub_ack_due = ssyn_seen && (state == UB) && (elapsed >= ub_ack_at);
  assign ub_md_due  = ssyn_seen && (state == UB) && (elapsed >= ub_md_at);

  // The slave is giving or taking the word this very tick.
  logic answering;
  assign answering = (state == GRANTED) && dev_rq && dev_ack;

  // XACK is made from XBUS ACK IN by the 74S64 at REQLM 0C11: at once for a
  // write, and through the 60 ns tap of the TD100 at 0C09 for a read. So the
  // write path is a gate and is combinational in `dev_ack`, and only the read
  // path waits. Registering the write path would put -MEMACK a tick late.
  //
  // **THE READ PATH'S OWN TAP IS A REGISTER, COMPARED ONE TICK EARLY**, which
  // is what `cadr_phase_gen.sv` does for its taps and is here for the same
  // reason.  Written as a comparison read straight into `acked`, the ten-bit
  // magnitude compare against `answered_at + DESKEW_T` stands between the
  // counter and -MEMACK/-LOADMD; those cross to the processor and land on
  // `md`'s and `md_held`'s clock enables, which were sixty of the eighty-six
  // failing endpoints of the DDR board at b5542c5:
  //
  //     -0.263 ns   busint/elapsed_reg[5]/C -> processor/md_reg[23]/CE
  //              4.943 ns (logic 2.006, route 2.937), LUT6 + CARRY4 + CARRY4
  //              and three more LUT6
  //
  // `elapsed >= X` at tick t is `elapsed >= X - 1` at tick t-1, because
  // `elapsed` counts by one and the deskew never lands on its saturation ---
  // so registering the earlier comparison puts the same value on the same
  // tick with the carry chain off the acknowledgment's path entirely.  This
  // is the second of the two remedies `rtl/plumbing/xilinx7/cadr_machine.xdc` sets out: the
  // signal is read every tick, so it is not a candidate for holding, and what
  // is left is to make the path shorter.
  //
  // The `state == GRANTED` term does at this end what `answered` used to do at
  // the far one.  A register lags its input by a tick, and `answered` is
  // cleared at the grant, so without it the last cycle's deskew would stand
  // through the first tick of the next cycle and acknowledge it.
  //
  // **AND IT IS NAMED IN `rtl/plumbing/xilinx7/cadr_machine.xdc`**, unlike the two holdings
  // that file describes.  Those are stable across a microcycle and read at the
  // end of one, so they fall in `slow` by its own test.  This is an
  // acknowledgment, read every tick; left unnamed it would take the fifteen
  // tick exception written for the datapath, and the one path this change
  // exists to shorten would stop being timed at all.
  logic deskewed, deskew_due;
  assign deskew_due = answered && (state == GRANTED)
                   && (elapsed >= answered_at + 10'(DESKEW_T) - 10'd1);

  logic acked;
  assign acked = (state == ACKED)
              || (state == GRANTED && ((write && answering) || deskewed))
              || (state == UB && ub_acked);

  assign n_memgrant = !(state == GRANTED || state == UB || state == ACKED);
  assign n_memack   = !acked;
  // On the Xbus the word lands with the acknowledgment, which the deskew has
  // already accounted for, so -LOADMD and -MEMACK coincide. They do not on the
  // Unibus, where the word comes UNIBUS_STROBE_NS after -UB SSYN and so
  // *before* the acknowledgment, which is why this is a port of its own.
  assign n_loadmd   = !(acked || (state == UB && ub_loadmd));
  // The flag belongs to the cycle standing, as `Ack::timed_out` does: it goes
  // when the cpu lifts -MEMRQ and the cycle is over. What outlives the cycle is
  // the NXM bit in the bus error register at REQERR, which is not this slice.
  assign timed_out  = (state == ACKED) && nxm;
  // `Busint::busy`, verbatim: a cycle is in flight from the tick -MEMRQ is
  // taken to the tick the processor lifts it.
  assign busy       = (state != IDLE);

  always_ff @(posedge clk) begin
    // The oscillator runs whatever the cycle is doing, and reset only sets its
    // phase: on the board it has been running since the power came up.
    //
    // **THE STARTING PARITY IS STATED HERE RATHER THAN INHERITED.**  Zero
    // makes the first half period the LONGER of the two wherever the grid
    // does not divide 425: at a 10 ns grid it is 43 ticks and then 42.  At
    // the 5 ns grid the machine runs at, every half period is 85 and the
    // parity does not arise.  The reference anchors the timeout at five
    // periods after the first gated rise, with whole periods counted from
    // power-on, and at this grid a zero start begins a half period at
    // reset as that does.  At a grid that does not divide 425 no starting
    // value keeps every edge on the reference's instant.  Issue #21 found a
    // separate one-tick defect in how the timer samples `vco`; that is not
    // this counter's and is fixed on its own.
    if (rst) begin
      vco_acc <= 9'd0;
      vco     <= 1'b1;
    end else if (vco_toggle) begin
      vco_acc <= vco_less;
      vco     <= !vco;
    end else begin
      vco_acc <= vco_next;
    end

    if (rst) begin
      state       <= IDLE;
      stage       <= 3'd0;
      arb_t       <= 9'd0;
      ub_master   <= 1'b0;
      ssyn_seen   <= 1'b0;
      ub_ack_at   <= 10'd0;
      ub_md_at    <= 10'd0;
      write       <= 1'b0;
      elapsed     <= 10'd0;
      answered    <= 1'b0;
      answered_at <= 10'd0;
      deskewed    <= 1'b0;
      ub_acked    <= 1'b0;
      ub_loadmd   <= 1'b0;
      tmr_fell    <= 1'b0;
      tmr_rises   <= 4'd0;
      nxm         <= 1'b0;
    end else begin
      // The gated output, while a cycle is granted. Its first fall is the
      // oscillator's first fall *strictly after* the grant, so a grant landing
      // on one misses it --- which falls out of the ordering here, the grant's
      // own clear of `tmr_fell` below coming after this.
      if (arb_t != 9'h1FF) arb_t <= arb_t + 9'd1;

      // The three taps, each one tick after its own comparison. See the notes
      // at `ub_ack_due` and at `deskew_due`.
      deskewed  <= deskew_due;
      ub_acked  <= ub_ack_due;
      ub_loadmd <= ub_md_due;

      if (state == GRANTED || state == UB) begin
        if (vco_toggle) begin
          if (!tmr_fell && vco) begin
            tmr_fell <= 1'b1;
          end else if (tmr_fell && !vco) begin
            tmr_rises <= tmr_rises + 4'd1;
            if (tmr_rises + 4'd1 == tmr_want) begin
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
              ub_ack_at   <= 10'd0;
              ub_md_at    <= 10'd0;
              tmr_fell    <= 1'b0;
              tmr_rises   <= 4'd0;
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
            ub_ack_at   <= 10'd0;
            ub_md_at    <= 10'd0;
            tmr_fell    <= 1'b0;
            tmr_rises   <= 4'd0;
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
            ssyn_seen   <= 1'b1;
            // The sums are made here, where they have a whole tick and are
            // off the comparator's path. `elapsed` saturates rather than
            // wraps, so these cannot run away behind it.
            ub_ack_at   <= elapsed + 10'(UB_ACK_T) - 10'd1;
            ub_md_at    <= elapsed + 10'(UB_STROBE_T) - 10'd1;
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
        // acknowledgment. That delay is the cpu's, not the interface's.
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
