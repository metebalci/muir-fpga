// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The display controller against muir, through the whole memory path.
//
// The DUT is `cadr_memory_path` as the machine wires it --- the decode, the
// bus interface, the bridge and `rtl/machine/cadr_tv.sv` inside it --- driven on the
// cpu's side of the cables by `build/tv.golden`, which `golden/src/tv.rs`
// writes out of muir's own `simpletv::SimpleTv` through `busint::Busint`.
// No harness: the wiring under test is the wiring on the board.
//
// WHAT THIS HOLDS TO, at every one of the trace's 77 million ticks:
//
//   - -MEMGRANT, -MEMACK, -LOADMD and NXM TIMEOUT against `Busint`, which is
//     what puts the acknowledgement of a control-word read 140 ns after the
//     grant and of a write 80 --- muir's TV answers in no time of its own
//     --- and the four dead words between the display's registers and the
//     disk's on the NXM timer;
//   - MD, at -MEMACK's rise on every answered read, against what muir's
//     model gave: the mode register with the flag in bit 4, the sync RAM's
//     byte or its absence, the frame buffer's word, main memory's;
//   - -XBUS.INTR against `SimpleTv::interrupt`, rows and gaps alike, which
//     is where a frame a tick long or short, an enable ignored, a flag that
//     the write does not clock or the frame does not preset, all show;
//   - the memory port: every frame-buffer cycle reaches `mem_*` at
//     `DISPLAY_BASE` plus four times the window offset, and every main
//     memory cycle at `MAIN_BASE` plus four times the address, with the
//     trace's own word --- asserted at the port on the tick, and read back
//     through a modelled DDR keyed by the STIMULUS's address and filled
//     from the STIMULUS's word, never the DUT's.  CLAUDE.md's rule, and the
//     reason `bridge-writes-the-address-instead-of-the-data` is in the list.
//
// THE MODELLED DDR ANSWERS AT ONCE, as `tb/cadr_machine_tb.cpp` answers
// main memory at the instant muir's board would: that is what makes the
// timing comparable, the bridge being thin.  A word nothing wrote is poison
// injective in the address, so a read that went to the wrong word cannot
// come back right; the generator never reads a word the program did not
// write, so the poison shows only on a bug.
//
// THE ROWS ARE SPARSE AND THE CHECK IS NOT.  The trace has a row wherever
// anything moves and nothing between; here every gap is stepped a tick at a
// time with the inputs held and every output required to hold, so a frame
// of 3,091,200 ticks is compared at 3,091,200 ticks.  MCLK is made from the
// grid and cross-checked against the column on the rows that carry it.
//
// AND THE COUNTS ARE THE GENERATOR'S.  The header says how many cycles of
// each kind the program made and how many times the interrupt rose and
// fell; the run counts what it saw and requires the same, so a trace that
// stopped reaching something says so here rather than passing thinner.
//
// THE WINDOW'S READS ARE COUNTED SEPARATELY AND REQUIRED TO CARRY A WORD.
// The frame buffer is the one thing in the window a program reads BACK ---
// a run light is a blind write, a character is a read, a merge and a write
// --- so "MD agreed on every answered read" is not enough on its own: a
// trace that stopped reading the window, or a reference that started
// answering zero there, would both go on passing.  The run therefore counts
// the window reads it compared, requires one per window read the header
// says the program made, and requires that what it compared them against
// had a bit set.  CLAUDE.md's rule: a check that only ever compares against
// zero passes a bridge stuck at zero.
//
// AND THEN CONFIGURATION B: THE WINDOW AGAINST A MEMORY THAT TAKES TIME.
// The trace above is muir's, and muir's TV answers a buffer word in no time
// of its own, so the modelled DDR must answer in the same tick for the
// acknowledgement to land where the reference puts it.  That leaves one
// thing unexercised anywhere in `make check`: this is the only check that
// ever puts the display's base on the memory port, and it was also the only
// one whose memory answered at once --- `tb/cadr_memory_path_tb.cpp` waits
// six ticks and `tb/cadr_ddr_boot_tb.cpp` four to twenty-six, but neither
// ever addresses the window.  So a bridge that acknowledged a window cycle
// BEFORE DDR had answered it had nothing looking at it, where the same bug
// at main memory's base is caught twice.
//
// So after the trace the run builds a second machine and drives window
// cycles at it directly, with a modelled DDR thirty-seven ticks behind the
// request:
//
//   - a word written and read back at the window's first word, at the last
//     word of the picture (23,111 --- 768 x 963 bits at one bit a pixel is
//     23,112 words of the 32,768), at the first word past the picture and
//     at the last word of the window;
//   - the reads taken in the reverse order of the writes, so that a read
//     giving the word before it cannot come back right;
//   - a word the program never wrote, which must come back as the modelled
//     DDR's poison rather than as zero: a bridge answering out of its own
//     idea of an unwritten word would pass a check that only ever read
//     words it had written;
//   - one word above the window and one below it, which nothing answers ---
//     the NXM timer ends both, MD is zero, and NO cycle reaches the port;
//   - and the window's first word once more at the end, after all of that.
//
// Every window cycle's byte address is asserted at the port against
// `DISPLAY_BASE + 4 * offset`, and the run fails if one of them lands in
// main memory's region instead.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "Vcadr_memory_path.h"
#include "verilated.h"

