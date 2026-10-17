// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE MACHINE IS HELD IN RESET UNTIL ITS MEMORY PORT IS LIVE**, on the
// Zynq boards' revision 15 top levels: `boards/arty-z7-20/quux15_arty.sv`
// (built with `QUUX15_ARTY`) and `boards/kria-kr260/quux15_kr260.sv`
// (`QUUX15_KRIA`), each simulated around the processing system's simulation
// (`tb/cadr_ps7_sim.sv`, `tb/cadr_ps8_sim.sv`), the Xilinx primitives' stubs
// and the core as a shell (`tb/quux15_core_shell.sv`).  The DE25-Nano's top
// level has the same property held by `tb/quux15_de25_top_tb.cpp`, through
// its memory port's gate; here the port's reset is the processing system's
// own (`S_AXI_HP0`'s on the Arty Z7-20, `pl_resetn0` on the Kria KR260), level
// 0 of `cadr_sim_level`, which this file drives.
//
// WHAT IS HELD, by the core's two resets as the shell sees them, its hard
// `rst` and its request `rst_req` (`quux15_core.sv`'s `rq_*`):
//   - with the port in reset, the core's hard reset is up every clock, the
//     fabric's own reset long over (the MMCM's stub locks at once);
//   - the port let out of reset, the core is let go within `kBound` clocks,
//     the synchronizer's three stages and the register behind them;
//   - the port put back into reset under a running core, the hard reset is
//     up again within `kBound` clocks and stays there while the port is;
//   - the console face's RESET key, written on the face's page, is a
//     request and never the hard reset; the write is answered once the core
//     has been through its reset (the shell's `rst_on`, which this file plays
//     as a core whose port drains at once), and, with a core that never
//     takes the request, at the face's bound (`ANSWER_T`), word 6 then
//     saying so in its <2>;
//   - on the Arty Z7-20, BTN1 is a request and never the hard reset.
// The processing system's ports are otherwise idle: its general-purpose
// masters ask only for the face's words and its memory answers nothing.
//
// **AND THE ETHERNET DEVICE'S PAGE WHERE ITS PROGRAM LOOKS** (QUUX's
// Ethernet contract, section 10), at the address `quux-ethernet-device`
// maps, `cadr_board.h`'s `CADR_BOARD_PACK_BASE` and `qed_face.h`'s
// `QED_FACE_OFFSET`, both included here: built with `QUUX15_REVISION` 16 the
// page reads IDENT "QE16" and a COUNTS write there reaches the core's
// Ethernet host side as index 11 with its word; built at 15 the page is the
// default slave's, "NONE", and the core's Ethernet side sees nothing.

#include <cstdarg>
#include <cstdio>

#ifdef QUUX15_ARTY
#include "Vquux15_arty.h"
#include "Vquux15_arty__Dpi.h"
#include "Vquux15_arty___024root.h"
using Top = Vquux15_arty;
using Root = Vquux15_arty___024root;
#define CORE_I(n) (r->quux15_arty__DOT__u_core__DOT__tbi_##n)
#define CORE_O(n) (r->quux15_arty__DOT__u_core__DOT__tbo_##n)
constexpr unsigned kFace = 0x80000000u;
#define BOARD "the Arty Z7-20"
#else
#include "Vquux15_kr260.h"
#include "Vquux15_kr260__Dpi.h"
#include "Vquux15_kr260___024root.h"
using Top = Vquux15_kr260;
using Root = Vquux15_kr260___024root;
#define CORE_I(n) (r->quux15_kr260__DOT__u_core__DOT__tbi_##n)
#define CORE_O(n) (r->quux15_kr260__DOT__u_core__DOT__tbo_##n)
constexpr unsigned kFace = 0xB0000000u;
#define BOARD "the Kria KR260"
#endif
#include "verilated.h"
#include "svdpi.h"

#define _Static_assert static_assert
extern "C" {
#include "cadr/cadr_board.h"
#include "qed_face.h"
}
#undef _Static_assert
#ifndef QUUX15_REVISION
#define QUUX15_REVISION 15
#endif

