// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/machine/cadr_phase_gen.sv from the reference trace and compares every
// tick.  The trace is written by golden/src/phase_gen.rs out of muir's own
// clock::Behavioural, and carries the stimulus as well as the expected
// outputs, so there is one definition of both.
//
// One tick is one posedge: the inputs for tick k are presented, the edge is
// taken, and the outputs are then the DUT's answer for tick k.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "Vcadr_phase_gen.h"
#include "verilated.h"

namespace {

struct Row {
  long tick;
  int rst, hang, ilong, speed;
  int tpclk, n_tpclk, tptse, n_tpwp, n_tpwpiram, n_tpr60;
};

const char *kSpeedName[4] = {"extra-slow", "slow", "normal", "fast"};

int Fail(const Row &r, const char *what, int got, int want) {
  std::fprintf(stderr,
               "tick %ld: %s is %d, reference says %d\n"
               "  inputs: rst=%d hang=%d ilong=%d speed=%s\n",
               r.tick, what, got, want, r.rst, r.hang, r.ilong,
               kSpeedName[r.speed & 3]);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/phase_gen.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  auto *dut = new Vcadr_phase_gen;
  dut->clk = 0;
  dut->rst = 1;
  dut->hang = 0;
  dut->ilong = 0;
  dut->speed = 0;
  // Verilator records the previous value of a clock at eval time, so the
  // first eval has to happen with clk low or the first posedge is not one.
  dut->eval();

  char line[256];
  long checked = 0;
  int bad = 0;

  // Coverage. A trace that agreed everywhere while exercising one tap would
  // pass and mean nothing, so the run also has to show every tap the 74S151
  // at CLOCK1 1D08 can select, and both ways the generator is held.
  // TPCLK rises at phase 0 and falls at the tap, so the ticks between are the
  // tap: 75, 85, 100, 115, 125, 140, 160 ns over five.
  const int kTaps[7] = {15, 17, 20, 23, 25, 28, 32};
  bool tap_seen[7] = {false};
  long rise_at = -1;
  int last_tpclk = 0;
  long hang_ticks = 0, reset_ticks = 0;

  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;

    Row r;
    int n = std::sscanf(line, "%ld %d %d %d %d %d %d %d %d %d %d", &r.tick,
                        &r.rst, &r.hang, &r.ilong, &r.speed, &r.tpclk,
                        &r.n_tpclk, &r.tptse, &r.n_tpwp, &r.n_tpwpiram,
                        &r.n_tpr60);
    if (n != 11) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }

    // Present tick k's inputs, then take the edge that makes them tick k's.
    dut->rst = r.rst;
    dut->hang = r.hang;
    dut->ilong = r.ilong;
    dut->speed = r.speed;

    dut->clk = 1;
    dut->eval();

    if (dut->tpclk != r.tpclk) bad += Fail(r, "TPCLK", dut->tpclk, r.tpclk);
    if (dut->n_tpclk != r.n_tpclk)
      bad += Fail(r, "-TPCLK", dut->n_tpclk, r.n_tpclk);
    if (dut->tptse != r.tptse) bad += Fail(r, "TPTSE", dut->tptse, r.tptse);
    if (dut->n_tpwp != r.n_tpwp)
      bad += Fail(r, "-TPWP", dut->n_tpwp, r.n_tpwp);
    if (dut->n_tpwpiram != r.n_tpwpiram)
      bad += Fail(r, "-TPWPIRAM", dut->n_tpwpiram, r.n_tpwpiram);
    // -TPR60 is not compared while RESET is held, and the reference is the
    // one at fault. `clock.rs` says "RESET holds the ring cleared: no
    // transition until it lifts", and `next_at` duly answers None --- but
    // `chip.rs`'s `apply_clock` still derives -TPR60 from `phase_ns`, which
    // is `time - cycle_start` with `cycle_start` left wherever the last
    // cycle put it. Time runs while reset is held, so phase_ns sweeps
    // through 60..100 and the reference emits a read tap off a ring it has
    // just said is cleared. A cleared ring produces no tap, so the DUT holds
    // -TPR60 deasserted throughout. See README, "Where this differs".
    if (!r.rst && dut->n_tpr60 != r.n_tpr60)
      bad += Fail(r, "-TPR60", dut->n_tpr60, r.n_tpr60);

    dut->clk = 0;
    dut->eval();

    if (r.rst) {
      ++reset_ticks;
      rise_at = -1;
    } else {
      if (r.hang) ++hang_ticks;
      if (r.tpclk && !last_tpclk) rise_at = r.tick;
      if (!r.tpclk && last_tpclk && rise_at >= 0) {
        long tap = r.tick - rise_at;
        for (int i = 0; i < 7; ++i)
          if (kTaps[i] == tap) tap_seen[i] = true;
        rise_at = -1;
      }
    }
    last_tpclk = r.tpclk;

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
  for (int i = 0; i < 7; ++i)
    if (!tap_seen[i]) {
      std::fprintf(stderr, "FAIL: the %d ns tap was never selected\n",
                   kTaps[i] * 5);
      ++thin;
    }
  if (hang_ticks == 0) {
    std::fprintf(stderr, "FAIL: -HANG was never asserted\n");
    ++thin;
  }
  if (reset_ticks == 0) {
    std::fprintf(stderr, "FAIL: RESET was never asserted\n");
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks agree with muir's clock::Behavioural\n"
      "    all 7 taps selected, %ld ticks held by -HANG, %ld by RESET\n",
      checked, hang_ticks, reset_ticks);
  return 0;
}
