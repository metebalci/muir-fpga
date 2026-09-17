// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_display_out`'s sleep timer and the mute on the four lanes, on a raster
// small enough to run a hundred frames.
//
// **WHAT SLEEP IS HERE.**  There is no power management on a digital link to a
// monitor: DPMS was an encoding of VGA's two sync lines, and DVI has no lines of
// that kind.  A source puts a monitor to sleep by STOPPING THE LINK, and the
// monitor sees no signal and goes into its own power save.  So the display
// output keeps its raster, its pixel clock and its buffers running and holds
// the four lanes at one level, and a wake lets them go again.  The mute is the
// display output's `mute`; `rtl/plumbing/cadr_hdmi_tx.sv` is what it gates, and
// `tb/cadr_hdmi_tx_tb.cpp` holds the gate.
//
// **WHAT THIS HOLDS**, each against the rule it comes from:
//
//   - the timer runs out after exactly the setting's number of seconds, to the
//     tick, counted from the write that set it, the wake that restarted it, or
//     the end of a fabric reset.  A prescaler a period out is a timer a tick a
//     second out, and only a count to the tick sees it;
//   - the mute changes ONLY at a frame boundary, which is the one pixel before
//     the first line of a frame, recovered here from the syncs and the data
//     enable exactly as a monitor recovers it and never from a counter inside
//     the module;
//   - the mute comes on at the first boundary the timer's verdict can reach
//     through its synchronizer, and not before the timer has run out;
//   - a wake lets the lanes go at the next boundary and starts the timer over;
//   - a wake while the display is awake starts the timer over too;
//   - a setting of zero never mutes, however long it runs, and writing zero to
//     a display that is asleep wakes it;
//   - the raster keeps running while the lanes are muted: every frame of it
//     still has its lines, its pixels and its sync, so a monitor woken up
//     locks onto a picture that never stopped;
//   - `asleep`, the machine clock's view of the mute, agrees with it within
//     its synchronizer;
//   - a fabric reset lets the lanes go at the next boundary, puts the setting
//     back to the fabric's own default and starts the timer from there.
//
// **THE RASTER AND THE SECOND ARE THIS BINARY'S, AND THEY ARE WRITTEN BELOW A
// SECOND TIME.**  The Makefile builds the module with a raster of 100 by 80 and
// a second of 2,000 ticks, so that three hundred seconds is eighty frames
// rather than a real five minutes.  The check does not read those figures out
// of the module: it measures the frame from the syncs and compares, so a build
// with other figures fails on the frame's own length rather than being measured
// against itself.  **THE DEFAULT SETTING IS NOT OVERRIDDEN**, so the three
// hundred is the module's own.
//
// **WHAT IT CANNOT HOLD.**  The second is 2,000 ticks here and 100,000,000 on
// the board.  The prescaler's COUNTING is held to the tick; the board's number
// is a literal beside the watchdog's, "one second at the 10 ns tick", and
// nothing but reading it holds it.  That is `cadr_debug_window.sv`'s standing
// too, and for the same reason: it is a fabric choice in board ticks and not
// one of MIT's instants.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Vcadr_display_out.h"
#include "verilated.h"

