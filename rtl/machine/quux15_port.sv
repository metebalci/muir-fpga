// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S PORT** (contract G3 revision 15, §6, A15b.5, A15b.6;
// the A15b.5 port's clocks): the cache holding its lines'
// words, the posted writes' queue of 8 and in-flight list of 16, the one
// fill, and main memory behind them on `quux15_axi_master.sv`.  muir's
// `muir::pipeline::port::Port` is the reference, clock for clock, through
// the core (`quux15_core.sv`) and its goldens.
//
// **A CLOCK BEGINS WITH muir'S `Port::tick`**, from the registers it began
// with: the writes at the in-flight list's front that are answered land, in
// order, several in one clock when a later one was answered first; the
// queue's head is accepted when its word is fixed, the list has room after
// those landings, and the write channel takes it; the fill waiting on the
// read rule is issued when no write to its line is queued or in flight; a
// fill whose line came in the clock before lands.  The core's stages then
// ask in this clock what muir's ask after the tick.
//
// **A LOOKUP IS A RAM READ AT THE CLOCK'S END**, its answer in the next:
// the tags compared there, a hit's word registered and in `MD` (or the
// table reader's) two clocks after the grant, as muir's hit; a miss's fill
// made then, as muir asks for it ("the fill is asked for then"), and
// issued in that clock if the read rule lets it.  Three ask:
//   P  the processor's read at WB's grant, through port A, never while a
//      fill is in flight (`p_busy`, muir's `Answer::Busy`, which holds WB);
//   W  a write start at WB's grant, port A's tags alone: whether the cache
//      holds its line, which its word, once fixed, writes;
//   T  a table read of a walk or a write-back, through port B; it is not
//      made while a fill is in flight and is asked again the next clock, as
//      muir's walker asks again after `Busy`; one made in the clock of a P
//      read that misses was Busy in muir, whose P made its fill first, and
//      is asked again.
//
// **THE LINES' WRITES WAIT FOR PORT B** in a buffer of four: a word fixed
// for a write the cache holds, a write-back's posted word.  Each is written
// at the first clock port B neither reads for T nor installs a fill and
// port A does not read the line's set; until then, and in the clock after
// one is made, a lookup's word is taken from the buffer where it holds a
// newer one.  muir's word is written at once, so the lookup that follows
// sees it, and so does this one.
//
// **THE CACHE**: 2 ways a set, `SETS` sets of 8 words, the set the line's
// low bits, LRU by the way used last; tags and lines in `quux15_tdp.sv`
// RAMs (a line 8 words of five bytes, so that a word is written with its
// byte enables, as UltraRAM takes them), the valid bits and the
// way used last in registers.  A fill installs into the way not used last
// at the edge of its line's last beat, and lands the clock after, when
// lookups may be made again; a queued write or a buffered word whose line
// it replaces no longer has its line in the cache.

