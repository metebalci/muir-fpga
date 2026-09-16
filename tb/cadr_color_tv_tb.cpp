// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The SECOND display board --- MIT's color TV --- against muir, through the
// whole memory path, on a backplane that also carries the first.
//
// The DUT is `cadr_memory_path` as the machine wires it: the three decodes,
// the bus interface, the bridge and BOTH `rtl/machine/cadr_tv.sv` instances
// inside it, with `color_tv` up. `build/color_tv.golden` is the stimulus and
// the reference, out of muir's own `tv::Tv::color()` through
// `busint::Busint`, and `golden/src/color_tv.rs` says what the program is
// and why.
//
// WHAT THIS HOLDS TO, and none of it is held anywhere else:
//
//   - **Two boards answer on one backplane and neither answers for the
//     other.** Every control word and every window word of both boards is
//     in the trace, at two straps, and the words are injective in the board
//     as well as the offset --- so a fabric whose second instance answered
//     the first's addresses, or whose windows shared one region of DDR,
//     reads back the wrong word rather than agreeing.
//   - **The two windows are two regions of DDR.** Every color-window cycle
//     reaches the memory port at `COLOR_DISPLAY_BASE` plus four times the
//     offset and every first-board cycle at `DISPLAY_BASE`, asserted at the
//     port on the tick, and read back through a modeled DDR keyed by the
//     STIMULUS's address and filled from the STIMULUS's word.
//   - **`-XBUS.INTR` is the OR of two boards**, which is muir's
//     `Machine::xbus_interrupt`: the column is compared at every tick, and
//     the trace raises the line from the color board alone, from the first
//     board alone, and from both.
//   - **The color map, which no bus cycle can read back.** It is write only
//     --- `color.lisp` keeps `HARDWARE-COLOR-MAP` in the band because "the
//     hardware does not allow reading back of the color map" --- so the
//     trace's header carries the map muir holds and this reads the fabric's
//     own map port and compares all forty-eight bytes of each board. That
//     port is what `rtl/plumbing/cadr_console.sv` answers pages 4 and 5
//     with, so what an RFB server renders through is what is compared here.
//
// AND CONFIGURATION B IS THE BACKPLANE WITH NO SECOND BOARD, which is the
// one the band probes for. `COLOR-EXISTS-P` in `sys/window/color.lisp`
// writes into the first buffer word with the error stop off and reads it
// back, and a machine with no board there has to give it the NXM. So the
// same cycles are run with `color_tv` down and required to time out with MD
// zero, while the first board goes on answering at its own strap --- which
// is what says the input does something rather than that the addresses are
// dead.
//
// THE ROWS ARE SPARSE AND THE CHECK IS NOT: every gap is stepped a tick at a
// time with the inputs held and every output required to hold, exactly as
// `tb/cadr_tv_tb.cpp` does.

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "Vcadr_memory_path.h"
#include "verilated.h"

