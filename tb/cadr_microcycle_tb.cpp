// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/cadr_microcycle.sv from muir's own trace and compares every
// microcycle.  The trace is written by golden/src/rtl.rs out of muir's `rtl`
// engine running MIT's boot PROM: a real program, not a scripted stimulus.
//
// One row is one microcycle.  The DUT runs on its own 200 MHz clock and says
// when a microcycle ended, on `clock_edge`; the values compared are the ones
// standing *before* that edge, which is the read phase the row describes ---
// `Rtl::signals` is "recorded in the read phase, where the sources drive and
// the ALU result is up but nothing has been written back".
//
// WHAT IS STIMULUS.  There is no ALU yet, so four things come out of the trace
// rather than out of the DUT: `jcond` off the ALU, `ob` for L and the OA
// substitution into IR, `m` for the word a WRITE-I-MEM stores, and the
// console's registers.  Every one leaves with a later slice.  They are
// counted and printed, so what this check is still being told rather than
// checking is on its own output.
//
// WHAT IS CHECKED.  PC, IR, LPC, OPC, ST, the A bus, LC, and the four
// sequencing flags NOP, PCS1, PCS0 and IWRITED --- which the DUT computes
// from IR and JCOND alone --- and the length of every microcycle in 200 MHz
// ticks.  PC now goes through the fabric's own stack on a POPJ rather than
// being handed the answer.
//
// WHAT THE CHECKED SIGNALS ARE WORTH, measured by mutation rather than
// assumed.  The A bus is the strong one: 96,192 distinct values over the run,
// and it catches a wrong write address, wrong write data, and the ACTL
// pass-around inverted or removed.  RETA's mux, WPC and the stack's push
// pass-around are each caught through PC on the 16,384 POPJs.  Against that:
//
//   - LC is **zero on every one of the 600,000 rows**.  The boot PROM never
//     runs macrocode, so the location counter never moves and its check is
//     vacuous.  Asserted below, so a trace that does move it re-opens this.
//   - The stack's RAM and pointer are **never read**.  Every push here is
//     popped by the very next microcycle, which takes SPCWPASS --- the word
//     standing on the SPC bus --- and not the 82S21s' output.  Moving SPCPTR
//     by two, or never writing the RAM at all, survives this check.
//   - The ALATCH/MLATCH gating is not distinguished: making the latches
//     transparent through the write phase survives, because the one overlap
//     it could show --- a write to the address being read --- is exactly what
//     the pass-around covers.  It is right for synthesis, not for this trace.
//   - The WADR/AADR comparator's top bit is never the one that differs, so a
//     nine-bit compare survives a ten-bit one.
//
// WHAT THIS PROGRAM DOES NOT EXERCISE, asserted here rather than assumed, so
// that a trace which reaches further re-opens each claim: every DISPATCH in
// it is a DISPWR, so the dispatch memory is written and never read and
// `dr`/`dp`/`dn`/`dpc` do not matter; it never halts; it never sets IR<46>,
// so the statistics counter never counts; it never sets PROMDISABLE, so it
// never runs the microcode it loads; and it runs at extra slow throughout,
// where both taps of the 74S151 are -TPR160 --- so ILONG changes nothing and
// the -NOPA gate on it at FLAG 3E07 is unchecked.  The scripted trace behind
// cadr_phase_gen.sv is what covers the seven taps.
//
// The control store comes up all ones rather than zero, and that is what
// makes the 16,384 words the boot PROM writes worth writing: every one of
// them is zero, so with the RAM coming up zero a write that never happened
// reads back exactly like one that did.  rtl/cadr_microcycle.sv says so at
// the array.

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <vector>

#include "Vcadr_microcycle.h"
#include "verilated.h"

