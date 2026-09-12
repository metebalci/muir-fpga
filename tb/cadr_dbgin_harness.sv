// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The debug cable's debuggee end, the register block and the machine, wired
// as the attachment will wire them --- **and this file IS the attachment,
// proved before it lands.**
//
// `rtl/machine/cadr_dbgin.sv` is a third master on the diagnostic bus.
// Joining it means the arm `rtl/machine/cadr_console_bus.sv` now carries, the
// cable brought out of `cadr_machine` as ports, and
// `rtl/plumbing/cadr_debug_window.sv` on a general-purpose port beside the
// console --- and the last of those waits on a decision nobody has taken yet,
// which general-purpose port the window sits on.  `docs/debug-cable.md` poses
// that question with the numbers.  So the wiring is written here, the check
// holds it, and that document carries it as a patch for whoever owns
// `cadr_memory_path.sv`, `cadr_machine.sv` and `cadr_arty.sv` to apply.  The
// lines below and the lines in the patch are the same lines.  It is the
// console slice's own shape, one slice along, and for the same reason: two
// other sessions are in those files.
//
// **THE ARBITER IS THE REAL ONE.**  `cadr_console_bus` is instantiated here
// and in `cadr_memory_path.sv` from one module, so what is checked is what is
// on the board.  A hand-written copy here would be two descriptions of one
// thing, and the check would be holding the copy.
//
// **THE PROCESSOR IS THE REAL ONE.**  `cadr_microcycle` is instantiated with
// MIT's boot PROM in its control store, driven from the same trace and the
// same stimulus `tb/cadr_microcycle_tb.cpp` drives it from.  So when the
// debugger halts the machine over the cable and reads its program counter,
// the answer is compared against muir's own value for the microcycle the
// machine stopped at.  That is what muir's `tests/fabric.rs` does on its
// side, and it is the claim the whole slice exists to make.
//
// **AND THE REGISTER BLOCK IS THE REAL ONE**, which is what makes the cable
// worth having: `cadr_spy_registers.sv` is CC's whole vocabulary,
// `spy_write(CLK, 0)` is a halt and `spy_read(PC)` is a program counter, and
// both are ordinary Unibus cycles at `0o766000` plus twice the register
// number.  No decode stands between the cable and the bus.
//
// WHAT THIS HARNESS ADDS THAT THE ATTACHMENT DOES NOT HAVE.  Three stimulus
// ports with no counterpart in the fabric, each there to make a property
// checkable:
//
//   `cpu_msyn` and its companions are a Unibus master standing where
//   `cadr_busint_xbus` stands --- the CADR's own cycle to `0o766012`.  The
//   arbiter has to keep three masters apart and this is the only way to ask
//   it to.
//
//   `con_req` and its companions are the console standing where
//   `cadr_console.sv` stands.  The debug master beats the console and the
//   console beats nothing, and a priority nothing exercises is not a
//   priority.
//
//   `err_status` is `Machine::debug_status`'s byte, which in the fabric comes
//   from the bus interface's own error register.  Driven from outside here so
//   that the byte `-DB READ STATUS` puts on `DBD<7:0>` is somebody else's
//   value and not a constant the module invented --- a check that hands the
//   DUT the answer tests nothing, and a constant would pass a module that
//   drove a constant.
//
// **AND THE DEBUGGEE'S RESET IS WIRED HERE THE WAY THE FABRIC WILL WIRE IT.**
// The modifier register's bit 1 is `-DEBUGEE RESET`, which crosses the
// debuggee's own cables to OLORD2 and is that processor's power-on reset ---
// MIT's own note is "write a 1 here then write a 0", so it is a level and not
// a pulse, and the machine is held in reset while it stands.  Joined with
// this harness's own `rst` and registered, because a reset lands on some
// thousands of registers spread across the machine and `cadr_arty.sv` already
// registers `pack_rst` for exactly that reason.  **It does NOT reset the
// window**, for the reason `cadr_console.sv` argues about its own: a carrier
// reset by the machine's reset would abandon the request that asked for it,
// and the debugger would be left waiting for an acknowledgement from a cable
// that had forgotten the request.

