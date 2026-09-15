// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The DDR3L behind the machine's memory port on this board: the generated
// controller, the crossing into its clock, the driver for its user interface,
// and the tally at its edge.
//
// **NOTHING CHECKS THIS FILE AND THAT IS WHAT IT IS FOR.**  It is the seam
// between three things that are checked --- `cadr_mem_cross`, `cadr_mig_ui`
// and `cadr_mem_count`, each with a testbench of its own --- and one thing
// that cannot be: 111 files of generated Verilog implementing a DDR3
// calibration sequence, a per-bit deskew PHY and a bank manager.  Keeping the
// wiring here and the logic there is what makes the unchecked part as small
// as it can be.  `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` says the same thing
// about the display's serializers and for the same reason.
//
// **AND IT IS IN THIS DIRECTORY AND NOT IN `rtl/plumbing/xilinx7/` ON
// PURPOSE.**  It names `cadr_mig_a7`, which is generated for THIS board's
// memory part, THIS board's pins and THIS board's part number, and the other
// two boards' Vivado flows read everything under `rtl/` --- a module there
// naming a core that does not exist in their build would be a black box in
// their design.  The layout rule puts vendor-specific pieces that are not a
// board's in the plumbing; this one is a board's.
//
// ---------------------------------------------------------------------------
// THE TWO CLOCKS, AND HOW THEY COEXIST
//
// This board has ONE 100 MHz oscillator and this design has ONE clock manager
// in its top level, which is what `boards/arty-z7-20/vivado/tick.tcl` requires
// and what makes the tick a number the constraints and the fabric cannot
// disagree about.  That manager's voltage-controlled oscillator runs at
// 1000 MHz and it divides it two ways:
//
//     CLKOUT0   1000 / 10   100 MHz     the machine's tick, and the
//                                       controller's system clock
//     CLKOUT1   1000 /  5   200 MHz     the controller's reference clock
//
// The controller then makes its own clocks from that same 100 MHz with a
// phase-locked loop of its own --- 100 x 13 = 1300 MHz, over four for a
// 325 MHz memory clock, over four again for an 81.25 MHz user clock ---
// which is why the project file says "No Buffer" for both of its inputs: it
// is given clocks rather than pins.  **Digilent's published file takes E3
// itself**, which cannot be done here, because the top level's own manager
// already has that pad and two input buffers on one pad is an error.
//
// The controller's phase-locked loop is therefore one more load on the
// machine's own clock net, which is a global net already driving some
// thousands of registers and is not a timing question.
//
// The 200 MHz reference is what the input delay controller calibrates
// against, and it has to be 200 MHz and accurate.  It comes off the same
// oscillator through the same manager as everything else, so it is exactly
// 200 MHz whenever the machine's tick is exactly 10 ns.
//
// **THE TWO DOMAINS ARE DECLARED UNRELATED**, in
// `boards/arty-a7-100/cadr_a7_ddr.xdc` and the flow beside it, and they are
// crossed at exactly one
// place: `cadr_mem_cross`, on the `mem_*` handshake, which was already a
// four-phase handshake with one transaction in flight.  They come from one
// oscillator so they do not drift, but they pass through two different clock
// managers, so their edges have no fixed relationship and a common period of
// 60 ns --- timing a path between them would ask for a two-nanosecond setup
// and would be answering a question nobody asked.
//
// ---------------------------------------------------------------------------
// WHAT RESETS WHAT, WHICH IS NOT ALL ONE THING
//
// `rst` here is the FABRIC's reset --- the clock manager not locked, or BTN3
// --- and it is what resets the controller.  It is deliberately NOT the
// machine's reset: pressing the boot button on a CADR does not erase its
// memory, and a controller reset would both erase it and cost a millisecond
// of retraining.  The top level passes the right one.
//
// Calibration takes about a millisecond after a fabric reset and the machine
// reaches its first main-memory cycle at microcycle 536,303, which is 118 ms
// after its own reset.  So the memory is always trained before the machine
// asks.  While it is not, `cadr_mig_ui` is held in reset, nothing is answered,
// and the machine's cycles end on the bus's 4.25 us timer exactly as they do
// on a board with no memory at all --- which is the right behavior and not a
// hang.
//
// ---------------------------------------------------------------------------
// ORDERING.  The controller is configured `Normal`, which lets it reorder
// requests against each other to keep pages open --- but never two requests to
// the same address, and here there are never two requests at all: the CADR
// "has no way to ask for the next word before it has this one", so the second
// command is not issued until the first has been answered.