namespace {

Top *top = nullptr;
Root *r = nullptr;
long t = 0;
int fails = 0;
int level0 = 0;
constexpr long kBound = 8;
// The face's bound on its answer to a RESET write (`quux15_face.sv`).
constexpr long kAnswerBound = 131072;
// Whether the shell plays a core that takes its request: its `rst_on` the
// hard reset or the request, as a core whose port is empty.
bool core_takes = true;
// The core's Ethernet host side as the shell sees it: its writes counted,
// the last's index and word.
long eth_writes = 0;
unsigned eth_idx = 0, eth_word = 0;

// The processing system's store and load on the face's port (GP 1): 0 idle,
// 1 address and word offered, 2 waiting for B, 3 read offered, 4 waiting for
// R.  What came back, and the clocks.
int gp_state = 0, gp_port = 1;
unsigned gp_addr = 0, gp_data = 0, gp_read = 0;
bool aw_out = false, w_out = false, ar_out = false;
long gp_wrote = -1, gp_answered = -1;
void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: %s, clock %ld: ", BOARD, t);
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

void Tick() {
  CORE_O(rst_on) = core_takes && (CORE_I(rst) || CORE_I(rst_req));
  CORE_O(rst_pend) = 0;
  CORE_O(rst_cut) = 0;
#ifdef QUUX15_ARTY
  top->sysclk = 0;
  top->eval();
  top->sysclk = 1;
  top->eval();
#else
  top->clk25 = 0;
  top->eval();
  top->clk25 = 1;
  top->eval();
#endif
  if (CORE_I(eth_we)) {
    ++eth_writes;
    eth_idx = CORE_I(eth_widx);
    eth_word = CORE_I(eth_wdata);
  }
  ++t;
}

long ReqHeld(long n) {
  long held = 0;
  for (long i = 0; i < n; ++i) {
    Tick();
    if (CORE_I(rst_req)) ++held;
  }
  return held;
}

long Held(long n) {
  long held = 0;
  for (long i = 0; i < n; ++i) {
    Tick();
    if (CORE_I(rst)) ++held;
  }
  return held;
}

template <typename F>
long Until(F cond, long limit) {
  for (long i = 0; i <= limit; ++i) {
    if (cond()) return i;
    Tick();
  }
  return -1;
}

}  // namespace

// The processing system's side, through `tb/cadr_sim_axi.sv`: masters that
// ask nothing, memory that answers nothing, and the port's reset.
void cadr_sim_gp(int port, svBit awready, svBit wready, svBit bvalid, int, int, svBit arready, svBit rvalid,
                 int rdata, int, int, svBit, int *awaddr, int *awlen, int *awid, svBit *awvalid, int *wdata,
                 int *wstrb, svBit *wlast, svBit *wvalid, svBit *bready, int *araddr, int *arlen, int *arid,
                 svBit *arvalid, svBit *rready) {
  *awaddr = *awlen = *awid = *wdata = *wstrb = *araddr = *arlen = *arid = 0;
  *awvalid = *wvalid = *wlast = *arvalid = 0;
  *bready = *rready = 1;
  if (port != gp_port) return;
  // A handshake: what this side drove from the last edge, and the other
  // side's ready before this one.
  static bool aw_drv = false, w_drv = false, ar_drv = false;
  if (gp_state == 1) {
    if (aw_drv && awready) aw_out = false;
    if (w_drv && wready) w_out = false;
    if (!aw_out && !w_out) gp_state = 2;
  } else if (gp_state == 2 && bvalid) {
    gp_answered = t;
    gp_state = 0;
  } else if (gp_state == 3 && ar_drv && arready) {
    ar_out = false;
    gp_state = 4;
  } else if (gp_state == 4 && rvalid) {
    gp_read = static_cast<unsigned>(rdata);
    gp_state = 0;
  }
  aw_drv = aw_out;
  w_drv = w_out;
  ar_drv = ar_out;
  *awaddr = static_cast<int>(gp_addr);
  *araddr = static_cast<int>(gp_addr);
  *wdata = static_cast<int>(gp_data);
  *wstrb = 0xF;
  *wlast = 1;
  *awvalid = aw_out;
  *wvalid = w_out;
  *arvalid = ar_out;
}

