// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A CADR DEBUGGING A CADR OVER ONE PMOD CABLE.
//
// `build/dbg_pmod.pass` holds the carrier to its one property: what goes in
// one end comes out the other, unchanged, whole and in bounded time.  This
// holds what the carrier is FOR.  Board A's own machine runs the four
// registers CC writes --- `0o766100` to `0o766114`, the DBGOUT page in
// `rtl/machine/cadr_busint_regs.sv` --- and board B answers them on its own
// Unibus through `rtl/machine/cadr_dbgin.sv`.  Eight wires between them, and
// this file is the wire.
//
// **NO muir REFERENCE EXISTS FOR THE CONNECTOR**, and there could not be
// one: muir has the cable and no pins, and no notion of a board that is a
// debugger at one moment and a debuggee at the next.  What every module
// UNDER the connector is held to is muir, in `build/busint_regs.pass`,
// `build/dbgin.pass` and `build/unibus.pass`; what is held here is the
// property those three cannot see, which is that the two ends make one cable.
//
// WHAT IS CHECKED, and each of them is a thing that can go wrong on a bench:
//
//   1. **No pad is ever driven from both ends.**  Asserted on every tick of
//      every phase, including the two moments it could happen --- two boards
//      with nothing set, and a second board told to connect while the first
//      already has.  A cable with one connector and two roles is safe only if
//      something enforces that the roles differ, and this is that something
//      being watched rather than argued for.
//   2. **A register read comes back with the OTHER machine's word.**  CC's
//      own sequence: the modifier, the address, the status, and a cycle.  The
//      word compared is the one board B's `cadr_spy_registers.sv` drove and
//      it is injective in the register number, so a road reading the wrong
//      register says so.
//   3. **The status read's high byte is all ones.**  `-DB READ STATUS`
//      enables an octal driver onto `DBD<7:0>` and nothing drives the byte
//      above it; the cable's pull-ups carry it, which is
//      `Rtl::try_debug_request`'s `0xff00 | status`.  This is the one place
//      in the transport where a byte nobody drives has to arrive as ones, and
//      the low byte beside it says the resolution is per byte and not per
//      cable.
//   4. **A cable with a real delay, and a beat corrupted on the wire.**  The
//      frame is refused, the levels stand, and the next frame carries them:
//      a bad cable costs a frame and never a word.
//   5. **An unplugged cable answers instead of hanging.**  Pull it under a
//      standing request and the debugger's own page answers at once with all
//      ones, which is what an open connector reads as.
//   6. **A role cannot change under a cycle**, at either end.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vcadr_dbg_cable_harness.h"
#include "verilated.h"

namespace {

// `busint::debug_register`: the four registers CC writes, as Unibus
// addresses on the DEBUGGER's own bus.
const unsigned kCycle = 0766100, kStatus = 0766104, kModifier = 0766110,
               kAddress = 0766114;

// `spy::BASE` and the registers CC reads through a debug CYCLE: a Unibus
// address on the DEBUGGEE.  Bit 0 of a debug address is not sent over the
// cable and the latch holds `UAO<16:1>`, so what CC writes into the address
// register is the address shifted right one.
const unsigned kSpyBase = 0766000;

// `Machine::debug_status`'s byte, from outside: both halves distinct and
// neither `0x00` nor `0xFF`, so that a check comparing it cannot pass a
// driver stuck either way.
const unsigned kErrStatus = 0245;

// The wiring, as the console's word 14 sets it and as
// `rtl/plumbing/cadr_dbg_cable.sv` names it.
const int kAuto = 0, kStraight = 1, kCrossover = 2;

// And what came of it: one value a meaning, the connector's own eight.
const int kWsAutoIdle = 0, kWsStraight = 1, kWsCrossover = 2, kWsListening = 3,
          kWsStFound = 4, kWsCrFound = 5, kWsStAssumed = 6, kWsCrAssumed = 7;

// The two intervals the detection is made of, from the harness's own
// parameters: TWENTY-FOUR beats of six and a gap of eighteen is a frame of
// 162, the listen is a frame and the loss interval, and a probe is the loss
// interval.  `LOSS_T` is 512 here and 1024 on a board.
//
// **TWENTY-FOUR BEATS AND NOT EIGHT, BECAUSE A GROUP CARRIES ONE DATA LINE.**
// The Pmod's pins are coupled pairs and this link puts one signal on each,
// with the partner of each driven low as a guard; twenty-one payload bits, a
// two-bit marker and a parity bit over one line is twenty-four beats.
const long kFrameT = 24 * 6 + 18;
const long kLossT = 512;
const long kDetectT = kFrameT + kLossT;
const long kActT = 2 * kFrameT;
const long kProbeT = kActT + 6 * kFrameT;
const long kRelistenT = kActT + kFrameT;

// **THE DEADLINE THE WHOLE TRANSPORT IS AGAINST**, and it is a tick count
// because the thing that counts it is in the fabric.
// `rtl/machine/cadr_busint_xbus.sv` runs the REQTIM oscillator at
// `425 / TICK_NS` ticks a half period and takes the PROM's SECOND table for a
// debug cycle, thirteen whole periods --- so a debugger gives up 13 * 170 =
// 2,210 ticks after the gated oscillator's first rise, which is
// `busint::DEBUG_TIMEOUT_NS`, 11.05 microseconds on MIT's 5 ns grid and 22.1
// of real time at this board's 10 ns tick.
//
// What this check holds the round trip to is HALF of it.  A cycle over the
// cable is a request frame, the far machine's own bus cycle and an answer
// frame, and a bound with a factor of two in hand is a bound that says
// something when the frame's length next moves; 2,210 would pass a transport
// three times slower than this one.
const long kDebugTimeoutT = 2210;
const long kRoundTripBound = kDebugTimeoutT / 2;

int failures = 0;
const int kMaxFailures = 20;

int Fail(const char *what, unsigned long got, unsigned long want) {
  if (failures < kMaxFailures)
    std::fprintf(stderr, "FAIL: %s is 0x%lx (%lu), wanting 0x%lx (%lu)\n", what, got, got, want,
                 want);
  return 1;
}

// The processor's sixteen-way diagnostic mux on board B, answered from
// outside and injective in the register number.
unsigned SpyWord(unsigned eadr) { return (0x9E00u ^ (eadr * 0x1111u)) | 0x0007u; }

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_dbg_cable_harness;

  long tick = 0;
  // The cable itself.  `join` is whether the two connectors are plugged
  // together; `delay` is how many ticks a wire takes; `corrupt` flips one
  // data line for one tick when it counts down to zero.
  //
  // **AND `crossed` IS THE RIBBON MADE THE WRONG WAY ROUND.**  A Pmod header
  // is two rows, pins 1 to 6 and 7 to 12, so a cable whose connector was
  // pressed on the other way up joins each board's pins 1 to 4 to the other's
  // 7 to 10, in order --- which is index `p` to index `p ^ 4` here.  Measured
  // on two boards, on a manufactured extension cable that could not be
  // re-crimped, which is why the fabric has a setting for it.
  int join = 1;
  int crossed = 0;
  int delay = 0;
  long corrupt = -1;
  // Which pin the corruption lands on.  Index 2 is the forward group's one
  // data line; index 1 is the guard beside its strobe.
  int corrupt_pin = 2;
  long contention = 0;   // pads driven from both ends, ever
  long a_drove = 0, b_drove = 0;
  // And a pad driven outside the group the board says it is on, ever.
  long pin_group_bad = 0, pin_group_ticks = 0;
  // **AND THE GUARDS.**  Each group of four is two coupled pairs of the Pmod
  // header, and the link puts one signal on each pair: the strobe on header
  // pin 1 (index 0) and the data line on pin 3 (index 2), with pins 2 and 4 ---
  // indices 1 and 3 --- DRIVEN LOW beside them, and the same on the return
  // row.  Three things follow and all three are asserted on every tick of
  // every phase: a group is enabled whole or not at all, a guard that is
  // enabled is at zero, and a board listening to a group drives no pin of it,
  // guard included.  A floating guard is not a guard --- it is a capacitor the
  // neighbor charges --- so "not driven" is a failure here and not a
  // tidiness.
  const int kGuardPins[4] = {1, 3, 5, 7};
  long guard_part_group = 0, guard_high = 0, guard_low_ticks = 0;

  // A wire is a little shift register, one a pad, so a delay is a real delay
  // and not a relabeling.  Sixteen pads, eight a board, and the two
  // directions of the join are separate wires.
  const int kMaxDelay = 8;
  // Ticks a released wire holds its last level before the pull-downs have it.
  // A weak pull-down at either end against a ribbon's capacitance is hundreds
  // of nanoseconds on a bench; forty ticks is four hundred here, and what the
  // number has to be is longer than the two ticks a synchronizer needs to see
  // the edge it makes.
  const int kDecayT = 40;
  unsigned char wire_ab[8][kMaxDelay + 1] = {{0}};
  unsigned char wire_ba[8][kMaxDelay + 1] = {{0}};
  unsigned char held_ab[8] = {0}, held_ba[8] = {0};
  int quiet_ab[8], quiet_ba[8];
  for (int k = 0; k < 8; ++k) {
    quiet_ab[k] = kDecayT;
    quiet_ba[k] = kDecayT;
  }

