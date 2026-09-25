// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/machine/quux_mem_port.sv from the reference trace and compares
// every tick.  The trace is golden/src/quux_port.rs's, out of muir's own
// memory_port::MemoryPort, and carries the processor's stimulus as well as
// what the port must do with it: -MEMGRANT, -MEMACK, -LOADMD, NXM TIMEOUT,
// whether the cycle was the memory bus's, and the word a read brings, from
// main memory, the frame buffer or a device register.
//
// **MAIN MEMORY IS THIS PROGRAM'S, AND IT IS A MEMORY.**  It starts as the
// generator's `initial` and is changed by what the port writes, and nothing
// else: a word from the wrong line, the wrong beat or a write that never
// went out reads back wrong on the next read of it, which the trace's word
// catches.  It answers each operation after a latency drawn from a seeded
// generator, one to MAX_LATENCY ticks: sooner than the nominal figures, as a
// board faster than them answers, so every acknowledgment must still land on
// muir's instant --- the floor.  Six at the most, because the floor is only
// muir's instant while main memory really is faster than it: a write behind
// the uncached requester's word waits for that word too, and at twelve ticks
// each the two together passed a write's 29 and the answer came, rightly,
// two ticks after muir's.  The coherence run below is where memory slower
// than the figures is held.  An answer the port took early would be
// faster than muir, and one that waited for the memory rather than the count
// would move with the latency; both fail here.
//
// **THE FRAME BUFFER IS MEMORY TOO** (contract Q7): its words are this
// program's at the display's base, `cadr_ddr_map::DISPLAY_BASE`, starting
// as `Initial` like main memory's, filled a line at a time and written
// through.  A word the port put at main memory's base, or a write that never
// reached the display's, reads back wrong; and the scanout reads these same
// words, so every write reaching them is what the display is owed.
//
// **AND A SECOND REQUESTER SHARES IT**: the uncached one, which on the
// machine is block-disk's transfers.  It asks for words of DDR no cycle of
// the trace touches, past main memory's two million, reads and writes, and
// holds its own copy of what it wrote there to check its reads; the port
// must serve it between the processor's operations without moving one of
// muir's instants.  The coherence run below is where it shares words.
//
// **A DEVICE REGISTER IS THIS PROGRAM TOO**, and it gives its word only in
// the tick the port asks it, the first tick after the grant: every other
// tick it drives the complement, so a word taken a tick early or late reads
// wrong.  And it is asked exactly once, in that tick, and never for a cycle
// that is not a device register's: a register read twice would pop a FIFO
// twice.  The frame is the whole machine's (`tb/cadr_busint_xbus_tb.cpp`
// says why t = 0 is two edges after reset).

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>

#include "Vquux_mem_port.h"
#include "verilated.h"
#include "cadr_tick.h"

