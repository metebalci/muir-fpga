// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The AXI adapter, against the protocol and against the property.
//
// There is no muir reference: nothing in MIT's drawings is an AXI master. So
// what it is held to is (a) AXI's own rules, checked every tick, and (b) that a
// read returns the word a write put at that address, with the address and data
// carried through unchanged.
//
// The slave here varies its handshake deliberately --- ready before valid,
// valid before ready, both in the same tick, and delays on each channel
// independently --- because a master that only ever met one of those would pass
// a test that only ever offered one.
//
// Two things this has to do that are easy to leave out, and both were left out
// first. It counts the handshakes per transaction and requires exactly one on
// each channel: a master that held `awvalid` up after `awready` issues a second
// write, and a slave that only records the address cannot tell. And it holds
// `mem_req` up for a tick or two after `mem_done`, as the bridge does, because
// a stimulus that drops it the instant the answer appears never gives the
// master the chance to re-issue.

#include <cstdio>
#include <cstdlib>
#include <map>

#include "Vcadr_axi_master.h"
#include "verilated.h"

namespace {

// A small deterministic generator, so a failure is reproducible.
unsigned lcg(unsigned &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

int bad = 0;
long tick = 0;

int Fail(const char *what, unsigned got, unsigned want) {
  std::fprintf(stderr, "tick %ld: %s is 0x%08x, expected 0x%08x\n", tick, what,
               got, want);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_axi_master;

  dut->clk = 0;
  dut->rst = 1;
  dut->mem_req = 0;
  dut->mem_write = 0;
  dut->mem_addr = 0;
  dut->mem_wdata = 0;
  dut->m_axi_awready = 0;
  dut->m_axi_wready = 0;
  dut->m_axi_bvalid = 0;
  dut->m_axi_bresp = 0;
  dut->m_axi_arready = 0;
  dut->m_axi_rvalid = 0;
  dut->m_axi_rdata = 0;
  dut->m_axi_rresp = 0;
  dut->m_axi_rlast = 0;
  dut->eval();

  std::map<unsigned, unsigned> slave;   // what the slave holds
  std::map<unsigned, unsigned> shadow;  // what it should hold, from the stimulus

  unsigned seed = 12345;

  // The transaction in flight, from the stimulus alone.
  bool busy = false, want_write = false;
  int hold = 0;
  long aw_count = 0, w_count = 0, ar_count = 0;
  unsigned want_addr = 0, want_data = 0;
  long ops = 0, reads_checked = 0, writes = 0;
  long saw_aw_first = 0, saw_w_first = 0, saw_together = 0;

  // Slave state.
  int aw_delay = 0, w_delay = 0, ar_delay = 0, b_delay = 0, r_delay = 0;
  bool aw_taken = false, w_taken = false;
  unsigned aw_addr = 0, w_data = 0, ar_addr = 0;
  int b_wait = -1, r_wait = -1;

  // For the protocol checks: last tick's valid and payload.
  int p_awvalid = 0, p_wvalid = 0, p_arvalid = 0;
  unsigned p_awaddr = 0, p_wdata = 0, p_araddr = 0;
  int p_awready = 0, p_wready = 0, p_arready = 0;

  const long TICKS = 200000;
  for (tick = 0; tick < TICKS && bad < 20; ++tick) {
    dut->rst = (tick < 4);

    // Start a new operation when the adapter is free.
    if (hold > 0) --hold;
    if (!busy && hold == 0 && dut->mem_req) dut->mem_req = 0;
    if (!busy && hold == 0 && tick >= 8 && !dut->mem_done) {
      unsigned v = lcg(seed);
      want_write = (v & 1) != 0;
      // Sixteen addresses, so reads land on words earlier writes touched.
      want_addr = 0x1800'0000u + ((v >> 4) % 16u) * 4u;
      want_data = lcg(seed);
      dut->mem_req = 1;
      dut->mem_write = want_write;
      dut->mem_addr = want_addr;
      dut->mem_wdata = want_data;
      busy = true;
      aw_taken = w_taken = false;
      // A fresh spread of handshake delays for every transaction.
      aw_delay = static_cast<int>(lcg(seed) % 4);
      w_delay = static_cast<int>(lcg(seed) % 4);
      ar_delay = static_cast<int>(lcg(seed) % 4);
      b_delay = static_cast<int>(lcg(seed) % 4);
      r_delay = static_cast<int>(lcg(seed) % 4);
      b_wait = r_wait = -1;
      aw_count = w_count = ar_count = 0;
      ++ops;
    }

    // The slave's readies for this tick.
    dut->m_axi_awready = (aw_delay <= 0);
    dut->m_axi_wready = (w_delay <= 0);
    dut->m_axi_arready = (ar_delay <= 0);
    dut->m_axi_bvalid = (b_wait == 0);
    dut->m_axi_rvalid = (r_wait == 0);
    dut->m_axi_bresp = 0;
    dut->m_axi_rresp = 0;
    dut->m_axi_rlast = 1;
    if (r_wait == 0) {
      auto it = slave.find(ar_addr);
      dut->m_axi_rdata = (it == slave.end()) ? 0xCAFEBABEu : it->second;
    }
    dut->eval();

    // --- AXI protocol, checked before the edge that would change anything.
    if (p_awvalid && !p_awready) {
      if (!dut->m_axi_awvalid)
        bad += Fail("awvalid dropped before awready", 0, 1);
      else if (dut->m_axi_awaddr != p_awaddr)
        bad += Fail("awaddr moved while awvalid", dut->m_axi_awaddr, p_awaddr);
    }
    if (p_wvalid && !p_wready) {
      if (!dut->m_axi_wvalid) bad += Fail("wvalid dropped before wready", 0, 1);
      else if (dut->m_axi_wdata != p_wdata)
        bad += Fail("wdata moved while wvalid", dut->m_axi_wdata, p_wdata);
    }
    if (p_arvalid && !p_arready) {
      if (!dut->m_axi_arvalid)
        bad += Fail("arvalid dropped before arready", 0, 1);
      else if (dut->m_axi_araddr != p_araddr)
        bad += Fail("araddr moved while arvalid", dut->m_axi_araddr, p_araddr);
    }
    if (dut->m_axi_awvalid && dut->m_axi_arvalid)
      bad += Fail("a read and a write outstanding at once", 1, 0);

    // --- The handshakes the slave takes this tick.
    const bool aw_go = dut->m_axi_awvalid && dut->m_axi_awready;
    const bool w_go = dut->m_axi_wvalid && dut->m_axi_wready;
    const bool ar_go = dut->m_axi_arvalid && dut->m_axi_arready;

    if (aw_go && w_go) ++saw_together;
    else if (aw_go) ++saw_aw_first;
    else if (w_go) ++saw_w_first;

    if (aw_go) {
      if (dut->m_axi_awaddr != want_addr)
        bad += Fail("awaddr", dut->m_axi_awaddr, want_addr);
      if (dut->m_axi_awlen != 0) bad += Fail("awlen", dut->m_axi_awlen, 0);
      if (dut->m_axi_awsize != 2) bad += Fail("awsize", dut->m_axi_awsize, 2);
      aw_addr = dut->m_axi_awaddr;
      aw_taken = true;
      if (++aw_count > 1)
        bad += Fail("AW handshakes in one transaction", aw_count, 1);
    }
    if (w_go) {
      if (dut->m_axi_wdata != want_data)
        bad += Fail("wdata", dut->m_axi_wdata, want_data);
      if (dut->m_axi_wstrb != 0xF) bad += Fail("wstrb", dut->m_axi_wstrb, 0xF);
      if (!dut->m_axi_wlast) bad += Fail("wlast", 0, 1);
      w_data = dut->m_axi_wdata;
      w_taken = true;
      if (++w_count > 1)
        bad += Fail("W handshakes in one transaction", w_count, 1);
    }
    if (aw_taken && w_taken && b_wait < 0) {
      slave[aw_addr] = w_data;
      b_wait = b_delay;
      aw_taken = w_taken = false;
    }
    if (ar_go) {
      if (dut->m_axi_araddr != want_addr)
        bad += Fail("araddr", dut->m_axi_araddr, want_addr);
      if (dut->m_axi_arlen != 0) bad += Fail("arlen", dut->m_axi_arlen, 0);
      ar_addr = dut->m_axi_araddr;
      r_wait = r_delay;
      if (++ar_count > 1)
        bad += Fail("AR handshakes in one transaction", ar_count, 1);
    }

    // Countdowns, and the responses the master has taken.
    if (aw_delay > 0) --aw_delay;
    if (w_delay > 0) --w_delay;
    if (ar_delay > 0) --ar_delay;
    if (b_wait == 0 && dut->m_axi_bready) b_wait = -1;
    else if (b_wait > 0) --b_wait;
    if (r_wait == 0 && dut->m_axi_rready) r_wait = -1;
    else if (r_wait > 0) --r_wait;

    p_awvalid = dut->m_axi_awvalid;
    p_wvalid = dut->m_axi_wvalid;
    p_arvalid = dut->m_axi_arvalid;
    p_awaddr = dut->m_axi_awaddr;
    p_wdata = dut->m_axi_wdata;
    p_araddr = dut->m_axi_araddr;
    p_awready = dut->m_axi_awready;
    p_wready = dut->m_axi_wready;
    p_arready = dut->m_axi_arready;

    // --- The answer.
    if (busy && dut->mem_done) {
      if (dut->mem_error) bad += Fail("mem_error", 1, 0);
      if (want_write) {
        shadow[want_addr] = want_data;
        ++writes;
      } else {
        auto it = shadow.find(want_addr);
        if (it != shadow.end()) {
          if (dut->mem_rdata != it->second)
            bad += Fail("mem_rdata", dut->mem_rdata, it->second);
          else
            ++reads_checked;
        }
      }
      // The bridge holds its request up until it has taken the word, so this
      // does too --- a request dropped the instant the answer appears never
      // lets the master re-issue, and never catches one that would.
      hold = 1 + static_cast<int>(lcg(seed) % 3);
      busy = false;
    }

    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
  }

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems over %ld ticks\n", bad, tick);
    return 1;
  }

  int thin = 0;
  const struct {
    const char *what;
    long n;
  } want[] = {{"transactions", ops},
              {"writes", writes},
              {"reads checked against an earlier write", reads_checked},
              {"writes where AW went first", saw_aw_first},
              {"writes where W went first", saw_w_first},
              {"writes where AW and W went together", saw_together}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the run has no %s\n", w.what);
      ++thin;
    }
  if (thin) return 1;

  std::printf(
      "ok: %ld AXI transactions, protocol held at every tick\n"
      "    %ld writes, %ld reads matched what was written; "
      "AW first %ld, W first %ld, together %ld\n",
      ops, writes, reads_checked, saw_aw_first, saw_w_first, saw_together);
  return 0;
}
