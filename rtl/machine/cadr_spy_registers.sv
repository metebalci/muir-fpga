// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The diagnostic register block: the sixteen registers at Unibus `0o766000`,
// which is `Responder::Interface` in muir and the console's whole vocabulary.
//
// These are the registers a CADR is *started* through.  `0o766012` is the mode
// register, and writing it is how the boot PROM turns itself off --- which is
// where the composed machine stopped before this existed, at microcycle
// 537,846 of the boot PROM, not on anything to do with the disk.
//
// **Three of them are written and all sixteen are read.**  The written ones
// are the machine's console state and live here: the mode register at OLORD1
// 1A09, the clock control register --- `RUN` in the 74S74 at 1A14 and the
// other four in the 74S175 at 1A09 --- and the OPC control register at 1A08.
// The read ones are almost all the *processor's* state: IR, PC, OPC, OB, the
// A and M buses, the statistics counter and two words of flags.  That state
// stays in the processor and comes back over `spy_eadr`/`spy_rdata`, which is
// `Engine::spy_read` on muir's side: four bits out, sixteen back.
//
// THE TIMING IS THE UNIBUS'S AND NOT THIS BOARD'S CHOICE.  A slave gives the
// word with `-UB SSYN` and takes one at `-UB MSYN`; for these registers that
// is `DIAGNOSTIC_NS` after MSYN either way, with the write landing earlier, at
// `REGISTER_STROBE_NS` --- and `-PROG.RESET` and `PROG.BOOT` earlier still, at
// the *leading* edge of that write pulse, `REGISTER_PULSE_NS` before the
// register loads.  The processor depends on that gap: a mode-register write
// carrying `PROG.BOOT` has to reach `BOOT.TRAP` before the edge that ends the
// microcycle, and the speed synchronizer samples the register sixty
// nanoseconds into every generator cycle.
//
// WHAT IS NOT HERE.  The other Unibus slaves.  Two of them are modules beside
// this one now --- `cadr_io_board.sv` is the card and `cadr_busint_regs.sv`
// the bus interface's own interrupt block and Unibus map, which are
// `Responder::Interface` as these sixteen are --- and two are not built: the
// Chaosnet interface, which is the card's own group and a slice of its own,
// and the debug block, which is a cycle on the other machine's Unibus and is
// answered over a cable.  These sixteen are the ones this machine cannot
// start without.

