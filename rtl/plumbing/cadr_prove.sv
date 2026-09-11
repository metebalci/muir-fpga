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
//   `writes` low     STEP THREE.  The fabric reads --- and then WRITES BACK
//                    WHAT IT READ, to a second address.  The debugger put a
//                    word at `addr` before the port came live; the witness
//                    reads it and puts whatever came back at `echo_addr`,
//                    and stops.  The debugger then reads `echo_addr` and does
//                    the comparing itself.
//
// STEP THREE WRITES THE WORD BACK RATHER THAN LIGHTING A LAMP, and that is
// the whole difference from the first version of this file.  A lamp is the
// fabric marking its own homework: `matched` compares what came back against
// a constant THIS FABRIC HOLDS, so a witness that read the wrong lane and a
// witness that held the wrong constant agree with each other, and the lamp is
// green either way.  Writing the word out raw moves the comparison to the
// observer that already has to be there --- and a lane swap, a shift or a
// byte reversal is then visible IN THE VALUE, not merely as a colour.
//
// It also takes the person out.  The first version started the read on BTN1
// and answered on LD4, so both halves of step three needed somebody in the
// room, and the board is on the end of a JTAG cable.  Now `go` is tied high
// on both boards, the sequence starts when `SAXIHP0ARESETN` says the port is
// live, and `SAXIHP0ARESETN` follows `LVL_SHFTR_EN` at `0xF8000900` ---
// measured at 700b98a --- so writing that register 0x0 then 0xF RE-ARMS the
// witness without reprogramming.  Three cases in one debugger session.
//
// THE LAMP IS STILL THERE and it is no longer the observer.  `has_run` and
// `matched` cost nothing and a person who is at the board can read them; no
// script asserts them, because a script cannot see a lamp and because the
// value at `echo_addr` says more.
//
// THE ADDRESSES, THE WORD AND THE DIRECTION ARE INPUTS AND NOT PARAMETERS,
// and that is a testability decision rather than a board one: on the board
// `boards/arty-z7-20/cadr_arty.sv` ties all four to constants and the fitter propagates
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
// NOBODY HAS TO BE AT THE BOARD FOR EITHER STEP, which is the same argument
// `cadr_probe.sv` makes for needing no arming.  `go` held high is one
// sequence and then silence: the top level ties it high, so the sequence
// happens once, at the moment `SAXIHP0ARESETN` says the port is live,
// whenever that is, and the next one needs a reset and not a finger.
//
// THE 80 ns SETUP IS HONOURED ON BOTH TRANSACTIONS, and it is not ceremony.
// `rtl/plumbing/xilinx7/cadr_ddr.xdc` relaxes the adapter's address and data registers to
// sixteen ticks on the strength of `cadr_busint_xbus.sv`'s `SETUP_T` --- the
// bus specification's "the responsibility of the bus master to assert good
// address, write, and data lines 80 ns. prior to asserting -XBUS.RQ".  This
// module is a bus master on that board, so it owes the same sixteen ticks; a
// witness that raised `mem_req` in the same tick as the address would make
// that constraint a claim about a board where it is false.  The write-back is
// a second transaction and owes them again, which is why it re-enters `SETUP`
// rather than going straight out.

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
    // It is also the RE-ARM: dropping and raising `SAXIHP0ARESETN` from the
    // debugger runs the whole sequence again.
    input  var logic        rst,

    // A level.  One sequence per rise; it must fall before another.
    input  var logic        go,

    // What to do, sampled at the start of a sequence and held for it.
    // `boards/arty-z7-20/cadr_arty.sv` ties these to constants and says which and why.
    input  var logic [31:0] addr,
    input  var logic [31:0] word,
    // Where a read puts what came back.  Ignored when `writes` is high.
    // It must not share a 64-bit beat with `addr`, or the write-back would
    // overwrite the thing it read; `boards/arty-z7-20/cadr_arty.sv` chose one that does
    // not and says why.
    input  var logic [31:0] echo_addr,
    input  var logic        writes,

    // The machine's own memory port, driven here instead.
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata,
    input  var logic        mem_error,

    // The verdict, for the lamp, and for nothing else --- see the header.
    // `has_run` is what keeps "nothing has happened yet" from looking like an
    // answer, the same distinction LD4 and LD5 already make by starting red.
    output var logic        has_run,
    output var logic        matched
);

  // The countdown needs to hold SETUP_T, so it needs a bit above it.
  localparam int unsigned CW = $clog2(SETUP_T + 1);

  typedef enum logic [1:0] {
    IDLE,   // waiting for `go`
    SETUP,  // address, word and direction are up; counting out the 80 ns
    REQ,    // the request is up, waiting for the answer
    HELD    // done; waiting for `go` to fall before another is allowed
  } state_e;

  state_e        state;
  logic [CW-1:0] count;
  // The word this sequence is about, held from the tick it started: `word`
  // is an input and the top level holds it still, but a check that swept it
  // would be comparing against whatever it had moved on to.
  logic [31:0]   want;
  // And the second address, held for the same reason.
  logic [31:0]   echo;
  // The write-back is still to come.  Set at the start of a read and cleared
  // when the write-back is loaded, so a sequence is EXACTLY two transactions
  // and never three.
  logic          echo_due;
  // Nothing in this sequence has disagreed yet.  It starts high and only a
  // read can lower it, so a write board --- which has no read --- leaves it
  // alone and `matched` is then the port's own answer and nothing more.
  logic          read_agreed;

  assign mem_req = (state == REQ);

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= IDLE;
      count       <= '0;
      mem_write   <= 1'b0;
      mem_addr    <= 32'd0;
      mem_wdata   <= 32'd0;
      want        <= 32'd0;
      echo        <= 32'd0;
      echo_due    <= 1'b0;
      read_agreed <= 1'b1;
      has_run     <= 1'b0;
      matched     <= 1'b0;
    end else begin
      unique case (state)
        IDLE: begin
          if (go) begin
            // Loaded here and held for the whole sequence, so that the
            // sixteen ticks below are sixteen ticks of a settled address ---
            // and so that what goes out at the end is what was asked for
            // and not whatever the inputs say by then.
            mem_addr    <= addr;
            mem_wdata   <= word;
            mem_write   <= writes;
            want        <= word;
            echo        <= echo_addr;
            // A read owes a write-back and a write does not.
            echo_due    <= !writes;
            read_agreed <= 1'b1;
            count       <= CW'(SETUP_T);
            // The lamp shows the LAST COMPLETED sequence and nothing
            // else, so a new one clears it.  A read board that kept the
            // previous verdict up while the next read was in flight would
            // show green for a word the debugger had already replaced.
            has_run     <= 1'b0;
            matched     <= 1'b0;
            state       <= SETUP;
          end
        end

        SETUP: begin
          if (count == '0) state <= REQ;
          else count <= count - CW'(1);
        end

        REQ: begin
          if (mem_done) begin
            if (echo_due) begin
              // THE READ CAME BACK.  What it brought is the payload of the
              // write-back --- raw, whatever it is --- because the observer
              // outside is the one that gets to say whether it is right.  A
              // fabric that substituted its own `want` here would write the
              // answer out no matter what the memory returned, which is the
              // lamp's failure mode with the lamp removed.
              //
              // Whether it AGREES is recorded too, for the lamp alone.  A
              // read that came back SLVERR or DECERR reached the port and
              // was refused, which is a different fault from a wrong word.
              read_agreed <= !mem_error && (mem_rdata == want);
              mem_addr    <= echo;
              mem_wdata   <= mem_rdata;
              mem_write   <= 1'b1;
              echo_due    <= 1'b0;
              // The write-back is a transaction of its own and owes the bus
              // the same 80 ns the first one did.
              count       <= CW'(SETUP_T);
              state       <= SETUP;
            end else begin
              has_run <= 1'b1;
              // Every transaction in the sequence had to be accepted, and a
              // read had to bring back the word wanted.  A write is right
              // when the port said so; whether the word is right is not a
              // question this fabric can answer about its own write, and
              // that is what the debugger is for.
              matched <= read_agreed && !mem_error;
              state   <= HELD;
            end
          end
        end

        // The adapter holds its answer until the request drops, exactly as
        // `cadr_xbus_ddr.sv` does, so the request drops here and the wait for
        // `go` happens afterwards.  With `go` tied high on the board this is
        // where the witness stays until the port is reset.
        HELD: begin
          if (!go) state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