namespace {

// The raster the Makefile builds this binary with: active, front porch, sync,
// back porch.  Both syncs positive, which is mode 0's.
constexpr int kHA = 80, kHF = 4, kHS = 6, kHB = 10;
constexpr int kVA = 70, kVF = 2, kVS = 3, kVB = 5;
constexpr long kHT = kHA + kHF + kHS + kHB;   // 100
constexpr long kVT = kVA + kVF + kVS + kVB;   // 80

// How many of the machine's ticks this build calls a second, and the fabric's
// own default setting, which this build leaves alone.
constexpr uint64_t kSecondT = 2000;
constexpr uint64_t kDefaultS = 300;

// The two clocks at their real periods, to the picosecond: the machine's
// 100 MHz and mode 0's pixel clock.  Deliberately incommensurate, so that the
// timer's verdict reaches the pixel domain at every phase of it.
constexpr uint64_t kClkHalf = 5000;
constexpr uint64_t kPclkHalf = 4638;
constexpr uint64_t kPclk = 2 * kPclkHalf;

// A level crossing into the pixel domain through two flops is taken by the
// frame boundary at least two pixel clocks after it moved and at most three;
// a boundary inside that window may take it or not, and one past it must.
constexpr uint64_t kSyncWindow = 3 * kPclk;

// How many edges of the machine's clock `asleep` may lag the mute: two flops
// and the edge that samples them.
constexpr int kAsleepLag = 3;

int bad = 0;

void Fail(const char *fmt, ...) {
  if (++bad <= 30) {
    va_list ap;
    va_start(ap, fmt);
    std::fprintf(stderr, "FAIL: ");
    std::vfprintf(stderr, fmt, ap);
    std::fprintf(stderr, "\n");
    va_end(ap);
  }
}

constexpr uint64_t kNever = UINT64_MAX;

struct Sim {
  Vcadr_display_out *dut = new Vcadr_display_out;

  uint64_t t = 0, next_clk = kClkHalf, next_pclk = kPclkHalf;
  int clk_v = 0, pclk_v = 0;

  // The machine clock's rising edges, counted.
  uint64_t ce = 0;

  // ---- what the timer must say
  //
  // The rising edge of the machine's clock at which `sleep_due` must first be
  // high, or `kNever`.  Every edge before it must read low, and every edge from
  // it on must read high until something clears it.
  uint64_t due_at = kNever;
  uint64_t due_rose_ps = 0;   // when it last went high, in picoseconds
  bool due_prev = false;
  long due_checks = 0, due_wrong = 0;

  // ---- what the host is doing to the display's face this edge
  int pend_set = 0;
  uint16_t pend_secs = 0;
  int pend_wake = 0;
  int rst = 1;            // the machine clock's reset: the fabric's
  uint64_t last_rst_edge = 0;
  bool rst_ended = false;
  // What the display's face holds, as far as this check has told it: the
  // fabric's own default until a write, and again after a reset.  A wake
  // starts the timer over from this.
  uint64_t setting = kDefaultS;

  // ---- the slave on the read port, which answers every burst with zeros:
  //      what the picture is does not matter here, only that the fetch
  //      never stops the raster.
  int burst_left = 0;

  // ---- the monitor
  int de_prev = 0, hs_prev = 0;
  int mute_prev = 0;
  bool vs_seen = false;         // a vsync pulse since the last first line
  bool mute_moved = false;      // the mute changed at the last sample
  uint64_t moved_ps = 0;
  long samples = 0;
  long boundaries = 0;
  std::vector<uint64_t> boundary_ps;   // one pixel before each frame's first line
  long frame_lines = -1, line_pixels = 0, since_hs = -1;
  long frames_seen = 0;
  // Whole frames the lanes were muted from end to end, and how many of those
  // had the raster's own shape.
  long muted_frames = 0, muted_frames_whole = 0;
  bool frame_muted_throughout = false;
  long bad_frames = 0;

  // ---- the mute's changes, for the scenarios to judge
  uint64_t last_rise_ps = 0, last_fall_ps = 0;
  long rises = 0, falls = 0;
  int asleep_lag = 0;
  long asleep_wrong = 0;

