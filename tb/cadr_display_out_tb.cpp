// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_display_out` against a modeled DDR, for whole frames, read the way a
// monitor reads them.
//
// **THE CHECK RECOVERS THE RASTER FROM THE SYNCS AND NOT FROM ANY COUNTER
// INSIDE THE MODULE.**  It watches `de`, `hsync` and `vsync` exactly as a
// monitor does, counts pixels from the leading edge of `de` and lines from the
// leading edge of `vsync`, and only then asks what color the pixel at that
// position should be.  So the module's pipeline depth is not something this has
// to know, and a change to it is not a change here.  A check that reached into
// the device for `hc` and `vc` would agree with the device about where it was,
// which is the failure this repository calls writing a check to confirm rather
// than to compare.
//
// **THE TWO CLOCKS ARE RUN AT THEIR REAL AND DELIBERATELY INCOMMENSURATE
// PERIODS**, 10.000 ns for the memory side and the mode's own for the raster,
// on a picosecond timeline, so that the edges of one fall at every phase of the
// other over a frame.  A testbench that clocked both from one counter would
// exercise one alignment of the two domains and call the buffers checked.
//
// THE TWO WINDOWS ARE POISONED INJECTIVELY IN THE ADDRESS, and with DIFFERENT
// poisons, so that a fetch of the wrong line, a swapped pair of words inside a
// beat, an off-by-one in the word index, a bank that never changes, a band
// taken from the wrong word column, or a color pixel fetched out of the first
// display's window all produce a picture that disagrees rather than a picture
// that happens to match.  Against a memory of zeros every one of those faults
// draws the same black screen.
//
// **AND THE COLOR MAP IS THE TESTBENCH'S**, injective in the color and
// different in all three channels, so that a channel order the other way round,
// a map applied to the wrong screen and an index off by one are all visible.
//
// THE MODE IS THE BINARY'S, and `argv[1]` says which: the raster's figures are
// parameters of the module and three builds carry the three. The table below is
// transcribed from the specifications rather than from the module, which is
// what makes comparing it worth anything.
//
// The configurations:
//
//   A  mono upright, the port at its ordinary speed.  A whole frame compared
//      pixel for pixel, the raster's own figures counted rather than sampled,
//      and every burst's shape asserted.  RUN FOR ALL THREE MODES.
//   B  the port slowed until it cannot keep up.  **A STIMULUS FAST ENOUGH
//      HIDES THE RACE IT EXISTS TO SHOW**: at the real speed the fetcher is a
//      whole line ahead and the underrun path is dead code no mutation can
//      reach.  Slowed, the raster must report it and show black.
//   C  the color board alone, upright: four-bit pixels through the map.
//   D  both, upright: the color screen drawn OVER the first display.
//   E  the first display alone, a quarter turn clockwise.
//   F  the first display alone, a quarter turn the other way.
//   G  both, rotated: the overlap and the two band sizes at once.
//
// B to G run on the default mode, because what they hold is the compositor and
// the band fetch rather than the raster, and those do not change with the mode.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <set>
#include <vector>

#include "Vcadr_display_out.h"
#include "verilated.h"

