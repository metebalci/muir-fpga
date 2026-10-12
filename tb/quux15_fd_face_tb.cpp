// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 15's file device and real-time clock as Linux reaches them:
// `rtl/plumbing/quux_fd_face.sv` with revision 15's register-page devices
// behind it (`tb/quux15_fd_face_harness.sv`).  The face is driven over AXI in
// the order `docs/file-device.md` gives Linux's server, and the devices as
// the core drives them, so that each rule of the host's side is held against
// what the processor then reads, and each ordering by the clock.  These are
// revision 14's scenarios (`tb/quux_fd_face_tb.cpp`), at revision 15's
// period and timing.
//
// There is no muir reference for the host's side: muir's device runs its
// commands itself.  The machine's side is muir's and is held on the whole
// core by `build/quux15_filedev.quux.pass`, this program's rules played there
// by the core's testbench as the server; what is here is the part of the
// contract that is this project's, each rule with the case just outside it:
//
//   - the page's map: IDENT "QF13", every register at its offset, a word
//     nothing names reading 0, a write of fewer than four bytes going nowhere
//   - MAIN_WORDS, and a ring reaching exactly to main memory's end accepted
//     where one a line past it is refused
//   - the clock: started at `rtc_start` by a reset until the host first sets
//     it and never after; the seconds with a staged fraction, the carry into
//     the next second at its clock and not a clock either side at the
//     period, the hold at 2^32 - 1, the stage forgotten, a fraction of a
//     second or more ignored, and the machine's write of word 103 going
//     nowhere
//   - the command producer shown as the core gives it
//   - the claim: taken only in the current epoch, holding quiet low across
//     a disable, let go in any
//   - a completion refused for a stale epoch, for moving 170 by nothing, for
//     passing the commands shown, and for overfilling the response ring, with
//     no sweep; accepted, landing the clock after its write: the sweep, the
//     interrupt as that clock leaves it, and the index and the handles open
//     from the clock after
//   - the handles open staged until the completion, zeroed by a disable, and
//     a stale epoch's count never landing in the next
//   - the epoch counting the disables, by the machine's write of 160, its
//     RESET-DEVICES and its reset, and not a reset of a device already
//     disabled

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "Vquux15_fd_face_harness.h"
#include "verilated.h"

