// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/machine/quux_mem_port.sv at revision 13 (WORD_BITS 40) from
// the reference trace and compares every tick.  The trace is
// golden/src/quux13_port.rs's, out of muir's own memory_port::MemoryPort on
// Geometry::QUUX_13, and carries the processor's stimulus as well as what
// the port must do with it: -MEMGRANT, -MEMACK, -LOADMD, NXM TIMEOUT,
// whether the cycle was the memory bus's, the word a read brings, and the
// prefetch's buffer at every master clock edge.
//
// **MAIN MEMORY IS THIS PROGRAM'S, AND IT IS BYTES.**  Packed storage as
// contract G1 §4.1 lays it out, transcribed here and not taken from the
// port: word w in the five bytes from `kMainBase + 5w`, `<7:0>` first and
// the tag last.  Every byte starts as its word's byte of the generator's
// `Initial`, and changes only when the port writes it.  So a fill that asks
// the wrong bytes, a line not of five beats, a write of the wrong bytes or
// strobes, or a word packed any other way reads back wrong on the next read
// of it; and every write the port makes is checked, where it lands and what
// it carries, against the cycle the trace wrote, in order.  The base is
// `MAIN13_BASE` as this model is built with it (`Makefile`), an address no
// other check uses, so a port that ignored the parameter misses it.
//
// **THE WINDOW IS BYTES TOO**, four a word at the display's base, the field
// alone (G1 §4.2): a line of it is four beats, a write four bytes.
//
// It answers each operation after a latency drawn from a seeded generator,
// sooner than the nominal figures, so every acknowledgment must still land
// on muir's instant, as `tb/quux_mem_port_tb.cpp` says for revision 12; and
// a second, uncached requester reads and writes words of DDR past main
// memory, which the port serves between its own operations.
//
// **THE PREFETCH'S BUFFER IS COMPARED AS THE PROCESSOR SEES IT**, at every
// master clock edge: the port's `pf_nx_*` less a store granted at that edge
// to the word it holds, which the processor drops at the grant itself and
// the port a tick later (`cadr_microcycle.sv`, "the prefetch").
//
// Not held here: coherence with a transfer beside the processor, which on
// revision 13 is block-disk's two transfers and their seam, not built yet.

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <unordered_map>
#include <vector>

#include "Vquux_mem_port.h"
#include "verilated.h"
#include "cadr_tick.h"

