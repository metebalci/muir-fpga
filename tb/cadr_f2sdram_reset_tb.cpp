// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The two resets of the DE25-Nano's memory port, with transactions in flight:
// `rtl/plumbing/cadr_f2sdram_port.sv` against a model of the FPGA-to-SDRAM
// bridge, the machine's side driven directly.
//
// **THE RULE.**  No transaction on the bridge is cut in half by the fabric's
// reset.  The bridge is reset only by the processor's reset, so a read it has
// taken it will answer and a write whose address it has taken it will wait
// for the beats of; a fabric that reset its side at once would leave the
// answer in the bridge's read channel, and the machine's next read would take
// it as its own --- every read one word late from then on.  So the fabric's
// reset goes through `cadr_f2sdram_gate.sv`'s drain: nothing new granted, the
// port reset once the share is idle, and the machine held until then.  Only
// the processor's own reset, which resets the bridge with the fabric's side,
// resets the port at once.
//
// **WHAT IS DRIVEN.**
//
//   THE FABRIC'S RESET UNDER A READ, for one tick and for ten: each read
//   after it must return its own word, the machine must be held while the
//   old answer is still owed, and nothing put to the bridge may be taken
//   back.
//
//   THE FABRIC'S RESET UNDER A WRITE, with its address taken and its
//   response not yet given: the response is taken, and the next read is
//   right.
//
//   THE FABRIC'S RESET UNDER THE PACK SIDE'S SIXTEEN-BEAT READ, the pack
//   side standing in as the master it is, which finishes its burst: all
//   sixteen beats reach it, and the port is not reset before the last.
//
//   THE PROCESSOR'S RESET UNDER A READ.  The bridge drops what it owed, as
//   a bridge in reset does.  The port must go into reset at once --- it
//   cannot wait for the share to go quiet, because the answer it would wait
//   for will never come --- the machine must NOT be held by it, and once
//   the processor is out of reset and the port open again a read must
//   return its own word.  This is the path `mutations/list.txt`'s
//   `gate-the-processors-reset-waits-for-quiet` takes away.
//
// THE BRIDGE'S PROTOCOL IS WATCHED THROUGHOUT: a valid that falls before its
// ready is counted, and the count must be zero.

#include "Vcadr_f2sdram_port.h"
#include "verilated.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <deque>

namespace {

Vcadr_f2sdram_port *d;
long now = 0;
int failures = 0;

void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::printf("FAIL t=%ld: ", now);
  std::vprintf(fmt, ap);
  std::printf("\n");
  va_end(ap);
  ++failures;
}

// The bridge: every read taken, answered in order after `LAT` ticks; every
// write taken, answered once its last beat is in.  A reset drops everything
// it owed.
const long LAT = 20;
struct Rd { uint32_t addr; int id; int len; int beat; long due; };
struct Wr { int id; };
std::deque<Rd> rq;
std::deque<Wr> aw;
int w_bursts = 0;
bool b_pending = false;
int b_id = 0;
long withdrawn = 0;
bool last_arvalid = false, last_awvalid = false, last_wvalid = false;
long reads_taken[8] = {};

uint64_t word64(uint32_t a) {
  return (static_cast<uint64_t>(0xB5000000u ^ (a + 4)) << 32) | (0xA5000000u ^ a);
}
uint32_t word32(uint32_t a) {
  const uint64_t w = word64(a & ~7u);
  return (a & 4) ? static_cast<uint32_t>(w >> 32) : static_cast<uint32_t>(w);
}

// The pack side, standing in as the master it is: one burst, taken whole.
bool p_want = false;
uint32_t p_addr = 0;
int p_beats = 0;

