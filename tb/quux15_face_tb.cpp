// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds revision 15's console face (`rtl/plumbing/quux15_face.sv`) to the
// words its header gives, driven over AXI as Linux's programs drive it, one
// beat a transaction, with the core behind it modeled here: its readout a word
// three clocks after its address, each word a function of the address alone;
// the diagnostic registers a function of the register; the counters and VMA,
// Q and MD moving every clock, so that a latch taken at the wrong read shows.
//
//   - IDENT, and UNMAPPED at a word the face does not name;
//   - the machine out of reset from power-on, as revisions 13 and 14 come up
//     on the boards; a write of RESET's key with all four strobes resets it
//     for RESET_T clocks; another value, or the key with a strobe off, does
//     nothing; the count of resets;
//   - CYCLES then CYCLESH, TICKS then TICKSH, and VMA then Q and MD, the high
//     words and the two beside VMA of the instant the low word was read;
//   - the readout: the echo names the old address until the word is there,
//     then the asked one, and words 11 and 12 the word of that address;
//     selector 15 pulses the snapshot, once;
//   - a diagnostic register read and written at word 16 + k;
//   - BUILD, BOARDS, RANGE, VIDEO and PERIOD as the bitstream's parameters
//     give them, and RTC's start written and read back and given to the
//     machine.
//
// It prints `ok:` and exits 0, or names each failure and exits 1.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>

#include "Vquux15_face.h"
#include "verilated.h"

