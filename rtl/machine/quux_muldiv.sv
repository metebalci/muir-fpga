// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's multiply and divide: ALU functions 42 and 43, `MUL` and `DIV`, each
// in one instruction (revision 3).
//
// muir's `muldiv::run`, ported.  Both are DEFINED as the CADR's own steps and
// muir computes them by running the steps; this computes the same words:
//
//   `MUL`  32 `MULTIPLY-STEP`s (ALU function 40, `MUS`): each adds the A
//          source into the 33-bit array when `Q<0>` is set and passes the M
//          operand through when it is not, then shifts the output bus right
//          with the array's bit 32 in at the top and `Q` right with the
//          array's bit 0 in at the top.  The first step's M operand is the
//          instruction's M source and every later one the step before's
//          output bus.  What 32 of them leave is one product, and it is
//          computed as one here: the 64-bit
//
//              {OB, Q} = sign-extended M + sign-extended A * Q
//
//          which is what the step sequence is, bit for bit, for every
//          operand: the array's ninth slice sign-extends M and A, the
//          multiplier bits are consumed out of `Q` from the bottom, and M
//          enters at the top and is shifted down 32 places.  So it is a
//          multiplier and an adder, not 32 adders.
//   `DIV`  `DIVIDE-FIRST-STEP` (51) then 31 `DIVIDE-STEP`s (41), non-
//          restoring: each adds or subtracts the A source as `Q<0>` (the
//          first step as if it were set) and `A<31>` choose, as page ALUC4
//          decides, then shifts the output bus left with `Q<31>` in at the
//          bottom and `Q` left with the complement of the array's bit 31 in
//          at the bottom.  The partial remainder is the output bus and the
//          quotient `Q`, with the first step's bit, the overflow, in
//          `Q<31>`.  It is 32 steps of logic here, as it is 32 in muir.
//
// Both ignore `IR<13:12>` and `IR<1:0>`, which `cadr_microcycle.sv` does
// where it uses these.
//
// **THE DIVIDER IS TWO STEPS A TICK**, so the words are there 17 ticks
// after `load`.  QUUX's definition gives the divide 330 ns, "a quotient bit
// each 10 ns for the 32 steps, and one 10 ns tick to load the result"
// (`muldiv::DIV_NS`), and the processor holds a `DIV` that long from the edge
// that loaded `IR`; the processor raises `load` seven ticks after that edge,
// when the scratchpad latches have closed and the M bus has settled
// (`cadr_machine.xdc`'s seven ticks out of the latches), so the words are
// there 24 ticks after it, well inside the hold.
//
// **WHY TWO: A `DIV` WHOSE M SOURCE IS `MD`, WITH A READ IN FLIGHT.**  QUUX
// has no hung microcycle (muir's `Geometry::hangs`): such a `DIV` waits,
// whole microcycles, until READ IN PROGRESS falls, and then runs once, so
// it divides the word the read brings, as muir's last read phase sees it.
// The word is in hand at `-LOADMD`, and the processor loads the divider
// again from it two ticks after (`div_word`); the microcycle that then runs
// ends no sooner than 290 ns after the strobe --- READ IN PROGRESS falls 140
// ns after it and the microcycle is 150 --- where a step a tick would need
// 330.  `build/quux_divmd.quux.pass` holds it: a `DIV` of `MD` at four
// distances from the read's start, with and without `ILONG`.
//
// What holds it: `build/muldiv.quux.pass` against `muldiv::run` itself over
// thousands of operands chosen at the edges of both representations and at
// random, each loaded and stepped as the processor does, and
// `build/quux_muldiv.quux.pass` against muir's QUUX running `MUL` and `DIV`
// in the processor, with the CADR's side of that program --- functions 42
// and 43 as the 74S181's --- in `build/quux_muldiv.pass`.

`default_nettype none

module quux_muldiv (
    input  var logic        clk,
    input  var logic        rst,
    // Take the operands and start the 32 steps.
    input  var logic        load,
    input  var logic [31:0] m,
    input  var logic [31:0] a,
    input  var logic [31:0] q,
    output var logic [31:0] mul_ob,
    output var logic [31:0] mul_q,
    output var logic [31:0] div_ob,
    output var logic [31:0] div_q
);

  // `MUL`: the product, as the 64-bit sum the 32 steps make.
  logic signed [63:0] product;
  assign product = 64'(signed'(m)) + signed'({{31{a[31]}}, a}) * signed'({32'd0, q});
  assign mul_ob  = product[63:32];
  assign mul_q   = product[31:0];

  // `DIV`: the steps, TWO a tick.  `sub` is page ALUC4's `ALUSUB`: the
  // first step subtracts when the divisor is positive, and each later one
  // when `Q<0>` and `A<31>` differ from each other --- `DIVSUB` with a
  // positive divisor or `DIVADD` with a negative one.  The array's bit 32 is
  // its sign, which a step does not read: its output bus is `ALU<30:0>` and
  // its quotient bit `ALU<31>`.  The second step of a tick is the first's
  // output taken straight on, never the first step of a divide.
  logic [31:0] dv_r, dv_q, dv_a;
  logic [5:0]  dv_k;
  logic        sub1, sub2;
  logic [32:0] f1, f2;
  logic [31:0] r1, q1;
  assign sub1 = (dv_k == 6'd0) ? !dv_a[31] : (dv_q[0] ^ dv_a[31]);
  assign f1   = sub1 ? ({dv_r[31], dv_r} - {dv_a[31], dv_a}) : ({dv_r[31], dv_r} + {dv_a[31], dv_a});
  assign r1   = {f1[30:0], dv_q[31]};
  assign q1   = {dv_q[30:0], !f1[31]};
  assign sub2 = q1[0] ^ dv_a[31];
  assign f2   = sub2 ? ({r1[31], r1} - {dv_a[31], dv_a}) : ({r1[31], r1} + {dv_a[31], dv_a});

  always_ff @(posedge clk) begin
    if (rst) begin
      dv_r <= 32'd0;
      dv_q <= 32'd0;
      dv_a <= 32'd0;
      dv_k <= 6'd32;
    end else if (load) begin
      dv_r <= m;
      dv_q <= q;
      dv_a <= a;
      dv_k <= 6'd0;
    end else if (dv_k != 6'd32) begin
      dv_r <= {f2[30:0], q1[31]};
      dv_q <= {q1[30:0], !f2[31]};
      dv_k <= dv_k + 6'd2;
    end
  end

  assign div_ob = dv_r;
  assign div_q  = dv_q;

  // The arrays' sign bits, which no step reads.
  logic unused_f;
  assign unused_f = f1[32] ^ f2[32];

endmodule

`default_nettype wire
