// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's clocks in the processor: the three interval timers of revision 10
// (contract Q11) and the microsecond clock of revision 5 (contract Q1).
// muir's `machine::Timers`, ported.
//
//     register page 110 + 2k  timer k's control and status: <0> on, <1> its
//                             flag (a write with it set clears it), <2> its
//                             mode (1 one-shot), taken only by a write that
//                             turns it on, <8> its interrupt enable, taken
//                             by every write
//     register page 111 + 2k  timer k's period in microseconds, <23:0>
//     register page 104 <0>   `RESET-DEVICES`: every timer to its reset state
//     source 15               the microseconds since power-on, 32 bits
//
// Every timer is reached through the register page alone.  Destinations 3
// and 4 write only M and source 17 reads all ones since revision 10, as on
// the CADR (`cadr_microcycle.sv`): Q1's tick control, interval timer and
// status are gone, and nothing of `OB` reaches the timers.
//
// A timer's flag rises a period after the write that starts it, then,
// periodic, every period after on the start's grid whether or not it was
// cleared between; one-shot, once, the
// count stopping at the rise (`live` down) until a period written while it
// is on or an off-then-on starts it again.  A write that turns it off, or a
// period written while it is on, takes its flag down.  A period of 0 never
// rises.  The flag rises whatever the interrupt enable says; under it, the
// flag is the timer's bit of word 100 (<0>, <1>, <2>) and a term of the
// interrupt that jump conditions 5 and 6 test.  `-RESET` --- the fabric's
// reset and every boot --- and `RESET-DEVICES` put every timer off, flag
// down, periodic, interrupt enable 0, period 0; the microsecond clock
// counts from power-on and nothing moves it.  None of this is the CADR's,
// and `cadr_microcycle.sv` builds this module on QUUX alone.
//
// **THE INSTANTS ARE muir'S** (contract Q11, rule 10).  A register page
// write is taken at the edge where the register decode takes its cycle and
// lands with that edge's time in the next microcycle; here the page takes
// it in the tick after that edge (`quux_feature_page.sv`'s `take`), so a
// period it starts runs from that edge.  `SINTR` is registered at the edge
// that ends each executed microcycle, waiting or not, with the flags as
// they stand at that edge (`Machine::interrupt_at(now)` at the end of
// `Rtl::clock_edge`): `irq`, from registers alone, nothing held off at any
// edge.  A page write is in no `SINTR` before the next edge, since it lands
// after the one that takes it (section 4 of the contract: nothing is held
// off for it, at K >= 4).  And a page read gives the timers as they stood
// at the edge that takes its cycle, a rise after that edge not in them:
// `rd_word` and `pending`.
//
// **A WRITE LANDS A TICK AFTER ITS EDGE**, from the page's registered
// `wdata`, so that nothing of the datapath reaches these every-tick
// registers in the tick it moves.  What a write depends on is taken at the
// edge itself --- whether each timer was on, whether its flag was up
// (`w_en`, `w_flag`) --- and the count it starts is one tick shorter, so
// the next rise is a period after the edge, muir's `now`.  A rise in the
// tick between is the period's own and stands.
//
// **A MICROSECOND PRESCALER AND A COUNT OF MICROSECONDS** for each timer, not
// a count of ticks: a period is whole microseconds of `TICKS_A_US` ticks each,
// so a write loads the count straight from the word written, with no
// multiply between a word and a register that runs every tick.  `pre` is the
// ticks left in the current microsecond, less one, and `us` the microseconds
// left, counted down to one; the flag rises in the tick both run out, and a
// periodic timer's both reload for the next period.
//
// What holds it, each against muir's QUUX at the pin: `build/quux_clocks.quux.k4.pass`,
// a program that reads every timer's two words through the page across
// rises, clears, periods written while running, each turned off, one-shot
// and periodic, the three at once, destination 3 writing only M and the
// shared edge;
// `build/quux_tickwin.quux.k4l1.pass`, the window between a rise and the
// edge `SINTR` is taken at, against a page write's edges;
// `build/quux_clockwait.quux.k4l1.pass`, the page's reads of word 100 and of
// a timer's word with the rise a tick either side of the edge that takes
// them; `build/quux_busreset.quux.k4.pass`, `RESET-DEVICES`; the CADR's side
// of `clocks`, sources 15 and 17 all ones and destinations 3 and 4 writing M
// alone; and the records aimed here in `mutations/list.txt`.

