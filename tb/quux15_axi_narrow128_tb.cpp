// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// rtl/plumbing/quux_axi_narrow128.sv behind QUUX revision 15's memory master,
// rtl/plumbing/quux15_axi_master.sv, as the Kria KR260 builds the pair
// (tb/quux15_axi_narrow128_harness.sv), against AXI4's rules on a 128-bit
// port and against memory.  The core's own testbench answers the master
// with its address and its first beat taken in one clock, as muir's port
// accepts a write; a port keeps no such rule, and the narrowing holds a beat
// until its burst's address has gone, so here **EACH CHANNEL'S READY IS ITS
// OWN**, drawn at random every clock.
//
// What is held, at the port:
//   - every address taken has exactly its burst of beats, in the order the
//     addresses were taken, `WLAST` on its last; no beat comes with no
//     address for it, and no address is left at the end with no beats ---
//     a master that offers a taken address again sends the port a burst it
//     never gives data for;
//   - every transfer narrow: `AxSIZE` eight bytes, each beat's strobes in
//     the half bit 3 of its address selects, a read beat's bytes put there by
//     the port with the other half poisoned;
//   - one write response a burst, in order.
// And at the master's port side, played as `quux15_port.sv` plays it: each
// word write offered while `w_free` and held until `w_taken`, up to sixteen
// unanswered, each answered once, in order (`b_done`, `b_id`); each line
// read held until `ar_taken`, one at a time, after every write to its line
// is answered (the read rule), its 40 bytes at `rd_last` main memory's.
// Main memory is packed storage from the board's base: word w at byte 5w,
// line L at 40L, and a write's word lands at 5w as five bytes; the words
// are drawn so that one in two runs into a second beat and some into the
// next 4 KiB page.  At the end every byte written must be memory's.

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <vector>

#include "Vquux15_axi_narrow128_harness.h"
#include "verilated.h"

