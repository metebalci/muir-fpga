// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The processor and the memory path, joined by the cables.
//
// Two halves that had never met.  `cadr_microcycle.sv` is `src/rtl.rs` and was
// checked with `MD` driven from muir's trace; `cadr_memory_path.sv` is the
// address decode, the bus interface and the DDR bridge and was checked from a
// test master.  Both passed.  Neither was the machine: stage 3's `busint` and
// stage 4's VCTL1 had never been asked to agree with each other about a single
// cycle, though `MBUSY`, `MBUSY.SYNC`, `-MEMACK` and `-LOADMD` are signals both
// of them believe in.
//
// This is the join, and it is the five cables doing what they are for.  What
// changes is not the two modules --- neither is touched --- but where `MD`
// comes from: it stops being a column of the trace and starts being the word
// the fabric's own bus interface strobes into it, at the instant that
// interface says.  The stall timing then has to come out right with the real
// interface underneath instead of a trace column, which is a stronger claim
// than either half makes alone.
//
// **`-LOADMD` is gated by RDCYC on the processor's side**, which is where MIT
// put it: "-LOADMD equals MEMACK and RDCYC".  The interface asserts it on
// every acknowledgment, read or write --- `Busint` and `cadr_busint_xbus.sv`
// both do --- so a write leaves MD alone whatever the bridge has on `rdata`.
// `cadr_microcycle.sv` says the same at the register.
//
// WHAT IS STILL OUTSIDE.  The number of memory boards, which is the machine's
// configuration; the DDR itself, behind `mem_req`/`mem_done`; and any Xbus
// slave that is neither main memory, the disk nor the display, behind
// `dev_rq`/`device_ack`.  **The display is inside**, in
// `cadr_memory_path.sv`, its frame buffer being that module's bridge at a
// second base; `rtl/machine/cadr_tv.sv` is the register face and the interrupt.
// **THE DISK CONTROLLER'S FOUR REGISTERS ARE INSIDE TOO**,
// `cadr_disk_controller.sv`, which is what the
// boot PROM's 16,951 device cycles reach: 11,301 reads of the status register
// from microcycle 537,848 on and 5,650 writes of the disk address register.
// They used to be answered from the trace, and that was stimulus.  What is
// still outside the disk is its pack side, `rtl/plumbing/cadr_disk_pack.sv`, which is
// three AXI faces and belongs beside the PS7 in the top level; the drive seam
// and the block store's seam cross this boundary to reach it.
//
// **AND THE I/O BOARD IS INSIDE NOW**, `cadr_io_board.sv`, the second slave on
// the Unibus beside the diagnostic register block: the keyboard, the mouse,
// the microsecond counter, the sixty-cycle clock, the interval timer and the
// status register they share.  It is instantiated in `cadr_memory_path.sv`
// where the Unibus seam is, as the display is; what crosses this boundary is
// what MIT plugged into the card --- the keyboard's cable, the mouse's seven
// lines, the serial chip's ready line, the Chaosnet interface's request ---
// and what the card shows.  None of the four is driven yet and
// `boards/arty-z7-20/cadr_arty.sv` says which slice will drive each.