`default_nettype none

module quux15_port #(
    parameter int unsigned SETS    = 4096,
    parameter bit          ONE_WRITE_ID = 1'b1,
    parameter int unsigned ID_BITS = 4,
    localparam int unsigned SB = $clog2(SETS),
    localparam int unsigned TB = 26 - SB
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- P: the processor's read.
    output var logic        p_busy,
    input  var logic        p_req,
    input  var logic [28:0] p_bus,
    output var logic        p_land,
    output var logic [39:0] p_word,
    // What lands in MD next clock: the core's next lookup of port B reads it.
    output var logic        p_land_next,
    output var logic [39:0] p_word_next,

    // --- W: a write start, and its word once fixed.
    output var logic        w_ok,
    input  var logic        w_req,
    input  var logic [28:0] w_bus,
    output var logic [2:0]  w_slot,
    input  var logic        fix_v,
    input  var logic [2:0]  fix_slot,
    input  var logic [39:0] fix_word,

    // --- A write-back's posted word, ahead of its reference's start.
    input  var logic        post_req,
    input  var logic [28:0] post_bus,
    input  var logic [39:0] post_word,
    output var logic        post_ok,

    // --- T: a table read, begun; its word, the clock it is here.
    input  var logic        t_start,
    input  var logic [28:0] t_addr,
    output var logic        t_ready,
    output var logic [39:0] t_word,

    // --- The tick's answers: error responses landed this clock (word 225),
    // --- and the queue's and the in-flight list's depths as the clock ends.
    output var logic [4:0]  errors_now,
    output var logic [3:0]  queue_n,
    output var logic [4:0]  inflight_n,
    // Nothing queued, in flight or filling.
    output var logic        idle,
    // The same as the clock ends, the sweep's hold over too (`Port::idle`):
    // what a halt's drain waits for.
    output var logic        idle_n,
    // Every write answered, as the tick leaves the clock (`Port::empty`):
    // what CMD_PROD waits for.
    output var logic        empty,
    // The file device's completion this clock: every line invalid, and
    // every lookup waits a set's clock each (`Port::sweep`; A15b.6).
    input  var logic        sweep_go,
    // The master's declared constants and its writes' ID mode
    // (`quux15_axi_master.sv`).
    output var logic        one_write_id,
    output var logic [3:0]  read_fabric_clocks,
    output var logic [3:0]  write_fabric_clocks,

    // --- Main memory.
    output var logic [ID_BITS-1:0] m_awid,
    output var logic [31:0]        m_awaddr,
    output var logic [7:0]         m_awlen,
    output var logic [2:0]         m_awsize,
    output var logic [1:0]         m_awburst,
    output var logic               m_awvalid,
    input  var logic               m_awready,
    output var logic [63:0]        m_wdata,
    output var logic [7:0]         m_wstrb,
    output var logic               m_wlast,
    output var logic               m_wvalid,
    input  var logic               m_wready,
    input  var logic [ID_BITS-1:0] m_bid,
    input  var logic [1:0]         m_bresp,
    input  var logic               m_bvalid,
    output var logic               m_bready,
    output var logic [31:0]        m_araddr,
    output var logic [7:0]         m_arlen,
    output var logic [2:0]         m_arsize,
    output var logic [1:0]         m_arburst,
    output var logic               m_arvalid,
    input  var logic               m_arready,
    input  var logic [63:0]        m_rdata,
    input  var logic [1:0]         m_rresp,
    input  var logic               m_rlast,
    input  var logic               m_rvalid,
    output var logic               m_rready
);

  localparam int unsigned QN = 8;
  localparam int unsigned FN = 16;
  localparam int unsigned DBN = 4;

  // A bus address's set, tag and lane.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [SB-1:0] set_of(input logic [28:0] b);
    return b[3 +: SB];
  endfunction
  function automatic logic [TB-1:0] tag_of(input logic [28:0] b);
    return b[28 -: TB];
  endfunction
  // A written word as the line keeps it, what a fill would read back: main
  // memory's whole word; in the frame buffer's window (`<28>`) the field
  // with a fixnum's tag, `005`, the window storing the field and dropping
  // the tag (G1 §4.2).
  function automatic logic [39:0] as_held(input logic [28:0] b, input logic [39:0] w);
    return b[28] ? {8'o005, w[31:0]} : w;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ============================================================== the master

  logic         ar_req, ar_taken, rd_last;
  logic [319:0] rd_data;
  logic         mw_req, mw_free, mw_taken, b_done, b_err;
  logic [ID_BITS-1:0] mw_id, b_id;
  logic [28:0]  mw_bus;
  logic [39:0]  mw_word;
  logic [25:0]  ar_line;

  quux15_axi_master #(.ID_BITS(ID_BITS), .ONE_WRITE_ID(ONE_WRITE_ID)) master (
      .clk(clk), .rst(rst),
      .ar_req(ar_req), .ar_line(ar_line), .ar_taken(ar_taken), .rd_last(rd_last), .rd_data(rd_data),
      .w_req(mw_req), .w_bus(mw_bus), .w_word(mw_word), .w_id(mw_id), .w_free(mw_free),
      .w_taken(mw_taken), .b_done(b_done), .b_id(b_id), .b_err(b_err),
      .one_write_id(one_write_id),
      .read_fabric_clocks(read_fabric_clocks), .write_fabric_clocks(write_fabric_clocks),
      .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
      .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata),
      .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bid(m_bid),
      .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready), .m_araddr(m_araddr),
      .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arvalid(m_arvalid),
      .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
      .m_rvalid(m_rvalid), .m_rready(m_rready)
  );

  // =============================================================== the state

  // The queue: each entry's bus address, word, whether the word is fixed,
  // and whether the cache holds its line (`q_hres` once the grant's tag read
  // has answered), in which way.
  logic [28:0] q_bus [QN];
  logic [39:0] q_word [QN];
  logic [QN-1:0] q_wv, q_hit, q_way, q_hres;
  logic [2:0]  q_head;
  logic [3:0]  q_count;

  // The in-flight list, a write's slot its AXI ID: its line, answered, and
  // answered with an error.
  logic [25:0] f_line [FN];
  logic [FN-1:0] f_arr, f_err;
  logic [3:0]  f_head;
  logic [4:0]  f_count;

  // The fill: waiting on the read rule, its line coming, landing.
  typedef enum logic [1:0] {F_NONE, F_WAIT, F_DATA, F_LAND} fstate_e;
  fstate_e     fs;
  logic [28:0] f_bus;
  logic        f_table;      // a table read's, not the processor's
  logic [39:0] f_word;

  // The lookups made at the last clock's end.
  logic        lp_v, lw_v, lt_v, lt_with_p;
  logic [28:0] lp_bus, lw_bus, lt_bus;
  logic [2:0]  lw_slot;
  // A P hit's word, landing.
  logic        p_hit_land;
  logic [39:0] p_hit_word;

  // The table read: begun and refused (Busy), its lookup made, its word
  // registered, its fill in flight.
  typedef enum logic [2:0] {T_IDLE, T_RETRY, T_LOOK, T_HIT, T_FILL} tstate_e;
  tstate_e     tst;
  logic [28:0] t_bus;
  logic [39:0] t_word_q;
  // The line the last table read found or filled, and its way: a
  // write-back's post writes that word.
  logic        tl_v, tl_way;
  logic [25:0] tl_line;

  // The sweep's clocks still to run after this one: cache words / 512 in
  // all (A15b.6); lookups wait while it runs.
  localparam int unsigned SWEEP_CLOCKS = SETS * 16 / 512 > 1 ? SETS * 16 / 512 : 1;
  logic [15:0] sweep_left;
  logic        sweeping;
  assign sweeping = sweep_go || sweep_left != 16'd0;
  // The set and way the last fill installed: a planted fault's sweep leaves
  // them.
  logic [SB-1:0] last_fill_set;
  logic          last_fill_way;

  // The cache's valid bits, a way's in RAM (`quux15_validmap.sv`), which
  // the sweep clears in its first clock; and the way each set used last, in
  // RAM too (`quux15_recency.sv`).  An empty cache at power-on, as a
  // bitstream holds it, which -RESET leaves as it is.
  logic          mru_f;
  logic          v0p, v0t, v0w, v1p, v1t, v1w;
  // The fill installed at the last edge: its set and way.
  logic        inst_q, inst_way_q;
  logic [SB-1:0] inst_set_q;

  // The lines' writes waiting for port B: each entry's set, way, lane,
  // word, whether its line is in the cache, its way still to come from the
  // grant's tag read (`db_pend`), made in the clock before (`db_young`).
  logic [DBN-1:0] db_v, db_hit, db_way, db_pend, db_young;
  logic [SB-1:0] db_set [DBN];
  logic [2:0]    db_lane [DBN];
  logic [39:0]   db_word [DBN];
  logic [2:0]    db_slot [DBN];

  // ================================================================ the RAMs

  logic          ta_en, tb_en, da_en, db_en;
  logic [SB-1:0] ta_addr, tb_addr, da_addr, dbk_addr;
  logic [1:0]    tb_we;
  logic [TB-1:0] tb_wdata;
  logic [TB-1:0] tag0_a, tag1_a, tag0_b, tag1_b;
  logic [39:0]   d0_we, d1_we;
  logic [319:0]  dbk_wdata;
  logic [319:0]  data0_a, data1_a, data0_b, data1_b;

  quux15_tdp #(.WIDTH(TB), .DEPTH(SETS)) tags0 (
      .clk(clk), .a_en(ta_en), .a_we(1'b0), .a_addr(ta_addr), .a_wdata('0), .a_q(tag0_a),
      .b_en(tb_en), .b_we(tb_we[0]), .b_addr(tb_addr), .b_wdata(tb_wdata), .b_q(tag0_b));
  quux15_tdp #(.WIDTH(TB), .DEPTH(SETS)) tags1 (
      .clk(clk), .a_en(ta_en), .a_we(1'b0), .a_addr(ta_addr), .a_wdata('0), .a_q(tag1_a),
      .b_en(tb_en), .b_we(tb_we[1]), .b_addr(tb_addr), .b_wdata(tb_wdata), .b_q(tag1_b));
  quux15_tdp #(.WIDTH(320), .DEPTH(SETS), .BYTE(8)) lines0 (
      .clk(clk), .a_en(da_en), .a_we('0), .a_addr(da_addr), .a_wdata('0), .a_q(data0_a),
      .b_en(db_en), .b_we(d0_we), .b_addr(dbk_addr), .b_wdata(dbk_wdata), .b_q(data0_b));
  quux15_tdp #(.WIDTH(320), .DEPTH(SETS), .BYTE(8)) lines1 (
      .clk(clk), .a_en(da_en), .a_we('0), .a_addr(da_addr), .a_wdata('0), .a_q(data1_a),
      .b_en(db_en), .b_we(d1_we), .b_addr(dbk_addr), .b_wdata(dbk_wdata), .b_q(data1_b));

  // A lane of a line.
  function automatic logic [39:0] lane(input logic [319:0] row, input logic [2:0] k);
    return row[40*k +: 40];
  endfunction

  // ================================================================ the tick

  // The writes that land: those at the list's front, each answered and
  // every one before it.
  logic [4:0]  n_land, n_err;
  logic [FN-1:0] staying;      // by slot: in flight after the landings
  always_comb begin
    logic run;
    n_land = '0;
    n_err  = '0;
    run    = 1'b1;
    staying = '0;
    for (int k = 0; k < FN; k++) begin
      logic [3:0] s;
      s = f_head + 4'(k);
      if (5'(k) < f_count) begin
        if (run && f_arr[s]) begin
          n_land = n_land + 5'd1;
          n_err  = n_err + {4'd0, f_err[s]};
        end else begin
          run = 1'b0;
          staying[s] = 1'b1;
        end
      end
    end
    errors_now = n_err;
  end

  // The accept: the head's word fixed, room in the list after the landings,
  // the write channel free.
  logic [3:0] f_tail;
  always_comb begin
    f_tail  = f_head + f_count[3:0];
    mw_req  = q_count != 4'd0 && q_wv[q_head] && (f_count - n_land) < 5'(FN) && mw_free;
    mw_bus  = q_bus[q_head];
    mw_word = q_word[q_head];
    mw_id   = f_tail;
  end

  // The lookups' answers, of the lookups made at the last clock's end.
  logic [SB-1:0] p_set, t_set, w_set;
  logic          p_h0, p_h1, p_hit, p_miss, t_h0, t_h1, t_hit, t_miss, t_cancel, w_h0, w_h1;
  logic [39:0]   p_lookup_word, t_lookup_word;
  always_comb begin
    p_set = set_of(lp_bus);
    t_set = set_of(lt_bus);
    w_set = set_of(lw_bus);
    p_h0  = v0p && tag0_a == tag_of(lp_bus);
    p_h1  = v1p && tag1_a == tag_of(lp_bus);
    p_hit  = lp_v && (p_h0 || p_h1);
    p_miss = lp_v && !(p_h0 || p_h1);
    t_h0  = v0t && tag0_b == tag_of(lt_bus);
    t_h1  = v1t && tag1_b == tag_of(lt_bus);
    // A table read made with a P read that missed was Busy.
    t_cancel = lt_v && lt_with_p && p_miss;
    t_hit  = lt_v && !t_cancel && (t_h0 || t_h1);
    t_miss = lt_v && !t_cancel && !(t_h0 || t_h1);
    // A write start's tags: the way a fill installed at the same edge was
    // read through its write, and cannot hold the start's line, which no
    // fill in flight has.
    w_h0  = v0w && tag0_a == tag_of(lw_bus) && !(inst_q && inst_set_q == w_set && !inst_way_q);
    w_h1  = v1w && tag1_a == tag_of(lw_bus) && !(inst_q && inst_set_q == w_set && inst_way_q);
    // The words, a buffered newer one in place of the line's.
    p_lookup_word = lane(p_h1 ? data1_a : data0_a, lp_bus[2:0]);
    t_lookup_word = lane(t_h1 ? data1_b : data0_b, lt_bus[2:0]);
    for (int k = 0; k < DBN; k++) begin
      if (db_v[k] && !db_young[k] && db_hit[k] && !db_pend[k] && db_set[k] == p_set
          && db_way[k] == p_h1 && db_lane[k] == lp_bus[2:0])
        p_lookup_word = db_word[k];
      if (db_v[k] && !db_young[k] && db_hit[k] && !db_pend[k] && db_set[k] == t_set
          && db_way[k] == t_h1 && db_lane[k] == lt_bus[2:0])
        t_lookup_word = db_word[k];
    end
  end

  // The fill: made by a miss now, issued when the read rule lets it.
  logic        f_new, f_exists, f_issue, written;
  logic [28:0] f_bus_now;
  logic [25:0] f_line_now;
  always_comb begin
    f_new      = p_miss || t_miss;
    f_bus_now  = f_new ? (p_miss ? lp_bus : lt_bus) : f_bus;
    f_line_now = f_bus_now[28:3];
    f_exists   = fs == F_WAIT || fs == F_DATA || f_new;
    // The read rule: no write to the line queued, or in flight and not
    // landing now.
    written = 1'b0;
    for (int k = 0; k < QN; k++)
      if (4'(k) < q_count && q_bus[3'(q_head + 3'(k))][28:3] == f_line_now) written = 1'b1;
    for (int k = 0; k < FN; k++)
      if (staying[k] && f_line[k] == f_line_now) written = 1'b1;
    ar_req  = (fs == F_WAIT || f_new) && !written;
    ar_line = f_line_now;
    f_issue = ar_taken;
  end

  // P, W, post: what the core may ask now.
  logic [3:0] q_after_accept;
  logic       post_push, w_push;
  assign p_busy = fs == F_WAIT || fs == F_DATA || sweeping;
  always_comb begin
    q_after_accept = q_count - {3'd0, mw_taken};
    post_ok = q_after_accept < 4'(QN);
  end
  assign post_push = post_req && post_ok;
  always_comb begin
    w_ok = !((fs == F_WAIT || fs == F_DATA) && f_bus[28:3] == w_bus[28:3]) && !sweeping
        && (q_after_accept + {3'd0, post_push}) < 4'(QN);
  end
  always_comb begin
    w_push = w_req && w_ok;
    w_slot = 3'(q_head + 3'(q_count) + 3'(post_push));
  end

  // T: made now when begun or asked again and no fill is in flight.
  logic t_issue, t_wanted;
  always_comb begin
    t_wanted = t_start || tst == T_RETRY || (tst == T_LOOK && t_cancel);
    t_issue  = t_wanted && !f_exists && !sweeping;
  end
  always_comb begin
    t_ready  = tst == T_HIT || (tst == T_FILL && fs == F_LAND);
    t_word   = tst == T_HIT ? t_word_q : f_word;
    p_land   = p_hit_land || (fs == F_LAND && !f_table);
    p_word   = p_hit_land ? p_hit_word : f_word;
  end
  always_comb begin
    p_land_next = p_hit || (install && !f_table);
    p_word_next = p_hit ? p_lookup_word : rd_data[40*f_bus[2:0] +: 40];
  end

  // The install: at the edge of the line's last beat, into the way the set
  // did not use last.
  logic          install, victim;
  logic [SB-1:0] f_set;
  always_comb begin
    install = fs == F_DATA && rd_last;
    f_set   = set_of(f_bus);
    victim  = !mru_f;
  end

  // The way each set used last: a P hit's, a T hit's and an install's
  // writes, the later in that order taking a set written twice; none in
  // -RESET.
  quux15_recency #(.SETS(SETS)) recency (
      .clk(clk),
      .we0(p_hit && !rst), .wa0(p_set), .wd0(p_h1),
      .we1(t_hit && !rst), .wa1(t_set), .wd1(t_h1),
      .we2(install && !rst), .wa2(f_set), .wd2(victim),
      .ra(f_set), .rd(mru_f));

  logic          v_we0, v_we1;
  logic [SB-1:0] v_wa;
  quux15_validmap #(.ENTRIES(SETS), .READS(3)) valid0 (
      .clk(clk), .rst(1'b0), .clear(sweep_go), .we(v_we0), .waddr(v_wa), .wbit(1'b1),
      .raddr0(lp_bus[3 +: SB]), .raddr1(lt_bus[3 +: SB]), .raddr2(lw_bus[3 +: SB]),
      .rbit0(v0p), .rbit1(v0t), .rbit2(v0w));
  quux15_validmap #(.ENTRIES(SETS), .READS(3)) valid1 (
      .clk(clk), .rst(1'b0), .clear(sweep_go), .we(v_we1), .waddr(v_wa), .wbit(1'b1),
      .raddr0(lp_bus[3 +: SB]), .raddr1(lt_bus[3 +: SB]), .raddr2(lw_bus[3 +: SB]),
      .rbit0(v1p), .rbit1(v1t), .rbit2(v1w));
  // The valid maps' writes: a fill's install.
  always_comb begin
    v_we0 = install && !victim;
    v_we1 = install && victim;
    v_wa  = f_set;
  end

  // The buffer's next entry to write, and the RAMs' ports this clock.
  // The oldest alone, in order: one whose way is still to come waits a
  // clock, and every word behind it.
  logic          drain;
  logic [1:0]    drain_k;
  always_comb begin
    drain_k = '0;
    drain = db_v[0] && !db_pend[0] && !install && !t_issue && !(p_req && set_of(p_bus) == db_set[0]);
    // Port A: P's tags and lines, or W's tags.
    ta_en   = p_req || w_push;
    ta_addr = p_req ? set_of(p_bus) : set_of(w_bus);
    da_en   = p_req;
    da_addr = set_of(p_bus);
    // Port B: the install, a table read, a buffered word.
    tb_en    = install || t_issue;
    tb_addr  = install ? f_set : set_of(t_issue ? (t_start ? t_addr : t_bus) : t_bus);
    tb_we    = install ? (victim ? 2'b10 : 2'b01) : 2'b00;
    tb_wdata = tag_of(f_bus);
    // Port B enabled for the oldest word whether it drains or not, a read
    // that nothing takes when it does not: the drain gates the write alone.
    db_en    = install || t_issue || (db_v[0] && !db_pend[0] && db_hit[0]);
    dbk_addr = install ? f_set : (t_issue ? set_of(t_start ? t_addr : t_bus) : db_set[drain_k]);
    d0_we    = '0;
    d1_we    = '0;
    dbk_wdata = '0;
    if (install) begin
      dbk_wdata = rd_data;
      if (victim) d1_we = '1;
      else        d0_we = '1;
    end else if (!t_issue && drain && db_hit[drain_k]) begin
      dbk_wdata[40*db_lane[drain_k] +: 40] = db_word[drain_k];
      if (db_way[drain_k]) d1_we[5*db_lane[drain_k] +: 5] = 5'h1f;
      else                 d0_we[5*db_lane[drain_k] +: 5] = 5'h1f;
    end
  end

  // The depths as the clock ends.
  always_comb begin
    queue_n    = q_count - {3'd0, mw_taken} + {3'd0, post_push} + {3'd0, w_push};
    inflight_n = f_count - n_land + {4'd0, mw_taken};
    idle       = q_count == 4'd0 && f_count == 5'd0 && fs == F_NONE;
    begin
      logic fill_n;
      // A fill as the clock ends: asked for now, issued or waiting, or
      // landing at the next clock.
      unique case (fs)
        F_NONE, F_LAND: fill_n = f_new;
        F_WAIT:         fill_n = 1'b1;
        F_DATA:         fill_n = 1'b1;
        default:        fill_n = 1'b0;
      endcase
      idle_n = queue_n == 4'd0 && inflight_n == 5'd0 && !fill_n && !sweep_go && sweep_left == 16'd0;
    end
    empty      = q_count == 4'd0 && f_count == n_land;
  end

  // **THE BUFFER'S NEXT ENTRIES, WITH ITS OLDEST DRAINED AND WITHOUT**,
  // each from the clock's registered state and its new words, so that the
  // drain, which waits on this clock's table read and P lookup, only picks.
  logic [DBN-1:0] db_nx_v [2], db_nx_hit [2], db_nx_way [2], db_nx_pend [2], db_nx_young [2];
  logic [SB-1:0]  db_nx_set [2][DBN];
  logic [2:0]     db_nx_lane [2][DBN];
  logic [39:0]    db_nx_word [2][DBN];
  logic [2:0]     db_nx_slot [2][DBN];
  always_comb begin
    for (int d = 0; d < 2; d++) begin
      logic drained;
      logic [DBN-1:0] nv, nhit, nway, npend, nyoung;
      logic [SB-1:0]  nset [DBN];
      logic [2:0]     nlane [DBN];
      logic [39:0]    nword [DBN];
      logic [2:0]     nslot [DBN];
      int n;
      drained = d == 1;
      // The entries that stay, in order.
      n = 0;
      nv = '0; nhit = '0; nway = '0; npend = '0; nyoung = '0;
      for (int k = 0; k < DBN; k++) begin
        nset[k] = '0; nlane[k] = '0; nword[k] = '0; nslot[k] = '0;
      end
      for (int k = 0; k < DBN; k++)
        if (db_v[k] && !(drained && 2'(k) == drain_k)) begin
          nv[n] = 1'b1;
          nset[n] = db_set[k]; nlane[n] = db_lane[k]; nword[n] = db_word[k];
          nslot[n] = db_slot[k];
          nhit[n] = db_hit[k]; nway[n] = db_way[k]; npend[n] = db_pend[k];
          // A word whose way the grant's tag read answers now.
          if (db_pend[k] && lw_v && lw_slot == db_slot[k]) begin
            npend[n] = 1'b0;
            nhit[n]  = w_h0 || w_h1;
            nway[n]  = w_h1;
          end
          if (install && db_set[k] == f_set && nway[n] == victim) nhit[n] = 1'b0;
          n++;
        end
      // A write-back's posted word: the line its table read found.
      if (post_push) begin
        nv[n] = 1'b1; nyoung[n] = 1'b1;
        nset[n] = set_of(post_bus); nlane[n] = post_bus[2:0]; nword[n] = as_held(post_bus, post_word);
        nhit[n] = tl_v && tl_line == post_bus[28:3];
        nway[n] = tl_way;
        if (install && set_of(post_bus) == f_set && tl_way == victim) nhit[n] = 1'b0;
        n++;
      end
      // A write's word fixed.
      if (fix_v) begin
        nv[n] = 1'b1; nyoung[n] = 1'b1;
        // The entry's address: granted in this clock, the start's own.
        nset[n] = set_of((w_push && w_slot == fix_slot) ? w_bus : q_bus[fix_slot]);
        nlane[n] = (w_push && w_slot == fix_slot) ? w_bus[2:0] : q_bus[fix_slot][2:0];
        nword[n] = as_held((w_push && w_slot == fix_slot) ? w_bus : q_bus[fix_slot], fix_word);
        nslot[n] = fix_slot;
        if (w_push && w_slot == fix_slot) begin
          // Granted in this clock: its tag read answers next clock.
          npend[n] = 1'b1;
        end else if (q_hres[fix_slot]) begin
          nhit[n] = q_hit[fix_slot];
          nway[n] = q_way[fix_slot];
        end else if (lw_v && lw_slot == fix_slot) begin
          nhit[n] = w_h0 || w_h1;
          nway[n] = w_h1;
        end else begin
          npend[n] = 1'b1;
        end
        if (install && nset[n] == f_set && nway[n] == victim && !npend[n]) nhit[n] = 1'b0;
        n++;
      end
      db_nx_v[d] = nv; db_nx_hit[d] = nhit; db_nx_way[d] = nway; db_nx_pend[d] = npend; db_nx_young[d] = nyoung;
      for (int k = 0; k < DBN; k++) begin
        db_nx_set[d][k] = nset[k]; db_nx_lane[d][k] = nlane[k]; db_nx_word[d][k] = nword[k]; db_nx_slot[d][k] = nslot[k];
      end
    end
  end

  // ================================================================ the edge

  always_ff @(posedge clk) begin
    if (rst) begin
      q_head <= '0; q_count <= '0; q_wv <= '0; q_hit <= '0; q_hres <= '0;
      f_head <= '0; f_count <= '0; f_arr <= '0; f_err <= '0;
      fs <= F_NONE;
      lp_v <= 1'b0; lw_v <= 1'b0; lt_v <= 1'b0;
      p_hit_land <= 1'b0;
      tst <= T_IDLE;
      tl_v <= 1'b0;
      inst_q <= 1'b0;
      db_v <= '0;
      sweep_left <= '0;
    end else begin
      // --- The landings and the accept.
      f_head  <= f_head + n_land[3:0];
      f_count <= f_count - n_land + {4'd0, mw_taken};
      for (int k = 0; k < FN; k++)
        if (!staying[k]) begin
          f_arr[k] <= 1'b0;
          f_err[k] <= 1'b0;
        end
      if (mw_taken) begin
        f_line[f_tail] <= q_bus[q_head][28:3];
        f_arr[f_tail]  <= 1'b0;
        f_err[f_tail]  <= 1'b0;
      end
      if (b_done) begin
        f_arr[b_id] <= 1'b1;
        f_err[b_id] <= b_err;
      end

      // --- The queue: the accept, the post, the write start, the word.
      if (mw_taken) q_wv[q_head] <= 1'b0;
      q_head  <= q_head + 3'(mw_taken);
      q_count <= queue_n;
      if (post_push) begin
        q_bus[3'(q_head + 3'(q_count))]  <= post_bus;
        q_word[3'(q_head + 3'(q_count))] <= post_word;
        q_wv[3'(q_head + 3'(q_count))]   <= 1'b1;
        q_hres[3'(q_head + 3'(q_count))] <= 1'b1;
        q_hit[3'(q_head + 3'(q_count))]  <= 1'b0;
      end
      if (w_push) begin
        q_bus[w_slot]  <= w_bus;
        q_wv[w_slot]   <= 1'b0;
        q_hres[w_slot] <= 1'b0;
        q_hit[w_slot]  <= 1'b0;
      end
      if (lw_v) begin
        q_hres[lw_slot] <= 1'b1;
        q_hit[lw_slot]  <= w_h0 || w_h1;
        q_way[lw_slot]  <= w_h1;
      end
      if (fix_v) begin
        q_word[fix_slot] <= fix_word;
        q_wv[fix_slot]   <= 1'b1;
      end

      // --- The lookups made now, answered next clock.
      lp_v      <= p_req;
      lp_bus    <= p_bus;
      lw_v      <= w_push;
      lw_bus    <= w_bus;
      lw_slot   <= w_slot;
      lt_v      <= t_issue;
      lt_bus    <= t_start ? t_addr : t_bus;
      lt_with_p <= p_req;
      p_hit_land <= p_hit;
      p_hit_word <= p_lookup_word;

      // --- The table read.
      if (t_start) t_bus <= t_addr;
      if (t_hit) begin
        t_word_q <= t_lookup_word;
        tl_v     <= 1'b1;
        tl_line  <= lt_bus[28:3];
        tl_way   <= t_h1;
      end
      unique case (tst)
        T_LOOK:  tst <= t_cancel ? (t_issue ? T_LOOK : T_RETRY) : t_hit ? T_HIT : T_FILL;
        T_RETRY: tst <= t_issue ? T_LOOK : T_RETRY;
        T_HIT:   tst <= T_IDLE;
        T_FILL:  if (fs == F_LAND) tst <= T_IDLE;
        default: ;
      endcase
      if (t_start) tst <= t_issue ? T_LOOK : T_RETRY;

      // --- The fill.
      unique case (fs)
        F_NONE, F_LAND: if (f_new) fs <= f_issue ? F_DATA : F_WAIT;
                        else fs <= F_NONE;
        F_WAIT: if (f_issue) fs <= F_DATA;
        F_DATA: if (install) fs <= F_LAND;
        default: ;
      endcase
      if (f_new) begin
        f_bus   <= f_bus_now;
        f_table <= t_miss;
      end
      inst_q <= install;
      // The sweep, before a fill installed at this edge, which lands after it.
      if (sweep_go) begin
        sweep_left <= 16'(SWEEP_CLOCKS - 1);
      end else if (sweep_left != 16'd0) begin
        sweep_left <= sweep_left - 16'd1;
      end
      if (install) begin
        last_fill_set <= f_set;
        last_fill_way <= victim;
        f_word        <= rd_data[40*f_bus[2:0] +: 40];
        inst_set_q    <= f_set;
        inst_way_q    <= victim;
        if (f_table) begin
          tl_v    <= 1'b1;
          tl_line <= f_bus[28:3];
          tl_way  <= victim;
        end
        // A queued write or a buffered word whose line it replaces.
        for (int k = 0; k < QN; k++)
          if (set_of(q_bus[k]) == f_set && ((lw_v && lw_slot == 3'(k)) ? w_h1 : q_way[k]) == victim)
            q_hit[k] <= 1'b0;
      end

      // --- The buffer: the word drained, the words made now, each way of
      // the drain made ready and the drain choosing (`db_nx`).
      db_v <= db_nx_v[drain]; db_hit <= db_nx_hit[drain]; db_way <= db_nx_way[drain];
      db_pend <= db_nx_pend[drain]; db_young <= db_nx_young[drain];
      for (int k = 0; k < DBN; k++) begin
        db_set[k] <= db_nx_set[drain][k]; db_lane[k] <= db_nx_lane[drain][k];
        db_word[k] <= db_nx_word[drain][k]; db_slot[k] <= db_nx_slot[drain][k];
      end
    end
  end

  // The fill's queued writes and the queue's slots, the master's line.
  logic unused;
  assign unused = ^{m_rlast, m_rresp, lt_with_p, last_fill_set, last_fill_way};

`ifdef QUUX15_DEBUG
  // A line a clock of the port's events, for a build with `QUUX15_DEBUG`.
  int unsigned dbg_clock = 0;
  always_ff @(posedge clk) begin
    dbg_clock <= rst ? 0 : dbg_clock + 1;
    if (!rst && (p_req || w_push || fix_v || post_push || lp_v || lw_v || lt_v || drain || install || mw_taken || n_land != 0))
      $display("%0d port: p_req %b %h w_push %b %h slot %0d fix %b slot %0d %h | lp %b hit %b%b lw %b slot %0d hit %b%b | drain %b set %h way %b lane %0d hit %b | inst %b | acc %b land %0d | db_v %b pend %b",
               dbg_clock + 1, p_req, p_bus, w_push, w_bus, w_slot, fix_v, fix_slot, fix_word, lp_v, p_h1, p_h0,
               lw_v, lw_slot, w_h1, w_h0, drain, db_set[0], db_way[0], db_lane[0], db_hit[0], install, mw_taken,
               n_land, db_v, db_pend);
  end
`endif

`ifndef SYNTHESIS
  // What the port is built never to see.
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (p_req && (lp_v || lt_v || lw_v) && f_new)
        $error("quux15_port: a processor read in the clock after a lookup that missed");
      if (w_req && f_new)
        $error("quux15_port: a write start in the clock a lookup missed");
      if (p_req && p_busy)
        $error("quux15_port: a processor read while a fill is in flight");
      if (post_push && fix_v && db_v[DBN-1])
        $error("quux15_port: the lines' write buffer overflows");
      if (db_v == '1 && (post_push || fix_v))
        $error("quux15_port: the lines' write buffer overflows");
      if (post_push && !(tl_v && tl_line == post_bus[28:3]))
        $error("quux15_port: a posted word whose line no table read found");
    end
  end
`endif

endmodule

`default_nettype wire
