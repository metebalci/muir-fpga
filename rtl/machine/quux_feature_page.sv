// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's feature page: one page of Xbus I/O space in which the machine lists
// its sizes, physical `17377000`-`17377377` (page 36776), and which since
// revision 6 carries its registers too (contract Q2: "the QUUX register page
// is the feature page").  Words 0-77 are the feature page proper and read
// only; the registers are below.
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
//     14   the interval timer and the microsecond clock, 1
//     15-77  0
//
// And the registers (`Machine::bus_read` and `bus_write`):
//
//     100  interrupt status, read only: <0> the tick, <1> the interval timer,
//          <2> the disk's done, <3> the keyboard, <4> the mouse, <5> the
//          network, each under its own enable
//     101  the bus errors, as `766044` gives them: <0> Xbus NXM, <3> Unibus
//          NXM, <5> Unibus map error; a write clears them
//     102  mode: <0> error stop, which the mode register's <2> is too
//     120-123  the keyboard and the mouse, `quux_input.sv` (contract Q3)
//     140-147  the Chaosnet interface's registers, word 140 + k being Unibus
//          `764140` + 2k, sixteen bits in the bottom of the word (contract
//          Q4); what the Unibus does not answer reads 0 and takes no write
//     the rest reserved: read 0, writes ignored
//
// **A REGISTER IS READ AND WRITTEN AT THE INSTANT THE PAGE ANSWERS**, the
// first tick of the cycle's `-XBUS.RQ` with the page matched, which is muir's
// `answered_at`: a read's word is taken there and held for the strobe, and a
// read that moves something --- the keyboard's FIFO, the mouse's changed bit,
// the Chaosnet's receive pointer --- moves it there, once.  The interrupt
// status is the flags as they stand at that tick.  The page's own three
// requests, the keyboard's, the mouse's and the network's, also reach the
// processor's interrupt as every word 100 bit does (`irq`; muir's
// `interrupt_at`, `3ceb4f7` for the network's); the tick's and the interval
// timer's reach it from `quux_clocks.sv`, and the disk's on the Xbus line.
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
// What holds it: `build/quux_map.quux.k4.pass`, whose program reads words 0
// to 14, 100, 200 and 377 through the map; `build/quux_page.quux.k4.pass`,
// whose program reads and writes every register word with key words pressed
// on the cable, the flags risen, a bus error made and the Chaosnet interface
// written and read both through the page and on the Unibus; each comparing
// `MD`, `SINTR` and every microcycle's length on every row against muir's
// QUUX; and the records aimed here in `mutations/list.txt`.