namespace {

Vquux15_face *d;
long ticks = 0;
int bad = 0;
long checks = 0;

// The face's parameters, as the testbench builds it (the Makefile's -G).
constexpr uint32_t kIdent = 0x434F4E53u;
constexpr uint32_t kUnmapped = ~kIdent;
constexpr uint32_t kResetKey = 0x52534554u;
constexpr int kResetT = 64;
constexpr uint32_t kBuild = 0x0E4E7450u;

void Want(const std::string &what, uint64_t got, uint64_t want) {
  ++checks;
  if (got != want) {
    ++bad;
    std::fprintf(stderr, "FAIL: %s: %#" PRIx64 ", want %#" PRIx64 " (tick %ld)\n", what.c_str(), got,
                 want, ticks);
  }
}

// The core behind the face.
uint64_t committed = 0x123456789ull, clocks = 0x0000ABCD00000000ull;
uint64_t vma = 0x1100000000ull, q = 0x2200000000ull, md = 0x3300000000ull;
std::deque<std::pair<unsigned, unsigned>> rm_pipe;  // the address, three clocks
long snaps = 0, spy_writes = 0;
unsigned last_eadr = 0, last_spy_word = 0;

uint64_t ro_model(unsigned sel, unsigned addr) {
  return 0xA5A5000000000000ull ^ (uint64_t(sel) << 40) ^ (uint64_t(addr) * 0x9E3779B97F4A7C15ull >> 8);
}
uint16_t spy_model(unsigned k) { return static_cast<uint16_t>(0x1000u + 0x111u * k); }

// One clock: the core's inputs set, the edge, the core's state moved.
void Step() {
  d->committed = committed;
  d->clocks = clocks;
  d->vma = vma;
  d->q = q;
  d->md = md;
  d->spy_rdata = spy_model(d->spy_raddr);
  const std::pair<unsigned, unsigned> head = rm_pipe.size() >= 3 ? rm_pipe[rm_pipe.size() - 3]
                                                                 : std::make_pair(0u, 0u);
  d->rm_word = ro_model(head.first, head.second);
  d->clk = 0;
  d->eval();
  d->clk = 1;
  d->eval();
  ++ticks;
  // What the face gave the core this edge.
  rm_pipe.emplace_back(d->rm_sel, d->rm_addr);
  if (rm_pipe.size() > 8) rm_pipe.pop_front();
  if (d->rm_snap) ++snaps;
  if (d->spy_we) {
    ++spy_writes;
    last_eadr = d->spy_eadr;
    last_spy_word = d->spy_wdata;
  }
  committed += 3;
  clocks += 1;
  vma += 1;
  q += 2;
  md += 5;
}

int Write(unsigned word, uint32_t data, unsigned strb = 0xF) {
  d->s_awaddr = (word * 4u) & 0xFFFu;
  d->s_awlen = 0;
  d->s_awid = 5;
  d->s_awvalid = 1;
  d->s_wdata = data;
  d->s_wstrb = strb;
  d->s_wlast = 1;
  d->s_wvalid = 1;
  d->s_bready = 1;
  bool aw = false, w = false;
  for (int k = 0; k < 64; ++k) {
    d->eval();
    const bool aw_now = d->s_awvalid && d->s_awready;
    const bool w_now = d->s_wvalid && d->s_wready;
    const bool b_now = d->s_bvalid && d->s_bready;
    const int resp = d->s_bresp;
    Step();
    if (aw_now) {
      aw = true;
      d->s_awvalid = 0;
    }
    if (w_now) {
      w = true;
      d->s_wvalid = 0;
    }
    if (b_now && aw && w) {
      d->s_bready = 0;
      return resp;
    }
  }
  Want("a write answered at word " + std::to_string(word), 0, 1);
  return -1;
}

uint32_t Read(unsigned word) {
  d->s_araddr = (word * 4u) & 0xFFFu;
  d->s_arlen = 0;
  d->s_arid = 3;
  d->s_arvalid = 1;
  d->s_rready = 1;
  for (int k = 0; k < 64; ++k) {
    d->eval();
    const bool ar_now = d->s_arvalid && d->s_arready;
    const bool r_now = d->s_rvalid && d->s_rready;
    const uint32_t data = d->s_rdata;
    const int resp = d->s_rresp;
    Step();
    if (ar_now) d->s_arvalid = 0;
    if (r_now) {
      d->s_rready = 0;
      Want("RRESP at word " + std::to_string(word), resp, 0);
      return data;
    }
  }
  Want("a read answered at word " + std::to_string(word), 0, 1);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vquux15_face;
  d->build = kBuild;
  d->rst = 1;
  for (int k = 0; k < 4; ++k) Step();
  d->rst = 0;
  Step();

  // ---- what it is, and what it is not
  Want("IDENT", Read(0), kIdent);
  for (unsigned w : {13u, 14u, 15u, 33u, 36u, 42u, 63u, 100u, 1023u})
    Want("word " + std::to_string(w) + ", which the face does not name", Read(w), kUnmapped);

  // ---- the reset: none from power-on, a pulse at the key alone
  Want("the machine running from power-on", d->mach_rst, 0);
  Want("STAT answered, no switch", Read(1), 0x04u);
  Write(6, kResetKey ^ 1u);
  for (int k = 0; k < 4; ++k) Step();
  Want("a value not the key resets nothing", d->mach_rst, 0);
  Write(6, kResetKey, 0x7u);
  for (int k = 0; k < 4; ++k) Step();
  Want("the key with a strobe off resets nothing", d->mach_rst, 0);
  Want("RESET reads the key's half and no reset", Read(6), (kResetKey & 0xFFFF0000u));
  Write(6, kResetKey);
  // The pulse runs RESET_T clocks from the key's edge, which is a clock or
  // two before the write's response.
  Want("the reset after the key", d->mach_rst, 1);
  int left = 0;
  while (d->mach_rst && left < 4 * kResetT) {
    Step();
    ++left;
  }
  ++checks;
  if (left > kResetT || left < kResetT - 8) {
    ++bad;
    std::fprintf(stderr, "FAIL: the reset ran %d clocks past the write's response, of %d\n", left, kResetT);
  }
  Want("STAT after the reset", Read(1), 0x04u);
  Want("RESET's count", Read(6), (kResetKey & 0xFFFF0000u) | (1u << 8));

  // ---- the counters: the high word of the low word's instant
  {
    const uint64_t c0 = committed;
    const uint32_t lo = Read(2);
    for (int k = 0; k < 7; ++k) Step();
    const uint32_t hi = Read(3);
    const uint64_t got = (uint64_t(hi) << 32) | lo;
    ++checks;
    if (got < c0 || got > c0 + 3 * 8) {
      ++bad;
      std::fprintf(stderr, "FAIL: CYCLES %#" PRIx64 " not of its read's instant, %#" PRIx64 "\n", got, c0);
    }
    committed = 0x00000001FFFFFFF0ull;  // a carry between the two reads
    const uint32_t lo2 = Read(2);
    for (int k = 0; k < 20; ++k) Step();
    const uint32_t hi2 = Read(3);
    Want("CYCLESH across a carry, the low word's", hi2, lo2 >= 0xFFFFFFF0u ? 1u : 2u);
    const uint64_t t0 = clocks;
    const uint32_t tlo = Read(4);
    const uint32_t thi = Read(5);
    Want("TICKSH", thi, uint32_t(t0 >> 32));
    ++checks;
    if (tlo < uint32_t(t0)) {
      ++bad;
      std::fprintf(stderr, "FAIL: TICKS %#x before its read\n", tlo);
    }
  }

  // ---- VMA, then Q and MD of the same instant
  {
    const uint32_t v = Read(7);
    for (int k = 0; k < 5; ++k) Step();
    const uint32_t qq = Read(8), mm = Read(9);
    // The three move together: VMA by 1, Q by 2 and MD by 5 a clock, so the
    // instant VMA was read at names Q and MD.
    const uint64_t at = uint64_t(v) - uint32_t(0x1100000000ull);
    Want("Q beside VMA", qq, uint32_t(0x2200000000ull + 2 * at));
    Want("MD beside VMA", mm, uint32_t(0x3300000000ull + 5 * at));
  }

  // ---- the readout: the echo moves when the word is there
  {
    const unsigned sel = 4, addr = 0x2CEC;
    const uint32_t asked = (sel << 14) | addr;
    Write(10, asked);
    // Read at once: the face takes the address and its word some clocks on.
    unsigned tries = 0;
    uint32_t echo = Read(10);
    while (echo != asked && tries < 32) {
      Want("an echo before the word: the old address", echo, 0x3FFFFu);
      echo = Read(10);
      ++tries;
    }
    Want("the echo", echo, asked);
    const uint64_t word = uint64_t(Read(11)) | (uint64_t(Read(12)) << 32);
    Want("the readout's word, both halves", word, ro_model(sel, addr));
    // Another address, the echo moving to it.
    const uint32_t asked2 = (13u << 14) | 0x3FFu;
    Write(10, asked2);
    for (int k = 0; k < 16; ++k) Step();
    Want("the second echo", Read(10), asked2);
    Want("its low half", Read(11), uint32_t(ro_model(13, 0x3FF)));
    Want("its high half", Read(12), uint32_t(ro_model(13, 0x3FF) >> 32));
    // A read of 11 alone gives the last echo's word.
    for (int k = 0; k < 9; ++k) Step();
    Want("word 11 read alone, the latch's", Read(11), uint32_t(ro_model(13, 0x3FF)));
    // The snapshot: selector 15, one pulse.
    snaps = 0;
    Write(10, 15u << 14);
    for (int k = 0; k < 16; ++k) Step();
    Want("selector 15's snapshot, one pulse", snaps, 1);
    Write(10, (2u << 14) | 7u);
    for (int k = 0; k < 16; ++k) Step();
    Want("another selector takes no snapshot", snaps, 1);
  }

  // ---- the diagnostic registers
  for (unsigned k = 0; k < 16; ++k)
    Want("diagnostic register " + std::to_string(k), Read(16 + k), spy_model(k));
  spy_writes = 0;
  Write(16 + 5, 0xABCD1234u);
  Want("a register written once", spy_writes, 1);
  Want("its EADR", last_eadr, 5);
  Want("its word", last_spy_word, 0x1234);
  Write(16 + 3, 0x0000FFFFu);
  Want("register 3 written", last_eadr, 3);

  // ---- what the bitstream is
  Want("BUILD", Read(32), kBuild);
  Want("BOARDS", Read(37), (0x4244u << 16) | 32u);
  Want("RANGE", Read(38), (0x1A5u << 22) | (32u << 11) | 32u);
  Want("VIDEO", Read(39), (0x356u << 22) | (1280u << 11) | 1024u);
  Want("PERIOD", Read(40), 34u);
  Write(37, (0x4D42u << 16) | 64u);
  Want("BOARDS refuses a write", Read(37), (0x4244u << 16) | 32u);
  Write(41, 0x6AB30C91u);
  Want("RTC's start read back", Read(41), 0x6AB30C91u);
  Want("RTC's start given to the machine", d->rtc_start, 0x6AB30C91u);
  Write(41, 0x00000000u, 0x1u);
  Want("RTC's start, one byte written", Read(41), 0x6AB30C00u);

  d->final();
  delete d;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d of %ld checks of quux15_face\n", bad, checks);
    return 1;
  }
  std::printf("ok: quux15_face, %ld checks: its words, the reset, the latches, the readout's echo, "
              "the diagnostic registers and the bitstream's words\n", checks);
  return 0;
}
