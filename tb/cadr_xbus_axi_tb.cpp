// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The DDR bridge and the AXI adapter together, when the NXM timer ends a bus
// cycle the memory has not answered yet.
//
// The bus interface gives a slave about 4.25 us and then ends the cycle
// itself: it lifts -XBUS.RQ, and the machine sees a nonexistent memory.  The
// AXI transaction already issued cannot be called back --- AXI has no abort
// --- so its answer still comes, late, into a bridge whose cycle is over.
// The adapter used to take that late answer as the answer to whatever was
// asking by then: the NEXT cycle was acknowledged at once with the old read's
// word, and a write in that position was acknowledged and never issued.
// Neither shows at the machine as anything but a wrong word, which is the
// worst way for a memory to fail.
//
// What this holds, with a slave whose latency the test sets per cycle:
//
//   - a cycle the timer ends is never acknowledged;
//   - the late answer is still taken from the slave (`rready` or `bready` up
//     when it comes), because a slave left holding a response is a hung port;
//   - the next cycle issues its OWN transaction, exactly one, at its own
//     address, and is answered with its own word or only after its own write
//     response;
//   - AXI's own rules at every tick: a valid stays up, with its payload
//     unmoved, until its ready, even when the cycle that asked has gone.
//
// Main memory is at 0x1800_0000 on the Zynq boards (`cadr_ddr_map.sv`), and
// this check builds that map.

#include <cstdio>
#include <cstdlib>
#include <map>

#include "Vcadr_xbus_axi_harness.h"
#include "verilated.h"

