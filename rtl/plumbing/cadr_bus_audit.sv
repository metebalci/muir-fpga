// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE FABRIC-SIDE AUDIT OF THE MEMORY PORT: one transaction per bus cycle, in
// the direction the bus cycle names, and none anywhere else --- watched on the
// board, for as long as the board runs, and readable hours after it has
// stopped.
//
// WHY THIS EXISTS, and it is one specific board bug.  CLAUDE.md's chain, every
// link measured: the board halts in `PDL-BUFFER-REFILL` because a word in
// MIT's page hash table is the faulting virtual address rather than a page
// table word; the memory data register is exonerated --- the composed machine
// cannot leave MD stale across a read, 59,358 strobes with MBUSY down at none
// of them --- so main memory already held that word, so the corruption is a
// WRITE THAT SHOULD NOT HAVE HAPPENED.  And `rtl/machine/cadr_microcycle.sv`
// loads `wdata` from MD at MEMGO REGARDLESS OF DIRECTION, measured on every
// one of the boot PROM's 256 reads, so the whole of MD stands on `mem_wdata`
// during a read: one unwanted write replaces a memory word with MD, at the
// read's own address, and neither the machine nor the microcode can tell
// afterwards.
//
// `tb/cadr_bus_audit_tb.cpp` holds exactly this property in simulation and is
// green.  What it cannot do is the reason this module exists: the boot PROM is
// the only program `cadr_machine` can run under Verilator, it makes 512
// main-memory cycles, and the board's event is one in about a hundred and
// seventy-six million microcycles.  A green simulation says the property holds
// for the one program we can run; only fabric can say it holds for the program
// the board runs.
//
// WHY NOT THE INSTRUMENTS THAT ALREADY EXIST.
//
//   `rtl/plumbing/cadr_mem_count.sv` counts four totals into fifteen bits each
//   and SATURATES at 32,767.  That is right for what it is for --- step four's
//   512 cycles, frozen from 118 ms --- and it is blind to this, with a number
//   on it: `build/rtl_sys.golden` carries 193,851 bus cycles in 2,800,000
//   microcycles of a System 100 band, so a counter of them passes 32,767 at
//   about microcycle 473,000.  The board reached 176,119,628 before it halted.
//   THE TALLY IS THEREFORE SATURATED FOR ROUGHLY 99.7% OF THE RUN THE BUG
//   HAPPENED IN, and a discrepancy of one in a hundred million is invisible in
//   a saturated total anyway.  THE COUNTER HERE COUNTS FAULTS AND NOT
//   TRANSACTIONS, which is what makes fifteen bits enormous headroom instead of
//   none: any reading but zero is the finding.
//
//   The probe fills from the first microcycle after reset and freezes at
//   1,024 samples, and the machine's first memory cycle is at microcycle
//   536,303.  It cannot reach a memory cycle at all, by construction.
//
//   A lamp is not enough because the machine halts long after the event, and
//   because a lamp can say that something happened and not what or where.
//
// WHERE IT REPORTS: the console's readout window, which is already the way
// anything inside `cadr_machine` is read on a halted board, over `M_AXI_GP1`,
// by `cadr-readout`, from anywhere, with nobody at the board.  This module
// presents a small table of eight 48-bit words, addressed and registered
// exactly as the readout's own memories are, and `cadr_machine` joins it into
// the window at a selector of its own.
//
// **AND A VALUE THAT MEANS NOTHING MUST NOT BE A VALUE THE INSTRUMENT CAN
// MEAN**, which is this repository's oldest standing rule and was learned
// twice by measurement --- undriven EMIO reading all ones like four saturated
// counters, and never-written DDR reading as bands of zeros and ones.  Three
// independent things separate "no faults" from "no instrument" here:
//
//   the readout window's own default arm answers `48'hA5A5_5A5A_A5A5` for a
//   selector the fabric does not map, so a bitstream built WITHOUT this module
//   reads that and not zero;
//
//   the window's echo carries back the address the word was read at, and
//   `cadr-readout` already refuses a word whose echo is not what it asked;
//
//   and every word this module produces carries `16'hB05A` in its top sixteen
//   bits.  So a reading of all zeros, a reading of all ones, and a reading of
//   `A5A5...` are each impossible here, and "0 faults" is a word that says who
//   wrote it.
//
// IT IS READ-ONLY AND NOTHING IT PRODUCES REACHES THE DATAPATH.  That is what
// makes it safe to leave in the board for good, and it is worth stating rather
// than noticing: an instrument that can change what it measures is not one.
//
// WHAT IT COSTS, MEASURED AND NOT ESTIMATED.  Out of context on
// `xc7z020clg400-1` under Vivado 2026.1, this module alone synthesises to
// **95 slice LUTs (0.18%), 347 slice registers (0.33%) and 16 carry cells**
// --- 103 LUT cells before packing --- no DSP and no block RAM, and closes at
// the 10 ns tick with **+5.790 ns**, worst path
// `req_q_reg/C -> first_addr_reg[0]/CE`, which is the fault term
// into the capture registers' clock enable.  That figure is post-synthesis,
// unplaced and out of context, and this file says so rather than quoting it as
// a board number: what the board costs is not a number until the module is
// instantiated and the paragraph below has been answered with a report.
//
// **WHICH TIMING SET ITS REGISTERS FALL INTO, WHICH MUST BE SETTLED BEFORE ANY
// SLACK FIGURE IS QUOTED FOR IT.**  `rtl/plumbing/xilinx7/cadr_machine.xdc`
// defines `slow` as every register under `cadr_machine` less a name list, so a
// module instantiated there is relaxed to fifteen ticks by DEFAULT and nothing
// says so --- that is the trap `cadr_disk_controller.sv` fell into, where
// 3,904 of 4,000 paths carried the exception and three slices' fit figures
// were figures for a disk nobody was timing.
//
// The right answer here is not one set for the whole module.  The edge
// detectors and the per-request and per-cycle state are read EVERY TICK and a
// relaxed edge detector misses an edge or invents one, which is an instrument
// that lies; the capture registers are written once and read once, by a
// console, on a halted machine.  So the clause wanted is the shape the disk
// and the display already have --- everything under the instance FAST, with
// the capture and the readout word added back to `slow`:
//
//     (NAME !~ *audit/* || NAME =~ *audit/first_* || \
//                          NAME =~ *audit/micro_reg* || \
//                          NAME =~ *audit/word_reg*)
//
// with `report_exceptions` read afterwards to confirm the count moved by what
// it should.  The measured worst path above is the `fast -> slow` arc into a
// capture register's CE, which that clause times at one tick, which is what it
// must be: a capture whose enable is relaxed can fire at a tick where its own
// data has not settled.
//
// And the clause names the INSTANCE and not the module, so the instantiation is
// `cadr_bus_audit audit (...)` and a rename of it silently empties the clause
// --- the `foreach` trap in a new place, and the tell is the same one:
// `report_exceptions` counting fewer than were written.
//
// WHAT THE OWNER BUNDLE IS, AND WHY IT IS AN INPUT RATHER THAN DECODED HERE.
// CLAUDE.md's shadow-memory rule says a check keyed by the thing under test
// moves with the bug, and the thing under test here is the path from the bus
// cycle to the AXI port.  So `cycle`, `cycle_write`, `cycle_memory` and
// `cycle_phys` must come from the MASTER'S OWN upstream signals --- MBUSY,
// the 74S175 at 1C23, and the held decode for the processor; the channel's own
// request, direction and decode for the disk --- and never from `bus_rq`,
// `bus_write` and `bus_sel`, which are the bridge's inputs and would move with
// a fault in the mux that makes them.  The instantiation owns that choice and
// the module says so here because a later reader cannot see it from inside.

