// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The CADR microcycle: the clock structure, the control store, the
// instruction path, the scratchpads, the datapath and the memory cycle's
// control.
//
// This is `src/rtl.rs` from muir bar the map and the registers that feed it.  A microcycle is two
// phases and one register edge --- "`-CLK0` is `-TPCLK AND MACHRUN` at CLOCK2
// 1D10 and `CLK1..CLK5` are `NOT(-CLK0)` through the 7428 buffers at 1D05,
// 1C01 and 1C11, so every edge-triggered register on the board takes one edge
// per microcycle, at the cycle boundary" --- and what rides on that edge here
// is everything but the memory path:
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
//   page MF          the functional sources, and the M bus over them
//   page SMCTL       the shift and mask amounts, byte mode included
//   page SHIFT/MSKG  the 32-bit rotate and the mask
//   page ALUC4/ALU   the nine 74S181s as one 33-bit array
//   page MO/OB       the merge and the output select
//   page Q, DSPCTL   Q and the dispatch constant
//   page VCTL1       MEMSTART, MBUSY, RDCYC, READ IN PROGRESS, -WAIT, -HANG
//
// What the memory path will make once it exists comes in as ports, and each
// one leaves with the slice that builds it: `md` and `vma`, `vmaok` off the
// map's permission bits, `sintr` from the cables, the word a SRCMAP puts on
// MF, and the dispatch memory's.  `tb/cadr_microcycle_tb.cpp` drives them
// from muir's own trace and counts them, so the hole each one leaves is on
// the check's own output rather than in a comment.
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
//   - MD, VMA and the two map levels.  A SRCMAP is reached once in 600,000
//     microcycles, which is not a check of a map under any amount of
//     cleverness, so no map machinery is built on it: its word comes in, as
//     do MD, VMA and -VMAOK.
//   - The bus interface, which is `rtl/cadr_busint_xbus.sv` and has a check
//     of its own.  What is here is the processor's half of the cables:
//     -MEMRQ and WRCYC out, -MEMACK and -MEMGRANT in.
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

    // --- what the memory path will make.  Each leaves with its own slice.
    input  var logic [31:0] md,           // MD, the memory data register
    input  var logic        n_memack,     // -MEMACK, off the cables
    input  var logic        n_memgrant,   // -MEMGRANT: "low when the processor
                                          //   has the bus.  Do not hang when
                                          //   this line is high!"
    input  var logic        sintr,        // SINTR, the interrupt off the cables

    // --- the machine, as `Rtl::signals` and `Rtl::spy` name it
    output var logic [13:0] pc,
    output var logic [13:0] lpc,
    output var logic [13:0] opc,          // OPC<13:0>, eight microcycles back
    output var logic [31:0] st,           // ST<31:0>, the statistics counter
    output var logic [47:0] ir,
    output var logic [31:0] a,            // the A bus, off ACTL's pass-around
    output var logic [31:0] m,            // the M bus
    output var logic [31:0] alu,          // ALU<31:0> of the 33-bit array
    output var logic [31:0] r,            // R, the shifter's output
    output var logic [31:0] ob,           // OB, what the write pulses store
    output var logic [31:0] q,            // Q
    output var logic [9:0]  dc,           // the dispatch constant
    output var logic [25:0] lc,           // LC<25:0>, the location counter
    output var logic [31:0] vma,          // VMA, the virtual memory address
    output var logic        vmaok,        // VMAOK: the access is permitted
    output var logic        jcond,        // the jump condition
    output var logic        nop,
    output var logic        pcs1,
    output var logic        pcs0,
    output var logic        iwrited,

    // --- one tick per microcycle, at the boundary: the edge every register
    // --- above takes.  What stands before it is that microcycle's.
    // --- the cables to the bus interface
    output var logic        n_memrq,      // -MEMRQ, a level while a cycle is wanted
    output var logic        memstart,     // MEMSTART, which also addresses the map
    output var logic        rdcyc,
    output var logic        wrcyc,

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
  assign machrun  = srun && !errhalt && !stathalt && !wait_;

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

  // page VCTL1/VCTL2: which kind of memory cycle, off IR<20:19> under DESTMEM.
  logic destmem, memwr, memrd, ifetch, memop, use_md;
  assign destmem = destm && ir[23];
  assign memwr   = destmem && (ir[20:19] == 2'd2);
  assign memrd   = destmem && (ir[20:19] == 2'd1);
  assign ifetch  = needfetch && lcinc;
  assign memop   = memrd || memwr || ifetch;
  // `USE.MD` is `NOR(-SRCMD, NOPA)` at VCTL1 3F18: this instruction reads MD
  // and is not nopped.  It is half of -HANG.
  assign use_md  = srcmd && !nop;

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

  // ------------------------------------------------- pages DRAM and DSPCTL
  //
  // The dispatch memory, asynchronous like the rest and small enough to stay
  // that way: 2048 x 17 in distributed RAM.  It is read inside the read phase
  // and its word decides where the microcycle goes, so a registered read
  // would need the address before `R` has settled.
  //
  // Bit 0 of the address is the 74S64s at 2F24, 2F05 and 2F23:
  //
  //     -DADR0 = NAND-OR(VMO18 AND IR8, VMO19 AND IR9,
  //                      -DMAPBENB AND DMASK0 AND R0, IR12)
  //     -DMAPBENB = NOR(IR8, IR9)                    at 3F14
  //
  // so a dispatch that takes a map bit takes it *instead of* R0, not as well.
  // ORing the two is the easy misreading of that NAND-OR.
  logic [16:0] dmem [0:2047];

  // Eight bits, not seven: IR<7:5> reaches 7 and `1 << 7` needs the room.
  logic [7:0]  dmask;
  logic        dmap, daddr0;
  logic [10:0] dadr;
  logic [16:0] dram_q;
  logic        dr, dp, dn, dfall, dispwr;
  logic [13:0] dpc;

  assign dmask  = (8'd1 << ir[7:5]) - 8'd1;
  assign dmap   = ir[8] || ir[9];
  assign daddr0 = (ir[8] && vmo[18])
               || (ir[9] && vmo[19])
               || (!dmap && dmask[0] && r[0])
               || ir[12];
  assign dadr   = {ir[22:13], daddr0} | {4'd0, dmask[6:1] & r[6:1], 1'b0};
  assign dram_q = dmem[dadr];
  assign dr     = dram_q[16];
  assign dp     = dram_q[15];
  assign dn     = dram_q[14];
  assign dpc    = dram_q[13:0];
  // `-DWEA` is `NAND(WP2, DISPWR)` at DRAM 2F03, gated by the live signal and
  // not by a registered one, so the address and the data are this
  // instruction's.  Which is why there is no dispatch pass-around.
  assign dispwr = irdisp && funct[2];

  // page CONTRL, sequencing.
  logic dispenb, ignpopj;
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
      // MAPWR0D is `WMAPD AND VMA26` and MAPWR1D is `WMAPD AND VMA25` at
      // VCTL2 1C15, and both pulses are -WP1, so the two levels are written
      // in the same write phase.  Address and data are the live ones:
      // nothing latches them.
      if (wmapd) begin
        if (vma[26]) l1_map[adr0] <= vma[31:27];
        if (vma[25]) l2_map[adr1] <= vma[23:0];
      end
      if (dispwr) dmem[dadr] <= a[16:0];
    end
  end

  // ---------------------------------------------------------- the datapath

  // page MF: the functional sources, off the two 74S138s that decode
  // IR<28:26> under IR<31> and IR<29>.
  logic prog_unibus_reset;
  logic srcdc, srcpdlptr, srcpdlidx, srcopc, srcq, srcvma, srcmap, srcmd, srclc;
  assign srcdc     = group_a && (ir[28:26] == 3'd0);
  assign srcpdlptr = group_a && (ir[28:26] == 3'd2);
  assign srcpdlidx = group_a && (ir[28:26] == 3'd3);
  assign srcopc    = group_a && (ir[28:26] == 3'd6);
  assign srcq      = group_a && (ir[28:26] == 3'd7);
  assign srcvma    = group_b && (ir[28:26] == 3'd0);
  assign srcmap    = group_b && (ir[28:26] == 3'd1);
  assign srcmd     = group_b && (ir[28:26] == 3'd2);
  assign srclc     = group_b && (ir[28:26] == 3'd3);

  logic [31:0] mf;
  always_comb begin
    if (srclc) begin
      // Bit 30 is not driven.  `LC<25:1>` with the byte-mode bit under it.
      mf = {needfetch, 1'b0, lc_byte_mode, prog_unibus_reset,
            int_enable, sequence_break, lc[25:1], lc0b};
    end else if (srcopc) begin
      mf = {18'd0, opc};
    end else if (srcdc) begin
      mf = {22'd0, dc};
    end else if (srcpdlptr) begin
      mf = {22'd0, pdl_ptr};
    end else if (srcpdlidx) begin
      mf = {22'd0, pdl_idx};
    end else if (srcq) begin
      mf = q;
    end else if (srcmd) begin
      mf = md;
    end else if (srcvma) begin
      mf = vma;
    end else if (srcmap) begin
      mf = mf_map;
    end else begin
      // "Functional sources 0o15, 0o16 and 0o17: the 74S138 that decodes
      // IR<28:26> ... has those three outputs unconnected, so nothing on page
      // MF drives the bus, and an undriven TTL bus reads high."
      mf = {32{1'b1}};
    end
  end

  // pages ALATCH and MLATCH: which driver has the M bus.
  logic mpassm, spcenb, pdlenb, mfenb;
  assign mpassm = !ir[31];
  assign spcenb = srcspc || srcspcpop;
  assign pdlenb = srcpdlpop || srcpdltop;
  assign mfenb  = !mpassm && !(spcenb || pdlenb);

  always_comb begin
    if (mpassm)      m = mmem_out;
    else if (pdlenb) m = pdl_q;
    // `SPCPTR<4:0>` on M<28:24> through the 74S241 at 4B10, with the RAM's
    // own `SPCO` under it --- not the push pass-around, which is on the SPC
    // bus and goes to the next-address path instead.
    else if (spcenb) m = {3'd0, spcptr, 6'd0, spc_q[17:0]};
    else if (mfenb)  m = mf;
    else             m = 32'd0;
  end

  // page SMCTL: the shift and mask amounts, with the LC byte-mode tweak.
  logic lc_modifies_mrot, inst_in_left_half, inst_in_2nd_or_4th_quarter;
  logic sh4, sh3, mr, sr;
  logic [4:0] mskr, shift, mskl;
  assign lc_modifies_mrot = ir[10] && ir[11];
  assign inst_in_left_half = !((lc[1] ^ lc0b) || !lc_modifies_mrot);
  assign sh4 = !(inst_in_left_half ^ !ir[4]);
  assign inst_in_2nd_or_4th_quarter = !(lc[0] || !lc_modifies_mrot) && lc_byte_mode;
  assign sh3 = !(!ir[3] ^ inst_in_2nd_or_4th_quarter);
  assign mr  = !irbyte || ir[13];
  assign sr  = !irbyte || ir[12];
  assign mskr  = mr ? {sh4, sh3, ir[2:0]} : 5'd0;
  assign shift = sr ? {sh4, sh3, ir[2:0]} : 5'd0;
  assign mskl  = mskr + ir[9:5];

  // pages SHIFT0-1: a 32-bit rotate left.  A shift of zero leaves the second
  // term a 32-place shift of a 32-bit word, which is zero.
  assign r = (m << shift) | (m >> (6'd32 - {1'b0, shift}));

  // page MSKG4
  logic [31:0] msk;
  assign msk = ({32{1'b1}} >> (5'd31 - mskl)) & ({32{1'b1}} << mskr);

  // pages ALUC4, ALU0-1.  "The CADR ALU is nine 74S181s and three 74S182s:
  // eight slices covering alu<31:0>, plus a ninth fed with m[31] and a[31]
  // again, which sign-extends both operands to 33 bits.  That is why the JUMP
  // comparisons are signed."  The whole array at once, off the datasheet's
  // active-high function table.
  logic specalu, mul, div, divpos, divsub, divadd, mulnop, aluadd, alusub;
  assign specalu = ir[8] && iralu;
  assign mul     = specalu && (ir[4:3] == 2'b00);
  assign div     = specalu && (ir[4:3] == 2'b01);
  assign divpos  = q[0] || ir[6];
  assign divsub  = div && divpos;
  assign divadd  = div && (ir[5] || !divpos);
  assign mulnop  = mul && !q[0];
  assign aluadd  = (divadd && !a[31]) || (divsub && a[31]) || mul;
  assign alusub  = mulnop || (divsub && !a[31]) || (divadd && a[31]) || irjump;

  logic [3:0] aluf;
  logic       alumode, cin;
  always_comb begin
    unique case ({alusub, aluadd})
      2'b00:   begin aluf = {ir[3], ir[4], !ir[6], !ir[5]}; alumode = !ir[7]; cin = ir[2];  end
      2'b01:   begin aluf = 4'b1001; alumode = 1'b0; cin = 1'b0;    end
      2'b10:   begin aluf = 4'b0110; alumode = 1'b0; cin = !irjump; end
      default: begin aluf = 4'b1111; alumode = 1'b1; cin = 1'b1;    end
    endcase
  end

  logic [32:0] alu_x, alu_y, alu_f, alu_p, alu_q;
  logic        aeqm;
  assign alu_x = {m[31], m};   // the ninth slice sign-extends both operands
  assign alu_y = {a[31], a};

  always_comb begin
    alu_p = 33'd0;
    alu_q = 33'd0;
    if (alumode) begin
      // Logic, M = H.
      unique case (aluf)
        4'h0: alu_p = ~alu_x;
        4'h1: alu_p = ~(alu_x | alu_y);
        4'h2: alu_p = ~alu_x & alu_y;
        4'h3: alu_p = 33'd0;
        4'h4: alu_p = ~(alu_x & alu_y);
        4'h5: alu_p = ~alu_y;
        4'h6: alu_p = alu_x ^ alu_y;
        4'h7: alu_p = alu_x & ~alu_y;
        4'h8: alu_p = ~alu_x | alu_y;
        4'h9: alu_p = ~(alu_x ^ alu_y);
        4'ha: alu_p = alu_y;
        4'hb: alu_p = alu_x & alu_y;
        4'hc: alu_p = {33{1'b1}};
        4'hd: alu_p = alu_x | ~alu_y;
        4'he: alu_p = alu_x | alu_y;
        4'hf: alu_p = alu_x;
        default: ;
      endcase
    end else begin
      // Arithmetic, M = L.  Every function is `p + q + Cn` for some p, q
      // drawn from A and B; see the datasheet table.
      unique case (aluf)
        4'h0: begin alu_p = alu_x;             alu_q = 33'd0;              end
        4'h1: begin alu_p = alu_x | alu_y;     alu_q = 33'd0;              end
        4'h2: begin alu_p = alu_x | ~alu_y;    alu_q = 33'd0;              end
        4'h3: begin alu_p = {33{1'b1}};        alu_q = 33'd0;              end
        4'h4: begin alu_p = alu_x;             alu_q = alu_x & ~alu_y;     end
        4'h5: begin alu_p = alu_x | alu_y;     alu_q = alu_x & ~alu_y;     end
        4'h6: begin alu_p = alu_x;             alu_q = ~alu_y;             end
        4'h7: begin alu_p = alu_x & ~alu_y;    alu_q = {33{1'b1}};         end
        4'h8: begin alu_p = alu_x;             alu_q = alu_x & alu_y;      end
        4'h9: begin alu_p = alu_x;             alu_q = alu_y;              end
        4'ha: begin alu_p = alu_x | ~alu_y;    alu_q = alu_x & alu_y;      end
        4'hb: begin alu_p = alu_x & alu_y;     alu_q = {33{1'b1}};         end
        4'hc: begin alu_p = alu_x;             alu_q = alu_x;              end
        4'hd: begin alu_p = alu_x | alu_y;     alu_q = alu_x;              end
        4'he: begin alu_p = alu_x | ~alu_y;    alu_q = alu_x;              end
        4'hf: begin alu_p = alu_x;             alu_q = {33{1'b1}};         end
        default: ;
      endcase
    end
  end

  assign alu_f = alumode ? alu_p : (alu_p + alu_q + {32'd0, cin});
  assign alu   = alu_f[31:0];

  // "Each slice pulls AEB low unless its four result bits are all ones; the
  // eight slices are wired together open-collector.  In subtract mode that is
  // exactly A = B."
  assign aeqm = &alu_f[31:0];

  // page MO, and the output select on page OB.
  logic [31:0] mo;
  logic [1:0]  osel;
  assign mo   = (msk & r) | (~msk & a);
  assign osel = {ir[13] && iralu, ir[12] && iralu};

  always_comb begin
    unique case (osel)
      2'b00: ob = mo;
      2'b01: ob = alu_f[31:0];
      2'b10: ob = alu_f[32:1];
      // `(ALU << 1)` with `Q<31>` shifted in at the bottom.
      default: ob = {alu_f[30:0], q[31]};
    endcase
  end

  // page FLAG: the jump conditions, off the 74S151 at 3E01.
  // `SINTR` is `INT` off the cables, registered by the 74S175 at LCC 3E12 on
  // CLK3C; `SINT` is it under INT.ENABLE at 4D09.
  logic sintr_d;
  logic aluneg, sint, pgf_or_int, pgf_or_int_or_sb;
  logic [2:0] conds;
  assign aluneg           = !aeqm && alu_f[32];
  assign sint             = sintr_d && int_enable;
  assign pgf_or_int       = !vmaok || sint;
  assign pgf_or_int_or_sb = pgf_or_int || sequence_break;
  assign conds            = ir[5] ? ir[2:0] : 3'd0;

  always_comb begin
    unique case (conds)
      3'd0: jcond = r[0];
      3'd1: jcond = aluneg;
      3'd2: jcond = alu_f[32];
      3'd3: jcond = aeqm;
      3'd4: jcond = !vmaok;
      3'd5: jcond = pgf_or_int;
      3'd6: jcond = pgf_or_int_or_sb;
      default: jcond = 1'b1;
    endcase
  end

  // -------------------------------------------------- pages VMEM0, VMEM1
  //
  // THERE IS NO MMU STATE.  Both levels are asynchronous rams with the
  // first's output in the second's address, so a lookup is a ripple through
  // two rams inside one cycle and not a cycle of its own: VMEM0 1C14 is
  // addressed by MAPI13..23 and drives -VMAP4..0, which are VMEM1 1E04's
  // address along with -MAPI8A..12A.
  //
  // Which is why these two are the memories that stay asynchronous.  The
  // control store and the scratchpads went to block RAM behind a phase; a
  // level of map behind a registered read would need the second level's
  // address a tick before the first level can give it, and the ripple would
  // become a state machine.  At 2048 x 5 and 1024 x 24 they are small enough
  // for distributed RAM, which reads asynchronously as the 93425As do ---
  // about 1,100 LUTs between them, and the ripple stays a ripple.
  //
  // `MAPI` is `VMA` while `MEMSTART` is up and `MD` otherwise, off the
  // 74S258s at VMAS 1C20 and its fellows, whose select is -MEMSTART.

  logic [4:0]  l1_map [0:2047];
  logic [23:0] l2_map [0:1023];

  logic [15:0] mapi;
  logic [10:0] adr0;
  logic [9:0]  adr1;
  logic [4:0]  vmap;
  logic [23:0] vmo;
  assign mapi = memstart ? vma[23:8] : md[23:8];
  assign adr0 = mapi[15:5];
  assign vmap = l1_map[adr0];
  assign adr1 = {vmap, mapi[4:0]};
  assign vmo  = l2_map[adr1];

  // page VMEMDR 1D14: a 74S373 transparent while MEMSTART, so on such a cycle
  // it is already following the word the map is putting out.  -PFR and -PFW
  // come from this and not from the live map output.
  logic [23:0] lvmo, lvmo_eff;
  assign lvmo_eff = memstart ? vmo : lvmo;

  // pages VCTL1 and VCTL2, as the nets they name.  -PFR is -LVMO23 inverted
  // with no WRCYC in it, and -PFW is a NAND, so these read the opposite way
  // round to the names: -PFR is high when the read is *permitted*.
  //
  //     VCTL2 1D26  74S04A  -PFR   = NOT(-LVMO23)
  //     VCTL1 1D17  74S00   -PFW   = NAND(-LVMO22, WRCYC)
  //     VCTL1 1D17  74S00O  -VMAOK = NAND(-PFR, -PFW)
  logic pfr, pfw;
  assign pfr   = lvmo_eff[23];
  assign pfw   = !(!lvmo_eff[22] && wrcyc);
  assign vmaok = pfr && pfw;

  // What a SRCMAP puts on MF.  "Bit 29 is **zero**, not one.  VMEMDR 1A01
  // puts -PFW, -PFR, HI12 and -VMAP<4:0> onto MF<31:24> through a 74S240,
  // which *inverts*, and a pull-up on the input of an inverting buffer is a
  // hard zero on its output.  A one there would be right for a '241, which is
  // what this is easy to mistake it for."
  logic [31:0] mf_map;
  assign mf_map = {!pfw, !pfr, 1'b0, vmap, vmo};

  // page VMA: the register, and what it takes.  An instruction fetch puts the
  // location counter's word address up instead of OB.
  logic destvma, destmdr, vmaenb, wmap, wmapd;
  logic [31:0] vmas;
  assign destvma = destmem && !ir[22];
  assign destmdr = destmem && ir[22];
  assign wmap    = destmem && (ir[20:19] == 2'd3);
  assign vmaenb  = destvma || ifetch;
  assign vmas    = ifetch ? {8'd0, lc[25:2]} : ob;

  // ------------------------------------------------------------- VCTL1
  //
  // The memory cycle as MIT specify it: MEMPREPARE to MEMSTART to -MEMRQ,
  // MBUSY waiting on -MEMACK from the bus interface, and -WAIT and -HANG
  // holding the clock generator off meanwhile.  A stall costs time and not a
  // microcycle.
  //
  //     3F16  74S64  -WAIT = NOR((DESTMEM AND MBUSY.SYNC),
  //                              (USE.MD AND MBUSY AND -MEMGRANT),
  //                              (LCINC AND NEEDFETCH AND MBUSY.SYNC))
  //     3F17  74S10  -HANG = NAND(RD.IN.PROGRESS, USE.MD, -CLK3G)
  //
  // WAIT stops the cpu clock and lets the master clock run, which is what lets
  // the bus interface start the cycle being waited for; HANG stops both, which
  // is why it must not happen before -MEMGRANT --- MIT's own warning, and the
  // second WAIT term is the gate that enforces it.
  //
  // In this fabric -WAIT is a term of MACHRUN, as the 9S42 at OLORD1 1A15 has
  // it, and -HANG goes to the generator's own input.  `src/rtl.rs` factors
  // both out into `Rtl::stall` instead, because its engine advances a
  // microcycle at a time; the two arrive at the same nanoseconds.

  logic mbusy, mbusy_sync, rd_in_progress;
  logic wait_, hang;

  // `MEMRQ` off the 9S42 at 1E25 is `MEMSTART AND VMAOK OR MBUSY`.
  logic memrq;
  assign memrq   = (memstart && vmaok) || mbusy;
  assign n_memrq = !memrq;

  // What MBUSY will hold after this tick, which is what MBUSY.SYNC has to
  // register.  `-MFINISHD` clearing MBUSY in the very tick MCLK1A samples it
  // is not a rare case: it is where a whole 220 ns wait cycle turns on, and
  // measured, it is the difference on the disk loop's every third stall.
  // `Rtl::master_clock_cycle` runs `after_memack` before it takes MBUSY.SYNC,
  // so the clear is seen; a register sampling MBUSY as it stood would wait a
  // cycle too long.
  logic mbusy_next;
  always_comb begin
    mbusy_next = mbusy;
    if (mfinish_clearing) mbusy_next = 1'b0;
    if (cpu_edge && memstart && vmaok) mbusy_next = 1'b1;
  end

  assign wait_ = (destmem && mbusy_sync)
              || (use_md && mbusy && n_memgrant)
              || (lcinc && needfetch && mbusy_sync);
  // A WAIT comes first, and this is not a tidiness: parking the generator
  // stops the master clock, and the master clock is what MBUSY.SYNC follows
  // MEMRQ on --- so a park taken while -WAIT is up would hold the cpu clock
  // for ever with nothing left to end it.  `Rtl::stall` answers `Wait` before
  // `Hang` for the same reason and is the reference here.  The board's own
  // answer is the `-CLK3G` term on the 74S10 at 3F17, which gates -HANG to
  // part of the cycle; muir leaves that term out and so does this.
  assign hang = use_md && rd_in_progress && !wait_;

  // "Cleared by MEMACK delayed by about 150 ns" --- `-RDFINISH` is `-MFINISH`
  // through the TD50 at VCTL1 1D23 and then the TD250 at 1D22, which is 140 ns
  // on the tap ordering `src/part.rs` records.  `MBUSY` clears on `-MFINISHD`,
  // the 30 ns tap of the same TD50.  Two countdowns off the acknowledgement.
  //
  // **-RDFINISH is two ticks short of its 140, and deliberately.**  Ending a
  // hang costs this fabric two ticks that the board spends in gate
  // propagation delay: RD.IN.PROGRESS falls on the tick the countdown
  // expires, and the parked generator needs one more tick to see -HANG lift
  // and another to raise TPCLK.  Charged in full, every hang ends 10 ns after
  // muir ends it --- and there are 11,404 hangs in the boot PROM, so it is
  // not a rounding one can leave.  The delay line is 140 ns; two ticks of it
  // are spent here instead, and this is where that is written down.
  localparam int unsigned MFINISHD_T  = 30 / 5;
  localparam int unsigned RD_FINISH_T = (140 / 5) - 2;

  logic       n_memack_q;
  logic [5:0] mfinish_t, rdfinish_t;
  logic       memack_edge, mfinish_clearing;
  assign memack_edge      = !n_memack && n_memack_q;
  assign mfinish_clearing = (mfinish_t == 6'd1) && !memack_edge;

  // page Q 2A05-2A11: the 74S194s shift under `QS1`/`QS0`.
  logic qs1, qs0;
  assign qs1 = ir[1] && iralu;
  assign qs0 = ir[0] && iralu;

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
      sintr_d      <= 1'b0;
      memstart     <= 1'b0;
      mbusy        <= 1'b0;
      mbusy_sync   <= 1'b0;
      rdcyc        <= 1'b0;
      wrcyc        <= 1'b0;
      rd_in_progress <= 1'b0;
      vma          <= 32'd0;
      wmapd        <= 1'b0;
      // What the latch at VMEMDR comes up holding. `Chip::power_on` puts
      // every register's outputs low, and the latch's are the active-low
      // -LVMO23, -LVMO22 and -PMA21..8, so the positive word is the two
      // permission bits and the page all ones. The board's own power-on
      // state is undefined, so this is a convention shared with muir and not
      // a fact about the hardware; `machine.rs` has the whole account under
      // LVMO_AT_POWER_ON.
      lvmo         <= {1'b1, 1'b1, 8'd0, 14'h3fff};
      n_memack_q   <= 1'b1;
      mfinish_t    <= 6'd0;
      rdfinish_t   <= 6'd0;
      prog_unibus_reset <= 1'b0;
      q            <= 32'd0;
      dc           <= 10'd0;
      for (int unsigned k = 0; k < 8; k++) opcs[k] <= 14'd0;
    end else begin
      // The acknowledgement's two delays, which run on their own and not on
      // the cpu clock: a stall is what they are there to end.
      n_memack_q <= n_memack;
      if (memack_edge) begin
        mfinish_t  <= 6'(MFINISHD_T);
        rdfinish_t <= 6'(RD_FINISH_T);
      end else begin
        if (mfinish_t != 6'd0) begin
          mfinish_t <= mfinish_t - 6'd1;
          if (mfinish_clearing) mbusy <= 1'b0;
        end
        if (rdfinish_t != 6'd0) begin
          rdfinish_t <= rdfinish_t - 6'd1;
          if (rdfinish_t == 6'd1) rd_in_progress <= 1'b0;
        end
      end

      // The master clock, which runs whether or not the cpu's does.
      if (mclk_edge) begin
        // `MBUSY.SYNC` is `MEMRQ` registered on MCLK1A, the second flip flop
        // of the 74S175 at VCTL1 1E20.  "Since you must wait during the first
        // half of a clock cycle, the busy condition (MEMRQ) must be
        // synchronized."  It is on the *master* clock, so it goes on
        // following MEMRQ through a WAIT --- which is what ends the wait.
        mbusy_sync <= (memstart && vmaok) || mbusy_next;
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
        sintr_d     <= sintr;
        if (destintctl) begin
          lc_byte_mode      <= ob[29];
          prog_unibus_reset <= ob[28];
          int_enable        <= ob[27];
          sequence_break    <= ob[26];
        end

        // page Q 2A05-2A11
        if (qs1 || qs0) begin
          unique case ({qs1, qs0})
            2'b01:   q <= {q[30:0], !alu_f[31]};
            2'b10:   q <= {alu_f[0], q[31:1]};
            default: q <= alu_f[31:0];
          endcase
        end

        // page VCTL2: the map write is delayed, gated by WMAPD.
        wmapd <= wmap;
        // page VMA
        if (vmaenb) vma <= vmas;

        // page VCTL1: the memory cycle.  MEMPREPARE is the write phase's
        // level and MEMSTART its registered copy, so a cycle prepared here
        // runs over the next microcycle.
        if (memstart) lvmo <= vmo;
        if (memstart && vmaok) begin
          mbusy      <= 1'b1;
          mfinish_t  <= 6'd0;
          // READ IN PROGRESS comes up on the same edge for a read, and has no
          // falling time until -MEMACK gives it one.
          if (rdcyc) begin
            rd_in_progress <= 1'b1;
            rdfinish_t     <= 6'd0;
          end
        end
        // WRCYC and RDCYC are one flip flop, the 74S175 at 1C23 on CLK2A:
        // load or hold, so the direction is the *starting* instruction's and
        // it stands until the next cycle starts.
        if (memop) begin
          wrcyc <= memwr;
          rdcyc <= !memwr;
        end
        memstart <= memop;

        // page DSPCTL 3C14/3C15: the 25S07s are enabled by -IRDISP and
        // clocked by CLK3E, so they take IR<41:32> of the DISPATCH itself ---
        // the word standing before this edge, not the one it loads.  Reading
        // the new IR here is a cycle early.
        if (irdisp) dc <= ir[41:32];
      end
    end
  end

  // What this slice does not read, named so that lint says so rather than
  // waving it through:
  //
  //   n_tpclk, tptse           the tri-state enables, -TSE1..4 --- nothing in
  //                            the fabric tri-states, so the drivers are muxes
  //   n_tpr60                  SPEEDCLK, counted from the boundary instead
  //   funct<0>, funct<3>       misc functions 0 and 3, neither of them -HALT
  //   spcv<20:15>              the stack's word above the return address:
  //                            it reaches the parity check and nothing else
  //   lvmo_eff<21:0>           -PMA21..8, the physical page: it leaves on the
  //                            cables as the bus cycle's address, which is
  //                            the bus interface's half and not this one's
  //   dmask<7>                 the mask reaches DADR<6:1> and DADR<0>; its
  //                            top bit is only there so 1 << 7 has the room
  //   destmdr                  MD's own write.  MD is the last port: its
  //                            other half is the word -LOADMD strobes off
  //                            the bus, and that is the memory's to give
  logic unused;
  assign unused = &{1'b0, n_tpclk, tptse, n_tpr60, funct[0], funct[3],
                    spcv[20:15], lvmo_eff[21:0], destmdr, dmask[7]};

endmodule

`default_nettype wire
