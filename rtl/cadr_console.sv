// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console: the sixteen diagnostic registers on `M_AXI_GP1`, so that a
// program in Linux can halt the machine, read its state and start it again.
//
// **WHAT A CONSOLE IS.**  muir's own is CC, the program `examples/cc.rs`
// runs on one CADR to debug another over the debug cable, and its whole
// vocabulary is `crate::spy`: sixteen registers at Unibus `0o766000`, three
// of them written and all sixteen read.  `Engine::spy_read` answers a read
// and `Machine::spy_write` takes a write --- "from a Unibus cycle **or from
// a console with no bus at all**", `src/spy.rs`'s own words.  This module is
// the second of those: a master on the diagnostic bus with nothing between
// it and the register block but the arbiter.
//
// `rtl/cadr_spy_registers.sv` is the register block and it is not touched
// here.  Its Unibus timing --- `-UB SSYN` at `DIAGNOSTIC_NS` after the
// strobe, the write pulse's leading edge `REGISTER_PULSE_NS` before the
// register loads, and the rule that a write lands at the machine's next look
// rather than at the strobe --- is the board's, is checked against muir by
// `build/machine.pass`, and is exactly what this module drives.  A console
// that reached around it and wrote the registers directly would be a second
// description of the same thing, and the two would drift.
//
// **THE QUESTION THIS EXISTS TO ANSWER.**  On the board the machine loads
// its microcode from its pack, does a fixed amount of disk work and goes
// quiet, and nothing built could say whether it is waiting or has halted.
// `FLAG-1` says: bit 8 is `SRUN`, bit 15 is `-WAIT`, bit 10 is `ERR`, and
// register 5 is `PC`.  `cc.rs` reads exactly that --- "`if b.spy_read(
// spy::FLAG_1) & 0x100 != 0 { "running" } else { "halted" }`".
//
// **WHAT LINUX SEES**, thirty-two words at `REG_BASE`, two pages of sixteen.
// The window is 128 bytes; `M_AXI_GP1` decodes `0x8000_0000` upward in the
// Zynq-7000 address map and this sits at the bottom of it.
//
//   page 0, `REG_BASE + 0x00`, the console's own, all read-only:
//
//     0  IDENT    reads `IDENT`, "CONS", so that the first read over GP1 can
//                 tell this face from a bus that answers zeros or ones
//     1  STAT     bit 0  busy      a diagnostic cycle is in flight
//                 bit 1  gnt       the diagnostic bus is the console's, live
//                 bit 2  answered  the last cycle got `-UB SSYN`
//                 bit 3  lost      some cycle since reset did not: sticky
//     2  CYCLES   microcycles the machine has retired since reset, bits 31:0.
//                 This is `Machine::cycles`, which `cc.rs` prints of the
//                 machine it is debugging, and it is what says the machine is
//                 running without stopping it to ask
//     3  CYCLESH  bits 63:32, **latched when CYCLES was read**: see below
//     4  TICKS    200 MHz ticks since reset, bits 31:0.  `Rtl::ns()` divided
//                 by five --- the machine's own time, which runs whether or
//                 not the machine does, so CYCLES against TICKS is a rate
//     5  TICKSH   bits 63:32, latched when TICKS was read
//     6-15        read `UNMAPPED`; writes dropped
//
//   page 1, `REG_BASE + 0x40`, the sixteen diagnostic registers, word k
//   being `EADR` k:
//
//     read   runs a diagnostic READ cycle and returns `SPY<15:0>` in bits
//            15:0 with bits 31:16 zero, or bit 16 set and nothing else
//            meaning the cycle was not answered
//     write  runs a diagnostic WRITE cycle with `SPY<15:0>` from bits 15:0
//
//   So `spy_read(eadr)` is a load from `REG_BASE + 0x40 + 4*eadr` and
//   `spy_write(eadr, v)` a store to it, and the console program's vocabulary
//   is muir's with no translation in between.  Register 3 has no read select
//   on the board and reads the open bus, all ones; that is a fact about the
//   machine and it comes back through here unchanged.
//
// **THE HIGH HALF IS LATCHED BY THE LOW HALF'S READ, and that is not a
// convenience.**  A 64-bit counter read as two 32-bit loads is wrong across
// a carry: the low half wraps between the two loads and the pair names a
// time 4,294,967,296 ticks in the future.  The rule is read CYCLES then
// CYCLESH, TICKS then TICKSH; the low read latches the high half beside it,
// so the pair is one instant.  A program that reads the high word without
// the low one gets whatever the last low read latched, which is why the
// order is the rule and not the advice.
//
// **EVERY ADDRESS ON GP1 IS ANSWERED, and with OKAY.**  A read nothing
// answers on a GP port does not fault the Arm, it hangs both cores at one PC
// each --- measured on the board, and `rtl/cadr_gp0_default.sv` says so at
// length.  So a read outside the thirty-two words completes with `UNMAPPED`
// and a write outside them completes and is dropped, in the window and out
// of it, over the whole gigabyte GP1 decodes.  **OKAY and not SLVERR**, which
// is where this differs from `rtl/cadr_disk_pack.sv`'s face: an error
// response to a Cortex-A9's posted write arrives as an imprecise external
// abort the kernel cannot attribute to a process, and a constant a program
// can recognise is the safer failure.  The pack side answers SLVERR outside
// its window because a board with GP0 and no pack side has
// `cadr_gp0_default.sv` under it to answer instead; GP1 has only this.
//
// `UNMAPPED` is the complement of `IDENT` and neither zero nor all ones ---
// zero is what a dead bus reads and all ones is what an undriven one reads,
// measured on this board's own EMIO pins, and **a value that means nothing
// must not be a value the instrument can mean.**
//
// **WHY GP1 AND NOT GP0, WHICH IS WHERE `README.md` PUTS THE CONSOLE.**  A
// slave that owns a GP port must answer the whole of it, and GP0 is already
// answered end to end --- `rtl/cadr_disk_pack.sv` inside its window and
// SLVERR outside it, anywhere in the port's gigabyte, or
// `rtl/cadr_gp0_default.sv` on a board without the pack side.  So a console
// on GP0 needs an address decode and a mux in front of that face, and a
// console on GP1 needs one `PCW_*` property and changes `ps7_init` by
// nothing --- measured, op for op across all three silicon revisions.
// `README.md` puts the debug cable on GP1 and its argument for keeping the
// two apart is a good one; `REG_BASE` is a parameter and moving this back is
// one line at the instantiation plus that decode.  **The decision is not
// this module's** and `docs/console.md` states both sides with the numbers.
//
// **THE CONSOLE IS THE SECOND MASTER ON THE DIAGNOSTIC BUS**, and it asks.
// The first is the CADR itself: `0o766000` is Unibus space, the boot PROM
// writes the mode register there, and `cadr_busint_xbus.sv` runs that cycle.
// So `dbg_req` goes up and the cycle waits for `dbg_gnt`.  The arbiter is
// outside this module for two reasons: what it has to see --- whether the
// processor's own Unibus cycle is running --- belongs to
// `cadr_memory_path.sv`, and what it holds has to be inside `cadr_machine`
// for `cadr_machine.xdc` to reach.  It is `rtl/cadr_console_bus.sv`, one
// module instantiated by that file and by `tb/cadr_console_harness.sv`, so
// that the check holds the thing on the board and not a copy of it.
//
// **AND THE CONSOLE'S HOLD ON THAT BUS IS BOUNDED, because the processor's
// is not.**  A CADR bus cycle that is not answered ends on the NXM timer at
// 4,250 ns from the gated oscillator's first rise.  This module holds the
// diagnostic bus for `DIAGNOSTIC_NS` plus the drop, which is 260 ns --- so a
// Unibus cycle that has to wait for the console behind it waits a sixteenth
// of its own timeout and cannot become an NXM.  That is the same argument
// the disk channel's per-word arbiter is held to, one bus along.
//
// **AND THE AXI TRANSACTION IS BOUNDED WHATEVER THE BUS DOES.**  `LOST_T`
// ticks after the request the engine gives up, drops `dbg_req`, sets STAT's
// `lost` and answers the read with bit 16 set.  A grant that never comes, or
// a register block that never answers, therefore costs the Arm `LOST_T`
// ticks and not the machine's uptime.  A bound nothing exercises is not a
// bound: `tb/cadr_console_tb.cpp` holds the grant off and requires the read
// to complete and to say it was lost.
//
// **WHAT IS NOT HERE.**  `STEP`, `NOP11`, `IDEBUG`, the debug IR, `LPC.HOLD`
// and `OPCCLK` --- the clock control register's bits 4:1 and the whole OPC
// control register --- are *written* through here, because a write of the
// CLK register is a write of the CLK register; but the board's own
// single-step is `SSTEP` and `SSDONE`, two flip flops of the 74S174 at OLORD1
// 1A10, and they are in `cadr_microcycle.sv`, which says at its port list
// that "the fabric has no console yet".  `cadr_spy_registers.sv` takes bit 0
// of a CLK write and drops the rest.  So `HALT` and `START` --- bit 0, `RUN`
// --- are the whole of what a console can make this machine do today, and
// `docs/console.md` names the two hunks that would add the rest.  Examining
// and depositing main memory is CC's `CC-EXECUTE-R`, which loads a
// microinstruction into the debug IR and clocks it: same two hunks.
//
// This module does not know any of that.  It carries `SPY<15:0>` both ways
// and the register block decides.

