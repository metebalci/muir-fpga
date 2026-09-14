// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT's debug cable over eight pins: the carrier between two boards.
//
// The debug cable joins two CADRs.  The debugger drives `-DEBUG IN REQ`,
// `DEBUG IN WR`, `DEBUG IN A<1:0>` and `DBD<15:0>` at the debuggee, and the
// debuggee answers with `DEBUG IN ACK` and `DBD<15:0>`.  MIT carries that on
// twenty-one wires, sixteen of them a bus the two ends share through
// transceivers.  A Pmod connector has eight signal pins, so a cable between
// two of these boards has eight wires and this module is what puts the
// cable's levels on them and takes them off again.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE.**  muir has the cable, and
// `rtl/machine/cadr_dbgin.sv` is held to it tick for tick; muir has no
// serialiser, because a model with no wires needs none.  What holds this is
// a property --- what goes in one end comes out the other, unchanged, in
// bounded time --- and that is why it is here and not in `rtl/machine/`, the
// same footing `cadr_axi_master.sv` and `cadr_debug_window.sv` are on.
//
// ## Eight pins, and why they are four each way
//
// The cable is ONE Pmod connector, and it carries both directions: twenty
// signals out and twenty back.  There are two ways to do that and only one of
// them is available here.
//
// **Half duplex**, seven data lines shared and turned around under a
// forwarded clock, is MIT's own arrangement: the Am8304s at DBGOUT 0B21 and
// 0B22 face whichever way `-DEBUG > UD` says.  It is also what the drawing
// claimed for a while, as "one clock and seven data".  Two things are wrong
// with it here.  A shared line turned around is two sets of drivers that must
// agree with no back channel to agree on, and a turnaround that misses does
// not corrupt a word, it puts two drivers on one wire.  And a receiver clocked
// from the cable is a second clock domain across the whole carrier, where the
// two boards already have a tick of the same length; what it would buy is a
// smaller delay, and delay is the one thing this cable does not care about.
//
// **Full duplex**, four pins each way, has no shared driver, nothing to turn
// around and nothing to agree about.  Each direction is one strobe and three
// data lines, driven by one end and sampled by the other with its own clock.
// That is what is built, and it is what makes the eighth wire a STROBE and
// not a clock: nothing on the receiving side is clocked by it.
//
// Which four pins are this end's is the ROLE and is not here:
// `rtl/plumbing/cadr_dbg_cable.sv` puts one of these on one connector and
// swaps the two groups between a debugger and a debuggee, so that a straight
// cable from one board's JA to another's JA maps every driver to a listener.
//
// The beats this costs are free.  A debugger gives up on a cycle 11.05
// microseconds after its grant --- `busint::DEBUG_TIMEOUT_NS`, the REQTIM
// PROM's second table, 1,105 ticks --- and a frame here is sixty-six.
//
// ## The frame, and why eight beats
//
// Twenty signals cross each way.  A frame must also say that it IS a frame,
// because an unplugged connector reads as a constant and a constant is
// indistinguishable from twenty levels that happen to be all ones or all
// zeros.  The project's own answer to that is a two-bit marker reading `01`:
// all zeros gives `00` and all ones gives `11`, so neither can be mistaken
// for a word.  `cadr_debug_window.sv` uses it in `STS` for the same reason.
//
// So a frame is twenty-two bits at least, and twenty-two over three lines is
// eight beats.  Eight beats is twenty-four slots, which leaves two over.
// **That is the beat count: eight, each way**, and the reason it is eight and
// not seven is the marker.
//
// **THE TWO SLOTS LEFT OVER ARE A PARITY BIT AND A ZERO**, and they catch
// what the marker cannot.  The marker says a frame is a frame; it says
// nothing about the twenty bits under it, so one line shorted, one beat
// sampled at the wrong instant or one bit flipped in the cable arrives as a
// level and is taken.  The parity bit is over the payload alone, so any odd
// number of bits wrong in it moves nothing at this end and the previous
// levels stand --- which is the same refusal a bad marker gets.  The zero
// fill is the third of the three: a line stuck high fails it whatever the
// payload is.  None of them is a code that can correct anything, and none
// should be: the far end sends the levels again sixty-six ticks later, so
// refusing a frame costs one frame.
//
// The drawing said four out and three back, against seven data lines on a
// connector carrying one direction.  Twenty over seven is three beats and
// twenty-two is four, so that count was right for its own premise; what does
// not hold is the premise, because one connector has to carry both
// directions, and the eighth pin is a strobe each way rather than a clock.
//
// ## The gap is the frame marker
//
// A receiver with no clock has to know which beat is beat zero.  It is told
// by the silence: the sender emits its eight beats back to back, `BEAT_T`
// ticks apart, and then leaves the lines alone for `GAP_T`.  Any interval
// longer than `GAP_MIN` with no transition is between frames, so the next
// transition is beat zero.  That costs no wire and no slot, and it
// resynchronises a receiver that has just come up, or that has been reset
// while the far end kept running, within one frame.
//
// The marker and the gap catch different things and both are kept.  The gap
// aligns the frame; the marker says whether what arrived in it was a frame at
// all.  A cable pulled out mid-frame is caught by the second, a receiver out
// of step by the first.
//
// ## What crosses is levels, and the frame is atomic
//
// The cable carries no events.  Every decision `cadr_dbgin.sv` makes is made
// from a level that is standing, and its two latches take `DBD<15:0>` at the
// trailing edge of their own strobe.  So the carrier's promise is that a
// level put in at one end stands at the other until it is replaced --- never
// cleared, never pulsed.
//
// **AND A FRAME IS PRESENTED WHOLE OR NOT AT ALL**, which is the promise that
// matters most.  `cadr_debug_window.sv`'s header names three hazards the
// cable has no defence against: a late address bit makes the 74S139 decode
// the wrong strobe, a late data line is latched instead of the intended word,
// and a write flag that moves inside a request inverts the cycle.  The window
// answers all three by making a request one 32-bit store.  A carrier that
// delivered a frame bit by bit would hand every one of them back.  So the
// sender takes its snapshot once, at the frame's first beat, and the receiver
// moves its outputs once, at the last --- and a frame that fails its marker
// moves them not at all, the previous levels standing.
//
// ## Sampling an asynchronous cable
//
// The strobe goes through two flops and a change is detected on the tick
// after the second.  The data lines go straight into the frame register,
// enabled by that detection --- which looks like sampling an asynchronous
// input and is not, because of WHEN it happens.  The sender changes the data
// and the strobe on the same edge, so they leave together and arrive together
// to within the skew of one Pmod cable.  By the time the strobe's change is
// detected the data has been standing for two ticks, and it stands for
// `BEAT_T` minus three more.  At the default six that is twenty nanoseconds
// of margin on the early side and thirty on the late, against a cable and a
// pad that contribute single-digit nanoseconds.  The strobe is the only thing
// on this cable that is synchronised, and the only thing that needs to be.
//
// ## An unplugged connector, and one that goes away
//
// With nothing plugged in, no transition ever arrives, no frame is ever
// taken, and `rx_levels` stands at zero with `rx_live` down.  Zero is the
// idle cable in both directions: `-DEBUG IN REQ` up, which is `dbg_in_req`
// low in the sense the whole transport uses, and `DEBUG IN ACK` down with
// neither byte driven.  `cadr_arty.sv` already ties the cable off that way on
// a board with no processing system and says why, and this reads the same.
//
// **WHAT THIS MODULE DOES NOT KNOW IS WHEN TO BE QUIET.**  Two boards cabled
// together with neither told to be the debugger must not both drive the
// return group, and a board with nothing plugged in should drive nothing at
// all; both are the CONNECTOR's business and are in
// `rtl/plumbing/cadr_dbg_cable.sv`, which simply leaves the pads
// high-impedance.  The sender here free-runs whatever the pads are doing, so
// a group that comes back under a running sender starts mid-frame and the
// receiver at the far end refuses that frame on its marker and its parity and
// takes the next one whole.  One frame, sixty-six ticks.
//
// A cable pulled out while a request stands is the case that needs a timer.
// The levels would otherwise stand for ever, `-DB NEED UB` would stay down,
// and the debug master would keep the debuggee's Unibus --- the wedged bus
// `cadr_debug_window.sv`'s watchdog exists for, one level further out.  On a
// real lashup the SIP at DBGIN 0A22 pulls the request up when the connector
// is pulled; here `LOSS_T` ticks with no good frame does it, and `rx_live`
// says so.  It is not a bound on a transaction and cannot be: frames are free
// running, so it fires only when the far end stops sending.
//
// ## What this module does not carry
//
// Nothing about the cable's ROLE.  The payload is a vector and which bit is
// `-DEBUG IN REQ` is decided where it is packed, so one module serves both
// ends and a check can put two of them back to back and get the cable.  The
// two directions are independent streams and never interlock, so neither can
// hold the other up and there is no deadlock to recover from.

