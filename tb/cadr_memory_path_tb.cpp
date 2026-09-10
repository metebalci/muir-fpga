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
// THE BUS RULE, against the property alone, and it is the half muir has no
// column for: **an unanswered read gives MD zero.** A slave drives MEM<31:0>
// only while it is selected and answering, so a cycle nothing answered leaves
// the lines undriven and -LOADMD --- which the interface asserts on the NXM
// timer's acknowledgement too --- strobes MD with zero. The trace already runs
// 29 cycles that nothing answers, 20 of them reads, and every one has a memory
// read before it that put a word in the bridge's `rdata` --- a write does not,
// the latch being guarded on `!dev_write`. So the sequence the rule is about
// was here all along; what was missing was anything looking at `rdata` when it
// arrived.
//
// THAT ASSERTION IS HERE BECAUSE IT WAS SOMEWHERE ELSE AND WENT QUIET.
// `build/ddr_boot.pass` held it from `05d28fa`: the boot PROM's 16,951 disk
// polls went unanswered, read the bridge's stale word, and bit 0 of it steered
// the program, so configuration B caught a bridge that held its word. At
// `70169fb` `rtl/cadr_disk_controller.sv`'s registers began answering those
// polls and the only unanswered cycles left on that program are two to empty
// Xbus space whose data the PROM ignores --- so the mutation stopped being
// caught while every check stayed green. A property held by which program
// happens to run is held by nothing. This check drives the rule from the
// stimulus instead, and fails if the stimulus stops carrying it.
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

#include <cstdint>
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

// What the modelled DDR holds at a byte address the stimulus has not written.
//
// INJECTIVE IN THE ADDRESS, and it was one constant. Every read of an address
// the trace never wrote used to be answered with 0xDEADBEEF and then counted
// rather than compared --- 20 of the run's 77 answered reads, so the integrity
// half stood on 57 of them. A constant cannot tell a read that went to the
// wrong untouched address from one that did not, and an uncompared word cannot
// tell anything at all. This is the same poison shape `tb/cadr_ddr_boot_tb.cpp`
// puts on page 0 and for the same reason.
uint32_t Untouched(unsigned byte_addr) {
  return (0x9E3779B9u * ((byte_addr >> 2) + 1u)) ^ 0xA5A5A5A5u;
}

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
  // The Xbus seam and the diagnostic register block, held quiet and said so.
  // Main memory is the one slave this check has; a device cycle reaches nobody,
  // which is what makes the trace's `present 0` cycles time out. These were
  // left to Verilator's zero-initialisation before, which is the same value and
  // not the same claim.
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->spy_rdata = 0;
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
  // Answered reads whose expected word has a bit set. A check that only ever
  // compared against zero would pass a bridge stuck at zero, which is exactly
  // what the rule below asks about --- so the two halves are counted apart.
  long reads_nonzero = 0;
  // Cycles nothing answered, where the word on MEM<31:0> must be zero.
  long unanswered_reads = 0, unanswered_writes = 0;
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
      dut->mem_rdata =
          (it == ddr.end()) ? Untouched(dut->mem_addr) : it->second;
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
      // The expected word comes from the stimulus in both cases: from what the
      // trace wrote where it wrote, and from the model's poison at the address
      // the trace ASKED for where it did not. A read that went somewhere else
      // is answered with that other address's poison and says so.
      const unsigned want =
          (it == shadow.end()) ? Untouched(0x1800'0000u + (r.phys << 2))
                               : it->second;
      if (it == shadow.end()) ++reads_untouched;
      if (dut->rdata != want) {
        bad += Fail(r, "MD", dut->rdata, want);
      } else {
        ++reads_checked;
        if (want != 0) ++reads_nonzero;
      }
    }

    // THE BUS RULE: nothing answered this cycle, so nothing drove MEM<31:0>
    // and what -LOADMD strobes into MD is zero. The interface acknowledges a
    // timed-out cycle on its own timer and asserts -LOADMD with it, so this is
    // the same instant the integrity check above samples at --- the difference
    // is that no slave was selected, and the bridge's `rdata` register, which
    // stands in for its driver onto the bus, must have let the word go.
    //
    // Held for a write as well as a read. The rule is about the data lines and
    // not about the direction: the processor's own RDCYC gate is what keeps a
    // write from strobing MD, and it is checked in `machine`, not here.
    if (!r.n_memack && memack_last && r.timed_out) {
      (r.wrcyc ? unanswered_writes : unanswered_reads)++;
      if (dut->rdata != 0)
        bad += Fail(r, "MEM<31:0> on a cycle nothing answered", dut->rdata, 0);
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
              {"answered reads whose word was compared", reads_checked},
              {"answered reads whose word has a bit set", reads_nonzero},
              {"reads that nothing answered", unanswered_reads}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the run has no %s\n", w.what);
      ++thin;
    }
  if (thin)
    std::fprintf(stderr,
                 "  counts: grants=%ld timeouts=%ld writes=%ld reads_ok=%ld "
                 "reads_untouched=%ld nonzero=%ld unanswered=%ld/%ld "
                 "ddr_words=%zu\n",
                 grants, timeouts, writes_seen, reads_checked, reads_untouched,
                 reads_nonzero, unanswered_reads, unanswered_writes,
                 ddr.size());
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks agree with muir's busint::Busint through the whole path\n"
      "    %ld cycles, %ld timed out; %ld words written to DDR, %ld reads "
      "gave back the word the stimulus put there (%ld of them the model's "
      "poison at an address never written, %ld with a bit set)\n"
      "    %ld reads and %ld writes that nothing answered gave MD zero, the "
      "bridge having let its word go when its cycle ended\n",
      checked, grants, timeouts, writes_seen, reads_checked, reads_untouched,
      reads_nonzero, unanswered_reads, unanswered_writes);
  return 0;
}
