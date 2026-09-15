// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_display_out` against a modeled DDR, for a whole frame, read the way
// a monitor reads it.
//
// **THE CHECK RECOVERS THE RASTER FROM THE SYNCS AND NOT FROM ANY COUNTER
// INSIDE THE MODULE.**  It watches `de`, `hsync` and `vsync` exactly as a
// monitor does, counts pixels from the leading edge of `de` and lines from
// the leading edge of `vsync`, and only then asks what color the pixel at
// that position should be.  So the module's pipeline depth is not something
// this has to know, and a change to it is not a change here.  A check that
// reached into the device for `hc` and `vc` would agree with the device
// about where it was, which is the failure this repository calls writing a
// check to confirm rather than to compare.
//
// **THE TWO CLOCKS ARE RUN AT THEIR REAL AND DELIBERATELY INCOMMENSURATE
// PERIODS**, 10.000 ns for the memory side and 9.275 ns for the raster, on a
// picosecond timeline, so that the edges of one fall at every phase of the
// other over a frame.  A testbench that clocked both from one counter would
// exercise one alignment of the two domains and call the line buffer
// checked.
//
// THE MEMORY IS POISONED INJECTIVELY IN THE ADDRESS, so that a fetch of the
// wrong line, a swapped pair of words inside a beat, an off-by-one in the
// word index or a bank that never changes all produce a picture that
// disagrees rather than a picture that happens to match.  Against a memory of
// zeros every one of those faults draws the same black screen.
//
// Two configurations:
//
//   A  the port answers at its ordinary speed.  A whole frame is compared
//      pixel for pixel --- the picture against the words it comes from, the
//      border black --- and the raster's own figures are counted rather than
//      sampled.
//
//   B  the port is slowed until it cannot keep up.  **A STIMULUS FAST
//      ENOUGH HIDES THE RACE IT EXISTS TO SHOW**: at the real speed the
//      fetcher is a whole line ahead and the underrun path is dead code no
//      mutation can reach.  Slowed, the raster must report the underrun and
//      show those lines BLACK rather than showing the words that did arrive.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <vector>

#include "Vcadr_display_out.h"
#include "verilated.h"

namespace {

// The mode, as `cadr_display_out.sv` has it: VESA DMT 1280x1024 at 60 Hz.
constexpr int kHActive = 1280, kHFront = 48, kHSync = 112, kHBack = 248;
constexpr int kVActive = 1024, kVFront = 1,  kVSync = 3,   kVBack = 38;
constexpr int kHTotal = kHActive + kHFront + kHSync + kHBack;   // 1688
constexpr int kVTotal = kVActive + kVFront + kVSync + kVBack;   // 1066

constexpr int kPicW = 768, kPicH = 963, kWordsPerLine = 24;
constexpr int kPicX0 = (kHActive - kPicW) / 2;   // 256
constexpr int kPicY0 = (kVActive - kPicH) / 2;   // 30
constexpr int kBeats = kWordsPerLine / 2;        // 12
constexpr int kLineBytes = kWordsPerLine * 4;    // 96

constexpr uint32_t kBase = 0x1C000000u;

// Picoseconds.  Not a common multiple of each other, on purpose.
constexpr uint64_t kClkHalf  = 5000;    // 100 MHz
constexpr uint64_t kPclkHalf = 4638;    // 107.8125 MHz, to the picosecond

int bad = 0;
long pclk_ticks = 0;

void Fail(const char *fmt, ...) {
  if (++bad <= 25) {
    va_list ap;
    va_start(ap, fmt);
    std::fprintf(stderr, "FAIL: ");
    std::vfprintf(stderr, fmt, ap);
    std::fprintf(stderr, "\n");
    va_end(ap);
  }
}

// Injective in the word index and never zero: multiplying by an odd constant
// is a bijection on 32 bits, so no two words of the display's region share a
// value.  The same idiom `cadr_axi_widen_tb.cpp` uses.
uint32_t Poison(uint32_t word) {
  return 0xF0000000u ^ (word * 2654435761u);
}

// What the picture should be: muir's `Tv::pixel`, bit 0 of a word the
// leftmost of the 32 pixels it carries.
bool Lit(int line, int x) {
  const uint32_t bit = static_cast<uint32_t>(line) * kWordsPerLine * 32u +
                       static_cast<uint32_t>(x);
  return ((Poison(bit / 32u) >> (bit % 32u)) & 1u) != 0u;
}

// --------------------------------------------------------------- the slave
//
// An AXI3 read slave on `S_AXI_HP3`, with the protocol asserted rather than
// assumed.
struct Slave {
  // How long the address waits for ready, and how long each beat waits.
  int ar_wait = 0;
  int beat_wait = 0;

