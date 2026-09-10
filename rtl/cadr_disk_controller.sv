// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk controller: the drive and the register face.  An Xbus slave at
// 0o17377774.
//
// A port of `disk_controller::Controller` as far as the channel and no
// further: the four registers a program reads and writes, the eight unit
// slots and what a drive on one of them answers, the spindle's block
// counter, the seek and its attention, and the hang timer.  What is NOT here
// is everything that touches a block: the block store, the command list, the
// header compare, the two checkwords and the move into main memory.  muir's
// controller is also a bus master and this is not one.
//
// THE NAME.  `cadr_xbus_ddr.sv` is main memory *in front of* DDR and is named
// for that; this is not the same shape.  The controller is a device on the
// Xbus that will shortly also be a MASTER on it --- the channel --- so naming
// it for the slave role would be wrong the day the channel lands.  It takes
// muir's own name instead, `src/disk_controller.rs`, which also leaves
// `disk_unit` free for the drive when `S_AXI_HP2` brings one.
//
// **THE DRIVE IS A SEAM AND NOT A CONSTANT.**  `drive_present`,
// `drive_read_only` and `drive_timed` come in from outside, eight units'
// worth of the first two, because a drive is a thing on a cable and not a
// property of this board.  `tb/cadr_disk_tb.cpp` attaches one where the
// reference trace's `ATTACH` row says; `rtl/cadr_arty.sv` ties all three off
// today and says what will drive them.  **A design with one drive always
// present is wrong**, and that was found by a Python model against
// `build/disk.golden` rather than by anything in fabric: a single `present`
// flag reads `1` where muir reads `0x2321` the moment the program stores
// another unit number, and MIT's boot PROM stores the disk address register
// 5,650 times.
//
// WHAT THE STATUS WORD IS, BIT BY BIT.  Every line is
// `disk_controller::Controller::status()` at muir `ee8f90e`
// (`src/disk_controller.rs:329`), and the right-hand column is what this
// slice can make of it.  `-` is a bit no state here can raise; CHANNEL means
// the bit is a transfer's and arrives with the channel:
//
//   <31:24> block counter          LIVE: the spindle's own count, which the
//                                      74LS569s at DCTRID 0B07/0B08 clock off
//                                      BLOCK.CLK^.  Zero with nothing on the
//                                      selected unit's cable, because the
//                                      pulses come off the drive
//   <23>    internal parity        - : not in the behavioural model at all
//   <22>    read compare diff      CHANNEL
//   <21>    CCW cycle              CHANNEL, and set and cleared inside one
//                                      store, so no read can ever see it
//   <20>    NXM error              CHANNEL
//   <19>    memory parity          - : not in the behavioural model
//   <18>    header compare         CHANNEL
//   <17>    header ECC             CHANNEL
//   <16>    ECC hard               CHANNEL
//   <15>    ECC soft               CHANNEL, and `Ecc::trap` with it ---
//                                      docs/disk-controller.md
//   <14>    overrun                CHANNEL
//   <13>    transfer aborted       LIVE, as `lossage()`: the disk lossage
//                                      under CMD2, and the transfer lossage's
//                                      one term this slice has, the timeout
//   <12>    start block            - : this controller has no detector
//   <11>    timeout error          LIVE: the 74LS124 at DCTMOT 0B04 through
//                                      the 74393 at 0C03, 2.56 s
//   <10>    seek error             LIVE: the selected drive's, raised by a
//                                      seek off the pack and taken away only
//                                      by a recalibrate
//   <9>     not on line            LIVE: nothing on the selected unit's cable
//   <8>     not on cylinder        LIVE: the same
//   <7>     read only              LIVE: the selected drive's switch, which
//                                      is stimulus --- nothing models a
//                                      switch, here or in muir
//   <6>     fault                  LIVE: the selected drive's, raised by a
//                                      write to a read-only pack and taken
//                                      away by a fault clear
//   <5>     no unit selected       LIVE: nothing on the selected unit's cable
//   <4>     multiple units         - : not in the behavioural model
//   <3>     interrupt request      LIVE, as `interrupt()`: not-active with
//                                      the done enable, or an attention with
//                                      the attention enable
//   <2>     attention              LIVE: the selected drive's
//   <1>     any attention          LIVE: any drive's, over all eight slots
//   <0>     not active             LIVE: the busy counter at zero
//
// With nothing on the cable and the command register at zero --- which is
// where MIT's boot PROM leaves it, never having written one --- that is bits
// 13, 9, 8, 5 and 0, `0o21441` = `0x2321`, and `tests/disk.rs`'s
// `a_controller_with_no_drive_is_ready_and_off_line` asserts the same word
// off muir and off the netlist board.
//
// **THE TIMEOUT IS THE BOARD'S STRUCTURE AND NOT muir'S, AND THEY AGREE
// EVERYWHERE.**  muir sets `timeout` at the hang and shows `<11>` only once
// `done_at` has passed --- `self.timeout && self.not_active()`.  The board
// starts the 74LS124's divider at the hang and the flop is set when it runs
// out; `-RESET ERR` clears the flop unconditionally and the running timer
// sets it again at expiry, where muir's `reset_errors` declines to clear it
// while the controller is still active.  No read can tell them apart: both
// `<11>` and the transfer lossage are gated by not-active in muir, and in the
// board the flop is not set until not-active is true anyway.  **This is a
// candidate equivalent mutant and is recorded in `mutations/list.txt` as
// such**, so that nobody files it as a hole.
//
// **`-XBUS.INTR` IS COMPUTED AND NOT BROUGHT OUT**, deliberately.  `<3>` is
// the level the board asserts on the backplane, and the machine takes it as
// `sintr`, which is still a stimulus port of `cadr_machine` fed from the
// trace.  Wiring one to the other wants the band: `sintr` is the disk's done
// interrupt on 17,185 of the band's 2,200,000 rows and on none of the boot
// PROM's, because the enable lives in a command register that program never
// writes.  A port that exists on one side of a boundary and not the other is
// what `dev_wdata` was, so this is written down rather than left.
//
// THE ANSWER IS COMBINATIONAL, AND THAT IS A MEASUREMENT.  muir's controller
// takes 0 ns of its own --- `IDEAL_DEVICE_NS = 0` --- so a read acknowledges
// 140 ns after the grant (80 ns of bus setup, then the 60 ns tap of the TD100
// at REQLM 0C09) and a write at 80.  `cadr_busint_xbus.sv` supplies both of
// those delays itself, so a slave that answers in the same tick `-XBUS.RQ`
// reaches it lands `-MEMACK` exactly where muir puts it, with no tolerance
// anywhere.  Nothing here may add a register between `dev_rq` and `dev_ack`
// --- the ADDRESS MATCH is held in one, and the note at `mine_c` below is
// about why that is a different thing and why the fitter insists on it.
//
// TWO SLAVES CANNOT ANSWER ONE CYCLE, and the decode is what makes that true
// rather than a convention.  `sel` is `cadr_xbus_decode`'s `device`, which
// requires the address to be in Xbus I/O space, and `memory` requires it not
// to be --- so main memory and this cannot both be selected, and that decode
// is checked against `busint::decode` over all 4,194,304 addresses.  Within
// Xbus I/O space this module then decodes its own four words out of `phys`,
// as a board on the backplane does: `device` is also true for the display's
// frame buffer and its eight control registers, which are disjoint from these
// four by construction.

