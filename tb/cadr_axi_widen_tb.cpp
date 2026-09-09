// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The widening, against a 64-bit memory that is not the DUT's.
//
// There is no muir reference for any of this --- nothing in MIT's drawings is
// an AXI master, still less a 64-bit AFI port --- so what the module is held
// to is the property: a 32-bit word written at an address lands in the half of
// the beat that address selects and in no other, and a read of that address
// gives it back.
//
// THE MEMORY IS KEYED BY THE STIMULUS AND NEVER BY THE DUT, which is the
// lesson CLAUDE.md paid for twice. A model memory indexed by the address the
// DUT presented moves with the bug: a converter that dropped an address bit
// would write consistent nonsense at the wrong beat and read it back from the
// same wrong beat, and every comparison would agree. So the beat here is
// chosen by the stimulus --- an index into a table of addresses this file
// wrote --- and the DUT's `m_awaddr` and `m_araddr` are compared against what
// that address should have produced. **That equality is the only thing in this
// testbench that can catch an address bug at all**, and it is written down
// here rather than left to the read-back for exactly that reason.
//
// What the DUT *does* supply is the payload: `m_wdata` and `m_wstrb` are
// applied byte by byte into the model beat, and `m_rdata` comes back out of
// it. So the placing of the word is the DUT's and the address is not.
//
// THE MEMORY IS POISONED AND NOT ZEROED. Every word comes up holding a value
// unique to its own index, so that (a) a read of a word nothing has written is
// distinguishable from a read of a word written zero, and (b) the two halves
// of a beat are never equal --- which is what makes a wrong lane select
// visible. A memory of zeros would hide both: the first read of any lane would
// return zero whichever half it took. The stimulus keeps the invariant across
// writes too, perturbing a word that would otherwise come to equal its
// neighbour, and every read asserts that the beat it is reading has two
// different halves. A stimulus that mirrors what the DUT expects cannot catch
// a direction bug; this one always offers a wrong answer beside the right one.
//
// THE TWO CHANNELS ARE DRIVEN INDEPENDENTLY, and that is not decoration. In
// `cadr_arty.sv` the write strobes are placed by the adapter's registered
// `awaddr` and the read lane is selected by its `araddr`, and the adapter
// holds each until the next transaction of that kind replaces it --- so on a
// write, `araddr` is the previous read's address. A lane selected from the
// wrong one of the two is invisible unless the two disagree, so this drives
// both on every evaluation, updates only the one the operation uses, and
// counts how often their bit 2 differs.
//
// READS AND WRITES MUST BE ABLE TO MEET. The addresses come from a small
// table, so a read lands on a word an earlier write touched constantly; the
// counters at the end require that to have happened in both halves, and
// require reads of never-written words in both halves too. A run where they
// never met would pass every comparison while testing nothing.
//
// WHAT THIS DOES NOT CHECK. Nothing here is a handshake: the module is
// combinational payload conversion and every valid, ready and last passes the
// top level straight through. Nor does it check that a single beat is the
// right shape for the port --- that is `cadr_axi_master`'s single-transaction
// property and its own testbench's. And it drives partial byte strobes, which
// the adapter never does: the module's stated function is to place whatever
// strobes it is given, and holding it to that is a superset of what the board
// asks of it.

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vcadr_axi_widen.h"
#include "verilated.h"