  // Which of the far board's eight pins this board's pin `p` is joined to.
  // The mapping is its own inverse either way round, so one function serves
  // both directions.
  auto Far = [&](int p) { return crossed ? (p ^ 4) : p; };

  auto Tick = [&]() {
    dut->clk_a = 0;
    dut->clk_b = 0;
    dut->eval();

    // **THE CABLE, AND THE ASSERTION THAT MAKES IT ONE CABLE.**  Eight wires
    // with two ends each, or sixteen pins with nobody on the other side.  A
    // wire driven from both ends is not modeled --- it is counted, and a run
    // that counts one has found the thing this connector's whole design is
    // about.  It is a WIRE and not a pad index: with a mirrored ribbon A's pin
    // `w` and B's pin `w ^ 4` are the two ends of one of them.
    //
    // **AND A WIRE NOBODY DRIVES DOES NOT SNAP TO ZERO.**  It decays through
    // the pull-downs at either end and the ribbon's own capacitance, which is
    // tens of nanoseconds on a real one, so a driver letting go leaves the
    // last level standing for a few ticks and then a transition.  That detail
    // is not a decoration: it is the seed of the fault two boards were found
    // in, and with a wire that snapped to zero the fabric this replaces passed
    // the bench's own sequence in simulation at every phase.
    for (int w = 0; w < 8; ++w) {
      const int ap = w, bp = Far(w);
      const bool a_on = ((dut->a_pin_t >> ap) & 1) == 0;
      const bool b_on = ((dut->b_pin_t >> bp) & 1) == 0;
      if (a_on) ++a_drove;
      if (b_on) ++b_drove;
      if (join && a_on && b_on) ++contention;
      unsigned char lvl = 0;
      bool driven = false;
      if (a_on) {
        lvl = (unsigned char)((dut->a_pin_o >> ap) & 1);
        driven = true;
      } else if (join && b_on) {
        lvl = (unsigned char)((dut->b_pin_o >> bp) & 1);
        driven = true;
      }
      if (driven) {
        held_ab[w] = lvl;
        quiet_ab[w] = 0;
      } else if (quiet_ab[w] < kDecayT) {
        lvl = held_ab[w];
        ++quiet_ab[w];
      } else {
        lvl = 0;
      }
      // **FIVE TICKS AND NOT ONE, AND THE COUNTER IS WHAT SAID SO.**  A
      // receiver samples its data lines once a beat, six ticks apart, so a
      // line flipped for a single tick usually lands between two samples and
      // changes nothing --- this leg asserted only that the WORD still arrived,
      // which it would whether or not any beat was actually corrupted.  The
      // frames-refused counter said none ever was.  Five consecutive ticks
      // cover exactly one sampling instant and never two, so one bit of one
      // frame is wrong and the frame is refused on its parity.
      // **AND IT IS THE DATA LINE, INDEX 2, AND NOT INDEX 1.**  Index 1 is a
      // GUARD now: nothing reads it, so a flip there would be a stimulus that
      // could not fail, which is this project's own trap about a check written
      // to confirm.  The guard is corrupted too, in a leg of its own below,
      // and what that leg asserts is the opposite --- that nothing moves.
      if (corrupt >= 0 && corrupt <= 4 && w == corrupt_pin) lvl ^= 1;
      for (int k = kMaxDelay; k > 0; --k) wire_ab[w][k] = wire_ab[w][k - 1];
      wire_ab[w][0] = lvl;
      // With the connector unplugged the far end of every pin is this board's
      // own pad, which decays the same way.
      if (!join) {
        unsigned char bl = 0;
        bool bd = false;
        if (b_on) {
          bl = (unsigned char)((dut->b_pin_o >> bp) & 1);
          bd = true;
        }
        if (bd) {
          held_ba[w] = bl;
          quiet_ba[w] = 0;
        } else if (quiet_ba[w] < kDecayT) {
          bl = held_ba[w];
          ++quiet_ba[w];
        } else {
          bl = 0;
        }
        for (int k = kMaxDelay; k > 0; --k) wire_ba[w][k] = wire_ba[w][k - 1];
        wire_ba[w][0] = bl;
      }
    }
    if (corrupt >= 0) --corrupt;

    unsigned a_in = 0, b_in = 0;
    for (int w = 0; w < 8; ++w) {
      const int ap = w, bp = Far(w);
      const bool a_on = ((dut->a_pin_t >> ap) & 1) == 0;
      const bool b_on = ((dut->b_pin_t >> bp) & 1) == 0;
      // **A DRIVEN PAD READS BACK WHAT THIS BOARD PUT ON IT**, which is what
      // `assign ja[i] = ja_t[i] ? 1'bz : ja_o[i]` is on every board: the pin is
      // a wire and not a one-way street.  A model that fed a board only the FAR
      // end's value would hide a receiver left listening to its own echo, and
      // that receiver is exactly what the connector has to hold quiet while it
      // drives.
      a_in |= (unsigned)(a_on ? ((dut->a_pin_o >> ap) & 1) : wire_ab[w][delay]) << ap;
      b_in |= (unsigned)(b_on ? ((dut->b_pin_o >> bp) & 1)
                              : (join ? wire_ab[w][delay] : wire_ba[w][delay]))
              << bp;
    }
    dut->a_pin_i = (unsigned char)a_in;
    dut->b_pin_i = (unsigned char)b_in;

    // **AND THE PINS A BOARD DRIVES FOLLOW THE WIRING IT REPORTS, ON EVERY
    // TICK.**  The console's word says which of the eight pins this board is
    // on, so it is a claim about the pads and can be held to them --- a
    // debuggee and a crossover debugger on the high four, a straight debugger
    // on the low four, and a board still LISTENING on neither.  It is a subset
    // and not an equality, because a board never drives a group something else
    // is driving and may be holding off.
    //
    // This is what makes the wiring's own state machine checkable where the
    // cable cannot see it: a board with nothing plugged in still has to drive
    // the pins it says it is driving.
    for (int e = 0; e < 2; ++e) {
      const unsigned t = e ? dut->b_pin_t : dut->a_pin_t;
      const int eng = e ? dut->b_engaged : dut->a_engaged;
      const int st = e ? dut->b_wire_state : dut->a_wire_state;
      const unsigned lo = (~t) & 0x0Fu, hi = (~t) & 0xF0u;
      unsigned bad = 0;
      if (!eng)
        bad = lo;                         // a debuggee answers on the high four
      else if (st == kWsListening)
        bad = lo | hi;                    // and drives nothing while it listens
      else if (st == kWsStraight || st == kWsStFound || st == kWsStAssumed)
        bad = hi;
      else
        bad = lo;
      if (bad) {
        if (!pin_group_bad)
          std::fprintf(stderr,
                       "FAIL: board %c drives 0x%02x at tick %ld with wire_state %d and "
                       "engaged %d\n", e ? 'B' : 'A', (unsigned)((~t) & 0xFFu), tick, st, eng);
        ++pin_group_bad;
      }
      if (eng) ++pin_group_ticks;

      // **THE GUARDS, ON EVERY TICK.**  A group is four pads and they go out
      // together, so a group enabled at all must have all four of its pads
      // enabled --- a guard left out of the enable is a floating line beside a
      // switching one, which is the thing the pairs made this link avoid.  And
      // an enabled guard must be LOW: it is there to be quiet, and a guard
      // carrying anything is a second signal on the pair.
      const unsigned o = e ? dut->b_pin_o : dut->a_pin_o;
      for (int g = 0; g < 2; ++g) {
        const unsigned grp = ((~t) >> (4 * g)) & 0x0Fu;
        if (grp != 0x0u && grp != 0xFu) {
          if (!guard_part_group)
            std::fprintf(stderr,
                         "FAIL: board %c drives a part of a group, 0x%02x, at tick %ld\n",
                         e ? 'B' : 'A', (unsigned)((~t) & 0xFFu), tick);
          ++guard_part_group;
        }
      }
      for (int k = 0; k < 4; ++k) {
        const int gp = kGuardPins[k];
        if (((t >> gp) & 1u) != 0u) continue;   // not driven by this board
        if (((o >> gp) & 1u) != 0u) {
          if (!guard_high)
            std::fprintf(stderr,
                         "FAIL: board %c drives guard pin %d high at tick %ld\n",
                         e ? 'B' : 'A', gp, tick);
          ++guard_high;
        } else {
          ++guard_low_ticks;
        }
      }
    }

    dut->clk_a = 1;
    dut->clk_b = 1;
    dut->eval();
    dut->clk_a = 0;
    dut->clk_b = 0;
    dut->eval();
    ++tick;
  };

  auto Idle = [&](long n) {
    for (long k = 0; k < n; ++k) Tick();
  };

  // Both boards back to where the power leaves them, so that a leg can start
  // where a bench starts.  The CABLE is the testbench's own and is left alone:
  // a leg that wants it mirrored, or unplugged, says so itself.
  auto Reset = [&]() {
    dut->connect_a = 0;
    dut->connect_b = 0;
    dut->a_msyn = 0;
    dut->rst_a = 1;
    dut->rst_b = 1;
    Idle(8);
    dut->rst_a = 0;
    dut->rst_b = 0;
    Idle(8);
  };

