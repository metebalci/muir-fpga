// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MIT's debug cable on eight pins, held to the one property a carrier has:
// **what goes in one end comes out the other, unchanged, whole, and in
// bounded time.**
//
// The carrier is `rtl/plumbing/cadr_dbg_tx.sv` with `cadr_dbg_rx.sv`, four pins each way, and
// `rtl/plumbing/cadr_dbg_join.sv` is what lets two debuggers share one DBGIN
// page.  Neither has a muir reference: muir has the cable and no wires, so
// there is no trace to compare against and what holds these is the property.
//
// **THE TESTBENCH IS THE CABLE.**  The harness brings the eight wires of each
// connector out as ports, so every wire here is delayed, skewed, shorted,
// crossed or unplugged by this file rather than assumed to be perfect.  A
// loopback of a serialiser into a deserialiser with an ideal wire between
// them is a check of arithmetic, not of a cable.
//
// **AND WHAT CROSSES IS POISON.**  A carrier fed a constant passes whatever
// it does to it.  So every value sent is `(h << 10) | (~h & 0x3FF)` for a
// walking `h`: the low half is the complement of the high half, every value
// in a run is distinct, and no value is zero, which is what an unplugged
// connector reads.  Three overlapping claims come out of that --- the value
// that arrives satisfies the complement, the value that arrives is one that
// was sent, and the value that arrives after the levels have stood is the one
// standing --- and a dropped line, a crossed pair or a stale half fails at
// least one of them by construction rather than by luck.
//
// **THE TWO ENDS ARE TWO BOARDS AND THEIR CLOCKS ARE NOT THE SAME CLOCK.**
// One phase runs the model at a twelfth of a tick so that the two ends can be
// given different periods and a phase offset, and the wires a delay each.
// That is the only place the carrier's one asynchronous crossing is really
// asked anything: on a common clock a strobe sampled through two flops is a
// strobe sampled against itself.
//
// WHAT IS MEASURED AND REPORTED RATHER THAN ASSUMED, on the check's own
// output: the worst end-to-end delay of a level, the worst round trip of a
// whole debug transaction against the 1,105 ticks a debugger waits before it
// gives up, the shortest lift that still latches at the far end, and the
// largest strobe-to-data skew the sampling survives.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <vector>

#include "Vcadr_dbg_pmod_harness.h"
#include "verilated.h"

namespace {

// The carrier's own four, as the harness overrides them.  A frame is
// BEATS * BEAT_T + GAP_T ticks, and BEATS is eight: twenty payload bits and
// the two-bit marker over three lines.
constexpr int kBeats = 8;
constexpr int kBeatT = 6;
constexpr int kGapT = 18;
constexpr long kFrameT = kBeats * kBeatT + kGapT;    // 66
constexpr long kLossT = 512;

// busint::DEBUG_TIMEOUT_NS, the REQTIM PROM's second table, at the 10 ns
// tick: what a debugger waits before it gives up on a cycle.  Every round
// trip this check measures is reported against it.
constexpr long kDebugTimeoutT = 1105;

// The window's words and the fields of `CTL` and `STS`, from
// `rtl/plumbing/cadr_debug_window.sv` and muir's `src/fabric.rs`.
constexpr uint32_t kRegBase = 0x8000'1000u;
constexpr unsigned kWIdent = 0, kWCtl = 1, kWSts = 2, kWClear = 3,
                   kWFaults = 4;
constexpr uint32_t kIdent = 0x4442'5547u;   // "DBUG"
constexpr uint32_t kLift = 0x4C49'4654u;    // "LIFT"
constexpr uint32_t kReq = 1u;
constexpr uint32_t kWrBit = 1u << 1;
constexpr uint32_t kAShift = 2;
constexpr uint32_t kSeqShift = 8;
constexpr uint32_t kDbdShift = 16;
constexpr uint32_t kStanding = 1u;
constexpr uint32_t kAckBit = 1u << 1;
constexpr uint32_t kDrvBit = 1u << 3;
constexpr uint32_t kMarkMask = 3u << 14;
constexpr uint32_t kMark = 1u << 14;

// busint::DEBUG_CYCLE and the three after it.
constexpr unsigned kACycle = 0, kAStatus = 1, kAModifier = 2, kAAddress = 3;

// spy::BASE and the registers CC uses: `spy::CLK` is 3 and a store of zero
// there is a halt, muir/tests/lashup.rs.
constexpr uint32_t kSpyBase = 0766000u;
constexpr unsigned kSpyClk = 3;
uint32_t SpyAddr(unsigned e) { return kSpyBase + 2u * e; }

// An address on this machine's Unibus that no slave in this harness claims:
// below the diagnostic block, and the I/O board is not in this harness at all.
constexpr uint32_t kDeadAddr = 0760000u;

// **THE ADDRESS LATCH IS `UAO<16:1>` AND BIT 17 IS IN THE MODIFIER
// REGISTER.**  MIT's own note is that bit 0 of the address is not sent over
// the cable, and the two 74LS374s hold sixteen bits above it; the eighteenth
// is modifier bit 0.  So the diagnostic block at `0o766000` cannot be reached
// by the latch alone --- which is a property of the cable and not of this
// carrier, and is the reason the modifier is left at 1 below.
uint16_t LatchWord(uint32_t uaddr) {
  return static_cast<uint16_t>((uaddr >> 1) & 0xFFFFu);
}
unsigned LatchTop(uint32_t uaddr) { return (uaddr >> 17) & 1u; }

// `Machine::debug_status`'s byte, from outside: a value the module cannot
// have invented, with both halves distinct and neither 0x00 nor 0xFF.
constexpr uint8_t kErrStatus = 0x5Au;

int bad = 0;
long tick = 0;
// Frames that arrived at either end of the carrier-alone pair, and frames
// refused: the two numbers the connector reports to the console.
long done_seen = 0, bad_seen = 0;

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  if (bad < 30) {
    std::fprintf(stderr, "tick %ld: %s is 0x%llx, wanting 0x%llx\n", tick, what,
                 got, want);
  }
  ++bad;
}

