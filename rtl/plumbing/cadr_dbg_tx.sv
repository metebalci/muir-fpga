// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT's debug cable over four pins: the sender.
//
// The debug cable joins two CADRs.  The debugger drives `-DEBUG IN REQ`,
// `DEBUG IN WR`, `DEBUG IN A<1:0>` and `DBD<15:0>` at the debuggee, and the
// debuggee answers with `DEBUG IN ACK` and `DBD<15:0>`.  MIT carries that on
// twenty-one wires, sixteen of them a bus the two ends share through
// transceivers.  A Pmod connector has eight signal pins, so a cable between
// two of these boards is four pins each way, and this module is what puts one
// direction's levels on its four.  `rtl/plumbing/cadr_dbg_rx.sv` is the other
// half and takes them off again.
//
// **TWO OF THOSE FOUR PINS CARRY SIGNALS AND TWO ARE GUARDS**, which is why
// `LINES` is one and not three.  The high-speed Pmod headers on these boards
// route their pins as coupled pairs --- 1 with 2, 3 with 4, 7 with 8, 9 with
// 10 --- so a row driven single-ended has an edge on one line coupling into
// its partner, and the partner may be the strobe.  This link therefore puts
// one signal on each pair and drives the other line of it LOW: the strobe
// alone on the first pair of a group and one data line alone on the second.
// The pin map is `rtl/plumbing/cadr_dbg_cable.sv`'s and the guards never
// reach this module; what reaches it is `LINES`, and one data line is what
// makes the frame twenty-four beats.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE.**  muir has the cable, and
// `rtl/machine/cadr_dbgin.sv` is held to it tick for tick; muir has no
// serialiser, because a model with no wires needs none.  What holds this is a
// property --- what goes in one end comes out the other, unchanged, in
// bounded time --- and that is why it is here and not in `rtl/machine/`, the
// same footing `cadr_axi_master.sv` and `cadr_debug_window.sv` are on.
//
// **WHY THE SENDER AND THE RECEIVER ARE TWO MODULES.**  They were one, and
// the connector above them needs them apart: a board listens on BOTH pin
// groups while it works out which way the cable is wired, and it must hear
// nothing of its own on the group it is driving.  Every pad is an `inout` and
// a driven pad reads back what this board put on it --- `cadr_arty.sv`'s
// `assign ja[i] = ja_t[i] ? 1'bz : ja_o[i]` is a wire and not a one-way
// street --- so the receiver on a group this board drives has to be held
// quiet, and holding it quiet must not stop the sender that is driving it.
// One reset each is the whole of the difference; nothing about the frame
// changed when they were split.
//
// ## The frame
//
// `PAYLOAD_W` signals cross each way.  A frame must also say that it IS a
// frame, because an unplugged connector reads as a constant and a constant is
// indistinguishable from a payload that happens to be all ones or all zeros.
// The project's own answer to that is a two-bit marker reading `01`: all
// zeros gives `00` and all ones gives `11`, so neither can be mistaken for a
// word.  `cadr_debug_window.sv` uses it in `STS` for the same reason.
//
// So a frame is `PAYLOAD_W + 3` bits at least --- the marker and a parity bit
// --- and at twenty-one over ONE line that is twenty-four beats, twenty-four
// slots with nothing over.  **That is the beat count: twenty-four, each
// way**, a frame of `24 * BEAT_T + GAP_T` ticks, which is 162 at the
// defaults.  It was eight beats and sixty-six ticks over three lines, and
// three lines a group is what the coupled pairs took away.
//
// **THE PARITY IS OVER THE WHOLE PAYLOAD AND CATCHES WHAT THE MARKER CANNOT.**
// The marker says a frame is a frame; it says nothing about the bits under
// it, so one line shorted, one beat sampled at the wrong instant or one bit
// flipped in the cable would arrive as a level and be taken.  Any odd number
// of bits wrong in the payload moves nothing at the far end and the previous
// levels stand, which is the same refusal a bad marker gets.  It is not a
// code that can correct anything, and it should not be: the far end sends the
// levels again one frame later, so refusing a frame costs one frame.
//
// **THERE WAS A ZERO FILL ONCE AND AT ONE DATA LINE THERE CANNOT BE ONE.**
// The frame is `PAYLOAD_W + 3` slots exactly when `LINES` is one, so the head
// is the marker and the parity bit and nothing else, at every payload.  The
// fill survives in the source because it is what lets the head be one
// expression rather than three cases, and it is unreachable in every
// configuration any board builds.  Nothing checks it and nothing can; saying
// so here is cheaper than leaving it to be found from a mutation that
// survives.
//
// It mattered while a group carried three data lines.  Twenty payload bits
// left a slot over then, and the connector spent it on the sender's ROLE ---
// `engaged`, whether the board that sent this frame is the DEBUGGER --- which
// is what lets two boards tell a debugger's frames from an idle debuggee's,
// diagnoses a crossed cable, and stops two idle boards holding each other's
// carriers up.  What that cost was the fill bit and one payload bit both wrong
// at once, which the parity reads as even.  The trade is recorded because the
// bit is still in the payload and the reason for it is not obvious from the
// code.
//
// ## The gap is the frame marker
//
// A receiver with no clock has to know which beat is beat zero.  It is told
// by the silence: the sender emits its beats back to back, `BEAT_T` ticks
// apart, and then leaves the lines alone for `GAP_T`.  That costs no wire and
// no slot, and it resynchronises a receiver that has just come up, or that has
// been reset while this end kept running, within one frame.
//
// The marker and the gap catch different things and both are kept.  The gap
// aligns the frame; the marker says whether what arrived in it was a frame at
// all.
//
// ## What crosses is levels, and the frame is atomic
//
// The cable carries no events.  Every decision `cadr_dbgin.sv` makes is made
// from a level that is standing, and its two latches take `DBD<15:0>` at the
// trailing edge of their own strobe.  So the carrier's promise is that a level
// put in at one end stands at the other until it is replaced --- never
// cleared, never pulsed.
//
// **AND A FRAME IS PRESENTED WHOLE OR NOT AT ALL**, which is the promise that
// matters most.  `cadr_debug_window.sv`'s header names three hazards the
// cable has no defence against: a late address bit makes the 74S139 decode the
// wrong strobe, a late data line is latched instead of the intended word, and
// a write flag that moves inside a request inverts the cycle.  The window
// answers all three by making a request one 32-bit store.  A carrier that
// delivered a frame bit by bit would hand every one of them back.  So this end
// takes its snapshot once, at the frame's first beat, and the receiver moves
// its outputs once, at the last.
//
// ## What this module does not carry
//
// Nothing about the cable's ROLE, beyond sending whatever bit the connector
// packs.  The payload is a vector and which bit is `-DEBUG IN REQ` is decided
// where it is packed, so one module serves both ends of the cable and a check
// can put a sender and a receiver back to back and get one direction of it.

