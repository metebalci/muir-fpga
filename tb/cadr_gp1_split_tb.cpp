// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `M_AXI_GP1` with three slaves on it, held to the one property the whole
// arrangement exists for: **every address on the port is answered, in both
// directions, by the slave the map names and by no other.**
//
// WHY THAT IS THE PROPERTY.  A read on a general-purpose port that nothing
// in the fabric answers does not fault the Arm; it hangs both cores at one
// PC each.  Measured on this board: the pack feeder read the register face
// at 0x4000_0000 on a bitstream without the pack side, nothing drove
// ARREADY, and both cores stood at one PC for as long as anyone looked.  No
// software guard can catch a load that never completes.  Until this slice
// `cadr_console.sv` answered the whole of GP1 by itself; a decode that lets
// the debug cable share the port is the one thing that can break that rule
// silently.
//
// **IT IS DEMONSTRATED AND NOT ASSERTED.**  Each of the three slaves answers
// with something only it can answer, so which one took a transaction is READ
// OFF the reply:
//
//     the console          "CONS" at word 0, and its own UNMAPPED,
//                          0xBCB0B1AC, everywhere else in its page
//     the debug cable      "DBUG" at word 0, and its own UNMAPPED,
//                          0xBBBDAAB8, everywhere else in its page
//     everything else      "NONE" at every address, OKAY
//
// The two UNMAPPEDs are the complements of two different IDENTs, so they are
// different words --- which is what makes "the console answered the cable's
// page" a visible failure rather than a plausible one.
//
// So a read of any address in the gigabyte says which slave replied, and the
// sweep below covers every word of the two pages --- 2,048 of them --- and a
// spread over the rest of the window: every page up to the sixteenth, every
// power of two, the first and last word of the port, and a pseudo-random
// sample.  A transaction that does not complete inside a bound is reported
// as the board's frozen cores rather than waited for.
//
// **AND THE TWO FACES ARE HELD TO THE ONE BUS BEHIND THEM.**  The port now
// has two roads to the same place: `spy_read(eadr)` through the console's
// page, and a `-DB NEED UB` cycle over MIT's own cable through the debug
// window's.  They meet on the real arbiter, `cadr_console_bus.sv`, in front
// of the real register block, and the check drives both at every one of the
// sixteen registers and requires the same word --- a word the harness's own
// `spy_rdata` port supplies, injectively in the register number, so neither
// road can have invented it.  `build/console.pass` and `build/dbgin.pass`
// hold the two faces separately; nothing before this held them together, and
// a split that broke either would be invisible to both.
//
// **A WRITE AND A READ TO DIFFERENT PAGES RUN TOGETHER**, because that is
// the one stimulus that can see a splitter with one held selection serving
// both channels --- the memory path's "two decode instances, not one muxed
// decode" lesson in a third place.  A stimulus that only ever had one
// channel busy would pass a splitter that routed a read to whichever slave a
// concurrent write had chosen.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Vcadr_gp1_split_harness.h"
#include "verilated.h"
#include "cadr_tick.h"

namespace {

const uint32_t GP1_BASE = 0x80000000u;
const uint32_t GP1_TOP  = 0xBFFFFFFCu;
const uint32_t CON_PAGE = 0x80000000u;
const uint32_t DBG_PAGE = 0x80001000u;

const uint32_t W_CONS = 0x434F4E53u;   // "CONS"
const uint32_t W_DBUG = 0x44425547u;   // "DBUG"
const uint32_t W_NONE = 0x4E4F4E45u;   // "NONE"
const uint32_t W_CON_UNMAPPED = ~W_CONS;
// Which build the harness tells the console the fabric is, page 2's word 32.
// `tb/cadr_gp1_split_harness.sv` drives it; it is a value no bitstream of
// this repository could carry, so a word that reads it came from the console
// and from nowhere else.
const uint32_t W_CON_BUILD = 0xC0FFEE21u;
// Page 2's word 33 carries "TV" in its top half: the backplane's display
// boards, and the marker is what says the console answered rather than that
// the setting is anything.
const uint32_t W_CON_TV_MARK = 0x5456u;
const uint32_t W_DBG_UNMAPPED = ~W_DBUG;
const uint32_t W_LIFT = 0x4C494654u;   // "LIFT"

// muir's `fabric::` bit positions, `tb/cadr_dbgin_tb.cpp`'s own constants.
const uint32_t kReq      = 1u;
const uint32_t kWr       = 1u << 1;
const uint32_t kAShift   = 2;
const uint32_t kSeqShift = 8;
const uint32_t kSeqMask  = 0xFu;
const uint32_t kDbdShift = 16;
const uint32_t kAck_     = 1u << 1;
const uint32_t kDrv      = 1u << 3;
const uint32_t kMark     = 1u << 14;
const uint32_t kMarkMask = 3u << 14;

// busint::DEBUG_CYCLE and the three after it.
const unsigned kACycle = 0, kAStatus = 1, kAModifier = 2, kAAddress = 3;
// busint::DEBUG_OUT_REQUEST_NS and DEBUG_RELEASE_NS, in ticks.
const long kLeadT = GridTicks(100);
const long kReleaseT = GridTicks(100);

// spy::BASE.
const uint32_t kSpyBase = 0766000u;
uint32_t SpyAddr(unsigned e) { return kSpyBase + 2u * e; }

// The console's own words, as offsets from `REG_BASE`.
const unsigned kConIdent = 0, kConStat = 1, kConVma = 7, kConQ = 8, kConMd = 9;
const unsigned kConSpy = 16;   // page 1, word k is EADR k

// The window's words.
const unsigned kWIdent = 0, kWCtl = 1, kWSts = 2, kWClear = 3, kWFaults = 4;

// What the harness's `spy_rdata` answers for a register: injective in the
// register number, so a road that reads the wrong register says so.  Not a
// constant, for the reason this project has recorded twice --- a check whose
// only exercise reads one value tests nothing.
uint16_t SpyPoison(unsigned eadr) {
  return static_cast<uint16_t>(0xA500u ^ (eadr * 0x1111u) ^ (eadr << 12));
}

// The three registers `mach_vma`, `mach_q` and `mach_md` are driven with,
// again from outside, and again distinct from each other.
// None of the three is zero, which is what an unconnected port reads, and no
// two are the same word --- the board's own readout at the `PDL-BUFFER-REFILL`
// halt had `Q` and `MD` equal and the pair only says something when they can
// differ.
const uint32_t kVma = 0x02651067u, kQ = 0x06000000u, kMd = 0x8A5C36E1u;

int bad = 0;
long tick = 0;

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  if (bad < 25) {
    std::fprintf(stderr, "tick %ld: %s is 0x%llx, wanting 0x%llx\n",
                 tick, what, got, want);
  }
  ++bad;
}

