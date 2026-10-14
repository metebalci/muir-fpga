// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// rtl/plumbing/quux15_axi3.sv behind QUUX revision 15's memory master,
// rtl/plumbing/quux15_axi_master.sv, as the Arty Z7-20 builds the pair
// (tb/quux15_axi3_harness.sv), against AXI3's rules on a 64-bit port and
// against memory.  The core's own testbench takes a write's address and its
// first beat in one clock, as muir's port accepts a write, and the Kria's
// 128-bit narrowing holds a beat until its burst's address has gone, so
// neither ever gives the master a port that takes the beat first.  S_AXI_HP0
// may take a write's data before its address or after it, so here the port
// is run three ways:
//
//   AW first   a beat is taken only while an address taken already is owed
//              beats, as the Kria's narrowing makes its port;
//   W first    an address is taken only once a beat taken in an earlier
//              clock waits for it, so every burst's first beat goes before
//              its address;
//   free       each channel's ready its own, at random, the two in one clock
//              among the rest.
//
// What is held, at the port:
//   - the beats are the bursts' in order, whichever came first: every
//     address taken has exactly its burst of beats, `WLAST` on its last, and
//     no beat is left over at the end --- a master that offers a taken beat
//     again sends the port a beat of the next burst that is not that burst's,
//     and one that offers a taken address again sends a burst it never gives
//     data for;
//   - every transfer eight bytes a beat (`AxSIZE` 3, two bits), INCR, the
//     length AXI3's four bits as the master asked;
//   - every write with ID 0, the port's tied `AWID` and `WID`;
//   - one write response a burst, in order, once its address and all its
//     beats are taken.
// And at the master's port side, played as `quux15_port.sv` plays it: each
// word write offered while `w_free` and held until `w_taken`, up to sixteen
// unanswered, each answered once, in order (`b_done`, `b_id`), and none to a
// line whose read is out; each line read held until `ar_taken`, one at a
// time, after every write to its line, offered or taken, is answered (the
// read rule), its 40 bytes at `rd_last` main memory's.  Main
// memory is packed storage from the Arty's base: word w at byte 5w, line L at
// 40L; the words are drawn so that one in two runs into a second beat and
// some into the next 4 KiB page.  At the end every byte written must be
// memory's.

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <vector>

#include "Vquux15_axi3_harness.h"
#include "verilated.h"

namespace {

constexpr uint64_t kBase = 0x12000000ull;
constexpr uint32_t kWords = 1u << 16;            // the words a run touches
constexpr size_t kBytes = size_t(kWords) * 5 + 64;

enum Order { kAwFirst, kWFirst, kFree };
const char *order_name(Order o) { return o == kAwFirst ? "AW first" : o == kWFirst ? "W first" : "free"; }

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
  long at;                                // the clock its address was taken
};

struct Beat {
  uint64_t data;
  unsigned strb;
  bool last;
  long at;                                // the clock it was taken
};