namespace {

// The three modes, from their own specifications.  `docs/display-output.md`
// has the arithmetic; these are the figures it arrives at.
struct ModeSpec {
  int ha, hf, hs, hb;
  int va, vf, vs, vb;
  int hpos, vpos;
  uint64_t pclk_half_ps;   // the board's own pixel clock, to the picosecond
  const char *name;
};
const ModeSpec kModes[3] = {
    {1280, 48, 112, 248, 1024, 1, 3, 38, 1, 1, 4638,
     "VESA DMT 1280x1024 at 60 Hz"},
    // Reduced blanking: 160 pixels of horizontal blanking whatever the width,
    // and the one mode of the three whose VSYNC is negative --- which is the
    // pair a sink reads reduced blanking by.
    {1400, 48, 32, 80, 1050, 3, 4, 23, 1, 0, 4961,
     "CVT reduced blanking 1400x1050 at 60 Hz"},
    {1920, 88, 44, 148, 1080, 4, 5, 36, 1, 1, 6737,
     "CEA-861 VIC 34, 1920x1080 at 30 Hz"},
};

int M = 0;                       // which mode this binary was built for
int HA, HF, HS, HB, VA, VF, VS, VB, HT, VT;
int HPOS, VPOS;
uint64_t kPclkHalf;

// The two screens: muir's `WIDTH`/`HEIGHT`/`WORDS_PER_LINE` and its
// `COLOR_*` counterparts.
constexpr int kPicW = 768, kPicH = 963, kWords = 24;
constexpr int kCW = 576, kCH = 454, kCWords = 72;
constexpr int kLineBytes = kWords * 4;    // 96
constexpr int kCLineBytes = kCWords * 4;  // 288

constexpr uint32_t kBase = 0x1C000000u;
constexpr uint32_t kCBase = 0x1C020000u;
constexpr int kOutstanding = 8;

// Where each picture sits, upright and rotated.
int MX0, MY0, CX0, CY0, RMX0, RMY0, RCX0, RCY0;

constexpr uint64_t kClkHalf = 5000;   // 100 MHz

int bad = 0;

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

// Injective in the word index and never zero: multiplying by an odd constant is
// a bijection on 32 bits, so no two words of a window share a value --- and the
// two windows use different constants, so no word of one can be a word of the
// other.
uint32_t PoisonM(uint32_t w) { return 0xF0000000u ^ (w * 2654435761u); }
uint32_t PoisonC(uint32_t w) { return 0x0F0F0F0Fu ^ (w * 2246822519u); }

uint32_t WordAt(uint32_t byte_addr) {
  if (byte_addr >= kCBase) return PoisonC((byte_addr - kCBase) / 4u);
  return PoisonM((byte_addr - kBase) / 4u);
}

// What the first display holds: muir's `Tv::pixel`, bit 0 of a word the
// leftmost of the 32 pixels it carries.
bool MonoLit(int row, int col) {
  const uint32_t w = static_cast<uint32_t>(row) * kWords + static_cast<uint32_t>(col) / 32u;
  return ((PoisonM(w) >> (col % 32)) & 1u) != 0u;
}

// And the color board: `Tv::color_pixel`, the LOW NIBBLE the leftmost of the 8
// pixels a word carries.
int ColorIndex(int row, int col) {
  const uint32_t w = static_cast<uint32_t>(row) * kCWords + static_cast<uint32_t>(col) / 8u;
  return static_cast<int>((PoisonC(w) >> ((col % 8) * 4)) & 0xFu);
}

// The map this check offers: injective in the color, none of the forty-eight
// bytes zero, and no two channels of one color equal --- so a channel order the
// other way round, an index off by one and a map read off the other board are
// each visible.
uint32_t MapEntry(int k) {
  const uint32_t r = 3u + 15u * static_cast<uint32_t>(k);
  const uint32_t g = 200u - 11u * static_cast<uint32_t>(k);
  const uint32_t b = 7u + 9u * static_cast<uint32_t>(k);
  return (r << 16) | (g << 8) | b;
}

// ---------------------------------------------------------- the geometry
//
// Where a raster pixel comes from, which is the whole of what rotation means
// here --- and it is written out from the rotation itself rather than from the
// module's arithmetic, so that the two are two descriptions and can disagree.
//
// A quarter turn clockwise puts the source's top-left corner at the picture's
// top-right: source (col, row) is drawn at (H-1-row, col).
bool MonoSrc(int x, int y, int rot, int *row, int *col) {
  if (rot == 0) {
    const int sx = x - MX0, sy = y - MY0;
    if (sx < 0 || sx >= kPicW || sy < 0 || sy >= kPicH) return false;
    *row = sy; *col = sx; return true;
  }
  const int px = x - RMX0, py = y - RMY0;
  if (px < 0 || px >= kPicH || py < 0 || py >= kPicW) return false;
  if (rot == 1) { *row = kPicH - 1 - px; *col = py; }
  else          { *row = px;             *col = kPicW - 1 - py; }
  return true;
}

bool ColorSrc(int x, int y, int rot, int *row, int *col) {
  if (rot == 0) {
    const int sx = x - CX0, sy = y - CY0;
    if (sx < 0 || sx >= kCW || sy < 0 || sy >= kCH) return false;
    *row = sy; *col = sx; return true;
  }
  const int px = x - RCX0, py = y - RCY0;
  if (px < 0 || px >= kCH || py < 0 || py >= kCW) return false;
  if (rot == 1) { *row = kCH - 1 - px; *col = py; }
  else          { *row = px;           *col = kCW - 1 - py; }
  return true;
}

// What the three channels must be at a pixel inside the active region.  **THE
// COLOR SCREEN IS DRAWN OVER THE FIRST DISPLAY** where both are shown.
uint32_t WantRGB(int x, int y, int sel, int rot) {
  int row, col;
  if ((sel & 2) && ColorSrc(x, y, rot, &row, &col))
    return MapEntry(ColorIndex(row, col));
  if ((sel & 1) && MonoSrc(x, y, rot, &row, &col))
    return MonoLit(row, col) ? 0xFFFFFFu : 0u;
  return 0u;
}

// --------------------------------------------------------------- the slave
//
// An AXI3 read slave on `S_AXI_HP3` with the protocol asserted rather than
// assumed, and with a queue, because the band fetch has several reads in flight
// at once and a slave that took one at a time would be a slave the master could
// not be checked against.
struct Burst {
  uint32_t addr;
  int len;
  int beat;
};

struct Slave {
  int ar_wait = 0;      // clocks before ARREADY
  int beat_wait = 0;    // clocks before each beat
  int arw = 0, bw = 0;
  int rot = 0;          // what this configuration asked for
  int live = 0;         // the settings have taken: compare from here
  long dump = 0;

  std::deque<Burst> q;

  long bursts = 0, beats = 0, ar_handshakes = 0, rlasts = 0, splits = 0;
  long mono_beats = 0, color_beats = 0;
  size_t max_in_flight = 0;

