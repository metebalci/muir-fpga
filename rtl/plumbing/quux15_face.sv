// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S CONSOLE FACE ON A BOARD**: the console's page
// (`cadr_console.sv`'s words, which `cadr-console`, `cadr-readout` and
// `cadr-checkpoint` drive) on a general purpose port (`cadr_gp_regs.sv`), for
// the pipelined core (`quux15_core.sv`), which has no diagnostic bus: its
// sixteen diagnostic registers are its own ports, written and read here
// directly.
//
// **THE CONSOLE'S WORDS, AND WHAT REVISION 15 MAKES OF EACH.**  Every word
// not named reads `UNMAPPED`, the complement of IDENT, and a write there is
// dropped, as on the console.
//
//   page 0, +0x00
//     0  IDENT    "CONS"
//     1  STAT     <2> answered: every diagnostic cycle is.  <4> and <5>,
//                 the no-auto-boot switch's, read 0: the board has none, and
//                 the machine comes out of reset running from its PROM, as
//                 revisions 13 and 14 do on it
//     2  CYCLES   the microcycles committed since reset, <31:0>
//     3  CYCLESH  <63:32>, latched when CYCLES was read
//     4  TICKS    the clocks since reset, <31:0>: a tick is the machine's
//                 clock, the period word 40 says
//     5  TICKSH   <63:32>, latched when TICKS was read
//     6  RESET    a write of `RESET_KEY` and of nothing else asks for the
//                 machine's reset, a request `RESET_T` clocks long, which
//                 the core latches and takes once its memory port has
//                 drained (`quux15_core.sv`'s `rq_*`).  **THE WRITE IS
//                 ANSWERED ONCE THE MACHINE HAS BEEN THROUGH ITS RESET, OR
//                 AFTER `ANSWER_T` CLOCKS, WHICHEVER COMES FIRST**: its B is
//                 held until then, and never longer, since a write on this
//                 port that nothing answers hangs both Arm cores.  It reads
//                 the key's top half in <31:16>, the resets since the face
//                 came up in <15:8> (saturating), and
//                   <0> a reset now: the request, the drain or the machine
//                       in its reset
//                   <1> the drain: the port not yet quiet
//                   <2> the last RESET write was answered at `ANSWER_T`,
//                       the machine not through its reset by then; cleared
//                       by the next RESET write
//                   <3> the reset cut the memory port: a drain met the
//                       core's bound, and the machine is held in reset
//                       until the port's own reset (sticky, the core's
//                       `rst_cut`)
//     7  VMA      <31:0> of VMA; **its read latches Q and MD beside it**
//     8  Q        <31:0> of Q, latched when VMA was read
//     9  MD       <31:0> of MD, latched when VMA was read
//     10 RO       the readout (A15b.13): written with `{sel<3:0>,
//                 word<13:0>}` (`quux15_core.sv`'s selectors and register
//                 table), read as the echo of the address the word in 11
//                 and 12 was read at; **its read latches all three**.  A
//                 write of selector 15 takes the devices' snapshot, the
//                 instant and the timers, which the checkpoint's time words
//                 then read
//     11 RO_LO    that word's <31:0>
//     12 RO_HI    its <63:32>: the console's 16 bits widened to 32, for the
//                 control store's 64-bit words
//
//   page 1, +0x40: word 16 + k is diagnostic register `EADR` k, read (the
//   register's word in <15:0>) and written (`SPY<15:0>` from <15:0>).
//
//   page 2, +0x80
//     32 BUILD    the bitstream's build stamp (USR_ACCESS)
//     33 DISPLAY  the backplane's display boards, `cadr_console.sv`'s word
//                 with its keys and marker: `TV_SIMPLE_KEY` or
//                 `TV_LISPM_KEY`, `COLOR_TV_KEY` or its complement, read
//                 back as `{TV_MARK, 14'd0, color_tv, tv_lispm}`.  QUUX has
//                 neither board, so the two settings are kept and read back
//                 and reach nothing, as on revisions 13 and 14
//     34 HDMI     what the display output shows and which way up, the
//                 console's six keys, read back as `{HDMI_MARK, 12'd0,
//                 rotate, out}`; out to `cadr_display_out.sv`'s `out_sel`
//                 and `rotate`.  The video controller fills the raster, so
//                 the output keeps it upright whatever the turn says
//     35 LAMPS    whether the activity lamp blinks or holds a level:
//                 `LAMP_STEADY_KEY` or its complement, read back as
//                 `{LAMP_MARK, 15'd0, steady}`; out to the board's lamp
//     36 SLEEP    whether the display output sleeps a monitor, and after how
//                 long: a write of `HDMI_SLEEP_KEY` in <31:16>, <15> clear,
//                 and the seconds in <14:0>, all four strobes, is a setting,
//                 and a write of `HDMI_WAKE_KEY` a wake, each a clock's pulse
//                 to the display output, which holds the setting; read back
//                 as `{HDMI_SLEEP_MARK, asleep, setting}`, or `UNMAPPED` on a
//                 board with no display output (`disp_fitted` low).
//                 `cadr-displayport` follows its bit 15
//     37 BOARDS   main memory: "BD" in <31:16> and its 64K-word units in
//                 <10:0>, read only: revision 15's is the bitstream's
//     38 RANGE    `MEM_BOARDS_RANGE_MARK` in <31:22>, the units as both the
//                 default <21:11> and the most <10:0>
//     39 VIDEO    the video controller's size: `CADR_VIDEO_MARK` in <31:22>,
//                 the width <21:11>, the height <10:0>
//     40 PERIOD   the clock's period, in units of 0.5 ns
//     41 RTC      the real-time clock's seconds at the machine's reset, as
//                 the processing system wrote them; the next reset takes
//                 them, until the host first sets the clock through the
//                 file device's page (`quux_fd_face.sv`, 0x010 and 0x014),
//                 the one setter, after which no reset reaches the clock
//                 (`quux15_devices.sv`).  No program writes it
//     42 ERRORS   the display output's two sticky bits, a bank the raster
//                 reached before its words (`underrun`) and a read the port
//                 answered with an error (`rd_error`): `{DISP_ERR_MARK,
//                 14'd0, rd_error, underrun}`, or `UNMAPPED` on a board with
//                 no display output.  A write of `DISP_CLEAR_KEY`, all four
//                 strobes, clears both: a clock's pulse to the display
//                 output, whose `underrun` clears once the pulse has crossed
//                 into the pixel domain, so a read in the next few clocks may
//                 still see it.  Every other write is dropped
//
//   page 3, +0xC0: **THE MEMORY PORT'S LATENCY PROBE**
//   (`quux15_mem_probe.sv`), on a board whose port has one (`probe_fitted`,
//   the DE25-Nano's and the Kria KR260's); on any other every word of the
//   page reads `UNMAPPED` and a write there is dropped.  Each latency is in
//   clocks of the machine's clock, from the port taking the machine's
//   address to its last read beat or its write response.
//     48 PROBE    a write of `PROBE_RUN_KEY` clears every figure and starts
//                 the probe, one of `PROBE_STOP_KEY` stops it, each a clock's
//                 pulse; every other write is dropped.  Read as
//                 `{PROBE_MARK, 13'd0, lost, saturated, running}`.  **READ
//                 THE FIGURES STOPPED**: while it runs they move, and a sum
//                 read beside a count may be a clock apart
//     49 RD_N     the reads timed: line fills, or each burst of a split one
//     50 RD_SUM   their latencies' sum, <31:0>
//     51 RD_SUMH  <47:32> of it in <15:0>
//     52 RD_MAX   the longest, <19:0>
//     53 WR_N     the writes timed, each burst of a split word one
//     54 WR_SUM   their latencies' sum, <31:0>
//     55 WR_SUMH  <47:32> of it in <15:0>
//     56 WR_MAX   the longest, <19:0>
//
// **A READOUT WORD IS THE MACHINE HALTED**: the core reads its memories on
// their write ports only while halted, so a word read while it runs is
// whatever the port last read.  The word is captured `RO_CLOCKS` clocks after
// the write of word 10, and the echo moves to the address only then, so a
// read of word 10 that came too soon names the old address and is refused by
// the reader (`cadr-readout`'s `ro_word`).

