// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's memory port (contract Q6, revision 7): the processor's cycle on a
// machine with no bus interface.  muir's `memory_port::MemoryPort` is the
// reference, and `build/quux_port.quux.pass` holds this module to it tick
// for tick (`golden/src/quux_port.rs`).  The cycle goes one of three ways,
// by the held decode of its physical address:
//
//   MAIN MEMORY, through the cache (`quux_cache.sv`) to the memory
//   controller below.  A read that hits is answered two ticks after the
//   grant; a miss fills its line and a write goes through, one operation of
//   main memory at a time, at the nominal timing: a line fill in 380 ns, a
//   write in 290, a write acknowledged after the hit time by the write
//   buffer, or when the buffer's last write is done.  No Xbus cycle, no
//   setup, no deskew, and `cached` says so to the processor, whose MBUSY and
//   READ IN PROGRESS then fall on the acknowledgment itself (muir's
//   `Ack::cached`).
//
//   AN XBUS DEVICE: `-XBUS.RQ` 80 ns after the grant, the device's answer,
//   and a read deskewed 60 ns more, exactly as the CADR's bus interface runs
//   an Xbus cycle (`cadr_busint_xbus.sv`, which this repeats for QUUX alone:
//   the CADR keeps its interface untouched).
//
//   NOTHING: the CADR's timeout, the free-running oscillator's first rise
//   after the grant plus 4,250 ns (`busint::nxm_timeout_at`), with `NXM
//   TIMEOUT` for word 101's Xbus NXM bit.
//
// **THE NOMINAL TIMING IS A FLOOR** (the contract's clarification).  Main
// memory's real answer comes when it comes --- the Arty's HP0 in about 21
// ticks, the DE25's bridge in 35 and a tail to 227 --- and the port answers
// the processor at muir's instant or, when main memory is slower than the
// figure, as soon as the words are there.  Two countdowns carry muir's
// arithmetic: `free_in`, when main memory is nominally free for its next
// operation (`memory_free_at`), and `buf_in`, when the write buffer is
// (`buffer_free_at`); each holds, over the tick after an edge, how many
// ticks after that edge the instant is.  A cycle granted at E starts its
// operation at E + free_in and is done READ_T or WRITE_T later.  A faster
// memory is simply held back to the count, which is what makes the fabric
// muir's in simulation and never faster than it on a board.
//
// **THE MEMORY CONTROLLER IS ONE ORDERED PORT, WITH ONE OPERATION IN
// FLIGHT**: the write buffer's word first, then a line fill, then the
// uncached requester --- the Xbus bridge's (`cadr_xbus_ddr.sv`), carrying
// MONO TV's frame buffer, which the contract keeps an uncached Xbus device,
// and block-disk's transfers.  The order is the coherence: a transfer that
// reads main memory is served after the buffered write, so it sees every
// word the processor wrote before START (the contract's first rule); a
// line filled before a transfer's word is written is dropped from the cache
// when the word lands (`quux_cache.sv`'s `snoop`, the second).  The seam
// out is the machine's `mem_*`, a level held until done as
// `rtl/plumbing/cadr_axi_master.sv` takes it, with `mem_line` asking four
// words, two 64-bit beats, and the whole line back on `mem_rline`.
//
// `drained` is up when no write waits in the buffer and main memory is
// idle: what the host waits for, after a halt, before it reads main memory
// from outside the machine (the contract: "a halt drains the write buffer").

