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
//   WB  A, M, the PDL buffer and the control store written; the word's
//       memory starts, one a clock, translated (`quux15_mmu.sv`: the TLB, a
//       walk on a miss, the fault, the write-back) and granted to the port
//       (`quux15_port.sv`: the cache, the posted writes, main memory on an
//       AXI master) or to the register page.
//
// **muir's `muir::pipeline::Pipeline` IS THE REFERENCE, CLOCK FOR CLOCK**:
// what each stage holds after each edge, the commit, the registers EX
// writes, the operands and output of each ALU or BYTE word, and the OA
// registers, against `golden/src/quux15.rs`'s traces in
// `tb/quux15_core_tb.cpp`.  Each piece below names the function of muir's
// `src/pipeline/` it is (`stages.rs`, `exec.rs`, `control.rs`), and the
// order of a clock is `stages.rs`'s `clock_once`: WB, then EX, then the
// front end (the redirect and its squash and restore, or RD's choices),
// then CS's reads, then the edge.  That order is what each clock computes,
// not the logic's depth: RD's choices are made from the copies as the clock
// began, beside the choices after a redirect and a squashed slot's, and EX's
// outcome selects among them last (`plan_r`, `plan_x`, `plan_k`).
//
// **THE MEMORY SIDE'S ORDER IN A CLOCK IS muir'S**: the port's tick (writes
// answered land, the queue's head accepted, a fill issued or landed) and a
// read's word landing in MD; WB's start; EX's register write, its holds (MD
// while a read is on its way, but for the word right after the read's
// start; a start behind a start; the map store's write; port B's lookup and
// walk; the late squash) and its microcycle, whose starts, map store and
// a write's word WB and the port take.  A write carries MD as its start's
// microcycle leaves it (A15b.3; right after a read start, the read's
// word); a device register's write still waits for the word after its start
// to leave EX.
//
// **THE CONSOLE** (A15b.13; muir's `pipeline/control.rs`) writes and reads
// the diagnostic registers (`spy_*`): RUN cleared drains the machine to a
// single-edge machine's state between two microcycles (CS and RD squashed
// and fetched again, EX and WB done, the port empty), and the readout
// (`ro_*`) gives what muir's checkpoint of it carries after the machine;
// STEP runs one word through the four stages, IDEBUG the debug IR's word in
// its place; the mode register's `-RESET` and `-BOOT`, taken halted; a HALT
// word under ERROR-STOP-ENABLE drains; OA-OUTSIDE-FIELDS freezes the machine
// mid-clock, the word in EX, which the spy reads.
//
// **WHAT IS NOT BUILT** --- MACRO-DISPATCH and D, the keyboard and the
// mouse, the network, block-disk's transfers (no pack is fitted, as in every
// trace here), the PDL buffer redirect inside the buffer --- stops a
// simulation at the word that needs it, naming it (`unbuilt`), rather than
// running on wrong.

