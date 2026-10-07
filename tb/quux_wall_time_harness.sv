// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's wall clocks at a given tick length: the microsecond clock and the
// interval timers (`rtl/machine/quux_clocks.sv`) and the real-time clock
// (`rtl/machine/quux_rtc.sv`), built with `TICK_PS` and driven by
// `tb/quux_wall_time_tb.cpp`, which holds each against wall time.

`default_nettype none

module quux_wall_time_harness #(
    parameter int unsigned TICK_PS = 10000
) (
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        edge_tick,
    input  var logic        pg_we,
    input  var logic [2:0]  pg_idx,
    input  var logic [23:0] pg_wdata,
    output var logic        irq,
    output var logic [31:0] usec,
    input  var logic        rtc_we_seconds,
    input  var logic        rtc_we_fraction,
    input  var logic [31:0] rtc_wdata,
    output var logic [31:0] rtc_seconds,
    output var logic [29:0] rtc_fraction,
    // The tick length the clocks were built with, for the testbench.
    output var logic [31:0] tick_ps
);
  assign tick_ps = 32'(TICK_PS);
  logic [23:0] rd_word;
  logic [2:0]  pending;
  logic [31:0] usec_s;
  logic [47:0] ro_time;
  logic [47:0] ro_count [0:2];
  logic [25:0] ro_conf [0:2];

  quux_clocks #(.TICK_PS(TICK_PS)) clocks (
      .clk(clk), .rst(rst), .n_boot(1'b1),
      .mclk_edge(edge_tick), .cpu_edge(edge_tick), .gen_edge(edge_tick),
      .pg_we(pg_we), .pg_idx(pg_idx), .pg_wdata(pg_wdata), .devreset(1'b0),
      .pg_ridx(3'd0), .rd_word(rd_word), .pending(pending),
      .usec_s(usec_s), .irq(irq),
      .ro_time(ro_time), .ro_count(ro_count), .ro_conf(ro_conf));
  assign usec = ro_time[31:0];

  quux_rtc #(.TICK_PS(TICK_PS)) rtc (
      .clk(clk), .we_seconds(rtc_we_seconds), .we_fraction(rtc_we_fraction),
      .wdata(rtc_wdata), .seconds(rtc_seconds), .fraction(rtc_fraction));

  logic unused;
  assign unused = ^{rd_word, pending, usec_s, ro_time[47:32], ro_count[0], ro_count[1],
                    ro_count[2], ro_conf[0], ro_conf[1], ro_conf[2]};
endmodule

`default_nettype wire
