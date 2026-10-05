// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/machine/quux_mem_port.sv at revision 13 (WORD_BITS 40) from
// the reference trace and compares every tick.  The trace is
// golden/src/quux13_port.rs's, out of muir's own memory_port::MemoryPort on
// Geometry::QUUX, and carries the processor's stimulus as well as what
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
// sooner than the nominal figures, as a board faster than them answers, so
// every acknowledgment must still land on muir's instant --- the floor: an
// answer the port took early would be faster than muir, and one that waited
// for the memory rather than the count would move with the latency; and
// a second, uncached requester --- block-disk's channel on the machine ---
// reads and writes whole words of main memory the trace never touches,
// which the port serves between its own operations: a write of five bytes
// at the word's packed address, a read of the one or two beats its bytes
// are in, the word taken from them.  Its words are this program's to check,
// and here it snoops nothing (`u_main` low): a snooped set would move
// muir's hits.
//
// **THE PREFETCH'S BUFFER IS COMPARED AS THE PROCESSOR SEES IT**, at every
// master clock edge: the port's `pf_nx_*` less a store granted at that edge
// to the word it holds, which the processor drops at the grant itself and
// the port a tick later (`cadr_microcycle.sv`, "the prefetch").
//
// **AND THE PORT'S COHERENCE WITH A TRANSFER**, which muir does not model at
// all: muir's block-disk moves a transfer's words at START and its cache
// holds no words, so nothing above can see what the fabric's cache does when
// block-disk's words reach main memory beside it, word by word, through the
// uncached requester.  `RunCoherence13` below holds it, whole 40-bit words in
// packed storage and the cache's 8-word lines.

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
// The uncached requester's words: 64 of main memory, from this word up and
// in lines the trace never touches (`Untouched`).
constexpr uint32_t kOtherPhys = 0x3E00000u;
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

// The trace's lines of main memory, `phys >> 3`, from a pass over it before
// the run: the uncached requester's words are in none of them.
std::vector<uint32_t> Untouched(const char *path) {
  std::FILE *f = std::fopen(path, "r");
  std::vector<uint32_t> words;
  if (!f) return words;
  std::vector<bool> touched(kMainWords / 8);
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    long tick;
    int mclk, n_memrq, wrcyc, kind;
    uint32_t phys;
    if (std::sscanf(line, "%ld %d %d %d %d %u", &tick, &mclk, &n_memrq, &wrcyc, &kind, &phys) == 6 &&
        kind == 0 && phys < kMainWords)
      touched[phys >> 3] = true;
  }
  std::fclose(f);
  // Words at every byte offset of a beat, 0 to 7: 5w mod 8 runs through
  // them all over eight consecutive words.
  for (uint32_t w = kOtherPhys; words.size() < 64 && w < kMainWords; w += (words.size() % 8 == 7) ? 57 : 1)
    if (!touched[w >> 3]) words.push_back(w);
  return words;
}

int Fail(const Row &r, const char *what, uint64_t got, uint64_t want) {
  std::fprintf(stderr,
               "tick %ld: %s is %" PRIx64 ", reference says %" PRIx64 "\n"
               "  inputs: n_memrq=%d wrcyc=%d kind=%d phys=%o mclk=%d\n",
               r.tick, what, got, want, r.n_memrq, r.wrcyc, r.kind, r.phys, r.mclk);
  return 1;
}

