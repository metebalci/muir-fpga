// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT's debug cable over four pins: the receiver.
//
// `rtl/plumbing/cadr_dbg_tx.sv` is the sender and its header has the frame,
// the gap, the marker and the parity, and why the two are separate modules.
// This is the other half: two pins in --- a strobe and one data line, the
// other two of the group being guards this module never sees --- the levels
// that were put on them at the far end out, and two questions about the
// connector beside them.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE**, for the sender's reason.
// What holds it is a property, in `build/dbg_pmod.pass`.
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
// `BEAT_T` minus three more.  At the default six that is twenty nanoseconds of
// margin on the early side and thirty on the late, against a cable and a pad
// that contribute single-digit nanoseconds.  The strobe is the only thing on
// this cable that is synchronized, and the only thing that needs to be.
//
// ## Two questions, and they are not the same question
//
// `rx_live` is whether a GOOD FRAME has arrived lately: the marker and the
// parity check --- and the fill too, where a setting leaves one --- and the far
// end has not since gone quiet.  It is what the DBGOUT page asks before it
// waits for an answer.
//
// `rx_active` is whether anything is DRIVING these four pins at all, good
// frame or not --- a strobe transition within the same `LOSS_T`.  It is what
// the connector asks before it enables a pad, because a group being driven
// with nothing sensible under it is still somebody else's driver, and two
// drivers on one wire is the failure the whole one-connector design is
// arranged to prevent.  A board that took the second question for the first
// would drive over a neighbor that was merely sending badly.
//
// **BOTH COME OUT OF RESET SAYING NOTHING HAS BEEN HEARD**, which is not a
// detail.  The connector holds this module in reset for as long as the board
// is driving the group it is watching --- a driven pad reads back what this
// board put on it --- so reset is also how a board FORGETS a group it has
// been driving, and a value that came out of reset meaning "somebody is
// there" would be a board claiming a pin group on the strength of its own
// echo.
//
// ## Counting what arrives, and why anybody would
//
// **THE HIGH-SPEED PMODS ON THESE BOARDS ROUTE THEIR PINS AS COUPLED PAIRS,
// AND THE LINK IS ARRANGED SO THAT NO PAIR CARRIES TWO SIGNALS.**  Pins 1 and
// 2 are a pair, 3 and 4, 7 and 8, and 9 and 10, with 0-ohm shunts where a
// differential termination would go.  A row driven single-ended has an edge on
// one line coupling into its partner, and the partner may be the STROBE, which
// is the one thing on this cable a false edge can hurt.  So the strobe has a
// pair to itself and the data line the other, with the even line of each
// driven LOW as a guard --- `rtl/plumbing/cadr_dbg_cable.sv` has the pin map.
// One data line is what makes the frame twenty-four beats where three made it
// eight.
//
// **THE COUNTERS ARE KEPT, BECAUSE A GUARDED PAIR IS AN ARGUMENT AND NOT A
// MEASUREMENT.**  Nothing has been measured on a board either way, and a false
// beat still misaligns the frame it lands in whatever made it.  What that
// costs is bounded and is not a wrong word: a misaligned frame fails its
// marker or its parity, moves nothing, and the levels stand until the next
// frame carries them again one frame later.  So a bad cable is LOST FRAMES and
// never wrong values --- unless it is frequent, and how frequent is a number
// nobody has.  `frame_done` and `frame_bad` are that number: count them both
// and read the ratio.
//
// ## An unplugged connector, and one that goes away
//
// With nothing plugged in, no transition ever arrives, no frame is ever taken,
// and `rx_levels` stands at zero with `rx_live` and `rx_active` down.  Zero is
// the idle cable in both directions: `-DEBUG IN REQ` up, which is `dbg_in_req`
// low in the sense the whole transport uses, and `DEBUG IN ACK` down with
// neither byte driven.  `cadr_arty.sv` already ties the cable off that way on
// a board with no processing system and says why, and this reads the same.
//
// A cable pulled out while a request stands is the case that needs a timer.
// The levels would otherwise stand for ever, `-DB NEED UB` would stay down,
// and the debug master would keep the debuggee's Unibus --- the wedged bus
// `cadr_debug_window.sv`'s watchdog exists for, one level further out.  On a
// real lashup the SIP at DBGIN 0A22 pulls the request up when the connector is
// pulled; here `LOSS_T` ticks with no good frame does it, and `rx_live` says
// so.  It is not a bound on a transaction and cannot be: frames are free
// running, so it fires only when the far end stops sending.

