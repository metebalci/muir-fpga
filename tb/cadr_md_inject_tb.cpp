// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE ONE TICK NO TRACE REACHES: `-LOADMD` RISING ON A DESTMDR BOUNDARY.
//
// tb/cadr_md_hold_tb.cpp measures the property over MIT's boot PROM and over a
// System 100 band and prints, every run, that no `-LOADMD` ever rose on the
// tick a DESTMDR wrote MD --- not once in 600,000 microcycles nor in
// 2,200,000.  So the property is in range for everything except the case the
// module's own structure singles out, and a check that never sees its own
// case is what this project keeps finding.  This is the stimulus for it.
//
// WHAT IT DOES.  It runs MIT's boot PROM under the same stimulus as
// tb/cadr_md_hold_tb.cpp, which is muir's trace with this testbench standing in
// for the bus interface, and then drives ONE extra `-LOADMD` strobe, for one
// tick, at an instant the trace does not: the `cpu_edge` at which an
// instruction writes MD.  The memory is modelled outside the design, as
// `ddr_boot` has it, and what it hands back is a poison word --- the
// complement of what MD is about to hold --- so a word that lands where it
// should not is a word nobody can mistake for the right one.  The boot PROM
// past its first bus cycle writes MD almost only with zero, so the poison is
// almost always all ones: the two are as far apart as thirty-two bits get,
// and which of them MD holds is not a judgement call.
//
// WHY THAT IS A LEGITIMATE THING TO DRIVE.  `n_loadmd` is an input of
// `cadr_microcycle` and the module has to be right for what its port can be
// told.  It is also not a fantasy on the far side: `cadr_busint_xbus.sv`
// drives `n_loadmd` as `!(acked || (state == UB && ub_loadmd))` and `n_memack`
// as `!acked`, so the two are separate terms and a Unibus cycle asserts
// -LOADMD off a signal -MEMACK does not carry.  Whether the composed memory
// path can place that edge on a boundary is a question about the memory path
// and is measured there, not here.
//
// WHAT MUST HAPPEN, AND IT IS MUIR'S RULE AND NOT THIS TESTBENCH'S.  A
// boundary carrying both is not a special case in `Rtl`: the bus word is
// applied where the engine looks and DESTMDR is applied at the edge, so the
// instruction's word is what stands and the bus word is CONSUMED.
// tb/cadr_microcycle_tb.cpp says the same in its own words --- "a row that
// both reads MD and writes it needs no special case: DESTMDR lands at the
// edge and overwrites whatever the bus put there, in the fabric as in
// `Rtl::clock_edge`".  So after the injected strobe, MD holds OB and nothing
// is left queued behind it.
//
// TWO CONFIGURATIONS, AND THE FIRST IS THE CONTROL.
//
//   A  the same run with no strobe injected.  MD must stand from the DESTMDR
//      edge through the microcycles that follow.  Without this, a machine
//      that was going to move MD anyway would make B's result meaningless.
//   B  the strobe, one tick, on the DESTMDR boundary itself.  MD must still
//      hold OB afterwards.
//
// THIS TARGET IS NOT IN `make check`, AND THAT IS DELIBERATE.  It is the
// check for a defect that has not been fixed: `cadr_microcycle.sv` takes the
// first branch of the MD register when `loadmd_edge` is up, so the `else if`
// that clears `md_pending` never runs, the flag survives the DESTMDR write,
// and the held word commits at the next master clock edge --- or at the very
// next tick if `-HANG` is up, a hang not being a boundary --- over the word
// the instruction put there.  The test is written first and left red; it
// joins `check` in the commit that makes it pass.

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "Vcadr_microcycle.h"
#include "Vcadr_microcycle___024root.h"
#include "verilated.h"

