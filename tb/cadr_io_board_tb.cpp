// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The I/O board against muir, at the Unibus.
//
// The DUT is `rtl/cadr_io_board.sv` alone, driven by `build/iob.golden`, which
// `golden/src/iob.rs` writes out of muir's own `ioboard::IoBoard` through
// `busint::IoBoardTiming`.  The seam is the one the card has on the machine:
// `-UB MSYN`, `ub_write`, `ub_addr`, `ub_wdata` in and `-UB SSYN`, `ub_rdata`
// back, which is exactly what `cadr_busint_xbus.sv` already drives and what
// `cadr_spy_registers.sv` already answers at `0o766000`.  Composing the two
// slaves under `cadr_memory_path.sv` is the next slice.
//
// WHAT THIS HOLDS TO, at every one of the trace's 80,949,318 ticks:
//
//   - `-UB SSYN` at the instant the trace names and at no earlier one, on
//     every answered cycle, and never at all on the eleven the card does not
//     answer --- held up for 6,000 ns each, which is well past the 2,250 ns
//     the keyboard-and-mouse group takes at its worst phase;
//   - `ub_rdata` at that instant, on all 837 reads;
//   - THE WHOLE FACE at every one of the 1,532 rows: the status register's
//     flip-flops, the two mouse counters, `CLOCK READY`, the interval last
//     loaded, the vector the card is asking for and `AUDIO`.  Every one of
//     those is a register on the card, so none is a column invented for the
//     trace;
//   - the decode, over all 262,144 addresses an eighteen-bit `ub_addr` can
//     carry, read and written: a real bus cycle each, checked for whether the
//     card answers and for WHEN.  See the exemption below.
//
// **THE ROWS ARE SPARSE AND THE CHECK IS NOT.**  The trace has a row wherever
// anything moves and nothing between; here every tick is run, with the free
// clocks left to run, and the face is compared where a row says so.
//
// **PLACEMENT: A ZERO-TIME TRACE ON A CLOCKED FABRIC.**  177 pairs of rows
// share an instant, because muir applies a cycle's face, then a press, then
// the next cycle's `-MSYN`, all at one nanosecond.  Two rules, and they are
// the disk's rules one slice along:
//
//   1. `-UB MSYN` DROPS ONE TICK EARLY, at `off - 5`, so that the bus is idle
//      for one tick before the next cycle.  102 pairs of cycles are back to
//      back in the trace --- the next `-MSYN` at the instant the last one
//      dropped --- which no clocked master can do.  Nothing on the card can
//      see it: everything a cycle does landed at `-UB SSYN`, twenty ticks
//      earlier, and `off` is only when the master lets go.
//   2. A ROW WHOSE ACTION CHANGES SOMETHING THE FACE SHOWS --- a press, the
//      serial port's ready line, `-UB INIT` --- IS PUSHED ONE TICK when it
//      would otherwise land on the tick the previous row's face is compared
//      at, and every row at that same instant after it is pushed with it.
//      Seven rows are pushed, and the run prints the count.  A mouse move or
//      a switch changes nothing the card shows until its next `KB CLK^`, and
//      a cycle changes nothing on the tick its `-MSYN` rises, so those share
//      a tick with the row before them and are not pushed.
//
// **THE MOUSE'S ENCODERS ARE IN HERE, AND muir'S SNAP WITH THEM.**  The card
// takes the seven lines MIT's mouse drives, so the thing that turns the
// trace's `MOVE` rows into quadrature phases is this file.
// `MouseInterface::sample` computes each step's instant as the later of the
// encoder's own due time and THE PREVIOUS EDGE ALREADY SAMPLED --- so a step
// whose due time has fallen behind is dragged forward onto an edge, and
// because an edge is a multiple of 8,000 and a step is 16,000, every step
// after it lands exactly on an edge.  The first two steps of a move therefore
// land on CONSECUTIVE edges and the rest on every other one.  Slice one
// measured what keeping the encoder's own phase instead costs: 307 face rows
// and 27 read-backs disagree, the counters one behind muir for the length of
// every move.  That is a contract, not a tolerance.
//
// **THE DECODE'S ONE EXEMPTION, BOUNDED AND COUNTED.**  `ioboard::answers`
// decodes the whole block, because the decode is one sheet, so the trace's
// `DEC` rows say the card answers the Chaosnet interface's group
// (`0o764140`-`0o764156`) and the serial port's (`0o764160`-`0o764176`).
// Those are two other slices and `rtl/cadr_io_board.sv` does not answer them;
// this check requires that it does not, names the fifteen addresses, and
// prints how many answering directions it let through --- so the day either
// slice lands, this line is what says so.  No `CYC` row goes near them.
//
// AND THE COUNTS ARE THE GENERATOR'S.  The header says how many cycles of
// each kind the program made, how many answers fell off the 5 ns grid, and
// how many phases of `-UB MSYN` inside the card's microsecond it used; the run
// counts what it saw and requires the same, so a trace that stopped reaching
// something says so here rather than passing thinner.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Vcadr_io_board.h"
#include "verilated.h"

