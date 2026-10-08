// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **A TRUE DUAL-PORT RAM OF REVISION 15'S MEMORY SIDE**: two ports, each a
// synchronous read with its word registered or a write of the bytes its
// enables name, one or the other a clock.  The cache's tags and lines are
// each one (`quux15_port.sv`).
//
// **NO_CHANGE**: a port that writes leaves its output as it was, which is
// what UltraRAM builds (a block RAM builds it too), so nothing reads a word
// through its own port's write.  **A READ OF THE ADDRESS THE OTHER PORT
// WRITES IN THE SAME CLOCK** is the word no primitive defines: under
// `QUUX15_RDW_POISON` it takes the old word's complement, so that a design
// that came to rely on it fails its golden.  The port is written never to
// make one where it uses the word; the poison is a simulation's.
//
// `BYTE` bits a byte, each with its write enable: 9 for the cache's lines,
// five bytes a word (UltraRAM's and block RAM's byte with its parity bit),
// and `WIDTH` for one enable.  `INIT_WORD` is every word at power-on.

`default_nettype none

module quux15_tdp #(
    parameter int unsigned WIDTH = 40,
    parameter int unsigned DEPTH = 4096,
    parameter int unsigned BYTE  = WIDTH,
    parameter logic [WIDTH-1:0] INIT_WORD = '0,
    localparam int unsigned BYTES = WIDTH / BYTE,
    localparam int unsigned AW    = $clog2(DEPTH)
) (
    input  var logic             clk,
    input  var logic             a_en,
    input  var logic [BYTES-1:0] a_we,
    input  var logic [AW-1:0]    a_addr,
    input  var logic [WIDTH-1:0] a_wdata,
    output var logic [WIDTH-1:0] a_q,
    input  var logic             b_en,
    input  var logic [BYTES-1:0] b_we,
    input  var logic [AW-1:0]    b_addr,
    input  var logic [WIDTH-1:0] b_wdata,
    output var logic [WIDTH-1:0] b_q
);

  if (BYTES * BYTE != WIDTH) begin : g_bad_bytes
    $error("quux15_tdp: WIDTH %0d is not a whole number of %0d-bit bytes", WIDTH, BYTE);
  end

  logic [WIDTH-1:0] mem[DEPTH] /* verilator public_flat_rw */;

  initial begin
    for (int unsigned k = 0; k < DEPTH; k++) mem[k] = INIT_WORD;
  end

  logic a_poison, b_poison;
`ifdef QUUX15_RDW_POISON
  assign a_poison = b_en && |b_we && b_addr == a_addr;
  assign b_poison = a_en && |a_we && a_addr == b_addr;
`else
  assign a_poison = 1'b0;
  assign b_poison = 1'b0;
`endif

  // Two processes write the one array, as the vendors' true dual-port
  // templates do; `always_ff` would refuse a second writer.
  /* verilator lint_off MULTIDRIVEN */
  always @(posedge clk) begin
    if (a_en) begin
      if (|a_we) begin
        for (int unsigned k = 0; k < BYTES; k++)
          if (a_we[k]) mem[a_addr][k*BYTE +: BYTE] <= a_wdata[k*BYTE +: BYTE];
      end else begin
        a_q <= a_poison ? ~mem[a_addr] : mem[a_addr];
      end
    end
  end

  always @(posedge clk) begin
    if (b_en) begin
      if (|b_we) begin
        for (int unsigned k = 0; k < BYTES; k++)
          if (b_we[k]) mem[b_addr][k*BYTE +: BYTE] <= b_wdata[k*BYTE +: BYTE];
      end else begin
        b_q <= b_poison ? ~mem[b_addr] : mem[b_addr];
      end
    end
  end
  /* verilator lint_on MULTIDRIVEN */

endmodule

`default_nettype wire
