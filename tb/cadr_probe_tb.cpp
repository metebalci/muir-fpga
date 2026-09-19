// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/plumbing/cadr_probe.sv --- the in-fabric probe the board will be read
// through --- and asks it the two questions nothing else can.
//
// **DOES SAMPLE j HOLD ROW j?**  The probe is wired to `cadr_machine`
// exactly as `boards/arty-z7-20/cadr_arty.sv` wires it, the machine is run from reset, and
// every sample is compared against `build/rtl.golden` --- the same reference
// the processor checks use, column for column.  Nothing about the alignment
// is asserted here or worked out on paper.  It cost one wrong answer to
// learn that this needs checking rather than deriving: `clock_edge` is
// registered, so a flip-flop that sees it high has already seen the datapath
// move, and a probe that stores `data` at that edge stores the *next*
// microcycle's read phase --- off by one, uniformly, on every column, and
// entirely plausible-looking.  The core holds `data` for a tick to fix it and
// this is what says the fix is right.
//
// The window needs no stimulus.  The boot PROM's first memory cycle is at
// microcycle 535,791, so nothing in the first thousand microcycles asks the
// bus for anything: no grant, no acknowledgment, no stall, no device.
//
// **IS THE SAMPLE THE LAST VALUE BEFORE THE BOUNDARY, OR SOMETHING FROM THE
// MIDDLE OF THE MICROCYCLE?**  It matters most where the window above cannot
// reach it.  A stall is the clock held off and `-LOADMD` strobes MD inside
// it, so `golden/src/trace.rs` samples the model only after the stall has
// drained --- "a reference sampled before a stall is the value the cycle was
// waiting to be rid of", wrong on 5,652 of 600,000 rows.  The fabric's
// equivalent instant is the last tick before the boundary.  There is no stall
// in the first thousand microcycles, so the second probe in the harness is
// driven with gaps of two to twenty ticks and a datapath that moves on every
// one of them, and the sample has to be the value that stood in the tick
// before the qualifier and no other.
//
// **AND THE READOUT IS PART OF THE CHECK.**  Every sample compared here is
// shifted out through the probe's own JTAG shift register, one DR scan a
// sample, against a model of what a TAP does in Capture-DR and Shift-DR
// taken from `$XILINX_VIVADO/data/verilog/src/unisims/BSCANE2.v`.  A probe
// whose readout is wrong is a probe that says nothing, and the
// board is the one place that cannot be debugged by looking.
//
// **AND THE SAME WINDOW OVER THE ALTERA PATH.**  A second probe on the same
// machine sits behind `rtl/plumbing/agilex5/cadr_probe_vjtag.sv`, as on the
// DE25-Nano, and is read the way Altera's Virtual JTAG IP Core User Guide
// (683705) describes a node being driven: TCK running in every state, the
// node's virtual Capture-DR and Shift-DR as the only states it acts in, and
// its one-bit virtual instruction choosing the sample register or a bypass
// bit.  Before a sample is read the bypass must return a pattern one bit late
// behind a captured 0, and the instruction the node holds must read back as
// the one shifted in, which are the two things
// `boards/de25-nano/quartus/probe.tcl` asks of the board.  Then all 1,024
// samples must agree with the trace as the first probe's did.  The model of
// the hub is the guide's words and not silicon; the board is the check on it.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vcadr_probe_harness.h"
#include "verilated.h"

