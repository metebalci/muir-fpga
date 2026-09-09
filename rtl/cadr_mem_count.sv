// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What the machine asked its memory port for, and what the processing system
// answered.  Four counters, and the difference between the two pairs is the
// whole instrument.
//
// WHY THIS EXISTS.  The boot PROM's only main-memory traffic is
// PAGE-0-PARITY-FIX, which reads each of the 256 words of page 0 and writes
// the same word straight back.  An identity copy leaves NOTHING BEHIND: page 0
// reading back unchanged afterwards says the path did no harm and cannot tell
// a machine that ran from one that never touched memory at all, because a
// board whose port is dead times out all 512 cycles and leaves page 0 exactly
// as unchanged.  So the board needs a positive witness, and the processing
// system ships no counter that could be one: the DDR controller has no
// performance monitors --- all 114 of its registers were enumerated --- the
// AFI interface's status is instantaneous, and Xilinx's own performance
// tooling instantiates a counter IP in the fabric for exactly this reason.
// This is that counter, at 64 flip-flops.
//
// **THE ANSWERS ARE COUNTED AT THE PROCESSING SYSTEM'S OWN HANDSHAKES**, `B`
// for a write and the last `R` beat for a read, and not at anything the
// fabric decides for itself.  That is the point of the module and it is
// CLAUDE.md's shadow-memory lesson one level down: a shadow memory keyed by
// the DUT's own address moves with the bug, and a counter of the fabric's own
// intentions moves with it in exactly the same way.  A fabric that never
// issued a transaction cannot fabricate a `BVALID`, so `answered_*` reading
// zero on a board is not a claim this design is able to get wrong in its own
// favour.
//
// AND THE ASKING IS COUNTED TOO, WHICH IS WHAT MAKES A ZERO READABLE.  With
// only the answers, `0` means either "the machine never got that far" or "the
// port is dead", and those are two different faults that would look the same
// --- the shape of failure this project keeps meeting.  With both pairs,
// `256 asked, 0 answered` is a dead port and `0 asked` is a machine that never
// reached its memory.  The request is counted at the RISE of `req`, which is a
// level the bridge holds up until it has been answered or the interface has
// timed the cycle out; counting the level would count ticks.
//
// FIFTEEN BITS EACH, SATURATING, WITH A MARKER BESIDE THEM.  Sixty-four EMIO
// GPIO bits is the whole budget --- `DATA_2_RO` at 0xE000A068 and `DATA_3_RO`
// at 0xE000A06C, thirty-two bits apiece --- and this is how they are spent:
//
//     gpio[14:0]   answered reads      gpio[46:32]  asked reads
//     gpio[15]     1                   gpio[47]     1
//     gpio[30:16]  answered writes     gpio[62:48]  asked writes
//     gpio[31]     0                   gpio[63]     0
//
// so that each of the two registers reads `(w & 0x80008000) == 0x00008000`
// when the fabric is driving it and cannot read that when it is not.
//
// **THE MARKER IS NOT DECORATION, AND IT WAS MEASURED RATHER THAN FORESEEN.**
// Run against a `DDR=0` bitstream --- a board with no tally in it at all ---
// both registers read `0xFFFFFFFF`, because with the level shifters on and
// nothing in the fabric driving the EMIO pins the processing system reads
// them as ALL ONES.  With the shifters off they read all zeros.  So an absent
// instrument reads exactly like four SATURATED counters, and all-ones is a
// value this module can legitimately produce; the two would have been
// indistinguishable, and the failure would have been reported as "the machine
// asked 65,535 times".  That is CLAUDE.md's never-written-DDR entry in a new
// place: a value that means nothing must not be a value the thing can mean.
// The marker makes the register say who wrote it.
//
// THE COUNTERS SATURATE FOR THE OTHER HALF OF THE SAME REASON.  The boot PROM
// asks 512 times and never again, so the reading stands at 256 of each for
// ever; a program that asked more than 32,767 times would wrap, and a wrapped
// counter reading a small number is a false negative of the exact kind this
// module exists to rule out.  CLAUDE.md's `-XBUS.RQ` entry is the same fact
// from the other side: a counter that wraps tells a lie no trace has a column
// to catch.
//
// AND THE PACKING IS HERE AND NOT IN THE TOP LEVEL, which is where it was
// written.  `rtl/cadr_arty.sv` cannot be simulated, so a field placed one bit
// over there is held by lint and by nothing else --- and a tally read at the
// wrong offset is a number that looks like a measurement.  In the module,
// `tb/cadr_mem_count_tb.cpp` reads the same sixty-four bits the debugger
// reads and unpacks them the same way.
//
// WHAT A MUTATION CAN AND CANNOT REACH HERE, so that nobody files a hole
// against a check doing its job.  The B and R channels are the only port
// signals this module is given, so it is structurally unable to count a
// request in place of an answer *at the port* --- there is no `AWVALID` here
// to count.  What it can do is take the machine-side request it already has,
// and `mutations/list.txt`'s `the-request-is-counted-as-a-write-answered` is
// exactly that: the false witness, written down, and caught by the
// configuration whose port never answers.  Ignoring a single term of a
// handshake --- `bready`, `rready`, `rlast` --- is an EQUIVALENCE against a
// protocol-correct slave with one transaction outstanding, measured rather
// than argued, because none of those signals is ever asserted without the
// others; the mutation that bites is dropping the slave's `valid` and counting
// the master's wait, which is in the list for both channels.
//
// AND THE TWO DIRECTIONS CANNOT BE TOLD APART BY THE PROGRAM.  The boot PROM
// reads page 0 and writes it straight back, 256 of each, so a tally with its
// `answered` counters swapped reads 256 and 256 exactly as a correct one
// does.  What separates them is a port that answers reads and never
// acknowledges a write, which is the third configuration
// `tb/cadr_mem_count_tb.cpp` runs and the only one in which the two numbers
// differ at all.

