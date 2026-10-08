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
// **MAIN MEMORY IS THE TESTBENCH'S** (`QUUX15_CORE`'s build): five bytes a
// word from byte 5w, its run's `# image main` words before reset ends, on the
// core's 64-bit AXI master port (`rtl/plumbing/quux15_axi_master.sv`).  The
// responder answers as muir's `PortTiming` at the trace's period does, by
// the run's `# port <read> <write> <occupancy>` line, in clocks, the
// master's declared constants less (A15b.5, `axi_read_clocks` and
// `axi_write_clocks`): a line's last beat `read` clocks after its first
// address less the read's constant, so that the fill lands `read` clocks
// after it is issued; a write's B its constant before the clock the write
// lands at, `write` clocks after its accept, plus the lateness muir's
// `LateModel` draws for it
// (`# late <seed> <most> <errors>`), draw for draw in accept order, the
// first `errors` writes answered with an error; and a new write's address
// and first beat taken `occupancy` clocks after the last.  muir answers the
// writes in order, one a clock, a write drawn earlier than the one before
// it answered the clock after that one (A15b.5, one ID for every write).
// With the core's `ONE_WRITE_ID` clear, each write has its own ID, and a
// write whose landing an earlier one decides is answered before that one,
// earliest deadline first.  A run
// with `# sweep skipped` has -RESET's sweep of the TLB taken as done, as
// muir's `Pipeline::skip_sweep` takes it.  Its `# period` and `# rtc` lines
// are the board's period in units of 0.5 ns and the real-time clock's
// seconds at power-on, given to the core as its top and its host give them.
// Its `# fdprod` and `# fddone` lines are the file device's host as muir's
// `FileDevice` played it (`golden/src/quux15.rs`'s `FileHost`): the fabric's
// doorbell is held to the clocks the producer moved at, and at each
// completion's clock the host's words go into main memory and the fabric is
// told.
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