namespace {

// A microcycle at normal speed: where MCLK falls.
constexpr long kMicrocycle = 29;

// `cadr_ddr_map.sv`'s three bases, transcribed here so that a move of the
// map is a mismatch and not a silent agreement.
constexpr uint32_t kMainBase = 0x18000000u;
constexpr uint32_t kDisplayBase = 0x1C000000u;
constexpr uint32_t kColorBase = 0x1C020000u;

// `tv::NORMAL_TV` and `tv::COLOR_TV`, checked against the trace's header.
constexpr uint32_t kBuffer = 017000000u;
constexpr uint32_t kControl = 017377760u;
constexpr uint32_t kColorBuffer = 017200000u;
constexpr uint32_t kColorControl = 017377750u;
constexpr uint32_t kBufferWords = 0100000u;
constexpr uint32_t kControlWords = 8u;

// `tv::COLORS` and `tv::CHANNELS`.
constexpr int kColors = 16;
constexpr int kChannels = 3;

struct Row {
  long tick;
  int n_memrq, wrcyc;
  unsigned phys, wdata;
  int mclk, xinit;
  int n_memgrant, n_memack, n_loadmd, timed_out;
  unsigned rdata;
  int intr;
};

bool InWindow(unsigned phys) { return phys >= kBuffer && phys < kBuffer + kBufferWords; }
bool InColorWindow(unsigned phys) {
  return phys >= kColorBuffer && phys < kColorBuffer + kBufferWords;
}
bool InControl(unsigned phys) { return phys >= kControl && phys < kControl + kControlWords; }
bool InColorControl(unsigned phys) {
  return phys >= kColorControl && phys < kColorControl + kControlWords;
}

// Where a word of the stimulus's address lives in DDR: three regions, and
// the two windows are two of them.
uint32_t ByteAddress(unsigned phys) {
  if (InColorWindow(phys)) return kColorBase + ((phys - kColorBuffer) << 2);
  if (InWindow(phys)) return kDisplayBase + ((phys - kBuffer) << 2);
  return kMainBase + (phys << 2);
}

// What the modeled DDR holds at a byte address nothing wrote: injective in
// the address, so a read that went to the wrong word cannot come back right.
uint32_t Untouched(uint32_t byte_addr) {
  return (0x9E3779B9u * ((byte_addr >> 2) + 1u)) ^ 0xA5A5A5A5u;
}

int Fail(long tick, const char *what, unsigned long got, unsigned long want, const Row &r) {
  std::fprintf(stderr,
               "tick %ld: %s is %lu (0x%lx), reference says %lu (0x%lx)\n"
               "  inputs: n_memrq=%d wrcyc=%d phys=0%o wdata=0x%x xinit=%d (row at tick %ld)\n",
               tick, what, got, got, want, want, r.n_memrq, r.wrcyc, r.phys, r.wdata, r.xinit,
               r.tick);
  return 1;
}

int BFail(const char *what, unsigned long got, unsigned long want) {
  std::fprintf(stderr, "configuration B: %s is %lu (0x%lx), wanting %lu (0x%lx)\n", what, got, got,
               want, want);
  return 1;
}

// ------------------------------------------------------------------------
// CONFIGURATION B: the backplane with no second display board
// ------------------------------------------------------------------------
//
// The head of this file has the argument. What is held here is the property
// the band depends on: with `color_tv` down every color address times out
// with MD zero, and the first board goes on answering at its own strap.
//
// It is NOT held against muir row by row --- `busint::decode` is the same
// machine and `build/xbus_decode.pass` walks every one of the 4,194,304
// addresses of both backplanes --- because what this adds is the composed
// path: the decode, the two instances' own held matches, the bridge and the
// acknowledgment all together.

struct BAnswer {
  bool answered, timed_out, port_seen;
  uint32_t md;
};

int ConfigurationB() {
  auto *dut = new Vcadr_memory_path;
  dut->n_boot = 1;
  dut->clk = 0;
  dut->rst = 1;
  dut->xbus_init = 0;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
  // **THE BACKPLANE WITH ONE DISPLAY BOARD**, which is `busint::decode`'s
  // own machine and every trace in this repository but the one above.
  dut->tv_lispm = 0;
  dut->color_tv = 0;
  dut->tv_map_a = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->spy_rdata = 0;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->ch_req = 0;
  dut->ch_write = 0;
  dut->ch_addr = 0;
  dut->ch_wdata = 0;
  dut->eval();

  std::map<uint32_t, uint32_t> ddr;
  long tick = 0;
  int bad = 0;
  long port_cycles = 0;

  // One bus cycle, run to its end or to the NXM timer. The memory answers at
  // once here: what is being asked is who answers, not when.
  auto cycle = [&](bool write, unsigned phys, uint32_t wdata) -> BAnswer {
    BAnswer a{false, false, false, 0};
    dut->phys = phys;
    dut->wrcyc = write ? 1 : 0;
    dut->wdata = wdata;
    dut->n_memrq = 0;
    for (long i = 0; i < 2000; ++i) {
      dut->rst = 0;
      dut->mclk = (tick % kMicrocycle) == 0;
      dut->clk = 1;
      dut->eval();
      dut->mem_done = 0;
      if (dut->mem_req) {
        a.port_seen = true;
        ++port_cycles;
        if (dut->mem_write) {
          ddr[dut->mem_addr] = dut->mem_wdata;
        } else {
          auto it = ddr.find(dut->mem_addr);
          dut->mem_rdata = (it == ddr.end()) ? Untouched(dut->mem_addr) : it->second;
        }
        dut->mem_done = 1;
      }
      dut->eval();
      if (!dut->n_memack) {
        a.answered = true;
        a.timed_out = dut->timed_out;
        a.md = dut->rdata;
      }
      dut->clk = 0;
      dut->eval();
      ++tick;
      if (a.answered) break;
    }
    dut->n_memrq = 1;
    // Let the interface finish and the bus idle.
    for (long i = 0; i < 80; ++i) {
      dut->mclk = (tick % kMicrocycle) == 0;
      dut->clk = 1;
      dut->eval();
      dut->mem_done = 0;
      dut->clk = 0;
      dut->eval();
      ++tick;
    }
    return a;
  };

  // Out of reset.
  for (long i = 0; i < 8; ++i) {
    dut->rst = (i < 4);
    dut->mclk = (tick % kMicrocycle) == 0;
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
    ++tick;
  }

  // **`COLOR-EXISTS-P`'s own two cycles**, and then a sweep of the color
  // board's whole face: nothing may answer any of it.
  const unsigned absent[] = {
      kColorBuffer,
      kColorBuffer + 1,
      kColorBuffer + kBufferWords - 1,
      kColorControl,
      kColorControl + 1,
      kColorControl + 4,
      kColorControl + kControlWords - 1,
  };
  long timed_out = 0;
  for (unsigned a : absent) {
    BAnswer w = cycle(true, a, 0x1234'5678u);
    if (!w.answered) bad += BFail("a write to a color address never ended", 0, 1);
    if (!w.timed_out) bad += BFail("a write to a color address was answered", 1, 0);
    if (w.port_seen) bad += BFail("a write to a color address reached the memory port", 1, 0);
    BAnswer r = cycle(false, a, 0);
    if (!r.answered) bad += BFail("a read of a color address never ended", 0, 1);
    if (!r.timed_out) bad += BFail("a read of a color address was answered", 1, 0);
    if (r.md != 0) bad += BFail("MD on a color read nothing answered", r.md, 0);
    if (r.port_seen) bad += BFail("a read of a color address reached the memory port", 1, 0);
    if (w.timed_out && r.timed_out) ++timed_out;
  }

  // And the first board still answers, at its own strap, on the same
  // backplane --- which is what says `color_tv` took the second board away
  // and not the decode.
  long answered = 0;
  const unsigned present[] = {kControl, kBuffer, kBuffer + kBufferWords - 1};
  for (unsigned a : present) {
    BAnswer w = cycle(true, a, 0xA5A5'1234u);
    if (w.timed_out) bad += BFail("a write to the first board timed out", 1, 0);
    BAnswer r = cycle(false, a, 0);
    if (r.timed_out) bad += BFail("a read of the first board timed out", 1, 0);
    if (!r.timed_out) ++answered;
    if (a != kControl && r.md != 0xA5A5'1234u)
      bad += BFail("the word the first board's window read back", r.md, 0xA5A5'1234u);
  }

  // The color board keeps no map either: nothing can have written one.
  for (int c = 0; c < kColors; ++c) {
    dut->tv_map_a = c;
    dut->eval();
    if (dut->tv_color_map_q != 0)
      bad += BFail("the color board's map on a backplane with no color board",
                   dut->tv_color_map_q, 0);
  }

  dut->final();
  delete dut;
  if (bad) {
    std::fprintf(stderr, "FAIL: configuration B, %d faults\n", bad);
    return 1;
  }
  std::printf(
      "ok: configuration B, the backplane with no second display board:\n"
      "    %ld color addresses gave the NXM to a write and a read, MD zero and the memory\n"
      "    port untouched --- the buffer's two edges, a word inside it and four control words\n"
      "    --- while the first board answered %ld of its own at the same time, and the color\n"
      "    board's map read zero at every one of its sixteen colors\n",
      timed_out, answered);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/color_tv.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  std::map<std::string, std::vector<long>> hdr;
  std::vector<Row> rows;
  // The two maps out of the header, `[board][color][channel]` with red
  // first: board 0 the first display and board 1 the color board.
  long map[2][kColors][kChannels];
  bool map_seen[2][kColors];
  std::memset(map, 0, sizeof map);
  std::memset(map_seen, 0, sizeof map_seen);

  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#') {
      char what[32];
      long color, r, g, b;
      if (std::sscanf(line, "# map_%31s %ld %ld %ld %ld", what, &color, &r, &g, &b) == 5) {
        const int board = (std::strcmp(what, "color") == 0)   ? 1
                          : (std::strcmp(what, "normal") == 0) ? 0
                                                               : -1;
        if (board < 0 || color < 0 || color >= kColors) {
          std::fprintf(stderr, "%s: cannot read a map line: %s", path, line);
          return 2;
        }
        map[board][color][0] = r;
        map[board][color][1] = g;
        map[board][color][2] = b;
        map_seen[board][color] = true;
        continue;
      }
      char key[64];
      int used = 0;
      if (std::sscanf(line, "# %63s%n", key, &used) == 1) {
        std::vector<long> vals;
        const char *p = line + used;
        long v;
        int n;
        while (std::sscanf(p, "%ld%n", &v, &n) == 1) {
          vals.push_back(v);
          p += n;
        }
        if (!vals.empty()) hdr[key] = vals;
      }
      continue;
    }
    if (line[0] == '\n') continue;
    Row r;
    if (std::sscanf(line, "%ld %d %d %u %u %d %d %d %d %d %d %u %d", &r.tick, &r.n_memrq, &r.wrcyc,
                    &r.phys, &r.wdata, &r.mclk, &r.xinit, &r.n_memgrant, &r.n_memack, &r.n_loadmd,
                    &r.timed_out, &r.rdata, &r.intr) != 13) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }
    rows.push_back(r);
  }
  std::fclose(f);
  if (rows.empty() || rows[0].tick != 0) {
    std::fprintf(stderr, "FAIL: the trace does not start at tick 0\n");
    return 1;
  }
  for (int b = 0; b < 2; ++b)
    for (int c = 0; c < kColors; ++c)
      if (!map_seen[b][c]) {
        std::fprintf(stderr, "FAIL: %s has no map line for board %d color %d\n", path, b, c);
        return 1;
      }

  auto want_h = [&](const char *key, size_t i = 0) -> long {
    auto it = hdr.find(key);
    if (it == hdr.end() || it->second.size() <= i) {
      std::fprintf(stderr, "FAIL: %s has no `%s` in its header\n", path, key);
      std::exit(1);
    }
    return it->second[i];
  };
  struct { const char *what; long got, want; } consts[] = {
      {"microcycle_ticks", want_h("microcycle_ticks"), kMicrocycle},
      {"setup_ticks", want_h("setup_ticks"), 16L},
      {"deskew_ticks", want_h("deskew_ticks"), 12L},
      {"buffer", want_h("buffer"), (long)kBuffer},
      {"control", want_h("control"), (long)kControl},
      {"color_buffer", want_h("color_buffer"), (long)kColorBuffer},
      {"color_control", want_h("color_control"), (long)kColorControl},
      {"buffer_words", want_h("buffer_words"), (long)kBufferWords},
      {"boards", want_h("boards"), 32L},
  };
  int wrong = 0;
  for (const auto &c : consts)
    if (c.got != c.want) {
      std::fprintf(stderr, "FAIL: the trace says %s is %ld and the fabric has %ld\n", c.what, c.got,
                   c.want);
      ++wrong;
    }
  if (wrong) return 1;
  const long last_tick = want_h("last_tick");

  auto *dut = new Vcadr_memory_path;
  dut->n_boot = 1;
  dut->clk = 0;
  dut->rst = 1;
  dut->xbus_init = 0;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
  // **THE BACKPLANE WITH BOTH BOARDS.** The first display is a SIMPLE TV,
  // which is muir's own default and what the trace's model is; the color
  // board is a LISPM TV whatever this says, `Tv::color` being one.
  dut->tv_lispm = 0;
  dut->color_tv = 1;
  dut->tv_map_a = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->spy_rdata = 0;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->ch_req = 0;
  dut->ch_write = 0;
  dut->ch_addr = 0;
  dut->ch_wdata = 0;
  dut->eval();

  std::map<uint32_t, uint32_t> ddr;
  long checked = 0;
  int bad = 0;
  long reads_checked = 0;
  long c_fb_reads = 0, c_fb_writes = 0, n_fb_reads = 0, n_fb_writes = 0;
  long main_reads = 0, main_writes = 0, nxm_cycles = 0;
  long c_reg_reads[8] = {0}, c_reg_writes[8] = {0};
  long n_reg_reads = 0, n_reg_writes = 0;
  long intr_rises = 0, intr_falls = 0, inits = 0, cycles = 0, timeouts = 0;
  // Where a window cycle's port went: the color region, the first board's,
  // or main memory's. The equality against `ByteAddress` fails first, but
  // the counts say in three numbers that no window cycle reached the wrong
  // region.
  long c_port = 0, n_port = 0, wrong_port = 0;
  long c_reads_with_a_bit = 0, c_reads_checked = 0;
  int intr_last = 0, memack_last = 1, memrq_last = 1, timed_out_last = 0;

  auto step = [&](long tick, const Row &r, bool on_row) {
    const int mclk = (tick % kMicrocycle) == 0;
    if (on_row && r.mclk != mclk) bad += Fail(tick, "the MCLK grid", mclk, r.mclk, r);
    dut->mclk = mclk;
    dut->xbus_init = on_row ? r.xinit : 0;
    dut->n_memrq = r.n_memrq;
    dut->wrcyc = r.wrcyc;
    dut->phys = r.phys;
    dut->wdata = r.wdata;

    dut->clk = 1;
    dut->eval();

    const int req = dut->mem_req;
    const uint32_t addr = dut->mem_addr;
    const int wr = dut->mem_write;
    const uint32_t want_addr = ByteAddress(r.phys);
    dut->mem_done = req;
    if (req) {
      if (addr != want_addr)
        bad += Fail(tick, "the byte address on the memory port", addr, want_addr, r);
      if (wr != r.wrcyc) bad += Fail(tick, "the direction on the memory port", wr, r.wrcyc, r);
      if (!wr) {
        auto it = ddr.find(addr);
        dut->mem_rdata = (it == ddr.end()) ? Untouched(addr) : it->second;
      }
    }
    dut->eval();

    if (dut->n_memgrant != r.n_memgrant)
      bad += Fail(tick, "-MEMGRANT", dut->n_memgrant, r.n_memgrant, r);
    if (dut->n_memack != r.n_memack) bad += Fail(tick, "-MEMACK", dut->n_memack, r.n_memack, r);
    if (dut->n_loadmd != r.n_loadmd) bad += Fail(tick, "-LOADMD", dut->n_loadmd, r.n_loadmd, r);
    if (dut->timed_out != r.timed_out) bad += Fail(tick, "NXM TIMEOUT", dut->timed_out, r.timed_out, r);
    if (dut->tv_intr != r.intr) bad += Fail(tick, "-XBUS.INTR", dut->tv_intr, r.intr, r);

    if (req && wr) {
      if (dut->mem_wdata != r.wdata)
        bad += Fail(tick, "the word on the memory port", dut->mem_wdata, r.wdata, r);
      ddr[want_addr] = r.wdata;
    }
    if (req && (InWindow(r.phys) || InColorWindow(r.phys))) {
      if (addr >= kColorBase && addr < kColorBase + (kBufferWords << 2)) ++c_port;
      else if (addr >= kDisplayBase && addr < kColorBase) ++n_port;
      else ++wrong_port;
    }

    if (!r.n_memack && memack_last) {
      if (r.timed_out) {
        if (dut->rdata != 0)
          bad += Fail(tick, "MEM<31:0> on a cycle nothing answered", dut->rdata, 0, r);
      } else if (!r.wrcyc) {
        if (dut->rdata != r.rdata) bad += Fail(tick, "MD", dut->rdata, r.rdata, r);
        else ++reads_checked;
        if (InColorWindow(r.phys)) {
          ++c_reads_checked;
          if (r.rdata != 0) ++c_reads_with_a_bit;
        }
      }
    }
    memack_last = r.n_memack;

    if (dut->tv_intr && !intr_last) ++intr_rises;
    if (!dut->tv_intr && intr_last) ++intr_falls;
    intr_last = dut->tv_intr;
    if (on_row && r.xinit) ++inits;
    if (r.timed_out && !timed_out_last) ++timeouts;
    timed_out_last = r.timed_out;
    if (!r.n_memrq && memrq_last) {
      ++cycles;
      if (InColorControl(r.phys))
        (r.wrcyc ? c_reg_writes : c_reg_reads)[r.phys - kColorControl]++;
      else if (InControl(r.phys)) (r.wrcyc ? n_reg_writes : n_reg_reads)++;
      else if (InColorWindow(r.phys)) (r.wrcyc ? c_fb_writes : c_fb_reads)++;
      else if (InWindow(r.phys)) (r.wrcyc ? n_fb_writes : n_fb_reads)++;
      else if (r.phys < (32u << 16)) (r.wrcyc ? main_writes : main_reads)++;
      else ++nxm_cycles;
    }
    memrq_last = r.n_memrq;

    dut->clk = 0;
    dut->eval();
    ++checked;
  };

  // **MUIR'S t = 0 IS TWO EDGES AFTER THE RESET EDGE, NOT THE RESET EDGE**:
  // the reset edge and one idle edge come before row 0, as they do in the
  // whole machine.  `tb/cadr_busint_xbus_tb.cpp` gives the argument at its
  // own `kPowerOnEdges`, and `POWER_ON_T` in `cadr_busint_xbus.sv` is what
  // it holds; issue #21.
  constexpr int kPowerOnEdges = 2;
  for (int e = 0; e < kPowerOnEdges; ++e) {
    dut->rst = (e == 0);
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
  }
  dut->rst = 0;

  long tick = 0;
  for (size_t i = 0; i < rows.size() && bad < 20; ++i) {
    const Row &r = rows[i];
    if (r.tick < tick) {
      std::fprintf(stderr, "%s: rows out of order at tick %ld\n", path, r.tick);
      return 2;
    }
    if (i > 0) {
      const Row &held = rows[i - 1];
      for (; tick < r.tick && bad < 20; ++tick) step(tick, held, false);
    }
    step(r.tick, r, true);
    tick = r.tick + 1;
  }
  for (; tick <= last_tick && bad < 20; ++tick) step(tick, rows.back(), false);

  // ---- the two color maps, which no bus cycle can read back -------------
  long map_bytes = 0, map_nonzero = 0;
  for (int c = 0; c < kColors && bad < 20; ++c) {
    dut->tv_map_a = c;
    dut->eval();
    const uint32_t got[2] = {dut->tv_map_q, dut->tv_color_map_q};
    for (int b = 0; b < 2; ++b) {
      const uint32_t want =
          ((uint32_t)map[b][c][0] << 16) | ((uint32_t)map[b][c][1] << 8) | (uint32_t)map[b][c][2];
      if (got[b] != want) {
        std::fprintf(stderr,
                     "the %s board's color map at color %d is 0x%06x, muir says 0x%06x\n",
                     b ? "color" : "first", c, got[b], want);
        ++bad;
      }
      map_bytes += 3;
      for (int ch = 0; ch < kChannels; ++ch)
        if (map[b][c][ch] != 0) ++map_nonzero;
    }
  }

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, checked);
    return 1;
  }

