// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The debug cable's DBGIN end: this machine as somebody else's debuggee.
//
// A CADR is debugged by another CADR.  The debugger's DBGOUT connector goes to
// this one's DBGIN connector over MIT's twenty-one wires, and through them the
// debugger reaches four strobes --- `-DB NEED UB`, `-DB READ STATUS`,
// `-DB ADR1 CLK` and `-DB ADR0 CLK` --- which the 74S139 at DBGIN 0A15 makes
// of `DEBUG IN A<1:0>` while `-DEBUG IN REQ` is down.  This module is that
// page: the decoder, the modifier register at 0A16, the two address latches
// at 0A18 and 0A19, the error-status driver at REQERR 0B15, and the debug
// master's place on this machine's Unibus.
//
// **WHAT HOLDS IT.**  muir, at `rtl` fidelity, through
// `lashup::CableEnd`'s debuggee half:
//
//   the strobes and their          `busint::DEBUG_CYCLE`, `DEBUG_STATUS`,
//   acknowledgement                `DEBUG_MODIFIER`, `DEBUG_ADDRESS`, and
//                                  `Rtl::try_debug_request`, which answers a
//                                  register strobe at the instant it is made
//                                  and a cycle never
//   the latches' trailing edge     `Busint::debug_latch`
//   the modifier's three bits      `busint::debug_modifier`
//   the eighteen-bit address       `Busint::debug_unibus_address`
//   the status byte                `Machine::debug_status`
//   the master's instants          `busint::DEBUG_MSYN_NS`,
//                                  `busint::DEBUG_RELEASE_NS`, and
//                                  `Busint::debug_set_master`
//
// **AND WHERE IT PARTS FROM muir, said once here rather than found later.**
// muir takes this master through MIT's own arbitration --- `NPR`, `NPG1 IN`,
// the 74LS74 at UBMAST 0D02, `SACK`, `BUS READY` and `-UB BBSY`, which is
// `Debug::NeedUb` through `Debug::Selected`.  `cadr_busint_xbus.sv` says in
// its own header that every branch it left out of the processor's
// arbitration belongs to this cable.  This fabric puts the debug master on
// `cadr_console_bus.sv` instead, the same simple arbiter the console uses:
// the grant is taken only with the processor's own strobe down, and it is
// held until this master lets go.  So `dbg_gnt` stands where `DBUB MASTER`
// stands and the instants either side of it are this fabric's, not MIT's.
// Everything from the grant onward --- `-UB MSYN` a hundred nanoseconds on,
// the slave's answer, `DEBUG ACK` with `-UB SSYN`, the release a hundred
// nanoseconds after the lift --- is muir's.
//
// **THE CABLE IS LEVELS AND NOT PULSES.**  `busint::DebugRequest` says so:
// the wires are held for the whole request, as the debugger's own Unibus
// cycle holds them, because the 8304s drive `DBD` from `UDO` for as long as
// `DEBUG ACTIVE` is up.  There is no edge on this cable that carries
// information by itself, and every decision made here is made from a level
// that is standing.
//
// **EXCEPT ONE, AND IT IS THE ONE THAT MATTERS.**  The latches are clocked on
// the way OUT.  `-DB ADR0 CLK` and `-DB ADR1 CLK` reach pin 11 of the two
// 74LS374s and the 25LS2519, so the address and modifier registers take `DBD`
// at the strobe's TRAILING edge, which is when the request lifts.  This
// module therefore takes `dbd_in` as it stands on the tick `dbg_in_req`
// falls, and does NOT keep a copy of its own.  That is deliberate: it makes
// the carrier's promise to hold the levels past the lift load-bearing, so a
// carrier that cleared `DBD` as part of lifting would write the wrong word
// into this machine's address or modifier register and the check would say
// so.  A modifier register that takes a stray one in bit 1 resets this
// machine and halts it.
//
// **THE STATUS DRIVES THE LOW BYTE AND NOTHING ABOVE IT.**  `-DB READ STATUS`
// enables the Am8304 at REQERR 0B15, which is an octal driver onto
// `DBD<7:0>`.  The high byte is undriven and the cable's own pull-ups carry
// it, which is why `Rtl::try_debug_request` writes the answer as
// `0xff00 | status`.  So `dbd_oe` is two bits, one a byte, and the carrier
// resolves an undriven byte as ones because that is what the SIP at DBGIN
// 0A22 does.  Putting the ones here instead would be this board claiming to
// drive a byte it does not drive.
//
// `err_status` is the byte itself and comes from outside, as `spy_rdata`
// does: `Machine::debug_status` assembles it out of the bus error register's
// eight bits, `-FREE` in bit 6 and `WRITE THROUGH ENB` in bit 7, and those
// registers are the bus interface's at `0o766040`-`0o766076`, which this
// fabric does not build.  What is real here is bit 6.
//
// **NO TIMEOUT RUNS FOR THIS MASTER.**  `Rtl::debug_ack`'s own comment: "a
// cycle at an address nothing answers is never acknowledged, there being no
// timeout for this master".  `INT BUSY`, which starts the timeout counter, is
// `NAND(-UBX GRANT, -LMX GRANT, -LMUB GRANT)` at RQSYNC 0C13 and knows
// nothing of the debug master.  So a cycle nothing answers stands until the
// debugger gives up, which its own interface does 11.05 microseconds after
// its grant --- `busint::DEBUG_TIMEOUT_NS`, the REQTIM PROM's second table.
// Nothing in this module counts, and that is the point: a timer here would be
// a machine MIT did not build.
//
// **AND A STANDING CYCLE STARVES THIS MACHINE, WHICH IS ALSO FAITHFUL.**
// `-DB NEED UB` down keeps the debug master on the Unibus with `-UB BBSY`
// asserted, so this machine's own Unibus cycles wait, and one that waits
// longer than the 4,250 ns NXM timer becomes a non-existent-memory error.
// That is what the real board does and it is why CC halts the debuggee before
// it does anything else.  The carrier's watchdog recovers a wedged bus; it
// cannot and does not protect the machine.