namespace {

// rtl/plumbing/cadr_ddr_map.sv's two bases, and the display's window as
// simpletv::BUFFER / BUFFER_WORDS and CONTROL / CONTROL_WORDS have them.
constexpr uint32_t kMainBase = 0x1800'0000u;
constexpr uint32_t kDisplayBase = 0x1C00'0000u;
constexpr uint32_t kBuffer = 017000000u;
constexpr uint32_t kBufferWords = 0100000u;
constexpr uint32_t kControl = 017377760u;
constexpr uint32_t kControlWords = 8u;
constexpr long kMicrocycle = 29;

// The picture: `simpletv::WIDTH` x `HEIGHT` at one bit a pixel, 768 across
// and 963 down, is 24 words to a line and 23,112 words of the window's
// 32,768.  The fabric knows nothing of it --- the window is one range and
// the decode is on its top seven address bits --- but it is where the
// screen ends, so configuration B reads the word on each side of it.
constexpr uint32_t kVisibleWords = 23112u;

// How far behind the request configuration B's modelled DDR answers.  Not a
// multiple of the microcycle, so the answer lands at a different phase on
// every cycle, and far inside the NXM timer's own thousand ticks.
constexpr long kLatency = 37;

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
bool InControl(unsigned phys) { return phys >= kControl && phys < kControl + kControlWords; }

// Where a word of the stimulus's address lives in DDR.
uint32_t ByteAddress(unsigned phys) {
  return InWindow(phys) ? kDisplayBase + ((phys - kBuffer) << 2) : kMainBase + (phys << 2);
}

// What the modelled DDR holds at a byte address nothing wrote: injective
// in the address, as `tb/cadr_memory_path_tb.cpp`'s is.
uint32_t Untouched(uint32_t byte_addr) {
  return (0x9E3779B9u * ((byte_addr >> 2) + 1u)) ^ 0xA5A5A5A5u;
}

// Configuration B's own word for an offset, injective in the offset AND in
// how many times that offset has been written --- `golden/src/tv.rs`'s own
// rule --- and from a different family from the trace's, so that a word the
// trace left behind could not read back right either.  Never zero for any
// offset the program uses, which the run asserts rather than assumes.
uint32_t WindowWord(uint32_t off, uint32_t nth) {
  return ((off + 1u) * 0x517C'C1DAu) ^ (nth * 0x2545'F491u) ^ 0xC3A5'96E7u;
}

int Fail(long tick, const char *what, unsigned long got, unsigned long want, const Row &r) {
  std::fprintf(stderr,
               "tick %ld: %s is %lu (0x%lx), reference says %lu (0x%lx)\n"
               "  inputs: n_memrq=%d wrcyc=%d phys=0%o wdata=0x%x xinit=%d (row at tick %ld)\n",
               tick, what, got, got, want, want, r.n_memrq, r.wrcyc, r.phys, r.wdata, r.xinit,
               r.tick);
  return 1;
}

// ------------------------------------------------------------------------
// CONFIGURATION B: the window against a memory that takes time
// ------------------------------------------------------------------------
//
// The head of this file has the argument.  In short: the trace above is
// muir's and its modelled DDR must answer in the same tick, so the one
// thing it cannot hold is what happens between a window cycle's request and
// DDR's answer --- and this is the only check in the tree that ever puts
// the display's base on the memory port at all.
//
// Nothing here is compared against muir, because muir's TV has no DDR
// behind it to be late.  What it is held to is the property: a word written
// into the window is the word read back out of it, at the display's base,
// however long the memory takes.

// What one tick of configuration B saw.  Read after the edge, as
// configuration A reads its outputs.
struct Tick {
  int n_memack, timed_out, mem_req, mem_write;
  uint32_t rdata, mem_addr;
};

// What one bus cycle came to.
struct Answer {
  bool answered, timed_out, port_seen;
  uint32_t md, port_addr;
  long port_cycles;
};

int BFail(const char *what, unsigned long got, unsigned long want) {
  std::fprintf(stderr, "configuration B: %s is %lu (0x%lx), wanting %lu (0x%lx)\n", what, got, got,
               want, want);
  return 1;
}

int ConfigurationB() {
  auto *dut = new Vcadr_memory_path;
  dut->clk = 0;
  dut->rst = 1;
  dut->xbus_init = 0;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
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

  std::map<uint32_t, uint32_t> ddr;  // byte address -> word, from the stimulus
  long tick = 0, port_cycles = 0, port_display = 0, port_main = 0;
  int bad = 0;

  // The modelled DDR's one transaction: taken at the request, answered
  // `kLatency` ticks later, and the port required to hold still between the
  // two --- which is the bus's own 80 ns rule seen from the other end.
  bool in_flight = false;
  long waited = 0;
  uint32_t held_addr = 0;
  int held_write = 0;

  auto step = [&]() -> Tick {
    dut->rst = (tick < 4);
    dut->mclk = (tick % kMicrocycle) == 0;
    dut->clk = 1;
    dut->eval();

    dut->mem_done = 0;
    if (dut->mem_req) {
      if (!in_flight) {
        in_flight = true;
        waited = 0;
        held_addr = dut->mem_addr;
        held_write = dut->mem_write;
        ++port_cycles;
        if (held_addr >= kDisplayBase && held_addr < kDisplayBase + (kBufferWords << 2))
          ++port_display;
        else if (held_addr >= kMainBase && held_addr < kDisplayBase)
          ++port_main;
      } else {
        ++waited;
      }
      if (waited == kLatency) {
        if (dut->mem_addr != held_addr)
          bad += BFail("the byte address under a request the memory has not answered", dut->mem_addr,
                       held_addr);
        if (dut->mem_write != held_write)
          bad += BFail("the direction under a request the memory has not answered", dut->mem_write,
                       held_write);
        if (held_write) {
          ddr[held_addr] = dut->mem_wdata;
        } else {
          auto it = ddr.find(held_addr);
          dut->mem_rdata = (it == ddr.end()) ? Untouched(held_addr) : it->second;
        }
        dut->mem_done = 1;
        in_flight = false;
      }
    } else {
      in_flight = false;
    }
    dut->eval();

    Tick t{dut->n_memack, dut->timed_out, dut->mem_req, dut->mem_write, dut->rdata, dut->mem_addr};
    dut->clk = 0;
    dut->eval();
    ++tick;
    return t;
  };

  // One bus cycle on the cpu's side of the cables, driven the way the
  // trace drives one: -MEMRQ down with the address and the word standing,
  // held until -MEMACK, then six ticks and a microcycle of gap.
  auto cycle = [&](bool write, uint32_t phys, uint32_t wdata) -> Answer {
    Answer a{false, false, false, 0u, 0u, 0};
    const long before = port_cycles;
    dut->phys = phys;
    dut->wrcyc = write ? 1 : 0;
    dut->wdata = wdata;
    dut->n_memrq = 0;
    int last_ack = 1;
    // Longer than the NXM timer, which is five periods of the 74LS124 at
    // REQTIM 0A01 and about a thousand ticks.
    for (long guard = 0; guard < 4000; ++guard) {
      const Tick t = step();
      if (t.mem_req && !a.port_seen) {
        a.port_seen = true;
        a.port_addr = t.mem_addr;
      }
      if (!t.n_memack && last_ack) {
        a.answered = true;
        a.md = t.rdata;
        a.timed_out = t.timed_out;
        break;
      }
      last_ack = t.n_memack;
    }
    for (int i = 0; i < 6; ++i) step();
    dut->n_memrq = 1;
    for (int i = 0; i < 2 * kMicrocycle; ++i) step();
    a.port_cycles = port_cycles - before;
    return a;
  };

  long reads_compared = 0, window_cycles = 0;
  uint32_t last_expected = 0;

  // A cycle to the window: answered, at the display's base, one transaction
  // on the port, and on a read the word that was put there.
  auto window = [&](const char *what, bool write, uint32_t off, uint32_t word) {
    const Answer a = cycle(write, kBuffer + off, write ? word : 0u);
    ++window_cycles;
    const uint32_t want_addr = kDisplayBase + (off << 2);
    if (!a.answered) {
      std::fprintf(stderr, "configuration B: nothing acknowledged %s\n", what);
      ++bad;
    }
    if (a.timed_out) {
      std::fprintf(stderr, "configuration B: the NXM timer ended %s\n", what);
      ++bad;
    }
    if (!a.port_seen) {
      std::fprintf(stderr, "configuration B: %s never reached the memory port\n", what);
      ++bad;
    } else if (a.port_addr != want_addr) {
      std::fprintf(stderr, "configuration B: %s went to 0x%08x on the memory port, wanting 0x%08x\n",
                   what, a.port_addr, want_addr);
      ++bad;
    }
    if (a.port_cycles != 1) {
      std::fprintf(stderr, "configuration B: %s made %ld transactions on the port, wanting one\n",
                   what, a.port_cycles);
      ++bad;
    }
    if (!write) {
      if (a.md != word) {
        std::fprintf(stderr, "configuration B: %s read back 0x%08x, wanting 0x%08x\n", what, a.md,
                     word);
        ++bad;
      } else {
        ++reads_compared;
      }
      // The word a read is held to must never be zero, and never the word
      // the read before it was held to: a bridge stuck at zero, and one
      // giving the word before, both have to fail somewhere.
      if (word == 0 || word == last_expected) {
        std::fprintf(stderr, "configuration B: %s is held to 0x%08x, which tests nothing\n", what,
                     word);
        ++bad;
      }
      last_expected = word;
    }
  };

  // And one to an address nothing answers: the timer ends it, MD is zero,
  // and no cycle reaches the port at all.
  auto nothing_answers = [&](const char *what, uint32_t phys) {
    const Answer a = cycle(false, phys, 0u);
    if (!a.answered || !a.timed_out) {
      std::fprintf(stderr, "configuration B: %s was answered rather than timed out\n", what);
      ++bad;
    }
    if (a.md != 0) {
      std::fprintf(stderr, "configuration B: %s gave MD 0x%08x, wanting zero\n", what, a.md);
      ++bad;
    }
    if (a.port_cycles != 0) {
      std::fprintf(stderr, "configuration B: %s made %ld transactions on the port, wanting none\n",
                   what, a.port_cycles);
      ++bad;
    }
  };

  // Past reset, and a microcycle or two for the held decodes to settle.
  for (int i = 0; i < 4 * kMicrocycle; ++i) step();

  // The window's four words: its first, the last of the picture, the first
  // past the picture, and its last.
  const uint32_t offs[4] = {0u, kVisibleWords - 1u, kVisibleWords, kBufferWords - 1u};
  const char *names[4] = {"the window's first word", "the last word of the picture",
                          "the first word past the picture", "the last word of the window"};
  char what[96];
  for (int i = 0; i < 4; ++i) {
    std::snprintf(what, sizeof what, "a write of %s", names[i]);
    window(what, true, offs[i], WindowWord(offs[i], 0));
  }
  // Read back in the reverse order, so no read can be right by giving the
  // word the read before it gave.
  for (int i = 3; i >= 0; --i) {
    std::snprintf(what, sizeof what, "a read of %s", names[i]);
    window(what, false, offs[i], WindowWord(offs[i], 0));
  }

  // A word of the window the program never wrote: it must come back as what
  // the modelled DDR holds there.  A bridge answering out of its own idea
  // of an unwritten word --- zero, or the word it last returned --- passes
  // a check that only ever reads words it has written.
  {
    const uint32_t off = 4095u;
    const uint32_t poison = Untouched(kDisplayBase + (off << 2));
    for (int i = 0; i < 4; ++i)
      if (poison == WindowWord(offs[i], 0)) {
        std::fprintf(stderr, "configuration B: the poison at offset %u is a word the program wrote\n",
                     off);
        ++bad;
      }
    window("a read of a word of the window nothing wrote", false, off, poison);
  }

  // The same offset written a second time and read back: a bridge that kept
  // the word it gave last time cannot pass this.
  window("a second write of the last word of the picture", true, offs[1], WindowWord(offs[1], 1));
  window("a read of the last word of the picture, rewritten", false, offs[1], WindowWord(offs[1], 1));

  // The window's two edges on the outside.
  nothing_answers("a read one word past the window", kBuffer + kBufferWords);
  nothing_answers("a read of the word below the window", kBuffer - 1);

  // And the window's first word once more, after all of that.
  window("a read of the window's first word at the end", false, offs[0], WindowWord(offs[0], 0));

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: configuration B, %d wrong over %ld ticks\n", bad, tick);
    return 1;
  }
  if (reads_compared != 7 || window_cycles != 12 || port_display != 12 || port_main != 0) {
    std::fprintf(stderr,
                 "FAIL: configuration B ran thin: %ld reads compared of seven, %ld window cycles of\n"
                 "      twelve, %ld at the display's base and %ld in main memory's region\n",
                 reads_compared, window_cycles, port_display, port_main);
    return 1;
  }

