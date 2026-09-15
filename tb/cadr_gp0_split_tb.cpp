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
const uint32_t INPUT_PAGE = 0x40003000u;

const uint32_t W_PACK = 0x5041434Bu;   // "PACK"
const uint32_t W_CHAO = 0x4348414Fu;   // "CHAO"
const uint32_t W_SERI = 0x53455249u;   // "SERI"
const uint32_t W_INPT = 0x494E5054u;   // "INPT"
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
const unsigned UB_KBD_LOW    = 0764100;
const unsigned UB_KBD_HIGH   = 0764102;
const unsigned UB_MOUSE_Y    = 0764104;
const unsigned UB_MOUSE_X    = 0764106;
const unsigned UB_IOB_CSR    = 0764112;

// `muir::terminal::keyboard`: `FRAME` is `0o37 << 19 | SOURCE << 16` with
// `SOURCE` = 1, the new keyboard's source ID --- bits 23-19 "Reserved, must
// be 1's" and 18-16 the source --- so every up-down word has `word >> 16 ==
// 0o371`.  `UP` is bit 8, "1=key up, 0=key down", and the position is the
// low seven bits.
const uint32_t KBD_FRAME = (037u << 19) | (1u << 16);
const uint32_t KBD_UP = 1u << 8;
uint32_t KbdWord(unsigned position, bool up) {
  return KBD_FRAME | (up ? KBD_UP : 0u) | (position & 0177u);
}
// `keyboard::TABLE`, by position: enough of MIT's own table to type with.
const unsigned KEY_RUBOUT = 023;      // Named("Rubout")
const unsigned KEY_LSHIFT = 024;      // Shift(Shift)
const unsigned KEY_STATUS = 046;      // Named("Status"), and 0o46 is the
                                      // value `(LOC 6)` compares against
const unsigned KEY_A      = 0123;     // Char('a', 'A')
const unsigned KEY_RETURN = 0136;     // Named("Return")

// `cadr_input_cables.sv`'s eight words.
enum InReg { IN_IDENT = 0, IN_STAT = 1, IN_KEY = 2, IN_MOUSE = 3,
             IN_BUTTONS = 4, IN_CTL = 5, IN_LOST = 6, IN_LINES = 7 };
const uint32_t IN_ST_KBD_READY = 1u << 0;
const uint32_t IN_ST_MOUSE_READY = 1u << 1;
const uint32_t IN_ST_ROOM = 1u << 2;
const uint32_t IN_ST_OWES = 1u << 3;
const uint32_t IN_CTL_FLUSH = 1u << 0;
const unsigned IN_DEPTH = 16;

// `ioboard::FLOATING`: nothing drives `UBO8`-`UBO15` at the keyboard's high
// half, so the upper byte pulls up.
const unsigned UB_FLOATING = 0177400;

// `mouse::MOUSE_STEP_NS` = 16,000, on MIT's 5 ns grid.
const long MOUSE_STEP_T = 16000 / 5;
// `ioboard::KB_CLK_NS` = 8,000: how long the card may take to latch a
// change onto `NEW`.
const long KB_CLK_T = 8000 / 5;

// `muir::serial::DIVISORS`, Table 1: the crystal periods in one 16X clock.
const unsigned DIVISORS[16] = {6336, 4224, 2880, 2355, 2112, 1056, 528, 264,
                               176,  158,  132,  88,   66,   44,   33,  16};
const unsigned BRCLK_HZ = 5068800u;
// **MIT'S 5 ns GRID, AS THE TWO CONSTANTS ABOVE ALREADY USE IT.**  muir gives
// a frame in nanoseconds of the MACHINE's own time, and every instant in this
// file is turned into ticks by dividing by five --- `MOUSE_STEP_NS` and
// `KB_CLK_NS` above, `ceil(span / 5)` in the disk's trace, `USEC_PERIOD_T` on
// the card itself.  The board's tick is 10 ns and the machine therefore runs
// at half real time on purpose; its clocks disagree with the wall and agree
// with muir, which is the decision this project took and the serial line is
// part of the machine.  A frame measured against the real 100 MHz instead
// would be half this many ticks and the chip would run at twice the rate its
// software programmed, measured in the only clock the machine has.
const unsigned TICK_NS = 5u;

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

// `muir::serial::Framing::half_bits` off mode register 1, and the frame at a
// rate: `half_bits * 8` 16X clocks, each `DIVISORS[rate]` crystal periods of
// the 5.0688 MHz can at IOBSER 0A15.
unsigned HalfBits(unsigned mr1) {
  const unsigned bits = 5 + ((mr1 >> 2) & 3);
  const unsigned parity = (mr1 & 0x10) ? 2 : 0;
  unsigned stop = 2;
  if (((mr1 >> 6) & 3) == 2) stop = 3;
  if (((mr1 >> 6) & 3) == 3) stop = 4;
  return 2 + 2 * bits + parity + stop;
}

// `muir::serial::Framing::frame_ns`, transcribed: the nanoseconds a character
// occupies the wire, in the machine's own time.
double FrameNs(unsigned mr1, unsigned rate) {
  return (double)HalfBits(mr1) * 8.0 * (double)DIVISORS[rate & 0xF] *
         1000000000.0 / (double)BRCLK_HZ;
}

