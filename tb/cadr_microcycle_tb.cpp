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
// WHAT IS STIMULUS.  There is no map yet, so what comes out of the trace
// rather than out of the DUT is `md` and `vma`, `vmaok` off the map's
// permission bits, `sintr` from the cables, the word a SRCMAP puts on MF, the
// dispatch memory's word, and the console's registers.  The bus interface is
// here too, as its far end: this testbench answers -MEMRQ with -MEMGRANT and
// -MEMACK at the instants muir's own interface answered them.
// `rtl/cadr_busint_xbus.sv` is the real thing and has a check of its own.  Every one leaves with
// a later slice.  They are counted and printed, so what this check is still
// being told rather than checking is on its own output.
//
// `mf_map` is the one that is frankly circular: a SRCMAP is reached **once**
// in 600,000 microcycles and its word is taken from the trace's own M column,
// so on that single row M checks nothing.  One row is not a check of a map
// under any amount of cleverness, and the map is a later slice; the count is
// printed so the circularity is visible rather than buried.
//
// WHAT IS CHECKED.  PC, IR, LPC, OPC, ST, the A and M buses, the ALU, R, OB,
// Q, DC, LC, JCOND, and the four sequencing flags NOP, PCS1, PCS0 and
// IWRITED --- plus the length of every microcycle in 200 MHz ticks.  PC goes
// through the fabric's own stack on a POPJ.
//
// **The stall is no longer subtracted.**  VCTL1 decides -WAIT and -HANG for
// itself now, so the whole interval between one microcycle boundary and the
// next is the fabric's own answer: 6,912 waits and 11,404 hangs over the run,
// 2,198,700 ns of held clock, and every one of them has to land where muir
// lands it.  That is the strongest single column in this check.
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
//   - OB's two shift selects are never taken: `OSEL` is only ever 0 (MO) or
//     1 (ALU), so `ALU >> 1` and `ALU << 1` with Q<31> shifted in are built
//     and unexercised.  Replacing `ALU >> 1` with `ALU` survives.
//   - Q is loaded five times and **never shifted**: `QS<1:0>` is 0 on 599,995
//     microcycles and 3 on the other five, so the 74S194s' shift paths and
//     every multiply and divide step with them are unexercised.
//   - AEQM widened from the low 32 slices to all 33 survives, so the
//     open-collector chain's width is not pinned down here either.
//   - Jump condition 5, `PAGE.FAULT OR INTERRUPT`, is never selected, and
//     condition 2 is selected once.
//   - Two of -WAIT's three terms never fire.  `USE.MD AND MBUSY AND
//     -MEMGRANT` --- MIT's "do not hang when this line is high", the gate
//     that keeps a hang from being taken before the grant --- is zero over
//     the run, and so is `LCINC AND NEEDFETCH AND MBUSY.SYNC`.  Dropping
//     either survives.  The first term carries the whole stall path here.
//   - **RDCYC and WRCYC being taken from the wrong instruction survives**,
//     and `src/rtl.rs` says in advance that it would: "taking it from the
//     instruction standing one microcycle later is the trap: that instruction
//     is the page-fault check MIT puts after every store, so MEMWR reads
//     false and every write cycle is performed as a read.  Nothing catches it
//     early --- the only thing the boot PROM writes before the disk is page
//     0, which it fills with the zeros already there."  Measured here from
//     the other side, and it holds.
//
// Against that, the ALU array is genuinely exercised: 21 of its 32
// function-and-mode combinations are reached, the sign-extending ninth slice
// is caught if removed (JCOND goes wrong at microcycle 5,202), the rotate is
// caught if reversed, the mask is caught if its two ends are swapped or if
// MSKL loses IR<9:5>, and swapping one entry of either half of the 74S181
// function table is caught within a few thousand microcycles.
//
// The stall path itself is caught where it is exercised: dropping -WAIT's
// first term, letting -HANG be taken before -WAIT, or clearing MBUSY one tick
// late are each caught at the boot PROM's first stalled microcycle.
//
// And the one-state-early trap on page DSPCTL is caught: the 25S07s take
// IR<41:32> of the DISPATCH *itself*, the word standing before the edge, and
// reading the newly loaded IR there instead is caught at microcycle 525,527.
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
  kLpc, kMd, kVma, kPromdis, kErrstop, kStathenb, kSpeed1, kSpeed0,
  kStall, kHalted, kBus, kAck, kGnt, kSintr, kNs,
  kColumns
};