`default_nettype none

module quux15_core #(
    // The PROM image, a 64-bit word a line (`quux15_store.sv`).
    parameter string PROM_HEX = "",
    // MACHINE-ID, functional source 16: `0x5155`, revision 15, processor 4.
    parameter logic [31:0] MACHINE_ID = {16'h5155, 12'd15, 4'd4},
    // Main memory's words: QUUX's 32 boards, 2M words.
    parameter int unsigned MAIN_WORDS = 32'h0020_0000,
    // The cache's words (`quux15_port.sv`): 4,096 sets of two 8-word lines.
    parameter int unsigned CACHE_WORDS = 65536,
    // The frame buffer's words, the device window's slice 0: the video
    // controller at 1280 by 1024, a bit a pixel.
    parameter int unsigned FB_WORDS = 40960,
    // One AXI ID for every write, as the board needs (A15b.5), its writes
    // answered in order; clear, an ID a slot of the port's in-flight list.
    parameter bit ONE_WRITE_ID = 1'b1,
    // The bubbles a wrong prediction costs (A15b.14): 1, EX's decision
    // driving the next fetch's address in its own clock; or 2, the fallback,
    // the target fetched a clock later (muir's `Pipeline::bubbles`).
    parameter int unsigned BUBBLES = 1
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
    output var logic [1:0]  obs_errhalt,

    // Main memory, an AXI4 master of 64 bits (`quux15_axi_master.sv`).
    output var logic [3:0]  m_awid,
    output var logic [31:0] m_awaddr,
    output var logic [7:0]  m_awlen,
    output var logic [2:0]  m_awsize,
    output var logic [1:0]  m_awburst,
    output var logic        m_awvalid,
    input  var logic        m_awready,
    output var logic [63:0] m_wdata,
    output var logic [7:0]  m_wstrb,
    output var logic        m_wlast,
    output var logic        m_wvalid,
    input  var logic        m_wready,
    input  var logic [3:0]  m_bid,
    input  var logic [1:0]  m_bresp,
    input  var logic        m_bvalid,
    output var logic        m_bready,
    output var logic [31:0] m_araddr,
    output var logic [7:0]  m_arlen,
    output var logic [2:0]  m_arsize,
    output var logic [1:0]  m_arburst,
    output var logic        m_arvalid,
    input  var logic        m_arready,
    input  var logic [63:0] m_rdata,
    input  var logic [1:0]  m_rresp,
    input  var logic        m_rlast,
    input  var logic        m_rvalid,
    output var logic        m_rready,
    // The clock's period in units of 0.5 ns (word 25, the machine's time),
    // and the real-time clock's seconds at power-on: the board's.
    input  var logic [6:0]  period,
    input  var logic [31:0] rtc_start,
    // The file device's host (contract Q9; `quux15_devices.sv`): the
    // doorbell and the producer; a command completed, its words written into
    // main memory by the host, and the handles then open.
    output var logic        fd_doorbell,
    output var logic [15:0] fd_prod,
    output var logic        fd_enabled,
    input  var logic        fd_done,
    input  var logic [7:0]  fd_handles,
    // The master's declared constants inside r and w (A15b.5), which
    // the testbench's responder subtracts from the port's clocks.
    output var logic        axi_one_write_id,
    output var logic [3:0]  axi_read_clocks,
    output var logic [3:0]  axi_write_clocks,

    // The console's diagnostic bus (`muir::spy`; A15b.13): a register
    // written at this clock's edge, `EADR<3:0>` and the word; a register
    // read, its word as the clock ends; and the readout of the halted
    // pipeline's state between two microcycles, a field a selector, what
    // a checkpoint of revision 15 carries after the machine.
    input  var logic        spy_we,
    input  var logic [3:0]  spy_eadr,
    input  var logic [15:0] spy_wdata,
    input  var logic [3:0]  spy_raddr,
    output var logic [15:0] spy_rdata,
    input  var logic [4:0]  ro_sel,
    output var logic [63:0] ro_word
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
  logic        cs_v_q, cs_nop_q, cs_pre_nop_q, cs_trap_q;
  logic [7:0]  cs_seq_q;
  logic [13:0] cs_pc_q;

  logic        rd_v_q, rd_nop, rd_pre_nop, rd_trap;
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
  // WB's first clock, when its word's writes land; and the word's starts
  // still to be granted, in order (`Back::starts`): read or write, LC's
  // fetch, the virtual address.  A write's word is MD as it stands at the
  // grant, which is MD as its start's microcycle left it (A15b.3): nothing
  // moves MD in between (below, `md_at_commit`).
  logic        wb_fresh;
  logic [1:0]  st_v, st_write, st_fetch;
  logic [31:0] st_va [2];
  logic        ex_map_held, ex_late_held, ex_b_walked, ex_int_rd;

  // --- The front end: the next fetch's address, the one after it when RD
  // or a redirect chose it before the word between was fetched, the next
  // fetched word's squashes, and the sequence counter.
  logic [13:0] npc_q, npc_after_q;
  logic        npc_after_v_q, nop_next_q, pre_nop_next_q;
  logic [7:0]  seq_ctr_q;

  // --- The console (`Pipeline::console_edge`; A15b.13).  The clock control
  // register (RUN, STEP, NOP, IDEBUG, LDSTAT), the mode register (QUUX's
  // without its speed bits; `<2>` ERROR-STOP-ENABLE, register-page word 102
  // too), the OPC control register and the debug IR, which the spy writes;
  // RUN and STEP as the master clock registers them (`srun`, `sstep`,
  // `ssdone`); halted, drained; draining; one word's step under way; a HALT
  // word under ERROR-STOP-ENABLE committed, whose drain begins next clock.
  logic        cc_run, cc_step, cc_nop11, cc_idebug, cc_ldstat;
  logic [5:0]  mode;
  logic [2:0]  opc_ctl;
  logic [63:0] debug_ir;
  logic        srun, sstep, ssdone, halted, draining, stepping, halt_req;
  // The HALT bit of the last microcycle (`x.halted`), the last committed
  // microcycle's sequence, and the microcycles committed (`committed`).
  logic        x_halted;
  logic [7:0]  last_seq;
  logic [63:0] committed;
  // CS's word is the debug IR's, loaded with IDEBUG up.
  logic        cs_dbg_q;
  logic [63:0] cs_dbg_word;

  // `-RESET` and `-BOOT` from the mode register's `<6>` and `<7>`, at the
  // edge the spy's write lands at (`console_edge`): the console's registers
  // cleared, RUN kept by the reset and set by the boot.
  logic reset_go, boot_go, reset_q, boot_q;
  always_comb begin
    boot_go  = spy_we && spy_eadr[2:0] == 3'd5 && spy_wdata[7];
    reset_go = (spy_we && spy_eadr[2:0] == 3'd5 && spy_wdata[6]) || boot_go;
  end
  // The clock the reset and the boot are for.
  always_ff @(posedge clk) begin
    reset_q <= !rst && reset_go;
    boot_q  <= !rst && boot_go;
  end

  // **THE CONSOLE'S CLOCK** (`console_edge`), from the registers as the
  // clock begins: RUN cleared while running, or a HALT word's drain, begins
  // the halt; RUN resumes a halted machine but under ERROR-STOP-ENABLE after
  // a HALT word; STEP raised runs one word.
  logic        drain_start, resume_go, step_go, halted_now, draining_now, fetch_ok;
  always_comb begin
    drain_start  = !halted && !draining && ((srun && !cc_run) || halt_req);
    resume_go    = cc_run && halted && !(mode[2] && x_halted);
    step_go      = cc_step && !sstep && halted && !resume_go;
    halted_now   = halted && !resume_go && !step_go;
    draining_now = draining || drain_start;
    // `fetching`: the step's word, or the machine running.
    fetch_ok     = !draining_now && !stepping && (step_go || (cc_run && !halted_now));
  end

  // **THE HALT'S SQUASH** (`begin_drain`), as the clock begins: CS and RD
  // emptied, their words fetched again in order, the first at the next
  // fetch's address and the second, or the trap again, or the address the
  // next fetch would have taken, after it.
  logic        rd_v, cs_v, npc_after_v, nop_next, pre_nop_next;
  logic        cs_nop, cs_pre_nop, cs_trap, cs_dbg;
  logic [13:0] npc, npc_after, cs_pc;
  logic [7:0]  seq_ctr, cs_seq;
  always_comb begin
    rd_v = rd_v_q && !drain_start;
    cs_v = cs_v_q && !drain_start;
    cs_nop = cs_nop_q; cs_pre_nop = cs_pre_nop_q; cs_trap = cs_trap_q; cs_dbg = cs_dbg_q;
    cs_pc = cs_pc_q; cs_seq = cs_seq_q;
    npc = npc_q; npc_after = npc_after_q; npc_after_v = npc_after_v_q;
    nop_next = nop_next_q; pre_nop_next = pre_nop_next_q; seq_ctr = seq_ctr_q;
    // Stopped at an error, nothing moves: the store reads the word in EX
    // for the spy's IR.
    if (errhalt != 2'd0) npc = ex_pc;
    // **THE CONSOLE'S BOOT** (`console_edge`'s `reset_pipeline` and `trap`),
    // as the clock after its write begins, the machine halted and so
    // empty: the trap in CS at the PROM's first word, the next fetch there.
    if (boot_q) begin
      cs_v = 1'b1; cs_nop = 1'b1; cs_pre_nop = 1'b0; cs_trap = 1'b1; cs_dbg = 1'b0;
      cs_pc = RESET_PC; cs_seq = seq_ctr_q;
      npc = RESET_PC; npc_after_v = 1'b0; nop_next = 1'b0; pre_nop_next = 1'b0;
      seq_ctr = seq_ctr_q + 8'd1;
    end
    if (drain_start) begin
      if (rd_v_q || cs_v_q) begin
        npc          = rd_v_q ? rd_pc : cs_pc;
        nop_next     = rd_v_q ? rd_nop : cs_nop;
        pre_nop_next = rd_v_q ? (rd_pre_nop && !rd_nop) : (cs_pre_nop && !cs_nop);
        npc_after_v  = 1'b1;
        npc_after    = (rd_v_q && cs_v_q) ? cs_pc : (rd_v_q ? rd_trap : cs_trap) ? npc : npc_q;
      end
      seq_ctr = ex_v ? ex_seq + 8'd1 : wb_v ? wb_seq + 8'd1 : seq_ctr_q + 8'd1;
    end
  end

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

  // --- The memory side's state (`stages.rs`'s `Back`, `exec.rs`'s `Exec`).
  // VMAOK, the last translation's entry and whether it was a write's.
  logic        vmaok, wrcyc;
  logic [29:0] lvmo;
  // The last start's acknowledgment: clocks still to wait.
  logic [1:0]  ack_left;
  // A read's word on its way to MD from a register or nothing there (clocks
  // to its landing, the word); a read in the port (`md_fill` or a hit).
  logic        pend_v, pend_dev;
  logic [1:0]  pend_left;
  logic [39:0] pend_word;
  logic        rd_port;
  // A read start's sequence and MD as it stood at the grant, which the word
  // right after it reads (`md_old`).
  logic        old_v;
  logic [7:0]  old_seq;
  logic [39:0] old_md;
  // A device register's write, taken the clock after its grant and no
  // sooner than the clock after the word right after its start has left EX
  // (`rgw_rel`, muir's `released`; A15b.3).
  logic        rgw_v, rgw_rel;
  logic [28:0] rgw_bus;
  logic [39:0] rgw_word;
  // A map store's write, landing at the head of the next microcycle
  // (`map_write_d`).
  logic        mwd_v;
  logic [39:0] mwd_vma, mwd_md;
  // Register-page words: 101's bus errors (`<0>` nothing there), 102's
  // error stop, 225's posted writes answered with an error.
  logic        bus_nxm, errstop;
  assign errstop = mode[2];
  logic [31:0] posted_errors;
  // CMD_PROD's write, taken from the register write and held until every
  // write before it is answered (`Back::cmd_prod`; A15b.5).
  logic        cprod_v, rw_take, take_cmd_prod;
  logic [31:0] cprod_word;
  // The PDL buffer redirect's copies of A 430 and 431 (A14.7).
  logic [31:0] pdl_base;
  logic [13:0] pdl_head;

  // --- The memories: M and the micro stack in flip-flops, dispatch memory
  // read in EX.  Each comes up as muir's machine has it; a testbench may
  // load them as a bitstream would (`public_flat_rw`).  **DISPATCH MEMORY
  // IN TWO HALVES**, its even entries and its odd: both read at the address's
  // `<11:1>`, and `<0>`, which a map-bit dispatch takes from port B's
  // lookup, picks between their words last.
  logic [39:0] mmem[32] /* verilator public_flat_rw */;
  logic [16:0] dmem_even[2048] /* verilator public_flat_rw */;
  logic [16:0] dmem_odd[2048] /* verilator public_flat_rw */;
  logic [18:0] spc[32];
  initial begin
    for (int k = 0; k < 32; k++) mmem[k] = 40'd0;
    for (int k = 0; k < 2048; k++) begin
      dmem_even[k] = 17'd0;
      dmem_odd[k]  = 17'd0;
    end
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
      .we   (wb_v && wb_fresh && wb_imem_we && running),
      .waddr(wb_imem_addr),
      .wdata(wb_imem_data)
  );
  // The boot's trap is a word of zeros, read from nowhere.
  assign cs_word = cs_trap ? 64'd0 : cs_dbg ? cs_dbg_word : store_q;

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
  // **THE PDL BUFFER'S NEWEST WRITE IS HELD**, in `pdlh_*`, and the RAM
  // takes it when a newer one lands: a read at the edge a write lands at
  // reads the word before it, as muir's reads before the edge's landing do,
  // whatever the RAM would make of a read and a write of one address at one
  // edge; a later read takes the held word (`rd_pdl_fix`).  With two bubbles
  // the word after a writer is read at the edge its writer lands at.  **A
  // HALT HOLDS IT OVER** (`pdl_pending`) when the last microcycle made it:
  // the next word's read takes the word before it, and it lands after
  // (`pdl_pend`), as a single-edge machine's buffer does.
  logic        pdlh_v, pdl_pend;
  logic [13:0] pdlh_addr;
  logic [39:0] pdlh_data;
  logic [7:0]  pdlh_seq;
  quux15_ram #(.WIDTH(40), .DEPTH(16384)) pdl (
      .clk  (clk),
      .re   (pdl_re),
      .raddr(pdl_raddr),
      .rdata(pdl_q),
      .we   (pdlh_v && land_pdl_we),
      .waddr(pdlh_addr),
      .wdata(pdlh_data)
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
  localparam int U_DEVICE = 0;  // the keyboard's, the mouse's or the network's words, the PDL buffer
                                // redirect inside the buffer, a dispatch-memory write on map bits
  localparam int U_MACRO = 1;   // MACRO-DISPATCH: destinations 5-7, the PDL field on M-AP or A-LOCALP (slice 4)
  localparam int U_DEV   = 2;   // a device's word the devices do not answer (a guard)

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
  // `wb_stage`: the word's A, M and PDL buffer writes land at the edge of its
  // first clock in WB, and WRITE-I-MEM's control store word; then its starts,
  // one a clock, each in turn (`start_at_wb`): the translation, a walk on a
  // miss, the fault, the write-back, and the port's grant.  The word leaves
  // once every start is done.

  always_comb begin
    land_a_we     = wb_v && wb_fresh && wb_a_we;
    land_a_addr   = wb_a_addr;
    land_m_we     = wb_v && wb_fresh && wb_m_we;
    land_m_addr   = wb_m_addr;
    land_data     = wb_data;
    land_pdl_we   = wb_v && wb_fresh && wb_pdl_we;
    // A write by the index takes the index as it stands at WB: the word's own
    // write counts, the next word's, at this clock's end, does not.
    land_pdl_addr = wb_pdl_at_index ? pdl_idx : wb_pdl_addr;
    land_pdl_data = wb_pdl_data;
    land_pdl_seq  = wb_seq;
  end

  // --- The port (`quux15_port.sv`) and the memory management
  // --- (`quux15_mmu.sv`).
  logic        p_busy, p_req, p_land, p_land_next, w_ok, w_req, post_req, post_ok;
  logic        t_start, t_ready, port_idle, port_idle_n, port_empty;
  logic [28:0] p_bus, w_bus, post_bus, t_addr;
  logic [39:0] p_word, p_word_next, post_word, t_word;
  logic [4:0]  errors_now, inflight_n;
  logic [3:0]  queue_n;
  quux15_port #(.SETS(CACHE_WORDS / 16), .ONE_WRITE_ID(ONE_WRITE_ID)) port (
      .clk(clk), .rst(rst),
      .p_busy(p_busy), .p_req(p_req), .p_bus(p_bus), .p_land(p_land), .p_word(p_word),
      .p_land_next(p_land_next), .p_word_next(p_word_next),
      .w_ok(w_ok), .w_req(w_req), .w_bus(w_bus), .w_word(md),
      .post_req(post_req), .post_bus(post_bus), .post_word(post_word), .post_ok(post_ok),
      .t_start(t_start), .t_addr(t_addr), .t_ready(t_ready), .t_word(t_word),
      .errors_now(errors_now), .queue_n(queue_n), .inflight_n(inflight_n), .idle(port_idle), .idle_n(port_idle_n),
      .empty(port_empty), .sweep_go(fd_done),
      .one_write_id(axi_one_write_id),
      .read_fabric_clocks(axi_read_clocks), .write_fabric_clocks(axi_write_clocks),
      .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
      .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata),
      .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
      .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
      .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
      .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp),
      .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready));

  logic [31:0] a_next_va, b_next_va, a_va, b_va, k_va;
  logic        a_req, a_hold, k_req, k_write, k_hold, k_busy, b_req, b_hold, b_walk_done, op_v, rw_v, sweeping;
  logic [29:0] a_entry, b_entry, k_entry;
  logic [39:0] k_md, op_vma, op_md;
  logic [7:0]  rw_k;
  logic [31:0] rw_data, refused;
  logic [17:0] directory;
  logic        ephemeral;
  logic [63:0] pointer_types;
  quux15_mmu #(.MAIN_WORDS(MAIN_WORDS)) mmu (
      .clk(clk), .rst(rst), .con_reset(reset_q),
      .a_next_va(a_next_va), .b_next_va(b_next_va),
      .a_req(a_req), .a_va(a_va), .a_hold(a_hold), .a_entry(a_entry),
      .k_req(k_req), .k_va(k_va), .k_entry(k_entry), .k_write(k_write), .k_md(k_md),
      .k_hold(k_hold), .k_busy(k_busy), .post_req(post_req), .post_bus(post_bus), .post_word(post_word),
      .post_ok(post_ok),
      .b_req(b_req), .b_va(b_va), .b_walked(ex_b_walked), .b_hold(b_hold), .b_walk_done(b_walk_done),
      .b_entry(b_entry),
      .op_v(op_v), .op_vma(op_vma), .op_md(op_md),
      .t_start(t_start), .t_addr(t_addr), .t_ready(t_ready), .t_word(t_word),
      .rw_v(rw_v), .rw_k(rw_k), .rw_data(rw_data),
      .directory(directory), .ephemeral(ephemeral), .pointer_types(pointer_types),
      .refused(refused), .sweeping(sweeping));

  // --- MD as this clock has it: a read's word landing now (`port_events`),
  // --- and whether a read is still on its way.
  logic        land_now, rif_now;
  logic [39:0] land_word, md_now;
  always_comb begin
    land_now  = (pend_v && pend_left == 2'd0) || p_land;
    land_word = p_land ? p_word : pend_word;
    md_now    = land_now ? land_word : md;
    rif_now   = (pend_v && pend_left != 2'd0) || (rd_port && !p_land);
  end

  // --- The register page's word `k`, read: the feature words (G2 §6.4),
  // --- the bus errors and error stop, the memory system's words (A14.9),
  // --- word 225 (A15b.1).  `ok` clear for a word not built here.
  localparam logic [31:0] FEATURES [0:15] = '{
      32'h515500f4, 32'h0, 32'h1000, 32'h4000, 32'h4000, 32'h400, 32'h1000, 32'h3,
      32'h1, 32'h5000400, 32'h10028, 32'he0000000, 32'h1, 32'h3, 32'h3, 32'h400};
  logic [31:0] posted_now;
  // The words `quux15_devices.sv` answers, a clock after the grant.
  function automatic logic dev_word(input logic [7:0] k);
    return k == 8'o100 || k == 8'o103 || k == 8'o104 || (k >= 8'o110 && k <= 8'o115)
        || (k >= 8'o200 && k <= 8'o203) || k == 8'o210 || (k >= 8'o160 && k <= 8'o171);
  endfunction
  // The words of the devices not built: the keyboard and the mouse, the
  // network.
  function automatic logic unbuilt_word(input logic [7:0] k);
    return (k >= 8'o120 && k <= 8'o123) || (k >= 8'o140 && k <= 8'o147)
        ;
  endfunction
  function automatic logic [32:0] register_read(input logic [7:0] k, input logic [31:0] posted);
    if (k < 8'o20) return {1'b1, FEATURES[k[3:0]]};
    if (dev_word(k) || unbuilt_word(k)) return {1'b0, 32'd0};
    unique case (k)
      8'o25:  return {1'b1, 25'd0, period};
      8'o101: return {1'b1, 31'd0, bus_nxm};
      8'o102: return {1'b1, 31'd0, errstop};
      8'o220: return {1'b1, 14'd0, directory};
      8'o221: return {1'b1, 31'd0, ephemeral};
      8'o222: return {1'b1, pointer_types[31:0]};
      8'o223: return {1'b1, pointer_types[63:32]};
      8'o224: return {1'b1, refused};
      8'o225: return {1'b1, posted};
      // Every other word is reserved, or a constant 0 on this board: the
      // board name (words 20-24) where the board's top gives none.
      default: return {1'b1, 32'd0};
    endcase
  endfunction
  function automatic logic register_writable(input logic [7:0] k);
    return !unbuilt_word(k);
  endfunction

  // --- The register page's devices and the machine's time
  // --- (`quux15_devices.sv`).
  logic [31:0] dev_rd_word, microseconds;
  logic        dev_rd_built, dev_wr_built, int_now;
  quux15_devices #(.MAIN_WORDS(MAIN_WORDS)) devices (
      .clk(clk), .rst(rst), .timers_rst(reset_q), .period(period), .rtc_start(rtc_start),
      .prod_v(cprod_v && port_empty && errhalt == 2'd0), .prod_data(cprod_word),
      .fd_doorbell(fd_doorbell), .fd_prod(fd_prod), .fd_enabled(fd_enabled),
      .fd_done(fd_done), .fd_handles(fd_handles),
      .rd_v(at_grant && s_device && !st_write[0] && dev_word(s_bus[7:0])), .rd_k(s_bus[7:0]),
      .rd_word(dev_rd_word), .rd_built(dev_rd_built),
      .wr_v(rw_take && errhalt == 2'd0 && dev_word(rgw_bus[7:0]) && !take_cmd_prod), .wr_k(rgw_bus[7:0]), .wr_data(rgw_word[31:0]), .wr_built(dev_wr_built),
      .microseconds(microseconds), .int_now(int_now));

  // --- The start at WB's head (`start_at_wb`).
  localparam logic [28:0] REGISTER_PAGE_BUS = 29'h1fff_ff00;
  logic        s_v, s_pre_hold, s_translated, k_idle, fault_now, vmaok_n, s_faulted;
  logic        s_redirect, s_inside, s_device, s_memory, s_window, s_nothing, s_reg_hold;
  logic        at_grant, s_done, wb_leaves, wb_read_grant, wb_ack_grant;
  logic [29:0] s_entry;
  logic [28:0] s_bus;
  logic [32:0] s_regword;
  logic [13:0] s_redirect_n;
  logic [31:0] s_off;
  always_comb begin
    posted_now  = posted_errors + {27'd0, errors_now};
    s_v         = wb_v && st_v[0];
    s_pre_hold  = sweeping || ack_left != 2'd0 || rif_now;
    a_va        = st_va[0];
    a_req       = s_v && !s_pre_hold;
  end
  always_comb begin
    s_translated = a_req && !a_hold;
    k_idle      = !k_busy;
    // The redirect (`redirect_14`): a paged start whose entry has status 5
    // and an access code that faults it proceeds as if the code were 11,
    // inside the PDL buffer or through memory.
    s_entry     = a_entry;
    s_redirect  = 1'b0;
    s_inside    = 1'b0;
    s_redirect_n = pdl_ptr - pdl_head + 14'd1;
    s_off       = a_va - pdl_base;
    if (a_va[31:29] != 3'b111 && a_entry[26:24] == 3'd5
        && !(a_entry[27] && (!st_write[0] || a_entry[26]))) begin
      s_redirect = 1'b1;
      s_entry    = a_entry | 30'(3 << 26);
      s_inside   = s_off <= {18'd0, s_redirect_n};
    end
    fault_now   = s_translated && k_idle;
    vmaok_n     = s_entry[27] && (!st_write[0] || s_entry[26]);
    s_faulted   = fault_now && !vmaok_n;
    // The bus address (`tlb::bus_address`) and who answers it
    // (`busint::decode_quux_14`).
    if (a_va[31:29] == 3'b111 && !a_va[28]) s_bus = {1'b1, a_va[27:0]};
    else s_bus = {1'b0, s_entry[17:0], a_va[9:0]};
    s_device    = s_bus[28:8] == REGISTER_PAGE_BUS[28:8];
    // The frame buffer's window is memory as main memory is, through the
    // cache and the port (`busint::decode_quux_14`).
    s_window    = s_bus[28] && !s_device && s_bus[27:0] < 28'(FB_WORDS);
    s_memory    = (!s_bus[28] && s_bus < 29'(MAIN_WORDS)) || s_window;
    s_nothing   = !s_device && !s_window && !s_memory;
    s_regword   = register_read(s_bus[7:0], posted_now);
    // A register access waits while a register's write before it is still to
    // be taken.
    s_reg_hold  = rgw_v && s_device;
    k_req       = s_translated && !s_faulted && !(fault_now && s_inside) && !s_reg_hold;
    k_va        = a_va;
    k_entry     = s_entry;
    k_write     = st_write[0];
    k_md        = md_now;
    w_bus       = s_bus;
    p_bus       = s_bus;
  end
  always_comb begin
    at_grant    = k_req && !k_hold;
    w_req       = at_grant && st_write[0] && s_memory;
    p_req       = at_grant && !st_write[0] && s_memory && !p_busy;
    s_done      = s_faulted || (at_grant && !(w_req && !w_ok) && !(at_grant && !st_write[0] && s_memory && p_busy));
    wb_leaves   = !wb_v || !st_v[0] || (s_done && !st_v[1]);
    wb_read_grant = at_grant && !st_write[0] && (p_req || s_device || s_nothing);
    // The grants that set `ack_at` beyond this clock: all but a memory read.
    wb_ack_grant  = s_done && at_grant && !(s_memory && !st_write[0]);
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

  // **EX's holds** (`ex_stage`), in muir's order, once WB leaves: a word
  // that uses MD while a read is on its way, but the word right after the
  // read's start, which reads MD as the start found it; a start while the
  // last start is unacknowledged or a read is on its way; a start in the
  // microcycle a map store's write lands in, a clock; port B's lookup of the
  // MD the word reads, while the sweep runs or a walk reads; MUL's and DIV's
  // clocks, DIV 18 and MUL 5 (A15b.3; `muldiv::DIV_CLOCKS_15`, `MUL_CLOCKS_15`);
  // the late squash, a check of conditions 4-6 in the clock a start before it
  // faulted at WB, a clock.
  logic ex_rd_mul, ex_rd_div, ex_try, ex_go, ex_succ, ex_succ_old, ex_rif, ex_ack, ex_uses_md, ex_will_start;
  logic md_wait, start_wait, map_hold, ex_portb, ex_reach_b, ex_b_hold, ex_reach_mul, ex_mul_hold;
  logic ex_reads_vmaok, ex_late, old_v_eff;
  logic [7:0]  old_seq_eff;
  logic [39:0] old_md_eff, md_read;
  logic [4:0] ex_needs;
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_pointer(input logic [39:0] w);
    return pointer_types[w[37:32]];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    ex_go       = ex_v && wb_leaves;
    // MD as the start at WB this clock left it (`md_old`).
    old_v_eff   = wb_read_grant || old_v;
    old_seq_eff = wb_read_grant ? wb_seq : old_seq;
    old_md_eff  = wb_read_grant ? md_now : old_md;
    ex_succ     = old_v_eff && old_seq_eff + 8'd1 == ex_seq;
    // The MD it reads: a read WB grants in this clock leaves MD as it is now,
    // and its start's second, LC's fetch, MD as the first read left it
    // (`old_md` takes the read's word when it lands, below), so the
    // registers alone say which.
    ex_succ_old = old_v && old_seq + 8'd1 == ex_seq;
    ex_rif      = rif_now || wb_read_grant;
    ex_ack      = ack_left != 2'd0 || wb_ack_grant;
    ex_uses_md  = (ex_ir[31] && (ex_ir[29:26] == 4'o11 || ex_ir[29:26] == 4'o12))
               || (ex_ir[44:43] == 2'd2 && ex_ir[9:8] != 2'd0 && ex_ir[11:10] != 2'd2)
               || (has_fd(ex_ir) && fd_code(ex_ir)[4:2] == 3'b110);
    ex_will_start = (!ex_nop && has_fd(ex_ir) && (fd_code(ex_ir) == 5'o21 || fd_code(ex_ir) == 5'o22
                                                  || fd_code(ex_ir) == 5'o31 || fd_code(ex_ir) == 5'o32))
                 || (next_instrd && lc_needfetch)
                 || (!ex_nop && ex_ir[44:43] == 2'd2 && ex_ir[24] && ex_ir[11:10] != 2'd2 && lc_needfetch);
    md_wait     = !ex_nop && ex_uses_md && ex_rif && !ex_succ;
    start_wait  = ex_will_start && (ex_ack || ex_rif);
    map_hold    = ex_will_start && mwd_v && !ex_map_held;
    md_read     = ex_succ_old ? old_md : md_now;
    ex_portb    = !ex_nop && ((ex_ir[31] && ex_ir[29:26] == 4'o11)
                              || (ex_ir[44:43] == 2'd2 && ex_ir[9:8] != 2'd0 && ex_ir[11:10] != 2'd2
                                  && is_pointer(md_now)));
    ex_reach_b  = ex_go && !md_wait && !start_wait && !map_hold;
    b_req       = ex_reach_b && ex_portb && !sweeping;
    // Port B looks up MD as it stands: the word right after a start, the
    // one word that would read MD as the start found it, never reads the
    // map (A15b.2's rule).
    b_va        = md_now[31:0];
  end
  always_comb begin
    ex_b_hold   = ex_portb && (sweeping || b_hold);
    ex_reach_mul = ex_reach_b && !ex_b_hold;
    ex_rd_mul   = !ex_nop && ex_ir[44:43] == 2'd0 && ex_ir[8] && ex_ir[4:3] == 2'd2;
    ex_rd_div   = !ex_nop && ex_ir[44:43] == 2'd0 && ex_ir[8] && ex_ir[4:3] == 2'd3;
    ex_needs    = ex_rd_div ? 5'd18 : ex_rd_mul ? 5'd5 : 5'd1;
    ex_mul_hold = ex_reach_mul && (ex_clocks + 5'd1 < ex_needs);
    // Conditions 4-6 (`condition_reads_vmaok`): `IR<2:0>` 4 to 6, whatever
    // `IR<4:3>` (14-16, 24-26, 34-36 too).
    ex_reads_vmaok = ex_ir[44:43] == 2'd1 && ex_ir[5] && ex_ir[2:0] >= 3'd4 && ex_ir[2:0] <= 3'd6;
    ex_late     = ex_reach_mul && !ex_mul_hold && !ex_nop && fault_now && ex_reads_vmaok
               && !ex_late_held && !vmaok_n;
    ex_try      = ex_reach_mul && !ex_mul_hold && !ex_late;
  end

  // The M operand (`read_functional`): M memory's word, or a functional
  // source's.  The micro stack's word is the stack's before this
  // microcycle's landing of the last one's push.
  logic [4:0]  ex_msrc;
  logic [39:0] ex_func, ex_mdata, md_in;
  logic        ex_pop_pdl, pfr, pfw;
  logic [1:0]  map_bits;
  always_comb begin
    ex_msrc    = ex_isel[30:26];
    ex_pop_pdl = 1'b0;
    // MD as the word reads it: as the start before found it, for the word
    // right after a read start.
    md_in      = md_read;
    // The last translation as WB left it this clock: MAP(MD)'s `<31:30>`.
    // MAP(MD)'s two fault bits from the last start's translation: no word
    // that reads the map runs while WB translates the start before it
    // (A15b.2's rule).
    pfr        = lvmo[27];
    pfw        = !(!lvmo[26] && wrcyc);
    // A map-bit dispatch's bits: the entry's `<23:22>` on a pointer, both
    // set on another word.
    map_bits   = is_pointer(md_now) ? b_entry[23:22] : 2'b11;
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
      4'o11: ex_func = {8'd0, !pfw, !pfr, b_entry};
      4'o12: ex_func = md_in;
      4'o13: ex_func = {lc_needfetch, 1'b0, intctl, intctl[3] ? lc : {lc[33:1], 1'b0}};
      4'o14: ex_func = {11'd0, spcptr, 5'd0, spc[spcptr]};
      4'o15: ex_func = {8'd0, microseconds};
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
      // The late squash's prediction: a start translated at WB in this
      // clock did not fault; the check holds a clock when it did.
      // A start WB reaches in a clock EX commits in is translated there.
      .vmaok         ((a_req && !k_busy) ? 1'b1 : vmaok),
      .map_bits      (map_bits),
      // The interrupt as this clock's register write leaves it, under
      // INTERRUPT-CONTROL <27>, the enable.
      .int_pending   (intctl[1] && int_now),
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
      .load  (ex_reach_mul && ex_rd_div && ex_clocks == 5'd0 && errhalt == 2'd0),
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
  // `pop_spc`: the word in `popped`.  **A POP READS THE STACK WHERE THE
  // MICROCYCLE BEGAN**, at the pointer as EX took it (`top0`, `p0`): after
  // the microcycle's own push the word below it, after the source's pop the
  // word that pop left, and a plain pop the top.  Only WRITE-I-MEM's
  // return under POPJ pops past it (`top1`), and its plain pop takes the
  // word it pushed.  So the stack is read at addresses from registers, and
  // the microcycle's decisions choose among the words read.
  function automatic spcx_t pop_spc(input spcx_t s, input logic [18:0] top0, input logic [18:0] top1,
                                    input logic [4:0] p0);
    spcx_t r;
    r = s;
    if (r.spc_pushed) begin
      r.spc_popped = 1'b1;
      r.popped = top0;
    end else if (r.spc_popped) begin
      r.popped = (r.sp == p0 - 5'd1) ? top0 : top1;
    end else begin
      r.popped = (r.sw_v && r.sw_ptr == r.sp) ? r.sw_word : top0;
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
  // The microcycle's starts, in order (`Exec::starts`), its map store's
  // write (`map_write`), the word a write started before takes, and MD as
  // the microcycle leaves it after a read that landed while the word right
  // after its start waited.
  typedef struct packed {
    logic        v;
    logic        write;
    logic        fetch;
    logic [31:0] va;
  } start_t;
  start_t      xs0, xs1;
  logic        x_mw_v, halt_rel;
  logic [39:0] x_mw_vma, x_mw_md, md_final;
  function automatic logic [69:0] add_start(input start_t a, input start_t b, input logic w,
                                             input logic f, input logic [31:0] va);
    start_t s0, s1;
    s0 = a;
    s1 = b;
    if (!s0.v) s0 = '{v: 1'b1, write: w, fetch: f, va: va};
    else s1 = '{v: 1'b1, write: w, fetch: f, va: va};
    return {s0, s1};
  endfunction
  // The stack's words a pop of this microcycle reads (`pop_spc`).
  logic [18:0] spc_top0, spc_top1;
  always_comb begin
    spc_top0 = spc_landed(spcptr);
    spc_top1 = spc_landed(spcptr + 5'd1);
  end

  always_comb begin
    errhalt_now = ex_try && !ex_nop && ex_outside;
    commit      = ex_try && !errhalt_now;
    ex_alu      = ex_isel[44:43] == 2'd0;
    ex_jump     = ex_isel[44:43] == 2'd1;
    ex_disp     = ex_isel[44:43] == 2'd2;
    ex_byte     = ex_isel[44:43] == 2'd3;
    nq = q; nvma = vma; nmd = md_in; nlc = lc; nlc_nf = lc_needfetch; novf = overflow;
    xs0 = '0; xs1 = '0;
    x_mw_v = 1'b0; x_mw_vma = vma; x_mw_md = md_in;
    // A map store's write of the microcycle before lands at this one's head
    // (`write_map_14`).
    op_v = commit && mwd_v;
    op_vma = mwd_vma;
    op_md = mwd_md;
    nptr = pdl_ptr; nidx = pdl_idx; nintctl = intctl; ndc = dc;
    noa_low = oa_low; noa_high = oa_high; nni = 1'b0; nid_new = next_instrd;
    nx_a_we = 1'b0; nx_m_we = 1'b0; nx_pdl_we = 1'b0; nx_pdl_at_index = 1'b0;
    nx_a_addr = 10'd0; nx_m_addr = 5'd0; nx_pdl_addr = 14'd0;
    dmem_we = 1'b0; dmem_wdata = ex_a_d1[16:0];
    inhibit = 1'b0; x_taken = 1'b0; wrote_imem = 1'b0; entry_pr = 2'd0;
    entry = x_daddr[0] ? dmem_odd[x_daddr[11:1]] : dmem_even[x_daddr[11:1]];
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
              5'o21, 5'o22: begin
                nvma = x_ob;
                {xs0, xs1} = add_start(xs0, xs1, fd_code(ex_isel) == 5'o22, 1'b0, x_ob[31:0]);
              end
              5'o23: begin
                nvma = x_ob;
                x_mw_v = 1'b1; x_mw_vma = x_ob; x_mw_md = md_in;
              end
              5'o30: nmd = x_ob;
              5'o31, 5'o32: begin
                nmd = x_ob;
                {xs0, xs1} = add_start(xs0, xs1, fd_code(ex_isel) == 5'o32, 1'b0, vma[31:0]);
              end
              5'o33: begin
                nmd = x_ob;
                x_mw_v = 1'b1; x_mw_vma = vma; x_mw_md = x_ob;
              end
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
              sx = pop_spc(sx, spc_top0, spc_top1, spcptr);
            end
          end else begin
            x_taken = x_jcond != ex_isel[6];
            if (ex_isel[8] && x_taken)
              sx = push_spc(sx, {5'd0, ex_isel[7] ? x_npc - 14'd1 : x_npc});
            if (x_taken) begin
              x_npc = ex_isel[25:12];
              if (ex_isel[9]) begin
                sx = pop_spc(sx, spc_top0, spc_top1, spcptr);
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
          if (ex_isel[9:8] != 2'd0 && ex_isel[11:10] == 2'd2) ub_ex[U_DEVICE] = 1'b1;
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
              if (stepped[35]) begin
                // LC's fetch (`step_lc`): VMA the word it steps past.
                nvma = {8'd0, nlc[33:2]};
                {xs0, xs1} = add_start(xs0, xs1, 1'b0, 1'b1, nlc[33:2]);
              end
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
                sx = pop_spc(sx, spc_top0, spc_top1, spcptr);
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
          sx = pop_spc(sx, spc_top0, spc_top1, spcptr);
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
        if (stepped[35]) begin
          nvma = {8'd0, nlc[33:2]};
          {xs0, xs1} = add_start(xs0, xs1, 1'b0, 1'b1, nlc[33:2]);
        end
        nlc = stepped[33:0];
        nlc_nf = stepped[34];
      end
      nid_new = nni;
    end
  end

  // ================================================= the memory side's next state
  //
  // What WB's start, EX's register write (`register_write_now`, at EX's
  // start) and EX's microcycle leave, in muir's order within the clock.
  logic        wb_nxm;
  logic        n_pend_v, n_rd_port, n_old_v, n_rgw_v, n_rgw_rel;
  logic        n_mwd_v, n_bus_nxm, n_pend_dev;
  logic [1:0]  n_pend_left, n_ack_left;
  logic [39:0] n_pend_word, n_old_md, n_rgw_word, n_md, n_mwd_vma, n_mwd_md;
  logic [7:0]  n_old_seq;
  logic [28:0] n_rgw_bus;
  logic [31:0] n_posted;
  logic        ub_register;
  always_comb begin
    wb_nxm = at_grant && s_nothing;
    // --- The register's write taken now (`register_write_now`); CMD_PROD's
    // --- held for the port.
    rw_take  = rgw_v && rgw_rel;
    take_cmd_prod = rw_take && rgw_bus[7:0] == 8'o164;
    rw_v     = rw_take && rgw_bus[7:0] >= 8'o220 && rgw_bus[7:0] <= 8'o224;
    rw_k     = rgw_bus[7:0];
    rw_data  = rgw_word[31:0];
    ub_register = rw_take && !register_writable(rgw_bus[7:0]);
    n_posted  = posted_now;
    n_bus_nxm = bus_nxm || wb_nxm;
    if (rw_take) begin
      unique case (rgw_bus[7:0])
        8'o225: n_posted = '0;
        8'o101: n_bus_nxm = 1'b0;
        default: ;
      endcase
    end
    // --- A register's or nothing's word on its way to MD.
    n_pend_v = pend_v && pend_left != 2'd0;
    n_pend_left = pend_left - 2'd1;
    n_pend_word = pend_word;
    n_pend_dev = 1'b0;
    if (at_grant && !st_write[0] && s_device) begin
      n_pend_v = 1'b1; n_pend_left = 2'd1; n_pend_word = {8'd0, s_regword[31:0]};
      // A device's word: read a clock on, at that clock's instant.
      n_pend_dev = dev_word(s_bus[7:0]);
    end
    if (pend_v && pend_left != 2'd0 && pend_dev) n_pend_word = {8'd0, dev_rd_word};
    if (at_grant && !st_write[0] && s_nothing) begin
      n_pend_v = 1'b1; n_pend_left = 2'd0; n_pend_word = '0;
    end
    n_rd_port = (rd_port && !p_land) || p_req;
    // --- MD as a read start found it, until a later word commits.
    n_old_v = old_v_eff; n_old_seq = old_seq_eff; n_old_md = old_md_eff;
    // A read that lands while its word waits in WB for its second start,
    // LC's fetch: the fetch's grant takes MD as the read left it.
    if (land_now && old_v && wb_v && old_seq == wb_seq && !wb_read_grant) n_old_md = land_word;
    if (commit && old_v_eff && ex_seq != old_seq_eff && (ex_seq - old_seq_eff) < 8'd128) n_old_v = 1'b0;
    // --- The acknowledgment: a write's and a register's two clocks after
    // --- the grant, nothing's one.
    n_ack_left = (ack_left != 2'd0) ? ack_left - 2'd1 : 2'd0;
    if (at_grant && s_done && (s_device || (s_memory && st_write[0]))) n_ack_left = 2'd1;
    if (at_grant && s_nothing) n_ack_left = 2'd0;
    // --- The register's write: taken, made, released.  A word that leaves
    // --- EX after the start's releases it (`end_of_microcycle`), at the
    // --- grant's clock or later, and so does a halt or a step whose last
    // --- word has left EX with RD and CS empty, nothing left to see the
    // --- interrupt before the write (`clock_once`'s end).  No word after
    // --- the start leaves EX before the grant, WB holding EX until its
    // --- starts are granted, so muir's release at the grant (`released`)
    // --- is this clock's.
    halt_rel = (draining_now || stepping) && !rd_v && !cs_v && !ex_v;
    n_rgw_v = rgw_v && !rw_take; n_rgw_bus = rgw_bus; n_rgw_word = rgw_word;
    n_rgw_rel = rgw_rel || commit || halt_rel;
    if (at_grant && s_device && st_write[0]) begin
      n_rgw_v = 1'b1; n_rgw_bus = s_bus; n_rgw_word = md;
      n_rgw_rel = commit || halt_rel;
    end
    // --- MD: the word EX leaves, or the read's word that landed.  The word
    // --- right after a read start that committed after the read landed
    // --- leaves the read's word, whatever it wrote.
    md_final = (ex_succ && !ex_rif) ? md_now : nmd;
    n_md     = commit ? md_final : md_now;
    // --- The map store's write, for the next microcycle's head.
    n_mwd_v = mwd_v && !commit; n_mwd_vma = mwd_vma; n_mwd_md = mwd_md;
    if (commit) begin
      n_mwd_v = x_mw_v; n_mwd_vma = x_mw_vma; n_mwd_md = x_mw_md;
    end
  end

  // The lookups' addresses for the next clock: the start WB will translate,
  // and the MD EX's word will read.
  logic        n_land;
  logic [39:0] n_md_now;
  always_comb begin
    if (wb_v && !wb_leaves) a_next_va = s_done ? st_va[1] : st_va[0];
    else a_next_va = xs0.va;
    n_land   = p_land_next || (n_pend_v && n_pend_left == 2'd0);
    n_md_now = p_land_next ? p_word_next : (n_pend_v && n_pend_left == 2'd0) ? n_pend_word : n_md;
    b_next_va = n_md_now[31:0];
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
        // The word after the write in execution order, fetched again after
        // the write: the next in sequence, or the target of the transfer whose
        // slot it fills, the address the write pushes under N.
        redirect    = 1'b1;
        refetch     = 1'b1;
        redirect_to = x_npc - 14'd1;
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
    // The stack's top as EX leaves it: the pointer moves a word at most, so
    // the three words around it as EX took it are read, and EX's pointer
    // picks one.
    arch_top_new = (nsw_v && nsw_ptr == sx.sp) ? nsw_word
                 : (sx.sp == spcptr) ? spc_after_ex(spcptr, land_spc)
                 : (sx.sp == spcptr + 5'd1) ? spc_after_ex(spcptr + 5'd1, land_spc)
                 : spc_after_ex(spcptr - 5'd1, land_spc);
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
  logic        refetch_slot, slot_here, rd_moves, cs_follows, block_load;
  logic [13:0] refetch_pc, npc_e, npc_after_e;
  logic        npc_after_v_e, nop_next_e, pre_nop_next_e;
  logic [7:0]  seq_e;
  copies_t     c_app, c_next;
  /* verilator lint_off UNUSEDSIGNAL */
  copies_t     c_cs;           // its PDL pointer and index alone
  /* verilator lint_on UNUSEDSIGNAL */
  plan_t       plan, plan_r, plan_x, plan_k;
  logic        hold_r, hold_x, rd_killed, rd_moves_n, rd_moves_x;
  logic [13:0] follower_r, follower_x;

  // **RD's CHOICES, EX's OUTCOME SELECTING AT THE END** (`plan_for`): the
  // plan from the copies as the clock began, which is the one RD makes
  // unless EX squashes or redirects (muir's `rd_plan`, before WB and EX);
  // and the plan of a delay slot EX squashes under N, a nopped word's, LC's
  // own step alone.  **AFTER A REDIRECT THE DELAY SLOT WAITS IN RD A
  // CLOCK** and plans from the restored copies in the next, so that no plan
  // follows EX's outcome in the clock EX decides it; the bubble comes ahead
  // of the slot, and none is added.  With two bubbles the target comes a
  // clock later anyway, and the slot plans at the redirect from the copies
  // EX restores (`plan_x`), which feeds only registers, CS being empty.
  // Each plan is complete on its own, so that EX's decision chooses among
  // them and does not run through them.
  always_comb begin
    follower_r = (cs_v && cs_seq == rd_seq + 8'd1) ? cs_pc : npc;
    plan_r = rd_plan(c, follower_r, 1'b0, rd_nop, rd_pre_nop, nsw_v, nsw_ptr, nsw_word, land_spc);
    hold_r = plan_r.returns && guard_holds(1'b0, nid_new);
  end

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
    rd_killed = 1'b0;
    c_app = c_ref;
    if (redirect) begin
      // Every word after the delay slot leaves nothing; the delay slot stays,
      // nopped under N, wherever it is; nopped by RD's prediction and running
      // after all, it is fetched again.
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
        // Two bubbles: the slot RD nopped on the prediction is fetched again
        // a clock later, as the target would be.
        if (BUBBLES == 2) block_load = 1'b1;
      end else if (slot_here) begin
        npc_e = redirect_to;
        npc_after_v_e = 1'b0;
        // Two bubbles: the target a clock later.  With the delay slot not
        // fetched yet there is nothing to delay, the slot being the next
        // word in sequence.
        if (BUBBLES == 2) block_load = 1'b1;
      end else begin
        // The delay slot not fetched yet: it comes first.
        npc_e = ex_pc + 14'd1;
        npc_after_e = redirect_to;
        npc_after_v_e = 1'b1;
        nop_next_e = kill_rd;
      end
      c_app = c_res;
      // Sequence numbers follow the order words run in.
      if (cs_keep) seq_e = cs_seq + 8'd1;
      else if (rd_keep) seq_e = rd_seq + 8'd1;
      else seq_e = ex_seq + ((refetch_slot || !slot_here) ? 8'd0 : 8'd1) + 8'd1;
    end else begin
      if (ex_restore) c_app = c_res;
      if (kill_rd) begin
        if (rd_v && rd_seq == slot_seq) begin
          rd_n_nop = 1'b1;
          rd_n_pre = 1'b0;
          rd_killed = 1'b1;
        end else if (cs_v && cs_seq == slot_seq) begin
          cs_n_nop = 1'b1;
          cs_n_pre = 1'b0;
        end else begin
          nop_next_e = 1'b1;
          pre_nop_next_e = 1'b0;
        end
      end
    end
    // After a redirect: the plan from the copies EX restores, the address of
    // the word after RD's as the redirect leaves it.
    follower_x = (cs_keep && cs_seq == rd_seq + 8'd1) ? cs_pc : npc_e;
    plan_x = rd_plan(c_res, follower_x, 1'b1, rd_n_nop, rd_n_pre, nsw_v, nsw_ptr, nsw_word, land_spc);
    hold_x = plan_x.returns && guard_holds(1'b1, nid_new);
    // A squashed delay slot: a nopped word's plan, LC's own step alone.
    plan_k = '0;
    plan_k.e.dest = D_NONE;
    plan_k.e.lcstep_own = c_app.next_instr;
    plan = (BUBBLES == 2 && redirect) ? plan_x : rd_killed ? plan_k : plan_r;
    // RD moves on its own plan, or a squashed slot's, which never holds.
    // After a redirect RD holds the delay slot, which waits, or nothing;
    // with two bubbles the slot moves on the redirect's plan.
    rd_moves_n = rd_keep && ex_free && !(hold_r && !rd_killed) && errhalt_now == 1'b0;
    rd_moves_x = BUBBLES == 2 && rd_keep && ex_free && !hold_x && errhalt_now == 1'b0;
    rd_moves = redirect ? rd_moves_x : rd_moves_n;
    // CS follows RD only without a redirect, which keeps no word behind the
    // delay slot: the plan after a redirect reaches NPC's registers alone.
    cs_follows = !redirect && rd_keep && cs_keep && cs_seq == rd_seq + 8'd1;
    c_next = rd_moves ? apply_effects(plan.e, c_app) : c_app;
    if (rd_moves) begin
      // `make_plan`.
      if (plan.next2_v && !cs_follows) begin
        npc_after_e = plan.next2;
        npc_after_v_e = 1'b1;
      end
      if (plan.kills && !cs_follows) pre_nop_next_e = 1'b1;
    end
    // The word after RD's, when CS holds it, from RD's own plan alone.
    if (cs_follows && rd_moves_n && !rd_killed) begin
      if (plan_r.next2_v) begin
        npc_e = plan_r.next2;
        npc_after_v_e = 1'b0;
      end
      if (plan_r.kills) cs_n_pre = 1'b1;
    end
    // The copies CS reads the PDL buffer through: after a redirect CS holds
    // at most the delay slot, behind an empty RD, so they are EX's.
    c_cs = redirect ? c_res
         : (rd_moves_n && !rd_killed) ? apply_effects(plan_r.e, c_app)
         : (rd_moves_n && c_app.next_instr) ? lc_step(c_app) : c_app;
  end

  // CS (`cs_hold`, `cs_reads`): the OA-REG-HIGH hold while its writer is in RD
  // or EX, and the PDL buffer's address waiting for a pointer or an index
  // written from the ALU.
  logic        rd_free, cs_hold, oa_hold, pdl_wait, cs_moves, cs_load, cs_load_raw;
  logic [47:0] cs_low, cs_ir, cs_sh_a, cs_sh_m;
  logic [1:0]  cs_rp;
  logic [13:0] cs_pdl_addr;
  always_comb begin
    // After a redirect CS keeps only the delay slot, behind an empty RD.
    rd_free  = !rd_keep || redirect || rd_moves_n;
    cs_low   = cs_word[47:0];
    oa_hold  = cs_word[61] && ((rd_keep && !rd_n_nop && writes_oa_high(rd_ir))
                            || (ex_v && !ex_nop && writes_oa_high(ex_ir)));
    cs_rp    = reads_pdl(cs_low);
    pdl_wait = cs_rp[1] && (cs_rp[0] ? c_cs.ptr_pend : c_cs.idx_pend);
    cs_hold  = oa_hold || pdl_wait;
    cs_moves = cs_keep && rd_free && !cs_hold && errhalt_now == 1'b0;
    // SH: OA-REG-HIGH as the clock began into the A source's address, and
    // into the M source's when it is M memory's (A15b.15).
    cs_sh_a  = cs_word[61] ? ({oa_high, 26'd0} & (48'o1777 << 32)) : 48'd0;
    cs_sh_m  = (cs_word[61] && !cs_low[31]) ? ({oa_high, 26'd0} & (48'o37 << 26)) : 48'd0;
    cs_ir    = cs_low | cs_sh_a | cs_sh_m;
    cs_pdl_addr = cs_ir[30] ? c_cs.ptr : c_cs.idx;
    // CS loads at the next address once its word has gone; not in the clock
    // a WRITE-I-MEM's refetch begins, the store being written a clock on.
    // The console's `fetching` gates CS's load, not the store's read, which
    // with CS empty, halted or draining, reads at NPC for the spy's IR.
    cs_load_raw = (!cs_keep || cs_moves) && !block_load && errhalt_now == 1'b0;
    cs_load  = cs_load_raw && fetch_ok;
    // A and the PDL buffer read every clock: RD takes their words in the
    // clock its word arrives and keeps them after, so a read that no word
    // takes changes nothing.
    a_re        = 1'b1;
    a_raddr     = cs_ir[41:32];
    pdl_re      = 1'b1;
  end

  // **THE STORE'S READ WITHOUT EX's REDIRECT**, for two bubbles: the next
  // address and CS's load as they are in a clock EX redirects nothing,
  // from the plan RD makes from its copies and EX's squash of the delay
  // slot under N.  In a clock EX redirects, CS takes nothing that clock
  // but the delay slot not fetched yet, the next word in sequence, which
  // `npc` already holds; or it keeps the delay slot held, which reads
  // nothing either way.  So the redirect reaches NPC's registers and CS's,
  // and not the store (checked below).
  logic        rd_killed_nr, rd_moves_nr, cs_moves_nr, cs_load_nr, cs_load_nr_raw, oa_hold_nr, pdl_wait_nr;
  logic [13:0] npc_nr;
  copies_t     c_app_nr;
  /* verilator lint_off UNUSEDSIGNAL */
  copies_t     c_cs_nr;           // its PDL pointer and index alone
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    rd_killed_nr = kill_rd && rd_v && rd_seq == slot_seq;
    rd_moves_nr  = rd_v && ex_free && !(hold_r && !rd_killed_nr) && errhalt_now == 1'b0;
    npc_nr = npc;
    if (rd_v && cs_v && cs_seq == rd_seq + 8'd1 && rd_moves_nr && !rd_killed_nr && plan_r.next2_v)
      npc_nr = plan_r.next2;
    c_app_nr = ex_restore ? c_res : c_ref;
    c_cs_nr  = (rd_moves_nr && !rd_killed_nr) ? apply_effects(plan_r.e, c_app_nr)
             : (rd_moves_nr && c_app_nr.next_instr) ? lc_step(c_app_nr) : c_app_nr;
    oa_hold_nr  = cs_word[61] && ((rd_v && !(rd_nop || rd_killed_nr) && writes_oa_high(rd_ir))
                               || (ex_v && !ex_nop && writes_oa_high(ex_ir)));
    pdl_wait_nr = cs_rp[1] && (cs_rp[0] ? c_cs_nr.ptr_pend : c_cs_nr.idx_pend);
    cs_moves_nr = cs_v && (!rd_v || rd_moves_nr) && !oa_hold_nr && !pdl_wait_nr && errhalt_now == 1'b0;
    cs_load_nr_raw = (!cs_v || cs_moves_nr) && errhalt_now == 1'b0;
    cs_load_nr  = cs_load_nr_raw && fetch_ok;
  end
  // The store's read, and the PDL buffer's address: with two bubbles as
  // though EX redirects nothing.
  // Halted, the store reads the next word to run for the spy's IR; stopped
  // at an error, the word in EX (the next fetch's address is EX's then).
  assign store_re    = ((BUBBLES == 2) ? cs_load_nr_raw : cs_load_raw) || errhalt != 2'd0;
  assign store_raddr = (BUBBLES == 2) ? npc_nr : npc_e;
  assign pdl_raddr   = (BUBBLES == 2) ? (cs_ir[30] ? c_cs_nr.ptr : c_cs_nr.idx) : cs_pdl_addr;

`ifndef SYNTHESIS
  // What two bubbles rely on: CS loads only the word the store read for it,
  // and keeps a word only while the store reads nothing; a word CS gives RD
  // reads the PDL buffer where it would after a redirect too.
  always_ff @(posedge clk) begin
    if (BUBBLES == 2 && !rst && errhalt == 2'd0) begin
      if (cs_moves && cs_rp[1] && (cs_ir[30] ? c_cs_nr.ptr : c_cs_nr.idx) != cs_pdl_addr) begin
        $display("quux15_core: two bubbles: CS's word at %o reads the PDL buffer at %o, not %o", cs_pc,
                 cs_ir[30] ? c_cs_nr.ptr : c_cs_nr.idx, cs_pdl_addr);
        $finish;
      end
      if (cs_load && !(cs_load_nr && npc_nr == npc_e)) begin
        $display("quux15_core: two bubbles: CS loads %o, the store read %o (%b)", npc_e, npc_nr, cs_load_nr);
        $finish;
      end
      if (cs_keep && !cs_moves && !cs_load && cs_load_nr_raw) begin
        $display("quux15_core: two bubbles: CS keeps %o while the store reads", cs_pc);
        $finish;
      end
    end
  end
  // **WHAT A WRITE'S WORD RELIES ON**: the port's queue entry, a register's
  // write and the walker take MD as it stands at the grant, for the word
  // muir's start carries from EX's commit (`written`), MD as the start's
  // microcycle left it (A15b.3; right after a read start, the read's word).
  // The two are one word because nothing moves MD while WB holds a write
  // start: a start waits in EX while a read is on its way, and WB holds EX
  // until its starts are granted.  A change that lets a word move MD in
  // between stops here.
  logic [39:0] md_at_commit;
  always_ff @(posedge clk) begin
    if (commit) md_at_commit <= md_final;
    if (!rst && errhalt == 2'd0 && wb_v && st_v[0] && st_write[0]
        && (md != md_at_commit || md_now != md_at_commit)) begin
      $display("quux15_core: MD moved between the commit of the write at %o and its grant: %o, not %o",
               wb_pc, md_now, md_at_commit);
      $finish;
    end
  end
  // **WHAT THE HALT RELIES ON**, which muir's drain does by hand:
  // - the successor's MD (`md_old`, kept at the drain's end only for the
  //   read start that ran last): a read start is granted in WB before the
  //   word after it commits, and any later commit drops it, so it is the
  //   last committed word's whenever it stands;
  // - RD's copies (`restore_copies`): a word's effects reach them only as
  //   it leaves RD for EX, and the squash leaves RD and CS empty, so with
  //   EX and WB drained they stand as the registers do, save a pending
  //   write's `seq` under no pending flag and the stack's top kept as the
  //   stack's word at the pointer (`spc_below`), the same word.
  always_ff @(posedge clk) begin
    if (!rst && errhalt == 2'd0) begin
      // A write is a word's first start, LC's fetch its second: WB keeps
      // one write's word.
      if (commit && xs1.v && xs1.write) begin
        $display("quux15_core: a write as a word's second start, %o", ex_pc);
        $finish;
      end
      if (n_old_v && n_old_seq != (commit ? ex_seq : last_seq)) begin
        $display("quux15_core: the MD a read start kept is not the last word's, %o", n_old_seq);
        $finish;
      end
      if (drain_end && (c_next.spc_ptr != c_res.spc_ptr || c_next.ptr != c_res.ptr || c_next.idx != c_res.idx
                        || c_next.lc != c_res.lc || c_next.nf != c_res.nf || c_next.bm != c_res.bm
                        || c_next.next_instr != c_res.next_instr || c_next.spc_pend || c_next.ptr_pend
                        || c_next.idx_pend || c_next.lc_pend
                        || (!c_next.spc_below && c_next.spc_top != c_res.spc_top))) begin
        $display("quux15_core: the halt leaves RD's copies apart from the registers");
        $finish;
      end
    end
  end
`endif

  // A device beyond the memory system's words, the frame buffer's window,
  // the redirect inside the PDL buffer: muir's `bus_read` and `bus_write`
  // and the redirect's buffer access, not built here.
  logic ub_wb;
  assign ub_wb = (at_grant && s_device && !st_write[0] && unbuilt_word(s_bus[7:0]))
              || (fault_now && s_redirect && s_inside) || ub_register;
  assign unbuilt = ub_ex | ((rd_moves && plan.ub_macro) ? (UNBUILT_BITS'(1) << U_MACRO) : '0)
                 | (ub_wb ? (UNBUILT_BITS'(1) << U_DEVICE) : '0)
                 | ((!dev_rd_built || !dev_wr_built) ? (UNBUILT_BITS'(1) << U_DEV) : '0);

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
      cs_v_q <= 1'b1; cs_nop_q <= 1'b1; cs_pre_nop_q <= 1'b0; cs_trap_q <= 1'b1; cs_dbg_q <= 1'b0;
      cs_seq_q <= 8'd1; cs_pc_q <= RESET_PC;
      rd_v_q <= 1'b0; ex_v <= 1'b0; wb_v <= 1'b0; rd_trap <= 1'b0;
      rd_nop <= 1'b0; rd_pre_nop <= 1'b0; ex_nop <= 1'b0; ex_pre_nop <= 1'b0;
      npc_q <= RESET_PC; npc_after_v_q <= 1'b0; npc_after_q <= 14'd0;
      nop_next_q <= 1'b0; pre_nop_next_q <= 1'b0;
      seq_ctr_q <= 8'd2;
      c <= '0;
      q <= 40'd0; vma <= 40'd0; md <= 40'd0; lc <= 34'd0; lc_needfetch <= 1'b0;
      pdl_ptr <= 14'd0; pdl_idx <= 14'd0; spcptr <= 5'd0; intctl <= 4'd0; dc <= 10'd0;
      overflow <= 1'b0; oa_low <= 26'd0; oa_high <= 22'd0;
      for (int k = 0; k < 8; k++) opc[k] <= 14'd0;
      npc_prev <= RESET_PC;
      next_instrd <= 1'b0;
      x_halted <= 1'b0; last_seq <= 8'd0; committed <= 64'd0;
      spc_w_v <= 1'b0; spc_w_ptr <= 5'd0; spc_w_word <= 19'd0;
      errhalt <= 2'd0;
      ex_clocks <= 5'd0;
      obs_commit <= 16'd0;
      obs_opnd <= 1'b0;
      // The memory side (`Pipeline::boot`, `reset_memory_system`): VMAOK
      // clear, nothing on its way, the words cleared.
      // LVMO as muir's machine has it at power-on (`lvmo_at_power_on`): read
      // and write access, the frame all ones.
      vmaok <= 1'b0; wrcyc <= 1'b0; lvmo <= 30'(32'b11 << 26 | 32'o777777);
      ack_left <= 2'd0; pend_v <= 1'b0; pend_dev <= 1'b0; rd_port <= 1'b0; old_v <= 1'b0;
      rgw_v <= 1'b0; mwd_v <= 1'b0; cprod_v <= 1'b0;
      bus_nxm <= 1'b0; posted_errors <= '0;
      wb_fresh <= 1'b0; st_v <= '0; ex_map_held <= 1'b0; ex_late_held <= 1'b0; ex_b_walked <= 1'b0;
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
      if (dmem_we && !x_daddr[0]) dmem_even[x_daddr[11:1]] <= dmem_wdata;
      if (dmem_we && x_daddr[0]) dmem_odd[x_daddr[11:1]] <= dmem_wdata;
      if (land_spc) spc[spc_w_ptr] <= spc_w_word;

      // --- The registers at EX's end.
      md <= n_md;
      if (commit) begin
        q <= nq; vma <= nvma; lc <= nlc; lc_needfetch <= nlc_nf;
        pdl_ptr <= nptr; pdl_idx <= nidx; intctl <= nintctl; dc <= ndc;
        overflow <= novf; oa_low <= noa_low; oa_high <= noa_high;
        spcptr <= sx.sp;
        spc_w_v <= nsw_v; spc_w_ptr <= nsw_ptr; spc_w_word <= nsw_word;
        npc_prev <= x_npc;
        next_instrd <= nid_new;
        // The HALT bit (`x.halted`): an executed word's `IR<11:10>` 1, not
        // a BYTE word's.
        x_halted <= !ex_nop && ex_isel[11:10] == 2'd1 && ex_isel[44:43] != 2'd3;
        last_seq <= ex_seq;
        committed <= committed + 64'd1;
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

      // --- The memory side.
      if (fault_now) begin
        vmaok <= vmaok_n;
        lvmo  <= s_entry;
        wrcyc <= st_write[0];
      end
      ack_left <= n_ack_left;
      pend_v <= n_pend_v; pend_left <= n_pend_left; pend_word <= n_pend_word; pend_dev <= n_pend_dev;
      rd_port <= n_rd_port;
      old_v <= n_old_v; old_seq <= n_old_seq; old_md <= n_old_md;
      rgw_v <= n_rgw_v; rgw_bus <= n_rgw_bus; rgw_rel <= n_rgw_rel; rgw_word <= n_rgw_word;
      mwd_v <= n_mwd_v; mwd_vma <= n_mwd_vma; mwd_md <= n_mwd_md;
      if (take_cmd_prod) begin
        cprod_v    <= 1'b1;
        cprod_word <= rgw_word[31:0];
      end else if (cprod_v && port_empty) begin
        cprod_v <= 1'b0;
      end
      bus_nxm <= n_bus_nxm; posted_errors <= n_posted;
      if (land_a_we && land_a_addr == 10'o430) pdl_base <= land_data[31:0];
      if (land_a_we && land_a_addr == 10'o431) pdl_head <= land_data[13:0];

      // --- WB: the word EX committed, and its writes and starts; or the word
      // --- WB holds, a start done.
      wb_v <= commit || (wb_v && !wb_leaves);
      wb_fresh <= commit;
      if (commit) begin
        st_v      <= {xs1.v, xs0.v};
        st_write  <= {xs1.write, xs0.write};
        st_fetch  <= {xs1.fetch, xs0.fetch};
        st_va[0]  <= xs0.va;
        st_va[1]  <= xs1.va;
      end else if (s_done) begin
        st_v      <= {1'b0, st_v[1]};
        st_write  <= {1'b0, st_write[1]};
        st_fetch  <= {1'b0, st_fetch[1]};
        st_va[0]  <= st_va[1];
      end
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
        ex_map_held <= 1'b0;
        ex_late_held <= 1'b0;
        ex_b_walked <= 1'b0;
        // The interrupt as it stood in the word's last clock in RD: what a
        // check that sampled there would read (a planted fault's).
        ex_int_rd <= int_now;
      end else if (commit || !ex_v) begin
        ex_v <= 1'b0;
        ex_clocks <= 5'd0;
      end else begin
        ex_a <= ex_a_d1;
        ex_m <= ex_m_d1;
        // MUL's and DIV's clocks count once the holds before them are past.
        if (ex_reach_mul) ex_clocks <= ex_clocks + 5'd1;
        if (ex_go && !md_wait && !start_wait && map_hold) ex_map_held <= 1'b1;
        if (ex_late) ex_late_held <= 1'b1;
        if (b_walk_done) ex_b_walked <= 1'b1;
      end

      // --- RD: CS's word, read at this edge; or the word RD holds, d2 and
      // the PDL buffer's forward into it.
      if (cs_moves) begin
        rd_v_q <= 1'b1; rd_nop <= cs_n_nop; rd_pre_nop <= cs_n_pre; rd_trap <= cs_trap;
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
        // The PDL buffer: the old word, unless the write landing at this
        // edge, two or more words before, replaces it; or the write landed
        // at the last edge, which the RAM takes at this one.
        begin
          logic land_fix;
          land_fix = land_pdl_we && land_pdl_addr == cs_pdl_addr
                  && (cs_seq - land_pdl_seq) >= 8'd2 && (cs_seq - land_pdl_seq) < 8'd128;
          rd_pdl_fix_v <= land_fix || (pdlh_v && pdlh_addr == cs_pdl_addr && !pdl_pend);
          rd_pdl_fix   <= land_fix ? land_pdl_data : pdlh_data;
        end
      end else if (rd_moves || !rd_keep) begin
        rd_v_q <= 1'b0;
      end else begin
        rd_nop <= rd_n_nop; rd_pre_nop <= rd_n_pre;
        rd_a_fix_v <= 1'b1; rd_a_fix <= rd_a_n;
        rd_m <= rd_m_n;
        rd_pdl_fix_v <= 1'b1; rd_pdl_fix <= rd_pdl_n;
      end

      // --- CS: the next word, at the address RD or the redirect chose.
      seq_ctr_q <= seq_e;
      npc_q <= npc_e; npc_after_q <= npc_after_e; npc_after_v_q <= npc_after_v_e;
      nop_next_q <= nop_next_e; pre_nop_next_q <= pre_nop_next_e;
      if (cs_load) begin
        cs_v_q <= 1'b1; cs_trap_q <= 1'b0;
        // With IDEBUG up the debug IR's word in place of the store's.
        cs_dbg_q <= cc_idebug; cs_dbg_word <= debug_ir;
        cs_nop_q <= nop_next_e; cs_pre_nop_q <= pre_nop_next_e && !nop_next_e;
        cs_seq_q <= seq_e; cs_pc_q <= npc_e;
        seq_ctr_q <= seq_e + 8'd1;
        npc_q <= npc_after_v_e ? npc_after_e : npc_e + 14'd1;
        npc_after_v_q <= 1'b0;
        nop_next_q <= 1'b0; pre_nop_next_q <= 1'b0;
      end else if (!cs_keep || cs_moves) begin
        // Squashed, or gone to RD with the next fetch a clock later.
        cs_v_q <= 1'b0;
      end else begin
        cs_nop_q <= cs_n_nop; cs_pre_nop_q <= cs_n_pre;
      end
    end
    if (!rst) begin
      // **THE CONSOLE'S -RESET AND -BOOT** (`console_edge`): OA-REG-LOW
      // and OA-REG-HIGH and word 225 cleared; the boot empties the four
      // stages and what is on its way (`reset_pipeline`), the trap in CS at
      // the PROM's first word, VMAOK clear.  Taken halted, the port idle.
      if (reset_q) begin
        oa_low <= '0; oa_high <= '0; posted_errors <= '0;
      end
      if (boot_q) begin
        spc_w_v <= 1'b0; old_v <= 1'b0; mwd_v <= 1'b0; vmaok <= 1'b0;
        npc_prev <= RESET_PC;
        c <= c_boot;
      end
    end
  end

  // ============================================================ the console

  // RD's copies after a boot (`restore_copies` after `reset_pipeline`): the
  // registers as they stand, the stack's pending write dropped.
  copies_t c_boot;
  always_comb begin
    c_boot = '0;
    c_boot.spc_ptr = spcptr;
    c_boot.spc_top = spc[spcptr];
    c_boot.ptr = pdl_ptr;
    c_boot.idx = pdl_idx;
    c_boot.lc = lc;
    c_boot.nf = lc_needfetch;
    c_boot.bm = intctl[3];
    c_boot.next_instr = next_instrd;
  end

  // **THE HALT ENDS** (`clock_once`'s end) as the clock ends with nothing in
  // the four stages, the port idle, no word on its way to MD, no register
  // write or CMD_PROD left: halted, between two microcycles.
  logic ex_v_n, wb_v_n, rd_v_n, cs_v_n, cprod_v_n, drain_end, halt_set;
  always_comb begin
    ex_v_n    = rd_moves || (ex_v && !commit);
    wb_v_n    = commit || (wb_v && !wb_leaves);
    rd_v_n    = cs_moves || (rd_keep && !rd_moves);
    cs_v_n    = cs_load || (cs_keep && !cs_moves);
    cprod_v_n = take_cmd_prod || (cprod_v && !port_empty);
    drain_end = (draining_now || stepping || step_go) && errhalt == 2'd0 && !errhalt_now
             && !ex_v_n && !wb_v_n && !rd_v_n && !cs_v_n && port_idle_n
             && !n_rd_port && !n_pend_v && !n_rgw_v && !cprod_v_n;
    // A HALT word under ERROR-STOP-ENABLE: the machine drains (`ex.halt`).
    halt_set  = commit && !ex_nop && ex_isel[11:10] == 2'd1 && ex_isel[44:43] != 2'd3 && errstop;
  end

  // **THE SPY'S WRITE** (`Machine::spy_write`), at the edge before the
  // clock it is for; `-RESET` and `-BOOT` with it (`reset_go`, `boot_go`).
  always_ff @(posedge clk) begin
    if (rst) begin
      // `Pipeline::boot`: RUN preset by -BOOT.
      cc_run <= 1'b1; cc_step <= 1'b0; cc_nop11 <= 1'b0; cc_idebug <= 1'b0; cc_ldstat <= 1'b0;
      mode <= '0; opc_ctl <= '0; debug_ir <= '0;
      srun <= 1'b1; sstep <= 1'b0; ssdone <= 1'b0;
      halted <= 1'b0; draining <= 1'b0; stepping <= 1'b0; halt_req <= 1'b0;
    end else begin
      ssdone   <= sstep;
      sstep    <= cc_step;
      srun     <= drain_end ? 1'b0 : cc_run;
      halted   <= drain_end || halted_now;
      draining <= draining_now && !drain_end;
      stepping <= (stepping || step_go) && !drain_end;
      halt_req <= halt_set;
      if (drain_end) cc_run <= 1'b0;
      if (rw_take && rgw_bus[7:0] == 8'o102) mode[2] <= rgw_word[0];
      if (spy_we) begin
        unique case (spy_eadr[2:0])
          3'd0: debug_ir[15:0]  <= spy_wdata;
          3'd1: debug_ir[31:16] <= spy_wdata;
          3'd2: debug_ir[47:32] <= spy_wdata;
          3'd3: {cc_ldstat, cc_idebug, cc_nop11, cc_step, cc_run} <= spy_wdata[4:0];
          3'd4: opc_ctl <= spy_wdata[2:0];
          // QUUX's mode register has no speed bits.
          3'd5: mode <= {spy_wdata[5:2], 2'b00};
          // `-LDDBIRX` (proposed), revision 15's alone.
          3'd6: debug_ir[63:48] <= spy_wdata;
          default: ;
        endcase
      end
      if (reset_go) begin
        mode <= '0; opc_ctl <= '0;
        cc_step <= 1'b0; cc_nop11 <= 1'b0; cc_idebug <= 1'b0; cc_ldstat <= 1'b0;
      end
      if (boot_go) cc_run <= 1'b1;
    end
  end

  // The PDL buffer's held write, and the halt's drain end and the boot.
  always_ff @(posedge clk) begin
    if (rst) begin
      pdlh_v <= 1'b0; pdl_pend <= 1'b0;
    end else begin
      if (land_pdl_we && running) begin
        pdlh_v <= 1'b1; pdlh_addr <= land_pdl_addr; pdlh_data <= land_pdl_data; pdlh_seq <= land_pdl_seq;
      end
      // The held-over write lands after the first word's read.
      if (pdl_pend && cs_moves) pdl_pend <= 1'b0;
      if (drain_end && !pdl_pend) begin
        if ((land_pdl_we && running) ? land_pdl_seq == (commit ? ex_seq : last_seq)
                                     : (pdlh_v && pdlh_seq == (commit ? ex_seq : last_seq)))
          pdl_pend <= 1'b1;
      end
      // A boot loses a write held over (`Back::default`).
      if (boot_q && pdl_pend) begin
        pdlh_v <= 1'b0; pdl_pend <= 1'b0;
      end
    end
  end

  // **THE SPY'S READ** (`spy_15`, of committed state): IR the next word to
  // run, read from the store while halted (a console reads IR halted), PC
  // its address; OPC the oldest
  // of the eight; FLAG-1's PROMDISABLE, ERR (the HALT bit), SSDONE and
  // SRUN, its other flags clear in their senses; FLAG-2's VMAOK; the
  // statistics counter 0; the rest open.
  always_comb begin
    unique case (spy_raddr)
      4'd0:  spy_rdata = store_q[15:0];
      4'd1:  spy_rdata = store_q[31:16];
      4'd2:  spy_rdata = store_q[47:32];
      4'd3:  spy_rdata = store_q[63:48];
      4'd4:  spy_rdata = {2'b00, opc[7]};
      // PC: the oldest word not committed, or the next fetch (`pc_15`).
      4'd5:  spy_rdata = {2'b00, (ex_v && !ex_nop) ? ex_pc : (rd_v_q && !rd_nop) ? rd_pc
                                  : (cs_v_q && !cs_nop_q) ? cs_pc_q : npc_q};
      4'd8:  spy_rdata = 16'he800 | {3'd0, mode[5], 1'b0, x_halted, ssdone, srun, 8'd0};
      4'd9:  spy_rdata = 16'hc0c0 | {12'd0, !vmaok, 3'd0};
      4'd14: spy_rdata = 16'd0;
      4'd15: spy_rdata = 16'd0;
      default: spy_rdata = 16'hffff;
    endcase
  end

  // **THE READOUT OF THE HALTED PIPELINE** (`save_15`'s fields after the
  // machine, the period and the port, in its order).
  always_comb begin
    unique case (ro_sel)
      5'd0:  ro_word = {50'd0, npc};
      5'd1:  ro_word = {49'd0, npc_after_v, npc_after};
      5'd2:  ro_word = {62'd0, pre_nop_next, nop_next};
      5'd3:  ro_word = {49'd0, pdl_pend, pdlh_addr};
      5'd4:  ro_word = {24'd0, pdlh_data};
      5'd5:  ro_word = {63'd0, old_v};
      5'd6:  ro_word = {24'd0, old_md};
      5'd7:  ro_word = 64'd0;                             // D's wait: D is not built
      5'd8:  ro_word = {38'd0, oa_low};
      5'd9:  ro_word = {42'd0, oa_high};
      5'd10: ro_word = {63'd0, next_instrd};
      5'd11: ro_word = {34'd0, lvmo};
      5'd12: ro_word = {63'd0, wrcyc};
      5'd13: ro_word = {39'd0, spc_w_v, spc_w_ptr, spc_w_word};
      5'd14: ro_word = {63'd0, mwd_v};
      5'd15: ro_word = {24'd0, mwd_vma};
      5'd16: ro_word = {24'd0, mwd_md};
      5'd17: ro_word = {8'd0, opc[3], opc[2], opc[1], opc[0]} ;
      5'd18: ro_word = {8'd0, opc[7], opc[6], opc[5], opc[4]};
      5'd19: ro_word = {62'd0, x_halted, halted};
      5'd20: ro_word = committed;
      5'd21: ro_word = {50'd0, npc_prev};
      // The console's registers, which the machine's part of a checkpoint
      // carries: the mode register, the clock control register, the OPC
      // control register; and the debug IR.
      5'd22: ro_word = {50'd0, opc_ctl, cc_ldstat, cc_idebug, cc_nop11, cc_step, cc_run, mode};
      5'd23: ro_word = debug_ir;
      default: ro_word = 64'd0;
    endcase
  end

  // ========================================================= the observation

  // The clock's events, as the trace has them: a grant at WB, a word landed
  // in MD, a register taken; the depths as the clock ends.
  always_ff @(posedge clk) begin
    if (rst || errhalt != 2'd0) begin
      obs_grant <= 2'd0; obs_mdl <= 1'b0; obs_reg <= 1'b0;
      obs_queue <= rst ? 4'd0 : queue_n; obs_inflight <= rst ? 5'd0 : inflight_n;
    end else begin
      obs_grant    <= at_grant ? {st_write[0], 1'b1} : 2'd0;
      obs_gaddr    <= {3'd0, s_bus};
      obs_mdl      <= land_now;
      obs_mdword   <= land_word;
      obs_reg      <= (at_grant && s_device && !st_write[0]) || (rw_take && !take_cmd_prod);
      obs_raddr    <= {3'd0, rw_take ? rgw_bus : s_bus};
      obs_queue    <= queue_n;
      obs_inflight <= inflight_n;
    end
  end

  always_comb begin
    // A HALT word's drain squashes CS and RD as its clock ends in muir
    // (`ex.halt`), which the core does as the next clock begins: the clock's
    // row shows them gone.
    obs_cs       = {cs_v_q && !(halt_req && !halted && !draining), cs_v_q && cs_nop_q, cs_pc_q};
    obs_rd       = {rd_v_q && !(halt_req && !halted && !draining), rd_v_q && rd_nop, rd_pc};
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
    obs_halted   = halted;
    obs_errhalt  = errhalt;
  end

`ifndef SYNTHESIS
  // **A15b.2's rule, the micro-assembler's**: no word right after a start
  // reads the map (`MAP(MD)` or a map-bit dispatch).  The core relies on it
  // (port B sees nothing of WB's clock), so a trace that breaks it is no
  // reference for this core.
  logic s1_prev_started;
  always_ff @(posedge clk) begin
    if (rst) s1_prev_started <= 1'b0;
    else if (commit) s1_prev_started <= xs0.v;
    if (!rst && errhalt == 2'd0 && commit && ex_portb && s1_prev_started) begin
      $display("quux15_core: the word at %o reads the map right after a start (A15b.2's rule)", ex_pc);
      $finish;
    end
  end

  // muir grants a word's second start in the clock its first faults; WB
  // here takes one start a clock, which no program yet tells apart.
  always_ff @(posedge clk) begin
    if (!rst && errhalt == 2'd0 && s_faulted && st_v[1])
      $error("quux15_core: a start after a start that faulted, in one clock, at PC %o", wb_pc);
  end

  // A word that needs what is not built stops the simulation, named.
  always_ff @(posedge clk) begin
    if (!rst && errhalt == 2'd0 && unbuilt != '0) begin
      $display("quux15_core: not built: %b (bit 0 a device, the window or the redirect inside, 1 MACRO-DISPATCH, 2 a device word unanswered) at PC %o",
               unbuilt, ex_v ? ex_pc : rd_pc);
      $finish;
    end
  end
`endif

  // What nothing reads yet.
  logic unused;
  assign unused = ^{ex_int_rd, s_regword[32], st_fetch, port_idle, lvmo[29:28], lvmo[25:0], n_land, n_md_now[39:32],
                    ex_pre_nop, x_mul, x_div, wb_seq, unbuilt, ex_word[63:62], ex_word[59],
                    ex_msrc[4], sx.pushed, ex_disp, plan.returns,
                    spy_eadr[3]};   // the write decoder takes `EADR<2:0>` (`spy::write_strobe`)

endmodule

`default_nettype wire
