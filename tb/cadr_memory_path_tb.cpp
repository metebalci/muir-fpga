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
// AND THE ARBITER, in a configuration of its own. The disk controller's
// channel is the second master on this bus and `Controller::write` reaches
// `main` directly, so there is no muir reference for it at all --- it is
// `cadr_axi_master.sv`'s situation. What holds it is a property with a number
// in it: **the processor's NXM timer is 4,250 ns from the gated oscillator's
// first rise and a block is 256 words**, so the arbiter yields the bus after
// every word and the processor wins. Configuration B runs the same scripted
// processor cycles twice, once with the channel idle and once with it
// streaming a whole block, and requires that no cycle grew by more than ONE
// memory access. A block held to the end of the block is caught by the growth
// and not by the timeout, which is what makes the check bite where a
// timeout-only one would not: two words is 60 ns against 4,250.
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
// `70169fb` `rtl/machine/cadr_disk_controller.sv`'s registers began answering those
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
#include <vector>

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


// ---------------------------------------------------------------- the arbiter
//
// CONFIGURATION B: the same scripted processor cycles twice, once with the
// disk controller's channel idle and once with it streaming a block, and the
// question is by how much the second run's cycles grew.
//
// **THE NUMBER THIS HOLDS TO IS THE NXM TIMER'S.** 4,250 ns from the gated
// oscillator's first rise, and a block is 256 words: a channel that kept the
// bus for a block would turn a legitimate memory reference into an NXM. So
// the arbiter yields after every word, and a processor cycle waits for at
// most one memory access. That bound is what is asserted, and it is much
// tighter than "the cycle did not time out" --- two words held is 2 x 30 ns
// against 4,250, which a timeout could never see.
//
// The processor side is scripted rather than replayed, because the trace is
// indexed by tick and a cycle that waits for the bus no longer lands where its
// row does. Nothing here is compared against muir; what is compared is one run
// of this fabric against another run of the same fabric.
//
// The model memory is keyed by what the TESTBENCH asked for and never by what
// the DUT put on the port, which is CLAUDE.md's rule and the reason the
// integrity half of configuration A was once wrong.
namespace {

// The modelled DDR's latency, in ticks, and the microcycle the master clock
// is pulsed at.
constexpr int kMemLatency = 6;
constexpr int kMicrocycle = 29;
// A block, and where it goes: a page well away from the addresses the
// processor's own cycles use, so that a word landing in the wrong place is
// visible in both directions.
constexpr unsigned kBlockPage = 0x00040000u;
constexpr int kBlockWords = 256;

// A word of the block, injective in the offset: a channel that wrote the
// address, or dropped a bit of the offset, cannot write the right word.
uint32_t BlockWord(int i) {
  return 0xC0DE0000u ^ (0x9E3779B9u * (uint32_t)(i + 1));
}
// And a word for the processor's own cycles, from a different family.
uint32_t CpuWord(unsigned a) { return 0x5A5A0000u ^ (0x85EBCA6Bu * (a + 3u)); }

struct Arb {
  std::vector<long> cycle;      // grant to -MEMACK, in ticks, per processor cycle
  long timeouts = 0;
  long words = 0;               // channel words that completed
  long collisions = 0;          // processor cycles that overlapped a channel word
  bool ok = true;
};

// One run. `stream` says whether the channel is asking for the bus.
Arb RunOnce(bool stream, std::map<unsigned, unsigned> &ddr) {
  Arb out;
  auto *dut = new Vcadr_memory_path;
  long tick = 0;
  int memrq = 1, wrcyc = 0;
  unsigned phys = 0, wdata = 0;
  long req_since = -1;
  int req_last = 0;
  // The channel's own state: one word at a time, the request standing until
  // `ch_done`, exactly as `rtl/machine/cadr_disk_controller.sv` drives it.
  int word = 0;
  std::vector<int> landed(kBlockWords, 0);
  long words_this_cycle = 0;

  dut->clk = 0;
  dut->rst = 1;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->spy_rdata = 0;
  // -XBUS INIT never comes: the display's flag is the power-on reset's.
  dut->xbus_init = 0;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->ch_req = 0;
  dut->ch_write = 0;
  dut->ch_addr = 0;
  dut->ch_wdata = 0;
  dut->eval();

  auto step = [&]() {
    dut->rst = (tick < 4);
    // MCLK7, one edge a microcycle at the boundary.
    dut->mclk = (tick % kMicrocycle) == 0;
    dut->n_memrq = memrq;
    dut->wrcyc = wrcyc;
    dut->phys = phys;
    dut->wdata = wdata;
    // The channel asks for the next word until it is answered.
    if (stream && word < kBlockWords) {
      dut->ch_req = 1;
      dut->ch_write = 1;
      dut->ch_addr = kBlockPage + (unsigned)word;
      dut->ch_wdata = BlockWord(word);
    } else {
      dut->ch_req = 0;
    }
    dut->clk = 1;
    dut->eval();
    // DDR answers a fixed number of ticks after the bridge asked.
    if (dut->mem_req && !req_last) req_since = tick;
    if (!dut->mem_req) req_since = -1;
    req_last = dut->mem_req;
    const int done = (req_since >= 0) && (tick - req_since >= kMemLatency);
    dut->mem_done = done;
    if (done && !dut->mem_write) {
      auto it = ddr.find(dut->mem_addr);
      dut->mem_rdata = (it == ddr.end()) ? 0u : it->second;
    }
    dut->eval();
    if (done && dut->mem_write) {
      ddr[dut->mem_addr] = dut->mem_wdata;
      if (getenv("ARB_DEBUG"))
        std::fprintf(stderr, "  t=%ld ddr[%08x]=%08x\n", tick,
                     (unsigned)dut->mem_addr, (unsigned)dut->mem_wdata);
    }
    // The channel's word, taken when the path says the cycle is over.
    if (dut->ch_req && dut->ch_done) {
      if (dut->ch_nxm) out.ok = false;
      if (word < kBlockWords) landed[word]++;
      ++word;
      ++out.words;
      ++words_this_cycle;
    }
    dut->clk = 0;
    dut->eval();
    ++tick;
  };

  for (int k = 0; k < 8; ++k) step();

  // Thirty-two processor cycles, alternating a write and a read of the same
  // address so that the read has a word to bring back.
  for (int c = 0; c < 32 && out.ok; ++c) {
    // A write and then a read of the same address, so that the read has a
    // word to bring back and a bridge that lost it is caught here too.
    const unsigned a = 0x100u + (unsigned)(c / 2) * 7u;
    const bool write = (c % 2) == 0;
    memrq = 0;
    wrcyc = write;
    phys = a;
    wdata = CpuWord(a);
    words_this_cycle = 0;
    long grant = -1, ack = -1;
    for (long k = 0; k < 4000; ++k) {
      step();
      if (!dut->n_memgrant && grant < 0) grant = tick;
      if (dut->timed_out) ++out.timeouts;
      if (grant >= 0 && !dut->n_memack) { ack = tick; break; }
    }
    if (grant < 0 || ack < 0) {
      std::fprintf(stderr,
                   "FAIL: the arbiter's cycle %d was never %s\n", c,
                   grant < 0 ? "granted" : "acknowledged");
      out.ok = false;
      break;
    }
    if (!write && dut->rdata != CpuWord(a)) {
      std::fprintf(stderr,
                   "FAIL: the arbiter's read of %x gave %08x, wanted %08x\n", a,
                   (unsigned)dut->rdata, CpuWord(a));
      out.ok = false;
    }
    if (getenv("ARB_DEBUG"))
      std::fprintf(stderr, "%s cycle %d a=%x wr=%d grant=%ld ack=%ld rdata=%08x words=%ld\n",
                   stream ? "busy" : "idle", c, a, (int)write, grant, ack,
                   (unsigned)dut->rdata, words_this_cycle);
    out.cycle.push_back(ack - grant);
    if (words_this_cycle) ++out.collisions;
    memrq = 1;
    for (int k = 0; k < 8; ++k) step();
  }

  // And the rest of the block, if the processor finished first.
  for (long k = 0; stream && word < kBlockWords && k < 200000; ++k) step();
  if (stream) {
    for (int i = 0; i < kBlockWords; ++i)
      if (landed[i] != 1) {
        std::fprintf(stderr,
                     "FAIL: the channel's word %d was answered %d times\n", i,
                     landed[i]);
        out.ok = false;
        break;
      }
  }
  dut->final();
  delete dut;
  return out;
}

int RunArbiter() {
  std::map<unsigned, unsigned> quiet_ddr, busy_ddr;
  Arb quiet = RunOnce(false, quiet_ddr);
  Arb busy = RunOnce(true, busy_ddr);
  if (!quiet.ok || !busy.ok) return 1;
  if (quiet.cycle.size() != busy.cycle.size() || quiet.cycle.empty()) {
    std::fprintf(stderr, "FAIL: the arbiter's two runs made %zu and %zu "
                         "processor cycles\n",
                 quiet.cycle.size(), busy.cycle.size());
    return 1;
  }
  if (busy.words != kBlockWords) {
    std::fprintf(stderr,
                 "FAIL: the channel moved %ld words of a %d-word block\n",
                 busy.words, kBlockWords);
    return 1;
  }
  if (quiet.words != 0) {
    std::fprintf(stderr, "FAIL: the idle channel moved %ld words\n",
                 quiet.words);
    return 1;
  }
  if (busy.timeouts || quiet.timeouts) {
    std::fprintf(stderr,
                 "FAIL: %ld processor cycles timed out with the channel idle "
                 "and %ld with it streaming: a memory reference the arbiter "
                 "delayed became an NXM\n",
                 quiet.timeouts, busy.timeouts);
    return 1;
  }
  // **ONE MEMORY ACCESS AND NOT TWO.** A word already in flight when the
  // processor asks has to finish; a second word must not start. So the bound
  // is the modelled memory's own latency and the four ticks the handover
  // costs: the tick the bus is left idle as the channel TAKES it, the
  // channel's acknowledgement register, the tick the arbiter takes to give the
  // bus back, and the tick the bus is left idle again as it does. The worst
  // case is the processor asking on the very tick the channel takes the bus.
  //
  // **IT IS THE MEASURED WORST AND NOT A ROUND NUMBER**, so a tick more fails:
  // 10 with `kMemLatency` at 6. A channel that kept the bus for two words costs
  // twice that and is caught by the growth, where a check that only asked
  // whether the cycle timed out could never see it --- two words is 60 ns
  // against 4,250.
  const long bound = kMemLatency + 4;
  long worst = 0;
  for (size_t i = 0; i < quiet.cycle.size(); ++i) {
    const long grew = busy.cycle[i] - quiet.cycle[i];
    if (grew > worst) worst = grew;
    if (grew > bound) {
      std::fprintf(stderr,
                   "FAIL: processor cycle %zu is %ld ticks long with the "
                   "channel streaming and %ld with it idle, %ld more than the "
                   "%ld one memory access may cost it\n",
                   i, busy.cycle[i], quiet.cycle[i], grew, bound);
      return 1;
    }
  }
  // And a run where the channel never once got in the processor's way would
  // pass the bound while testing nothing.
  if (busy.collisions == 0) {
    std::fprintf(stderr,
                 "FAIL: not one of the arbiter's processor cycles overlapped a "
                 "channel word, so the bound above tested nothing\n");
    return 1;
  }
  // The block has to have landed where it was addressed, and nothing else
  // with it: the processor's own words are from a different family and a
  // different page.
  for (int i = 0; i < kBlockWords; ++i) {
    const unsigned byte_addr = 0x1800'0000u + ((kBlockPage + (unsigned)i) << 2);
    auto it = busy_ddr.find(byte_addr);
    if (it == busy_ddr.end() || it->second != BlockWord(i)) {
      std::fprintf(stderr,
                   "FAIL: the channel's word %d is %08x at %08x, wanted %08x\n",
                   i, it == busy_ddr.end() ? 0u : it->second, byte_addr,
                   BlockWord(i));
      return 1;
    }
  }
  if (quiet_ddr.size() + kBlockWords != busy_ddr.size()) {
    std::fprintf(stderr,
                 "FAIL: the streaming run left %zu words in memory and the "
                 "idle one %zu: a block is %d\n",
                 busy_ddr.size(), quiet_ddr.size(), kBlockWords);
    return 1;
  }
  std::printf(
      "    and the arbiter: %zu processor cycles run twice, %ld of them with a "
      "channel word in flight; the worst grew %ld ticks against a bound of %ld, "
      "one memory access. The channel's %ld words all landed, once each, at the "
      "addresses it named.\n",
      busy.cycle.size(), busy.collisions, worst, bound, busy.words);
  return 0;
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
  // -XBUS INIT never comes: the display's flag is the power-on reset's.
  dut->xbus_init = 0;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  // The second master is quiet for the whole of configuration A: this half of
  // the check is held to muir tick for tick, and a channel word would move
  // -MEMACK. What the arbiter does is configuration B's question.
  dut->ch_req = 0;
  dut->ch_write = 0;
  dut->ch_addr = 0;
  dut->ch_wdata = 0;
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

  const int arb = RunArbiter();
  if (arb) return arb;

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
