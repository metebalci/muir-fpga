// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds rtl/machine/quux_input.sv to muir's `quux_input::QuuxInput` over the
// script `golden/src/quux_input.rs` writes: key words pressed on the cable,
// the mouse's counts and buttons as the I/O board would hand them over, reads
// and writes of words 120-123, and the boot word.  Each operation is one
// tick; a read's word is compared as it stands before the tick's edge, which
// is where the register page takes it, and the interrupt status's two bits
// after it, with the inputs idle.  A boot word must bring `-BOOT` down on
// the tick after its press and hold it for the board's 4 us, and no other
// press may bring it down.  Nothing here keeps a model of the FIFO.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vquux_input.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/quux_input.quux.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  auto *dut = new Vquux_input;
  auto idle = [&]() {
    dut->kbd_strobe = 0;
    dut->rd = 0;
    dut->wr = 0;
    dut->which = 0;
    // Poison on the data lines when nothing writes.
    dut->wdata = 0xdeadbeef;
  };
  // A boot pulse seen since the last `t` line, and how long the last one was.
  bool booted = false;
  long boot_ticks = 0, boot_run = 0;
  auto tick = [&]() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    if (!dut->n_boot) {
      if (boot_run == 0) booted = true;
      ++boot_run;
    } else if (boot_run) {
      boot_ticks = boot_run;
      boot_run = 0;
    }
  };
  idle();
  dut->mouse_x = 0;
  dut->mouse_y = 0;
  dut->mouse_buttons = 0;
  dut->rst = 1;
  tick();
  tick();
  dut->rst = 0;
  tick();
  char line[256];
  long rows = 0, bad = 0, reads = 0, presses = 0, moves = 0, boots = 0;
  long irq_up = 0, reads_nonzero = 0;
  auto fail = [&](const char *what, uint64_t got, uint64_t want) {
    if (bad < 20)
      std::fprintf(stderr, "row %ld: %s is %" PRIx64 ", muir has %" PRIx64 "\n", rows, what,
                   got, want);
    ++bad;
  };
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    ++rows;
    unsigned a = 0, b = 0, c = 0, irq = 0;
    idle();
    if (std::sscanf(line, "p %x %x", &a, &irq) == 2) {
      dut->kbd_strobe = 1;
      dut->kbd_code = a;
      ++presses;
      tick();
    } else if (std::sscanf(line, "m %x %x %x", &a, &b, &irq) == 3) {
      dut->mouse_x = a;
      dut->mouse_y = b;
      ++moves;
      tick();
    } else if (std::sscanf(line, "b %x %x", &a, &irq) == 2) {
      dut->mouse_buttons = a;
      tick();
    } else if (std::sscanf(line, "r %x %x %x", &a, &b, &irq) == 3) {
      dut->rd = 1;
      dut->which = a;
      dut->eval();
      if (!dut->mine) fail("the word's own select", 0, 1);
      if (dut->rdata != b) fail("a read", dut->rdata, b);
      if (b) ++reads_nonzero;
      ++reads;
      tick();
    } else if (std::sscanf(line, "w %x %x %x", &a, &b, &irq) == 3) {
      dut->wr = 1;
      dut->which = a;
      dut->wdata = b;
      tick();
    } else if (std::sscanf(line, "t %x", &a) == 1) {
      // Let a pulse run out before judging it.
      idle();
      for (int k = 0; k < 450; ++k) tick();
      if (booted != (a != 0)) fail("a boot since the last", booted, a);
      if (booted) {
        ++boots;
        if (boot_ticks != 400) fail("the boot pulse's ticks", boot_ticks, 400);
      }
      booted = false;
      continue;
    } else {
      std::fprintf(stderr, "%s: cannot read row %ld: %s", path, rows, line);
      return 2;
    }
    idle();
    dut->eval();
    if (dut->irq != irq) fail("the interrupt status's two bits", dut->irq, irq);
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
  std::printf("ok: %ld operations agree with muir's quux_input::QuuxInput: %ld presses, "
              "%ld reads (%ld nonzero), %ld moves, %ld boots, %ld rows interrupting\n",
              rows, presses, reads, reads_nonzero, moves, boots, irq_up);
  delete dut;
  return 0;
}
