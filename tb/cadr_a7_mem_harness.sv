// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Arty A7-100's memory path, and a model of the thing it drives.
//
// WHAT IS HERE.  Everything between the board's memory masters and the DDR3L
// controller, wired as `boards/arty-a7-100/cadr_arty_a7.sv` and
// `boards/arty-a7-100/cadr_a7_memory.sv` wire it, with a MODEL of the
// controller's native user interface in place of the 111 files of generated
// Verilog that nothing here can simulate:
//
//   * `cadr_mem_share`, the one arbiter, in the board's own index order: the
//     machine's port 0, the debugger's JTAG window 1, the disk pack face's
//     master 2, and the soft processing system's DDR window 3;
//   * `cadr_jtag_mem`, the debugger's window, as master 1;
//   * **the real `cadr_disk_pack`**, its register face driven by the testbench
//     as the firmware or Linux would drive it, its own master answered by
//     `cadr_hp2_mem` as master 2, and a model of the block store the
//     controller keeps, so that what a fetch put in a slot can be read
//     straight out of the slot and not only back through the same path;
//   * a port for the soft processing system's window, as master 3, which the
//     bridge drives on the board and the testbench drives here;
//   * `cadr_mem_cross` and `cadr_mig_ui`, and the tally at the controller's
//     edge.
//
// **THE MODEL IS THE POINT AND IT IS NOT A STUB.**  `tb/cadr_mig_stub.sv` is a
// stub: it has the port list and no behavior, and it exists so that lint can
// elaborate a board.  This is a model of what UG586 says the interface does,
// and it is written to be UNFORGIVING in the two directions that matter:
//
//   * **It answers an unwritten block with poison that is injective in the
//     address**, so a read that went to the wrong place comes back with the
//     wrong place's word rather than with zero.  A model that answered zero
//     would pass a design that dropped an address bit, which is this project's
//     control-store-comes-up-zero lesson in a third place.
//   * **It watches the protocol and says so**, with four flags the testbench
//     asserts stay clear: a command whose address is not a sixteen-byte block,
//     a write data beat that does not end its burst, a command that moves
//     while the controller has not taken it, and --- the one that is a rule
//     rather than a convention --- write data arriving more than two user
//     clocks AFTER its own command, which UG586 forbids and which a design
//     that raises both together and waits for each can do on the day the data
//     path is busy for three cycles.
//
// **AND THE MEMORY IT KEEPS IS TAGGED**, so the model itself cannot alias two
// addresses onto one word and hide the fault it exists to find.  A block whose
// tag does not match reads as never written, which is poison.
//
// **THE STORE MODEL ANSWERS TWO TICKS BEHIND THE ADDRESS**, which is what
// `rtl/machine/cadr_disk_controller.sv` does: the block RAM's own register
// and the seam's.  A store that answered at once would let the face's
// write-back take a word a tick early and still read right.

