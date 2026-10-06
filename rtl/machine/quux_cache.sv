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
// **REVISION 13'S CACHE HAS 8-WORD LINES OF 40-BIT WORDS** (contract G2 §3,
// `WORD_BITS` 40): the lines of packed storage (G1 §4.1), still 4,096 words
// in two ways, over the 28-bit physical space (G1 §3.2):
//
//   256 sets, line = phys[27:3], set = phys[10:3], tag = phys[27:11],
//   word = phys[2:0].
//
// The tag starts at bit 11 in both, a way being 2,048 words.  Its top bits,
// `phys<27:26>`, are the window's alone (`1760000000` up): no main memory
// the boards can hold reaches them.
//
// **AND A SECOND LOOKUP, OF THE NEXT LINE, FOR THE PREFETCH'S PAGE REACH**
// (muir's `Reach::Page`, revision 13's): the tags of the set after the
// grant's, and word 0 of each way's line there, read at the same edge off
// copies of those RAMs, so that `next_line_hit` and `next_line_word` say
// whether the cache holds the line after the grant's and what its first word
// is.  The next line of a page never wraps the set: a page is 1,024 words,
// set 255's last word is `phys<10:0>` all ones, and a word whose next is in
// another page is not looked past.  So the next line's tag is the grant's
// tag and its set is the grant's plus one.  Revision 12 has neither: its
// prefetch keeps to the line (`Reach::Line`), and the two outputs are 0.
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
// `build/quux13_port.quux.pass` compares every read's hit or miss with
// muir's.  A write touches neither the order nor the valid bits
// (`busint.rs`, and muir's port: a write never calls `Cache::read`); a line
// holding the word takes the new word, two ticks after the grant.
//
// **THE VALID BITS ARE FLIP-FLOPS, SO THAT A WHOLE CACHE GOES IN ONE TICK.**
// muir's invalidation is instantaneous, at the request after a block-disk
// register is written, and a sweep of a RAM would move the timing.  1,024
// valid bits and 512 recency bits are 1,536 registers and three 512-way
// read multiplexers; the words and the tags are RAM: eight 512 by 32 (a
// word lane of a way each) and two 512 by 11.  Revision 13's are 512 valid
// bits and 256 recency bits; sixteen 256 by 40 and two 256 by 17, and the
// next line's copies, two 256 by 40 and two 256 by 17.
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
//
// **NO RAM IS READ AT THE EDGE THAT WRITES IT**, and so neither tool's
// read-during-write behavior is relied on: the RAMs are read at `look`, a
// master clock edge the port is idle, and written by a fill or a write's
// update, which happen only inside a cycle.  `CADR_RDW_POISON`, which only
// the read-during-write checks define, makes a read at an edge that writes
// the same set take the complement, and the programs still agree with muir:
// `build/rdw_poison_quux13_mem.quux.k4.pass` on the lines and their fills,
// `build/rdw_poison_quux13_pf.quux.k4.pass` on the next line's copies.

