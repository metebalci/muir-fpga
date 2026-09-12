// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The I/O board against muir, at the Unibus.
//
// The DUT is `rtl/machine/cadr_io_board.sv` alone, driven by `build/iob.golden`, which
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
// **THE DECODE HAS NO EXEMPTION LEFT.**  This file used to require that the
// card did NOT answer the Chaosnet interface's group (`0o764140`-`0o764156`)
// or the serial port's (`0o764160`-`0o764176`), and printed how many
// answering directions that let through: twenty-seven of fifty-five.  Both
// groups are built, so all fifty-five are held, at three answer timings the
// rest of the card does not use --- `IOB_CHAOS_BUFFER_NS` through the
// transmitter, `IOB_RBUF_SETUP_NS` on `FCLK^`, and `IOB_SERIAL_NS` past a
// half-microsecond clock whose phase is 203 ns.
//
// **AND THE TWO FAR ENDS ARE STIMULUS, NOT MODELS.**  The Chaosnet's cable
// and the 2651's line are the `cadr-chaosnet` and `cadr-serial` programs' on
// the board, and muir's own interface plays both here: the trace records the
// instants they act at as `CRX`, `CTD`, `CBL`, `STK`, `SDN` and `SRX` rows
// and this file replays them at the card's seam.  What the card hands back
// --- the transmit buffer at a read of START, a character on the cable --- is
// compared and never driven.
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
// busint::IOB_CHAOS_BUFFER_NS, IOB_FCLK_NS, IOB_RBUF_SETUP_NS,
// IOB_HALF_USEC_NS, IOB_HALF_USEC_PHASE_NS and IOB_SERIAL_NS: the three
// timings the Chaosnet interface and the serial port answer on.
constexpr long kChaosBuf = 350;
constexpr long kFclk = 125;
constexpr long kRbufSetup = 33;
constexpr long kHalfUsec = 500;
constexpr long kHalfUsecPhase = 203;
constexpr long kSerialNs = 750;

// The registers this file names, by their own Unibus address.
constexpr unsigned kKbdLow = 0764100u, kCsr = 0764112u;
constexpr unsigned kUsecLowReg = 0764120u, kUsecHighReg = 0764122u;
constexpr unsigned kClock = 0764124u, kGpio = 0764126u;
// The Chaosnet interface's group and the serial port's, and the registers
// inside them whose answer is not the plain TD250.
constexpr unsigned kChaosFirst = 0764140u, kChaosLast = 0764156u;
constexpr unsigned kSerialFirst = 0764160u, kSerialLast = 0764176u;
constexpr unsigned kChaosWbuf = 0764142u;   // written; read it is MY ADDRESS
constexpr unsigned kChaosRbuf = 0764144u;
constexpr unsigned kChaosStart = 0764152u;
constexpr unsigned kChaosCsr = 0764140u;
constexpr unsigned kSerialStatus = 0764162u;
constexpr unsigned kSerialMode = 0764164u, kSerialCommand = 0764166u;

// How many rows this check's placement has to push one tick.  The two rules
// are in the header; the number is this file's own and not the trace's, so it
// is written here and asserted rather than read out of the header.
constexpr long kPushedRows = 8;

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

// `IoBoardTiming::fclk_edge_at_or_after` and `half_usec_edge_after`.
long FclkEdgeAtOrAfter(long t) { return (t + kFclk - 1) / kFclk * kFclk; }
long HalfUsecEdgeAfter(long t) {
  long k = (t < kHalfUsecPhase ? 0 : (t - kHalfUsecPhase) / kHalfUsec) + 1;
  return kHalfUsecPhase + k * kHalfUsec;
}

