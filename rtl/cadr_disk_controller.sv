// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The disk controller's four registers: an Xbus slave at 0o17377774.
//
// A port of `disk_controller::Controller`'s register face --- `status()`,
// `read` and `write` --- and of nothing else.  muir's controller is also a
// channel and a bus master: it fetches CCWs, walks a command list and moves
// pages into main memory.  None of that is here.  What is here is the four
// registers a program can read and write, which is what MIT's boot PROM
// touches and all it touches.
//
// THE NAME.  `cadr_xbus_ddr.sv` is main memory *in front of* DDR and is named
// for that; this is not the same shape.  The controller is a device on the
// Xbus that will shortly also be a MASTER on it --- the channel --- so naming
// it for the slave role would be wrong the day the channel lands.  It takes
// muir's own name instead, `src/disk_controller.rs`, which also leaves
// `disk_unit` free for the drive when `S_AXI_HP2` brings one.
//
// **A WIRE RETURNING 0x2321 WOULD PASS THE CHECK THIS MODULE IS HELD TO, AND
// THAT HAS TO BE SAID HERE RATHER THAN DISCOVERED LATER.**  On MIT's boot
// PROM the whole of this module reduces to one constant and a decode: 11,301
// reads of the status register, every one answering `0x2321`, and 5,650
// writes of zero to the disk address register.  No command is ever written;
// CLP and START are never touched.  So `build/machine.pass` cannot tell this
// register block from a constant, and `mutations/list.txt`'s disk section
// says which mutations are equivalences on that trace for exactly this
// reason.  It is the control-store-writes-all-zeros shape again --- CLAUDE.md
// has it twice already --- and the answer is the same: the trace that tells
// them apart is the band, and the band needs the drive, which is the next
// slice.
//
// WHAT THE STATUS WORD IS, BIT BY BIT.  Every line is
// `disk_controller::Controller::status()` at muir `ee8f90e`
// (`src/disk_controller.rs:329`), and the right-hand column is what this
// slice can make of it.  `-` is a bit no state here can raise:
//
//   <31:24> block counter          - : `block_counter()` answers 0 with no
//                                      drive on the cable; the two 74LS569s
//                                      at DCTRID 0B07/0B08 are clocked by
//                                      BLOCK.CLK^ off the drive
//   <23>    internal parity        - : not in the behavioural model at all
//   <22>    read compare diff      - : a transfer's, and none starts here
//   <21>    CCW cycle              - : set and cleared inside one store, so
//                                      no read can ever see it
//   <20>    NXM error              - : the channel's
//   <19>    memory parity          - : not in the behavioural model
//   <18>    header compare         - : a transfer's
//   <17>    header ECC             - : a transfer's
//   <16>    ECC hard               - : a transfer's
//   <15>    ECC soft               - : a transfer's, and `Ecc::trap` is not
//                                      going into fabric --- docs/disk-controller.md
//   <14>    overrun                - : a transfer's
//   <13>    transfer aborted       LIVE, as `lossage()`: with nothing on the
//                                      cable the disk lossage stands unless
//                                      the command register's CMD2 is up
//   <12>    start block            - : this controller has no detector
//   <11>    timeout error          - : `hang()`'s, and nothing hangs here
//   <10>    seek error             - : the selected drive's
//   <9>     not on line            1 : nothing on the cable
//   <8>     not on cylinder        1 : nothing on the cable
//   <7>     read only              - : the selected drive's
//   <6>     fault                  - : the selected drive's
//   <5>     no unit selected       1 : nothing on the cable
//   <4>     multiple units         - : not in the behavioural model
//   <3>     interrupt request      LIVE, as `interrupt()`: not-active is
//                                      always true here, so the done enable
//                                      alone decides it
//   <2>     attention              - : the selected drive's
//   <1>     any attention          - : any drive's
//   <0>     not active             1 : nothing takes time here, so the
//                                      controller is never busy
//
// With the command register at zero --- which is where the boot PROM leaves
// it, never having written one --- that is bits 13, 9, 8, 5 and 0, `0o21441`
// = `0x2321`, and `tests/disk.rs`'s
// `a_controller_with_no_drive_is_ready_and_off_line` asserts the same word
// off muir and off the netlist board.
//
// **`-XBUS.INTR` IS COMPUTED AND NOT BROUGHT OUT**, deliberately.  `<3>` is
// the level the board asserts on the backplane, and the machine takes it as
// `sintr`, which is still a stimulus port of `cadr_machine` fed from the
// trace.  Wiring one to the other is the drive's slice: `sintr` is the disk's
// done interrupt on 17,185 of the band's 2,200,000 rows and on none of the
// boot PROM's, because the enable lives in a command register this program
// never writes.  A port that exists on one side of a boundary and not the
// other is what `dev_wdata` was, so this is written down rather than left.
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
  // back" --- and only three of its bits are read on this side of the
  // channel: CMD2 for the disk lossage, and the two interrupt enables.  The
  // command code itself and the unit and cylinder fields are the channel's
  // and the drive's, and are held here because the register is one register
  // and a program may write it in any order it likes.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] cmd;
  // Write-only here, and read by nothing until the channel walks the command
  // list.  Register 1 reads back the LAST MEMORY ADDRESS and not this ---
  // MIT puts two different things at one address --- so holding it costs
  // nothing this slice can observe and saves the next one guessing.  **The
  // boot PROM never writes it**: any mutation of it is invisible on that
  // trace, and `mutations/list.txt` says so.
  logic [31:0] clp;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] da;

  // --- the status word ---------------------------------------------------
  //
  // "<0> Not Active.  0 means the controller is busy, 1 means it is ready to
  // accept a command."  `not_active()` is `now >= done_at`, and nothing here
  // charges `done_at`: a transfer is the channel's and START does not start
  // one yet.  So the controller is never busy, which is also how muir runs by
  // default --- `Controller::timed` is off, and every count this project
  // quotes was measured with it off.
  logic not_active;
  assign not_active = 1'b1;

  // `-LOSSAGE`, the 74LS21 at DCBUSY 0B15 over four terms, of which only the
  // disk lossage can fire here: `NO SELECT`, `MULTIPLE SELECT`, `SEL UNIT
  // FAULT`, `SEL UNIT SEEK ERROR` and `-SEL UNIT ON LINE` through the 74LS32
  // at 0C16, which lets them through only with CMD2 low.  With no drive the
  // first of those stands, so the bit follows CMD2 alone.  The transfer
  // lossage --- timeout, NXM, overrun, the header and ECC errors --- has no
  // source in this slice; see the table at the top.
  logic lossage;
  assign lossage = !cmd[2];

  // "Done Interrupt Enable.  Enables not-active (bit 0 of the status
  // register) to cause an interrupt."  The attention enable needs a drive to
  // raise an attention, so with none on the cable the done enable is the
  // whole of it.
  logic interrupt;
  assign interrupt = not_active && cmd[11];

  // The word itself.  Written by name rather than as a 32-bit concatenation,
  // because the table at the top of this file is the specification and a
  // concatenation of eighteen zeros and five names is not readable against
  // it.  Everything not named here is zero, and the table says why for each.
  logic [31:0] status;
  assign status = 32'h0000_0320                             // <9> <8> <5>
                | (lossage    ? 32'h0000_2000 : 32'd0)      // <13>
                | (interrupt  ? 32'h0000_0008 : 32'd0)      // <3>
                | (not_active ? 32'h0000_0001 : 32'd0);     // <0>

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
      // position."  `Ecc::trap` is not going into fabric --- see
      // docs/disk-controller.md, where that is a decision and not an
      // omission --- so this reads zero and `STATUS<15>` never fires.
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
  // and does, and so will the channel.  So the cycle is latched the way
  // `cadr_xbus_ddr.sv` latches `done`, and cleared when the request goes.
  logic taken;

  // "Writing anything at this address initiates the operation specified in
  // the command, disk address, and command list pointer registers."  **AND IT
  // DOES NOTHING YET**: `Controller::start` is the channel, the drive and
  // `S_AXI_HP2`, none of which exist.  The pulse is here because the write
  // has to be distinguished from the other three now rather than later, and
  // because a START that silently wrote a register would be worse than one
  // that does nothing.  The boot PROM never stores into it.
  logic start_pulse;
  assign start_pulse = asked && dev_write && !taken && (which == 2'd3);

  logic unused;
  assign unused = &{1'b0, start_pulse};

  // The held decode, above, and the write below: one process, because both
  // are this slave's state.
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
      // `xbus_init`: -XINIT clears the command register --- the 74LS175 at
      // DCCMD 0C21 and the 74LS273 at 0C10, pin 1 of each.  "The disk address
      // counters (the 74LS193s at DCDA 0A17-0A21), the command list pointer
      // (DCCLP) and the CCW latches (DCCCW) have no pin on it and stand", so
      // on the board those two come up undefined; zero is this fabric's
      // convention for them, as `LVMO_AT_POWER_ON` is elsewhere.
      cmd   <= 32'd0;
      clp   <= 32'd0;
      da    <= 32'd0;
      taken <= 1'b0;
    end else if (!asked) begin
      taken <= 1'b0;
    end else if (dev_write && !taken) begin
      taken <= 1'b1;
      unique case (which)
        // "Writing the command register does NOT initiate a transfer, unlike
        // most disk controllers.  Use register 3 (START) to initiate a
        // transfer, after setting up the other registers."
        //
        // **`reset_errors()` AND `reset()` HAVE NOTHING TO CLEAR IN THIS
        // SLICE, WHICH IS A STATEMENT ABOUT THE SLICE AND NOT AN OMISSION.**
        // Every flag `-RESET ERR` clears --- the 74LS273s at DCSTS 0C12 and
        // 0D24, the 74LS279 at 0B12 and `STOPPED BY ERROR` at DCBUSY 0B06 ---
        // is raised only by a transfer, and the table at the top of this file
        // says so bit by bit; `reset()` also charges `done_at` to now, and
        // nothing here charges it forward.  So the store below is the whole
        // of what a command write does here, INCLUDING code 0o16, whose
        // "takes effect as soon as it is stored" is a reset of state that
        // does not exist yet.  Building flops nothing can set would put
        // unexercised logic in the fabric and an equivalent mutant in the
        // list; both arrive with the channel, together with the thing that
        // sets them.
        2'd0: cmd <= wdata;
        2'd1: clp <= wdata;
        // "Storing into the Disk Address register momentarily deselects the
        // current unit so that the drive can update its read-only status from
        // the switch."  Nothing models the switch, here or in muir.
        2'd2: da <= wdata;
        default: ;   // START: `start_pulse` above, which does nothing yet
      endcase
    end
  end

endmodule

`default_nettype wire