// A word of the faces' port (GP 0), written and answered, or read.
void PortWrite(unsigned addr, unsigned v) {
  gp_port = 0;
  gp_addr = addr;
  gp_data = v;
  aw_out = w_out = true;
  gp_state = 1;
  gp_wrote = t;
  gp_answered = -1;
  for (int i = 0; i < 200 && gp_state != 0; ++i) Tick();
  gp_port = 1;
}
unsigned PortRead(unsigned addr) {
  gp_port = 0;
  gp_addr = addr;
  ar_out = true;
  gp_state = 3;
  for (int i = 0; i < 200 && gp_state != 0; ++i) Tick();
  gp_port = 1;
  return gp_read;
}

// The face's word `k`, written and answered, or read.
void FaceWrite(unsigned k, unsigned v) {
  gp_addr = kFace + 4 * k;
  gp_data = v;
  aw_out = w_out = true;
  gp_state = 1;
  gp_wrote = t;
  gp_answered = -1;
}
unsigned FaceRead(unsigned k) {
  gp_addr = kFace + 4 * k;
  ar_out = true;
  gp_state = 3;
  for (int i = 0; i < 200 && gp_state != 0; ++i) Tick();
  return gp_read;
}

void cadr_sim_mem(int, svBit, int, int, int, svBit, long long, int, svBit, svBit, svBit, int, int, int,
                             svBit, svBit, svBit *awready, svBit *wready, svBit *bvalid, int *bresp, int *bid,
                             svBit *arready, svBit *rvalid, long long *rdata, int *rresp, int *rid, svBit *rlast) {
  *awready = *wready = *bvalid = *arready = *rvalid = *rlast = 0;
  *bresp = *bid = *rresp = *rid = 0;
  *rdata = 0;
}

