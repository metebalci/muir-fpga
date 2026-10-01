// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The 32-bit word in a 128-bit beat: `cadr_axi_widen.sv` for a port four
// words wide.
//
// **THE KRIA KR260's MEMORY PORT IS 128 BITS, AND THE FABRIC MEETS IT AT
// THAT WIDTH.**  The Zynq UltraScale+'s `S_AXI_HP0_FPD` takes 32, 64 or 128
// bits on its fabric side, chosen by a register of the processing system
// (`AFIFM2`'s `RDCTRL` and `WRCTRL`, UG1087), and the board's own boot
// firmware leaves it at 128, its reset value; loading a bitstream does not
// change it (read on the board before and after `fpga loadb`).  So the
// fabric is built for the width the part comes up with, and no program has
// to write a register before the machine's memory works: a bitstream loaded
// by any path finds the port as it expects it.
//
// ONE WORD A TRANSACTION, IN A FULL-WIDTH BEAT, exactly as the 64-bit
// widening does it: the beat is the port's whole width (`AxSIZE` 128 bits),
// its address is the word's address with the low four bits cleared, the word
// is copied into all four lanes and the byte strobes open the one lane the
// word's address selects.  The read takes the same lane back out.  A narrow
// transfer would do as well by AXI's rules; a full-width one is what the
// 64-bit board does and what the port upsizes nothing for.
//
// **THE LANE COMES FROM EACH CHANNEL'S OWN ADDRESS**: the write strobes from
// `s_awaddr` and the read lane from `s_araddr`, which `cadr_axi_master.sv`
// holds from the address it issues until the next transaction of that kind,
// so the read address is still there when the beat comes back.
// `tb/cadr_axi_widen128_tb.cpp` drives the two apart on purpose.
//
// AND IT IS COMBINATIONAL PAYLOAD AND NOTHING ELSE.  Every valid, ready, last,
// response and ID passes the top level straight through; AXI4 on both sides,
// so the length is the master's eight bits unchanged.

`default_nettype none

module cadr_axi_widen128 (
    input  var logic [31:0]  s_awaddr,
    input  var logic [7:0]   s_awlen,
    input  var logic [2:0]   s_awsize,
    input  var logic [31:0]  s_wdata,
    input  var logic [3:0]   s_wstrb,
    input  var logic [31:0]  s_araddr,
    input  var logic [7:0]   s_arlen,
    input  var logic [2:0]   s_arsize,
    output var logic [31:0]  s_rdata,

    output var logic [31:0]  m_awaddr,
    output var logic [7:0]   m_awlen,
    output var logic [2:0]   m_awsize,
    output var logic [127:0] m_wdata,
    output var logic [15:0]  m_wstrb,
    output var logic [31:0]  m_araddr,
    output var logic [7:0]   m_arlen,
    output var logic [2:0]   m_arsize,
    input  var logic [127:0] m_rdata
);

  // Sixteen bytes a beat: AXI's `AxSIZE` code 4.
  localparam logic [2:0] SIZE_BEAT = 3'b100;

  assign m_awaddr = {s_awaddr[31:4], 4'b0000};
  assign m_araddr = {s_araddr[31:4], 4'b0000};

  assign m_awlen = s_awlen;
  assign m_arlen = s_arlen;

  assign m_awsize = SIZE_BEAT;
  assign m_arsize = SIZE_BEAT;

  assign m_wdata = {4{s_wdata}};

  always_comb begin
    unique case (s_awaddr[3:2])
      2'd0: m_wstrb = {12'h000, s_wstrb};
      2'd1: m_wstrb = {8'h00, s_wstrb, 4'h0};
      2'd2: m_wstrb = {4'h0, s_wstrb, 8'h00};
      2'd3: m_wstrb = {s_wstrb, 12'h000};
    endcase
  end

  always_comb begin
    unique case (s_araddr[3:2])
      2'd0: s_rdata = m_rdata[31:0];
      2'd1: s_rdata = m_rdata[63:32];
      2'd2: s_rdata = m_rdata[95:64];
      2'd3: s_rdata = m_rdata[127:96];
    endcase
  end

  // The master's size is always a word, and the low two address bits are
  // always zero: neither says anything the beat needs.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{s_awsize, s_arsize, s_awaddr[1:0], s_araddr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
