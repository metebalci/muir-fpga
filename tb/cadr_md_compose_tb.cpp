// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// CAN THE COMPOSED MACHINE LEAVE MD STALE ACROSS A READ?
//
// There is a latent defect in `rtl/machine/cadr_microcycle.sv`: MD has three
// writers --- the third of them held by the last section of this file --- and
// at a tick where `loadmd_edge` and a `DESTMDR` `cpu_edge` coincide the first
// branch of the register runs, the `else if` that clears `md_pending` never
// does, and the held bus word commits over the instruction's own word one
// boundary later.  `tb/cadr_md_inject_tb.cpp` is the falsifiable statement of
// it and is red on purpose.  Both that and `tb/cadr_md_hold_tb.cpp` run
// against `cadr_microcycle`, where the bus is muir's stimulus, and
// the open question is the one this file exists to answer:
//
//     What is not known: whether the composed machine can place that edge at
//     all.  `n_loadmd` is `!(acked || (state == UB && ub_loadmd))` where
//     `n_memack` is `!acked`, and `ub_loadmd` and `ub_acked` are two
//     registers off two due times --- so the Unibus is where the strobe and
//     the acknowledgment come apart.
//
// THE DUT IS `cadr_machine`, so the bus interface, the decode, the bridge and
// the arbiter are all in the design and only DDR is modeled.  That is the
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
// THE WORD COMPARED IS THE MODEL'S, NEVER THE DUT'S.  The shadow-memory rule:
// the expected word is what this file put on `mem_rdata`, at the address this
// file decoded, so a bridge that latched the wrong word, a processor that
// took it at the wrong instant and a strobe that arrived without its word are
// all visible.  The poison is injective in the address, so a word from the
// wrong place is not a word from anywhere.
//
// THE LATENCY SCHEDULE WALKS THE MICROCYCLE.  A fixed delay puts every
// acknowledgment at the same phase of the 29-tick microcycle and would
// measure one phase 512 times.  The schedule steps by a stride coprime with
// 29 over a span wider than a microcycle, so the acknowledgment lands at
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
#include "cadr_tick.h"
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
  // `UB MD LOAD`, MD's third writer: a foreign master's mapped write.
  long md_loads = 0;           // edges the debugger's word was taken at
  long md_gate_waits = 0;      // ticks the request stood while the gate held
  long md_wait_mbusy = 0;      // of those, ticks MBUSY was the term holding it
  long md_wait_pending = 0;    // and ticks md_pending was
  long md_word_wrong = 0;      // loads after which MD did not hold the word
  long md_across_processor = 0; // loads taken while the processor owned MD
  long md_answered = 0;        // mapped writes of MD the interface answered
  long md_load_on_even = 0;    // a load on the EVEN word, which is the buffer
  long md_load_missing = 0;    // an odd word that never reached the load
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
  // `-BOOT2` is a pulled-up line and nothing on this check presses it.
  // **Active low, so an undriven input would hold the machine at the boot
  // trap for ever**, which is the loud failure this line exists to avoid.
  dut->n_boot2 = 1;
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
          // behavior, MEM<31:0> being driven from MD by the master --- so on
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
    // thirty-six, which is what a 29-tick microcycle and an acknowledgment
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

  // ---------------------------------------------------------------------
  // `UB MD LOAD`: MD's THIRD WRITER, ON A MACHINE THAT IS STILL RUNNING.
  // ---------------------------------------------------------------------
  //
  // A Unibus master that is not this board, writing through a map entry whose
  // page has its high five bits ones, loads the processor's `MD` with the two
  // halves instead of putting them on the Xbus: `busint::map_to_md`, CC's
  // `CC-WRITE-MD`, which is how the debugger sets the pushdown buffer index
  // and how every write it makes through `MD` gets there.  `MD` had two
  // writers and now has three, and the whole question this file exists to ask
  // --- can one of them land across another --- is asked of the new one here.
  //
  // **THE MACHINE IS LEFT RUNNING ON PURPOSE.**  muir's own gate is that the
  // interface must not be in a granted cycle, and its reason is that "the
  // debuggee CC works on is halted" --- so a halted debuggee would test the
  // gate against the one case where it cannot bite.  Running MIT's boot PROM
  // under it gives real `MBUSY` windows for the request to arrive in, and the
  // check is the invariant rather than an outcome: every edge the word is
  // taken at has both terms DOWN, and every tick the request waits is counted
  // --- split by which term held it --- so the coverage is on the output.
  //
  // **AND THE SPLIT SAYS THE `md_pending` TERM IS UNCOVERED HERE, WHICH IS
  // THE HONEST THING TO PRINT.**  Measured: 54 ticks of waiting over three
  // writes, `MBUSY` up for every one of them and `md_pending` for one.  The
  // reason is structural --- `md_pending` is cleared at once under `-HANG`
  // and the boot PROM hangs at nearly every strobe it makes --- so the window
  // that term is about is about one tick long on this program.
  // `mutations/list.txt` carries that as a measured equivalence rather than
  // as a record nothing catches.
  //
  // The master is this file on `con_*`, which is the seam a foreign master
  // presents to `cadr_machine` --- `con_gnt` is half of the `ub_foreign` the
  // window answers on.  `tb/cadr_unibus_tb.cpp` runs the same route with
  // MIT's own cable one module down.
  {
    auto TickMd = [&]() {
      dut->mem_done = 0;
      dut->mem_rdata = kNotAnswering;
      if (dut->mem_req) {
        const long w = (static_cast<long>(dut->mem_addr) - static_cast<long>(kMainBase)) / 4;
        const bool inside = w >= 0 && w < kWindowWords && (dut->mem_addr & 3u) == 0;
        if (dut->mem_write) {
          if (inside) mem[w] = dut->mem_wdata;
        } else {
          dut->mem_rdata = inside ? mem[w] : kNotAnswering;
        }
        dut->mem_done = 1;
      }
      dut->clk = 1;
      dut->eval();
      // Post-edge, so everything read here is what the NEXT edge will see:
      // the same convention the loop above works in.
      if (root->cadr_machine__DOT__ub_md_req && !root->cadr_machine__DOT__ub_md_ack) {
        ++out.md_gate_waits;
        // Which term held it, so the coverage says whether a mutation of
        // either could bite rather than leaving it to be guessed.
        if (root->cadr_machine__DOT__processor__DOT__mbusy) ++out.md_wait_mbusy;
        if (root->cadr_machine__DOT__processor__DOT__md_pending) ++out.md_wait_pending;
      }
      dut->clk = 0;
      dut->eval();
    };

    // The cycle a foreign master runs: the request up, the grant taken, the
    // strobe held until the slave answers, and the request dropped once the
    // line is free.  It watches for `UB MD LOAD` throughout and compares `MD`
    // at the tick after the edge that took the word --- the gate forbids any
    // other writer at that edge, so one tick is exact.
    auto Foreign = [&](unsigned uaddr, int write, unsigned wdata, long guard) -> int {
      dut->con_req = 1;
      dut->con_addr = uaddr;
      dut->con_write = write;
      dut->con_wdata = wdata;
      for (long g = 0; g < 4000 && !dut->con_gnt; ++g) TickMd();
      dut->con_msyn = 1;
      int answered = 0, due = 0;
      uint32_t want = 0;
      for (long g = 0; g < guard; ++g) {
        TickMd();
        // The edge that took the word has just happened, so `md` is the
        // register's post-edge value: the gate forbids any other writer at
        // that edge, which is what makes one tick exact.
        if (due) {
          due = 0;
          if (dut->md != want) ++out.md_word_wrong;
        }
        if (root->cadr_machine__DOT__ub_md_ack) {
          ++out.md_loads;
          want = root->cadr_machine__DOT__ub_md_data;
          due = 1;
          // The invariant: the debugger's word is never taken at an edge
          // where the processor's own path into `MD` is live.
          if (root->cadr_machine__DOT__processor__DOT__md_pending ||
              root->cadr_machine__DOT__processor__DOT__mbusy)
            ++out.md_across_processor;
        }
        if (dut->con_ssyn) {
          answered = 1;
          break;
        }
      }
      if (due) {
        TickMd();
        if (dut->md != want) ++out.md_word_wrong;
      }
      dut->con_msyn = 0;
      for (long g = 0; g < 400; ++g) TickMd();
      dut->con_req = 0;
      for (long g = 0; g < 40; ++g) TickMd();
      return answered;
    };

    // CC's own entry: "CC-WRITE-MD loads map register 16 with 177000".
    Foreign(0766140u + 2u * 016u, 1, 0177000u, 8000);
    // Three pairs, the halves differing in every byte, at three words of the
    // page --- `MD` has no address and this is what says so.
    const unsigned pairs[3][2] = {{0xC3A5u, 0x7E19u}, {0x0FF0u, 0x1234u}, {0xFFFFu, 0x0000u}};
    for (int i = 0; i < 3; ++i) {
      const unsigned base = 0140000u + (016u << 10) + ((0x21u + (unsigned)i) << 2);
      // The EVEN word is the page's write buffer and no load at all.
      const long before = out.md_loads;
      Foreign(base, 1, pairs[i][0], 8000);
      if (out.md_loads != before) ++out.md_load_on_even;
      // The ODD word loads `MD` with the two halves, and is ANSWERED:
      // `-LOADMD ACK` at REQLM 0A11 is what acknowledges the cycle, which is
      // the whole of what used to hang.
      out.md_answered += Foreign(base + 2, 1, pairs[i][1], 8000);
      if (out.md_loads != before + 1) ++out.md_load_missing;
    }
  }

  dut->final();
  delete dut;
  return out;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  std::printf("md_compose: can the composed machine leave MD stale?\n");
  std::printf("  DUT              cadr_machine, DDR modeled, nothing else\n");
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

  std::printf("\n  UB MD LOAD, MD's third writer --- a foreign master's mapped write:\n");
  std::printf("    loads taken        %ld\n", r.md_loads);
  std::printf("    cycles answered    %ld by -LOADMD ACK\n", r.md_answered);
  std::printf("    ticks the gate held the request off  %ld --- %ld on MBUSY, %ld on md_pending\n",
              r.md_gate_waits, r.md_wait_mbusy, r.md_wait_pending);
  std::printf("    loads across the processor's own MD path  %ld\n", r.md_across_processor);
  std::printf("    loads after which MD did not hold the word  %ld\n", r.md_word_wrong);
  std::printf("    loads on the even word (the buffer's)  %ld\n", r.md_load_on_even);
  std::printf("    odd words that never reached a load  %ld\n", r.md_load_missing);

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

  // `UB MD LOAD`.  Three pairs, three loads, three acknowledgments; the word
  // in `MD` after every one of them; and the invariant that no load was taken
  // at an edge where the processor's own path into `MD` was live.
  Check(r.md_loads == 3, "%ld writes of MD reached UB MD LOAD, wanting 3", r.md_loads);
  Check(r.md_answered == 3,
        "%ld mapped writes of MD were acknowledged, wanting 3 --- -LOADMD ACK is "
        "what answers the cycle and a debugger hangs for ever without it",
        r.md_answered);
  // In nanoseconds of MIT's time and not in ticks, so that the bar is the
  // same at any grid: 100 ns, which was twenty ticks at 5 ns.
  Check(r.md_gate_waits * kGridNs > 100,
        "the gate held the request off for only %ld ticks, %ld ns, which is "
        "too few for the refusal to be a measurement rather than a coincidence",
        r.md_gate_waits, r.md_gate_waits * kGridNs);
  Check(r.md_word_wrong == 0,
        "%ld writes of MD left MD holding something other than the word that "
        "went out on UB MD LOAD",
        r.md_word_wrong);
  Check(r.md_load_on_even == 0,
        "%ld EVEN words of a write of MD reached UB MD LOAD; the even word is "
        "the page's write buffer and nothing else",
        r.md_load_on_even);
  Check(r.md_load_missing == 0, "%ld odd words never reached UB MD LOAD",
        r.md_load_missing);
  Check(r.md_across_processor == 0,
        "%ld writes of MD were taken while the processor's own MBUSY or "
        "md_pending was up",
        r.md_across_processor);

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
