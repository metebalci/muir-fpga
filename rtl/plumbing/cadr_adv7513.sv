// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The HDMI transmitter's own configuration, over its two-wire bus.
//
// On the Arty Z7-20 the fabric makes the link itself: `cadr_hdmi_tx.sv`
// encodes DVI and four serializers put it on the connector, and a bitstream
// that has been loaded is a board that is already transmitting.  The
// DE25-Nano has a transmitter part on the board instead, an Analog Devices
// ADV7513, and the fabric hands it a raster on a parallel bus.  **THAT PART
// DOES NOTHING AT ALL UNTIL ITS REGISTERS ARE WRITTEN**, so a board with a
// perfect raster on its video pins and an unconfigured transmitter shows a
// monitor nothing, and looks exactly like a board whose display is broken.
// This module is what writes them.
//
// It is plain SystemVerilog and names no vendor, so a check can compare it
// rather than confirm it.  What is specific to this board is the program
// below and the address it is written to, and both are cited.
//
// **NOTHING IN THE PATH IS SOFTWARE**, which is what keeps the DE25-Nano's
// display the same thing the Arty Z7-20's is.  `docs/display-output.md`
// opens by saying the two screens are scanned out of memory and driven onto
// the connector with no software in the path; the transmitter's two wires go
// to fabric pins on this board and not to the processor, so had this been
// left to Linux the picture would have needed a program, a face and a boot
// before it could appear.  It needs none.
//
// WHAT THE PROGRAM IS, AND WHERE IT COMES FROM
//
// The ADV7513 data sheet in the board's resource package is the short form,
// twelve pages: it gives the part's pins, its electrical limits and its bus
// timing, and it does not give the register map.  The register map is in
// Analog Devices' programming guide, which is not in the package and is not
// on this machine.  So the program below is NOT derived here, and saying so
// is the point.
//
// It is the board vendor's own initialization of the transmitter on this
// board, taken whole and in its own order from
// `Demonstration/FPGA/HDMI_TX/V_HDMI/I2C_HDMI_Config.v` of the DE25-Nano rev
// B resource package, sha256
// `b9b7c477173fee9b6cb5e3d6a6ba1122c7a0b539f205d807b1d61b22048fd391`.  That
// is the same footing on which `boards/de25-nano/de25_nano_pins.tcl` takes
// the package's pin assignments, and `boards/de25-nano/README.md` records
// the package and its digests.
//
// **NOTHING IS DROPPED AND NOTHING IS REORDERED, DELIBERATELY.**  Several
// entries are marked in that file only as "must be set", with no account of
// what they do, and a few are about audio, which this machine does not have.
// Dropping them would be a claim that they are dispensable, and the document
// that would settle it is not here; reordering them would be a claim about
// what the part does between two writes.  Both are guesses, and the rule in
// this project is to read rather than guess.  So the list is written out as
// it stands, with the purpose named for the entries whose purpose that file
// names, and the whole of it costs about ten milliseconds once ---
// 9.93 ms measured, which `build/adv7513.pass` prints.
//
// The three entries that carry this design rather than the part's defaults
// are worth naming here, because the raster is built to match them:
//
//   0x15 = 0x20   the input is 4:4:4 with SEPARATE SYNCS, which is what
//                 `cadr_display_out.sv` puts out: `de`, `hsync` and `vsync`
//                 as their own pins beside the data.
//   0x16 = 0x30   the input is 24 bits and the output format is 4:4:4, which
//                 is the 24-bit bus `red`, `green` and `blue` drive.
//   0xBA = 0x60   no clock delay, which is why the video is launched on the
//                 rising edge of the pixel clock and that same clock is
//                 forwarded to the part.  `boards/de25-nano/cadr_de25.sv`
//                 has the whole of that argument.
//
// THE ADDRESS
//
// `0x72`, the eight-bit write address, so a seven-bit address of `0x39`.
// The data sheet gives pin 22, `PD`, as "Power-Down Control and I2C Address
// Selection", so which of the part's two addresses answers is a fact about
// how this board straps that pin and not about the part.  `0x72` is the
// address the board vendor's own configuration writes to, on the board this
// is for.
//
// HOW IT IS DRIVEN, AND WHAT THE DATA SHEET BOUNDS
//
// Both lines are open drain: the fabric pulls a line low or releases it, and
// the board's resistors pull it up.  `scl_oe` and `sda_oe` mean "pull low".
// Nothing here ever drives a line high, which is what makes a stretched
// clock and an acknowledge possible at all.
//
// The data sheet's Table 1, under I2C INTERFACE, bounds five intervals and
// the clock:
//
//   SCL clock frequency                       400 kHz maximum
//   SDA setup time            tDSU            100 ns minimum
//   SDA hold time             tDHO            100 ns minimum
//   setup time for a start    tSTASU          0.6 us minimum
//   hold time for a start     tSTAH           0.6 us minimum
//   setup time for a stop     tSTOSU          0.6 us minimum
//
// The bus is run at a quarter of the frequency bound, and every interval is
// a quarter of a bit period, so each of the five has at least four times the
// margin the sheet asks for.  `tb/cadr_adv7513_tb.cpp` measures all six off
// the waveform and prints the worst of each, and the elaboration assertion
// below refuses a parameterization that would break any of them, so a build
// at another clock cannot quietly go out of bounds.
//
// The data sheet bounds no bus-free time between a stop and the next start,
// so one is not invented: the bus is left idle for a whole bit period, which
// is longer than every interval the sheet does bound.
//
// A STRETCHED CLOCK IS WAITED FOR.  After releasing SCL the engine waits for
// the line to read high before it counts the high phase, so a part holding
// the clock down is followed rather than talked over.  Both lines are
// synchronized in two flops first, since neither is of this clock.
//
// WHEN IT RUNS
//
// Out of reset, once.  And again whenever `restart` is raised, which
// `boards/de25-nano/cadr_de25.sv` raises when the display wakes from sleep.
// Sleep on this board stops the pixel clock at the pin, so the part's own
// input clock goes away and comes back; whether it relocks by itself is not
// established by any document here, and re-running the program costs about
// ten milliseconds at a wake and removes the question.  That is the honest
// reason and it is not a measurement: the sleep and the wake have been seen
// at the board (`docs/board.md`, 21 September), with the program re-run at
// the wake, and nobody has tried a wake without it.
//
// WHAT IS REPORTED RATHER THAN SWALLOWED
//
// A byte the part does not acknowledge stops the program, raises `failed`
// and leaves `configured` down, and the bus is released with a stop so it is
// not left hung.  An unanswered write that carried on to the next one would
// leave a half-configured transmitter reporting success, which is the shape
// of every fault this project has had to dig out afterwards.  `writes`
// counts the register writes the part has acknowledged, so how far it got is
// a number and not an inference.
//
// WHAT NOTHING HERE HOLDS
//
// **What speaks for the program is the board, and only for the whole of
// it.**  `build/adv7513.pass` holds what leaves the two pins --- the framing,
// the byte stream, the acknowledges, the intervals and the re-run --- against
// a decoder that recovers all of it from the two wires, and that is a check on
// this module and not evidence about the ADV7513.  The evidence about the part
// is `docs/board.md`'s sessions of 20 and 21 September: with this program
// written, a monitor on the board's connector showed the machine's screen,
// with a key typed at the board appearing on it.  That says the program as a
// whole makes the part transmit this mode; it says nothing about any one
// register, and no value here has been tried against another.
//
// Nothing reads the part's interrupt pin and nothing reads hot-plug detect,
// so the program is written whether or not a monitor is attached.  That is
// the Arty Z7-20's behavior too, and `docs/display-output.md` records it
// there under what is not built: the block sends its raster whether a
// monitor is attached or not.

