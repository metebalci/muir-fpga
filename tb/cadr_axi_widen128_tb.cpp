// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The 128-bit widening, against a 128-bit memory that is not the DUT's.
//
// `tb/cadr_axi_widen_tb.cpp`'s method at four lanes: a word written at an
// address lands in the lane of the beat that address selects and in no
// other, and a read of that address gives it back.
//
// THE MEMORY IS KEYED BY THE STIMULUS AND NEVER BY THE DUT: the beat is an
// index into a table of addresses this file wrote, and the DUT's `m_awaddr`
// and `m_araddr` are compared against what that address should produce,
// which is the only thing here that can catch an address bug.  What the DUT
// supplies is the payload: `m_wdata` and `m_wstrb` are applied byte by byte
// into the model beat, and `m_rdata` is read out of it.  A REFERENCE copy of
// the memory, updated from the stimulus alone, says what every beat must
// hold afterwards, so a strobe in a wrong lane shows as a neighbor changed.
//
// THE MEMORY IS POISONED: every word holds a value unique to its index, so
// no two lanes of a beat are ever equal and a wrong lane always has a wrong
// answer to give.
//
// THE TWO CHANNELS ARE DRIVEN APART: the write strobes come from `s_awaddr`
// and the read lane from `s_araddr`, and the two are kept different, with
// how often their lane bits differ counted, so a lane taken from the wrong
// channel cannot hide.

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vcadr_axi_widen128.h"
#include "verilated.h"

namespace {

unsigned lcg(unsigned &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

const int BEATS = 64;
const int READ_ONLY_BEATS = 8;

uint32_t poison(int idx) {
  return 0xF0000000u ^ static_cast<uint32_t>(idx * 2654435761u);
}

uint32_t apply32(uint32_t old, uint32_t data, unsigned strb) {
  for (int i = 0; i < 4; ++i)
    if (strb & (1u << i)) {
      const uint32_t mask = 0xFFu << (8 * i);
      old = (old & ~mask) | (data & mask);
    }
  return old;
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
  auto *dut = new Vcadr_axi_widen128;
  unsigned seed = 20261001u;

  uint32_t beat_addr[BEATS];
  for (int b = 0; b < BEATS; ++b) {
    if (b < BEATS / 2)
      beat_addr[b] = 0x6000'0000u + static_cast<uint32_t>(b) * 16u;
    else
      beat_addr[b] = ((lcg(seed) << 16) ^ lcg(seed)) & 0xFFFF'FFF0u;
  }
  for (int b = 0; b < BEATS; ++b)
    for (int c = 0; c < b; ++c)
      if (beat_addr[b] == beat_addr[c]) beat_addr[b] ^= 0x10u << (b % 20);

  uint32_t mem[BEATS][4], ref[BEATS][4];
  bool written[BEATS][4] = {};
  for (int b = 0; b < BEATS; ++b)
    for (int l = 0; l < 4; ++l) mem[b][l] = ref[b][l] = poison(4 * b + l);

  long reads_written[4] = {}, reads_poison[4] = {}, writes[4] = {};
  long lanes_apart = 0, partial = 0;
  uint32_t aw = beat_addr[0], ar = beat_addr[1] + 4;

  for (op = 0; op < 200000; ++op) {
    const bool is_write = lcg(seed) & 1;
    int b = static_cast<int>(lcg(seed) % BEATS);
    const int l = static_cast<int>(lcg(seed) % 4);
    if (is_write && b < READ_ONLY_BEATS) b += READ_ONLY_BEATS;
    const uint32_t addr = beat_addr[b] + 4u * static_cast<uint32_t>(l);
    if (is_write) aw = addr; else ar = addr;
    if (((aw >> 2) & 3) != ((ar >> 2) & 3)) ++lanes_apart;

    const uint32_t wdata = (lcg(seed) << 8) ^ lcg(seed);
    unsigned strb = lcg(seed) & 0xF;
    if (strb == 0) strb = 0xF;
    if (strb != 0xF) ++partial;
    const unsigned len = lcg(seed) & 0xFF;

    dut->s_awaddr = aw;
    dut->s_araddr = ar;
    dut->s_wdata = wdata;
    dut->s_wstrb = strb;
    dut->s_awlen = len;
    dut->s_arlen = len ^ 0x5A;
    dut->s_awsize = 2;
    dut->s_arsize = 2;
    // The model memory's beat at the READ address, presented as the port's
    // read data whichever operation this is.
    {
      int rb = -1;
      for (int k = 0; k < BEATS; ++k)
        if (beat_addr[k] == (ar & ~0xFu)) rb = k;
      for (int w = 0; w < 4; ++w) dut->m_rdata[w] = rb >= 0 ? mem[rb][w] : 0;
    }
    dut->eval();

    if (dut->m_awlen != len) fail("m_awlen", dut->m_awlen, len);
    if (dut->m_arlen != (len ^ 0x5A)) fail("m_arlen", dut->m_arlen, len ^ 0x5A);
    if (dut->m_awsize != 4) fail("m_awsize", dut->m_awsize, 4);
    if (dut->m_arsize != 4) fail("m_arsize", dut->m_arsize, 4);
    if (dut->m_awaddr != (aw & ~0xFu)) fail("m_awaddr", dut->m_awaddr, aw & ~0xFu);
    if (dut->m_araddr != (ar & ~0xFu)) fail("m_araddr", dut->m_araddr, ar & ~0xFu);

    if (is_write) {
      // The DUT's payload into the model beat, byte by byte.
      for (int w = 0; w < 4; ++w)
        mem[b][w] = apply32(mem[b][w], dut->m_wdata[w], (dut->m_wstrb >> (4 * w)) & 0xF);
      // The reference, from the stimulus alone.
      ref[b][l] = apply32(ref[b][l], wdata, strb);
      // Keep every lane of the beat distinct, so a wrong lane stays visible.
      for (int w = 0; w < 4; ++w)
        if (w != l && ref[b][w] == ref[b][l]) {
          ref[b][l] ^= 0x00010000u;
          mem[b][l] ^= 0x00010000u;
        }
      for (int w = 0; w < 4; ++w)
        if (mem[b][w] != ref[b][w]) fail("a beat word after the write", mem[b][w], ref[b][w]);
      written[b][l] = true;
      ++writes[l];
    } else {
      if (dut->s_rdata != ref[b][l]) fail("s_rdata", dut->s_rdata, ref[b][l]);
      if (written[b][l]) ++reads_written[l]; else ++reads_poison[l];
    }
  }

  for (int l = 0; l < 4; ++l) {
    std::printf("axi_widen128: lane %d: %ld writes, %ld reads of written words, %ld of poison\n",
                l, writes[l], reads_written[l], reads_poison[l]);
    if (!writes[l] || !reads_written[l] || !reads_poison[l]) {
      std::fprintf(stderr, "axi_widen128: lane %d was not exercised both ways\n", l);
      ++bad;
    }
  }
  std::printf("axi_widen128: the two channels' lanes differed on %ld of %ld operations; "
              "%ld partial strobes\n", lanes_apart, op, partial);
  if (lanes_apart < op / 2) {
    std::fprintf(stderr, "axi_widen128: the channels did not disagree often enough\n");
    ++bad;
  }
  delete dut;
  if (bad) {
    std::fprintf(stderr, "axi_widen128: FAILED, %d mismatches\n", bad);
    return 1;
  }
  std::printf("axi_widen128: ok\n");
  return 0;
}
