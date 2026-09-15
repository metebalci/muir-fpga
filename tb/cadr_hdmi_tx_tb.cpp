// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_hdmi_tx` against a second encoder written from DVI 1.0.
//
// **THE REFERENCE HERE IS NOT THE RTL RESTATED.**  It is the specification's
// own pseudocode --- section 3.2.2, figure 3-5 --- transcribed with `N0` and
// `N1` both present in every branch, which is the shape the fabric
// deliberately does NOT use: `cadr_tmds_encode.sv` folds them into one signed
// difference so that four expressions cannot disagree about a sign.  Two
// different shapes of the same arithmetic is the whole value of this check.
// A reference written by copying the RTL would agree with it about anything.
//
// **AND THE SWEEP IS EXHAUSTIVE OVER THE ENCODER'S STATE, NOT A SAMPLE OF
// IT.**  The output depends on the byte and on the running disparity, and
// the disparity cannot be written from outside --- it can only be driven
// there.  So the reference model is used to search: every disparity value
// reachable from a control period is found by breadth-first search, with the
// shortest sequence of bytes that reaches it, and then every one of the 256
// byte values is tested in every one of those states by playing that
// sequence through the device first.  The check reports how many states it
// found and refuses to pass on fewer than the whole reachable set.
//
// What this cannot hold is the serializer: `OSERDESE2` and `OBUFDS` are
// primitives, their stubs in `tb/cadr_arty_stubs.sv` tie their outputs low,
// and a check built on a stub confirms rather than compares.  See
// `docs/display-output.md`.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <vector>

#include "Vcadr_hdmi_tx.h"
#include "verilated.h"

namespace {

long tick = 0;
int bad = 0;

void Fail(const char *what, int ch, unsigned d, int c, int de, int cnt,
          unsigned got, unsigned want) {
  if (++bad <= 20) {
    std::fprintf(stderr,
                 "FAIL tick %ld: channel %d, d=0x%02x c=%d de=%d disparity %d:"
                 " got %03x, want %03x\n",
                 tick, ch, d, c, de, cnt, got, want);
  }
}

// ---------------------------------------------------------------- the model
//
// DVI 1.0 figure 3-5, one branch at a time.  `cnt` is the running disparity
// and is reset by any control period.
struct Ref {
  int cnt = 0;

  static int Ones(unsigned v, int n) {
    int k = 0;
    for (int i = 0; i < n; i++) k += (v >> i) & 1u;
    return k;
  }

