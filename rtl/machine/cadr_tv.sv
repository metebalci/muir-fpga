// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The display controller: MIT's TV, muir's `simpletv::SimpleTv`, as an Xbus
// slave --- the register face and the vertical interrupt.
//
// What the board is, from `src/simpletv.rs` and the sources it cites
// (`sys/window/shwarm.lisp`, `cadrtv/lmtv.order`, `data/SIMPLETV.netlist`):
// a 32,768-word frame buffer at `0o17000000`, eight control words at
// `0o17377760`, and a vertical flag.  Register 0 is the mode register ---
// the Am25LS2519 at NXBCTL 0F12 holding `MODE<3:0>`: `CLOCK MODE<1:0>`,
// `MODE BOW` and `MODE INTR ENB` --- read back through the 74LS244 at 0F11
// with `VERT FLAG` in bit 4 and bits 5 to 7 (VSYNC, HSYNC, SYNC PROM ENB)
// undriven here and zero, as `lmtv.order` and ECO 2 say they must read.
// **The flag is a flop of its own, the 74LS74 at 0E14: preset by `-TVMA
// CLR`, the sync program's start of frame, once a frame; clocked by `-LOAD
// MODE` with `XDI 4` as its data, so a write of the register puts the
// written bit 4 into it; cleared by `-RESET`, which is `-XBUS INIT`.**
// `SEND INTR` is the flag ANDed with the enable at the 74S08 at 0D10, and
// that is what the board puts on `-XBUS.INTR`.  Registers 1 to 3 are the
// sync program RAM --- the eight 2147s at NSYRAM, 4K by 8 --- its data at
// the pointer, the pointer (write only, twelve bits) and the enable (write
// only, bit 7 selecting the RAM over the PROM, bits 6 to 0 the vertical
// spacing); 4 to 7 "respond but don't do anything".
//
// **WHAT IS NOT HERE, DELIBERATELY.**  No video timing: muir has none
// either --- "the vertical flag is kept on a frame clock rather than a
// raster, FRAME_NS, which is the netlist board's own period" --- and the
// sync program in the RAM is stored and read back, never run.  The frame
// is 15,456,000 ns, 966 lines of 16.000 us measured on the netlist board,
// which is 3,091,200 ticks of this clock exactly, counted from power-on as
// muir counts its frames.  And no frame buffer: the bitmap lives in PS
// DDR3, in the 8 MB `cadr_ddr_map.sv` reserves for the display, so that
// whatever draws the screen later --- a display output block, an RFB
// server on the processing system --- reads it from there.  A cycle to
// the window is answered by MAIN MEMORY'S BRIDGE at the display's base:
// this module decodes the window and says so on `fb_sel`, and
// `cadr_memory_path.sv` selects the bridge on it, exactly as it does for
// main memory.  One bridge and one memory port rather than a second
// master, because the Xbus has one master a cycle and the bridge is idle
// whenever this window is asked --- the disk's channel reaches main
// memory alone and never the window.  What that costs against muir is
// what main memory already costs: muir's TV answers a buffer word in no
// time of its own and the board's DDR answers when it answers, so the
// composed machine waits on the frame buffer as it waits on memory.  In
// the check the modelled DDR answers at once and the timing agrees with
// muir tick for tick.
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
// **PRIORITY AT ONE EDGE: `-XBUS INIT`, then the write, then the preset.**
// A write landing on the tick a frame begins keeps the written bit ---
// muir's `vert_flag` asks for a frame *strictly* since `written_at` ---
// and the trace reaches that tick at frame 25 and either side of it at
// frames 6 and 15, so the order is checked and not merely argued.  Init
// over everything, because the 74LS74's clear is a pin and not a clock.
//
// THE HELD MATCH.  `ctl`, `fb` and `which` are taken once from `phys` ---
// the far end of the map, constant for the whole microcycle --- and held
// a tick, as `cadr_memory_path.sv` holds its decode and the disk holds
// `mine`.  Any future Xbus slave must hold its address match and not
// compute it: the disk's first draft computed it and missed by 6 ns.
// They are the two registers of this module `rtl/plumbing/xilinx7/cadr_machine.xdc`
// leaves in its relaxed set; everything else here is timed at the tick.

