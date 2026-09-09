// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One sample per microcycle, held in block RAM and shifted out over JTAG.
//
// WHY THIS EXISTS.  Everything in this repository agrees with muir in
// simulation --- 600,000 microcycles of MIT's boot PROM and 2,200,000 of a
// System 100 band --- and a bitstream of it has run on the part.  What has
// never happened is a comparison of what the *board* computes against what
// the model computes, because the board's whole observable surface is six
// LEDs.  Every hardware claim so far is an opinion about lights.  The probe
// is the instrument that changes that: a window of real execution, in the
// vocabulary of `Rtl::signals()`, diffable against `build/rtl.golden` row
// for row.
//
// WHY IT IS NOT AN ILA.  It was meant to be.  `create_debug_core` is refused
// by the licence on this host --- `License_Tier:BASIC` in
// `~/.Xilinx/Xilinx.lic`, and Vivado answers "'create_debug_core' tcl command
// is not supported.  Your current selected license is BASIC" --- so the
// scripted debug-core flow does not exist here, and the ILA IP core, which
// does generate at BASIC, is the directory of generated XML this project has
// already decided against.  A BSCANE2 is a primitive: one instantiation in a
// file somebody can read, which is the same argument `cadr_arty.sv` makes for
// `MMCME2_BASE`.
//
// THE THREE THINGS THIS HAS TO GET RIGHT.
//
// **1.  IT SAMPLES WHERE THE TESTBENCH SAMPLES**, which is the tick before the
// microcycle boundary and not the boundary itself.  `tb/cadr_machine_tb.cpp`
// compares the values standing *before* the edge on which `clock_edge` rises
// --- "the read phase the row describes" --- and `golden/src/trace.rs` samples
// the model after a stall has drained, because `-LOADMD` strobes MD while the
// clock is held off and a sample taken before the stall carries the word the
// cycle was waiting to be rid of.  Wrong on 5,652 of 600,000 rows if you get
// it the other way round.  The fabric has only one instant available and it is
// the right one: a stall *is* the clock held off, so the last tick before the
// boundary is after -LOADMD fired.
//
// Reaching that instant costs one tick of holding, and the arithmetic is
// worth writing down because a cheaper-looking arrangement gets it wrong.
// `clock_edge` is registered in `cadr_microcycle.sv` --- "so that it stands
// high over the tick the registers actually moved in" --- so a flip-flop that
// sees `qualify` high has already seen the datapath move: `data` at that edge
// is the *next* microcycle's read phase and not this one's.  What that edge
// must store is `data` as it stood one tick earlier, which is what `data_q`
// holds.  Off by one microcycle otherwise, uniformly, on every column.
//
// **2.  THE SAMPLE CARRIES ITS OWN MICROCYCLE NUMBER.**  `cycle` counts
// qualifying edges from reset, and is stored with each sample, so the trace's
// first column is in the capture rather than inferred from the position of a
// sample in a buffer.  It is the only direct proof that the window begins at
// microcycle zero, it turns a dropped sample into "the counter jumped" rather
// than "nine columns went wrong at once", and it makes a misalignment
// diagnosable rather than merely detectable.
//
// **3.  A SAMPLE SAYS WHETHER IT IS ONE.**  Only a qualifying edge writes, so
// every written entry carries a set valid bit, and an entry the probe never
// reached is the RAM's initial zero and carries a clear one.  A partial
// capture --- a machine that stopped before the buffer filled --- therefore
// reads back as the microcycles it did run followed by nothing, rather than as
// a buffer of plausible zeros.
//
// THE TRIGGER IS RESET, and that is the whole of it.  `wr_addr` and `cycle`
// clear on `rst` and the buffer fills from the first qualifying edge after it,
// then freezes.  Nothing has to be armed and nobody has to be standing at the
// board: by the time a bitstream is programmed and a JTAG readout is
// arranged, the window --- the first DEPTH microcycles the machine ever ran
// --- has long since been taken and cannot be overwritten.  Pressing BTN0
// takes a fresh one.
//
// THE READOUT PROTOCOL, which `vivado/probe.tcl` is the other half of.  One
// DR scan of SAMPLE bits returns one sample and advances the read pointer, so
// DEPTH scans return the whole buffer and leave the pointer where they found
// it.  There is no bit counter and no use of UPDATE: the pointer moves on the
// CAPTURE edge, after the word has been loaded, so a scan that is aborted or
// over-shifted still advances the pointer exactly once.  The pointer wraps,
// and each sample carries its own `cycle`, so a readout that starts in the
// middle of the buffer is rotated back into order by the reader rather than
// being lost.
//
// THE CLOCK CROSSING IS QUASI-STATIC AND THAT IS ON PURPOSE.  `rd_addr` lives
// in the DRCK domain and moves once per scan --- 454 TCKs, tens of
// microseconds --- while `mem_q` is read in the 200 MHz domain through a
// two-flop synchroniser on the address.  By the time the JTAG side loads
// `mem_q` at the next CAPTURE, the address has been stable for thousands of
// ticks and the word for very nearly as many.  It is the same argument
// `CLAUDE.md` makes about the map: a synchronous read of an address that is
// constant for the whole interval settles long before anything looks at it.

