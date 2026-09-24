// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// WRITES THAT LAND IN THE MICROCYCLE THAT READS THE SAME MEMORY, AND WRITES
// WHOSE MICROCYCLE IS HELD, ON THE WHOLE MACHINE AGAINST muir's `rtl`.
//
// `golden/src/dispatch_write_order.rs` builds muir's own
// `tests/dispatch_write_order.rs` programs, runs each on `rtl` under the
// fabric's grid and writes every microcycle and the end state.  This runs
// each program on `cadr_machine` --- the processor, the bus interface, the
// decode and the bridge --- and holds it to both.  No reference program
// reaches these corners: MIT's boot PROM writes the dispatch memory and
// never reads it, and neither it nor a band writes a map entry in the
// microcycle before one is read, or a dispatch word in the microcycle that
// pops through it.
//
// WHAT IS CHECKED, per program:
//
//   - every microcycle: PC, IR, the A and M buses, OB, MD and VMA as the
//     read phase before the edge saw them, and the microcycle's length in
//     nanoseconds, which is where a -WAIT or a -HANG shows;
//   - the end state, every word of it: the M memory, the micro-stack and its
//     pointer, the whole dispatch memory, both map levels and the PDL.  The
//     golden names each nonzero word, so every word it does not name must be
//     zero here.
//
// WHAT IS STIMULUS, and how little.  The boot PROM, the level-2 map and the
// dispatch memory the program starts from are loaded into the fabric's own
// arrays before reset is released, as muir's test loads its `Machine`.
// Main memory is a model here, behind `mem_req`/`mem_done`: **the word it
// hands back is the one at the address the bridge asked for**, never the
// trace's, so a read that went to the wrong address comes back with the
// wrong word.  WHEN it answers is muir's: `tb/cadr_machine_tb.cpp`'s
// placement, the acknowledgment's nanosecond rounded up to a tick and a read
// answered `XBUS_ACK_NS` before it.
//
// A program ends in a jump to itself, so its end state does not depend on
// how many microcycles run past that point; the golden says how many run and
// this runs as many.

#include <algorithm>
#include <cerrno>
#include <cinttypes>
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

constexpr int kTickNs = kGridNs;
constexpr int kXbusAckNs = 60;
constexpr uint32_t kMainBase = 0x18000000u;
constexpr uint32_t kNotAnswering = 0xDEADBEE5u;
constexpr long kReadTicks = 1;

// The trace's columns, in the order `golden/src/trace.rs` prints them.
enum Col {
  kCycle, kPc, kIr, kQ, kA, kM, kAlu, kR, kOb, kDc, kOpc, kSt, kLc,
  kWmapd, kDestspcd, kIwrited, kImodd, kPdlwrited, kSpushd, kNop, kNVmaok,
  kJcond, kPcs1, kPcs0, kSrun,
  kLpc, kMd, kVma, kPromdis, kErrstop, kStathenb, kSpeed1, kSpeed0,
  kStall, kHalted, kBus, kAck, kGnt, kSintr, kNs,
  kColumns
};

struct Row {
  uint64_t v[kColumns];
};

struct Program {
  std::string name;
  size_t rows = 0;
  std::vector<uint64_t> prom;
  std::vector<std::pair<uint32_t, uint32_t>> l2, dmem, main;
  uint32_t speed = 0;   // {SPEED1, SPEED0} of the mode register at the boot
  std::vector<Row> trace;
  std::vector<uint32_t> mmem, spc;
  uint32_t spcptr = 0;
  std::map<uint32_t, uint32_t> end_dmem, end_l1, end_l2, end_pdl;
};

bool ParseRow(const char *p, Row &r) {
  for (int i = 0; i < kColumns; ++i) {
    char *end = nullptr;
    r.v[i] = std::strtoull(p, &end, 16);
    if (end == p) return false;
    p = end;
  }
  return true;
}

std::vector<uint32_t> Words(const char *p) {
  std::vector<uint32_t> out;
  for (;;) {
    char *end = nullptr;
    const unsigned long v = std::strtoul(p, &end, 16);
    if (end == p) break;
    out.push_back(static_cast<uint32_t>(v));
    p = end;
  }
  return out;
}

