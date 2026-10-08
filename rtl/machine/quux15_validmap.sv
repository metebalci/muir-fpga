// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **4,096 VALID BITS IN RAM, CLEARED ALL AT ONCE** (contract G3 revision 15,
// A15b.6 for the cache's lines, A14.4 for the TLB's entries): a bit an
// entry, kept as 64 columns of 64 words in LUT RAM, a word of each column a
// group of 64 entries, and beside them a group's own valid bit in a
// register.  An entry is valid when its bit and its group's are set.
//
// **A CLEAR IS ONE CLOCK**: every group's bit cleared, which is what muir's
// sweep and empty do to the whole cache or TLB at once (the clocks they hold
// lookups for are the port's and the MMU's to count).  The columns keep
// their stale bits, and a group's bits are rewritten whole the first time
// an entry of the group is written after a clear: the entry's bit as
// written, every other bit of the group cleared, and the group valid again.
// So nothing stale is ever seen, and no clear sweeps the RAM.
//
// One write a clock, of one entry; `READS` reads, up to three, each from LUT RAM as it
// stands after the last edge.  A clear and a write in one clock: the clear
// first, the write after it.

`default_nettype none

module quux15_validmap #(
    // The entries, a power of two from 64 up; the reads.
    parameter int unsigned ENTRIES = 4096,
    parameter int unsigned READS = 2,
    localparam int unsigned AW = $clog2(ENTRIES),
    localparam int unsigned GROUPS = ENTRIES / 64
) (
    input  var logic          clk,
    // -RESET clears as a clear does; tie it low where nothing resets.
    input  var logic          rst,
    input  var logic          clear,
    input  var logic          we,
    input  var logic [AW-1:0] waddr,
    input  var logic          wbit,
    // The reads, up to three; each its own port, so that one read's word
    // may feed another's address.
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

  // The write: one column, or every column of a group being made valid.
  always_comb begin
    whole  = clear || !gv[waddr[AW-1:6]];
    col_wa = waddr[AW-1:6];
    for (int c = 0; c < 64; c++) begin
      col_we[c] = we && (whole || waddr[5:0] == 6'(c));
      col_wd[c] = waddr[5:0] == 6'(c) ? wbit : 1'b0;
    end
  end

  logic [63:0] colq0, colq1, colq2;
  for (genvar c = 0; c < 64; c++) begin : g_col
    logic m [GROUPS];
    initial for (int k = 0; k < GROUPS; k++) m[k] = 1'b0;
    always_ff @(posedge clk) if (col_we[c]) m[col_wa] <= col_wd[c];
    assign colq0[c] = m[raddr0[AW-1:6]];
    if (READS > 1) begin : g_r1
      assign colq1[c] = m[raddr1[AW-1:6]];
    end else begin : g_n1
      assign colq1[c] = 1'b0;
    end
    if (READS > 2) begin : g_r2
      assign colq2[c] = m[raddr2[AW-1:6]];
    end else begin : g_n2
      assign colq2[c] = 1'b0;
    end
  end

  assign rbit0 = gv[raddr0[AW-1:6]] && colq0[raddr0[5:0]];
  assign rbit1 = READS > 1 && gv[raddr1[AW-1:6]] && colq1[raddr1[5:0]];
  assign rbit2 = READS > 2 && gv[raddr2[AW-1:6]] && colq2[raddr2[5:0]];

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