`default_nettype none

module cadr_probe #(
    // Samples.  A power of two, because the read pointer wraps on it.
    parameter int unsigned DEPTH = 1024
) (
    input  var logic             clk,      // 200 MHz, the machine's own
    input  var logic             rst,
    input  var logic             qualify,  // `clock_edge`: one tick a microcycle

    // THE DATAPATH, ONE PORT A COLUMN, NAMED FOR THE COLUMN.  The subset of
    // `build/rtl.golden`'s header that `cadr_machine` brings out, in the
    // trace's own order.  What is not here is not here because the machine
    // has no port for it --- `wmapd`, `destspcd`, `imodd`, `pdlwrited`,
    // `spushd`, `srun`, `errstop`, `stathenb`, `speed1`, `speed0` --- or
    // because it is not a signal at all: `stall`, `halted`, `ns` and `ack`
    // are nanosecond counts the model keeps, `bus` counts memory cycles, and
    // `gnt` and `sintr` are the far end of a bus nothing is on here.
    //
    // `n_vmaok` is the trace's polarity and the board's, `NAND(-PFR, -PFW)`
    // at VCTL1 1D17 --- low when the access is permitted.  `cadr_machine`
    // brings out the logical `vmaok` the jump conditions take, so the
    // inversion is one visible expression at the instantiation.
    //
    // `cycle` is not a port: this module counts it, so that a sample carries
    // its own microcycle number rather than its position in a buffer.
    input  var logic [13:0]      pc,
    input  var logic [47:0]      ir,
    input  var logic [31:0]      q,
    input  var logic [31:0]      a,
    input  var logic [31:0]      m,
    input  var logic [31:0]      alu,
    input  var logic [31:0]      r,
    input  var logic [31:0]      ob,
    input  var logic [9:0]       dc,
    input  var logic [13:0]      opc,
    input  var logic [31:0]      st,
    input  var logic [25:0]      lc,
    input  var logic             iwrited,
    input  var logic             nop,
    input  var logic             n_vmaok,
    input  var logic             jcond,
    input  var logic             pcs1,
    input  var logic             pcs0,
    input  var logic [13:0]      lpc,
    input  var logic [31:0]      md,
    input  var logic [31:0]      vma,
    input  var logic             promdis,

    // The BSCANE2's fabric side.  The primitive is instantiated in
    // `cadr_arty.sv`, beside the MMCM, so that this module is a module and
    // can be simulated: `tb/cadr_probe_tb.cpp` drives these directly.
    input  var logic             jtag_drck,
    input  var logic             jtag_sel,
    input  var logic             jtag_shift,
    input  var logic             jtag_capture,
    input  var logic             jtag_tdi,
    output var logic             jtag_tdo
);

  // THE LAYOUT, AND THE ONLY PLACE IT IS WRITTEN.  Most significant field
  // first, in the trace's column order, so that a sample read as one long
  // hexadecimal number has its columns in the order the trace's header names
  // them.  `vivado/probe.tcl` walks the same list in the same order and
  // checks its own total against `SAMPLE` before it decodes anything.
  localparam int unsigned WIDTH  = 421;
  localparam int unsigned ADDR   = $clog2(DEPTH);
  localparam int unsigned SAMPLE = 1 + 32 + WIDTH;   // valid, cycle, data

  logic [WIDTH-1:0] data;
  assign data = {pc, ir, q, a, m, alu, r, ob, dc, opc, st, lc,
                 iwrited, nop, n_vmaok, jcond, pcs1, pcs0,
                 lpc, md, vma, promdis};

  logic [SAMPLE-1:0] mem [DEPTH];

  // Zeroed so that an unwritten entry reads back with its valid bit clear
  // rather than as X.  Vivado brings block RAM up zero anyway; this is for
  // the simulation, where X would make a partial capture unreadable instead
  // of merely empty.
  initial begin
    for (int unsigned i = 0; i < DEPTH; i++) mem[i] = '0;
  end

  // ----------------------------------------------------- the sampling side

  logic [ADDR-1:0]  wr_addr;
  logic [31:0]      cycle;
  logic             full;

  // ONE TICK OF HOLDING, AND IT IS THE WHOLE OF THE ALIGNMENT.  See the
  // header: at the edge where `qualify` is high the datapath has already
  // moved, so what this edge must store is what stood a tick before it.
  // It is not reset --- there is nothing to reset it to that is more
  // truthful than the machine's own output --- and the first thing written
  // is a qualified sample, by which time it has been following `data` for a
  // whole microcycle.
  //
  // **IT IS TWO REGISTERS AND NOT ONE, AND THE SPLIT IS A TIMING CLAIM.**
  // Most of what `cadr_machine` brings out is combinational --- the A and M
  // buses, the ALU, R, OB, the four sequencing flags --- and the machine's
  // own consumers of those take a microcycle to settle in, which is what
  // `rtl/cadr_machine.xdc` grants them.  A register outside the machine
  // taking the same nets in one 5 ns tick asks for something nothing in the
  // design has ever met: measured, `memstart_reg` reaching this register
  // through 24 levels of the dispatch memory is 18.048 ns, and the
  // instrumented board came out at **-13.156 ns on 2,400 endpoints** before
  // the split.  So `stable_q` takes the microcycle exception, in
  // `rtl/cadr_probe.xdc`, on the same argument the machine makes for
  // itself: its inputs stand still from one boundary to the next.
  //
  // `late_q` must NOT, and that is the whole reason there are two.  It holds
  // the four columns that can move *inside* a microcycle --- `lpc`, `md`,
  // `vma` and `promdis` --- and `md` is the one CLAUDE.md's entry about
  // sampling before a stall is about: `-LOADMD` strobes it while the clock is
  // held off, and a register given 75 ns to notice might not have.  All four
  // come straight off registers in the machine, so one tick is what they can
  // have and what they do not need help meeting.
  //
  // They divide on a bit boundary because the trace's column order puts them
  // last: bits 78 down to 0 are exactly `lpc`, `md`, `vma`, `promdis`.
  localparam int unsigned LATE = 79;
  logic [WIDTH-1:LATE] stable_q;
  logic [LATE-1:0]     late_q;
  logic [WIDTH-1:0]    data_q;
  assign data_q = {stable_q, late_q};

  always_ff @(posedge clk) begin
    stable_q <= data[WIDTH-1:LATE];
    late_q   <= data[LATE-1:0];
    if (rst) begin
      wr_addr <= '0;
      cycle   <= 32'd0;
      full    <= 1'b0;
    end else begin
      // Free-running, so that `cycle` is the trace's own absolute microcycle
      // number and not an index into a buffer that has stopped filling.
      if (qualify) cycle <= cycle + 32'd1;
      if (qualify && !full) begin
        mem[wr_addr] <= {1'b1, cycle, data_q};
        wr_addr <= wr_addr + ADDR'(1);
        if (wr_addr == ADDR'(DEPTH - 1)) full <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------ the readout side

  // The pointer lives in the JTAG domain and comes up at zero, so a board
  // that has been configured and not yet read hands back sample zero first.
  logic [ADDR-1:0] rd_addr = '0;

  logic [ADDR-1:0]   rd_addr_s1, rd_addr_s2;
  logic [SAMPLE-1:0] mem_q;
  always_ff @(posedge clk) begin
    rd_addr_s1 <= rd_addr;
    rd_addr_s2 <= rd_addr_s1;
    mem_q      <= mem[rd_addr_s2];
  end

  logic [SAMPLE-1:0] sr;
  always_ff @(posedge jtag_drck) begin
    if (jtag_sel) begin
      if (jtag_capture) begin
        sr      <= mem_q;
        // ADVANCED HERE, NOT AT UPDATE, and not on a count of shifted bits.
        // One CAPTURE is one scan whatever happens afterwards, so a scan that
        // is cut short or shifted with the wrong length still moves the
        // pointer exactly once and the reader stays in step.
        rd_addr <= rd_addr + ADDR'(1);
      end else if (jtag_shift) begin
        sr <= {jtag_tdi, sr[SAMPLE-1:1]};
      end
    end
  end

  assign jtag_tdo = sr[0];

endmodule

`default_nettype wire