  void Edge() {
    const uint64_t tn = (next_clk < next_pclk) ? next_clk : next_pclk;
    const bool ck = (tn == next_clk), pk = (tn == next_pclk);
    t = tn;
    if (ck) { clk_v ^= 1; next_clk += kClkHalf; }
    if (pk) { pclk_v ^= 1; next_pclk += kPclkHalf; }

    const bool clk_rise = ck && clk_v;
    const bool pclk_rise = pk && pclk_v;

    if (clk_rise) {
      // The read port.
      dut->m_arready = burst_left == 0;
      dut->m_rvalid = burst_left > 0;
      dut->m_rdata = 0;
      dut->m_rresp = 0;
      dut->m_rlast = burst_left == 1;
      // What the host asks for on this edge.
      dut->rst = rst;
      dut->sleep_set = pend_set;
      dut->sleep_secs = pend_secs;
      dut->wake = pend_wake;
    }
    dut->prst = (t < 64000) ? 1 : 0;
    dut->map_q = 0;
    dut->out_sel = 1;
    dut->rotate = 0;

    // The handshakes as they stand before the edge.
    const int ar_hs = clk_rise && dut->m_arvalid && dut->m_arready;
    const int r_hs = clk_rise && dut->m_rvalid && dut->m_rready;
    const int ar_len = dut->m_arlen;

    dut->clk = clk_v;
    dut->pclk = pclk_v;
    dut->eval();

    if (clk_rise) {
      ++ce;
      if (r_hs) --burst_left;
      if (ar_hs) burst_left = ar_len + 1;

      // What the timer must say from this edge on.  A reset held on the
      // edge clears it and puts the default back, and it counts from the
      // last edge the reset was held; a write or a wake taken on the edge
      // starts it over from the edge itself.  **A WRITE WINS OVER A WAKE**
      // when both land on one edge, which is the order the module takes
      // them in and is stated in its header.
      if (rst) {
        due_at = kNever;
        last_rst_edge = ce;
        setting = kDefaultS;
        rst_ended = false;
      } else if (!rst_ended) {
        rst_ended = true;
        if (!pend_set && !pend_wake)
          due_at = setting ? last_rst_edge + setting * kSecondT : kNever;
      }
      if (!rst && pend_set) {
        setting = pend_secs;
        due_at = setting ? ce + setting * kSecondT : kNever;
      } else if (!rst && pend_wake) {
        due_at = setting ? ce + setting * kSecondT : kNever;
      }
      pend_set = 0;
      pend_wake = 0;

      const bool due = dut->sleep_due != 0;
      const bool want = (due_at != kNever) && (ce >= due_at);
      if (due != want) {
        // The first few by edge, and every one counted: a timer a tick out is
        // one line, and a timer that never runs is a flood that would hide the
        // scenario that says why.
        if (++due_wrong <= 3)
          Fail("edge %llu: sleep_due is %d, and the timer %s", (unsigned long long)ce, due,
               want ? "has run out" : "has not run out");
      }
      ++due_checks;
      if (due && !due_prev) due_rose_ps = t;
      due_prev = due;

      // `asleep` is the mute a few edges late and never more.
      if (dut->asleep != dut->mute) {
        if (++asleep_lag > kAsleepLag && ++asleep_wrong <= 3)
          Fail("edge %llu: asleep has disagreed with the mute for %d edges",
               (unsigned long long)ce, asleep_lag);
      } else {
        asleep_lag = 0;
      }
    }

    if (pclk_rise && !dut->prst) Monitor();
  }

  void Monitor() {
    ++samples;
    const int de = dut->de, hs = dut->hsync, vs = dut->vsync, mute = dut->mute;
    const bool first_line = de && !de_prev && vs_seen;

    // **THE MUTE MOVES ONLY AT A FRAME BOUNDARY**: the sample after it moved
    // must be the first pixel of a frame's first line.
    if (mute_moved) {
      if (!first_line)
        Fail("the mute changed %s at %llu ps, and the next pixel does not begin a frame",
             mute_prev ? "on" : "off", (unsigned long long)moved_ps);
      mute_moved = false;
    }
    if (mute != mute_prev) {
      mute_moved = true;
      moved_ps = t;
      if (mute) { ++rises; last_rise_ps = t; } else { ++falls; last_fall_ps = t; }
    }

    // The raster's own shape, from the syncs.
    if (since_hs >= 0) ++since_hs;
    if (hs && !hs_prev) {
      if (since_hs > 0 && since_hs != kHT) {
        Fail("a line of %ld pixels between two hsyncs, want %ld", since_hs, kHT);
      }
      since_hs = 0;
    }
    if (de) ++line_pixels;
    if (!de && de_prev) {
      if (line_pixels != kHA) Fail("an enabled line of %ld pixels, want %d", line_pixels, kHA);
      line_pixels = 0;
    }
    if (de && !de_prev) {
      if (first_line) {
        ++boundaries;
        boundary_ps.push_back(t - kPclk);
        if (frame_lines >= 0) {
          ++frames_seen;
          if (frame_lines != kVA) {
            ++bad_frames;
            Fail("a frame of %ld enabled lines, want %d", frame_lines, kVA);
          }
          if (frame_muted_throughout) {
            ++muted_frames;
            if (frame_lines == kVA) ++muted_frames_whole;
          }
        }
        frame_lines = 0;
        frame_muted_throughout = true;
        vs_seen = false;
      }
      if (frame_lines >= 0) ++frame_lines;
    }
    if (!mute) frame_muted_throughout = false;
    if (vs) vs_seen = true;

    de_prev = de;
    hs_prev = hs;
    mute_prev = mute;
  }