  // The strided walk: how far into a band each window is, so that a step that
  // is not the stride shows.
  long single_n[2] = {0, 0};
  uint32_t last_single[2] = {0, 0};

  uint8_t s_arvalid = 0, s_arready = 0, s_rvalid = 0, s_rready = 0, s_rlast = 0;
  // **THE ADDRESS CHANNEL IS TAKEN BEFORE THE EDGE THAT CONSUMES IT, AND THAT
  // IS NOT FUSSINESS.**  A master may change `ARADDR` on the cycle after a
  // handshake, and the strided arm does: `saddr` steps by a source line at the
  // very edge the address is taken.  Reading `m_araddr` after that edge reads
  // the NEXT address, so every band was recorded --- and SERVED --- one source
  // row too high: row 1 where row 0 was asked for, and a row 963 that does not
  // exist where row 962 was.  The rotated picture then disagreed with the
  // bitmap by a row everywhere, and the address walk complained about a step it
  // had itself invented.  The contiguous arm hid it, because `c_araddr` is
  // written once a burst and is the same either side of the edge.  A slave
  // latches the address channel on the edge where VALID and READY are both up,
  // which is what these are.
  uint32_t s_araddr = 0;
  int s_arlen = 0, s_arsize = 0, s_arburst = 0;

  uint64_t BeatData(uint32_t a) const {
    return static_cast<uint64_t>(WordAt(a)) |
           (static_cast<uint64_t>(WordAt(a + 4)) << 32);
  }

  void Drive(Vcadr_display_out *dut) {
    dut->m_arready = (q.size() < static_cast<size_t>(kOutstanding) && arw == 0) ? 1 : 0;
    if (!q.empty() && bw == 0) {
      const Burst &b = q.front();
      dut->m_rvalid = 1;
      dut->m_rdata = BeatData(b.addr + static_cast<uint32_t>(8 * b.beat));
      dut->m_rresp = 0;
      dut->m_rlast = (b.beat == b.len) ? 1 : 0;
    } else {
      dut->m_rvalid = 0; dut->m_rdata = 0; dut->m_rresp = 0; dut->m_rlast = 0;
    }
  }

  void Sample(Vcadr_display_out *dut) {
    s_arvalid = dut->m_arvalid; s_arready = dut->m_arready;
    s_rvalid = dut->m_rvalid;   s_rready = dut->m_rready;
    s_rlast = dut->m_rlast;
    s_araddr = dut->m_araddr;   s_arlen = dut->m_arlen;
    s_arsize = dut->m_arsize;   s_arburst = dut->m_arburst;
  }

  void AfterEdge(Vcadr_display_out *dut) {
    if (arw > 0) --arw;
    if (s_arvalid && s_arready) {
      ++ar_handshakes; ++bursts;
      const uint32_t a = s_araddr;
      const int len = s_arlen;
      if (s_arsize != 3) Fail("ARSIZE %u, want 3 (eight bytes)", s_arsize);
      if (s_arburst != 1) Fail("ARBURST %u, want INCR", s_arburst);
      if (a % 8u) Fail("address %08x is not beat aligned", a);
      const uint32_t last = a + static_cast<uint32_t>(8 * len) + 7u;
      if ((a >> 12) != (last >> 12))
        Fail("burst at %08x of %d beats crosses a 4 KB boundary", a, len + 1);
      if (len > 15) Fail("ARLEN %d, and AXI3 has four bits of it", len);
      if (dump > 0) { std::fprintf(stderr, "AR %08x len %d\n", a, len); --dump; }
      const int win = (a >= kCBase) ? 1 : 0;
      const uint32_t base = win ? kCBase : kBase;
      const uint32_t stride = static_cast<uint32_t>(win ? kCLineBytes : kLineBytes);
      const long rows = win ? kCH : kPicH;
      if (len == 0 && rot != 0 && live) {
        // A strided band: every read is one word out of one source row, so the
        // addresses walk the window a whole source line apart until the band is
        // done, and then begin again at a row-0 address --- which is the only
        // kind inside the first line's worth of the window, a word column being
        // narrower than a line.  An address that is neither is a band taken out
        // of the wrong rows, which draws a picture made of one column over and
        // over.
        const int at_row0 = (a - base) < stride;
        if (!at_row0 && single_n[win] > 0 && a != last_single[win] + stride)
          Fail("a strided read at %08x follows %08x, want a step of %u or a row-0 address",
               a, last_single[win], stride);
        last_single[win] = a;
        single_n[win] = 1;
      } else {
        single_n[win] = 0;
      }
      (void)rows;
      if (a < base) Fail("address %08x is below its window's base %08x", a, base);
      q.push_back(Burst{a, len, 0});
      if (q.size() > max_in_flight) max_in_flight = q.size();
      if (q.size() > static_cast<size_t>(kOutstanding))
        Fail("%zu reads in flight, and the master may hold %d", q.size(), kOutstanding);
      arw = ar_wait;
      if (bw == 0) bw = beat_wait;
    }
    if (bw > 0) --bw;
    if (s_rvalid && s_rready) {
      ++beats;
      Burst &b = q.front();
      if (b.addr >= kCBase) ++color_beats; else ++mono_beats;
      if (s_rlast) {
        ++rlasts;
        if (b.beat != b.len) Fail("RLAST on beat %d of %d", b.beat, b.len);
        q.pop_front();
      } else {
        if (b.beat == b.len) Fail("no RLAST on the burst's last beat");
        ++b.beat;
      }
      bw = beat_wait;
    }
  }
};

// -------------------------------------------------------------- the monitor
struct Monitor {
  int de_prev = 0, hs_prev = 0, vs_prev = 0;
  int x = 0, y = -1;
  long since_hs = -1;
  long hs_high = 0, vs_high = 0;
  long de_this_line = 0;
  long lines_this_frame = -1, active_lines = 0;
  long frames = 0;
  std::set<long> line_lengths, hs_widths, de_widths, hs_to_de;
  std::set<long> frame_lengths, vs_widths, active_per_frame;
};

struct Result {
  long underruns = 0, compared = 0, mono_beats = 0, color_beats = 0;
  long black_lines = 0, bursts = 0;
  size_t max_in_flight = 0;
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc > 1) M = std::atoi(argv[1]);
  if (M < 0 || M > 2) { std::fprintf(stderr, "FAIL: mode %d\n", M); return 1; }

