// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// TWO BOARDS, ONE PMOD CABLE, AND A CADR DEBUGGING A CADR.
//
// `build/dbg_pmod.pass` holds the carrier: what goes in one end comes out the
// other.  This holds the thing the carrier is for.  One board's own machine
// runs CC's four registers --- the DBGOUT page in
// `rtl/machine/cadr_busint_regs.sv` --- and the other board answers them on
// its Unibus through `rtl/machine/cadr_dbgin.sv`, with eight wires between
// them and nothing else.  The claim is not that bits cross: it is that a
// register read on one board comes back with the OTHER board's word in it.
//
// **THE TESTBENCH IS THE CABLE, AND IT IS THE CABLE THAT CAN GO WRONG.**  All
// sixteen pads are harness ports --- eight a board --- with their tri-state
// enables beside them, so the file that drives this decides what the wire
// does: joins the two, delays them, flips a bit in one beat, unplugs them, or
// leaves them floating.  **And it can see contention**: a pad driven from both
// ends is a thing to ASSERT AGAINST, not a thing to model, and the only
// reason this harness brings `pin_t` out rather than resolving the wire
// inside is that a resolved wire cannot tell you who drove it.
//
// **THE TWO BOARDS HAVE TWO CLOCKS**, as two boards do, and one reset each.
//
// **AND THE CABLE ITSELF CAN BE MADE THE WRONG WAY ROUND**, which is what a
// bench found: a ribbon made from two host sockets mirrors the header's two
// rows, so each board's pins 1 to 4 reach the other's 7 to 10.  That is the
// testbench's own variable rather than anything in the fabric, and each
// board's SETTING --- auto, straight or crossover --- is a port beside its
// `connect`, because in the fabric it is the console's word and not a
// parameter.
//
// WHERE THIS IS NOT THE BOARD.  On `boards/arty-z7-20/cadr_arty.sv` the
// register window sits beside the connector on the DBGIN page's join, and a
// whole machine sits behind the DBGOUT page; here the window's arm of the
// join is a stimulus port and the DBGOUT page's machine is the testbench
// driving a Unibus.  What is between them is the same three modules the board
// has, wired the same way.

