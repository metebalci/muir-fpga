// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The CADR clock generator, as a synchronous phase generator.
//
// This is `src/clock.rs` from muir, ported.  On the board the generator is
// four analog delay lines and three cross-coupled NAND pairs on pages CLOCK1
// and CLOCK2 --- the one part of the CADR that cannot be levelized.  muir
// models it behind a trait rather than as parts, and so does this: the delay
// line becomes a counter.
//
// Every instant the generator names is a multiple of five nanoseconds ON THE
// DRAWINGS, so `TICK_NS` below is 5 and every tap divides out exactly: the
// four read taps (75, 85, 100, 160 ns) and their ILONG variants (115, 125,
// 140) are 15, 17, 20, 32, 23, 25 and 28 ticks.  `phase` counts those ticks.
//
// **`TICK_NS` IS THE CONVERSION FROM MIT'S DRAWINGS AND NOT THE LENGTH OF A
// TICK.**  It is 5 for ever, because the drawings' grid is 5 ns and dividing
// by anything else rounds an instant --- at 10 the first tap collapses to
// zero ticks and SELECT lands on top of another tap.  How long a tick then
// LASTS is the board's business and nobody's here: `boards/arty-z7-20/cadr_arty.sv`
// makes it 6.25 ns, so this generator's cycle is 29 ticks of 6.25 rather
// than of 5 and every instant keeps its exact ratio to every other.  The
// machine cannot tell, and neither can any check --- they all compare tick
// counts.
//
// MACHRUN is deliberately not a port.  `-CLK0` is `-TPCLK AND MACHRUN` at
// CLOCK2 1D10, which is on the board and not in the generator; `clock.rs`
// carries `machrun` in its `Inputs` and `advance` never reads it.
//
// KNOWN GAP, and it is in the reference rather than here: with `reset` held,
// muir's `apply_clock` keeps deriving `-TPR60` from `phase_ns`, which is
// `time - cycle_start` with `cycle_start` left where the last cycle put it.
// Time runs on while reset is held, so `phase_ns` sweeps 60..100 and the
// reference emits a spurious `-TPR60` --- even from power-on, where it lands
// at ticks 11 to 18 of the trace.  This module holds `phase` at zero under
// reset instead, so a cleared ring produces no tap, and the testbench does
// not compare `-TPR60` while `RESET` is high.  See tb/cadr_phase_gen_tb.cpp.