bool Load(const char *path, std::vector<Program> &all) {
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return false;
  }
  char line[1024];
  Program *p = nullptr;
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    char tag[32] = {0}, sub[32] = {0};
    unsigned long long a = 0, b = 0;
    if (std::sscanf(line, "program %31s %llx", tag, &a) == 2) {
      all.emplace_back();
      p = &all.back();
      p->name = tag;
      p->rows = a;
      continue;
    }
    if (!p) return false;
    if (std::sscanf(line, "prom %llx %llx", &a, &b) == 2) {
      if (p->prom.size() <= a) p->prom.resize(a + 1, 0);
      p->prom[a] = b;
    } else if (std::sscanf(line, "l2 %llx %llx", &a, &b) == 2) {
      p->l2.emplace_back(a, b);
    } else if (std::sscanf(line, "dmem %llx %llx", &a, &b) == 2) {
      p->dmem.emplace_back(a, b);
    } else if (std::sscanf(line, "speed %llx", &a) == 1) {
      p->speed = static_cast<uint32_t>(a);
    } else if (std::sscanf(line, "main %llx %llx", &a, &b) == 2) {
      p->main.emplace_back(a, b);
    } else if (line[0] == 'r' && line[1] == ' ') {
      Row r;
      if (!ParseRow(line + 2, r)) return false;
      p->trace.push_back(r);
    } else if (std::sscanf(line, "end %31s", sub) == 1) {
      const char *rest = line + 4 + std::strlen(sub);
      const std::string s = sub;
      if (s == "mmem") p->mmem = Words(rest);
      else if (s == "spc") p->spc = Words(rest);
      else if (s == "spcptr") p->spcptr = Words(rest).at(0);
      else {
        const std::vector<uint32_t> w = Words(rest);
        if (w.size() != 2) return false;
        if (s == "dmem") p->end_dmem[w[0]] = w[1];
        else if (s == "l1") p->end_l1[w[0]] = w[1];
        else if (s == "l2") p->end_l2[w[0]] = w[1];
        else if (s == "pdl") p->end_pdl[w[0]] = w[1];
        else return false;
      }
    } else if (std::strncmp(line, "done", 4) == 0) {
      p = nullptr;
    } else {
      std::fprintf(stderr, "%s: cannot read the line: %s", path, line);
      return false;
    }
  }
  std::fclose(f);
  return true;
}

// Every word of one of the fabric's arrays against the golden's nonzero
// list: a word the list does not name must be zero.
template <typename Array>
int Memory(const Program &p, const char *what, const Array &fabric, size_t n,
           const std::map<uint32_t, uint32_t> &want) {
  int bad = 0;
  for (size_t k = 0; k < n; ++k) {
    const auto it = want.find(static_cast<uint32_t>(k));
    const uint64_t w = it == want.end() ? 0 : it->second;
    const uint64_t got = fabric[k];
    if (got != w) {
      if (bad < 4)
        std::fprintf(stderr, "FAIL: %s: %s[%zo] is %" PRIo64 ", rtl has %" PRIo64 "\n",
                     p.name.c_str(), what, k, got, w);
      ++bad;
    }
  }
  return bad;
}

struct Totals {
  long rows = 0, stalls = 0, reads = 0, writes = 0, disp_writes = 0;
  // `CADR_GAP_MONITOR`'s counts, summed over the programs: where a hung
  // cycle's map or dispatch write landed (`mw` in `cadr_microcycle.sv`).
  uint64_t gm_writes = 0, gm_early = 0, gm_early_b3 = 0, gm_late_l = 0, gm_late_lm1 = 0;
  int64_t gm_min_md = 1000, gm_min_b = 1000;
  std::map<long, long> ack_slip;   // muir's -MEMACK minus the fabric's, ns
};