`default_nettype none

module cadr_a7_memory (
    // The machine's own clock and the fabric's reset, both in that domain.
    input  var logic        clk,
    input  var logic        rst,

    // The controller's two inputs, made by the top level's clock manager.
    input  var logic        sys_clk,   // 100 MHz, on a global buffer
    input  var logic        ref_clk,   // 200 MHz, on a global buffer

    // The machine's memory port, in `clk`.
    input  var logic        mem_req,
    input  var logic        mem_write,
    input  var logic [31:0] mem_addr,
    input  var logic [31:0] mem_wdata,
    output var logic        mem_done,
    output var logic [31:0] mem_rdata,
    output var logic        mem_error,

    // What the observer reads.  `tally` is `cadr_mem_count`'s sixty-four bits
    // and is in the CONTROLLER's clock: it is read over JTAG hundreds of
    // milliseconds later, by which time the boot PROM has stopped touching
    // memory altogether, and the Arty Z7-20's own tally has exactly the same
    // property --- a debugger sampling pins that are still counting reads a
    // count that was true at some instant.
    output var logic [63:0] tally,
    output var logic        calib_done,

    // The DDR3L itself.
    inout  wire  [15:0]     ddr3_dq,
    inout  wire  [1:0]      ddr3_dqs_p,
    inout  wire  [1:0]      ddr3_dqs_n,
    output var logic [13:0] ddr3_addr,
    output var logic [2:0]  ddr3_ba,
    output var logic        ddr3_ras_n,
    output var logic        ddr3_cas_n,
    output var logic        ddr3_we_n,
    output var logic        ddr3_reset_n,
    output var logic [0:0]  ddr3_ck_p,
    output var logic [0:0]  ddr3_ck_n,
    output var logic [0:0]  ddr3_cke,
    output var logic [0:0]  ddr3_cs_n,
    output var logic [1:0]  ddr3_dm,
    output var logic [0:0]  ddr3_odt
);

  // ------------------------------------------------ the controller's side
  logic        ui_clk, ui_clk_sync_rst;
  logic        ui_rst;
  logic [27:0] app_addr;
  logic [2:0]  app_cmd;
  logic        app_en, app_rdy;
  logic [127:0] app_wdf_data, app_rd_data;
  logic [15:0] app_wdf_mask;
  logic        app_wdf_end, app_wdf_wren, app_wdf_rdy;
  logic        app_rd_data_valid, app_rd_data_end;
  logic        app_sr_active, app_ref_ack, app_zq_ack;
  logic [11:0] device_temp;

  assign ui_rst = ui_clk_sync_rst || !calib_done;

  // The fabric's reset carried into the controller's clock, for the tally
  // alone.  **NOT `ui_rst`**: a tally the controller's own reset cleared would
  // erase itself every time calibration ran, and would read "nothing was
  // asked" on a controller that never trained --- which is the one reading
  // that has to mean something else.  That is the Arty Z7-20's argument about
  // `axi_rst` word for word.
  logic [2:0] rst_ui_sync;
  always_ff @(posedge ui_clk) rst_ui_sync <= {rst_ui_sync[1:0], rst};

  // ----------------------------------------------- the port, in ui_clk
  logic        b_req, b_write, b_done, b_error;
  logic [31:0] b_addr, b_wdata, b_rdata;

  cadr_mem_cross u_cross (
      .a_clk(clk), .a_rst(rst),
      .a_mem_req(mem_req), .a_mem_write(mem_write),
      .a_mem_addr(mem_addr), .a_mem_wdata(mem_wdata),
      .a_mem_done(mem_done), .a_mem_rdata(mem_rdata),
      .a_mem_error(mem_error),
      .b_clk(ui_clk), .b_rst(ui_rst),
      .b_mem_req(b_req), .b_mem_write(b_write),
      .b_mem_addr(b_addr), .b_mem_wdata(b_wdata),
      .b_mem_done(b_done), .b_mem_rdata(b_rdata), .b_mem_error(b_error)
  );

  cadr_mig_ui u_ui (
      .clk(ui_clk), .rst(ui_rst),
      .mem_req(b_req), .mem_write(b_write),
      .mem_addr(b_addr), .mem_wdata(b_wdata),
      .mem_done(b_done), .mem_rdata(b_rdata), .mem_error(b_error),
      .app_addr(app_addr), .app_cmd(app_cmd),
      .app_en(app_en), .app_rdy(app_rdy),
      .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
      .app_wdf_end(app_wdf_end), .app_wdf_wren(app_wdf_wren),
      .app_wdf_rdy(app_wdf_rdy),
      .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid)
  );

  // ------------------------------------------------------- the tally
  //
  // **IT COUNTS AT THE CONTROLLER'S OWN EDGE AND NOT AT THE MACHINE'S.**  The
  // Arty Z7-20's counts the processing system's B and R beats, which is the
  // far side of everything the fabric wrote; this counts what the controller's
  // user interface ACCEPTED --- a command taken is `app_en` with `app_rdy`,
  // which is inside `cadr_mig_ui`'s own request level, and a write's data
  // taken is `app_wdf_wren` with `app_wdf_rdy`, and a read answered is
  // `app_rd_data_valid`.  A fabric that issued nothing cannot make the
  // controller produce a read word, which is what makes this a POSITIVE
  // witness rather than a restatement of what we asked for.
  cadr_mem_count u_count (
      .clk(ui_clk), .rst(rst_ui_sync[2]),
      .req(b_req), .req_write(b_write),
      .bvalid(app_wdf_wren), .bready(app_wdf_rdy),
      .rvalid(app_rd_data_valid), .rready(1'b1), .rlast(1'b1),
      .gpio(tally)
  );

  // ------------------------------------------------- the generated core
  //
  // The port list is `boards/arty-a7-100/mig/gen/.../cadr_mig_a7.veo`'s, which
  // is the generator's own instantiation template, so that this can be checked
  // against it by eye rather than against memory.
  cadr_mig_a7 u_mig (
      .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
      .ddr3_cas_n(ddr3_cas_n), .ddr3_ck_n(ddr3_ck_n), .ddr3_ck_p(ddr3_ck_p),
      .ddr3_cke(ddr3_cke), .ddr3_ras_n(ddr3_ras_n),
      .ddr3_reset_n(ddr3_reset_n), .ddr3_we_n(ddr3_we_n),
      .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
      .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt),
      .init_calib_complete(calib_done),
      .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en),
      .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
      .app_wdf_wren(app_wdf_wren), .app_wdf_mask(app_wdf_mask),
      .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end),
      .app_rd_data_valid(app_rd_data_valid),
      .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
      // Self refresh, refresh and impedance recalibration are the
      // controller's own business here: nothing in this design asks for one,
      // and the controller refreshes on its own timer whatever these say.
      .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
      .app_sr_active(app_sr_active), .app_ref_ack(app_ref_ack),
      .app_zq_ack(app_zq_ack),
      .ui_clk(ui_clk), .ui_clk_sync_rst(ui_clk_sync_rst),
      .device_temp(device_temp),
      .sys_clk_i(sys_clk), .clk_ref_i(ref_clk),
      // ACTIVE LOW, which the project file says and this is the only place it
      // matters.
      .sys_rst(!rst)
  );

  // The five things the controller reports that nothing here reads.  Folded
  // rather than left dangling, so that lint's complaint about an unread signal
  // stays a complaint about a real mistake.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, app_sr_active, app_ref_ack, app_zq_ack,
                    app_rd_data_end, device_temp};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