`default_nettype none

module quux_mem_port
  import cadr_ddr_map::*;
#(
    // QUUX's nominal main memory, `MemoryTiming::NOMINAL`, in ticks.
    parameter int unsigned READ_T  = cadr_tick_pkg::ticks(380),
    parameter int unsigned WRITE_T = cadr_tick_pkg::ticks(290)
) (
    input  var logic         clk,
    input  var logic         rst,

    // The processor's side, as `cadr_busint_xbus.sv` has it on the CADR.
    input  var logic         mclk,
    input  var logic         n_memrq,
    input  var logic         wrcyc,
    input  var logic [21:0]  phys,       // the map's output at the grant
    input  var logic [31:0]  wdata,
    // The held decode: main memory.  Anything else is the Xbus's, a
    // device's or nothing's, and a device says so by answering.
    input  var logic         is_memory,
    output var logic         n_memgrant,
    output var logic         n_memack,
    output var logic         n_loadmd,
    output var logic         timed_out,
    output var logic         cached,     // the cycle is main memory's
    output var logic [31:0]  word,       // a read of main memory's word
    output var logic         busy,

    // The Xbus, for a device's cycle.
    output var logic         dev_rq,
    output var logic         dev_write,
    input  var logic         dev_ack,

    // A block-disk register was written: the whole cache goes at the next
    // grant, muir's `dma_written`.
    input  var logic         invalidate,

    // The uncached requester, `cadr_xbus_ddr.sv`'s seam.  `u_main` says the
    // word is main memory's, and `u_phys` which, for the cache's snoop.
    input  var logic         u_req,
    input  var logic         u_write,
    input  var logic [31:0]  u_addr,
    input  var logic [31:0]  u_wdata,
    input  var logic         u_main,
    input  var logic [21:0]  u_phys,
    output var logic         u_done,
    output var logic [31:0]  u_rdata,  // main memory's own, while u_done

    // Main memory: the machine's DDR seam.
    output var logic         mem_req,
    output var logic         mem_write,
    output var logic         mem_line,
    output var logic [31:0]  mem_addr,
    output var logic [31:0]  mem_wdata,
    input  var logic         mem_done,
    input  var logic [31:0]  mem_rdata,
    input  var logic [127:0] mem_rline,

    output var logic         drained,
    // The cache's counts of reads, for the host: muir's `hits` and
    // `misses`.
    output var logic [31:0]  hits,
    output var logic [31:0]  misses
);

  localparam int unsigned SETUP_T  = cadr_tick_pkg::ticks(80);
  localparam int unsigned DESKEW_T = cadr_tick_pkg::ticks(60);
  localparam int unsigned HIT_T    = cadr_tick_pkg::ticks(20);

  // ----------------------------------------------- the timeout oscillator
  //
  // `cadr_busint_xbus.sv`'s, line for line: the 74LS124 at REQTIM 0A01,
  // 850 ns, free-running from power-on high first, whose gated output the
  // grant opens; `NXM TIMEOUT` on the sixth rise.  See that file for the
  // arithmetic and for why the period stays in nanoseconds.
  localparam int unsigned VCO_HALF_NS = 425;
  localparam int unsigned POWER_ON_T  = cadr_tick_pkg::POWER_ON_EDGES;
  localparam int unsigned NXM_RISES   = 6;

  logic [8:0] vco_acc;
  logic       vco, vco_toggle;
  logic [8:0] vco_next, vco_less;
  assign vco_next   = vco_acc + 9'(cadr_tick_pkg::TICK_NS);
  assign vco_less   = vco_next - 9'(VCO_HALF_NS);
  assign vco_toggle = (vco_acc >= 9'(VCO_HALF_NS - cadr_tick_pkg::TICK_NS));

  logic       nxm, tmr_fell;
  logic [3:0] tmr_rises;
  logic       nxm_due;
  assign nxm_due = tmr_fell && !vco && !vco_toggle
                && (tmr_rises + 4'd1 == 4'(NXM_RISES))
                && (vco_acc >= 9'(VCO_HALF_NS - 2 * cadr_tick_pkg::TICK_NS));

  // ------------------------------------------------------- the cycle
  typedef enum logic [1:0] {IDLE, REQUESTED, GRANTED, ACKED} state_e;
  state_e state;
  logic       write;
  logic       first;        // the first tick of GRANTED: the lookup's answer
  logic       kmem;         // the cycle is main memory's, from its first tick
  logic [9:0] elapsed;
  logic       answered, deskewed;
  logic [9:0] answered_at;

  logic take;
  assign take = (state == IDLE || state == REQUESTED) && !n_memrq && mclk;

  logic mem_cycle;
  assign mem_cycle = first ? is_memory : kmem;

  logic ack_standing;
  assign ack_standing = (state == ACKED) && !n_memrq;

  // `kmem` and not `mem_cycle`: in the first tick `elapsed` is zero and
  // the request is not yet out, so the held flag is all this needs.
  assign dev_rq    = !kmem && ((state == GRANTED && elapsed >= 10'(SETUP_T) - 10'd1)
                               || ack_standing);
  assign dev_write = write;

  logic answering, deskew_due;
  assign answering  = (state == GRANTED) && dev_rq && dev_ack;
  assign deskew_due = answered && (state == GRANTED)
                   && (elapsed >= answered_at + 10'(DESKEW_T) - 10'd1);

  // Main memory's acknowledgment, a register set at the edge before its
  // instant (`ack_in` below).
  logic mack_q;

  logic acked;
  assign acked = ack_standing
              || (state == GRANTED && mem_cycle && mack_q)
              || (state == GRANTED && !mem_cycle && ((write && answering) || deskewed));

  assign n_memgrant = !(state == GRANTED || state == ACKED);
  assign n_memack   = !acked;
  assign n_loadmd   = !acked;
  assign timed_out  = ack_standing && nxm;
  assign busy       = (state != IDLE);
  assign cached     = (state == GRANTED || state == ACKED) && mem_cycle;

  // ------------------------------------------------------- the cache
  logic c_hit, c_hit_way, c_victim;
  logic [31:0] c_word;
  logic c_touch, c_miss, c_update, c_fill, c_inval, c_snoop;
  logic [21:0] snoop_phys;
  logic inval_owed;

  // The cache reads at every edge the port is idle, so the grant's edge
  // reads the grant's address; `line_phys` is it, held for the cycle, and
  // every address this port uses after the grant is taken from there and
  // not from `phys`, which is the map's ripple while `MEMSTART` is up.
  logic [21:0] line_phys;
  logic idle;
  assign idle = (state == IDLE || state == REQUESTED);

  quux_cache cache (
      .clk        (clk),
      .rst        (rst),
      .look       (idle),
      .look_phys  (phys),
      .line_phys  (line_phys),
      .hit        (c_hit),
      .hit_way    (c_hit_way),
      .victim     (c_victim),
      .touch      (c_touch),
      .touch_miss (c_miss),
      .update     (c_update),
      .update_word(wdata),
      .word       (c_word),
      .fill       (c_fill),
      .fill_line  (mem_rline),
      .invalidate (c_inval),
      .snoop      (c_snoop),
      .snoop_phys (snoop_phys)
  );

  // The way and the victim are the cache's business: it keeps them for the
  // word and the fill.  A line's address has no word in it.
  logic unused_cache;
  assign unused_cache = ^{c_hit_way, c_victim, fill_phys[1:0]};

  // The whole cache at the grant after a block-disk register was written.
  assign c_inval = take && (inval_owed || invalidate);

  // A read of main memory decides at the end of its first tick.
  logic decide;
  assign decide   = (state == GRANTED) && first && is_memory;
  assign c_touch  = decide && !write;
  assign c_miss   = !c_hit;
  assign c_update = decide && write;

  // --------------------------------------------- the nominal countdowns
  //
  // Over the tick after an edge, `free_in` is how many ticks after that
  // edge main memory is nominally free, and `buf_in` the same for the write
  // buffer: muir's `memory_free_at` and `buffer_free_at`, saturating at
  // zero.  `ack_in` is the cycle's own acknowledgment the same way, and
  // `mack_q` is raised at the edge before it.
  localparam int unsigned CW = 8;
  logic [CW-1:0] free_in, buf_in, ack_in;
  logic [CW-1:0] start_in, done_in, ack_e;
  assign start_in = free_in;
  assign done_in  = start_in + CW'(write ? WRITE_T : READ_T);
  // A write is answered after the hit time, or when the buffer's last write
  // is done.  A read hit two ticks after the grant, and a miss when its line
  // is done, which the tick after the lookup settles (`settle`).
  assign ack_e = (buf_in > CW'(HIT_T)) ? buf_in : CW'(HIT_T);
  logic          settle, read_hit_q;
  logic [CW-1:0] done_q;

  // What is really in flight, which the counts never overtake: a miss's
  // line not yet in, a write not yet taken by main memory.
  logic fill_owed, fill_have, wb_valid, wb_sent;
  logic [21:0] wb_phys;
  logic [31:0] wb_word;
  logic [31:0] line_word [4];
  logic        from_line;
  assign word = from_line ? line_word[line_phys[1:0]] : c_word;

  // A write enters the buffer at its acknowledgment, when the one before it
  // has really gone: the count alone is muir's, the flag is the board's.
  logic ready;
  assign ready = !mem_cycle || !write || !wb_valid;

  // ---------------------------------------------- the memory controller
  //
  // **THE UNCACHED REQUESTER PASSES STRAIGHT THROUGH** when main memory is
  // idle and nothing of the cache's waits: `mem_*` are the bridge's own
  // wires then, and its answer is main memory's, with no register between.
  // So a frame-buffer cycle is answered as it was on the bridge alone, which
  // is muir's instant in simulation, and only a cache operation already in
  // flight can delay it --- which the testbench's main memory, answering in
  // a few ticks, never lets reach a device's 80 ns of setup.  The cache's
  // own operations are registered.
  typedef enum logic [1:0] {M_IDLE, M_BUSY, M_LET_GO, M_THROUGH} mstate_e;
  mstate_e mstate;
  typedef enum logic {OP_WRITE, OP_FILL} op_e;
  op_e op;
  logic [21:0] fill_phys;

  logic go_write, go_fill, go_u, through;
  assign go_write = wb_valid && !wb_sent;
  assign go_fill  = fill_owed && !fill_have && !go_write;
  // The order: the buffer's write, then a line, then the uncached word.
  // Decided here once, for the wires and for the state both.
  assign go_u     = u_req && !go_write && !go_fill;
  // An uncached word goes out from an idle controller, and stays out
  // (`M_THROUGH`) until the bridge and main memory have both let go.
  // Main memory has let go of the last answer whenever the controller is
  // idle (`M_LET_GO` and `M_THROUGH` each wait for it), so an answer here
  // is this word's, and may come in the very tick it is asked.
  assign through  = (mstate == M_THROUGH) || ((mstate == M_IDLE) && go_u);

  logic        mreq_q, mwrite_q, mline_q;
  logic [31:0] maddr_q, mwdata_q;
  assign mem_req   = through ? u_req   : mreq_q;
  assign mem_write = through ? u_write : mwrite_q;
  assign mem_line  = through ? 1'b0    : mline_q;
  assign mem_addr  = through ? u_addr  : maddr_q;
  assign mem_wdata = through ? u_wdata : mwdata_q;
  assign u_done    = through && mem_done;
  assign u_rdata   = mem_rdata;

  assign c_fill  = (mstate == M_BUSY) && mem_done && (op == OP_FILL);
  assign c_snoop = through && mem_done && u_write && u_main;
  assign snoop_phys = u_phys;
  assign drained = !wb_valid && !fill_owed && (mstate == M_IDLE) && !mem_done;

  always_ff @(posedge clk) begin
    if (rst) begin
      vco_acc <= 9'(VCO_HALF_NS - POWER_ON_T * cadr_tick_pkg::TICK_NS);
      vco     <= 1'b0;
    end else if (vco_toggle) begin
      vco_acc <= vco_less;
      vco     <= !vco;
    end else begin
      vco_acc <= vco_next;
    end

    if (rst) begin
      state       <= IDLE;
      write       <= 1'b0;
      first       <= 1'b0;
      kmem        <= 1'b0;
      elapsed     <= 10'd0;
      answered    <= 1'b0;
      answered_at <= 10'd0;
      deskewed    <= 1'b0;
      tmr_fell    <= 1'b0;
      tmr_rises   <= 4'd0;
      nxm         <= 1'b0;
      mack_q      <= 1'b0;
      free_in     <= '0;
      buf_in      <= '0;
      ack_in      <= '0;
      settle      <= 1'b0;
      read_hit_q  <= 1'b0;
      done_q      <= '0;
      fill_owed   <= 1'b0;
      fill_have   <= 1'b0;
      from_line   <= 1'b0;
      wb_valid    <= 1'b0;
      wb_sent     <= 1'b0;
      wb_phys     <= 22'd0;
      wb_word     <= 32'd0;
      inval_owed  <= 1'b0;
      mstate      <= M_IDLE;
      op          <= OP_WRITE;
      fill_phys   <= 22'd0;
      mreq_q      <= 1'b0;
      mwrite_q    <= 1'b0;
      mline_q     <= 1'b0;
      maddr_q     <= 32'd0;
      mwdata_q    <= 32'd0;
      hits        <= 32'd0;
      misses      <= 32'd0;
      for (int w = 0; w < 4; w++) line_word[w] <= 32'd0;
    end else begin
      // The countdowns run on their own.
      if (free_in != '0) free_in <= free_in - 1'b1;
      if (buf_in  != '0) buf_in  <= buf_in  - 1'b1;
      if (ack_in  != '0) ack_in  <= ack_in  - 1'b1;
      deskewed <= deskew_due;
      mack_q   <= 1'b0;

      if (invalidate) inval_owed <= 1'b1;
      if (take) inval_owed <= 1'b0;

      if (state == GRANTED && !mem_cycle) begin
        if (vco_toggle) begin
          if (!tmr_fell && vco) tmr_fell <= 1'b1;
          else if (tmr_fell && !vco) tmr_rises <= tmr_rises + 4'd1;
        end
        if (nxm_due) begin
          state <= ACKED;
          nxm   <= 1'b1;
        end
      end

      unique case (state)
        IDLE, REQUESTED: begin
          if (!n_memrq) begin
            write <= wrcyc;
            if (mclk) begin
              state       <= GRANTED;
              first       <= 1'b1;
              elapsed     <= 10'd0;
              answered    <= 1'b0;
              answered_at <= 10'd0;
              tmr_fell    <= 1'b0;
              tmr_rises   <= 4'd0;
              nxm         <= 1'b0;
              from_line   <= 1'b0;
            end else begin
              state <= REQUESTED;
            end
          end else if (state == REQUESTED && mclk) begin
            state <= IDLE;
          end
        end

        GRANTED: begin
          first <= 1'b0;
          if (elapsed != 10'h3FF) elapsed <= elapsed + 10'd1;
          if (first) kmem <= is_memory;
          settle <= 1'b0;
          if (decide) begin
            // muir's `memory_cycle`, at the grant: the start is when main
            // memory is free, the done a timing after it, and the write
            // buffer is free when its write is done.  A write's arithmetic
            // is all here.  Of a read's only the hit is: the lookup's answer
            // reaches as few registers as it can in the one tick it has, and
            // a miss is settled a tick later from the answer held.
            if (write) begin
              free_in <= done_in - 1'b1;
              buf_in  <= done_in - 1'b1;
              if (ack_e == CW'(HIT_T) && ready) mack_q <= 1'b1;
              else ack_in <= ack_e - 1'b1;
            end else begin
              mack_q     <= c_hit;
              read_hit_q <= c_hit;
              done_q     <= done_in;
              settle     <= 1'b1;
            end
          end else if (settle) begin
            // The read the edge before looked up: `done_q` is counted from
            // the grant, two edges back.
            if (read_hit_q) hits <= hits + 32'd1;
            else begin
              misses    <= misses + 32'd1;
              free_in   <= done_q - CW'(2);
              ack_in    <= done_q - CW'(2);
              fill_owed <= 1'b1;
              fill_have <= 1'b0;
              fill_phys <= line_phys;
              from_line <= 1'b1;
            end
          end else if (mem_cycle && !first && !acked && !mack_q) begin
            // Waiting: for the count, for the line, for the buffer.
            if (ack_in <= CW'(HIT_T) && ready
                && (write || fill_have || c_fill)) begin
              mack_q <= 1'b1;
            end
          end
          if (acked) begin
            state <= ACKED;
            if (mem_cycle && write) begin
              // Into the buffer, at the acknowledgment.
              wb_valid <= 1'b1;
              wb_sent  <= 1'b0;
              wb_phys  <= line_phys;
              wb_word  <= wdata;
            end
          end else if (answering && !answered) begin
            answered    <= 1'b1;
            answered_at <= elapsed;
          end
        end

        ACKED: begin
          if (n_memrq) state <= IDLE;
        end

        default: state <= IDLE;
      endcase

      // The line, when it comes: its words for the read that missed.
      if (c_fill) begin
        fill_have <= 1'b1;
        for (int w = 0; w < 4; w++) line_word[w] <= mem_rline[32*w +: 32];
      end
      if (state == ACKED && fill_have) begin
        fill_owed <= 1'b0;
        fill_have <= 1'b0;
      end

      // The memory controller: one operation, held until main memory has
      // answered and has let go of its answer.
      unique case (mstate)
        M_IDLE: begin
          if (go_u) begin
            mstate <= M_THROUGH;
          end else if (!mem_done) begin
            if (go_write) begin
              op       <= OP_WRITE;
              mreq_q   <= 1'b1;
              mwrite_q <= 1'b1;
              mline_q  <= 1'b0;
              maddr_q  <= main_byte_address(wb_phys);
              mwdata_q <= wb_word;
              wb_sent  <= 1'b1;
              mstate   <= M_BUSY;
            end else if (go_fill) begin
              op       <= OP_FILL;
              mreq_q   <= 1'b1;
              mwrite_q <= 1'b0;
              mline_q  <= 1'b1;
              maddr_q  <= main_byte_address({fill_phys[21:2], 2'b00});
              mstate   <= M_BUSY;
            end
          end
        end
        M_BUSY: begin
          if (mem_done) begin
            mreq_q <= 1'b0;
            mstate <= M_LET_GO;
            if (op == OP_WRITE) wb_valid <= 1'b0;
          end
        end
        M_THROUGH: begin
          if (!u_req && !mem_done) mstate <= M_IDLE;
        end
        default: begin
          if (!mem_done) mstate <= M_IDLE;
        end
      endcase
    end
  end

endmodule

`default_nettype wire
