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
//   modeled DDR --- for a word already in flight.  That, and not throughput,
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
// **AND THE UNIBUS HAS THREE SLAVES ON IT NOW.**  `cadr_spy_registers.sv` is
// the diagnostic register block at `0o766000`, `cadr_io_board.sv` is the I/O
// board at `0o764100`-`0o764126` --- the keyboard, the mouse, the two clocks
// and the status register they share --- and `cadr_busint_regs.sv` is the bus
// interface's own two groups, the interrupt block at `0o766040`-`0o766076`
// and the Unibus map at `0o766140`-`0o766176`.  All three hang off the seam
// `cadr_console_bus.sv` presents, `-UB SSYN` is the OR of theirs as the
// open-collector line on the backplane is, and the word is a mux on which of
// them answered.
//
// **AND THE XBUS HAS THREE MASTERS ON IT NOW.**  The third is the Unibus
// map's window, `0o140000`-`0o177777`, which `cadr_busint_regs.sv` answers
// for a foreign Unibus master and half of which is an Xbus cycle at the
// translated address --- `Responder::MapXbus`, `Machine::mapped_read` and
// `mapped_write`.  It is arbitrated exactly as the channel is, per word and
// behind the processor, and behind the channel as well; the section that
// builds it says why, and says which page never takes the bus at all.  The
// window is what makes the map's sixteen registers worth having: they landed
// first, so the debugger could program a map and then had nothing to send
// through it.
//
// **AND THE MASTER FOR ONE IS COMPOSED.**  The only master muir has for a
// mapped cycle is the debug cable's, `cadr_dbgin.sv`, which is instantiated
// below with `ub_foreign` half its grant; the console is a master but cannot
// address anything outside `0o766000`-`0o766036`; and the processor's own
// cycles are not mapped by `busint::decode` and must not be.  What drives the
// route is `build/busint_regs.pass` at the block's own seam and
// `build/unibus.pass` through this arbiter twice --- once on the console's
// seam, which is the seam a foreign master presents, and once over MIT's own
// cable, which is the master the route was built for.
//
// **THERE IS NO DECODE IN FRONT OF THEM, AND THAT IS DELIBERATE.**  The
// obvious composition is one decode that hands the cycle to a slave, and it
// would make both of the mutations that matter here untestable.  CLAUDE.md
// records the shape: the display's `tv-answers-its-neighbours`, written as a
// wider address match gated by the decode's `device`, SURVIVED, because a
// slave that honors a guard checked exhaustively elsewhere cannot answer an
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