  HA = kModes[M].ha; HF = kModes[M].hf; HS = kModes[M].hs; HB = kModes[M].hb;
  VA = kModes[M].va; VF = kModes[M].vf; VS = kModes[M].vs; VB = kModes[M].vb;
  HPOS = kModes[M].hpos; VPOS = kModes[M].vpos;
  kPclkHalf = kModes[M].pclk_half_ps;
  HT = HA + HF + HS + HB;
  VT = VA + VF + VS + VB;
  MX0 = (HA - kPicW) / 2;  MY0 = (VA - kPicH) / 2;
  CX0 = (HA - kCW) / 2;    CY0 = (VA - kCH) / 2;
  RMX0 = (HA - kPicH) / 2; RMY0 = (VA - kPicW) / 2;
  RCX0 = (HA - kCH) / 2;   RCY0 = (VA - kCW) / 2;

  // **EVERY PICTURE MUST FIT THE MODE, UPRIGHT AND ROTATED**, or the check
  // would be comparing against a rectangle that runs off the raster and would
  // report the module's own clamping as a fault.
  if (MX0 < 0 || MY0 < 0 || CX0 < 0 || CY0 < 0 ||
      RMX0 < 0 || RMY0 < 0 || RCX0 < 0 || RCY0 < 0)
    Fail("mode %d does not hold both screens at 1:1, upright and rotated", M);

  // The two poisons must be injective over the words they cover, must make
  // pictures, and must not collide with each other.  Asserted rather than
  // assumed: a poison that repeats is a memory that cannot tell a fetch of the
  // wrong line from a fetch of the right one.
  {
    std::set<uint32_t> seen;
    long lit = 0;
    for (int w = 0; w < kPicH * kWords; w++) {
      seen.insert(PoisonM(static_cast<uint32_t>(w)));
      for (int b = 0; b < 32; b++) lit += (PoisonM(static_cast<uint32_t>(w)) >> b) & 1u;
    }
    if (seen.size() != static_cast<size_t>(kPicH * kWords))
      Fail("the first display's poison collides: %zu words for %d", seen.size(),
           kPicH * kWords);
    const long total = static_cast<long>(kPicH) * kWords * 32;
    if (lit < total / 3 || lit > 2 * total / 3)
      Fail("the poison makes %ld lit pixels of %ld, which is not a picture", lit, total);
    std::set<uint32_t> cseen;
    std::set<int> colors;
    for (int w = 0; w < kCH * kCWords; w++) {
      cseen.insert(PoisonC(static_cast<uint32_t>(w)));
      if (seen.count(PoisonC(static_cast<uint32_t>(w))))
        Fail("a word of the color window equals one of the first display's");
      for (int n = 0; n < 8; n++)
        colors.insert(static_cast<int>((PoisonC(static_cast<uint32_t>(w)) >> (n * 4)) & 0xFu));
    }
    if (cseen.size() != static_cast<size_t>(kCH * kCWords))
      Fail("the color window's poison collides");
    if (colors.size() != 16)
      Fail("the color picture uses %zu of the sixteen colors", colors.size());
    std::set<uint32_t> ent;
    for (int k = 0; k < 16; k++) {
      const uint32_t e = MapEntry(k);
      if (!(e >> 16) || !((e >> 8) & 0xFF) || !(e & 0xFF))
        Fail("map entry %d has a zero channel", k);
      if (((e >> 16) == ((e >> 8) & 0xFF)) || (((e >> 8) & 0xFF) == (e & 0xFF)) ||
          ((e >> 16) == (e & 0xFF)))
        Fail("map entry %d has two equal channels, so a channel order cannot be seen", k);
      ent.insert(e);
    }
    if (ent.size() != 16) Fail("the map is not injective in the color");
  }