namespace {

constexpr long kTick = 5;              // nanoseconds a tick
constexpr long kUbAddresses = 1 << 18;
constexpr unsigned kNoReg = 0xFFFF'FFFFu;

// ioboard::FIRST_USEC_EDGE_NS, KB_CLK_NS, MOUSE_STEP_NS.
constexpr long kFirstEdge = 890;
constexpr long kUsecPeriod = 1000;
constexpr long kKbClk = 8000;
constexpr long kMouseStep = 16000;
// busint::IOB_STRAIGHT_NS and IOB_USEC_LOW_NS.
constexpr long kStraight = 250;
constexpr long kUsecLow = 313;

// The registers this file names, by their own Unibus address.
constexpr unsigned kKbdLow = 0764100u, kCsr = 0764112u;
constexpr unsigned kUsecLowReg = 0764120u, kUsecHighReg = 0764122u;
constexpr unsigned kClock = 0764124u, kGpio = 0764126u;
// The two groups this card does not answer: the Chaosnet interface's and the
// serial port's.  See the header.
constexpr unsigned kOtherFirst = 0764140u, kOtherLast = 0764176u;

// How long a cycle nothing should answer is held in the decode sweep.  The
// longest answer the card can give is the keyboard-and-mouse group at its
// worst phase, 2,250 ns; the trace's own eleven unanswered cycles are held
// for 6,000.
constexpr long kSweepHold = 460;

// `busint::IoBoardTiming::usec_edge_after`: the first rising edge of the
// card's microsecond clock STRICTLY after `t`.
long UsecEdgeAfter(long t) {
  if (t < kFirstEdge) return kFirstEdge;
  return kFirstEdge + ((t - kFirstEdge) / kUsecPeriod + 1) * kUsecPeriod;
}

// `IoBoardTiming::answer`, rounded up to the 5 ns grid --- which is a rounding
// only for the counter's low half, and that is the trace's `slip`.
long AnswerNs(unsigned reg, long msyn) {
  long exact;
  if (reg == kUsecLowReg) {
    exact = UsecEdgeAfter(msyn) + kUsecLow;
  } else if (reg == kUsecHighReg || reg == kClock || reg == kGpio) {
    exact = msyn + kStraight;
  } else {
    // The keyboard, mouse, status and beep registers select through two
    // stages of the microsecond clock.
    exact = UsecEdgeAfter(msyn) + kUsecPeriod + kStraight;
  }
  return (exact + kTick - 1) / kTick * kTick;
}

bool ThisCardAnswers(unsigned reg) {
  return reg != kNoReg && !(reg >= kOtherFirst && reg <= kOtherLast);
}

// The mouse's two encoders, muir's `terminal::mouse::Encoders` with
// `MouseInterface::sample`'s snap around them.  Phase 2 at power-on, both
// lines of each pair high, which is what the board's 74LS14s read with
// nothing plugged in.
struct Encoders {
  long dx = 0, dy = 0;
  int xp = 2, yp = 2;
  long next = 0;

  bool Busy() const { return dx != 0 || dy != 0; }
  void Send(long ddx, long ddy) { dx += ddx; dy += ddy; }

  void Step(long now) {
    if (dx != 0) {
      int s = dx > 0 ? 1 : -1;
      xp = ((xp + s) % 4 + 4) % 4;
      dx -= s;
    }
    if (dy != 0) {
      int s = dy > 0 ? 1 : -1;
      yp = ((yp + s) % 4 + 4) % 4;
      dy -= s;
    }
    next = now + kMouseStep;
  }

  // One rising edge of `KB CLK^` at `ns`.  THE SNAP: the step's instant is the
  // later of its own due time and the previous edge, so a step that has fallen
  // behind is dragged onto an edge and every step after it lands on one.
  void Edge(long ns) {
    if (!Busy()) return;
    long prev = ns - kKbClk;
    long due = next > prev ? next : prev;
    if (due <= ns) Step(due);
  }