namespace {

// A small deterministic generator, so a failure is reproducible.
unsigned lcg(unsigned &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

int bad = 0;
long op = 0;

int Fail(const char *what, uint64_t got, uint64_t want) {
  std::fprintf(stderr, "op %ld: %s is 0x%016llx, expected 0x%016llx\n", op,
               what, static_cast<unsigned long long>(got),
               static_cast<unsigned long long>(want));
  return 1;
}

// Sixty-four beats, a hundred and twenty-eight words: small enough that reads
// land on written words constantly, and the addresses themselves are spread
// across the whole 32-bit space so that every bit of the beat address is
// exercised in both states.
const int BEATS = 64;
const int WORDS = 2 * BEATS;

// The first eight beats are never written to, only read. Without them the
// hundred and twenty-eight words are all written inside the first few hundred
// operations and the poison is only ever read at the very start of the run ---
// so "a read of a word nothing has written" would be a property held for a
// moment and then never again. Reserving a few keeps it live to the last
// operation, in both halves.
const int READ_ONLY_BEATS = 8;

// Unique per word index, and never zero: see the header. Multiplying by an odd
// constant is a bijection on 32 bits, so no two words share a value and no
// beat comes up with two equal halves.
uint32_t poison(int idx) {
  return 0xF0000000u ^ static_cast<uint32_t>(idx * 2654435761u);
}

uint64_t apply64(uint64_t old, uint64_t data, unsigned strb) {
  for (int i = 0; i < 8; ++i)
    if (strb & (1u << i)) {
      const uint64_t mask = 0xFFull << (8 * i);
      old = (old & ~mask) | (data & mask);
    }
  return old;
}

uint32_t apply32(uint32_t old, uint32_t data, unsigned strb) {
  for (int i = 0; i < 4; ++i)
    if (strb & (1u << i)) {
      const uint32_t mask = 0xFFu << (8 * i);
      old = (old & ~mask) | (data & mask);
    }
  return old;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_axi_widen;

  unsigned seed = 20260909u;

  // The beat addresses. Half of them in the region `cadr_ddr_map` reserves,
  // which is where every address the machine makes actually falls, and half
  // scattered over the whole 32-bit space so that bits the real map holds
  // constant are exercised anyway. Eight-aligned, as every address the bridge
  // produces is: a word address shifted twice into a 256 MB aligned base.
  uint32_t beat_addr[BEATS];
  for (int b = 0; b < BEATS; ++b) {
    if (b < BEATS / 2)
      beat_addr[b] = 0x1800'0000u + static_cast<uint32_t>(b) * 8u;
    else
      // Two draws, because the generator returns twenty-four bits: one alone
      // leaves the top byte of every address zero, and the bit-toggle check
      // at the end of the run said so.
      beat_addr[b] = ((lcg(seed) << 16) ^ lcg(seed)) & 0xFFFF'FFF8u;
  }
  // Two beats sharing an address would let a write to one be read out of the
  // other and would make the model wrong rather than the DUT.
  for (int i = 0; i < BEATS; ++i)
    for (int j = i + 1; j < BEATS; ++j)
      if (beat_addr[i] == beat_addr[j]) {
        std::fprintf(stderr, "FAIL: beats %d and %d share an address\n", i, j);
        return 1;
      }

  uint64_t mem[BEATS];
  uint32_t shadow[WORDS];
  bool written[WORDS];
  for (int w = 0; w < WORDS; ++w) {
    shadow[w] = poison(w);
    written[w] = false;
  }
  for (int b = 0; b < BEATS; ++b)
    mem[b] = (static_cast<uint64_t>(shadow[2 * b + 1]) << 32) | shadow[2 * b];

  // The two channels, each holding what its last transaction put there.
  // Deliberately started on different halves.
  int aw_beat = 0, aw_half = 0, ar_beat = 1, ar_half = 1;
  uint32_t aw_addr = beat_addr[0] + 0;
  uint32_t ar_addr = beat_addr[1] + 4;
  uint32_t wdata = 0x0123'4567u;
  unsigned wstrb = 0xF, awlen = 0, arlen = 0, awsize = 2, arsize = 2;

  // Which bits of an address this run has seen in each state, so that the
  // equality against the aligned address is not being asserted over a constant.
  uint32_t addr_bits_high = 0, addr_bits_low = 0;

  long writes = 0, reads = 0;
  long w_half[2] = {0, 0}, r_half[2] = {0, 0};
  long r_after_write[2] = {0, 0}, r_untouched[2] = {0, 0};
  long r_both_halves_written = 0, w_other_half_written = 0;
  long full_strobe = 0, partial_strobe = 0;
  long channels_disagree_on_read = 0, channels_disagree_on_write = 0;
  long blind_reads = 0;

  const long OPS = 200000;
  for (op = 0; op < OPS && bad < 20; ++op) {
    const bool is_write = (lcg(seed) & 1) != 0;

    if (is_write) {
      aw_beat = READ_ONLY_BEATS +
                static_cast<int>(lcg(seed) % (BEATS - READ_ONLY_BEATS));
      aw_half = static_cast<int>(lcg(seed) & 1);
      aw_addr = beat_addr[aw_beat] + 4u * static_cast<uint32_t>(aw_half);
      wdata = lcg(seed) ^ (lcg(seed) << 16);
      // Mostly the whole word, which is all the adapter ever asks for, and
      // sometimes a subset --- never none, which would be a write of nothing.
      if (lcg(seed) % 5 == 0) {
        wstrb = 1u + lcg(seed) % 15u;
        ++partial_strobe;
      } else {
        wstrb = 0xF;
        ++full_strobe;
      }
      // Keep the beat's two halves different, so that every later read of it
      // can tell a right lane from a wrong one. Flipping a strobed byte is
      // enough: it changes the word that will land, which was the only value
      // equal to the neighbour.
      const int idx = 2 * aw_beat + aw_half, sib = 2 * aw_beat + (1 - aw_half);
      if (apply32(shadow[idx], wdata, wstrb) == shadow[sib]) {
        int byte = 0;
        while (!(wstrb & (1u << byte))) ++byte;
        wdata ^= 0xFFu << (8 * byte);
      }
      // AXI4's eight bits of length and three of size, driven over their whole
      // range: the port takes four bits of the one and none of the other, and
      // that has to be true of every value rather than of zero.
      awlen = lcg(seed) & 0xFFu;
      awsize = lcg(seed) & 0x7u;
    } else {
      ar_beat = static_cast<int>(lcg(seed) % BEATS);
      ar_half = static_cast<int>(lcg(seed) & 1);
      ar_addr = beat_addr[ar_beat] + 4u * static_cast<uint32_t>(ar_half);
      arlen = lcg(seed) & 0xFFu;
      arsize = lcg(seed) & 0x7u;
    }

    addr_bits_high |= aw_addr | ar_addr;
    addr_bits_low |= ~aw_addr | ~ar_addr;

    dut->s_awaddr = aw_addr;
    dut->s_awlen = awlen;
    dut->s_awsize = awsize;
    dut->s_wdata = wdata;
    dut->s_wstrb = wstrb;
    dut->s_araddr = ar_addr;
    dut->s_arlen = arlen;
    dut->s_arsize = arsize;
    // The beat the read address names, out of the stimulus's own memory.
    dut->m_rdata = mem[ar_beat];
    dut->eval();

    // --- the beat address. The only check here that can see an address bug,
    // and the reason the model memory is keyed by the stimulus instead.
    if (dut->m_awaddr != (aw_addr & 0xFFFF'FFF8u))
      bad += Fail("m_awaddr", dut->m_awaddr, aw_addr & 0xFFFF'FFF8u);
    if (dut->m_araddr != (ar_addr & 0xFFFF'FFF8u))
      bad += Fail("m_araddr", dut->m_araddr, ar_addr & 0xFFFF'FFF8u);

    // --- length and size. AXI3 carries four bits of length, and the beat's
    // size is the port's width whatever the adapter says the word's is.
    if (dut->m_awlen != (awlen & 0xFu))
      bad += Fail("m_awlen", dut->m_awlen, awlen & 0xFu);
    if (dut->m_arlen != (arlen & 0xFu))
      bad += Fail("m_arlen", dut->m_arlen, arlen & 0xFu);
    if (dut->m_awsize != 3) bad += Fail("m_awsize", dut->m_awsize, 3);
    if (dut->m_arsize != 3) bad += Fail("m_arsize", dut->m_arsize, 3);

    // --- the strobes, in the half the write address selects and nowhere
    // else. The memory below would catch a strobe in the wrong half as data;
    // this catches it as a strobe, and says which of the two it was.
    const unsigned want_strb = aw_half ? (wstrb << 4) : wstrb;
    if (dut->m_wstrb != want_strb)
      bad += Fail("m_wstrb", dut->m_wstrb, want_strb);

    // --- the read. Checked on every evaluation and not only on read
    // operations: the read path is combinational and the read address stands
    // between reads, so a write is also a moment at which the lane select can
    // be wrong.
    if (static_cast<uint32_t>(mem[ar_beat] >> 32) ==
        static_cast<uint32_t>(mem[ar_beat]))
      ++blind_reads;
    if (dut->s_rdata != shadow[2 * ar_beat + ar_half])
      bad += Fail("s_rdata", dut->s_rdata, shadow[2 * ar_beat + ar_half]);

    if (((aw_addr ^ ar_addr) & 4u) != 0) {
      if (is_write) ++channels_disagree_on_write;
      else ++channels_disagree_on_read;
    }

    if (is_write) {
      const int idx = 2 * aw_beat + aw_half, sib = 2 * aw_beat + (1 - aw_half);
      if (written[sib]) ++w_other_half_written;
      // The DUT's own word and strobes into a beat the stimulus chose.
      mem[aw_beat] = apply64(mem[aw_beat], dut->m_wdata, dut->m_wstrb);
      // And the stimulus's own word and strobes into the shadow.
      shadow[idx] = apply32(shadow[idx], wdata, wstrb);
      written[idx] = true;
      // The whole beat, both halves: what was written landed where the
      // address says and the other half did not move. A write that reached
      // both halves fails here on the half it had no business in.
      const uint64_t want = (static_cast<uint64_t>(shadow[2 * aw_beat + 1])
                             << 32) | shadow[2 * aw_beat];
      if (mem[aw_beat] != want)
        bad += Fail("the beat after the write", mem[aw_beat], want);
      ++writes;
      ++w_half[aw_half];
    } else {
      ++reads;
      ++r_half[ar_half];
      if (written[2 * ar_beat + ar_half]) ++r_after_write[ar_half];
      else ++r_untouched[ar_half];
      if (written[2 * ar_beat] && written[2 * ar_beat + 1])
        ++r_both_halves_written;
    }
  }

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems over %ld operations\n", bad, op);
    return 1;
  }

  // Every bit of an address above the beat boundary must have been driven
  // both ways, or the equality above is being asserted over a constant and a
  // dropped bit somewhere in 31:3 would never show.
  const uint32_t moved = addr_bits_high & addr_bits_low & 0xFFFF'FFF8u;
  if (moved != 0xFFFF'FFF8u) {
    std::fprintf(stderr,
                 "FAIL: address bits 0x%08x never took both values, so the "
                 "beat address is being checked over a constant\n",
                 0xFFFF'FFF8u & ~moved);
    return 1;
  }
  if (blind_reads) {
    std::fprintf(stderr,
                 "FAIL: %ld reads of a beat whose halves were equal --- a "
                 "wrong lane select would not have shown\n",
                 blind_reads);
    return 1;
  }

  int thin = 0;
  const struct {
    const char *what;
    long n;
  } want[] = {
      {"writes", writes},
      {"reads", reads},
      {"writes into the low half", w_half[0]},
      {"writes into the high half", w_half[1]},
      {"reads of the low half", r_half[0]},
      {"reads of the high half", r_half[1]},
      {"reads of a low half an earlier write touched", r_after_write[0]},
      {"reads of a high half an earlier write touched", r_after_write[1]},
      {"reads of a low half nothing has written", r_untouched[0]},
      {"reads of a high half nothing has written", r_untouched[1]},
      {"reads of a beat with both halves written", r_both_halves_written},
      {"writes beside a half an earlier write touched", w_other_half_written},
      {"writes of the whole word", full_strobe},
      {"writes of part of a word", partial_strobe},
      {"reads while the write channel selects the other half",
       channels_disagree_on_read},
      {"writes while the read channel selects the other half",
       channels_disagree_on_write}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the run has no %s\n", w.what);
      ++thin;
    }
  if (thin) return 1;

  std::printf(
      "ok: %ld conversions over %ld beats, address and length held at every "
      "one\n"
      "    %ld writes --- %ld low half, %ld high, %ld beside a written "
      "neighbour, %ld of part of a word\n"
      "    %ld reads --- %ld low half, %ld high, %ld of a word an earlier "
      "write put there, %ld of a poisoned one\n"
      "    %ld reads of a beat with two written halves; the channels selected "
      "different halves on %ld reads and %ld writes\n",
      writes + reads, static_cast<long>(BEATS), writes, w_half[0], w_half[1],
      w_other_half_written, partial_strobe, reads, r_half[0], r_half[1],
      r_after_write[0] + r_after_write[1], r_untouched[0] + r_untouched[1],
      r_both_halves_written, channels_disagree_on_read,
      channels_disagree_on_write);
  return 0;
}
