// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S CORE: THE PIPELINE** (contract G3 revision 15, §3, §5,
// §6; appendix A15b).  Four stages of one clock each, so that the microcycle
// is the clock:
//
//   CS  the control store's word, read at the edge that loaded CS; the A
//       memory's and the PDL buffer's read addresses leave CS with it, read
//       at the edge it leaves, before that edge's writes.  An SH word ORs
//       OA-REG-HIGH into its A and M source here.
//   RD  decode; the M memory's word, read at the edge the word entered RD
//       after that edge's writes; d2 and d3 into the operands, the PDL
//       buffer's forward; the next address of every transfer RD resolves or
//       predicts, from RD's speculative copies of the micro stack's pointer
//       and top, the PDL pointer and index, and LC; the guard.
//   EX  the word runs (`quux15_exec.sv`), d1 into its operands, its OA
//       selects applied and checked; the registers and the micro stack
//       written at its end; a conditional jump or a dispatch decided and RD's
//       choice checked, a wrong one redirecting the front end.
//   WB  A, M, the PDL buffer and the control store written.
//
// **muir's `muir::pipeline::Pipeline` IS THE REFERENCE, CLOCK FOR CLOCK**:
// what each stage holds after each edge, the commit, the registers EX
// writes, the operands and output of each ALU or BYTE word, and the OA
// registers, against `golden/src/quux15.rs`'s traces in
// `tb/quux15_core_tb.cpp`.  Each piece below names the function of muir's
// `src/pipeline/` it is (`stages.rs`, `exec.rs`, `control.rs`), and the
// order of a clock is `stages.rs`'s `clock_once`: WB, then EX, then the
// front end (the redirect and its squash and restore, or RD's choices),
// then CS's reads, then the edge.
//
// **WHAT IS NOT BUILT** --- memory starts and the map, LC's fetch,
// MACRO-DISPATCH and D, the devices and time, the console's halt --- stops
// a simulation at the word that needs it, naming it (`unbuilt`), rather than
// running on wrong.