  // Board A's own machine, running one register cycle: this is CC.
  struct Res {
    long ssyn = -1;
    unsigned word = 0;
    int answered = 0;
  };
  // The longest a debug cycle on board A's own Unibus has taken, over every
  // phase of the run: `-UB MSYN` to `-UB SSYN`, which is what the REQTIM
  // counter beside it would be counting on a board.
  long worst_ssyn = -1;
  auto Run = [&](unsigned uaddr, int write, unsigned wdata, long guard) {
    Res r;
    dut->a_addr = uaddr;
    dut->a_write = write;
    dut->a_wdata = wdata;
    dut->a_msyn = 1;
    for (long k = 0; k < guard; ++k) {
      Tick();
      if (dut->a_ssyn && r.ssyn < 0) {
        r.ssyn = k;
        r.answered = 1;
        r.word = dut->a_rdata;
        if (k > worst_ssyn) worst_ssyn = k;
        break;
      }
    }
    dut->a_msyn = 0;
    // The master holds the strobe a delay-line section past the answer ---
    // `busint::UNIBUS_STROBE_NS` --- and the levels stand past the lift,
    // which is what the far end's latches clock on.
    //
    // **AND THEN A HOLD THAT IS THE CARRIER'S AND NOT THE BUS'S.**  On MIT's
    // cable the lift is seen at the far end within nanoseconds; over a
    // serialized one it is a level like any other and has to cross a frame, so
    // a debugger that lifted and asked again inside that would have the far
    // end see one request where it made two.  It is written as frames rather
    // than as a constant because it IS frames: at eight beats twenty-four
    // ticks happened to be enough and at twenty-four beats it is not, which is
    // a stimulus that would have gone on passing while measuring less.
    // `tb/cadr_dbg_pmod_tb.cpp` sweeps the shortest hold that still latches
    // and reports it; this one only has to be longer than that.
    Idle(24 + 2 * kFrameT);
    return r;
  };

  // CC's own sequence: point the address register at a location on the
  // debuggee and run a cycle there.  `CC-READ` is exactly this.
  auto Peek = [&](unsigned uaddr, long guard) {
    Run(kAddress, 1, (uaddr >> 1) & 0xFFFFu, guard);
    return Run(kCycle, 0, 0, guard);
  };

  // **AND THE ADDRESS LATCH AT THE FAR END IS ONLY SIXTEEN BITS WIDE**, so
  // `UAO<17>` comes out of the MODIFIER register instead --- `busint`'s own
  // arrangement, and `cadr_dbgin.sv` keeps it.  Every address this check
  // reaches for is in the diagnostic block at `0o766000`, which has that bit
  // set, so a board whose modifier has just been reset can be spoken to and
  // will answer about the wrong half of its Unibus.  A leg that resets the
  // far board writes it again before it reads anything: measured the hard
  // way, with four register reads that crossed the cable perfectly and came
  // back from an address nothing answers.
  auto SetModifier = [&]() {
    Run(kModifier, 1, 1, 4000);
    Idle(8 * kFrameT);
  };

  dut->rst_a = 1;
  dut->rst_b = 1;
  dut->connect_a = 0;
  dut->connect_b = 0;
  // Both boards on `auto`, which is what the fabric comes up with and what a
  // card that says nothing leaves it at.
  dut->wire_a = kAuto;
  dut->wire_b = kAuto;
  dut->a_msyn = 0;
  dut->a_write = 0;
  dut->a_addr = 0;
  dut->a_wdata = 0;
  dut->b_win_req = 0;
  dut->b_win_wr = 0;
  dut->b_win_a = 0;
  dut->b_win_dbd = 0;
  dut->b_spy_rdata = 0;
  dut->b_err_status = kErrStatus;
  dut->a_pin_i = 0;
  dut->b_pin_i = 0;
  dut->eval();
  Idle(4);
  dut->rst_a = 0;
  dut->rst_b = 0;
  Idle(8);

  // ---- 1. two boards, nothing set: neither drives anything ----------------
  //
  // The state any two boards come up in with a cable between them.  A
  // debuggee drives nothing until it hears a debugger, so a pair with nobody
  // told to connect is a pair with sixteen quiet pads --- which is the only
  // arrangement in which a cable with one connector and two roles is safe.
  Idle(600);
  if (a_drove || b_drove)
    failures += Fail("pads driven by two boards that were told nothing",
                     (unsigned long)(a_drove + b_drove), 0);
  if (dut->a_engaged || dut->b_engaged)
    failures += Fail("a board that took the debugger's role without being told",
                     (unsigned)(dut->a_engaged || dut->b_engaged), 0);
  long quiet_ticks = tick;

  // ---- 2. A is told to connect, and the cable comes up --------------------
  //
  // **AND IT TAKES A LISTENING INTERVAL FIRST**, because `auto` is what a
  // board comes up with: it drives nothing at all for a frame and the loss
  // interval while it works out which way the ribbon was made, then assumes
  // straight and is proved right by the answer.  The idle here is the listen,
  // the first probe and the two frames the far end takes to answer it.
  dut->connect_a = 1;
  Idle(kDetectT + 6 * kFrameT);
  if (!dut->a_engaged) failures += Fail("A engaged after connect", 0, 1);
  if (dut->a_wire_state != kWsStFound)
    failures += Fail("the wiring A found on a straight cable", dut->a_wire_state, kWsStFound);
  if (dut->b_engaged) failures += Fail("B engaged without being told", 1, 0);
  if (!dut->a_live) failures += Fail("A hearing good frames from B", 0, 1);
  if (!dut->b_live) failures += Fail("B hearing good frames from A", 0, 1);
  if (!dut->b_foreign) failures += Fail("B seeing a debugger on the connector", 0, 1);
  if (dut->a_foreign) failures += Fail("A seeing a foreign debugger", 1, 0);
  if (!a_drove || !b_drove) failures += Fail("both ends driving once the cable is up", 0, 1);

  // ---- 3. CC's own sequence, over the cable -------------------------------
  //
  // The status first, because it is the one register whose word is a byte and
  // whose high byte is the open cable.
  long reads = 0, writes = 0;
  {
    const Res st = Run(kStatus, 0, 0, 4000);
    if (!st.answered) {
      failures += Fail("-UB SSYN reading the debuggee's status over the cable", 0, 1);
    } else {
      ++reads;
      if (st.word != (0xFF00u | kErrStatus))
        failures += Fail("the debuggee's status word, high byte off the cable's pull-ups",
                         st.word, 0xFF00u | kErrStatus);
    }
  }

  // The modifier register: bit 0 is address bit 17 and the other two are
  // `-DEBUGEE RESET` and `-DEBUG TIMEOUT INH`.  One, so the address bit is
  // set and neither of the other two is --- a stray one in bit 1 would reset
  // the machine at the far end, which is what the carrier's whole-frame
  // promise exists to prevent.
  {
    Run(kModifier, 1, 1, 4000);
    ++writes;
    Idle(400);
    if (dut->b_modifier != 1) failures += Fail("the modifier register at the far end",
                                              dut->b_modifier, 1);
    if (dut->b_debuggee_reset) failures += Fail("-DEBUGEE RESET after a modifier of one", 1, 0);
  }

  // And now the registers themselves: all sixteen of the debuggee's
  // diagnostic block, read through a cycle on ITS Unibus.
  long peeks = 0;
  for (unsigned e = 0; e < 16 && failures < kMaxFailures; ++e) {
    const unsigned uaddr = kSpyBase + 2 * e;
    dut->b_spy_rdata = SpyWord(e);
    const Res r = Peek(uaddr, 8000);
    writes += 1;
    if (!r.answered) {
      failures += Fail("-UB SSYN on a debug cycle at the debuggee's diagnostic block", 0, 1);
      continue;
    }
    ++reads;
    ++peeks;
    // The latch at the far end is read AFTER the cycle that used it: it
    // clocks on the trailing edge of its own strobe, which is a frame behind
    // the master's lift, and the cycle that follows is what proves it landed
    // in time --- the carrier delivers levels in the order they were put on.
    if (dut->b_address != ((uaddr >> 1) & 0xFFFFu))
      failures += Fail("the address latch at the far end", dut->b_address,
                       (uaddr >> 1) & 0xFFFFu);
    if (r.word != SpyWord(e))
      failures += Fail("the word the other machine's register gave", r.word, SpyWord(e));
  }

  // ---- 3a. THE FRAMES, COUNTED ------------------------------------------
  //
  // **THE PINS OF A PMOD ROW ARE ROUTED AS COUPLED PAIRS AND THIS LINK DRIVES
  // ALL FOUR SINGLE-ENDED**, so an edge on one line can couple into the strobe
  // beside it and misalign the frame it lands in.  A misaligned frame moves
  // nothing and the next one carries the levels again, so what that costs is
  // refused frames --- and how often is a number nobody has.  The two counters
  // are the instrument, and this is the control for them: over a settled
  // session on a clean cable, frames arrive and NOT ONE is refused.
  //
  // The window has no role change in it on purpose.  A board that has just
  // started driving joins the far end's frame part way through, so the frame
  // it lands in fails its marker --- which is the carrier working and not a
  // cable fault, and a check that counted those would be measuring its own
  // stimulus.
  long clean_heard = 0;
  {
    const unsigned a0 = dut->a_frames, b0 = dut->b_frames;
    Idle(40 * kFrameT);
    const unsigned a1 = dut->a_frames, b1 = dut->b_frames;
    const unsigned a_heard = (a1 >> 8) - (a0 >> 8), b_heard = (b1 >> 8) - (b0 >> 8);
    const unsigned a_bad = (a1 & 0xFFu) - (a0 & 0xFFu), b_bad = (b1 & 0xFFu) - (b0 & 0xFFu);
    if (a_bad || b_bad)
      failures += Fail("frames refused over a settled cable with nothing wrong with it",
                       a_bad + b_bad, 0);
    if (a_heard < 20 || b_heard < 20)
      failures += Fail("frames heard over a settled cable", a_heard < b_heard ? a_heard : b_heard,
                       20);
    else
      clean_heard = a_heard + b_heard;
  }