namespace {

constexpr int kTickNs = 5;

// Not before this microcycle.  `loadmd_edge` is gated by RDCYC and RDCYC is
// a flip flop loaded by a memory operation, so it is zero until the boot
// PROM's first bus cycle at 536,303 and no strobe of any kind can be placed
// before then.  The search below requires RDCYC anyway and says so if it
// finds nothing, so this is where to look rather than a claim of its own.
constexpr size_t kNotBefore = 536400;

// How many microcycles to watch MD for after the edge.  The boot PROM's own
// windows run two to five microcycles from a DESTMDR to the map write that
// reads MD as its index, so this covers them with room over.
constexpr int kWatchCycles = 8;

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

// What one configuration found.
struct Result {
  bool reached = false;      // a DESTMDR boundary was found to act on
  bool injected = false;     // and the strobe landed on that very tick
  size_t cycle = 0;          // the microcycle it happened on
  uint32_t ob = 0;           // what the instruction wrote
  uint32_t poison = 0;       // what the strobe offered
  bool pending_after = false;// md_pending right after the edge
  uint32_t md_after = 0;     // MD right after the edge
  uint32_t md_end = 0;       // MD kWatchCycles boundaries later
  bool md_moved = false;     // and whether it moved in between
  uint32_t moved_to = 0;     // to what, the first time
  size_t moved_at = 0;       // on which microcycle
  long moved_tick = 0;
};

}  // namespace

