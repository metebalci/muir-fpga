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
// what a CADR with an empty backplane slot does.

`default_nettype none

module cadr_memory_path (
    input  var logic        clk,          // 200 MHz, one tick = 5 ns
    input  var logic        rst,

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

    // What else the decode made of the address, so that a cycle nothing
    // answers can say why rather than merely time out.
    output var logic        nxm,          // Xbus space with nothing in it
    output var logic        unibus,       // the Unibus, which is its own slice
    output var logic        ub_msyn_o,    // -UB MSYN, brought out for a check
    output var logic        ub_ssyn_o,
    output var logic [2:0]  arb_stage,
    output var logic [17:0] ub_addr_o,
    output var logic [15:0] ub_rdata_o,

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
  logic [31:0] memory_rdata;
  logic ub_msyn, ub_write, ub_ssyn;
  assign ub_msyn_o = ub_msyn;
  assign ub_ssyn_o = ub_ssyn;
  assign ub_addr_o = ub_addr;
  assign ub_rdata_o = ub_rdata;
  logic [15:0] ub_rdata;

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
      .dev_rq     (dev_rq),
      .dev_write  (dev_write),
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

  // Above the register block there is nothing on this Unibus yet, so the top
  // of the page number goes nowhere: only 0o766xxx is answered.
  logic unused_page;
  assign unused_page = &{1'b0, ub_page[13:9]};

  cadr_spy_registers spy_registers (
      .clk        (clk),
      .rst        (rst),
      .mclk       (mclk),
      .ub_msyn    (ub_msyn),
      .ub_write   (ub_write),
      .ub_addr    (ub_addr),
      .ub_wdata   (wdata[15:0]),
      .ub_ssyn    (ub_ssyn),
      .ub_rdata   (ub_rdata),
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

  cadr_xbus_ddr main_memory (
      .clk      (clk),
      .rst      (rst),
      .sel      (is_memory),
      .dev_rq   (dev_rq),
      .dev_write(dev_write),
      .phys     (phys),
      .wdata    (wdata),
      .dev_ack  (memory_ack),
      .rdata    (memory_rdata),
      .mem_req  (mem_req),
      .mem_write(mem_write),
      .mem_addr (mem_addr),
      .mem_wdata(mem_wdata),
      .mem_done (mem_done),
      .mem_rdata(mem_rdata)
  );

  // The acknowledgements, joined as the open-collector `-XBUS.ACK` joins
  // them, and the word from whichever slave answered.
  assign dev_ack = memory_ack || device_ack;
  // The word from whichever slave answered. A Unibus register is sixteen bits
  // and reaches `MEM<15:0>`; the rest of the word is what nothing drives.
  assign rdata   = ub_ssyn      ? {16'hffff, ub_rdata}
                 : device_ack   ? device_rdata
                                : memory_rdata;

endmodule

`default_nettype wire