  unsigned Encode(unsigned D, int C, bool DE) {
    if (!DE) {
      cnt = 0;
      switch (C & 3) {
        case 0: return 0x354u;   // 1101010100
        case 1: return 0x0ABu;   // 0010101011
        case 2: return 0x154u;   // 0101010100
        default: return 0x2ABu;  // 1010101011
      }
    }

    // Stage one: transition minimization.
    const int n1d = Ones(D, 8);
    const bool xnor_mode = (n1d > 4) || (n1d == 4 && ((D & 1u) == 0u));
    int qm[9];
    qm[0] = static_cast<int>(D & 1u);
    for (int i = 1; i < 8; i++) {
      const int di = static_cast<int>((D >> i) & 1u);
      qm[i] = xnor_mode ? !(qm[i - 1] ^ di) : (qm[i - 1] ^ di);
    }
    qm[8] = xnor_mode ? 0 : 1;

    // Stage two: direct-current balance.
    int N1 = 0;
    for (int i = 0; i < 8; i++) N1 += qm[i];
    const int N0 = 8 - N1;

    int q[10];
    if (cnt == 0 || N1 == N0) {
      q[9] = !qm[8];
      q[8] = qm[8];
      for (int i = 0; i < 8; i++) q[i] = qm[8] ? qm[i] : !qm[i];
      cnt = qm[8] ? (cnt + N1 - N0) : (cnt + N0 - N1);
    } else if ((cnt > 0 && N1 > N0) || (cnt < 0 && N0 > N1)) {
      q[9] = 1;
      q[8] = qm[8];
      for (int i = 0; i < 8; i++) q[i] = !qm[i];
      cnt = cnt + 2 * qm[8] + (N0 - N1);
    } else {
      q[9] = 0;
      q[8] = qm[8];
      for (int i = 0; i < 8; i++) q[i] = qm[i];
      cnt = cnt - 2 * (1 - qm[8]) + (N1 - N0);
    }

    unsigned out = 0;
    for (int i = 0; i < 10; i++) out |= static_cast<unsigned>(q[i]) << i;
    return out;
  }
};

uint32_t rnd_state = 0x1D0FA11u;
uint32_t Rnd() {
  rnd_state = rnd_state * 1664525u + 1013904223u;
  return rnd_state >> 8;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_hdmi_tx;

  Ref r0, r1, r2;   // one per channel, as the fabric has one per channel

  dut->pclk = 0;
  dut->prst = 1;
  dut->red = 0; dut->green = 0; dut->blue = 0;
  dut->de = 0; dut->hsync = 0; dut->vsync = 0;
  dut->eval();

  // One symbol: drive, clock, then read what came out of it.
  auto step = [&](unsigned red, unsigned green, unsigned blue, bool de,
                  bool hs, bool vs) {
    dut->red = red; dut->green = green; dut->blue = blue;
    dut->de = de ? 1 : 0;
    dut->hsync = hs ? 1 : 0;
    dut->vsync = vs ? 1 : 0;
    dut->pclk = 0; dut->eval();
    dut->pclk = 1; dut->eval();
    ++tick;
  };

  auto compare = [&](unsigned red, unsigned green, unsigned blue, bool de,
                     bool hs, bool vs) {
    const int c0 = (vs ? 2 : 0) | (hs ? 1 : 0);
    const int d0 = r0.cnt, d1 = r1.cnt, d2 = r2.cnt;
    const unsigned w0 = r0.Encode(blue, c0, de);
    const unsigned w1 = r1.Encode(green, 0, de);
    const unsigned w2 = r2.Encode(red, 0, de);
    step(red, green, blue, de, hs, vs);
    if (dut->tmds0 != w0) Fail("ch0", 0, blue, c0, de, d0, dut->tmds0, w0);
    if (dut->tmds1 != w1) Fail("ch1", 1, green, 0, de, d1, dut->tmds1, w1);
    if (dut->tmds2 != w2) Fail("ch2", 2, red, 0, de, d2, dut->tmds2, w2);
    // The clock channel is a constant: five low then five high, bit 0 first.
    if (dut->tmds_clk != 0x01Fu) {
      if (++bad <= 20) {
        std::fprintf(stderr, "FAIL tick %ld: clock channel %03x, want 01f\n",
                     tick, dut->tmds_clk);
      }
    }
  };

  // Release reset with a control period, which is what a blanking interval
  // is and what puts every channel's disparity at a known zero.
  for (int i = 0; i < 4; i++) {
    dut->prst = (i < 2) ? 1 : 0;
    if (i >= 2) { compare(0, 0, 0, false, false, false); }
    else        { step(0, 0, 0, false, false, false); }
  }
  r0.cnt = r1.cnt = r2.cnt = 0;

  // ------------------------------------------------------------ the search
  //
  // Every disparity reachable from zero, and the shortest byte sequence that
  // reaches it.  Breadth-first over the reference model, which is legitimate
  // because the model is the thing being trusted for the sweep's SHAPE while
  // the device is the thing being compared for its VALUES.
  std::map<int, std::vector<unsigned>> path;
  path[0] = {};
  {
    std::vector<int> frontier{0};
    while (!frontier.empty()) {
      std::vector<int> next;
      for (int cnt : frontier) {
        for (unsigned b = 0; b < 256; b++) {
          Ref probe;
          probe.cnt = cnt;
          probe.Encode(b, 0, true);
          if (path.find(probe.cnt) == path.end()) {
            std::vector<unsigned> p = path[cnt];
            p.push_back(b);
            path[probe.cnt] = p;
            next.push_back(probe.cnt);
          }
        }
      }
      frontier.swap(next);
    }
  }

  const size_t states = path.size();

  // ------------------------------------------------- every byte, every state
  long cases = 0;
  std::set<std::pair<int, unsigned>> covered;
  for (const auto &kv : path) {
    for (unsigned b = 0; b < 256; b++) {
      // A control period puts every channel back at zero, and it is also the
      // only way to get there, so each case starts with one.
      compare(0, 0, 0, false, false, false);
      for (unsigned step_b : kv.second) compare(step_b, step_b, step_b, true, false, false);
      if (r0.cnt != kv.first) {
        std::fprintf(stderr,
                     "FAIL: the search's own path did not reach disparity %d"
                     " (reached %d)\n", kv.first, r0.cnt);
        ++bad;
        break;
      }
      covered.insert({kv.first, b});
      compare(b, b, b, true, false, false);
      ++cases;
    }
  }

  // ------------------------------------------------------ the control tokens
  //
  // All four, and that each resets the disparity: the byte before each one is
  // chosen to leave the disparity away from zero.
  long tokens = 0;
  for (int hs = 0; hs < 2; hs++) {
    for (int vs = 0; vs < 2; vs++) {
      compare(0, 0, 0, false, false, false);
      compare(0xFF, 0xFF, 0xFF, true, false, false);   // moves the disparity
      compare(0, 0, 0, false, hs != 0, vs != 0);
      if (r0.cnt != 0) {
        std::fprintf(stderr, "FAIL: a control period left disparity %d\n", r0.cnt);
        ++bad;
      }
      ++tokens;
      // And that channels 1 and 2 send the C1C0 = 00 token whatever the
      // syncs are doing, which is the channel assignment DVI fixes.
      if (dut->tmds1 != 0x354u || dut->tmds2 != 0x354u) {
        std::fprintf(stderr,
                     "FAIL: with hsync=%d vsync=%d channels 1 and 2 sent"
                     " %03x/%03x, want 354 on both\n",
                     hs, vs, dut->tmds1, dut->tmds2);
        ++bad;
      }
    }
  }

  // ------------------------------------------------------- a running stream
  //
  // Pixels and blanking mixed, every cycle compared, so that the ordinary
  // path through the module is exercised as well as the constructed states.
  long stream = 0;
  for (long i = 0; i < 200000; i++) {
    const uint32_t v = Rnd();
    const bool de = (v & 7u) != 0;      // mostly video, some blanking
    compare((v >> 3) & 0xFFu, (v >> 11) & 0xFFu, (v >> 19) & 0xFFu, de,
            ((v >> 27) & 1u) != 0, ((v >> 28) & 1u) != 0);
    ++stream;
  }

  const bool short_sweep = covered.size() != states * 256u;
  if (short_sweep) {
    std::fprintf(stderr,
                 "FAIL: swept %zu (disparity, byte) pairs, wanted %zu\n",
                 covered.size(), states * 256u);
    ++bad;
  }
  if (states < 8) {
    std::fprintf(stderr,
                 "FAIL: the search found only %zu disparity states, which is"
                 " too few for the sweep to mean anything\n", states);
    ++bad;
  }

  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::printf(
      "ok: the transmitter agrees with DVI 1.0 over %ld symbols\n"
      "    %zu disparity states reachable from a control period, found by\n"
      "    breadth-first search; %ld (state, byte) cases, which is every one\n"
      "    of 256 bytes in every one of them\n"
      "    %ld control periods, all four tokens, disparity reset at each\n"
      "    %ld pseudorandom symbols of mixed video and blanking\n"
      "    the clock channel constant at 01f throughout\n",
      tick, states, cases, tokens, stream);
  return 0;
}
