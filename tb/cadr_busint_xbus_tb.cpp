// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/machine/cadr_busint_xbus.sv from the reference trace and compares every
// tick. The trace is written by golden/src/busint_xbus.rs out of muir's own
// busint::Busint, and carries the stimulus as well as the expected outputs.
//
// The Xbus slave lives here rather than in the DUT: the trace's `device_ns`
// column says how long it takes, and this counts the ticks from -XBUS.RQ and
// answers. That is what the DUT is being checked against --- a bus interface
// that runs a cycle for whatever is on the bus.
//
// The slave also holds the interface to the bus's own rule about the request,
// which the trace cannot: muir has no -XBUS.RQ to compare against, so the
// only thing that can say the request was held through the acknowledgment is
// the slave that was waiting on it. Found by mutation, issue #2.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vcadr_busint_xbus.h"
#include "verilated.h"
#include "cadr_tick.h"

namespace {

struct Row {
  long tick;
  int n_memrq, wrcyc, device_ns, present, mclk;
  unsigned phys, wdata;
  int boards;
  int n_memgrant, n_memack, n_loadmd, timed_out;
};

int Fail(const Row &r, const char *what, int got, int want) {
  std::fprintf(stderr,
               "tick %ld: %s is %d, reference says %d\n"
               "  inputs: n_memrq=%d wrcyc=%d device_ns=%d mclk=%d\n",
               r.tick, what, got, want, r.n_memrq, r.wrcyc, r.device_ns,
               r.mclk);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/busint_xbus.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  auto *dut = new Vcadr_busint_xbus;
  dut->clk = 0;
  dut->rst = 1;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->dev_ack = 0;
  dut->eval();

  // **MUIR'S t = 0 IS TWO EDGES AFTER THE RESET EDGE, NOT THE RESET EDGE.**
  // Row n is compared as the outputs edge n settled, and that is muir's
  // instant n ticks in: the frame `tb/cadr_machine_tb.cpp` reads the whole
  // machine in, where `-MEMGRANT` falls on the edge muir grants on.  In that
  // frame the machine's power-on --- where muir's ring starts and where
  // `chip::toggle_at` counts the timeout oscillator from --- is two edges
  // after the reset edge: the ring starts on the first edge reset is low
  // (`cadr_phase_gen.sv`), and the processor and this interface take the
  // ring's boundary one edge after the ring makes it (`boundary` in
  // `cadr_microcycle.sv`).  So the reset edge and one idle edge come before
  // row 0 here, as they do on the board.
  //
  // This check used to reset the module ON row 0.  That held the oscillator
  // to a power-on two ticks earlier than the machine has, and it passed
  // with the oscillator two ticks early --- issue #21, which only the whole
  // machine's NXM leg could see.  The two agree now because both are the
  // machine's frame, and `POWER_ON_T` in the module is what they agree on.
  for (int e = 0; e < kPowerOnEdges; ++e) {
    dut->rst = (e == 0);
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();
  }
  dut->rst = 0;

  char line[256];
  long checked = 0;
  int bad = 0;

  // The slave: once -XBUS.RQ is out, answer device_ns later.
  int rq_last = 0;
  long rq_since = -1;

  // Coverage. A trace where nothing was ever granted would agree everywhere
  // and mean nothing, so the run has to show reads and writes, a slave that
  // answers at once and one that takes longer than a microcycle, and a
  // request that arrives on the master clock edge itself.
  long grants = 0, reads = 0, writes = 0, instant = 0, over_a_cycle = 0;
  long rq_on_edge = 0, timeouts = 0, ack_with_rq = 0;
  int memack_last = 1;
  int timed_out_last = 0;
  int memgrant_last = 1;

  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;

    Row r;
    // The address, the word and the board count belong to the whole memory
    // path, not to the interface, but they share one trace so that the
    // stimulus has a single definition. Read past them here.
    int n = std::sscanf(line, "%ld %d %d %d %d %u %u %d %d %d %d %d %d",
                        &r.tick, &r.n_memrq, &r.wrcyc, &r.device_ns,
                        &r.present, &r.phys, &r.wdata, &r.boards, &r.mclk,
                        &r.n_memgrant, &r.n_memack, &r.n_loadmd,
                        &r.timed_out);
    if (n != 13) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }

    dut->mclk = r.mclk;
    dut->n_memrq = r.n_memrq;
    dut->wrcyc = r.wrcyc;

