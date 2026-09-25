// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's memory port and register decode (contracts Q6 and Q7, revision
// 8): the processor's cycle on a machine with no bus interface and no
// device bus.  muir's `memory_port::MemoryPort` is the reference, and
// `build/quux_port.quux.pass` holds this module to it tick for tick
// (`golden/src/quux_port.rs`).  The cycle goes one of three ways, by the
// held decode of its physical address:
//
//   THE MEMORY BUS, main memory and MONO TV's frame buffer, through the
//   cache (`quux_cache.sv`) to the memory controller below.  A read that
//   hits is answered two ticks after the grant; a miss fills its line and a
//   write goes through, one operation of main memory at a time, at the
//   nominal timing: a line fill in 380 ns, a write in 290, a write
//   acknowledged after the hit time by the write buffer, or when the
//   buffer's last write is done.  `cached` says so to the processor, whose
//   MBUSY and READ IN PROGRESS then fall on the acknowledgment itself
//   (muir's `Ack::cached`).  The frame buffer is DDR at the display's base,
//   where the scanout reads it on its own port; the cache writes through,
//   so every word written reaches it once the write buffer has drained.
//
//   A DEVICE REGISTER, MONO TV's, block-disk's or the register page's:
//   taken at the grant and acknowledged a microcycle on, `K` ticks, with no
//   setup and no deskew, never cached.  The register is asked in the one
//   tick after the grant (`dev_rq`), which is the first tick its own held
//   match has the grant's address, and its word is taken in that tick and
//   held for the strobe.  muir takes it at the grant's instant; the tick
//   between is inside the microcycle the grant starts, which reads nothing
//   of the register, and the acknowledgment is muir's to the tick.
//
//   NOTHING: a decode miss, failing at once, `-MEMACK` in the very tick
//   that takes the request, with `NXM TIMEOUT` for word 101's NXM bit and a
//   word of zero.  No timer.  The held decode has had the address since the
//   tick after the map settled, two ticks into the microcycle before the
//   grant (`cadr_machine.xdc`'s split every-tick registers), so it is good
//   in the tick the request is taken.
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
// uncached requester --- block-disk's transfers, by the memory path's
// bridge (`cadr_xbus_ddr.sv`), which carries nothing of the processor's on
// QUUX.  The order is the coherence: a transfer that reads main memory is
// served after the buffered write, so it sees every word the processor
// wrote before START (the contract's first rule); a line filled before a
// transfer's word is written is dropped from the cache when the word lands
// (`quux_cache.sv`'s `snoop`, the second).  The seam out is the machine's
// `mem_*`, a level held until done as `rtl/plumbing/cadr_axi_master.sv`
// takes it, with `mem_line` asking four words, two 64-bit beats, and the
// whole line back on `mem_rline`.
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
    parameter int unsigned WRITE_T = cadr_tick_pkg::ticks(290),
    // QUUX's microcycle in ticks, the machine's `SYNC_K`: a device
    // register is acknowledged this long after the grant, muir's
    // `cycle_ns(Speed::Normal, false)`, whatever `ILONG` does.
    parameter int unsigned K = 4
) (
    input  var logic         clk,
    input  var logic         rst,

    // The processor's side, as `cadr_busint_xbus.sv` has it on the CADR.
    input  var logic         mclk,
    input  var logic         n_memrq,
    input  var logic         wrcyc,
    input  var logic [21:0]  phys,       // the map's output at the grant
    input  var logic [31:0]  wdata,
    // The held decode: the memory bus (main memory or the frame buffer),
    // or a device register.  Neither is an address nothing answers.  Their
    // OR is good in the tick that takes the request, which is all an empty
    // address needs; which of the two it is, from the first tick after the
    // grant, which is when the frame buffer's own held match has the
    // grant's address (`cadr_memory_path.sv`).
    input  var logic         is_memory,
    input  var logic         is_device,
    output var logic         n_memgrant,
    output var logic         n_memack,
    output var logic         n_loadmd,
    output var logic         timed_out,
    output var logic         cached,     // the cycle is the memory bus's
    output var logic [31:0]  word,       // the word a read brings, any read
    output var logic         busy,

    // The register decode: a device register asked, for one tick, and the
    // word it gives in that tick.
    output var logic         dev_rq,
    output var logic         dev_write,
    input  var logic [31:0]  dev_rdata,

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

  localparam int unsigned HIT_T = cadr_tick_pkg::ticks(20);

  // ------------------------------------------------------- the cycle
  typedef enum logic [1:0] {IDLE, REQUESTED, GRANTED, ACKED} state_e;
  state_e state;
  logic       write;
  logic       first;        // the first tick of GRANTED: the lookup's answer
  logic       kmem;         // the cycle is the memory bus's, from its first tick
  logic       kdev;         // the cycle is a device register's, the same
  logic       nxm;          // the cycle was an address nothing answers
  logic [5:0] elapsed;      // ticks since the grant, for a register's: K is
                            // at most 63 (`quux_phase_gen.sv`)
  logic [31:0] dev_word;    // the register's word, taken when it was asked

  logic take;
  assign take = (state == IDLE || state == REQUESTED) && !n_memrq && mclk;

  // An address nothing answers fails in the tick that takes it.
  logic empty;
  assign empty = take && !is_memory && !is_device;

  // `kmem` and `kdev` are taken at the end of the first tick; in it the
  // held decode itself is read.
  logic mem_cycle, dev_cycle;
  assign mem_cycle = first ? is_memory : kmem;
  assign dev_cycle = first ? (is_device && !is_memory) : kdev;

  logic ack_standing;
  assign ack_standing = (state == ACKED) && !n_memrq;

  // The register, asked once, in the first tick after the grant.
  assign dev_rq    = (state == GRANTED) && first && dev_cycle;
  assign dev_write = write;

  // The memory bus's acknowledgment, a register set at the edge before its
  // instant (`ack_in` below).
  logic mack_q;

  logic acked;
  assign acked = ack_standing || empty
              || (state == GRANTED && mem_cycle && mack_q)
              || (state == GRANTED && dev_cycle && elapsed == 6'(K - 1));

  assign n_memgrant = !(state == GRANTED || state == ACKED);
  assign n_memack   = !acked;
  assign n_loadmd   = !acked;
  assign timed_out  = empty || (ack_standing && nxm);
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
  assign word = (empty || nxm) ? 32'd0
              : dev_cycle      ? dev_word
              : from_line      ? line_word[line_phys[1:0]] : c_word;

  // A write enters the buffer at its acknowledgment, when the one before it
  // has really gone: the count alone is muir's, the flag is the board's.
  logic ready;
  assign ready = !mem_cycle || !write || !wb_valid;

  // ---------------------------------------------- the memory controller
  //
  // **THE UNCACHED REQUESTER PASSES STRAIGHT THROUGH** when main memory is
  // idle and nothing of the cache's waits: `mem_*` are the bridge's own
  // wires then, and its answer is main memory's, with no register between.
  // Block-disk's contract fixes the outcome of a transfer and not its time,
  // so its words wait behind a cache operation in flight without moving
  // anything muir holds.  The cache's own operations are registered.
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
      state       <= IDLE;
      write       <= 1'b0;
      first       <= 1'b0;
      kmem        <= 1'b0;
      kdev        <= 1'b0;
      elapsed     <= 6'd0;
      dev_word    <= 32'd0;
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
      mack_q   <= 1'b0;

      if (invalidate) inval_owed <= 1'b1;
      if (take) inval_owed <= 1'b0;

      // The register's word, in the tick it is asked.
      if (dev_rq) dev_word <= dev_rdata;

      unique case (state)
        IDLE, REQUESTED: begin
          if (!n_memrq) begin
            write <= wrcyc;
            if (mclk) begin
              // An address nothing answers is acknowledged in this tick and
              // stands acknowledged from the edge.
              state       <= empty ? ACKED : GRANTED;
              first       <= !empty;
              elapsed     <= 6'd0;
              kmem        <= 1'b0;
              kdev        <= 1'b0;
              nxm         <= empty;
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
          if (elapsed != 6'h3F) elapsed <= elapsed + 6'd1;
          if (first) begin
            kmem <= is_memory;
            kdev <= is_device && !is_memory;
          end
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
              maddr_q  <= quux_byte_address(wb_phys);
              mwdata_q <= wb_word;
              wb_sent  <= 1'b1;
              mstate   <= M_BUSY;
            end else if (go_fill) begin
              op       <= OP_FILL;
              mreq_q   <= 1'b1;
              mwrite_q <= 1'b0;
              mline_q  <= 1'b1;
              maddr_q  <= quux_byte_address({fill_phys[21:2], 2'b00});
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