namespace {

// The layout, most significant field first, as `rtl/plumbing/cadr_probe.sv`
// concatenates it.  Held here as a table rather than as offsets, so that this
// program and `boards/arty-z7-20/vivado/probe.tcl` are two readings of one list and not two
// lists.
struct Field {
  const char *name;
  int width;
};
const Field kFields[] = {
    {"pc", 14},  {"ir", 48},  {"q", 32},   {"a", 32},       {"m", 32},
    {"alu", 32}, {"r", 32},   {"ob", 32},  {"dc", 10},      {"opc", 14},
    {"st", 32},  {"lc", 26},  {"iwrited", 1}, {"nop", 1},   {"n_vmaok", 1},
    {"jcond", 1}, {"pcs1", 1}, {"pcs0", 1}, {"lpc", 14},    {"md", 32},
    {"vma", 32}, {"promdis", 1},
};
const int kNFields = static_cast<int>(sizeof(kFields) / sizeof(kFields[0]));
const int kDataWidth = 421;
const int kSampleWidth = 1 + 32 + kDataWidth;   // valid, cycle, data

// What the harness is built with.  Verilator takes these from the module's
// own parameters; they are repeated here because the testbench has to size
// its own tables, and a disagreement shows up at once as a capture that never
// fills.
const int kRealDepth = 1024;
const int kSynthDepth = 8;

// One sample, as bits.  454 of them, so a small bitset by hand rather than a
// dependency.
struct Sample {
  std::vector<uint8_t> bit;
  Sample() : bit(kSampleWidth, 0) {}
  uint64_t field(int lsb, int width) const {
    uint64_t v = 0;
    for (int i = width - 1; i >= 0; --i) v = (v << 1) | bit[lsb + i];
    return v;
  }
};

int offset_of(const char *name, int *width) {
  int lsb = kDataWidth;
  for (int i = 0; i < kNFields; ++i) {
    lsb -= kFields[i].width;
    if (!std::strcmp(kFields[i].name, name)) {
      *width = kFields[i].width;
      return lsb;
    }
  }
  std::fprintf(stderr, "FAIL: no field named %s\n", name);
  std::exit(1);
}

Vcadr_probe_harness *dut = nullptr;
long ticks = 0;

void tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
  ++ticks;
}

// A DR scan of one sample, modeled on the UNISIM: DRCK follows TCK in
// Capture-DR and Shift-DR, the shift register loads on the CAPTURE rising
// edge, and the TAP reads TDO between rising edges --- so the first bit out
// is the one standing after the load.
Sample scan(bool synth) {
  // The machine's clock keeps running while JTAG is scanned, which is what
  // the board does and what the read pointer's crossing is written for: the
  // pointer moved at the last CAPTURE and the 200 MHz side has to have
  // fetched the word before this one.
  for (int i = 0; i < 8; ++i) tick();

  dut->real_sel = synth ? 0 : 1;
  dut->synth_sel = synth ? 1 : 0;
  dut->jtag_capture = 1;
  dut->jtag_shift = 0;
  dut->jtag_drck = 0;
  dut->eval();
  dut->jtag_drck = 1;
  dut->eval();

  dut->jtag_capture = 0;
  dut->jtag_shift = 1;
  Sample s;
  for (int i = 0; i < kSampleWidth; ++i) {
    s.bit[i] = synth ? dut->synth_tdo : dut->real_tdo;
    dut->jtag_drck = 0;
    dut->eval();
    dut->jtag_drck = 1;
    dut->eval();
  }
  dut->jtag_shift = 0;
  dut->real_sel = 0;
  dut->synth_sel = 0;
  dut->eval();
  return s;
}

// ---------------------------------------------- the Altera path, the hub's side
//
// One rising edge of TCK with the node's two virtual states as given.  The
// hub's state signals are its FSM's registered state, standing across the
// edge the state acts on, so they are set with TCK low and the edge follows.
void vj_edge(bool cdr, bool sdr) {
  dut->vj_cdr = cdr;
  dut->vj_sdr = sdr;
  dut->vj_tck = 0;
  dut->eval();
  dut->vj_tck = 1;
  dut->eval();
}

// TCK in the states where the node must do nothing: Run-Test/Idle, the
// Select, Exit, Update and Pause states, and all of an IR scan.
void vj_idle(int edges) {
  for (int i = 0; i < edges; ++i) vj_edge(false, false);
}

// A virtual IR scan: the hub captures `ir_out`, shifts, and at Update-IR the
// node's instruction becomes `value`.  Returns what was captured.
int vj_vir(int value) {
  for (int i = 0; i < 8; ++i) tick();
  vj_idle(3);
  const int captured = dut->vj_ir_out;
  vj_idle(12);
  dut->vj_ir_in = value;
  vj_idle(3);
  return captured;
}

// A virtual DR scan with `tdi` shifted in, first bit first, returning what
// came out, first bit out first.  Idle, Select-DR, Capture-DR, one edge a bit
// of Shift-DR, Exit1-DR, Update-DR, Idle: TCK runs through all of them, and
// TDO is read before each shifting edge.
std::vector<uint8_t> vj_vdr(const std::vector<uint8_t> &tdi) {
  for (int i = 0; i < 8; ++i) tick();
  vj_idle(2);
  vj_edge(true, false);
  std::vector<uint8_t> out(tdi.size(), 0);
  for (size_t i = 0; i < tdi.size(); ++i) {
    dut->vj_tdi = tdi[i];
    dut->vj_cdr = 0;
    dut->vj_sdr = 1;
    dut->vj_tck = 0;
    dut->eval();
    out[i] = dut->vj_tdo;
    dut->vj_tck = 1;
    dut->eval();
  }
  dut->vj_tdi = 0;
  vj_idle(4);
  return out;
}

