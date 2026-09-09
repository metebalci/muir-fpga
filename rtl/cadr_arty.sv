// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine on an Arty Z7-20: a top level with real pins.
//
// Everything else here is checked against muir and none of it has been near a
// chip.  This exists to find out whether the design can be built at all ---
// synthesised, placed, routed and written to a bitstream against a real part
// with real package pins --- which is a different question from whether it is
// correct, and one nothing in this repository has ever asked.
//
// **BY DEFAULT THIS IS NOT A WORKING CADR AND IS NOT MEANT TO BE.**  With
// `DDR` zero there is no memory behind it: `mem_done` is tied low, so the
// first cycle the boot PROM runs to main memory --- microcycle 536,303 of
// 600,000 --- never completes, and the machine stalls there for ever.  What
// it can show is that the fabric runs: the clock generator ticking,
// microcycles retiring, the PROM executing.
//
// `DDR` set puts the Zynq processing system and its DDR3 behind `mem_*`.  It
// is off for the same reason `PROBE_DEPTH` is, and the note beside that
// parameter is the whole argument: the design this file describes by default
// is the machine and nothing else, so what the machine costs and what the
// memory costs stay two questions.
//
// `PROVE` set builds one of the two boards that answer whether that memory
// works at all, and neither of them is the machine running out of it.  The
// machine is still in the design and still stalls on its own memory port
// exactly as the default board does; what changes is that `rtl/cadr_prove.sv`
// drives that port instead, with one word and one address, and somebody
// outside the design says whether the word arrived.  `PROVE=1` writes a word
// for a debugger to read; `PROVE=2` reads one a debugger wrote and WRITES IT
// BACK to a second address, so the comparing is done outside the design there
// too.  Neither needs anybody at the board.  That module's header is the
// whole argument for the two steps and for their order.
//
// TWO THINGS THIS FILE HAS TO GET RIGHT THAT ARE NOT OBVIOUS.
//
// **The board's clock is 125 MHz and the machine's tick is 5 ns.**  Every
// instant the CADR names is a multiple of five nanoseconds --- the seven read
// taps, the 80 ns bus setup, the 60 ns deskew --- and `cadr_phase_gen.sv`
// counts them directly.  Run the fabric from the 125 MHz pin and the taps
// become 8 ns apart and it is a different machine, one that would still build
// and still light LEDs.  So the 200 MHz comes from an MMCM: 125 x 8 = 1000 MHz
// at the VCO, divided by five.  A primitive rather than a generated IP core,
// because a primitive is one instantiation in a file somebody can read and an
// IP core is a directory of generated XML.
//
// **Every output has to reach a pin or synthesis will delete the machine.**
// `cadr_machine` brings out the whole datapath for the testbenches to compare
// --- PC, IR, the A and M buses, the ALU, twenty-odd more --- and a top level
// that left them unconnected would synthesise to almost nothing, place and
// route in seconds, and write a perfectly good bitstream of an empty part.
// That is the failure this project keeps meeting: not an error, but a
// plausible artefact.  So the wide outputs are reduced into one LED through a
// register, which costs four LUTs and keeps every one of them load-bearing.
// `vivado/bitstream.tcl` checks the utilisation against what the design is
// known to cost rather than trusting that the file exists.

