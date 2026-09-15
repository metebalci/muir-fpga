// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The display controller: MIT's TV, muir's `tv::Tv`, as an Xbus
// slave --- the register face, the sync program and the vertical interrupt.
//
// What the board is, from `src/tv.rs` and the sources it cites
// (`sys/window/shwarm.lisp`, `cadrtv/lmtv.order`, `data/SIMPLETV.netlist`):
// a 32,768-word frame buffer at `0o17000000`, eight control words at
// `0o17377760`, and a vertical flag.  Register 0 is the mode register ---
// the Am25LS2519 at NXBCTL 0F12 holding `MODE<3:0>`: `CLOCK MODE<1:0>`,
// `MODE BOW` and `MODE INTR ENB` --- read back through the 74LS244 at 0F11
// with `VERT FLAG` in bit 4, `VSYNC` and `HSYNC` in bits 5 and 6 off the
// sync generator, and bit 7 reading zero because ECO 2 of `cadrtv/lmtv.eco`
// grounds it on this board.
// **The flag is a flop of its own, the 74LS74 at 0E14: preset by `-TVMA
// CLR`, the sync program's start of field; clocked by `-LOAD MODE` with
// `XDI 4` as its data, so a write of the register puts the written bit 4
// into it; cleared by `-RESET`, which is `-XBUS INIT`.**
// `SEND INTR` is the flag ANDed with the enable at the 74S08 at 0D10, and
// that is what the board puts on `-XBUS.INTR`.  Registers 1 to 3 are the
// sync program RAM --- the eight 2147s at NSYRAM, 4K by 8 --- its data at
// the pointer, the pointer (write only, twelve bits) and the enable (write
// only, bit 7 selecting the RAM over the PROM, bits 6 to 0 the vertical
// spacing).  Register 4 is the COLOUR register: the 74S138 at 0F13 drives
// `-LOAD COLOR` from it, and `lmtv.order` gives it as write only with the
// map value in bits 15 to 8, the channel in 7 and 6 and the colour in 3 to 0.
// The map RAMs and their converters are off the board, so the write reaches
// nothing here: this answers the write and keeps nothing, because nothing on
// this board can read the map back.  muir's model keeps the sixteen entries
// --- three channels each, `tv::Tv::color_map` --- for its colour board and
// its checkpoint; the register is write only on both boards, so no check
// here reads one back.
// Only 5 to 7 are the three `lmtv.order` says "respond but don't do
// anything".
//
// **THE SYNC PROGRAM IS RUN, AND IT IS WHAT MAKES THE FRAME.**  `lmtv.order`,
// `>Sync Program`: "The Sync Program executes an instruction every (32, 16,
// 8, 32) bits of video (indexed by Mode<1-0>) or roughly every 1/2
// microsecond", and it "is structured as a series of loops.  Each loop is
// executed a fixed number of times between 1 and 256.  A loop starts with a
// word containing the number of times it is to be executed.  This word is
// never executed as an instruction, and does not cause a time delay ... The
// second to last instruction of a loop contains Special Function 2 or 3; one
// more instruction is executed (JUMP-XCT-NEXT) and then control returns to
// the first instruction of the loop, unless the repeat counter has counted
// out."  An End of Program sends control back to location 0; an End of Loop
// takes the word after next as the next loop's repeat count.  That is the
// whole machine below, and muir runs the same rules in `src/tv/sync.rs`.
//
// Three things come off it and nothing else here does:
//
//   **`VSYNC` and `HSYNC` in the mode register are the program's own bits 1
//   and 0**, latched at the instruction boundary AFTER the instruction that
//   carries them --- read off the netlist SIMPLE TV, `src/tv/sync.rs`.  On
//   MIT's own `cpt.prom` the pair changes 1,932 times in one frame, which is
//   what `%XBUS-WRITE-SYNC` in the colour software waits on.
//
//   **`-TVMA CLR`, the program's Special Function 1, presets the vertical
//   flag** --- `lmtv.order`: "this is set by TVMA CLR, not by the start of
//   Vertical Sync".  For `cpt.prom` in clock mode 0 that falls 16,000 ns
//   into the program, as the first line's 32nd instruction completes, and
//   once a frame of 15,456,000 ns thereafter.  It is NOT the frame boundary
//   and this module counted from the boundary until the sync program landed.
//
//   **The program's start MOVES.**  A write that changes `CLOCK MODE<1:0>`,
//   a write of a RAM word while the RAM is selected, or a change of the
//   RAM's enable runs the program afresh from location 0 --- `Tv::restart`
//   --- so the flag's phase is not fixed to power-on at all.
//
// **AN INSTRUCTION IS 100 OR 125 TICKS AND NOTHING ROUNDS.**  500 ns in
// clock modes 0 and 1 and 625 ns in modes 2 and 3 (`sync::INSTRUCTION_NS`,
// measured on the netlist LISPM TV with `cpt.prom` running), which on MIT's
// 5 ns grid is exactly 100 and 125.  muir walks the whole program into a
// timeline because a model jumps in time; this executes one instruction
// every 100 or 125 ticks, which is a program counter, a repeat counter and
// the two sync bits latched an instruction late.  MIT's `cadrtv/cpt.prom` is
// the program from power-on, `$readmemh`'d from `SYNC_PROM_HEX` as the boot
// PROM's image is, until the software loads the RAM and selects it.
//
// **WHERE THIS PARTS FROM muir, MEASURED AND BOUNDED.**  Two instants, both
// of them muir looking at a program it has already walked to the end:
//
//   `Timeline::sync_at` answers, for the first instruction of a run, the
//   bits the program leaves at the END of a run --- right for a program that
//   has been running, and a guess for the first run after a restart, which is
//   the only run where no instruction has landed yet.  The 74LS175 at NSYREG
//   0D02 is a register with no clear on the program's start, so this module
//   holds the bits it held, and at power-on it holds zero.  The reference
//   trace does not read the mode register there and `golden/src/tv.rs` says
//   so at the assert that keeps it out.
//
//   `Timeline::of` answers None for a program that runs off the end of its
//   store without an End of Loop, and answers it AT THE RESTART; this module
//   discovers it by fetching, and stops when the fetch runs past the
//   program.  No walk in the reference gets as far as one instruction before
//   the next restart replaces it, and the generator asserts that too.
//
// **AND NO FRAME BUFFER**: the bitmap lives in PS DDR3, in the 8 MB
// `cadr_ddr_map.sv` reserves for the display, so that whatever draws the
// screen --- a display output block, an RFB server on the processing system
// --- reads it from there.  A cycle to the window is answered by MAIN
// MEMORY'S BRIDGE at the display's base: this module decodes the window and
// says so on `fb_sel`, and `cadr_memory_path.sv` selects the bridge on it,
// exactly as it does for main memory.  One bridge and one memory port rather
// than a second master, because the Xbus has one master a cycle and the
// bridge is idle whenever this window is asked --- the disk's channel reaches
// main memory alone and never the window.  What that costs against muir is
// what main memory already costs: muir's TV answers a buffer word in no time
// of its own and the board's DDR answers when it answers, so the composed
// machine waits on the frame buffer as it waits on memory.  In the check the
// modelled DDR answers at once and the timing agrees with muir tick for tick.
//
// THE ANSWER IS A GATE, as the disk's is and for the same measured reason:
// muir's TV takes 0 ns of its own (`IDEAL_DEVICE_NS`), so a read
// acknowledges 140 ns after the grant and a write at 80, and
// `cadr_busint_xbus.sv` supplies both delays itself.  `dev_ack` is the
// held address match alone; the AND with `-XBUS.RQ` is made at the bus
// interface, where the disk's note at its `dev_ack` says it must be.
//
// **THE STORE LANDS ONE TICK AFTER `-XBUS.RQ` RISES, AND THE REFERENCE SAYS
// SO.**  A register takes the word at the clock edge after the request is
// first seen; muir's `Rtl` hands it over at the request's own instant.  On
// the board the 2519 clocks on `-LOAD MODE`, a gate or two behind `XBUS
// RQ`, so a tick is nearer the board than none.  `golden/src/tv.rs` writes
// the model at `answered_at + 5` for that reason and holds `-XBUS.INTR` at
// every tick to it, so the tick is a stated instant and not a tolerance.
// There is no further hold: the store's decision is `ctl && dev_rq &&
// dev_write && !taken` --- the held match, `-XBUS.RQ`, the direction and
// the cycle's latch, one AND --- where the disk's START needed its whole
// decode held to reach a data pin in time.
//
// **PRIORITY AT ONE EDGE: `-XBUS INIT`, then the write, then the preset,
// and a restart over the instruction boundary.**  A write landing on the
// tick a `-TVMA CLR` falls keeps the written bit --- muir's `vert_flag` asks
// for a field *strictly* since `written_at` --- and a restart landing on an
// instruction boundary suppresses that boundary, because muir's new timeline
// begins at the restart and the old one's last instruction is not in it.
// Init over everything, because the 74LS74's clear is a pin and not a clock.
//
// THE HELD MATCH.  `ctl`, `fb` and `which` are taken once from `phys` ---
// the far end of the map, constant for the whole microcycle --- and held
// a tick, as `cadr_memory_path.sv` holds its decode and the disk holds
// `mine`.  Any future Xbus slave must hold its address match and not
// compute it: the disk's first draft computed it and missed by 6 ns.
// They are the two registers of this module `rtl/plumbing/xilinx7/cadr_machine.xdc`
// leaves in its relaxed set; everything else here is timed at the tick.

