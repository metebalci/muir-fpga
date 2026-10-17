// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S REGISTER-PAGE DEVICES AND ITS TIME** (contract G3
// revision 15, A15b.1, A15b.12; contracts Q9, Q11, Q13): the machine's time
// in units of 0.5 ns at the clock's period, the microsecond clock
// (functional source 15), the real-time clock (word 103), the three interval
// timers (words 110-115), the keyboard and the mouse (words 120-123,
// `quux15_input.sv`), the Chaosnet interface (words 140-147,
// `quux15_chaos.sv`), the file device's registers (words 160-171,
// contract Q9: the host runs the commands) and the host's side of it and of
// the real-time clock, block-disk's registers (words 200-203), the
// interrupt status (word 100), RESET-DEVICES (word 104), the video
// controller's mode (word 210), and the interrupt
// the conditions 5 and 6 test; and on revision 16 the Ethernet device
// (words 240-257, `quux16_ethernet.sv`, `ETHERNET`).  muir's
// `Machine::bus_read`, `bus_write`, `Timers`, `QuuxInput`, the Chaosnet's
// `Interface`, `BlockDisk`, `EthernetDevice` and `interrupt_at` are the
// reference, clock for clock through the core (`quux15_core.sv`) and its
// goldens.
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
    parameter int unsigned MAIN_WORDS = 32'h0020_0000,
    // A block's time in units of 0.5 ns: muir's `block_disk::BLOCK_NS`,
    // 100 us.
    parameter int unsigned BLOCK_UNITS = 200_000,
    // Revision 16's Ethernet device, words 240-257 and word 100's <8>
    // (`quux16_ethernet.sv`); none below it, the words not decoded here.
    parameter bit ETHERNET = 1'b0
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
    // The core's release of the register read before (`quux15_core.sv`'s
    // `n_rgr_rel`): an interrupt level the read lowered counts from the
    // next clock (the register read ruling).
    input  var logic        rd_release,

    // A register write taken this clock.
    input  var logic        wr_v,
    input  var logic [7:0]  wr_k,
    input  var logic [31:0] wr_data,
    output var logic        wr_built,

    // A held write taken this clock: once every write before it is answered
    // (the core holds it until the port is empty, A15b.5), CMD_PROD's, or
    // on revision 16 the Ethernet device's 244 or 250 (`prod_k`, the word).
    input  var logic        prod_v,
    input  var logic [7:0]  prod_k,
    input  var logic [31:0] prod_data,

    // The file device's host (contract Q9): the doorbell, the producer
    // moved; the host's side by index, `quux_fd_face.sv`'s map, one write
    // and one read a clock (THE HOST'S SIDE, below); and a completion the
    // host made landing this clock, its response and buffer B already in
    // main memory, which drops the cache (the port's sweep).
    output var logic        fd_doorbell,
    output var logic [15:0] fd_prod,
    output var logic        fd_enabled,
    input  var logic        host_we,
    input  var logic [3:0]  host_widx,
    input  var logic [31:0] host_wdata,
    input  var logic [3:0]  host_ridx,
    output var logic [31:0] host_rdata,
    output var logic        fd_complete,

    // The Ethernet device's host (`quux16_ethernet.sv`, revision 16): its
    // side by index, `quux_ed_face.sv`'s map, one write and one read a
    // clock; 244 and 250 as this clock leaves them; and an RX_CONS move
    // landing this clock, which makes the cache coherent (the port's sweep).
    input  var logic        eth_we,
    input  var logic [4:0]  eth_widx,
    input  var logic [31:0] eth_wdata,
    input  var logic [4:0]  eth_ridx,
    output var logic [31:0] eth_rdata,
    output var logic [15:0] eth_tx_prod,
    output var logic [15:0] eth_rx_prod,
    output var logic        eth_sweep,

    // Block-disk's pack and its walk (`quux15_block_walk.sv`): a pack on
    // unit 0; START taken for a walk, with the registers it reads; the walk
    // running, a block it moved, its end and what it leaves; and its words
    // still on the port, for the readout.
    input  var logic        bd_present,
    output var logic        bd_start,
    output var logic [31:0] bd_st_cmd,
    output var logic [27:0] bd_st_clp,
    output var logic [27:0] bd_st_da,
    input  var logic        bd_walking,
    input  var logic        bd_charge,
    input  var logic        bd_fin,
    input  var logic [27:0] bd_fin_lma,
    input  var logic [28:0] bd_fin_da,
    input  var logic        bd_fin_past_end,
    input  var logic        bd_fin_nxm,
    input  var logic        bd_flight,

    // The keyboard and the mouse (`quux15_input.sv`): the keyboard's cable,
    // the mouse's seven lines, the boot word's request and the host's
    // handshake.
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    input  var logic [6:0]  mouse_lines,
    output var logic        kbd_boot,
    output var logic        kbd_busy,

    // The Chaosnet interface's cable (`quux15_chaos.sv`): the seam of
    // `cadr_io_board.sv`'s interface, which `cadr_chaos_cable.sv` takes.
    input  var logic [15:0] chaos_address,
    output var logic        chaos_tx_go,
    output var logic [8:0]  chaos_tx_len,
    output var logic        chaos_tx_valid,
    output var logic [15:0] chaos_tx_word,
    output var logic        chaos_tx_clear,
    output var logic        chaos_reset,
    output var logic [15:0] chaos_csr,
    input  var logic        chaos_rx_valid,
    input  var logic [15:0] chaos_rx_word,
    input  var logic        chaos_rx_done,
    input  var logic [12:0] chaos_rx_bits,
    input  var logic        chaos_rx_crc,
    input  var logic        chaos_rx_lost,
    input  var logic        chaos_tx_done,
    input  var logic        chaos_tx_abort,
    input  var logic        chaos_cbl_busy,
    input  var logic        chaos_rx_start,
    input  var logic [11:0] chaos_rx_stored,
    input  var logic        chaos_rx_store,
    output var logic [11:0] chaos_bits,

    // Source 15, the microseconds since power-on, at this clock's instant.
    output var logic [31:0] microseconds,
    // The interrupt, as this clock's write leaves it (word 100 non-zero).
    output var logic        int_now,

    // The readout (A15b.13): a word of the devices' own state, `ro_k`
    // naming it, for the checkpoint a board takes halted; `snap` takes the
    // instant and the timers as they stand, which the readout's time words
    // read, so that a checkpoint names one instant however long it reads.
    input  var logic        snap,
    input  var logic [6:0]  ro_k,
    output var logic [63:0] ro_dev,

    // The video controller's mode, word 210's black-on-white, out to the
    // board's display output (`cadr_display_out.sv`'s `bow`).
    output var logic        bow
);

  localparam logic [11:0] US_UNITS  = 12'd2000;
  localparam logic [31:0] SEC_UNITS = 32'd2_000_000_000;

  // The host's side, by index (`quux_fd_face.sv`: 0x010 is 0, 0x014 is 1,
  // 0x100 + 4k is k + 2).
  localparam logic [3:0] H_RTC_SECONDS  = 4'd0;
  localparam logic [3:0] H_RTC_FRACTION = 4'd1;
  localparam logic [3:0] H_STATE        = 4'd2;
  localparam logic [3:0] H_CLAIM        = 4'd3;
  localparam logic [3:0] H_CMD_BASE     = 4'd4;
  localparam logic [3:0] H_CMD_LOG2     = 4'd5;
  localparam logic [3:0] H_RESP_BASE    = 4'd6;
  localparam logic [3:0] H_RESP_LOG2    = 4'd7;
  localparam logic [3:0] H_CMD_PROD     = 4'd8;
  localparam logic [3:0] H_RESP_PROD    = 4'd9;
  localparam logic [3:0] H_RESP_CONS    = 4'd10;
  localparam logic [3:0] H_HANDLES      = 4'd11;
  localparam logic [3:0] H_MEM_WORDS    = 4'd12;

  // ================================================================ the time

  logic [31:0] us_cnt, rtc_sec;
  logic [10:0] us_frac;
  logic [30:0] rtc_frac;
  // **THE REAL-TIME CLOCK IS THE HOST'S** (`quux_rtc.sv`'s rule): the host
  // writes the seconds, and the fraction they start at, through the host's
  // side, at boot and at every second after.  A machine reset starts it at
  // `rtc_start`, muir's `--rtc`, only until the host first sets it; after
  // that no reset reaches it, as a real clock keeps real time whatever
  // happens to the processor, and a band booting after a reset never reads
  // a clock just put back.  The stage is a fraction in nanoseconds for the
  // next seconds written; a fraction of a second or more is ignored.  Both
  // from the fabric's configuration, which no reset reaches.
  logic [29:0] rtc_stage = 30'd0;
  logic        rtc_host  = 1'b0;
  logic        h_rtc_sec;
  assign h_rtc_sec = host_we && host_widx == H_RTC_SECONDS;
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
    end else begin
      if ({1'b0, us_frac} + 12'(period) >= US_UNITS) begin
        us_frac <= 11'({1'b0, us_frac} + 12'(period) - US_UNITS);
        us_cnt  <= us_cnt + 32'd1;
      end else begin
        us_frac <= us_frac + 11'(period);
      end
    end
    // The real-time clock: set by the host, at the edge its write lands
    // on; started at a reset until then; else counted, held at 2^32 - 1
    // (muir's `Rtc::seconds` saturates).
    if (h_rtc_sec) begin
      rtc_sec  <= host_wdata;
      rtc_frac <= {rtc_stage, 1'b0};
    end else if (rst && !rtc_host) begin
      rtc_sec  <= rtc_start;
      rtc_frac <= 31'(period);
    end else if ({1'b0, rtc_frac} + 32'(period) >= SEC_UNITS) begin
      rtc_frac <= 31'({1'b0, rtc_frac} + 32'(period) - SEC_UNITS);
      if (rtc_sec != 32'hFFFF_FFFF) rtc_sec <= rtc_sec + 32'd1;
    end else begin
      rtc_frac <= rtc_frac + 31'(period);
    end
  end
  always_ff @(posedge clk) begin
    if (h_rtc_sec) begin
      rtc_stage <= 30'd0;
      rtc_host  <= 1'b1;
    end else if (host_we && host_widx == H_RTC_FRACTION && host_wdata < 32'd1_000_000_000) begin
      rtc_stage <= host_wdata[29:0];
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

  // Its registers (muir's `BlockDisk`).  A START of a read (0) or a write
  // (11) with a pack on unit 0 starts the walk (`quux15_block_walk.sv`);
  // without one it moves nothing and leaves it as it was; another command
  // stops by error.
  //
  // **DONE IS muir'S, ROUNDED ONCE**: START's instant plus `BLOCK_UNITS` a
  // block moved, the walk's `charge`s added to `bd_rem`, DONE less the
  // instant, as they come, so that not-active is seen at the first clock at
  // or after DONE whatever the period (200,000 / P is not whole at P = 17 or
  // 36).  **AND NOT BEFORE THE WALK'S END**: muir moves the words at START,
  // the walk over the blocks' time, so block-disk is active until the later
  // of the two (`quux_block_disk.sv`'s rule, revision 13's).  The disk
  // address, the last memory address and the errors stand from the walk's
  // end, as on revision 13: a register read before not-active reads them
  // as they were, where muir has them at START.
  //
  // **RESET-DEVICES** clears the command and the errors and leaves
  // block-disk not active at once, as muir's `xbus_init`; a walk runs on to
  // its end (muir's pages all moved at START), its disk address and last
  // memory address taken there, its errors and its time not.  A START while
  // a walk still runs after a RESET-DEVICES moves nothing, where muir would
  // run it: a departure no program makes.
  logic [31:0] bd_cmd;
  logic [27:0] bd_clp, bd_lma;
  logic [28:0] bd_da;
  logic        bd_bad, bd_past_end, bd_nxm;
  logic signed [47:0] bd_rem;     // DONE less now
  logic        bd_rem_pos;        // DONE still to come
  logic        bd_on;             // a transfer's DONE is owed
  logic        bd_own;            // the walk's errors are the registers' at its end
  logic        bd_da_own;         // and its disk address
  logic        bd_active;
  assign bd_active = bd_on && (bd_walking || bd_rem_pos);
  // For the readout: the instant block-disk was last told the clock (an
  // access of its words), and DONE, as muir's `BlockDisk` keeps them; and the
  // instant of the last RESET-DEVICES, which muir's video controller keeps
  // (`Tv::xbus_init`'s `written_at`).
  logic [47:0] bd_now, bd_done, tv_at;

  // ============================================================ the display

  // The video controller's mode, word 210: black-on-white, `<2>`, and
  // nothing else (muir's `Tv::write_control` on `Board::Video`); no reset
  // clears it.  It leaves on `bow` for the board's display output.
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
            || wr_k == 8'o210 || (wr_k >= 8'o160 && wr_k <= 8'o171) || (wr_k >= 8'o120 && wr_k <= 8'o123)
            || (wr_k >= 8'o140 && wr_k <= 8'o147) || (ETHERNET && wr_k >= 8'o240 && wr_k <= 8'o257);
  end

  // Block-disk's state as this clock's walk's end and write leave it.
  logic [31:0] bd_cmd_w;
  logic        bd_bad_w, bd_past_end_w, bd_nxm_w, bd_idle_w, bd_go;
  always_comb begin
    bd_cmd_w      = bd_cmd;
    bd_bad_w      = bd_bad;
    bd_past_end_w = bd_past_end;
    bd_nxm_w      = bd_nxm;
    bd_idle_w     = !bd_active;
    if (bd_fin && bd_own) begin
      bd_past_end_w = bd_fin_past_end;
      bd_nxm_w      = bd_fin_nxm;
    end
    if (wr_bd && wr_k[1:0] == 2'd0) begin
      bd_cmd_w = wr_data;
      bd_bad_w = 1'b0; bd_past_end_w = 1'b0; bd_nxm_w = 1'b0;
    end
    if (wr_bd && wr_k[1:0] == 2'd3) begin
      bd_past_end_w = 1'b0; bd_nxm_w = 1'b0;
      bd_bad_w = !(bd_cmd[3:0] == 4'o00 || bd_cmd[3:0] == 4'o11);
    end
    // START of a transfer: the walk, idle, and a pack.
    bd_go = wr_bd && wr_k[1:0] == 2'd3 && (bd_cmd[3:0] == 4'o00 || bd_cmd[3:0] == 4'o11)
         && bd_present && !bd_walking;
    if (bd_go) bd_idle_w = 1'b0;
    if (wr_reset) begin
      bd_cmd_w = '0;
      bd_bad_w = 1'b0; bd_past_end_w = 1'b0; bd_nxm_w = 1'b0;
      bd_idle_w = 1'b1;
    end
  end
  assign bd_start  = bd_go;
  assign bd_st_cmd = bd_cmd;
  assign bd_st_clp = bd_clp;
  assign bd_st_da  = bd_da[27:0];

  // DONE less the next clock's instant: START's at zero, a block moved owed.
  logic signed [47:0] bd_rem_n;
  always_comb begin
    bd_rem_n = (bd_go ? 48'sd0 : bd_rem) + ((bd_charge && bd_on && !bd_go) ? 48'(BLOCK_UNITS) : 48'sd0)
             - 48'(period);
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

  // **THE HOST'S SIDE** (contract Q9; `quux_file_device.sv`'s, revision
  // 14's, whose header has it for the server's author, and `docs/
  // file-device.md`).  Registers by index, `quux_fd_face.sv` multiplying by
  // four:
  //
  //     0, 1 the real-time clock's seconds and fraction (above)
  //     2    STATE, read: <0> enabled, <1> the interrupt enable, <2> busy,
  //          <3> quiet, <4> work waiting, <5> the last completion refused,
  //          <31:16> EPOCH, one more at every disable
  //     3    CLAIM: written {EPOCH, <0> 1} sets busy if enabled in that
  //          epoch; written <0> 0 clears it in any; read <0> busy
  //     4-7  the command ring's base and size, the response ring's
  //     8    the command producer: 164 as the core gave it, once every write
  //          before it was answered (A15b.5), so the host reads no entry
  //          still in the posted writes
  //     9    RESP_PROD: read 165 = 170; written {EPOCH, <15:0> index}
  //          completes the commands up to the index
  //     10   171
  //     11   HANDLES: written {EPOCH, <7:0> count}, the handles open once
  //          the next completion lands; read, the count the machine sees
  //     12   MAIN_WORDS: main memory's words
  //
  // **QUIET IS "NOT ENABLED AND NOT BUSY"**: busy is the host's claim, held
  // while it copies into main memory for a command, so a disable while it
  // copies does not read quiet, and the machine does not reuse a ring the
  // host is still writing.  **A WRITE CARRYING AN EPOCH NOT THE CURRENT ONE
  // IS IGNORED**, so a command the host was running when the machine
  // disabled the device never publishes, and its handle count never lands
  // in the new epoch.  Busy and the epoch outlast every reset (from the
  // fabric's configuration, 0): the host may be copying across one, and a
  // reset that put the epoch back would let a completion from before it
  // land after it.
  //
  // **A COMPLETION IS ACCEPTED** when the device is enabled, the EPOCH is
  // the current one, it moves 170 forward by one to the commands shown, and
  // it leaves the response ring no fuller than its size; otherwise nothing
  // changes and STATE's <5> goes up until the next accepted completion or
  // CLAIM.  **IT LANDS THE CLOCK AFTER ITS WRITE** (`fd_complete`, from a
  // register), as one host completion is one of muir's: 165 and 170 move,
  // the handles staged land with them, word 100's <7> rises as that clock's
  // register write leaves it, and the cache is swept, at that clock, so a
  // completion written at clock k - 1 is muir's completion at clock k.  A
  // disable in the clock between drops it.  **WITH NO CLAIM HELD THE
  // MACHINE'S WORDS READ AS muir'S**, which has no host: quiet is then
  // "not enabled".
  logic        fd_busy  = 1'b0;
  logic [15:0] fd_epoch = 16'd0;
  logic        fd_crefused;           // STATE <5>
  logic [7:0]  fd_hnext;              // HANDLES, staged
  logic        fd_pub;                // a completion accepted: it lands now
  logic [15:0] fd_pub_to;
  assign fd_complete = fd_pub && fd_on;

  // The host sees a completion it wrote at once.
  logic [15:0] fd_chost, fd_cstep, fd_croom;
  logic        fd_in_epoch, fd_ok, h_complete, h_claim, fd_work;
  assign fd_chost    = fd_complete ? fd_pub_to : fd_ccons;
  assign fd_in_epoch = fd_on && host_wdata[31:16] == fd_epoch;
  assign fd_cstep    = host_wdata[15:0] - fd_chost;
  assign fd_croom    = host_wdata[15:0] - fd_rcons;
  assign fd_ok       = fd_in_epoch && fd_cstep != 16'd0 && fd_cstep <= fd_cprod - fd_chost
                    && fd_croom <= 16'd1 << fd_rlog;
  assign h_complete  = host_we && host_widx == H_RESP_PROD;
  assign h_claim     = host_we && host_widx == H_CLAIM;
  assign fd_work     = fd_on && fd_cprod != fd_chost && fd_chost - fd_rcons < 16'd1 << fd_rlog;

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
    if (fd_complete) fd_ccons_w = fd_pub_to;
    // CMD_PROD, from `port_events`.
    if (prod_v && prod_k == 8'o164 && fd_on_w) begin
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

  // ================================================== the keyboard and the mouse

  // Words 120-123 (`quux15_input.sv`): a read granted this clock, its word
  // the clock after; a write taken this clock.
  logic [31:0] in_word;
  logic [1:0]  in_irq, in_irq_state, in_irq_g;
  logic [47:0] in_ro_state;
  logic [23:0] in_ro_fifo;
  logic        in_rd_mine, in_wr_mine;
  assign in_rd_mine = rd_v && rd_k >= 8'o120 && rd_k <= 8'o123;
  assign in_wr_mine = wr_v && wr_k >= 8'o120 && wr_k <= 8'o123;
  quux15_input input_regs (
      .clk(clk), .rst(rst),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code), .mouse_lines(mouse_lines),
      .rd(in_rd_mine), .rd_k(rd_k), .rd_release(rd_release), .wr(in_wr_mine), .wr_k(wr_k), .wdata(wr_data),
      .rd_word(in_word),
      .irq(in_irq), .irq_state(in_irq_state), .boot(kbd_boot), .busy(kbd_busy),
      .ro_state(in_ro_state), .ro_fifo_a(ro_k[5:0]), .ro_fifo_q(in_ro_fifo));
  // Word 100's <4> and <5> as the read's grant found them.
  always_ff @(posedge clk) in_irq_g <= in_irq_state;

  // The read granted last clock, at the clock after its grant.
  logic       rq_v;
  logic [7:0] rq_k;

  // ================================================== the Chaosnet interface

  // Words 140-147 (`quux15_chaos.sv`): a read at the clock after its grant
  // (`rq_v`, `rq_k`), its word and its effect there; a write taken this
  // clock; RESET-DEVICES resets it.
  logic [15:0] ch_word;
  logic        ch_irq, ch_irq_state;
  quux15_chaos chaos_regs (
      .clk(clk), .rst(rst), .dev_reset(wr_reset),
      .rd(rq_v && rq_k[7:3] == 5'o14), .rd_k(rq_k[2:0]),
      .wr(wr_v && wr_k[7:3] == 5'o14), .wr_k(wr_k[2:0]), .wdata(wr_data[15:0]),
      .rd_word(ch_word), .irq(ch_irq), .irq_state(ch_irq_state),
      .chaos_address(chaos_address), .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word),
      .chaos_tx_clear(chaos_tx_clear), .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(chaos_rx_valid), .chaos_rx_word(chaos_rx_word), .chaos_rx_done(chaos_rx_done),
      .chaos_rx_bits(chaos_rx_bits), .chaos_rx_crc(chaos_rx_crc), .chaos_rx_lost(chaos_rx_lost),
      .chaos_tx_done(chaos_tx_done), .chaos_tx_abort(chaos_tx_abort),
      .chaos_cbl_busy(chaos_cbl_busy), .chaos_rx_start(chaos_rx_start),
      .chaos_rx_stored(chaos_rx_stored), .chaos_rx_store(chaos_rx_store), .chaos_bits(chaos_bits));

  // =================================================== the Ethernet device

  // Words 240-257 (`quux16_ethernet.sv`, revision 16): a read at the clock
  // after its grant (`rq_v`, `rq_k`); a write taken this clock; 244 and 250
  // as the core holds them; RESET-DEVICES disables it.  Below revision 16
  // nothing decodes them and every output is 0.
  logic [31:0] ed_word;
  logic [63:0] ed_ro;
  logic        ed_irq, ed_irq_state;
  if (ETHERNET) begin : g_ethernet
    quux16_ethernet #(.MAIN_WORDS(MAIN_WORDS)) eth_regs (
        .clk(clk), .rst(rst), .dev_reset(wr_reset),
        .rd(rq_v && rq_k[7:4] == 4'o12), .rd_k(rq_k[3:0]), .rd_word(ed_word),
        .wr(wr_v && wr_k[7:4] == 4'o12), .wr_k(wr_k[3:0]), .wdata(wr_data),
        .held(prod_v && (prod_k == 8'o244 || prod_k == 8'o250)), .held_rx(prod_k == 8'o250),
        .held_data(prod_data[15:0]),
        .irq(ed_irq), .irq_state(ed_irq_state),
        .tx_prod_now(eth_tx_prod), .rx_prod_now(eth_rx_prod), .sweep(eth_sweep),
        .host_we(eth_we), .host_widx(eth_widx), .host_wdata(eth_wdata),
        .host_ridx(eth_ridx), .host_rdata(eth_rdata),
        .ro_k(ro_k[2:0]), .ro_word(ed_ro));
  end else begin : g_no_ethernet
    assign ed_ro = 64'd0;
    assign ed_word = 32'd0;
    assign ed_irq = 1'b0;
    assign ed_irq_state = 1'b0;
    assign eth_tx_prod = 16'd0;
    assign eth_rx_prod = 16'd0;
    assign eth_sweep = 1'b0;
    assign eth_rdata = 32'd0;
    logic eth_unused;
    assign eth_unused = ^{eth_we, eth_widx, eth_wdata, eth_ridx};
  end

  // ================================================================ word 100

  function automatic logic [31:0] sources(input timer_t t0, input timer_t t1, input timer_t t2,
                                          input logic [31:0] cmd, input logic idle, input logic fd);
    return {24'd0, fd, 3'd0, idle && cmd[11], t2.ie && t2.up, t1.ie && t1.up, t0.ie && t0.up};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  // And the keyboard's and the mouse's, `<4>` and `<5>` (`quux15_input.sv`),
  // the network's, `<6>` (`quux15_chaos.sv`), and on revision 16 the
  // Ethernet device's, `<8>` (`quux16_ethernet.sv`).
  assign int_now = sources(tm_w[0], tm_w[1], tm_w[2], bd_cmd_w, bd_idle_w,
                           fd_ie_w && fd_ccons_w != fd_rcons_w) != 32'd0 || in_irq != 2'd0 || ch_irq
                || ed_irq;

  // ================================================================ the read

  always_comb begin
    rd_built = 1'b1;
    rd_word  = 32'd0;
    unique case (rq_k)
      8'o100: rd_word = sources(tm[0], tm[1], tm[2], bd_cmd, !bd_active, fd_ie && fd_ccons != fd_rcons);
      8'o120, 8'o121, 8'o122, 8'o123: rd_word = in_word;
      8'o140, 8'o141, 8'o142, 8'o143, 8'o144, 8'o145, 8'o146, 8'o147: rd_word = {16'd0, ch_word};
      8'o160: rd_word = {23'd0, fd_ie, 7'd0, fd_on};
      8'o161: rd_word = {8'd0, fd_hopen, 7'd0, fd_ccons != fd_rcons, 4'd0, fd_fault, fd_refused,
                         !fd_on && !fd_busy, fd_on};
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
                         3'd0, !bd_present, 5'd0, !bd_active && bd_cmd[11], 2'd0, !bd_active};
      8'o201: rd_word = {4'd0, bd_lma};
      8'o202: rd_word = {3'd0, bd_da};
      8'o203: rd_word = 32'd0;
      8'o210: rd_word = {29'd0, bow, 2'd0};
      8'o240, 8'o241, 8'o242, 8'o243, 8'o244, 8'o245, 8'o246, 8'o247,
      8'o250, 8'o251, 8'o252, 8'o253, 8'o254, 8'o255, 8'o256, 8'o257: begin
        rd_word  = ed_word;
        rd_built = ETHERNET;
      end
      default: rd_built = 1'b0;
    endcase
    // Word 100's <4> and <5>, the keyboard's and the mouse's, as the grant
    // found them.
    if (rq_k == 8'o100) rd_word[5:4] = in_irq_g;
    // And `<6>`, the network's, at the clock after the grant, where muir
    // reads its interface.
    if (rq_k == 8'o100) rd_word[6] = ch_irq_state;
    // And `<8>`, the Ethernet device's, as the clock began.
    if (rq_k == 8'o100) rd_word[8] = ed_irq_state;
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
      bd_rem <= '0; bd_rem_pos <= 1'b0; bd_on <= 1'b0; bd_own <= 1'b0; bd_da_own <= 1'b0;
      bd_now <= '0; bd_done <= '0; tv_at <= '0;
      fd_on <= 1'b0; fd_ie <= 1'b0; fd_refused <= 1'b0; fd_fault <= 1'b0;
      fd_cbase <= '0; fd_rbase <= '0; fd_clog <= '0; fd_rlog <= '0;
      fd_cprod <= '0; fd_ccons <= '0; fd_rcons <= '0; fd_hopen <= '0;
      fd_crefused <= 1'b0; fd_hnext <= '0; fd_pub <= 1'b0; fd_pub_to <= '0;
    end else begin
      fd_on <= fd_on_w; fd_ie <= fd_ie_w; fd_refused <= fd_refused_w; fd_fault <= fd_fault_w;
      fd_cbase <= fd_cbase_w; fd_rbase <= fd_rbase_w; fd_clog <= fd_clog_w; fd_rlog <= fd_rlog_w;
      fd_cprod <= fd_cprod_w; fd_ccons <= fd_ccons_w; fd_rcons <= fd_rcons_w;
      // The host's writes: a completion accepted lands the next clock;
      // STATE's <5> says whether the last was refused, and a claim clears
      // it; HANDLES staged in the epoch.  The handles open land with the
      // completion.  The disable, the device's reset, closes the handles
      // and drops the staged count: last, over the rest.
      fd_pub <= h_complete && fd_ok;
      if (h_complete && fd_ok) fd_pub_to <= host_wdata[15:0];
      if (h_complete) fd_crefused <= !fd_ok;
      if (h_claim) fd_crefused <= 1'b0;
      if (host_we && host_widx == H_HANDLES && fd_in_epoch) fd_hnext <= host_wdata[7:0];
      if (fd_complete) fd_hopen <= fd_hnext;
      if (fd_on && !fd_on_w) begin
        fd_hopen <= '0;
        fd_hnext <= '0;
      end
      for (int k = 0; k < 3; k++) tm[k] <= timer_tick(tm_w[k], period);
      bd_cmd <= bd_cmd_w;
      bd_bad <= bd_bad_w; bd_past_end <= bd_past_end_w; bd_nxm <= bd_nxm_w;
      if (wr_v && wr_k == 8'o210) bow <= wr_data[2];
      if (wr_bd && wr_k[1:0] == 2'd1) bd_clp <= wr_data[27:0];
      // The walk's end: the last memory address, and the disk address
      // unless it was written since START, which the write's own takes.
      if (bd_fin) bd_lma <= bd_fin_lma;
      if (bd_fin && bd_da_own) bd_da <= bd_fin_da;
      if (wr_bd && wr_k[1:0] == 2'd2) bd_da <= {1'b0, wr_data[27:0]};
      if (bd_go) begin
        bd_on <= 1'b1; bd_own <= 1'b1; bd_da_own <= 1'b1;
      end
      if (wr_bd && wr_k[1:0] == 2'd0) bd_own <= 1'b0;
      if (wr_bd && wr_k[1:0] == 2'd2) bd_da_own <= 1'b0;
      if (wr_reset) begin
        bd_on <= 1'b0; bd_own <= 1'b0;
      end
      // muir's `advance` before an access, and RESET-DEVICES's DONE at the
      // clock last told.
      if (wr_bd || (rq_v && rq_k[7:2] == 6'o40)) bd_now <= inst;
      if (wr_reset) bd_done <= bd_now;
      else if (bd_go) bd_done <= inst;
      else if (bd_charge && bd_on) bd_done <= bd_done + 48'(BLOCK_UNITS);
      if (wr_reset) tv_at <= inst;
      // DONE less the instant, counted down by the period.
      if (bd_on || bd_go) begin
        bd_rem     <= bd_rem_n;
        bd_rem_pos <= bd_rem_n > 0;
      end
      if (timers_rst)
        for (int k = 0; k < 3; k++) tm[k] <= '0;
    end
  end

  // ======================================== the host's claim and the epoch

  // The epoch counts every disable: the machine's write of 160, its
  // RESET-DEVICES, and a reset of the machine that finds the device
  // enabled.  No reset reaches either.
  always_ff @(posedge clk) begin
    if (rst ? fd_on : fd_on && !fd_on_w) fd_epoch <= fd_epoch + 16'd1;
    if (h_claim) begin
      if (!host_wdata[0]) fd_busy <= 1'b0;
      else if (fd_in_epoch && !rst) fd_busy <= 1'b1;
    end
  end

  // The host's reads, a clock after the index.
  always_ff @(posedge clk) begin
    unique case (host_ridx)
      H_RTC_SECONDS:  host_rdata <= rtc_sec;
      H_RTC_FRACTION: host_rdata <= {2'd0, rtc_frac[30:1]};
      H_STATE:        host_rdata <= {fd_epoch, 10'd0, fd_crefused, fd_work, !fd_on && !fd_busy,
                                     fd_busy, fd_ie, fd_on};
      H_CLAIM:        host_rdata <= {31'd0, fd_busy};
      H_CMD_BASE:     host_rdata <= {4'd0, fd_cbase};
      H_CMD_LOG2:     host_rdata <= {28'd0, fd_clog};
      H_RESP_BASE:    host_rdata <= {4'd0, fd_rbase};
      H_RESP_LOG2:    host_rdata <= {28'd0, fd_rlog};
      H_CMD_PROD:     host_rdata <= {16'd0, fd_cprod};
      H_RESP_PROD:    host_rdata <= {16'd0, fd_chost};
      H_RESP_CONS:    host_rdata <= {16'd0, fd_rcons};
      H_HANDLES:      host_rdata <= {24'd0, fd_hopen};
      H_MEM_WORDS:    host_rdata <= 32'(MAIN_WORDS);
      default:        host_rdata <= 32'd0;
    endcase
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
  //         <3> active, <4> a transfer in flight (its walk running or its
  //         words on the port), which no checkpoint carries, <5> a pack on
  //         unit 0
  //   16    DONE, and 17 the instant block-disk was last told
  //   18    word 210's black-on-white
  //   19    the instant, muir's `Machine::ns`
  //   20    the real-time clock's seconds; 21 the microseconds
  //   22    the instant of the last RESET-DEVICES
  //   23    the keyboard and the mouse (`quux15_input.sv`'s `ro_state`)
  //   24-31 revision 16's Ethernet device, its word k - 24
  //         (`quux16_ethernet.sv`'s readout); 0 below revision 16
  //   64-127 the keyboard's FIFO, word k - 64 of it, in <23:0>
  always_comb begin
    ro_dev = 64'd0;
    unique case (ro_k[4:0])
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
      5'd13: ro_dev = {35'd0, bd_da};
      5'd14: ro_dev = {36'd0, bd_lma};
      5'd15: ro_dev = {58'd0, bd_present, bd_flight, bd_active, bd_nxm, bd_past_end, bd_bad};
      5'd16: ro_dev = {16'd0, bd_done};
      5'd17: ro_dev = {16'd0, bd_now};
      5'd18: ro_dev = {63'd0, bow};
      5'd19: ro_dev = {16'd0, snap_inst};
      5'd20: ro_dev = {32'd0, rtc_sec};
      5'd21: ro_dev = {32'd0, us_cnt};
      5'd22: ro_dev = {16'd0, tv_at};
      5'd23: ro_dev = {16'd0, in_ro_state};
      5'd24, 5'd25, 5'd26, 5'd27, 5'd28, 5'd29, 5'd30, 5'd31: ro_dev = ed_ro;
      default: ro_dev = 64'd0;
    endcase
    if (ro_k[6:5] != 2'd0) ro_dev = ro_k[6] ? {40'd0, in_ro_fifo} : 64'd0;
  end

  logic unused;
  assign unused = ^{wr_k[7:3], prod_data[31:16]};

endmodule

`default_nettype wire
