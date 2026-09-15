// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT's debug cable on ONE Pmod connector: which end of it this board is, and
// which way round the ribbon was made.
//
// A CADR is debugged by another CADR.  The debugger's DBGOUT page drives
// `-DEBUG IN REQ`, `DEBUG IN WR`, `DEBUG IN A<1:0>` and `DBD<15:0>` at the
// debuggee's DBGIN page, and the debuggee answers with `DEBUG IN ACK` and
// `DBD<15:0>`.  `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` are the
// carrier that puts one direction of that on four pins.  This module is the
// CONNECTOR: it puts one sender and two receivers on the eight pins of one
// Pmod header, decides which four of them this board drives, and says which of
// the two machines on the cable this one is.
//
// **NO muir REFERENCE EXISTS FOR THIS MODULE.**  muir has the cable and no
// wires, and it has no notion of a board that is a debugger at one moment and
// a debuggee at the next: `Rtl::attach_debug_cable` is a thing done to a
// machine when a lashup is built.  What holds this is a property, and it is
// why the module is here and not in `rtl/machine/`.
//
// ## One connector, and what that forces
//
// The cable is ONE header --- JA on the Zynq boards, JB on the Arty A7-100,
// whose JA is a standard Pmod.  Both directions cross it, four pins each ---
// a strobe, one data line and the two GUARDS the section on the pin map below
// explains --- and the second header carries nothing: a board is a debugger or
// a debuggee on this cable and never both at once, so a second connector would
// buy only the case of a board debugging one machine while another debugs it,
// which the register window already covers --- muir on this board's own Arm
// cores reaches the DBGIN page whatever the connector is doing.
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
// Pmod ribbon does not have, so the resolution has to be told.
//
// **AND THE TWENTY-FIRST BIT EACH WAY IS THIS BOARD'S OWN ROLE.**  It is not
// MIT's and it is not the machine's: it says whether the board that sent this
// frame is the DEBUGGER, and it is what lets the far end tell a debugger
// driving the connector from an idle debuggee that happens to be reaching the
// same pins.  `cadr_dbg_tx.sv`'s header has what it cost --- the frame's zero
// fill --- and why the parity covers it.  Everything below that needs to know
// which kind of board is at the far end is this one bit.
//
// ## Which four pins are this board's, and which way the ribbon was made
//
// A Pmod ribbon is supposed to join pin one to pin one.  The four low pins are
// then the DEBUGGER's --- it drives them and the debuggee listens --- and the
// four high pins the DEBUGGEE's, and neither group is ever driven from both
// ends while the two boards hold different roles.  A group is four pins
// throughout this file: two carry the strobe and the data line and two are
// guards, and all four are enabled together, so everything said here about a
// board driving or listening to a group is about all four of them.  That is
// what makes this full duplex with no shared pin rather than a bus that has to
// be turned around.
//
// **A CABLE MADE FROM TWO HOST SOCKETS MIRRORS THE HEADER'S TWO ROWS, AND
// ONE WAS MEASURED ON THE BENCH.**  A 2x6 Pmod header has pins 1 to 6 in one
// row and 7 to 12 in the other, so a ribbon whose connector was pressed on the
// other way up joins each board's 1-4 to the other's 7-10, in order.  With
// that cable a debugger drives four pins the far board never listens to, and
// two idle boards can end up hearing each other's carriers and each reporting
// a debugger that is not there.  Both were measured on two boards on 14
// September; the cable was a manufactured extension and could not be
// re-crimped.
//
// So the wiring is a SETTING, `straight` or `crossover`, and `auto` is the
// default that looks for it:
//
//   **ONLY THE DEBUGGER APPLIES IT.**  A debuggee always drives the high four
//   and listens on the low four, whatever the setting says.  A debugger drives
//   the low four and listens on the high four when the cable is straight, and
//   the other way round when it is crossed.  One end compensating is what
//   straightens a crossed cable; two would cross it again.
//
//   **AND THE SETTING IS TAKEN WHEN THE ROLE IS TAKEN.**  `wire_q` latches it
//   at the take, so a setting that moved under a board that was already
//   debugging could not move the pins under a standing cycle.  The console
//   refuses the write for the same reason and the two are independent: the
//   console's refusal is what a person is told, and the latch is what the
//   fabric does whatever it is told.
//
// ## Finding the wiring: what a board hears while it is quiet
//
// Under `auto` a board that has just taken the role **drives nothing at all**
// for one frame and the carrier's loss interval, and listens on BOTH groups.
// It can, because there are two receivers and they are nailed to their own
// four pins.  What it hears names the cable:
//
//   idle frames --- a board saying it is a DEBUGGEE --- on the HIGH four is a
//   straight cable, because a debuggee drives the high four and a straight
//   ribbon lands them on the high four here;
//
//   the same frames on the LOW four is a crossover, because that is where the
//   far board's high four land when the rows are mirrored;
//
//   frames from a DEBUGGER on either group is the two-debuggers case, and the
//   board that was already driving keeps the role --- which the take's own
//   guard refuses in the first place;
//
//   and nothing at all is a cable with nothing at the far end, or a far board
//   that is a debuggee with nobody driving it, since a debuggee sends nothing
//   until it hears a debugger.
//
// **THE LAST OF THOSE IS THE COMMON CASE AND IS WHY THE FALLBACK MOVES.**  Two
// boards freshly reset are two silent debuggees whatever the cable is, so a
// board that listened, heard nothing and stood on `straight` for ever would
// never bring a crossed cable up --- it would drive four pins nobody listens
// to and report that nothing was answering.  So the fallback is straight and
// then, while nothing has answered, it ALTERNATES: one probe interval driving
// the low four, the next driving the high four, until the far end answers on
// the group this board is listening to.  An answer settles the wiring and the
// alternation stops.  The cost of being wrong is one probe interval; the cost
// of not alternating is a cable that never comes up without somebody setting
// the wiring by hand.
//
// **NOTHING IS DRIVEN BEFORE THE LISTENING IS OVER**, which is what makes the
// detection safe on a cable that IS crossed: a board that drove while it
// listened would be driving four pins whose far end it has not identified.
//
// ## And a board never drives a group somebody else is driving
//
// Every pad enable is gated on that group's receiver saying nothing is on it.
// That one rule is what keeps one connector with two roles safe in every
// arrangement, including the ones the role rules alone do not cover: two
// boards told to connect within the same listening interval, a probe that
// lands on a group the far end is still answering on, a debuggee whose
// debugger has not compensated for a crossed cable.  A group being driven with
// nothing sensible under it is still somebody else's driver, so the gate is
// the receiver's ACTIVITY and not its frames.
//
// **AND IT IS SELF-SUSTAINING ONCE IT STARTS, BY CONSTRUCTION.**  A receiver
// whose group this board drives is held in RESET --- every pad is an `inout`
// and a driven pad reads back what this board put on it --- so its activity
// reads as nothing for as long as the drive lasts and the gate cannot turn on
// the board's own echo.  That reset is also how a board FORGETS a group it has
// been driving: it comes out of it saying nothing has been heard, which is the
// only honest thing for a board that has been listening to itself to say.
//
// ## And the roles must differ, so something has to enforce it
//
//   Two debuggees, which is what two boards cabled together and nothing set
//   ARE: neither may drive the return group, or both would.  A debuggee
//   therefore drives nothing until it hears a DEBUGGER --- a good frame whose
//   role bit is set --- and a board with no cable in it drives nothing at all,
//   for ever.  The cost is one frame of silence at the start of a session and
//   the gain is that the power-on state of any two boards is safe.
//
//   **THE ROLE BIT IS WHAT MAKES THAT SAFE ON A CROSSED CABLE TOO.**  It used
//   to be a strobe transition, and two idle boards on a crossed ribbon then
//   answered each other's answers for ever: measured, and it left neither able
//   to take the debugger's role, because the take refused while anything was
//   driving the connector.  A frame that says "I am a debuggee" is not a
//   debugger, so neither the answer nor the refusal fires.
//
//   Two debuggers, which is a person telling both boards to connect: the
//   second may not take the role.  It cannot, because `foreign` --- a board
//   saying it is the debugger, on a group this one is not driving --- holds
//   `engaged` down, and the console has the bit to say why.  **The first board
//   told wins**, which is the only rule that can be enforced from one end.
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
// **THE ROLE MAY NOT CHANGE UNDER A CYCLE.**  `engaged` rises only with no
// debugger on the connector and no request standing at either end, and falls
// only with this board's own request down.  A debug cycle is a level held for
// its whole length at both ends, so a role changing inside one would leave the
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
// FURTHER.**  No frames arrive, `out_live` is down, and `out_dbd_in` stands at
// all ones --- the whole sixteen undriven, which is what an open connector is.
// `rtl/machine/cadr_busint_regs.sv` answers its own machine's cycle at once
// when that is so, which is muir's own no-cable arm: "With no cable the
// pull-up answers at `-UB MSYN`."  So an unplugged cable is not an error
// anybody has to handle; it is a debuggee that answers every strobe
// immediately with ones, and CC sees the machine it cannot reach.
//
// ## The whole of it as a table
//
// What this board does, by the role it holds, the setting it was given and
// what arrives on which group.  `F` is the four low pins and `R` the four
// high; "idle" is a good frame whose role bit is clear and "debugger" one
// whose role bit is set.  A group this board is driving is not listened to at
// all, its receiver being held in reset, so every row below is about a group
// this board has left alone.
//
//   role       setting      hears          on   what this board does
//   ---------  -----------  -------------  ---  ------------------------------
//   debuggee   any          nothing        --   drives nothing
//   debuggee   any          debugger       F    answers it on R; refuses the
//                                               role while it is there
//   debuggee   any          debugger       R    a crossed cable and a debugger
//                                               that has not compensated: does
//                                               NOT answer, and refuses the
//                                               role while it is there
//   debuggee   any          idle           F    an idle debuggee over a
//                                               crossed cable: answers
//                                               nothing, blocks nothing, and
//                                               the console says so
//   debuggee   any          idle           R    reported and acted on by
//                                               nothing: a straight cable puts
//                                               no debuggee there
//   debugger   straight     --             --   drives F, listens on R
//   debugger   crossover    --             --   drives R, listens on F
//   debugger   auto         (listening)    --   drives NOTHING for one frame
//                                               and the loss interval
//   debugger   auto         idle           R    straight, found: drives F
//   debugger   auto         idle           F    crossover, found: drives R
//   debugger   auto         debugger    F or R  the two-debuggers case; the
//                                               take refuses while it stands
//   debugger   auto         nothing        --   assumes straight, and
//                                               alternates each probe interval
//                                               --- through a quiet interval
//                                               each time --- until something
//                                               answers
//   any        any          anything at
//              all on a group it is about to drive  does not drive it
//
// The last row is the one that holds in every combination the others do not
// name, and it is the one the check counts on every tick.

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
    // --- `engaged` is whether this board took it, and the four below say
    // --- what the connector looks like to somebody asking why.
    input  var logic        connect,
    output var logic        engaged,
    output var logic        foreign,    // a DEBUGGER is on the connector
    output var logic        peer_far,   // and on the pins this board answers on
    output var logic        live,       // good frames are arriving
    output var logic        active,     // something is driving a group

    // --- the wiring: `WIRE_AUTO`, `WIRE_STRAIGHT` or `WIRE_CROSSOVER`, from
    // --- the console's word 14, and `wire_state` is what came of it.  See
    // --- the header's table and the state's own names below.
    input  var logic [1:0]  wiring,
    output var logic [2:0]  wire_state,

    // --- and how the cable is behaving: frames heard, sixteen bits, and
    // --- frames REFUSED, eight, both saturating and both cleared only by
    // --- reset.  See the header: the pins are routed as coupled pairs and
    // --- what crosstalk costs is refused frames, so the ratio is the
    // --- measurement nobody has yet.
    output var logic [23:0] frames,

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

  // ---------------------------------------------------- the eight pins, named
  //
  // **ONE SIGNAL PER COUPLED PAIR, AND THE PARTNER OF EACH DRIVEN LOW.**  The
  // high-speed Pmod headers on these boards route their pins as pairs --- 1
  // with 2, 3 with 4, 7 with 8, 9 with 10, with 0-ohm shunts where a
  // differential termination would go --- so a group driven single-ended on
  // all four pins has an edge on one line coupling into its partner, and the
  // partner may be the STROBE.  A false edge on a strobe makes a false beat
  // and a false beat misaligns the frame it lands in.
  //
  // So each pair carries ONE signal and its other line is a GUARD held at
  // zero by whichever board drives that group.  The strobe has the first pair
  // of a group to itself and the one data line has the second.  A guard is
  // driven and not left floating: a quiet line beside a switching one is only
  // quiet if something holds it, and a floating line is a capacitor the
  // neighbor charges.
  //
  // | index | header pin | forward group | return group |
  // |---|---|---|---|
  // | 0 / 4 | 1 / 7  | strobe        | strobe        |
  // | 1 / 5 | 2 / 8  | guard, low    | guard, low    |
  // | 2 / 6 | 3 / 9  | data          | data          |
  // | 3 / 7 | 4 / 10 | guard, low    | guard, low    |
  //
  // **WHAT IT COSTS IS THE FRAME'S LENGTH AND NOTHING ELSE.**  One data line
  // where there were three is twenty-four beats where there were eight, 162
  // ticks a frame against 66, which the section on the intervals below
  // carries through the detection and the probe.  A debug cycle is two frames
  // and the far machine's own bus cycle, and the debugger gives up at
  // `busint::DEBUG_TIMEOUT_NS` --- the REQTIM PROM's second table, which this
  // fabric counts as 2,210 ticks in `rtl/machine/cadr_busint_xbus.sv`.
  // `build/dbg_pmod.pass` and `build/dbg_cable.pass` measure the round trip
  // against it rather than leaving the arithmetic to stand on its own.
  localparam int unsigned FWD_STB = 0;   // the low four, header pins 1 to 4
  localparam int unsigned FWD_GD0 = 1;
  localparam int unsigned FWD_DAT = 2;
  localparam int unsigned FWD_GD1 = 3;
  localparam int unsigned RET_STB = 4;   // and the high four, pins 7 to 10
  localparam int unsigned RET_GD0 = 5;
  localparam int unsigned RET_DAT = 6;
  localparam int unsigned RET_GD1 = 7;

  // The cable's levels: MIT's twenty plus the sender's own role.
  localparam int unsigned PAYLOAD_W = 21;
  localparam int unsigned LINES     = 1;
  localparam int unsigned ROLE_BIT  = PAYLOAD_W - 1;

  // The three the console's word 14 can hold.  `WIRE_AUTO` is the reset
  // value, because a board that looks is right more often than a board that
  // assumes, and the two forced settings exist to take the looking out of the
  // way when somebody is diagnosing a cable.
  localparam logic [1:0] WIRE_AUTO      = 2'd0;
  localparam logic [1:0] WIRE_STRAIGHT  = 2'd1;
  localparam logic [1:0] WIRE_CROSSOVER = 2'd2;

  // What `wire_state` says, and it is one field with one meaning per value so
  // that no reader has to combine it with another bit to know what it means.
  localparam logic [2:0] WS_AUTO_IDLE  = 3'd0;  // auto, and not the debugger
  localparam logic [2:0] WS_STRAIGHT   = 3'd1;  // straight, set
  localparam logic [2:0] WS_CROSSOVER  = 3'd2;  // crossover, set
  localparam logic [2:0] WS_LISTENING  = 3'd3;  // auto, listening, driving nothing
  localparam logic [2:0] WS_ST_FOUND   = 3'd4;  // auto, straight, heard
  localparam logic [2:0] WS_CR_FOUND   = 3'd5;  // auto, crossover, heard
  localparam logic [2:0] WS_ST_ASSUMED = 3'd6;  // auto, nothing heard, trying straight
  localparam logic [2:0] WS_CR_ASSUMED = 3'd7;  // auto, nothing heard, trying crossover

  // One frame, from the carrier's own arithmetic, and the three intervals the
  // detection is made of.
  //
  // The listen is a frame plus the loss interval: a frame so that one whole
  // one can arrive, and the loss interval because that is how long a far board
  // that was answering somebody goes on answering after it stops being spoken
  // to --- which is the window in which there is anything to hear.
  //
  // `ACT_T` is how long a group goes on looking driven after its driver stops,
  // and it is two frames rather than the loss interval because a sender
  // free-runs and a gap of a whole frame already means nobody is there.
  //
  // **AND THE PROBE IS BUILT ON `ACT_T` AND NOT ON A ROUND NUMBER**, because
  // the far end cannot answer on a group until that group has stopped looking
  // driven to IT: this board drove the other one last probe, so a probe
  // shorter than `ACT_T` plus the round trip flips away before the answer can
  // arrive.  Measured, at `LOSS_T`: the answer landed exactly as the
  // assumption flipped and a mirrored cable never came up.
  //
  // **AND EVERY ONE OF THEM IS THREE TIMES WHAT IT WAS**, because one data
  // line a group makes the frame twenty-four beats where three made it eight.
  // At the defaults: a frame is 162 ticks, `ACT_T` 324, the listen
  // `162 + LOSS_T`, a probe 1,296 and a re-listen 486.  Nothing here is a
  // round number and nothing here is a constant: they are all the frame, so
  // the connector cannot drift from the carrier under it.
  localparam int unsigned BEATS    = (PAYLOAD_W + 2 + 1 + LINES - 1) / LINES;
  localparam int unsigned FRAME_T  = BEATS * BEAT_T + GAP_T;
  localparam int unsigned ACT_T    = 2 * FRAME_T;
  localparam int unsigned DETECT_T = FRAME_T + LOSS_T;
  localparam int unsigned PROBE_T  = ACT_T + 6 * FRAME_T;
  // **AND A FLIP GOES THROUGH A QUIET INTERVAL, WHICH IS NOT TIDINESS.**  The
  // receiver on a group this board is driving is held in reset, so the moment
  // it lets that group go it knows NOTHING about it --- and the next flip but
  // one would drive it again on the strength of a counter that has not run.
  // Measured before this went in: the far end's answer arrived on the group
  // this board had just released, the flip drove it anyway, and the check
  // counted 580 pad-ticks from both ends.  So a flip listens first, for long
  // enough that both receivers are telling the truth, and anything heard in
  // that interval settles the wiring outright.
  localparam int unsigned RELISTEN_T = ACT_T + FRAME_T;
  // **THE PHASE COUNTER IS SIZED FROM THE LONGEST OF THE THREE AND NOT FROM
  // THE LISTEN.**  It was `$clog2(DETECT_T + 1)`, which held while a frame was
  // sixty-six ticks and the probe was the shorter of the two; at twenty-four
  // beats a probe is 1,296 ticks and a listen with the CHECK's own shrunken
  // loss interval is 674, so the load truncated and the probe ended after 272.
  // Nothing said so: the board's own numbers still fitted, and only the check
  // --- which shrinks `LOSS_T` to make a run seconds rather than minutes ---
  // was wrong.  A width derived from one of three intervals is a width that is
  // right by coincidence.
  localparam int unsigned PH_TRY  = PROBE_T > DETECT_T ? PROBE_T : DETECT_T;
  localparam int unsigned PH_LONG = PH_TRY > RELISTEN_T ? PH_TRY : RELISTEN_T;
  localparam int unsigned PH_W     = $clog2(PH_LONG + 1);

  // ------------------------------------------------------------- the carrier
  //
  // ONE sender and TWO receivers.  What this end sends is its own half of the
  // cable, and which half that is follows the role; what it listens to is both
  // groups at once, because the wiring is not known until something has been
  // heard and because a group nobody is listening to is a group a board can
  // drive over.  The far end reads a frame by ITS role, and the two are
  // complementary, so a frame packed as a request is read as a request and one
  // packed as an answer is read as an answer.
  logic [PAYLOAD_W-1:0] tx_levels;
  logic                 tx_stb;
  logic [LINES-1:0]     tx_d;

  logic [PAYLOAD_W-1:0] fwd_levels, ret_levels;
  logic                 fwd_live, ret_live, fwd_act, ret_act;
  logic                 fwd_done, fwd_frame_bad, ret_done, ret_frame_bad;

  logic drive_fwd, drive_ret;

  // The debugger's twenty and the debuggee's, packed as
  // `tb/cadr_dbg_pmod_harness.sv` packs them, under the role bit.  The debuggee's spare bit goes out as zero.
  assign tx_levels = engaged ? {1'b1, out_req, out_wr, out_a, out_dbd}
                             : {1'b0, 1'b0, in_ack, in_dbd_oe, in_dbd_out};

  cadr_dbg_tx #(
      .PAYLOAD_W(PAYLOAD_W), .LINES(LINES), .BEAT_T(BEAT_T), .GAP_T(GAP_T)
  ) u_tx (
      .clk(clk), .rst(rst),
      .tx_levels(tx_levels), .tx_stb(tx_stb), .tx_d(tx_d)
  );

  // **A RECEIVER IS HELD IN RESET WHILE THIS BOARD DRIVES ITS GROUP.**  The
  // pads are `inout` and a driven one reads back what this board put on it, so
  // a receiver left running there would decode this board's own frames --- and
  // on a crossed cable those are indistinguishable from the far end's, both
  // boards being debuggees with the same role bit.  Measured as a hazard
  // before it was built: a board that had been answering on the high four and
  // then took the role would have read its own last frames as the far end's
  // and called the cable straight, which is the one wiring it cannot be.
  cadr_dbg_rx #(
      .PAYLOAD_W(PAYLOAD_W), .LINES(LINES), .GAP_MIN(GAP_MIN),
      .LOSS_T(LOSS_T), .ACT_T(ACT_T)
  ) u_rx_fwd (
      .clk(clk), .rst(rst || drive_fwd),
      .rx_stb(pin_i[FWD_STB]), .rx_d(pin_i[FWD_DAT]),
      .rx_levels(fwd_levels), .rx_live(fwd_live), .rx_active(fwd_act),
      .frame_done(fwd_done), .frame_bad(fwd_frame_bad)
  );

  cadr_dbg_rx #(
      .PAYLOAD_W(PAYLOAD_W), .LINES(LINES), .GAP_MIN(GAP_MIN),
      .LOSS_T(LOSS_T), .ACT_T(ACT_T)
  ) u_rx_ret (
      .clk(clk), .rst(rst || drive_ret),
      .rx_stb(pin_i[RET_STB]), .rx_d(pin_i[RET_DAT]),
      .rx_levels(ret_levels), .rx_live(ret_live), .rx_active(ret_act),
      .frame_done(ret_done), .frame_bad(ret_frame_bad)
  );

  // ------------------------------------------------- who is out there, and what
  //
  // A good frame on a group this board is not driving, and the one bit that
  // says what kind of board sent it.  Nothing here tests `drive_*`: the
  // receiver is held in reset while its group is driven, so its `rx_live` is
  // already down and a term for it would be a mutation nothing could catch.
  logic fwd_dbgr, ret_dbgr, fwd_idle, ret_idle;
  assign fwd_dbgr = fwd_live &&  fwd_levels[ROLE_BIT];
  assign ret_dbgr = ret_live &&  ret_levels[ROLE_BIT];
  assign fwd_idle = fwd_live && !fwd_levels[ROLE_BIT];
  assign ret_idle = ret_live && !ret_levels[ROLE_BIT];

  // **AND A DEBUGGEE AT THE FAR END IS `live` WITHOUT `foreign`**, which is
  // why it takes no wire of its own: on a cable with two ends, a good frame
  // that is not a debugger's is a debuggee's.
  //
  // **`peer_far` IS THE CROSSED CABLE, NAMED FROM THE END THAT CANNOT
  // COMPENSATE.**  A debuggee listens on the low four and answers on the high
  // four, so on a straight cable nothing but this board ever drives the high
  // four and its receiver there hears nothing, ever.  Frames arriving on it
  // can only be the far board's low four reaching the wrong pins, which is a
  // mirrored ribbon with a debugger at the far end that has not compensated
  // for it --- the exact fault two boards were found in, read off the board
  // that is not the one with the setting.  It is a debuggee's signal by
  // construction: a board that is driving the high four has that receiver
  // held in reset, so a debugger and an answering debuggee both read it as
  // false.
  assign foreign   = fwd_dbgr || ret_dbgr;
  assign peer_far  = !engaged && ret_live;
  assign live      = fwd_live || ret_live;
  assign active    = fwd_act  || ret_act;

  // ------------------------------------------------- how the cable behaves
  //
  // **THE PINS ARE COUPLED PAIRS AND THIS LINK PUTS ONE SIGNAL ON EACH**, with
  // the partner driven low --- the section above has the map and the reason.
  // That removes the coupling this counter was put in to measure, and the
  // counter stays anyway.
  //
  // **A GUARDED PAIR IS AN ARGUMENT AND NOT A MEASUREMENT.**  Nothing about
  // either arrangement has been seen on a board, a ribbon has its own
  // crosstalk between pairs as well as within one, and a false beat costs the
  // same whatever made it: the frame fails its marker or its parity, moves
  // nothing, and the levels stand until the next frame carries them again.  So
  // a bad cable is LOST FRAMES and never wrong values, unless it is frequent
  // --- and how frequent is still a number nobody has.  These two counters are
  // that number, read through the console: frames heard, whatever their checks
  // said, and frames refused.
  //
  // Both saturate rather than wrap, for the reason the console's other counts
  // do: a counter that can read zero again is one that can say nothing has
  // ever happened when something has.  A saturated `heard` beside a `refused`
  // of nothing is still a statement --- sixty-five thousand frames and not one
  // refused --- and a `refused` of anything at all is the finding.
  //
  // A receiver whose group this board drives is held in reset, so what these
  // count is what ARRIVED and never what this board sent.
  logic [15:0] frames_heard;
  logic [7:0]  frames_refused;
  logic [1:0]  heard_inc, bad_inc;
  logic [16:0] heard_sum;
  logic [8:0]  bad_sum;
  assign heard_inc = {1'b0, fwd_done} + {1'b0, ret_done};
  assign bad_inc   = {1'b0, fwd_frame_bad} + {1'b0, ret_frame_bad};
  assign heard_sum = {1'b0, frames_heard}   + 17'(heard_inc);
  assign bad_sum   = {1'b0, frames_refused} + 9'(bad_inc);

  always_ff @(posedge clk) begin
    if (rst) begin
      frames_heard   <= '0;
      frames_refused <= '0;
    end else begin
      if (heard_inc != 2'd0)
        frames_heard <= heard_sum[16] ? 16'hFFFF : heard_sum[15:0];
      if (bad_inc != 2'd0)
        frames_refused <= bad_sum[8] ? 8'hFF : bad_sum[7:0];
    end
  end

  assign frames = {frames_heard, frames_refused};

  // ---------------------------------------------------------------- the role
  //
  // `engaged` is the whole of it: one flop, which is why the console can read
  // the role back and get an answer about the connector rather than about what
  // it was last told.
  //
  // **AND THE GUARD IS `foreign` AND NOT `active`.**  It was activity, and a
  // pair of idle boards on a crossed ribbon then locked each other out: each
  // heard the other's answers on the group a debugger drives, called it a
  // debugger, and refused the role.  What the take must refuse is a DEBUGGER,
  // which is a frame that says so.
  logic take, drop;
  assign take = connect && !engaged && !foreign && !in_req && !out_req;
  assign drop = !connect && engaged && !out_req;

  // ------------------------------------------------------------- the wiring
  //
  // `wire_q` is the setting as it stood when the role was taken, `crossed` the
  // wiring in effect, `decided` whether there is one yet, and `found` whether
  // it was heard rather than assumed.  See the header: only a debugger applies
  // any of it, and a board drives nothing while it is listening.
  logic [1:0]      wire_q;
  logic            crossed, decided, found;
  logic [PH_W-1:0] ph_t;

  // The group this board listens to once the wiring is settled: a debuggee
  // always the low four, a debugger the one it is not driving.
  logic lsn_idle;
  assign lsn_idle = crossed ? fwd_idle : ret_idle;

  always_ff @(posedge clk) begin
    if (rst) begin
      engaged <= 1'b0;
      wire_q  <= WIRE_AUTO;
      crossed   <= 1'b0;
      decided <= 1'b0;
      found   <= 1'b0;
      ph_t    <= '0;
    end else if (take) begin
      engaged <= 1'b1;
      wire_q  <= wiring;
      found   <= 1'b0;
      crossed   <= (wiring == WIRE_CROSSOVER);
      decided <= (wiring != WIRE_AUTO);
      // A forced setting drives at once; `auto` listens first, and the timer
      // is what says for how long.
      ph_t    <= (wiring == WIRE_AUTO) ? PH_W'(DETECT_T) : '0;
    end else if (drop) begin
      engaged <= 1'b0;
      crossed   <= 1'b0;
      decided <= 1'b0;
      found   <= 1'b0;
      ph_t    <= '0;
    end else if (engaged && wire_q == WIRE_AUTO) begin
      if (!decided) begin
        // Listening, and driving nothing.  A debuggee's frames on the high
        // four are a straight cable and on the low four a crossover; the
        // order between them is arbitrary and settled here so that a cable
        // reaching both groups gives one answer and not an oscillation.
        if (ret_idle) begin
          decided <= 1'b1; crossed <= 1'b0; found <= 1'b1; ph_t <= '0;
        end else if (fwd_idle) begin
          decided <= 1'b1; crossed <= 1'b1; found <= 1'b1; ph_t <= '0;
        end else if (ph_t != '0) begin
          ph_t <= ph_t - 1'b1;
        end else begin
          // Nothing was heard, which is what two freshly reset boards sound
          // like whatever the cable is.  Drive on the assumption standing ---
          // straight at the take, and the other one after every flip.
          decided <= 1'b1; found <= 1'b0; ph_t <= PH_W'(PROBE_T);
        end
      end else if (!found) begin
        // Assuming, and driving.  An answer on the group this board is
        // listening to settles the wiring; nothing for a probe interval flips
        // the assumption, which is the only thing that brings a crossed cable
        // up when both boards started out silent.
        if (lsn_idle) begin
          found <= 1'b1; ph_t <= '0;
        end else if (ph_t != '0) begin
          ph_t <= ph_t - 1'b1;
        end else begin
          // Flip the assumption, and go quiet while the group this board has
          // just been driving settles --- see `RELISTEN_T`.
          crossed <= ~crossed; decided <= 1'b0; ph_t <= PH_W'(RELISTEN_T);
        end
      end
    end
  end

  // And what the console is told, one value a meaning.
  always_comb begin
    if (!engaged)                     wire_state = (wiring == WIRE_STRAIGHT)  ? WS_STRAIGHT
                                                 : (wiring == WIRE_CROSSOVER) ? WS_CROSSOVER
                                                                              : WS_AUTO_IDLE;
    else if (wire_q == WIRE_STRAIGHT) wire_state = WS_STRAIGHT;
    else if (wire_q == WIRE_CROSSOVER)wire_state = WS_CROSSOVER;
    else if (!decided)                wire_state = WS_LISTENING;
    else if (found)                   wire_state = crossed ? WS_CR_FOUND   : WS_ST_FOUND;
    else                              wire_state = crossed ? WS_CR_ASSUMED : WS_ST_ASSUMED;
  end

  // ------------------------------------------------------------ the eight pins
  //
  // A debuggee drives the high four and only while it hears a DEBUGGER on the
  // low four; a debugger drives one group or the other by the wiring, and
  // neither while it is still listening.
  //
  // **AND NEITHER DRIVES A GROUP SOMETHING ELSE IS DRIVING.**  That is the one
  // rule that holds in every arrangement, including the ones the role rules do
  // not reach: two boards told to connect inside one listening interval, a
  // probe that lands on a group the far end is still answering on, or a
  // debuggee whose debugger has not compensated for a crossed cable.
  //
  // **AND A BOARD IN RESET DRIVES NOTHING**, which is not a detail: a
  // receiver's activity comes out of reset SATURATED --- nothing has been
  // heard --- and a pad enabled before that value is loaded is a board
  // claiming a group on the strength of a counter that has not run yet.  Two
  // boards reset together would both claim the return group and hold it until
  // their timers ran out, which the two-board check counted.
  logic want_fwd, want_ret;
  assign want_fwd = engaged && decided && !crossed;
  assign want_ret = engaged ? (decided && crossed) : fwd_dbgr;
  assign drive_fwd = want_fwd && !fwd_act && !rst;
  assign drive_ret = want_ret && !ret_act && !rst;

  //
  // **A GROUP IS DRIVEN WHOLE OR NOT AT ALL, AND TWO OF ITS FOUR PINS ARE
  // GUARDS.**  `pin_o` starts at zero, so the two lines named `*_GD*` go out
  // LOW whenever their group is enabled: that is the whole of the guard, and
  // it has to be a DRIVEN low rather than a pad left out of the enable, or the
  // line beside the strobe is a floating capacitor its neighbor charges.
  // Enabling all four also keeps the pad groups the console reports and
  // `build/dbg_cable.pass` asserts against --- the low four or the high four,
  // never a subset of one.
  // Written a pin at a time and not a nibble at a time, so that every one of
  // the eight names above appears where it is used: a guard's level is a
  // statement of its own and reads as one.
  always_comb begin
    pin_o = 8'h00;
    pin_t = 8'hFF;
    if (drive_fwd) begin
      pin_o[FWD_STB] = tx_stb;
      pin_o[FWD_DAT] = tx_d[0];
      pin_o[FWD_GD0] = 1'b0;
      pin_o[FWD_GD1] = 1'b0;
      pin_t[FWD_STB] = 1'b0;
      pin_t[FWD_DAT] = 1'b0;
      pin_t[FWD_GD0] = 1'b0;
      pin_t[FWD_GD1] = 1'b0;
    end
    if (drive_ret) begin
      pin_o[RET_STB] = tx_stb;
      pin_o[RET_DAT] = tx_d[0];
      pin_o[RET_GD0] = 1'b0;
      pin_o[RET_GD1] = 1'b0;
      pin_t[RET_STB] = 1'b0;
      pin_t[RET_DAT] = 1'b0;
      pin_t[RET_GD0] = 1'b0;
      pin_t[RET_GD1] = 1'b0;
    end
  end

  // ------------------------------------------------- what comes off the cable
  //
  // A debugger reads answers off the group it listens to and a debuggee reads
  // requests off the low four, and the one it is not reading is held at the
  // idle cable rather than left to the payload: zero is `-DEBUG IN REQ` up and
  // `DEBUG IN ACK` down, and ones are the undriven lines.
  //
  // **AND EACH READS ONLY FRAMES FROM THE OTHER KIND OF BOARD.**  A request
  // comes from a debugger and an answer from a debuggee, and the role bit says
  // which arrived; a board that took an idle board's frames for the far end's
  // answers would be reading a cable nobody is driving on its behalf.
  // Nineteen and not twenty-one: the role bit is read above, and the request
  // bit is the debuggee's to read.  A vector with bits nothing reads is a
  // mutation nobody can catch, so it is not declared.
  logic [18:0] lsn_levels;
  assign lsn_levels = crossed ? fwd_levels[18:0] : ret_levels[18:0];

  assign in_req = !engaged && fwd_dbgr && fwd_levels[19];
  assign in_wr  = !engaged ? fwd_levels[18]    : 1'b0;
  assign in_a   = !engaged ? fwd_levels[17:16] : 2'b00;
  assign in_dbd = !engaged ? fwd_levels[15:0]  : 16'h0000;

  assign out_live = engaged && decided && lsn_idle;
  assign out_ack  = out_live && lsn_levels[18];
  // The two byte enables, resolved against the cable's pull-ups.  See the
  // header: a byte nobody drives reads as ones, and a cable with nothing at
  // the far end is all sixteen of them.
  assign out_dbd_in = out_live
                    ? {lsn_levels[17] ? lsn_levels[15:8] : 8'hFF,
                       lsn_levels[16] ? lsn_levels[7:0]  : 8'hFF}
                    : 16'hFFFF;

endmodule

`default_nettype wire