`default_nettype none

module cadr_machine #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    // MIT's TV sync PROM, for the display inside `cadr_memory_path`.
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex",

    // Whether the second display board --- the color TV --- is built into
    // this fabric at all.  `rtl/machine/cadr_memory_path.sv` says what it
    // does; a board whose part has no room for the slot builds with it zero
    // and is then a machine with one display, which is what
    // `busint::decode` describes and what every reference trace but
    // `color_tv.golden` was taken on.
    parameter int LMTV = 1,

    // **WHICH MACHINE THIS IS**: "cadr", MIT's, or "quux", the evolved CADR.
    // Every board's top level hands it down, and the make variable of the
    // same name sets it.  **EVERY QUUX ADDITION IS BEHIND IT AND ELABORATES
    // TO NOTHING FOR THE CADR**: the CADR's text stands in each `g_cadr`
    // branch as it stood before QUUX existed, and `make check` holds it to
    // muir's CADR.  What QUUX is, is muir's `Geometry::QUUX` and
    // `docs/quux.md` at the pin, summarized under "QUUX" below.
    parameter string MACHINE = "cadr",

    // **QUUX'S MICROCYCLE, IN TICKS** (H1a): K, and L more for an `ILONG`
    // instruction, muir's `TimingModel::Sync { cycle_ticks, ilong_ticks }`.
    // A board's own, from its top level: the fit is what says its longest
    // path settles in K ticks, and the board's constraint file states K.
    // Nothing on the CADR reads either; `cadr_microcycle.sv` has the rest.
    parameter int unsigned SYNC_K = 4,
    parameter int unsigned SYNC_L = 0
) (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- -XBUS.INTR, WHICH IS NOT A PORT ANY MORE AND USED TO BE.
    //
    // It was `input sintr`, driven from the trace in `tb/cadr_machine_tb.cpp`
    // and tied to `1'b0` in `boards/arty-z7-20/cadr_arty.sv`, because the two things that
    // put a level on the line --- the display's vertical interrupt and the
    // disk's request --- were computed inside this module and neither was
    // wired to it.  Both are inside now and the join is below, so the only
    // thing left of the port is an OBSERVATION output: `sintr_o` is the
    // level, for a check to compare and for the top level to fold.  The day
    // the I/O board or the Unibus arrives it brings an interrupt in, and
    // that is an input with something driving it rather than a stimulus port
    // nothing does.
    output var logic        sintr_o,

    // --- THE DISK'S DRIVE SEAM, eight unit slots of it.
    //
    // A drive is a thing on a cable and not a property of the controller, so
    // presence and the read-only switch are per unit and `Controller::timed`
    // --- whether the drive's own time is charged at all --- comes with them.
    // `tb/cadr_disk_tb.cpp` attaches one where the reference trace's `ATTACH`
    // row says; `boards/arty-z7-20/cadr_arty.sv` ties all three off and says what will
    // drive them. **A design with one drive always present is wrong**: with
    // the presence a constant, `<1>` any-attention stops being over all eight
    // and the status reads `1` the moment a program stores another unit
    // number, which MIT's boot PROM does 5,650 times.
    //
    // Nothing on this side of the seam fetches a block yet: `S_AXI_HP2` and
    // the block store are the channel's slice.
    input  var logic [7:0]  drive_present,
    input  var logic [7:0]  drive_read_only,
    input  var logic        drive_timed,

    // --- THE BLOCK STORE'S SEAM.
    //
    // The other half of the drive: a slot holds one block, its header, its
    // header checkword and its data checkword, and `rtl/plumbing/cadr_disk_pack.sv`
    // fills it over `S_AXI_HP2` --- the pack is a file Linux puts in DDR and
    // the block's address crosses over `M_AXI_GP0`.  That module sits
    // OUTSIDE this one, beside the memory port's adapter in `boards/arty-z7-20/cadr_arty.sv`
    // with `DDR=1`, because it is three AXI faces and a PS7 and this module
    // is the machine; with `DDR=0` the top level ties the seam off and the
    // store, the channel and the drive constant-fold.
    //
    // Both halves cross here now.  `store_rdata` is what the write-back
    // reads, a tick behind its address as a block RAM's read is; `store_miss`
    // is the controller saying the walk asked for a block the store does not
    // hold, and `ch_active` is its interlock --- the pack side must not touch
    // a slot while the channel is walking.  They used to be folded inside,
    // there being no master; a port on one side of a boundary and not the
    // other is what `dev_wdata` was.
    input  var logic        store_we,
    input  var logic [4:0]  store_slot,
    input  var logic [8:0]  store_addr,
    input  var logic [31:0] store_wdata,
    output var logic [31:0] store_rdata,
    output var logic        store_miss,
    output var logic        ch_active,
    // And the pack side's own half of the interlock: a block is in flight
    // through the seam, on this slot, and the controller looks its own slot
    // up again when a move is on it.
    input  var logic        store_busy,
    input  var logic [4:0]  store_busy_slot,
    // The request path and the cache's bookkeeping, straight through from
    // `cadr_disk_controller.sv`, whose ports say what each is: the block
    // the walk lacks, its posting, the wait, Linux's denial, the slot the
    // walk is on and the two things it did to it.
    output var logic        req_valid,
    output var logic [30:0] req_tag,
    output var logic        req_post,
    output var logic        ch_waiting,
    input  var logic        store_deny,
    output var logic [4:0]  ch_slot,
    output var logic        ch_wrote,
    output var logic        ch_hit,

    // --- THE I/O BOARD'S CABLES, straight through to `cadr_memory_path`.
    //
    // The card is a Unibus slave inside this machine; these are the things
    // plugged into it, and their header is at the instance there.  A port
    // rather than a tie-off inside for `drive_present`'s reason: what is on
    // a cable is not a property of the board it plugs into, and a check has
    // to be able to move it.
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    input  var logic [6:0]  mouse_lines,

    // --- `-BOOT2`, THE LIGHT PANEL'S BUTTON.
    //
    // `mit/cadrwd/icmem3.wlr` puts `-BOOT2` on `1AJ2-03` and the MBCPIN
    // drawing marks that connector "TO LIGHT PANEL", beside the parity-error
    // and run lamps.  So a CADR boots three ways and they meet on the
    // processor board, at the 74S02 at OLORD2 1A07: `-BOOT1` from the
    // keyboard by way of the I/O board and the Unibus, `-BOOT2` from the
    // button, and `PROG.BOOT` from the other machine over the debug cable.
    // The processor cannot tell which was pressed.
    //
    // Active low and a level, because that is what a pulled-up line taken
    // down by a momentary switch is: whatever presses it holds it for as long
    // as the finger is there, and the machine sits at the boot trap until it
    // is let go.  The board gives it two sources, a push-button and the
    // console's own register; muir's prompt `boot` presses this one.
    input  var logic        n_boot2,

    // --- **THE NO-AUTO-BOOT SWITCH.**
    //
    // A CADR whose power has just come on has `RUN` clear and runs nothing:
    // the button on its light panel is what starts it.  This says which of
    // those two states the machine comes out of reset in --- high leaves `RUN`
    // clear, low presets it, which is what every trace here starts from ---
    // and it is read at the reset arm of `cadr_spy_registers.sv` and at no
    // other instant, so moving it under a running machine does nothing until
    // the next reset.  `-BOOT` presets `RUN` whatever it says, because the
    // button is what takes the hold off.
    //
    // It is a LEVEL and not a pulse, and it is the board's: on the Arty Z7-20
    // it is SW0.  muir's `--no-auto-boot` leaves the same machine in the same
    // state, and the console reports both this level and the value the machine
    // actually came up with.
    input  var logic        no_auto_boot,

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
    // counting bits can see: `cadr_io_board.sv`'s header says what each is
    // for and what holds it.
    input  var logic        ser_rx_end,
    input  var logic        ser_rx_parity,
    input  var logic        ser_rx_framing,
    input  var logic        ser_plugged,
    output var logic [7:0]  ser_status,
    // The 2651's SYN1, SYN2 and DLE registers and their pointer: nothing
    // reads them back, so without a reader synthesis trims them away.
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
    input  var logic        chaos_rx_lost,
    input  var logic        chaos_tx_done,
    input  var logic        chaos_tx_abort,
    input  var logic        chaos_cbl_busy,
    output var logic [11:0] chaos_bits,
    // `-UB INTR` and `-UB BR5`.  They go to `cadr_busint_regs.sv` inside the
    // machine, where `ENABLE UB INTS` decides whether the interface takes the
    // request, and the taken interrupt is the Unibus half of `sintr_o` below.
    // They leave as observations besides, which is what the top level folds;
    // the note at the card's instance in `cadr_memory_path.sv` says what that
    // used to cost.
    output var logic        iob_intr,
    output var logic [7:0]  iob_vector,
    output var logic        audio,
    output var logic [7:0]  csr_face,
    output var logic [11:0] mouse_x,
    output var logic [11:0] mouse_y,
    output var logic        clock_ready,
    output var logic [15:0] interval,

    // --- how many 64K-word memory boards are fitted, 1 to 60
    input  var logic [6:0]  boards,

    // --- AND WHICH DISPLAY BOARDS ARE, which is the same kind of fact: what
    // is in the backplane rather than what the machine is doing.  `tv_lispm`
    // says the first display is a LISPM TV rather than a SIMPLE TV, muir's
    // `--tv-board`; `color_tv` fits the second board, the color TV at
    // `0o17200000`, muir's `--color-tv`.  Both come from the console face ---
    // `rtl/plumbing/cadr_console.sv`'s page 2 word 33 --- and the maps below
    // go back the other way.  `rtl/machine/cadr_tv.sv` is the board.
    input  var logic        tv_lispm,
    input  var logic        color_tv,
    input  var logic [3:0]  tv_map_a,
    output var logic [23:0] tv_map_q,
    output var logic [23:0] tv_color_map_q,

    // And the color board's map on a second port, for the display output, which
    // is the off-board map hardware `lmtv.order` describes.  See
    // `rtl/machine/cadr_tv.sv` for why the board offers two.
    input  var logic [3:0]  disp_map_a,
    output var logic [23:0] disp_color_map_q,

    // --- the machine, as `Rtl::signals` and `Rtl::spy` name it
    output var logic [13:0] pc,
    output var logic [13:0] lpc,
    output var logic [13:0] opc,
    output var logic [31:0] st,
    output var logic [47:0] ir,
    output var logic [31:0] a,
    output var logic [31:0] m,
    output var logic [31:0] alu,
    output var logic [31:0] r,
    output var logic [31:0] ob,
    output var logic [31:0] q,
    output var logic [9:0]  dc,
    output var logic [25:0] lc,
    output var logic [31:0] vma,
    output var logic [31:0] md,
    output var logic        vmaok,
    output var logic        jcond,
    output var logic        nop,
    output var logic        pcs1,
    output var logic        pcs0,
    output var logic        iwrited,
    // **`-PROMENABLE` AT PCTL 1C19: THE PROM'S OWN SELECT.**  A board drives
    // the blue lamp from this rather than from `promdisable` below, which is
    // the mode register's bit.  The two are different nets and the difference
    // is visible: the select follows the PC, so it drops on every
    // control-store write while the PROM is loading and the lamp sits a
    // little under full brightness, and it is dark for good once PROMDISABLE
    // is set.  `cadr_microcycle.sv` has it at the assignment.
    output var logic        promenable,
    output var logic        clock_edge,

    // --- what the bus interface reports, for a check to watch
    output var logic        wrcyc,        // WRCYC, so a check can see the direction

    // --- the Xbus, for a slave that is neither main memory nor the disk
    output var logic        device,       // the decode put this cycle outside memory
    output var logic        dev_rq,       // -XBUS.RQ
    output var logic        dev_write,
    output var logic [21:0] phys,         // the address it is asking about
    // **THE WORD, WHICH THIS BOUNDARY USED TO DROP.**  `cadr_memory_path.sv`
    // has it and its own comment calls `phys` and `wdata` "the address and
    // the word"; the machine brought out the address and not the word, so a
    // slave hung on this seam could be written to and never see what.  No
    // slave exists yet, which is why it cost nothing and why it is worth
    // fixing now: the failure would appear in the slave and the cause would
    // be here.  Same class as `md` staying driveable after it became an
    // output --- a port that exists on one side of a boundary and not the
    // other.
    output var logic [31:0] dev_wdata,    // MEM<31:0> out of the cpu
    // -XBUS.ACK and MEM<31:0> from a slave out there.  Joined with the disk
    // controller's below, as the open-collector line joins them; the disk
    // answers only its own four addresses, so the two cannot both answer one
    // cycle.  `device_rdata` shows through on a WRITE, where no slave drives
    // the data lines --- see the note at the instance.
    input  var logic        device_ack,
    input  var logic [31:0] device_rdata,
    output var logic        promdisable,  // PROMDISABLE, as the mode register holds it
    output var logic        ub_msyn,      // -UB MSYN, so a check can see the Unibus run
    output var logic        ub_ssyn_o,
    output var logic [2:0]  arb_stage,
    output var logic        n_memrq_o,
    output var logic        n_memack_o,
    output var logic        n_memgrant_o,
    output var logic        mbusy_o,
    output var logic        mbusy_sync_o,
    output var logic [17:0] ub_addr_o,
    output var logic [15:0] ub_rdata_o,
    // Which slave is pulling `-UB SSYN`: bit 0 the diagnostic register block,
    // bit 1 the I/O board.  See the port in `cadr_memory_path.sv`.
    output var logic [2:0]  ub_ssyn_by,
    output var logic        n_loadmd_o,
    output var logic        rdcyc_o,
    output var logic        nxm,          // Xbus space with nothing in it
    output var logic        unibus,       // the Unibus, which is its own slice
    output var logic        memstart,     // MEMSTART, which also addresses the map
    output var logic        timed_out,
    // OLORD1's three, for the board's lamps: the machine's own run signal as
    // a level, and the two ways it stops itself.  See the note at
    // `cadr_microcycle.sv`'s ports.
    output var logic        machrun,
    output var logic        errhalt,
    output var logic        stathalt,
    // **`-BOOT` ITSELF, WHICH LEAVES THE MACHINE BECAUSE THE BOARD HAS A LAMP
    // TO CLEAR.**  The 74S02 at OLORD2 1A07 makes it out of all three boot
    // lines and the processor cannot tell which was pressed; neither can
    // anything out here, which is the point.  It is active low, like the
    // three it is made of.  The error lamp is cleared by it, so a machine
    // booted at the button starts with a clean lamp however it stopped, and
    // the board does not have to know that a keyboard chord is also a boot.
    output var logic        n_boot_o,

    // --- THE CONSOLE'S HALF OF THE DIAGNOSTIC BUS.
    //
    // The sixteen registers at Unibus `0o766000` are the machine's, and
    // `cadr_spy_registers.sv` inside `cadr_memory_path` holds them.  What is
    // outside is the console itself, `rtl/plumbing/cadr_console.sv`, an AXI slave on
    // `M_AXI_GP1` --- an AXI face and nothing to do with the machine, beside
    // the PS7 in `boards/arty-z7-20/cadr_arty.sv`, exactly as the disk's pack side sits
    // there.  So this seam is a second Unibus master asking the arbiter
    // inside for the diagnostic bus.  With no console the top level ties
    // `con_req` and `con_msyn` low and the whole of it folds.
    input  var logic        con_req,
    output var logic        con_gnt,
    input  var logic        con_msyn,
    input  var logic        con_write,
    input  var logic [17:0] con_addr,
    input  var logic [15:0] con_wdata,
    output var logic        con_ssyn,
    output var logic [15:0] con_rdata,

    // --- THE DEBUG CABLE, which leaves this machine as MIT's own wires.
    //
    // A CADR is debugged by another CADR: the debugger's DBGOUT connector
    // goes to this one's DBGIN connector over twenty-one wires, and
    // `rtl/machine/cadr_dbgin.sv` inside `cadr_memory_path` is that page ---
    // the 74S139 at DBGIN 0A15, the modifier register, the two address
    // latches, the error-status driver, and the debug master's place on this
    // machine's Unibus.  What crosses HERE is the cable, and nothing else.
    //
    // The carrier that puts the cable on a general-purpose port is
    // `rtl/plumbing/cadr_debug_window.sv`, beside the PS7 in
    // `boards/arty-z7-20/cadr_arty.sv` exactly as the console and the disk's
    // pack side sit there.  With no carrier the top level holds `dbg_in_req`
    // low and the whole of the page folds to its idle state.
    //
    // `dbg_in_req` high means `-DEBUG IN REQ` is DOWN, muir's `fabric::REQ`.
    input  var logic        dbg_in_req,
    input  var logic        dbg_in_wr,
    input  var logic [1:0]  dbg_in_a,
    input  var logic [15:0] dbd_in,
    output var logic        dbg_in_ack,
    output var logic [15:0] dbd_out,
    output var logic [1:0]  dbd_oe,
    // **AND THE OTHER END OF THE SAME CABLE: THE DBGOUT PAGE.**  This machine
    // as somebody else's debugger, which is CC on this board writing
    // `0o766100`-`0o766137`.  `rtl/machine/cadr_busint_regs.sv` holds those
    // four registers; what leaves here is the four control lines and the
    // sixteen data lines they drive, and what comes back is the
    // acknowledgment and the lines RESOLVED --- a byte nobody drives reads
    // as ones, the SIP at DBGIN 0A22 being on the far board.
    //
    // **`dbgout_live` IS THE WHOLE OF THE DIFFERENCE BETWEEN muir's TWO
    // ARMS.**  `debug_cable` false answers the cycle at `-UB MSYN` with the
    // pull-ups, and true waits for `DEBUG OUT ACK`.  So a top level with no
    // connector ties it low, `dbgout_dbd_in` to all ones and `dbgout_ack`
    // low, and this machine reads ones from its debug registers and carries
    // on --- which is what MIT's board does with a bare connector.
    //
    // These SEVEN used to be tied off inside this module, with a note saying
    // the wrapper change and its wiring were one commit.  This is that
    // commit: `rtl/plumbing/cadr_dbg_cable.sv` on Pmod JA is what they reach.
    output var logic        dbgout_req,
    output var logic        dbgout_wr,
    output var logic [1:0]  dbgout_a,
    output var logic [15:0] dbgout_dbd,
    input  var logic        dbgout_ack,
    input  var logic [15:0] dbgout_dbd_in,
    input  var logic        dbgout_live,
    // The modifier register's two effects.  `debuggee_reset` is bit 1, a
    // LEVEL that is this processor's power-on reset --- it goes out here and
    // comes back as `rst`, which the top level makes out of the board's own
    // reset, the console's pulse and this.  `timeout_inhibit` is bit 2 and
    // nothing consumes it yet; `cadr_memory_path.sv` says why at the
    // instance.
    output var logic        debuggee_reset,
    output var logic        timeout_inhibit,
    // And the reset the DBGIN page takes, which is NOT this module's `rst`.
    // `debuggee_reset` is modifier bit 1 and the top level joins it INTO
    // `rst`; a page reset by its own bit 1 clears the bit that is clearing
    // it, and MIT's "write a 1 here then write a 0" could not be written.
    // `cadr_memory_path.sv` says it at length at the instance.  On a board
    // with no carrier this and `rst` are the same net.
    input  var logic        dbg_rst,
    // **AND THE THREE REGISTERS THAT ARE NOT ON THAT BUS.**  MIT's sixteen
    // carry `IR`, `OPC`, `PC`, `OB`, the two flag words, `M`, `A` and `ST`
    // and nothing else, so neither the virtual address register nor `Q` nor
    // `MD` can be read through `cadr_spy_registers` at all.  They leave here
    // already captured at the microcycle boundary ---
    // `rtl/machine/cadr_console_state.sv`
    // below, instantiated inside this module ON PURPOSE, because a register
    // sampling `vma` from outside `cadr_machine` is outside the reach of
    // `rtl/plumbing/xilinx7/cadr_machine.xdc` and gets one tick for a path the file relaxes to
    // fifteen.  That is the -12.837 ns the console's own read-back met.
    //
    // **`md` IS ALSO A PLAIN OUTPUT OF THIS MODULE, AND `con_md` IS NOT THAT
    // PORT.**  `md` above is the datapath wire a check watches; `con_md` is
    // the same register captured at the boundary for a console that is a
    // level up and outside the constraints.  A console reading the port would
    // be the -12.837 ns shape again, which is the whole reason there are two.
    output var logic [31:0] con_vma,
    output var logic [31:0] con_q,
    output var logic [31:0] con_md,

    // --- **AND THE READOUT, WHICH IS NOT A REGISTER BUT A WINDOW.**  The
    // machine's memories --- the control store, the boot PROM, the A and M
    // scratchpads, the pushdown buffer, the micro-stack, the dispatch
    // memory, both levels of the map, the OPC shift register --- and a
    // table of the processor's own registers that the diagnostic bus has no
    // register for.  `con_ro_addr` names a word, `con_ro_data` is that word
    // three ticks later and `con_ro_echo` is the address it was read at.
    //
    // The readout itself is the last section of `cadr_microcycle.sv`, where
    // the memories are; the whole argument for a second read port rather
    // than a borrowed one is there.  What matters here is that the address
    // is registered INSIDE that module and the data and the echo leave it
    // as registers, which is `cadr_console_state.sv`'s rule and the reason
    // this port is three wires and not a memory interface: a register in
    // `rtl/plumbing/cadr_console.sv` reaching an array in here would be the
    // -12.837 ns that module's header records, with a deeper cone.
    input  var logic [17:0] con_ro_addr,
    output var logic [47:0] con_ro_data,
    output var logic [17:0] con_ro_echo,

    // --- PS DDR3, behind the AXI adapter
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata,
    // QUUX's line fill (contract Q6): four words at a 16-byte boundary, two
    // 64-bit beats, back on `mem_rline` with the lowest address in bits
    // 31:0.  The CADR never raises `mem_line`, and a board that builds only
    // the CADR ties `mem_rline` to zero.
    output var logic        mem_line,
    input  var logic [127:0] mem_rline,
    // QUUX's memory port is idle and its write buffer empty: what the host
    // waits for, after a halt, before it reads main memory (the contract's
    // "a halt drains the write buffer").  Always up on the CADR.
    output var logic        mem_drained,

    // --- AND WHAT THE PROCESSING SYSTEM ITSELF ANSWERED, which is for the
    // transaction audit below and reaches nothing else in this module.
    //
    // **WHY AN INSTRUMENT INSIDE THE MACHINE NEEDS TWO WIRES FROM OUTSIDE
    // IT.**  `rtl/plumbing/cadr_axi_master.sv` is a level ABOVE this module,
    // in `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr`, so a transaction born in
    // the adapter raises no second `mem_req` and every clause anchored on one
    // is blind to it.  The port's own handshakes are not blind to it: these
    // are `rvalid && rready && rlast` and `bvalid && bready` at the `PS7`
    // boundary, which is exactly where `rtl/plumbing/cadr_mem_count.sv` counts
    // them and for the same reason --- a fabric that never issued a
    // transaction cannot fabricate a `B` or an `R`.
    //
    // Tied low on every board that has no `S_AXI_HP0` behind the machine, and
    // the audit's word 8 is what tells that silence from a port answering
    // correctly.
    input  var logic        port_read_ack,
    input  var logic        port_write_ack
);

  // A machine this file does not know stops elaboration, in every tool,
  // rather than building the CADR under a name nobody meant.
  if (MACHINE != "cadr" && MACHINE != "quux") begin : g_unknown_machine
    $error("cadr_machine: MACHINE is \"%s\", and it is \"cadr\" or \"quux\"", MACHINE);
  end

  // ------------------------------------------------------------------ QUUX
  //
  // **QUUX, THE EVOLVED CADR, AS muir'S `Geometry::QUUX` HAS IT AT THE PIN**,
  // revision 4.  Each difference is built where the CADR's own part is, behind
  // `MACHINE`, and each module says in its header what holds it:
  //
  //   the six-bit level-1 map entry, read in `MAP(MD)<29:24>` and written
  //   from `VMA<31:27>` and `VMA<24>`, and the 2,048-entry level 2
  //                                                  `cadr_microcycle.sv`
  //   the MACHINE-ID in functional sources 16 and 36     `cadr_microcycle.sv`
  //   the feature page at `17377000`                     `quux_feature_page.sv`
  //   the 16K-word PDL buffer, its pointer and index 14 bits
  //                                                  `cadr_microcycle.sv`
  //   the boot PROM, version 1000, which is the image `PROM_HEX` names: every
  //   QUUX build and check hands it `build/boot_prom.quux.hex`
  //   MONO TV in place of the SIMPLE and LISPM TV, 1280 by 1024, and no
  //   color board                                     `quux_mono_tv.sv`
  //   `MUL` and `DIV` in one instruction each, and the divider's hold
  //                                   `quux_muldiv.sv`, `cadr_microcycle.sv`
  //   the processor's tick: destinations 3 and 4, source 17 and the
  //   interrupt                                        `cadr_microcycle.sv`
  //
  // The values every part reads are decided once, here.
  localparam bit          QUUX       = MACHINE == "quux";
  // `(0x5155 << 16) | (8 << 4) | 4`: the signature, hardware revision 8 ---
  // the device registers of contract Q7, after contract Q6's memory port ---
  // and processor type 4, `Geometry::QUUX.machine_id`.
  localparam logic [31:0] MACHINE_ID = 32'h5155_0084;
  // MONO TV at the size every QUUX bitstream builds: 1280 by 1024, one bit
  // a pixel, 40 words a line at `17000000`.
  localparam int unsigned MONO_TV_WIDTH  = 1280;
  localparam int unsigned MONO_TV_HEIGHT = 1024;

  // The cables, named at both ends as `cadr_cables.map` has them.
  logic        mclk;
  logic        n_memrq, rdcyc;
  logic [31:0] wdata, rdata;
  // The console's registers, which now live on the bus interface where a
  // console can write them, and reach the processor as signals.
  logic [3:0]  spy_eadr;
  logic [15:0] spy_rdata;
  logic        run, errstop, stathenb, prog_reset, prog_boot;
  // `-BOOT1`: the I/O board's `-BOOT*`, which reaches the processor across
  // the backplane, and which `cables.txt` pairs with the processor's
  // `1AJ1-12`.
  //
  // **THE TWO ENDS SIT ON DIFFERENT PINS, AND ONE HAND-RUN WIRE JOINS
  // THEM.**  The I/O board sends `-BOOT*` out of its slot on `CP1` and the
  // bus interface takes `-LM BOOT` in on `CR1` at its own slot, so the line
  // is not simply bused across the cage.  Two of MIT's own files say why,
  // and both are read rather than reasoned from:
  //
  //   `mit/cadr1/dubspc.wires`  the wire list for the double SPC backplane
  //                             the I/O board sits in.  It buses the power
  //                             rails and the Unibus across every slot and
  //                             names NEITHER `CP1` NOR `CR1` anywhere, so
  //                             both pins are free there --- and it says in
  //                             its own prose that device-specific wiring is
  //                             added by hand afterwards and is not in it.
  //   `mit/cadr1/xspec.text.3`  the Xbus specification.  Its "SLOT 11, BUS
  //                             INTERFACE SLOT" table is the bus interface's
  //                             own pin list, and there `CP1` is
  //                             `-XBUS.SYNC`, so the boot line could not
  //                             have arrived on the pin the I/O board sends
  //                             it out on; `CR1` is marked bused through and
  //                             otherwise uncommitted, which is how the Xbus
  //                             power reset is marked at the same slot.
  //
  // So `-BOOT*` leaves a free pin of the I/O board's slot, `-LM BOOT` sits
  // on a bused line at the bus interface's, and one wire run by hand joins
  // them --- the way the console's video and sync pairs were run between
  // boards in this same cage, landing on differently named pins at the two
  // ends.  **THAT WIRE IS ASSUMED AND NOT SHOWN.**  No file in MIT's
  // material carries it; muir's `src/cable.rs` makes the same assumption and
  // keeps an unverified marker at it, and this fabric rests on muir's
  // reading.  What would reopen it is a cage, or a photograph of one,
  // showing something other than a wire between the I/O slot's `CP1` and the
  // bus interface slot's `CR1`.
  //
  // Nothing downstream turns on the answer: either way the level arrives
  // here, and the gate that makes `-BOOT` of it is at the bottom of this
  // file.
  logic        n_boot1;
  // The clock control register's other four bits and the debug IR, made on
  // the bus interface and read by the processor: a single step and the
  // forced microinstruction CC reads a scratchpad with.
  logic        step, nop11, idebug, ldstat;
  logic [47:0] debug_ir;
  logic [1:0]  mode_speed;
  logic        n_memgrant, n_memack, n_loadmd;
  // `UB MD LOAD` at REQLM 0B17: the register block in `cadr_memory_path`
  // decodes a foreign master's mapped write into `MD` and the processor takes
  // the word.  Three wires under one roof, which is what this module is for.
  logic        ub_md_req, ub_md_ack;
  logic [31:0] ub_md_data;

  // **`-XBUS.INTR` IS WHOLLY IN THE FABRIC NOW.**  `LM INT` is `UB INT OR
  // XBUS INTR IN` at UBINTC 0E04, and the Xbus line is the display's
  // vertical interrupt ORed with the disk's request.  The display's is made
  // in `cadr_memory_path.sv`'s `cadr_tv`; the disk's is
  // `cadr_disk_controller.sv`'s `intr`, which that module used to compute
  // and keep.  The join is one gate before the 74S175 at LCC 3E12, which
  // `cadr_microcycle.sv` registers at the microcycle edge, and it is here
  // because that is where the backplane puts it.
  //
  // **THE BOARD IS WHY.**  On 2026-09-10 the machine restored a whole System
  // band off its pack and then spun for ever in `AWAIT-DISK` at microcode
  // `0o25221`: `A-DISK-BUSY` is cleared in one place, `DISK-COMPLETION-OK`,
  // reached only from the Xbus interrupt handler, and JCOND at `0o25222`
  // read 0 with -VMAOK permitted --- `sint` was 0 and the interrupt was not
  // arriving.  The disk had finished and the wire did not exist.
  //
  // WHAT HOLDS EACH HALF.  `build/disk.pass` holds the disk's `intr` row for
  // row against `Controller::interrupt()`; `build/tv.pass` holds the
  // display's to the tick; `build/machine.pass` holds THE JOIN, comparing
  // `sintr_o` against `rtl.golden`'s own `sintr` column --- muir's
  // `Machine::xbus_interrupt()`, the same OR --- on all 600,000 microcycles.
  // **That column is zero throughout and the zero is a live one**: the boot
  // PROM never writes the disk's command register and never enables the
  // display, so both enables are off, while the controller answers 11,301
  // status reads with `0x2321`, `<0>` set --- not-active true on every one of
  // them.  The interrupt's own term is therefore true all the way through and
  // only the enable holds the level down, which is what makes a fabric that
  // ignored the enable, or inverted either half of this gate, fail here.
  // **What no check reaches is the gate made an AND**, `disk_intr &&
  // tv_intr`: with neither request ever raised by either reference program,
  // `0 || 0` and `0 && 0` are the same zero, and it survives `machine`,
  // `ddr_boot` and `probe` alike --- measured.  Dropping an operand outright
  // does not even build, the dropped signal being read nowhere else here.
  // The section note in `mutations/list.txt` carries both measurements and
  // what would close them, which is a machine-level reference whose program
  // enables an interrupt and is not the band.
  //
  // **AND THE UNIBUS HALF OF `LM INT` IS HERE NOW TOO.**  Until
  // `cadr_busint_regs.sv` the Xbus line WAS `sintr_o`, because the other
  // operand of MIT's gate --- `UB INT`, a Unibus interrupt taken --- is
  // taken only under `ENABLE UB INTS`, bit 10 of a register this fabric did
  // not have.  It has it now, so this is the whole of `LM INT` at last:
  // `Machine::interrupt()` is `xbus_interrupt() || unibus_interrupt().
  // is_some()` and this line is that expression.  `xbus_intr` goes back INTO
  // `cadr_memory_path` because the interface reads it in bit 14 of the
  // interrupt status register, which is what the backplane's one wire does.
  //
  // **Neither reference program raises either Unibus request**, the boot PROM
  // never enabling an interrupt and the band's card being unread, so
  // `ub_int` is zero throughout both traces and `sintr_o` is what it was.
  // That is the same shape as the AND equivalence above and is recorded with
  // it rather than filed as a hole: `build/busint_regs.pass` is what holds
  // `ub_int` itself, over a program written to move it.
  logic tv_intr;
  logic disk_intr;
  logic xbus_intr;
  logic ub_int;
  assign xbus_intr = disk_intr || tv_intr;
  // And on QUUX its tick, `Machine::interrupt`'s third term, which is the
  // processor's own and so reaches neither the Xbus nor the bus interface's
  // interrupt status; `cadr_microcycle.sv` says when it is up.  Zero on the
  // CADR.
  logic tick_irq;
  // And QUUX's register page's own three, the keyboard, the mouse and the
  // network (`quux_feature_page.sv`'s `irq`), each a term of
  // `Machine::interrupt_at` on QUUX.  Zero on the CADR.
  logic page_irq;
  // QUUX's register page's wires into the memory path and the processor
  // (`cadr_memory_path.sv`'s ports say what each is).
  logic [1:0]  clock_pending;
  logic [2:0]  page_err, mouse_buttons;
  logic        page_err_clear, page_errstop_we, page_errstop;
  logic        page_ch_land, page_ch_wr, chaos_ireq;
  logic [2:0]  page_ch_which;
  logic [15:0] page_ch_wdata, page_ch_rdata;
  logic        iob_n_boot1;
  logic [7:0]  iob_csr_face;
  // MONO TV's black-on-white, for the register page's readout below.
  logic        mono_bow;
  // **ON QUUX THE UNIBUS INTERRUPT DOES NOT REACH THE PROCESSOR**, QUUX
  // having no Unibus (contract Q5, `Machine::interrupt_at`'s
  // `geometry.unibus`): its devices interrupt through the register page.
  // **`-XBUS INIT` AND `-UB INIT`: THE POWER-ON RESET, AND THE PROCESSOR'S
  // `PROG.UNIBUS.RESET`.**  On the board the bus interface's `RESET` (the
  // 74S10 at DBGIN 0A14) is made from `-LM UNIBUS RESET`, the processor's
  // `PROG.UNIBUS.RESET` (`INTERRUPT-CONTROL<28>`, over the cable as
  // `-BUS.RESET`), the debug cable's `-DEBUGEE RESET` and `UNIBUS INIT IN`,
  // and it reaches every board on the backplane.  muir's `Rtl` calls
  // `Machine::bus_reset` when the `INTERRUPT-CONTROL` write that raises the
  // bit lands, on either machine, and each board clears once what its own
  // reset pin clears: the display boards' vertical flag, the disk's command
  // and errors (the CADR's controller and QUUX's block-disk), and the I/O
  // board's interrupt enables, Chaosnet interface and serial line.  So the
  // bit's rise is one tick of init here, the tick after the edge that takes
  // the write.  `rst` asserts it too, and the top level makes `rst` of the
  // board's reset, the console's pulse and the debug cable's reset.
  //
  // **AND THE INTERRUPT IS THE RESET BOARDS' AT THE WRITE'S OWN EDGE.**
  // muir takes `SINTR` at the end of the microcycle whose write raised the
  // bit, after the boards have cleared, where the boards here clear a tick
  // after the edge that ends it.  So in the microcycle that writes the bit
  // (`prog_unibus_reset_rising`) the terms those boards make are held off:
  // the Xbus line's whole, the display's flag and the disk's done, and on
  // QUUX the network's term of the register page.  This is `quux_clocks.sv`'s
  // shape for a write that takes its own flag down.  In the one tick between
  // that edge and the boards' clearing the terms are up again, and nothing
  // takes them there: `SINTR` is taken at the processor's edge alone, a
  // microcycle on.  The Unibus line is left as it is; nothing here compares
  // it across a reset.
  logic prog_unibus_reset, prog_unibus_reset_rising, prog_unibus_reset_q;
  logic bus_init;
  always_ff @(posedge clk)
    prog_unibus_reset_q <= rst ? 1'b0 : prog_unibus_reset;
  assign bus_init = rst || (prog_unibus_reset && !prog_unibus_reset_q);

  assign sintr_o   = (xbus_intr && !prog_unibus_reset_rising) || (ub_int && !QUUX) || tick_irq || page_irq;

  cadr_microcycle #(
      .PROM_HEX(PROM_HEX),
      .MACHINE(MACHINE),
      .MACHINE_ID(MACHINE_ID),
      .SYNC_K(SYNC_K),
      .SYNC_L(SYNC_L)
  ) processor (
      .clk         (clk),
      .rst         (rst),
      .n_boot      (n_boot),
      .machrun_o   (machrun),
      .errhalt_o   (errhalt),
      .stathalt_o  (stathalt),
      .run         (run),
      .no_auto_boot(no_auto_boot),
      .step        (step),
      .nop11       (nop11),
      .idebug      (idebug),
      .ldstat      (ldstat),
      .debug_ir    (debug_ir),
      .promdisable (promdisable),
      .errstop     (errstop),
      .stathenb    (stathenb),
      .mode_speed  (mode_speed),
      .spy_eadr    (spy_eadr),
      .spy_rdata   (spy_rdata),
      .sintr       (sintr_o),
      .tick_irq    (tick_irq),
      .clock_pending(clock_pending),
      .prog_unibus_reset_o(prog_unibus_reset),
      .prog_unibus_reset_rising(prog_unibus_reset_rising),
      .n_memack    (n_memack),
      .n_memgrant  (n_memgrant),
      .n_loadmd    (n_loadmd),
      .rdata       (rdata),
      .cached      (cached),
      .mem_drained (mem_drained),
      .ub_md_req   (ub_md_req),
      .ub_md_data  (ub_md_data),
      .ub_md_ack   (ub_md_ack),
      .pc          (pc),
      .lpc         (lpc),
      .opc         (opc),
      .st          (st),
      .ir          (ir),
      .a           (a),
      .m           (m),
      .alu         (alu),
      .r           (r),
      .ob          (ob),
      .q           (q),
      .dc          (dc),
      .lc          (lc),
      .vma         (vma),
      .vmaok       (vmaok),
      .jcond       (jcond),
      .nop         (nop),
      .pcs1        (pcs1),
      .pcs0        (pcs0),
      .iwrited     (iwrited),
      .promenable  (promenable),
      .md          (md),
      .phys        (phys),
      .wdata       (wdata),
      .mclk        (mclk),
      .n_memrq     (n_memrq),
      .mbusy_o     (mbusy_o),
      .mbusy_sync_o(mbusy_sync_o),
      .memstart    (memstart),
      .rdcyc       (rdcyc),
      .wrcyc       (wrcyc),
      .clock_edge  (clock_edge),
      .ro_addr     (con_ro_addr),
      .ro_data     (proc_ro_data),
      .ro_echo     (con_ro_echo)
  );

  // The virtual address register, `Q` and `MD` for the console, captured at
  // the microcycle boundary.  It is four lines and it is still a module of its
  // own, for the reason `rtl/machine/cadr_console_bus.sv` gives at the same shape:
  // `tb/cadr_console_harness.sv` instantiates THIS module and not a copy of
  // it, so the check holds what the board has.
  cadr_console_state console_state (
      .clk     (clk),
      .rst     (rst),
      .mclk    (mclk),
      .vma     (vma),
      .q       (q),
      .md      (md),
      .con_vma (con_vma),
      .con_q   (con_q),
      .con_md  (con_md)
  );

  // QUUX's memory port (contract Q6): the cycle is main memory's; block-disk
  // answered a write of one of its registers, which is muir's
  // `dma_written` and invalidates the cache at the next grant; the cache's
  // counts; and the Xbus bridge's own seam, for the audit.
  logic        cached, bd_written;
  logic [31:0] cache_hits, cache_misses;
  logic        br_req, br_write, br_done;
  logic [31:0] br_addr, br_wdata;

  cadr_memory_path #(
      // QUUX has no color board: the color TV is a LISPM TV strapped
      // elsewhere, and QUUX's bitstream has neither of the CADR's boards.
      .LMTV(QUUX ? 0 : LMTV),
      .SYNC_PROM_HEX(SYNC_PROM_HEX),
      .MACHINE(MACHINE),
      .MONO_TV_WORDS(MONO_TV_WIDTH / 32 * MONO_TV_HEIGHT),
      .SYNC_K(SYNC_K)
  ) memory (
      .clk        (clk),
      .rst        (rst),
      // `-XBUS INIT`, as the disk takes it below: the power-on reset and
      // `PROG.UNIBUS.RESET`'s rise (`bus_init` above).
      .xbus_init  (bus_init),
      .mclk       (mclk),
      .n_memrq    (n_memrq),
      .wrcyc      (wrcyc),
      .phys       (phys),
      .wdata      (wdata),
      .n_memgrant (n_memgrant),
      .n_memack   (n_memack),
      .rdata      (rdata),
      .timed_out  (timed_out),
      .boards     (boards),
      .device     (device),
      .dev_rq     (dev_rq),
      .dev_write  (dev_write),
      .device_ack (dev_ack_joined),
      .device_rdata(dev_rdata_joined),
      .tv_intr    (tv_intr),
      .tv_lispm   (tv_lispm),
      .color_tv   (color_tv),
      .tv_map_a   (tv_map_a),
      .tv_map_q   (tv_map_q),
      .tv_color_map_q(tv_color_map_q),
      .disp_map_a (disp_map_a),
      .disp_color_map_q(disp_color_map_q),
      .ch_req     (ch_req),
      .ch_write   (ch_write),
      .ch_addr    (ch_addr),
      .ch_wdata   (ch_wdata),
      .ch_done    (ch_done),
      .ch_nxm     (ch_nxm),
      .ch_rdata   (ch_rdata),
      .nxm        (nxm),
      .unibus     (unibus),
      .ch_own_o      (aud_ch_own),
      .bus_changing_o(aud_changing),
      .cpu_memory_o  (aud_cpu_memory),
      .ch_memory_o   (aud_ch_memory),
      .ub_msyn_o  (ub_msyn),
      .ub_ssyn_o  (ub_ssyn_o),
      .arb_stage  (arb_stage),
      .ub_addr_o  (ub_addr_o),
      .ub_rdata_o (ub_rdata_o),
      .ub_ssyn_by (ub_ssyn_by),
      .xbus_intr  (xbus_intr),
      .ub_int     (ub_int),
      // On QUUX the keyboard's cable reaches the register page and not the
      // I/O board (`quux_input.sv`), as muir's terminal delivers to the page
      // on QUUX; the board's `-BOOT*` is then idle and the page makes it.
      .kbd_strobe (QUUX ? 1'b0 : kbd_strobe),
      .kbd_code   (kbd_code),
      .n_boot_star(iob_n_boot1),
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
      .chaos_rx_lost(chaos_rx_lost),
      .chaos_tx_done(chaos_tx_done),
      .chaos_tx_abort(chaos_tx_abort),
      .chaos_cbl_busy(chaos_cbl_busy),
      .chaos_bits (chaos_bits),
      .iob_intr   (iob_intr),
      .iob_vector (iob_vector),
      .audio      (audio),
      .csr_face   (iob_csr_face),
      .mouse_x    (mouse_x),
      .mouse_y    (mouse_y),
      .clock_ready(clock_ready),
      .interval   (interval),
      .n_loadmd   (n_loadmd),
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
      .no_auto_boot(no_auto_boot),
      .con_req    (con_req),
      .con_gnt    (con_gnt),
      .con_msyn   (con_msyn),
      .con_write  (con_write),
      .con_addr   (con_addr),
      .con_wdata  (con_wdata),
      .con_ssyn   (con_ssyn),
      .con_rdata  (con_rdata),
      .dbg_in_req (dbg_in_req),
      .dbg_in_wr  (dbg_in_wr),
      .dbg_in_a   (dbg_in_a),
      .dbd_in     (dbd_in),
      .dbg_in_ack (dbg_in_ack),
      .dbd_out    (dbd_out),
      .dbd_oe     (dbd_oe),
      // The DBGOUT end of the same cable: this machine as the debugger, which
      // is the four registers CC writes at `0o766100`-`0o766137`.
      //
      // **IT LEAVES THIS MODULE AND THE CONNECTOR IS THE TOP LEVEL'S.**
      // `rtl/plumbing/cadr_dbg_cable.sv` is what puts it on a Pmod header and
      // decides whether this board is the debugger.  A board with no
      // connector at all ties `dbgout_live` low and `dbgout_dbd_in` to all
      // ones out there, which is exactly muir's `debug_cable` false: no board
      // at the far end, the lines carried by the pull-ups, and the page
      // answering its own machine at `-UB MSYN`.
      .dbgout_req   (dbgout_req),
      .dbgout_wr    (dbgout_wr),
      .dbgout_a     (dbgout_a),
      .dbgout_dbd   (dbgout_dbd),
      .dbgout_ack   (dbgout_ack),
      .dbgout_dbd_in(dbgout_dbd_in),
      .dbgout_live  (dbgout_live),
      .debuggee_reset (debuggee_reset),
      .timeout_inhibit(timeout_inhibit),
      .dbg_rst    (dbg_rst),
      .ub_md_req  (ub_md_req),
      .ub_md_data (ub_md_data),
      .ub_md_ack  (ub_md_ack),
      .mem_req    (mem_req),
      .mem_write  (mem_write),
      .mem_addr   (mem_addr),
      .mem_wdata  (mem_wdata),
      .mem_done   (mem_done),
      .mem_rdata  (mem_rdata),
      .mem_line   (mem_line),
      .mem_rline  (mem_rline),
      .quux_invalidate(bd_written),
      .cached     (cached),
      .port_drained(mem_drained),
      .cache_hits (cache_hits),
      .cache_misses(cache_misses),
      .br_req_o   (br_req),
      .br_write_o (br_write),
      .br_addr_o  (br_addr),
      .br_wdata_o (br_wdata),
      .br_done_o  (br_done),
      .page_err       (page_err),
      .page_err_clear (page_err_clear),
      .page_errstop_we(page_errstop_we),
      .page_errstop   (page_errstop),
      .page_ch_land   (page_ch_land),
      .page_ch_wr     (page_ch_wr),
      .page_ch_which  (page_ch_which),
      .page_ch_wdata  (page_ch_wdata),
      .page_ch_rdata  (page_ch_rdata),
      .chaos_ireq     (chaos_ireq),
      .mouse_buttons  (mouse_buttons),
      .mono_bow_o     (mono_bow)
  );

  // --- the disk controller, the first Xbus slave that is not main memory ---
  //
  // It hangs off the seam `cadr_memory_path.sv` brings out, at the same place
  // an external slave does, and the two are joined the way the open-collector
  // `-XBUS.ACK` joins them.  **THE MACHINE'S OWN `device_ack` PORT STAYS**:
  // the display and the I/O board are still outside, and this is one slave
  // arriving rather than the seam closing.
  //
  // A CYCLE CANNOT BE ANSWERED TWICE, and the decode is what says so:
  // `cadr_xbus_decode.sv` makes `memory` and `device` mutually exclusive by
  // construction --- Xbus I/O space or not --- and inside `device` this module
  // claims only 0o17377774..7, four of the four million addresses the decode
  // is checked against.  Anything hung on the external port owes the same
  // discipline, and nothing here can enforce it for a slave it cannot see.
  //
  // THE DATA LINES ARE SEPARATE FROM THE ACKNOWLEDGMENT, which is the bus
  // and not a convenience: a slave drives MEM<31:0> only while it is
  // answering a READ, so on a device write the seam is left to whatever is
  // outside.  On the board that is nothing and reads zero; in
  // `tb/cadr_machine_tb.cpp` it is the complement of the word MD should hold,
  // which is what keeps the processor's RDCYC gate on -LOADMD observable:
  // poison, never data.  It matters because main memory's own bridge refuses
  // to latch on a write, so `mem_rdata` cannot reach MD on one whatever the
  // processor does.  Measured with the seam held at zero instead, the
  // mutation `rdcyc-gate-dropped` is caught on 2 rows of 600,000 and both
  // are the single UNIBUS write, the one word this program puts on
  // MEM<31:0> without a slave; with the poison it is caught on all 5,650
  // device writes as well.
  logic        disk_ack, disk_drives;
  assign bd_written = QUUX && disk_ack && dev_write;
  logic [31:0] disk_rdata;
  logic        dev_ack_joined;
  logic [31:0] dev_rdata_joined;
  // The channel, which makes the disk controller the second master on this
  // bus.  `cadr_memory_path.sv` has the arbiter and says what it holds to.
  logic        ch_req, ch_write, ch_done, ch_nxm;
  logic [21:0] ch_addr;
  logic [31:0] ch_wdata, ch_rdata;

  // **ON QUUX THE DISK IS BLOCK-DISK AND NOTHING ELSE** (`quux_block_disk.sv`,
  // muir's "the CADR's controller is refused on QUUX"): the same four
  // registers, the same interrupt on the Xbus line and the same two seams,
  // so everything around the instance is the one wiring.  Its done
  // interrupt is also the register page's word 100 `<2>`.  The instance is
  // `disk` in both machines' generate blocks, which the constraint files
  // name.
  // Block-disk's registers for the register page's readout below.
  logic [31:0] bd_ro_cmd, bd_ro_clp, bd_ro_da, bd_ro_lma, bd_ro_since_done;
  logic [6:0]  bd_ro_flags;
  if (QUUX) begin : g_quux_disk
  quux_block_disk disk (
      .clk      (clk),
      .rst      (rst),
      // `-XBUS INIT` on the backplane: the power-on reset and
      // `PROG.UNIBUS.RESET`'s rise (`bus_init` above).  `rst` is the harder
      // of the two: it clears the disk address counters and the command list
      // pointer, which `-XINIT` leaves standing.
      .xbus_init(bus_init),
      .drive_present  (drive_present),
      .drive_read_only(drive_read_only),
      .drive_timed    (drive_timed),
      .sel      (device),
      .dev_rq   (dev_rq),
      .dev_write(dev_write),
      .phys     (phys),
      .wdata    (wdata),
      .dev_ack  (disk_ack),
      .rdata    (disk_rdata),
      .drives   (disk_drives),
      .intr     (disk_intr),
      .store_we   (store_we),
      .store_slot (store_slot),
      .store_addr (store_addr),
      .store_wdata(store_wdata),
      .store_rdata(store_rdata),
      .store_miss (store_miss),
      .ch_req   (ch_req),
      .ch_write (ch_write),
      .ch_addr  (ch_addr),
      .ch_wdata (ch_wdata),
      .ch_done  (ch_done),
      .ch_nxm   (ch_nxm),
      .ch_rdata (ch_rdata),
      .ch_active(ch_active),
      .store_busy(store_busy),
      .store_busy_slot(store_busy_slot),
      .req_valid(req_valid),
      .req_tag  (req_tag),
      .req_post (req_post),
      .ch_waiting(ch_waiting),
      .store_deny(store_deny),
      .ch_slot_o(ch_slot),
      .ch_wrote (ch_wrote),
      .ch_hit   (ch_hit),
      .ro_cmd   (bd_ro_cmd),
      .ro_clp   (bd_ro_clp),
      .ro_da    (bd_ro_da),
      .ro_lma   (bd_ro_lma),
      .ro_flags (bd_ro_flags),
      .ro_since_done(bd_ro_since_done)
  );
  end else begin : g_cadr_disk
  assign bd_ro_cmd        = 32'd0;
  assign bd_ro_clp        = 32'd0;
  assign bd_ro_da         = 32'd0;
  assign bd_ro_lma        = 32'd0;
  assign bd_ro_since_done = 32'd0;
  assign bd_ro_flags      = 7'd0;
  cadr_disk_controller disk (
      .clk      (clk),
      .rst      (rst),
      // `-XBUS INIT` on the backplane: the power-on reset and
      // `PROG.UNIBUS.RESET`'s rise (`bus_init` above).  `rst` is the harder
      // of the two: it clears the disk address counters and the command list
      // pointer, which `-XINIT` leaves standing.
      .xbus_init(bus_init),
      .drive_present  (drive_present),
      .drive_read_only(drive_read_only),
      .drive_timed    (drive_timed),
      .sel      (device),
      .dev_rq   (dev_rq),
      .dev_write(dev_write),
      .phys     (phys),
      .wdata    (wdata),
      .dev_ack  (disk_ack),
      .rdata    (disk_rdata),
      .drives   (disk_drives),
      .intr     (disk_intr),
      .store_we   (store_we),
      .store_slot (store_slot),
      .store_addr (store_addr),
      .store_wdata(store_wdata),
      .store_rdata(store_rdata),
      .store_miss (store_miss),
      .ch_req   (ch_req),
      .ch_write (ch_write),
      .ch_addr  (ch_addr),
      .ch_wdata (ch_wdata),
      .ch_done  (ch_done),
      .ch_nxm   (ch_nxm),
      .ch_rdata (ch_rdata),
      .ch_active(ch_active),
      .store_busy(store_busy),
      .store_busy_slot(store_busy_slot),
      .req_valid(req_valid),
      .req_tag  (req_tag),
      .req_post (req_post),
      .ch_waiting(ch_waiting),
      .store_deny(store_deny),
      .ch_slot_o(ch_slot),
      .ch_wrote (ch_wrote),
      .ch_hit   (ch_hit)
  );
  end

  // **QUUX'S FEATURE PAGE IS A SLAVE ON THE SAME SEAM**, beside the disk and
  // joined the same way: the decode makes page 36776 a device only on QUUX,
  // and the page and the disk's four registers are disjoint, so the two
  // cannot both answer one cycle.
  // The register page's readout, selector 12 (below, in the QUUX block).
  logic [47:0] quux_ro_word;
  logic [17:0] quux_ro_a1, quux_ro_a2;
  logic [13:0] in_ro_state;
  logic [6:0]  in_ro_count;
  logic [23:0] in_ro_fifo_q;
  if (QUUX) begin : g_quux_feature_page
    logic        feature_ack, feature_drives;
    logic        page_n_boot, page_kbd_busy;
    logic [31:0] feature_rdata;

    quux_feature_page #(
        .MACHINE_ID   (MACHINE_ID),
        .SCREEN_WIDTH (MONO_TV_WIDTH),
        .SCREEN_HEIGHT(MONO_TV_HEIGHT),
        .SCREEN_WPL   (MONO_TV_WIDTH / 32)
    ) feature_page (
        .clk          (clk),
        .rst          (rst),
        .sel          (device),
        .phys         (phys),
        .dev_write    (dev_write),
        .dev_rq       (dev_rq),
        .wdata        (wdata),
        .dev_ack      (feature_ack),
        .drives       (feature_drives),
        .rdata        (feature_rdata),
        .clock_pending(clock_pending),
        // Block-disk's done (`quux_block_disk.sv`).
        .disk_irq     (disk_intr),
        .chaos_ireq   (chaos_ireq),
        .prog_unibus_reset_rising(prog_unibus_reset_rising),
        .err          (page_err),
        .err_clear    (page_err_clear),
        .errstop      (errstop),
        .errstop_we   (page_errstop_we),
        .errstop_d    (page_errstop),
        .ch_land      (page_ch_land),
        .ch_wr        (page_ch_wr),
        .ch_which     (page_ch_which),
        .ch_wdata     (page_ch_wdata),
        .ch_rdata     (page_ch_rdata),
        .kbd_strobe   (kbd_strobe),
        .kbd_code     (kbd_code),
        .mouse_x      (mouse_x),
        .mouse_y      (mouse_y),
        .mouse_buttons(mouse_buttons),
        .irq          (page_irq),
        .n_boot_kbd   (page_n_boot),
        .kbd_busy     (page_kbd_busy),
        .ro_in_state  (in_ro_state),
        .ro_in_count  (in_ro_count),
        .ro_fifo_a    (quux_ro_a2[5:0]),
        .ro_fifo_q    (in_ro_fifo_q)
    );

    // **THE REGISTER PAGE'S DEVICES ON THE READOUT, AT SELECTOR 12**: what a
    // checkpoint carries of them as muir's `QuuxInput`, `BlockDisk`,
    // `Machine::bus_error` and MONO TV's `Tv::mode`.  On the audit's pipeline
    // and for its reason: the address delayed by two, the word registered
    // once, landing on the tick the echo names it (the audit's note below).
    // Each word is taken whole in one tick.  The words:
    //
    //     0   the keyboard and the mouse: <43:38> the FIFO's head, <37:31> its
    //         count, <30> overflowed, <29> the keyboard's enable, <28> the
    //         mouse changed, <27> the mouse's enable, <26:24> the buttons,
    //         <23:12> Y, <11:0> X
    //     1-4 block-disk's command, command list pointer, disk address and
    //         last memory address
    //     5   block-disk's flags, <38:32> (`quux_block_disk.sv`'s `ro_flags`),
    //         and <31:0> the ticks since its blocks' time ran out
    //     6   <8> MONO TV's black-on-white, <5:0> the bus errors as word 101
    //         reads them (`Machine::bus_error`)
    //     100-177  the keyboard FIFO's sixty-four words, by index
    //
    // and anything else `RO_NO_MEMORY`.  What holds it:
    // `build/quux_readout_window.quux.pass`.
    always_ff @(posedge clk) begin
      if (rst) begin
        quux_ro_a1 <= 18'h3FFFF;
        quux_ro_a2 <= 18'h3FFFF;
      end else begin
        quux_ro_a1 <= con_ro_addr;
        quux_ro_a2 <= quux_ro_a1;
      end
    end
    always_ff @(posedge clk) begin
      if (quux_ro_a2[13:6] == 8'd1) begin
        quux_ro_word <= {24'd0, in_ro_fifo_q};
      end else begin
        unique case (quux_ro_a2[13:0])
          14'd0: quux_ro_word <= {4'd0, in_ro_state[13:8], in_ro_count, in_ro_state[3:0],
                                  mouse_buttons, mouse_y, mouse_x};
          14'd1: quux_ro_word <= {16'd0, bd_ro_cmd};
          14'd2: quux_ro_word <= {16'd0, bd_ro_clp};
          14'd3: quux_ro_word <= {16'd0, bd_ro_da};
          14'd4: quux_ro_word <= {16'd0, bd_ro_lma};
          14'd5: quux_ro_word <= {9'd0, bd_ro_flags, bd_ro_since_done};
          14'd6: quux_ro_word <= {39'd0, mono_bow, 2'd0, page_err[2], 1'b0, page_err[1],
                                  2'd0, page_err[0]};
          default: quux_ro_word <= 48'hA5A5_5A5A_A5A5;
        endcase
      end
    end
    logic unused_ro;
    assign unused_ro = ^{quux_ro_a2[17:14], in_ro_state[7:4]};

    // The keyboard's boot word boots from the page on QUUX, and the host's
    // handshake reads the page's FIFO in `KBD READY`'s place.
    assign n_boot1  = iob_n_boot1 && page_n_boot;
    // The board's own `KBD READY`, which the cable never raises on QUUX.
    assign csr_face = {iob_csr_face[7:6], page_kbd_busy, iob_csr_face[4:0]};
    logic unused_kbd_ready;
    assign unused_kbd_ready = iob_csr_face[5];

    assign dev_ack_joined   = disk_ack || feature_ack || device_ack;
    assign dev_rdata_joined = disk_drives    ? disk_rdata
                            : feature_drives ? feature_rdata
                                             : device_rdata;
  end else begin : g_cadr_seam
  assign dev_ack_joined   = disk_ack || device_ack;
  assign dev_rdata_joined = disk_drives ? disk_rdata : device_rdata;
  assign page_irq         = 1'b0;
  assign n_boot1          = iob_n_boot1;
  assign csr_face         = iob_csr_face;
  assign page_err_clear   = 1'b0;
  assign page_errstop_we  = 1'b0;
  assign page_errstop     = 1'b0;
  assign page_ch_land     = 1'b0;
  assign page_ch_wr       = 1'b0;
  assign page_ch_which    = 3'd0;
  assign page_ch_wdata    = 16'd0;
  // The page's wires the CADR does not read, and its readout: selector 12
  // reads `RO_NO_MEMORY` on the CADR, as every selector it does not map.
  assign quux_ro_word = 48'hA5A5_5A5A_A5A5;
  assign quux_ro_a1   = 18'h3FFFF;
  assign quux_ro_a2   = 18'h3FFFF;
  assign in_ro_state  = 14'd0;
  assign in_ro_count  = 7'd0;
  assign in_ro_fifo_q = 24'd0;
  logic unused_page;
  assign unused_page = ^{clock_pending, page_err, page_ch_rdata, chaos_ireq, mouse_buttons,
                         mono_bow, bd_ro_cmd, bd_ro_clp, bd_ro_da, bd_ro_lma, bd_ro_flags,
                         bd_ro_since_done, quux_ro_a1, quux_ro_a2, in_ro_state, in_ro_count,
                         in_ro_fifo_q};
  end

  // ------------------------------------------------- the transaction audit
  //
  // ONE TRANSACTION PER BUS CYCLE, IN THE DIRECTION THE CYCLE NAMES, AND NONE
  // ANYWHERE ELSE --- watched in fabric, for as long as the board runs.
  // `rtl/plumbing/cadr_bus_audit.sv` is the whole of it and its header is the
  // argument; `build/bus_audit.pass` holds the same property in simulation
  // over MIT's boot PROM.  That is the only program this module can run in
  // simulation and it makes 512 main-memory cycles, against the board's event
  // of one in about a hundred and seventy-six million microcycles.
  //
  // **THE INSTANCE IS NAMED `audit` BECAUSE THE CONSTRAINT NAMES THE
  // INSTANCE.**  `rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes every
  // register under this module that is not named fast, and a relaxed edge
  // detector misses an edge or invents one --- an instrument that lies.  Its
  // clause is `NAME !~ *audit/*` with the capture registers added back, so a
  // rename here empties the clause in silence and the tell is
  // `report_exceptions` counting fewer than were written.
  //
  // **AND THE BUNDLE BELOW IS THE MASTER'S OWN SIGNALS AND NEVER THE
  // BRIDGE'S.**  A check keyed by the thing under test moves with the bug, and
  // the thing under test is the path from a bus cycle to the AXI port.  So the
  // processor's cycle is MBUSY --- the 74S175 at 1C23 for its direction, the
  // held decode for what answers it --- and the channel's is its own
  // ownership, direction and decode, and neither is `bus_rq`, `bus_write` or
  // `bus_sel`, which are the mux a fault would move with.
  //
  // **THE IDLE TICK IS WHAT SEPARATES THE TWO MASTERS.**  MBUSY is up from
  // MEMGO until MFINISHD_T ticks after -MEMACK and the channel may take the
  // bus inside either end of that window, so the two cycles overlap; the
  // arbiter already leaves the bus idle for one tick at every change of owner,
  // and forcing `aud_cycle` low on that tick turns a handover into a fall and
  // a rise, which re-samples the attributes and resets the per-cycle request
  // count.  Nothing in flight is chopped: the channel cannot take the bus
  // while the processor's -XBUS.RQ is up, and `mem_req` cannot stand without
  // it.
  logic aud_ch_own, aud_changing, aud_cpu_memory, aud_ch_memory;
  logic        aud_cycle, aud_write, aud_memory;
  logic [21:0] aud_phys;
  assign aud_cycle  = aud_changing ? 1'b0 : (aud_ch_own ? 1'b1 : mbusy_o);
  assign aud_write  = aud_ch_own ? ch_write      : wrcyc;
  assign aud_memory = aud_ch_own ? aud_ch_memory : aud_cpu_memory;
  assign aud_phys   = aud_ch_own ? ch_addr       : phys;

  // **THE READOUT, JOINED INTO THE CONSOLE'S WINDOW AT A SELECTOR OF ITS
  // OWN.**  `cadr_microcycle.sv` maps 0 to 10 and answers `RO_NO_MEMORY` for
  // anything else; 11 is the audit's, 12 QUUX's register page's and 13 to 15
  // are still free.  That is
  // how anything inside this module is read on a HALTED board, over
  // `M_AXI_GP1`, by `cadr-readout`, from anywhere, with nobody at the board
  // --- and the board's own event is hours in the past by the time anybody
  // looks.
  //
  // **THE PIPELINE IS THE WINDOW'S AND THE AUDIT IS PUT ON IT RATHER THAN
  // BESIDE IT.**  `ro_addr` reaches `ro_data` and `ro_echo` three ticks later
  // inside the processor: `ro_a0` at one, the memories' second ports at two,
  // the word register at three.  The audit's own `word` is one tick behind its
  // `sel`, so `sel` is the address delayed by TWO and the word lands on the
  // same tick as the memories' --- and the mux is on `con_ro_echo`, which is
  // the address that word was read at, so the three wires stay one instant.
  // Out of reset the echo is the reserved selector, which is not this one, so
  // the window answers exactly as it did before this module was joined to it.
  //
  // Only four bits of the address are carried: the audit has sixteen words and
  // the other ten bits would be a signal nothing reads.
  localparam logic [3:0] RO_AUDIT = 4'd11;

  logic [47:0] proc_ro_data, aud_word;
  logic [3:0]  ro_sel_d1, ro_sel_d2;

  always_ff @(posedge clk) begin
    if (rst) begin
      ro_sel_d1 <= 4'd0;
      ro_sel_d2 <= 4'd0;
    end else begin
      ro_sel_d1 <= con_ro_addr[3:0];
      ro_sel_d2 <= ro_sel_d1;
    end
  end

  // And selector 12, QUUX's register page (above): `RO_NO_MEMORY` on the CADR.
  localparam logic [3:0] RO_QUUX_PAGE = 4'd12;
  assign con_ro_data = (con_ro_echo[17:14] == RO_AUDIT)     ? aud_word
                     : (con_ro_echo[17:14] == RO_QUUX_PAGE) ? quux_ro_word
                                                            : proc_ro_data;

  // **ON QUUX THE AUDIT WATCHES THE XBUS BRIDGE'S SEAM, NOT MAIN
  // MEMORY'S** (contract Q6).  Main memory's cycles are the memory port's,
  // through the cache: a read that hits makes no transaction, a miss makes a
  // line fill, and a write reaches main memory from the buffer after the
  // cycle has ended, so "one transaction per bus cycle" is not a property of
  // that seam at all.  It is still a property of the bridge's, which carries
  // MONO TV's frame buffer and block-disk's transfers one word a cycle, and
  // the port's answers to the bridge stand in for the PS7's handshakes.
  // What holds the port's own traffic is `build/quux_port.quux.*.pass`.
  //
  // The port's answers are taken a tick after the bridge sees them, as the
  // PS7's handshakes always come after the request they answer: the bridge
  // may be answered in the very tick it asks, where the audit counts the
  // request owed only from the next.
  logic aud_req, aud_mwrite, aud_done, br_done_q, br_rack_q, br_wack_q;
  logic [31:0] aud_addr, aud_wdata;
  logic aud_read_ack, aud_write_ack;
  always_ff @(posedge clk) begin
    br_done_q <= rst ? 1'b0 : br_done;
    br_rack_q <= !rst && br_done && !br_done_q && !br_write;
    br_wack_q <= !rst && br_done && !br_done_q &&  br_write;
  end
  assign aud_req       = QUUX ? br_req   : mem_req;
  assign aud_mwrite    = QUUX ? br_write : mem_write;
  assign aud_done      = QUUX ? br_done  : mem_done;
  assign aud_addr      = QUUX ? br_addr  : mem_addr;
  assign aud_wdata     = QUUX ? br_wdata : mem_wdata;
  assign aud_read_ack  = QUUX ? br_rack_q : port_read_ack;
  assign aud_write_ack = QUUX ? br_wack_q : port_write_ack;
  logic unused_port_acks;
  assign unused_port_acks = QUUX && ^{port_read_ack, port_write_ack, cache_hits, cache_misses};

  cadr_bus_audit audit (
      .clk         (clk),
      .rst         (rst),
      .cycle       (aud_cycle),
      .cycle_write (aud_write),
      .cycle_memory(aud_memory),
      .cycle_phys  (aud_phys),
      .mem_req     (aud_req),
      .mem_write   (aud_mwrite),
      .mem_done    (aud_done),
      .mem_addr    (aud_addr),
      .mem_wdata   (aud_wdata),
      .port_read_ack (aud_read_ack),
      .port_write_ack(aud_write_ack),
      .boundary    (clock_edge),
      .vma         (vma),
      .md          (md),
      .pc          (pc),
      .opc         (opc),
      .sel         (ro_sel_d2),
      .word        (aud_word)
  );

  // ----------------------------------------------------- `-BOOT`, OLORD2 1A07
  //
  // **A CADR BOOTS THREE WAYS AND THEY MEET HERE.**  `data/CADR.netlist`, the
  // OLORD2 page: the 74LS14 at 1A20 inverts `-BOOT1` into pin 5 of the 74S02
  // at 1A07; another section of the same 74LS14 inverts `-BOOT2`, the 74S32
  // at 1C18 ORs that with `PROG.BOOT`, and its output is pin 6 of the same
  // gate.  A 74S02 is a NOR, so `-BOOT` at pin 4 is low when ANY of the three
  // is asserted and high when none is --- the three-way OR the drawing makes
  // out of an inverter, an OR gate and a NOR.  **The processor cannot tell
  // which was pressed**, and nothing downstream is given a way to.
  //
  //   `-BOOT1`     the keyboard's, by way of the I/O board's own decode of
  //                the boot word and `-BOOT*` on the backplane.  That pulse
  //                is 4 us; see `cadr_io_board.sv`.
  //   `-BOOT2`     the light panel's momentary button, a level for as long
  //                as it is held.  `boards/arty-z7-20/cadr_arty.sv` gives it
  //                two sources, a push-button and the console's register.
  //   `PROG.BOOT`  the other machine's, over the debug cable: bit 7 of a
  //                mode-register write, a pulse `cadr_spy_registers.sv`
  //                makes at the LEADING edge of the write strobe so that it
  //                reaches the trap before the microcycle ends.
  //
  // **AND `-BOOT` DOES THREE THINGS, ALL OF THEM ON THIS PAGE.**  It presets
  // `RUN` at the 74S74 at OLORD1 1A14, so a halted machine starts; it clears
  // the 74LS109 at 1A18, whose `-Q` is `BOOT.TRAP`, so the next microcycle is
  // nopped and `NPC` is forced to zero; and it is one of the three inputs of
  // the open-collector 74S10 at 1C08 that makes `RESET`, which clears the two
  // 74S175s of the console's registers --- `PROMDISABLE` among them, which is
  // what puts the boot PROM back over the control store --- and the flip-flops
  // at CONTRL, LCC, PDLCTL, VCTL1, FLAG and ACTL.  `Engine::boot` is exactly
  // that list and `Engine::keyboard_boot` presses it, so the fabric's two
  // takers are the processor and the register block.
  logic n_boot;
  assign n_boot = !(!n_boot1 || !n_boot2 || prog_boot);
  assign n_boot_o = n_boot;

  // RDCYC leaves the processor for the check's sake: a write must not move
  // MD, and that is the thing this composition makes visible.
  // -PROG.RESET is the other pulse a mode-register write makes, and the
  // processor does not act on it yet. See the note at the top.
  logic unused;
  assign n_loadmd_o = n_loadmd;
  assign n_memrq_o  = n_memrq;
  assign n_memack_o = n_memack;
  assign n_memgrant_o = n_memgrant;
  assign rdcyc_o    = rdcyc;
  assign dev_wdata  = wdata;
  assign unused = &{1'b0, prog_reset};

endmodule

`default_nettype wire
