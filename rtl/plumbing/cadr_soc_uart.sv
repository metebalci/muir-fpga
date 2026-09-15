// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system's own console line: a transmitter and a receiver
// on the board's USB-UART bridge, and four registers the firmware drives them
// through.
//
// **THIS IS NOT THE CADR's SERIAL LINE AND MUST NOT BE CONFUSED WITH IT.**
// `rtl/plumbing/cadr_serial_line.sv` is the far end of the 2651 on the I/O
// board: its framing, its baud rate and the instant it says a frame has ended
// are all held to muir tick for tick, and CLAUDE.md records what happened the
// one time that file divided against the board's real clock instead of MIT's
// 5 ns grid.  This is the other kind of line entirely.  It carries the
// FIRMWARE's own words to whoever is at the board, it answers to nothing in
// muir, and it has to agree with the wall clock because the thing at the other
// end of it is a terminal program on somebody's laptop.  So `CLK_HZ` here is
// the board's real clock and that is correct, where one file along it was the
// bug.
//
// **THE PINS ARE DIGILENT'S AND THEIR NAMES ARE FROM THE HOST's POINT OF
// VIEW**, which is worth saying once because it reads backwards.
// `Arty-A7-100-Master.xdc` calls them `uart_rxd_out` (D10) and `uart_txd_in`
// (A9): `uart_rxd_out` is what the FPGA drives and the USB bridge receives,
// and `uart_txd_in` is what the bridge drives and the FPGA receives.  So
// `tx` below leaves on `uart_rxd_out` and `rx` arrives on `uart_txd_in`.
//
// THE FRAME is 8N1 --- one start bit low, eight data bits least significant
// first, one stop bit high --- and the line idles high.  There is no parity
// and no flow control, which is what every terminal program defaults to.
//
// THE RATE.  `DIVISOR` is how many ticks one bit lasts, `CLK_HZ / BAUD`.  At
// 100 MHz and 115,200 baud that is 868.06, and 868 is 0.007 % fast: a
// character is ten bit times, so the receiver's sampling point at the middle
// of the stop bit is off by less than a tenth of a bit.  The number is
// computed here rather than written down, so that a board with a different
// clock gets a different divisor and not a different rate.
//
// THE REGISTERS, four words at the base the SoC decodes:
//
//   0x00  IDENT   reads "UART", so that a firmware's first load can tell this
//                 face from a bus answering zeros or ones --- the same rule
//                 the machine's own faces keep, and for the same reason: a
//                 value that means nothing must not be a value the instrument
//                 can mean
//   0x04  STAT    bit 0  tx_ready   the transmitter will take a byte now
//                 bit 1  rx_valid   a byte is waiting to be read
//                 bit 2  rx_over    a byte arrived on top of an unread one;
//                                   sticky, and cleared by writing STAT
//   0x08  TX      a write sends bits 7:0.  **A write while `tx_ready` is
//                 clear is DROPPED**, and that is deliberate: a face that
//                 stalled the bus instead would put an unbounded wait inside
//                 a load, which is the shape of fault this project has
//                 measured on silicon and will not build again.  The firmware
//                 polls `tx_ready`, which costs it nothing it has to be told
//                 about
//   0x0C  RX      bit 8 is `rx_valid` and bits 7:0 the byte.  **A read with
//                 bit 8 set POPS the byte**; a read with it clear takes
//                 nothing.  Bit 8 and not a separate register, so that the
//                 test and the datum come out of one load and cannot name two
//                 instants
//
// An address in the page that is none of the four reads `UNMAPPED`, the
// complement of IDENT, and a write to it is dropped.  Nothing here can refuse
// to answer.

