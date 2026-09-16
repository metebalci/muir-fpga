// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds every free-running clock of the COMPOSED machine to muir's instants,
// with the origin taken from the processor and from nothing the clocks decide.
//
// WHAT THIS IS FOR.  Each oscillator has a check of its own --- the I/O board's
// against `iob.golden`, the display's against `tv.golden` --- and each of those
// checks sets muir's t = 0 from its own reset.  A clock that started at the
// wrong edge in the whole machine and at the edge its own check expected agrees
// with that check, which is how the bus interface's timeout oscillator ran two
// ticks ahead of muir for as long as it did (issue #21), and how the I/O board's
// clocks and the display's program from power-on did after it was fixed: every
// one of them 20 ns early at the 10 ns grid, measured, while every check was
// green.
//
// WHERE THE ORIGIN COMES FROM.  `build/power_on.golden` carries the instants
// the first microcycles of muir's `rtl` engine end at, dated as `rtl.golden`
// dates its rows, and `machine.pass` holds the composed machine's microcycles
// to exactly those.  So the tick `clock_edge` is high after, less muir's
// instant in ticks, is where muir's t = 0 falls on this run --- and it must be
// the same tick for every one of those microcycles, or the origin is not an
// origin and the check says so before it compares anything.
//
// WHAT IS COMPARED.  Every edge the trace lists, each at the tick the fabric
// acts on it: the term that says an edge is due, standing before the clock
// edge that takes it --- `usec_now`, `hu_now`, `fclk_now`, `kb_now`, the mains'
// registered wrap and `-TVMA CLR` --- and the display's two sync bits after the
// clock edge that latches them.  The instants are muir's `free_running` under
// `--timing-model fpga`, the first tick at or after each exact edge.
//
// THE PROBES ARE INTERNAL.  None of these clocks reaches a port of
// `cadr_machine`, so the model is built with `--public-flat-rw` and the names
// below are the RTL's.  A renamed signal fails to compile, which is the loud
// way round.  **Nothing here reads the power-on constant itself**, so a module
// that started its clocks at any other edge is caught by a disagreement with
// muir and not by agreement with a number written in two places.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "Vcadr_machine.h"
#include "Vcadr_machine___024root.h"
#include "cadr_tick.h"
#include "verilated.h"

namespace {

using Instants = std::vector<long>;

std::map<std::string, Instants> ReadGolden(const char *path) {
  std::map<std::string, Instants> out;
  FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "FAIL: cannot open %s\n", path);
    std::exit(1);
  }
  char line[4096];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    char *save = nullptr;
    char *name = strtok_r(line, " \n", &save);
    if (!name) continue;
    Instants v;
    for (char *tok = strtok_r(nullptr, " \n", &save); tok;
         tok = strtok_r(nullptr, " \n", &save)) {
      v.push_back(std::strtol(tok, nullptr, 10));
    }
    out[name] = v;
  }
  std::fclose(f);
  return out;
}

// One clock: the instants muir gives it and the ticks this run saw it at.
struct Clock {
  const char *what;
  Instants want_ns;
  std::vector<long> seen;
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/power_on.golden";
  auto g = ReadGolden(path);

  const char *keys[] = {"tick_ns", "microcycle_ends", "usec", "half_usec", "fclk",
                        "kb_clk",  "sixty_cycle",     "tvma_clr", "sync_changes"};
  for (const char *k : keys) {
    if (g.find(k) == g.end() || g[k].empty()) {
      std::fprintf(stderr, "FAIL: %s carries no `%s` line\n", path, k);
      return 1;
    }
  }
  if (g["tick_ns"][0] != kGridNs) {
    std::fprintf(stderr, "FAIL: %s was generated at a %ld ns grid and this is %ld\n",
                 path, g["tick_ns"][0], kGridNs);
    return 1;
  }

  Clock usec{"the microsecond clock", g["usec"], {}};
  Clock half{"the half-microsecond clock", g["half_usec"], {}};
  Clock fclk{"FCLK^", g["fclk"], {}};
  Clock kb{"KB CLK^", g["kb_clk"], {}};
  Clock mains{"the sixty-cycle clock", g["sixty_cycle"], {}};
  Clock clr{"the display's -TVMA CLR", g["tvma_clr"], {}};
  Clock sync{"the display's sync bits", g["sync_changes"], {}};
  Clock *clocks[] = {&usec, &half, &fclk, &kb, &mains, &clr, &sync};
  for (Clock *c : clocks) {
    for (size_t i = 1; i < c->want_ns.size(); ++i) {
      if (c->want_ns[i] <= c->want_ns[i - 1] || c->want_ns[i] % kGridNs != 0) {
        std::fprintf(stderr, "FAIL: %s: %s's instants are not rising ticks\n", path, c->what);
        return 1;
      }
    }
  }
  const Instants &ends = g["microcycle_ends"];
  long last_ns = 0;
  for (Clock *c : clocks) last_ns = std::max(last_ns, c->want_ns.back());

