// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's clocks in the processor (revision 5, contract Q1): the tick, fixed
// at 60 Hz; an interval timer; and the microsecond clock.  muir's
// `machine::Tick`, ported.
//
//     destination 3   control: <0> the tick's enable, and a write with <1>
//                     set clears its flag; <2> the interval timer's enable,
//                     and a write with <3> set clears its flag
//     destination 4   the interval timer's period in microseconds, <23:0>;
//                     a write starts a period from then; 0 stops it
//     source 17       <0> the tick's flag, <1> its enable, <2> the interval
//                     timer's flag, <3> its enable
//     source 15       the microseconds since power-on, 32 bits, wrapping
//
// A flag rises a period after its timer is enabled (the interval timer's
// also after its period is written), then every period after, whether or not
// it was cleared between; a clear takes it down until the next.  While
// enabled each flag is ORed into the interrupt that jump conditions 5 and 6
// test.  `-RESET` --- the fabric's reset and every boot --- turns both off and
// leaves the interval timer's period at 0; the microsecond clock counts from
// power-on and no boot moves it.  None of this is the CADR's, and
// `cadr_microcycle.sv` builds this module on QUUX alone.
//
// **THE INSTANTS ARE muir'S.**  A write lands at the edge that ends its
// microcycle, `Rtl::clock_edge`'s `now`, so a period starts from that edge
// and its flag rises exactly a period later.  Source 17 and source 15 are
// read at the instant their microcycle's read phase starts, the master clock
// edge it runs from (`Rtl::read_phase` at `self.ns`), with that edge's own
// write in it: `status` and `usec_s`.  And `SINTR` is registered at the edge
// that ends each executed microcycle, waiting or not, with the flags as they
// stand at that edge and that edge's own write in them
// (`Machine::interrupt_at(now)` at the end of `Rtl::clock_edge`): `irq`.
//
// **THE WRITE LANDS A TICK AFTER ITS EDGE, FROM `L`**, which is the word `OB`
// gave at that edge, so that nothing of the datapath reaches these
// every-tick registers in the tick it moves.  What the write depends on is
// taken at the edge itself --- which destination, whether each timer was on,
// whether its flag was up --- and the count it starts is one tick shorter, so
// the next rise is a period after the edge, muir's `now`.  A rise in the
// tick between is the period's own and stands.
//
// **A MICROSECOND PRESCALER AND A COUNT OF MICROSECONDS** for each timer, not
// a count of ticks: a period is whole microseconds of `TICKS_A_US` ticks each,
// so a write loads the count straight from the word written, with no
// multiply between `OB` and a register that runs every tick.  `pre` is the
// ticks left in the current microsecond, less one, and `us` the microseconds
// left, counted down to one; the flag rises in the tick both run out, and
// both reload for the next period.  An interval timer enabled at a period of
// 0 is enabled and never rises (`live` down), as muir's `Tick::after`.
//
// What holds it: `build/quux_clocks.quux.k4.pass` against muir's QUUX, a
// program that reads sources 15 and 17 across both timers' rises, clears,
// periods written while running and each turned off, and tests condition 5
// with the interrupt enabled; `build/quux_tickwin.quux.k4l1.pass`, the
// window between a rise and the edge `SINTR` is taken at, with rises
// strictly inside the microcycle and inside a wait for `MD`; and the CADR's
// side of the same programs, sources 15 and 17 all ones and destinations 3
// and 4 writing M alone.

