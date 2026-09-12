// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE FABRIC-SIDE AUDIT, HELD TO WHAT IT HAS TO SAY.
//
// `rtl/plumbing/cadr_bus_audit.sv` is an INSTRUMENT, and this repository's
// rule about those is that an instrument nothing checks is worse than no
// instrument: it will be read on a board, once, and believed.  The tally at
// `rtl/plumbing/cadr_mem_count.sv` carries the same sentence at the head of
// its own check and for the same reason.
//
// THE DUT IS THE MODULE ALONE and the stimulus is directed, which is the
// opposite of `tb/cadr_bus_audit_tb.cpp` next door: that one runs the property
// through the whole composed machine on MIT's boot PROM, where the fault
// clauses never fire and what is proved is that they never fire.  A program
// cannot be made to fault on demand, so the clauses themselves --- what each
// one catches, which one wins when two are true at once, what is captured, and
// what the word reads --- have no stimulus there at all.  Here every clause is
// driven on purpose.
//
// WHAT IS HELD, in the order the cases run:
//
//   CLEAN     twenty well-formed bus cycles of both directions, memory and
//             not, must leave every counter at zero and the latch empty.  The
//             guard, and the one that matters most: a fault detector that
//             fires on correct traffic is useless, and every case below would
//             still pass if it did.
//   NO CYCLE  a request with no bus cycle open --- the transaction the fabric
//             invented, which is the board's own suspect.
//   NOT MEMORY  a request on a cycle the decode did not call main memory.
//   DIRECTION a request whose direction is not the one the cycle holds.  THE
//             CAPTURED WORD IS ASSERTED HERE and not merely the clause,
//             because what makes this instrument worth having is that it names
//             the word a spurious write would have put into memory.
//   TWO REQS  one bus cycle that asks the port twice.
//   TWICE     one request answered twice.
//   LOOSE ANS an answer with no request standing, which is the only shape in
//             which a transaction the AXI adapter ran by itself is visible
//             from inside `cadr_machine` --- the adapter being outside it, so
//             its address channels are not.
//   STALLED   a request that falls with no answer at all.  It must count in
//             its OWN counter and must NOT take the first-fault latch: on a
//             board where `ps7_post_config` has not run every request falls
//             this way, and a dead port that erased the record would be the
//             instrument destroying its own evidence.
//   FIRST     two faults, different clauses: the latch holds the FIRST and the
//             count reaches two.
//   SATURATES faults beyond 32,767 leave the counter at 32,767 and the latch
//             untouched.
//   MARKER    every one of the eight words carries `B05A` in its top sixteen
//             bits, so that neither an all-zeros nor an all-ones reading can
//             be mistaken for this module's answer.  Measured against both, as
//             CLAUDE.md's EMIO entry says it must be: that lesson was learned
//             from a board reading `0xFFFFFFFF` where four saturated counters
//             would have read the same.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "Vcadr_bus_audit.h"
#include "verilated.h"

namespace {

constexpr uint16_t kMark = 0xB05A;

// The clause codes, as the module names them.
constexpr int kNone = 0, kTwice = 1, kTwoReqs = 2, kDirection = 3,
              kNoCycle = 4, kNotMemory = 5, kLooseAns = 6;

int fails = 0;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: ");
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

// A poison injective in the word, never zero and never all ones, so a captured
// field that took nothing and one that took the word cannot be confused.
uint32_t Poison(int n) {
  return (0x9E3779B9u * static_cast<uint32_t>(n + 1)) ^ 0xA5A5A5A5u;
}

struct Dut {
  Vcadr_bus_audit *m = new Vcadr_bus_audit;

  void tick() {
    m->clk = 1;
    m->eval();
    m->clk = 0;
    m->eval();
  }

  void reset() {
    m->clk = 0;
    m->rst = 1;
    m->cycle = 0;
    m->cycle_write = 0;
    m->cycle_memory = 0;
    m->cycle_phys = 0;
    m->mem_req = 0;
    m->mem_write = 0;
    m->mem_done = 0;
    m->mem_addr = 0;
    m->mem_wdata = 0;
    m->boundary = 0;
    m->vma = 0;
    m->md = 0;
    m->pc = 0;
    m->opc = 0;
    m->sel = 0;
    m->eval();
    for (int i = 0; i < 4; ++i) tick();
    m->rst = 0;
    tick();
  }