  int thin = 0;
  auto same = [&](const char *what, long got, long want) {
    if (got != want) {
      std::fprintf(stderr, "FAIL: the run saw %ld %s and the trace's header says %ld\n", got, what,
                   want);
      ++thin;
    }
  };
  same("cycles", cycles, want_h("cycles"));
  for (int k = 0; k < 8; ++k) {
    char what[80];
    std::snprintf(what, sizeof what, "reads of the color board's register %d", k);
    same(what, c_reg_reads[k], want_h("color_register_reads", k));
    std::snprintf(what, sizeof what, "writes of the color board's register %d", k);
    same(what, c_reg_writes[k], want_h("color_register_writes", k));
  }
  same("reads of the first board's registers", n_reg_reads, want_h("normal_register_reads"));
  same("writes of the first board's registers", n_reg_writes, want_h("normal_register_writes"));
  same("color window reads", c_fb_reads, want_h("color_buffer_reads"));
  same("color window writes", c_fb_writes, want_h("color_buffer_writes"));
  same("first board window reads", n_fb_reads, want_h("buffer_reads"));
  same("first board window writes", n_fb_writes, want_h("buffer_writes"));
  same("main memory reads", main_reads, want_h("main_reads"));
  same("main memory writes", main_writes, want_h("main_writes"));
  same("cycles nothing answered", nxm_cycles, want_h("nxm_cycles"));
  same("timeouts", timeouts, want_h("nxm_cycles"));
  same("-XBUS INIT pulses", inits, want_h("inits"));
  same("rises of -XBUS.INTR", intr_rises, want_h("intr_rises"));
  same("falls of -XBUS.INTR", intr_falls, want_h("intr_falls"));
  same("color window cycles at the color base", c_port, c_fb_reads + c_fb_writes);
  same("first board window cycles at the display's base", n_port, n_fb_reads + n_fb_writes);
  same("window cycles that reached the wrong region", wrong_port, 0);
  same("color window reads compared at -LOADMD", c_reads_checked, c_fb_reads);
  if (thin) return 1;

