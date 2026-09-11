// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The memory path: everything between `-MEMRQ` from the processor and a word
// in PS DDR3.
//
// The first place the pieces run together.  The processor is not here --- a
// test master drives the cpu side of the cables --- and neither is AXI; what is
// here is the whole of the path in between:
//
//   cadr_xbus_decode   which slave the address belongs to, if any
//   cadr_busint_xbus   the Xbus cycle: grant, request, acknowledge, timeout
//   cadr_xbus_ddr      main memory, in front of DDR
//
// A cycle to an address with nothing at it reaches no slave, nothing answers,
// and the interface's own timer ends it --- which is the NXM timeout, and is
// why the decode's `nxm` needs no wire of its own here.
//
// **THE XBUS IS BROUGHT OUT, because main memory is one slave and not the
// only one.**  On the board `-XBUS.RQ` goes to every slave, each decodes the
// address for itself, and whichever owns it pulls `-XBUS.ACK`.  That is the
// shape here: `dev_rq` and `dev_write` leave, `device_ack` and `device_rdata`
// come back, and the acknowledgements are joined the way an open-collector
// line joins them.  Main memory stays inside because it is the one slave the
// fabric already has; the display and the disk controller will hang off these
// when they exist, and `device` says the cycle is not memory's so a slave
// need not repeat the whole decode.
//
// Until something is wired there, `device_ack` is low, nothing answers a
// device cycle, and the interface's own timer ends it --- which is exactly
// what a CADR with an empty backplane slot does.  **The display is wired
// inside now**, `cadr_tv` below, because its frame buffer is this module's
// bridge at a second base; the disk hangs on the seam from `cadr_machine.sv`.
//
// **AND THERE ARE TWO MASTERS NOW.**  The disk controller's channel moves a
// block into main memory a word at a time, and `Controller::write` reaches
// `main` directly with no bus and no time --- so there is no muir reference
// for the arbitration, only a property, and it is a hard one:
//
//   **THE PROCESSOR'S NXM TIMER IS 4,250 ns FROM THE GATED OSCILLATOR'S
//   FIRST RISE AND A BLOCK IS 256 WORDS.**  A channel that took the bus for a
//   block would turn a legitimate memory reference into an NXM.  So the
//   arbiter is PER WORD and the processor wins: the channel may begin a word
//   only while `-XBUS.RQ` is down, and a processor cycle waits at most one
//   memory access --- twenty to a hundred and thirty nanoseconds on the
//   modelled DDR --- for a word already in flight.  That, and not throughput,
//   is what `tb/cadr_memory_path_tb.cpp`'s second configuration holds.
//
// **THE CHANNEL REACHES MAIN MEMORY AND NOTHING ELSE**, which is why the
// mux is in front of the bridge and `dev_rq` to the other slaves is held down
// while the channel has the bus.  A CCW names a page and muir's rule for one
// that is not main memory is `STATUS<20>`, NXM --- `page + BLOCK_WORDS >
// main.len()` --- so a channel cycle that the decode does not call main
// memory is answered here as nothing at all, and no slave on the seam is ever
// asked about it.
//
// The address and data mux sits IN FRONT OF THE DECODE and its register, so
// the -6.5 ns family the held decode was written to cut off is untouched: the
// channel's address goes through a decode of its own into a register, and
// what reaches the bridge's `sel` is a mux on two registered bits.
//
// **AND THE UNIBUS HAS TWO SLAVES ON IT NOW.**  `cadr_spy_registers.sv` is
// the diagnostic register block at `0o766000` and `cadr_io_board.sv` is the
// I/O board at `0o764100`-`0o764126`: the keyboard, the mouse, the two clocks
// and the status register they share.  Both hang off the seam
// `cadr_console_bus.sv` presents, `-UB SSYN` is the OR of theirs as the
// open-collector line on the backplane is, and the word is a mux on which of
// them answered.
//
// **THERE IS NO DECODE IN FRONT OF THEM, AND THAT IS DELIBERATE.**  The
// obvious composition is one decode that hands the cycle to a slave, and it
// would make both of the mutations that matter here untestable.  CLAUDE.md
// records the shape: the display's `tv-answers-its-neighbours`, written as a
// wider address match gated by the decode's `device`, SURVIVED, because a
// slave that honours a guard checked exhaustively elsewhere cannot answer an
// address the guard refuses --- so the mutation tests the guard and not the
// slave.  On the backplane each board decodes the whole address for itself
// and pulls `-SSYN` if it is its own; that is what both of these do, and a
// match widened in either of them is then visible here.  What replaces the
// decode is the assertion: `build/unibus.pass` runs a real bus cycle at every
// word address of `0o760000`-`0o777776` in both directions and requires that
// AT MOST ONE slave answers each, which is the claim a decode would have
// assumed rather than tested.
//
// **AND THE TWO MASTERS' ARBITER COVERS BOTH SLAVES.**  The console takes the
// bus for `DIAGNOSTIC_NS` plus the drop and can only name the register block
// --- `cadr_console.sv` builds its address as `SPY_BASE | eadr<<1` and cannot
// reach the card at all --- but it takes the BUS, not the block, so a
// processor cycle to the card is masked while it holds, exactly as a
// processor cycle to the block is.  Two masters driving one set of address
// lines at once is what a shared bus must not do, and putting the card on the
// far side of the arbiter is what keeps that true without a second argument.

