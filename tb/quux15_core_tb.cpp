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
// doorbell is held to the clocks the producer moved at, and **THIS
// TESTBENCH IS THE HOST'S SERVER** on the core's host side, as Linux's
// `quux-file-device` drives it through `quux_fd_face.sv`, so that each of
// muir's completions lands at muir's clock k: STATE read for the epoch at
// k - 4, the claim taken at k - 3 and RESP_PROD read, HANDLES staged at
// k - 2, RESP_PROD written at k - 1, the host's words into main memory at
// k, before anything reads them, and the claim let go at k + 1, with the
// completion's acceptance read back from STATE.
//
// **A RUN WITH THE KEYBOARD AND THE MOUSE** (`golden/src/quux15_input.rs`):
// `# key <clock> <word>` is a key word muir's `QuuxInput` took before that
// clock, which this testbench puts on the core's cable (`kbd_strobe`) in the
// clock before it, as `cadr_input_cables.sv` would; `# mouse <clock> <x> <y>
// <buttons>` is the mouse's counts and buttons as muir's took them before
// that clock, a step of each count at most, which this testbench makes the
// face's way in the clock before it: each count's phase a step up or down,
// in `Encoders::levels`' Gray order, the switches low when pressed, on the
// core's seven lines (`mouse_lines`), which stay as they are after.
//
// **A RUN WITH THE NETWORK** (`golden/src/quux15_network.rs`): this
// testbench is the far end on the core's Chaosnet cable seam
// (`quux15_chaos.sv`), as muir's interface saw its cable, each `<clock>`
// being the first row whose registers have it: `# chaos-address <a>` the
// switches; `# chaos-rx <clock> <bits> <crc> <n> <words>` a frame, its words
// on `chaos_rx_word` a clock each in the `n` clocks before the clock before
// `<clock>`, and `chaos_rx_done` in that clock; `# chaos-lost <clock>`
// `chaos_rx_lost`, and `# chaos-txdone <clock> <abort>` `chaos_tx_done`, in
// the clock before; `# chaos-busy <clock> <level>` `chaos_cbl_busy` from
// that clock on.  `# chaos-tx <clock> <n> <words>` is a START muir took at
// that clock: the core's `chaos_tx_go` must be up in that row with `n`, and
// its words come out on `chaos_tx_valid` in the rows after, in order; every
// frame the core sends must be one of these.
//
// **A RUN THAT ENDS IN A CHECKPOINT** (`# checkpoint <clock> <file> <rtc start>
// <rtc base> <read> <write> <occupancy> <cache>`, the checkpoints group):
// halted, the devices' snapshot is taken at that clock's edge, and after it
// the whole machine is read through the core's readout (`rm_*`) by the
// board's own reader (`cadr-readout`'s `ro_read_quux15`, its face modeled
// here: a word of the window is the core's three clocks after its address)
// and written by the board's own writer (`chk_rtl.c`), main memory and the
// frame buffer being this testbench's; the file must be muir's, `<file>`,
// byte for byte.  The fabric's is kept beside it as `<file>.fabric` when it
// is not and `QUUX15_KEEP_FABRIC` is set, for a field-by-field look.  The
// model takes no snapshot of its own when the reader asks: the clock muir's
// file is of has taken it.  A run that ends in `# checkpoint-refused <clock>
// <why>` is one muir refuses to write, a file device's handle open or command
// queued: the board's writer must refuse it too (`chk_rtl_refusal`).
//
// **A RUN WITH A PACK** (`# pack <blocks> <latency>`; `golden/src/
// quux15_blockdisk.rs`): block-disk's unit 0 holds a pack of that many
// blocks, each word `pack_word(block, word)` at first, and this testbench is
// its pack side, as `tb/quux13_block_disk_tb.cpp`'s is: a block the walk asks
// for is in a slot of the store `latency` clocks later, a dirty slot written
// back first, a block past the pack denied.  **WHILE THE TRANSFER IS IN
// FLIGHT** (the core's `obs_transfer`, its walk running or its words on the
// port) the `queue` and `inflight` columns are not compared: muir moves the
// words at START, landing the queue there, and its port never holds them
// (A15b.5); the processor using the port inside that window
// is the run's own fault, and fails it.  Each page `# endpage <first word>
// <hash>` names is held to muir's at the end, five bytes a word, and each
// block `# endblock <block> <hash>`, the store's dirty slots written back
// first.  **A RUN JUDGED BY ITS RESULTS** (`# results-only <park> <clocks>`)
// carries no row: the core runs until it has committed its park and is
// quiet, and the pages and blocks are held to muir's; `# read-at-ar`, its
// memory answers a read with the words as they stood when the read's
// address was taken.
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
#include <map>
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
#include <fstream>
#include <functional>
#include <unistd.h>
#include <iterator>
// The board's C headers, whose compile-time checks are C11's.
#define _Static_assert static_assert
extern "C" {
#include "chk_rtl.h"
#include "readout.h"
}
#undef _Static_assert
#endif