namespace {

constexpr uint64_t kBase = 0x5A000000ull;
constexpr uint32_t kWords = 1u << 16;            // the words a run touches
constexpr size_t kBytes = size_t(kWords) * 5 + 64;

struct Rng {
  uint64_t s;
  uint64_t next() {
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    return s * 0x2545F4914F6CDD1Dull;
  }
  bool chance(unsigned pct) { return next() % 100 < pct; }
  uint32_t below(uint32_t n) { return static_cast<uint32_t>(next() % n); }
};

struct Burst {
  uint64_t addr;
  unsigned len, sent;
};

int run(uint64_t seed, unsigned aw_pct, unsigned w_pct, unsigned ar_pct, unsigned r_pct,
        unsigned b_pct, long ops) {
  Rng rng{seed * 0x9E3779B97F4A7C15ull + 1};
  auto *d = new Vquux15_axi_narrow128_harness;
  std::vector<uint8_t> mem(kBytes), want(kBytes);
  for (size_t i = 0; i < kBytes; ++i) mem[i] = want[i] = static_cast<uint8_t>(rng.next());
  long bad = 0, tick_n = 0;
  auto fail = [&](const char *what) {
    if (bad < 10) std::fprintf(stderr, "seed %" PRIu64 ", clock %ld: %s\n", seed, tick_n, what);
    ++bad;
  };

  // --- the port --------------------------------------------------------------
  std::deque<Burst> aw_q, ar_q;
  std::deque<long> b_due;                 // a burst's response, by clock
  long r_wait = -1;
  // The master's side.
  struct Wr {
    uint32_t w;
    uint64_t word;
  };
  std::deque<Wr> to_write;
  long writes = 0, two_beat = 0, splits = 0, reads = 0, bursts_w = 0, bursts_r = 0;
  std::vector<int> pending(kWords / 8 + 1, 0);   // unanswered writes, by line
  std::deque<uint32_t> inflight;                  // the lines of the writes taken, in order
  bool w_on = false, ar_on = false, rd_wait = false;
  Wr cur{};
  uint32_t cur_line = 0, next_id = 0, ans_id = 0;
  long done_ops = 0;

  auto drive = [&]() {
    // The port's readies, each its own.
    d->m_awready = rng.chance(aw_pct);
    d->m_wready = rng.chance(w_pct);
    d->m_arready = rng.chance(ar_pct);
    d->m_bvalid = !b_due.empty() && b_due.front() <= tick_n && rng.chance(b_pct);
    d->m_bresp = 0;
    d->m_rvalid = 0;
    d->m_rlast = 0;
    if (!ar_q.empty() && r_wait >= 0 && tick_n >= r_wait && rng.chance(r_pct)) {
      Burst &b = ar_q.front();
      const uint64_t a = b.addr + 8ull * b.sent;
      uint32_t w[4];
      for (int k = 0; k < 4; ++k) w[k] = 0xDEADBEEFu;
      uint8_t bytes[16];
      std::memcpy(bytes, w, 16);
      for (int k = 0; k < 8; ++k) {
        const uint64_t off = a - kBase + k;
        bytes[(a & 8) + k] = off < kBytes ? mem[off] : 0xA5;
      }
      std::memcpy(&d->m_rdata, bytes, 16);
      d->m_rvalid = 1;
      d->m_rlast = b.sent + 1 == b.len;
    }
    // The master's port side: a write offered while free, a read when the
    // line's writes are answered.
    if (!w_on && !to_write.empty() && d->w_free && inflight.size() < 16) {
      cur = to_write.front();
      to_write.pop_front();
      w_on = true;
    }
    d->w_req = w_on;
    d->w_bus = cur.w;
    d->w_word = cur.word;
    d->w_id = next_id & 15;
    if (!ar_on && !rd_wait && done_ops < ops && rng.chance(20)) {
      cur_line = rng.below(kWords / 8 - 1);
      if (pending[cur_line] == 0) ar_on = true;
    }
    d->ar_req = ar_on;
    d->ar_line = cur_line;
  };

  auto take = [&]() {
    // The port's channels, before the edge.
    if (d->m_awvalid && d->m_awready) {
      if (d->m_awsize != 3) fail("a write address not eight bytes a beat");
      if (d->m_awaddr % 8) fail("a write address off eight bytes");
      aw_q.push_back({d->m_awaddr, d->m_awlen + 1u, 0});
      ++bursts_w;
    }
    if (d->m_wvalid && d->m_wready) {
      if (aw_q.empty() || aw_q.front().sent == aw_q.front().len) {
        fail("a write beat with no address for it");
      } else {
        // The oldest address still owed beats.
        Burst *b = nullptr;
        for (auto &x : aw_q)
          if (x.sent < x.len) {
            b = &x;
            break;
          }
        const uint64_t a = b->addr + 8ull * b->sent;
        uint8_t bytes[16];
        std::memcpy(bytes, &d->m_wdata, 16);
        const unsigned half = (a & 8) ? 0x00FFu : 0xFF00u;
        if (d->m_wstrb & half) fail("a write beat's strobes outside the half its address selects");
        for (int k = 0; k < 16; ++k)
          if ((d->m_wstrb >> k) & 1) {
            const uint64_t off = (a & ~15ull) + k - kBase;
            if (off < kBytes) mem[off] = bytes[k];
          }
        ++b->sent;
        if (d->m_wlast != (b->sent == b->len)) fail("WLAST not on the burst's last beat");
        if (b->sent == b->len) b_due.push_back(tick_n + 2 + rng.below(20));
      }
      while (!aw_q.empty() && aw_q.front().sent == aw_q.front().len) aw_q.pop_front();
    }
    if (d->m_bvalid && d->m_bready) b_due.pop_front();
    if (d->m_arvalid && d->m_arready) {
      if (d->m_arsize != 3) fail("a read address not eight bytes a beat");
      ar_q.push_back({d->m_araddr, d->m_arlen + 1u, 0});
      if (ar_q.size() == 1) r_wait = tick_n + 3 + rng.below(30);
      ++bursts_r;
    }
    if (d->m_rvalid && d->m_rready) {
      Burst &b = ar_q.front();
      if (++b.sent == b.len) {
        ar_q.pop_front();
        r_wait = ar_q.empty() ? -1 : tick_n + 1;
      }
    }
    // The master's port side.
    if (w_on && d->w_taken) {
      for (int k = 0; k < 5; ++k) want[5ull * cur.w + k] = static_cast<uint8_t>(cur.word >> (8 * k));
      ++pending[cur.w / 8];
      inflight.push_back(cur.w / 8);
      ++next_id;
      w_on = false;
      ++writes;
      ++done_ops;
    }
    if (d->b_done) {
      if (inflight.empty()) {
        fail("a write answered that was not taken");
      } else {
        if (d->b_id != (ans_id & 15)) fail("a write answered out of order");
        --pending[inflight.front()];
        inflight.pop_front();
        ++ans_id;
      }
    }
    if (ar_on && d->ar_taken) {
      ar_on = false;
      rd_wait = true;
    }
    if (rd_wait && d->rd_last) {
      uint8_t got[40];
      std::memcpy(got, &d->rd_data, 40);
      if (std::memcmp(got, &mem[40ull * cur_line], 40) != 0) fail("a line read is not main memory's");
      rd_wait = false;
      ++reads;
      ++done_ops;
    }
  };

  // The words to write: every second one into a second beat, some across a
  // 4 KiB page.
  for (long k = 0; k < ops; ++k) {
    uint32_t w = rng.below(kWords - 1);
    if (rng.chance(10)) w = (4096u * (1 + rng.below(60)) - 4) / 5;
    const uint64_t word = rng.next() & 0xFFFFFFFFFFull;
    to_write.push_back({w, word});
    const unsigned off = (5u * w) % 8;
    if (off >= 4) {
      ++two_beat;
      if ((5u * w / 8 + 1) % 512 == 0) ++splits;
    }
  }

  d->rst = 1;
  d->ar_req = 0;
  d->w_req = 0;
  for (int k = 0; k < 4; ++k) {
    d->clk = 0;
    d->eval();
    d->clk = 1;
    d->eval();
  }
  d->rst = 0;
  const long limit = ops * 200 + 10000;
  while (tick_n < limit && bad == 0) {
    drive();
    d->clk = 0;
    d->eval();
    take();
    d->clk = 1;
    d->eval();
    ++tick_n;
    if (to_write.empty() && !w_on && inflight.empty() && !ar_on && !rd_wait && b_due.empty() &&
        aw_q.empty() && ar_q.empty() && done_ops >= ops)
      break;
  }
  if (bad == 0 && tick_n >= limit) {
    char why[200];
    std::snprintf(why, sizeof why,
                  "the run did not end: %zu writes still to offer, %zu unanswered, %zu addresses "
                  "owed beats, %zu responses owed",
                  to_write.size(), inflight.size(), aw_q.size(), b_due.size());
    fail(why);
  }
  if (bad == 0 && std::memcmp(mem.data(), want.data(), kBytes) != 0) fail("main memory is not every word written");
  delete d;
  if (bad) {
    std::fprintf(stderr, "FAIL: seed %" PRIu64 ", readies %u/%u/%u/%u/%u: %ld problems\n", seed, aw_pct,
                 w_pct, ar_pct, r_pct, b_pct, bad);
    return 1;
  }
  std::printf("ok: seed %" PRIu64 ", readies AW %u%% W %u%% AR %u%% R %u%% B %u%%: %ld writes (%ld of two "
              "beats, %ld across 4 KiB) in %ld write bursts, %ld line reads in %ld read bursts, %ld clocks\n",
              seed, aw_pct, w_pct, ar_pct, r_pct, b_pct, writes, two_beat, splits, bursts_w, reads, bursts_r,
              tick_n);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int bad = 0;
  // Every ready up at once, as the core's testbench has them; then each its
  // own at random, the write channels apart, and slow.
  const unsigned cases[][5] = {{100, 100, 100, 100, 100}, {50, 50, 50, 70, 50}, {90, 20, 60, 50, 30},
                               {20, 90, 30, 90, 80}, {10, 10, 10, 20, 10}};
  for (uint64_t seed = 1; seed <= 3; ++seed)
    for (const auto &c : cases) bad += run(seed, c[0], c[1], c[2], c[3], c[4], 3000);
  return bad ? 1 : 0;
}