`default_nettype none

module cadr_dbg_cable_harness #(
    // The carrier's own four, shrunk so that a check is seconds and not
    // minutes.  `LOSS_T` is what says the far end has gone.
    parameter int unsigned BEAT_T  = 6,
    parameter int unsigned GAP_T   = 18,
    parameter int unsigned GAP_MIN = 12,
    parameter int unsigned LOSS_T  = 512
) (
    // --- board A, the one that will be told to be the debugger
    input  var logic        clk_a,
    input  var logic        rst_a,
    input  var logic        connect_a,
    // Which way round board A believes the ribbon was made: 0 auto, 1
    // straight, 2 crossover.  A PORT and not a parameter, so that one binary
    // runs both cables against both settings and the four combinations are
    // one run rather than four --- the wiring is a run-time setting in the
    // fabric too, out of the console's word 14.
    input  var logic [1:0]  wire_a,
    output var logic [2:0]  a_wire_state,
    // Frames heard and frames refused, sixteen bits and eight: the crosstalk
    // instrument, and what a clean cable must read nothing in.
    output var logic [23:0] a_frames,
    // Its own machine's Unibus, which is CC writing the four registers.
    input  var logic        a_msyn,
    input  var logic        a_write,
    input  var logic [17:0] a_addr,
    input  var logic [15:0] a_wdata,
    output var logic        a_ssyn,
    output var logic [15:0] a_rdata,
    output var logic        a_select_debug,
    output var logic        a_engaged,
    output var logic        a_foreign,
    output var logic        a_peer_far,
    output var logic        a_live,
    output var logic [7:0]  a_pin_o,
    output var logic [7:0]  a_pin_t,
    input  var logic [7:0]  a_pin_i,

    // --- board B, which is a debuggee and stays one
    input  var logic        clk_b,
    input  var logic        rst_b,
    input  var logic        connect_b,
    input  var logic [1:0]  wire_b,
    output var logic [2:0]  b_wire_state,
    output var logic [23:0] b_frames,
    output var logic        b_engaged,
    output var logic        b_foreign,
    output var logic        b_peer_far,
    output var logic        b_live,
    output var logic [7:0]  b_pin_o,
    output var logic [7:0]  b_pin_t,
    input  var logic [7:0]  b_pin_i,
    // The window's arm of B's join: the second debugger, which is muir on
    // that board's own Arm cores.  A stimulus port with no counterpart in the
    // fabric, which is the only way to ask the join anything.
    input  var logic        b_win_req,
    input  var logic        b_win_wr,
    input  var logic [1:0]  b_win_a,
    input  var logic [15:0] b_win_dbd,
    output var logic        b_holder,
    // B's processor, answered from outside: `cadr_spy_registers.sv` is CC's
    // whole vocabulary and a check that handed it the answer would test
    // nothing, so the word comes from the testbench.
    input  var logic [15:0] b_spy_rdata,
    output var logic [3:0]  b_spy_eadr,
    input  var logic [7:0]  b_err_status,
    output var logic        b_debuggee_reset,
    output var logic        b_run,
    output var logic        b_dbg_gnt,
    output var logic [2:0]  b_modifier,
    output var logic [15:0] b_address
);

  // ------------------------------------------------------- board A
  //
  // The DBGOUT page and the connector.  Everything else of the register block
  // is tied off: this board's interrupt block, map and window are somebody
  // else's check and are driven to nothing here.
  logic        a_dbg_req, a_dbg_wr;
  logic [1:0]  a_dbg_a;
  logic [15:0] a_dbg_dbd;
  logic        a_dbg_ack, a_dbg_live;
  logic [15:0] a_dbg_in;

  logic        a_active_u;
  logic        a_map_req_u, a_map_write_u, a_map_md_u, a_ub_int_u, a_ub_int_hand_u;
  logic [21:0] a_map_addr_u;
  logic [31:0] a_map_wdata_u, a_map_md_wdata_u;
  logic [7:0]  a_err_status_u;

  cadr_busint_regs a_regs (
      .clk(clk_a), .rst(rst_a),
      .ub_msyn(a_msyn), .ub_write(a_write), .ub_addr(a_addr), .ub_wdata(a_wdata),
      .ub_ssyn(a_ssyn), .ub_rdata(a_rdata),
      .ub_foreign(1'b0),
      .map_req(a_map_req_u), .map_addr(a_map_addr_u), .map_write(a_map_write_u),
      .map_wdata(a_map_wdata_u), .map_done(1'b0), .map_rdata(32'd0),
      .map_md(a_map_md_u), .map_md_wdata(a_map_md_wdata_u), .map_md_done(1'b0),
      .dbgout_req(a_dbg_req), .dbgout_wr(a_dbg_wr), .dbgout_a(a_dbg_a),
      .dbgout_dbd(a_dbg_dbd), .dbgout_ack(a_dbg_ack), .dbgout_dbd_in(a_dbg_in),
      .dbgout_live(a_dbg_live), .select_debug(a_select_debug),
      .xbus_intr(1'b0), .iob_intr(1'b0), .iob_vector(8'd0),
      .timed_out(1'b0), .unibus(1'b0), .ub_int(a_ub_int_u), .ub_int_hand(a_ub_int_hand_u),
      .err_status(a_err_status_u),
      .page_err_clear(1'b0)
  );

  // A's DBGIN arm is not driven from here: this board is the debugger and
  // what arrives on its connector is answers.  The three are folded.
  logic        a_in_req_u, a_in_wr_u;
  logic [1:0]  a_in_a_u;
  logic [15:0] a_in_dbd_u;

  cadr_dbg_cable #(
      .BEAT_T(BEAT_T), .GAP_T(GAP_T), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) a_cable (
      .clk(clk_a), .rst(rst_a),
      .connect(connect_a), .engaged(a_engaged), .foreign(a_foreign),
      .peer_far(a_peer_far), .live(a_live), .active(a_active_u),
      .wiring(wire_a), .wire_state(a_wire_state), .frames(a_frames),
      .out_req(a_dbg_req), .out_wr(a_dbg_wr), .out_a(a_dbg_a), .out_dbd(a_dbg_dbd),
      .out_ack(a_dbg_ack), .out_dbd_in(a_dbg_in), .out_live(a_dbg_live),
      .in_req(a_in_req_u), .in_wr(a_in_wr_u), .in_a(a_in_a_u), .in_dbd(a_in_dbd_u),
      .in_ack(1'b0), .in_dbd_out(16'd0), .in_dbd_oe(2'b00),
      .pin_o(a_pin_o), .pin_t(a_pin_t), .pin_i(a_pin_i)
  );

  // ------------------------------------------------------- board B
  //
  // The connector, the join that keeps two debuggers apart, the DBGIN page,
  // the arbiter and the sixteen diagnostic registers: `cadr_arty.sv`'s own
  // wiring, with the window's arm brought out as stimulus.
  logic        b_cab_req, b_cab_wr, b_cab_ack;
  logic [1:0]  b_cab_a, b_cab_oe;
  logic [15:0] b_cab_dbd, b_cab_back;
  logic        b_active_u, b_out_ack_u, b_out_live_u, b_cpu_ssyn_u;
  logic [15:0] b_out_dbd_u;
  logic        b_req_v, b_wr_v;
  logic [1:0]  b_a_v;
  logic [15:0] b_dbd_v;

  cadr_dbg_cable #(
      .BEAT_T(BEAT_T), .GAP_T(GAP_T), .GAP_MIN(GAP_MIN), .LOSS_T(LOSS_T)
  ) b_cable (
      .clk(clk_b), .rst(rst_b),
      .connect(connect_b), .engaged(b_engaged), .foreign(b_foreign),
      .peer_far(b_peer_far), .live(b_live), .active(b_active_u),
      .wiring(wire_b), .wire_state(b_wire_state), .frames(b_frames),
      .out_req(1'b0), .out_wr(1'b0), .out_a(2'b00), .out_dbd(16'd0),
      .out_ack(b_out_ack_u), .out_dbd_in(b_out_dbd_u), .out_live(b_out_live_u),
      .in_req(b_req_v), .in_wr(b_wr_v), .in_a(b_a_v), .in_dbd(b_dbd_v),
      .in_ack(b_cab_ack), .in_dbd_out(b_cab_back), .in_dbd_oe(b_cab_oe),
      .pin_o(b_pin_o), .pin_t(b_pin_t), .pin_i(b_pin_i)
  );

  cadr_dbg_join b_join (
      .clk(clk_b), .rst(rst_b),
      .a_req(b_win_req), .a_wr(b_win_wr), .a_a(b_win_a), .a_dbd(b_win_dbd),
      .b_req(b_req_v), .b_wr(b_wr_v), .b_a(b_a_v), .b_dbd(b_dbd_v),
      .req(b_cab_req), .wr(b_cab_wr), .a(b_cab_a), .dbd(b_cab_dbd),
      .holder(b_holder)
  );

  // The microcycle boundary, a normal microcycle: `cadr_console_bus.sv` captures the
  // diagnostic mux at it, and a harness with no boundary would compare a
  // constant.
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

  // The machine's reset joined with the modifier register's bit 1, as the top
  // level joins it.  The cable's own end takes the BOARD's reset and never
  // this, or a debuggee reset over the cable would forget the request that
  // asked for it.
  logic b_mach_rst, b_timeout_inhibit_u;
  always_ff @(posedge clk_b) b_mach_rst <= rst_b || b_debuggee_reset;

  logic        b_dbg_req, b_dbg_msyn, b_dbg_write, b_dbg_ssyn;
  logic [17:0] b_dbg_addr;
  logic [15:0] b_dbg_wdata, b_dbg_rdata;

  cadr_dbgin b_dbgin (
      .clk(clk_b), .rst(rst_b),
      .dbg_in_req(b_cab_req), .dbg_in_wr(b_cab_wr), .dbg_in_a(b_cab_a),
      .dbd_in(b_cab_dbd),
      .dbg_in_ack(b_cab_ack), .dbd_out(b_cab_back), .dbd_oe(b_cab_oe),
      .err_status(b_err_status),
      .debuggee_reset(b_debuggee_reset), .timeout_inhibit(b_timeout_inhibit_u),
      .dbg_req(b_dbg_req), .dbg_gnt(b_dbg_gnt),
      .ub_msyn(b_dbg_msyn), .ub_write(b_dbg_write), .ub_addr(b_dbg_addr),
      .ub_wdata(b_dbg_wdata), .ub_ssyn(b_dbg_ssyn), .ub_rdata(b_dbg_rdata),
      .modifier_o(b_modifier), .address_o(b_address)
  );

  logic        b_sr_msyn, b_sr_write, b_sr_ssyn;
  logic [17:0] b_sr_addr;
  logic [15:0] b_sr_wdata, b_sr_rdata;
  logic        b_con_gnt_u, b_con_ssyn_u;
  logic [15:0] b_con_rdata_u;

  cadr_console_bus b_bus (
      .clk(clk_b), .rst(b_mach_rst), .mclk(mclk),
      .cpu_msyn(1'b0), .cpu_write(1'b0), .cpu_addr(18'd0), .cpu_wdata(16'd0),
      .cpu_ssyn(b_cpu_ssyn_u),
      .dbg_req(b_dbg_req), .dbg_gnt(b_dbg_gnt),
      .dbg_msyn(b_dbg_msyn), .dbg_write(b_dbg_write), .dbg_addr(b_dbg_addr),
      .dbg_wdata(b_dbg_wdata), .dbg_ssyn(b_dbg_ssyn), .dbg_rdata(b_dbg_rdata),
      .con_req(1'b0), .con_gnt(b_con_gnt_u),
      .con_msyn(1'b0), .con_write(1'b0), .con_addr(18'd0), .con_wdata(16'd0),
      .con_ssyn(b_con_ssyn_u), .con_rdata(b_con_rdata_u),
      .sr_msyn(b_sr_msyn), .sr_write(b_sr_write), .sr_addr(b_sr_addr),
      .sr_wdata(b_sr_wdata), .sr_ssyn(b_sr_ssyn), .sr_rdata(b_sr_rdata)
  );

  logic b_errstop_u, b_stathenb_u, b_prog_reset_u, b_prog_boot_u, b_promdisable_u;
  logic b_step_u, b_nop11_u, b_idebug_u, b_ldstat_u;
  logic [47:0] b_debug_ir_u;
  logic [1:0]  b_mode_speed_u;

  cadr_spy_registers b_spy (
      .clk(clk_b), .rst(b_mach_rst), .mclk(mclk),
      .ub_msyn(b_sr_msyn), .ub_write(b_sr_write), .ub_addr(b_sr_addr),
      .ub_wdata(b_sr_wdata), .ub_ssyn(b_sr_ssyn), .ub_rdata(b_sr_rdata),
      .spy_eadr(b_spy_eadr), .spy_rdata(b_spy_rdata),
      .step(b_step_u), .nop11(b_nop11_u), .idebug(b_idebug_u), .ldstat(b_ldstat_u),
      .debug_ir(b_debug_ir_u),
      .run(b_run), .promdisable(b_promdisable_u),
      .errstop(b_errstop_u), .stathenb(b_stathenb_u), .mode_speed(b_mode_speed_u),
      .prog_reset(b_prog_reset_u), .prog_boot(b_prog_boot_u),
      .n_boot(1'b1),
      // No no-auto-boot switch in this harness: RUN comes up preset, as the
      // fabric's reset leaves it with the boot button just let go.
      .no_auto_boot(1'b0),
      // QUUX's register page's word 102; this is the CADR's register block.
      .page_errstop_we(1'b0),
      .page_errstop   (1'b0)
  );

  logic unused;
  assign unused = ^{a_active_u, b_active_u, b_out_ack_u, b_out_live_u, b_out_dbd_u,
                    b_cpu_ssyn_u,
                    a_map_req_u, a_map_addr_u, a_map_write_u, a_map_wdata_u,
                    a_map_md_u, a_map_md_wdata_u, a_ub_int_u, a_ub_int_hand_u, a_err_status_u,
                    a_in_req_u, a_in_wr_u, a_in_a_u, a_in_dbd_u,
                    b_timeout_inhibit_u, b_con_gnt_u, b_con_ssyn_u, b_con_rdata_u,
                    b_errstop_u, b_stathenb_u, b_prog_reset_u, b_prog_boot_u,
                    b_promdisable_u, b_step_u, b_nop11_u, b_idebug_u, b_ldstat_u,
                    b_debug_ir_u, b_mode_speed_u};

endmodule

`default_nettype wire