`default_nettype none

module quux_feature_page #(
    parameter logic [31:0] MACHINE_ID     = 32'h5155_0064,
    parameter int unsigned L1_BITS        = 6,
    parameter int unsigned PDL_BITS       = 14,
    parameter int unsigned IMEM_WORDS     = 16384,
    parameter int unsigned AMEM_WORDS     = 1024,
    parameter int unsigned DMEM_WORDS     = 2048,
    parameter logic [31:0] MULDIV         = 32'd3,
    parameter logic [31:0] TICK           = 32'd1,
    parameter logic [31:0] CLOCKS         = 32'd1,
    parameter int unsigned SCREEN_WIDTH   = 1280,
    parameter int unsigned SCREEN_HEIGHT  = 1024,
    parameter int unsigned SCREEN_WPL     = 40,
    parameter logic [21:0] SCREEN_BUFFER  = 22'o17000000
) (
    input  var logic        clk,
    input  var logic        rst,

    // The held decode's `device`, the cycle's address, its direction,
    // `-XBUS.RQ` and the word written.
    input  var logic        sel,
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [21:0] phys,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic        dev_write,
    input  var logic        dev_rq,
    input  var logic [31:0] wdata,

    // `-XBUS.ACK` and the word, which this page drives only while answering
    // a READ: `cadr_machine.sv` joins both beside the disk controller's.
    output var logic        dev_ack,
    output var logic        drives,
    output var logic [31:0] rdata,

    // --- word 100's sources that are not this page's own
    input  var logic [1:0]  clock_pending,   // <0> the tick, <1> the interval timer
    input  var logic        disk_irq,        // <2> the disk's done
    input  var logic        chaos_ireq,      // <5> the network
    // --- word 101: the bus errors, and their clear
    input  var logic [2:0]  err,             // {map, Unibus NXM, Xbus NXM}
    output var logic        err_clear,
    // --- word 102: error stop, and its write
    input  var logic        errstop,
    output var logic        errstop_we,
    output var logic        errstop_d,
    // --- words 140-147: the Chaosnet interface (`cadr_io_board.sv`'s `qp_`)
    output var logic        ch_land,
    output var logic        ch_wr,
    output var logic [2:0]  ch_which,
    output var logic [15:0] ch_wdata,
    input  var logic [15:0] ch_rdata,
    // --- words 120-123: the keyboard's cable and the mouse's counts
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    input  var logic [11:0] mouse_x,
    input  var logic [11:0] mouse_y,
    input  var logic [2:0]  mouse_buttons,

    // The page's own requests into the processor's interrupt: the keyboard,
    // the mouse and the network.
    output var logic        irq,
    // The keyboard's boot word, and the host's handshake (`quux_input.sv`).
    output var logic        n_boot_kbd,
    output var logic        kbd_busy
);

  localparam logic [13:0] FEATURE_PAGE = 14'o36776;

  logic       mine, taken;
  logic [7:0] which;

  // **THE INSTANT THE PAGE ANSWERS**: the first tick of `-XBUS.RQ` with the
  // page matched, once a cycle.
  logic take;
  assign take = mine && dev_rq && !taken;

  // Words 140-147 as `ioboard::answers` takes them: a read of all but 146,
  // and a write of 140, 141, 144 and 145.  **Unchecked, and said so**: a
  // write the Unibus refuses would reach registers that take no write
  // anyway, and a read of 146 would be the receive buffer, which is empty
  // with no cable --- and no trace here has one --- so the refusal is built
  // on muir's word and not measured.
  logic in_chaos, chaos_answers;
  assign in_chaos = which[7:3] == 5'o14;
  assign chaos_answers = in_chaos && (dev_write ? (which[1] == 1'b0)
                                                : (which[2:0] != 3'd6));

  logic [31:0] in_rdata;
  logic [1:0]  in_irq;
  logic        in_mine;

  quux_input input_regs (
      .clk          (clk),
      .rst          (rst),
      .kbd_strobe   (kbd_strobe),
      .kbd_code     (kbd_code),
      .mouse_x      (mouse_x),
      .mouse_y      (mouse_y),
      .mouse_buttons(mouse_buttons),
      .rd           (take && !dev_write),
      .wr           (take && dev_write),
      .which        (which),
      .wdata        (wdata),
      .rdata        (in_rdata),
      .mine         (in_mine),
      .irq          (in_irq),
      .n_boot       (n_boot_kbd),
      .busy         (kbd_busy)
  );

  logic [31:0] word;
  always_comb begin
    word = 32'd0;
    if (in_mine) begin
      word = in_rdata;
    end else if (in_chaos) begin
      word = chaos_answers ? {16'd0, ch_rdata} : 32'd0;
    end else begin
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
        8'o14:   word = CLOCKS;
        8'o100:  word = {26'd0, chaos_ireq, in_irq, disk_irq, clock_pending};
        8'o101:  word = {26'd0, err[2], 1'b0, err[1], 2'b00, err[0]};
        8'o102:  word = {31'd0, errstop};
        default: word = 32'd0;
      endcase
    end
  end

  logic [31:0] held;

  always_ff @(posedge clk) begin
    if (rst) begin
      mine  <= 1'b0;
      which <= 8'd0;
      taken <= 1'b0;
      held  <= 32'd0;
    end else begin
      mine  <= sel && (phys[21:8] == FEATURE_PAGE);
      which <= phys[7:0];
      if (take) begin
        taken <= 1'b1;
        held  <= word;
      end else if (!(mine && dev_rq)) begin
        taken <= 1'b0;
      end
    end
  end

  assign err_clear  = take && dev_write && which == 8'o101;
  assign errstop_we = take && dev_write && which == 8'o102;
  assign errstop_d  = wdata[0];
  assign ch_land    = take && chaos_answers;
  assign ch_wr      = dev_write;
  assign ch_which   = which[2:0];
  assign ch_wdata   = wdata[15:0];

  assign irq = (|in_irq) || chaos_ireq;

  // The bus interface ANDs the acknowledgment with `-XBUS.RQ` itself
  // (`cadr_disk_controller.sv` has why the slave must not), and the lines are
  // driven only for a read, a write leaving them to the master.  The word is
  // the one taken at the answer, and before it the one being made, which no
  // strobe can take: `-LOADMD` follows the acknowledgment by the deskew.
  assign dev_ack = mine;
  assign drives  = mine && !dev_write;
  assign rdata   = drives ? (taken ? held : word) : 32'd0;

endmodule

`default_nettype wire