// And that frame in fabric ticks, on the grid.
double FrameTicks(unsigned mr1, unsigned rate) {
  return FrameNs(mr1, rate) / (double)TICK_NS;
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
enum Slave { kPack, kChaos, kSer, kInput, kDflt };

Slave Owner(uint32_t addr) {
  const uint32_t page = addr & 0xFFFFF000u;
  if (page == PACK_PAGE) return kPack;
  if (page == CHAOS_PAGE) return kChaos;
  if (page == SER_PAGE) return kSer;
  if (page == INPUT_PAGE) return kInput;
  return kDflt;
}

const char *Name(Slave s) {
  switch (s) {
    case kPack: return "the pack side";
    case kChaos: return "the Chaosnet cable";
    case kSer: return "the serial line";
    case kInput: return "the keyboard and mouse";
    default: return "the default slave";
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_gp0_split_harness;
  Bus b(dut);

  dut->rst = 1;
  // The card's own reset, which on the board is `mach_rst` and not the
  // port's: the two are released together here and are pulsed apart below,
  // where the input face's queue is held to emptying on a machine restart.
  dut->card_rst = 1;
  b.Quiet();
  dut->ub_msyn = 0; dut->ub_write = 0; dut->ub_addr = 0; dut->ub_wdata = 0;
  dut->ub_init = 0;
  dut->m_awaddr = 0; dut->m_awlen = 0; dut->m_awid = 0;
  dut->m_wdata = 0; dut->m_wstrb = 0xF;
  dut->m_araddr = 0; dut->m_arlen = 0; dut->m_arid = 0;
  for (int k = 0; k < 8; ++k) b.Step();
  dut->rst = 0;
  dut->card_rst = 0;
  b.Idle(4);

  // ======================================================================
  // THE AUTOBOOT TEST, BEFORE ANYTHING HAS BEEN WRITTEN
  // ======================================================================
  //
  // **THIS IS THE FIRST THING THE CHECK DOES BECAUSE IT IS THE FIRST THING
  // THE MACHINE DOES.**  Four instructions into microcode 323,
  // `sys/ucadr/uc-cadr.lisp` at `(LOC 6)` reads `0o764112` and
  // `(JUMP-IF-BIT-CLEAR (BYTE-FIELD 1 5) MD COLD-BOOT)`: `KBD READY` clear
  // is a cold boot and ready is a WARM one.  A board coming up with a word
  // waiting at that register therefore goes somewhere it was never asked to
  // go, and CLAUDE.md names this as the trap aimed at whatever carries keys.
  //
  // `cadr_input_cables.sv`'s first leg against it is that the ONLY source of
  // `kbd_strobe` is an AXI write.  So: from reset, with nothing written,
  // the card's `KBD READY` must be down and STAY down --- and muir had to
  // build the same leg, its `unibus.rs` recording what happened without one:
  // an un-reset receiver read the idle-high cable as twenty-four ones and
  // `KBD READY` was up 196 us after power-on for the microcode to find.
  //
  // It runs for a card's `KB CLK^` and more, so a face that strobed on its
  // own divider rather than on a write would have had several chances.
  {
    for (int k = 0; k < 6 && bad < 25; ++k) {
      b.Idle(KB_CLK_T);
      const unsigned csr = b.UbRead(UB_IOB_CSR);
      if (csr & 040u)
        Fail("KBD READY with nothing ever written to the input face --- the machine "
             "would take the WARM boot at (LOC 6)", csr, 0);
    }
    // And the mouse at rest reads as no mouse: `Encoders::default` sits at
    // phase 2, both lines of each pair HIGH on the cable, which the card's
    // 74LS14s turn into four quadrature bits of ZERO.  A face that came up
    // at phase 0 would read 0b0101 here and MOUSE READY would come up at the
    // first `KB CLK^`.
    const unsigned mx = b.UbRead(UB_MOUSE_X);
    if ((mx >> 12) != 0)
      Fail("the mouse's quadrature lines at rest, which muir's Encoders::default "
           "makes zero at the card", mx >> 12, 0);
    if ((mx & 07777u) != 0) Fail("the mouse's X count at rest", mx & 07777u, 0);
    const unsigned my = b.UbRead(UB_MOUSE_Y);
    if ((my & 07777u) != 0) Fail("the mouse's Y count at rest", my & 07777u, 0);
    if (b.UbRead(UB_IOB_CSR) & 020u) Fail("MOUSE READY with nothing ever moved", 1, 0);
  }

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
    const uint32_t ident_in = b.Read(INPUT_PAGE, &resp);
    if (ident_in != W_INPT) FailAt(INPUT_PAGE, "the input face's IDENT", ident_in, W_INPT);
    if (resp != 0) FailAt(INPUT_PAGE, "RRESP at the input IDENT", resp, 0);
    const uint32_t none = b.Read(GP0_BASE + 0x4000, &resp);
    if (none != W_NONE) FailAt(GP0_BASE + 0x4000, "the default slave's word", none, W_NONE);
    if (resp != 0) FailAt(GP0_BASE + 0x4000, "RRESP at the fifth page", resp, 0);
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
        case kInput:
          if (got != W_INPT) FailAt(addr, "the word at the input page", got, W_INPT);
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
    sweep.push_back(INPUT_PAGE + 4 * k);
  }
  for (uint32_t p = 4; p < 16; ++p) sweep.push_back(GP0_BASE + (p << 12));
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
  long by[5] = {0, 0, 0, 0, 0};
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
      case kSer:
      case kInput: {
        const uint32_t word = (addr & 0xFFFu) >> 2;
        if (resp != 0) FailAt(addr, "RRESP from a register face", resp, 0);
        if (got == W_NONE) FailAt(addr, "the reply: the default slave answered a register page", got, 0);
        // An undefined word of any of the three reads zero; the defined ones
        // are held below, register by register.
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
  // a frame would be testing the slave rather than the decode.  **The one
  // thing it does leave behind is a key word of zero on the input face**,
  // `KEY` being a register whose whole content is a word; the input section
  // below drains the card and flushes the queue before it begins, and says
  // so.
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
      {INPUT_PAGE + 4 * IN_BUTTONS, 0u, CHAOS_PAGE, W_CHAO},
      {SER_PAGE + 4 * 4, 0u, INPUT_PAGE, W_INPT},
      {INPUT_PAGE + 4 * IN_MOUSE, 0u, PACK_PAGE + 4 * 7, W_PACK},
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
  long chars_out = 0, chars_in = 0, looped = 0, in_span = 0;
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
      // **THE FRAME IS COMPARED AGAINST muir AND NOT AGAINST ITSELF.**  `want`
      // is `Framing::frame_ns` divided by MIT's 5 ns, so this is the
      // reference's own number and not a restatement of the module's
      // arithmetic in the testbench.  The take is the first 16X clock at or
      // after the load, so the span is the frame plus up to one 16X clock,
      // plus the bus cycles either side --- and nothing else.  Bounded both
      // ways at that, because a frame that is too LONG is as wrong as one
      // that is too short and a one-sided bound would say nothing about it.
      const double x16_t = (double)DIVISORS[rates[i] & 0xF] * 1000000000.0 /
                           (double)BRCLK_HZ / (double)TICK_NS;
      if ((double)span < want || (double)span > want + x16_t + 4000.0)
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
      // **AND IT TOOK ITS FRAME, WHICH IS THE HALF THAT WAS NOT BEING
      // ASKED.**  `ser_rx_end` is the receiver's frame end and it comes off
      // the same generator as the transmitter's, so the same wrong time base
      // sat here too --- and a loop that only waits for the character to
      // arrive passes a receiver that hands it over at once.  A machine given
      // characters faster than its own rate overruns, which is `SR4` and is
      // silent.
      in_span = tick - in_at;
      const double in_want = FrameTicks(kMr1, 15);
      if ((double)in_span < in_want)
        Fail("the ticks a character's frame into the machine took",
             (unsigned long long)in_span, (unsigned long long)in_want);
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
  // MIT'S OWN CHANNEL WALK, AND THE FRAME'S LENGTH AS THE THING THAT SAVES IT
  // ======================================================================
  //
  // `sys/io1/serial.lisp`'s `:RESET` makes three Unibus channels on vector
  // `0o264`, all with the status register `0o764162` as their CSR, and
  // `GET-UNIBUS-CHANNEL` pushes each new one to the FRONT of the vector's
  // list, so the microcode walks them RANDOM, OUTPUT, INPUT.  It reads each
  // channel's CSR, ANDs it with that channel's mask, services the FIRST
  // channel whose bits are set, and dismisses --- it does not go on walking.
  //
  //   RANDOM  mask 4  SR2 TxEMT/DSCHG   its data address IS the CSR, so
  //                                     "absorbing" is a status read
  //   OUTPUT  mask 1  SR0 TxRDY         loads the next character, or writes
  //                                     the command register to turn the
  //                                     transmitter off
  //   INPUT   mask 2  SR1 RxRDY         takes the character in
  //
  // RANDOM exists, in MIT's own comment, "for some serial pci chips which
  // seem to cause interrupts on modem transitions.  This absorbs these to
  // prevent the microcode from bombing because it can't find anyone to give
  // the interrupt to."  It is meant for DSCHG, which a status read clears.
  // It is NOT meant for TxEMT, which a status read does NOT clear --- the
  // sheet is explicit, and the diagnostic it documents (read the status
  // twice; SR2 still set with SR6 and SR7 unchanged means TxEMT) only works
  // because of that.  muir models both rules and so does `cadr_io_board.sv`,
  // and neither is at fault here.
  //
  // **WHAT KEEPS RANDOM OFF THE TRANSMITTER'S BACK IS TIME.**  TxEMT rises a
  // whole character frame after the holding register empties, and the
  // handler reloads within a walk of TxRDY, so SR2 is clear at every
  // interrupt the transmitter causes and OUTPUT is reached every time.  The
  // frame is the margin, and the margin is the thing this section measures
  // --- from the DRIVER's side, in the driver's own terms, rather than by
  // reading the module's arithmetic back out of it.
  //
  // Two latencies, either side of the frame muir gives, which between them
  // LOCATE the frame's end instead of merely bounding it:
  //
  //   nine tenths of a frame   OUTPUT still reloads first: the string streams
  //   eleven tenths of a frame TxEMT is up when the handler arrives, RANDOM
  //                            absorbs eight in a row and the machine spins
  //                            having sent one character --- which is the real
  //                            chip's behavior too, and is what the board did
  //
  // A fabric whose frame ends early fails the first of those with the second
  // still passing, and that is the board's fault written down as a check.
  long walk_streamed = 0, walk_wedged = 0;
  {
    const char *out = "HELLO CADR";
    const size_t out_len = 10;
    // Rate 14 is 9600 baud, which is what the machine asked for on the board.
    const unsigned kRate = 14;
    const unsigned kMr2 = 0x30u | kRate;   // both halves on the generator
    const double frame = FrameTicks(kMr1, kRate);

    for (int leg = 0; leg < 2 && bad < 25; ++leg) {
      const long latency = (long)(frame * (leg == 0 ? 0.9 : 1.1));
      const char *name = leg == 0 ? "nine tenths of a frame"
                                  : "eleven tenths of a frame";

      // --- the chip, programmed as `serial.lisp` programs it.
      b.Write(SER_PAGE + 4 * 4, 0u);         // cable out first, so that
      b.Idle(8);                             // plugging it in is one change
      (void)b.UbRead(UB_SER_CMD);            // the mode pointer back to MR1
      b.UbWrite(UB_SER_MODE, kMr1);
      b.UbWrite(UB_SER_MODE, kMr2);
      b.UbWrite(UB_SER_CMD, 0x27);           // TxEN, RxEN, DTR, RTS
      b.Write(SER_PAGE + 4 * 4, 7u);         // the device plugs in
      b.Idle(8);
      // SER INT ENABLE, the 74LS74 at IOBSER 0D21, keeping the four bits of
      // the 74LS175 the card holds beside it.
      b.UbWrite(UB_IOB_CSR, (b.UbRead(UB_IOB_CSR) & 017u) | 0200u);
      // The plug raised DSCHG, which is RANDOM's real job: let the walk
      // absorb it before the string starts, exactly as it would on the board.
      b.Idle(64);
      (void)b.UbRead(UB_SER_STAT);

      size_t op = 0, in_hand = 0;
      std::string arrived;
      long absorbed = 0, run_absorbed = 0, armed = -1;
      bool turned_off = false;

      // The foreground primes the transmitter with the first character, as
      // `serial.lisp`'s output does before it leaves the buffer to the
      // interrupt.
      b.UbWrite(UB_SER_DATA, (unsigned char)out[op++]);
      in_hand = 1;

      const long began = tick;
      // Leg 0 runs one frame a character; leg 1 spends a whole latency on
      // each absorbed interrupt, so its budget is counted in those.
      const long budget = leg == 0 ? (long)(frame * 16.0) + 200000
                                   : latency * 12 + (long)(frame * 4.0);
      while (tick - began < budget) {
        if (leg == 0 && arrived.size() >= out_len) break;
        if (leg == 1 && run_absorbed >= 8) break;

        // The card's own request at the machine, on the serial vector.
        if (b.d->intr_request && b.d->intr_vector == 0264u) {
          if (armed < 0) armed = tick;
        } else {
          armed = -1;
        }

        if (armed >= 0 && tick - armed >= latency) {
          // --- the walk, first match wins, then dismiss.  The microcode
          // reads each channel's CSR in turn and all three name the same
          // register, so it reads the status once per channel it tests where
          // this reads it once and tests the masks in order.  The count
          // differs and nothing that depends on it does: a status read
          // clears DSCHG and leaves TxEMT, which is the whole point, and
          // DSCHG is gone after the walk either way.
          const unsigned st = b.UbRead(UB_SER_STAT) & 0377u;
          if (st & 4u) {                       // RANDOM: SR2
            (void)b.UbRead(UB_SER_STAT);       // absorbed by reading the CSR
            ++absorbed;
            ++run_absorbed;
          } else if (st & 1u) {                // OUTPUT: SR0 TxRDY
            run_absorbed = 0;
            if (op < out_len) {
              b.UbWrite(UB_SER_DATA, (unsigned char)out[op++]);
              ++in_hand;
            } else {
              b.UbWrite(UB_SER_CMD, 0x27u & 0376u);   // INTR-OUTDEV's turnoff
              turned_off = true;
            }
          } else if (st & 2u) {                // INPUT: SR1 RxRDY
            run_absorbed = 0;
            (void)b.UbRead(UB_SER_DATA);
          }
          armed = -1;
          continue;
        }

        // The far end, which is Linux: it takes what the port has finished
        // sending.  Between handler runs only, so that the latency above is
        // the handler's and not the bus's.
        if (b.Read(SER_PAGE + 4) & 1u) {
          const uint32_t rd = b.Read(SER_PAGE + 4 * 2);
          if (rd & 0x100u) arrived.push_back((char)(rd & 0xFFu));
        }
        b.Idle(1);
      }

      if (leg == 0) {
        // The whole string, in order, with RANDOM never once absorbing a
        // transmitter interrupt.  `in_hand` and `turned_off` are named so
        // that a leg which streamed by accident --- the foreground's one
        // character and nothing else --- cannot read as a pass.
        if (arrived != std::string(out, out_len)) {
          Fail("the characters that reached the cable at nine tenths of a frame",
               arrived.size(), out_len);
          std::fprintf(stderr, "  the far end got \"%s\", wanting \"%s\"\n",
                       arrived.c_str(), out);
          std::fprintf(stderr,
                       "  the handler waited %ld ticks; muir's frame is %ld, "
                       "and RANDOM absorbed %ld interrupts\n",
                       latency, (long)frame, absorbed);
        } else {
          ++walk_streamed;
        }
        if (absorbed != 0)
          Fail("interrupts RANDOM absorbed while the transmitter was streaming",
               absorbed, 0);
        if (in_hand != out_len)
          Fail("characters OUTPUT handed the chip", in_hand, out_len);
        if (!turned_off)
          Fail("INTR-OUTDEV's turnoff once the buffer emptied", 0, 1);
      } else {
        // And the other side of it: a handler slower than the frame really
        // does wedge, on this chip and on MIT's.  Without this half, a
        // frame made enormous would pass the leg above and say nothing.
        if (run_absorbed < 8)
          Fail("interrupts RANDOM absorbed in a row at eleven tenths of a frame",
               run_absorbed, 8);
        else if (arrived.size() != 1)
          Fail("characters that reached the cable before the walk wedged",
               arrived.size(), 1);
        else
          ++walk_wedged;
      }
      // Leave the port as the section above left it.
      b.UbWrite(UB_SER_CMD, 0x27);
      b.UbWrite(UB_IOB_CSR, b.UbRead(UB_IOB_CSR) & 017u);
    }
  }

  // ======================================================================
  // AND THE SECOND TRANSMISSION, WHICH IS WHERE THE BOARD STOPPED
  // ======================================================================
  //
  // The section above ends where `serial.lisp` ends a burst: the buffer is
  // empty, `INTR-OUTDEV` writes the command register with `TxEN` cleared ---
  // `(LOGAND UART-COMMAND 376)` --- and the last character is still in the
  // shift register.  The next `format` turns the transmitter back on and the
  // walk is supposed to start again.  On the board it did not: the machine
  // wedged in the interrupt service with the status register reading `0o305`
  // --- DSR, DCD, TxRDY and SR2 --- and the command register `0o47`, so the
  // transmitter was enabled, the holding register was empty, and SR2 was up.
  // With SR2 up the RANDOM channel matches first at every interrupt and
  // OUTPUT never loads the holding register, so nothing is ever sent and
  // nothing ever clears SR2.  One burst a boot, for ever.
  //
  // **WHAT THE SHEET SAYS, AND IT IS ABOUT THE DISABLE.**  SCN2661/SCN68661,
  // the command register: "If the transmitter is disabled, it will complete
  // the transmission of the character in the transmit shift register (if any)
  // prior to terminating operation.  The TxD output will then remain in the
  // marking state (High) while TxRDY and TxEMT will go High (inactive)."
  // High is inactive on both.  So the drain that follows a disable does NOT
  // raise TxEMT: the transmitter terminates operation with the bit down, and
  // it is down again at the next enable --- "TxEMT will not go active until
  // at least one character has been transmitted", SR0 being "initially set
  // when the transmitter is enabled by CR0".
  //
  // Two rates, because the board showed the fault at both and the property is
  // not a frame length: 9600, and 300, where a whole `(format zz "HELLO
  // CADR")` came out on the wire and the next one did not.
  long second_streamed = 0;
  {
    // --- THE TWO WAYS SR2 CAN STAND AT A TURN-OFF, AND THE SHEET'S ONE
    // ANSWER.  The driver's turn-off lands either side of the drain.  A
    // handler that reloads inside the frame writes it while the last
    // character is still in the shift register, which is what the two legs
    // below run.  A slower one writes it after the shift register has
    // already run out and raised TxEMT.  One sentence answers both --- at a
    // disable "TxRDY and TxEMT will go High (inactive)" --- and in this card
    // they are two different terms: the drain's own `s_tx_on`, and the
    // command register's clear.  Neither alone is the rule.
    const unsigned kRate = 14;
    const double frame0 = FrameTicks(kMr1, kRate);
    b.Write(SER_PAGE + 4 * 4, 0u);
    b.Idle(8);
    (void)b.UbRead(UB_SER_CMD);
    b.UbWrite(UB_SER_MODE, kMr1);
    b.UbWrite(UB_SER_MODE, 0x30u | kRate);
    b.UbWrite(UB_SER_CMD, 0x27);
    b.Write(SER_PAGE + 4 * 4, 7u);
    b.Idle(64);
    (void)b.UbRead(UB_SER_STAT);              // the plug's DSCHG
    // One character out with the transmitter left ON, which is the state a
    // handler slower than the frame finds: TxEMT up and visible.
    b.UbWrite(UB_SER_DATA, 'Z');
    b.Idle((long)(frame0 * 3.0));
    if (b.Read(SER_PAGE + 4) & 1u) (void)b.Read(SER_PAGE + 4 * 2);
    if (!(b.UbRead(UB_SER_STAT) & 4u))
      Fail("SR2 once the shift register ran out with the transmitter on", 0, 1);
    // The turn-off now finds it up, and the next enable must still not
    // present it: nothing has been transmitted since that enable.
    b.UbWrite(UB_SER_CMD, 0x26);
    b.Idle((long)(frame0 * 2.0));
    b.UbWrite(UB_SER_CMD, 0x27);
    if (b.UbRead(UB_SER_STAT) & 4u)
      Fail("SR2 at an enable whose turn-off had found TxEMT already up", 1, 0);
    if (!(b.UbRead(UB_SER_STAT) & 1u))
      Fail("TxRDY at that enable", 0, 1);
    b.UbWrite(UB_SER_CMD, 0x26);

    struct Leg { unsigned rate; const char *first; const char *second; };
    const Leg legs[2] = {{14, "HELLO", "TWO"}, {5, "HI", "GO"}};

    for (int li = 0; li < 2 && bad < 25; ++li) {
      const Leg &L = legs[li];
      const double frame = FrameTicks(kMr1, L.rate);
      const long latency = (long)(frame / 32.0);   // a handler in microseconds

      // --- the chip, programmed as `serial.lisp` programs it, and the
      // command register as the board read it before any transmission:
      // `0o46`, the receiver on and the TRANSMITTER OFF.
      b.Write(SER_PAGE + 4 * 4, 0u);
      b.Idle(8);
      (void)b.UbRead(UB_SER_CMD);
      b.UbWrite(UB_SER_MODE, kMr1);
      b.UbWrite(UB_SER_MODE, 0x30u | L.rate);
      b.UbWrite(UB_SER_CMD, 0x26);
      b.Write(SER_PAGE + 4 * 4, 7u);
      b.Idle(8);
      b.UbWrite(UB_IOB_CSR, (b.UbRead(UB_IOB_CSR) & 017u) | 0200u);
      b.Idle(64);
      (void)b.UbRead(UB_SER_STAT);       // the plug's DSCHG, RANDOM's real job

      std::string arrived, taken_in;
      long absorbed = 0;

      // One burst: the foreground turns the transmitter on, and MIT's walk
      // does the rest until the buffer empties and OUTPUT turns it off.
      // Returns false if the walk wedged --- eight absorbed in a row with no
      // character moving, which is what the board did.
      auto burst = [&](const char *out, long *got, long *abs, bool *off) {
        const size_t out_len = std::strlen(out);
        size_t op = 0;
        long run_absorbed = 0, armed = -1;
        const size_t before = arrived.size();
        const long abs_before = absorbed;
        *off = false;
        b.UbWrite(UB_SER_CMD, 0x27);     // the turn-on
        // The sheet's two sentences about an enable, read at the register
        // the driver reads: the holding register is empty so TxRDY is set,
        // and TxEMT has not gone active because this transmitter has not
        // transmitted anything since it was enabled.
        const unsigned at_on = b.UbRead(UB_SER_STAT) & 0377u;
        if (at_on & 4u)
          Fail("SR2 at the transmitter's enable, before it has sent anything",
               1, 0);
        if (!(at_on & 1u))
          Fail("TxRDY at the transmitter's enable, the holding register empty",
               0, 1);
        const long began = tick;
        const long budget = (long)(frame * (double)(out_len + 6)) + latency * 24;
        while (tick - began < budget && run_absorbed < 8) {
          if (arrived.size() - before >= out_len && *off) break;
          if (b.d->intr_request && b.d->intr_vector == 0264u) {
            if (armed < 0) armed = tick;
          } else {
            armed = -1;
          }
          if (armed >= 0 && tick - armed >= latency) {
            const unsigned st = b.UbRead(UB_SER_STAT) & 0377u;
            if (st & 4u) {                      // RANDOM: SR2
              (void)b.UbRead(UB_SER_STAT);
              ++absorbed;
              ++run_absorbed;
            } else if (st & 1u) {               // OUTPUT: SR0 TxRDY
              run_absorbed = 0;
              if (op < out_len) {
                b.UbWrite(UB_SER_DATA, (unsigned char)out[op++]);
              } else {
                b.UbWrite(UB_SER_CMD, 0x27u & 0376u);   // INTR-OUTDEV's turnoff
                *off = true;
              }
            } else if (st & 2u) {               // INPUT: SR1 RxRDY
              run_absorbed = 0;
              taken_in.push_back((char)(b.UbRead(UB_SER_DATA) & 0xFFu));
            }
            armed = -1;
            continue;
          }
          if (b.Read(SER_PAGE + 4) & 1u) {
            const uint32_t rd = b.Read(SER_PAGE + 4 * 2);
            if (rd & 0x100u) arrived.push_back((char)(rd & 0xFFu));
          }
          b.Idle(1);
        }
        *got = (long)(arrived.size() - before);
        *abs = absorbed - abs_before;
        return run_absorbed < 8;
      };

      long got1 = 0, abs1 = 0, got2 = 0, abs2 = 0;
      bool off1 = false, off2 = false;
      (void)burst(L.first, &got1, &abs1, &off1);
      if (arrived != std::string(L.first))
        Fail("the characters the FIRST burst put on the cable", got1,
             (long)std::strlen(L.first));
      if (!off1) Fail("INTR-OUTDEV's turnoff at the end of the first burst", 0, 1);
      // The turn-off really did reach the command register: `TxEN` down in
      // the register the driver would read back, which is the other way this
      // could have gone wrong and did not.
      if (b.UbRead(UB_SER_CMD) & 1u)
        Fail("TxEN in the command register after INTR-OUTDEV's turnoff", 1, 0);

      // The gap between two `format`s.  The last character is still in the
      // shift register when the turn-off lands, and the sheet has the
      // transmitter complete it and then terminate operation; two frames is
      // long enough for both, and the far end takes the character.
      const long gap_until = tick + (long)(frame * 2.0);
      while (tick < gap_until) {
        if (b.Read(SER_PAGE + 4) & 1u) {
          const uint32_t rd = b.Read(SER_PAGE + 4 * 2);
          if (rd & 0x100u) arrived.push_back((char)(rd & 0xFFu));
        }
        b.Idle(1);
      }
      // With the transmitter disabled the bit is not visible whatever it
      // holds, which is why the board's own readout between the two `format`s
      // said nothing: `0o300` here and `0o305` one command write later.
      if (b.UbRead(UB_SER_STAT) & 4u)
        Fail("SR2 with the transmitter disabled", 1, 0);

      // AND THE RECEIVER, WHICH THE WEDGE STARVED TOO.  With RANDOM matching
      // every interrupt the INPUT channel is never reached either, so the
      // character sits in the receive holding register unread, the line's
      // `TX_ROOM` goes down behind it --- `card_room` is `s_rx_runs &&
      // !RxRDY` --- and `cadr-serial` stops offering.  One character put in
      // as the second burst starts says that road is open: MIT's walk
      // reaches INPUT, which it cannot do while SR2 stands.
      if (b.Read(SER_PAGE + 4 * 1) & 2u) b.Write(SER_PAGE + 4 * 3, 0x6Bu);
      const bool ok2 = burst(L.second, &got2, &abs2, &off2);
      const std::string want = std::string(L.first) + std::string(L.second);
      if (!ok2 || arrived != want) {
        Fail("the characters the SECOND burst put on the cable", got2,
             (long)std::strlen(L.second));
        std::fprintf(stderr,
                     "  at %s baud the far end got \"%s\", wanting \"%s\"; "
                     "RANDOM absorbed %ld in the second burst\n",
                     L.rate == 14 ? "9600" : "300", arrived.c_str(),
                     want.c_str(), abs2);
      }
      if (abs1 != 0)
        Fail("interrupts RANDOM absorbed during the first burst", abs1, 0);
      if (abs2 != 0)
        Fail("interrupts RANDOM absorbed during the second burst", abs2, 0);
      if (!off2)
        Fail("INTR-OUTDEV's turnoff at the end of the second burst, which is "
             "what a THIRD burst needs", 0, 1);
      if (taken_in != "k")
        Fail("the characters MIT's INPUT channel took while the second burst "
             "was on the wire", taken_in.size(), 1);
      if (bad == 0) ++second_streamed;

      b.UbWrite(UB_SER_CMD, 0x27);
      b.UbWrite(UB_IOB_CSR, b.UbRead(UB_IOB_CSR) & 017u);
    }
  }

  // ======================================================================
  // A DISABLE HALF A FRAME INTO A CHARACTER, AND THE CHARACTER GOES ANYWAY
  // ======================================================================
  //
  // The section above ends a burst the way `INTR-OUTDEV` ends one, with the
  // last character still in the shift register, and takes that character off
  // the far end afterwards.  So the drain itself is already exercised there.
  // What nothing here could say is WHEN the character arrived, and that is
  // the whole of the property.  The sheet, on the command register: "If the
  // transmitter is disabled, it will complete the transmission of the
  // character in the transmit shift register (if any) prior to terminating
  // operation."  Completing it is a statement about the shift register going
  // on shifting at the rate it was programmed with.  A shift register that
  // stopped at the disable and finished the character whenever something
  // else next started its clock would put the same character on the same
  // wire, late, and every assertion above would pass.
  //
  // So this measures the instant.  `muir::serial::Pci::transmit` works the
  // frame's end out at the TAKE --- `shifting = Some((next, start + frame))`
  // --- and then delivers at that instant whatever the software has since
  // done to the command register, so the reference has the character land
  // one frame after it started and not one tick later.
  //
  // **AND THE SECOND LEG IS THE ONE NOTHING IN THIS TREE COULD SEE.**  With
  // the receiver left on, the baud-rate generator has a reason to run that
  // has nothing to do with the character in flight, so a generator gated on
  // the two enables alone still clocks it out and the fault is invisible.
  // Turn BOTH halves off and the character in the shift register is the only
  // thing keeping the crystal going --- `gen_on`'s `tx_busy` term, which is
  // `Pci::generator_on`'s own reason for existing.  Measured before this leg
  // was written: with that term dropped, `gp0_split`, `iob` and `unibus` all
  // passed.
  long drained_on_time = 0;
  {
    const unsigned kRate = 14;                      // 9600 baud
    const double frame = FrameTicks(kMr1, kRate);
    const double x16_t = (double)DIVISORS[kRate & 0xF] * 1000000000.0 /
                         (double)BRCLK_HZ / (double)TICK_NS;
    // `TxEN` cleared, and then both halves cleared, with `DTR` and `RTS`
    // kept in each: the two commands muir's own pair of tests writes.
    const unsigned offs[2] = {0x26u, 0x22u};
    for (int li = 0; li < 2 && bad < 25; ++li) {
      // The chip from scratch and the plug in, as every leg above does it.
      b.Write(SER_PAGE + 4 * 4, 0u);
      b.Idle(8);
      (void)b.UbRead(UB_SER_CMD);
      b.UbWrite(UB_SER_MODE, kMr1);
      b.UbWrite(UB_SER_MODE, 0x30u | kRate);
      b.UbWrite(UB_SER_CMD, 0x27);
      b.Write(SER_PAGE + 4 * 4, 7u);
      b.Idle(64);
      (void)b.UbRead(UB_SER_STAT);       // the plug's own data set change
      if (b.Read(SER_PAGE + 4) & 1u) (void)b.Read(SER_PAGE + 4 * 2);

      const long at = tick;
      b.UbWrite(UB_SER_DATA, 'A');
      // Half a frame in, which is where the output channel's turn-off lands:
      // the character is in the shift register and the far end has not got
      // it.
      while (tick - at < (long)(frame / 2.0)) b.Idle(1);
      if (b.Read(SER_PAGE + 4) & 1u)
        Fail("a character on the cable half a frame into its own frame", 1, 0);
      b.UbWrite(UB_SER_CMD, offs[li]);
      // "The TxD output will then remain in the marking state (High) while
      // TxRDY and TxEMT will go High (inactive)" --- High is inactive on
      // both, so neither bit stands at a disable.
      const unsigned st = b.UbRead(UB_SER_STAT) & 0377u;
      if (st & 5u)
        Fail("TxRDY and SR2 with the transmitter disabled mid-character",
             st & 5u, 0);

      const long bound = (long)(frame * 3.0) + 20000;
      while (!(b.Read(SER_PAGE + 4) & 1u) && tick - at < bound) { }
      if (!(b.Read(SER_PAGE + 4) & 1u)) {
        Fail("the character the disable found in the shift register", 0, 1);
        break;
      }
      const long span = tick - at;
      const uint32_t rd = b.Read(SER_PAGE + 4 * 2);
      if ((rd & 0x1FFu) != 0x141u)
        Fail("the character the far end got after the disable",
             rd & 0x1FFu, 0x141u);
      // **AND IT ARRIVED WHEN IT WOULD HAVE.**  The same bound the rate
      // measurement above uses: muir's own frame, plus the one 16X clock the
      // take may wait for and the bus cycles either side, and nothing more.
      // A frame that came out too LONG is the fault this section exists to
      // catch, so the upper bound is the assertion and not a formality.
      if ((double)span < frame || (double)span > frame + x16_t + 4000.0)
        Fail("the ticks the disabled transmitter's last character took",
             (unsigned long long)span, (unsigned long long)frame);
      // And nothing follows it: the transmitter terminated operation.
      b.Idle((long)(frame * 1.5));
      if (b.Read(SER_PAGE + 4) & 1u)
        Fail("a second character after the transmitter terminated operation",
             1, 0);
      if (bad == 0) ++drained_on_time;
    }
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

  // ======================================================================
  // THE KEYBOARD AND THE MOUSE, ACROSS THE SEAM
  // ======================================================================
  //
  // The fourth page is the far end of the card's other two cables, and the
  // only way to hold a far end to anything is to read what the MACHINE sees
  // of it.  So every comparison here is a Unibus read of the card's own
  // registers --- `0o764100` and `0o764102` for the keyboard's two halves,
  // `0o764104` and `0o764106` for the mouse, `0o764112` for the status they
  // share --- against what was written at `0x4000_3000`.  The card itself is
  // `build/iob.pass`'s and is held to muir there; what is held here is the
  // crossing.
  //
  // **IT IS LAST BECAUSE IT ENDS BY RESETTING THE CARD**, which is leg 2 of
  // the autoboot trap and cannot be run with anything else still to check.
  long keys_typed = 0, keys_lost = 0, mouse_moved = 0, keys_swept = 0;
  double step_span = 0;
  {
    // The write sweep swept a zero through every word of every page, and on
    // this face word 2 is `KEY`: one word of zero is queued and the card is
    // holding it.  Drain it in MIT's own order and flush, which is also the
    // state `cadr-terminal` is required to start a program from.
    (void)b.UbRead(UB_KBD_HIGH);
    (void)b.UbRead(UB_KBD_LOW);
    b.Write(INPUT_PAGE + 4 * IN_CTL, IN_CTL_FLUSH);
    b.Idle(16);
    uint32_t st = b.Read(INPUT_PAGE + 4 * IN_STAT);
    if (st & IN_ST_KBD_READY) Fail("KBD READY after the card was drained", st, 0);
    if (!(st & IN_ST_ROOM)) Fail("the queue's room after a flush", st, IN_ST_ROOM);
    if ((st >> 8) & 0x3Fu) Fail("the queue's depth after a flush", (st >> 8) & 0x3Fu, 0);
    if (st & IN_ST_OWES) Fail("the mouse owing steps after a flush", st, 0);

    // --- ONE WORD, AND THE CARD'S OWN ASYMMETRY BETWEEN THE HALVES.
    // MIT's Unibus channel reads the HIGH half first --- `uc-interrupt.lisp`,
    // "needs to read the high-order word first" --- and only the LOW half
    // clears `KBD READY`, the 74LS74 at IOBKBD 0B30 having `-READ.KBD.LOW`
    // on its clear pin and nothing else.  The word is `keyboard::up_down`'s,
    // so the frame bits are compared too: `word >> 16` is `0o371` on every
    // word the new keyboard sends.
    {
      const uint32_t w = KbdWord(KEY_RUBOUT, false);
      b.Write(INPUT_PAGE + 4 * IN_KEY, w);
      long waited = 0;
      while (!(b.UbRead(UB_IOB_CSR) & 040u) && waited < 40) ++waited;
      if (!(b.UbRead(UB_IOB_CSR) & 040u)) {
        Fail("KBD READY after a word was written to the input face", 0, 1);
      } else {
        ++keys_typed;
        const unsigned hi = b.UbRead(UB_KBD_HIGH);
        if (hi != (UB_FLOATING | ((w >> 16) & 0xFFu)))
          Fail("the keyboard's high half, with the upper byte floating",
               hi, UB_FLOATING | ((w >> 16) & 0xFFu));
        if ((hi & 0377u) != 0371u)
          Fail("the frame bits: every new-keyboard word has `word >> 16` = 0o371",
               hi & 0377u, 0371u);
        // Reading the high half does NOT clear it.
        if (!(b.UbRead(UB_IOB_CSR) & 040u))
          Fail("KBD READY after the HIGH half was read, which must not clear it", 0, 1);
        const unsigned lo = b.UbRead(UB_KBD_LOW);
        if (lo != (w & 0xFFFFu)) Fail("the keyboard's low half", lo, w & 0xFFFFu);
        // ...and the LOW half does.
        b.Idle(4);
        if (b.UbRead(UB_IOB_CSR) & 040u)
          Fail("KBD READY after the LOW half was read, which must clear it", 1, 0);
      }
      // And `KEY` reads back the word last HANDED TO THE CARD.
      const uint32_t back = b.Read(INPUT_PAGE + 4 * IN_KEY);
      if ((back & 0xFFFFFFu) != w) Fail("KEY read back", back & 0xFFFFFFu, w);
      if (!(back & 0x1000000u)) Fail("KEY's bit 24, that a word has ever gone", back, 0x1000000u);
    }

    // --- THE HANDSHAKE, WHICH IS `Keyboard::deliver` IN FABRIC.
    // Four words written while the card can hold one.  The card must get
    // them ONE AT A TIME, each after the machine has read the last --- a
    // face that strobed them all in would leave the card holding the LAST,
    // and MIT's own rule is that "a word landing on one not yet read
    // replaces it", so the loss would be silent.  This is the shape of a
    // shifted key: Left Shift down, 'a' down, 'a' up, Left Shift up.
    {
      const uint32_t typed[4] = {
        KbdWord(KEY_LSHIFT, false), KbdWord(KEY_A, false),
        KbdWord(KEY_A, true), KbdWord(KEY_LSHIFT, true)
      };
      for (uint32_t w : typed) b.Write(INPUT_PAGE + 4 * IN_KEY, w);
      b.Idle(16);
      // One has gone and three are waiting.
      st = b.Read(INPUT_PAGE + 4 * IN_STAT);
      if (((st >> 8) & 0x3Fu) != 3)
        Fail("words still queued with the card holding the first", (st >> 8) & 0x3Fu, 3);
      for (int k = 0; k < 4 && bad < 25; ++k) {
        long waited = 0;
        while (!(b.UbRead(UB_IOB_CSR) & 040u) && waited < 40) ++waited;
        if (!(b.UbRead(UB_IOB_CSR) & 040u)) {
          Fail("KBD READY for a word of a shifted keystroke", 0, 1);
          break;
        }
        const unsigned hi = b.UbRead(UB_KBD_HIGH);
        const unsigned lo = b.UbRead(UB_KBD_LOW);
        const uint32_t got = ((uint32_t)(hi & 0377u) << 16) | lo;
        if (got != typed[k])
          Fail("the word the machine read, in the order it was written", got, typed[k]);
        else
          ++keys_typed;
        b.Idle(8);
      }
      st = b.Read(INPUT_PAGE + 4 * IN_STAT);
      if ((st >> 8) & 0x3Fu) Fail("the queue once the machine has read them all",
                                  (st >> 8) & 0x3Fu, 0);
    }

    // --- THE QUEUE'S BOUND, AND `LOST`.  A machine that has stopped reading
    // still loses words, exactly as the cable does; what this face owes is
    // that the loss is COUNTED and not silent.
    {
      b.Write(INPUT_PAGE + 4 * IN_KEY, KbdWord(KEY_RETURN, false));
      long waited = 0;
      while (!(b.UbRead(UB_IOB_CSR) & 040u) && waited < 40) ++waited;
      const uint32_t lost_before = b.Read(INPUT_PAGE + 4 * IN_LOST);
      for (unsigned k = 0; k < IN_DEPTH; ++k)
        b.Write(INPUT_PAGE + 4 * IN_KEY, KbdWord(KEY_A, false));
      st = b.Read(INPUT_PAGE + 4 * IN_STAT);
      if (((st >> 8) & 0x3Fu) != IN_DEPTH)
        Fail("the queue filled to its depth", (st >> 8) & 0x3Fu, IN_DEPTH);
      if (st & IN_ST_ROOM) Fail("the queue's room bit when it is full", st, 0);
      if (b.Read(INPUT_PAGE + 4 * IN_LOST) != lost_before)
        Fail("LOST while the queue still had room", 1, 0);
      b.Write(INPUT_PAGE + 4 * IN_KEY, KbdWord(KEY_A, true));
      const uint32_t lost_after = b.Read(INPUT_PAGE + 4 * IN_LOST);
      if (lost_after != lost_before + 1)
        Fail("LOST for a word offered to a full queue", lost_after, lost_before + 1);
      keys_lost = 1;
      // The one that was refused must be LOST and not queued behind the
      // others: the depth is unchanged.
      if (((b.Read(INPUT_PAGE + 4 * IN_STAT) >> 8) & 0x3Fu) != IN_DEPTH)
        Fail("the queue's depth after a word was refused",
             (b.Read(INPUT_PAGE + 4 * IN_STAT) >> 8) & 0x3Fu, IN_DEPTH);
    }

    // --- FLUSH, which is leg 3: a program starting under a running machine
    // begins with the seam empty.  The queue is full here, so this is the
    // case that matters.
    {
      b.Write(INPUT_PAGE + 4 * IN_CTL, IN_CTL_FLUSH);
      b.Idle(8);
      st = b.Read(INPUT_PAGE + 4 * IN_STAT);
      if ((st >> 8) & 0x3Fu) Fail("the queue after FLUSH", (st >> 8) & 0x3Fu, 0);
      if (!(st & IN_ST_ROOM)) Fail("the queue's room after FLUSH", st, IN_ST_ROOM);
      // The card is still holding the word it had; release it, and NOTHING
      // may follow, because the sixteen behind it are gone.
      (void)b.UbRead(UB_KBD_LOW);
      for (int k = 0; k < 4 && bad < 25; ++k) {
        b.Idle(KB_CLK_T);
        if (b.UbRead(UB_IOB_CSR) & 040u)
          Fail("a word reaching the card after FLUSH threw the queue away", 1, 0);
      }
    }


    // --- A WORD QUEUED ON THE VERY TICK ONE LEFT, which is the only thing
    // that can see the queue's count written from two places.
    //
    // **THE RACE HAS TO BE AIMED, AND THREE ATTEMPTS AT THIS CHECK MISSED
    // IT.**  The record was written, run, and SURVIVED three times before
    // this worked, which is the useful part of the story and is why it is
    // written out.
    //
    //   1. Four words written while the card held one.  With `KBD READY` up
    //      no take fires at all, so the two events never met.
    //   2. The card released, then a write swept across the ticks after it.
    //      By the time a Unibus read RETURNS the take has already fired ---
    //      and the queue was empty anyway, a take needing `count` non-zero
    //      and the word just handed over having been the only one in it.
    //   3. The write issued WHILE `-UB MSYN` was up, with the delay before
    //      it swept over the window the card answers in.  Nearer, but the
    //      card answers this group anywhere between 1,250 and 2,250 ns after
    //      the strobe depending where the request fell in its own
    //      microsecond, so a delay measured from the STROBE lands on the
    //      take only by luck, and two hundred offsets of luck were not
    //      enough.
    //
    // **WHAT WORKS IS MEASURING FROM THE ANSWER AND NOT FROM THE STROBE.**
    // The write's address is handshaken early and its DATA BEAT held back by
    // hand; the run then waits for `-UB SSYN` itself and releases the beat a
    // counted number of ticks after it.  The card clears `KBD READY` where
    // it answers, this module sees that one tick later and takes the tick
    // after that, so a sweep of a dozen ticks from the answer covers the
    // take exactly and needs no luck at all.  That is this project's own
    // "to tell an equivalence from a blind check, sweep the magnitude",
    // applied to a phase rather than to a delay.
    //
    // **AND WHAT SAYS IT LANDED IS THE WORDS AND NOT THE COUNT.**  The count
    // is the thing being tested.  A put swallowed by a take leaves the queue
    // one short for ever, so its word is never handed over and `KBD READY`
    // never comes up for it: a comparison against the stimulus, which cannot
    // move with the bug.
    {
      long wrote = 0, read_back = 0;
      const uint32_t seq[4] = {
        KbdWord(KEY_A, false), KbdWord(KEY_A, true),
        KbdWord(KEY_RETURN, false), KbdWord(KEY_RETURN, true)
      };
      for (unsigned after = 0; after < 12 && bad < 25; ++after) {
        // Start clean: the card free and the queue empty.
        b.Write(INPUT_PAGE + 4 * IN_CTL, IN_CTL_FLUSH);
        b.Idle(8);
        if (b.UbRead(UB_IOB_CSR) & 040u) {
          (void)b.UbRead(UB_KBD_LOW);
          b.Idle(8);
        }
        // One word to the card and TWO behind it, so that the take which
        // fires when the card is released has something to take.
        for (int j = 0; j < 3; ++j) {
          b.Write(INPUT_PAGE + 4 * IN_KEY, seq[j]);
          ++wrote;
        }
        long waited = 0;
        while (!(b.UbRead(UB_IOB_CSR) & 040u) && waited < 40) ++waited;

        // The write's ADDRESS, handshaken now; its data beat is held.
        b.Quiet();
        dut->m_awaddr = INPUT_PAGE + 4 * IN_KEY;
        dut->m_awlen = 0;
        dut->m_awid = 0x2A;
        dut->m_wdata = seq[3];
        dut->m_wstrb = 0xF;
        dut->m_wlast = 1;
        dut->m_awvalid = 1;
        int aw_done = 0;
        for (int t = 0; t < 16 && !aw_done; ++t) {
          dut->clk = 0; dut->eval();
          aw_done = dut->m_awvalid && dut->m_awready;
          dut->clk = 1; dut->eval();
          ++tick;
        }
        dut->m_awvalid = 0;
        if (!aw_done) {
          Fail("the write address of an aimed round was never taken", 0, 1);
          break;
        }

        // `-UB MSYN` up for a read of the keyboard's low half, and the word
        // taken at the FIRST tick the card answers --- before the take that
        // follows can put the next one on the same lines.
        dut->ub_msyn = 1;
        dut->ub_addr = UB_KBD_LOW;
        dut->ub_write = 0;
        dut->ub_wdata = 0;
        unsigned got = 0;
        long spun = 0;
        int answered = 0;
        while (spun < 2000) {
          dut->clk = 0; dut->eval();
          if (dut->ub_ssyn) { got = dut->ub_rdata; answered = 1; }
          dut->clk = 1; dut->eval();
          ++tick;
          ++spun;
          if (answered) break;
        }
        if (!answered) {
          Fail("the card never answered the aimed Unibus cycle", 0, 1);
          break;
        }
        if (got != (seq[0] & 0xFFFFu))
          FailAt(INPUT_PAGE, "the word the aimed cycle read", got, seq[0] & 0xFFFFu);
        ++read_back;
        dut->ub_msyn = 0;

        // ...and the data beat `after` ticks past that answer.  Somewhere in
        // this sweep is the tick the take fires on.
        for (unsigned t = 0; t < after; ++t) {
          dut->clk = 0; dut->eval();
          dut->clk = 1; dut->eval();
          ++tick;
        }
        dut->m_wvalid = 1;
        int w_done = 0;
        for (int t = 0; t < 16 && !w_done; ++t) {
          dut->clk = 0; dut->eval();
          w_done = dut->m_wvalid && dut->m_wready;
          dut->clk = 1; dut->eval();
          ++tick;
        }
        dut->m_wvalid = 0;
        if (!w_done) {
          Fail("the write data of an aimed round was never taken", 0, 1);
          break;
        }
        ++wrote;
        dut->m_bready = 1;
        int b_done = 0;
        for (int t = 0; t < 16 && !b_done; ++t) {
          dut->clk = 0; dut->eval();
          b_done = dut->m_bvalid && dut->m_bready;
          dut->clk = 1; dut->eval();
          ++tick;
        }
        dut->m_bready = 0;
        b.Quiet();
        b.Idle(4);

        // The three behind it, sampled at a settled card and so held to
        // their order.  **A LOST PUT SHOWS UP AS THE THIRD NEVER
        // ARRIVING**: the count is one short of what the queue holds, so
        // the last word is never handed over and `KBD READY` never comes up
        // for it.
        for (int j = 1; j < 4 && bad < 25; ++j) {
          waited = 0;
          while (!(b.UbRead(UB_IOB_CSR) & 040u) && waited < 60) ++waited;
          if (!(b.UbRead(UB_IOB_CSR) & 040u)) {
            Fail("a word queued on the tick one left never reached the card --- "
                 "the queue's count lost a put to a take", 0, 1);
            break;
          }
          const unsigned lo = b.UbRead(UB_KBD_LOW);
          if (lo != (seq[j] & 0xFFFFu))
            Fail("a word of an aimed round, in order", lo, seq[j] & 0xFFFFu);
          ++read_back;
        }
        const uint32_t left = (b.Read(INPUT_PAGE + 4 * IN_STAT) >> 8) & 0x3Fu;
        if (left != 0) Fail("the queue at the end of an aimed round", left, 0);
      }
      if (wrote != read_back)
        Fail("words written against words the machine read, over the sweep",
             (unsigned long long)read_back, (unsigned long long)wrote);
      keys_swept = wrote;
    }

    // --- THE MOUSE, ONE STEP AT A TIME: THE GRAY ORDER AND THE DIRECTION.
    // muir's `tests/ioboard.rs` walks a rightward move as board-side
    // `(HORB, HORA)` readings 00, 10, 11, 01, 00 with counts 0, 1, 2, 3, 4,
    // and `mouse.rs` says "phase up is to the right and down".  `MOUSE_X`
    // puts `NEW HORA` at bit 12 and `NEW HORB` at 13, so the reading is
    // `(x >> 12) & 3` with bit 13 above bit 12.
    {
      const unsigned want_phase[4] = {2, 3, 1, 0};   // 0b10, 0b11, 0b01, 0b00
      for (unsigned k = 0; k < 4 && bad < 25; ++k) {
        b.Write(INPUT_PAGE + 4 * IN_MOUSE, 1u);      // dx = +1
        long waited = 0;
        while ((b.Read(INPUT_PAGE + 4 * IN_STAT) & IN_ST_OWES) && waited < 8000) ++waited;
        // The card latches the lines on its own `KB CLK^`, up to 8,000 ns
        // after they move.
        b.Idle(2 * KB_CLK_T);
        const unsigned x = b.UbRead(UB_MOUSE_X);
        ++mouse_moved;
        if ((x & 07777u) != k + 1)
          Fail("the mouse's X count after a step to the right", x & 07777u, k + 1);
        if (((x >> 12) & 3u) != want_phase[k])
          Fail("the quadrature the card latched, (HORB, HORA)", (x >> 12) & 3u, want_phase[k]);
        if (((x >> 14) & 3u) != 0)
          Fail("the VERTICAL lines, which a move on X must not touch", (x >> 14) & 3u, 0);
        if ((b.UbRead(UB_MOUSE_Y) & 07777u) != 0)
          Fail("the mouse's Y count during a move on X", b.UbRead(UB_MOUSE_Y) & 07777u, 0);
      }
      // Back to zero, then ONE count below it: the counters are twelve bits
      // and wrap, `mouse::COUNT` being 0o7777.
      b.Write(INPUT_PAGE + 4 * IN_MOUSE, 0xFFCu);    // dx = -4
      long waited = 0;
      while ((b.Read(INPUT_PAGE + 4 * IN_STAT) & IN_ST_OWES) && waited < 40000) ++waited;
      b.Idle(2 * KB_CLK_T);
      if ((b.UbRead(UB_MOUSE_X) & 07777u) != 0)
        Fail("the mouse's X count back at zero", b.UbRead(UB_MOUSE_X) & 07777u, 0);
      b.Write(INPUT_PAGE + 4 * IN_MOUSE, 0xFFFu);    // dx = -1
      waited = 0;
      while ((b.Read(INPUT_PAGE + 4 * IN_STAT) & IN_ST_OWES) && waited < 8000) ++waited;
      b.Idle(2 * KB_CLK_T);
      if ((b.UbRead(UB_MOUSE_X) & 07777u) != 07777u)
        Fail("one count below zero, which wraps at twelve bits",
             b.UbRead(UB_MOUSE_X) & 07777u, 07777u);
      b.Write(INPUT_PAGE + 4 * IN_MOUSE, 1u);
      waited = 0;
      while ((b.Read(INPUT_PAGE + 4 * IN_STAT) & IN_ST_OWES) && waited < 8000) ++waited;
      b.Idle(2 * KB_CLK_T);
      // --- and DOWN is positive on Y.
      b.Write(INPUT_PAGE + 4 * IN_MOUSE, 3u << 12);  // dy = +3
      waited = 0;
      while ((b.Read(INPUT_PAGE + 4 * IN_STAT) & IN_ST_OWES) && waited < 40000) ++waited;
      b.Idle(2 * KB_CLK_T);
      mouse_moved += 3;
      if ((b.UbRead(UB_MOUSE_Y) & 07777u) != 3)
        Fail("the mouse's Y count after three steps down", b.UbRead(UB_MOUSE_Y) & 07777u, 3);
      if ((b.UbRead(UB_MOUSE_X) & 07777u) != 0)
        Fail("the mouse's X count during a move on Y", b.UbRead(UB_MOUSE_X) & 07777u, 0);
      b.Write(INPUT_PAGE + 4 * IN_MOUSE, 0xFFDu << 12);   // dy = -3, back to rest
      waited = 0;
      while ((b.Read(INPUT_PAGE + 4 * IN_STAT) & IN_ST_OWES) && waited < 40000) ++waited;
    }

    // --- THE RATE, WHICH IS THE ONE THING HOLDING THIS ENCODER TO muir.
    // `mouse::MOUSE_STEP_NS` is 16,000 ns of the machine's own time --- "two
    // of the board's 8 us clocks, so that every step is latched into `NEW`
    // and then into `OLD` before the next, and none is missed".  Measured
    // between the FIRST step of a move and the LAST, which has no phase in
    // it: the divider free-runs, so when the first step falls is a matter of
    // where the write landed, and 63 steps after it is not.
    {
      const unsigned kSteps = 64;
      b.Write(INPUT_PAGE + 4 * IN_MOUSE, kSteps);
      long first = 0, last = 0, waited = 0;
      while (waited < 400000) {
        const uint32_t owed = b.Read(INPUT_PAGE + 4 * IN_MOUSE) & 0xFFFu;
        if (owed != kSteps && first == 0) first = tick;
        if (owed == 0) { last = tick; break; }
        ++waited;
      }
      if (!first || !last) {
        Fail("a move of 64 steps never finished", 0, 1);
      } else {
        step_span = (double)(last - first);
        mouse_moved += kSteps;
        const double want = (double)(kSteps - 1) * (double)MOUSE_STEP_T;
        // The two instants are each read by a poll, so each is late by at
        // most one poll; 200 ticks is generous against a poll of about ten
        // and tight against 0.2 per cent of the span.
        if (step_span < want - 200.0 || step_span > want + 200.0)
          Fail("the ticks 63 steps of the mouse took, against 63 x MOUSE_STEP_NS / 5",
               (unsigned long long)step_span, (unsigned long long)want);
      }
      b.Idle(2 * KB_CLK_T);
      if ((b.UbRead(UB_MOUSE_X) & 07777u) != kSteps)
        Fail("the count 64 steps produced --- one a step, none missed",
             b.UbRead(UB_MOUSE_X) & 07777u, kSteps);
    }

    // --- THE THREE SWITCHES, AND WHICH READ OF THE MOUSE CLEARS `MOUSE
    // READY`.  `mouse.rs` says RFB's own mask needs no translation: left 1,
    // middle 2, right 4, and the card puts them at `MOUSE_Y` bits 12, 13 and
    // 14 as `TAILSW`, `MIDSW` and `HEADSW`.  A read of Y clears `MOUSE
    // READY` and a read of X does not, the 74LS109 at IOBCSR 0C26 having
    // `-READ.MOUSE.Y` on its clear.
    {
      (void)b.UbRead(UB_MOUSE_Y);                    // clear whatever stands
      b.Idle(4);
      b.Write(INPUT_PAGE + 4 * IN_BUTTONS, 5u);      // left and right down
      if (b.Read(INPUT_PAGE + 4 * IN_BUTTONS) != 5u)
        Fail("BUTTONS read back", b.Read(INPUT_PAGE + 4 * IN_BUTTONS), 5u);
      b.Idle(2 * KB_CLK_T);
      if (!(b.UbRead(UB_IOB_CSR) & 020u))
        Fail("MOUSE READY after a switch changed, which the 25LS2521 compares "
             "on all seven lines", 0, 1);
      const unsigned y = b.UbRead(UB_MOUSE_Y);
      if (((y >> 12) & 7u) != 5u)
        Fail("the three switches as the machine reads them at MOUSE Y", (y >> 12) & 7u, 5u);
      if ((y >> 15) != 0) Fail("bit 15 of MOUSE Y, which is ground", y >> 15, 0);
      b.Idle(4);
      if (b.UbRead(UB_IOB_CSR) & 020u)
        Fail("MOUSE READY after a read of Y, which must clear it", 1, 0);
      b.Write(INPUT_PAGE + 4 * IN_BUTTONS, 0u);
      b.Idle(2 * KB_CLK_T);
      if (!(b.UbRead(UB_IOB_CSR) & 020u)) Fail("MOUSE READY after the switches lifted", 0, 1);
      (void)b.UbRead(UB_MOUSE_X);
      b.Idle(4);
      if (!(b.UbRead(UB_IOB_CSR) & 020u))
        Fail("MOUSE READY after a read of X, which must NOT clear it", 0, 1);
      (void)b.UbRead(UB_MOUSE_Y);
      b.Idle(4);
      if (b.UbRead(UB_IOB_CSR) & 020u) Fail("MOUSE READY after the read of Y", 1, 0);
    }

    // --- `LINES`, the diagnostic, against what the card actually has.  The
    // whole seam in one word, so that a bring-up on the board can see the
    // cable without a Unibus cycle: the seven lines as the connector sees
    // them, and the card's own `csr_face` beside them.
    {
      b.Write(INPUT_PAGE + 4 * IN_BUTTONS, 5u);
      b.Idle(4);
      const uint32_t lines = b.Read(INPUT_PAGE + 4 * IN_LINES);
      // A pressed switch is pulled to GROUND, so `~5` in the top three; the
      // mouse is at rest, which is both lines of each pair HIGH.
      if ((lines & 0x7Fu) != 0x2Fu)
        Fail("LINES: the seven the mouse is driving, two switches down and at rest",
             lines & 0x7Fu, 0x2Fu);
      const unsigned csr = b.UbRead(UB_IOB_CSR);
      if ((((lines >> 16) & 040u) != 0) != ((csr & 040u) != 0))
        Fail("LINES' copy of the card's KBD READY against the card's own CSR",
             (lines >> 16) & 040u, csr & 040u);
      b.Write(INPUT_PAGE + 4 * IN_BUTTONS, 0u);
    }

    // --- AND LEG 2: A MACHINE RESET EMPTIES THE QUEUE.
    // The console can restart the CADR while Linux runs.  A key typed at the
    // machine that was is not a key typed at the machine that is, and the
    // microcode's first act after the boot PROM is to ask whether anybody is
    // typing --- so a queue that survived the restart would put a word under
    // that test and send the machine down the warm path.  This is the last
    // thing the check does, because it resets the card.
    {
      b.Write(INPUT_PAGE + 4 * IN_CTL, IN_CTL_FLUSH);
      b.Idle(8);
      for (int k = 0; k < 5; ++k) b.Write(INPUT_PAGE + 4 * IN_KEY, KbdWord(KEY_STATUS, false));
      b.Idle(16);
      st = b.Read(INPUT_PAGE + 4 * IN_STAT);
      if (((st >> 8) & 0x3Fu) != 4)
        Fail("four words queued behind the one the card took", (st >> 8) & 0x3Fu, 4);
      if (!(b.UbRead(UB_IOB_CSR) & 040u)) Fail("KBD READY before the machine's reset", 0, 1);
      dut->card_rst = 1;
      b.Idle(8);
      dut->card_rst = 0;
      b.Idle(16);
      st = b.Read(INPUT_PAGE + 4 * IN_STAT);
      if ((st >> 8) & 0x3Fu)
        Fail("the queue after the machine was reset", (st >> 8) & 0x3Fu, 0);
      // And nothing arrives afterwards, for longer than the card's own
      // clock: the machine comes up to a keyboard with nothing in it, which
      // is what `(LOC 6)` needs.
      for (int k = 0; k < 6 && bad < 25; ++k) {
        b.Idle(KB_CLK_T);
        if (b.UbRead(UB_IOB_CSR) & 040u)
          Fail("KBD READY after the machine was reset --- the restarted microcode "
               "would take the WARM boot", 1, 0);
      }
      // The keyboard still works afterwards, which is what says the pending
      // flag was cleared with the queue and not left set on a word whose
      // acknowledgement the reset threw away.
      const uint32_t w = KbdWord(KEY_RETURN, false);
      b.Write(INPUT_PAGE + 4 * IN_KEY, w);
      long waited = 0;
      while (!(b.UbRead(UB_IOB_CSR) & 040u) && waited < 40) ++waited;
      if (!(b.UbRead(UB_IOB_CSR) & 040u)) {
        Fail("a word after the machine's reset: the keyboard is dead", 0, 1);
      } else {
        ++keys_typed;
        const unsigned hi = b.UbRead(UB_KBD_HIGH);
        const unsigned lo = b.UbRead(UB_KBD_LOW);
        if ((((uint32_t)(hi & 0377u) << 16) | lo) != w)
          Fail("the word the machine read after its own reset",
               ((uint32_t)(hi & 0377u) << 16) | lo, w);
      }
    }
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
      "      four pages and a spread over the rest of the gigabyte: %ld to the\n"
      "      pack side, %ld to the Chaosnet cable, %ld to the serial line,\n"
      "      %ld to the keyboard and mouse, %ld to the default slave, each\n"
      "      identified BY ITS OWN REPLY\n"
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
      "      %.0f and %.0f from `Framing::half_bits` and `DIVISORS`; %ld ticks\n"
      "      for a character INTO the machine against the same %.0f, the\n"
      "      receiver's frame being the transmitter's generator again; and %ld\n"
      "      through local loop back with the cable out, which is the leg\n"
      "      that exercises the nine derivations the line transcribes\n"
      "    MIT's own RANDOM/OUTPUT/INPUT walk on vector 0o264, at 9600 baud:\n"
      "      %ld leg streamed \"HELLO CADR\" whole with a handler nine tenths\n"
      "      of a frame late and RANDOM absorbing nothing, and %ld wedged\n"
      "      after one character with it eleven tenths late --- the two\n"
      "      together locate the frame's end where the chip puts it, from the\n"
      "      driver's side\n"
      "    %ld keyboard words the machine read back out of its own two halves,\n"
      "      handed over ONE AT A TIME against the card's KBD READY, which is\n"
      "      `Keyboard::deliver` in fabric; %ld refused on a full queue and\n"
      "      counted in LOST; and %ld more over a twelve-tick sweep whose write\n"
      "      beat is released a counted number of ticks after the card's OWN\n"
      "      answer, so that a put lands on the tick a take does --- the only\n"
      "      thing that can see the queue's count written from two places\n"
      "    %ld mouse steps, the Gray order and the direction against muir's own\n"
      "      00, 10, 11, 01 with counts 1 to 4, the twelve-bit wrap, and\n"
      "      %.0f ticks over 63 steps against 63 x MOUSE_STEP_NS / 5 = %.0f\n"
      "    nothing reached the card's KBD READY until a word was WRITTEN, and\n"
      "      nothing reached it after the machine's own reset: the two legs\n"
      "      that keep a board out of the warm boot at (LOC 6)\n"
      "    every address, length and ID poisoned the tick its handshake was\n"
      "      done, so a match that is read rather than held routes elsewhere\n"
      "    %ld responses and read beats held until they were taken\n"
      "    %ld rates at which a SECOND transmission started after the driver\n"
      "      had turned the transmitter off, which is one `format` and then\n"
      "      another: the sheet has TxEMT go inactive at a disable and stay\n"
      "      there until the enabled transmitter has sent something, with a\n"
      "      character taken IN on each, which the same wedge stopped\n"
      "    %ld disables half a frame into a character whose character still\n"
      "      reached the far end one frame after it started --- the second\n"
      "      with the RECEIVER off too, so that the character in the shift\n"
      "      register was the only thing keeping the crystal running\n",
      pages, reads, writes, by[kPack], by[kChaos], by[kSer], by[kInput], by[kDflt],
      crossed, bursts,
      frames_out, frames_in, chars_out, chars_in, measured[0], measured[1],
      FrameTicks(kMr1, 15), FrameTicks(kMr1, 12), in_span,
      FrameTicks(kMr1, 15), looped,
      walk_streamed, walk_wedged,
      keys_typed, keys_lost, keys_swept, mouse_moved, step_span,
      (double)(64 - 1) * (double)MOUSE_STEP_T, b.stalls, second_streamed, drained_on_time);
  return 0;
}