  // One microcycle boundary, so that a fault has a coordinate to be named in.
  void boundary() {
    m->boundary = 1;
    tick();
    m->boundary = 0;
  }

  // A well-formed bus cycle: open it, raise the request, answer it once, drop
  // the request, close it.  `reqs` says how many requests to raise inside it
  // and `answers` how many answers to give each --- both 1 for a clean cycle.
  void cycle(bool write, bool memory, uint32_t phys, uint32_t addr,
             uint32_t wdata, int reqs = 1, int answers = 1,
             bool req_write = false, bool use_req_write = false) {
    m->cycle = 1;
    m->cycle_write = write;
    m->cycle_memory = memory;
    m->cycle_phys = phys;
    tick();
    for (int r = 0; r < reqs; ++r) {
      m->mem_req = 1;
      m->mem_write = use_req_write ? req_write : write;
      m->mem_addr = addr;
      m->mem_wdata = wdata;
      tick();
      for (int a = 0; a < answers; ++a) {
        m->mem_done = 1;
        tick();
        m->mem_done = 0;
        tick();
      }
      m->mem_req = 0;
      tick();
    }
    m->cycle = 0;
    tick();
  }

  // A request with no bus cycle open at all.
  void loose_request(bool write, uint32_t addr, uint32_t wdata) {
    m->mem_req = 1;
    m->mem_write = write;
    m->mem_addr = addr;
    m->mem_wdata = wdata;
    tick();
    m->mem_done = 1;
    tick();
    m->mem_done = 0;
    m->mem_req = 0;
    tick();
  }

  uint64_t word(int s) {
    m->sel = s;
    tick();
    tick();
    return m->word;
  }

  uint16_t mark(int s) { return static_cast<uint16_t>(word(s) >> 32); }
  uint32_t low(int s) { return static_cast<uint32_t>(word(s)); }

