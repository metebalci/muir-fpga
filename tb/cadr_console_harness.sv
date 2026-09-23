// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console, the register block and the processor, wired as the attachment
// wires them --- **and this file IS the attachment, proved before it lands.**
//
// `rtl/plumbing/cadr_console.sv` is a second master on the diagnostic bus and the CADR
// is the first.  Joining them means a mux at `cadr_spy_registers`'s Unibus
// port and an arbiter in front of it, and both belong in
// `rtl/machine/cadr_memory_path.sv`, which this slice does not own --- another
// session is in that file.  So the mux and the arbiter are written here, the
// check holds them, and `docs/console.md` carries them as a patch for
// whoever owns `cadr_memory_path.sv`, `cadr_machine.sv` and `cadr_arty.sv` to
// apply.  The lines below and the lines in the patch are the same lines.
//
// **THE PROCESSOR IS THE REAL ONE.**  `cadr_microcycle` is instantiated here
// with MIT's boot PROM in its control store, driven from the same trace and
// the same stimulus `tb/cadr_microcycle_tb.cpp` drives it from --- so what
// the console reads back is the machine's own state at a microcycle the
// reference names, and not a model's.  `run`, `promdisable`, `errstop`,
// `stathenb` and the speed bits are NOT stimulus here as they are there:
// they come out of `cadr_spy_registers`, which is what the console writes.
// **That is the point of the check**: the halt is the console's, through the
// register block, and the machine that stops is the one muir's trace
// describes.
//
// WHAT THIS HARNESS ADDS THAT THE ATTACHMENT DOES NOT HAVE.  Two stimulus
// ports with no counterpart in the fabric, both there to make a property
// checkable:
//
//   `cpu_msyn` and its three companions are a Unibus master standing where
//   `cadr_busint_xbus` stands --- the CADR's own cycle to `0o766012`, which
//   the boot PROM makes.  The arbiter has to keep the two apart and this is
//   the only way to ask it to.  In the fabric these come from the bus
//   interface and are not ports at all.
//
//   `gnt_inhibit` holds the grant off for ever, which nothing in the fabric
//   can do.  It is how `LOST_T` is exercised: a bound nothing exercises is
//   not a bound, and the Arm hangs at one PC if an AXI read never completes.
//
// **AND THE CONSOLE'S RESET IS WIRED HERE THE WAY `cadr_arty.sv` WIRES IT**,
// which is the same rule as the arbiter above: the check must hold the thing
// on the board and not a copy of it.  `mach_rst` leaves `cadr_console`, is
// ORed with this harness's own `rst` --- the board's MMCM lock and BTN1 ---
// and the OR is REGISTERED, because a reset lands on some two thousand
// registers spread across the machine and `cadr_arty.sv` already registers
// `pack_rst` for exactly that reason.  What comes out drives the register
// block, the arbiter and the processor.  **It does NOT drive the console**,
// which is the decision `rtl/plumbing/cadr_console.sv`'s header argues at length: a
// console reset by the machine's reset would abandon the AXI write that
// asked for it, and a GP write that never answers hangs both Arm cores.
//
// `mach_rst_o` brings it out so that the check can count the pulse's ticks.
// A pulse is a thing you can only see by looking every tick, and its length
// is a number the module states.