`default_nettype none

module cadr_dbgin_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    // Shrunk from the module's own one second, because a bound nothing
    // exercises is not a bound and a second is 100,000,000 ticks.
    parameter int unsigned WATCHDOG_T = 4096
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

    // --- the general-purpose port the window sits on, brought out for the
    // --- testbench's own master
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

    // --- the CADR's own Unibus master, which the fabric has and this does not
    input  var logic        cpu_msyn,
    input  var logic        cpu_write,
    input  var logic [17:0] cpu_addr,
    input  var logic [15:0] cpu_wdata,
    output var logic        cpu_ssyn,

    // --- the console standing where `cadr_console.sv` stands
    input  var logic        con_req,
    output var logic        con_gnt,
    input  var logic        con_msyn,
    input  var logic        con_write,
    input  var logic [17:0] con_addr,
    input  var logic [15:0] con_wdata,
    output var logic        con_ssyn,

    // --- `Machine::debug_status`'s byte, from outside: see the header
    input  var logic [7:0]  err_status,

    // --- MIT's cable, watched every tick.  A level that moves at the wrong
    // --- instant is a thing you can only see by looking every tick.
    output var logic        cab_req,
    output var logic        cab_wr,
    output var logic [1:0]  cab_a,
    output var logic [15:0] cab_dbd_out,
    output var logic        cab_ack,
    output var logic [15:0] cab_dbd_in,
    output var logic [1:0]  cab_dbd_oe,

    // --- the two latches and the modifier's two effects
    output var logic [2:0]  modifier_o,
    output var logic [15:0] address_o,
    output var logic        debuggee_reset_o,
    output var logic        timeout_inhibit_o,

    // --- the debug master's place on the bus
    output var logic        dbg_req_o,
    output var logic        dbg_gnt_o,
    output var logic        dbg_msyn_o,
    output var logic        dbg_ssyn_o,

    // --- the machine's own state, so that a halt is visible without the cable
    output var logic        mach_rst_o,
    output var logic        run_o,
    output var logic        promdisable_o,
    output var logic        mclk_o
);

  logic [3:0]  spy_eadr;
  logic [15:0] spy_rdata;
  logic        mclk;
  assign mclk_o = mclk;

  // The cable, between the window and the DBGIN page.
  logic        dbg_in_req, dbg_in_wr, dbg_in_ack;
  logic [1:0]  dbg_in_a, dbd_oe;
  logic [15:0] dbd_to_machine, dbd_from_machine;
  assign cab_req     = dbg_in_req;
  assign cab_wr      = dbg_in_wr;
  assign cab_a       = dbg_in_a;
  assign cab_dbd_out = dbd_to_machine;
  assign cab_ack     = dbg_in_ack;
  assign cab_dbd_in  = dbd_from_machine;
  assign cab_dbd_oe  = dbd_oe;

  // The debug master's half of the diagnostic bus.
  logic        dbg_req, dbg_gnt, dbg_msyn, dbg_write, dbg_ssyn;
  logic [17:0] dbg_addr;
  logic [15:0] dbg_wdata, dbg_rdata;
  assign dbg_req_o  = dbg_req;
  assign dbg_gnt_o  = dbg_gnt;
  assign dbg_msyn_o = dbg_msyn;
  assign dbg_ssyn_o = dbg_ssyn;

  // What reaches the register block, and what comes back.
  logic        sr_msyn, sr_write, sr_ssyn;
  logic [17:0] sr_addr;
  logic [15:0] sr_wdata, sr_rdata;
  logic [15:0] con_rdata;

  // The board's own reset joined with the modifier register's bit 1,
  // registered: see the header.
  logic debuggee_reset, mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || debuggee_reset;
  assign mach_rst_o      = mach_rst;
  assign debuggee_reset_o = debuggee_reset;

  cadr_debug_window #(
      .WATCHDOG_T(WATCHDOG_T)
  ) window (
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
      .dbg_in_req (dbg_in_req),
      .dbg_in_wr  (dbg_in_wr),
      .dbg_in_a   (dbg_in_a),
      .dbd_out    (dbd_to_machine),
      .dbg_in_ack (dbg_in_ack),
      .dbd_in     (dbd_from_machine),
      .dbd_oe     (dbd_oe)
  );

  // **THE DBGIN PAGE TAKES THE BOARD'S RESET AND NOT THE ONE IT MAKES.**  MIT
  // calls modifier bit 1 "Resets the debuggee's Unibus and bus interface",
  // which reads as though this page should be in it --- and it must not be,
  // because the bit is a LEVEL: "write a 1 here then write a 0".  A modifier
  // register cleared by its own bit 1 clears the bit that is clearing it, so
  // the reset becomes a one-tick pulse and MIT's own sequence cannot be
  // written at all.  Measured here before it was understood: the check read
  // `-DEBUGEE RESET` low on the tick after it went high.  The cable's own end
  // is the cable's, like the window above it, and is reset with the board.
  cadr_dbgin dbgin (
      .clk             (clk),
      .rst             (rst),
      .dbg_in_req      (dbg_in_req),
      .dbg_in_wr       (dbg_in_wr),
      .dbg_in_a        (dbg_in_a),
      .dbd_in          (dbd_to_machine),
      .dbg_in_ack      (dbg_in_ack),
      .dbd_out         (dbd_from_machine),
      .dbd_oe          (dbd_oe),
      .err_status      (err_status),
      .debuggee_reset  (debuggee_reset),
      .timeout_inhibit (timeout_inhibit_o),
      .dbg_req         (dbg_req),
      .dbg_gnt         (dbg_gnt),
      .ub_msyn         (dbg_msyn),
      .ub_write        (dbg_write),
      .ub_addr         (dbg_addr),
      .ub_wdata        (dbg_wdata),
      .ub_ssyn         (dbg_ssyn),
      .ub_rdata        (dbg_rdata),
      .modifier_o      (modifier_o),
      .address_o       (address_o)
  );

  cadr_console_bus console_bus (
      .clk       (clk),
      .rst       (mach_rst),
      .mclk      (mclk),
      .cpu_msyn  (cpu_msyn),
      .cpu_write (cpu_write),
      .cpu_addr  (cpu_addr),
      .cpu_wdata (cpu_wdata),
      .cpu_ssyn  (cpu_ssyn),
      .dbg_req   (dbg_req),
      .dbg_gnt   (dbg_gnt),
      .dbg_msyn  (dbg_msyn),
      .dbg_write (dbg_write),
      .dbg_addr  (dbg_addr),
      .dbg_wdata (dbg_wdata),
      .dbg_ssyn  (dbg_ssyn),
      .dbg_rdata (dbg_rdata),
      .con_req   (con_req),
      .con_gnt   (con_gnt),
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
      .errstop    (errstop_u),
      .stathenb   (stathenb_u),
      .mode_speed (mode_speed_u),
      .prog_reset (prog_reset_u),
      .prog_boot  (prog_boot_u)
  );

  logic       errstop_u, stathenb_u, prog_reset_u, prog_boot_u;
  logic [1:0] mode_speed_u;

  cadr_microcycle #(
      .PROM_HEX(PROM_HEX)
  ) processor (
      .clk         (clk),
      .rst         (mach_rst),
      .run         (run_o),
      .promdisable (promdisable_o),
      .errstop     (errstop_u),
      .stathenb    (stathenb_u),
      .mode_speed  (mode_speed_u),
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
      .clock_edge  (clock_edge),
      .ro_addr     (18'd0),
      .ro_data     (ro_data_u),
      .ro_echo     (ro_echo_u)
  );

  // The processor's memory-path half is not here: this harness is the cable,
  // the register block and the machine, and `build/machine.pass` is where the
  // bus interface meets the processor.  The readout window's three wires are
  // the console's and `build/readout.pass` holds them; the address the
  // readout walks is the console's own and there is no console here, so it is
  // tied off and the two halves that come back are folded.  Folded so that
  // nothing goes unread.
  logic [21:0] phys_u;
  logic [31:0] wdata_u;
  logic        mbusy_u, mbusy_sync_u, memstart_u, rdcyc_u;
  logic [17:0] ro_echo_u;
  logic [47:0] ro_data_u;
  logic        unused;
  assign unused = ^{phys_u, wdata_u, mbusy_u, mbusy_sync_u, memstart_u,
                    rdcyc_u, prog_reset_u, prog_boot_u, con_rdata,
                    ro_data_u, ro_echo_u};

endmodule

`default_nettype wire
