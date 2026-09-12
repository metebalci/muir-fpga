// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The bus interface's own Unibus registers: the interrupt block at
// `0o766040`-`0o766076` and the Unibus map at `0o766140`-`0o766176`.
//
// The 74S133 at UBCYC 0E08 decodes `0o766000` to `0o766176` and the 74S139 at
// 0E07 splits it four ways on address bits 6 and 5.  MIT's `unaddr.text` lists
// the four the same way: "CADR UNIBUS interrupt status" at `766040`, "CADR
// XBUS error status" at `766044`, "Debuggee's selected UNIBUS location" from
// `766100`, and "`XBUS<->UNIBUS` mapping registers" at `766140`-`766176`.
// Two of the four are here.
//
//   - the DIAGNOSTIC block is `rtl/machine/cadr_spy_registers.sv` and has
//     been since the console;
//   - the DEBUG block is a cycle on the OTHER machine's Unibus, answered over
//     the cable by that machine.  muir's `busint::register` gives it `None`
//     for exactly that reason and so does the decode below: a slave here that
//     answered `0o766100` would be answering for a machine that is not there.
//     **In the composed machine those four addresses therefore time out**,
//     where muir's `Responder::Debug` with no cable answers at `-UB MSYN` off
//     the pull-up on `DEBUG OUT ACK`.  That is a divergence of the cable's
//     absence and not of this module, and it goes when the cable's side is
//     built.
//
// **WHY THIS IS A MODULE AND NOT MORE OF `cadr_spy_registers.sv`.**  The two
// answer with the same register cycle --- `busint::DIAGNOSTIC_NS` after
// `-UB MSYN`, the write landing at `REGISTER_STROBE_NS` --- so the timing
// shell below is that file's a second time, which is a duplication worth
// naming.  What is not duplicated is anything else: every one of the
// diagnostic sixteen is the PROCESSOR's own state, read back over
// `spy_eadr`/`spy_rdata` and written to the console's three registers, while
// none of these is.  These are pages UBINTC, REQERR and UBMAP; that file is
// page DIAG.  The alternative was to rename that module and widen it, which
// moves every source list, every harness and every mutation record aimed at
// it; the constant is shared instead, under muir's own name in both files, so
// a mutation on either is caught by that file's own check.
//
// **THE MATCH IS HELD, NEVER COMPUTED.**  `rtl/machine/cadr_io_board.sv`'s
// header carries the measurement: the disk controller's first draft matched
// combinationally and carried the map's ripple into `-MEMACK`/`-LOADMD` and so
// into the countdowns' clock enables, -6.195 ns on 1,065 endpoints.  So `sel`,
// `in_int`, `in_map`, `which`, `mapk` and `wr` are taken from `ub_addr` into
// registers every tick and nothing downstream ever sees the address.  The earliest answer this block can
// give is fifty ticks after `-UB MSYN`, so a match a tick behind the strobe is
// forty-nine ticks early and the hold is free --- and the counter starts on
// `ub_msyn` alone, so a master that puts the address up on the tick of the
// strobe, which is what `golden/src/busint_regs.rs` is, is served.
//
// **THAT MAKES THE HOLD A TIMING FACT AND NOT A BEHAVIOURAL ONE, AND IT WAS
// MEASURED RATHER THAN ASSERTED.**  The six rewritten as `assign`s off
// `ub_addr` pass `busint_regs` over all 38,319,186 of its ticks and `unibus`
// over all 13,192,237 of its, with both summaries byte-identical.  So no
// mutation of this is live and `mutations/list.txt` records the equivalence
// rather than leaving somebody to file it as a hole.
//
// **AND THOSE SIX ARE THE ONLY REGISTERS OF THIS MODULE IN THE RELAXED SET.**
// `rtl/plumbing/xilinx7/cadr_machine.xdc` defines `slow` as every register
// minus a name list, which swallows every module written after it --- the
// trap that cost the disk controller three slices' fit figures --- so this
// module is excluded whole there and the six are put back.  That file carries
// the argument for each of the rest, and says that no fit has been run at the
// commit which added the clause.
//
// **WHAT IS HERE, REGISTER BY REGISTER.**
//
//   `766040`  the interrupt status register.  Read, it is three things at
//             once: the bits it holds, `XBUS INTR IN` live in bit 14, and the
//             interrupt TAKEN in bit 15 with its vector in bits 2 to 9.  The
//             vector field is stored by a write and does not read back on its
//             own --- the 74LS374 at UBINTC 0D17 is enabled by `UB INT` ---
//             which is muir's `Machine::interface_read` exactly.  Written, it
//             reaches `CONTROL_MASK`, `0o36001`: bit 0 and bits 10 to 13.
//             MIT: writing `766040` "writes into bits 0 and 10-13 (mask
//             36001)".
//
//   `766042`  the same register's other half, `-LOAD INT CTL2 REG`, which the
//             microcode calls `CLEAR-INTERRUPT`.  It reads as nothing --- it
//             is a write strobe and has no read select --- and a write
//             reaches `CONTROL2_MASK`, `0o101774`: the vector field and
//             `UB INT`.
//
//   `766044`  the error status register.  Read, the high byte is the Unibus
//             pulled up and reads as ones, `WRITE THROUGH ENB` is bit 7,
//             `-FREE` is bit 6 and reads SET --- the interface is busy with
//             the read that is fetching it --- and the two NXM bits are below.
//             Written, it is `-RESET ERR`: "Writing this location ignores the
//             data written and clears the status bits", all but bit 7, which
//             the 74S74 at UBCYC 0B08 clocks from data bit 7.
//
//   `766046`  decoded, and wired to nothing.  It answers and reads zero.
//
//   `766140`  sixteen 29701s at UBMAP 0E12-0E15, read back through the
//   `-766176` 74LS244s at 0E16 and 0E17.  Sixteen bits each, stored and read
//             back and nothing else: **the one master that WALKS them is the
//             debug cable's**, `Machine::mapped_read` and `mapped_write`, and
//             the processor's own Unibus cycles are not mapped --- `busint::
//             decode` never makes a map responder for them.  So the read and
//             write buffers at RBUF and WBUF are not here either, and neither
//             is `UB MAP ERROR`, bit 5 of the register above, which only a
//             mapped cycle can set.
//
// **WITHIN THE INTERRUPT BLOCK THE FOUR REPEAT EVERY EIGHT BYTES.**  The
// 74S138 at 0E03 looks at address bits 2 and 1 alone, so `0o766050` is
// `0o766040` and `0o766064` is `0o766044`, through `0o766076`.  The decode
// below is `busint::register` and `build/busint_regs.pass` sweeps it against
// that function at every one of the 262,144 addresses an eighteen-bit
// `ub_addr` can carry.
//
// **AND `0o766077` AND `0o766177` ARE DECODED BY NOBODY**, because muir's own
// ranges end at the even address.  Nothing can tell: bit 0 of a Unibus address
// is always zero, the master's `UAO<17:1>` dropping it, so no cycle reaches
// one.  muir is the reference and this follows it; the trace's `IFACENONE`
// runs are where the claim lives.
//
// **WHAT THIS CLOSES.**  `rtl/machine/cadr_memory_path.sv` used to say that
// the card's interrupt request could not be joined into `-XBUS.INTR`, because
// muir takes it only under `ENABLE UB INTS` and that bit had no register to
// live in.  It has one now: `ub_int` below is `Machine::unibus_interrupt`,
// and `cadr_machine.sv` makes `sintr_o` the OR of it with the Xbus line, as
// `LM INT` is `UB INT OR XBUS INTR IN` at UBINTC 0E04.
//
// And it closes the first of the two defects behind the interrupt storm.
// Microcode 323's handler reads `766040` and branches on bit 1, `LOCAL
// ENABLE`, a jumper pulled up on the board: clear, it takes `INNL0` and the
// PDP-11-arbitrating path, which falls through to `XB-INTR-RET` and never
// reaches `INTRX0`, the only code that clears an Xbus level.  Unanswered,
// that read gives MD zero and the bit is clear.  Answered, it is set, and the
// handler takes the branch MIT wrote for a machine that arbitrates its own
// Unibus.