namespace {

using Top = QUUX15_TOP;

// What a trace's runs held, summed for its line.
struct Totals {
  size_t clocks = 0, commits = 0, operands = 0, grants = 0, landed = 0, registers = 0;
  // Block-disk's: clocks of runs judged by their results, rows inside a
  // transfer's window, pages and blocks held at the end, and the pack
  // side's blocks served, written back and denied.
  size_t results_clocks = 0, windowed = 0, pages = 0, blocks = 0;
  long served = 0, written_back = 0, denied = 0;
} totals;

// Main memory's words: QUUX's 32 boards, 2M words, five bytes each, or the
// build's `QUUX15_MAIN_UNITS` of 64K words, as the core's `MAIN_WORDS` is
// built (the Kria's 512, 32M: `quux15_mainsize.quux.pass`); the frame
// buffer's, four bytes each from the master's `DISPLAY_BASE`.
#ifndef QUUX15_MAIN_UNITS
#define QUUX15_MAIN_UNITS 32
#endif
constexpr uint64_t kMainWords = uint64_t(QUUX15_MAIN_UNITS) << 16;
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
constexpr size_t kCommit = 4, kOpnd = 13, kGrant = 19, kMdl = 21, kReg = 23, kQueue = 25;

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
  // Main memory's 64K-word units, as the trace's machine has them: 32
  // unless its `# main-units` line says otherwise.
  uint64_t main_units = 32;
  // Block-disk's pack: its blocks and the pack side's latency; the pages
  // and blocks held to muir's at the end; a run judged by them alone, where
  // it parks and the clocks muir took; reads answered as their address
  // found memory.
  bool pack = false, read_at_ar = false, results_only = false;
  uint64_t pack_blocks = 0, pack_latency = 0, park = 0, muir_clocks = 0;
  std::vector<std::pair<uint64_t, uint64_t>> end_pages, end_blocks;
  // The file device's host: the doorbells, by clock, and the completions,
  // by clock, each its handles open and the words written.
  std::vector<std::pair<uint64_t, uint64_t>> fd_prod;
  struct FdDone {
    uint64_t clock, handles;
    std::vector<std::pair<uint64_t, uint64_t>> words;
  };
  std::vector<FdDone> fd_done;
  // The console (`golden/src/quux15_console.rs`): a diagnostic register
  // written before a clock, one read as a clock ends, and the halted
  // pipeline's state as a clock ends, the end of muir's checkpoint in hex.
  struct Spy {
    uint64_t clock, eadr, word;
  };
  std::vector<Spy> spy_writes, spy_reads;
  std::vector<std::pair<uint64_t, std::string>> halted;
  // The keyboard's words and the mouse's counts, by the clock muir took them
  // before (`golden/src/quux15_input.rs`).
  std::vector<std::pair<uint64_t, uint64_t>> keys;
  struct Mouse {
    uint64_t clock, x, y, buttons;
  };
  std::vector<Mouse> mice;
  // The network's far end (`golden/src/quux15_network.rs`).
  uint64_t chaos_address = 0;
  struct ChaosRx {
    uint64_t clock, bits, crc;
    std::vector<uint64_t> words;
  };
  std::vector<ChaosRx> chaos_rx;
  std::vector<uint64_t> chaos_lost;
  std::vector<std::pair<uint64_t, uint64_t>> chaos_txdone, chaos_busy;
  struct ChaosTx {
    uint64_t clock;
    std::vector<uint64_t> words;
  };
  std::vector<ChaosTx> chaos_tx;
  // The checkpoint the run ends in, if it does: its clock, muir's file and
  // what the fabric's declares.
  struct Ckpt {
    bool on = false, refused = false;
    uint64_t clock = 0, rtc_start = 0, rtc_base = 0, read = 0, write = 0, occupancy = 0, cache = 0;
    std::string file;
  } ckpt;
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
    else if (i.memory == "mdmem" && i.address < 1024)
      // The MACRO DISPATCH MEMORY's entries, eighteen bits.
      r->quux15_core__DOT__mdmem[i.address] = static_cast<uint32_t>(i.word & 0x3ffff);
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
      if (w.size() == 4 && (w[0] == "spy" || w[0] == "read")) {
        Run::Spy e{std::strtoull(w[1].c_str(), nullptr, 16), std::strtoull(w[2].c_str(), nullptr, 16),
                   std::strtoull(w[3].c_str(), nullptr, 16)};
        (w[0] == "spy" ? runs.back().spy_writes : runs.back().spy_reads).push_back(e);
        continue;
      }
      if (w.size() == 9 && w[0] == "checkpoint") {
        Run::Ckpt &c = runs.back().ckpt;
        c.on = true;
        c.clock = std::strtoull(w[1].c_str(), nullptr, 16);
        c.file = w[2];
        c.rtc_start = std::strtoull(w[3].c_str(), nullptr, 16);
        c.rtc_base = std::strtoull(w[4].c_str(), nullptr, 16);
        c.read = std::strtoull(w[5].c_str(), nullptr, 10);
        c.write = std::strtoull(w[6].c_str(), nullptr, 10);
        c.occupancy = std::strtoull(w[7].c_str(), nullptr, 10);
        c.cache = std::strtoull(w[8].c_str(), nullptr, 10);
        continue;
      }
      if (w.size() == 3 && w[0] == "checkpoint-refused") {
        Run::Ckpt &c = runs.back().ckpt;
        c.on = true;
        c.refused = true;
        c.clock = std::strtoull(w[1].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 3 && w[0] == "key") {
        runs.back().keys.emplace_back(std::strtoull(w[1].c_str(), nullptr, 16),
                                      std::strtoull(w[2].c_str(), nullptr, 16));
        continue;
      }
      if (w.size() == 5 && w[0] == "mouse") {
        runs.back().mice.push_back({std::strtoull(w[1].c_str(), nullptr, 16),
                                    std::strtoull(w[2].c_str(), nullptr, 16),
                                    std::strtoull(w[3].c_str(), nullptr, 16),
                                    std::strtoull(w[4].c_str(), nullptr, 16)});
        continue;
      }
      if (w.size() == 2 && w[0] == "chaos-address") {
        runs.back().chaos_address = std::strtoull(w[1].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() >= 5 && w[0] == "chaos-rx") {
        Run::ChaosRx f{std::strtoull(w[1].c_str(), nullptr, 16), std::strtoull(w[2].c_str(), nullptr, 16),
                       std::strtoull(w[3].c_str(), nullptr, 16), {}};
        const size_t n = std::strtoull(w[4].c_str(), nullptr, 16);
        for (size_t k = 5; k < w.size(); ++k) f.words.push_back(std::strtoull(w[k].c_str(), nullptr, 16));
        if (f.words.size() != n) {
          std::fprintf(stderr, "%s: a chaos-rx line with %zu words where it says %zu\n", path, f.words.size(), n);
          result = 2;
          break;
        }
        runs.back().chaos_rx.push_back(f);
        continue;
      }
      if (w.size() == 2 && w[0] == "chaos-lost") {
        runs.back().chaos_lost.push_back(std::strtoull(w[1].c_str(), nullptr, 16));
        continue;
      }
      if (w.size() == 3 && (w[0] == "chaos-txdone" || w[0] == "chaos-busy")) {
        (w[0] == "chaos-busy" ? runs.back().chaos_busy : runs.back().chaos_txdone)
            .emplace_back(std::strtoull(w[1].c_str(), nullptr, 16), std::strtoull(w[2].c_str(), nullptr, 16));
        continue;
      }
      if (w.size() >= 3 && w[0] == "chaos-tx") {
        Run::ChaosTx f{std::strtoull(w[1].c_str(), nullptr, 16), {}};
        const size_t n = std::strtoull(w[2].c_str(), nullptr, 16);
        for (size_t k = 3; k < w.size(); ++k) f.words.push_back(std::strtoull(w[k].c_str(), nullptr, 16));
        if (f.words.size() != n) {
          std::fprintf(stderr, "%s: a chaos-tx line with %zu words where it says %zu\n", path, f.words.size(), n);
          result = 2;
          break;
        }
        runs.back().chaos_tx.push_back(f);
        continue;
      }
      if (w.size() == 3 && w[0] == "halted") {
        runs.back().halted.emplace_back(std::strtoull(w[1].c_str(), nullptr, 16), w[2]);
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
      if (w.size() == 2 && w[0] == "main-units") {
        runs.back().main_units = std::strtoull(w[1].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 3 && w[0] == "pack") {
        runs.back().pack = true;
        runs.back().pack_blocks = std::strtoull(w[1].c_str(), nullptr, 16);
        runs.back().pack_latency = std::strtoull(w[2].c_str(), nullptr, 16);
        continue;
      }
      if (w.size() == 1 && w[0] == "read-at-ar") {
        runs.back().read_at_ar = true;
        continue;
      }
      if (w.size() == 3 && (w[0] == "endpage" || w[0] == "endblock")) {
        (w[0] == "endpage" ? runs.back().end_pages : runs.back().end_blocks)
            .emplace_back(std::strtoull(w[1].c_str(), nullptr, 16), std::strtoull(w[2].c_str(), nullptr, 16));
        continue;
      }
      if (w.size() == 3 && w[0] == "results-only") {
        runs.back().results_only = true;
        runs.back().park = std::strtoull(w[1].c_str(), nullptr, 16);
        runs.back().muir_clocks = std::strtoull(w[2].c_str(), nullptr, 16);
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
    if (!header || (runs[k].rows.size() < 2 && !runs[k].results_only)) {
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
    // The host makes a completion over the five clocks before it.
    for (size_t k = 0; k < run.fd_done.size(); ++k)
      if (run.fd_done[k].clock < 5 || (k > 0 && run.fd_done[k].clock < run.fd_done[k - 1].clock + 6))
        host_why_ = "a completion at clock " + std::to_string(run.fd_done[k].clock) +
                    ", too soon for the host to make it";
  }

  void image(uint64_t addr, uint64_t word) {
    for (int b = 0; b < 5; ++b) mem_[addr * 5 + b] = static_cast<uint8_t>(word >> (8 * b));
  }

  // Main memory's bytes, packed storage, and the frame buffer's.
  const std::vector<uint8_t> &main_bytes() const { return mem_; }
  const std::vector<uint8_t> &fb_bytes() const { return fb_; }

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

  // The host's write of index `idx` in this clock: one a clock, as the
  // face gives them.
  void host_write(Top *d, unsigned idx, uint32_t v, uint64_t t) {
    if (d->host_we && host_why_.empty())
      host_why_ = "the testbench's host has two writes in clock " + std::to_string(t);
    d->host_we = 1;
    d->host_widx = idx & 0xFu;
    d->host_wdata = v;
  }

  void drive(Top *d, uint64_t t) {
    // The file device's host, the server (above): STATE read in every clock
    // but the one RESP_PROD's index is read in, a read's word the clock
    // after its index.
    enum : unsigned { kState = 2, kClaim = 3, kRespProd = 9, kHandles = 11 };
    const uint32_t seen = d->host_rdata;
    d->host_we = 0;
    d->host_widx = 0;
    d->host_wdata = 0;
    d->host_ridx = kState;
    for (const Run::FdDone &f : run_.fd_done) {
      if (t + 3 == f.clock) {
        host_epoch_ = seen >> 16;
        host_write(d, kClaim, host_epoch_ << 16 | 1u, t);
        d->host_ridx = kRespProd;
      }
      if (t + 2 == f.clock) {
        host_index_ = seen & 0xFFFFu;
        host_write(d, kHandles, host_epoch_ << 16 | (f.handles & 0xFFu), t);
      }
      if (t + 1 == f.clock)
        host_write(d, kRespProd, host_epoch_ << 16 | ((host_index_ + 1) & 0xFFFFu), t);
      // Its words into main memory before anything reads them.
      if (t == f.clock)
        for (const auto &w : f.words) image(w.first, w.second);
      // The claim let go, and the completion found accepted.
      if (t == f.clock + 1) {
        host_write(d, kClaim, 0, t);
        if ((seen & 0x20u) && host_why_.empty())
          host_why_ = "the file device refused the host's completion of clock " + std::to_string(f.clock);
      }
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
        for (int b = 0; b < 8; ++b) {
          // `# read-at-ar`: the words as the read's address found them.
          if (run_.read_at_ar) {
            v |= static_cast<uint64_t>(l.data[8 * l.sent + b]) << (8 * b);
            continue;
          }
          if (const uint8_t *at = byte(base + b)) v |= static_cast<uint64_t>(*at) << (8 * b);
        }
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
    if (!host_why_.empty()) {
      why = host_why_;
      return false;
    }
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
        l.data.assign(8 * l.total, 0);
        for (int b = 0; b < 8 * l.total; ++b)
          if (const uint8_t *at = byte(l.byte + b)) l.data[b] = *at;
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
    std::vector<uint8_t> data;   // the line as its address found it
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
  // The host's server: the epoch and RESP_PROD as it read them, and why it
  // could not do its part.
  uint32_t host_epoch_ = 0, host_index_ = 0;
  std::string host_why_;
  std::vector<uint8_t> mem_, fb_;
  std::vector<Line> lines_;
  std::vector<Write> writes_;
  uint64_t seed_ = 0, errors_ = 0, last_accept_ = 0, last_land_ = 0, cont_addr_ = 0;
  bool cont_ = false, accepted_any_ = false, bfirst_ = false;
  long bpick_ = -1;
};
#endif


#ifdef QUUX15_CORE
// **BLOCK-DISK'S PACK SIDE** (`# pack`), `tb/quux13_block_disk_tb.cpp`'s:
// the pack's blocks `pack_word(block, word)` at first and those written back
// since; a block the walk asks for is put in a slot `latency` clocks later,
// the tag written last, a dirty slot written back first through the seam's
// read port, two clocks behind its address; a block past the pack denied.
// The slot the walk is on is never taken.  `drive` sets the seam's inputs
// for a clock from the outputs as the last edge left them, and `after`
// reads what the edge did.
uint32_t pack_word(uint32_t lba, uint32_t w) {
  const uint32_t rot = (lba << 23) | (lba >> 9);
  return (lba << 12) ^ (w << 1) ^ 0x5a000001u ^ rot;
}

// FNV-1a over `n` bytes.
uint32_t fnv(const uint8_t *b, size_t n) {
  uint32_t h = 0x811c9dc5u;
  for (size_t i = 0; i < n; ++i) {
    h ^= b[i];
    h *= 0x01000193u;
  }
  return h;
}

class PackSide {
 public:
  static constexpr int kSlots = 24, kWords = 256;
  PackSide(uint64_t blocks, uint64_t latency) : blocks_(blocks), latency_(latency) {}

  std::vector<uint32_t> block(uint32_t lba) const {
    const auto it = written_.find(lba);
    if (it != written_.end()) return it->second;
    std::vector<uint32_t> b(kWords);
    for (int w = 0; w < kWords; ++w) b[w] = pack_word(lba, w);
    return b;
  }

  void drive(Top *d) {
    d->store_we = 0;
    d->store_deny = 0;
    d->store_busy = 0;
    switch (state_) {
      case IDLE:
        if (d->req_valid) {
          state_ = WAIT;
          t_ = 0;
          lba_ = d->req_tag;
          if (lba_ >= (1u << 28)) past_28_ = true;
          ++asked_;
        }
        break;
      case WAIT:
        if (!d->req_valid) {
          state_ = IDLE;
          break;
        }
        if (++t_ < latency_) break;
        if (lba_ >= blocks_) {
          d->store_deny = 1;
          ++denied_;
          state_ = IDLE;
          break;
        }
        slot_ = -1;
        for (int s = 0; s < kSlots && slot_ < 0; ++s)
          if (!valid_[s]) slot_ = s;
        while (slot_ < 0) {
          const int s = victim_++ % kSlots;
          if (!(d->ch_active && !d->ch_waiting && d->ch_slot == s)) slot_ = s;
        }
        k_ = 0;
        state_ = dirty_[slot_] ? BACK : FILL;
        words_ = block(lba_);
        break;
      case BACK:
        d->store_busy = 1;
        d->store_busy_slot = slot_;
        d->store_slot = slot_;
        d->store_addr = k_ < kWords ? k_ : 0;
        if (k_ >= 2) back_[k_ - 2] = d->store_rdata;
        if (++k_ == kWords + 2) {
          written_[tag_[slot_]] = back_;
          dirty_[slot_] = false;
          ++written_back_;
          if (lba_ == tag_[slot_]) words_ = back_;
          k_ = 0;
          state_ = FILL;
        }
        break;
      case FILL:
        d->store_busy = 1;
        d->store_busy_slot = slot_;
        d->store_we = 1;
        d->store_slot = slot_;
        if (k_ == 0) {
          d->store_addr = 259;
          d->store_wdata = 0x80000000u;
          valid_[slot_] = false;
        } else if (k_ <= kWords) {
          d->store_addr = k_ - 1;
          d->store_wdata = words_[k_ - 1];
        } else if (k_ <= kWords + 3) {
          d->store_addr = 256 + (k_ - kWords - 1);
          d->store_wdata = 0;
        } else {
          d->store_addr = 259;
          d->store_wdata = lba_;
          valid_[slot_] = true;
          tag_[slot_] = lba_;
          ++served_;
          state_ = IDLE;
        }
        ++k_;
        break;
    }
  }

  void after(const Top *d) {
    if (d->ch_wrote) dirty_[d->ch_slot] = true;
  }

  bool idle() const { return state_ == IDLE; }

  // The dirty slots written back through the seam, a clock a word.
  void write_back(Top *d, const std::function<void()> &edge) {
    for (int s = 0; s < kSlots; ++s) {
      if (!dirty_[s]) continue;
      std::vector<uint32_t> w(kWords);
      for (int k = 0; k < kWords + 2; ++k) {
        d->store_we = 0;
        d->store_slot = s;
        d->store_addr = k < kWords ? k : 0;
        if (k >= 2) w[k - 2] = d->store_rdata;
        edge();
      }
      written_[tag_[s]] = w;
      dirty_[s] = false;
      ++written_back_;
    }
  }

  long served_ = 0, written_back_ = 0, denied_ = 0, asked_ = 0;
  bool past_28_ = false;

 private:
  enum { IDLE, WAIT, BACK, FILL } state_ = IDLE;
  uint64_t blocks_, latency_;
  uint64_t t_ = 0;
  int slot_ = 0, k_ = 0, victim_ = 0;
  uint32_t lba_ = 0;
  uint32_t tag_[kSlots] = {};
  bool valid_[kSlots] = {}, dirty_[kSlots] = {};
  std::vector<uint32_t> words_, back_ = std::vector<uint32_t>(kWords);
  std::map<uint32_t, std::vector<uint32_t>> written_;
};
#endif

#ifdef QUUX15_CORE
// **The halted pipeline as muir's checkpoint writes it** (`save_15`'s fields
// after the machine, the period and the port), from the core's readout, in
// hexadecimal: what a checkpoint the fabric writes carries.
std::string halted_tail(Top *dut) {
  std::string out;
  auto put = [&](uint64_t v, int bytes) {
    char h[3];
    for (int k = 0; k < bytes; ++k) {
      std::snprintf(h, sizeof h, "%02x", static_cast<unsigned>((v >> (8 * k)) & 0xff));
      out += h;
    }
  };
  auto sel = [&](int k) {
    dut->ro_sel = k;
    dut->eval();
    return static_cast<uint64_t>(dut->ro_word);
  };
  put(sel(0), 2);                                   // npc
  const uint64_t na = sel(1);                       // npc_after
  put((na >> 14) & 1, 1);
  if ((na >> 14) & 1) put(na & 0x3fff, 2);
  const uint64_t nf = sel(2);
  put((nf >> 1) & 1, 1);                            // pre_nop_next
  put(nf & 1, 1);                                   // nop_next
  const uint64_t pp = sel(3);                       // pdl_pending
  put((pp >> 14) & 1, 1);
  if ((pp >> 14) & 1) {
    put(pp & 0x3fff, 2);
    put(sel(4), 5);
  }
  const uint64_t mo = sel(5);                       // md_old
  put(mo & 1, 1);
  if (mo & 1) put(sel(6), 5);
  const uint64_t dw = sel(7);                       // D's wait
  put(dw & 1, 1);                                   // d_wait
  put((dw >> 1) & 1, 1);                            // d_slot_pending
  put(sel(8), 8);                                   // oa_low
  put(sel(9), 8);                                   // oa_high
  put(0, 1);                                        // next_instr, between microcycles
  put(sel(10) & 1, 1);                              // next_instrd
  put(sel(11), 4);                                  // lvmo
  put(sel(12) & 1, 1);                              // wrcyc
  const uint64_t sw = sel(13);                      // spc_write
  put((sw >> 24) & 1, 1);
  if ((sw >> 24) & 1) {
    put((sw >> 19) & 0x1f, 1);
    put(sw & 0x7ffff, 4);
  }
  const uint64_t mw = sel(14);                      // map_write_d
  put(mw & 1, 1);
  if (mw & 1) {
    put(sel(15), 5);
    put(sel(16), 5);
  }
  put(8, 8);                                        // opc, eight
  const uint64_t o0 = sel(17), o1 = sel(18);
  for (int k = 0; k < 8; ++k) put(((k < 4 ? o0 : o1) >> (14 * (k % 4))) & 0x3fff, 2);
  const uint64_t h = sel(19);
  put((h >> 1) & 1, 1);                             // x.halted
  put(h & 1, 1);                                    // halted
  put(sel(20), 8);                                  // committed
  put(sel(21), 2);                                  // npc_prev
  return out;
}
#endif

#ifdef QUUX15_CORE
// **The console face as the board's reader drives it** (`quux15_face.sv`'s
// words 10 to 12): a write of word 10 puts the address on the core's readout
// and three clocks later the word is there; its read is the echo, 11 and 12
// the word's halves.
struct TbFace {
  Top *dut;
  std::function<void()> edge;
  uint32_t echo = 0x3FFFF;
  uint64_t data = 0;
};
uint32_t tb_face_read(struct readout *r, unsigned word) {
  TbFace *f = static_cast<TbFace *>(r->ctx);
  if (word == RO_ADDR) return f->echo;
  if (word == RO_DATA_LO) return static_cast<uint32_t>(f->data);
  if (word == RO_DATA_HI) return static_cast<uint32_t>(f->data >> 32);
  return RO_UNMAPPED;
}
void tb_face_write(struct readout *r, unsigned word, uint32_t v) {
  TbFace *f = static_cast<TbFace *>(r->ctx);
  if (word != RO_ADDR) return;
  f->dut->rm_sel = static_cast<uint8_t>((v >> 14) & 0xF);
  f->dut->rm_addr = static_cast<uint16_t>(v & 0x3FFF);
  for (int k = 0; k < 4; ++k) f->edge();
  f->data = f->dut->rm_word;
  f->echo = v;
}

std::vector<uint8_t> file_bytes(const std::string &path) {
  std::ifstream in(path, std::ios::binary);
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

// The run's checkpoint, the machine halted and its snapshot taken: the
// fabric's file against muir's.  Empty when they are the same bytes.
std::string checkpoint_check(Top *dut, const Run &run, const Bench &bench, const std::function<void()> &edge) {
  TbFace face{dut, edge};
  struct readout r;
  std::memset(&r, 0, sizeof r);
  r.read = tb_face_read;
  r.write = tb_face_write;
  r.ctx = &face;
  struct cadr_image img;
  if (img_alloc_video(&img, static_cast<unsigned>(kMainWords >> 16), 1, 15, 1280, 1024) != 0)
    return "the image could not be made";
  std::string why;
  if (ro_read_quux15(&r, &img) != 0) {
    img_free(&img);
    return "the readout's echo named another word";
  }
  if (run.ckpt.refused) {
    char refusal[256];
    const int refuses = chk_rtl_refusal(&img, refusal, sizeof refusal);
    img_free(&img);
    return refuses ? "" : "muir refuses this checkpoint, a file device's handle open or command "
                          "queued, and the board's writer does not";
  }
  img.main13 = bench.main_bytes().data();
  const std::vector<uint8_t> &fb = bench.fb_bytes();
  for (unsigned i = 0; i < img.tv_words && 4u * i + 3u < fb.size(); ++i)
    img.tv[i] = static_cast<uint32_t>(fb[4 * i]) | static_cast<uint32_t>(fb[4 * i + 1]) << 8 |
                static_cast<uint32_t>(fb[4 * i + 2]) << 16 | static_cast<uint32_t>(fb[4 * i + 3]) << 24;
  struct chk_declared d;
  std::memset(&d, 0, sizeof d);
  d.chaos_address = 0177001;
  d.rtc_counted = 1;
  d.rtc_start = static_cast<uint32_t>(run.ckpt.rtc_start);
  d.rtc_base = run.ckpt.rtc_base;
  d.timing[0] = run.ckpt.read;
  d.timing[1] = run.ckpt.write;
  d.timing[2] = run.ckpt.occupancy;
  d.cache_words = static_cast<uint32_t>(run.ckpt.cache);
  struct chk w;
  chk_init(&w);
  chk_rtl_body(&w, &img, &d);
  const std::string kept = run.ckpt.file + ".fabric";
  const std::string out = kept + "." + std::to_string(static_cast<long>(getpid()));
  if (chk_write_file(out.c_str(), "rtl", static_cast<uint32_t>(kMainWords >> 16), &w) != 0)
    why = "the fabric's file could not be written";
  chk_free(&w);
  img.main13 = nullptr;
  img_free(&img);
  if (!why.empty()) return why;
  const std::vector<uint8_t> a = file_bytes(out), b = file_bytes(run.ckpt.file);
  const bool keep = std::getenv("QUUX15_KEEP_FABRIC") != nullptr && a != b;
  if (keep)
    std::rename(out.c_str(), kept.c_str());
  else
    std::remove(out.c_str());
  if (b.empty()) return "muir's file " + run.ckpt.file + " is not there";
  if (a == b) return "";
  size_t k = 0;
  while (k < a.size() && k < b.size() && a[k] == b[k]) ++k;
  return "the fabric's checkpoint, " + std::to_string(a.size()) + " bytes, is not muir's, " +
         std::to_string(b.size()) + " bytes: they part at byte " + std::to_string(k) +
         (keep ? " (" + kept + ")" : "");
}
#endif

// One run on a design made for it, its registers' random words from
// `seed`: 0 when it agrees, 1 when not.
int run_trace(const char *path, const Run &run, int seed) {
  const std::vector<std::vector<uint64_t>> &rows = run.rows;
  // **A TRACE OF ANOTHER MAIN MEMORY IS REFUSED**: the core's address decode,
  // walk and file device are built for this testbench's size.
  if (run.main_units != (kMainWords >> 16)) {
    std::fprintf(stderr, "FAIL: %s run %s is of a machine with %llu units of main memory, and this testbench and its "
                 "core are built for %llu (QUUX15_MAIN_UNITS, MAIN_WORDS)\n", path, run.name.c_str(),
                 static_cast<unsigned long long>(run.main_units),
                 static_cast<unsigned long long>(kMainWords >> 16));
    return 1;
  }
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
  PackSide pack(run.pack_blocks, run.pack_latency);
  auto edge = [&]() {
    bench.drive(dut, clock);
    if (run.pack) pack.drive(dut);
    dut->clk = 0;
    dut->eval();
    if (!bench_bad && !bench.take(dut, clock, bench_why)) bench_bad = true;
    dut->clk = 1;
    dut->eval();
    if (run.pack) pack.after(dut);
  };
  auto quiet = [&]() {
    dut->host_we = 0; dut->host_widx = 0; dut->host_wdata = 0; dut->host_ridx = 2;
    dut->m_awready = 0; dut->m_wready = 0; dut->m_arready = 0;
    dut->m_bvalid = 0; dut->m_rvalid = 0; dut->m_bid = 0; dut->m_bresp = 0;
    dut->m_rdata = 0; dut->m_rresp = 0; dut->m_rlast = 0;
    dut->spy_we = 0; dut->spy_eadr = 0; dut->spy_wdata = 0; dut->spy_raddr = 0; dut->ro_sel = 0;
    dut->rm_en = 1; dut->rm_snap = 0; dut->rm_sel = 0; dut->rm_addr = 0;
    // Block-disk's pack side: a pack on unit 0 as the run has one.
    dut->drive_present = run.pack;
    dut->store_we = 0; dut->store_slot = 0; dut->store_addr = 0; dut->store_wdata = 0;
    dut->store_deny = 0; dut->store_busy = 0; dut->store_busy_slot = 0;
    // The keyboard's cable idle, the mouse at rest with nothing pressed:
    // both phases at 2, every line high.
    dut->kbd_strobe = 0; dut->kbd_code = 0; dut->mouse_lines = 0x7f;
    // The network's cable idle, at the run's switches.
    dut->chaos_address = static_cast<uint16_t>(run.chaos_address);
    dut->chaos_rx_valid = 0; dut->chaos_rx_word = 0; dut->chaos_rx_done = 0; dut->chaos_rx_bits = 0;
    dut->chaos_rx_crc = 0; dut->chaos_rx_lost = 0; dut->chaos_tx_done = 0; dut->chaos_tx_abort = 0;
    dut->chaos_cbl_busy = 0;
  };
  quiet();
  // **THE NETWORK'S FAR END, BY THE CLOCK IT DRIVES THE SEAM IN**: each
  // event in the clock before the row that first shows it, a frame's words
  // in the clocks before that.  Two things on one wire in one clock is the
  // trace's fault and fails the run.
  struct Seam {
    bool rx_valid = false, rx_done = false, lost = false, txdone = false;
    uint64_t rx_word = 0, rx_bits = 0, rx_crc = 0, abort = 0;
  };
  std::map<uint64_t, Seam> seam;
  std::string chaos_why;
  for (const Run::ChaosRx &f : run.chaos_rx) {
    const uint64_t n = f.words.size();
    if (f.clock < n + 2) {
      chaos_why = "a frame at clock " + std::to_string(f.clock) + " whose words would come before clock 1";
      break;
    }
    for (uint64_t j = 0; j < n; ++j) {
      Seam &c = seam[f.clock - 1 - n + j];
      if (c.rx_valid) chaos_why = "two frames' words in clock " + std::to_string(f.clock - 1 - n + j);
      c.rx_valid = true;
      c.rx_word = f.words[j];
    }
    Seam &c = seam[f.clock - 1];
    if (c.rx_done) chaos_why = "two frames at clock " + std::to_string(f.clock);
    c.rx_done = true;
    c.rx_bits = f.bits;
    c.rx_crc = f.crc;
  }
  for (uint64_t at : run.chaos_lost) {
    Seam &c = seam[at - 1];
    if (c.lost) chaos_why = "two frames lost at clock " + std::to_string(at);
    c.lost = true;
  }
  for (const auto &d : run.chaos_txdone) {
    Seam &c = seam[d.first - 1];
    if (c.txdone) chaos_why = "two Transmit Dones at clock " + std::to_string(d.first);
    c.txdone = true;
    c.abort = d.second;
  }
  size_t busy_next = 0;
  // What the core sent: the row of each START and the words that followed.
  std::vector<Run::ChaosTx> sent;
  std::vector<uint64_t> sent_len;
  if (!chaos_why.empty()) {
    std::fprintf(stderr, "%s: run %s: the network's far end: %s\n", path, run.name.c_str(), chaos_why.c_str());
    dut->final();
    delete dut;
    return 1;
  }
  // The face's mouse: each count's phase, from `Encoders::default`'s 2, and
  // the counts and buttons muir has.
  unsigned phase_x = 2, phase_y = 2;
  uint64_t mouse_x = 0, mouse_y = 0, mouse_b = 0;
  std::string input_why;
  auto cable = [](unsigned p) -> unsigned { return ((p >> 1) & 1) | ((((p >> 1) ^ p) & 1) << 1); };
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
  size_t commits = 0, operands = 0, grants = 0, landed = 0, registers = 0, windowed = 0;
  for (size_t k = 0; k < rows.size(); ++k) {
#ifdef QUUX15_CORE
    clock = k;
#endif
#ifdef QUUX15_CORE
    // The console's write for the clock after this edge's, and the
    // devices' snapshot at a checkpoint's clock's own edge, which takes the
    // instant and the timers as that clock has them.
    dut->spy_we = 0;
    dut->rm_snap = run.ckpt.on && run.ckpt.clock == k;
    for (const Run::Spy &w : run.spy_writes)
      if (w.clock == k + 1) {
        dut->spy_we = 1;
        dut->spy_eadr = static_cast<uint8_t>(w.eadr);
        dut->spy_wdata = static_cast<uint16_t>(w.word);
      }
    // The keyboard's word and the mouse's step for the clock after this
    // edge's, on the cable in this clock.
    dut->kbd_strobe = 0;
    for (const auto &key : run.keys)
      if (key.first == k + 1) {
        dut->kbd_strobe = 1;
        dut->kbd_code = static_cast<uint32_t>(key.second & 0xffffff);
      }
    for (const Run::Mouse &m : run.mice) {
      if (m.clock != k + 1) continue;
      const uint64_t dx = (m.x - mouse_x) & 0xfff, dy = (m.y - mouse_y) & 0xfff;
      if ((dx != 0 && dx != 1 && dx != 0xfff) || (dy != 0 && dy != 1 && dy != 0xfff))
        input_why = "a mouse move of more than a step a count at clock " + std::to_string(m.clock);
      phase_x = (phase_x + (dx == 1 ? 1u : dx == 0xfff ? 3u : 0u)) & 3;
      phase_y = (phase_y + (dy == 1 ? 1u : dy == 0xfff ? 3u : 0u)) & 3;
      mouse_x = m.x;
      mouse_y = m.y;
      mouse_b = m.buttons & 7;
      dut->mouse_lines = static_cast<uint8_t>(((~mouse_b & 7) << 4) | (cable(phase_y) << 2) | cable(phase_x));
    }
    // The network's far end in this clock.
    {
      const auto it = seam.find(k);
      const Seam c = it == seam.end() ? Seam{} : it->second;
      dut->chaos_rx_valid = c.rx_valid;
      dut->chaos_rx_word = static_cast<uint16_t>(c.rx_word);
      dut->chaos_rx_done = c.rx_done;
      dut->chaos_rx_bits = static_cast<uint16_t>(c.rx_bits);
      dut->chaos_rx_crc = c.rx_crc != 0;
      dut->chaos_rx_lost = c.lost;
      dut->chaos_tx_done = c.txdone;
      dut->chaos_tx_abort = c.abort != 0;
      while (busy_next < run.chaos_busy.size() && run.chaos_busy[busy_next].first <= k)
        dut->chaos_cbl_busy = run.chaos_busy[busy_next++].second != 0;
    }
    if (!input_why.empty()) {
      std::fprintf(stderr, "%s: run %s: %s\n", path, run.name.c_str(), input_why.c_str());
      if (bad == 0) {
        first_clock = k;
        first_column = "mouse";
      }
      ++bad;
      break;
    }
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
#ifdef QUUX15_CORE
    // What the core sends, as this clock ends.
    if (dut->chaos_tx_go) {
      sent.push_back({k, {}});
      sent_len.push_back(dut->chaos_tx_len);
    }
    if (dut->chaos_tx_valid) {
      if (sent.empty()) {
        if (bad == 0) {
          first_clock = k;
          first_column = "chaos";
        }
        if (++bad <= 20) std::fprintf(stderr, "clock %zu: a word on the network's cable with no START\n", k);
      } else {
        sent.back().words.push_back(dut->chaos_tx_word);
      }
    }
#endif
    const std::vector<uint64_t> &want = rows[k];
    commits += (want[1 + kCommit] >> 15) & 1;
    operands += ((want[1 + kCommit] >> 15) & 1) && want[1 + kOpnd];
    grants += want[1 + kGrant] != 0;
    landed += want[1 + kMdl] != 0;
    registers += want[1 + kReg] != 0;
    const std::vector<uint64_t> row(want.begin() + 1, want.end());
    // The transfer's window: the depths are muir's port's, which never
    // holds the transfer's words; and the processor keeps off the port.
    bool window = false;
#ifdef QUUX15_CORE
    window = dut->obs_transfer;
    windowed += window;
    if (window && row[kGrant] != 0 && !((row[kGrant + 1] >> 28) & 1)) {
      if (bad == 0) {
        first_clock = k;
        first_column = "window";
      }
      if (++bad <= 20)
        std::fprintf(stderr, "clock %zu: the run's processor uses the port at %" PRIx64
                     " while block-disk's transfer is in flight\n", k, row[kGrant + 1]);
    }
#endif
    for (size_t c = 0; c < kN; ++c) {
      const Column &col = kColumns[c];
      if (!compared(col.when, row)) continue;
      if (window && (c == kQueue || c == kQueue + 1)) continue;
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
#ifdef QUUX15_CORE
    // The console's reads and the halted state, as this clock ends.
    for (const Run::Spy &r : run.spy_reads) {
      if (r.clock != k) continue;
      dut->spy_raddr = static_cast<uint8_t>(r.eadr);
      dut->eval();
      if (dut->spy_rdata == r.word) continue;
      if (bad == 0) {
        first_clock = k;
        first_column = "spy";
      }
      if (++bad <= 20)
        std::fprintf(stderr, "clock %zu: spy register %" PRIu64 " reads %x, muir says %" PRIx64 "\n", k,
                     r.eadr, static_cast<unsigned>(dut->spy_rdata), r.word);
    }
    for (const auto &h : run.halted) {
      if (h.first != k) continue;
      const std::string got = halted_tail(dut);
      if (got == h.second) continue;
      if (bad == 0) {
        first_clock = k;
        first_column = "halted";
      }
      if (++bad <= 20)
        std::fprintf(stderr, "clock %zu: the halted state is %s, muir's checkpoint %s\n", k, got.c_str(),
                     h.second.c_str());
    }
    // **A HALT SENDS A REGISTER READ OUT** (A15b.13; the halt-release
    // clarification): a halted machine holds no interrupt level a read
    // lowered, at every clock it is halted (`quux15_input.sv`'s `held`).
    if (dut->obs_halted && dut->rootp->quux15_core__DOT__devices__DOT__input_regs__DOT__held != 0) {
      if (bad == 0) {
        first_clock = k;
        first_column = "held";
      }
      if (++bad <= 20)
        std::fprintf(stderr, "clock %zu: halted, the input holds the levels %x a read lowered\n", k,
                     static_cast<unsigned>(dut->rootp->quux15_core__DOT__devices__DOT__input_regs__DOT__held));
    }
#endif
  }
#ifdef QUUX15_CORE
  // **THE FRAMES THE CORE SENT**, against the STARTs muir took: each at its
  // row, with its length and its words, as far as the rows reach.
  {
    size_t want = 0;
    for (size_t j = 0; j < sent.size(); ++j) {
      const Run::ChaosTx *t = want < run.chaos_tx.size() ? &run.chaos_tx[want] : nullptr;
      std::string why;
      if (!t || t->clock != sent[j].clock)
        why = "a START at clock " + std::to_string(sent[j].clock) + " where muir took " +
              (t ? "one at clock " + std::to_string(t->clock) : std::string("none"));
      else if (sent_len[j] != t->words.size())
        why = "START at clock " + std::to_string(t->clock) + " sends " + std::to_string(sent_len[j]) +
              " words, muir's " + std::to_string(t->words.size());
      else
        for (size_t i = 0; i < sent[j].words.size() && why.empty(); ++i)
          if (i >= t->words.size() || sent[j].words[i] != t->words[i])
            why = "the frame of the START at clock " + std::to_string(t->clock) + ": word " + std::to_string(i) +
                  " is " + std::to_string(sent[j].words[i]) + ", muir's " +
                  (i < t->words.size() ? std::to_string(t->words[i]) : std::string("none"));
      if (why.empty() && sent[j].clock + t->words.size() < rows.size() && sent[j].words.size() != t->words.size())
        why = "the frame of the START at clock " + std::to_string(t->clock) + " came out with " +
              std::to_string(sent[j].words.size()) + " words";
      ++want;
      if (why.empty()) continue;
      if (bad == 0) {
        first_clock = sent[j].clock;
        first_column = "chaos";
      }
      if (++bad <= 20) std::fprintf(stderr, "the network: %s\n", why.c_str());
    }
    if (want < run.chaos_tx.size() && run.chaos_tx[want].clock < rows.size()) {
      if (bad == 0) {
        first_clock = run.chaos_tx[want].clock;
        first_column = "chaos";
      }
      if (++bad <= 20)
        std::fprintf(stderr, "the network: muir's START at clock %" PRIu64 " sent nothing from the core\n",
                     run.chaos_tx[want].clock);
    }
  }
  // **A RUN JUDGED BY ITS RESULTS**: the core runs until it has committed
  // its park and stays quiet 64 clocks, its transfer done and no write of
  // its own unanswered, in at most eight times muir's clocks.
  size_t results_clocks = 0;
  if (run.results_only && bad == 0) {
    const uint64_t limit = 8 * run.muir_clocks + 200000;
    long still = -1;
    uint64_t k = 0;
    for (; k < limit; ++k) {
      clock = k;
      if (k > 0) edge();
      if (bench_bad || Verilated::gotFinish()) {
        std::fprintf(stderr, "clock %" PRIu64 ": %s\n", k,
                     bench_bad ? ("the responder: " + bench_why).c_str() : "the design stopped the simulation");
        first_clock = k;
        first_column = bench_bad ? "axi" : "stop";
        ++bad;
        break;
      }
      const uint64_t c = dut->obs_commit;
      if (still < 0 && ((c >> 15) & 1) && !((c >> 14) & 1) && (c & 0x3fff) == run.park) still = 0;
      if (still >= 0) {
        still = (!dut->obs_transfer && dut->obs_queue == 0 && dut->obs_inflight == 0) ? still + 1 : 0;
        if (still >= 64) break;
      }
    }
    results_clocks = k;
    if (bad == 0 && k == limit) {
      std::fprintf(stderr, "the core has not parked at %" PRIo64 " and gone quiet in %" PRIu64
                   " clocks, muir's %" PRIu64 "\n", run.park, limit, run.muir_clocks);
      first_clock = k;
      first_column = "park";
      ++bad;
    }
  }
  // **THE END**: each page named held to muir's, five bytes a word, and
  // each block, the store's dirty slots written back first.
  if (bad == 0 && (!run.end_pages.empty() || !run.end_blocks.empty())) {
    if (run.pack) {
      for (int k = 0; k < 4096 && !pack.idle(); ++k) edge();
      pack.write_back(dut, edge);
    }
    for (const auto &p : run.end_pages) {
      const uint32_t h = fnv(bench.main_bytes().data() + 5 * p.first, 5 * 1024);
      if (h == p.second) continue;
      std::fprintf(stderr, "at the end: main memory's page %" PRIo64 " hashes to %x, muir's to %" PRIx64 "\n",
                   p.first, h, p.second);
      if (bad == 0) first_column = "page";
      ++bad;
    }
    for (const auto &b : run.end_blocks) {
      const std::vector<uint32_t> w = pack.block(static_cast<uint32_t>(b.first));
      std::vector<uint8_t> bytes;
      for (uint32_t x : w)
        for (int i = 0; i < 4; ++i) bytes.push_back(static_cast<uint8_t>(x >> (8 * i)));
      const uint32_t h = fnv(bytes.data(), bytes.size());
      if (h == b.second) continue;
      std::fprintf(stderr, "at the end: the pack's block %" PRIu64 " hashes to %x, muir's to %" PRIx64 "\n",
                   b.first, h, b.second);
      if (bad == 0) first_column = "block";
      ++bad;
    }
    if (bad) first_clock = rows.size();
  }
  if (run.pack && pack.past_28_) {
    std::fprintf(stderr, "the pack side was asked for a block at 2^28 or past it\n");
    if (bad == 0) first_column = "pack";
    ++bad;
  }
  // A run that ends in a checkpoint: the machine read and written as a
  // board's program does, against muir's file.
  if (bad == 0 && run.ckpt.on) {
    dut->rm_snap = 0;
    const std::string why = checkpoint_check(dut, run, bench, edge);
    if (!why.empty()) {
      std::fprintf(stderr, "clock %" PRIu64 ": %s\n", run.ckpt.clock, why.c_str());
      first_clock = run.ckpt.clock;
      first_column = "checkpoint";
      ++bad;
    }
  }
#endif
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
#ifdef QUUX15_CORE
  totals.results_clocks += results_clocks;
  totals.windowed += windowed;
  totals.pages += run.end_pages.size();
  totals.blocks += run.end_blocks.size();
  totals.served += pack.served_;
  totals.written_back += pack.written_back_;
  totals.denied += pack.denied_;
#endif
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
    if (totals.pages || totals.blocks || totals.served)
      std::printf("    block-disk: %zu rows in a transfer's window, %zu clocks of runs judged by their "
                  "results; %zu pages and %zu blocks equal to muir's at the end; the pack side served "
                  "%ld blocks, wrote %ld back, denied %ld\n",
                  totals.windowed, totals.results_clocks, totals.pages, totals.blocks, totals.served,
                  totals.written_back, totals.denied);
  }
  return result;
}
