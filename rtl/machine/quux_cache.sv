// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's memory cache (contract Q6, revision 7): 4,096 words of main memory
// in lines of four, two ways to a set, write-through, allocating on a read
// miss and never on a write.  muir's `cache::Cache` is the reference for
// which lines are held and in what order; muir holds tags only, and this
// holds the words too, which is the contract's "timing plus that
// coherence".  `rtl/machine/quux_mem_port.sv` runs it: when to look, what a
// cycle does with the answer, and when main memory's words arrive.
//
//   512 sets, line = phys[21:2], set = phys[10:2], tag = phys[21:11],
//   word = phys[1:0].
//
// **THE LOOKUP IS TWO TICKS, AND THE FIRST IS THE RAM'S.**  At the edge the
// port takes a cycle (`look`), the tag and data RAMs take the set's address
// off `look_phys` --- the map's output, which has had the whole microcycle
// --- and over the tick after it both ways' tags and lines are out.  The
// tags are compared with the held tag and the valid bits over that tick
// (`hit`, `victim`); the port registers what it decides at the next edge
// (`touch`), and over the second tick `word` is the word of the way that
// hit, off the RAM's output, which holds until the next lookup.  So a hit is
// answered two ticks after its grant: muir's `hit_ns`, 20 ns.
//
// **REPLACEMENT IS muir'S `Vec`, EXACTLY.**  muir keeps each set's lines in
// recency order and truncates to two on a miss: a hit moves its line to the
// front, a miss inserts the new line at the front and drops the last.  Here
// a set has two valid bits and the way most recently used: a miss fills an
// invalid way if one is, else the way NOT most recently used, and whatever
// is filled or hit becomes the most recent.  The two descriptions hold the
// same lines in every order two ways allow, invalidations included, and
// `build/quux_port.quux.pass` compares every read's hit or miss with
// muir's.  A write touches neither the order nor the valid bits
// (`busint.rs`, and muir's port: a write never calls `Cache::read`); a line
// holding the word takes the new word, two ticks after the grant.
//
// **THE VALID BITS ARE FLIP-FLOPS, SO THAT A WHOLE CACHE GOES IN ONE TICK.**
// muir's invalidation is instantaneous, at the request after a block-disk
// register is written, and a sweep of a RAM would move the timing.  1,024
// valid bits and 512 recency bits are 1,536 registers and three 512-way
// read multiplexers; the words and the tags are RAM: eight 512 by 32 (a
// word lane of a way each) and two 512 by 11.
//
// **A WORD WRITTEN BEHIND THE PROCESSOR'S BACK CLEARS ITS SET**
// (`snoop`): block-disk's transfers reach main memory through the port's
// uncached requester, and a line holding a word from before one must not be
// hit after it (the contract's second coherence rule).  Clearing both ways
// of the set, rather than comparing the tag, costs a miss on a line that
// shared the set and was not written; muir invalidates the whole cache for
// the same transfer, so the lines lost here are ones muir has lost too
// unless the processor refilled them while the transfer ran --- a timing
// difference and never a word.

