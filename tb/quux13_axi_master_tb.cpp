// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// rtl/plumbing/quux_axi_master.sv at revision 13 (WORD_BITS 40) against
// AXI3's rules and against memory: packed storage's five-beat lines and
// five-byte words (contract G1 §4.1), the window's four-beat lines and
// four-byte words, and the split at a 4 KiB boundary.
//
// There is no muir reference: nothing muir models is an AXI port.  So the
// master is held to (a) the protocol, checked every tick --- a valid held,
// with its payload, until its ready; every transfer the port's full 64 bits
// and INCR; a burst's last beat marked and no other; **NO BURST CROSSING A
// 4 KiB BOUNDARY**; a split line's second address up in the tick after its
// first is taken, not after its data --- and (b) the property: DDR is bytes,
// every line read returns the bytes from its address, and a write changes
// exactly the bytes it names, five from any byte or four at a four-byte
// address, and nothing else.
//
// The slave is a memory of bytes that varies every handshake and takes
// several reads' addresses before it answers the first, as both boards'
// ports do; it answers in order, one ID.  One transaction in eight is
// refused, SLVERR and DECERR in turn, and `mem_error` must say so; a refused
// write lands nowhere.  And now and then the requester lets go of a request
// before its answer, and the master must finish that transaction on the
// port and throw its answer away.
//
// The addresses gather at 4 KiB boundaries: lines whose 40 bytes run over
// one, at `40L mod 4096` 4064 to 4088, and words whose five bytes do.

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <unordered_map>
#include <vector>

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

// Packed storage's base on the boards is a multiple of 4 KiB (G1 §4.1).
constexpr uint32_t kBase = 0x12000000u;
constexpr uint32_t kSpan = 1u << 16;   // a small region, so bytes are re-read often

uint8_t Initial(uint32_t a) { return static_cast<uint8_t>((a * 0x9E3779B1u ^ 0x13579BDFu) >> 13); }