  // The thinness guards: a trace that stopped reaching one of these would go
  // on passing without them.
  if (c_fb_reads < 10 || n_fb_reads < 10 || c_reg_writes[4] < 40 || nxm_cycles < 3 ||
      intr_rises < 3) {
    std::fprintf(stderr,
                 "FAIL: the trace is too thin: %ld color window reads, %ld first board's,\n"
                 "      %ld color register writes, %ld timeouts, %ld interrupt rises\n",
                 c_fb_reads, n_fb_reads, c_reg_writes[4], nxm_cycles, intr_rises);
    return 1;
  }
  if (c_reads_with_a_bit < c_reads_checked) {
    std::fprintf(stderr,
                 "FAIL: %ld color window reads compared and %ld against a word with a bit set;\n"
                 "      a check that only ever compares against zero passes a bridge stuck at zero\n",
                 c_reads_checked, c_reads_with_a_bit);
    return 1;
  }
  // And the maps have to hold something: a map of zeros is what a fabric
  // that kept nothing would answer with.
  if (map_nonzero < 48) {
    std::fprintf(stderr, "FAIL: only %ld of the %ld map bytes are non-zero\n", map_nonzero,
                 map_bytes);
    return 1;
  }
  // The two boards' maps must not be the SAME map, or one store answering
  // both would pass.
  int identical = 1;
  for (int c = 0; c < kColors && identical; ++c)
    for (int ch = 0; ch < kChannels; ++ch)
      if (map[0][c][ch] != map[1][c][ch]) {
        identical = 0;
        break;
      }
  if (identical) {
    std::fprintf(stderr, "FAIL: the two boards' maps are the same map in the reference\n");
    return 1;
  }

