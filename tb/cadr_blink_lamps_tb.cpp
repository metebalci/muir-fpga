// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The two lamps `--no-blinking-leds` changes: the clock lamp and the
// microcycle lamp, blinking by default and steady when the console says so.
//
// The DUT is `tb/cadr_blink_lamps_harness.sv`, which puts
// `rtl/plumbing/cadr_lamp_clock.sv` and `rtl/plumbing/cadr_lamp_microcycle.sv`
// side by side at their own default parameters --- the parameters the boards
// build them with --- and gives them one setting, as the console's one word
// does on the board.
//
// **WHAT IS HELD HERE.**
//
//   - The clock lamp, blinking, is the blink whatever the lock says; steady, it
//     is the lock whatever the blink says, and it follows the lock with NO
//     clock edge in between.  That last is the property the module exists for:
//     a lamp that sampled the lock on a clock would stay lit when the clock
//     stopped, which is the one case the steady lamp is for.
//   - The microcycle lamp, blinking, is bit 19 of a count of RETIRED
//     microcycles and not of ticks, and it freezes, lit or dark, when they
//     stop.
//   - Steady, it is lit on every tick while microcycles retire, including
//     across the longest stall a running machine has, for more than twice the
//     hold; dark before the first one; and lit for EXACTLY `kHoldT` ticks
//     after the last one, counted from the tick that retired it.
//   - The hold counts in both modes, so a mode changed at run time shows the
//     right state at once.
//   - A reset puts out both the hold and the count.
//
// **WHAT IS NOT HELD HERE**: which signals the boards wire to the inputs and
// which pins the outputs drive.  That is `boards/arty-z7-20/cadr_arty.sv`'s and
// `boards/cora-z7-07s/cadr_cora.sv`'s, and their lint.  Whether the console's
// word moves the setting is `build/console.pass`'s.
//
// Build and run:
//     verilator --cc --exe --build -Wall -Mdir build/obj_blink_lamps \
//         --top-module cadr_blink_lamps_harness \
//         rtl/plumbing/cadr_lamp_clock.sv rtl/plumbing/cadr_lamp_microcycle.sv \
//         tb/cadr_blink_lamps_harness.sv "$PWD"/tb/cadr_blink_lamps_tb.cpp
//     build/obj_blink_lamps/Vcadr_blink_lamps_harness

#include <cstdint>
#include <cstdio>
#include "Vcadr_blink_lamps_harness.h"
#include "cadr_tick.h"
#include "verilated.h"

namespace {

// `cadr_lamp_microcycle.sv`'s two defaults.  The boards build the module with
// no override, so these are the board's numbers and not a scaled-down copy of
// them: a check at a smaller hold would hold a lamp nobody builds.
constexpr long kHoldT = 1L << 22;   // 41.9 ms at the 10 ns tick
constexpr int kBlinkBit = 19;

// A microcycle at normal speed, in ticks: the read tap and the restart, each
// rounded up to MIT's grid.  15 at the 10 ns grid.
constexpr long kMicrocycleT = GridTicks(85) + GridTicks(60);

// The longest stall a running machine has between two microcycles, in ticks,
// taken with room: TWICE the debug cable's deadline, which is thirteen
// periods of the NXM oscillator after its first rise, 1,105 ticks at the 10 ns
// grid.  The real stall adds up to a period and a half before that rise and
// the arbitration before the transfer, which the factor of two covers.
constexpr long kLongestStall = 2 * GridTicks(13 * 850);

int bad = 0;
long tick = 0;

void Fail(const char *what, long got, long want) {
  // A lamp checked on every tick fails on every tick once it is wrong, and
  // the first few say everything the rest would.
  if (bad < 12)
    std::fprintf(stderr, "FAIL: %s is %ld, wanted %ld (tick %ld)\n", what, got, want, tick);
  ++bad;
}

struct Lamps {
  Vcadr_blink_lamps_harness *d;

  Lamps() : d(new Vcadr_blink_lamps_harness) {
    d->clk = 0;
    d->rst = 1;
    d->steady = 0;
    d->locked = 1;
    d->tick_blink = 0;
    d->retired = 0;
    d->eval();
    Step(8);
    d->rst = 0;
    Step(2);
  }
  ~Lamps() { d->final(); delete d; }

  void Step(long n) {
    for (long k = 0; k < n; ++k) {
      d->clk = 1;
      d->eval();
      d->clk = 0;
      d->eval();
      ++tick;
    }
  }
  // One tick, retiring a microcycle at its edge or not.
  void Tick(bool retire) {
    d->retired = retire ? 1 : 0;
    Step(1);
    d->retired = 0;
  }
  void Reset() {
    d->rst = 1;
    Step(2);
    d->rst = 0;
  }
  int Cycle() const { return d->cycle_lit; }
  int Clock() const { return d->clock_lit; }
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Lamps l;

