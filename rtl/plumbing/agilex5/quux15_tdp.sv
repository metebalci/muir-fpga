// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S TRUE DUAL-PORT RAM ON AN AGILEX 5**: the Agilex 5 version
// of `rtl/machine/quux15_tdp.sv`, which says what it holds and how it
// behaves.  The same ports and the same behavior, built so that Quartus
// takes it into M20K:
//
// - **A BYTE-ENABLED RAM IS SPLIT INTO WORD COLUMNS**, five bytes a column,
//   each with one write enable, since an M20K takes no 40 byte enables.
//   Revision 15's port writes a line's word as its five bytes together or
//   the whole line (`quux15_port.sv`), so a column's five enables are
//   always equal; the testbench's build stops on any write where they are
//   not.
// - **QUARTUS'S READ-DURING-WRITE SETTING** (`ramstyle "no_rw_check"`): a
//   read of the address the other port writes in the same clock is the word
//   the behavioral version leaves undefined and poisons under
//   `QUUX15_RDW_POISON`, as this one does.  Each port's own write leaves its
//   output as it was (no change), as there.

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

  if (BYTES == 1) begin : g_one
    quux15_tdp_col #(.WIDTH(WIDTH), .DEPTH(DEPTH), .INIT_WORD(INIT_WORD)) c (
        .clk, .a_we(a_en && a_we[0]), .a_re(a_en && !a_we[0]), .a_addr, .a_wdata, .a_q,
        .b_we(b_en && b_we[0]), .b_re(b_en && !b_we[0]), .b_addr, .b_wdata, .b_q);
  end else begin : g_cols
    localparam int unsigned CB = 5;          // bytes a column
    localparam int unsigned CW = CB * BYTE;
    if (BYTES % CB != 0) begin : g_bad_cols
      $error("quux15_tdp: %0d bytes are not whole columns of %0d", BYTES, CB);
    end
    for (genvar k = 0; k < BYTES / CB; k++) begin : g_col
      quux15_tdp_col #(.WIDTH(CW), .DEPTH(DEPTH), .INIT_WORD(INIT_WORD[k*CW +: CW])) c (
          .clk,
          .a_we(a_en && a_we[CB*k]), .a_re(a_en && ~|a_we), .a_addr,
          .a_wdata(a_wdata[k*CW +: CW]), .a_q(a_q[k*CW +: CW]),
          .b_we(b_en && b_we[CB*k]), .b_re(b_en && ~|b_we), .b_addr,
          .b_wdata(b_wdata[k*CW +: CW]), .b_q(b_q[k*CW +: CW]));
`ifdef VERILATOR
      always_ff @(posedge clk) begin
        if ((a_en && a_we[CB*k +: CB] != '0 && a_we[CB*k +: CB] != '1)
            || (b_en && b_we[CB*k +: CB] != '0 && b_we[CB*k +: CB] != '1))
          $error("quux15_tdp: a write of part of column %0d (a %b, b %b)", k,
                 a_we[CB*k +: CB], b_we[CB*k +: CB]);
      end
`endif
    end
  end
endmodule

// One column: Quartus's true dual-port template.  A port reads when its
// whole word writes nothing, as the behavioral version's does, so that its
// output is left as it was by a write to any column (no change).
/* verilator lint_off DECLFILENAME */
module quux15_tdp_col #(
    parameter int unsigned WIDTH = 40,
    parameter int unsigned DEPTH = 4096,
    parameter logic [WIDTH-1:0] INIT_WORD = '0,
    localparam int unsigned AW = $clog2(DEPTH)
) (
    input  var logic             clk,
    input  var logic             a_we,
    input  var logic             a_re,
    input  var logic [AW-1:0]    a_addr,
    input  var logic [WIDTH-1:0] a_wdata,
    output var logic [WIDTH-1:0] a_q,
    input  var logic             b_we,
    input  var logic             b_re,
    input  var logic [AW-1:0]    b_addr,
    input  var logic [WIDTH-1:0] b_wdata,
    output var logic [WIDTH-1:0] b_q
);
  (* ramstyle = "no_rw_check" *) logic [WIDTH-1:0] mem[DEPTH] /* verilator public_flat_rw */;

  initial begin
    for (int unsigned k = 0; k < DEPTH; k++) mem[k] = INIT_WORD;
  end

  logic a_poison, b_poison;
`ifdef QUUX15_RDW_POISON
  assign a_poison = b_we && b_addr == a_addr;
  assign b_poison = a_we && a_addr == b_addr;
`else
  assign a_poison = 1'b0;
  assign b_poison = 1'b0;
`endif

  /* verilator lint_off MULTIDRIVEN */
  always @(posedge clk) if (a_we) mem[a_addr] <= a_wdata;
  always @(posedge clk) if (a_re) a_q <= a_poison ? ~mem[a_addr] : mem[a_addr];
  always @(posedge clk) if (b_we) mem[b_addr] <= b_wdata;
  always @(posedge clk) if (b_re) b_q <= b_poison ? ~mem[b_addr] : mem[b_addr];
  /* verilator lint_on MULTIDRIVEN */
endmodule
/* verilator lint_on DECLFILENAME */

`default_nettype wire