void drive_bridge() {
  if (d->h2f_reset) {
    rq.clear();
    aw.clear();
    w_bursts = 0;
    b_pending = false;
  }
  d->f2s_arready = !d->h2f_reset && rq.size() < 4;
  d->f2s_awready = !d->h2f_reset;
  d->f2s_wready = !d->h2f_reset;
  if (!rq.empty() && rq.front().due <= now) {
    const Rd &r = rq.front();
    d->f2s_rvalid = 1;
    d->f2s_rid = r.id;
    d->f2s_rdata = word64(r.addr + 8u * static_cast<uint32_t>(r.beat));
    d->f2s_rlast = r.beat == r.len;
    d->f2s_rresp = 0;
  } else {
    d->f2s_rvalid = 0;
    d->f2s_rlast = 0;
  }
  d->f2s_bvalid = b_pending;
  d->f2s_bid = b_id;
  d->f2s_bresp = 0;
  // The pack side's master: the burst's address until taken, then every beat.
  d->p_arvalid = p_want;
  d->p_araddr = p_addr;
  d->p_arlen = 15;
  d->p_arsize = 3;
  d->p_arburst = 1;
  d->p_rready = 1;
}

void step() {
  drive_bridge();
  d->eval();
  const bool ar = d->f2s_arvalid && d->f2s_arready;
  const bool r = d->f2s_rvalid && d->f2s_rready;
  const bool awh = d->f2s_awvalid && d->f2s_awready;
  const bool wh = d->f2s_wvalid && d->f2s_wready;
  const bool bh = d->f2s_bvalid && d->f2s_bready;
  const bool pa = d->p_arvalid && d->p_arready;
  const bool pr = d->p_rvalid && d->p_rready;
  if (!d->h2f_reset) {
    if (last_arvalid && !d->f2s_arvalid) ++withdrawn;
    if (last_awvalid && !d->f2s_awvalid) ++withdrawn;
    if (last_wvalid && !d->f2s_wvalid) ++withdrawn;
  }
  last_arvalid = d->f2s_arvalid && !ar && !d->h2f_reset;
  last_awvalid = d->f2s_awvalid && !awh && !d->h2f_reset;
  last_wvalid = d->f2s_wvalid && !wh && !d->h2f_reset;
  const uint32_t ara = d->f2s_araddr;
  const int arid = d->f2s_arid, arlen = d->f2s_arlen, awid = d->f2s_awid;
  const bool wlast = d->f2s_wlast;
  d->clk = 1;
  d->eval();
  d->clk = 0;
  d->eval();
  if (ar) {
    rq.push_back(Rd{ara, arid, arlen, 0, now + LAT});
    ++reads_taken[arid & 7];
  }
  if (r) {
    if (++rq.front().beat > rq.front().len) rq.pop_front();
  }
  if (awh) aw.push_back(Wr{awid});
  if (wh && wlast) ++w_bursts;
  if (bh) b_pending = false;
  if (!b_pending && !aw.empty() && w_bursts > 0) {
    b_pending = true;
    b_id = aw.front().id;
    aw.pop_front();
    --w_bursts;
  }
  if (pa) p_want = false;
  if (pr) ++p_beats;
  ++now;
}

bool owed_to_machine() {
  for (const Rd &r : rq)
    if (r.id == 0) return true;
  return false;
}

// Watch the machine's hold: it may rise only once nothing is owed.
bool held_before = true;
void step_watching() {
  step();
  if (d->may_start && held_before && owed_to_machine())
    fail("the machine was let go while the bridge still owed it an answer");
  held_before = !d->may_start;
}

void run(long n) {
  for (long i = 0; i < n; i++) step_watching();
}

// One machine access, the way `cadr_xbus_ddr.sv` makes it: a level held
// until done, dropped, and a tick between.
long access(bool write, uint32_t a, uint32_t wd) {
  d->mem_addr = a;
  d->mem_write = write;
  d->mem_wdata = wd;
  d->mem_req = 1;
  long n = 0;
  while (!d->mem_done && n < 5000) {
    step_watching();
    ++n;
  }
  const long got = d->mem_done ? static_cast<long>(d->mem_rdata) : -1;
  d->mem_req = 0;
  step_watching();
  step_watching();
  return got;
}

void read_is_own(const char *what, uint32_t a) {
  const long got = access(false, a, 0);
  if (got < 0) fail("%s: the read of %08x never finished", what, a);
  else if (static_cast<uint32_t>(got) != word32(a))
    fail("%s: the read of %08x returned %08lx, want %08x", what, a, got,
         word32(a));
}

// Wait until the machine may run again, the port reopened.
void wait_running(const char *what) {
  long n = 0;
  while ((!d->may_start || !d->live) && n < 5000) {
    step_watching();
    ++n;
  }
  if (!d->may_start || !d->live) fail("%s: the port did not reopen", what);
}

