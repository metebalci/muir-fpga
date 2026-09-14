// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Two debuggers at one DBGIN page, and the rule that keeps them apart.
//
// `rtl/machine/cadr_dbgin.sv` is this machine's debuggee end, and on MIT's
// board exactly one cable reaches it, because there is exactly one DBGIN
// connector.  This board has two ways in: `rtl/plumbing/cadr_debug_window.sv`,
// which is muir on this board's own Arm cores, and the Pmod connector, which
// is a second board.  Both drive the same twenty wires and something has to
// say which.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE**, and there could not be one:
// it answers a question MIT's board cannot ask.  What holds it is a property.
//
// **THE RULE IS THE FIRST TO ASSERT HOLDS, UNTIL IT LIFTS.**  The cable is
// levels, so "a request is standing" is a level and the holder is one
// registered bit.  A tie goes to the window, which is the debugger that is
// always there.  Nothing pre-empts: a request cannot change hands halfway,
// which is the whole point.
//
// **AND HALFWAY IS WHERE THE DAMAGE WOULD BE.**  The three hazards
// `cadr_debug_window.sv` names --- a late address bit, a late data line, a
// write flag that moves inside a request --- are all reachable by simply
// OR-ing two debuggers together, which is the obvious way to write this and
// is wrong.  A modifier register that takes a stray one in bit 1 resets this
// machine and halts it, so a merge that can scramble a request is a merge
// that can halt the CADR because two debuggers happened to overlap.
//
// **THE SELECTION IS COMBINATIONAL AND THE HOLD IS REGISTERED**, which is not
// the same as registering the selection.  A request appearing at an idle
// cable must be carried on the tick it appears, or the levels would lag the
// request by a tick and `cadr_dbgin.sv`'s decode, which is a decode and not a
// register, would see the request with the previous holder's address bits.
// So `sel` follows the requests while the cable is idle and follows the
// registered holder while it is not.
//
// The holder is released a tick after the request falls rather than on the
// same tick, and that tick is load-bearing.  `cadr_dbgin.sv` latches `DBD` at
// the edge AFTER the one that dropped the request, so the holder's levels
// must still be on the cable then.  Releasing on the fall would put the other
// debugger's levels under that latch.

`default_nettype none

module cadr_dbg_join (
    input  var logic        clk,
    input  var logic        rst,

    // --- the local debugger: `cadr_debug_window.sv` on a general-purpose port
    input  var logic        a_req,
    input  var logic        a_wr,
    input  var logic [1:0]  a_a,
    input  var logic [15:0] a_dbd,

    // --- the debugger on the connector, off `cadr_dbg_rx.sv`.  An
    // --- unplugged connector presents zeros, so it never asks.
    input  var logic        b_req,
    input  var logic        b_wr,
    input  var logic [1:0]  b_a,
    input  var logic [15:0] b_dbd,

    // --- the cable, as `cadr_dbgin.sv` sees it
    output var logic        req,
    output var logic        wr,
    output var logic [1:0]  a,
    output var logic [15:0] dbd,

    // --- which of the two has it: 0 the window, 1 the connector
    output var logic        holder
);

  logic busy;   // a request was standing last tick
  logic held;   // and this is who had it

  logic sel;
  assign sel = busy ? held : (a_req ? 1'b0 : 1'b1);

  assign req    = sel ? b_req : a_req;
  assign wr     = sel ? b_wr  : a_wr;
  assign a      = sel ? b_a   : a_a;
  assign dbd    = sel ? b_dbd : a_dbd;
  assign holder = sel;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      held <= 1'b0;
    end else begin
      busy <= req;
      held <= sel;
    end
  end

endmodule

`default_nettype wire