  bool open = false;
  uint32_t addr = 0;
  int len = 0, beat = 0;
  int wait = 0;

  long bursts = 0, beats = 0, ar_handshakes = 0, rlasts = 0;
  long lines = 0, split_lines = 0, line_beats = 0, bursts_this_line = 0;
  std::vector<uint32_t> line_addrs;

  // Sampled at the edge, so a handshake is read with the values that were
  // present when it happened.
  uint8_t s_arvalid = 0, s_arready = 0, s_rvalid = 0, s_rready = 0, s_rlast = 0;

  uint64_t BeatData(uint32_t a) const {
    const uint32_t w = (a - kBase) / 4u;
    return static_cast<uint64_t>(Poison(w)) |
           (static_cast<uint64_t>(Poison(w + 1)) << 32);
  }

  void Drive(Vcadr_display_out *dut) {
    if (!open && dut->m_arvalid) {
      if (wait > 0) { --wait; dut->m_arready = 0; }
      else dut->m_arready = 1;
    } else {
      dut->m_arready = 0;
    }

    if (open && wait == 0) {
      dut->m_rvalid = 1;
      dut->m_rdata  = BeatData(addr + static_cast<uint32_t>(8 * beat));
      dut->m_rresp  = 0;
      dut->m_rlast  = (beat == len) ? 1 : 0;
    } else {
      dut->m_rvalid = 0;
      dut->m_rdata = 0; dut->m_rresp = 0; dut->m_rlast = 0;
    }
  }

  void Sample(Vcadr_display_out *dut) {
    s_arvalid = dut->m_arvalid; s_arready = dut->m_arready;
    s_rvalid = dut->m_rvalid;   s_rready = dut->m_rready;
    s_rlast = dut->m_rlast;
    if (open && wait > 0) --wait;
  }

