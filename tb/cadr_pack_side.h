// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The far ends of the pack side's two AXI faces, for the two testbenches that
// drive `tb/cadr_disk_harness.sv`: `tb/cadr_disk_pack_tb.cpp`, the property
// check, and `tb/cadr_disk_tb.cpp`, the reference trace.
//
//   Ddr        the memory behind `S_AXI_HP2`, 64-bit beats keyed by address,
//              POISONED where nothing has been written --- a function of the
//              address, never zero and never all ones --- so that a fetch
//              from a wrong address or a write-back that missed lands on
//              something that differs from the answer in every word.  Only
//              the slave below writes it through the port; the testbench
//              seeds it and compares against it.
//
//   Hp2Slave   the slave on that face: an AXI3 slave that counts.  Exactly
//              one address handshake per burst, the number of data beats the
//              length promised, WLAST and RLAST where the length says and
//              nowhere else, a response per burst and one only, no burst
//              crossing 4 KB, beats aligned to their size.  A slave that only
//              recorded the address could not see a duplicate handshake,
//              which is CLAUDE.md's `awvalid-held-up-after-awready` lesson.
//              Ready and valid come with a delay that either VARIES, so that a
//              master which assumed one shape of handshake fails, or is
//              FIXED, for the trace testbench whose rows sit on a 5 ns grid
//              and need every move to cost the same ticks.  It can be told to
//              answer one burst with SLVERR.
//
//   Gp0Master  Linux, on the other face: writes and reads of the pack side's
//              registers as single-beat 32-bit AXI3 transactions, run to
//              completion by a tick callback so that the slave above keeps
//              running while a register write is in flight.
//
// THE TICK PROTOCOL both testbenches follow, because the slave's readies
// depend on the master's valids in the same cycle:
//
//     dut->clk = 0; <set the testbench's own inputs>; dut->eval();
//     side.drive(dut);          // readies and response valids for this cycle
//     dut->eval();
//     side.sample(dut);         // what the edge is about to see
//     dut->clk = 1; dut->eval();
//     side.after_edge(dut);     // the handshakes that happened at it

#ifndef CADR_PACK_SIDE_H
#define CADR_PACK_SIDE_H

#include <cstdint>
#include <cstdio>
#include <functional>
#include <map>
#include <vector>

#include "Vcadr_disk_harness.h"