  // ---- 4. a cable with a delay in it, and a beat flipped on the wire ------
  //
  // Three ticks of wire either way is thirty nanoseconds on this board, which
  // is a long Pmod ribbon and then some; the corruption is the forward group's
  // one data line inverted for five ticks, in the middle of a frame.  Neither
  // may change a word: the frame that carries the bad beat fails its parity
  // and moves nothing, and the next one --- a frame later --- carries the same
  // levels.
  //
  // **AND THEN THE SAME FAULT ON A GUARD PIN, WHICH MUST COST NOTHING.**  That
  // is the whole of what one signal per pair buys, stated as a check: a pin
  // whose only job is to sit at zero beside a signal has nobody reading it, so
  // a fault on it moves neither the word nor the refusal count.  It is the
  // opposite assertion from the one above and the two together say the pin
  // roles are what this file believes they are.
  delay = 3;
  Idle(400);
  long delayed = 0, corrupted = 0;
  for (unsigned e = 0; e < 4 && failures < kMaxFailures; ++e) {
    dut->b_spy_rdata = SpyWord(e);
    const Res r = Peek(kSpyBase + 2 * e, 8000);
    if (!r.answered || r.word != SpyWord(e))
      failures += Fail("a debug cycle over a cable with a delay in it", r.word, SpyWord(e));
    else
      ++delayed;
  }
  const unsigned bad_before = dut->b_frames & 0xFFu;
  for (unsigned e = 4; e < 8 && failures < kMaxFailures; ++e) {
    dut->b_spy_rdata = SpyWord(e);
    corrupt = 40 + 7 * (long)e;   // inside the request's own frames
    const Res r = Peek(kSpyBase + 2 * e, 8000);
    corrupt = -1;
    if (!r.answered || r.word != SpyWord(e))
      failures += Fail("a debug cycle over a cable with a beat flipped in it", r.word, SpyWord(e));
    else
      ++corrupted;
  }
  // And each of those was COUNTED as refused at the far end, which is what
  // makes the counter an instrument rather than a number that is always zero:
  // a check whose refusals never move could not tell a counter from a
  // constant.
  long counted_bad = (long)(((dut->b_frames & 0xFFu) - bad_before) & 0xFFu);
  if (counted_bad == 0)
    failures += Fail("frames counted as refused after a beat was flipped in each", 0, 1);

  // The guard beside the forward strobe, flipped the same way and for the same
  // five ticks.  Nothing reads it, so nothing may move: not the word, and not
  // the far board's count of refused frames.
  long guarded = 0;
  {
    const unsigned guard_bad_before = dut->b_frames & 0xFFu;
    corrupt_pin = 1;
    for (unsigned e = 8; e < 12 && failures < kMaxFailures; ++e) {
      dut->b_spy_rdata = SpyWord(e);
      corrupt = 40 + 7 * (long)e;
      const Res r = Peek(kSpyBase + 2 * e, 8000);
      corrupt = -1;
      if (!r.answered || r.word != SpyWord(e))
        failures += Fail("a debug cycle over a cable with a GUARD pin flipped in it", r.word,
                         SpyWord(e));
      else
        ++guarded;
    }
    corrupt_pin = 2;
    const unsigned guard_bad = (dut->b_frames & 0xFFu) - guard_bad_before;
    if (guard_bad)
      failures += Fail("frames refused after a guard pin was flipped, which nothing reads",
                       guard_bad, 0);
  }
  delay = 0;
  Idle(400);

  // ---- 4b. a cycle at an address nothing answers -------------------------
  //
  // **THE FRAME'S LENGTH IS SPENT OUT OF A BUDGET, AND THIS IS THE WORST CASE
  // IN IT.**  A debug cycle is a request frame, the far machine's own bus
  // cycle and an answer frame.  The far machine's half is under a microsecond
  // when a slave answers; when nothing does, MIT's board runs it out on ITS
  // own timer.  Here the debuggee's Unibus has one slave, the diagnostic
  // block, so a cycle anywhere else is a cycle nothing answers at all.
  //
  // What must happen is that it does NOT come back with a word: the debuggee
  // never acknowledges, the debugger's own interface gives up, and the cable
  // carries on afterwards.  **What ends it is not in this DUT**: the REQTIM
  // counter is in `rtl/machine/cadr_busint_xbus.sv` and `build/unibus.pass` is
  // what holds it to the PROM's second table.  What this leg shows is that the
  // carrier neither answers such a cycle nor is left broken by one, over more
  // ticks than that counter would have taken.
  long unanswered = 0;
  {
    const long before = contention;
    // `0o760000` is below the diagnostic block and nothing in this harness
    // decodes it.  The address latch carries `UAO<16:1>`, so bit 17 is the
    // modifier's and is already set.
    const Res r = Peek(0760000, kDebugTimeoutT + 4 * kFrameT);
    if (r.answered)
      failures += Fail("a debug cycle at an address nothing answers came back", r.word, 0);
    else
      ++unanswered;
    if (contention != before)
      failures += Fail("pads driven from both ends over a cycle nothing answered",
                       (unsigned long)(contention - before), 0);
    // And the cable is still a cable: the next cycle reads the register it
    // names.  A carrier that had latched the abandoned request would answer
    // this one out of it.
    dut->b_spy_rdata = SpyWord(3);
    const Res good = Peek(kSpyBase + 2 * 3, 8000);
    if (!good.answered || good.word != SpyWord(3))
      failures += Fail("the cycle after one that nothing answered", good.word, SpyWord(3));
  }

  // ---- 5. the cable pulled under a standing request ----------------------
  //
  // The debugger's page must ANSWER there rather than wait: an open connector
  // is a debuggee that answers everything with ones, and a page that waited
  // would hang its own machine's Unibus cycle on a cable nobody is holding.
  long pulled = 0;
  {
    dut->a_addr = kStatus;
    dut->a_write = 0;
    dut->a_wdata = 0;
    dut->a_msyn = 1;
    long ssyn_at = -1;
    unsigned word = 0;
    for (long k = 0; k < 4000; ++k) {
      if (k == 30) join = 0;   // pulled, well after the request went out
      Tick();
      if (dut->a_ssyn && ssyn_at < 0) {
        ssyn_at = k;
        word = dut->a_rdata;
        break;
      }
    }
    dut->a_msyn = 0;
    Idle(24);
    if (ssyn_at < 0) {
      failures += Fail("-UB SSYN after the cable was pulled", 0, 1);
    } else if (word != 0xFFFFu) {
      failures += Fail("the word a pulled cable gives", word, 0xFFFFu);
    } else {
      ++pulled;
    }
    if (dut->a_live) failures += Fail("A still hearing a board that is not there", 1, 0);
    join = 1;
    Idle(600);
    if (!dut->a_live) failures += Fail("A hearing B again once the cable is back", 0, 1);
  }

  // ---- 6. two debuggers, and a role that may not change under a cycle -----
  //
  // B is told to connect while A already has it.  It must refuse: it can see
  // a debugger driving the forward group, and the first board told is the one
  // that has it.  A pad driven from both ends would be the failure, and the
  // counter below has been watching for it since the first tick.
  dut->connect_b = 1;
  Idle(800);
  if (dut->b_engaged)
    failures += Fail("B took the role with a debugger already on the cable", 1, 0);
  if (!dut->b_foreign) failures += Fail("B seeing the debugger it refused to displace", 0, 1);
  {
    // And the cable still works while it is being refused.
    dut->b_spy_rdata = SpyWord(9);
    const Res r = Peek(kSpyBase + 18, 8000);
    if (!r.answered || r.word != SpyWord(9))
      failures += Fail("a debug cycle while the far board is asking for the role", r.word,
                       SpyWord(9));
  }
  dut->connect_b = 0;
  Idle(200);

  // A's role, dropped while a request stands: it may not go until the cycle
  // has.  `engaged` is what drives the pads, so a role that changed inside a
  // request would leave the far end waiting on a cable that had stopped
  // answering.
  long held_under_cycle = 0;
  {
    dut->a_addr = kCycle;
    dut->a_write = 0;
    dut->a_wdata = 0;
    dut->a_msyn = 1;
    int seen_req = 0;
    for (long k = 0; k < 200; ++k) {
      Tick();
      if (dut->a_select_debug) seen_req = 1;
      if (k == 60) dut->connect_a = 0;
      if (k > 60 && !dut->a_engaged) break;
    }
    if (!seen_req) failures += Fail("SELECT DEBUG during the cycle the role was dropped in", 0, 1);
    if (!dut->a_engaged) {
      failures += Fail("A's role held until the cycle ended", 0, 1);
    } else {
      ++held_under_cycle;
    }
    dut->a_msyn = 0;
    Idle(200);
    if (dut->a_engaged) failures += Fail("A's role dropped once the cycle had gone", 1, 0);
  }

