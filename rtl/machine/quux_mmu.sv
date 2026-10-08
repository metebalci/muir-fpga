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
// pointer), the next values of `VMA` and `MD` (their registers' D), a few
// decoded bits of `IR` and the generator's ticks; what it gives back is two
// entries, the dispatch's map bits, whether the generator cycle now running
// is held, and the redirect's word and index.  The memory side is a seam of
// its own to the memory port (`sd_*`, `wb_*`), through which the walk reads
// and the write-back writes through the cache.  A pipelined engine takes the
// same seam.
//
// **THE TLB IS READ AT THE EDGE** (A14.4, A14.5): at every generator cycle's
// last tick (`gen_edge`), port A at `VMA`'s next value and port B at `MD`'s,
// so that its word is out from the next cycle's first tick, as the edge's
// own registers are, and has their time.  MD moves only on such a tick on
// QUUX, so a `MD` that a cycle the TLB holds brings in is looked up again at
// the next one's edge.  **ITS WRITES ARE OFF THE EDGE**: the write-back's OR
// and a `WRITE-MAP` operation, which land at the edge, are taken there into
// registers of the edge (`e_or_*`, `e_op_*`) and written two ticks on, and a
// walk's fill on the first tick after its end that is not an edge; and the
// write landing at an edge, or still pending across it, is forwarded to
// that edge's read of the same index (`e_fa_*`, `e_fb_*`), so every read
// sees the entry as written at the edge that ended the microcycle before.
// No read is made while the sweep runs, and none in a tick that writes.
//
// **THE HOLD, AND WHEN IT IS DECIDED** (muir's `Rtl::tlb_hold`): before a
// microcycle runs, a start's `MEMSTART` looks up port A at `VMA`, and
// `MAP(MD)` or a map-bit dispatch on a pointer-typed `MD` looks up port B at
// `MD`; while a sweep runs, either waits for its end; a miss walks; and a
// start the redirect serves inside the PDL buffer holds one microcycle.  The
// hold is whole generator cycles, the master clock not running and the bus
// running on, and it is decided inside each generator cycle: on its first
// tick (`g1`) from muir's arithmetic and a walk still going, and on its
// second (`g2`) for a walk or the redirect the TLB's answer starts.  `tlbh`
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
// never ends before the walk's entry is in, the floor below.
//
// **THE SIDE SEAM'S ANSWER IS A REGISTER** (`quux_mem_port.sv`): a look on
// tick t is answered by the cache over t + 1, and the walk and the write-back
// act on it over t + 2, from registers: the next look's address, the
// countdowns and every decision.  Two things alone take the answer over
// t + 1 itself: **THE WALK'S ENTRY**, written into its result in the tick of
// its last answer (`r_set`), so that a walk of two hits looked up on a
// generator cycle's first tick has its entry by the start of the cycle
// after it, muir's 40 ns at K = 4; and the cache's re-read of the waiting
// cycle's own line in each write-back answer's tick (`sd_relook`), so that
// a write-back's end decides the cycle in the tick its answer is a register.
//
// **THE WALK'S ENTRY STANDS FOR THE REST OF THE MICROCYCLE** (A14.6): muir
// looks the TLB up again in every read phase and, finding nothing, walks
// again with no fill and no time; the entry the walk found is that answer.
// The datapath takes it from registers of the edge (`e_bpa_*`, `e_bpb_*`),
// loaded at each edge of the microcycle from the walk's result, so that it
// is as old as the TLB's word whenever a cycle runs.  A walk whose entry is
// not in at a generator cycle's start holds that cycle (`walk_open`), and
// the checks built with `CADR_GAP_MONITOR` fail if a result is ever
// written inside a cycle that runs.
//
// **WHAT IS BUILT, AND WHERE PORT B WAITS LONGER THAN muir'S**: a walk's
// fill pending across an edge is forwarded to port B's read there, muir's
// entry for an `MD` that changes, in a cycle the walk holds, to the page
// being walked at that edge.  A fill made in that edge's own tick is not
// (it would put `MD`'s next value in the cache's answer's tick): when `MD`
// moves at that edge to another word of the walked page, which a program
// can bring about, port B walks the page again.  And port B's walk queued
// behind port A's (`w_b_queued`) still runs after A's fill has made B's
// lookup hit.  Each holds port B a walk longer than muir does; revision
// 15's memory management (`quux15_mmu.sv`) has neither.
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

    // --- the generator: its last tick (the boundary), the tick before it,
    // --- whether the machine runs at all (`MACHRUN` without `-WAIT`), and
    // --- the edges taken
    input  var logic        gen_edge,
    input  var logic        gen_pre,
    input  var logic        machrun_base,
    input  var logic        cpu_edge,
    output var logic        tlbh,

    // --- the processor's registers and decode
    input  var logic        memstart,
    input  var logic        wrcyc,
    input  var logic [39:0] vma,
    input  var logic [39:0] md,
    // `VMA`'s and `MD`'s next values, what their registers take at this
    // tick's end: the TLB's addresses at the edge.
    input  var logic [31:0] vma_nx,
    input  var logic [31:0] md_nx,
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
    // That, and the word's index in the buffer, as the tick before left
    // them, for the PDL buffer's port, which is enabled on every tick
    // (`cadr_microcycle.sv`): constant over a generator cycle, so the
    // edge's own.
    output var logic        redirect_in_q,
    output var logic [PDL_BITS-1:0] redirect_idx_q,
    output var logic        pdl_rd,         // read the PDL buffer at `redirect_idx_q` this tick
    output var logic        op_drop,        // an operation landing drops the prefetch's word

    // --- the register page's words 220-227 (`quux_feature_page.sv`)
    input  var logic        ms_we,
    input  var logic [2:0]  ms_idx,
    input  var logic [31:0] ms_wdata,
    output var logic [31:0] ms_rdata,

    // --- the memory port's side (`quux_mem_port.sv`): `sd_hit`, `sd_word`,
    // `sd_fill_v` and `sd_fill_word` are registers, the answer of the tick
    // before; `sd_hit_live` and `sd_word_live` the cache's own over the tick
    // after a look.
    output var logic        sd_look,
    output var logic [28:0] sd_phys,
    input  var logic        sd_ready,
    input  var logic        sd_walk_ready,
    input  var logic        sd_grant_ready,
    input  var logic signed [10:0] sd_ack_at,
    input  var logic        sd_hit,
    input  var logic [39:0] sd_word,
    input  var logic        sd_hit_live,
    input  var logic        sd_h1_live,
    input  var logic [39:0] sd_word0_live,
    input  var logic [39:0] sd_word1_live,
    output var logic        sd_commit,
    output var logic        sd_wr,
    output var logic [39:0] sd_wdata,
    output var logic [29:0] sd_wbits,
    output var logic signed [10:0] sd_until,
    input  var logic signed [10:0] sd_done,
    input  var logic        sd_fill_v,
    input  var logic [39:0] sd_fill_word,
    input  var logic        sd_wdone,
    output var logic        sd_relook,
    // The write-back's hold, a register of the grant's edge, up from the
    // tick after it; and its end.
    output var logic        wb_hold,
    output var logic        wb_rel_v,
    output var logic        wb_rel_now,
    output var logic signed [10:0] wb_rel,
    // A refusal's end on a registered answer, a register: `wb_rel` whenever
    // `wb_rel_now` is up, given apart so that the cycle's decision in that
    // tick has it from a register and never through the side's answer.
    output var logic signed [10:0] wb_rel_q,

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
  logic        refuse_now, refuse_p;

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
      if (refuse_p) refused <= refused + 32'd1;
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

  // The ticks of a generator cycle: `g1` its first, `g2` its second.  Ticks
  // since its start, for an operation's sweep, whose instant is the start of
  // the microcycle that runs.
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

  logic [31:0] va_a, va_b;
  assign va_a = vma[31:0];
  assign va_b = md[31:0];

  // The sweep (A14.4) runs on the RAM alone; declared here, run below.
  logic        sweeping;
  logic [K-2:0] sweep_i;

  // **THE PORTS' WORDS** (R1): the RAM's, read at the edge, or the write
  // that edge forwarded (`e_f*_v`), whose hit is taken there against the
  // next value's tag.
  logic             e_fa_v, e_fb_v, e_fa_hit, e_fb_hit;
  logic [29:0]      e_fa_ent, e_fb_ent;
  logic             hit_a, hit_b;
  logic [29:0]      qa_ent, qb_ent;
  assign hit_a  = e_fa_v ? e_fa_hit : (ta_q[WIDTH-1] && ta_q[29+TAG:30] == tag(va_a));
  assign hit_b  = e_fb_v ? e_fb_hit : (tb_q[WIDTH-1] && tb_q[29+TAG:30] == tag(va_b));
  assign qa_ent = e_fa_v ? e_fa_ent : ta_q[29:0];
  assign qb_ent = e_fb_v ? e_fb_ent : tb_q[29:0];

  // ------------------------------------------------------- the bypasses
  //
  // What a walk found, for the rest of the microcycle it was made in: the
  // entry it loaded, or the no-entry word it did not (A14.6).  The walk
  // writes its result (`ra`, `rb`, port B's for the `MD` it walked for) in
  // the tick of its last answer; the datapath reads the edge's copies
  // (`e_bpa_*`, `e_bpb_*`), port B's match against `MD` taken at the edge
  // too, so that no 32-bit compare stands in `MAP(MD)`'s path (R2).
  logic        ra_v, rb_v, walked_a, walked_b, redirect_held;
  logic [29:0] ra, rb;
  logic [31:0] rb_va;
  logic        e_bpa_v, e_bpb_v;
  logic [29:0] e_bpa, e_bpb;

  // **THE HIT IS THE LAST SELECT** (R2): the window's fixed entry, the
  // walk's and the no-entry word are chosen from registers before the RAM's
  // word is out.
  logic [29:0] raw_a, pre_a, pre_b;
  logic        use_a, use_b;
  assign pre_a = !paged(va_a) ? fixed(va_a) : e_bpa_v ? e_bpa : NO_ENTRY;
  assign use_a = paged(va_a) && !e_bpa_v;
  assign raw_a = (use_a && hit_a) ? qa_ent : pre_a;
  assign pre_b = !paged(va_b) ? fixed(va_b) : e_bpb_v ? e_bpb : NO_ENTRY;
  assign use_b = paged(va_b) && !e_bpb_v;
  assign ent_b = (use_b && hit_b) ? qb_ent : pre_b;

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
  logic [PDL_BITS-1:0] n_pdl, idx_pdl, redirect_idx;
  logic [31:0] off_pdl;
  assign fires   = memstart && paged(va_a) && raw_a[26:24] == 3'd5
                && !(raw_a[27] && (!wrcyc || raw_a[26]));
  assign n_pdl   = PDL_BITS'(pdl_ptr - pdl_head + PDL_BITS'(1));
  assign off_pdl = va_a - pdl_base;
  assign idx_pdl = PDL_BITS'(pdl_head + off_pdl[PDL_BITS-1:0]);
  assign redirect_in  = fires && off_pdl <= 32'(n_pdl);
  assign redirect_idx = idx_pdl;
  assign ent_a = fires ? (raw_a | 30'(3 << 26)) : raw_a;

  // **THE REDIRECT'S PORT FROM REGISTERS** (R5): every input of the two
  // above moves only at an edge, so the tick before an edge has the edge's
  // values; the PDL buffer, enabled on every tick, takes these.
  always_ff @(posedge clk) begin
    redirect_in_q  <= redirect_in;
    redirect_idx_q <= redirect_idx;
  end

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
  // cache's side lookup: looked on a tick (`W_DLOOK`, `W_PLOOK`), answered
  // by the cache over the next (`W_DANS`, `W_PANS`), and acted on over the
  // one after from the registered answer (`W_DRES`, `W_PRES`), the next look
  // made there; a miss waits for its line (`W_DWAIT`, `W_PWAIT`).  **The
  // directory entry is looked up on the generator cycle's first tick**, for
  // the port that misses, the TLB having answered at the edge; the walk
  // takes it on the second tick if it walks.  So a walk of two hits is in
  // the result at the end of the cycle's fourth tick, muir's 40 ns.
  typedef enum logic [3:0] {W_IDLE, W_DLOOK, W_DANS, W_DRES, W_DWAIT, W_PLOOK, W_PANS, W_PRES,
                            W_PWAIT} wstate_e;
  wstate_e wstate;
  logic        w_port;       // 0 port A, 1 port B
  logic        w_b_queued;   // port B to walk after port A
  logic [31:0] w_va;
  logic [27:0] w_page_at;
  logic        w_first;      // the directory read looked on the cycle's first tick
  logic        w_done;       // the walk's result is written
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
  assign unused_words = ^{wk_page[39:30], f_word[39:30], sd_word[39:30], sd_word0_live[39:30],
                          sd_word1_live[39:30]};

  // **WHAT AN ANSWER DECIDES, TAKEN IN ITS OWN TICK** (R3): the directory
  // entry's presence and the guard, from the cache's answer over the tick
  // after a look, as registers beside the answer itself; and a line's word,
  // with the same three, a tick after it is given.  The walk and the
  // write-back act on these.
  logic        lv_dok, lv_gok;
  // The cache's answer over the tick after a look, each way's word decided
  // on before the hit chooses the way: the walk's entry and the two tests
  // a tick sooner than through the chosen word.
  logic        live_dok, live_gok, live_load;
  logic [29:0] live_val;
  assign live_dok  = sd_h1_live ? dir_ok(sd_word1_live) : dir_ok(sd_word0_live);
  assign live_gok  = sd_h1_live ? guard_ok(sd_word1_live, b_frame) : guard_ok(sd_word0_live, b_frame);
  assign live_load = sd_h1_live ? page_load(sd_word1_live) : page_load(sd_word0_live);
  assign live_val  = sd_h1_live ? sd_word1_live[29:0] : sd_word0_live[29:0];
  logic        f_v, f_dok, f_gok, f_load;
  logic [39:0] f_word;

  // --------------------------------------------------- the write-back
  //
  // A14.6, from the grant: the directory entry and the page entry read again
  // through the cache unless port A's walk read them for this reference;
  // the guard; and the page entry written with the bits ORed in, through
  // the line holding it and the write buffer.  Its end is the instant the
  // cycle waits for (`wb_rel`), given in the tick the outcome is a register,
  // so that the cycle decides in that tick, its own line read again by the
  // cache in the tick before (`sd_relook`); a write decides in the tick
  // after its own, which the write buffer's countdown takes it in.  So a
  // refusal on the directory entry decides by the third tick after the
  // grant, of the four muir's arithmetic gives it, one by the guard by the
  // fifth of its six, a write after both reads by the sixth of its eight,
  // and port A's walked entry's write by the third of its four.  A refusal
  // the start can see (no directory, or port A's walk's entry failing the
  // guard) takes no time and holds nothing.
  //
  // **THE GRANT IS A REGISTER OF ITS EDGE** (R4): what the start asks to
  // write back depends on the TLB's word and on `MD` as the edge leaves it,
  // which have the microcycle; it is taken at the master clock edge into
  // `e_go`, `e_ref`, `e_bits` and `e_frame`, and the write-back's machine
  // starts from them on the next tick (`st1`), where the cache is looked up
  // for every start the edge took, a lookup touching nothing until it is
  // committed.
  typedef enum logic [3:0] {B_IDLE, B_DLOOK, B_DANS, B_DRES, B_DWAIT, B_PLOOK, B_PANS, B_PRES,
                            B_PWAIT, B_ULOOK, B_WR} bstate_e;
  bstate_e bstate;
  logic [31:0] b_va;
  logic        b_ul;         // port A's walk read the entry: write it at once
  logic [17:0] b_frame;      // the TLB entry's frame
  logic [29:0] b_bits;
  logic [27:0] b_page_at;
  logic [39:0] b_page;
  logic signed [10:0] b_t;
  logic        st1;          // the tick after an edge that took a start out
  logic        e_go, e_ref;
  logic [29:0] e_bits;
  logic [17:0] e_frame;

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
  assign wb_hold = e_go;

  // ---------------------------------------------- the hold's decision
  //
  // `held` is the generator cycle now running held: by a sweep or a walk
  // that reaches past its start in muir's time, or by a walk whose entry
  // was not in at its start, as the cycle's first tick sees them, or by a
  // walk or the redirect decided on its second tick.  A walk's entry still
  // to come at the cycle's last tick, or written after its start, holds it
  // too, the floor (`tlbh`).
  logic held, walk_open, res_mid;
  assign walk_open = wstate != W_IDLE && !w_done;
  assign tlbh      = held || walk_open;

  logic need_a, need_b, need_any;
  assign need_a   = memstart && paged(va_a);
  assign need_b   = port_b && paged(va_b);
  assign need_any = memstart || port_b;
  logic walk_a, walk_b;
  assign walk_a = need_a && !hit_a && !walked_a;
  assign walk_b = need_b && !hit_b && !(walked_b && rb_va == va_b);

  // The TLB's answer, out from `g1`, decides on `g1` which ports walk and
  // whether the redirect takes the start, as registers (`d_*`): every input
  // of those is constant over the generator cycle, so `g2` acts on the same
  // decision a tick later, from registers.
  logic d_wa, d_wb, d_redir;
  // The decision on `g2`, and whether it walks with the lookup `g1` made.
  logic start_walk, spec_ok, first_b;
  assign start_walk = g2 && !held && machrun_base && wstate == W_IDLE && directory != 18'd0
                   && (d_wa || d_wb);
  assign first_b    = !d_wa;
  assign spec_ok    = spec_v && spec_port == first_b;
  // The directory entry looked up on `g1` for every lookup a start or `MD`
  // asks, whatever the TLB answers, and at the port that misses when both
  // ask: a lookup touches nothing, and the TLB's word only chooses its
  // address.
  logic spec_look;
  assign spec_look  = g1 && machrun_base && wstate == W_IDLE && bstate == B_IDLE && directory != 18'd0
                   && sd_walk_ready && !sweeping && ((need_a && !walked_a) || need_b);

  // ------------------------------------------- the TLB's reads and writes
  //
  // The writes that land at an edge (A14.4): the write-back's OR on port A
  // at the grant, an operation on port B at the cpu edge.  Taken at the
  // edge, pending from its next tick (`pa_*`, `pb_*`, with a walk's fill),
  // written on the first tick that is not an edge.  An empty writes nothing
  // but the sweep, which every pending write gives way to.
  logic [1:0]  op;
  assign op      = vma[33:32];
  // An operation lands whatever the TLB is doing; one landing while the
  // sweep still runs on the RAM is the sweep's (an empty restarts it; a
  // direct write or an invalidation there is not built: no microcode makes
  // one within N/2 ticks of an empty or a boot).
  logic op_land, or_go, op_go, rd_now;
  assign op_land = wmap_land && paged(va_b) && op != 2'd0;
  assign op_drop = op_land;
  assign or_go   = wb_go && hit_a && !sweeping;
  assign op_go   = op_land && !sweeping && op != 2'd3;
  assign rd_now  = gen_edge && !sweeping;
  logic [WIDTH-1:0] or_word, op_word;
  assign or_word = {1'b1, tag(va_a), qa_ent | wb_bits};
  assign op_word = (op == 2'd1) ? {1'b1, tag(va_b), vma[29:0]} : '0;

  logic             e_or_v, e_op_v, pa_v, pb_v;
  logic [K-1:0]     e_or_idx, e_op_idx, pa_idx, pb_idx;
  logic [WIDTH-1:0] e_or_w, e_op_w, pa_w, pb_w;

  always_comb begin
    ta_en = 1'b0; ta_we = 1'b0; ta_idx = index(vma_nx); ta_wdata = pa_w;
    tb_en = 1'b0; tb_we = 1'b0; tb_idx = index(md_nx);  tb_wdata = pb_w;
    if (sweeping) begin
      ta_en = 1'b1; ta_we = 1'b1; ta_idx = {sweep_i, 1'b0}; ta_wdata = '0;
      tb_en = 1'b1; tb_we = 1'b1; tb_idx = {sweep_i, 1'b1}; tb_wdata = '0;
    end else if (gen_edge) begin
      ta_en = 1'b1;
      tb_en = 1'b1;
    end else begin
      if (pa_v) begin
        ta_en = 1'b1; ta_we = 1'b1; ta_idx = pa_idx;
      end
      if (pb_v) begin
        tb_en = 1'b1; tb_we = 1'b1; tb_idx = pb_idx;
      end
    end
  end

  // The write landing at this edge, or pending across it, at the index an
  // edge read takes: at most one of them, the OR and an operation never
  // landing at one edge and a fill never made or pending at a master clock
  // edge (port B takes a fill only once it is pending, see the header).
  // Port A takes no OR: a start's grant clears `MEMSTART`, and the
  // start after it is held to a later edge (`start_after_start` in
  // `cadr_microcycle.sv`), so port A's word read at a grant is never a
  // start's.  A port-B operation is written two ticks after its edge, never
  // across one.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic fwd_hit(input logic [WIDTH-1:0] w, input logic [31:0] va);
    return w[WIDTH-1] && w[29+TAG:30] == tag(va);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  // Port A's: the operation, else the fill made now, else the pending
  // write.  The fill is chosen last, from what its own address gives
  // (`fl_*`), as it alone hangs on the side seam's answer of this tick.
  logic             fa_m, fb_m, fa_hit, op_ma, fl_ma, fl_ha, fl_sel;
  logic [WIDTH-1:0] fa_w, fb_w;
  logic [29:0]      fa_ent;
  always_comb begin
    fa_m = 1'b0; fa_w = pa_w;
    fb_m = 1'b0; fb_w = pa_w;
    op_ma = op_go && index(va_b) == index(vma_nx);
    if (op_ma) begin fa_m = 1'b1; fa_w = op_word; end
    else if (pa_v && pa_idx == index(vma_nx)) begin fa_m = 1'b1; fa_w = pa_w; end
    fl_ma  = index(r_va) == index(vma_nx);
    fl_ha  = tag(r_va) == tag(vma_nx);
    fl_sel = !op_ma && fill_now && fl_ma;
    fa_hit = fl_sel ? fl_ha : fwd_hit(fa_w, vma_nx);
    fa_ent = fl_sel ? r_val : fa_w[29:0];
    fa_m   = fa_m || fl_sel;
    if (or_go && index(va_a) == index(md_nx)) begin fb_m = 1'b1; fb_w = or_word; end
    else if (op_go && index(va_b) == index(md_nx)) begin fb_m = 1'b1; fb_w = op_word; end
    else if (pa_v && pa_idx == index(md_nx)) begin fb_m = 1'b1; fb_w = pa_w; end
  end

  // ---------------------------------------- what the walk reads and finds
  //
  // The result written this tick (`r_set`), from the cache's answer over
  // the tick after its look or from a line: the no-entry word for a
  // directory entry not present, or the page entry, loaded or not.
  logic        r_set, r_port, r_load, fill_now;
  logic [29:0] r_val;
  logic [WIDTH-1:0] fill_word;
  logic [31:0] r_va;
  // On the walk's starting tick its port and address are not yet registered.
  assign r_port = start_walk ? first_b : w_port;
  assign r_va   = start_walk ? (first_b ? va_b : va_a) : w_va;
  logic        w_end;
  always_comb begin
    r_set  = 1'b0;
    r_load = 1'b0;
    r_val  = NO_ENTRY;
    unique case (wstate)
      W_DANS: if (sd_hit_live && !live_dok) r_set = 1'b1;
      W_DWAIT: if (f_v && !f_dok) r_set = 1'b1;
      W_PANS: if (sd_hit_live) begin
        r_set  = 1'b1;
        r_load = live_load;
        r_val  = live_load ? live_val : NO_ENTRY;
      end
      W_PWAIT: if (f_v) begin
        r_set  = 1'b1;
        r_load = f_load;
        r_val  = f_load ? f_word[29:0] : NO_ENTRY;
      end
      default: ;
    endcase
    // The spec look's answer is over the walk's starting tick.
    if (start_walk && spec_ok && sd_hit_live && !live_dok) r_set = 1'b1;
  end
  // The TLB's fill, made in the result's tick: written on the next tick
  // that is not an edge, and forwarded to an edge read before then.
  assign fill_now  = r_set && r_load;
  assign fill_word = {1'b1, tag(r_va), r_val};
  // A walk ends: its directory entry absent from a registered hit or from a
  // line, or its page entry in.
  assign w_end = (wstate == W_DRES && sd_hit && !lv_dok)
              || (wstate == W_DWAIT && f_v && !f_dok)
              || (wstate == W_PRES && sd_hit)
              || (wstate == W_PWAIT && f_v);

  // --------------------------------------------------- the side seam
  //
  // The walker in a hold and the write-back at a grant, never at once.
  logic b_wr_now, b_spec;
  assign b_spec = st1 && paged(b_va) && bstate == B_IDLE && sd_grant_ready;
  // The look and its address leave through a net the DE25-Nano's constraints
  // can name (`rtl/plumbing/quux_keep_net.sv`), for the side seam's one-tick
  // clause.
  logic        sd_look_c;
  logic [28:0] sd_phys_c;
  quux_keep_net #(.W(30)) side_net (.d({sd_look_c, sd_phys_c}), .q({sd_look, sd_phys}));
  always_comb begin
    sd_look_c   = 1'b0;
    sd_phys_c   = '0;
    sd_commit = 1'b0;
    sd_until  = until_s;
    sd_relook = 1'b0;
    if (spec_look) begin
      sd_look_c = 1'b1;
      sd_phys_c = 29'(dir_at(directory, (need_a && !walked_a && (!need_b || walk_a)) ? va_a : va_b));
    end
    // The walker.
    unique case (wstate)
      W_DLOOK: if (sd_walk_ready) begin
        sd_look_c = 1'b1;
        sd_phys_c = 29'(dir_at(directory, w_va));
      end
      W_DRES: begin
        sd_commit = 1'b1;
        // The walk's first read starts at the generator cycle's start; or,
        // looked up later, at the later of that and the acknowledgment of
        // the cycle that was in flight (clarification 74).  A look on `g1`
        // had none in flight.
        sd_until  = w_first ? until_s : w_ua;
        if (sd_hit && lv_dok && sd_walk_ready) begin
          sd_look_c = 1'b1;
          sd_phys_c = 29'({sd_word[17:0], w_va[19:10]});
        end
      end
      W_PLOOK: if (sd_walk_ready) begin
        sd_look_c = 1'b1;
        sd_phys_c = 29'(w_page_at);
      end
      W_PRES: sd_commit = 1'b1;
      default: ;
    endcase
    // Port B's walk after port A's, looked up as port A's ends.
    if (w_end && w_b_queued && sd_walk_ready) begin
      sd_look_c = 1'b1;
      sd_phys_c = 29'(dir_at(directory, va_b));
    end
    // The write-back's reads: the first on the tick after the grant, for
    // every start the edge took, then as the machine goes.
    if (b_spec) begin
      sd_look_c = 1'b1;
      sd_phys_c = b_ul ? 29'(b_page_at) : 29'(dir_at(directory, b_va));
    end
    unique case (bstate)
      B_DLOOK: if (sd_ready) begin
        sd_look_c = 1'b1;
        sd_phys_c = 29'(dir_at(directory, b_va));
      end
      B_DANS, B_PANS: sd_relook = 1'b1;
      B_DRES: begin
        sd_commit = 1'b1;
        sd_until  = b_t;
        if (sd_hit && lv_dok && sd_ready) begin
          sd_look_c = 1'b1;
          sd_phys_c = 29'({sd_word[17:0], b_va[19:10]});
        end
      end
      B_PLOOK, B_ULOOK: if (sd_ready) begin
        sd_look_c = 1'b1;
        sd_phys_c = 29'(b_page_at);
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

  // The write-back's write, and its end in the tick its outcome is a
  // register: apart from the block above, as the port's `sd_ready` waits
  // on them.
  assign b_wr_now = (bstate == B_PRES && sd_hit && lv_gok) || bstate == B_WR;
  assign sd_wr    = b_wr_now;
  // The line the page entry's read has just found takes the write.
  assign sd_wdata = (bstate == B_PRES) ? (sd_word | 40'(b_bits)) : (b_page | 40'(b_bits));
  // The bits alone, a register from the tick after the grant: the cache
  // writes a re-read entry from its own registered word and these, so that
  // nothing from outside it reaches its RAMs' write ports in the tick.
  assign sd_wbits = b_bits;
  assign wb_rel_v = (bstate == B_DRES && sd_hit && !lv_dok)
                 || (bstate == B_DWAIT && f_v && !f_dok)
                 || (bstate == B_PRES && sd_hit)
                 || (bstate == B_PWAIT && f_v && !f_gok)
                 || bstate == B_WR;
  // A refusal on a registered answer, which ends the write-back in this
  // tick and lets the cycle decide in it (`quux_mem_port.sv`'s
  // `decide_now`).
  // A register, taken from the answer's own tick (`B_DANS`, `B_PANS`, which
  // go on to `B_DRES` and `B_PRES` whatever comes), so that the cycle's
  // decision on it starts from a register.
  logic wb_rel_now_q;
  assign wb_rel_now = wb_rel_now_q;
  // A write's end is the port's answer; a refusal's on a hit, its last
  // read's, a hit's time after `b_t` (`b_rel_n`, the tick before's sum);
  // one on a line, `b_t`.
  logic signed [10:0] b_rel_n;
  // The later of `until` and the acknowledgment, a tick early: over the
  // look's answer (`W_DANS`) neither moves but by its count, the walker
  // having looked with no cycle in flight or with it acknowledged, and no
  // cycle taken while the walk holds the machine.
  logic signed [10:0] w_ua;
  assign wb_rel   = b_wr_now ? sd_done
                  : wb_rel_now ? b_rel_n
                  : b_t;
  assign wb_rel_q = b_rel_n;

  // The redirect's PDL read, on the last tick but one of the generator
  // cycle its hold was decided in.
  logic redirect_take, rd_pend;
  assign pdl_rd = rd_pend && gen_pre;

  // A hold's `until` as this tick has it: the walk's registered answer
  // committed now moves it in this tick.
  logic signed [10:0] until_eff;
  assign until_eff = (wstate == W_DRES || wstate == W_PRES) ? sd_done : until_s;

  // The guard's count's pulse: a refusal at the grant, from the grant's
  // registers, or one the write-back's machine found.
  assign refuse_p = (st1 && e_ref) || refuse_now;

  // **THE EDGE'S REGISTERS** (`e_*`): loaded at an edge only, from what the
  // microcycle settled, and read through the next: the forwards and the
  // walk's entries for the TLB's words, the writes landing there, and the
  // grant.
  always_ff @(posedge clk) begin
    if (rst) begin
      e_fa_v   <= 1'b0;
      e_fb_v   <= 1'b0;
      e_fa_hit <= 1'b0;
      e_fb_hit <= 1'b0;
      e_fa_ent <= '0;
      e_fb_ent <= '0;
      e_bpa_v  <= 1'b0;
      e_bpb_v  <= 1'b0;
      e_bpa    <= '0;
      e_bpb    <= '0;
      e_or_v   <= 1'b0;
      e_op_v   <= 1'b0;
      e_or_idx <= '0;
      e_op_idx <= '0;
      e_or_w   <= '0;
      e_op_w   <= '0;
      e_go     <= 1'b0;
      e_ref    <= 1'b0;
      e_bits   <= '0;
      e_frame  <= '0;
    end else begin
      if (gen_edge) begin
        if (rd_now) begin
          e_fa_v   <= fa_m;
          e_fa_hit <= fa_hit;
          e_fa_ent <= fa_ent;
          e_fb_v   <= fb_m;
          e_fb_hit <= fwd_hit(fb_w, md_nx);
          e_fb_ent <= fb_w[29:0];
        end
        // The walk's entries, for the cycle this edge starts; none past the
        // microcycle's end.  A result written in this very tick is taken.
        e_bpa_v <= !cpu_edge && ((r_set && !r_port) || ra_v);
        e_bpa   <= (r_set && !r_port) ? r_val : ra;
        e_bpb_v <= !cpu_edge && ((r_set && r_port) ? (r_va == md_nx) : (rb_v && rb_va == md_nx));
        e_bpb   <= (r_set && r_port) ? r_val : rb;
        e_or_v   <= or_go;
        e_or_idx <= index(va_a);
        e_or_w   <= or_word;
        e_op_v   <= op_go;
        e_op_idx <= index(va_b);
        e_op_w   <= op_word;
      end
      if (gen_edge && !tlbh) begin
        e_go    <= wb_go && !wb_now_refused;
        e_ref   <= wb_go && wb_now_refused;
        e_bits  <= wb_bits;
        e_frame <= ent_a[17:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      held          <= 1'b0;
      ra_v          <= 1'b0;
      rb_v          <= 1'b0;
      ra            <= '0;
      rb            <= '0;
      rb_va         <= '0;
      walked_a      <= 1'b0;
      walked_b      <= 1'b0;
      redirect_held <= 1'b0;
      res_mid       <= 1'b0;
      until_s       <= FLOOR;
      b_rel_n       <= FLOOR;
      wb_rel_now_q  <= 1'b0;
      lv_dok        <= 1'b0;
      lv_gok        <= 1'b0;
      f_v           <= 1'b0;
      f_word        <= '0;
      f_dok         <= 1'b0;
      f_gok         <= 1'b0;
      f_load        <= 1'b0;
      wstate        <= W_IDLE;
      w_port        <= 1'b0;
      w_b_queued    <= 1'b0;
      w_va          <= '0;
      w_page_at     <= '0;
      w_first       <= 1'b0;
      w_done        <= 1'b0;
      wk_page_v     <= 1'b0;
      wk_page_at    <= '0;
      wk_page       <= '0;
      spec_v        <= 1'b0;
      spec_port     <= 1'b0;
      d_wa          <= 1'b0;
      d_wb          <= 1'b0;
      d_redir       <= 1'b0;
      pa_v          <= 1'b0;
      pb_v          <= 1'b0;
      pa_idx        <= '0;
      pb_idx        <= '0;
      pa_w          <= '0;
      pb_w          <= '0;
      bstate        <= B_IDLE;
      b_va          <= '0;
      b_ul          <= 1'b0;
      b_frame       <= '0;
      b_bits        <= '0;
      b_page_at     <= '0;
      b_page        <= '0;
      b_t           <= FLOOR;
      st1           <= 1'b0;
      refuse_now    <= 1'b0;
      rd_pend       <= 1'b0;
      sweeping      <= 1'b1;
      sweep_i       <= '0;
      sweep_s       <= 17'(ENTRIES) + 17'(SWEEP_RESET_ADJ);
    end else begin
      until_s    <= down(until_s);
      b_t        <= down(b_t);
      b_rel_n    <= down(b_t) + 11'(HIT_T);
      w_ua       <= smax(down(until_s), down(sd_ack_at));
      wb_rel_now_q <= (bstate == B_DANS && sd_hit_live && !live_dok)
                   || (bstate == B_PANS && sd_hit_live && !live_gok);
      lv_dok     <= live_dok;
      lv_gok     <= live_gok;
      f_v        <= sd_fill_v;
      f_word     <= sd_fill_word;
      f_dok      <= dir_ok(sd_fill_word);
      f_gok      <= guard_ok(sd_fill_word, b_frame);
      f_load     <= page_load(sd_fill_word);
      sweep_s    <= (sweep_s == -17'sd1024) ? sweep_s : sweep_s - 17'sd1;
      refuse_now <= 1'b0;
      spec_v     <= spec_look;
      if (spec_look) spec_port <= !(need_a && !walked_a && (!need_b || walk_a));
      if (g1) begin
        d_wa    <= walk_a;
        d_wb    <= walk_b;
        d_redir <= fires && redirect_in;
      end
      st1        <= gen_edge && !tlbh && memstart;
      res_mid    <= gen_edge ? 1'b0 : (res_mid || r_set);

      // The sweep, two entries a tick (A14.4: N ticks of muir's; it is done
      // in N/2 here, inside the time muir gives it).
      if (sweeping) begin
        sweep_i <= sweep_i + 1'b1;
        if (&sweep_i) sweeping <= 1'b0;
      end

      // ---- the TLB's pending writes: written off the edge, or given way
      // to the sweep
      if (!gen_edge && !sweeping) begin
        pa_v <= 1'b0;
        pb_v <= 1'b0;
      end
      if (sweeping) begin
        pa_v <= 1'b0;
        pb_v <= 1'b0;
      end
      if (g1 && e_or_v) begin
        pa_v   <= 1'b1;
        pa_idx <= e_or_idx;
        pa_w   <= e_or_w;
      end
      if (g1 && e_op_v) begin
        pb_v   <= 1'b1;
        pb_idx <= e_op_idx;
        pb_w   <= e_op_w;
      end

      // ---- the hold's decision, cycle by cycle
      if (g1) begin
        // Held by what reaches past this cycle's start: a walk's `until`, a
        // sweep a lookup waits for, or a walk whose entry is not yet in.
        held <= machrun_base && ((until_eff > 11'sd0) || (need_any && sweep_s > 17'sd0) || walk_open);
      end
      if (g2 && !held && machrun_base && wstate == W_IDLE) begin
        if (d_wa || d_wb) begin
          if (directory == 18'd0) begin
            // No directory: no read, no time, no entry (A14.3); the miss
            // reads the no-entry word as it is, and the port is walked.
            if (d_wa) begin
              walked_a  <= 1'b1;
              wk_page_v <= 1'b0;
            end
            if (d_wb) begin
              walked_b <= 1'b1;
              rb_va    <= va_b;
            end
          end else begin
            held       <= 1'b1;
            w_port     <= first_b;
            w_b_queued <= d_wa && d_wb;
            w_va       <= first_b ? va_b : va_a;
            until_s    <= -11'sd2;
            w_first    <= spec_ok;
            w_done     <= 1'b0;
            wstate     <= spec_ok ? W_DRES : W_DLOOK;
          end
        end else if (d_redir && !redirect_held) begin
          held          <= 1'b1;
          redirect_held <= 1'b1;
        end
      end

      // ---- the walker
      unique case (wstate)
        W_DLOOK: if (sd_walk_ready) wstate <= W_DANS;
        W_DANS:  wstate <= W_DRES;
        W_DRES: begin
          until_s <= sd_done - 11'sd1;
          if (!sd_hit) wstate <= W_DWAIT;
          else if (lv_dok) begin
            w_page_at <= {sd_word[17:0], w_va[19:10]};
            // The page entry looked up now, or once the seam is the walker's.
            wstate    <= sd_walk_ready ? W_PANS : W_PLOOK;
          end
        end
        W_DWAIT: begin
          if (f_v && f_dok) begin
            w_page_at <= {f_word[17:0], w_va[19:10]};
            wstate    <= W_PLOOK;
          end
        end
        W_PLOOK: if (sd_walk_ready) wstate <= W_PANS;
        W_PANS:  wstate <= W_PRES;
        W_PRES: begin
          until_s <= sd_done - 11'sd1;
          if (!sd_hit) wstate <= W_PWAIT;
        end
        default: ;
      endcase

      // The result, in the tick of its last answer.
      if (r_set) begin
        w_done <= 1'b1;
        if (!r_port) begin
          ra_v     <= 1'b1;
          ra       <= r_val;
          walked_a <= 1'b1;
        end else begin
          rb_v     <= 1'b1;
          rb       <= r_val;
          rb_va    <= r_va;
          walked_b <= 1'b1;
        end
      end

      // The fill, pending from the result's tick.
      if (fill_now) begin
        pa_v   <= 1'b1;
        pa_idx <= index(r_va);
        pa_w   <= fill_word;
      end

      // The walk's end: port A's page entry kept for the write-back, and port
      // B's walk after port A's.
      if (w_end) begin
        if (!w_port && (wstate == W_PRES || wstate == W_PWAIT)) begin
          wk_page_v  <= 1'b1;
          wk_page_at <= w_page_at;
          wk_page    <= (wstate == W_PRES) ? sd_word : f_word;
        end
        if (w_b_queued) begin
          w_b_queued <= 1'b0;
          w_port     <= 1'b1;
          w_va       <= va_b;
          w_first    <= 1'b0;
          w_done     <= 1'b0;
          wstate     <= sd_walk_ready ? W_DANS : W_DLOOK;
        end else begin
          wstate <= W_IDLE;
        end
      end

      // ---- the write-back, from the grant (muir's `Rtl::write_back`)
      if (gen_edge && !tlbh && memstart) begin
        b_va      <= va_a;
        b_ul      <= walked_a;
        b_page_at <= wk_page_at;
        b_page    <= wk_page;
      end
      if (st1 && e_go && bstate == B_IDLE) begin
        b_frame <= e_frame;
        b_bits  <= e_bits;
        b_t     <= -11'sd1;
        bstate  <= b_spec ? (b_ul ? B_WR : B_DANS) : (b_ul ? B_ULOOK : B_DLOOK);
      end
      unique case (bstate)
        B_DLOOK: if (sd_ready) bstate <= B_DANS;
        B_DANS:  bstate <= B_DRES;
        B_DRES: begin
          b_t <= sd_done - 11'sd1;
          if (!sd_hit) bstate <= B_DWAIT;
          else if (lv_dok) begin
            b_page_at <= {sd_word[17:0], b_va[19:10]};
            bstate    <= sd_ready ? B_PANS : B_PLOOK;
          end else begin
            refuse_now <= 1'b1;
            bstate     <= B_IDLE;
          end
        end
        B_DWAIT: begin
          if (f_v) begin
            if (f_dok) begin
              b_page_at <= {f_word[17:0], b_va[19:10]};
              bstate    <= B_PLOOK;
            end else begin
              refuse_now <= 1'b1;
              bstate     <= B_IDLE;
            end
          end
        end
        B_PLOOK: if (sd_ready) bstate <= B_PANS;
        B_PANS:  bstate <= B_PRES;
        B_PRES: begin
          b_t <= sd_done - 11'sd1;
          if (!sd_hit) bstate <= B_PWAIT;
          else begin
            if (!lv_gok) refuse_now <= 1'b1;
            bstate <= B_IDLE;
          end
        end
        B_PWAIT: begin
          if (f_v) begin
            b_page <= f_word;
            if (f_gok) bstate <= B_ULOOK;
            else begin
              refuse_now <= 1'b1;
              bstate     <= B_IDLE;
            end
          end
        end
        B_ULOOK: if (sd_ready) bstate <= B_WR;
        B_WR:    bstate <= B_IDLE;
        default: ;
      endcase

      // ---- the redirect's read, pending from its decision to the tick
      if (redirect_take) rd_pend <= 1'b1;
      else if (gen_pre || gen_edge) rd_pend <= 1'b0;

      // ---- an operation (A14.4): an empty starts the sweep, from the
      // start of the microcycle that runs, N ticks
      if (op_land && op == 2'd3) begin
        sweeping <= 1'b1;
        sweep_i  <= '0;
        sweep_s  <= 17'(ENTRIES) - 17'(since_start) - 17'sd1;
      end

      // ---- the microcycle ends: its walks and its redirect are done with
      if (cpu_edge) begin
        ra_v          <= 1'b0;
        rb_v          <= 1'b0;
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

  assign redirect_take = g2 && !held && machrun_base && wstate == W_IDLE && !(d_wa || d_wb)
                       && d_redir && !redirect_held;

    // **THE SIDE SEAM HAS ONE MASTER AT A TIME** (clarification 74): from a
  // look to its registered answer, and through a miss's fill, the seam is
  // the walker's or the write-back's, never both's; the walker reads only
  // once the cycle in flight is acknowledged, after its write-back.  And
  // **NO GENERATOR CYCLE THAT RUNS WAITED FOR A WALK'S ENTRY BY THE FLOOR
  // ALONE**: the walk's entry is in by the start of every cycle that muir's
  // time lets run, or the fabric would hold where muir does not.  Held on
  // every tick of the checks that build the machine with
  // `CADR_GAP_MONITOR`.
`ifdef CADR_GAP_MONITOR
  logic mon_w_on, mon_b_on;
  assign mon_w_on = spec_look || (start_walk && spec_ok)
                 || wstate == W_DANS || wstate == W_DRES || wstate == W_DWAIT
                 || wstate == W_PANS || wstate == W_PRES || wstate == W_PWAIT
                 || ((wstate == W_DLOOK || wstate == W_PLOOK) && sd_walk_ready);
  assign mon_b_on = b_spec || bstate == B_DANS || bstate == B_DRES || bstate == B_DWAIT
                 || bstate == B_PANS || bstate == B_PRES || bstate == B_PWAIT
                 || bstate == B_WR
                 || ((bstate == B_DLOOK || bstate == B_PLOOK || bstate == B_ULOOK) && sd_ready);
  always_ff @(posedge clk) begin
    if (!rst && mon_w_on && mon_b_on)
      $fatal(1, "quux_mmu: the walker and the write-back both on the side seam");
    if (!rst && gen_edge && !tlbh && res_mid)
      $fatal(1, "quux_mmu: a walk's entry written after the start of a generator cycle that runs");
    if (!rst && wb_rel_now != ((bstate == B_DRES && sd_hit && !lv_dok) || (bstate == B_PRES && sd_hit && !lv_gok)))
      $fatal(1, "quux_mmu: the write-back's refusal on a registered answer taken a tick early is not its own");
    if (!rst && wstate == W_DRES && !w_first && w_ua != smax(until_s, sd_ack_at))
      $fatal(1, "quux_mmu: the walk's start %0d where until and the acknowledgment say %0d",
             w_ua, smax(until_s, sd_ack_at));
  end
`endif

endmodule

`default_nettype wire
