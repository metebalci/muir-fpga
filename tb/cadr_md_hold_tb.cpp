// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MD MUST STILL HOLD WHAT ITS OWN INSTRUCTION PUT THERE WHEN THE MAP IS
// WRITTEN.  A property check on rtl/machine/cadr_microcycle.sv, measured every
// 200 MHz tick, with no new reference: what it asserts is a rule about the
// module and not an agreement with muir.
//
// WHY.  `mapi` is `memstart ? vma[23:8] : md[23:8]`, so outside a memory
// cycle the map is indexed by MD --- and the map write happens at the write
// pulse of the microcycle AFTER the one carrying `VMA-WRITE-MAP`, because
// `wmapd` is registered at the boundary while "address and data are the live
// ones: nothing latches them".  So an instruction that puts a virtual address
// in MD and then writes the map through it needs MD to stand from its own
// boundary until that pulse, several microcycles later.  Anything that moves
// MD inside that span writes the map at the wrong entry, silently, and the
// machine reads through a translation nobody asked for.
//
// MD has exactly two writers, both in one `always_ff`: the held word from
// `-LOADMD`, committed at a master clock edge or at once under `-HANG`, and
// `DESTMDR` at `cpu_edge`.  So a change of MD inside the window is a held
// word committing, and there is nothing else it can be.  That is what makes
// this property sharp rather than a smoke test.
//
// THE THREE THINGS IT SAYS, in the order they bite:
//
//   1. At the `cpu_edge` where `DESTMDR` is up, MD takes OB.  Free, and it is
//      what makes the rest mean anything: a window whose opening value were
//      wrong would compare a wrong word against itself for ever after.
//   2. At that same edge `md_pending` must be CLEAR.  A word still pending
//      after the instruction has written MD commits later and overwrites it
//      --- at the next boundary, or at the very next tick if `-HANG` is up,
//      a hang not being a boundary.  This is the invariant, and it is the
//      one that fails at the instant the damage is done rather than
//      wherever the wrong map entry is eventually read.
//   3. From that edge until the write pulse with `WMAPD` up, MD does not
//      change unless `-LOADMD` has strobed since --- a word the microcode
//      asked for after the write may land, and one strobed before it was
//      consumed at that edge and may not.  This is the property the module's
//      users depend on, stated on the observable.
//
// WHAT IT IS DRIVEN BY.  The same stimulus as tb/cadr_microcycle_tb.cpp: muir's
// own trace, one row a microcycle, with this testbench standing in for the
// bus interface at the instants muir's own interface answered.  Nothing is
// compared against the trace here --- cadr_microcycle_tb.cpp does that, column
// by column --- and the trace is used only to keep a real program running
// under the property.  A write cycle is handed the complement of the word MD
// should hold, for the reason that testbench gives: a stimulus that mirrors
// cannot show a load that should not have happened.
//
// WHAT IT READS OUT OF THE DUT.  `destmdr`, `wmapd`, `wp`, `cpu_edge`,
// `md_pending` and `loadmd_edge` are internal, so the model is verilated
// `--public-flat-rw` and they are read by name.  They are the module's own
// signals and not a second description of them: a testbench that re-decoded
// DESTMDR out of IR would be asserting a property of its own decode.
//
// AND THE COVERAGE IS THE FINDING.  A window is only a check of anything if
// something could have moved MD inside it, so the run counts the windows, how
// long they are, how many carry a `-LOADMD` at all, and how close the nearest
// one ever comes when it does not.  Those numbers are printed whether the run
// passes or fails, because a property that is out of range on every trace it
// is measured over is exactly the thing this project keeps finding, and it
// has to be visible on the check's own output rather than reasoned about.

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

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // Streamed, not held: the band trace is 297 MB and holding it parsed is
  // most of a gigabyte.  Read once for the acknowledgement instants, which
  // are the only thing that has to be known before their row, then again to
  // drive.  tb/cadr_microcycle_tb.cpp says the same and for the same reason.
  bool pack_trace = false;
  std::vector<uint64_t> ack_for;
  std::vector<uint64_t> rdata_for;
  size_t total_rows = 0;
  {
    char line[512];
    std::vector<uint64_t> bus_at;
    std::vector<uint64_t> acks;
    std::vector<uint64_t> mds;
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
        return 2;
      }
      acks.push_back(r.v[kAck]);
      mds.push_back(r.v[kMd]);
      stalled.push_back(r.v[kStall] != 0);
      if (r.v[kBus]) bus_at.push_back(total_rows);
      ++total_rows;
    }
    rdata_for.assign(total_rows, 0);
    for (size_t i = 0; i < total_rows; ++i) {
      rdata_for[i] =
          stalled[i] ? mds[i] : (i + 1 < total_rows ? mds[i + 1] : mds[i]);
    }
    ack_for.assign(total_rows, 0);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
    }
  }

  // A trace the Makefile could not make carries no microcycles, and that is
  // not a failure: the System release is fetched material.
  if (total_rows < 2) {
    std::printf("skipped: %s carries no microcycles\n", path);
    std::fclose(f);
    return 0;
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
    return 1;
  }
  drive(cur, 0);

  size_t k = 0;
  bool bus_outstanding = false;
  long ack_at_tick = 0;
  int bad = 0;

  // WHAT IS OPEN, and it never closes: MD's owner is the last instruction
  // that wrote it, and every map write until the next one is indexed by that
  // word.  A "window" for the lengths below is the span from a DESTMDR to the
  // FIRST map write after it, which is the shape the microcode uses; later
  // pulses under the same MD are counted separately rather than ignored.
  bool have_owner = false;
  uint32_t expect_md = 0;
  long owner_tick = 0;
  size_t owner_cycle = 0;
  bool window_measured = false;
  bool window_had_strobe = false;
  // How many words `-LOADMD` has strobed that MD has not yet taken.  A word
  // strobed AFTER the owning DESTMDR is one the microcode asked for and may
  // land; a word strobed before it was consumed at that edge and may not.
  // That distinction is the whole of the property: the register has two
  // writers, so a change of MD with nothing outstanding is a stale held word
  // committing and can be nothing else.
  int allowed = 0;

  // What the run measured.
  long windows = 0;
  long shortest_ticks = 0, longest_ticks = 0;
  long shortest_cycles = 0, longest_cycles = 0;
  long pulses_from_md = 0, pulses_from_vma = 0;
  long pulses_writing_map = 0, orphan_pulses = 0, later_pulses = 0;
  long windows_with_loadmd = 0, strobes_in_window = 0;
  long destmdr_edges = 0, loadmd_edges = 0;
  long commits_after_strobe = 0, coincidences = 0;
  // THE PRECONDITION OF THE LEAK, counted directly.  A word can only
  // outlive a DESTMDR if one was owed at that edge, so this is the number
  // that says whether the invariant above had anything to hold.
  long pending_at_cpu_edge = 0, pending_at_destmdr = 0;
  // ...and of those, how many were a DESTMEM instruction at all.  DESTMDR
  // is one of the two memory destinations, and `-WAIT`'s first term is
  // `DESTMEM AND MBUSY.SYNC`, so this is what says whether the absence
  // above is that gate or an arithmetic accident.
  long pending_at_destmem = 0;
  long pending_left_set = 0, md_not_ob = 0, stale_commits = 0;
  bool any_gap = false;
  long nearest_gap_ticks = 0;   // a strobe outside a window, to that window
  long last_loadmd_tick = -1;

  const long kMaxTicks = static_cast<long>(total_rows) * 96 + 1024;

  for (long t = 0; t < kMaxTicks && k < total_rows; ++t) {
    if (t == 4) dut->rst = 0;

    dut->n_memgrant = bus_outstanding ? 0 : 1;
    const bool acking = bus_outstanding && t >= ack_at_tick;
    dut->n_memack = acking ? 0 : 1;
    dut->n_loadmd = acking ? 0 : 1;
    // Poison on a write, as tb/cadr_microcycle_tb.cpp does and for its reason:
    // a stimulus that hands back the word MD should hold makes an extra load
    // a no-op, and nothing then shows.
    if (dut->wrcyc)
      dut->rdata = ~static_cast<uint32_t>(rdata_for[k < total_rows ? k : 0]);
    // SETTLE BEFORE SAMPLING.  `loadmd_edge` is combinational off the input
    // driven three lines above, so reading it without an eval reads the
    // previous tick's -LOADMD --- measured, and it reported zero strobes over
    // the whole boot PROM while MD was plainly moving.
    dut->eval();

    // What stands BEFORE the edge, which is what the edge will act on.
    const bool pre_cpu_edge = root->cadr_microcycle__DOT__cpu_edge != 0;
    const bool pre_destmdr = root->cadr_microcycle__DOT__destmdr != 0;
    const bool pre_wp = root->cadr_microcycle__DOT__wp != 0;
    const bool pre_wmapd = root->cadr_microcycle__DOT__wmapd != 0;
    const bool pre_loadmd_edge = root->cadr_microcycle__DOT__loadmd_edge != 0;
    const bool pre_pending = root->cadr_microcycle__DOT__md_pending != 0;
    const bool pre_memstart = dut->memstart != 0;
    const uint32_t pre_ob = dut->ob;
    const uint32_t pre_vma = dut->vma;
    const uint32_t pre_md = dut->md;

    // THE MAP WRITE: the write pulse with WMAPD standing.  `mapi` is MD
    // unless MEMSTART is up, and "address and data are the live ones:
    // nothing latches them", so this is the instant MD is read as the index.
    if (pre_wp && pre_wmapd) {
      if (!have_owner) {
        ++orphan_pulses;
      } else if (!window_measured) {
        ++windows;
        const long tk = t - owner_tick;
        const long cy = static_cast<long>(k) - static_cast<long>(owner_cycle);
        if (windows == 1 || tk < shortest_ticks) shortest_ticks = tk;
        if (windows == 1 || tk > longest_ticks) longest_ticks = tk;
        if (windows == 1 || cy < shortest_cycles) shortest_cycles = cy;
        if (windows == 1 || cy > longest_cycles) longest_cycles = cy;
        window_measured = true;
        if (last_loadmd_tick >= 0 && last_loadmd_tick < owner_tick) {
          const long g = owner_tick - last_loadmd_tick;
          if (!any_gap || g < nearest_gap_ticks) {
            nearest_gap_ticks = g;
            any_gap = true;
          }
        }
      } else {
        ++later_pulses;
      }
      if (pre_memstart) ++pulses_from_vma; else ++pulses_from_md;
      if (((pre_vma >> 26) & 1) || ((pre_vma >> 25) & 1)) ++pulses_writing_map;
    }

    if (pre_cpu_edge && pre_pending) {
      ++pending_at_cpu_edge;
      if (root->cadr_microcycle__DOT__destmem) ++pending_at_destmem;
      if (pre_destmdr) ++pending_at_destmdr;
    }

    if (pre_loadmd_edge) {
      ++loadmd_edges;
      ++allowed;
      last_loadmd_tick = t;
      if (have_owner && !window_measured) {
        ++strobes_in_window;
        if (!window_had_strobe) { window_had_strobe = true; ++windows_with_loadmd; }
      }
      // THE COINCIDENCE ITSELF.  `-LOADMD` rising on the very tick DESTMDR
      // writes MD is the one case where the first branch of the MD register
      // is taken and the `else if` that clears `md_pending` never runs.
      if (pre_cpu_edge && pre_destmdr) ++coincidences;
    }

    dut->clk = 1;
    dut->eval();

    const uint32_t post_md = dut->md;
    const bool post_pending = root->cadr_microcycle__DOT__md_pending != 0;

    if (pre_cpu_edge && pre_destmdr) {
      ++destmdr_edges;
      // 1. The instruction's write landed.  Free, and it is what makes the
      // rest mean anything.
      if (post_md != pre_ob) {
        ++md_not_ob;
        if (bad < 20) {
          std::fprintf(stderr,
                       "FAIL: microcycle %zu, tick %ld: DESTMDR left MD %08x "
                       "where OB was %08x\n",
                       k, t, post_md, pre_ob);
          ++bad;
        }
      }
      // 2. THE INVARIANT.  Nothing may still be pending behind the write: a
      // word left queued commits at the next master clock edge --- or at the
      // very next tick if -HANG is up, a hang not being a boundary --- and
      // overwrites what the instruction put there.
      if (post_pending) {
        ++pending_left_set;
        if (bad < 20) {
          std::fprintf(stderr,
                       "FAIL: microcycle %zu, tick %ld: md_pending is still "
                       "set after DESTMDR wrote MD %08x; the held word "
                       "commits at the next master clock edge, or at the next "
                       "tick under -HANG, and overwrites it\n",
                       k, t, post_md);
          ++bad;
        }
      }
      have_owner = true;
      expect_md = post_md;
      owner_tick = t;
      owner_cycle = k;
      window_measured = false;
      window_had_strobe = false;
      allowed = 0;
    } else if (post_md != expect_md && have_owner) {
      if (allowed > 0) {
        // A word the microcode asked for since the owning DESTMDR.  MD is
        // allowed to take it, and it becomes what must stand from here.
        --allowed;
        ++commits_after_strobe;
        expect_md = post_md;
      } else {
        // 3. THE PROPERTY, on the observable.  MD has two writers and this
        // is not the instruction, so a word strobed BEFORE the owning
        // DESTMDR has committed after it.  Every map write from here to the
        // next DESTMDR is made at a different entry.
        ++stale_commits;
        if (bad < 20) {
          std::fprintf(stderr,
                       "FAIL: microcycle %zu, tick %ld: MD moved from %08x to "
                       "%08x with nothing strobed since DESTMDR wrote it at "
                       "microcycle %zu; the map is indexed by MD<23:8>, so "
                       "the entry a VMA-WRITE-MAP now reaches is %04x and not "
                       "%04x\n",
                       k, t, expect_md, post_md, owner_cycle,
                       (post_md >> 8) & 0xffff, (expect_md >> 8) & 0xffff);
          ++bad;
        }
        expect_md = post_md;
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
      if (k < total_rows) {
        if (!read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu of %zu\n",
                       path, k, total_rows);
          return 1;
        }
        drive(cur, k);
      }
    }

    dut->clk = 0;
    dut->eval();

    if (bad >= 20) {
      std::fprintf(stderr, "stopping after %d failures\n", bad);
      break;
    }
  }

  dut->final();
  delete dut;
  std::fclose(f);

  const char *which =
      pack_trace ? "a System 100 band" : "MIT's boot PROM";

  // What the run reached, printed before any verdict: a property nothing
  // could have broken is the finding, not a pass.
  std::printf(
      "%s %zu microcycles of %s, every tick\n"
      "    %ld DESTMDR writes of MD, %ld -LOADMD strobes, %ld of which\n"
      "        committed a word MD was owed\n"
      "    %ld windows --- a DESTMDR to the first map write after it ---\n"
      "        %ld to %ld ticks, %ld to %ld microcycles\n"
      "    %ld map writes under an owning DESTMDR, %ld of them further\n"
      "        writes under the same MD; %ld wrote a map level (VMA<26> or\n"
      "        VMA<25>), %ld were indexed by MD and %ld by VMA with MEMSTART\n"
      "        up; %ld had no DESTMDR before them at all\n"
      "    %ld windows carried a -LOADMD strobe, %ld strobes landed inside\n"
      "        one, %ld landed on a DESTMDR boundary\n"
      "    a word was owed at %ld cpu edges, %ld of them a DESTMEM\n"
      "        instruction and %ld of them a DESTMDR one\n",
      bad ? "measured over" : "ok:", k, which, destmdr_edges, loadmd_edges,
      commits_after_strobe, windows, shortest_ticks, longest_ticks,
      shortest_cycles, longest_cycles,
      windows + later_pulses, later_pulses, pulses_writing_map,
      pulses_from_md, pulses_from_vma, orphan_pulses,
      windows_with_loadmd, strobes_in_window, coincidences,
      pending_at_cpu_edge, pending_at_destmem, pending_at_destmdr);
  if (any_gap)
    std::printf("    the nearest a strobe outside a window came to one: %ld "
                "ticks, %ld ns\n",
                nearest_gap_ticks, nearest_gap_ticks * kTickNs);

  if (bad) {
    std::fprintf(stderr,
                 "FAIL: %ld DESTMDR writes did not land, %ld left a word "
                 "pending behind them, %ld stale words committed over an MD "
                 "its own instruction had written\n",
                 md_not_ob, pending_left_set, stale_commits);
    return 1;
  }
  if (k != total_rows) {
    std::fprintf(stderr,
                 "FAIL: the run stopped after %zu of %zu microcycles\n", k,
                 total_rows);
    return 1;
  }

  // THE CHECK HAS TO HAVE SEEN ITS OWN CASE.  A run with no window asserts
  // nothing at all and must say so rather than print "ok".
  int thin = 0;
  if (windows == 0) {
    std::fprintf(stderr,
                 "FAIL: this program opened no window at all --- no map write "
                 "followed a DESTMDR --- so the property is out of range on "
                 "this trace and the run checked nothing\n");
    ++thin;
  }
  if (pulses_writing_map == 0) {
    std::fprintf(stderr,
                 "FAIL: not one map write selected a level with VMA<26> or "
                 "VMA<25>, so no map entry was ever indexed by MD\n");
    ++thin;
  }
  if (loadmd_edges == 0 || commits_after_strobe == 0) {
    std::fprintf(stderr,
                 "FAIL: %ld -LOADMD strobes and %ld words committed; with "
                 "nothing loading MD there is nothing that could move it\n",
                 loadmd_edges, commits_after_strobe);
    ++thin;
  }
  if (destmdr_edges == 0) {
    std::fprintf(stderr, "FAIL: no instruction wrote MD on this trace\n");
    ++thin;
  }
  if (thin) return 1;

  // AND WHETHER IT WAS IN RANGE IS A SEPARATE QUESTION FROM WHETHER IT
  // PASSED.  Said on the output every run, loudly, because a property no
  // program brings a load near is a property nothing is holding.
  if (windows_with_loadmd == 0) {
    std::printf(
        "    NOT ONE WINDOW CARRIED A -LOADMD ON THIS TRACE.  The run is in\n"
        "    range for DESTMDR landing and for md_pending being clear behind\n"
        "    it, and OUT OF RANGE for a word arriving while a map write is\n"
        "    pending on MD.  A directed stimulus is what covers that, not\n"
        "    this trace.\n");
  }
  if (coincidences == 0 || pending_at_destmdr == 0) {
    std::printf(
        "    NOTHING WAS OWED AT A DESTMDR EDGE ON THIS TRACE, and no -LOADMD\n"
        "    rose on one, so the tick at which the MD register takes its\n"
        "    first branch and leaves md_pending set is unreached here.  How\n"
        "    near it came is the line above: %ld cpu edges did carry a word\n"
        "    that MD had not taken, and not one of them was an edge writing\n"
        "    MD.  tb/cadr_md_inject_tb.cpp is the stimulus for that tick, and\n"
        "    it is not a trace.\n",
        pending_at_cpu_edge);
  }
  return 0;
}
