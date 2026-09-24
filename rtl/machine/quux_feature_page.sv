// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's feature page: one page of Xbus I/O space in which the machine lists
// its sizes, physical `17377000`-`17377377` (page 36776), read-only.
//
// muir's `Geometry::feature_word` and `Machine::bus_read`, ported.  A read is
// answered as an Xbus device answers, `Responder::Device` in muir's `rtl`
// engine, and a write is acknowledged and goes nowhere.  The words, at muir's
// pin:
//
//     0    the MACHINE-ID, as functional source 16 gives it
//     1    the level-1 map entry's bits, 6
//     2    the level-2 map's entries, 32 << 6 = 2,048
//     3    the PDL buffer's words, 1 << 14 = 16,384
//     4    the control store's words, 16,384
//     5    A memory's words, 1,024
//     6    the dispatch memory's words, 2,048
//     7    the multiply and divide, 3: bit 0 MUL, bit 1 DIV
//     10   the processor tick, 1
//     11   the main screen's width in 31:16 and height in 15:0
//     12   the main screen's bits a pixel in 31:16 and words a line in 15:0
//     13   the main screen's buffer, its first physical address, `17000000`
//     the rest, 0
//
// Words 11 to 13 are the display's: MONO TV at the bitstreams' 1280 by 1024,
// 40 words a line.  The values are parameters that `cadr_machine.sv` sets
// from the one place each is decided, so this page and the thing it
// describes cannot disagree by an edit to one of them.
//
// **ONLY QUUX HAS IT.**  `cadr_machine.sv` builds this module under
// `MACHINE == "quux"` and nowhere else, and on the CADR the page times out
// with the Xbus NXM bit, which `build/quux_map.pass` holds against muir's CADR.
//
// **THE MATCH IS HELD ONE TICK, AS THE DISK CONTROLLER'S IS, AND FOR ITS
// REASON.**  `phys` is the far end of the map, and `dev_ack` must stay a gate
// on a held match: `cadr_disk_controller.sv` has the measurement at `mine_c`.
// `-XBUS.RQ` goes out sixteen ticks after the grant, so a match a tick behind
// the address is settled long before anything reads it.
//
// **ITS OWN PAGE MATCH IS NOT WHAT BOUNDS IT, AND NO CHECK CAN SAY IT IS.**
// The page sees a cycle only when the held decode has already called it a
// device's, and the only other device words anywhere near it are the
// display's registers and the disk's in page 36777, which answer for
// themselves and whose words win on the seam: a match here widened to that
// page is unobservable, measured, and a match widened below it never sees a
// cycle.  What bounds the page is `cadr_xbus_decode.sv`, which
// `build/xbus_decode.quux.pass` holds over every address.
//
// What holds it: `build/quux_map.quux.pass`, whose program reads words 0 to
// 14, 100, 200 and 377 through the map and compares `MD` on every row and
// every microcycle's length against muir's QUUX; and the records aimed here
// in `mutations/list.txt`.

`default_nettype none

module quux_feature_page #(
    parameter logic [31:0] MACHINE_ID     = 32'h5155_0044,
    parameter int unsigned L1_BITS        = 6,
    parameter int unsigned PDL_BITS       = 14,
    parameter int unsigned IMEM_WORDS     = 16384,
    parameter int unsigned AMEM_WORDS     = 1024,
    parameter int unsigned DMEM_WORDS     = 2048,
    parameter logic [31:0] MULDIV         = 32'd3,
    parameter logic [31:0] TICK           = 32'd1,
    parameter int unsigned SCREEN_WIDTH   = 1280,
    parameter int unsigned SCREEN_HEIGHT  = 1024,
    parameter int unsigned SCREEN_WPL     = 40,
    parameter logic [21:0] SCREEN_BUFFER  = 22'o17000000
) (
    input  var logic        clk,
    input  var logic        rst,

    // The held decode's `device`, the cycle's address and its direction.
    input  var logic        sel,
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [21:0] phys,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic        dev_write,

    // `-XBUS.ACK` and the word, which this page drives only while answering
    // a READ: `cadr_machine.sv` joins both beside the disk controller's.
    output var logic        dev_ack,
    output var logic        drives,
    output var logic [31:0] rdata
);

  localparam logic [13:0] FEATURE_PAGE = 14'o36776;

  logic       mine;
  logic [7:0] which;

  always_ff @(posedge clk) begin
    if (rst) begin
      mine  <= 1'b0;
      which <= 8'd0;
    end else begin
      mine  <= sel && (phys[21:8] == FEATURE_PAGE);
      which <= phys[7:0];
    end
  end

  logic [31:0] word;
  always_comb begin
    unique case (which)
      8'o0:    word = MACHINE_ID;
      8'o1:    word = 32'(L1_BITS);
      8'o2:    word = 32'(32 << L1_BITS);
      8'o3:    word = 32'(1 << PDL_BITS);
      8'o4:    word = 32'(IMEM_WORDS);
      8'o5:    word = 32'(AMEM_WORDS);
      8'o6:    word = 32'(DMEM_WORDS);
      8'o7:    word = MULDIV;
      8'o10:   word = TICK;
      8'o11:   word = {16'(SCREEN_WIDTH), 16'(SCREEN_HEIGHT)};
      8'o12:   word = {16'd1, 16'(SCREEN_WPL)};
      8'o13:   word = {10'd0, SCREEN_BUFFER};
      default: word = 32'd0;
    endcase
  end

  // The bus interface ANDs the acknowledgment with `-XBUS.RQ` itself
  // (`cadr_disk_controller.sv` has why the slave must not), and the lines are
  // driven only for a read, a write leaving them to the master.
  assign dev_ack = mine;
  assign drives  = mine && !dev_write;
  assign rdata   = drives ? word : 32'd0;

endmodule

`default_nettype wire
