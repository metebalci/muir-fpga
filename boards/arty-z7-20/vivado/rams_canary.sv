// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The tool canary of `rams_check.tcl`: the shape Vivado 2026.1 builds wrong,
// reduced to one memory.  Not part of any design, and read by no board's
// glob; `rams_check.tcl` synthesizes it out of context on its own before the
// board is read.
//
// One address, chosen by a COMBINATIONAL write enable, for a READ_FIRST
// write and a read in one process, with a second read port beside them and
// 16K words.  Written so, the synthesis this project measured builds sixteen
// block RAMs with only `ra` at their address pins: the write lands at the
// read address.  A registered enable, a WRITE_FIRST write or a 1K-deep array
// each keep the mux, which is why the canary is exactly this and nothing
// milder.  Quartus keeps the mux in this form as well.
`default_nettype none

module rams_canary (
    input  var logic        clk,
    input  var logic        wp,
    input  var logic        pw,
    input  var logic [13:0] wa,
    input  var logic [13:0] ra,
    input  var logic [13:0] ro_a,
    input  var logic [31:0] d,
    output var logic [31:0] q,
    output var logic [31:0] ro_q
);
  logic [31:0] mem [0:16383];
  logic        we;
  logic [13:0] a;
  assign we = wp && pw;
  assign a  = we ? wa : ra;
  always_ff @(posedge clk) begin
    if (we) mem[a] <= d;
    q <= mem[a];
  end
  always_ff @(posedge clk) ro_q <= mem[ro_a];
endmodule

`default_nettype wire
