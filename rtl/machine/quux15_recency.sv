// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **A BIT A SET IN LUT RAM, WRITTEN THREE TIMES A CLOCK** (contract G3
// revision 15, A15b.6): the cache's recency bits, the way each set used last,
// which a P lookup's hit, a T lookup's hit and a fill's install each write.
// Three banks of `SETS` bits, each written by one of the three alone; a set's
// bit is the three banks' bits XORed, and a write stores its bit XOR the two
// other banks' bits at its set, so that it alone decides the XOR.  Each bank
// a LUT RAM, read where the other two write and where the bit is read.
//
// **WRITES TO ONE SET IN ONE CLOCK: THE LATER WINS**, as statements in that
// order would leave it: an install over a T hit over a P hit.  The bit read
// is the bit as the clock began.  Every bit 0 at power-on; nothing clears
// them (muir's `invalidate` keeps the recency, `port.rs`).

`default_nettype none

module quux15_recency #(
    parameter int unsigned SETS = 4096,
    localparam int unsigned AW = $clog2(SETS)
) (
    input  var logic          clk,
    input  var logic          we0,
    input  var logic [AW-1:0] wa0,
    input  var logic          wd0,
    input  var logic          we1,
    input  var logic [AW-1:0] wa1,
    input  var logic          wd1,
    input  var logic          we2,
    input  var logic [AW-1:0] wa2,
    input  var logic          wd2,
    input  var logic [AW-1:0] ra,
    output var logic          rd
);

  logic b0 [SETS];
  logic b1 [SETS];
  logic b2 [SETS];
  initial
    for (int k = 0; k < SETS; k++) begin
      b0[k] = 1'b0;
      b1[k] = 1'b0;
      b2[k] = 1'b0;
    end

  // Each write's enable, a later one to its set taking its place.
  logic e0, e1, e2;
  always_comb begin
    e2 = we2;
    e1 = we1 && !(we2 && wa2 == wa1);
    e0 = we0 && !(we1 && wa1 == wa0) && !(we2 && wa2 == wa0);
  end

  always_ff @(posedge clk) if (e0) b0[wa0] <= wd0 ^ b1[wa0] ^ b2[wa0];
  always_ff @(posedge clk) if (e1) b1[wa1] <= wd1 ^ b0[wa1] ^ b2[wa1];
  always_ff @(posedge clk) if (e2) b2[wa2] <= wd2 ^ b0[wa2] ^ b1[wa2];

  assign rd = b0[ra] ^ b1[ra] ^ b2[ra];

endmodule

`default_nettype wire