// Main memory's words: QUUX's 32 boards, 2M words, five bytes each; the
// frame buffer's, four bytes each from the master's `DISPLAY_BASE`.
constexpr uint64_t kMainWords = 32u << 16;
constexpr uint64_t kFbWords = 40960;
constexpr uint64_t kDisplayBase = 0x0A000000;

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
  // The port's clocks at the trace's period, the seeded model, the sweep.
  uint64_t read = 0, write = 0, occupancy = 1;
  bool late = false;
  uint64_t late_seed = 0, late_most = 0, late_errors = 0;
  bool skip_sweep = false;
  // The period in units of 0.5 ns and the real-time clock's start.
  uint64_t period = 20, rtc = 0;
  // The file device's host: the doorbells, by clock, and the completions,
  // by clock, each its handles open and the words written.
  std::vector<std::pair<uint64_t, uint64_t>> fd_prod;
  struct FdDone {
    uint64_t clock, handles;
    std::vector<std::pair<uint64_t, uint64_t>> words;
  };
  std::vector<FdDone> fd_done;
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
      // The store keeps `<47:0>` inverted (`quux15_store.sv`).
      r->quux15_core__DOT__store__DOT__ram__DOT__mem[i.address] = i.word ^ 0x0000ffffffffffffull;
    else if (i.memory == "amem" && i.address < 1024)
      r->quux15_core__DOT__amem__DOT__mem[i.address] = i.word & 0xffffffffffull;
    else if (i.memory == "mmem" && i.address < 32)
      r->quux15_core__DOT__mmem[i.address] = i.word & 0xffffffffffull;
    else if (i.memory == "dmem" && i.address < 4096 && i.address % 2 == 0)
      // Dispatch memory's halves, its even entries and its odd.
      r->quux15_core__DOT__dmem_even[i.address / 2] = static_cast<uint32_t>(i.word & 0x1ffff);
    else if (i.memory == "dmem" && i.address < 4096)
      r->quux15_core__DOT__dmem_odd[i.address / 2] = static_cast<uint32_t>(i.word & 0x1ffff);
    else if (i.memory == "pdl" && i.address < 16384)
      r->quux15_core__DOT__pdl__DOT__mem[i.address] = i.word & 0xffffffffffull;
    else if (i.memory == "main" && i.address < kMainWords)
      ;  // the testbench's own, `Bench::image`
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
      if (w.size() == 3 && w[0] == "fdprod") {
        runs.back().fd_prod.emplace_back(std::strtoull(w[1].c_str(), nullptr, 16),
                                          std::strtoull(w[2].c_str(), nullptr, 16));
        continue;
      }
      if (w.size() >= 3 && w[0] == "fddone" && w.size() % 2 == 1) {
        Run::FdDone d;
        d.clock = std::strtoull(w[1].c_str(), nullptr, 16);
        d.handles = std::strtoull(w[2].c_str(), nullptr, 16);
        for (size_t k = 3; k + 1 < w.size(); k += 2)
          d.words.emplace_back(std::strtoull(w[k].c_str(), nullptr, 16),
                               std::strtoull(w[k + 1].c_str(), nullptr, 16));
        runs.back().fd_done.push_back(d);
        continue;
      }
      if (w.size() == 2 && w[0] == "period") {
        runs.back().period = std::strtoull(w[1].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 2 && w[0] == "rtc") {
        runs.back().rtc = std::strtoull(w[1].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 4 && w[0] == "port") {
        runs.back().read = std::strtoull(w[1].c_str(), nullptr, 16);
        runs.back().write = std::strtoull(w[2].c_str(), nullptr, 16);
        runs.back().occupancy = std::strtoull(w[3].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 4 && w[0] == "late") {
        runs.back().late = true;
        runs.back().late_seed = std::strtoull(w[1].c_str(), nullptr, 16);
        runs.back().late_most = std::strtoull(w[2].c_str(), nullptr, 16);
        runs.back().late_errors = std::strtoull(w[3].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 2 && w[0] == "sweep" && w[1] == "skipped") {
        runs.back().skip_sweep = true;
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

#ifdef QUUX15_CORE

// **THE RESPONDER** on the core's AXI port: main memory, and muir's port's
// timing and seeded model.  `drive` sets its inputs for clock `t`, `take`
// reads what the core did in that clock before its edge.
class Bench {
 public:
  explicit Bench(const Run &run) : run_(run), mem_(kMainWords * 5, 0), fb_(kFbWords * 4, 0) {
    seed_ = run.late_seed;
    errors_ = run.late_errors;
  }

  void image(uint64_t addr, uint64_t word) {
    for (int b = 0; b < 5; ++b) mem_[addr * 5 + b] = static_cast<uint8_t>(word >> (8 * b));
  }

  // muir's `LateModel::next`: xorshift64*, 1 to `most` clocks.
  uint64_t late() {
    if (!run_.late) return 0;
    uint64_t x = seed_ ? seed_ : 1;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    seed_ = x;
    const uint64_t most = run_.late_most ? run_.late_most : 1;
    return ((x * 0x2545f4914f6cdd1dull) >> 33) % most + 1;
  }

  void drive(Top *d, uint64_t t) {
    // The file device's host: a completion at this clock, its words into
    // main memory before anything reads them.
    d->fd_done = 0;
    for (const Run::FdDone &f : run_.fd_done)
      if (f.clock == t) {
        for (const auto &w : f.words) image(w.first, w.second);
        d->fd_done = 1;
        d->fd_handles = static_cast<uint8_t>(f.handles);
      }
    // Writes land in main memory at the clock muir lands them.
    for (Write &w : writes_)
      if (!w.applied && w.land == t) {
        for (const auto &b : w.bytes)
          if (uint8_t *at = byte(b.first)) *at = b.second;
        w.applied = true;
      }
    // A new write's address and first beat taken `occupancy` clocks after
    // the last; a write's second beat or second address at once.
    const bool ready = cont_ || t >= last_accept_ + run_.occupancy || !accepted_any_;
    d->m_awready = ready;
    d->m_wready = ready;
    d->m_arready = 1;
    // The line's beats, its last `read` clocks after its first address less
    // the master's constant.
    const uint64_t rc = d->axi_read_clocks, wc = d->axi_write_clocks;
    d->m_rvalid = 0;
    d->m_rlast = 0;
    d->m_rdata = 0;
    d->m_rresp = 0;
    if (!lines_.empty()) {
      Line &l = lines_.front();
      const uint64_t first = l.ar + run_.read - rc - (l.total - 1);
      if (t >= first && l.sent < l.total && t == first + l.sent) {
        uint64_t v = 0;
        const uint64_t base = l.byte + 8 * l.sent;
        for (int b = 0; b < 8; ++b)
          if (const uint8_t *at = byte(base + b)) v |= static_cast<uint64_t>(*at) << (8 * b);
        d->m_rvalid = 1;
        d->m_rdata = v;
        d->m_rlast = (l.sent == l.first_beats - 1) || l.sent == l.total - 1;
      }
    }
    // One B a clock: a write that must land at the next clock, or else the
    // one whose deadline comes first among those that may be answered early.
    d->m_bvalid = 0;
    d->m_bid = 0;
    d->m_bresp = 0;
    bpick_ = -1;
    bfirst_ = false;
    // **ONE ID** (the core's `ONE_WRITE_ID`, A15b.5): the responses in
    // order, the oldest write's, a split write's first B before its last,
    // each at its write's clock or the first after the one before.
    if (d->axi_one_write_id) {
      for (size_t k = 0; k < writes_.size(); ++k) {
        Write &w = writes_[k];
        if (w.b_done) continue;
        if (w.split && !w.b1) {
          if (t >= w.ready1) {
            bpick_ = static_cast<long>(k);
            bfirst_ = true;
          }
        } else if (t >= w.ready && t + wc >= w.land) {
          bpick_ = static_cast<long>(k);
        }
        break;
      }
      if (bpick_ >= 0) {
        Write &w = writes_[bpick_];
        d->m_bvalid = 1;
        d->m_bid = 0;
        d->m_bresp = (!bfirst_ && w.error) ? 2 : 0;
      }
      return;
    }
    for (size_t k = 0; k < writes_.size(); ++k) {
      Write &w = writes_[k];
      if (w.b_done) continue;
      if (w.split && !w.b1 && t >= w.ready1) {
        if (bpick_ < 0 || w.land < writes_[bpick_].land) {
          bpick_ = static_cast<long>(k);
          bfirst_ = true;
        }
        continue;
      }
      if (t < w.ready) continue;
      if (w.exact && w.land - wc == t) {
        bpick_ = static_cast<long>(k);
        bfirst_ = false;
        break;
      }
      if (!w.exact && (bpick_ < 0 || w.land < writes_[bpick_].land)) {
        bpick_ = static_cast<long>(k);
        bfirst_ = false;
      }
    }
    if (bpick_ >= 0) {
      Write &w = writes_[bpick_];
      if (!bfirst_ && w.exact && w.land - wc != t) {
        // An exact write is answered at its clock alone.
        bpick_ = -1;
      } else {
        d->m_bvalid = 1;
        d->m_bid = w.id;
        d->m_bresp = (!bfirst_ && w.error) ? 2 : 0;
      }
    }
  }

  // What the core did in clock `t`, its outputs before the edge; false when
  // the core broke the responder's rules.
  bool take(const Top *d, uint64_t t, std::string &why) {
    // The doorbell: the fabric's, at the clocks and values the host saw.
    bool want = false;
    uint64_t value = 0;
    for (const auto &p : run_.fd_prod)
      if (p.first == t) {
        want = true;
        value = p.second;
      }
    if (d->fd_doorbell != want || (want && d->fd_prod != value)) {
      char b[160];
      std::snprintf(b, sizeof b, "the file device's doorbell is %d (%" PRIx64 "), the host's %d (%" PRIx64 ")",
                    static_cast<int>(d->fd_doorbell), static_cast<uint64_t>(d->fd_prod),
                    static_cast<int>(want), value);
      why = b;
      return false;
    }
    if (d->m_arvalid && d->m_arready) {
      const uint64_t a = d->m_araddr;
      // A line's first address: main memory's at 40 bytes a line, the
      // frame buffer's at 32 (the second address of a split line is
      // neither).
      const bool win = a >= kDisplayBase;
      if (win ? a % 32 == 0 : a % 40 == 0) {
        Line l;
        l.ar = t;
        l.byte = a;
        l.total = win ? 4 : 5;
        l.first_beats = static_cast<int>(d->m_arlen) + 1;
        if (!lines_.empty()) {
          why = "a line read while another is answered";
          return false;
        }
        lines_.push_back(l);
      }
    }
    if (d->m_rvalid && d->m_rready && !lines_.empty()) {
      Line &l = lines_.front();
      if (++l.sent == l.total) lines_.erase(lines_.begin());
    }
    const bool aw = d->m_awvalid && d->m_awready, wb = d->m_wvalid && d->m_wready;
    if (cont_) {
      Write &w = writes_.back();
      if (wb) {
        put(w, cont_addr_, d->m_wdata, d->m_wstrb);
        cont_ = false;
        w.ready = t + 1;
      }
    } else if (aw && wb) {
      // A write accepted: its lateness drawn, its landing in muir's order.
      Write w;
      w.id = d->m_awid;
      w.accept = t;
      put(w, d->m_awaddr, d->m_wdata, d->m_wstrb);
      // Main memory's word is five bytes, in one beat or two; the frame
      // buffer's is four, in one.
      int strobes = __builtin_popcount(d->m_wstrb);
      const bool more = d->m_awaddr < kDisplayBase && strobes < 5;
      w.split = more && d->m_awlen == 0;
      cont_ = more;
      cont_addr_ = d->m_awaddr + 8;
      w.ready = t + 1;
      w.ready1 = t + 1;
      const uint64_t r = t + run_.write + late();
      w.error = errors_ > 0;
      if (errors_ > 0) --errors_;
      w.exact = r > last_land_;
      w.land = r > last_land_ ? r : last_land_ + 1;
      last_land_ = w.land;
      last_accept_ = t;
      accepted_any_ = true;
      writes_.push_back(w);
    } else if (aw != wb) {
      why = "a write's address and first beat taken apart";
      return false;
    }
    if (d->m_bvalid && d->m_bready && bpick_ >= 0) {
      Write &w = writes_[bpick_];
      if (bfirst_) w.b1 = true;
      else w.b_done = true;
    }
    // Every write answered by its deadline.
    const uint64_t wc = d->axi_write_clocks;
    for (const Write &w : writes_)
      if (!w.b_done && t + wc >= w.land) {
        why = "a write's B missed its clock";
        return false;
      }
    while (!writes_.empty() && writes_.front().b_done && writes_.front().applied) writes_.erase(writes_.begin());
    return true;
  }

 private:
  struct Line {
    uint64_t ar = 0, byte = 0;
    int first_beats = 5, sent = 0, total = 5;
  };
  // The byte at a port address: main memory's from 0, the frame buffer's
  // from `kDisplayBase` (the master's defaults); nothing elsewhere.
  uint8_t *byte(uint64_t a) {
    if (a < mem_.size()) return &mem_[a];
    if (a >= kDisplayBase && a - kDisplayBase < fb_.size()) return &fb_[a - kDisplayBase];
    return nullptr;
  }
  struct Write {
    uint32_t id = 0;
    uint64_t accept = 0, land = 0, ready = 0, ready1 = 0;
    bool exact = false, error = false, split = false, b1 = false, b_done = false, applied = false;
    std::vector<std::pair<uint64_t, uint8_t>> bytes;
  };
  static void put(Write &w, uint64_t addr, uint64_t data, uint32_t strb) {
    for (int b = 0; b < 8; ++b)
      if ((strb >> b) & 1) w.bytes.emplace_back(addr + b, static_cast<uint8_t>(data >> (8 * b)));
  }

  const Run &run_;
  std::vector<uint8_t> mem_, fb_;
  std::vector<Line> lines_;
  std::vector<Write> writes_;
  uint64_t seed_ = 0, errors_ = 0, last_accept_ = 0, last_land_ = 0, cont_addr_ = 0;
  bool cont_ = false, accepted_any_ = false, bfirst_ = false;
  long bpick_ = -1;
};
#endif

// One run on a design made for it, its registers' random words from
// `seed`: 0 when it agrees, 1 when not.
int run_trace(const char *path, const Run &run, int seed) {
  const std::vector<std::vector<uint64_t>> &rows = run.rows;
  // A run before that stopped the simulation stopped it for itself alone.
  Verilated::gotFinish(false);
  Verilated::randSeed(seed);
  Top *dut = new Top;
#ifdef QUUX15_CORE
  Bench bench(run);
  for (const Image &i : run.images)
    if (i.memory == "main" && i.address < kMainWords) bench.image(i.address, i.word);
  std::string bench_why;
  bool bench_bad = false;
  uint64_t clock = 0;
  auto edge = [&]() {
    bench.drive(dut, clock);
    dut->clk = 0;
    dut->eval();
    if (!bench_bad && !bench.take(dut, clock, bench_why)) bench_bad = true;
    dut->clk = 1;
    dut->eval();
  };
  auto quiet = [&]() {
    dut->fd_done = 0; dut->fd_handles = 0;
    dut->m_awready = 0; dut->m_wready = 0; dut->m_arready = 0;
    dut->m_bvalid = 0; dut->m_rvalid = 0; dut->m_bid = 0; dut->m_bresp = 0;
    dut->m_rdata = 0; dut->m_rresp = 0; dut->m_rlast = 0;
  };
  quiet();
#else
  auto edge = [&]() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
  };
#endif
  dut->rst = 1;
  dut->clk = 0;
#ifdef QUUX15_CORE
  // The board's period and the host's real-time clock, as its top gives
  // them.
  dut->period = static_cast<uint8_t>(run.period);
  dut->rtc_start = static_cast<uint32_t>(run.rtc);
#endif
  dut->eval();
  if (!load(dut, run, path)) {
    dut->final();
    delete dut;
    return 1;
  }
#ifdef QUUX15_CORE
  for (int k = 0; k < 4; ++k) {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
  }
#else
  for (int k = 0; k < 4; ++k) edge();
#endif
  dut->rst = 0;
  dut->clk = 0;
  dut->eval();
#ifdef QUUX15_CORE
  if (run.skip_sweep) {
    dut->rootp->quux15_core__DOT__mmu__DOT__sweep_left = 0;
    dut->eval();
  }
#endif

  long bad = 0;
  size_t first_clock = 0;
  const char *first_column = nullptr;
  size_t commits = 0, operands = 0, grants = 0, landed = 0, registers = 0;
  for (size_t k = 0; k < rows.size(); ++k) {
#ifdef QUUX15_CORE
    clock = k;
#endif
    if (k > 0) edge();
#ifdef QUUX15_CORE
    if (bench_bad) {
      std::fprintf(stderr, "clock %zu: the responder: %s\n", k, bench_why.c_str());
      if (bad == 0) {
        first_clock = k;
        first_column = "axi";
      }
      ++bad;
      break;
    }
#endif
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
