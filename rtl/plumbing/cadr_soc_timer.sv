// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system's clock: a free-running 64-bit counter of the
// board's own ticks, a comparator against it, and the machine-timer interrupt
// RISC-V calls `mtip`.
//
// **IT COUNTS THE BOARD'S TICKS AND NOT THE CADR's.**  The console's TICKS
// register counts the same edges, but it is zeroed by the machine's reset and
// this is not: the firmware's idea of how long something took must survive
// the machine being restarted under it, or the one instrument that can time a
// reset is the one the reset breaks.  So there are two clocks in the design
// on purpose and they are both honest about what they count.
//
// **ONE TICK IS TEN NANOSECONDS AND THAT IS NOT WRITTEN DOWN ANYWHERE IN THE
// FIRMWARE.**  Word 1 reads how many ticks go into one real microsecond,
// computed here from `CLK_HZ`.  A firmware that divided by a constant of its
// own would be a second description of the board's clock, and this project
// has measured what that costs: `boards/arty-z7-20/vivado/tick.tcl` exists
// because a constraint file holding its own period described a machine nobody
// was building.  The same argument applies to a program.
//
// THE REGISTERS, six words at the base the SoC decodes:
//
//   0x00  IDENT        reads "TIME"
//   0x04  TICKS_PER_US `CLK_HZ / 1,000,000`, so that the firmware converts
//                      without knowing the clock.  100 at this board's 10 ns
//                      tick, 160 at 6.25 and 200 at 5 --- every tick this
//                      project has built with divides a thousand exactly,
//                      which is a constraint on any future tick and not a
//                      fact about this one
//   0x08  MTIME_LO     bits 31:0 of the counter.  **Reading it LATCHES bits
//                      63:32 beside it**
//   0x0C  MTIME_HI     that latch.  Read LO then HI, in that order, or the
//                      pair names a time 4,294,967,296 ticks in the future
//                      across a carry --- the console's own rule for CYCLES
//                      and TICKS, for the identical reason
//   0x10  MTIMECMP_LO  written; the interrupt is up while the counter has
//   0x14  MTIMECMP_HI  reached the pair.  Both come up all ones, so a
//                      firmware that never writes them never sees the
//                      interrupt
//
// An address in the page that is none of the six reads `UNMAPPED` and a write
// to it is dropped.  Nothing here can refuse to answer.
//
// **WRITE THE HIGH HALF FIRST.**  A comparator against a 64-bit value written
// as two stores is momentarily against a value neither the old one nor the
// new, and the safe order is the one that cannot make the moment an EARLIER
// deadline: set HI to all ones, then LO, then HI.  That is the sequence
// RISC-V's own privileged specification gives for a 32-bit hart and the
// firmware follows it.

`default_nettype none

module cadr_soc_timer #(
    parameter int unsigned CLK_HZ   = 100_000_000,
    // "TIME".
    parameter logic [31:0] IDENT    = 32'h5449_4D45,
    parameter logic [31:0] UNMAPPED = ~IDENT
) (
    input  var logic        clk,
    input  var logic        rst,

    input  var logic        sel,
    input  var logic        we,
    input  var logic [3:0]  be,
    input  var logic [11:0] addr,
    input  var logic [31:0] wdata,
    output var logic [31:0] rdata,

    // `mtip`, into the core's `irq_timer_i`.
    output var logic        irq
);

  localparam logic [31:0] TICKS_PER_US = 32'(CLK_HZ / 1_000_000);

  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic [31:0] mtime_hi_latched;

  logic [2:0] word;
  assign word = addr[4:2];

  assign irq = (mtime >= mtimecmp);

  always_ff @(posedge clk) begin
    if (rst) begin
      mtime            <= 64'd0;
      // All ones, so that a firmware which never writes the comparator never
      // sees the interrupt.  Zero would raise it at the first tick.
      mtimecmp         <= {64{1'b1}};
      mtime_hi_latched <= 32'd0;
      rdata            <= UNMAPPED;
    end else begin
      mtime <= mtime + 64'd1;

      if (sel && we) begin
        // Byte enables are honored because the seam carries them; a store of
        // a half word to a timer is not something any firmware here does, and
        // a face that quietly widened it would be lying about what landed.
        if (word == 3'd4) begin
          for (int unsigned i = 0; i < 4; i++) begin
            if (be[i]) mtimecmp[i*8 +: 8] <= wdata[i*8 +: 8];
          end
        end
        if (word == 3'd5) begin
          for (int unsigned i = 0; i < 4; i++) begin
            if (be[i]) mtimecmp[32 + i*8 +: 8] <= wdata[i*8 +: 8];
          end
        end
      end

      if (sel && !we) begin
        case (word)
          3'd0: rdata <= IDENT;
          3'd1: rdata <= TICKS_PER_US;
          3'd2: begin
            rdata            <= mtime[31:0];
            // The latch that makes the pair one instant.  See the header.
            mtime_hi_latched <= mtime[63:32];
          end
          3'd3:    rdata <= mtime_hi_latched;
          3'd4:    rdata <= mtimecmp[31:0];
          3'd5:    rdata <= mtimecmp[63:32];
          default: rdata <= UNMAPPED;
        endcase
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, addr[11:5], addr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
