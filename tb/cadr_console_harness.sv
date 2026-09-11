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
// ORed with this harness's own `rst` --- the board's MMCM lock and BTN0 ---
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

    // --- the machine's reset as `cadr_arty.sv` makes it: this harness's own
    // --- `rst` or the console's pulse, registered.  Watched every tick, so
    // --- that `RESET_T` is asserted as a length and not as "something
    // --- happened".
    output var logic        mach_rst_o,

    // --- what a check watches
    output var logic        con_req,
    output var logic        con_gnt,
    // The microcycle boundary and the console's acknowledgement, which are
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
    output var logic        prog_boot_o
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

  cadr_console_bus console_bus (
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

  cadr_console console (
      .clk        (clk),
      .rst        (rst),
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
      .mach_rst   (con_mach_rst)
  );

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
      .promdisable(promdisable_o),
      .errstop    (errstop_o),
      .stathenb   (stathenb_o),
      .mode_speed (mode_speed_o),
      .prog_reset (prog_reset_o),
      .prog_boot  (prog_boot_o)
  );

  cadr_microcycle #(
      .PROM_HEX(PROM_HEX)
  ) processor (
      .clk         (clk),
      .rst         (mach_rst),
      .run         (run_o),
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
      .clock_edge  (clock_edge)
  );

  // The processor's memory-path half is not here: this harness is the
  // console, the register block and the machine, and `build/machine.pass` is
  // where the bus interface meets the processor.  Folded so that nothing
  // goes unread.
  logic [21:0] phys_u;
  logic [31:0] wdata_u;
  logic        mbusy_u, mbusy_sync_u, memstart_u, rdcyc_u;
  logic        unused;
  assign unused = ^{phys_u, wdata_u, mbusy_u, mbusy_sync_u, memstart_u, rdcyc_u};

endmodule

`default_nettype wire