`default_nettype none

module cadr_soc_uart #(
    // The board's real clock, in hertz.  See the header: this face is the one
    // place in the design that is about the wall clock on purpose.
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned BAUD   = 115_200,
    // "UART".
    parameter logic [31:0] IDENT    = 32'h5541_5254,
    parameter logic [31:0] UNMAPPED = ~IDENT
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- the register seam, as `cadr_soc.sv` drives it.  One tick: `sel` is
    // --- up with the address and the read answer is registered, so a load
    // --- costs the core one cycle and never more.
    input  var logic        sel,
    input  var logic        we,
    input  var logic [3:0]  be,
    input  var logic [11:0] addr,     // byte address inside the page
    input  var logic [31:0] wdata,
    output var logic [31:0] rdata,

    // --- the pins.  `tx` leaves on `uart_rxd_out` and `rx` arrives on
    // --- `uart_txd_in`; the header says why those names read backwards.
    output var logic        tx,
    input  var logic        rx
);

  // How many ticks one bit lasts.  `CLK_HZ / BAUD` truncates, which is the
  // right direction: a divisor one tick short makes the line slightly fast,
  // and a receiver samples in the middle of a bit.
  localparam int unsigned DIVISOR = CLK_HZ / BAUD;
  // Half of it, which is where the receiver moves its sampling point to after
  // it has seen a start bit.
  localparam int unsigned HALF_DIVISOR = DIVISOR / 2;
  localparam int unsigned CNT_W = $clog2(DIVISOR + 1);

  // ------------------------------------------------------------ the transmitter
  //
  // A shift register with the start bit and the stop bit already in it, so
  // that the state machine is a counter and nothing else: load
  // {stop, byte, start} = 10 bits and shift one out every `DIVISOR` ticks,
  // least significant first, which puts the start bit out first and the stop
  // bit last.  The line idles high because the register is all ones when it
  // is empty.
  logic [9:0]        tx_sr;
  logic [3:0]        tx_left;      // bits still to go, 0 when idle
  logic [CNT_W-1:0]  tx_t;
  logic              tx_ready;

  assign tx_ready = (tx_left == 4'd0);
  assign tx       = tx_sr[0];

  logic tx_take;

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_sr   <= 10'h3FF;
      tx_left <= 4'd0;
      tx_t    <= '0;
    end else if (tx_take) begin
      // {stop, data<7:0>, start}
      tx_sr   <= {1'b1, wdata[7:0], 1'b0};
      tx_left <= 4'd10;
      tx_t    <= CNT_W'(DIVISOR - 1);
    end else if (tx_left != 4'd0) begin
      if (tx_t == '0) begin
        tx_sr   <= {1'b1, tx_sr[9:1]};
        tx_left <= tx_left - 4'd1;
        tx_t    <= CNT_W'(DIVISOR - 1);
      end else begin
        tx_t <= tx_t - CNT_W'(1);
      end
    end
  end

  // --------------------------------------------------------- the receiver
  //
  // Two synchronizer stages, because the pin is asynchronous to this clock,
  // and then: idle until the line goes low, wait HALF a bit so that the
  // sampling point is in the middle of the start bit, check it is still low
  // --- a glitch shorter than half a bit is not a start bit and is ignored
  // --- and then take a bit every `DIVISOR` ticks for eight bits and a stop.
  logic [1:0]       rx_sync;
  logic             rx_busy;
  logic [3:0]       rx_left;
  logic [CNT_W-1:0] rx_t;
  logic [7:0]       rx_sr;
  logic [7:0]       rx_byte;
  logic             rx_valid;
  logic             rx_over;

  logic rx_pop;       // a read of RX with bit 8 set
  logic stat_write;   // a write of STAT, which clears the overrun bit

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_sync  <= 2'b11;
      rx_busy  <= 1'b0;
      rx_left  <= 4'd0;
      rx_t     <= '0;
      rx_sr    <= 8'd0;
      rx_byte  <= 8'd0;
      rx_valid <= 1'b0;
      rx_over  <= 1'b0;
    end else begin
      rx_sync <= {rx_sync[0], rx};

      if (rx_pop)     rx_valid <= 1'b0;
      if (stat_write) rx_over  <= 1'b0;

      if (!rx_busy) begin
        if (!rx_sync[1]) begin
          // A falling edge: aim at the middle of the start bit.
          rx_busy <= 1'b1;
          rx_left <= 4'd9;              // the start bit and eight data bits
          rx_t    <= CNT_W'(HALF_DIVISOR - 1);
        end
      end else if (rx_t == '0) begin
        rx_t <= CNT_W'(DIVISOR - 1);
        if (rx_left == 4'd9) begin
          // The middle of the start bit.  Still low, or it was a glitch.
          if (rx_sync[1]) rx_busy <= 1'b0;
          else            rx_left <= 4'd8;
        end else if (rx_left != 4'd0) begin
          rx_sr   <= {rx_sync[1], rx_sr[7:1]};
          rx_left <= rx_left - 4'd1;
        end else begin
          // The middle of the stop bit.  A framing error --- the line low
          // where the stop bit should be --- drops the byte rather than
          // delivering a wrong one.
          rx_busy <= 1'b0;
          if (rx_sync[1]) begin
            rx_byte <= rx_sr;
            // **THE OVERRUN IS COUNTED AND THE OLD BYTE IS KEPT.**  A face
            // that overwrote would lose the byte the firmware was about to
            // read and gain one it never asked for, and neither would be
            // visible.  Keeping the old one and saying so is the honest
            // direction.
            if (rx_valid && !rx_pop) rx_over <= 1'b1;
            else                     rx_valid <= 1'b1;
          end
        end
      end else begin
        rx_t <= rx_t - CNT_W'(1);
      end
    end
  end

  // --------------------------------------------------------- the registers
  //
  // **THE MATCH IS HELD, NEVER COMPUTED**, which is the rule every slave in
  // this repository is held to: `sel` and `addr` arrive together, the answer
  // is registered, and nothing downstream of a load waits on an address
  // comparison rippling.
  logic [1:0] word;
  assign word = addr[3:2];

  // The write effects, one tick, gated on `sel && we` and on the word.
  assign tx_take    = sel && we && (word == 2'd2) && be[0] && tx_ready;
  assign stat_write = sel && we && (word == 2'd1);
  assign rx_pop     = sel && !we && (word == 2'd3) && rx_valid;

  always_ff @(posedge clk) begin
    if (rst) begin
      rdata <= UNMAPPED;
    end else if (sel && !we) begin
      case (word)
        2'd0:    rdata <= IDENT;
        2'd1:    rdata <= {29'd0, rx_over, rx_valid, tx_ready};
        2'd3:    rdata <= {23'd0, rx_valid, rx_byte};
        // Word 2 is the transmitter and is write-only: there is nothing to
        // read there and `UNMAPPED` says so, rather than a zero that a dead
        // bus also reads.
        default: rdata <= UNMAPPED;
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, addr[11:4], addr[1:0], be[3:1], wdata[31:8]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