void FailAt(uint32_t addr, const char *what, unsigned long long got,
            unsigned long long want) {
  if (bad < 25) {
    std::fprintf(stderr, "tick %ld: at 0x%08x, %s is 0x%llx, wanting 0x%llx\n",
                 tick, addr, what, got, want);
  }
  ++bad;
}

void Say(const char *what) {
  if (bad < 25) std::fprintf(stderr, "tick %ld: %s\n", tick, what);
  ++bad;
}

uint32_t seed = 0x5C31A97Du;
uint32_t rnd() {
  seed = seed * 1664525u + 1013904223u;
  return seed >> 8;
}

// ---------------------------------------------------------------- the bus

struct WTxn {
  uint32_t addr = 0;
  std::vector<uint32_t> data;
  uint32_t strb = 0xF;
  unsigned id = 0;
  int resp = -1;
  int bs = 0;
  unsigned beats = 0;
  bool aw = false;
  int aws = 0;
  bool done = false;
};

struct RTxn {
  uint32_t addr = 0;
  unsigned len = 0;
  unsigned id = 0;
  std::vector<uint32_t> data;
  int resp = -1;
  bool ar = false;
  int ars = 0;
  bool done = false;
};

struct Bus {
  Vcadr_gp1_split_harness *d;
  long aw_total = 0, w_total = 0, b_total = 0, ar_total = 0, r_total = 0;
  long stalls = 0;

  explicit Bus(Vcadr_gp1_split_harness *dut) : d(dut) {}

  void Quiet() {
    d->m_awvalid = 0; d->m_wvalid = 0; d->m_bready = 0;
    d->m_arvalid = 0; d->m_rready = 0;
    d->m_wlast = 0;
  }

  // The processor's sixteen-way diagnostic mux, answered from outside: the
  // register block's `ub_rdata` IS `spy_rdata`, so this is what both roads
  // must come back with.  Driven from `spy_eadr` as the processor drives it
  // --- combinationally, one address held for the whole cycle --- and set
  // before the edge, never after, which is the convention every testbench
  // here uses.
  void Feed() { d->spy_rdata = SpyPoison(d->spy_eadr); }

  void Step() {
    Feed();
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    ++tick;
  }

  void Idle(long n) {
    Quiet();
    for (long k = 0; k < n; ++k) Step();
  }

