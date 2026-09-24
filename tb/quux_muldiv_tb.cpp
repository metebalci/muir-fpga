// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds rtl/machine/quux_muldiv.sv to muir's `muldiv::run`, row for row, over
// the operands `golden/src/muldiv.rs` writes: every combination of ten edge
// values and twenty thousand random triples.  The multiply is combinational
// and the divide two steps a tick, so each row is driven, loaded as the
// processor loads it, its operands poisoned, stepped 16 ticks and compared
// --- and compared again 32 ticks further on, where the words must not have
// moved.  Nothing here
// computes a product or a quotient of its own.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vquux_muldiv.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/muldiv.quux.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  auto *dut = new Vquux_muldiv;
  auto tick = [&]() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
  };
  dut->rst = 1;
  dut->load = 0;
  tick();
  tick();
  dut->rst = 0;
  char line[256];
  long rows = 0, bad = 0;
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    unsigned m, a, q, mo, mq, dob, dq;
    if (std::sscanf(line, "%x %x %x %x %x %x %x", &m, &a, &q, &mo, &mq, &dob, &dq) != 7) {
      std::fprintf(stderr, "%s: row %ld is not seven words\n", path, rows);
      return 2;
    }
    dut->m = m;
    dut->a = a;
    dut->q = q;
    dut->load = 1;
    tick();
    dut->load = 0;
    // The operands are poisoned after the load, as the M bus would move
    // under a divider that went on reading it.
    dut->m = ~m;
    dut->a = ~a;
    dut->q = ~q;
    // Two steps a tick: the words are there sixteen ticks after the load.
    for (int k = 0; k < 16; k++) tick();
    const unsigned div_ob = dut->div_ob, div_q = dut->div_q;
    for (int k = 0; k < 32; k++) tick();
    if (dut->div_ob != div_ob || dut->div_q != div_q) {
      if (++bad <= 20)
        std::fprintf(stderr, "m %08x a %08x q %08x: the divider moved after its 32 steps\n",
                     m, a, q);
    }
    dut->m = m;
    dut->a = a;
    dut->q = q;
    dut->eval();
    const unsigned got[4] = {dut->mul_ob, dut->mul_q, div_ob, div_q};
    const unsigned want[4] = {mo, mq, dob, dq};
    static const char *what[4] = {"MUL's output bus", "MUL's Q", "DIV's output bus", "DIV's Q"};
    for (int i = 0; i < 4; i++) {
      if (got[i] != want[i]) {
        if (++bad <= 20)
          std::fprintf(stderr, "m %08x a %08x q %08x: %s is %08x, muir says %08x\n",
                       m, a, q, what[i], got[i], want[i]);
      }
    }
    ++rows;
  }
  std::fclose(f);
  dut->final();
  delete dut;
  if (rows < 1000) {
    std::fprintf(stderr, "FAIL: %s carries %ld rows\n", path, rows);
    return 1;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %ld mismatches over %ld operand triples\n", bad, rows);
    return 1;
  }
  std::printf("ok: %ld operand triples of MUL and DIV agree with muir's muldiv::run\n", rows);
  return 0;
}