`default_nettype none

module cadr_tv (
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

  // simpletv::CONTROL, 0o17377760, in eights; simpletv::BUFFER,
  // 0o17000000, in 32,768s.  The same constants `cadr_xbus_decode.sv`
  // makes `device` from, held here because a board decodes its own
  // address and the decode's `device` is one signal for every slave.
  localparam logic [18:0] CONTROL_PAGE = 19'd507902;
  localparam logic [6:0]  BUFFER_SLOT  = 7'd120;

  // simpletv::FRAME_NS, 15,456,000 ns, in ticks.
  //
  // **SO THE FRAME IS 30.912 REAL MILLISECONDS AND THE VERTICAL INTERRUPT
  // ARRIVES AT 32.35 Hz, WHERE THE DISPLAY BOARD SCANNED AT 64.70.**  These
  // are the machine's nanoseconds divided by MIT's five-nanosecond grid, and
  // the board clocks a tick at 10 ns rather than 5 --- `cadr_arty.sv`, whose
  // header is the argument.  It matters more here than anywhere else in the
  // machine, because **MIT's microcode uses this interrupt as its
  // roughly-sixty-cycle clock**: mouse tracking and the scheduler's sequence
  // break both run off it, so the machine's idea of a second is 50% of one.
  // Mete decided on 2026-09-11 that the machine keeps agreeing with muir for
  // now --- the checks are the backbone and `tv.golden` compares tick counts
  // --- and this is the record of what that costs rather than a fix.
  //
  // **UNDOING IT IS STILL ONE CONSTANT.**  A real frame is exactly 1,545,600
  // ticks of 10 ns, a whole number, so restoring real time here is that
  // number in place of this one and nothing else ---
  // at the price of this module no longer agreeing with muir.  The RFB server
  // on the processing system does the opposite and paces off the REAL frame,
  // because it compares against `CLOCK_MONOTONIC`: see `SCREEN_FRAME_REAL_NS`
  // in `boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src/screen_geom.h`.
  localparam logic [21:0] FRAME_T = 22'd3_091_200;

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
  // and so decides what register 1 reads back.  Bits 6 to 0 are the
  // vertical spacing, which the 74LS273 at NTVINC 0A07 holds for a sync
  // generator this board does not have --- nothing reads them back, in muir
  // or here, so they have no register and lint agrees.
  logic        sync_on;
  logic [7:0]  sync_ram [4096];
  logic [7:0]  sync_q;    // the RAM's word at the pointer, a tick behind it

  // The frame counter, which is `-TVMA CLR` here: it wraps once a frame and
  // presets the flag as it does.  Counted from reset, as muir counts from
  // power-on; both are on the same 5 ns grid, so they never drift.
  logic [21:0] frame_t;
  logic        frame_start;
  assign frame_start = (frame_t == FRAME_T - 22'd1);

  // ONCE PER BUS CYCLE, the way `cadr_xbus_ddr.sv` latches `done`: -XBUS.RQ
  // stands for tens of ticks and the word is taken at the first of them.
  logic taken, store_now;
  assign store_now = asked && dev_write && !taken;

  // What a read gives: the mode register with the flag in bit 4 and zeros
  // above; the sync RAM's word while the RAM is the one selected, "31-8
  // garbage" read as zero; and nothing from the write-only and the empty
  // registers.
  logic [31:0] word;
  always_comb begin
    unique case (which)
      3'd0:    word = {27'd0, flag, mode};
      3'd1:    word = sync_on ? {24'd0, sync_q} : 32'd0;
      default: word = 32'd0;
    endcase
  end
  assign rdata = drives ? word : 32'd0;

  assign intr = mode[3] && flag;

  // The sync program RAM: a store into register 1 writes the byte at the
  // pointer, and the word at the pointer is read every tick into `sync_q`.
  // A process of its own with a plain read, because Vivado refuses a RAM
  // whose read has a mux in it and infers a BRAM36 for this.
  always_ff @(posedge clk) begin
    if (store_now && which == 3'd1) sync_ram[pointer] <= wdata[7:0];
    sync_q <= sync_ram[pointer];
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
      frame_t <= 22'd0;
      taken   <= 1'b0;
    end else begin
      ctl   <= ctl_c;
      fb    <= fb_c;
      which <= which_c;

      frame_t <= frame_start ? 22'd0 : frame_t + 22'd1;

      // The flag: init over the write over the preset.  See the top.
      if (xbus_init)                       flag <= 1'b0;
      else if (store_now && which == 3'd0) flag <= wdata[4];
      else if (frame_start)                flag <= 1'b1;

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
    end
  end

  // The word's bits above the widest register here go nowhere, and the
  // reference says so: a write of 0xFFFFFFE5 to the mode register reads
  // back as 0o5.
  logic unused;
  assign unused = &{1'b0, wdata[31:12]};

endmodule

`default_nettype wire