`default_nettype none

module cadr_phase_gen (
    input  var logic       clk,        // 160 MHz, one tick = 6.25 ns
    input  var logic       rst,        // RESET, synchronous, active high
    input  var logic       hang,       // -HANG from VCTL1, true = stalling
    input  var logic       ilong,      // -ILONG from FLAG, true = stretch
    input  var logic [1:0] speed,      // {SSPEED1, SSPEED0}

    output var logic       tpclk,      // TPCLK          CLOCK2 1C07 pin 3
    output var logic       n_tpclk,    // -TPCLK         CLOCK2 1C06 pin 12
    output var logic       tptse,      // TPTSE          CLOCK2 1C06 pin 6
    // MAX_FANOUT, AND IT IS THE ONLY THING THIS FILE CAN DO ABOUT A PROBLEM
    // THAT LIVES DOWNSTREAM OF IT.  -TPWP leaves here on one flop and ends at
    // the dispatch memory's write enables --- 136 RAM256X1S primitives, whose
    // bank decode is two LUT levels past this register and inside
    // `cadr_microcycle.sv`.  Placed and routed on the board at 8a5d8dc the
    // arc `n_tpwp_reg/C -> dmem_reg_*/RAMS64E_*/WE` is 3 logic levels, 0.828
    // ns of logic and 3.132 ns of route.
    //
    // Three is not tuning.  Synthesis gives the net nine loads, so anything
    // from 9 upwards binds on nothing: 16 and 64 both leave one flop with a
    // fanout of nine and differ from no attribute at all only by two LUTs of
    // placement noise --- board WNS -0.133 either way against -0.384 with
    // none, and out of context -0.595 against -0.484, which is the same
    // no-op moving the number in the opposite direction.  A value that binds
    // replicates: 3 gives three flops of four, four and three loads, and
    // phys_opt then merges the bank decode into one LUT5, so the arc loses a
    // logic level as well.  Measured at 8a5d8dc, board flow, one sample each:
    //
    //     attribute   copies   this arc   WNS      failing   registers
    //     none        1        +0.136     -0.384   10        746
    //     16 or 64    1        -0.028     -0.133   29        746
    //     5           2        +0.503     -0.193   22        747
    //     3           3        +0.557     -0.054    1        748
    //     2           4        -0.002     -0.118   14        749
    //
    // Out of context the same three: -0.484 with none, -0.197 with this,
    // 94 failing endpoints against 48.  The WNS of neither flow is on this
    // arc --- it is `ir`/`answered_at` into the countdowns' resets, which is
    // the processor's business and not this file's --- so what is claimed
    // here is the arc, which is the column that moves with the mechanism.
    (* max_fanout = 3 *)
    output var logic       n_tpwp,     // write pulse    CLOCK2 1C06 pin 8
    output var logic       n_tpwpiram, // control store  CLOCK2 1C13 pin 8
    output var logic       n_tpr60     // -TPR60, SPEEDCLK's source
);

  // Speed, as clock.rs names it: SSPEED1,SSPEED0 = 00 ExtraSlow, 01 Slow,
  // 10 Normal, 11 Fast.
  localparam logic [1:0] SPEED_EXTRA_SLOW = 2'b00;
  localparam logic [1:0] SPEED_SLOW       = 2'b01;
  localparam logic [1:0] SPEED_NORMAL     = 2'b10;
  localparam logic [1:0] SPEED_FAST       = 2'b11;

  // The read phase in ticks, off the 74S151 at CLOCK1 1D08, which selects on
  // {SSPEED1, SSPEED0, -ILONG}.  ILONG adds forty nanoseconds --- eight ticks
  // --- except at extra slow, where 160 is already the longest tap the chain
  // provides.  `Speed::read_phase_ns` has the same table.
  //
  // FIVE, FOR EVER: this is MIT's grid and not the board's clock.  See the
  // header --- `cadr_arty.sv` makes a tick 6.25 ns and nothing below moves
  // for it, because what is written below is tick COUNTS.
  localparam int unsigned TICK_NS = 5;

  // The fixed instants, all measured from -TPR0 at phase zero.
  localparam int unsigned TSE_OFF_T  = 5 / TICK_NS;    //   5 ns
  localparam int unsigned TSE_ON_T   = 25 / TICK_NS;   //  25 ns
  localparam int unsigned TPR60_ON_T = 60 / TICK_NS;   //  60 ns
  localparam int unsigned SELECT_T   = 65 / TICK_NS;   //  65 ns
  localparam int unsigned TPR60_OFF_T = (60 + 40) / TICK_NS; // 100 ns

  // ...and the ones measured from the end of the read phase.
  localparam int unsigned WP_ON_T      = 30 / TICK_NS; // -TPW30
  localparam int unsigned WPIRAM_OFF_T = 45 / TICK_NS; // -TPW45
  // WP_OFF_NS is 70 on the board but the cycle restarts at -TPDONE = -TPW60,
  // so muir clamps the pulse to the boundary: `WP_OFF_NS.min(RESTART)`.  The
  // hardware's pulse outlives the boundary and propagation delay closes it
  // before the clock edge arrives; with no gate delays here, a pulse that
  // outlived it would write at the next instruction's address.  See the
  // WP_OFF_NS comment in clock.rs.
  localparam int unsigned RESTART_T = 60 / TICK_NS;    // -TPDONE, 60 ns

  logic [5:0] phase;       // ticks since -TPR0
  logic       running;     // a cycle has started; low while reset is held

  // THE TAPS ARE HELD AS INSTANTS, ONE TICK EARLY, AND COMPARED AGAINST THE
  // COUNTER ITSELF.  This is the only tick-rate logic in the design --- the
  // datapath has a whole microcycle and the scratchpads a whole phase --- so
  // it is the one place worth arranging for the tool.
  //
  // Written the obvious way, each tap is `phase_next == read_t + offset`, and
  // the path out of the counter is an increment, then an add, then a compare,
  // then the register: measured out of context at a 5 ns tick, that missed by
  // 0.244 ns with seven failing endpoints, three quarters of it routing.
  // Holding `read_t + offset - 1` in registers of their own leaves the
  // counter driving a comparator and nothing else.  The subtraction of one is
  // what removes the increment: `phase_next == X` is `phase == X-1` for every
  // tap inside the cycle, since `phase_next` is only not `phase + 1` at the
  // wrap, and no tap lands there.
  //
  // The instants change once a cycle, at SELECT, where the adds have a whole
  // tick and are off the counter's path entirely.
  logic [5:0] tpclk_off_at;    // -TPR<read>, ending the read phase
  logic [5:0] wp_on_at;        // -TPW30
  logic [5:0] wpiram_off_at;   // -TPW45
  logic [5:0] wrap_at;         // the last tick of the cycle
  logic [5:0] park_at;         // where -HANG holds the ring

  // The cycle is `read_t + RESTART_T` ticks long, phases 0 .. cycle_t-1.
  // `park_at` is that length: where the generator sits when -HANG holds the
  // next -TPR0 off.  muir does the same thing by leaving CycleStart pending
  // and shifting it forward, which is why the write pulse still ends (WpOff
  // is ahead of CycleStart in the queue at the same nanosecond) but TPCLK
  // does not rise.
  logic       wrap;
  logic [5:0] phase_next;
  assign wrap       = (phase == wrap_at) || (phase == park_at);
  assign phase_next = wrap ? (hang ? park_at : 6'd0) : phase + 6'd1;

  // The tap the 74S151 selects, read at SELECT_T.
  logic [5:0] read_sel;
  always_comb begin
    unique case (speed)
      SPEED_FAST:       read_sel = ilong ? 6'd23 : 6'd15;  // 115 : 75 ns
      SPEED_NORMAL:     read_sel = ilong ? 6'd25 : 6'd17;  // 125 : 85 ns
      SPEED_SLOW:       read_sel = ilong ? 6'd28 : 6'd20;  // 140 : 100 ns
      SPEED_EXTRA_SLOW: read_sel = 6'd32;                  // 160 ns, both
      default:          read_sel = 6'd17;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      // muir's reset clears every output and leaves one CycleStart pending,
      // so the generator is held at -TPR0 until reset lifts.
      running    <= 1'b0;
      phase      <= 6'd0;
      // Normal, no ILONG; replaced at the first SELECT.
      tpclk_off_at  <= 6'd17 - 6'd1;
      wp_on_at      <= 6'd17 + 6'(WP_ON_T) - 6'd1;
      wpiram_off_at <= 6'd17 + 6'(WPIRAM_OFF_T) - 6'd1;
      wrap_at       <= 6'd17 + 6'(RESTART_T) - 6'd1;
      park_at       <= 6'd17 + 6'(RESTART_T);
      tpclk      <= 1'b0;
      tptse      <= 1'b0;
      n_tpwp     <= 1'b1;
      n_tpwpiram <= 1'b1;
    end else if (!running) begin
      // Reset has lifted: CycleStart, at once.
      running <= 1'b1;
      phase   <= 6'd0;
      tpclk   <= 1'b1;
    end else begin
      phase <= phase_next;

      // The write pulse closes at the boundary whether or not -HANG lets the
      // next cycle start.
      if (wrap) n_tpwp <= 1'b1;

      if (phase_next == 6'd0) tpclk <= 1'b1;                    // CycleStart
      if (phase == 6'(TSE_OFF_T) - 6'd1) tptse <= 1'b0;
      if (phase == 6'(TSE_ON_T) - 6'd1) tptse <= 1'b1;
      if (phase == 6'(SELECT_T) - 6'd1) begin
        tpclk_off_at  <= read_sel - 6'd1;
        wp_on_at      <= read_sel + 6'(WP_ON_T) - 6'd1;
        wpiram_off_at <= read_sel + 6'(WPIRAM_OFF_T) - 6'd1;
        wrap_at       <= read_sel + 6'(RESTART_T) - 6'd1;
        park_at       <= read_sel + 6'(RESTART_T);
      end

      if (phase == tpclk_off_at) begin                          // ReadEnd
        tpclk      <= 1'b0;
        n_tpwpiram <= 1'b0;
      end
      if (phase == wp_on_at) n_tpwp <= 1'b0;
      if (phase == wpiram_off_at) n_tpwpiram <= 1'b1;
    end
  end

  // -TPR60 is a window on the phase rather than a latch: chip.rs computes it
  // as `(60..60+TPR_PULSE_NS).contains(&phase_ns)` and puts it on the board.
  assign n_tpr60 = !(running && phase >= 6'(TPR60_ON_T) && phase < 6'(TPR60_OFF_T));

  assign n_tpclk = !tpclk;

endmodule

`default_nettype wire
