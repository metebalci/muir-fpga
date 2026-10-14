// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE VALID BITS' TWO VERSIONS, RUN ALIKE** (`tools/quux15_ram_eq_check.py
// validmap`): random clears, writes and reads of `quux15_validmap`, the
// inputs and every read's bit printed each clock, built once with
// `rtl/machine/quux15_validmap.sv` and once with `rtl/plumbing/agilex5/
// quux15_validmap.sv` under `QUUX15_A5_MLAB_POISON`, and the two outputs
// compared line for line, at each `ENTRIES` and `READS` the core builds.
// The writes are mostly to four groups and the reads mostly to the groups
// written, so that a read often names the group the clock before wrote
// (the MLAB's write window) and the one this clock writes.  The stimulus
// is the testbench's own generator, seeded by `+seed=`.

`default_nettype none
// A testbench's own style: blocking assignments in its processes, and a
// generator's word used in part.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */

module quux15_validmap_eq_tb;
  parameter int unsigned ENTRIES = 4096, READS = 2;
  localparam int unsigned AW = $clog2(ENTRIES);
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic          rst = 1'b1, clear = 1'b0, we = 1'b0, wbit = 1'b0;
  logic [AW-1:0] waddr = '0, raddr0 = '0, raddr1 = '0, raddr2 = '0;
  logic          rbit0, rbit1, rbit2;
  quux15_validmap #(.ENTRIES(ENTRIES), .READS(READS)) dut (.*);

  logic [63:0] s;
  function automatic logic [31:0] rnd();
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    return s[31:0];
  endfunction
  // An entry of one of four groups mostly, else anywhere.
  function automatic logic [AW-1:0] addr();
    logic [31:0] r;
    r = rnd();
    return (r[2:0] == 3'd0) ? AW'(r >> 8) : AW'({(r >> 8) % 4, 6'(r >> 16)});
  endfunction
  // A read of the group just written, often.
  function automatic logic [AW-1:0] near(input logic [AW-1:0] a);
    logic [31:0] r;
    r = rnd();
    return (r[1:0] != 2'd0) ? AW'({a[AW-1:6], 6'(r >> 8)}) : addr();
  endfunction

  int unsigned seed, clocks;
  logic [AW-1:0] last;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("clocks=%d", clocks)) clocks = 200000;
    s = 64'h9e3779b97f4a7c15 ^ 64'(seed);
    last = '0;
    for (int unsigned n = 0; n < clocks; n++) begin
      @(negedge clk);
      rst    = n < 2;
      clear  = rnd() % 64 == 0;
      we     = rnd() % 2 == 0;
      waddr  = addr();
      wbit   = rnd() % 4 != 0;
      raddr0 = near(last);
      raddr1 = near(last);
      raddr2 = near(waddr);
      if (we) last = waddr;
      #1;
      $display("%0d %b %b %b %h %b %h %h %h | %b %b %b", n, rst, clear, we, waddr, wbit,
               raddr0, raddr1, raddr2, rbit0, rbit1, rbit2);
    end
    $finish;
  end
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
`default_nettype wire
