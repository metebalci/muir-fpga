// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The soft processing system: a RISC-V core in fabric, its memory, its
// console line and its clock, mastering the same register faces the Zynq's
// ARM cores master on the other two boards.
//
// **THIS IS THE ARTIX's ANSWER TO `boards/arty-z7-20/cadr_ps7.sv`, AND THE
// PARALLEL IS EXACT.**  That file brings the processing system's AXI ports out
// and `boards/arty-z7-20/cadr_arty.sv` hangs the faces off them; this brings
// the same AXI ports out and `boards/arty-a7-100/cadr_arty_a7.sv` hangs the
// same faces off them, with the same parameters and the same wires.  Nothing
// in `rtl/machine/` knows which it is behind, and nothing in the faces does
// either.  **The faces are therefore not here**: a face beside the machine is
// what both other boards have, and moving it inside the processing system on
// one board would be the beginning of two descriptions of the same
// composition.
//
// **THE CORE IS IBEX AND IT IS NOT OURS.**  lowRISC's, two-stage, in-order,
// RV32IMC, under Apache-2.0, vendored at a pinned commit in `third_party/ibex/`
// with its own licence and its provenance beside it --- `third_party/ibex/README.md`
// says which commit, how it was obtained and what each file's digest is.  The
// decision behind it is in CLAUDE.md and it is the important one: a standard
// soft core and never a home-made one.  A processor this project wrote would
// be a second machine to be wrong about, in a repository whose whole method is
// holding ONE machine to a reference.
//
// WHY IBEX and not the others.  MicroBlaze arrives as an IP directory with an
// encrypted netlist and its own toolchain, which is the thing this project has
// declined twice already for much smaller pieces.  VexRiscv is faster per LUT
// and its Verilog is generated from Scala, so the tree would hold generated
// output nobody can read.  picorv32 is one plain file and the smallest, and
// takes four or five cycles an instruction, which is too slow for the network
// stack and the RFB server this has to grow into.  Ibex is SystemVerilog ---
// this repository's own language --- about one instruction a cycle, a few
// thousand LUTs, and it is the core OpenTitan ships.
//
// THE CONFIGURATION, and why each half of it:
//
//   `BaseIsaRV32I`      the base.  Not RV32E: sixteen registers would save a
//                       little distributed RAM and cost a toolchain nobody
//                       else uses
//   `RV32M = RV32MFast` a multiplier and divider.  The part has 240 DSP
//                       slices and the machine uses none of them, so this is
//                       free in the only resource that is not contended
//   `RV32B = RV32BNone` no bit manipulation.  The toolchain here does not emit
//                       it and the firmware does not want it
//   `RV32ZC = RV32Zca`  the compressed instructions and nothing beyond them.
//                       `Zca` IS the C extension for an integer-only target,
//                       so this is the C of RV32IMC exactly.  Zcb and Zcmp
//                       are extra decode for instructions `-march=rv32imc`
//                       never emits
//   `ICache = 0`        no caches to start.  A cache is the answer to a slow
//                       memory and this memory is one block RAM at one cycle,
//                       so there is nothing for it to hide.  It would also
//                       want the `prim_ram_1p` family and its scrambling, and
//                       every one of those is another vendored file
//   `WritebackStage=0`  two stages, and `BranchTargetALU = 0` with it.
//                       **BOTH WERE TRIED THE OTHER WAY, FOR TIMING, AND MADE
//                       IT WORSE.**  Ibex's own guidance is that the branch
//                       adder and the third stage are what a design short of
//                       frequency reaches for, and this design is short of it
//                       --- so they were turned on and the board was built
//                       again: **-3.216 ns with both off, -3.694 ns with both
//                       on**, at `xc7a100tcsg324-1` with the core on the
//                       machine's own 10 ns tick.  They are off because the
//                       measurement says so and not because the smaller core
//                       was assumed to be the slower one.  **BOTH OF THOSE
//                       FIGURES ARE HISTORY**: what closed the design was
//                       giving this system a clock of its own, and neither
//                       option was tried again on it, there being nothing
//                       left to buy.  `boards/arty-a7-100/README.md` carries
//                       what the critical path was and what it is now.
//   `PMPEnable = 0`     no memory protection.  There is one program and no
//                       supervisor to protect it from
//   `SecureIbex = 0`    none of the hardening: no lockstep, no dummy
//                       instructions, no ECC on the register file or the bus.
//                       Every one of those answers a threat model this board
//                       does not have, and each costs logic and vendored files
//   `BranchPredictor=0` no prediction, and `BranchTargetALU = 0` with it
//
// THE MAP.  The faces keep the addresses the Linux programs use, which is the
// whole point of the exercise --- `console_face.h` says `0x8000_0000` and
// `pack_side.h` says `0x4000_0000`, and a header that had to say "except on
// the Artix" would be the beginning of two programs:
//
//     0x0000_0000  `RAM_WORDS` words of block RAM, the firmware in it
//     0x1000_0000  this processing system's own UART
//     0x1000_1000  its own timer
//     0x4000_0000  the disk pack face          `cadr_disk_pack.sv`
//     0x8000_0000  the console                 `cadr_console.sv`
//     0x8000_1000  the debug cable's window    `cadr_debug_window.sv`
//     everything else                          `cadr_gp0_default.sv`, "NONE"
//
// **THE SoC's OWN TWO PAGES ARE AT `0x1000_0000` AND THAT IS DELIBERATE.**
// They are not the Zynq's peripherals wearing the Zynq's addresses: nothing in
// this repository has ever named `0xE000_1000`, and a UART pretending to be
// the processing system's would be a lie a program could act on.  They sit
// where nothing else does, in a region no face has ever claimed.
//
// **AND EVERY ADDRESS IS ANSWERED.**  `rtl/plumbing/cadr_soc_axi.sv`'s last
// port is a catch-all and `cadr_gp0_default.sv` is behind it, so a load from
// an address nothing implements completes with "NONE" rather than standing
// for ever.  That is the GP0-hang rule this project measured on silicon, kept
// on a board whose core has no interconnect to give it a DECERR at all.
//
// **AND THERE ARE TWO CLOCKS IN HERE, WHICH IS THE ONE PLACE THIS PARTS FROM
// `cadr_ps7.sv`'s shape.**  Ibex computes a load or a store's address in the
// cycle it uses it, and on this part that arc is about 12.9 ns --- three more
// than the machine's tick, and not a path a constraint may relax, being one
// cycle of a processor.  So the core, its memory, its UART and its timer run
// on a clock of their own off the same manager, `clk`, and the bridge runs on
// the machine's, `axi_clk`, where the four faces already are.
// `rtl/plumbing/cadr_soc_cross.sv` is the seam between them and carries the
// whole argument; `boards/arty-a7-100/README.md` carries the measurement that
// made it necessary.
//
// **THE FACES THEREFORE DO NOT KNOW THERE ARE TWO CLOCKS**, and neither does
// anything in `rtl/machine/`.  What crosses is one request and one answer, at
// the narrowest seam in the design, and not a hundred and forty wires of AXI.
//
// **ONE DATA TRANSACTION AT A TIME, AND IT COSTS A CYCLE.**  A load from the
// block RAM answers two cycles after the request rather than one, because the
// seam does not accept a new request in the cycle it answers the old one.  A
// one-deep pipeline would get it back and is not built: a firmware polling a
// UART is not what this board is short of, and a seam that can have two
// answers outstanding is a seam whose ordering has to be checked.  Instruction
// fetch is NOT like this --- it is pipelined, one word a cycle --- because it
// is the path that decides how fast the core runs.

