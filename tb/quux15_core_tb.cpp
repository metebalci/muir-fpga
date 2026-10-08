// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds revision 15's core to muir's pipeline clock for clock, over traces of
// `golden/src/quux15.rs`, whose columns `golden/src/trace15.rs` says.
//
//   V<top> <trace>... [+plusargs, handed to the design]
//
// A trace is one run or several, each from its header line (`# clock ...`)
// on, named by its `# run` line.  **A RUN BRINGS ITS MEMORIES**: its
// `# image <memory> <address> <word>` lines are written into the core's
// PROM, control store, A, M, dispatch memory and PDL buffer after its RAMs
// have come up and before its reset ends, as a bitstream would hold them
// (`QUUX15_CORE`'s build; the stand-in has no memories and ignores them).
//
// The design is the Verilated top `QUUX15_TOP` names, built with this file:
// revision 15's core (`rtl/machine/quux15_core.sv`), or `tb/quux15_replay.sv`,
// the stand-in that shows this testbench catches what it should
// (`tools/quux15_replay_check.py`).  Either shows the trace's columns on
// outputs of the same names, `obs_<column>`.  Each trace is run on a design
// of its own, made afresh.
//
// **EVERY REGISTER COMES UP RANDOM.**  The core is built with Verilator's
// `--x-initial unique` and run under `Verilated::randReset(2)`, a run's seed
// `QUUX15_SEED` (1 if unset) plus its place in its trace, which a failure
// names, so that state its reset does not set is whatever a board's would
// be, and a trace that reads it fails.  The
// memories come up as the core's `initial` blocks say, which is what a
// bitstream says of a RAM.
//
// **ROW k IS THE DESIGN AS CLOCK k ENDS.**  `rst` is held high for four
// rising edges and dropped; row 0 is compared there, with no edge since, and
// row k after the k-th rising edge from it.  Each column of each row is
// compared, with these rules, which leave out what muir does not define:
//
//   cs rd ex wb commit   a stage's word, `<15>` valid, `<14>` nopped,
//                        `<13:0>` its address: the valid bit always; whether
//                        nopped when valid; the address when valid and not
//                        nopped (muir gives no nopped word's address)
//   pdlptr ... ic, opnd  the eight registers, and whether the word committed
//                        was an ALU or a BYTE word, on a row whose commit is
//                        valid
//   ea em ob             that word's operands and output, on a row where it
//                        was
//   gaddr, mdword, raddr an event's address or word, on a row with its event
//   the rest             every row
//
// A design that stops the simulation (`$finish`, the core's "not built")
// fails at that clock.  Nothing here computes what a core should do: every
// value it holds a column to is the trace's.  It reports the first 20
// differences and the first one again on its last line, `FAIL: ... the first
// at clock <k>, <column>`, which the stand-in's check reads.

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "verilated.h"

#ifndef QUUX15_TOP
#error "QUUX15_TOP names the Verilated top: Vquux15_replay, or revision 15's core"
#endif
#define QUUX15_STR2(x) #x
#define QUUX15_STR(x) QUUX15_STR2(x)
#define QUUX15_HEADER(x) QUUX15_STR(x.h)
#include QUUX15_HEADER(QUUX15_TOP)
#ifdef QUUX15_CORE
#include "Vquux15_core___024root.h"
#endif

