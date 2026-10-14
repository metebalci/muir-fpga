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
// WHAT IS HELD, by the core's `rst` as the shell sees it:
//   - with the port in reset, the core is in reset every clock, the
//     fabric's own reset long over (the MMCM's stub locks at once);
//   - the port let out of reset, the core is let go within `kBound` clocks,
//     the synchronizer's three stages and the register behind them;
//   - the port put back into reset under a running core, the core is in
//     reset again within `kBound` clocks and stays there while the port is.
// The processing system's ports are otherwise idle: its general-purpose
// masters ask nothing and its memory answers nothing.

#include <cstdarg>
#include <cstdio>

#ifdef QUUX15_ARTY
#include "Vquux15_arty.h"
#include "Vquux15_arty__Dpi.h"
#include "Vquux15_arty___024root.h"
using Top = Vquux15_arty;
using Root = Vquux15_arty___024root;
#define CORE_I(n) (r->quux15_arty__DOT__u_core__DOT__tbi_##n)
#define BOARD "the Arty Z7-20"
#else
#include "Vquux15_kr260.h"
#include "Vquux15_kr260__Dpi.h"
#include "Vquux15_kr260___024root.h"
using Top = Vquux15_kr260;
using Root = Vquux15_kr260___024root;
#define CORE_I(n) (r->quux15_kr260__DOT__u_core__DOT__tbi_##n)
#define BOARD "the Kria KR260"
#endif
#include "verilated.h"
#include "svdpi.h"

namespace {

Top *top = nullptr;
Root *r = nullptr;
long t = 0;
int fails = 0;
int level0 = 0;
constexpr long kBound = 8;

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
  ++t;
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
void cadr_sim_gp(int, svBit, svBit, svBit, int, int, svBit, svBit, int, int, int, svBit, int *awaddr,
                            int *awlen, int *awid, svBit *awvalid, int *wdata, int *wstrb, svBit *wlast,
                            svBit *wvalid, svBit *bready, int *araddr, int *arlen, int *arid, svBit *arvalid,
                            svBit *rready) {
  *awaddr = *awlen = *awid = *wdata = *wstrb = *araddr = *arlen = *arid = 0;
  *awvalid = *wvalid = *wlast = *arvalid = 0;
  *bready = *rready = 1;
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

  delete top;
  if (fails) {
    std::fprintf(stderr, "quux15 reset hold, %s: FAILED, %d checks\n", BOARD, fails);
    return 1;
  }
  std::printf("quux15 reset hold, %s: ok, the core held while its memory port is in reset, let go %ld clocks after "
              "it, reset again %ld clocks after it\n", BOARD, let_go, caught);
  return 0;
}