`default_nettype none

module quux15_core #(
    // The PROM image, a 64-bit word a line (`quux15_store.sv`).
    parameter string PROM_HEX = "",
    // MACHINE-ID, functional source 16: `0x5155`, revision 15, processor 4.
    parameter logic [31:0] MACHINE_ID = {16'h5155, 12'd15, 4'd4}
) (
    input  var logic        clk,
    // Power-on: the machine as muir's `Pipeline::boot` leaves it, the boot's
    // trap in CS.
    input  var logic        rst,
    // What `tb/quux15_core_tb.cpp` compares, `golden/src/trace15.rs`'s
    // columns, as each clock ends.
    output var logic [15:0] obs_cs,
    output var logic [15:0] obs_rd,
    output var logic [15:0] obs_ex,
    output var logic [15:0] obs_wb,
    output var logic [15:0] obs_commit,
    output var logic [13:0] obs_pdlptr,
    output var logic [13:0] obs_pdlidx,
    output var logic [4:0]  obs_spcptr,
    output var logic [39:0] obs_q,
    output var logic [39:0] obs_vma,
    output var logic [39:0] obs_md,
    output var logic [40:0] obs_lc,
    output var logic [31:0] obs_ic,
    output var logic        obs_opnd,
    output var logic [39:0] obs_ea,
    output var logic [39:0] obs_em,
    output var logic [39:0] obs_ob,
    output var logic [25:0] obs_oalow,
    output var logic [21:0] obs_oahigh,
    output var logic [1:0]  obs_grant,
    output var logic [31:0] obs_gaddr,
    output var logic        obs_mdl,
    output var logic [39:0] obs_mdword,
    output var logic        obs_reg,
    output var logic [31:0] obs_raddr,
    output var logic [3:0]  obs_queue,
    output var logic [4:0]  obs_inflight,
    output var logic        obs_halted,
    output var logic [1:0]  obs_errhalt
);

  localparam logic [13:0] RESET_PC = 14'o36000;

  // ===================================================================== types

  // RD's speculative copies (`Copies`): the micro stack's pointer and top
  // (after a pop the top is the stack's word below, `spc_below`; a data push
  // not yet committed, by its word's `seq`), the PDL pointer and index and a
  // write of either from the ALU not yet committed, LC's counter, NEEDFETCH,
  // byte mode and an LC write not yet committed, and NEXT INSTR.
  typedef struct packed {
    logic [4:0]  spc_ptr;
    logic [18:0] spc_top;
    logic        spc_below;
    logic        spc_pend;
    logic [7:0]  spc_seq;
    logic [13:0] ptr;
    logic        ptr_pend;
    logic [7:0]  ptr_seq;
    logic [13:0] idx;
    logic        idx_pend;
    logic [7:0]  idx_seq;
    logic [33:0] lc;
    logic        nf;
    logic        bm;
    logic        lc_pend;
    logic [7:0]  lc_seq;
    logic        next_instr;
  } copies_t;

  // A word's effects on the copies, in the order `plan_for` makes them
  // (`Effect`).
  localparam logic [2:0] D_NONE = 3'd0, D_LC = 3'd1, D_PDL_INC = 3'd2, D_IDX = 3'd3,
                         D_IDX_W = 3'd4, D_PTR_W = 3'd5, D_SPC = 3'd6;
  typedef struct packed {
    logic        lcstep_own;   // the microcycle's own step, NEXT INSTRD
    logic        spcpop_src;   // functional source 14, but on a dispatch
    logic        pdl_dec;      // functional source 4
    logic [2:0]  dest;         // the destination's
    logic [13:0] idx_val;      // the PDL address field's index
    logic [7:0]  seq;          // the writer
    logic        lcstep_disp;  // a dispatch's IR<24>
    logic        spcpop_disp;  // a dispatch's source 14 with R predicted
    logic        push;         // a call's return, pushed
    logic [18:0] push_word;
    logic        ret;          // a return, popped
    logic        ret_ni;       // and the step it asks for
  } effects_t;

  // RD's choices for its word (`RdPlan`).
  typedef struct packed {
    effects_t    e;
    logic        next2_v;
    logic [13:0] next2;
    logic        resolved;
    logic        pred_taken_v;
    logic        pred_taken;
    logic        pred_pr_v;
    logic [1:0]  pred_pr;      // {P, R}
    logic        kills;
    logic        returns;
    logic        ub_macro;
  } plan_t;

  // The micro stack's pointer and flags through one microcycle (`push_spc`,
  // `pop_spc`, `ignpopj`), the write a push leaves for the next, and the
  // word a pop took.
  typedef struct packed {
    logic [4:0]  sp;
    logic        pushed;
    logic        spc_pushed;
    logic        spc_popped;
    logic        sw_v;
    logic [4:0]  sw_ptr;
    logic [18:0] sw_word;
    logic [18:0] popped;
  } spcx_t;

  // ===================================================================== state

  // --- The stages.  A word's `seq` is its place in program order, eight
  // bits, compared by difference.
  logic        cs_v, cs_nop, cs_pre_nop, cs_trap;
  logic [7:0]  cs_seq;
  logic [13:0] cs_pc;

  logic        rd_v, rd_nop, rd_pre_nop;
  logic [7:0]  rd_seq;
  logic [13:0] rd_pc;
  logic [63:0] rd_word;
  logic [47:0] rd_ir;
  logic [9:0]  rd_a_addr;
  logic        rd_a_fix_v;
  logic [39:0] rd_a_fix;
  logic [4:0]  rd_m_addr;
  logic [39:0] rd_m;
  logic [13:0] rd_pdl_addr;
  logic        rd_pdl_fix_v;
  logic [39:0] rd_pdl_fix;

  logic        ex_v, ex_nop, ex_pre_nop;
  logic [7:0]  ex_seq;
  logic [13:0] ex_pc;
  logic [63:0] ex_word;
  logic [47:0] ex_ir;
  logic [9:0]  ex_a_addr;
  logic [39:0] ex_a;
  logic [4:0]  ex_m_addr;
  logic [39:0] ex_m;
  logic [39:0] ex_pdl;
  logic        ex_next2_v, ex_resolved, ex_pred_taken_v, ex_pred_taken, ex_pred_pr_v;
  logic [13:0] ex_next2;
  logic [1:0]  ex_pred_pr;
  logic [4:0]  ex_clocks;

  logic        wb_v, wb_nop, wb_m31;
  logic        wb_a_we, wb_m_we, wb_pdl_we, wb_pdl_at_index, wb_imem_we;
  logic [9:0]  wb_a_addr;
  logic [4:0]  wb_m_addr;
  logic [39:0] wb_data;
  logic [13:0] wb_pdl_addr;
  logic [39:0] wb_pdl_data;
  logic [7:0]  wb_seq;
  logic [13:0] wb_pc;
  logic [13:0] wb_imem_addr;
  logic [63:0] wb_imem_data;

  // --- The front end: the next fetch's address, the one after it when RD
  // or a redirect chose it before the word between was fetched, the next
  // fetched word's squashes, and the sequence counter.
  logic [13:0] npc, npc_after;
  logic        npc_after_v, nop_next, pre_nop_next;
  logic [7:0]  seq_ctr;

  // --- RD's copies.
  copies_t     c;

  // --- The registers EX writes, at its end.
  logic [39:0] q, vma, md;
  logic [33:0] lc;
  logic        lc_needfetch;
  logic [13:0] pdl_ptr, pdl_idx;
  logic [4:0]  spcptr;
  logic [3:0]  intctl;      // INTERRUPT-CONTROL's `<29:26>`
  logic [9:0]  dc;          // the dispatch constant
  logic        overflow;
  logic [25:0] oa_low;
  logic [21:0] oa_high;
  logic [13:0] opc[8];
  logic [13:0] npc_prev;    // `micro`'s `npc`, for EX's check of RD's choices
  logic        next_instrd; // NEXT INSTRD: the next microcycle steps LC
  // The micro stack's write a push leaves, landing in the next microcycle
  // after its reads (`Exec::spc_write`).
  logic        spc_w_v;
  logic [4:0]  spc_w_ptr;
  logic [18:0] spc_w_word;
  logic [1:0]  errhalt;
  logic        errhalt_now;

  // --- The memories: M and the micro stack in flip-flops, dispatch memory
  // read in EX.  Each comes up as muir's machine has it; a testbench may
  // load them as a bitstream would (`public_flat_rw`).
  logic [39:0] mmem[32] /* verilator public_flat_rw */;
  logic [16:0] dmem[4096] /* verilator public_flat_rw */;
  logic [18:0] spc[32];
  initial begin
    for (int k = 0; k < 32; k++) mmem[k] = 40'd0;
    for (int k = 0; k < 4096; k++) dmem[k] = 17'd0;
    for (int k = 0; k < 32; k++) spc[k] = 19'd0;
  end

  // ================================================================= the store

  logic        store_re;
  logic [13:0] store_raddr;
  logic [63:0] store_q, cs_word;
  logic        running;
  quux15_store #(.PROM_HEX(PROM_HEX)) store (
      .clk  (clk),
      .re   (store_re),
      .raddr(store_raddr),
      .rdata(store_q),
      .we   (wb_v && wb_imem_we && running),
      .waddr(wb_imem_addr),
      .wdata(wb_imem_data)
  );
  // The boot's trap is a word of zeros, read from nowhere.
  assign cs_word = cs_trap ? 64'd0 : store_q;

  // ========================================================= A and the PDL

  logic        a_re, pdl_re;
  logic [9:0]  a_raddr;
  logic [13:0] pdl_raddr;
  logic [39:0] a_q, pdl_q;
  logic        land_a_we, land_m_we, land_pdl_we;
  logic [9:0]  land_a_addr;
  logic [4:0]  land_m_addr;
  logic [39:0] land_data, land_pdl_data;
  logic [13:0] land_pdl_addr;
  logic [7:0]  land_pdl_seq;

  quux15_ram #(.WIDTH(40), .DEPTH(1024)) amem (
      .clk  (clk),
      .re   (a_re),
      .raddr(a_raddr),
      .rdata(a_q),
      .we   (land_a_we && running),
      .waddr(land_a_addr),
      .wdata(land_data)
  );
  quux15_ram #(.WIDTH(40), .DEPTH(16384)) pdl (
      .clk  (clk),
      .re   (pdl_re),
      .raddr(pdl_raddr),
      .rdata(pdl_q),
      .we   (land_pdl_we && running),
      .waddr(land_pdl_addr),
      .wdata(land_pdl_data)
  );

  // The machine runs: out of reset, and no error halt now or before.  The
  // RAMs take no write in reset, when WB's registers are whatever they came
  // up as.
  assign running = !rst && errhalt == 2'd0 && !errhalt_now;

  // RD's operands: the RAM's word, or a forward that replaced it.
  logic [39:0] rd_a, rd_pdl;
  assign rd_a   = rd_a_fix_v ? rd_a_fix : a_q;
  assign rd_pdl = rd_pdl_fix_v ? rd_pdl_fix : pdl_q;

  // ============================================================ decoding help

  // Each of these reads the fields of a word it needs.
  /* verilator lint_off UNUSEDSIGNAL */
  // A functional destination's code, 34-37 as 30-33 and 24-27 as 20-23
  // (`dest_code`); `has_fd` when the word has one.
  function automatic logic [4:0] fd_code(input logic [47:0] ir);
    logic [4:0] cd;
    cd = ir[23:19];
    return cd[4] ? (cd & ~5'o4) : cd;
  endfunction
  function automatic logic has_fd(input logic [47:0] ir);
    return (ir[44:43] == 2'd0 || ir[44:43] == 2'd3) && !ir[25];
  endfunction
  // Whether a JUMP's condition is always true or never (`unconditional`):
  // `{known, taken}`.
  function automatic logic [1:0] unconditional(input logic [47:0] ir);
    if (!ir[5]) return 2'b00;
    if (ir[4:0] == 5'o10 || ir[4:0] == 5'o11 || ir[4:0] == 5'o12 || ir[2:0] != 3'd7) return 2'b00;
    return {1'b1, !ir[6]};
  endfunction
  // A word's M source reads the PDL buffer: functional sources 4, 5, 24, 25
  // (`reads_pdl`); `{reads, by the pointer}`.
  function automatic logic [1:0] reads_pdl(input logic [47:0] ir);
    if (!ir[31]) return 2'b00;
    if (ir[29:26] == 4'o4 || ir[29:26] == 4'o5) return {1'b1, ir[30]};
    return 2'b00;
  endfunction
  // Functional source 14, the micro stack popped.
  function automatic logic pops_spc(input logic [47:0] ir);
    return ir[31] && ir[29:26] == 4'o14;
  endfunction
  // A word that writes OA-REG-HIGH, destination 17.
  function automatic logic writes_oa_high(input logic [47:0] ir);
    return has_fd(ir) && fd_code(ir) == 5'o17;
  endfunction
  // A word that writes M 31 (`writes_m31`).
  function automatic logic writes_m31(input logic [47:0] ir);
    return has_fd(ir) && ir[18:14] == 5'o31;
  endfunction
  // The fields the OA selects reach (A15b.15, `oa_fields`): `{high's, low's}`.
  function automatic logic [95:0] oa_fields(input logic [47:0] ir);
    logic [47:0] dst, src, lo, hi;
    dst = ir[25] ? (48'o1777 << 14) : (48'o37 << 14);
    src = (48'o1777 << 32) | (ir[31] ? 48'd0 : (48'o37 << 26));
    unique case (ir[44:43])
      2'd0: begin lo = dst | (48'o17 << 3); hi = src; end
      2'd3: begin lo = dst | 48'o7777;      hi = src; end
      2'd1: begin lo = 48'o37777 << 12;     hi = src; end
      default: begin
        lo = (ir[11:10] == 2'd2) ? (48'o7777 << 12) : 48'd0;
        hi = 48'd0;
      end
    endcase
    return {hi, lo};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // What a simulation stops at: a word that needs what is not built.
  localparam int UNBUILT_BITS = 3;
  logic [UNBUILT_BITS-1:0] unbuilt;
  localparam int U_START = 0;   // a memory start or LC's fetch, MAP(MD), the map, map bits (slice 3)
  localparam int U_MACRO = 1;   // MACRO-DISPATCH: destinations 5-7, the PDL field on M-AP or A-LOCALP (slice 4)
  localparam int U_TIME  = 2;   // the microsecond clock, source 15 (slice 5)

  // ======================================================== RD's copies' help

  // Each of these reads the fields of the copies, a word or an entry it needs.
  /* verilator lint_off UNUSEDSIGNAL */

  function automatic copies_t lc_step(input copies_t ci);
    copies_t r;
    r = ci;
    r.next_instr = 1'b0;
    if (r.lc_pend) return r;
    r.lc = r.lc + (r.bm ? 34'd1 : 34'd2);
    r.nf = !((r.bm && r.lc[0]) || r.lc[1]);
    return r;
  endfunction
  function automatic copies_t spc_pop(input copies_t ci);
    copies_t r;
    r = ci;
    r.spc_ptr = r.spc_ptr - 5'd1;
    r.spc_below = 1'b1;
    r.spc_pend = 1'b0;
    return r;
  endfunction
  function automatic copies_t spc_push(input copies_t ci, input logic [18:0] w);
    copies_t r;
    r = ci;
    r.spc_ptr = r.spc_ptr + 5'd1;
    r.spc_top = w;
    r.spc_below = 1'b0;
    r.spc_pend = 1'b0;
    return r;
  endfunction
  // `apply_effect`, each of a plan's effects in their order.
  function automatic copies_t apply_effects(input effects_t e, input copies_t ci);
    copies_t r;
    r = ci;
    if (e.lcstep_own) r = lc_step(r);
    if (e.spcpop_src) r = spc_pop(r);
    if (e.pdl_dec) r.ptr = r.ptr - 14'd1;
    unique case (e.dest)
      D_LC:      begin r.lc_pend = 1'b1; r.lc_seq = e.seq; r.nf = 1'b1; end
      D_PDL_INC: r.ptr = r.ptr + 14'd1;
      D_IDX:     begin r.idx = e.idx_val; r.idx_pend = 1'b0; end
      D_IDX_W:   begin r.idx_pend = 1'b1; r.idx_seq = e.seq; end
      D_PTR_W:   begin r.ptr_pend = 1'b1; r.ptr_seq = e.seq; end
      D_SPC:     begin
        r.spc_ptr = r.spc_ptr + 5'd1;
        r.spc_pend = 1'b1;
        r.spc_seq = e.seq;
        r.spc_below = 1'b0;
      end
      default: ;
    endcase
    if (e.lcstep_disp) r = lc_step(r);
    if (e.spcpop_disp) r = spc_pop(r);
    if (e.push) r = spc_push(r, e.push_word);
    if (e.ret) begin
      r = spc_pop(r);
      if (e.ret_ni) r.next_instr = 1'b1;
    end
    return r;
  endfunction

  // The micro stack as EX leaves it this clock, for the copies RD takes
  // after EX (`view_new`): the write the last microcycle left, landed by
  // this one's commit, and the one this one leaves.
  // (Every signal EX computes this clock comes into these functions as an
  // argument, so that the order the simulator evaluates them in sees it.)
  logic        nsw_v;
  logic [4:0]  nsw_ptr;
  logic [18:0] nsw_word;
  logic        land_spc;
  function automatic logic [18:0] spc_after_ex(input logic [4:0] a, input logic lnd);
    return (lnd && spc_w_ptr == a) ? spc_w_word : spc[a];
  endfunction
  // RD's copy of the stack's top (`top`): the word it holds, or after a pop
  // the stack's word below, as the word in EX leaves it.
  function automatic logic [18:0] top_of(input copies_t ci, input logic view_new, input logic sw_v,
                                         input logic [4:0] sw_ptr, input logic [18:0] sw_word,
                                         input logic lnd);
    if (!ci.spc_below) return ci.spc_top;
    if (view_new) return (sw_v && sw_ptr == ci.spc_ptr) ? sw_word : spc_after_ex(ci.spc_ptr, lnd);
    return (spc_w_v && spc_w_ptr == ci.spc_ptr) ? spc_w_word : spc[ci.spc_ptr];
  endfunction

  // **RD's choices for its word** (`plan_for`, with `rd_return`), from the
  // copies `c0`; `follower` is the address of the word after it.  A return
  // whose popped word asks for the main loop (`<14>`) resolves in RD only
  // when no fetch is due: MACRO-DISPATCH is not built, so there is no fused
  // return.
  function automatic plan_t rd_plan(input copies_t c0, input logic [13:0] follower,
                                    input logic view_new, input logic nop, input logic pre_nop,
                                    input logic sw_v, input logic [4:0] sw_ptr,
                                    input logic [18:0] sw_word, input logic lnd);
    plan_t       p;
    copies_t     cc;
    logic [13:0] ret, base, target;
    logic [1:0]  unc;
    logic        taken, has_t, retn;
    logic [18:0] popped;
    p = '0;
    p.e.dest = D_NONE;
    cc = c0;
    // The microcycle's own step, executed or nopped.
    if (cc.next_instr) begin
      p.e.lcstep_own = 1'b1;
      cc = lc_step(cc);
    end
    if (nop || pre_nop) return p;
    if (pops_spc(rd_ir) && rd_ir[44:43] != 2'd2) begin
      p.e.spcpop_src = 1'b1;
      cc = spc_pop(cc);
    end
    if (rd_ir[31] && rd_ir[29:26] == 4'o4) begin
      p.e.pdl_dec = 1'b1;
      cc.ptr = cc.ptr - 14'd1;
    end
    p.e.seq = rd_seq;
    if (has_fd(rd_ir)) begin
      unique case (fd_code(rd_ir))
        5'o1: begin
          p.e.dest = D_LC;
          cc.lc_pend = 1'b1;
          cc.lc_seq = rd_seq;
          cc.nf = 1'b1;
        end
        5'o11: begin
          p.e.dest = D_PDL_INC;
          cc.ptr = cc.ptr + 14'd1;
        end
        5'o13: begin
          // The PDL address field forms the index early (A15b.2), unless
          // its base is still being written.
          p.e.dest = D_IDX_W;
          if (rd_word[48]) begin
            if (rd_word[50:49] == 2'd2 && !cc.ptr_pend) p.e.dest = D_IDX;
            if (rd_word[50:49] == 2'd3 && !cc.idx_pend) p.e.dest = D_IDX;
            if (!rd_word[50]) p.ub_macro = 1'b1;
          end
          base = rd_word[49] ? cc.idx : cc.ptr;
          p.e.idx_val = base + {{6{rd_word[58]}}, rd_word[58:51]};
          if (p.e.dest == D_IDX) begin
            cc.idx = p.e.idx_val;
            cc.idx_pend = 1'b0;
          end else begin
            cc.idx_pend = 1'b1;
            cc.idx_seq = rd_seq;
          end
        end
        5'o14: begin
          p.e.dest = D_PTR_W;
          cc.ptr_pend = 1'b1;
          cc.ptr_seq = rd_seq;
        end
        5'o15: begin
          p.e.dest = D_SPC;
          cc.spc_ptr = cc.spc_ptr + 5'd1;
          cc.spc_pend = 1'b1;
          cc.spc_seq = rd_seq;
          cc.spc_below = 1'b0;
        end
        default: ;
      endcase
    end
    retn   = 1'b0;
    taken  = 1'b0;
    unc    = 2'b00;
    ret    = 14'd0;
    unique case (rd_ir[44:43])
      2'd1: begin
        // JUMP.
        ret = rd_ir[7] ? follower : follower + 14'd1;
        if (rd_ir[9] && rd_ir[8]) begin
          // WRITE-I-MEM: EX writes the store and fetches again.
          p.resolved = 1'b1;
        end else if (rd_word[60] || rd_ir[42]) begin
          // SL takes its target in EX, and a JUMP with POPJ transfers there
          // (A15b.15); RD fetches on, and pushes a call's return.
          p.resolved = 1'b1;
          if (rd_ir[8] && rd_word[60] && !rd_ir[42]) begin
            p.e.push = 1'b1;
            p.e.push_word = {5'd0, ret};
            cc = spc_push(cc, {5'd0, ret});
          end
        end else begin
          unc = unconditional(rd_ir);
          if (unc[1]) taken = unc[0];
          else begin
            // A conditional jump: its hint, H (A15b.2).
            p.resolved = 1'b1;
            taken = rd_word[48];
            p.pred_taken_v = 1'b1;
            p.pred_taken = taken;
          end
          if (taken) begin
            if (rd_ir[8]) begin
              p.e.push = 1'b1;
              p.e.push_word = {5'd0, ret};
              cc = spc_push(cc, {5'd0, ret});
            end
            p.next2_v = 1'b1;
            p.next2 = rd_ir[25:12];
            p.kills = rd_ir[7];
            retn = rd_ir[9];
          end
        end
      end
      2'd2: begin
        // DISPATCH.
        if (rd_ir[24]) begin
          p.e.lcstep_disp = 1'b1;
          cc = lc_step(cc);
        end
        if (rd_ir[11:10] == 2'd2) begin
          // A dispatch-memory write transfers only through IGNPOPJ, with
          // POPJ: EX decides.
          p.resolved = rd_ir[42];
        end else begin
          // The predicted target (A15b.2): P and R stored inverted.
          p.resolved = 1'b1;
          p.pred_pr_v = 1'b1;
          p.pred_pr = {!rd_word[62], !rd_word[63]};
          if (pops_spc(rd_ir) && !rd_word[63]) begin
            p.e.spcpop_disp = 1'b1;
            cc = spc_pop(cc);
          end
          if (p.pred_pr == 2'b11) retn = rd_ir[42];
          else if (p.pred_pr == 2'b00) begin
            p.next2_v = 1'b1;
            p.next2 = rd_word[61:48];
          end else if (p.pred_pr == 2'b10) begin
            p.e.push = 1'b1;
            p.e.push_word = {5'd0, follower + 14'd1};
            cc = spc_push(cc, {5'd0, follower + 14'd1});
            p.next2_v = 1'b1;
            p.next2 = rd_word[61:48];
          end else retn = 1'b1;
        end
      end
      default: begin
        // ALU, BYTE: POPJ, unless the stack changed by data, which EX decides.
        if (rd_ir[42]) begin
          if ((has_fd(rd_ir) && fd_code(rd_ir) == 5'o15) || pops_spc(rd_ir)) begin
            p.returns = 1'b1;
            p.resolved = 1'b1;
          end else retn = 1'b1;
        end
      end
    endcase
    if (retn) begin
      // `rd_return`.
      p.returns = 1'b1;
      p.e.ret = 1'b1;
      popped = top_of(cc, view_new, sw_v, sw_ptr, sw_word, lnd);
      cc = spc_pop(cc);
      has_t = 1'b1;
      target = popped[13:0];
      if (popped[14]) begin
        if (!pops_spc(rd_ir)) begin
          p.e.ret_ni = 1'b1;
          cc.next_instr = 1'b1;
        end
        if (cc.lc_pend || cc.nf) has_t = 1'b0;
        else target = popped[13:0] | 14'd2;
      end
      p.next2_v = has_t;
      p.next2 = target;
      if (!has_t) p.resolved = 1'b1;
    end
    return p;
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

  // **The guard** (A15b.16): a return RD resolves or predicts waits a clock
  // while the word in EX writes INTERRUPT-CONTROL, MACRO-DISPATCH's
  // registers, the stack's data or M 31, or LC in a microcycle that steps
  // it; and while the word in WB, in its first clock, writes M 31.
  logic        nid_new;
  function automatic logic guard_holds(input logic view_new, input logic nid);
    logic h, steps;
    h = 1'b0;
    if (ex_v && !ex_nop) begin
      if (has_fd(ex_ir) && (fd_code(ex_ir) == 5'o2 || fd_code(ex_ir) == 5'o5 || fd_code(ex_ir) == 5'o6
                            || fd_code(ex_ir) == 5'o7 || fd_code(ex_ir) == 5'o15))
        h = 1'b1;
      if (writes_m31(ex_ir)) h = 1'b1;
      steps = (view_new ? nid : next_instrd) || (ex_ir[44:43] == 2'd2 && ex_ir[24]);
      if (has_fd(ex_ir) && fd_code(ex_ir) == 5'o1 && steps) h = 1'b1;
    end
    if (!view_new && wb_v && !wb_nop && wb_m31) h = 1'b1;
    return h;
  endfunction

  // ======================================================================= WB
  //
  // `wb_stage`: the word's A, M and PDL buffer writes land at its clock's
  // edge, and WRITE-I-MEM's control store word.  Nothing holds WB yet: with
  // no starts, every word leaves after a clock.

  always_comb begin
    land_a_we     = wb_v && wb_a_we;
    land_a_addr   = wb_a_addr;
    land_m_we     = wb_v && wb_m_we;
    land_m_addr   = wb_m_addr;
    land_data     = wb_data;
    land_pdl_we   = wb_v && wb_pdl_we;
    // A write by the index takes the index as it stands at WB: the word's own
    // write counts, the next word's, at this clock's end, does not.
    land_pdl_addr = wb_pdl_at_index ? pdl_idx : wb_pdl_addr;
    land_pdl_data = wb_pdl_data;
    land_pdl_seq  = wb_seq;
  end

  // ======================================================================= EX

  // d1: WB's writes this clock into EX's operands.
  logic [39:0] ex_a_d1, ex_m_d1;
  always_comb begin
    ex_a_d1 = (land_a_we && land_a_addr == ex_a_addr) ? land_data : ex_a;
    ex_m_d1 = (land_m_we && land_m_addr == ex_m_addr && !ex_ir[31]) ? land_data : ex_m;
  end

  // The word with its OA selects (`oa_selected`), and OA-OUTSIDE-FIELDS: a
  // register bit set in neither the word nor the class's fields.  SL is ORed
  // here; SH's fields, the A and M source, were read at CS and RD with it,
  // and nothing in EX reads them again, so EX takes only its check.
  logic [47:0] ex_low, ex_isel, oa_lo_bits, oa_hi_bits, f_lo, f_hi;
  logic        ex_sl, ex_sh, ex_outside;
  always_comb begin
    ex_low     = ex_word[47:0];
    ex_sl      = ex_word[60];
    ex_sh      = ex_word[61];
    {f_hi, f_lo} = oa_fields(ex_low);
    oa_lo_bits = {22'd0, oa_low};
    oa_hi_bits = {oa_high, 26'd0};
    ex_outside = (ex_sl && (oa_lo_bits & ~ex_low & ~f_lo) != 48'd0)
              || (ex_sh && (oa_hi_bits & ~ex_low & ~f_hi) != 48'd0);
    ex_isel    = ex_low | (ex_sl ? oa_lo_bits : 48'd0);
  end

  // MUL and DIV's clocks in EX, from the word RD decoded: DIV 18, MUL 5
  // (A15b.3; `muldiv::DIV_CLOCKS_15`, `MUL_CLOCKS_15`).
  logic ex_rd_mul, ex_rd_div, ex_hold, ex_try;
  logic [4:0] ex_needs;
  always_comb begin
    ex_rd_mul = !ex_nop && ex_ir[44:43] == 2'd0 && ex_ir[8] && ex_ir[4:3] == 2'd2;
    ex_rd_div = !ex_nop && ex_ir[44:43] == 2'd0 && ex_ir[8] && ex_ir[4:3] == 2'd3;
    ex_needs  = ex_rd_div ? 5'd18 : ex_rd_mul ? 5'd5 : 5'd1;
    ex_hold   = ex_v && (ex_clocks + 5'd1 < ex_needs);
    ex_try    = ex_v && !ex_hold;
  end

  // The M operand (`read_functional`): M memory's word, or a functional
  // source's.  The micro stack's word is the stack's before this
  // microcycle's landing of the last one's push.
  logic [4:0]  ex_msrc;
  logic [39:0] ex_func, ex_mdata;
  logic        ex_pop_pdl;
  always_comb begin
    ex_msrc    = ex_isel[30:26];
    ex_pop_pdl = 1'b0;
    unique case (ex_msrc[3:0])
      4'o0:  ex_func = {30'd0, dc};
      4'o1:  ex_func = {11'd0, spcptr, 5'd0, spc[spcptr]};
      4'o2:  ex_func = {26'd0, pdl_ptr};
      4'o3:  ex_func = {26'd0, pdl_idx};
      4'o4:  begin ex_func = ex_pdl; ex_pop_pdl = 1'b1; end
      4'o5:  ex_func = ex_pdl;
      4'o6:  ex_func = {26'd0, opc[7]};
      4'o7:  ex_func = q;
      4'o10: ex_func = vma;
      4'o12: ex_func = md;
      4'o13: ex_func = {lc_needfetch, 1'b0, intctl, intctl[3] ? lc : {lc[33:1], 1'b0}};
      4'o14: ex_func = {11'd0, spcptr, 5'd0, spc[spcptr]};
      4'o16: ex_func = {8'd0, MACHINE_ID};
      default: ex_func = {40{1'b1}};
    endcase
    ex_mdata = ex_isel[31] ? ex_func : ex_m_d1;
  end

  // The datapath.
  logic [39:0] x_ob, x_q;
  logic        x_ovf, x_lc_adder, x_jcond, x_mul, x_div;
  logic [1:0]  x_lc_high;
  logic [11:0] x_daddr;
  logic [31:0] mul_ob, mul_q, div_ob, div_q;
  quux15_exec exec (
      .ir            (ex_isel),
      .m             (ex_mdata),
      .a             (ex_a_d1),
      .q             (q),
      .lc            (lc),
      .byte_mode     (intctl[3]),
      .overflow      (overflow),
      .vmaok         (1'b0),
      .int_pending   (1'b0),
      .sequence_break(intctl[0]),
      .mul_ob        (mul_ob),
      .mul_q         (mul_q),
      .div_ob        (div_ob),
      .div_q         (div_q),
      .ob            (x_ob),
      .q_alu         (x_q),
      .overflow_alu  (x_ovf),
      .lc_adder      (x_lc_adder),
      .lc_high       (x_lc_high),
      .jcond         (x_jcond),
      .daddr         (x_daddr),
      .is_mul        (x_mul),
      .is_div        (x_div)
  );

  // MUL and DIV: the divider takes its operands at the edge ending EX's first
  // clock and has the words 16 edges later; the multiplier is the product.
  quux_muldiv muldiv (
      .clk   (clk),
      .rst   (rst),
      .load  (ex_v && ex_rd_div && ex_clocks == 5'd0 && errhalt == 2'd0),
      .m     (ex_mdata[31:0]),
      .dm    (ex_mdata[31:0]),
      .a     (ex_a_d1[31:0]),
      .q     (q[31:0]),
      .mul_ob(mul_ob),
      .mul_q (mul_q),
      .div_ob(div_ob),
      .div_q (div_q)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  // The stack's word at `a` once this microcycle has landed the last one's
  // push (`land_spc_write`): what `pop_spc` reads.
  function automatic logic [18:0] spc_landed(input logic [4:0] a);
    return (spc_w_v && spc_w_ptr == a) ? spc_w_word : spc[a];
  endfunction
  // `push_spc`.
  function automatic spcx_t push_spc(input spcx_t s, input logic [18:0] w);
    spcx_t r;
    r = s;
    r.pushed = 1'b1;
    if (r.spc_popped) r.sp = r.sp + 5'd1;
    r.spc_pushed = 1'b1;
    r.sp = r.sp + 5'd1;
    r.sw_v = 1'b1;
    r.sw_ptr = r.sp;
    r.sw_word = w;
    return r;
  endfunction
  // `pop_spc`: the word in `popped`.
  function automatic spcx_t pop_spc(input spcx_t s);
    spcx_t r;
    r = s;
    if (r.spc_pushed) begin
      r.spc_popped = 1'b1;
      r.popped = spc_landed(r.sp - 5'd1);
    end else if (r.spc_popped) begin
      r.popped = spc_landed(r.sp + 5'd1);
    end else begin
      r.popped = (r.sw_v && r.sw_ptr == r.sp) ? r.sw_word : spc_landed(r.sp);
      r.sp = r.sp - 5'd1;
      r.spc_popped = 1'b1;
    end
    return r;
  endfunction
  // `ignpopj`: a dispatch whose entry has no R gives back the source's pop.
  function automatic spcx_t ignpopj(input spcx_t s, input logic [16:0] e);
    spcx_t r;
    r = s;
    if (!e[16] && r.spc_popped) begin
      r.sp = r.sp + 5'd1;
      r.spc_popped = 1'b0;
    end
    return r;
  endfunction
  // `step_lc`: LC's counter steps; with NEEDFETCH a fetch starts:
  // `{fetch, NEEDFETCH, counter}`.
  function automatic logic [35:0] step_lc(input logic [33:0] l, input logic nf, input logic bm);
    logic [33:0] r;
    logic        nnf;
    r = l + (bm ? 34'd1 : 34'd2);
    nnf = !((bm && r[0]) || r[1]);
    return {nf, nnf, r};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // `execute`: what the word in EX does when it commits this clock.
  logic        commit, ex_alu, ex_byte, ex_jump, ex_disp;
  logic        inhibit, x_taken, wrote_imem, popj_end;
  logic [1:0]  entry_pr;
  logic [13:0] x_npc, x_npc_seq;
  logic [16:0] entry;
  logic [63:0] iwr;
  spcx_t       sx;
  // The writes it leaves for WB.
  logic        nx_a_we, nx_m_we, nx_pdl_we, nx_pdl_at_index;
  logic [9:0]  nx_a_addr;
  logic [4:0]  nx_m_addr;
  logic [13:0] nx_pdl_addr;
  // The registers at its end.
  logic [39:0] nq, nvma, nmd;
  logic [33:0] nlc;
  logic        nlc_nf, novf, nni;
  logic [13:0] nptr, nidx, formed;
  logic [3:0]  nintctl;
  logic [9:0]  ndc;
  logic [25:0] noa_low;
  logic [21:0] noa_high;
  logic        dmem_we, mismatch;
  logic [16:0] dmem_wdata;
  logic [35:0] stepped;
  logic [UNBUILT_BITS-1:0] ub_ex;
  always_comb begin
    errhalt_now = ex_try && !ex_nop && ex_outside;
    commit      = ex_try && !errhalt_now;
    ex_alu      = ex_isel[44:43] == 2'd0;
    ex_jump     = ex_isel[44:43] == 2'd1;
    ex_disp     = ex_isel[44:43] == 2'd2;
    ex_byte     = ex_isel[44:43] == 2'd3;
    nq = q; nvma = vma; nmd = md; nlc = lc; nlc_nf = lc_needfetch; novf = overflow;
    nptr = pdl_ptr; nidx = pdl_idx; nintctl = intctl; ndc = dc;
    noa_low = oa_low; noa_high = oa_high; nni = 1'b0; nid_new = next_instrd;
    nx_a_we = 1'b0; nx_m_we = 1'b0; nx_pdl_we = 1'b0; nx_pdl_at_index = 1'b0;
    nx_a_addr = 10'd0; nx_m_addr = 5'd0; nx_pdl_addr = 14'd0;
    dmem_we = 1'b0; dmem_wdata = ex_a_d1[16:0];
    inhibit = 1'b0; x_taken = 1'b0; wrote_imem = 1'b0; entry_pr = 2'd0;
    entry = dmem[x_daddr];
    iwr = {ex_a_d1[31:0], ex_mdata[31:0]};
    formed = 14'd0; mismatch = 1'b0; popj_end = 1'b0;
    stepped = '0;
    ub_ex = '0;
    sx = '0;
    sx.sp = spcptr;
    nsw_v = spc_w_v; nsw_ptr = spc_w_ptr; nsw_word = spc_w_word;
    land_spc = 1'b0;
    // `micro`'s `npc`: the address after the next word's, one past the
    // address the microcycle before chose.
    x_npc_seq = npc_prev + 14'd1;
    x_npc     = x_npc_seq;
    if (commit) begin
      // The last microcycle's push lands, after this one's reads.
      land_spc = spc_w_v;
      if (ex_nop) begin
        nsw_v = 1'b0;
      end else begin
        popj_end = ex_isel[42];
        if ((ex_alu || ex_byte) && ex_word[48]) begin
          if (!ex_word[50]) ub_ex[U_MACRO] = 1'b1;
          formed = (ex_word[49] ? pdl_idx : pdl_ptr) + {{6{ex_word[58]}}, ex_word[58:51]};
        end
        if (ex_isel[31] && ex_msrc[3:0] == 4'o11) ub_ex[U_START] = 1'b1;
        if (ex_isel[31] && ex_msrc[3:0] == 4'o15) ub_ex[U_TIME] = 1'b1;
        if (ex_pop_pdl && ex_isel[31]) nptr = pdl_ptr - 14'd1;
        if (pops_spc(ex_isel)) begin
          sx.sp = spcptr - 5'd1;
          sx.spc_popped = 1'b1;
        end
        if (ex_alu || ex_byte) begin
          if (ex_alu) begin
            nq   = x_q;
            novf = x_ovf;
          end
          if (ex_isel[25]) begin
            nx_a_we   = 1'b1;
            nx_a_addr = ex_isel[23:14];
          end else begin
            nx_a_we   = 1'b1;
            nx_a_addr = {5'd0, ex_isel[18:14]};
            nx_m_we   = 1'b1;
            nx_m_addr = ex_isel[18:14];
            // `write_functional`.
            unique case (fd_code(ex_isel))
              5'o1: begin
                nlc = {(ex_alu && x_lc_adder) ? x_lc_high : x_ob[33:32], x_ob[31:0]};
                if (!intctl[3]) nlc[0] = 1'b0;
                nlc_nf = 1'b1;
              end
              5'o2: nintctl = x_ob[37:34];
              5'o5, 5'o6, 5'o7: ub_ex[U_MACRO] = 1'b1;
              5'o10: begin
                nx_pdl_we   = 1'b1;
                nx_pdl_addr = nptr;
              end
              5'o11: begin
                nptr        = nptr + 14'd1;
                nx_pdl_we   = 1'b1;
                nx_pdl_addr = nptr;
              end
              5'o12: begin
                nx_pdl_we       = 1'b1;
                nx_pdl_at_index = 1'b1;
              end
              5'o13: nidx = x_ob[13:0];
              5'o14: nptr = x_ob[13:0];
              5'o15: sx = push_spc(sx, x_ob[18:0]);
              5'o16: noa_low = x_ob[25:0];
              5'o17: noa_high = x_ob[21:0];
              5'o20: nvma = x_ob;
              5'o21, 5'o22, 5'o23, 5'o31, 5'o32, 5'o33: ub_ex[U_START] = 1'b1;
              5'o30: nmd = x_ob;
              default: ;
            endcase
          end
        end else if (ex_jump) begin
          // `jump`.
          if (ex_isel[9] && ex_isel[8]) begin
            // WRITE-I-MEM: the store at the address from IWR, in WB; the
            // words behind are fetched again (A15b.4).
            wrote_imem = 1'b1;
            if (!ex_isel[6] && x_jcond) begin
              sx = push_spc(sx, {5'd0, ex_isel[7] ? x_npc - 14'd1 : x_npc});
              sx.spc_pushed = 1'b0;
              sx.spc_popped = 1'b0;
              sx = pop_spc(sx);
            end
          end else begin
            x_taken = x_jcond != ex_isel[6];
            if (ex_isel[8] && x_taken)
              sx = push_spc(sx, {5'd0, ex_isel[7] ? x_npc - 14'd1 : x_npc});
            if (x_taken) begin
              x_npc = ex_isel[25:12];
              if (ex_isel[9]) begin
                sx = pop_spc(sx);
                x_npc = sx.popped[13:0];
                if (sx.popped[14]) begin
                  // `jump_return`, MACRO-DISPATCH off: the fetch asked for.
                  if (!pops_spc(ex_isel)) nni = 1'b1;
                  if (!lc_needfetch) x_npc[1] = 1'b1;
                end
                popj_end = 1'b0;
              end
              inhibit = ex_isel[7];
            end
          end
        end else begin
          // `dispatch`: a dispatch-memory write, or the entry's transfer.
          // **EVERY DISPATCH LOADS THE DISPATCH CONSTANT**, a dispatch-memory
          // write included: page DSPCTL's 25S07s are clocked under -IRDISP.
          if (ex_isel[9:8] != 2'd0) ub_ex[U_START] = 1'b1;
          ndc = ex_isel[41:32];
          if (ex_isel[11:10] == 2'd2) begin
            dmem_we = 1'b1;
            sx = ignpopj(sx, entry);
            if (popj_end && !entry[16]) begin
              x_npc = entry[13:0];
              popj_end = 1'b0;
            end
          end else begin
            entry_pr = {entry[15], entry[16]};
            sx = ignpopj(sx, entry);
            if (ex_isel[24]) begin
              stepped = step_lc(nlc, nlc_nf, intctl[3]);
              if (stepped[35]) ub_ex[U_START] = 1'b1;
              nlc = stepped[33:0];
              nlc_nf = stepped[34];
            end
            inhibit = entry[14];
            if (!(entry[15] && entry[16])) begin
              if (entry[15])
                sx = push_spc(sx, {5'd0, entry[14] ? (ex_isel[25] ? x_npc - 14'd2 : x_npc - 14'd1)
                                                   : x_npc});
              x_npc = entry[13:0];
              if (entry[16]) begin
                sx = pop_spc(sx);
                x_npc = sx.popped[13:0];
                if (sx.popped[14]) begin
                  if (!pops_spc(ex_isel)) nni = 1'b1;
                  if (!nlc_nf) x_npc[1] = 1'b1;
                end
              end
              popj_end = 1'b0;
            end
          end
        end
        // POPJ: a return at the microcycle's end.
        if (popj_end) begin
          sx = pop_spc(sx);
          x_npc = sx.popped[13:0];
          if (sx.popped[14]) begin
            if (!pops_spc(ex_isel)) nni = 1'b1;
            if (!nlc_nf) x_npc[1] = 1'b1;
          end
        end
        nsw_v = sx.sw_v; nsw_ptr = sx.sw_ptr; nsw_word = sx.sw_word;
        mismatch = (ex_alu || ex_byte) && ex_word[48] && ex_word[50] && formed != nidx;
      end
      // `end_of_microcycle`: NEXT INSTRD steps LC, fetching with NEEDFETCH.
      if (next_instrd) begin
        stepped = step_lc(nlc, nlc_nf, nintctl[3]);
        if (stepped[35]) ub_ex[U_START] = 1'b1;
        nlc = stepped[33:0];
        nlc_nf = stepped[34];
      end
      nid_new = nni;
    end
  end

  // EX's check of RD's choices (`ex_stage`'s end): a choice that was wrong,
  // or a nopped slot that runs, redirects the front end; WRITE-I-MEM fetches
  // the words behind it again.
  logic        kill_rd, ex_restore, slot_pre_nopped, redirect, refetch;
  logic [13:0] redirect_to;
  logic [7:0]  slot_seq;
  always_comb begin
    slot_seq        = ex_seq + 8'd1;
    kill_rd         = commit && !ex_nop && inhibit;
    ex_restore      = commit && !ex_nop && ex_resolved && inhibit;
    slot_pre_nopped = (rd_v && rd_seq == slot_seq && rd_pre_nop)
                   || (cs_v && cs_seq == slot_seq && cs_pre_nop)
                   || (pre_nop_next && !(rd_v && rd_seq == slot_seq) && !(cs_v && cs_seq == slot_seq));
    redirect    = 1'b0;
    refetch     = 1'b0;
    redirect_to = x_npc;
    if (commit && !ex_nop) begin
      if (wrote_imem) begin
        redirect    = 1'b1;
        refetch     = 1'b1;
        redirect_to = ex_pc + 14'd1;
      end else if (ex_resolved) begin
        if (x_npc != (ex_next2_v ? ex_next2 : x_npc_seq)
            || (ex_pred_taken_v && ex_pred_taken != x_taken)
            || (ex_pred_pr_v && ex_pred_pr != entry_pr))
          redirect = 1'b1;
      end
      if (!redirect && !inhibit && slot_pre_nopped) redirect = 1'b1;
    end
  end

  // ================================================================ the front

  // The copies after EX: refreshed by the commit of the word that wrote them
  // from the ALU (`refresh_pending`), and restored from the registers as EX
  // leaves them (`restore_copies`).
  logic [18:0] arch_top_new;
  copies_t     c_ref, c_res;
  always_comb begin
    arch_top_new = (nsw_v && nsw_ptr == sx.sp) ? nsw_word : spc_after_ex(sx.sp, land_spc);
    c_ref = c;
    if (commit) begin
      if (c.idx_pend && c.idx_seq == ex_seq) begin
        c_ref.idx_pend = 1'b0;
        c_ref.idx = nidx;
      end
      if (c.ptr_pend && c.ptr_seq == ex_seq) begin
        c_ref.ptr_pend = 1'b0;
        c_ref.ptr = nptr;
      end
      if (c.spc_pend && c.spc_seq == ex_seq) begin
        c_ref.spc_pend = 1'b0;
        c_ref.spc_top = arch_top_new;
        c_ref.spc_below = 1'b0;
      end
      if (c.lc_pend && c.lc_seq == ex_seq) begin
        c_ref.lc_pend = 1'b0;
        c_ref.lc = nlc;
        c_ref.nf = nlc_nf;
      end
      // INTERRUPT-CONTROL's byte mode, which the guard holds behind.
      c_ref.bm = nintctl[3];
    end
    c_res = '0;
    c_res.spc_ptr = sx.sp;
    c_res.spc_top = arch_top_new;
    c_res.ptr = nptr;
    c_res.idx = nidx;
    c_res.lc = nlc;
    c_res.nf = nlc_nf;
    c_res.bm = nintctl[3];
    c_res.next_instr = nid_new;
  end

  // **The front end** (`front_and_edge`): a redirect's squash and restore,
  // or EX's squash of the delay slot under N; RD's choices made for the word
  // in RD.
  logic        ex_free, rd_keep, cs_keep, rd_n_nop, rd_n_pre, cs_n_nop, cs_n_pre;
  logic        refetch_slot, slot_here, view_new, rd_moves, cs_follows, block_load;
  logic [13:0] refetch_pc, follower, npc_e, npc_after_e;
  logic        npc_after_v_e, nop_next_e, pre_nop_next_e;
  logic [7:0]  seq_e;
  copies_t     c_dec, c_app, c_next;
  plan_t       plan;
  logic        hold;
  always_comb begin
    ex_free  = !ex_v || commit;
    rd_keep  = rd_v;
    cs_keep  = cs_v;
    rd_n_nop = rd_nop;
    rd_n_pre = rd_pre_nop;
    cs_n_nop = cs_nop;
    cs_n_pre = cs_pre_nop;
    refetch_slot = 1'b0;
    refetch_pc   = 14'd0;
    slot_here    = 1'b0;
    npc_e = npc; npc_after_e = npc_after; npc_after_v_e = npc_after_v;
    nop_next_e = nop_next; pre_nop_next_e = pre_nop_next;
    seq_e = seq_ctr;
    block_load = 1'b0;
    view_new = 1'b0;
    c_dec = c;
    c_app = c_ref;
    if (redirect) begin
      // Every word after the delay slot leaves nothing; the delay slot stays,
      // nopped under N, wherever it is; nopped by RD's prediction and running
      // after all, it is fetched again.
      view_new = 1'b1;
      if (rd_v) begin
        if (rd_seq == slot_seq && !refetch) begin
          if (kill_rd) begin
            rd_n_nop = 1'b1;
            rd_n_pre = 1'b0;
          end else if (rd_pre_nop) begin
            refetch_slot = 1'b1;
            refetch_pc = rd_pc;
            rd_keep = 1'b0;
          end
        end else rd_keep = 1'b0;
      end
      if (cs_v) begin
        if (cs_seq == slot_seq && !refetch) begin
          if (kill_rd) begin
            cs_n_nop = 1'b1;
            cs_n_pre = 1'b0;
          end else if (cs_pre_nop) begin
            refetch_slot = 1'b1;
            refetch_pc = cs_pc;
            cs_keep = 1'b0;
          end
        end else cs_keep = 1'b0;
      end
      slot_here = (rd_keep && rd_seq == slot_seq) || (cs_keep && cs_seq == slot_seq);
      pre_nop_next_e = 1'b0;
      nop_next_e = 1'b0;
      if (refetch) begin
        npc_e = redirect_to;
        npc_after_v_e = 1'b0;
        block_load = 1'b1;
      end else if (refetch_slot) begin
        npc_e = refetch_pc;
        npc_after_e = redirect_to;
        npc_after_v_e = 1'b1;
      end else if (slot_here) begin
        npc_e = redirect_to;
        npc_after_v_e = 1'b0;
      end else begin
        // The delay slot not fetched yet: it comes first.
        npc_e = ex_pc + 14'd1;
        npc_after_e = redirect_to;
        npc_after_v_e = 1'b1;
        nop_next_e = kill_rd;
      end
      c_dec = c_res;
      c_app = c_res;
      // Sequence numbers follow the order words run in.
      if (cs_keep) seq_e = cs_seq + 8'd1;
      else if (rd_keep) seq_e = rd_seq + 8'd1;
      else seq_e = ex_seq + ((refetch_slot || !slot_here) ? 8'd0 : 8'd1) + 8'd1;
    end else begin
      if (ex_restore) begin
        view_new = 1'b1;
        c_dec = c_res;
        c_app = c_res;
      end
      if (kill_rd) begin
        if (rd_v && rd_seq == slot_seq) begin
          rd_n_nop = 1'b1;
          rd_n_pre = 1'b0;
          view_new = 1'b1;
          c_dec = c_app;
        end else if (cs_v && cs_seq == slot_seq) begin
          cs_n_nop = 1'b1;
          cs_n_pre = 1'b0;
        end else begin
          nop_next_e = 1'b1;
          pre_nop_next_e = 1'b0;
        end
      end
    end
    // The address of the word after RD's (`follower`), as `plan_for` reads
    // it: before EX at the clock's start, after a redirect or a restore.
    if (view_new) follower = (cs_keep && cs_seq == rd_seq + 8'd1) ? cs_pc : npc_e;
    else follower = (cs_v && cs_seq == rd_seq + 8'd1) ? cs_pc : npc;
    plan = rd_plan(c_dec, follower, view_new, rd_n_nop, rd_n_pre, nsw_v, nsw_ptr, nsw_word, land_spc);
    hold = plan.returns && guard_holds(view_new, nid_new);
    rd_moves = rd_keep && ex_free && !hold && errhalt_now == 1'b0;
    cs_follows = rd_keep && cs_keep && cs_seq == rd_seq + 8'd1;
    c_next = c_app;
    if (rd_moves) begin
      // `make_plan`.
      c_next = apply_effects(plan.e, c_app);
      if (plan.next2_v) begin
        if (cs_follows) begin
          npc_e = plan.next2;
          npc_after_v_e = 1'b0;
        end else begin
          npc_after_e = plan.next2;
          npc_after_v_e = 1'b1;
        end
      end
      if (plan.kills) begin
        if (cs_follows) cs_n_pre = 1'b1;
        else pre_nop_next_e = 1'b1;
      end
    end
  end

  // CS (`cs_hold`, `cs_reads`): the OA-REG-HIGH hold while its writer is in RD
  // or EX, and the PDL buffer's address waiting for a pointer or an index
  // written from the ALU.
  logic        rd_free, cs_hold, oa_hold, pdl_wait, cs_moves, cs_load;
  logic [47:0] cs_low, cs_ir, cs_sh_a, cs_sh_m;
  logic [1:0]  cs_rp;
  logic [13:0] cs_pdl_addr;
  always_comb begin
    rd_free  = !rd_keep || rd_moves;
    cs_low   = cs_word[47:0];
    oa_hold  = cs_word[61] && ((rd_keep && !rd_n_nop && writes_oa_high(rd_ir))
                            || (ex_v && !ex_nop && writes_oa_high(ex_ir)));
    cs_rp    = reads_pdl(cs_low);
    pdl_wait = cs_rp[1] && (cs_rp[0] ? c_next.ptr_pend : c_next.idx_pend);
    cs_hold  = oa_hold || pdl_wait;
    cs_moves = cs_keep && rd_free && !cs_hold && errhalt_now == 1'b0;
    // SH: OA-REG-HIGH as the clock began into the A source's address, and
    // into the M source's when it is M memory's (A15b.15).
    cs_sh_a  = cs_word[61] ? ({oa_high, 26'd0} & (48'o1777 << 32)) : 48'd0;
    cs_sh_m  = (cs_word[61] && !cs_low[31]) ? ({oa_high, 26'd0} & (48'o37 << 26)) : 48'd0;
    cs_ir    = cs_low | cs_sh_a | cs_sh_m;
    cs_pdl_addr = cs_ir[30] ? c_next.ptr : c_next.idx;
    // CS loads at the next address once its word has gone; not in the clock
    // a WRITE-I-MEM's refetch begins, the store being written a clock on.
    cs_load  = (!cs_keep || cs_moves) && !block_load && errhalt_now == 1'b0;
    store_re    = cs_load;
    store_raddr = npc_e;
    a_re        = cs_moves;
    a_raddr     = cs_ir[41:32];
    pdl_re      = cs_moves;
    pdl_raddr   = cs_pdl_addr;
  end

  assign unbuilt = ub_ex | ((rd_moves && plan.ub_macro) ? (UNBUILT_BITS'(1) << U_MACRO) : '0);

  // ================================================================= the edge

  // d2 and the PDL buffer's forward into the word in RD at this edge.
  logic [39:0] rd_a_n, rd_m_n, rd_pdl_n;
  logic        rd_pdl_fwd;
  always_comb begin
    rd_a_n     = (land_a_we && land_a_addr == rd_a_addr) ? land_data : rd_a;
    rd_m_n     = (land_m_we && land_m_addr == rd_m_addr && !rd_ir[31]) ? land_data : rd_m;
    rd_pdl_fwd = land_pdl_we && land_pdl_addr == rd_pdl_addr && (rd_seq - land_pdl_seq) >= 8'd2
              && (rd_seq - land_pdl_seq) < 8'd128;
    rd_pdl_n   = rd_pdl_fwd ? land_pdl_data : rd_pdl;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      // `Pipeline::boot`: the trap in CS at the PROM's first word, which the
      // first fetch reads again; RD's copies from the registers.
      cs_v <= 1'b1; cs_nop <= 1'b1; cs_pre_nop <= 1'b0; cs_trap <= 1'b1;
      cs_seq <= 8'd1; cs_pc <= RESET_PC;
      rd_v <= 1'b0; ex_v <= 1'b0; wb_v <= 1'b0;
      rd_nop <= 1'b0; rd_pre_nop <= 1'b0; ex_nop <= 1'b0; ex_pre_nop <= 1'b0;
      npc <= RESET_PC; npc_after_v <= 1'b0; npc_after <= 14'd0;
      nop_next <= 1'b0; pre_nop_next <= 1'b0;
      seq_ctr <= 8'd2;
      c <= '0;
      q <= 40'd0; vma <= 40'd0; md <= 40'd0; lc <= 34'd0; lc_needfetch <= 1'b0;
      pdl_ptr <= 14'd0; pdl_idx <= 14'd0; spcptr <= 5'd0; intctl <= 4'd0; dc <= 10'd0;
      overflow <= 1'b0; oa_low <= 26'd0; oa_high <= 22'd0;
      for (int k = 0; k < 8; k++) opc[k] <= 14'd0;
      npc_prev <= RESET_PC;
      next_instrd <= 1'b0;
      spc_w_v <= 1'b0; spc_w_ptr <= 5'd0; spc_w_word <= 19'd0;
      errhalt <= 2'd0;
      ex_clocks <= 5'd0;
      obs_commit <= 16'd0;
      obs_opnd <= 1'b0;
    end else if (errhalt != 2'd0) begin
      // Stopped: nothing moves.
      obs_commit <= 16'd0;
    end else if (errhalt_now) begin
      // OA-OUTSIDE-FIELDS (A15b.15): the machine halts before the word
      // commits, and nothing at this edge happens.
      errhalt    <= 2'd1;
      obs_commit <= 16'd0;
    end else begin
      // --- M memory, the micro stack and dispatch memory take their writes.
      if (land_m_we) mmem[land_m_addr] <= land_data;
      if (dmem_we) dmem[x_daddr] <= dmem_wdata;
      if (land_spc) spc[spc_w_ptr] <= spc_w_word;

      // --- The registers at EX's end.
      if (commit) begin
        q <= nq; vma <= nvma; md <= nmd; lc <= nlc; lc_needfetch <= nlc_nf;
        pdl_ptr <= nptr; pdl_idx <= nidx; intctl <= nintctl; dc <= ndc;
        overflow <= novf; oa_low <= noa_low; oa_high <= noa_high;
        spcptr <= sx.sp;
        spc_w_v <= nsw_v; spc_w_ptr <= nsw_ptr; spc_w_word <= nsw_word;
        npc_prev <= x_npc;
        next_instrd <= nid_new;
        if (!ex_nop) begin
          for (int k = 7; k > 0; k--) opc[k] <= opc[k-1];
          opc[0] <= ex_pc;
        end
        // PDL-FIELD-MISMATCH (A15b.2): the word commits, and the machine
        // stops after it.
        if (mismatch) errhalt <= 2'd2;
        obs_commit <= {1'b1, ex_nop, ex_nop ? 14'd0 : ex_pc};
        obs_opnd   <= !ex_nop && (ex_alu || ex_byte);
        obs_ea     <= ex_a_d1;
        obs_em     <= ex_mdata;
        obs_ob     <= x_ob;
      end else begin
        obs_commit <= 16'd0;
        obs_opnd   <= 1'b0;
      end

      // --- The copies.
      c <= c_next;

      // --- WB: the word EX committed, and its writes.
      wb_v <= commit;
      if (commit) begin
        wb_nop <= ex_nop; wb_seq <= ex_seq; wb_pc <= ex_pc;
        wb_m31 <= !ex_nop && writes_m31(ex_ir);
        wb_a_we <= nx_a_we; wb_a_addr <= nx_a_addr;
        wb_m_we <= nx_m_we; wb_m_addr <= nx_m_addr;
        wb_data <= x_ob;
        wb_pdl_we <= nx_pdl_we; wb_pdl_at_index <= nx_pdl_at_index;
        wb_pdl_addr <= nx_pdl_addr; wb_pdl_data <= x_ob;
        wb_imem_we <= wrote_imem;
        wb_imem_addr <= ex_isel[25:12];
        wb_imem_data <= iwr;
      end

      // --- EX: RD's word, or the word EX holds, d1 into it.
      if (rd_moves) begin
        ex_v <= 1'b1; ex_nop <= rd_n_nop; ex_pre_nop <= rd_n_pre;
        ex_seq <= rd_seq; ex_pc <= rd_pc; ex_word <= rd_word; ex_ir <= rd_ir;
        ex_a_addr <= rd_a_addr; ex_a <= rd_a_n;
        ex_m_addr <= rd_m_addr; ex_m <= rd_m_n;
        ex_pdl <= rd_pdl_n;
        ex_next2_v <= plan.next2_v; ex_next2 <= plan.next2;
        ex_resolved <= plan.resolved;
        ex_pred_taken_v <= plan.pred_taken_v; ex_pred_taken <= plan.pred_taken;
        ex_pred_pr_v <= plan.pred_pr_v; ex_pred_pr <= plan.pred_pr;
        ex_clocks <= 5'd0;
      end else if (commit || !ex_v) begin
        ex_v <= 1'b0;
        ex_clocks <= 5'd0;
      end else begin
        ex_a <= ex_a_d1;
        ex_m <= ex_m_d1;
        ex_clocks <= ex_clocks + 5'd1;
      end

      // --- RD: CS's word, read at this edge; or the word RD holds, d2 and
      // the PDL buffer's forward into it.
      if (cs_moves) begin
        rd_v <= 1'b1; rd_nop <= cs_n_nop; rd_pre_nop <= cs_n_pre;
        rd_seq <= cs_seq; rd_pc <= cs_pc; rd_word <= cs_word; rd_ir <= cs_ir;
        rd_a_addr <= cs_ir[41:32];
        // d3: the write landing at the edge of the read, which the RAM gives
        // as the old word.
        rd_a_fix_v <= land_a_we && land_a_addr == cs_ir[41:32];
        rd_a_fix   <= land_data;
        // M memory is read after this edge's write.
        rd_m_addr <= cs_ir[30:26];
        rd_m <= (land_m_we && land_m_addr == cs_ir[30:26]) ? land_data : mmem[cs_ir[30:26]];
        rd_pdl_addr <= cs_pdl_addr;
        // The PDL buffer: the old word, unless the write two or more words
        // before replaces it.
        rd_pdl_fix_v <= land_pdl_we && land_pdl_addr == cs_pdl_addr
                     && (cs_seq - land_pdl_seq) >= 8'd2 && (cs_seq - land_pdl_seq) < 8'd128;
        rd_pdl_fix   <= land_pdl_data;
      end else if (rd_moves || !rd_keep) begin
        rd_v <= 1'b0;
      end else begin
        rd_nop <= rd_n_nop; rd_pre_nop <= rd_n_pre;
        rd_a_fix_v <= 1'b1; rd_a_fix <= rd_a_n;
        rd_m <= rd_m_n;
        rd_pdl_fix_v <= rd_pdl_fix_v || rd_pdl_fwd; rd_pdl_fix <= rd_pdl_n;
      end

      // --- CS: the next word, at the address RD or the redirect chose.
      seq_ctr <= seq_e;
      npc <= npc_e; npc_after <= npc_after_e; npc_after_v <= npc_after_v_e;
      nop_next <= nop_next_e; pre_nop_next <= pre_nop_next_e;
      if (cs_load) begin
        cs_v <= 1'b1; cs_trap <= 1'b0;
        cs_nop <= nop_next_e; cs_pre_nop <= pre_nop_next_e && !nop_next_e;
        cs_seq <= seq_e; cs_pc <= npc_e;
        seq_ctr <= seq_e + 8'd1;
        npc <= npc_after_v_e ? npc_after_e : npc_e + 14'd1;
        npc_after_v <= 1'b0;
        nop_next <= 1'b0; pre_nop_next <= 1'b0;
      end else if (!cs_keep) begin
        cs_v <= 1'b0;
      end else begin
        cs_nop <= cs_n_nop; cs_pre_nop <= cs_n_pre;
      end
    end
  end

  // ========================================================= the observation

  always_comb begin
    obs_cs       = {cs_v, cs_v && cs_nop, cs_pc};
    obs_rd       = {rd_v, rd_v && rd_nop, rd_pc};
    obs_ex       = {ex_v, ex_v && ex_nop, ex_pc};
    obs_wb       = {wb_v, wb_v && wb_nop, wb_pc};
    obs_pdlptr   = pdl_ptr;
    obs_pdlidx   = pdl_idx;
    obs_spcptr   = spcptr;
    obs_q        = q;
    obs_vma      = vma;
    obs_md       = md;
    obs_lc       = {lc_needfetch, 6'd0, lc};
    obs_ic       = {2'd0, intctl, 26'd0};
    obs_oalow    = oa_low;
    obs_oahigh   = oa_high;
    obs_grant    = 2'd0;
    obs_gaddr    = 32'd0;
    obs_mdl      = 1'b0;
    obs_mdword   = 40'd0;
    obs_reg      = 1'b0;
    obs_raddr    = 32'd0;
    obs_queue    = 4'd0;
    obs_inflight = 5'd0;
    obs_halted   = 1'b0;
    obs_errhalt  = errhalt;
  end

`ifndef SYNTHESIS
  // A word that needs what is not built stops the simulation, named.
  always_ff @(posedge clk) begin
    if (!rst && errhalt == 2'd0 && unbuilt != '0) begin
      $display("quux15_core: not built: %b (bit 0 starts, LC's fetch and the map, 1 MACRO-DISPATCH, 2 time) at PC %o",
               unbuilt, ex_v ? ex_pc : rd_pc);
      $finish;
    end
  end
`endif

  // What nothing reads yet.
  logic unused;
  assign unused = ^{ex_pre_nop, x_mul, x_div, wb_seq, unbuilt, ex_word[63:62], ex_word[59],
                    ex_msrc[4], sx.pushed, ex_disp};

endmodule

`default_nettype wire
