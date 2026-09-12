// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `M_AXI_GP0` with four slaves on it, held to the one property the whole
// arrangement exists for: **every address on the port is answered, in both
// directions, by the slave the map names and by no other.**
//
// WHY THAT IS THE PROPERTY.  A read on GP0 that nothing in the fabric
// answers does not fault the Arm; it hangs both cores at one PC each.
// Measured on this board: the pack feeder read the register face at
// 0x4000_0000 on a bitstream without the pack side, nothing drove ARREADY,
// and both cores stood at one PC for as long as anyone looked.  No software
// guard can catch a load that never completes, so the rule is that the
// fabric which owns the port answers all of it --- and a decode that lets
// three faces share the port is the one thing that can break that rule
// silently.
//
// **IT IS DEMONSTRATED AND NOT ASSERTED.**  Each of the four slaves answers
// with something only it can answer, so which one took a transaction is READ
// OFF the reply:
//
//     the pack side    "PACK" at its word 7, and SLVERR outside its own
//                      sixteen words --- an answer, and a distinctive one
//     the Chaosnet     "CHAO" at word 0, zero and OKAY at an undefined word
//     the serial line  "SERI" at word 0, zero and OKAY at an undefined word
//     everything else  "NONE" at every address, OKAY
//
// So a read of any address in the gigabyte says which slave replied, and the
// sweep below covers every word of the three pages --- 3,072 of them --- and a
// spread over the rest of the window: every page up to the sixteenth, every
// power of two, the first and last word of the port, and a pseudo-random
// sample.  A transaction that does not complete inside a bound is reported as
// the board's frozen cores rather than waited for.
//
// **AND THE TWO NEW FACES ARE HELD TO THE CARD ON THE OTHER SIDE OF THEM.**
// `cadr_chaos_cable.sv` and `cadr_serial_line.sv` are the far ends of the
// I/O board's two cables, so the check that matters is read-back across the
// whole seam: a frame the machine transmits must come out of the TX window
// with the source and the check word the 9401 would have appended, a frame
// written into the RX window must come back out of the card word for word
// with the bit counter AIM-628 names, a character the machine transmits must
// come out of `RDATA`, and a character written to `WDATA` must come out of
// the card's own data register.  The card is driven through its Unibus
// exactly as `tb/cadr_io_board_tb.cpp` drives it; `build/iob.pass` is what
// holds the card to muir, and this holds the two halves meeting.
//
// **A WRITE AND A READ TO DIFFERENT PAGES RUN TOGETHER**, because that is
// the one stimulus that can see a splitter with one held selection serving
// both channels --- the memory path's "two decode instances, not one muxed
// decode" lesson in a second place.  A stimulus that only ever had one
// channel busy would pass a splitter that routed a read to whichever slave a
// concurrent write had chosen.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vcadr_gp0_split_harness.h"
#include "verilated.h"