namespace {

// The base this model is built with, `-GMAIN13_BASE` in the Makefile.
constexpr uint32_t kMainBase = 0x06123000u;
constexpr uint64_t kMainWords = 64ull << 20;
constexpr uint32_t kFbBase = 0x1C000000u;   // cadr_ddr_map::DISPLAY_BASE, Zynq
constexpr uint32_t kWindow = 01760000000u;
constexpr uint32_t kFbWords = 40960u;
// The uncached requester's words: DDR past main memory's bytes.
constexpr uint32_t kOtherBase = 0x1B000000u;
constexpr int kMaxLatency = 6;
constexpr uint64_t kMask40 = (1ull << 40) - 1;

uint64_t Initial(uint32_t phys) {
  const uint64_t x = (static_cast<uint64_t>(phys) + 1) * 0x9E3779B97F4A7C15ull;
  return ((x >> 20) ^ 0x3C5AA5C3A5ull) & kMask40;
}

struct Rng {
  uint64_t s;
  uint32_t Next() {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    return static_cast<uint32_t>(s >> 33);
  }
  uint32_t Below(uint32_t n) { return Next() % n; }
};

// DDR, a byte at a time: what the port wrote, and otherwise the initial
// word's byte, laid out as G1 says.
struct Ddr {
  std::unordered_map<uint32_t, uint8_t> written;
  static bool InMain(uint32_t a) { return a >= kMainBase && a - kMainBase < 5 * kMainWords; }
  static bool InFb(uint32_t a) { return a >= kFbBase && a - kFbBase < 4u * kFbWords; }
  uint8_t Get(uint32_t a) const {
    const auto it = written.find(a);
    if (it != written.end()) return it->second;
    if (InMain(a)) {
      const uint32_t off = a - kMainBase;
      return static_cast<uint8_t>(Initial(off / 5) >> (8 * (off % 5)));
    }
    if (InFb(a)) {
      const uint32_t off = a - kFbBase;
      return static_cast<uint8_t>(Initial(kWindow + off / 4) >> (8 * (off % 4)));
    }
    return static_cast<uint8_t>(~a);
  }
  void Put(uint32_t a, uint8_t b) { written[a] = b; }
};

struct Row {
  long tick;
  int mclk, n_memrq, wrcyc, kind;
  uint32_t phys;
  uint64_t wdata;
  int inval;
  uint32_t dev_word;
  int fetch;
  uint32_t vaddr;
  int drop;
  int n_memgrant, n_memack, n_loadmd, timed_out, cached;
  uint64_t word;
  int pf_v;
  uint32_t pf_vaddr, pf_phys;
  uint64_t pf_word;
};

int Fail(const Row &r, const char *what, uint64_t got, uint64_t want) {
  std::fprintf(stderr,
               "tick %ld: %s is %" PRIx64 ", reference says %" PRIx64 "\n"
               "  inputs: n_memrq=%d wrcyc=%d kind=%d phys=%o mclk=%d\n",
               r.tick, what, got, want, r.n_memrq, r.wrcyc, r.kind, r.phys, r.mclk);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/quux13_port.quux.k4.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  auto *dut = new Vquux_mem_port;
  dut->clk = 0;
  dut->rst = 1;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->is_device = 0;
  dut->dev_rdata = 0;
  dut->mem_done = 0;
  dut->u_req = 0;
  dut->invalidate = 0;
  dut->pf_fetch = 0;
  dut->pf_drop = 0;
  dut->eval();
  for (int e = 0; e < kPowerOnEdges; ++e) {
    dut->rst = (e == 0);
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
  }
  dut->rst = 0;

  Ddr ddr;
  Rng rng{0x13ed0f13ull};

  long answer_at = -1;
  bool u_asking = false, u_write = false;
  uint32_t u_addr = 0, u_word = 0;
  long u_next = 50;
  std::map<uint32_t, uint32_t> other;

  // The writes the trace's cycles owe main memory and the window, in
  // order: the physical address and the word, taken at the acknowledgment.
  std::deque<std::pair<uint32_t, uint64_t>> owed;

  long checked = 0, acks = 0, words = 0, fills = 0, fb_fills = 0, writes_main = 0, fb_writes = 0;
  long spanning_writes = 0, crossing_lines = 0, dev_asked = 0, dev_words = 0, timeouts = 0;
  long reads_u = 0, writes_u = 0, pf_compared = 0, pf_held = 0, pf_view_dropped = 0;
  long grant_row = -1;
  bool asked = false;
  bool acked_seen = false;
  int bad = 0;
  char line[512];

  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    Row r;
    const int n = std::sscanf(line,
                              "%ld %d %d %d %d %u %" SCNu64 " %d %u %d %u %d %d %d %d %d %d %" SCNu64
                              " %d %u %u %" SCNu64,
                              &r.tick, &r.mclk, &r.n_memrq, &r.wrcyc, &r.kind, &r.phys, &r.wdata,
                              &r.inval, &r.dev_word, &r.fetch, &r.vaddr, &r.drop, &r.n_memgrant,
                              &r.n_memack, &r.n_loadmd, &r.timed_out, &r.cached, &r.word, &r.pf_v,
                              &r.pf_vaddr, &r.pf_phys, &r.pf_word);
    if (n != 22) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }

    dut->mclk = r.mclk;
    dut->n_memrq = r.n_memrq;
    dut->wrcyc = r.wrcyc;
    dut->phys = r.phys;
    dut->wdata = r.wdata;
    dut->is_memory = (r.kind == 0);
    dut->is_device = (r.kind == 1);
    dut->invalidate = r.inval;
    dut->pf_fetch = r.fetch;
    dut->pf_vaddr = r.vaddr;
    dut->pf_drop = r.drop;