void Say(const char *what) {
  if (bad < 30) std::fprintf(stderr, "tick %ld: %s\n", tick, what);
  ++bad;
}

// The processor's sixteen-way diagnostic mux, answered from outside and
// injective in the register number, so that a road reading the wrong register
// says so.  The same idiom `tb/cadr_gp1_split_tb.cpp` uses and for the same
// reason.
uint16_t SpyPoison(unsigned eadr) {
  return static_cast<uint16_t>(0xA500u ^ (eadr * 0x1111u) ^ (eadr << 12));
}

// The carrier's poison: the low half the complement of the high half, so
// that any single dropped or crossed line breaks a relation the receiver
// cannot repair, and no value is zero or all ones.
uint32_t Poison(unsigned i) {
  const uint32_t h = (0x155u + i * 0x0A7u) & 0x3FFu;
  return ((h << 10) | (~h & 0x3FFu)) & 0xFFFFFu;
}

bool PoisonWellFormed(uint32_t v) {
  return ((v >> 10) & 0x3FFu) == ((~v) & 0x3FFu);
}

// ------------------------------------------------------------------ a wire
//
// One line of the cable: a history of what has been driven onto it, read back
// a settable number of evaluation points later, with the faults a wire can
// have.  `force` is a short to a rail and `inv` two ends of a pair swapped.
struct Wire {
  uint32_t hist = 0;
  int delay = 0;
  int force = -1;
  bool inv = false;

  void Push(int v) { hist = (hist << 1) | static_cast<uint32_t>(v & 1); }
  int Get() const {
    if (force >= 0) return force;
    const int v = static_cast<int>((hist >> delay) & 1u);
    return inv ? !v : v;
  }
  void Clear() {
    hist = 0;
    delay = 0;
    force = -1;
    inv = false;
  }
};

// ------------------------------------------------------------- a connector
//
// Eight wires: one strobe and three data each way.  `perm` is the order the
// three data lines of the A-to-B half arrive in, so that crossing two of them
// is one line of stimulus.
struct Link {
  Wire ab[4];
  Wire ba[4];
  bool cut_ab = false;
  bool cut_ba = false;
  int perm[3] = {0, 1, 2};

  void Reset() {
    for (int k = 0; k < 4; ++k) {
      ab[k].Clear();
      ba[k].Clear();
    }
    cut_ab = false;
    cut_ba = false;
    perm[0] = 0;
    perm[1] = 1;
    perm[2] = 2;
  }

  void Push(int a_stb, int a_d, int b_stb, int b_d) {
    ab[0].Push(a_stb);
    ba[0].Push(b_stb);
    for (int k = 0; k < 3; ++k) {
      ab[1 + k].Push((a_d >> k) & 1);
      ba[1 + k].Push((b_d >> k) & 1);
    }
  }

  // What the B end sees, and what the A end sees.  An unplugged connector
  // reads zero: the pins carry a pull-down and the strobe then never moves,
  // which is the state `cadr_dbg_rx.sv` calls not live.
  int BStb() const { return cut_ab ? 0 : ab[0].Get(); }
  int BD() const {
    if (cut_ab) return 0;
    int v = 0;
    for (int k = 0; k < 3; ++k) v |= ab[1 + perm[k]].Get() << k;
    return v;
  }
  int AStb() const { return cut_ba ? 0 : ba[0].Get(); }
  int AD() const {
    if (cut_ba) return 0;
    int v = 0;
    for (int k = 0; k < 3; ++k) v |= ba[1 + k].Get() << k;
    return v;
  }
};

Vcadr_dbg_pmod_harness *d = nullptr;
Link link_p;   // the carrier alone
Link link_o;   // the carrier in the debugger's path

// What the carrier alone has been given, so that a value arriving can be
// asked whether it was ever sent.
std::set<uint32_t> sent_ab, sent_ba;
long worst_level_delay = 0;

// One evaluation of the model with the two clocks as given.  The cable is
// wired here and nowhere else: inputs from the wires' histories before, the
// outputs pushed into them after.
void EvalPoint(int clk_a, int clk_b) {
  d->spy_rdata = SpyPoison(d->spy_eadr);
  d->pb_stb_i = static_cast<uint8_t>(link_p.BStb());
  d->pb_d_i = static_cast<uint8_t>(link_p.BD());
  d->pa_stb_i = static_cast<uint8_t>(link_p.AStb());
  d->pa_d_i = static_cast<uint8_t>(link_p.AD());
  d->ob_stb_i = static_cast<uint8_t>(link_o.BStb());
  d->ob_d_i = static_cast<uint8_t>(link_o.BD());
  d->oa_stb_i = static_cast<uint8_t>(link_o.AStb());
  d->oa_d_i = static_cast<uint8_t>(link_o.AD());
  d->clk = static_cast<uint8_t>(clk_a);
  d->clk_b = static_cast<uint8_t>(clk_b);
  d->eval();
  // **A FRAME ARRIVED, AND WHETHER IT WAS TAKEN.**  Sampled at every eval
  // point rather than once a tick, because the two boards are clocked apart in
  // the asynchronous phase and a one-tick term at one end is not visible at the
  // other's edge.  A Pmod row is routed as coupled pairs and this link drives
  // all four single-ended, so what an edge coupling into a strobe costs is
  // refused frames; the connector counts them for the console, and this counts
  // the same terms so that a leg can ask whether the fault it injected was
  // seen as one.
  if (d->p_done_a) ++done_seen;
  if (d->p_done_b) ++done_seen;
  if (d->p_bad_a) ++bad_seen;
  if (d->p_bad_b) ++bad_seen;
  link_p.Push(d->pa_stb_o, d->pa_d_o, d->pb_stb_o, d->pb_d_o);
  link_o.Push(d->oa_stb_o, d->oa_d_o, d->ob_stb_o, d->ob_d_o);
}

