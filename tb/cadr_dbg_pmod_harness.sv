// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Two boards, a Pmod cable between them, and a real debug cycle over it.
//
// `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` are the carrier: MIT's
// debug cable on eight pins, four each way, a sender and a receiver.  This
// harness is what holds them, and it holds them two ways at once.
//
// **THE CARRIER ALONE, WITH THE PINS BROUGHT OUT.**  `u_pa_*` and `u_pb_*` are
// a pair with their payloads driven from outside and their four wires --- a
// strobe and one data line each way --- as harness ports, so the testbench IS
// the cable and can do to it what a cable does: delay it, skew the strobe
// against the data, unplug it, short a line high or low, cross the strobe with
// the data line.  A carrier whose two ends are the same module cannot mirror a
// fault --- there is no shared state for a bug to hide in ---
// but a check that fed it a constant could still pass a carrier that dropped
// a line, so what goes in is poison: every value distinct, so that a value
// arriving at the far end either was sent or was not.
//
// **AND THE CARRIER IN A DEBUGGER'S PATH.**  `u_out_*` and `u_in_*` carry
// `rtl/plumbing/cadr_debug_window.sv` to `rtl/machine/cadr_dbgin.sv` and the
// answer back, through `rtl/machine/cadr_console_bus.sv` into
// `rtl/machine/cadr_spy_registers.sv`, which is CC's whole vocabulary.  So
// the claim is not that bits cross a wire: it is that a debugger halts this
// machine and reads a register over MIT's own cable, carried on eight pins.
//
// **THE TWO ENDS ARE TWO BOARDS AND HAVE TWO CLOCKS.**  `clk` is the
// debugger's and `clk_b` the debuggee's, with a reset each.  Two boards have
// two crystals, so a carrier checked on one clock is a carrier whose only
// asynchronous crossing has been checked against itself.  The testbench runs
// them apart and out of phase.
//
// WHERE THIS IS NOT THE BOARD, said here rather than found later.  On
// `boards/arty-z7-20/cadr_arty.sv` the window is on the NEAR side of the
// join and the connector carries a second board; here the window is on the
// FAR side, so that the cable is inside the debugger's own path and its round
// trip can be measured.  The modules and the wiring between them are the
// same modules and the same wiring; what differs is which arm of
// `cadr_dbg_join.sv` the window is on.  The board's arrangement is what
// `build/arty.pass` lints, and the join is asked to keep two debuggers apart
// here by driving its near arm from the testbench --- `loc_*`, a stimulus
// port with no counterpart in the fabric, which is the only way to ask.
//
// **THE MICROCYCLE BOUNDARY IS MADE HERE**, a pulse every normal microcycle --- 15 ticks at a 10 ns grid --- because
// `cadr_console_bus.sv` captures the diagnostic mux at it.  A harness with no
// boundary would leave the read-back frozen at its reset value and the check
// would be comparing a constant.  There is no processor: `spy_rdata` comes
// from outside for the reason `err_status` does in the neighboring harnesses
// --- a check that hands the DUT the answer tests nothing, and a value from
// outside is somebody else's.

