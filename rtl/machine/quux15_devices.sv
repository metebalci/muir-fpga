// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S REGISTER-PAGE DEVICES AND ITS TIME** (contract G3
// revision 15, A15b.1, A15b.12; contracts Q9, Q11, Q13): the machine's time
// in units of 0.5 ns at the clock's period, the microsecond clock
// (functional source 15), the real-time clock (word 103), the three interval
// timers (words 110-115), the file device's registers (words 160-171,
// contract Q9: the host runs the commands), block-disk's registers (words
// 200-203), the
// interrupt status (word 100), RESET-DEVICES (word 104), the video
// controller's mode (word 210), and the interrupt
// the conditions 5 and 6 test.  muir's `Machine::bus_read`, `bus_write`,
// `Timers`, `BlockDisk` and `interrupt_at` are the reference, clock for
// clock through the core (`quux15_core.sv`) and its goldens.
//
// **THE TIME IS THE CLOCK'S INSTANT, k TIMES THE PERIOD, IN UNITS OF 0.5 ns**
// (muir's `Pipeline::instant`; A15b.12): nothing here holds it whole.
// Each thing that reads it keeps its own remainder against its own grid,
// stepped by the period each clock, so that an edge is acted on at the
// first clock at or after it and nothing drifts: the microsecond clock and
// the real-time clock as a count and its remainder, a timer as the units to
// its deadline.  The registers here, between two edges, are the machine as
// it stands at that clock's instant.
//
// **A REGISTER IS READ A CLOCK AFTER ITS GRANT, AT THAT CLOCK'S INSTANT**
// (muir reads it at `instant(grant + 1)`, the state as no write has changed
// it since: a register read waits while a register's write before it is
// still to be taken), and its word goes to `MD` the clock after (A15b.3):
// `rd_word` is the word of the address the core latched at the grant.  A
// write is taken at the clock the core's `register_write_now` takes it, at
// that clock's instant, before the word in EX runs: **`int_now` IS THE
// INTERRUPT AS THAT WRITE LEAVES IT**, which the conditions read in the same
// clock, from registers and the write's own bits, out of EX's loop.
//
// **TIMERS**: a timer's `rem` is its deadline less the clock's instant.  It
// counts down by the period; a deadline passed raises the flag (`up`), and a
// periodic timer's count wraps by its period, so that it holds the next
// boundary of the start's grid after the instant, which a clear of the flag
// takes as the new deadline (muir's `deadline + (now - deadline) / p * p +
// p`).  A period is at least 2,000 units and a clock at most 80, so one wrap
// a clock is enough.

