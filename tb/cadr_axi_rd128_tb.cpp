// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A 64-bit read master with several bursts in flight on a 128-bit port:
// `rtl/plumbing/cadr_axi_rd128.sv`.
//
// **THE MASTER HERE HAS MORE IN FLIGHT THAN THE MODULE HOLDS, AND MOVES ITS
// ADDRESS AT ONCE**, as `cadr_display_out.sv` does: it offers a new burst on
// the cycle after each is taken, up to twelve outstanding against the
// module's eight, so the queue fills and the module must hold the channel.
// Each burst starts at a random eight-byte-aligned address, so in either
// half, with a random length of one to sixteen beats, odd and even.
//
// THE PORT IS A MEMORY THAT ANSWERS IN ORDER, at a random latency, with
// valid and ready dropping at random.  Every 128-bit beat carries the
// doubleword the beat's address names in its half and a DIFFERENT word in
// the other half, so a wrong half is a wrong answer; and the doubleword is
// injective in its address.  The half a beat belongs in is worked out here
// from the burst's address and the beat's number, never read from the DUT.
//
// What is held: every beat the master takes is the doubleword at the address
// it asked for, in order; no burst reaches the port that the master did not
// offer, and none twice; more than eight are never out at the port; and the
// whole run's beats all arrive.

#include <cstdint>
#include <cstdio>
#include <deque>

#include "Vcadr_axi_rd128.h"
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

// The doubleword at an eight-byte-aligned address: injective in it.
uint64_t mem64(uint32_t a) {
  const uint64_t x = a >> 3;
  return (x * 0x9E3779B97F4A7C15ull) ^ (x << 40) ^ 0x5A5A0000u;
}

struct Burst {
  uint32_t addr;
  unsigned len;  // beats - 1
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *d = new Vcadr_axi_rd128;
  unsigned s = 12345;
  const int kBursts = 4000;

  std::deque<Burst> offered_order;   // what the master offered, in order
  std::deque<Burst> at_port;         // taken by the port, awaiting data
  std::deque<Burst> expect;          // the master's own record, to check data
  Burst cur{};
  int offered = 0, done = 0, outstanding = 0, max_port = 0;
  bool have = false;
  unsigned beat_m = 0;               // beat within the burst the port is answering
  unsigned beat_s = 0;               // beat within the burst the master is taking
  int latency = 0;
  long beats_taken = 0, beats_wanted = 0;

  auto tick = [&](int clk) {
    d->clk = clk;
    d->eval();
  };

  d->rst = 1;
  d->s_arvalid = 0;
  d->s_rready = 0;
  d->m_arready = 0;
  d->m_rvalid = 0;
  d->m_rlast = 0;
  d->m_rdata[0] = d->m_rdata[1] = d->m_rdata[2] = d->m_rdata[3] = 0;
  for (int i = 0; i < 4; i++) { tick(0); tick(1); }
  d->rst = 0;

  while (done < kBursts && cyc < 2000000) {
    ++cyc;
    // The master: a new burst whenever it has none offered, up to twelve out.
    if (!have && offered < kBursts && outstanding < 12) {
      cur.addr = ((lcg(s) << 8) ^ lcg(s)) & 0x7FFF'FFF8u;
      cur.len = lcg(s) & 15u;
      have = true;
    }
    d->s_arvalid = have;
    d->s_araddr = cur.addr;
    d->s_arlen = cur.len;
    d->s_arsize = 3;
    d->s_rready = (lcg(s) & 3u) != 0;
    // The port: ready at random; data in order after a random latency.
    d->m_arready = (lcg(s) & 3u) != 0;
    bool give = false;
    if (!at_port.empty()) {
      if (latency > 0) --latency;
      give = latency == 0 && (lcg(s) & 3u) != 0;
    }
    if (give) {
      const Burst &b = at_port.front();
      const uint32_t a = b.addr + 8u * beat_m;
      const uint64_t right = mem64(a), other = ~mem64(a) ^ 0x1234;
      const uint64_t lo = (a & 8u) ? other : right, hi = (a & 8u) ? right : other;
      d->m_rdata[0] = static_cast<uint32_t>(lo);
      d->m_rdata[1] = static_cast<uint32_t>(lo >> 32);
      d->m_rdata[2] = static_cast<uint32_t>(hi);
      d->m_rdata[3] = static_cast<uint32_t>(hi >> 32);
      d->m_rlast = beat_m == b.len;
    } else {
      d->m_rlast = 0;
    }
    d->m_rvalid = give;
    tick(0);

    // What the cycle's edge takes, read before it.
    const bool ar_m = d->m_arvalid && d->m_arready;
    const bool ar_s = d->s_arvalid && d->s_arready;
    const bool r = d->m_rvalid && d->s_rready;
    if (ar_s != ar_m) fail("an address handshake on one side only", ar_s, ar_m);
    if (d->m_arvalid && (d->m_araddr != cur.addr || d->m_arlen != cur.len || d->m_arsize != 3))
      fail("the port's address is not the master's", d->m_araddr, cur.addr);
    if (d->s_rvalid != d->m_rvalid) fail("RVALID", d->s_rvalid, d->m_rvalid);
    if (d->m_rready != d->s_rready) fail("RREADY", d->m_rready, d->s_rready);
    if (r) {
      if (expect.empty()) {
        fail("a beat with no burst asked", 1, 0);
      } else {
        const Burst &b = expect.front();
        const uint32_t a = b.addr + 8u * beat_s;
        const uint64_t got = (static_cast<uint64_t>(d->s_rdata) );
        if (got != mem64(a)) fail("a beat's doubleword", got, mem64(a));
        if (d->s_rlast != (beat_s == b.len)) fail("RLAST", d->s_rlast, beat_s == b.len);
        ++beats_taken;
        if (beat_s == b.len) {
          expect.pop_front();
          beat_s = 0;
        } else {
          ++beat_s;
        }
      }
    }
    if (ar_m) {
      at_port.push_back(cur);
      expect.push_back(cur);
      beats_wanted += cur.len + 1;
      have = false;
      ++offered;
      ++outstanding;
      if (static_cast<int>(at_port.size()) > max_port) max_port = at_port.size();
      if (at_port.size() == 1) latency = lcg(s) % 24;
    }
    if (r) {
      if (beat_m == at_port.front().len) {
        at_port.pop_front();
        beat_m = 0;
        --outstanding;
        ++done;
        if (!at_port.empty()) latency = lcg(s) % 6;
      } else {
        ++beat_m;
      }
    }
    tick(1);
  }

  if (done != kBursts) fail("bursts finished", done, kBursts);
  if (beats_taken != beats_wanted) fail("beats taken", beats_taken, beats_wanted);
  if (max_port > 8) fail("bursts out at the port at once", max_port, 8);
  if (max_port < 8) fail("the queue never filled: bursts out at most", max_port, 8);
  delete d;
  if (bad) {
    std::fprintf(stderr, "axi_rd128: %d failure(s)\n", bad);
    return 1;
  }
  std::printf("ok: cadr_axi_rd128, %d bursts, %ld beats, eight out at once\n", kBursts,
              beats_taken);
  return 0;
}