// One configuration.  `inject` is false for the control.
static int RunOne(const char *path, bool inject, Result &res) {
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  bool pack_trace = false;
  std::vector<uint64_t> ack_for, rdata_for;
  size_t total_rows = 0;
  {
    char line[512];
    std::vector<uint64_t> bus_at, acks, mds;
    std::vector<char> stalled;
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
        std::fclose(f);
        return 2;
      }
      acks.push_back(r.v[kAck]);
      mds.push_back(r.v[kMd]);
      stalled.push_back(r.v[kStall] != 0);
      if (r.v[kBus]) bus_at.push_back(total_rows);
      ++total_rows;
    }
    rdata_for.assign(total_rows, 0);
    for (size_t i = 0; i < total_rows; ++i)
      rdata_for[i] =
          stalled[i] ? mds[i] : (i + 1 < total_rows ? mds[i + 1] : mds[i]);
    ack_for.assign(total_rows, 0);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
    }
  }
  if (total_rows < 2 || pack_trace) {
    std::fprintf(stderr,
                 "FAIL: %s is not MIT's boot PROM, or carries no microcycles\n",
                 path);
    std::fclose(f);
    return 2;
  }
  std::rewind(f);

  auto *dut = new Vcadr_microcycle;
  auto *root = dut->rootp;
  dut->clk = 0;
  dut->rst = 1;
  dut->n_memack = 1;
  dut->n_memgrant = 1;
  dut->n_loadmd = 1;
  dut->rdata = 0;
  dut->spy_eadr = 0;
  dut->eval();

  auto read_next = [&](Row &r) {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      return ParseRow(line, r);
    }
    return false;
  };
  auto drive = [&](const Row &r, size_t row) {
    dut->sintr = static_cast<uint8_t>(r.v[kSintr]);
    dut->rdata = static_cast<uint32_t>(rdata_for[row]);
    dut->run = static_cast<uint8_t>(r.v[kSrun]);
    dut->promdisable = static_cast<uint8_t>(r.v[kPromdis]);
    dut->errstop = static_cast<uint8_t>(r.v[kErrstop]);
    dut->stathenb = static_cast<uint8_t>(r.v[kStathenb]);
    dut->mode_speed =
        static_cast<uint8_t>((r.v[kSpeed1] << 1) | (r.v[kSpeed0] & 1));
  };

  Row cur;
  if (!read_next(cur)) {
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n", path);
    std::fclose(f);
    return 2;
  }
  drive(cur, 0);

  size_t k = 0;
  bool bus_outstanding = false;
  long ack_at_tick = 0;

  // THE EDGE IS PREDICTED A TICK AHEAD, because the strobe has to be driven
  // before the tick is evaluated and what makes the tick interesting is only
  // readable after it.  At the end of every tick the combinational control
  // signals already stand at what the NEXT edge will act on, so the tick
  // after this one is knowable here.  The prediction is confirmed after the
  // settle eval and abandoned if it was wrong, so nothing is claimed on it.
  bool arm = false;
  bool done = false;          // the edge has been acted on
  int watching = -1;          // boundaries left to watch, -1 until armed
  long acted_tick = 0;

  const long kMaxTicks = static_cast<long>(total_rows) * 96 + 1024;

  for (long t = 0; t < kMaxTicks && k < total_rows; ++t) {
    if (t == 4) dut->rst = 0;

    dut->n_memgrant = bus_outstanding ? 0 : 1;
    const bool acking = bus_outstanding && t >= ack_at_tick;
    dut->n_memack = acking ? 0 : 1;
    dut->n_loadmd = acking ? 0 : 1;
    if (dut->wrcyc)
      dut->rdata = ~static_cast<uint32_t>(rdata_for[k < total_rows ? k : 0]);

    // The one strobe.  -LOADMD was high the tick before --- nothing else is
    // acknowledging, which is part of what `arm` required --- so this is a
    // rising edge, and the word offered is the complement of what MD is
    // about to hold.
    const bool strobe_now = arm && inject && !acking;
    if (strobe_now) {
      dut->n_loadmd = 0;
      dut->rdata = ~dut->ob;
    }

    dut->eval();

    const bool pre_cpu_edge = root->cadr_microcycle__DOT__cpu_edge != 0;
    const bool pre_destmdr = root->cadr_microcycle__DOT__destmdr != 0;
    const bool pre_loadmd_edge = root->cadr_microcycle__DOT__loadmd_edge != 0;
    const uint32_t pre_ob = dut->ob;

    const bool acting = arm && pre_cpu_edge && pre_destmdr &&
                        (!inject || pre_loadmd_edge);
    arm = false;

    dut->clk = 1;
    dut->eval();

    if (acting && !done) {
      done = true;
      res.reached = true;
      res.injected = inject && pre_loadmd_edge;
      res.cycle = k;
      res.ob = pre_ob;
      res.poison = ~pre_ob;
      res.md_after = dut->md;
      res.pending_after = root->cadr_microcycle__DOT__md_pending != 0;
      res.md_end = dut->md;
      acted_tick = t;
      watching = kWatchCycles;
    } else if (watching > 0) {
      if (dut->md != res.md_end) {
        if (!res.md_moved) {
          res.md_moved = true;
          res.moved_at = k;
          res.moved_to = dut->md;
          res.moved_tick = t - acted_tick;
        }
        res.md_end = dut->md;
      }
    }

    if (bus_outstanding && dut->n_memack == 0 && dut->n_memrq) {
      bus_outstanding = false;
      dut->n_memack = 1;
      dut->n_memgrant = 1;
    }

    if (dut->clock_edge) {
      if (cur.v[kBus]) {
        bus_outstanding = true;
        ack_at_tick = t + static_cast<long>((ack_for[k] - cur.v[kNs] +
                                             kTickNs - 1) / kTickNs);
      }
      ++k;
      if (watching > 0 && --watching == 0) break;
      if (k < total_rows) {
        if (!read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu\n", path, k);
          std::fclose(f);
          return 2;
        }
        drive(cur, k);
      }
    }

    dut->clk = 0;
    dut->eval();

    // A candidate for the next tick: a DESTMDR boundary, with RDCYC up so a
    // strobe can be placed at all, and no cycle of the program's own in
    // flight to confuse it with.
    if (!done && k >= kNotBefore && dut->rdcyc && !bus_outstanding &&
        root->cadr_microcycle__DOT__cpu_edge &&
        root->cadr_microcycle__DOT__destmdr)
      arm = true;
  }

  dut->final();
  delete dut;
  std::fclose(f);
  return 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";

  Result control, injected;
  int rc = RunOne(path, false, control);
  if (rc) return rc;
  rc = RunOne(path, true, injected);
  if (rc) return rc;

  int bad = 0;
  std::printf("the one tick no trace reaches, on MIT's boot PROM:\n");

  // A: THE CONTROL.  MD has to stand of its own accord, or B says nothing.
  if (!control.reached) {
    std::fprintf(stderr,
                 "FAIL: configuration A found no DESTMDR boundary with RDCYC "
                 "up and nothing in flight after microcycle %zu\n",
                 kNotBefore);
    ++bad;
  } else {
    std::printf(
        "    A  control: microcycle %zu writes MD %08x and no strobe is\n"
        "       placed; %d boundaries later MD is %08x\n",
        control.cycle, control.ob, kWatchCycles, control.md_end);
    if (control.pending_after) {
      std::fprintf(stderr,
                   "FAIL: configuration A left md_pending set with no strobe "
                   "anywhere near it\n");
      ++bad;
    }
    if (control.md_moved) {
      std::fprintf(stderr,
                   "FAIL: configuration A saw MD move to %08x on its own at "
                   "microcycle %zu, %ld ticks after the edge; the control has "
                   "to hold or B measures the program and not the strobe\n",
                   control.moved_to, control.moved_at, control.moved_tick);
      ++bad;
    }
  }

  // B: THE CASE.
  if (!injected.reached || !injected.injected) {
    std::fprintf(stderr,
                 "FAIL: configuration B never placed -LOADMD on a DESTMDR "
                 "boundary; the stimulus did not reach its own case\n");
    ++bad;
  } else {
    std::printf(
        "    B  strobed: microcycle %zu writes MD %08x while -LOADMD rises on\n"
        "       that very tick offering %08x; md_pending is %s after the\n"
        "       edge, and %d boundaries later MD is %08x\n",
        injected.cycle, injected.ob, injected.poison,
        injected.pending_after ? "STILL SET" : "clear", kWatchCycles,
        injected.md_end);
    if (injected.cycle != control.cycle) {
      std::fprintf(stderr,
                   "FAIL: the two configurations acted on different "
                   "microcycles, %zu and %zu\n",
                   control.cycle, injected.cycle);
      ++bad;
    }
    if (injected.md_after != injected.ob) {
      std::fprintf(stderr,
                   "FAIL: the instruction's own write did not land: MD is %08x "
                   "where OB was %08x\n",
                   injected.md_after, injected.ob);
      ++bad;
    }
    // MUIR'S RULE.  The bus word is applied where the engine looks and
    // DESTMDR is applied at the edge, so the word is consumed and the
    // instruction's is what stands.
    if (injected.pending_after) {
      std::fprintf(stderr,
                   "FAIL: md_pending is still set after the edge.  The strobe "
                   "and the instruction's write fell on one tick, so the "
                   "first branch of the MD register was taken and the `else "
                   "if` that clears the flag never ran.  The held word %08x "
                   "commits at the next master clock edge --- or at the very "
                   "next tick if -HANG is up --- over the %08x the "
                   "instruction put there.\n",
                   injected.poison, injected.ob);
      ++bad;
    }
    if (injected.md_moved) {
      std::fprintf(stderr,
                   "FAIL: MD moved to %08x at microcycle %zu, %ld ticks after "
                   "the edge.  The map is indexed by MD<23:8> whenever "
                   "MEMSTART is down, so a VMA-WRITE-MAP between here and the "
                   "next DESTMDR writes entry %04x and not %04x.\n",
                   injected.moved_to, injected.moved_at, injected.moved_tick,
                   (injected.moved_to >> 8) & 0xffff,
                   (injected.ob >> 8) & 0xffff);
      ++bad;
    }
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d of the two configurations' claims\n", bad);
    return 1;
  }
  std::printf(
      "    ok: a -LOADMD on a DESTMDR boundary is consumed by that edge and\n"
      "        the instruction's word stands, as Rtl::clock_edge has it\n");
  return 0;
}