  // ---- 7. THE ROLE IS A BOARD'S OWN, AND THE DBGIN PAGE IS NEVER SWITCHED
  // ---- OFF BY IT ---------------------------------------------------------
  //
  // A board becomes the debugger by being told to, and it stays a DEBUGGEE
  // through its own register window while it does --- which is what
  // `docs/debug-cable.md` means by "only the connector changes hands".  A
  // real CADR has both connectors live for the same reason, so this is the
  // fabric being faithful rather than being convenient.
  //
  // What can go wrong, and what is asserted:
  //
  //   a board told to connect drives the connector, and the other end sees
  //   it --- which is leg 2 for A and is asked here of B, so that the role
  //   is a property of the module and not of which board the check happens
  //   to have wired as the debugger;
  //
  //   its own DBGIN page still answers its window while it does.  The window
  //   arm is stimulus here, as it is on the board a debugger is: what is
  //   watched is the ADDRESS latch inside `cadr_dbgin.sv`, which takes the
  //   word the holder drove;
  //
  //   and a board told to disconnect goes QUIET --- it drives no pad at all
  //   with nothing else on the cable --- while its window goes on answering.
  long b_role_ticks = 0, win_writes = 0, short_sessions = 0;
  {
    // A has let the role go at the end of leg 6.  Give the cable a frame to
    // settle so that neither board believes anything is on it.
    Idle(600);
    const long a_before = a_drove, b_before = b_drove;
    dut->connect_b = 1;
    Idle(kDetectT + 6 * kFrameT);
    if (!dut->b_engaged) failures += Fail("B engaged after connect", 0, 1);
    if (dut->a_engaged) failures += Fail("A engaged after it let the role go", 1, 0);
    if (!dut->a_foreign)
      failures += Fail("A seeing the debugger that took the cable", 0, 1);
    if (b_drove == b_before)
      failures += Fail("B driving the connector with the role", 0, 1);
    if (a_drove == a_before)
      failures += Fail("A answering the debugger that took the cable", 0, 1);
    b_role_ticks = tick;

    // And B's own DBGIN page still answers its window, with B holding the
    // cable's other role.  `a = 3` is `-DB ADR2 CLK`, the address latch, and
    // the word is poison: both halves distinct, neither `0x0000` nor
    // `0xFFFF`, and not a value anything else in this run drives.
    dut->b_win_a = 3;
    dut->b_win_wr = 1;
    dut->b_win_dbd = 0x5C3A;
    dut->b_win_req = 1;
    Idle(64);
    if (dut->b_holder != 0)
      failures += Fail("B's window holding its own page while B is the debugger",
                       dut->b_holder, 0);
    dut->b_win_req = 0;
    Idle(64);
    ++win_writes;
    if (dut->b_address != 0x5C3A)
      failures += Fail("B's DBGIN page answering its window while B debugs somebody",
                       dut->b_address, 0x5C3A);

    // Told to disconnect, B goes quiet: with A a debuggee that has stopped
    // hearing anybody, NOTHING on this cable is driven.
    dut->connect_b = 0;
    Idle(1200);
    if (dut->b_engaged) failures += Fail("B let the role go", 1, 0);
    const long a_quiet = a_drove, b_quiet = b_drove;
    Idle(600);
    if (a_drove != a_quiet || b_drove != b_quiet)
      failures += Fail("pads driven by two boards that have both let go",
                       (unsigned long)((a_drove - a_quiet) + (b_drove - b_quiet)), 0);
    if (dut->a_foreign || dut->b_foreign)
      failures += Fail("a debugger still on a cable nobody is driving", 1, 0);

    // And the window goes on answering a board that is nobody's debugger.
    dut->b_win_dbd = 0xA3C5;
    dut->b_win_req = 1;
    Idle(64);
    dut->b_win_req = 0;
    Idle(64);
    ++win_writes;
    if (dut->b_address != 0xA3C5)
      failures += Fail("B's DBGIN page answering its window after the role was given back",
                       dut->b_address, 0xA3C5);
    dut->b_win_wr = 0;
    dut->b_win_a = 0;
    dut->b_win_dbd = 0;

    // **AND A SHORT SESSION, WHICH IS A DIFFERENT QUESTION FROM A LONG ONE.**
    // What a board coming out of the role knows about the connector is
    // nothing, and there are two ways to forget: the activity timer, and the
    // two synchronizer flops in front of it.  A board that held the role for
    // longer than `LOSS_T` has a timer that has saturated on its own, so the
    // long session above cannot tell a held timer from a free-running one.
    // Connect and disconnect again inside `LOSS_T` and it can: a timer left
    // running is still near zero, so the board comes out of the role
    // believing somebody is driving the forward group and drives the return
    // one --- on top of the debuggee that is driving it.
    //
    // A race check needs the stimulus that loses the race, and the stimulus a
    // testbench reaches for first is the comfortable one.
    //
    // **AND THE SETTING IS FORCED FOR IT**, which is not a convenience: under
    // `auto` a session this short is spent listening and drives nothing at
    // all, so it would ask the question of a board that never took a pin.  A
    // board told the wiring drives from the tick it takes the role, which is
    // the stimulus this leg is about.
    {
      Idle(1200);
      dut->wire_b = kStraight;
      dut->connect_b = 1;
      Idle(120);
      if (!dut->b_engaged) failures += Fail("B engaged on a short session", 0, 1);
      if (dut->b_wire_state != kWsStraight)
        failures += Fail("B's wiring on a short session", dut->b_wire_state, kWsStraight);
      dut->connect_b = 0;
      Idle(400);
      if (dut->b_engaged) failures += Fail("B let a short session go", 1, 0);
      dut->wire_b = kAuto;
      ++short_sessions;
    }
  }


  // ---- 8. A RIBBON MADE THE WRONG WAY ROUND ------------------------------
  //
  // A Pmod header is two rows and a cable made from two host sockets mirrors
  // them, so each board's pins 1 to 4 reach the other's 7 to 10.  Two boards
  // were found on exactly such a cable: the one told to connect drove four
  // pins the other never listens to and reported that nothing was answering.
  //
  // Under `auto` a board finds that out for itself.  It listens on both groups
  // while driving nothing, and then --- because two boards freshly reset are
  // two silent debuggees whatever the cable is, and silence names no wiring
  // --- it assumes straight and ALTERNATES until something answers.
  long crossed_sessions = 0, crossed_peeks = 0, far_seen = 0;
  long cont_mark = contention;
  auto ContentionSince = [&](const char *what) {
    if (contention != cont_mark) {
      failures += Fail(what, (unsigned long)(contention - cont_mark), 0);
      cont_mark = contention;
    }
  };
  {
    Reset();
    crossed = 1;
    const long quiet_a = a_drove, quiet_b = b_drove;
    Idle(800);
    if (a_drove != quiet_a || b_drove != quiet_b)
      failures += Fail("pads driven by two boards on a mirrored ribbon with nothing set",
                       (unsigned long)((a_drove - quiet_a) + (b_drove - quiet_b)), 0);

    dut->connect_a = 1;
    // The listen, and a look inside the first probe --- which is the WRONG
    // group on this cable.  What the far board sees then is the whole
    // diagnosis in one bit: frames arriving on the four pins a debuggee
    // ANSWERS on, which nothing but a mirrored ribbon can do.
    Idle(kDetectT + 3 * kFrameT);
    if (dut->a_wire_state != kWsStAssumed)
      failures += Fail("the wiring A assumes when it has heard nothing",
                       dut->a_wire_state, kWsStAssumed);
    if (!dut->b_peer_far)
      failures += Fail("B seeing a debugger on the pins it answers on", 0, 1);
    else
      ++far_seen;
    if (!dut->b_foreign) failures += Fail("B seeing a debugger at all", 0, 1);
    if (dut->b_engaged) failures += Fail("B taking a role nobody gave it", 1, 0);
    if (dut->a_live) failures += Fail("A hearing an answer on the wrong group", 1, 0);

    // And then the alternation reaches the other group and the cable comes up.
    Idle(kProbeT + 14 * kFrameT);
    if (dut->a_wire_state != kWsCrFound)
      failures += Fail("the wiring A found on a mirrored ribbon", dut->a_wire_state,
                       kWsCrFound);
    if (!dut->a_live) failures += Fail("A hearing B over a mirrored ribbon", 0, 1);
    if (!dut->b_foreign) failures += Fail("B seeing the debugger that compensated", 0, 1);
    if (dut->b_peer_far)
      failures += Fail("B still hearing the far end on the pins it answers on", 1, 0);
    ++crossed_sessions;
    SetModifier();

    // A debug cycle over it, which is the only claim that matters: board A's
    // own machine reading board B's diagnostic register through eight wires
    // that are not the ones either board was built expecting.
    for (unsigned e = 0; e < 4 && failures < kMaxFailures; ++e) {
      dut->b_spy_rdata = SpyWord(e);
      const Res r = Peek(kSpyBase + 2 * e, 8000);
      if (!r.answered || r.word != SpyWord(e))
        failures += Fail("a debug cycle over a mirrored ribbon", r.word, SpyWord(e));
      else
        ++crossed_peeks;
    }

    // ---- and the lock-out, which is what was measured on the bench --------
    //
    // The role given back, and then the OTHER board told to take it.  On the
    // fabric this replaces, the disconnect's own transient left each board
    // hearing the other's answers, each calling that a debugger, and NEITHER
    // able to engage --- measured on two boards, and it stood for as long as
    // anybody looked.  A frame that says "I am a debuggee" is not a debugger,
    // so neither the answer nor the refusal fires and the connector goes
    // quiet.
    dut->connect_a = 0;
    Idle(2 * kLossT);
    if (dut->a_engaged || dut->b_engaged)
      failures += Fail("a role still held after the connector was given back", 1, 0);
    if (dut->a_foreign || dut->b_foreign)
      failures += Fail("a debugger on a connector both boards have let go", 1, 0);
    const long after_a = a_drove, after_b = b_drove;
    Idle(600);
    if (a_drove != after_a || b_drove != after_b)
      failures += Fail("pads driven by two boards that have both let go of a mirrored ribbon",
                       (unsigned long)((a_drove - after_a) + (b_drove - after_b)), 0);

    dut->connect_b = 1;
    Idle(kDetectT + 2 * kProbeT + 14 * kFrameT);
    if (!dut->b_engaged)
      failures += Fail("the OTHER board taking the role over a mirrored ribbon", 0, 1);
    if (dut->b_wire_state != kWsCrFound)
      failures += Fail("the wiring B found on a mirrored ribbon", dut->b_wire_state,
                       kWsCrFound);
    if (!dut->b_live) failures += Fail("B hearing A over a mirrored ribbon", 0, 1);
    ++crossed_sessions;
    dut->connect_b = 0;
    Idle(2 * kLossT);
    ContentionSince("wires driven from both ends over a mirrored ribbon");
  }