  long faults() { return word(0) & 0x7FFFu; }
  long stalled() { return (word(0) >> 16) & 0x7FFFu; }
  // The latch IS the clause: zero says nothing was latched, so there is no
  // separate valid bit for it to disagree with.
  int clause() { return static_cast<int>((word(1) >> 22) & 7u); }
  bool valid() { return clause() != kNone; }
  int seen() { return static_cast<int>((word(1) >> 25) & 0x3Fu); }
  uint32_t phys() { return word(1) & 0x3FFFFFu; }
};

void RunClean(Dut &d) {
  d.reset();
  // Both directions, memory and not, and a cycle that asks nothing at all ---
  // which is what every device and Unibus and NXM cycle is.
  for (int i = 0; i < 20; ++i) {
    d.boundary();
    const bool write = (i % 3) == 0;
    if (i % 2) {
      d.cycle(write, true, 0x100 + i, 0x18000000 + 4 * i, Poison(i));
    } else {
      // A cycle the decode did not call memory, asking nothing: the shape the
      // boot PROM makes 88,695 times.
      d.m->cycle = 1;
      d.m->cycle_write = write;
      d.m->cycle_memory = 0;
      d.m->cycle_phys = 017377774;
      d.tick();
      d.tick();
      d.m->cycle = 0;
      d.tick();
    }
  }
  Check(d.faults() == 0, "clean traffic produced %ld faults", d.faults());
  Check(d.stalled() == 0, "clean traffic produced %ld stalled requests",
        d.stalled());
  Check(!d.valid(), "clean traffic latched a fault");
  Check(d.clause() == kNone, "clean traffic latched clause %d", d.clause());
  Check(d.seen() == 0, "clean traffic set the clause bitmap to %#x", d.seen());
}

void RunClause(const char *name, int want, void (*drive)(Dut &)) {
  Dut d;
  d.reset();
  drive(d);
  Check(d.valid(), "%s: nothing was latched", name);
  Check(d.clause() == want, "%s: clause %d latched, wanting %d", name,
        d.clause(), want);
  Check(d.faults() >= 1, "%s: the fault count is %ld", name, d.faults());
  Check((d.seen() & (1 << (want - 1))) != 0,
        "%s: the clause bitmap is %#x and bit %d is clear", name, d.seen(),
        want - 1);
  delete d.m;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  {
    Dut d;
    RunClean(d);
    delete d.m;
  }

  RunClause("a request with no cycle open", kNoCycle, [](Dut &d) {
    d.boundary();
    d.cycle(false, true, 0x40, 0x18000100, Poison(1));
    d.loose_request(true, 0x18000100, Poison(2));
  });

  RunClause("a request on a cycle that is not memory's", kNotMemory,
            [](Dut &d) {
              d.boundary();
              d.cycle(true, false, 017377776, 0x1F000000, Poison(3));
            });

  RunClause("a request in the direction the cycle does not name", kDirection,
            [](Dut &d) {
              d.boundary();
              d.cycle(false, true, 0x50, 0x18000140, Poison(4), 1, 1, true,
                      true);
            });

  RunClause("one cycle, two requests", kTwoReqs, [](Dut &d) {
    d.boundary();
    d.cycle(false, true, 0x60, 0x18000180, Poison(5), 2, 1);
  });

  RunClause("one request, two answers", kTwice, [](Dut &d) {
    d.boundary();
    d.cycle(false, true, 0x70, 0x180001C0, Poison(6), 1, 2);
  });

  // THE CLAUSE THAT REACHES PAST `cadr_machine`.  The AXI adapter is outside
  // the machine, so this module cannot see its address channels; what it can
  // see is that the adapter answered when nothing had asked, which is what an
  // adapter running a transaction of its own looks like from in here.  The
  // stimulus is the tail of `mutations/list.txt`'s
  // `the-read-is-issued-a-second-time`: a clean cycle, and then a second
  // answer after the request has gone.
  RunClause("an answer with no request standing", kLooseAns, [](Dut &d) {
    d.boundary();
    d.cycle(false, true, 0x78, 0x180001E0, Poison(7));
    d.m->mem_done = 1;
    d.tick();
    d.m->mem_done = 0;
    d.tick();
  });

  // WHAT THE INSTRUMENT IS FOR: the word a spurious write would have put into
  // memory, at the address it would have put it.  Asserted in full, because a
  // clause code alone would not have told anybody what happened on the board.
  {
    Dut d;
    d.reset();
    for (int i = 0; i < 7; ++i) d.boundary();
    d.m->vma = 0x261FC9F9u;
    d.m->md = 0x0A1FC941u;
    d.m->pc = 0x1234 & 0x3FFF;
    d.m->opc = 0x0ABC;
    d.cycle(false, true, 0103757, 0x1810FDF4, 0x261FC9F9u, 1, 1, true, true);
    Check(d.clause() == kDirection, "the record: clause %d", d.clause());
    Check(d.phys() == 0103757, "the record: physical %o, wanting %o",
          d.phys(), 0103757);
    Check(d.low(2) == 0x1810FDF4u, "the record: byte address %08x", d.low(2));
    Check(d.low(3) == 0x261FC9F9u,
          "the record: the word on the write-data lines reads %08x, wanting "
          "%08x --- this is the field that names the corruption",
          d.low(3), 0x261FC9F9u);
    Check(d.low(4) == 0x261FC9F9u, "the record: VMA %08x", d.low(4));
    Check(d.low(5) == 0x0A1FC941u, "the record: MD %08x", d.low(5));
    Check(d.low(6) == 7, "the record: microcycle %u, wanting 7", d.low(6));
    Check(((d.low(7) >> 16) & 0x3FFFu) == (0x1234u & 0x3FFFu),
          "the record: PC %o", (d.low(7) >> 16) & 0x3FFFu);
    Check((d.low(7) & 0x3FFFu) == 0x0ABCu, "the record: OPC %o",
          d.low(7) & 0x3FFFu);
    delete d.m;
  }

  // A REQUEST THAT FALLS WITH NO ANSWER IS NOT A FAULT AND MUST NOT TAKE THE
  // LATCH.  This is the whole board before `ps7_post_config`, and an
  // instrument that spent its one record on it would have destroyed its own
  // evidence.
  {
    // THREE WELL-FORMED CYCLES, one request each, none of them answered ---
    // which is the whole board before `ps7_post_config`.  One request per
    // cycle on purpose: three inside one cycle would itself be the TWO_REQS
    // fault and would take the latch for a reason that has nothing to do with
    // the stall.  The first draft of this case did exactly that and the check
    // said so, which is why the stimulus is spelled out here rather than
    // reusing `cycle()`.
    Dut d;
    d.reset();
    for (int i = 0; i < 3; ++i) {
      d.boundary();
      d.m->cycle = 1;
      d.m->cycle_write = 0;
      d.m->cycle_memory = 1;
      d.m->cycle_phys = 0x80 + i;
      d.tick();
      d.m->mem_req = 1;
      d.m->mem_addr = 0x18000200 + 4 * i;
      d.tick();
      d.tick();
      d.m->mem_req = 0;
      d.tick();
      d.m->cycle = 0;
      d.tick();
    }
    Check(d.stalled() == 3, "%ld unanswered requests counted, wanting 3",
          d.stalled());
    Check(d.faults() == 0,
          "a port that answers nothing produced %ld faults", d.faults());
    Check(!d.valid(), "an unanswered request took the first-fault latch");
    Check(d.clause() == kNone, "the latch holds clause %d", d.clause());
    delete d.m;
  }

  // THE LATCH HOLDS THE FIRST AND NOT THE LAST.
  {
    Dut d;
    d.reset();
    d.boundary();
    d.cycle(true, false, 017377776, 0x1F000000, Poison(9));   // NOT_MEMORY
    d.boundary();
    d.loose_request(true, 0x18000300, Poison(10));             // NO_CYCLE
    Check(d.clause() == kNotMemory,
          "the latch holds clause %d, wanting the first, %d", d.clause(),
          kNotMemory);
    Check(d.faults() == 2, "%ld faults counted, wanting 2", d.faults());
    Check(d.low(6) == 1, "the record names microcycle %u, wanting the first "
          "fault's, 1", d.low(6));
    Check(d.seen() == ((1 << (kNotMemory - 1)) | (1 << (kNoCycle - 1))),
          "the clause bitmap is %#x", d.seen());
    delete d.m;
  }

  // THE COUNT SATURATES AND THE RECORD DOES NOT MOVE.  A counter that wrapped
  // back to a small number is the false negative this module exists to rule
  // out; CLAUDE.md's `-XBUS.RQ` entry is the same fact one module along.
  {
    Dut d;
    d.reset();
    d.boundary();
    d.loose_request(true, 0x18000400, Poison(11));
    const uint32_t first = d.low(2);
    for (int i = 0; i < 33000; ++i) d.loose_request(true, 0x18000500, 0);
    Check(d.faults() == 32767, "the fault count reads %ld, wanting 32,767 "
          "saturated", d.faults());
    Check(d.low(2) == first,
          "the record moved: byte address %08x, wanting the first fault's %08x",
          d.low(2), first);
    delete d.m;
  }

  // THE MARKER, ON EVERY WORD, IN BOTH STATES OF THE INSTRUMENT.
  {
    Dut d;
    d.reset();
    for (int s = 0; s < 8; ++s) {
      const uint64_t w = d.word(s);
      Check(d.mark(s) == kMark,
            "word %d of a clean instrument reads %012" PRIx64 ": its top "
            "sixteen bits are %04x and not %04x, so a reading of nothing and "
            "a reading of no instrument are not told apart", s, w, d.mark(s),
            kMark);
      Check(w != 0 && w != 0xFFFFFFFFFFFFull,
            "word %d reads %012" PRIx64 ", which is a value an undriven or "
            "saturated path can also produce", s, w);
      Check((w >> 32) != 0xA5A5u,
            "word %d collides with the readout window's own answer for a "
            "selector the fabric does not map", s);
    }
    d.boundary();
    d.loose_request(true, 0x18000600, Poison(12));
    for (int s = 0; s < 8; ++s) {
      Check(d.mark(s) == kMark, "word %d of a faulted instrument reads mark "
            "%04x", s, d.mark(s));
    }
    delete d.m;
  }

  if (fails) {
    std::fprintf(stderr, "bus audit unit: %d failure%s\n", fails,
                 fails == 1 ? "" : "s");
    return 1;
  }
  std::printf("bus audit unit: ok --- clean traffic is silent, every clause "
              "fires, the record names the word and the address, an "
              "unanswered request does not take the latch, the count "
              "saturates, and every word says who wrote it\n");
  return 0;
}
