// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE KRIA KR260'S MEMORY PORT LATENCY PROBE, THROUGH ITS TOP LEVEL**:
// `boards/kria-kr260/quux15_kr260.sv` simulated around the processing
// system's simulation (`tb/cadr_ps8_sim.sv`), the Xilinx primitives' stubs
// and the core as a shell (`tb/quux15_core_shell.sv`), as
// `tb/quux15_zynq_reset_tb.cpp` builds it.  The shell's master port is
// driven from here and `S_AXI_HP0_FPD`'s memory is modeled here, so the
// machine's traffic goes through `quux_axi_narrow128.sv` to the port, and
// the port's own handshakes are timed here, edge for edge, as the probe
// (`rtl/plumbing/quux15_mem_probe.sv`) is to time them: a read from its
// address taken to its last beat taken, a write from its address taken to
// its response taken.  The probe is started and stopped with the console
// face's keys and read on its page 3, words 48 to 56, over
// `M_AXI_HPM1_FPD`, as the board's software reads it.
//
// WHAT IS HELD:
//   - word 48 reads the marker with the probe stopped out of reset, and the
//     figures read zero though the port has answered (nothing is counted
//     before RUN);
//   - a run started with reads and writes already taken by the port and
//     unanswered, under traffic with random readies on both sides (the
//     master's RREADY and BREADY among them), line fills of one burst and of
//     two, writes of one beat, two beats and two bursts, and a tail of long
//     answers: every count, sum and longest equal to the port's handshakes
//     timed here, and the marker with lost and saturated clear;
//   - the port's reset with addresses taken and unanswered: the figures
//     kept through it (they are the fabric's), the probe's queues forgotten
//     with the port's transactions, the next run exact again;
//   - thirty-two write bursts taken and unanswered at once, what sixteen
//     posted writes split at 4 KiB can put in flight: not lost, and exact.

#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>

#include "Vquux15_kr260.h"
#include "Vquux15_kr260__Dpi.h"
#include "Vquux15_kr260___024root.h"
#include "svdpi.h"
#include "verilated.h"

using Top = Vquux15_kr260;
using Root = Vquux15_kr260___024root;
#define CORE_I(n) (r->quux15_kr260__DOT__u_core__DOT__tbi_##n)
#define CORE_O(n) (r->quux15_kr260__DOT__u_core__DOT__tbo_##n)

