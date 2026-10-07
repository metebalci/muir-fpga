// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 14's TLB memory (contract G3 revision 14, appendix A14.4):
// N entries, direct-mapped, each a valid bit, the tag `VA<31:10+k>` and the
// page entry's `<29:0>`, with k = log2 N; 41 bits at 4,096 entries.  muir's
// `tlb::Tlb` holds the same contents; `quux_mmu.sv` decides what is read and
// written and when, and this module is only the memory.
//
// **ONE TRUE DUAL-PORT MEMORY, BOTH PORTS WRITING** (A14.15, M2's notes):
// port A is addressed by `VMA`'s index and writes the walker's fills, the
// write-backs' OR and half of the sweep; port B is addressed by `MD`'s index
// and writes the `WRITE-MAP` operations and the other half of the sweep.
// Quartus builds one true dual-port M20K only when both ports write; with
// port A writing alone it built two simple dual-port copies, or registers
// (`m2-fit.md`).
//
// **BOTH PORTS ARE NO_CHANGE**: a port's output holds what it last read
// while the port writes.  UltraRAM refuses WRITE_FIRST, and Vivado then
// builds block RAM in its place without failing (M2); in NO_CHANGE it builds
// one URAM288.  So nothing here reads a word through a write: `quux_mmu.sv`
// reads both ports at every generator cycle's edge and writes them only on
// the ticks between, a write landing at an edge or pending across it
// forwarded to that edge's read; no port is read in a tick either port
// writes.
//
// **THE PRIMITIVE IS CHOSEN OUTSIDE `rtl/machine/`**: block RAM on the Arty
// Z7-20, M20K on the DE25-Nano, UltraRAM on the Kria KR260, each by its
// board flow's setting on this memory (`tlb_mem`); nothing here names a
// vendor.  The read-during-write question is the one the board flows'
// `rams_check.tcl` scripts and this module's poison answer.
//
// **THE READ-DURING-WRITE POISON** (`CADR_RDW_POISON`, a check's variant and
// never a board's): a port read in a tick in which the other port writes the
// address it reads takes the complement, the word no tool defines; and a
// port's own read and write in one tick is refused outright, as the module
// is written never to do it.  `build/rdw_poison_quux14.quux.*.pass` runs the
// TLB's programs under it, and `n_rdw` counts the ticks it fired on.
//
// **THE ENABLES ARE EXPLICIT** (the block-RAM rule, `0c500d4`): each port is
// enabled only on the ticks it reads or writes: at the edge, its address
// then `VMA`'s or `MD`'s next value, which has the microcycle, and on a tick
// it writes, its address then a register of the tick; so a block RAM's
// address is never moving while it is enabled (UG473;
// `boards/arty-z7-20/vivado/tlb_check.tcl` holds each enable to the edge).

`default_nettype none

module quux_tlb #(
    // The entries, N, a power of two from 1,024 to 32,768 (A14.4).
    parameter int unsigned ENTRIES = 4096,
    localparam int unsigned K      = $clog2(ENTRIES),
    localparam int unsigned TAG    = 22 - K,
    localparam int unsigned WIDTH  = 1 + TAG + 30
) (
    input  var logic             clk,

    // Port A: enabled, written, the index, the word.
    input  var logic             a_en,
    input  var logic             a_we,
    input  var logic [K-1:0]     a_idx,
    input  var logic [WIDTH-1:0] a_wdata,
    output var logic [WIDTH-1:0] a_q,

    // Port B.
    input  var logic             b_en,
    input  var logic             b_we,
    input  var logic [K-1:0]     b_idx,
    input  var logic [WIDTH-1:0] b_wdata,
    output var logic [WIDTH-1:0] b_q
);

  if (ENTRIES < 1024 || ENTRIES > 32768 || (1 << K) != ENTRIES) begin : g_bad_entries
    $error("quux_tlb: ENTRIES is %0d; the TLB is a power of two from 1,024 to 32,768 entries", ENTRIES);
  end

  logic [WIDTH-1:0] tlb_mem [0:ENTRIES-1];

`ifdef CADR_RDW_POISON
  logic a_poison, b_poison;
  assign a_poison = a_en && !a_we && b_en && b_we && a_idx == b_idx;
  assign b_poison = b_en && !b_we && a_en && a_we && a_idx == b_idx;
  longint unsigned n_writes = 0, n_rdw = 0;
  always_ff @(posedge clk) begin
    if ((a_en && a_we) || (b_en && b_we)) n_writes <= n_writes + 1;
    if (a_poison || b_poison) n_rdw <= n_rdw + 1;
    if (a_en && a_we && b_en && b_we && a_idx == b_idx)
      $fatal(1, "quux_tlb: both ports write entry %0d in one tick", a_idx);
  end
  // The machine is built never to read through a write, so one that did is a
  // fault even when nothing used the word.
  final begin
    $display("rdw_poison: the TLB written at %0d ticks, read through the other port's write %0d times",
             n_writes, n_rdw);
    if (n_rdw != 0) $fatal(1, "quux_tlb: a port read the entry the other port wrote, %0d times", n_rdw);
  end
`else
  logic a_poison, b_poison;
  assign a_poison = 1'b0;
  assign b_poison = 1'b0;
`endif

  // Port A, NO_CHANGE: a write leaves the output as it was.
  always_ff @(posedge clk) begin
    if (a_en) begin
      if (a_we) tlb_mem[a_idx] <= a_wdata;
      else      a_q <= a_poison ? ~tlb_mem[a_idx] : tlb_mem[a_idx];
    end
  end

  // Port B, the same.
  always_ff @(posedge clk) begin
    if (b_en) begin
      if (b_we) tlb_mem[b_idx] <= b_wdata;
      else      b_q <= b_poison ? ~tlb_mem[b_idx] : tlb_mem[b_idx];
    end
  end

endmodule

`default_nettype wire
