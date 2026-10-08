// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **A STAND-IN FOR REVISION 15'S CORE, FOR THE CHECK OF ITS TESTBENCH.**  It
// plays a trace of `golden/src/quux15.rs` back, a row a clock, on the outputs
// revision 15's core shows `tb/quux15_core_tb.cpp`: row 0 out of reset, and
// the next row at each rising edge with `rst` low.  It computes nothing, and
// nothing of the fabric is built with it; `tools/quux15_replay_check.py`
// runs the testbench against it to show that the testbench passes a core that
// agrees with muir and names the first clock and column of one that does not.
//
//   +replay=<trace>   the trace to play, which need not be the one the
//                     testbench compares against
//   +stub             show zeros on every output: a core that does nothing
//   +fault_clock=<k> +fault_col=<c> +fault_xor=<x>
//                     row k's column c (the trace's own numbering, the clock
//                     being column 0) shown XOR x: one wrong value
//
// Not synthesizable, and not meant to be: it reads a file in its initial
// block and at every edge.

/* verilator lint_off BLKSEQ */
module quux15_replay (
    input  logic        clk,
    input  logic        rst,
    output logic [63:0] obs_cs,
    output logic [63:0] obs_rd,
    output logic [63:0] obs_ex,
    output logic [63:0] obs_wb,
    output logic [63:0] obs_commit,
    output logic [63:0] obs_pdlptr,
    output logic [63:0] obs_pdlidx,
    output logic [63:0] obs_spcptr,
    output logic [63:0] obs_q,
    output logic [63:0] obs_vma,
    output logic [63:0] obs_md,
    output logic [63:0] obs_lc,
    output logic [63:0] obs_ic,
    output logic [63:0] obs_oalow,
    output logic [63:0] obs_oahigh,
    output logic [63:0] obs_grant,
    output logic [63:0] obs_gaddr,
    output logic [63:0] obs_mdl,
    output logic [63:0] obs_mdword,
    output logic [63:0] obs_reg,
    output logic [63:0] obs_raddr,
    output logic [63:0] obs_queue,
    output logic [63:0] obs_inflight,
    output logic [63:0] obs_halted
);
  // The clock and the 24 columns `golden/src/trace15.rs` writes.
  localparam int COLUMNS = 25;

  integer fd;
  longint unsigned shown;
  longint unsigned fault_clock;
  int fault_col;
  logic [63:0] fault_xor;
  bit stub;
  logic [63:0] row[COLUMNS];

  // The trace's next row into `row`; at its end the last row stays.
  task automatic read_row();
    string line;
    int n;
    logic [63:0] c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11;
    logic [63:0] c12, c13, c14, c15, c16, c17, c18, c19, c20, c21, c22, c23, c24;
    while ($fgets(line, fd) != 0) begin
      if (line.len() < 2 || line.getc(0) == "#") continue;
      n = $sscanf(line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                  c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16,
                  c17, c18, c19, c20, c21, c22, c23, c24);
      if (n != COLUMNS) $fatal(1, "quux15_replay: a row of %0d columns, not %0d", n, COLUMNS);
      row = '{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17,
              c18, c19, c20, c21, c22, c23, c24};
      return;
    end
  endtask

  // Column `c` of the row shown, as the plusargs say to show it.
  function automatic logic [63:0] value(int c);
    if (stub) return 64'd0;
    if (shown == fault_clock && c == fault_col) return row[c] ^ fault_xor;
    return row[c];
  endfunction

  task automatic show();
    obs_cs     = value(1);
    obs_rd     = value(2);
    obs_ex     = value(3);
    obs_wb     = value(4);
    obs_commit = value(5);
    obs_pdlptr = value(6);
    obs_pdlidx = value(7);
    obs_spcptr = value(8);
    obs_q      = value(9);
    obs_vma    = value(10);
    obs_md     = value(11);
    obs_lc     = value(12);
    obs_ic     = value(13);
    obs_oalow  = value(14);
    obs_oahigh = value(15);
    obs_grant  = value(16);
    obs_gaddr  = value(17);
    obs_mdl    = value(18);
    obs_mdword = value(19);
    obs_reg    = value(20);
    obs_raddr    = value(21);
    obs_queue    = value(22);
    obs_inflight = value(23);
    obs_halted   = value(24);
  endtask

  initial begin
    string path;
    if (!$value$plusargs("replay=%s", path)) $fatal(1, "quux15_replay: no +replay=<trace>");
    stub = $test$plusargs("stub") != 0;
    if (!$value$plusargs("fault_clock=%d", fault_clock)) fault_clock = '1;
    if (!$value$plusargs("fault_col=%d", fault_col)) fault_col = -1;
    if (!$value$plusargs("fault_xor=%h", fault_xor)) fault_xor = 64'd0;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "quux15_replay: cannot read %s", path);
    for (int c = 0; c < COLUMNS; c++) row[c] = 64'd0;
    shown = 0;
    read_row();
    show();
  end

  always @(posedge clk) begin
    if (!rst) begin
      read_row();
      shown = shown + 1;
      show();
    end
  end
endmodule
/* verilator lint_on BLKSEQ */
