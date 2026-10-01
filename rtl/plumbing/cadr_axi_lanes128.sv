// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A 32-bit register face on a 128-bit port the processing system masters.
//
// **THE KRIA KR260's `M_AXI_HPM0_FPD` AND `M_AXI_HPM1_FPD` ARE 128 BITS
// WIDE**, which is the reset value of their width fields in `FPD_SLCR`'s
// `AFI_FS` (UG1087) and what the board's boot firmware leaves them at; a
// bitstream load does not change it (read on the board).  The faces behind
// them --- the disk pack's, the cables', the console, the debug window and
// the default slaves --- are 32-bit AXI slaves, as they are on every board.
// So this sits between the port and the splitter, and the faces keep their
// width, their registers and their checks.
//
// **A WORD ACCESS ON A 128-BIT PORT IS A NARROW TRANSFER**, by AXI's rules:
// a store of a word at an address puts the word in the lane the address's
// bits 3:2 select and opens that lane's byte strobes only, and a load takes
// the word from that lane.  Every face access the programs make is a word
// (`volatile uint32_t`), so:
//
//   - **A WRITE'S LANE IS THE ONE ITS STROBES OPEN.**  The word handed down
//     is the lane whose four strobes are not all clear, and its strobes go
//     with it.  Chosen by the strobes and not by the address, so the module
//     keeps no state and needs no write address: a write's data may arrive
//     before its address on AXI, and a lane taken from the strobes is right
//     whichever comes first.  A beat with no strobe open writes nothing in
//     any lane and goes down with no strobe open.
//   - **A READ'S WORD GOES BACK IN EVERY LANE**, so whichever lane the
//     address selects holds it.  No state here either.
//
// WHAT IT DOES NOT DO: split an access wider than a word.  A doubleword or
// quadword store goes down as one beat carrying the lowest strobed lane's
// word, and a wider load comes back with the one word in every lane.  Such
// an access still completes with the right number of beats, the right ID and
// RLAST where the length says --- every handshake, ID, length and response
// passes straight through --- so nothing hangs; it is just not a copy of
// more than one register.  The programs never make one.
//
// `tb/cadr_axi_lanes128_tb.cpp` holds both directions against stimulus that
// places the word in its lane itself.

`default_nettype none

module cadr_axi_lanes128 (
    // The port's side: the 128-bit payload.
    input  var logic [127:0] s_wdata,
    input  var logic [15:0]  s_wstrb,
    output var logic [127:0] s_rdata,
    // The face's side: one word.
    output var logic [31:0]  m_wdata,
    output var logic [3:0]   m_wstrb,
    input  var logic [31:0]  m_rdata
);

  always_comb begin
    if (s_wstrb[3:0] != 4'h0) begin
      m_wdata = s_wdata[31:0];
      m_wstrb = s_wstrb[3:0];
    end else if (s_wstrb[7:4] != 4'h0) begin
      m_wdata = s_wdata[63:32];
      m_wstrb = s_wstrb[7:4];
    end else if (s_wstrb[11:8] != 4'h0) begin
      m_wdata = s_wdata[95:64];
      m_wstrb = s_wstrb[11:8];
    end else begin
      // Lane 3, or no lane at all: with every strobe clear this is lane 3's
      // word with no strobe open, which writes nothing.
      m_wdata = s_wdata[127:96];
      m_wstrb = s_wstrb[15:12];
    end
  end

  assign s_rdata = {4{m_rdata}};

endmodule

`default_nettype wire