int Run(const Program &p, Totals &tot) {
  auto *dut = new Vcadr_machine;
  auto *root = dut->rootp;
  dut->n_boot2 = 1;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;      // Machine::new: MAIN_WORDS >> 16
  dut->mem_done = 0;
  dut->mem_rdata = kNotAnswering;
  dut->device_ack = 0;
  dut->device_rdata = kNotAnswering;
  dut->eval();

  // The program and the memories it starts from, into the fabric's own
  // arrays: `Machine::new` with the program's PROM, as muir's test builds it.
  // The control store is left as the fabric brings it up; no program runs
  // out of it.
#define PROC(x) root->cadr_machine__DOT__processor__DOT__##x
  for (size_t k = 0; k < 1024; ++k) PROC(prom_mem)[k] = k < p.prom.size() ? p.prom[k] : 0;
  for (size_t k = 0; k < 2048; ++k) PROC(dmem)[k] = 0;
  for (size_t k = 0; k < 2048; ++k) PROC(l1_map)[k] = 0;
  for (size_t k = 0; k < 1024; ++k) PROC(l2_map)[k] = 0;
  for (size_t k = 0; k < 1024; ++k) PROC(amem)[k] = 0;
  for (size_t k = 0; k < 1024; ++k) PROC(pdl)[k] = 0;
  for (size_t k = 0; k < 32; ++k) PROC(mmem)[k] = 0;
  for (size_t k = 0; k < 32; ++k) PROC(spcm)[k] = 0;
  for (const auto &e : p.l2) PROC(l2_map)[e.first] = e.second;
  for (const auto &e : p.dmem) PROC(dmem)[e.first] = e.second;
  std::map<uint32_t, uint32_t> mem;
  for (const auto &e : p.main) mem[e.first] = e.second;

  // When -MEMACK is due for the bus cycle a row starts: the first nonzero
  // `ack` at or after that row, as `tb/cadr_machine_tb.cpp` finds it.
  std::vector<uint64_t> ack_for(p.trace.size(), 0);
  for (size_t i = 0; i < p.trace.size(); ++i) {
    if (!p.trace[i].v[kBus]) continue;
    size_t j = i;
    while (j < p.trace.size() && p.trace[j].v[kAck] == 0) ++j;
    ack_for[i] = j < p.trace.size() ? p.trace[j].v[kAck] : 0;
  }

  struct Sample {
    uint64_t pc, ir, a, m, ob, md, vma;
  };
  auto take = [&]() {
    return Sample{dut->pc, dut->ir, dut->a, dut->m, dut->ob, dut->md, dut->vma};
  };
  Sample prev = take();

  int bad = 0;
  size_t k = 0;
  long last_edge = -1;
  uint64_t prev_ns = 0;
  bool bus_outstanding = false, ack_armed = false;
  long ack_at_tick = 0;
  uint64_t ack_want = 0;
  const long kMaxTicks = static_cast<long>(p.rows) * 200 + 1024;
  auto fail = [&](const Row &r, const char *what, uint64_t got, uint64_t want) {
    if (bad < 8)
      std::fprintf(stderr,
                   "FAIL: %s: microcycle %" PRIu64 " (PC %" PRIo64 "): %s is %" PRIx64
                   ", rtl has %" PRIx64 "\n",
                   p.name.c_str(), r.v[kCycle], r.v[kPc], what, got, want);
    ++bad;
  };

  for (long t = 0; t < kMaxTicks && k < p.rows; ++t) {
    if (t == 4) dut->rst = 0;
    // The speed the program runs at, in the mode register as the console
    // would leave it, once the reset arm has let go of the register: muir's
    // program sets `Machine::mode` before its boot, which leaves it alone.
    if (t == 5 && p.speed)
      root->cadr_machine__DOT__memory__DOT__spy_registers__DOT__mode_speed = p.speed;

    dut->mem_done = 0;
    dut->mem_rdata = kNotAnswering;
    // A read is answered `XBUS_ACK_NS` before muir's acknowledgment, and one
    // tick later than that; a write at muir's acknowledgment.  Measured, not
    // fitted: without the tick every read acknowledged 10 ns before muir's,
    // which is also what `tb/cadr_machine_tb.cpp`'s histogram prints for its
    // 256 reads of main memory (+0 against its instrument's -10), and a hang
    // then ended 10 ns early; with it a write acknowledged 10 ns late.  The
    // slip is held to zero on every cycle below.
    const long answer_tick =
        ack_at_tick - (dut->mem_write ? 0 : kXbusAckNs / kTickNs - kReadTicks);
    if (dut->mem_req && bus_outstanding && t >= answer_tick) {
      const long w = (static_cast<long>(dut->mem_addr) - static_cast<long>(kMainBase)) / 4;
      if (dut->mem_write) {
        mem[static_cast<uint32_t>(w)] = dut->mem_wdata;
        ++tot.writes;
      } else {
        const auto it = mem.find(static_cast<uint32_t>(w));
        dut->mem_rdata = it == mem.end() ? 0 : it->second;
        ++tot.reads;
      }
      dut->mem_done = 1;
    }

    dut->clk = 1;
    dut->eval();

    if (bus_outstanding && !dut->mem_req && !dut->dev_rq && t > ack_at_tick)
      bus_outstanding = false;

    // WHERE -MEMACK LANDS, against muir's.  Observed after the edge, so an
    // acknowledgment the edge at tick `t` settled is that edge's nanosecond.
    if (ack_armed && !dut->n_memack_o) {
      ack_armed = false;
      const long ns_now = static_cast<long>(prev_ns) + (t - last_edge) * kTickNs;
      tot.ack_slip[static_cast<long>(ack_want) - ns_now]++;
    }

    if (dut->clock_edge) {
      const Row &r = p.trace[k];
      if (prev.pc != r.v[kPc]) fail(r, "PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) fail(r, "IR", prev.ir, r.v[kIr]);
      if (prev.a != r.v[kA]) fail(r, "the A bus", prev.a, r.v[kA]);
      if (prev.m != r.v[kM]) fail(r, "the M bus", prev.m, r.v[kM]);
      if (prev.ob != r.v[kOb]) fail(r, "OB", prev.ob, r.v[kOb]);
      if (prev.md != r.v[kMd]) fail(r, "MD", prev.md, r.v[kMd]);
      if (prev.vma != r.v[kVma]) fail(r, "VMA", prev.vma, r.v[kVma]);
      if (last_edge >= 0) {
        const uint64_t want = r.v[kNs] - prev_ns;
        const uint64_t got = static_cast<uint64_t>(t - last_edge) * kTickNs;
        if (got != want) fail(r, "the microcycle in ns", got, want);
      }
      if (r.v[kStall]) ++tot.stalls;
      if (!r.v[kNop] && ((r.v[kIr] >> 43) & 3) == 2 && ((r.v[kIr] >> 10) & 3) == 2)
        ++tot.disp_writes;
      if (r.v[kBus]) {
        bus_outstanding = true;
        ack_armed = ack_for[k] != 0;
        ack_want = ack_for[k];
        ack_at_tick = t + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
      }
      last_edge = t;
      prev_ns = r.v[kNs];
      ++k;
      ++tot.rows;
      if (bad >= 8) break;
    }

    dut->clk = 0;
    dut->eval();
    prev = take();
  }

  if (k != p.rows && !bad) {
    std::fprintf(stderr, "FAIL: %s: ran %zu of %zu microcycles\n", p.name.c_str(), k, p.rows);
    ++bad;
  }

  // The end state, every word.
  for (size_t i = 0; i < 32; ++i) {
    if (PROC(mmem)[i] != p.mmem.at(i)) {
      std::fprintf(stderr, "FAIL: %s: M[%zo] is %" PRIo32 ", rtl has %" PRIo32 "\n",
                   p.name.c_str(), i, static_cast<uint32_t>(PROC(mmem)[i]), p.mmem.at(i));
      ++bad;
    }
    if ((PROC(spcm)[i] & 0x7ffffu) != (p.spc.at(i) & 0x7ffffu)) {
      std::fprintf(stderr, "FAIL: %s: SPC[%zo] is %" PRIo32 ", rtl has %" PRIo32 "\n",
                   p.name.c_str(), i, static_cast<uint32_t>(PROC(spcm)[i]), p.spc.at(i));
      ++bad;
    }
  }
  if (PROC(spcptr) != p.spcptr) {
    std::fprintf(stderr, "FAIL: %s: SPCPTR is %u, rtl has %u\n", p.name.c_str(),
                 static_cast<unsigned>(PROC(spcptr)), p.spcptr);
    ++bad;
  }
  bad += Memory(p, "the dispatch memory", PROC(dmem), 2048, p.end_dmem);
  bad += Memory(p, "the level-1 map", PROC(l1_map), 2048, p.end_l1);
  bad += Memory(p, "the level-2 map", PROC(l2_map), 1024, p.end_l2);
  bad += Memory(p, "the PDL", PROC(pdl), 1024, p.end_pdl);
#ifdef CADR_GAP_MONITOR
  std::printf("    %-26s writes %" PRIu64 ", early %" PRIu64 " (boundary three on %" PRIu64
              "), two ticks after MD late %" PRIu64 " and on time %" PRIu64 "; nearest MD %" PRId64
              ", nearest boundary %" PRId64 "\n",
              p.name.c_str(), static_cast<uint64_t>(PROC(gm_writes)),
              static_cast<uint64_t>(PROC(gm_early)), static_cast<uint64_t>(PROC(gm_early_b3)),
              static_cast<uint64_t>(PROC(gm_late_l)), static_cast<uint64_t>(PROC(gm_late_lm1)),
              static_cast<int64_t>(PROC(gm_min_md)), static_cast<int64_t>(PROC(gm_min_b)));
  tot.gm_writes += PROC(gm_writes);
  tot.gm_early += PROC(gm_early);
  tot.gm_early_b3 += PROC(gm_early_b3);
  tot.gm_late_l += PROC(gm_late_l);
  tot.gm_late_lm1 += PROC(gm_late_lm1);
  tot.gm_min_md = std::min<int64_t>(tot.gm_min_md, static_cast<int64_t>(PROC(gm_min_md)));
  tot.gm_min_b = std::min<int64_t>(tot.gm_min_b, static_cast<int64_t>(PROC(gm_min_b)));
#endif
#undef PROC

  dut->final();
  delete dut;
  return bad;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = argc > 1 ? argv[1] : "build/dispatch_write_order.golden";
  std::vector<Program> all;
  if (!Load(path, all)) return 2;
  if (all.empty()) {
    std::fprintf(stderr, "FAIL: %s carries no programs\n", path);
    return 1;
  }
  Totals tot;
  int failed = 0;
  for (const Program &p : all) {
    if (p.trace.size() != p.rows || p.mmem.size() != 32 || p.spc.size() != 32) {
      std::fprintf(stderr, "FAIL: %s: the golden's program is incomplete\n", p.name.c_str());
      ++failed;
      continue;
    }
    const int bad = Run(p, tot);
    std::printf("  %-26s %s\n", p.name.c_str(), bad ? "DIFFERS" : "agrees");
    if (bad) ++failed;
  }
  std::printf("dispatch_write_order: %zu programs, %ld microcycles, %ld dispatch writes, "
              "%ld microcycles held by -WAIT or -HANG, "
              "%ld reads and %ld writes of main memory\n",
              all.size(), tot.rows, tot.disp_writes, tot.stalls, tot.reads, tot.writes);
  // The model's placement is the stimulus the whole check stands on, so it is
  // held here rather than trusted: every -MEMACK where muir's is.
  long slipped = 0;
  for (const auto &e : tot.ack_slip) {
    std::printf("    -MEMACK %+ld ns from muir on %ld cycles\n", e.first, e.second);
    if (e.first) slipped += e.second;
  }
  if (slipped) {
    std::fprintf(stderr, "FAIL: %ld acknowledgments are not where muir's are, so the "
                 "stimulus is wrong before the fabric is\n", slipped);
    return 1;
  }
  // A run that reached none of the corners would agree and mean nothing.
  if (!tot.disp_writes || !tot.reads || !tot.stalls) {
    std::fprintf(stderr, "FAIL: the programs reached no dispatch write, no read or no stall\n");
    return 1;
  }
  // WHERE THE MAP AND DISPATCH WRITES LANDED.  The monitor in the processor
  // has already failed the run on a write less than two ticks after MD
  // moved or less than three before a boundary; this asks that the programs
  // came to both bounds, since a bound nothing came near was not measured.
  // An early write whose hang ends on the edge after the pulse is the one
  // the boundary reads three edges after it; a late write follows MD moving
  // at the end of the cycle's last tick, and one on time MD moving at the
  // end of the tick before, both two ticks on.
  std::printf("    map and dispatch writes: %" PRIu64 ", %" PRIu64 " early (%" PRIu64
              " with the boundary three edges on); two ticks after MD moved, %" PRIu64 " late and %" PRIu64
              " on time; nearest MD %" PRId64 " ticks, nearest boundary %" PRId64 "\n",
              tot.gm_writes, tot.gm_early, tot.gm_early_b3, tot.gm_late_l, tot.gm_late_lm1,
              tot.gm_min_md, tot.gm_min_b);
  if (!tot.gm_early_b3 || !tot.gm_late_l || !tot.gm_late_lm1 || tot.gm_min_md != 2 ||
      tot.gm_min_b != 3) {
    std::fprintf(stderr, "FAIL: the programs did not bring a hung write to both of its bounds\n");
    return 1;
  }
  if (failed) {
    std::fprintf(stderr, "FAIL: %d of %zu programs differ from muir's rtl\n", failed, all.size());
    return 1;
  }
  std::printf("ok: every program agrees with muir's rtl, every microcycle and every word\n");
  return 0;
}