`default_nettype none

module cadr_dbg_pmod #(
    // The cable's levels, in one direction.  Twenty at both ends: the
    // debugger's `{REQ, WR, A<1:0>, DBD<15:0>}` and the debuggee's
    // `{ACK, DRIVEN<1:0>, DBD<15:0>}` with a bit to spare.
    parameter int unsigned PAYLOAD_W = 20,
    // Data lines a direction.  Eight pins, one strobe each way, three left.
    parameter int unsigned LINES     = 3,
    // Ticks a beat.  See the header: what this buys is the margin either side
    // of the instant the receiver samples the data lines.
    parameter int unsigned BEAT_T    = 6,
    // Ticks of silence between frames, and the silence a receiver treats as
    // being between them.  `BEAT_T < GAP_MIN < GAP_T`, with room either side
    // for a tick of sampling jitter.
    parameter int unsigned GAP_T     = 18,
    parameter int unsigned GAP_MIN   = 12,
    // Ticks with no good frame before the far end is taken to be gone.  Free
    // running frames arrive every `BEATS * BEAT_T + GAP_T`, so this is
    // fifteen of them at the defaults and fires only when they stop.
    parameter int unsigned LOSS_T    = 1024
) (
    input  var logic                 clk,   // 100 MHz, one tick = 10 ns
    input  var logic                 rst,

    // --- the cable's levels, as this end has them
    input  var logic [PAYLOAD_W-1:0] tx_levels,
    output var logic [PAYLOAD_W-1:0] rx_levels,
    // Whether a frame has arrived and not yet been lost.  Down means an
    // unplugged connector or one that has gone quiet, and `rx_levels` is then
    // zero, which is the idle cable.
    output var logic                 rx_live,

    // --- the connector.  Four pins out, four in.
    output var logic                 tx_stb,
    output var logic [LINES-1:0]     tx_d,
    input  var logic                 rx_stb,
    input  var logic [LINES-1:0]     rx_d
);

  // The marker, and the frame it forces.  Two bits reading `01`, so that a
  // connector reading all zeros and one reading all ones are both refused ---
  // muir's `fabric::MARK`, and `cadr_debug_window.sv`'s `STS`.
  localparam int unsigned          MARK_W = 2;
  localparam logic [MARK_W-1:0]    MARK   = 2'b01;

  localparam int unsigned BEATS  = (PAYLOAD_W + MARK_W + 1 + LINES - 1) / LINES;
  localparam int unsigned SLOTS  = BEATS * LINES;
  // The marker, the parity bit and the zero fill together: everything above
  // the payload.  The marker is at the top, the parity bit under it, and the
  // fill under that, so a setting with no fill at all is not a special case.
  localparam int unsigned HEAD_W = SLOTS - PAYLOAD_W;
  localparam int unsigned BEAT_W = $clog2(BEATS + 1);
  localparam int unsigned TT_W   = $clog2((GAP_T > BEAT_T ? GAP_T : BEAT_T) + 1);
  localparam int unsigned IDLE_W = $clog2(GAP_MIN + 1);
  localparam int unsigned LOSS_W = $clog2(LOSS_T + 1);

  // The frame this end would send if it started one now: the marker at the
  // top, the payload at the bottom, zero fill in between.  Built whole rather
  // than concatenated, so that a setting with no fill at all is not a special
  // case in the source.
  logic [SLOTS-1:0] frame_out;
  always_comb begin
    frame_out                      = '0;
    frame_out[PAYLOAD_W-1:0]       = tx_levels;
    frame_out[SLOTS-MARK_W-1]      = ^tx_levels;
    frame_out[SLOTS-1 -: MARK_W]   = MARK;
  end

  // And what the head of a frame must read for the receiver to take it: the
  // marker, the parity of the payload UNDER it, and the fill as zero.  A
  // frame that fails any of the three moves nothing.
  function automatic logic [HEAD_W-1:0] head_want(input logic [PAYLOAD_W-1:0] v);
    head_want                     = '0;
    head_want[HEAD_W-MARK_W-1]    = ^v;
    head_want[HEAD_W-1 -: MARK_W] = MARK;
  endfunction

  // ------------------------------------------------------------------------
  // The sender
  // ------------------------------------------------------------------------
  //
  // Eight beats `BEAT_T` apart, then `GAP_T` of silence, for ever.  **The
  // snapshot is taken once**, at the first beat, so the frame is one
  // consistent set of levels and never a mixture of two --- see the header.
  // Free running rather than sent on a change, because a receiver that has
  // just come up must be told the levels without the far end having to do
  // anything, and because a constant frame rate is a constant delay.

  logic [SLOTS-1:0]  tx_frame;
  logic [BEAT_W-1:0] tx_beat;
  logic [TT_W-1:0]   tx_t;
  logic              tx_gap;

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_stb   <= 1'b0;
      tx_d     <= '0;
      tx_frame <= '0;
      tx_beat  <= '0;
      // Out of reset the line is quiet for a gap, so that a receiver already
      // running sees a frame boundary before it sees a beat.
      tx_gap   <= 1'b1;
      tx_t     <= TT_W'(GAP_T - 1);
    end else if (tx_t != '0) begin
      tx_t <= tx_t - 1'b1;
    end else if (tx_gap) begin
      tx_frame <= {frame_out[SLOTS-LINES-1:0], {LINES{1'b0}}};
      tx_d     <= frame_out[SLOTS-1 -: LINES];
      tx_stb   <= ~tx_stb;
      tx_beat  <= BEAT_W'(1);
      tx_gap   <= 1'b0;
      tx_t     <= TT_W'(BEAT_T - 1);
    end else if (tx_beat != BEAT_W'(BEATS)) begin
      tx_frame <= {tx_frame[SLOTS-LINES-1:0], {LINES{1'b0}}};
      tx_d     <= tx_frame[SLOTS-1 -: LINES];
      tx_stb   <= ~tx_stb;
      tx_beat  <= tx_beat + 1'b1;
      tx_t     <= TT_W'(BEAT_T - 1);
    end else begin
      // The last beat's levels stay on the lines through the gap.  Nothing
      // here clears them: this cable carries levels and a carrier that
      // cleared its lines would write the wrong word into the debuggee's
      // address latch, which takes `DBD` at the trailing edge of its strobe.
      tx_gap <= 1'b1;
      tx_t   <= TT_W'(GAP_T - 1);
    end
  end

  // ------------------------------------------------------------------------
  // The receiver
  // ------------------------------------------------------------------------

  logic [1:0]        stb_s;     // the strobe, through two flops
  logic              stb_q;     // and as it was last tick
  logic              change;
  logic [SLOTS-LINES-1:0] rx_frame;
  logic [BEAT_W-1:0] rx_beat;
  logic [IDLE_W-1:0] idle_t;
  logic [LOSS_W-1:0] loss_t;

  assign change = (stb_s[1] != stb_q);

  // The frame as it would stand with this beat shifted in, and whether it is
  // the last beat and whether what it completes is a frame.  Read of
  // `rx_d` straight from the pins: see the header for why that is a sample
  // and not a race.
  logic [SLOTS-1:0] rx_next;
  logic             complete, good;
  assign rx_next  = {rx_frame, rx_d};
  assign complete = change && (rx_beat == BEAT_W'(BEATS - 1));
  assign good     = (rx_next[SLOTS-1:PAYLOAD_W] == head_want(rx_next[PAYLOAD_W-1:0]));

  always_ff @(posedge clk) begin
    if (rst) begin
      stb_s     <= 2'b00;
      stb_q     <= 1'b0;
      rx_frame  <= '0;
      rx_beat   <= '0;
      // Saturated, so that this end starts out believing it is between
      // frames and takes the next transition as beat zero.
      idle_t    <= IDLE_W'(GAP_MIN);
      loss_t    <= LOSS_W'(LOSS_T);
      rx_levels <= '0;
      rx_live   <= 1'b0;
    end else begin
      stb_s <= {stb_s[0], rx_stb};
      stb_q <= stb_s[1];

      if (change) begin
        idle_t   <= '0;
        rx_frame <= rx_next[SLOTS-LINES-1:0];
        rx_beat  <= complete ? BEAT_W'(0) : (rx_beat + 1'b1);
      end else if (idle_t != IDLE_W'(GAP_MIN)) begin
        idle_t <= idle_t + 1'b1;
      end else begin
        // The gap: whatever arrives next is beat zero.
        rx_beat <= '0;
      end

      if (complete && good) begin
        rx_levels <= rx_next[PAYLOAD_W-1:0];
        rx_live   <= 1'b1;
        loss_t    <= '0;
      end else if (loss_t != LOSS_W'(LOSS_T)) begin
        loss_t <= loss_t + 1'b1;
      end else begin
        // The far end has stopped.  This is the SIP at DBGIN 0A22 pulling
        // `-DEBUG IN REQ` up when somebody pulls the cable out, and it is
        // what stops a request standing for ever on a connector that is no
        // longer connected to anything.
        rx_levels <= '0;
        rx_live   <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