namespace {

const uint32_t GP0_BASE = 0x40000000u;
const uint32_t GP0_TOP  = 0x7FFFFFFCu;
const uint32_t PACK_PAGE = 0x40000000u;
const uint32_t CHAOS_PAGE = 0x40001000u;
const uint32_t SER_PAGE = 0x40002000u;

const uint32_t W_PACK = 0x5041434Bu;   // "PACK"
const uint32_t W_CHAO = 0x4348414Fu;   // "CHAO"
const uint32_t W_SERI = 0x53455249u;   // "SERI"
const uint32_t W_NONE = 0x4E4F4E45u;   // "NONE"

// The two windows, as word offsets into the Chaosnet page --- `+0x400` and
// `+0x800` in bytes, which is what `chaos_face.h`'s own two constants say.
const uint32_t CH_TX_WIN = 0x100u;
const uint32_t CH_RX_WIN = 0x200u;

// The card's own registers, Unibus byte addresses in octal.
const unsigned UB_CH_CSR    = 0764140;
const unsigned UB_CH_MYADDR = 0764142;   // read MY ADDRESS, written the buffer
const unsigned UB_CH_RDBUF  = 0764144;
const unsigned UB_CH_BITS   = 0764146;
const unsigned UB_CH_START  = 0764152;
const unsigned UB_SER_DATA  = 0764160;
const unsigned UB_SER_STAT  = 0764162;
const unsigned UB_SER_MODE  = 0764164;
const unsigned UB_SER_CMD   = 0764166;

// `muir::serial::DIVISORS`, Table 1: the crystal periods in one 16X clock.
const unsigned DIVISORS[16] = {6336, 4224, 2880, 2355, 2112, 1056, 528, 264,
                               176,  158,  132,  88,   66,   44,   33,  16};
const unsigned BRCLK_HZ = 5068800u;
const unsigned CLK_HZ = 100000000u;

int bad = 0;
long tick = 0;

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  if (bad < 25) {
    std::fprintf(stderr, "tick %ld: %s is 0x%llx (%llu), wanting 0x%llx (%llu)\n",
                 tick, what, got, got, want, want);
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

uint32_t seed = 0x3D9A17C5u;
uint32_t rnd() {
  seed = seed * 1664525u + 1013904223u;
  return seed >> 8;
}

// `muir::chaos::packet::check_word`: the Fairchild 9401 at LMTBUF C09
// dividing by CRC-16, `x^16 + x^15 + x^2 + 1`, from a cleared register, over
// the words in the order written, each most significant bit first.  The one
// arrangement that reproduces the word the netlist board produced ---
// `chaos_test_packet.c` holds the same eight lines against the board's own
// 0135771.
uint16_t CheckWord(const std::vector<uint16_t> &words) {
  uint32_t r = 0;
  for (uint16_t w : words) {
    for (int k = 15; k >= 0; --k) {
      const bool d = (w >> k) & 1;
      const bool fb = d ^ ((r >> 15) & 1);
      uint32_t next = (r << 1) & 0xFFFF;
      if (fb) next ^= (1u | (1u << 2) | (1u << 15));
      r = next;
    }
  }
  return (uint16_t)r;
}

// `muir::serial::Framing::half_bits` off mode register 1, and the frame in
// fabric ticks at a rate: `half_bits * 8` 16X clocks, each `DIVISORS[rate]`
// crystal periods, each `CLK_HZ / BRCLK_HZ` ticks.
unsigned HalfBits(unsigned mr1) {
  const unsigned bits = 5 + ((mr1 >> 2) & 3);
  const unsigned parity = (mr1 & 0x10) ? 2 : 0;
  unsigned stop = 2;
  if (((mr1 >> 6) & 3) == 2) stop = 3;
  if (((mr1 >> 6) & 3) == 3) stop = 4;
  return 2 + 2 * bits + parity + stop;
}

double FrameTicks(unsigned mr1, unsigned rate) {
  const double x16 = (double)DIVISORS[rate & 0xF] * (double)CLK_HZ / (double)BRCLK_HZ;
  return (double)HalfBits(mr1) * 8.0 * x16;
}

// ---------------------------------------------------------------- the bus

struct WTxn {
  uint32_t addr = 0;
  std::vector<uint32_t> data;
  uint32_t strb = 0xF;
  unsigned id = 0;
  int resp = -1;
  int bs = 0;          // responses seen
  unsigned beats = 0;  // data beats accepted
  bool aw = false;     // the address was accepted
  int aws = 0;         // address handshakes seen
  bool done = false;
};

struct RTxn {
  uint32_t addr = 0;
  unsigned len = 0;   // ARLEN: beats minus one
  unsigned id = 0;
  std::vector<uint32_t> data;
  int resp = -1;      // the first beat's RRESP; every beat is checked equal
  bool ar = false;
  int ars = 0;
  bool done = false;
};

struct Bus {
  Vcadr_gp0_split_harness *d;
  long aw_total = 0, w_total = 0, b_total = 0, ar_total = 0, r_total = 0;
  long stalls = 0;

  explicit Bus(Vcadr_gp0_split_harness *dut) : d(dut) {}

  void Quiet() {
    d->m_awvalid = 0; d->m_wvalid = 0; d->m_bready = 0;
    d->m_arvalid = 0; d->m_rready = 0;
    d->m_wlast = 0;
  }

  // One tick: the inputs are what the edge samples, the outputs what is seen
  // before it.  Nothing after the edge is looked at, which is the convention
  // every testbench here uses and the one that does not put an answer a tick
  // late.
  void Step() {
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
    const long kBound = 6000;
    int aw_hold = (int)(rnd() % 3), w_hold = (int)(rnd() % 3);
    int b_hold = (int)(rnd() % 3), ar_hold = (int)(rnd() % 3);
    int r_hold = (int)(rnd() % 3);
    if (w) { w->beats = 0; w->bs = 0; w->aws = 0; w->aw = false; w->done = false; }
    if (r) { r->data.clear(); r->ars = 0; r->ar = false; r->done = false; }
    while ((w && !w->done) || (r && !r->done)) {
      // --- what the master offers this tick.
      //
      // **THE ADDRESS, THE LENGTH AND THE ID ARE POISONED THE MOMENT THEIR
      // HANDSHAKE IS DONE**, which AXI allows and a real interconnect does:
      // once AWVALID met AWREADY the channel is free and the master may put
      // anything on it.  The poison is the complement, which lands outside
      // the port's window --- so a slave or a splitter that read the LIVE
      // address rather than the one it captured routes the rest of the
      // transaction somewhere else, and a stimulus that politely held the
      // address still would never have said so.  That is this project's own
      // "a stimulus more polite than the real consumer tests less", and it
      // is what makes the held match checkable rather than merely written
      // down.
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

  // One word, and the response beside it.
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

  // ------------------------------------------------------------- the Unibus
  //
  // The card's own bus, driven as `tb/cadr_io_board_tb.cpp` drives it: the
  // strobe up with the address, spun until `-UB SSYN`, then down.  The
  // earliest this card can answer is fifty ticks after the strobe.
  unsigned Ub(unsigned addr, int write, unsigned wdata) {
    d->ub_msyn = 1;
    d->ub_addr = addr;
    d->ub_write = write;
    d->ub_wdata = wdata;
    long waited = 0;
    unsigned got = 0;
    while (waited < 2000) {
      d->clk = 0; d->eval();
      if (d->ub_ssyn) { got = d->ub_rdata; break; }
      d->clk = 1; d->eval();
      ++tick;
      ++waited;
    }
    if (waited >= 2000) Fail("the card never answered a Unibus cycle", 0, 1);
    d->clk = 1; d->eval();
    ++tick;
    d->ub_msyn = 0;
    for (int k = 0; k < 3; ++k) Step();
    return got;
  }

  unsigned UbRead(unsigned addr) { return Ub(addr, 0, 0); }
  void UbWrite(unsigned addr, unsigned v) { (void)Ub(addr, 1, v); }
};

// Which slave the map says answers `addr`, and what that slave's reply looks
// like.  This is the map, written once, and the sweep compares against it.
enum Slave { kPack, kChaos, kSer, kDflt };

Slave Owner(uint32_t addr) {
  const uint32_t page = addr & 0xFFFFF000u;
  if (page == PACK_PAGE) return kPack;
  if (page == CHAOS_PAGE) return kChaos;
  if (page == SER_PAGE) return kSer;
  return kDflt;
}

const char *Name(Slave s) {
  switch (s) {
    case kPack: return "the pack side";
    case kChaos: return "the Chaosnet cable";
    case kSer: return "the serial line";
    default: return "the default slave";
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_gp0_split_harness;
  Bus b(dut);

  dut->rst = 1;
  b.Quiet();
  dut->ub_msyn = 0; dut->ub_write = 0; dut->ub_addr = 0; dut->ub_wdata = 0;
  dut->ub_init = 0;
  dut->m_awaddr = 0; dut->m_awlen = 0; dut->m_awid = 0;
  dut->m_wdata = 0; dut->m_wstrb = 0xF;
  dut->m_araddr = 0; dut->m_arlen = 0; dut->m_arid = 0;
  for (int k = 0; k < 8; ++k) b.Step();
  dut->rst = 0;
  b.Idle(4);

  // ======================================================================
  // The four are where the map says, and each says who it is
  // ======================================================================
  {
    int resp = 0;
    const uint32_t ident_pack = b.Read(PACK_PAGE + 4 * 7, &resp);
    if (ident_pack != W_PACK) FailAt(PACK_PAGE + 28, "the pack side's IDENT", ident_pack, W_PACK);
    if (resp != 0) FailAt(PACK_PAGE + 28, "RRESP at the pack's IDENT", resp, 0);
    const uint32_t ident_chaos = b.Read(CHAOS_PAGE, &resp);
    if (ident_chaos != W_CHAO) FailAt(CHAOS_PAGE, "the Chaosnet cable's IDENT", ident_chaos, W_CHAO);
    if (resp != 0) FailAt(CHAOS_PAGE, "RRESP at the Chaosnet IDENT", resp, 0);
    const uint32_t ident_ser = b.Read(SER_PAGE, &resp);
    if (ident_ser != W_SERI) FailAt(SER_PAGE, "the serial line's IDENT", ident_ser, W_SERI);
    if (resp != 0) FailAt(SER_PAGE, "RRESP at the serial IDENT", resp, 0);
    const uint32_t none = b.Read(GP0_BASE + 0x3000, &resp);
    if (none != W_NONE) FailAt(GP0_BASE + 0x3000, "the default slave's word", none, W_NONE);
    if (resp != 0) FailAt(GP0_BASE + 0x3000, "RRESP at the fourth page", resp, 0);
  }

  // ======================================================================
  // EVERY PAGE OF THE PORT, EXHAUSTIVELY
  // ======================================================================
  //
  // `M_AXI_GP0`'s window is 0x4000_0000 to 0x7FFF_FFFF, a gigabyte, which is
  // 262,144 pages of 4 KB.  Every one of them is read, and the word that
  // comes back says which slave answered: "CHAO" and "SERI" at the two the
  // map names, "NONE" at every other, and at the pack side's a word that is
  // neither --- its own first register, answered OKAY.  **A SAMPLE WOULD NOT
  // DO**, because a decode wrong by one bit is wrong on a set of pages a
  // sample can miss, and the whole point of the arrangement is that no
  // address falls through: one that does hangs both Arm cores at one PC each.
  // This is `cadr_xbus_decode`'s exhaustive shape, on the one port where an
  // unanswered address is not a wrong answer but a stopped processor.
  //
  // The handshakes vary here as everywhere --- `Read` holds its valid and
  // ready for a random few ticks --- so this is not a faster, politer
  // stimulus than the sweep below; it is the same one, over every page.
  long pages = 0;
  {
    for (uint32_t page = 0; page < 262144u && bad < 25; ++page) {
      const uint32_t addr = GP0_BASE + (page << 12);
      int resp = -1;
      const uint32_t got = b.Read(addr, &resp);
      ++pages;
      if (resp != 0) FailAt(addr, "RRESP at a page's first word", resp, 0);
      switch (Owner(addr)) {
        case kChaos:
          if (got != W_CHAO) FailAt(addr, "the word at the Chaosnet page", got, W_CHAO);
          break;
        case kSer:
          if (got != W_SERI) FailAt(addr, "the word at the serial page", got, W_SERI);
          break;
        case kPack:
          // The pack side's word 0 is its ADDR register, which holds
          // whatever was last written to it --- so what is held here is that
          // the DEFAULT slave did not answer the pack's page.
          if (got == W_NONE)
            FailAt(addr, "the word at the pack's page: the default slave answered it",
                   got, 0);
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
  // What each slave's reply must look like at an address with nothing
  // behind it.  The three faces answer zero and OKAY; the pack side answers
  // SLVERR outside its own sixteen words, which is its older and narrower
  // decision and is an answer all the same; the default answers "NONE".
  std::vector<uint32_t> sweep;
  for (uint32_t k = 0; k < 1024; ++k) {
    sweep.push_back(PACK_PAGE + 4 * k);
    sweep.push_back(CHAOS_PAGE + 4 * k);
    sweep.push_back(SER_PAGE + 4 * k);
  }
  for (uint32_t p = 3; p < 16; ++p) sweep.push_back(GP0_BASE + (p << 12));
  for (int s = 12; s < 30; ++s) {
    sweep.push_back(GP0_BASE + (1u << s));
    sweep.push_back(GP0_BASE + (1u << s) + 0xFFC);
  }
  sweep.push_back(GP0_BASE);
  sweep.push_back(GP0_TOP);
  sweep.push_back(GP0_BASE + 0x0FFC);
  sweep.push_back(GP0_BASE + 0x1FFC);
  sweep.push_back(GP0_BASE + 0x2FFC);
  sweep.push_back(GP0_BASE + 0x3FFC);
  for (int k = 0; k < 400; ++k)
    sweep.push_back((GP0_BASE + (rnd() & 0x3FFFFFFCu)) & 0x7FFFFFFCu);

  long reads = 0, writes = 0;
  long by[4] = {0, 0, 0, 0};
  for (uint32_t addr : sweep) {
    if (bad >= 25) break;
    const Slave s = Owner(addr);
    ++by[s];
    int resp = -1;
    const uint32_t got = b.Read(addr, &resp);
    ++reads;
    // The reply names the slave.  This is the whole demonstration: an
    // address routed to the wrong slave gives the wrong word or the wrong
    // response, and an address routed nowhere gives neither.
    switch (s) {
      case kDflt:
        if (got != W_NONE) FailAt(addr, "the reply, which should be the default's", got, W_NONE);
        if (resp != 0) FailAt(addr, "RRESP from the default slave", resp, 0);
        break;
      case kChaos:
      case kSer: {
        const uint32_t word = (addr & 0xFFFu) >> 2;
        if (resp != 0) FailAt(addr, "RRESP from a register face", resp, 0);
        if (got == W_NONE) FailAt(addr, "the reply: the default slave answered a register page", got, 0);
        // An undefined word of either face reads zero; the defined ones are
        // held below, register by register.
        const bool defined = (s == kChaos)
            ? (word <= 8 || (word >= 0x100 && word < 0x300))
            : (word <= 7);
        if (!defined && got != 0)
          FailAt(addr, "an undefined word of a register face", got, 0);
        break;
      }
      case kPack: {
        const uint32_t word = (addr & 0xFFFu) >> 2;
        if (got == W_NONE) FailAt(addr, "the reply: the default slave answered the pack's page", got, 0);
        if (word < 16) {
          if (resp != 0) FailAt(addr, "RRESP inside the pack's sixteen words", resp, 0);
        } else {
          // The pack side answers SLVERR outside its own window, in its
          // own page: `cadr_disk_pack.sv` says why.  An answer, and not a
          // hang, which is what this check is about.
          if (resp != 2) FailAt(addr, "RRESP outside the pack's sixteen words", resp, 2);
        }
        break;
      }
    }
  }

  // Writes over the same sweep.  Zero everywhere, so that no command bit of
  // any face is set: a `CTL` write with no bits set is a harmless probe by
  // each face's own rule, and a sweep that started a disk move or committed
  // a frame would be testing the slave rather than the decode.
  for (uint32_t addr : sweep) {
    if (bad >= 25) break;
    const Slave s = Owner(addr);
    const int resp = b.Write(addr, 0);
    ++writes;
    const uint32_t word = (addr & 0xFFFu) >> 2;
    const int want = (s == kPack && word >= 16) ? 2 : 0;
    if (resp != want) FailAt(addr, "BRESP", resp, want);
  }

  // ======================================================================
  // A WRITE AND A READ TO DIFFERENT PAGES, TOGETHER
  // ======================================================================
  //
  // The one stimulus that sees a splitter with one held selection for both
  // channels.  Each round writes one page's register and reads another
  // page's IDENT at the same time, and the read must come back from the
  // page it named.
  long crossed = 0;
  {
    struct Pair { uint32_t waddr, wdata; uint32_t raddr, rwant; };
    const Pair pairs[] = {
      {CHAOS_PAGE + 4 * 2, 0x1234u, SER_PAGE, W_SERI},
      {SER_PAGE + 4 * 4, 0u, CHAOS_PAGE, W_CHAO},
      {CHAOS_PAGE + 4 * 4, 0u, PACK_PAGE + 4 * 7, W_PACK},
      {GP0_BASE + 0x5000, 0u, CHAOS_PAGE, W_CHAO},
      {SER_PAGE + 4 * 4, 0u, GP0_BASE + 0x9000, W_NONE},
      {PACK_PAGE + 4 * 2, 0u, SER_PAGE, W_SERI},
      {CHAOS_PAGE + 4 * 2, 0x1234u, GP0_BASE + 0x11000, W_NONE},
      {GP0_BASE + 0x7000, 0u, SER_PAGE, W_SERI},
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
        if (w.resp != 0) FailAt(p.waddr, "BRESP with a read in flight", w.resp, 0);
        if (r.data.empty() || r.data[0] != p.rwant)
          FailAt(p.raddr, "the word a read gave with a write to another page in flight",
                 r.data.empty() ? 0 : r.data[0], p.rwant);
      }
    }
  }

  // ======================================================================
  // BURSTS, AND A BURST AT THE END OF A PAGE
  // ======================================================================
  long bursts = 0;
  {
    // A burst of reads across a face's registers walks the address up a word
    // a beat, so the beats are the registers in order.  The Chaosnet page's
    // words 0 and 1 are IDENT and STAT.
    RTxn r;
    r.addr = CHAOS_PAGE;
    r.len = 8;
    r.id = 0x321;
    b.Run(nullptr, &r);
    ++bursts;
    if (r.data.size() == 9) {
      if (r.data[0] != W_CHAO) FailAt(CHAOS_PAGE, "a burst's first beat", r.data[0], W_CHAO);
      // The third beat is MYADDR, which the rounds above left at 0x1234:
      // a burst walks the address up a word a beat, so the beats ARE the
      // registers in order and the value says the walk is right.
      if (r.data[2] != 0x1234u)
        FailAt(CHAOS_PAGE + 8, "a burst's third beat, MYADDR", r.data[2], 0x1234u);
    }
    // And a burst of writes: sixteen beats into the Chaosnet's RX window,
    // then the same sixteen read back.
    WTxn w;
    w.addr = CHAOS_PAGE + 4 * CH_RX_WIN;
    for (unsigned k = 0; k < 16; ++k) w.data.push_back(0x1000u + k);
    w.id = 0x111;
    b.Run(&w, nullptr);
    ++bursts;
    if (w.resp != 0) Fail("BRESP for a sixteen-beat write", w.resp, 0);
    RTxn back;
    back.addr = CHAOS_PAGE + 4 * CH_RX_WIN;
    back.len = 15;
    back.id = 0x222;
    b.Run(nullptr, &back);
    ++bursts;
    for (unsigned k = 0; k < back.data.size(); ++k) {
      if (back.data[k] != 0x1000u + k)
        FailAt(CHAOS_PAGE + 4 * (CH_RX_WIN + k), "a word of the RX window read back",
               back.data[k], 0x1000u + k);
    }
    // A sixteen-beat read whose last beat is the page's last word.  AXI
    // forbids a burst that crosses a 4 KB boundary, so this is the longest
    // legal one there --- and it must terminate whatever the face's own
    // arithmetic does with the offset.
    RTxn edge;
    edge.addr = SER_PAGE + 0xFC0;
    edge.len = 15;
    edge.id = 0x0AB;
    b.Run(nullptr, &edge);
    ++bursts;
    for (uint32_t v : edge.data)
      if (v != 0) FailAt(SER_PAGE + 0xFC0, "a beat at the end of the serial page", v, 0);
  }

  // ======================================================================
  // THE BYTE STROBES
  // ======================================================================
  {
    // The Chaosnet's MYADDR is sixteen bits and a `writeb` must reach one
    // byte of it.  Written whole, then one byte, then read back.
    b.Write(CHAOS_PAGE + 4 * 2, 0xFFFFu);
    uint32_t got = b.Read(CHAOS_PAGE + 4 * 2);
    if (got != 0xFFFFu) FailAt(CHAOS_PAGE + 8, "MYADDR written whole", got, 0xFFFFu);
    b.Write(CHAOS_PAGE + 4 * 2, 0x00A5u, 0x1);
    got = b.Read(CHAOS_PAGE + 4 * 2);
    if (got != 0xFFA5u) FailAt(CHAOS_PAGE + 8, "MYADDR with the low byte strobed", got, 0xFFA5u);
    b.Write(CHAOS_PAGE + 4 * 2, 0x5A00u, 0x2);
    got = b.Read(CHAOS_PAGE + 4 * 2);
    if (got != 0x5AA5u) FailAt(CHAOS_PAGE + 8, "MYADDR with the high byte strobed", got, 0x5AA5u);
    // A write with no strobes at all changes nothing and is still answered.
    const int resp = b.Write(CHAOS_PAGE + 4 * 2, 0xFFFFu, 0x0);
    if (resp != 0) Fail("BRESP for a write with no byte strobed", resp, 0);
    got = b.Read(CHAOS_PAGE + 4 * 2);
    if (got != 0x5AA5u) FailAt(CHAOS_PAGE + 8, "MYADDR after a write with no strobes", got, 0x5AA5u);
  }

  // ======================================================================
  // THE CHAOSNET CABLE, ACROSS THE SEAM
  // ======================================================================
  const uint16_t kMyAddr = 0003101;   // muir's own `CHAOS_ADDRESS`
  long frames_out = 0, frames_in = 0;
  {
    b.Write(CHAOS_PAGE + 4 * 2, kMyAddr);
    if (b.Read(CHAOS_PAGE + 4 * 2) != kMyAddr)
      Fail("MYADDR read back", b.Read(CHAOS_PAGE + 4 * 2), kMyAddr);
    // The switches are what the machine reads at MY ADDRESS, so the card
    // sees them through the seam.
    const unsigned mine = b.UbRead(UB_CH_MYADDR);
    if (mine != kMyAddr) Fail("MY ADDRESS as the machine reads it", mine, kMyAddr);

    // --- a frame the machine transmits.  Eight header words and the cable
    // destination, which is what AIM-628 says the software writes.
    std::vector<uint16_t> buffer = {
      0001000, 0000012, 0003102, 0000001, 0003101, 0000002, 0000003, 0000004,
      0x4142, 0x4344, 0x4546, 0003102
    };
    for (uint16_t w : buffer) b.UbWrite(UB_CH_MYADDR, w);
    // Reading START is what sends it.
    const unsigned started = b.UbRead(UB_CH_START);
    if (started != kMyAddr) Fail("a read of START, which is MY ADDRESS again", started, kMyAddr);
    // The card bursts the buffer out a word a tick from the tick after; the
    // cable takes it, appends the source and the check word and offers it.
    long waited = 0;
    while (!(b.Read(CHAOS_PAGE + 4) & 1u) && waited < 40) ++waited;
    if (!(b.Read(CHAOS_PAGE + 4) & 1u)) Fail("STAT's TX_VALID after a START", 0, 1);
    ++frames_out;
    const uint32_t txlen = b.Read(CHAOS_PAGE + 4 * 3);
    if (txlen != buffer.size() + 2)
      Fail("TXLEN, the frame's words with the trailer", txlen, buffer.size() + 2);
    std::vector<uint16_t> all = buffer;
    all.push_back(kMyAddr);
    const uint16_t check = CheckWord(all);
    all.push_back(check);
    for (unsigned k = 0; k < all.size(); ++k) {
      const uint32_t got = b.Read(CHAOS_PAGE + 4 * (CH_TX_WIN + k));
      if (got != all[k]) {
        const char *what = k + 2 < all.size() ? "a word of the frame the machine transmitted"
                         : (k + 2 == all.size() ? "the source address the cable inserted"
                                                : "the check word the cable computed");
        FailAt(CHAOS_PAGE + 4 * (CH_TX_WIN + k), what, got, all[k]);
      }
    }
    // Taking it is what lets the machine's Transmit Done come up.
    if (b.UbRead(UB_CH_CSR) & 0200u)
      Fail("Transmit Done before the frame was taken", 1, 0);
    b.Write(CHAOS_PAGE + 4 * 5, 1u);
    if (b.Read(CHAOS_PAGE + 4) & 1u) Fail("STAT's TX_VALID after the frame was taken", 1, 0);
    if (b.Read(CHAOS_PAGE + 4 * 3) != 0) Fail("TXLEN with no frame waiting", 1, 0);
    const unsigned csr = b.UbRead(UB_CH_CSR);
    if (!(csr & 0200u)) Fail("Transmit Done after the frame was taken", csr, 0200u);

    // --- a frame the cable gives the machine.  The words are the buffer,
    // the source and the check word, as the machine reads them back.
    std::vector<uint16_t> in = {
      0002000, 0000006, 0003101, 0000005, 0003102, 0000006, 0000007, 0000010,
      0x5152, 0x5354, 0003101, 0
    };
    in.back() = CheckWord(std::vector<uint16_t>(in.begin(), in.end() - 1));
    for (unsigned k = 0; k < in.size(); ++k)
      b.Write(CHAOS_PAGE + 4 * (CH_RX_WIN + k), in[k]);
    b.Write(CHAOS_PAGE + 4 * 4, (uint32_t)in.size());
    if (b.Read(CHAOS_PAGE + 4 * 4) != in.size())
      Fail("RXLEN read back", b.Read(CHAOS_PAGE + 4 * 4), in.size());
    const uint32_t lost_before = b.Read(CHAOS_PAGE + 4 * 6);
    b.Write(CHAOS_PAGE + 4 * 5, 2u);
    // The stream is a word a tick and then the commit: give it room.
    b.Idle(600);
    ++frames_in;
    const uint32_t lost_after = b.Read(CHAOS_PAGE + 4 * 6);
    if (lost_after != lost_before)
      Fail("LOST moved for a frame the machine's buffer was empty for", lost_after, lost_before);
    const uint32_t stat = b.Read(CHAOS_PAGE + 4);
    if (!(stat & 2u)) Fail("STAT's RX_BUSY after a frame was stored", stat, 2u);
    if (stat & 4u) Fail("STAT's RX_ARMED with a packet unread", stat, 0u);
    // Receive Done, and the bit counter AIM-628 names: the bits minus one.
    const unsigned ccsr = b.UbRead(UB_CH_CSR);
    if (!(ccsr & 0100000u)) Fail("Receive Done as the machine reads it", ccsr, 0100000u);
    const unsigned bits = b.UbRead(UB_CH_BITS);
    if (bits != in.size() * 16 - 1)
      Fail("the bit counter, the bits minus one", bits, in.size() * 16 - 1);
    for (unsigned k = 0; k < in.size(); ++k) {
      const unsigned got = b.UbRead(UB_CH_RDBUF);
      if (got != in[k]) Fail("a word the machine read out of the receive buffer", got, in[k]);
    }
    const unsigned drained = b.UbRead(UB_CH_BITS);
    if (drained != 07777u) Fail("the bit counter once the packet is read out", drained, 07777u);

    // --- a frame given while the machine has not emptied its buffer is
    // refused and counted, which is the only way the program can tell.
    b.Write(CHAOS_PAGE + 4 * 4, (uint32_t)in.size());
    const uint32_t lost2_before = b.Read(CHAOS_PAGE + 4 * 6);
    b.Write(CHAOS_PAGE + 4 * 5, 2u);
    b.Idle(600);
    const uint32_t lost2_after = b.Read(CHAOS_PAGE + 4 * 6);
    if (lost2_after != lost2_before + 1)
      Fail("LOST for a frame refused on a full buffer", lost2_after, lost2_before + 1);

    // Clear Receiver lets the next one in, and the cable sees it.
    b.UbWrite(UB_CH_CSR, 010u);
    b.Idle(4);
    const uint32_t armed = b.Read(CHAOS_PAGE + 4);
    if (!(armed & 4u)) Fail("STAT's RX_ARMED after Clear Receiver", armed, 4u);
    if (armed & 2u) Fail("STAT's RX_BUSY after Clear Receiver", armed, 0u);
    b.Write(CHAOS_PAGE + 4 * 4, (uint32_t)in.size());
    const uint32_t lost3_before = b.Read(CHAOS_PAGE + 4 * 6);
    b.Write(CHAOS_PAGE + 4 * 5, 2u);
    b.Idle(600);
    ++frames_in;
    if (b.Read(CHAOS_PAGE + 4 * 6) != lost3_before)
      Fail("LOST for a frame the machine had room for", 1, 0);
    if (b.UbRead(UB_CH_BITS) != in.size() * 16 - 1)
      Fail("the bit counter for the second frame", b.UbRead(UB_CH_BITS), in.size() * 16 - 1);
    for (unsigned k = 0; k < in.size(); ++k) (void)b.UbRead(UB_CH_RDBUF);
    b.UbWrite(UB_CH_CSR, 010u);
    b.Idle(4);
  }

  // ======================================================================
  // THE SERIAL LINE, ACROSS THE SEAM
  // ======================================================================
  long chars_out = 0, chars_in = 0, looped = 0;
  double measured[2] = {0, 0};
  const unsigned kMr1 = 0x4E;    // asynchronous 16X, eight bits, no parity, one stop
  {
    // With the cable out nothing moves, which is what the tie-off this
    // replaces did: the take is gated on `-CTS`.
    if (b.Read(SER_PAGE + 4) & 2u) Fail("TX_ROOM with the cable out", 1, 0);
    // Program the chip over the Unibus.  A read of the command register
    // puts the mode pointer back, then MR1 and MR2 in that order.
    (void)b.UbRead(UB_SER_CMD);
    b.UbWrite(UB_SER_MODE, kMr1);
    b.UbWrite(UB_SER_MODE, 0x3F);    // rate 15, both halves on the generator
    b.UbWrite(UB_SER_CMD, 0x27);     // TxEN, RxEN, DTR, RTS
    // MODE reads back what the machine programmed, which is how
    // `serial_face_rate` learns the rate.
    const uint32_t mode = b.Read(SER_PAGE + 4 * 5);
    if ((mode & 0xFFu) != kMr1) Fail("MODE's MR1", mode & 0xFFu, kMr1);
    if (((mode >> 8) & 0xFFu) != 0x3Fu) Fail("MODE's MR2", (mode >> 8) & 0xFFu, 0x3Fu);
    if (((mode >> 16) & 0xFFu) != 0x27u) Fail("MODE's command register", (mode >> 16) & 0xFFu, 0x27u);
    if (((mode >> 8) & 0xFu) != 15u) Fail("the rate `serial_face_rate` reads", (mode >> 8) & 0xFu, 15u);
    // Plug the cable in: the three modem lines together.
    b.Write(SER_PAGE + 4 * 4, 7u);
    if (b.Read(SER_PAGE + 4 * 4) != 7u) Fail("CTL read back", b.Read(SER_PAGE + 4 * 4), 7u);
    b.Idle(4);
    const uint32_t st = b.Read(SER_PAGE + 4);
    if (!(st & 2u)) Fail("TX_ROOM with the cable in and the receiver on", st, 2u);
    if (!(st & 4u)) Fail("STAT's TX_ON", st, 4u);
    if (!(st & 8u)) Fail("STAT's RX_ON", st, 8u);

    // --- a character the machine transmits, at two rates, so that the
    // generator's own arithmetic is measured and not merely exercised.
    const unsigned rates[2] = {15, 12};
    const unsigned mr2s[2] = {0x3F, 0x3C};
    const unsigned chars[2] = {0xD5, 0x41};
    for (int i = 0; i < 2 && bad < 25; ++i) {
      if (i > 0) {
        (void)b.UbRead(UB_SER_CMD);
        b.UbWrite(UB_SER_MODE, kMr1);
        b.UbWrite(UB_SER_MODE, mr2s[i]);
      }
      const double want = FrameTicks(kMr1, rates[i]);
      const long bound = (long)(want * 1.5) + 20000;
      const long at = tick;
      b.UbWrite(UB_SER_DATA, chars[i]);
      // Bounded in TICKS and not in reads: a frame at 4,800 baud is 208,000
      // of them and a loop counted in polls is a loop whose length depends
      // on how many ticks a poll happens to take.
      while (!(b.Read(SER_PAGE + 4) & 1u) && tick - at < bound) { }
      const long span = tick - at;
      if (!(b.Read(SER_PAGE + 4) & 1u)) {
        Fail("a character the machine transmitted never reached the line", 0, 1);
        break;
      }
      ++chars_out;
      measured[i] = (double)span;
      // The take is the first 16X clock at or after the load, so the span is
      // the frame plus up to one 16X clock, plus the bus cycles either side.
      // A wrong divisor is a factor out and a wrong frame length a tenth,
      // so a fifth is a bound that catches both and tolerates neither.
      if ((double)span < want || (double)span > want * 1.2 + 2000.0)
        Fail("the ticks a character's frame took", (unsigned long long)span,
             (unsigned long long)want);
      const uint32_t rd = b.Read(SER_PAGE + 4 * 2);
      if (!(rd & 0x100u)) Fail("RDATA's valid bit", rd, 0x100u);
      if ((rd & 0xFFu) != chars[i]) Fail("the character RDATA gave", rd & 0xFFu, chars[i]);
      // The read consumed it.
      if (b.Read(SER_PAGE + 4) & 1u) Fail("STAT's RX_VALID after RDATA was read", 1, 0);
      const uint32_t again = b.Read(SER_PAGE + 4 * 2);
      if (again & 0x100u) Fail("RDATA's valid bit on a second read", again, 0u);
    }
    // The two rates are DIVISORS[12] / DIVISORS[15] apart: 66 against 16.
    if (measured[0] > 0 && measured[1] > 0) {
      const double ratio = measured[1] / measured[0];
      const double want = (double)DIVISORS[12] / (double)DIVISORS[15];
      if (ratio < want * 0.9 || ratio > want * 1.1)
        Fail("the ratio of two rates' frames, in hundredths",
             (unsigned long long)(ratio * 100), (unsigned long long)(want * 100));
    }

    // --- a character the cable gives the machine.  Back at rate 15.
    (void)b.UbRead(UB_SER_CMD);
    b.UbWrite(UB_SER_MODE, kMr1);
    b.UbWrite(UB_SER_MODE, 0x3F);
    b.Idle(4);
    const uint32_t before = b.Read(SER_PAGE + 4);
    if (!(before & 2u)) Fail("TX_ROOM before a character is offered", before, 2u);
    b.Write(SER_PAGE + 4 * 3, 0x51u);
    // It takes its frame time, so the room goes while it is on its way:
    // that is what rate-limits a program which reads a socket in bursts.
    if (b.Read(SER_PAGE + 4) & 2u)
      Fail("TX_ROOM while a character is on its way in", 1, 0);
    if ((b.Read(SER_PAGE + 4 * 3) & 0x1FFu) != 0x151u)
      Fail("WDATA read back with the character on its way",
           b.Read(SER_PAGE + 4 * 3) & 0x1FFu, 0x151u);
    const long in_bound = (long)(FrameTicks(kMr1, 15) * 1.5) + 20000;
    long in_at = tick;
    while (!(b.UbRead(UB_SER_STAT) & 2u) && tick - in_at < in_bound) { }
    if (!(b.UbRead(UB_SER_STAT) & 2u)) {
      Fail("RxRDY: the machine never saw the character", 0, 1);
    } else {
      ++chars_in;
      const unsigned got = b.UbRead(UB_SER_DATA) & 0xFFu;
      if (got != 0x51u) Fail("the character the machine received", got, 0x51u);
      if (b.UbRead(UB_SER_STAT) & 2u) Fail("RxRDY after the machine read the character", 1, 0);
    }
    if (!(b.Read(SER_PAGE + 4) & 2u)) Fail("TX_ROOM once the character has landed", 0, 2u);

    // --- and a character offered with no room is dropped, not queued.
    b.Write(SER_PAGE + 4 * 3, 0x52u);
    const uint32_t busy = b.Read(SER_PAGE + 4);
    if (busy & 2u) Fail("TX_ROOM with a character already on its way", 1, 0);
    b.Write(SER_PAGE + 4 * 3, 0x53u);     // refused: no room
    in_at = tick;
    while (!(b.UbRead(UB_SER_STAT) & 2u) && tick - in_at < in_bound) { }
    const unsigned second = b.UbRead(UB_SER_DATA) & 0xFFu;
    if (second != 0x52u)
      Fail("the character the machine received: the refused one must be lost, not queued",
           second, 0x52u);

    // --- the cable coming out stops the port, both halves.
    b.Write(SER_PAGE + 4 * 4, 0u);
    b.Idle(8);
    const uint32_t out = b.Read(SER_PAGE + 4);
    if (out & 2u) Fail("TX_ROOM with the cable pulled out", 1, 0);

    // --- LOCAL LOOP BACK WITH THE CABLE OUT, which is the one leg that
    // exercises the nine lines the line side transcribes from the card.
    // There `-CTS` is the command register's own RTS and `-DCD` its DTR, so
    // the chip runs with nothing plugged in: the character the machine
    // writes goes to its OWN receiver and never to the cable.  A line side
    // that took `-CTS` from `ser_plugged` alone would never pace the frame
    // and the machine's transmitter would stop at the first character.
    (void)b.UbRead(UB_SER_CMD);
    b.UbWrite(UB_SER_MODE, kMr1);
    b.UbWrite(UB_SER_MODE, 0x3F);
    b.UbWrite(UB_SER_CMD, 0xA7);     // local loop back, TxEN, RxEN, DTR, RTS
    b.Idle(4);
    if (b.Read(SER_PAGE + 4) & 1u) Fail("a character waiting before the loop back", 1, 0);
    b.UbWrite(UB_SER_DATA, 0x7Eu);
    const long loop_bound = (long)(FrameTicks(kMr1, 15) * 1.5) + 20000;
    const long loop_at = tick;
    while (!(b.UbRead(UB_SER_STAT) & 2u) && tick - loop_at < loop_bound) { }
    if (!(b.UbRead(UB_SER_STAT) & 2u)) {
      Fail("the machine's own receiver in local loop back", 0, 1);
    } else {
      ++looped;
      const unsigned back = b.UbRead(UB_SER_DATA) & 0xFFu;
      if (back != 0x7Eu) Fail("the character the loop back returned", back, 0x7Eu);
    }
    // And nothing reached the cable, which is what loop back means.
    if (b.Read(SER_PAGE + 4) & 1u)
      Fail("a character on the cable in local loop back", 1, 0);
    b.UbWrite(UB_SER_CMD, 0x27);
  }

  // ======================================================================
  // AND THE INTERRUPTS THE TWO FACES RAISE
  // ======================================================================
  {
    // The Chaosnet's is masked: with IRQEN zero nothing reaches `IRQ_F2P`
    // however the bits stand, which is what lets a program poll instead.
    b.Write(CHAOS_PAGE + 4 * 8, 0u);
    b.Idle(2);
    if (dut->chaos_irq) Fail("the Chaosnet interrupt with IRQEN zero", 1, 0);
    // A frame waiting sets bit 0, and with the mask on it reaches the PS.
    std::vector<uint16_t> one = {0001000, 0000000, 0003102, 0, 0, 0, 0, 0, 0003102};
    for (uint16_t w : one) b.UbWrite(UB_CH_MYADDR, w);
    (void)b.UbRead(UB_CH_START);
    b.Idle(40);
    const uint32_t irq = b.Read(CHAOS_PAGE + 4 * 7);
    if (!(irq & 1u)) Fail("IRQ bit 0 with a frame waiting", irq, 1u);
    b.Write(CHAOS_PAGE + 4 * 8, 1u);
    b.Idle(2);
    if (!dut->chaos_irq) Fail("the Chaosnet interrupt with the mask on", 0, 1);
    // A 1 written clears the bit, and the interrupt with it.
    b.Write(CHAOS_PAGE + 4 * 7, 1u);
    b.Idle(2);
    if (b.Read(CHAOS_PAGE + 4 * 7) & 1u) Fail("IRQ bit 0 after a 1 was written", 1, 0);
    if (dut->chaos_irq) Fail("the Chaosnet interrupt after the bit was cleared", 1, 0);
    b.Write(CHAOS_PAGE + 4 * 5, 1u);     // take the frame
    b.Write(CHAOS_PAGE + 4 * 8, 0u);
  }

  // ======================================================================
  // `-UB INIT` REACHES BOTH FACES
  // ======================================================================
  {
    // A frame waiting, then the machine's own Reset: the frame goes and the
    // count of resets moves, and `LOST` does NOT go backwards --- the one
    // thing that would make `chaos_face_give` read a store as a refusal.
    std::vector<uint16_t> one = {0001000, 0, 0003102, 0, 0, 0, 0, 0, 0003102};
    for (uint16_t w : one) b.UbWrite(UB_CH_MYADDR, w);
    (void)b.UbRead(UB_CH_START);
    b.Idle(40);
    if (!(b.Read(CHAOS_PAGE + 4) & 1u)) Fail("a frame waiting before the reset", 0, 1);
    const uint32_t lost = b.Read(CHAOS_PAGE + 4 * 6);
    const uint32_t resets = b.Read(CHAOS_PAGE + 4 * 5) >> 8;
    dut->ub_init = 1;
    b.Idle(4);
    dut->ub_init = 0;
    b.Idle(8);
    if (b.Read(CHAOS_PAGE + 4) & 1u) Fail("a frame still waiting after Reset", 1, 0);
    if ((b.Read(CHAOS_PAGE + 4 * 5) >> 8) <= resets)
      Fail("CTL's count of the machine's resets", b.Read(CHAOS_PAGE + 4 * 5) >> 8, resets + 1);
    if (b.Read(CHAOS_PAGE + 4 * 6) != lost)
      Fail("LOST across a reset, which must not go backwards",
           b.Read(CHAOS_PAGE + 4 * 6), lost);
    // And the IDENTs still answer, which is the cheapest statement that the
    // whole arrangement survived it.
    if (b.Read(CHAOS_PAGE) != W_CHAO) Fail("the Chaosnet IDENT after a reset", b.Read(CHAOS_PAGE), W_CHAO);
    if (b.Read(SER_PAGE) != W_SERI) Fail("the serial IDENT after a reset", b.Read(SER_PAGE), W_SERI);
    if (b.Read(PACK_PAGE + 28) != W_PACK) Fail("the pack's IDENT after a reset", b.Read(PACK_PAGE + 28), W_PACK);
  }

  delete dut;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::printf(
      "ok: `M_AXI_GP0` answers every address it was asked, in both directions\n"
      "    all %ld pages of the port read, and the word each gave says which\n"
      "      slave answered: no address in the gigabyte falls through\n"
      "    %ld reads and %ld writes swept over the window --- every word of the\n"
      "      three pages and a spread over the rest of the gigabyte: %ld to the\n"
      "      pack side, %ld to the Chaosnet cable, %ld to the serial line,\n"
      "      %ld to the default slave, each identified BY ITS OWN REPLY\n"
      "    %ld rounds with a write and a read to different pages in flight\n"
      "      together, which is the only stimulus that sees one selection\n"
      "      serving both channels\n"
      "    %ld bursts, one of them ending on a page's last word; the byte\n"
      "      strobes reaching one byte of a sixteen-bit register\n"
      "    %ld frames out of the machine and %ld into it, the source address\n"
      "      and the check word compared against `packet::check_word`, the bit\n"
      "      counter against AIM-628, and a frame refused on a full buffer\n"
      "      counted in LOST\n"
      "    %ld characters out of the machine at two rates and %ld into it:\n"
      "      %.0f ticks a frame at 19,200 baud and %.0f at 4,800, against\n"
      "      %.0f and %.0f from `Framing::half_bits` and `DIVISORS`; and %ld\n"
      "      through local loop back with the cable out, which is the leg\n"
      "      that exercises the nine derivations the line transcribes\n"
      "    every address, length and ID poisoned the tick its handshake was\n"
      "      done, so a match that is read rather than held routes elsewhere\n"
      "    %ld responses and read beats held until they were taken\n",
      pages, reads, writes, by[kPack], by[kChaos], by[kSer], by[kDflt], crossed, bursts,
      frames_out, frames_in, chars_out, chars_in, measured[0], measured[1],
      FrameTicks(kMr1, 15), FrameTicks(kMr1, 12), looped, b.stalls);
  return 0;
}