  auto *dut = new Vcadr_machine;
  auto *r = dut->rootp;
  // As `tb/cadr_machine_tb.cpp` drives it: the boot button up, 32 boards, and
  // nothing answering a memory or device cycle, which the boot PROM does not
  // reach in the few microseconds that decide the origin.
  dut->n_boot2 = 1;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->eval();

  // Any reset of a few edges; the check does not depend on its length.
  constexpr long kResetEdges = 4;
  std::vector<long> edges_at;
  int sync_before = -1;
  const long kMaxTicks = last_ns / kGridNs + kResetEdges + 1024;

  for (long t = 0; t < kMaxTicks; ++t) {
    dut->rst = (t < kResetEdges);

    // The terms that say an edge is due, before the clock edge that takes it.
    const bool usec_due = r->cadr_machine__DOT__memory__DOT__iob__DOT__usec_now;
    const bool half_due = r->cadr_machine__DOT__memory__DOT__iob__DOT__hu_now;
    const bool fclk_due = r->cadr_machine__DOT__memory__DOT__iob__DOT__fclk_now;
    const bool kb_due = r->cadr_machine__DOT__memory__DOT__iob__DOT__kb_now;
    const bool mains_due = r->cadr_machine__DOT__memory__DOT__iob__DOT__mains_wrap;
    const bool clr_due = r->cadr_machine__DOT__memory__DOT__tv__DOT__tvma_clr;

    dut->clk = 1;
    dut->eval();

    if (!dut->rst) {
      if (usec_due) usec.seen.push_back(t);
      if (half_due) half.seen.push_back(t);
      if (fclk_due) fclk.seen.push_back(t);
      if (kb_due) kb.seen.push_back(t);
      if (mains_due) mains.seen.push_back(t);
      if (clr_due) clr.seen.push_back(t);
      if (dut->clock_edge) edges_at.push_back(t);
      const int bits = (r->cadr_machine__DOT__memory__DOT__tv__DOT__sync_v << 1) |
                       r->cadr_machine__DOT__memory__DOT__tv__DOT__sync_h;
      if (sync_before >= 0 && bits != sync_before) sync.seen.push_back(t);
      sync_before = bits;
    }

    dut->clk = 0;
    dut->eval();
  }

  // The origin, from the processor alone.
  if (edges_at.size() < ends.size()) {
    std::fprintf(stderr, "FAIL: the machine ended %zu microcycles, wanting at least %zu\n",
                 edges_at.size(), ends.size());
    return 1;
  }
  if (ends[0] % kGridNs != 0) {
    std::fprintf(stderr, "FAIL: muir's first microcycle ends off the grid, at %ld ns\n", ends[0]);
    return 1;
  }
  const long zero = edges_at[0] - ends[0] / kGridNs;
  for (size_t k = 0; k < ends.size(); ++k) {
    const long z = edges_at[k] - ends[k] / kGridNs;
    if (z != zero) {
      std::fprintf(stderr,
                   "FAIL: microcycle %zu ends at tick %ld, which puts muir's t = 0 at %ld "
                   "where the first put it at %ld: the processor itself does not agree with "
                   "muir, and there is no origin to compare the clocks from\n",
                   k, edges_at[k], z, zero);
      return 1;
    }
  }
  if (zero < kResetEdges) {
    std::fprintf(stderr, "FAIL: muir's t = 0 falls at tick %ld, inside the reset\n", zero);
    return 1;
  }

  int bad = 0;
  long compared = 0;
  for (Clock *c : clocks) {
    if (c->seen.size() < c->want_ns.size()) {
      std::fprintf(stderr, "FAIL: %s made %zu edges in %ld ticks, wanting %zu\n", c->what,
                   c->seen.size(), kMaxTicks, c->want_ns.size());
      ++bad;
      continue;
    }
    for (size_t i = 0; i < c->want_ns.size(); ++i) {
      const long got_ns = (c->seen[i] - zero) * kGridNs;
      ++compared;
      if (got_ns != c->want_ns[i]) {
        std::fprintf(stderr,
                     "FAIL: %s, edge %zu, is at %ld ns of muir's time, wanting %ld "
                     "(%+ld ns); muir's t = 0 is tick %ld, from the processor\n",
                     c->what, i + 1, got_ns, c->want_ns[i], got_ns - c->want_ns[i], zero);
        ++bad;
      }
    }
  }
  delete dut;
  if (bad) return 1;

  std::printf("power_on: muir's t = 0 is tick %ld of this run, from the processor's first %zu "
              "microcycles, %ld edges after the reset edge\n",
              zero, ends.size(), zero - (kResetEdges - 1));
  std::printf("power_on: %ld edges of the microsecond clock and its half, FCLK^, KB CLK^, the "
              "mains and the display's program from power-on, every one at muir's instant\n",
              compared);
  return 0;
}