  // ---- 8a. AND AT EVERY PHASE OF THE FRAME THE ROLE IS DROPPED IN ---------
  //
  // **THE SEED OF THE BENCH'S FAULT IS THE EDGE A DRIVER MAKES BY LETTING
  // GO.**  A group released mid-frame holds its last level for as long as the
  // pull-downs take, and if that level was high the board's own activity
  // watcher sees a transition on a pin nobody is driving --- and answers it.
  // Whether it does depends on which beat the role was dropped in, so the
  // question has to be asked at every phase and not at a convenient one.
  //
  // Measured on the fabric this replaces, over the same twelve phases with the
  // same cable: four of them left both boards calling the other's answers a
  // debugger, with NEITHER able to take the role afterwards --- which is what
  // two boards on a bench were found doing, and it stood for as long as
  // anybody looked.
  long phases = 0;
  {
    for (long skew = 0; skew < kFrameT && failures < kMaxFailures; skew += 6) {
      Reset();
      crossed = 1;
      dut->wire_a = kCrossover;      // forced, so the drop can be timed
      dut->connect_a = 1;
      Idle(12 * kFrameT + skew);
      if (!dut->a_engaged) failures += Fail("A engaged before the role was dropped", 0, 1);
      dut->connect_a = 0;
      Idle(2 * kLossT);
      if (dut->a_foreign || dut->b_foreign)
        failures += Fail("a debugger on a connector both boards have let go, at a phase",
                         (unsigned long)skew, 0);
      const long qa = a_drove, qb = b_drove;
      Idle(400);
      if (a_drove != qa || b_drove != qb)
        failures += Fail("pads driven after a role was dropped, at a phase",
                         (unsigned long)skew, 0);
      // And the role can be had again, by either board, which is the thing the
      // lock-out took away.
      dut->connect_b = 1;
      Idle(12 * kFrameT);
      dut->wire_b = kCrossover;
      if (!dut->b_engaged)
        failures += Fail("the other board taking the role after a drop, at a phase",
                         (unsigned long)skew, 0);
      dut->connect_b = 0;
      dut->wire_a = kAuto;
      dut->wire_b = kAuto;
      Idle(2 * kLossT);
      ++phases;
    }
    ContentionSince("wires driven from both ends while the role was dropped mid-frame");
  }

  // ---- 9. THE SETTING, FORCED, ON BOTH CABLES ----------------------------
  //
  // Four combinations and two outcomes.  A board told the wiring drives from
  // the tick it takes the role and never listens first, which is what the
  // setting is for: it takes the looking out of the way when somebody is
  // diagnosing a cable.  Told the truth it works; told the other thing it is
  // a debugger driving pins nobody listens to, which must read exactly like an
  // unplugged cable and must not put two drivers on one wire.
  long forced_up = 0, forced_quiet = 0;
  for (int c = 0; c < 2; ++c) {
    for (int w = 0; w < 2; ++w) {
      const int setting = w ? kCrossover : kStraight;
      const bool matches = (c == 1) == (setting == kCrossover);
      Reset();
      crossed = c;
      dut->wire_a = (unsigned char)setting;
      dut->connect_a = 1;
      Idle(12 * kFrameT);
      if (!dut->a_engaged)
        failures += Fail("A engaged on a forced setting", 0, 1);
      if (dut->a_wire_state != (setting == kCrossover ? kWsCrossover : kWsStraight))
        failures += Fail("the wiring A was told to use", dut->a_wire_state,
                         (unsigned long)(setting == kCrossover ? kWsCrossover : kWsStraight));
      if (matches) {
        SetModifier();
        dut->b_spy_rdata = SpyWord(5);
        const Res r = Peek(kSpyBase + 10, 8000);
        if (!r.answered || r.word != SpyWord(5))
          failures += Fail("a debug cycle with the wiring set by hand", r.word, SpyWord(5));
        else
          ++forced_up;
      } else {
        // The far board hears a debugger on the pins it answers on --- the
        // two ends disagree about the cable --- and says so, while answering
        // nothing.  The debugger's own page must not wait for a cable nobody
        // is holding: it answers at once with the sixteen undriven lines.
        if (!dut->b_peer_far)
          failures += Fail("B saying the two ends disagree about the cable", 0, 1);
        else
          ++far_seen;
        if (dut->a_live) failures += Fail("A hearing an answer it cannot have", 1, 0);
        const Res st = Run(kStatus, 0, 0, 4000);
        if (!st.answered)
          failures += Fail("-UB SSYN with the wiring set the wrong way", 0, 1);
        else if (st.word != 0xFFFFu)
          failures += Fail("the word a wiring nobody answers gives", st.word, 0xFFFFu);
        else
          ++forced_quiet;
      }
      dut->connect_a = 0;
      Idle(2 * kLossT);
      dut->wire_a = kAuto;
      ContentionSince("wires driven from both ends with the wiring set by hand");
    }
  }

  // ---- 10. NO CABLE AT ALL, AND THE FALLBACK THAT MOVES -------------------
  //
  // A board told to connect with nothing in the connector hears nothing, which
  // is the same silence a far board that has not been told anything makes.  So
  // it assumes straight --- and then alternates, because the assumption is the
  // only thing it can be wrong about and one probe interval is the whole cost
  // of finding out.  What a person reads is "nothing heard", with the
  // assumption it is trying beside it.
  long assumed_straight = 0, assumed_crossover = 0;
  {
    Reset();
    crossed = 0;
    join = 0;
    dut->connect_a = 1;
    Idle(kDetectT + 2 * kFrameT);
    if (!dut->a_engaged) failures += Fail("A engaged with no cable in the connector", 0, 1);
    if (dut->a_wire_state != kWsStAssumed)
      failures += Fail("the wiring a board with no cable falls back to",
                       dut->a_wire_state, kWsStAssumed);
    ++assumed_straight;
    if (dut->a_live) failures += Fail("A hearing a board that is not there", 1, 0);
    // And the alternation, which is what makes `auto` work on a mirrored
    // ribbon that nobody has told it about.
    for (long k = 0; k < 3 * kProbeT && !assumed_crossover; ++k) {
      Tick();
      if (dut->a_wire_state == kWsCrAssumed) ++assumed_crossover;
    }
    if (!assumed_crossover)
      failures += Fail("the assumption a board with no cable moves to", 0, 1);
    const Res st = Run(kStatus, 0, 0, 4000);
    if (!st.answered)
      failures += Fail("-UB SSYN with no cable in the connector", 0, 1);
    else if (st.word != 0xFFFFu)
      failures += Fail("the word an empty connector gives", st.word, 0xFFFFu);
    dut->connect_a = 0;
    join = 1;
    Idle(2 * kLossT);
  }

