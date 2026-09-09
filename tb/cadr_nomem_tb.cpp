// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What does the machine do with nothing behind `mem_*`?
//
// **THIS HARNESS DIES WITH THE CLAIM IT BACKS.**  `docs/board.md` has a
// paragraph on what the board shows with no memory --- LD1 blinking slowly
// rather than dark --- and every number in it comes from here.  When the PS
// block lands and that paragraph goes, this file goes with it.  It is not a
// check: it asserts nothing, it is not in `make check`, and it cannot fail.
//
// WHY IT EXISTS.  `rtl/cadr_arty.sv` said the machine "stalls there for ever"
// at the boot PROM's first main-memory cycle, and the board said otherwise:
// Mete reported LD1 blinking, slowly.  The prediction was wrong and re-reading
// the RTL would have produced another prediction.  So the configuration the
// bitstream actually has --- `mem_done` tied low, `mem_rdata` zero, which is
// the instantiation in `cadr_arty.sv` --- was run in simulation and measured.
//
// An unanswered cycle does not stall the machine; it ends on the NXM timer,
// about 4.25 us later, and the machine goes on.  So the board is not stuck,
// it is running about seven times slow, and a light that would have been
// motionless blinks instead.  A wrong sentence in the documentation was
// corrected by measurement rather than by reasoning again, which is why the
// measurement is worth keeping runnable.
//
// MEASURED at 200 MHz over 40,000,000 ticks --- 200 ms of machine time, this
// file's default, and the single run every figure here comes from:
//
//     microcycles        590,925
//     first mem_req      tick 23,597,357, microcycle 536,303
//     NXM timeouts       13,783 in the 82 ms after it, which is 168 kHz
//     after that cycle   1.50 us per microcycle, against 0.22 normal
//     beat[19]           toggles every 0.79 s
//
// `docs/board.md` quotes 30,590 timeouts in 300 ms, from a longer run. The
// rate is the figure to compare: the count depends on where the run stops,
// and timeouts only begin at the first memory cycle, 118 ms in.
//
// There is no Makefile rule on purpose: this was added at a stop, and the rule
// belongs to whoever owns the Makefile.  Build it by hand, from the repository
// root, with `build/boot_prom.hex` already made:
//
//     verilator --cc --exe --build -Wall -O2 -CFLAGS -O2 -Irtl \
//         -Mdir build/obj_nomem \
//         -GPROM_HEX='"'"$PWD"'/build/boot_prom.hex"' \
//         --top-module cadr_machine \
//         rtl/cadr_phase_gen.sv rtl/cadr_microcycle.sv rtl/cadr_ddr_map.sv \
//         rtl/cadr_xbus_decode.sv rtl/cadr_busint_xbus.sv rtl/cadr_xbus_ddr.sv \
//         rtl/cadr_spy_registers.sv rtl/cadr_memory_path.sv rtl/cadr_machine.sv \
//         "$PWD"/tb/cadr_nomem_tb.cpp
//     build/obj_nomem/Vcadr_machine [ticks]
//
// It takes one argument, the tick count, so a shorter run is a smaller number
// rather than an edit.  Below about 24 million it does not reach the first
// memory cycle and prints only the counts before it.
#include <cstdio>
#include <cstdlib>
#include "Vcadr_machine.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_machine;
  const long TICKS = argc > 1 ? atol(argv[1]) : 40000000L;

  // The step-1 bitstream's configuration exactly, and that is the point: no
  // interrupt, no Xbus device, 32 boards of memory declared and none behind
  // the bridge. Change any of these and it is measuring a different board.
  dut->clk = 0; dut->rst = 1; dut->sintr = 0; dut->boards = 32;
  dut->device_ack = 0; dut->device_rdata = 0;
  dut->mem_done = 0; dut->mem_rdata = 0;          // NO MEMORY
  dut->eval();

  long micro = 0, timeouts = 0;
  int to_last = 0;
  long first_memreq = -1, micro_at_first = -1;
  for (long t = 0; t < TICKS; ++t) {
    dut->rst = (t < 8);
    dut->clk = 1; dut->eval();
    if (dut->clock_edge) ++micro;
    // Rising edges, not the level. `timed_out` stands only for a sliver at
    // the end of each timeout, which is why the LED counts edges too.
    if (dut->timed_out && !to_last) ++timeouts;
    to_last = dut->timed_out;
    if (dut->mem_req && first_memreq < 0) { first_memreq = t; micro_at_first = micro; }
    dut->clk = 0; dut->eval();
  }
  double ns = TICKS * 5.0;
  printf("ticks              %ld  (%.3f ms of machine time)\n", TICKS, ns / 1e6);
  printf("microcycles        %ld\n", micro);
  printf("first mem_req at   tick %ld, microcycle %ld\n", first_memreq, micro_at_first);
  printf("NXM timeouts       %ld\n", timeouts);
  if (micro_at_first > 0 && micro > micro_at_first) {
    double after = micro - micro_at_first;
    double ns_after = (TICKS - first_memreq) * 5.0;
    printf("after the first memory cycle: %.0f microcycles in %.3f ms\n", after, ns_after/1e6);
    printf("  = %.2f us per microcycle (normal is 0.22)\n", ns_after / after / 1000.0);
    printf("  beat[19] toggles every 524288 microcycles = %.2f s\n",
           524288.0 * (ns_after / after) / 1e9);
  }
  dut->final(); delete dut; return 0;
}