`default_nettype none

module quux_clocks (
    input  var logic        clk,
    input  var logic        rst,
    // `-BOOT`, active low: a boot is a `-RESET` and resets every timer.
    input  var logic        n_boot,

    // The master clock edge, and the edge that runs a microcycle.
    input  var logic        mclk_edge,
    input  var logic        cpu_edge,

    // The register page (`quux_feature_page.sv`): a write of word 110 + `pg_idx`
    // in the tick the page takes it, and its word; `RESET-DEVICES`, the
    // tick after the page takes a write of word 104 with <0> set.
    input  var logic        pg_we,
    input  var logic [2:0]  pg_idx,
    input  var logic [23:0] pg_wdata,
    input  var logic        devreset,
    // A read of word 110 + `pg_ridx`, as the timers stood at the last master
    // clock edge.
    input  var logic [2:0]  pg_ridx,
    output var logic [23:0] rd_word,
    // Word 100's three bits, as they stood at the last master clock edge:
    // [0] timer 0, [1] timer 1, [2] timer 2, each its flag under its
    // interrupt enable (`Timers::interrupt_sources`).
    output var logic [2:0]  pending,

    // Source 15, as the microcycle standing reads it.
    output var logic [31:0] usec_s,
    // The interrupt `SINTR` takes at this edge.
    output var logic        irq,

    // **THE READOUT'S VIEW, FOR A CHECKPOINT** (`cadr_microcycle.sv`'s
    // register table, entries 22 to 28; `docs/checkpoint.md`).  Raw
    // registers, each word taken in one tick, and each timer's count word
    // carrying the microsecond clock's low bits of the SAME tick: a timer's
    // next rise is `pre + (us - 1) * TICKS_A_US` ticks after the tick its
    // word was taken at, and the reader must know which tick that was, the
    // timers running while the machine is halted and the reader's accesses
    // being microseconds apart.  `build/quux_readout_window.quux.k4.pass`
    // holds every field.
    //   ro_time      <38:32> usec_t, <31:0> usec
    //   ro_count[k]  <47:41> usec<6:0>, <40:34> usec_t, <33> on, <32> sticky,
    //                <31> live, <30:24> pre, <23:0> us
    //   ro_conf[k]   <25> interrupt enable, <24> one-shot, <23:0> period
    output var logic [47:0] ro_time,
    output var logic [47:0] ro_count [0:2],
    output var logic [25:0] ro_conf [0:2]
);

  localparam int unsigned TICKS_A_US = 1000 / cadr_tick_pkg::TICK_NS;

  // ------------------------------------------------ the three timers

  logic [2:0]  en, sticky, live, one_shot, ie;
  logic [23:0] period [0:2];
  logic [23:0] us [0:2];
  logic [6:0]  pre [0:2];
  logic [2:0]  rise, flag;
  for (genvar k = 0; k < 3; k++) begin : g_rise
    assign rise[k] = en[k] && live[k] && (pre[k] == 7'd0) && (us[k] == 24'd1);
    assign flag[k] = en[k] && (sticky[k] || rise[k]);
  end

  // What the edge knows, for the tick after it: a microcycle ran, and each
  // timer's on and flag at the edge, which a page write taken there meets.
  logic       w;
  logic [2:0] w_en, w_flag;

  // **A PAGE WRITE, LANDING**: of timer k's control word, or of its period.
  logic [2:0] p_ctl, p_per;
  for (genvar k = 0; k < 3; k++) begin : g_page
    assign p_ctl[k] = pg_we && pg_idx == 3'(2 * k);
    assign p_per[k] = pg_we && pg_idx == 3'(2 * k + 1);
  end

  // Each timer's restart, clear and off this tick, from the page.  A
  // control word written with <0> turns the timer on if it was off at the
  // edge, and clears a flag up at the edge if <1> is set too; written
  // without <0>, it turns the timer off.  A period written while it is on
  // starts a period from the edge.
  logic [2:0] restart, clear, off;
  for (genvar k = 0; k < 3; k++) begin : g_land
    assign restart[k] = (p_ctl[k] && pg_wdata[0] && !w_en[k]) || (p_per[k] && w_en[k]);
    assign clear[k]   = p_ctl[k] && pg_wdata[0] && pg_wdata[1] && w_flag[k];
    assign off[k]     = p_ctl[k] && !pg_wdata[0];
  end

  // The period a restart counts: the one written, if this is the write of it.
  logic [23:0] start_us [0:2];
  for (genvar k = 0; k < 3; k++) begin : g_start
    assign start_us[k] = p_per[k] ? pg_wdata : period[k];
  end

  // ------------------------------------------------ the microsecond clock
  //
  // `Timers::microseconds`: `ns / 1000` of muir's time, whose t = 0 is the
  // composed machine's power-on, `cadr_tick_pkg::POWER_ON_EDGES` edges after
  // the reset edge, as `cadr_io_board.sv` counts its clocks from.
  logic [1:0]  power_on_t;
  logic [31:0] usec;
  logic [6:0]  usec_t;

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

  // The flags as they stood at the last master clock edge, for a page read
  // taken after it (`flag_e` below).
  logic [2:0] flag_s;

  always_ff @(posedge clk) begin
    if (rst || !n_boot) begin
      w      <= 1'b0;
      w_en   <= 3'b000;
      w_flag <= 3'b000;
      flag_s <= 3'b000;
    end else begin
      w      <= cpu_edge;
      w_en   <= en;
      w_flag <= flag;
      // At a held edge the flags of that tick, and at an edge that ran a
      // microcycle, in the tick after it, the flags at that edge.
      if (mclk_edge && !cpu_edge) flag_s <= flag;
      else if (w) flag_s <= w_flag;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || !n_boot || devreset) begin
      en       <= 3'b000;
      sticky   <= 3'b000;
      live     <= 3'b000;
      one_shot <= 3'b000;
      ie       <= 3'b000;
      for (int k = 0; k < 3; k++) begin
        period[k] <= 24'd0;
        us[k]     <= 24'd0;
        pre[k]    <= 7'd0;
      end
    end else begin
      for (int k = 0; k < 3; k++) begin
        if (p_per[k]) period[k] <= pg_wdata;
        // The mode, from the write that turns it on.  The interrupt enable,
        // from every write of the word.
        if (p_ctl[k]) begin
          ie[k] <= pg_wdata[8];
          if (restart[k]) one_shot[k] <= pg_wdata[2];
        end
        // A clear is of the flag as it stood at the edge, before a rise
        // this tick, which the count below then raises again.
        if (clear[k]) sticky[k] <= 1'b0;
        // The count runs on its own: a rise every period while on, or one
        // rise and a stop for a one-shot.
        if (en[k] && live[k]) begin
          if (pre[k] == 7'd0) begin
            pre[k] <= 7'(TICKS_A_US - 1);
            if (us[k] == 24'd1) begin
              sticky[k] <= 1'b1;
              if (one_shot[k]) live[k] <= 1'b0;
              else us[k] <= period[k];
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
    end
  end

  // **A PAGE READ SEES THE TIMERS AS THEY STOOD AT THE EDGE THAT TAKES ITS
  // CYCLE** (rule 10): in the tick after an edge that ran a microcycle, the
  // flags at that edge; after a held edge, or later, `flag_s`.  The page
  // takes a read in the tick after the edge, where a rise of that tick
  // already shows in `flag`, which is after the edge.  On, the mode and the
  // interrupt enable change only by a page write, which never lands in the
  // tick a read is taken, so they are read as they stand.
  logic [2:0] flag_e;
  assign flag_e     = w ? w_flag : flag_s;

  always_comb begin
    rd_word = 24'd0;
    unique case (pg_ridx)
      3'd0, 3'd2, 3'd4: begin
        rd_word[0] = en[pg_ridx[2:1]];
        rd_word[1] = flag_e[pg_ridx[2:1]];
        rd_word[2] = one_shot[pg_ridx[2:1]];
        rd_word[8] = ie[pg_ridx[2:1]];
      end
      3'd1, 3'd3, 3'd5: rd_word = period[pg_ridx[2:1]];
      default: rd_word = 24'd0;
    endcase
  end
  assign pending = flag_e & ie;

  assign ro_time = {9'd0, usec_t, usec};
  for (genvar k = 0; k < 3; k++) begin : g_ro
    assign ro_count[k] = {usec[6:0], usec_t, en[k], sticky[k], live[k], pre[k], us[k]};
    assign ro_conf[k]  = {ie[k], one_shot[k], period[k]};
  end

  // **`SINTR` AT THE EDGE THAT ENDS THE MICROCYCLE, WAITING OR NOT** (muir's
  // `ef015eb`, `Machine::interrupt_at(now)` at the end of `Rtl::clock_edge`):
  // each flag under its interrupt enable as it stands in the edge's own tick,
  // a rise on that tick counting as before the edge.  Nothing the
  // microcycle writes holds a term off: a page write taken at this edge
  // lands after it, in muir as here, and is in the next edge's `SINTR`, not
  // this one's, and destination 3 writes only M.
  assign irq = (flag[0] && ie[0])
            || (flag[1] && ie[1]) || (flag[2] && ie[2]);

endmodule

`default_nettype wire
