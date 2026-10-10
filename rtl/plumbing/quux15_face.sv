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
//     6  RESET    a write of `RESET_KEY` and of nothing else resets the
//                 machine for `RESET_T` clocks; it reads the key's top half
//                 in <31:16>, the resets since the face came up in <15:8>
//                 (saturating) and <0> a reset now
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
//     37 BOARDS   main memory: "BD" in <31:16> and its 64K-word units in
//                 <10:0>, read only: revision 15's is the bitstream's
//     38 RANGE    `MEM_BOARDS_RANGE_MARK` in <31:22>, the units as both the
//                 default <21:11> and the most <10:0>
//     39 VIDEO    the video controller's size: `CADR_VIDEO_MARK` in <31:22>,
//                 the width <21:11>, the height <10:0>
//     40 PERIOD   the clock's period, in units of 0.5 ns
//     41 RTC      the real-time clock's seconds at the machine's reset, as
//                 the processing system wrote them (the host's time); the
//                 next reset takes them
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
    // Main memory, in 64K-word units, and the video controller's size.
    parameter int unsigned MAIN_UNITS = 32,
    parameter int unsigned VIDEO_W    = 1280,
    parameter int unsigned VIDEO_H    = 1024,
    // The period, in units of 0.5 ns.
    parameter logic [31:0] PERIOD     = 32'd26,
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
    // --- The machine.
    output var logic        mach_rst,
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
    input  var logic [63:0] rm_word
);

  localparam int unsigned RO_CLOCKS = 6;
  localparam logic [15:0] MEM_BOARDS_MARK       = 16'h4244;
  localparam logic [9:0]  MEM_BOARDS_RANGE_MARK = 10'h1A5;
  localparam logic [9:0]  VIDEO_MARK            = 10'h356;

  logic [9:0]  w_word, r_word;
  logic        wr, rd;
  logic [31:0] wr_data, wr_mask, rd_data;

  cadr_gp_regs #(.ID_W(ID_W), .LEN_W(LEN_W)) u_regs (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awid(s_awid), .s_awvalid(s_awvalid),
      .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bresp(s_bresp), .s_bid(s_bid),
      .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arid(s_arid), .s_arvalid(s_arvalid),
      .s_arready(s_arready), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rid(s_rid),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .w_word(w_word), .wr(wr), .wr_data(wr_data), .wr_mask(wr_mask),
      .r_word(r_word), .rd(rd), .rd_data(rd_data)
  );

  // --- The machine's reset: RESET's key's pulse.
  logic [6:0]  reset_left;
  logic [7:0]  resets;
  logic        key_ok;
  assign key_ok = wr && w_word == 10'd6 && wr_mask == 32'hFFFF_FFFF && wr_data == RESET_KEY;
  always_ff @(posedge clk) begin
    if (rst) begin
      reset_left <= '0;
      resets     <= '0;
    end else if (key_ok) begin
      reset_left <= 7'(RESET_T);
      if (resets != 8'hFF) resets <= resets + 8'd1;
    end else if (reset_left != '0) begin
      reset_left <= reset_left - 7'd1;
    end
  end
  assign mach_rst = reset_left != '0;

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
        10'd6:  rd_data = {RESET_KEY[31:16], resets, 7'd0, reset_left != '0};
        10'd7:  rd_data = vma_lo;
        10'd8:  rd_data = q_l;
        10'd9:  rd_data = md_l;
        10'd10: rd_data = echo_l;
        10'd11: rd_data = lo_l;
        10'd12: rd_data = hi_l;
        10'd32: rd_data = build;
        10'd37: rd_data = {MEM_BOARDS_MARK, 5'd0, 11'(MAIN_UNITS)};
        10'd38: rd_data = {MEM_BOARDS_RANGE_MARK, 11'(MAIN_UNITS), 11'(MAIN_UNITS)};
        10'd39: rd_data = {VIDEO_MARK, 11'(VIDEO_W), 11'(VIDEO_H)};
        10'd40: rd_data = PERIOD;
        10'd41: rd_data = rtc_start;
        default: rd_data = UNMAPPED;
      endcase
    end
  end

  logic unused;
  assign unused = ^{vma[39:32], q[39:32], md[39:32]};

endmodule

`default_nettype wire