`default_nettype none

module quux15_devices #(
    // Main memory's words: a ring must fit below them.
    parameter int unsigned MAIN_WORDS = 32'h0020_0000
) (
    input  var logic        clk,
    input  var logic        rst,
    // The console's -RESET: the interval timers as a power-on leaves them
    // (`Timers::new`), and nothing else.
    input  var logic        timers_rst,
    // The clock's period in units of 0.5 ns (word 25), and the real-time
    // clock's seconds at power-on, both the board's (the host's).
    input  var logic [6:0]  period,
    input  var logic [31:0] rtc_start,

    // A register read granted this clock, its word the next clock.
    input  var logic        rd_v,
    input  var logic [7:0]  rd_k,
    output var logic [31:0] rd_word,
    output var logic        rd_built,

    // A register write taken this clock.
    input  var logic        wr_v,
    input  var logic [7:0]  wr_k,
    input  var logic [31:0] wr_data,
    output var logic        wr_built,

    // CMD_PROD's write, taken this clock: once every write before it is
    // answered (the core holds it until the port is empty, A15b.5).
    input  var logic        prod_v,
    input  var logic [31:0] prod_data,

    // The file device's host (contract Q9): the doorbell, the producer
    // moved; and a command completed this clock, its response and buffer B
    // written into main memory, the handles then open.
    output var logic        fd_doorbell,
    output var logic [15:0] fd_prod,
    output var logic        fd_enabled,
    input  var logic        fd_done,
    input  var logic [7:0]  fd_handles,

    // Source 15, the microseconds since power-on, at this clock's instant.
    output var logic [31:0] microseconds,
    // The interrupt, as this clock's write leaves it (word 100 non-zero).
    output var logic        int_now,

    // The readout (A15b.13): a word of the devices' own state, `ro_k`
    // naming it, for the checkpoint a board takes halted; `snap` takes the
    // instant and the timers as they stand, which the readout's time words
    // read, so that a checkpoint names one instant however long it reads.
    input  var logic        snap,
    input  var logic [4:0]  ro_k,
    output var logic [63:0] ro_dev
);

  localparam logic [11:0] US_UNITS  = 12'd2000;
  localparam logic [31:0] SEC_UNITS = 32'd2_000_000_000;

  // ================================================================ the time

  logic [31:0] us_cnt, rtc_sec;
  logic [10:0] us_frac;
  logic [30:0] rtc_frac;
  // The instant itself, kept for the readout alone (muir's `Machine::ns`).
  logic [47:0] inst;
  always_ff @(posedge clk) begin
    if (rst) inst <= 48'(period);
    else inst <= inst + 48'(period);
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      // Clock 1's instant is one period.
      us_cnt   <= 32'd0;
      us_frac  <= 11'(period);
      rtc_sec  <= rtc_start;
      rtc_frac <= 31'(period);
    end else begin
      if ({1'b0, us_frac} + 12'(period) >= US_UNITS) begin
        us_frac <= 11'({1'b0, us_frac} + 12'(period) - US_UNITS);
        us_cnt  <= us_cnt + 32'd1;
      end else begin
        us_frac <= us_frac + 11'(period);
      end
      if ({1'b0, rtc_frac} + 32'(period) >= SEC_UNITS) begin
        rtc_frac <= 31'({1'b0, rtc_frac} + 32'(period) - SEC_UNITS);
        rtc_sec  <= rtc_sec + 32'd1;
      end else begin
        rtc_frac <= rtc_frac + 31'(period);
      end
    end
  end
  assign microseconds = us_cnt;

  // ============================================================== the timers

  typedef struct packed {
    logic        on;
    logic        one_shot;
    logic        ie;
    logic [23:0] period_us;
    logic        armed;        // a deadline: not `u64::MAX`
    logic        up;           // the deadline passed: the flag
    logic signed [37:0] rem;   // the deadline (or the next grid point) less now
  } timer_t;

  timer_t tm [3];

  // A period in units: `period_us` x 2,000.
  function automatic logic signed [37:0] units_of(input logic [23:0] us);
    return 38'(({14'd0, us} << 11) - ({14'd0, us} << 5) - ({14'd0, us} << 4));
  endfunction

  // A write of a timer's control or period word at this clock's instant
  // (`write_control`, `write_period`).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic timer_t timer_write(input timer_t t, input logic period_word, input logic [31:0] v);
    timer_t r;
    r = t;
    if (period_word) begin
      r.period_us = v[23:0];
      if (r.on) begin
        r.armed = v[23:0] != 24'd0;
        r.up    = 1'b0;
        r.rem   = units_of(v[23:0]);
      end
    end else begin
      if (v[0] && !t.on) begin
        r.one_shot = v[2];
        r.armed    = t.period_us != 24'd0;
        r.up       = 1'b0;
        r.rem      = units_of(t.period_us);
      end else if (v[1] && t.armed && t.up) begin
        if (t.one_shot || t.period_us == 24'd0) begin
          r.armed = 1'b0;
          r.up    = 1'b0;
        end else begin
          // The next boundary of the start's grid after now, which the
          // count holds while the flag is up.
          r.up = 1'b0;
        end
      end
      if (!v[0]) begin
        r.armed = 1'b0;
        r.up    = 1'b0;
      end
      r.on = v[0];
      r.ie = v[8];
    end
    return r;
  endfunction

  // A clock passes: the count steps, a deadline passed raises the flag, and
  // a periodic timer's count wraps onto its grid.
  function automatic timer_t timer_tick(input timer_t t, input logic [6:0] p);
    timer_t r;
    logic signed [37:0] n;
    r = t;
    if (!t.armed) return r;
    n = t.rem - 38'(p);
    if (n <= 0) begin
      r.up = 1'b1;
      if (!t.one_shot) n = n + units_of(t.period_us);
    end
    // A one-shot that has risen counts nothing more: its deadline stays.
    if (!(t.one_shot && t.up)) r.rem = n;
    return r;
  endfunction

  // ============================================================== block-disk

  // Its registers (muir's `BlockDisk`), without a pack: a START moves
  // nothing and leaves it not active; another command stops by error.
  logic [31:0] bd_cmd;
  logic [27:0] bd_clp, bd_da, bd_lma;
  logic        bd_bad, bd_past_end, bd_nxm;
  logic signed [47:0] bd_rem;     // DONE less now: not active once <= 0
  logic        bd_active;
  // For the readout: the instant block-disk was last told the clock (an
  // access of its words), and DONE, as muir's `BlockDisk` keeps them; and the
  // instant of the last RESET-DEVICES, which muir's video controller keeps
  // (`Tv::xbus_init`'s `written_at`).
  logic [47:0] bd_now, bd_done, tv_at;

  // ============================================================ the display

  // The video controller's mode, word 210: black-on-white, `<2>`, and
  // nothing else (muir's `Tv::write_control` on `Board::Video`); no reset
  // clears it.
  logic bow;
  initial bow = 1'b0;

  // ============================================================== the writes

  timer_t      tm_w [3];
  logic        wr_timer, wr_reset, wr_bd;
  logic [1:0]  wr_tk;
  always_comb begin
    wr_timer = wr_v && wr_k >= 8'o110 && wr_k <= 8'o115;
    wr_tk    = 2'((wr_k - 8'o110) >> 1);
    wr_reset = wr_v && wr_k == 8'o104 && wr_data[0];
    wr_bd    = wr_v && wr_k >= 8'o200 && wr_k <= 8'o203;
    for (int k = 0; k < 3; k++) begin
      tm_w[k] = tm[k];
      if (wr_reset) tm_w[k] = '0;
      if (wr_timer && wr_tk == 2'(k)) tm_w[k] = timer_write(tm[k], wr_k[0], wr_data);
    end
    wr_built = !wr_v || wr_k == 8'o104 || wr_timer || wr_bd || wr_k == 8'o100 || wr_k == 8'o103
            || wr_k == 8'o210 || (wr_k >= 8'o160 && wr_k <= 8'o171);
  end

  // Block-disk's state as this clock's write leaves it.
  logic [31:0] bd_cmd_w;
  logic        bd_bad_w, bd_past_end_w, bd_nxm_w, bd_idle_w;
  always_comb begin
    bd_cmd_w      = bd_cmd;
    bd_bad_w      = bd_bad;
    bd_past_end_w = bd_past_end;
    bd_nxm_w      = bd_nxm;
    bd_idle_w     = !bd_active;
    if (wr_bd && wr_k[1:0] == 2'd0) begin
      bd_cmd_w = wr_data;
      bd_bad_w = 1'b0; bd_past_end_w = 1'b0; bd_nxm_w = 1'b0;
    end
    if (wr_bd && wr_k[1:0] == 2'd3) begin
      bd_past_end_w = 1'b0; bd_nxm_w = 1'b0;
      bd_bad_w = !(bd_cmd[3:0] == 4'o00 || bd_cmd[3:0] == 4'o11);
    end
    if (wr_reset) begin
      bd_cmd_w = '0;
      bd_bad_w = 1'b0; bd_past_end_w = 1'b0; bd_nxm_w = 1'b0;
      bd_idle_w = 1'b1;
    end
  end

  // ========================================================= the file device

  // Its registers (muir's `FileDevice`, words 160-171): enabled, the
  // interrupt enable, the two faults, the rings' bases and log2 sizes, the
  // command producer and consumer (the response producer is the consumer:
  // one response a command, in order) and the response consumer; the
  // handles open, the host's.
  logic        fd_on, fd_ie, fd_refused, fd_fault;
  logic [27:0] fd_cbase, fd_rbase;
  logic [3:0]  fd_clog, fd_rlog;
  logic [15:0] fd_cprod, fd_ccons, fd_rcons;
  logic [7:0]  fd_hopen;

  // A ring fits: on a line, at most 2^8 entries, below main memory's end.
  function automatic logic fits(input logic [27:0] base, input logic [3:0] log2);
    return base[2:0] == 3'd0 && log2 <= 4'd8
        && 32'(base) + (32'd8 << log2) <= 32'(MAIN_WORDS);
  endfunction

  // The file device as this clock's CMD_PROD and register write leave it.
  logic        fd_on_w, fd_ie_w, fd_refused_w, fd_fault_w;
  logic [27:0] fd_cbase_w, fd_rbase_w;
  logic [3:0]  fd_clog_w, fd_rlog_w;
  logic [15:0] fd_cprod_w, fd_ccons_w, fd_rcons_w;
  always_comb begin
    fd_on_w = fd_on; fd_ie_w = fd_ie; fd_refused_w = fd_refused; fd_fault_w = fd_fault;
    fd_cbase_w = fd_cbase; fd_rbase_w = fd_rbase; fd_clog_w = fd_clog; fd_rlog_w = fd_rlog;
    fd_cprod_w = fd_cprod; fd_ccons_w = fd_ccons; fd_rcons_w = fd_rcons;
    // The host's completion, in this clock's `advance_devices`.
    if (fd_done && fd_on) fd_ccons_w = fd_ccons + 16'd1;
    // CMD_PROD, from `port_events`.
    if (prod_v && fd_on_w) begin
      if (prod_data[15:0] - fd_ccons_w > (16'd1 << fd_clog_w)
          || prod_data[15:0] - fd_ccons_w < fd_cprod_w - fd_ccons_w)
        fd_fault_w = 1'b1;
      else
        fd_cprod_w = prod_data[15:0];
    end
    // The register write, in EX's `register_write_now`.
    if (wr_v && wr_k == 8'o160) begin
      fd_refused_w = 1'b0;
      fd_fault_w   = 1'b0;
      if (!fd_on_w && wr_data[0]) begin
        if (fits(fd_cbase_w, fd_clog_w) && fits(fd_rbase_w, fd_rlog_w)) begin
          fd_on_w = 1'b1; fd_ie_w = wr_data[8];
          fd_cprod_w = '0; fd_ccons_w = '0; fd_rcons_w = '0;
        end else begin
          fd_refused_w = 1'b1;
        end
      end else if (fd_on_w && !wr_data[0]) begin
        fd_on_w = 1'b0; fd_ie_w = 1'b0;
        fd_cprod_w = '0; fd_ccons_w = '0; fd_rcons_w = '0;
      end else if (fd_on_w) begin
        fd_ie_w = wr_data[8];
      end
    end
    if (wr_v && !fd_on_w) begin
      if (wr_k == 8'o162) fd_cbase_w = wr_data[27:0];
      if (wr_k == 8'o163) fd_clog_w  = wr_data[3:0];
      if (wr_k == 8'o166) fd_rbase_w = wr_data[27:0];
      if (wr_k == 8'o167) fd_rlog_w  = wr_data[3:0];
    end
    if (wr_v && fd_on_w && wr_k == 8'o171) begin
      if (wr_data[15:0] - fd_rcons_w > fd_ccons_w - fd_rcons_w) fd_fault_w = 1'b1;
      else fd_rcons_w = wr_data[15:0];
    end
    // RESET-DEVICES: disabled, the faults cleared; the rings stay.
    if (wr_reset) begin
      fd_on_w = 1'b0; fd_ie_w = 1'b0; fd_refused_w = 1'b0; fd_fault_w = 1'b0;
      fd_cprod_w = '0; fd_ccons_w = '0; fd_rcons_w = '0;
    end
  end
  assign fd_doorbell = fd_on_w && fd_cprod_w != fd_cprod;
  assign fd_prod     = fd_cprod_w;
  assign fd_enabled  = fd_on_w;

  // ================================================================ word 100

  function automatic logic [31:0] sources(input timer_t t0, input timer_t t1, input timer_t t2,
                                          input logic [31:0] cmd, input logic idle, input logic fd);
    return {24'd0, fd, 3'd0, idle && cmd[11], t2.ie && t2.up, t1.ie && t1.up, t0.ie && t0.up};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  assign int_now = sources(tm_w[0], tm_w[1], tm_w[2], bd_cmd_w, bd_idle_w,
                           fd_ie_w && fd_ccons_w != fd_rcons_w) != 32'd0;

  // ================================================================ the read

  logic       rq_v;
  logic [7:0] rq_k;
  always_comb begin
    rd_built = 1'b1;
    rd_word  = 32'd0;
    unique case (rq_k)
      8'o100: rd_word = sources(tm[0], tm[1], tm[2], bd_cmd, !bd_active, fd_ie && fd_ccons != fd_rcons);
      8'o160: rd_word = {23'd0, fd_ie, 7'd0, fd_on};
      8'o161: rd_word = {8'd0, fd_hopen, 7'd0, fd_ccons != fd_rcons, 4'd0, fd_fault, fd_refused, !fd_on, fd_on};
      8'o162: rd_word = {4'd0, fd_cbase};
      8'o163: rd_word = {28'd0, fd_clog};
      8'o164: rd_word = fd_on ? {16'd0, fd_cprod} : 32'd0;
      8'o165, 8'o170: rd_word = fd_on ? {16'd0, fd_ccons} : 32'd0;
      8'o166: rd_word = {4'd0, fd_rbase};
      8'o167: rd_word = {28'd0, fd_rlog};
      8'o171: rd_word = fd_on ? {16'd0, fd_rcons} : 32'd0;
      8'o103: rd_word = rtc_sec;
      8'o104: rd_word = 32'd0;
      8'o110: rd_word = {23'd0, tm[0].ie, 5'd0, tm[0].one_shot, tm[0].up, tm[0].on};
      8'o112: rd_word = {23'd0, tm[1].ie, 5'd0, tm[1].one_shot, tm[1].up, tm[1].on};
      8'o114: rd_word = {23'd0, tm[2].ie, 5'd0, tm[2].one_shot, tm[2].up, tm[2].on};
      8'o111: rd_word = {8'd0, tm[0].period_us};
      8'o113: rd_word = {8'd0, tm[1].period_us};
      8'o115: rd_word = {8'd0, tm[2].period_us};
      8'o200: rd_word = {11'd0, bd_nxm, 2'd0, bd_past_end, 3'd0, bd_bad || bd_past_end || bd_nxm,
                         3'd0, 1'b1, 5'd0, !bd_active && bd_cmd[11], 2'd0, !bd_active};
      8'o201: rd_word = {4'd0, bd_lma};
      8'o202: rd_word = {4'd0, bd_da};
      8'o203: rd_word = 32'd0;
      8'o210: rd_word = {29'd0, bow, 2'd0};
      default: rd_built = 1'b0;
    endcase
    if (!rq_v) rd_built = 1'b1;
  end

  // ================================================================ the edge

  always_ff @(posedge clk) begin
    rq_v <= rd_v;
    rq_k <= rd_k;
    if (rst) begin
      for (int k = 0; k < 3; k++) tm[k] <= '0;
      bd_cmd <= '0; bd_clp <= '0; bd_da <= '0; bd_lma <= '0;
      bd_bad <= 1'b0; bd_past_end <= 1'b0; bd_nxm <= 1'b0;
      bd_rem <= '0; bd_active <= 1'b0;
      bd_now <= '0; bd_done <= '0; tv_at <= '0;
      fd_on <= 1'b0; fd_ie <= 1'b0; fd_refused <= 1'b0; fd_fault <= 1'b0;
      fd_cbase <= '0; fd_rbase <= '0; fd_clog <= '0; fd_rlog <= '0;
      fd_cprod <= '0; fd_ccons <= '0; fd_rcons <= '0; fd_hopen <= '0;
    end else begin
      fd_on <= fd_on_w; fd_ie <= fd_ie_w; fd_refused <= fd_refused_w; fd_fault <= fd_fault_w;
      fd_cbase <= fd_cbase_w; fd_rbase <= fd_rbase_w; fd_clog <= fd_clog_w; fd_rlog <= fd_rlog_w;
      fd_cprod <= fd_cprod_w; fd_ccons <= fd_ccons_w; fd_rcons <= fd_rcons_w;
      if (fd_done) fd_hopen <= fd_handles;
      for (int k = 0; k < 3; k++) tm[k] <= timer_tick(tm_w[k], period);
      bd_cmd <= bd_cmd_w;
      bd_bad <= bd_bad_w; bd_past_end <= bd_past_end_w; bd_nxm <= bd_nxm_w;
      if (wr_v && wr_k == 8'o210) bow <= wr_data[2];
      if (wr_bd && wr_k[1:0] == 2'd1) bd_clp <= wr_data[27:0];
      if (wr_bd && wr_k[1:0] == 2'd2) bd_da <= wr_data[27:0];
      if (wr_reset) bd_active <= 1'b0;
      // muir's `advance` before an access, and RESET-DEVICES's DONE at the
      // clock last told.
      if (wr_bd || (rq_v && rq_k[7:2] == 6'o40)) bd_now <= inst;
      if (wr_reset) bd_done <= bd_now;
      if (wr_reset) tv_at <= inst;
      // DONE counted down by the period: no pack, nothing to count.
      if (bd_active) begin
        bd_rem <= bd_rem - 48'(period);
        if (bd_rem - 48'(period) <= 0) bd_active <= 1'b0;
      end
      if (timers_rst)
        for (int k = 0; k < 3; k++) tm[k] <= '0;
    end
  end

  // ============================================================= the readout

  // **A TIMER'S DEADLINE AS muir KEEPS IT**: `rem` holds it less the
  // instant until the flag rises; then a periodic timer's count runs on to
  // the next boundary of its grid and a one-shot's stops, and muir's
  // deadline stays where the flag rose until a clear moves it.  So the
  // instant of each rise is kept here, for the readout alone.
  logic [47:0] tm_rise [3];
  always_ff @(posedge clk) begin
    for (int k = 0; k < 3; k++)
      if (!rst && tm_w[k].armed && !tm_w[k].up && $signed(tm_w[k].rem - 38'(period)) <= 0)
        tm_rise[k] <= inst + 48'($signed(tm_w[k].rem));
  end

  // **THE SNAPSHOT**: the instant and each timer's words and deadline, as
  // `snap` finds them; `u64::MAX` is no deadline.
  logic [47:0] snap_inst;
  logic [31:0] snap_ctl [3];
  logic [63:0] snap_dl [3];
  always_ff @(posedge clk) begin
    if (snap) begin
      snap_inst <= inst;
      for (int k = 0; k < 3; k++) begin
        snap_ctl[k] <= {tm[k].period_us, 3'd0, tm[k].up, tm[k].armed, tm[k].ie, tm[k].one_shot, tm[k].on};
        snap_dl[k]  <= !tm[k].armed ? 64'hFFFF_FFFF_FFFF_FFFF
                     : tm[k].up ? {16'd0, tm_rise[k]}
                     : {16'd0, inst + 48'($signed(tm[k].rem))};
      end
    end
  end

  // **THE DEVICES' STATE FOR A CHECKPOINT**: what muir's `Timers`,
  // `FileDevice`, `BlockDisk` and the machine's clock save, as the
  // registers here hold it; the time words the snapshot's.
  //
  //   0-2   timer k: <0> on, <1> one-shot, <2> interrupt enable, <3> a
  //         deadline, <4> the flag; <31:8> the period in us
  //   3-5   timer k's deadline, in units of 0.5 ns; all ones for none
  //   6     the file device: <0> enabled, <1> interrupt enable, <2> refused,
  //         <3> the index fault; <15:8> the handles open
  //   7, 8  the command ring's base, the response ring's
  //   9     <3:0> the command ring's log2 size, <7:4> the response ring's
  //   10    <15:0> the command producer, <31:16> its consumer, <47:32> the
  //         response consumer
  //   11-14 block-disk's command, command list, disk address and LMA
  //   15    block-disk: <0> a bad command, <1> past the end, <2> NXM,
  //         <3> active
  //   16    DONE, and 17 the instant block-disk was last told
  //   18    word 210's black-on-white
  //   19    the instant, muir's `Machine::ns`
  //   20    the real-time clock's seconds; 21 the microseconds
  //   22    the instant of the last RESET-DEVICES
  always_comb begin
    ro_dev = 64'd0;
    unique case (ro_k)
      5'd0:  ro_dev = {32'd0, snap_ctl[0]};
      5'd1:  ro_dev = {32'd0, snap_ctl[1]};
      5'd2:  ro_dev = {32'd0, snap_ctl[2]};
      5'd3:  ro_dev = snap_dl[0];
      5'd4:  ro_dev = snap_dl[1];
      5'd5:  ro_dev = snap_dl[2];
      5'd6:  ro_dev = {48'd0, fd_hopen, 4'd0, fd_fault, fd_refused, fd_ie, fd_on};
      5'd7:  ro_dev = {36'd0, fd_cbase};
      5'd8:  ro_dev = {36'd0, fd_rbase};
      5'd9:  ro_dev = {56'd0, fd_rlog, fd_clog};
      5'd10: ro_dev = {16'd0, fd_rcons, fd_ccons, fd_cprod};
      5'd11: ro_dev = {32'd0, bd_cmd};
      5'd12: ro_dev = {36'd0, bd_clp};
      5'd13: ro_dev = {36'd0, bd_da};
      5'd14: ro_dev = {36'd0, bd_lma};
      5'd15: ro_dev = {60'd0, bd_active, bd_nxm, bd_past_end, bd_bad};
      5'd16: ro_dev = {16'd0, bd_done};
      5'd17: ro_dev = {16'd0, bd_now};
      5'd18: ro_dev = {63'd0, bow};
      5'd19: ro_dev = {16'd0, snap_inst};
      5'd20: ro_dev = {32'd0, rtc_sec};
      5'd21: ro_dev = {32'd0, us_cnt};
      5'd22: ro_dev = {16'd0, tv_at};
      default: ro_dev = 64'd0;
    endcase
  end

  logic unused;
  assign unused = ^{wr_k[7:3], prod_data[31:16]};

endmodule

`default_nettype wire