`default_nettype none

module cadr_disk_controller (
    input  var logic        clk,        // 200 MHz, one tick = 5 ns
    input  var logic        rst,

    // `-XBUS INIT` on the backplane, which is not a bus cycle on these four
    // registers: it clears the command register and stops the channel, and
    // the disk address counters (the 74LS193s at DCDA 0A17-0A21), the command
    // list pointer (DCCLP) and the CCW latches (DCCCW) have no pin on it and
    // stand.  `cadr_machine.sv` ties it to the power-on reset, which is the
    // one thing that does assert it there; `rst` above is the harder reset
    // and clears the counters too.
    input  var logic        xbus_init,

    // --- the drive seam, eight units of it -------------------------------
    //
    // "Many bits in these registers refer to the 'selected unit', which is
    // that disk unit whose number is currently in bits <30:28> of the
    // disk-address register."  So presence is per unit and so is the
    // read-only switch; `<1>` any-attention is over all eight and everything
    // else is the selected one's.
    input  var logic [7:0]  drive_present,
    input  var logic [7:0]  drive_read_only,
    // Whether the drive's own time is charged, which is `Controller::timed`.
    // Off is how muir runs by default and what every count this project
    // quotes was measured with; on is the only way to reach a seek's length.
    // It is a property of the drive on the cable rather than of this board,
    // so it comes in with the drive.
    input  var logic        drive_timed,

    // The Xbus slave side, exactly as `cadr_xbus_ddr.sv` takes it.
    input  var logic        sel,        // the decode says this cycle is a device's
    input  var logic        dev_rq,     // -XBUS.RQ, as a positive level
    input  var logic        dev_write,
    input  var logic [21:0] phys,       // -XADDR21..0, a word address
    input  var logic [31:0] wdata,      // MEM<31:0> from the cpu
    output var logic        dev_ack,    // -XBUS.ACK
    output var logic [31:0] rdata,      // MEM<31:0> to the cpu
    output var logic        drives      // this slave is driving MEM<31:0>
);

  // `disk_controller::REGS`, 0o17377774, four words.  MIT: "These are
  // normally at physical addresses 17377774-17377777, which is just below the
  // Unibus.  The address can be changed by changing jumpers."  The jumpers
  // are not modelled; muir's constant is not either.
  localparam logic [19:0] REGS_PAGE = 20'd1015807;   // 0o17377774 >> 2

  // --- the drive's geometry and the spindle's numbers ---------------------
  //
  // `disk_unit::Geometry::T300`, which is what a System 100 band runs on, and
  // the timing constants beside it.  Every one is muir's, by name:
  // `REVOLUTION_NS` and `SECTOR_NS` (1,164 bytes x 8 bits x `BIT_NS`),
  // `INDEX_PULSE_NS`, `SECTOR_PULSE_NS`, `SEEK_SETTLE_NS`,
  // `SEEK_NS_PER_CYLINDER` and `disk_controller::TIMEOUT_NS`.
  localparam int unsigned CYLINDERS = 815;
  localparam int unsigned HEADS     = 19;
  localparam int unsigned BPT       = 17;   // blocks per track

  localparam logic [23:0] REVOLUTION_NS   = 24'd16_666_667;
  localparam logic [19:0] SECTOR_NS       = 20'd968_448;
  localparam logic [19:0] INDEX_PULSE_NS  = 20'd4_000;
  localparam logic [19:0] SECTOR_PULSE_NS = 20'd1_240;

  // The 74LS124 at DCTMOT 0B04 section 1 at 20 ms, divided by 128 by the
  // 74393 at 0C03: 2.56 s, which is 512,000,000 ticks of this clock.  **It
  // must not be shortened**; a check that cannot tell this constant from a
  // wrong one is `RD_FINISH_T` again.
  localparam logic [31:0] TIMEOUT_NS = 32'd2_560_000_000;

  localparam logic [27:0] SEEK_SETTLE_NS       = 28'd5_939_729;
  localparam logic [16:0] SEEK_NS_PER_CYLINDER = 17'd60_271;

  // **THE ADDRESS MATCH IS TAKEN ONCE AND HELD, AND THE REASON IS TIMING
  // RATHER THAN FUNCTION.**  This is `cadr_memory_path.sv`'s note about its
  // own decode, one slave along, and it is here because leaving it
  // combinational cost the board flow its timing closure: `phys` is the far
  // end of the map, a ripple through two asynchronous RAMs, and `dev_ack`
  // must be a gate --- so a combinational match carries that ripple into
  // `-MEMACK` and `-LOADMD` and thence onto `mfinish_t`'s and `md`'s clock
  // enables, which are counters and edge detectors that genuinely run at tick
  // rate and are rightly outside the XDC's exception.  Measured on the DDR=0
  // board flow at the commit this module landed at, three ways:
  //
  //     the machine without this module      +0.105 ns MET, 0 of 14,041
  //     with the match combinational         -6.195 ns,     1,065 of 14,312
  //     with the match held, as below        +0.067 ns MET, 0 of 14,297
  //
  // The failing path was `processor/memstart_reg/C ->
  // processor/mfinish_t_reg[0]/CE`, thirteen logic levels through `l1_map`
  // --- the same -6.5 ns family, from the same cause, that registering the
  // decode cut off at its source.  The 38 ps between the first and third
  // figures is inside the quarter-nanosecond of placement noise this project
  // has measured on a bit-identical netlist; the 6.3 ns is not.
  //
  // NOTHING WAITS FOR IT THAT WAS NOT ALREADY WAITING A MICROCYCLE.  `phys`
  // is `VMA` or `MD` through the map, all microcycle registers, so it is
  // constant for the whole microcycle; `sel` is already held one tick by the
  // memory path for this same reason; and `-XBUS.RQ` does not go out until
  // SETUP_T --- sixteen ticks --- after the grant, so a match two ticks
  // behind the address is settled long before anything reads it.
  //
  // It is held HERE and not in `cadr_xbus_decode.sv`, which already computes
  // `disk_regs` and would be the tidier place, because the decode's `device`
  // is deliberately one signal for every Xbus slave: a board on the backplane
  // decodes its own address.  Moving it there means giving the decode an
  // output per slave, which is a change to a module checked exhaustively
  // against `busint::decode` and is not this slice's to make.
  logic mine_c, mine, asked;
  logic [1:0] which_c, which;
  assign mine_c  = sel && (phys[21:2] == REGS_PAGE);
  // Which of the four.  `register(phys)` in muir is the same subtraction, and
  // `read`/`write` mask it to two bits.
  assign which_c = phys[1:0];

  assign asked = mine && dev_rq;

  // 0 ns of its own, and it must stay a gate: see the note at the top.
  assign dev_ack = asked;

  // --- the three registers a program can write ---------------------------
  //
  // `cmd` is write-only --- "Note that the command register cannot be read
  // back".  `clp` is write-only here too: register 1 reads back the LAST
  // MEMORY ADDRESS and not the pointer, MIT putting two different things at
  // one address, and nothing in this slice makes a memory reference.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] clp;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] cmd;
  logic [31:0] da;

  // --- the eight unit slots ----------------------------------------------
  //
  // The heads' position is the drive's and so are its two flags.  A seek off
  // the pack raises `seek_error` and only a recalibrate takes it away ---
  // `-RESET ERR` does not reach the drive --- and a write to a read-only pack
  // raises `fault`, which a fault clear takes away.
  logic [11:0] u_cyl  [8];
  logic [7:0]  u_head [8];
  logic [7:0]  u_blk  [8];
  logic [7:0]  u_fault;
  logic [7:0]  u_seek_err;
  // The attention: `Unit::attention_at` is an instant and `attention(now)` is
  // `now >= attention_at`, with `u64::MAX` meaning none.  In fabric that is a
  // countdown and a flag saying it was armed at all --- a seek raises the
  // attention when the heads arrive, and an at-ease takes it away.
  logic [7:0]  u_att_armed;
  logic [27:0] u_att_ns [8];

  logic [2:0] sel_unit;
  logic       present, read_only;
  assign sel_unit  = da[30:28];
  assign present   = drive_present[sel_unit];
  assign read_only = drive_read_only[sel_unit];

  logic [7:0] att_ready;
  always_comb begin
    for (int u = 0; u < 8; u++)
      att_ready[u] = drive_present[u] && u_att_armed[u] && (u_att_ns[u] == 28'd0);
  end

  logic attention, any_attention;
  assign attention     = att_ready[sel_unit];
  assign any_attention = |att_ready;

  // --- the spindle --------------------------------------------------------
  //
  // `spin` is `now mod REVOLUTION_NS`: a counter incremented by five a tick
  // and wrapped by SUBTRACTING the revolution, which is exact even though
  // neither constant is a multiple of five.  `region` is `spin / SECTOR_NS`
  // and `into` is the remainder, both kept as counters so that nothing here
  // divides: `into` adds five a tick and gives `SECTOR_NS` back when it
  // passes the threshold, and `region` steps with it.  Run against muir's own
  // closed form for three revolutions --- 10,000,010 ticks --- with 0
  // disagreements before a line of this was written.
  //
  // `disk_unit::turn` caps the region at the number of blocks on a track, and
  // so does this: eighteen sectors would be 17,432,064 ns and the revolution
  // is 16,666,667, so the last region is the track's 203,051 ns leftover and
  // the cap never binds.  It is written anyway because the drawing's counter
  // has one.
  logic [23:0] spin, spin_next;
  logic [19:0] into;
  logic [4:0]  region;
  logic        wrapping, stepping;
  logic [19:0] pulse_ns;

  assign spin_next = spin + 24'd5;
  assign wrapping  = spin_next >= REVOLUTION_NS;
  assign stepping  = (into + 20'd5 >= SECTOR_NS) && (region < 5'(BPT));
  assign pulse_ns  = (region == 5'd0) ? INDEX_PULSE_NS : SECTOR_PULSE_NS;

  // "The count steps to `k` as region `k`'s pulse ends and holds the region
  // before it through the pulse", and the region before region 0 is the
  // track's seventeenth --- `DCHECK-BLOCK-COUNTER` wants every value 0 to 17
  // and no other, and the 17 is exactly this.
  logic [7:0] block_counter;
  always_comb begin
    if (!present) block_counter = 8'd0;
    else if (into >= pulse_ns) block_counter = {3'd0, region};
    else if (region == 5'd0) block_counter = 8'(BPT);
    else block_counter = {3'd0, region - 5'd1};
  end

  // --- the busy counter and the hang timer --------------------------------
  //
  // `Controller::done_at` is an instant and `not_active()` is `now >=
  // done_at`; here it is a DOWN-COUNTER IN NANOSECONDS, decremented by five a
  // tick, which reaches zero on exactly the tick a counter loaded with
  // `ceil(span / 5)` would --- and needs no divider for a span that is not a
  // multiple of five.  `seek_ns(2)` is 6,060,271 and is not; nor is a
  // transfer's access time when the channel brings one.
  logic [31:0] busy_ns;
  logic        not_active;
  assign not_active = (busy_ns == 32'd0);

  // `hanging` says the counter now running is the 2.56 s timer and not a
  // drive's own time, so that only its expiry sets the timeout flop.  See the
  // note at the top about why the flop is set at expiry rather than at the
  // hang.
  logic hanging, timeout;

  // --- how long a seek takes, worked out before it is asked for -----------
  //
  // `seek_ns(n)` is a multiply, and the START that uses it is a bus write
  // whose answer must be a gate.  So it is computed from the disk address
  // register and the heads' position every tick and REGISTERED, and the START
  // takes last tick's value --- which is the position and the address as they
  // stood before the store, which is what `frm` is in the model.  Nothing
  // waits: the disk address is written by an earlier bus cycle and `-XBUS.RQ`
  // is sixteen ticks after the grant.
  //
  // A recalibrate seeks home, so its distance is the cylinder the heads are
  // on rather than the difference; codes 0o05 and 0o15 are the at-ease sector
  // and share their low three bits.
  logic        is_recal;
  logic [11:0] cyl_now, cyl_to, cyl_n;
  logic [27:0] seek_span, seek_ns_c, seek_ns_r;
  assign is_recal = (cmd[2:0] == 3'b101) && cmd[9];
  assign cyl_now  = u_cyl[sel_unit];
  assign cyl_to   = da[27:16];
  assign cyl_n    = is_recal ? cyl_now
                             : ((cyl_now > cyl_to) ? cyl_now - cyl_to : cyl_to - cyl_now);
  // Both operands widened before the multiply, or the product is taken at the
  // width of the wider one and 4,095 cylinders of it fall off the top.
  assign seek_span = 28'(cyl_n) * 28'(SEEK_NS_PER_CYLINDER);
  assign seek_ns_c = (cyl_n == 12'd0) ? 28'd0 : SEEK_SETTLE_NS + seek_span;

  // --- the status word ---------------------------------------------------
  //
  // `-LOSSAGE`, the 74LS21 at DCBUSY 0B15 over four terms.  The DISK lossage
  // is `NO SELECT`, `MULTIPLE SELECT`, `SEL UNIT FAULT`, `SEL UNIT SEEK
  // ERROR` and `-SEL UNIT ON LINE` through the 74LS32 at 0C16, which lets
  // them through only with CMD2 low.  The TRANSFER lossage is the timeout,
  // NXM, overrun and the header and ECC errors, and the timeout is the one
  // term of it this slice has --- the rest arrive with the channel.
  //
  // `timeout && not_active` is muir's own expression and is kept verbatim.
  // With the flop set at the timer's expiry rather than at the hang the gate
  // is redundant --- the timer reaching zero IS not-active --- except in one
  // corner: a second hang started with no store into the command register
  // between, where muir's flop is still up from the last one and the board's
  // is not.  No row of `build/disk.golden` reaches it, every hang there being
  // preceded by a command write, and the gate makes the two structures agree
  // there too rather than leaving a parting nothing exercises.
  logic transfer_lossage, disk_lossage, lossage;
  assign transfer_lossage = timeout && not_active;
  assign disk_lossage     = cmd[2] ? 1'b0
                          : (!present ? 1'b1
                                      : (u_fault[sel_unit] || u_seek_err[sel_unit]));
  assign lossage = transfer_lossage || disk_lossage;

  // "Done Interrupt Enable.  Enables not-active (bit 0 of the status
  // register) to cause an interrupt", and "Attention Interrupt Enable" the
  // any-attention beside it.
  logic interrupt;
  assign interrupt = not_active && (cmd[11] || (cmd[10] && any_attention));

  // The word itself.  Written by name rather than as a 32-bit concatenation,
  // because the table at the top of this file is the specification and a
  // concatenation of eighteen zeros and a dozen names is not readable against
  // it.  Everything not named here is zero, and the table says why for each.
  logic [31:0] status;
  assign status = {block_counter, 24'd0}                       // <31:24>
                | (transfer_lossage ? 32'h0000_0800 : 32'd0)   // <11>
                | (lossage    ? 32'h0000_2000 : 32'd0)         // <13>
                | (interrupt  ? 32'h0000_0008 : 32'd0)         // <3>
                | (not_active ? 32'h0000_0001 : 32'd0)         // <0>
                | (present ? ((u_seek_err[sel_unit] ? 32'h0000_0400 : 32'd0)   // <10>
                            | (read_only           ? 32'h0000_0080 : 32'd0)   // <7>
                            | (u_fault[sel_unit]   ? 32'h0000_0040 : 32'd0)   // <6>
                            | (attention           ? 32'h0000_0004 : 32'd0))  // <2>
                          : 32'h0000_0320)                     // <9> <8> <5>
                | (any_attention ? 32'h0000_0002 : 32'd0);     // <1>

  // --- what a read returns -----------------------------------------------

  logic [31:0] word;
  always_comb begin
    unique case (which)
      // 0: STATUS.
      2'd0: word = status;
      // 1: MEMORY ADDRESS.  "Address of the last memory reference made by the
      // disk control."  <23:22> is the controller type, 0 for a Trident, so
      // the register is the address alone --- and nothing here has made a
      // memory reference, the channel being the next slice.
      2'd1: word = 32'd0;
      // 2: DISK ADDRESS, read back as it was written.
      2'd2: word = da;
      // 3: ERROR CORRECTION.  "<31:16> Error pattern bits.  <15:0> Error bit
      // position."  Both are the channel's: the pattern comes out of the ECC
      // register over a block's data and there is no block here.
      default: word = 32'd0;
    endcase
  end

  // **A SLAVE DRIVES MEM<31:0> ONLY WHILE IT IS ANSWERING A READ.**  That is
  // the rule `cadr_xbus_ddr.sv` learned the hard way: its `rdata` register
  // held the last word it returned and every unanswered cycle strobed MD with
  // it.  Here the answer is combinational, so there is no register to hold
  // anything, and the driver is named rather than implied --- `drives` is
  // what `cadr_machine.sv` mixes this onto the seam with, and what leaves the
  // seam free on a write, where MEM<31:0> belongs to the master.
  assign drives = asked && !dev_write;
  assign rdata  = drives ? word : 32'd0;

  // --- what a write does -------------------------------------------------
  //
  // ONCE PER BUS CYCLE.  `-XBUS.RQ` stands from the setup boundary until the
  // cpu lifts -MEMRQ, tens of ticks, and `Controller::write` runs once.  The
  // three register stores are idempotent and would not care; START is a pulse
  // and does.  So the cycle is latched the way `cadr_xbus_ddr.sv` latches
  // `done`, and cleared when the request goes.
  logic taken;

  // "Writing anything at this address initiates the operation specified in
  // the command, disk address, and command list pointer registers."  It is
  // the `which == 2'd3` arm of the write below, and the four bits it acts on
  // are these.
  //
  // **WHAT A DATA-MOVING COMMAND DOES HERE, AND WHAT IT DOES NOT.**  Codes
  // 0o00 read, 0o10 read-compare, 0o11 write, 0o02 Read All, 0o13 Write All
  // and the two undocumented 0o01 and 0o03 all reach `Controller::transfer`
  // or its access time.  The SEEK a transfer begins with is the drive's and
  // is here --- `transfer()`'s first act is `u.seek(c, h, b)`, and a seek off
  // the pack raises `<10>` before any block is touched, which
  // `build/disk.pass` compares.  The WALK is the channel's and is not: the
  // command list, the header compare, the two checkwords, the words
  // themselves, `<22:14>`, the last memory address, the ECC register and the
  // heads' position after the walk.
  //
  // NOR IS THE TIME ONE TAKES, and that is not an omission either:
  // `access_ns(frm, to, block, blocks)` is a function of how many blocks the
  // command list names, which is the walk.  So a data-moving START leaves
  // `busy_ns` alone, the check exempts what a transfer moves, and both are
  // counted on its output.  A write to a read-only pack is the exception and
  // is here in full, because muir raises the fault and returns BEFORE any
  // data moves.
  logic [3:0] code;
  logic       data_moving, ro_fault;
  assign code        = cmd[3:0];
  assign data_moving = (code == 4'o00) || (code == 4'o01) || (code == 4'o02)
                    || (code == 4'o03) || (code == 4'o10) || (code == 4'o11)
                    || (code == 4'o13);
  assign ro_fault    = ((code == 4'o11) || (code == 4'o13)) && read_only;

  // A store into START with nothing on the selected unit's cable does nothing
  // at all unless the command's bit 2 is up: `Controller::start` returns
  // before it looks at the code.  Sectors 4 to 7 --- seek, at ease, offset
  // clear, and the reserved codes --- are the ones that do not need a drive.
  logic can_start;
  assign can_start = present || cmd[2];

  // Where the disk address register says the heads should go.
  logic [11:0] da_cyl;
  logic [7:0]  da_head, da_blk;
  assign da_cyl  = da[27:16];
  assign da_head = da[15:8];
  assign da_blk  = da[7:0];

  // A seek the drive refuses: "an attempt is made to seek to a nonexistent
  // cylinder".  A seek to where the heads already are is not one, and muir
  // answers it before it looks at the geometry.
  logic seek_here, seek_off_pack;
  assign seek_here     = (da_cyl == u_cyl[sel_unit]) && (da_head == u_head[sel_unit])
                      && (da_blk == u_blk[sel_unit]);
  assign seek_off_pack = (da_cyl >= 12'(CYLINDERS)) || (da_head >= 8'(HEADS))
                      || (da_blk >= 8'(BPT));

  // The held decode.  One process, because it is this slave's own state.
  always_ff @(posedge clk) begin
    if (rst) begin
      mine  <= 1'b0;
      which <= 2'd0;
    end else begin
      mine  <= mine_c;
      which <= which_c;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      // Power-on.  `-XINIT` clears the command register --- the 74LS175 at
      // DCCMD 0C21 and the 74LS273 at 0C10, pin 1 of each --- and stops the
      // channel; the disk address counters, the command list pointer and the
      // CCW latches have no pin on it, so on the board those come up
      // undefined and zero is this fabric's convention for them, as
      // `LVMO_AT_POWER_ON` is elsewhere.
      cmd         <= 32'd0;
      clp         <= 32'd0;
      da          <= 32'd0;
      taken       <= 1'b0;
      busy_ns     <= 32'd0;
      hanging     <= 1'b0;
      timeout     <= 1'b0;
      spin        <= 24'd0;
      into        <= 20'd0;
      region      <= 5'd0;
      seek_ns_r   <= 28'd0;
      u_fault     <= 8'd0;
      u_seek_err  <= 8'd0;
      u_att_armed <= 8'd0;
      for (int u = 0; u < 8; u++) begin
        u_cyl[u]    <= 12'd0;
        u_head[u]   <= 8'd0;
        u_blk[u]    <= 8'd0;
        u_att_ns[u] <= 28'd0;
      end
    end else begin
      // --- the spindle, which turns whatever the bus is doing
      if (wrapping) begin
        spin   <= spin_next - REVOLUTION_NS;
        into   <= 20'(spin_next - REVOLUTION_NS);
        region <= 5'd0;
      end else begin
        spin <= spin_next;
        if (stepping) begin
          into   <= into + 20'd5 - SECTOR_NS;
          region <= region + 5'd1;
        end else begin
          into <= into + 20'd5;
        end
      end

      // --- the busy counter, and the timeout flop at its expiry
      if (busy_ns > 32'd5) begin
        busy_ns <= busy_ns - 32'd5;
      end else if (busy_ns != 32'd0) begin
        busy_ns <= 32'd0;
        if (hanging) begin
          timeout <= 1'b1;
          hanging <= 1'b0;
        end
      end

      // --- the attentions, one countdown a unit
      for (int u = 0; u < 8; u++) begin
        if (u_att_armed[u] && u_att_ns[u] != 28'd0)
          u_att_ns[u] <= (u_att_ns[u] > 28'd5) ? u_att_ns[u] - 28'd5 : 28'd0;
      end

      // --- how long the next seek would take, from where the heads are now
      seek_ns_r <= seek_ns_c;

      // --- the backplane's init, which is not a bus cycle
      if (xbus_init) begin
        cmd     <= 32'd0;
        busy_ns <= 32'd0;
        hanging <= 1'b0;
        timeout <= 1'b0;
      end else if (!asked) begin
        taken <= 1'b0;
      end else if (dev_write && !taken) begin
        taken <= 1'b1;
        unique case (which)
          // "Writing the command register does NOT initiate a transfer,
          // unlike most disk controllers.  Use register 3 (START) to initiate
          // a transfer, after setting up the other registers."
          //
          // `-RESET ERR` is `-LOAD CMD` OR `-XINIT`, the 74LS08 at DCCMD
          // 0D14: EVERY store into register 0 clears the eight transfer error
          // flops --- the 74LS273s at DCSTS 0C12 and 0D24, the 74LS279 at
          // 0B12 and `STOPPED BY ERROR` at DCBUSY 0B06.  BUSY is not among
          // them, so a hung sequencer stays hung and its timer keeps counting.
          // Seven of the eight are the channel's and arrive with it; the
          // timeout is the one this slice has.
          2'd0: begin
            cmd     <= wdata;
            timeout <= 1'b0;
            // "Reset.  Stops whatever the disk control is doing", and it
            // takes effect as soon as it is stored, with no START: the
            // 74LS00 at DCCMD 0A28 adds `RESET` to `-RESET ERR`.
            if (wdata[3:0] == 4'o16) begin
              busy_ns <= 32'd0;
              hanging <= 1'b0;
            end
          end
          2'd1: clp <= wdata;
          // "Storing into the Disk Address register momentarily deselects the
          // current unit so that the drive can update its read-only status
          // from the switch."  Nothing models the switch, here or in muir.
          2'd2: da <= wdata;
          // --- START, and the sequencer such as this slice has one --------
          default: begin
            if (can_start) begin
              unique case (1'b1)
                // A transfer: the seek it begins with, and the read-only
                // fault that stops a write before it.  See the note above.
                data_moving: begin
                  if (present) begin
                    if (ro_fault) begin
                      u_fault[sel_unit] <= 1'b1;
                    end else if (!seek_here) begin
                      if (seek_off_pack) begin
                        u_seek_err[sel_unit] <= 1'b1;
                      end else begin
                        u_cyl[sel_unit]  <= da_cyl;
                        u_head[sel_unit] <= da_head;
                        u_blk[sel_unit]  <= da_blk;
                      end
                    end
                  end
                end
                // Seek, and the seek of sector 4's undocumented twin.  The
                // heads' move is charged and the attention comes up when they
                // arrive --- both from the DISTANCE THE ADDRESS NAMES, which
                // muir charges whether or not the seek was refused.  With
                // nothing on the cable the sequencer waits for a drive that
                // never answers and MIT's board with the timeout jumper in
                // ends it 2.56 s on.
                (code == 4'o04) || (code == 4'o14): begin
                  if (present) begin
                    if (!seek_here) begin
                      if (seek_off_pack) begin
                        u_seek_err[sel_unit] <= 1'b1;
                      end else begin
                        u_cyl[sel_unit]  <= da_cyl;
                        u_head[sel_unit] <= da_head;
                        u_blk[sel_unit]  <= da_blk;
                      end
                    end
                    busy_ns              <= drive_timed ? 32'(seek_ns_r) : 32'd0;
                    u_att_armed[sel_unit] <= 1'b1;
                    u_att_ns[sel_unit]    <= drive_timed ? seek_ns_r : 28'd0;
                  end else begin
                    busy_ns <= TIMEOUT_NS;
                    hanging <= 1'b1;
                  end
                end
                // At ease, and with it the recalibrate and the fault clear.
                // "At ease ... clears the attention"; the recalibrate takes
                // the heads home and clears the drive's own two flags, which
                // is the only thing that clears a seek error; the fault clear
                // takes the fault away on its own.  A recalibrate raises an
                // attention when the heads arrive and does NOT make the
                // controller busy --- muir charges nothing here, and MIT's
                // driver polls the attention rather than not-active.
                (code == 4'o05) || (code == 4'o15): begin
                  if (present) begin
                    u_att_armed[sel_unit] <= 1'b0;
                    if (cmd[9]) begin
                      u_cyl[sel_unit]      <= 12'd0;
                      u_head[sel_unit]     <= 8'd0;
                      u_blk[sel_unit]      <= 8'd0;
                      u_fault[sel_unit]    <= 1'b0;
                      u_seek_err[sel_unit] <= 1'b0;
                      u_att_armed[sel_unit] <= 1'b1;
                      u_att_ns[sel_unit]    <= drive_timed ? seek_ns_r : 28'd0;
                    end
                    if (cmd[8]) u_fault[sel_unit] <= 1'b0;
                  end
                end
                // Offset clear, which needs a drive to answer it and hangs
                // without one.
                code == 4'o06: begin
                  if (!present) begin
                    busy_ns <= TIMEOUT_NS;
                    hanging <= 1'b1;
                  end
                end
                // Reset, which took effect at the store into the command
                // register: this is the START that follows it, and MIT's
                // "takes effect as soon as it is stored" is why it does
                // nothing here.
                code == 4'o16: begin
                end
                // The three codes `newdsk.31` leaves the sequencer in: 0o07
                // and 0o17 are sector 7, which the microcode does not write,
                // and 0o12 is the Read All sector entered with the memory
                // channel turned round.  All three start and never finish.
                default: begin
                  busy_ns <= TIMEOUT_NS;
                  hanging <= 1'b1;
                end
              endcase
            end
          end
        endcase
      end
    end
  end

  logic unused;
  assign unused = &{1'b0, cmd[31:12], cmd[7:4]};

endmodule

`default_nettype wire
