// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE MACRO DISPATCH MEMORY'S TWO VERSIONS, RUN ALIKE**
// (`tools/quux15_ram_eq_check.py mdmem`): random writes and reads of
// `quux15_mdmem`, every port's entry printed each clock, built once with
// `rtl/machine/quux15_mdmem.sv` and once with `rtl/plumbing/agilex5/
// quux15_mdmem.sv` over `tb/quux15_altdpram_model.sv`, and the two outputs
// compared line for line: the clock, the write, the five addresses and the
// five entries.  The addresses are mostly sixteen, so that a read
// often names what the clock before wrote (the MLAB's write window, which
// the model poisons) and what this clock writes.  The stimulus is the
// testbench's own generator, seeded by `+seed=`, so that it cannot depend on
// the design under it.

`default_nettype none
// A testbench's own style: blocking assignments in its processes, and a
// generator's word used in part.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */

module quux15_mdmem_eq_tb;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic        we = 1'b0, wmay = 1'b0;
  logic [9:0]  waddr = '0;
  logic [17:0] wdata = '0;
  logic [9:0]  ra[5];
  logic [17:0] re[5];
  initial for (int i = 0; i < 5; i++) ra[i] = '0;

  quux15_mdmem dut (
      .clk, .we, .waddr, .wdata, .wmay,
      .rd_a(ra[0]), .rd_e(re[0]), .rx_a(ra[1]), .rx_e(re[1]), .ex_a(ra[2]), .ex_e(re[2]),
      .d_a(ra[3]), .d_e(re[3]), .ro_a(ra[4]), .ro_e(re[4]));

  // xorshift64, the testbench's alone.
  logic [63:0] s;
  function automatic logic [31:0] rnd();
    s = s ^ (s << 13);
    s = s ^ (s >> 7);
    s = s ^ (s << 17);
    return s[31:0];
  endfunction
  function automatic logic [9:0] addr();
    logic [31:0] r;
    r = rnd();
    return (r[1:0] == 2'd0) ? r[17:8] : {6'd0, r[11:8]};
  endfunction

  int unsigned seed, clocks;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("clocks=%d", clocks)) clocks = 200000;
    s = 64'h9e3779b97f4a7c15 ^ 64'(seed);
    for (int unsigned n = 0; n < clocks; n++) begin
      @(negedge clk);
      we    = rnd() % 3 == 0;
      wmay  = we;
      waddr = addr();
      wdata = 18'(rnd());
      for (int i = 0; i < 5; i++) ra[i] = addr();
      #1;
      $display("%0d %b %h %h %h %h %h %h %h | %h %h %h %h %h", n, we, waddr, wdata,
               ra[0], ra[1], ra[2], ra[3], ra[4], re[0], re[1], re[2], re[3], re[4]);
    end
    $finish;
  end
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
`default_nettype wire
