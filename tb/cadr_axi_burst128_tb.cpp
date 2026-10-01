// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A 64-bit burst master on a 128-bit port: `rtl/plumbing/cadr_axi_burst128.sv`.
//
// THE HALF A BEAT BELONGS IN IS WORKED OUT HERE FROM THE BURST'S ADDRESS AND
// THE BEAT'S NUMBER, AND NEVER READ FROM THE DUT: beat k of a burst at A is
// at A + 8k, and bit 3 of that says which half.  Each burst starts at a
// random eight-byte-aligned address, so it begins in either half, and has a
// random length of one to sixteen beats, odd and even, so a count that did
// not go back to zero at the burst's end would start the next burst in the
// wrong half.
//
// THE CHANNELS RUN AT ONCE AND STALL AT RANDOM, as the port and the master
// would let them: a write burst and a read burst are in flight together,
// valid and ready each drop at random, and the module may count only the
// beats that were taken.  The address stands from the burst's start to its
// last beat, as `cadr_disk_pack.sv` holds it, and changes between bursts.
//
// On a write the doubleword must be in both halves and the strobes must open
// the beat's half only, with the master's own strobes in it; on a read the
// doubleword must come from the beat's half, the other half carrying a
// different word so that a wrong half is a wrong answer.

#include <cstdint>
#include <cstdio>

#include "Vcadr_axi_burst128.h"
#include "verilated.h"

namespace {

unsigned lcg(unsigned &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

int bad = 0;
long cyc = 0;

void fail(const char *what, uint64_t got, uint64_t want) {
  if (bad < 20)
    std::fprintf(stderr, "cycle %ld: %s is 0x%llx, expected 0x%llx\n", cyc, what,
                 static_cast<unsigned long long>(got),
                 static_cast<unsigned long long>(want));
  ++bad;
}

uint64_t word64(unsigned &s) {
  return (static_cast<uint64_t>((lcg(s) << 8) ^ lcg(s)) << 32) ^ ((lcg(s) << 8) ^ lcg(s));
}

struct Burst {
  uint32_t addr = 0;
  unsigned len = 0;  // beats - 1
  unsigned beat = 0;
};

void new_burst(Burst &b, unsigned &s) {
  b.addr = ((lcg(s) << 8) ^ lcg(s)) & 0x7FFF'FFF8u;
  b.len = lcg(s) % 16;
  b.beat = 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_axi_burst128;
  unsigned seed = 20261003u;

  dut->clk = 0;
  dut->rst = 1;
  dut->s_wvalid = 0;
  dut->s_wready = 0;
  dut->s_rvalid = 0;
  dut->s_rready = 0;
  for (int i = 0; i < 4; ++i) {
    dut->clk = !dut->clk;
    dut->eval();
  }
  dut->rst = 0;

  Burst w, r;
  new_burst(w, seed);
  new_burst(r, seed);
  long wbeats[2] = {}, rbeats[2] = {}, wbursts = 0, rbursts = 0;
  long wstart[2] = {}, rstart[2] = {}, stalls = 0;

  for (cyc = 0; cyc < 400000; ++cyc) {
    // Drive on the low phase.
    dut->clk = 0;
    const uint64_t wd = word64(seed);
    const unsigned ws = (lcg(seed) & 0xFF) | 1;
    const uint64_t lo = word64(seed);
    uint64_t hi = word64(seed);
    if (hi == lo) hi ^= 1;
    dut->s_awaddr = w.addr;
    dut->s_awlen = w.len;
    dut->s_awsize = 3;
    dut->s_araddr = r.addr;
    dut->s_arlen = r.len;
    dut->s_arsize = 3;
    dut->s_wdata = wd;
    dut->s_wstrb = ws;
    dut->s_wlast = (w.beat == w.len);
    dut->s_wvalid = (lcg(seed) % 4) != 0;
    dut->s_wready = (lcg(seed) % 3) != 0;
    dut->s_rlast = (r.beat == r.len);
    dut->s_rvalid = (lcg(seed) % 4) != 0;
    dut->s_rready = (lcg(seed) % 3) != 0;
    if (!(dut->s_wvalid && dut->s_wready)) ++stalls;
    dut->m_rdata[0] = static_cast<uint32_t>(lo);
    dut->m_rdata[1] = static_cast<uint32_t>(lo >> 32);
    dut->m_rdata[2] = static_cast<uint32_t>(hi);
    dut->m_rdata[3] = static_cast<uint32_t>(hi >> 32);
    dut->eval();

    // The half each channel's beat is in, from the stimulus.
    const unsigned wh = ((w.addr + 8u * w.beat) >> 3) & 1;
    const unsigned rh = ((r.addr + 8u * r.beat) >> 3) & 1;

    if (dut->m_awaddr != w.addr) fail("m_awaddr", dut->m_awaddr, w.addr);
    if (dut->m_araddr != r.addr) fail("m_araddr", dut->m_araddr, r.addr);
    if (dut->m_awlen != w.len) fail("m_awlen", dut->m_awlen, w.len);
    if (dut->m_arlen != r.len) fail("m_arlen", dut->m_arlen, r.len);
    if (dut->m_awsize != 3) fail("m_awsize", dut->m_awsize, 3);
    if (dut->m_arsize != 3) fail("m_arsize", dut->m_arsize, 3);
    const uint64_t got_lo = (static_cast<uint64_t>(dut->m_wdata[1]) << 32) | dut->m_wdata[0];
    const uint64_t got_hi = (static_cast<uint64_t>(dut->m_wdata[3]) << 32) | dut->m_wdata[2];
    if (got_lo != wd) fail("m_wdata's low half", got_lo, wd);
    if (got_hi != wd) fail("m_wdata's high half", got_hi, wd);
    const unsigned want_strb = wh ? (ws << 8) : ws;
    if (dut->m_wstrb != want_strb) fail("m_wstrb", dut->m_wstrb, want_strb);
    const uint64_t want_r = rh ? hi : lo;
    if (dut->s_rdata != want_r) fail("s_rdata", dut->s_rdata, want_r);

    // The edge: count the beats taken.
    const bool wtake = dut->s_wvalid && dut->s_wready;
    const bool rtake = dut->s_rvalid && dut->s_rready;
    dut->clk = 1;
    dut->eval();
    if (wtake) {
      if (w.beat == 0) ++wstart[(w.addr >> 3) & 1];
      ++wbeats[wh];
      if (w.beat == w.len) { new_burst(w, seed); ++wbursts; } else ++w.beat;
    }
    if (rtake) {
      if (r.beat == 0) ++rstart[(r.addr >> 3) & 1];
      ++rbeats[rh];
      if (r.beat == r.len) { new_burst(r, seed); ++rbursts; } else ++r.beat;
    }
  }

  std::printf("axi_burst128: %ld write bursts (%ld from the low half, %ld from the high), "
              "beats %ld low %ld high\n", wbursts, wstart[0], wstart[1], wbeats[0], wbeats[1]);
  std::printf("axi_burst128: %ld read bursts (%ld from the low half, %ld from the high), "
              "beats %ld low %ld high; %ld write stalls\n",
              rbursts, rstart[0], rstart[1], rbeats[0], rbeats[1], stalls);
  if (!wstart[0] || !wstart[1] || !rstart[0] || !rstart[1] || !stalls) ++bad;
  delete dut;
  if (bad) {
    std::fprintf(stderr, "axi_burst128: FAILED, %d mismatches\n", bad);
    return 1;
  }
  std::printf("axi_burst128: ok\n");
  return 0;
}
