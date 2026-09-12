// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// CAN THE COMPOSED MACHINE LEAVE MD STALE ACROSS A READ?
//
// CLAUDE.md records a latent defect in `rtl/machine/cadr_microcycle.sv`: MD
// has two writers, and at a tick where `loadmd_edge` and a `DESTMDR`
// `cpu_edge` coincide the first branch of the register runs, the `else if`
// that clears `md_pending` never does, and the held bus word commits over the
// instruction's own word one boundary later.  `tb/cadr_md_inject_tb.cpp` is
// the falsifiable statement of it and is red on purpose.  Both that and
// `tb/cadr_md_hold_tb.cpp` run against `cadr_microcycle`, where the bus is
// muir's stimulus, and CLAUDE.md's open question is the one this file exists
// to answer:
//
//     "What is not known: whether the composed machine can place that edge at
//      all.  `n_loadmd` is `!(acked || (state == UB && ub_loadmd))` where
//      `n_memack` is `!acked`, and `ub_loadmd` and `ub_acked` are two
//      registers off two due times --- so the Unibus is where the strobe and
//      the acknowledgement come apart."
//
// THE DUT IS `cadr_machine`, so the bus interface, the decode, the bridge and
// the arbiter are all in the design and only DDR is modelled.  That is the
// whole point: nothing between the processor and the memory is stimulus.
//
// WHAT IT MEASURES, AND WHY THAT IS THE RIGHT QUESTION.
//
// The coincidence needs a `cpu_edge` on the tick -LOADMD falls, on an
// instruction whose destination is MD.  A destination of MD is a DESTMEM, and
// -WAIT's first term is `DESTMEM AND MBUSY.SYNC` --- so the coincidence is
// reachable only if MBUSY.SYNC can be DOWN at a tick where -LOADMD falls.
// That is a property of the composed machine, it is one bit wide, and it is
// what this file counts.  Three facts are printed rather than argued:
//
//   1. every tick -LOADMD falls, with MBUSY, MBUSY.SYNC, -MEMGRANT, the
//      instruction's held DESTMEM and whether the tick was a master clock
//      edge and a cpu edge;
//   2. the number of coincidences, which is the defect's own precondition;
//   3. the invariant itself --- that MD, at every cpu edge after a read the
//      MODEL answered, holds the word the MODEL handed back.
//
// THE WORD COMPARED IS THE MODEL'S, NEVER THE DUT'S.  CLAUDE.md's shadow
// memory rule: the expected word is what this file put on `mem_rdata`, at the
// address this file decoded, so a bridge that latched the wrong word, a
// processor that took it at the wrong instant and a strobe that arrived
// without its word are all visible.  The poison is injective in the address,
// so a word from the wrong place is not a word from anywhere.
//
// THE LATENCY SCHEDULE WALKS THE MICROCYCLE.  A fixed delay puts every
// acknowledgement at the same phase of the 29-tick microcycle and would
// measure one phase 512 times.  The schedule steps by a stride coprime with
// 29 over a span wider than a microcycle, so the acknowledgement lands at
// every offset from the boundary that the machine's own stalling permits ---
// and the histogram of those offsets is printed, because a phase that never
// occurs is the finding.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>

#include "Vcadr_machine.h"
#include "Vcadr_machine___024root.h"
#include "verilated.h"

namespace {

constexpr uint32_t kMainBase = 0x18000000u;
constexpr int kPageWords = 256;
constexpr int kWindowWords = 4096;
constexpr uint32_t kNotAnswering = 0xDEADBEE5u;

// Far enough past the parity loop's 512 cycles, which close at about 118 ms.
constexpr long kTicks = 40000000L;

// A poison injective in the word, and never zero, so "MD took nothing" and
// "MD took the word" cannot be confused.  Bit 0 is cleared so that the boot
// PROM's disk-ready test reads the same as `ddr_boot`'s configuration A.
uint32_t Poison(int word) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>(word + 1)) ^ 0xA5A5A5A5u;
  return p & ~1u;
}