`default_nettype none

module cadr_dbg_tx #(
    // The cable's levels, in one direction.  Twenty-one at both ends of the
    // connector: the debugger's `{ENGAGED, REQ, WR, A<1:0>, DBD<15:0>}` and
    // the debuggee's `{ENGAGED, spare, ACK, DRIVEN<1:0>, DBD<15:0>}`.
    parameter int unsigned PAYLOAD_W = 21,
    // Data lines a direction.  ONE, because the four pins of a group are two
    // coupled pairs and this link puts one signal on each: the strobe on one
    // pair and this data line on the other, with the partner of each driven
    // low as a guard.  See the header.
    parameter int unsigned LINES     = 1,
    // Ticks a beat.  What this buys is the margin either side of the instant
    // the receiver samples the data lines; `cadr_dbg_rx.sv` has the sum.
    parameter int unsigned BEAT_T    = 6,
    // Ticks of silence between frames.  `BEAT_T < GAP_MIN < GAP_T` at the
    // receiver, with room either side for a tick of sampling jitter.
    parameter int unsigned GAP_T     = 18
) (
    input  var logic                 clk,   // 100 MHz, one tick = 10 ns
    input  var logic                 rst,

    // --- the cable's levels, as this end has them
    input  var logic [PAYLOAD_W-1:0] tx_levels,

    // --- the connector.  One strobe and one data line; the two guard pins
    // --- of the group are the connector's and never reach this module.
    output var logic                 tx_stb,
    output var logic [LINES-1:0]     tx_d
);

  // The marker, and the frame it forces.  Two bits reading `01`, so that a
  // connector reading all zeros and one reading all ones are both refused ---
  // muir's `fabric::MARK`, and `cadr_debug_window.sv`'s `STS`.
  localparam int unsigned          MARK_W = 2;
  localparam logic [MARK_W-1:0]    MARK   = 2'b01;

  localparam int unsigned BEATS  = (PAYLOAD_W + MARK_W + 1 + LINES - 1) / LINES;
  localparam int unsigned SLOTS  = BEATS * LINES;
  localparam int unsigned BEAT_W = $clog2(BEATS + 1);
  localparam int unsigned TT_W   = $clog2((GAP_T > BEAT_T ? GAP_T : BEAT_T) + 1);

  // The frame this end would send if it started one now: the marker at the
  // top, the parity under it, the payload at the bottom, and zero fill in
  // between if the payload does not reach.  Built whole rather than
  // concatenated, so that a setting with no fill at all --- which is what the
  // connector's own twenty-one is --- is not a special case in the source.
  logic [SLOTS-1:0] frame_out;
  always_comb begin
    frame_out                      = '0;
    frame_out[PAYLOAD_W-1:0]       = tx_levels;
    frame_out[SLOTS-MARK_W-1]      = ^tx_levels;
    frame_out[SLOTS-1 -: MARK_W]   = MARK;
  end

  // ------------------------------------------------------------------------
  // The sender
  // ------------------------------------------------------------------------
  //
  // `BEATS` beats `BEAT_T` apart, then `GAP_T` of silence, for ever.  **The
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

endmodule

`default_nettype wire
