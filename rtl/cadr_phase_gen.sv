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
// Every instant the generator names is a multiple of five nanoseconds, so a
// 200 MHz master clock resolves all of them exactly and `phase` counts in
// five-nanosecond ticks.  The four read taps (75, 85, 100, 160 ns) and their
// ILONG variants (115, 125, 140) are 15, 17, 20, 32, 23, 25 and 28 ticks.
//
// MACHRUN is deliberately not a port.  `-CLK0` is `-TPCLK AND MACHRUN` at
// CLOCK2 1D10, which is on the board and not in the generator; `clock.rs`
// carries `machrun` in its `Inputs` and `advance` never reads it.
//
// KNOWN GAP, and it is in the reference rather than here: with `reset` held,
// muir's `apply_clock` keeps deriving `-TPR60` from `phase_ns`, which is
// `time - cycle_start` with `cycle_start` left where the last cycle put it.
// Held long enough that phase_ns sweeps 60..100, the reference emits a
// spurious `-TPR60`.  This module holds `phase` at zero under reset instead,
// so the two agree on every tick except that one, and the vector script
// asserts reset only before the first cycle.  See tb/cadr_phase_gen_tb.cpp.

`default_nettype none

module cadr_phase_gen (
    input  var logic       clk,        // 200 MHz, one tick = 5 ns
    input  var logic       rst,        // RESET, synchronous, active high
    input  var logic       hang,       // -HANG from VCTL1, true = stalling
    input  var logic       ilong,      // -ILONG from FLAG, true = stretch
    input  var logic [1:0] speed,      // {SSPEED1, SSPEED0}

    output var logic       tpclk,      // TPCLK          CLOCK2 1C07 pin 3
    output var logic       n_tpclk,    // -TPCLK         CLOCK2 1C06 pin 12
    output var logic       tptse,      // TPTSE          CLOCK2 1C06 pin 6
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
  logic [5:0] read_t;      // the chosen read phase, in ticks
  logic       running;     // a cycle has started; low while reset is held

  // The cycle is `read_t + RESTART_T` ticks long, phases 0 .. cycle_t-1.
  // `cycle_t` itself is the park value: where the generator sits when -HANG
  // holds the next -TPR0 off.  muir does the same thing by leaving CycleStart
  // pending and shifting it forward, which is why the write pulse still ends
  // (WpOff is ahead of CycleStart in the queue at the same nanosecond) but
  // TPCLK does not rise.
  logic [5:0] cycle_t;
  assign cycle_t = read_t + 6'(RESTART_T);

  logic       wrap;
  logic [5:0] phase_next;
  assign wrap       = (phase == cycle_t - 6'd1) || (phase == cycle_t);
  assign phase_next = wrap ? (hang ? cycle_t : 6'd0) : phase + 6'd1;

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
      read_t     <= 6'd17;   // Normal, no ILONG; replaced at the first SELECT
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
      if (phase_next == 6'(TSE_OFF_T)) tptse <= 1'b0;
      if (phase_next == 6'(TSE_ON_T)) tptse <= 1'b1;
      if (phase_next == 6'(SELECT_T)) read_t <= read_sel;

      if (phase_next == read_t) begin                           // ReadEnd
        tpclk      <= 1'b0;
        n_tpwpiram <= 1'b0;
      end
      if (phase_next == read_t + 6'(WP_ON_T)) n_tpwp <= 1'b0;
      if (phase_next == read_t + 6'(WPIRAM_OFF_T)) n_tpwpiram <= 1'b1;
    end
  end

  // -TPR60 is a window on the phase rather than a latch: chip.rs computes it
  // as `(60..60+TPR_PULSE_NS).contains(&phase_ns)` and puts it on the board.
  assign n_tpr60 = !(running && phase >= 6'(TPR60_ON_T) && phase < 6'(TPR60_OFF_T));

  assign n_tpclk = !tpclk;

endmodule

`default_nettype wire
