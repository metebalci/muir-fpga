// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The debug cable's carrier: sixteen words on a general-purpose AXI port, and
// MIT's twenty-one wires behind them.
//
// The debugger is muir, running under Linux on the board's own Arm cores.  It
// reaches this window through `/dev/mem` with ordinary 32-bit loads and
// stores, selected by `--debug-cable-connect 0x<address>`.  There is no
// socket, no frame encoding and no promise protocol: muir's `src/fabric.rs`
// is the other end of this file and `muir` issue #95 is the specification
// both were written to.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE**, in the sense the rest of
// `rtl/machine/` has one.  There is no trace to compare against tick for
// tick, because muir has no model of a register window with a clock.  What
// holds it is the AXI3 protocol, read-back, and the layout muir's
// `fabric::Fabric` stores into --- the same kind of evidence
// `cadr_axi_master.sv` is held to, and it is why this file is in
// `rtl/plumbing/` and `cadr_dbgin.sv` is not.
//
// **THE LAYOUT.**  Sixteen words, 64 bytes.  Five are used and the rest read
// `UNMAPPED`.  muir's `src/fabric.rs` documents every field; the constants
// here are its constants.
//
//   0  IDENT   read-only, "DBUG", 0x44425547
//   1  CTL     the request, whole, in one store
//   2  STS     the answer, in one load
//   3  CLEAR   a store of "LIFT" lifts any standing request and clears
//   4  FAULTS  a count and three sticky faults
//   5-15       UNMAPPED, the complement of IDENT
//
// `IDENT` is compared as a 32-bit word and never as bytes.  These are 32-bit
// registers on a 32-bit port, so a load gives the register's value unchanged
// and byte order never enters.  It is the same convention as `CONS` for the
// console, `PACK` for the disk pack side, and `NONE` for a general-purpose
// port brought out with nothing of ours behind it --- and `NONE` is why a
// window pointed at the wrong port reads a printable word rather than
// hanging.
//
// **THE WHOLE REQUEST CROSSES IN ONE STORE, AND THAT IS THE POINT.**  The
// cable has no parity, no framing and no acknowledgement of the request
// itself, and three ways of getting it wrong are undetectable by anything on
// it.  A late address bit makes the 74S139 decode the wrong strobe, so a
// request meant for the address latch fires `-DB NEED UB` and runs a Unibus
// cycle on the debuggee at whatever address was last latched --- not a
// corrupt read, a write to a register nobody asked for.  A late data line is
// latched instead of the intended word, and a modifier register that takes a
// stray one in bit 1 resets the debuggee and halts it.  A write flag that
// moves inside a request inverts the cycle.
//
// `CTL` is one register and a request is one store, so there is no ordering
// for a carrier to get wrong.
//
// **A STORE THAT DOES NOT STROBE ALL FOUR LANES IS DROPPED**, and that is the
// same hazard arriving by a different door.  A byte store to `CTL` would set
// `REQ` beside whatever `DBD` the last store left.  Nothing is recorded when
// one is dropped and nothing needs to be: `COUNT` does not move, `STS` does
// not hold the request, and muir's own guard --- the sequence number ---
// reports it as "not the adapter holding muir's request".  That is `COUNT`
// doing the job its own doc comment gives it, which is to answer whether
// anything is happening at all.
//
// **THE HUNDRED NANOSECONDS ARE REPRODUCED HERE, WHERE THEY ARE FREE.**  On
// the board the data, the address bits and the write flag are on the cable
// one delay-line section before the request: `-DEBUG OUT REQ` is
// `NAND(SELECT DEBUG, SELECT DEBUG DLYD)` at DBGOUT 0A11 and the delay is the
// MTD100 at 0A10, so the request falls after everything else is standing.
// That is `busint::DEBUG_OUT_REQUEST_NS`.  A store to `CTL` puts the levels
// on the cable at once and asserts `-DEBUG IN REQ` `LEAD_T` ticks later.
//
// **AND THE LEVELS ARE NEVER CLEARED, WHICH IS WHAT THE LIFT NEEDS.**  On the
// board `DEBUG ACTIVE` is `SELECT DEBUG OR SELECT DEBUG DLYD` at DBGOUT 0A09
// and so falls one section AFTER the request, holding `DBD` past the lift.
// The debuggee's latches take `DBD` at the trailing edge of their strobe, so a
// carrier that cleared the lines as part of lifting would write the wrong word
// into the debuggee's address or modifier register.  `cadr_dbgin.sv`
// deliberately keeps no copy of `DBD`, so the promise made here is
// load-bearing rather than decorative.
//
// **AND IT IS A RULE AND NOT A COUNTDOWN, WHICH IS A CORRECTION.**  This
// module carried a trailing section of its own for a while, `LEAD_T` ticks
// after the lift during which no new request was taken --- and nothing could
// ever reach it.  `cadr_dbgin.sv` latches at the edge AFTER the one that
// dropped `-DEBUG IN REQ`, so the word it takes is the one standing at the end
// of the lift's own write beat; and this port cannot deliver a second beat
// until four ticks later, the write channel having to pass W_RESP and W_ADDR
// to get there.  A twenty-tick guard in front of a four-tick structural
// margin is an exemption nothing exercises, which this project has learnt
// looks exactly like one that is right.  What replaces it is the rule --- the
// levels are written once, at the request, and never cleared --- and
// `tb/cadr_dbgin_tb.cpp` measuring the margin every run rather than assuming
// it, so the day the port's shape changes the check says so.
//
// **THE LEVELS COME FROM THE REQUEST AND NOT FROM THE LIFT.**  muir writes a
// lift as the request word with bit 0 cleared and nothing else changed, so
// the two agree; this module does not depend on it.  A lift store clears
// `REQ` and touches nothing else, which is what the board does --- what is on
// `DBD` after the lift is the cycle's own word, and `CTL` reads it back with
// `REQ` clear, which is what "the adapter is holding" means when it is
// holding nothing.
//
// **A REQUEST SHORTER THAN THE LEAD MAKES NO STROBE AT ALL, and that is
// faithful rather than a corner.**  `-DEBUG OUT REQ` is low only while both
// `SELECT DEBUG` and its delayed copy are high, so a select shorter than one
// section never brings the request down on the real cable either.  Here the
// lift stops the lead, no strobe is made, `STS` says the adapter is not
// holding the request, and muir treats the cycle as unanswered.
//
// **THE ANSWER IS LATCHED AT THE ACKNOWLEDGEMENT AND NOT READ AT THE LOAD.**
// `ACK`, `DBD` and `DRV` are taken at the instant `DEBUG IN ACK` first rises
// for the standing request and held until it is lifted.  By the time the Arm
// gets round to loading `STS`, the fabric has run for however long the core
// took, and the word the debuggee drove may be long gone.  muir's
// `cable::DebugIn::observe` records the same instant on the simulated side.
//
// **AN UNDRIVEN BYTE READS ONES, BECAUSE THAT IS WHAT THE CABLE DOES.**  The
// SIP at DBGIN 0A22 pulls the cable up, and `-DB READ STATUS` enables an
// octal driver onto `DBD<7:0>` alone, so a status read reads
// `0xff00 | status` --- which `Rtl::try_debug_request` already writes that
// way.  `cadr_dbgin.sv` drives the low byte and says which bytes it drives;
// the resolution is here, because the pull-ups are the cable's and not the
// board's.  `DRV` reports whether the debuggee drove anything at all, which
// on the wire is indistinguishable from driving all ones and in fabric is
// free to know.
//
// **THE MARKER AND THE SEQUENCE.**  `STS` and `FAULTS` carry `01` in bits 15
// and 14.  A word of all zeros gives `00` and one of all ones gives `11`, so
// neither can be mistaken for an answer, and muir applies the guard to every
// load and not only the first.  It has to live outside `DBD`, because all
// ones there is what an open cable reads and is a perfectly legal answer.
// The four-bit sequence crosses in `CTL` and comes back in `STS`: an
// acknowledgement left standing from a previous transaction reads exactly
// like an answer to the present one, and the sequence is what tells them
// apart.
//
// **THE WATCHDOG, AND WHAT IT CANNOT DO.**  A request left standing holds
// `-DB NEED UB` down, keeps the debug master on the debuggee's Unibus with
// `-UB BBSY` asserted, and the machine's own cycles wait for ever.  On a real
// lashup unplugging the cable ends that, the SIP pulling `-DEBUG IN REQ` up;
// here there is nothing to unplug, so a request that has stood longer than
// `WATCHDOG_T` is lifted and `FAULTS` bit 0 is set.
//
// The interval's only job is to be far longer than any legitimate hold, and
// it cannot be short enough to protect the machine.  The machine's own Unibus
// cycle becomes an NXM 4,250 ns after its grant, which is shorter than any
// round trip through a mapped load on a core Linux may preempt --- so by the
// time any watchdog could fire, the damage a standing cycle does is already
// done.  What it recovers is a wedged bus, not a cycle.  One second is a
// floor with margin and is not derived from anything; it is a parameter
// because a bound nothing exercises is not a bound, and the check shrinks it.
//
// **EVERY ADDRESS ON THE PORT IS ANSWERED, WITH OKAY.**  A read nothing
// answers on a general-purpose port does not fault the Arm, it hangs both
// cores at one program counter each --- measured on the board, and
// `cadr_gp0_default.sv` says so at length.  So a read outside the sixteen
// words completes with `UNMAPPED` and a write outside them completes and is
// dropped, over the whole gigabyte the port decodes.  OKAY and not SLVERR,
// for the reason the console gives: an error response to a Cortex-A9's
// posted write arrives as an imprecise external abort the kernel cannot
// attribute to a process, and a constant a program can recognise is the safer
// failure.
//
// **WHERE THE WINDOW SITS IS NOT DECIDED.**  `REG_BASE` is a parameter and
// this module is a whole-port slave, so it drops onto a port of its own
// unchanged or behind a split.  `docs/debug-cable.md` has the question with
// its numbers.