  // Drive a write and a read to completion together.  Either may be null.
  // The protocol is asserted every tick: exactly one handshake per channel
  // per transaction, RLAST where ARLEN says and nowhere else, the response
  // never before the data.
  void Run(WTxn *w, RTxn *r) {
    const long began = tick;
    const long kBound = 20000;
    int aw_hold = (int)(rnd() % 3), w_hold = (int)(rnd() % 3);
    int b_hold = (int)(rnd() % 3), ar_hold = (int)(rnd() % 3);
    int r_hold = (int)(rnd() % 3);
    if (w) { w->beats = 0; w->bs = 0; w->aws = 0; w->aw = false; w->done = false; }
    if (r) { r->data.clear(); r->ars = 0; r->ar = false; r->done = false; }
    while ((w && !w->done) || (r && !r->done)) {
      // **THE ADDRESS, THE LENGTH AND THE ID ARE POISONED THE MOMENT THEIR
      // HANDSHAKE IS DONE**, which AXI allows and a real interconnect does:
      // once AWVALID met AWREADY the channel is free and the master may put
      // anything on it.  The poison is the complement, which lands outside
      // the port's window --- so a splitter that read the LIVE address
      // rather than the one it captured routes the rest of the transaction
      // somewhere else, and a stimulus that politely held the address still
      // would never have said so.
      if (w && !w->done) {
        d->m_awaddr = w->aw ? ~w->addr : w->addr;
        d->m_awlen = w->aw ? (uint8_t)(~(w->data.size() - 1) & 0xF)
                           : (uint8_t)(w->data.size() - 1);
        d->m_awid = w->aw ? (~w->id & 0xFFF) : w->id;
        d->m_awvalid = (!w->aw && aw_hold == 0) ? 1 : 0;
        d->m_wdata = w->beats < w->data.size() ? w->data[w->beats] : 0;
        d->m_wstrb = w->strb;
        d->m_wlast = (w->beats + 1 == w->data.size()) ? 1 : 0;
        d->m_wvalid = (w->aw && w->beats < w->data.size() && w_hold == 0) ? 1 : 0;
        d->m_bready = (w->beats == w->data.size() && b_hold == 0) ? 1 : 0;
      } else {
        d->m_awvalid = 0; d->m_wvalid = 0; d->m_bready = 0; d->m_wlast = 0;
      }
      if (r && !r->done) {
        d->m_araddr = r->ar ? ~r->addr : r->addr;
        d->m_arlen = r->ar ? (uint8_t)(~r->len & 0xF) : (uint8_t)r->len;
        d->m_arid = r->ar ? (~r->id & 0xFFF) : r->id;
        d->m_arvalid = (!r->ar && ar_hold == 0) ? 1 : 0;
        d->m_rready = (r->ar && r_hold == 0) ? 1 : 0;
      } else {
        d->m_arvalid = 0; d->m_rready = 0;
      }

      Feed();
      d->clk = 0; d->eval();

      const bool aw_hs = d->m_awvalid && d->m_awready;
      const bool w_hs = d->m_wvalid && d->m_wready;
      const bool b_hs = d->m_bready && d->m_bvalid;
      const bool ar_hs = d->m_arvalid && d->m_arready;
      const bool r_hs = d->m_rready && d->m_rvalid;

      if (w && !w->done) {
        if (d->m_bvalid && w->beats < w->data.size())
          Fail("BVALID before the write's last beat", 1, 0);
        if (d->m_bvalid && !b_hs) ++stalls;
        if (b_hs) {
          ++w->bs;
          w->resp = d->m_bresp;
          if ((unsigned)d->m_bid != w->id) FailAt(w->addr, "BID", d->m_bid, w->id);
        }
      }
      if (r && !r->done) {
        if (d->m_rvalid && !r->ar) Fail("RVALID before the read's address", 1, 0);
        if (d->m_rvalid && !r_hs) ++stalls;
        if (r_hs) {
          if ((unsigned)d->m_rid != r->id) FailAt(r->addr, "RID", d->m_rid, r->id);
          const bool last = (r->data.size() == r->len);
          if ((d->m_rlast != 0) != last)
            FailAt(r->addr, last ? "RLAST missing on the last beat"
                                 : "RLAST on a beat that is not the last",
                   d->m_rlast, last);
          if (r->data.empty()) r->resp = d->m_rresp;
          else if (d->m_rresp != r->resp)
            FailAt(r->addr, "RRESP changed inside one burst", d->m_rresp, r->resp);
          r->data.push_back(d->m_rdata);
        }
      }

      d->clk = 1; d->eval();
      ++tick;

      if (w && !w->done) {
        if (aw_hs) { w->aw = true; ++w->aws; ++aw_total; } else if (aw_hold > 0) --aw_hold;
        if (w_hs) { ++w->beats; ++w_total; w_hold = (int)(rnd() % 3); }
        else if (w_hold > 0) --w_hold;
        if (b_hs) { w->done = true; ++b_total; }
        else if (b_hold > 0 && w->beats == w->data.size()) --b_hold;
      }
      if (r && !r->done) {
        if (ar_hs) { r->ar = true; ++r->ars; ++ar_total; } else if (ar_hold > 0) --ar_hold;
        if (r_hs) {
          ++r_total;
          r_hold = (int)(rnd() % 3);
          if (r->data.size() == r->len + 1) r->done = true;
        } else if (r_hold > 0 && r->ar) --r_hold;
      }

      if (tick - began > kBound) {
        if (w && !w->done)
          FailAt(w->addr, "a write that never completed --- the board's frozen cores", 0, 1);
        if (r && !r->done)
          FailAt(r->addr, "a read that never completed --- the board's frozen cores", 0, 1);
        break;
      }
      if (bad >= 25) break;
    }
    Quiet();
    if (w) {
      if (w->aws != 1) FailAt(w->addr, "write-address handshakes for one write", w->aws, 1);
      if (w->bs != 1) FailAt(w->addr, "responses to one write", w->bs, 1);
      if (w->beats != w->data.size())
        FailAt(w->addr, "write beats taken", w->beats, w->data.size());
    }
    if (r) {
      if (r->ars != 1) FailAt(r->addr, "read-address handshakes for one read", r->ars, 1);
      if (r->data.size() != r->len + 1)
        FailAt(r->addr, "read beats for one read", r->data.size(), r->len + 1);
    }
  }

  uint32_t Read(uint32_t addr, int *resp = nullptr) {
    RTxn r;
    r.addr = addr;
    r.id = rnd() & 0xFFF;
    Run(nullptr, &r);
    if (resp) *resp = r.resp;
    return r.data.empty() ? 0 : r.data[0];
  }