    dut->clk = 1;
    dut->eval();

    // Last tick's -XBUS.RQ, kept before `rq_last` moves on: the rule below
    // is about the tick it falls.
    const int rq_before = rq_last;

    // The slave is combinational, as an Xbus slave is: it sees -XBUS.RQ and
    // answers device_ns later, in the same tick if device_ns is zero. So its
    // answer is worked out after the edge has settled dev_rq, and fed back in
    // with a second eval that moves no register.
    if (dut->dev_rq && !rq_last) rq_since = r.tick;
    if (!dut->dev_rq) rq_since = -1;
    rq_last = dut->dev_rq;

    // Nothing at the address never answers, and the timer is what ends the
    // cycle. That is the stimulus, not something the interface is told.
    dut->dev_ack = r.present && (rq_since >= 0) &&
                   ((r.tick - rq_since) * kGridNs >= r.device_ns);
    dut->eval();

    if (dut->n_memgrant != r.n_memgrant)
      bad += Fail(r, "-MEMGRANT", dut->n_memgrant, r.n_memgrant);
    if (dut->n_memack != r.n_memack)
      bad += Fail(r, "-MEMACK", dut->n_memack, r.n_memack);
    if (dut->n_loadmd != r.n_loadmd)
      bad += Fail(r, "-LOADMD", dut->n_loadmd, r.n_loadmd);
    if (dut->timed_out != r.timed_out)
      bad += Fail(r, "NXM TIMEOUT", dut->timed_out, r.timed_out);

    // "-XBUS.ACK ... remains asserted until the -XBUS.RQ signal is removed
    // by the master" --- so the master holds the request out through the
    // acknowledgment, and lets go only when the cpu lifts -MEMRQ. A slave
    // that obeys the specification holds its answer against the request, and
    // one whose request was withdrawn under it would be left driving the bus
    // at a master that had gone.
    //
    // Nothing above sees this: -MEMGRANT, -MEMACK, -LOADMD and NXM TIMEOUT
    // are all made from the state alone, and dropping the request the moment
    // the cycle was acknowledged moved none of them --- through this path or
    // through the whole memory path either. Issue #2.
    if (rq_before && !dut->dev_rq && !r.n_memrq)
      bad += Fail(r, "-XBUS.RQ, withdrawn while the cpu still wants the cycle",
                  0, 1);
    // And the coverage that says the rule is not vacuous: the acknowledgment
    // has to arrive with the request still out, on some cycle.
    if (!r.n_memack && memack_last) {
      if (dut->dev_rq) ++ack_with_rq;
      else
        bad += Fail(r, "-XBUS.RQ at the acknowledgment", 0, 1);
    }
    memack_last = r.n_memack;

    dut->clk = 0;
    dut->eval();

    if (!r.n_memgrant && memgrant_last) {
      ++grants;
      if (r.wrcyc) ++writes; else ++reads;
      if (r.device_ns == 0) ++instant;
      // Longer than a normal microcycle on the grid: the tap and the
      // restart each rounded up, 85 and 60 ns.
      if (r.device_ns > (GridTicks(85) + GridTicks(60)) * kGridNs) ++over_a_cycle;
      if (r.mclk && !r.n_memrq) ++rq_on_edge;
    }
    memgrant_last = r.n_memgrant;
    if (r.timed_out && !timed_out_last) ++timeouts;
    timed_out_last = r.timed_out;