`default_nettype none

module quux_cache #(
    // 32, the CADR's word and QUUX's to revision 12; 40, revision 13's
    // (`cadr_machine.sv`).
    parameter int unsigned WORD_BITS = 32,
    // Revision 14's key, 29 bits: `<28>` = 1 for the device window's frame
    // buffer, 0 for main memory (A14.1).
    parameter bit          PAGED     = 1'b0,
    localparam bit          WIDE      = WORD_BITS > 32,
    localparam int unsigned PHYS_BITS = PAGED ? 29 : WIDE ? 28 : 22,
    localparam int unsigned LINE_WORDS = WIDE ? 8 : 4
) (
    input  var logic         clk,
    input  var logic         rst,

    // The lookup: the RAMs are read at every edge `look` is up --- every
    // master clock edge the port is idle, and at no tick between, whose
    // address is still settling (`quux_mem_port.sv`) --- so the one at the
    // grant takes the grant's address, and the answer is out over the tick
    // after it.  `line_phys` is that address held for the cycle.
    input  var logic         look,
    input  var logic [PHYS_BITS-1:0] look_phys,
    output var logic [PHYS_BITS-1:0] line_phys,
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
    input  var logic [WORD_BITS-1:0] update_word,

    // The word a read hit, over the tick after the decision.  A miss's word
    // is the fill's and the port has it.
    output var logic [WORD_BITS-1:0] word,
    // And the word after it in the same line, which the RAMs put out with
    // it: the cache-only prefetch (`quux_mem_port.sv`).  Its value past the
    // line's last word means nothing.
    output var logic [WORD_BITS-1:0] next_word,
    // Revision 13's page reach: whether a valid way holds the line after the
    // looked-up one, and word 0 of that line.  The valid bits are read as
    // the tick has them, the tags and the word as the lookup's edge read
    // them.  0 on revision 12.
    output var logic         next_line_hit,
    output var logic [WORD_BITS-1:0] next_line_word,

    // The line a miss asked for: written into the victim, its tag with it,
    // and made valid.  Word w in bits `WORD_BITS * w` up.
    input  var logic         fill,
    input  var logic [LINE_WORDS*WORD_BITS-1:0] fill_line,

    // Everything dropped, at the edge `invalidate` is up: muir's
    // `Cache::invalidate`.  And a word block-disk wrote: its set dropped.
    input  var logic         invalidate,
    input  var logic         snoop,
    input  var logic [PHYS_BITS-1:0] snoop_phys,

    // **REVISION 14'S SIDE LOOKUP** (`quux_mmu.sv` through `quux_mem_port.sv`):
    // the walk's reads and the write-back's, with held registers of their
    // own, so that a processor's cycle's set, tag, way and pending fill are
    // never theirs.  The RAMs' one read port is the processor's or the
    // side's in a tick, never both (the port sees to it).  `s_hit` and
    // `s_word` are out over the tick after `slook`; in that tick `s_touch`
    // commits a read to the order as a processor's read does, keeping the
    // way a miss fills (`s_fill`), and `s_update` writes a word into the
    // line that holds it.  Unused, and tied low, below revision 14.
    input  var logic         slook,
    input  var logic [PHYS_BITS-1:0] slook_phys,
    output var logic         s_hit,
    output var logic [WORD_BITS-1:0] s_word,
    input  var logic         s_touch,
    input  var logic         s_fill,
    input  var logic [LINE_WORDS*WORD_BITS-1:0] s_fill_line,
    input  var logic         s_update,
    input  var logic [WORD_BITS-1:0] s_update_word
);

  localparam int unsigned OFF_BITS = WIDE ? 3 : 2;
  localparam int unsigned IDX_BITS = WIDE ? 8 : 9;
  localparam int unsigned SETS     = 1 << IDX_BITS;
  localparam int unsigned TAG_BITS = PHYS_BITS - 11;
  localparam int unsigned WB       = WORD_BITS;

  // A snooped word clears its set, whatever its tag or its place in the line.
  logic unused_snoop;
  assign unused_snoop = ^{snoop_phys[PHYS_BITS-1:11], snoop_phys[OFF_BITS-1:0]};

  // **THE ADDRESS HELD, AND THE RAMS' READ, ARE THE MICROCYCLE'S; EVERY
  // OTHER REGISTER HERE IS THE TICK'S.**  `look_phys` is the far end of the
  // map and arrives late in the microcycle; it is read at every idle master
  // clock edge, so what the grant's edge reads had the whole microcycle, which is what
  // the constraint files give these (the RAMs, `idx_q`, `tag_q` and
  // `off_q`) and nothing else here.  The lookup's answer, read a tick after
  // the grant, is what makes the two-tick hit.
  logic [IDX_BITS-1:0] idx_q;
  logic [TAG_BITS-1:0] tag_q;
  logic [OFF_BITS-1:0] off_q;
  assign line_phys = {tag_q, idx_q, off_q};

  logic [SETS-1:0] valid0, valid1, mru;
  logic [TAG_BITS-1:0] tag0_out, tag1_out;
  logic [WB-1:0] data0_out [LINE_WORDS];
  logic [WB-1:0] data1_out [LINE_WORDS];

  logic v0, v1;
  assign v0 = valid0[idx_q];
  assign v1 = valid1[idx_q];

  // The side lookup's own held address, way and update.
  logic [IDX_BITS-1:0] s_idx_q;
  logic [TAG_BITS-1:0] s_tag_q;
  logic [OFF_BITS-1:0] s_off_q;
  logic s_h0, s_h1, s_way_q, s_victim, s_touch_q, s_upd_q, s_upd_way_q;
  // The set a touch was of, for the order a tick later: the side may look
  // the next address up in the tick it touches.
  logic [IDX_BITS-1:0] s_tidx_q;
  logic [WB-1:0] s_upd_word_q;
  assign s_h0     = valid0[s_idx_q] && (tag0_out == s_tag_q);
  assign s_h1     = valid1[s_idx_q] && (tag1_out == s_tag_q);
  assign s_hit    = s_h0 || s_h1;
  assign s_victim = !valid0[s_idx_q] ? 1'b0 : !valid1[s_idx_q] ? 1'b1 : !mru[s_idx_q];

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
  logic [WB-1:0] upd_word_q;

  // **THE WORD AND THE NEXT ARE CHOSEN FROM THE LINE A TICK EARLY**: the
  // lookup's two lines are out over the tick after the grant, and at the
  // read's decision (`touch`) the word at the offset and the word after it
  // are taken from each way, so that over the second tick only the way is
  // left to choose.  The same words as reading the RAMs' outputs then, and
  // eight lanes fewer between them and `MD`.
  logic [WB-1:0] word0_q, word1_q, next0_q, next1_q;
  always_ff @(posedge clk) begin
    if (touch) begin
      word0_q <= data0_out[off_q];
      word1_q <= data1_out[off_q];
      next0_q <= data0_out[off_q + OFF_BITS'(1)];
      next1_q <= data1_out[off_q + OFF_BITS'(1)];
    end
  end
  assign word = way_q ? word1_q : word0_q;
  assign next_word = way_q ? next1_q : next0_q;
  assign s_word = s_h1 ? data1_out[s_off_q] : data0_out[s_off_q];

  // ------------------------------------------------------------ the RAMs
  //
  // Simple dual-port RAMs, a read port taken at `look` and a write port for
  // the fill and the write-through update; nothing reads a set in the tick
  // it is written (the processor waits for its own cycle), so neither tool's
  // read-during-write behavior is relied on.
  (* ram_style = "block", ramstyle = "M20K" *) logic [TAG_BITS-1:0] tag0_ram [SETS];
  (* ram_style = "block", ramstyle = "M20K" *) logic [TAG_BITS-1:0] tag1_ram [SETS];

  logic [IDX_BITS-1:0] look_idx;
  assign look_idx = look ? look_phys[10:OFF_BITS] : slook_phys[10:OFF_BITS];
  logic look_any;
  assign look_any = look || slook;

  // Which word lanes of which way are written this edge, and with what.
  logic        wr0, wr1, wr_tag;
  logic [LINE_WORDS-1:0] lanes;
  logic [LINE_WORDS*WB-1:0] wr_line;
  logic [IDX_BITS-1:0] widx;
  logic [TAG_BITS-1:0] wtag;
  always_comb begin
    wr0 = 1'b0;
    wr1 = 1'b0;
    wr_tag = 1'b0;
    lanes = '0;
    wr_line = fill_line;
    widx = idx_q;
    wtag = tag_q;
    if (fill) begin
      wr0 = !way_q;
      wr1 = way_q;
      wr_tag = 1'b1;
      lanes = '1;
    end else if (upd_q) begin
      wr0 = !upd_way_q;
      wr1 = upd_way_q;
      lanes = LINE_WORDS'(1) << off_q;
      wr_line = {LINE_WORDS{upd_word_q}};
    end else if (s_fill) begin
      wr0 = !s_way_q;
      wr1 = s_way_q;
      wr_tag = 1'b1;
      lanes = '1;
      wr_line = s_fill_line;
      widx = s_idx_q;
      wtag = s_tag_q;
    end else if (s_upd_q) begin
      wr0 = !s_upd_way_q;
      wr1 = s_upd_way_q;
      lanes = LINE_WORDS'(1) << s_off_q;
      wr_line = {LINE_WORDS{s_upd_word_q}};
      widx = s_idx_q;
    end
  end

  // **THE READ-DURING-WRITE POISON**: under `CADR_RDW_POISON` a RAM read at
  // an edge that writes the set it reads takes the complement of the word,
  // the one tick a board's RAM does not define (see the header).  Nothing
  // else defines it, and a board flow never does.
  logic rdw0, rdw1;
`ifdef CADR_RDW_POISON
  assign rdw0 = look_any && wr0 && (look_idx == widx);
  assign rdw1 = look_any && wr1 && (look_idx == widx);
  longint unsigned n_ram_writes = 0, n_rdw = 0;
  always_ff @(posedge clk) begin
    if (wr0 || wr1) n_ram_writes <= n_ram_writes + 1;
    if (rdw0 || rdw1) n_rdw <= n_rdw + 1;
  end
  // A poison on RAMs nothing wrote tested nothing, so the check that is
  // this rule's for the cache, which alone defines `CADR_RDW_POISON_CACHE`,
  // fails a run that never wrote them.  The other read-during-write checks
  // run programs that touch no main memory.
  final begin
    $display("rdw_poison: the cache's RAMs written at %0d edges, read at one of them %0d times",
             n_ram_writes, n_rdw);
