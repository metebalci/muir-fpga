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
// microcycle, and the speed synchroniser samples the register sixty
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
    output var logic        promdisable,  // PROMDISABLE, mode register bit 5
    output var logic        errstop,      // ERRSTOP, bit 2
    output var logic        stathenb,     // STATHENB, bit 3
    output var logic [1:0]  mode_speed,   // {SPEED1, SPEED0}, bits 1 and 0
    output var logic        prog_reset,   // -PROG.RESET, a pulse
    output var logic        prog_boot     // PROG.BOOT, a pulse
);

  // busint::DIAGNOSTIC_NS, REGISTER_STROBE_NS and REGISTER_PULSE_NS.
  localparam int unsigned SSYN_T   = 250 / 5;
  localparam int unsigned STROBE_T = 150 / 5;
  localparam int unsigned PULSE_T  = (150 - 100) / 5;

  // spy::BASE and the sixteen registers above it, two apart.
  localparam logic [17:0] BASE = 18'o766000;

  logic selected;
  assign selected = (ub_addr >= BASE) && (ub_addr < BASE + 18'o40);
  assign spy_eadr = ub_addr[4:1];

  // spy::MODE, spy::CLK and spy::OPC_CONTROL.
  localparam logic [3:0] REG_CLK  = 4'd3;
  localparam logic [3:0] REG_MODE = 4'd5;

  logic [8:0] elapsed;
  logic       running;

  // **THE WRITE LANDS WHERE THE MACHINE NEXT LOOKS, NOT AT THE STROBE.**
  // `Rtl::land_write` is called at the microcycle boundary and again
  // `SPEEDCLK_NS` into every generator cycle --- the second because the speed
  // synchroniser samples the mode register there --- and the register takes
  // its word at the first of those instants at or after the strobe. So a
  // write whose strobe falls just after a boundary waits for the next
  // opportunity, which is up to a microcycle away. Applying it at the strobe
  // instead sets PROMDISABLE a microcycle early, measured on the band at
  // 1,410,034 against muir's 1,410,035.
  localparam int unsigned SPEEDCLK_T = 60 / 5;

  logic [5:0]  phase_t;      // ticks since the boundary
  logic        landing;      // one of the two instants is now
  logic        pending;
  logic [15:0] held;
  logic [3:0]  held_eadr;
  assign landing = mclk || (phase_t == 6'(SPEEDCLK_T));

  always_ff @(posedge clk) begin
    if (rst) begin
      running     <= 1'b0;
      elapsed     <= 9'd0;
      ub_ssyn     <= 1'b0;
      prog_reset  <= 1'b0;
      prog_boot   <= 1'b0;
      // **RESET HERE IS THE BOOT BUTTON HELD.**  `-BOOT` presets `RUN` at
      // OLORD1 1A14 and is one of the three inputs of `RESET` at 1C08, and
      // "a finger holds it for many master clocks, so SRUN has followed RUN
      // by the time it is released".  `Engine::boot` does exactly this ---
      // reset, then `run` --- so a fabric coming out of reset is a machine
      // whose boot button has just been let go, which is what every trace
      // here starts from.  A separate button is what a console would add.
      run         <= 1'b1;
      promdisable <= 1'b0;
      errstop     <= 1'b0;
      stathenb    <= 1'b0;
      mode_speed  <= 2'b00;
      phase_t     <= 6'd0;
      pending     <= 1'b0;
      held        <= 16'd0;
      held_eadr   <= 4'd0;
    end else begin
      prog_reset <= 1'b0;
      prog_boot  <= 1'b0;
      if (mclk) phase_t <= 6'd0;
      else if (!(&phase_t)) phase_t <= phase_t + 6'd1;

      if (pending && landing) begin
        pending <= 1'b0;
        unique case (held_eadr)
          REG_CLK: run <= held[0];
          REG_MODE: begin
            mode_speed  <= {held[1], held[0]};
            errstop     <= held[2];
            stathenb    <= held[3];
            // bit 4 is TRAPENB, the memory parity trap on page TRAP
            promdisable <= held[5];
          end
          default: ;
        endcase
      end
      if (!ub_msyn) begin
        running <= 1'b0;
        elapsed <= 9'd0;
        ub_ssyn <= 1'b0;
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
        if (ub_write && running && elapsed == 9'(STROBE_T)) begin
          pending   <= 1'b1;
          held      <= ub_wdata;
          held_eadr <= spy_eadr;
        end

        if (running && elapsed >= 9'(SSYN_T)) ub_ssyn <= 1'b1;
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
  // `held<7:6>` are the two pulses, and they are taken from the bus at the
  // write pulse's leading edge rather than from the held word: they are the
  // pulse, not the register.
  assign unused = &{1'b0, ub_wdata[15:8], ub_wdata[4], held[15:6], held[4],
                    ub_addr[17:5], ub_addr[0]};

endmodule

`default_nettype wire
