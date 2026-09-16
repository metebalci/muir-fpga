// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One memory port, several masters, one word at a time, and the machine first.
//
// WHO ASKS.  The Arty A7-100 has one memory controller and four things that
// want it.  Index 0 is the machine's own port, or the proving witness in its
// place.  The others are the debugger's JTAG window, `cadr_jtag_mem.sv`; the
// disk pack face's own master, `cadr_disk_pack.sv` through `cadr_hp2_mem.sv`,
// which is `S_AXI_HP2` on a Zynq; and the soft processing system's window
// onto DDR, a target of `cadr_soc_axi.sv`.  Every one of them speaks the
// `mem_*` handshake: a level held up until the answer, and the answer standing
// until the level falls.
//
// WHERE THE ZYNQ DOES THIS, AND HOW IT DIFFERS.  On the Arty Z7-20 the machine
// reaches DDR through `S_AXI_HP0` and the pack face through `S_AXI_HP2`, and
// the two meet only inside the processing system's DDR controller, on two of
// its ports, interleaved by the controller at its own discretion.  The
// machine's claim there rests on measurement: arbitration inside a hard block
// costs tens of nanoseconds against a bus that allows 4,250.  Here the
// controller is the generated one in the fabric, it has one user interface,
// and the arbitration is this file's.  So the machine's claim rests on
// construction instead, and `tb/cadr_a7_mem_tb.cpp` measures it.
//
// **THE MACHINE WINS, AND IT WINS PER WORD.**  Whenever the port is free and
// the machine is asking, the machine is served.  Nothing is taken back once
// it has started, because a request half made to a DDR3 controller cannot be
// withdrawn, so a machine cycle that arrives while another master's word is in
// flight waits for that one word and no more.  The others take turns among
// themselves, the last one served going to the back, so none of them can hold
// the port while another waits.  A block the disk moves is 259 words, and the
// machine can step in between any two of them.  This is the argument
// `cadr_memory_path.sv`'s channel arbiter makes on the Zynq, with the
// processor winning every word, and it is held here by the same kind of check:
// the machine's own cycles timed with nobody else asking and again with the
// disk and the window streaming, and no cycle allowed to grow by more than one
// access.
//
// **AND THE DEBUGGER'S WINDOW GAVE UP ITS OWN ARBITER TO THIS ONE.**  It used to
// sit in front of the port and let the machine win there.  Kept, with this
// module behind it, a machine cycle could wait for a JTAG transaction that was
// itself waiting for a disk word: two accesses, where one is the bound.  One
// arbiter with every master in front of it is what makes the bound hold in
// every case rather than in the ones anybody thought of.
//
// **THE PORT IS LEFT IDLE BETWEEN OWNERS.**  After an owner lets go, the next
// one is not chosen until the answer has fallen, and the crossing behind this
// takes a new request only once its own acknowledgment has cleared as well.
// So no owner can be handed the previous owner's answer, and the answer each
// requester sees is gated by whose turn it is.  The Zynq's arbiter met this
// fault once already, and its bus idles a tick at every change of owner for
// the same reason.
//
// **THE WAIT FOR THE ANSWER TO FALL IS BELT AND BRACES, MEASURED.**  With it
// removed `tb/cadr_a7_mem_tb.cpp` stays green, because `cadr_mem_cross.sv`
// drops its own request at the same edge this module sees the owner let go,
// and its answer is that request ANDed with its acknowledgment.  The wait stays
// so that the promise is this file's and not a property of its neighbor, and
// `mutations/list.txt` records the equivalence beside this module's records.
//
// WHY IN THE MACHINE'S CLOCK.  All the masters are in it already: the soft
// system's window arrives there through `cadr_soc_cross.sv`, and the pack face
// and the JTAG window run on the machine's tick.  Arbitrating here keeps one
// crossing into the controller's user clock, `cadr_mem_cross.sv`, which is
// constrained and checked, rather than adding a crossing a master.
//
// THE SELECT IS A REGISTER.  The payload multiplexer is steered by `owner`,
// which is chosen a tick before the request goes out, so no request level and
// no comparison ripples into the address the crossing captures.  The bus's own
// 80 ns contract, `boards/arty-a7-100/cadr_a7_ddr.xdc`, starts at the machine's
// registers for that reason and leaves this select timed at one tick.
//
// NO muir REFERENCE EXISTS FOR THIS, as none exists for any DDR controller.  It
// is held to the handshake and to a bound with a number in it.

`default_nettype none

module cadr_mem_share #(
    // How many masters.  Index 0 is the one with priority.
    parameter int unsigned N = 4
) (
    input  var logic                 clk,
    input  var logic                 rst,

    // ---------------------------------------------------- the masters' side
    input  var logic [N-1:0]         req,
    input  var logic [N-1:0]         write,
    input  var logic [N-1:0][31:0]   addr,
    input  var logic [N-1:0][31:0]   wdata,
    // One bit a master, up only while that master owns the port and the
    // answer stands.  The word and the flag are shared: they mean something
    // only beside a master's own `done`.
    output var logic [N-1:0]         done,
    output var logic [31:0]          rdata,
    output var logic                 error,

    // ------------------------------------------------------ the one port
    output var logic                 p_req,
    output var logic                 p_write,
    output var logic [31:0]          p_addr,
    output var logic [31:0]          p_wdata,
    input  var logic                 p_done,
    input  var logic [31:0]          p_rdata,
    input  var logic                 p_error,

    // Who has the port, for a check to watch.  `busy` is up from the choice
    // until the answer has fallen.
    output var logic                 busy,
    output var logic [$clog2(N)-1:0] owner
);

  localparam int unsigned OW = $clog2(N);

  typedef enum logic [1:0] {
    FREE,     // nobody has the port and the last answer has gone
    ASK,      // the owner's request is out, or its answer is standing
    LET_GO    // the owner has let go; waiting for the answer to fall
  } state_e;

  state_e        st;
  logic [OW-1:0] last;    // the last of the others to have had the port
  logic [OW-1:0] pick;
  logic          any;

  // Who is next.  The machine if it is asking; otherwise the first of the
  // others to be asking, counting on from the one served last.
  always_comb begin
    logic [OW-1:0] c;
    pick = '0;
    any  = 1'b0;
    c    = '0;
    if (req[0]) begin
      any = 1'b1;
    end else begin
      for (int unsigned k = 1; k < N; k++) begin
        c = OW'(1 + ((32'(last) - 1 + k) % (N - 1)));
        if (!any && req[c]) begin
          pick = c;
          any  = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st    <= FREE;
      owner <= '0;
      last  <= OW'(N - 1);
    end else begin
      unique case (st)
        FREE: if (any) begin
          owner <= pick;
          st    <= ASK;
        end
        ASK: if (!req[owner]) st <= LET_GO;
        LET_GO: if (!p_done) begin
          if (owner != '0) last <= owner;
          st <= FREE;
        end
        default: st <= FREE;
      endcase
    end
  end

  assign busy    = (st != FREE);
  assign p_req   = (st == ASK) && req[owner];
  assign p_write = write[owner];
  assign p_addr  = addr[owner];
  assign p_wdata = wdata[owner];

  always_comb begin
    done        = '0;
    done[owner] = (st == ASK) && p_done;
  end
  assign rdata = p_rdata;
  assign error = p_error;

endmodule

`default_nettype wire