namespace {

using Top = QUUX15_TOP;

// What a trace's runs held, summed for its line.
struct Totals {
  size_t clocks = 0, commits = 0, operands = 0, grants = 0, landed = 0, registers = 0;
} totals;

// When a column is compared, by the trace's row.
enum When { kEvery, kStage, kAtCommit, kIfGrant, kIfMd, kIfReg, kIfOpnd };

struct Column {
  const char *name;
  When when;
  uint64_t (*get)(const Top *);
};

#define QUUX15_COLUMN(n, w) \
  { #n, w, [](const Top *d) -> uint64_t { return static_cast<uint64_t>(d->obs_##n); } }

// In the trace's order, after its clock.
const Column kColumns[] = {
    QUUX15_COLUMN(cs, kStage),         QUUX15_COLUMN(rd, kStage),
    QUUX15_COLUMN(ex, kStage),         QUUX15_COLUMN(wb, kStage),
    QUUX15_COLUMN(commit, kStage),     QUUX15_COLUMN(pdlptr, kAtCommit),
    QUUX15_COLUMN(pdlidx, kAtCommit),  QUUX15_COLUMN(spcptr, kAtCommit),
    QUUX15_COLUMN(q, kAtCommit),       QUUX15_COLUMN(vma, kAtCommit),
    QUUX15_COLUMN(md, kAtCommit),      QUUX15_COLUMN(lc, kAtCommit),
    QUUX15_COLUMN(ic, kAtCommit),      QUUX15_COLUMN(opnd, kAtCommit),
    QUUX15_COLUMN(ea, kIfOpnd),        QUUX15_COLUMN(em, kIfOpnd),
    QUUX15_COLUMN(ob, kIfOpnd),        QUUX15_COLUMN(oalow, kEvery),
    QUUX15_COLUMN(oahigh, kEvery),     QUUX15_COLUMN(grant, kEvery),
    QUUX15_COLUMN(gaddr, kIfGrant),    QUUX15_COLUMN(mdl, kEvery),
    QUUX15_COLUMN(mdword, kIfMd),      QUUX15_COLUMN(reg, kEvery),
    QUUX15_COLUMN(raddr, kIfReg),      QUUX15_COLUMN(queue, kEvery),
    QUUX15_COLUMN(inflight, kEvery),   QUUX15_COLUMN(halted, kEvery),
    QUUX15_COLUMN(errhalt, kEvery),
};
constexpr size_t kN = sizeof kColumns / sizeof kColumns[0];

// The trace's columns, by name, for the rules.
constexpr size_t kCommit = 4, kOpnd = 13, kGrant = 19, kMdl = 21, kReg = 23;

bool stage_agrees(uint64_t got, uint64_t want) {
  if (got >> 16) return false;
  const bool valid = (want >> 15) & 1, nop = (want >> 14) & 1;
  if (((got >> 15) & 1) != valid) return false;
  if (!valid) return true;
  if (((got >> 14) & 1) != nop) return false;
  if (nop) return true;
  return (got & 0x3fff) == (want & 0x3fff);
}

bool compared(When w, const std::vector<uint64_t> &row) {
  switch (w) {
    case kEvery:
    case kStage:
      return true;
    case kAtCommit:
      return (row[kCommit] >> 15) & 1;
    case kIfGrant:
      return row[kGrant] != 0;
    case kIfMd:
      return row[kMdl] != 0;
    case kIfReg:
      return row[kReg] != 0;
    case kIfOpnd:
      return ((row[kCommit] >> 15) & 1) && row[kOpnd] != 0;
  }
  return true;
}

std::vector<std::string> words(const char *line) {
  std::vector<std::string> out;
  const char *p = line;
  while (*p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') ++p;
    const char *q = p;
    while (*q && *q != ' ' && *q != '\t' && *q != '\n' && *q != '\r') ++q;
    if (q > p) out.emplace_back(p, q - p);
    p = q;
  }
  return out;
}

// One run of a trace: its name, its memories' words and its rows.
struct Image {
  std::string memory;
  uint64_t address, word;
};
struct Run {
  std::string name;
  std::vector<Image> images;
  std::vector<std::vector<uint64_t>> rows;
};

// The run's memories into the design, which has just come up.
bool load(Top *dut, const Run &run, const char *path) {
#ifdef QUUX15_CORE
  auto *r = dut->rootp;
  for (const Image &i : run.images) {
    bool ok = true;
    if (i.memory == "prom" && i.address < 1024)
      r->quux15_core__DOT__store__DOT__prom[i.address] = i.word;
    else if (i.memory == "imem" && i.address < 16384)
      r->quux15_core__DOT__store__DOT__ram__DOT__mem[i.address] = i.word;
    else if (i.memory == "amem" && i.address < 1024)
      r->quux15_core__DOT__amem__DOT__mem[i.address] = i.word & 0xffffffffffull;
    else if (i.memory == "mmem" && i.address < 32)
      r->quux15_core__DOT__mmem[i.address] = i.word & 0xffffffffffull;
    else if (i.memory == "dmem" && i.address < 4096)
      r->quux15_core__DOT__dmem[i.address] = static_cast<uint32_t>(i.word & 0x1ffff);
    else if (i.memory == "pdl" && i.address < 16384)
      r->quux15_core__DOT__pdl__DOT__mem[i.address] = i.word & 0xffffffffffull;
    else
      ok = false;
    if (!ok) {
      std::fprintf(stderr, "%s: run %s: no memory `%s` with a word %" PRIx64 "\n", path,
                   run.name.c_str(), i.memory.c_str(), i.address);
      return false;
    }
  }
#else
  // The stand-in plays rows back and has no memories to take.
  (void)dut;
  (void)run;
  (void)path;
#endif
  return true;
}

// Reads `path`'s runs: 0 when it is a reference this testbench reads, and
// otherwise what the program exits with.
int read_trace(const char *path, std::vector<Run> &runs) {
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  char line[1024];
  bool header = false;
  int result = 0;
  while (result == 0 && std::fgets(line, sizeof line, f)) {
    std::vector<std::vector<uint64_t>> &rows = runs.empty() ? runs.emplace_back().rows : runs.back().rows;
    if (line[0] == '#') {
      if (std::strstr(line, "PLANTED FAULT")) {
        std::fprintf(stderr, "%s carries a fault planted in muir; it is no reference\n", path);
        result = 2;
        break;
      }
      std::vector<std::string> w = words(line + 1);
      if (w.size() == 4 && w[0] == "image") {
        runs.back().images.push_back({w[1], std::strtoull(w[2].c_str(), nullptr, 16),
                                      std::strtoull(w[3].c_str(), nullptr, 16)});
        continue;
      }
      if (w.size() >= 2 && w[0] == "run") {
        runs.back().name = w[1];
        continue;
      }
      if (!w.empty() && w[0] == "clock") {
        // A run begins.
        if (!runs.back().rows.empty() || header) runs.emplace_back();
        bool ok = w.size() == kN + 1;
        for (size_t c = 0; ok && c < kN; ++c) ok = w[c + 1] == kColumns[c].name;
        if (!ok) {
          std::fprintf(stderr, "%s: its columns are not the ones this testbench compares\n", path);
          result = 2;
          break;
        }
        header = true;
      }
      continue;
    }
    std::vector<std::string> w = words(line);
    if (w.empty()) continue;
    if (w.size() != kN + 1) {
      std::fprintf(stderr, "%s: row %zu has %zu columns, not %zu\n", path, rows.size(), w.size(),
                   kN + 1);
      result = 2;
      break;
    }
    std::vector<uint64_t> v;
    for (const std::string &s : w) v.push_back(std::strtoull(s.c_str(), nullptr, 16));
    if (v[0] != rows.size()) {
      std::fprintf(stderr, "%s: row %zu is clock %" PRIu64 "\n", path, rows.size(), v[0]);
      result = 2;
      break;
    }
    rows.push_back(v);
  }
  std::fclose(f);
  for (size_t k = 0; result == 0 && k < runs.size(); ++k) {
    if (runs[k].name.empty()) runs[k].name = std::to_string(k);
    if (!header || runs[k].rows.size() < 2) {
      std::fprintf(stderr, "FAIL: %s run %s carries %s%zu rows\n", path, runs[k].name.c_str(),
                   header ? "" : "no header and ", runs[k].rows.size());
      result = 1;
    }
  }
  return result;
}

// One run on a design made for it, its registers' random words from
// `seed`: 0 when it agrees, 1 when not.
int run_trace(const char *path, const Run &run, int seed) {
  const std::vector<std::vector<uint64_t>> &rows = run.rows;
  // A run before that stopped the simulation stopped it for itself alone.
  Verilated::gotFinish(false);
  Verilated::randSeed(seed);
  Top *dut = new Top;
  auto edge = [&]() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
  };
  dut->rst = 1;
  dut->clk = 0;
  dut->eval();
  if (!load(dut, run, path)) {
    dut->final();
    delete dut;
    return 1;
  }
  for (int k = 0; k < 4; ++k) edge();
  dut->rst = 0;
  dut->clk = 0;
  dut->eval();

  long bad = 0;
  size_t first_clock = 0;
  const char *first_column = nullptr;
  size_t commits = 0, operands = 0, grants = 0, landed = 0, registers = 0;
  for (size_t k = 0; k < rows.size(); ++k) {
    if (k > 0) edge();
    if (Verilated::gotFinish()) {
      std::fprintf(stderr, "clock %zu: the design stopped the simulation\n", k);
      if (bad == 0) {
        first_clock = k;
        first_column = "stop";
      }
      ++bad;
      break;
    }
    const std::vector<uint64_t> &want = rows[k];
    commits += (want[1 + kCommit] >> 15) & 1;
    operands += ((want[1 + kCommit] >> 15) & 1) && want[1 + kOpnd];
    grants += want[1 + kGrant] != 0;
    landed += want[1 + kMdl] != 0;
    registers += want[1 + kReg] != 0;
    const std::vector<uint64_t> row(want.begin() + 1, want.end());
    for (size_t c = 0; c < kN; ++c) {
      const Column &col = kColumns[c];
      if (!compared(col.when, row)) continue;
      const uint64_t got = col.get(dut);
      const bool agrees = col.when == kStage ? stage_agrees(got, row[c]) : got == row[c];
      if (agrees) continue;
      if (bad == 0) {
        first_clock = k;
        first_column = col.name;
      }
      if (++bad <= 20)
        std::fprintf(stderr, "clock %zu: %s is %" PRIx64 ", muir says %" PRIx64 "\n", k, col.name,
                     got, row[c]);
    }
  }
  dut->final();
  delete dut;
  if (bad) {
    std::fprintf(stderr,
                 "FAIL: %ld differences over %zu clocks of %s%s%s (QUUX15_SEED %d); the first at clock %zu, %s\n",
                 bad, rows.size(), path, run.name.empty() ? "" : " run ", run.name.c_str(), seed,
                 first_clock, first_column);
    return 1;
  }
  totals.clocks += rows.size();
  totals.commits += commits;
  totals.operands += operands;
  totals.grants += grants;
  totals.landed += landed;
  totals.registers += registers;
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *seed_s = std::getenv("QUUX15_SEED");
  const int seed = seed_s ? std::atoi(seed_s) : 1;
  Verilated::randReset(2);
  std::vector<const char *> paths;
  for (int i = 1; i < argc; ++i)
    if (argv[i][0] != '+') paths.push_back(argv[i]);
  if (paths.empty()) {
    std::fprintf(stderr, "usage: %s <trace>... [+plusargs]\n", argv[0]);
    return 2;
  }
  int result = 0;
  for (const char *path : paths) {
    std::vector<Run> runs;
    const int r = read_trace(path, runs);
    if (r) return r;
    totals = Totals{};
    bool bad = false;
    // Each run's random words from a seed of its own, so that a run that
    // fails fails alone too.
    for (size_t k = 0; k < runs.size(); ++k)
      if (run_trace(path, runs[k], seed + static_cast<int>(k))) bad = true;
    if (bad) {
      result = 1;
      continue;
    }
    std::printf("ok: %zu clocks of %s%s agree with muir's pipeline: %zu commits, %zu ALU and BYTE "
                "words' operands, %zu grants, %zu words landed in MD, %zu registers taken\n",
                totals.clocks, path,
                runs.size() > 1 ? (" in " + std::to_string(runs.size()) + " runs").c_str() : "",
                totals.commits, totals.operands, totals.grants, totals.landed, totals.registers);
  }
  return result;
}