Sample scan_alt() {
  std::vector<uint8_t> out = vj_vdr(std::vector<uint8_t>(kSampleWidth, 0));
  Sample s;
  for (int i = 0; i < kSampleWidth; ++i) s.bit[i] = out[i];
  return s;
}

// ---------------------------------------------------------- the reference

struct Golden {
  std::vector<std::string> names;
  std::vector<std::vector<uint64_t>> rows;
};

bool read_golden(const char *path, size_t want, Golden *g) {
  FILE *f = std::fopen(path, "r");
  if (!f) return false;
  char line[8192];
  while (std::fgets(line, sizeof(line), f)) {
    if (line[0] == '#') {
      if (g->names.empty()) {
        char *p = std::strtok(line + 1, " \t\n");
        while (p) {
          g->names.push_back(p);
          p = std::strtok(nullptr, " \t\n");
        }
      }
      continue;
    }
    std::vector<uint64_t> row;
    char *p = std::strtok(line, " \t\n");
    while (p) {
      row.push_back(std::strtoull(p, nullptr, 16));
      p = std::strtok(nullptr, " \t\n");
    }
    if (row.empty()) continue;
    g->rows.push_back(row);
    if (g->rows.size() >= want) break;
  }
  std::fclose(f);
  return !g->names.empty() && g->rows.size() >= want;
}