  std::printf(
      "ok: configuration B, %ld ticks with the memory %ld ticks behind every request:\n"
      "    %ld cycles to the window, all at the display's base and none in main memory's region;\n"
      "    %ld reads compared --- the window's first word, the last of the picture and the first\n"
      "    past it, the last of the window, one word nothing wrote, one rewritten, and the first\n"
      "    word again at the end; and the words on either side of the window timed out with MD zero\n",
      tick, kLatency, window_cycles, reads_compared);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/tv.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // ---- the trace and its header ------------------------------------------
  std::map<std::string, std::vector<long>> hdr;
  std::vector<Row> rows;
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#') {
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
    if (std::sscanf(line, "%ld %d %d %u %u %d %d %d %d %d %d %u %d", &r.tick, &r.n_memrq,
                    &r.wrcyc, &r.phys, &r.wdata, &r.mclk, &r.xinit, &r.n_memgrant, &r.n_memack,
                    &r.n_loadmd, &r.timed_out, &r.rdata, &r.intr) != 13) {
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

  auto want_h = [&](const char *key, size_t i = 0) -> long {
    auto it = hdr.find(key);
    if (it == hdr.end() || it->second.size() <= i) {
      std::fprintf(stderr, "FAIL: %s has no `%s` in its header\n", path, key);
      std::exit(1);
    }
    return it->second[i];
  };
  // The module's own constants against the generator's header: a muir that
  // moved says so here and not as a mismatch a frame in.
  struct { const char *what; long got, want; } consts[] = {
      {"frame_ticks", want_h("frame_ticks"), 3091200L},
      {"microcycle_ticks", want_h("microcycle_ticks"), kMicrocycle},
      {"setup_ticks", want_h("setup_ticks"), 16L},
      {"deskew_ticks", want_h("deskew_ticks"), 12L},
      {"buffer", want_h("buffer"), (long)kBuffer},
      {"buffer_words", want_h("buffer_words"), (long)kBufferWords},
      {"control", want_h("control"), (long)kControl},
      {"boards", want_h("boards"), 32L},
  };
  int wrong = 0;
  for (const auto &c : consts)
    if (c.got != c.want) {
      std::fprintf(stderr, "FAIL: the trace says %s is %ld and the fabric has %ld\n", c.what,
                   c.got, c.want);
      ++wrong;
    }
  if (wrong) return 1;
  const long last_tick = want_h("last_tick");
  const long frame_ticks = want_h("frame_ticks");

  // ---- the DUT -----------------------------------------------------------
  auto *dut = new Vcadr_memory_path;
  dut->clk = 0;
  dut->rst = 1;
  dut->xbus_init = 0;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
  // The seam for the slaves outside, the register block's read side and the
  // channel, all quiet and said so.
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

  std::map<uint32_t, uint32_t> ddr;  // byte address -> word, from the stimulus

  long checked = 0;
  int bad = 0;
  long reads_checked = 0, writes_seen = 0, reads_seen = 0;
  long fb_reads = 0, fb_writes = 0, main_reads = 0, main_writes = 0, nxm_cycles = 0;
  // The window's own reads, counted where they are COMPARED rather than
  // where the cycle begins, and how many of them the reference gave a word
  // with a bit set.  See the head of the file.
  long fb_reads_checked = 0, fb_reads_with_a_bit = 0;
  // Where the port went on a window cycle: the display's region, or main
  // memory's.  The equality against `ByteAddress` below is what fails
  // first, but the count is what says in one number that no window cycle
  // ever reached the wrong region.
  long fb_port_display = 0, fb_port_main = 0;
  long reg_reads[8] = {0}, reg_writes[8] = {0};
  long intr_rises = 0, intr_falls = 0, inits = 0, cycles = 0, timeouts = 0;
  int intr_last = 0, memack_last = 1, memrq_last = 1, timed_out_last = 0;

  // One tick: the inputs are what the edge samples, the outputs what is seen
  // after it.  `r` is the row whose inputs are in force --- the last one
  // read --- and `exp` the outputs that must hold: the row's own on its
  // tick, and still the row's in the gap after it.
  auto step = [&](long tick, const Row &r, bool on_row) {
    dut->rst = (tick == 0);
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

    // DDR answers on the tick the bridge asks, and the port is held to the
    // stimulus while it does.
    const int req = dut->mem_req;
    const uint32_t addr = dut->mem_addr;
    const int wr = dut->mem_write;
    const uint32_t want_addr = ByteAddress(r.phys);
    dut->mem_done = req;
    if (req) {
      if (addr != want_addr) bad += Fail(tick, "the byte address on the memory port", addr, want_addr, r);
      if (wr != r.wrcyc) bad += Fail(tick, "the direction on the memory port", wr, r.wrcyc, r);
      if (!wr) {
        auto it = ddr.find(addr);
        dut->mem_rdata = (it == ddr.end()) ? Untouched(addr) : it->second;
      }
    }
    dut->eval();

    if (dut->n_memgrant != r.n_memgrant) bad += Fail(tick, "-MEMGRANT", dut->n_memgrant, r.n_memgrant, r);
    if (dut->n_memack != r.n_memack) bad += Fail(tick, "-MEMACK", dut->n_memack, r.n_memack, r);
    if (dut->n_loadmd != r.n_loadmd) bad += Fail(tick, "-LOADMD", dut->n_loadmd, r.n_loadmd, r);
    if (dut->timed_out != r.timed_out) bad += Fail(tick, "NXM TIMEOUT", dut->timed_out, r.timed_out, r);
    if (dut->tv_intr != r.intr) bad += Fail(tick, "-XBUS.INTR", dut->tv_intr, r.intr, r);

    if (req && wr) {
      if (dut->mem_wdata != r.wdata) bad += Fail(tick, "the word on the memory port", dut->mem_wdata, r.wdata, r);
      ddr[want_addr] = r.wdata;
      ++writes_seen;
    }
    if (req && !wr) ++reads_seen;
    if (req && InWindow(r.phys)) {
      if (addr >= kDisplayBase && addr < kDisplayBase + (kBufferWords << 2)) ++fb_port_display;
      else if (addr >= kMainBase && addr < kDisplayBase) ++fb_port_main;
    }

    // MD at -MEMACK's rise: the word muir's model gave, or zero where nothing
    // answered.
    if (!r.n_memack && memack_last) {
      if (r.timed_out) {
        if (dut->rdata != 0) bad += Fail(tick, "MEM<31:0> on a cycle nothing answered", dut->rdata, 0, r);
      } else if (!r.wrcyc) {
        if (dut->rdata != r.rdata) bad += Fail(tick, "MD", dut->rdata, r.rdata, r);
        else ++reads_checked;
        if (InWindow(r.phys)) {
          ++fb_reads_checked;
          if (r.rdata != 0) ++fb_reads_with_a_bit;
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
    // A cycle begins where -MEMRQ falls; count it by what it reaches.
    if (!r.n_memrq && memrq_last) {
      ++cycles;
      if (InControl(r.phys)) (r.wrcyc ? reg_writes : reg_reads)[r.phys - kControl]++;
      else if (InWindow(r.phys)) (r.wrcyc ? fb_writes : fb_reads)++;
      else if (r.phys < (32u << 16)) (r.wrcyc ? main_writes : main_reads)++;
      else ++nxm_cycles;
    }
    memrq_last = r.n_memrq;

    dut->clk = 0;
    dut->eval();
    ++checked;
  };

  long tick = 0;
  for (size_t i = 0; i < rows.size() && bad < 20; ++i) {
    const Row &r = rows[i];
    if (r.tick < tick) {
      std::fprintf(stderr, "%s: rows out of order at tick %ld\n", path, r.tick);
      return 2;
    }
    // The gap before this row: the previous row's inputs and outputs hold.
    if (i > 0) {
      const Row &held = rows[i - 1];
      for (; tick < r.tick && bad < 20; ++tick) step(tick, held, false);
    }
    step(r.tick, r, true);
    tick = r.tick + 1;
  }
  // And the tail, to the trace's last tick.
  for (; tick <= last_tick && bad < 20; ++tick) step(tick, rows.back(), false);

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, checked);
    return 1;
  }

  // ---- what the run saw, against what the generator says it made --------
  int thin = 0;
  auto same = [&](const char *what, long got, long want) {
    if (got != want) {
      std::fprintf(stderr, "FAIL: the run saw %ld %s and the trace's header says %ld\n", got, what, want);
      ++thin;
    }
  };
  same("cycles", cycles, want_h("cycles"));
  for (int k = 0; k < 8; ++k) {
    char what[64];
    std::snprintf(what, sizeof what, "reads of register %d", k);
    same(what, reg_reads[k], want_h("register_reads", k));
    std::snprintf(what, sizeof what, "writes of register %d", k);
    same(what, reg_writes[k], want_h("register_writes", k));
  }
  same("frame-buffer reads", fb_reads, want_h("buffer_reads"));
  same("frame-buffer writes", fb_writes, want_h("buffer_writes"));
  same("main memory reads", main_reads, want_h("main_reads"));
  same("main memory writes", main_writes, want_h("main_writes"));
  same("cycles nothing answered", nxm_cycles, want_h("nxm_cycles"));
  same("timeouts", timeouts, want_h("nxm_cycles"));
  same("-XBUS INIT pulses", inits, want_h("inits"));
  same("rises of -XBUS.INTR", intr_rises, want_h("intr_rises"));
  same("falls of -XBUS.INTR", intr_falls, want_h("intr_falls"));
  // Every answered read was compared, and every frame-buffer and main
  // memory cycle reached the port, once.
  same("answered reads compared", reads_checked, cycles - nxm_cycles - (long)(fb_writes + main_writes) -
                                                     (reg_writes[0] + reg_writes[1] + reg_writes[2] + reg_writes[3] +
                                                      reg_writes[4] + reg_writes[5] + reg_writes[6] + reg_writes[7]));
  same("words written through the port", writes_seen, fb_writes + main_writes);
  same("words read through the port", reads_seen, fb_reads + main_reads);
  // Every window read was compared, not merely seen, and every window cycle
  // went to the display's region.
  same("window reads compared at -LOADMD", fb_reads_checked, fb_reads);
  same("window cycles at the display's base", fb_port_display, fb_reads + fb_writes);
  same("window cycles that reached main memory's region", fb_port_main, 0);
  if (thin) return 1;
  if (intr_rises < 12 || fb_writes < 10 || reg_writes[1] < 10 || nxm_cycles < 3) {
    std::fprintf(stderr, "FAIL: the trace is too thin to hold anything: %ld interrupt rises, %ld buffer writes, "
                         "%ld sync writes, %ld timeouts\n", intr_rises, fb_writes, reg_writes[1], nxm_cycles);
    return 1;
  }
  // And what those window reads were compared AGAINST had a bit set.  A
  // reference answering zero in the window, or a program that stopped
  // writing before it read, would leave a check that a bridge stuck at zero
  // walks straight through.
  if (fb_reads_checked < 10 || fb_reads_with_a_bit < fb_reads_checked) {
    std::fprintf(stderr,
                 "FAIL: %ld window reads were compared and %ld of them against a word with a bit set;\n"
                 "      a check that only ever compares against zero passes a bridge stuck at zero\n",
                 fb_reads_checked, fb_reads_with_a_bit);
    return 1;
  }

  std::printf(
      "ok: %ld ticks, %ld frames, agree with muir's SimpleTv through Busint at every tick\n"
      "    %ld cycles: %ld reads and %ld writes of the mode register, %ld and %ld of the sync RAM's data,\n"
      "    %ld and %ld of the frame buffer through DDR at the display's base, %ld and %ld of main memory,\n"
      "    %ld that nothing answered; %ld answered reads compared at -LOADMD; -XBUS.INTR up %ld times and\n"
      "    down %ld, to the tick, over %ld -XBUS INIT pulses\n"
      "    of those, %ld reads of the window compared against muir's own word, every one with a bit set,\n"
      "    and all %ld window cycles at the display's base with none in main memory's region\n",
      checked, last_tick / frame_ticks, cycles, reg_reads[0], reg_writes[0], reg_reads[1], reg_writes[1],
      fb_reads, fb_writes, main_reads, main_writes, nxm_cycles, reads_checked, intr_rises, intr_falls, inits,
      fb_reads_checked, fb_port_display);

  return ConfigurationB();
}