    ++checked;
    if (bad >= 20) {
      std::fprintf(stderr, "stopping after %d mismatches\n", bad);
      break;
    }
  }

  std::fclose(f);

  // ---- A ONE-TICK REQUEST IS NO REQUEST ---------------------------------
  //
  // The priority logic samples -MEMRQ at the master clock edge and nowhere
  // else, so a request that has gone again by that edge must not be granted.
  // No trace can hold this: in zero delay -MEMRQ never falls between the tick
  // that raises it and the edge, because `memgo_q` follows registers that
  // move only at the boundary.  On silicon it can: `memgo_q` is relaxed to the
  // fast read tap and the map reaches it in about nineteen nanoseconds, so
  // the tick after a boundary that raises MEMSTART can capture a VMAOK still
  // rippling, and on an access that faults that is exactly one tick of
  // request.  Granting it ran a bus cycle nobody asked for.  So this leg
  // drives that tick, and a control beside it drives a request standing at
  // the edge, which must still be granted and run --- or an interface that
  // never granted anything would pass.
  long one_tick_legs = 0, standing_legs = 0;
  if (!bad) {
    auto step = [&](int n_memrq, int mclk) {
      dut->n_memrq = n_memrq;
      dut->mclk = mclk;
      dut->wrcyc = 0;
      dut->clk = 1;
      dut->eval();
      // The slave answers at once: the control leg needs its cycle to end.
      dut->dev_ack = dut->dev_rq;
      dut->eval();
      dut->clk = 0;
      dut->eval();
    };
    // Whatever the trace left standing, let it finish and come back to IDLE.
    for (int k = 0; k < 20000 && dut->busy; ++k) step(1, (k % 15) == 14);
    if (dut->busy) {
      std::fprintf(stderr, "directed leg: the interface never returned to IDLE\n");
      ++bad;
    }

    if (!bad) {
      step(0, 0);  // one tick of -MEMRQ, between master clock edges
      const int entered = dut->busy;
      int granted = 0, rq = 0;
      for (int k = 0; k < 5; ++k) {
        step(1, 0);
        granted |= !dut->n_memgrant;
        rq |= dut->dev_rq;
      }
      step(1, 1);  // the edge, with the request gone
      granted |= !dut->n_memgrant;
      rq |= dut->dev_rq;
      const int busy_after = dut->busy;
      for (int k = 0; k < 40; ++k) {
        step(1, 0);
        granted |= !dut->n_memgrant;
        rq |= dut->dev_rq;
      }
      if (!entered) {
        std::fprintf(stderr, "directed leg: one tick of -MEMRQ did not leave "
                             "IDLE, so the leg tests nothing\n");
        ++bad;
      }
      if (granted || rq) {
        std::fprintf(stderr,
                     "directed leg: ONE TICK of -MEMRQ, gone by the master "
                     "clock edge, was granted (-MEMGRANT %s, -XBUS.RQ %s): a "
                     "bus cycle the processor never asked for\n",
                     granted ? "fell" : "held", rq ? "rose" : "held");
        ++bad;
      }
      if (busy_after) {
        std::fprintf(stderr, "directed leg: still busy after the edge that "
                             "found no request\n");
        ++bad;
      }
      if (!bad) ++one_tick_legs;
    }

    if (!bad) {
      for (int k = 0; k < 6; ++k) step(0, 0);  // the same request, standing
      step(0, 1);                              // at the edge
      const int granted = !dut->n_memgrant;
      int rq = 0, acked = 0;
      for (int k = 0; k < 40 && !acked; ++k) {
        step(0, 0);
        rq |= dut->dev_rq;
        acked |= !dut->n_memack;
      }
      for (int k = 0; k < 20 && dut->busy; ++k) step(1, 0);
      if (!granted || !rq || !acked || dut->busy) {
        std::fprintf(stderr,
                     "directed leg: a request standing at the master clock "
                     "edge was not granted and run (granted %d, -XBUS.RQ %d, "
                     "-MEMACK %d, back in IDLE %d)\n",
                     granted, rq, acked, !dut->busy);
        ++bad;
      } else {
        ++standing_legs;
      }
    }
  }

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, checked);
    return 1;
  }
  if (checked == 0) {
    std::fprintf(stderr, "FAIL: the trace was empty\n");
    return 1;
  }

  int thin = 0;
  const struct {
    const char *what;
    long n;
  } want[] = {{"grants", grants},
              {"reads", reads},
              {"writes", writes},
              {"cycles answered at once", instant},
              {"cycles slower than a microcycle", over_a_cycle},
              {"requests standing at the master clock edge", rq_on_edge},
              {"cycles that timed out", timeouts},
              {"cycles acknowledged with -XBUS.RQ still out", ack_with_rq}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the trace has no %s\n", w.what);
      ++thin;
    }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks agree with muir's busint::Busint\n"
      "    %ld cycles --- %ld reads, %ld writes, %ld answered at once, "
      "%ld slower than a microcycle, %ld timed out\n"
      "    %ld acknowledged with -XBUS.RQ still out\n"
      "    %ld one-tick request gone by the edge and not granted, %ld standing "
      "at the edge and run\n",
      checked, grants, reads, writes, instant, over_a_cycle, timeouts,
      ack_with_rq, one_tick_legs, standing_legs);
  return 0;
}