  // The seven lines as MIT's mouse drives them: the quadrature pairs in Gray
  // order and the three switches, each pulled to ground when pressed.  The
  // card's 74LS14s invert all seven.
  int Lines(int switches) const {
    auto levels = [](int p, int *a, int *b) {
      int g = p ^ (p >> 1);
      *a = (g >> 1) & 1;
      *b = g & 1;
    };
    int xa, xb, ya, yb;
    levels(xp, &xa, &xb);
    levels(yp, &ya, &yb);
    int inverted = ((!xa) << 0) | ((!xb) << 1) | ((!ya) << 2) | ((!yb) << 3);
    return (~(inverted | (switches << 4))) & 0x7F;
  }
};

enum Tag { kCyc, kKey, kMove, kBtn, kSer, kInit, kFace };

struct Row {
  Tag tag;
  long n, ns;
  long ssyn, slip, off;      // CYC
  unsigned uaddr, reg_;
  int write;
  unsigned wdata, rdata;
  unsigned code;             // KEY
  long dx, dy;               // MOVE
  unsigned mask;             // BTN
  int ready;                 // SER
  // the face, in the trace's own order
  unsigned csr, x, y, held;
  int clkrdy;
  unsigned interval, intr;
  int audio, serrdy;
  // where this row lands on the 5 ns grid
  long face_tick, cmp_tick, act_tick;
};

int bad = 0;

void Fail(long tick, const Row &r, const char *what, unsigned long got, unsigned long want) {
  if (bad < 25) {
    std::fprintf(stderr,
                 "tick %ld (%ld ns): %s is 0x%lx (%lu), muir says 0x%lx (%lu)\n"
                 "  row %ld at %ld ns\n",
                 tick, tick * kTick, what, got, got, want, want, r.n, r.ns);
  }
  ++bad;
}

// One tick of a DUT: the inputs are what the edge samples, the outputs what is
// seen after it.
struct Dut {
  Vcadr_io_board *d;
  long tick = 0;

