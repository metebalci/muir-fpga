// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk controller: the drive, the register face and the memory channel.
// An Xbus slave at 0o17377774 and, when a transfer is running, an Xbus
// MASTER as well.
//
// A port of `disk_controller::Controller` as far as muir has one: the four
// registers a program reads and writes, the eight unit slots and what a
// drive on one of them answers, the spindle's block counter, the seek and
// its attention, the hang timer; the channel --- the block store, the
// command list's walk with its sixteen-bit wrap, the header compare and its
// mask, both checkwords through DCECC and the trap that locates a burst, and
// the move into main memory a word at a time; and the TRACK --- `0o02` Read
// All and `0o13` Write All, which go round the whole of one as bytes rather
// than as blocks.
//
// **THE TRACK IS THE ONLY THING ON THIS BOARD THAT IS A BIT STREAM.**
// Everything else moves words: the walk, the store, the checkwords a byte at
// a time.  Read All and Write All are the format itself --- "The format is
// determined by the program that uses the Write All operation to format the
// disk" --- so what crosses the channel is the 1,164 bytes a sector actually
// carries, gaps, syncs, pad and checkwords included, and what comes back is
// whatever a program chose to put there.  `disk_unit::sector_image_laid` is
// the serialiser and `disk_unit::parse_sector` the parser, and the two are
// inverses over a whole track: `tb/cadr_disk_tb.cpp` runs one into the other
// as well as comparing both against the reference trace, because a trace
// that reaches 3,072 bytes of 20,160 cannot hold either alone.
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
//   <22>    read compare diff      LIVE: a read-compare found a word in
//                                      memory that the block does not carry.
//                                      It does NOT stop the transfer
//   <21>    CCW cycle              LIVE: up while a command list word is
//                                      being fetched, so a fetch that reaches
//                                      no memory leaves it up.  A fetch is
//                                      one bus cycle and nothing in either
//                                      trace reads the register during one
//   <20>    NXM error              LIVE: a command list word, or a page, that
//                                      main memory does not answer for
//   <19>    memory parity          - : not in the behavioural model
//   <18>    header compare         LIVE: the block's header against the disk
//                                      address register, under the mask below
//   <17>    header ECC             LIVE: the header's own checkword, and a
//                                      transfer walking off the end of the
//                                      pack
//   <16>    ECC hard               LIVE: a data checkword that fails and a
//                                      burst `Ecc::trap` cannot locate
//   <15>    ECC soft               LIVE: one it can, and register 3 says where
//   <14>    overrun                LIVE, on command `0o03` alone: measured on
//                                      the netlist board and nowhere else
//   <13>    transfer aborted       LIVE, as `lossage()`: the disk lossage
//                                      under CMD2, and the whole transfer
//                                      lossage --- the timeout, NXM, overrun,
//                                      and the header and ECC errors
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
// **THE STORE IS HELD TWO TICKS, AND THE TIMERS IT LOADS ARE LOADED TWO TICKS
// SHORT.**  The acknowledgement stays a gate; what lands two ticks after the
// request is the REGISTERS' update --- the command, the disk address, the
// pointer, and everything a START does.  Measured with the drive present in
// the fitter for the first time (the pack side gives it a real seam, so it
// stops constant-folding): the decision to store was a function of the bus
// interface's tick counter --- `elapsed` reaching the 80 ns setup makes
// `-XBUS.RQ`, which makes `asked`, which through "a write, not taken, into
// register 3, a transfer, a drive present" reached the clock enable of every
// drive register --- seven logic levels and 6.8 ns, 3,620 endpoints failing
// by up to 2.077 ns on the DDR=1 board.  Held ONE tick it still failed by
// 1.483: the request was off the path, but the START's whole decode ---
// which register, is a drive present, a transfer or a track, a write to a
// read-only pack, a seek off the pack --- still sat between registers and
// the data pins of every register a START loads, ten logic levels into
// `acc_spin`.  So the hold is two ticks: the first latches the request, the
// word and the register number; the second DECODES, from registers only, into
// one flag a decision; the third acts on the flags, two logic levels from a
// data pin.
// Nothing on the bus can see 5 ns in a register: the next bus cycle is 145 ns
// away.  What CAN see it is the trace, which samples every timer a START
// loads either side of its expiry to the tick --- so each such load is made
// with `STORE_HOLD_NS` less, written at the load and not hidden in the
// constant, the way `RD_FINISH_T` carries its "two ticks short of 140 ns" in
// the open.  The word and the register number are taken as they stood at the
// request tick, from copies registered every tick with no enable, because on
// this bus the data lines may change the tick after the request drops; the
// decode's inputs --- the command, the disk address, the drive --- are
// registers a START store does not write, so reading them a tick later reads
// the same values.
// `disk-timeout-a-tick-short` and `disk-seek-settle-a-tick-short` are the
// records that prove the compensation is exact: both still fail their check
// by one tick, and would not if the hold had been paid for twice or not at
// all.
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

