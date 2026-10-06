// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 14's memory management (contract G3 revision 14, appendix
// A14.1-A14.9): the windows' decode and fixed entries, the TLB's two ports
// and its contents (`quux_tlb.sv`), the walk, the write-backs and their
// guard, the sweep, the `WRITE-MAP` operations, the PDL buffer redirect and
// its snooped copies, the ephemeral-reference setter, and the memory
// system's register-page words 220-227.  muir's `tlb.rs`, `Machine::
// translate_14`, `tlb_fill`, `write_back`, `redirect_14`, `write_map_14` and
// `Rtl::tlb_hold` and `Rtl::write_back` are the reference, and every
// program of `golden/src/quux14.rs` holds this module to them tick for
// tick through the whole machine (`build/quux14_*.quux.*.pass`).
//
// **ITS OWN MODULE, WITH A NARROW SEAM TO THE MICRO-ENGINE.**  What the
// processor gives it is registers (`VMA`, `MD`, `MEMSTART`, `WRCYC`, the PDL
// pointer), a few decoded bits of `IR` and the generator's ticks; what it
// gives back is two entries, the dispatch's map bits, whether the generator
// cycle now running is held, and the redirect's word and index.  The memory
// side is a seam of its own to the memory port (`sd_*`, `wb_*`), through
// which the walk reads and the write-back writes through the cache.  A
// pipelined engine takes the same seam.
//
// **THE HOLD, AND WHEN IT IS DECIDED** (muir's `Rtl::tlb_hold`): before a
// microcycle runs, a start's `MEMSTART` looks up port A at `VMA`, and
// `MAP(MD)` or a map-bit dispatch on a pointer-typed `MD` looks up port B at
// `MD`; while a sweep runs, either waits for its end; a miss walks; and a
// start the redirect serves inside the PDL buffer holds one microcycle.  The
// hold is whole generator cycles, the master clock not running and the bus
// running on, and it is decided inside each generator cycle, from the
// tick after its start: the TLB is read on the generator cycle's first tick
// (`g1`), its answer is out on the second (`g2`), and the cycle is held if a
// sweep or a walk reaches past its start, or the redirect takes it.  `tlbh`
// is that decision, read by the processor on the cycle's last tick, where
// the master clock edge and the cpu edge are then not taken.
//
// **THE TIME IS muir'S ARITHMETIC, AND THE WORDS ARE REAL**: every instant
// is a count of ticks against the tick it is read in, as the memory port's
// countdowns are (`quux_mem_port.sv`): over the tick after an edge e, a
// count holds the instant less e.  The walk's `until` starts at the
// generator cycle's start and moves by the memory port's answer for each
// read, a cache hit's 20 ns or a line fill when main memory is free; the
// cycles that start before it are held.  The reads themselves go through
// the cache and main memory as the port really serves them, and a hold
// never ends before the walk's words are in, the floor the port's own
// countdowns keep.
//
// **WHAT NOTHING HOLDS HERE TICK FOR TICK, AND WHY**: muir translates a
// port-B lookup whose `MD` moved during a `-WAIT` of the same microcycle by
// a walk that neither fills nor takes time (`Rtl::tlb_hold`'s `walked`);
// this module walks, fills and holds for it, as A14.6 asks of every miss.
// The programs keep `MD` still across a lookup.

