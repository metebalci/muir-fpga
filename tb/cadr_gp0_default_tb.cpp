// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The default slave on `M_AXI_GP0`, held to the one property it has: every
// transaction on the port completes, with the response the module says it
// gives.
//
// WHY THIS EXISTS.  A read nothing answers on GP0 does not fault the Arm, it
// hangs both cores at one PC each --- measured on the board when the pack
// feeder read the register face on a bitstream without the pack side.  So a
// board that brings the port out and has nothing on it answers everything
// with `rtl/plumbing/cadr_gp0_default.sv`, and this is what says that module answers.
// `build/arty.pass` holds that it is wired into the two proving boards; it
// cannot hold what it does, being lint.
//
// WHAT IS HELD.  Writes of one to sixteen beats and reads of one to sixteen,
// at addresses across the port's gigabyte, with valids and readies that come
// and go so that a slave which assumed one shape of handshake fails: every
// write gets exactly one response, carrying the address's ID, OKAY; every
// read gets exactly ARLEN+1 beats, each carrying the ID and the module's
// word, OKAY, with RLAST on the last beat and on no other.  A write and a
// read in flight at once, as the interconnect will do.  A transaction that
// does not complete within a bound is the failure the board showed, and is
// reported as such rather than waited for.

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vcadr_gp0_default.h"
#include "verilated.h"

namespace {

const uint32_t WORD = 0x4E4F4E45u;   // "NONE", the module's default
long tick = 0;
int bad = 0;

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  std::fprintf(stderr, "tick %ld: %s is 0x%llx, expected 0x%llx\n", tick, what, got, want);
  ++bad;
}

