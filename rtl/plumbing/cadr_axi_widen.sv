// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The widening: the machine's 32-bit word in `S_AXI_HP0`'s 64-bit beat.
//
// `cadr_axi_master` speaks AXI4 at 32 bits, which is the width of a CADR word
// and of everything upstream of it.  The Zynq-7000 AFI ports are 64 bits and
// are used here at their native width, which is what keeps `ps7_init`
// something we use rather than something we own: at 64 bits any correct Arty
// Z7-20 `ps7_init` works unmodified.  **A narrow transfer --- `AWSIZE` of four
// bytes on a 64-bit port --- is legal AXI and is not used here.**  Whether the
// AFI port and the memory controller handle one as well was sidestepped rather
// than answered, and a full-width beat with byte strobes needs no answer to it.
//
// So this is what sits between the two, and it is four assignments and a
// truncation:
//
//   the address    the beat's, not the word's: the low three bits go.
//   the data       the word in both halves of the beat, offered twice.
//   the strobes    the word's four, in the half `A[2]` selects and nowhere
//                  else --- which is what makes the other half of the beat
//                  untouched by a write that is not addressed to it.
//   the read       the half `A[2]` selects, taken from the beat that came back.
//   len and size   AXI4's eight bits of length narrowed to AXI3's four, and
//                  the size replaced by the beat's own.
//
// `A[2]` IS THE ADAPTER'S REGISTERED ADDRESS AND NOT THE BRIDGE'S.  Each
// direction takes its own: the write strobes are placed by `s_awaddr` and the
// read lane is selected by `s_araddr`, because those are the addresses the
// transactions are actually at.  The adapter holds each until the next
// transaction of that kind replaces it, so on a write `s_araddr` is the
// previous read's address and vice versa --- and a lane selected from the
// wrong one of the two is a bug that only shows when they disagree.  The
// testbench drives them independently for that reason.
//
// WHY THIS IS A MODULE AND NOT SIX LINES IN THE TOP LEVEL, which is where it
// was written.  `boards/arty-z7-20/cadr_arty.sv` cannot be simulated --- Verilator has
// neither `MMCME2_BASE` nor `PS7` --- so anything living there is held by lint
// and by the fitter and by nothing else.  The conversion is small and it is
// exactly the kind of thing that is wrong quietly: a lane select taken from
// the wrong channel, a strobe pattern that writes both halves, the
// half-selecting bit left in the beat address.  None of those is a build
// failure and all of them are a machine that reads back the wrong word.  A
// module has a check; a generate block in the top level does not.
//
// AXI SIZE IS DELIBERATELY NOT DERIVED FROM `s_awsize`.  The adapter says four
// bytes, which is the word; the beat is eight, and the strobes above are what
// make those the same thing.  Reading the adapter's size and widening it would
// be inventing a behaviour for a value that is a constant on one side of a
// wire, so the constant is written here and the adapter's is left unread.

`default_nettype none

module cadr_axi_widen (
    // The adapter's side: AXI4, 32 bits, one beat.  Payload only --- every
    // handshake passes the top level straight through, one width to the
    // other, and there is nothing here to do to it.
    input  var logic [31:0] s_awaddr,
    input  var logic [7:0]  s_awlen,
    input  var logic [2:0]  s_awsize,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic [31:0] s_araddr,
    input  var logic [7:0]  s_arlen,
    input  var logic [2:0]  s_arsize,
    output var logic [31:0] s_rdata,

    // The port's side: AXI3, 64 bits, one beat.
    output var logic [31:0] m_awaddr,
    output var logic [3:0]  m_awlen,
    output var logic [1:0]  m_awsize,
    output var logic [63:0] m_wdata,
    output var logic [7:0]  m_wstrb,
    output var logic [31:0] m_araddr,
    output var logic [3:0]  m_arlen,
    output var logic [1:0]  m_arsize,
    input  var logic [63:0] m_rdata
);

  // 2^3 = 8 bytes: the port's whole width.
  localparam logic [1:0] SIZE_BEAT = 2'b11;

  // The beat's address. The low three bits are not lost --- bit 2 is what the
  // strobes and the lane select below are made of, and bits 1 and 0 are zero
  // on every address this ever sees: `cadr_xbus_ddr` shifts a word address
  // twice into a base that is 256 MB aligned.
  assign m_awaddr = {s_awaddr[31:3], 3'b000};
  assign m_araddr = {s_araddr[31:3], 3'b000};

  // AXI4 carries eight bits of burst length and AXI3 four. Both are zero here
  // --- one beat is one beat in either --- so the truncation is a formality,
  // and it is written where a check can see it rather than in a port
  // connection where nothing can.
  assign m_awlen = s_awlen[3:0];
  assign m_arlen = s_arlen[3:0];

  assign m_awsize = SIZE_BEAT;
  assign m_arsize = SIZE_BEAT;

  // The word twice, and the strobes deciding which copy lands.
  assign m_wdata = {s_wdata, s_wdata};
  assign m_wstrb = s_awaddr[2] ? {s_wstrb, 4'b0000} : {4'b0000, s_wstrb};

  assign s_rdata = s_araddr[2] ? m_rdata[63:32] : m_rdata[31:0];

  // Deliberately unread, and each for the reason above: the adapter's size,
  // which is the word's and not the beat's; AXI4's top nibble of length, which
  // AXI3 does not carry; and the two low address bits, which are zero on every
  // address the bridge makes.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{s_awsize, s_arsize, s_awlen[7:4], s_arlen[7:4],
                    s_awaddr[1:0], s_araddr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