`default_nettype none

module quux_mmu #(
    // The TLB's entries, N (A14.4); the board's top gives it.
    parameter int unsigned ENTRIES  = 4096,
    parameter int unsigned PDL_BITS = 14,
    // The reset's sweep, its end against the edge `-BOOT` is let go at,
    // in ticks beyond N: muir's `reset_memory_system` at `Rtl::reset`.
    parameter int signed   SWEEP_RESET_ADJ = 2,
    localparam int unsigned K       = $clog2(ENTRIES),
    localparam int unsigned TAG     = 22 - K,
    localparam int unsigned WIDTH   = 1 + TAG + 30
) (
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        n_boot,

    // --- the generator: its last tick (the boundary), whether the machine
    // --- runs at all (`MACHRUN` without `-WAIT`), and the edges taken
    input  var logic        gen_edge,
    input  var logic        machrun_base,
    input  var logic        cpu_edge,
    output var logic        tlbh,

    // --- the processor's registers and decode
    input  var logic        memstart,
    input  var logic        wrcyc,
    input  var logic [39:0] vma,
    input  var logic [39:0] md,
    input  var logic        srcmap_run,     // `MAP(MD)`, not nopped
    input  var logic        map_dispatch,   // a DISPATCH on map bits, not nopped
    input  var logic [PDL_BITS-1:0] pdl_ptr,
    // The start going out at this tick's edge to memory (`MEMGO` at a
    // master clock edge), and the word a write carries, `MD` as the edge
    // leaves it.
    input  var logic        start_go,
    input  var logic [39:0] md_out,
    // A `WRITE-MAP` operation landing at this tick's edge (`WMAPD` at a cpu
    // edge).
    input  var logic        wmap_land,
    // A memory's write pulse, for the redirect's copies.
    input  var logic        a_we,
    input  var logic [9:0]  a_adr,
    input  var logic [31:0] a_data,
    // Main memory's 64K-word boards, for the frame check.
    input  var logic [10:0] boards,

    // --- what the processor reads
    output var logic [29:0] ent_a,          // port A's entry, the redirect's access applied
    output var logic [29:0] ent_b,          // port B's entry, `MAP(MD)<29:0>`
    output var logic [1:0]  map_bits,       // a map-bit dispatch's `<23:22>`
    output var logic        redirect_in,    // the start is served inside the buffer
    output var logic [PDL_BITS-1:0] redirect_idx,
    output var logic        pdl_rd,         // read the PDL buffer at `redirect_idx` this tick
    output var logic        op_drop,        // an operation landing drops the prefetch's word

    // --- the register page's words 220-227 (`quux_feature_page.sv`)
    input  var logic        ms_we,
    input  var logic [2:0]  ms_idx,
    input  var logic [31:0] ms_wdata,
    output var logic [31:0] ms_rdata,

    // --- the memory port's side (`quux_mem_port.sv`)
    output var logic        sd_look,
    output var logic [28:0] sd_phys,
    input  var logic        sd_ready,
    input  var logic        sd_walk_ready,
    input  var logic signed [10:0] sd_ack_at,
    input  var logic        sd_hit,
    input  var logic [39:0] sd_word,
    output var logic        sd_commit,
    output var logic        sd_wr,
    output var logic [39:0] sd_wdata,
    output var logic signed [10:0] sd_until,
    input  var logic signed [10:0] sd_done,
    input  var logic        sd_fill_v,
    input  var logic [39:0] sd_fill_word,
    input  var logic        sd_wdone,
    output var logic        wb_hold,
    output var logic        wb_rel_v,
    output var logic signed [10:0] wb_rel,

    // --- the readout, for a checkpoint (A14.14)
    output var logic [17:0] ro_directory,
    output var logic        ro_ephemeral,
    output var logic [63:0] ro_pointer_types,
    output var logic [31:0] ro_refused,
    output var logic [31:0] ro_pdl_base,
    output var logic [PDL_BITS-1:0] ro_pdl_head
);

  // ------------------------------------------------- the address space
  //
  // A14.1: `VA<31:29>` = `111` the windows, `VA<28>` between them; A memory's
  // window `35700000000`-`35700001777`.  The fixed entries (A14.5).
  localparam logic [29:0] RW_STATUS_4  = {2'b11, 12'o1460, 16'd0} >> 0;
  localparam logic [29:0] FIX_RW4      = 30'(32'b11 << 28 | 32'o1460 << 18);
  localparam logic [29:0] FIX_AMEM     = 30'(32'b11 << 28 | 32'o760 << 18);
  localparam logic [29:0] NO_ENTRY     = 30'(32'o60 << 18);

  // The functions take whole addresses and read the bits they name.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic paged(input logic [31:0] va);
    return va[31:29] != 3'b111;
  endfunction
  function automatic logic [29:0] fixed(input logic [31:0] va);
    if (va[28]) return FIX_RW4 | 30'(va[27:10]);
    if (va[31:10] == 22'(32'o35700000000 >> 10)) return FIX_AMEM;
    return FIX_RW4;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  logic unused_rw;
  assign unused_rw = ^{RW_STATUS_4, vma[39:34]};

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [K-1:0] index(input logic [31:0] va);
    return va[9+K:10];
  endfunction
  function automatic logic [TAG-1:0] tag(input logic [31:0] va);
    return va[31:10+K];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ------------------------------------------- the memory system's words
  logic [17:0] directory;
  logic        ephemeral;
  logic [63:0] pointer_types;
  logic [31:0] refused;
  logic        refuse_now;

  always_comb begin
    unique case (ms_idx)
      3'd0:    ms_rdata = 32'(directory);
      3'd1:    ms_rdata = 32'(ephemeral);
      3'd2:    ms_rdata = pointer_types[31:0];
      3'd3:    ms_rdata = pointer_types[63:32];
      3'd4:    ms_rdata = refused;
      default: ms_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst || !n_boot) begin
      directory     <= 18'd0;
      ephemeral     <= 1'b0;
      pointer_types <= 64'd0;
      refused       <= 32'd0;
    end else begin
      if (refuse_now) refused <= refused + 32'd1;
      if (ms_we) begin
        unique case (ms_idx)
          3'd0:    directory <= ms_wdata[17:0];
          3'd1:    ephemeral <= ms_wdata[0];
          3'd2:    pointer_types[31:0]  <= ms_wdata;
          3'd3:    pointer_types[63:32] <= ms_wdata;
          3'd4:    refused <= 32'd0;
          default: ;
        endcase
      end
    end
  end
  assign ro_directory     = directory;
  assign ro_ephemeral     = ephemeral;
  assign ro_pointer_types = pointer_types;
  assign ro_refused       = refused;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_pointer(input logic [39:0] w);
    return pointer_types[w[37:32]];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ------------------------------------------------ the redirect's copies
  //
  // A14.7: taken in A memory's write pulse at A 430 and 431; -RESET does not
  // clear them, as it does not clear A memory.
  logic [31:0]          pdl_base;
  logic [PDL_BITS-1:0]  pdl_head;
  always_ff @(posedge clk) begin
    if (a_we && a_adr == 10'o430) pdl_base <= a_data;
    if (a_we && a_adr == 10'o431) pdl_head <= a_data[PDL_BITS-1:0];
  end
  assign ro_pdl_base = pdl_base;
  assign ro_pdl_head = pdl_head;

  // ------------------------------------------------------------ the TLB
  logic             ta_en, ta_we, tb_en, tb_we;
  logic [K-1:0]     ta_idx, tb_idx;
  logic [WIDTH-1:0] ta_wdata, tb_wdata, ta_q, tb_q;

  quux_tlb #(.ENTRIES(ENTRIES)) tlb (
      .clk    (clk),
      .a_en   (ta_en),
      .a_we   (ta_we),
      .a_idx  (ta_idx),
      .a_wdata(ta_wdata),
      .a_q    (ta_q),
      .b_en   (tb_en),
      .b_we   (tb_we),
      .b_idx  (tb_idx),
      .b_wdata(tb_wdata),
      .b_q    (tb_q)
  );

  // The ticks of a generator cycle: `g1` its first, the TLB read; `g2` its
  // second, the answer out.  Ticks since its start, for an operation's
  // sweep, whose instant is the start of the microcycle that runs.
  logic g1, g2;
  logic [5:0] since_start;
  always_ff @(posedge clk) begin
    if (rst) begin
      g1 <= 1'b0;
      g2 <= 1'b0;
      since_start <= 6'd0;
    end else begin
      g1 <= gen_edge;
      g2 <= g1;
      since_start <= gen_edge ? 6'd0 : (since_start == 6'h3F ? since_start : since_start + 6'd1);
    end
  end

  // The ports' answers: hit, and the entry.
  logic [31:0] va_a, va_b;
  assign va_a = vma[31:0];
  assign va_b = md[31:0];
  logic hit_a, hit_b;
  assign hit_a = ta_q[WIDTH-1] && ta_q[29+TAG:30] == tag(va_a);
  assign hit_b = tb_q[WIDTH-1] && tb_q[29+TAG:30] == tag(va_b);

  // ------------------------------------------------------- the bypasses
  //
  // What a walk found, for the rest of the microcycle it was made in: the
  // entry it loaded, or the no-entry word it did not (A14.6).  muir looks
  // the TLB up again in every read phase and, finding nothing, walks again
  // with no fill and no time; the entry the walk found is that answer, and
  // the RAM is read again at the next microcycle's start.  Port B's is for
  // the `MD` it walked for.
  logic        byp_a_v, byp_b_v;
  logic [29:0] byp_a, byp_b;
  logic [31:0] byp_b_va;
  logic        walked_a, walked_b, redirect_held;

  logic [29:0] raw_a;
  always_comb begin
    if (!paged(va_a))            raw_a = fixed(va_a);
    else if (byp_a_v)            raw_a = byp_a;
    else if (hit_a)              raw_a = ta_q[29:0];
    else                         raw_a = NO_ENTRY;
  end
  always_comb begin
    if (!paged(va_b))                        ent_b = fixed(va_b);
    else if (byp_b_v && byp_b_va == va_b)    ent_b = byp_b;
    else if (hit_b)                          ent_b = tb_q[29:0];
    else                                     ent_b = NO_ENTRY;
  end

  // ---------------------------------------------------- port B's request
  //
  // `MAP(MD)` always looks up; a map-bit dispatch only for a pointer type
  // (A14.5), and otherwise reads not oldspace, not extra PDL, `11`.
  logic port_b;
  assign port_b   = srcmap_run || (map_dispatch && is_pointer(md));
  assign map_bits = (map_dispatch && is_pointer(md)) ? ent_b[23:22] : 2'b11;

  // ------------------------------------------------------- the redirect
  //
  // A14.7: a start through a status-5 entry whose access code faults it;
  // the test PGF-R-PDL's, unsigned.  The reference then goes on as if the
  // access code were `11`, inside the buffer or outside it.
  logic        fires;
  logic [PDL_BITS-1:0] n_pdl, idx_pdl;
  logic [31:0] off_pdl;
  assign fires   = memstart && paged(va_a) && raw_a[26:24] == 3'd5
                && !(raw_a[27] && (!wrcyc || raw_a[26]));
  assign n_pdl   = PDL_BITS'(pdl_ptr - pdl_head + PDL_BITS'(1));
  assign off_pdl = va_a - pdl_base;
  assign idx_pdl = PDL_BITS'(pdl_head + off_pdl[PDL_BITS-1:0]);
  assign redirect_in  = fires && off_pdl <= 32'(n_pdl);
  assign redirect_idx = idx_pdl;
  assign ent_a = fires ? (raw_a | 30'(3 << 26)) : raw_a;

  // --------------------------------------------- time, in muir's ticks
  //
  // Signed counts of ticks against the tick they are read in: over the
  // tick after an edge e, an instant less e.  They run down a tick a tick
  // and stop at `FLOOR`, which every instant compared with them is past.
  localparam logic signed [10:0] FLOOR = -11'sd512;
  // The cache's hit time, `quux_mem_port.sv`'s and muir's `hit_ns`.
  localparam int unsigned HIT_T = cadr_tick_pkg::ticks(20);
  // The write buffer takes the write-back's word behind the cycle's own.
  logic unused_wdone;
  assign unused_wdone = sd_wdone;
  function automatic logic signed [10:0] down(input logic signed [10:0] v);
    return (v == FLOOR) ? v : v - 11'sd1;
  endfunction
  function automatic logic signed [10:0] smax(input logic signed [10:0] x, input logic signed [10:0] y);
    return (x > y) ? x : y;
  endfunction

  // The sweep's end (A14.4): N ticks after its instant, the reset's or the
  // start of the microcycle whose operation empties the TLB.
  logic signed [16:0] sweep_s;
  // The walk's `until`.
  logic signed [10:0] until_s;

  // ------------------------------------------------------- the walker
  //
  // A14.3, A14.6: the directory entry at `{base<17:2>, VA<31:20>}`, then, if
  // it is present with its frame in main memory, the page entry at `{frame,
  // VA<19:10>}`; no entry for base 0, an absent directory entry, a status 0
  // or 7, or an in-core entry past main memory.  Each read through the
  // cache's side lookup, a hit answered over the tick after its look and
  // the next look made in that same tick, so that a walk of two hits is in
  // the bypass by the start of the generator cycle after the one it holds,
  // muir's 40 ns; a miss waits for its line.  **The directory entry is
  // looked up on the generator cycle's first tick, before the TLB has
  // answered**, for the port that would walk first: a lookup touches
  // nothing, and the walk takes it on the second tick if it walks.
  typedef enum logic [2:0] {W_IDLE, W_DLOOK, W_DRES, W_DWAIT, W_PLOOK, W_PRES, W_PWAIT, W_TLB} wstate_e;
  wstate_e wstate;
  logic        w_port;       // 0 port A, 1 port B
  logic        w_b_queued;   // port B to walk after port A
  logic [31:0] w_va;
  logic [27:0] w_page_at;
  logic [29:0] w_result;
  logic        w_load;
  // Port A's walk this microcycle, for the write-back (A14.6: "When the walk
  // has just read the entry for this reference, it writes at once").
  logic        wk_page_v;
  logic [27:0] wk_page_at;
  logic [39:0] wk_page;
  // The directory entry looked up on `g1`, for which port.
  logic        spec_v, spec_port;

  // Main memory's frames.
  logic [17:0] frames;
  assign frames = 18'({boards, 6'd0});

  // Where a walk reads (A14.3).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [27:0] dir_at(input logic [17:0] base, input logic [31:0] va);
    return {base[17:2], va[31:20]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  // A directory entry present with its frame in main memory; a page entry
  // loaded, and what.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic dir_ok(input logic [39:0] d);
    return d[26:24] == 3'd4 && d[17:0] < frames;
  endfunction
  function automatic logic page_load(input logic [39:0] e);
    return e[26:24] == 3'd1 || (e[26:24] >= 3'd2 && e[26:24] <= 3'd6 && e[17:0] < frames);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  logic unused_words;
  assign unused_words = ^{wk_page[39:30], sd_fill_word[39:30], sd_word[39:30]};

  // --------------------------------------------------- the write-back
  //
  // A14.6, from the grant: the directory entry and the page entry read again
  // through the cache unless port A's walk read them for this reference;
  // the guard; and the page entry written with the bits ORed in, through
  // the line holding it and the write buffer.  Its end is the instant the
  // cycle waits for (`wb_rel`), given in the tick the outcome is known, so
  // that the cycle looks itself up again in that tick and decides in the
  // next: a hit on both entries and the write decide by the fourth tick
  // after the grant, inside the six muir's arithmetic gives them.  A
  // refusal the start can see (no directory, or port A's walk's entry
  // failing the guard) takes no time and holds nothing.
  typedef enum logic [3:0] {B_IDLE, B_DLOOK, B_DRES, B_DWAIT, B_PLOOK, B_PRES, B_PWAIT, B_ULOOK,
                            B_WR} bstate_e;
  bstate_e bstate;
  logic [31:0] b_va;
  logic [17:0] b_frame;      // the TLB entry's frame
  logic [29:0] b_bits;
  logic [27:0] b_page_at;
  logic [39:0] b_page;
  logic signed [10:0] b_t;

  // The guard (A14.6): in core, status 2 to 6, with the TLB entry's frame.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic guard_ok(input logic [39:0] page, input logic [17:0] frame);
    return page[26:24] >= 3'd2 && page[26:24] <= 3'd6 && page[17:0] == frame;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // The bits a start through `ent_a` asks to write back (A14.6, A14.8): a
  // paged reference that goes to memory; accessed when 0, modified on a
  // write when 0, ephemeral-reference on a write of a pointer into
  // ephemeral space with the enable, when 0.
  logic [29:0] wb_bits;
  logic        eph;
  assign eph = ephemeral && is_pointer(md_out) && md_out[31:28] == 4'b1101;
  assign wb_bits = (30'(1 << 28) & ~ent_a)
                 | (wrcyc ? (30'(1 << 29) & ~ent_a) : 30'd0)
                 | ((wrcyc && eph) ? (30'(1 << 19) & ~ent_a) : 30'd0);
  logic wb_go, wb_now_refused;
  assign wb_go   = start_go && paged(va_a) && wb_bits != 30'd0;
  assign wb_now_refused = walked_a ? !(wk_page_v && guard_ok(wk_page, ent_a[17:0]))
                                   : directory == 18'd0;
  assign wb_hold = wb_go && !wb_now_refused;

  // ---------------------------------------------- the hold's decision
  //
  // `held` is the generator cycle now running held: by a sweep or a walk
  // that reaches past its start, as the cycle's first tick sees it, or by a
  // walk or the redirect decided on its second tick.  A walk still going at
  // the cycle's last tick holds it too, the floor (`tlbh`).
  logic held, walking;
  assign walking = wstate != W_IDLE;
  assign tlbh    = held || walking;

  logic need_a, need_b, need_any;
  assign need_a   = memstart && paged(va_a);
  assign need_b   = port_b && paged(va_b);
  assign need_any = memstart || port_b;
  logic walk_a, walk_b;
  assign walk_a = need_a && !hit_a && !walked_a;
  assign walk_b = need_b && !hit_b && !(walked_b && byp_b_va == va_b);

  // The decision on `g2`, and whether it walks with the lookup `g1` made.
  logic start_walk, spec_ok, first_b;
  assign start_walk = g2 && !held && machrun_base && wstate == W_IDLE && directory != 18'd0
                   && (walk_a || walk_b);
  assign first_b    = !walk_a;
  assign spec_ok    = spec_v && spec_port == first_b;
  logic spec_look;
  assign spec_look  = g1 && machrun_base && wstate == W_IDLE && bstate == B_IDLE && directory != 18'd0
                   && sd_walk_ready && !sweeping && ((need_a && !walked_a) || need_b);

  // The TLB's writes this tick: the sweep (both ports), a fill (port A), the
  // write-back's OR (port A, at the grant), an operation (port B, at the cpu
  // edge).  Reads on `g1` alone, and never in a tick that writes.
  logic        sweeping;
  logic [K-2:0] sweep_i;
  logic        fill_now, or_now, op_now;
  logic [1:0]  op;
  assign op      = vma[33:32];
  // An operation lands whatever the TLB is doing; one landing while the
  // sweep still runs on the RAM is the sweep's (an empty restarts it; a
  // direct write or an invalidation there is not built: no microcode makes
  // one within N/2 ticks of an empty or a boot).
  logic op_land;
  assign op_land = wmap_land && paged(va_b) && op != 2'd0;
  assign op_now  = op_land && !sweeping;
  assign op_drop = op_land;
  assign or_now  = wb_go && hit_a && !sweeping;
  assign fill_now = wstate == W_TLB && w_load && !g1;

  always_comb begin
    ta_en = 1'b0; ta_we = 1'b0; ta_idx = index(va_a); ta_wdata = '0;
    tb_en = 1'b0; tb_we = 1'b0; tb_idx = index(va_b); tb_wdata = '0;
    if (sweeping) begin
      ta_en = 1'b1; ta_we = 1'b1; ta_idx = {sweep_i, 1'b0};
      tb_en = 1'b1; tb_we = 1'b1; tb_idx = {sweep_i, 1'b1};
    end else begin
      if (fill_now) begin
        ta_en = 1'b1; ta_we = 1'b1; ta_idx = index(w_va);
        ta_wdata = {1'b1, tag(w_va), w_result};
      end else if (or_now) begin
        ta_en = 1'b1; ta_we = 1'b1; ta_idx = index(va_a);
        ta_wdata = {1'b1, tag(va_a), ta_q[29:0] | wb_bits};
      end else if (g1) begin
        ta_en = 1'b1;
      end
      if (op_now) begin
        tb_en = 1'b1; tb_we = 1'b1; tb_idx = index(va_b);
        tb_wdata = (op == 2'd1) ? {1'b1, tag(va_b), vma[29:0]} : '0;
      end else if (g1) begin
        tb_en = 1'b1;
      end
    end
  end

  // --------------------------------------------------- the side seam
  //
  // The walker in a hold and the write-back at a grant, never at once.
  logic        dres_now, d_first;
  logic [31:0] d_va;
  assign dres_now = (start_walk && spec_ok) || wstate == W_DRES;
  assign d_first  = start_walk;
  assign d_va     = d_first ? (first_b ? va_b : va_a) : w_va;
  logic unused_d_va;
  assign unused_d_va = ^{d_va[31:20], d_va[9:0]};
  always_comb begin
    sd_look   = 1'b0;
    sd_phys   = '0;
    sd_commit = 1'b0;
    sd_until  = until_s;
    if (spec_look) begin
      sd_look = 1'b1;
      sd_phys = 29'(dir_at(directory, (need_a && !walked_a) ? va_a : va_b));
    end
    // The walker.
    if (dres_now) begin
      sd_commit = 1'b1;
      // The walk's first read starts at the generator cycle's start, the
      // edge before `g1`: -1 over `g2`; or, looked up later, at the later
      // of that and the acknowledgment of the cycle that was in flight
      // (clarification 74).  A look on `g1` had none in flight.
      sd_until  = d_first ? -11'sd1 : smax(until_s, sd_ack_at);
      if (sd_hit && dir_ok(sd_word) && sd_walk_ready) begin
        sd_look = 1'b1;
        sd_phys = 29'({sd_word[17:0], d_va[19:10]});
      end
    end else if (wstate == W_DLOOK && sd_walk_ready) begin
      sd_look = 1'b1;
      sd_phys = 29'(dir_at(directory, w_va));
    end else if (wstate == W_PLOOK && sd_walk_ready) begin
      sd_look = 1'b1;
      sd_phys = 29'(w_page_at);
    end else if (wstate == W_PRES) begin
      sd_commit = 1'b1;
    end
    // The write-back's reads.
    unique case (bstate)
      B_DLOOK: if (sd_ready) begin
        sd_look = 1'b1;
        sd_phys = 29'(dir_at(directory, b_va));
      end
      B_DRES: begin
        sd_commit = 1'b1;
        sd_until  = b_t;
        if (sd_hit && dir_ok(sd_word)) begin
          sd_look = 1'b1;
          sd_phys = 29'({sd_word[17:0], b_va[19:10]});
        end
      end
      B_PLOOK, B_ULOOK: if (sd_ready) begin
        sd_look = 1'b1;
        sd_phys = 29'(b_page_at);
      end
      B_PRES: begin
        sd_commit = 1'b1;
        // A write with the read starts when the read is done.
        sd_until  = b_wr_now ? b_t + 11'(HIT_T) : b_t;
      end
      B_WR: sd_until = b_t;
      default: ;
    endcase
  end

  // The write-back's write, and its end in the tick its outcome is known:
  // apart from the block above, as the port's `sd_ready` waits on them.
  logic b_wr_now;
  assign b_wr_now = (bstate == B_PRES && sd_hit && guard_ok(sd_word, b_frame)) || bstate == B_WR;
  assign sd_wr    = b_wr_now;
  // The line the page entry's read has just found takes the write.
  assign sd_wdata = (bstate == B_PRES) ? (sd_word | 40'(b_bits)) : (b_page | 40'(b_bits));
  assign wb_rel_v = (bstate == B_DRES && sd_hit && !dir_ok(sd_word))
                 || (bstate == B_DWAIT && sd_fill_v && !dir_ok(sd_fill_word))
                 || (bstate == B_PRES && sd_hit)
                 || (bstate == B_PWAIT && sd_fill_v && !guard_ok(sd_fill_word, b_frame))
                 || bstate == B_WR;
  // A write's end is the port's answer; a refusal's, its last read's.
  assign wb_rel   = b_wr_now ? sd_done
                  : (bstate == B_DRES) ? sd_done
                  : (bstate == B_PRES) ? b_t + 11'(HIT_T)
                  : b_t;

  // The redirect's PDL read, the tick after the cycle it holds was decided.
  logic redirect_take;
  always_ff @(posedge clk) pdl_rd <= redirect_take;

  // A walk's result: its bypass at once, its fill in `W_TLB`.
  task automatic walk_result(input logic load, input logic [29:0] e);
    w_load   <= load;
    w_result <= load ? e : NO_ENTRY;
    wstate   <= W_TLB;
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      held          <= 1'b0;
      byp_a_v       <= 1'b0;
      byp_b_v       <= 1'b0;
      byp_a         <= '0;
      byp_b         <= '0;
      byp_b_va      <= '0;
      walked_a      <= 1'b0;
      walked_b      <= 1'b0;
      redirect_held <= 1'b0;
      until_s       <= FLOOR;
      wstate        <= W_IDLE;
      w_port        <= 1'b0;
      w_b_queued    <= 1'b0;
      w_va          <= '0;
      w_page_at     <= '0;
      w_result      <= '0;
      w_load        <= 1'b0;
      wk_page_v     <= 1'b0;
      wk_page_at    <= '0;
      wk_page       <= '0;
      spec_v        <= 1'b0;
      spec_port     <= 1'b0;
      bstate        <= B_IDLE;
      b_va          <= '0;
      b_frame       <= '0;
      b_bits        <= '0;
      b_page_at     <= '0;
      b_page        <= '0;
      b_t           <= FLOOR;
      refuse_now    <= 1'b0;
      sweeping      <= 1'b1;
      sweep_i       <= '0;
      sweep_s       <= 17'(ENTRIES) + 17'(SWEEP_RESET_ADJ);
    end else begin
      until_s    <= down(until_s);
      b_t        <= down(b_t);
      sweep_s    <= (sweep_s == -17'sd1024) ? sweep_s : sweep_s - 17'sd1;
      refuse_now <= 1'b0;
      spec_v     <= spec_look;
      if (spec_look) spec_port <= !(need_a && !walked_a);

      // The sweep, two entries a tick (A14.4: N ticks of muir's; it is done
      // in N/2 here, inside the time muir gives it).
      if (sweeping) begin
        sweep_i <= sweep_i + 1'b1;
        if (&sweep_i) sweeping <= 1'b0;
      end

      // ---- the hold's decision, cycle by cycle
      if (g1) begin
        // Held by what reaches past this cycle's start: a walk's `until`, or
        // a sweep a lookup waits for.
        // A walk's reads still going here end past this start, so a second
        // walk queued behind the first holds this cycle before its `until`
        // is known: a read looked up or answered now ends a hit's time on
        // at the least, a wait or a fill later still; but a page entry's hit
        // answered now ends when its `sd_done` says, which may be this
        // start (muir's `until` not past it).
        held <= machrun_base && ((until_s > 11'sd0) || (need_any && sweep_s > 17'sd0)
                                 || (wstate != W_IDLE && wstate != W_TLB
                                     && !(wstate == W_PRES && sd_hit && sd_done <= 11'sd0))
                                 || (wstate == W_TLB && w_b_queued));
      end
      if (g2 && !held && machrun_base && wstate == W_IDLE) begin
        if (walk_a || walk_b) begin
          if (directory == 18'd0) begin
            // No directory: no read, no time, no entry (A14.3).
            if (walk_a) begin
              byp_a_v  <= 1'b1;
              byp_a    <= NO_ENTRY;
              walked_a <= 1'b1;
              wk_page_v <= 1'b0;
            end
            if (walk_b) begin
              byp_b_v  <= 1'b1;
              byp_b    <= NO_ENTRY;
              byp_b_va <= va_b;
              walked_b <= 1'b1;
            end
          end else begin
            held       <= 1'b1;
            w_port     <= first_b;
            w_b_queued <= walk_a && walk_b;
            w_va       <= first_b ? va_b : va_a;
            until_s    <= -11'sd2;
            if (!spec_ok) wstate <= W_DLOOK;
          end
        end else if (fires && redirect_in && !redirect_held) begin
          held          <= 1'b1;
          redirect_held <= 1'b1;
        end
      end

      // ---- the walker
      if (dres_now) begin
        until_s <= sd_done - 11'sd1;
        if (!sd_hit) wstate <= W_DWAIT;
        else if (dir_ok(sd_word)) begin
          w_page_at <= {sd_word[17:0], d_va[19:10]};
          // The page entry looked up now, or once the seam is the walker's.
          wstate    <= sd_walk_ready ? W_PRES : W_PLOOK;
        end else walk_result(1'b0, NO_ENTRY);
      end
      unique case (wstate)
        W_DLOOK: if (sd_walk_ready) wstate <= W_DRES;
        W_DWAIT: begin
          if (sd_fill_v) begin
            if (dir_ok(sd_fill_word)) begin
              w_page_at <= {sd_fill_word[17:0], w_va[19:10]};
              wstate    <= W_PLOOK;
            end else walk_result(1'b0, NO_ENTRY);
          end
        end
        W_PLOOK: if (sd_walk_ready) wstate <= W_PRES;
        W_PRES: begin
          until_s <= sd_done - 11'sd1;
          if (!sd_hit) wstate <= W_PWAIT;
          else begin
            walk_result(page_load(sd_word), sd_word[29:0]);
            if (!w_port) begin
              wk_page_v  <= 1'b1;
              wk_page_at <= w_page_at;
              wk_page    <= sd_word;
            end
          end
        end
        W_PWAIT: begin
          if (sd_fill_v) begin
            walk_result(page_load(sd_fill_word), sd_fill_word[29:0]);
            if (!w_port) begin
              wk_page_v  <= 1'b1;
              wk_page_at <= w_page_at;
              wk_page    <= sd_fill_word;
            end
          end
        end
        W_TLB: begin
          // The fill, unless it is a read tick; the bypass at once.
          if (!w_load || !g1) begin
            if (!w_port) begin
              byp_a_v  <= 1'b1;
              byp_a    <= w_result;
              walked_a <= 1'b1;
            end else begin
              byp_b_v  <= 1'b1;
              byp_b    <= w_result;
              byp_b_va <= w_va;
              walked_b <= 1'b1;
            end
            if (w_b_queued) begin
              w_b_queued <= 1'b0;
              w_port     <= 1'b1;
              w_va       <= va_b;
              wstate     <= W_DLOOK;
            end else begin
              wstate <= W_IDLE;
            end
          end
        end
        default: ;
      endcase

      // ---- the write-back, from the grant (muir's `Rtl::write_back`)
      unique case (bstate)
        B_IDLE: begin
          if (wb_go) begin
            b_va    <= va_a;
            b_frame <= ent_a[17:0];
            b_bits  <= wb_bits;
            b_t     <= 11'sd0;
            if (wb_now_refused) refuse_now <= 1'b1;
            else if (walked_a) begin
              // Port A's walk read the entry: written at once, into the
              // line looked up for it.
              b_page_at <= wk_page_at;
              b_page    <= wk_page;
              bstate    <= B_ULOOK;
            end else begin
              bstate <= B_DLOOK;
            end
          end
        end
        B_DLOOK: if (sd_ready) bstate <= B_DRES;
        B_DRES: begin
          b_t <= sd_done - 11'sd1;
          if (!sd_hit) bstate <= B_DWAIT;
          else if (dir_ok(sd_word)) begin
            b_page_at <= {sd_word[17:0], b_va[19:10]};
            bstate    <= B_PRES;
          end else begin
            refuse_now <= 1'b1;
            bstate     <= B_IDLE;
          end
        end
        B_DWAIT: begin
          if (sd_fill_v) begin
            if (dir_ok(sd_fill_word)) begin
              b_page_at <= {sd_fill_word[17:0], b_va[19:10]};
              bstate    <= B_PLOOK;
            end else begin
              refuse_now <= 1'b1;
              bstate     <= B_IDLE;
            end
          end
        end
        B_PLOOK: if (sd_ready) bstate <= B_PRES;
        B_PRES: begin
          b_t <= sd_done - 11'sd1;
          if (!sd_hit) bstate <= B_PWAIT;
          else begin
            if (!guard_ok(sd_word, b_frame)) refuse_now <= 1'b1;
            bstate <= B_IDLE;
          end
        end
        B_PWAIT: begin
          if (sd_fill_v) begin
            b_page <= sd_fill_word;
            if (guard_ok(sd_fill_word, b_frame)) bstate <= B_ULOOK;
            else begin
              refuse_now <= 1'b1;
              bstate     <= B_IDLE;
            end
          end
        end
        B_ULOOK: if (sd_ready) bstate <= B_WR;
        B_WR: bstate <= B_IDLE;
        default: bstate <= B_IDLE;
      endcase

      // ---- an operation (A14.4): an empty starts the sweep, from the
      // start of the microcycle that runs, N ticks
      if (op_land && op == 2'd3) begin
        sweeping <= 1'b1;
        sweep_i  <= '0;
        sweep_s  <= 17'(ENTRIES) - 17'(since_start) - 17'sd1;
      end

      // ---- the microcycle ends: its walks and its redirect are done with
      if (cpu_edge) begin
        byp_a_v       <= 1'b0;
        byp_b_v       <= 1'b0;
        walked_a      <= 1'b0;
        walked_b      <= 1'b0;
        redirect_held <= 1'b0;
        wk_page_v     <= 1'b0;
      end

      // -RESET: swept, as at power-on, from the edge it is let go at.
      if (!n_boot) begin
        sweeping <= 1'b1;
        sweep_i  <= '0;
        sweep_s  <= 17'(ENTRIES) + 17'(SWEEP_RESET_ADJ);
        held     <= 1'b0;
      end
    end
  end

  assign redirect_take = g2 && !held && machrun_base && wstate == W_IDLE && !(walk_a || walk_b)
                       && fires && redirect_in && !redirect_held;

  // **THE SIDE SEAM HAS ONE MASTER AT A TIME** (clarification 74): from a
  // look to its answer, and through a miss's fill, the seam is the walker's
  // or the write-back's, never both's; the walker reads only once the cycle
  // in flight is acknowledged, after its write-back.  Held on every tick of
  // the checks that build the machine with `CADR_GAP_MONITOR`.
`ifdef CADR_GAP_MONITOR
  logic mon_w_on, mon_b_on;
  assign mon_w_on = spec_look || dres_now
                 || wstate == W_DWAIT || wstate == W_PRES || wstate == W_PWAIT
                 || ((wstate == W_DLOOK || wstate == W_PLOOK) && sd_walk_ready);
  assign mon_b_on = bstate == B_DRES || bstate == B_DWAIT || bstate == B_PRES || bstate == B_PWAIT
                 || bstate == B_WR
                 || ((bstate == B_DLOOK || bstate == B_PLOOK || bstate == B_ULOOK) && sd_ready);
  always_ff @(posedge clk) begin
    if (!rst && mon_w_on && mon_b_on)
      $fatal(1, "quux_mmu: the walker and the write-back both on the side seam");
  end
`endif

endmodule

`default_nettype wire