namespace {

// Five nanoseconds, the master clock's period.
constexpr int kTickNs = 5;

// The trace's columns, in the order golden/src/rtl.rs prints them.
enum Col {
  kCycle, kPc, kIr, kQ, kA, kM, kAlu, kR, kOb, kDc, kOpc, kSt, kLc,
  kWmapd, kDestspcd, kIwrited, kImodd, kPdlwrited, kSpushd, kNop, kNVmaok,
  kJcond, kPcs1, kPcs0, kSrun,
  kLpc, kPromdis, kErrstop, kStathenb, kSpeed1, kSpeed0,
  kStall, kHalted, kBus, kNs,
  kColumns
};

struct Row {
  uint64_t v[kColumns];
};

int Fail(const Row &r, const char *what, uint64_t got, uint64_t want) {
  std::fprintf(stderr,
               "microcycle %" PRIu64 " (PC %" PRIo64 "): %s is %" PRIx64
               ", reference says %" PRIx64 "\n"
               "  IR %" PRIo64 "  NOP %" PRIu64 "  JCOND %" PRIu64
               "  PCS %" PRIu64 "%" PRIu64 "\n",
               r.v[kCycle], r.v[kPc], what, got, want, r.v[kIr], r.v[kNop],
               r.v[kJcond], r.v[kPcs1], r.v[kPcs0]);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // The whole trace is held: the SPC target for a POPJ is the PC the next
  // microcycle runs at, so a row is not complete until the one after it is
  // read.  That is the stack's word arriving from the trace, and it goes
  // when slice 2 builds the stack.
  std::vector<Row> rows;
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    Row r;
    const char *p = line;
    int i = 0;
    for (; i < kColumns; ++i) {
      char *end = nullptr;
      r.v[i] = std::strtoull(p, &end, 16);
      if (end == p) break;
      p = end;
    }
    if (i != kColumns) {
      std::fprintf(stderr, "%s: row %zu has %d columns, wanted %d\n", path,
                   rows.size(), i, kColumns);
      return 2;
    }
    rows.push_back(r);
  }
  std::fclose(f);

  if (rows.size() < 2) {
    std::fprintf(stderr, "FAIL: %s carries %zu microcycles\n", path,
                 rows.size());
    return 1;
  }

  auto *dut = new Vcadr_microcycle;
  dut->clk = 0;
  dut->rst = 1;
  dut->hang = 0;
  dut->dr = 0;
  dut->dp = 0;
  dut->dn = 0;
  dut->dpc = 0;
  // Verilator records the previous value of a clock at eval time, so the
  // first eval has to happen with clk low or the first posedge is not one.
  dut->eval();

  // Present row `k`'s stimulus: what the datapath would be driving over that
  // microcycle, and what the console would be holding.
  auto drive = [&](size_t k) {
    const Row &r = rows[k];
    dut->jcond = static_cast<uint8_t>(r.v[kJcond]);
    dut->ob = static_cast<uint32_t>(r.v[kOb]);
    dut->m = static_cast<uint32_t>(r.v[kM]);
    dut->srun = static_cast<uint8_t>(r.v[kSrun]);
    dut->promdisable = static_cast<uint8_t>(r.v[kPromdis]);
    dut->errstop = static_cast<uint8_t>(r.v[kErrstop]);
    dut->stathenb = static_cast<uint8_t>(r.v[kStathenb]);
    dut->mode_speed =
        static_cast<uint8_t>((r.v[kSpeed1] << 1) | (r.v[kSpeed0] & 1));
  };

  // What the DUT held over the microcycle now ending: sampled every tick, so
  // that the edge is compared against the read phase before it and not
  // against the values the edge has just produced.
  struct Sample {
    uint64_t pc, ir, lpc, opc, st, a, lc, nop, pcs1, pcs0, iwrited;
  };
  auto take = [&]() {
    return Sample{dut->pc, dut->ir,  dut->lpc,  dut->opc,  dut->st, dut->a,
                  dut->lc, dut->nop, dut->pcs1, dut->pcs0, dut->iwrited};
  };

  drive(0);
  Sample prev = take();

  size_t k = 0;          // the microcycle now running
  long last_edge = -1;   // -1 until the first, whose length has no start
  int bad = 0;

  // Coverage, and the assertions that say what this program leaves untouched.
  long lengths_checked = 0, dispatches = 0, disp_reads = 0, halts = 0;
  long iwrites = 0, popjs = 0, jumps = 0, prom_fetches = 0, ram_fetches = 0;
  long stat_counts = 0, stalls = 0, ram_executes = 0, other_speed = 0;
  long lc_moved = 0;
  std::set<uint64_t> a_values;

  // Long enough for every microcycle plus the reset and a margin: the
  // longest cycle the generator makes is 44 ticks at extra slow.
  const long kMaxTicks = static_cast<long>(rows.size()) * 64 + 1024;

