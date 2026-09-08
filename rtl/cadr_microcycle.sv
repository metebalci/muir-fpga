// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The CADR microcycle: the clock structure, the control store and the
// instruction path, with the datapath still empty.
//
// This is the first slice of `src/rtl.rs` from muir.  A microcycle is two
// phases and one register edge --- "`-CLK0` is `-TPCLK AND MACHRUN` at CLOCK2
// 1D10 and `CLK1..CLK5` are `NOT(-CLK0)` through the 7428 buffers at 1D05,
// 1C01 and 1C11, so every edge-triggered register on the board takes one edge
// per microcycle, at the cycle boundary" --- and what rides on that edge here
// is everything that needs no A bus, M bus or ALU to compute:
//
//   page ICTL/PCTL   the control store, and the boot PROM over its bottom 1K
//   page IREG        IR, with the OA registers substituting fields as it loads
//   page CONTRL      NOP, N, IWRITED, and the four-way NPC select
//   page NPC/LPC     PC and LPC
//   page OPCS        the eight-deep shift register of PCs
//   page STAT        the statistics counter
//   page OLORD1      MACHRUN, and the speed synchroniser at 1A01
//
// What the datapath will make once it exists comes in as ports, and each one
// leaves again when its slice lands: `jcond` from the ALU, `ob` for the OA
// substitution, `a` and `m` for IWR, `spc_target` off the stack, and the
// dispatch memory's word.  `tb/cadr_microcycle_tb.cpp` drives them from
// muir's own trace and counts them, so the hole each one leaves is on the
// check's own output rather than in a comment.
//
// THE CONTROL STORE IS SYNCHRONOUS, and that is the decision this slice was
// meant to settle.  The 93425As and the control store on the board are
// asynchronous: the address is up in the read phase and the word is there in
// the same phase.  FPGA block RAM is not, so the read is issued at the
// microcycle boundary with `NPC` as its address and completes one 200 MHz
// tick later --- 5 ns into a microcycle that is 145 ns at normal speed and
// 220 ns at the extra slow the boot PROM runs at.  The word is up for the
// whole read phase either way, which is what the board's timing asks.  The
// same reasoning is what will carry the scratchpads in the next slice.
//
// WHAT IS NOT HERE, and belongs to a later slice or to the console:
//
//   - The scratchpads, the ALU and everything on the A and M buses.  `iwr`
//     is `IR<15:0>` of the A bus with the M bus under it, so the control
//     store write takes its word from the trace until they exist.
//   - The stack.  `SPC` is read for a POPJ and written for a push; slice 2
//     has it, and until then `spc_target` comes in.
//   - The dispatch memory.  Every DISPATCH in the boot PROM is a DISPWR ---
//     a write of the memory, not a read of it --- so `dr`, `dp`, `dn` and
//     `dpc` are unexercised, and the testbench asserts that rather than
//     leaving it to be assumed.
//   - The console: `NOP11`, `IDEBUG` and the debug IR, `LPC.HOLD`, the OPC
//     clock a halted machine is stepped by, `-LDSTAT`, and the single-step
//     term of `MACHRUN`, `SSTEP AND -SSDONE`.  `srun`, `promdisable`,
//     `errstop`, `stathenb` and the speed bits are the console's registers
//     as OLORD1 1A09 and 1A10 hold them, so they come in as ports.
//   - `-HANG` and `-WAIT`.  `hang` is passed to the generator and nothing
//     here raises it; VCTL1 is slice 5, where `src/rtl.rs`'s `stall` is.