  void AfterEdge(Vcadr_display_out *dut) {
    if (s_arvalid && s_arready) {
      ++ar_handshakes;
      if (open) Fail("a second read address while a burst was open");
      addr = dut->m_araddr;
      len  = dut->m_arlen;
      if (dut->m_arsize != 3) Fail("ARSIZE %u, want 3 (eight bytes)", dut->m_arsize);
      if (dut->m_arburst != 1) Fail("ARBURST %u, want INCR", dut->m_arburst);
      // A burst runs to the end of the line or to the next 4 KB boundary,
      // whichever comes first.  Computed here from the address and from how
      // much of the line has already arrived, independently of how the
      // module works it out.
      {
        const long done = ((addr - kBase) % kLineBytes == 0u) ? 0 : line_beats;
        const long owed = kBeats - done;
        const long to_bound = (4096 - static_cast<long>(addr & 0xFFFu)) / 8;
        const long want = (owed < to_bound) ? owed : to_bound;
        if (len + 1 != want)
          Fail("ARLEN %d at %08x, want %ld beats", len, addr, want);
      }
      if (addr % 8u) Fail("address %08x is not beat aligned", addr);
      const uint32_t last = addr + static_cast<uint32_t>(8 * len) + 7u;
      if ((addr >> 12) != (last >> 12)) Fail("burst at %08x crosses a 4 KB boundary", addr);

      // A burst either starts a line or continues one that a 4 KB boundary
      // cut short.  Twelve beats a line either way.
      if ((addr - kBase) % kLineBytes == 0u) {
        if (lines > 0 && line_beats != kBeats)
          Fail("a line was fetched in %ld beats, want %d", line_beats, kBeats);
        if (bursts_this_line > 1) ++split_lines;
        ++lines;
        line_beats = 0;
        bursts_this_line = 0;
        line_addrs.push_back(addr);
      } else {
        if (bursts_this_line == 0)
          Fail("burst at %08x continues a line nothing started", addr);
        // A continuation must resume exactly where the last burst stopped,
        // and the last burst must have stopped at a 4 KB boundary.
        if ((addr & 0xFFFu) != 0u)
          Fail("burst at %08x continues a line but is not at a page boundary", addr);
      }
      ++bursts_this_line;

      open = true; beat = 0; ++bursts;
      wait = beat_wait;
    }
    if (s_rvalid && s_rready) {
      ++beats;
      ++line_beats;
      if (!open) Fail("a data beat with no burst open");
      if (s_rlast) {
        ++rlasts;
        if (beat != len) Fail("RLAST on beat %d of %d", beat, len);
        open = false;
        wait = ar_wait;
      } else {
        if (beat == len) Fail("no RLAST on the burst's last beat");
        ++beat;
        wait = beat_wait;
      }
    }
  }
};

// -------------------------------------------------------------- the monitor
//
// What a display does with the three signals it is given.
struct Monitor {
  int de_prev = 0, hs_prev = 0, vs_prev = 0;
  int x = 0, y = -1;
  long since_hs = -1, since_vs_lines = -1;
  long hs_high = 0, vs_high_lines = 0;
  long line_len = -1, de_this_line = 0;
  long lines_this_frame = -1, active_lines = 0;

  long frames = 0;
  bool counting = false;

  // Geometry, counted rather than sampled.
  std::set<long> line_lengths, hs_widths, de_widths, hs_to_de;
  std::set<long> frame_lengths, vs_widths, active_per_frame;
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  // The poison must actually be injective over the words this reads, and
  // must actually make a picture: a memory whose bits are all one way tests
  // nothing.  Both asserted rather than assumed.
  {
    std::set<uint32_t> seen;
    long lit = 0;
    for (int w = 0; w < kPicH * kWordsPerLine; w++) {
      seen.insert(Poison(static_cast<uint32_t>(w)));
      for (int b = 0; b < 32; b++) lit += (Poison(static_cast<uint32_t>(w)) >> b) & 1u;
    }
    if (seen.size() != static_cast<size_t>(kPicH * kWordsPerLine))
      Fail("the poison collides: %zu distinct words for %d", seen.size(),
           kPicH * kWordsPerLine);
    const long total = static_cast<long>(kPicH) * kWordsPerLine * 32;
    if (lit < total / 3 || lit > 2 * total / 3)
      Fail("the poison makes %ld lit pixels of %ld, which is not a picture",
           lit, total);
  }

  struct Result { long underruns; long black_lines; long compared; long bursts;
                  long splits; long lines; };