`default_nettype none

module quux15_face #(
    parameter logic [31:0] IDENT      = 32'h434F_4E53,
    parameter logic [31:0] UNMAPPED   = ~IDENT,
    parameter logic [31:0] RESET_KEY  = 32'h5253_4554,
    parameter int unsigned RESET_T    = 64,
    // The longest a RESET write waits for its answer: 2^17 clocks, past
    // the core's drain bound (2^16) and its reset, so that an answer at the
    // bound finds a cut drain already recorded in word 6's <3>.
    parameter int unsigned ANSWER_T   = 131072,
    // Main memory, in 64K-word units, and the video controller's size.
    parameter int unsigned MAIN_UNITS = 32,
    parameter int unsigned VIDEO_W    = 1280,
    parameter int unsigned VIDEO_H    = 1024,
    // The period, in units of 0.5 ns.
    parameter logic [31:0] PERIOD     = 32'd26,
    // **WORDS 33 TO 36**: `cadr_console.sv`'s keys and markers, the same
    // values, so that `cadr-console` and `cadr-displayport` drive and read
    // them unchanged.
    parameter logic [31:0] TV_SIMPLE_KEY   = 32'h534D_504C,
    parameter logic [31:0] TV_LISPM_KEY    = 32'h4C53_504D,
    parameter logic [31:0] COLOR_TV_KEY    = 32'h434F_4C52,
    parameter logic [15:0] TV_MARK         = 16'h5456,
    parameter logic [31:0] HDMI_TV_KEY     = 32'h4854_5631,
    parameter logic [31:0] HDMI_COLOR_KEY  = 32'h4854_5632,
    parameter logic [31:0] HDMI_BOTH_KEY   = 32'h4854_5642,
    parameter logic [31:0] HDMI_UP_KEY     = 32'h4855_5052,
    parameter logic [31:0] HDMI_CW_KEY     = 32'h4852_4357,
    parameter logic [31:0] HDMI_CCW_KEY    = 32'h4852_4343,
    parameter logic [15:0] HDMI_MARK       = 16'h4844,
    parameter logic [31:0] LAMP_STEADY_KEY = 32'h5354_4459,
    parameter logic [15:0] LAMP_MARK       = 16'h4C44,
    parameter logic [15:0] HDMI_SLEEP_KEY  = 16'h4853,
    parameter logic [31:0] HDMI_WAKE_KEY   = 32'h5741_4B45,
    parameter logic [15:0] HDMI_SLEEP_MARK = 16'h5A5A,
    // **AND WORD 42**, the display output's two sticky bits: the marker
    // "DE", and the clear's key "CLRD", on `RESET_KEY`'s rule --- four
    // distinct bytes, none `00` or `FF`, neither IDENT, UNMAPPED, another
    // key nor what the word reads back.
    parameter logic [15:0] DISP_ERR_MARK   = 16'h4445,
    parameter logic [31:0] DISP_CLEAR_KEY  = 32'h434C_5244,
    // **AND WORD 48**, the latency probe's: the marker "PB", and the keys
    // "PRUN" and "STOP", on the same rule.
    parameter logic [15:0] PROBE_MARK      = 16'h5042,
    parameter logic [31:0] PROBE_RUN_KEY   = 32'h5052_554E,
    parameter logic [31:0] PROBE_STOP_KEY  = 32'h5354_4F50,
    parameter int unsigned ID_W       = 16,
    parameter int unsigned LEN_W      = 8
) (
    input  var logic        clk,
    input  var logic        rst,
    // --- The page, from the splitter.
    input  var logic [11:0] s_awaddr,
    input  var logic [LEN_W-1:0] s_awlen,
    input  var logic [ID_W-1:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [ID_W-1:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [11:0] s_araddr,
    input  var logic [LEN_W-1:0] s_arlen,
    input  var logic [ID_W-1:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [ID_W-1:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,
    // --- The build stamp.
    input  var logic [31:0] build,
    // --- The machine: the reset asked for, and the core's answer to it
    // --- (`quux15_core.sv`'s `rst_pend`, `rst_on`, `rst_cut`).
    output var logic        mach_req,
    input  var logic        mach_pend,
    input  var logic        mach_on,
    input  var logic        mach_cut,
    output var logic [31:0] rtc_start,
    input  var logic [63:0] committed,
    input  var logic [47:0] clocks,
    input  var logic [39:0] vma,
    input  var logic [39:0] q,
    input  var logic [39:0] md,
    output var logic        spy_we,
    output var logic [3:0]  spy_eadr,
    output var logic [15:0] spy_wdata,
    output var logic [3:0]  spy_raddr,
    input  var logic [15:0] spy_rdata,
    output var logic        rm_en,
    output var logic        rm_snap,
    output var logic [3:0]  rm_sel,
    output var logic [13:0] rm_addr,
    input  var logic [63:0] rm_word,
    // --- The display output (`cadr_display_out.sv`), words 34, 36 and 42,
    // --- in this clock's domain: what it shows and which way up; the sleep's
    // --- setting and wake, pulses, and what it holds; whether there is one;
    // --- its two sticky bits, `underrun` brought into this domain by the
    // --- board, and their clear, a pulse.
    output var logic [1:0]  disp_out,
    output var logic [1:0]  disp_rotate,
    output var logic        sleep_set,
    output var logic [14:0] sleep_secs,
    output var logic        wake,
    input  var logic        disp_fitted,
    input  var logic [14:0] sleep_q,
    input  var logic        asleep,
    input  var logic        underrun,
    input  var logic        rd_error,
    output var logic        err_clear,
    // --- The activity lamp, word 35: steady rather than blinking.
    output var logic        steady_lamps,
    // --- The memory port's latency probe, page 3: whether there is one;
    // --- its state and its eight words (49 to 56 in order); RUN and STOP,
    // --- pulses.
    input  var logic        probe_fitted,
    input  var logic [2:0]  probe_state,
    input  var logic [7:0][31:0] probe_words,
    output var logic        probe_run,
    output var logic        probe_stop
);

  localparam int unsigned RO_CLOCKS = 6;
  localparam logic [15:0] MEM_BOARDS_MARK       = 16'h4244;
  localparam logic [9:0]  MEM_BOARDS_RANGE_MARK = 10'h1A5;
  localparam logic [9:0]  VIDEO_MARK            = 10'h356;

  logic [9:0]  w_word, r_word;
  logic        wr, rd;
  logic [31:0] wr_data, wr_mask, rd_data;
  // The write channel's answer, held while a RESET write waits (`ans_hold`).
  logic        regs_bvalid, regs_bready, ans_hold;
  assign s_bvalid    = regs_bvalid && !ans_hold;
  assign regs_bready = s_bready && !ans_hold;

  cadr_gp_regs #(.ID_W(ID_W), .LEN_W(LEN_W)) u_regs (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awid(s_awid), .s_awvalid(s_awvalid),
      .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bresp(s_bresp), .s_bid(s_bid),
      .s_bvalid(regs_bvalid), .s_bready(regs_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arid(s_arid), .s_arvalid(s_arvalid),
      .s_arready(s_arready), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rid(s_rid),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .w_word(w_word), .wr(wr), .wr_data(wr_data), .wr_mask(wr_mask),
      .r_word(r_word), .rd(rd), .rd_data(rd_data)
  );

  // --- The machine's reset: RESET's key's request, a pulse the core
  // --- latches; and the write's answer, held until the machine has been in
  // --- its reset and out of it (`ans_seen`, then all three low), or until
  // --- `ANSWER_T` clocks have gone (`ans_bound`).
  logic [6:0]  reset_left;
  logic [7:0]  resets;
  logic        key_ok, ans_seen, ans_bound;
  logic [17:0] ans_count;
  assign key_ok = wr && w_word == 10'd6 && wr_mask == 32'hFFFF_FFFF && wr_data == RESET_KEY;
  always_ff @(posedge clk) begin
    if (rst) begin
      reset_left <= '0;
      resets     <= '0;
      ans_hold   <= 1'b0;
      ans_seen   <= 1'b0;
      ans_bound  <= 1'b0;
      ans_count  <= '0;
    end else if (key_ok) begin
      reset_left <= 7'(RESET_T);
      if (resets != 8'hFF) resets <= resets + 8'd1;
      ans_hold   <= 1'b1;
      ans_seen   <= 1'b0;
      ans_bound  <= 1'b0;
      ans_count  <= '0;
    end else begin
      if (reset_left != '0) reset_left <= reset_left - 7'd1;
      if (ans_hold) begin
        ans_count <= ans_count + 18'd1;
        if (mach_on) ans_seen <= 1'b1;
        if (ans_seen && !mach_on && !mach_pend && reset_left == '0) begin
          ans_hold <= 1'b0;
        end else if (32'(ans_count) + 1 >= ANSWER_T) begin
          ans_hold  <= 1'b0;
          ans_bound <= 1'b1;
        end
      end
    end
  end
  assign mach_req = reset_left != '0;

  // --- Words 33 to 36 and 42: the display output and the lamp, as
  // --- `cadr_console.sv` has them.  A whole-word key is compared with the
  // --- beat's unstrobed lanes as zero, so a key with no zero byte asks for
  // --- all four lanes by itself; a setting carrying its value in the
  // --- bottom half asks by the strobes.  Settings are register loads; the
  // --- sleep's setting and wake and the sticky bits' clear are a clock's
  // --- pulse each, the display holding what they set.
  logic [31:0] w_full;
  logic        tv_lispm, color_tv;
  assign w_full = wr_data & wr_mask;
  always_ff @(posedge clk) begin
    if (rst) begin
      // One SIMPLE TV and no color board, the first display shown upright,
      // the lamp blinking: what `cadr_console.sv` comes up with.
      tv_lispm     <= 1'b0;
      color_tv     <= 1'b0;
      disp_out     <= 2'b01;
      disp_rotate  <= 2'd0;
      steady_lamps <= 1'b0;
      sleep_set    <= 1'b0;
      sleep_secs   <= 15'd0;
      wake         <= 1'b0;
      err_clear    <= 1'b0;
      probe_run    <= 1'b0;
      probe_stop   <= 1'b0;
    end else begin
      sleep_set <= 1'b0;
      wake      <= 1'b0;
      err_clear <= 1'b0;
      probe_run  <= wr && w_word == 10'd48 && probe_fitted && w_full == PROBE_RUN_KEY;
      probe_stop <= wr && w_word == 10'd48 && probe_fitted && w_full == PROBE_STOP_KEY;
      if (wr && w_word == 10'd33) begin
        if (w_full == TV_SIMPLE_KEY)      tv_lispm <= 1'b0;
        else if (w_full == TV_LISPM_KEY)  tv_lispm <= 1'b1;
        if (w_full == COLOR_TV_KEY)       color_tv <= 1'b1;
        else if (w_full == ~COLOR_TV_KEY) color_tv <= 1'b0;
      end
      if (wr && w_word == 10'd34) begin
        if (w_full == HDMI_TV_KEY)         disp_out    <= 2'b01;
        else if (w_full == HDMI_COLOR_KEY) disp_out    <= 2'b10;
        else if (w_full == HDMI_BOTH_KEY)  disp_out    <= 2'b11;
        else if (w_full == HDMI_UP_KEY)    disp_rotate <= 2'd0;
        else if (w_full == HDMI_CW_KEY)    disp_rotate <= 2'd1;
        else if (w_full == HDMI_CCW_KEY)   disp_rotate <= 2'd2;
      end
      if (wr && w_word == 10'd35) begin
        if (w_full == LAMP_STEADY_KEY)       steady_lamps <= 1'b1;
        else if (w_full == ~LAMP_STEADY_KEY) steady_lamps <= 1'b0;
      end
      if (wr && w_word == 10'd36) begin
        if (w_full[31:16] == HDMI_SLEEP_KEY && !w_full[15] && wr_mask == 32'hFFFF_FFFF) begin
          sleep_set  <= 1'b1;
          sleep_secs <= w_full[14:0];
        end
        if (w_full == HDMI_WAKE_KEY) wake <= 1'b1;
      end
      if (wr && w_word == 10'd42 && w_full == DISP_CLEAR_KEY) err_clear <= 1'b1;
    end
  end

  // --- The written words: the diagnostic registers, the readout's address,
  // --- the real-time clock's start.
  logic        ro_pending;
  logic [2:0]  ro_count;
  logic [17:0] ro_asked, ro_echo;
  logic [63:0] ro_data;
  always_ff @(posedge clk) begin
    if (rst) begin
      spy_we     <= 1'b0;
      rm_snap    <= 1'b0;
      spy_eadr   <= 4'd0;
      spy_wdata  <= 16'd0;
      rm_en      <= 1'b0;
      ro_asked   <= 18'h3FFFF;
      ro_echo    <= 18'h3FFFF;
      ro_pending <= 1'b0;
      ro_count   <= '0;
      ro_data    <= '0;
      rtc_start  <= 32'd0;
    end else begin
      spy_we  <= 1'b0;
      rm_snap <= wr && w_word == 10'd10 && wr_data[17:14] == 4'd15;
      if (wr && w_word[9:4] == 6'd1) begin
        // A diagnostic register written, a clock's pulse.
        spy_we    <= 1'b1;
        spy_eadr  <= w_word[3:0];
        spy_wdata <= wr_data[15:0];
      end
      if (wr && w_word == 10'd10) begin
        rm_en      <= 1'b1;
        ro_asked   <= wr_data[17:0];
        ro_pending <= 1'b1;
        ro_count   <= 3'(RO_CLOCKS);
      end else if (ro_pending) begin
        if (ro_count == '0) begin
          ro_pending <= 1'b0;
          ro_echo    <= ro_asked;
          ro_data    <= rm_word;
        end else begin
          ro_count <= ro_count - 3'd1;
        end
      end
      if (wr && w_word == 10'd41) rtc_start <= (rtc_start & ~wr_mask) | (wr_data & wr_mask);
    end
  end
  assign rm_sel  = ro_asked[17:14];
  assign rm_addr = ro_asked[13:0];

  // --- The latches a low word's read takes: CYCLES's high half, TICKS's,
  // --- Q and MD beside VMA, the readout's word beside its echo.
  logic [31:0] cycles_hi, ticks_hi, q_l, md_l, echo_l, lo_l, hi_l;
  always_ff @(posedge clk) begin
    if (rst) begin
      cycles_hi <= '0; ticks_hi <= '0; q_l <= '0; md_l <= '0;
      echo_l <= '0; lo_l <= '0; hi_l <= '0;
    end else if (rd) begin
      unique case (r_word)
        10'd2:  cycles_hi <= committed[63:32];
        10'd4:  ticks_hi <= {16'd0, clocks[47:32]};
        10'd7:  begin q_l <= q[31:0]; md_l <= md[31:0]; end
        10'd10: begin echo_l <= {14'd0, ro_echo}; lo_l <= ro_data[31:0]; hi_l <= ro_data[63:32]; end
        default: ;
      endcase
    end
  end

  // The read: a choice off `r_word`, which `cadr_gp_regs.sv` samples a
  // clock after `rd`, the latch then taken.  A diagnostic register is read
  // off its own word's index.
  assign spy_raddr = r_word[3:0];
  logic [31:0] cyc_lo, tick_lo;
  always_ff @(posedge clk) begin
    if (rd && r_word == 10'd2) cyc_lo <= committed[31:0];
    if (rd && r_word == 10'd4) tick_lo <= clocks[31:0];
  end
  logic [31:0] vma_lo;
  always_ff @(posedge clk) begin
    if (rd && r_word == 10'd7) vma_lo <= vma[31:0];
  end
  always_comb begin
    rd_data = UNMAPPED;
    if (r_word[9:4] == 6'd1) begin
      rd_data = {16'd0, spy_rdata};
    end else begin
      unique case (r_word)
        10'd0:  rd_data = IDENT;
        10'd1:  rd_data = {29'd0, 1'b1, 2'd0};
        10'd2:  rd_data = cyc_lo;
        10'd3:  rd_data = cycles_hi;
        10'd4:  rd_data = tick_lo;
        10'd5:  rd_data = ticks_hi;
        10'd6:  rd_data = {RESET_KEY[31:16], resets, 4'd0, mach_cut, ans_bound, mach_pend,
                           reset_left != '0 || mach_pend || mach_on};
        10'd7:  rd_data = vma_lo;
        10'd8:  rd_data = q_l;
        10'd9:  rd_data = md_l;
        10'd10: rd_data = echo_l;
        10'd11: rd_data = lo_l;
        10'd12: rd_data = hi_l;
        10'd32: rd_data = build;
        10'd33: rd_data = {TV_MARK, 14'd0, color_tv, tv_lispm};
        10'd34: rd_data = {HDMI_MARK, 12'd0, disp_rotate, disp_out};
        10'd35: rd_data = {LAMP_MARK, 15'd0, steady_lamps};
        10'd36: rd_data = disp_fitted ? {HDMI_SLEEP_MARK, asleep, sleep_q} : UNMAPPED;
        10'd37: rd_data = {MEM_BOARDS_MARK, 5'd0, 11'(MAIN_UNITS)};
        10'd38: rd_data = {MEM_BOARDS_RANGE_MARK, 11'(MAIN_UNITS), 11'(MAIN_UNITS)};
        10'd39: rd_data = {VIDEO_MARK, 11'(VIDEO_W), 11'(VIDEO_H)};
        10'd40: rd_data = PERIOD;
        10'd41: rd_data = rtc_start;
        10'd42: rd_data = disp_fitted ? {DISP_ERR_MARK, 14'd0, rd_error, underrun} : UNMAPPED;
        10'd48: rd_data = probe_fitted ? {PROBE_MARK, 13'd0, probe_state} : UNMAPPED;
        10'd49, 10'd50, 10'd51, 10'd52, 10'd53, 10'd54, 10'd55, 10'd56:
                rd_data = probe_fitted ? probe_words[r_word[2:0] - 3'd1] : UNMAPPED;
        default: rd_data = UNMAPPED;
      endcase
    end
  end

  logic unused;
  assign unused = ^{vma[39:32], q[39:32], md[39:32]};

endmodule

`default_nettype wire
