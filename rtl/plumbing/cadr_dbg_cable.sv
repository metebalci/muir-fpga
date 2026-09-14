// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT's debug cable on ONE Pmod connector, and which end of it this board is.
//
// A CADR is debugged by another CADR.  The debugger's DBGOUT page drives
// `-DEBUG IN REQ`, `DEBUG IN WR`, `DEBUG IN A<1:0>` and `DBD<15:0>` at the
// debuggee's DBGIN page, and the debuggee answers with `DEBUG IN ACK` and
// `DBD<15:0>`.  `rtl/plumbing/cadr_dbg_pmod.sv` is the carrier that puts one
// direction of that on four pins.  This module is the CONNECTOR: it puts one
// carrier on the eight pins of one Pmod header, decides which four of them
// this board drives, and says which of the two machines on the cable this one
// is.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE.**  muir has the cable and no
// wires, and it has no notion of a board that is a debugger at one moment and
// a debuggee at the next: `Rtl::attach_debug_cable` is a thing done to a
// machine when a lashup is built.  What holds this is a property, and it is
// why the module is here and not in `rtl/machine/`.
//
// ## One connector, and what that forces
//
// The cable is ONE header, JA.  Both directions cross it, four pins each,
// and the second header carries nothing: a board is a debugger or a debuggee
// on this cable and never both at once, so a second connector would buy only
// the case of a board debugging one machine while another debugs it, which
// the register window already covers --- muir on this board's own Arm cores
// reaches the DBGIN page whatever the connector is doing.
//
// **WHAT ACTUALLY CROSSES IS TWENTY OUT AND NINETEEN BACK, COUNTED OFF THE
// NETLIST.**  MIT's cable is twenty-one wires: four out --- `-DEBUG OUT REQ`,
// `DEBUG OUT WR` and `DEBUG OUT A<1:0>`, which the 74S241 at DBGOUT 0A17
// drives --- sixteen shared, `DBD<15:0>`, and `DEBUG OUT ACK` back.  The bus
// enable and its direction are NOT on it: `-DBD ENB` and `-DEBUG > UD` are
// pins 9 and 11 of the two Am8304s at DBGOUT 0B21 and 0B22, and
// `data/BUSINT.netlist` shows them made on the debugger's own board by the
// 74S02 at 0B12 and the 74S51 at 0B11 out of `DEBUG ACTIVE`, `DBUB MASTER`
// and the write line.  An earlier count of twenty-two outgoing signals
// included them and was wrong.
//
// Un-sharing the sixteen for a carrier with no bus on it gives twenty out ---
// the four and the data --- and nineteen back: the acknowledgement, the data,
// and TWO BITS SAYING WHICH BYTES OF IT THIS END DRIVES.  Those two are why
// the return is nineteen and not seventeen: `-DB READ STATUS` drives only
// `DBD<7:0>` and MIT's cable carries the byte above it on pull-ups that a
// Pmod ribbon does not have, so the resolution has to be told.  The payload
// is twenty each way and the return's spare bit goes out as zero.
//
// **A STRAIGHT CABLE IS WHAT DECIDES THE PIN GROUPS.**  A Pmod ribbon joins
// pin one to pin one, so a cable from one board's JA to another's JA maps
// each pin to the SAME pin at the far end.  The four low pins are therefore
// the DEBUGGER's --- it drives them and the debuggee listens --- and the four
// high pins the DEBUGGEE's.  Neither group is ever driven from both ends
// while the two boards hold different roles, which is what makes this full
// duplex with no shared pin rather than a bus that has to be turned around.
//
// **AND THE ROLES MUST DIFFER, SO SOMETHING HAS TO ENFORCE IT.**  Two
// questions, and each has one answer here.
//
//   Two debuggees, which is what two boards cabled together and nothing set
//   ARE: neither may drive the return group, or both would.  A debuggee
//   therefore drives nothing until it hears a debugger --- `rx_active`, a
//   strobe transition on the forward group within `LOSS_T` --- and a board
//   with no cable in it drives nothing at all, for ever.  The cost is one
//   frame of silence at the start of a session and the gain is that the
//   power-on state of any two boards is safe.
//
//   Two debuggers, which is a person telling both boards to connect: the
//   second may not take the role.  It cannot, because `foreign` --- the
//   forward group live while this board is not the one driving it --- holds
//   `engaged` down, and the console has the bit to say why.  **The first
//   board told wins**, which is the only rule that can be enforced from one
//   end.
//
// ## Every board is a debuggee and nothing has to be set
//
// `engaged` comes up clear out of reset, so a board with a cable in it and
// nothing said is a debuggee: it answers a debugger on the connector as MIT's
// board answers one on its DBGIN.  `connect` makes it the debugger instead,
// and the connector alone changes hands --- the DBGIN page is never switched
// off, because the register window is a debugger too and this board stays
// debuggable through it while it debugs somebody else.
//
// **THE ROLE MAY NOT CHANGE UNDER A CYCLE.**  `engaged` rises only with the
// forward group quiet and no request standing at either end, and falls only
// with this board's own request down.  A debug cycle is a level held for its
// whole length at both ends, so a role changing inside one would leave the
// far end waiting on a cable that had stopped answering --- which its own
// interface would end at `busint::DEBUG_TIMEOUT_NS`, 11.05 microseconds, but
// as a timeout rather than as an answer.  Refusing the change is cheaper than
// explaining it, and the console reports the refusal rather than queueing it.
//
// ## What an unplugged cable reads as, and why it is ones
//
// `-DB READ STATUS` enables an octal driver onto `DBD<7:0>` at the debuggee
// and nothing drives the byte above it; the cable's own pull-ups carry it,
// which is why `Rtl::try_debug_request` answers `0xff00 | status`.  So the
// return frame carries the two byte enables beside the sixteen lines and the
// resolution is here, at the debugger's end of the cable, where the SIP at
// DBGIN 0A22 is on the board.  A byte nobody drives reads as ones.
//
// **AND A CABLE WITH NOTHING AT THE FAR END IS THE SAME PICTURE ONE STEP
// FURTHER.**  No frames arrive, `out_live` is down, and `out_dbd_in` stands
// at all ones --- the whole sixteen undriven, which is what an open connector
// is.  `rtl/machine/cadr_busint_regs.sv` answers its own machine's cycle at
// once when that is so, which is muir's own no-cable arm: "With no cable the
// pull-up answers at `-UB MSYN`."  So an unplugged cable is not an error
// anybody has to handle; it is a debuggee that answers every strobe
// immediately with ones, and CC sees the machine it cannot reach.