// A tick with both boards clocked together.  Every phase but the asynchronous
// one runs here, because the carrier's arithmetic and the debug cycle it
// carries do not need a twelfth of a tick to be asked anything.
void Tick() {
  EvalPoint(0, 0);
  EvalPoint(1, 1);
  ++tick;
}

void Idle(long n) {
  for (long k = 0; k < n; ++k) Tick();
}

// --------------------------------------------------------------- the port
//
// A single-beat master on the window's port.  The protocol's own corners are
// `build/gp1_split.pass`'s business; what is wanted here is a store and a
// load that complete.
void Quiet() {
  d->s_awvalid = 0;
  d->s_wvalid = 0;
  d->s_bready = 0;
  d->s_arvalid = 0;
  d->s_rready = 0;
  d->s_wlast = 0;
}

void AxiWrite(uint32_t addr, uint32_t data, uint32_t strb = 0xFu) {
  d->s_awaddr = addr;
  d->s_awlen = 0;
  d->s_awid = 5;
  d->s_wdata = data;
  d->s_wstrb = static_cast<uint8_t>(strb);
  d->s_wlast = 1;
  bool aw = false, w = false, b = false;
  long guard = 0;
  while (!b) {
    d->s_awvalid = aw ? 0 : 1;
    d->s_wvalid = (aw && !w) ? 1 : 0;
    d->s_bready = w ? 1 : 0;
    // **BOTH BOARDS ARE CLOCKED THROUGH AN AXI TRANSACTION**, which is worth
    // saying because the first draft clocked only the debugger's: the far
    // end then stood still for the whole of a poll and no acknowledgement
    // ever came back, which reads exactly like a carrier that drops the
    // return path.
    EvalPoint(0, 0);
    const bool aw_hs = d->s_awvalid && d->s_awready;
    const bool w_hs = d->s_wvalid && d->s_wready;
    const bool b_hs = d->s_bready && d->s_bvalid;
    EvalPoint(1, 1);
    ++tick;
    if (aw_hs) aw = true;
    if (w_hs) w = true;
    if (b_hs) b = true;
    if (++guard > 200) {
      Say("a store to the window never completed");
      break;
    }
  }
  Quiet();
}

uint32_t AxiRead(uint32_t addr) {
  d->s_araddr = addr;
  d->s_arlen = 0;
  d->s_arid = 6;
  bool ar = false;
  uint32_t out = 0;
  long guard = 0;
  for (;;) {
    d->s_arvalid = ar ? 0 : 1;
    d->s_rready = ar ? 1 : 0;
    EvalPoint(0, 0);
    const bool ar_hs = d->s_arvalid && d->s_arready;
    const bool r_hs = d->s_rready && d->s_rvalid;
    if (r_hs) out = d->s_rdata;
    EvalPoint(1, 1);
    ++tick;
    if (ar_hs) ar = true;
    if (r_hs) break;
    if (++guard > 200) {
      Say("a load from the window never completed");
      break;
    }
  }
  Quiet();
  return out;
}

uint32_t CtlWord(unsigned a, bool wr, uint16_t dbd, unsigned seq, bool req) {
  uint32_t w = (static_cast<uint32_t>(dbd) << kDbdShift) |
               ((seq & 0xFu) << kSeqShift) | ((a & 3u) << kAShift);
  if (wr) w |= kWrBit;
  if (req) w |= kReq;
  return w;
}

// A whole transaction over the cable: the request, the wait for the
// acknowledgement to come back across, the lift, and the hold that lets the
// lift cross so that the far end's latches take what is standing.
//
// **THE HOLD IS THE CARRIER'S OWN REQUIREMENT AND IS NOT IN THE WINDOW.** On
// the direct cable a lift is seen at the next tick and the structural margin
// is four; over eight pins the lift is a level like any other and has to
// cross a frame.  A debugger that lifted and asked again inside that would
// have the far end see one request where it made two, so the hold is swept
// and reported below rather than assumed.
long last_round_trip = 0;

uint32_t CableReq(unsigned a, bool wr, uint16_t dbd, unsigned seq, long bound,
                  long hold = 3 * kFrameT) {
  const uint32_t w = CtlWord(a, wr, dbd, seq, true);
  AxiWrite(kRegBase + 4 * kWCtl, w);
  const long began = tick;
  uint32_t sts = 0;
  for (;;) {
    sts = AxiRead(kRegBase + 4 * kWSts);
    if (sts & kAckBit) break;
    if (tick - began > bound) break;
  }
  last_round_trip = tick - began;
  AxiWrite(kRegBase + 4 * kWCtl, CtlWord(a, wr, dbd, seq, false));
  Idle(hold);
  return sts;
}

// The value the debuggee put on `DBD<15:0>`, as `STS` recorded it.
uint16_t StsDbd(uint32_t sts) { return static_cast<uint16_t>(sts >> 16); }