`default_nettype none

module cadr_microcycle #(
    // MIT's boot PROM as `golden/src/prom.rs` writes it: 1024 words of
    // twelve hex digits.  Generated into build/, never committed.
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic        clk,          // 200 MHz, one tick = 5 ns
    input  var logic        rst,          // RESET, synchronous, active high

    // --- the console's registers: OLORD1 1A09 and 1A10.  The fabric has no
    // --- console yet, so these are driven rather than written.
    input  var logic        srun,         // SRUN, the registered RUN
    input  var logic        promdisable,  // PROMDISABLE, mode register bit 14
    input  var logic        errstop,      // ERRSTOP, bit 6
    input  var logic        stathenb,     // STATHENB, bit 11
    input  var logic [1:0]  mode_speed,   // {SPEED1, SPEED0}, bits 4 and 3

    // --- -HANG, from VCTL1.  Slice 5.
    input  var logic        hang,

    // --- what the datapath will make.  Each leaves with its own slice.
    input  var logic        jcond,        // the jump condition, off the ALU
    input  var logic [31:0] ob,           // OB, for the OA substitution
    input  var logic [31:0] a,            // the A bus, IWR<47:32>
    input  var logic [31:0] m,            // the M bus, IWR<31:0>
    input  var logic [13:0] spc_target,   // the stack's word, for a POPJ
    input  var logic [13:0] dpc,          // DPC<13:0>, the dispatch memory
    input  var logic        dr,           // DR<16>
    input  var logic        dp,           // DP<15>
    input  var logic        dn,           // DN<14>

    // --- the machine, as `Rtl::signals` and `Rtl::spy` name it
    output var logic [13:0] pc,
    output var logic [13:0] lpc,
    output var logic [13:0] opc,          // OPC<13:0>, eight microcycles back
    output var logic [31:0] st,           // ST<31:0>, the statistics counter
    output var logic [47:0] ir,
    output var logic        nop,
    output var logic        pcs1,
    output var logic        pcs0,
    output var logic        iwrited,

    // --- one tick per microcycle, at the boundary: the edge every register
    // --- above takes.  What stands before it is that microcycle's.
    output var logic        clock_edge
);

  localparam int unsigned IMEM_WORDS = 16384;
  localparam int unsigned PROM_WORDS = 1024;

  // ------------------------------------------------------------ the clock

  logic tpclk, n_tpclk, tptse, n_tpwp, n_tpwpiram, n_tpr60;
  logic ilong;
  logic [1:0] speed;

  cadr_phase_gen u_phase_gen (
      .clk        (clk),
      .rst        (rst),
      .hang       (hang),
      .ilong      (ilong),
      .speed      (speed),
      .tpclk      (tpclk),
      .n_tpclk    (n_tpclk),
      .tptse      (tptse),
      .n_tpwp     (n_tpwp),
      .n_tpwpiram (n_tpwpiram),
      .n_tpr60    (n_tpr60)
  );

  // TPCLK rising is -TPR0: the boundary, where the read phase of the next
  // microcycle begins and every register takes what this one produced.
  logic tpclk_q;
  logic boundary;
  assign boundary = tpclk && !tpclk_q;

  // The first rise out of reset *starts* the first microcycle; it does not
  // end one, there being none before it.  `Rtl::step` is the same: the read
  // phase runs from the reset state and the edge comes at its end.
  logic started;

  // MCLK, which runs whether or not MACHRUN is up: "the mode register and the
  // trap follow the console even with the machine halted".
  logic mclk_edge;
  assign mclk_edge = boundary && started;

  // `boundary` is a level over the tick in which TPCLK rose, and every
  // `always_ff` below samples it as it stood *before* that tick's edge --- so
  // the registers move one tick after it, which is a buffer delay's worth of
  // a 160 ns read phase and consistent throughout.  `clock_edge` is
  // registered so that it stands high over the tick the registers actually
  // moved in, which is what anything watching them has to line up with.

  // page OLORD1, the 9S42 at 1A15.  The single-step term is the console's and
  // there is no console; `-WAIT` is VCTL1's and slice 5 has it.
  logic errhalt, stathalt, machrun;
  logic halted, statstop;
  assign errhalt  = errstop && halted;
  assign stathalt = stathenb && statstop;
  assign machrun  = srun && !errhalt && !stathalt;

  logic cpu_edge;
  assign cpu_edge = mclk_edge && machrun;

  // The speed synchroniser, the 74S174 at OLORD1 1A01, clocked by SPEEDCLK
  // sixty nanoseconds into the generator cycle --- and the 74S151 at CLOCK1
  // 1D08 selects the tap five nanoseconds after that, at 65.  So the shift
  // has to be *complete* by phase 12 for the select at phase 13 to see it,
  // which is a tick earlier than an edge detector on `n_tpr60` can manage:
  // that net only goes low once phase is already 12, and a register moving
  // off it lands at 13, too late, leaving the tap chosen from the old speed
  // for the whole cycle.  So the phase is counted here instead.
  //
  // `phase_t` tracks the generator's own `phase` from the tick after the
  // boundary on.  Over the boundary tick itself it still holds the last
  // cycle's count, which cannot alias: the shortest cycle the generator
  // makes is 27 ticks and this is only ever compared against 11.
  localparam int unsigned SPEEDCLK_T = 60 / 5 - 1;   // phase 11, shifting into 12

  logic [5:0] phase_t;
  logic       speedclk;
  assign speedclk = phase_t == 6'(SPEEDCLK_T);

  logic [1:0] speed_a;

  always_ff @(posedge clk) begin
    if (rst) begin
      tpclk_q    <= 1'b0;
      started    <= 1'b0;
      phase_t    <= 6'd0;
      clock_edge <= 1'b0;
      speed      <= 2'b00;   // ExtraSlow, as `Rtl::new` comes up
      speed_a    <= 2'b00;
    end else begin
      tpclk_q    <= tpclk;
      clock_edge <= cpu_edge;
      if (boundary) begin
        started <= 1'b1;
        phase_t <= 6'd1;
      end else if (!(&phase_t)) begin
        phase_t <= phase_t + 6'd1;
      end
      if (speedclk) begin
        speed   <= speed_a;
        speed_a <= mode_speed;
      end
    end
  end

  // ---------------------------------------------------- the control store

  // page ICTL and PCTL.  `BOTTOM.1K` at PCTL 1D18 is the top four PC bits all
  // clear, and `-PROMENABLE` at 1C19 is that with `PROMDISABLED`, `IWRITEDA`
  // and `-IDEBUG`; there is no console, so no `IDEBUG`.
  logic [47:0] prom_mem [0:PROM_WORDS-1];
  logic [47:0] imem     [0:IMEM_WORDS-1];
  logic [47:0] prom_q, imem_q;

  initial begin
    $readmemh(PROM_HEX, prom_mem);
    // ALL ONES, WHERE `Machine::new` COMES UP ZERO, and deliberately so.  The
    // board's own control store is undefined at power-on --- which is why the
    // boot PROM's first pass over it writes all 16,384 words --- so what it
    // comes up holding is a convention, as `LVMO_AT_POWER_ON` is a convention.
    // muir picks zero.  Picking zero here too would make the boot PROM's pass
    // unobservable: every word it writes is zero, so a write that never
    // happened, or landed at the wrong address, would read back exactly like
    // one that did.  Measured, not supposed --- with the store coming up zero,
    // dropping the write pulse for all but one address survives the check.
    // A word read before it is written would now disagree with muir, loudly,
    // which is the right way round for a convention neither of them can
    // justify.
    for (int unsigned k = 0; k < IMEM_WORDS; k++) imem[k] = {48{1'b1}};
  end

  logic [13:0] npc;
  logic [13:0] cs_radr;
  // Read every tick: at the boundary the address is the PC being taken,
  // and the rest of the cycle it is the PC standing.  One tick of latency
  // into a phase that is 160 ns long here.
  assign cs_radr = cpu_edge ? npc : pc;

  logic promdisabled;
  logic bottom_1k, promenable;
  assign bottom_1k  = pc < 14'(PROM_WORDS);
  assign promenable = bottom_1k && !promdisabled && !iwrited;

  // page IWR: `IR<15:0>` of the A bus over the whole of the M bus.  The word
  // a `WRITE-I-MEM` stores, and what the I bus carries while `IWRITED` is up
  // --- the RAM has just been written with it, at this very address.
  logic [47:0] iwr;

  // `Rtl::read_phase` short-circuits this --- with IWRITED up it puts `IWR`
  // straight on the I bus --- because its write phase runs after its read
  // phase and the RAM has not been written yet when it needs the word.  The
  // board has no such trouble and neither does this: "-IWEA is NAND(WP5A,
  // IWRITEDA) at ICTL 1B13 ... the write pulse lands in the write phase,
  // before the edge that loads IR, so what the RAM puts on the I bus at that
  // edge is the word just written and not the one it held".  Reading it back
  // out of the RAM is what the board does, and it is what makes every one of
  // the 16,384 words the boot PROM loads a write *and* a read that IR is then
  // compared on.  Bypassing would leave the control store write-only.
  logic [47:0] i;
  assign i = promenable ? prom_q : imem_q;

  // `-IWEA` is `NAND(WP5A, IWRITEDA)` at ICTL 1B13: the control store write
  // pulse is -TPWPIRAM, and the word is stored on its trailing edge, in the
  // write phase and before the boundary that loads IR.
  logic n_tpwpiram_q, iwe;
  assign iwe = iwrited && n_tpwpiram && !n_tpwpiram_q;

  always_ff @(posedge clk) begin
    n_tpwpiram_q <= n_tpwpiram;
    prom_q       <= prom_mem[cs_radr[9:0]];
    imem_q       <= imem[cs_radr];
    if (iwe) imem[pc] <= iwr;
  end

  // -------------------------------------------------------- page CONTRL

  // TRAP: `-BOOT` clears the 74LS109 at OLORD2 1A18, and the first master
  // clock edge with SRUN already up clocks the trap away again.  It nops its
  // microcycle and forces NPC to zero.
  logic trap;

  // `-INOP` is the 74S175's own -Q at CONTRL 3D26 wire-ANDed with the
  // open-collector 74S08 at 3E14; `NOP11` is the console's and is not here.
  logic inop;
  assign nop = trap || inop;

  // page SOURCE: the class, off IR<44:43>, and the misc function off
  // IR<11:10>.  A nopped cycle decodes as nothing at all.
  logic irbyte, irdisp, irjump, iralu;
  always_comb begin
    irbyte = 1'b0;
    irdisp = 1'b0;
    irjump = 1'b0;
    iralu  = 1'b0;
    if (!nop) begin
      unique case (ir[44:43])
        2'd0: iralu  = 1'b1;
        2'd1: irjump = 1'b1;
        2'd2: irdisp = 1'b1;
        2'd3: irbyte = 1'b1;
        default: ;
      endcase
    end
  end

  logic [3:0] funct;
  assign funct = nop ? 4'd0 : (4'd1 << ir[11:10]);

  // `-HALT` is misc function 1, MIT's HALT-CONS, and OLORD2 1A05 registers
  // it.  Under ERRSTOP it stops the machine.
  logic halt;
  assign halt = funct[1];

  // page ACTL/MCTL, only as far as the OA registers need it: an M
  // destination in the middle group, IR<21:19> of 6 or 7.
  logic dest, destm, mid_group;
  logic destimod0, destimod1;
  assign dest      = iralu || irbyte;
  assign destm     = dest && !ir[25];
  assign mid_group = destm && !ir[23] && ir[22];
  assign destimod0 = mid_group && (ir[21:19] == 3'd6);
  assign destimod1 = mid_group && (ir[21:19] == 3'd7);

  // page CONTRL, sequencing.  The dispatch memory's word is slice 4's.
  logic dfall, dispenb, ignpopj;
  logic jfalse, jret, jretf, iwrite, ipopj, popj, n;
  assign dfall   = dr && dp;
  assign dispenb = irdisp && !funct[2];
  assign ignpopj = irdisp && !dr;
  assign jfalse  = irjump && ir[6];
  assign jret    = irjump && !ir[8] && ir[9];
  assign jretf   = jret && ir[6];
  assign iwrite  = irjump && ir[8] && ir[9];
  assign ipopj   = ir[42] && !nop;
  assign popj    = ipopj || iwrited;

  assign n = trap || iwrited || (dispenb && dn)
          || (jfalse && !jcond && ir[7])
          || (irjump && !ir[6] && jcond && ir[7]);

  assign pcs1 = !((popj && !ignpopj)
               || (jfalse && !jcond)
               || (irjump && !ir[6] && jcond)
               || (dispenb && dr && !dp));
  assign pcs0 = !(popj
               || (dispenb && !dfall)
               || (jretf && !jcond)
               || (jret && !ir[6] && jcond));

  logic [13:0] ipc;
  assign ipc = pc + 14'd1;

  always_comb begin
    if (trap) begin
      npc = 14'd0;
    end else begin
      unique case ({pcs1, pcs0})
        2'b00: npc = spc_target;
        2'b01: npc = ir[25:12];
        2'b10: npc = dpc;
        2'b11: npc = ipc;
        default: npc = ipc;
      endcase
    end
  end

  // page FLAG, the 74S10 at 3E07: `-ILONG` is `NAND(IR45, -NOPA)` and
  // `STATBIT` is IR<46> the same way.
  logic statbit;
  assign ilong   = ir[45] && !nop;
  assign statbit = ir[46] && !nop;

  // ------------------------------------------------- page IREG, the OA mux

  // The 74S374s on page OA substitute fields into the word as it loads: the
  // I bus with OB over it, IR<47:26> for a DESTIMOD1 and IR<25:0> for a
  // DESTIMOD0.  `Rtl::clock_edge` builds the same word.
  logic [47:0] iob, ir_next;
  assign iob = i
             | ({26'd0, ob[21:0]} << 26)
             | {22'd0, ob[25:0]};

  always_comb begin
    ir_next = i;
    if (destimod1) ir_next[47:26] = iob[47:26];
    if (destimod0) ir_next[25:0]  = iob[25:0];
  end

  // -------------------------------------------------------- the registers

  logic [13:0] opcs [0:7];
  assign opc = opcs[7];

  always_ff @(posedge clk) begin
    if (rst) begin
      // `Rtl::new` comes up with every register clear and `Engine::boot`
      // raises the trap; SRUN is the console's and comes in.
      trap         <= 1'b1;
      promdisabled <= 1'b0;
      inop         <= 1'b0;
      iwrited      <= 1'b0;
      halted       <= 1'b0;
      statstop     <= 1'b0;
      pc           <= 14'd0;
      lpc          <= 14'd0;
      ir           <= 48'd0;
      iwr          <= 48'd0;
      st           <= 32'd0;
      for (int unsigned k = 0; k < 8; k++) opcs[k] <= 14'd0;
    end else begin
      // The master clock, which runs whether or not the cpu's does.
      if (mclk_edge) begin
        promdisabled <= promdisable;
        // The 74LS109 at OLORD2 1A18 drops the trap at the first edge whose
        // J, SRUN, was up.
        if (srun) trap <= 1'b0;
      end

      if (cpu_edge) begin
        ir      <= ir_next;
        pc      <= npc;
        lpc     <= pc;                 // LPC.HOLD is the console's
        inop    <= n;
        iwrited <= iwrite;
        halted  <= halt;
        iwr     <= {a[15:0], m};

        // page OPCS 1F06-1F13: dual *eight-bit* shift registers with only the
        // last stage brought out, so what a SRCOPC reads is the PC of eight
        // microcycles ago and not of one.
        opcs[0] <= pc;
        for (int unsigned k = 1; k < 8; k++) opcs[k] <= opcs[k-1];

        // page STAT 1B01-1C05: eight 74S169s chained, counting up, enabled by
        // -STATBIT.  `STAT.OVF` registered at OLORD2 1A05 is STATSTOP.  The
        // console's -LDSTAT, which loads the counter from IWR, is not here.
        statstop <= (&st) && statbit;
        if (statbit) st <= st + 32'd1;
      end
    end
  end

  // What this slice does not read, named so that lint says so rather than
  // waving it through:
  //
  //   n_tpclk, tptse, n_tpwp   the write phase's, for the scratchpads --- slice 2
  //   n_tpr60                  SPEEDCLK, counted from the boundary instead
  //   ob<31:26>                the OA registers substitute IR<25:0> and IR<47:26>
  //   a<31:16>                 IWR takes A<15:0> and the whole of M
  //   funct<0>, funct<3>       misc functions 0 and 3, neither of them -HALT
  logic unused;
  assign unused = &{1'b0, n_tpclk, tptse, n_tpwp, n_tpr60,
                    ob[31:26], a[31:16], funct[0], funct[3]};

endmodule

`default_nettype wire
