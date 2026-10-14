// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **DISPATCH MEMORY'S TWO VERSIONS, RUN ALIKE** (`tools/quux15_ram_eq_check.py
// dmem`): random writes and reads of `quux15_dmem`, the write, both
// addresses and both entries printed each clock, built once with
// `rtl/machine/quux15_dmem.sv` and once with `rtl/plumbing/agilex5/
// quux15_dmem.sv` under `QUUX15_A5_MLAB_POISON`, and the two outputs compared
// line for line.  The addresses are mostly sixteen, both halves, so that a
// read often names what the clock before wrote (the MLAB's write window)
// and what this clock writes.  The stimulus is the testbench's own
// generator, seeded by `+seed=`.

`default_nettype none
// A testbench's own style: blocking assignments in its processes, and a
// generator's word used in part.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */

module quux15_dmem_eq_tb;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic        we = 1'b0;
  logic [11:0] waddr = '0, ex_a = '0, ro_a = '0;
  logic [16:0] wdata = '0, ex_e, ro_e;
  quux15_dmem dut (.*);

  logic [63:0] s;
  function automatic logic [31:0] rnd();
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    return s[31:0];
  endfunction
  function automatic logic [11:0] addr();
    logic [31:0] r;
    r = rnd();
    return (r[1:0] == 2'd0) ? 12'(r >> 8) : 12'((r >> 8) % 16);
  endfunction

  int unsigned seed, clocks;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("clocks=%d", clocks)) clocks = 200000;
    s = 64'h9e3779b97f4a7c15 ^ 64'(seed);
    for (int unsigned n = 0; n < clocks; n++) begin
      @(negedge clk);
      we    = rnd() % 3 == 0;
      waddr = addr();
      wdata = 17'(rnd());
      ex_a  = addr();
      ro_a  = addr();
      #1;
      $display("%0d %b %h %h %h %h | %h %h", n, we, waddr, wdata, ex_a, ro_a, ex_e, ro_e);
    end
    $finish;
  end
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
`default_nettype wire