`default_nettype none

module cadr_busint_regs (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- the Unibus, as a slave sees it
    input  var logic        ub_msyn,      // -UB MSYN, the master's strobe
    input  var logic        ub_write,
    input  var logic [17:0] ub_addr,      // the Unibus address
    input  var logic [15:0] ub_wdata,     // UDI<15:0> from the master
    output var logic        ub_ssyn,      // -UB SSYN: this block answers
    output var logic [15:0] ub_rdata,

    // --- `XBUS INTR IN`, the backplane's own interrupt line, live.  It is
    // read in bit 14 of the interrupt status register and is not stored.
    input  var logic        xbus_intr,

    // --- the I/O board's request and the vector it is asking with, which
    // `rtl/machine/cadr_io_board.sv` brings out as `intr_request` and
    // `intr_vector`.  Nothing in this fabric runs a Unibus interrupt CYCLE ---
    // no grant chain, no `BR5`, no vector on the bus --- so the vector arrives
    // on a wire where the board reads it off `UDI<9:2>` at the grant.  muir
    // does the same and says why: "The model has no grant cycle to latch at,
    // so the vector is read off the requesting board at the time of the read:
    // the same value, since the request holds until the microcode has read the
    // device's data."
    input  var logic        iob_intr,
    input  var logic [7:0]  iob_vector,

    // --- the interface's own cycles, for the error status register.
    // `timed_out` is `NXM TIMEOUT` as `cadr_busint_xbus.sv` gives it, a level
    // that stands for the cycle it belongs to; `unibus` is the held decode,
    // which says which of the two NXM bits that cycle sets.
    input  var logic        timed_out,
    input  var logic        unibus,

    // --- `UB INT`: a Unibus interrupt taken, or simulated by writing the bit.
    // `cadr_machine.sv` ORs it with the Xbus line into `SINTR`.
    output var logic        ub_int
);

  // busint::DIAGNOSTIC_NS and REGISTER_STROBE_NS, the same two instants
  // `cadr_spy_registers.sv` answers on: this is one register cycle on the
  // board and the block select is shared.
  localparam int unsigned SSYN_T   = 250 / 5;
  localparam int unsigned STROBE_T = 150 / 5;

  // busint::interrupt_status and busint::error_status.
  localparam logic [15:0] LOCAL_ENABLE  = 16'o000002;
  localparam logic [15:0] VECTOR_MASK   = 16'o001774;
  localparam logic [15:0] ENABLE_UB_INTS = 16'o002000;
  localparam logic [15:0] XBUS_INTR     = 16'o040000;
  localparam logic [15:0] UB_INT        = 16'o100000;
  localparam logic [15:0] CONTROL_MASK  = 16'o036001;
  localparam logic [15:0] CONTROL2_MASK = 16'o101774;

  // busint::register's two ranges, which end at the even address.
  localparam logic [17:0] INT_LOW  = 18'o766040;
  localparam logic [17:0] INT_HIGH = 18'o766076;
  localparam logic [17:0] MAP_LOW  = 18'o766140;
  localparam logic [17:0] MAP_HIGH = 18'o766176;

  // ------------------------------------------------------------- the decode
  //
  // Combinational here and registered below; nothing downstream sees these.
  logic in_int_c, in_map_c;
  assign in_int_c = (ub_addr >= INT_LOW) && (ub_addr <= INT_HIGH);
  assign in_map_c = (ub_addr >= MAP_LOW) && (ub_addr <= MAP_HIGH);

  logic        sel, in_int, in_map, wr;
  logic [1:0]  which;   // UBA<2:1>, which of the interrupt block's four
  logic [3:0]  mapk;    // UBA<4:1>, which of the map's sixteen

  // ------------------------------------------------------- the interrupt taken
  //
  // `Machine::unibus_interrupt`: a bit written by hand stands until it is
  // written clear and carries the vector the same write put there; otherwise
  // the card's request is taken while `ENABLE UB INTS` is set, with the
  // card's own vector.  A Unibus vector is a multiple of four, so the field
  // holds it unshifted and `VECTOR_MASK` takes nothing real out of it.
  logic [15:0] int_status;
  logic [15:0] ub_map [16];
  logic        taken_hand, taken_card;
  logic [15:0] taken_vector;
  assign taken_hand   = (int_status & UB_INT) != 16'd0;
  assign taken_card   = ((int_status & ENABLE_UB_INTS) != 16'd0) && iob_intr;
  assign ub_int       = taken_hand || taken_card;
  assign taken_vector = taken_hand ? (int_status & VECTOR_MASK)
                                   : ({8'd0, iob_vector} & VECTOR_MASK);

  // ---------------------------------------------------------- the read side
  logic        err_xbus, err_unibus, write_through;
  logic [15:0] ctl_word, err_word, word;

  // What the stored register shows of itself: everything but the three
  // things the read makes up, which are bit 14, bit 15 and the vector field.
  assign ctl_word = (int_status & ~(XBUS_INTR | UB_INT | VECTOR_MASK))
                  | (xbus_intr ? XBUS_INTR : 16'd0)
                  | (ub_int ? (UB_INT | taken_vector) : 16'd0);

  // The 74LS244 at REQERR 0C16 drives eight bits of `UDO`; the high byte is
  // the Unibus pulled up and reads as ones, measured on the netlist board.
  // `-FREE` in bit 6 reads SET because the interface is busy with this very
  // read.  Bit 5 is `UB MAP ERROR` and only a mapped cycle sets it, so it is
  // a constant zero here and the header says so.
  assign err_word = {8'hFF, write_through, 1'b1, 2'b00, err_unibus, 2'b00, err_xbus};

  always_comb begin
    if (in_map) begin
      word = ub_map[mapk];
    end else if (in_int) begin
      unique case (which)
        2'd0: word = ctl_word;
        2'd2: word = err_word;
        // `766042` is a write strobe with no read select, and `766046` is
        // decoded and wired to nothing.  Both read as zero, which is what
        // `Machine::interface_read` answers for them.
        default: word = 16'd0;
      endcase
    end else begin
      word = 16'd0;
    end
  end

  // The lines are driven only while this block is selected and reading, as a
  // slave on an open-collector bus drives them only for its own cycle: the
  // rule the DDR bridge broke by holding its word past the end of one.
  assign ub_rdata = (sel && !wr) ? word : 16'd0;

  // ------------------------------------------------------------ the bus cycle
  logic [6:0]  t_msyn;   // ticks since `-UB MSYN`, saturating
  logic        answer_now, land;

  // Saturating and never wrapping, for `cadr_io_board.sv`'s reason: `elapsed`
  // in `cadr_busint_xbus.sv` was ten bits and wrapped, and six checks and
  // sixty-three mutations passed over what that did to `-XBUS.RQ`.
  localparam logic [6:0] T_MAX = 7'd127;

  assign answer_now = sel && (t_msyn >= 7'(SSYN_T));
  // The tick the write lands, which muir puts at `REGISTER_STROBE_NS` and
  // not at the answer: `Busint`'s `answered` for a write of this block.
  assign land = ub_msyn && sel && wr && (t_msyn == 7'(STROBE_T));

  // **A TIMEOUT IS AN EDGE AND `timed_out` IS A LEVEL.**  It stands for the
  // whole of the cycle it belongs to, so the bit is set on its rise and the
  // one cycle sets one bit.
  logic timed_out_q;

  integer k;
  always_ff @(posedge clk) begin
    if (rst) begin
      sel           <= 1'b0;
      in_int        <= 1'b0;
      in_map        <= 1'b0;
      wr            <= 1'b0;
      which         <= 2'd0;
      mapk          <= 4'd0;
      ub_ssyn       <= 1'b0;
      t_msyn        <= 7'd0;
      timed_out_q   <= 1'b0;
      // `LOCAL ENABLE` is a jumper, pulled up on the board: this machine
      // arbitrates its own Unibus.  It is in neither write mask, so nothing
      // can clear it and reset is the only thing that sets it ---
      // `Machine::new` comes up at exactly this value.
      int_status    <= LOCAL_ENABLE;
      err_xbus      <= 1'b0;
      err_unibus    <= 1'b0;
      write_through <= 1'b0;
      for (k = 0; k < 16; k = k + 1) ub_map[k] <= 16'd0;
    end else begin
      // The held match: taken every tick, and the whole reason nothing
      // downstream of here ever sees `ub_addr`.
      sel    <= in_int_c || in_map_c;
      in_int <= in_int_c;
      in_map <= in_map_c;
      wr     <= ub_write;
      which  <= ub_addr[2:1];
      mapk   <= ub_addr[4:1];

      // The error flops.  `-RESET ERR` is a clear on them and the timeout is
      // a clock, so a write landing on the tick a timeout rises clears: the
      // clear pin wins, which is what the ordering here says.
      timed_out_q <= timed_out;
      if (timed_out && !timed_out_q) begin
        if (unibus) err_unibus <= 1'b1;
        else err_xbus <= 1'b1;
      end

      if (!ub_msyn) begin
        ub_ssyn <= 1'b0;
        t_msyn  <= 7'd0;
      end else begin
        if (t_msyn != T_MAX) t_msyn <= t_msyn + 7'd1;
        if (answer_now) ub_ssyn <= 1'b1;

        if (land) begin
          if (in_map) begin
            ub_map[mapk] <= ub_wdata;
          end else begin
            unique case (which)
              2'd0: int_status <= (int_status & ~CONTROL_MASK) | (ub_wdata & CONTROL_MASK);
              2'd1: int_status <= (int_status & ~CONTROL2_MASK) | (ub_wdata & CONTROL2_MASK);
              // `-RESET ERR`: "Writing this location ignores the data written
              // and clears the status bits" --- all but the one the drawings
              // clock from it.
              2'd2: begin
                err_xbus      <= 1'b0;
                err_unibus    <= 1'b0;
                write_through <= ub_wdata[7];
              end
              // `766046` is decoded and wired to nothing.
              default: ;
            endcase
          end
        end
      end
    end
  end

  logic unused;
  // `ub_addr<17:5>` and `<0>` reach nothing: the two ranges are compared
  // whole above, bit 0 is decoded nowhere in the block, and what is left
  // picks the register.  `iob_vector<1:0>` are masked off by `VECTOR_MASK`,
  // a Unibus vector being a multiple of four.
  assign unused = &{1'b0, ub_addr[17:5], ub_addr[0], iob_vector[1:0]};

endmodule

`default_nettype wire
