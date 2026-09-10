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
  // The processor's own -XBUS.RQ, before the arbiter puts it on the bus.
  logic cpu_rq, cpu_write;
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
  logic        bus_write, bus_rq, bus_sel;
  assign bus_phys  = ch_own ? ch_addr  : phys;
  assign bus_wdata = ch_own ? ch_wdata : wdata;
  assign bus_write = ch_own ? ch_write : cpu_write;
  assign bus_rq    = changing ? 1'b0 : (ch_own ? ch_req : cpu_rq);
  assign bus_sel   = ch_own ? ch_memory : is_memory;

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
      .sel      (bus_sel),
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

  // The acknowledgements, joined as the open-collector `-XBUS.ACK` joins
  // them, and the word from whichever slave answered.  Nothing answers the
  // processor while the channel has the bus: its cycle simply waits, which is
  // what the per-word arbitration bounds.
  assign dev_ack = !ch_own && (memory_ack || device_ack);
  // The word from whichever slave answered. A Unibus register is sixteen bits
  // and reaches `MEM<15:0>`; the rest of the word is what nothing drives.
  assign rdata   = ub_ssyn      ? {16'hffff, ub_rdata}
                 : device_ack   ? device_rdata
                                : memory_rdata;

endmodule

`default_nettype wire