    // Main memory: an operation answered `latency` ticks after it is asked,
    // its bytes read or written then, and the answer held until the port
    // lets go.
    if (dut->mem_req && !dut->mem_done && answer_at < 0) {
      answer_at = r.tick + 1 + static_cast<long>(rng.Below(kMaxLatency));
    }
    if (dut->mem_req && !dut->mem_done && answer_at >= 0 && r.tick >= answer_at) {
      const uint32_t a = dut->mem_addr;
      if (dut->mem_line) {
        if (dut->mem_write) bad += Fail(r, "a line fill that writes", 1, 0);
        int beats = 0;
        if (Ddr::InMain(a)) {
          const uint32_t off = a - kMainBase;
          // The line of the cycle standing, 40 bytes at its eight words.
          const uint32_t want = kMainBase + 40u * (r.phys >> 3);
          if (off % 40 != 0 || a != want) bad += Fail(r, "a line fill's address in main memory", a, want);
          if (dut->mem_beats != 5) bad += Fail(r, "a main memory line's beats", dut->mem_beats, 5);
          beats = 5;
          ++fills;
          if ((a & 0xFFFu) + 40u > 0x1000u) ++crossing_lines;
        } else if (Ddr::InFb(a)) {
          const uint32_t want = kFbBase + 32u * ((r.phys - kWindow) >> 3);
          if (a != want) bad += Fail(r, "a line fill's address in the window", a, want);
          if (dut->mem_beats != 4) bad += Fail(r, "a window line's beats", dut->mem_beats, 4);
          beats = 4;
          ++fb_fills;
        } else {
          bad += Fail(r, "a line fill outside main memory and the window", a, 0);
        }
        for (int w = 0; w < 10; ++w) dut->mem_rline[w] = 0xDEADBEEFu ^ static_cast<uint32_t>(w);
        for (int b = 0; b < 8 * beats; ++b) {
          const uint32_t shift = 8 * (b % 4);
          uint32_t &x = dut->mem_rline[b / 4];
          x = (x & ~(0xFFu << shift)) | (static_cast<uint32_t>(ddr.Get(a + b)) << shift);
        }
      } else if (dut->mem_write) {
        if (Ddr::InMain(a) || Ddr::InFb(a)) {
          const bool main = Ddr::InMain(a);
          if (owed.empty()) {
            bad += Fail(r, "a write no cycle made", a, 0);
          } else {
            const auto want = owed.front();
            owed.pop_front();
            const uint32_t want_addr = want.first >= kWindow ? kFbBase + 4u * (want.first - kWindow)
                                                              : kMainBase + 5u * want.first;
            const uint64_t want_word = want.first >= kWindow ? (want.second & 0xFFFFFFFFull) : want.second;
            if (a != want_addr) bad += Fail(r, "where the write went", a, want_addr);
            if (dut->mem_wide != (main ? 1 : 0)) bad += Fail(r, "a write's five bytes", dut->mem_wide, main);
            if (dut->mem_wdata != want_word) bad += Fail(r, "the word written", dut->mem_wdata, want_word);
          }
          const int bytes = dut->mem_wide ? 5 : 4;
          for (int b = 0; b < bytes; ++b) ddr.Put(a + b, static_cast<uint8_t>(dut->mem_wdata >> (8 * b)));
          if (main) {
            ++writes_main;
            if ((a & 7u) > 3u) ++spanning_writes;
          } else {
            ++fb_writes;
          }
        } else if (a >= kOtherBase && a < kOtherBase + 0x10000u) {
          if (dut->mem_wide) bad += Fail(r, "an uncached write of five bytes", 1, 0);
          other[a] = static_cast<uint32_t>(dut->mem_wdata);
        } else {
          bad += Fail(r, "a write DDR has not got", a, 0);
        }
      } else {
        if (a >= kOtherBase && a < kOtherBase + 0x10000u) {
          dut->mem_rdata = other.count(a) ? other[a] : ~a;
        } else {
          bad += Fail(r, "a single read, which only the uncached requester makes", a, 0);
        }
      }
      dut->mem_done = 1;
      answer_at = -1;
    }
    if (!dut->mem_req && dut->mem_done) dut->mem_done = 0;

    // The uncached requester.
    if (!u_asking && r.tick >= u_next && !dut->u_done) {
      u_asking = true;
      u_write = rng.Below(2);
      u_addr = kOtherBase + 4 * rng.Below(64);
      u_word = rng.Next();
    }
    dut->u_req = u_asking;
    dut->u_write = u_write;
    dut->u_addr = u_addr;
    dut->u_wdata = u_word;
    dut->u_main = 0;
    dut->u_phys = 0;

    dut->eval();
    dut->dev_rdata = dut->dev_rq ? r.dev_word : ~r.dev_word;
    dut->eval();