int column_of(const Golden &g, const char *name) {
  for (size_t i = 0; i < g.names.size(); ++i)
    if (g.names[i] == name) return static_cast<int>(i);
  return -1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = argc > 1 ? argv[1] : "build/rtl.golden";

  Golden g;
  if (!read_golden(path, kRealDepth, &g)) {
    std::fprintf(stderr, "FAIL: cannot read %d rows of %s\n", kRealDepth, path);
    return 1;
  }

  dut = new Vcadr_probe_harness;
  dut->clk = 0;
  dut->rst = 1;
  dut->jtag_drck = 0;
  dut->jtag_shift = 0;
  dut->jtag_capture = 0;
  dut->jtag_tdi = 0;
  dut->real_sel = 0;
  dut->synth_sel = 0;
  dut->s_qualify = 0;
  dut->vj_tck = 0;
  dut->vj_tdi = 0;
  dut->vj_ir_in = 0;
  dut->vj_cdr = 0;
  dut->vj_sdr = 0;

  // ------------------------------------------------- the run, and the gaps
  //
  // The synthetic side gets a datapath that moves on every tick and a
  // qualifier with gaps of 2 to 20 ticks between them --- a stall, made much
  // longer than the machine's own so that a sample taken from the middle of
  // one could not be mistaken for the value at its end.
  std::vector<uint64_t> synth_want;      // the value that stood a tick before
  uint64_t synth_v = 0;
  uint64_t synth_prev = 0;
  int gap = 2, until_qualify = 2;
  long synth_qualified = 0;

  long microcycles = 0;
  int prev_clock_edge = 0;

  const long kMaxTicks = 400000;
  for (long t = 0; t < kMaxTicks && microcycles <= kRealDepth + 4; ++t) {
    if (t == 4) dut->rst = 0;

    // The datapath the synthetic probe sees, changed every tick.
    synth_prev = synth_v;
    synth_v = static_cast<uint64_t>(t) * 0x9E3779B97F4A7C15ull;
    dut->s_pc = synth_v & 0x3fff;
    dut->s_ir = synth_v & 0xffffffffffffull;
    dut->s_q = static_cast<uint32_t>(synth_v >> 3);
    dut->s_a = static_cast<uint32_t>(synth_v >> 5);
    dut->s_m = static_cast<uint32_t>(synth_v >> 7);
    dut->s_alu = static_cast<uint32_t>(synth_v >> 11);
    dut->s_r = static_cast<uint32_t>(synth_v >> 13);
    dut->s_ob = static_cast<uint32_t>(synth_v >> 17);
    dut->s_dc = (synth_v >> 19) & 0x3ff;
    dut->s_opc = (synth_v >> 23) & 0x3fff;
    dut->s_st = static_cast<uint32_t>(synth_v >> 29);
    dut->s_lc = (synth_v >> 31) & 0x3ffffff;
    dut->s_iwrited = (synth_v >> 37) & 1;
    dut->s_nop = (synth_v >> 38) & 1;
    dut->s_n_vmaok = (synth_v >> 39) & 1;
    dut->s_jcond = (synth_v >> 40) & 1;
    dut->s_pcs1 = (synth_v >> 41) & 1;
    dut->s_pcs0 = (synth_v >> 42) & 1;
    dut->s_lpc = (synth_v >> 43) & 0x3fff;
    dut->s_md = static_cast<uint32_t>(synth_v >> 2);
    dut->s_vma = static_cast<uint32_t>(synth_v >> 19);
    dut->s_promdis = (synth_v >> 47) & 1;

    // The qualifier, one tick wide, with a growing gap behind it. Held low
    // through the reset so that the first sample is the first one after it.
    int qualify = 0;
    if (t > 8) {
      if (--until_qualify <= 0) {
        qualify = 1;
        gap = gap >= 20 ? 2 : gap + 3;
        until_qualify = gap;
      }
    }
    dut->s_qualify = static_cast<uint8_t>(qualify);
    if (qualify) {
      // What the probe must store: the value that stood a tick earlier.
      synth_want.push_back(synth_prev);
      ++synth_qualified;
    }

    tick();

    if (dut->clock_edge && !prev_clock_edge) ++microcycles;
    prev_clock_edge = dut->clock_edge;
  }

  if (microcycles <= kRealDepth) {
    std::fprintf(stderr,
                 "FAIL: only %ld microcycles in %ld ticks; the capture never "
                 "filled\n",
                 microcycles, ticks);
    return 1;
  }

  // ------------------------------------------------ the machine's capture

  int bad = 0;
  int reported = 0;
  std::vector<int> col(kNFields), off(kNFields), wid(kNFields);
  for (int i = 0; i < kNFields; ++i) {
    off[i] = offset_of(kFields[i].name, &wid[i]);
    col[i] = column_of(g, kFields[i].name);
    if (col[i] < 0) {
      std::fprintf(stderr,
                   "FAIL: %s has no column named %s; the probe's field list "
                   "and the trace's header have parted company\n",
                   path, kFields[i].name);
      return 1;
    }
  }
  const int cycle_col = column_of(g, "cycle");

  long compared = 0;
  std::vector<long> distinct_lo(kNFields, 0);
  // THE ONE COMPARISON, FOR BOTH PATHS: the Zynq boards' `BSCANE2` first,
  // then the Altera node, each of the 1,024 samples against its row.
  for (int path_i = 0; path_i < 2; ++path_i) {
  const bool alt = path_i == 1;
  if (alt) {
    // The node's instruction comes up 0, the bypass bit.  A 16-bit pattern
    // through it must come back one bit late behind the captured 0, and the
    // instruction it holds must read back as the one shifted in.
    if (vj_vir(0) != 0) {
      std::fprintf(stderr, "FAIL: the node's instruction did not come up 0\n");
      return 1;
    }
    const uint32_t pattern = 0xa53c;
    std::vector<uint8_t> in(16);
    for (int i = 0; i < 16; ++i) in[i] = (pattern >> i) & 1;
    std::vector<uint8_t> out = vj_vdr(in);
    uint32_t back = 0;
    for (int i = 0; i < 16; ++i) back |= static_cast<uint32_t>(out[i]) << i;
    if (back != ((pattern << 1) & 0xffff)) {
      std::fprintf(stderr,
                   "FAIL: the bypass returned %04x for %04x, wanting %04x: one "
                   "bit of delay behind a captured 0\n",
                   back, pattern, (pattern << 1) & 0xffff);
      return 1;
    }
    const int first = vj_vir(1);
    const int second = vj_vir(1);
    if (first != 0 || second != 1) {
      std::fprintf(stderr, "FAIL: the node's instruction reads back %d and %d "
                           "after 0 and 1 were shifted in\n", first, second);
      return 1;
    }
  }
  for (int j = 0; j < kRealDepth; ++j) {
    Sample s = alt ? scan_alt() : scan(false);
    if (!s.bit[kSampleWidth - 1]) {
      std::fprintf(stderr,
                   "FAIL: sample %d has its valid bit clear; the capture did "
                   "not fill\n",
                   j);
      return 1;
    }
    const uint64_t cyc = s.field(kDataWidth, 32);
    if (cyc != static_cast<uint64_t>(j)) {
      std::fprintf(stderr,
                   "FAIL: sample %d carries cycle %llu; the window does not "
                   "begin at microcycle zero, or a sample was dropped\n",
                   j, static_cast<unsigned long long>(cyc));
      return 1;
    }
    if (g.rows[j][cycle_col] != cyc) {
      std::fprintf(stderr, "FAIL: sample %d is cycle %llu, the trace's row is "
                           "cycle %llu\n",
                   j, static_cast<unsigned long long>(cyc),
                   static_cast<unsigned long long>(g.rows[j][cycle_col]));
      return 1;
    }
    for (int i = 0; i < kNFields; ++i) {
      const uint64_t got = s.field(off[i], wid[i]);
      const uint64_t want = g.rows[j][col[i]];
      ++compared;
      if (got != want) {
        ++bad;
        if (reported < 20) {
          ++reported;
          std::fprintf(stderr,
                       "FAIL: microcycle %d, %s: the capture has %llx where "
                       "muir has %llx\n",
                       j, kFields[i].name,
                       static_cast<unsigned long long>(got),
                       static_cast<unsigned long long>(want));
        }
      }
      if (got) ++distinct_lo[i];
    }
    if (bad >= 20) break;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches in %ld comparisons, reading %s\n",
                 bad, compared,
                 alt ? "through the Altera node" : "through the BSCANE2");
    return 1;
  }
  }

  // ------------------------------------------------ the synthetic capture
  //
  // The probe froze when it filled, so what it holds is the FIRST
  // kSynthDepth qualified samples and not the last: a probe that kept
  // overwriting would read back as the end of the run.
  if (synth_qualified <= kSynthDepth) {
    std::fprintf(stderr, "FAIL: only %ld synthetic samples were offered\n",
                 synth_qualified);
    return 1;
  }
  // Twice round, so that the read pointer's wrap is checked as well as its
  // walk: DEPTH scans must leave it where they found it.
  for (int pass = 0; pass < 2; ++pass) {
    for (int j = 0; j < kSynthDepth; ++j) {
      Sample s = scan(true);
      if (!s.bit[kSampleWidth - 1]) {
        std::fprintf(stderr, "FAIL: synthetic sample %d is not valid\n", j);
        return 1;
      }
      const uint64_t cyc = s.field(kDataWidth, 32);
      if (cyc != static_cast<uint64_t>(j)) {
        std::fprintf(stderr,
                     "FAIL: synthetic sample %d carries cycle %llu on pass "
                     "%d; the read pointer did not come back to where it "
                     "started\n",
                     j, static_cast<unsigned long long>(cyc), pass);
        return 1;
      }
      int w = 0;
      const int o = offset_of("ir", &w);
      const uint64_t got = s.field(o, w);
      const uint64_t want = synth_want[j] & 0xffffffffffffull;
      if (got != want) {
        std::fprintf(stderr,
                     "FAIL: synthetic sample %d holds %llx where the value "
                     "standing in the tick before the qualifier was %llx --- "
                     "the probe is sampling at the wrong instant\n",
                     j, static_cast<unsigned long long>(got),
                     static_cast<unsigned long long>(want));
        return 1;
      }
    }
  }

  // What the window actually exercised, on the check's own output, because a
  // column that never moves is a column this proves nothing about.
  std::printf(
      "ok: %d microcycles of the board's capture agree with muir's rtl "
      "engine\n",
      kRealDepth);
  std::printf("    read out over the probe's own JTAG shift register, one DR "
              "scan a sample, %ld ticks of machine\n",
              ticks);
  std::printf("    %d columns compared, %ld comparisons, and the sample's own "
              "cycle counts 0 to %d\n",
              kNFields, compared, kRealDepth - 1);
  std::printf("    read twice: through the Zynq boards' BSCANE2, and through "
              "the Altera node with TCK in every state,\n"
              "    its bypass one bit late and its instruction read back\n");
  std::printf("    columns that are non-zero somewhere in the window:");
  for (int i = 0; i < kNFields; ++i)
    if (distinct_lo[i]) std::printf(" %s", kFields[i].name);
  std::printf("\n");
  std::printf("    columns flat at zero for all %d rows, so untested here:",
              kRealDepth);
  for (int i = 0; i < kNFields; ++i)
    if (!distinct_lo[i]) std::printf(" %s", kFields[i].name);
  std::printf("\n");
  std::printf("    %d synthetic samples twice over, gaps of 2 to 20 ticks, "
              "the stall the window has none of\n",
              kSynthDepth);

  dut->final();
  delete dut;
  return 0;
}