int fails = 0;
constexpr int kFailuresPrinted = 20;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  if (fails > kFailuresPrinted) return;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: ");
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
  if (fails == kFailuresPrinted)
    std::fprintf(stderr, "  (further failures counted and not printed)\n");
}

// One tick on which -LOADMD fell, with everything that decides whether the
// coincidence is reachable there.
struct Strobe {
  long tick;
  long micro;
  int mbusy, mbusy_sync, memgrant, destmem_q, mclk_edge, cpu_edge, destmdr;
  int rdcyc;
  long since_edge;    // ticks since the last master clock edge
  uint32_t rdata;
};

struct Run {
  long micro = 0;
  long reads = 0, writes = 0;
  long strobes = 0;
  long coincidences = 0;
  long mbusy_down_at_strobe = 0;
  long sync_down_at_strobe = 0;
  long pending_across_destmdr = 0;
  long md_checked = 0;
  long md_landed = 0;          // model read words watched into MD
  long dir_wrong = 0;          // a DDR transaction whose direction is not WRCYC's
  long late_land = 0;          // words not in MD by the deadline
  long deferred = 0;           // strobes that landed ON a boundary tick
  long strobe_on_edge = 0;
  long read_carried_md = 0;    // reads whose write-data lines carried MD
  std::vector<Strobe> first;      // the first few, printed
  std::map<long, long> phase;     // ticks since the last boundary, histogram
  long final_pc = -1;
};

long Latency(size_t n) {
  // 4..40 ticks, stride 13, which is coprime with both 29 and 37.
  return 4 + static_cast<long>((n * 13) % 37);
}