`default_nettype none

module cadr_console_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- the processor's stimulus, as `tb/cadr_microcycle_tb.cpp` drives it
    input  var logic        n_memack,
    input  var logic        n_memgrant,
    input  var logic        n_loadmd,
    input  var logic [31:0] rdata,
    input  var logic        sintr,

    // --- the processor, as `Rtl::signals` and `Rtl::spy` name it
    output var logic [13:0] pc,
    output var logic [13:0] lpc,
    output var logic [13:0] opc,
    output var logic [31:0] st,
    output var logic [47:0] ir,
    output var logic [31:0] a,
    output var logic [31:0] m,
    output var logic [31:0] alu,
    output var logic [31:0] r,
    output var logic [31:0] ob,
    output var logic [31:0] q,
    output var logic [9:0]  dc,
    output var logic [25:0] lc,
    output var logic [31:0] vma,
    output var logic [31:0] md,
    output var logic        vmaok,
    output var logic        jcond,
    output var logic        nop,
    output var logic        pcs1,
    output var logic        pcs0,
    output var logic        iwrited,
    output var logic        clock_edge,
    output var logic        n_memrq,
    output var logic        wrcyc,

    // --- **THE BACKPLANE'S DISPLAY BOARDS, page 2's word 33.**  The two
    // settings leave the console and go to `cadr_machine` on the board; here
    // they leave the harness, so that the testbench can compare the LEVEL the
    // fabric holds against the WORD it reads back.  Those are two facts: a
    // console that reported the key it was given rather than the setting it
    // made would agree with itself and with nothing else.
    output var logic        tv_lispm,
    output var logic        color_tv,

    // --- **AND WHAT THE DISPLAY OUTPUT SHOWS, page 2's word 34.**  Out of the
    // harness for word 33's reason: the LEVEL the fabric holds and the WORD it
    // reads back are two facts, and a console that reported the key it was
    // given would agree with itself and with nothing else.
    output var logic [1:0]  hdmi_out,
    output var logic [1:0]  hdmi_rotate,

    // --- **AND WHETHER THE LAMPS BLINK, page 2's word 35.**  Out of the
    // harness for word 33's reason: the level the fabric holds and the word it
    // reads back are two facts.
    output var logic        steady_lamps,

    // --- **AND WHETHER THE DISPLAY OUTPUT SLEEPS, page 2's word 36.**  The
    // setting and the mute are the display output's and not the console's,
    // so the console's two pulses come out of the harness and the display's
    // three answers come in: the testbench plays the display, and what it
    // holds is that a key is carried and that a word is read back.
    output var logic        hdmi_sleep_set,
    output var logic [14:0] hdmi_sleep_secs,
    output var logic        hdmi_wake,
    input  var logic        hdmi_sleep_fitted,
    input  var logic [14:0] hdmi_sleep_q,
    input  var logic        hdmi_asleep,

    // --- `M_AXI_GP1`, brought out for the testbench's own master
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

    // --- the CADR's own Unibus master, which the fabric has and this does
    // --- not: stimulus, so that the arbiter can be asked to keep them apart
    input  var logic        cpu_msyn,
    input  var logic        cpu_write,
    input  var logic [17:0] cpu_addr,
    input  var logic [15:0] cpu_wdata,
    output var logic        cpu_ssyn,
    output var logic [15:0] cpu_rdata,

    // --- the grant held off for ever, to exercise the engine's own bound
    input  var logic        gnt_inhibit,

    // --- WHICH BUILD THE FABRIC IS, page 2's word 32.  On a board this comes
    // --- out of `rtl/plumbing/xilinx7/cadr_usr_access.sv`, a primitive
    // --- reading the part's AXSS register; here the testbench chooses it, so
    // --- that a read of word 32 is a comparison against a value the check
    // --- picked and not a confirmation of whatever the fabric happened to
    // --- hold.  That is the difference the `md` trap is about.
    input  var logic [31:0] build,

    // --- the debug cable's role: what the console asks for, and what the
    // --- connector says back.  The four inputs are the testbench playing the
    // --- connector, which is what lets it refuse.
    output var logic        dbg_connect,
    // And the cable's wiring, which is the console's own register: what it
    // holds goes out, and what the connector made of it comes back.  The
    // refusal this check is about is the console's --- a setting may not move
    // under a board that is already the debugger --- so `dbg_engaged` beside
    // it is the testbench playing the connector.
    output var logic [1:0]  dbg_wiring,
    input  var logic [2:0]  dbg_wire_state,
    input  var logic [23:0] dbg_frames,
    input  var logic        dbg_engaged,
    input  var logic        dbg_foreign,
    input  var logic        dbg_peer_far,
    input  var logic        dbg_live,
    input  var logic        dbg_active,

    // --- the machine's reset as `cadr_arty.sv` makes it: this harness's own
    // --- `rst` or the console's pulse, registered.  Watched every tick, so
    // --- that `RESET_T` is asserted as a length and not as "something
    // --- happened".
    output var logic        mach_rst_o,
    // The console's press of `-BOOT2`, brought out so the check can count the
    // pulse's ticks as it counts the reset's.
    output var logic        mach_boot_o,

    // --- what a check watches
    output var logic        con_req,
    output var logic        con_gnt,
    // The microcycle boundary and the console's acknowledgment, which are
    // the two instants the read-back's lag is measured between: `con_rdata`
    // is loaded at `mclk` and the console takes it at `-UB SSYN`.
    output var logic        mclk_o,
    output var logic        con_ssyn_o,
    output var logic        run_o,
    output var logic        promdisable_o,
    output var logic        errstop_o,
    output var logic        stathenb_o,
    output var logic [1:0]  mode_speed_o,
    output var logic        prog_reset_o,
    output var logic        prog_boot_o,

    // --- the readout window's three wires, brought out so that a check can
    // --- watch the pipeline EVERY TICK rather than through AXI.  The
    // --- property that needs it: the echo and the word arrive together, so
    // --- at the first tick the echo names the address a program asked for,
    // --- the word standing beside it is that address's.  A word a tick
    // --- staler than its echo is an echo that lies, and nothing reachable
    // --- over AXI can see it --- an AXI read cannot come back inside the
    // --- three ticks the pipeline takes, so by the time a program looks,
    // --- both a right design and a stale one have settled.  `build/readout
    // --- .pass`'s third phase is the one that looks, and
    // --- `readout-hands-over-a-word-a-tick-staler-than-its-echo` is the
    // --- record that says it bites.
    output var logic [17:0] ro_addr_o,
    output var logic [47:0] ro_data_o,
    output var logic [17:0] ro_echo_o
);

  logic [3:0]  spy_eadr;
  logic [15:0] spy_rdata;
  logic        mclk;

  // The console's half of the diagnostic bus.
  logic        con_msyn, con_write, con_ssyn;
  assign mclk_o     = mclk;
  assign con_ssyn_o = con_ssyn;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  // The readout window's three wires, console to processor and back.
  logic [17:0] con_ro_addr, con_ro_echo;
  logic [47:0] con_ro_data;
  assign ro_addr_o = con_ro_addr;
  assign ro_data_o = con_ro_data;
  assign ro_echo_o = con_ro_echo;

  // What reaches the register block, and what comes back.
  logic        sr_msyn, sr_write, sr_ssyn;
  logic [17:0] sr_addr;
  logic [15:0] sr_wdata, sr_rdata;

  // ------------------------------------------------------------------------
  // THE ARBITER AND THE MUX --- `rtl/machine/cadr_console_bus.sv`, the real one
  // ------------------------------------------------------------------------
  //
  // This harness used to hold a hand-written copy of the arbiter, because the
  // attachment had not landed and `rtl/machine/cadr_memory_path.sv` was another
  // session's file.  It has landed, and the arbiter is a module of its own
  // for exactly that reason: **two descriptions of one thing drift, and the
  // check would then be holding the copy.**  `cadr_memory_path.sv`
  // instantiates the same module in the same way, so what is checked here is
  // what is on the board.
  //
  // `gnt_inhibit` is the one thing the harness still adds, and it is stimulus
  // with no counterpart in the fabric: it holds the grant off for ever, which
  // is how `LOST_T` is exercised.
  logic con_gnt_raw;
  assign con_gnt = con_gnt_raw && !gnt_inhibit;

  // The board's own reset joined with the console's pulse, registered ---
  // `boards/arty-z7-20/cadr_arty.sv`, which does the same and says why.  Everything of the
  // machine takes this; the console takes `rst`.
  logic con_mach_rst, mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || con_mach_rst;
  assign mach_rst_o = mach_rst;

  // **AND THE CONSOLE'S OTHER BUTTON, `-BOOT2`.**  A write of `BOOT_KEY` to
  // page 0's word 13 holds the light panel's line down; `cadr_arty.sv` ORs it
  // with BTN0 and gives the result to `cadr_machine`, where the 74S02 at
  // OLORD2 1A07 makes `-BOOT` of it beside the keyboard's `-BOOT1` and the
  // debug cable's `PROG.BOOT`.  This harness has neither of those two, so the
  // gate here is the one input it has; `cadr_machine.sv` has the whole gate
  // and the account of it.
  //
  // It is wired rather than folded for the reason the readout's ports are:
  // the check must hold the thing on the board.  What `build/console.pass`
  // then holds is the whole path, a store on the AXI face to the machine
  // running the PROM from word 0 again.
  logic con_mach_boot, n_boot;
  assign n_boot     = !con_mach_boot;
  assign mach_boot_o = con_mach_boot;

  // The third master's answers, folded: see the tie-off below.
  logic        dbg_gnt_unused, dbg_ssyn_unused;
  logic [15:0] dbg_rdata_unused;
  logic        unused_dbg;
  assign unused_dbg = ^{dbg_gnt_unused, dbg_ssyn_unused, dbg_rdata_unused};

  cadr_console_bus console_bus (
      // --- the debug cable's master, `rtl/machine/cadr_dbgin.sv`, which is
      // --- NOT COMPOSED HERE YET.  `rtl/machine/cadr_console_bus.sv` carries
      // --- the third master because the arbiter must be one description of
      // --- one thing, and `tb/cadr_dbgin_harness.sv` is where it is driven
      // --- and held.  Tied off, the whole arm folds --- `dbg_own` is
      // --- constant false --- exactly as `con_req` was tied off in
      // --- `boards/arty-z7-20/cadr_arty.sv` before the console landed.
      // --- `docs/debug-cable.md` has the patch that brings it up.
      .dbg_req   (1'b0),
      .dbg_gnt   (dbg_gnt_unused),
      .dbg_msyn  (1'b0),
      .dbg_write (1'b0),
      .dbg_addr  (18'd0),
      .dbg_wdata (16'd0),
      .dbg_ssyn  (dbg_ssyn_unused),
      .dbg_rdata (dbg_rdata_unused),
      .clk       (clk),
      .rst       (mach_rst),
      .mclk      (mclk),
      .cpu_msyn  (cpu_msyn),
      .cpu_write (cpu_write),
      .cpu_addr  (cpu_addr),
      .cpu_wdata (cpu_wdata),
      .cpu_ssyn  (cpu_ssyn),
      .con_req   (con_req),
      .con_gnt   (con_gnt_raw),
      .con_msyn  (con_msyn),
      .con_write (con_write),
      .con_addr  (con_addr),
      .con_wdata (con_wdata),
      .con_ssyn  (con_ssyn),
      .con_rdata (con_rdata),
      .sr_msyn   (sr_msyn),
      .sr_write  (sr_write),
      .sr_addr   (sr_addr),
      .sr_wdata  (sr_wdata),
      .sr_ssyn   (sr_ssyn),
      .sr_rdata  (sr_rdata)
  );
  assign cpu_rdata = sr_rdata;

  // The virtual address register, `Q` and `MD` for page 0's words 7, 8 and 9,
  // captured at the microcycle boundary.  **`rtl/machine/cadr_console_state.sv`, the same
  // module `rtl/machine/cadr_machine.sv` instantiates and not a copy of it**, for the
  // reason the arbiter above is a module: two descriptions of one thing
  // drift, and the check would then be holding the copy.  In the fabric its
  // `vma` and `q` are `cadr_machine`'s internal wires off the processor;
  // here they are this harness's own outputs off the same processor.
  logic [31:0] con_vma, con_q, con_md;
  cadr_console_state console_state (
      .clk     (clk),
      .rst     (mach_rst),
      .mclk    (mclk),
      .vma     (vma),
      .q       (q),
      .md      (md),
      .con_vma (con_vma),
      .con_q   (con_q),
      .con_md  (con_md)
  );

  // The color map this harness offers, `[board][color]`: a byte a channel,
  // none of them zero and every one of them distinct in all three.
  function automatic logic [23:0] map_word(input logic board, input logic [3:0] color);
    logic [7:0] red, green, blue;
    red   = 8'd1 + {4'd0, color} + (board ? 8'd97 : 8'd0);
    green = 8'd2 + {3'd0, color, 1'b0} + (board ? 8'd53 : 8'd0);
    blue  = 8'd3 + {2'd0, color, 2'b0} + (board ? 8'd29 : 8'd0);
    return {red, green, blue};
  endfunction

  logic [3:0] tv_map_a;

  cadr_console console (
      .clk        (clk),
      .rst        (rst),
      .fabric_rst (1'b0),
      .s_awaddr   (s_awaddr),
      .s_awlen    (s_awlen),
      .s_awid     (s_awid),
      .s_awvalid  (s_awvalid),
      .s_awready  (s_awready),
      .s_wdata    (s_wdata),
      .s_wstrb    (s_wstrb),
      .s_wlast    (s_wlast),
      .s_wvalid   (s_wvalid),
      .s_wready   (s_wready),
      .s_bresp    (s_bresp),
      .s_bid      (s_bid),
      .s_bvalid   (s_bvalid),
      .s_bready   (s_bready),
      .s_araddr   (s_araddr),
      .s_arlen    (s_arlen),
      .s_arid     (s_arid),
      .s_arvalid  (s_arvalid),
      .s_arready  (s_arready),
      .s_rdata    (s_rdata),
      .s_rresp    (s_rresp),
      .s_rid      (s_rid),
      .s_rlast    (s_rlast),
      .s_rvalid   (s_rvalid),
      .s_rready   (s_rready),
      .dbg_req    (con_req),
      .dbg_gnt    (con_gnt),
      .ub_msyn    (con_msyn),
      .ub_write   (con_write),
      .ub_addr    (con_addr),
      .ub_wdata   (con_wdata),
      .ub_ssyn    (con_ssyn),
      .ub_rdata   (con_rdata),
      .clock_edge (clock_edge),
      .mach_vma   (con_vma),
      .mach_q     (con_q),
      .mach_md    (con_md),
      .build      (build),
      // The readout of the processor's memories, page 0's words 10, 11 and
      // 12.  Wired here as `boards/arty-z7-20/cadr_arty.sv` wires it, which
      // is this harness's own rule: the check must hold the thing on the
      // board and not a copy of it.  What the window IS is checked by
      // `build/readout.pass` and its own harness; what this one needs is
      // for the ports to exist, so that a console read of word 10 while the
      // machine runs is a read of something and not of an open wire.
      .ro_addr    (con_ro_addr),
      .ro_data    (con_ro_data),
      .ro_echo    (con_ro_echo),
      .mach_rst   (con_mach_rst),
      .mach_boot  (con_mach_boot),
      // The board's no-auto-boot switch, which this harness has none of: the
      // machine came up with its boot button just let go, and nobody has
      // touched a switch since.
      .no_auto_boot_held(1'b0),
      .no_auto_boot_now (1'b0),
      // **THE BACKPLANE'S DISPLAY BOARDS, page 2's word 33, AND THE TWO
      // COLOR MAPS ON PAGES 4 AND 5.**  The two settings leave the console
      // and go to `cadr_machine` on the board; here they come straight back
      // out, so that the testbench can write a key and read what the fabric
      // made of it.  The maps come the other way, out of the two `cadr_tv`
      // instances on the board and out of a pattern here --- injective in
      // the board, the color and the channel, so that a page read off the
      // wrong one cannot come back right, and no byte zero, which is what a
      // face answering nothing would give.
      .tv_lispm   (tv_lispm),
      .color_tv   (color_tv),
      .tv_map_a   (tv_map_a),
      .tv_map_q   (map_word(1'b0, tv_map_a)),
      .tv_color_map_q(map_word(1'b1, tv_map_a)),
      .hdmi_out(hdmi_out), .hdmi_rotate(hdmi_rotate),
      .steady_lamps(steady_lamps),
      .hdmi_sleep_set(hdmi_sleep_set), .hdmi_sleep_secs(hdmi_sleep_secs),
      .hdmi_wake(hdmi_wake), .hdmi_sleep_fitted(hdmi_sleep_fitted),
      .hdmi_sleep_q(hdmi_sleep_q), .hdmi_asleep(hdmi_asleep),
      // **THE DEBUG CABLE'S ROLE, page 0's word 14, AND THE CONNECTOR IS THE
      // TESTBENCH.**  `build/dbg_cable.pass` is the check that has a real one
      // and two real boards on it; what this check holds is the console's own
      // half --- that the two keys and nothing else move `dbg_connect`, and
      // that the word reports the role the fabric HAS beside the one that was
      // asked for.  Those are different facts whenever the connector refuses,
      // so the four come in as stimulus and the testbench is what refuses.
      .dbg_connect(dbg_connect),
      .dbg_wiring(dbg_wiring),
      .dbg_wire_state(dbg_wire_state),
      .dbg_frames(dbg_frames),
      .dbg_engaged(dbg_engaged),
      .dbg_foreign(dbg_foreign),
      .dbg_peer_far(dbg_peer_far),
      .dbg_live   (dbg_live),
      .dbg_active (dbg_active)
  );

  // The clock control register's other four bits and the debug IR, out of
  // the register block and into the processor: the single step, and the
  // forced microinstruction CC reads a scratchpad with.
  logic        step_w, nop11_w, idebug_w, ldstat_w;
  logic [47:0] debug_ir_w;

  cadr_spy_registers spy_registers (
      .clk        (clk),
      .rst        (mach_rst),
      .mclk       (mclk),
      .ub_msyn    (sr_msyn),
      .ub_write   (sr_write),
      .ub_addr    (sr_addr),
      .ub_wdata   (sr_wdata),
      .ub_ssyn    (sr_ssyn),
      .ub_rdata   (sr_rdata),
      .spy_eadr   (spy_eadr),
      .spy_rdata  (spy_rdata),
      .run        (run_o),
      .step       (step_w),
      .nop11      (nop11_w),
      .idebug     (idebug_w),
      .ldstat     (ldstat_w),
      .debug_ir   (debug_ir_w),
      .promdisable(promdisable_o),
      .errstop    (errstop_o),
      .stathenb   (stathenb_o),
      .mode_speed (mode_speed_o),
      .prog_reset (prog_reset_o),
      .prog_boot  (prog_boot_o),
      .n_boot     (n_boot),
      .no_auto_boot(1'b0)
  );

  logic ub_md_ack_u;

  cadr_microcycle #(
      .PROM_HEX(PROM_HEX)
  ) processor (
      .clk         (clk),
      .rst         (mach_rst),
      .n_boot      (n_boot),
      // OLORD1's three, which reach the board's lamps and nothing here.
      // `-PROMENABLE` goes to a lamp on a board and there is no lamp here.
      /* verilator lint_off PINCONNECTEMPTY */
      .machrun_o (), .errhalt_o (), .stathalt_o (), .promenable (),
      /* verilator lint_on PINCONNECTEMPTY */
      .run         (run_o),
      // The board's no-auto-boot switch, which this harness has none of: the
      // machine comes up as the fabric's reset leaves it, with the boot
      // button just let go.
      .no_auto_boot(1'b0),
      .step        (step_w),
      .nop11       (nop11_w),
      .idebug      (idebug_w),
      .ldstat      (ldstat_w),
      .debug_ir    (debug_ir_w),
      .promdisable (promdisable_o),
      .errstop     (errstop_o),
      .stathenb    (stathenb_o),
      .mode_speed  (mode_speed_o),
      .spy_eadr    (spy_eadr),
      .spy_rdata   (spy_rdata),
      .n_memack    (n_memack),
      .n_memgrant  (n_memgrant),
      .n_loadmd    (n_loadmd),
      .rdata       (rdata),
      // `UB MD LOAD`, MD's third writer: a foreign master's mapped write
      // through the Unibus map, which this harness has no register block to
      // make.  Tied off, and the acknowledgment is then never asked for.
      .ub_md_req   (1'b0),
      .ub_md_data  (32'd0),
      .ub_md_ack   (ub_md_ack_u),
      .sintr       (sintr),
      .pc          (pc),
      .lpc         (lpc),
      .opc         (opc),
      .st          (st),
      .ir          (ir),
      .a           (a),
      .m           (m),
      .alu         (alu),
      .r           (r),
      .ob          (ob),
      .q           (q),
      .dc          (dc),
      .lc          (lc),
      .vma         (vma),
      .vmaok       (vmaok),
      .jcond       (jcond),
      .nop         (nop),
      .pcs1        (pcs1),
      .pcs0        (pcs0),
      .iwrited     (iwrited),
      .md          (md),
      .phys        (phys_u),
      .wdata       (wdata_u),
      .mclk        (mclk),
      .n_memrq     (n_memrq),
      .mbusy_o     (mbusy_u),
      .mbusy_sync_o(mbusy_sync_u),
      .memstart    (memstart_u),
      .rdcyc       (rdcyc_u),
      .wrcyc       (wrcyc),
      .clock_edge  (clock_edge),
      .ro_addr     (con_ro_addr),
      .ro_data     (con_ro_data),
      .ro_echo     (con_ro_echo)
  );

  // The processor's memory-path half is not here: this harness is the
  // console, the register block and the machine, and `build/machine.pass` is
  // where the bus interface meets the processor.  Folded so that nothing
  // goes unread.
  logic [21:0] phys_u;
  logic [31:0] wdata_u;
  logic        mbusy_u, mbusy_sync_u, memstart_u, rdcyc_u;
  logic        unused;
  assign unused = ^{phys_u, wdata_u, mbusy_u, mbusy_sync_u, memstart_u, rdcyc_u,
                    ub_md_ack_u};

endmodule

`default_nettype wire