  Dut() : d(new Vcadr_io_board) {
    d->clk = 0;
    d->rst = 1;
    d->ub_msyn = 0;
    d->ub_write = 0;
    d->ub_addr = 0;
    d->ub_wdata = 0;
    d->ub_init = 0;
    d->kbd_strobe = 0;
    d->kbd_code = 0;
    d->mouse_lines = 0x7F;  // a mouse at rest, nothing pressed
    d->ser_ready = 0;
    d->chaos_intr = 0;
    d->eval();
  }
  ~Dut() {
    d->final();
    delete d;
  }
  void Rise() {
    d->rst = (tick == 0);
    d->clk = 1;
    d->eval();
  }
  void Fall() {
    d->clk = 0;
    d->eval();
    ++tick;
  }
  void Idle(long n) {
    for (long k = 0; k < n; ++k) {
      Rise();
      Fall();
    }
  }
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/iob.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // ---- the trace -----------------------------------------------------------
  std::map<std::string, long> hdr;
  std::map<unsigned, long> hdr_reads, hdr_writes, hdr_vectors;
  std::vector<Row> rows;
  // What `ioboard::answers` makes of every address, both directions.
  std::vector<unsigned> dec[2];
  dec[0].assign(kUbAddresses, 0);
  dec[1].assign(kUbAddresses, 0);
  std::vector<char> covered(kUbAddresses, 0);
  long dec_rows = 0, dec_none_runs = 0, trace_answers = 0;

  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#') {
      char key[64];
      long a, b;
      int used = 0;
      if (std::sscanf(line, "# %63s%n", key, &used) != 1) continue;
      std::string k(key);
      if ((k == "read" || k == "write" || k == "vector") &&
          std::sscanf(line + used, "%lo %ld", &a, &b) == 2) {
        // These three are printed in octal, one line a register or vector.
        (k == "read" ? hdr_reads : k == "write" ? hdr_writes : hdr_vectors)[(unsigned)a] = b;
      } else if (std::sscanf(line + used, "%ld", &a) == 1) {
        hdr[k] = a;
      }
      continue;
    }
    if (line[0] == '\n') continue;
    if (!std::strncmp(line, "DECNONE ", 8)) {
      unsigned lo, hi;
      if (std::sscanf(line + 8, "%x %x", &lo, &hi) != 2) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, line);
        return 2;
      }
      for (unsigned u = lo; u <= hi; ++u) {
        dec[0][u] = dec[1][u] = kNoReg;
        covered[u] = 1;
      }
      ++dec_none_runs;
      continue;
    }
    if (!std::strncmp(line, "DEC ", 4)) {
      unsigned u, r;
      int w;
      if (std::sscanf(line + 4, "%x %d %x", &u, &w, &r) != 3) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, line);
        return 2;
      }
      dec[w][u] = r;
      covered[u] = 1;
      ++dec_rows;
      if (r != kNoReg) ++trace_answers;
      continue;
    }

    // An event row: the tag, its number, the instant, the row's own fields and
    // then the nine columns of the face.
    char tag[16];
    Row r;
    std::memset(&r, 0, sizeof r);
    int n = std::sscanf(line, "%15s", tag);
    if (n != 1) continue;
    const char *p = line + std::strlen(tag);
    int got = 0;
    if (!std::strcmp(tag, "CYC")) {
      r.tag = kCyc;
      got = std::sscanf(p, "%ld %ld %ld %ld %ld %x %x %d %x %x %x %x %x %x %d %x %x %d %d", &r.n,
                        &r.ns, &r.ssyn, &r.slip, &r.off, &r.uaddr, &r.reg_, &r.write, &r.wdata,
                        &r.rdata, &r.csr, &r.x, &r.y, &r.held, &r.clkrdy, &r.interval, &r.intr,
                        &r.audio, &r.serrdy);
      if (got != 19) got = 0;
    } else if (!std::strcmp(tag, "KEY") || !std::strcmp(tag, "BTN")) {
      unsigned v;
      got = std::sscanf(p, "%ld %ld %x %x %x %x %x %d %x %x %d %d", &r.n, &r.ns, &v, &r.csr, &r.x,
                        &r.y, &r.held, &r.clkrdy, &r.interval, &r.intr, &r.audio, &r.serrdy);
      if (got != 12) got = 0;
      if (!std::strcmp(tag, "KEY")) {
        r.tag = kKey;
        r.code = v;
      } else {
        r.tag = kBtn;
        r.mask = v;
      }
    } else if (!std::strcmp(tag, "MOVE")) {
      r.tag = kMove;
      got = std::sscanf(p, "%ld %ld %ld %ld %x %x %x %x %d %x %x %d %d", &r.n, &r.ns, &r.dx, &r.dy,
                        &r.csr, &r.x, &r.y, &r.held, &r.clkrdy, &r.interval, &r.intr, &r.audio,
                        &r.serrdy);
      if (got != 13) got = 0;
    } else if (!std::strcmp(tag, "SER")) {
      r.tag = kSer;
      got = std::sscanf(p, "%ld %ld %d %x %x %x %x %d %x %x %d %d", &r.n, &r.ns, &r.ready, &r.csr,
                        &r.x, &r.y, &r.held, &r.clkrdy, &r.interval, &r.intr, &r.audio, &r.serrdy);
      if (got != 12) got = 0;
    } else if (!std::strcmp(tag, "INIT") || !std::strcmp(tag, "FACE")) {
      r.tag = !std::strcmp(tag, "INIT") ? kInit : kFace;
      got = std::sscanf(p, "%ld %ld %x %x %x %x %d %x %x %d %d", &r.n, &r.ns, &r.csr, &r.x, &r.y,
                        &r.held, &r.clkrdy, &r.interval, &r.intr, &r.audio, &r.serrdy);
      if (got != 11) got = 0;
    } else {
      std::fprintf(stderr, "%s: unknown row: %s", path, line);
      return 2;
    }
    if (!got) {
      std::fprintf(stderr, "%s: cannot parse: %s", path, line);
      return 2;
    }
    rows.push_back(r);
  }
  std::fclose(f);

  auto want_h = [&](const char *key) -> long {
    auto it = hdr.find(key);
    if (it == hdr.end()) {
      std::fprintf(stderr, "FAIL: %s has no `%s` in its header\n", path, key);
      std::exit(1);
    }
    return it->second;
  };

  // The module's own constants against the generator's header: a muir that
  // moved says so here and not as a mismatch a microsecond in.  The last six
  // are printed in octal by the generator and are compared as the digits they
  // are, which is what makes them readable beside `docs/io-board.md`.
  struct {
    const char *what;
    long got, want;
  } consts[] = {
      {"tick_ns", want_h("tick_ns"), kTick},
      {"ub_address_bits", want_h("ub_address_bits"), 18},
      {"first_usec_edge_ns", want_h("first_usec_edge_ns"), kFirstEdge},
      {"kb_clk_ns", want_h("kb_clk_ns"), kKbClk},
      {"mouse_step_ns", want_h("mouse_step_ns"), kMouseStep},
      {"interval_tick_ns", want_h("interval_tick_ns"), 16000},
      {"sixty_cycle_ns", want_h("sixty_cycle_ns"), 16666666},
      {"unibus_strobe_ns", want_h("unibus_strobe_ns"), 100},
      {"csr_writable", want_h("csr_writable"), 217},
      {"csr_floating", want_h("csr_floating"), 177400},
      {"mouse_count", want_h("mouse_count"), 7777},
      {"kbd_vector", want_h("kbd_vector"), 260},
      {"serial_vector", want_h("serial_vector"), 264},
      {"clock_vector", want_h("clock_vector"), 274},
      {"rows", want_h("rows"), (long)rows.size()},
      {"dec_rows", want_h("dec_rows"), dec_rows},
      {"dec_none_runs", want_h("dec_none_runs"), dec_none_runs},
  };
  int wrong = 0;
  for (const auto &c : consts) {
    if (c.got != c.want) {
      std::fprintf(stderr, "FAIL: the trace says %s is %ld and the fabric has %ld\n", c.what, c.got,
                   c.want);
      ++wrong;
    }
  }
  for (long u = 0; u < kUbAddresses; ++u) {
    if (!covered[u]) {
      std::fprintf(stderr, "FAIL: the trace's decode rows do not cover 0%lo\n", (unsigned long)u);
      ++wrong;
      break;
    }
  }
  if (wrong) return 1;
  const long last_tick = want_h("last_tick");

  // ---- the placement -------------------------------------------------------
  //
  // See the header.  Compare ticks are monotone; a row whose action changes
  // something the face shows is pushed a tick rather than sharing one with the
  // row before it.
  long pushed = 0;
  long prev_cmp = -1;
  for (auto &r : rows) {
    r.face_tick = (r.tag == kCyc ? r.off : r.ns) / kTick;
    long want = r.face_tick;
    if (want < prev_cmp) want = prev_cmp;
    const bool visible = (r.tag == kKey || r.tag == kSer || r.tag == kInit);
    if (visible && want == prev_cmp) {
      want = prev_cmp + 1;
      ++pushed;
    }
    r.cmp_tick = want;
    // A press, the serial line and `-UB INIT` land where they are compared; a
    // move and a switch land at their own instant, because what they change is
    // an input the card samples on its own clock.
    r.act_tick = visible ? want : r.ns / kTick;
    prev_cmp = want;
  }

  // The cycles, and the two ticks that bound each: `-UB MSYN` up at `msyn` and
  // down one tick before `off`.
  struct Cyc {
    long msyn_t, ssyn_t, last_t;
    unsigned addr, wdata;
    int write, answered;
    size_t row;
  };
  std::vector<Cyc> cycs;
  for (size_t i = 0; i < rows.size(); ++i) {
    const Row &r = rows[i];
    if (r.tag != kCyc) continue;
    Cyc c;
    c.msyn_t = r.ns / kTick;
    c.answered = (r.ssyn != 0);
    c.ssyn_t = c.answered ? r.ssyn / kTick : 0;
    c.last_t = r.off / kTick - 2;  // the last tick `-UB MSYN` is up
    c.addr = r.uaddr;
    c.wdata = r.wdata;
    c.write = r.write;
    c.row = i;
    if (c.last_t < c.msyn_t) {
      std::fprintf(stderr, "FAIL: row %ld is too short to run on a 5 ns grid\n", r.n);
      return 1;
    }
    // The testbench's own model of `IoBoardTiming` against the trace: if these
    // ever part, the decode sweep below would be checking the wrong instant.
    if (c.answered && AnswerNs(r.reg_, r.ns) != r.ssyn) {
      std::fprintf(stderr, "FAIL: row %ld: this check computes -UB SSYN at %ld and muir says %ld\n",
                   r.n, AnswerNs(r.reg_, r.ns), r.ssyn);
      return 1;
    }
    cycs.push_back(c);
  }

  // ---- the run -------------------------------------------------------------
  //
  // Three lists, each in its own order: the cycles, the pulses that land where
  // they are compared, and the mouse's rows, which act where their own row is
  // compared because what they change is an input the card samples on its own
  // clock.  `act_tick` is not monotone across all rows --- a pushed press can
  // sit a tick after a cycle whose `-MSYN` is at the same instant --- so they
  // are kept apart rather than walked with one pointer.
  std::vector<size_t> strobes;
  for (size_t i = 0; i < rows.size(); ++i) {
    if (rows[i].tag == kKey || rows[i].tag == kSer || rows[i].tag == kInit) strobes.push_back(i);
  }

  Dut b;
  Encoders enc;
  int switches = 0;
  int ser_model = 0;
  size_t ci = 0, ri = 0, si = 0;
  unsigned addr_held = 0, wdata_held = 0;
  int write_held = 0;

  long answered = 0, unanswered = 0, reads = 0, writes = 0, slips = 0;
  long presses = 0, moves = 0, inits = 0, faces = 0, sers = 0, btns = 0;
  long compared_rdata = 0, compared_faces = 0;
  std::set<long> phases;
  std::map<unsigned, long> saw_reads, saw_writes, saw_vectors;
  Row nowhere;
  std::memset(&nowhere, 0, sizeof nowhere);

  for (long t = 0; t <= last_tick && bad < 25; ++t) {
    // The mouse's own clock, and the encoders' step on it, BEFORE anything
    // this tick's rows do: muir advances the board to the instant and then
    // applies what happens there.
    if (t > 0 && (t * kTick) % kKbClk == 0) enc.Edge(t * kTick);

    // --- the inputs this edge samples
    while (ci < cycs.size() && t > cycs[ci].last_t) ++ci;
    const bool in_cycle = (ci < cycs.size() && t >= cycs[ci].msyn_t);
    if (in_cycle) {
      addr_held = cycs[ci].addr;
      wdata_held = cycs[ci].wdata;
      write_held = cycs[ci].write;
      if (t == cycs[ci].msyn_t) phases.insert((t * kTick) % kUsecPeriod);
    }
    b.d->ub_msyn = in_cycle;
    b.d->ub_addr = addr_held;
    b.d->ub_wdata = wdata_held;
    b.d->ub_write = write_held;
    b.d->mouse_lines = enc.Lines(switches);

    b.d->kbd_strobe = 0;
    b.d->kbd_code = 0;
    b.d->ub_init = 0;
    while (si < strobes.size() && rows[strobes[si]].act_tick == t) {
      const Row &r = rows[strobes[si]];
      if (r.tag == kKey) {
        b.d->kbd_strobe = 1;
        b.d->kbd_code = r.code;
      } else if (r.tag == kInit) {
        b.d->ub_init = 1;
      } else {
        ser_model = r.ready;
      }
      ++si;
    }
    b.d->ser_ready = ser_model;

    b.Rise();

    // `-INIT*` into the 8837 at IOBXCV 0F06 IS the 2651's RESET pin, so the
    // serial port's ready line falls because THE CARD carried the pulse to it.
    if (b.d->ser_reset) ser_model = 0;

    // --- `-UB SSYN`, at the instant the trace names and at no other
    if (in_cycle) {
      const Cyc &c = cycs[ci];
      const Row &r = rows[c.row];
      const int want = (c.answered && t >= c.ssyn_t) ? 1 : 0;
      if (b.d->ub_ssyn != want) Fail(t, r, "-UB SSYN", b.d->ub_ssyn, want);
      if (c.answered && t == c.ssyn_t) {
        ++answered;
        if (r.slip != 0) {
          ++slips;
          if (r.reg_ != kUsecLowReg) {
            Fail(t, r, "an answer off the 5 ns grid at a register that should be on it", r.reg_,
                 kUsecLowReg);
          }
        }
        if (c.write) {
          ++writes;
          saw_writes[r.reg_]++;
        } else {
          ++reads;
          saw_reads[r.reg_]++;
          if (b.d->ub_rdata != r.rdata) Fail(t, r, "ub_rdata", b.d->ub_rdata, r.rdata);
          else ++compared_rdata;
        }
      }
    } else if (b.d->ub_ssyn) {
      nowhere.n = -1;
      nowhere.ns = t * kTick;
      Fail(t, nowhere, "-UB SSYN with -UB MSYN down", b.d->ub_ssyn, 0);
    }

    // --- the face, wherever a row says so.  A move and a switch act HERE,
    // where their own row is compared: muir advances the board to the instant
    // and then moves the mouse, so an edge on that very tick sees what the
    // mouse held before it.
    while (ri < rows.size() && rows[ri].cmp_tick <= t) {
      const Row &r = rows[ri];
      if (r.cmp_tick != t) {
        std::fprintf(stderr, "FAIL: row %ld was scheduled at tick %ld and it is now %ld\n", r.n,
                     r.cmp_tick, t);
        return 1;
      }
      if (r.tag == kMove) {
        enc.Send(r.dx, r.dy);
        ++moves;
      } else if (r.tag == kBtn) {
        switches = (int)(r.mask & 7u);
        ++btns;
      }
      if (b.d->csr_face != r.csr) Fail(t, r, "the status register's flip-flops", b.d->csr_face, r.csr);
      if (b.d->mouse_x != r.x) Fail(t, r, "the mouse's X counter", b.d->mouse_x, r.x);
      if (b.d->mouse_y != r.y) Fail(t, r, "the mouse's Y counter", b.d->mouse_y, r.y);
      if ((unsigned)switches != r.held) Fail(t, r, "the switches this check holds", switches, r.held);
      if (b.d->clock_ready != r.clkrdy) Fail(t, r, "CLOCK READY", b.d->clock_ready, r.clkrdy);
      if (b.d->interval != r.interval) Fail(t, r, "the interval last loaded", b.d->interval, r.interval);
      if (b.d->intr_vector != r.intr) Fail(t, r, "the interrupt vector", b.d->intr_vector, r.intr);
      if ((b.d->intr_request != 0) != (r.intr != 0))
        Fail(t, r, "the interrupt request", b.d->intr_request, r.intr != 0);
      if (b.d->audio != r.audio) Fail(t, r, "AUDIO", b.d->audio, r.audio);
      if (ser_model != r.serrdy) Fail(t, r, "the serial port's ready line", ser_model, r.serrdy);
      if (r.intr != 0) saw_vectors[r.intr]++;
      switch (r.tag) {
        case kKey: ++presses; break;
        case kInit: ++inits; break;
        case kSer: ++sers; break;
        case kFace: ++faces; break;
        default: break;
      }
      ++compared_faces;
      ++ri;
    }

    b.Fall();
  }
  unanswered = (long)cycs.size() - answered;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches replaying %s\n", bad, path);
    return 1;
  }
  if (ri != rows.size()) {
    std::fprintf(stderr, "FAIL: %zu rows of %zu were never compared\n", rows.size() - ri,
                 rows.size());
    return 1;
  }

  // ---- the decode, over the whole of an eighteen-bit `ub_addr` --------------
  //
  // A real bus cycle at every address, in both directions: does the card
  // answer, and WHEN.  The instant is what tells the three timing groups
  // apart, and so tells `0o764130` from `0o764120`'s neighbours.
  Dut s;
  long dec_answers = 0, dec_silent = 0, dec_other = 0;
  for (long u = 0; u < kUbAddresses && bad < 25; ++u) {
    for (int w = 0; w < 2; ++w) {
      const unsigned reg = dec[w][u];
      const long msyn_t = s.tick;
      const bool ours = ThisCardAnswers(reg);
      const long ssyn_t = ours ? AnswerNs(reg, msyn_t * kTick) / kTick : 0;
      const long last_t = ours ? ssyn_t + 3 : msyn_t + kSweepHold;

      s.d->ub_msyn = 1;
      s.d->ub_addr = (unsigned)u;
      s.d->ub_write = w;
      s.d->ub_wdata = 0x5A5A;
      for (long t = msyn_t; t <= last_t && bad < 25; ++t) {
        s.Rise();
        const int want = (ours && t >= ssyn_t) ? 1 : 0;
        if (s.d->ub_ssyn != want) {
          if (bad < 25) {
            std::fprintf(stderr,
                         "tick %ld: the decode at 0%lo %s: -UB SSYN is %d and should be %d\n"
                         "  muir's answers() says %s; -UB MSYN rose at %ld ns\n",
                         t, (unsigned long)u, w ? "written" : "read", s.d->ub_ssyn, want,
                         reg == kNoReg ? "nothing answers"
                                       : (ours ? "this card answers" : "another slice answers"),
                         msyn_t * kTick);
          }
          ++bad;
        }
        s.Fall();
      }
      if (ours) ++dec_answers;
      else if (reg == kNoReg) ++dec_silent;
      else ++dec_other;   // the Chaosnet interface's group and the serial port's
      s.d->ub_msyn = 0;
      s.Idle(1);
    }
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d disagreements over the decode\n", bad);
    return 1;
  }

  // ---- the priority chain, including the input nothing drives yet ----------
  //
  // NOT A COMPARISON WITH muir: `interrupt_request` consults `self.chaos`,
  // which is `None` unless an interface is plugged in, and plugging one in
  // drags the whole Chaosnet board into the trace.  So `0o270` and its place
  // in the chain are held to page IOBINT's own two equations --- `V2 = (SER
  // AND NOT CHAOS) OR CLOCK` and `V3 = CLOCK OR CHAOS` --- and this says so.
  // The other three vectors are compared against muir above, on every row.
  {
    Dut p;
    p.Idle(4);
    auto cycle = [&](unsigned addr, int write, unsigned wdata) {
      p.d->ub_msyn = 1;
      p.d->ub_addr = addr;
      p.d->ub_write = write;
      p.d->ub_wdata = wdata;
      long waited = 0;
      do {
        p.Rise();
        p.Fall();
        ++waited;
      } while (!p.d->ub_ssyn && waited < 600);
      p.d->ub_msyn = 0;
      p.Idle(2);
      return waited;
    };
    auto want_vector = [&](const char *when, unsigned want) {
      if (p.d->intr_vector != want || (p.d->intr_request != 0) != (want != 0)) {
        std::fprintf(stderr,
                     "FAIL: the priority chain, %s: the card asks for 0%o (request %d) and page "
                     "IOBINT's equations say 0%o\n",
                     when, p.d->intr_vector, p.d->intr_request, want);
        ++bad;
      }
    };
    cycle(kClock, 1, 0x0800);          // an interval long enough not to run out
    cycle(kCsr, 1, 0217);              // all five enables
    p.d->kbd_strobe = 1;
    p.d->kbd_code = 0x123456;
    p.Rise();
    p.Fall();
    p.d->kbd_strobe = 0;
    want_vector("the keyboard alone", 0260);
    p.d->ser_ready = 1;
    p.Idle(1);
    want_vector("the serial port over the keyboard", 0264);
    p.d->chaos_intr = 1;
    p.Idle(1);
    want_vector("the Chaosnet over the serial port", 0270);
    cycle(kClock, 1, 0);               // an interval of zero is over at once
    want_vector("the clock over everything", 0274);
    cycle(kCsr, 1, 0207);              // the clock's enable away
    want_vector("the Chaosnet again", 0270);
    p.d->chaos_intr = 0;
    p.Idle(1);
    want_vector("the serial port again", 0264);
    p.d->ser_ready = 0;
    p.Idle(1);
    want_vector("the keyboard again", 0260);
    cycle(kKbdLow, 0, 0);              // the low half's read clears KBD READY
    want_vector("nothing waiting", 0);
    if (bad) return 1;
  }

  // ---- what the run saw, against what the generator says it made -----------
  int thin = 0;
  auto same = [&](const char *what, long got, long want) {
    if (got != want) {
      std::fprintf(stderr, "FAIL: the run saw %ld %s and the trace's header says %ld\n", got, what,
                   want);
      ++thin;
    }
  };
  same("rows compared", compared_faces, (long)rows.size());
  same("answered reads", reads, want_h("reads"));
  same("answered writes", writes, want_h("writes"));
  same("cycles nothing answered", unanswered, want_h("unanswered"));
  same("answers off the 5 ns grid", slips, want_h("offgrid_answers"));
  same("phases of -UB MSYN", (long)phases.size(), want_h("msyn_phases"));
  same("presses", presses, want_h("presses"));
  same("moves", moves, want_h("moves"));
  same("-UB INIT pulses", inits, want_h("inits"));
  same("faces between cycles", faces, want_h("faces"));
  same("directions the decode answers", dec_answers + dec_other, trace_answers);
  same("directions nothing answers", dec_silent, 2 * kUbAddresses - trace_answers);
  for (const auto &kv : hdr_reads) same("reads of a register", saw_reads[kv.first], kv.second);
  for (const auto &kv : hdr_writes) same("writes of a register", saw_writes[kv.first], kv.second);
  for (const auto &kv : hdr_vectors) {
    if (saw_vectors[kv.first] == 0) {
      std::fprintf(stderr, "FAIL: the vector 0%o was never asked for\n", kv.first);
      ++thin;
    }
  }
  if (thin) return 1;
  if (pushed != 7 || slips == 0 || presses < 10 || moves < 10 || btns < 8 || sers < 2 ||
      dec_other == 0) {
    std::fprintf(stderr,
                 "FAIL: the placement or the trace is not what this check was written against: "
                 "%ld rows pushed, %ld off-grid answers, %ld presses, %ld moves, %ld switch masks, "
                 "%ld serial rows, %ld exempt\n",
                 pushed, slips, presses, moves, btns, sers, dec_other);
    return 1;
  }

  std::printf(
      "ok: %ld ticks (%ld ns of the card's own time), agree with muir's ioboard::IoBoard through\n"
      "    busint::IoBoardTiming at the Unibus.  %zu rows compared in full --- the status\n"
      "    register's flip-flops, both mouse counters, CLOCK READY, the interval last loaded, the\n"
      "    interrupt vector and AUDIO --- with %ld rows pushed one tick where muir put two events\n"
      "    at one nanosecond.\n"
      "    %ld cycles: %ld reads and %ld writes answered at -UB SSYN to the tick and at no earlier\n"
      "    tick, %ld read words compared there, %ld that nothing answered held 6,000 ns each.\n"
      "    %ld of the answers fall off the 5 ns grid and every one is the microsecond counter's\n"
      "    low half; %ld of the 200 phases of -UB MSYN inside the card's microsecond were used.\n"
      "    %ld presses, %ld moves, %ld switch masks, %ld -UB INIT pulses, %ld faces between cycles.\n"
      "    The decode: %ld directions answered and %ld silent over all %ld directions of an\n"
      "    eighteen-bit ub_addr, read and written, a real bus cycle each.  EXEMPT: %ld answering\n"
      "    directions in the Chaosnet interface's and the serial port's groups (0%o-0%o), which\n"
      "    ioboard::answers decodes and this card does not answer, those being two other slices.\n"
      "    The priority chain is held to page IOBINT's equations, 0o270 included, which no trace\n"
      "    against this model can reach.\n",
      b.tick, want_h("last_ns"), rows.size(), pushed, (long)cycs.size(), reads, writes, compared_rdata,
      unanswered, slips, (long)phases.size(), presses, moves, btns, inits, faces, dec_answers,
      dec_silent, (long)kUbAddresses * 2, dec_other, kOtherFirst, kOtherLast);
  return 0;
}