namespace {

constexpr unsigned kFace = 0xB0000000u;
constexpr unsigned kProbeWord = 48;
constexpr uint32_t kRunKey = 0x5052554Eu, kStopKey = 0x53544F50u;
constexpr uint32_t kMarker = 0x50420000u;

Top *top = nullptr;
Root *r = nullptr;
long t = 0;
int fails = 0;
int level0 = 0;
std::mt19937_64 rng(0x6b70726f6265ull);
bool Chance(double p) { return std::uniform_real_distribution<double>(0, 1)(rng) < p; }
long Uni(long lo, long hi) { return std::uniform_int_distribution<long>(lo, hi)(rng); }

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: the Kria KR260's probe, clock %ld: ", t);
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

// --- The figures, timed here at the port's handshakes.
struct Figures {
  uint64_t rn = 0, rs = 0, rm = 0, wn = 0, ws = 0, wm = 0;
};
Figures want;
bool counting = false;  // answers in the run's window

// --- S_AXI_HP0_FPD's memory: in order, random readies, random latencies.
struct Burst {
  long stamp;   // the edge its address was taken at
  int beats;    // beats still to come (reads) or still to be taken (writes)
  long due;     // the earliest edge its first beat (read) or its B (write) may be driven at
};
std::deque<Burst> ar_q, aw_q;
bool gate = true;        // answers let out
double p_ready = 0.7;    // the port's ARREADY, AWREADY and WREADY
bool m_awready = false, m_wready = false, m_bvalid = false, m_arready = false, m_rvalid = false, m_rlast = false;
long protocol = 0;       // a W beat with no address taken, or other nonsense

long Delay() {
  if (Chance(0.03)) return Uni(200, 2000);
  return Uni(3, 40);
}

// --- The master, the shell's port: line fills and posted writes.
struct Line {
  int bursts;        // 1 or 2
  int first_len;     // the first burst's beats
};
int r_issued = 0;            // bursts of the current line whose address is taken
int r_bursts_open = 0;       // bursts whose address is taken and last beat not yet
bool r_line = false;         // a line is being read
Line line{};
long reads_left = 0;         // lines still to ask for
struct WBurst {
  int beats;
};
std::deque<WBurst> aw_todo, w_todo;   // bursts whose address, and whose beats, are still to go
int w_beat = 0;                       // beats of w_todo's head already taken
long w_open = 0;                      // bursts whose address is taken and B not yet
long writes_left = 0;                 // words still to write
long w_cap = 16;                      // the most bursts this master keeps unanswered
double p_rready = 0.8, p_bready = 0.8;

void MasterReset() {
  r_issued = r_bursts_open = 0;
  r_line = false;
  reads_left = writes_left = 0;
  aw_todo.clear();
  w_todo.clear();
  w_beat = 0;
  w_open = 0;
}

bool Idle() {
  return !r_line && reads_left == 0 && aw_todo.empty() && w_todo.empty() && w_open == 0 && writes_left == 0 &&
         ar_q.empty() && aw_q.empty();
}

// What the master drives for the next edge.
void Drive() {
  CORE_O(m_arsize) = 3;
  CORE_O(m_awsize) = 3;
  CORE_O(m_arburst) = 1;
  CORE_O(m_awburst) = 1;
  CORE_O(m_awid) = 0;
  // A new line once the last is in.
  if (!r_line && reads_left > 0) {
    --reads_left;
    r_line = true;
    r_issued = 0;
    line.bursts = Chance(0.3) ? 2 : 1;
    line.first_len = line.bursts == 2 ? static_cast<int>(Uni(1, 4)) : 5;
  }
  if (r_line && r_issued < line.bursts) {
    const int len = r_issued == 0 ? line.first_len : 5 - line.first_len;
    if (!CORE_O(m_arvalid)) CORE_O(m_araddr) = static_cast<uint32_t>(0x5A000000u + 40u * Uni(0, 100000));
    CORE_O(m_arlen) = static_cast<uint8_t>(len - 1);
    CORE_O(m_arvalid) = 1;
  } else {
    CORE_O(m_arvalid) = 0;
  }
  CORE_O(m_rready) = Chance(p_rready);
  // Writes: a word as one beat, two beats, or two bursts of one.
  while (writes_left > 0 && aw_todo.size() < 4) {
    --writes_left;
    const int kind = static_cast<int>(Uni(0, 9));
    if (kind < 5) {
      aw_todo.push_back({1});
      w_todo.push_back({1});
    } else if (kind < 9) {
      aw_todo.push_back({2});
      w_todo.push_back({2});
    } else {
      aw_todo.push_back({1});
      w_todo.push_back({1});
      aw_todo.push_back({1});
      w_todo.push_back({1});
    }
  }
  if (!aw_todo.empty() && w_open < w_cap) {
    if (!CORE_O(m_awvalid)) CORE_O(m_awaddr) = static_cast<uint32_t>(0x5A000000u + 8u * Uni(0, 1000000));
    CORE_O(m_awlen) = static_cast<uint8_t>(aw_todo.front().beats - 1);
    CORE_O(m_awvalid) = 1;
  } else {
    CORE_O(m_awvalid) = 0;
  }
  if (!w_todo.empty()) {
    CORE_O(m_wvalid) = 1;
    CORE_O(m_wdata) = rng();
    CORE_O(m_wstrb) = 0x1F;
    CORE_O(m_wlast) = w_beat + 1 == w_todo.front().beats;
  } else {
    CORE_O(m_wvalid) = 0;
  }
  CORE_O(m_bready) = Chance(p_bready);
}

void Tick() {
  CORE_O(rst_on) = CORE_I(rst) || CORE_I(rst_req);
  CORE_O(rst_pend) = 0;
  CORE_O(rst_cut) = 0;
  const bool held = CORE_I(rst);
  if (held) {
    MasterReset();
    CORE_O(m_arvalid) = 0;
    CORE_O(m_awvalid) = 0;
    CORE_O(m_wvalid) = 0;
    CORE_O(m_rready) = 1;
    CORE_O(m_bready) = 1;
  }
  top->clk25 = 0;
  top->eval();
  // The master's handshakes at this edge, as they stand before it.
  const bool ar_hs = CORE_O(m_arvalid) && CORE_I(m_arready);
  const bool aw_hs = CORE_O(m_awvalid) && CORE_I(m_awready);
  const bool w_hs = CORE_O(m_wvalid) && CORE_I(m_wready);
  const bool r_hs = CORE_I(m_rvalid) && CORE_O(m_rready);
  const bool r_last = r_hs && CORE_I(m_rlast);
  const bool b_hs = CORE_I(m_bvalid) && CORE_O(m_bready);
  top->clk25 = 1;
  top->eval();
  ++t;
  if (held) return;
  if (ar_hs) {
    ++r_issued;
    ++r_bursts_open;
    CORE_O(m_arvalid) = 0;
  }
  if (r_last) {
    --r_bursts_open;
    if (r_issued == line.bursts && r_bursts_open == 0) r_line = false;
  }
  if (aw_hs) {
    aw_todo.pop_front();
    ++w_open;
    CORE_O(m_awvalid) = 0;
  }
  if (w_hs) {
    if (++w_beat == w_todo.front().beats) {
      w_todo.pop_front();
      w_beat = 0;
    }
  }
  if (b_hs) --w_open;
  Drive();
}

void Run(long n) {
  for (long i = 0; i < n; ++i) Tick();
}

template <typename F>
long Until(F cond, long limit) {
  for (long i = 0; i <= limit; ++i) {
    if (cond()) return i;
    Tick();
  }
  return -1;
}

// --- The processing system's loads and stores on the face's port (GP 1),
// --- as `tb/quux15_zynq_reset_tb.cpp` makes them.
int gp_state = 0;
unsigned gp_addr = 0, gp_data = 0, gp_read = 0;
bool aw_out = false, w_out = false, ar_out = false;

}  // namespace