Run Simulate() {
  Run out;
  std::vector<uint32_t> mem(kWindowWords);
  for (int i = 0; i < kWindowWords; ++i) mem[i] = Poison(i);

  auto *dut = new Vcadr_machine;
  auto *root = dut->rootp;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->mem_done = 0;
  dut->mem_rdata = kNotAnswering;
  dut->eval();

  long pending = -1;
  bool req_last = false;
  long last_edge = -1;

  // What the model last handed back on a READ.  Every one of these is the
  // model's own word, never the DUT's.
  //
  //   owed   answered by the model, the strobe not yet seen
  //   pend   strobed, not yet committed to MD --- the word is due at the
  //          first master clock edge, or at once while -HANG is up
  //   held   committed, and MD must go on holding it until an instruction
  //          writes MD or another slave strobes
  uint32_t owed_md = 0;
  bool owed = false;
  uint32_t pend_md = 0;
  bool pend = false;
  uint32_t held_md = 0;
  bool held = false;

  int n_loadmd_last = 1;
  bool due_land = false, due_hold = false;
  bool strobed_on_edge = false;
  uint32_t due_land_md = 0, due_hold_md = 0;

  for (long t = 0; t < kTicks; ++t) {
    dut->rst = (t < 8);

    dut->mem_done = 0;
    dut->mem_rdata = kNotAnswering;
    if (dut->mem_req) {
      if (!req_last) pending = Latency(static_cast<size_t>(out.reads + out.writes));
      if (pending > 0) --pending;
      if (pending == 0) {
        const long w =
            (static_cast<long>(dut->mem_addr) - static_cast<long>(kMainBase)) / 4;
        const bool inside =
            w >= 0 && w < kWindowWords && (dut->mem_addr & 3u) == 0;
        // THE DIRECTION THE BRIDGE ASKS FOR MUST BE THE ONE THE PROCESSOR'S
        // OWN WRCYC/RDCYC FLIP FLOP HOLDS.  `cadr_microcycle.sv` calls that
        // pair "one flip flop, the 74S175 at 1C23 on CLK2A: load or hold, so
        // the direction is the *starting* instruction's and it stands until
        // the next cycle starts", and `cadr_busint_xbus.sv` latches `write`
        // from it once, in IDLE.  A read performed as a write puts `wdata`
        // --- which is MD, captured at MEMGO whatever the direction --- into
        // memory at the read's own address, and nothing downstream could tell
        // that from a legitimate store.  Nothing else in `make check`
        // compares the two.
        if ((dut->mem_write != 0) != (dut->wrcyc != 0)) ++out.dir_wrong;
        if (dut->mem_write) {
          ++out.writes;
          if (inside) mem[w] = dut->mem_wdata;
        } else {
          ++out.reads;
          // **WHAT THE WRITE-DATA LINES CARRY DURING A READ**, measured rather
          // than reasoned about.  `cadr_microcycle.sv` loads `wdata` from MD
          // at MEMGO whatever the direction --- which is the board's own
          // behaviour, MEM<31:0> being driven from MD by the master --- so on
          // every read the whole of MD is standing on `mem_wdata` at the
          // bridge.  The consequence is worth a number: one wrong bit of
          // `mem_write` on one cycle silently replaces a memory word with MD,
          // at the address the read asked for, and nothing in the machine or
          // in the microcode can tell afterwards.
          if (dut->mem_wdata == dut->md) ++out.read_carried_md;
          const uint32_t word = inside ? mem[w] : kNotAnswering;
          dut->mem_rdata = word;
          owed_md = word;
          owed = true;
        }
        dut->mem_done = 1;
        pending = -1;
      }
    } else {
      pending = -1;
    }
    req_last = dut->mem_req != 0;

    dut->clk = 1;
    dut->eval();

    // THE SAMPLING CONVENTION, AND IT COSTS A TICK.  After `eval()` at the
    // rising edge the registers hold their POST-edge values, so every
    // combinational signal read here --- `mclk_edge`, `cpu_edge`, `destmdr`,
    // `n_loadmd` --- is already built out of them and is therefore the value
    // the NEXT edge will see.  They are all shifted by the same one tick, so
    // the relations between them are exact; what is not exact is comparing
    // one of them against a REGISTER read in the same breath.  `md` is a
    // register, so every comparison of it is deferred by a tick below.
    const int n_loadmd = dut->n_loadmd_o;
    const int cpu_edge = root->cadr_machine__DOT__processor__DOT__cpu_edge;
    const int mclk_edge = root->cadr_machine__DOT__processor__DOT__mclk_edge;
    const int destmdr = root->cadr_machine__DOT__processor__DOT__destmdr;
    const int md_pending = root->cadr_machine__DOT__processor__DOT__md_pending;

    if (mclk_edge) last_edge = t;

    const bool strobe = (n_loadmd == 0) && (n_loadmd_last == 1) && dut->rdcyc_o;
    if (strobe) {
      ++out.strobes;
      Strobe s;
      s.tick = t;
      s.micro = out.micro;
      s.mbusy = dut->mbusy_o;
      s.mbusy_sync = dut->mbusy_sync_o;
      s.memgrant = dut->n_memgrant_o;
      s.destmem_q = root->cadr_machine__DOT__processor__DOT__destmem_q;
      s.mclk_edge = mclk_edge;
      s.cpu_edge = cpu_edge;
      s.destmdr = destmdr;
      s.rdcyc = dut->rdcyc_o;
      s.since_edge = last_edge < 0 ? -1 : t - last_edge;
      s.rdata = owed ? owed_md : 0;
      if (out.first.size() < 12) out.first.push_back(s);
      ++out.phase[s.since_edge];
      if (!s.mbusy) ++out.mbusy_down_at_strobe;
      if (!s.mbusy_sync) ++out.sync_down_at_strobe;
      if (cpu_edge && destmdr) ++out.coincidences;
      // A strobe the model owes no word for is a device cycle or the NXM
      // timer.  MD legitimately takes whatever that slave drove, which this
      // file does not model, so the invariant simply stops watching --- it
      // never guesses.
      pend = owed;
      pend_md = owed_md;
      held = false;
      owed = false;
      strobed_on_edge = mclk_edge != 0;
      if (mclk_edge) ++out.strobe_on_edge;
    }
    n_loadmd_last = n_loadmd;

    // THE INVARIANT, in two halves.
    //
    //   the landing  a word the model handed back on a read must be IN MD by
    //                the first master clock edge after its strobe.  That is
    //                muir's own rule --- `Rtl::after_memack` applies the word
    //                where the engine looks --- and it is what a -WAIT or a
    //                -HANG that failed to hold the machine would break.
    //   the holding  and it must still be there at every cpu edge after that,
    //                until an instruction writes MD or another slave strobes.
    //                That is `tb/cadr_md_hold_tb.cpp`'s property with a real
    //                bus under it instead of muir's stimulus.
    // The deferred comparisons, one tick after the edge they are about.
    if (due_land) {
      due_land = false;
      ++out.md_landed;
      if (dut->md != due_land_md) {
        ++out.late_land;
        Check(false,
              "microcycle %ld tick %ld: the model answered a read with %08x "
              "and MD holds %08x at the master clock edge after the strobe",
              out.micro, t, due_land_md, dut->md);
      }
    }
    if (due_hold) {
      due_hold = false;
      ++out.md_checked;
      Check(dut->md == due_hold_md,
            "microcycle %ld tick %ld: MD is %08x, wanting the word the model "
            "handed back, %08x",
            out.micro, t, dut->md, due_hold_md);
    }

    // **A STROBE THAT LANDS ON A MASTER CLOCK EDGE COSTS THE WORD A WHOLE
    // MICROCYCLE, and it is reachable.**  The MD register takes the
    // `loadmd_edge` branch on that tick, so the `else if` that commits the
    // held word does not run and the commit waits for the NEXT boundary.
    // Measured here rather than argued: it happens on about one read in
    // thirty-six, which is what a 29-tick microcycle and an acknowledgement
    // free to land anywhere gives.  It is harmless only because -HANG covers
    // it --- `rd_in_progress` is still up for RD_FINISH_T ticks, so an
    // instruction that READS MD in that microcycle parks the generator and
    // the word commits on the next tick, before its read phase.  An
    // instruction that does not read MD does not care.  So the deadline this
    // file holds to is the second boundary, and the count of words that
    // needed it is printed.
    if (mclk_edge && pend && strobed_on_edge) {
      strobed_on_edge = false;
      ++out.deferred;
    } else if (mclk_edge && pend) {
      if (destmdr && cpu_edge) {
        // The instruction's own word wins and the bus word is consumed; the
        // flag must not survive.  This is the latent defect's exact statement.
        if (md_pending) ++out.pending_across_destmdr;
        pend = false;
      } else {
        due_land = true;
        due_land_md = pend_md;
        held_md = pend_md;
        held = true;
        pend = false;
      }
    }

    if (cpu_edge) {
      ++out.micro;
      if (destmdr) {
        held = false;
        if (md_pending) ++out.pending_across_destmdr;
      } else if (held) {
        due_hold = true;
        due_hold_md = held_md;
      }
    }

    out.final_pc = dut->pc;
    dut->clk = 0;
    dut->eval();
  }
  dut->final();
  delete dut;
  return out;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  std::printf("md_compose: can the composed machine leave MD stale?\n");
  std::printf("  DUT              cadr_machine, DDR modelled, nothing else\n");
  std::printf("  program          MIT's boot PROM\n");
  std::printf("  DDR latency      4..40 ticks, stride 13 a transaction\n");

  Run r = Simulate();

  std::printf("\n  microcycles      %ld\n", r.micro);
  std::printf("  DDR reads        %ld\n", r.reads);
  std::printf("  DDR writes       %ld\n", r.writes);
  std::printf("  -LOADMD strobes  %ld with RDCYC up\n", r.strobes);
  std::printf("  words landed     %ld read words watched into MD\n", r.md_landed);
  std::printf("  MD compared      %ld times against the model's own word\n",
              r.md_checked);
  std::printf("  direction wrong  %ld of %ld DDR transactions\n", r.dir_wrong,
              r.reads + r.writes);
  std::printf("  strobe on a boundary tick        %ld of %ld reads\n",
              r.strobe_on_edge, r.reads);
  std::printf("  words deferred a whole microcycle %ld\n", r.deferred);
  std::printf("  reads with MD on the write lines %ld of %ld\n",
              r.read_carried_md, r.reads);

  std::printf("\n  the first strobes, and what was true on their tick:\n");
  std::printf("    %-10s %-9s %-5s %-5s %-5s %-8s %-5s %-5s %-6s\n",
              "tick", "microcyc", "MBSY", "SYNC", "GRNT", "DESTMEMq", "MCLK",
              "CPU", "DESTMD");
  for (const Strobe &s : r.first) {
    std::printf("    %-10ld %-9ld %-5d %-5d %-5d %-8d %-5d %-5d %-6d\n", s.tick,
                s.micro, s.mbusy, s.mbusy_sync, !s.memgrant, s.destmem_q,
                s.mclk_edge, s.cpu_edge, s.destmdr);
  }

  std::printf("\n  ticks from the last master clock edge to the strobe:\n");
  for (const auto &kv : r.phase)
    std::printf("    %4ld ticks  %ld strobes\n", kv.first, kv.second);

  std::printf("\n  MBUSY down at a strobe            %ld of %ld\n",
              r.mbusy_down_at_strobe, r.strobes);
  std::printf("  MBUSY.SYNC down at a strobe       %ld of %ld\n",
              r.sync_down_at_strobe, r.strobes);
  std::printf("  strobe on a DESTMDR cpu edge      %ld\n", r.coincidences);
  std::printf("  md_pending left set over DESTMDR  %ld\n",
              r.pending_across_destmdr);

  // THE GATE, stated as a claim and not as a story.  -LOADMD cannot fall
  // before -MEMACK on either bus --- on the Xbus they are the same signal
  // through `acked`, and on the Unibus UB_STROBE_T (20 ticks) is less than
  // UB_ACK_T (30) --- and MBUSY is cleared MFINISHD_T (6 ticks) AFTER
  // -MEMACK.  So MBUSY is up at every strobe, MBUSY.SYNC was registered at a
  // boundary where MEMRQ was up, and -WAIT's first term holds MACHRUN down
  // for exactly the instruction the coincidence needs.
  Check(r.mbusy_down_at_strobe == 0,
        "MBUSY was down on %ld of %ld -LOADMD strobes; the gate that makes the "
        "DESTMDR coincidence unreachable is not holding",
        r.mbusy_down_at_strobe, r.strobes);
  Check(r.sync_down_at_strobe == 0,
        "MBUSY.SYNC was down on %ld of %ld -LOADMD strobes", r.sync_down_at_strobe,
        r.strobes);
  Check(r.coincidences == 0,
        "%ld -LOADMD strobes landed on a DESTMDR cpu edge --- the latent "
        "defect's precondition IS reachable on the composed machine",
        r.coincidences);
  Check(r.pending_across_destmdr == 0,
        "md_pending was left set over %ld DESTMDR edges", r.pending_across_destmdr);
  Check(r.strobes > 200, "only %ld strobes; this run exercised nothing",
        r.strobes);
  Check(r.micro > 800000,
        "the machine retired only %ld microcycles; it did not get through the "
        "program and nothing below is about the program it was meant to run",
        r.micro);
  // NOT a failure, and saying why is the point: the boot PROM's parity loop
  // writes MD with the instruction that follows every read, so there is no
  // microcycle in this program where MD is holding a bus word and the
  // instruction is not about to overwrite it.  The holding half of the
  // invariant is therefore uncovered HERE and covered by
  // `build/md_hold.pass` on both programs; what this file covers that
  // nothing else does is the landing, with a real bus under it.
  std::printf("  holding half     %s\n",
              r.md_checked ? "exercised"
                           : "NOT exercised by this program --- see md_hold");
  Check(r.md_landed > 200, "only %ld read words were watched into MD",
        r.md_landed);
  Check(r.late_land == 0, "%ld read words had not reached MD by the boundary",
        r.late_land);
  Check(r.dir_wrong == 0,
        "%ld DDR transactions asked for a direction the processor's WRCYC did "
        "not hold",
        r.dir_wrong);
  Check(r.reads == 256 && r.writes == 256,
        "%ld reads and %ld writes, wanting 256 of each", r.reads, r.writes);

  if (fails) {
    std::printf("\nmd_compose: %d failures\n", fails);
    return 1;
  }
  std::printf(
      "\nmd_compose: MD never stale, and the DESTMDR coincidence was not "
      "reachable in %ld strobes\n",
      r.strobes);
  return 0;
}