`default_nettype none

module cadr_a7_mem_harness #(
    parameter int unsigned NBLK = 4096
) (
    // ------------------------------------------------------ the machine's side
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        mem_req,
    input  var logic        mem_write,
    input  var logic [31:0] mem_addr,
    input  var logic [31:0] mem_wdata,
    output var logic        mem_done,
    output var logic [31:0] mem_rdata,
    output var logic        mem_error,

    // ------------------------------------------------------- the memory's side
    input  var logic        ui_clk,
    input  var logic        ui_rst,

    // -------------------------------------------------------- the JTAG window
    input  var logic        jtag_drck,
    input  var logic        jtag_sel,
    input  var logic        jtag_shift,
    input  var logic        jtag_capture,
    input  var logic        jtag_update,
    input  var logic        jtag_tdi,
    output var logic        jtag_tdo,
    input  var logic        calib_done,
    input  var logic        prove_has_run,
    input  var logic        prove_matched,
    output var logic        arm,
    output var logic        mach_reset,
    output var logic [63:0] tally,

    // ------------------------------------------- the disk pack face's registers
    //
    // Single beats, as the bridge and Linux both drive them.  The length is
    // zero, the identifiers are zero and every beat is the last, inside.
    input  var logic [31:0] pk_awaddr,
    input  var logic        pk_awvalid,
    output var logic        pk_awready,
    input  var logic [31:0] pk_wdata,
    input  var logic [3:0]  pk_wstrb,
    input  var logic        pk_wvalid,
    output var logic        pk_wready,
    output var logic [1:0]  pk_bresp,
    output var logic        pk_bvalid,
    input  var logic        pk_bready,
    input  var logic [31:0] pk_araddr,
    input  var logic        pk_arvalid,
    output var logic        pk_arready,
    output var logic [31:0] pk_rdata,
    output var logic [1:0]  pk_rresp,
    output var logic        pk_rvalid,
    input  var logic        pk_rready,

    // ------------------------------------------ the soft system's DDR window
    input  var logic        win_req,
    input  var logic        win_write,
    input  var logic [31:0] win_addr,
    input  var logic [31:0] win_wdata,
    output var logic        win_done,
    output var logic [31:0] win_rdata,
    output var logic        win_error,

    // ----------------------------------------- the store the face fills, read
    input  var logic [4:0]  store_peek_slot,
    input  var logic [8:0]  store_peek_addr,
    output var logic [31:0] store_peek_data,

    // -------------------------------------------------- who has the port
    output var logic        sh_busy_o,
    output var logic [1:0]  sh_owner_o,
    output var logic [3:0]  sh_done_o,

    // ------------------------------------------ the model's knobs, and its report
    //
    // Backpressure and latency are the testbench's to choose, not a random
    // number generator's: a check that stalls at a different place every time
    // it is run cannot be bisected.
    input  var logic        hold_cmd,     // the controller will not take a command
    input  var logic        hold_wdata,   // ...nor a write data beat
    input  var logic [3:0]  read_latency, // user clocks from command to word
    output var logic        viol_addr_align,
    output var logic        viol_wdf_end,
    output var logic        viol_cmd_unstable,
    output var logic        viol_wdata_late,

    // A window into the model's own memory, for the testbench alone: a byte
    // address in, the 32-bit word the model holds there out.  It is how "the
    // write landed in this lane and disturbed no other" is asked.
    input  var logic [27:0] peek_addr,
    output var logic [31:0] peek_data
);

  // ------------------------------------------------------------- the port
  logic        port_req, port_write, port_done, port_error;
  logic [31:0] port_addr, port_wdata, port_rdata;

  logic        x_req, x_write, x_done, x_error;
  logic [31:0] x_addr, x_wdata, x_rdata;

  // The arbiter's answers.
  logic [3:0]  sh_done;
  logic [31:0] sh_rdata;
  logic        sh_error, sh_busy;
  logic [1:0]  sh_owner;

  // The debugger's request.
  logic        jw_req, jw_write;
  logic [31:0] jw_addr, jw_wdata;

  // The disk pack face's master's words.
  logic        hp_mem_req, hp_mem_write;
  logic [31:0] hp_mem_addr, hp_mem_wdata;

  cadr_jtag_mem u_window (
      .clk(clk), .rst(rst),
      .p_req(jw_req), .p_write(jw_write),
      .p_addr(jw_addr), .p_wdata(jw_wdata),
      .p_done(sh_done[1]), .p_rdata(sh_rdata), .p_error(sh_error),
      .tally(tally), .calib_done(calib_done),
      .prove_has_run(prove_has_run), .prove_matched(prove_matched),
      .arm(arm), .mach_reset(mach_reset),
      .jtag_drck(jtag_drck), .jtag_sel(jtag_sel), .jtag_shift(jtag_shift),
      .jtag_capture(jtag_capture), .jtag_update(jtag_update),
      .jtag_tdi(jtag_tdi), .jtag_tdo(jtag_tdo)
  );

  cadr_mem_share #(
      .N(4)
  ) u_share (
      .clk(clk), .rst(rst),
      .req  ({win_req,   hp_mem_req,   jw_req,   mem_req}),
      .write({win_write, hp_mem_write, jw_write, mem_write}),
      .addr ({win_addr,  hp_mem_addr,  jw_addr,  mem_addr}),
      .wdata({win_wdata, hp_mem_wdata, jw_wdata, mem_wdata}),
      .done(sh_done), .rdata(sh_rdata), .error(sh_error),
      .p_req(port_req), .p_write(port_write),
      .p_addr(port_addr), .p_wdata(port_wdata),
      .p_done(port_done), .p_rdata(port_rdata), .p_error(port_error),
      .busy(sh_busy), .owner(sh_owner)
  );

  assign mem_done   = sh_done[0];
  assign mem_rdata  = sh_rdata;
  assign mem_error  = sh_error;
  assign win_done   = sh_done[3];
  assign win_rdata  = sh_rdata;
  assign win_error  = sh_error;
  assign sh_busy_o  = sh_busy;
  assign sh_owner_o = sh_owner;
  assign sh_done_o  = sh_done;

  // ---------------------------------------------- the disk pack face, real
  logic [31:0] hp_awaddr, hp_araddr;
  logic [3:0]  hp_awlen, hp_arlen;
  logic [1:0]  hp_awsize, hp_awburst, hp_arsize, hp_arburst, hp_bresp, hp_rresp;
  logic [63:0] hp_wdata, hp_rdata;
  logic [7:0]  hp_wstrb;
  logic        hp_awvalid, hp_awready, hp_wlast, hp_wvalid, hp_wready;
  logic        hp_bvalid, hp_bready, hp_arvalid, hp_arready;
  logic        hp_rlast, hp_rvalid, hp_rready;

  logic        store_we;
  logic [4:0]  store_slot;
  logic [8:0]  store_addr;
  logic [31:0] store_wdata, store_rdata;
  logic        pk_moving, pk_deny, pk_irq, pk_timed;
  logic [4:0]  pk_moving_slot;
  logic [7:0]  pk_present, pk_read_only;
  logic [11:0] pk_bid, pk_rid;
  logic        pk_rlast;

  cadr_disk_pack u_pack (
      .clk(clk), .rst(rst),
      .s_awaddr(pk_awaddr), .s_awlen(4'd0), .s_awid(12'd0),
      .s_awvalid(pk_awvalid), .s_awready(pk_awready),
      .s_wdata(pk_wdata), .s_wstrb(pk_wstrb), .s_wlast(1'b1),
      .s_wvalid(pk_wvalid), .s_wready(pk_wready),
      .s_bresp(pk_bresp), .s_bid(pk_bid), .s_bvalid(pk_bvalid),
      .s_bready(pk_bready),
      .s_araddr(pk_araddr), .s_arlen(4'd0), .s_arid(12'd0),
      .s_arvalid(pk_arvalid), .s_arready(pk_arready),
      .s_rdata(pk_rdata), .s_rresp(pk_rresp), .s_rid(pk_rid),
      .s_rlast(pk_rlast), .s_rvalid(pk_rvalid), .s_rready(pk_rready),
      .m_awaddr(hp_awaddr), .m_awlen(hp_awlen), .m_awsize(hp_awsize),
      .m_awburst(hp_awburst), .m_awvalid(hp_awvalid), .m_awready(hp_awready),
      .m_wdata(hp_wdata), .m_wstrb(hp_wstrb), .m_wlast(hp_wlast),
      .m_wvalid(hp_wvalid), .m_wready(hp_wready),
      .m_bresp(hp_bresp), .m_bvalid(hp_bvalid), .m_bready(hp_bready),
      .m_araddr(hp_araddr), .m_arlen(hp_arlen), .m_arsize(hp_arsize),
      .m_arburst(hp_arburst), .m_arvalid(hp_arvalid), .m_arready(hp_arready),
      .m_rdata(hp_rdata), .m_rresp(hp_rresp), .m_rlast(hp_rlast),
      .m_rvalid(hp_rvalid), .m_rready(hp_rready),
      .store_we(store_we), .store_slot(store_slot),
      .store_addr(store_addr), .store_wdata(store_wdata),
      .store_rdata(store_rdata),
      // The controller's side, idle: no walk, no request, nothing missed.
      .store_miss(1'b0), .ch_active(1'b0),
      .moving(pk_moving), .moving_slot(pk_moving_slot),
      .req_valid(1'b0), .req_tag(31'd0), .req_post(1'b0),
      .ch_waiting(1'b0), .ch_slot(5'd0), .ch_wrote(1'b0), .ch_hit(1'b0),
      .deny(pk_deny), .irq(pk_irq),
      .drive_present(pk_present), .drive_read_only(pk_read_only),
      .drive_timed(pk_timed)
  );

  cadr_hp2_mem u_hp2 (
      .clk(clk), .rst(rst),
      .s_awaddr(hp_awaddr), .s_awlen(hp_awlen), .s_awsize(hp_awsize),
      .s_awburst(hp_awburst), .s_awvalid(hp_awvalid), .s_awready(hp_awready),
      .s_wdata(hp_wdata), .s_wstrb(hp_wstrb), .s_wlast(hp_wlast),
      .s_wvalid(hp_wvalid), .s_wready(hp_wready),
      .s_bresp(hp_bresp), .s_bvalid(hp_bvalid), .s_bready(hp_bready),
      .s_araddr(hp_araddr), .s_arlen(hp_arlen), .s_arsize(hp_arsize),
      .s_arburst(hp_arburst), .s_arvalid(hp_arvalid), .s_arready(hp_arready),
      .s_rdata(hp_rdata), .s_rresp(hp_rresp), .s_rlast(hp_rlast),
      .s_rvalid(hp_rvalid), .s_rready(hp_rready),
      .mem_req(hp_mem_req), .mem_write(hp_mem_write),
      .mem_addr(hp_mem_addr), .mem_wdata(hp_mem_wdata),
      .mem_done(sh_done[2]), .mem_rdata(sh_rdata), .mem_error(sh_error)
  );

  // The block store, as the controller keeps it: twenty-four slots of 260
  // places --- the block, its header and two checkwords, and the tag --- and
  // the word back two ticks after its address.
  logic [31:0] store [0:23][0:259];
  logic [31:0] store_q;
  integer si, sj;
  initial begin
    for (si = 0; si < 24; si = si + 1)
      for (sj = 0; sj < 260; sj = sj + 1)
        store[si][sj] = 32'hDEAD_0000 ^ 32'(si * 260 + sj);
  end
  always_ff @(posedge clk) begin
    if (store_we && store_slot < 5'd24 && store_addr < 9'd260)
      store[store_slot][store_addr] <= store_wdata;
    store_q     <= (store_slot < 5'd24 && store_addr < 9'd260)
                   ? store[store_slot][store_addr] : 32'd0;
    store_rdata <= store_q;
  end
  assign store_peek_data = (store_peek_slot < 5'd24 && store_peek_addr < 9'd260)
                           ? store[store_peek_slot][store_peek_addr] : 32'd0;

  cadr_mem_cross u_cross (
      .a_clk(clk), .a_rst(rst),
      .a_mem_req(port_req), .a_mem_write(port_write),
      .a_mem_addr(port_addr), .a_mem_wdata(port_wdata),
      .a_mem_done(port_done), .a_mem_rdata(port_rdata),
      .a_mem_error(port_error),
      .b_clk(ui_clk), .b_rst(ui_rst),
      .b_mem_req(x_req), .b_mem_write(x_write),
      .b_mem_addr(x_addr), .b_mem_wdata(x_wdata),
      .b_mem_done(x_done), .b_mem_rdata(x_rdata), .b_mem_error(x_error)
  );

  logic [27:0]  app_addr;
  logic [2:0]   app_cmd;
  logic         app_en, app_rdy;
  logic [127:0] app_wdf_data, app_rd_data;
  logic [15:0]  app_wdf_mask;
  logic         app_wdf_end, app_wdf_wren, app_wdf_rdy;
  logic         app_rd_data_valid;

  cadr_mig_ui u_ui (
      .clk(ui_clk), .rst(ui_rst),
      .mem_req(x_req), .mem_write(x_write),
      .mem_addr(x_addr), .mem_wdata(x_wdata),
      .mem_done(x_done), .mem_rdata(x_rdata), .mem_error(x_error),
      .app_addr(app_addr), .app_cmd(app_cmd),
      .app_en(app_en), .app_rdy(app_rdy),
      .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
      .app_wdf_end(app_wdf_end), .app_wdf_wren(app_wdf_wren),
      .app_wdf_rdy(app_wdf_rdy),
      .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid)
  );

  // The tally, wired as the board wires it: at the controller's own edge, and
  // cleared by the MACHINE's reset carried into the controller's clock rather
  // than by the controller's own --- see `cadr_a7_memory.sv` for why.
  logic [2:0] rst_ui_sync;
  always_ff @(posedge ui_clk) rst_ui_sync <= {rst_ui_sync[1:0], rst};

  cadr_mem_count u_count (
      .clk(ui_clk), .rst(rst_ui_sync[2]),
      .req(x_req), .req_write(x_write),
      .bvalid(app_wdf_wren), .bready(app_wdf_rdy),
      .rvalid(app_rd_data_valid), .rready(1'b1), .rlast(1'b1),
      .gpio(tally)
  );

  // The two bits of a peek address below a word: every address on this bus is
  // word aligned and there is nothing for them to select.  And what the face
  // reports that this check does not ask about.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_peek;
  assign unused_peek = &{1'b0, peek_addr[1:0], pk_moving, pk_moving_slot,
                         pk_deny, pk_irq, pk_timed, pk_present, pk_read_only,
                         pk_bid, pk_rid, pk_rlast};
  /* verilator lint_on UNUSEDSIGNAL */

  // ===================== the model of MIG's user interface =================

  localparam logic [2:0] CMD_WRITE = 3'b000;
  localparam logic [2:0] CMD_READ  = 3'b001;

  assign app_rdy     = !hold_cmd;
  assign app_wdf_rdy = !hold_wdata;

  // The store: a block, its tag, and whether it was ever written.  The index
  // is the low part of the block address and the tag is the rest, so two
  // different addresses that share an index read as never written rather than
  // as each other.  **A model that aliased would hide exactly the fault this
  // check exists to find.**
  localparam int unsigned IDX_BITS = $clog2(NBLK);
  localparam int unsigned TAG_BITS = 24 - IDX_BITS;

  logic [127:0]        mstore       [0:NBLK-1];
  logic [TAG_BITS-1:0] mstore_tag   [0:NBLK-1];
  logic                mstore_valid [0:NBLK-1];

  integer i;
  initial begin
    for (i = 0; i < NBLK; i = i + 1) begin
      mstore[i]       = 128'd0;
      mstore_tag[i]   = '0;
      mstore_valid[i] = 1'b0;
    end
  end

  function automatic logic [31:0] poison(input logic [23:0] block,
                                         input logic [1:0]  lane);
    return 32'hB000_0000 ^ {6'd0, block, lane};
  endfunction

  function automatic logic [127:0] poison_block(input logic [23:0] block);
    return {poison(block, 2'd3), poison(block, 2'd2),
            poison(block, 2'd1), poison(block, 2'd0)};
  endfunction

  // A byte mask, a set bit meaning DO NOT WRITE, applied to a block.
  function automatic logic [127:0] merge(input logic [127:0] cur,
                                         input logic [127:0] dat,
                                         input logic [15:0]  msk);
    logic [127:0] out;
    for (int b = 0; b < 16; b++) begin
      out[8*b +: 8] = msk[b] ? cur[8*b +: 8] : dat[8*b +: 8];
    end
    return out;
  endfunction

  // The block a command names, and where it is kept.
  logic [23:0]         cmd_block;
  logic [IDX_BITS-1:0] cmd_idx;
  logic [TAG_BITS-1:0] cmd_tag;
  assign cmd_block = app_addr[26:3];
  assign cmd_idx   = cmd_block[IDX_BITS-1:0];
  assign cmd_tag   = cmd_block[23:IDX_BITS];

  logic [127:0] cmd_current;
  assign cmd_current = (mstore_valid[cmd_idx] && mstore_tag[cmd_idx] == cmd_tag)
                       ? mstore[cmd_idx] : poison_block(cmd_block);

  // The write data that arrived before its command, which is MIG's own write
  // data FIFO, one entry deep because the master never has two writes out.
  logic         wdf_have;
  logic [127:0] wdf_data;
  logic [15:0]  wdf_mask;

  // ...and the other order: a write command whose data has not come yet.
  logic                wp_valid;
  logic [23:0]         wp_block;
  logic [IDX_BITS-1:0] wp_idx;
  logic [TAG_BITS-1:0] wp_tag;
  logic [2:0]          wp_age;
  assign wp_idx = wp_block[IDX_BITS-1:0];
  assign wp_tag = wp_block[23:IDX_BITS];

  logic [127:0] wp_current;
  assign wp_current = (mstore_valid[wp_idx] && mstore_tag[wp_idx] == wp_tag)
                      ? mstore[wp_idx] : poison_block(wp_block);

  // The read in flight.  One, because the master never asks for two.
  logic [4:0]   rd_t;
  logic         rd_busy;
  logic [127:0] rd_word;

  assign app_rd_data       = rd_word;
  assign app_rd_data_valid = rd_busy && (rd_t == 5'd0);

  // What the master was holding on the previous clock, and whether it had been
  // taken, which is what says whether it was allowed to move.
  logic        seen_en, seen_taken;
  logic [2:0]  seen_cmd;
  logic [27:0] seen_addr;

  logic cmd_take, data_take;
  assign cmd_take  = app_en && app_rdy;
  assign data_take = app_wdf_wren && app_wdf_rdy;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      wdf_have          <= 1'b0;
      wdf_data          <= 128'd0;
      wdf_mask          <= 16'hFFFF;
      wp_valid          <= 1'b0;
      wp_block          <= 24'd0;
      wp_age            <= 3'd0;
      rd_busy           <= 1'b0;
      rd_t              <= 5'd0;
      rd_word           <= 128'd0;
      seen_en           <= 1'b0;
      seen_taken        <= 1'b0;
      seen_cmd          <= 3'd0;
      seen_addr         <= 28'd0;
      viol_addr_align   <= 1'b0;
      viol_wdf_end      <= 1'b0;
      viol_cmd_unstable <= 1'b0;
      viol_wdata_late   <= 1'b0;
    end else begin
      // ---- a command stands, unchanged, until the controller takes it
      if (seen_en && !seen_taken) begin
        if (!app_en || app_cmd != seen_cmd || app_addr != seen_addr) begin
          viol_cmd_unstable <= 1'b1;
        end
      end
      seen_en    <= app_en;
      seen_taken <= cmd_take;
      seen_cmd   <= app_cmd;
      seen_addr  <= app_addr;

      // ---- UG586's rule: write data may lead its command by any amount and
      // may follow it by at most two user clocks.
      if (wp_valid && !data_take) begin
        wp_age <= wp_age + 3'd1;
        if (wp_age >= 3'd2) viol_wdata_late <= 1'b1;
      end

      if (data_take && !app_wdf_end) viol_wdf_end <= 1'b1;

      // ---- the four ways a write can be completed, and the two ways it waits
      if (cmd_take && app_addr[2:0] != 3'b000) viol_addr_align <= 1'b1;
      if (cmd_take && app_addr[27] != 1'b0)    viol_addr_align <= 1'b1;

      if (wp_valid && data_take) begin
        // The command came first and its data has caught up.
        mstore[wp_idx]        <= merge(wp_current, app_wdf_data, app_wdf_mask);
        mstore_tag[wp_idx]    <= wp_tag;
        mstore_valid[wp_idx]  <= 1'b1;
        wp_valid              <= 1'b0;
      end else if (cmd_take && app_cmd == CMD_WRITE) begin
        if (data_take) begin
          mstore[cmd_idx]       <= merge(cmd_current, app_wdf_data, app_wdf_mask);
          mstore_tag[cmd_idx]   <= cmd_tag;
          mstore_valid[cmd_idx] <= 1'b1;
        end else if (wdf_have) begin
          mstore[cmd_idx]       <= merge(cmd_current, wdf_data, wdf_mask);
          mstore_tag[cmd_idx]   <= cmd_tag;
          mstore_valid[cmd_idx] <= 1'b1;
          wdf_have              <= 1'b0;
        end else begin
          wp_valid <= 1'b1;
          wp_block <= cmd_block;
          wp_age   <= 3'd0;
        end
      end else if (data_take) begin
        // Data ahead of its command: the write FIFO holds it.
        wdf_have <= 1'b1;
        wdf_data <= app_wdf_data;
        wdf_mask <= app_wdf_mask;
      end

      // ---- a read
      if (cmd_take && app_cmd == CMD_READ) begin
        rd_busy <= 1'b1;
        rd_t    <= {1'b0, read_latency};
        rd_word <= cmd_current;
      end else if (rd_busy) begin
        if (rd_t != 5'd0) rd_t <= rd_t - 5'd1;
        else              rd_busy <= 1'b0;
      end
    end
  end

  // ------------------------------------------------- the testbench's window
  logic [23:0]         peek_block;
  logic [IDX_BITS-1:0] peek_idx;
  logic [TAG_BITS-1:0] peek_tag;
  assign peek_block = peek_addr[27:4];
  assign peek_idx   = peek_block[IDX_BITS-1:0];
  assign peek_tag   = peek_block[23:IDX_BITS];

  always_comb begin
    if (mstore_valid[peek_idx] && mstore_tag[peek_idx] == peek_tag) begin
      peek_data = mstore[peek_idx][32*peek_addr[3:2] +: 32];
    end else begin
      peek_data = poison(peek_block, peek_addr[3:2]);
    end
  end

endmodule

`default_nettype wire