`default_nettype none

module cadr_mem_count (
    input  var logic clk,
    // THE MACHINE'S RESET AND NOT THE PORT'S.  `rtl/cadr_arty.sv` holds the
    // adapter in reset until `SAXIHP0ARESETN` says `S_AXI_HP0` can answer, and
    // a tally cleared by that would erase its own evidence the moment anybody
    // wrote LVL_SHFTR_EN --- and would read `0 asked` on a dead port, which is
    // the one reading that must mean something else.
    input  var logic rst,

    // The requester's side, which is `mem_req` on the board this exists for
    // and `rtl/cadr_prove.sv`'s on a `PROVE` one: a level held up until the
    // word is done or the interface has timed the cycle out.
    input  var logic req,
    input  var logic req_write,

    // The port's side: the processing system's own answers.  `S_AXI_HP0`
    // speaks AXI3 and every transaction here is one beat, so `rlast` is
    // always the first beat's --- it is in the term because a counter of read
    // transactions counts last beats, not beats.
    input  var logic bvalid,
    input  var logic bready,
    input  var logic rvalid,
    input  var logic rready,
    input  var logic rlast,

    // The sixty-four EMIO GPIO bits, laid out as the header tabulates them.
    // One output and not four, because what a debugger reads is one word and
    // the two descriptions of a layout drift.
    output var logic [63:0] gpio
);

  // Not a parameter: the width is 64 EMIO bits divided four ways with a
  // marker bit in each field, and it is not a knob anybody may turn.
  localparam int unsigned WIDTH = 15;

  logic [WIDTH-1:0] asked_reads, asked_writes;
  logic [WIDTH-1:0] answered_reads, answered_writes;

  // Bit 15 of each register set and bit 31 clear: a pattern neither an
  // all-ones nor an all-zeros reading can produce.
  assign gpio = {1'b0, asked_writes,    1'b1, asked_reads,
                 1'b0, answered_writes, 1'b1, answered_reads};

  logic req_q, started;
  assign started = req && !req_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      req_q           <= 1'b0;
      asked_reads     <= '0;
      asked_writes    <= '0;
      answered_reads  <= '0;
      answered_writes <= '0;
    end else begin
      req_q <= req;
      if (started && !req_write && !(&asked_reads)) begin
        asked_reads <= asked_reads + 1;
      end
      if (started && req_write && !(&asked_writes)) begin
        asked_writes <= asked_writes + 1;
      end
      if (rvalid && rready && rlast && !(&answered_reads)) begin
        answered_reads <= answered_reads + 1;
      end
      if (bvalid && bready && !(&answered_writes)) begin
        answered_writes <= answered_writes + 1;
      end
    end
  end

endmodule

`default_nettype wire