int cadr_sim_level(int which) { return which == 0 ? level0 : 0; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Top;
  r = top->rootp;
#ifdef QUUX15_ARTY
  top->btn = 0;
  top->sw = 0;
#endif
  top->eval();

  // The port in reset: the core with it, every clock after the fabric's
  // reset is over.
  Held(20);
  long held = Held(300);
  Check(held == 300, "the core was out of reset %ld clocks of 300 with its memory port in reset", 300 - held);
  // The port out of reset.
  level0 = 1;
  const long let_go = Until([] { return CORE_I(rst) == 0; }, 100);
  Check(let_go >= 0 && let_go <= kBound, "the core left reset %ld clocks after its port, wanting within %ld", let_go,
        kBound);
  held = Held(200);
  Check(held == 0, "the core was in reset %ld clocks of 200 with its port live", held);
  // The port back into reset under a running core.
  level0 = 0;
  const long caught = Until([] { return CORE_I(rst) != 0; }, 100);
  Check(caught >= 0 && caught <= kBound, "the core went into reset %ld clocks after its port, wanting within %ld",
        caught, kBound);
  held = Held(200);
  Check(held == 200, "the core was out of reset %ld clocks of 200 with its port in reset again", 200 - held);
  level0 = 1;
  Check(Until([] { return CORE_I(rst) == 0; }, 100) >= 0, "the core never left reset after its port did again");
  Held(50);

  // The console face's RESET key: a request, the hard reset untouched, the
  // write answered once the core has been through its reset.
  constexpr unsigned kResetWord = 6, kResetKey = 0x52534554u;
  FaceWrite(kResetWord, kResetKey);
  long req_seen = 0, hard_seen = 0;
  for (int i = 0; i < 2000 && gp_answered < 0; ++i) {
    Tick();
    if (CORE_I(rst_req)) ++req_seen;
    if (CORE_I(rst)) ++hard_seen;
  }
  const long answered = gp_answered - gp_wrote;
  Check(req_seen > 0, "the face's RESET key never asked for the core's reset");
  Check(hard_seen == 0, "the face's RESET key gave the core its hard reset for %ld clocks", hard_seen);
  Check(gp_answered >= 0 && answered < 200, "the RESET write was answered %ld clocks after it, wanting soon after "
        "the core's reset", answered);
  unsigned w6 = FaceRead(kResetWord);
  Check((w6 & 0xFFFF0000u) == 0x52530000u && (w6 & 0xF) == 0, "word 6 reads %08x after a reset the core took", w6);
  // A core that never takes the request: the answer at the face's bound,
  // and word 6 says so.
  core_takes = false;
  Held(10);
  FaceWrite(kResetWord, kResetKey);
  for (long i = 0; i < kAnswerBound + 1000 && gp_answered < 0; ++i) Tick();
  const long bounded = gp_answered < 0 ? -1 : gp_answered - gp_wrote;
  Check(bounded >= kAnswerBound && bounded <= kAnswerBound + 16,
        "with the core not taking the request the RESET write was answered %ld clocks after it, wanting the "
        "face's bound, %ld", bounded, kAnswerBound);
  w6 = FaceRead(kResetWord);
  Check(((w6 >> 2) & 1) == 1, "word 6 reads %08x after an answer at the bound, wanting <2> set", w6);
  core_takes = true;
  Held(100);
#ifdef QUUX15_ARTY
  // BTN1: a request, the hard reset untouched.
  top->btn = 2;
  const long btn_req = ReqHeld(100);
  long btn_hard = 0;
  for (int i = 0; i < 100; ++i) {
    Tick();
    if (CORE_I(rst)) ++btn_hard;
  }
  top->btn = 0;
  Check(btn_req >= 100 - kBound, "BTN1 held asked for the core's reset %ld clocks of 100", btn_req);
  Check(btn_hard == 0, "BTN1 gave the core its hard reset for %ld clocks", btn_hard);
  Check(Until([] { return CORE_I(rst_req) == 0; }, 100) >= 0, "the request stood after BTN1 was let go");
#endif

  // **THE ETHERNET DEVICE'S PAGE**, where its program maps it.
  constexpr unsigned kPage = CADR_BOARD_PACK_BASE + QED_FACE_OFFSET;
  const long eth_before = eth_writes;
  const unsigned ident = PortRead(kPage);
  PortWrite(kPage + 0x12C, 0x01021A30u);
  Held(400);
  eth_writes -= eth_before;
#if QUUX15_REVISION == 16
  Check(ident == 0x51453136u, "the Ethernet device's page at %08x reads %08x, wanting \"QE16\"", kPage, ident);
  Check(eth_writes == 1 && eth_idx == 11 && eth_word == 0x01021A30u,
        "a COUNTS write at %08x reached the core's Ethernet side %ld times, index %u, word %08x", kPage + 0x12C,
        eth_writes, eth_idx, eth_word);
#else
  Check(ident == 0x4E4F4E45u, "the page at %08x reads %08x on revision 15, wanting the default's \"NONE\"", kPage,
        ident);
  Check(eth_writes == 0, "a write at %08x reached the core's Ethernet side on revision 15", kPage + 0x12C);
#endif

  delete top;
  if (fails) {
    std::fprintf(stderr, "quux15 reset hold, %s: FAILED, %d checks\n", BOARD, fails);
    return 1;
  }
  std::printf("quux15 reset hold, %s: ok, the core held while its memory port is in reset, let go %ld clocks after "
              "it, reset again %ld clocks after it; the RESET key a request, answered %ld clocks after the write, "
              "and at the face's bound, %ld, when the core does not take it; revision %d's page at %08x reads "
              "%08x\n", BOARD, let_go, caught, answered, bounded, QUUX15_REVISION, kPage, ident);
  return 0;
}
