// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE VALID BITS ON AN AGILEX 5**: the Agilex 5 version of
// `rtl/machine/quux15_validmap.sv`, which says what it holds and how it is
// cleared.  The same ports and the same behavior, with the 64 columns in
// MLAB.
//
// **A READ IN THE CLOCK AFTER A WRITE TAKES THE WRITE**: the behavioral
// version reads each column as it stands after the last edge, and the cache
// and the MMU read a group in the clock after writing it (a poison of that
// read fails the `walk` and `ports` goldens).  An MLAB writes its cell during
// the clock after the edge that takes the write, and a read of the cell in
// that clock is undefined (Quartus's `no_rw_check`, which the build gives
// these RAMs).  **SO THE WRITE IS FORWARDED**: each column's last write is
// held a clock (`fw_we`, `fw_wa`, `fw_wd`), and a read of its group in that
// clock takes the held bit and not the MLAB's.  From the clock after, the
// MLAB holds it.  Under `QUUX15_A5_MLAB_POISON`, simulation's only, the
// MLAB's read in that clock is the bit's complement, so that a design that
// came to rely on the MLAB there fails (`tools/quux15_ram_eq_check.py
// validmap`, `make quux15-a5`).

`default_nettype none

module quux15_validmap #(
    parameter int unsigned ENTRIES = 4096,
    parameter int unsigned READS = 2,
    localparam int unsigned AW = $clog2(ENTRIES),
    localparam int unsigned GROUPS = ENTRIES / 64
) (
    input  var logic          clk,
    input  var logic          rst,
    input  var logic          clear,
    input  var logic          we,
    input  var logic [AW-1:0] waddr,
    input  var logic          wbit,
    input  var logic [AW-1:0] raddr0,
    input  var logic [AW-1:0] raddr1,
    input  var logic [AW-1:0] raddr2,
    output var logic          rbit0,
    output var logic          rbit1,
    output var logic          rbit2
);

  if (ENTRIES < 64 || (1 << AW) != ENTRIES) begin : g_bad
    $error("quux15_validmap: ENTRIES is %0d; a power of two from 64 up", ENTRIES);
  end

  logic [GROUPS-1:0] gv;
  initial gv = '0;
  logic [63:0] col_we, col_wd;
  logic [AW-7:0] col_wa;
  logic        whole;

  always_comb begin
    whole  = clear || !gv[waddr[AW-1:6]];
    col_wa = waddr[AW-1:6];
    for (int c = 0; c < 64; c++) begin
      col_we[c] = we && (whole || waddr[5:0] == 6'(c));
      col_wd[c] = waddr[5:0] == 6'(c) ? wbit : 1'b0;
    end
  end

  // The write the MLABs are still taking.
  logic [63:0]   fw_we = '0;
  logic [63:0]   fw_wd;
  logic [AW-7:0] fw_wa;
  always_ff @(posedge clk) begin
    fw_we <= col_we;
    fw_wd <= col_wd;
    fw_wa <= col_wa;
  end

  logic [63:0] colq0, colq1, colq2;
  for (genvar c = 0; c < 64; c++) begin : g_col
    logic m [GROUPS];
    initial for (int k = 0; k < GROUPS; k++) m[k] = 1'b0;
    always_ff @(posedge clk) if (col_we[c]) m[col_wa] <= col_wd[c];
    logic q0, q1, q2;
    assign q0 = m[raddr0[AW-1:6]];
    assign q1 = m[raddr1[AW-1:6]];
    assign q2 = m[raddr2[AW-1:6]];
`ifdef QUUX15_A5_MLAB_POISON
    // The MLAB's write window, kept apart from the forwarding's registers.
    logic          pz_we = 1'b0;
    logic [AW-7:0] pz_wa;
    always_ff @(posedge clk) begin
      pz_we <= col_we[c];
      pz_wa <= col_wa;
    end
    assign colq0[c] = (pz_we && pz_wa == raddr0[AW-1:6]) ? ~q0 : q0;
    assign colq1[c] = READS > 1 && ((pz_we && pz_wa == raddr1[AW-1:6]) ? ~q1 : q1);
    assign colq2[c] = READS > 2 && ((pz_we && pz_wa == raddr2[AW-1:6]) ? ~q2 : q2);
`else
    assign colq0[c] = q0;
    assign colq1[c] = READS > 1 && q1;
    assign colq2[c] = READS > 2 && q2;
`endif
  end

  // Each read's bit: the held write's, for a read of its group in the
  // clock after it, else the MLAB's.
  logic h0, h1, h2;
  assign h0 = fw_we[raddr0[5:0]] && fw_wa == raddr0[AW-1:6];
  assign h1 = fw_we[raddr1[5:0]] && fw_wa == raddr1[AW-1:6];
  assign h2 = fw_we[raddr2[5:0]] && fw_wa == raddr2[AW-1:6];
  assign rbit0 = gv[raddr0[AW-1:6]] && (h0 ? fw_wd[raddr0[5:0]] : colq0[raddr0[5:0]]);
  assign rbit1 = READS > 1 && gv[raddr1[AW-1:6]] && (h1 ? fw_wd[raddr1[5:0]] : colq1[raddr1[5:0]]);
  assign rbit2 = READS > 2 && gv[raddr2[AW-1:6]] && (h2 ? fw_wd[raddr2[5:0]] : colq2[raddr2[5:0]]);

  always_ff @(posedge clk) begin
    if (rst) begin
      gv <= '0;
    end else begin
      if (clear) gv <= '0;
      if (we) gv[waddr[AW-1:6]] <= 1'b1;
    end
  end

endmodule

`default_nettype wire