void ResetBoth() {
  link_p.Reset();
  link_o.Reset();
  d->rst = 1;
  d->rst_b = 1;
  Quiet();
  // Poison out of reset as well, because the first frame a receiver takes is
  // whatever was standing while it locked on, and a check that could not name
  // that value would report the carrier working correctly as a fault.
  d->p_tx_a = Poison(0);
  d->p_tx_b = Poison(70);
  sent_ab.insert(Poison(0));
  sent_ba.insert(Poison(70));
  d->loc_req = 0;
  d->loc_wr = 0;
  d->loc_a = 0;
  d->loc_dbd = 0;
  d->err_status = kErrStatus;
  d->cpu_msyn = 0;
  d->cpu_write = 0;
  d->cpu_addr = 0;
  d->cpu_wdata = 0;
  Idle(8);
  d->rst = 0;
  d->rst_b = 0;
  Idle(4);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vcadr_dbg_pmod_harness;

  ResetBoth();

  // ================================================================ phase 1
  //
  // The carrier alone, both directions at once, an ideal wire, and poison.
  // What this asks is the whole of the property: a level put in at one end
  // stands at the other, whole, inside a bound --- and nothing else ever
  // appears there.
  std::fprintf(stderr, "phase 1: the carrier alone, poisoned both ways\n");
  {
    // Let the two ends lock on before anything is claimed: a receiver that
    // has just come up is between frames and takes the next gap as its
    // boundary.
    Idle(3 * kFrameT);
    if (!d->p_live_a || !d->p_live_b)
      Say("the carrier is not live after three frames of an ideal wire");

    long values = 0;
    for (unsigned i = 0; i < 24; ++i) {
      const uint32_t va = Poison(i);
      const uint32_t vb = Poison(i + 71);   // a different walk each way, so
                                            // that the two directions cannot
                                            // be each other
      d->p_tx_a = va;
      d->p_tx_b = vb;
      sent_ab.insert(va);
      sent_ba.insert(vb);
      long got_ab = -1, got_ba = -1;
      for (long k = 0; k < 4 * kFrameT; ++k) {
        Tick();
        if (d->p_live_b && !PoisonWellFormed(d->p_rx_b))
          Fail("a value at the B end is not one this check can have sent",
               d->p_rx_b, va);
        if (d->p_live_a && !PoisonWellFormed(d->p_rx_a))
          Fail("a value at the A end is not one this check can have sent",
               d->p_rx_a, vb);
        if (d->p_live_b && sent_ab.find(d->p_rx_b) == sent_ab.end())
          Fail("the B end shows a value that was never sent", d->p_rx_b, va);
        if (d->p_live_a && sent_ba.find(d->p_rx_a) == sent_ba.end())
          Fail("the A end shows a value that was never sent", d->p_rx_a, vb);
        if (got_ab < 0 && d->p_rx_b == va) got_ab = k;
        if (got_ba < 0 && d->p_rx_a == vb) got_ba = k;
      }
      if (got_ab < 0) Fail("the B end never took the level", d->p_rx_b, va);
      if (got_ba < 0) Fail("the A end never took the level", d->p_rx_a, vb);
      if (got_ab > worst_level_delay) worst_level_delay = got_ab;
      if (got_ba > worst_level_delay) worst_level_delay = got_ba;
      ++values;
    }
    std::fprintf(stderr,
                 "  %ld levels each way delivered whole; worst delay %ld ticks "
                 "against a frame of %ld\n",
                 values, worst_level_delay, kFrameT);
    if (worst_level_delay > 2 * kFrameT)
      Fail("the worst level delay", static_cast<unsigned long long>(worst_level_delay),
           static_cast<unsigned long long>(2 * kFrameT));
  }

  // ================================================================ phase 2
  //
  // The same, with the two ends on two clocks.  Twelve evaluation points a
  // tick, the B end given a different period and a phase of its own, and each
  // wire a delay --- which is the only configuration in this file where the
  // carrier's one asynchronous crossing is asked anything at all.
  std::fprintf(stderr, "phase 2: two boards, two clocks, a wire with delay\n");
  {
    struct Case {
      int pa, pb, phase, delay;
      const char *what;
    };
    const Case cases[] = {
        {12, 12, 0, 0, "the same period, in phase"},
        {12, 12, 5, 2, "the same period, out of phase"},
        {12, 13, 3, 3, "the far end 8 per cent slower"},
        {13, 12, 7, 1, "the far end 8 per cent faster"},
        {12, 11, 2, 5, "the far end 9 per cent faster, a long wire"},
    };
    for (const Case &c : cases) {
      ResetBoth();
      for (int k = 0; k < 4; ++k) {
        link_p.ab[k].delay = c.delay;
        link_p.ba[k].delay = c.delay;
      }
      long sub = 0;
      const long per_value = 6L * kFrameT * 12;
      for (unsigned i = 0; i < 6; ++i) {
        const uint32_t va = Poison(i + 200);
        const uint32_t vb = Poison(i + 311);
        d->p_tx_a = va;
        d->p_tx_b = vb;
        sent_ab.insert(va);
        sent_ba.insert(vb);
        bool ab_ok = false, ba_ok = false;
        for (long u = 0; u < per_value; ++u, ++sub) {
          const int ca = ((sub % c.pa) < c.pa / 2) ? 1 : 0;
          const int cb = (((sub + c.phase) % c.pb) < c.pb / 2) ? 1 : 0;
          EvalPoint(ca, cb);
          if (d->p_live_b && !PoisonWellFormed(d->p_rx_b))
            Fail("a malformed value at the B end", d->p_rx_b, va);
          if (d->p_live_a && !PoisonWellFormed(d->p_rx_a))
            Fail("a malformed value at the A end", d->p_rx_a, vb);
          if (d->p_rx_b == va) ab_ok = true;
          if (d->p_rx_a == vb) ba_ok = true;
        }
        if (!ab_ok) {
          std::fprintf(stderr, "  %s: ", c.what);
          Fail("the B end never took the level", d->p_rx_b, va);
        }
        if (!ba_ok) {
          std::fprintf(stderr, "  %s: ", c.what);
          Fail("the A end never took the level", d->p_rx_a, vb);
        }
      }
      std::fprintf(stderr, "  %s: six levels each way, delivered\n", c.what);
    }
  }

  // ================================================================ phase 3
  //
  // What a cable does when it is wrong.  Each case asserts the SPECIFIC thing
  // the design claims: a connector with nothing in it is not live, one pulled
  // out stops being live inside the dead-man, and a frame of all ones or all
  // zeros is refused by the marker rather than taken as twenty levels.
  std::fprintf(stderr, "phase 3: an unplugged cable, a dead one, and a bad one\n");
  {
    // Nothing plugged in at all.
    ResetBoth();
    link_p.cut_ab = true;
    link_p.cut_ba = true;
    d->p_tx_a = Poison(3);
    d->p_tx_b = Poison(9);
    Idle(4 * kFrameT);
    if (d->p_live_a || d->p_live_b)
      Say("an unplugged connector came up live");
    if (d->p_rx_a != 0 || d->p_rx_b != 0)
      Fail("an unplugged connector is not showing the idle cable", d->p_rx_b, 0);

    // Plugged in, running, and then pulled out.
    ResetBoth();
    d->p_tx_a = Poison(4);
    d->p_tx_b = Poison(11);
    Idle(4 * kFrameT);
    if (!d->p_live_b) Say("the carrier is not live before the cable is pulled");
    if (d->p_rx_b != Poison(4)) Fail("the level before the pull", d->p_rx_b, Poison(4));
    link_p.cut_ab = true;
    long fell = -1;
    for (long k = 0; k < kLossT + 4 * kFrameT; ++k) {
      Tick();
      if (fell < 0 && !d->p_live_b) fell = k;
    }
    if (fell < 0) {
      Say("the carrier never noticed the cable had gone");
    } else {
      if (d->p_rx_b != 0)
        Fail("a pulled cable left the levels standing", d->p_rx_b, 0);
      // `loss_t` has been counting since the LAST GOOD FRAME, which may be
      // most of a frame before the cable was pulled, so the earliest it can
      // fire is a frame short of the interval.  Measured before it was
      // written this way: 505 ticks against a dead man of 512.
      if (fell < kLossT - kFrameT)
        Fail("the dead man fired early", static_cast<unsigned long long>(fell),
             static_cast<unsigned long long>(kLossT - kFrameT));
      std::fprintf(stderr,
                   "  a pulled cable stopped being live %ld ticks later, the "
                   "dead man being %ld\n",
                   fell, kLossT);
    }

    // The marker's own claim: neither a rail can be mistaken for a frame.
    // The strobe still moves, so beats keep arriving; what stops them being
    // taken is the marker and the fill.
    for (int rail = 0; rail <= 1; ++rail) {
      ResetBoth();
      d->p_tx_a = Poison(6);
      Idle(4 * kFrameT);
      if (!d->p_live_b) Say("not live before a rail is applied");
      for (int k = 1; k < 4; ++k) link_p.ab[k].force = rail;
      long gone = -1;
      for (long k = 0; k < kLossT + 4 * kFrameT; ++k) {
        Tick();
        if (gone < 0 && !d->p_live_b) gone = k;
      }
      if (gone < 0) {
        Say(rail ? "a frame of all ones was taken as a word"
                 : "a frame of all zeros was taken as a word");
      }
    }
    std::fprintf(stderr, "  all ones and all zeros both refused by the marker\n");

    // A single line shorted, and two lines crossed.  Neither is guaranteed to
    // break the marker --- only beat zero and one bit of beat one carry it ---
    // so what is asserted is that the fault is VISIBLE: either the frame stops
    // being taken, or what arrives is not what was sent.
    int seen = 0, cases = 0;
    for (int line = 0; line < 3; ++line) {
      for (int rail = 0; rail <= 1; ++rail) {
        ResetBoth();
        const uint32_t v = Poison(13 + line * 2 + rail);
        d->p_tx_a = v;
        sent_ab.insert(v);
        Idle(4 * kFrameT);
        link_p.ab[1 + line].force = rail;
        Idle(kLossT + 4 * kFrameT);
        ++cases;
        const bool visible = !d->p_live_b || d->p_rx_b != v;
        if (visible) ++seen;
        else Fail("a shorted data line was invisible", d->p_rx_b, v);
      }
    }
    for (int i = 0; i < 3; ++i) {
      const int j = (i + 1) % 3;
      ResetBoth();
      const uint32_t v = Poison(31 + i);
      d->p_tx_a = v;
      sent_ab.insert(v);
      Idle(4 * kFrameT);
      link_p.perm[i] = j;
      link_p.perm[j] = i;
      Idle(kLossT + 4 * kFrameT);
      ++cases;
      const bool visible = !d->p_live_b || d->p_rx_b != v;
      if (visible) ++seen;
      else Fail("two crossed data lines were invisible", d->p_rx_b, v);
    }
    std::fprintf(stderr, "  %d of %d shorted or crossed lines were visible\n",
                 seen, cases);
    // **AND EVERY ONE OF THEM WAS COUNTED AS A REFUSAL**, which is the other
    // half of what "visible" means.  A Pmod row is routed as coupled pairs and
    // this link drives all four single-ended, so an edge on one line can couple
    // into the strobe beside it; what that costs is refused frames, and the
    // count is how often.  A counter that could only read zero would report a
    // perfect cable whatever the cable was doing.
    if (bad_seen == 0)
      Fail("frames counted as refused over lines that were shorted and crossed", 0, 1);
  }

  // ================================================================ phase 4
  //
  // How much the strobe may be skewed against the data and still be sampled
  // in the right beat.  Measured rather than asserted: the design's claim is
  // that the margin is most of a beat, and this says how much of it there is.
  std::fprintf(stderr, "phase 4: the strobe skewed against the data\n");
  {
    int worst_early = 0, worst_late = 0;
    for (int skew = -8; skew <= 8; ++skew) {
      ResetBoth();
      // A positive skew delays the strobe against the data, a negative one
      // the data against the strobe.  Evaluation points are half a tick, so
      // eight of them is four ticks either way.
      const int base = 8;
      link_p.ab[0].delay = base + (skew > 0 ? skew : 0);
      for (int k = 1; k < 4; ++k) link_p.ab[k].delay = base + (skew < 0 ? -skew : 0);
      d->p_tx_a = Poison(50);
      sent_ab.insert(Poison(50));
      Idle(6 * kFrameT);
      const bool ok = d->p_live_b && d->p_rx_b == Poison(50);
      if (ok) {
        if (skew < 0 && -skew > worst_early) worst_early = -skew;
        if (skew > 0 && skew > worst_late) worst_late = skew;
      }
    }
    std::fprintf(stderr,
                 "  the strobe survives %d evaluation points early and %d "
                 "late --- a point is half a tick and a beat is %d ticks\n",
                 worst_early, worst_late, kBeatT);
    if (worst_early < 2 || worst_late < 2)
      Say("the sampling margin is under a tick either side");
  }

  // ================================================================ phase 5
  //
  // A real debug cycle, over the cable.  The window is a debugger on one
  // board, `cadr_dbgin.sv` the debuggee on another, and between them eight
  // pins.  Everything from here is the composed path and nothing is stimulus
  // except the cable itself.
  std::fprintf(stderr, "phase 5: a debugger over eight pins\n");
  ResetBoth();
  Idle(4 * kFrameT);
  {
    const uint32_t id = AxiRead(kRegBase + 4 * kWIdent);
    if (id != kIdent) Fail("IDENT", id, kIdent);
    if (!d->out_live_o || !d->in_live_o)
      Say("the connector is not live with a cable in it");
  }

  // The address latch, swept: eight addresses, each of them a word the far
  // end can only have got over the cable, and each read back at the harness's
  // own `address_o`.  This is the whole of the outgoing twenty --- the two
  // address bits pick the strobe and the sixteen data lines carry the word.
  {
    long worst = 0;
    const uint16_t words[] = {0x0000, 0xFFFF, 0xA5C3, 0x5A3C,
                              0x8001, 0x7FFE, 0x1234, 0xEDCB};
    for (unsigned i = 0; i < sizeof(words) / sizeof(words[0]); ++i) {
      const uint32_t sts =
          CableReq(kAAddress, false, words[i], (i + 1) & 0xF, 4000);
      if ((sts & kMarkMask) != kMark) Fail("STS has no marker", sts & kMarkMask, kMark);
      if (!(sts & kAckBit)) Say("a latch strobe was never acknowledged");
      if (sts & kDrvBit) Say("the debuggee drove DBD under -DB ADR0 CLK");
      if (d->address_o != words[i])
        Fail("the address latch after a strobe over the cable", d->address_o,
             words[i]);
      if (last_round_trip > worst) worst = last_round_trip;
    }
    std::fprintf(stderr,
                 "  eight addresses latched over the cable; worst round trip "
                 "%ld ticks, the debugger gives up at %ld\n",
                 worst, kDebugTimeoutT);
    if (worst >= kDebugTimeoutT)
      Fail("the round trip", static_cast<unsigned long long>(worst),
           static_cast<unsigned long long>(kDebugTimeoutT));
  }

  // The modifier register: three bits out of `DBD<2:0>`, and bit 1 is this
  // machine's reset, so the sweep stays clear of it --- a stray one there
  // halts the machine, which is the hazard the join exists to keep out.
  {
    for (unsigned m = 0; m < 8; ++m) {
      if (m & 2u) continue;
      const uint32_t sts = CableReq(kAModifier, false,
                                    static_cast<uint16_t>(0xFF00u | m), m, 4000);
      if (!(sts & kAckBit)) Say("a modifier strobe was never acknowledged");
      if (d->modifier_o != m) Fail("the modifier register", d->modifier_o, m);
    }
    // And left at 1, which is address bit 17: every Unibus cycle below is to
    // the diagnostic block at `0o766000` and the latch cannot carry that bit.
    CableReq(kAModifier, false, 0x0001, 1, 4000);
    if (d->modifier_o != 1) Fail("the modifier before the cycles", d->modifier_o, 1);
  }

  // The status read, which is the return path's own claim: the Am8304 at
  // REQERR 0B15 drives `DBD<7:0>` and nothing above it, so what comes back is
  // `0xff00 | status` --- the high byte the cable's pull-ups and not this
  // board's.  A byte-wise enable that the carrier failed to carry would show
  // here and nowhere else.
  {
    const uint32_t sts = CableReq(kAStatus, false, 0x0000, 7, 4000);
    if (!(sts & kAckBit)) Say("-DB READ STATUS was never acknowledged");
    if (!(sts & kDrvBit)) Say("the debuggee drove nothing under -DB READ STATUS");
    const uint16_t want = static_cast<uint16_t>(0xFF00u | kErrStatus);
    if (StsDbd(sts) != want) Fail("the status byte over the cable", StsDbd(sts), want);
  }

  // The cycle: all sixteen diagnostic registers, read over MIT's own cable
  // and carried on eight pins.  `spy_rdata` is injective in the register
  // number, so a road that reads the wrong register says which.
  {
    long worst = 0;
    for (unsigned e = 0; e < 16; ++e) {
      if (LatchTop(SpyAddr(e)) != 1) Say("the diagnostic block moved");
      CableReq(kAAddress, false, LatchWord(SpyAddr(e)), e, 4000);
      const uint32_t sts = CableReq(kACycle, false, 0x0000, e, 6000);
      if (!(sts & kAckBit)) {
        Say("a read cycle over the cable was never acknowledged");
        continue;
      }
      if (!(sts & kDrvBit)) Say("the debuggee drove nothing on a read cycle");
      if (StsDbd(sts) != SpyPoison(e))
        Fail("a diagnostic register read over the cable", StsDbd(sts),
             SpyPoison(e));
      if (last_round_trip > worst) worst = last_round_trip;
    }
    std::fprintf(stderr,
                 "  sixteen diagnostic registers read over the cable; worst "
                 "round trip %ld ticks\n",
                 worst);
    if (worst >= kDebugTimeoutT)
      Fail("a cycle's round trip", static_cast<unsigned long long>(worst),
           static_cast<unsigned long long>(kDebugTimeoutT));
  }

  // The halt: CC's first act on a debuggee is `spy_write(CLK, 0)`, which is
  // an ordinary Unibus write at `0o766006`.  Over eight pins it is the same
  // write and it has to have the same effect.
  {
    if (!d->run_o) Say("the machine is not running before the halt");
    CableReq(kAAddress, false, LatchWord(SpyAddr(kSpyClk)), 2, 4000);
    const uint32_t sts = CableReq(kACycle, true, 0x0000, 3, 6000);
    if (!(sts & kAckBit)) Say("the halt was never acknowledged");
    if (d->run_o) Say("RUN is still set after a halt over the cable");
    const uint32_t back = CableReq(kACycle, true, 0x0001, 4, 6000);
    if (!(back & kAckBit)) Say("the start was never acknowledged");
    if (!d->run_o) Say("RUN did not come back after a start over the cable");
    std::fprintf(stderr, "  the machine halted and started again over the cable\n");
  }

  // A cycle nothing answers is never acknowledged, over the cable as on it:
  // there is no timeout for this master and the debugger is what gives up.
  {
    if (LatchTop(kDeadAddr) != 1) Say("the dead address moved");
    CableReq(kAAddress, false, LatchWord(kDeadAddr), 5, 4000);
    const uint32_t w = CtlWord(kACycle, false, 0x0000, 6, true);
    AxiWrite(kRegBase + 4 * kWCtl, w);
    long saw = -1;
    for (long k = 0; k < 3000; ++k) {
      Tick();
      const uint32_t sts = AxiRead(kRegBase + 4 * kWSts);
      if (sts & kAckBit) {
        saw = k;
        break;
      }
      if (tick > 200000) break;
    }
    if (saw >= 0) Say("a cycle at an address nothing answers was acknowledged");
    AxiWrite(kRegBase + 4 * kWClear, kLift);
    Idle(3 * kFrameT);
  }

  // ================================================================ phase 6
  //
  // The lift, swept.  A carrier that carries levels makes the lift a level,
  // and a debugger that lifts and asks again inside one frame makes one
  // request where it meant two.  The shortest hold that still latches is
  // measured here and belongs in the module's header rather than in anyone's
  // memory.
  std::fprintf(stderr, "phase 6: the shortest lift that still latches\n");
  {
    long shortest = -1;
    for (long hold = 8; hold <= 4 * kFrameT; hold += 8) {
      // Put a word the far end cannot already be holding into the latch.
      const uint16_t want = static_cast<uint16_t>(0x4000u ^ (hold * 7));
      // Clear the way: a properly held transaction first, so that the state
      // the sweep starts from is the same every time.
      CableReq(kAAddress, false, 0x0000, 1, 4000);
      AxiWrite(kRegBase + 4 * kWCtl, CtlWord(kAAddress, false, want, 2, true));
      Idle(3 * kFrameT);
      AxiWrite(kRegBase + 4 * kWCtl, CtlWord(kAAddress, false, want, 2, false));
      Idle(hold);
      const bool took = (d->address_o == want);
      Idle(3 * kFrameT);
      if (took && shortest < 0) shortest = hold;
      if (shortest >= 0 && hold >= shortest && d->address_o != want)
        Fail("a lift held longer than the shortest that worked did not latch",
             d->address_o, want);
    }
    if (shortest < 0) {
      Say("no lift in four frames ever latched at the far end");
    } else {
      std::fprintf(stderr,
                   "  the shortest lift that latches is %ld ticks, a frame "
                   "being %ld\n",
                   shortest, kFrameT);
      if (shortest > 2 * kFrameT)
        Fail("the shortest lift", static_cast<unsigned long long>(shortest),
             static_cast<unsigned long long>(2 * kFrameT));
    }
  }

  // ================================================================ phase 7
  //
  // Two debuggers at one DBGIN page.  `cadr_dbg_join.sv`'s rule is that the
  // first to assert holds until it lifts, and the near arm wins a tie.  What
  // makes this worth a check is what the obvious merge would do instead: a
  // request built half from one debugger and half from the other can put a
  // stray one in the modifier register's bit 1, which resets this machine.
  std::fprintf(stderr, "phase 7: two debuggers, and which of them has it\n");
  {
    // The connector has it: a request is standing over the cable, and the
    // near arm asserts in the middle of it.
    const uint32_t w = CtlWord(kAAddress, false, 0xBEEF, 9, true);
    AxiWrite(kRegBase + 4 * kWCtl, w);
    Idle(3 * kFrameT);
    if (!d->cab_req_o) Say("the connector's request never reached the page");
    if (d->holder_o != 1) Say("the connector does not hold the page");
    d->loc_req = 1;
    d->loc_wr = 1;
    d->loc_a = 2;              // -DB ADR1 CLK: the modifier register
    d->loc_dbd = 0x0002;       // and bit 1, which would reset this machine
    for (long k = 0; k < 2 * kFrameT; ++k) {
      Tick();
      if (d->holder_o != 1) Say("the page changed hands inside a request");
      if (d->cab_a_o != 3) Fail("the address bits inside a request", d->cab_a_o, 3);
      if (d->cab_dbd_o != 0xBEEF)
        Fail("the data lines inside a request", d->cab_dbd_o, 0xBEEF);
      if (d->debuggee_reset_o) Say("the near arm reset the machine mid-request");
    }
    // The connector lifts.  The near arm's request is then taken, and the
    // far end's latch must have got the connector's word and not the near
    // arm's.
    AxiWrite(kRegBase + 4 * kWCtl, CtlWord(kAAddress, false, 0xBEEF, 9, false));
    Idle(3 * kFrameT);
    if (d->address_o != 0xBEEF)
      Fail("the latch took the wrong debugger's word", d->address_o, 0xBEEF);
    if (d->holder_o != 0) Say("the near arm did not get the page after the lift");
    if (d->cab_req_o != 1) Say("the near arm's request is not at the page");

    // The near arm lifts; nothing was latched from it but the modifier,
    // which it asked for, so put it back.
    d->loc_dbd = 0x0000;
    Idle(4);
    d->loc_req = 0;
    Idle(3 * kFrameT);
    if (d->modifier_o != 0) Fail("the modifier after the near arm's lift", d->modifier_o, 0);
    if (d->debuggee_reset_o) Say("the machine is held in reset after phase 7");

    // And the other way round: the near arm first, and the connector cannot
    // take the page from it.
    d->loc_req = 1;
    d->loc_a = 3;
    d->loc_dbd = 0x1357;
    Idle(4);
    if (d->holder_o != 0) Say("the near arm did not get an idle page");
    AxiWrite(kRegBase + 4 * kWCtl, CtlWord(kAAddress, false, 0x2468, 10, true));
    for (long k = 0; k < 3 * kFrameT; ++k) {
      Tick();
      if (d->holder_o != 0) Say("the connector took the page from the near arm");
    }
    d->loc_req = 0;
    Idle(8);
    if (d->address_o != 0x1357)
      Fail("the near arm's own word was not latched", d->address_o, 0x1357);
    AxiWrite(kRegBase + 4 * kWCtl, CtlWord(kAAddress, false, 0x2468, 10, false));
    Idle(3 * kFrameT);
    std::fprintf(stderr, "  the page never changed hands inside a request\n");
  }

  // ================================================================ phase 8
  //
  // An unplugged DBGIN connector may not ask for anything.  This is the
  // board's default state --- nothing is in JB --- and a carrier that
  // presented anything but zeros there would put the debug master on this
  // machine's Unibus for ever, which is the wedged bus the window's watchdog
  // exists for one level out.
  std::fprintf(stderr, "phase 8: nothing plugged into the debuggee's connector\n");
  {
    ResetBoth();
    link_o.cut_ab = true;
    Idle(4 * kFrameT + kLossT);
    if (d->in_live_o) Say("an unplugged DBGIN connector came up live");
    if (d->cab_req_o) Say("an unplugged DBGIN connector asked for the bus");
    if (d->dbg_req_o) Say("the debug master took the bus with no cable in it");
    if (d->debuggee_reset_o) Say("an unplugged connector reset the machine");
    std::fprintf(stderr, "  an unplugged connector asks for nothing\n");
  }

  // ================================================================ phase 9
  //
  // One board reset while the other keeps running.  This is a button on one
  // of two boards and it is the case the frame's own marker cannot answer:
  // the end that came back starts counting beats wherever the far end
  // happens to be, so unless something realigns the frame it stays wrong for
  // ever and the marker refuses every frame from then on.  What realigns it
  // is the gap, and this is the only stimulus in the file that asks.
  //
  // **THE SWEEP HAS TO COVER A WHOLE FRAME AND NOT A FEW TICKS OF ONE.**
  // Measured before it was written this way: a sweep of seventeen lengths
  // released the far end during the gap or inside beat zero every time, and
  // an end released there locks on to beat zero by itself --- the level the
  // first beat put on the lines is still standing, so the change it detects
  // is beat zero's own.  Nothing about the gap was being asked and the record
  // aimed at it survived.  Seventy-one covers every offset in a
  // sixty-six-tick frame.
  std::fprintf(stderr, "phase 9: one board reset, the other still running\n");
  {
    long worst_back = 0;
    for (long len = 1; len <= 71; ++len) {
      ResetBoth();
      const uint32_t va = Poison(90 + len);
      const uint32_t vb = Poison(140 + len);
      d->p_tx_a = va;
      d->p_tx_b = vb;
      sent_ab.insert(va);
      sent_ba.insert(vb);
      Idle(4 * kFrameT);
      if (!d->p_live_a || !d->p_live_b) Say("not live before the reset");

      d->rst_b = 1;
      Idle(len);
      d->rst_b = 0;

      long back = -1;
      for (long k = 0; k < 8 * kFrameT; ++k) {
        Tick();
        if (back < 0 && d->p_live_a && d->p_live_b && d->p_rx_b == va &&
            d->p_rx_a == vb)
          back = k;
      }
      if (back < 0) {
        std::fprintf(stderr, "  a reset of %ld ticks: ", len);
        Fail("the carrier never came back", d->p_rx_b, va);
      } else if (back > worst_back) {
        worst_back = back;
      }
    }
    std::fprintf(stderr,
                 "  seventy-one reset lengths, and the worst took %ld ticks to "
                 "come back, a frame being %ld\n",
                 worst_back, kFrameT);
    if (worst_back > 4 * kFrameT)
      Fail("the worst recovery", static_cast<unsigned long long>(worst_back),
           static_cast<unsigned long long>(4 * kFrameT));
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::fprintf(stderr,
               "PASS: the debug cable crosses eight pins in %d beats each way, "
               "%ld ticks a frame; worst level delay %ld ticks\n",
               kBeats, kFrameT, worst_level_delay);
  delete d;
  return 0;
}
