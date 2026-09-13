// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `M_AXI_GP1` as the board has it: the splitter, the three slaves behind it,
// and MIT's debug cable joined up behind the second of them.
//
// **THE HARNESS IS THE ATTACHMENT, and that is the point.**  What the check
// has to demonstrate is not that `cadr_gp1_split.sv` routes --- routing is
// twenty lines --- but that **every address on the port is answered in both
// directions**, which is a property of the splitter AND of what is wired
// behind it.  A read nothing answers on a general-purpose port does not
// fault the Arm, it hangs both cores at one program counter each, measured
// on this board.  So this instantiates the real three: `cadr_console.sv` on
// the first page, `cadr_debug_window.sv` on the second and
// `cadr_gp0_default.sv` for the rest of the gigabyte, exactly as
// `boards/arty-z7-20/cadr_arty.sv` does, and the testbench sweeps the window.
//
// Each answers word 0 with something only it can answer --- "CONS", "DBUG",
// "NONE" --- so which slave took a transaction is READ OFF the reply rather
// than assumed.
//
// **AND THE WHOLE OF THE DEBUG CABLE IS HERE TOO, WHICH IS WHAT MAKES IT
// READ-BACK.**  `cadr_debug_window.sv`'s far side is MIT's twenty-one wires,
// so the only way to hold the second page to anything is to put
// `rtl/machine/cadr_dbgin.sv` on the other end of them and run a debug cycle
// across.  The debug master and the console then meet on the real arbiter,
// `rtl/machine/cadr_console_bus.sv`, in front of the real register block,
// `rtl/machine/cadr_spy_registers.sv` --- which is the arrangement
// `cadr_memory_path.sv` carries.  `build/dbgin.pass` is what holds the cable
// itself to muir and `build/console.pass` the console; this holds the two
// roads onto one bus, which nothing did before, and it is what says the
// split did not break either of them.
//
// So the read-back the check makes is this: `spy_read(eadr)` through the
// console's page and a `-DB NEED UB` cycle at `0o766000 + 2*eadr` over the
// cable through the window's page reach the SAME register and give the SAME
// word --- a word this harness's own `spy_rdata` port supplies, so neither
// module can have invented it.
//
// WHAT THIS HARNESS ADDS THAT THE ATTACHMENT DOES NOT HAVE.  Stimulus ports
// with no counterpart in the fabric, each there to make a property
// checkable:
//
//   `cpu_msyn` and its companions are a Unibus master standing where
//   `cadr_busint_xbus` stands --- the CADR's own cycle to `0o766012`.  The
//   arbiter has to keep three masters apart and this is the only way to ask
//   it to.
//
//   `spy_rdata` is the processor's sixteen-way diagnostic mux.  There is no
//   processor here, which is deliberate: what this check is about is the
//   port, and a value the testbench owns is a better read-back than one a
//   processor computes.  `build/console.pass` and `build/dbgin.pass` are
//   where the real processor is.
//
//   `mach_vma`, `mach_q` and `mach_md` are page 0's words 7, 8 and 9, from
//   outside for the same reason.
//
//   `err_status` is `Machine::debug_status`'s byte, which in the fabric
//   comes from the bus interface's own error register.
//
// **THE MICROCYCLE BOUNDARY IS MADE HERE**, a pulse every 29 ticks, because
// `cadr_console_bus.sv` captures the diagnostic mux at it and `cadr_console
// .sv` counts microcycles off `clock_edge`.  A harness with no boundary
// would leave the console's read-back frozen at its reset value and the
// check would be comparing a constant.