`default_nettype none

module cadr_memory_path (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,
    // `-XBUS INIT` on the backplane, which is not a bus cycle: the display's
    // vertical flag clears on it.  `cadr_machine.sv` ties it to the power-on
    // reset, the one thing that asserts it there.
    input  var logic        xbus_init,

    // The processor's side of the cables.
    input  var logic        mclk,         // MCLK7, the microcycle boundary
    input  var logic        n_memrq,      // -MEMRQ
    input  var logic        wrcyc,        // WRCYC
    input  var logic [21:0] phys,         // -PMA21..8 and -VMA7..0
    input  var logic [31:0] wdata,        // MEM<31:0> out of the cpu
    output var logic        n_memgrant,   // -MEMGRANT
    output var logic        n_memack,     // -MEMACK
    output var logic        n_loadmd,     // -LOADMD
    output var logic [31:0] rdata,        // MEM<31:0> into the cpu
    output var logic        timed_out,    // NXM TIMEOUT

    // How many 64K-word memory boards are fitted, 1 to 60.
    input  var logic [6:0]  boards,

    // The Xbus, as a slave that is not main memory sees it. `phys` and
    // `wdata` above are the address and the word; `device` says the decode
    // put this cycle outside main memory.
    output var logic        device,
    output var logic        dev_rq,       // -XBUS.RQ
    output var logic        dev_write,
    input  var logic        device_ack,   // -XBUS.ACK, from that slave
    input  var logic [31:0] device_rdata,
    // The display's `SEND INTR`, onto -XBUS.INTR: see the instance below.
    output var logic        tv_intr,

    // The disk controller's memory channel, the second master on this bus.
    // One word a cycle, the request standing until `ch_done`; `ch_nxm` says
    // main memory does not answer for that address.
    input  var logic        ch_req,
    input  var logic        ch_write,
    input  var logic [21:0] ch_addr,
    input  var logic [31:0] ch_wdata,
    output var logic        ch_done,
    output var logic        ch_nxm,
    output var logic [31:0] ch_rdata,

    // What else the decode made of the address, so that a cycle nothing
    // answers can say why rather than merely time out.
    output var logic        nxm,          // Xbus space with nothing in it
    output var logic        unibus,       // the Unibus, which now has two
                                          // slaves on it and is no longer a
                                          // slice of its own
    output var logic        ub_msyn_o,    // -UB MSYN, brought out for a check
    output var logic        ub_ssyn_o,
    output var logic [2:0]  arb_stage,
    output var logic [17:0] ub_addr_o,
    output var logic [15:0] ub_rdata_o,
    // **WHICH SLAVE IS PULLING `-UB SSYN`**: bit 0 the diagnostic register
    // block, bit 1 the I/O board.  `ub_ssyn_o` is the line itself, which is
    // the OR of these and cannot tell them apart --- and "at most one of them
    // answers any address" is the whole claim the composition makes, so it is
    // measured here rather than inferred from the word that came back.  Two
    // slaves answering one cycle would show as `2'b11` and show as nothing at
    // all on the line.
    output var logic [1:0]  ub_ssyn_by,

    // --- THE I/O BOARD'S OWN CABLES, which cross this boundary and every one
    // above it until something drives them.
    //
    // `rtl/machine/cadr_io_board.sv` is the second slave on the Unibus and is
    // instantiated below.  What it needs from outside the machine is what MIT
    // plugged into the card: the keyboard's cable, the mouse's seven lines,
    // the 2651's ready line and the Chaosnet interface's request.  None of
    // the four exists in fabric yet --- `cadr-usb-input` is last in the order
    // of work, the serial port and the Chaosnet interface are two slices of
    // their own --- so `boards/arty-z7-20/cadr_arty.sv` ties all four off and
    // says which slice will drive each.  They are ports rather than constants
    // here for the reason `drive_present` is: a thing on a cable is not a
    // property of the board it plugs into, and a check has to be able to move
    // it.  `build/unibus.pass` drives the keyboard and the mouse from here.
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    input  var logic [6:0]  mouse_lines,
    input  var logic        ser_ready,
    input  var logic        chaos_intr,

    // `-INIT*` into the 8837 at IOBXCV 0F06 is the 2651's own reset pin, so
    // the card owes the serial slice this whether or not the chip is fitted.
    output var logic        ser_reset,
    // `-UB INTR` and `-UB BR5`: the card's `intr_request` and `intr_vector`.
    // Nothing in `rtl/` runs a Unibus interrupt cycle, and the note at the
    // instance below says what that costs and what would close it.
    output var logic        iob_intr,
    output var logic [7:0]  iob_vector,
    // `AUDIO`, the level the speaker's pair is driven to.
    output var logic        audio,
    // The card's own state, as `cadr_io_board.sv` brings it out for a check.
    output var logic [7:0]  csr_face,
    output var logic [11:0] mouse_x,
    output var logic [11:0] mouse_y,
    output var logic        clock_ready,
    output var logic [15:0] interval,

    // --- THE CONSOLE, the second master on the diagnostic bus.
    //
    // `0o766000` is Unibus space and the CADR reaches it itself --- the boot
    // PROM writes the mode register there --- so the register block has two
    // masters and something must keep them apart.  `rtl/plumbing/cadr_console.sv` is
    // the other, an AXI slave on `M_AXI_GP1` in the top level, and it asks
    // here.  The arbiter and the mux are below, at the register block's
    // instance; `docs/console.md` and `tb/cadr_console_harness.sv` carry the
    // same lines.
    input  var logic        con_req,      // the console wants the bus
    output var logic        con_gnt,      // and has it
    input  var logic        con_msyn,     // -UB MSYN, the console's strobe
    input  var logic        con_write,
    input  var logic [17:0] con_addr,
    input  var logic [15:0] con_wdata,    // SPY<15:0> out
    output var logic        con_ssyn,     // -UB SSYN, to whoever asked
    output var logic [15:0] con_rdata,    // SPY<15:0> back

    // The diagnostic register block, which lives on this board: its read side
    // reaches into the processor, and its written bits are the console's.
    output var logic [3:0]  spy_eadr,
    input  var logic [15:0] spy_rdata,
    output var logic        run,
    output var logic        promdisable,
    output var logic        errstop,
    output var logic        stathenb,
    output var logic [1:0]  mode_speed,
    output var logic        prog_reset,
    output var logic        prog_boot,

    // PS DDR3, behind the AXI adapter that is not written yet.
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata
);

  logic is_memory;
  logic dev_ack, memory_ack;
  // The processor's own -XBUS.RQ, before the arbiter puts it on the bus.
  logic cpu_rq, cpu_write;
  logic [31:0] memory_rdata;
  logic ub_msyn, ub_write, ub_ssyn;
  assign ub_msyn_o = ub_msyn;
  assign ub_ssyn_o = ub_ssyn;
  assign ub_addr_o = ub_addr;
  assign ub_rdata_o = ub_rdata;
  logic [15:0] ub_rdata;

  // ------------------------------------------------------------------------
  // THE DIAGNOSTIC BUS HAS TWO MASTERS
  // ------------------------------------------------------------------------
  //
  // `rtl/machine/cadr_console_bus.sv` is the arbiter, the mux and the console's
  // read-back register, and its header carries the whole argument.  **It is a
  // module of its own for two reasons, and the second is the one that
  // matters.**  The first is that `tb/cadr_console_harness.sv` needs the same
  // arbiter and a second copy of it here would be two descriptions of one
  // thing.  The second is timing: the console is a level ABOVE this machine,
  // in `boards/arty-z7-20/cadr_arty.sv` beside the PS7, and `rtl/plumbing/xilinx7/cadr_machine.xdc` is read
  // `read_xdc -ref cadr_machine` and cannot name a register up there.  With
  // the read-back captured in the console, the board flow asked the sixteen-
  // way diagnostic mux to settle in one tick and read **-12.837 ns on 5,698
  // endpoints**; captured here it falls into that file's `slow` set on the
  // file's own test and has the microcycle.
  logic        sr_msyn, sr_write, sr_ssyn;
  logic [17:0] sr_addr;
  logic [15:0] sr_wdata;

  // The two slaves' own answers, before the bus joins them.  `sr_ssyn` is
  // `-UB SSYN` as a master sees it --- the open-collector line, which is up
  // if anything is pulling it --- and `ub_rdata` is the word of whichever
  // slave is answering.  The mux is on `iob_ssyn` and not on the card's own
  // select, so a card that answers nothing shows nothing, which is the rule
  // the DDR bridge broke by holding its word past its cycle.
  logic        blk_ssyn, iob_ssyn;
  logic [15:0] blk_rdata, iob_rdata;
  assign sr_ssyn    = blk_ssyn || iob_ssyn;
  assign ub_rdata   = iob_ssyn ? iob_rdata : blk_rdata;
  assign ub_ssyn_by = {iob_ssyn, blk_ssyn};

  cadr_console_bus console_bus (
      .clk       (clk),
      .rst       (rst),
      .mclk      (mclk),
      .cpu_msyn  (ub_msyn),
      .cpu_write (ub_write),
      .cpu_addr  (ub_addr),
      .cpu_wdata (wdata[15:0]),
      .cpu_ssyn  (ub_ssyn),
      .con_req   (con_req),
      .con_gnt   (con_gnt),
      .con_msyn  (con_msyn),
      .con_write (con_write),
      .con_addr  (con_addr),
      .con_wdata (con_wdata),
      .con_ssyn  (con_ssyn),
      .con_rdata (con_rdata),
      .sr_msyn   (sr_msyn),
      .sr_write  (sr_write),
      .sr_addr   (sr_addr),
      .sr_wdata  (sr_wdata),
      .sr_ssyn   (sr_ssyn),
      .sr_rdata  (ub_rdata)
  );

  // **THE DECODE IS TAKEN ONCE AND HELD, and the reason is timing rather than
  // function.**  `phys` is the far end of the map: `vma` is registered at the
  // microcycle boundary and the lookup is a ripple through two asynchronous
  // RAMs, so the address arrives late in the microcycle it belongs to and is
  // then constant for the whole of it.  Left combinational, the decode
  // carries that ripple onward into `cadr_xbus_ddr`'s `sel`, out of its
  // `dev_ack`, through `cadr_busint_xbus` and into `-MEMACK` and `-LOADMD`
  // --- which land on `n_memack_q` and `n_loadmd_q`, the two edge detectors
  // that genuinely run at tick rate and so are the two the multicycle
  // exception must not cover.  The tool then asks a map lookup to happen in
  // five nanoseconds: `vma_reg[13]/C -> n_loadmd_q_reg/D` at -6.542 ns.
  //
  // Registering it once cuts the family at its source.  What reaches the edge
  // detectors afterwards starts at `is_memory` and is a gate or two; what
  // reaches `is_memory` starts at `vma` and ends here, between two registers
  // that both move at the microcycle and are both in the XDC's `slow` set.
  // Nothing waits a tick for it that was not already waiting a microcycle:
  // `unibus` is read at the grant, which `cadr_busint_xbus` takes only when
  // `mclk` is up, and `sel` matters only once `dev_rq` is out, which is after
  // that grant.
  //
  // The decode itself stays combinational and stays exhaustively checked
  // against `busint::decode`.  This is a register on its outputs, not a
  // change to what it decides.
  logic is_memory_c, device_c, nxm_c, unibus_c;

  cadr_xbus_decode decode (
      .phys  (phys),
      .boards(boards),
      .memory(is_memory_c),
      .device(device_c),
      .nxm   (nxm_c),
      .unibus(unibus_c)
  );

  // --- the second master, and the arbiter ---------------------------------
  //
  // The channel's address gets a decode of its own rather than sharing the
  // processor's.  One decode with the address muxed in front of it would put
  // the channel's answer into `device`, `nxm` and `unibus` --- and `unibus`
  // is what `cadr_busint_xbus` arbitrates on, so a page that happened to
  // decode there would reach into the processor's next cycle.  Two instances
  // of a module checked exhaustively against `busint::decode` over all
  // 4,194,304 addresses cost eleven LUTs and cannot do that.
  logic ch_memory_c, ch_memory;
  logic ch_device_c, ch_nxm_c, ch_unibus_c;

  cadr_xbus_decode ch_decode (
      .phys  (ch_addr),
      .boards(boards),
      .memory(ch_memory_c),
      .device(ch_device_c),
      .nxm   (ch_nxm_c),
      .unibus(ch_unibus_c)
  );

  // **THE CHANNEL MAY BEGIN A WORD ONLY WHILE THE PROCESSOR IS NOT ASKING**,
  // and it gives the bus back at the end of every one.  `ch_own` is a
  // register, so it comes up a tick after `ch_req` --- which is the tick
  // `ch_memory` needs to settle, the channel's decode being registered like
  // the processor's.  `sel` and the request change at the same edge, so
  // neither master ever sees the other's address under its own request.
  //
  // **AND THE BUS IS LEFT IDLE FOR A TICK AT EVERY CHANGE OF OWNER.**  That
  // is not tidiness: `cadr_xbus_ddr.sv` keeps a `done` flop and an `rdata`
  // register for the cycle it is answering, and clears them when nothing is
  // asking.  Handing the bus straight from one master to the other with the
  // request never falling leaves both standing --- so the processor's read
  // inherits the channel's finished cycle, is acknowledged in no time and
  // takes the word that slave last had, which for a channel WRITE is nothing
  // at all.  Measured: without this tick, the first read of the arbiter's own
  // scenario comes back zero where the same read with the channel idle brings
  // back its word.  It is the same fact as the bridge holding a word past its
  // cycle, met from the other side.
  logic ch_own, ch_own_d, ch_ack_q, changing;
  assign changing = ch_own ^ ch_own_d;

  logic [21:0] bus_phys;
  logic [31:0] bus_wdata;
  logic        bus_write, bus_rq, bus_sel, bus_display;
  assign bus_phys  = ch_own ? ch_addr  : phys;
  assign bus_wdata = ch_own ? ch_wdata : wdata;
  assign bus_write = ch_own ? ch_write : cpu_write;
  assign bus_rq    = changing ? 1'b0 : (ch_own ? ch_req : cpu_rq);
  // The bridge answers main memory and the display's frame buffer, at two
  // bases; the channel reaches only the first.  `tv_fb` is held in
  // `cadr_tv`, as `is_memory` is held here, so this is a mux on registers.
  assign bus_sel     = ch_own ? ch_memory : (is_memory || tv_fb);
  assign bus_display = !ch_own && tv_fb;

  // The channel's answer comes a tick after main memory's, because the
  // bridge's `rdata` is a register: `dev_ack` is a gate on `mem_done` and the
  // word is only there at the edge after it.  The processor gets the same
  // word through `cadr_busint_xbus`'s own 60 ns tap of the TD100 at 0C09;
  // this is the channel's equivalent, and it costs a tick a word.
  assign ch_done  = ch_own && ch_ack_q;
  assign ch_nxm   = ch_own && !ch_memory;
  assign ch_rdata = memory_rdata;

  always_ff @(posedge clk) begin
    if (rst) begin
      ch_own     <= 1'b0;
      ch_own_d   <= 1'b0;
      ch_ack_q   <= 1'b0;
      ch_memory  <= 1'b0;
    end else begin
      ch_memory <= ch_memory_c;
      ch_own_d  <= ch_own;
      ch_ack_q  <= ch_own && !changing && (memory_ack || !ch_memory);
      if (!ch_own) ch_own <= ch_req && !cpu_rq;
      else if (ch_done) ch_own <= 1'b0;
    end
  end

  // The channel's decode says only whether main memory answers for the
  // address; a channel cycle never reaches a slave, so the other three
  // outputs are read here and nowhere else.
  logic unused_ch_decode;
  assign unused_ch_decode = ^{ch_device_c, ch_nxm_c, ch_unibus_c};

  // The same holding, for the Unibus address: it is `phys` with a subtraction
  // on it and it reaches `elapsed` in the register block, which is a counter
  // and so is excluded from the exception for the same reason the edge
  // detectors are.
  logic [13:0] ub_page;
  logic [17:0] ub_addr, ub_addr_c;
  assign ub_page   = phys[21:8] - 14'o37000;
  assign ub_addr_c = {ub_page[8:0], phys[7:0], 1'b0};

  always_ff @(posedge clk) begin
    if (rst) begin
      is_memory <= 1'b0;
      device    <= 1'b0;
      nxm       <= 1'b0;
      unibus    <= 1'b0;
      ub_addr   <= 18'd0;
    end else begin
      is_memory <= is_memory_c;
      device    <= device_c;
      nxm       <= nxm_c;
      unibus    <= unibus_c;
      ub_addr   <= ub_addr_c;
    end
  end

  cadr_busint_xbus busint (
      .clk        (clk),
      .rst        (rst),
      .mclk       (mclk),
      .n_memrq    (n_memrq),
      .wrcyc      (wrcyc),
      .n_memgrant (n_memgrant),
      .n_memack   (n_memack),
      .n_loadmd   (n_loadmd),
      .timed_out  (timed_out),
      .dev_rq     (cpu_rq),
      .dev_write  (cpu_write),
      .dev_ack    (dev_ack),
      .unibus     (unibus),
      .ub_msyn    (ub_msyn),
      .ub_write   (ub_write),
      .ub_ssyn    (ub_ssyn),
      .arb_stage  (arb_stage)
  );

  // `ub_addr` is `busint::unibus_address`: the pages above 0o37000 of the
  // 22-bit physical space, shifted left one because the Unibus counts bytes.
  // It is computed and held above, with the decode.

  // Both slaves decode `ub_addr[17:0]`, which is nine bits of page and eight
  // of word; the pages above `0o777` of the fourteen the subtraction leaves
  // go nowhere, there being no Unibus location above `0o777776`.
  logic unused_page;
  assign unused_page = &{1'b0, ub_page[13:9]};

  cadr_spy_registers spy_registers (
      .clk        (clk),
      .rst        (rst),
      .mclk       (mclk),
      .ub_msyn    (sr_msyn),
      .ub_write   (sr_write),
      .ub_addr    (sr_addr),
      .ub_wdata   (sr_wdata),
      .ub_ssyn    (blk_ssyn),
      .ub_rdata   (blk_rdata),
      .spy_eadr   (spy_eadr),
      .spy_rdata  (spy_rdata),
      .run        (run),
      .promdisable(promdisable),
      .errstop    (errstop),
      .stathenb   (stathenb),
      .mode_speed (mode_speed),
      .prog_reset (prog_reset),
      .prog_boot  (prog_boot)
  );

  // --- the I/O board, the second Unibus slave -----------------------------
  //
  // The keyboard, the mouse, the microsecond counter, the sixty-cycle clock,
  // the interval timer and the status register they share, at `0o764100` to
  // `0o764126`.  `rtl/machine/cadr_io_board.sv` is the card and
  // `build/iob.pass` holds it to `ioboard::IoBoard` through
  // `busint::IoBoardTiming` over 81 million ticks; what is new here is that a
  // cycle of the machine's own reaches it.
  //
  // **WHY IT MATTERS MORE THAN ITS SIZE SUGGESTS.**  The microsecond counter
  // at `0o764120` is the CADR's whole timebase: MIT's `(TIME)` is that
  // counter shifted, and the wall clock, `PROCESS-SLEEP`, every Chaosnet timer
  // and the scheduler hang off it.  A System 100 band's first
  // `READ-MICROSECOND-CLOCK` is at microcycle 2,087,379 and `TRACK-MOUSE`
  // reads `0o764104` and `0o764106` six thousand microcycles later.  Unwired,
  // those reads are answered by nothing and MD takes zero, which is Mete's
  // own decision for an unanswered cycle and not a fault --- but a machine
  // whose clock reads zero for ever is not one that can run a scheduler.
  //
  // **THE STROBE ARRIVES LONG AFTER THE ADDRESS HERE, WHICH THE CARD'S TRACE
  // CANNOT SAY.**  `golden/src/iob.rs` is a master with no address setup at
  // all --- `-UB MSYN` and the address on the same nanosecond, and the next
  // cycle's strobe on the tick the last one dropped --- so the card is
  // written to need the address only fifty ticks after the strobe and holds
  // its match in a register rather than computing it.  This master is the
  // other extreme, and it was measured rather than assumed: `ub_addr` is a
  // register off `phys`, which is the far end of the map and stands still for
  // the whole microcycle, while `-UB MSYN` is `UNIBUS_ADDRESS_NS` --- twenty
  // ticks --- after a grant that is itself two master clocks past the
  // arbitration.  So the address is settled tens of ticks before the strobe
  // and the held match is never the thing that is late.
  //
  // **`-UB INIT` IS TIED TO THE POWER-ON RESET.**  It clears the 74LS175's
  // four interrupt enables and the 74LS74's serial enable and reaches nothing
  // else.  Nothing in this fabric pulls it: the bus interface's own registers
  // at `0o766040`-`0o766076`, which are where a program would, are not built
  // --- `cadr_spy_registers.sv` answers `0o766000`-`0o766036` and no more ---
  // and there is no console button on the line.  So the one thing that
  // asserts it here is `rst`, which is `xbus_init`'s argument one bus along.
  // It is tied rather than made a port because a port carrying nothing but
  // `rst` at every level up to the top level says less than this comment.
  cadr_io_board iob (
      .clk        (clk),
      .rst        (rst),
      .ub_msyn    (sr_msyn),
      .ub_write   (sr_write),
      .ub_addr    (sr_addr),
      .ub_wdata   (sr_wdata),
      .ub_ssyn    (iob_ssyn),
      .ub_rdata   (iob_rdata),
      .ub_init    (rst),
      .kbd_strobe (kbd_strobe),
      .kbd_code   (kbd_code),
      .mouse_lines(mouse_lines),
      .ser_ready  (ser_ready),
      .ser_reset  (ser_reset),
      .chaos_intr (chaos_intr),
      // **THE REQUEST GOES OUT AND IS NOT ORed INTO `-XBUS.INTR`, AND THAT IS
      // A DECISION RATHER THAN AN OMISSION.**  `LM INT` is `UB INT OR XBUS
      // INTR IN` at UBINTC 0E04, so on the board the card's interrupt does
      // reach the processor --- but not as a level.  muir's
      // `Machine::unibus_interrupt` takes it only while `ENABLE UB INTS` is
      // set, which is bit 10 of the bus interface's own interrupt control
      // register at Unibus `0o766040`, and that register is one of the ones
      // this fabric does not have.  Joining the request straight into
      // `sintr_o` would therefore raise the processor's interrupt where muir
      // raises it only under a bit no program here can set, which is a
      // divergence and not a wire.  So it leaves as an observation output,
      // the top level folds it, and what closes it is `0o766040` --- the
      // register, `ENABLE UB INTS`, `UB INT` and the vector field a handler
      // reads back --- and not a gate.
      .intr_request(iob_intr),
      .intr_vector (iob_vector),
      .audio      (audio),
      .csr_face   (csr_face),
      .mouse_x    (mouse_x),
      .mouse_y    (mouse_y),
      .clock_ready(clock_ready),
      .interval   (interval)
  );

  cadr_xbus_ddr main_memory (
      .clk      (clk),
      .rst      (rst),
      .sel      (bus_sel),
      .display  (bus_display),
      .dev_rq   (bus_rq),
      .dev_write(bus_write),
      .phys     (bus_phys),
      .wdata    (bus_wdata),
      .dev_ack  (memory_ack),
      .rdata    (memory_rdata),
      .mem_req  (mem_req),
      .mem_write(mem_write),
      .mem_addr (mem_addr),
      .mem_wdata(mem_wdata),
      .mem_done (mem_done),
      .mem_rdata(mem_rdata)
  );

  // What the other slaves see: the processor's cycle and never the channel's.
  // See the note at the top --- the channel reaches main memory alone.
  assign dev_rq    = ch_own ? 1'b0 : cpu_rq;
  assign dev_write = cpu_write;

  // --- the display, the second Xbus slave that is not main memory ---------
  //
  // **INSIDE THIS MODULE AND NOT BESIDE THE DISK IN `cadr_machine.sv`**,
  // because half of it is this module's business: the frame buffer is a
  // window onto main memory's bridge at a second base, and the signal that
  // selects the bridge is made here.  The register face comes with it, so
  // that the display is one board with one held decode, and so that
  // `build/tv.pass` drives the wiring the board has rather than a harness
  // of it.  `rtl/machine/cadr_tv.sv` says what the board is and what is not built.
  //
  // It hangs on the same seam the disk does, at the same place: `sel` is the
  // held `device`, and the display decodes its own two ranges out of `phys`
  // as a board on the backplane does.  A cycle cannot be answered twice for
  // the reason `cadr_machine.sv` gives at the disk: the decode makes `memory`
  // and `device` exclusive, and inside `device` the display's 32,776 words
  // and the disk's four are disjoint by construction.
  logic        tv_ack, tv_drives, tv_fb;
  logic [31:0] tv_rdata;

  cadr_tv tv (
      .clk      (clk),
      .rst      (rst),
      .xbus_init(xbus_init),
      .sel      (device),
      .dev_rq   (dev_rq),
      .dev_write(dev_write),
      .phys     (phys),
      .wdata    (wdata),
      .dev_ack  (tv_ack),
      .rdata    (tv_rdata),
      .drives   (tv_drives),
      .fb_sel   (tv_fb),
      .intr     (tv_intr)
  );

  // The acknowledgements, joined as the open-collector `-XBUS.ACK` joins
  // them, and the word from whichever slave answered.  Nothing answers the
  // processor while the channel has the bus: its cycle simply waits, which is
  // what the per-word arbitration bounds.
  assign dev_ack = !ch_own && (memory_ack || tv_ack || device_ack);
  // The word from whichever slave answered. A Unibus register is sixteen bits
  // and reaches `MEM<15:0>`; the rest of the word is what nothing drives.  The
  // display drives the lines only while answering a READ of a control word
  // --- a write, and every frame-buffer cycle, leaves them to the others.
  //
  // **THE TOP HALF IS ZERO BECAUSE muir'S IS, AND IT WAS ONES UNTIL 11 Sep.**  `Machine::bus_read` (`../muir/src/machine.rs:710`)
  // answers a Unibus register with `self.ioboard.read(r, self.ns) as u32` ---
  // a `u16` widened, so `MEM<31:16>` is ZERO --- under a comment saying "the
  // Unibus carries 16 bits, in the bottom of one Lisp machine word".  This
  // This line drove `16'hffff` there until 11 Sep, on the argument that an
  // undriven open-collector line reads as a one --- and `tb/cadr_unibus_tb.cpp`
  // asserted `(c.word >> 16) == 0xFFFF` against a constant of its OWN and
  // compared only `c.word & 0xFFFF` with muir, so the sixteen bits where the
  // two machines disagreed were held to this fabric's own choice and to
  // nothing else.  Both are corrected: the word follows muir and the check
  // asserts muir's value with the reason beside it.
  //
  // **It is a live suspect and not a note.**  Every Unibus register read on
  // the board gives `0xFFFF_xxxx` where muir gives `0x0000_xxxx`, so any
  // microcode that uses the whole word --- a mask, a byte deposit, a swap ---
  // diverges.  The I/O board's status register reads `0o177400`, and
  // `0xFFFF_FF00` masked at `0xFF00_0000` is `0xFF00_0000` where muir's
  // `0x0000_FF00` masked the same way is zero.  The board's page zero holds
  // 128 words of `0xFF000000` in the interrupt channel table where muir has
  // zero.  **Which of the two is right is a question about the real Xbus and
  // is not this file's to decide**, so nothing is changed here: it is written
  // down where somebody meeting the line will meet it.
  assign rdata   = ub_ssyn      ? {16'h0000, ub_rdata}
                 : tv_drives    ? tv_rdata
                 : device_ack   ? device_rdata
                                : memory_rdata;

endmodule

`default_nettype wire
