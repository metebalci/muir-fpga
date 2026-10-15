// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE MEMORY PORT'S LATENCY PROBE**: how long the bridge takes to answer
// the machine, timed at the bridge's own handshakes, for the DE25-Nano's
// FPGA-to-SDRAM bridge (`quux15_f2sdram_port.sv`) and the Kria KR260's
// `S_AXI_HP0_FPD` (`boards/kria-kr260/quux15_kr260.sv`), each board's own
// wiring feeding it its port's four handshakes.  The tally
// (`cadr_mem_count.sv`) counts requests and answers and has no timer, so it
// cannot give a latency; this does, for the machine's port alone:
//
//   a read     from the bridge taking its address (ARVALID and ARREADY with
//              the machine's ID) to the bridge's last beat of it (RVALID,
//              RREADY and RLAST with that ID): a line fill, or each of the
//              two bursts of a line split at 4 KiB
//   a write    from the bridge taking its address (AWVALID and AWREADY) to
//              its response (BVALID and BREADY), each burst of a split
//              word its own
//
// each as the most, the sum and the count, in clocks of the machine's clock.
// The machine's transactions carry one ID, so the bridge answers each
// direction in order, and the probe keeps the clock each address was taken
// in a queue per direction, as deep as that direction can have in flight
// (on the DE25-Nano the share's `M_WRITES` writes; reads by beats, a
// line's five, so three lines at most; on the Kria KR260 the master's
// sixteen posted writes each split in two at most, and a line's two
// reads).  A latency is the clock its answer came in less the
// clock at the queue's head.
//
// **IT RUNS ONLY WHEN TOLD.**  `run`, a clock's pulse, clears every figure
// and starts it; `stop` freezes it, so that software reads a set of figures
// taken over one interval and no read tears a sum from its count.  The
// queues follow the bridge whether it runs or not, so a run started with
// transactions in flight times those too.  Out of the fabric's reset it is
// stopped and every figure 0.
//
// **WHAT IT CANNOT SEE, IT SAYS.**  `lost`, sticky until the next `run`: an
// address taken with its queue full, or an answer with its queue empty;
// either would put the queue out of step with the bridge.  `saturated`,
// sticky until the next `run`: a count reached all ones, and both
// directions stopped there.  A latency is the difference of two `T_W`-bit
// clock stamps, so one longer than 2^`T_W` - 1 clocks (24 ms at 23 ns) reads
// short; none near it is expected, the longest tail seen on this path being
// 4 to 9 us.
//
// `port_rst` is the bridge's: what was in flight is forgotten, and so are
// the queues.  `rst` is the fabric's, the figures' and the run's.
//
// What holds it: `tb/quux15_f2sdram_tb.cpp` times the same handshakes itself
// in every configuration and compares the figures the face reads, and
// `tb/quux15_kr260_probe_tb.cpp` does the same through the Kria KR260's
// top level.