struct Burst {
  uint32_t addr;
  int beats;
  int resp;     // 0 OKAY, 2 SLVERR, 3 DECERR
  bool old;     // an abandoned transaction's
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *m = new Vquux_axi_master;
  Rng rng{0x13a31eadull};
  std::unordered_map<uint32_t, uint8_t> ddr;
  auto get = [&](uint32_t a) -> uint8_t {
    const auto it = ddr.find(a);
    return it != ddr.end() ? it->second : Initial(a);
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
  enum Kind { kLine5, kLine4, kWide, kWord, kRead };
  bool asking = false, abandon = false;
  Kind kind = kLine5;
  uint32_t addr = 0;
  uint64_t wdata = 0;
  int refuse = 0;
  int hold_after = 0;
  long idle_gap = 0;
  long answered = 0, lines5 = 0, lines4 = 0, wides = 0, spanning = 0, words = 0, reads = 0;
  long errors = 0, abandoned = 0, split_lines = 0, split_writes = 0, pipelined = 0;

  // The slave: addresses taken and not yet answered, in order.
  std::deque<Burst> ar_q, aw_q;
  int r_beat = 0;
  int r_delay = 0, b_delay = 0;
  // Write data taken, a burst at a time, and bursts whose data is all in.
  struct WBeat {
    uint64_t data;
    uint8_t strb;
    bool last;
  };
  struct WBurst {
    Burst b;
    std::vector<WBeat> data;
  };
  std::deque<WBeat> w_pending;   // beats taken, ahead of their address or not
  std::deque<WBurst> b_q;                               // bursts owed a response
  // An abandoned transaction still on the port: how many of its addresses
  // are still to be taken, and how it is answered.  The master finishes it
  // before it starts the next, so the next addresses taken are its.
  int stale_aw = 0, stale_ar = 0, stale_resp = 0;
  bool was_abandoned = false;
  // The request as the master saw it the tick before, for the rule that an
  // answer comes only to a request standing.
  bool req_was = false;
  // The request's own addresses taken, and how many it has.
  int aw_mine = 0, ar_mine = 0;
  auto bursts_of = [&](Kind k, uint32_t a) {
    if (k == kLine5 || k == kLine4) return (a & 0xFFFu) + 8u * (k == kLine5 ? 5 : 4) > 0x1000u ? 2 : 1;
    if (k == kWide) return ((a & 7u) > 3u && (a & 0xFF8u) == 0xFF8u) ? 2 : 1;
    return 1;
  };
  // The protocol's stability: a valid's payload the tick before.
  bool ar_was = false, aw_was = false, w_was = false;
  uint32_t ar_addr_was = 0, aw_addr_was = 0;
  int ar_len_was = 0, aw_len_was = 0;
  uint64_t w_data_was = 0;
  int w_strb_was = 0, w_last_was = 0;
  // A split line: the tick its first address was taken.
  long first_ar_taken = -1;
  // What a write changed, for the check that it changed only its bytes.
  std::unordered_map<uint32_t, uint8_t> before;
  // **THE SECOND HALF OF THE RUN KEEPS THE DE25-NANO'S RULE FOR WRITES**
  // (`rtl/plumbing/cadr_f2sdram_share.sv`): no write address is taken while
  // another write is owed its response, so a split write's second address
  // waits for the first burst's B.  A master that took no B until both of
  // its addresses were in never finishes such a write, and the run says so.
  const long kOneWriteFrom = 400000;
  long split_writes_one = 0, asked_at = -1;

  for (long t = 0; t < 800000; ++t) {
    // After a request let go, the next waits until the port is quiet: the
    // master finishes the one it let go first, and a request let go before
    // the master took it would leave nothing to count its addresses by.
    const bool quiet = stale_aw == 0 && stale_ar == 0 && aw_q.empty() && ar_q.empty() && b_q.empty() &&
                       w_pending.empty() && !m->m_awvalid && !m->m_wvalid && !m->m_arvalid;
    if (!asking && hold_after == 0 && (quiet || !was_abandoned)) {
      if (quiet) was_abandoned = false;
      if (idle_gap > 0) {
        --idle_gap;
      } else {
        asking = true;
        const uint32_t k = rng.Below(20);
        kind = k < 7 ? kLine5 : k < 9 ? kLine4 : k < 15 ? kWide : k < 18 ? kWord : kRead;
        switch (kind) {
          case kLine5: {
            // A line of packed storage, 40 bytes at 40L; now and then one
            // that runs over a 4 KiB boundary.
            uint32_t l = rng.Below(kSpan / 40);
            if (rng.Below(3) == 0) {
              const uint32_t page = rng.Below(kSpan / 4096);
              l = (page * 4096 + 4064 + 8 * rng.Below(4)) / 40;
              while ((40 * l) % 4096 < 4064) ++l;
            }
            addr = kBase + 40 * l;
            break;
          }
          case kLine4:
            addr = kBase + 32 * rng.Below(kSpan / 32);
            break;
          case kWide: {
            // A word of packed storage, five bytes at 5w; now and then one
            // across a 4 KiB boundary, or near one.
            uint32_t w = rng.Below(kSpan / 5 - 1);
            if (rng.Below(3) == 0) {
              const uint32_t page = 1 + rng.Below(kSpan / 4096 - 1);
              w = (page * 4096 - 1 - rng.Below(8)) / 5;
            }
            addr = kBase + 5 * w;
            break;
          }
          case kWord:
          case kRead:
            addr = kBase + 4 * rng.Below(kSpan / 4);
            break;
        }
        wdata = (static_cast<uint64_t>(rng.Next()) << 8 ^ rng.Next()) & ((1ull << 40) - 1);
        abandon = rng.Below(20) == 0;
        refuse = rng.Below(8) == 0 ? 1 + (errors % 2) : 0;
        before.clear();
        aw_mine = ar_mine = 0;
      }
    }
    m->mem_req = asking || hold_after > 0;
    m->mem_write = kind == kWide || kind == kWord;
    m->mem_line = kind == kLine5 || kind == kLine4;
    m->mem_beats = kind == kLine5 ? 5 : kind == kLine4 ? 4 : 0;
    m->mem_wide = kind == kWide;
    m->mem_addr = addr;
    m->mem_wdata = kind == kWord ? (wdata & 0xFFFFFFFFull) : wdata;

    // --- the slave's outputs for this tick
    const bool one_write = t >= kOneWriteFrom;
    m->m_awready = (one_write ? aw_q.empty() && b_q.empty() : aw_q.size() < 2) && rng.Below(3) != 0;
    m->m_wready = rng.Below(3) != 0;
    m->m_arready = ar_q.size() < 3 && rng.Below(3) != 0;
    m->m_bvalid = 0;
    m->m_rvalid = 0;
    if (!b_q.empty() && b_delay == 0) {
      m->m_bvalid = 1;
      m->m_bresp = b_q.front().b.resp;
    }
    if (!ar_q.empty() && r_delay == 0) {
      const Burst &b = ar_q.front();
      m->m_rvalid = rng.Below(4) != 0;
      uint64_t d = 0;
      for (int k = 0; k < 8; ++k) d |= static_cast<uint64_t>(get(b.addr + 8 * r_beat + k)) << (8 * k);
      m->m_rdata = d;
      m->m_rresp = b.resp;
      m->m_rlast = r_beat == b.beats - 1;
    }
    m->eval();

    // --- the protocol, before the edge
    if (ar_was && (!m->m_arvalid || m->m_araddr != ar_addr_was || m->m_arlen != ar_len_was))
      fail(t, "a read address withdrawn or changed before it was taken");
    if (aw_was && (!m->m_awvalid || m->m_awaddr != aw_addr_was || m->m_awlen != aw_len_was))
      fail(t, "a write address withdrawn or changed before it was taken");
    if (w_was && (!m->m_wvalid || m->m_wdata != w_data_was || m->m_wstrb != w_strb_was ||
                  m->m_wlast != w_last_was))
      fail(t, "a write beat withdrawn or changed before it was taken");
    auto crosses = [](uint32_t a, int beats) { return (a & 0xFFFu) + 8u * beats > 0x1000u; };
    if (m->m_arvalid) {
      if (m->m_arsize != 3 || m->m_arburst != 1 || (m->m_araddr & 7)) fail(t, "a read not full-width INCR");
      if (crosses(m->m_araddr, m->m_arlen + 1)) fail(t, "a read burst across a 4 KiB boundary");
    }
    if (m->m_awvalid) {
      if (m->m_awsize != 3 || m->m_awburst != 1 || (m->m_awaddr & 7)) fail(t, "a write not full-width INCR");
      if (crosses(m->m_awaddr, m->m_awlen + 1)) fail(t, "a write burst across a 4 KiB boundary");
    }
    // A split line's second address, up in the tick after the first's.
    if (first_ar_taken >= 0 && t == first_ar_taken + 1) {
      if (m->m_arvalid) ++pipelined;
      else fail(t, "a split line's second address waited");
      first_ar_taken = -1;
    }

    const bool aw_take = m->m_awvalid && m->m_awready;
    const bool w_take = m->m_wvalid && m->m_wready;
    const bool ar_take = m->m_arvalid && m->m_arready;
    const bool b_take = m->m_bvalid && m->m_bready;
    const bool r_take = m->m_rvalid && m->m_rready;
    ar_was = m->m_arvalid && !ar_take;
    ar_addr_was = m->m_araddr;
    ar_len_was = m->m_arlen;
    aw_was = m->m_awvalid && !aw_take;
    aw_addr_was = m->m_awaddr;
    aw_len_was = m->m_awlen;
    w_was = m->m_wvalid && !w_take;
    w_data_was = m->m_wdata;
    w_strb_was = m->m_wstrb;
    w_last_was = m->m_wlast;

    const int resp_now = refuse ? (refuse == 1 ? 2 : 3) : 0;
    if (ar_take) {
      if (ar_q.empty()) r_delay = static_cast<int>(rng.Below(6));
      const bool old = stale_ar > 0;
      if (old) --stale_ar;
      else ++ar_mine;
      ar_q.push_back({m->m_araddr, m->m_arlen + 1, old ? stale_resp : resp_now, old});
      // The first of a split line's two: its bytes stop at the boundary.
      if (!old && m->mem_line && m->m_araddr == (addr & ~7u) &&
          static_cast<int>(m->m_arlen + 1) < m->mem_beats) {
        first_ar_taken = t;
      }
    }
    if (aw_take) {
      const bool old = stale_aw > 0;
      if (old) --stale_aw;
      else ++aw_mine;
      aw_q.push_back({m->m_awaddr, m->m_awlen + 1, old ? stale_resp : resp_now, old});
    }
    if (w_take) {
      w_pending.push_back({m->m_wdata, static_cast<uint8_t>(m->m_wstrb), m->m_wlast != 0});
    }
    // A burst whose address and every beat are in is written, unless it is
    // refused, and owed its response.
    if (!aw_q.empty() && static_cast<int>(w_pending.size()) >= aw_q.front().beats) {
      WBurst wb{aw_q.front(), {}};
      aw_q.pop_front();
      for (int k = 0; k < wb.b.beats; ++k) {
        wb.data.push_back(w_pending.front());
        w_pending.pop_front();
        // The burst's last beat marked, and no other.
        if (wb.data.back().last != (k == wb.b.beats - 1))
          fail(t, "a write burst's last beat not marked, or another marked");
      }
      if (!wb.b.resp) {
        for (int k = 0; k < wb.b.beats; ++k)
          for (int j = 0; j < 8; ++j)
            if (wb.data[k].strb >> j & 1) {
              const uint32_t a = wb.b.addr + 8 * k + j;
              if (!wb.b.old && !before.count(a)) before[a] = get(a);
              ddr[a] = static_cast<uint8_t>(wb.data[k].data >> (8 * j));
            }
      }
      if (b_q.empty()) b_delay = static_cast<int>(rng.Below(6));
      b_q.push_back(wb);
    }
    if (b_take) {
      b_q.pop_front();
      if (!b_q.empty()) b_delay = static_cast<int>(rng.Below(4));
    }
    if (r_take) {
      if (r_beat == ar_q.front().beats - 1) {
        ar_q.pop_front();
        r_beat = 0;
        r_delay = static_cast<int>(rng.Below(3));
      } else {
        ++r_beat;
        r_delay = static_cast<int>(rng.Below(3));
      }
    }
    if (r_delay > 0) --r_delay;
    if (b_delay > 0) --b_delay;

    // A transaction that never finishes: the port and the master each
    // waiting on the other.
    if (asking && asked_at < 0) asked_at = t;
    if (!asking) asked_at = -1;
    if (asked_at >= 0 && t - asked_at == 20000) fail(t, "a transaction never finished: the master and the port wait on each other");
    // An answer only to a request standing, or let go in this tick: the
    // one it was abandoned by is finished on the port and thrown away.
    if (m->mem_done && !req_was) fail(t, "an answer with no request standing");
    req_was = m->mem_req;

    // The answer, as the requester sees it before the edge.
    if (asking && m->mem_done) {
      ++answered;
      if (m->mem_error != (refuse != 0)) fail(t, "mem_error is not what the port answered");
      if (kind == kLine5 || kind == kLine4) {
        const int beats = kind == kLine5 ? 5 : 4;
        (kind == kLine5 ? lines5 : lines4)++;
        if ((addr & 0xFFFu) + 8u * beats > 0x1000u) ++split_lines;
        if (!refuse)
          for (int b = 0; b < 8 * beats; ++b) {
            const uint8_t got = static_cast<uint8_t>(m->mem_rline[b / 4] >> (8 * (b % 4)));
            if (got != get(addr + b)) {
              fail(t, "a line's byte is wrong");
              break;
            }
          }
      } else if (kind == kRead) {
        ++reads;
        uint32_t want = 0;
        for (int b = 0; b < 4; ++b) want |= static_cast<uint32_t>(get(addr + b)) << (8 * b);
        if (!refuse && m->mem_rdata != want) fail(t, "a word read is wrong");
      } else {
        // Exactly the word's bytes changed, to the word's; a refused write
        // changed nothing.
        const int bytes = kind == kWide ? 5 : 4;
        if (kind == kWide) {
          ++wides;
          if ((addr & 7) > 3) ++spanning;
          if ((addr & 0xFFFu) > 0xFFBu) {
            ++split_writes;
            if (t >= kOneWriteFrom) ++split_writes_one;
          }
        } else {
          ++words;
        }
        for (const auto &e : before) {
          const bool mine = e.first >= addr && e.first < addr + bytes;
          if (!mine) fail(t, "a write changed a byte outside its word");
        }
        if (!refuse) {
          for (int b = 0; b < bytes; ++b)
            if (get(addr + b) != static_cast<uint8_t>(wdata >> (8 * b))) fail(t, "a write's byte is wrong");
          if (static_cast<int>(before.size()) != bytes) {
            if (bad < 3)
              std::fprintf(stderr, "  wrote %zu of %d bytes at %08x, kind %d, abandoned %ld\n", before.size(),
                           bytes, addr, kind, abandoned);
            fail(t, "a write did not write all its bytes");
          }
        } else if (!before.empty()) {
          fail(t, "a refused write landed");
        }
      }
      if (refuse) ++errors;
      asking = false;
      hold_after = 1 + static_cast<int>(rng.Below(2));
    } else if (hold_after > 0) {
      if (--hold_after == 0) idle_gap = 1 + static_cast<int>(rng.Below(3));
    }
    if (asking && abandon && rng.Below(6) == 0) {
      asking = false;
      const bool writes = kind == kWide || kind == kWord;
      stale_aw = writes ? bursts_of(kind, addr) - aw_mine : 0;
      stale_ar = writes ? 0 : bursts_of(kind, addr) - ar_mine;
      stale_resp = resp_now;
      was_abandoned = true;
      ++abandoned;
      hold_after = 0;
      idle_gap = 1 + static_cast<int>(rng.Below(3));
    }

    m->clk = 1;
    m->eval();
    m->clk = 0;
    m->eval();
  }

  std::printf("quux13_axi_master: %ld answers: %ld five-beat lines and %ld four-beat, %ld of them "
              "split at 4 KiB, the second address up a tick after the first %ld times; %ld five-byte "
              "writes, %ld of them over two beats and %ld split at 4 KiB; %ld four-byte writes, %ld "
              "word reads; %ld refused; %ld requests let go before their answer; %ld split writes "
              "under the one-write rule\n",
              answered, lines5, lines4, split_lines, pipelined, wides, spanning, split_writes, words,
              reads, errors, abandoned, split_writes_one);
  if (!bad && (lines5 < 2000 || lines4 < 500 || split_lines < 300 || pipelined < 200 || wides < 2000 ||
               spanning < 500 || split_writes < 100 || words < 1000 || reads < 500 || errors < 100 ||
               abandoned < 100 || split_writes_one < 40)) {
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