`default_nettype none

module cadr_dbgin #(
    // busint::DEBUG_MSYN_NS: from `DBUB MASTER` to `-UB MSYN`.  "MSYN OUT at
    // DATCTL 0D08 follows the master a delay-line section on."
    parameter int unsigned MSYN_T    = 100 / 5,
    // busint::DEBUG_RELEASE_NS: from `-DEBUG IN REQ` rising to `DBUB MASTER`
    // clearing, the 74S74 at UBMAST 0D02.
    parameter int unsigned RELEASE_T = 100 / 5
) (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- the cable, as the carrier presents it.  Levels, held for the whole
    // --- request; `dbg_in_req` high means `-DEBUG IN REQ` is DOWN, which is
    // --- muir's `fabric::REQ` and is the sense the whole transport uses.
    input  var logic        dbg_in_req,
    input  var logic        dbg_in_wr,    // DEBUG IN WR
    input  var logic [1:0]  dbg_in_a,     // DEBUG IN A<1:0>
    input  var logic [15:0] dbd_in,       // DBD<15:0> as the debugger drives
    output var logic        dbg_in_ack,   // DEBUG IN ACK
    output var logic [15:0] dbd_out,      // DBD<15:0> as this board drives
    output var logic [1:0]  dbd_oe,       // {DBD<15:8>, DBD<7:0>} driven

    // --- the error status the 8304 at REQERR 0B15 puts on `DBD<7:0>`:
    // --- `Machine::debug_status`, assembled where its registers are
    input  var logic [7:0]  err_status,

    // --- the modifier register's two effects, `busint::debug_modifier`
    output var logic        debuggee_reset,   // bit 1, `-DEBUGEE RESET`
    output var logic        timeout_inhibit,  // bit 2, `-DEBUG TIMEOUT INH`

    // --- this machine's Unibus, as the third master drives it.  The names
    // --- and the polarities are `cadr_console_bus.sv`'s.
    output var logic        dbg_req,      // -DB BUS REQ: this master wants it
    input  var logic        dbg_gnt,      // DBUB MASTER: and has it
    output var logic        ub_msyn,
    output var logic        ub_write,
    output var logic [17:0] ub_addr,
    output var logic [15:0] ub_wdata,
    input  var logic        ub_ssyn,
    input  var logic [15:0] ub_rdata,

    // --- the two latches, brought out so that a check can read them without
    // --- going round through a bus cycle.  `Busint::debug_modifier` and the
    // --- 74LS374s' `UAO<16:1>`.
    output var logic [2:0]  modifier_o,
    output var logic [15:0] address_o
);

  // busint::DEBUG_CYCLE, DEBUG_STATUS, DEBUG_MODIFIER, DEBUG_ADDRESS: Y0 to
  // Y3 of the 74S139 at DBGIN 0A15.
  localparam logic [1:0] A_CYCLE    = 2'd0;
  localparam logic [1:0] A_STATUS   = 2'd1;
  localparam logic [1:0] A_MODIFIER = 2'd2;
  localparam logic [1:0] A_ADDRESS  = 2'd3;

  // The width the two counters need.  Both are `MSYN_T` or `RELEASE_T` ticks
  // and nothing here counts further, there being no timeout for this master.
  localparam int unsigned WAIT_W = $clog2((MSYN_T > RELEASE_T ? MSYN_T
                                                              : RELEASE_T) + 1);

  // The four strobes, decoded combinationally while the request is down, as
  // the 74S139 decodes them.  **It is a decode and not a register**: the
  // request is what enables it, the address bits have been standing a
  // hundred nanoseconds by then, and a strobe held in a register would be a
  // strobe that outlived its request.
  logic strobe_cycle, strobe_status, strobe_modifier, strobe_address;
  assign strobe_cycle    = dbg_in_req && (dbg_in_a == A_CYCLE);
  assign strobe_status   = dbg_in_req && (dbg_in_a == A_STATUS);
  assign strobe_modifier = dbg_in_req && (dbg_in_a == A_MODIFIER);
  assign strobe_address  = dbg_in_req && (dbg_in_a == A_ADDRESS);

  // The request's own trailing edge, which is what clocks the latches.
  logic req_q;
  logic lift;
  assign lift = req_q && !dbg_in_req;

  // The modifier register, the 25LS2519 at DBGIN 0A16, and the two address
  // latches, the 74LS374s at 0A18 and 0A19.  Both take `DBD` at the trailing
  // edge of their own strobe and nowhere else.
  logic [2:0]  modifier;
  logic [15:0] address;
  assign modifier_o      = modifier;
  assign address_o       = address;
  assign debuggee_reset  = modifier[1];
  assign timeout_inhibit = modifier[2];

  // `Busint::debug_unibus_address`: `UAO<16:1>` from the latches, `UAO17`
  // from the modifier register, and bit 0 always zero --- MIT's own note,
  // "Bit 0 of the address is not sent over the cable".
  assign ub_addr = {modifier[0], address, 1'b0};

  // The cycle engine.  `C_NEEDUB` is `-DB NEED UB` down with the bus not yet
  // this master's; `C_MSYN` is `DBUB MASTER` with the address out and
  // `-UB MSYN` a delay-line section away; `C_XFER` is the cycle running;
  // `C_REL` is the request lifted with `DBUB MASTER` still up.
  typedef enum logic [2:0] { C_IDLE, C_NEEDUB, C_MSYN, C_XFER, C_REL } cstate_e;
  cstate_e            cst;
  logic [WAIT_W-1:0]  wait_t;
  logic               acked;      // `DEBUG ACK` for the cycle now standing

  // `-DB BUS REQ` at UBMAST 0D06 is down for as long as this master wants the
  // bus or still holds it, so the arbiter may not hand it away underneath the
  // release.
  assign dbg_req  = (cst != C_IDLE);
  assign ub_msyn  = (cst == C_XFER);
  assign ub_write = dbg_in_wr;
  assign ub_wdata = dbd_in;

  // `DEBUG ACK` is `(DBUB MASTER AND SSYN T0) OR NAND(-DB ADR1 CLK, -DB ADR0
  // CLK, -DB READ STATUS)`, the 74S08, 74S10 and 74S32 at DBGIN 0A12, 0A14
  // and 0A09.  The second half is the three register strobes acknowledged the
  // instant they are made, with nothing in between; the first is the cycle's,
  // and it follows `-UB SSYN` with no delay of its own.
  assign dbg_in_ack = strobe_status || strobe_modifier || strobe_address
                      || (strobe_cycle && acked);

  // What this board drives on `DBD`.  The status is the low byte alone, the
  // Am8304 at REQERR 0B15 being an octal driver onto `DBD<7:0>`; a read cycle
  // is both bytes from `-UB SSYN` on, the transceivers facing outward under
  // `-DEBUG > UD`; a write cycle and the two latch strobes drive nothing,
  // the debugger having the lines.
  //
  // **AND THE READ CYCLE'S WORD IS LIVE AND NOT LATCHED, WHICH IS A DECISION
  // AND WAS WRONG FIRST.**  The transceivers drive `DBD` from `UDI` while the
  // cycle runs; the word is good at `-UB SSYN` and the debugger samples it
  // there.  Nothing on this board holds it, and MIT's own note about the
  // diagnostic registers is that "read and write at the same address are
  // uncorrelated" --- the 74LS244s drive `SPY<15:0>` asynchronously and a
  // running machine moves them under a standing `-UB SSYN`.  So the latch
  // belongs to whoever is watching, which is the carrier:
  // `cadr_debug_window.sv` takes `DBD` and `DRV` at the instant `DEBUG IN
  // ACK` first rises, exactly as `cable::DebugIn::observe` records "the word
  // the board drove" on the simulated side.  A register here would make that
  // one redundant, and a redundant latch is two places a mutation can be made
  // and neither caught.
  always_comb begin
    if (strobe_status) begin
      dbd_out = {8'h00, err_status};
      dbd_oe  = 2'b01;
    end else if (strobe_cycle && acked && !dbg_in_wr) begin
      dbd_out = ub_rdata;
      dbd_oe  = 2'b11;
    end else begin
      dbd_out = 16'h0000;
      dbd_oe  = 2'b00;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      req_q    <= 1'b0;
      modifier <= 3'd0;
      address  <= 16'd0;
      cst      <= C_IDLE;
      wait_t   <= '0;
      acked    <= 1'b0;
    end else begin
      req_q <= dbg_in_req;

      // `Busint::debug_latch`: the trailing edge of a register strobe.  The
      // 74LS374s take `DBD<15:0>` under `-DB ADR0 CLK` and the 25LS2519
      // `DBD<2:0>` under `-DB ADR1 CLK`; `-DB READ STATUS` loads nothing.
      // The word taken is `dbd_in` as it stands at this edge, which is what
      // makes the carrier's hold past the lift load-bearing.
      if (lift) begin
        if (dbg_in_a == A_ADDRESS)  address  <= dbd_in;
        if (dbg_in_a == A_MODIFIER) modifier <= dbd_in[2:0];
      end

      unique case (cst)
        C_IDLE: begin
          acked <= 1'b0;
          if (strobe_cycle) cst <= C_NEEDUB;
        end

        // Asking.  A request withdrawn before this master has the bus leaves
        // nothing behind: `-DB RESET` at UBMAST 0B16 is `DB NEED UB AND
        // -DBUB MASTER` and resets the two flops at 0D02.  muir's
        // `Busint::debug_release` takes `NeedUb` straight to `Idle`.
        C_NEEDUB:
          if (!dbg_in_req) cst <= C_IDLE;
          // **THE TICK THAT TAKES THE GRANT IS THE FIRST OF THE SECTION**,
          // which is why this loads two short and the release below loads
          // one.  `DBUB MASTER` is a registered output of the arbiter, so the
          // edge that brings it up is the edge this arm runs at, and
          // `-UB MSYN` is due `MSYN_T` ticks after that level stands ---
          // measured, at 21 ticks against muir's 20, before it was written
          // this way.
          else if (dbg_gnt) begin
            cst    <= C_MSYN;
            wait_t <= WAIT_W'(MSYN_T - 2);
          end

        // `DBUB MASTER` is up, the address is on the bus, and `-UB MSYN`
        // follows a delay-line section on.  From here the lift costs the
        // release, because the master has the bus.
        C_MSYN:
          if (!dbg_in_req) begin
            cst    <= C_REL;
            wait_t <= WAIT_W'(RELEASE_T - 1);
          end else if (wait_t == '0) cst <= C_XFER;
          else wait_t <= wait_t - 1'b1;

        // The cycle is running.  `-UB SSYN` raises `DEBUG ACK`, and from that
        // instant this board drives the lines a read brings back --- "the word
        // on `DBD<15:0>` if this side drives it, as of that instant".  Nothing
        // ends this but the slave's answer or the debugger's lift.
        C_XFER: begin
          if (ub_ssyn && !acked) acked <= 1'b1;
          if (!dbg_in_req) begin
            cst    <= C_REL;
            wait_t <= WAIT_W'(RELEASE_T - 1);
          end
        end

        // `-UB MSYN` dropped with the request; `DBUB MASTER` and `-UB BBSY`
        // follow it down a delay-line section later.
        C_REL: begin
          acked <= 1'b0;
          if (wait_t == '0) cst <= C_IDLE;
          else wait_t <= wait_t - 1'b1;
        end

        default: cst <= C_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
