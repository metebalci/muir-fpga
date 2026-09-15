// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system's memory: one block RAM the core fetches its
// instructions from on one port and reads and writes its data on the other,
// with the firmware already in it when the part configures.
//
// **THE FIRMWARE ARRIVES AT ELABORATION, WHICH IS THE SAME IDIOM THE BOOT
// PROM ARRIVES BY.**  `rtl/machine/cadr_microcycle.sv` takes `PROM_HEX` and
// `$readmemh`s MIT's 16,384 words into the control store, and this takes
// `FIRMWARE_HEX` and does the same.  So a bitstream carries its firmware the
// way it carries the CADR's microcode, there is no loader, no flash to write
// and no first stage --- which is how a bare FPGA design boots and is the
// whole of the answer to "without Linux, U-Boot, a device tree, will that
// work".
//
// **AND THE TRAP THAT IDIOM CARRIES IS RECORDED AND IS REAL.**  `$readmemh`
// on a file that is not there is a WARNING and not an error, so a memory whose
// hex went missing elaborates empty and the core runs zeros --- which on
// RISC-V is an illegal instruction at the first fetch, so the failure at least
// announces itself rather than running a different program.  The Makefile's
// rule is what stops it happening: the hex is a prerequisite, a stale absolute
// path compiled into a binary having once made `make` believe a control store
// of nothing was up to date.
//
// **ONE MEMORY AND NOT TWO.**  A split instruction and data memory would be
// smaller to reason about and wrong to build: a firmware has constants in its
// text, a string literal is read by a load, and the linker puts `.rodata`
// where it likes.  So this is one address space, port A reading it for the
// fetch unit and port B reading and writing it for the load-store unit, which
// is a true dual-port block RAM and what the part has.
//
// **THE READ IS A PLAIN REGISTER AND THE MULTIPLEXER IS OUTSIDE IT.**  Vivado
// refuses a RAM process with a multiplexer on its read --- `Synth 8-2914
// Unsupported RAM template`, a hard stop --- and Verilator lints and
// simulates such a thing happily, so this is one of the places where lint is
// not the fitter.  The block store met it once; this is written the way that
// one was rewritten.
//
// **READ-FIRST, WHICH IS WHAT THE PRIMITIVE DOES.**  A write and a read of one
// address on one port in one cycle returns the OLD word.  Nothing here reads
// what it is writing in the same cycle, and saying which it is costs nothing
// and stops the question being asked again.
//
// **THE TWO PORTS CAN NAME ONE WORD AND NOTHING ARBITRATES THEM.**  Port B
// writing while port A fetches the same address gives port A the old word,
// which is the block RAM's own behavior for two ports in one cycle, and a
// firmware that wrote over the instruction it was about to execute would be
// doing something no firmware here does.  It is stated rather than guarded:
// a guard would cost a cycle on every fetch to make a case nobody reaches
// half a cycle different.

`default_nettype none

module cadr_soc_ram #(
    // How many 32-bit words.  8,192 is 32 KB, which is eight block RAM tiles
    // on this part and about four times the first firmware.  It is a
    // parameter because the programs this will grow into --- a pack server, a
    // network stack, an RFB server --- will want more, and because a board
    // with less block RAM will want less.
    parameter int unsigned WORDS = 8192,
    parameter string FIRMWARE_HEX = "build/soc_firmware.hex"
) (
    input  var logic                      clk,

    // --- port A: the fetch unit.  Read only; there is nothing that writes
    // --- instructions.
    input  var logic                      a_en,
    input  var logic [$clog2(WORDS)-1:0]  a_addr,
    output var logic [31:0]               a_rdata,

    // --- port B: the load-store unit.
    input  var logic                      b_en,
    input  var logic                      b_we,
    input  var logic [3:0]                b_be,
    input  var logic [$clog2(WORDS)-1:0]  b_addr,
    input  var logic [31:0]               b_wdata,
    output var logic [31:0]               b_rdata
);

  logic [31:0] mem [0:WORDS-1];

  initial begin
    $readmemh(FIRMWARE_HEX, mem);
  end

  always_ff @(posedge clk) begin
    if (a_en) a_rdata <= mem[a_addr];
  end

  always_ff @(posedge clk) begin
    if (b_en) begin
      if (b_we) begin
        for (int unsigned i = 0; i < 4; i++) begin
          if (b_be[i]) mem[b_addr][i*8 +: 8] <= b_wdata[i*8 +: 8];
        end
      end
      b_rdata <= mem[b_addr];
    end
  end

endmodule

`default_nettype wire
