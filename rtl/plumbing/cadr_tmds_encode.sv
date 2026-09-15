// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One TMDS channel's 8b/10b encoder, from the DVI 1.0 specification.
//
// THERE IS NO muir REFERENCE FOR THIS AND THERE CANNOT BE.  Nothing in MIT's
// drawings is a serial link to a monitor: the SIMPLE TV drove a analog
// video signal off a sync program and a shift register, and what this file
// encodes for is a connector that did not exist.  So it is held to a
// SPECIFICATION rather than to a model, the way `cadr_axi_master.sv` is:
// DVI 1.0, section 3.2.2, "Encode Algorithm", figure 3-5.
//
// THE ALGORITHM, AND THE ONE PLACE IT IS EASY TO GET SUBTLY WRONG.  A pixel
// is turned into ten bits in two stages.  The first minimizes transitions:
// count the ones in the byte, and if there are more than four --- or exactly
// four with bit 0 clear --- build the intermediate word with XNOR and mark it
// with a clear ninth bit, otherwise with XOR and a set one.  The second
// stage balances the direct current: a running disparity counter decides
// whether the eight bits go out as they are or inverted, and the tenth bit
// says which was done.
//
// The subtlety is the counter's update, which the specification writes as
// four different expressions in the three branches.  They are transcribed
// below as one signed difference --- `diff`, the ones less the zeros of the
// intermediate word --- because writing them as the specification does, with
// `N0` and `N1` both present in every line, is how a sign gets flipped in one
// branch of four and survives every test that does not sweep the disparity.
// The check does sweep it: `tb/cadr_hdmi_tx_tb.cpp` reaches EVERY disparity
// state the encoder can be in, by breadth-first search over its own reference
// model, and compares all 256 byte values in each of them.
//
// **A CONTROL PERIOD RESETS THE DISPARITY TO ZERO.**  That is in the
// specification and it is not an optimization: the four control tokens are
// balanced by construction, and a receiver resynchronizes on them.  It is
// also what makes the encoder's state space small enough to search
// exhaustively, since every frame's blanking returns it to a known state.
//
// THE FOUR CONTROL TOKENS ARE CONSTANTS AND ARE WRITTEN OUT IN BINARY, in
// the specification's own bit order, so that they can be read against it
// rather than decoded from hexadecimal.  They are transmitted least
// significant bit first, which is the serializer's business and not this
// module's.

`default_nettype none

module cadr_tmds_encode (
    input  var logic       clk,
    input  var logic       rst,

    // The pixel byte, valid while `de`.
    input  var logic [7:0] d,
    // The two control bits, sent while `de` is low.  On the blue channel
    // these are HSYNC and VSYNC; on the other two they are zero.
    input  var logic [1:0] c,
    input  var logic       de,

    // The ten bits, bit 0 first on the wire.
    output var logic [9:0] q
);

  // ---------------------------------------------- stage one: transitions

  logic [3:0] n1_d;
  always_comb begin
    n1_d = 4'd0;
    for (int i = 0; i < 8; i++) n1_d += {3'b0, d[i]};
  end

  // "if N1(D) > 4 or (N1(D) == 4 and D0 == 0)" --- DVI 1.0 figure 3-5.
  logic use_xnor;
  assign use_xnor = (n1_d > 4'd4) || ((n1_d == 4'd4) && !d[0]);

  // THE CHAIN IS UNROLLED, ONE LINE A BIT, and that is not laziness.  Each
  // bit depends on the one below it, and neither shape that expresses the
  // dependency compactly survives lint: a `for` inside an `always_comb`
  // reads a variable it has already written in the same pass, which is
  // ALWCOMBORDER, and eight continuous assignments to the bits of one
  // packed vector are UNOPTFLAT, because the circularity analysis takes a
  // packed vector as a single signal.  Eight distinct scalars have neither
  // problem, and they read against DVI 1.0 figure 3-5 line for line, which
  // is the form this repository wants anyway.
  logic qm0, qm1, qm2, qm3, qm4, qm5, qm6, qm7;
  assign qm0 = d[0];
  assign qm1 = use_xnor ? ~(qm0 ^ d[1]) : (qm0 ^ d[1]);
  assign qm2 = use_xnor ? ~(qm1 ^ d[2]) : (qm1 ^ d[2]);
  assign qm3 = use_xnor ? ~(qm2 ^ d[3]) : (qm2 ^ d[3]);
  assign qm4 = use_xnor ? ~(qm3 ^ d[4]) : (qm3 ^ d[4]);
  assign qm5 = use_xnor ? ~(qm4 ^ d[5]) : (qm4 ^ d[5]);
  assign qm6 = use_xnor ? ~(qm5 ^ d[6]) : (qm5 ^ d[6]);
  assign qm7 = use_xnor ? ~(qm6 ^ d[7]) : (qm6 ^ d[7]);

  // The ninth bit says which of the two was used: set for XOR, clear for
  // XNOR, so that the receiver can undo it.
  logic [8:0] qm;
  assign qm = {~use_xnor, qm7, qm6, qm5, qm4, qm3, qm2, qm1, qm0};

  // ---------------------------------------------- stage two: balancing

  logic [3:0] n1_qm;
  always_comb begin
    n1_qm = 4'd0;
    for (int i = 0; i < 8; i++) n1_qm += {3'b0, qm[i]};
  end

  // The ones less the zeros of the intermediate word: `N1(q_m) - N0(q_m)`,
  // which is even and lies in -8 .. +8.  Every one of the specification's
  // counter updates is written in terms of this, which is what stops the
  // three branches disagreeing about a sign.
  logic signed [5:0] diff;
  assign diff = signed'({2'b0, n1_qm}) - signed'(6'd8 - {2'b0, n1_qm});

  // The running disparity.  It is bounded by the algorithm itself --- a
  // symbol that would take it away from zero is inverted --- and never
  // leaves -8 .. +8, so six signed bits are two more than it can use.
  logic signed [5:0] cnt, cnt_n;
  logic [9:0] q_n;

  always_comb begin
    if (!de) begin
      cnt_n = 6'sd0;
      unique case (c)
        2'b00:   q_n = 10'b1101010100;
        2'b01:   q_n = 10'b0010101011;
        2'b10:   q_n = 10'b0101010100;
        default: q_n = 10'b1010101011;
      endcase
    end else if ((cnt == 6'sd0) || (diff == 6'sd0)) begin
      // No running imbalance, or a symbol that carries none: the ninth bit
      // decides, and the tenth is its complement.
      q_n = {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
      cnt_n = qm[8] ? (cnt + diff) : (cnt - diff);
    end else if (((cnt > 6'sd0) && (diff > 6'sd0)) ||
                 ((cnt < 6'sd0) && (diff < 6'sd0))) begin
      // The symbol would push the disparity further the way it already
      // leans, so it goes out inverted.
      q_n = {1'b1, qm[8], ~qm[7:0]};
      cnt_n = cnt + (qm[8] ? 6'sd2 : 6'sd0) - diff;
    end else begin
      q_n = {1'b0, qm[8], qm[7:0]};
      cnt_n = cnt - (qm[8] ? 6'sd0 : 6'sd2) + diff;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= 6'sd0;
      // A reset leaves the line in a control period, which is what a
      // monitor with nothing to lock to should see.
      q   <= 10'b1101010100;
    end else begin
      cnt <= cnt_n;
      q   <= q_n;
    end
  end

endmodule

`default_nettype wire