namespace {

Vcadr_xbus_axi_harness *t;
long tick = 0;
int bad = 0;

const unsigned MAIN_BASE = 0x18000000u;
const int NXM = 425;  // ticks the bus interface gives a slave, near enough

// The slave.  Latencies are set by the test before each cycle.
int r_lat = 5, b_lat = 5;
long r_due = -1, b_due = -1, ar_open = 0, aw_open = 0;
unsigned r_addr = 0, aw_addr = 0, w_data = 0;
bool aw_got = false, w_got = false;
std::map<unsigned, unsigned> mem;
long ar_n = 0, aw_n = 0, w_n = 0, r_n = 0, b_n = 0;
unsigned last_araddr = 0, last_awaddr = 0, last_wdata = 0;

// Last tick's valid and payload, for AXI's stability rule.
int p_arv = 0, p_awv = 0, p_wv = 0, p_arr = 0, p_awr = 0, p_wr = 0;
unsigned p_ara = 0, p_awa = 0, p_wd = 0;

void Fail(const char *what, unsigned got, unsigned want) {
  std::fprintf(stderr, "tick %ld: %s is 0x%08x, expected 0x%08x\n", tick, what, got, want);
  ++bad;
}

unsigned Answer(unsigned addr) {
  auto it = mem.find(addr);
  return it == mem.end() ? (0xD0000000u | addr) : it->second;
}

void Step() {
  t->clk = 0;
  t->arready = (r_due < 0) && tick >= ar_open;
  t->awready = !aw_got && tick >= aw_open;
  t->wready = !w_got;
  t->rvalid = (r_due >= 0 && tick >= r_due);
  t->rdata_i = Answer(r_addr);
  t->bvalid = (b_due >= 0 && tick >= b_due);
  t->eval();

  if (p_arv && !p_arr) {
    if (!t->arvalid) Fail("arvalid dropped before arready", 0, 1);
    else if (t->araddr != p_ara) Fail("araddr moved while arvalid", t->araddr, p_ara);
  }
  if (p_awv && !p_awr) {
    if (!t->awvalid) Fail("awvalid dropped before awready", 0, 1);
    else if (t->awaddr != p_awa) Fail("awaddr moved while awvalid", t->awaddr, p_awa);
  }
  if (p_wv && !p_wr) {
    if (!t->wvalid) Fail("wvalid dropped before wready", 0, 1);
    else if (t->wdata_o != p_wd) Fail("wdata moved while wvalid", t->wdata_o, p_wd);
  }
  p_arv = t->arvalid; p_arr = t->arready; p_ara = t->araddr;
  p_awv = t->awvalid; p_awr = t->awready; p_awa = t->awaddr;
  p_wv = t->wvalid; p_wr = t->wready; p_wd = t->wdata_o;

  const bool ar = t->arvalid && t->arready, r = t->rvalid && t->rready;
  const bool aw = t->awvalid && t->awready, w = t->wvalid && t->wready;
  const bool b = t->bvalid && t->bready;
  const unsigned ara = t->araddr, awa = t->awaddr, wd = t->wdata_o;

  t->clk = 1;
  t->eval();
  ++tick;

  if (ar) { ++ar_n; last_araddr = ara; r_addr = ara; r_due = tick + r_lat; }
  if (r) { ++r_n; r_due = -1; }
  if (aw) { ++aw_n; last_awaddr = awa; aw_addr = awa; aw_got = true; }
  if (w) { ++w_n; last_wdata = wd; w_data = wd; w_got = true; }
  if (aw_got && w_got && b_due < 0) {
    mem[aw_addr] = w_data;
    b_due = tick + b_lat;
  }
  if (b) { ++b_n; b_due = -1; aw_got = w_got = false; }
}

void Idle(int n) { for (int i = 0; i < n; ++i) Step(); }

// One bus cycle: the request up until the acknowledgment or the NXM bound,
// then down for `gap` ticks.  Whether it was answered, and the word.
bool Cycle(bool write, unsigned phys, unsigned wd, unsigned *word, int gap) {
  t->dev_rq = 1;
  t->dev_write = write;
  t->phys = phys;
  t->wdata = wd;
  bool acked = false;
  for (int i = 0; i < NXM; ++i) {
    t->eval();
    if (t->dev_ack) { acked = true; break; }
    Step();
  }
  // The bridge latches the word on the acknowledgment's tick, and the cpu
  // takes it at -LOADMD, which is later still.
  Step();
  if (acked && word) *word = t->rdata;
  t->dev_rq = 0;
  Idle(gap);
  return acked;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vcadr_xbus_axi_harness;
  t->dev_rq = 0; t->dev_write = 0; t->phys = 0; t->wdata = 0;
  t->rst = 1;
  Idle(4);
  t->rst = 0;
  Idle(2);

  long cases = 0;
  unsigned word = 0;

  for (int gap : {1, 2, 5}) {
    // --- A read the timer ends, then a read.
    {
      r_lat = 600;
      const long ar0 = ar_n;
      if (Cycle(false, 100, 0, &word, gap)) Fail("an acknowledgment for a read the timer ended", 1, 0);
      r_lat = 5;
      const long ar1 = ar_n;
      if (!Cycle(false, 200, 0, &word, gap)) Fail("an acknowledgment for the read after it", 0, 1);
      if (word != Answer(MAIN_BASE + 4 * 200)) Fail("the word the read after it was given", word, Answer(MAIN_BASE + 4 * 200));
      if (ar_n - ar1 != 1) Fail("AR handshakes for the read after it", ar_n - ar1, 1);
      if (last_araddr != MAIN_BASE + 4 * 200) Fail("its read address", last_araddr, MAIN_BASE + 4 * 200);
      if (ar_n - ar0 != 2) Fail("AR handshakes for the two reads", ar_n - ar0, 2);
      ++cases;
    }
    Idle(700);
    if (r_due >= 0) Fail("a read response the adapter never took", 1, 0);

    // --- A read the timer ends, then a write, then a read of it back.
    {
      r_lat = 600;
      if (Cycle(false, 101, 0, &word, gap)) Fail("an acknowledgment for a read the timer ended", 1, 0);
      r_lat = 5;
      const long aw0 = aw_n, w0 = w_n, b0 = b_n;
      const unsigned v = 0xABC00000u | static_cast<unsigned>(gap);
      if (!Cycle(true, 300 + gap, v, nullptr, gap)) Fail("an acknowledgment for the write after it", 0, 1);
      if (aw_n - aw0 != 1) Fail("AW handshakes for the write after it", aw_n - aw0, 1);
      if (w_n - w0 != 1) Fail("W handshakes for the write after it", w_n - w0, 1);
      if (b_n - b0 != 1) Fail("B handshakes before the write was acknowledged", b_n - b0, 1);
      if (last_awaddr != MAIN_BASE + 4 * (300 + gap)) Fail("its write address", last_awaddr, MAIN_BASE + 4 * (300 + gap));
      if (last_wdata != v) Fail("its write data", last_wdata, v);
      if (!Cycle(false, 300 + gap, 0, &word, gap)) Fail("an acknowledgment reading it back", 0, 1);
      if (word != v) Fail("the word read back", word, v);
      ++cases;
    }
    Idle(700);

    // --- A write the timer ends, then a read.
    {
      b_lat = 600;
      if (Cycle(true, 400, 0x55AA55AAu, nullptr, gap)) Fail("an acknowledgment for a write the timer ended", 1, 0);
      b_lat = 5;
      const long ar0 = ar_n;
      if (!Cycle(false, 500, 0, &word, gap)) Fail("an acknowledgment for the read after it", 0, 1);
      if (word != Answer(MAIN_BASE + 4 * 500)) Fail("the word the read after a late write was given", word, Answer(MAIN_BASE + 4 * 500));
      if (ar_n - ar0 != 1) Fail("AR handshakes for the read after a late write", ar_n - ar0, 1);
      ++cases;
    }
    Idle(700);
    if (b_due >= 0) Fail("a write response the adapter never took", 1, 0);

    // --- The slave holds its address channel shut past the timer: the
    // valid must stay up, and the read after it must still get its own.
    {
      ar_open = tick + 600;
      r_lat = 5;
      if (Cycle(false, 600, 0, &word, gap)) Fail("an acknowledgment for a read whose AR was never taken", 1, 0);
      const long ar0 = ar_n;
      if (!Cycle(false, 700, 0, &word, gap)) Fail("an acknowledgment for the read after it", 0, 1);
      if (word != Answer(MAIN_BASE + 4 * 700)) Fail("the word after a held address channel", word, Answer(MAIN_BASE + 4 * 700));
      if (last_araddr != MAIN_BASE + 4 * 700) Fail("its read address", last_araddr, MAIN_BASE + 4 * 700);
      if (ar_n - ar0 < 1 || ar_n - ar0 > 2) Fail("AR handshakes across the held channel", ar_n - ar0, 2);
      ++cases;
    }
    Idle(700);
    {
      aw_open = tick + 600;
      if (Cycle(true, 800, 0x12345678u, nullptr, gap)) Fail("an acknowledgment for a write whose AW was never taken", 1, 0);
      const long aw0 = aw_n;
      const unsigned v = 0x0F0F0000u | static_cast<unsigned>(gap);
      if (!Cycle(true, 900, v, nullptr, gap)) Fail("an acknowledgment for the write after it", 0, 1);
      if (!Cycle(false, 900, 0, &word, gap)) Fail("an acknowledgment reading it back", 0, 1);
      if (word != v) Fail("the word read back after a held address channel", word, v);
      if (aw_n - aw0 < 1 || aw_n - aw0 > 2) Fail("AW handshakes across the held channel", aw_n - aw0, 2);
      ++cases;
    }
    Idle(700);
  }

  // --- The late answer landing on every tick around the one the timer ends
  // the cycle, and the next cycle starting one tick later: the tick the
  // request falls and the answer comes together is the one a check of the
  // live request alone gets wrong.
  for (int lat = NXM - 12; lat < NXM + 12; ++lat) {
    for (int write = 0; write < 2; ++write) {
      r_lat = b_lat = lat;
      const unsigned first = 2000 + static_cast<unsigned>(lat) * 2 + write;
      const bool acked = Cycle(write, first, 0x3C3C0000u | first, write ? nullptr : &word, 1);
      r_lat = b_lat = 3;
      const long ar0 = ar_n;
      if (!Cycle(false, 3000, 0, &word, 1)) Fail("an acknowledgment for the read after an edge", 0, 1);
      if (word != Answer(MAIN_BASE + 4 * 3000)) Fail("the word the read after an edge was given", word, Answer(MAIN_BASE + 4 * 3000));
      if (ar_n - ar0 != 1) Fail("AR handshakes for the read after an edge", ar_n - ar0, 1);
      (void)acked;
      Idle(20);
      ++cases;
    }
  }

  // --- And the ordinary path, which none of this may have slowed or moved:
  // a fast slave answers every cycle, one transaction each.
  {
    r_lat = b_lat = 3;
    const long ar0 = ar_n, aw0 = aw_n;
    for (unsigned k = 0; k < 50; ++k) {
      if (!Cycle(true, 1000 + k, 0x7700 + k, nullptr, 1)) Fail("an ordinary write", 0, 1);
      if (!Cycle(false, 1000 + k, 0, &word, 1)) Fail("an ordinary read", 0, 1);
      if (word != 0x7700 + k) Fail("an ordinary read back", word, 0x7700 + k);
    }
    if (ar_n - ar0 != 50) Fail("AR handshakes over fifty ordinary reads", ar_n - ar0, 50);
    if (aw_n - aw0 != 50) Fail("AW handshakes over fifty ordinary writes", aw_n - aw0, 50);
    ++cases;
  }

  t->final();
  delete t;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems over %ld cases\n", bad, cases);
    return 1;
  }
  std::printf("ok: %ld cases: a cycle the NXM timer ends is never answered, its late "
              "response is drained, and the next cycle gets its own transaction\n", cases);
  return 0;
}