// `IoBoardTiming::answer`, rounded up to the 5 ns grid.  TWO REGISTERS ANSWER
// OFF IT: the counter's low half at 313 ns past its edge, and EVERY address
// of the serial port's group, whose half-microsecond clock has a phase of
// 203 --- so 953 + 500k, which is 3 modulo 5 and two nanoseconds short of a
// tick on every cycle of the group.  That is the trace's `slip`.
long AnswerNs(unsigned reg, int write, long msyn) {
  long exact;
  if (reg == kUsecLowReg) {
    exact = UsecEdgeAfter(msyn) + kUsecLow;
  } else if (reg == kUsecHighReg || reg == kClock || reg == kGpio) {
    exact = msyn + kStraight;
  } else if (reg >= kSerialFirst && reg <= kSerialLast) {
    exact = HalfUsecEdgeAfter(msyn) + kSerialNs;
  } else if (reg == kChaosStart || (reg == kChaosWbuf && write)) {
    // Through the transmitter's `-TSR.SSYN`.
    exact = msyn + kChaosBuf;
  } else if (reg == kChaosRbuf) {
    // The receive buffer's RAM on `FCLK^`, and then a TD250.
    exact = FclkEdgeAtOrAfter(msyn + kRbufSetup) + kStraight;
  } else if (reg >= kChaosFirst && reg <= kChaosLast) {
    exact = msyn + kStraight;
  } else {
    // The keyboard, mouse, status and beep registers select through two
    // stages of the microsecond clock.
    exact = UsecEdgeAfter(msyn) + kUsecPeriod + kStraight;
  }
  return (exact + kTick - 1) / kTick * kTick;
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

enum Tag {
  kCyc, kKey, kMove, kBtn, kSer, kInit, kFace,
  // The two far ends, which are Linux's on the board: stimulus but for `kCtx`
  // and `kSout`, which are assertions about what the card hands over.
  kCtx, kCrx, kCtd, kCbl, kStk, kSdn, kSrx, kSre, kSout, kSpl
};

// Every row ends with the same face.  Six columns are new to this slice: the
// Chaosnet interface's CSR as a read assembles it, its bit counter, and the
// 2651's three registers and status byte.
#define FACE_FMT " %x %x %x %x %d %x %x %d %d %x %x %x %x %x %x"
#define FACE_ARGS                                                              \
  &r.csr, &r.x, &r.y, &r.held, &r.clkrdy, &r.interval, &r.intr, &r.audio,      \
      &r.serrdy, &r.ccsr, &r.cbits, &r.sm1, &r.sm2, &r.scmd, &r.sstat
constexpr int kFaceCols = 15;

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
  long seq, len, bits;       // CTX, CRX
  int crc, busy, abort;      // CRX, CTD, CBL
  unsigned data;             // SRX, SOUT
  int plugged;               // SPL
  // the face, in the trace's own order
  unsigned csr, x, y, held;
  int clkrdy;
  unsigned interval, intr;
  int audio, serrdy;
  unsigned ccsr, cbits, sm1, sm2, scmd, sstat;
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
    // The two far ends, which are `cadr-serial`'s and `cadr-chaosnet`'s on
    // the board.  **`ser_ready` AND `chaos_intr` ARE GONE**: the card
    // computes both now, so a line left driving them fails to compile rather
    // than quietly supplying the answer.
    d->ser_tx_take = 0;
    d->ser_tx_done = 0;
    d->ser_rx_strobe = 0;
    d->ser_rx_data = 0;
    d->ser_rx_end = 0;
    d->ser_rx_parity = 0;
    d->ser_rx_framing = 0;
    d->ser_plugged = 0;
    d->chaos_address = 0;
    d->chaos_rx_valid = 0;
    d->chaos_rx_word = 0;
    d->chaos_rx_done = 0;
    d->chaos_rx_bits = 0;
    d->chaos_rx_crc = 0;
    d->chaos_tx_done = 0;
    d->chaos_tx_abort = 0;
    d->chaos_cbl_busy = 0;
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
  // The two buffers, by direction and sequence: 0 a packet a `CRX` row lands,
  // 1 a buffer a `CTX` row says the card handed over.
  std::map<std::pair<int, long>, std::vector<unsigned>> bufs;
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
    if (!std::strncmp(line, "CBUF ", 5)) {
      int dir;
      long seq, k;
      unsigned w;
      if (std::sscanf(line + 5, "%d %ld %lx %x", &dir, &seq, &k, &w) != 4) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, line);
        return 2;
      }
      std::vector<unsigned> &v = bufs[std::make_pair(dir, seq)];
      if ((long)v.size() != k) {
        std::fprintf(stderr, "%s: buffer %d/%ld is out of order at %ld\n", path, dir, seq, k);
        return 2;
      }
      v.push_back(w);
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
      got = std::sscanf(p, "%ld %ld %ld %ld %ld %x %x %d %x %x" FACE_FMT, &r.n, &r.ns, &r.ssyn,
                        &r.slip, &r.off, &r.uaddr, &r.reg_, &r.write, &r.wdata, &r.rdata,
                        FACE_ARGS);
      if (got != 10 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "KEY") || !std::strcmp(tag, "BTN")) {
      unsigned v;
      got = std::sscanf(p, "%ld %ld %x" FACE_FMT, &r.n, &r.ns, &v, FACE_ARGS);
      if (got != 3 + kFaceCols) got = 0;
      if (!std::strcmp(tag, "KEY")) {
        r.tag = kKey;
        r.code = v;
      } else {
        r.tag = kBtn;
        r.mask = v;
      }
    } else if (!std::strcmp(tag, "MOVE")) {
      r.tag = kMove;
      got = std::sscanf(p, "%ld %ld %ld %ld" FACE_FMT, &r.n, &r.ns, &r.dx, &r.dy, FACE_ARGS);
      if (got != 4 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "SER")) {
      r.tag = kSer;
      got = std::sscanf(p, "%ld %ld %d" FACE_FMT, &r.n, &r.ns, &r.ready, FACE_ARGS);
      if (got != 3 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "INIT") || !std::strcmp(tag, "FACE")) {
      r.tag = !std::strcmp(tag, "INIT") ? kInit : kFace;
      got = std::sscanf(p, "%ld %ld" FACE_FMT, &r.n, &r.ns, FACE_ARGS);
      if (got != 2 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "CTX")) {
      r.tag = kCtx;
      got = std::sscanf(p, "%ld %ld %ld %ld" FACE_FMT, &r.n, &r.ns, &r.seq, &r.len, FACE_ARGS);
      if (got != 4 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "CRX")) {
      r.tag = kCrx;
      got = std::sscanf(p, "%ld %ld %ld %lx %ld %d %d" FACE_FMT, &r.n, &r.ns, &r.seq, &r.bits,
                        &r.len, &r.crc, &r.busy, FACE_ARGS);
      if (got != 7 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "CTD")) {
      r.tag = kCtd;
      got = std::sscanf(p, "%ld %ld %d" FACE_FMT, &r.n, &r.ns, &r.abort, FACE_ARGS);
      if (got != 3 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "CBL")) {
      r.tag = kCbl;
      got = std::sscanf(p, "%ld %ld %d" FACE_FMT, &r.n, &r.ns, &r.busy, FACE_ARGS);
      if (got != 3 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "STK") || !std::strcmp(tag, "SDN") ||
               !std::strcmp(tag, "SRE")) {
      // `SRE` is the received frame's own end, `Pci::rx_times`' second
      // instant: the echoing modes put the echoed character on the cable
      // there, and a seam carrying only `SRX` could not place it.
      r.tag = !std::strcmp(tag, "STK") ? kStk : !std::strcmp(tag, "SDN") ? kSdn : kSre;
      got = std::sscanf(p, "%ld %ld" FACE_FMT, &r.n, &r.ns, FACE_ARGS);
      if (got != 2 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "SRX") || !std::strcmp(tag, "SOUT")) {
      r.tag = !std::strcmp(tag, "SRX") ? kSrx : kSout;
      got = std::sscanf(p, "%ld %ld %x" FACE_FMT, &r.n, &r.ns, &r.data, FACE_ARGS);
      if (got != 3 + kFaceCols) got = 0;
    } else if (!std::strcmp(tag, "SPL")) {
      r.tag = kSpl;
      got = std::sscanf(p, "%ld %ld %d" FACE_FMT, &r.n, &r.ns, &r.plugged, FACE_ARGS);
      if (got != 3 + kFaceCols) got = 0;
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
      {"chaos_vector", want_h("chaos_vector"), 270},
      {"chaos_first", want_h("chaos_first"), 764140},
      {"chaos_last", want_h("chaos_last"), 764156},
      {"serial_first", want_h("serial_first"), 764160},
      {"serial_last", want_h("serial_last"), 764176},
      {"chaos_writable", want_h("chaos_writable"), 67},
      {"chaos_buffer_words", want_h("chaos_buffer_words"), 256},
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
    // **WHAT IS PUSHED AND WHAT IS NOT, AND THE RULE IS THE GENERATOR'S OWN
    // SHAPE.**  A row is pushed only where the generator MUTATES the board
    // between two rows at one nanosecond --- a press, `-UB INIT`, the RS-232
    // cable going in or out --- because then muir has two different faces at
    // that instant and a clocked fabric needs two ticks for them.
    //
    // The far end's rows mutate nothing: muir's `advance` applies them from
    // the clock, so EVERY row at that instant carries the state with them
    // already in it, and they belong on one tick with all of their inputs
    // sampled by the same edge.  Pushing them apart is what made the second
    // of two at one instant a tick late.
    const bool mutates = (r.tag == kKey || r.tag == kInit || r.tag == kSpl);
    const bool from_outside = mutates || r.tag == kCrx || r.tag == kCtd || r.tag == kCbl ||
                              r.tag == kStk || r.tag == kSdn || r.tag == kSrx;
    if (mutates && want == prev_cmp) {
      want = prev_cmp + 1;
      ++pushed;
    }
    r.cmp_tick = want;
    // What reaches the card from outside lands where it is compared; a move
    // and a switch land at their own instant, because what they change is an
    // input the card samples on its own clock.
    r.act_tick = from_outside ? want : r.ns / kTick;
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
    if (c.answered && AnswerNs(r.reg_, r.write, r.ns) != r.ssyn) {
      std::fprintf(stderr, "FAIL: row %ld: this check computes -UB SSYN at %ld and muir says %ld\n",
                   r.n, AnswerNs(r.reg_, r.write, r.ns), r.ssyn);
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
    const Tag t = rows[i].tag;
    if (t == kKey || t == kInit || t == kSpl || t == kCrx || t == kCtd || t == kCbl || t == kStk ||
        t == kSdn || t == kSrx || t == kSre)
      strobes.push_back(i);
  }

  // **A PACKET IS STREAMED IN BEFORE IT LANDS.**  muir's interface takes a
  // frame whole at one instant; the card's receive buffer is filled a word a
  // tick off the seam and committed by `chaos_rx_done`, which is where the
  // trace puts the instant.  So the words go in on the ticks before the
  // `CRX` row and nothing of them is visible until it: `ch_rlen` is the
  // committed length and the fill counter is separate.
  std::vector<std::pair<long, unsigned>> rx_stream;
  {
    long prev = -1;
    for (const auto &r : rows) {
      if (r.tag != kCrx) {
        if (r.cmp_tick > prev) prev = r.cmp_tick;
        continue;
      }
      const std::vector<unsigned> &w = bufs[std::make_pair(0, r.seq)];
      if ((long)w.size() != r.len) {
        std::fprintf(stderr, "FAIL: row %ld says %ld words and the trace carries %zu\n", r.n,
                     r.len, w.size());
        return 1;
      }
      const long from = r.cmp_tick - (long)w.size() - 1;
      if (from <= prev) {
        std::fprintf(stderr, "FAIL: row %ld leaves no room to stream %zu words in\n", r.n,
                     w.size());
        return 1;
      }
      for (size_t k = 0; k < w.size(); ++k) rx_stream.push_back({from + (long)k, w[k]});
      prev = r.cmp_tick;
    }
  }

  // Where the card must strobe a character onto the cable, and where it must
  // say a frame is to go: at those ticks and at no others.
  std::set<long> sout_ticks, txgo_ticks;
  for (const auto &r : rows) {
    if (r.tag == kSout) sout_ticks.insert(r.cmp_tick);
    if (r.tag == kCyc && !r.write && r.reg_ == kChaosStart) txgo_ticks.insert(r.ssyn / kTick);
  }

  Dut b;
  Encoders enc;
  b.d->chaos_address = (unsigned)want_h("chaos_address");
  int switches = 0;
  int plugged = 0, cbl_busy = 0;
  size_t ci = 0, ri = 0, si = 0, xi = 0;
  // What the card has handed over since the last `CTX` row.
  std::vector<unsigned> tx_seen;
  long tx_go_seen = 0, tx_words = 0, sout_seen = 0, rx_words = 0;
  unsigned addr_held = 0, wdata_held = 0;
  int write_held = 0;

  // **THE 2651'S SYN1, SYN2 AND DLE REGISTERS, AND WHAT HOLDS THEM.**  The
  // trace has no column for them and cannot have one: muir keeps them
  // (`Pci::syn`, `Pci::next_syn`) and exposes no accessor, and nothing on the
  // chip or the board reads them back --- synchronous mode is what they are
  // for and this board never enters it.  So this is the one thing in this run
  // held to the Signetics sheet rather than to muir, and it is a model of
  // Table 4 fed BY THE TRACE'S OWN CYCLES: a write of the status address goes
  // to the register the pointer names and the pointer counts 0, 1, 2, 0; a
  // read of the command register puts it back, "the pointers are reset ... by
  // performing a Read Command Register operation"; and `RESET` clears all
  // four.  Nothing here reads the DUT, which is the shadow-memory rule.
  struct Syn {
    unsigned syn1 = 0, syn2 = 0, dle = 0, ptr = 0;
    unsigned face() const { return syn1 | (syn2 << 8) | (dle << 16) | (ptr << 24); }
    void wrote(unsigned v) {
      if (ptr == 0) syn1 = v & 0xFFu;
      else if (ptr == 1) syn2 = v & 0xFFu;
      else dle = v & 0xFFu;
      ptr = (ptr == 2) ? 0 : ptr + 1;
    }
  } syn;
  long syn_writes = 0, syn_resets = 0, syn_wraps = 0;

  long answered = 0, unanswered = 0, reads = 0, writes = 0, slips = 0, serial_slips = 0;
  long presses = 0, moves = 0, inits = 0, faces = 0, sers = 0, btns = 0, ctxs = 0, sres = 0;
  long compared_rdata = 0, compared_faces = 0, compared_syn = 0;
  std::set<long> phases;
  std::map<unsigned, long> saw_reads, saw_writes, saw_vectors;
  Row nowhere;
  std::memset(&nowhere, 0, sizeof nowhere);

  // The placement can push a row one tick past the trace's own last instant,
  // so the run goes on until every row has been compared --- bounded, so that
  // a row that can never be reached is a failure and not a hang.
  for (long t = 0; (t <= last_tick || ri < rows.size()) && t <= last_tick + 64 && bad < 25; ++t) {
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
    b.d->chaos_rx_done = 0;
    b.d->chaos_tx_done = 0;
    b.d->chaos_tx_abort = 0;
    b.d->ser_tx_take = 0;
    b.d->ser_tx_done = 0;
    b.d->ser_rx_strobe = 0;
    b.d->ser_rx_end = 0;
    // Nothing in the trace raises either: muir's behavioural 2651 does not
    // model them and says so, so the run holds them at zero over the whole
    // trace and the second configuration below is what raises them.
    b.d->ser_rx_parity = 0;
    b.d->ser_rx_framing = 0;
    b.d->chaos_rx_valid = 0;
    if (xi < rx_stream.size() && rx_stream[xi].first == t) {
      b.d->chaos_rx_valid = 1;
      b.d->chaos_rx_word = rx_stream[xi].second;
      ++xi;
      ++rx_words;
    }
    while (si < strobes.size() && rows[strobes[si]].act_tick == t) {
      const Row &r = rows[strobes[si]];
      switch (r.tag) {
        case kKey:
          b.d->kbd_strobe = 1;
          b.d->kbd_code = r.code;
          break;
        case kInit:
          b.d->ub_init = 1;
          break;
        case kSer:
          // The old `SER` rows moved the 2651 directly, before the chip was
          // on this card.  They move it through its own registers now, so
          // there is nothing for this row to drive: what it still says is
          // what the card's ready line must be, and the face below holds it.
          break;
        case kCrx:
          b.d->chaos_rx_done = 1;
          b.d->chaos_rx_bits = (unsigned)r.bits;
          b.d->chaos_rx_crc = r.crc;
          cbl_busy = r.busy;
          break;
        case kCtd:
          b.d->chaos_tx_done = 1;
          b.d->chaos_tx_abort = r.abort;
          break;
        case kCbl:
          cbl_busy = r.busy;
          break;
        case kStk:
          b.d->ser_tx_take = 1;
          break;
        case kSdn:
          b.d->ser_tx_done = 1;
          break;
        case kSrx:
          b.d->ser_rx_strobe = 1;
          b.d->ser_rx_data = r.data;
          break;
        case kSre:
          b.d->ser_rx_end = 1;
          break;
        case kSpl:
          plugged = r.plugged;
          break;
        default:
          break;
      }
      ++si;
    }
    b.d->chaos_cbl_busy = cbl_busy;
    b.d->ser_plugged = plugged;

    b.Rise();

    // `RESET` --- `-INIT*` into the 8837 at IOBXCV 0F06 is the 2651's own
    // reset pin --- takes the chip back to its default, the SYN registers and
    // their pointer with it.
    if (b.d->ub_init) syn = Syn();

    // What the card hands the two far ends.  The transmit buffer streams out
    // from the tick after START; a character reaches the cable exactly where
    // a `SOUT` row says and nowhere else, and a frame is offered exactly
    // where START was read.
    if (b.d->chaos_tx_valid) {
      tx_seen.push_back(b.d->chaos_tx_word);
      ++tx_words;
    }
    if (b.d->chaos_tx_go) {
      ++tx_go_seen;
      if (!txgo_ticks.count(t)) {
        nowhere.n = -1;
        nowhere.ns = t * kTick;
        Fail(t, nowhere, "chaos_tx_go with no read of START", 1, 0);
      }
    }
    if (b.d->ser_tx_strobe) {
      ++sout_seen;
      if (!sout_ticks.count(t)) {
        nowhere.n = -1;
        nowhere.ns = t * kTick;
        Fail(t, nowhere, "a character on the cable that muir did not send", b.d->ser_tx_data, 0);
      }
    }

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
          if (r.reg_ >= kSerialFirst && r.reg_ <= kSerialLast) {
            ++serial_slips;
            if (r.slip != 2)
              Fail(t, r, "the serial port's answer is not two short of a tick", r.slip, 2);
          } else if (r.reg_ != kUsecLowReg) {
            Fail(t, r, "an answer off the 5 ns grid at a register that should be on it", r.reg_,
                 kUsecLowReg);
          }
        }
        // The SYN model moves where the word crosses, which is this tick:
        // `land` in the card is the edge `-UB SSYN` rises at.
        if (c.write && r.reg_ == kSerialStatus) {
          if (syn.ptr == 2) ++syn_wraps;
          syn.wrote(r.wdata);
          ++syn_writes;
        } else if (!c.write && r.reg_ == kSerialCommand) {
          if (syn.ptr != 0) ++syn_resets;
          syn.ptr = 0;
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
      // `SER.IREQ` is the card's own now: the 2651's `-RxRDY` or `-TxRDY`,
      // which are `SR1` and `SR0` of the status byte it assembles.
      const int serrdy = (b.d->ser_status & 0x3) != 0;
      if (serrdy != r.serrdy) Fail(t, r, "the serial port's ready line", serrdy, r.serrdy);
      if (b.d->chaos_csr != r.ccsr) Fail(t, r, "the Chaosnet CSR", b.d->chaos_csr, r.ccsr);
      if (b.d->chaos_bits != r.cbits) Fail(t, r, "the Chaosnet bit counter", b.d->chaos_bits, r.cbits);
      if (b.d->ser_mode1 != r.sm1) Fail(t, r, "the 2651's mode register 1", b.d->ser_mode1, r.sm1);
      if (b.d->ser_mode2 != r.sm2) Fail(t, r, "the 2651's mode register 2", b.d->ser_mode2, r.sm2);
      if (b.d->ser_cmd != r.scmd) Fail(t, r, "the 2651's command register", b.d->ser_cmd, r.scmd);
      if (b.d->ser_status != r.sstat) Fail(t, r, "the 2651's status register", b.d->ser_status, r.sstat);
      if (b.d->ser_syn_face != syn.face())
        Fail(t, r, "the 2651's SYN registers and their pointer", b.d->ser_syn_face, syn.face());
      else ++compared_syn;
      if (r.intr != 0) saw_vectors[r.intr]++;
      switch (r.tag) {
        case kKey: ++presses; break;
        case kInit: ++inits; break;
        case kSer: ++sers; break;
        case kFace: ++faces; break;
        case kSre: ++sres; break;
        case kSout:
          // The character the card put on the cable, at the instant muir's
          // shift register delivered it.
          if (!b.d->ser_tx_strobe)
            Fail(t, r, "no character on the cable", 0, r.data);
          else if (b.d->ser_tx_data != r.data)
            Fail(t, r, "the character on the cable", b.d->ser_tx_data, r.data);
          break;
        case kCtx: {
          // The transmit buffer the card handed over since the last such
          // row: the words came over the bus and it must give them back, in
          // order and with nothing else.
          const std::vector<unsigned> &w = bufs[std::make_pair(1, r.seq)];
          if ((long)tx_seen.size() != r.len) {
            Fail(t, r, "words handed over for the frame", tx_seen.size(), r.len);
          } else {
            for (size_t k = 0; k < w.size(); ++k) {
              if (tx_seen[k] != w[k]) {
                Fail(t, r, "a word of the transmit buffer", tx_seen[k], w[k]);
                break;
              }
            }
          }
          tx_seen.clear();
          ++ctxs;
          break;
        }
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
  s.d->chaos_address = (unsigned)want_h("chaos_address");
  long dec_answers = 0, dec_silent = 0;
  for (long u = 0; u < kUbAddresses && bad < 25; ++u) {
    for (int w = 0; w < 2; ++w) {
      const unsigned reg = dec[w][u];
      const long msyn_t = s.tick;
      const bool ours = (reg != kNoReg);
      const long ssyn_t = ours ? AnswerNs(reg, w, msyn_t * kTick) / kTick : 0;
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
                         reg == kNoReg ? "nothing answers" : "this card answers",
                         msyn_t * kTick);
          }
          ++bad;
        }
        s.Fall();
      }
      if (ours) ++dec_answers;
      else ++dec_silent;
      s.d->ub_msyn = 0;
      s.Idle(1);
    }
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d disagreements over the decode\n", bad);
    return 1;
  }

  // ---- the priority chain, driven through the cards' own registers --------
  //
  // **ALL FOUR VECTORS ARE COMPARED AGAINST muir ABOVE NOW**, `0o270`
  // included: the trace plugs a Chaosnet interface in, which is what no
  // trace against this model could do before.  What this block adds is the
  // CONTENTION, which the trace does not reach --- the Chaosnet asking while
  // the serial port and the keyboard are, and the clock over all three ---
  // held to page IOBINT's own two equations, `V2 = (SER AND NOT CHAOS) OR
  // CLOCK` and `V3 = CLOCK OR CHAOS`.  Every request here is raised through
  // a register a program writes and not through a wire this check drives.
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
    // The 2651 asynchronous at eight bits, 19,200 baud on its internal
    // clock, transmitter and receiver enabled with the cable in: `SR0` comes
    // up and `SER.IREQ` with it.
    p.d->ser_plugged = 1;
    cycle(kSerialMode, 1, 0116);
    cycle(kSerialMode, 1, 0177);
    cycle(kSerialCommand, 1, 0047);
    want_vector("the serial port over the keyboard", 0264);
    // The Chaosnet interface's Transmit Done is up from power-up, so its own
    // enable is all it takes.
    cycle(kChaosCsr, 1, 0040);
    want_vector("the Chaosnet over the serial port", 0270);
    cycle(kClock, 1, 0);               // an interval of zero is over at once
    want_vector("the clock over everything", 0274);
    cycle(kCsr, 1, 0207);              // the clock's enable away
    want_vector("the Chaosnet again", 0270);
    cycle(kChaosCsr, 1, 0);
    want_vector("the serial port again", 0264);
    cycle(kSerialCommand, 1, 0);
    want_vector("the keyboard again", 0260);
    cycle(kKbdLow, 0, 0);              // the low half's read clears KBD READY
    want_vector("nothing waiting", 0);
    if (bad) return 1;
  }

  // ---- the parity and framing flags, which no trace against muir can reach -
  //
  // **muir'S BEHAVIOURAL 2651 RAISES NEITHER AND SAYS SO**: "the break the
  // transmitter can force and the framing and parity errors the receiver can
  // raise ... need a far end that sends bits rather than characters --- the
  // netlist board has one".  So `SR3` and `SR5` are zero on every row of the
  // trace above, and a check that only ever compares against zero passes a
  // card whose flags are stuck there --- the DDR bridge's lesson, at a status
  // byte.  This configuration raises them, and what it holds is the Signetics
  // sheet rather than muir: the receiver latches each with the character it
  // belongs to, a later character does not clear one, `CR4` clears all three
  // error bits together and is not itself stored, and the receiver's own gate
  // decides whether anything is latched at all.
  //
  // Both flags arrive on the seam, `ser_rx_parity` and `ser_rx_framing`,
  // because a parity bit that did not agree and a stop bit that was low are
  // properties of the FRAME and this card has nothing bit-wise in it.
  // Nothing on the board drives either today: `cadr_serial_line.sv` holds
  // both low, a TCP socket carrying bytes and not bits.
  {
    Dut q;
    q.Idle(4);
    auto cycle = [&](unsigned addr, int write, unsigned wdata) {
      q.d->ub_msyn = 1;
      q.d->ub_addr = addr;
      q.d->ub_write = write;
      q.d->ub_wdata = wdata;
      long waited = 0;
      do {
        q.Rise();
        q.Fall();
        ++waited;
      } while (!q.d->ub_ssyn && waited < 600);
      const unsigned got = q.d->ub_rdata;
      q.d->ub_msyn = 0;
      q.Idle(2);
      return got;
    };
    // One character off the seam, with the two flags its frame carried.
    auto rx = [&](unsigned data, int par, int frm) {
      q.d->ser_rx_strobe = 1;
      q.d->ser_rx_data = data;
      q.d->ser_rx_parity = par;
      q.d->ser_rx_framing = frm;
      q.Rise();
      q.Fall();
      q.d->ser_rx_strobe = 0;
      q.d->ser_rx_parity = 0;
      q.d->ser_rx_framing = 0;
      q.Idle(2);
    };
    auto want_status = [&](const char *when, unsigned mask, unsigned want) {
      if ((q.d->ser_status & mask) != want) {
        std::fprintf(stderr,
                     "FAIL: the 2651's error flags, %s: the status byte is 0%o and under mask "
                     "0%o that is 0%o, where the sheet says 0%o\n",
                     when, q.d->ser_status, mask, q.d->ser_status & mask, want);
        ++bad;
      }
    };
    // `SR5 SR4 SR3`, framing, overrun and parity: what `CR4` clears.
    constexpr unsigned kErrors = 0070u;
    constexpr unsigned kParity = 0010u, kOverrun = 0020u, kFraming = 0040u;
    constexpr unsigned kRxReady = 0002u;
    // Asynchronous 16X, eight bits, one stop; 19,200 baud on the internal
    // clock both ways; the receiver and transmitter on with the cable in.
    q.d->ser_plugged = 1;
    cycle(kSerialMode, 1, 0116);
    cycle(kSerialMode, 1, 0177);
    cycle(kSerialCommand, 1, 0047);
    rx(0125, 0, 0);
    want_status("a clean character", kErrors | kRxReady, kRxReady);
    if (cycle(kSerialFirst, 0, 0) != (0177400u | 0125u)) {
      std::fprintf(stderr, "FAIL: the clean character did not reach the holding register\n");
      ++bad;
    }
    // A parity error, then a framing error one character later: each is
    // latched with its own character and NEITHER clears the other.
    rx(0252, 1, 0);
    want_status("a character whose parity was wrong", kErrors, kParity);
    cycle(kSerialFirst, 0, 0);
    rx(0063, 0, 1);
    want_status("a framing error after a parity error", kErrors, kParity | kFraming);
    cycle(kSerialFirst, 0, 0);
    // A clean one does not clear what stands.
    rx(0007, 0, 0);
    want_status("a clean character after two bad ones", kErrors, kParity | kFraming);
    // An overrun on top, so that all three stand together and `CR4` is shown
    // clearing the set and not one bit of it.
    rx(0011, 0, 0);
    want_status("a character on a full holding register", kErrors, kParity | kFraming | kOverrun);
    // `CR4` is a command and not a bit: it clears the three and is not
    // stored, which the command register's read-back says.
    cycle(kSerialCommand, 1, 0047 | 0020);
    want_status("RESET ERROR", kErrors, 0);
    if (cycle(kSerialCommand, 0, 0) != (0177400u | 0047u)) {
      std::fprintf(stderr, "FAIL: RESET ERROR was stored in the command register\n");
      ++bad;
    }
    // And the gate: with the receiver not running --- the cable out, so
    // `-DCD` is up --- a frame with both errors is not this receiver's and
    // nothing is latched.  `Pci::receive` breaks on `rx_runs` before it
    // looks at a character at all.
    cycle(kSerialFirst, 0, 0);
    q.d->ser_plugged = 0;
    q.Idle(2);
    rx(0377, 1, 1);
    want_status("a frame arriving with the receiver stopped", kErrors | kRxReady, 0);
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
  same("directions the decode answers", dec_answers, trace_answers);
  same("transmit buffers handed over", ctxs, want_h("ctx_rows"));
  same("words of them", tx_words, want_h("ctx_words"));
  same("frames offered to the far end", tx_go_seen, want_h("ctx_rows"));
  same("characters put on the cable", sout_seen, want_h("sout_rows"));
  same("received frames ended", sres, want_h("sre_rows"));
  same("words streamed into the receive buffer", rx_words, want_h("crx_words"));
  same("answers off the grid at the serial port", serial_slips, want_h("offgrid_serial"));
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
  // The SYN model is fed by the trace and is worth nothing if the trace
  // stopped feeding it: four writes so the pointer wraps at three, and a read
  // of the command register that actually had a pointer to put back.
  if (syn_writes < 4 || syn_wraps < 1 || syn_resets < 1) {
    std::fprintf(stderr,
                 "FAIL: the trace no longer exercises the SYN registers: %ld writes, %ld wraps of "
                 "the pointer, %ld reads of the command register that moved it\n",
                 syn_writes, syn_wraps, syn_resets);
    return 1;
  }
  if (pushed != kPushedRows || slips == 0 || presses < 10 || moves < 10 || btns < 8 ||
      sers < 2 || ctxs < 5) {
    std::fprintf(stderr,
                 "FAIL: the placement or the trace is not what this check was written against: "
                 "%ld rows pushed, %ld off-grid answers, %ld presses, %ld moves, %ld switch masks, "
                 "%ld serial rows, %ld buffers handed over\n",
                 pushed, slips, presses, moves, btns, sers, ctxs);
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
      "    %ld of the answers fall off the 5 ns grid: %ld are the microsecond counter's low half\n"
      "    and the rest EVERY cycle of the serial port's group, whose half-microsecond clock has\n"
      "    a phase of 203 ns; %ld of the 200 phases of -UB MSYN in the card's microsecond were used.\n"
      "    %ld presses, %ld moves, %ld switch masks, %ld -UB INIT pulses, %ld faces between cycles.\n"
      "    The decode: %ld directions answered and %ld silent over all %ld directions of an\n"
      "    eighteen-bit ub_addr, read and written, a real bus cycle each.  NOTHING IS EXEMPT: the\n"
      "    Chaosnet interface's group (0%o-0%o) and the serial port's (0%o-0%o) are answered here\n"
      "    now, and every direction ioboard::answers decodes is compared.\n"
      "    The Chaosnet: %ld frames offered at a read of START carrying %ld words, compared against\n"
      "    what the bus wrote; %ld words streamed back into the receive buffer.  The serial port:\n"
      "    %ld characters put on the cable at the instant muir's shift register delivered them.\n"
      "    All four vectors are compared against muir, 0o270 included; the contention no trace\n"
      "    reaches is held to page IOBINT's equations, through the cards' own registers.\n"
      "    The two echoing modes put %ld characters back on the line at the end of the received\n"
      "    frame, which is what the SRE rows are and what the card could not place before.\n"
      "    The 2651's SYN1, SYN2 and DLE registers and their pointer are compared on all %ld rows\n"
      "    against Table 4 rather than against muir, which keeps them and has no accessor: %ld\n"
      "    writes, %ld wraps of the pointer, %ld reads of the command register that moved it.\n"
      "    A second configuration raises the parity and framing flags, which muir's own 2651\n"
      "    never does, and holds CR4 clearing all three errors together and storing none of them.\n",
      b.tick, want_h("last_ns"), rows.size(), pushed, (long)cycs.size(), reads, writes, compared_rdata,
      unanswered, slips, slips - serial_slips, (long)phases.size(), presses, moves, btns, inits,
      faces, dec_answers,
      dec_silent, (long)kUbAddresses * 2, kChaosFirst, kChaosLast, kSerialFirst, kSerialLast,
      ctxs, tx_words, rx_words, sout_seen, sres, compared_syn, syn_writes, syn_wraps,
      syn_resets);
  return 0;
}
