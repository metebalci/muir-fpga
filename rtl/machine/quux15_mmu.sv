// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S MEMORY MANAGEMENT** (contract G3 revision 15, A15b.3;
// revision 14's A14.1-A14.9 as revision 15 keeps them): the windows'
// decode and fixed entries, the TLB and its two lookups, muir's pipeline's
// walk, the write-back of the accessed, modified and ephemeral bits and its
// refusal, the `WRITE-MAP` operations and the sweep, and the memory system's
// register-page words 220-224.  muir's `tlb.rs`, `Machine::translate_14`,
// `Pipeline::walk`, `write_back_at_wb` and `write_map_14` are the reference,
// clock for clock through the core (`quux15_core.sv`) and its goldens.
//
// **A CLOCK ASKS IN muir'S ORDER**: WB's start first (port A: its lookup, a
// walk on a miss, the translation; then, once the core has its fault and
// its holds, the write-back), then EX's word (port B: `MAP(MD)` or a
// map-bit dispatch, the lookup of the `MD` it reads, a walk on a miss),
// then the `WRITE-MAP` operation that lands at the head of EX's microcycle.
// Each sees what the ones before it in the clock wrote: port B a fill or an
// OR WB made in the same clock, and a walk's caller its own fill, in the
// clock it lands (forwards from the writes into the lookups).
//
// **THE WALK IS muir's PIPELINE'S** (A15b.3): each table read a cache read
// through the port (`quux15_port.sv`'s T), the walk the port that asked
// first, keeping the address it began with to its fill: asked for
// another meanwhile, it finishes its own and answers "not yet", and the
// caller looks its address up again.  Neither of revision 14's longer
// holds is here: port B looks up in every clock it waits, and starts a walk
// only when that clock's lookup misses; no walk of port B waits behind port
// A's (`quux_mmu.sv`'s `w_b_queued`).
//
// **THE TLB**: 4,096 entries, direct-mapped, an entry `VA<31:22>` and the
// page entry's `<29:0>` in two RAMs of one write and one read, one read by
// WB's next start's address and one by EX's next `MD`, each at the clock's
// end for the next; the valid bits in RAM (`quux15_validmap.sv`), so that an empty clears
// every entry at once, as muir's sweep does, the starts and port B's
// lookups held 4,096 clocks behind it by a count (A14.4).  The RAMs
// take one write a clock, in order; a write not yet taken, or taken at the
// edge a lookup read through, is forwarded to the lookup.