`ifdef CADR_RDW_POISON_CACHE
    if (n_ram_writes == 0)
      $fatal(1, "rdw_poison: the cache's RAMs were never written, so this run measured nothing about them");
`endif
  end
`else
  assign rdw0 = 1'b0;
  assign rdw1 = 1'b0;
`endif

  always_ff @(posedge clk) begin
    if (look_any) begin
      tag0_out <= rdw0 ? ~tag0_ram[look_idx] : tag0_ram[look_idx];
      tag1_out <= rdw1 ? ~tag1_ram[look_idx] : tag1_ram[look_idx];
    end
    if (wr_tag && wr0) tag0_ram[widx] <= wtag;
    if (wr_tag && wr1) tag1_ram[widx] <= wtag;
  end

  // A word lane of each way, a RAM of its own, so that a write-through
  // word is a write of one RAM and a fill a write of all of them.
  for (genvar w = 0; w < LINE_WORDS; w++) begin : g_lane
    (* ram_style = "block", ramstyle = "M20K" *) logic [WB-1:0] d0_ram [SETS];
    (* ram_style = "block", ramstyle = "M20K" *) logic [WB-1:0] d1_ram [SETS];
    always_ff @(posedge clk) begin
      if (look_any) begin
        data0_out[w] <= rdw0 ? ~d0_ram[look_idx] : d0_ram[look_idx];
        data1_out[w] <= rdw1 ? ~d1_ram[look_idx] : d1_ram[look_idx];
      end
      if (wr0 && lanes[w]) d0_ram[widx] <= wr_line[WB*w +: WB];
      if (wr1 && lanes[w]) d1_ram[widx] <= wr_line[WB*w +: WB];
    end
  end

  // ------------------------------------- the next line, revision 13's
  //
  // Copies of the tag RAMs and of lane 0's, each written one set BELOW the
  // set it copies: copy entry k holds set k + 1.  So the lookup's own
  // address reads the next set's line, with no adder between the map's late
  // output and the RAMs, and the write address, `idx_q` less one, is a
  // register's.  A copy and not a second read port of the same RAM: each
  // stays a simple dual-port RAM, which both tools build as one.  Set 0's
  // copy, at entry 255, is never read as a next line: the next line of a
  // page never wraps the set (the header).
  if (WIDE) begin : g_next_line
    (* ram_style = "block", ramstyle = "M20K" *) logic [TAG_BITS-1:0] ntag0_ram [SETS];
    (* ram_style = "block", ramstyle = "M20K" *) logic [TAG_BITS-1:0] ntag1_ram [SETS];
    (* ram_style = "block", ramstyle = "M20K" *) logic [WB-1:0] nd0_ram [SETS];
    (* ram_style = "block", ramstyle = "M20K" *) logic [WB-1:0] nd1_ram [SETS];
    logic [IDX_BITS-1:0] nwr_idx, nidx;
    logic [TAG_BITS-1:0] ntag0_out, ntag1_out;
    logic [WB-1:0]       nd0_out, nd1_out;
    assign nwr_idx = widx - IDX_BITS'(1);
    assign nidx    = idx_q + IDX_BITS'(1);
    logic nrdw0, nrdw1;