namespace {

constexpr uint32_t kMainWords = 32u << 16;
constexpr uint32_t kMainBase = 0x18000000u;   // cadr_ddr_map::MAIN_BASE, Zynq
constexpr uint32_t kFbBase = 0x1C000000u;     // cadr_ddr_map::DISPLAY_BASE, Zynq
constexpr uint32_t kFb = 017000000u;          // tv::BUFFER, the frame buffer's first word
constexpr uint32_t kFbWords = 40960u;         // MONO TV at 1280 by 1024
// The uncached requester's words: DDR past main memory's two million.
constexpr uint32_t kOtherBase = kMainBase + 4u * kMainWords;
constexpr int kMaxLatency = 6;

uint32_t Initial(uint32_t phys) { return (phys + 1u) * 0x9E3779B1u ^ 0x3C5AA5C3u; }

struct Rng {
  uint64_t s;
  uint32_t Next() {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    return static_cast<uint32_t>(s >> 33);
  }
  uint32_t Below(uint32_t n) { return Next() % n; }
};

struct Row {
  long tick;
  int mclk, n_memrq, wrcyc, kind;
  unsigned phys, wdata;
  int inval;
  unsigned dev_word;
  int n_memgrant, n_memack, n_loadmd, timed_out, cached;
  unsigned word;
};

int Fail(const Row &r, const char *what, long got, long want) {
  std::fprintf(stderr,
               "tick %ld: %s is %lx, reference says %lx\n"
               "  inputs: n_memrq=%d wrcyc=%d kind=%d phys=%o mclk=%d\n",
               r.tick, what, got, want, r.n_memrq, r.wrcyc, r.kind, r.phys, r.mclk);
  return 1;
}

// **AND THE PORT'S COHERENCE, WHICH muir DOES NOT MODEL AT ALL.**  muir's
// block-disk moves a transfer's words at START and its cache holds no words,
// so nothing above can see what the fabric's cache does when block-disk's
// words reach main memory beside it, word by word, through the uncached
// requester.  The contract's two rules are held here as properties instead:
// a transfer's read sees every word the processor wrote before it (the write
// buffer is drained first), and no processor read hits a word from before a
// transfer's write (the word's set is dropped as it lands).  Here a
// processor and a transfer run at random over a few sets of the cache, the
// processor writing one set of words and the transfer another and both
// reading all of them, main memory answering in one to sixty ticks --- past
// the nominal figures too, as the DE25's tail does --- and every word read
// must be one the word held at some instant between the read's start and its
// answer.  A word from before a write that ended before the read began is
// the failure either rule would make.
int RunCoherence(Vquux_mem_port *dut) {
  Rng rng{0xc0e4e2e7ull};
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

  // Words the processor writes and words the transfer writes, in the same
  // few sets, so that each drops the other's lines as well as its own.
  const uint32_t kSets[4] = {3, 4, 200, 511};
  const uint32_t kTags[3] = {0, 1, 01777};
  auto pick = [&](bool transfer) {
    const uint32_t set = kSets[rng.Below(4)], tag = kTags[rng.Below(3)];
    // Words 0 and 1 of a line are the processor's, 2 and 3 the transfer's.
    return (tag << 11) | (set << 2) | (transfer ? 2 : 0) | rng.Below(2);
  };
  std::map<uint32_t, std::vector<std::pair<long, uint32_t>>> history;
  auto value_at_or_after = [&](uint32_t a, long from, long to, uint32_t got) {
    const auto it = history.find(a);
    uint32_t current = Initial(a);
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
  std::vector<uint32_t> ddr(kMainWords);
  for (uint32_t a = 0; a < kMainWords; ++a) ddr[a] = Initial(a);

  long answer_at = -1;
  // The processor.
  bool p_asking = false, p_write = false;
  uint32_t p_phys = 0, p_word = 0;
  long p_grant = -1, p_next = 20, p_release = -1;
  // The transfer.
  bool t_asking = false, t_write = false;
  uint32_t t_phys = 0, t_word = 0;
  long t_start = 0, t_next = 30;
  long p_reads = 0, p_writes = 0, t_reads = 0, t_writes = 0, slow = 0, very_slow = 0, pulses = 0;
  int bad = 0;

  for (long t = 0; t < 2000000; ++t) {
    const bool mclk = (t % 4) == 0;
    // Main memory.
    if (dut->mem_req && !dut->mem_done && answer_at < 0) {
      // Now and then far slower than the timeout's 4.25 us, as a port that
      // has not yet been opened is: main memory's cycle waits for it and is
      // never ended as an address nothing answers.
      const uint32_t lat = rng.Below(3000) == 0 ? 500 + rng.Below(200)
                         : rng.Below(8) == 0   ? 40 + rng.Below(20)
                                               : 1 + rng.Below(12);
      if (lat > 29) ++slow;
      if (lat >= 500) ++very_slow;
      answer_at = t + lat;
    }
    if (dut->mem_req && !dut->mem_done && answer_at >= 0 && t >= answer_at) {
      const uint32_t w = (dut->mem_addr - kMainBase) >> 2;
      if (dut->mem_line) {
        for (int k = 0; k < 4; ++k) dut->mem_rline[k] = ddr[(w & ~3u) + k];
      } else if (dut->mem_write) {
        ddr[w] = dut->mem_wdata;
      } else {
        dut->mem_rdata = ddr[w];
      }
      dut->mem_done = 1;
      answer_at = -1;
    }
    if (!dut->mem_req && dut->mem_done) dut->mem_done = 0;

    // The processor: a request at a master clock edge, main memory's.
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
      p_word = rng.Next();
      p_grant = -1;
    }
    dut->n_memrq = !p_asking;
    dut->mclk = mclk;
    dut->wrcyc = p_write;
    dut->phys = p_phys;
    dut->wdata = p_word;
    dut->is_memory = 1;
    // A block-disk register written now and then, between the processor's
    // cycles: the whole cache at the next grant.
    dut->invalidate = !p_asking && rng.Below(400) == 0;
    if (dut->invalidate) ++pulses;

    // The transfer: a word of main memory, held until answered.
    if (!t_asking && t >= t_next && !dut->u_done) {
      t_asking = true;
      t_write = rng.Below(2) == 0;
      t_phys = pick(t_write);
      if (!t_write && rng.Below(2) == 0) t_phys = pick(false);
      t_word = rng.Next();
      t_start = t;
    }
    dut->u_req = t_asking;
    dut->u_write = t_write;
    dut->u_addr = kMainBase + 4 * t_phys;
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
            std::fprintf(stderr, "coherence: tick %ld: the processor read %08x at %o, a word it "
                         "did not hold between %ld and %ld\n", t, dut->word, p_phys, from, t);
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
        // From the tick before it was asked: a processor's write answered
        // on the very tick the transfer asks is one it may or may not see,
        // the two being at one instant.
        if (!value_at_or_after(t_phys, t_start - 1, t, dut->u_rdata)) {
          if (bad < 10)
            std::fprintf(stderr, "coherence: tick %ld: the transfer read %08x at %o, a word it did "
                         "not hold between %ld and %ld\n", t, dut->u_rdata, t_phys, t_start, t);
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
  std::printf("quux_mem_port: coherence: %ld processor reads and %ld writes, %ld transfer reads "
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
  const char *path = (argc > 1) ? argv[1] : "build/quux_port.quux.golden";
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
  dut->eval();
  for (int e = 0; e < kPowerOnEdges; ++e) {
    dut->rst = (e == 0);
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
  }
  dut->rst = 0;

  std::vector<uint32_t> main(kMainWords);
  for (uint32_t a = 0; a < kMainWords; ++a) main[a] = Initial(a);
  std::vector<uint32_t> fb(kFbWords);
  for (uint32_t a = 0; a < kFbWords; ++a) fb[a] = Initial(kFb + a);
  std::map<uint32_t, uint32_t> other;   // the uncached requester's words
  Rng rng{0x6d656d6f7279ull};

  // Main memory's side of the seam.
  long answer_at = -1;
  // The uncached requester.
  bool u_asking = false, u_write = false;
  uint32_t u_addr = 0, u_word = 0;
  long u_next = 50;

  long checked = 0, acks = 0, words = 0, fills = 0, writes_seen = 0, reads_u = 0, writes_u = 0;
  long timeouts = 0, grants = 0, fb_fills = 0, fb_writes = 0, dev_asked = 0, dev_words = 0;
  // The row whose edge granted the cycle standing, and whether its device
  // register has been asked.
  long grant_row = -1;
  bool asked = false;
  int bad = 0;
  char line[256];

  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    Row r;
    const int n = std::sscanf(line, "%ld %d %d %d %d %u %u %d %u %d %d %d %d %d %u", &r.tick,
                              &r.mclk, &r.n_memrq, &r.wrcyc, &r.kind, &r.phys, &r.wdata,
                              &r.inval, &r.dev_word, &r.n_memgrant, &r.n_memack, &r.n_loadmd,
                              &r.timed_out, &r.cached, &r.word);
    if (n != 15) {
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

    // Main memory: an operation is answered `latency` ticks after it is
    // asked, its words read or written then, and the answer held until the
    // port lets go --- `cadr_axi_master.sv`'s protocol.
    if (dut->mem_req && !dut->mem_done && answer_at < 0) {
      answer_at = r.tick + 1 + static_cast<long>(rng.Below(kMaxLatency));
    }
    if (dut->mem_req && !dut->mem_done && answer_at >= 0 && r.tick >= answer_at) {
      const uint32_t a = dut->mem_addr;
      if (a >= kMainBase && a < kMainBase + 4 * kMainWords) {
        const uint32_t w = (a - kMainBase) >> 2;
        if (dut->mem_line) {
          if (dut->mem_write || (w & 3)) {
            bad += Fail(r, "a line fill's address, not a line's", a, a & ~15u);
          }
          for (int k = 0; k < 4; ++k) dut->mem_rline[k] = main[(w & ~3u) + k];
          ++fills;
        } else if (dut->mem_write) {
          main[w] = dut->mem_wdata;
          ++writes_seen;
        } else {
          bad += Fail(r, "a single read of main memory, which only the bridge makes", a, 0);
        }
      } else if (a >= kFbBase && a < kFbBase + 4 * kFbWords) {
        const uint32_t w = (a - kFbBase) >> 2;
        if (dut->mem_line) {
          if (dut->mem_write || (w & 3)) {
            bad += Fail(r, "a line fill's address, not a line's", a, a & ~15u);
          }
          for (int k = 0; k < 4; ++k) dut->mem_rline[k] = fb[(w & ~3u) + k];
          ++fb_fills;
        } else if (dut->mem_write) {
          fb[w] = dut->mem_wdata;
          ++fb_writes;
        } else {
          bad += Fail(r, "a single read of the frame buffer, which only a fill makes", a, 0);
        }
      } else if (a >= kOtherBase && a < kOtherBase + 0x10000u) {
        if (dut->mem_line) bad += Fail(r, "a line fill by the uncached requester", a, 0);
        if (dut->mem_write) other[a] = dut->mem_wdata;
        else dut->mem_rdata = other.count(a) ? other[a] : ~a;
      } else {
        bad += Fail(r, "main memory asked for an address it has not got", a, 0);
      }
      dut->mem_done = 1;
      answer_at = -1;
    }
    if (!dut->mem_req && dut->mem_done) dut->mem_done = 0;

    // The uncached requester: a word outside main memory now and then, held
    // until done, as `cadr_xbus_ddr.sv` holds it.
    // A new word only once the last answer has been let go: the request
    // falls for at least the tick the port takes to see it fall.
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
    // The device register gives its word in the tick it is asked and its
    // complement in every other.
    dut->dev_rdata = dut->dev_rq ? r.dev_word : ~r.dev_word;
    dut->eval();

    // **A REGISTER IS ASKED ONCE, IN THE TICK AFTER THE GRANT, AND ONLY A
    // REGISTER'S CYCLE ASKS** (contract Q7): the memory bus's cycles and an
    // address nothing answers reach no register at all.
    if (dut->dev_rq) {
      if (r.kind != 1) bad += Fail(r, "a register asked on a cycle that is not a register's", 1, 0);
      else if (asked) bad += Fail(r, "a register asked a second time", 1, 0);
      else if (r.tick != grant_row + 1)
        bad += Fail(r, "a register asked, ticks after the grant", r.tick - grant_row, 1);
      asked = true;
      ++dev_asked;
    }
    if (dut->dev_write != r.wrcyc && dut->dev_rq)
      bad += Fail(r, "the register's direction", dut->dev_write, r.wrcyc);
    if (dut->n_memack != r.n_memack) bad += Fail(r, "-MEMACK", dut->n_memack, r.n_memack);
    if (dut->n_loadmd != r.n_loadmd) bad += Fail(r, "-LOADMD", dut->n_loadmd, r.n_loadmd);
    if (dut->timed_out != r.timed_out)
      bad += Fail(r, "NXM TIMEOUT", dut->timed_out, r.timed_out);
    if (!r.n_memack) {
      ++acks;
      if (dut->cached != r.cached) bad += Fail(r, "cached", dut->cached, r.cached);
      if (!r.wrcyc) {
        ++words;
        if (r.kind == 1) ++dev_words;
        if (dut->word != r.word) bad += Fail(r, "the word a read brings", dut->word, r.word);
      }
      if (r.timed_out) ++timeouts;
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
    if (dut->n_memgrant != r.n_memgrant)
      bad += Fail(r, "-MEMGRANT", dut->n_memgrant, r.n_memgrant);
    if (!was_granted && !dut->n_memgrant) {
      grant_row = r.tick;
      asked = false;
    }
    if (r.kind == 1 && !r.n_memack && !asked && r.n_memrq == 0)
      bad += Fail(r, "a register's cycle acknowledged without the register asked", 0, 1);
    if (!r.n_memgrant && r.mclk) ++grants;
    dut->clk = 0;
    dut->eval();
    ++checked;
    if (bad >= 20) {
      std::fprintf(stderr, "stopping after %d mismatches\n", bad);
      break;
    }
  }

  std::printf("quux_mem_port: %ld ticks against muir's MemoryPort; %ld acknowledgments, %ld words "
              "read, %ld of them a register's; %ld line fills and %ld writes reached main memory, "
              "%ld and %ld the frame buffer; %ld registers asked; %ld addresses nothing answers; "
              "the uncached requester made %ld reads and %ld writes; hits %u, misses %u\n",
              checked, acks, words, dev_words, fills, writes_seen, fb_fills, fb_writes, dev_asked,
              timeouts, reads_u, writes_u, dut->hits, dut->misses);
  if (!bad && (fills < 1000 || writes_seen < 1000 || words < 3000 || timeouts < 20 ||
               fb_fills < 100 || fb_writes < 100 || dev_words < 500 || dev_asked < 1000 ||
               reads_u < 100 || writes_u < 100)) {
    std::fprintf(stderr, "FAIL: the run reached too little of the port to say anything\n");
    ++bad;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  if (RunCoherence(dut)) {
    std::fprintf(stderr, "FAIL: the port is not coherent with the uncached requester\n");
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
