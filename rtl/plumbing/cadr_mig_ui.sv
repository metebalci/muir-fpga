// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine's memory port onto the Memory Interface Generator's native user
// interface: one 32-bit word a request, out of a 128-bit DDR3L burst.
//
// WHERE THIS SITS.  On the Arty Z7-20 `mem_*` goes into `cadr_axi_master`,
// which turns it into single-beat AXI4, then into `cadr_axi_widen`, which
// makes it 64 bits, and then into the Zynq's own DDR controller through
// `S_AXI_HP0`.  On the Arty A7-100 there is no processing system and no DDR
// controller, so the controller is Xilinx's MIG in the fabric, and this is
// what drives it.  Everything upstream is unchanged: `cadr_xbus_ddr` asks for
// a word at a byte address and waits, exactly as it does on the other board.
//
// WHY THE NATIVE USER INTERFACE AND NOT MIG's AXI4 SLAVE.  MIG will generate
// either.  Three reasons for this one, and the first is the decisive one:
//
//   1. **The AXI slave this board's memory would present is 128 bits wide and
//      refuses narrow bursts.**  Digilent's published project file sets
//      `C0_S_AXI_DATA_WIDTH` to 128 --- which is what a 16-bit DDR3 at a 4:1
//      PHY ratio gives --- and `C0_S_AXI_SUPPORTS_NARROW_BURST` to 0.  A
//      single-beat 32-bit transaction on a 128-bit bus IS a narrow transfer.
//      So the AXI route would need either that option turned on, which is
//      logic inside the generated core nothing here can check, or a 32-to-128
//      widening of our own in front of it --- `cadr_axi_widen` one size up.
//      And that widening's whole job is choosing a lane and a byte strobe,
//      which is exactly what this module does directly, with no second
//      protocol in between.
//   2. The master is single-beat and one-in-flight by construction --- the
//      CADR "has no way to ask for the next word before it has this one" ---
//      and the user interface is a one-command-at-a-time interface.  The AXI
//      shim exists to reorder, buffer and pack bursts, none of which this
//      master can generate.
//   3. It is less generated logic in the design, and the generated logic is
//      the part of this board nothing in this repository can hold to
//      anything.
//
// **AND ONE-IN-FLIGHT IS WHAT MAKES ORDERING A NON-QUESTION.**  MIG's
// controller is configured `Normal` ordering, so it may reorder requests
// against each other.  There are never two.
//
// ---------------------------------------------------------------------------
// THE THREE ARITHMETICS, WHICH ARE THE WHOLE OF THIS MODULE
//
// **1. THE ADDRESS.**  `app_addr` is not a byte address.  It counts DRAM
// words --- 16 bits each on this board --- and MIG slices it into column, row
// and bank directly: with `UserMemoryAddressMap BANK_ROW_COLUMN` the
// generated `mig_7series_v4_2_ui_cmd.v` reads `col = app_addr[COL_WIDTH-1:0]`,
// `row` above that and `bank` above that.  The burst is eight DRAM words
// fixed, so the low three bits of the column are the burst's own and
// `app_addr[2:0]` must be zero: one user transaction is 8 x 16 = 128 bits =
// SIXTEEN BYTES.  So a byte address B becomes `app_addr = {B[27:4], 3'b000}`.
//
// **2. WHICH LANE.**  Those sixteen bytes arrive on `app_rd_data[127:0]` and
// leave on `app_wdf_data[127:0]`, least significant byte first, so the 32-bit
// word at byte address B is at bit `32 * B[3:2]`.  Getting this wrong reads
// and writes a neighbor three words away and is the classic fault this
// family of module has: `cadr_axi_widen`'s header records the same thing one
// size down, and the board's proving step is written to catch exactly it.
//
// **3. WHICH BYTES TO WRITE.**  `app_wdf_mask` is sixteen bits, one a byte,
// and a SET bit means DO NOT WRITE.  So a 32-bit write masks all sixteen
// bytes except the four of its own lane.  There is no read-modify-write here
// and there must not be one: the DDR3's data mask does it in the part.
//
// ---------------------------------------------------------------------------
// THE WRITE ORDERING, WHICH IS A RULE AND NOT A PREFERENCE.  MIG allows the
// write data to be presented before its command, with it, or up to two user
// clocks after it --- and no later.  A design that raises both together and
// then waits for each to be taken can therefore break the rule on its own, on
// the day the write data FIFO happens to be full for three cycles.  So the
// data goes FIRST and the command follows it: `app_wdf_wren` is held until
// `app_wdf_rdy` takes it, and only then does `app_en` go up.  Data at or
// before the command is always legal, so the rule cannot be broken by any
// backpressure the controller chooses to apply.  It costs one user clock on a
// write, which is 12.3 ns on this board against a bus that allows 4,250.
//
// ---------------------------------------------------------------------------
// THE ADDRESS THE MACHINE MAY NOT USE.  `cadr_ddr_map` reserves 128 MB at
// 0x1800_0000 --- a Zynq layout, where the bottom 384 MB is Linux's.  This
// board has 256 MB and no Linux, so the same reservation is put at the TOP of
// the chip, which is where it is on the other board too, and the translation
// is one constant bit: byte address {5'b00011, x[26:0]} becomes DDR byte
// address {1'b1, x[26:0]}.  No adder, and the map's constants do not move.
// The bottom 128 MB of this board's DDR3L is nobody's yet; a soft processor
// beside the machine would take it.
//
// An address outside the reservation is a FAULT and not a wrap: it is
// answered at once, with `mem_error` up and a zero word, and no command goes
// to the controller.  Wrapping it would put a wild write in DDR and let the
// machine carry on.