  // ---- 11. A SETTING MAY NOT MOVE UNDER A BOARD THAT IS DEBUGGING ---------
  //
  // The wiring decides which four pins this board drives, so a setting that
  // moved inside a session would take the pins out from under a cycle and
  // leave the far end answering into wires nobody is listening to.  The
  // console refuses the write; the FABRIC latches the setting at the take, and
  // the two are independent on purpose --- the refusal is what a person is
  // told and the latch is what the fabric does whatever it is told.  This is
  // the latch, asked the only way a check can ask it: by moving the setting
  // under a board that is already the debugger.
  long held_setting = 0;
  {
    Reset();
    crossed = 0;
    dut->wire_a = kStraight;
    dut->connect_a = 1;
    Idle(12 * kFrameT);
    if (!dut->a_engaged) failures += Fail("A engaged before the setting was moved", 0, 1);
    dut->wire_a = kCrossover;
    Idle(4 * kFrameT);
    if (dut->a_wire_state != kWsStraight)
      failures += Fail("the wiring in effect after the setting moved under it",
                       dut->a_wire_state, kWsStraight);
    SetModifier();
    dut->b_spy_rdata = SpyWord(11);
    const Res r = Peek(kSpyBase + 22, 8000);
    if (!r.answered || r.word != SpyWord(11))
      failures += Fail("a debug cycle after the setting moved under it", r.word, SpyWord(11));
    else
      ++held_setting;
    // **AND `auto` IS THE ONE THAT WOULD DO SOMETHING**, so it is the one the
    // check moves to: a board whose state machine read the live setting would
    // start LOOKING for a wiring under a session that was told one, and would
    // flip its pins a probe interval later.  Moved from one forced value to
    // another, a board that read the live setting and one that latched it
    // would both stand still and the check would say nothing.
    //
    // **AND WITH NOTHING ANSWERING**, which is the arrangement in which the
    // auto machine would actually take the pins: its timer stands at zero
    // after a forced take, so a board that read the live setting would flip
    // its assumption on the very next tick and go quiet to relisten --- on the
    // wires of a session that was told which four pins to drive.  With the far
    // end answering there is nothing to flip TO, so the mutation is invisible;
    // this is the stimulus that loses the race.
    join = 0;
    Idle(2 * kLossT);
    dut->wire_a = kAuto;
    Idle(kProbeT + kRelistenT + 6 * kFrameT);
    if (dut->a_wire_state != kWsStraight)
      failures += Fail("the wiring in effect after the setting moved to auto under it",
                       dut->a_wire_state, kWsStraight);
    join = 1;
    Idle(2 * kLossT);
    dut->b_spy_rdata = SpyWord(12);
    const Res r2 = Peek(kSpyBase + 24, 8000);
    if (!r2.answered || r2.word != SpyWord(12))
      failures += Fail("a debug cycle after the setting moved to auto under it", r2.word,
                       SpyWord(12));
    else
      ++held_setting;
    // And it takes once the role has been given back, which is the other half
    // of the same claim.
    dut->wire_a = kCrossover;
    dut->connect_a = 0;
    Idle(2 * kLossT);
    dut->connect_a = 1;
    Idle(12 * kFrameT);
    if (dut->a_wire_state != kWsCrossover)
      failures += Fail("the wiring taken at the next take", dut->a_wire_state, kWsCrossover);
    dut->connect_a = 0;
    dut->wire_a = kAuto;
    Idle(2 * kLossT);
    ContentionSince("wires driven from both ends while a setting moved under a session");
  }


  // ---- 12. THE ROLE TAKEN WHILE THE FAR END IS STILL ANSWERING -----------
  //
  // **THIS IS THE ONE STIMULUS IN WHICH THE LISTEN HAS ANYTHING TO HEAR**, and
  // it is worth saying why.  A debuggee sends nothing until it hears a
  // debugger, so two boards freshly reset are silent and a board listening to
  // them learns nothing --- which is why the fallback alternates.  A board that
  // has just STOPPED being the debugger leaves the far end still answering for
  // as long as its own loss interval, and a board that takes the role in that
  // window hears idle frames and names the cable outright.
  //
  // Both cables, because the group the frames arrive on is the whole answer:
  // the far board drives the high four, so on a straight ribbon they land on
  // the high four here and on a mirrored one on the low four.
  long heard_wiring = 0;
  for (int c = 0; c < 2; ++c) {
    Reset();
    crossed = c;
    dut->wire_a = (unsigned char)(c ? kCrossover : kStraight);
    dut->connect_a = 1;
    Idle(12 * kFrameT);
    if (!dut->a_live)
      failures += Fail("the far end answering before the role is given back", 0, 1);
    // Given back and taken again inside the far end's own loss interval, with
    // nothing said about the wiring this time.
    dut->connect_a = 0;
    dut->wire_a = kAuto;
    Idle(2 * kFrameT);
    dut->connect_a = 1;
    // Well inside the listening interval: what settles it here is what was
    // HEARD, and a board that had to assume would still be listening.
    Idle(6 * kFrameT);
    const int want = c ? kWsCrFound : kWsStFound;
    if (dut->a_wire_state != want)
      failures += Fail("the wiring a board hears while the far end is still answering",
                       dut->a_wire_state, (unsigned long)want);
    else
      ++heard_wiring;
    dut->connect_a = 0;
    Idle(2 * kLossT);
    ContentionSince("wires driven from both ends while the role was taken again");
  }

  // ---- 13. A GROUP THE FAR END IS ALREADY DRIVING ------------------------
  //
  // **THE RULE THAT HOLDS WHERE THE ROLES DO NOT.**  A board never enables a
  // pad on a group whose receiver says something is on it, and the arrangement
  // that needs it is a board changing its mind about the wiring while the far
  // end is still answering the last one.
  //
  // A mirrored ribbon, a board told `crossover`, and the far board answering
  // on its high four --- which land on this board's LOW four.  Told `straight`
  // and reconnected before the far end has stopped, this board wants exactly
  // those four pins.  Without the gate it drives them, and the check counts a
  // wire driven from both ends.
  long over_a_driver = 0;
  for (int c = 0; c < 2; ++c) {
    // The cable, and the two settings in the order that puts the far end on
    // the group the second one wants.  On a straight ribbon the far board
    // answers on the high four, which are this board's high four, so the
    // second setting to want them is `crossover`.  On a mirrored one its
    // answers land on the low four and the second setting is `straight`.
    const int first = c ? kCrossover : kStraight;
    const int second = c ? kStraight : kCrossover;
    Reset();
    crossed = c;
    dut->wire_a = (unsigned char)first;
    dut->connect_a = 1;
    Idle(12 * kFrameT);
    if (!dut->a_live)
      failures += Fail("the far end answering before the setting is changed", 0, 1);
    dut->connect_a = 0;
    dut->wire_a = (unsigned char)second;
    // Two frames, which is well inside the far end's loss interval: it is
    // still driving, and this board still knows it is.
    Idle(2 * kFrameT);
    dut->connect_a = 1;
    Idle(6 * kFrameT);
    if (!dut->a_engaged) failures += Fail("A engaged on the second setting", 0, 1);
    ++over_a_driver;
    dut->connect_a = 0;
    dut->wire_a = kAuto;
    Idle(2 * kLossT);
    ContentionSince("wires driven from both ends by a board that changed its mind");
  }

  // ---- 14. TWO DEBUGGERS, AND AN ANSWER IS A DEBUGGEE'S -----------------
  //
  // Two boards told to connect in the SAME tick both take the role: neither
  // can see the other, a debugger being a frame and a frame taking two of them
  // to arrive.  On a mirrored ribbon each one's four driven pins land on the
  // four the other is listening to, so each hears the other's REQUESTS where
  // its own cable's replies would be.
  //
  // **AN ANSWER COMES FROM A DEBUGGEE AND THE ROLE BIT SAYS WHICH ARRIVED.**  A
  // board that took any good frame there for an answer would read
  // `DEBUG OUT ACK` out of somebody else's `-DEBUG IN REQ` and sixteen data
  // lines out of an address.  What must happen instead is nothing: the
  // debugger's own page answers with the sixteen undriven lines, exactly as an
  // unplugged connector does, and the console says a debugger is on it.
  long two_debuggers = 0;
  {
    Reset();
    crossed = 1;
    dut->wire_a = kStraight;
    dut->wire_b = kStraight;
    dut->connect_a = 1;
    dut->connect_b = 1;      // the same tick: neither has heard the other yet
    Idle(12 * kFrameT);
    if (!dut->a_engaged || !dut->b_engaged)
      failures += Fail("two boards told in the same tick both taking the role",
                       (unsigned)(dut->a_engaged && dut->b_engaged), 1);
    if (!dut->a_foreign || !dut->b_foreign)
      failures += Fail("each board seeing the other debugger", 0, 1);
    // `live` is true and rightly so --- good frames ARE arriving --- and
    // `foreign` is what says they are a debugger's.  What must not happen is
    // one word of them reaching the DBGOUT page, and the status read is where
    // that shows: a page that took them would answer with bits out of somebody
    // else's address.
    if (!dut->a_live)
      failures += Fail("A hearing the other debugger's frames at all", 0, 1);
    const Res st = Run(kStatus, 0, 0, 4000);
    if (!st.answered)
      failures += Fail("-UB SSYN with a second debugger on the connector", 0, 1);
    else if (st.word != 0xFFFFu)
      failures += Fail("the word another debugger's frames give", st.word, 0xFFFFu);
    else
      ++two_debuggers;
    dut->connect_a = 0;
    dut->connect_b = 0;
    dut->wire_a = kAuto;
    dut->wire_b = kAuto;
    Idle(2 * kLossT);
    ContentionSince("wires driven from both ends by two debuggers");
  }