`default_nettype none

module cadr_bus_audit (
    input  var logic        clk,
    input  var logic        rst,

    // --- THE BUS CYCLE, from whichever master owns the bus.  See the header:
    // these are the master's own signals and not the bridge's.
    input  var logic        cycle,         // a bus cycle is open
    input  var logic        cycle_write,   // its direction, held for the whole of it
    input  var logic        cycle_memory,  // the held decode says memory answers it
    input  var logic [21:0] cycle_phys,    // the address it is asking about

    // --- THE MEMORY PORT, which is what is being audited.
    input  var logic        mem_req,
    input  var logic        mem_write,
    input  var logic        mem_done,
    input  var logic [31:0] mem_addr,
    input  var logic [31:0] mem_wdata,

    // --- THE COORDINATES A FAULT IS NAMED BY.  The microcycle is the one
    // this project's whole board narrative is written in, so it is counted
    // here rather than left to be worked out from anything else.
    input  var logic        boundary,      // the microcycle boundary
    input  var logic [31:0] vma,
    input  var logic [31:0] md,
    input  var logic [13:0] pc,
    input  var logic [13:0] opc,

    // --- THE READOUT.  `sel` names a word and `word` is that word one tick
    // later, which is the discipline `cadr_microcycle.sv`'s readout memories
    // keep and the reason this is three wires and not a bus.
    input  var logic [2:0]  sel,
    output var logic [47:0] word
);

  // WHO WROTE THE WORD.  In the top sixteen bits of every one of them: the
  // halves differ, neither is a rotation of the other, and it is neither the
  // readout window's `A5A5` for an unmapped selector nor anything an undriven
  // or saturated path can produce.
  localparam logic [15:0] MARK = 16'hB05A;

  // The clauses, in the order the header of `tb/cadr_bus_audit_tb.cpp` gives
  // them.  ZERO IS "NOTHING WAS LATCHED" and there is no separate valid bit:
  // a clause of zero in the readout is the whole of the statement that no
  // fault was seen, so the two cannot disagree with each other.
  localparam logic [2:0] C_NONE       = 3'd0;
  localparam logic [2:0] C_TWICE      = 3'd1;  // one request, two answers
  localparam logic [2:0] C_TWO_REQS   = 3'd2;  // one bus cycle, two requests
  localparam logic [2:0] C_DIRECTION  = 3'd3;  // not the direction the cycle names
  localparam logic [2:0] C_NO_CYCLE   = 3'd4;  // a request with no cycle open
  localparam logic [2:0] C_NOT_MEMORY = 3'd5;  // a cycle the decode says is not memory's
  // AND THE ONE THAT REACHES PAST `cadr_machine`.  This module sits inside the
  // machine and the AXI adapter sits outside it, in `cadr_arty.sv`'s `g_ddr`,
  // so the address channels are not visible here and an adapter that issued a
  // transaction of its own would be invisible at `mem_req` --- which is
  // exactly what `mutations/list.txt`'s `the-read-is-issued-a-second-time`
  // does.  It is not invisible at `mem_done`: the adapter holds its answer
  // until the bridge lets go, so a rise of `mem_done` with no request standing
  // cannot happen in a correct design and IS a transaction the adapter ran by
  // itself.  One clause, no new ports, and it is the difference between an
  // instrument that watches the bridge and one that watches the port.
  localparam logic [2:0] C_LOOSE_ANS  = 3'd6;  // an answer with no request standing

  // --------------------------------------------------------- what is watched
  //
  // THE THREE EDGE DETECTORS ARE THE ONLY THING HERE THAT IS READ EVERY TICK,
  // and that is a constraint statement rather than a comment.
  // `rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes every register in
  // `cadr_machine` that is not named fast, so these three land in the relaxed
  // set by default --- and a relaxed edge detector misses an edge or invents
  // one, which is an instrument that lies.  They must be named FAST there in
  // the same commit that instantiates this module.  Everything else here is
  // written once and read once, by a console, on a halted machine, so the
  // relaxed set is where it belongs.
  logic req_q, done_q, cycle_q;
  logic req_rise, done_rise, cycle_rise, cycle_fall;
  assign req_rise   = mem_req && !req_q;
  assign done_rise  = mem_done && !done_q;
  assign cycle_rise = cycle && !cycle_q;
  assign cycle_fall = !cycle && cycle_q;

  // The state of the request now open and of the cycle now open.  Two bits
  // each and saturating: what matters is "more than one", and a counter that
  // wrapped back to one would be the false negative this whole module is
  // about.
  logic       in_req;
  logic [1:0] answers, reqs;
  logic       cyc_open, cyc_write, cyc_memory;
  logic [21:0] cyc_phys;

  // --------------------------------------------------------- what is faulted
  logic [2:0] fault_clause;
  logic       fault;

  always_comb begin
    fault_clause = C_NONE;
    // In the order of what a spurious write looks like, most specific first:
    // the direction being wrong is the board's own suspect and must not be
    // reported as a mere duplicate.
    if (req_rise && !cyc_open)                    fault_clause = C_NO_CYCLE;
    else if (req_rise && !cyc_memory)             fault_clause = C_NOT_MEMORY;
    else if (req_rise && (mem_write != cyc_write)) fault_clause = C_DIRECTION;
    else if (req_rise && (reqs != 2'd0))          fault_clause = C_TWO_REQS;
    else if (done_rise && in_req && (answers != 2'd0)) fault_clause = C_TWICE;
    else if (done_rise && !in_req)                fault_clause = C_LOOSE_ANS;
    fault = fault_clause != C_NONE;
  end

  // ------------------------------------------------------------ the record
  logic [14:0] faults;      // saturating; any reading but zero is the finding
  logic [14:0] stalled;     // requests that fell with no answer at all
  // Which clauses ever fired, one bit each, indexed by the clause code less
  // one --- so six bits for six clauses and no spare.  A field with a bit in
  // it that nothing can ever set is a bit somebody has to be told to
  // disbelieve, and the pad in word 1 is a pad and says so.
  logic [5:0]  seen;
  // AND THE LATCH IS THE CLAUSE ITSELF.  There is no separate valid bit: a
  // clause of zero says nothing was latched, so no two fields of the record
  // can disagree about whether there is one.
  logic [2:0]  first_clause;
  logic [21:0] first_phys;
  logic [31:0] first_addr, first_data, first_vma, first_md, first_micro;
  logic [13:0] first_pc, first_opc;
  logic [31:0] micro;

  always_ff @(posedge clk) begin
    if (rst) begin
      req_q          <= 1'b0;
      done_q         <= 1'b0;
      cycle_q        <= 1'b0;
      in_req         <= 1'b0;
      answers        <= 2'd0;
      reqs           <= 2'd0;
      cyc_open       <= 1'b0;
      cyc_write      <= 1'b0;
      cyc_memory     <= 1'b0;
      cyc_phys       <= 22'd0;
      faults         <= 15'd0;
      stalled        <= 15'd0;
      seen           <= 6'd0;
      first_clause   <= C_NONE;
      first_phys     <= 22'd0;
      first_addr     <= 32'd0;
      first_data     <= 32'd0;
      first_vma      <= 32'd0;
      first_md       <= 32'd0;
      first_micro    <= 32'd0;
      first_pc       <= 14'd0;
      first_opc      <= 14'd0;
      micro          <= 32'd0;
    end else begin
      req_q   <= mem_req;
      done_q  <= mem_done;
      cycle_q <= cycle;

      // THE MICROCYCLE, counted here so that a fault is named in the
      // coordinate everything else about this board is named in.  It does not
      // saturate: at 32 bits it runs for 4,294,967,295 of them, which is
      // twenty-four times the 176,119,628 the board reached before it halted,
      // and a wrap is visible as a fault number smaller than the console's own
      // reading of the machine.
      if (boundary) micro <= micro + 32'd1;

      // The bus cycle the master has opened, taken from the master's own
      // signals at the instant it opens.
      if (cycle_rise) begin
        cyc_open   <= 1'b1;
        cyc_write  <= cycle_write;
        cyc_memory <= cycle_memory;
        cyc_phys   <= cycle_phys;
        reqs       <= 2'd0;
      end else if (cycle_fall) begin
        cyc_open <= 1'b0;
      end

      // The request now open at the memory port.
      if (req_rise) begin
        in_req         <= 1'b1;
        answers        <= 2'd0;
        if (reqs != 2'd3) reqs <= reqs + 2'd1;
      end else if (in_req && !mem_req) begin
        in_req <= 1'b0;
        // A REQUEST THAT FELL WITH NO ANSWER IS A DIFFERENT FAULT AND GETS A
        // COUNTER OF ITS OWN.  On a board where `ps7_post_config` has not run
        // the port answers nothing and every request falls this way; letting
        // that take the first-fault latch would erase the record this module
        // exists to keep with a fault anybody can already see four other ways.
        if (answers == 2'd0 && !(&stalled)) stalled <= stalled + 15'd1;
      end
      if (done_rise && in_req && answers != 2'd3) answers <= answers + 2'd1;

      // THE FAULT.  Counted always, latched once.
      if (fault) begin
        if (!(&faults)) faults <= faults + 15'd1;
        seen[fault_clause - 3'd1] <= 1'b1;
        if (first_clause == C_NONE) begin
          first_clause <= fault_clause;
          // The address twice over, because a mistranslation between the
          // CADR's word address and the byte address on the port is itself
          // one of the things this can catch: `cyc_phys` is what the master
          // asked for and `mem_addr` is what went out.
          first_phys   <= cyc_phys;
          first_addr   <= mem_addr;
          // WHAT STOOD ON THE WRITE-DATA LINES, which on a read is the whole
          // of MD and is therefore the word a spurious write would have put
          // into memory.  This is the field that names the corruption.
          first_data   <= mem_wdata;
          first_vma    <= vma;
          first_md     <= md;
          first_micro  <= micro;
          first_pc     <= pc;
          first_opc    <= opc;
        end
      end
    end
  end

  // ------------------------------------------------------------ the readout
  //
  // Eight words, each with the marker in its top sixteen bits, registered one
  // tick behind `sel` as the readout window's own memories are.
  logic [47:0] word_c;
  always_comb begin
    unique case (sel)
      3'd0:    word_c = {MARK, 1'b0, stalled, 1'b1, faults};
      3'd1:    word_c = {MARK, 1'b0, seen, first_clause, first_phys};
      3'd2:    word_c = {MARK, first_addr};
      3'd3:    word_c = {MARK, first_data};
      3'd4:    word_c = {MARK, first_vma};
      3'd5:    word_c = {MARK, first_md};
      3'd6:    word_c = {MARK, first_micro};
      3'd7:    word_c = {MARK, 2'd0, first_pc, 2'd0, first_opc};
      default: word_c = {MARK, 32'd0};
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) word <= {MARK, 32'd0};
    else word <= word_c;
  end

endmodule

`default_nettype wire