`default_nettype none

module cadr_mig_ui
  import cadr_ddr_map::*;
#(
    // The DDR3L on this board: 256 MB, so 28 bits of byte address.
    parameter int unsigned DDR_BYTE_BITS = 28,
    // MIG's user word: 128 bits at a 4:1 PHY ratio with a 16-bit part.
    parameter int unsigned UI_BITS       = 128,
    // MIG's application address: RANK + BANK + ROW + COLUMN = 1+3+14+10.
    parameter int unsigned APP_BITS      = 28
) (
    // MIG's own user clock, 81.25 MHz on this board, and its reset --- which
    // is `ui_clk_sync_rst` OR calibration not yet finished.  Held in reset the
    // machine's cycles are not answered and end on the bus's own 4.25 us
    // timer, exactly as they do on a board with no memory at all.
    input  var logic                    clk,
    input  var logic                    rst,

    // The port, in this clock.  `cadr_mem_cross` is what brings it here from
    // the machine's.
    input  var logic                    mem_req,      // a level, held
    input  var logic                    mem_write,
    input  var logic [31:0]             mem_addr,     // byte address
    input  var logic [31:0]             mem_wdata,
    output var logic                    mem_done,
    output var logic [31:0]             mem_rdata,
    output var logic                    mem_error,    // outside the reservation

    // MIG's native user interface, command side.
    output var logic [APP_BITS-1:0]     app_addr,
    output var logic [2:0]              app_cmd,
    output var logic                    app_en,
    input  var logic                    app_rdy,

    // ...write data side.
    output var logic [UI_BITS-1:0]      app_wdf_data,
    output var logic [UI_BITS/8-1:0]    app_wdf_mask,
    output var logic                    app_wdf_end,
    output var logic                    app_wdf_wren,
    input  var logic                    app_wdf_rdy,

    // ...and read data side.  There is no ready: MIG hands the word over when
    // it has it and the interface must take it.
    input  var logic [UI_BITS-1:0]      app_rd_data,
    input  var logic                    app_rd_data_valid
);

  // MIG's command encoding, from UG586: 000 write, 001 read.
  localparam logic [2:0] CMD_WRITE = 3'b000;
  localparam logic [2:0] CMD_READ  = 3'b001;

  // Which five bits of a byte address say "the machine's reservation", taken
  // from the map rather than written here, so that moving the map moves this.
  localparam int unsigned REGION_BITS = 32 - DDR_BYTE_BITS + 1;   // 5
  localparam logic [REGION_BITS-1:0] REGION =
      RESERVED_BASE[31 -: REGION_BITS];

  typedef enum logic [2:0] {
    IDLE,
    WDATA,    // the write data, which must not follow its command
    WCMD,
    RCMD,
    RWAIT,
    DONE      // the answer stands until the requester lets go
  } state_e;

  state_e state;

  logic [31:0] addr_q, wdata_q;

  // WHICH OF THE FOUR 32-BIT LANES OF THE SIXTEEN-BYTE BLOCK.  Named, because
  // it is read in three places --- the byte mask, the read's lane select and
  // this comment --- and a slice taken three times is three chances to take a
  // different one.
  logic [1:0] lane_q;
  assign lane_q = addr_q[3:2];

  // The translation: the machine's reservation is the top half of the chip,
  // and a user transaction is sixteen bytes of it --- so what is carried is
  // the BLOCK and the low four bits of the byte address are not part of it.
  // They are not dropped silently: `lane_q` is bits 3 and 2 and bits 1 and 0
  // are a word alignment the whole machine has.
  logic [DDR_BYTE_BITS-1:4] ddr_block;
  assign ddr_block = {1'b1, addr_q[DDR_BYTE_BITS-2:4]};

  // The top bit of `app_addr` is the rank, and this board has one rank, so it
  // is zero for ever.
  assign app_addr = {1'b0, ddr_block, 3'b000};

  // The five bits that say which region the request was for are TESTED at the
  // request and do not travel with it: a byte address inside the reservation
  // is what is left once they have been checked.  The bottom two are the word
  // alignment every address on this bus has --- `cadr_xbus_ddr` builds a byte
  // address by shifting a word address left by two --- and there is nothing
  // for them to select.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_region;
  assign unused_region = &{1'b0, addr_q[31:DDR_BYTE_BITS-1], addr_q[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

  assign app_cmd = (state == WCMD) ? CMD_WRITE : CMD_READ;
  assign app_en  = (state == WCMD) || (state == RCMD);

  // The word goes into its own lane and the other three lanes are masked.
  // Every lane carries the same word so that a wrong mask cannot be told from
  // a wrong lane by luck --- what selects is the mask alone, which is the
  // thing the DDR3 part acts on.
  assign app_wdf_data = {4{wdata_q}};
  always_comb begin
    app_wdf_mask = {(UI_BITS/8){1'b1}};
    app_wdf_mask[4*lane_q +: 4] = 4'b0000;
  end
  assign app_wdf_end  = (state == WDATA);
  assign app_wdf_wren = (state == WDATA);

  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= IDLE;
      addr_q    <= 32'd0;
      wdata_q   <= 32'd0;
      mem_done  <= 1'b0;
      mem_rdata <= 32'd0;
      mem_error <= 1'b0;
    end else begin
      unique case (state)
        IDLE: begin
          mem_done  <= 1'b0;
          mem_error <= 1'b0;
          if (mem_req) begin
            addr_q  <= mem_addr;
            wdata_q <= mem_wdata;
            if (mem_addr[31 -: REGION_BITS] != REGION) begin
              // Not ours.  Answered, so that nothing hangs, and named.
              mem_rdata <= 32'd0;
              mem_error <= 1'b1;
              mem_done  <= 1'b1;
              state     <= DONE;
            end else begin
              state <= mem_write ? WDATA : RCMD;
            end
          end
        end

        WDATA:  if (app_wdf_rdy) state <= WCMD;
        WCMD:   if (app_rdy) begin
                  mem_done <= 1'b1;
                  state    <= DONE;
                end
        RCMD:   if (app_rdy) state <= RWAIT;
        RWAIT:  if (app_rd_data_valid) begin
                  mem_rdata <= app_rd_data[32*lane_q +: 32];
                  mem_done  <= 1'b1;
                  state     <= DONE;
                end

        DONE:   if (!mem_req) begin
                  mem_done  <= 1'b0;
                  mem_error <= 1'b0;
                  state     <= IDLE;
                end

        default: state <= IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