  // --- 1.  OUT OF RESET, BLINKING: the microcycle lamp is the count's bit and
  // the count is zero.
  if (l.Cycle()) Fail("the microcycle lamp out of reset", l.Cycle(), 0);

  // --- 2.  THE CLOCK LAMP, BLINKING, IS THE BLINK WHATEVER THE LOCK SAYS.
  // No clock edge: the module has none.
  for (int locked = 0; locked < 2; ++locked) {
    for (int blink = 0; blink < 2; ++blink) {
      l.d->locked = locked;
      l.d->tick_blink = blink;
      l.d->eval();
      if (l.Clock() != blink) Fail("the clock lamp, blinking", l.Clock(), blink);
    }
  }

  // --- 3.  STEADY, IT IS THE LOCK WHATEVER THE BLINK SAYS, AND IT FOLLOWS THE
  // LOCK WITH NO CLOCK EDGE.
  //
  // This is the property the lamp is for.  A clock that has stopped cannot
  // clock a register that would turn a lamp off, so every change of the lock
  // here is made and read back between edges: a lamp that sampled the lock
  // would still show the value it last sampled.
  l.d->steady = 1;
  for (int blink = 0; blink < 2; ++blink) {
    l.d->tick_blink = blink;
    for (int locked : {1, 0, 1, 0}) {
      l.d->locked = locked;
      l.d->eval();
      if (l.Clock() != locked) Fail("the clock lamp, steady, read with no edge", l.Clock(), locked);
    }
  }
  // And with the blink moving underneath it on every tick, lit throughout.
  l.d->locked = 1;
  for (long k = 0; k < 64; ++k) {
    l.d->tick_blink = static_cast<uint8_t>(k & 1);
    l.Step(1);
    if (!l.Clock()) Fail("the clock lamp, steady and locked, with the blink moving", l.Clock(), 1);
  }
  // And back to blinking: the blink again, lock or no lock.
  l.d->steady = 0;
  l.d->locked = 0;
  l.d->tick_blink = 1;
  l.d->eval();
  if (!l.Clock()) Fail("the clock lamp back to blinking, unlocked", l.Clock(), 1);
  l.d->locked = 1;
  l.d->tick_blink = 0;
  l.d->eval();
  if (l.Clock()) Fail("the clock lamp back to blinking, locked", l.Clock(), 0);

  // --- 4.  BLINKING, THE MICROCYCLE LAMP COUNTS MICROCYCLES AND NOT TICKS.
  //
  // One microcycle every third tick, so a lamp counting ticks toggles three
  // times too early.  Every tick is compared, through the rise at 2^19 and the
  // fall at 2^20, and the two are counted so that a lamp which never moved
  // cannot pass by being compared against a count that never got there.
  l.Reset();
  {
    long events = 0;
    int toggles = 0;
    int was = l.Cycle();
    const long want_events = (2L << kBlinkBit) + 3;
    for (long k = 0; events < want_events; ++k) {
      const bool retire = (k % 3) == 2;
      l.Tick(retire);
      if (retire) ++events;
      const int want = static_cast<int>((events >> kBlinkBit) & 1);
      if (l.Cycle() != want) Fail("the microcycle lamp, blinking", l.Cycle(), want);
      if (l.Cycle() != was) ++toggles;
      was = l.Cycle();
    }
    if (toggles != 2) Fail("the times the microcycle lamp changed over 2^20 microcycles", toggles, 2);
  }

  // --- 5.  AND IT FREEZES WHEN THE MACHINE STOPS.
  //
  // Stopped with the bit set, for twice the hold: a blink is a level that
  // stands still, and it must not be the hold going out.
  l.Reset();
  for (long k = 0; k < (1L << kBlinkBit) + 5; ++k) l.Tick(true);
  if (!l.Cycle()) Fail("the microcycle lamp at 2^19 + 5 microcycles", l.Cycle(), 1);
  for (long k = 0; k < 2 * kHoldT; ++k) {
    l.Tick(false);
    if (!l.Cycle()) {
      Fail("the blinking lamp of a stopped machine, which should stand still lit", l.Cycle(), 1);
      break;
    }
  }

  // --- 6.  STEADY, IT IS DARK UNTIL THE MACHINE RETIRES SOMETHING, AND THEN
  // LIT ON EVERY TICK WHILE IT RUNS.
  //
  // A microcycle every `kMicrocycleT` ticks, the normal speed, with the
  // longest stall a running machine has put in every so often, for more than
  // twice the hold:
  // a hold that is not re-armed by every microcycle goes out once and is
  // caught here.
  l.Reset();
  l.d->steady = 1;
  l.Step(1000);
  if (l.Cycle()) Fail("the steady lamp of a machine that has retired nothing", l.Cycle(), 0);
  {
    long ran = 0;
    bool started = false;
    long next_stall = 50000;
    while (ran < 2 * kHoldT + 100000) {
      long gap = kMicrocycleT;
      if (ran >= next_stall) {
        gap = kLongestStall;
        next_stall += 250000;
      }
      for (long g = 0; g < gap; ++g) {
        l.Tick(g == gap - 1);
        if (g == gap - 1) started = true;
        if (started && !l.Cycle()) {
          Fail("the steady lamp of a running machine", l.Cycle(), 1);
          ran = 3 * kHoldT;
          break;
        }
      }
      ran += gap;
    }
  }