  void Clocks(uint64_t n) {
    const uint64_t until = ce + n;
    while (ce < until) Edge();
  }

  // Runs until `pred` holds or `limit` edges of the machine's clock have gone.
  template <typename P>
  bool Until(P pred, uint64_t limit) {
    const uint64_t until = ce + limit;
    while (ce < until) {
      if (pred()) return true;
      Edge();
    }
    return pred();
  }

  // The first frame boundary strictly after `from`, or `kNever`.
  uint64_t BoundaryAfter(uint64_t from) const {
    for (uint64_t b : boundary_ps)
      if (b > from) return b;
    return kNever;
  }
};

// **THE MUTE MOVED AT THE BOUNDARY IT HAD TO**: the first boundary after the
// cause that is past the synchronizer's window, or one inside the window.  A
// boundary before the cause is a mute that did not wait for the timer; a later
// one is a mute that let a whole frame go by.
void JudgeLatency(const Sim &s, const char *what, uint64_t cause_ps, uint64_t moved_ps) {
  if (moved_ps <= cause_ps) {
    Fail("%s: the mute moved at %llu ps, before its cause at %llu ps", what,
         (unsigned long long)moved_ps, (unsigned long long)cause_ps);
    return;
  }
  uint64_t b = s.BoundaryAfter(cause_ps);
  while (b != kNever && b < moved_ps) {
    if (b >= cause_ps + kSyncWindow) {
      Fail("%s: a frame boundary at %llu ps went by without it, %llu ps after its cause",
           what, (unsigned long long)b, (unsigned long long)(b - cause_ps));
      return;
    }
    b = s.BoundaryAfter(b);
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Sim s;

  // ---- out of reset
  s.rst = 1;
  s.Clocks(16);
  s.rst = 0;
  s.Clocks(4);
  if (s.dut->sleep_setting != kDefaultS)
    Fail("the setting out of reset is %u seconds, want the fabric's own %llu",
         s.dut->sleep_setting, (unsigned long long)kDefaultS);

  // ---- A: a setting of five seconds times out to the tick, and the lanes are
  //      muted at the next boundary the verdict can reach and not before.
  const uint64_t n = 5;
  s.Clocks(3);
  s.pend_set = 1;
  s.pend_secs = static_cast<uint16_t>(n);
  s.Clocks(1);
  const uint64_t set_edge = s.ce;
  if (s.dut->sleep_setting != n)
    Fail("A: the setting reads %u after writing %llu", s.dut->sleep_setting,
         (unsigned long long)n);
  if (!s.Until([&] { return s.dut->sleep_due != 0; }, n * kSecondT + 8))
    Fail("A: the timer never ran out");
  else if (s.ce != set_edge + n * kSecondT)
    Fail("A: the timer ran out at edge %llu, %llu after the write; want %llu",
         (unsigned long long)s.ce, (unsigned long long)(s.ce - set_edge),
         (unsigned long long)(n * kSecondT));
  if (s.rises != 0) Fail("A: the lanes were muted before the timer ran out");
  const uint64_t due_ps = s.due_rose_ps;
  if (!s.Until([&] { return s.rises > 0; }, 4 * kVT * kHT))
    Fail("A: the timer ran out and the lanes were never muted");
  else
    JudgeLatency(s, "A, the mute on", due_ps, s.last_rise_ps);

  // ---- B: the raster keeps running while the lanes are muted.
  const long muted_before = s.muted_frames;
  s.Until([&] { return s.muted_frames >= muted_before + 3; }, 8 * kVT * kHT);
  if (s.muted_frames < muted_before + 3)
    Fail("B: only %ld whole frames went by muted", s.muted_frames - muted_before);
  if (s.muted_frames_whole != s.muted_frames)
    Fail("B: %ld of %ld muted frames were not the raster's own shape",
         s.muted_frames - s.muted_frames_whole, s.muted_frames);
  if (s.falls != 0) Fail("B: the lanes came back with nothing asked of them");

  // ---- C: a wake lets the lanes go at the next boundary and starts the timer
  //      over from the wake.
  s.pend_wake = 1;
  s.Clocks(1);
  const uint64_t wake_edge = s.ce;
  const uint64_t wake_ps = s.t;
  if (s.dut->sleep_setting != n) Fail("C: a wake moved the setting");
  if (!s.Until([&] { return s.falls > 0; }, 4 * kVT * kHT))
    Fail("C: a wake did not let the lanes go");
  else
    JudgeLatency(s, "C, the mute off after a wake", wake_ps, s.last_fall_ps);
  if (!s.Until([&] { return s.dut->sleep_due != 0; }, n * kSecondT + 8))
    Fail("C: the timer did not run out again after the wake");
  else if (s.ce != wake_edge + n * kSecondT)
    Fail("C: after a wake the timer ran out %llu edges later, want %llu",
         (unsigned long long)(s.ce - wake_edge), (unsigned long long)(n * kSecondT));
  if (!s.Until([&] { return s.rises > 1; }, 4 * kVT * kHT))
    Fail("C: the timer ran out again and the lanes stayed on");
  else
    JudgeLatency(s, "C, the mute on again", s.due_rose_ps, s.last_rise_ps);

  // ---- D: a wake while the display is AWAKE starts the timer over too.
  s.pend_wake = 1;
  s.Clocks(1);
  const uint64_t d_wake = s.ce;
  s.Until([&] { return s.falls > 1; }, 4 * kVT * kHT);
  if (s.falls < 2) Fail("D: the lanes did not come back for the second wake");
  // Most of the way to the timeout, and then another wake.
  const uint64_t almost = d_wake + n * kSecondT - 700;
  if (s.ce < almost) s.Clocks(almost - s.ce);
  if (s.dut->sleep_due) Fail("D: the timer ran out early");
  const long rises_before = s.rises;
  s.pend_wake = 1;
  s.Clocks(1);
  const uint64_t poke_edge = s.ce;
  // Past where the first wake would have timed out: nothing is due, and the
  // lanes stay on.
  s.Clocks(1400);
  if (s.dut->sleep_due) Fail("D: a wake while awake did not start the timer over");
  if (!s.Until([&] { return s.dut->sleep_due != 0; }, n * kSecondT))
    Fail("D: the timer never ran out after the second wake");
  else if (s.ce != poke_edge + n * kSecondT)
    Fail("D: after a wake while awake the timer ran out %llu edges later, want %llu",
         (unsigned long long)(s.ce - poke_edge), (unsigned long long)(n * kSecondT));
  if (s.rises != rises_before)
    Fail("D: the lanes were muted before the restarted timer ran out");
  s.Until([&] { return s.rises > rises_before; }, 4 * kVT * kHT);
  if (s.rises == rises_before) Fail("D: the restarted timer ran out and the lanes stayed on");

  // ---- E: zero never mutes, and writing it to a display that is asleep
  //      wakes it.
  const long falls_before_e = s.falls;
  s.pend_set = 1;
  s.pend_secs = 0;
  s.Clocks(1);
  const uint64_t zero_ps = s.t;
  if (s.dut->sleep_setting != 0) Fail("E: the setting reads %u after writing 0",
                                      s.dut->sleep_setting);
  if (!s.Until([&] { return s.falls > falls_before_e; }, 4 * kVT * kHT))
    Fail("E: writing zero to a display asleep did not let the lanes go");
  else
    JudgeLatency(s, "E, the mute off after a zero", zero_ps, s.last_fall_ps);
  const long rises_e = s.rises;
  // Longer than the longest setting this run uses, several times over, and
  // across many frames: `due_at` is `kNever`, so every edge asserts it low.
  s.Clocks(12 * n * kSecondT);
  if (s.rises != rises_e) Fail("E: a setting of zero muted the lanes");
  if (s.dut->asleep) Fail("E: a setting of zero says the display is asleep");

  // ---- F: a fabric reset while muted lets the lanes go at the next boundary,
  //      restores the fabric's own three hundred, and starts from there.
  s.pend_set = 1;
  s.pend_secs = static_cast<uint16_t>(n);
  s.Clocks(1);
  s.Until([&] { return s.rises > rises_e; }, n * kSecondT + 4 * kVT * kHT);
  if (s.rises == rises_e) Fail("F: the lanes were not muted before the reset");
  s.Clocks(2 * kVT * kHT / 2);
  const long falls_f = s.falls;
  s.rst = 1;
  s.Clocks(1);
  const uint64_t rst_ps = s.t;
  s.Clocks(7);
  s.rst = 0;
  s.Clocks(1);
  const uint64_t rst_end = s.last_rst_edge;
  if (s.dut->sleep_setting != kDefaultS)
    Fail("F: after a fabric reset the setting reads %u, want the fabric's own %llu",
         s.dut->sleep_setting, (unsigned long long)kDefaultS);
  if (!s.Until([&] { return s.falls > falls_f; }, 4 * kVT * kHT))
    Fail("F: a fabric reset did not let the lanes go");
  else
    JudgeLatency(s, "F, the mute off after a reset", rst_ps, s.last_fall_ps);
  const long rises_f = s.rises;
  if (!s.Until([&] { return s.dut->sleep_due != 0; }, kDefaultS * kSecondT + 8))
    Fail("F: the fabric's own default never ran out");
  else if (s.ce != rst_end + kDefaultS * kSecondT)
    Fail("F: after a reset the timer ran out %llu edges later, want %llu",
         (unsigned long long)(s.ce - rst_end), (unsigned long long)(kDefaultS * kSecondT));
  if (s.rises != rises_f) Fail("F: the lanes were muted before the default ran out");
  s.Until([&] { return s.rises > rises_f; }, 4 * kVT * kHT);
  if (s.rises == rises_f) Fail("F: the default ran out and the lanes stayed on");

  // ---- the run as a whole
  if (s.due_wrong) Fail("sleep_due disagreed with the timer on %ld edges", s.due_wrong);
  if (s.asleep_wrong) Fail("asleep lagged the mute too far on %ld edges", s.asleep_wrong);
  if (s.frames_seen < 20) Fail("only %ld frames were seen, which is not a run", s.frames_seen);
  if (s.bad_frames) Fail("%ld frames were not the raster's own shape", s.bad_frames);

  delete s.dut;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems\n", bad);
    return 1;
  }
  std::printf(
      "ok: the display output sleeps and wakes on a raster of %ld by %ld\n"
      "    the timer to the tick at 5 seconds of %llu ticks, from a write, a\n"
      "    wake while asleep, a wake while awake and a fabric reset; %ld edges\n"
      "    asserted against it, and the fabric's own %llu seconds after the reset\n"
      "    the mute on %ld times and off %ld, every change one pixel before a\n"
      "    frame's first line and none a frame late; %ld whole frames muted with\n"
      "    the raster's own shape; zero never muted over %llu edges\n",
      kHT, kVT, (unsigned long long)kSecondT, s.due_checks, (unsigned long long)kDefaultS,
      s.rises, s.falls, s.muted_frames, (unsigned long long)(12 * n * kSecondT));
  return 0;
}
