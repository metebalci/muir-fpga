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
// **This is not a working CADR and is not meant to be.**  There is no memory
// behind it: `mem_done` is tied low, so the first cycle the boot PROM runs to
// main memory --- microcycle 535,791 of 600,000 --- never completes, and the
// machine stalls there for ever.  What it can show is that the fabric runs:
// the clock generator ticking, microcycles retiring, the PROM executing.  DDR
// behind `mem_*` is the next slice.
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

module cadr_arty #(
    parameter string PROM_HEX = "build/boot_prom.hex"
) (
    input  var logic       sysclk,   // 125 MHz, pin H16
    input  var logic [3:0] btn,
    output var logic [3:0] led
);

  // ------------------------------------------------------------ the clock
  //
  // 125 MHz in, 200 MHz out. The VCO must sit between 600 and 1200 MHz on a
  // -1 part: 125 x 8 is 1000, comfortably inside, and 1000 / 5 is the tick.
  logic clk_fb, clk_200_raw, clk, mmcm_locked;

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
  logic vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge, wrcyc;
  logic device, dev_rq, dev_write, promdisable, ub_msyn, ub_ssyn;
  logic n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc, nxm, unibus;
  logic memstart, timed_out, mbusy, mbusy_sync;
  logic mem_req, mem_write;

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
      // NO MEMORY. See the note at the top: the machine stalls at the boot
      // PROM's first main-memory cycle and stays there.
      .mem_done(1'b0), .mem_rdata(32'd0),
      .pc(pc), .lpc(lpc), .opc(opc), .st(st), .ir(ir), .a(a), .m(m),
      .alu(alu), .r(r), .ob(ob), .q(q), .dc(dc), .lc(lc), .vma(vma),
      .md(md), .vmaok(vmaok), .jcond(jcond), .nop(nop), .pcs1(pcs1),
      .pcs0(pcs0), .iwrited(iwrited), .clock_edge(clock_edge),
      .wrcyc(wrcyc), .device(device), .dev_rq(dev_rq),
      .dev_write(dev_write), .phys(phys), .promdisable(promdisable),
      .ub_msyn(ub_msyn), .ub_ssyn_o(ub_ssyn), .arb_stage(arb_stage),
      .n_memrq_o(n_memrq), .n_memack_o(n_memack),
      .n_memgrant_o(n_memgrant), .mbusy_o(mbusy), .mbusy_sync_o(mbusy_sync),
      .ub_addr_o(ub_addr),
      .ub_rdata_o(ub_rdata), .n_loadmd_o(n_loadmd), .rdcyc_o(rdcyc),
      .nxm(nxm), .unibus(unibus), .memstart(memstart),
      .timed_out(timed_out), .mem_req(mem_req), .mem_write(mem_write),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata)
  );

  // ------------------------------------------------------------- the LEDs
  //
  // `witness` is what keeps the machine alive through synthesis. Every output
  // of `cadr_machine` folds into it, so none of them is dead, and it is
  // registered so the fold is not a combinational path across the design.
  // It is not meant to be readable --- it is a load, and what it shows is
  // that the datapath is moving at all.
  logic witness;
  always_ff @(posedge clk) begin
    if (rst) begin
      witness <= 1'b0;
    end else begin
      witness <= ^{pc, lpc, opc, st, ir, a, m, alu, r, ob, q, dc, lc,
                   vma, md, phys, ub_addr, ub_rdata, arb_stage,
                   mem_addr, mem_wdata,
                   vmaok, jcond, nop, pcs1, pcs0, iwrited, clock_edge,
                   wrcyc, device, dev_rq, dev_write, promdisable,
                   ub_msyn, ub_ssyn,
                   n_memrq, n_memack, n_memgrant, n_loadmd, rdcyc,
                   nxm, unibus, memstart, mbusy, mbusy_sync,
                   mem_req, mem_write};
    end
  end

  // A microcycle is 145 ns at normal speed and the boot PROM runs at extra
  // slow, 220 ns, so this divides to something an eye can see: bit 23 of a
  // count of microcycles is about one and a half seconds.
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
  logic [25:0] tick;
  always_ff @(posedge clk) tick <= tick + 26'd1;

  // LD0 is the heartbeat and the other three are status. The heartbeat gets
  // the first LED because it is the one to look at first: it answers "is this
  // thing running at all", and every other light is meaningless until it says
  // yes. A dark LD0 means the board is not programmed or the MMCM never
  // locked; a blinking LD0 with the rest dark means the fabric is clocked and
  // the machine is not retiring microcycles, which is a different fault
  // entirely.
  assign led[0] = tick[25];      // the fabric is clocked          --- heartbeat
  assign led[1] = beat[23];      // microcycles are retiring
  assign led[2] = timed_out;     // a cycle reached the NXM timer
  assign led[3] = witness;       // the datapath is not optimised away

  // btn[3:1] are pins the board has and this design does not use. Reading
  // them keeps the ports legal without inventing behaviour for them.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, btn[3:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