  auto run = [&](int sel, int rot, int ar_wait, int beat_wait, long frames_wanted,
                 bool compare, Result *res, const char *who = "?") {
    std::fprintf(stderr, "    -- configuration %s: sel %d rot %d --\n", who, sel, rot);
    auto *dut = new Vcadr_display_out;
    Slave slave;
    slave.ar_wait = ar_wait;
    slave.beat_wait = beat_wait;
    slave.rot = rot;
    if (getenv("DISP_DUMP")) slave.dump = atol(getenv("DISP_DUMP"));
    Monitor mon;

    dut->clk = 0; dut->pclk = 0; dut->rst = 1; dut->prst = 1;
    dut->out_sel = static_cast<uint8_t>(sel);
    dut->rotate = static_cast<uint8_t>(rot);
    dut->m_arready = 0; dut->m_rdata = 0; dut->m_rresp = 0;
    dut->m_rlast = 0; dut->m_rvalid = 0; dut->map_q = 0;
    // Nobody writes the sleep setting or wakes the display here: the
    // module's own three hundred seconds of real clock is ninety-three
    // thousand frames, and `build/display_sleep.pass` is the check that runs
    // the timer out.  So the lanes must never be muted in these runs.
    dut->sleep_set = 0; dut->sleep_secs = 0; dut->wake = 0;
    dut->eval();

    uint64_t t = 0, next_clk = kClkHalf, next_pclk = kPclkHalf;
    int clk_v = 0, pclk_v = 0;
    long compared = 0, mismatches = 0, black_lines = 0;
    int under_seen = 0;
    std::vector<int> line_got(kPicH, -1);
    int line_have = 0;
    uint32_t col_got = 0;
    int col_have = 0;
    bool line_black = false;
    long base_mono = 0, base_color = 0, base_bursts = 0;
    long per_frame_mono = 0, per_frame_color = 0;

    while (mon.frames <= frames_wanted) {
      const uint64_t tn = (next_clk < next_pclk) ? next_clk : next_pclk;
      const bool ck = (tn == next_clk), pk = (tn == next_pclk);
      t = tn;
      if (t > 900000000000ull) { Fail("the run made no progress"); break; }
      if (ck) { clk_v ^= 1; next_clk += kClkHalf; }
      if (pk) { pclk_v ^= 1; next_pclk += kPclkHalf; }

      const int in_reset = (t < 64000) ? 1 : 0;
      dut->rst = in_reset; dut->prst = in_reset;

      // The color board's map, answered combinationally as
      // `rtl/machine/cadr_tv.sv` answers it.
      dut->map_q = MapEntry(dut->map_a & 15);

      if (ck && clk_v) { slave.Drive(dut); dut->eval(); slave.Sample(dut); }
      dut->clk = clk_v; dut->pclk = pclk_v;
      dut->eval();
      if (ck && clk_v) slave.AfterEdge(dut);

      if (pk && pclk_v) {
        const int de = dut->de, hs = dut->hsync, vs = dut->vsync;
        if (mon.since_hs >= 0) ++mon.since_hs;
        const int hs_a = HPOS ? hs : !hs, vs_a = VPOS ? vs : !vs;
        const int hsp = HPOS ? mon.hs_prev : !mon.hs_prev;
        const int vsp = VPOS ? mon.vs_prev : !mon.vs_prev;
        // **A ZERO-LENGTH PULSE IS NOT A PULSE.**  The two `prev` levels start
        // at zero, and on a mode whose sync is ACTIVE LOW --- which reduced
        // blanking's vertical sync is, and is how a sink knows it --- the idle
        // level is one, so the first sample reads as a trailing edge and would
        // record a width of nothing.  That is the check's own artefact and not
        // the raster's, so it is dropped where it is made rather than allowed
        // for in the comparison.
        if (hs_a) ++mon.hs_high;
        else if (hsp && mon.hs_high > 0) mon.hs_widths.insert(mon.hs_high);
        if (!hs_a && hsp) mon.hs_high = 0;
        if (vs_a) ++mon.vs_high;
        else if (vsp && mon.vs_high > 0) mon.vs_widths.insert(mon.vs_high);
        if (!vs_a && vsp) mon.vs_high = 0;

        if (hs_a && !hsp) {
          if (mon.since_hs > 0) {
            mon.line_lengths.insert(mon.since_hs);
            mon.de_widths.insert(mon.de_this_line);
          }
          mon.since_hs = 0;
          mon.de_this_line = 0;
          if (mon.lines_this_frame >= 0) ++mon.lines_this_frame;
        }
        if (vs_a && !vsp) {
          if (mon.lines_this_frame > 0) {
            mon.frame_lengths.insert(mon.lines_this_frame);
            mon.active_per_frame.insert(mon.active_lines);
            // What the port moved over one whole frame, which is how "the
            // picture is read exactly once a frame" is measured.
          }
          ++mon.frames;
          // **THE SETTINGS TAKE AT THE TOP OF A FRAME, SO FRAME ONE RUNS ON THE
          // FABRIC'S OWN DEFAULTS AND FRAME TWO IS THE CHANGEOVER.**  Frame two
          // legitimately shows a bank filled for the other geometry --- it is
          // the one frame where what was asked for is not what is wanted --- so
          // everything is compared and counted from frame THREE.  A check that
          // compared frame two would be asking the module to have fetched
          // something before it was told to.
          if (mon.frames == 3) {
            slave.live = 1;
            base_mono = slave.mono_beats; base_color = slave.color_beats;
            base_bursts = slave.bursts;
          }
          if (mon.frames >= 4) {
            per_frame_mono = (slave.mono_beats - base_mono) / (mon.frames - 3);
            per_frame_color = (slave.color_beats - base_color) / (mon.frames - 3);
          }
          mon.lines_this_frame = 0;
          mon.active_lines = 0;
          mon.y = -1;
        }
        if (dut->mute) Fail("the lanes were muted at frame %ld, and nothing ran the timer out",
                            mon.frames);
        if (dut->underrun && !under_seen) {
          under_seen = 1;
          std::fprintf(stderr, "       underrun first seen at frame %ld line %d\n",
                       mon.frames, mon.y);
        }
        if (de && !mon.de_prev) { mon.x = 0; ++mon.y; ++mon.active_lines;
                                  if (mon.since_hs >= 0) mon.hs_to_de.insert(mon.since_hs);
                                  line_black = true; }
        if (de && getenv("DISP_COL") && rot == 1 && mon.frames == 3 &&
            mon.x == RMX0 + atoi(getenv("DISP_COL")) &&
            mon.y >= RMY0 && mon.y < RMY0 + 32) {
          if (dut->red) col_got |= 1u << (mon.y - RMY0);
          col_have = 1;
        }
        if (de && getenv("DISP_LINE") && rot && mon.frames == 3 &&
            mon.y == atoi(getenv("DISP_LINE"))) {
          const int px = mon.x - RMX0;
          if (px >= 0 && px < kPicH) line_got[px] = (dut->red != 0);
          line_have = 1;
        }
        if (de) {
          const uint32_t got = (static_cast<uint32_t>(dut->red) << 16) |
                               (static_cast<uint32_t>(dut->green) << 8) |
                               static_cast<uint32_t>(dut->blue);
          if (got) line_black = false;
          if (compare && mon.frames >= 3 && mon.y >= 0 && mon.y < VA) {
            const uint32_t want = WantRGB(mon.x, mon.y, sel, rot);
            if (got != want) {
              if (++mismatches <= 4) {
                Fail("pixel (%d,%d) is %06x, want %06x", mon.x, mon.y, got, want);
                int row, col;
                if (rot && (sel & 1) && MonoSrc(mon.x, mon.y, rot, &row, &col)) {
                  std::fprintf(stderr,
                      "       frame %ld: source row %d column %d --- band %d,"
                      " entry %d, half %d, bit %d\n",
                      mon.frames, row, col, col / 32, row / 2, row & 1, col % 32);
                  for (int b = 0; b < kWords; b++) {
                    const uint32_t w = static_cast<uint32_t>(row) * kWords + static_cast<uint32_t>(b);
                    const bool lit = ((PoisonM(w) >> (col % 32)) & 1u) != 0u;
                    if (lit == (got != 0))
                      std::fprintf(stderr, "       band %d would give this bit\n", b);
                  }
                  for (int r = 0; r < kPicH; r++) {
                    const uint32_t w = static_cast<uint32_t>(r) * kWords + static_cast<uint32_t>(col / 32);
                    const bool lit = ((PoisonM(w) >> (col % 32)) & 1u) != 0u;
                    if (lit == (got != 0) && (r == row - 1 || r == row + 1 ||
                                              r == row - 2 || r == row + 2))
                      std::fprintf(stderr, "       row %d would give this bit\n", r);
                  }
                }
              } else if (mismatches == 5) ++bad;
            }
            ++compared;
          }
          ++mon.x; ++mon.de_this_line;
        } else {
          if (mon.de_prev && line_black && mon.y >= 0 && mon.y < VA) ++black_lines;
          if (dut->red || dut->green || dut->blue)
            Fail("a channel is lit outside de at line %d", mon.y);
        }
        mon.de_prev = de; mon.hs_prev = hs; mon.vs_prev = vs;
      }
    }

    // The per-frame totals, taken from the slave over the whole run and divided
    // rather than sampled: simpler, and a run of whole frames makes it exact to
    // within one job either end.
    if (col_have) {
      const int px = atoi(getenv("DISP_COL"));
      const int row = kPicH - 1 - px;
      std::fprintf(stderr, "       column px %d (source row %d), band 0's 32 bits:"
                   " got %08x want %08x\n", px, row, col_got,
                   PoisonM(static_cast<uint32_t>(row) * kWords));
      for (int w = 0; w < kPicH * kWords; w++)
        if (PoisonM(static_cast<uint32_t>(w)) == col_got)
          std::fprintf(stderr, "       it is word %d --- row %d band %d\n",
                       w, w / kWords, w % kWords);
    }
    if (line_have) {
      // **WHAT DID THE MODULE PUT ON A WHOLE ROTATED LINE, AND WHICH (band,
      // bit) WOULD HAVE PRODUCED IT?**  One pixel names half the bands by
      // chance; 963 of them name one.
      const int want_y = atoi(getenv("DISP_LINE"));
      {
        long filled = 0;
        for (int px = 0; px < kPicH; px++) if (line_got[px] >= 0) ++filled;
        std::fprintf(stderr, "       line %d: %ld of %d pixels captured, rot %d\n",
                     want_y, filled, kPicH, rot);
        std::fprintf(stderr, "       got   :");
        for (int px = 0; px < 48; px++) std::fprintf(stderr, "%d", line_got[px] < 0 ? 9 : line_got[px]);
        std::fprintf(stderr, "\n       want  :");
        for (int px = 0; px < 48; px++) {
          const int row = (rot == 1) ? (kPicH - 1 - px) : px;
          std::fprintf(stderr, "%d", MonoLit(row, want_y - RMY0) ? 1 : 0);
        }
        std::fprintf(stderr, "\n");
      }
      int hits = 0;
      for (int b = 0; b < kWords; b++)
        for (int k = 0; k < 32; k++) {
          int ok = 1;
          for (int px = 0; px < kPicH && ok; px++) {
            if (line_got[px] < 0) continue;
            const int row = (rot == 1) ? (kPicH - 1 - px) : px;
            const uint32_t w = static_cast<uint32_t>(row) * kWords + static_cast<uint32_t>(b);
            if ((((PoisonM(w) >> k) & 1u) != 0) != (line_got[px] != 0)) ok = 0;
          }
          if (ok) { std::fprintf(stderr, "       line %d IS band %d bit %d\n", want_y, b, k); ++hits; }
        }
      if (!hits) {
        // Not any (band, bit) of this orientation: try the other one, and try
        // the upright shape, which is what a buffer still holding lines is.
        for (int b = 0; b < kWords && !hits; b++)
          for (int k = 0; k < 32 && !hits; k++) {
            int ok = 1;
            for (int px = 0; px < kPicH && ok; px++) {
              if (line_got[px] < 0) continue;
              const int row = (rot == 1) ? px : (kPicH - 1 - px);
              const uint32_t w = static_cast<uint32_t>(row) * kWords + static_cast<uint32_t>(b);
              if ((((PoisonM(w) >> k) & 1u) != 0) != (line_got[px] != 0)) ok = 0;
            }
            if (ok) { std::fprintf(stderr, "       line %d IS band %d bit %d, the OTHER way up\n", want_y, b, k); ++hits; }
          }
      }
      if (!hits) {
        long lit = 0, dark = 0;
        for (int px = 0; px < kPicH; px++) { if (line_got[px] > 0) ++lit; else if (line_got[px] == 0) ++dark; }
        std::fprintf(stderr, "       line %d matches no (band, bit): %ld lit, %ld dark\n",
                     want_y, lit, dark);
        std::fprintf(stderr, "       first 64 pixels:");
        for (int px = 0; px < 64; px++) std::fprintf(stderr, "%d", line_got[px] < 0 ? 9 : line_got[px]);
        std::fprintf(stderr, "\n       wanted        :");
        for (int px = 0; px < 64; px++) {
          const int row = kPicH - 1 - px;
          std::fprintf(stderr, "%d", MonoLit(row, 0) ? 1 : 0);
        }
        std::fprintf(stderr, "\n");
      }
    }
    res->underruns = dut->underrun;
    res->compared = compared;
    res->black_lines = black_lines;
    res->bursts = slave.bursts;
    res->mono_beats = per_frame_mono;
    res->color_beats = per_frame_color;
    res->max_in_flight = slave.max_in_flight;
    if (slave.ar_handshakes != slave.bursts)
      Fail("%ld address handshakes for %ld bursts", slave.ar_handshakes, slave.bursts);
    // The run stops wherever the frame count runs out, so as many bursts as the
    // master may hold at once can still be open at the end.
    if (slave.rlasts > slave.bursts || slave.bursts - slave.rlasts > kOutstanding)
      Fail("%ld RLASTs for %ld bursts", slave.rlasts, slave.bursts);
    if (dut->rd_error) Fail("the module reported a read error and none was given");
    (void)base_bursts;
    delete dut;
    return mon;
  };