// A machine read put to the bridge and left outstanding.
void read_outstanding(uint32_t a) {
  const long before = reads_taken[0];
  d->mem_addr = a;
  d->mem_write = 0;
  d->mem_req = 1;
  long n = 0;
  while (reads_taken[0] == before && n < 200) {
    step_watching();
    ++n;
  }
  if (reads_taken[0] == before) fail("the machine's read never reached the bridge");
  d->mem_req = 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vcadr_f2sdram_port;
  d->h2f_reset = 0;
  d->gp_open = 1;
  d->gp_half = 0;
  d->warm_req_n = 1;
  d->mem_req = 0;
  d->p_awvalid = 0;
  d->p_wvalid = 0;
  d->p_bready = 1;
  d->d_arvalid = 0;
  d->d_rready = 1;
  d->rst = 1;
  run(10);
  d->rst = 0;
  wait_running("start");

  read_is_own("control", 0xB000'0100u);
  read_is_own("control", 0xB000'0204u);

  // --- the fabric's reset under a read, one tick and ten.
  for (int pulse : {1, 10}) {
    read_outstanding(0xB000'0100u + 8u * static_cast<uint32_t>(pulse));
    d->rst = 1;
    run(pulse);
    d->rst = 0;
    if (d->may_start) fail("fabric reset of %d: the machine was not held", pulse);
    wait_running("the fabric's reset under a read");
    read_is_own("after the fabric's reset under a read", 0xB000'0300u);
    read_is_own("after the fabric's reset under a read", 0xB000'0404u);
  }

  // --- the fabric's reset under a write whose address is taken.
  {
    d->mem_addr = 0xB000'0500u;
    d->mem_write = 1;
    d->mem_wdata = 0x1234'5678u;
    d->mem_req = 1;
    long n = 0;
    while (aw.empty() && n < 200) {
      step_watching();
      ++n;
    }
    d->mem_req = 0;
    d->rst = 1;
    run(3);
    d->rst = 0;
    wait_running("the fabric's reset under a write");
    if (!aw.empty() || b_pending || w_bursts != 0)
      fail("the fabric's reset under a write: the bridge was left owing a write");
    read_is_own("after the fabric's reset under a write", 0xB000'0600u);
  }

  // --- the fabric's reset under the pack side's sixteen-beat read.
  {
    p_beats = 0;
    p_addr = 0xB100'0000u;
    p_want = true;
    long n = 0;
    while (p_beats < 3 && n < 500) {
      step_watching();
      ++n;
    }
    d->rst = 1;
    bool cut = false;
    for (int i = 0; i < 40; i++) {
      step_watching();
      if (!d->live && p_beats < 16) cut = true;
    }
    d->rst = 0;
    wait_running("the fabric's reset under the pack side's burst");
    if (cut) fail("the pack side's burst: the port was reset before its last beat");
    if (p_beats != 16) fail("the pack side's burst: %d beats of 16 reached it", p_beats);
    read_is_own("after the fabric's reset under the pack side's burst", 0xB000'0700u);
  }

  // --- the processor's reset under a read.
  {
    read_outstanding(0xB000'0800u);
    d->h2f_reset = 1;
    long n = 0;
    while (d->live && n < 20) {
      step();
      ++n;
    }
    if (d->live)
      fail("the processor's reset did not reset the port at once: it is still "
           "live %ld ticks later, waiting for an answer the bridge dropped", n);
    run(50);
    if (!d->may_start) fail("the processor's reset held the running machine");
    d->h2f_reset = 0;
    wait_running("the processor's reset");
    read_is_own("after the processor's reset", 0xB000'0900u);
    read_is_own("after the processor's reset", 0xB000'0A04u);
  }

  if (withdrawn != 0)
    fail("%ld addresses or write beats withdrawn from the bridge before their "
         "handshake", withdrawn);

  d->final();
  delete d;
  if (failures) {
    std::printf("%d failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  std::printf("ok: the memory port's two resets, with transactions in flight: "
              "no answer lost or misdelivered, nothing withdrawn\n");
  return 0;
}
