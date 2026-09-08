// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/cadr_busint_xbus.sv from the reference trace and compares every
// tick. The trace is written by golden/src/busint_xbus.rs out of muir's own
// busint::Busint, and carries the stimulus as well as the expected outputs.
//
// The Xbus slave lives here rather than in the DUT: the trace's `device_ns`
// column says how long it takes, and this counts the ticks from -XBUS.RQ and
// answers. That is what the DUT is being checked against --- a bus interface
// that runs a cycle for whatever is on the bus.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vcadr_busint_xbus.h"
#include "verilated.h"

namespace {

struct Row {
  long tick;
  int n_memrq, wrcyc, device_ns, mclk;
  int n_memgrant, n_memack, n_loadmd;
};

int Fail(const Row &r, const char *what, int got, int want) {
  std::fprintf(stderr,
               "tick %ld: %s is %d, reference says %d\n"
               "  inputs: n_memrq=%d wrcyc=%d device_ns=%d mclk=%d\n",
               r.tick, what, got, want, r.n_memrq, r.wrcyc, r.device_ns,
               r.mclk);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/busint_xbus.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  auto *dut = new Vcadr_busint_xbus;
  dut->clk = 0;
  dut->rst = 1;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->dev_ack = 0;
  dut->eval();

  char line[256];
  long checked = 0;
  int bad = 0;

  // The slave: once -XBUS.RQ is out, answer device_ns later.
  int rq_last = 0;
  long rq_since = -1;

  // Coverage. A trace where nothing was ever granted would agree everywhere
  // and mean nothing, so the run has to show reads and writes, a slave that
  // answers at once and one that takes longer than a microcycle, and a
  // request that arrives on the master clock edge itself.
  long grants = 0, reads = 0, writes = 0, instant = 0, over_a_cycle = 0;
  long rq_on_edge = 0;
  int memgrant_last = 1;

  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;

    Row r;
    int n = std::sscanf(line, "%ld %d %d %d %d %d %d %d", &r.tick, &r.n_memrq,
                        &r.wrcyc, &r.device_ns, &r.mclk, &r.n_memgrant,
                        &r.n_memack, &r.n_loadmd);
    if (n != 8) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }

    dut->rst = (r.tick == 0);
    dut->mclk = r.mclk;
    dut->n_memrq = r.n_memrq;
    dut->wrcyc = r.wrcyc;

    dut->clk = 1;
    dut->eval();

    // The slave is combinational, as an Xbus slave is: it sees -XBUS.RQ and
    // answers device_ns later, in the same tick if device_ns is zero. So its
    // answer is worked out after the edge has settled dev_rq, and fed back in
    // with a second eval that moves no register.
    if (dut->dev_rq && !rq_last) rq_since = r.tick;
    if (!dut->dev_rq) rq_since = -1;
    rq_last = dut->dev_rq;

    dut->dev_ack =
        (rq_since >= 0) && ((r.tick - rq_since) * 5 >= r.device_ns);
    dut->eval();

    if (dut->n_memgrant != r.n_memgrant)
      bad += Fail(r, "-MEMGRANT", dut->n_memgrant, r.n_memgrant);
    if (dut->n_memack != r.n_memack)
      bad += Fail(r, "-MEMACK", dut->n_memack, r.n_memack);
    if (dut->n_loadmd != r.n_loadmd)
      bad += Fail(r, "-LOADMD", dut->n_loadmd, r.n_loadmd);

    dut->clk = 0;
    dut->eval();

    if (!r.n_memgrant && memgrant_last) {
      ++grants;
      if (r.wrcyc) ++writes; else ++reads;
      if (r.device_ns == 0) ++instant;
      if (r.device_ns > 145) ++over_a_cycle;
      if (r.mclk && !r.n_memrq) ++rq_on_edge;
    }
    memgrant_last = r.n_memgrant;

    ++checked;
    if (bad >= 20) {
      std::fprintf(stderr, "stopping after %d mismatches\n", bad);
      break;
    }
  }

  std::fclose(f);
  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, checked);
    return 1;
  }
  if (checked == 0) {
    std::fprintf(stderr, "FAIL: the trace was empty\n");
    return 1;
  }

  int thin = 0;
  const struct {
    const char *what;
    long n;
  } want[] = {{"grants", grants},
              {"reads", reads},
              {"writes", writes},
              {"cycles answered at once", instant},
              {"cycles slower than a microcycle", over_a_cycle},
              {"requests standing at the master clock edge", rq_on_edge}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the trace has no %s\n", w.what);
      ++thin;
    }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks agree with muir's busint::Busint\n"
      "    %ld cycles --- %ld reads, %ld writes, %ld answered at once, "
      "%ld slower than a microcycle\n",
      checked, grants, reads, writes, instant, over_a_cycle);
  return 0;
}
