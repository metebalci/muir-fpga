// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Arty A7-100's memory path, and a model of the thing it drives.
//
// WHAT IS HERE.  The three modules between the machine's memory port and the
// DDR3L controller --- `cadr_jtag_mem`, `cadr_mem_cross` and `cadr_mig_ui` ---
// wired exactly as `boards/arty-a7-100/cadr_a7_memory.sv` wires them, with a
// MODEL of the controller's native user interface in place of the 111 files of
// generated Verilog that nothing here can simulate.
//
// **THE MODEL IS THE POINT AND IT IS NOT A STUB.**  `tb/cadr_mig_stub.sv` is a
// stub: it has the port list and no behaviour, and it exists so that lint can
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

  cadr_jtag_mem u_window (
      .clk(clk), .rst(rst),
      .m_req(mem_req), .m_write(mem_write),
      .m_addr(mem_addr), .m_wdata(mem_wdata),
      .m_done(mem_done), .m_rdata(mem_rdata), .m_error(mem_error),
      .p_req(port_req), .p_write(port_write),
      .p_addr(port_addr), .p_wdata(port_wdata),
      .p_done(port_done), .p_rdata(port_rdata), .p_error(port_error),
      .tally(tally), .calib_done(calib_done),
      .prove_has_run(prove_has_run), .prove_matched(prove_matched),
      .arm(arm), .mach_reset(mach_reset),
      .jtag_drck(jtag_drck), .jtag_sel(jtag_sel), .jtag_shift(jtag_shift),
      .jtag_capture(jtag_capture), .jtag_update(jtag_update),
      .jtag_tdi(jtag_tdi), .jtag_tdo(jtag_tdo)
  );

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
  // word aligned and there is nothing for them to select.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_peek;
  assign unused_peek = &{1'b0, peek_addr[1:0]};
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

  logic [127:0]        store       [0:NBLK-1];
  logic [TAG_BITS-1:0] store_tag   [0:NBLK-1];
  logic                store_valid [0:NBLK-1];

  integer i;
  initial begin
    for (i = 0; i < NBLK; i = i + 1) begin
      store[i]       = 128'd0;
      store_tag[i]   = '0;
      store_valid[i] = 1'b0;
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
  assign cmd_current = (store_valid[cmd_idx] && store_tag[cmd_idx] == cmd_tag)
                       ? store[cmd_idx] : poison_block(cmd_block);

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
  assign wp_current = (store_valid[wp_idx] && store_tag[wp_idx] == wp_tag)
                      ? store[wp_idx] : poison_block(wp_block);

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
        store[wp_idx]        <= merge(wp_current, app_wdf_data, app_wdf_mask);
        store_tag[wp_idx]    <= wp_tag;
        store_valid[wp_idx]  <= 1'b1;
        wp_valid             <= 1'b0;
      end else if (cmd_take && app_cmd == CMD_WRITE) begin
        if (data_take) begin
          store[cmd_idx]       <= merge(cmd_current, app_wdf_data, app_wdf_mask);
          store_tag[cmd_idx]   <= cmd_tag;
          store_valid[cmd_idx] <= 1'b1;
        end else if (wdf_have) begin
          store[cmd_idx]       <= merge(cmd_current, wdf_data, wdf_mask);
          store_tag[cmd_idx]   <= cmd_tag;
          store_valid[cmd_idx] <= 1'b1;
          wdf_have             <= 1'b0;
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
    if (store_valid[peek_idx] && store_tag[peek_idx] == peek_tag) begin
      peek_data = store[peek_idx][32*peek_addr[3:2] +: 32];
    end else begin
      peek_data = poison(peek_block, peek_addr[3:2]);
    end
  end

endmodule

`default_nettype wire