  std::printf(
      "ok: %ld ticks agree with muir's Tv::color() beside its Tv, through Busint, at every tick\n"
      "    %ld cycles on one backplane: %ld reads and %ld writes of the color board's registers,\n"
      "    %ld and %ld of the first board's; %ld and %ld of the color window and %ld and %ld of\n"
      "    the first board's, each at its own base in DDR and none in the other's region;\n"
      "    %ld and %ld of main memory, %ld that nothing answered; %ld answered reads compared at\n"
      "    -LOADMD; -XBUS.INTR up %ld times and down %ld, to the tick, as the OR of two boards\n"
      "    and %ld bytes of color map --- both boards', every color, out of a port no bus\n"
      "    cycle can reach\n",
      checked, cycles,
      c_reg_reads[0] + c_reg_reads[1] + c_reg_reads[2] + c_reg_reads[3] + c_reg_reads[4] +
          c_reg_reads[5] + c_reg_reads[6] + c_reg_reads[7],
      c_reg_writes[0] + c_reg_writes[1] + c_reg_writes[2] + c_reg_writes[3] + c_reg_writes[4] +
          c_reg_writes[5] + c_reg_writes[6] + c_reg_writes[7],
      n_reg_reads, n_reg_writes, c_fb_reads, c_fb_writes, n_fb_reads, n_fb_writes, main_reads,
      main_writes, nxm_cycles, reads_checked, intr_rises, intr_falls, map_bytes);

  return ConfigurationB();
}
