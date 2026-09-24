// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's clock generator, `rtl/machine/quux_phase_gen.sv`, held
// tick by tick to `golden/src/phase_gen.rs --machine quux`: muir's
// `TimingModel::Sync`, a microcycle of SYNC_K ticks and SYNC_K + SYNC_L for an
// `ILONG` instruction, with nothing inside it.
//
// The trace carries the stimulus and the expected outputs, as the CADR's
// does, so the two cannot drift apart.  Compared: TPCLK, a tick at each
// boundary; the write pulse, low over each microcycle's last tick so that it
// ends on the boundary's edge; the control store's pulse, the boundary's
// tick; and TPTSE and -TPR60, which have no meaning on QUUX and must stand
// idle.  `penult` and `last` place the CADR's hung-cycle writes and must
// stay low.
//
// **AND THE RUN HAS TO HAVE REACHED WHAT IT HOLDS**: microcycles of both
// lengths when the two differ, reset twice, and -HANG up on some ticks, so
// that a trace which stopped exercising one of them fails rather than passes
// with nothing compared.

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vquux_phase_gen.h"
#include "verilated.h"

namespace {

struct Row {
  long tick;
  int rst, hang, ilong, speed;
  int tpclk, n_tpclk, tptse, n_tpwp, n_tpwpiram, n_tpr60;
};

int Fail(const Row &r, const char *what, int got, int want) {
  std::fprintf(stderr,
               "tick %ld: %s is %d, reference says %d\n"
               "  inputs: rst=%d hang=%d ilong=%d\n",
               r.tick, what, got, want, r.rst, r.hang, r.ilong);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/phase_gen.quux.k4l1.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  auto *dut = new Vquux_phase_gen;
  dut->clk = 0;
  dut->rst = 1;
  dut->hang = 0;
  dut->ilong = 0;
  dut->speed = 2;
  dut->eval();

  char line[256];
  long checked = 0, hang_ticks = 0, resets = 0;
  int bad = 0, last_rst = 0;
  long rise_at = -1;
  // The lengths seen, in ticks, between one rise and the next.
  long len_count[64] = {0};

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
    if (dut->n_tpwp != r.n_tpwp) bad += Fail(r, "-TPWP", dut->n_tpwp, r.n_tpwp);
    if (dut->n_tpwpiram != r.n_tpwpiram)
      bad += Fail(r, "-TPWPIRAM", dut->n_tpwpiram, r.n_tpwpiram);
    if (dut->n_tpr60 != r.n_tpr60)
      bad += Fail(r, "-TPR60", dut->n_tpr60, r.n_tpr60);
    if (dut->penult) bad += Fail(r, "penult", dut->penult, 0);
    if (dut->last) bad += Fail(r, "last", dut->last, 0);

    dut->clk = 0;
    dut->eval();

    if (r.rst) {
      if (!last_rst) ++resets;
      rise_at = -1;
    } else {
      if (r.hang) ++hang_ticks;
      if (r.tpclk) {
        if (rise_at >= 0 && r.tick - rise_at < 64) ++len_count[r.tick - rise_at];
        rise_at = r.tick;
      }
    }
    last_rst = r.rst;
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
  int thin = 0;
  if (checked == 0) {
    std::fprintf(stderr, "FAIL: the trace was empty\n");
    ++thin;
  }
  int lengths = 0;
  for (int i = 0; i < 64; ++i)
    if (len_count[i]) ++lengths;
  // Two lengths when ILONG adds ticks, and one when it does not.
  const int want_lengths = (SYNC_L_TB > 0) ? 2 : 1;
  if (lengths != want_lengths) {
    std::fprintf(stderr, "FAIL: %d microcycle lengths seen, wanting %d\n", lengths,
                 want_lengths);
    ++thin;
  }
  if (!len_count[SYNC_K_TB]) {
    std::fprintf(stderr, "FAIL: no microcycle of %d ticks\n", SYNC_K_TB);
    ++thin;
  }
  if (SYNC_L_TB > 0 && !len_count[SYNC_K_TB + SYNC_L_TB]) {
    std::fprintf(stderr, "FAIL: no microcycle of %d ticks\n", SYNC_K_TB + SYNC_L_TB);
    ++thin;
  }
  if (resets < 2) {
    std::fprintf(stderr, "FAIL: reset came up %ld times, wanting two\n", resets);
    ++thin;
  }
  if (!hang_ticks) {
    std::fprintf(stderr, "FAIL: -HANG was never up\n");
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks agree with muir's TimingModel::Sync at K=%d, L=%d\n"
      "    %ld microcycles of %d ticks and %ld of %d, reset twice, %ld ticks of -HANG ignored\n",
      checked, SYNC_K_TB, SYNC_L_TB, len_count[SYNC_K_TB], SYNC_K_TB,
      SYNC_L_TB > 0 ? len_count[SYNC_K_TB + SYNC_L_TB] : 0L, SYNC_K_TB + SYNC_L_TB,
      hang_ticks);
  return 0;
}