  auto run = [&](int ar_wait, int beat_wait, long frames_wanted,
                 bool compare_pixels, Result *res) {
    auto *dut = new Vcadr_display_out;
    Slave slave;
    slave.ar_wait = ar_wait;
    slave.beat_wait = beat_wait;
    Monitor mon;

    dut->clk = 0; dut->pclk = 0; dut->rst = 1; dut->prst = 1;
    dut->m_arready = 0; dut->m_rdata = 0; dut->m_rresp = 0;
    dut->m_rlast = 0; dut->m_rvalid = 0;
    dut->eval();

    uint64_t t = 0, next_clk = kClkHalf, next_pclk = kPclkHalf;
    int clk_v = 0, pclk_v = 0;
    long black_lines = 0, compared = 0, mismatches_here = 0;
    std::vector<long> per_line(kVActive, 0);
    std::vector<int> got_row(kPicW, -1);
    bool got_row_done = false;
    // Which raster line is currently showing black, for configuration B.
    bool line_was_black = false;

    while (mon.frames <= frames_wanted) {
      const uint64_t tn = (next_clk < next_pclk) ? next_clk : next_pclk;
      const bool ck = (tn == next_clk), pk = (tn == next_pclk);
      t = tn;
      if (t > 200000000000ull) break;   // 200 us of nothing: give up

      if (ck) { clk_v ^= 1; next_clk += kClkHalf; }
      if (pk) { pclk_v ^= 1; next_pclk += kPclkHalf; }

      // Reset for the first 64 ns on both domains.
      const int in_reset = (t < 64000) ? 1 : 0;
      dut->rst = in_reset; dut->prst = in_reset;

      if (ck && clk_v) { slave.Drive(dut); dut->eval(); slave.Sample(dut); }

      dut->clk = clk_v; dut->pclk = pclk_v;
      dut->eval();

      if (ck && clk_v) slave.AfterEdge(dut);

      if (pk && pclk_v) {
        ++pclk_ticks;
        const int de = dut->de, hs = dut->hsync, vs = dut->vsync;

        if (mon.since_hs >= 0) ++mon.since_hs;
        // Both pulses are measured in PIXEL CLOCKS and recorded at their
        // trailing edge, which is exact and needs no assumption about how
        // the two counters line up.
        if (hs) ++mon.hs_high; else if (mon.hs_prev) mon.hs_widths.insert(mon.hs_high);
        if (!hs && mon.hs_prev) mon.hs_high = 0;
        if (vs) ++mon.vs_high_lines; else if (mon.vs_prev) mon.vs_widths.insert(mon.vs_high_lines);
        if (!vs && mon.vs_prev) mon.vs_high_lines = 0;

        // hsync's leading edge ends a line.
        if (hs && !mon.hs_prev) {
          if (mon.since_hs > 0) {
            mon.line_lengths.insert(mon.since_hs);
            mon.de_widths.insert(mon.de_this_line);
          }
          mon.since_hs = 0;
          mon.de_this_line = 0;
          if (mon.lines_this_frame >= 0) ++mon.lines_this_frame;
        }

        // vsync's leading edge ends a frame.
        if (vs && !mon.vs_prev) {
          if (mon.lines_this_frame > 0) {
            mon.frame_lengths.insert(mon.lines_this_frame);
            mon.active_per_frame.insert(mon.active_lines);
          }
          ++mon.frames;
          mon.lines_this_frame = 0;
          mon.active_lines = 0;
          mon.y = -1;
        }

        // de's leading edge starts an active line.
        if (de && !mon.de_prev) {
          mon.x = 0;
          ++mon.y;
          ++mon.active_lines;
          if (mon.since_hs >= 0) mon.hs_to_de.insert(mon.since_hs);
          line_was_black = true;   // until a lit pixel says otherwise
        }

        if (de) {
          const int x = mon.x, y = mon.y;
          const bool inpic = (x >= kPicX0) && (x < kPicX0 + kPicW) &&
                             (y >= kPicY0) && (y < kPicY0 + kPicH);
          const bool white = dut->white != 0;
          if (white) line_was_black = false;
          if (compare_pixels && mon.frames == 2 && y == kPicY0 && inpic &&
              !got_row_done) {
            got_row[x - kPicX0] = white ? 1 : 0;
            if (x == kPicX0 + kPicW - 1) got_row_done = true;
          }
          if (compare_pixels && mon.frames >= 2 && y >= 0 && y < kVActive) {
            const bool want = inpic ? Lit(y - kPicY0, x - kPicX0) : false;
            if (white != want) {
              ++mismatches_here;
              if (y >= 0 && y < kVActive) ++per_line[y];
              if (mismatches_here <= 4) {
                // Which line, if any, this pixel WOULD have matched: a
                // whole line off by one shows up at once, where a list of
                // wrong pixels does not.
                int candidate = -1;
                if (inpic) {
                  for (int L = 0; L < kPicH && candidate < 0; L++)
                    if (Lit(L, x - kPicX0) == white) candidate = L;
                }
                Fail("pixel (%d,%d) is %s, want %s%s%d", x, y,
                     white ? "white" : "black", want ? "white" : "black",
                     inpic ? "; picture line wanted is " : " (outside the picture) ",
                     inpic ? y - kPicY0 : 0);
                if (candidate >= 0 && mismatches_here == 1)
                  std::fprintf(stderr,
                               "       (the first picture line whose bit at"
                               " this column agrees is %d)\n", candidate);
              }
              else if (mismatches_here == 5) ++bad;
            }
            ++compared;
          }
          ++mon.x;
          ++mon.de_this_line;
        } else {
          // The line just ended: if it showed nothing at all inside the
          // picture rows, count it.  Only meaningful in configuration B.
          if (mon.de_prev && line_was_black && mon.y >= kPicY0 &&
              mon.y < kPicY0 + kPicH) {
            ++black_lines;
          }
        }

        if (compare_pixels && !de && dut->white) Fail("white is set outside de");

        mon.de_prev = de; mon.hs_prev = hs; mon.vs_prev = vs;
      }
    }

    if (mismatches_here && got_row_done) {
      // What actually came out of the first picture line, as words, beside
      // what the memory holds for the first few lines: a transform shows up
      // here that a list of wrong pixels never would.
      for (int w = 0; w < 4; w++) {
        uint32_t g = 0;
        for (int b = 0; b < 32; b++) g |= (uint32_t)got_row[w * 32 + b] << b;
        std::fprintf(stderr, "       word %d: got %08x  line0 %08x  line1 %08x"
                             "  line2 %08x  poison(w)=%08x poison(w+24)=%08x\n",
                     w, g, Poison(w), Poison(24 + w), Poison(48 + w),
                     Poison(w), Poison(24 + w));
      }
      long lines_wrong = 0;
      std::fprintf(stderr, "       mismatching lines (y: count):");
      for (int y = 0; y < kVActive; y++)
        if (per_line[y]) {
          if (++lines_wrong <= 12) std::fprintf(stderr, " %d:%ld", y, per_line[y]);
        }
      std::fprintf(stderr, "  ... %ld lines wrong, %ld pixels in all\n",
                   lines_wrong, mismatches_here);
    }
    res->underruns = dut->underrun;
    res->black_lines = black_lines;
    res->compared = compared;

    // What the port did, whichever configuration this was.
    if (slave.ar_handshakes != slave.bursts)
      Fail("%ld address handshakes for %ld bursts", slave.ar_handshakes, slave.bursts);
    // The run stops wherever the frame count runs out, so at most one burst
    // and one line can be in flight at the end.
    if (slave.rlasts != slave.bursts && slave.rlasts != slave.bursts - 1)
      Fail("%ld RLASTs for %ld bursts", slave.rlasts, slave.bursts);
    if (slave.beats < (slave.lines - 1) * kBeats || slave.beats > slave.lines * kBeats)
      Fail("%ld beats for %ld lines of %d", slave.beats, slave.lines, kBeats);
    if (dut->rd_error) Fail("the module reported a read error and none was given");

    // Every line start must be a line's, and they must walk the picture: an
    // address that never moves is a fetcher that ignores the line number.
    std::set<uint32_t> distinct(slave.line_addrs.begin(), slave.line_addrs.end());
    for (uint32_t a : distinct) {
      const uint32_t line = (a - kBase) / kLineBytes;
      if (line >= static_cast<uint32_t>(kPicH))
        Fail("address %08x is line %u, past the picture's %d", a, line, kPicH);
    }
    if (compare_pixels) {
      if (distinct.size() != static_cast<size_t>(kPicH))
        Fail("%zu distinct line addresses over the run, want %d",
             distinct.size(), kPicH);
      // **THE SPLIT MUST ACTUALLY HAPPEN**, or the second burst is dead
      // code and no mutation of it could ever be caught.
      if (slave.split_lines == 0)
        Fail("no line was fetched in two bursts, so the 4 KB split is untested");
    }
    res->bursts = slave.bursts;
    res->splits = slave.split_lines;
    res->lines  = slave.lines;

    delete dut;
    return mon;
  };

