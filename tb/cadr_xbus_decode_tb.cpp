// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Checks rtl/cadr_xbus_decode.sv against muir's busint::decode at every one of
// the 4,194,304 addresses the Xbus can carry, for each board count in the
// reference. Not sampled: 22 bits is small enough to walk.
//
// The reference is written as runs of equal answer --- there are only eight
// per board count --- which are expanded here. That keeps the file readable
// against the constants it came from while the check stays exhaustive.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vcadr_xbus_decode.h"
#include "verilated.h"

namespace {

struct Run {
  long boards, first, last;
  std::string kind;
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/xbus_decode.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  std::vector<Run> runs;
  char line[256], kind[32];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    Run r;
    if (std::sscanf(line, "%ld %ld %ld %31s", &r.boards, &r.first, &r.last,
                    kind) != 4) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }
    r.kind = kind;
    runs.push_back(r);
  }
  std::fclose(f);

  if (runs.empty()) {
    std::fprintf(stderr, "FAIL: the reference is empty\n");
    return 1;
  }

  auto *dut = new Vcadr_xbus_decode;

  long checked = 0;
  int bad = 0;
  long n_memory = 0, n_device = 0, n_nxm = 0, n_unibus = 0;
  long board_counts = 0;
  long last_boards = -1;

  for (const Run &r : runs) {
    if (r.boards != last_boards) {
      ++board_counts;
      last_boards = r.boards;
    }
    const int want_memory = r.kind == "memory";
    const int want_device = r.kind == "device";
    const int want_nxm = r.kind == "nxm";
    const int want_unibus = r.kind == "unibus";
    if (!(want_memory || want_device || want_nxm || want_unibus)) {
      std::fprintf(stderr, "%s: unknown kind `%s`\n", path, r.kind.c_str());
      return 2;
    }

    dut->boards = static_cast<unsigned>(r.boards);
    for (long phys = r.first; phys <= r.last; ++phys) {
      dut->phys = static_cast<unsigned>(phys);
      dut->eval();

      if (dut->memory != want_memory || dut->device != want_device ||
          dut->nxm != want_nxm || dut->unibus != want_unibus) {
        std::fprintf(
            stderr,
            "boards=%ld phys=%ld (0%lo): memory=%d device=%d nxm=%d unibus=%d,"
            " reference says %s\n",
            r.boards, phys, phys, dut->memory, dut->device, dut->nxm,
            dut->unibus, r.kind.c_str());
        if (++bad >= 20) {
          std::fprintf(stderr, "stopping after %d mismatches\n", bad);
          goto done;
        }
      }

      // Exactly one answer, always. Nothing in the reference can catch a
      // decode that says an address is both memory and a device, because the
      // reference only ever names one.
      if (dut->memory + dut->device + dut->nxm + dut->unibus != 1) {
        std::fprintf(stderr,
                     "boards=%ld phys=%ld (0%lo): %d answers, want exactly 1\n",
                     r.boards, phys, phys,
                     dut->memory + dut->device + dut->nxm + dut->unibus);
        if (++bad >= 20) goto done;
      }

      n_memory += dut->memory;
      n_device += dut->device;
      n_nxm += dut->nxm;
      n_unibus += dut->unibus;
      ++checked;
    }
  }

done:
  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld addresses\n", bad,
                 checked);
    return 1;
  }

  // Coverage: every answer has to occur, or a decode that never says one of
  // them would pass.
  int thin = 0;
  const struct {
    const char *what;
    long n;
  } want[] = {{"memory", n_memory},
              {"device", n_device},
              {"nxm", n_nxm},
              {"unibus", n_unibus}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: no address decoded as %s\n", w.what);
      ++thin;
    }
  if (thin) return 1;

  std::printf(
      "ok: %ld addresses agree with muir's busint::decode\n"
      "    %ld board counts, every address of the 22-bit space in each\n",
      checked, board_counts);
  return 0;
}
