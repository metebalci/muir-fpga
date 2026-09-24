// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's clock generator: a microcycle of SYNC_K ticks, and SYNC_K + SYNC_L
// for an `ILONG` instruction (H1a, muir's `TimingModel::Sync`).
//
// The CADR's generator, `cadr_phase_gen.sv`, is the delay line ported: a
// read phase ended by one of seven taps, a write pulse, a control-store
// pulse, `TPTSE`, `-TPR60` and a ring `-HANG` parks.  QUUX has none of
// that.  Its microcycle is one register edge every K ticks, every write
// lands on that edge, and a microcycle that waits (for the bus, for MD or
// for the divider) waits whole K-tick cycles with the master clock running,
// so nothing parks the generator.  What is left is a counter.
//
// **THE SAME PORTS AS THE CADR'S**, so `cadr_microcycle.sv` names either
// the same way and the testbench drives both.  `hang` and `speed` are read
// by nothing: QUUX has no hung microcycle and one rate.  `TPTSE` and
// `-TPR60` stand at their idle values, and `penult` and `last`, which place
// the CADR's writes in a hung microcycle, stay low.  The two write pulses
// are one tick each and say where the writes land; see there.
//
// **TPCLK IS UP FOR ONE TICK, THE BOUNDARY'S.**  `cadr_microcycle.sv` takes
// the boundary as TPCLK's rise, and the processor's registers move on the
// edge that ends that tick.  Out of reset the first rise comes on the first
// tick, as the CADR's does, so `cadr_tick_pkg::POWER_ON_EDGES` holds for
// both.
//
// **WHERE `ILONG` IS READ.**  `-ILONG` is `IR<45>`, and IR moves on the edge
// that ends the boundary tick, so the instruction a microcycle runs is in IR
// from the tick after its rise to the end of the microcycle, and `ilong` is
// read at the microcycle's last tick, where it is that instruction's.  muir
// takes `r.ilong` from the read phase of the cycle, which is the same IR.
//
// What holds it: `build/phase_gen.quux.k4l1.pass`, the generator alone
// against `golden/src/phase_gen.rs --machine quux`, microcycles of K and K +
// L both, and every QUUX machine trace, each of whose microcycles has its
// length compared.

`default_nettype none

module quux_phase_gen #(
    parameter int unsigned SYNC_K = 4,
    parameter int unsigned SYNC_L = 0
) (
    input  var logic       clk,
    input  var logic       rst,
    input  var logic       hang,
    input  var logic       ilong,
    input  var logic [1:0] speed,

    output var logic       tpclk,
    output var logic       n_tpclk,
    output var logic       tptse,
    output var logic       n_tpwp,
    output var logic       n_tpwpiram,
    output var logic       n_tpr60,
    output var logic       penult,
    output var logic       last
);

  // **K IS FOUR AT THE LEAST.**  Not for this counter's sake, which would
  // count two: a `DIV` of MD needs its word in the divider seventeen ticks
  // before the edge that ends the microcycle it runs, which READ IN
  // PROGRESS lets start 14 ticks after the strobe, and the word is in a
  // register the divider can be loaded from one tick after the strobe
  // (`cadr_microcycle.sv`, "A `DIV` OF `MD`").  So 14 + K >= 18.  At a K of
  // three the word would have to go into the divider straight off the bus
  // on the strobe's own tick, and the bus's cone is two ticks deep.
  if (SYNC_K < 4 || SYNC_K + SYNC_L > 63) begin : g_bad_k
    $error("quux_phase_gen: SYNC_K is %0d and SYNC_L %0d; QUUX's microcycle is 4 to 63 ticks",
           SYNC_K, SYNC_L);
  end

  logic [5:0] phase;       // ticks since the rise
  logic       running;
  logic       wrap;
  logic [5:0] phase_next;
  logic       last_next;
  // The microcycle's last tick: K - 1, or K + L - 1 under ILONG.
  assign wrap = (phase == 6'(SYNC_K - 1) && !(ilong && SYNC_L != 0))
             || (phase == 6'(SYNC_K + SYNC_L - 1) && ilong);

  always_ff @(posedge clk) begin
    if (rst) begin
      running <= 1'b0;
      phase   <= 6'd0;
      tpclk   <= 1'b0;
    end else if (!running) begin
      running <= 1'b1;
      phase   <= 6'd0;
      tpclk   <= 1'b1;
    end else begin
      phase <= phase_next;
      tpclk <= wrap;
    end
  end

  // **THE WRITE PULSE IS THE MICROCYCLE'S LAST TICK, AND IT ENDS ON THE
  // BOUNDARY'S EDGE**, which is where `cadr_microcycle.sv` takes every write
  // (`wp`, as the pulse ends, gated by MACHRUN).  So QUUX's writes land on
  // the edge that ends the microcycle, as muir's `sync` lands them, with the
  // processor's writes taken exactly as the CADR's are.  The control store's
  // pulse is the boundary's tick itself: `iwe` takes its leading edge, so
  // the store is written on that same edge.
  //
  // A register, as the CADR's is, and so a compare of the NEXT phase: the
  // pulse is low over the tick whose phase is the microcycle's last.  The
  // `ILONG` it reads is IR's as it stands, which is the next tick's too
  // except on the boundary's own tick, where IR is about to move; the next
  // tick is then phase 1, which is the last only at a K of two, which is
  // refused above.
  assign phase_next = wrap ? 6'd0 : phase + 6'd1;
  assign last_next  = (phase_next == 6'(SYNC_K - 1) && !(ilong && SYNC_L != 0))
                   || (phase_next == 6'(SYNC_K + SYNC_L - 1) && ilong);
  always_ff @(posedge clk) begin
    if (rst || !running) n_tpwp <= 1'b1;
    else                 n_tpwp <= !last_next;
  end
  assign n_tpwpiram = !tpclk;
  assign n_tpclk    = !tpclk;
  assign tptse      = 1'b0;
  assign n_tpr60    = 1'b1;
  assign penult     = 1'b0;
  assign last       = 1'b0;

  logic unused;
  assign unused = &{1'b0, hang, speed};

endmodule

`default_nettype wire