void cadr_sim_gp(int port, svBit awready, svBit wready, svBit bvalid, int, int, svBit arready, svBit rvalid,
                 int rdata, int, int, svBit, int *awaddr, int *awlen, int *awid, svBit *awvalid, int *wdata,
                 int *wstrb, svBit *wlast, svBit *wvalid, svBit *bready, int *araddr, int *arlen, int *arid,
                 svBit *arvalid, svBit *rready) {
  *awaddr = *awlen = *awid = *wdata = *wstrb = *araddr = *arlen = *arid = 0;
  *awvalid = *wvalid = *wlast = *arvalid = 0;
  *bready = *rready = 1;
  if (port != 1) return;
  static bool aw_drv = false, w_drv = false, ar_drv = false;
  if (gp_state == 1) {
    if (aw_drv && awready) aw_out = false;
    if (w_drv && wready) w_out = false;
    if (!aw_out && !w_out) gp_state = 2;
  } else if (gp_state == 2 && bvalid) {
    gp_state = 0;
  } else if (gp_state == 3 && ar_drv && arready) {
    ar_out = false;
    gp_state = 4;
  } else if (gp_state == 4 && rvalid) {
    gp_read = static_cast<unsigned>(rdata);
    gp_state = 0;
  }
  aw_drv = aw_out;
  w_drv = w_out;
  ar_drv = ar_out;
  *awaddr = static_cast<int>(gp_addr);
  *araddr = static_cast<int>(gp_addr);
  *wdata = static_cast<int>(gp_data);
  *wstrb = 0xF;
  *wlast = 1;
  *awvalid = aw_out;
  *wvalid = w_out;
  *arvalid = ar_out;
}

// S_AXI_HP0_FPD (port 0): the machine's memory.  The call is made at the
// edge with what the fabric drove before it; a handshake is that and what
// this side drove from the last edge.
void cadr_sim_mem(int port, svBit rst, int, int awlen, int, svBit awvalid, long long, int, svBit wlast, svBit wvalid,
                  svBit bready, int, int arlen, int, svBit arvalid, svBit rready, svBit *awready, svBit *wready,
                  svBit *bvalid, int *bresp, int *bid, svBit *arready, svBit *rvalid, long long *rdata, int *rresp,
                  int *rid, svBit *rlast) {
  *awready = *wready = *bvalid = *arready = *rvalid = *rlast = 0;
  *bresp = *bid = *rresp = *rid = 0;
  *rdata = 0;
  if (port != 0) return;
  const long e = t;
  if (rst) {
    ar_q.clear();
    aw_q.clear();
    m_awready = m_wready = m_bvalid = m_arready = m_rvalid = m_rlast = false;
    return;
  }
  // The handshakes at this edge.
  if (arvalid && m_arready) ar_q.push_back({e, arlen + 1, e + Delay()});
  if (m_rvalid && rready) {
    Burst &b = ar_q.front();
    if (--b.beats == 0) {
      if (!m_rlast) ++protocol;
      if (counting) {
        const uint64_t lat = static_cast<uint64_t>(e - b.stamp);
        ++want.rn;
        want.rs += lat;
        if (lat > want.rm) want.rm = lat;
      }
      ar_q.pop_front();
    }
    m_rvalid = false;
  }
  if (awvalid && m_awready) aw_q.push_back({e, awlen + 1, -1});
  if (wvalid && m_wready) {
    Burst *b = nullptr;
    for (auto &x : aw_q)
      if (x.beats > 0) {
        b = &x;
        break;
      }
    if (!b) {
      ++protocol;
    } else if (--b->beats == 0) {
      if (!wlast) ++protocol;
      b->due = e + Delay();
    }
  }
  if (m_bvalid && bready) {
    const Burst &b = aw_q.front();
    if (counting) {
      const uint64_t lat = static_cast<uint64_t>(e - b.stamp);
      ++want.wn;
      want.ws += lat;
      if (lat > want.wm) want.wm = lat;
    }
    aw_q.pop_front();
    m_bvalid = false;
  }
  // What this side drives from this edge.
  m_arready = Chance(p_ready);
  m_awready = Chance(p_ready);
  m_wready = Chance(p_ready);
  if (!m_rvalid && gate && !ar_q.empty() && e >= ar_q.front().due && Chance(0.7)) {
    m_rvalid = true;
    m_rlast = ar_q.front().beats == 1;
  }
  if (!m_bvalid && gate && !aw_q.empty() && aw_q.front().beats == 0 && e >= aw_q.front().due) m_bvalid = true;
  *awready = m_awready;
  *wready = m_wready;
  *arready = m_arready;
  *rvalid = m_rvalid;
  *rlast = m_rvalid && m_rlast;
  *bvalid = m_bvalid;
}