`default_nettype none

module quux_cache (
    input  var logic         clk,
    input  var logic         rst,

    // The lookup: the RAMs are read at every edge `look` is up --- every
    // edge the port is idle --- so the one at the grant takes the grant's
    // address, and the answer is out over the tick after it.  `line_phys` is
    // that address held for the cycle.
    input  var logic         look,
    input  var logic [21:0]  look_phys,
    output var logic [21:0]  line_phys,
    output var logic         hit,       // a valid way holds the line
    output var logic         hit_way,   // and which
    output var logic         victim,    // the way a miss would fill

    // At the edge ending the tick the answer is out: a read's decision.
    // `touch` moves the order (a read of main memory, hit or miss); `miss`
    // says which, so the victim is kept for the fill.
    input  var logic         touch,
    input  var logic         touch_miss,
    // A write's word, into the way that holds the line if one does; taken
    // at the same edge, written a tick later.
    input  var logic         update,
    input  var logic [31:0]  update_word,

    // The word a read hit, over the tick after the decision.  A miss's word
    // is the fill's and the port has it.
    output var logic [31:0]  word,

    // The line a miss asked for: written into the victim, its tag with it,
    // and made valid.
    input  var logic         fill,
    input  var logic [127:0] fill_line,

    // Everything dropped, at the edge `invalidate` is up: muir's
    // `Cache::invalidate`.  And a word block-disk wrote: its set dropped.
    input  var logic         invalidate,
    input  var logic         snoop,
    input  var logic [21:0]  snoop_phys
);

  localparam int unsigned SETS = 512;

  // A snooped word clears its set, whatever its tag or its place in the line.
  logic unused_snoop;
  assign unused_snoop = ^{snoop_phys[21:11], snoop_phys[1:0]};

  // **THE ADDRESS HELD, AND THE RAMS' READ, ARE THE MICROCYCLE'S; EVERY
  // OTHER REGISTER HERE IS THE TICK'S.**  `look_phys` is the far end of the
  // map and arrives late in the microcycle; it is read at every idle edge,
  // so what the grant's edge reads had the whole microcycle, which is what
  // the constraint files give these (the RAMs, `idx_q`, `tag_q` and
  // `off_q`) and nothing else here.  The lookup's answer, read a tick after
  // the grant, is what makes the two-tick hit.
  logic [8:0]  idx_q;
  logic [10:0] tag_q;
  logic [1:0]  off_q;
  assign line_phys = {tag_q, idx_q, off_q};

  logic [SETS-1:0] valid0, valid1, mru;
  logic [10:0] tag0_out, tag1_out;
  logic [31:0] data0_out [4];
  logic [31:0] data1_out [4];

  logic v0, v1;
  assign v0 = valid0[idx_q];
  assign v1 = valid1[idx_q];

  logic h0, h1;
  assign h0  = v0 && (tag0_out == tag_q);
  assign h1  = v1 && (tag1_out == tag_q);
  assign hit = h0 || h1;
  assign hit_way = h1;
  assign victim  = !v0 ? 1'b0 : !v1 ? 1'b1 : !mru[idx_q];

  // The decision, held for the word and for the fill.
  logic way_q;       // the way hit, or the victim of a miss
  logic touch_q, mru_new_q;
  logic upd_q, upd_way_q;
  logic [31:0] upd_word_q;

  assign word = way_q ? data1_out[off_q] : data0_out[off_q];

  // ------------------------------------------------------------ the RAMs
  //
  // Ten simple dual-port RAMs, a read port taken at `look` and a write port
  // for the fill and the write-through update; nothing reads a set in the
  // tick it is written (the processor waits for its own cycle), so neither
  // tool's read-during-write behavior is relied on.
  (* ram_style = "block", ramstyle = "M20K" *) logic [10:0] tag0_ram [SETS];
  (* ram_style = "block", ramstyle = "M20K" *) logic [10:0] tag1_ram [SETS];

  logic [8:0] look_idx;
  assign look_idx = look_phys[10:2];

  // Which word lanes of which way are written this edge, and with what.
  logic        wr0, wr1;
  logic [3:0]  lanes;
  logic [127:0] wr_line;
  always_comb begin
    wr0 = 1'b0;
    wr1 = 1'b0;
    lanes = 4'b0000;
    wr_line = fill_line;
    if (fill) begin
      wr0 = !way_q;
      wr1 = way_q;
      lanes = 4'b1111;
    end else if (upd_q) begin
      wr0 = !upd_way_q;
      wr1 = upd_way_q;
      lanes = 4'b0001 << off_q;
      wr_line = {4{upd_word_q}};
    end
  end

  always_ff @(posedge clk) begin
    if (look) begin
      tag0_out <= tag0_ram[look_idx];
      tag1_out <= tag1_ram[look_idx];
    end
    if (fill && !way_q) tag0_ram[idx_q] <= tag_q;
    if (fill &&  way_q) tag1_ram[idx_q] <= tag_q;
  end

  // A word lane of each way, a RAM of its own, so that a write-through
  // word is a write of one RAM and a fill a write of four.
  for (genvar w = 0; w < 4; w++) begin : g_lane
    (* ram_style = "block", ramstyle = "M20K" *) logic [31:0] d0_ram [SETS];
    (* ram_style = "block", ramstyle = "M20K" *) logic [31:0] d1_ram [SETS];
    always_ff @(posedge clk) begin
      if (look) begin
        data0_out[w] <= d0_ram[look_idx];
        data1_out[w] <= d1_ram[look_idx];
      end
      if (wr0 && lanes[w]) d0_ram[idx_q] <= wr_line[32*w +: 32];
      if (wr1 && lanes[w]) d1_ram[idx_q] <= wr_line[32*w +: 32];
    end
  end

  // ----------------------------------------------- the state in registers
  always_ff @(posedge clk) begin
    if (look) begin
      idx_q <= look_idx;
      tag_q <= look_phys[21:11];
      off_q <= look_phys[1:0];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      way_q      <= 1'b0;
      touch_q    <= 1'b0;
      mru_new_q  <= 1'b0;
      upd_q      <= 1'b0;
      upd_way_q  <= 1'b0;
      upd_word_q <= 32'd0;
      valid0     <= '0;
      valid1     <= '0;
      mru        <= '0;
    end else begin
      upd_q <= update && hit;
      if (update) begin
        upd_way_q  <= hit_way;
        upd_word_q <= update_word;
      end
      // The way for the word and the fill at once; the order a tick later,
      // from the answer held, so that the lookup reaches as few registers as
      // it can in its tick.  Nothing looks the set up before then.
      if (touch) way_q <= touch_miss ? victim : hit_way;
      touch_q <= touch;
      if (touch) mru_new_q <= touch_miss ? victim : hit_way;
      if (touch_q) mru[idx_q] <= mru_new_q;
      if (fill) begin
        if (way_q) valid1[idx_q] <= 1'b1;
        else       valid0[idx_q] <= 1'b1;
      end
      if (snoop) begin
        valid0[snoop_phys[10:2]] <= 1'b0;
        valid1[snoop_phys[10:2]] <= 1'b0;
      end
      if (invalidate) begin
        valid0 <= '0;
        valid1 <= '0;
      end
    end
  end

endmodule

`default_nettype wire