module cadr_disk_controller #(
    // How many blocks the store holds.  The pack is 263,245 of them and this
    // is a window on it: `S_AXI_HP2` fetches the block Linux put in DDR into
    // a slot, and the slot is what the channel reads and writes.  The
    // reference trace watches 23 blocks at once, which is what fixes the
    // number here; `tb/cadr_disk_tb.cpp` asserts the trace's own count
    // against it rather than assuming.
    parameter int unsigned SLOTS = 24
) (
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
    output var logic        drives,     // this slave is driving MEM<31:0>

    // --- the block store's seam ------------------------------------------
    //
    // **WHAT DRIVES THIS.**  `rtl/cadr_disk_pack.sv`, the pack side: the
    // pack is a file Linux puts in DDR, Linux writes the block's address over
    // `M_AXI_GP0`, and the master on `S_AXI_HP2` fetches the block's 259
    // words --- the block, its header, its header checkword and its data
    // checkword --- into a slot, then writes back whatever a Write left
    // there.  `tb/cadr_disk_tb.cpp` used to drive this seam from the trace's
    // `BLK` rows directly; it now drives the pack side's registers and DDR
    // and the store is reachable only through the master.
    //
    // `store_addr` names one of the 260 places in a slot: 0..255 the block,
    // 256 the header, 257 its checkword, 258 the data's, and 259 the TAG ---
    // `{4'd0, cylinder<11:0>, head<7:0>, block<7:0>}`, whose write is also
    // what makes the slot valid.  **A tag written with bit 31 set takes the
    // slot's block away instead**: the slot is invalid until its tag is
    // written again, and the tag it had stands unread.  `cadr_disk_pack.sv`
    // does that first and writes the tag last, so that a walk reaching the
    // slot during the ~300 ticks of a fill misses it rather than reading a
    // block half old and half new.
    //
    // `store_rdata` is TWO ticks behind `store_addr`: the block RAM's own
    // tick, and one in a register on the way out --- the read is the RAM's
    // output through a mux, 2.6 ns of the tick before it has crossed to the
    // pack side, and it reached that module's registers 19 ps late on the
    // DDR=1 board at ef9dee9.  It is what the write-back reads, and the only
    // way anything outside can see what a Write left on the pack.  The pack
    // side drives the four lines below from registers of its own, so a write
    // lands here the tick after it decides one.
    input  var logic        store_we,
    input  var logic [4:0]  store_slot,
    input  var logic [8:0]  store_addr,
    input  var logic [31:0] store_wdata,
    output var logic [31:0] store_rdata,
    // **A BLOCK THE WALK ASKED FOR AND THE STORE DOES NOT HOLD.**  The
    // store is a window on the pack that Linux fills, and a block it was not
    // given is a block the walk cannot have: the transfer stops where it
    // stands and this stays up until the next reset, so that it is never
    // silent.  `cadr_disk_pack.sv` reads it back to Linux in its status word;
    // `tb/cadr_disk_tb.cpp` requires it low at every tick of the trace, and
    // `tb/cadr_disk_pack_tb.cpp` requires it up when a slot has been taken
    // away.  A walk that meets a FILL in progress waits for it (`store_busy`)
    // and then finds the block, so that is not a miss.  **Fetching on demand
    // --- the walk waiting for Linux to fill a slot it did not ask for yet,
    // rather than stopping --- is not built**: it has no reference, and the
    // wait would sit inside a transfer whose time the trace compares.
    output var logic        store_miss,

    // --- the memory channel, a MASTER on the Xbus -------------------------
    //
    // **NO muir REFERENCE EXISTS FOR THIS.**  `Controller::write` reaches
    // `main` directly and in no time at all, so what the channel is held to
    // is a property and not a trace, exactly as `cadr_axi_master.sv` is: the
    // block lands whole, at the address the command list names, and the
    // processor's own memory cycles are still answered inside their timeout.
    // `cadr_memory_path.sv` has the two-way arbiter that makes the second
    // half true, and its own check has the scenario.
    //
    // One word a cycle, the request standing until `ch_done`.  `ch_nxm`
    // arrives with `ch_done` and says nothing was there, which is muir's
    // `page + BLOCK_WORDS > main.len()` --- the same predicate, because a
    // page is 256-aligned and a board is 65,536 words, so a page is wholly
    // inside main memory or wholly outside it.
    output var logic        ch_req,
    output var logic        ch_write,
    output var logic [21:0] ch_addr,    // a word address
    output var logic [31:0] ch_wdata,
    input  var logic        ch_done,
    input  var logic        ch_nxm,
    input  var logic [31:0] ch_rdata,
    // **THE INTERLOCK THE OTHER HALF OF THE SEAM NEEDS.**  While this is up
    // the channel owns the slot it is working on: `S_AXI_HP2` must not fetch
    // a block into it and must not write one back out of it.  It is the
    // board's own `BUSY` for a transfer, and `STATUS<0>` is made from it ---
    // which is why it is an output and not something to be inferred from the
    // status register: a thing outside cannot make a bus cycle to find out
    // whether it is allowed to make a bus cycle.
    output var logic        ch_active,
    // **AND THE OTHER HALF OF THE INTERLOCK.**  While the pack side is moving
    // a block through the seam --- filling a slot or writing one back --- a
    // walk must not touch the store, so a transfer STARTed then defers its
    // first command-list fetch until the move is over.  The time waited is
    // the walk's own and comes off the access time like the rest of it.
    // Mutual, because either side alone leaves a tick in which the other
    // may begin: the pack side's copy of `ch_active` is a register and so a
    // tick behind, which is why `ch_active` is announced two ticks ahead of
    // the walk below, and this is what covers the tick the announcement
    // cannot.  Nothing in either trace ever overlaps the two, so this is held
    // by `tb/cadr_disk_pack_tb.cpp`'s property and not by muir.
    input  var logic        store_busy
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

  // Two ticks: how long a register store is held past the request that made
  // it, for the fitter's sake --- see the note at the top.  Every timer a
  // store loads is loaded this much short, and the walk's own tally of ticks
  // starts at it, so that what expires expires at muir's instant.
  localparam logic [31:0] STORE_HOLD_NS = 32'd10;

  // **AND ONE TICK MORE ON THE WAY OUT.**  The counters' answers in the
  // status word are registers --- `busy_zero_q`, `att_zero_q`,
  // `block_counter_q` --- because as wires --- a 32-bit zero test, eight
  // 28-bit ones, two compares on the spindle --- then the word, the register
  // mux, the driver, the machine's join and the memory path's mux, they were
  // eight logic levels into MD's data pins across three modules: `disk/busy_ns_reg[*]/C -> processor/md_held_reg[*]/D`, -0.46 ns
  // on the DDR=1 board once the disk was timed at the tick.  A register there
  // shows every timer's expiry one tick late, so every timer is loaded one
  // tick shorter still, and the spindle starts one tick further on: what the
  // register shows at any tick is then what the wire showed at it.  The
  // trace's own tick-sharp samples --- `disk-timeout-a-tick-short`,
  // `disk-seek-settle-a-tick-short`, `disk-index-pulse-a-tick-narrow` ---
  // are what say the compensation is exact, as they say it of the store's.
  localparam logic [31:0] READ_HOLD_NS = 32'd5;
  // What a timer a START loads is loaded short by, all told.
  localparam logic [31:0] HOLD_NS = STORE_HOLD_NS + READ_HOLD_NS;

  localparam logic [27:0] SEEK_SETTLE_NS       = 28'd5_939_729;
  localparam logic [16:0] SEEK_NS_PER_CYLINDER = 17'd60_271;

  // A block is 256 words, and the code is run over every bit of them.
  localparam int unsigned BLOCK_WORDS = 256;
  // `Ecc::CYCLE`: how many shifts with feedback and nothing coming in bring
  // the code back on itself.  muir calls it measured rather than read ---
  // `newdsk.31`'s "ECC FIELD SIZE", which it calls "about 3 milliseconds".
  localparam int unsigned ECC_CYCLE = 42_945;
  // The scan runs over the block and gives up one step past its end.
  localparam int unsigned ECC_BITS  = BLOCK_WORDS * 32;
  localparam int unsigned ECC_SPIN  = ECC_CYCLE - ECC_BITS;   // 34,753

  // --- DCECC, thirty-two stages ------------------------------------------
  //
  // `ECC.OUT` and `ECC1` to `ECC31`, four 74LS273s clocked on `CLK.SR^`,
  // every stage taking the one above it and four of them --- `ECC29`,
  // `ECC20`, `ECC10` and `ECC8` --- taking it exclusive-or `ECC.IN` through
  // the 74LS86s at 0E27.  `ECC.IN` is the data bit exclusive-or `ECC.OUT`,
  // gated by `ECC FEEDBACK ENABLE`.  So the taps are 31, 29, 20, 10 and 8.
  //
  // **THE CHECKWORD IS THE REGISTER.**  What the controller writes after a
  // field is the register shifted out with feedback OFF, `ECC.OUT` first ---
  // and with feedback off a shift is a shift, so the k'th bit out is the
  // k'th bit of the register.  `Ecc::checkword()` and `Ecc::raw()` are the
  // same thirty-two bits, which is why nothing here shifts a checkword out.
  localparam logic [31:0] ECC_TAPS = 32'hA010_0500;

  function automatic logic [31:0] ecc_bit(input logic [31:0] ecc_in,
                                          input logic d, input logic fb);
    logic inp;
    inp = fb && (d ^ ecc_in[0]);
    ecc_bit = {1'b0, ecc_in[31:1]} ^ (inp ? ECC_TAPS : 32'd0);
  endfunction

  // A byte a tick, low-order bit first, as everything on this disk goes.
  // `docs/disk-controller.md`'s figure for a block: 8,224 shifts, 5 us eight
  // at a time.
  function automatic logic [31:0] ecc_byte(input logic [31:0] ecc_in,
                                           input logic [7:0] b);
    logic [31:0] t;
    t = ecc_in;
    for (int k = 0; k < 8; k++) t = ecc_bit(t, b[k], 1'b1);
    ecc_byte = t;
  endfunction

  // --- the format on the pack, byte by byte --------------------------------
  //
  // `disk_unit::format`, which is `sys/doc/disk.text`'s "The format of a
  // block is" read straight down.  Ten fields adding to 1,164 bytes, which is
  // the sector length MIT set the drive's jumpers to --- `dctrid.drw`, "Set
  // sector length jumpers in drive to 1410 (octal) which is 1164. bytes".
  // Everything goes low-order bit first and low-order byte first.
  //
  // **THE OFFSETS ARE WRITTEN AS SUMS AND NOT AS NUMBERS**, so that a field
  // whose length is questioned moves the ones after it.
  localparam int unsigned F_PREAMBLE = 53;                       // ones
  localparam int unsigned F_VFO_LOCK = 8;                        // ones
  localparam int unsigned F_HDR_SYNC = F_PREAMBLE + F_VFO_LOCK;  // 61
  localparam int unsigned F_HEADER   = F_HDR_SYNC + 1;           // 62
  localparam int unsigned F_HECC     = F_HEADER + 4;             // 66
  localparam int unsigned F_RELOCK   = F_HECC + 4;               // 70, ones
  localparam int unsigned F_DAT_SYNC = F_RELOCK + 20;            // 90
  localparam int unsigned F_PAD      = F_DAT_SYNC + 1;           // 91
  localparam int unsigned F_DATA     = F_PAD + 1;                // 92
  localparam int unsigned F_DECC     = F_DATA + BLOCK_WORDS * 4; // 1116
  localparam int unsigned F_POST     = F_DECC + 4;               // 1120, ones
  localparam int unsigned F_SECTOR   = 1164;
  // "A track contains (approximately) 20160. bytes (on a T-80 or a T-300)",
  // which is Century Data's exact figure.  Seventeen sectors are 19,788 of
  // them and the rest is the leftover the index closes, holding no block and
  // written with ones like every other gap.
  localparam int unsigned F_TRACK    = 20160;
  localparam int unsigned F_LEFTOVER = F_TRACK - 17 * F_SECTOR;  // 372
  // "SYNC - a byte containing octal 177", seven ones then a zero low bit
  // first, and "PAD - a byte containing octal 377".
  localparam logic [7:0]  F_SYNC     = 8'o177;
  localparam logic [7:0]  F_PADB     = 8'o377;

  // **A SECTOR IS 291 WHOLE WORDS AND THE LEFTOVER 93**, so every boundary
  // this slice counts is a word boundary and neither the serialiser nor the
  // parser ever straddles one.  `lay_down_track` cuts the written bytes at
  // 1,164-byte strides and knows nothing of the leftover, which is why the
  // parser counts words and not sectors of the track.
  localparam int unsigned F_SECTOR_W = F_SECTOR / 4;             // 291
  localparam int unsigned F_SECTOR_B = F_SECTOR * 8;             // 9,312
  // What the parser still needs when it finds the data's sync: the pad, the
  // data and its checkword.  `take_bits` answers `None` if they do not fit in
  // the chunk, and NOTHING IS WRITTEN when it does --- which is why the fit
  // is asked at the sync and not discovered by running off the end.
  localparam int unsigned F_TAIL_B   = 8 + BLOCK_WORDS * 32 + 32;  // 8,232
  // `after_sync`: "a zero after at least sixty-four ones, which is how the
  // controller finds one too --- its `PREAMBLE DETECT` fires on the first
  // zero after ones, and the preamble is never shorter than eight bytes of
  // them."  Eight bytes of VFO LOCK is where the 64 comes from.
  localparam int unsigned F_ONES     = 64;

  // --- the block store ----------------------------------------------------
  //
  // 259 words a slot and a tag beside them.  The 256 data words are a block
  // RAM with two ports --- the seam on one and the channel on the other, so
  // a fill and a walk never contend --- and the three words and the tag are
  // small enough to be registers.
  //
  // **A READ THAT NEVER HAPPENED MUST NOT READ BACK LIKE ONE THAT DID**, and
  // that is a property of the trace rather than of this file: every word of
  // every block it lays down is a function of both the block and the offset
  // within it, so no wrong slot and no wrong offset gives the right word.
  // `golden/src/disk.rs` says so at its `pack_word`.
  logic [31:0] blk_ram [SLOTS*BLOCK_WORDS];
  logic [31:0] s_header [SLOTS];
  logic [31:0] s_hck    [SLOTS];
  logic [31:0] s_dck    [SLOTS];
  logic [27:0] s_tag    [SLOTS];
  logic [SLOTS-1:0] s_valid;

  // The one word of a slot the channel writes as well: a Write leaves a fresh
  // data checkword behind it --- "the board writes a fresh checkword after
  // every data field it writes" --- and `Unit::write_block_at` drops the
  // pack's old one for the same reason.  It is driven from the channel's
  // process below and taken here so that the register has one driver.
  logic       ch_dck_we;
  logic [4:0] ch_dck_slot;
  logic [31:0] ch_dck_val;

  // The seam's port.  `store_addr` above 255 is the header, the two
  // checkwords and the tag, in that order.
  logic [12:0] seam_word;
  logic [31:0] seam_meta;
  assign seam_word = 13'(store_slot) * 13'(BLOCK_WORDS) + 13'(store_addr[7:0]);
  always_comb begin
    unique case (store_addr[1:0])
      2'd0: seam_meta = s_header[store_slot];
      2'd1: seam_meta = s_hck[store_slot];
      2'd2: seam_meta = s_dck[store_slot];
      default: seam_meta = {4'd0, s_tag[store_slot]};
    endcase
  end

  // **THE READ IS A PLAIN REGISTER AND THE MUX IS OUTSIDE IT**, which is not a
  // style: a block RAM's port is `if (we) ram[a] <= d; q <= ram[a];` and
  // nothing else, and a mux on the read inside the same process is
  // "Unsupported RAM template [Synth 8-2914]" --- synthesis stops rather than
  // inferring registers, which is the good case.  Measured on the DDR=0 board
  // flow the first time this store was fitted.
  logic [31:0] seam_q, seam_meta_q;
  logic        seam_meta_sel;
  always_ff @(posedge clk) begin
    if (store_we && store_addr < 9'(BLOCK_WORDS)) blk_ram[seam_word] <= store_wdata;
    seam_q <= blk_ram[seam_word];
  end
  always_ff @(posedge clk) begin
    seam_meta_q   <= seam_meta;
    seam_meta_sel <= store_addr >= 9'(BLOCK_WORDS);
    // The second tick: the mux into a register, so that what crosses the
    // seam starts at one.  See the port.
    store_rdata   <= seam_meta_sel ? seam_meta_q : seam_q;
  end

  // The reset is at the END of this process so that only `s_valid` carries
  // it: the tag, the header and the checkwords are not reset --- a slot is
  // valid by its bit and not by its contents --- and written with the reset
  // in front of them, every one of their enables took the synchroniser's net.
  always_ff @(posedge clk) begin
    if (store_we && store_addr >= 9'(BLOCK_WORDS)) begin
      unique case (store_addr[1:0])
        2'd0: s_header[store_slot] <= store_wdata;
        2'd1: s_hck[store_slot]    <= store_wdata;
        2'd2: s_dck[store_slot]    <= store_wdata;
        default: begin
          // Bit 31: the block is taken away, and the tag it had stands.
          if (store_wdata[31]) begin
            s_valid[store_slot] <= 1'b0;
          end else begin
            s_tag[store_slot]   <= store_wdata[27:0];
            s_valid[store_slot] <= 1'b1;
          end
        end
      endcase
    end else if (ch_dck_we) begin
      s_dck[ch_dck_slot] <= ch_dck_val;
    end else if (trk_meta_we) begin
      // `write_sector_at`: the header, its checkword and the data's, as the
      // parser found them and not as they should have been.  "A formatter
      // can write a checkword that does not check", and `STATUS<17>` is what
      // a later Read makes of it.
      s_header[ch_slot] <= ps_hdr;
      s_hck[ch_slot]    <= ps_hck;
      s_dck[ch_slot]    <= ps_dck;
    end
    if (rst_q) s_valid <= '0;
  end

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
  //
  // **AND THE GATE IS THE BUS INTERFACE'S, NOT THIS SLAVE'S.**  What is
  // driven here is the held match alone.  `cadr_busint_xbus.sv` reads
  // `dev_ack` in one place, `answering = GRANTED && dev_rq && dev_ack`, so
  // the AND with -XBUS.RQ is made there whatever a slave puts on the line,
  // and a slave that made it too sent the request out to itself and back:
  // `busint/FSM_sequential_state_reg[1]/C -> processor/mfinish_t_reg[*]/CE`,
  // six logic levels and 4.98 ns on the DDR=1 board at ef9dee9, of which
  // one level and two crossings were -XBUS.RQ arriving here to be ANDed with
  // `mine` and leaving again as the acknowledgement.  Fourteen of the
  // board's failing endpoints, all of them the processor's two countdowns,
  // which are counters and rightly outside the microcycle exception.  The
  // data lines are still driven only while `asked` --- `drives` below keeps
  // the request in it --- and -MEMACK lands on the same tick as before,
  // because the request was always a term of it at the far end.  What
  // `mine` says before -XBUS.RQ is up is what the address decode says: this
  // cycle is this slave's.  Nothing reads it then.
  assign dev_ack = mine;

  // --- the three registers a program can write ---------------------------
  //
  // `cmd` is write-only --- "Note that the command register cannot be read
  // back".  `clp` is write-only here too: register 1 reads back the LAST
  // MEMORY ADDRESS and not the pointer, MIT putting two different things at
  // one address, and nothing in this slice makes a memory reference.
  //
  // **ONLY 22 BITS OF `clp` LEAVE THE BOARD**, and the counter is only
  // sixteen of them: `DCCLP` is four 74LS569s at 0D21, 0D22, 0D23 and 0D25
  // counting `XBAO<15:0>` with the last carry going nowhere, and the 74LS374
  // at 0D26 holding `XBAO<21:16>` as `-LOAD CLP` latched it.  "Only bits
  // <15:0> of the CLP can count; if you attempt to carry into the high 8
  // bits you will wrap around."  The register takes all 32 as a program
  // writes them; the walk reads `<21:0>`.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] clp;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] cmd;
  logic [31:0] da;
  // The last memory reference, and where a burst was.
  logic [31:0] lma;
  logic [31:0] ecc_reg;

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

  // **THE RESET IS TAKEN INTO A REGISTER OF THIS MODULE'S OWN, AND THE
  // SPINDLE STARTS A TICK ON TO PAY FOR IT.**  `rst` is the board's
  // synchroniser, one net into some two and a half thousand reset pins here,
  // and the fitter could not bring a copy of it within reach of them all:
  // 4.7 ns of routing into the ECC register's clear with no logic on the
  // path at all.  `rst_q` is a tick behind, so this module comes out of
  // reset one tick after the machine does.  Nothing on the bus can reach it
  // in that tick, and nothing here moves in it but the spindle --- which
  // would then be five nanoseconds behind muir's `now` for ever, and the
  // trace samples the block counter either side of every edge.  So `spin`
  // and `into` are reset to FIVE for it, the value the machine's first free
  // tick would have put in them --- and to five more on top, for the read
  // word being a register a tick behind the counter (`READ_HOLD_NS`), so the
  // counter runs a tick ahead of muir's `now` and the word shows `now`.
  // `spin_q` to `spin_q3` stay at zero, which is what they hold at those
  // same ticks either way.
  // This is `STORE_HOLD_NS`'s argument at the other end of the run; the
  // record `disk-reset-held-and-not-paid-for` is what says the check sees
  // it, the same way `disk-timeout-a-tick-short` says it sees the hold.
  logic rst_q;
  always_ff @(posedge clk) rst_q <= rst;

  // **THE DRIVE SEAM IS NOT HELD ON THE WAY IN, AND THAT WAS MEASURED
  // TOO.**  The three come from registers Linux writes in
  // `cadr_disk_pack.sv`; driven straight into the status word as a wire
  // they crossed two modules and eight logic levels to land on MD, -0.129 ns
  // on the DDR=1 board at ef9dee9.  The counters in the status word are read
  // through registers now, which is what cut that path; a register on the seam as
  // well made the drive appear TWO ticks after Linux said so, and
  // `tb/cadr_disk_pack_tb.cpp` reads the status the tick after the DRIVE
  // register's write is acknowledged, saw an empty cable, and said so.  The
  // `_q` names stay, as the readers' side of the seam.
  logic [7:0] drive_present_q, drive_read_only_q;
  logic       drive_timed_q;
  assign drive_present_q   = drive_present;
  assign drive_read_only_q = drive_read_only;
  assign drive_timed_q     = drive_timed;

  logic [2:0] sel_unit;
  logic       present, read_only;
  assign sel_unit  = da[30:28];
  assign present   = drive_present_q[sel_unit];
  assign read_only = drive_read_only_q[sel_unit];

  logic [7:0] att_ready;
  always_comb begin
    for (int u = 0; u < 8; u++)
      att_ready[u] = drive_present_q[u] && u_att_armed[u] && att_zero_q[u];
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
  // `spin` as it stood three ticks ago: what a START held two ticks reads
  // for the spindle's position at the request, exactly and across the wrap,
  // the counter itself running a tick ahead of muir's `now` for the read
  // word's sake (`READ_HOLD_NS`).  A subtraction would have to know whether
  // the block's instant fell inside the tick, and muir's `until` decides
  // that at the request.
  logic [23:0] spin_q, spin_q2, spin_q3;
  logic [19:0] into;
  logic [4:0]  region;
  logic        wrapping, stepping;
  logic [19:0] pulse_ns;

  assign spin_next = spin + 24'd5;
  // **THE WRAP AND THE STEP ARE REGISTERS, COMPARED A TICK EARLY.**  As
  // gates on `spin_next` and `into + 5` they put an adder, a compare and the
  // subtraction in series on the counters' own data pins, thirteen logic
  // levels; `spin >= REVOLUTION_NS - 10` at tick t is `spin + 5 >=
  // REVOLUTION_NS` at t+1, which is `cadr_phase_gen.sv`'s trick for its
  // taps.  After a wrap the count is under five, so the tick after a wrap
  // cannot wrap, and after a step `into` is under five likewise; both terms
  // are written in.  `disk-index-pulse-a-tick-narrow` and
  // `disk-block-counter-off-by-a-region` are what say the edges still fall
  // where muir puts them.
  logic wrap_q, step_q;
  assign wrapping  = wrap_q;
  assign stepping  = step_q;
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
  // **BUSY IS UP WHILE THE CHANNEL IS WALKING**, which is the board's own
  // `BUSY` and not muir's: muir's transfer takes no time, so `done_at` is the
  // whole of its not-active and there is no instant during a walk for
  // anything to read.  In fabric there is, and a controller that said "not
  // active" in the middle of moving a block would be lying to a driver
  // polling `<0>`.  Nothing in either trace reads the register during a walk,
  // so the two cannot be told apart there.
  logic        ch_busy;
  // Through the register, with the store looked ahead at: see the note at
  // `busy_zero_q`.
  assign not_active = busy_zero_q && !ch_busy;

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
  //
  // **THREE REGISTERS DEEP, NOT ONE, AND NOT FOUR.**  The operands --- the
  // heads' cylinder through the unit's mux, the address's, the recalibrate's
  // decode --- into the first; the distance, a compare and a difference,
  // into the second; the multiply with the settle added on the multiplier's
  // own post-adder into the third.  In one tick they were ten logic levels
  // into the multiplier's input alone, -5.9 ns on the DDR=1 board at
  // ef9dee9, the first fit to time the disk at all.
  //
  // **THREE IS THE MOST THE TRACE ALLOWS**, and that is a measurement and
  // not a guess: `tb/cadr_disk_pack_tb.cpp` and the trace both place a store
  // into the disk address and the START that reads its distance four ticks
  // apart --- back-to-back bus writes on the 5 ns grid --- so `seek_ns_r`
  // must hold the new address's distance three edges after `da` takes it.
  // A fourth stage, tried first, read the old distance at every such START
  // and the property check said so at its first timed seek.  The heads and
  // the command are the other inputs and change no closer to a START than
  // that.
  //
  // The compare that says which way the difference goes is made in the
  // first stage with the operands, so the second is two differences side by
  // side and a choice; and the value the timers take --- the seek less the
  // hold --- is a second product with its own settle, because the hold's
  // subtraction after the sum was nine logic levels into every attention
  // countdown.  Zero stays zero: a seek to the cylinder the heads are on has
  // a zero settle and a zero product either way.
  logic        is_recal, is_recal_r, gt_r;
  logic [11:0] cyl_now, cyl_to, cyl_now_r, cyl_to_r, cyl_n, cyl_n_r;
  logic [7:0]  head_now_r, blk_now_r;
  logic [27:0] settle_r, settle_held_r, seek_ns_c, seek_held_c, seek_ns_r, seek_held_r;
  assign is_recal = (cmd[2:0] == 3'b101) && cmd[9];
  assign cyl_now  = u_cyl[sel_unit];
  assign cyl_to   = da[27:16];
  assign cyl_n    = is_recal_r ? cyl_now_r
                               : (gt_r ? cyl_now_r - cyl_to_r : cyl_to_r - cyl_now_r);
  // Both operands widened before the multiply, or the product is taken at the
  // width of the wider one and 4,095 cylinders of it fall off the top.
  assign seek_ns_c   = 28'(cyl_n_r) * 28'(SEEK_NS_PER_CYLINDER) + settle_r;
  assign seek_held_c = 28'(cyl_n_r) * 28'(SEEK_NS_PER_CYLINDER) + settle_held_r;

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
  //
  // **THE SEVEN OTHER TRANSFER ERROR FLOPS ARE HERE NOW**, and they are the
  // 74LS273s at DCSTS 0C12 and 0D24 and the 74LS279 at 0B12.  Every one is
  // cleared by `-RESET ERR` --- a store into register 0 --- and again at the
  // start of a transfer, which is `Controller::transfer`'s first act.
  logic e_rcdiff, e_ccwcyc, e_nxm, e_overrun;
  logic e_hdrcmp, e_hdrecc, e_ecchard, e_eccsoft;

  //
  // **WHAT IS HELD IS THE COUNTERS' ANSWERS, AND ONLY THOSE.**  Three
  // registers stand between the counters and the status word: whether the
  // busy counter is at zero, whether each attention countdown is, and the
  // block counter --- a 32-bit zero test, eight 28-bit ones and two compares
  // on the spindle, which with the rest of the word behind them were eight
  // logic levels into MD's data pins.  Each is a tick behind the counter it
  // reads, and the timers pay for the tick (`READ_HOLD_NS`).  Everything
  // else in the word is a flop read straight: the command, the timeout and
  // the seven other error flops, the drive's own two, the arm of each
  // attention.  A first draft registered the whole word, and the trace's
  // check found what that costs: `tb/cadr_disk_tb.cpp` reads a register back
  // the tick after a store into it lands, with no tick between, and a word a
  // tick behind shows that read the flops as they stood before the store ---
  // which is the same word a design that had mis-written one of them shows,
  // so `disk-reset-err-reaches-the-drive` survived.  The flops stay wires
  // into the word for that reason, and the one counter a command store
  // reaches --- BUSY, on a `0o16` or an init --- has the store looked ahead
  // at in its register's own tick.
  logic       cmd_reset;
  logic       busy_zero_q;
  logic [7:0] att_zero_q, block_counter_q;
  assign cmd_reset = xbus_init || (st_go && st_which == 2'd0 && st_wdata[3:0] == 4'o16);
  always_ff @(posedge clk) begin
    busy_zero_q     <= (busy_ns == 32'd0) || cmd_reset;
    for (int u = 0; u < 8; u++) att_zero_q[u] <= (u_att_ns[u] == 28'd0);
    block_counter_q <= block_counter;
  end

  logic transfer_lossage, disk_lossage, lossage;
  assign transfer_lossage = (timeout && not_active) || e_nxm || e_overrun
                          || e_hdrecc || e_hdrcmp || e_ecchard || e_eccsoft;
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
  assign status = {block_counter_q, 24'd0}                     // <31:24>
                | (e_rcdiff   ? 32'h0040_0000 : 32'd0)         // <22>
                | (e_ccwcyc   ? 32'h0020_0000 : 32'd0)         // <21>
                | (e_nxm      ? 32'h0010_0000 : 32'd0)         // <20>
                | (e_hdrcmp   ? 32'h0004_0000 : 32'd0)         // <18>
                | (e_hdrecc   ? 32'h0002_0000 : 32'd0)         // <17>
                | (e_ecchard  ? 32'h0001_0000 : 32'd0)         // <16>
                | (e_eccsoft  ? 32'h0000_8000 : 32'd0)         // <15>
                | (e_overrun  ? 32'h0000_4000 : 32'd0)         // <14>
                | ((timeout && not_active) ? 32'h0000_0800 : 32'd0)   // <11>
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
      // 0: STATUS.  The counters in it are read through registers: see
      // `READ_HOLD_NS`.
      2'd0: word = status;
      // 1: MEMORY ADDRESS.  "Address of the last memory reference made by the
      // disk control."  <23:22> is the controller type, 0 for a Trident, so
      // the register is the address alone.  The channel writes it at every
      // command-list fetch and again at the last word of every page it
      // moves; muir has it as "the last memory reference", so a page counts
      // once and not 256 times.
      2'd1: word = lma;
      // 2: DISK ADDRESS, read back as it was written --- or, after a
      // transfer, as the walk left the heads.
      2'd2: word = da;
      // 3: ERROR CORRECTION.  "<31:16> Error pattern bits.  <15:0> Error bit
      // position."  What `Ecc::trap` found: the burst brought down to bit 0,
      // and where its first errored bit is.  "Note that the bit position is
      // off by 1; the first bit in the block is bit 1."
      default: word = ecc_reg;
    endcase
  end

  // **A SLAVE DRIVES MEM<31:0> ONLY WHILE IT IS ANSWERING A READ.**  That is
  // the rule `cadr_xbus_ddr.sv` learned the hard way: its `rdata` register
  // held the last word it returned and every unanswered cycle strobed MD with
  // it.  Here the answer is combinational, so there is no register to hold
  // anything, and the driver is named rather than implied --- `drives` is
  // what `cadr_machine.sv` mixes this onto the seam with, and what leaves the
  // seam free on a write, where MEM<31:0> belongs to the master.
  //
  // **AND `drives` IS THE MATCH AND THE DIRECTION, NOT THE REQUEST.**  As
  // `asked && !dev_write` the request was a term of every data line: the bus
  // interface's counter through this gate, the word mux, the machine's join
  // and the memory path's mux to MD's data pins, `busint/elapsed_reg[*]/C ->
  // processor/md_held_reg[*]/D` at -1.2 ns.  The word is on the lines from
  // the moment the slave is selected for a read, and what samples them is
  // -LOADMD, with the request up; a write cycle shows the seam's poison
  // exactly as before, because the direction is still in it.
  assign drives = mine && !dev_write;
  assign rdata  = drives ? word : 32'd0;

  // --- what a write does -------------------------------------------------
  //
  // ONCE PER BUS CYCLE.  `-XBUS.RQ` stands from the setup boundary until the
  // cpu lifts -MEMRQ, tens of ticks, and `Controller::write` runs once.  The
  // three register stores are idempotent and would not care; START is a pulse
  // and does.  So the cycle is latched the way `cadr_xbus_ddr.sv` latches
  // `done`, and cleared when the request goes --- and the store itself lands
  // the tick after it is latched, held for the fitter; see the top.
  logic taken;
  // The store, held: `store_now` is the tick the request is first seen;
  // `store_q` the tick after, with `wdata_q` and `which_q` the word and the
  // register as they stood at the request, when the decode is made; and the
  // `st_*` flags the tick after that, when the registers take it.  Each flag
  // is one decision of the START, made from registers, so that what reaches
  // a data pin is a flag and not a decode.
  logic        store_now, store_q;
  logic [31:0] wdata_q;
  logic [1:0]  which_q;
  assign store_now = asked && dev_write && !taken;
  logic        st_go;
  logic [31:0] st_wdata;
  logic [1:0]  st_which;
  logic        st_seek_here, st_seek_off;
  // **ONE FLAG A DECISION, AND THE DECISION MADE WHOLE.**  The second stage
  // used to hold the START's terms separately --- can it start, is the
  // command a transfer, is a drive present, is the pack read-only --- and
  // the third ANDed them again in front of every register a START loads:
  // with the request and the command's code beside them that was a cone of
  // eleven register bits, five and six logic levels into the clock enables
  // of the heads' position, 173 failing endpoints from `st_is_all` alone
  // when the disk was first timed at the tick.  Each flag below is the
  // whole of one arm's condition, so the third stage asks one bit and the
  // unit.  The codes are disjoint, so exactly one flag can be up, and the
  // command's code and two bits ride along as registers so that `cmd` is
  // not in the cone either.
  logic        st_xfer;        // a Read, Read-Compare or Write, on a present drive that is not read-only
  logic        st_all;         // a Read All or Write All, likewise
  logic        st_fault;       // a write to a read-only pack: the fault and nothing else
  logic        st_rev;         // 0o01 or 0o03: the access time alone
  logic        st_seek;        // 0o04 or 0o14 with a drive
  logic        st_atease;      // 0o05 or 0o15 with a drive
  logic        st_hang;        // a START the sequencer never finishes
  logic [3:0]  st_code;
  logic        st_recal, st_fclr;   // `cmd[9]` and `cmd[8]`, as they stood

  // "Writing anything at this address initiates the operation specified in
  // the command, disk address, and command list pointer registers."  It is
  // the `which == 2'd3` arm of the write below, and the four bits it acts on
  // are these.
  //
  // **WHAT EACH COMMAND CODE DOES, AND WHERE THE ONE HOLE IS.**  0o00 read,
  // 0o10 read-compare and 0o11 write reach `Controller::transfer` and the
  // walk below it, all of it here.  0o02 Read All and 0o13 Write All reach
  // `Controller::transfer_all`, which walks the same command list with a
  // track's bytes on the disk side instead of a block's words, and that is
  // here too.  0o01 and 0o03 reach neither and are charged an access time
  // alone.
  //
  // A WRITE TO A READ-ONLY PACK is the exception to all of it: muir raises
  // the fault and returns before anything is cleared or moved, so it is here
  // in full and its status is compared with no exemption.
  logic [3:0] code;
  logic       is_transfer, is_all, is_reversed, ro_fault;
  assign code        = cmd[3:0];
  // The three that walk the command list a block at a time.
  assign is_transfer = (code == 4'o00) || (code == 4'o10) || (code == 4'o11);
  // The two that go round the track as bytes, `Controller::transfer_all`.
  assign is_all      = (code == 4'o02) || (code == 4'o13);
  // "01, 03 and 12: the Write, Write All and Read All sectors entered with
  // the memory channel pointed the other way."  **They do not seek**, which
  // is not an omission: `Controller::start` reaches neither `transfer` nor
  // `transfer_all` for them and charges the access time alone --- and 03
  // raises the overrun, measured on the netlist board and modelled from that
  // measurement.  12 hangs and is with the reserved codes below.
  assign is_reversed = (code == 4'o01) || (code == 4'o03);
  assign ro_fault    = ((code == 4'o11) || (code == 4'o13)) && read_only;

  // A store into START with nothing on the selected unit's cable does nothing
  // at all unless the command's bit 2 is up: `Controller::start` returns
  // before it looks at the code.  Sectors 4 to 7 --- seek, at ease, offset
  // clear, and the reserved codes --- are the ones that do not need a drive.
  logic can_start;
  assign can_start = present || cmd[2];
  // The store being decoded is a START that may start: register 3, with
  // `can_start`.  And the codes the arms below are keyed on, named here so
  // that the flags read as the arms do.
  logic start_c, is_seek, is_atease, is_hangs;
  assign start_c   = (which_q == 2'd3) && can_start;
  assign is_seek   = (code == 4'o04) || (code == 4'o14);
  assign is_atease = (code == 4'o05) || (code == 4'o15);
  assign is_hangs  = (code == 4'o07) || (code == 4'o17) || (code == 4'o12);

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
  // Against the copies the seek's first stage keeps of the heads' position,
  // which stand a tick behind them: the heads move at a START, and the next
  // START's decode is two ticks after that at the closest the bus allows.
  assign seek_here     = (da_cyl == cyl_now_r) && (da_head == head_now_r)
                      && (da_blk == blk_now_r);
  assign seek_off_pack = (da_cyl >= 12'(CYLINDERS)) || (da_head >= 8'(HEADS))
                      || (da_blk >= 8'(BPT));

  // ------------------------------------------------------------------------
  // THE MEMORY CHANNEL
  // ------------------------------------------------------------------------
  //
  // `Controller::command_list` as a clocked machine.  muir walks the list in
  // no time at all and this walks it a word a tick, so the two agree about
  // what happened and not about when --- which is why the channel's own
  // instant is not compared anywhere and its RESULT is compared everywhere.
  //
  // The order the states go in is muir's order and it is not arbitrary: the
  // header compare is asked before the header's checkword because the board
  // asks it there --- `newdsk.31` at `033`, four steps past the last HEADER
  // STROBE --- which is why MIT writes "Unfortunately most header ECC errors
  // show up as header compare errors instead".  The data checkword is asked
  // before the page is looked at, so a block that does not check moves
  // nothing.  And the page's NXM is discovered by the first word's own bus
  // cycle, which is where muir's `page + BLOCK_WORDS > main.len()` sits.
  //
  // **THE TIME A TRANSFER TAKES IS THE DRIVE'S AND NOT THE WALK'S.**
  // `access_ns` is the heads' move, then the wait for the addressed block to
  // come round, then a sector a block --- milliseconds, where the walk is
  // microseconds.  muir measures it from the instant of the START; this
  // finishes the walk some ticks after that instant, so `elapsed` counts what
  // the walk spent and the busy counter is loaded with the difference.  Get
  // that wrong and not-active flips a walk's length late, which the trace
  // samples for, a sector at a time.
  typedef enum logic [4:0] {
    C_IDLE, C_CCW, C_LOOK, C_HDRC, C_HDRE, C_HDRCK, C_DATA, C_DCK, C_ECCQ,
    C_TSPIN, C_TSCAN, C_TSOFT, C_TSOFT2, C_MOVE, C_WEND, C_NEXT,
    C_ACCMUL, C_ACCMOD, C_ACCMOD2, C_ACCSUM, C_ACCSUM2, C_ACCSUM3, C_ACCDIFF,
    C_ACCFIN,
    // The track: the slot the first sector comes out of, then a page at a
    // time in either direction.
    C_TLOOK, C_TRD, C_TWR
  } ch_state_e;

  ch_state_e   ch_state;
  logic [15:0] ch_n;            // which CCW the list is on
  logic [13:0] ch_page;         // XBI<21:8>, the page DCCCW latched
  logic        ch_more;         // XBI0, the More flag
  logic [4:0]  ch_slot;
  logic [2:0]  ch_unit;
  logic [8:0]  ch_i, ch_ra;     // the word being moved, and the store's read ahead
  logic [2:0]  ch_ph;
  logic [31:0] ecc_r, blk_w;
  logic        ch_read, ch_cmp; // the direction, and whether it only compares
  logic [7:0]  ch_moved;
  logic [16:0] trap_n;
  logic [13:0] trap_step;
  logic        ch_setda, ch_track;

  // --- the track, and the two halves that are inverses over it ------------
  //
  // `disk_unit::sector_image_laid` on the way out and
  // `disk_unit::parse_sector` on the way back.  A Read All puts the bytes
  // under the head into the pages the command list names, four to a word,
  // low-order byte first, going round and round --- the command does not
  // advance the head, so a list longer than a track comes back to where it
  // started.  A Write All takes the pages back into bytes, cuts them at
  // 1,164-byte strides and lays each one where the heads are, "The format is
  // determined by the program that uses the Write All operation to format
  // the disk".
  //
  // **THE BIT RATE IS THE DRIVE'S AND THIS IS NOT IT.**  `BIT_NS` is 104, so
  // a bit on the pack is 20.8 ticks of this clock and a whole track is a
  // revolution: 16,666,667 ns, 3,333,334 ticks.  The serialiser takes a BYTE
  // a tick and the parser a BIT a tick, and both pay a bus cycle a word on
  // top.  MEASURED on the property check's twenty pages, 5,120 words:
  //
  //     Read All   44,250 ticks    221 us     8.6 ticks a word
  //     Write All 184,427 ticks    922 us    36.0 ticks a word
  //
  // against the drive's 16.7 ms.  So the fabric is seventy-five times faster
  // than the pack in one direction and eighteen in the other, nothing here
  // is the constraint, and `track_ns` --- the heads' move, the wait for the
  // block, and one whole revolution --- is what the operation is charged,
  // exactly as muir has it.  What the stream does cost is the CHANNEL:
  // 5,040 words for a whole track, where the longest block transfer in
  // either trace is 256.
  logic [7:0]  trk_b, trk_b_next;   // which block this sector is
  logic [10:0] trk_p;               // the byte within the sector
  logic        trk_gap;             // in the track's leftover
  logic [8:0]  trk_g;               // the byte within it
  // **A PARSE THAT FAILS STOPS THE TRACK AND NOT THE WALK.**
  // `write_all_bytes` collects every page the list names and only then does
  // `lay_down_track` cut and parse them, so a chunk that will not parse ends
  // the LAYING where it stands while the command list goes on being fetched
  // --- which is what the last memory address and `STATUS<20>` are made of.
  logic        trk_lay;

  // The parser.  Bit-serial, because `parse_sector` is: `after_sync` hunts a
  // zero after at least sixty-four ones and nothing says that zero falls on
  // a byte boundary.
  //
  // **IT DOES NOT RUN THE CODE.**  `parse_sector` computes `header_checks`
  // and `data_checks` and `lay_down_track` reads NEITHER: what a Write All
  // lays down is the header, the checkword and the data as the program wrote
  // them, checking or not, and `STATUS<17>` and `<16>` are what a later Read
  // makes of them.  `cadrdc/newdsk.31` agrees --- HEADER STROBE appears only
  // in the Read sector at `024` and the Write sector at `124`, and the Write
  // All sector from `300` finds the index and writes the track out without
  // one.  So there is no DCECC in this path, and a checkword that does not
  // check survives the round trip, which is the whole of issue 51.
  typedef enum logic [2:0] {
    P_SYNC1, P_HDR, P_HCK, P_SYNC2, P_PAD_, P_DATA_, P_DCK, P_DONE
  } ps_state_e;
  ps_state_e   ps_st;
  logic [6:0]  ps_ones;     // consecutive ones, held at F_ONES
  // The field being taken, low-order bit first.  THIRTY-ONE bits and not
  // thirty-two: the thirty-second is the one arriving, so the word is
  // `{ps_bitv, ps_sh}` and nothing ever reads a bit the register has already
  // pushed out.  Written at thirty-two first, and lint said so.
  logic [30:0] ps_sh;
  logic [13:0] ps_n;        // bits into the field
  logic [8:0]  ps_wc;       // the word within the 291-word chunk
  logic [4:0]  ps_bit;      // the bit within the word
  logic [31:0] ps_hdr, ps_hck, ps_dck, ps_w;
  logic        ps_wr;       // a parsed word goes into the store this tick
  logic        trk_meta_we;
  logic        ps_bitv;

  assign trk_b_next = (trk_b == 8'(BPT-1)) ? 8'd0 : trk_b + 8'd1;
  // `take_bits` fits: `at + 1 + F_TAIL_B <= F_SECTOR_B` with `at` the bit's
  // place in the chunk, `{ps_wc, ps_bit}` --- which is `at <= F_SECTOR_B -
  // F_TAIL_B - 1`, written as the word and the bit of that bound so that it
  // is two constant compares and not an adder into a fourteen-bit one --- the fitter built the sum as a carry chain in front
  // of the parser's state.  Still in the format's own constants, so a field
  // whose length is questioned moves it.
  localparam int unsigned F_FIT_AT = F_SECTOR_B - F_TAIL_B - 1;   // 1,079
  logic ps_fits;
  assign ps_fits = (ps_wc < 9'(F_FIT_AT / 32))
                || ((ps_wc == 9'(F_FIT_AT / 32)) && (ps_bit <= 5'(F_FIT_AT % 32)));
  // Bit 0, always: the word is shifted down a bit as each is taken, so that
  // no thirty-two-way select stands in front of the parser.  `ps_bit` still
  // counts, for `ps_at` and the word's end.
  assign ps_bitv    = blk_w[0];

  // A byte is taken out of the track only while the serialiser is filling a
  // word, which is four ticks in every bus cycle.
  //
  // Whether the byte is the sector's last, or the leftover's, is a register
  // made a tick early: `trk_p` will be 1,163 next tick if it is 1,162 and
  // advancing, or 1,163 and not.  The compare was in front of `trk_b`'s
  // enable and the slot's.
  logic       trk_adv, trk_end_sec, trk_end_gap, trk_step;
  logic       trk_p_last_q, trk_g_last_q, ps_bit_last_q, ps_wc_last_q;
  assign trk_adv     = (ch_state == C_TRD) && (ch_ph <= 3'd3);
  assign trk_end_sec = !trk_gap && trk_p_last_q && (trk_b != 8'(BPT-1));
  assign trk_end_gap = trk_gap && trk_g_last_q;
  assign trk_step    = trk_adv && (trk_end_sec || trk_end_gap);
  logic [7:0] trk_byte_q;
  logic [1:0] trd_lane;            // which lane the byte a tick behind fills
  assign trd_lane = 2'(ch_ph - 3'd1);

  // The byte the head is over.  `sector_image_laid` written as a select:
  // 61 bytes of ones, the sync, the header and its checkword, 20 more ones,
  // the sync, the pad, the data and its checkword, and 44 ones.  The header
  // and its checkword start at byte 62, which is 2 modulo 4, and the data
  // and its checkword at 92 and 1,116, which are both 0 --- so two lane
  // indices are all this needs, and each is the byte offset taken modulo the
  // word.
  logic [1:0] lane_hi, lane_lo;
  logic [7:0] trk_byte;
  assign lane_hi = 2'(trk_p - 11'(F_HEADER));
  assign lane_lo = 2'(trk_p);
  always_comb begin
    if      (trk_gap)                       trk_byte = 8'hff;
    else if (trk_p <  11'(F_HDR_SYNC))      trk_byte = 8'hff;
    else if (trk_p == 11'(F_HDR_SYNC))      trk_byte = F_SYNC;
    else if (trk_p <  11'(F_HECC))          trk_byte = hdr_q[8*lane_hi +: 8];
    else if (trk_p <  11'(F_RELOCK))        trk_byte = hck_q[8*lane_hi +: 8];
    else if (trk_p <  11'(F_DAT_SYNC))      trk_byte = 8'hff;
    else if (trk_p == 11'(F_DAT_SYNC))      trk_byte = F_SYNC;
    else if (trk_p == 11'(F_PAD))           trk_byte = F_PADB;
    else if (trk_p <  11'(F_DECC))          trk_byte = chb_q2[8*lane_lo +: 8];
    else if (trk_p <  11'(F_POST))          trk_byte = dck_q[8*lane_lo +: 8];
    else                                    trk_byte = 8'hff;
  end

  logic [27:0] acc_seek, acc_spin;
  logic [7:0]  acc_blk;
  logic [27:0] acc_at, acc_mv;
  logic [31:0] elapsed;

  assign ch_busy   = (ch_state != C_IDLE);
  // Announced two ticks ahead: a START is in the store's hold pipeline for
  // two ticks before `ch_state` moves, and the pack side reads this through a
  // register of its own, so without the announcement a request landing in
  // those ticks would be accepted against a walk about to begin.  `store_q`
  // and `st_go` are the hold's two stages; register 3 is START.  A START
  // that starts no walk raises this for two ticks and drops it, which the
  // trace testbench's wait after every START absorbs inside the write's own
  // four ticks.
  assign ch_active = ch_busy || (store_q && which_q == 2'd3)
                             || (st_go && st_which == 2'd3);

  // `access_ns(from, to, block, blocks)` and `track_ns(from, to, block)`:
  // the heads' move, then `disk_unit::until` --- the wait for the addressed
  // block to come round, measured from the instant the seek ENDS --- and
  // then a sector a block, or a whole revolution for Read All and Write All.
  // `acc_spin` has been brought back inside a revolution by the state below
  // it, which is an add and at most four subtractions where the model has a
  // remainder.
  logic [31:0] acc_total, acc_total_r;
  // The latency: the wait for the addressed block to come round from where
  // the spindle stood when the seek ended, both differences and the compare
  // that chooses between them into registers, then the choice.
  logic [28:0] acc_d1, acc_d2, acc_lat_r;
  logic        acc_ge;
  assign acc_total   = 32'(acc_seek) + 32'(acc_lat_r) + 32'(acc_mv);
  // Registered in a state of its own before `elapsed` is taken off it: the
  // three additions, the compare and the subtraction in one tick were 5.3 ns
  // into `busy_ns` on the DDR=1 board, the first board to fit the drive at
  // all.  The tick it costs is counted by `elapsed` like every other tick of
  // the walk, so nothing about the expiry moves.
  //
  // **AND THE SUBTRACTION OF `elapsed` HAS A STATE OF ITS OWN TOO.**  Made
  // in the tick that loads `busy_ns`, the compare and the difference were
  // two carry chains in series into the counter's data pins:
  // `disk/elapsed_reg[2]/C -> disk/busy_ns_reg[3]/D`, eight logic levels
  // and 5.04 ns on the DDR=1 board at ef9dee9.  So `C_ACCDIFF` takes both
  // into registers and `C_ACCFIN` loads from them --- less the one tick that
  // `elapsed` has counted in between, which is the same arithmetic the
  // counter does for itself every tick.  Same rule as above: the tick is
  // the walk's, and the expiry does not move.
  logic [31:0] acc_left;   // `acc_total_r - elapsed`, as of C_ACCDIFF
  logic        acc_owed;   // and whether that was positive
  logic [27:0] acc_less;   // `acc_spin` less a revolution, as of C_ACCMOD
  logic        acc_over;   // and whether it was a revolution or more

  // The bus master's own four lines, registered: a master asserts good
  // address, write and data 80 ns before it asserts the request, and a
  // register is the cheapest way to promise that here.
  logic        ch_req_r, ch_write_r;
  logic [21:0] ch_addr_r;
  logic [31:0] ch_wdata_r;
  assign ch_req   = ch_req_r;
  assign ch_write = ch_write_r;
  assign ch_addr  = ch_addr_r;
  assign ch_wdata = ch_wdata_r;

  // The store's other port.  A read transfer reads it ahead of the ECC and
  // ahead of the bus; a write transfer writes it behind the bus.
  logic [12:0] chb_a;
  logic [31:0] chb_q, chb_d;
  logic        chb_we;
  // `ch_i` is the word within the PAGE and `ch_ra` the word within the
  // BLOCK, and which of the two addresses the store is the direction ---
  // except on a track, where both directions read or write the block by
  // `ch_ra` while `ch_i` walks the page on the bus.
  assign chb_a  = 13'(ch_slot) * 13'(BLOCK_WORDS)
                + 13'((ch_read || ch_track) ? ch_ra[7:0] : ch_i[7:0]);
  assign chb_we = ((ch_state == C_MOVE) && !ch_read && (ch_ph == 3'd2))
                || ps_wr;
  assign chb_d  = ch_track ? ps_w : blk_w;

  // **AND ITS READ IS TWO TICKS BEHIND THE ADDRESS.**  The store is six
  // block RAMs and the word comes out of a mux across them, 2.7 ns of the
  // tick before it reaches a register; `chb_q2` is that register.  Every
  // reader had a tick to spare already except the first word of a page's
  // move, which has a second settling tick now.
  logic [31:0] chb_q2;
  always_ff @(posedge clk) begin
    if (chb_we) blk_ram[chb_a] <= chb_d;
    chb_q  <= blk_ram[chb_a];
    chb_q2 <= chb_q;
  end

  // Which slot holds the block under the heads.  Twenty-four comparators, as
  // a board with a window on a pack has: the tag is the address and there is
  // no arithmetic between them.
  logic [27:0] want_tag, want_tag_q;
  logic [7:0]  want_blk;
  logic        slot_hit_c, slot_hit;
  logic [4:0]  slot_of_c, slot_of;
  // **A TRACK ASKS FOR A BLOCK THE HEADS ARE NOT ON.**  The walk's key is
  // where the heads are; Read All and Write All go round the whole track
  // from there without moving them, so their key is the sector the stream is
  // on: for a Read All the NEXT block, so that `ch_slot` can be latched at
  // `trk_step`, the tick a new sector begins; for the first sector and for a
  // Write All's parser the block the stream is on.
  //
  // **THE LOOKUP IS THREE REGISTERS DEEP, AND EVERY KEY IT IS ASKED ABOUT
  // HAS STOOD FOR LONGER THAN THAT.**  The key is an eight-way mux on the unit,
  // the twenty-four comparators are twenty-eight bits each, and the priority
  // encoder behind them is five bits wide: made in the tick that reads it,
  // that was seventeen logic levels from `ch_state` back into `ch_state`,
  // 20.1 ns, on the DDR=1 board at ef9dee9 --- where it had never been timed,
  // the whole disk having fallen into `rtl/cadr_machine.xdc`'s microcycle
  // set.  So the key is registered and the answer is registered off it.  A
  // Read All's next block has been the next block for a whole sector; the
  // walk's key is the heads' position, set at the START or at `C_NEXT`, and
  // `C_LOOK` comes after a command-list fetch --- the request goes out the
  // tick after, the answer is a tick behind that at the testbench's fastest,
  // so the decision is four ticks on at the earliest; the parser's key is
  // the chunk's block, set a chunk earlier.  The first sector's lookup at
  // `C_TLOOK` is the one place the key has just moved, and that state waits
  // the three ticks and says so.
  assign want_blk = (ch_state == C_TRD) ? trk_b_next
                  : (ch_track ? trk_b : u_blk[ch_unit]);
  assign want_tag = {u_cyl[ch_unit], u_head[ch_unit], want_blk};
  // Three, in fact: the key, the twenty-four compares, the encoder.  The
  // middle stage was eight levels and -1.3 ns on its own.
  logic [SLOTS-1:0] hit_q;
  always_comb begin
    slot_hit_c = 1'b0;
    slot_of_c  = 5'd0;
    for (int k = 0; k < int'(SLOTS); k++)
      if (hit_q[k]) begin
        slot_hit_c = 1'b1;
        slot_of_c  = 5'(k);
      end
  end
  always_ff @(posedge clk) begin
    want_tag_q <= want_tag;
    for (int k = 0; k < int'(SLOTS); k++)
      hit_q[k] <= s_valid[k] && (s_tag[k] == want_tag_q);
    slot_hit   <= slot_hit_c;
    slot_of    <= slot_of_c;
  end

  // The header a sector at this address should carry, under the mask.
  // `<31:28>` is the next-block address code and the two bits above the
  // cylinder, and it has no counterpart in the disk address register: on
  // DCHDCM the first of the 25LS2521's four compares puts the read byte on
  // both sides of itself, so a header differing there alone is not an error.
  // The registered key: `C_HDRC` is a walk state, where the key is the
  // heads' position and has stood since before `C_LOOK`.
  logic [27:0] hdr_want;
  assign hdr_want = want_tag_q;

  // **THE SLOT'S THREE WORDS, READ INTO REGISTERS.**  `s_header`, `s_hck`
  // and `s_dck` are distributed RAM twenty-four deep, and read by `ch_slot`
  // into a twenty-eight-bit compare or the code's byte step in the same tick
  // they were ten logic levels into `e_hdrcmp` and `ch_state`.  `ch_slot` is
  // set at `C_LOOK` and at `trk_step`, and the first reader of each is a
  // tick or more behind: `C_HDRC` waits one, and the track's header bytes
  // come sixty-one preamble bytes after the sector begins.
  logic [31:0] hdr_q, hck_q, dck_q;
  always_ff @(posedge clk) begin
    hdr_q <= s_header[ch_slot];
    hck_q <= s_hck[ch_slot];
    dck_q <= s_dck[ch_slot];
  end

  // Where the command list is now: only `<15:0>` counts.
  logic [31:0] clp_now;
  assign clp_now = {clp[31:16], clp[15:0] + ch_n};

  // The burst `Ecc::trap` is looking at, once the high twenty-one stages are
  // clear: the eleven the board's `-ECC=ZERO` does not read, brought down to
  // bit 0, and how wide it is.
  logic [3:0] burst_low, burst_high;
  always_comb begin
    burst_low  = 4'd11;
    burst_high = 4'd0;
    for (int k = 10; k >= 0; k--) if (ecc_r[k]) burst_low = 4'(k);
    for (int k = 0; k <= 10; k++) if (ecc_r[k]) burst_high = 4'(k);
  end
  logic        ch_i_last, ecc_zero_q, hck_eq_q, hdr_eq_q, ecc_hi_zero_q;
  logic [31:0] ecc_next;
  assign ecc_next = ecc_bit(ecc_r, 1'b0, 1'b1);
  logic [3:0]  burst_width, burst_width_q;
  logic [10:0] burst_pattern, burst_pattern_q;
  assign burst_width   = burst_high - burst_low;
  assign burst_pattern = ecc_r[10:0] >> burst_low;

  // The block after this one: "0 following block on same track, 1 block 0 on
  // next track (next head), 2 block 0 on head 0 of next cylinder".
  //
  // Registered, because the chain of three carries and two compares off an
  // eight-way mux on the unit reached the enable of every head-position
  // register fourteen logic levels deep at `C_NEXT`.  The heads move at the
  // START and at `C_NEXT` itself, and the next `C_NEXT` is a page's walk
  // away, so a copy one tick behind is the same value where it is read.
  // ... and the position itself comes through a register first, the unit's
  // mux being three levels on its own.  Two ticks behind, then, against a
  // page's walk.
  logic [11:0] hd_cyl_q, nb_c_c, nb_c;
  logic [7:0]  hd_head_q, hd_blk_q, nb_h_c, nb_b_c, nb_h, nb_b;
  logic        nb_off_pack;
  always_comb begin
    nb_c_c = hd_cyl_q;
    nb_h_c = hd_head_q;
    nb_b_c = hd_blk_q + 8'd1;
    if (nb_b_c >= 8'(BPT)) begin
      nb_b_c = 8'd0;
      nb_h_c = hd_head_q + 8'd1;
      if (nb_h_c >= 8'(HEADS)) begin
        nb_h_c = 8'd0;
        nb_c_c = hd_cyl_q + 12'd1;
      end
    end
  end
  always_ff @(posedge clk) begin
    hd_cyl_q    <= u_cyl[ch_unit];
    hd_head_q   <= u_head[ch_unit];
    hd_blk_q    <= u_blk[ch_unit];
    nb_c        <= nb_c_c;
    nb_h        <= nb_h_c;
    nb_b        <= nb_b_c;
    nb_off_pack <= (nb_c_c >= 12'(CYLINDERS));
  end

  // The held decode.  One process, because it is this slave's own state.
  always_ff @(posedge clk) begin
    if (rst_q) begin
      mine  <= 1'b0;
      which <= 2'd0;
    end else begin
      mine  <= mine_c;
      which <= which_c;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_q) begin
      // Power-on.  `-XINIT` clears the command register --- the 74LS175 at
      // DCCMD 0C21 and the 74LS273 at 0C10, pin 1 of each --- and stops the
      // channel; the disk address counters, the command list pointer and the
      // CCW latches have no pin on it, so on the board those come up
      // undefined and zero is this fabric's convention for them, as
      // `LVMO_AT_POWER_ON` is elsewhere.
      cmd         <= 32'd0;
      clp         <= 32'd0;
      da          <= 32'd0;
      lma         <= 32'd0;
      ecc_reg     <= 32'd0;
      taken       <= 1'b0;
      store_q     <= 1'b0;
      wdata_q     <= 32'd0;
      which_q     <= 2'd0;
      st_go       <= 1'b0;
      st_wdata    <= 32'd0;
      st_which    <= 2'd0;
      st_xfer     <= 1'b0;
      st_all      <= 1'b0;
      st_fault    <= 1'b0;
      st_rev      <= 1'b0;
      st_seek     <= 1'b0;
      st_atease   <= 1'b0;
      st_hang     <= 1'b0;
      st_code     <= 4'd0;
      st_recal    <= 1'b0;
      st_fclr     <= 1'b0;
      st_seek_here <= 1'b0;
      st_seek_off <= 1'b0;
      spin_q      <= 24'd0;
      spin_q2     <= 24'd0;
      spin_q3     <= 24'd0;
      wrap_q      <= 1'b0;
      step_q      <= 1'b0;
      busy_ns     <= 32'd0;
      hanging     <= 1'b0;
      timeout     <= 1'b0;
      e_rcdiff    <= 1'b0;
      e_ccwcyc    <= 1'b0;
      e_nxm       <= 1'b0;
      e_overrun   <= 1'b0;
      e_hdrcmp    <= 1'b0;
      e_hdrecc    <= 1'b0;
      e_ecchard   <= 1'b0;
      e_eccsoft   <= 1'b0;
      ch_state    <= C_IDLE;
      ch_req_r    <= 1'b0;
      ch_write_r  <= 1'b0;
      ch_addr_r   <= 22'd0;
      ch_wdata_r  <= 32'd0;
      ch_n        <= 16'd0;
      ch_page     <= 14'd0;
      ch_more     <= 1'b0;
      ch_slot     <= 5'd0;
      ch_unit     <= 3'd0;
      ch_i        <= 9'd0;
      ch_ra       <= 9'd0;
      ch_ph       <= 3'd0;
      ecc_r       <= 32'd0;
      blk_w       <= 32'd0;
      ch_read     <= 1'b0;
      ch_cmp      <= 1'b0;
      ch_moved    <= 8'd0;
      trap_n      <= 17'd0;
      trap_step   <= 14'd0;
      ch_setda    <= 1'b0;
      ch_track    <= 1'b0;
      trk_b       <= 8'd0;
      trk_p       <= 11'd0;
      trk_gap     <= 1'b0;
      trk_g       <= 9'd0;
      trk_lay     <= 1'b0;
      ps_st       <= P_SYNC1;
      ps_ones     <= 7'd0;
      ps_sh       <= 31'd0;
      ps_n        <= 14'd0;
      ps_wc       <= 9'd0;
      ps_bit      <= 5'd0;
      ps_hdr      <= 32'd0;
      ps_hck      <= 32'd0;
      ps_dck      <= 32'd0;
      ps_w        <= 32'd0;
      ps_wr       <= 1'b0;
      trk_meta_we <= 1'b0;
      acc_seek    <= 28'd0;
      acc_spin    <= 28'd0;
      acc_blk     <= 8'd0;
      acc_at      <= 28'd0;
      acc_mv      <= 28'd0;
      acc_total_r <= 32'd0;
      acc_left    <= 32'd0;
      acc_owed    <= 1'b0;
      acc_less    <= 28'd0;
      acc_over    <= 1'b0;
      acc_lat_r   <= 29'd0;
      acc_d1      <= 29'd0;
      acc_d2      <= 29'd0;
      acc_ge      <= 1'b0;
      burst_width_q   <= 4'd0;
      burst_pattern_q <= 11'd0;
      ch_i_last     <= 1'b0;
      ecc_zero_q    <= 1'b1;
      hck_eq_q      <= 1'b0;
      hdr_eq_q      <= 1'b0;
      ecc_hi_zero_q <= 1'b0;
      trk_p_last_q  <= 1'b0;
      trk_g_last_q  <= 1'b0;
      ps_bit_last_q <= 1'b0;
      ps_wc_last_q  <= 1'b0;
      trk_byte_q    <= 8'd0;
      elapsed     <= 32'd0;
      ch_dck_we   <= 1'b0;
      ch_dck_slot <= 5'd0;
      ch_dck_val  <= 32'd0;
      store_miss  <= 1'b0;
      // Ten, not zero: five for the reset held a tick here (see `rst_q`),
      // five for the read word held a tick on the way out (`READ_HOLD_NS`).
      spin        <= 24'd10;
      into        <= 20'd10;
      region      <= 5'd0;
      seek_ns_r   <= 28'd0;
      seek_held_r <= 28'd0;
      settle_r    <= 28'd0;
      settle_held_r <= 28'd0;
      cyl_n_r     <= 12'd0;
      cyl_now_r   <= 12'd0;
      cyl_to_r    <= 12'd0;
      head_now_r  <= 8'd0;
      blk_now_r   <= 8'd0;
      gt_r        <= 1'b0;
      is_recal_r  <= 1'b0;
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
      wrap_q <= !wrapping && (spin >= REVOLUTION_NS - 24'd10);
      step_q <= !wrapping && !stepping && (into >= SECTOR_NS - 20'd10)
             && (region < 5'(BPT));
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
      // Zero stays zero, so the countdown runs whenever the unit is armed
      // and the enable is the arm alone rather than a 28-bit zero test.
      for (int u = 0; u < 8; u++) begin
        if (u_att_armed[u])
          u_att_ns[u] <= (u_att_ns[u] > 28'd5) ? u_att_ns[u] - 28'd5 : 28'd0;
      end

      // --- the flags the walk reads instead of the compares they stand for:
      // each exact by construction, because what it compares has stood, or
      // will have moved by exactly one step, when it is read
      ch_i_last     <= (ch_i == 9'(BLOCK_WORDS-1));
      ecc_zero_q    <= (ecc_r == 32'd0);
      hck_eq_q      <= (ecc_r == hck_q);
      hdr_eq_q      <= (hdr_q[27:0] == hdr_want);
      // The scan shifts the register every tick, so this is the test on the
      // value about to land: `ecc_bit` with nothing coming in and feedback
      // on, which is what both scanning states shift by.
      ecc_hi_zero_q <= (ecc_next[31:11] == 21'd0);
      // The parser's word end, likewise made on the bit about to be taken:
      // `ps_bit` counts only while a word is going through, and is put back
      // to zero before the next.  And the chunk's end, whose counter moves
      // once a word.
      ps_bit_last_q <= ((ch_state == C_TWR) && (ch_ph >= 3'd2)) ? (ps_bit == 5'd30) : 1'b0;
      ps_wc_last_q  <= (ps_wc == 9'(F_SECTOR_W - 1));
      trk_p_last_q  <= (trk_adv && !trk_gap) ? (trk_p == 11'(F_SECTOR-2))
                                             : (trk_p == 11'(F_SECTOR-1));
      trk_g_last_q  <= (trk_adv && trk_gap)  ? (trk_g == 9'(F_LEFTOVER-2))
                                             : (trk_g == 9'(F_LEFTOVER-1));
      trk_byte_q    <= trk_byte;

      // --- how long the next seek would take, from where the heads are now
      cyl_now_r   <= cyl_now;
      cyl_to_r    <= cyl_to;
      head_now_r  <= u_head[sel_unit];
      blk_now_r   <= u_blk[sel_unit];
      gt_r        <= (cyl_now > cyl_to);
      is_recal_r  <= is_recal;
      cyl_n_r     <= cyl_n;
      settle_r      <= (cyl_n == 12'd0) ? 28'd0 : SEEK_SETTLE_NS;
      settle_held_r <= (cyl_n == 12'd0) ? 28'd0 : SEEK_SETTLE_NS - 28'(HOLD_NS);
      seek_ns_r   <= seek_ns_c;
      seek_held_r <= seek_held_c;
      // --- the spindle two ticks ago, and the bus as it stands, for a held
      // store; and the store's decode, one flag a decision, from registers
      spin_q  <= spin;
      spin_q2 <= spin_q;
      spin_q3 <= spin_q2;
      wdata_q <= wdata;
      which_q <= which;
      store_q <= store_now;
      st_go       <= store_q;
      st_wdata    <= wdata_q;
      st_which    <= which_q;
      st_xfer     <= start_c && is_transfer && present && !ro_fault;
      st_all      <= start_c && is_all && present && !ro_fault;
      st_fault    <= start_c && (is_transfer || is_all) && present && ro_fault;
      st_rev      <= start_c && is_reversed;
      st_seek     <= start_c && is_seek && present;
      st_atease   <= start_c && is_atease && present;
      // The three the sequencer never comes back from, and the two that do
      // not without a drive to answer them.
      st_hang     <= start_c && (is_hangs || ((is_seek || code == 4'o06) && !present));
      st_code     <= code;
      st_recal    <= cmd[9];
      st_fclr     <= cmd[8];
      st_seek_here <= seek_here;
      st_seek_off <= seek_off_pack;

      // --- the channel, a word at a time --------------------------------
      ch_dck_we   <= 1'b0;
      ps_wr       <= 1'b0;
      trk_meta_we <= 1'b0;
      if (ps_wr)  ch_ra <= ch_ra + 9'd1;
      if (ch_busy) elapsed <= elapsed + 32'd5;

      // --- the track goes past the head, a byte at a time -----------------
      //
      // `track_bytes`: seventeen sectors from the block the disk address
      // names, and the LEFTOVER after the one whose block number is the last
      // on the track --- wherever in the sequence that falls, which is why
      // the gap is triggered on `trk_b` and not on the count.  A sector's
      // data words come out of the store one tick ahead of the byte that
      // needs them: `ch_ra` steps on the last lane of each, so `chb_q` holds
      // the next word by the time the first lane of it is asked for, and it
      // stands at zero through the sixty-one preamble bytes before the
      // first.
      if (trk_adv) begin
        if (trk_gap) begin
          if (trk_end_gap) begin
            trk_gap <= 1'b0;
            trk_g   <= 9'd0;
          end else begin
            trk_g <= trk_g + 9'd1;
          end
        end else if (trk_p_last_q) begin
          trk_p <= 11'd0;
          if (trk_b == 8'(BPT-1)) begin
            trk_gap <= 1'b1;
            trk_g   <= 9'd0;
          end
        end else begin
          trk_p <= trk_p + 11'd1;
          if ((trk_p >= 11'(F_DATA)) && (trk_p < 11'(F_DECC))
              && (lane_lo == 2'd3))
            ch_ra <= ch_ra + 9'd1;
        end
        if (trk_step) begin
          trk_b   <= trk_b_next;
          ch_slot <= slot_of;
          ch_ra   <= 9'd0;
          if (!slot_hit) store_miss <= 1'b1;
        end
      end
      unique case (ch_state)
        C_IDLE: ;
        // The command list word, and `<21>` up for the length of its fetch.
        // A fetch main memory does not answer leaves `<21>` up, which is
        // muir's own structure: `ccw_cycle` is set before the fetch and
        // cleared after one that worked.
        C_CCW: begin
          // Deferred while the pack side is moving a block: see `store_busy`
          // at the ports.  `elapsed` goes on counting, so the wait comes off
          // the access time.
          if (!ch_req_r && !store_busy) begin
            ch_req_r   <= 1'b1;
            ch_write_r <= 1'b0;
            ch_addr_r  <= clp_now[21:0];
            lma        <= clp_now;
            e_ccwcyc   <= 1'b1;
          end else if (ch_done) begin
            ch_req_r <= 1'b0;
            if (ch_nxm) begin
              e_nxm    <= 1'b1;
              ch_state <= C_ACCMUL;
            end else begin
              e_ccwcyc <= 1'b0;
              // "<23:8> Main memory address of a page.  <0> More flag."
              // DCCCW latches `XBI<21:8>` and clocks `XBI0`, so the two bits
              // above the page go nowhere: the address is the 22 bits the
              // Xbus has.
              ch_page  <= ch_rdata[21:8];
              ch_more  <= ch_rdata[0];
              // `each_ccw` and `command_list` walk the same list; the track
              // has no block to look up and no header to compare, so it
              // goes straight at the page.  `ch_ra` is the TRACK's position
              // and is not touched here.
              if (ch_track) begin
                ch_i     <= 9'd0;
                ch_ph    <= 3'd0;
                ch_state <= ch_read ? C_TRD : C_TWR;
              end else begin
                ch_state <= C_LOOK;
              end
            end
          end
        end
        C_LOOK: begin
          ch_i  <= 9'd0;
          ch_ra <= 9'd0;
          ch_ph <= 3'd0;
          if (!slot_hit) begin
            store_miss <= 1'b1;
            ch_state   <= C_ACCMUL;
          end else begin
            ch_slot  <= slot_of;
            ch_state <= C_HDRC;
          end
        end
        // One tick for `hdr_q` to take the slot `C_LOOK` chose, one for
        // `hdr_eq_q` to compare it, then the decision; `ch_ph` is zero out
        // of `C_LOOK`.
        C_HDRC: begin
          if (ch_ph != 3'd2) begin
            ch_ph <= ch_ph + 3'd1;
          end else if (!hdr_eq_q) begin
            e_hdrcmp <= 1'b1;
            ch_ph    <= 3'd0;
            ch_state <= C_ACCMUL;
          end else begin
            ecc_r    <= 32'd0;
            ch_ph    <= 3'd0;
            ch_state <= C_HDRE;
          end
        end
        // The header's own checkword, a byte a tick.  `Ecc::checkword` and
        // `Ecc::raw` are the same thirty-two bits, so what the code leaves
        // after the four header bytes IS the checkword to compare against.
        C_HDRE: begin
          ecc_r <= ecc_byte(ecc_r, hdr_q[8*ch_ph[1:0] +: 8]);
          if (ch_ph == 3'd3) begin
            ch_ph    <= 3'd0;
            ch_state <= C_HDRCK;
          end else begin
            ch_ph <= ch_ph + 3'd1;
          end
        end
        // The compare is a register, `hck_eq_q`, and this waits the tick it
        // takes.  `ch_ph` is zero out of `C_HDRE`.
        C_HDRCK: begin
          if (ch_ph == 3'd0) begin
            ch_ph <= 3'd1;
          end else if (!hck_eq_q) begin
            e_hdrecc <= 1'b1;
            ch_ph    <= 3'd0;
            ch_state <= C_ACCMUL;
          end else begin
            ecc_r    <= 32'd0;
            ch_i     <= 9'd0;
            ch_ra    <= 9'd0;
            ch_ph    <= 3'd0;
            ch_state <= ch_read ? C_DATA : C_MOVE;
          end
        end
        // The data field and the checkword written after it, read back
        // through the code as the board's shift register reads them.  Five
        // ticks a word: one to take the store's word and ask for the next,
        // four to run its bytes through.
        //
        // **THE WORD IS SHIFTED DOWN A BYTE AS EACH GOES THROUGH**, so the
        // code always reads `blk_w[7:0]` and no lane is selected: the mux on
        // the phase was two of five logic levels into the register.  The
        // same in `C_DCK` and on the write side of `C_MOVE`.
        C_DATA: begin
          if (ch_ph == 3'd0) begin
            blk_w <= chb_q2;
            ch_ra <= ch_ra + 9'd1;
            ch_ph <= 3'd1;
          end else begin
            ecc_r <= ecc_byte(ecc_r, blk_w[7:0]);
            blk_w <= {8'd0, blk_w[31:8]};
            if (ch_ph == 3'd4) begin
              ch_ph <= 3'd0;
              if (ch_i_last) begin
                blk_w    <= dck_q;
                ch_state <= C_DCK;
              end else begin
                ch_i <= ch_i + 9'd1;
              end
            end else begin
              ch_ph <= ch_ph + 3'd1;
            end
          end
        end
        C_DCK: begin
          ecc_r <= ecc_byte(ecc_r, blk_w[7:0]);
          blk_w <= {8'd0, blk_w[31:8]};
          if (ch_ph == 3'd3) begin
            ch_ph    <= 3'd0;
            ch_state <= C_ECCQ;
          end else begin
            ch_ph <= ch_ph + 3'd1;
          end
        end
        // "A checkword that checks leaves the register at zero and there is
        // nothing to report."
        //
        // The zero test is a register, `ecc_zero_q`, and this waits the tick
        // it takes: thirty-two bits into `ch_state` and the register's own
        // enable was six levels.  `ch_ph` is zero out of `C_DCK`.
        C_ECCQ: begin
          ch_i  <= 9'd0;
          ch_ra <= 9'd0;
          if (ch_ph == 3'd0) begin
            ch_ph <= 3'd1;
          end else begin
            ch_ph <= 3'd0;
            if (ecc_zero_q) begin
              ch_state <= C_MOVE;
            end else begin
              trap_n   <= 17'(ECC_SPIN);
              ch_state <= C_TSPIN;
            end
          end
        end
        // `newdsk.31` at 070: "Run the ECC register the right number of
        // times to make the cyclic code repeat, then run it through the data
        // field again, looking for zero."  34,753 shifts and then up to
        // 8,193 more, one a tick --- 214.7 us at worst, which
        // `docs/disk-controller.md` measured before this was built and which
        // is 22% of a block's own time on the pack.
        C_TSPIN: begin
          ecc_r <= ecc_bit(ecc_r, 1'b0, 1'b1);
          if (trap_n == 17'd1) begin
            trap_step <= 14'd0;
            ch_state  <= C_TSCAN;
          end else begin
            trap_n <= trap_n - 17'd1;
          end
        end
        C_TSCAN: begin
          // "Zero" is the board's `-ECC=ZERO`, the S133 at 0C27, which reads
          // ECC11 to ECC31 and not the ten below them: what is left is the
          // burst, and eleven bits is the span that makes a soft error soft.
          if (ecc_hi_zero_q) begin
            ch_state <= C_TSOFT;
          end else if (trap_step == 14'(ECC_BITS)) begin
            e_ecchard <= 1'b1;
            ch_state  <= C_ACCMUL;
          end else begin
            ecc_r     <= ecc_bit(ecc_r, 1'b0, 1'b1);
            trap_step <= trap_step + 14'd1;
          end
        end
        // The burst, worked out from a register that has stopped shifting:
        // two priority encoders, a subtraction and a compare against the
        // step were ten logic levels into `e_eccsoft` and `ecc_reg` when made
        // in the scan's own tick.  Two ticks the walk pays and the result
        // does not move; the trap's instant is compared nowhere.
        C_TSOFT: begin
          burst_width_q   <= burst_width;
          burst_pattern_q <= burst_pattern;
          ch_state        <= C_TSOFT2;
        end
        C_TSOFT2: begin
          if (trap_step >= 14'(burst_width_q)) begin
            e_eccsoft <= 1'b1;
            // "Note that the bit position is off by 1; the first bit in
            // the block is bit 1."
            ecc_reg   <= {5'd0, burst_pattern_q,
                          16'(trap_step) - 16'(burst_width_q) + 16'd1};
          end else begin
            e_ecchard <= 1'b1;
          end
          ch_state <= C_ACCMUL;
        end
        // The page.  A read puts the block's words into memory, a
        // read-compare only looks at them --- "This error does not stop the
        // transfer" --- and a write takes them out of memory into the store,
        // running a fresh checkword over them as it goes.
        //
        // **THE PAGE'S NXM IS THE FIRST WORD'S OWN BUS CYCLE.**  muir asks
        // `page + BLOCK_WORDS > main.len()` before it moves anything, and a
        // page is 256-aligned while a board is 65,536 words, so a page is
        // wholly inside main memory or wholly outside it: the first cycle
        // decides, and nothing has moved by then.
        C_MOVE: begin
          if (ch_read) begin
            unique case (ch_ph)
              3'd0: ch_ph <= 3'd1;              // the store's read settles...
              3'd1: ch_ph <= 3'd2;              // ...and crosses its register
              3'd2: begin
                blk_w <= chb_q2;
                ch_ra <= ch_ra + 9'd1;
                ch_ph <= 3'd3;
              end
              3'd3: begin
                ch_req_r   <= 1'b1;
                ch_write_r <= !ch_cmp;
                ch_addr_r  <= {ch_page, ch_i[7:0]};
                ch_wdata_r <= blk_w;
                ch_ph      <= 3'd4;
              end
              default: if (ch_done) begin
                ch_req_r <= 1'b0;
                if (ch_nxm) begin
                  e_nxm    <= 1'b1;
                  ch_state <= C_ACCMUL;
                end else begin
                  if (ch_cmp && ch_rdata != blk_w) e_rcdiff <= 1'b1;
                  if (ch_i_last) begin
                    ch_state <= C_NEXT;
                  end else begin
                    // The next word was asked for at the take above and has
                    // had the request's ticks to arrive.
                    ch_i  <= ch_i + 9'd1;
                    ch_ph <= 3'd2;
                  end
                end
              end
            endcase
          end else begin
            unique case (ch_ph)
              3'd0: begin
                ch_req_r   <= 1'b1;
                ch_write_r <= 1'b0;
                ch_addr_r  <= {ch_page, ch_i[7:0]};
                ch_ph      <= 3'd1;
              end
              3'd1: if (ch_done) begin
                ch_req_r <= 1'b0;
                if (ch_nxm) begin
                  e_nxm    <= 1'b1;
                  ch_state <= C_ACCMUL;
                end else begin
                  blk_w <= ch_rdata;
                  ch_ph <= 3'd2;
                end
              end
              // The word goes into the store whole at phase 2 --- `chb_d`
              // reads `blk_w` before this edge shifts it --- and through the
              // code a byte a tick from there.
              3'd2: begin ecc_r <= ecc_byte(ecc_r, blk_w[7:0]); blk_w <= {8'd0, blk_w[31:8]}; ch_ph <= 3'd3; end
              3'd3: begin ecc_r <= ecc_byte(ecc_r, blk_w[7:0]); blk_w <= {8'd0, blk_w[31:8]}; ch_ph <= 3'd4; end
              3'd4: begin ecc_r <= ecc_byte(ecc_r, blk_w[7:0]); blk_w <= {8'd0, blk_w[31:8]}; ch_ph <= 3'd5; end
              default: begin
                ecc_r <= ecc_byte(ecc_r, blk_w[7:0]);
                if (ch_i_last) begin
                  ch_state <= C_WEND;
                end else begin
                  ch_i  <= ch_i + 9'd1;
                  ch_ph <= 3'd0;
                end
              end
            endcase
          end
        end
        // "The board writes a fresh checkword after every data field it
        // writes", so a bad one a Write All left is gone.
        C_WEND: begin
          ch_dck_we   <= 1'b1;
          ch_dck_slot <= ch_slot;
          ch_dck_val  <= ecc_r;
          ch_state    <= C_NEXT;
        end
        // "the last memory reference made by the disk control", which for a
        // page is its last word and not each of its 256.
        C_NEXT: begin
          lma      <= {10'd0, ch_page, 8'hFF};
          ch_moved <= ch_moved + 8'd1;
          if (!ch_more) begin
            ch_state <= C_ACCMUL;
          end else if (ch_track) begin
            // `each_ccw` has no block to advance to, "the track being one
            // stream", so the heads stand and the next CCW is fetched.
            ch_n     <= ch_n + 16'd1;
            ch_state <= C_CCW;
          end else if (nb_off_pack) begin
            // "Header ECC Error also happens if an attempt is made to
            // continue a read or write operation past the end of the disk."
            // `next_block` is `seek` underneath, so the drive raises its own
            // seek error as well.
            u_seek_err[ch_unit] <= 1'b1;
            e_hdrecc            <= 1'b1;
            ch_state            <= C_ACCMUL;
          end else begin
            u_cyl[ch_unit]  <= nb_c;
            u_head[ch_unit] <= nb_h;
            u_blk[ch_unit]  <= nb_b;
            ch_n            <= ch_n + 16'd1;
            ch_state        <= C_CCW;
          end
        end
        // The slot the track's first sector comes out of, and the only one
        // Read All has to look up before it starts: the rest are latched at
        // `trk_step` as the stream crosses into them.
        //
        // The key --- the heads, moved by the START that landed a tick ago,
        // and `trk_b` with them --- is three registers from the answer, so
        // this waits three ticks before it looks.  `ch_ph` is zero out of
        // the START.
        C_TLOOK: begin
          ch_ra <= 9'd0;
          if (ch_ph != 3'd3) begin
            ch_ph <= ch_ph + 3'd1;
          end else begin
            ch_ph <= 3'd0;
            if (!slot_hit && ch_read) begin
              store_miss <= 1'b1;
              ch_state   <= C_ACCMUL;
            end else begin
              if (ch_read) ch_slot <= slot_of;
              ch_state <= C_CCW;
            end
          end
        end

        // Read All.  Four ticks take four bytes out of the track and the
        // fifth puts the word on the bus, "the track's bytes into the pages
        // the command list names, four bytes to a word, low-order byte
        // first".
        //
        // **THE NXM IS THE FIRST WORD'S OWN BUS CYCLE**, as it is for a
        // block: muir asks `page + BLOCK_WORDS > main.len()` before it takes
        // a byte, so its stream position is untouched by a page that is not
        // there, and this one has taken four bytes by the time the cycle
        // answers.  Nothing can tell them apart, because the walk stops --- a
        // page that is not there is the end of the transfer either way.
        //
        // **THE BYTE IS TAKEN OUT OF A REGISTER, A TICK AFTER IT WAS UNDER
        // THE HEAD.**  `trk_byte` is a ten-way select on where the stream is
        // and then a lane of one of four words, and straight into the word
        // being assembled it was seven logic levels, -0.46 ns on the board
        // without the memory.  `trk_byte_q` takes it every tick; the four
        // ticks that advance the stream are the same four, and the assembly
        // follows them one behind, so the word is on the bus a tick later
        // than it was and the same bytes are in it.
        C_TRD: begin
          unique case (ch_ph)
            3'd0: ch_ph <= 3'd1;   // the first byte into `trk_byte_q`
            3'd1, 3'd2, 3'd3, 3'd4: begin
              blk_w[8*trd_lane +: 8] <= trk_byte_q;
              ch_ph <= ch_ph + 3'd1;
            end
            3'd5: begin
              ch_req_r   <= 1'b1;
              ch_write_r <= 1'b1;
              ch_addr_r  <= {ch_page, ch_i[7:0]};
              ch_wdata_r <= blk_w;
              ch_ph      <= 3'd6;
            end
            default: if (ch_done) begin
              ch_req_r <= 1'b0;
              if (ch_nxm) begin
                e_nxm    <= 1'b1;
                ch_state <= C_ACCMUL;
              end else if (ch_i_last) begin
                ch_state <= C_NEXT;
              end else begin
                ch_i  <= ch_i + 9'd1;
                ch_ph <= 3'd0;
              end
            end
          endcase
        end

        // Write All.  A word off the bus, then its thirty-two bits into the
        // parser one a tick, low-order bit first --- which is the order
        // `to_le_bytes` and `b >> k & 1` put them in, so a word IS its bits
        // from 0 to 31 and no byte lane appears here at all.
        C_TWR: begin
          unique case (ch_ph)
            3'd0: begin
              ch_req_r   <= 1'b1;
              ch_write_r <= 1'b0;
              ch_addr_r  <= {ch_page, ch_i[7:0]};
              ch_ph      <= 3'd1;
            end
            3'd1: if (ch_done) begin
              ch_req_r <= 1'b0;
              if (ch_nxm) begin
                e_nxm    <= 1'b1;
                ch_state <= C_ACCMUL;
              end else begin
                blk_w  <= ch_rdata;
                ps_bit <= 5'd0;
                ch_ph  <= 3'd2;
              end
            end
            default: begin
              // ---- one bit through `parse_sector` ------------------------
              blk_w <= {1'b0, blk_w[31:1]};
              if (trk_lay) begin
                unique case (ps_st)
                  // `after_sync`, and the ones counter is what says a run is
                  // a preamble and not a byte that happens to have ones in
                  // it.  It holds at F_ONES rather than counting on, because
                  // a preamble is 488 of them and eleven bits would not hold
                  // that.
                  P_SYNC1, P_SYNC2: begin
                    if (ps_bitv) begin
                      if (ps_ones != 7'(F_ONES)) ps_ones <= ps_ones + 7'd1;
                    end else if (ps_ones >= 7'(F_ONES)) begin
                      ps_n <= 14'd0;
                      if (ps_st == P_SYNC1) begin
                        ps_st <= P_HDR;
                      end else if (ps_fits) begin
                        // `take_bits` fits: the slot is looked up HERE and
                        // not earlier, so a chunk that will not parse never
                        // touches the store.
                        ps_st   <= P_PAD_;
                        ch_ra   <= 9'd0;
                        ch_slot <= slot_of;
                        if (!slot_hit) begin
                          store_miss <= 1'b1;
                          trk_lay    <= 1'b0;
                        end
                      end else begin
                        // The data and its checkword do not fit in what is
                        // left of the chunk: `None`, and the track stops.
                        trk_lay <= 1'b0;
                      end
                    end else begin
                      ps_ones <= 7'd0;
                    end
                  end
                  P_HDR, P_HCK, P_DCK: begin
                    ps_sh <= {ps_bitv, ps_sh[30:1]};
                    if (ps_n == 14'd31) begin
                      ps_n <= 14'd0;
                      unique case (ps_st)
                        P_HDR: begin
                          ps_hdr <= {ps_bitv, ps_sh};
                          ps_st  <= P_HCK;
                        end
                        P_HCK: begin
                          ps_hck  <= {ps_bitv, ps_sh};
                          ps_ones <= 7'd0;
                          ps_st   <= P_SYNC2;
                        end
                        default: begin
                          ps_dck      <= {ps_bitv, ps_sh};
                          trk_meta_we <= 1'b1;
                          ps_st       <= P_DONE;
                        end
                      endcase
                    end else begin
                      ps_n <= ps_n + 14'd1;
                    end
                  end
                  // "PAD - a byte containing octal 377, which is here to fix
                  // a bug in the logic for read-compare. (Ugh)"  Skipped, as
                  // `take_bits(bits, at + 8, ...)` skips it.
                  P_PAD_: begin
                    if (ps_n == 14'd7) begin
                      ps_n  <= 14'd0;
                      ps_st <= P_DATA_;
                    end else begin
                      ps_n <= ps_n + 14'd1;
                    end
                  end
                  P_DATA_: begin
                    ps_sh <= {ps_bitv, ps_sh[30:1]};
                    if (ps_n[4:0] == 5'd31) begin
                      ps_w  <= {ps_bitv, ps_sh};
                      ps_wr <= 1'b1;
                    end
                    if (ps_n == 14'(BLOCK_WORDS*32 - 1)) begin
                      ps_n  <= 14'd0;
                      ps_st <= P_DCK;
                    end else begin
                      ps_n <= ps_n + 14'd1;
                    end
                  end
                  default: ;   // P_DONE: the rest of the chunk is gap
                endcase
              end
              // ---- the chunk and the page --------------------------------
              if (ps_bit_last_q) begin
                if (ps_wc_last_q) begin
                  // `while at + format::SECTOR <= bytes.len()`, one stride
                  // done.  A chunk that did not reach the end of its own
                  // parse is `None` and stops the laying; the walk goes on.
                  //
                  // **THE PARSE CAN END ON THE CHUNK'S LAST BIT**, and then
                  // `ps_st` is still `P_DCK` at this point --- it goes to
                  // `P_DONE` at this same edge.  That happens when the data's
                  // sync is at bit 1,080 exactly, which is 352 bits later
                  // than this format puts it, so nothing on a well-formed
                  // pack reaches it; `tb/cadr_disk_tb.cpp` builds a chunk
                  // that does, and the one a bit later that does not.
                  if (!(ps_st == P_DONE
                        || (ps_st == P_DCK && ps_n == 14'd31)))
                    trk_lay <= 1'b0;
                  ps_wc   <= 9'd0;
                  ps_st   <= P_SYNC1;
                  ps_ones <= 7'd0;
                  ps_n    <= 14'd0;
                  trk_b   <= trk_b_next;
                end else begin
                  ps_wc <= ps_wc + 9'd1;
                end
                if (ch_i_last) begin
                  ch_state <= C_NEXT;
                end else begin
                  ch_i  <= ch_i + 9'd1;
                  ch_ph <= 3'd0;
                end
              end else begin
                ps_bit <= ps_bit + 5'd1;
              end
            end
          endcase
        end

        C_ACCMUL: begin
          acc_at   <= 28'(acc_blk) * 28'(SECTOR_NS);
          acc_mv   <= ch_track ? 28'(REVOLUTION_NS)
                               : 28'(ch_moved) * 28'(SECTOR_NS);
          acc_spin <= acc_spin + acc_seek;
          ch_state <= C_ACCMOD;
        end
        // Each turn of the remainder is two ticks --- the compare and the
        // difference into registers, then the choice --- so that neither
        // stands in front of the other on `acc_spin`'s data pins.  At most
        // four turns; every tick of them is the walk's.
        C_ACCMOD: begin
          acc_over  <= (acc_spin >= 28'(REVOLUTION_NS));
          acc_less  <= acc_spin - 28'(REVOLUTION_NS);
          ch_state  <= C_ACCMOD2;
        end
        C_ACCMOD2: begin
          if (acc_over) begin
            acc_spin <= acc_less;
            ch_state <= C_ACCMOD;
          end else begin
            ch_state <= C_ACCSUM;
          end
        end
        // The latency --- a compare and two differences, then the choice,
        // each into a register --- and the three-way sum off that register
        // a tick later: together they were sixteen logic levels and 5.4 ns
        // of logic alone.
        C_ACCSUM: begin
          acc_ge   <= (acc_at >= acc_spin);
          acc_d1   <= 29'(acc_at) - 29'(acc_spin);
          acc_d2   <= 29'(REVOLUTION_NS) - 29'(acc_spin) + 29'(acc_at);
          ch_state <= C_ACCSUM2;
        end
        C_ACCSUM2: begin
          acc_lat_r <= acc_ge ? acc_d1 : acc_d2;
          ch_state  <= C_ACCSUM3;
        end
        C_ACCSUM3: begin
          acc_total_r <= acc_total;
          ch_state    <= C_ACCDIFF;
        end
        C_ACCDIFF: begin
          acc_left <= acc_total_r - elapsed;
          acc_owed <= acc_total_r > elapsed;
          ch_state <= C_ACCFIN;
        end
        C_ACCFIN: begin
          // "When a transfer is terminated by an error, the disk address
          // register contains the address of the block being transferred
          // when the error occurred.  When a transfer terminated normally,
          // the disk address register has the address of the last block
          // transferred."  Either way it is where the heads are.
          if (ch_setda)
            da <= {1'b0, ch_unit, u_cyl[ch_unit], u_head[ch_unit], u_blk[ch_unit]};
          // `acc_left` was taken a tick ago and `elapsed` has counted five
          // since, so what is still owed is five less --- and zero stays
          // zero, as the counter itself has it.
          busy_ns  <= !drive_timed_q ? 32'd0
                    : ((acc_owed && acc_left > 32'd5) ? acc_left - 32'd5 : 32'd0);
          ch_state <= C_IDLE;
        end
        default: ch_state <= C_IDLE;
      endcase

      if (!xbus_init) begin
        if (!asked) taken <= 1'b0;
        else if (store_now) taken <= 1'b1;
      end
      // The store lands here, two ticks after the request: see the note at
      // the top.  Every term below is a register --- the `st_*` flags, `cmd`,
      // `da` --- so a data pin is two logic levels from one.
      //
      // **`-XBUS INIT` IS NOT A TERM OF THE STORE ANY MORE; IT COMES AFTER
      // IT.**  Written as `st_go && !xbus_init`, the init was the first gate
      // of every register's enable and the START's whole decode sat behind
      // it, and on the board `xbus_init` is the power-on reset: `rst_sync_
      // reg[3]/C -> disk/u_blk_reg[*]/CE`, six logic levels and 5.05 ns,
      // 36 of the DDR=1 board's failing endpoints at ef9dee9 --- three
      // quarters of it the reset synchroniser's net crossing the disk.  The
      // init block now follows the store, so on the flops it has a pin on it
      // wins by coming last, and on the ones it has no pin on --- the disk
      // address, the pointer, the drive --- a store landing in the same tick
      // lands, which is what a level on `-XINIT` and a strobe on `-LOAD DA`
      // would do to two 74LS chips.  Nothing exercises the tick they meet
      // in: `rst` holds the whole process in its reset branch on the board,
      // and the trace never stores into a controller being initialised.
      if (st_go) begin
        unique case (st_which)
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
            cmd       <= st_wdata;
            timeout   <= 1'b0;
            e_rcdiff  <= 1'b0;
            e_ccwcyc  <= 1'b0;
            e_nxm     <= 1'b0;
            e_overrun <= 1'b0;
            e_hdrcmp  <= 1'b0;
            e_hdrecc  <= 1'b0;
            e_ecchard <= 1'b0;
            e_eccsoft <= 1'b0;
            // "Reset.  Stops whatever the disk control is doing", and it
            // takes effect as soon as it is stored, with no START: the
            // 74LS00 at DCCMD 0A28 adds `RESET` to `-RESET ERR`.
            if (st_wdata[3:0] == 4'o16) begin
              busy_ns  <= 32'd0;
              hanging  <= 1'b0;
              ch_state <= C_IDLE;
              ch_req_r <= 1'b0;
            end
          end
          2'd1: clp <= st_wdata;
          // "Storing into the Disk Address register momentarily deselects the
          // current unit so that the drive can update its read-only status
          // from the switch."  Nothing models the switch, here or in muir.
          2'd2: da <= st_wdata;
          // --- START, and the sequencer such as this slice has one --------
          //
          // One flag an arm, and the flags are exclusive: see them at
          // `st_xfer`.  A START whose flag is none of these does nothing,
          // which is the store into START with nothing on the cable and a
          // code that needs one, and 0o16 --- the Reset that took effect at
          // the store into the command register, so that MIT's "takes effect
          // as soon as it is stored" is why it does nothing here.
          default: begin
            // A transfer: the seek it begins with and then the walk.  The
            // read-only fault that stops a write before it is `st_fault`.
            //
            // **`Controller::transfer` CLEARS THE EIGHT ERROR FLOPS
            // BEFORE IT DOES ANYTHING ELSE**, which the board does at
            // the store into the command register instead --- `-RESET
            // ERR` is `-LOAD CMD` OR `-XINIT` and a START is neither.
            // Every transfer in `build/disk.golden` is preceded by a
            // command store, so nothing tells the two apart; muir's is
            // taken so that a second START with no store between does
            // not leave the last transfer's errors standing.
            if (st_xfer) begin
              e_rcdiff  <= 1'b0;
              e_ccwcyc  <= 1'b0;
              e_nxm     <= 1'b0;
              e_overrun <= 1'b0;
              e_hdrcmp  <= 1'b0;
              e_hdrecc  <= 1'b0;
              e_ecchard <= 1'b0;
              e_eccsoft <= 1'b0;
              timeout   <= 1'b0;
              ch_unit   <= sel_unit;
              ch_read   <= (st_code != 4'o11);
              ch_cmp    <= (st_code == 4'o10);
              ch_moved  <= 8'd0;
              ch_n      <= 16'd0;
              ch_i      <= 9'd0;
              ch_ra     <= 9'd0;
              ch_ph     <= 3'd0;
              ch_req_r  <= 1'b0;
              ch_track  <= 1'b0;
              // The length is measured from where the heads were and
              // where the spindle stood when the START landed.
              // The spindle as it stood at the request, and the
              // walk's tally beginning a tick in: the store is held.
              acc_seek  <= seek_ns_r;
              acc_spin  <= 28'(spin_q3);
              acc_blk   <= da_blk;
              elapsed   <= HOLD_NS;
              if (!st_seek_here && st_seek_off) begin
                // A seek the drive refuses: no walk, no disk address,
                // and the access time still charged with no blocks.
                u_seek_err[sel_unit] <= 1'b1;
                ch_setda <= 1'b0;
                ch_state <= C_ACCMUL;
              end else begin
                if (!st_seek_here) begin
                  u_cyl[sel_unit]  <= da_cyl;
                  u_head[sel_unit] <= da_head;
                  u_blk[sel_unit]  <= da_blk;
                end
                ch_setda <= 1'b1;
                ch_state <= C_CCW;
              end
            end
            // Read All and Write All: the seek, then the whole track as
            // one stream of bytes --- out of the store's sectors on a
            // Read All and into them on a Write All --- and then a
            // revolution charged for it.
            if (st_all) begin
              e_rcdiff  <= 1'b0;
              e_ccwcyc  <= 1'b0;
              e_nxm     <= 1'b0;
              e_overrun <= 1'b0;
              e_hdrcmp  <= 1'b0;
              e_hdrecc  <= 1'b0;
              e_ecchard <= 1'b0;
              e_eccsoft <= 1'b0;
              timeout   <= 1'b0;
              ch_unit   <= sel_unit;
              ch_read   <= (st_code == 4'o02);
              ch_cmp    <= 1'b0;
              ch_moved  <= 8'd0;
              ch_track  <= 1'b1;
              ch_n      <= 16'd0;
              ch_i      <= 9'd0;
              ch_ra     <= 9'd0;
              ch_ph     <= 3'd0;
              ch_req_r  <= 1'b0;
              // The spindle as it stood at the request, and the
              // walk's tally beginning a tick in: the store is held.
              acc_seek  <= seek_ns_r;
              acc_spin  <= 28'(spin_q3);
              acc_blk   <= da_blk;
              elapsed   <= HOLD_NS;
              // The stream starts at the block the disk address
              // names and goes round from there --- `track_bytes`
              // runs `(block + k) % blocks_per_track` and puts the
              // track's leftover after the sector whose block number
              // is the last on the track, wherever in the sequence
              // that falls.
              trk_b     <= da_blk;
              trk_p     <= 11'd0;
              trk_gap   <= 1'b0;
              trk_g     <= 9'd0;
              trk_lay   <= 1'b1;
              ps_st     <= P_SYNC1;
              ps_ones   <= 7'd0;
              ps_n      <= 14'd0;
              ps_wc     <= 9'd0;
              ps_bit    <= 5'd0;
              if (!st_seek_here && st_seek_off) begin
                u_seek_err[sel_unit] <= 1'b1;
                ch_setda <= 1'b0;
                ch_state <= C_ACCMUL;
              end else begin
                if (!st_seek_here) begin
                  u_cyl[sel_unit]  <= da_cyl;
                  u_head[sel_unit] <= da_head;
                  u_blk[sel_unit]  <= da_blk;
                end
                ch_setda <= 1'b1;
                ch_state <= C_TLOOK;
              end
            end
            // A WRITE TO A READ-ONLY PACK: muir raises the fault and returns
            // before anything is cleared or moved.
            if (st_fault) u_fault[sel_unit] <= 1'b1;
            // The two sectors entered with the channel turned round that
            // still finish: no seek, no data, the access time of one
            // block, and the overrun on 03.
            if (st_rev) begin
              if (st_code == 4'o03) e_overrun <= 1'b1;
              ch_unit  <= sel_unit;
              ch_moved <= 8'd1;
              ch_track <= 1'b0;
              ch_setda <= 1'b0;
              acc_seek <= seek_ns_r;
              acc_spin <= 28'(spin_q3);           // at the request: held
              acc_blk  <= da_blk;
              elapsed  <= HOLD_NS;
              ch_state <= C_ACCMUL;
            end
            // Seek, and the seek of sector 4's undocumented twin.  The
            // heads' move is charged and the attention comes up when they
            // arrive --- both from the DISTANCE THE ADDRESS NAMES, which
            // muir charges whether or not the seek was refused.  With
            // nothing on the cable the sequencer waits for a drive that
            // never answers and MIT's board with the timeout jumper in
            // ends it 2.56 s on: that is `st_hang`.
            if (st_seek) begin
              if (!st_seek_here) begin
                if (st_seek_off) begin
                  u_seek_err[sel_unit] <= 1'b1;
                end else begin
                  u_cyl[sel_unit]  <= da_cyl;
                  u_head[sel_unit] <= da_head;
                  u_blk[sel_unit]  <= da_blk;
                end
              end
              // Both three ticks short: the store is held two and the read
              // word one.  See the top.
              busy_ns              <= drive_timed_q ? 32'(seek_held_r) : 32'd0;
              u_att_armed[sel_unit] <= 1'b1;
              u_att_ns[sel_unit]    <= drive_timed_q ? seek_held_r : 28'd0;
            end
            // At ease, and with it the recalibrate and the fault clear.
            // "At ease ... clears the attention"; the recalibrate takes
            // the heads home and clears the drive's own two flags, which
            // is the only thing that clears a seek error; the fault clear
            // takes the fault away on its own.  A recalibrate raises an
            // attention when the heads arrive and does NOT make the
            // controller busy --- muir charges nothing here, and MIT's
            // driver polls the attention rather than not-active.
            if (st_atease) begin
              u_att_armed[sel_unit] <= 1'b0;
              if (st_recal) begin
                u_cyl[sel_unit]      <= 12'd0;
                u_head[sel_unit]     <= 8'd0;
                u_blk[sel_unit]      <= 8'd0;
                u_fault[sel_unit]    <= 1'b0;
                u_seek_err[sel_unit] <= 1'b0;
                u_att_armed[sel_unit] <= 1'b1;
                u_att_ns[sel_unit]    <= drive_timed_q ? seek_held_r : 28'd0;   // three ticks short: held
              end
              if (st_fclr) u_fault[sel_unit] <= 1'b0;
            end
            // The sequencer waiting for a drive that never answers: a seek
            // or an offset clear with nothing on the cable, and the three
            // codes `newdsk.31` leaves it in --- 0o07 and 0o17 are sector
            // 7, which the microcode does not write, and 0o12 is the Read
            // All sector entered with the memory channel turned round.
            // MIT's board with the timeout jumper in ends all of them
            // 2.56 s on.  Two ticks short: the store is held.  See the top.
            if (st_hang) begin
              busy_ns <= TIMEOUT_NS - HOLD_NS;
              hanging <= 1'b1;
            end
          end
        endcase
      end

      // --- the backplane's init, which is not a bus cycle.  Last, so that it
      // wins over a store landing in the same tick on every flop it reaches:
      // see the note at the store.
      if (xbus_init) begin
        cmd       <= 32'd0;
        busy_ns   <= 32'd0;
        hanging   <= 1'b0;
        timeout   <= 1'b0;
        e_rcdiff  <= 1'b0;
        e_ccwcyc  <= 1'b0;
        e_nxm     <= 1'b0;
        e_overrun <= 1'b0;
        e_hdrcmp  <= 1'b0;
        e_hdrecc  <= 1'b0;
        e_ecchard <= 1'b0;
        e_eccsoft <= 1'b0;
        // `RESET` stops the channel: DCCHAN 0E16, DCBUSY 0C26.
        ch_state  <= C_IDLE;
        ch_req_r  <= 1'b0;
      end
    end
  end

  logic unused;
  // ... and the low bits of the code's next value, of which only the high
  // twenty-one are tested.
  assign unused = &{1'b0, cmd[31:12], cmd[7:4], ecc_next[10:0]};

endmodule

`default_nettype wire
