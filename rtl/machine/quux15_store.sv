// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S CONTROL STORE** (contract G3 revision 15, A15b.2, A15b.4):
// 16,384 words of 64 bits, MIT's 48 in `<47:0>` and the extension in
// `<63:48>`, and QUUX's boot PROM at 36000-37777 (contract Q2), 1,024 words
// of 64 bits read from `PROM_HEX`, a word a line in hex
// (`golden/src/quux15.rs --prom`).  muir's `Machine::fetch`: an address from
// 36000 up reads the PROM, which nothing writes, and every other the RAM.
//
// CS sends the address (`re` with `raddr`) and the word is out by the next
// edge, registered, as the core's CS stage holds it.  `WRITE-I-MEM` writes the
// RAM in WB (A15b.4).  **A READ OF THE ADDRESS WRITTEN IN THE SAME CLOCK TAKES
// THE WORD WRITTEN**, by a forward: WRITE-I-MEM's refetch of the word right
// after it reads it in the clock it is written, and the RAM's own result
// there, the old word (under `QUUX15_RDW_POISON` its complement,
// `quux15_ram.sv`), is never used.
//
// **THE RAM COMES UP AS muir's MACHINE HAS IT**: `<47:0>` all ones and the
// extension zero (`golden/src/machine_axis.rs`, "the control store comes up
// all ones", which muir's `Insn::new` keeps to 48 bits).  No trace fetches a
// word nobody wrote; the convention says what such a fetch would read.
// **`<47:0>` IS STORED INVERTED**, so that a RAM that comes up zero, as
// UltraRAM does, reads that word: one RTL on every board.
//
// **THE READOUT** (A15b.13): the RAM's word at `ro_addr` on its write port,
// `<47:0>` turned back, and the PROM's on a port of its own, each a clock
// after the address, for the console's checkpoint taken halted.  So the RAM
// is two ports (`quux15_tdp.sv`): CS reads on port A, and port B is the
// write's, or the readout's while `ro_en` stands, which the core raises only
// halted, when nothing writes.
//
// The RAM is inferred here; the board's flow chooses the primitive (URAM on
// the Kria, `RAM_STYLE`) when revision 15 is built for one.  The RAM is read
// at every address CS sends, the PROM's too, and the PROM's word chosen a
// clock on, so that no address compare stands before the read's enable.

`default_nettype none

module quux15_store #(
    parameter string PROM_HEX = ""
) (
    input  var logic        clk,
    input  var logic        re,
    input  var logic [13:0] raddr,
    output var logic [63:0] rdata,
    input  var logic        we,
    input  var logic [13:0] waddr,
    input  var logic [63:0] wdata,
    input  var logic        ro_en,
    input  var logic [13:0] ro_addr,
    output var logic [63:0] ro_imem,
    output var logic [63:0] ro_prom
);

  localparam logic [13:0] PROM_BASE = 14'o36000;
  localparam logic [63:0] INVERT    = 64'h0000_ffff_ffff_ffff;

  logic [63:0] prom[1024] /* verilator public_flat_rw */;
  initial begin
    for (int unsigned k = 0; k < 1024; k++) prom[k] = 64'd0;
    if (PROM_HEX != "") $readmemh(PROM_HEX, prom);
  end

  logic [63:0] ram_q, prom_q, fwd_q, ram_ro_q;
  logic        from_prom, fwd_v;
  logic ram_we;
  assign ram_we = we && waddr < PROM_BASE;
  quux15_tdp #(
      .WIDTH    (64),
      .DEPTH    (16384),
      .INIT_WORD(64'h0)
  ) ram (
      .clk    (clk),
      .a_en   (re),
      .a_we   (1'b0),
      .a_addr (raddr),
      .a_wdata(64'd0),
      .a_q    (ram_q),
      .b_en   (ram_we || ro_en),
      .b_we   (ram_we),
      .b_addr (ro_en ? ro_addr : waddr),
      .b_wdata(wdata ^ INVERT),
      .b_q    (ram_ro_q)
  );
  assign ro_imem = ram_ro_q ^ INVERT;
  always_ff @(posedge clk) begin
    if (ro_en) ro_prom <= prom[ro_addr[9:0]];
  end

  always_ff @(posedge clk) begin
    if (re) begin
      prom_q    <= prom[raddr[9:0]];
      from_prom <= raddr >= PROM_BASE;
      fwd_v     <= we && waddr == raddr && raddr < PROM_BASE;
      fwd_q     <= wdata;
    end
  end

  assign rdata = fwd_v ? fwd_q : from_prom ? prom_q : ram_q ^ INVERT;

endmodule

`default_nettype wire