`default_nettype none

module cadr_debug_window #(
    // Where the sixteen words sit.  `0x8000_0000` is the first address
    // `M_AXI_GP1` decodes to the fabric in the Zynq-7000 PS address map, as
    // `0x4000_0000` is `M_AXI_GP0`'s.
    parameter logic [31:0] REG_BASE = 32'h8000_0080,
    // muir's `fabric::DBUG`: "DBUG", 'D' in the most significant byte.
    parameter logic [31:0] IDENT    = 32'h4442_5547,
    // muir's `fabric::UNMAPPED`: the complement of IDENT, so that a window
    // answering with it cannot be mistaken for one of the five that mean
    // something.
    parameter logic [31:0] UNMAPPED = ~IDENT,
    // muir's `fabric::LIFT`: "LIFT".  Four distinct bytes, none of them `00`
    // or `FF`, halves that differ and are not rotations of each other, and
    // not IDENT, not UNMAPPED and not what the word reads back --- so an
    // arbitrary value landing there cannot lift a live request.
    parameter logic [31:0] LIFT     = 32'h4C49_4654,
    // busint::DEBUG_OUT_REQUEST_NS, in ticks: the levels are on the cable
    // this long before the request, and this long after the lift.
    parameter int unsigned LEAD_T   = 100 / 5,
    // How long a request may stand before the watchdog lifts it.  One second
    // at the 10 ns tick.  See the header: it is a floor with margin.
    parameter int unsigned WATCHDOG_T = 100_000_000
) (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- the general-purpose port, on which the processing system is the
    // --- master.  AXI3, 32 bits, 12-bit IDs, one write and one read in
    // --- flight at once.
    input  var logic [31:0] s_awaddr,
    input  var logic [3:0]  s_awlen,
    input  var logic [11:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [11:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [31:0] s_araddr,
    input  var logic [3:0]  s_arlen,
    input  var logic [11:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [11:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- MIT's cable, to `cadr_dbgin.sv`.  Twenty signals out and eighteen
    // --- back, every one of them a wire on the DBGIN connector.
    output var logic        dbg_in_req,   // -DEBUG IN REQ asserted
    output var logic        dbg_in_wr,    // DEBUG IN WR
    output var logic [1:0]  dbg_in_a,     // DEBUG IN A<1:0>
    output var logic [15:0] dbd_out,      // DBD<15:0> as the debugger drives
    input  var logic        dbg_in_ack,   // DEBUG IN ACK
    input  var logic [15:0] dbd_in,       // DBD<15:0> as the debuggee drives
    input  var logic [1:0]  dbd_oe        // which bytes the debuggee drives
);

  // The window's words: muir's `fabric::IDENT` and the four after it.
  localparam logic [3:0] W_IDENT  = 4'd0;
  localparam logic [3:0] W_CTL    = 4'd1;
  localparam logic [3:0] W_STS    = 4'd2;
  localparam logic [3:0] W_CLEAR  = 4'd3;
  localparam logic [3:0] W_FAULTS = 4'd4;

  // muir's `fabric::MARK`: `01` in bits 15 and 14 of STS and FAULTS, so that
  // a word of all zeros (`00`) and one of all ones (`11`) are both refused.
  localparam logic [1:0] MARK = 2'b01;

  localparam int unsigned LEAD_W = $clog2(LEAD_T + 1);
  localparam int unsigned DOG_W  = $clog2(WATCHDOG_T + 1);

  // ------------------------------------------------------------------------
  // The cable's own state
  // ------------------------------------------------------------------------

  logic              standing;   // a request is at the window
  logic [3:0]        seq;        // its sequence, muir's four bits
  logic [15:0]       count;      // requests taken, saturating
  logic [2:0]        faults;     // watchdog, request-on-request, idle lift

  logic [LEAD_W-1:0] lead_t;     // ticks to `-DEBUG IN REQ`
  logic              leading;    // counting them down
  logic [DOG_W-1:0]  dog_t;      // ticks the request has stood

  logic              sts_ack;    // `DEBUG IN ACK` rose for this request
  logic              sts_drv;    // and the debuggee drove at least one line
  logic [15:0]       sts_dbd;    // the lines as they stood at that instant

  // What the debuggee is putting on `DBD` right now, with an undriven byte
  // resolved as ones: the cable's pull-ups, the SIP at DBGIN 0A22.
  logic [15:0] dbd_seen;
  assign dbd_seen = {dbd_oe[1] ? dbd_in[15:8] : 8'hff,
                     dbd_oe[0] ? dbd_in[7:0]  : 8'hff};

  // ------------------------------------------------------------------------
  // The port
  // ------------------------------------------------------------------------

  typedef enum logic [1:0] { W_ADDR, W_DATA, W_RESP } wstate_e;
  typedef enum logic [1:0] { R_ADDR, R_PREP, R_PREP2, R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rstt;

  logic [31:0] w_at, r_at;
  logic [11:0] w_id, r_id;
  logic [3:0]  r_left;
  logic [31:0] w_next, r_next;
  assign w_next = w_at + 32'd4;
  assign r_next = r_at + 32'd4;

  // Whether a beat's address is one of the sixteen words, and which.  The
  // window is 64 bytes, so the match is on bits 31:6 and the index is 5:2.
  function automatic logic in_window(input logic [31:6] page);
    return page == REG_BASE[31:6];
  endfunction

  logic       w_in;
  logic [3:0] w_idx;
  assign w_in  = in_window(w_at[31:6]);
  assign w_idx = w_at[5:2];

  logic       r_in_q;
  logic [3:0] r_idx_q;
  logic [31:0] rdata_q;

  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bresp   = 2'b00;   // OKAY, everywhere: see the header
  assign s_bid     = w_id;

  assign s_arready = (rstt == R_ADDR);
  assign s_rvalid  = (rstt == R_DATA);
  assign s_rlast   = (r_left == 4'd0);
  assign s_rresp   = 2'b00;   // OKAY, everywhere
  assign s_rdata   = rdata_q;
  assign s_rid     = r_id;

  // A write beat lands this tick, and whether it strobed all four lanes.
  logic w_beat, w_whole;
  assign w_beat  = s_wvalid && s_wready;
  assign w_whole = (s_wstrb == 4'b1111);

  // The five words a load gives.  `CTL` reads back what the adapter is
  // holding, which closes the question of whether a store landed; `STS` and
  // `FAULTS` carry the marker; `CLEAR` reads the key's own top half with the
  // marker in it and one live bit, so that reading it and writing the word
  // straight back cannot lift a request.
  logic [31:0] r_word;
  always_comb begin
    if (!r_in_q) r_word = UNMAPPED;
    else begin
      unique case (r_idx_q)
        W_IDENT:  r_word = IDENT;
        W_CTL:    r_word = {dbd_out, 4'd0, seq, 4'd0, dbg_in_a, dbg_in_wr,
                            standing};
        W_STS:    r_word = {sts_dbd, MARK, 2'd0, seq, 4'd0, sts_drv, 1'b0,
                            sts_ack, standing};
        W_CLEAR:  r_word = {LIFT[31:16], MARK, 13'd0, standing};
        W_FAULTS: r_word = {count, MARK, 11'd0, faults};
        default:  r_word = UNMAPPED;
      endcase
    end
  end

  // ------------------------------------------------------------------------
  // The cable, driven
  // ------------------------------------------------------------------------

  // A store to `CTL` this tick, whole, in the window.
  logic ctl_store, clear_store;
  assign ctl_store   = w_beat && w_in && w_whole && (w_idx == W_CTL);
  assign clear_store = w_beat && w_in && w_whole && (w_idx == W_CLEAR)
                       && (s_wdata == LIFT);

  // The watchdog is due, or the debugger has lifted.
  logic dog_fires, lifting;
  assign dog_fires = standing && (dog_t == '0);
  assign lifting   = standing && ((ctl_store && !s_wdata[0]) || clear_store
                                  || dog_fires);


  always_ff @(posedge clk) begin
    if (rst) begin
      standing   <= 1'b0;
      seq        <= 4'd0;
      count      <= 16'd0;
      faults     <= 3'd0;
      leading    <= 1'b0;
      lead_t     <= '0;
      dog_t      <= '0;
      sts_ack    <= 1'b0;
      sts_drv    <= 1'b0;
      sts_dbd    <= 16'd0;
      dbg_in_req <= 1'b0;
      dbg_in_wr  <= 1'b0;
      dbg_in_a   <= 2'd0;
      dbd_out    <= 16'd0;
    end else begin
      // The lead, counting down to `-DEBUG IN REQ`.
      if (leading) begin
        if (lead_t == '0) begin
          leading    <= 1'b0;
          dbg_in_req <= 1'b1;
        end else lead_t <= lead_t - 1'b1;
      end

      // The dead man, counting the ticks a request has stood.
      if (standing && dog_t != '0) dog_t <= dog_t - 1'b1;

      // The answer, taken at the instant `DEBUG IN ACK` first rises for the
      // request now standing, and held until it is lifted.
      if (dbg_in_req && dbg_in_ack && !sts_ack) begin
        sts_ack <= 1'b1;
        sts_drv <= |dbd_oe;
        sts_dbd <= dbd_seen;
      end

      if (lifting) begin
        standing   <= 1'b0;
        dbg_in_req <= 1'b0;
        leading    <= 1'b0;
        if (dog_fires) faults[0] <= 1'b1;
      end

      if (ctl_store) begin
        if (s_wdata[0]) begin
          if (standing) begin
            // A second request while one stands is the caller's error:
            // `-DEBUG OUT REQ` is one level and a debugger has one request
            // out at a time.  It is recorded and dropped, because taking it
            // would corrupt the one the debuggee is answering.
            faults[1] <= 1'b1;
          end else begin
            standing   <= 1'b1;
            seq        <= s_wdata[11:8];
            dbd_out    <= s_wdata[31:16];
            dbg_in_a   <= s_wdata[3:2];
            dbg_in_wr  <= s_wdata[1];
            leading    <= 1'b1;
            lead_t     <= LEAD_W'(LEAD_T - 1);
            dog_t      <= DOG_W'(WATCHDOG_T);
            sts_ack    <= 1'b0;
            sts_drv    <= 1'b0;
            sts_dbd    <= 16'd0;
            if (count != 16'hFFFF) count <= count + 16'd1;
          end
        end else if (!standing) begin
          faults[2] <= 1'b1;   // a lift with nothing standing
        end
      end

      // The key, and only the key.  It lifts any standing request --- the
      // lift above --- and clears the count, the faults and the sequence, so
      // that a fresh muir inherits no half-finished transaction from a run
      // that was killed.
      if (clear_store) begin
        seq     <= 4'd0;
        count   <= 16'd0;
        faults  <= 3'd0;
        sts_ack <= 1'b0;
        sts_drv <= 1'b0;
        sts_dbd <= 16'd0;
      end
    end
  end

  // ------------------------------------------------------------------------
  // The port's two state machines
  // ------------------------------------------------------------------------

  logic w_last_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      wst      <= W_ADDR;
      w_at     <= 32'd0;
      w_id     <= 12'd0;
      w_last_q <= 1'b0;
      rstt     <= R_ADDR;
      r_at     <= 32'd0;
      r_id     <= 12'd0;
      r_left   <= 4'd0;
      r_in_q   <= 1'b0;
      r_idx_q  <= 4'd0;
      rdata_q  <= 32'd0;
    end else begin
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_at <= s_awaddr;
          w_id <= s_awid;
          wst  <= W_DATA;
        end
        W_DATA: if (s_wvalid) begin
          w_at     <= w_next;
          w_last_q <= s_wlast;
          if (s_wlast) wst <= W_RESP;
        end
        W_RESP: if (s_bready) begin
          w_last_q <= 1'b0;
          wst      <= W_ADDR;
        end
        default: wst <= W_ADDR;
      endcase

      unique case (rstt)
        R_ADDR: if (s_arvalid) begin
          r_at   <= s_araddr;
          r_id   <= s_arid;
          r_left <= s_arlen;
          rstt   <= R_PREP;
        end
        // The compare and the index registered, then the word: driven
        // straight off `r_at`, the mux reached the PS7's own RDATA pins
        // four logic levels late on the disk pack side's face, and this one
        // is built the same way for the same reason.
        R_PREP: begin
          r_in_q  <= in_window(r_at[31:6]);
          r_idx_q <= r_at[5:2];
          rstt    <= R_PREP2;
        end
        R_PREP2: begin
          rdata_q <= r_word;
          rstt    <= R_DATA;
        end
        R_DATA: if (s_rready) begin
          if (r_left == 4'd0) rstt <= R_ADDR;
          else begin
            r_at   <= r_next;
            r_left <= r_left - 4'd1;
            rstt   <= R_PREP;
          end
        end
        default: rstt <= R_ADDR;
      endcase
    end
  end

  // AWLEN and the write beat's last flag are not read: the data channel says
  // where a write ends, which is `cadr_gp0_default.sv`'s rule and the one the
  // interconnect drives.
  logic unused_w;
  assign unused_w = ^{s_awlen, w_last_q};

endmodule

`default_nettype wire