  // ------------------------------------------------------ configuration A
  Result a{};
  Monitor mon = run(0, 0, 3, true, &a);

  auto one = [&](const std::set<long> &s, long want, const char *what) {
    if (s.size() != 1 || *s.begin() != want) {
      std::fprintf(stderr, "FAIL: %s came out as", what);
      for (long v : s) std::fprintf(stderr, " %ld", v);
      std::fprintf(stderr, ", want exactly %ld\n", want);
      ++bad;
    }
  };

  one(mon.line_lengths, kHTotal, "the pixels in a line");
  one(mon.hs_widths, kHSync, "the hsync pulse, in pixels");
  one(mon.hs_to_de, kHSync + kHBack, "hsync's edge to de's");
  one(mon.frame_lengths, kVTotal, "the lines in a frame");
  // vsync is three whole lines, so it is that many pixel clocks.  Measured
  // in pixels rather than in lines because the two counters need not line
  // up and an off-by-one there would be the check's, not the module's.
  one(mon.vs_widths, static_cast<long>(kVSync) * kHTotal, "the vsync pulse, in pixels");
  one(mon.active_per_frame, kVActive, "the enabled lines in a frame");

  // A line of vertical blanking legitimately enables no pixels at all, so
  // there are exactly two answers and both are wanted.
  if (mon.de_widths.size() != 2 || mon.de_widths.count(0) != 1 ||
      mon.de_widths.count(kHActive) != 1) {
    std::fprintf(stderr, "FAIL: the enabled pixels in a line came out as");
    for (long v : mon.de_widths) std::fprintf(stderr, " %ld", v);
    std::fprintf(stderr, ", want exactly 0 and %d\n", kHActive);
    ++bad;
  }

