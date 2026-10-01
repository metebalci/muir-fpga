// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The faces' word on a 128-bit master port: `rtl/plumbing/cadr_axi_lanes128.sv`.
//
// THE STIMULUS PLACES THE WORD IN ITS LANE ITSELF, AS THE PORT DOES, AND
// FILLS THE OTHER THREE LANES WITH DIFFERENT WORDS: a word store at lane l
// puts the word in lane l and opens that lane's strobes only, and the other
// lanes carry whatever the port's data path held, so a module that took the
// wrong lane hands down a wrong word and not the right one by accident.  The
// expected word comes from the stimulus, never from the DUT.
//
// Also held: a partial store keeps its own byte strobes; a store with no
// strobe open goes down with no strobe open; a store wider than a word goes
// down as the lowest strobed lane's word with that lane's strobes, as the
// module's header says; and a read's word is in every lane.

#include <cstdint>
#include <cstdio>

#include "Vcadr_axi_lanes128.h"
#include "verilated.h"

namespace {

unsigned lcg(unsigned &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

int bad = 0;
long op = 0;

void fail(const char *what, uint64_t got, uint64_t want) {
  if (bad < 20)
    std::fprintf(stderr, "op %ld: %s is 0x%llx, expected 0x%llx\n", op, what,
                 static_cast<unsigned long long>(got),
                 static_cast<unsigned long long>(want));
  ++bad;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_axi_lanes128;
  unsigned seed = 20261002u;
  long lane_stores[4] = {}, partial = 0, empty = 0, wide = 0, reads = 0;

  for (op = 0; op < 100000; ++op) {
    uint32_t w[4];
    for (int k = 0; k < 4; ++k) w[k] = (lcg(seed) << 8) ^ lcg(seed) ^ (0x11111111u * k);
    // No two lanes equal, so a wrong lane is never right by accident.
    for (int k = 1; k < 4; ++k)
      for (int j = 0; j < k; ++j)
        if (w[k] == w[j]) w[k] ^= 0x80000000u >> k;

    const unsigned kind = lcg(seed) % 16;
    unsigned strb16 = 0, want_strb = 0;
    uint32_t want_word = 0;
    if (kind == 0) {
      // No strobe open: nothing written, and the face is told so.
      strb16 = 0;
      want_strb = 0;
      want_word = w[3];
      ++empty;
    } else if (kind == 1) {
      // A doubleword or wider: the lowest strobed lane's word.
      const int lo = static_cast<int>(lcg(seed) % 3);
      const int n = 2 + static_cast<int>(lcg(seed) % (4 - lo - 1));
      for (int k = lo; k < lo + n && k < 4; ++k) strb16 |= 0xFu << (4 * k);
      want_strb = 0xF;
      want_word = w[lo];
      ++wide;
    } else {
      const int l = static_cast<int>(lcg(seed) % 4);
      unsigned s = lcg(seed) & 0xF;
      if (s == 0 || (lcg(seed) & 1)) s = 0xF;
      if (s != 0xF) ++partial;
      strb16 = s << (4 * l);
      want_strb = s;
      want_word = w[l];
      ++lane_stores[l];
    }
    for (int k = 0; k < 4; ++k) dut->s_wdata[k] = w[k];
    dut->s_wstrb = strb16;
    const uint32_t r = (lcg(seed) << 8) ^ lcg(seed);
    dut->m_rdata = r;
    dut->eval();
    if (dut->m_wdata != want_word) fail("m_wdata", dut->m_wdata, want_word);
    if (dut->m_wstrb != want_strb) fail("m_wstrb", dut->m_wstrb, want_strb);
    for (int k = 0; k < 4; ++k)
      if (dut->s_rdata[k] != r) fail("a lane of s_rdata", dut->s_rdata[k], r);
    ++reads;
  }
  for (int l = 0; l < 4; ++l) {
    std::printf("axi_lanes128: lane %d: %ld word stores\n", l, lane_stores[l]);
    if (!lane_stores[l]) ++bad;
  }
  std::printf("axi_lanes128: %ld partial, %ld with no strobe, %ld wider than a word, %ld reads\n",
              partial, empty, wide, reads);
  if (!partial || !empty || !wide) ++bad;
  delete dut;
  if (bad) {
    std::fprintf(stderr, "axi_lanes128: FAILED, %d mismatches\n", bad);
    return 1;
  }
  std::printf("axi_lanes128: ok\n");
  return 0;
}