// **THE PORT'S COHERENCE WITH A TRANSFER, AT REVISION 13.**  The contract's
// two rules, held as properties with revision 13's words and lines, since
// muir has no model of them: a transfer's read sees every word the
// processor wrote before it (the write buffer is drained first), and no
// processor read hits a word from before a transfer's write (the cache's
// `snoop` drops the word's set as it lands).  The processor and a transfer
// run at random over a few sets of the cache, whole 40-bit words with their
// tags, the processor's in words 0-3 of a line and the transfer's in 4-7 so
// that each drops the other's lines as well as its own; main memory is
// packed storage, bytes, answering in one to sixty ticks and now and then
// far past the timeout; and every word read must be one the word held at
// some instant between the read's start and its answer.
int RunCoherence13(Vquux_mem_port *dut) {
  Rng rng{0xc0e4e2e713ull};
  dut->rst = 1;
  for (int e = 0; e < 4; ++e) {
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
  }
  dut->rst = 0;
  dut->n_memrq = 1;
  dut->mclk = 0;
  dut->u_req = 0;
  dut->mem_done = 0;
  dut->invalidate = 0;
  dut->is_device = 0;
  dut->dev_rdata = 0;
  dut->pf_fetch = 0;
  dut->pf_drop = 0;

  // Sets 3, 4, 200 and 255 of the 256, each with three tags, one past 22
  // bits and one with every bit of the 64M words.
  const uint32_t kSets[4] = {3, 4, 200, 255};
  const uint32_t kTags[3] = {0, 1, 077777};
  auto pick = [&](bool transfer) {
    const uint32_t set = kSets[rng.Below(4)], tag = kTags[rng.Below(3)];
    return (tag << 11) | (set << 3) | (transfer ? 4 : 0) | rng.Below(4);
  };
  auto word40 = [&]() { return ((static_cast<uint64_t>(rng.Next()) << 8) ^ rng.Next()) & kMask40; };
  std::map<uint32_t, std::vector<std::pair<long, uint64_t>>> history;
  auto value_at_or_after = [&](uint32_t a, long from, long to, uint64_t got) {
    const auto it = history.find(a);
    uint64_t current = Initial(a);
    if (it == history.end()) return got == current;
    for (const auto &e : it->second) {
      if (e.first <= from) current = e.second;
    }
    if (got == current) return true;
    for (const auto &e : it->second) {
      if (e.first > from && e.first <= to && e.second == got) return true;
    }
    return false;
  };
  Ddr ddr;

  long answer_at = -1;
  bool p_asking = false, p_write = false;
  uint32_t p_phys = 0;
  uint64_t p_word = 0;
  long p_grant = -1, p_next = 20, p_release = -1;
  bool t_asking = false, t_write = false;
  uint32_t t_phys = 0;
  uint64_t t_word = 0;
  long t_start = 0, t_next = 30;
  long p_reads = 0, p_writes = 0, t_reads = 0, t_writes = 0, slow = 0, very_slow = 0, pulses = 0;
  int bad = 0;

  for (long t = 0; t < 2000000; ++t) {
    const bool mclk = (t % 4) == 0;
    if (dut->mem_req && !dut->mem_done && answer_at < 0) {
      const uint32_t lat = rng.Below(3000) == 0 ? 500 + rng.Below(200)
                         : rng.Below(8) == 0   ? 40 + rng.Below(20)
                                               : 1 + rng.Below(12);
      if (lat > 29) ++slow;
      if (lat >= 500) ++very_slow;
      answer_at = t + lat;
    }
    if (dut->mem_req && !dut->mem_done && answer_at >= 0 && t >= answer_at) {
      const uint32_t a = dut->mem_addr;
      if (!Ddr::InMain(a)) {
        if (bad < 10) std::fprintf(stderr, "coherence: tick %ld: main memory asked at %08x\n", t, a);
        ++bad;
      }
      if (dut->mem_line) {
        for (int w = 0; w < 10; ++w) dut->mem_rline[w] = 0xDEADBEEFu ^ static_cast<uint32_t>(w);
        for (int b = 0; b < 8 * dut->mem_beats; ++b) {
          const uint32_t shift = 8 * (b % 4);
          uint32_t &x = dut->mem_rline[b / 4];
          x = (x & ~(0xFFu << shift)) | (static_cast<uint32_t>(ddr.Get(a + b)) << shift);
        }
      } else if (dut->mem_write) {
        if (!dut->mem_wide) {
          if (bad < 10) std::fprintf(stderr, "coherence: tick %ld: a write of main memory of four bytes\n", t);
          ++bad;
        }
        for (int b = 0; b < 5; ++b) ddr.Put(a + b, static_cast<uint8_t>(dut->mem_wdata >> (8 * b)));
      } else {
        if (bad < 10) std::fprintf(stderr, "coherence: tick %ld: a single read at %08x\n", t, a);
        ++bad;
      }
      dut->mem_done = 1;
      answer_at = -1;
    }
    if (!dut->mem_req && dut->mem_done) dut->mem_done = 0;

    if (p_release == t) {
      p_asking = false;
      p_release = -1;
      p_next = t + 1 + rng.Below(12);
    }
    if (!p_asking && t >= p_next && mclk) {
      p_asking = true;
      p_write = rng.Below(3) == 0;
      p_phys = pick(false);
      if (!p_write && rng.Below(3) == 0) p_phys = pick(true);
      p_word = word40();
      p_grant = -1;
    }
    dut->n_memrq = !p_asking;
    dut->mclk = mclk;
    dut->wrcyc = p_write;
    dut->phys = p_phys;
    dut->wdata = p_word;
    dut->is_memory = 1;
    dut->invalidate = !p_asking && rng.Below(400) == 0;
    if (dut->invalidate) ++pulses;

    if (!t_asking && t >= t_next && !dut->u_done) {
      t_asking = true;
      t_write = rng.Below(2) == 0;
      t_phys = pick(t_write);
      if (!t_write && rng.Below(2) == 0) t_phys = pick(false);
      t_word = word40();
      t_start = t;
    }
    dut->u_req = t_asking;
    dut->u_write = t_write;
    dut->u_addr = ~0u;
    dut->u_wdata = t_word;
    dut->u_main = 1;
    dut->u_phys = t_phys;

    dut->eval();
    if (dut->timed_out || dut->dev_rq) {
      if (bad < 10)
        std::fprintf(stderr, "coherence: tick %ld: a cycle of main memory's %s\n", t,
                     dut->timed_out ? "timed out" : "raised -XBUS.RQ");
      ++bad;
    }
    if (p_asking && p_grant < 0 && !dut->n_memgrant) p_grant = t;
    if (p_asking && !dut->n_memack && p_release < 0) {
      const long from = p_grant < 0 ? t : p_grant;
      if (p_write) {
        history[p_phys].emplace_back(t, p_word);
        ++p_writes;
      } else {
        ++p_reads;
        if (!value_at_or_after(p_phys, from - 1, t, dut->word)) {
          if (bad < 10)
            std::fprintf(stderr, "coherence: tick %ld: the processor read %010" PRIx64 " at %o, a "
                         "word it did not hold between %ld and %ld\n", t,
                         static_cast<uint64_t>(dut->word), p_phys, from, t);
          ++bad;
        }
      }
      p_release = t + 1;
    }
    if (t_asking && dut->u_done) {
      if (t_write) {
        history[t_phys].emplace_back(t, t_word);
        ++t_writes;
      } else {
        ++t_reads;
        if (!value_at_or_after(t_phys, t_start - 1, t, dut->u_rdata)) {
          if (bad < 10)
            std::fprintf(stderr, "coherence: tick %ld: the transfer read %010" PRIx64 " at %o, a "
                         "word it did not hold between %ld and %ld\n", t,
                         static_cast<uint64_t>(dut->u_rdata), t_phys, t_start, t);
          ++bad;
        }
      }
      t_asking = false;
      t_next = t + 1 + rng.Below(20);
    }
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
    if (bad >= 10) break;
  }
  std::printf("quux13_mem_port: coherence: %ld processor reads and %ld writes, %ld transfer reads "
              "and %ld writes, %ld of main memory's answers past the nominal figures and %ld past "
              "the timeout, %ld invalidations; hits %u, misses %u\n",
              p_reads, p_writes, t_reads, t_writes, slow, very_slow, pulses, dut->hits, dut->misses);
  if (!bad && (p_reads < 20000 || t_reads < 20000 || t_writes < 20000 || dut->hits < 5000 ||
               very_slow < 20)) {
    std::fprintf(stderr, "FAIL: the coherence run reached too little\n");
    ++bad;
  }
  return bad;
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

  const std::vector<uint32_t> u_words = Untouched(path);
  if (u_words.size() != 64) {
    std::fprintf(stderr, "FAIL: no room for the uncached requester's words\n");
    return 1;
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
  uint32_t u_phys = 0;
  uint64_t u_word = 0;
  long u_next = 50;
  std::map<uint32_t, uint64_t> other;
  long u_spanning = 0, u_two_beats = 0;

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
        if (u_asking && !u_write && a == ((kMainBase + 5u * u_phys) & ~7u)) {
          // The uncached requester's word: the beats its five bytes are in,
          // which are in a line no fill of the trace's asks.
          const uint32_t at = kMainBase + 5u * u_phys;
          const int want_beats = (at & 7u) > 3u ? 2 : 1;
          if (a != (at & ~7u)) bad += Fail(r, "the uncached read's address", a, at & ~7u);
          if (dut->mem_beats != want_beats) bad += Fail(r, "the uncached read's beats", dut->mem_beats, want_beats);
          beats = dut->mem_beats;
          if (beats == 2) ++u_two_beats;
        } else if (Ddr::InMain(a)) {
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
      } else if (dut->mem_write && u_asking && u_write && a == kMainBase + 5u * u_phys) {
        // The uncached requester's word: its five bytes at its packed address.
        const uint32_t at = kMainBase + 5u * u_phys;
        if (a != at) bad += Fail(r, "where the uncached write went", a, at);
        if (!dut->mem_wide) bad += Fail(r, "the uncached write's five bytes", 0, 1);
        if (dut->mem_wdata != u_word) bad += Fail(r, "the uncached word written", dut->mem_wdata, u_word);
        for (int b = 0; b < 5; ++b) ddr.Put(a + b, static_cast<uint8_t>(dut->mem_wdata >> (8 * b)));
        other[u_phys] = u_word;
        if ((a & 7u) > 3u) ++u_spanning;
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
        } else {
          bad += Fail(r, "a write DDR has not got", a, 0);
        }
      } else {
        bad += Fail(r, "a single read, which revision 13's port never makes", a, 0);
      }
      dut->mem_done = 1;
      answer_at = -1;
    }
    if (!dut->mem_req && dut->mem_done) dut->mem_done = 0;

    // The uncached requester.
    if (!u_asking && r.tick >= u_next && !dut->u_done) {
      u_asking = true;
      u_write = rng.Below(2);
      u_phys = u_words[rng.Below(64)];
      u_word = ((static_cast<uint64_t>(rng.Next()) << 8) ^ rng.Next()) & kMask40;
    }
    dut->u_req = u_asking;
    dut->u_write = u_write;
    dut->u_addr = ~0u;   // not read on revision 13
    dut->u_wdata = u_word;
    dut->u_main = 0;
    dut->u_phys = u_phys;

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
        const uint64_t want = other.count(u_phys) ? other[u_phys] : Initial(u_phys);
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
              "a store's grant dropping it at %ld; the uncached requester made %ld reads, %ld of "
              "them of two beats, and %ld writes, %ld of them across two; hits %u, misses %u\n",
              checked, acks, words, dev_words, fills, crossing_lines, fb_fills, writes_main,
              spanning_writes, fb_writes, dev_asked, timeouts, pf_compared, pf_held,
              pf_view_dropped, reads_u, u_two_beats, writes_u, u_spanning, dut->hits, dut->misses);
  if (!bad && (fills < 1000 || writes_main < 1000 || spanning_writes < 300 || fb_fills < 100 ||
               fb_writes < 100 || words < 3000 || timeouts < 20 || dev_words < 500 ||
               pf_held < 1000 || pf_view_dropped < 10 || reads_u < 100 || writes_u < 100 ||
               u_two_beats < 20 || u_spanning < 20)) {
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
  if (RunCoherence13(dut)) {
    std::fprintf(stderr, "FAIL: the port is not coherent with the uncached requester\n");
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