`default_nettype none

module quux_clocks (
    input  var logic        clk,
    input  var logic        rst,
    // `-BOOT`, active low: a boot is a `-RESET` and turns both timers off.
    input  var logic        n_boot,

    // The master clock edge, and the edge that runs a microcycle.
    input  var logic        mclk_edge,
    input  var logic        cpu_edge,
    // The microcycle ending writes destination 3 or 4 (decoded, not yet
    // gated by the edge), and its `OB`: what the edge is about to land.
    input  var logic        dest_ctl,
    input  var logic        dest_per,
    input  var logic [3:0]  ob,
    // `L`, the word `OB` gave at the last edge, standing from the tick after it.
    input  var logic [23:0] l,

    // Source 17 and source 15, as the microcycle standing reads them.
    output var logic [3:0]  status,
    output var logic [31:0] usec_s,
    // The interrupt `SINTR` takes at this edge.
    output var logic        irq,
    // Each flag as it stands, under its enable: the register page's word
    // 100, `<0>` the tick and `<1>` the interval timer
    // (`Machine::interrupt_sources`).
    output var logic [1:0]  pending,

    // **THE READOUT'S VIEW, FOR A CHECKPOINT** (`cadr_microcycle.sv`'s
    // register table, entries 22 to 25; `docs/checkpoint.md`).  Raw
    // registers, each word taken in one tick, and each timer's word carrying
    // the microsecond clock's low bits of the SAME tick: a timer's next rise
    // is `pre + (us - 1) * TICKS_A_US` ticks after the tick its word was
    // taken at, and the reader must know which tick that was, the timers
    // running while the machine is halted and the reader's accesses being
    // microseconds apart.  `build/quux_readout_window.quux.k4.pass` holds every field.
    //   ro_time      <38:32> usec_t, <31:0> usec
    //   ro_timer[k]  <47:41> usec<6:0>, <40:34> usec_t, <33> en, <32> sticky,
    //                <31> live, <30:24> pre, <23:0> us
    //   ro_period    the interval timer's period in microseconds
    output var logic [47:0] ro_time,
    output var logic [47:0] ro_tick,
    output var logic [47:0] ro_interval,
    output var logic [23:0] ro_period
);

  localparam int unsigned TICKS_A_US = 1000 / cadr_tick_pkg::TICK_NS;
  // The tick's period, fixed: 16,667 us, 60 Hz (`Tick::PERIOD_US`).
  localparam logic [23:0] TICK_US = 24'd16667;

  // ------------------------------------------------ the two timers' counts

  // [0] the tick, [1] the interval timer.
  logic [1:0]  en, sticky, live;
  logic [23:0] us [0:1];
  logic [6:0]  pre [0:1];
  logic [23:0] interval_us;
  logic [1:0]  rise, flag;
  for (genvar k = 0; k < 2; k++) begin : g_rise
    assign rise[k] = en[k] && live[k] && (pre[k] == 7'd0) && (us[k] == 24'd1);
    assign flag[k] = en[k] && (sticky[k] || rise[k]);
  end

  // What the edge knows, for the tick after it.
  logic       w, w_ctl, w_per;
  logic [1:0] w_en, w_flag;

  // The write, landing: each timer's restart, clear and off.
  logic [1:0] restart, clear, off;
  assign restart[0] = w_ctl && l[0] && !w_en[0];
  assign clear[0]   = w_ctl && l[1] && w_flag[0];
  assign off[0]     = w_ctl && !l[0];
  assign restart[1] = (w_ctl && l[2] && !w_en[1]) || (w_per && w_en[1]);
  assign clear[1]   = w_ctl && l[3] && w_flag[1];
  assign off[1]     = w_ctl && !l[2];

  // The period a restart counts: the tick's own, or the interval timer's,
  // the word being written if this is the write of it.
  logic [23:0] start_us [0:1];
  assign start_us[0] = TICK_US;
  assign start_us[1] = w_per ? l[23:0] : interval_us;

  // ------------------------------------------------ the microsecond clock
  //
  // `Tick::microseconds`: `ns / 1000` of muir's time, whose t = 0 is the
  // composed machine's power-on, `cadr_tick_pkg::POWER_ON_EDGES` edges after
  // the reset edge, as `cadr_io_board.sv` counts its clocks from.
  logic [1:0]  power_on_t;
  logic [31:0] usec;
  logic [6:0]  usec_t;

  // The status as the standing microcycle reads it (`status`'s note above).
  logic [1:0] flag_s, en_s;

  always_ff @(posedge clk) begin
    if (rst) begin
      power_on_t <= 2'(cadr_tick_pkg::POWER_ON_EDGES);
      usec       <= 32'd0;
      usec_t     <= 7'(TICKS_A_US - 1);
      usec_s     <= 32'd0;
    end else begin
      if (power_on_t != 2'd0) begin
        power_on_t <= power_on_t - 2'd1;
      end else begin
        usec_t <= (usec_t == 7'd0) ? 7'(TICKS_A_US - 1) : usec_t - 7'd1;
        if (usec_t == 7'd0) usec <= usec + 32'd1;
      end
      // At the edge, with an increment that falls on it: a change on an edge
      // counts as before it, muir's rule.
      if (mclk_edge) usec_s <= usec + 32'(power_on_t == 2'd0 && usec_t == 7'd0);
    end
  end

  always_ff @(posedge clk) begin
    if (rst || !n_boot) begin
      en          <= 2'b00;
      sticky      <= 2'b00;
      live        <= 2'b00;
      interval_us <= 24'd0;
      us[0] <= 24'd0; us[1] <= 24'd0;
      pre[0] <= 7'd0; pre[1] <= 7'd0;
      flag_s      <= 2'b00;
      en_s        <= 2'b00;
      w           <= 1'b0;
      w_ctl       <= 1'b0;
      w_per       <= 1'b0;
      w_en        <= 2'b00;
      w_flag      <= 2'b00;
    end else begin
      w      <= cpu_edge;
      w_ctl  <= cpu_edge && dest_ctl;
      w_per  <= cpu_edge && dest_per;
      w_en   <= en;
      w_flag <= flag;

      if (w_per) interval_us <= l[23:0];

      for (int k = 0; k < 2; k++) begin
        // A clear is of the flag as it stood at the edge, before a rise
        // this tick, which the period below then raises again.
        if (clear[k]) sticky[k] <= 1'b0;
        // The period runs on its own: a rise every period while enabled.
        if (en[k] && live[k]) begin
          if (pre[k] == 7'd0) begin
            pre[k] <= 7'(TICKS_A_US - 1);
            if (us[k] == 24'd1) begin
              us[k]     <= (k == 0) ? TICK_US : interval_us;
              sticky[k] <= 1'b1;
            end else begin
              us[k] <= us[k] - 24'd1;
            end
          end else begin
            pre[k] <= pre[k] - 7'd1;
          end
        end
        if (restart[k]) begin
          en[k]     <= 1'b1;
          sticky[k] <= 1'b0;
          live[k]   <= start_us[k] != 24'd0;
          pre[k]    <= 7'(TICKS_A_US - 2);
          us[k]     <= start_us[k];
        end
        if (off[k]) begin
          en[k]     <= 1'b0;
          sticky[k] <= 1'b0;
          live[k]   <= 1'b0;
        end
      end

      // What the microcycle standing reads, as it stood at the master clock
      // edge the microcycle started on: at a held edge the flags of that
      // tick, and at an edge that ran a microcycle, the tick after it, with
      // that edge's write in it.
      if (mclk_edge && !cpu_edge) begin
        flag_s <= flag;
        en_s   <= en;
      end else if (w) begin
        for (int k = 0; k < 2; k++) begin
          flag_s[k] <= w_flag[k] && !(restart[k] || clear[k] || off[k]);
          en_s[k]   <= off[k] ? 1'b0 : (w_en[k] || restart[k]);
        end
      end
    end
  end

  // The period reloads from `interval_us` at a rise, which is the word last
  // written; a write of it restarts the count from the word itself.  A
  // period of 0 written while running stops the timer through `live`.

  assign status  = {en_s[1], flag_s[1], en_s[0], flag_s[0]};
  assign pending = flag;

  assign ro_time     = {9'd0, usec_t, usec};
  assign ro_tick     = {usec[6:0], usec_t, en[0], sticky[0], live[0], pre[0], us[0]};
  assign ro_interval = {usec[6:0], usec_t, en[1], sticky[1], live[1], pre[1], us[1]};
  assign ro_period   = interval_us;

  // **`SINTR` AT THE EDGE THAT ENDS THE MICROCYCLE, WAITING OR NOT** (muir's
  // `1775bba`, `Machine::interrupt_at(now)` at the end of `Rtl::clock_edge`):
  // the flags as they stand in the edge's own tick, a rise on that tick
  // counting as before the edge, less what this microcycle's own write takes
  // down there --- a timer turned off, a flag cleared, or the interval
  // timer's period written, which starts a period from the edge.  A timer
  // this write enables is off at the edge and so raises nothing.  It used to
  // be the flags the microcycle STARTED with, `flag_s`, which is where muir
  // took them before `1775bba`, and which missed a rise inside the
  // microcycle, or on the edge ending it, by one microcycle:
  // `build/quux_tickwin.quux.k4l1.pass` finds it on rows inside a plain
  // microcycle, on its ending edge, and inside a wait for `MD`.
  assign irq = (flag[0] && !(dest_ctl && (!ob[0] || ob[1])))
            || (flag[1] && !(dest_ctl && (!ob[2] || ob[3])) && !dest_per);

endmodule

`default_nettype wire