  for (long t = 0; t < kMaxTicks && k < rows.size(); ++t) {
    if (t == 4) dut->rst = 0;

    dut->clk = 1;
    dut->eval();

    if (dut->clock_edge) {
      const Row &r = rows[k];

      if (prev.pc != r.v[kPc]) bad += Fail(r, "PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) bad += Fail(r, "IR", prev.ir, r.v[kIr]);
      if (prev.lpc != r.v[kLpc]) bad += Fail(r, "LPC", prev.lpc, r.v[kLpc]);
      if (prev.opc != r.v[kOpc]) bad += Fail(r, "OPC", prev.opc, r.v[kOpc]);
      if (prev.st != r.v[kSt]) bad += Fail(r, "ST", prev.st, r.v[kSt]);
      if (prev.a != r.v[kA]) bad += Fail(r, "the A bus", prev.a, r.v[kA]);
      if (prev.lc != r.v[kLc]) bad += Fail(r, "LC", prev.lc, r.v[kLc]);
      if (prev.nop != r.v[kNop]) bad += Fail(r, "NOP", prev.nop, r.v[kNop]);
      if (prev.pcs1 != r.v[kPcs1]) bad += Fail(r, "PCS1", prev.pcs1, r.v[kPcs1]);
      if (prev.pcs0 != r.v[kPcs0]) bad += Fail(r, "PCS0", prev.pcs0, r.v[kPcs0]);
      if (prev.iwrited != r.v[kIwrited])
        bad += Fail(r, "IWRITED", prev.iwrited, r.v[kIwrited]);

      // The microcycle's own length.  muir charges the stall before the
      // cycle and the cycle after it, so what the generator owes is the
      // interval less the stall.  Nothing here raises -HANG --- VCTL1 is
      // slice 5 --- so the DUT runs the cycles back to back and the stall is
      // arithmetic rather than a driven input.
      if (last_edge >= 0) {
        const uint64_t before = (k == 0) ? 0 : rows[k - 1].v[kNs];
        const uint64_t want = r.v[kNs] - before - r.v[kStall];
        const uint64_t got = static_cast<uint64_t>(t - last_edge) * kTickNs;
        if (got != want) bad += Fail(r, "the microcycle in ns", got, want);
        ++lengths_checked;
      }
      if (r.v[kStall]) ++stalls;
      if (r.v[kLc]) ++lc_moved;
      a_values.insert(r.v[kA]);
      // Extra slow is {SPEED1,SPEED0} = 00, where both taps of the 74S151 are
      // -TPR160 and ILONG changes nothing.  Asserted rather than assumed, so
      // that a trace which does change speed re-opens the claim below.
      if (r.v[kSpeed1] || r.v[kSpeed0]) ++other_speed;

      // What the program reaches, and what it does not.
      if (r.v[kNop] == 0) {
        const uint64_t cls = (r.v[kIr] >> 43) & 3;
        const uint64_t funct = (r.v[kIr] >> 10) & 3;
        if (cls == 2) {
          ++dispatches;
          // DISPWR is misc function 2, which is what makes the dispatch a
          // write of the memory rather than a read of it.  If this ever
          // fails the dispatch memory is being read and slice 1 cannot
          // answer for where the machine goes next.
          if (funct != 2) ++disp_reads;
        }
        if (cls == 1 && ((r.v[kIr] >> 8) & 3) == 3) ++iwrites;
        if (((r.v[kIr] >> 46) & 1) != 0) ++stat_counts;
      }
      if (r.v[kPcs1] == 0 && r.v[kPcs0] == 0) ++popjs;
      if (r.v[kPcs1] == 0 && r.v[kPcs0] == 1) ++jumps;
      if (r.v[kSrun] == 0 || r.v[kHalted] != 0) ++halts;
      // -PROMENABLE at PCTL 1C19.  Everything else comes out of the control
      // store RAM, which here is every WRITE-I-MEM reading back the word its
      // own write pulse has just put there.
      if (r.v[kPc] < 1024 && r.v[kPromdis] == 0 && r.v[kIwrited] == 0)
        ++prom_fetches;
      else
        ++ram_fetches;
      // ...and none of them is the machine *running* the microcode it has
      // loaded: this program never gets past the disk wait to `JUMP-TO-6`,
      // so PROMDISABLE is never set and every fetch above the PROM is a
      // write-back.  Said here so the gap is on the check's own output.
      if (r.v[kIwrited] == 0 && r.v[kPc] >= 1024) ++ram_executes;

      last_edge = t;
      ++k;
      if (k < rows.size()) drive(k);

      if (bad >= 20) {
        std::fprintf(stderr, "stopping after %d mismatches\n", bad);
        break;
      }
    }

    dut->clk = 0;
    dut->eval();
    prev = take();
  }

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %zu microcycles\n", bad, k);
    return 1;
  }
  if (k != rows.size()) {
    std::fprintf(stderr,
                 "FAIL: the run stopped after %zu of %zu microcycles --- the "
                 "generator is not making a boundary\n",
                 k, rows.size());
    return 1;
  }