namespace {

// The period, in units of 0.5 ns: 18 ns, the Kria's.
constexpr unsigned kPeriod = 36;
// Main memory's words, the harness's.
constexpr uint32_t kMainWords = 0x200000u;

Vquux15_fd_face_harness *d;
long ticks = 0;
int bad = 0;
long checks = 0;

void Fail(const std::string &what, uint64_t got, uint64_t want) {
  ++bad;
  std::fprintf(stderr, "FAIL: %s: %#" PRIx64 ", want %#" PRIx64 " (clock %ld)\n", what.c_str(), got,
               want, ticks);
}

void Want(const std::string &what, uint64_t got, uint64_t want) {
  ++checks;
  if (got != want) Fail(what, got, want);
}

// What the file device held over each clock, before the edge that ends it,
// with the host's write that edge takes.
struct Sample {
  bool complete, irq, host_we;
  unsigned widx;
  unsigned cons, handles;
};
std::vector<Sample> log_clocks;

void Sample_() {
  log_clocks.push_back(Sample{d->fd_complete != 0, d->int_now != 0, d->dbg_host_we != 0,
                              d->dbg_host_widx, d->dbg_cons, d->dbg_handles});
}

void Step() {
  d->clk = 0;
  d->eval();
  Sample_();
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
    Sample_();
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
    Sample_();
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

// The core's register read: granted in clock `at` (now when it has passed),
// the word the clock after, at that clock's instant.
uint32_t PRead(unsigned which, long at = -1) {
  while (at >= 0 && ticks < at) Step();
  d->rd_v = 1;
  d->rd_k = which & 0xFFu;
  Step();
  d->rd_v = 0;
  d->eval();
  const uint32_t v = d->rd_word;
  Step();
  return v;
}

// The core's register write, taken in one clock.
void PWrite(unsigned which, uint32_t v) {
  d->wr_v = 1;
  d->wr_k = which & 0xFFu;
  d->wr_data = v;
  Step();
  d->wr_v = 0;
  Step();
}

// CMD_PROD's write, as the core gives it once every write before it is
// answered.
void PProd(uint32_t v) {
  d->prod_v = 1;
  d->prod_data = v;
  Step();
  d->prod_v = 0;
  Step();
}

// The machine's reset, the core's `rst`, for a few clocks.
void MachReset() {
  d->mach_rst = 1;
  Idle(3);
  d->mach_rst = 0;
  Idle(2);
}

// The face's registers.
constexpr uint32_t IDENT = 0x000, RTC_SECONDS = 0x010, RTC_FRACTION = 0x014, STATE = 0x100,
                   CLAIM = 0x104, CMD_BASE = 0x108, CMD_LOG2 = 0x10C, RESP_BASE = 0x110,
                   RESP_LOG2 = 0x114, CMD_PROD = 0x118, RESP_PROD = 0x11C, RESP_CONS = 0x120,
                   HANDLES = 0x124, MEM_WORDS = 0x128;

uint32_t Epoch() { return Read(STATE) & 0xFFFF0000u; }

// The clock the host's write of index `widx` landed at the end of, the last
// one logged.
long LastHostWrite(unsigned widx) {
  for (long t = static_cast<long>(log_clocks.size()) - 1; t >= 0; --t)
    if (log_clocks[t].host_we && log_clocks[t].widx == widx) return t;
  return -1;
}

// Whether a completion landed in any clock from `from` on.
bool CompletedSince(long from) {
  for (long t = from; t < static_cast<long>(log_clocks.size()); ++t)
    if (log_clocks[t].complete) return true;
  return false;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vquux15_fd_face_harness;
  d->rst = 1;
  d->mach_rst = 1;
  d->period = kPeriod;
  d->rtc_start = 0x5A5A0001u;
  d->rd_v = 0;
  d->rd_k = 0;
  d->wr_v = 0;
  d->wr_k = 0;
  d->wr_data = 0;
  d->prod_v = 0;
  d->prod_data = 0;
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
  Want("IDENT, \"QF13\"", Read(IDENT), 0x51463133u);
  Want("a word nothing names, 0x008", Read(0x008), 0);
  Want("a word nothing names, 0x0FC", Read(0x0FC), 0);
  Want("a word nothing names past MEM_WORDS, 0x12C", Read(0x12C), 0);
  Want("the page's last word", Read(0xFFC), 0);
  Want("MEM_WORDS", Read(MEM_WORDS), kMainWords);
  Want("STATE out of reset: quiet, epoch 0", Read(STATE), 0x8u);

  // ---------------------------------------------------------- the clock
  // Before the host has set it, a reset starts it at `rtc_start`.
  Want("word 103 from the reset's start", PRead(0103), 0x5A5A0001u);
  d->rtc_start = 0x5A5A0002u;
  MachReset();
  Want("word 103 from a second reset's start, the host not having set it", PRead(0103), 0x5A5A0002u);
  const uint32_t S = 0x6AB30C91u;
  Want("BRESP", Write(RTC_FRACTION, 999999000u), 0);
  Write(RTC_SECONDS, S);
  const long ts = LastHostWrite(0);
  Want("word 103 after the host set it", PRead(0103), S);
  // The fraction moves by the period a clock from the stage, so the carry
  // lands at the edge `n` clocks after the seconds' own: the clock before
  // reads S, the clock after S + 1.  A read takes two clocks, so the two
  // instants are two runs of the same second.
  const long n = (2000 + kPeriod - 1) / kPeriod;
  Want("word 103 in the clock before the carry", PRead(0103, ts + n - 1), S);
  Write(RTC_FRACTION, 999999000u);
  Write(RTC_SECONDS, S);
  const long ts2 = LastHostWrite(0);
  Want("word 103 in the clock after the carry", PRead(0103, ts2 + n), S + 1);
  {
    // A few clocks past the carry: under a microsecond into the second.
    const uint32_t f = Read(RTC_FRACTION);
    ++checks;
    if (f >= 1000000u) Fail("the fraction just past the carry", f, 0);
  }
  Want("RTC_SECONDS reads what word 103 does", Read(RTC_SECONDS), S + 1);
  // The machine's write of 103 goes nowhere.
  PWrite(0103, 0x12345678u);
  Want("word 103 after the machine wrote it", PRead(0103), S + 1);
  // A reset of the machine leaves a clock the host has set alone.
  d->rtc_start = 0x11111111u;
  MachReset();
  Want("word 103 after a reset of the machine, the host having set it", PRead(0103), S + 1);
  // The hold at the last second, read past the carry.
  Write(RTC_FRACTION, 999999000u);
  Write(RTC_SECONDS, 0xFFFFFFFFu);
  {
    const long t2 = LastHostWrite(0);
    Want("word 103 held at the last second past the carry", PRead(0103, t2 + n), 0xFFFFFFFFu);
  }
  // The stage is forgotten once used: seconds alone start the second at 0.
  Write(RTC_SECONDS, S);
  {
    const long t3 = LastHostWrite(0);
    const uint32_t f = Read(RTC_FRACTION);
    // The read's word is taken a few clocks after the write landed.
    const long since = static_cast<long>(log_clocks.size()) - t3;
    ++checks;
    if (f > static_cast<uint32_t>(kPeriod / 2 * since) || f == 0)
      Fail("the fraction after seconds written alone", f, kPeriod / 2 * since);
  }
  // A fraction of a second or more is ignored, and the stage keeps what it
  // had.
  Write(RTC_FRACTION, 500u);
  Write(RTC_FRACTION, 1000000000u);
  Write(RTC_SECONDS, S);
  {
    const long t4 = LastHostWrite(0);
    const uint32_t f = Read(RTC_FRACTION);
    const long since = static_cast<long>(log_clocks.size()) - t4;
    ++checks;
    if (f < 500u || f > 500u + static_cast<uint32_t>(kPeriod / 2 * since))
      Fail("the fraction from a stage a second too long left alone", f, 500);
  }
  // A write of fewer than four bytes goes nowhere.
  Write(RTC_SECONDS, 0x11111111u, 0x1);
  Want("the seconds after a byte written", PRead(0103), S);

  // ---------------------------------------------------------- the rings
  // A ring of 512 entries is refused, as muir's largest is 256.
  PWrite(0162, 0400);
  PWrite(0163, 9);
  PWrite(0166, 0440);
  PWrite(0167, 0);
  PWrite(0160, 0x101);
  Want("161 after an enable with a command ring of 512 entries", PRead(0161), 2 | 4);
  PWrite(0163, 1);
  // A ring reaching a line past main memory is refused; to its end, taken.
  PWrite(0166, kMainWords - 8);
  PWrite(0167, 1);
  PWrite(0160, 0x101);
  Want("161 after an enable whose response ring passes main memory's end", PRead(0161), 2 | 4);
  PWrite(0167, 0);
  PWrite(0160, 0x101);
  Want("161 after an enable whose response ring ends at main memory's end", PRead(0161), 1);
  PWrite(0160, 0);
  // A command ring of two entries at 400 and a response ring of one at 440.
  PWrite(0166, 0440);
  PWrite(0160, 0x101);
  Want("161 enabled", PRead(0161), 1);
  Want("STATE enabled, the interrupt enable, epoch 1", Read(STATE), (1u << 16) | 0x3u);
  Want("CMD_BASE", Read(CMD_BASE), 0400);
  Want("CMD_LOG2", Read(CMD_LOG2), 1);
  Want("RESP_BASE", Read(RESP_BASE), 0440);
  Want("RESP_LOG2", Read(RESP_LOG2), 0);
  Want("CMD_PROD", Read(CMD_PROD), 0);
  Want("RESP_PROD", Read(RESP_PROD), 0);
  Want("RESP_CONS", Read(RESP_CONS), 0);
  Want("HANDLES", Read(HANDLES), 0);
  Want("STATE: no work", Read(STATE) & 0x10u, 0);

  // The producer, as the core gives it.
  PProd(1);
  Want("CMD_PROD", Read(CMD_PROD), 1);
  Want("STATE: work", Read(STATE) & 0x10u, 0x10u);
  uint32_t e = Epoch();

  // The claim: only in the current epoch.
  Write(CLAIM, (e + (1u << 16)) | 1u);
  Want("busy after a claim in another epoch", Read(CLAIM), 0);
  Write(CLAIM, e | 1u);
  Want("busy after a claim in the epoch", Read(CLAIM), 1);
  Want("STATE busy, not quiet", Read(STATE) & 0xCu, 0x4u);

  // Completions refused: a stale epoch, a step of nothing, past the shown;
  // none sweeps the cache.
  const long before_refused = static_cast<long>(log_clocks.size());
  Write(RESP_PROD, (e + (1u << 16)) | 1u);
  Want("STATE <5> after a completion in another epoch", Read(STATE) & 0x20u, 0x20u);
  Want("165 after it", PRead(0165), 0);
  Write(RESP_PROD, e | 0u);
  Want("STATE <5> after a completion moving nothing", Read(STATE) & 0x20u, 0x20u);
  Write(RESP_PROD, e | 2u);
  Want("STATE <5> after a completion past the commands shown", Read(STATE) & 0x20u, 0x20u);
  Want("165 after them", PRead(0165), 0);
  Want("RESP_PROD after them", Read(RESP_PROD), 0);
  Want("a sweep after a refused completion", CompletedSince(before_refused), 0);

  // Accepted, with a handle staged first: it lands the clock after its
  // write, the sweep and the interrupt then, the index and the handles the
  // clock after that.
  Write(HANDLES, e | 1u);
  Want("161's handles with the count only staged", (PRead(0161) >> 16) & 0xFFu, 0);
  Write(RESP_PROD, e | 1u);
  Idle(4);
  {
    const long w = LastHostWrite(9);
    Want("the sweep in the clock the completion is written", log_clocks[w].complete, 0);
    Want("the sweep in the clock after", log_clocks[w + 1].complete, 1);
    Want("the sweep in the clock the index shows", log_clocks[w + 2].complete, 0);
    Want("the interrupt in the clock the completion is written", log_clocks[w].irq, 0);
    Want("the interrupt the clock after", log_clocks[w + 1].irq, 1);
    Want("165 in the clock after the completion", log_clocks[w + 1].cons, 0);
    Want("165 two clocks after the completion", log_clocks[w + 2].cons, 1);
    Want("the handles open in the clock after the completion", log_clocks[w + 1].handles, 0);
    Want("the handles open two clocks after", log_clocks[w + 2].handles, 1);
  }
  Want("STATE <5> cleared by an accepted completion", Read(STATE) & 0x20u, 0);
  Want("170 as the processor reads it", PRead(0170), 1);
  Want("161: a response waiting, a handle open", PRead(0161), 1 | 0x100 | (1u << 16));
  Want("HANDLES", Read(HANDLES), 1);
  Want("RESP_PROD", Read(RESP_PROD), 1);
  Write(CLAIM, 0u);
  Want("busy let go", Read(CLAIM), 0);

  // The response ring full: a command shown, and no work until 171 moves.
  PProd(2);
  Want("CMD_PROD, a second command", Read(CMD_PROD), 2);
  Want("STATE with the response ring full: no work", Read(STATE) & 0x10u, 0);
  Write(CLAIM, e | 1u);
  Write(RESP_PROD, e | 2u);
  Want("STATE <5> after a completion overfilling the response ring", Read(STATE) & 0x20u, 0x20u);
  PWrite(0171, 1);
  Want("STATE with a response slot free: work", Read(STATE) & 0x10u, 0x10u);
  Write(RESP_PROD, e | 2u);
  Want("STATE <5> after the completion with room", Read(STATE) & 0x20u, 0);
  Want("170 after it", PRead(0170), 2);
  PWrite(0171, 2);

  // A third command, answered with three handles open, and a fourth taken
  // but not answered when the machine disables the device.
  PProd(3);
  Write(HANDLES, e | 3u);
  Write(RESP_PROD, e | 3u);
  Want("161's handles with three open", (PRead(0161) >> 16) & 0xFFu, 3);
  PWrite(0171, 3);
  PProd(4);
  Write(HANDLES, e | 4u);
  Want("busy, the claim still held", Read(CLAIM), 1);
  PWrite(0160, 0);
  Want("STATE after the disable: epoch 2, busy, not quiet", Read(STATE), (2u << 16) | 0x4u);
  Want("161 after the disable, busy: not quiet, no handles", PRead(0161), 0);
  Want("HANDLES after the disable", Read(HANDLES), 0);
  Write(RESP_PROD, e | 4u);
  Want("STATE <5> after the old epoch's completion", Read(STATE) & 0x20u, 0x20u);
  Write(HANDLES, e | 5u);
  Write(CLAIM, e | 1u);
  Want("busy after the old epoch's claim, still held", Read(CLAIM), 1);
  Write(CLAIM, 0u);
  Want("161 once the claim is let go: quiet", PRead(0161), 2);
  Want("STATE: quiet, epoch 2", Read(STATE), (2u << 16) | 0x8u);

  // Enabled again: the old epoch's count never lands in the new one.
  PWrite(0160, 0x001);
  Want("STATE enabled again, epoch 2", Read(STATE), (2u << 16) | 0x1u);
  Write(HANDLES, e | 5u);                  // the old epoch's: ignored
  PProd(1);
  const uint32_t e2 = Epoch();
  Write(RESP_PROD, e2 | 1u);
  Want("161's handles after a completion, the old epoch's count ignored",
       (PRead(0161) >> 16) & 0xFFu, 0);
  // Word 100's <7>, the file device's (contract Q13).
  Want("100 with the interrupt enable off", PRead(0100) & 0x80u, 0);
  PWrite(0160, 0x101);
  Want("100 with the interrupt enable on and a response waiting", PRead(0100) & 0x80u, 0x80u);

  // RESET-DEVICES disables it, and counts; one of a device already disabled
  // does not.  It clears the faults too.
  PProd(0x50);
  Want("161 after a producer claiming too many", PRead(0161) & 0x8u, 0x8u);
  PWrite(0104, 1);
  Want("STATE after RESET-DEVICES: epoch 3, quiet", Read(STATE), (3u << 16) | 0x8u);
  Want("161 after RESET-DEVICES: quiet, no fault", PRead(0161), 2);
  PWrite(0104, 1);
  Want("STATE after RESET-DEVICES of a disabled device: epoch 3", Read(STATE), (3u << 16) | 0x8u);

  // A reset of the whole machine leaves the clock, the epoch and the claim
  // alone, disabling the device and counting it: a completion from before
  // the reset can never land after it.
  Write(RTC_SECONDS, 0x70000000u);
  PWrite(0160, 0x001);
  const uint32_t e_before = Epoch();
  Write(CLAIM, e_before | 1u);
  MachReset();
  Want("word 103 after a reset of the machine", PRead(0103), 0x70000000u);
  Want("STATE after a reset of the machine: the epoch counted, busy held",
       Read(STATE), (e_before + (1u << 16)) | 0x4u);
  Write(RESP_PROD, e_before | 1u);
  Want("STATE <5> after a completion from before the reset", Read(STATE) & 0x20u, 0x20u);
  Write(CLAIM, 0u);
  Want("161 once the claim is let go after the reset: quiet", PRead(0161), 2);
  // And a reset of a machine whose device is disabled does not count.
  MachReset();
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
  PProd(2);
  PProd(1);
  Want("161 after a producer claiming fewer than are waiting", PRead(0161) & 0x8u, 0x8u);
  Want("164 after it", PRead(0164), 2);
  PWrite(0160, 0x001);
  Want("161 once 160 is written again", PRead(0161) & 0x8u, 0);
  PProd(0);
  Want("161 after a producer claiming none of two waiting", PRead(0161) & 0x8u, 0x8u);
  Want("164 after that", PRead(0164), 2);
  PWrite(0160, 0);

  // A completion past the commands shown, with room for it in the response
  // ring, is refused: the bound the ring's room does not mask.  A response
  // ring of four, one command shown, a completion of two.
  PWrite(0167, 2);
  PWrite(0160, 0x001);
  PProd(1);
  {
    const uint32_t ep = Epoch();
    Write(CLAIM, ep | 1u);
    Write(RESP_PROD, ep | 2u);
    Want("STATE <5> after a completion past the one command shown, with room",
         Read(STATE) & 0x20u, 0x20u);
    Want("170 after it", PRead(0170), 0);
    Write(RESP_PROD, ep | 1u);
    Want("170 after the completion of the one shown", PRead(0170), 1);
    Write(CLAIM, 0u);
  }
  // Two commands completed at once, as the host may: 170 moves by two.
  PProd(3);
  {
    const uint32_t ep = Epoch();
    PWrite(0171, 1);
    Write(RESP_PROD, ep | 3u);
    Want("170 after a completion of two at once", PRead(0170), 3);
    Want("STATE <5> after it", Read(STATE) & 0x20u, 0);
  }
  PWrite(0160, 0);
  PWrite(0167, 0);

  std::printf("quux15_fd_face: %ld checks over %ld clocks, %d failed\n", checks, ticks, bad);
  d->final();
  delete d;
  if (bad) return 1;
  std::printf("ok: the face and revision 15's file device agree on every rule of the host's side\n");
  return 0;
}