  // --- 7.  AND LIT FOR EXACTLY THE HOLD AFTER THE LAST ONE.
  //
  // The tick that retires the last microcycle is the first tick lit, and the
  // lamp is lit on `kHoldT` ticks in all.  Counted, not bounded: a hold a tick
  // long or a tick short is a different lamp.
  {
    l.Tick(true);
    long lit = 1;
    if (!l.Cycle()) Fail("the steady lamp on the tick that retired the last microcycle", l.Cycle(), 1);
    for (long k = 0; k < kHoldT + 1000; ++k) {
      l.Tick(false);
      if (l.Cycle()) ++lit;
    }
    if (lit != kHoldT) Fail("the ticks the steady lamp stays lit after the last microcycle", lit, kHoldT);
    if (l.Cycle()) Fail("the steady lamp of a machine long stopped", l.Cycle(), 0);
  }

  // --- 8.  THE HOLD COUNTS WHILE THE LAMP BLINKS, SO A MODE CHANGED AT RUN
  // TIME SHOWS THE RIGHT STATE AT ONCE.
  //
  // Running and blinking, then stopped, then made steady half way through the
  // hold: still lit, with no microcycle since, and out when the hold that
  // started at the last microcycle is over.
  l.d->steady = 0;
  for (long k = 0; k < 290; ++k) l.Tick((k % 29) == 28);
  {
    long lit = 1;   // the tick that retired it, spent blinking
    for (long k = 0; k < kHoldT / 2; ++k) l.Tick(false);
    lit += kHoldT / 2;
    l.d->steady = 1;
    l.d->eval();
    if (!l.Cycle())
      Fail("the lamp made steady half a hold after the machine stopped", l.Cycle(), 1);
    long more = 0;
    for (long k = 0; k < kHoldT; ++k) {
      l.Tick(false);
      if (l.Cycle()) ++more;
    }
    if (lit + more != kHoldT)
      Fail("the ticks lit from the last microcycle, across the change of mode", lit + more, kHoldT);
  }
  // And made steady long after the machine stopped: dark at once.
  l.d->steady = 0;
  for (long k = 0; k < 290; ++k) l.Tick((k % 29) == 28);
  for (long k = 0; k < kHoldT + 10; ++k) l.Tick(false);
  l.d->steady = 1;
  l.d->eval();
  if (l.Cycle()) Fail("the lamp made steady long after the machine stopped", l.Cycle(), 0);

  // --- 9.  A RESET PUTS OUT THE HOLD AND THE COUNT.
  //
  // A machine held in reset retires nothing, so neither lamp may go on saying
  // it did.
  l.Tick(true);
  if (!l.Cycle()) Fail("the steady lamp at a microcycle, before the reset", l.Cycle(), 1);
  l.Reset();
  if (l.Cycle()) Fail("the steady lamp just after a reset", l.Cycle(), 0);
  for (long k = 0; k < kHoldT + 10; ++k) {
    l.Tick(false);
    if (l.Cycle()) {
      Fail("the steady lamp of a machine that has retired nothing since its reset", l.Cycle(), 0);
      break;
    }
  }
  l.d->steady = 0;
  for (long k = 0; k < (1L << kBlinkBit); ++k) l.Tick(true);
  if (!l.Cycle()) Fail("the blinking lamp at 2^19 microcycles", l.Cycle(), 1);
  l.Reset();
  if (l.Cycle()) Fail("the blinking lamp after a reset", l.Cycle(), 0);

  if (bad) {
    std::fprintf(stderr, "FAIL: %d checks failed\n", bad);
    return 1;
  }
  std::printf(
      "ok: the clock and microcycle lamps, blinking and steady, over %ld ticks.\n"
      "    The clock lamp blinks whatever the lock says and, steady, is the MMCM's lock\n"
      "    whatever the blink says, following it with no clock edge.  The microcycle lamp\n"
      "    blinks on bit %d of a count of microcycles, not ticks, and freezes when they\n"
      "    stop; steady, it is dark until one retires, lit on every tick of a machine\n"
      "    running with stalls of %ld ticks for over twice the hold, and lit for exactly\n"
      "    %ld ticks after the last microcycle.  The hold counts in both modes, so a\n"
      "    change of mode shows the right state at once, and a reset puts out both.\n"
      "    Which nets the boards wire to it is their lint's, and not held here.\n",
      tick, kBlinkBit, kLongestStall, kHoldT);
  return 0;
}
