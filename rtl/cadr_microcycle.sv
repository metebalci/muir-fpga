// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The CADR microcycle: the clock structure, the control store, the
// instruction path and the scratchpads, with the ALU still to come.
//
// This is the first two slices of `src/rtl.rs` from muir.  A microcycle is two
// phases and one register edge --- "`-CLK0` is `-TPCLK AND MACHRUN` at CLOCK2
// 1D10 and `CLK1..CLK5` are `NOT(-CLK0)` through the 7428 buffers at 1D05,
// 1C01 and 1C11, so every edge-triggered register on the board takes one edge
// per microcycle, at the cycle boundary" --- and what rides on that edge here
// is everything that needs no ALU to compute:
//
//   page ICTL/PCTL   the control store, and the boot PROM over its bottom 1K
//   page IREG        IR, with the OA registers substituting fields as it loads
//   page CONTRL      NOP, N, IWRITED, and the four-way NPC select
//   page NPC/LPC     PC and LPC
//   page OPCS        the eight-deep shift register of PCs
//   page STAT        the statistics counter
//   page OLORD1      MACHRUN, and the speed synchroniser at 1A01
//   page ACTL/MCTL   the A and M memories, their latches and pass-arounds
//   page PDLCTL      the PDL, its pointer and its index
//   page SPC/SPCW    the stack, SPCPTR, RETA and the push pass-around
//   page LC/LCC/FLAG the location counter and the byte-mode flags
//
// What the datapath will make once it exists comes in as ports, and each one
// leaves again when its slice lands: `jcond` from the ALU, `ob` for L and the
// OA substitution, `m` for IWR, and the dispatch memory's word.
// `tb/cadr_microcycle_tb.cpp` drives them from muir's own trace and counts
// them, so the hole each one leaves is on the check's own output rather than
// in a comment.
//
// TWO MEMORY DECISIONS, BOTH SETTLED WITH THE PHASE GENERATOR RATHER THAN AT
// BRING-UP, because FPGA block RAM has no asynchronous read and every memory
// on this board does.
//
// **The control store is read synchronously**, the read issued at the
// microcycle boundary with `NPC` as its address and complete one 200 MHz tick
// later --- 5 ns into a microcycle that is 145 ns at normal speed and 220 ns
// at the extra slow the boot PROM runs at.
//
// **The scratchpads are read while CLK is high, and the 74S373s are what
// holds the word.**  `rtl.rs`'s header is explicit: the 93425As have "no clock
// pin, so what holds a word between phases is the 74S373 at ALATCH, MLATCH,
// PLATCH or SPCLCH and not the memory.  Modelling the memory as a register
// loaded early is the 74S373 drawn one state too soon."  A synchronous read
// enabled by TPCLK *is* that latch --- it follows the memory through the read
// phase and holds through the write phase --- and it settles the
// read-during-write question for nothing, since the write pulses fire with
// TPCLK low, after the latches have stopped following.
//
// Sizes, for what will have to fit: A memory 1024 x 32 and the PDL 1024 x 32
// are a BRAM36 each at x32.  M memory 32 x 32 and the stack 32 x 21 are small
// enough for distributed RAM, which is where the 93425As' asynchronous read
// would have gone anyway.  One BRAM per original chip would not fit and is
// not what this asks for.
//
// THE CONTROL STORE COMES UP ALL ONES where `Machine::new` comes up zero, and
// deliberately; the comment at the array says why.
//
// WHAT IS NOT HERE, and belongs to a later slice or to the console:
//
//   - The A and M buses, the ALU, the shifter and OB.  So `mmem_out`, the
//     PDL's word and the stack's upper bits are built and go nowhere: they
//     reach only the M bus, and the M bus is the next slice.
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
//
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
    input  var logic [31:0] ob,           // OB, what L takes at the edge
    input  var logic [31:0] m,            // the M bus, IWR<31:0>
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
    output var logic [31:0] a,            // the A bus, off ACTL's pass-around
    output var logic [25:0] lc,           // LC<25:0>, the location counter
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

  // page ACTL/MCTL: the destination this instruction will hand on.  `DESTM`
  // is what shortens an M destination to five bits, at the 25S09s on 3B28
  // and 3B29.
  logic dest, destm, low_group, mid_group;
  logic destlc, destintctl;
  logic destpdltop, destpdl_p, destpdl_x, destpdlx, destpdlp, destspc;
  logic destimod0, destimod1;
  assign dest       = iralu || irbyte;
  assign destm      = dest && !ir[25];
  assign low_group  = destm && !ir[23] && !ir[22];
  assign mid_group  = destm && !ir[23] && ir[22];
  assign destlc     = low_group && (ir[21:19] == 3'd1);
  assign destintctl = low_group && (ir[21:19] == 3'd2);
  assign destpdltop = mid_group && (ir[21:19] == 3'd0);
  assign destpdl_p  = mid_group && (ir[21:19] == 3'd1);
  assign destpdl_x  = mid_group && (ir[21:19] == 3'd2);
  assign destpdlx   = mid_group && (ir[21:19] == 3'd3);
  assign destpdlp   = mid_group && (ir[21:19] == 3'd4);
  assign destspc    = mid_group && (ir[21:19] == 3'd5);
  assign destimod0  = mid_group && (ir[21:19] == 3'd6);
  assign destimod1  = mid_group && (ir[21:19] == 3'd7);

  logic [9:0] wadr_in;
  assign wadr_in = destm ? {5'd0, ir[18:14]} : ir[23:14];

  // page SOURCE: the two functional-source groups, off the 74S138s that
  // decode IR<28:26> under IR<31> and IR<29>.
  logic group_a, group_b;
  logic srcpdlpop, srcpdltop, srcspc, srcspcpop;
  assign group_a   = ir[31] && !ir[29];
  assign group_b   = ir[31] && ir[29];
  assign srcspc    = group_a && (ir[28:26] == 3'd1);
  assign srcpdlpop = group_a && (ir[28:26] == 3'd4);
  assign srcpdltop = group_a && (ir[28:26] == 3'd5);
  assign srcspcpop = group_b && (ir[28:26] == 3'd4);

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

  // ---------------------------------------------------- the scratchpads
  //
  // THE 74S373s ARE THE STATE, AND THEY ARE WHAT MAKES BLOCK RAM WORK HERE.
  // `rtl.rs`'s header: the 93425As "are 93425As with no clock pin, so what
  // holds a word between phases is the 74S373 at ALATCH, MLATCH, PLATCH or
  // SPCLCH and not the memory.  Modelling the memory as a register loaded
  // early is the 74S373 drawn one state too soon."  So the latch follows the
  // memory *while CLK is high* and holds through the write phase --- and a
  // synchronous read enabled by TPCLK is exactly that, with the read landing
  // one 200 MHz tick into a read phase 160 ns long.  It also settles the
  // read-during-write question for nothing: the write pulses fire with TPCLK
  // low, when the latches have stopped following.
  //
  // Sizes, for what will have to fit: A memory 1024 x 32 and the PDL
  // 1024 x 32 are a BRAM36 each at x32.  M memory 32 x 32 and the stack
  // 32 x 21 are small enough to land in distributed RAM, which is where the
  // 93425As' asynchronous read would have gone anyway; one BRAM per original
  // chip would not fit and is not what this asks for.

  logic [31:0] amem [0:1023];
  logic [31:0] mmem [0:31];
  logic [31:0] pdl  [0:1023];
  logic [20:0] spcm [0:31];

  logic [31:0] amem_q, mmem_q, pdl_q;
  logic [20:0] spc_q;

  // page L 3C26-3C29: the 74S374 that holds OB for the write pulse.  Its
  // input is the datapath's and comes in until slice 3.
  logic [31:0] l;

  // page ACTL 3B26/3B28/3B29: the destination of the instruction *before*
  // this one, which is the address the write pulse in this cycle will use.
  logic [9:0] wadr;
  logic       destd, destmd;

  // The pass-arounds.  "A scratchpad write is one microcycle behind the
  // instruction that computed it ... what hides that from the microcode is
  // the pass-around: the comparators at ACTL 3B21/3B27 and MCTL 4B18 match
  // the instruction's source address against the pending WADR and put L on
  // the bus instead of the memory's output."  `-AMEMENB` is `NAND(-APASS,
  // TSE3A)` at 3B16 and `APASSENB` is `AND(APASS1, APASS2, TSE4A)` at 4B11;
  // the M comparator is the 93S46 at 4B18, which matches `DESTMD` as its
  // sixth bit.
  logic [9:0] aadr;
  logic [4:0] madr;
  logic       apass, mpass;
  assign aadr  = ir[41:32];
  assign madr  = ir[30:26];
  assign apass = destd && (wadr == aadr);
  assign mpass = destmd && (wadr[4:0] == madr);

  assign a = apass ? l : amem_q;

  // The M memory's output.  It reaches the M bus through the 74S257s at
  // MLATCH under `MPASSM`, and the M bus is slice 3, so nothing here reads
  // this yet.
  logic [31:0] mmem_out;
  assign mmem_out = mpass ? l : mmem_q;

  // page PDLCTL: `PDLP` is `(CLK AND IR30) OR (-CLK AND -PWIDX)` off the
  // 74S51 at 4D07, so the PDL is addressed by IR<30> in the read phase and by
  // the pending write's own `PWIDX` in the write phase.
  logic [9:0] pdl_ptr, pdl_idx;
  logic [9:0] pdla_read, pdla_write;
  logic       pwidx, pdlwrited, pdlwrite, pdlcnt;
  assign pdla_read  = ir[30] ? pdl_ptr : pdl_idx;
  assign pdla_write = pwidx  ? pdl_idx : pdl_ptr;
  assign pdlwrite   = destpdltop || destpdl_x || destpdl_p;
  assign pdlcnt     = (!nop && srcpdlpop) || destpdl_p;

  // page SPC and SPCW.  The 82S21s at 4E21-4E23 read at the pointer; the
  // 74S157s at SPCW 4E12-4E14 select on `DESTSPCD`, the *registered*
  // DESTSPC, over L and the registered RETA, so the word is known before the
  // ALU is and the pass-around closes no loop.  While a push is pending
  // `SPCWPASS` at CONTRL 3D21 puts that word on the SPC bus in place of the
  // RAM's --- and the SPC bus is the PC's next-address path, not M.
  logic [4:0]  spcptr;
  logic [13:0] reta;
  logic        spushd, destspcd, spush, spop, spcnt;
  logic [20:0] spcw, spcv;
  assign spcw = destspcd ? l[20:0] : {7'd0, reta};
  assign spcv = spushd ? spcw : spc_q;

  assign spop  = ((srcspcpop && !nop) || popj) && !ignpopj
              || (dispenb && dr && !dp)
              || (jret && !ir[6] && jcond)
              || (jretf && !jcond);
  assign spush = destspc
              || (jfalse && ir[8] && !jcond)
              || (dispenb && dp && !dr)
              || (irjump && !ir[6] && ir[8] && jcond);
  assign spcnt = spush || spop;

  // page LCC and LC.  `NEXT.INSTR` and the byte-mode flags decide whether the
  // stack's word is munged on the way to the PC.
  logic newlc, next_instrd, next_instr;
  logic lc_byte_mode, int_enable, sequence_break;
  logic lc0b, have_wrong_word, last_byte_in_word, needfetch, lcinc, newlc_in;
  assign lc0b              = lc[0] && lc_byte_mode;
  assign have_wrong_word   = newlc || destlc;
  assign last_byte_in_word = !lc[1] && !lc0b;
  assign needfetch         = have_wrong_word || last_byte_in_word;
  assign lcinc             = next_instrd || (irdisp && ir[24]);
  assign newlc_in          = have_wrong_word && !lcinc;
  assign next_instr        = spop && !(srcspcpop && !nop) && spcv[14];

  logic spcmung, spc1a;
  logic [13:0] spc_target;
  assign spcmung    = spcv[14] && !needfetch;
  assign spc1a      = spcmung || spcv[1];
  assign spc_target = {spcv[13:2], spc1a, spcv[0]};

  // page SPCW 4F11-4F14: RETA's input mux takes WPC when N and IPC otherwise,
  // and it is registered, so the address it carries belongs to the
  // instruction whose push is pending.
  logic [13:0] wpc, reta_in;
  assign wpc     = (irdisp && ir[25]) ? lpc : pc;
  assign reta_in = n ? wpc : ipc;

  // The write pulses.  `-AWPA` at ACTL 3B30, `-MWPA` at MCTL 4B22, `-PWPA` at
  // 4D20 and `-SWPA` at SPC 4E30 are all -WP gated by a *registered* enable,
  // so everything stored here belongs to the previous instruction.  Taken on
  // the pulse's leading edge, which is thirty nanoseconds into a write phase
  // where the address and the word have been stable since the boundary.
  logic n_tpwp_q, wp;
  assign wp = !n_tpwp && n_tpwp_q;

  always_ff @(posedge clk) begin
    n_tpwp_q <= n_tpwp;
    // The latches follow the memories while CLK is high, and hold.
    if (tpclk) begin
      amem_q <= amem[aadr];
      mmem_q <= mmem[madr];
      pdl_q  <= pdl[pdla_read];
      spc_q  <= spcm[spcptr];
    end
    if (wp) begin
      if (destd)     amem[wadr]       <= l;
      if (destmd)    mmem[wadr[4:0]]  <= l;
      if (pdlwrited) pdl[pdla_write]  <= l;
      // "at the pointer the edge has already moved to": the 82S21s are
      // addressed by SPCPTR<4:0> with no offset.
      if (spushd)    spcm[spcptr]     <= spcw;
    end
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
      l            <= 32'd0;
      wadr         <= 10'd0;
      destd        <= 1'b0;
      destmd       <= 1'b0;
      pwidx        <= 1'b0;
      pdlwrited    <= 1'b0;
      spushd       <= 1'b0;
      destspcd     <= 1'b0;
      reta         <= 14'd0;
      spcptr       <= 5'd0;
      pdl_ptr      <= 10'd0;
      pdl_idx      <= 10'd0;
      lc           <= 26'd0;
      lc_byte_mode <= 1'b0;
      int_enable   <= 1'b0;
      sequence_break <= 1'b0;
      newlc        <= 1'b0;
      next_instrd  <= 1'b0;
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

        // page L, and page ACTL: the write this cycle's instruction has just
        // computed, handed to the next one to store.
        l      <= ob;
        wadr   <= wadr_in;
        destd  <= dest;
        destmd <= destm;

        // pages PDLCTL and CONTRL: what the write pulses will stand on.
        pwidx     <= destpdl_x;
        pdlwrited <= pdlwrite;
        spushd    <= spush;
        destspcd  <= destspc;
        reta      <= reta_in;

        // page SPC pointer
        if (spcnt) spcptr <= spush ? spcptr + 5'd1 : spcptr - 5'd1;

        // page PDLPTR
        if (destpdlx) pdl_idx <= ob[9:0];
        if (destpdlp) pdl_ptr <= ob[9:0];
        else if (pdlcnt)
          pdl_ptr <= (!nop && srcpdlpop) ? pdl_ptr - 10'd1 : pdl_ptr + 10'd1;

        // page LC: the 74S169s count by one or two, byte mode deciding which.
        if (destlc) lc <= ob[25:0];
        else lc <= lc + 26'(lcinc) + 26'((lcinc && !lc_byte_mode));

        // page LCC 3E12 and FLAG 3E08
        newlc       <= newlc_in;
        next_instrd <= next_instr;
        if (destintctl) begin
          lc_byte_mode   <= ob[29];
          int_enable     <= ob[27];
          sequence_break <= ob[26];
        end
      end
    end
  end

  // What this slice does not read, named so that lint says so rather than
  // waving it through:
  //
  //   n_tpclk, tptse           the read phase's tri-state enables --- slice 3
  //   n_tpr60                  SPEEDCLK, counted from the boundary instead
  //   ob<31:30>, ob<28>        no destination reads them
  //   funct<0>, funct<3>       misc functions 0 and 3, neither of them -HALT
  //   mmem_out, pdl_q          they reach only the M bus --- slice 3
  //   spcv<20:15>              SPC<20:15> reaches only M and the parity check
  //   srcspc, srcpdltop        likewise: they select on the M bus
  //   int_enable, sequence_break   they reach only JCOND --- slice 3
  logic unused;
  assign unused = &{1'b0, n_tpclk, tptse, n_tpr60,
                    ob[31:30], ob[28], funct[0], funct[3],
                    mmem_out, pdl_q, spcv[20:15], srcspc, srcpdltop,
                    int_enable, sequence_break};

endmodule

`default_nettype wire