`default_nettype none

module cadr_gp1_split_harness #(
    // Shrunk from the window's own one second, because a bound nothing
    // exercises is not a bound and a second is 100,000,000 ticks.
    parameter int unsigned WATCHDOG_T = 4096
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- `M_AXI_GP1` as the PS would drive it -----------------------------
    input  var logic [31:0] m_awaddr,
    input  var logic [3:0]  m_awlen,
    input  var logic [11:0] m_awid,
    input  var logic        m_awvalid,
    output var logic        m_awready,
    input  var logic [31:0] m_wdata,
    input  var logic [3:0]  m_wstrb,
    input  var logic        m_wlast,
    input  var logic        m_wvalid,
    output var logic        m_wready,
    output var logic [1:0]  m_bresp,
    output var logic [11:0] m_bid,
    output var logic        m_bvalid,
    input  var logic        m_bready,
    input  var logic [31:0] m_araddr,
    input  var logic [3:0]  m_arlen,
    input  var logic [11:0] m_arid,
    input  var logic        m_arvalid,
    output var logic        m_arready,
    output var logic [31:0] m_rdata,
    output var logic [1:0]  m_rresp,
    output var logic [11:0] m_rid,
    output var logic        m_rlast,
    output var logic        m_rvalid,
    input  var logic        m_rready,

    // --- the processor's sixteen-way diagnostic mux, from outside ---------
    input  var logic [15:0] spy_rdata,
    output var logic [3:0]  spy_eadr,

    // --- page 0's words 7, 8 and 9, from outside -------------------------
    input  var logic [31:0] mach_vma,
    input  var logic [31:0] mach_q,
    input  var logic [31:0] mach_md,

    // --- `Machine::debug_status`'s byte, from outside --------------------
    input  var logic [7:0]  err_status,

    // --- the CADR's own Unibus master, which the fabric has and this does
    // --- not: stimulus, so that the arbiter can be asked to keep three
    // --- masters apart
    input  var logic        cpu_msyn,
    input  var logic        cpu_write,
    input  var logic [17:0] cpu_addr,
    input  var logic [15:0] cpu_wdata,
    output var logic        cpu_ssyn,

    // --- what a check watches --------------------------------------------
    output var logic        mclk_o,
    output var logic        con_req_o,
    output var logic        con_gnt_o,
    output var logic        dbg_req_o,
    output var logic        dbg_gnt_o,
    output var logic        cab_req_o,
    output var logic        cab_ack_o,
    output var logic        mach_rst_o,
    output var logic        run_o,
    output var logic        debuggee_reset_o
);

  // --------------------------------------------------------- the boundary
  //
  // 29 ticks, a microcycle at normal speed.  See the header: without it the
  // console's read-back never loads and the check compares a constant.
  logic [4:0] beat;
  logic       mclk;
  always_ff @(posedge clk) begin
    if (rst) begin
      beat <= 5'd0;
      mclk <= 1'b0;
    end else if (beat == 5'd28) begin
      beat <= 5'd0;
      mclk <= 1'b1;
    end else begin
      beat <= beat + 5'd1;
      mclk <= 1'b0;
    end
  end
  assign mclk_o = mclk;

  // ------------------------------------------------------- the three ports
  logic [31:0] c_awaddr, c_wdata, c_araddr, c_rdata;
  logic [3:0]  c_awlen, c_wstrb, c_arlen;
  logic [11:0] c_awid, c_arid, c_bid, c_rid;
  logic        c_awvalid, c_awready, c_wlast, c_wvalid, c_wready;
  logic        c_bvalid, c_bready, c_arvalid, c_arready;
  logic        c_rlast, c_rvalid, c_rready;
  logic [1:0]  c_bresp, c_rresp;

  logic [31:0] d_awaddr, d_wdata, d_araddr, d_rdata;
  logic [3:0]  d_awlen, d_wstrb, d_arlen;
  logic [11:0] d_awid, d_arid, d_bid, d_rid;
  logic        d_awvalid, d_awready, d_wlast, d_wvalid, d_wready;
  logic        d_bvalid, d_bready, d_arvalid, d_arready;
  logic        d_rlast, d_rvalid, d_rready;
  logic [1:0]  d_bresp, d_rresp;

  logic [31:0] x_rdata;
  logic [3:0]  x_arlen;
  logic [11:0] x_awid, x_arid, x_bid, x_rid;
  logic        x_awvalid, x_awready, x_wlast, x_wvalid, x_wready;
  logic        x_bvalid, x_bready, x_arvalid, x_arready;
  logic        x_rlast, x_rvalid, x_rready;
  logic [1:0]  x_bresp, x_rresp;

  cadr_gp1_split u_split (
      .clk(clk), .rst(rst),
      .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awid(m_awid),
      .s_awvalid(m_awvalid), .s_awready(m_awready),
      .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
      .s_wvalid(m_wvalid), .s_wready(m_wready),
      .s_bresp(m_bresp), .s_bid(m_bid), .s_bvalid(m_bvalid),
      .s_bready(m_bready),
      .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arid(m_arid),
      .s_arvalid(m_arvalid), .s_arready(m_arready),
      .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rid(m_rid),
      .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
      .con_awaddr(c_awaddr), .con_awlen(c_awlen), .con_awid(c_awid),
      .con_awvalid(c_awvalid), .con_awready(c_awready),
      .con_wdata(c_wdata), .con_wstrb(c_wstrb), .con_wlast(c_wlast),
      .con_wvalid(c_wvalid), .con_wready(c_wready),
      .con_bresp(c_bresp), .con_bid(c_bid), .con_bvalid(c_bvalid),
      .con_bready(c_bready),
      .con_araddr(c_araddr), .con_arlen(c_arlen), .con_arid(c_arid),
      .con_arvalid(c_arvalid), .con_arready(c_arready),
      .con_rdata(c_rdata), .con_rresp(c_rresp), .con_rid(c_rid),
      .con_rlast(c_rlast), .con_rvalid(c_rvalid), .con_rready(c_rready),
      .dbg_awaddr(d_awaddr), .dbg_awlen(d_awlen), .dbg_awid(d_awid),
      .dbg_awvalid(d_awvalid), .dbg_awready(d_awready),
      .dbg_wdata(d_wdata), .dbg_wstrb(d_wstrb), .dbg_wlast(d_wlast),
      .dbg_wvalid(d_wvalid), .dbg_wready(d_wready),
      .dbg_bresp(d_bresp), .dbg_bid(d_bid), .dbg_bvalid(d_bvalid),
      .dbg_bready(d_bready),
      .dbg_araddr(d_araddr), .dbg_arlen(d_arlen), .dbg_arid(d_arid),
      .dbg_arvalid(d_arvalid), .dbg_arready(d_arready),
      .dbg_rdata(d_rdata), .dbg_rresp(d_rresp), .dbg_rid(d_rid),
      .dbg_rlast(d_rlast), .dbg_rvalid(d_rvalid), .dbg_rready(d_rready),
      .dflt_awid(x_awid), .dflt_awvalid(x_awvalid), .dflt_awready(x_awready),
      .dflt_wlast(x_wlast), .dflt_wvalid(x_wvalid), .dflt_wready(x_wready),
      .dflt_bresp(x_bresp), .dflt_bid(x_bid), .dflt_bvalid(x_bvalid),
      .dflt_bready(x_bready),
      .dflt_arlen(x_arlen), .dflt_arid(x_arid), .dflt_arvalid(x_arvalid),
      .dflt_arready(x_arready),
      .dflt_rdata(x_rdata), .dflt_rresp(x_rresp), .dflt_rid(x_rid),
      .dflt_rlast(x_rlast), .dflt_rvalid(x_rvalid), .dflt_rready(x_rready)
  );

  // ----------------------------------------------------------- the console
  logic        con_req, con_gnt, con_msyn, con_write, con_ssyn;
  logic [17:0] con_addr;
  logic [15:0] con_wdata, con_rdata;
  logic [17:0] con_ro_addr, con_ro_echo;
  logic [47:0] con_ro_data;
  logic        con_mach_rst;
  assign con_req_o = con_req;
  assign con_gnt_o = con_gnt;

  cadr_console u_console (
      .clk(clk), .rst(rst),
      .s_awaddr(c_awaddr), .s_awlen(c_awlen), .s_awid(c_awid),
      .s_awvalid(c_awvalid), .s_awready(c_awready),
      .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wlast(c_wlast),
      .s_wvalid(c_wvalid), .s_wready(c_wready),
      .s_bresp(c_bresp), .s_bid(c_bid), .s_bvalid(c_bvalid),
      .s_bready(c_bready),
      .s_araddr(c_araddr), .s_arlen(c_arlen), .s_arid(c_arid),
      .s_arvalid(c_arvalid), .s_arready(c_arready),
      .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rid(c_rid),
      .s_rlast(c_rlast), .s_rvalid(c_rvalid), .s_rready(c_rready),
      .dbg_req(con_req), .dbg_gnt(con_gnt),
      .ub_msyn(con_msyn), .ub_write(con_write), .ub_addr(con_addr),
      .ub_wdata(con_wdata), .ub_ssyn(con_ssyn), .ub_rdata(con_rdata),
      .clock_edge(mclk),
      .mach_vma(mach_vma), .mach_q(mach_q), .mach_md(mach_md),
      .ro_addr(con_ro_addr), .ro_data(con_ro_data), .ro_echo(con_ro_echo),
      .mach_rst(con_mach_rst)
  );

  // The readout window's three wires belong to `build/readout.pass` and
  // there is no processor here to answer them, so the echo follows the
  // address a tick on --- which is what a reader compares against --- and
  // the word is zero.  Folded below so that nothing goes unread.
  always_ff @(posedge clk) con_ro_echo <= con_ro_addr;
  assign con_ro_data = 48'd0;

  // -------------------------------------------------- the debug cable's two
  logic        dbg_in_req, dbg_in_wr, dbg_in_ack;
  logic [1:0]  dbg_in_a, dbd_oe;
  logic [15:0] dbd_to_machine, dbd_from_machine;
  assign cab_req_o = dbg_in_req;
  assign cab_ack_o = dbg_in_ack;

  cadr_debug_window #(
      .REG_BASE(32'h8000_1000),
      .WATCHDOG_T(WATCHDOG_T)
  ) u_window (
      .clk(clk), .rst(rst),
      .s_awaddr(d_awaddr), .s_awlen(d_awlen), .s_awid(d_awid),
      .s_awvalid(d_awvalid), .s_awready(d_awready),
      .s_wdata(d_wdata), .s_wstrb(d_wstrb), .s_wlast(d_wlast),
      .s_wvalid(d_wvalid), .s_wready(d_wready),
      .s_bresp(d_bresp), .s_bid(d_bid), .s_bvalid(d_bvalid),
      .s_bready(d_bready),
      .s_araddr(d_araddr), .s_arlen(d_arlen), .s_arid(d_arid),
      .s_arvalid(d_arvalid), .s_arready(d_arready),
      .s_rdata(d_rdata), .s_rresp(d_rresp), .s_rid(d_rid),
      .s_rlast(d_rlast), .s_rvalid(d_rvalid), .s_rready(d_rready),
      .dbg_in_req(dbg_in_req), .dbg_in_wr(dbg_in_wr), .dbg_in_a(dbg_in_a),
      .dbd_out(dbd_to_machine),
      .dbg_in_ack(dbg_in_ack), .dbd_in(dbd_from_machine), .dbd_oe(dbd_oe)
  );

  // The board's own reset joined with the modifier register's bit 1,
  // registered --- `tb/cadr_dbgin_harness.sv` and `cadr_arty.sv` do the same
  // and say why.  The cable's own two ends take `rst`, never this.
  logic debuggee_reset, mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || debuggee_reset || con_mach_rst;
  assign mach_rst_o       = mach_rst;
  assign debuggee_reset_o = debuggee_reset;

  logic        dbg_req, dbg_gnt, dbg_msyn, dbg_write, dbg_ssyn;
  logic [17:0] dbg_addr;
  logic [15:0] dbg_wdata, dbg_rdata;
  logic [2:0]  modifier_u;
  logic [15:0] address_u;
  logic        timeout_inhibit_u;
  assign dbg_req_o = dbg_req;
  assign dbg_gnt_o = dbg_gnt;

  cadr_dbgin u_dbgin (
      .clk(clk), .rst(rst),
      .dbg_in_req(dbg_in_req), .dbg_in_wr(dbg_in_wr), .dbg_in_a(dbg_in_a),
      .dbd_in(dbd_to_machine),
      .dbg_in_ack(dbg_in_ack), .dbd_out(dbd_from_machine), .dbd_oe(dbd_oe),
      .err_status(err_status),
      .debuggee_reset(debuggee_reset), .timeout_inhibit(timeout_inhibit_u),
      .dbg_req(dbg_req), .dbg_gnt(dbg_gnt),
      .ub_msyn(dbg_msyn), .ub_write(dbg_write), .ub_addr(dbg_addr),
      .ub_wdata(dbg_wdata), .ub_ssyn(dbg_ssyn), .ub_rdata(dbg_rdata),
      .modifier_o(modifier_u), .address_o(address_u)
  );

  // ------------------------------------------- the arbiter and the block
  logic        sr_msyn, sr_write, sr_ssyn;
  logic [17:0] sr_addr;
  logic [15:0] sr_wdata, sr_rdata;

  cadr_console_bus u_bus (
      .clk(clk), .rst(mach_rst), .mclk(mclk),
      .cpu_msyn(cpu_msyn), .cpu_write(cpu_write), .cpu_addr(cpu_addr),
      .cpu_wdata(cpu_wdata), .cpu_ssyn(cpu_ssyn),
      .dbg_req(dbg_req), .dbg_gnt(dbg_gnt),
      .dbg_msyn(dbg_msyn), .dbg_write(dbg_write), .dbg_addr(dbg_addr),
      .dbg_wdata(dbg_wdata), .dbg_ssyn(dbg_ssyn), .dbg_rdata(dbg_rdata),
      .con_req(con_req), .con_gnt(con_gnt),
      .con_msyn(con_msyn), .con_write(con_write), .con_addr(con_addr),
      .con_wdata(con_wdata), .con_ssyn(con_ssyn), .con_rdata(con_rdata),
      .sr_msyn(sr_msyn), .sr_write(sr_write), .sr_addr(sr_addr),
      .sr_wdata(sr_wdata), .sr_ssyn(sr_ssyn), .sr_rdata(sr_rdata)
  );

  logic       errstop_u, stathenb_u, prog_reset_u, prog_boot_u;
  logic       promdisable_u;
  logic [1:0] mode_speed_u;

  cadr_spy_registers u_spy (
      .clk(clk), .rst(mach_rst), .mclk(mclk),
      .ub_msyn(sr_msyn), .ub_write(sr_write), .ub_addr(sr_addr),
      .ub_wdata(sr_wdata), .ub_ssyn(sr_ssyn), .ub_rdata(sr_rdata),
      .spy_eadr(spy_eadr), .spy_rdata(spy_rdata),
      .run(run_o), .promdisable(promdisable_u),
      .errstop(errstop_u), .stathenb(stathenb_u), .mode_speed(mode_speed_u),
      .prog_reset(prog_reset_u), .prog_boot(prog_boot_u)
  );

  // ---------------------------------------- everything else on the port
  cadr_gp0_default u_rest (
      .clk(clk), .rst(rst),
      .s_awvalid(x_awvalid), .s_awid(x_awid), .s_awready(x_awready),
      .s_wlast(x_wlast), .s_wvalid(x_wvalid), .s_wready(x_wready),
      .s_bresp(x_bresp), .s_bid(x_bid), .s_bvalid(x_bvalid),
      .s_bready(x_bready),
      .s_arlen(x_arlen), .s_arid(x_arid), .s_arvalid(x_arvalid),
      .s_arready(x_arready),
      .s_rdata(x_rdata), .s_rresp(x_rresp), .s_rid(x_rid),
      .s_rlast(x_rlast), .s_rvalid(x_rvalid), .s_rready(x_rready)
  );

  logic unused;
  assign unused = ^{modifier_u, address_u, timeout_inhibit_u,
                    errstop_u, stathenb_u, mode_speed_u,
                    prog_reset_u, prog_boot_u, promdisable_u};

endmodule

`default_nettype wire
