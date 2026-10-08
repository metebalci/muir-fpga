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
//       buffer's forward; the next address of a jump RD resolves, and RD's
//       speculative copies of the PDL pointer and index.
//   EX  the word runs (`quux15_exec.sv`), d1 into its operands, its OA
//       selects applied and checked; the registers written at its end.
//   WB  A, M and the PDL buffer written.
//
// **muir's `muir::pipeline::Pipeline` IS THE REFERENCE, CLOCK FOR CLOCK**:
// what each stage holds after each edge, the commit, the registers EX
// writes, the operands and output of each ALU or BYTE word, and the OA
// registers, against `golden/src/quux15.rs`'s traces in
// `tb/quux15_core_tb.cpp`.  Each piece below names the function of muir's
// `src/pipeline/` it is (`stages.rs`, `exec.rs`, `control.rs`), and the
// order of a clock is `stages.rs`'s `clock_once`: WB, then EX, then the
// front end, then CS's reads, then the edge.
//
// **THE STRAIGHT LINE, AND NOT YET THE REST.**  This is the core as far as
// the straight line goes: ALU and BYTE words, the functional sources and
// destinations of the registers, the PDL buffer, MUL and DIV, the OA
// registers and selects with the hold and OA-OUTSIDE-FIELDS, an
// unconditional jump RD resolves, and a dispatch that falls through as
// predicted.  What is not built --- a transfer EX redirects, the micro
// stack, LC's step and fetch, memory starts, the map, D, the devices, the
// console's halt --- stops a simulation at the word that needs it, naming
// it (`unbuilt`), rather than running on wrong.

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
  logic        ex_next2_v, ex_resolved, ex_pred_pr_v;
  logic [13:0] ex_next2;
  logic [1:0]  ex_pred_pr;
  logic [4:0]  ex_clocks;

  logic        wb_v;
  logic        wb_a_we, wb_m_we, wb_pdl_we, wb_pdl_at_index;
  logic [9:0]  wb_a_addr;
  logic [4:0]  wb_m_addr;
  logic [39:0] wb_data;
  logic [13:0] wb_pdl_addr;
  logic [39:0] wb_pdl_data;
  logic [7:0]  wb_seq;
  logic        wb_nop;
  logic [13:0] wb_pc;

  // --- The front end: the next fetch's address, the one after it when RD
  // chose it before the word between was fetched, the next fetched word's
  // squashes, and the sequence counter.
  logic [13:0] npc, npc_after;
  logic        npc_after_v, nop_next, pre_nop_next;
  logic [7:0]  seq_ctr;

  // --- RD's speculative copies (`Copies`): the PDL pointer and index, and a
  // write of either from the ALU not yet committed, by its word's `seq`.
  logic [13:0] c_ptr, c_idx;
  logic        c_ptr_pend, c_idx_pend;
  logic [7:0]  c_ptr_seq, c_idx_seq;

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
  logic [1:0]  errhalt;
  logic        errhalt_now;

  // --- The memories.
  logic [39:0] mmem[32];
  logic [16:0] dmem[4096];
  initial begin
    for (int k = 0; k < 32; k++) mmem[k] = 40'd0;
    for (int k = 0; k < 4096; k++) dmem[k] = 17'd0;
  end

  // ================================================================= the store

  logic        store_re;
  logic [13:0] store_raddr;
  logic [63:0] store_q, cs_word;
  quux15_store #(.PROM_HEX(PROM_HEX)) store (
      .clk  (clk),
      .re   (store_re),
      .raddr(store_raddr),
      .rdata(store_q),
      .we   (1'b0),
      .waddr(14'd0),
      .wdata(64'd0)
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

  // The machine runs: no error halt now or before.
  logic running;
  assign running = errhalt == 2'd0 && !errhalt_now;

  // RD's operands: the RAM's word, or a forward that replaced it.
  logic [39:0] rd_a, rd_pdl;
  assign rd_a   = rd_a_fix_v ? rd_a_fix : a_q;
  assign rd_pdl = rd_pdl_fix_v ? rd_pdl_fix : pdl_q;

  // ============================================================ decoding help

  // Each of these reads the fields of a word it needs.
  /* verilator lint_off UNUSEDSIGNAL */
  // A functional destination's code, 34-37 as 30-33 and 24-27 as 20-23
  // (`dest_code`); `fd_v` when the word has one.
  function automatic logic [4:0] fd_code(input logic [47:0] ir);
    logic [4:0] c;
    c = ir[23:19];
    return c[4] ? (c & ~5'o4) : c;
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
  // A word that writes OA-REG-HIGH, destination 17.
  function automatic logic writes_oa_high(input logic [47:0] ir);
    return has_fd(ir) && fd_code(ir) == 5'o17;
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
  localparam int UNBUILT_BITS = 16;
  logic [UNBUILT_BITS-1:0] unbuilt;
  localparam int U_REDIRECT = 0;   // a transfer EX redirects (slice 2)
  localparam int U_SPC      = 1;   // the micro stack, POPJ, a call or a return (slice 2)
  localparam int U_COND     = 2;   // a conditional jump, a predicted transfer (slice 2)
  localparam int U_IMEM     = 3;   // WRITE-I-MEM (slice 2)
  localparam int U_PDLFIELD = 4;   // the PDL address field (slice 2)
  localparam int U_START    = 5;   // a memory start, MAP(MD), the map, map bits (slice 3)
  localparam int U_LCSTEP   = 6;   // LC's step and fetch, a dispatch with IR<24> (slice 4)
  localparam int U_MACRO    = 7;   // MACRO-DISPATCH's registers, destinations 5-7 (slice 4)
  localparam int U_TIME     = 8;   // the microsecond clock, source 15 (slice 5)
  localparam int U_SL_JUMP  = 9;   // a JUMP with SL, which EX transfers (slice 2)

  // ======================================================================= WB
  //
  // `wb_stage`: the word's A, M and PDL buffer writes land at its clock's
  // edge.  Nothing holds WB yet: with no starts, every word leaves after a
  // clock.

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
  // source's.
  logic [4:0]  ex_msrc;
  logic [39:0] ex_func, ex_mdata;
  logic        ex_pop_pdl;
  always_comb begin
    ex_msrc    = ex_isel[30:26];
    ex_pop_pdl = 1'b0;
    unique case (ex_msrc[3:0])
      4'o0:  ex_func = {30'd0, dc};
      4'o2:  ex_func = {26'd0, pdl_ptr};
      4'o3:  ex_func = {26'd0, pdl_idx};
      4'o4:  begin ex_func = ex_pdl; ex_pop_pdl = 1'b1; end
      4'o5:  ex_func = ex_pdl;
      4'o6:  ex_func = {26'd0, opc[7]};
      4'o7:  ex_func = q;
      4'o10: ex_func = vma;
      4'o12: ex_func = md;
      4'o13: ex_func = {lc_needfetch, 1'b0, intctl, intctl[3] ? lc : {lc[33:1], 1'b0}};
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

  // `execute`: what the word in EX does when it commits this clock.
  logic        commit, ex_alu, ex_byte, ex_jump, ex_disp;
  logic        inhibit, entry_ok;
  logic [13:0] x_npc, x_npc_seq;
  logic [16:0] entry;
  // The writes it leaves for WB.
  logic        nx_a_we, nx_m_we, nx_pdl_we, nx_pdl_at_index;
  logic [9:0]  nx_a_addr;
  logic [4:0]  nx_m_addr;
  logic [13:0] nx_pdl_addr;
  // The registers at its end.
  logic [39:0] nq, nvma, nmd;
  logic [33:0] nlc;
  logic        nlc_nf, novf;
  logic [13:0] nptr, nidx;
  logic [3:0]  nintctl;
  logic [9:0]  ndc;
  logic [25:0] noa_low;
  logic [21:0] noa_high;
  logic        dmem_we;
  logic [16:0] dmem_wdata;
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
    noa_low = oa_low; noa_high = oa_high;
    nx_a_we = 1'b0; nx_m_we = 1'b0; nx_pdl_we = 1'b0; nx_pdl_at_index = 1'b0;
    nx_a_addr = 10'd0; nx_m_addr = 5'd0; nx_pdl_addr = 14'd0;
    dmem_we = 1'b0; dmem_wdata = ex_a_d1[16:0];
    inhibit = 1'b0;
    entry = dmem[x_daddr];
    entry_ok = 1'b1;
    ub_ex = '0;
    // `micro`'s `npc`: the address after the next word's, one past the
    // address the microcycle before chose.
    x_npc_seq = npc_prev + 14'd1;
    x_npc     = x_npc_seq;
    if (commit && !ex_nop) begin
      if (ex_isel[42]) ub_ex[U_SPC] = 1'b1;
      if ((ex_alu || ex_byte) && ex_word[48]) ub_ex[U_PDLFIELD] = 1'b1;
      if (ex_isel[31] && (ex_msrc[3:0] == 4'o1 || ex_msrc[3:0] == 4'o14)) ub_ex[U_SPC] = 1'b1;
      if (ex_isel[31] && ex_msrc[3:0] == 4'o11) ub_ex[U_START] = 1'b1;
      if (ex_isel[31] && ex_msrc[3:0] == 4'o15) ub_ex[U_TIME] = 1'b1;
      if (ex_pop_pdl && ex_isel[31]) nptr = pdl_ptr - 14'd1;
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
            5'o15: ub_ex[U_SPC] = 1'b1;
            5'o16: noa_low = x_ob[25:0];
            5'o17: noa_high = x_ob[21:0];
            5'o20: nvma = x_ob;
            5'o21, 5'o22, 5'o23, 5'o31, 5'o32, 5'o33: ub_ex[U_START] = 1'b1;
            5'o30: nmd = x_ob;
            default: ;
          endcase
        end
      end else if (ex_jump) begin
        // `jump`: a condition true transfers, N inhibiting the slot.
        if (ex_isel[9] && ex_isel[8]) ub_ex[U_IMEM] = 1'b1;
        else if (x_jcond != ex_isel[6]) begin
          if (ex_isel[8] || ex_isel[9]) ub_ex[U_SPC] = 1'b1;
          inhibit = ex_isel[7];
          x_npc   = ex_isel[25:12];
        end
      end else begin
        // `dispatch`: a dispatch-memory write, or the entry's transfer; the
        // dispatch constant loaded by a dispatch that reads the memory.
        if (ex_isel[9:8] != 2'd0) ub_ex[U_START] = 1'b1;
        if (ex_isel[11:10] == 2'd2) begin
          dmem_we = 1'b1;
        end else begin
          ndc = ex_isel[41:32];
          if (ex_isel[24]) ub_ex[U_LCSTEP] = 1'b1;
          inhibit = entry[14];
          if (entry[15] && entry[16]) begin
            // Falls through.
          end else if (entry[15] || entry[16]) begin
            ub_ex[U_SPC] = 1'b1;
          end else begin
            x_npc = entry[13:0];
          end
          entry_ok = !ex_pred_pr_v || ex_pred_pr == {entry[15], entry[16]};
        end
      end
    end
  end

  // EX's check of RD's choices (`ex_stage`'s end): a choice that was wrong,
  // or a nopped slot that runs, would redirect the front end.
  logic kill_rd, ex_restore, slot_pre_nopped;
  logic [7:0] slot_seq;
  always_comb begin
    slot_seq        = ex_seq + 8'd1;
    kill_rd         = commit && !ex_nop && inhibit;
    ex_restore      = commit && !ex_nop && ex_resolved && inhibit;
    slot_pre_nopped = (rd_v && rd_seq == slot_seq && rd_pre_nop)
                   || (cs_v && cs_seq == slot_seq && cs_pre_nop)
                   || (pre_nop_next && !(rd_v && rd_seq == slot_seq) && !(cs_v && cs_seq == slot_seq));
  end

  logic redirect;
  always_comb begin
    redirect = 1'b0;
    if (commit && !ex_nop) begin
      if (ex_resolved && (x_npc != (ex_next2_v ? ex_next2 : x_npc_seq) || !entry_ok)) redirect = 1'b1;
      if (!redirect && !inhibit && slot_pre_nopped) redirect = 1'b1;
    end
  end

  // ================================================================ the front

  // EX's squash of the delay slot under N (`front_and_edge`, no redirect).
  logic rd_is_slot, cs_is_slot, rd_nop_e, rd_pre_nop_e, cs_nop_e, cs_pre_nop_e;
  logic nop_next_e, pre_nop_next_e;
  always_comb begin
    rd_is_slot     = rd_v && rd_seq == slot_seq;
    cs_is_slot     = cs_v && cs_seq == slot_seq;
    rd_nop_e       = rd_nop || (kill_rd && rd_is_slot);
    rd_pre_nop_e   = rd_pre_nop && !(kill_rd && rd_is_slot);
    cs_nop_e       = cs_nop || (kill_rd && cs_is_slot);
    cs_pre_nop_e   = cs_pre_nop && !(kill_rd && cs_is_slot);
    nop_next_e     = nop_next || (kill_rd && !rd_is_slot && !cs_is_slot);
    pre_nop_next_e = pre_nop_next && !(kill_rd && !rd_is_slot && !cs_is_slot);
  end

  // The copies: refreshed by the commit of the word that wrote them from the
  // ALU (`refresh_pending`), or restored from the registers (`restore_copies`).
  logic [13:0] cr_ptr, cr_idx;
  logic        cr_ptr_pend, cr_idx_pend;
  always_comb begin
    cr_ptr = c_ptr; cr_idx = c_idx; cr_ptr_pend = c_ptr_pend; cr_idx_pend = c_idx_pend;
    if (commit && c_ptr_pend && c_ptr_seq == ex_seq) begin
      cr_ptr_pend = 1'b0;
      cr_ptr      = nptr;
    end
    if (commit && c_idx_pend && c_idx_seq == ex_seq) begin
      cr_idx_pend = 1'b0;
      cr_idx      = nidx;
    end
    if (ex_restore) begin
      cr_ptr = nptr; cr_idx = nidx; cr_ptr_pend = 1'b0; cr_idx_pend = 1'b0;
    end
  end

  // RD's choices for its word (`plan_for`), made when it moves to EX.
  logic        ex_free, rd_moves, cs_follows;
  logic        p_next2_v, p_resolved, p_pred_v, p_kills;
  logic [13:0] p_next2;
  logic [1:0]  p_pred;
  logic [13:0] nc_ptr, nc_idx;
  logic        nc_ptr_pend, nc_idx_pend;
  logic [7:0]  nc_ptr_seq, nc_idx_seq;
  logic [UNBUILT_BITS-1:0] ub_rd;
  logic [4:0]  rd_src;
  logic [1:0]  rd_unc;
  always_comb begin
    ex_free    = !ex_v || commit;
    rd_moves   = rd_v && ex_free && errhalt_now == 1'b0;
    cs_follows = rd_v && cs_v && cs_seq == rd_seq + 8'd1;
    p_next2_v = 1'b0; p_next2 = 14'd0; p_resolved = 1'b0; p_pred_v = 1'b0; p_pred = 2'd0;
    p_kills = 1'b0;
    nc_ptr = cr_ptr; nc_idx = cr_idx; nc_ptr_pend = cr_ptr_pend; nc_idx_pend = cr_idx_pend;
    nc_ptr_seq = c_ptr_seq; nc_idx_seq = c_idx_seq;
    ub_rd = '0;
    rd_src = rd_ir[30:26];
    rd_unc = unconditional(rd_ir);
    if (rd_moves && !rd_nop_e && !rd_pre_nop_e) begin
      if (rd_ir[31] && rd_src[3:0] == 4'o14) ub_rd[U_SPC] = 1'b1;
      if (rd_ir[31] && rd_src[3:0] == 4'o4) nc_ptr = nc_ptr - 14'd1;
      if (has_fd(rd_ir)) begin
        unique case (fd_code(rd_ir))
          5'o11: nc_ptr = nc_ptr + 14'd1;
          5'o13: begin
            if (rd_word[48]) ub_rd[U_PDLFIELD] = 1'b1;
            nc_idx_pend = 1'b1;
            nc_idx_seq  = rd_seq;
          end
          5'o14: begin
            nc_ptr_pend = 1'b1;
            nc_ptr_seq  = rd_seq;
          end
          5'o15: ub_rd[U_SPC] = 1'b1;
          default: ;
        endcase
      end
      unique case (rd_ir[44:43])
        2'd1: begin
          if (rd_ir[9] && rd_ir[8]) ub_rd[U_IMEM] = 1'b1;
          else if (rd_word[60]) ub_rd[U_SL_JUMP] = 1'b1;
          else if (rd_ir[42]) ub_rd[U_SPC] = 1'b1;
          else if (!rd_unc[1]) ub_rd[U_COND] = 1'b1;
          else if (rd_unc[0]) begin
            if (rd_ir[8] || rd_ir[9]) ub_rd[U_SPC] = 1'b1;
            p_next2_v = 1'b1;
            p_next2   = rd_ir[25:12];
            p_kills   = rd_ir[7];
          end
        end
        2'd2: begin
          if (rd_ir[24]) ub_rd[U_LCSTEP] = 1'b1;
          if (rd_ir[11:10] == 2'd2) begin
            p_resolved = rd_ir[42];
            if (rd_ir[42]) ub_rd[U_SPC] = 1'b1;
          end else begin
            p_resolved = 1'b1;
            p_pred_v   = 1'b1;
            p_pred     = {!rd_word[62], !rd_word[63]};
            if (p_pred != 2'b11 || rd_ir[42]) ub_rd[U_COND] = 1'b1;
          end
        end
        default: if (rd_ir[42]) ub_rd[U_SPC] = 1'b1;
      endcase
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
    rd_free  = !rd_v || rd_moves;
    cs_low   = cs_word[47:0];
    oa_hold  = cs_word[61] && ((rd_v && !rd_nop_e && writes_oa_high(rd_ir))
                            || (ex_v && !ex_nop && writes_oa_high(ex_ir)));
    cs_rp    = reads_pdl(cs_low);
    pdl_wait = cs_rp[1] && (cs_rp[0] ? nc_ptr_pend : nc_idx_pend);
    cs_hold  = oa_hold || pdl_wait;
    cs_moves = cs_v && rd_free && !cs_hold && errhalt_now == 1'b0;
    // SH: OA-REG-HIGH as the clock began into the A source's address, and
    // into the M source's when it is M memory's (A15b.15).
    cs_sh_a  = cs_word[61] ? ({oa_high, 26'd0} & (48'o1777 << 32)) : 48'd0;
    cs_sh_m  = (cs_word[61] && !cs_low[31]) ? ({oa_high, 26'd0} & (48'o37 << 26)) : 48'd0;
    cs_ir    = cs_low | cs_sh_a | cs_sh_m;
    cs_pdl_addr = cs_ir[30] ? nc_ptr : nc_idx;
    // CS loads at the next address once its word has gone.
    cs_load  = (!cs_v || cs_moves) && errhalt_now == 1'b0;
  end

  // The next fetch's address once RD's choice is made (`make_plan`).
  logic [13:0] npc_e, npc_after_e;
  logic        npc_after_v_e, cs_pre_nop_p, pre_nop_next_p;
  always_comb begin
    npc_e = npc; npc_after_e = npc_after; npc_after_v_e = npc_after_v;
    cs_pre_nop_p = cs_pre_nop_e; pre_nop_next_p = pre_nop_next_e;
    if (rd_moves) begin
      if (p_next2_v) begin
        if (cs_follows) begin
          npc_e = p_next2;
          npc_after_v_e = 1'b0;
        end else begin
          npc_after_e = p_next2;
          npc_after_v_e = 1'b1;
        end
      end
      if (p_kills) begin
        if (cs_follows) cs_pre_nop_p = 1'b1;
        else pre_nop_next_p = 1'b1;
      end
    end
    store_re    = cs_load;
    store_raddr = npc_e;
    a_re        = cs_moves;
    a_raddr     = cs_ir[41:32];
    pdl_re      = cs_moves;
    pdl_raddr   = cs_pdl_addr;
  end

  assign unbuilt = ub_ex | ub_rd | (redirect ? (UNBUILT_BITS'(1) << U_REDIRECT) : '0);

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
      // first fetch reads again.
      cs_v <= 1'b1; cs_nop <= 1'b1; cs_pre_nop <= 1'b0; cs_trap <= 1'b1;
      cs_seq <= 8'd1; cs_pc <= RESET_PC;
      rd_v <= 1'b0; ex_v <= 1'b0; wb_v <= 1'b0;
      rd_nop <= 1'b0; rd_pre_nop <= 1'b0; ex_nop <= 1'b0; ex_pre_nop <= 1'b0;
      npc <= RESET_PC; npc_after_v <= 1'b0; npc_after <= 14'd0;
      nop_next <= 1'b0; pre_nop_next <= 1'b0;
      seq_ctr <= 8'd2;
      c_ptr <= 14'd0; c_idx <= 14'd0; c_ptr_pend <= 1'b0; c_idx_pend <= 1'b0;
      c_ptr_seq <= 8'd0; c_idx_seq <= 8'd0;
      q <= 40'd0; vma <= 40'd0; md <= 40'd0; lc <= 34'd0; lc_needfetch <= 1'b0;
      pdl_ptr <= 14'd0; pdl_idx <= 14'd0; spcptr <= 5'd0; intctl <= 4'd0; dc <= 10'd0;
      overflow <= 1'b0; oa_low <= 26'd0; oa_high <= 22'd0;
      for (int k = 0; k < 8; k++) opc[k] <= 14'd0;
      npc_prev <= RESET_PC;
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
      // --- The RAMs and M memory take WB's writes.
      if (land_m_we) mmem[land_m_addr] <= land_data;
      if (dmem_we) dmem[x_daddr] <= dmem_wdata;

      // --- The registers at EX's end.
      if (commit) begin
        q <= nq; vma <= nvma; md <= nmd; lc <= nlc; lc_needfetch <= nlc_nf;
        pdl_ptr <= nptr; pdl_idx <= nidx; intctl <= nintctl; dc <= ndc;
        overflow <= novf; oa_low <= noa_low; oa_high <= noa_high;
        npc_prev <= x_npc;
        if (!ex_nop) begin
          for (int k = 7; k > 0; k--) opc[k] <= opc[k-1];
          opc[0] <= ex_pc;
        end
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
      c_ptr <= nc_ptr; c_idx <= nc_idx; c_ptr_pend <= nc_ptr_pend; c_idx_pend <= nc_idx_pend;
      c_ptr_seq <= nc_ptr_seq; c_idx_seq <= nc_idx_seq;

      // --- WB: the word EX committed, and its writes.
      wb_v <= commit;
      if (commit) begin
        wb_nop <= ex_nop; wb_seq <= ex_seq; wb_pc <= ex_pc;
        wb_a_we <= nx_a_we; wb_a_addr <= nx_a_addr;
        wb_m_we <= nx_m_we; wb_m_addr <= nx_m_addr;
        wb_data <= x_ob;
        wb_pdl_we <= nx_pdl_we; wb_pdl_at_index <= nx_pdl_at_index;
        wb_pdl_addr <= nx_pdl_addr; wb_pdl_data <= x_ob;
      end

      // --- EX: RD's word, or the word EX holds, d1 into it.
      if (rd_moves) begin
        ex_v <= 1'b1; ex_nop <= rd_nop_e; ex_pre_nop <= rd_pre_nop_e;
        ex_seq <= rd_seq; ex_pc <= rd_pc; ex_word <= rd_word; ex_ir <= rd_ir;
        ex_a_addr <= rd_a_addr; ex_a <= rd_a_n;
        ex_m_addr <= rd_m_addr; ex_m <= rd_m_n;
        ex_pdl <= rd_pdl_n;
        ex_next2_v <= p_next2_v; ex_next2 <= p_next2;
        ex_resolved <= p_resolved; ex_pred_pr_v <= p_pred_v; ex_pred_pr <= p_pred;
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
        rd_v <= 1'b1; rd_nop <= cs_nop_e; rd_pre_nop <= cs_pre_nop_p;
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
      end else if (rd_moves) begin
        rd_v <= 1'b0;
      end else begin
        rd_nop <= rd_nop_e; rd_pre_nop <= rd_pre_nop_e;
        rd_a_fix_v <= 1'b1; rd_a_fix <= rd_a_n;
        rd_m <= rd_m_n;
        rd_pdl_fix_v <= rd_pdl_fix_v || rd_pdl_fwd; rd_pdl_fix <= rd_pdl_n;
      end

      // --- CS: the next word, at the address RD chose.
      if (cs_load) begin
        cs_v <= 1'b1; cs_trap <= 1'b0;
        cs_nop <= nop_next_e; cs_pre_nop <= pre_nop_next_p && !nop_next_e;
        cs_seq <= seq_ctr; cs_pc <= npc_e;
        seq_ctr <= seq_ctr + 8'd1;
        npc <= npc_after_v_e ? npc_after_e : npc_e + 14'd1;
        npc_after_v <= 1'b0;
        nop_next <= 1'b0; pre_nop_next <= 1'b0;
      end else begin
        cs_nop <= cs_nop_e; cs_pre_nop <= cs_pre_nop_p;
        npc <= npc_e; npc_after <= npc_after_e; npc_after_v <= npc_after_v_e;
        nop_next <= nop_next_e; pre_nop_next <= pre_nop_next_p;
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
      $display("quux15_core: not built: %b (bit 0 a redirect, 1 the micro stack, 2 a conditional or predicted transfer, 3 WRITE-I-MEM, 4 the PDL field, 5 starts and the map, 6 LC's step, 7 MACRO-DISPATCH, 8 time, 9 a JUMP with SL) at PC %o",
               unbuilt, ex_v ? ex_pc : rd_pc);
      $finish;
    end
  end
`endif

  // What nothing reads yet.
  logic unused;
  assign unused = ^{ex_pre_nop, x_mul, x_div, wb_seq, unbuilt, ex_word[63:62], ex_word[59:49],
                    ex_msrc[4], ex_disp, rd_src[4]};

endmodule

`default_nettype wire
