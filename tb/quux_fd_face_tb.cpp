// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's revision 9 as Linux reaches it: `rtl/plumbing/quux_fd_face.sv` with
// the machine's register page behind it (`tb/quux_fd_face_harness.sv`).  The
// face is driven over AXI in the order `docs/file-device.md` gives Linux's
// server, and the page as the processor drives it, with `-XBUS.RQ` at the
// tick this program names, so that each rule of the host's side is held
// against what the processor then reads, and each ordering by the tick.
//
// There is no muir reference for the host's side: muir's device runs its
// commands itself.  The machine's side is muir's and is held on the whole
// machine by `build/quux_files.quux.k4.pass` and `build/quux_rtc.quux.k4.pass`;
// what is here is the part of the contract that is this project's, each
// rule with the case just outside it:
//
//   - the page's map: IDENT, every register at its offset, a word nothing
//     names reading 0, a write of fewer than four bytes going nowhere
//   - the register page leaving block-disk's words, 200-203, and the video
//     controller's, 210, to their own slaves, and answering the reserved
//     words beside them (contract Q13)
//   - MEM_WORDS, from the machine's main memory, and a ring reaching exactly
//     to its end accepted where one a word past it is refused
//   - the clock: the seconds with a staged fraction, the carry into the next
//     second at its tick and not a tick either side, the hold at 2^32 - 1,
//     the stage forgotten, a fraction of a second or more ignored, and the
//     machine's write of word 103 going nowhere
//   - the command producer shown only once the write buffer has drained
//   - the claim: taken only in the current epoch, holding quiet low across
//     a disable, let go in any
//   - a completion refused for a stale epoch, for moving 170 by nothing, for
//     passing the commands shown, and for overfilling the response ring;
//     accepted, the cache invalidated and the interrupt up in the tick after
//     it lands, and the index and the handles open in the tick after that
//   - the handles open staged until the completion, zeroed by a disable, and
//     a stale epoch's count never landing in the next
//   - the epoch counting the disables, by the machine and by its reset, and
//     not a reset of a device already disabled

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "Vquux_fd_face_harness.h"
#include "verilated.h"