module cadr_memory_path #(
    // MIT's TV sync PROM as a `$readmemh` image, passed down to `cadr_tv`;
    // `rtl/machine/cadr_tv.sv` says what it is and why it is named at
    // elaboration rather than left to a relative default.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex"
) (
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

    // `XBUS INTR IN`, the backplane's one interrupt line as it arrives at the
    // bus interface: the disk controller's request ORed with the display's.
    // The display's is made here and the disk's in `cadr_machine.sv`, so the
    // OR is made there and comes back in --- which is what the backplane is.
    // `rtl/machine/cadr_busint_regs.sv` reads it in bit 14 of the interrupt
    // status register and does not store it.
    input  var logic        xbus_intr,
    // `UB INT`: the Unibus interrupt the interface has taken, or one
    // simulated by writing the bit.  `cadr_machine.sv` ORs it with the line
    // above into `SINTR`, as `LM INT` is `UB INT OR XBUS INTR IN` at
    // UBINTC 0E04.
    output var logic        ub_int,

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
    // block, bit 1 the I/O board, bit 2 the bus interface's own registers.
    // `ub_ssyn_o` is the line itself, which is the OR of these and cannot tell
    // them apart --- and "at most one of them answers any address" is the
    // whole claim the composition makes, so it is measured here rather than
    // inferred from the word that came back.  Two slaves answering one cycle
    // would show as two bits up and show as nothing at all on the line.
    output var logic [2:0]  ub_ssyn_by,

    // --- WHAT THE TRANSACTION AUDIT IS ANCHORED ON.  Four registers and an
    // observation: `rtl/plumbing/cadr_bus_audit.sv` is instantiated a level up
    // in `rtl/machine/cadr_machine.sv`, watches one transaction per bus cycle
    // at the memory port, and nothing it produces reaches the datapath.
    //
    // **THEY ARE THE ARBITER'S STATE AND EACH MASTER'S OWN HELD DECODE, AND
    // NOT `bus_rq`, `bus_write` OR `bus_sel`.**  That module's header carries
    // the argument, and it is CLAUDE.md's shadow-memory rule: a check keyed by
    // the thing under test moves with the bug, and the thing under test is the
    // path from a bus cycle to the AXI port --- so a fault in the mux those
    // three come out of must not also move what the audit compares against.
    // The request and the direction are therefore taken at each master, which
    // is why `mbusy` and `wrcyc` are not here: the processor's are the
    // processor's and `cadr_machine.sv` reads them where they are made.
    //
    // `cpu_memory_o` is `is_memory || tv_fb` and NOT `is_memory` alone,
    // because the display's frame buffer is this bridge at a second base: a
    // frame-buffer cycle decodes as `device` and issues a transaction anyway,
    // and an audit that did not know that would fault on the first pixel the
    // machine ever painted.
    //
    // `bus_changing_o` is the idle tick this module already inserts at every
    // change of owner.  The audit uses it to close one cycle and open the
    // next, because MBUSY and `ch_own` genuinely overlap --- see the note at
    // the arbiter below.
    output var logic        ch_own_o,       // the channel has the bus
    output var logic        bus_changing_o, // the idle tick at a handover
    output var logic        cpu_memory_o,   // the bridge answers the processor
    output var logic        ch_memory_o,    // the bridge answers the channel

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
    // `-BOOT*` off the card, the keyboard's boot word decoded: a 4 us pulse
    // out of the card's slot on `CP1`, joined by a hand-run backplane wire to
    // the bus interface's bused `CR1`, where it is `-LM BOOT` and reaches the
    // processor as `-BOOT1`; the wire is assumed, and the join in
    // `cadr_machine.sv` says on what.  The gate that makes `-BOOT` of it is
    // there too, where the light panel's `-BOOT2` and the debug cable's
    // `PROG.BOOT` meet it.
    output var logic        n_boot_star,
    input  var logic [6:0]  mouse_lines,

    // --- THE SERIAL PORT'S LINE AND THE CHAOSNET'S CABLE, which the two
    // Linux programs own: `cadr-serial` offers the 2651's line on a TCP
    // socket as muir's `--serial` does, and `cadr-chaosnet` frames what the
    // interface hands it.  **`ser_ready` AND `chaos_intr` USED TO BE INPUTS
    // HERE AND ARE GONE**: both chips are on the card now, so the card makes
    // its own `SER.IREQ` and `CHAOS.IREQ`, and a line left driving either
    // fails to compile rather than quietly supplying the answer.
    output var logic        ser_reset,
    output var logic [7:0]  ser_mode1,
    output var logic [7:0]  ser_mode2,
    output var logic [7:0]  ser_cmd,
    output var logic        ser_tx_strobe,
    output var logic [7:0]  ser_tx_data,
    input  var logic        ser_tx_take,
    input  var logic        ser_tx_done,
    input  var logic        ser_rx_strobe,
    input  var logic [7:0]  ser_rx_data,
    // The received frame's own end, and the two errors only a far end
    // counting bits can see.  `cadr_io_board.sv`'s header says what each is
    // for: `ser_rx_end` is what lets the card place the echo auto echo and
    // remote loop back owe the line, and the two flags are `SR3` and `SR5`.
    input  var logic        ser_rx_end,
    input  var logic        ser_rx_parity,
    input  var logic        ser_rx_framing,
    input  var logic        ser_plugged,
    output var logic [7:0]  ser_status,
    // The 2651's SYN1, SYN2 and DLE registers and their pointer, out for the
    // check: nothing reads them back, so without a reader synthesis trims
    // them and the fabric would not have the registers at all.
    output var logic [25:0] ser_syn_face,
    input  var logic [15:0] chaos_address,
    output var logic        chaos_tx_go,
    output var logic [8:0]  chaos_tx_len,
    output var logic        chaos_tx_valid,
    output var logic [15:0] chaos_tx_word,
    output var logic        chaos_tx_clear,
    output var logic        chaos_reset,
    output var logic [15:0] chaos_csr,
    input  var logic        chaos_rx_valid,
    input  var logic [15:0] chaos_rx_word,
    input  var logic        chaos_rx_done,
    input  var logic [12:0] chaos_rx_bits,
    input  var logic        chaos_rx_crc,
    input  var logic        chaos_tx_done,
    input  var logic        chaos_tx_abort,
    input  var logic        chaos_cbl_busy,
    output var logic [11:0] chaos_bits,
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

    // --- THE DEBUG CABLE, the third master on the diagnostic bus, and MIT's
    // --- own wires out of this machine.
    //
    // `rtl/machine/cadr_dbgin.sv` is the DBGIN page: the 74S139 at 0A15, the
    // modifier register at 0A16, the two address latches at 0A18 and 0A19,
    // the error-status driver at REQERR 0B15, and the debug master's place on
    // this machine's Unibus.  It is instantiated below, beside the two Unibus
    // slaves, because the master it makes belongs on the arbiter down there
    // and an arbiter must be one description of one thing.
    //
    // What crosses THIS boundary is the cable itself --- the twenty-one wires
    // of MIT's DBGIN connector --- and nothing else.  The carrier that puts
    // them on a general-purpose port is `rtl/plumbing/cadr_debug_window.sv`,
    // which is a level above and is not the machine's: that is the same
    // boundary this repository draws between `rtl/machine/` and
    // `rtl/plumbing/`.  `docs/debug-cable.md` has the whole of it.
    //
    // `dbg_in_req` high means `-DEBUG IN REQ` is DOWN, which is muir's
    // `fabric::REQ` and is the sense the whole transport uses.
    input  var logic        dbg_in_req,
    input  var logic        dbg_in_wr,       // DEBUG IN WR
    input  var logic [1:0]  dbg_in_a,        // DEBUG IN A<1:0>
    input  var logic [15:0] dbd_in,          // DBD<15:0> as the debugger drives
    output var logic        dbg_in_ack,      // DEBUG IN ACK
    output var logic [15:0] dbd_out,         // DBD<15:0> as this board drives
    output var logic [1:0]  dbd_oe,          // {DBD<15:8>, DBD<7:0>} driven

    // --- AND THE SAME CABLE'S OTHER END: this machine as the DEBUGGER, which
    // --- is the DBGOUT page in `rtl/machine/cadr_busint_regs.sv` and is what
    // --- CC writes.  The carrier is `rtl/plumbing/cadr_dbg_cable.sv`, a
    // --- level above for the same reason the window is.
    //
    // The four go out as levels held for the whole request; the two come back
    // with the lines already resolved against the far end's pull-ups, and
    // `dbgout_live` says whether there is a board there at all.
    output var logic        dbgout_req,
    output var logic        dbgout_wr,
    output var logic [1:0]  dbgout_a,
    output var logic [15:0] dbgout_dbd,
    input  var logic        dbgout_ack,
    input  var logic [15:0] dbgout_dbd_in,
    input  var logic        dbgout_live,

    // --- the modifier register's two effects, `busint::debug_modifier`.
    // Bit 1 is `-DEBUGEE RESET`, which crosses the debuggee's own cables to
    // OLORD2 and is that processor's power-on reset, so it goes OUT of the
    // machine and comes back as `rst` --- `boards/arty-z7-20/cadr_arty.sv`
    // joins it with the board's own and with the console's pulse, which is
    // where the console's already lands.  It is a LEVEL and not a pulse:
    // MIT's own note is "write a 1 here then write a 0".
    //
    // Bit 2 turns off this machine's NXM timeout, for all of its cycles and
    // not only the debugger's.  **Nothing consumes it yet** --- the counter
    // is inside `cadr_busint_xbus.sv`, which is held to muir tick for tick
    // over a trace, so giving it this term needs a trace with a debug cable
    // in it.  It is a port so that the bit exists and is readable rather
    // than being quietly dropped, which is this file's rule about building
    // the machine whole.
    output var logic        debuggee_reset,
    output var logic        timeout_inhibit,

    // --- and the reset the DBGIN page itself takes, which is NOT this
    // --- module's `rst`.
    //
    // **A MODIFIER REGISTER CLEARED BY ITS OWN BIT 1 CLEARS THE BIT THAT IS
    // CLEARING IT.**  `debuggee_reset` above is modifier bit 1, and MIT's own
    // note is that it is a LEVEL --- "write a 1 here then write a 0".  The
    // top level joins it with the board's reset and the console's pulse and
    // hands the result back as this module's `rst`, so a DBGIN page reset by
    // `rst` would turn that level into a one-tick pulse and MIT's sequence
    // could not be written at all.  `tb/cadr_dbgin_harness.sv` measured
    // exactly that before it was understood and says so at its instance.
    //
    // So the cable's own end takes the BOARD's reset, one level up, exactly
    // as the carrier does --- and it is a port rather than a constant for the
    // reason every seam here is: a thing on a cable is not a property of the
    // board it plugs into.  On a board with no carrier the two are the same
    // net and the difference costs nothing.
    input  var logic        dbg_rst,

    // The diagnostic register block, which lives on this board: its read side
    // reaches into the processor, and its written bits are the console's.
    output var logic [3:0]  spy_eadr,
    input  var logic [15:0] spy_rdata,
    output var logic        run,
    // The other four bits of the clock control register and the debug IR:
    // written here, read by the processor on the far side of the cables.
    output var logic        step,
    output var logic        nop11,
    output var logic        idebug,
    output var logic        ldstat,
    output var logic [47:0] debug_ir,
    output var logic        promdisable,
    output var logic        errstop,
    output var logic        stathenb,
    output var logic [1:0]  mode_speed,
    output var logic        prog_reset,
    output var logic        prog_boot,
    // `-BOOT`, made by the 74S02 at OLORD2 1A07 out of the three boot lines.
    // It comes back DOWN here because the console's registers are on this
    // board now and `-BOOT` is one of the three inputs of `RESET` at 1C08,
    // which clears them.  `cadr_machine.sv` has the gate and the account.
    input  var logic        n_boot,
    // The no-auto-boot switch, on its way to the register block's reset arm
    // and to nothing else.  `cadr_spy_registers.sv`'s port says what it does
    // and when it is read; this module only carries it.
    input  var logic        no_auto_boot,

    // --- `UB MD LOAD`, `NOR(-UB TO MD, -UBX GRANT)` at REQLM 0B17: a
    // foreign master's mapped write whose page is the processor's `MD`.
    // The word does not go on the Xbus at all --- `-UB TO MD` holds the
    // request off at REQLM 0E09 --- so this leaves the module beside the
    // memory port rather than through it, and `cadr_machine.sv` wires it to
    // `cadr_microcycle`, which owns `MD` and says on `ub_md_ack` when it has
    // taken the word.  `busint::Responder::MapMd`, CC's `CC-WRITE-MD`.
    output var logic        ub_md_req,
    output var logic [31:0] ub_md_data,
    input  var logic        ub_md_ack,

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
  logic        blk_ssyn, iob_ssyn, bir_ssyn;
  logic [15:0] blk_rdata, iob_rdata, bir_rdata;
  assign sr_ssyn    = blk_ssyn || iob_ssyn || bir_ssyn;
  assign ub_rdata   = iob_ssyn ? iob_rdata : bir_ssyn ? bir_rdata : blk_rdata;
  assign ub_ssyn_by = {bir_ssyn, iob_ssyn, blk_ssyn};

  // ------------------------------------------------- the debug cable's end
  //
  // `rtl/machine/cadr_dbgin.sv` is MIT's DBGIN page and the third master on
  // the diagnostic bus.  It was tied off here until the port the carrier
  // sits on was decided, and the tie-off's own comment said so; the decision
  // is made --- `rtl/plumbing/cadr_debug_window.sv` shares `M_AXI_GP1` with
  // the console behind `rtl/plumbing/cadr_gp1_split.sv` --- so the arm is
  // live and the cable leaves this module as ports.
  //
  // `tb/cadr_dbgin_harness.sv` was written as this attachment before it
  // landed, and these are its lines.  What that harness has and this does not
  // is a `cadr_console_bus` of its own; here the one below is the same
  // module, so what `build/dbgin.pass` checks is what the board carries.
  //
  // **THE PAGE TAKES `dbg_rst` AND NOT `rst`, AND THAT IS THE WHOLE REASON
  // THERE ARE TWO.**  `rst` is the machine's, which the top level makes out
  // of the board's reset, the console's pulse and `debuggee_reset` --- and
  // `debuggee_reset` is this module's modifier bit 1.  A page reset by its
  // own bit 1 clears the bit that is clearing it, so MIT's "write a 1 here
  // then write a 0" becomes a one-tick pulse that cannot be written.
  // Measured in `tb/cadr_dbgin_harness.sv` before it was understood, and the
  // port declaration above says it again where somebody wiring this will
  // read it.
  //
  // What a machine reset DOES do to a standing debug cycle is leave it
  // unanswered: `cadr_console_bus` takes `rst` and drops the grant, so a
  // cycle in `C_XFER` waits for a `-UB SSYN` that never comes until the
  // debugger lifts.  That is what the real board does --- there is no
  // timeout for this master --- and the debugger's own 11.05 us is what ends
  // it.
  //
  // **AND THE ERROR STATUS BYTE IS ASSEMBLED HERE, WHICH IS WHERE REQERR
  // ASSEMBLES IT.**  `Machine::debug_status` is `bus_error | NOT_FREE |
  // WRITE_THROUGH`, and the 8304 at REQERR 0B15 takes the eight nets that
  // make it: seven are that page's own and the eighth, `-FREE`, arrives from
  // the request logic.  In this fabric the seven are
  // `rtl/machine/cadr_busint_regs.sv`'s `err_status` and `-FREE` is
  // `cadr_busint_xbus.sv`'s `busy`, so this module is the page they meet on.
  // The 74LS244 at REQERR 0C16 reads the same seven for `0o766044`, which is
  // why they are one expression over there rather than two.
  //
  // **FIVE OF THE EIGHT BITS ARE REAL AND THREE ARE ZERO FOR GOOD.**  Bits 1,
  // 2 and 4 are `XB PAR ERROR`, `LM ADR PAR ERROR` and `LM PAR ERROR`, and
  // muir's own note on `machine::bus_error` is that "the rest of the register
  // is parity errors, which cannot happen here".  The two NXM bits, the map
  // error and write-through are held over there; `-FREE` is live here.
  //
  // The byte is a PORT on `cadr_dbgin` rather than a constant inside it for
  // the reason `build/dbgin.pass` gives: a check that hands the module the
  // answer tests nothing, and there the byte comes from outside.  What holds
  // THIS join is `build/unibus.pass`, which makes each bit true by driving
  // the machine and reads the byte back over MIT's own cable.

  // `error_status::NOT_FREE`, the 8304's pin 7 and `DBD6`.
  localparam logic [7:0] NOT_FREE = 8'o100;

  logic [7:0]  regs_err_status;   // the seven this board holds
  logic        busint_busy;       // `-FREE`, inverted
  logic [7:0]  dbg_err_status;
  assign dbg_err_status = regs_err_status | (busint_busy ? NOT_FREE : 8'd0);

  logic        dbg_req, dbg_gnt, dbg_msyn, dbg_write, dbg_ssyn;
  logic [17:0] dbg_addr;
  logic [15:0] dbg_wdata, dbg_rdata;
  logic [2:0]  dbg_modifier;
  logic [15:0] dbg_address;
  logic        unused_dbg;
  assign unused_dbg = ^{dbg_modifier, dbg_address};

  cadr_dbgin dbgin (
      .clk             (clk),
      .rst             (dbg_rst),
      .dbg_in_req      (dbg_in_req),
      .dbg_in_wr       (dbg_in_wr),
      .dbg_in_a        (dbg_in_a),
      .dbd_in          (dbd_in),
      .dbg_in_ack      (dbg_in_ack),
      .dbd_out         (dbd_out),
      .dbd_oe          (dbd_oe),
      .err_status      (dbg_err_status),
      .debuggee_reset  (debuggee_reset),
      .timeout_inhibit (timeout_inhibit),
      .dbg_req         (dbg_req),
      .dbg_gnt         (dbg_gnt),
      .ub_msyn         (dbg_msyn),
      .ub_write        (dbg_write),
      .ub_addr         (dbg_addr),
      .ub_wdata        (dbg_wdata),
      .ub_ssyn         (dbg_ssyn),
      .ub_rdata        (dbg_rdata),
      .modifier_o      (dbg_modifier),
      .address_o       (dbg_address)
  );

  // **WHOSE CYCLE IS ON THE BUS**, which is `MSYN IN` rather than `MSYN OUT`
  // and is the one thing the mapped window at `0o140000`-`0o177777` needs
  // that the two register groups do not.  `busint::decode`, which is what the
  // PROCESSOR's own Unibus cycle goes through, answers `Responder::NoUnibus`
  // at every address of that window; the map responders are made in
  // `Rtl::try_debug_request` and nowhere else.  So the board's own cycle must
  // NOT be mapped and a foreign master's must be, and this is that
  // distinction: the arbiter already knows it and nothing else has to.
  //
  // **The console is counted and cannot reach the window**, which is worth
  // saying rather than leaving as an apparent oversight: a slave decodes the
  // address and not the master, so a board on MIT's backplane would map the
  // console's cycle exactly as it maps the cable's --- but
  // `rtl/plumbing/cadr_console.sv` builds its address as `SPY_BASE |
  // eadr<<1`, four bits of `eadr`, and can put nothing but
  // `0o766000`-`0o766036` on the bus.
  //
  // **THE CABLE IS THAT MASTER AND IT IS COMPOSED HERE NOW.**  Until the
  // carrier's port was decided this arm was tied off and the window answered
  // nothing, which the tie-off's own comment said; `cadr_dbgin` is
  // instantiated above and its grant is half of this term, so a debug cycle
  // at a window address is translated and the processor's at the same address
  // still times out.  `build/unibus.pass` runs both and compares the word the
  // memory port was asked for.
  logic ub_foreign;
  assign ub_foreign = dbg_gnt || con_gnt;

  cadr_console_bus console_bus (
      // --- the debug cable's master, `rtl/machine/cadr_dbgin.sv` above.
      // --- First on MIT's grant chain, so it beats the console; it waits
      // --- for the processor's own strobe like everything else on this bus.
      .dbg_req   (dbg_req),
      .dbg_gnt   (dbg_gnt),
      .dbg_msyn  (dbg_msyn),
      .dbg_write (dbg_write),
      .dbg_addr  (dbg_addr),
      .dbg_wdata (dbg_wdata),
      .dbg_ssyn  (dbg_ssyn),
      .dbg_rdata (dbg_rdata),
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

  // --- the third master, the Unibus map's window --------------------------
  //
  // `rtl/machine/cadr_busint_regs.sv` answers `0o140000`-`0o177777` for a
  // foreign Unibus master, and the half of that which is an Xbus cycle
  // --- `Responder::MapXbus` --- comes out here.  It gets a decode of its own
  // for the channel's reason one line up: one decode with the address muxed
  // in front of it would put this master's page into `device`, `nxm` and
  // `unibus`, and `unibus` is what `cadr_busint_xbus` arbitrates on.
  //
  // **ONLY A MAIN-MEMORY PAGE TAKES THE BUS, BY muir'S OWN WORDS.**
  // `Busint::debug_xbus_edge`: "The processor asking for the Xbus meanwhile,
  // and a mapped page nothing answers, are **not modeled**: the debuggee CC
  // works on is halted, and its map points at memory."  So a mapped page that
  // is a device, the Unibus or nothing never asks for the bus at all: the
  // cycle is never acknowledged and stands until its master gives up, which
  // is what `cadr_dbgin.sv` says happens to any cycle nothing answers ---
  // "there being no timeout for this master".  Refusing the GRANT rather than
  // the acknowledgement is what keeps the machine's own Xbus cycles running
  // meanwhile.
  logic        map_req, map_write, map_done, map_md;
  logic [21:0] map_addr;
  logic [31:0] map_wdata, map_md_wdata;
  logic        mp_own, mp_ack_q, mp_memory, mp_memory_c;
  logic        mp_device_c, mp_nxm_c, mp_unibus_c;

  cadr_xbus_decode mp_decode (
      .phys  (map_addr),
      .boards(boards),
      .memory(mp_memory_c),
      .device(mp_device_c),
      .nxm   (mp_nxm_c),
      .unibus(mp_unibus_c)
  );

  // `-UB TO MD` LEAVES THIS MODULE NOW.  The register block decodes it,
  // puts `UBXRQ` in the gate as REQU 0D12 does and latches the thirty-two
  // lines; the processor takes the word and acknowledges, which is `UB MD
  // LOAD` at REQLM 0B17 and the whole of what CC's `CC-WRITE-MD` needs.  The
  // arbitration is NOT here: the word never reaches the Xbus, so nothing has
  // to wait for the bus, and the one gate muir has --- the interface not
  // being in a granted cycle --- is about the processor's own `MD` writers
  // and lives with them in `cadr_microcycle.sv`.
  assign ub_md_req  = map_md;
  assign ub_md_data = map_md_wdata;

  // The map's decode says only whether main memory answers for the address:
  // a mapped cycle at any other page never takes the bus, which the header
  // says at length, so the other three outputs are read here and nowhere
  // else.
  logic unused_map;
  assign unused_map = ^{mp_device_c, mp_nxm_c, mp_unibus_c};

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
  //
  // **AND THE MAP'S WINDOW IS A THIRD OWNER, BEHIND BOTH.**  `owner` is two
  // bits rather than one flag, and `changing` is a comparison rather than an
  // exclusive-or, so that the idle tick below is taken at EVERY change of
  // owner and not only at the channel's.  The processor wins over both and
  // the channel wins over the map: the channel is a disk moving a block under
  // a rotational deadline and the map is a debugger, so the debugger waits.
  logic ch_own, ch_ack_q, changing;
  logic [1:0] owner, owner_d;
  assign owner    = {mp_own, ch_own};
  assign changing = owner != owner_d;

  logic [21:0] bus_phys;
  logic [31:0] bus_wdata;
  logic        bus_write, bus_rq, bus_sel, bus_display;
  assign bus_phys  = ch_own ? ch_addr  : mp_own ? map_addr  : phys;
  assign bus_wdata = ch_own ? ch_wdata : mp_own ? map_wdata : wdata;
  assign bus_write = ch_own ? ch_write : mp_own ? map_write : cpu_write;
  assign bus_rq    = changing ? 1'b0 : (ch_own ? ch_req : mp_own ? map_req : cpu_rq);
  // The bridge answers main memory and the display's frame buffer, at two
  // bases; the channel reaches only the first.  `tv_fb` is held in
  // `cadr_tv`, as `is_memory` is held here, so this is a mux on registers.
  assign bus_sel     = ch_own ? ch_memory : mp_own ? mp_memory : (is_memory || tv_fb);
  assign bus_display = !ch_own && !mp_own && tv_fb;

  // The channel's answer comes a tick after main memory's, because the
  // bridge's `rdata` is a register: `dev_ack` is a gate on `mem_done` and the
  // word is only there at the edge after it.  The processor gets the same
  // word through `cadr_busint_xbus`'s own 60 ns tap of the TD100 at 0C09;
  // this is the channel's equivalent, and it costs a tick a word.
  assign ch_done  = ch_own && ch_ack_q;
  assign ch_nxm   = ch_own && !ch_memory;
  assign ch_rdata = memory_rdata;

  // The map's window, the same shape and for the same reason: its word is a
  // tick behind main memory's acknowledgement because the bridge's `rdata` is
  // a register.  There is no `nxm` here, a page that is not main memory never
  // having taken the bus at all.
  assign map_done = mp_own && mp_ack_q;

  // The audit's anchor, brought out: see the port list.  Four registers and a
  // gate, read by an instrument a level up and by nothing else.
  assign ch_own_o       = ch_own;
  assign bus_changing_o = changing;
  assign cpu_memory_o   = is_memory || tv_fb;
  assign ch_memory_o    = ch_memory;

  always_ff @(posedge clk) begin
    if (rst) begin
      ch_own     <= 1'b0;
      owner_d    <= 2'd0;
      ch_ack_q   <= 1'b0;
      ch_memory  <= 1'b0;
      mp_own     <= 1'b0;
      mp_ack_q   <= 1'b0;
      mp_memory  <= 1'b0;
    end else begin
      ch_memory <= ch_memory_c;
      mp_memory <= mp_memory_c;
      owner_d   <= owner;
      ch_ack_q  <= ch_own && !changing && (memory_ack || !ch_memory);
      mp_ack_q  <= mp_own && !changing && memory_ack;
      if (!ch_own) ch_own <= ch_req && !cpu_rq && !mp_own;
      else if (ch_done) ch_own <= 1'b0;
      // The map's window waits for the processor AND for the channel, and it
      // lets go at the end of its word like the channel --- or at once if its
      // master dropped the request, which is a Unibus cycle abandoned
      // mid-flight and must not leave the Xbus held.
      //
      // **THE TAKE READS THE DECODE COMBINATIONALLY AND `bus_sel` READS IT
      // HELD, and the difference is a tick that would otherwise be a
      // hazard.**  `cadr_busint_regs.sv` puts `map_addr` up at the same edge
      // as `map_req`, where the channel's controller has its address up
      // first --- so `mp_memory`, a register off the decode, still holds the
      // PREVIOUS mapped cycle's answer on the tick the request arrives.
      // Taking the bus on that would give a non-memory page the grant with
      // `bus_sel` then falling under it, and the arm would stand until its
      // master gave up with the processor's own cycles waiting behind it.
      // Reading `mp_memory_c` here decides on this cycle's address; reading
      // the register in `bus_sel` keeps that held for the cycle, which is
      // what the channel does one line up.  `map_addr` is itself a register,
      // so this is a decode between two registers and not the map's ripple.
      if (!mp_own) mp_own <= map_req && mp_memory_c && !cpu_rq && !ch_own && !ch_req;
      else if (map_done || !map_req) mp_own <= 1'b0;
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
      .select_debug(select_debug),
      .ub_msyn    (ub_msyn),
      .ub_write   (ub_write),
      .ub_ssyn    (ub_ssyn),
      .arb_stage  (arb_stage),
      .busy       (busint_busy)
  );

  // `SELECT DEBUG`, which never leaves this module: the DBGOUT page makes it
  // out of the held match and the REQTIM counter takes the PROM's second
  // table for it.  This is the page-level wiring REQERR's own byte is joined
  // by, one page along.
  logic select_debug;

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
      .step       (step),
      .nop11      (nop11),
      .idebug     (idebug),
      .ldstat     (ldstat),
      .debug_ir   (debug_ir),
      .promdisable(promdisable),
      .errstop    (errstop),
      .stathenb   (stathenb),
      .mode_speed (mode_speed),
      .prog_reset (prog_reset),
      .prog_boot  (prog_boot),
      .n_boot     (n_boot),
      .no_auto_boot(no_auto_boot)
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
  // those reads are answered by nothing and MD takes zero, which is the
  // decided behavior for an unanswered cycle and not a fault --- but a
  // machine whose clock reads zero for ever is not one that can run a
  // scheduler.
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
  // else.  Nothing in this fabric pulls it: MIT's own source is
  // `-LM UNIBUS RESET`, which is the console's reset and the debug cable's
  // `-DEBUGEE RESET`, and neither is built --- the bus interface's own
  // registers below answer `0o766040`-`0o766076` but none of their bits
  // reaches this line.  So the one thing that asserts it here is `rst`, which
  // is `xbus_init`'s argument one bus along.  It is tied rather than made a
  // port because a port carrying nothing but `rst` at every level up to the
  // top level says less than this comment.
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
      .n_boot_star(n_boot_star),
      .mouse_lines(mouse_lines),
      .ser_reset  (ser_reset),
      .ser_mode1  (ser_mode1),
      .ser_mode2  (ser_mode2),
      .ser_cmd    (ser_cmd),
      .ser_tx_strobe(ser_tx_strobe),
      .ser_tx_data(ser_tx_data),
      .ser_tx_take(ser_tx_take),
      .ser_tx_done(ser_tx_done),
      .ser_rx_strobe(ser_rx_strobe),
      .ser_rx_data(ser_rx_data),
      .ser_rx_end (ser_rx_end),
      .ser_rx_parity(ser_rx_parity),
      .ser_rx_framing(ser_rx_framing),
      .ser_plugged(ser_plugged),
      .ser_status (ser_status),
      .ser_syn_face(ser_syn_face),
      .chaos_address(chaos_address),
      .chaos_tx_go(chaos_tx_go),
      .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid),
      .chaos_tx_word(chaos_tx_word),
      .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset),
      .chaos_csr  (chaos_csr),
      .chaos_rx_valid(chaos_rx_valid),
      .chaos_rx_word(chaos_rx_word),
      .chaos_rx_done(chaos_rx_done),
      .chaos_rx_bits(chaos_rx_bits),
      .chaos_rx_crc(chaos_rx_crc),
      .chaos_tx_done(chaos_tx_done),
      .chaos_tx_abort(chaos_tx_abort),
      .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits (chaos_bits),
      // **THE REQUEST GOES TO THE BUS INTERFACE AND NOT STRAIGHT TO THE
      // PROCESSOR**, which is what `0o766040` closed.  `LM INT` is `UB INT
      // OR XBUS INTR IN` at UBINTC 0E04, and muir's
      // `Machine::unibus_interrupt` takes a device's request only while
      // `ENABLE UB INTS` is set --- bit 10 of the interrupt control register.
      // That register had nowhere to live until `cadr_busint_regs.sv`, so
      // this pair used to leave the machine as observation outputs with a
      // note saying a gate here would raise an interrupt muir raises only
      // under a bit no program could set.  They go to that module now, and
      // out of the machine as well, where the top level still folds them.
      .intr_request(iob_intr),
      .intr_vector (iob_vector),
      .audio      (audio),
      .csr_face   (csr_face),
      .mouse_x    (mouse_x),
      .mouse_y    (mouse_y),
      .clock_ready(clock_ready),
      .interval   (interval)
  );

  // --- the bus interface's own registers, the third Unibus slave ----------
  //
  // The interrupt block at `0o766040`-`0o766076` and the Unibus map at
  // `0o766140`-`0o766176`: `Responder::Interface` in muir, as the diagnostic
  // block is, and `rtl/machine/cadr_busint_regs.sv` says which pages of the
  // drawings each is and what is deliberately not built.  `build/
  // busint_regs.pass` holds it to `busint::register` and
  // `Machine::interface_read` at its own seam and sweeps the decode over all
  // 262,144 addresses; what is new HERE is that a cycle of the machine's own
  // reaches it and that the three slaves never answer one address.
  //
  // **THE ERROR STATUS REGISTER IS WIRED TO THIS MODULE'S OWN TIMEOUT.**
  // `timed_out` is `NXM TIMEOUT` as `cadr_busint_xbus.sv` gives it, a level
  // standing for the cycle it belongs to, and `unibus` is the held decode
  // beside it: together they say which of the register's two NXM bits a
  // cycle nothing answered sets.  muir sets the bit at the decode, where it
  // can see there is no responder; the board sets it when the timer runs
  // out, and the two agree because a cycle nothing answers always runs the
  // timer out --- the same shape as the timeout race `cadr_busint_xbus.sv`
  // already records.
  cadr_busint_regs busint_regs (
      .clk       (clk),
      .rst       (rst),
      .ub_msyn   (sr_msyn),
      .ub_write  (sr_write),
      .ub_addr   (sr_addr),
      .ub_wdata  (sr_wdata),
      .ub_ssyn   (bir_ssyn),
      .ub_rdata  (bir_rdata),
      .ub_foreign(ub_foreign),
      .map_req   (map_req),
      .map_addr  (map_addr),
      .map_write (map_write),
      .map_wdata (map_wdata),
      .map_done  (map_done),
      .map_rdata (memory_rdata),
      .map_md    (map_md),
      .map_md_wdata(map_md_wdata),
      .map_md_done(ub_md_ack),
      .xbus_intr (xbus_intr),
      .iob_intr  (iob_intr),
      .iob_vector(iob_vector),
      .timed_out (timed_out),
      .unibus    (unibus),
      .ub_int    (ub_int),
      .err_status(regs_err_status),
      // The DBGOUT end of MIT's debug cable, this machine as the debugger.
      // It leaves the machine to `rtl/plumbing/cadr_dbg_cable.sv`, which is
      // the connector and the role; `select_debug` does not leave at all and
      // goes to the REQTIM counter above, which is the whole reason a debug
      // cycle may wait 11.05 microseconds where any other waits 4.25.
      .dbgout_req   (dbgout_req),
      .dbgout_wr    (dbgout_wr),
      .dbgout_a     (dbgout_a),
      .dbgout_dbd   (dbgout_dbd),
      .dbgout_ack   (dbgout_ack),
      .dbgout_dbd_in(dbgout_dbd_in),
      .dbgout_live  (dbgout_live),
      .select_debug (select_debug)
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

  cadr_tv #(
      .SYNC_PROM_HEX(SYNC_PROM_HEX)
  ) tv (
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
  assign dev_ack = !ch_own && !mp_own && (memory_ack || tv_ack || device_ack);
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