`default_nettype none

module cadr_dbg_rx #(
    // The cable's levels, in one direction.  `cadr_dbg_tx.sv`'s header has
    // what the twenty-one are.
    parameter int unsigned PAYLOAD_W = 21,
    // Data lines a direction.  ONE: the four pins of a group are two coupled
    // pairs and this link puts one signal on each, the strobe on one and this
    // line on the other.  See the header and `cadr_dbg_tx.sv`'s.
    parameter int unsigned LINES     = 1,
    // The silence this end treats as being between frames.  It is the only
    // one of the sender's three intervals this end needs: `BEAT_T < GAP_MIN <
    // GAP_T`, so a gap is told from a beat with a tick of sampling jitter
    // either side, and the beat and the gap themselves are the sender's.
    parameter int unsigned GAP_MIN   = 12,
    // Ticks with no good frame before the far end is taken to be gone.  Free
    // running frames arrive every `BEATS * BEAT_T + GAP_T`, 162 ticks at the
    // defaults, so this is six of them and fires only when they stop.
    parameter int unsigned LOSS_T    = 1024,
    // And ticks with no TRANSITION before nothing is taken to be driving these
    // pins, which is a different question and wants a different number.
    //
    // **IT IS SHORT ON PURPOSE, AND THE LENGTH IS LOAD-BEARING.**  A sender
    // free-runs, so a gap longer than one frame means nobody is there --- two
    // frames is a bound with a whole frame of margin, where `LOSS_T` is six.
    // The connector overrides this parameter with two frames of the frame it
    // is actually sending, which is 324 ticks at twenty-four beats.  What the
    // difference costs was measured: the connector will not drive a group
    // anything else is driving, so a board waits out THIS
    // interval before it may answer on a group the far end has stopped
    // driving.  At `LOSS_T` that wait is longer than a probe and a cable that
    // was being hunted for never came up.
    parameter int unsigned ACT_T     = 256
) (
    input  var logic                 clk,   // 100 MHz, one tick = 10 ns
    input  var logic                 rst,

    // --- the connector.  One strobe and one data line; the group's two
    // --- guard pins are the connector's and never reach this module.
    input  var logic                 rx_stb,
    input  var logic [LINES-1:0]     rx_d,

    // --- what was put on them at the far end, and the two questions
    output var logic [PAYLOAD_W-1:0] rx_levels,
    output var logic                 rx_live,
    output var logic                 rx_active,

    // --- and two one-tick terms for whoever is counting.  A frame ARRIVED,
    // --- whatever its checks said, and a frame was REFUSED --- the marker or
    // --- the parity wrong.  See the header: on these boards the two numbers
    // --- together are how often a bad cable costs a frame.
    output var logic                 frame_done,
    output var logic                 frame_bad
);

  localparam int unsigned          MARK_W = 2;
  localparam logic [MARK_W-1:0]    MARK   = 2'b01;

  localparam int unsigned BEATS  = (PAYLOAD_W + MARK_W + 1 + LINES - 1) / LINES;
  localparam int unsigned SLOTS  = BEATS * LINES;
  // The marker, the parity bit and the zero fill together: everything above
  // the payload.  The marker is at the top, the parity bit under it, and the
  // fill under that, so a payload that fills the frame exactly is not a
  // special case.  **AT ONE DATA LINE THERE IS NEVER A FILL**, the frame being
  // the payload, the marker and the parity bit exactly, so `HEAD_W` is three
  // in every configuration any board builds and the fill is unreachable.  It
  // is kept because it is what makes the head one expression rather than three
  // cases; nothing checks it and nothing can, and saying so is cheaper than
  // leaving somebody to find that out from a mutation that survives.
  localparam int unsigned HEAD_W = SLOTS - PAYLOAD_W;
  localparam int unsigned BEAT_W = $clog2(BEATS + 1);
  localparam int unsigned IDLE_W = $clog2(GAP_MIN + 1);
  localparam int unsigned LOSS_W = $clog2(LOSS_T + 1);
  localparam int unsigned ACT_W  = $clog2(ACT_T + 1);

  // What the head of a frame must read for this end to take it: the marker,
  // the parity of the payload UNDER it, and any fill as zero.  A frame that
  // fails any of the three moves nothing.
  function automatic logic [HEAD_W-1:0] head_want(input logic [PAYLOAD_W-1:0] v);
    head_want                     = '0;
    head_want[HEAD_W-MARK_W-1]    = ^v;
    head_want[HEAD_W-1 -: MARK_W] = MARK;
  endfunction

  logic [1:0]        stb_s;     // the strobe, through two flops
  logic              stb_q;     // and as it was last tick
  logic              change;
  logic [SLOTS-LINES-1:0] rx_frame;
  logic [BEAT_W-1:0] rx_beat;
  logic [IDLE_W-1:0] idle_t;
  logic [LOSS_W-1:0] loss_t;
  logic [ACT_W-1:0]  act_t;

  assign change = (stb_s[1] != stb_q);

  // The frame as it would stand with this beat shifted in, and whether it is
  // the last beat and whether what it completes is a frame.  `rx_d` is read
  // straight from the pins: see the header for why that is a sample and not a
  // race.
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
      act_t     <= ACT_W'(ACT_T);
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

      // Anything at all on these pins, which is the second question.  A
      // transition, not a frame: the count runs from the last edge and
      // saturates, and the saturated value is what "nobody is driving this"
      // reads as.
      if (change) act_t <= '0;
      else if (act_t != ACT_W'(ACT_T)) act_t <= act_t + 1'b1;

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

  assign rx_active = (act_t != ACT_W'(ACT_T));

  // A frame arrived, and whether it was taken.  One tick each, at the beat
  // that completes it: what counts them is the connector, which knows which
  // groups this board is listening to.
  assign frame_done = complete;
  assign frame_bad  = complete && !good;

endmodule

`default_nettype wire