  auto one = [&](const std::set<long> &s, long want, const char *what) {
    if (s.size() != 1 || *s.begin() != want) {
      std::fprintf(stderr, "FAIL: %s came out as", what);
      for (long v : s) std::fprintf(stderr, " %ld", v);
      std::fprintf(stderr, ", want exactly %ld\n", want);
      ++bad;
    }
  };

  // ------------------------------------------------------ configuration A
  Result a;
  Monitor mon = run(1, 0, 0, 0, 4, true, &a, "A mono upright");
  one(mon.line_lengths, HT, "the pixels in a line");
  one(mon.hs_widths, HS, "the hsync pulse, in pixels");
  one(mon.hs_to_de, HS + HB, "hsync's edge to de's");
  one(mon.frame_lengths, VT, "the lines in a frame");
  one(mon.vs_widths, static_cast<long>(VS) * HT, "the vsync pulse, in pixels");
  one(mon.active_per_frame, VA, "the enabled lines in a frame");
  if (mon.de_widths.size() != 2 || mon.de_widths.count(0) != 1 ||
      mon.de_widths.count(HA) != 1) {
    std::fprintf(stderr, "FAIL: the enabled pixels in a line came out as");
    for (long v : mon.de_widths) std::fprintf(stderr, " %ld", v);
    std::fprintf(stderr, ", want exactly 0 and %d\n", HA);
    ++bad;
  }
  if (a.underruns) Fail("the port kept up and the module reported an underrun");
  if (a.compared < static_cast<long>(HA) * VA)
    Fail("only %ld pixels compared, want at least %d", a.compared, HA * VA);
  // **THE PICTURE IS READ ONCE A FRAME AND THE COLOR WINDOW IS NOT READ AT
  // ALL.**  963 lines of twelve beats over the run's whole frames, and nothing
  // from a screen that is not being shown.
  if (a.color_beats != 0)
    Fail("%ld beats came out of the color window with only the first display shown",
         a.color_beats);
  if (a.mono_beats != static_cast<long>(kPicH) * (kWords / 2))
    Fail("%ld beats a frame for the first display, want %ld --- the picture read once",
         a.mono_beats, static_cast<long>(kPicH) * (kWords / 2));

