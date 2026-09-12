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
// every acknowledgement, read or write --- `Busint` and `cadr_busint_xbus.sv`
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
    parameter string PROM_HEX = "build/boot_prom.hex"
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

  // The cables, named at both ends as `cadr_cables.map` has them.
  logic        mclk;
  logic        n_memrq, rdcyc;
  logic [31:0] wdata, rdata;
  // The console's registers, which now live on the bus interface where a
  // console can write them, and reach the processor as signals.
  logic [3:0]  spy_eadr;
  logic [15:0] spy_rdata;
  logic        run, errstop, stathenb, prog_reset, prog_boot;
  logic [1:0]  mode_speed;
  logic        n_memgrant, n_memack, n_loadmd;

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
  assign sintr_o   = xbus_intr || ub_int;

  cadr_microcycle #(
      .PROM_HEX(PROM_HEX)
  ) processor (
      .clk         (clk),
      .rst         (rst),
      .run         (run),
      .promdisable (promdisable),
      .errstop     (errstop),
      .stathenb    (stathenb),
      .mode_speed  (mode_speed),
      .spy_eadr    (spy_eadr),
      .spy_rdata   (spy_rdata),
      .sintr       (sintr_o),
      .n_memack    (n_memack),
      .n_memgrant  (n_memgrant),
      .n_loadmd    (n_loadmd),
      .rdata       (rdata),
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

  cadr_memory_path memory (
      .clk        (clk),
      .rst        (rst),
      // `-XBUS INIT`, as the disk takes it below: the power-on reset is the
      // one thing that asserts it here.
      .xbus_init  (rst),
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
      .kbd_strobe (kbd_strobe),
      .kbd_code   (kbd_code),
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
      .iob_intr   (iob_intr),
      .iob_vector (iob_vector),
      .audio      (audio),
      .csr_face   (csr_face),
      .mouse_x    (mouse_x),
      .mouse_y    (mouse_y),
      .clock_ready(clock_ready),
      .interval   (interval),
      .n_loadmd   (n_loadmd),
      .spy_eadr   (spy_eadr),
      .spy_rdata  (spy_rdata),
      .run        (run),
      .promdisable(promdisable),
      .errstop    (errstop),
      .stathenb   (stathenb),
      .mode_speed (mode_speed),
      .prog_reset (prog_reset),
      .prog_boot  (prog_boot),
      .con_req    (con_req),
      .con_gnt    (con_gnt),
      .con_msyn   (con_msyn),
      .con_write  (con_write),
      .con_addr   (con_addr),
      .con_wdata  (con_wdata),
      .con_ssyn   (con_ssyn),
      .con_rdata  (con_rdata),
      .mem_req    (mem_req),
      .mem_write  (mem_write),
      .mem_addr   (mem_addr),
      .mem_wdata  (mem_wdata),
      .mem_done   (mem_done),
      .mem_rdata  (mem_rdata)
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
  // THE DATA LINES ARE SEPARATE FROM THE ACKNOWLEDGEMENT, which is the bus
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
  logic [31:0] disk_rdata;
  logic        dev_ack_joined;
  logic [31:0] dev_rdata_joined;
  // The channel, which makes the disk controller the second master on this
  // bus.  `cadr_memory_path.sv` has the arbiter and says what it holds to.
  logic        ch_req, ch_write, ch_done, ch_nxm;
  logic [21:0] ch_addr;
  logic [31:0] ch_wdata, ch_rdata;

  cadr_disk_controller disk (
      .clk      (clk),
      .rst      (rst),
      // `-XBUS INIT` on the backplane. The power-on reset is the one thing
      // that asserts it here --- there is no console to pull it --- and `rst`
      // is the harder of the two: it clears the disk address counters and the
      // command list pointer, which `-XINIT` leaves standing.
      .xbus_init(rst),
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

  assign dev_ack_joined   = disk_ack || device_ack;
  assign dev_rdata_joined = disk_drives ? disk_rdata : device_rdata;

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
  // anything else; 11 is the audit's and 12 to 15 are still free.  That is
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

  assign con_ro_data = (con_ro_echo[17:14] == RO_AUDIT) ? aud_word : proc_ro_data;

  cadr_bus_audit audit (
      .clk         (clk),
      .rst         (rst),
      .cycle       (aud_cycle),
      .cycle_write (aud_write),
      .cycle_memory(aud_memory),
      .cycle_phys  (aud_phys),
      .mem_req     (mem_req),
      .mem_write   (mem_write),
      .mem_done    (mem_done),
      .mem_addr    (mem_addr),
      .mem_wdata   (mem_wdata),
      .port_read_ack (port_read_ack),
      .port_write_ack(port_write_ack),
      .boundary    (clock_edge),
      .vma         (vma),
      .md          (md),
      .pc          (pc),
      .opc         (opc),
      .sel         (ro_sel_d2),
      .word        (aud_word)
  );

  // RDCYC leaves the processor for the check's sake: a write must not move
  // MD, and that is the thing this composition makes visible.
  // -PROG.RESET and PROG.BOOT: the two pulses a mode-register write makes,
  // which the processor does not act on yet. See the note at the top.
  logic unused;
  assign n_loadmd_o = n_loadmd;
  assign n_memrq_o  = n_memrq;
  assign n_memack_o = n_memack;
  assign n_memgrant_o = n_memgrant;
  assign rdcyc_o    = rdcyc;
  assign dev_wdata  = wdata;
  assign unused = &{1'b0, prog_reset, prog_boot};

endmodule

`default_nettype wire