int cadr_sim_level(int which) { return which == 0 ? level0 : 0; }

namespace {

void FaceWrite(unsigned k, unsigned v) {
  gp_addr = kFace + 4 * k;
  gp_data = v;
  aw_out = w_out = true;
  gp_state = 1;
  for (int i = 0; i < 400 && gp_state != 0; ++i) Tick();
  Check(gp_state == 0, "the face's word %u was not answered", k);
}
unsigned FaceRead(unsigned k) {
  gp_addr = kFace + 4 * k;
  ar_out = true;
  gp_state = 3;
  for (int i = 0; i < 400 && gp_state != 0; ++i) Tick();
  Check(gp_state == 0, "the face's word %u read was not answered", k);
  return gp_read;
}

// Page 3 read, the probe stopped, against the figures timed here.
Figures ReadProbe(const char *when, uint32_t *w48) {
  uint32_t w[9];
  for (unsigned k = 0; k < 9; ++k) w[k] = FaceRead(kProbeWord + k);
  *w48 = w[0];
  Figures f;
  f.rn = w[1];
  f.rs = w[2] | (static_cast<uint64_t>(w[3] & 0xFFFF) << 32);
  f.rm = w[4];
  f.wn = w[5];
  f.ws = w[6] | (static_cast<uint64_t>(w[7] & 0xFFFF) << 32);
  f.wm = w[8];
  Check(w[0] == kMarker, "%s: word 48 reads %08x, wanting %08x (the marker, stopped, not lost, not saturated)", when,
        w[0], kMarker);
  return f;
}

void Compare(const char *when, const Figures &got) {
  Check(got.rn == want.rn && got.rs == want.rs && got.rm == want.rm,
        "%s: the probe's reads are %" PRIu64 ", sum %" PRIu64 ", longest %" PRIu64 "; the port's handshakes give %" PRIu64
        ", %" PRIu64 ", %" PRIu64, when, got.rn, got.rs, got.rm, want.rn, want.rs, want.rm);
  Check(got.wn == want.wn && got.ws == want.ws && got.wm == want.wm,
        "%s: the probe's writes are %" PRIu64 ", sum %" PRIu64 ", longest %" PRIu64 "; the port's handshakes give %" PRIu64
        ", %" PRIu64 ", %" PRIu64, when, got.wn, got.ws, got.wm, want.wn, want.ws, want.wm);
}

void Drain(long limit) {
  const long n = Until([] { return Idle(); }, limit);
  Check(n >= 0, "the traffic did not drain in %ld clocks (reads open %d, writes open %ld)", limit, r_bursts_open,
        w_open);
}

// Traffic already in flight at RUN: addresses taken, the answers held until
// after the RUN key's write is answered.
void RunFromInFlight(long lines, long words) {
  gate = false;
  reads_left = 1;
  writes_left = 6;
  Until([] { return r_bursts_open > 0 && w_open >= 4; }, 2000);
  Check(r_bursts_open > 0 && w_open >= 4, "no traffic in flight before RUN (reads %d, writes %ld)", r_bursts_open,
        w_open);
  want = Figures{};
  FaceWrite(kProbeWord, kRunKey);
  Run(4);
  counting = true;
  Check(FaceRead(kProbeWord) == (kMarker | 1), "word 48 reads %08x running, wanting %08x", FaceRead(kProbeWord),
        kMarker | 1);
  gate = true;
  reads_left += lines;
  writes_left += words;
}

void StopDrained(long limit) {
  Drain(limit);
  Run(8);
  counting = false;
  FaceWrite(kProbeWord, kStopKey);
  Run(4);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Top;
  r = top->rootp;
  top->eval();
  Run(20);
  level0 = 1;
  Check(Until([] { return CORE_I(rst) == 0; }, 100) >= 0, "the core never left reset with its port live");
  Run(20);

  // ---- Out of reset: the marker, stopped, and nothing counted before RUN.
  {
    reads_left = 40;
    writes_left = 200;
    Drain(400000);
    Run(8);
    uint32_t w48;
    want = Figures{};
    const Figures f = ReadProbe("before any RUN", &w48);
    Compare("before any RUN", f);
    Check(protocol == 0, "%ld beats the port could not place", protocol);
  }

  // ---- A run started under traffic in flight.
  Figures first;
  {
    RunFromInFlight(3000, 12000);
    StopDrained(2000000);
    uint32_t w48;
    first = ReadProbe("the first run", &w48);
    Compare("the first run", first);
    Check(want.rn > 3000 && want.wn > 12000, "the first run timed %" PRIu64 " reads and %" PRIu64 " writes", want.rn,
          want.wn);
    Check(want.rm > 200 && want.wm > 200, "the first run's longest read %" PRIu64 " and write %" PRIu64
          " are not the tail's", want.rm, want.wm);
  }

  // ---- The port's reset with addresses taken and unanswered.
  {
    gate = false;
    reads_left = 1;
    writes_left = 8;
    Until([] { return r_bursts_open > 0 && w_open >= 6; }, 2000);
    Check(r_bursts_open > 0 && w_open >= 6, "no traffic in flight before the port's reset");
    // Nothing more asked for; then the port's reset.
    reads_left = writes_left = 0;
    aw_todo.clear();
    Run(4);
    level0 = 0;
    Check(Until([] { return CORE_I(rst) != 0; }, 100) >= 0, "the core was not reset with its port");
    Run(50);
    level0 = 1;
    gate = true;
    Check(Until([] { return CORE_I(rst) == 0; }, 100) >= 0, "the core never left reset after its port");
    Run(20);
    // The figures are the fabric's: the first run's, through the port's reset.
    {
      uint32_t w48;
      const Figures kept = ReadProbe("through the port's reset", &w48);
      Check(kept.rn == first.rn && kept.rs == first.rs && kept.rm == first.rm && kept.wn == first.wn &&
                kept.ws == first.ws && kept.wm == first.wm,
            "through the port's reset the probe reads %" PRIu64 " reads and %" PRIu64 " writes, wanting the first "
            "run's %" PRIu64 " and %" PRIu64, kept.rn, kept.wn, first.rn, first.wn);
    }
    RunFromInFlight(1000, 4000);
    StopDrained(2000000);
    uint32_t w48;
    const Figures f = ReadProbe("after the port's reset", &w48);
    Compare("after the port's reset", f);
  }

  // ---- Thirty-two write bursts unanswered at once.
  {
    w_cap = 32;
    p_bready = 1.0;
    gate = false;
    writes_left = 0;
    want = Figures{};
    FaceWrite(kProbeWord, kRunKey);
    Run(4);
    counting = true;
    for (int i = 0; i < 32; ++i) aw_todo.push_back({1}), w_todo.push_back({1});
    const long n = Until([] { return w_open == 32; }, 20000);
    Check(n >= 0, "only %ld write bursts were taken unanswered, wanting 32", w_open);
    Run(30);
    gate = true;
    StopDrained(200000);
    uint32_t w48;
    const Figures f = ReadProbe("thirty-two writes in flight", &w48);
    Compare("thirty-two writes in flight", f);
    Check(want.wn == 32, "the run timed %" PRIu64 " writes, wanting 32", want.wn);
  }
  Check(protocol == 0, "%ld beats the port could not place", protocol);

  delete top;
  if (fails) {
    std::fprintf(stderr, "quux15 Kria KR260 probe: FAILED, %d checks\n", fails);
    return 1;
  }
  std::printf("quux15 Kria KR260 probe: ok, page 3 equal to the port's handshakes: %" PRIu64 " reads (mean %.2f, "
              "longest %" PRIu64 ") and %" PRIu64 " writes (mean %.2f, longest %" PRIu64 ") in the first run; exact "
              "after the port's reset and with 32 writes in flight\n",
              first.rn, first.rn ? double(first.rs) / first.rn : 0.0, first.rm, first.wn,
              first.wn ? double(first.ws) / first.wn : 0.0, first.wm);
  return 0;
}