  // A run that agreed everywhere while reaching nothing would pass and mean
  // nothing.  These are what it has to have reached, and what it has to have
  // left alone for the holes above to be the size they are claimed to be.
  int thin = 0;
  if (disp_reads) {
    std::fprintf(stderr,
                 "FAIL: %ld dispatches are not DISPWR, so the dispatch memory "
                 "is read and the NPC mux has an answer this slice cannot give\n",
                 disp_reads);
    ++thin;
  }
  if (halts) {
    std::fprintf(stderr,
                 "FAIL: the machine halted on %ld microcycles; MACHRUN going "
                 "down is not modelled here\n",
                 halts);
    ++thin;
  }
  if (stat_counts) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles carry IR<46>; the statistics counter "
                 "is claimed unexercised\n",
                 stat_counts);
    ++thin;
  }
  if (lc_moved) {
    std::fprintf(stderr,
                 "FAIL: LC is nonzero on %ld microcycles; it is claimed "
                 "constant zero, which is what makes its check vacuous\n",
                 lc_moved);
    ++thin;
  }
  if (other_speed) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles run at other than extra slow; ILONG is "
                 "claimed to change nothing here\n",
                 other_speed);
    ++thin;
  }
  if (ram_executes) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles run microcode out of the control "
                 "store; PROMDISABLE is claimed never set\n",
                 ram_executes);
    ++thin;
  }
  struct {
    const char *what;
    long n;
  } reached[] = {
      {"POPJ off the stack", popjs},   {"jumps to IR<25:12>", jumps},
      {"WRITE-I-MEMs", iwrites},       {"fetches out of the boot PROM", prom_fetches},
      {"fetches out of the control store", ram_fetches},
      {"microcycles the bus held off", stalls},
  };
  for (const auto &e : reached) {
    if (e.n == 0) {
      std::fprintf(stderr, "FAIL: the run reached no %s\n", e.what);
      ++thin;
    }
  }
  if (thin) return 1;

  std::printf(
      "ok: %zu microcycles agree with muir's rtl engine on MIT's boot PROM\n"
      "    PC, IR, LPC, OPC, ST, the A bus, LC and NOP/PCS1/PCS0/IWRITED\n"
      "    every microcycle;\n"
      "    %ld microcycle lengths in 200 MHz ticks\n"
      "    reached: %ld POPJs, %ld jumps, %ld WRITE-I-MEMs, %ld dispatches\n"
      "             (all DISPWR), %ld PROM fetches, %ld control store fetches,\n"
      "             %ld microcycles the bus held off\n"
      "    driven from the trace, and going with their own slice: JCOND, OB,\n"
      "             M for IWR, the console registers\n"
      "    the A bus took %zu distinct values; LC took one, zero\n"
      "    not reached by this program, and so not checked: the dispatch\n"
      "             memory's read, MACHRUN down, the statistics counter,\n"
      "             microcode run out of the control store, LC, the stack's\n"
      "             RAM and pointer (every push is popped through SPCWPASS),\n"
      "             the M memory and the PDL (they reach only the M bus),\n"
      "             and -ILONG --- every cycle is extra slow, where both taps\n"
      "             are -TPR160, so FLAG 3E07's -NOPA gate of it is unchecked\n",
      k, lengths_checked, popjs, jumps, iwrites, dispatches, prom_fetches,
      ram_fetches, stalls, a_values.size());
  return 0;
}