`ifdef CADR_RDW_POISON
    assign nrdw0 = look && wr0 && (look_idx == nwr_idx);
    assign nrdw1 = look && wr1 && (look_idx == nwr_idx);
`else
    assign nrdw0 = 1'b0;
    assign nrdw1 = 1'b0;
`endif
    always_ff @(posedge clk) begin
      if (look) begin
        ntag0_out <= nrdw0 ? ~ntag0_ram[look_idx] : ntag0_ram[look_idx];
        ntag1_out <= nrdw1 ? ~ntag1_ram[look_idx] : ntag1_ram[look_idx];
        nd0_out   <= nrdw0 ? ~nd0_ram[look_idx] : nd0_ram[look_idx];
        nd1_out   <= nrdw1 ? ~nd1_ram[look_idx] : nd1_ram[look_idx];
      end
      if (wr_tag && wr0) ntag0_ram[nwr_idx] <= wtag;
      if (wr_tag && wr1) ntag1_ram[nwr_idx] <= wtag;
      if (wr0 && lanes[0]) nd0_ram[nwr_idx] <= wr_line[WB-1:0];
      if (wr1 && lanes[0]) nd1_ram[nwr_idx] <= wr_line[WB-1:0];
    end
    // The valid bits of the next set, from the held set: registers both.
    logic nh0, nh1;
    assign nh0 = valid0[nidx] && (ntag0_out == tag_q);
    assign nh1 = valid1[nidx] && (ntag1_out == tag_q);
    assign next_line_hit  = nh0 || nh1;
    assign next_line_word = nh1 ? nd1_out : nd0_out;
  end else begin : g_line_reach
    assign next_line_hit  = 1'b0;
    assign next_line_word = '0;
  end

  // ----------------------------------------------- the state in registers
  always_ff @(posedge clk) begin
    if (look) begin
      idx_q <= look_idx;
      tag_q <= look_phys[PHYS_BITS-1:11];
      off_q <= look_phys[OFF_BITS-1:0];
    end
    if (slook) begin
      s_idx_q <= slook_phys[10:OFF_BITS];
      s_tag_q <= slook_phys[PHYS_BITS-1:11];
      s_off_q <= slook_phys[OFF_BITS-1:0];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      way_q      <= 1'b0;
      touch_q    <= 1'b0;
      mru_new_q  <= 1'b0;
      upd_q      <= 1'b0;
      upd_way_q  <= 1'b0;
      upd_word_q <= '0;
      valid0     <= '0;
      valid1     <= '0;
      mru        <= '0;
      s_way_q      <= 1'b0;
      s_touch_q    <= 1'b0;
      s_upd_q      <= 1'b0;
      s_upd_way_q  <= 1'b0;
      s_upd_word_q <= '0;
      s_tidx_q     <= '0;
    end else begin
      // The side's commit: the way, the order a tick later, a fill into the
      // way kept, an update into the way that holds the word.
      if (s_touch) begin
        s_way_q  <= s_hit ? s_h1 : s_victim;
        s_tidx_q <= s_idx_q;
      end
      s_touch_q <= s_touch;
      if (s_touch_q) mru[s_tidx_q] <= s_way_q;
      s_upd_q <= s_update && s_hit;
      if (s_update) begin
        s_upd_way_q  <= s_h1;
        s_upd_word_q <= s_update_word;
      end
      if (s_fill) begin
        if (s_way_q) valid1[s_idx_q] <= 1'b1;
        else         valid0[s_idx_q] <= 1'b1;
      end
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
        valid0[snoop_phys[10:OFF_BITS]] <= 1'b0;
        valid1[snoop_phys[10:OFF_BITS]] <= 1'b0;
      end
      if (invalidate) begin
        valid0 <= '0;
        valid1 <= '0;
      end
    end
  end

endmodule

`default_nettype wire
