// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The witness for the memory port: one word, one address, and somebody
// outside the design to say whether it arrived.
//
// Nothing in this repository has ever seen the CADR's memory work.  The
// machine agrees with muir for 600,000 microcycles of boot PROM and
// 2,200,000 of a band, `cadr_axi_master.sv` is held to the AXI protocol and
// to read-back, `cadr_axi_widen.sv` to the lane and the strobes --- and every
// one of those is the design checking itself.  `cadr_ps7.sv` is the piece
// with no check of any kind: the port either answers or it does not, and no
// simulation here can tell.
//
// So before the machine is put behind real memory, two smaller steps, and
// this module is the fabric half of both.  What makes them worth doing is
// that the OBSERVER IS OUTSIDE THE DESIGN.  A debugger attached to the
// processing system reads and writes DDR through a path that shares nothing
// with this one, so a fabric that is wrong about the address, the word, the
// lane or the strobes cannot agree with it by construction.  That is
// CLAUDE.md's shadow-memory lesson applied to silicon: a check whose model
// comes from the DUT moves with the bug, and this one cannot move at all.
//
//   `writes` high    STEP TWO.  The fabric writes.  As soon as the port comes
//                    live it puts `word` at `addr` and stops.  Then somebody
//                    reads that address from the debugger, and reads its
//                    NEIGHBOURS, which is the half that catches a strobe
//                    pattern that opens both halves of the beat.
//
//   `writes` low     STEP THREE.  The fabric reads.  The debugger writes a
//                    pattern from outside, a button starts the read, and a
//                    lamp says whether what came back is `word`.  The value
//                    comes from outside so the fabric cannot be accidentally
//                    right --- and the way to prove the lamp can fail is to
//                    write something else and press again.
//
// THE ADDRESS, THE WORD AND THE DIRECTION ARE INPUTS AND NOT PARAMETERS, and
// that is a testability decision rather than a board one: on the board
// `rtl/cadr_arty.sv` ties all three to constants and the fitter propagates
// them, so the fabric is what parameters would have given.  What it buys is
// that ONE model checks both steps and can sweep the address --- every bit
// above the beat boundary taking both values, and bit 2 taking both --- which
// is what `tb/cadr_axi_widen_tb.cpp` had to do for the same reason.  A
// parameter would have meant two binaries and a check that only ever saw one
// address.
//
// IT DRIVES THE MACHINE'S OWN `mem_*` PORT AND NOT A LOOKALIKE.  Everything
// downstream of these four signals --- the adapter, the widening, the PS7
// wrapper, the constraints on all of it --- is exactly what `cadr_machine`
// will drive the day the machine goes behind real memory.  A witness that
// built its own path would prove that path and say nothing about this one.
//
// NOBODY HAS TO BE AT THE BOARD FOR STEP TWO, which is the same argument
// `cadr_probe.sv` makes for needing no arming.  `go` held high is one
// transaction and then silence: the top level ties it high for a write
// board, so the write happens once, at the moment `SAXIHP0ARESETN` says the
// port is live, whenever that is.  A read board ties `go` to a button, and
// the transaction repeats once per press --- reading is idempotent, so a
// bouncing contact costs nothing but another read.
//
// THE 80 ns SETUP IS HONOURED HERE TOO, and it is not ceremony.
// `rtl/cadr_ddr.xdc` relaxes the adapter's address and data registers to
// sixteen ticks on the strength of `cadr_busint_xbus.sv`'s `SETUP_T` --- the
// bus specification's "the responsibility of the bus master to assert good
// address, write, and data lines 80 ns. prior to asserting -XBUS.RQ".  This
// module is a bus master on that board, so it owes the same sixteen ticks; a
// witness that raised `mem_req` in the same tick as the address would make
// that constraint a claim about a board where it is false.

`default_nettype none

module cadr_prove #(
    // Ticks between the address settling and the request going up.  Sixteen
    // is `cadr_busint_xbus.sv`'s `SETUP_T`, which is the 80 ns the bus
    // specification puts on the master at a 5 ns tick.
    parameter int unsigned SETUP_T = 16
) (
    input  var logic        clk,
    // Held while the port is dead, so this cannot start before the port can
    // answer.  On the board that is `rst || !SAXIHP0ARESETN`, synchronised.
    input  var logic        rst,

    // A level.  One transaction per rise; it must fall before another.
    input  var logic        go,

    // What to do, sampled at the start of a transaction and held for it.
    // `rtl/cadr_arty.sv` ties these to constants and says which and why.
    input  var logic [31:0] addr,
    input  var logic [31:0] word,
    input  var logic        writes,

    // The machine's own memory port, driven here instead.
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata,
    input  var logic        mem_error,

    // The verdict, for the lamp.  `has_run` is what keeps "nothing has
    // happened yet" from looking like an answer --- the same distinction LD4
    // and LD5 already make by starting red.
    output var logic        has_run,
    output var logic        matched
);

  // The countdown needs to hold SETUP_T, so it needs a bit above it.
  localparam int unsigned CW = $clog2(SETUP_T + 1);

  typedef enum logic [1:0] {
    IDLE,   // waiting for `go`
    SETUP,  // address, word and direction are up; counting out the 80 ns
    REQ,    // the request is up, waiting for the answer
    HELD    // answered; waiting for `go` to fall before another is allowed
  } state_e;

  state_e        state;
  logic [CW-1:0] count;
  // The word this transaction is about, held from the tick it started: `word`
  // is an input and the top level holds it still, but a check that swept it
  // would be comparing against whatever it had moved on to.
  logic [31:0]   want;

  assign mem_req = (state == REQ);

  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= IDLE;
      count     <= '0;
      mem_write <= 1'b0;
      mem_addr  <= 32'd0;
      mem_wdata <= 32'd0;
      want      <= 32'd0;
      has_run   <= 1'b0;
      matched   <= 1'b0;
    end else begin
      unique case (state)
        IDLE: begin
          if (go) begin
            // Loaded here and held for the whole transaction, so that the
            // sixteen ticks below are sixteen ticks of a settled address ---
            // and so that what is compared at the end is what was asked for
            // and not whatever the inputs say by then.
            mem_addr  <= addr;
            mem_wdata <= word;
            mem_write <= writes;
            want      <= word;
            count     <= CW'(SETUP_T);
            // The lamp shows the LAST COMPLETED transaction and nothing
            // else, so a new one clears it.  A read board that kept the
            // previous verdict up while the next read was in flight would
            // show green for a word the debugger had already replaced.
            has_run   <= 1'b0;
            matched   <= 1'b0;
            state     <= SETUP;
          end
        end

        SETUP: begin
          if (count == '0) state <= REQ;
          else count <= count - CW'(1);
        end

        REQ: begin
          if (mem_done) begin
            has_run <= 1'b1;
            // A WRITE IS RIGHT WHEN THE PORT SAID SO AND A READ WHEN THE WORD
            // CAME BACK.  `mem_error` is SLVERR or DECERR, which is a cycle
            // that reached the port and was refused --- a different fault
            // from a wrong word, and one that must not read as a match.
            // Whether the word is right is not a question this fabric can
            // answer about its own write; that is what the debugger is for.
            matched <= !mem_error && (mem_write || (mem_rdata == want));
            state   <= HELD;
          end
        end

        // The adapter holds its answer until the request drops, exactly as
        // `cadr_xbus_ddr.sv` does, so the request drops here and the wait for
        // `go` happens afterwards.
        HELD: begin
          if (!go) state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