namespace pack_side {

// The record: 259 words at the block's address --- the block, its header, its
// header checkword and its data checkword --- and the pad word after them
// that a write-back must never touch.  `rtl/cadr_disk_pack.sv`'s header.
const int RECORD_WORDS = 259;
const unsigned RECORD_ALIGN = 128;

// The pack side's registers, at `REG_BASE`.
const unsigned REG_BASE = 0x40000000u;
enum Reg {
  R_ADDR = 0, R_TAG = 1, R_SLOT = 2, R_CTL = 3, R_DRIVE = 4, R_REQ = 5, R_DIRTY = 6,
  R_IDENT = 7, R_REF = 8, R_IRQ = 9, R_IRQEN = 10
};
enum Ctl {
  CTL_FETCH = 1u << 0, CTL_WRITE = 1u << 1, CTL_TAKE = 1u << 2, CTL_DENY = 1u << 3,
  ST_BUSY = 1u << 0, ST_DONE = 1u << 1, ST_ERROR = 1u << 2, ST_REFUSED = 1u << 3,
  ST_CH_ACTIVE = 1u << 4, ST_STORE_MISS = 1u << 5, ST_WAITING = 1u << 6
};
// REQ: the block the controller lacks, valid in bit 31, in TAG's layout below.
const unsigned REQ_VALID = 1u << 31;
// IRQ and IRQEN: the three events.
enum Irq { IRQ_REQ = 1u << 0, IRQ_DIRTY = 1u << 1, IRQ_DONE = 1u << 2 };
const unsigned IDENT = 0x5041434Bu;
// The tag: {unit<2:0>, cylinder<11:0>, head<7:0>, block<7:0>}, the disk
// address register's own layout without its bit 31.
inline uint32_t tag_of(unsigned unit, unsigned c, unsigned h, unsigned b) {
  return (unit & 7u) << 28 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
}

// DCECC's code, for the checkword a Write leaves after the data: thirty-two
// stages, taps 31, 29, 20, 10 and 8, a bit at a time low-order first.  A
// second expression of `Ecc`, written here so that the testbench's
// expectation for a written-back checkword comes from muir's definition and
// not from the module under test.
inline uint32_t ecc_bit(uint32_t r, int d, bool fb) {
  const int inp = fb && (d ^ (int)(r & 1u));
  r >>= 1;
  if (inp) r ^= 0xA0100500u;
  return r;
}
inline uint32_t ecc_over_words(const uint32_t *w, int n) {
  uint32_t r = 0;
  for (int i = 0; i < n; ++i)
    for (int k = 0; k < 32; ++k) r = ecc_bit(r, (w[i] >> k) & 1u, true);
  return r;   // with feedback off a shift is a shift: raw() is checkword()
}

inline uint32_t lcg(uint32_t &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

// ---------------------------------------------------------------- the DDR
struct Ddr {
  std::map<uint64_t, uint64_t> beats;
  long reads = 0, writes = 0;

  static uint64_t poison(uint64_t a) {
    const uint32_t x = (uint32_t)(a * 0x9E3779B1ull);
    const uint32_t y = (uint32_t)((a ^ 0xA5A55A5Aull) * 0x85EBCA6Bull);
    return ((uint64_t)(y | 1u) << 32) | (x | 2u);
  }
  uint64_t read(uint64_t a) {
    ++reads;
    auto it = beats.find(a & ~7ull);
    return it == beats.end() ? poison(a & ~7ull) : it->second;
  }
  uint64_t peek(uint64_t a) const {
    auto it = beats.find(a & ~7ull);
    return it == beats.end() ? poison(a & ~7ull) : it->second;
  }
  void write(uint64_t a, uint64_t v, unsigned strb) {
    ++writes;
    a &= ~7ull;
    uint64_t cur = peek(a);
    for (int lane = 0; lane < 8; ++lane) {
      const uint64_t m = 0xFFull << (8 * lane);
      if (strb >> lane & 1u) cur = (cur & ~m) | (v & m);
    }
    beats[a] = cur;
  }
  uint32_t word(uint64_t at) const {
    const uint64_t b = peek(at);
    return (at & 4) ? (uint32_t)(b >> 32) : (uint32_t)b;
  }
  void set_word(uint64_t at, uint32_t w) {
    const uint64_t a = at & ~7ull;
    uint64_t b = peek(a);
    if (at & 4) b = (b & 0xFFFFFFFFull) | ((uint64_t)w << 32);
    else b = (b & ~0xFFFFFFFFull) | w;
    beats[a] = b;
  }
  // The record at `at`, as the testbench lays it: the 259 words, and the pad
  // left as its poison.
  void place(uint64_t at, const uint32_t *words) {
    for (int i = 0; i < RECORD_WORDS; ++i) set_word(at + 4u * i, words[i]);
  }
  void record(uint64_t at, uint32_t *words) const {
    for (int i = 0; i < RECORD_WORDS; ++i) words[i] = word(at + 4u * i);
  }
  uint32_t pad(uint64_t at) const { return word(at + 4u * RECORD_WORDS); }
  // Forget everything written, so that a run can be laid out again.
  void clear() { beats.clear(); }
};

// ------------------------------------------------------- the HP2 slave
struct Hp2Slave {
  Ddr *ddr;
  // Fixed delays, or varying ones off `seed`.
  bool vary = false;
  uint32_t seed = 0x5A17;
  int fixed_ready = 0;     // ticks a valid waits for ready
  int fixed_resp = 1;      // ticks after the last beat before the response

  // What is in flight.
  bool aw_open = false, w_open = false, b_pending = false;
  uint64_t aw_addr = 0;
  int aw_len = 0, w_beats = 0;
  int aw_wait = 0, w_wait = 0, b_wait = -1;
  bool ar_open = false, r_open = false;
  uint64_t ar_addr = 0;
  int ar_len = 0, r_beats = 0;
  int ar_wait = 0, r_wait = 0;
  unsigned w_resp = 0, r_resp = 0;
  // Answer the n'th burst (counting AW and AR together from zero) with
  // SLVERR; -1 for none.
  long refuse_burst = -1;
  long bursts = 0;

  // The tally, and the protocol errors seen.
  long aw_count = 0, w_count = 0, b_count = 0, ar_count = 0, r_count = 0;
  long write_bursts = 0, read_bursts = 0;
  std::vector<uint64_t> aw_addrs, ar_addrs;
  std::vector<unsigned> aw_lens, ar_lens, strobes;
  int bad = 0;
  std::function<void(const char *)> complain;

  // The pre-edge snapshot.
  int s_awvalid = 0, s_awready = 0, s_wvalid = 0, s_wready = 0, s_wlast = 0;
  int s_bvalid = 0, s_bready = 0, s_arvalid = 0, s_arready = 0;
  int s_rvalid = 0, s_rready = 0;
  uint64_t s_awaddr = 0, s_araddr = 0, s_wdata = 0;
  unsigned s_wstrb = 0, s_awlen = 0, s_arlen = 0, s_awsize = 0, s_arsize = 0;
  unsigned s_awburst = 0, s_arburst = 0;

  void fail(const char *what) {
    ++bad;
    if (complain) complain(what);
  }
  int delay() { return vary ? (int)(lcg(seed) % 4) : fixed_ready; }
  int resp_delay() { return vary ? (int)(lcg(seed) % 3) : fixed_resp; }

  void reset(Vcadr_disk_harness *dut) {
    aw_open = w_open = b_pending = ar_open = r_open = false;
    b_wait = -1;
    dut->hp2_awready = 0; dut->hp2_wready = 0; dut->hp2_arready = 0;
    dut->hp2_bvalid = 0; dut->hp2_bresp = 0;
    dut->hp2_rvalid = 0; dut->hp2_rdata = 0; dut->hp2_rresp = 0; dut->hp2_rlast = 0;
  }

  // This cycle's readies and response valids, from the state and the
  // master's valids as they stand after the first eval.
  void drive(Vcadr_disk_harness *dut) {
    // AW: TAKEN WHENEVER IT IS OFFERED, open burst or not.  A slave that
    // withheld ready while a burst was open could never see a master
    // offering a second address, which is CLAUDE.md's
    // `awvalid-held-up-after-awready` lesson; taking it and counting it is
    // what makes the duplicate a failure rather than a stall.
    if (dut->hp2_awvalid) {
      if (aw_wait > 0) { --aw_wait; dut->hp2_awready = 0; }
      else dut->hp2_awready = 1;
    } else dut->hp2_awready = 0;
    // W: only once the address is in --- our master sends AW first, and a
    // slave may wait for it.
    if (dut->hp2_wvalid && aw_open) {
      if (w_wait > 0) { --w_wait; dut->hp2_wready = 0; }
      else dut->hp2_wready = 1;
    } else dut->hp2_wready = 0;
    // B
    if (b_pending && b_wait == 0) {
      dut->hp2_bvalid = 1;
      dut->hp2_bresp = w_resp;
    } else {
      dut->hp2_bvalid = 0;
      dut->hp2_bresp = 0;
    }
    // AR, taken whenever offered for the same reason.
    if (dut->hp2_arvalid) {
      if (ar_wait > 0) { --ar_wait; dut->hp2_arready = 0; }
      else dut->hp2_arready = 1;
    } else dut->hp2_arready = 0;
    // R: a beat stands until taken; the next follows after a delay.
    if (ar_open && r_wait == 0) {
      const uint64_t a = ar_addr + 8ull * r_beats;
      dut->hp2_rvalid = 1;
      dut->hp2_rdata = ddr->peek(a);
      dut->hp2_rresp = r_resp;
      dut->hp2_rlast = (r_beats == ar_len);
    } else {
      dut->hp2_rvalid = 0;
      dut->hp2_rdata = 0;
      dut->hp2_rresp = 0;
      dut->hp2_rlast = 0;
    }
  }

  void sample(Vcadr_disk_harness *dut) {
    s_awvalid = dut->hp2_awvalid; s_awready = dut->hp2_awready;
    s_wvalid = dut->hp2_wvalid; s_wready = dut->hp2_wready; s_wlast = dut->hp2_wlast;
    s_bvalid = dut->hp2_bvalid; s_bready = dut->hp2_bready;
    s_arvalid = dut->hp2_arvalid; s_arready = dut->hp2_arready;
    s_rvalid = dut->hp2_rvalid; s_rready = dut->hp2_rready;
    s_awaddr = dut->hp2_awaddr; s_araddr = dut->hp2_araddr;
    s_wdata = dut->hp2_wdata; s_wstrb = dut->hp2_wstrb;
    s_awlen = dut->hp2_awlen; s_arlen = dut->hp2_arlen;
    s_awsize = dut->hp2_awsize; s_arsize = dut->hp2_arsize;
    s_awburst = dut->hp2_awburst; s_arburst = dut->hp2_arburst;
  }

  void check_burst(uint64_t a, unsigned len, unsigned size, unsigned burst,
                   const char *which) {
    char msg[160];
    if (size != 3) {
      std::snprintf(msg, sizeof msg, "%s burst size is %u, not the port's eight bytes", which, size);
      fail(msg);
    }
    if (burst != 1) {
      std::snprintf(msg, sizeof msg, "%s burst is not INCR", which);
      fail(msg);
    }
    if (a & 7) {
      std::snprintf(msg, sizeof msg, "%s burst address %llx is not beat-aligned", which, (unsigned long long)a);
      fail(msg);
    }
    if ((a >> 12) != ((a + 8ull * (len + 1) - 1) >> 12)) {
      std::snprintf(msg, sizeof msg, "%s burst at %llx of %u beats crosses 4 KB", which, (unsigned long long)a, len + 1);
      fail(msg);
    }
  }

  void after_edge(Vcadr_disk_harness *dut) {
    (void)dut;
    if (s_awvalid && s_awready) {
      ++aw_count; ++write_bursts;
      if (aw_open || b_pending) fail("a second write address before the response");
      aw_open = true; w_open = true;
      aw_addr = s_awaddr; aw_len = (int)s_awlen; w_beats = 0;
      aw_addrs.push_back(aw_addr); aw_lens.push_back(s_awlen);
      check_burst(aw_addr, s_awlen, s_awsize, s_awburst, "write");
      w_resp = (bursts == refuse_burst) ? 2u : 0u;
      ++bursts;
      w_wait = delay();
    }
    if (s_wvalid && s_wready) {
      ++w_count;
      if (!aw_open) fail("a data beat with no write address open");
      const uint64_t a = aw_addr + 8ull * w_beats;
      ddr->write(a, s_wdata, s_wstrb);
      strobes.push_back(s_wstrb);
      const bool last = (w_beats == aw_len);
      if ((s_wlast != 0) != last) fail(last ? "WLAST missing on the burst's last beat"
                                            : "WLAST on a beat that is not the last");
      ++w_beats;
      if (last) {
        aw_open = false; w_open = false;
        b_pending = true; b_wait = resp_delay();
      } else {
        w_wait = delay();
      }
    } else if (b_pending && b_wait > 0 && !s_bvalid) {
      --b_wait;
    }
    if (s_bvalid && s_bready) {
      ++b_count;
      if (!b_pending) fail("a response taken that was not offered");
      b_pending = false; b_wait = -1;
      aw_wait = delay();
    }
    if (s_arvalid && s_arready) {
      ++ar_count; ++read_bursts;
      if (ar_open) fail("a second read address while a read burst is open");
      ar_open = true;
      ar_addr = s_araddr; ar_len = (int)s_arlen; r_beats = 0;
      ar_addrs.push_back(ar_addr); ar_lens.push_back(s_arlen);
      check_burst(ar_addr, s_arlen, s_arsize, s_arburst, "read");
      r_resp = (bursts == refuse_burst) ? 2u : 0u;
      ++bursts;
      r_wait = resp_delay();
    } else if (ar_open && r_wait > 0 && !s_rvalid) {
      --r_wait;
    }
    if (s_rvalid && s_rready) {
      ++r_count;
      ++ddr->reads;
      const bool last = (r_beats == ar_len);
      ++r_beats;
      if (last) { ar_open = false; ar_wait = delay(); }
      else r_wait = delay();
    }
  }
};

// ------------------------------------------------------- the GP0 master
struct Gp0Master {
  // One transaction at a time, run by `tick` until it completes.
  bool vary = false;
  uint32_t seed = 0x6009;
  uint32_t id = 1;
  long writes = 0, reads = 0;
  unsigned last_resp = 0;
  uint32_t last_rdata = 0;
  int bad = 0;
  std::function<void(const char *)> complain;

  void fail(const char *what) { ++bad; if (complain) complain(what); }

  void quiet(Vcadr_disk_harness *dut) {
    dut->gp0_awvalid = 0; dut->gp0_wvalid = 0; dut->gp0_bready = 0;
    dut->gp0_arvalid = 0; dut->gp0_rready = 0;
    dut->gp0_awaddr = 0; dut->gp0_awlen = 0; dut->gp0_awid = 0;
    dut->gp0_wdata = 0; dut->gp0_wstrb = 0; dut->gp0_wlast = 0;
    dut->gp0_araddr = 0; dut->gp0_arlen = 0; dut->gp0_arid = 0;
  }

  // A 32-bit write of one beat, with `strb` byte lanes.  `tick` runs one
  // cycle of the whole testbench and returns the pre-edge snapshot's
  // readies through the DUT's pins as they stood.
  void write(Vcadr_disk_harness *dut, std::function<void()> tick,
             uint32_t addr, uint32_t data, unsigned strb = 0xF) {
    const uint32_t my = id++ & 0xFFF;
    dut->gp0_awaddr = addr; dut->gp0_awlen = 0; dut->gp0_awid = my;
    dut->gp0_wdata = data; dut->gp0_wstrb = strb; dut->gp0_wlast = 1;
    int aw_hold = vary ? (int)(lcg(seed) % 3) : 0;
    int w_hold = vary ? (int)(lcg(seed) % 3) : 0;
    bool aw_done = false, w_done = false, b_done = false;
    int guard = 0;
    while (!b_done) {
      dut->gp0_awvalid = !aw_done && aw_hold == 0;
      dut->gp0_wvalid = !w_done && w_hold == 0;
      dut->gp0_bready = aw_done && w_done;
      // Sampled before the edge, as the slave does.
      dut->eval();
      const bool aw_hs = dut->gp0_awvalid && dut->gp0_awready;
      const bool w_hs = dut->gp0_wvalid && dut->gp0_wready;
      const bool b_hs = dut->gp0_bready && dut->gp0_bvalid;
      const unsigned resp = dut->gp0_bresp;
      const unsigned bid = dut->gp0_bid;
      tick();
      if (aw_hs) aw_done = true; else if (aw_hold > 0) --aw_hold;
      if (w_hs) w_done = true; else if (w_hold > 0) --w_hold;
      if (b_hs) {
        b_done = true;
        last_resp = resp;
        if (bid != my) fail("the write response carries the wrong ID");
      }
      if (++guard > 200) { fail("a register write did not complete"); break; }
    }
    quiet(dut);
    ++writes;
  }

  uint32_t read(Vcadr_disk_harness *dut, std::function<void()> tick, uint32_t addr) {
    const uint32_t my = id++ & 0xFFF;
    dut->gp0_araddr = addr; dut->gp0_arlen = 0; dut->gp0_arid = my;
    int ar_hold = vary ? (int)(lcg(seed) % 3) : 0;
    int r_hold = vary ? (int)(lcg(seed) % 3) : 0;
    bool ar_done = false, r_done = false;
    uint32_t got = 0;
    int guard = 0;
    while (!r_done) {
      dut->gp0_arvalid = !ar_done && ar_hold == 0;
      dut->gp0_rready = ar_done && r_hold == 0;
      dut->eval();
      const bool ar_hs = dut->gp0_arvalid && dut->gp0_arready;
      const bool r_hs = dut->gp0_rready && dut->gp0_rvalid;
      const uint32_t rd = dut->gp0_rdata;
      const unsigned resp = dut->gp0_rresp;
      const unsigned rid = dut->gp0_rid;
      const int rlast = dut->gp0_rlast;
      tick();
      if (ar_hs) ar_done = true; else if (ar_hold > 0) --ar_hold;
      if (ar_done && !r_hs && r_hold > 0) --r_hold;
      if (r_hs) {
        r_done = true;
        got = rd;
        last_resp = resp;
        if (rid != my) fail("the read data carries the wrong ID");
        if (!rlast) fail("a single-beat read without RLAST");
      }
      if (++guard > 200) { fail("a register read did not complete"); break; }
    }
    quiet(dut);
    ++reads;
    last_rdata = got;
    return got;
  }
};

}  // namespace pack_side

#endif
