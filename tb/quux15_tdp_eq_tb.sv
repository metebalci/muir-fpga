// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S TRUE DUAL-PORT RAM IN ITS TWO VERSIONS, RUN ALIKE**
// (`tools/quux15_ram_eq_check.py tdp`): `quux15_tdp` at every width and
// byte-enable form the core instantiates, each driven at random as revision
// 15 uses it, built once with `rtl/machine/quux15_tdp.sv` and once with
// `rtl/plumbing/agilex5/quux15_tdp.sv`, and the two outputs compared clock
// for clock.  Each line is the clock and, for each RAM, a running hash of
// both its ports' words.
//
// The forms (`quux15_core.sv`, `quux15_store.sv`, `quux15_port.sv`): A and
// the PDL buffer, 40 bits; the control store, 64; each way's tags at the
// three boards' caches (`26 - log2(SETS)` bits at 4,096, 1,024 and 256
// sets); and each way's lines, 320 bits in 8-bit bytes, at the same depths.
//
// As revision 15 uses it: a write names a whole word of five bytes or the
// whole line (`quux15_port.sv`), and the two ports never meet at an address
// one of them writes, where the behavioral version poisons the read.  With
// `+partial=a` (or `b`) a write of that port sometimes names one byte, which
// the Agilex 5 version's guard must refuse.  Each RAM has a generator of its
// own, seeded by `+seed=` and its place, so the stimulus cannot depend on
// the design under it or on the order Verilator runs the processes in.

`default_nettype none
// A testbench's own style: blocking assignments in its processes, and a
// generator's word used in part.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */

/* verilator lint_off DECLFILENAME */
module quux15_tdp_eq_case #(
    parameter int unsigned WIDTH = 40,
    parameter int unsigned DEPTH = 1024,
    parameter int unsigned BYTE  = WIDTH,
    parameter int unsigned PLACE = 0,
    localparam int unsigned BYTES = WIDTH / BYTE,
    localparam int unsigned AW    = $clog2(DEPTH)
) (
    input  var logic        clk,
    input  var logic [31:0] seed,
    input  var logic [1:0]  partial,
    output var logic [31:0] h
);
  logic             a_en = 1'b0, b_en = 1'b0;
  logic [BYTES-1:0] a_we = '0, b_we = '0;
  logic [AW-1:0]    a_addr = '0, b_addr = '0;
  logic [WIDTH-1:0] a_wdata = '0, b_wdata = '0, a_q, b_q;
  quux15_tdp #(.WIDTH(WIDTH), .DEPTH(DEPTH), .BYTE(BYTE)) dut (.*);

  logic [63:0] s;
  logic        started = 1'b0;
  function automatic logic [31:0] rnd();
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    return s[31:0];
  endfunction
  function automatic logic [BYTES-1:0] we_of(input logic part);
    logic [BYTES-1:0] w;
    logic [31:0]      r;
    r = rnd();
    case (r[1:0])
      2'd0, 2'd1: w = '0;
      2'd2:       w = '1;
      default: begin
        // One word of five bytes, or the whole of a RAM with one enable.
        w = '0;
        for (int unsigned k = 0; k < BYTES; k++)
          if (BYTES == 1 || k / 5 == (r >> 8) % (BYTES / 5)) w[k] = 1'b1;
      end
    endcase
    if (part && BYTES > 1 && r[7:2] == 6'd0)
      for (int unsigned k = 0; k < BYTES; k++) w[k] = k == (r >> 8) % BYTES;
    return w;
  endfunction
  function automatic logic [WIDTH-1:0] word();
    logic [WIDTH+31:0] v;
    for (int unsigned i = 0; i < WIDTH; i += 32) v[i +: 32] = rnd();
    return v[WIDTH-1:0];
  endfunction
  function automatic logic [AW-1:0] addr();
    logic [31:0] r;
    r = rnd();
    return (r[2:0] == 3'd0) ? AW'((r >> 8) % DEPTH) : AW'((r >> 8) % 8);
  endfunction

  // Hashed, then driven, at each falling edge: the words are those the
  // rising edge before registered.
  always @(negedge clk) begin
    if (!started) begin
      s = 64'h9e3779b97f4a7c15 ^ {32'(PLACE), seed};
      h = 32'h811c9dc5;
      started = 1'b1;
    end
    for (int unsigned i = 0; i < WIDTH; i += 32) h = (h ^ 32'(a_q >> i)) * 32'h01000193;
    for (int unsigned i = 0; i < WIDTH; i += 32) h = (h ^ 32'(b_q >> i)) * 32'h01000193;
    a_en = rnd() % 4 != 0;
    b_en = rnd() % 4 != 0;
    a_we = we_of(partial[0]);
    b_we = we_of(partial[1]);
    a_wdata = word();
    b_wdata = word();
    a_addr = addr();
    b_addr = addr();
    if (a_en && b_en && a_addr == b_addr && (a_we != '0 || b_we != '0)) b_addr = b_addr + 1'b1;
  end
endmodule
/* verilator lint_on DECLFILENAME */

module quux15_tdp_eq_tb;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic [31:0] seed;
  logic [1:0]  partial = 2'd0;
  string       which;
  int unsigned clocks, n = 0;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if ($value$plusargs("partial=%s", which)) partial = (which == "a") ? 2'd1 : (which == "b") ? 2'd2 : 2'd0;
    if (!$value$plusargs("clocks=%d", clocks)) clocks = 50000;
  end

  logic [31:0] h[9];
  quux15_tdp_eq_case #(.WIDTH(40),  .DEPTH(1024),  .PLACE(0)) c_amem   (.clk, .seed, .partial, .h(h[0]));
  quux15_tdp_eq_case #(.WIDTH(40),  .DEPTH(16384), .PLACE(1)) c_pdl    (.clk, .seed, .partial, .h(h[1]));
  quux15_tdp_eq_case #(.WIDTH(64),  .DEPTH(16384), .PLACE(2)) c_store  (.clk, .seed, .partial, .h(h[2]));
  quux15_tdp_eq_case #(.WIDTH(14),  .DEPTH(4096),  .PLACE(3)) c_tags64 (.clk, .seed, .partial, .h(h[3]));
  quux15_tdp_eq_case #(.WIDTH(16),  .DEPTH(1024),  .PLACE(4)) c_tags16 (.clk, .seed, .partial, .h(h[4]));
  quux15_tdp_eq_case #(.WIDTH(18),  .DEPTH(256),   .PLACE(5)) c_tags4  (.clk, .seed, .partial, .h(h[5]));
  quux15_tdp_eq_case #(.WIDTH(320), .DEPTH(4096), .BYTE(8), .PLACE(6)) c_lines64 (.clk, .seed, .partial, .h(h[6]));
  quux15_tdp_eq_case #(.WIDTH(320), .DEPTH(1024), .BYTE(8), .PLACE(7)) c_lines16 (.clk, .seed, .partial, .h(h[7]));
  quux15_tdp_eq_case #(.WIDTH(320), .DEPTH(256),  .BYTE(8), .PLACE(8)) c_lines4  (.clk, .seed, .partial, .h(h[8]));

  // Printed at the rising edge, between the falling edges that set them.
  always @(posedge clk) begin
    if (n > 0)
      $display("%0d %h %h %h %h %h %h %h %h %h", n, h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]);
    n++;
    if (n > clocks) $finish;
  end
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
`default_nettype wire