`default_nettype none

module cadr_adv7513 #(
    // The fabric's clock, and the bus this engine runs it at.  The bus is a
    // quarter of the data sheet's 400 kHz bound.
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned SCL_HZ = 100_000,
    // The seven-bit address, which is the board's `0x72` shifted down.
    parameter logic [6:0]  ADDR   = 7'h39
) (
    input  var logic       clk,
    input  var logic       rst,

    // Run the program again from the top, clearing `configured` and
    // `failed`.  One tick is enough and a level is taken once.
    input  var logic       restart,

    // The program has been through with every byte acknowledged.
    output var logic       configured,
    // A byte was not acknowledged; the program stopped there.
    output var logic       failed,
    // How many register writes the part has acknowledged.
    output var logic [5:0] writes,

    // The two wires.  `*_oe` pulls a line low; nothing here drives high.
    input  var logic       scl_i,
    output var logic       scl_oe,
    input  var logic       sda_i,
    output var logic       sda_oe
);

  // ------------------------------------------------------------ the program
  //
  // The register and the value, in the board vendor's own order.  Each
  // comment is that file's own note on the entry, except where this design
  // depends on the entry, which the header names.
  localparam int unsigned N_REGS = 33;
  localparam logic [15:0] PROGRAM [N_REGS] = '{
      16'h9803,   // must be set to 0x03 for proper operation
      16'h0100,   // the audio clock regeneration N, 6144
      16'h0218,   //   "
      16'h0300,   //   "
      16'h0B2E,   // MCLK active
      16'h0CBC,   // the audio interface is I2S
      16'h1472,   // audio word length, and eight channels in the status
      16'h1520,   // INPUT 4:4:4 WITH SEPARATE SYNCS: this design's raster
      16'h1630,   // OUTPUT 4:4:4, 24-BIT INPUT: this design's video bus
      16'h1846,   // no color space conversion
      16'h4080,   // the general control packet enabled
      16'h4110,   // the power-down control: the transmitter powered up
      16'h49A8,   // dither, 12 bits to 10
      16'h5510,   // RGB in the AVI InfoFrame
      16'h5608,   // the active format aspect
      16'h96F6,   // the interrupt register
      16'h7307,   // eight channels in the InfoFrame
      16'h761F,   // the speaker allocation for eight channels
      16'h9803,   // must be set to 0x03 for proper operation
      16'h9902,   // must be set to its default
      16'h9AE0,   // must be set to 0b1110_0000
      16'h9C30,   // the PLL filter's R1
      16'h9D61,   // the clock divide
      16'hA2A4,   // must be set to 0xA4 for proper operation
      16'hA3A4,   // must be set to 0xA4 for proper operation
      16'hA504,   // must be set to its default
      16'hAB40,   // must be set to its default
      16'hAF16,   // HDMI mode rather than DVI
      16'hBA60,   // NO CLOCK DELAY: this design's clock forwarding
      16'hD1FF,   // must be set to its default
      16'hDE10,   // must be set to its default for proper operation
      16'hE460,   // must be set to its default
      16'hFA7D    // how many times to look for a good phase
  };

  // ------------------------------------------------------------- the timing
  //
  // A bit period is four quarters, and every interval the data sheet bounds
  // is one quarter or more.  `QUARTER` rounds up, so the bus is never faster
  // than asked for.
  localparam int unsigned QUARTER   = (CLK_HZ + (SCL_HZ * 4) - 1) / (SCL_HZ * 4);
  localparam int unsigned QUARTER_W = (QUARTER <= 1) ? 1 : $clog2(QUARTER);

  // **THE DATA SHEET'S SIX BOUNDS, AT THIS PARAMETERIZATION.**  A build at
  // another clock or another bus speed stops here rather than going quietly
  // out of specification, which is what a bound with nothing enforcing it
  // becomes.  The arithmetic is in picoseconds, in sixty-four bits so that a
  // clock of any speed is exact; one quarter is `QUARTER` clocks.
  // **NOT ONE LITERAL OF A MILLION MILLION**, which Verilator takes and
  // Quartus refuses: a bare decimal constant is thirty-two bits, and the
  // first build of this file on the real tool stopped at "decimal constant
  // 1000000000000 is too large, using -727379968 instead".  Two factors that
  // each fit, multiplied in sixty-four, is the same number and is portable.
  localparam longint unsigned PS_PER_S   = longint'(1_000_000) * longint'(1_000_000);
  localparam longint unsigned CLK_PS     = PS_PER_S / longint'(CLK_HZ);
  localparam longint unsigned QUARTER_PS = longint'(QUARTER) * CLK_PS;
  if (SCL_HZ > 400_000) begin : g_too_fast
    $error("the ADV7513's bus is 400 kHz at most, and SCL_HZ is %0d", SCL_HZ);
  end
  // tDSU and tDHO are 100 ns; tSTASU, tSTAH and tSTOSU are 0.6 us.  One
  // quarter has to clear the longest of them.
  if (QUARTER_PS < 600_000) begin : g_too_short
    $error("a quarter of a bit is %0d ps, and the data sheet asks 600000 ps of a start and a stop",
           QUARTER_PS);
  end
  if (QUARTER < 2) begin : g_no_quarter
    $error("a quarter of a bit is %0d clocks, which cannot be counted", QUARTER);
  end
  if (N_REGS > 63) begin : g_too_many
    $error("the program is %0d writes and `writes` counts to 63", N_REGS);
  end

  // ------------------------------------------------- the two lines, sampled
  //
  // Neither is of this clock, so both come in through two flops.  `scl_seen`
  // is what a stretched clock is followed by.
  logic [1:0] scl_s, sda_s;
  logic       scl_seen, sda_seen;
  always_ff @(posedge clk) begin
    scl_s <= {scl_s[0], scl_i};
    sda_s <= {sda_s[0], sda_i};
  end
  assign scl_seen = scl_s[1];
  assign sda_seen = sda_s[1];

  // ------------------------------------------------------------ the engine
  //
  // One bit is four quarters.  The line levels are decided by the state and
  // the quarter, so a start is a fall of SDA while SCL is high, a stop a
  // rise of it while SCL is high, and a data bit changes only while SCL is
  // low --- which is the whole of the protocol's shape.
  typedef enum logic [2:0] {
      S_START,    // SDA falls while SCL is high
      S_BYTE,     // eight bits, most significant first
      S_ACK,      // SDA released, and the part answers
      S_STOP,     // SDA rises while SCL is high
      S_GAP,      // the bus left free for a bit period
      S_DONE      // the program is through, or it stopped on a failure
  } state_t;

  state_t                 state;
  logic [QUARTER_W-1:0]   qcnt;      // clocks within a quarter
  logic [1:0]             quarter;   // which quarter of the bit
  logic [2:0]             bitno;     // which bit of the byte, 7 down to 0
  logic [1:0]             byteno;    // 0 the address, 1 the register, 2 the value
  logic [5:0]             entry;     // which register write
  logic [7:0]             shifter;   // the byte going out
  logic                   sda_bit;   // the data line, one quarter behind it
  logic                   ack_bad;   // the part did not acknowledge this byte

  // The quarter advances once its clocks are counted, EXCEPT where SCL has
  // been released and the line has not risen: there the engine waits, which
  // is how a stretched clock is followed.
  logic scl_released, may_advance, tick;
  assign scl_released = !scl_oe;
  assign may_advance  = !scl_released || scl_seen;
  assign tick         = (qcnt == QUARTER_W'(QUARTER - 1)) && may_advance;

  // **THE LINES, BY STATE AND QUARTER, AND EVERY INTERVAL THE DATA SHEET
  // BOUNDS IS A WHOLE QUARTER.**  The rhythm of a bit is the same everywhere:
  // SCL low in quarters 0 and 1 and high in 2 and 3, and SDA moves at the
  // quarter 0 to 1 boundary, which is a quarter after SCL fell and a quarter
  // before it rises.  So a bit is a hold of one quarter and a setup of one
  // quarter, and the two clocks either side are half the bit each.
  //
  //   quarter    0      1      2      3
  //   SCL       low    low    high   high
  //   SDA      hold    new    new    new
  //
  // A start is the same rhythm with SCL held high across the move, so SDA
  // falls at the 0 to 1 boundary with a quarter of SCL high behind it and
  // two quarters in front; a stop is its mirror, with SDA low from the 0 to
  // 1 boundary and rising at the 2 to 3 boundary, a quarter after SCL rose.
  // **NOTHING MOVES SDA AT AN EDGE OF SCL ANYWHERE**, which is the one thing
  // a slave would read as a start or a stop in the middle of a byte.
  always_comb begin
    scl_oe = 1'b0;    // released unless something below pulls it low
    sda_oe = 1'b0;    // released unless something below pulls it low
    unique case (state)
      // The bus free: both released.
      S_GAP, S_DONE: begin
        scl_oe = 1'b0;
        sda_oe = 1'b0;
      end
      // SCL high but for the last quarter, where it falls into the first
      // byte; SDA falls at the 0 to 1 boundary, which is the start.
      S_START: begin
        scl_oe = (quarter == 2'd3);
        sda_oe = (quarter != 2'd0);
      end
      // A data bit and the acknowledge bit keep one rhythm; what parts them
      // is only which of the two ends of the bus drives SDA, and `sda_bit`
      // is released for the whole of the acknowledge.
      S_BYTE, S_ACK: begin
        scl_oe = (quarter == 2'd0) || (quarter == 2'd1);
        sda_oe = !sda_bit;
      end
      // SDA low from the 0 to 1 boundary, while SCL is still low; SCL rises
      // at the 1 to 2 boundary and SDA at the 2 to 3, which is the stop.
      S_STOP: begin
        scl_oe = (quarter == 2'd0) || (quarter == 2'd1);
        sda_oe = (quarter == 2'd1) || (quarter == 2'd2);
      end
      default: begin
        scl_oe = 1'b0;
        sda_oe = 1'b0;
      end
    endcase
  end

  // The byte each step of a write sends: the address with its write bit, then
  // the register, then the value.
  logic [7:0] next_byte;
  always_comb begin
    unique case (byteno)
      2'd0:    next_byte = {ADDR, 1'b0};
      2'd1:    next_byte = PROGRAM[entry][15:8];
      default: next_byte = PROGRAM[entry][7:0];
    endcase
  end

  // `restart` is taken on its rise, so a caller that holds it up asks for one
  // run and not for a held reset.
  logic restart_q, restart_edge;
  always_ff @(posedge clk) restart_q <= rst ? 1'b0 : restart;
  assign restart_edge = restart && !restart_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      // **OUT OF RESET THE BUS IS LEFT FREE FIRST**, which is what `S_GAP`
      // is, so the first start has a bus that has been idle for a bit period
      // behind it rather than one this engine has just taken hold of.
      state      <= S_GAP;
      qcnt       <= '0;
      quarter    <= 2'd0;
      bitno      <= 3'd7;
      byteno     <= 2'd0;
      entry      <= 6'd0;
      shifter    <= {ADDR, 1'b0};
      sda_bit    <= 1'b1;
      ack_bad    <= 1'b0;
      configured <= 1'b0;
      failed     <= 1'b0;
      writes     <= 6'd0;
    end else if (restart_edge) begin
      // From the top, whatever it was doing.  The bus is left released for a
      // gap first, so a restart in the middle of a byte cannot look like a
      // start to a part that was listening.
      state      <= S_GAP;
      qcnt       <= '0;
      quarter    <= 2'd0;
      bitno      <= 3'd7;
      byteno     <= 2'd0;
      entry      <= 6'd0;
      shifter    <= {ADDR, 1'b0};
      sda_bit    <= 1'b1;
      ack_bad    <= 1'b0;
      configured <= 1'b0;
      failed     <= 1'b0;
      writes     <= 6'd0;
    end else begin
      if (!tick) begin
        if (may_advance) qcnt <= qcnt + QUARTER_W'(1);
      end else begin
        qcnt <= '0;
        // The part's answer is read in the middle of the acknowledge bit,
        // where SCL is high: at the end of quarter 2, which is the last
        // quarter SCL is released for.  A low line is the acknowledge.
        // **THE DATA LINE MOVES HERE AND NOWHERE ELSE**, at the boundary
        // between the bit's first and second quarters, which is a quarter
        // after SCL fell.  The acknowledge bit releases it for the part to
        // answer on; every other bit puts up the shifter's top bit.
        if (quarter == 2'd0 && (state == S_BYTE || state == S_ACK))
          sda_bit <= (state == S_ACK) ? 1'b1 : shifter[7];
        // The part's answer, read in the third quarter, which is inside
        // SCL's high and a whole quarter after it rose.  A low line is the
        // acknowledge.
        if (state == S_ACK && quarter == 2'd2) ack_bad <= sda_seen;
        quarter <= quarter + 2'd1;
        if (quarter == 2'd3) begin
          unique case (state)
            S_START: begin
              state   <= S_BYTE;
              bitno   <= 3'd7;
              shifter <= next_byte;
              // The start left SDA low, and the first quarter of the first
              // bit holds it there while SCL is low.
              sda_bit <= 1'b0;
            end
            S_BYTE: begin
              shifter <= {shifter[6:0], 1'b0};
              if (bitno == 3'd0) begin
                state <= S_ACK;
              end else begin
                bitno <= bitno - 3'd1;
              end
            end
            S_ACK: begin
              if (ack_bad) begin
                // Report it and stop, with a stop so the bus is not left
                // hung.  `failed` is raised when the stop is through.
                state <= S_STOP;
              end else if (byteno == 2'd2) begin
                // The third byte of this write is acknowledged.
                writes <= writes + 6'd1;
                state  <= S_STOP;
              end else begin
                byteno  <= byteno + 2'd1;
                bitno   <= 3'd7;
                state   <= S_BYTE;
                shifter <= (byteno == 2'd0) ? PROGRAM[entry][15:8]
                                            : PROGRAM[entry][7:0];
              end
            end
            S_STOP: begin
              if (ack_bad) begin
                failed <= 1'b1;
                state  <= S_DONE;
              end else begin
                state <= S_GAP;
              end
            end
            S_GAP: begin
              if (failed) begin
                state <= S_DONE;
              end else if (entry == 6'(N_REGS - 1) && writes == 6'(N_REGS)) begin
                configured <= 1'b1;
                state      <= S_DONE;
              end else begin
                // The gap after a restart comes here with nothing written
                // yet, and starts the program; the gap after a write moves
                // on to the next one.
                if (writes != 6'd0) entry <= entry + 6'd1;
                byteno  <= 2'd0;
                bitno   <= 3'd7;
                shifter <= {ADDR, 1'b0};
                state   <= S_START;
              end
            end
            default: begin
              state <= S_DONE;
            end
          endcase
        end
      end
    end
  end

endmodule

`default_nettype wire