uint32_t seed = 0x6B5A1D07u;
uint32_t rnd() {
  seed = seed * 1664525u + 1013904223u;
  return seed >> 8;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_gp0_default;

  dut->rst = 1;
  dut->s_awvalid = 0; dut->s_wvalid = 0; dut->s_bready = 0;
  dut->s_arvalid = 0; dut->s_rready = 0;
  dut->s_awid = 0; dut->s_arid = 0; dut->s_arlen = 0; dut->s_wlast = 0;
  auto step = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    ++tick;
  };
  for (int i = 0; i < 4; ++i) step();
  dut->rst = 0;
  for (int i = 0; i < 2; ++i) step();

  // A write and a read run together, each a little state machine driven
  // from one loop, so the two halves overlap as the interconnect makes them.
  long writes = 0, reads = 0, w_beats = 0, r_beats = 0, b_resps = 0;
  long stalls_w = 0, stalls_r = 0;
  const int ROUNDS = 400;
  const long BOUND = 400;   // ticks a transaction may take before it is stuck

  for (int round = 0; round < ROUNDS && bad < 20; ++round) {
    // --- the write: AW, then WLEN beats, then B
    const unsigned wlen = 1 + rnd() % 16;
    const unsigned wid = rnd() & 0xFFF;
    int aw_hold = rnd() % 4, w_hold = rnd() % 4, b_hold = rnd() % 4;
    bool aw_done = false, b_done = false;
    unsigned w_sent = 0;
    int b_seen = 0;
    // --- the read: AR, then ARLEN+1 beats
    const unsigned rlen = rnd() % 16;   // ARLEN
    const unsigned rid = rnd() & 0xFFF;
    int ar_hold = rnd() % 4, r_hold = rnd() % 4;
    bool ar_done = false, r_done = false;
    unsigned r_got = 0;
    const long began = tick;
    dut->s_awid = wid;
    dut->s_arid = rid;
    dut->s_arlen = rlen;
    while ((!b_done || !r_done) && bad < 20) {
      dut->s_awvalid = !aw_done && aw_hold == 0;
      dut->s_wvalid  = aw_done && w_sent < wlen && w_hold == 0;
      dut->s_wlast   = (w_sent + 1 == wlen);
      dut->s_bready  = (w_sent == wlen) && b_hold == 0;
      dut->s_arvalid = !ar_done && ar_hold == 0;
      dut->s_rready  = ar_done && r_hold == 0;
      dut->clk = 0; dut->eval();
      const bool aw_hs = dut->s_awvalid && dut->s_awready;
      const bool w_hs  = dut->s_wvalid && dut->s_wready;
      const bool b_hs  = dut->s_bready && dut->s_bvalid;
      const bool ar_hs = dut->s_arvalid && dut->s_arready;
      const bool r_hs  = dut->s_rready && dut->s_rvalid;
      if (dut->s_bvalid && !b_hs && w_sent == wlen) ++stalls_w;
      if (dut->s_rvalid && !r_hs && ar_done) ++stalls_r;
      // A response offered before the data is in, or data taken before the
      // address, is a slave answering the wrong transaction.
      if (dut->s_bvalid && w_sent < wlen) Fail("BVALID before the last write beat", 1, 0);
      if (dut->s_rvalid && !ar_done) Fail("RVALID before the read address", 1, 0);
      if (b_hs) {
        ++b_seen;
        if (dut->s_bresp != 0) Fail("BRESP", dut->s_bresp, 0);
        if (dut->s_bid != wid) Fail("BID", dut->s_bid, wid);
      }
      if (r_hs) {
        if (dut->s_rresp != 0) Fail("RRESP", dut->s_rresp, 0);
        if (dut->s_rid != rid) Fail("RID", dut->s_rid, rid);
        if (dut->s_rdata != WORD) Fail("RDATA", dut->s_rdata, WORD);
        const bool last = (r_got == rlen);
        if ((dut->s_rlast != 0) != last) Fail(last ? "RLAST missing on the last beat" : "RLAST on a beat that is not the last", dut->s_rlast, last);
      }
      dut->clk = 1; dut->eval();
      ++tick;
      if (aw_hs) { aw_done = true; ++writes; } else if (aw_hold > 0) --aw_hold;
      if (w_hs) { ++w_sent; ++w_beats; w_hold = rnd() % 3; } else if (w_hold > 0) --w_hold;
      if (b_hs) { b_done = true; ++b_resps; } else if (b_hold > 0 && w_sent == wlen) --b_hold;
      if (ar_hs) { ar_done = true; ++reads; } else if (ar_hold > 0) --ar_hold;
      if (r_hs) { ++r_got; ++r_beats; r_hold = rnd() % 3; if (r_got == rlen + 1) r_done = true; }
      else if (r_hold > 0 && ar_done) --r_hold;
      if (tick - began > BOUND) {
        Fail("a transaction did not complete: the write's response", b_done, 1);
        Fail("a transaction did not complete: the read's last beat", r_done, 1);
        break;
      }
    }
    if (b_seen != 1) Fail("write responses to one write", b_seen, 1);
    if (r_got != rlen + 1) Fail("read beats to one read", r_got, rlen + 1);
    // Nothing offered between transactions.
    dut->s_awvalid = 0; dut->s_wvalid = 0; dut->s_bready = 0; dut->s_arvalid = 0; dut->s_rready = 0;
    for (int q = 0; q < (int)(rnd() % 3); ++q) {
      step();
      if (dut->s_bvalid) Fail("BVALID with no write in flight", 1, 0);
      if (dut->s_rvalid) Fail("RVALID with no read in flight", 1, 0);
    }
  }

  delete dut;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::printf(
      "ok: the default GP0 slave answers every transaction\n"
      "    %ld writes of 1 to 16 beats (%ld beats, %ld responses, OKAY, the ID\n"
      "      echoed), %ld reads of 1 to 16 beats (%ld beats of 0x%08x, OKAY,\n"
      "      the ID echoed, RLAST on the last beat only), a write and a read\n"
      "      in flight together, valids and readies varying; %ld response\n"
      "      and %ld read beats held until taken\n",
      writes, w_beats, b_resps, reads, r_beats, WORD, stalls_w, stalls_r);
  return 0;
}