namespace {

Vquux_fd_face_harness *d;
long ticks = 0;
int bad = 0;
long checks = 0;

void Fail(const std::string &what, uint64_t got, uint64_t want) {
  ++bad;
  std::fprintf(stderr, "FAIL: %s: %#" PRIx64 ", want %#" PRIx64 " (tick %ld)\n", what.c_str(), got,
               want, ticks);
}

void Want(const std::string &what, uint64_t got, uint64_t want) {
  ++checks;
  if (got != want) Fail(what, got, want);
}

// What the file device held over each tick, before the edge that ends it,
// with the host's write that edge takes.
struct TickSample {
  bool invalidate, irq, host_we;
  unsigned widx;
  unsigned cons, handles;
};
std::vector<TickSample> log_ticks;

void Step() {
  d->clk = 0;
  d->eval();
  log_ticks.push_back(TickSample{d->fd_invalidate != 0, d->dbg_irq != 0, d->dbg_host_we != 0,
                                 d->dbg_host_widx, d->dbg_cons, d->dbg_handles});
  d->clk = 1;
  d->eval();
  ++ticks;
}

void Idle(int n) {
  for (int k = 0; k < n; ++k) Step();
}

// One AXI3 write of a word, with its strobes; the response returned.
int Write(uint32_t addr, uint32_t data, unsigned strb = 0xF) {
  d->m_awaddr = addr & 0xFFFu;
  d->m_awlen = 0;
  d->m_awid = 5;
  d->m_awvalid = 1;
  d->m_wdata = data;
  d->m_wstrb = strb;
  d->m_wlast = 1;
  d->m_wvalid = 1;
  d->m_bready = 1;
  bool aw = false, w = false;
  for (int k = 0; k < 64; ++k) {
    d->clk = 0;
    d->eval();
    const bool aw_now = d->m_awvalid && d->m_awready;
    const bool w_now = d->m_wvalid && d->m_wready;
    const bool b_now = d->m_bvalid && d->m_bready;
    const int resp = d->m_bresp;
    log_ticks.push_back(TickSample{d->fd_invalidate != 0, d->dbg_irq != 0, d->dbg_host_we != 0,
                                   d->dbg_host_widx, d->dbg_cons, d->dbg_handles});
    d->clk = 1;
    d->eval();
    ++ticks;
    if (aw_now) {
      aw = true;
      d->m_awvalid = 0;
    }
    if (w_now) {
      w = true;
      d->m_wvalid = 0;
    }
    if (b_now && aw && w) {
      d->m_bready = 0;
      return resp;
    }
  }
  Fail("a write never answered at " + std::to_string(addr), 0, 1);
  return -1;
}

uint32_t Read(uint32_t addr) {
  d->m_araddr = addr & 0xFFFu;
  d->m_arlen = 0;
  d->m_arid = 3;
  d->m_arvalid = 1;
  d->m_rready = 1;
  for (int k = 0; k < 64; ++k) {
    d->clk = 0;
    d->eval();
    const bool ar_now = d->m_arvalid && d->m_arready;
    const bool r_now = d->m_rvalid && d->m_rready;
    const uint32_t data = d->m_rdata;
    const int resp = d->m_rresp;
    log_ticks.push_back(TickSample{d->fd_invalidate != 0, d->dbg_irq != 0, d->dbg_host_we != 0,
                                   d->dbg_host_widx, d->dbg_cons, d->dbg_handles});
    d->clk = 1;
    d->eval();
    ++ticks;
    if (ar_now) d->m_arvalid = 0;
    if (r_now) {
      d->m_rready = 0;
      ++checks;
      if (resp != 0) Fail("RRESP at " + std::to_string(addr), resp, 0);
      if (!d->m_rlast) Fail("RLAST on a single beat at " + std::to_string(addr), 0, 1);
      return data;
    }
  }
  Fail("a read never answered at " + std::to_string(addr), 0, 1);
  return 0;
}

// The page's words, as the processor addresses them: physical 17777400 on
// (contract Q13).
constexpr uint32_t kPage = 017777400u;

// The processor's cycle at the page, as `cadr_machine.sv` presents it: the
// held decode a tick before `-XBUS.RQ`, the register taken in the first tick
// of `-XBUS.RQ`, and the word read held for the strobe.  The take is at tick
// `at` when that is later than now.
uint32_t Proc(unsigned which, bool write, uint32_t wdata, long at = -1) {
  while (at >= 0 && ticks < at - 1) Step();
  d->sel = 1;
  d->phys = kPage | which;
  d->dev_write = write;
  d->wdata = write ? wdata : 0xDEADBEEFu;
  d->dev_rq = 0;
  Step();
  d->dev_rq = 1;
  Step();
  d->eval();
  const uint32_t v = d->drives ? static_cast<uint32_t>(d->rdata) : 0xFFFFFFFFu;
  d->dev_rq = 0;
  d->sel = 0;
  d->dev_write = 0;
  Step();
  return v;
}
uint32_t PRead(unsigned which, long at = -1) { return Proc(which, false, 0, at); }
void PWrite(unsigned which, uint32_t v) { (void)Proc(which, true, v); }

// Whether the page acknowledges a read of word `which`, at the tick it takes
// the cycle.
bool PAcks(unsigned which) {
  d->sel = 1;
  d->phys = kPage | which;
  d->dev_write = 0;
  d->wdata = 0xDEADBEEFu;
  d->dev_rq = 0;
  Step();
  d->dev_rq = 1;
  Step();
  d->eval();
  const bool ack = d->dev_ack;
  d->dev_rq = 0;
  d->sel = 0;
  Step();
  return ack;
}

// The face's registers.
constexpr uint32_t IDENT = 0x000, RTC_SECONDS = 0x010, RTC_FRACTION = 0x014, STATE = 0x100,
                   CLAIM = 0x104, CMD_BASE = 0x108, CMD_LOG2 = 0x10C, RESP_BASE = 0x110,
                   RESP_LOG2 = 0x114, CMD_PROD = 0x118, RESP_PROD = 0x11C, RESP_CONS = 0x120,
                   HANDLES = 0x124, MEM_WORDS = 0x128;

uint32_t Epoch() { return Read(STATE) & 0xFFFF0000u; }

// The tick the host's write of index `widx` landed on, the last one logged.
long LastHostWrite(unsigned widx) {
  for (long t = static_cast<long>(log_ticks.size()) - 1; t >= 0; --t)
    if (log_ticks[t].host_we && log_ticks[t].widx == widx) return t;
  return -1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vquux_fd_face_harness;
  d->rst = 1;
  d->mach_rst = 1;
  d->xbus_init = 0;
  d->sel = 0;
  d->phys = 0;
  d->dev_write = 0;
  d->dev_rq = 0;
  d->wdata = 0;
  d->mem_words = 0x200000;
  d->drained = 1;
  d->m_awvalid = 0;
  d->m_wvalid = 0;
  d->m_bready = 0;
  d->m_arvalid = 0;
  d->m_rready = 0;
  Idle(4);
  d->rst = 0;
  d->mach_rst = 0;
  Idle(2);

  // ---------------------------------------------------------- the map
  Want("IDENT", Read(IDENT), 0x51464439u);
  Want("a word nothing names, 0x008", Read(0x008), 0);
  Want("a word nothing names, 0x0FC", Read(0x0FC), 0);
  Want("a word nothing names past MEM_WORDS, 0x12C", Read(0x12C), 0);
  Want("the page's last word", Read(0xFFC), 0);
  Want("MEM_WORDS, 32 boards", Read(MEM_WORDS), 0x200000u);
  d->mem_words = 7u << 16;
  Want("MEM_WORDS, 7 boards", Read(MEM_WORDS), 7u << 16);
  d->mem_words = 0x200000;
  Want("STATE out of reset: quiet, epoch 0", Read(STATE), 0x8u);

  // ------------------------------------- the words that are other slaves'
  // Block-disk's 200-203 and the video controller's 210 are answered by
  // their own slaves on the same seam, and never by the page (contract
  // Q13: exactly one slave answers each word).  No trace can see a second
  // answer there, the page's word being 0 and the device's winning the
  // join, so it is held here, each with the reserved word beside it, which
  // the page does answer.
  for (unsigned w : {0177u, 0200u, 0201u, 0202u, 0203u, 0204u, 0207u, 0210u, 0211u, 0377u}) {
    const bool theirs = (w >= 0200u && w <= 0203u) || w == 0210u;
    Want("the page's acknowledgment of word " + std::to_string(w >> 6) + std::to_string((w >> 3) & 7) +
             std::to_string(w & 7),
         PAcks(w), !theirs);
  }

  // ---------------------------------------------------------- the clock
  const uint32_t S = 0x6AB30C91u;
  Want("BRESP", Write(RTC_FRACTION, 999999000u), 0);
  Write(RTC_SECONDS, S);
  const long ts = LastHostWrite(0);
  Want("word 103 after the host set it", PRead(0103), S);
  // The fraction moves 10 ns a tick from the stage, so the carry lands at
  // the edge 100 ticks after the seconds' own: the tick before reads S, the
  // tick after S + 1.
  // A read takes three ticks, so the two instants are two runs of the same
  // second: the tick before the carry in one, the tick after in the other.
  Want("word 103 in the tick before the carry", PRead(0103, ts + 100), S);
  Write(RTC_FRACTION, 999999000u);
  Write(RTC_SECONDS, S);
  const long ts2 = LastHostWrite(0);
  Want("word 103 in the tick after the carry", PRead(0103, ts2 + 101), S + 1);
  {
    const uint32_t f = Read(RTC_FRACTION);
    if (f >= 1000000u || f % 10u != 0) Fail("the fraction just past the carry", f, 0);
    ++checks;
  }
  Want("RTC_SECONDS reads what word 103 does", Read(RTC_SECONDS), S + 1);
  // The machine's write of 103 goes nowhere.
  PWrite(0103, 0x12345678u);
  Want("word 103 after the machine wrote it", PRead(0103), S + 1);
  // The hold at the last second, read past the carry.
  Write(RTC_FRACTION, 999999000u);
  Write(RTC_SECONDS, 0xFFFFFFFFu);
  {
    const long t2 = LastHostWrite(0);
    Want("word 103 held at the last second past the carry", PRead(0103, t2 + 101), 0xFFFFFFFFu);
  }
  // The stage is forgotten once used: seconds alone start the second at 0.
  Write(RTC_SECONDS, S);
  {
    const long t3 = LastHostWrite(0);
    const uint32_t f = Read(RTC_FRACTION);
    // The read's word is taken a few ticks after the write landed.
    const long since = static_cast<long>(log_ticks.size()) - t3;
    ++checks;
    if (f > static_cast<uint32_t>(10 * since) || f == 0)
      Fail("the fraction after seconds written alone", f, 10 * since);
  }
  // A fraction of a second or more is ignored, and the stage keeps what it
  // had.
  Write(RTC_FRACTION, 500u);
  Write(RTC_FRACTION, 1000000000u);
  Write(RTC_SECONDS, S);
  {
    const long t4 = LastHostWrite(0);
    const uint32_t f = Read(RTC_FRACTION);
    const long since = static_cast<long>(log_ticks.size()) - t4;
    ++checks;
    if (f < 500u || f > 500u + static_cast<uint32_t>(10 * since))
      Fail("the fraction from a stage a second too long left alone", f, 500);
  }
  // A write of fewer than four bytes goes nowhere.
  Write(RTC_SECONDS, 0x11111111u, 0x1);
  Want("the seconds after a byte written", PRead(0103), S);

  // ---------------------------------------------------------- the rings
  // A command ring of two entries at 400 and a response ring of one at 440.
  PWrite(0162, 0400);
  PWrite(0163, 1);
  PWrite(0166, 0440);
  PWrite(0167, 0);
  // A ring of 512 entries is refused, as muir's largest is 256.
  PWrite(0163, 9);
  PWrite(0160, 0x101);
  Want("161 after an enable with a command ring of 512 entries", PRead(0161), 2 | 4);
  PWrite(0163, 1);
  // A ring reaching a word past main memory is refused; to its end, taken.
  d->mem_words = 0447;
  PWrite(0160, 0x101);
  Want("161 after an enable whose response ring passes main memory's end", PRead(0161), 2 | 4);
  d->mem_words = 0450;
  PWrite(0160, 0x101);
  Want("161 after an enable whose response ring ends at main memory's end", PRead(0161), 1);
  d->mem_words = 0x200000;
  Want("STATE enabled, the interrupt enable", Read(STATE), 0x3u);
  Want("CMD_BASE", Read(CMD_BASE), 0400);
  Want("CMD_LOG2", Read(CMD_LOG2), 1);
  Want("RESP_BASE", Read(RESP_BASE), 0440);
  Want("RESP_LOG2", Read(RESP_LOG2), 0);
  Want("CMD_PROD", Read(CMD_PROD), 0);
  Want("RESP_PROD", Read(RESP_PROD), 0);
  Want("RESP_CONS", Read(RESP_CONS), 0);
  Want("HANDLES", Read(HANDLES), 0);

  // The producer, shown only once the write buffer has drained.
  d->drained = 0;
  PWrite(0164, 1);
  Idle(20);
  Want("CMD_PROD with the write buffer not drained", Read(CMD_PROD), 0);
  Want("STATE with the write buffer not drained: no work", Read(STATE) & 0x10u, 0);
  d->drained = 1;
  Idle(2);
  Want("CMD_PROD with the write buffer drained", Read(CMD_PROD), 1);
  Want("STATE: work", Read(STATE) & 0x10u, 0x10u);

  // The claim: only in the current epoch.
  Write(CLAIM, (1u << 16) | 1u);
  Want("busy after a claim in another epoch", Read(CLAIM), 0);
  Write(CLAIM, 1u);
  Want("busy after a claim in the epoch", Read(CLAIM), 1);
  Want("STATE busy, not quiet", Read(STATE) & 0xCu, 0x4u);

  // Completions refused: a stale epoch, a step of nothing, past the shown.
  Write(RESP_PROD, (1u << 16) | 1u);
  Want("STATE <5> after a completion in another epoch", Read(STATE) & 0x20u, 0x20u);
  Want("165 after it", PRead(0165), 0);
  Write(RESP_PROD, 0u);
  Want("STATE <5> after a completion moving nothing", Read(STATE) & 0x20u, 0x20u);
  Write(RESP_PROD, 2u);
  Want("STATE <5> after a completion past the commands shown", Read(STATE) & 0x20u, 0x20u);
  Want("165 after them", PRead(0165), 0);
  Want("RESP_PROD after them", Read(RESP_PROD), 0);

  // Accepted, with a handle staged first: invalidated at once, the
  // interrupt the tick after, the index and the handles the tick after that.
  Write(HANDLES, 1u);
  Want("161's handles with the count only staged", (PRead(0161) >> 16) & 0xFFu, 0);
  Write(RESP_PROD, 1u);
  Idle(4);
  {
    const long w = LastHostWrite(9);
    Want("the invalidation in the tick the completion lands", log_ticks[w].invalidate, 0);
    Want("the invalidation in the tick after", log_ticks[w + 1].invalidate, 1);
    Want("the invalidation in the tick the index shows", log_ticks[w + 2].invalidate, 0);
    Want("the interrupt in the tick the completion lands", log_ticks[w].irq, 0);
    Want("the interrupt the tick after", log_ticks[w + 1].irq, 1);
    Want("165 in the tick after the completion", log_ticks[w + 1].cons, 0);
    Want("165 two ticks after the completion", log_ticks[w + 2].cons, 1);
    Want("the handles open in the tick after the completion", log_ticks[w + 1].handles, 0);
    Want("the handles open two ticks after", log_ticks[w + 2].handles, 1);
  }
  Want("STATE <5> cleared by an accepted completion", Read(STATE) & 0x20u, 0);
  Want("170 as the processor reads it", PRead(0170), 1);
  Want("161: a response waiting, a handle open", PRead(0161), 1 | 0x100 | (1u << 16));
  Want("HANDLES", Read(HANDLES), 1);
  Want("RESP_PROD", Read(RESP_PROD), 1);
  Write(CLAIM, 0u);
  Want("busy let go", Read(CLAIM), 0);

  // The response ring full: a command shown, and no work until 171 moves.
  PWrite(0164, 2);
  Idle(2);
  Want("CMD_PROD, a second command", Read(CMD_PROD), 2);
  Want("STATE with the response ring full: no work", Read(STATE) & 0x10u, 0);
  Write(CLAIM, 1u);
  Write(RESP_PROD, 2u);
  Want("STATE <5> after a completion overfilling the response ring", Read(STATE) & 0x20u, 0x20u);
  PWrite(0171, 1);
  Want("STATE with a response slot free: work", Read(STATE) & 0x10u, 0x10u);
  Write(RESP_PROD, 2u);
  Want("STATE <5> after the completion with room", Read(STATE) & 0x20u, 0);
  Want("170 after it", PRead(0170), 2);
  PWrite(0171, 2);

  // A third command, answered with three handles open, and a fourth taken
  // but not answered when the machine disables the device.
  PWrite(0164, 3);
  Idle(2);
  Write(HANDLES, 3u);
  Write(RESP_PROD, 3u);
  Want("161's handles with three open", (PRead(0161) >> 16) & 0xFFu, 3);
  PWrite(0171, 3);
  PWrite(0164, 4);
  Idle(2);
  Write(HANDLES, 4u);
  Want("busy, the claim still held", Read(CLAIM), 1);
  PWrite(0160, 0);
  Want("STATE after the disable: epoch 1, busy, not quiet", Read(STATE), (1u << 16) | 0x4u);
  Want("161 after the disable, busy: not quiet, no handles", PRead(0161), 0);
  Want("HANDLES after the disable", Read(HANDLES), 0);
  Write(RESP_PROD, 4u);
  Want("STATE <5> after the old epoch's completion", Read(STATE) & 0x20u, 0x20u);
  Write(HANDLES, 5u);
  Write(CLAIM, 1u);
  Want("busy after the old epoch's claim, still held", Read(CLAIM), 1);
  Write(CLAIM, 0u);
  Want("161 once the claim is let go: quiet", PRead(0161), 2);
  Want("STATE: quiet, epoch 1", Read(STATE), (1u << 16) | 0x8u);

  // Enabled again: the old epoch's count never lands in the new one.
  PWrite(0160, 0x001);
  Want("STATE enabled again, epoch 1", Read(STATE), (1u << 16) | 0x1u);
  Write(HANDLES, 5u);                      // the old epoch's: ignored
  PWrite(0164, 1);
  Idle(2);
  const uint32_t e1 = Epoch();
  Write(RESP_PROD, e1 | 1u);
  Want("161's handles after a completion, the old epoch's count ignored",
       (PRead(0161) >> 16) & 0xFFu, 0);
  // Word 100's <7>, the file device's since revision 11 (contract Q13).
  Want("100 with the interrupt enable off", PRead(0100) & 0x80u, 0);
  PWrite(0160, 0x101);
  Want("100 with the interrupt enable on and a response waiting", PRead(0100) & 0x80u, 0x80u);

  // The machine's reset disables it, and counts; a reset of a device
  // already disabled does not.  It clears the faults too.
  PWrite(0164, 0x50);
  Want("161 after a producer claiming too many", PRead(0161) & 0x8u, 0x8u);
  d->xbus_init = 1;
  Step();
  d->xbus_init = 0;
  Idle(2);
  Want("STATE after a machine reset: epoch 2, quiet", Read(STATE), (2u << 16) | 0x8u);
  Want("161 after the machine reset: quiet, no fault", PRead(0161), 2);
  d->xbus_init = 1;
  Step();
  d->xbus_init = 0;
  Idle(2);
  Want("STATE after a reset of a disabled device: epoch 2", Read(STATE), (2u << 16) | 0x8u);

  // A reset of the whole machine leaves the clock, the epoch and the claim
  // alone, disabling the device and counting it: a completion from before
  // the reset can never land after it.
  Write(RTC_SECONDS, 0x70000000u);
  PWrite(0160, 0x001);
  const uint32_t e_before = Epoch();
  Write(CLAIM, e_before | 1u);
  d->mach_rst = 1;
  Idle(3);
  d->mach_rst = 0;
  Idle(2);
  Want("word 103 after a reset of the machine", PRead(0103), 0x70000000u);
  Want("STATE after a reset of the machine: the epoch counted, busy held",
       Read(STATE), (e_before + (1u << 16)) | 0x4u);
  Write(RESP_PROD, e_before | 1u);
  Want("STATE <5> after a completion from before the reset", Read(STATE) & 0x20u, 0x20u);
  Write(CLAIM, 0u);
  Want("161 once the claim is let go after the reset: quiet", PRead(0161), 2);
  // And a reset of a machine whose device is disabled does not count.
  d->mach_rst = 1;
  Idle(3);
  d->mach_rst = 0;
  Idle(2);
  Want("STATE after a reset of a machine with the device disabled",
       Read(STATE) & 0xFFFF0000u, e_before + (1u << 16));

  // A producer claiming fewer commands than are waiting is a fault too, and
  // goes nowhere: two waiting, one claimed; and none claimed.  The rings
  // again first, which the machine's reset put back to power-on's.
  Want("163 after a reset of the machine", PRead(0163), 0);
  PWrite(0162, 0400);
  PWrite(0163, 1);
  PWrite(0166, 0440);
  PWrite(0167, 0);
  PWrite(0160, 0x001);
  d->drained = 0;
  PWrite(0164, 2);
  PWrite(0164, 1);
  Want("161 after a producer claiming fewer than are waiting", PRead(0161) & 0x8u, 0x8u);
  Want("164 after it", PRead(0164), 2);
  PWrite(0160, 0x001);
  Want("161 once 160 is written again", PRead(0161) & 0x8u, 0);
  PWrite(0164, 0);
  Want("161 after a producer claiming none of two waiting", PRead(0161) & 0x8u, 0x8u);
  Want("164 after that", PRead(0164), 2);
  d->drained = 1;
  PWrite(0160, 0);

  // A completion past the commands shown, with room for it in the response
  // ring, is refused: the bound the ring's room does not mask.  A response
  // ring of four, one command shown, a completion of two.
  PWrite(0162, 0400);
  PWrite(0163, 1);
  PWrite(0166, 0440);
  PWrite(0167, 2);
  PWrite(0160, 0x001);
  PWrite(0164, 1);
  Idle(2);
  {
    const uint32_t e = Epoch();
    Write(CLAIM, e | 1u);
    Write(RESP_PROD, e | 2u);
    Want("STATE <5> after a completion past the one command shown, with room",
         Read(STATE) & 0x20u, 0x20u);
    Want("170 after it", PRead(0170), 0);
    Write(RESP_PROD, e | 1u);
    Want("170 after the completion of the one shown", PRead(0170), 1);
    Write(CLAIM, 0u);
  }
  PWrite(0160, 0);
  PWrite(0167, 0);

  std::printf("quux_fd_face: %ld checks over %ld ticks, %d failed\n", checks, ticks, bad);
  if (bad) return 1;
  std::printf("ok: the face and the machine's register page agree on every rule of the host's side\n");
  return 0;
}