  // ---- and nothing was ever driven from both ends -------------------------
  if (contention)
    failures += Fail("pads driven from both ends of the cable at once", (unsigned long)contention,
                     0);
  if (pin_group_bad)
    failures += Fail("ticks with a pad driven outside the group the board says it is on",
                     (unsigned long)pin_group_bad, 0);
  if (guard_part_group)
    failures += Fail("ticks with part of a pin group driven and the rest of it floating",
                     (unsigned long)guard_part_group, 0);
  if (guard_high)
    failures += Fail("ticks with a guard pin driven anything but low",
                     (unsigned long)guard_high, 0);

  // **AND EVERY ONE OF THEM FINISHED INSIDE THE DEBUGGER'S OWN TIMEOUT.**
  // This is the budget the frame's length is spent out of, measured rather
  // than computed: a cycle is two frames and the far machine's bus cycle, and
  // the interface beside this master gives up at `kDebugTimeoutT` ticks.
  std::fprintf(stderr,
               "the slowest debug cycle over the cable took %ld ticks; a frame is %ld, "
               "the debugger gives up at %ld and this check at %ld\n",
               worst_ssyn, kFrameT, kDebugTimeoutT, kRoundTripBound);
  if (worst_ssyn < 0)
    failures += Fail("debug cycles measured against the debugger's timeout", 0, 1);
  else if (worst_ssyn >= kRoundTripBound)
    failures += Fail("the slowest debug cycle over the cable",
                     (unsigned long)worst_ssyn, (unsigned long)kRoundTripBound);

  if (failures) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", failures, tick);
    return 1;
  }

  int thin = 0;
  auto least = [&](const char *what, long got, long want) {
    if (got < want) {
      std::fprintf(stderr, "FAIL: the run reached %ld %s and cannot hold anything with fewer\n",
                   got, what);
      ++thin;
    }
  };
  least("registers of the debuggee read over the cable", peeks, 16);
  least("cycles over a cable with a delay in it", delayed, 4);
  least("cycles over a cable with a beat flipped in it", corrupted, 4);
  least("cables pulled under a standing request", pulled, 1);
  least("roles held under a cycle", held_under_cycle, 1);
  least("ticks with the second board holding the role", b_role_ticks, 1);
  least("window writes through a page whose board held a role", win_writes, 2);
  least("roles taken and given back inside the loss interval", short_sessions, 1);
  least("ticks with two boards cabled together and nobody told anything", quiet_ticks, 600);
  least("sessions over a ribbon made the wrong way round", crossed_sessions, 2);
  least("phases of the frame the role was dropped in", phases, 11);
  least("registers read over a ribbon made the wrong way round", crossed_peeks, 4);
  least("cables brought up with the wiring set by hand", forced_up, 2);
  least("cables left quiet by a wiring set the wrong way", forced_quiet, 2);
  least("boards that said the two ends disagree about the cable", far_seen, 3);
  least("boards that fell back to straight with nothing to hear", assumed_straight, 1);
  least("boards that then tried the other wiring", assumed_crossover, 1);
  least("settings moved under a board that was already debugging", held_setting, 2);
  least("wirings heard rather than assumed", heard_wiring, 2);
  least("connectors with two debuggers on them", two_debuggers, 1);
  least("frames heard over a settled cable with none refused", clean_heard, 40);
  least("frames counted as refused when a beat was flipped in them", counted_bad, 1);
  least("boards that changed their mind while the far end was driving", over_a_driver, 2);
  least("ticks with a board holding the role, its pads watched", pin_group_ticks, 20000);
  least("pin-ticks with a guard driven low beside a signal", guard_low_ticks, 20000);
  least("cycles over a cable with a guard pin flipped in it", guarded, 4);
  least("cycles at an address nothing answered", unanswered, 1);
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks --- A CADR DEBUGGED A CADR OVER ONE PMOD CABLE.  Board A's own machine ran\n"
      "    CC's four registers at 0766100-0766114 and board B answered them on its own Unibus,\n"
      "    with eight wires between them and this file as the wire.  All %ld of the debuggee's\n"
      "    diagnostic registers were read through a cycle on ITS bus and each came back with the\n"
      "    word that board drove, injective in the register number; the address latch at the far\n"
      "    end held what CC wrote; the status read came back 0x%04x, the low byte the debuggee's\n"
      "    and the high byte the open cable's pull-ups, which is the one place a byte nobody\n"
      "    drives has to arrive as ones.\n"
      "    THE CABLE WAS MADE TO MISBEHAVE: %ld cycles over three ticks of wire each way, and %ld\n"
      "    with the one DATA line inverted for five ticks inside the request --- the frame fails\n"
      "    its parity, moves nothing, and the next one %ld ticks later carries the same\n"
      "    levels, so a bad cable costs a frame and never a word.  Pulled under a standing\n"
      "    request, the debugger's own page answered at once with all ones rather than waiting,\n"
      "    and heard the far board again when it was plugged back in.\n"
      "    ONE SIGNAL A COUPLED PAIR, AND THE OTHER LINE OF EACH DRIVEN LOW: the strobe on header\n"
      "    pin 1 with pin 2 held at zero beside it, the data line on pin 3 with pin 4, and the\n"
      "    same on the return row.  Every group a board drove went out whole --- all four pads,\n"
      "    never a subset, %ld pin-ticks of guard at zero --- and %ld cycles ran with a GUARD pin\n"
      "    inverted the way the data line was, moving neither a word nor the far board's count of\n"
      "    refused frames, which nothing reading that pin is what that means.  The slowest debug\n"
      "    cycle of the whole run took %ld ticks, against a frame of %ld and the %ld the\n"
      "    debugger's own REQTIM table gives it; and %ld cycle(s) at an address nothing\n"
      "    answers came back with no word at all over more ticks than that table allows,\n"
      "    with the cable still carrying the cycle after them.\n"
      "    AND NO PAD WAS EVER DRIVEN FROM BOTH ENDS, over every tick of every phase: %ld ticks\n"
      "    with two boards cabled together and neither told anything, where a debuggee drives\n"
      "    nothing until it hears a debugger; a second board told to connect while the first\n"
      "    had the role, which it refused because it could see a debugger on the forward group;\n"
      "    and a role dropped inside a cycle, which was held until the cycle had gone.\n"
      "    AND THE ROLE IS A BOARD'S OWN AND THE DBGIN PAGE IS NEVER SWITCHED OFF BY IT: the\n"
      "    SECOND board was told to connect and took the role, drove the connector and was\n"
      "    heard by the first, which saw a foreign debugger and answered it; %ld write(s) went\n"
      "    through that board's OWN window into its OWN DBGIN page while it held the cable's\n"
      "    other role, and the address latch took each word, which is what `only the connector\n"
      "    changes hands` means; told to disconnect it went quiet, with not one pad driven at\n"
      "    either end over 600 ticks, and its window went on answering.  AND ONCE MORE IN A\n"
      "    SHORT SESSION --- the role taken and given back inside the loss interval, where a\n"
      "    board's timer has not had time to saturate on its own and only its being HELD\n"
      "    makes it forget the connector.  A long session cannot tell those two apart.\n"
      "    AND THE RIBBON WAS MADE THE WRONG WAY ROUND, which is what two boards on a bench\n"
      "    were found on: each board's pins 1-4 joined to the other's 7-10, so a debugger\n"
      "    drives four pins the far board never listens to.  On `auto` a board listens on\n"
      "    BOTH groups while driving nothing, and then --- two freshly reset boards being two\n"
      "    silent debuggees whatever the cable is --- assumes straight and ALTERNATES until\n"
      "    something answers: %ld session(s) came up that way and %ld of the far board's\n"
      "    registers were read through them.  The far board said so in one bit while the\n"
      "    wiring was wrong, %ld time(s): frames on the four pins a debuggee ANSWERS on,\n"
      "    which nothing but a mirrored ribbon can do.  THE LOCK-OUT IS GONE: the role given\n"
      "    back left the connector quiet and the OTHER board then took it, where the fabric\n"
      "    this replaces left each board calling the other's answers a debugger and neither\n"
      "    able to engage --- asked at %ld phases of the frame the role can be dropped in,\n"
      "    because a group released mid-beat holds its last level until the pull-downs have\n"
      "    it and only some of those phases make the edge that seeded it: four of twelve did,\n"
      "    measured on the fabric this replaces, and all of them are quiet here.\n"
      "    SET BY HAND, %ld cable(s) came up and %ld read exactly like an\n"
      "    unplugged connector --- 0xFFFF at once rather than a wait --- with no wire driven\n"
      "    twice in either case; with no cable at all the board fell back to straight and\n"
      "    then tried the other wiring; and a setting moved under a board that was already\n"
      "    debugging moved nothing, the cycle after it carrying the right word.\n",
      tick, peeks, 0xFF00u | kErrStatus, delayed, corrupted, kFrameT, guard_low_ticks,
      guarded, worst_ssyn, kFrameT, kDebugTimeoutT, unanswered, quiet_ticks, win_writes,
      crossed_sessions, crossed_peeks, far_seen, phases, forced_up, forced_quiet);
  dut->final();
  delete dut;
  return 0;
}