struct Row {
  uint64_t v[kColumns];
};

// One row of hexadecimal columns. Returns false if the count is wrong.
bool ParseRow(const char *line, Row &r) {
  const char *p = line;
  for (int i = 0; i < kColumns; ++i) {
    char *end = nullptr;
    r.v[i] = std::strtoull(p, &end, 16);
    if (end == p) return false;
    p = end;
  }
  return true;
}

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

  // THE TRACE IS STREAMED, NOT HELD.  The pack trace is 2.2 million
  // microcycles and 297 MB; holding it as parsed rows is 686 MB of a machine
  // three sessions are building on.  So it is read twice instead: once for
  // the acknowledgement times, which are the only thing needing to be known
  // before their row, and once to drive the DUT.
  bool pack_trace = false;
  std::vector<uint64_t> ack_for;
  std::vector<bool> arbitrated;
  long unibus_cycles = 0;
  size_t total_rows = 0;
  {
    char line[512];
    std::vector<uint64_t> bus_at;   // row indices that start a bus cycle
    std::vector<uint64_t> acks;     // and every row's ack column
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#') {
        if (std::strstr(line, "rtl_sys.rs")) pack_trace = true;
        continue;
      }
      if (line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "%s: row %zu has the wrong column count\n", path,
                     total_rows);
        return 2;
      }
      acks.push_back(r.v[kAck]);
      if (r.v[kBus]) bus_at.push_back(total_rows);
      ++total_rows;
    }
    // For each microcycle that starts a bus cycle, when -MEMACK is due. The
    // interface usually knows at the boundary; a cycle that has to arbitrate
    // for the Unibus first is granted, acknowledged and finished inside a
    // later microcycle's stall, so its answer appears on a later row.
    ack_for.assign(total_rows, 0);
    arbitrated.assign(total_rows, false);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
      // A cycle whose answer is not known at the boundary it started on had
      // to arbitrate for the Unibus first. THE FABRIC'S BUS INTERFACE HAS NO
      // UNIBUS PATH --- `cadr_busint_xbus.sv` is the Xbus half --- so neither
      // this testbench's model of it nor the processor behind it can place
      // that grant, and the microcycles the arbitration stalls are exempt
      // from the length check. They are counted, and the count is held down,
      // so this cannot quietly become the rule.
      if (j != i) {
        ++unibus_cycles;
        for (size_t x = i; x <= j && x < total_rows; ++x) arbitrated[x] = true;
      }
    }
  }

  // A trace the Makefile could not make says so in one comment line and
  // carries no microcycles. That is not a failure: the System release is
  // fetched material and a checkout without it still runs every check that
  // matters.
  if (total_rows == 0) {
    std::printf("skipped: %s carries no microcycles\n", path);
    std::fclose(f);
    return 0;
  }
  if (total_rows < 2) {
    std::fprintf(stderr, "FAIL: %s carries %zu microcycles\n", path,
                 total_rows);
    return 1;
  }
  std::rewind(f);

  auto *dut = new Vcadr_microcycle;
  dut->clk = 0;
  dut->rst = 1;
  dut->n_memack = 1;
  dut->n_memgrant = 1;
  // Verilator records the previous value of a clock at eval time, so the
  // first eval has to happen with clk low or the first posedge is not one.
  dut->eval();

  // Reads the next data row, skipping comments. False at end of file.
  auto read_next = [&](Row &r) {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      return ParseRow(line, r);
    }
    return false;
  };

  // Present a row's stimulus: what the memory path would be driving over that
  // microcycle, and what the console would be holding.
  auto drive = [&](const Row &r) {
    dut->md = static_cast<uint32_t>(r.v[kMd]);
    dut->sintr = static_cast<uint8_t>(r.v[kSintr]);
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
    uint64_t pc, ir, lpc, opc, st, a, m, alu, r, ob, q, dc, lc, vma, vmaok,
        jcond, nop, pcs1, pcs0, iwrited;
  };
  auto take = [&]() {
    return Sample{dut->pc,  dut->ir,    dut->lpc, dut->opc,   dut->st,
                  dut->a,   dut->m,     dut->alu, dut->r,     dut->ob,
                  dut->q,   dut->dc,    dut->lc,  dut->vma,   dut->vmaok,
                  dut->jcond, dut->nop, dut->pcs1, dut->pcs0, dut->iwrited};
  };

  Row cur;
  if (!read_next(cur)) {
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n", path);
    return 1;
  }
  uint64_t prev_ns = 0;
  drive(cur);
  Sample prev = take();

  size_t k = 0;          // the microcycle now running
  long last_edge = -1;   // -1 until the first, whose length has no start
  int bad = 0;

  // Coverage, and the assertions that say what this program leaves untouched.
  long lengths_checked = 0, dispatches = 0, disp_reads = 0, halts = 0;
  long iwrites = 0, popjs = 0, jumps = 0, prom_fetches = 0, ram_fetches = 0;
  long stat_counts = 0, stalls = 0, ram_executes = 0, other_speed = 0;
  long lc_moved = 0, map_sources = 0, cycles_run = 0;
  long q_shifts = 0, ilongs = 0, promdis_rows = 0;
  long sub_tick = 0, worst_slip = 0, best_slip = 0, arb_skipped = 0;
  bool any_slip = false;
  bool bus_outstanding = false;
  long ack_at_tick = 0;
  std::set<uint64_t> a_values, m_values, ob_values;

  // Long enough for every microcycle plus the reset and a margin: the
  // longest cycle the generator makes is 44 ticks at extra slow.
  const long kMaxTicks = static_cast<long>(total_rows) * 96 + 1024;

  for (long t = 0; t < kMaxTicks && k < total_rows; ++t) {
    if (t == 4) dut->rst = 0;

    // The bus interface, as far as VCTL1 can see it: -MEMGRANT low while a
    // cycle is outstanding, -MEMACK low from the interface's answer until the
    // processor lifts -MEMRQ, which is what drops it. cadr_busint_xbus.sv is
    // the real thing and has its own check; this is its far end.
    dut->n_memgrant = bus_outstanding ? 0 : 1;
    dut->n_memack = (bus_outstanding && t >= ack_at_tick) ? 0 : 1;

    dut->clk = 1;
    dut->eval();

    // "MEMRQ drops when MEMACK rises, which causes MEMACK to drop."
    if (bus_outstanding && dut->n_memack == 0 && dut->n_memrq) {
      bus_outstanding = false;
      dut->n_memack = 1;
      dut->n_memgrant = 1;
    }

    if (dut->clock_edge) {
      const Row &r = cur;

      if (prev.pc != r.v[kPc]) bad += Fail(r, "PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) bad += Fail(r, "IR", prev.ir, r.v[kIr]);
      if (prev.lpc != r.v[kLpc]) bad += Fail(r, "LPC", prev.lpc, r.v[kLpc]);
      if (prev.opc != r.v[kOpc]) bad += Fail(r, "OPC", prev.opc, r.v[kOpc]);
      if (prev.st != r.v[kSt]) bad += Fail(r, "ST", prev.st, r.v[kSt]);
      if (prev.a != r.v[kA]) bad += Fail(r, "the A bus", prev.a, r.v[kA]);
      if (prev.lc != r.v[kLc]) bad += Fail(r, "LC", prev.lc, r.v[kLc]);
      if (prev.m != r.v[kM]) bad += Fail(r, "the M bus", prev.m, r.v[kM]);
      if (prev.alu != r.v[kAlu]) bad += Fail(r, "the ALU", prev.alu, r.v[kAlu]);
      if (prev.r != r.v[kR]) bad += Fail(r, "R", prev.r, r.v[kR]);
      if (prev.ob != r.v[kOb]) bad += Fail(r, "OB", prev.ob, r.v[kOb]);
      if (prev.q != r.v[kQ]) bad += Fail(r, "Q", prev.q, r.v[kQ]);
      if (prev.dc != r.v[kDc]) bad += Fail(r, "DC", prev.dc, r.v[kDc]);
      if (prev.jcond != r.v[kJcond])
        bad += Fail(r, "JCOND", prev.jcond, r.v[kJcond]);
      if (prev.vma != r.v[kVma]) bad += Fail(r, "VMA", prev.vma, r.v[kVma]);
      // The net is -VMAOK, `NAND(-PFR, -PFW)` at VCTL1 1D17: *low* when the
      // access is permitted, the opposite of the logical VMAOK the jump
      // conditions and MEMRQ take.
      if (prev.vmaok == r.v[kNVmaok])
        bad += Fail(r, "-VMAOK", !prev.vmaok, r.v[kNVmaok]);
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
        const uint64_t before = prev_ns;
        // The stall is no longer subtracted: VCTL1 decides it now, so the
        // whole interval between boundaries is the fabric's own answer.
        const uint64_t want = r.v[kNs] - before;
        const uint64_t got = static_cast<uint64_t>(t - last_edge) * kTickNs;
        if (got != want) {
          const long slip = static_cast<long>(got) - static_cast<long>(want);
          if (arbitrated[k]) {
            ++arb_skipped;
          } else if (r.v[kStall] && slip > -kTickNs && slip < kTickNs) {
            ++sub_tick;
            if (!any_slip || slip > worst_slip) worst_slip = slip;
            if (!any_slip || slip < best_slip) best_slip = slip;
            any_slip = true;
          } else {
            bad += Fail(r, "the microcycle in ns", got, want);
          }
        }
        ++lengths_checked;
      }
      if (r.v[kStall]) ++stalls;
      // The bus cycle this edge started, and when the interface will answer.
      if (r.v[kBus]) {
        bus_outstanding = true;
        // Rounded *up*: a memory board answers on its own refresh clock, so
        // muir's acknowledgement is not on the five-nanosecond grid, and the
        // fabric can only see it at a tick at or after it. Truncating instead
        // ends a wait one 220 ns cycle early wherever the acknowledgement
        // falls within a tick of a master clock edge.
        ack_at_tick =
            t + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
        ++cycles_run;
      }
      if (r.v[kLc]) ++lc_moved;
      if (r.v[kPromdis]) ++promdis_rows;
      a_values.insert(r.v[kA]);
      m_values.insert(r.v[kM]);
      ob_values.insert(r.v[kOb]);
      // SRCMAP is group B source 1, and its word is handed to the DUT.
      if (r.v[kNop] == 0 && ((r.v[kIr] >> 31) & 1) && ((r.v[kIr] >> 29) & 1) &&
          (((r.v[kIr] >> 26) & 7) == 1))
        ++map_sources;
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
        // QS<1:0> of 1 or 2 is a shift; 3 is the load, which the boot PROM
        // does five times and nothing else.
        if (cls == 0) {
          const uint64_t qs = r.v[kIr] & 3;
          if (qs == 1 || qs == 2) ++q_shifts;
        }
        if ((r.v[kIr] >> 45) & 1) ++ilongs;
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
      prev_ns = r.v[kNs];
      ++k;
      if (k < total_rows) {
        if (!read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu of %zu\n",
                       path, k, total_rows);
          return 1;
        }
        drive(cur);
      }

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
  if (k != total_rows) {
    std::fprintf(stderr,
                 "FAIL: the run stopped after %zu of %zu microcycles --- the "
                 "generator is not making a boundary\n",
                 k, total_rows);
    return 1;
  }

  // A run that agreed everywhere while reaching nothing would pass and mean
  // nothing.  These are what it has to have reached, and what it has to have
  // left alone for the holes above to be the size they are claimed to be.
  int thin = 0;
  if (disp_reads && !pack_trace) {
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
  if (lc_moved && !pack_trace) {
    std::fprintf(stderr,
                 "FAIL: LC is nonzero on %ld microcycles; it is claimed "
                 "constant zero, which is what makes its check vacuous\n",
                 lc_moved);
    ++thin;
  }
  // A fraction of a percent is the Unibus showing through --- the pack trace
  // talks to the disk, and 347 of its 141,849 bus cycles arbitrate. A tenth
  // of them would mean the exemption had become the rule and was covering
  // something other than the missing Unibus path.
  if (unibus_cycles * 100 > cycles_run) {
    std::fprintf(stderr,
                 "FAIL: %ld of %ld bus cycles arbitrated for the Unibus; the "
                 "length check exempts those and cannot exempt that share\n",
                 unibus_cycles, cycles_run);
    ++thin;
  }
  if (other_speed && !pack_trace) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles run at other than extra slow; ILONG is "
                 "claimed to change nothing here\n",
                 other_speed);
    ++thin;
  }
  if (ram_executes && !pack_trace) {
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
  // What the pack trace exists for. The boot PROM reaches none of these, and
  // if this one stops reaching them it has stopped earning its 297 MB.
  if (pack_trace) {
    struct {
      const char *what;
      long n;
    } wanted[] = {
        {"reads of the map", map_sources},   {"reads of the dispatch memory", disp_reads},
        {"shifts of Q", q_shifts},           {"microcycles with PROMDISABLE set", promdis_rows},
        {"instructions with ILONG", ilongs}, {"microcycles run out of the control store", ram_executes},
    };
    for (const auto &e : wanted) {
      if (e.n == 0) {
        std::fprintf(stderr,
                     "FAIL: the pack trace reached no %s, which is what it is "
                     "for\n",
                     e.what);
        ++thin;
      }
    }
  }
  if (thin) return 1;

  std::printf(
      "ok: %zu microcycles agree with muir's rtl engine %s\n"
      "    PC, IR, LPC, OPC, ST, LC, the A and M buses, the ALU, R, OB, Q,\n"
      "    DC, VMA, -VMAOK, JCOND and NOP/PCS1/PCS0/IWRITED every microcycle;\n"
      "    %ld microcycle lengths in 200 MHz ticks, %ld of them within a tick\n"
      "    rather than exact (slip %+ld to %+ld ns), %ld exempt for the Unibus\n"
      "    arbitration of %ld of %ld bus cycles\n"
      "    reached: %ld POPJs, %ld jumps, %ld WRITE-I-MEMs, %ld dispatches of\n"
      "             which %ld read the memory, %ld PROM fetches, %ld control\n"
      "             store fetches, %ld microcycles the bus held off, %ld map\n"
      "             reads, %ld Q shifts, %ld ILONG instructions\n"
      "    the A bus took %zu distinct values, the M bus %zu, OB %zu\n"
      "    driven from the trace, and going with the memory path: MD, the\n"
      "             word -LOADMD strobes into it; SINTR off the cables; the\n"
      "             console's registers\n",
      k, pack_trace ? "on a System 100 band" : "on MIT's boot PROM",
      lengths_checked, sub_tick, best_slip, worst_slip, arb_skipped,
      unibus_cycles, cycles_run, popjs, jumps, iwrites, dispatches, disp_reads,
      prom_fetches, ram_fetches, stalls, map_sources, q_shifts, ilongs,
      a_values.size(), m_values.size(), ob_values.size());

  // What this program did not reach, printed from the counts rather than
  // asserted from memory, so the list cannot outlive its reasons.
  struct {
    const char *what;
    long n;
  } unreached[] = {
      {"the dispatch memory's read", disp_reads},
      {"MACHRUN down", halts},
      {"the statistics counter", stat_counts},
      {"microcode run out of the control store", ram_executes},
      {"the location counter (LC is zero throughout)", lc_moved},
      {"a speed other than extra slow", other_speed},
      {"the map's read", map_sources},
      {"a shift of Q", q_shifts},
      {"an ILONG instruction", ilongs},
  };
  bool said = false;
  for (const auto &e : unreached) {
    if (e.n) continue;
    if (!said) {
      std::printf("    not reached by this program, and so not checked:\n");
      said = true;
    }
    std::printf("             %s\n", e.what);
  }
  return 0;
}