`default_nettype none

module quux15_mem_probe #(
    parameter int unsigned T_W      = 20,
    parameter int unsigned RD_DEPTH = 4,
    parameter int unsigned WR_DEPTH = 16
) (
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        port_rst,
    input  var logic        run,
    input  var logic        stop,
    // The bridge's handshakes with the machine's ID.
    input  var logic        ar_take,
    input  var logic        r_last,
    input  var logic        aw_take,
    input  var logic        b_take,
    output var logic        running,
    output var logic        lost,
    output var logic        saturated,
    output var logic [31:0] rd_count,
    output var logic [47:0] rd_sum,
    output var logic [T_W-1:0] rd_max,
    output var logic [31:0] wr_count,
    output var logic [47:0] wr_sum,
    output var logic [T_W-1:0] wr_max
);

  localparam int unsigned RA = $clog2(RD_DEPTH);
  localparam int unsigned WA = $clog2(WR_DEPTH);

  // The clock, free running.
  logic [T_W-1:0] now;
  always_ff @(posedge clk) begin
    if (rst) now <= '0;
    else now <= now + T_W'(1);
  end

  // --- The two queues of stamps: pushed at an address taken, popped at its
  // --- answer, both in one clock when they meet.
  logic [T_W-1:0] rd_q [RD_DEPTH];
  logic [T_W-1:0] wr_q [WR_DEPTH];
  logic [RA-1:0]  rd_head, rd_tail;
  logic [WA-1:0]  wr_head, wr_tail;
  logic [RA:0]    rd_n;
  logic [WA:0]    wr_n;
  logic           rd_push, rd_pop, wr_push, wr_pop, rd_bad, wr_bad;
  assign rd_bad  = (ar_take && !r_last && rd_n == (RA+1)'(RD_DEPTH)) || (r_last && rd_n == '0);
  assign wr_bad  = (aw_take && !b_take && wr_n == (WA+1)'(WR_DEPTH)) || (b_take && wr_n == '0);
  assign rd_push = ar_take && !(rd_n == (RA+1)'(RD_DEPTH) && !r_last);
  assign rd_pop  = r_last && rd_n != '0;
  assign wr_push = aw_take && !(wr_n == (WA+1)'(WR_DEPTH) && !b_take);
  assign wr_pop  = b_take && wr_n != '0;

  always_ff @(posedge clk) begin
    if (rd_push) rd_q[rd_tail] <= now;
    if (wr_push) wr_q[wr_tail] <= now;
  end
  always_ff @(posedge clk) begin
    if (rst || port_rst) begin
      rd_head <= '0;
      rd_tail <= '0;
      rd_n    <= '0;
      wr_head <= '0;
      wr_tail <= '0;
      wr_n    <= '0;
    end else begin
      if (rd_push) rd_tail <= (rd_tail == RA'(RD_DEPTH - 1)) ? '0 : rd_tail + RA'(1);
      if (rd_pop)  rd_head <= (rd_head == RA'(RD_DEPTH - 1)) ? '0 : rd_head + RA'(1);
      rd_n <= rd_n + (rd_push ? (RA+1)'(1) : '0) - (rd_pop ? (RA+1)'(1) : '0);
      if (wr_push) wr_tail <= (wr_tail == WA'(WR_DEPTH - 1)) ? '0 : wr_tail + WA'(1);
      if (wr_pop)  wr_head <= (wr_head == WA'(WR_DEPTH - 1)) ? '0 : wr_head + WA'(1);
      wr_n <= wr_n + (wr_push ? (WA+1)'(1) : '0) - (wr_pop ? (WA+1)'(1) : '0);
    end
  end

  // --- The figures.
  logic [T_W-1:0] rd_lat, wr_lat;
  assign rd_lat = now - rd_q[rd_head];
  assign wr_lat = now - wr_q[wr_head];

  logic counting;
  assign counting = running && !saturated;

  always_ff @(posedge clk) begin
    if (rst) begin
      running   <= 1'b0;
      lost      <= 1'b0;
      saturated <= 1'b0;
      rd_count  <= '0;
      rd_sum    <= '0;
      rd_max    <= '0;
      wr_count  <= '0;
      wr_sum    <= '0;
      wr_max    <= '0;
    end else if (run) begin
      running   <= 1'b1;
      lost      <= 1'b0;
      saturated <= 1'b0;
      rd_count  <= '0;
      rd_sum    <= '0;
      rd_max    <= '0;
      wr_count  <= '0;
      wr_sum    <= '0;
      wr_max    <= '0;
    end else begin
      if (stop) running <= 1'b0;
      if (rd_bad || wr_bad) lost <= 1'b1;
      if (counting && rd_pop) begin
        rd_count <= rd_count + 32'd1;
        rd_sum   <= rd_sum + 48'(rd_lat);
        if (rd_lat > rd_max) rd_max <= rd_lat;
      end
      if (counting && wr_pop) begin
        wr_count <= wr_count + 32'd1;
        wr_sum   <= wr_sum + 48'(wr_lat);
        if (wr_lat > wr_max) wr_max <= wr_lat;
      end
      if (counting && ((rd_pop && rd_count == 32'hFFFF_FFFE) || (wr_pop && wr_count == 32'hFFFF_FFFE)))
        saturated <= 1'b1;
    end
  end

endmodule

`default_nettype wire
