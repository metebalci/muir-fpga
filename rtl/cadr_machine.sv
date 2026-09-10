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
// configuration; the DDR itself, behind `mem_req`/`mem_done`; and the Xbus
// slaves that are neither main memory nor the disk --- the display and the
// I/O board --- behind `dev_rq`/`device_ack`.  **THE DISK CONTROLLER'S FOUR
// REGISTERS ARE INSIDE NOW**, `cadr_disk_controller.sv`, which is what the
// boot PROM's 16,951 device cycles reach: 11,301 reads of the status register
// from microcycle 537,848 on and 5,650 writes of the disk address register.
// They used to be answered from the trace, and that was stimulus.  What is
// still outside the disk is everything past its register face: the channel,
// the drive and `S_AXI_HP2`.  The Unibus is outside too, and not merely unbuilt:
// `cadr_busint_xbus.sv` is the Xbus half, and 347 of the System band's
// 141,849 bus cycles arbitrate for a bus that is not here.

`default_nettype none

module cadr_machine #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic        clk,          // 200 MHz, one tick = 5 ns
    input  var logic        rst,

    // --- SINTR, the interrupt off the cables
    input  var logic        sintr,

    // --- THE DISK'S DRIVE SEAM, eight unit slots of it.
    //
    // A drive is a thing on a cable and not a property of the controller, so
    // presence and the read-only switch are per unit and `Controller::timed`
    // --- whether the drive's own time is charged at all --- comes with them.
    // `tb/cadr_disk_tb.cpp` attaches one where the reference trace's `ATTACH`
    // row says; `rtl/cadr_arty.sv` ties all three off and says what will
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
    // header checkword and its data checkword, and `S_AXI_HP2` is what will
    // fill it --- the pack is a file Linux puts in DDR and the block's
    // address crosses over `M_AXI_GP0`.  Neither exists; the seam does, and
    // `tb/cadr_disk_tb.cpp` drives the controller's end of it from the
    // reference trace's `BLK` rows.  `rtl/cadr_arty.sv` ties it off, and with
    // it tied off the whole store and the whole channel constant-fold, which
    // is the same thing that happens to the drive.
    //
    // Only the WRITE half leaves this module.  The read-back and the store's
    // own interlock are the master's business and there is no master, so
    // they are folded below rather than brought out to a port nothing can
    // drive --- which is what `dev_wdata` was, one boundary along.
    input  var logic        store_we,
    input  var logic [4:0]  store_slot,
    input  var logic [8:0]  store_addr,
    input  var logic [31:0] store_wdata,

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
    output var logic        n_loadmd_o,
    output var logic        rdcyc_o,
    output var logic        nxm,          // Xbus space with nothing in it
    output var logic        unibus,       // the Unibus, which is its own slice
    output var logic        memstart,     // MEMSTART, which also addresses the map
    output var logic        timed_out,

    // --- PS DDR3, behind the AXI adapter
    output var logic        mem_req,
    output var logic        mem_write,
    output var logic [31:0] mem_addr,
    output var logic [31:0] mem_wdata,
    input  var logic        mem_done,
    input  var logic [31:0] mem_rdata
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
      .sintr       (sintr),
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
      .clock_edge  (clock_edge)
  );

  cadr_memory_path memory (
      .clk        (clk),
      .rst        (rst),
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
      .ch_req     (ch_req),
      .ch_write   (ch_write),
      .ch_addr    (ch_addr),
      .ch_wdata   (ch_wdata),
      .ch_done    (ch_done),
      .ch_nxm     (ch_nxm),
      .ch_rdata   (ch_rdata),
      .nxm        (nxm),
      .unibus     (unibus),
      .ub_msyn_o  (ub_msyn),
      .ub_ssyn_o  (ub_ssyn_o),
      .arb_stage  (arb_stage),
      .ub_addr_o  (ub_addr_o),
      .ub_rdata_o (ub_rdata_o),
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
  logic        ch_req, ch_write, ch_done, ch_nxm, ch_active;
  logic [21:0] ch_addr;
  logic [31:0] ch_wdata, ch_rdata;
  logic [31:0] store_rdata;
  logic        store_miss;

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
      .ch_active(ch_active)
  );

  assign dev_ack_joined   = disk_ack || device_ack;
  assign dev_rdata_joined = disk_drives ? disk_rdata : device_rdata;

  // RDCYC leaves the processor for the check's sake: a write must not move
  // MD, and that is the thing this composition makes visible.
  // -PROG.RESET and PROG.BOOT: the two pulses a mode-register write makes,
  // which the processor does not act on yet. See the note at the top.
  // The store's read-back and its interlock, folded rather than brought out:
  // see the note at the seam's ports.  `store_miss` is the controller saying
  // the walk asked for a block the store does not hold, which cannot happen
  // once `S_AXI_HP2` fetches on demand and which `build/disk.pass` requires
  // to stay low at every tick of its own run.
  logic unused;
  assign n_loadmd_o = n_loadmd;
  assign n_memrq_o  = n_memrq;
  assign n_memack_o = n_memack;
  assign n_memgrant_o = n_memgrant;
  assign rdcyc_o    = rdcyc;
  assign dev_wdata  = wdata;
  assign unused = &{1'b0, prog_reset, prog_boot, store_miss, ch_active,
                    ^store_rdata};

endmodule

`default_nettype wire