`default_nettype none

module cadr_dbg_pmod_harness #(
    // Shrunk from the window's own one second, because a bound nothing
    // exercises is not a bound and a second is 100,000,000 ticks.
    parameter int unsigned WATCHDOG_T = 4096,
    // The carrier's own four, at the module's defaults.  Named here so that
    // the testbench's arithmetic and the DUT's cannot drift apart.
    //
    // **AND `LINES` IS ONE**, which is what makes the frame twenty-four beats.
    // The Pmod's pins are coupled pairs and the link puts one signal on each,
    // with the partner driven low as a guard; the guards are
    // `rtl/plumbing/cadr_dbg_cable.sv`'s and never reach the carrier, so what
    // this harness brings out is a strobe and one data line each way.  It is
    // passed to every instance rather than left at the default, so that the
    // port widths here and the frame there cannot drift apart.
    parameter int unsigned LINES      = 1,
    parameter int unsigned BEAT_T     = 6,
    parameter int unsigned GAP_T      = 18,
    parameter int unsigned GAP_MIN    = 12,
    // Shrunk from the module's 1,024 for the same reason as the watchdog.
    parameter int unsigned LOSS_T     = 512
) (
    // --- the debugger's board
    input  var logic        clk,
    input  var logic        rst,
    // --- the debuggee's board
    input  var logic        clk_b,
    input  var logic        rst_b,

    // --- the general-purpose port the window sits on
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

    // --- the carrier alone: a payload each way, and the eight wires
    input  var logic [19:0] p_tx_a,
    output var logic [19:0] p_rx_a,
    output var logic        p_live_a,
    // A frame ARRIVED at this end, whatever its checks said, and a frame was
    // REFUSED.  One tick each: the connector counts them and the console
    // reports the pair, because a Pmod row is routed as coupled pairs and what
    // an edge coupling into a strobe costs is refused frames.
    output var logic        p_done_a,
    output var logic        p_bad_a,
    input  var logic [19:0] p_tx_b,
    output var logic [19:0] p_rx_b,
    output var logic        p_live_b,
    output var logic        p_done_b,
    output var logic        p_bad_b,
    output var logic            pa_stb_o,
    output var logic [LINES-1:0] pa_d_o,
    input  var logic            pa_stb_i,
    input  var logic [LINES-1:0] pa_d_i,
    output var logic            pb_stb_o,
    output var logic [LINES-1:0] pb_d_o,
    input  var logic            pb_stb_i,
    input  var logic [LINES-1:0] pb_d_i,

    // --- the debugger's connector, the window behind it
    output var logic            oa_stb_o,
    output var logic [LINES-1:0] oa_d_o,
    input  var logic            oa_stb_i,
    input  var logic [LINES-1:0] oa_d_i,
    // --- the debuggee's connector, `cadr_dbgin.sv` behind it
    output var logic            ob_stb_o,
    output var logic [LINES-1:0] ob_d_o,
    input  var logic            ob_stb_i,
    input  var logic [LINES-1:0] ob_d_i,

    // --- a second debugger at the join's near arm: stimulus, see the header
    input  var logic        loc_req,
    input  var logic        loc_wr,
    input  var logic [1:0]  loc_a,
    input  var logic [15:0] loc_dbd,

    // --- the processor's sixteen-way diagnostic mux, from outside
    input  var logic [15:0] spy_rdata,
    output var logic [3:0]  spy_eadr,

    // --- `Machine::debug_status`'s byte, from outside
    input  var logic [7:0]  err_status,

    // --- the CADR's own Unibus master, which the fabric has and this does not
    input  var logic        cpu_msyn,
    input  var logic        cpu_write,
    input  var logic [17:0] cpu_addr,
    input  var logic [15:0] cpu_wdata,
    output var logic        cpu_ssyn,

    // --- what the check watches, every tick
    output var logic        mclk_o,
    output var logic        win_req_o,
    output var logic        win_wr_o,
    output var logic [1:0]  win_a_o,
    output var logic [15:0] win_dbd_o,
    output var logic        win_ack_o,
    output var logic [15:0] win_dbd_in_o,
    output var logic [1:0]  win_oe_o,
    output var logic        cab_req_o,
    output var logic        cab_wr_o,
    output var logic [1:0]  cab_a_o,
    output var logic [15:0] cab_dbd_o,
    output var logic        cab_ack_o,
    output var logic [15:0] cab_dbd_back_o,
    output var logic [1:0]  cab_oe_o,
    output var logic        out_live_o,
    output var logic        in_live_o,
    output var logic        holder_o,
    output var logic        dbg_req_o,
    output var logic        dbg_gnt_o,
    output var logic [2:0]  modifier_o,
    output var logic [15:0] address_o,
    output var logic        debuggee_reset_o,
    output var logic        mach_rst_o,
    output var logic        run_o
);

  // ------------------------------------------------- the carrier alone
  //
  // Two ends, two clocks, payloads and pins from outside.  Nothing of the
  // cable's meaning is here: the payload is twenty bits and which bit is
  // `-DEBUG IN REQ` is decided where it is packed, which is the point of the
  // module taking a vector.
  // **AND THE PAIR HERE IS TWENTY BITS WHERE THE CONNECTOR'S IS TWENTY-ONE**,
  // on purpose: one source serves two payloads and nothing about the frame may
  // depend on which.  The two used to differ in their zero fill as well --- at
  // three data lines twenty payload bits left a slot over and twenty-one left
  // none --- and at ONE data line neither has a fill, because the frame is the
  // payload, the marker and the parity bit exactly.  So the fill is
  // unreachable in every configuration any board builds, and the only thing
  // that still exercises it is a `LINES` this design no longer uses.  It is
  // said here rather than left to be discovered, and the two payloads are
  // still worth having: a beat count worked out from one of them would be
  // caught by the other.
  logic pa_act_u, pb_act_u;

  cadr_dbg_tx #(
      .PAYLOAD_W(20), .LINES(LINES), .BEAT_T(BEAT_T), .GAP_T(GAP_T)
  ) u_pa_tx (
      .clk(clk), .rst(rst),
      .tx_levels(p_tx_a), .tx_stb(pa_stb_o), .tx_d(pa_d_o)
  );

  cadr_dbg_rx #(
      .PAYLOAD_W(20), .LINES(LINES), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) u_pa_rx (
      .clk(clk), .rst(rst),
      .rx_stb(pa_stb_i), .rx_d(pa_d_i),
      .rx_levels(p_rx_a), .rx_live(p_live_a), .rx_active(pa_act_u),
      .frame_done(p_done_a), .frame_bad(p_bad_a)
  );

  cadr_dbg_tx #(
      .PAYLOAD_W(20), .LINES(LINES), .BEAT_T(BEAT_T), .GAP_T(GAP_T)
  ) u_pb_tx (
      .clk(clk_b), .rst(rst_b),
      .tx_levels(p_tx_b), .tx_stb(pb_stb_o), .tx_d(pb_d_o)
  );

  cadr_dbg_rx #(
      .PAYLOAD_W(20), .LINES(LINES), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) u_pb_rx (
      .clk(clk_b), .rst(rst_b),
      .rx_stb(pb_stb_i), .rx_d(pb_d_i),
      .rx_levels(p_rx_b), .rx_live(p_live_b), .rx_active(pb_act_u),
      .frame_done(p_done_b), .frame_bad(p_bad_b)
  );

  // ------------------------------------------------------- the debugger
  //
  // The window, and the DBGOUT end of the cable in front of it.  What it
  // drives is the twenty; what comes back is the nineteen with a bit to
  // spare, packed as `boards/arty-z7-20/cadr_arty.sv` packs them.
  logic        win_req, win_wr;
  logic [1:0]  win_a;
  logic [15:0] win_dbd;
  logic [20:0] out_back;
  logic        out_live;
  logic        out_act_u, out_done_u, out_bad_u;
  assign win_req_o    = win_req;
  assign win_wr_o     = win_wr;
  assign win_a_o      = win_a;
  assign win_dbd_o    = win_dbd;
  assign win_ack_o    = out_back[18];
  assign win_oe_o     = out_back[17:16];
  assign win_dbd_in_o = out_back[15:0];
  // **AND AN ANSWER COMES FROM A DEBUGGEE**, which is what the role bit says:
  // `rtl/plumbing/cadr_dbg_cable.sv` reads its own `out_live` the same way, so
  // that a second debugger's requests cannot be read as this cable's replies.
  assign out_live_o   = out_live && !out_back[20];

  cadr_debug_window #(
      .REG_BASE(32'h8000_1000),
      .WATCHDOG_T(WATCHDOG_T)
  ) u_window (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awid(s_awid),
      .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bresp(s_bresp), .s_bid(s_bid), .s_bvalid(s_bvalid),
      .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arid(s_arid),
      .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rid(s_rid),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .dbg_in_req(win_req), .dbg_in_wr(win_wr), .dbg_in_a(win_a),
      .dbd_out(win_dbd),
      .dbg_in_ack(out_back[18]), .dbd_in(out_back[15:0]),
      .dbd_oe(out_back[17:16])
  );

  // The role bit is set: these twenty-one are a DEBUGGER's frame, packed as
  // `rtl/plumbing/cadr_dbg_cable.sv` packs them.
  cadr_dbg_tx #(
      .PAYLOAD_W(21), .LINES(LINES), .BEAT_T(BEAT_T), .GAP_T(GAP_T)
  ) u_out_tx (
      .clk(clk), .rst(rst),
      .tx_levels({1'b1, win_req, win_wr, win_a, win_dbd}),
      .tx_stb(oa_stb_o), .tx_d(oa_d_o)
  );

  cadr_dbg_rx #(
      .PAYLOAD_W(21), .LINES(LINES), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) u_out_rx (
      .clk(clk), .rst(rst),
      .rx_stb(oa_stb_i), .rx_d(oa_d_i),
      .rx_levels(out_back), .rx_live(out_live), .rx_active(out_act_u),
      .frame_done(out_done_u), .frame_bad(out_bad_u)
  );

  // ------------------------------------------------------- the debuggee
  logic [20:0] in_req_v;
  logic        in_live;
  logic        in_act_u, in_done_u, in_bad_u;
  assign in_live_o = in_live;

  logic        cab_req, cab_wr, cab_ack;
  logic [1:0]  cab_a, cab_oe;
  logic [15:0] cab_dbd, cab_back;
  assign cab_req_o      = cab_req;
  assign cab_wr_o       = cab_wr;
  assign cab_a_o        = cab_a;
  assign cab_dbd_o      = cab_dbd;
  assign cab_ack_o      = cab_ack;
  assign cab_dbd_back_o = cab_back;
  assign cab_oe_o       = cab_oe;

  // And the role bit is clear: a DEBUGGEE's frame, its own spare bit under it.
  cadr_dbg_tx #(
      .PAYLOAD_W(21), .LINES(LINES), .BEAT_T(BEAT_T), .GAP_T(GAP_T)
  ) u_in_tx (
      .clk(clk_b), .rst(rst_b),
      .tx_levels({1'b0, 1'b0, cab_ack, cab_oe, cab_back}),
      .tx_stb(ob_stb_o), .tx_d(ob_d_o)
  );

  cadr_dbg_rx #(
      .PAYLOAD_W(21), .LINES(LINES), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) u_in_rx (
      .clk(clk_b), .rst(rst_b),
      .rx_stb(ob_stb_i), .rx_d(ob_d_i),
      .rx_levels(in_req_v), .rx_live(in_live), .rx_active(in_act_u),
      .frame_done(in_done_u), .frame_bad(in_bad_u)
  );

  cadr_dbg_join u_join (
      .clk(clk_b), .rst(rst_b),
      .a_req(loc_req), .a_wr(loc_wr), .a_a(loc_a), .a_dbd(loc_dbd),
      .b_req(in_req_v[19] && in_req_v[20]), .b_wr(in_req_v[18]), .b_a(in_req_v[17:16]),
      .b_dbd(in_req_v[15:0]),
      .req(cab_req), .wr(cab_wr), .a(cab_a), .dbd(cab_dbd),
      .holder(holder_o)
  );

  // --------------------------------------------------------- the boundary
  //
  // A microcycle at normal speed.  See the header.
  // A normal microcycle on MIT's grid: the read tap and the restart, each
  // put through `cadr_tick_pkg::ticks` as `cadr_phase_gen.sv` puts them.
  localparam int unsigned MICROCYCLE_T = cadr_tick_pkg::ticks(85) + cadr_tick_pkg::ticks(60);
  logic [4:0] beat;
  logic       mclk;
  always_ff @(posedge clk_b) begin
    if (rst_b) begin
      beat <= 5'd0;
      mclk <= 1'b0;
    end else if (beat == 5'(MICROCYCLE_T - 1)) begin
      beat <= 5'd0;
      mclk <= 1'b1;
    end else begin
      beat <= beat + 5'd1;
      mclk <= 1'b0;
    end
  end
  assign mclk_o = mclk;

  // The board's own reset joined with the modifier register's bit 1,
  // registered --- `tb/cadr_dbgin_harness.sv` and `cadr_arty.sv` do the same
  // and say why.  The cable's two ends take the board's reset, never this.
  logic debuggee_reset, mach_rst;
  always_ff @(posedge clk_b) mach_rst <= rst_b || debuggee_reset;
  assign mach_rst_o       = mach_rst;
  assign debuggee_reset_o = debuggee_reset;

  logic        dbg_req, dbg_gnt, dbg_msyn, dbg_write, dbg_ssyn;
  logic [17:0] dbg_addr;
  logic [15:0] dbg_wdata, dbg_rdata;
  logic        timeout_inhibit_u;
  assign dbg_req_o = dbg_req;
  assign dbg_gnt_o = dbg_gnt;

  cadr_dbgin u_dbgin (
      .clk(clk_b), .rst(rst_b),
      .dbg_in_req(cab_req), .dbg_in_wr(cab_wr), .dbg_in_a(cab_a),
      .dbd_in(cab_dbd),
      .dbg_in_ack(cab_ack), .dbd_out(cab_back), .dbd_oe(cab_oe),
      .err_status(err_status),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit_u),
      .dbg_req(dbg_req), .dbg_gnt(dbg_gnt),
      .ub_msyn(dbg_msyn), .ub_write(dbg_write), .ub_addr(dbg_addr),
      .ub_wdata(dbg_wdata), .ub_ssyn(dbg_ssyn), .ub_rdata(dbg_rdata),
      .modifier_o(modifier_o), .address_o(address_o)
  );

  // ------------------------------------------- the arbiter and the block
  logic        sr_msyn, sr_write, sr_ssyn;
  logic [17:0] sr_addr;
  logic [15:0] sr_wdata, sr_rdata;
  logic [15:0] con_rdata_u;

  cadr_console_bus u_bus (
      .clk(clk_b), .rst(mach_rst), .mclk(mclk),
      .cpu_msyn(cpu_msyn), .cpu_write(cpu_write), .cpu_addr(cpu_addr),
      .cpu_wdata(cpu_wdata), .cpu_ssyn(cpu_ssyn),
      .dbg_req(dbg_req), .dbg_gnt(dbg_gnt),
      .dbg_msyn(dbg_msyn), .dbg_write(dbg_write), .dbg_addr(dbg_addr),
      .dbg_wdata(dbg_wdata), .dbg_ssyn(dbg_ssyn), .dbg_rdata(dbg_rdata),
      .con_req(1'b0), .con_gnt(con_gnt_u),
      .con_msyn(1'b0), .con_write(1'b0), .con_addr(18'd0),
      .con_wdata(16'd0), .con_ssyn(con_ssyn_u), .con_rdata(con_rdata_u),
      .sr_msyn(sr_msyn), .sr_write(sr_write), .sr_addr(sr_addr),
      .sr_wdata(sr_wdata), .sr_ssyn(sr_ssyn), .sr_rdata(sr_rdata)
  );

  logic con_gnt_u, con_ssyn_u;
  logic errstop_u, stathenb_u, prog_reset_u, prog_boot_u, promdisable_u;
  // The clock control register's other four bits and the debug IR.  There is
  // no processor in this harness, so they are folded like the mode register's
  // bits beside them: what the register block MAKES is checked here, and what
  // the machine does with it is `build/sstep.pass`'s.
  logic        step_u, nop11_u, idebug_u, ldstat_u;
  logic [47:0] debug_ir_u;
  logic [1:0] mode_speed_u;

  cadr_spy_registers u_spy (
      .clk(clk_b), .rst(mach_rst), .mclk(mclk),
      .ub_msyn(sr_msyn), .ub_write(sr_write), .ub_addr(sr_addr),
      .ub_wdata(sr_wdata), .ub_ssyn(sr_ssyn), .ub_rdata(sr_rdata),
      .spy_eadr(spy_eadr), .spy_rdata(spy_rdata),
      .step(step_u), .nop11(nop11_u), .idebug(idebug_u), .ldstat(ldstat_u),
      .debug_ir(debug_ir_u),
      .run(run_o), .promdisable(promdisable_u),
      .errstop(errstop_u), .stathenb(stathenb_u), .mode_speed(mode_speed_u),
      .prog_reset(prog_reset_u), .prog_boot(prog_boot_u),
      // `-BOOT` released: nothing in this check presses any of the three.
      .n_boot(1'b1),
      // No no-auto-boot switch here: the machine comes up as the fabric's
      // reset leaves it, with the boot button just let go.
      .no_auto_boot(1'b0)
  );

  logic unused;
  assign unused = ^{pa_act_u, pb_act_u, out_act_u, in_act_u,
                    out_done_u, out_bad_u, in_done_u, in_bad_u,
                    timeout_inhibit_u, con_gnt_u, con_ssyn_u, con_rdata_u,
                    errstop_u, stathenb_u, mode_speed_u, prog_reset_u,
                    prog_boot_u, promdisable_u,
                    step_u, nop11_u, idebug_u, ldstat_u, debug_ir_u,
                    in_req_v[19:16],
                    out_back[19]};

endmodule

`default_nettype wire