  int Write(uint32_t addr, uint32_t word, uint32_t strb = 0xF) {
    WTxn w;
    w.addr = addr;
    w.data.push_back(word);
    w.strb = strb;
    w.id = rnd() & 0xFFF;
    Run(&w, nullptr);
    return w.resp;
  }
};

// Which slave the map says answers `addr`.  This is the map, written once,
// and the sweep compares against it.
enum Slave { kCon, kDbg, kDflt };

Slave Owner(uint32_t addr) {
  const uint32_t page = addr & 0xFFFFF000u;
  if (page == CON_PAGE) return kCon;
  if (page == DBG_PAGE) return kDbg;
  return kDflt;
}

const char *Name(Slave s) {
  switch (s) {
    case kCon: return "the console";
    case kDbg: return "the debug cable";
    default: return "the default slave";
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_gp1_split_harness;
  Bus b(dut);

  dut->rst = 1;
  b.Quiet();
  dut->m_awaddr = 0; dut->m_awlen = 0; dut->m_awid = 0;
  dut->m_wdata = 0; dut->m_wstrb = 0xF;
  dut->m_araddr = 0; dut->m_arlen = 0; dut->m_arid = 0;
  dut->spy_rdata = 0;
  dut->mach_vma = kVma; dut->mach_q = kQ; dut->mach_md = kMd;
  dut->err_status = 0x5A;
  dut->cpu_msyn = 0; dut->cpu_write = 0; dut->cpu_addr = 0; dut->cpu_wdata = 0;
  for (int k = 0; k < 8; ++k) b.Step();
  dut->rst = 0;
  b.Idle(4);

  // ======================================================================
  // The three are where the map says, and each says who it is
  // ======================================================================
  {
    int resp = 0;
    const uint32_t ident_con = b.Read(CON_PAGE + 4 * kConIdent, &resp);
    if (ident_con != W_CONS) FailAt(CON_PAGE, "the console's IDENT", ident_con, W_CONS);
    if (resp != 0) FailAt(CON_PAGE, "RRESP at the console's IDENT", resp, 0);
    const uint32_t ident_dbg = b.Read(DBG_PAGE + 4 * kWIdent, &resp);
    if (ident_dbg != W_DBUG) FailAt(DBG_PAGE, "the debug cable's IDENT", ident_dbg, W_DBUG);
    if (resp != 0) FailAt(DBG_PAGE, "RRESP at the debug cable's IDENT", resp, 0);
    const uint32_t none = b.Read(GP1_BASE + 0x2000, &resp);
    if (none != W_NONE) FailAt(GP1_BASE + 0x2000, "the default slave's word", none, W_NONE);
    if (resp != 0) FailAt(GP1_BASE + 0x2000, "RRESP at the third page", resp, 0);
  }

  // ======================================================================
  // EVERY PAGE OF THE PORT, EXHAUSTIVELY
  // ======================================================================
  //
  // `M_AXI_GP1`'s window is 0x8000_0000 to 0xBFFF_FFFF, a gigabyte, which is
  // 262,144 pages of 4 KB.  Every one of them is read, and the word that
  // comes back says which slave answered: "CONS" at the console's, "DBUG" at
  // the cable's, "NONE" at every other.  **A SAMPLE WOULD NOT DO**, because
  // a decode wrong by one bit is wrong on a set of pages a sample can miss,
  // and the whole point of the arrangement is that no address falls through:
  // one that does hangs both Arm cores at one PC each.  This is
  // `cadr_xbus_decode`'s exhaustive shape, on the second of the two ports
  // where an unanswered address is not a wrong answer but a stopped
  // processor.
  //
  // The handshakes vary here as everywhere --- `Read` holds its valid and
  // ready for a random few ticks --- so this is not a faster, politer
  // stimulus than the sweep below; it is the same one, over every page.
  long pages = 0;
  {
    for (uint32_t page = 0; page < 262144u && bad < 25; ++page) {
      const uint32_t addr = GP1_BASE + (page << 12);
      int resp = -1;
      const uint32_t got = b.Read(addr, &resp);
      ++pages;
      if (resp != 0) FailAt(addr, "RRESP at a page's first word", resp, 0);
      switch (Owner(addr)) {
        case kCon:
          if (got != W_CONS) FailAt(addr, "the word at the console's page", got, W_CONS);
          break;
        case kDbg:
          if (got != W_DBUG) FailAt(addr, "the word at the debug cable's page", got, W_DBUG);
          break;
        default:
          if (got != W_NONE) FailAt(addr, "the word at a page with nothing on it", got, W_NONE);
          break;
      }
    }
  }

  // ======================================================================
  // THE SWEEP: every address answered, by the slave the map names
  // ======================================================================
  //
  // Every word of the two pages, plus a spread over the rest of the
  // gigabyte.  What each slave's reply must look like at an address with
  // nothing behind it is its OWN UNMAPPED, and the two are different words:
  // the console's is ~"CONS" and the cable's ~"DBUG", so a page answered by
  // the wrong face is visible and not merely plausible.
  std::vector<uint32_t> sweep;
  for (uint32_t k = 0; k < 1024; ++k) {
    sweep.push_back(CON_PAGE + 4 * k);
    sweep.push_back(DBG_PAGE + 4 * k);
  }
  for (uint32_t p = 2; p < 16; ++p) sweep.push_back(GP1_BASE + (p << 12));
  for (int s = 12; s < 30; ++s) {
    sweep.push_back(GP1_BASE + (1u << s));
    sweep.push_back(GP1_BASE + (1u << s) + 0xFFC);
  }
  sweep.push_back(GP1_BASE);
  sweep.push_back(GP1_TOP);
  sweep.push_back(GP1_BASE + 0x0FFC);
  sweep.push_back(GP1_BASE + 0x1FFC);
  sweep.push_back(GP1_BASE + 0x2FFC);

  long reads = 0, writes = 0;
  long by[3] = {0, 0, 0};
  for (uint32_t addr : sweep) {
    if (bad >= 25) break;
    const Slave s = Owner(addr);
    ++by[s];
    int resp = -1;
    const uint32_t got = b.Read(addr, &resp);
    ++reads;
    if (resp != 0) FailAt(addr, "RRESP", resp, 0);
    // The reply names the slave.  This is the whole demonstration: an
    // address routed to the wrong slave gives the wrong word, and an
    // address routed nowhere gives no answer at all.
    const uint32_t word = (addr & 0xFFFu) >> 2;
    switch (s) {
      case kDflt:
        if (got != W_NONE) FailAt(addr, "the reply, which should be the default's", got, W_NONE);
        break;
      case kCon:
        if (got == W_NONE)
          FailAt(addr, "the reply: the default slave answered the console's page", got, 0);
        if (got == W_DBG_UNMAPPED)
          FailAt(addr, "the reply: the debug cable answered the console's page", got, 0);
        // Words 0 to 31 are the console's first two pages of sixteen, word
        // 32 is which build the fabric is, word 33 is which display boards
        // the backplane has, words 64 to 95 are the two boards' color maps,
        // and everything else in its 4 KB page is its own UNMAPPED.  **THE
        // BUILD IS ASSERTED HERE TOO**, and not skipped, because what this
        // check is about is which slave answers an address: a word that
        // reads the harness's own stamp came from the console and from
        // nothing else, which is a stronger statement about the routing than
        // `UNMAPPED` is.  The display word carries its own marker, which
        // says the same thing about it.
        if (word == 32) {
          if (got != W_CON_BUILD)
            FailAt(addr, "the console's build word", got, W_CON_BUILD);
        } else if (word == 33) {
          if ((got >> 16) != W_CON_TV_MARK)
            FailAt(addr, "the display word's marker", got >> 16, W_CON_TV_MARK);
        } else if (word == 34) {
          // **AND WHAT THE DISPLAY OUTPUT SHOWS**, page 2's word 34, which
          // carries a marker of its own exactly as word 33 does.  What this
          // check is about is that the CONSOLE answered at this address rather
          // than the default slave or the cable, so the marker is the whole
          // assertion; `build/console.pass` is where the word's six keys and
          // its two settings are held.
          if ((got >> 16) != 0x4844u)
            FailAt(addr, "the hdmi word's marker", got >> 16, 0x4844u);
        } else if (word >= 64 && word < 96) {
          // The two color maps, which this harness drives with zeros: what
          // is asserted here is that the console answered and not that the
          // map is anything, `build/console.pass` being where the pattern
          // is.  The default slave's and the cable's own words are what
          // this rules out, and both are checked above.
        } else if (word > 32 && got != W_CON_UNMAPPED) {
          FailAt(addr, "a word above the console's build", got, W_CON_UNMAPPED);
        }
        break;
      case kDbg:
        if (got == W_NONE)
          FailAt(addr, "the reply: the default slave answered the cable's page", got, 0);
        if (got == W_CON_UNMAPPED)
          FailAt(addr, "the reply: the console answered the cable's page", got, 0);
        // Five words are used; everything else in the page is UNMAPPED.
        if (word >= 5 && got != W_DBG_UNMAPPED)
          FailAt(addr, "a word above the cable's five", got, W_DBG_UNMAPPED);
        break;
    }
  }

  // Writes over the same sweep.  Zero everywhere, so that no command word of
  // either face is armed: the console's word 6 takes a reset only on
  // `RESET_KEY`, and the cable's `CTL` with bit 0 clear is a lift of nothing
  // --- which the window records in `FAULTS` and is asserted below.  A sweep
  // that reset the machine or started a debug cycle would be testing the
  // slave rather than the decode.
  for (uint32_t addr : sweep) {
    if (bad >= 25) break;
    const int resp = b.Write(addr, 0);
    ++writes;
    if (resp != 0) FailAt(addr, "BRESP", resp, 0);
  }

  // And the two faces still answer, which is the cheapest statement that the
  // sweep did not wedge either of them.
  if (b.Read(CON_PAGE) != W_CONS) Fail("the console's IDENT after the sweep", b.Read(CON_PAGE), W_CONS);
  if (b.Read(DBG_PAGE) != W_DBUG) Fail("the cable's IDENT after the sweep", b.Read(DBG_PAGE), W_DBUG);

  // ======================================================================
  // A WRITE AND A READ TO DIFFERENT PAGES, TOGETHER
  // ======================================================================
  //
  // The one stimulus that sees a splitter with one held selection for both
  // channels.  Each round writes one page's word and reads another page's
  // IDENT at the same time, and the read must come back from the page it
  // named.
  long crossed = 0;
  {
    struct Pair { uint32_t waddr, wdata; uint32_t raddr, rwant; };
    const Pair pairs[] = {
      {DBG_PAGE + 4 * kWFaults, 0u, CON_PAGE, W_CONS},
      {CON_PAGE + 4 * 10, 0u, DBG_PAGE, W_DBUG},
      {GP1_BASE + 0x5000, 0u, CON_PAGE, W_CONS},
      {GP1_BASE + 0x7000, 0u, DBG_PAGE, W_DBUG},
      {CON_PAGE + 4 * 11, 0u, GP1_BASE + 0x9000, W_NONE},
      {DBG_PAGE + 4 * 8, 0u, GP1_BASE + 0x11000, W_NONE},
      {DBG_PAGE + 4 * 9, 0u, CON_PAGE + 4 * 40, W_CON_UNMAPPED},
      {CON_PAGE + 4 * 12, 0u, DBG_PAGE + 4 * 40, W_DBG_UNMAPPED},
    };
    for (const Pair &p : pairs) {
      for (int round = 0; round < 4 && bad < 25; ++round) {
        WTxn w;
        w.addr = p.waddr;
        w.data.push_back(p.wdata);
        w.id = rnd() & 0xFFF;
        RTxn r;
        r.addr = p.raddr;
        r.id = (rnd() & 0xFFF) ^ 0x555;
        b.Run(&w, &r);
        ++crossed;
        const uint32_t got = r.data.empty() ? 0 : r.data[0];
        if (got != p.rwant)
          FailAt(p.raddr, "a read run beside a write to another page", got, p.rwant);
        if (w.resp != 0) FailAt(p.waddr, "BRESP on the write beside it", w.resp, 0);
      }
    }
  }

  // ======================================================================
  // A BURST, AND ONE THAT ENDS ON A PAGE'S LAST WORD
  // ======================================================================
  //
  // AXI forbids a burst that crosses a 4 KB boundary, so a legal burst stays
  // in the page it started in and a slave handed a twelve-bit offset can
  // never see one wrap.  This drives one anyway, at the end of each page and
  // at the end of a page nothing claims, and requires it to terminate ---
  // the splitter ends a read where the SLAVE says it does, so a slave that
  // sent fewer beats than ARLEN would leave the port owing one.
  long bursts = 0;
  {
    const uint32_t at[] = {CON_PAGE + 0xFF0, DBG_PAGE + 0xFF0,
                           GP1_BASE + 0x3FF0, CON_PAGE, DBG_PAGE};
    for (uint32_t a : at) {
      if (bad >= 25) break;
      RTxn r;
      r.addr = a;
      r.len = 3;
      r.id = rnd() & 0xFFF;
      b.Run(nullptr, &r);
      ++bursts;
      if (r.data.size() != 4)
        FailAt(a, "beats in a four-beat burst", r.data.size(), 4);
      if (r.resp != 0) FailAt(a, "RRESP in a burst", r.resp, 0);
    }
  }

  // ======================================================================
  // THE TWO ROADS TO ONE REGISTER BLOCK
  // ======================================================================
  //
  // This is what the split is FOR, and it is the read-back the check is
  // held to.  `spy_read(eadr)` through the console's page and a debug cycle
  // over MIT's own cable through the window's page reach the same sixteen
  // registers by two entirely different paths --- two AXI faces, two masters
  // on `cadr_console_bus.sv` --- and must give the same word.  The word
  // itself comes from the harness's `spy_rdata` port and is injective in the
  // register number, so neither road can be right by accident and a road
  // reading the wrong register says which.
  unsigned seq = 0;
  auto Ctl = [&](unsigned a, bool write, uint16_t dbd) {
    seq = (seq + 1) & kSeqMask;
    return kReq | (write ? kWr : 0) | ((a & 3u) << kAShift)
           | (seq << kSeqShift) | (uint32_t(dbd) << kDbdShift);
  };
  auto Win = [&](unsigned i) { return DBG_PAGE + 4u * i; };
  // A request is the store and then the lead: the window puts the levels on
  // the cable at once and brings `-DEBUG IN REQ` down `LEAD_T` ticks later,
  // as the MTD100 at DBGOUT 0A10 does, so a request lifted inside that
  // section never reaches the 74S139 at all.
  auto Request = [&](uint32_t w) { b.Write(Win(kWCtl), w); b.Idle(kLeadT + 4); };
  auto Lift = [&](uint32_t w) { b.Write(Win(kWCtl), w & ~kReq); b.Idle(kLeadT + 4); };
  auto LoadSts = [&]() {
    const uint32_t s = b.Read(Win(kWSts));
    if ((s & kMarkMask) != kMark) Fail("STS's MARK", s & kMarkMask, kMark);
    return s;
  };

  auto CableCycle = [&](uint32_t uaddr, bool write, uint16_t word,
                        bool expect_ack) {
    uint32_t w = Ctl(kAModifier, false,
                     static_cast<uint16_t>((uaddr >> 17) & 1u));
    Request(w);
    Lift(w);
    w = Ctl(kAAddress, false, static_cast<uint16_t>((uaddr >> 1) & 0xFFFFu));
    Request(w);
    Lift(w);
    w = Ctl(kACycle, write, word);
    Request(w);
    uint32_t s = 0;
    long waited = 0;
    for (;;) {
      s = LoadSts();
      if (((s >> kSeqShift) & kSeqMask) != seq)
        Fail("the cycle's sequence", (s >> kSeqShift) & kSeqMask, seq);
      if (s & kAck_) break;
      if (waited >= 4000) break;
      b.Idle(16);
      waited += 16;
    }
    const bool acked = (s & kAck_) != 0;
    if (acked != expect_ack)
      Say(expect_ack ? "a cycle at a slave's own address was not acknowledged"
                     : "a cycle at an address nothing answers was acknowledged");
    Lift(w);
    b.Idle(kReleaseT + 4);
    return s;
  };

  long both = 0;
  {
    // The window's `FAULTS` picked up the idle lift the sweep's zero write
    // to `CTL` made; clear the cable and start from rest.
    b.Write(Win(kWClear), W_LIFT);
    b.Idle(kLeadT + 8);
    for (unsigned e = 0; e < 16 && bad < 25; ++e) {
      const uint16_t want = SpyPoison(e);
      // Road one: the console's page 1, which is `spy_read(eadr)`.
      const uint32_t via_con = b.Read(CON_PAGE + 4 * (kConSpy + e));
      if (via_con & (1u << 16))
        FailAt(CON_PAGE + 4 * (kConSpy + e), "a diagnostic cycle the console lost", 1, 0);
      if ((via_con & 0xFFFFu) != want)
        FailAt(CON_PAGE + 4 * (kConSpy + e), "spy_read through the console's page",
               via_con & 0xFFFFu, want);
      // Road two: MIT's cable through the window's page.
      const uint32_t s = CableCycle(SpyAddr(e), false, 0, true);
      if (!(s & kDrv)) Say("the debuggee drove nothing on a read cycle");
      const uint16_t via_cable = static_cast<uint16_t>(s >> kDbdShift);
      if (via_cable != want)
        Fail("the same register read over the debug cable", via_cable, want);
      ++both;
    }
  }

  // And the status strobe, which drives only `DBD<7:0>` --- the high byte is
  // the open cable's pull-ups, so a status read reads `0xff00 | status` and
  // the adapter must not zero it.  `err_status` is driven from outside, so
  // this is read-back and not a constant either module holds.
  {
    uint32_t w = Ctl(kAStatus, false, 0);
    Request(w);
    const uint32_t s = LoadSts();
    Lift(w);
    b.Idle(kReleaseT + 4);
    if (!(s & kAck_)) Say("a status strobe was not acknowledged");
    const uint16_t got = static_cast<uint16_t>(s >> kDbdShift);
    const uint16_t want = static_cast<uint16_t>(0xFF00u | 0x5Au);
    if (got != want) Fail("the error status read over the cable", got, want);
  }

  // The console's words 7, 8 and 9, which are the other read-back this page
  // carries: driven from outside, latched together at a read of word 7.
  {
    const uint32_t v = b.Read(CON_PAGE + 4 * kConVma);
    const uint32_t q = b.Read(CON_PAGE + 4 * kConQ);
    const uint32_t m = b.Read(CON_PAGE + 4 * kConMd);
    if (v != kVma) Fail("the virtual address register through the console's page", v, kVma);
    if (q != kQ) Fail("Q through the console's page", q, kQ);
    if (m != kMd) Fail("MD through the console's page", m, kMd);
  }

  // ======================================================================
  // AND NEITHER MASTER STARVES THE OTHER BEHIND THE SPLIT
  // ======================================================================
  //
  // The debug master beats the console on `cadr_console_bus.sv` --- MIT's
  // 74LS74 at UBMAST 0D02 is first on the `NPG1 IN` chain --- and both wait
  // for the processor's own strobe.  Running a console cycle while a debug
  // cycle stands is what says the split did not put them on one another's
  // road: they share a bus and not a port, and a console read that came
  // back with the cable's answer would be this check's whole point.
  {
    uint32_t w = Ctl(kAModifier, false,
                     static_cast<uint16_t>((SpyAddr(6) >> 17) & 1u));
    Request(w);
    Lift(w);
    w = Ctl(kAAddress, false, static_cast<uint16_t>((SpyAddr(6) >> 1) & 0xFFFFu));
    Request(w);
    Lift(w);
    w = Ctl(kACycle, false, 0);
    Request(w);
    // The cable is holding the bus.  The console's own cycle waits and then
    // gives up after `LOST_T`, which is its own bound and not a hang.
    const uint32_t via_con = b.Read(CON_PAGE + 4 * (kConSpy + 6));
    const uint32_t s = LoadSts();
    Lift(w);
    b.Idle(kReleaseT + 4);
    if (!(s & kAck_)) Say("the standing cable cycle was never acknowledged");
    if (static_cast<uint16_t>(s >> kDbdShift) != SpyPoison(6))
      Fail("the cable's word while the console asked too", s >> kDbdShift, SpyPoison(6));
    // The console either got the word or reported the cycle lost; what it
    // must never do is report a word that is not that register's.
    if (!(via_con & (1u << 16)) && (via_con & 0xFFFFu) != SpyPoison(6))
      Fail("the console's word while the cable held the bus",
           via_con & 0xFFFFu, SpyPoison(6));
    // And the port answered both, which is the property this file is about.
    if (b.Read(CON_PAGE) != W_CONS) Say("the console stopped answering its page");
    if (b.Read(DBG_PAGE) != W_DBUG) Say("the cable stopped answering its page");
  }

  // ======================================================================
  // THE MODIFIER'S BIT 1 IS A LEVEL, AND MIT'S OWN SEQUENCE MUST BE WRITABLE
  // ======================================================================
  //
  // `-DEBUGEE RESET` crosses the debuggee's own cables to OLORD2 and is that
  // processor's power-on reset, so CC's reset of a debuggee goes down the
  // cable and needs nothing else.  MIT's note is "write a 1 here then write a
  // 0", which makes it a LEVEL and not a pulse, and the level is what the
  // machine is held in reset by.
  //
  // **THE TRAP THIS IS HERE FOR.**  A DBGIN page reset by the machine's own
  // reset is reset by its own modifier bit 1: the register that holds the bit
  // is cleared by the bit, the level becomes a one-tick pulse, and MIT's
  // sequence cannot be written at all.  `tb/cadr_dbgin_harness.sv` measured
  // that before it was understood, and the composition onto the board met it
  // a second time --- `cadr_machine` takes `mach_rst`, which the top level
  // makes out of `debuggee_reset`, so the page needs a reset of its own and
  // `cadr_memory_path.sv` has a `dbg_rst` port for it.  This harness is wired
  // the way the board is: the page takes `rst`, the arbiter and the register
  // block take `mach_rst`.
  long levels = 0;
  {
    // Write a 1.  The modifier takes DBD<2:0> at the strobe's trailing edge.
    uint32_t w = Ctl(kAModifier, false, 0x2);
    Request(w);
    Lift(w);
    b.Idle(8);
    if (!dut->debuggee_reset_o) Say("modifier bit 1 did not raise -DEBUGEE RESET");
    if (!dut->mach_rst_o) Say("-DEBUGEE RESET did not reach the machine's reset");
    // And it STANDS.  A pulse would be gone by now; two hundred ticks is
    // seven microcycles and far more than any edge could survive.
    b.Idle(200);
    if (!dut->debuggee_reset_o)
      Say("-DEBUGEE RESET did not stand: the level is a pulse, so MIT's "
          "\"write a 1 here then write a 0\" cannot be written");
    if (!dut->mach_rst_o) Say("the machine came out of reset with the level up");
    ++levels;
    // Then write a 0, which is the other half of the sequence.
    w = Ctl(kAModifier, false, 0x0);
    Request(w);
    Lift(w);
    b.Idle(8);
    if (dut->debuggee_reset_o) Say("-DEBUGEE RESET did not clear on a zero");
    b.Idle(8);
    if (dut->mach_rst_o) Say("the machine stayed in reset after the level cleared");
    ++levels;
    // And the port still answers, and the machine's own register block works
    // again --- a reset that wedged either would be a reset nobody could use.
    if (b.Read(CON_PAGE) != W_CONS) Say("the console stopped answering after a debuggee reset");
    if (b.Read(DBG_PAGE) != W_DBUG) Say("the cable stopped answering after a debuggee reset");
    const uint32_t s2 = CableCycle(SpyAddr(4), false, 0, true);
    if (static_cast<uint16_t>(s2 >> kDbdShift) != SpyPoison(4))
      Fail("a register read after the debuggee reset", s2 >> kDbdShift, SpyPoison(4));
  }

  const long swept_con = by[kCon], swept_dbg = by[kDbg], swept_dflt = by[kDflt];
  (void)Name;

  delete dut;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::printf(
      "ok: `M_AXI_GP1` answers every address it was asked, in both directions\n"
      "    all %ld pages of the port read, and the word each gave says which\n"
      "      slave answered: no address in the gigabyte falls through\n"
      "    %ld reads and %ld writes swept over the window --- every word of the\n"
      "      two pages and a spread over the rest of the gigabyte: %ld to the\n"
      "      console, %ld to the debug cable, %ld to the default slave, each\n"
      "      identified BY ITS OWN REPLY, the two faces' UNMAPPED words being\n"
      "      different words\n"
      "    %ld rounds with a write and a read to different pages in flight\n"
      "      together, which is the only stimulus that sees one selection\n"
      "      serving both channels\n"
      "    %ld bursts, three of them ending on a page's last word\n"
      "    %ld of the sixteen diagnostic registers reached BY BOTH ROADS the\n"
      "      port now has --- `spy_read` through the console's page and a\n"
      "      -DB NEED UB cycle over MIT's cable through the window's --- each\n"
      "      giving the word the harness's own `spy_rdata` supplied\n"
      "    the error status read over the cable as 0xff00 | status, the high\n"
      "      byte being the open cable's pull-ups and not the adapter's\n"
      "    a console cycle asked for while a cable cycle stood: the debug\n"
      "      master first, the console bounded, the port answering both\n"
      "    %ld halves of MIT's own reset sequence over the cable --- write a 1\n"
      "      here then write a 0 --- with the level STANDING two hundred ticks\n"
      "      in between, which a page reset by its own modifier bit could not\n"
      "      do, and the register block reachable again afterwards\n"
      "    every address, length and ID poisoned the tick its handshake was\n"
      "      done, so a match that is read rather than held routes elsewhere\n"
      "    %ld responses and read beats held until they were taken\n",
      pages, reads, writes, swept_con, swept_dbg, swept_dflt, crossed, bursts,
      both, levels, b.stalls);
  return 0;
}