`default_nettype none

module quux15_mmu #(
    // Main memory's words: the walk's frames are below it.
    parameter int unsigned MAIN_WORDS = 32'h0020_0000
) (
    input  var logic        clk,
    input  var logic        rst,
    // The console's -RESET, in the clock it is for.
    input  var logic        con_reset,

    // --- The lookups' addresses for the next clock: WB's start's and EX's
    // --- `MD`'s, read at this clock's end.
    input  var logic [31:0] a_next_va,
    input  var logic [31:0] b_next_va,

    // --- Port A: WB's start reaches the TLB (past the sweep, its
    // --- acknowledgment and `MD`); its address.
    input  var logic        a_req,
    input  var logic [31:0] a_va,
    output var logic        a_hold,        // the walk reads on
    output var logic [29:0] a_entry,       // the translation, when not held

    // --- The write-back of WB's start, once its fault and holds are past.
    input  var logic        k_req,
    input  var logic [31:0] k_va,
    input  var logic [29:0] k_entry,
    input  var logic        k_write,
    input  var logic [39:0] k_md,
    output var logic        k_hold,        // reads, or waits for the queue
    output var logic        k_busy,        // a write-back is under way
    output var logic        post_req,
    output var logic [28:0] post_bus,
    output var logic [39:0] post_word,
    input  var logic        post_ok,

    // --- Port B: EX's word reaches its lookup; the `MD` it reads; its
    // walk done in an earlier clock, so that it takes the TLB as it stands.
    input  var logic        b_req,
    input  var logic [31:0] b_va,
    input  var logic        b_walked,
    output var logic        b_hold,
    output var logic        b_walk_done,   // its walk done: it holds a clock
    output var logic [29:0] b_entry,

    // --- The WRITE-MAP operation landing at the head of EX's microcycle.
    input  var logic        op_v,
    input  var logic [39:0] op_vma,
    input  var logic [39:0] op_md,

    // --- The table reads, through the port.
    output var logic        t_start,
    output var logic [28:0] t_addr,
    input  var logic        t_ready,
    input  var logic [39:0] t_word,

    // --- The memory system's words: a register write taken, and the words.
    input  var logic        rw_v,
    input  var logic [7:0]  rw_k,
    input  var logic [31:0] rw_data,
    output var logic [17:0] directory,
    output var logic        ephemeral,
    output var logic [63:0] pointer_types,
    output var logic [31:0] refused,

    // --- The sweep runs: starts and port B's lookups wait.
    output var logic        sweeping
);

  localparam int unsigned ENTRIES = 4096;
  localparam logic [29:0] ENTRY_BITS = '1;
  localparam logic [29:0] RW_STATUS_4 = 30'(32'b11 << 28 | 32'o1460 << 18);
  localparam logic [29:0] A_MEMORY_WINDOW_ENTRY = 30'(32'b11 << 28 | 32'o760 << 18);
  localparam logic [29:0] NO_ENTRY = 30'(32'o60 << 18);
  localparam logic [31:0] A_MEMORY_WINDOW = 32'o35700000000;
  localparam logic [29:0] ACCESSED = 30'(1 << 28);
  localparam logic [29:0] MODIFIED = 30'(1 << 29);
  localparam logic [29:0] EPHEMERAL = 30'(1 << 19);
  localparam logic [17:0] FRAMES = 18'(MAIN_WORDS >> 10);
  localparam int unsigned FN = 4;

  // ======================================================== decode and entries

  /* verilator lint_off UNUSEDSIGNAL */
  typedef enum logic [1:0] {PAGED, DEVICE, AMEMORY, PHYSICAL} region_e;
  function automatic region_e region(input logic [31:0] va);
    if (va[31:29] != 3'b111) return PAGED;
    if (va[28]) return PHYSICAL;
    if ({va[31:10], 10'd0} == A_MEMORY_WINDOW) return AMEMORY;
    return DEVICE;
  endfunction
  function automatic logic [29:0] fixed_entry(input logic [31:0] va);
    unique case (region(va))
      PHYSICAL: return RW_STATUS_4 | {12'd0, va[27:10]};
      AMEMORY:  return A_MEMORY_WINDOW_ENTRY;
      default:  return RW_STATUS_4;
    endcase
  endfunction
  function automatic logic [2:0] status(input logic [39:0] e);
    return e[26:24];
  endfunction
  function automatic logic [11:0] idx(input logic [31:0] va);
    return va[21:10];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ================================================================ the TLB

  // The entries' words, the tag and the entry, in two RAMs of one write and
  // one read; their valid bits in RAM (`quux15_validmap.sv`), which an empty
  // or -RESET clears in one clock.
  logic [11:0]  ra_idx, rb_idx, w_idx;
  logic [39:0]  ra_q, rb_q, w_data;
  logic         w_en, w_v;
  quux15_ram #(.WIDTH(40), .DEPTH(ENTRIES)) tlb_a (
      .clk(clk), .re(1'b1), .raddr(ra_idx), .rdata(ra_q), .we(w_en), .waddr(w_idx), .wdata(w_data));
  quux15_ram #(.WIDTH(40), .DEPTH(ENTRIES)) tlb_b (
      .clk(clk), .re(1'b1), .raddr(rb_idx), .rdata(rb_q), .we(w_en), .waddr(w_idx), .wdata(w_data));
  // The indices the RAMs were read at, at the last edge: each lookup's own,
  // the valid bits read there too.
  logic [11:0]  a_idx_q, b_idx_q;
  logic         vm_a, vm_b, vm_none;
  quux15_validmap #(.ENTRIES(ENTRIES), .READS(2)) valid (
      .clk(clk), .rst(rst), .clear(op_empty || con_reset), .we(w_en && !con_reset), .waddr(w_idx), .wbit(w_v),
      .raddr0(a_idx_q), .raddr1(b_idx_q), .raddr2(12'd0),
      .rbit0(vm_a), .rbit1(vm_b), .rbit2(vm_none));
  // The writes the RAMs have not taken, oldest first, each with its valid
  // bit; and the one they took at the last edge, which that edge's reads
  // read through.
  logic [FN-1:0] fq_v, fq_bit;
  logic [11:0]   fq_idx [FN];
  logic [39:0]   fq_data [FN];
  logic          hist_v;
  logic [11:0]   hist_idx;
  logic [39:0]   hist_data;

  // The RAM's word at a lookup's address, the newest write forwarded.
  function automatic logic [39:0] tlb_word(input logic [39:0] q, input logic [11:0] at);
    logic [39:0] r;
    r = q;
    if (hist_v && hist_idx == at) r = hist_data;
    for (int k = 0; k < FN; k++)
      if (fq_v[k] && fq_idx[k] == at) r = fq_data[k];
    return r;
  endfunction
  // An entry's valid bit: a write not yet taken's, or the RAM's.
  function automatic logic tlb_valid(input logic ram, input logic [11:0] at);
    logic r;
    r = ram;
    for (int k = 0; k < FN; k++)
      if (fq_v[k] && fq_idx[k] == at) r = fq_bit[k];
    return r;
  endfunction

  // ================================================================ the walk

  typedef enum logic [1:0] {IDLE, DIR, PAGE} step_e;
  step_e        w_state, k_state;
  logic [31:0]  w_va;
  // The walk under way is WB's start's (port A), not port B's.
  logic         w_owner_a;
  logic [29:0]  k_bits;
  logic [28:0]  k_page;
  logic         k_word_v;
  logic [39:0]  k_word;
  logic [12:0]  sweep_left /* verilator public_flat_rw */;

  // One call of the walk (muir's `Pipeline::walk`): the state it leaves,
  // whether it answers (`Some`), its fill, and a table read begun.
  typedef struct packed {
    step_e       state;
    logic [31:0] va;
    logic        done;
    logic        fill;
    logic [29:0] entry;
    logic        tstart;
    logic [28:0] taddr;
    logic        took;       // took the table read's word
  } walk_t;

  function automatic walk_t walk_call(input step_e st, input logic [31:0] wva, input logic [31:0] va,
                                      input logic ready, input logic [39:0] word,
                                      input logic [17:0] base);
    walk_t r;
    logic [39:0] dir;
    logic [17:0] frame;
    r = '0;
    r.state = st;
    r.va = (st == IDLE) ? va : wva;
    unique case (st)
      IDLE: begin
        if (base == 18'd0) begin
          r.done = 1'b1;
        end else begin
          r.state  = DIR;
          r.tstart = 1'b1;
          r.taddr  = {1'b0, base[17:2], r.va[31:20]};
        end
      end
      DIR: if (ready) begin
        r.took = 1'b1;
        dir = word;
        frame = dir[17:0];
        if (status(dir) != 3'd4 || frame >= FRAMES) begin
          r.state = IDLE;
          r.done = 1'b1;
        end else begin
          r.state  = PAGE;
          r.tstart = 1'b1;
          r.taddr  = {1'b0, frame, r.va[19:10]};
        end
      end
      PAGE: if (ready) begin
        r.took = 1'b1;
        r.state = IDLE;
        r.done = 1'b1;
        unique case (status(word))
          3'd0, 3'd7: r.fill = 1'b0;
          3'd1: r.fill = 1'b1;
          default: r.fill = word[17:0] < FRAMES;
        endcase
        r.entry = word[29:0] & ENTRY_BITS;
      end
      default: ;
    endcase
    // Asked for another address, it answers not yet.
    if (r.va != va) r.done = 1'b0;
    return r;
  endfunction

  // ============================================================ port A, WB's

  walk_t       wa, wb;
  logic [39:0] a_word, b_word;
  logic        a_hit, b_hit;
  logic [29:0] a_hit_entry, b_hit_entry;
  // The walk's fill at WB, and the entry it writes.
  logic        aw_fill;
  logic [11:0] aw_idx;
  // The write-back's step.
  logic        k_refused, k_done, k_or;
  logic [29:0] k_bits_now;
  step_e       k_state_n;
  logic [28:0] k_page_n;
  logic        k_word_v_n;
  logic [39:0] k_word_n;
  logic        k_tstart;
  logic [28:0] k_taddr;
  always_comb begin
    // --- The lookup.
    a_word      = tlb_word(ra_q, a_idx_q);
    a_hit       = tlb_valid(vm_a, a_idx_q) && a_word[39:30] == a_va[31:22];
    a_hit_entry = a_word[29:0];
    // --- The walk, on a miss of a paged address.
    wa = walk_call(w_state, w_va, a_va, t_ready, t_word, directory);
    a_hold  = 1'b0;
    a_entry = fixed_entry(a_va);
    aw_fill = 1'b0;
    aw_idx  = idx(a_va);
    if (a_req && region(a_va) == PAGED && a_hit) begin
      a_entry = a_hit_entry;
      wa = '{state: w_state, va: w_va, default: '0};
    end else if (a_req && region(a_va) == PAGED) begin
      if (!wa.done) begin
        a_hold = 1'b1;
      end else if (wa.fill) begin
        // muir's translation looks the TLB up again: the fill (`wa.va` is
        // the start's own address, the walk being ours).
        a_entry = wa.entry;
        aw_fill = 1'b1;
      end else begin
        a_entry = NO_ENTRY;
      end
    end else begin
      wa = '{state: w_state, va: w_va, default: '0};
    end
  end

  always_comb begin
    // --- The write-back (muir's `write_back_at_wb`).
    k_hold = 1'b0; k_refused = 1'b0; k_done = 1'b0; k_or = 1'b0;
    k_state_n = k_state; k_page_n = k_page; k_word_v_n = k_word_v; k_word_n = k_word;
    k_tstart = 1'b0; k_taddr = '0;
    k_bits_now = k_bits;
    post_req = 1'b0;
    post_bus = k_page;
    post_word = '0;
    if (k_req && region(k_va) == PAGED) begin
      unique case (k_state)
        IDLE: begin
          logic eph;
          eph = ephemeral && pointer_types[k_md[37:32]] && k_md[31:28] == 4'b1101;
          k_bits_now = (ACCESSED & ~k_entry)
                     | (k_write ? ((MODIFIED & ~k_entry) | (eph ? (EPHEMERAL & ~k_entry) : '0)) : '0);
          if (k_bits_now != '0) begin
            k_or = 1'b1;
            if (directory == 18'd0) begin
              k_refused = 1'b1;
            end else begin
              k_state_n = DIR;
              k_tstart  = 1'b1;
              k_taddr   = {1'b0, directory[17:2], k_va[31:20]};
              k_hold    = 1'b1;
            end
          end
        end
        DIR: begin
          if (!t_ready || wa.took) k_hold = 1'b1;
          else if (status(t_word) != 3'd4 || t_word[17:0] >= FRAMES) begin
            k_state_n = IDLE;
            k_refused = 1'b1;
          end else begin
            k_page_n  = {1'b0, t_word[17:0], k_va[19:10]};
            k_state_n = PAGE;
            k_tstart  = 1'b1;
            k_taddr   = {1'b0, t_word[17:0], k_va[19:10]};
            k_hold    = 1'b1;
          end
        end
        PAGE: begin
          logic        have;
          logic [39:0] page;
          have = k_word_v || (t_ready && !wa.took);
          page = k_word_v ? k_word : t_word;
          if (!have) begin
            k_hold = 1'b1;
          end else if (!(status(page) >= 3'd2 && status(page) <= 3'd6)
                       || page[17:0] != k_entry[17:0]) begin
            k_state_n  = IDLE;
            k_word_v_n = 1'b0;
            k_refused  = 1'b1;
          end else begin
            post_req  = 1'b1;
            post_bus  = k_page;
            post_word = page | {10'd0, k_bits};
            if (!post_ok) begin
              k_hold     = 1'b1;
              k_word_v_n = 1'b1;
              k_word_n   = page;
            end else begin
              k_state_n  = IDLE;
              k_word_v_n = 1'b0;
            end
          end
        end
        default: ;
      endcase
    end
    k_done = k_req && !k_hold;
  end
  assign k_busy = k_state != IDLE;

  // WB's write to the TLB this clock: the walk's fill, the write-back's OR
  // into the entry the start translated through (or its fill), one write.
  logic        aw_v;
  logic [39:0] aw_data;
  always_comb begin
    aw_v    = aw_fill;
    aw_data = aw_fill ? {a_va[31:22], wa.entry} : {a_va[31:22], a_hit_entry};
    if (k_or && (a_hit || aw_fill)) begin
      aw_v    = 1'b1;
      aw_data = {aw_data[39:30], aw_data[29:0] | k_bits_now};
    end
  end

  // ============================================================ port B, EX's
  //
  // **PORT B FROM WHAT THE CLOCK BEGAN WITH**, so that EX's hold and MAP(MD)
  // wait on neither WB's grant nor its holds: port B's lookup counts only
  // when WB leaves, so a walk WB's start has under way is over by then, and
  // port B's own walk is the one it began (`w_owner`).  **NOTHING OF WB'S
  // CLOCK REACHES IT**: the word in EX is the word right after WB's, and a
  // word right after a start does not read the map (A15b.2's rule, the
  // micro-assembler's), so WB's same clock's fill and OR, which muir's
  // pipeline would show port B, never meet a lookup.
  logic        bw_v, b_called;
  logic [11:0] bw_idx;
  logic [39:0] bw_data;
  step_e       b_state;
  always_comb begin
    // --- The lookup.
    b_word = tlb_word(rb_q, b_idx_q);
    b_hit       = tlb_valid(vm_b, b_idx_q) && b_word[39:30] == b_va[31:22];
    b_hit_entry = b_word[29:0];
    // --- Its walk: its own, or one WB's start has ended.
    b_state = (w_owner_a || w_state == IDLE) ? IDLE : w_state;
    wb = walk_call(b_state, w_va, b_va, t_ready, t_word, directory);
    b_hold  = 1'b0;
    b_entry = fixed_entry(b_va);
    bw_idx  = idx(b_va);
    bw_data = {b_va[31:22], wb.entry};
    if (region(b_va) == PAGED) begin
      // **THE TLB's WORD RAW**: a miss holds the word, so the hit decides
      // nothing of the entry it reads, but after the word's walk, when the
      // TLB without it means the walk found no entry.  **A WALK'S FILL IS
      // USED A CLOCK LATER**: the word holds the clock its walk ends, the
      // fill written at the edge, and looks the TLB up again in the next
      // (muir's `ex_stage`, `b_walked`), so that no table word reaches EX's
      // operand in the clock it lands.
      b_entry = (b_walked && !b_hit) ? NO_ENTRY : b_hit_entry;
      b_hold  = !b_hit && !b_walked;
    end
    b_called    = b_req && region(b_va) == PAGED && !b_hit && !b_walked;
    bw_v        = b_called && wb.done && wb.fill;
    b_walk_done = b_called && wb.done;
    if (!b_called) wb = '{state: wa.state, va: wa.va, default: '0};
  end

  // The table read begun this clock: at most one.
  always_comb begin
    t_start = wa.tstart || k_tstart || wb.tstart;
    t_addr  = wa.tstart ? wa.taddr : k_tstart ? k_taddr : wb.taddr;
  end

  // ============================================================ the operation

  // `tlb::Operation::of`: an MD in a window does nothing; VMA<33:32> 1 a
  // direct write, 2 an invalidation, 3 an empty.
  logic op_load, op_inval, op_empty;
  always_comb begin
    op_load  = op_v && op_md[31:29] != 3'b111 && op_vma[33:32] == 2'd1;
    op_inval = op_v && op_md[31:29] != 3'b111 && op_vma[33:32] == 2'd2;
    op_empty = op_v && op_md[31:29] != 3'b111 && op_vma[33:32] == 2'd3;
    sweeping = sweep_left != 13'd0;
  end

  // ================================================================ the edge

  always_ff @(posedge clk) begin
    if (rst) begin
      fq_v       <= '0;
      hist_v     <= 1'b0;
      w_state    <= IDLE;
      w_owner_a  <= 1'b0;
      k_state    <= IDLE;
      k_word_v   <= 1'b0;
      sweep_left <= 13'(ENTRIES - 1);
      directory  <= '0;
      ephemeral  <= 1'b0;
      pointer_types <= '0;
      refused    <= '0;
    end else begin
      // --- The walk and the write-back.
      w_state  <= wb.state;
      w_va     <= wb.va;
      if (wa.tstart && w_state == IDLE) w_owner_a <= 1'b1;
      if (wb.tstart && b_called) w_owner_a <= 1'b0;
      k_state  <= k_state_n;
      k_page   <= k_page_n;
      k_word_v <= k_word_v_n;
      k_word   <= k_word_n;
      if (k_req && k_state == IDLE) k_bits <= k_bits_now;
      if (k_refused) refused <= refused + 32'd1;

      // --- The TLB's writes, in muir's order: WB's, port B's fill, the
      // --- operation; the RAMs take one a clock, the oldest; an empty drops
      // --- every write before it, its valid bits cleared at once.
      begin
        logic [FN-1:0] nv, nb;
        logic [11:0]   ni [FN];
        logic [39:0]   nd [FN];
        int n;
        n = 0;
        nv = '0;
        nb = '0;
        for (int k = 0; k < FN; k++) begin
          ni[k] = '0;
          nd[k] = '0;
        end
        // The oldest is taken this edge.
        for (int k = 1; k < FN; k++)
          if (fq_v[k]) begin
            nv[n] = 1'b1; nb[n] = fq_bit[k]; ni[n] = fq_idx[k]; nd[n] = fq_data[k];
            n++;
          end
        if (aw_v) begin
          nv[n] = 1'b1; nb[n] = 1'b1; ni[n] = aw_idx; nd[n] = aw_data; n++;
        end
        if (bw_v) begin
          nv[n] = 1'b1; nb[n] = 1'b1; ni[n] = bw_idx; nd[n] = bw_data; n++;
        end
        if (op_load || op_inval) begin
          nv[n] = 1'b1; nb[n] = op_load; ni[n] = idx(op_md[31:0]);
          nd[n] = {op_md[31:22], op_vma[29:0]}; n++;
        end
        if (op_empty) nv = '0;
        // The RAMs take the oldest now: one queued, or this clock's first.
        hist_v    <= w_en;
        hist_idx  <= w_idx;
        hist_data <= w_data;
        if (!fq_v[0] && nv[0]) begin
          // This clock's first write is taken at once.
          for (int k = 0; k < FN - 1; k++) begin
            fq_v[k] <= nv[k + 1]; fq_bit[k] <= nb[k + 1]; fq_idx[k] <= ni[k + 1]; fq_data[k] <= nd[k + 1];
          end
          fq_v[FN-1] <= 1'b0;
        end else begin
          fq_v <= nv;
          fq_bit <= nb;
          for (int k = 0; k < FN; k++) begin
            fq_idx[k] <= ni[k]; fq_data[k] <= nd[k];
          end
        end
      end
      a_idx_q <= idx(a_next_va);
      b_idx_q <= idx(b_next_va);

      // --- The sweep's count.
      if (op_empty) sweep_left <= 13'(ENTRIES - 1);
      else if (sweep_left != 13'd0) sweep_left <= sweep_left - 13'd1;

      // --- The memory system's words (A14.9).
      if (rw_v) begin
        unique case (rw_k)
          8'o220: directory <= rw_data[17:0];
          8'o221: ephemeral <= rw_data[0];
          8'o222: pointer_types[31:0] <= rw_data;
          8'o223: pointer_types[63:32] <= rw_data;
          8'o224: refused <= '0;
          default: ;
        endcase
      end
      // --- The console's -RESET (`reset_memory_system`), the machine
      // halted and the MMU idle, in the clock it is for: the TLB emptied and
      // its lookups held to that clock's 4,096th, the words cleared.
      if (con_reset) begin
        fq_v          <= '0;
        hist_v        <= 1'b0;
        sweep_left    <= 13'(ENTRIES - 1);
        directory     <= '0;
        ephemeral     <= 1'b0;
        pointer_types <= '0;
        refused       <= '0;
      end
    end
  end

  // The RAMs' write this clock: the oldest queued, or this clock's first.
  always_comb begin
    // An empty this clock drops every write before it, its own clock's too.
    w_en   = (fq_v[0] || aw_v || bw_v || op_load || op_inval) && !op_empty;
    w_idx  = fq_v[0] ? fq_idx[0] : aw_v ? aw_idx : bw_v ? bw_idx : idx(op_md[31:0]);
    w_data = fq_v[0] ? fq_data[0] : aw_v ? aw_data : bw_v ? bw_data : {op_md[31:22], op_vma[29:0]};
    w_v    = fq_v[0] ? fq_bit[0] : (aw_v || bw_v || op_load);
    ra_idx = idx(a_next_va);
    rb_idx = idx(b_next_va);
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (a_req && region(a_va) == PAGED && idx(a_va) != a_idx_q)
        $error("quux15_mmu: port A looked up %o, read at index %o", a_va, a_idx_q);
      if (b_req && region(b_va) == PAGED && idx(b_va) != b_idx_q)
        $error("quux15_mmu: port B looked up %o, read at index %o", b_va, b_idx_q);
      if ((wa.tstart && k_tstart) || (wa.tstart && wb.tstart) || (k_tstart && wb.tstart))
        $error("quux15_mmu: two table reads begun in one clock");
      if (fq_v[FN-1] && (aw_v || bw_v || op_load || op_inval))
        $error("quux15_mmu: the TLB's writes overflow");
    end
  end
`endif

  logic unused;
  assign unused = ^{vm_none, k_done, wb, wa.fill, k_md[39:38], k_md[27:0], op_vma[39:34], op_vma[31:30],
                    op_md[39:32]};

endmodule

`default_nettype wire