`default_nettype none

module cadr_console #(
    // Where the thirty-two words sit.  `0x8000_0000` is the first address
    // `M_AXI_GP1` decodes to the fabric in the Zynq-7000 PS address map,
    // as `0x4000_0000` is `M_AXI_GP0`'s.
    parameter logic [31:0] REG_BASE = 32'h8000_0000,
    // "CONS".
    parameter logic [31:0] IDENT    = 32'h434F_4E53,
    // What an address in neither page reads: the complement of IDENT.
    parameter logic [31:0] UNMAPPED = ~IDENT,
    // How long a diagnostic cycle may take before the engine gives up, in
    // 200 MHz ticks.  The cycle itself is `DIAGNOSTIC_NS` = 250 ns = 50
    // ticks; the rest is the wait for the grant, and the processor's own
    // Unibus cycle in front of it is bounded by its NXM timer at 4,250 ns.
    // 4,096 ticks is 20.48 us, four NXM timeouts, and it is a bound on how
    // long the Arm may stall and nothing else.
    parameter int unsigned LOST_T   = 4096
) (
    input  var logic        clk,          // 200 MHz, one tick = 5 ns
    input  var logic        rst,

    // --- `M_AXI_GP1`, on which the processing system is the master.  AXI3,
    // --- 32 bits, 12-bit IDs, one write and one read in flight at once.
    input  var logic [31:0] s_awaddr,
    input  var logic [3:0]  s_awlen,
    input  var logic [11:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [11:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [31:0] s_araddr,
    input  var logic [3:0]  s_arlen,
    input  var logic [11:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [11:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- the diagnostic bus, as a second Unibus master drives it.  The
    // --- names and the polarities are `cadr_spy_registers.sv`'s ports.
    output var logic        dbg_req,      // the console wants the bus
    input  var logic        dbg_gnt,      // and has it
    output var logic        ub_msyn,      // -UB MSYN, this master's strobe
    output var logic        ub_write,
    output var logic [17:0] ub_addr,
    output var logic [15:0] ub_wdata,     // SPY<15:0> out
    input  var logic        ub_ssyn,      // -UB SSYN: the block answers
    // `SPY<15:0>` back.  **It arrives already registered**, and by design:
    // `rtl/cadr_console_bus.sv` captures the sixteen-way diagnostic mux at
    // the microcycle boundary inside `cadr_machine`, where
    // `rtl/cadr_machine.xdc` can relax it.  Captured here instead the board
    // read -12.837 ns; that module's header has the whole of it.  What it
    // costs is that this word is the machine as of the last boundary, which
    // is exact on a halted machine and is muir's own read-phase semantics on
    // a running one.
    input  var logic [15:0] ub_rdata,

    // --- the machine's own beat: one tick high for every microcycle the
    // --- processor retired, `cadr_microcycle.sv`'s `clock_edge`.
    input  var logic        clock_edge
);

  // spy::BASE, and "the EADR<3:0> lines just follow the Unibus address
  // <4:1>", so register k is at BASE + 2k.
  localparam logic [17:0] SPY_BASE = 18'o766000;

  // ------------------------------------------------------------------------
  // The machine's beat
  // ------------------------------------------------------------------------

  logic [63:0] cycles, ticks;

  always_ff @(posedge clk) begin
    if (rst) begin
      cycles <= 64'd0;
      ticks  <= 64'd0;
    end else begin
      ticks <= ticks + 64'd1;
      if (clock_edge) cycles <= cycles + 64'd1;
    end
  end

  // ------------------------------------------------------------------------
  // The GP1 face's state, declared before the engine that reads it
  // ------------------------------------------------------------------------

  typedef enum logic [2:0] { W_ADDR, W_DATA, W_CYCLE, W_RESP } wstate_e;
  typedef enum logic [2:0] { R_ADDR, R_START, R_CYCLE, R_PREP, R_PREP2,
                             R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;

  logic [31:0] w_at, r_at;      // the beat's address, walked up a word a beat
  logic [11:0] w_id, r_id;
  logic [3:0]  r_left;          // beats still owed on the read
  logic        w_last_q;        // the beat now in hand was WLAST

  // Whether the beat's address is one of the thirty-two words, and which.
  // Two pages of sixteen: bit 4 of the index is the page, bits 3:0 are
  // `EADR<3:0>` on page 1.
  function automatic logic in_window(input logic [31:7] page);
    return page == REG_BASE[31:7];
  endfunction
  logic        w_in, r_in;
  logic [4:0]  w_idx, r_idx;
  logic [31:0] w_next;
  assign w_next = w_at + 32'd4;
  assign r_in   = in_window(r_at[31:7]);
  assign w_idx  = w_at[6:2];
  assign r_idx  = r_at[6:2];

  // The low sixteen bits of a write beat, unstrobed lanes reading zero, as
  // `cadr_disk_pack.sv` merges a beat against zero for its CTL word: a
  // `writeb` of the low byte is then the same write as a `writel` of the
  // same value, and a lane nobody strobed carries nothing of its own.
  logic [15:0] w_spy;
  assign w_spy = {s_wstrb[1] ? s_wdata[15:8] : 8'd0,
                  s_wstrb[0] ? s_wdata[7:0]  : 8'd0};

  // **THE WRITE BEAT'S REGISTER AND WORD ARE LATCHED AT THE BEAT**, because
  // `w_at` walks up in the same tick the beat lands: the cycle that follows
  // would otherwise be aimed at the register after the one written.
  logic [3:0]  w_eadr_q;
  logic [15:0] w_spy_q;

  // ------------------------------------------------------------------------
  // The diagnostic engine: one Unibus cycle at a time
  // ------------------------------------------------------------------------
  //
  // The two halves of AXI are independent and the processing system's
  // interconnect will drive both at once, so the read side and the write
  // side both ask this and it serves one.  **The write side wins a tie**,
  // arbitrarily and stated: a program that reads and writes the same
  // register from two threads has a race of its own making, and one rule is
  // one rule.

  typedef enum logic [2:0] { E_IDLE, E_GRANT, E_ACTIVE, E_DROP } estate_e;
  estate_e est;

  logic        eng_w_req, eng_r_req;   // the two askers, held while waiting
  logic        eng_for_w;              // whose cycle is running
  logic        eng_done;               // one tick, the cycle is over
  logic        eng_lost;               // and it was not answered
  logic [15:0] eng_rdata;
  logic [3:0]  eng_eadr;
  logic        eng_write;
  logic [15:0] eng_wdata;
  logic [12:0] waited;                 // ticks since the request

  assign eng_w_req = (wst == W_CYCLE);
  assign eng_r_req = (rst_r == R_CYCLE);

  assign dbg_req  = (est != E_IDLE);
  assign ub_msyn  = (est == E_ACTIVE);
  assign ub_write = eng_write;
  assign ub_addr  = SPY_BASE | {13'd0, eng_eadr, 1'b0};
  assign ub_wdata = eng_wdata;

  logic answered, lost_ever;

  always_ff @(posedge clk) begin
    if (rst) begin
      est       <= E_IDLE;
      eng_for_w <= 1'b0;
      eng_done  <= 1'b0;
      eng_lost  <= 1'b0;
      eng_rdata <= 16'd0;
      eng_eadr  <= 4'd0;
      eng_write <= 1'b0;
      eng_wdata <= 16'd0;
      waited    <= 13'd0;
      answered  <= 1'b0;
      lost_ever <= 1'b0;
    end else begin
      eng_done <= 1'b0;
      unique case (est)
        // `!eng_done` is what keeps a cycle from being started twice.
        // `eng_done` stands for the tick in which the asking side leaves its
        // wait state, and its request is a level off that state, so without
        // this the engine would see the request still up and run the cycle
        // again --- once for every register a program touched.
        E_IDLE: begin
          waited <= 13'd0;
          if (!eng_done && (eng_w_req || eng_r_req)) begin
            eng_for_w <= eng_w_req;
            eng_eadr  <= eng_w_req ? w_eadr_q : r_idx[3:0];
            eng_write <= eng_w_req;
            eng_wdata <= w_spy_q;
            est       <= E_GRANT;
          end
        end
        // `dbg_req` is up from here on.  The arbiter outside gives the bus
        // when the processor's own Unibus cycle is not running and holds the
        // grant until the request drops, so the cycle below cannot have the
        // bus taken away under it.
        E_GRANT: begin
          waited <= waited + 13'd1;
          if (dbg_gnt) begin
            waited <= 13'd0;
            est    <= E_ACTIVE;
          end else if (waited == 13'(LOST_T - 1)) begin
            eng_lost <= 1'b1;
            est      <= E_DROP;
          end
        end
        // -UB MSYN is up.  `cadr_spy_registers.sv` answers with -UB SSYN
        // `DIAGNOSTIC_NS` after the strobe, having taken a write at
        // `REGISTER_STROBE_NS` and put the mode register's two pulses out at
        // `REGISTER_PULSE_NS` on the way; the word on `SPY<15:0>` is the
        // processor's and stands while the block is selected.
        E_ACTIVE: begin
          waited <= waited + 13'd1;
          if (ub_ssyn) begin
            eng_rdata <= ub_rdata;
            eng_lost  <= 1'b0;
            est       <= E_DROP;
          end else if (waited == 13'(LOST_T - 1)) begin
            eng_lost <= 1'b1;
            est      <= E_DROP;
          end
        end
        // MSYN is down; the block clears its own -UB SSYN the tick after,
        // and the bus is given back only once it has.  Dropping the request
        // while SSYN is still up would hand the next master a bus that is
        // already answering.
        E_DROP: if (!ub_ssyn) begin
          eng_done <= 1'b1;
          answered <= !eng_lost;
          if (eng_lost) lost_ever <= 1'b1;
          est      <= E_IDLE;
        end
        default: est <= E_IDLE;
      endcase
    end
  end

  logic eng_done_w, eng_done_r;
  assign eng_done_w = eng_done && eng_for_w;
  assign eng_done_r = eng_done && !eng_for_w;

  // ------------------------------------------------------------------------
  // The GP1 face
  // ------------------------------------------------------------------------

  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bresp   = 2'b00;   // OKAY, everywhere: see the header
  assign s_bid     = w_id;

  // A write beat lands this tick.
  logic w_beat;
  assign w_beat = s_wvalid && s_wready;

  // **THE WORD AND THE RESPONSE ARE REGISTERS, MADE THE TICK BEFORE RVALID**,
  // for the reason `cadr_disk_pack.sv` gives at the same place: driven
  // straight off `r_at`, the window compare and the mux reached the PS7's own
  // RDATA pins four logic levels late on the DDR=1 board.  `R_START`
  // registers the compare and the index, `R_PREP2` the word.
  logic [31:0] rdata_q;
  logic        r_in_q;
  logic [4:0]  r_idx_q;
  logic [15:0] r_spy;      // what the cycle brought back
  logic        r_lost;
  assign s_arready = (rst_r == R_ADDR);
  assign s_rvalid  = (rst_r == R_DATA);
  assign s_rlast   = (r_left == 4'd0);
  assign s_rresp   = 2'b00;   // OKAY, everywhere
  assign s_rdata   = rdata_q;
  assign s_rid     = r_id;

  // A page-0 read is a register of this module; a page-1 read is what the
  // cycle brought back, with bit 16 up if it brought nothing.
  logic [31:0] stat_word, r_word;
  assign stat_word = {28'd0, lost_ever, answered, dbg_gnt, (est != E_IDLE)};
  logic [31:0] cycles_hi_q, ticks_hi_q;
  always_comb begin
    if (!r_in_q) r_word = UNMAPPED;
    else if (r_idx_q[4]) r_word = {15'd0, r_lost, r_spy};
    else begin
      unique case (r_idx_q[3:0])
        4'd0:    r_word = IDENT;
        4'd1:    r_word = stat_word;
        4'd2:    r_word = cycles[31:0];
        4'd3:    r_word = cycles_hi_q;
        4'd4:    r_word = ticks[31:0];
        4'd5:    r_word = ticks_hi_q;
        default: r_word = UNMAPPED;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wst         <= W_ADDR;
      rst_r       <= R_ADDR;
      w_at        <= 32'd0;
      r_at        <= 32'd0;
      w_id        <= 12'd0;
      r_id        <= 12'd0;
      r_left      <= 4'd0;
      w_in        <= 1'b0;
      w_last_q    <= 1'b0;
      w_eadr_q    <= 4'd0;
      w_spy_q     <= 16'd0;
      rdata_q     <= 32'd0;
      r_in_q      <= 1'b0;
      r_idx_q     <= 5'd0;
      r_spy       <= 16'd0;
      r_lost      <= 1'b0;
      cycles_hi_q <= 32'd0;
      ticks_hi_q  <= 32'd0;
    end else begin
      // --- writes
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_at <= s_awaddr;
          w_in <= in_window(s_awaddr[31:7]);
          w_id <= s_awid;
          wst  <= W_DATA;
        end
        W_DATA: if (w_beat) begin
          w_last_q <= s_wlast;
          w_eadr_q <= w_idx[3:0];
          w_spy_q  <= w_spy;
          w_at     <= w_next;
          w_in     <= in_window(w_next[31:7]);
          // Page 1 is a diagnostic write and takes a bus cycle.  Page 0 is
          // read-only and outside the window is dropped; both complete with
          // OKAY and nothing else happens.
          if (w_in && w_idx[4]) wst <= W_CYCLE;
          else if (s_wlast) wst <= W_RESP;
        end
        W_CYCLE: if (eng_done_w) wst <= w_last_q ? W_RESP : W_DATA;
        W_RESP: if (s_bready) wst <= W_ADDR;
        default: wst <= W_ADDR;
      endcase

      // --- reads
      unique case (rst_r)
        R_ADDR: if (s_arvalid) begin
          r_at   <= s_araddr;
          r_id   <= s_arid;
          r_left <= s_arlen;
          rst_r  <= R_START;
        end
        // Which word this beat names, and whether it needs the machine
        // asked.  **The high half of each counter is latched here**, by the
        // read of the low half, so that the pair a program reads names one
        // instant across the carry.
        R_START: begin
          r_in_q  <= r_in;
          r_idx_q <= r_idx;
          if (r_in && !r_idx[4] && r_idx[3:0] == 4'd2) cycles_hi_q <= cycles[63:32];
          if (r_in && !r_idx[4] && r_idx[3:0] == 4'd4) ticks_hi_q  <= ticks[63:32];
          rst_r <= (r_in && r_idx[4]) ? R_CYCLE : R_PREP;
        end
        R_CYCLE: if (eng_done_r) begin
          r_spy  <= eng_rdata;
          r_lost <= eng_lost;
          rst_r  <= R_PREP;
        end
        R_PREP: rst_r <= R_PREP2;
        R_PREP2: begin
          rdata_q <= r_word;
          rst_r   <= R_DATA;
        end
        R_DATA: if (s_rready) begin
          r_at <= r_at + 32'd4;
          if (r_left == 4'd0) rst_r <= R_ADDR;
          else begin
            r_left <= r_left - 4'd1;
            rst_r  <= R_START;
          end
        end
        default: rst_r <= R_ADDR;
      endcase
    end
  end

  // The AXI3 length on the write channel is not read: a register access is
  // walked a beat at a time until WLAST says it is over, and one write is in
  // flight at a time so the response's ID is the address's.  The strobes on
  // the top two lanes name bytes no diagnostic register has.
  logic unused_s;
  assign unused_s = ^{s_awlen, s_wstrb[3:2], s_wdata[31:16]};

endmodule

`default_nettype wire