`default_nettype none

module cadr_soc #(
    // 32 KB of block RAM: eight tiles on this part, and about four times what
    // the first firmware needs.
    parameter int unsigned RAM_WORDS = 8192,
    parameter string FIRMWARE_HEX = "build/soc_firmware.hex",
    // **THE SOFT SYSTEM'S OWN CLOCK IN HERTZ, WHICH IS NOT THE MACHINE'S**,
    // for the UART's divisor and the timer's microsecond.  See
    // `cadr_soc_uart.sv`'s header: this is the one corner of the design that
    // is about the wall clock rather than about MIT's grid, and since the
    // clock the core runs on is slower than the machine's tick the two
    // numbers are different.  The board passes the frequency `CLKOUT2` of its
    // one clock manager makes; a value that did not match it would give a
    // transmitter at the wrong rate and a microsecond that was not one, and
    // the firmware reads the microsecond out of the timer rather than
    // dividing by a constant of its own.
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned BAUD   = 115_200,
    // Where this processing system's own two pages sit.
    parameter logic [31:0] UART_BASE  = 32'h1000_0000,
    parameter logic [31:0] TIMER_BASE = 32'h1000_1000,
    // The three faces, at the addresses the Linux programs use.
    parameter logic [31:0] PACK_BASE = 32'h4000_0000,
    parameter logic [31:0] CON_BASE  = 32'h8000_0000,
    parameter logic [31:0] DBG_BASE  = 32'h8000_1000
) (
    // **THE SOFT SYSTEM'S OWN CLOCK.**  Everything in here but the bridge
    // runs on it.
    input  var logic        clk,
    // The board's reset, a level, asynchronous to `clk` --- it is made in the
    // machine's domain and synchronised onto this one below, in the one place
    // that has to know.
    input  var logic        rst,

    // **THE MACHINE'S TICK, WHICH THE BRIDGE AND THE FOUR FACES RUN ON.**
    // Every AXI signal in the port list below is in THIS domain; nothing that
    // crosses between the two leaves this module.
    input  var logic        axi_clk,
    input  var logic        axi_rst,

    // --- the board's USB-UART bridge.  `tx` leaves on `uart_rxd_out` and
    // --- `rx` arrives on `uart_txd_in`; those names are from the host's point
    // --- of view and `cadr_soc_uart.sv` says so.
    output var logic        uart_tx,
    input  var logic        uart_rx,

    // --- **THE DISK PACK SIDE's INTERRUPT**, into the core's external
    // --- interrupt.  On the Zynq the same line goes to `IRQ_F2P` and Linux
    // --- takes it; here there is no interrupt controller and no operating
    // --- system, so it is `mip.MEIP` and the firmware may enable it or poll
    // --- the face instead.  The first firmware polls, and this is here so
    // --- that the one that does not need no change in fabric.
    input  var logic        ext_irq,

    // --- the disk pack face ------------------------------------------------
    output var logic [31:0] pack_awaddr,
    output var logic [3:0]  pack_awlen,
    output var logic [11:0] pack_awid,
    output var logic        pack_awvalid,
    input  var logic        pack_awready,
    output var logic [31:0] pack_wdata,
    output var logic [3:0]  pack_wstrb,
    output var logic        pack_wlast,
    output var logic        pack_wvalid,
    input  var logic        pack_wready,
    input  var logic [1:0]  pack_bresp,
    input  var logic [11:0] pack_bid,
    input  var logic        pack_bvalid,
    output var logic        pack_bready,
    output var logic [31:0] pack_araddr,
    output var logic [3:0]  pack_arlen,
    output var logic [11:0] pack_arid,
    output var logic        pack_arvalid,
    input  var logic        pack_arready,
    input  var logic [31:0] pack_rdata,
    input  var logic [1:0]  pack_rresp,
    input  var logic [11:0] pack_rid,
    input  var logic        pack_rlast,
    input  var logic        pack_rvalid,
    output var logic        pack_rready,

    // --- the console -------------------------------------------------------
    output var logic [31:0] con_awaddr,
    output var logic [3:0]  con_awlen,
    output var logic [11:0] con_awid,
    output var logic        con_awvalid,
    input  var logic        con_awready,
    output var logic [31:0] con_wdata,
    output var logic [3:0]  con_wstrb,
    output var logic        con_wlast,
    output var logic        con_wvalid,
    input  var logic        con_wready,
    input  var logic [1:0]  con_bresp,
    input  var logic [11:0] con_bid,
    input  var logic        con_bvalid,
    output var logic        con_bready,
    output var logic [31:0] con_araddr,
    output var logic [3:0]  con_arlen,
    output var logic [11:0] con_arid,
    output var logic        con_arvalid,
    input  var logic        con_arready,
    input  var logic [31:0] con_rdata,
    input  var logic [1:0]  con_rresp,
    input  var logic [11:0] con_rid,
    input  var logic        con_rlast,
    input  var logic        con_rvalid,
    output var logic        con_rready,

    // --- the debug cable's register window ---------------------------------
    output var logic [31:0] dbg_awaddr,
    output var logic [3:0]  dbg_awlen,
    output var logic [11:0] dbg_awid,
    output var logic        dbg_awvalid,
    input  var logic        dbg_awready,
    output var logic [31:0] dbg_wdata,
    output var logic [3:0]  dbg_wstrb,
    output var logic        dbg_wlast,
    output var logic        dbg_wvalid,
    input  var logic        dbg_wready,
    input  var logic [1:0]  dbg_bresp,
    input  var logic [11:0] dbg_bid,
    input  var logic        dbg_bvalid,
    output var logic        dbg_bready,
    output var logic [31:0] dbg_araddr,
    output var logic [3:0]  dbg_arlen,
    output var logic [11:0] dbg_arid,
    output var logic        dbg_arvalid,
    input  var logic        dbg_arready,
    input  var logic [31:0] dbg_rdata,
    input  var logic [1:0]  dbg_rresp,
    input  var logic [11:0] dbg_rid,
    input  var logic        dbg_rlast,
    input  var logic        dbg_rvalid,
    output var logic        dbg_rready,

    // --- everything else ---------------------------------------------------
    output var logic [11:0] dflt_awid,
    output var logic        dflt_awvalid,
    input  var logic        dflt_awready,
    output var logic        dflt_wlast,
    output var logic        dflt_wvalid,
    input  var logic        dflt_wready,
    input  var logic [1:0]  dflt_bresp,
    input  var logic [11:0] dflt_bid,
    input  var logic        dflt_bvalid,
    output var logic        dflt_bready,
    output var logic [3:0]  dflt_arlen,
    output var logic [11:0] dflt_arid,
    output var logic        dflt_arvalid,
    input  var logic        dflt_arready,
    input  var logic [31:0] dflt_rdata,
    input  var logic [1:0]  dflt_rresp,
    input  var logic [11:0] dflt_rid,
    input  var logic        dflt_rlast,
    input  var logic        dflt_rvalid,
    output var logic        dflt_rready
);

  localparam int unsigned RAM_AW = $clog2(RAM_WORDS);

  // ------------------------------------------ this domain's own reset

  // **THE RESET ARRIVES FROM THE MACHINE'S DOMAIN AND IS SYNCHRONISED HERE, IN
  // THE ONE PLACE THAT HAS TO KNOW.**  The board makes one reset --- the clock
  // manager not locked, or the fabric-reset button --- in the machine's
  // domain, and a reset released asynchronously to this clock is a reset some
  // of these registers leave a clock before the others.  The alternative was a
  // second synchroniser in the board's top level and a third in the check's
  // harness, which is two more descriptions of one thing.
  //
  // **THE TWO SIDES OF THE CROSSING THEREFORE COME OUT OF RESET AT DIFFERENT
  // INSTANTS, AND THAT IS HARMLESS BY CONSTRUCTION**: both sides are held
  // while `rst` stands, and what each sees of the other while it is held is
  // the other's idle level --- no request out, no acknowledgement back --- so
  // whichever leaves first finds the far side where it would have found it
  // anyway.
  logic [2:0] rst_sync;
  logic       rst_a;
  always_ff @(posedge clk) rst_sync <= {rst_sync[1:0], rst};
  assign rst_a = rst_sync[2];

  // **AND THE PACK SIDE'S INTERRUPT IS A LEVEL FROM THE MACHINE'S DOMAIN**,
  // into the core's external interrupt.  Two flip-flops, for the reason every
  // level that crosses gets two.  It is the only signal that reaches this
  // domain from the other one outside `cadr_soc_cross`, and
  // `rtl/plumbing/xilinx7/cadr_soc.xdc` bounds its route with everything else
  // that crosses.
  logic [1:0] irq_sync;
  always_ff @(posedge clk) begin
    if (rst_a) irq_sync <= 2'b00;
    else       irq_sync <= {irq_sync[0], ext_irq};
  end

  // --------------------------------------------------------- the core's seams

  logic        instr_req, instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_addr, instr_rdata;

  logic        data_req, data_gnt, data_rvalid, data_we, data_err;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;

  logic [4:0]  rf_raddr_a, rf_raddr_b, rf_waddr_wb;
  logic        rf_we_wb;
  logic [31:0] rf_wdata_wb, rf_rdata_a, rf_rdata_b;
  logic [ibex_cheriot_pkg::REGCAP_W-1:0] rf_wcap, rf_rcap_a, rf_rcap_b;
  logic        dummy_instr_id, dummy_instr_wb;

  logic        timer_irq;

  // ---------------------------------------------------------------- the core

  /* verilator lint_off PINCONNECTEMPTY */
  ibex_core #(
      .BaseIsa        (ibex_pkg::BaseIsaRV32I),
      .PMPEnable      (1'b0),
      .MHPMCounterNum (0),
      .RV32E          (1'b0),
      .RV32M          (ibex_pkg::RV32MFast),
      .RV32B          (ibex_pkg::RV32BNone),
      .RV32ZC         (ibex_pkg::RV32Zca),
      .BranchTargetALU(1'b0),
      .WritebackStage (1'b0),
      .ICache         (1'b0),
      .ICacheECC      (1'b0),
      .BranchPredictor(1'b0),
      .DbgTriggerEn   (1'b0),
      .SecureIbex     (1'b0),
      .DummyInstructions(1'b0),
      .RegFileECC     (1'b0),
      .MemECC         (1'b0),
      // The reset vector is `{boot_addr[31:8], 8'h80}` and the trap vector
      // table is the 128 bytes below it, so the firmware's link script puts
      // the vectors at 0 and `_start` at 0x80.  Ibex's own assertion demands
      // that the low byte of this be zero.
      .DmBaseAddr     (32'h0000_0000),
      .DmAddrMask     (32'h0000_0000),
      .DmHaltAddr     (32'h0000_0000),
      .DmExceptionAddr(32'h0000_0000)
  ) u_cpu (
      .clk_i (clk),
      .rst_ni(!rst_a),

      .hart_id_i  (32'd0),
      .boot_addr_i(32'h0000_0000),
      // CHERIoT is in this core and is off here: this is a plain RV32IMC
      // machine and the capability half of the register file folds with it.
      .cheriot_enable_i(ibex_pkg::IbexMuBiOff),

      .instr_req_o   (instr_req),
      .instr_gnt_i   (instr_gnt),
      .instr_rvalid_i(instr_rvalid),
      .instr_addr_o  (instr_addr),
      .instr_rdata_i (instr_rdata),
      .instr_err_i   (instr_err),

      .data_req_o   (data_req),
      .data_gnt_i   (data_gnt),
      .data_rvalid_i(data_rvalid),
      .data_we_o    (data_we),
      .data_be_o    (data_be),
      .data_addr_o  (data_addr),
      .data_wdata_o (data_wdata),
      .data_tag_o   (),
      .data_rdata_i (data_rdata),
      .data_tag_i   (1'b0),
      .data_err_i   (data_err),

      .dummy_instr_id_o(dummy_instr_id),
      .dummy_instr_wb_o(dummy_instr_wb),
      .rf_raddr_a_o    (rf_raddr_a),
      .rf_raddr_b_o    (rf_raddr_b),
      .rf_waddr_wb_o   (rf_waddr_wb),
      .rf_we_wb_o      (rf_we_wb),
      .rf_wdata_wb_ecc_o(rf_wdata_wb),
      .rf_rdata_a_ecc_i(rf_rdata_a),
      .rf_rdata_b_ecc_i(rf_rdata_b),
      .rf_wcap_ecc_wb_o(rf_wcap),
      .rf_rcap_a_ecc_i (rf_rcap_a),
      .rf_rcap_b_ecc_i (rf_rcap_b),

      // No instruction cache, so no cache RAMs.  The ports are tied off
      // rather than left off, so that an Ibex which grew one would be a
      // PINMISSING here and not a silent change of behaviour.
      .ic_tag_req_o  (), .ic_tag_write_o(), .ic_tag_addr_o(), .ic_tag_wdata_o(),
      .ic_tag_rdata_i('{default: '0}),
      .ic_data_req_o (), .ic_data_write_o(), .ic_data_addr_o(), .ic_data_wdata_o(),
      .ic_data_rdata_i('{default: '0}),
      .ic_scr_key_valid_i(1'b0),
      .ic_scr_key_req_o(),

      .irq_software_i(1'b0),
      .irq_timer_i   (timer_irq),
      .irq_external_i(irq_sync[1]),
      .irq_fast_i    (15'd0),
      .irq_nm_i      (1'b0),
      .irq_pending_o (),

      .debug_req_i(1'b0),
      .crash_dump_o(),
      .double_fault_seen_o(),

      .fetch_enable_i       (ibex_pkg::IbexMuBiOn),
      .mcounteren_writable_i(ibex_pkg::IbexMuBiOff),
      .alert_minor_o        (),
      .alert_major_internal_o(),
      .alert_major_bus_o    (),
      .core_busy_o          ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // The register file is not inside `ibex_core`: `ibex_top` is what normally
  // instantiates it, and `ibex_top` brings a clock gate and the cache RAMs
  // with it --- every one of which is a `prim_*` module and another vendored
  // file answering a question this board does not ask.  So the core is
  // instantiated bare and its register file beside it, which is the smallest
  // honest composition.  **THE FPGA VARIANT**, because it is distributed RAM
  // and the flip-flop one is a thousand registers.
  ibex_register_file_fpga #(
      .BaseIsa          (ibex_pkg::BaseIsaRV32I),
      .RV32E            (1'b0),
      .DataWidth        (32),
      .DummyInstructions(1'b0)
  ) u_rf (
      .clk_i (clk),
      .rst_ni(!rst_a),

      .test_en_i       (1'b0),
      .dummy_instr_id_i(dummy_instr_id),
      .dummy_instr_wb_i(dummy_instr_wb),
      .cheriot_enable_i(ibex_pkg::IbexMuBiOff),

      .raddr_a_i(rf_raddr_a),
      .rdata_a_o(rf_rdata_a),
      .rcap_a_o (rf_rcap_a),
      .raddr_b_i(rf_raddr_b),
      .rdata_b_o(rf_rdata_b),
      .rcap_b_o (rf_rcap_b),
      .waddr_a_i(rf_waddr_wb),
      .wdata_a_i(rf_wdata_wb),
      .wcap_a_i (rf_wcap),
      .we_a_i   (rf_we_wb)
  );

  // ---------------------------------------------------------------- the memory

  logic                  ram_a_en, ram_b_en, ram_b_we;
  logic [RAM_AW-1:0]     ram_a_addr, ram_b_addr;
  logic [31:0]           ram_a_rdata, ram_b_rdata;

  cadr_soc_ram #(
      .WORDS       (RAM_WORDS),
      .FIRMWARE_HEX(FIRMWARE_HEX)
  ) u_ram (
      .clk    (clk),
      .a_en   (ram_a_en),
      .a_addr (ram_a_addr),
      .a_rdata(ram_a_rdata),
      .b_en   (ram_b_en),
      .b_we   (ram_b_we),
      .b_be   (data_be),
      .b_addr (ram_b_addr),
      .b_wdata(data_wdata),
      .b_rdata(ram_b_rdata)
  );

  // ------------------------------------------------------- instruction fetch
  //
  // Always granted, answered one cycle later, one word a cycle.  **A fetch
  // from outside the memory comes back with `instr_err`**, which the core takes
  // as an instruction access fault and the firmware's trap handler prints:
  // the alternative is a core running whatever a wrapped address happened to
  // hold, which is the shape of fault nobody ever diagnoses.
  logic instr_in_ram;
  assign instr_in_ram = (instr_addr[31:RAM_AW+2] == '0);
  assign ram_a_en     = instr_req;
  assign ram_a_addr   = instr_addr[RAM_AW+1:2];
  assign instr_gnt    = instr_req;
  assign instr_rdata  = ram_a_rdata;

  always_ff @(posedge clk) begin
    if (rst_a) begin
      instr_rvalid <= 1'b0;
      instr_err    <= 1'b0;
    end else begin
      instr_rvalid <= instr_req;
      instr_err    <= instr_req && !instr_in_ram;
    end
  end

  // ------------------------------------------------------------ the data seam

  logic uart_sel, timer_sel;
  logic [31:0] uart_rdata, timer_rdata;

  logic br_req, br_done, br_err;
  logic [31:0] br_rdata;

  // Which of the four a load or a store is for.  **The decode is on the whole
  // address and nothing aliases**: an address in the low region above the
  // memory is not a wrapped memory address, it is one nothing implements, and
  // it goes to the catch-all and reads "NONE".  A region mapped twice is a
  // fault that presents as data appearing where nobody put it.
  logic in_ram, in_uart, in_timer, in_axi;
  assign in_ram   = (data_addr[31:RAM_AW+2] == '0);
  assign in_uart  = (data_addr[31:12] == UART_BASE[31:12]);
  assign in_timer = (data_addr[31:12] == TIMER_BASE[31:12]);
  assign in_axi   = !(in_ram || in_uart || in_timer);

  // One outstanding, and the grant is what starts it.  See the header for
  // what this costs and why the pipeline is not built.
  //
  // **AND THE GUARD IS BELT AND BRACES, MEASURED.**  Ibex's load-store unit
  // drops `data_req_o` at the grant and does not raise it again until
  // `data_rvalid_i`, so the seam is never OFFERED a second request and
  // `!d_busy` is never the thing that refuses one.  The record written to
  // prove otherwise --- `data_gnt = data_req`, the guard gone --- survives
  // every check, and `mutations/list.txt` records that as an equivalence
  // rather than leaving it to be filed as a hole.  The guard stays because it
  // is what makes the bridge's single held selection a property of THIS file
  // rather than of the core in front of it, and because a core that pipelined
  // its loads would otherwise break the bridge silently.
  //
  // **AND IT IS LOAD-BEARING IN A SECOND WAY NOW THAT THE BRIDGE IS A CLOCK
  // AWAY.**  This flag is what holds the next request off for one clock after
  // an answer, and one clock is exactly the margin the crossing's fourth phase
  // has: `cadr_soc_cross.sv` records the measurement --- of 273 requests, 129
  // arrive while the acknowledgement still stands at the second flip-flop of
  // the synchroniser and none while it stands at the first.  The crossing is
  // written not to need that (it holds its answer until the handshake has
  // closed, so a requester may ask on the very next clock), and the two
  // together are belt and braces on a seam where getting it wrong would hand
  // a load the answer to the one before it.
  logic d_busy, d_axi, fast_ans;

  assign data_gnt = data_req && !d_busy;

  assign ram_b_en   = data_gnt && in_ram;
  assign ram_b_we   = data_we;
  assign ram_b_addr = data_addr[RAM_AW+1:2];
  assign uart_sel   = data_gnt && in_uart;
  assign timer_sel  = data_gnt && in_timer;
  assign br_req     = data_gnt && in_axi;

  // What answers, and when.  A one-cycle source answers in the cycle after the
  // grant and its register still holds the word; the bridge answers with its
  // own `done`.
  logic axi_ans;
  assign axi_ans     = d_busy && d_axi && br_done;
  assign data_rvalid = fast_ans || axi_ans;
  assign data_err    = axi_ans && br_err;

  // **WHICH SOURCE ANSWERED IS HELD AND NOT RECOMPUTED.**  `data_addr` is not
  // guaranteed to stand after the grant, so a read multiplexer built off the
  // live address would select on whatever the core had moved on to.
  logic [1:0] d_src;
  localparam logic [1:0] SRC_RAM = 2'd0, SRC_UART = 2'd1, SRC_TIMER = 2'd2,
                         SRC_AXI = 2'd3;

  always_comb begin
    case (d_src)
      SRC_UART:  data_rdata = uart_rdata;
      SRC_TIMER: data_rdata = timer_rdata;
      SRC_AXI:   data_rdata = br_rdata;
      default:   data_rdata = ram_b_rdata;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst_a) begin
      d_busy   <= 1'b0;
      d_axi    <= 1'b0;
      fast_ans <= 1'b0;
      d_src    <= SRC_RAM;
    end else begin
      fast_ans <= 1'b0;
      if (data_gnt) begin
        d_busy   <= 1'b1;
        d_axi    <= in_axi;
        fast_ans <= !in_axi;
        d_src    <= in_axi   ? SRC_AXI
                  : in_uart  ? SRC_UART
                  : in_timer ? SRC_TIMER
                             : SRC_RAM;
      end
      if (fast_ans || axi_ans) d_busy <= 1'b0;
    end
  end

  // --------------------------------------------------- this system's own two

  cadr_soc_uart #(
      .CLK_HZ(CLK_HZ),
      .BAUD  (BAUD)
  ) u_uart (
      .clk  (clk),
      .rst  (rst_a),
      .sel  (uart_sel),
      .we   (data_we),
      .be   (data_be),
      .addr (data_addr[11:0]),
      .wdata(data_wdata),
      .rdata(uart_rdata),
      .tx   (uart_tx),
      .rx   (uart_rx)
  );

  cadr_soc_timer #(
      .CLK_HZ(CLK_HZ)
  ) u_timer (
      .clk  (clk),
      .rst  (rst_a),
      .sel  (timer_sel),
      .we   (data_we),
      .be   (data_be),
      .addr (data_addr[11:0]),
      .wdata(data_wdata),
      .rdata(timer_rdata),
      .irq  (timer_irq)
  );

  // The two low bits of a fetch address are always zero --- the fetch unit asks
  // for words --- so nothing here reads them.  Said out loud rather than
  // masked away, because a fetch unit that stopped aligning would be a change
  // this line would have hidden.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, instr_addr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

  // ----------------------------------------------- the crossing and the bridge
  //
  // **THE BRIDGE IS ON THE MACHINE'S CLOCK AND THIS IS THE SEAM.**  Everything
  // above runs on the core's own clock; everything below the crossing runs on
  // the machine's, where the four faces are.  `cadr_soc_cross.sv` carries the
  // whole argument for the shape --- a four-phase handshake, a payload that
  // has stopped moving before the level that points at it, and two flip-flops
  // on each level --- and `rtl/plumbing/xilinx7/cadr_soc.xdc` is where that
  // argument is told to the fitter.
  logic        x_req, x_we, x_gnt, x_done, x_err;
  logic [3:0]  x_be;
  logic [31:0] x_addr, x_wdata, x_rdata;

  cadr_soc_cross u_cross (
      .a_clk(clk), .a_rst(rst_a),
      .a_req(br_req), .a_we(data_we), .a_be(data_be), .a_addr(data_addr),
      .a_wdata(data_wdata),
      .a_done(br_done), .a_rdata(br_rdata), .a_err(br_err),

      .b_clk(axi_clk), .b_rst(axi_rst),
      .b_req(x_req), .b_we(x_we), .b_be(x_be), .b_addr(x_addr),
      .b_wdata(x_wdata),
      .b_gnt(x_gnt), .b_done(x_done), .b_rdata(x_rdata), .b_err(x_err)
  );

  cadr_soc_axi #(
      .PACK_BASE(PACK_BASE),
      .CON_BASE (CON_BASE),
      .DBG_BASE (DBG_BASE)
  ) u_axi (
      .clk(axi_clk), .rst(axi_rst),
      .req(x_req), .we(x_we), .be(x_be), .addr(x_addr),
      .wdata(x_wdata),
      // **THE GRANT IS READ NOW, WHERE IT USED TO REACH NOTHING.**  With the
      // seam a clock apart from the bridge, the crossing cannot know from the
      // asking side alone that the request has been taken: it holds `req` up
      // until this says so and drops it in the same clock, which is what stops
      // one load becoming two transactions when the bridge comes back to idle.
      .gnt(x_gnt),
      .done(x_done), .rdata(x_rdata), .err(x_err),

      .pack_awaddr(pack_awaddr), .pack_awlen(pack_awlen), .pack_awid(pack_awid),
      .pack_awvalid(pack_awvalid), .pack_awready(pack_awready),
      .pack_wdata(pack_wdata), .pack_wstrb(pack_wstrb), .pack_wlast(pack_wlast),
      .pack_wvalid(pack_wvalid), .pack_wready(pack_wready),
      .pack_bresp(pack_bresp), .pack_bid(pack_bid), .pack_bvalid(pack_bvalid),
      .pack_bready(pack_bready),
      .pack_araddr(pack_araddr), .pack_arlen(pack_arlen), .pack_arid(pack_arid),
      .pack_arvalid(pack_arvalid), .pack_arready(pack_arready),
      .pack_rdata(pack_rdata), .pack_rresp(pack_rresp), .pack_rid(pack_rid),
      .pack_rlast(pack_rlast), .pack_rvalid(pack_rvalid), .pack_rready(pack_rready),

      .con_awaddr(con_awaddr), .con_awlen(con_awlen), .con_awid(con_awid),
      .con_awvalid(con_awvalid), .con_awready(con_awready),
      .con_wdata(con_wdata), .con_wstrb(con_wstrb), .con_wlast(con_wlast),
      .con_wvalid(con_wvalid), .con_wready(con_wready),
      .con_bresp(con_bresp), .con_bid(con_bid), .con_bvalid(con_bvalid),
      .con_bready(con_bready),
      .con_araddr(con_araddr), .con_arlen(con_arlen), .con_arid(con_arid),
      .con_arvalid(con_arvalid), .con_arready(con_arready),
      .con_rdata(con_rdata), .con_rresp(con_rresp), .con_rid(con_rid),
      .con_rlast(con_rlast), .con_rvalid(con_rvalid), .con_rready(con_rready),

      .dbg_awaddr(dbg_awaddr), .dbg_awlen(dbg_awlen), .dbg_awid(dbg_awid),
      .dbg_awvalid(dbg_awvalid), .dbg_awready(dbg_awready),
      .dbg_wdata(dbg_wdata), .dbg_wstrb(dbg_wstrb), .dbg_wlast(dbg_wlast),
      .dbg_wvalid(dbg_wvalid), .dbg_wready(dbg_wready),
      .dbg_bresp(dbg_bresp), .dbg_bid(dbg_bid), .dbg_bvalid(dbg_bvalid),
      .dbg_bready(dbg_bready),
      .dbg_araddr(dbg_araddr), .dbg_arlen(dbg_arlen), .dbg_arid(dbg_arid),
      .dbg_arvalid(dbg_arvalid), .dbg_arready(dbg_arready),
      .dbg_rdata(dbg_rdata), .dbg_rresp(dbg_rresp), .dbg_rid(dbg_rid),
      .dbg_rlast(dbg_rlast), .dbg_rvalid(dbg_rvalid), .dbg_rready(dbg_rready),

      .dflt_awid(dflt_awid), .dflt_awvalid(dflt_awvalid),
      .dflt_awready(dflt_awready),
      .dflt_wlast(dflt_wlast), .dflt_wvalid(dflt_wvalid), .dflt_wready(dflt_wready),
      .dflt_bresp(dflt_bresp), .dflt_bid(dflt_bid), .dflt_bvalid(dflt_bvalid),
      .dflt_bready(dflt_bready),
      .dflt_arlen(dflt_arlen), .dflt_arid(dflt_arid), .dflt_arvalid(dflt_arvalid),
      .dflt_arready(dflt_arready),
      .dflt_rdata(dflt_rdata), .dflt_rresp(dflt_rresp), .dflt_rid(dflt_rid),
      .dflt_rlast(dflt_rlast), .dflt_rvalid(dflt_rvalid), .dflt_rready(dflt_rready)
  );

endmodule

`default_nettype wire