`default_nettype none

module cadr_dbg_cable #(
    // The carrier's own four, passed through so that a check may shrink them.
    parameter int unsigned BEAT_T  = 6,
    parameter int unsigned GAP_T   = 18,
    parameter int unsigned GAP_MIN = 12,
    parameter int unsigned LOSS_T  = 1024
) (
    input  var logic        clk,      // 100 MHz, one tick = 10 ns
    input  var logic        rst,      // the BOARD's reset, never the machine's

    // --- the role.  `connect` is the console's word and the fpgarc line;
    // --- `engaged` is whether this board took it, and the three below say
    // --- what the connector looks like to somebody asking why.
    input  var logic        connect,
    output var logic        engaged,
    output var logic        foreign,  // somebody else is the debugger here
    output var logic        live,     // good frames are arriving
    output var logic        active,   // the far end is driving its group

    // --- the DBGOUT page, `rtl/machine/cadr_busint_regs.sv`: this board's own
    // --- machine as the debugger, which is CC writing `0o766100`-`0o766137`
    input  var logic        out_req,
    input  var logic        out_wr,
    input  var logic [1:0]  out_a,
    input  var logic [15:0] out_dbd,
    output var logic        out_ack,
    output var logic [15:0] out_dbd_in,  // the lines, resolved: see the header
    output var logic        out_live,    // a cable with a board at the far end

    // --- the DBGIN page's far arm, `rtl/machine/cadr_dbgin.sv` through
    // --- `rtl/plumbing/cadr_dbg_join.sv`: a second board's debugger arriving
    // --- here.  Zero while this board is the debugger, the connector being
    // --- the other way round then.
    output var logic        in_req,
    output var logic        in_wr,
    output var logic [1:0]  in_a,
    output var logic [15:0] in_dbd,
    input  var logic        in_ack,
    input  var logic [15:0] in_dbd_out,
    input  var logic [1:0]  in_dbd_oe,

    // --- the connector.  `pin_t` is the pad's tri-state enable in Xilinx's
    // --- sense: HIGH is not driven.
    output var logic [7:0]  pin_o,
    output var logic [7:0]  pin_t,
    input  var logic [7:0]  pin_i
);

  // The two groups of four, by role.  The strobe is the top pin of each
  // group and the three data lines are under it.
  localparam int unsigned FWD_STB = 3;   // the debugger drives these four
  localparam int unsigned RET_STB = 7;   // and the debuggee these

  // ---------------------------------------------------------------- the role
  //
  // `engaged` is the whole of it: one flop, which is why the console can read
  // the role back and get an answer about the connector rather than about
  // what it was last told.
  logic take, drop;
  assign take = connect && !engaged && !active && !in_req && !out_req;
  assign drop = !connect && engaged && !out_req;

  always_ff @(posedge clk) begin
    if (rst) engaged <= 1'b0;
    else if (take) engaged <= 1'b1;
    else if (drop) engaged <= 1'b0;
  end

  assign foreign = !engaged && active;

  // ------------------------------------------------------------- the carrier
  //
  // ONE carrier: what this end sends is its own half of the cable, and which
  // half that is follows the role.  The far end reads it by ITS role, and the
  // two are complementary, so a frame packed as a request is read as a
  // request and one packed as an answer is read as an answer.
  logic [19:0] tx_levels, rx_levels;
  logic        tx_en, rx_live;
  logic        tx_stb, rx_stb;
  logic [2:0]  tx_d, rx_d;

  // The debugger's twenty and the debuggee's, packed as
  // `tb/cadr_dbg_pmod_harness.sv` and `boards/arty-z7-20/cadr_arty.sv` pack
  // them.  The debuggee's top bit is spare and goes out as zero.
  assign tx_levels = engaged ? {out_req, out_wr, out_a, out_dbd}
                             : {1'b0, in_ack, in_dbd_oe, in_dbd_out};

  // A debuggee DRIVES only while it hears a debugger; a debugger drives
  // always, being the end that starts everything.  The carrier under this
  // free-runs either way: what `tx_en` gates is the pads, so a board that has
  // just heard a debugger joins mid-frame and the far end refuses that one
  // frame on its marker and its parity.  See the header.
  assign tx_en = engaged || active;

  cadr_dbg_pmod #(
      .PAYLOAD_W(20), .LINES(3),
      .BEAT_T(BEAT_T), .GAP_T(GAP_T), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) u_pmod (
      .clk(clk), .rst(rst),
      .tx_levels(tx_levels),
      .rx_levels(rx_levels), .rx_live(rx_live),
      .tx_stb(tx_stb), .tx_d(tx_d),
      .rx_stb(rx_stb), .rx_d(rx_d)
  );

  // ------------------------------------------------- is anybody out there
  //
  // `rx_live` is whether a GOOD FRAME has arrived lately, which is what the
  // DBGOUT page asks before it waits for an answer.  This is the other
  // question: whether the far end is driving the pins at all, good frame or
  // not.  It is the connector's and not the carrier's, because what it
  // decides is which pads THIS board drives --- and a strobe that is being
  // driven with nothing sensible under it is still somebody else's driver.
  //
  // The same `LOSS_T` the carrier uses, counted from a transition rather than
  // from a frame.  Two flops, because it is a pin and this board's clock is
  // not the far end's.
  localparam int unsigned ACT_W = $clog2(LOSS_T + 1);
  logic [1:0]          act_s;
  logic                act_q;
  logic [ACT_W-1:0]    act_t;
  always_ff @(posedge clk) begin
    if (rst) begin
      act_s <= 2'b00;
      act_q <= 1'b0;
      act_t <= ACT_W'(LOSS_T);
    end else begin
      act_s <= {act_s[0], rx_stb};
      act_q <= act_s[1];
      // **HELD SATURATED WHILE THIS BOARD IS THE DEBUGGER**, and that is not
      // tidiness.  A debugger listens to the RETURN group, so its timer would
      // be reset by the debuggee's own answers --- and the tick it stopped
      // being the debugger it would believe somebody was driving the FORWARD
      // group and start driving the return one, on top of the debuggee that
      // is still driving it.  Measured: four pads held from both ends for as
      // long as the timer took to run out.  What a board coming out of the
      // role knows about the connector is nothing, and nothing is what this
      // says.
      if (engaged) act_t <= ACT_W'(LOSS_T);
      else if (act_s[1] != act_q) act_t <= '0;
      else if (act_t != ACT_W'(LOSS_T)) act_t <= act_t + 1'b1;
    end
  end

  assign live   = rx_live;
  assign active = (act_t != ACT_W'(LOSS_T));

  // ------------------------------------------------------------ the eight pins
  //
  // The low four are the debugger's and the high four the debuggee's, so a
  // straight cable maps every driver to a listener.  A group this board does
  // not drive is high-impedance at the pad and so is its own group while it
  // is quiet, which is what keeps two debuggees off one another's lines.
  //
  // **AND A BOARD IN RESET DRIVES NOTHING**, which is not a detail: the
  // activity timer comes out of reset SATURATED --- nothing has been heard
  // --- and a pad enabled before it has been loaded is a board claiming a
  // group on the strength of a counter that has not run yet.  Two boards
  // reset together would both claim the return group and hold it until their
  // timers ran out, which the two-board check counted.
  logic drive_fwd, drive_ret;
  assign drive_fwd = engaged && !rst;
  assign drive_ret = !engaged && tx_en && !rst;

  always_comb begin
    pin_o = 8'h00;
    pin_t = 8'hFF;
    if (drive_fwd) begin
      pin_o[FWD_STB]     = tx_stb;
      pin_o[FWD_STB-1:0] = tx_d;
      pin_t[FWD_STB:0]   = 4'h0;
    end
    if (drive_ret) begin
      pin_o[RET_STB]     = tx_stb;
      pin_o[RET_STB-1:4] = tx_d;
      pin_t[RET_STB:4]   = 4'h0;
    end
  end

  // And what this end listens to is the other group.
  assign rx_stb = engaged ? pin_i[RET_STB]     : pin_i[FWD_STB];
  assign rx_d   = engaged ? pin_i[RET_STB-1:4] : pin_i[FWD_STB-1:0];

  // ------------------------------------------------- what comes off the cable
  //
  // A debugger reads answers and a debuggee reads requests, and the one it is
  // not reading is held at the idle cable rather than left to the payload:
  // zero is `-DEBUG IN REQ` up and `DEBUG IN ACK` down, and ones are the
  // undriven lines.
  assign in_req = !engaged && rx_live && rx_levels[19];
  assign in_wr  = !engaged ? rx_levels[18]    : 1'b0;
  assign in_a   = !engaged ? rx_levels[17:16] : 2'b00;
  assign in_dbd = !engaged ? rx_levels[15:0]  : 16'h0000;

  assign out_live = engaged && rx_live;
  assign out_ack  = out_live && rx_levels[18];
  // The two byte enables, resolved against the cable's pull-ups.  See the
  // header: a byte nobody drives reads as ones, and a cable with nothing at
  // the far end is all sixteen of them.
  assign out_dbd_in = out_live
                    ? {rx_levels[17] ? rx_levels[15:8] : 8'hFF,
                       rx_levels[16] ? rx_levels[7:0]  : 8'hFF}
                    : 16'hFFFF;

endmodule

`default_nettype wire