  if (a.underruns) Fail("the port kept up and the module reported an underrun");
  if (a.compared < static_cast<long>(kHActive) * kVActive)
    Fail("only %ld pixels compared, want at least %d", a.compared,
         kHActive * kVActive);

  // ------------------------------------------------------ configuration B
  //
  // Slow enough to lose: a line gives the fetcher 1,688 pixel clocks, which
  // is about 1,566 of the memory side's.  Two hundred clocks a beat over
  // twelve beats is 2,400 and cannot finish in time.
  Result b{};
  (void)run(40, 200, 2, false, &b);

  if (!b.underruns)
    Fail("the port could not keep up and no underrun was reported");
  if (b.black_lines == 0)
    Fail("the port could not keep up and no line was shown black");

  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems\n", bad);
    return 1;
  }
  std::printf(
      "ok: the display output agrees with the bitmap over a whole frame\n"
      "    %ld pixels compared against a DDR poisoned injectively in the\n"
      "    address --- the picture against its words, the border black\n"
      "    the raster counted: %d pixels a line, %d of them enabled, hsync\n"
      "    %d wide and %d before de; %d lines a frame, %d enabled, vsync %d\n"
      "    %ld lines fetched in %ld bursts of eight-byte INCR beats, twelve\n"
      "    beats a line, one address handshake and one RLAST a burst; %ld of\n"
      "    those lines were split by a 4 KB boundary and fetched in two\n"
      "    and with the port slowed to 200 clocks a beat: underrun reported\n"
      "    and %ld lines shown black rather than shown wrong\n",
      a.compared, kHTotal, kHActive, kHSync, kHSync + kHBack, kVTotal,
      kVActive, kVSync, a.lines, a.bursts, a.splits, b.black_lines);
  return 0;
}