int run(uint64_t seed, Order order, unsigned aw_pct, unsigned w_pct, unsigned ar_pct, unsigned r_pct,
        unsigned b_pct, long ops) {
  Rng rng{seed * 0x9E3779B97F4A7C15ull + 7 + order};
  auto *d = new Vquux15_axi3_harness;
  std::vector<uint8_t> mem(kBytes), want(kBytes);
  for (size_t i = 0; i < kBytes; ++i) mem[i] = want[i] = static_cast<uint8_t>(rng.next());
  long bad = 0, tick_n = 0;
  auto fail = [&](const char *what) {
    if (bad < 10)
      std::fprintf(stderr, "seed %" PRIu64 ", %s, clock %ld: %s\n", seed, order_name(order), tick_n, what);
    ++bad;
  };

  // --- the port --------------------------------------------------------------
  std::deque<Burst> aw_q, ar_q;           // write bursts owed beats; read bursts owed beats
  std::deque<Beat> w_early;               // beats taken before their burst's address
  std::deque<long> b_due;                 // a burst's response, by clock
  long r_wait = -1;
  long w_first_n = 0, aw_first_n = 0, same_n = 0;
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

  // The beats the port is owed by the addresses it has taken.
  auto owed = [&]() {
    unsigned n = 0;
    for (auto &x : aw_q) n += x.len - x.sent;
    return n;
  };

  // A beat into the burst it belongs to, memory and all; a burst's first
  // beat counted by where it went against its address.
  auto land = [&](Burst &b, const Beat &w) {
    if (b.sent == 0) {
      if (w.at < b.at) ++w_first_n;
      else if (w.at == b.at) ++same_n;
      else ++aw_first_n;
    }
    const uint64_t a = b.addr + 8ull * b.sent;
    for (int k = 0; k < 8; ++k)
      if ((w.strb >> k) & 1) {
        const uint64_t off = a + k - kBase;
        if (off < kBytes) mem[off] = static_cast<uint8_t>(w.data >> (8 * k));
      }
    ++b.sent;
    if (w.last != (b.sent == b.len)) fail("WLAST not on the burst's last beat");
    if (b.sent == b.len) b_due.push_back(tick_n + 2 + rng.below(20));
  };

  auto drive = [&]() {
    // The port's readies, by the order this run keeps.
    bool awr = rng.chance(aw_pct), wr = rng.chance(w_pct);
    if (order == kAwFirst) wr = wr && owed() > 0;
    if (order == kWFirst) awr = awr && !w_early.empty();
    d->m_awready = awr;
    d->m_wready = wr;
    d->m_arready = rng.chance(ar_pct);
    d->m_bvalid = !b_due.empty() && b_due.front() <= tick_n && rng.chance(b_pct);
    d->m_bresp = 0;
    d->m_rresp = 0;
    d->m_rvalid = 0;
    d->m_rlast = 0;
    d->m_rdata = 0;
    if (!ar_q.empty() && r_wait >= 0 && tick_n >= r_wait && rng.chance(r_pct)) {
      Burst &b = ar_q.front();
      const uint64_t a = b.addr + 8ull * b.sent;
      uint64_t v = 0;
      for (int k = 0; k < 8; ++k) {
        const uint64_t off = a - kBase + k;
        v |= uint64_t(off < kBytes ? mem[off] : 0xA5) << (8 * k);
      }
      d->m_rdata = v;
      d->m_rvalid = 1;
      d->m_rlast = b.sent + 1 == b.len;
    }
    // The master's port side: a write offered while free, a read when the
    // line's writes are answered, and no write to a line while its read is
    // out (the port's own order: a fill then the word written into it).
    if (!w_on && !to_write.empty() && d->w_free && inflight.size() < 16 &&
        !((ar_on || rd_wait) && to_write.front().w / 8 == cur_line)) {
      cur = to_write.front();
      to_write.pop_front();
      w_on = true;
    }
    d->w_req = w_on;
    d->w_bus = cur.w;
    d->w_word = cur.word;
    d->w_id = next_id & 15;
    // The read rule counts a write offered and not yet taken as one queued.
    if (!ar_on && !rd_wait && done_ops < ops && rng.chance(20)) {
      cur_line = rng.below(kWords / 8 - 1);
      if (pending[cur_line] == 0 && !(w_on && cur.w / 8 == cur_line)) ar_on = true;
    }
    d->ar_req = ar_on;
    d->ar_line = cur_line;
  };

  auto take = [&]() {
    // The port's channels, before the edge: the beat first, so that a beat
    // and an address in one clock meet as the port would see them.
    const bool aw_hs = d->m_awvalid && d->m_awready;
    const bool w_hs = d->m_wvalid && d->m_wready;
    if (w_hs) {
      Beat w{d->m_wdata, d->m_wstrb, static_cast<bool>(d->m_wlast), tick_n};
      Burst *b = nullptr;
      for (auto &x : aw_q)
        if (x.sent < x.len) {
          b = &x;
          break;
        }
      if (b) land(*b, w);
      else w_early.push_back(w);
    }
    if (aw_hs) {
      if (d->m_awsize != 3) fail("a write address not eight bytes a beat");
      if (d->m_awburst != 1) fail("a write burst not INCR");
      if (d->m_awaddr % 8) fail("a write address off eight bytes");
      if (d->m_awid != 0) fail("a write with an ID other than the port's tied zero");
      aw_q.push_back({d->m_awaddr, d->m_awlen + 1u, 0, tick_n});
      ++bursts_w;
      // The beats that came first are this burst's, in order.
      while (!w_early.empty() && aw_q.back().sent < aw_q.back().len) {
        // Only the oldest burst owed beats takes them.
        Burst *b = nullptr;
        for (auto &x : aw_q)
          if (x.sent < x.len) {
            b = &x;
            break;
          }
        land(*b, w_early.front());
        w_early.pop_front();
      }
    }
    while (!aw_q.empty() && aw_q.front().sent == aw_q.front().len) aw_q.pop_front();
    if (d->m_bvalid && d->m_bready) b_due.pop_front();
    if (d->m_arvalid && d->m_arready) {
      if (d->m_arsize != 3) fail("a read address not eight bytes a beat");
      if (d->m_arburst != 1) fail("a read burst not INCR");
      ar_q.push_back({d->m_araddr, d->m_arlen + 1u, 0, tick_n});
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
        aw_q.empty() && ar_q.empty() && w_early.empty() && done_ops >= ops)
      break;
  }
  if (bad == 0 && tick_n >= limit) {
    char why[240];
    std::snprintf(why, sizeof why,
                  "the run did not end: %zu writes still to offer, %zu unanswered, %zu addresses "
                  "owed beats, %zu beats with no address, %zu responses owed",
                  to_write.size(), inflight.size(), aw_q.size(), w_early.size(), b_due.size());
    fail(why);
  }
  if (bad == 0 && std::memcmp(mem.data(), want.data(), kBytes) != 0) fail("main memory is not every word written");
  // The order this run was for must have happened.
  if (bad == 0 && order == kWFirst && w_first_n == 0) fail("no beat went before its address");
  if (bad == 0 && order == kWFirst && (aw_first_n != 0 || same_n != 0))
    fail("a burst's first beat went with or after its address");
  if (bad == 0 && order == kAwFirst && w_first_n != 0) fail("a burst's first beat went before its address");
  if (bad == 0 && order == kFree && (aw_pct < 100 || w_pct < 100) && (w_first_n == 0 || aw_first_n == 0))
    fail("the free port never took a first beat before its address, or never after");
  delete d;
  if (bad) {
    std::fprintf(stderr, "FAIL: seed %" PRIu64 ", %s, readies %u/%u/%u/%u/%u: %ld problems\n", seed,
                 order_name(order), aw_pct, w_pct, ar_pct, r_pct, b_pct, bad);
    return 1;
  }
  std::printf("ok: seed %" PRIu64 ", %s, readies AW %u%% W %u%% AR %u%% R %u%% B %u%%: %ld writes (%ld of "
              "two beats, %ld across 4 KiB) in %ld write bursts, their first beats %ld before the address, "
              "%ld after, %ld with it; %ld line reads in %ld read bursts, %ld clocks\n",
              seed, order_name(order), aw_pct, w_pct, ar_pct, r_pct, b_pct, writes, two_beat, splits, bursts_w,
              w_first_n, aw_first_n, same_n, reads, bursts_r, tick_n);
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
  // Two hundred seeds: a read and a write of one line meeting is rare, and
  // three seeds never met it.
  for (Order o : {kAwFirst, kWFirst, kFree})
    for (uint64_t seed = 1; seed <= 200; ++seed)
      for (const auto &c : cases) bad += run(seed, o, c[0], c[1], c[2], c[3], c[4], 3000);
  return bad ? 1 : 0;
}
