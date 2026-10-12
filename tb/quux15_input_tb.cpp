// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds rtl/machine/quux15_input.sv, revision 15's keyboard and mouse, to
// muir's `quux_input::QuuxInput` over the script `golden/src/quux_input.rs`
// writes, which `tb/quux_input_tb.cpp` holds revision 13's to: key words
// pressed on the cable, the mouse's counts and buttons, reads and writes of
// words 120-123, and the boot word.
//
// Each operation is one clock, the inputs idle after it.  A press is the
// cable's word in that clock.  A read is granted in that clock and its word
// is out the clock after.  A write is taken in that clock.  The interrupt
// status's two bits are compared after each operation, the inputs idle.
//
// **THE MOUSE IS DRIVEN ON ITS SEVEN LINES, AS `cadr_input_cables.sv`
// DRIVES THEM**: the script gives the counts a move leaves, and this
// testbench walks each count's phase there a step a clock, the shorter way
// round the twelve bits, in `Encoders::levels`' Gray order, and the buttons
// low on the switches' lines.  A boot word must raise `boot` for the one
// clock after its press, and no other press may raise it.  Nothing here
// keeps a model of the FIFO.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vquux15_input.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/quux_input.quux.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  auto *dut = new Vquux15_input;
  auto idle = [&]() {
    dut->kbd_strobe = 0;
    dut->rd = 0;
    dut->wr = 0;
    // Poison on the selects and the data lines when nothing reads or writes.
    dut->rd_k = 0121;
    dut->wr_k = 0120;
    dut->wdata = 0xdeadbeef;
  };
  // The mouse's phases, at rest at 2, and its switches.
  unsigned phase_x = 2, phase_y = 2, sw = 0;
  auto cable = [](unsigned p) -> unsigned { return ((p >> 1) & 1) | ((((p >> 1) ^ p) & 1) << 1); };
  auto lines = [&]() {
    dut->mouse_lines = static_cast<uint8_t>(((~sw & 7) << 4) | (cable(phase_y) << 2) | cable(phase_x));
  };
  // Boot pulses seen since the last `t` line, and the clocks of the last.
  long boot_pulses = 0, boot_run = 0, boot_len = 0;
  auto tick = [&]() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    if (dut->boot) {
      if (boot_run == 0) ++boot_pulses;
      ++boot_run;
    } else if (boot_run) {
      boot_len = boot_run;
      boot_run = 0;
    }
  };
  idle();
  lines();
  dut->rst = 1;
  tick();
  tick();
  dut->rst = 0;
  tick();
  char line[256];
  long rows = 0, bad = 0, reads = 0, presses = 0, moves = 0, steps = 0, boots = 0;
  long irq_up = 0, reads_nonzero = 0;
  unsigned cx = 0, cy = 0;
  auto fail = [&](const char *what, uint64_t got, uint64_t want) {
    if (bad < 20)
      std::fprintf(stderr, "row %ld: %s is %" PRIx64 ", muir has %" PRIx64 "\n", rows, what,
                   got, want);
    ++bad;
  };
  // A count walked to `to` a step a clock, the shorter way round.
  auto walk = [&](unsigned &count, unsigned to, unsigned &phase) {
    while (count != to) {
      const unsigned up = (to - count) & 0xfff;
      const bool forward = up <= 0x800;
      count = (count + (forward ? 1 : 0xfff)) & 0xfff;
      phase = (phase + (forward ? 1 : 3)) & 3;
      lines();
      tick();
      ++steps;
    }
  };
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    ++rows;
    unsigned a = 0, b = 0, irq = 0;
    idle();
    if (std::sscanf(line, "p %x %x", &a, &irq) == 2) {
      dut->kbd_strobe = 1;
      dut->kbd_code = a & 0xffffff;
      ++presses;
      tick();
    } else if (std::sscanf(line, "m %x %x %x", &a, &b, &irq) == 3) {
      walk(cx, a, phase_x);
      walk(cy, b, phase_y);
      ++moves;
    } else if (std::sscanf(line, "b %x %x", &a, &irq) == 2) {
      sw = a & 7;
      lines();
      tick();
    } else if (std::sscanf(line, "r %x %x %x", &a, &b, &irq) == 3) {
      dut->rd = 1;
      dut->rd_k = a;
      tick();
      idle();
      dut->eval();
      if (dut->rd_word != b) fail("a read", dut->rd_word, b);
      if (b) ++reads_nonzero;
      ++reads;
    } else if (std::sscanf(line, "w %x %x %x", &a, &b, &irq) == 3) {
      dut->wr = 1;
      dut->wr_k = a;
      dut->wdata = b;
      tick();
    } else if (std::sscanf(line, "t %x", &a) == 1) {
      idle();
      tick();
      tick();
      if ((boot_pulses != 0) != (a != 0)) fail("a boot since the last", boot_pulses, a);
      if (boot_pulses > 1) fail("the boot's requests since the last", boot_pulses, 1);
      if (boot_pulses) {
        ++boots;
        if (boot_len != 1) fail("the boot's request's clocks", boot_len, 1);
      }
      boot_pulses = 0;
      continue;
    } else {
      std::fprintf(stderr, "%s: cannot read row %ld: %s", path, rows, line);
      return 2;
    }
    idle();
    dut->eval();
    if (dut->irq != irq) fail("the interrupt status's two bits", dut->irq, irq);
    if (dut->irq_state != irq) fail("the interrupt status as the clock began", dut->irq_state, irq);
    if (dut->irq) ++irq_up;
  }
  std::fclose(f);
  if (!bad && (presses == 0 || moves == 0 || boots == 0 || reads_nonzero == 0 || irq_up == 0)) {
    std::fprintf(stderr, "FAIL: the script reached too little: %ld presses, %ld moves, %ld boots, "
                 "%ld nonzero reads, %ld rows with an interrupt\n",
                 presses, moves, boots, reads_nonzero, irq_up);
    return 1;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %ld mismatches over %ld rows\n", bad, rows);
    return 1;
  }
  std::printf("ok: %ld operations agree with muir's quux_input::QuuxInput on revision 15's keyboard and "
              "mouse: %ld presses, %ld reads (%ld nonzero), %ld moves in %ld steps of the mouse's lines, "
              "%ld boots, %ld rows interrupting\n",
              rows, presses, reads, reads_nonzero, moves, steps, boots, irq_up);
  delete dut;
  return 0;
}