`default_nettype none

module cadr_tv #(
    // MIT's sync PROM as a `$readmemh` image, `build/sync_prom.hex`, written
    // by `golden/src/sync_prom.rs` out of muir's own `cadrtv/cpt.prom`.  Named
    // at elaboration and absolute, for the reason `cadr_microcycle.sv`'s
    // `PROM_HEX` is: `$readmemh` resolves against the working directory, and
    // a model built with the relative default runs only from the repository
    // root.  A file that is not there is a WARNING and leaves a program of
    // zeros, which is a display that never interrupts, so the guard below
    // makes it loud where a simulator can say so.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex"
) (
    input  var logic        clk,        // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // `-XBUS INIT` on the backplane: clears the vertical flag's flop and
    // nothing else on this board --- the mode register and the sync RAM's
    // enable clear on `-POWER RESET`, which is `rst` here.
    input  var logic        xbus_init,

    // The Xbus slave side, exactly as `cadr_disk_controller.sv` takes it.
    input  var logic        sel,        // the decode says this cycle is a device's
    input  var logic        dev_rq,     // -XBUS.RQ, as a positive level
    input  var logic        dev_write,
    input  var logic [21:0] phys,       // -XADDR21..0, a word address
    input  var logic [31:0] wdata,      // MEM<31:0> from the cpu
    output var logic        dev_ack,    // -XBUS.ACK, for the control words
    output var logic [31:0] rdata,      // MEM<31:0> to the cpu
    output var logic        drives,     // this slave is driving MEM<31:0>

    // This cycle is the frame buffer's: held, for main memory's bridge to
    // answer at the display's base.  The window's decode is this board's
    // --- the MAPADR switch on the SIMPLE TV, "for the normal TV, x is 6"
    // --- and it is held here for the reason `mine` is held in the disk.
    output var logic        fb_sel,

    // `SEND INTR`: the vertical flag with the interrupt enable, onto
    // `-XBUS.INTR`.
    output var logic        intr
);

  // tv::CONTROL, 0o17377760, in eights; tv::BUFFER,
  // 0o17000000, in 32,768s.  The same constants `cadr_xbus_decode.sv`
  // makes `device` from, held here because a board decodes its own
  // address and the decode's `device` is one signal for every slave.
  localparam logic [18:0] CONTROL_PAGE = 19'd507902;
  localparam logic [6:0]  BUFFER_SLOT  = 7'd120;

  // The sync program's three stores, and the two lengths that matter.
  //
  // `tv::SYNC_RAM_WORDS`: the eight 2147s at NSYRAM 0A01-0B04, 4K by 1 each,
  // addressed by the twelve bits of the pointer.
  localparam int SYNC_RAM_WORDS = 4096;
  // The 74S472 beside them, 512 by 8, which the enable selects against.  The
  // image is the whole chip so that nothing in it is undefined.
  localparam int SYNC_CHIP_WORDS = 512;
  // And the 297 words of it MIT burned, `cadrtv/cpt.prom`.  muir sizes its
  // image to the highest address burned and calls a fetch past it a program
  // that makes no frame, so this is where a PROM fetch runs off the end; the
  // unburned tail reads zero, which is what a read of register 1 above the
  // program gives.  `golden/src/tv.rs` puts the number in the trace's header
  // and `tb/cadr_tv_tb.cpp` holds this constant to it.
  localparam int SYNC_PROM_WORDS = 297;

  // An instruction of the sync program, in ticks of MIT's 5 ns grid: 500 ns
  // in clock modes 0 and 1 and 625 ns in modes 2 and 3, `sync::INSTRUCTION_NS`
  // measured on the netlist LISPM TV.  **Exactly 100 and 125 --- nothing
  // rounds**, which is the constraint the whole machine is built on and the
  // reason a tick stays MIT's 5 ns here while the board clocks one at 10.
  localparam logic [6:0] INSTRUCTION_T_FAST = 7'd100;
  localparam logic [6:0] INSTRUCTION_T_SLOW = 7'd125;

  // --- the held match --------------------------------------------------
  logic       ctl_c, fb_c, ctl, fb;
  logic [2:0] which_c, which;
  assign ctl_c   = sel && (phys[21:3] == CONTROL_PAGE);
  assign fb_c    = sel && (phys[21:15] == BUFFER_SLOT);
  assign which_c = phys[2:0];

  assign fb_sel  = fb;
  // 0 ns of its own, and a gate: see the top.
  assign dev_ack = ctl;

  logic asked;
  assign asked  = ctl && dev_rq;
  assign drives = ctl && !dev_write;

  // --- the registers -----------------------------------------------------
  logic [3:0]  mode;      // MODE<3:0>, the 2519
  logic        flag;      // VERT FLAG, the 74LS74 at 0E14
  logic [11:0] pointer;   // the sync RAM's address, register 2
  // Register 3's bit 7: the sync enable, which selects the RAM over the PROM
  // and so decides both what register 1 reads back and which program the
  // generator runs.  Bits 6 to 0 are the vertical spacing, which the
  // 74LS273 at NTVINC 0A07 holds for the video cycles this module does not
  // make --- nothing reads them back, in muir or here, so they have no
  // register and lint agrees.
  logic        sync_on;

  // --- the sync program's two stores -------------------------------------
  //
  // Two read ports each: the register face reads at the pointer, and the
  // generator fetches at its own address.  A simple dual port, written as
  // the two processes Vivado infers one from --- and a plain read in each,
  // because Vivado refuses a RAM process with a mux on its read.
  logic [7:0] sync_ram  [SYNC_RAM_WORDS];
  logic [7:0] sync_prom [SYNC_CHIP_WORDS];

  logic [7:0] ram_face, ram_seq, prom_face, prom_seq;

  // --- the sync generator ------------------------------------------------
  //
  // `Timeline::of`'s walk, one instruction every INSTRUCTION_T ticks.
  // `seq_a` is the address standing on the generator's read port; the word
  // at it is `seq_word`, two ticks behind an assignment to `seq_a` and so
  // settled long before the boundary that uses it, an instruction being a
  // hundred ticks.  `seq_load` counts those two ticks out after the address
  // of a loop's repeat count is applied: the count word "is never executed
  // as an instruction, and does not cause a time delay", so the loading
  // costs no time of its own and the boundary keeps counting through it.
  logic [12:0] seq_a;       // thirteen bits, so that past the RAM is visible
  logic [12:0] seq_first;   // the loop's first instruction
  logic [12:0] seq_after;   // the JUMP-XCT-NEXT instruction that leaves it
  logic [8:0]  seq_left;    // iterations left, 1 to 256
  logic        seq_one_more;
  logic [1:0]  seq_ended;   // 2 End of Loop, 3 End of Program
  logic [1:0]  seq_load;    // ticks left before a repeat count is taken
  logic        seq_alive;   // a program that makes a frame is still running
  logic [6:0]  seq_t;       // ticks into the instruction
  logic        sync_h, sync_v;  // the 74LS175 at NSYREG 0D02

  logic [6:0] step_t;
  assign step_t = mode[1] ? INSTRUCTION_T_SLOW : INSTRUCTION_T_FAST;

  logic [7:0] seq_word;
  assign seq_word = sync_on ? ram_seq : prom_seq;

  // `program.get(p)?`: the RAM is the twelve bits its 2147s address, the
  // PROM the 297 words MIT burned.
  logic seq_past;
  assign seq_past = sync_on ? seq_a[12] : (seq_a >= 13'(SYNC_PROM_WORDS));

  logic seq_fire;
  assign seq_fire = seq_alive && (seq_load == 2'd0) && (seq_t == step_t - 7'd1);

  // `-TVMA CLR`, Special Function 1, at the instant the instruction carrying
  // it completes.
  logic tvma_clr;
  assign tvma_clr = seq_fire && !seq_past && (seq_word[7:6] == 2'b01);

  // The iteration ends at the instruction after the one that carried the End
  // of Loop or End of Program: `one_more && p == after`.
  logic seq_end_of_iteration;
  assign seq_end_of_iteration = seq_one_more && (seq_a == seq_after);

  // ONCE PER BUS CYCLE, the way `cadr_xbus_ddr.sv` latches `done`: -XBUS.RQ
  // stands for tens of ticks and the word is taken at the first of them.
  logic taken, store_now;
  assign store_now = asked && dev_write && !taken;

  // A write that changes the program the generator runs, or the rate it runs
  // at, runs it afresh from location 0: `Tv::restart`.
  logic restart;
  assign restart = store_now
      && ( (which == 3'd0 && ((wdata[1:0] ^ mode[1:0]) != 2'd0))
        || (which == 3'd1 && sync_on)
        || (which == 3'd3 && (wdata[7] != sync_on)) );

  // What a read gives: the mode register with the flag in bit 4 and the sync
  // generator's two bits above it; the sync program's word at the pointer,
  // out of whichever store the enable selects, "31-8 garbage" read as zero;
  // and nothing from the write-only and the empty registers.
  logic [7:0] face_word;
  assign face_word = sync_on ? ram_face
                             : ((pointer[11:9] == 3'd0) ? prom_face : 8'd0);

  logic [31:0] word;
  always_comb begin
    unique case (which)
      3'd0:    word = {25'd0, sync_h, sync_v, flag, mode};
      3'd1:    word = {24'd0, face_word};
      default: word = 32'd0;
    endcase
  end
  assign rdata = drives ? word : 32'd0;

  assign intr = mode[3] && flag;

  // The sync program RAM, port A: the register face.  A store into register 1
  // writes the byte at the pointer, and the word at the pointer is read every
  // tick.
  always_ff @(posedge clk) begin
    if (store_now && which == 3'd1) sync_ram[pointer] <= wdata[7:0];
    ram_face <= sync_ram[pointer];
  end

  // And port B: the generator's fetch.
  always_ff @(posedge clk) begin
    ram_seq <= sync_ram[seq_a[11:0]];
  end

  // MIT's PROM, the same two ports.  Read at elaboration, and checked: a
  // `$readmemh` of a file that is not there is a warning, and a program of
  // zeros is a display that never interrupts and never moves a sync bit ---
  // which would pass every check that does not read this board.
  initial begin
    $readmemh(SYNC_PROM_HEX, sync_prom);
`ifdef VERILATOR
    if (sync_prom[0] !== 8'h01)
      $fatal(1, "cadr_tv: %s is not MIT's cadrtv/cpt.prom: word 0 is %02h, wanting 01",
             SYNC_PROM_HEX, sync_prom[0]);
`endif
  end

  always_ff @(posedge clk) begin
    prom_face <= sync_prom[pointer[8:0]];
    prom_seq  <= sync_prom[seq_a[8:0]];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ctl     <= 1'b0;
      fb      <= 1'b0;
      which   <= 3'd0;
      mode    <= 4'd0;
      flag    <= 1'b0;
      pointer <= 12'd0;
      sync_on <= 1'b0;
      taken   <= 1'b0;

      // Power-on: the PROM's program from location 0.  The 74LS175 that
      // holds the sync bits comes up cleared here; on the board it comes up
      // undefined and the first instruction lands 500 ns later, which is
      // before any processor exists to read it.  See WHERE THIS PARTS FROM
      // muir at the top.
      seq_a        <= 13'd0;
      seq_first    <= 13'd1;
      seq_after    <= 13'd1;
      seq_left     <= 9'd1;
      seq_one_more <= 1'b0;
      seq_ended    <= 2'd0;
      seq_load     <= 2'd2;
      seq_alive    <= 1'b1;
      seq_t        <= 7'd0;
      sync_h       <= 1'b0;
      sync_v       <= 1'b0;
    end else begin
      ctl   <= ctl_c;
      fb    <= fb_c;
      which <= which_c;

      // The flag: init over the write over the preset.  See the top.
      if (xbus_init)                       flag <= 1'b0;
      else if (store_now && which == 3'd0) flag <= wdata[4];
      else if (tvma_clr)                   flag <= 1'b1;

      // The four pins of the 2519 land; the sync registers take theirs;
      // everything above bit 3, 11 or 7 has nowhere to be stored, and the
      // spacing below the enable nothing to be read by.
      if (store_now) begin
        unique case (which)
          3'd0:    mode    <= wdata[3:0];
          3'd2:    pointer <= wdata[11:0];
          3'd3:    sync_on <= wdata[7];
          default: ;
        endcase
      end

      if (!asked)         taken <= 1'b0;
      else if (store_now) taken <= 1'b1;

      // --- the sync generator ---------------------------------------------
      if (restart) begin
        // From location 0, which holds a repeat count.  The sync bits are
        // not touched: the 74LS175 has no clear on the program's start.
        seq_a        <= 13'd0;
        seq_one_more <= 1'b0;
        seq_ended    <= 2'd0;
        seq_load     <= 2'd2;
        seq_alive    <= 1'b1;
        seq_t        <= 7'd0;
      end else if (seq_load != 2'd0) begin
        // The repeat count, once its word has arrived: "a word containing
        // the number of times it is to be executed ... never executed as an
        // instruction, and does not cause a time delay", and a zero is the
        // counter's 256, the count being eight bits.
        if (seq_load == 2'd1) begin
          if (seq_past) begin
            seq_alive <= 1'b0;
          end else begin
            seq_left  <= (seq_word == 8'd0) ? 9'd256 : {1'b0, seq_word};
            seq_first <= seq_a + 13'd1;
            seq_a     <= seq_a + 13'd1;
            // `let mut ended = Special::None;` and `let mut after = first;`
            // at the top of each loop: a loop that carries no End of Loop
            // and no End of Program never ends an iteration and walks off
            // the end of the program, which is what `Timeline::of` calls a
            // program that makes no frame.
            seq_after    <= seq_a + 13'd1;
            seq_one_more <= 1'b0;
            seq_ended    <= 2'd0;
          end
        end
        seq_load <= seq_load - 2'd1;
        seq_t    <= seq_t + 7'd1;
      end else if (seq_fire) begin
        seq_t <= 7'd0;
        if (seq_past) begin
          // The walk ran off the end of the program: no frame, and nothing
          // moves again until a restart.  `Timeline::of` answers None.
          seq_alive <= 1'b0;
        end else begin
          // The bits land at the boundary after the instruction.
          sync_h <= seq_word[0];
          sync_v <= seq_word[1];

          // Special Function 2 is End of Loop and 3 End of Program, so bit 7
          // is the whole test; 1 is `-TVMA CLR` and 0 no special function.
          if (seq_word[7] && !seq_one_more) begin
            seq_ended    <= seq_word[7:6];
            seq_one_more <= 1'b1;
            seq_after    <= seq_a + 13'd1;
          end

          if (seq_end_of_iteration) begin
            if (seq_left > 9'd1) begin
              seq_left     <= seq_left - 9'd1;
              seq_a        <= seq_first;
              seq_one_more <= 1'b0;
            end else if (seq_ended == 2'b11) begin
              // End of Program: "control returns to location 0 of the Sync
              // Program ... which is expected to contain a repeat count".
              seq_a    <= 13'd0;
              seq_load <= 2'd2;
            end else begin
              // End of Loop: "the location after next is taken as the repeat
              // count of the next loop".
              seq_a    <= seq_after + 13'd1;
              seq_load <= 2'd2;
            end
          end else begin
            seq_a <= seq_a + 13'd1;
          end
        end
      end else begin
        seq_t <= seq_t + 7'd1;
      end
    end
  end

  // The word's bits above the widest register here go nowhere, and the
  // reference says so: a write of 0xFFFFFFE5 to the mode register reads
  // back as 0o5.
  logic unused;
  // `seq_word[5:2]` are the instruction's Blank, Composite Sync and Video
  // Buffer Cycle Type: this module makes no video cycles and drives no
  // monitor, so nothing here reads them, and a bit nothing reads is a lint
  // error unless it is said out loud.
  assign unused = &{1'b0, wdata[31:12], seq_word[5:2]};

endmodule

`default_nettype wire
