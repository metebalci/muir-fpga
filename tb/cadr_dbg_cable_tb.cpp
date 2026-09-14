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
  int join = 1;
  int delay = 0;
  long corrupt = -1;
  long contention = 0;   // pads driven from both ends, ever
  long a_drove = 0, b_drove = 0;

  // A wire is a little shift register, one a pad, so a delay is a real delay
  // and not a relabelling.  Sixteen pads, eight a board, and the two
  // directions of the join are separate wires.
  const int kMaxDelay = 8;
  unsigned char wire_ab[8][kMaxDelay + 1] = {{0}};
  unsigned char wire_ba[8][kMaxDelay + 1] = {{0}};

  auto Tick = [&]() {
    dut->clk_a = 0;
    dut->clk_b = 0;
    dut->eval();

    // **THE CABLE, AND THE ASSERTION THAT MAKES IT ONE CABLE.**  A pad driven
    // from both ends is not modelled --- it is counted, and a run that counts
    // one has found the thing this connector's whole design is about.
    for (int p = 0; p < 8; ++p) {
      const bool a_on = ((dut->a_pin_t >> p) & 1) == 0;
      const bool b_on = ((dut->b_pin_t >> p) & 1) == 0;
      if (a_on) ++a_drove;
      if (b_on) ++b_drove;
      if (join && a_on && b_on) ++contention;
      // What each end puts on the wire, and what the other end reads a
      // `delay` later.  An undriven pad is a pull-down: a floating input on
      // this part is not a level and the carrier asks only that it not
      // change.
      unsigned char av = a_on ? (unsigned char)((dut->a_pin_o >> p) & 1) : 0;
      unsigned char bv = b_on ? (unsigned char)((dut->b_pin_o >> p) & 1) : 0;
      if (corrupt == 0 && p == 1) {
        av ^= 1;
        bv ^= 1;
      }
      for (int k = kMaxDelay; k > 0; --k) {
        wire_ab[p][k] = wire_ab[p][k - 1];
        wire_ba[p][k] = wire_ba[p][k - 1];
      }
      wire_ab[p][0] = av;
      wire_ba[p][0] = bv;
    }
    if (corrupt >= 0) --corrupt;

    unsigned a_in = 0, b_in = 0;
    for (int p = 0; p < 8; ++p) {
      // Each end reads what the OTHER end drove, through the cable, or its
      // own pad's pull-down with nothing plugged in.
      if (join) {
        a_in |= (unsigned)wire_ba[p][delay] << p;
        b_in |= (unsigned)wire_ab[p][delay] << p;
      }
    }
    dut->a_pin_i = (unsigned char)a_in;
    dut->b_pin_i = (unsigned char)b_in;

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

  // Board A's own machine, running one register cycle: this is CC.
  struct Res {
    long ssyn = -1;
    unsigned word = 0;
    int answered = 0;
  };
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
        break;
      }
    }
    dut->a_msyn = 0;
    // The master holds the strobe a delay-line section past the answer ---
    // `busint::UNIBUS_STROBE_NS` --- and the levels stand past the lift,
    // which is what the far end's latches clock on.
    Idle(24);
    return r;
  };

  // CC's own sequence: point the address register at a location on the
  // debuggee and run a cycle there.  `CC-READ` is exactly this.
  auto Peek = [&](unsigned uaddr, long guard) {
    Run(kAddress, 1, (uaddr >> 1) & 0xFFFFu, guard);
    return Run(kCycle, 0, 0, guard);
  };

  dut->rst_a = 1;
  dut->rst_b = 1;
  dut->connect_a = 0;
  dut->connect_b = 0;
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
  dut->connect_a = 1;
  Idle(400);
  if (!dut->a_engaged) failures += Fail("A engaged after connect", 0, 1);
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

  // ---- 4. a cable with a delay in it, and a beat flipped on the wire ------
  //
  // Three ticks of wire either way is thirty nanoseconds on this board, which
  // is a long Pmod ribbon and then some; the corruption is one data line
  // inverted for one tick, in the middle of a frame.  Neither may change a
  // word: the frame that carries the bad beat fails its parity and moves
  // nothing, and the next one --- sixty-six ticks later --- carries the same
  // levels.
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
  delay = 0;
  Idle(400);

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
    Idle(600);
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
    // two synchroniser flops in front of it.  A board that held the role for
    // longer than `LOSS_T` has a timer that has saturated on its own, so the
    // long session above cannot tell a held timer from a free-running one.
    // Connect and disconnect again inside `LOSS_T` and it can: a timer left
    // running is still near zero, so the board comes out of the role
    // believing somebody is driving the forward group and drives the return
    // one --- on top of the debuggee that is driving it.
    //
    // A race check needs the stimulus that loses the race, and the stimulus a
    // testbench reaches for first is the comfortable one.
    {
      Idle(1200);
      dut->connect_b = 1;
      Idle(120);
      if (!dut->b_engaged) failures += Fail("B engaged on a short session", 0, 1);
      dut->connect_b = 0;
      Idle(400);
      if (dut->b_engaged) failures += Fail("B let a short session go", 1, 0);
      ++short_sessions;
    }
  }

  // ---- and nothing was ever driven from both ends -------------------------
  if (contention)
    failures += Fail("pads driven from both ends of the cable at once", (unsigned long)contention,
                     0);

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
      "    with a data line inverted for a tick inside the request --- the frame fails its\n"
      "    parity, moves nothing, and the next one sixty-six ticks later carries the same\n"
      "    levels, so a bad cable costs a frame and never a word.  Pulled under a standing\n"
      "    request, the debugger's own page answered at once with all ones rather than waiting,\n"
      "    and heard the far board again when it was plugged back in.\n"
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
      "    makes it forget the connector.  A long session cannot tell those two apart.\n",
      tick, peeks, 0xFF00u | kErrStatus, delayed, corrupted, quiet_ticks, win_writes);
  dut->final();
  delete dut;
  return 0;
}
