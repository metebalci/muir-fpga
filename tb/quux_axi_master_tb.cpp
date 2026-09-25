// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// rtl/plumbing/quux_axi_master.sv against AXI3's rules and against memory.
//
// There is no muir reference: nothing muir models is an AXI port.  So the
// master is held to (a) the protocol, checked every tick --- a valid held
// until its ready, one handshake of each channel a transaction, a line read
// of ARLEN 1 at a 16-byte boundary and a word's of ARLEN 0, every transfer
// the port's full 64 bits, and a write's strobes on the one half its address
// names --- and (b) the property: every read returns what the writes before
// it left at that address, a line its four words in order, and every
// request is answered exactly once.
//
// The slave here is a memory of 64-bit beats that varies every handshake:
// ready before valid, valid before ready, both in one tick, and delays on
// each channel apart, including a gap between a line's two beats.  One
// transaction in eight is refused, SLVERR and DECERR in turn, and
// `mem_error` must say so; a refused write lands nowhere.  And now and then
// the requester lets go of a request before its answer --- the machine's
// reset mid-flight --- and the master must finish that transaction on the
// port and throw its answer away, which the next request's word, different
// by construction, would show if it did not.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>

#include "Vquux_axi_master.h"
#include "verilated.h"

namespace {

struct Rng {
  uint64_t s;
  uint32_t Next() {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    return static_cast<uint32_t>(s >> 33);
  }
  uint32_t Below(uint32_t n) { return Next() % n; }
};

constexpr uint32_t kBase = 0x18000000u;
constexpr uint32_t kWords = 4096;   // a small window, so words are re-read often

uint32_t Initial(uint32_t a) { return a * 0x9E3779B1u ^ 0x13579BDFu; }

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *m = new Vquux_axi_master;
  Rng rng{0x6c696e65ull};
  std::map<uint32_t, uint64_t> beats;   // by beat address
  auto beat_of = [&](uint32_t a) -> uint64_t {
    const auto it = beats.find(a);
    if (it != beats.end()) return it->second;
    return static_cast<uint64_t>(Initial(a + 4)) << 32 | Initial(a);
  };
  auto word_of = [&](uint32_t byte) {
    const uint64_t b = beat_of(byte & ~7u);
    return (byte & 4) ? static_cast<uint32_t>(b >> 32) : static_cast<uint32_t>(b);
  };

  int bad = 0;
  auto fail = [&](long t, const char *what) {
    if (bad < 20) std::fprintf(stderr, "tick %ld: %s\n", t, what);
    ++bad;
  };

  m->clk = 0;
  m->rst = 1;
  m->mem_req = 0;
  m->m_awready = m->m_wready = m->m_bvalid = m->m_arready = m->m_rvalid = 0;
  for (int i = 0; i < 4; ++i) {
    m->clk = 1;
    m->eval();
    m->clk = 0;
    m->eval();
  }
  m->rst = 0;

  // The requester.
  bool asking = false, write = false, line = false, abandon = false;
  uint32_t addr = 0, word = 0;
  int hold_after = 0;
  long answered = 0, reads = 0, lines = 0, writes = 0, errors = 0, abandoned = 0, idle_gap = 0;
  // The slave: the transaction it has in hand.
  bool aw_have = false, w_have = false, ar_have = false, b_due = false;
  uint32_t aw_addr = 0, ar_addr = 0;
  uint64_t w_data = 0;
  int w_strb = 0, ar_len = 0, r_beat = 0, delay = 0;
  int refuse = 0;
  long refused_cycle = -1;
  int aw_hs = 0, w_hs = 0, ar_hs = 0;
  // An abandoned transaction still on the port, whose strobes are its own
  // request's and not the one now asking.
  bool stale = false;

