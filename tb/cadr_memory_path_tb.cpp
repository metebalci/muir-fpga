// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The memory path end to end, checked two ways at once.
//
// TIMING, against muir: -MEMGRANT, -MEMACK, -LOADMD and NXM TIMEOUT have to
// agree with busint::Busint at every tick, as they did before the decode and
// the bridge were in the way. That the path grew does not make the cycle
// longer, and this is what says so.
//
// INTEGRITY, against the stimulus: a read returns the word an earlier write
// put at that address. There is no reference for this half --- nothing in MIT's
// drawings is a DDR controller --- so what it is held to is the property.
//
// The shadow is keyed by the trace's own `phys` and filled with the trace's own
// `wdata`, never by anything the DUT produced. That matters, and it was wrong
// once: keyed by the DUT's `mem_addr` and filled from its `mem_wdata`, the
// shadow moves with the bug, so a bridge that wrote the address instead of the
// data, or dropped an address bit, passed. Both are caught now, and both are in
// the mutation list.
//
// The DDR behind the bridge is modelled here, answering `device_ns` after the
// bridge asks, which is what makes the timing comparable: the trace's
// `device_ns` is the model's device answer time measured from -XBUS.RQ, and a
// thin bridge puts the request out on that same tick.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

#include "Vcadr_memory_path.h"
#include "verilated.h"

namespace {

struct Row {
  long tick;
  int n_memrq, wrcyc, device_ns, present;
  unsigned phys, wdata;
  int boards, mclk;
  int n_memgrant, n_memack, n_loadmd, timed_out;
};

int Fail(const Row &r, const char *what, long got, long want) {
  std::fprintf(stderr,
               "tick %ld: %s is %ld, reference says %ld\n"
               "  inputs: n_memrq=%d wrcyc=%d device_ns=%d present=%d "
               "phys=%u boards=%d\n",
               r.tick, what, got, want, r.n_memrq, r.wrcyc, r.device_ns,
               r.present, r.phys, r.boards);
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

  auto *dut = new Vcadr_memory_path;
  dut->clk = 0;
  dut->rst = 1;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->eval();

  // What DDR holds, keyed by byte address as real DDR is.
  std::map<unsigned, unsigned> ddr;
  // What *should* be at each CADR word address, from the stimulus alone.
  std::map<unsigned, unsigned> shadow;
  int req_last = 0;
  long req_since = -1;

  // Reads whose word an earlier write put there, and which have been checked.
  long reads_checked = 0, reads_untouched = 0, writes_seen = 0;
  int memack_last = 1;

  char line[256];
  long checked = 0;
  int bad = 0;
  long grants = 0, timeouts = 0;
  int memgrant_last = 1, timed_out_last = 0;

  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;

    Row r;
    if (std::sscanf(line, "%ld %d %d %d %d %u %u %d %d %d %d %d %d", &r.tick,
                    &r.n_memrq, &r.wrcyc, &r.device_ns, &r.present, &r.phys,
                    &r.wdata, &r.boards, &r.mclk, &r.n_memgrant, &r.n_memack,
                    &r.n_loadmd, &r.timed_out) != 13) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }

    dut->rst = (r.tick == 0);
    dut->mclk = r.mclk;
    dut->n_memrq = r.n_memrq;
    dut->wrcyc = r.wrcyc;
    dut->phys = r.phys;
    dut->wdata = r.wdata;
    dut->boards = static_cast<unsigned>(r.boards);

    dut->clk = 1;
    dut->eval();

    // DDR answers device_ns after the bridge asked. Worked out after the edge
    // has settled mem_req, and fed back with a second eval that moves no
    // register --- the same shape the Xbus slave had.
    if (dut->mem_req && !req_last) req_since = r.tick;
    if (!dut->mem_req) req_since = -1;
    req_last = dut->mem_req;

    const int done =
        (req_since >= 0) && ((r.tick - req_since) * 5 >= r.device_ns);
    dut->mem_done = done;
    if (done && !dut->mem_write) {
      auto it = ddr.find(dut->mem_addr);
      dut->mem_rdata = (it == ddr.end()) ? 0xDEADBEEFu : it->second;
    }
    dut->eval();

    if (dut->n_memgrant != r.n_memgrant)
      bad += Fail(r, "-MEMGRANT", dut->n_memgrant, r.n_memgrant);
    if (dut->n_memack != r.n_memack)
      bad += Fail(r, "-MEMACK", dut->n_memack, r.n_memack);
    if (dut->n_loadmd != r.n_loadmd)
      bad += Fail(r, "-LOADMD", dut->n_loadmd, r.n_loadmd);
    if (dut->timed_out != r.timed_out)
      bad += Fail(r, "NXM TIMEOUT", dut->timed_out, r.timed_out);

    // The word lands in DDR while the request stands. What the bridge puts on
    // the memory port is checked against the stimulus here and now, rather than
    // only showing up as a wrong word much later.
    if (done && dut->mem_write) {
      const unsigned want_addr = 0x1800'0000u + (r.phys << 2);
      if (dut->mem_addr != want_addr)
        bad += Fail(r, "the byte address on the memory port", dut->mem_addr,
                    want_addr);
      if (dut->mem_wdata != r.wdata)
        bad += Fail(r, "the word on the memory port", dut->mem_wdata, r.wdata);
      ddr[dut->mem_addr] = dut->mem_wdata;
      shadow[r.phys] = r.wdata;
      ++writes_seen;
    }

    // Integrity: at -MEMACK on a read that was answered rather than timed out,
    // the word the cpu is given has to be the one that was written there.
    if (!r.n_memack && memack_last && !r.timed_out && !r.wrcyc && r.present) {
      auto it = shadow.find(r.phys);
      if (it == shadow.end()) {
        ++reads_untouched;
      } else if (dut->rdata != it->second) {
        bad += Fail(r, "MD", dut->rdata, it->second);
      } else {
        ++reads_checked;
      }
    }
    memack_last = r.n_memack;

    dut->clk = 0;
    dut->eval();

    if (!r.n_memgrant && memgrant_last) ++grants;
    memgrant_last = r.n_memgrant;
    if (r.timed_out && !timed_out_last) ++timeouts;
    timed_out_last = r.timed_out;

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
  const struct {
    const char *what;
    long n;
  } want[] = {{"grants", grants},
              {"cycles that timed out", timeouts},
              {"writes that reached DDR", writes_seen},
              {"reads checked against an earlier write", reads_checked}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the run has no %s\n", w.what);
      ++thin;
    }
  if (thin)
    std::fprintf(stderr,
                 "  counts: grants=%ld timeouts=%ld writes=%ld reads_ok=%ld "
                 "reads_untouched=%ld ddr_words=%zu\n",
                 grants, timeouts, writes_seen, reads_checked, reads_untouched,
                 ddr.size());
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks agree with muir's busint::Busint through the whole path\n"
      "    %ld cycles, %ld timed out; %ld words written to DDR, %ld reads "
      "matched what was written (%ld read untouched words)\n",
      checked, grants, timeouts, writes_seen, reads_checked, reads_untouched);
  return 0;
}