  if (M == 0) {
    // ---------------------------------------------------- configuration B
    Result b;
    (void)run(1, 0, 40, 200, 3, false, &b, "B mono upright, port slowed");
    if (!b.underruns) Fail("the port could not keep up and no underrun was reported");
    if (b.black_lines == 0) Fail("the port could not keep up and no line was shown black");

    // ---------------------------------------------------- configuration C
    Result c;
    (void)run(2, 0, 0, 0, 4, true, &c, "C color upright");
    if (c.underruns) Fail("the color screen reported an underrun at the port's own speed");
    if (c.mono_beats != 0)
      Fail("%ld beats came out of the first display's window with only the color screen shown",
           c.mono_beats);
    if (c.color_beats != static_cast<long>(kCH) * (kCWords / 2))
      Fail("%ld beats a frame for the color screen, want %ld", c.color_beats,
           static_cast<long>(kCH) * (kCWords / 2));

    // ---------------------------------------------------- configuration D
    Result d;
    (void)run(3, 0, 0, 0, 4, true, &d, "D both upright");
    if (d.underruns) Fail("both screens at once reported an underrun");
    if (d.mono_beats == 0 || d.color_beats == 0)
      Fail("both screens were asked for and one window was never read");

    // -------------------------------------------------- configurations E, F
    for (int rot = 1; rot <= 2; rot++) {
      Result e;
      (void)run(1, rot, 0, getenv("DISP_BW") ? atoi(getenv("DISP_BW")) : 4, 4, true, &e, rot == 1 ? "E mono clockwise" : "F mono anticlockwise");
      if (e.underruns) Fail("the rotated first display reported an underrun");
      if (e.max_in_flight < 2)
        Fail("the band fetch never had two reads in flight, so the address"
             " channel running ahead of the data is untested");
      // A band is one word out of each of the picture's rows and there are as
      // many bands as the picture is words wide, so a frame is the picture.
      const long want = static_cast<long>(kWords) * kPicH;
      if (e.mono_beats != want)
        Fail("%ld beats a frame for the rotated first display, want %ld",
             e.mono_beats, want);
    }

    // ---------------------------------------------------- configuration G
    Result g;
    (void)run(3, 1, 0, 4, 4, true, &g, "G both clockwise");
    if (g.underruns) Fail("both screens rotated reported an underrun");
    if (g.mono_beats == 0 || g.color_beats == 0)
      Fail("both screens were asked for rotated and one window was never read");
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems\n", bad);
    return 1;
  }
  std::printf(
      "ok: mode %d, %s\n"
      "    %ld pixels compared against two DDR windows poisoned injectively in\n"
      "    the address --- the first display's bits, the color board's nibbles\n"
      "    through a sixteen-entry map, and the border black\n"
      "    the raster counted: %d pixels a line, %d of them enabled, hsync %d\n"
      "    wide and %d before de; %d lines a frame, %d enabled, vsync %d;\n"
      "    hsync %s and vsync %s\n"
      "%s",
      M, kModes[M].name, a.compared, HT, HA, HS, HS + HB, VT, VA, VS,
      HPOS ? "positive" : "negative", VPOS ? "positive" : "negative",
      M == 0 ? "    and on this mode: the color screen alone, both with the color one\n"
               "    drawn over the first, both quarter turns, and both rotated at once;\n"
               "    the underrun reported with the port slowed to 200 clocks a beat\n"
             : "");
  return 0;
}