  for (long t = 0; t < 600000; ++t) {
    // --- the requester, before the edge: a request, held until answered;
    // held a tick or two more, as the bridge holds it, so a master that
    // re-issued on a standing request would; then a gap.
    if (!asking && hold_after == 0) {
      if (idle_gap > 0) {
        --idle_gap;
      } else {
        asking = true;
        const uint32_t k = rng.Below(10);
        write = k < 4;
        line = !write && k < 7;
        addr = kBase + 4 * rng.Below(kWords);
        word = rng.Next();
        abandon = rng.Below(20) == 0;
        refuse = rng.Below(8) == 0 ? 1 + (errors % 2) : 0;
        aw_hs = w_hs = ar_hs = 0;
      }
    }
    m->mem_req = asking || hold_after > 0;
    m->mem_write = write;
    m->mem_line = line;
    m->mem_addr = addr;
    m->mem_wdata = word;

    // --- the slave's outputs for this tick
    m->m_awready = !aw_have && rng.Below(3) != 0;
    m->m_wready = !w_have && rng.Below(3) != 0;
    m->m_arready = !ar_have && rng.Below(3) != 0;
    m->m_bvalid = 0;
    m->m_rvalid = 0;
    if (b_due && delay == 0) {
      m->m_bvalid = 1;
      m->m_bresp = refuse ? (refuse == 1 ? 2 : 3) : 0;
    }
    if (ar_have && delay == 0) {
      m->m_rvalid = rng.Below(4) != 0;
      m->m_rdata = beat_of(ar_addr + 8 * r_beat);
      m->m_rresp = refuse ? (refuse == 1 ? 2 : 3) : 0;
      m->m_rlast = r_beat == ar_len;
    }
    m->eval();

    // --- the protocol, before the edge
    if (m->m_arvalid && !stale) {
      if (line && m->m_arlen != 1) fail(t, "a line read not two beats");
      if (!line && m->m_arlen != 0) fail(t, "a word read not one beat");
      if (line && (m->m_araddr & 15)) fail(t, "a line read not at a 16-byte boundary");
      if (m->m_arsize != 3 || m->m_arburst != 1) fail(t, "a read not full-width INCR");
    }
    if (m->m_awvalid && (m->m_awlen != 0 || m->m_awsize != 3 || (m->m_awaddr & 7)))
      fail(t, "a write not one full-width beat");
    if (m->m_wvalid && !stale && m->m_wstrb != ((addr & 4) ? 0xF0 : 0x0F))
      fail(t, "a write's strobes not on its half");

    // Handshakes the slave takes at this edge.
    const bool aw_take = m->m_awvalid && m->m_awready;
    const bool w_take = m->m_wvalid && m->m_wready;
    const bool ar_take = m->m_arvalid && m->m_arready;
    const bool b_take = m->m_bvalid && m->m_bready;
    const bool r_take = m->m_rvalid && m->m_rready;
    if (aw_take) { aw_have = true; aw_addr = m->m_awaddr; if (!stale && ++aw_hs > 1) fail(t, "two AW handshakes"); }
    if (w_take) {
      w_have = true; w_data = m->m_wdata; w_strb = m->m_wstrb;
      if (!stale && ++w_hs > 1) fail(t, "two W handshakes");
    }
    if (ar_take) {
      ar_have = true; ar_addr = m->m_araddr; ar_len = m->m_arlen; r_beat = 0;
      delay = static_cast<int>(rng.Below(6));
      if (!stale && ++ar_hs > 1) fail(t, "two AR handshakes");
    }
    if (aw_have && w_have && !b_due) {
      b_due = true;
      delay = static_cast<int>(rng.Below(6));
      if (!refuse) {
        uint64_t b = beat_of(aw_addr);
        for (int k = 0; k < 8; ++k)
          if (w_strb >> k & 1) b = (b & ~(0xFFull << 8 * k)) | (w_data & (0xFFull << 8 * k));
        beats[aw_addr] = b;
      }
    }
    if (b_take) { b_due = aw_have = w_have = false; stale = false; }
    if (r_take) {
      if (r_beat == ar_len) { ar_have = false; stale = false; }
      else { ++r_beat; delay = static_cast<int>(rng.Below(3)); }
    }
    if (delay > 0) --delay;

    // The answer, as the requester sees it before the edge.
    if (asking && m->mem_done) {
      ++answered;
      if (m->mem_error != (refuse != 0)) fail(t, "mem_error is not what the port answered");
      if (write) {
        ++writes;
      } else if (line) {
        ++lines;
        if (!refuse)
          for (int k = 0; k < 4; ++k)
            if (m->mem_rline[k] != word_of((addr & ~15u) + 4 * k)) fail(t, "a line's word is wrong");
      } else {
        ++reads;
        if (!refuse && m->mem_rdata != word_of(addr)) {
          if (bad < 3) std::fprintf(stderr, "addr %08x got %08x want %08x\n", addr, m->mem_rdata, word_of(addr));
          fail(t, "a word read is wrong");
        }
      }
      if (refuse) ++errors;
      asking = false;
      hold_after = 1 + static_cast<int>(rng.Below(2));
    } else if (hold_after > 0) {
      // The request falls for at least a tick before the next, as the
      // bridge's does: a request that never fell would be the same one.
      if (--hold_after == 0) idle_gap = 1 + static_cast<int>(rng.Below(3));
    }
    // The requester lets go early now and then, the machine's reset.
    if (asking && abandon && rng.Below(6) == 0) {
      asking = false;
      stale = true;
      ++abandoned;
      hold_after = 0;
      idle_gap = 1 + static_cast<int>(rng.Below(3));
    }

    m->clk = 1;
    m->eval();
    m->clk = 0;
    m->eval();
  }
  (void)refused_cycle;

  std::printf("quux_axi_master: %ld answers: %ld word reads, %ld line reads, %ld writes, %ld of them "
              "refused; %ld requests let go before their answer\n",
              answered, reads, lines, writes, errors, abandoned);
  if (!bad && (reads < 1000 || lines < 1000 || writes < 1000 || errors < 100 || abandoned < 100)) {
    std::fprintf(stderr, "FAIL: the run reached too little\n");
    ++bad;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d\n", bad);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