`default_nettype none

module cadr_spy_registers (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- the Unibus, as a slave sees it
    input  var logic        mclk,         // MCLK7, the microcycle boundary
    input  var logic        ub_msyn,      // -UB MSYN, the master's strobe
    input  var logic        ub_write,
    input  var logic [17:0] ub_addr,      // the Unibus address
    input  var logic [15:0] ub_wdata,     // SPY<15:0> from the master
    output var logic        ub_ssyn,      // -UB SSYN: this slave answers
    output var logic [15:0] ub_rdata,

    // --- the processor's own state, read but never written here
    output var logic [3:0]  spy_eadr,     // EADR<3:0>, which register
    input  var logic [15:0] spy_rdata,

    // --- the console state, which is this block's
    output var logic        run,          // RUN, before OLORD1 1A10 registers it
    // The other four bits of the clock control register: the 74S175 at OLORD1
    // 1A09 beside `RUN`'s own 74S74 at 1A14.  MIT's `ir.bits` numbers them in
    // OCTAL --- 1 Run, 2 Step, 4 NOP, 10 IDEBUG, 20 LDSTAT --- so CC's
    // `CC-CLOCK` writes 2, `CC-DEBUG-CLOCK` 12 and `CC-NOOP-DEBUG-CLOCK` 16,
    // all octal.  Reading that 16 as decimal gives LDSTAT alone, which loads
    // the statistics counter and clocks nothing.
    output var logic        step,         // STEP, bit 1
    output var logic        nop11,        // NOP11, bit 2
    output var logic        idebug,       // IDEBUG, bit 3
    output var logic        ldstat,       // LDSTAT, bit 4
    // The debug IR, the six 74S374s on page DEBUG, loaded sixteen bits at a
    // time by `-LDDBIRL`, `-LDDBIRM` and `-LDDBIRH` --- EADR 0, 1 and 2,
    // which are also the three registers that READ `IR`.  "Read and write at
    // the same address are uncorrelated", as the interface's own document
    // says, and this is where that bites.
    output var logic [47:0] debug_ir,
    output var logic        promdisable,  // PROMDISABLE, mode register bit 5
    output var logic        errstop,      // ERRSTOP, bit 2
    output var logic        stathenb,     // STATHENB, bit 3
    output var logic [1:0]  mode_speed,   // {SPEED1, SPEED0}, bits 1 and 0
    output var logic        prog_reset,   // -PROG.RESET, a pulse
    output var logic        prog_boot,    // PROG.BOOT, a pulse
    // **`-BOOT`, WHICH THIS BLOCK IS ONE OF THE TWO TAKERS OF.**  The 74S02
    // at OLORD2 1A07 makes it out of the keyboard's `-BOOT1`, the light
    // panel's `-BOOT2` and the debug cable's `PROG.BOOT`; `cadr_machine.sv`
    // has the gate.  Here it does the two things the OLORD1 page does with
    // it: it PRESETS `RUN` at the 74S74 at 1A14, and it is one of the three
    // inputs of `RESET` at the 74S10 at 1C08, which is the CLEAR pin of both
    // 74S175s --- the mode register at 1A08 with `PROMDISABLE` in it, and the
    // clock control register's other four bits at 1A09.
    //
    // So a boot leaves this block exactly as `rst` does, which is the same
    // fact the reset arm below already states: the fabric's reset IS the boot
    // button held.  What was missing was a way to press it while the fabric
    // runs, and these three lines are it.
    input  var logic        n_boot,

    // **THE NO-AUTO-BOOT SWITCH, AND THE ONE INSTANT IT IS READ AT.**  A CADR
    // whose power has just come on has `RUN` clear and is running nothing: the
    // boot button is what starts it, and until somebody presses it the machine
    // sits there.  The reset arm below is where this fabric decides which of
    // the two states it comes up in, so the switch is read THERE and nowhere
    // else --- which is what makes it a power-on condition rather than a
    // control.  High leaves `RUN` clear; low leaves it preset, which is what
    // every trace here and every bring-up board starts from.
    //
    // **IT IS A LEVEL AND IT IS SAMPLED, AND THE DIFFERENCE IS THE WHOLE
    // BEHAVIOR.**  Nothing outside the reset arm looks at it, so flipping the
    // switch under a running machine does nothing at all until the next fabric
    // reset --- a machine that stopped mid-instruction because somebody moved a
    // switch would be a control the CADR never had.  And `-BOOT` still presets
    // `RUN` below whatever this says, because the button is what takes the hold
    // off: that is the whole point of holding the machine at the button.
    //
    // `boards/arty-z7-20/cadr_arty.sv` drives it from SW0, synchronized; the
    // console reports both this level and the value the machine came out of
    // reset with.  muir's own `--no-auto-boot` is the same state by the same
    // argument.
    input  var logic        no_auto_boot
);

  // busint::DIAGNOSTIC_NS, REGISTER_STROBE_NS and REGISTER_PULSE_NS.
  localparam int unsigned SSYN_T   = cadr_tick_pkg::ticks(250);
  localparam int unsigned STROBE_T = cadr_tick_pkg::ticks(150);
  localparam int unsigned PULSE_T  = cadr_tick_pkg::ticks(150 - 100);

  // spy::BASE and the sixteen registers above it, two apart.
  localparam logic [17:0] BASE = 18'o766000;

  logic selected;
  assign selected = (ub_addr >= BASE) && (ub_addr < BASE + 18'o40);
  assign spy_eadr = ub_addr[4:1];

  // spy::MODE, spy::CLK and the three halves of the debug IR.
  localparam logic [3:0] REG_IR_LOW  = 4'd0;
  localparam logic [3:0] REG_IR_MED  = 4'd1;
  localparam logic [3:0] REG_IR_HIGH = 4'd2;
  localparam logic [3:0] REG_CLK     = 4'd3;
  localparam logic [3:0] REG_MODE    = 4'd5;

  logic [8:0] elapsed;
  logic       running;

  // **THE WRITE LANDS WHERE THE MACHINE NEXT LOOKS, NOT AT THE STROBE.**
  // `Rtl::land_write` is called at the microcycle boundary and again
  // `SPEEDCLK_NS` into every generator cycle --- the second because the speed
  // synchronizer samples the mode register there --- and the register takes
  // its word at the first of those instants at or after the strobe. So a
  // write whose strobe falls just after a boundary waits for the next
  // opportunity, which is up to a microcycle away. Applying it at the strobe
  // instead sets PROMDISABLE a microcycle early, measured on the band at
  // 1,410,034 against muir's 1,410,035.
  //
  // **AND AT SPEEDCLK THE WORD LANDS BEFORE THE SYNCHRONIZER TAKES IT.**
  // muir's step calls `land_write` at `SPEEDCLK_NS` and then `speedclk`, so a
  // speed written by then is the one the synchronizer shifts in at that same
  // instant.  The synchronizer in `cadr_microcycle.sv` shifts on the edge
  // that is SPEEDCLK, the end of the tick its `phase_t` reads five; this
  // counter reads one less than that one over the same ticks (it starts at
  // zero on the tick after the boundary, where that one starts at one), so
  // SPEEDCLK's edge ends this counter's tick four, and the word has to be in
  // the register on the edge before it: tick three.  Landed where it used to
  // be, on this counter's tick six, a speed the processor wrote reached the
  // generator a cycle after muir's, at every write phase tried
  // (`mode-speed-written-0` to `-5` in `build/dispatch_write_order.pass`).
  localparam int unsigned SPEEDCLK_T = cadr_tick_pkg::ticks(60);

  logic [5:0]  phase_t;      // ticks since the boundary
  logic        landing;      // one of the two instants is now
  logic        pending;
  logic [15:0] held;
  logic [3:0]  held_eadr;
  assign landing = mclk || (phase_t == 6'(SPEEDCLK_T) - 6'd3);

  // **A WRITE STROBED ON OR BEFORE SPEEDCLK IS SPEEDCLK'S, EVEN WHEN ITS
  // STROBE COMES AFTER THIS LANDING.**  muir lands every write whose strobe
  // is at or before the SPEEDCLK instant (`Rtl::land_write` at `now >= at`),
  // so a strobe exactly on SPEEDCLK counts as before it.  The landing above
  // is two ticks ahead of SPEEDCLK for the synchronizer's sake, and a strobe
  // on either of those two ticks has not happened yet when it lands.  The
  // strobe's tick is this slave's own count, so it is known: a strobe due on
  // this tick or the next is landed here, from the word the master holds on
  // the bus until the cycle ends, and not strobed again.  Without it a
  // speed written on SPEEDCLK reached the generator a cycle after muir's:
  // `speed-written-on-speedclk` in `build/dispatch_write_order.pass`.
  logic strobe_due, early, early_taken;
  assign strobe_due = ub_msyn && selected && ub_write && running
                   && (elapsed == 9'(STROBE_T) - 9'd1 || elapsed == 9'(STROBE_T) - 9'd2);
  assign early = !mclk && (phase_t == 6'(SPEEDCLK_T) - 6'd3) && strobe_due && !early_taken;

  logic [15:0] land_word;
  logic [3:0]  land_eadr;
  assign land_word = pending ? held : ub_wdata;
  assign land_eadr = pending ? held_eadr : spy_eadr;

  // **THE COUNT FROM -UB MSYN IS ONE SHORT OF EACH INSTANT.**  `elapsed` is
  // zero on the first tick this block sees -UB MSYN, which is the tick after
  // the edge the master raised it on, so the edge `N` ticks after -UB MSYN
  // ends the tick `elapsed` reads `N - 1`.  Compared against `N`, the
  // register strobe and -UB SSYN both came a tick late: the mode register
  // missed a SPEEDCLK muir's `answered` makes, and the cycle's -MEMACK was
  // 10 ns after muir's, measured by `build/dispatch_write_order.pass` on the
  // processor's own writes of the mode register.  The write pulse's leading
  // edge below is counted the same way and has not been moved: nothing here
  // writes the two pulse bits against muir, so which tick it belongs on is
  // not measured.

  // `-BOOT` is a LEVEL on two of its three sources --- a finger on a button,
  // and the console's register holding the line down --- so `RESET` is held
  // for as long as it is, and the registers are cleared on every tick of it
  // rather than on its edge.  That is what the 74S175s' CLEAR pin does.
  logic booting;
  assign booting = !n_boot;

  always_ff @(posedge clk) begin
    if (rst) begin
      running     <= 1'b0;
      elapsed     <= 9'd0;
      ub_ssyn     <= 1'b0;
      prog_reset  <= 1'b0;
      prog_boot   <= 1'b0;
      // **RESET HERE IS THE BOOT BUTTON HELD, UNLESS THE SWITCH SAYS IT IS
      // NOT.**  `-BOOT` presets `RUN` at OLORD1 1A14 and is one of the three
      // inputs of `RESET` at 1C08, and "a finger holds it for many master
      // clocks, so SRUN has followed RUN by the time it is released".
      // `Engine::boot` does exactly this --- reset, then `run` --- so a fabric
      // coming out of reset is a machine whose boot button has just been let
      // go, which is what every trace here starts from.
      //
      // With `no_auto_boot` high it is a machine whose button has NOT been
      // pressed: `RUN` clear, nothing running, and only `-BOOT` starts it.
      // **This assignment is the only place the switch is read**, so the
      // sample is taken at the last tick of reset and at no other instant; the
      // port's own note says why that is the behavior and not an economy.
      run         <= !no_auto_boot;
      // The 74S175 at OLORD1 1A09 is cleared by `-RESET`, where `RUN`'s own
      // flip flop at 1A14 is preset by `-BOOT` and cleared by `-CLOCK RESET
      // A`: a console that resets the machine leaves it running or halted as
      // it was, and `Machine::reset_console_registers` says the same.
      step        <= 1'b0;
      nop11       <= 1'b0;
      idebug      <= 1'b0;
      ldstat      <= 1'b0;
      debug_ir    <= 48'd0;
      promdisable <= 1'b0;
      errstop     <= 1'b0;
      stathenb    <= 1'b0;
      mode_speed  <= 2'b00;
      phase_t     <= 6'd0;
      pending     <= 1'b0;
      held        <= 16'd0;
      held_eadr   <= 4'd0;
      early_taken <= 1'b0;
    end else begin
      prog_reset <= 1'b0;
      prog_boot  <= 1'b0;

      if (mclk) phase_t <= 6'd0;
      else if (!(&phase_t)) phase_t <= phase_t + 6'd1;

      if ((pending && landing) || early) begin
        pending <= 1'b0;
        unique case (land_eadr)
          // **THE CLOCK CONTROL REGISTER IS FIVE BITS AND NOT ONE.**  It took
          // bit 0 alone until CC, over the debug cable, wrote `16` octal at
          // it and the machine did not move: `CC-EXECUTE` loads the debug IR
          // and then asks for one clock, and with `STEP`, `NOP11` and
          // `IDEBUG` all dropped the forced microinstruction never ran and
          // the debugger read back its own stale OBUS.
          REG_CLK: begin
            run    <= land_word[0];
            step   <= land_word[1];
            nop11  <= land_word[2];
            idebug <= land_word[3];
            ldstat <= land_word[4];
          end
          REG_IR_LOW:  debug_ir[15:0]  <= land_word;
          REG_IR_MED:  debug_ir[31:16] <= land_word;
          REG_IR_HIGH: debug_ir[47:32] <= land_word;
          REG_MODE: begin
            mode_speed  <= {land_word[1], land_word[0]};
            errstop     <= land_word[2];
            stathenb    <= land_word[3];
            // bit 4 is TRAPENB, the memory parity trap on page TRAP
            promdisable <= land_word[5];
          end
          default: ;
        endcase
      end
      if (early) early_taken <= 1'b1;
      if (!ub_msyn) begin
        running <= 1'b0;
        elapsed <= 9'd0;
        ub_ssyn <= 1'b0;
        early_taken <= 1'b0;
      end else if (selected) begin
        running <= 1'b1;
        if (elapsed != 9'h1FF) elapsed <= elapsed + 9'd1;

        // The write pulse's leading edge, which carries the two pulses out of
        // the mode register's own bits before the register loads.
        if (ub_write && running && elapsed == 9'(PULSE_T) && spy_eadr == REG_MODE) begin
          prog_reset <= ub_wdata[6];
          prog_boot  <= ub_wdata[7];
        end

        // The trailing edge of -LDMODE or -LDCLK, where the word is taken.
        // It is applied above, at the machine's next look.
        if (ub_write && running && elapsed == 9'(STROBE_T) - 9'd1 && !early && !early_taken) begin
          pending   <= 1'b1;
          held      <= ub_wdata;
          held_eadr <= spy_eadr;
        end

        if (running && elapsed >= 9'(SSYN_T) - 9'd1) ub_ssyn <= 1'b1;
      end

      // **`-BOOT` HELD IS `RESET` HELD**, and this is the reset arm above
      // less the things `RESET` has no pin on.  It is written LAST so that it
      // beats a write landing in the same tick, which is the board's own
      // order: `RESET` reaches the two 74S175s' CLEAR pin, and on a 74S175
      // the clear is asynchronous and dominant over the load.  A word already
      // held for the machine's next look goes with the registers it was for.
      //
      // The bus cycle itself is NOT interrupted: `-UB SSYN` still comes and
      // the master still lets go, because `RESET` has no pin on this slave's
      // handshake.  What is lost is the word, not the answer.
      //
      // **AND IT IS WHAT TAKES A NO-AUTO-BOOT HOLD OFF.**  A machine held
      // with `RUN` clear at reset is a machine waiting for its button, so the
      // preset here is unconditional and does not consult `no_auto_boot`: the
      // switch decides how the machine comes up and the button decides when it
      // goes, which is the arrangement a CADR's own light panel has.
      if (booting) begin
        run         <= 1'b1;   // preset at the 74S74 at OLORD1 1A14
        step        <= 1'b0;   // the 74S175 at 1A09, cleared by -RESET
        nop11       <= 1'b0;
        idebug      <= 1'b0;
        ldstat      <= 1'b0;
        promdisable <= 1'b0;   // the 74S175 at 1A08, the mode register
        errstop     <= 1'b0;
        stathenb    <= 1'b0;
        mode_speed  <= 2'b00;
        pending     <= 1'b0;
      end
    end
  end

  // The word this slave gives. Every register a console reads is the
  // processor's, so this is `spy_rdata` and nothing of its own: the three
  // written here are write-only from the bus's point of view, and
  // `Rtl::spy_read` answers for the rest --- including register 3, which has
  // no read select at all and reads as the open bus.
  assign ub_rdata = spy_rdata;

  logic unused;
  // `held<7:6>` are the mode register's two pulses, and they are taken from
  // the bus at the write pulse's leading edge rather than from the held word:
  // they are the pulse, not the register.  Every bit of `held` is read now,
  // the debug IR taking all sixteen.
  assign unused = &{1'b0, ub_addr[17:5], ub_addr[0]};

endmodule

`default_nettype wire