    if (dut->dev_rq) {
      if (r.kind != 1) bad += Fail(r, "a register asked on a cycle that is not a register's", 1, 0);
      else if (asked) bad += Fail(r, "a register asked a second time", 1, 0);
      else if (r.tick != grant_row + 1)
        bad += Fail(r, "a register asked, ticks after the grant", r.tick - grant_row, 1);
      asked = true;
      ++dev_asked;
    }
    if (dut->n_memack != r.n_memack) bad += Fail(r, "-MEMACK", dut->n_memack, r.n_memack);
    if (dut->n_loadmd != r.n_loadmd) bad += Fail(r, "-LOADMD", dut->n_loadmd, r.n_loadmd);
    if (dut->timed_out != r.timed_out) bad += Fail(r, "NXM TIMEOUT", dut->timed_out, r.timed_out);
    if (!r.n_memack) {
      ++acks;
      if (dut->cached != r.cached) bad += Fail(r, "cached", dut->cached, r.cached);
      if (!r.wrcyc) {
        ++words;
        if (r.kind == 1) ++dev_words;
        if (dut->word != r.word) bad += Fail(r, "the word a read brings", dut->word, r.word);
      } else if (r.kind == 0 && !acked_seen) {
        // The write the cycle owes DDR, which the port writes from its
        // buffer later.
        owed.emplace_back(r.phys, r.wdata);
      }
      if (r.timed_out) ++timeouts;
      acked_seen = true;
    } else {
      acked_seen = false;
    }

    // The prefetch's buffer as the processor takes it at this edge.
    if (r.mclk) {
      const bool take = !r.n_memrq && dut->n_memgrant;
      const bool store_drop = take && r.wrcyc && dut->pf_nx_phys == r.phys;
      const bool view = dut->pf_nx_v && !store_drop;
      if (dut->pf_nx_v && store_drop) ++pf_view_dropped;
      ++pf_compared;
      if (view != (r.pf_v != 0)) bad += Fail(r, "the prefetch holds a word", view, r.pf_v);
      if (view && r.pf_v) {
        ++pf_held;
        if (dut->pf_nx_vaddr != r.pf_vaddr) bad += Fail(r, "the prefetched word's virtual address", dut->pf_nx_vaddr, r.pf_vaddr);
        if (dut->pf_nx_phys != r.pf_phys) bad += Fail(r, "the prefetched word's physical address", dut->pf_nx_phys, r.pf_phys);
        if (dut->pf_nx_word != r.pf_word) bad += Fail(r, "the prefetched word", dut->pf_nx_word, r.pf_word);
      }
    }

    if (u_asking && dut->u_done) {
      if (u_write) {
        ++writes_u;
      } else {
        ++reads_u;
        const uint32_t want = other.count(u_addr) ? other[u_addr] : ~u_addr;
        if (dut->u_rdata != want) bad += Fail(r, "the uncached requester's word", dut->u_rdata, want);
      }
      u_asking = false;
      u_next = r.tick + 1 + static_cast<long>(rng.Below(300));
    }

    const bool was_granted = !dut->n_memgrant;
    dut->clk = 1;
    dut->eval();
    if (dut->n_memgrant != r.n_memgrant) bad += Fail(r, "-MEMGRANT", dut->n_memgrant, r.n_memgrant);
    if (!was_granted && !dut->n_memgrant) {
      grant_row = r.tick;
      asked = false;
    }
    if (r.kind == 1 && !r.n_memack && !asked && r.n_memrq == 0)
      bad += Fail(r, "a register's cycle acknowledged without the register asked", 0, 1);
    dut->clk = 0;
    dut->eval();
    ++checked;
    if (bad >= 20) {
      std::fprintf(stderr, "stopping after %d mismatches\n", bad);
      break;
    }
  }

  std::printf("quux13_mem_port: %ld ticks against muir's MemoryPort on revision 13; %ld "
              "acknowledgments, %ld words read, %ld of them a register's; %ld line fills of main "
              "memory, %ld of them across 4 KiB, and %ld of the window; %ld writes of main memory, "
              "%ld of them across two beats, and %ld of the window; %ld registers asked; %ld "
              "addresses nothing answers; the prefetch compared at %ld edges, holding a word at %ld, "
              "a store's grant dropping it at %ld; the uncached requester made %ld reads and %ld "
              "writes; hits %u, misses %u\n",
              checked, acks, words, dev_words, fills, crossing_lines, fb_fills, writes_main,
              spanning_writes, fb_writes, dev_asked, timeouts, pf_compared, pf_held,
              pf_view_dropped, reads_u, writes_u, dut->hits, dut->misses);
  if (!bad && (fills < 1000 || writes_main < 1000 || spanning_writes < 300 || fb_fills < 100 ||
               fb_writes < 100 || words < 3000 || timeouts < 20 || dev_words < 500 ||
               pf_held < 1000 || pf_view_dropped < 10 || reads_u < 100 || writes_u < 100)) {
    std::fprintf(stderr, "FAIL: the run reached too little of the port to say anything\n");
    ++bad;
  }
  // The last write may still be in the buffer when the trace ends.
  if (!bad && owed.size() > 1) {
    std::fprintf(stderr, "FAIL: %zu writes the trace made never reached DDR\n", owed.size());
    ++bad;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