`default_nettype none

// AND ONE THING IT DOES NOT DO BY DEFAULT.  `PROBE_DEPTH` is zero here, so
// the design this file describes is the machine and nothing else --- the same
// LUTs, the same registers, the same 28 block RAM tiles `vivado/bitstream.tcl`
// measures.  Setting it instantiates `cadr_probe.sv`, which records one
// sample a microcycle and hands it back over JTAG; `vivado/probe.tcl` builds
// that bitstream and reads it.  Off by default because an instrument in every
// bitstream is an instrument nobody measures the cost of, and because the two
// questions --- does the machine fit, and what does watching it cost --- are
// worth keeping apart.
//
// AND THE SAME FOR `DDR`, which is zero here, so nothing below instantiates
// `cadr_ps7.sv` or `cadr_axi_master.sv` and `mem_done` is tied low exactly as
// it has always been tied.  Setting it puts the processing system and DDR3
// behind the machine's memory port --- the piece with no muir reference of
// any kind --- and `vivado/bitstream.tcl` builds that board with `DDR=1`.
module cadr_arty #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    parameter int unsigned PROBE_DEPTH = 0,
    parameter int unsigned DDR = 0,
    // 0 the machine, 1 the fabric writes a word, 2 the fabric reads one back
    // and writes what it read to a second address.
    // See the note above the memory below: a `PROVE` board is a `DDR` board
    // by construction, because proving the port needs the port.
    parameter int unsigned PROVE = 0
) (
    input  var logic       sysclk,   // 125 MHz, pin H16
    input  var logic [3:0] btn,
    output var logic [3:0] led,
    // The two tricolour LEDs. Driven high to light, one pin a colour.
    output var logic       led4_r, led4_g, led4_b,
    output var logic       led5_r, led5_g, led5_b
);

  // ------------------------------------------------------------ the clock
  //
  // 125 MHz in, 200 MHz out. The VCO must sit between 600 and 1200 MHz on a
  // -1 part: 125 x 8 is 1000, comfortably inside, and 1000 / 5 is the tick.
  logic clk_fb, clk_200_raw, clk, mmcm_locked;

  // The eleven clock outputs this design does not take are left empty on
  // purpose --- that is how the primitive is written and what Xilinx's own
  // templates do --- so the style warning about it is turned off here rather
  // than answered with eleven wires nothing reads.
  /* verilator lint_off PINCONNECTEMPTY */
  MMCME2_BASE #(
      .CLKIN1_PERIOD  (8.000),   // 125 MHz
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(8.000),   // 1000 MHz at the VCO
      .CLKOUT0_DIVIDE_F(5.000)   // 200 MHz, one tick = 5 ns
  ) u_mmcm (
      .CLKIN1  (sysclk),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_200_raw),
      .LOCKED  (mmcm_locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .CLKFBOUTB()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  BUFG u_bufg (.I(clk_200_raw), .O(clk));

  // Reset while the MMCM has not locked, and on BTN0. Synchronised out of
  // the 200 MHz domain: `locked` is asynchronous to it by construction.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked || btn[0]};
  assign rst = rst_sync[3];

  // ---------------------------------------------------------- the machine

  logic [13:0] pc, lpc, opc;
  logic [31:0] st, a, m, alu, r, ob, q, vma, md;
  logic [47:0] ir;
  logic [9:0]  dc;
  logic [25:0] lc;
  logic [21:0] phys;
  logic [17:0] ub_addr;
  logic [15:0] ub_rdata;
  logic [2:0]  arb_stage;
  logic [31:0] mem_addr, mem_wdata;
  // MEM<31:0> on its way to an Xbus slave. No slave exists, so nothing
  // reads it --- but it is an output of `cadr_machine` and the fold below
  // is what keeps it from being deleted along with whatever computes it.
  logic [31:0] dev_wdata;
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge, wrcyc;
  logic device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, timed_out, mbusy, mbusy_sync;
  logic mem_req, mem_write;
  // The answer, from whatever is behind the memory port. Driven in one of the
  // two arms of the `DDR` generate below and nowhere else.
  logic mem_done;
  logic [31:0] mem_rdata;
  // A write or read that came back SLVERR or DECERR, held. Zero when there is
  // no memory, so LD5's blue is dark on the board this file builds by default.
  logic ddr_error;

  // LD4's three colours, as {red, green, blue}. It is a wire and not three
  // assignments because WHAT LD4 SAYS DEPENDS ON THE BOARD: on the machine it
  // is where the boot has got to, and on a `PROVE` board it is the witness's
  // verdict. Driven from exactly one of two generate blocks, one down in the
  // memory and one beside the other lamps, so that neither configuration
  // leaves a signal the other one reads. Getting that wrong is an
  // UNUSEDSIGNAL and `build/arty.pass` says so.
  logic [2:0] lamp4;

  // A `PROVE` board is a `DDR` board: the whole of what it proves is that the
  // processing system's memory answers, and there is nothing to prove without
  // the port. Written as one localparam rather than left to whoever sets the
  // generics, because `PROVE=1` alone silently building the default board is
  // the shape of failure this project keeps meeting --- a switch that reads as
  // set and does nothing.
  localparam int unsigned PORT = ((DDR != 0) || (PROVE != 0)) ? 1 : 0;

  // The heartbeat's counter. Declared here and counted down in the lamps
  // where its comment is, because a `PROVE` board's LD4 blinks off it and the
  // memory generate above the lamps is where that lamp is driven from.
  logic [25:0] tick;

  // ------------------------------------------------ the witness's numbers
  //
  // WHERE, AND WHAT. One address in the region `rtl/cadr_ddr_map.sv` reserves
  // for the machine's main memory, and one word to put there. Both are chosen
  // so that a WRONG one is visible to somebody reading DDR from outside, which
  // is the only property that matters here --- the observer cannot be fooled
  // by a fabric that is consistently wrong, but it can be fooled by a value
  // that a broken bus would have produced anyway.
  //
  //   the address    `main_byte_address(22'o12345671)`, which is word
  //                  2,739,129 of the 3,932,160 the machine can reach ---
  //                  0x18A7_2EE4. Not the base: a bus stuck at zero, or one
  //                  that lost its high bits, lands on the base, so the base
  //                  is the one address that cannot tell you anything. Its
  //                  bits alternate, so a dropped or doubled address bit
  //                  moves it somewhere unrelated and the word is simply not
  //                  there. And **bit 2 is set**, which is the sharp part:
  //                  `cadr_axi_widen.sv` puts the word in the HIGH half of
  //                  the 64-bit beat at 0x18A7_2EE0, so the word at
  //                  0x18A7_2EE4's neighbour is the one a strobe pattern that
  //                  opens both halves would destroy. Reading that neighbour
  //                  is what makes the check able to fail.
  //
  //   the word       0x8A5C_36E1. Four different bytes, none of them 0x00 or
  //                  0xFF, each with three or four bits set, so a lane stuck
  //                  either way shows in every lane. Its halves differ and
  //                  neither is a rotation of the other, so a lane swap
  //                  shows. Bit 0 and bit 31 are both set, so a shift either
  //                  way shows. Reversed byte for byte it is 0xE1365C8A, so
  //                  an endianness swap shows. And it is not the address, nor
  //                  the address shifted, which is CLAUDE.md's
  //                  bridge-writes-the-address-instead-of-the-data in the one
  //                  place here where it could happen.
  //
  // THE FILLER IS ITS COMPLEMENT, 0x75A3_C91E, and that is not decoration.
  // The neighbourhood is filled with it from the debugger before the port is
  // released, so every word that should not have changed differs from `WORD`
  // in every bit. CLAUDE.md's "a stimulus that poisons cannot move with the
  // bug": against a neighbourhood of zeros, a word that half-landed reads as
  // plausible. `docs/board.md` will carry the procedure; the numbers live
  // here, once.
  //
  //   the second     `main_byte_address(22'o12345706)`, 0x18A7_2F18. A
  //   address        `PROVE=2` board reads `PROVE_ADDR` and writes WHAT CAME
  //                  BACK here, so that the debugger and not the fabric does
  //                  the comparing. Chosen the same way as the first, and for
  //                  four reasons:
  //
  //                  **A DIFFERENT BEAT.** Its beat is 0x18A7_2F18 and the
  //                  read's is 0x18A7_2EE0, seven beats apart, so the
  //                  write-back cannot touch the word it just read --- and
  //                  the read's beat is checked to be unchanged afterwards,
  //                  which is what says so.
  //
  //                  **BIT 2 CLEAR, WHERE THE READ'S IS SET.** The read
  //                  takes the HIGH half of its beat and the write-back
  //                  opens the LOW half of its own, so a widening stuck on
  //                  one half is caught in one direction or the other: stuck
  //                  low, the read brings back filler; stuck high, the word
  //                  lands on this address's neighbour instead.
  //
  //                  **INSIDE THE POISONED BLOCK, WITH ITS OWN NEIGHBOUR IN
  //                  IT TOO.** 0x18A7_2F1C is the other half of this beat
  //                  and carries the filler like everything else, so a
  //                  strobe pattern that opened both halves of the
  //                  write-back destroys a word the debugger prints.
  //
  //                  **NOT THE BASE, AND NOT THE READ'S ADDRESS SHIFTED.**
  //                  It differs from `PROVE_ADDR` in bits 2 through 8, so a
  //                  dropped or doubled bit among the low nine moves the
  //                  write-back somewhere the block still shows.
  localparam logic [31:0] PROVE_ADDR = cadr_ddr_map::main_byte_address(22'o12345671);
  localparam logic [31:0] PROVE_WORD = 32'h8A5C_36E1;
  localparam logic [31:0] PROVE_ECHO = cadr_ddr_map::main_byte_address(22'o12345706);

  cadr_machine #(
      .PROM_HEX(PROM_HEX)
  ) u_machine (
      .clk(clk), .rst(rst),
      // Nothing raises an interrupt and nothing answers a device cycle: the
      // Xbus devices are their own slices and none of them exists.
      .sintr(1'b0), .device_ack(1'b0), .device_rdata(32'd0),
      // 32 boards of 64K words, which is muir's own default and what every
      // trace in this repository was taken with.
      .boards(7'd32),
      // The memory, or the absence of one: see the `DDR` generate below.
      .mem_done(mem_done), .mem_rdata(mem_rdata),
      .pc(pc), .lpc(lpc), .opc(opc), .st(st), .ir(ir), .a(a), .m(m),
      .alu(alu), .r(r), .ob(ob), .q(q), .dc(dc), .lc(lc), .vma(vma),
      .md(md), .vmaok(vmaok), .jcond(jcond), .nop(nop), .pcs1(pcs1),
      .pcs0(pcs0), .iwrited(iwrited), .clock_edge(clock_edge),
      .wrcyc(wrcyc), .device(device), .dev_rq(dev_rq),
      .dev_write(dev_write), .dev_wdata(dev_wdata),
      .phys(phys), .promdisable(promdisable),
      .ub_msyn(ub_msyn), .ub_ssyn_o(ub_ssyn), .arb_stage(arb_stage),
      .n_memrq_o(n_memrq), .n_memack_o(n_memack),
      .n_memgrant_o(n_memgrant), .mbusy_o(mbusy), .mbusy_sync_o(mbusy_sync),
      .ub_addr_o(ub_addr),
      .ub_rdata_o(ub_rdata), .n_loadmd_o(n_loadmd), .rdcyc_o(rdcyc),
      .nxm(nxm), .unibus(unibus), .memstart(memstart),
      .timed_out(timed_out), .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata)
  );

  // ----------------------------------------------------------- the memory
  //
  // `DDR` puts the Zynq processing system behind the machine's memory port:
  // `cadr_axi_master.sv` turning a request into a transaction, the generated
  // `cadr_ps7.sv` carrying it to `S_AXI_HP0`, and `cadr_axi_widen.sv` between
  // them.
  // **This is the piece with no muir reference at all** --- nothing in MIT's
  // drawings is an AXI master --- so what holds it is the protocol, the
  // read-back, and eventually the board.
  //
  // THE PORT IS DEAD UNTIL SOFTWARE SAYS OTHERWISE, and that is what lets
  // this work with nobody at the board. `ps7_post_config` writes
  // `LVL_SHFTR_EN` and clears `FPGA_RST_CTRL`; until it has, the PS-PL level
  // shifters are off and `S_AXI_HP0` answers nothing at all. `hp0_aresetn` is
  // the PS7 output that says the port is live, and the adapter is held in
  // reset by it --- so before Linux is up the machine hangs on its first
  // memory cycle, which is exactly what it does with `DDR` off, and after
  // Linux is up it does not. Nobody has to arm anything.
  //
  // THE FABRIC CLOCK STAYS ON THE PIN. `hp0_aclk` is a PS7 *input* and takes
  // the MMCM's 200 MHz: the fabric clocks the port rather than the other way
  // round. Driving the fabric from `FCLK_CLK0` is the obvious move now that
  // the PS is in the design and it is wrong --- programming a `.bit` over
  // JTAG does not start the PS, so the board would be dark until somebody
  // booted it, and nothing in this slice needs FCLK.
  //
  // ONE WORD A TRANSACTION, IN A FULL-WIDTH BEAT. `cadr_axi_master` speaks 32
  // bits and `S_AXI_HP0` is used at its native 64; the beat is the port's
  // full width, with the byte strobes choosing which half of it the word
  // belongs in and a lane select on the way back. That conversion is
  // `rtl/cadr_axi_widen.sv` and its header is the argument for all of it ---
  // including why it is a module: this file cannot be simulated, so anything
  // written here is held by lint and the fitter and nothing else, and a lane
  // selected from the wrong channel is neither a lint error nor a fitter
  // one.
  if (PORT != 0) begin : g_ddr

    // The port's reset, out of the PS at whatever moment software runs
    // post-config, and asynchronous to this clock by construction --- so it
    // is synchronised in, the same way `mmcm_locked` is.
    logic       hp0_aresetn;
    logic [2:0] port_rst_sync;
    always_ff @(posedge clk) begin
      port_rst_sync <= {port_rst_sync[1:0], hp0_aresetn};
    end

    logic axi_rst;
    assign axi_rst = rst || !port_rst_sync[2];

    // WHAT THE ADAPTER IS ASKED FOR, which is the machine's request on the
    // board this file exists to build and the witness's on a `PROVE` one.
    // Named apart from `mem_*` deliberately: `mem_*` is what `cadr_machine`
    // brings out and it keeps meaning that in every configuration, including
    // the one where nothing downstream is listening to it.
    logic        port_req, port_write;
    logic [31:0] port_addr, port_wdata;
    logic        port_done, port_error;
    logic [31:0] port_rdata;

    // The adapter's AXI4 side, 32 bits wide.
    logic [31:0] awaddr, araddr, wdata;
    logic [7:0]  awlen, arlen;
    logic [2:0]  awsize, arsize;
    logic [1:0]  awburst, arburst, bresp, rresp;
    logic [3:0]  wstrb;
    logic        awvalid, awready, wvalid, wready, wlast;
    logic        bvalid, bready, arvalid, arready, rvalid, rready, rlast;
    logic [31:0] rdata;

    // The port's side, 64 bits wide.
    logic [31:0] hp0_awaddr, hp0_araddr;
    logic [3:0]  hp0_awlen, hp0_arlen;
    logic [1:0]  hp0_awsize, hp0_arsize;
    logic [63:0] hp0_wdata, hp0_rdata;
    logic [7:0]  hp0_wstrb;

    // ------------------------------------------------- who drives the port
    //
    // THE MACHINE, or the witness that goes ahead of it. `rtl/cadr_prove.sv`
    // has the argument for the two steps; what belongs here is only that it
    // drives `mem_*`'s own wires into the same adapter, the same widening and
    // the same PS7 that the machine will drive --- a witness with a path of
    // its own would prove that path and say nothing about this one.
    if (PROVE == 0) begin : g_machine_drives

      assign port_req   = mem_req;
      assign port_write = mem_write;
      assign port_addr  = mem_addr;
      assign port_wdata = mem_wdata;
      assign mem_done   = port_done;
      assign mem_rdata  = port_rdata;

    end else begin : g_prove

      // A LEVEL, AND WHAT HOLDS IT UP DECIDES WHETHER ANYBODY HAS TO BE
      // HERE. `cadr_prove` runs one sequence per rise of `go` and needs it
      // to fall before another, so a `go` tied high is exactly one sequence
      // at the moment the port comes live --- which is both steps' whole
      // requirement: it must happen with nobody at the board, because the
      // board is on the end of a JTAG cable and the port comes live whenever
      // software says so.
      //
      // AND THE NEXT ONE IS A RESET AND NOT A FINGER. `SAXIHP0ARESETN`
      // follows `LVL_SHFTR_EN` at 0xF8000900 --- measured at 700b98a --- so
      // writing that register 0x0 then 0xF drops `axi_rst` and raises it,
      // the witness returns to IDLE and runs the whole sequence again. Step
      // three's first draft tied this to BTN1 and answered on LD4, which
      // needed somebody in the room for both halves; the write-back to
      // `PROVE_ECHO` and this re-arm are what took the person out.
      logic prove_go;
      assign prove_go = 1'b1;

      logic prove_has_run, prove_matched;

      cadr_prove u_prove (
          // The three constants the whole exercise is about, tied here
          // because this is the file that chose them.
          .addr  (PROVE_ADDR),
          .word  (PROVE_WORD),
          // Where a read puts what came back. A write board never reads it.
          .echo_addr(PROVE_ECHO),
          .writes(PROVE == 1),
          .clk(clk),
          // Held while the port is dead, so nothing goes out before
          // `SAXIHP0ARESETN` says `S_AXI_HP0` can answer it.
          .rst(axi_rst),
          .go(prove_go),
          .mem_req(port_req), .mem_write(port_write),
          .mem_addr(port_addr), .mem_wdata(port_wdata),
          .mem_done(port_done), .mem_rdata(port_rdata),
          .mem_error(port_error),
          .has_run(prove_has_run), .matched(prove_matched)
      );

      // THE MACHINE GETS NOTHING, exactly as on the board with no memory at
      // all. It reaches its first main-memory cycle at microcycle 536,303,
      // the NXM timer ends it at about 4.25 us, and it carries on --- so
      // LD0, LD1, LD2 and LD3 read on a `PROVE` board exactly as
      // `docs/board.md` tabulates them for a board with no memory, and the
      // one lamp that changes is LD4.
      assign mem_done  = 1'b0;
      assign mem_rdata = 32'd0;

      // LD4 IS A LAMP HERE AND NO LONGER THE OBSERVER. Red until something
      // has completed, and it BLINKS while the port is still dead, because
      // "nobody has run ps7_post_config" and "the port swallowed the
      // transaction" are two different faults and a steady red would be
      // both of them. Green is the sequence that completed and was right;
      // blue is one that completed and was wrong --- a word that came back
      // different, or a SLVERR or DECERR on either transaction. Nothing
      // else can light it.
      //
      // WHAT SAYS WHETHER THE READ IS RIGHT IS `PROVE_ECHO` AND NOT THIS.
      // `matched` compares what came back against a constant this fabric
      // holds, so a witness that read the wrong lane and one that held the
      // wrong constant agree with each other and both light green. The
      // write-back puts the word itself where a debugger can read it, and
      // that is what `vivado/prove_read.tcl` asserts. This lamp costs
      // nothing and is for whoever happens to be at the board.
      assign lamp4 = {!prove_has_run && (port_rst_sync[2] || tick[24]),
                      prove_has_run &&  prove_matched,
                      prove_has_run && !prove_matched};

    end

    cadr_axi_master u_axi (
        .clk(clk), .rst(axi_rst),
        .mem_req(port_req), .mem_write(port_write),
        .mem_addr(port_addr), .mem_wdata(port_wdata),
        .mem_done(port_done), .mem_rdata(port_rdata), .mem_error(port_error),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    // The widening: `rtl/cadr_axi_widen.sv`, and it is a module rather than
    // the six assignments it used to be here because this file cannot be
    // simulated and a module can. Its header has the whole of the conversion;
    // what belongs here is only that the payload goes through it and every
    // handshake does not.
    cadr_axi_widen u_widen (
        .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
        .s_wdata(wdata), .s_wstrb(wstrb),
        .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
        .s_rdata(rdata),
        .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize),
        .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb),
        .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize),
        .m_rdata(hp0_rdata)
    );

    cadr_ps7 u_ps7 (
        .hp0_aclk(clk),
        .hp0_aresetn(hp0_aresetn),
        .hp0_awaddr(hp0_awaddr),
        // AXI3 at the port: four bits of length, two of size. One beat, and
        // the beat is the port's whole width.
        .hp0_awlen(hp0_awlen),
        .hp0_awsize(hp0_awsize),
        .hp0_awburst(awburst),
        .hp0_awvalid(awvalid), .hp0_awready(awready),
        .hp0_wdata(hp0_wdata), .hp0_wstrb(hp0_wstrb),
        .hp0_wlast(wlast), .hp0_wvalid(wvalid), .hp0_wready(wready),
        .hp0_bresp(bresp), .hp0_bvalid(bvalid), .hp0_bready(bready),
        .hp0_araddr(hp0_araddr),
        .hp0_arlen(hp0_arlen),
        .hp0_arsize(hp0_arsize),
        .hp0_arburst(arburst),
        .hp0_arvalid(arvalid), .hp0_arready(arready),
        .hp0_rdata(hp0_rdata), .hp0_rresp(rresp), .hp0_rlast(rlast),
        .hp0_rvalid(rvalid), .hp0_rready(rready)
    );

    // Held once it has ever happened: an error is a fault to find, not a
    // state to watch flicker past.
    logic error_seen;
    always_ff @(posedge clk) begin
      if (rst) error_seen <= 1'b0;
      else if (port_error) error_seen <= 1'b1;
    end
    assign ddr_error = error_seen;

  end else begin : g_nomem

    // NO MEMORY, which is what this top level has always been. The machine
    // stalls at the boot PROM's first main-memory cycle and stays there, and
    // `mem_req`, `mem_write`, `mem_addr` and `mem_wdata` reach nothing but
    // the `witness` fold below --- which is the only thing keeping them, and
    // whatever computes them, out of the bin.
    assign mem_done  = 1'b0;
    assign mem_rdata = 32'd0;
    assign ddr_error = 1'b0;

  end

  // ------------------------------------------------------------ the probe
  //
  // One sample a microcycle of the columns `build/rtl.golden` carries, held
  // in block RAM and shifted out over JTAG, so that what the *board* computes
  // can be diffed against what muir computes. `rtl/cadr_probe.sv` is the
  // whole of it and its header says why it is not an ILA.
  //
  // **THE COLUMN LIST AND THE BIT LAYOUT ARE THAT FILE'S**, one port a
  // column, so that this file does not hold a second copy of them to drift.
  // What is here is the two things only a top level can say: which net is
  // which column, and that `-VMAOK` is the trace's polarity where
  // `cadr_machine` brings out the logical one the jump conditions take.
  if (PROBE_DEPTH > 0) begin : g_probe
    // The JTAG scan chain the readout uses.  USER1 --- IR 0x02 on a 7-series
    // part --- which `vivado/probe.tcl` selects by name and by code.
    //
    // RESET, RUNTEST, TCK, TMS and UPDATE are left empty because nothing here
    // reads them: the pointer moves on CAPTURE, so UPDATE is not needed, and
    // that is the point of moving it there. See `cadr_probe.sv`.
    logic bscan_drck, bscan_sel, bscan_shift, bscan_capture, bscan_tdi;
    logic bscan_tdo;
    /* verilator lint_off PINCONNECTEMPTY */
    BSCANE2 #(
        .JTAG_CHAIN(1)
    ) u_bscan (
        .CAPTURE(bscan_capture),
        .DRCK   (bscan_drck),
        .SEL    (bscan_sel),
        .SHIFT  (bscan_shift),
        .TDI    (bscan_tdi),
        .TDO    (bscan_tdo),
        .RESET(), .RUNTEST(), .TCK(), .TMS(), .UPDATE()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    cadr_probe #(
        .DEPTH(PROBE_DEPTH)
    ) u_probe (
        .clk(clk), .rst(rst),
        // ONE SAMPLE A MICROCYCLE, on the machine's own boundary. A
        // free-running probe at 200 MHz would mostly record a machine
        // standing still and would line up with no row of anything.
        .qualify(clock_edge),
        .pc(pc), .ir(ir), .q(q), .a(a), .m(m), .alu(alu), .r(r), .ob(ob),
        .dc(dc), .opc(opc), .st(st), .lc(lc),
        .iwrited(iwrited), .nop(nop), .n_vmaok(!vmaok), .jcond(jcond),
        .pcs1(pcs1), .pcs0(pcs0),
        .lpc(lpc), .md(md), .vma(vma), .promdis(promdisable),
        .jtag_drck(bscan_drck), .jtag_sel(bscan_sel),
        .jtag_shift(bscan_shift), .jtag_capture(bscan_capture),
        .jtag_tdi(bscan_tdi), .jtag_tdo(bscan_tdo)
    );
  end

  // ------------------------------------------------------------- the LEDs
  //
  // `witness` is what keeps the machine alive through synthesis. Every output
  // of `cadr_machine` folds into it, so none of them is dead, and it is
  // registered so the fold is not a combinational path across the design.
  // It is not meant to be readable --- it is a load, and what it shows is
  // that the datapath is moving at all.
  //
  // **All forty-nine of them, including the ones something else already
  // reads** --- `clock_edge`, `promdisable`, `timed_out`, `n_memack` drive
  // LEDs as well and are still here, because the rule the comment states is
  // the whole specification and a fold with exceptions in it is not a rule
  // anybody can check. What checks it is `make build/arty.pass`: an output
  // left off the instantiation is a Verilator PINMISSING, which is how
  // `dev_wdata` was found missing from both.
  logic witness;
  always_ff @(posedge clk) begin
    if (rst) begin
      witness <= 1'b0;
    end else begin
      witness <= ^{pc, lpc, opc, st, ir, a, m, alu, r, ob, q, dc, lc,
                   vma, md, phys, ub_addr, ub_rdata, arb_stage,
                   mem_addr, mem_wdata, dev_wdata,
                   vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge,
                   wrcyc, device, dev_rq, dev_write, promdisable,
                   ub_msyn, ub_ssyn,
                   n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc,
                   nxm, unibus, memstart, timed_out, mbusy, mbusy_sync,
                   mem_req, mem_write};
    end
  end

  // A microcycle is 145 ns at normal speed and the boot PROM runs at extra
  // slow, 220 ns. Bit 23 of a count of them is 1.85 s a half-period --- a
  // 3.7 s cycle, which reads as a light that is on or off rather than one
  // that blinks. Bit 19 is 524,288 microcycles, 115 ms, about 4 Hz: fast
  // enough to be obviously alive and slow enough to count.
  logic [23:0] beat;
  always_ff @(posedge clk) begin
    if (rst) beat <= 24'd0;
    else if (clock_edge) beat <= beat + 24'd1;
  end

  // AND A HEARTBEAT THAT DOES NOT DEPEND ON THE MACHINE. Without it a dark
  // board means "not programmed", "the MMCM never locked" or "the machine
  // stalled", and those are three different problems that look the same. This
  // counts the master clock and nothing else, so it blinks whenever the
  // fabric is clocked at all --- about three times a second at 200 MHz --- and
  // it is deliberately not reset by `rst`, because `rst` is held while the
  // MMCM is unlocked and a heartbeat that stopped during reset would lose the
  // one case it exists to distinguish.
  always_ff @(posedge clk) tick <= tick + 26'd1;

  // LD0 is the heartbeat and the other three are status. The heartbeat gets
  // the first LED because it is the one to look at first: it answers "is this
  // thing running at all", and every other light is meaningless until it says
  // yes. A dark LD0 means the board is not programmed or the MMCM never
  // locked; a blinking LD0 with the rest dark means the fabric is clocked and
  // the machine is not retiring microcycles, which is a different fault
  // entirely.
  // LD2 counts NXM timeouts rather than showing the flag. `timed_out` is a
  // level that stands only while an unanswered cycle is up --- a sliver at the
  // end of each 4.25 us timeout --- so at the measured 168 kHz it integrates
  // to a light too faint to read, which is what the board showed. Counting the
  // rising edges and lighting a bit of the count turns it into a rate: bit 16
  // is 65,536 timeouts, about 0.39 s a half-period at that rate.
  //
  // The rate is the point. Faster means cycles are timing out more often.
  // An earlier version of this comment said dark would mean memory is
  // working. Measured, it does not: memory answers only the boot PROM's 512
  // page-0 cycles, once, and the 16,951 disk-controller polls time out
  // regardless, so this lamp reads the same with DDR and without. See
  // docs/board.md. The memory path is checked by the debugger reading DDR
  // from outside, not by any lamp here.
  logic timed_out_q;
  logic [16:0] nxm_count;
  always_ff @(posedge clk) begin
    timed_out_q <= timed_out;
    if (rst) nxm_count <= 17'd0;
    else if (timed_out && !timed_out_q) nxm_count <= nxm_count + 17'd1;
  end

  // ------------------------------------------------- the tricolour LEDs
  //
  // LD4 is where the machine is in its own boot, and it starts red because
  // "nothing has happened yet" must not look like "running".
  //
  //   red    the fabric is not running --- reset held or the MMCM unlocked
  //   blue   running out of the boot PROM, which is where it is today
  //   green  PROMDISABLE is set: running microcode out of the control store
  //
  // Blue is the honest colour for now. The boot PROM clears the control store
  // and never sets PROMDISABLE --- issue #1 lists it as unreached --- because
  // the microcode comes off a disk pack and there is no disk. So green is the
  // day a pack is readable, and this light will not change before then.
  //
  // ON A `PROVE` BOARD LD4 SAYS SOMETHING ELSE ENTIRELY --- the witness's
  // verdict, driven from `g_ddr.g_prove` where the numbers are. It is this
  // lamp and not LD5 because LD4's inputs are all read somewhere else as
  // well (`mmcm_locked` by the reset synchroniser, `promdisable` by the
  // `witness` fold), so overriding it leaves nothing undriven and nothing
  // unread; LD5's `bus_nxm` has no other reader and overriding that one would
  // have meant moving its counter into a generate to keep lint quiet.
  //
  // The colours are one axis either way: red is "nothing yet", and the two
  // boards disagree only about what would count as something.
  assign {led4_r, led4_g, led4_b} = lamp4;
  if (PROVE == 0) begin : g_lamp_boot
    assign lamp4 = {!mmcm_locked || rst,
                    mmcm_locked && !rst &&  promdisable,
                    mmcm_locked && !rst && !promdisable};
  end

  // LD5 is the bus, latched on each acknowledgement: red if that cycle was a
  // non-existent-memory reference, green if something answered it. It starts
  // red because before the first cycle nothing has answered, which is the
  // same distinction LD4 makes.
  //
  // `timed_out` and not the decode's `nxm`: there are two signals of that name
  // and they mean opposite kinds of thing. The decode's says the *address* is
  // Xbus space with nothing built there; the interface's register, which
  // `timed_out` carries out, says *this cycle* ended on the timer rather than
  // on a slave. Latching the decode's showed green on a board with no memory,
  // because the disk registers at 0o17377774 are in the decode's map and so
  // are not empty space --- they are simply unanswered.
  //
  // Today it is red and stays red: every cycle is the boot PROM polling a
  // disk controller that is not there. **It goes green the first time a real
  // slave answers**, which is what step 2 is for --- so this is the light to
  // watch when the PS block and DDR3 land.
  //
  // AND IT STAYS RED ON A `PROVE` BOARD TOO, which is not a fault. The
  // witness has the port and the machine's `mem_done` is tied low, so the
  // machine's own cycles still end on the timer. This lamp is about the
  // machine's memory and there is not one yet; LD4 is the one to read there.
  logic memack_q, bus_nxm;
  always_ff @(posedge clk) begin
    memack_q <= !n_memack;
    if (rst) begin
      bus_nxm <= 1'b1;                       // nothing has answered yet
    end else if (!n_memack && !memack_q) begin
      bus_nxm <= timed_out;                  // latch the outcome at the ack
    end
  end
  assign led5_r =  bus_nxm;
  assign led5_g = !bus_nxm;
  // Blue is the AXI answer, held once it has ever been an error: SLVERR or
  // DECERR from `S_AXI_HP0` is a cycle that reached the port and was refused,
  // which is a different fault from a cycle nothing answered and must not
  // look like one. Constant zero when `DDR` is off, so this is dark on the
  // board this file builds by default and the light means what it says.
  assign led5_b = ddr_error;

  assign led[0] = tick[25];      // the fabric is clocked          --- heartbeat
  assign led[1] = beat[19];      // microcycles are retiring, ~4 Hz
  assign led[2] = nxm_count[16]; // NXM timeouts, blinking at their rate
  assign led[3] = witness;       // the datapath is not optimised away

  // btn[3:1] are pins the board has and this design does not use. BTN1 was
  // a `PROVE=2` board's start button until the witness learned to write back
  // what it read; nothing presses anything now, and the pins are read here
  // only to keep them legal without inventing behaviour for them.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, btn[3:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
