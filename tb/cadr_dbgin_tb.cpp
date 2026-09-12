// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The debug cable's debuggee end: muir plays the debugger through a window of
// memory-mapped registers, and the machine on the other side of MIT's cable
// runs its boot PROM out of the same trace `tb/cadr_microcycle_tb.cpp` drives
// it from.
//
// **WHAT IS HELD TO muir, AND WHERE THE REFERENCE IS.**
//
//   the four strobes      `busint::DEBUG_CYCLE`, `DEBUG_STATUS`,
//                         `DEBUG_MODIFIER` and `DEBUG_ADDRESS`, the 74S139 at
//                         DBGIN 0A15 decoding `DEBUG IN A<1:0>`
//
//   a register strobe is  `Rtl::try_debug_request`, which sets the answer for
//   acknowledged at once  any strobe but `DEBUG_CYCLE` at the instant the
//                         request is made --- the 74S10 at DBGIN 0A14 is a
//                         gate --- and a cycle never
//
//   the latches' edge     `Busint::debug_latch`: the 74LS374s take
//                         `DBD<15:0>` under `-DB ADR0 CLK` and the 25LS2519
//                         `DBD<2:0>` under `-DB ADR1 CLK`, both at the
//                         strobe's TRAILING edge
//
//   the address           `Busint::debug_unibus_address`, `UAO<16:1>` from
//                         the latches with `UAO17` from the modifier and bit
//                         0 always zero
//
//   the status word       `Machine::debug_status` and `Rtl::try_debug_request`
//                         writing it as `0xff00 | status`: the Am8304 at
//                         REQERR 0B15 drives `DBD<7:0>` and the cable's
//                         pull-ups carry the rest
//
//   the master's instants `busint::DEBUG_MSYN_NS` from the grant to
//                         `-UB MSYN`, `busint::DIAGNOSTIC_NS` to the register
//                         block's `-UB SSYN`, `busint::DEBUG_RELEASE_NS` from
//                         the lift to `DBUB MASTER` clearing
//
//   no timeout for this   `Rtl::debug_ack`: "a cycle at an address nothing
//   master                answers is never acknowledged, there being no
//                         timeout for this master"
//
//   what a halt means     `spy_write(CLK, 0)`, muir/tests/lashup.rs:152-157,
//                         which is CC's first act on a debuggee --- and the
//                         program counter read back afterwards is compared
//                         against `build/rtl.golden`'s own column for the
//                         microcycle the machine stopped at, through the same
//                         `SpyWord` reconstruction `tb/cadr_console_tb.cpp`
//                         uses.  **That is the claim the slice exists to
//                         make**: muir's own debugger, over MIT's own cable,
//                         halts this machine and reads a register whose value
//                         muir wrote down.
//
// **WHAT IS A PROPERTY AND NOT muir.**  The register window itself.  No muir
// reference exists for it, as none exists for `cadr_axi_master.sv`: what
// holds it is the AXI3 protocol, read-back, and the layout muir's
// `src/fabric.rs` stores into.  Every transaction is counted handshake by
// handshake, one a channel; every address on the port answers; and the
// hazards muir issue #95 names are the subject of the phases below rather
// than a claim in a comment.
//
// **THE HAZARDS, AND WHERE EACH IS ASKED FOR.**
//
//   a request whose parts  phase 1 watches the cable EVERY TICK: the levels
//   cross in one store     stand `LEAD_T` ticks before `-DEBUG IN REQ` falls
//                          and `LEAD_T` ticks after it rises, and no level
//                          ever moves on the tick the request does.  Phase 8
//                          stores `CTL` with three byte lanes and requires
//                          that no request is made at all
//
//   a split store makes    phase 1 latches the modifier and the address and
//   the wrong strobe       requires each to take the word of the store that
//                          made its own request --- a second request is
//                          placed the tick the first is lifted and refused,
//                          which is the only way the levels could move at the
//                          latching edge
//
//   the 11.05 us timeout   phase 5 runs a cycle at an address no slave claims
//   and the Xbus's 4.25    and requires that NOTHING acknowledges it and that
//                          the fabric runs no timer of its own for two
//                          thousand ticks --- twice the debugger's own
//                          11.05 us at the 10 ns tick, and five times the
//                          bus's 4.25
//
//   the watchdog and its   phase 6 leaves a cycle standing past `WATCHDOG_T`
//   sequence number        and requires the adapter to lift it, to say so in
//                          `FAULTS`, to give the machine its Unibus back, and
//                          to report a sequence the debugger can tell from
//                          its own
//
// **AND THE STATUS BYTE IS SOMEBODY ELSE'S**, driven into the harness and
// changed between two reads, because a check that hands the DUT the value it
// should produce tests nothing and a constant would pass a module that drove
// a constant.

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "Vcadr_dbgin_harness.h"
#include "verilated.h"

namespace {

constexpr int kTickNs = 5;

// The trace's columns, in the order golden/src/rtl.rs prints them.
enum Col {
  kCycle, kPc, kIr, kQ, kA, kM, kAlu, kR, kOb, kDc, kOpc, kSt, kLc,
  kWmapd, kDestspcd, kIwrited, kImodd, kPdlwrited, kSpushd, kNop, kNVmaok,
  kJcond, kPcs1, kPcs0, kSrun,
  kLpc, kMd, kVma, kPromdis, kErrstop, kStathenb, kSpeed1, kSpeed0,
  kStall, kHalted, kBus, kAck, kGnt, kSintr, kNs,
  kColumns
};

struct Row {
  uint64_t v[kColumns];
};

bool ParseRow(const char *line, Row &r) {
  const char *p = line;
  for (int i = 0; i < kColumns; ++i) {
    char *end = nullptr;
    r.v[i] = std::strtoull(p, &end, 16);
    if (end == p) return false;
    p = end;
  }
  return true;
}

// The window, as `rtl/plumbing/cadr_debug_window.sv` parameterises it and as
// muir's `src/fabric.rs` names it.
constexpr uint32_t kBase     = 0x80000080u;
constexpr uint32_t kIdent    = 0x44425547u;   // "DBUG"
constexpr uint32_t kUnmapped = ~kIdent;
constexpr uint32_t kLift     = 0x4C494654u;   // "LIFT"
constexpr long     kLeadT    = 100 / 5;       // busint::DEBUG_OUT_REQUEST_NS
constexpr long     kMsynT    = 100 / 5;       // busint::DEBUG_MSYN_NS
constexpr long     kReleaseT = 100 / 5;       // busint::DEBUG_RELEASE_NS
// `busint::DIAGNOSTIC_NS` is fifty ticks, and the fifty-first is the edge at
// which the master asserted `-UB MSYN`: **a level settled at the end of tick
// t is what tick t+1's edge consumes**, and `cadr_spy_registers.sv` counts
// from the first edge that sees the strobe.  That block's own timing is held
// to muir by `build/machine.pass` and is not this check's to re-derive; what
// is this check's is that the debug master waits for the slave's own answer
// and acknowledges exactly there, which is what a constant rather than a
// range says.
constexpr long     kSsynT    = 250 / 5 + 1;
constexpr long     kWatchdogT = 4096;         // the harness's own, shrunk

uint32_t Win(unsigned i) { return kBase + 4u * i; }
enum WinReg { kWIdent = 0, kWCtl = 1, kWSts = 2, kWClear = 3, kWFaults = 4 };

// muir's `fabric::` bit positions.
constexpr uint32_t kReq       = 1u;
constexpr uint32_t kWr        = 1u << 1;
constexpr uint32_t kAShift    = 2;
constexpr uint32_t kSeqShift  = 8;
constexpr uint32_t kSeqMask   = 0xfu;
constexpr uint32_t kDbdShift  = 16;
constexpr uint32_t kAck_      = 1u << 1;
constexpr uint32_t kDrv       = 1u << 3;
constexpr uint32_t kMark      = 1u << 14;
constexpr uint32_t kMarkMask  = 3u << 14;
constexpr uint32_t kCountShift = 16;
constexpr uint32_t kFaultWatchdog  = 1u;
constexpr uint32_t kFaultOnRequest = 1u << 1;
constexpr uint32_t kFaultIdleLift  = 1u << 2;

// busint::DEBUG_CYCLE and the three after it.
constexpr unsigned kACycle = 0, kAStatus = 1, kAModifier = 2, kAAddress = 3;

// spy::BASE and the registers CC uses.  `spy::CLK` is 3, written; `spy::PC`
// is 5 and `spy::FLAG_1` is 8, read.
constexpr uint32_t kSpyBase = 0766000u;
constexpr unsigned kSpyClk = 3, kSpyPc = 5, kSpyFlag1 = 8;
uint32_t SpyAddr(unsigned e) { return kSpyBase + 2u * e; }

// An address on the Unibus that no slave in this fabric claims: below the
// diagnostic block and nowhere near the I/O board, which is not in this
// harness at all.
constexpr uint32_t kDeadAddr = 0760000u;

// muir's own two constants, tests/spy.rs:703-707.
constexpr uint16_t kFlag1Running = 0xe800u | 0x100u;
constexpr uint16_t kFlag1Halted  = 0xe800u;

int bad = 0;
long tick = 0;

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  std::fprintf(stderr, "tick %ld: %s is 0x%llx, the reference says 0x%llx\n",
               tick, what, got, want);
  if (++bad >= 20) {
    std::fprintf(stderr, "FAIL: stopping after %d mismatches\n", bad);
    std::exit(1);
  }
}

void Say(const char *what) {
  std::fprintf(stderr, "tick %ld: %s\n", tick, what);
  if (++bad >= 20) {
    std::fprintf(stderr, "FAIL: stopping after %d mismatches\n", bad);
    std::exit(1);
  }
}

// What `Engine::spy_read` answers for this microcycle, off the reference's own
// columns: `tb/cadr_console_tb.cpp`'s reconstruction, muir/src/spy.rs bit for
// bit.  The cable reads the same sixteen registers the console does, through
// MIT's own path instead of ours, so the reference is the same.
uint16_t SpyWord(const Row &r, int eadr, bool halted) {
  const uint64_t ir = r.v[kIr];
  switch (eadr) {
    case 0: return static_cast<uint16_t>(ir);
    case 1: return static_cast<uint16_t>(ir >> 16);
    case 2: return static_cast<uint16_t>(ir >> 32);
    case 3: return 0xffffu;                        // spy::OPEN_READ
    case 4: return static_cast<uint16_t>(r.v[kOpc] & 0x3fffu);
    case 5: return static_cast<uint16_t>(r.v[kPc] & 0x3fffu);
    case 6: return static_cast<uint16_t>(r.v[kOb]);
    case 7: return static_cast<uint16_t>(r.v[kOb] >> 16);
    case 8: {
      uint16_t w = 0xe000u;
      if (r.v[kPromdis]) w |= 1u << 12;
      w |= 1u << 11;
      if (r.v[kHalted]) w |= 1u << 10;
      if (!halted && r.v[kSrun]) w |= 1u << 8;
      return w;
    }
    case 9: {
      uint16_t w = 0xc0c0u;
      if (r.v[kWmapd]) w |= 1u << 13;
      if (r.v[kDestspcd]) w |= 1u << 12;
      if (r.v[kIwrited]) w |= 1u << 11;
      if (r.v[kImodd]) w |= 1u << 10;
      if (r.v[kPdlwrited]) w |= 1u << 9;
      if (r.v[kSpushd]) w |= 1u << 8;
      if (r.v[kNop]) w |= 1u << 4;
      if (r.v[kNVmaok]) w |= 1u << 3;
      if (r.v[kJcond]) w |= 1u << 2;
      if (r.v[kPcs1]) w |= 1u << 1;
      if (r.v[kPcs0]) w |= 1u;
      return w;
    }
    case 10: return static_cast<uint16_t>(r.v[kM]);
    case 11: return static_cast<uint16_t>(r.v[kM] >> 16);
    case 12: return static_cast<uint16_t>(r.v[kA]);
    case 13: return static_cast<uint16_t>(r.v[kA] >> 16);
    case 14: return static_cast<uint16_t>(r.v[kSt]);
    case 15: return static_cast<uint16_t>(r.v[kSt] >> 16);
    default: return 0;
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";
  // How many microcycles of the trace to stream past the cable's own phases.
  // The whole of it is 600,000; the default is the whole of it and the
  // Makefile does not shorten it.
  const size_t limit = (argc > 2) ? std::strtoull(argv[2], nullptr, 0) : 0;

  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // The trace is streamed, not held, as `tb/cadr_microcycle_tb.cpp` reads it.
  // One pass for the acknowledgement times, one to drive.
  std::vector<uint64_t> ack_for, rdata_for;
  std::vector<bool> arbitrated;
  size_t total_rows = 0;
  {
    char line[512];
    std::vector<uint64_t> bus_at, acks, mds;
    std::vector<char> stalled_srcmd;
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "%s: row %zu has the wrong column count\n", path,
                     total_rows);
        return 2;
      }
      acks.push_back(r.v[kAck]);
      mds.push_back(r.v[kMd]);
      stalled_srcmd.push_back(r.v[kStall] != 0);
      if (r.v[kBus]) bus_at.push_back(total_rows);
      ++total_rows;
    }
    rdata_for.assign(total_rows, 0);
    for (size_t i = 0; i < total_rows; ++i)
      rdata_for[i] = stalled_srcmd[i] ? mds[i]
                                      : (i + 1 < total_rows ? mds[i + 1] : mds[i]);
    ack_for.assign(total_rows, 0);
    arbitrated.assign(total_rows, false);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
      if (j != i)
        for (size_t x = i; x <= j && x < total_rows; ++x) arbitrated[x] = true;
    }
  }
  if (total_rows < 2) {
    std::fprintf(stderr, "FAIL: %s carries %zu microcycles\n", path, total_rows);
    return 1;
  }
  std::rewind(f);

  auto *dut = new Vcadr_dbgin_harness;
  dut->clk = 0;
  dut->rst = 1;
  dut->n_memack = 1;
  dut->n_memgrant = 1;
  dut->n_loadmd = 1;
  dut->rdata = 0;
  dut->sintr = 0;
  dut->s_awvalid = 0; dut->s_wvalid = 0; dut->s_bready = 0;
  dut->s_arvalid = 0; dut->s_rready = 0;
  dut->s_awaddr = 0; dut->s_awlen = 0; dut->s_awid = 0;
  dut->s_wdata = 0; dut->s_wstrb = 0xF; dut->s_wlast = 0;
  dut->s_araddr = 0; dut->s_arlen = 0; dut->s_arid = 0;
  dut->cpu_msyn = 0; dut->cpu_write = 0; dut->cpu_addr = 0; dut->cpu_wdata = 0;
  dut->con_req = 0; dut->con_msyn = 0; dut->con_write = 0; dut->con_addr = 0;
  dut->con_wdata = 0;
  // The status byte, from outside.  `-FREE` in bit 6 and `WRITE THROUGH ENB`
  // in bit 7 are the two `Machine::debug_status` adds to the error register's
  // own; this is a poison pattern and is moved during phase 1.
  dut->err_status = 0x5a;
  dut->eval();

  auto read_next = [&](Row &r) {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      return ParseRow(line, r);
    }
    return false;
  };

  Row cur;
  if (!read_next(cur)) {
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n", path);
    return 1;
  }

  struct Sample {
    uint64_t pc, ir, lpc, opc, st, a, m, alu, r, ob, q, dc, lc, vma, md, vmaok,
        jcond, nop, pcs1, pcs0, iwrited;
  };
  auto take = [&]() {
    return Sample{dut->pc,  dut->ir,    dut->lpc, dut->opc,   dut->st,
                  dut->a,   dut->m,     dut->alu, dut->r,     dut->ob,
                  dut->q,   dut->dc,    dut->lc,  dut->vma,   dut->md,
                  dut->vmaok,
                  dut->jcond, dut->nop, dut->pcs1, dut->pcs0, dut->iwrited};
  };
  dut->rdata = 0;
  dut->sintr = static_cast<uint8_t>(cur.v[kSintr]);
  Sample prev = take();

  size_t k = 0;
  long last_edge = -1;
  uint64_t prev_ns = 0;
  bool bus_outstanding = false;
  long ack_at_tick = 0;
  long lengths_checked = 0, sub_tick = 0, arb_skipped = 0, halt_skipped = 0;
  bool machine_halted = false;
  bool compare_rows = true;      // dropped while the machine is held in reset
  long microcycles = 0;

  // ---- the cable, watched every tick ------------------------------------
  //
  // Every level and the request, as they stood at the end of the last tick,
  // and the tick each last moved.  The two claims are that the levels are
  // `LEAD_T` ticks old when the request falls and stay `LEAD_T` ticks after
  // it rises, and that nothing moves on the tick the request does.
  struct Cable {
    uint8_t req = 0, wr = 0, a = 0;
    uint16_t dbd = 0;
    long levels_at = -1;     // the tick the levels last moved
    long req_at = -1;        // the tick the request last moved
  } cab;
  long lead_min = -1, trail_min = -1;
  long lead_seen = 0, trail_seen = 0;
  bool cable_moved_with_req = false;

  // **THE ACKNOWLEDGEMENT'S OWN LAG, MEASURED AT THE CABLE AND NOT THROUGH A
  // LOAD.**  "Acknowledged at once" is a claim about an instant and a load
  // through the port takes several ticks, so asking a poll whether the answer
  // was quick cannot tell a gate from a bus cycle.  `DEBUG ACK` is
  // `(DBUB MASTER AND SSYN T0) OR NAND(-DB ADR1 CLK, -DB ADR0 CLK, -DB READ
  // STATUS)`: the second half is three gates and the first is a whole Unibus
  // cycle, so the two are told apart by how many ticks after `-DEBUG IN REQ`
  // each rises.  Kept per strobe, since they are different claims.
  long ack_lag_min[4] = {-1, -1, -1, -1};
  long ack_lag_max[4] = {-1, -1, -1, -1};
  long ack_seen[4] = {0, 0, 0, 0};
  long req_down_at = -1;
  uint8_t ack_prev = 0;
  uint16_t dbd_at_ack = 0;
  bool drv_at_ack = false;
  bool lines_moved_since_ack = false;

  // What the debug master's own instants measured out at, over the run.
  long grant_at = -1, msyn_at = -1, ssyn_at = -1, lift_at = -1;
  long msyn_lag_min = -1, msyn_lag_max = -1;
  long release_min = -1, release_max = -1;
  long ssyn_lag_min = -1, ssyn_lag_max = -1;
  long cycles_run = 0;
  uint8_t gnt_prev = 0, msyn_prev = 0, ssyn_prev = 0, dbgreq_prev = 0;

  // What the two latches held, so that a check can say a latch took its word
  // at the lift and not before.
  uint32_t mod_prev = 0, addr_prev = 0;
  long mod_moved_at = -1, addr_moved_at = -1;

  // ---- the AXI master on the window's port -------------------------------
  struct Axi {
    enum { IDLE, AW, W, B, AR, R } st = IDLE;
    uint32_t addr = 0, wdata = 0;
    unsigned len = 0;
    unsigned beat = 0;
    unsigned id = 0;
    uint32_t strb = 0xF;
    std::vector<uint32_t> got;
    bool aw_hs = false, w_hs = false, b_hs = false, ar_hs = false, r_hs = false;
    int hold = 0;
    long aw_n = 0, w_n = 0, b_n = 0, ar_n = 0, r_n = 0;
  } axi;
  uint32_t jitter = 0x13579BDu;
  auto rnd = [&]() { jitter = jitter * 1664525u + 1013904223u; return jitter >> 9; };
  long axi_reads = 0, axi_writes = 0, axi_beats = 0;

  // One tick, in `tb/cadr_microcycle_tb.cpp`'s own order: one evaluation with
  // the clock high, which is the edge, and one with it low, which settles the
  // combinational network for the next.  The order is not a detail --- see
  // that file, and `tb/cadr_console_tb.cpp` which says what moving it costs.
  auto Tick = [&]() {
    dut->n_memgrant = bus_outstanding ? 0 : 1;
    const bool acking = bus_outstanding && tick >= ack_at_tick;
    dut->n_memack = acking ? 0 : 1;
    dut->n_loadmd = acking ? 0 : 1;
    // Poison on a write, for the reason `cadr_microcycle_tb.cpp` gives.
    if (dut->wrcyc)
      dut->rdata = ~static_cast<uint32_t>(rdata_for[k < total_rows ? k : 0]);

    dut->clk = 1;
    dut->eval();

    if (bus_outstanding && dut->n_memack == 0 && dut->n_memrq) {
      bus_outstanding = false;
      dut->n_memack = 1;
      dut->n_memgrant = 1;
    }

    if (dut->clock_edge && k < total_rows && compare_rows) {
      const Row &r = cur;
      if (prev.pc != r.v[kPc]) Fail("PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) Fail("IR", prev.ir, r.v[kIr]);
      if (prev.lpc != r.v[kLpc]) Fail("LPC", prev.lpc, r.v[kLpc]);
      if (prev.opc != r.v[kOpc]) Fail("OPC", prev.opc, r.v[kOpc]);
      if (prev.st != r.v[kSt]) Fail("ST", prev.st, r.v[kSt]);
      if (prev.a != r.v[kA]) Fail("the A bus", prev.a, r.v[kA]);
      if (prev.m != r.v[kM]) Fail("the M bus", prev.m, r.v[kM]);
      if (prev.alu != r.v[kAlu]) Fail("the ALU", prev.alu, r.v[kAlu]);
      if (prev.r != r.v[kR]) Fail("R", prev.r, r.v[kR]);
      if (prev.ob != r.v[kOb]) Fail("OB", prev.ob, r.v[kOb]);
      if (prev.q != r.v[kQ]) Fail("Q", prev.q, r.v[kQ]);
      if (prev.dc != r.v[kDc]) Fail("DC", prev.dc, r.v[kDc]);
      if (prev.lc != r.v[kLc]) Fail("LC", prev.lc, r.v[kLc]);
      if (prev.vma != r.v[kVma]) Fail("VMA", prev.vma, r.v[kVma]);
      if (prev.md != r.v[kMd]) Fail("MD", prev.md, r.v[kMd]);
      if (prev.vmaok == r.v[kNVmaok]) Fail("-VMAOK", !prev.vmaok, r.v[kNVmaok]);
      if (prev.jcond != r.v[kJcond]) Fail("JCOND", prev.jcond, r.v[kJcond]);
      if (prev.nop != r.v[kNop]) Fail("NOP", prev.nop, r.v[kNop]);
      if (prev.pcs1 != r.v[kPcs1]) Fail("PCS1", prev.pcs1, r.v[kPcs1]);
      if (prev.pcs0 != r.v[kPcs0]) Fail("PCS0", prev.pcs0, r.v[kPcs0]);
      if (prev.iwrited != r.v[kIwrited]) Fail("IWRITED", prev.iwrited, r.v[kIwrited]);

      // The microcycle's own length.  A microcycle the cable stopped the
      // clock in the middle of is as long as the halt, so `last_edge` is
      // dropped at each halt and the next edge re-anchors it; the exemption
      // is one microcycle a halt and is counted.  **What this covers and what
      // it does not**: the processor's Unibus master is stimulus in this
      // harness, so a debug cycle cannot lengthen a microcycle here the way
      // it would on the board.  What it does catch is a halt or a start that
      // lost or repeated a microcycle, and a cable that disturbed the
      // generator.
      if (last_edge >= 0) {
        const uint64_t want = r.v[kNs] - prev_ns;
        const uint64_t got = static_cast<uint64_t>(tick - last_edge) * kTickNs;
        if (got != want) {
          const long slip = static_cast<long>(got) - static_cast<long>(want);
          if (arbitrated[k]) ++arb_skipped;
          else if (r.v[kStall] && slip >= -kTickNs && slip <= kTickNs) ++sub_tick;
          else {
            std::fprintf(stderr,
                         "microcycle %zu (PC %" PRIo64 "): length %llu ns, the "
                         "reference says %llu\n",
                         k, r.v[kPc], (unsigned long long)got,
                         (unsigned long long)want);
            ++bad;
          }
        }
        ++lengths_checked;
      }
      last_edge = tick;
      prev_ns = r.v[kNs];
      if (r.v[kBus]) {
        bus_outstanding = true;
        ack_at_tick = tick + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
      }
      ++k;
      if (k < total_rows) {
        if (!read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu\n", path, k);
          ++bad;
        }
        dut->rdata = static_cast<uint32_t>(rdata_for[k]);
        dut->sintr = static_cast<uint8_t>(cur.v[kSintr]);
      }
    }
    if (dut->clock_edge) ++microcycles;

    // -- the AXI state, advanced from the handshakes sampled before the edge
    if (axi.hold > 0) --axi.hold;
    switch (axi.st) {
      case Axi::AW: if (axi.aw_hs) { axi.st = Axi::W; axi.beat = 0; axi.hold = rnd() % 3; } break;
      case Axi::W:
        if (axi.w_hs) {
          if (axi.beat == axi.len) { axi.st = Axi::B; axi.hold = rnd() % 3; }
          else { ++axi.beat; axi.hold = rnd() % 3; }
        }
        break;
      case Axi::B: if (axi.b_hs) axi.st = Axi::IDLE; break;
      case Axi::AR: if (axi.ar_hs) { axi.st = Axi::R; axi.beat = 0; axi.hold = rnd() % 3; } break;
      case Axi::R:
        if (axi.r_hs) {
          if (axi.beat == axi.len) axi.st = Axi::IDLE;
          else { ++axi.beat; axi.hold = rnd() % 3; }
        }
        break;
      default: break;
    }

    // -- what the master offers at the next edge.  **The order is not a
    // detail**: valid and ready are "as they stand before the edge", so the
    // master's own outputs are set here and the handshakes are read after the
    // settling evaluation, which is `tb/cadr_console_tb.cpp`'s order.  Set
    // after the sampling instead, every transaction's first handshake is
    // missed and nothing ever completes --- measured, on the way to this.
    dut->s_awvalid = (axi.st == Axi::AW) && axi.hold == 0;
    dut->s_wvalid  = (axi.st == Axi::W) && axi.hold == 0;
    dut->s_wlast   = (axi.st == Axi::W) && (axi.beat == axi.len);
    dut->s_bready  = (axi.st == Axi::B) && axi.hold == 0;
    dut->s_arvalid = (axi.st == Axi::AR) && axi.hold == 0;
    dut->s_rready  = (axi.st == Axi::R) && axi.hold == 0;

    dut->clk = 0;
    dut->eval();
    prev = take();

    // -- the cable, sampled where it has settled
    {
      const bool levels_moved = cab.wr != dut->cab_wr || cab.a != dut->cab_a ||
                                cab.dbd != dut->cab_dbd_out;
      const bool req_moved = cab.req != dut->cab_req;
      if (levels_moved && req_moved) cable_moved_with_req = true;
      if (req_moved) {
        if (dut->cab_req) {
          // The request falls: the levels have been standing since
          // `levels_at`.  `-DEBUG OUT REQ` is `NAND(SELECT DEBUG, SELECT
          // DEBUG DLYD)` and the delay is one MTD100 section.
          if (cab.levels_at >= 0) {
            const long lead = tick - cab.levels_at;
            if (lead_min < 0 || lead < lead_min) lead_min = lead;
            ++lead_seen;
          }
          req_down_at = tick;
        } else {
          // The request lifts: the levels must not move for a section after
          // it, because that is when the debuggee's latches take `DBD`.
          cab.req_at = tick;
        }
      }
      if (levels_moved && cab.req_at >= 0 && !cab.req) {
        const long trail = tick - cab.req_at;
        if (trail_min < 0 || trail < trail_min) trail_min = trail;
        ++trail_seen;
        cab.req_at = -1;
      }
      if (levels_moved) cab.levels_at = tick;
      // `DEBUG ACK` rising for the request standing now, and the lines as
      // they stood at that instant --- with an undriven byte read as ones,
      // which is what the cable's pull-ups give.  **This is the reference for
      // the carrier's latch**: `cadr_dbgin.sv` drives a read cycle's word
      // LIVE, so the lines move under a standing acknowledgement whenever the
      // machine is running, and the word `STS` gives has to be the one from
      // here and not whatever stands when the Arm gets round to loading.
      if (!ack_prev && dut->cab_ack && req_down_at >= 0) {
        const unsigned a = dut->cab_a & 3u;
        const long lag = tick - req_down_at;
        if (ack_lag_min[a] < 0 || lag < ack_lag_min[a]) ack_lag_min[a] = lag;
        if (lag > ack_lag_max[a]) ack_lag_max[a] = lag;
        ++ack_seen[a];
        dbd_at_ack = static_cast<uint16_t>(
            ((dut->cab_dbd_oe & 2) ? (dut->cab_dbd_in & 0xff00u) : 0xff00u) |
            ((dut->cab_dbd_oe & 1) ? (dut->cab_dbd_in & 0x00ffu) : 0x00ffu));
        drv_at_ack = (dut->cab_dbd_oe != 0);
        lines_moved_since_ack = false;
      } else if (ack_prev && dut->cab_ack) {
        const uint16_t now = static_cast<uint16_t>(
            ((dut->cab_dbd_oe & 2) ? (dut->cab_dbd_in & 0xff00u) : 0xff00u) |
            ((dut->cab_dbd_oe & 1) ? (dut->cab_dbd_in & 0x00ffu) : 0x00ffu));
        if (now != dbd_at_ack) lines_moved_since_ack = true;
      }
      ack_prev = dut->cab_ack;
      cab.req = dut->cab_req;
      cab.wr = dut->cab_wr;
      cab.a = dut->cab_a;
      cab.dbd = dut->cab_dbd_out;
    }

    // -- the debug master's own instants
    {
      if (!dbgreq_prev && dut->dbg_req_o) { grant_at = -1; msyn_at = -1; ssyn_at = -1; }
      if (!gnt_prev && dut->dbg_gnt_o) grant_at = tick;
      if (!msyn_prev && dut->dbg_msyn_o) {
        msyn_at = tick;
        if (grant_at >= 0) {
          const long lag = tick - grant_at;
          if (msyn_lag_min < 0 || lag < msyn_lag_min) msyn_lag_min = lag;
          if (lag > msyn_lag_max) msyn_lag_max = lag;
        }
      }
      if (!ssyn_prev && dut->dbg_ssyn_o) {
        ssyn_at = tick;
        if (msyn_at >= 0) {
          const long lag = tick - msyn_at;
          if (ssyn_lag_min < 0 || lag < ssyn_lag_min) ssyn_lag_min = lag;
          if (lag > ssyn_lag_max) ssyn_lag_max = lag;
        }
        ++cycles_run;
      }
      if (msyn_prev && !dut->dbg_msyn_o) lift_at = tick;
      if (dbgreq_prev && !dut->dbg_req_o && lift_at >= 0 && gnt_prev) {
        const long rel = tick - lift_at;
        if (release_min < 0 || rel < release_min) release_min = rel;
        if (rel > release_max) release_max = rel;
        lift_at = -1;
      }
      gnt_prev = dut->dbg_gnt_o;
      msyn_prev = dut->dbg_msyn_o;
      ssyn_prev = dut->dbg_ssyn_o;
      dbgreq_prev = dut->dbg_req_o;
    }

    // -- the two latches: when each last moved
    if (dut->modifier_o != mod_prev) { mod_prev = dut->modifier_o; mod_moved_at = tick; }
    if (dut->address_o != addr_prev) { addr_prev = dut->address_o; addr_moved_at = tick; }

    // -- the handshakes, as they stand before the edge that consummates them
    axi.aw_hs = dut->s_awvalid && dut->s_awready;
    axi.w_hs  = dut->s_wvalid && dut->s_wready;
    axi.b_hs  = dut->s_bvalid && dut->s_bready;
    axi.ar_hs = dut->s_arvalid && dut->s_arready;
    axi.r_hs  = dut->s_rvalid && dut->s_rready;
    // A response offered before the data is in, or a beat before the address,
    // is a slave answering a transaction nobody made.
    if (dut->s_bvalid && axi.st != Axi::B) Say("BVALID with no write awaiting one");
    if (dut->s_rvalid && axi.st != Axi::R) Say("RVALID with no read awaiting one");
    if (axi.aw_hs) ++axi.aw_n;
    if (axi.w_hs) { ++axi.w_n; ++axi_beats; }
    if (axi.b_hs) {
      ++axi.b_n;
      if (dut->s_bresp != 0) Fail("BRESP", dut->s_bresp, 0);
      if (dut->s_bid != axi.id) Fail("BID", dut->s_bid, axi.id);
    }
    if (axi.ar_hs) ++axi.ar_n;
    if (axi.r_hs) {
      ++axi.r_n;
      if (dut->s_rresp != 0) Fail("RRESP", dut->s_rresp, 0);
      if (dut->s_rid != axi.id) Fail("RID", dut->s_rid, axi.id);
      const bool last = (axi.beat == axi.len);
      if ((dut->s_rlast != 0) != last)
        Fail(last ? "RLAST missing on the last beat"
                  : "RLAST on a beat that is not the last",
             dut->s_rlast, last);
      axi.got.push_back(dut->s_rdata);
    }

    ++tick;
  };

  auto Idle = [&](long n) { for (long i = 0; i < n; ++i) Tick(); };

  // One whole AXI transaction, driven from the tick loop so that the machine
  // runs while a program reads it.  Every one is counted handshake by
  // handshake and exactly one is required on each channel.
  auto Store = [&](uint32_t addr, uint32_t value, uint32_t strb = 0xF) {
    axi.st = Axi::AW; axi.addr = addr; axi.wdata = value; axi.len = 0;
    axi.beat = 0; axi.strb = strb; axi.id = (axi.id + 1) & 0xFFF;
    axi.hold = rnd() % 3;
    axi.aw_n = axi.w_n = axi.b_n = 0;
    dut->s_awaddr = addr; dut->s_awlen = 0; dut->s_awid = axi.id;
    dut->s_wdata = value; dut->s_wstrb = static_cast<uint8_t>(strb);
    long guard = 0;
    while (axi.st != Axi::IDLE) {
      Tick();
      if (++guard > 40000) { Say("a store never completed"); return; }
    }
    ++axi_writes;
    if (axi.aw_n != 1 || axi.w_n != 1 || axi.b_n != 1)
      Fail("the store's handshake count", (axi.aw_n << 8) | (axi.w_n << 4) | axi.b_n,
           0x111);
  };
  auto Load = [&](uint32_t addr, unsigned beats = 1) {
    axi.st = Axi::AR; axi.addr = addr; axi.len = beats - 1; axi.beat = 0;
    axi.got.clear(); axi.id = (axi.id + 1) & 0xFFF;
    axi.hold = rnd() % 3;
    axi.ar_n = axi.r_n = 0;
    dut->s_araddr = addr; dut->s_arlen = static_cast<uint8_t>(beats - 1);
    dut->s_arid = axi.id;
    long guard = 0;
    while (axi.st != Axi::IDLE) {
      Tick();
      if (++guard > 40000) { Say("a load never completed"); return uint32_t(0); }
    }
    ++axi_reads;
    if (axi.ar_n != 1 || axi.r_n != static_cast<long>(beats))
      Fail("the load's handshake count", (axi.ar_n << 8) | axi.r_n,
           0x100 | beats);
    return axi.got.empty() ? uint32_t(0) : axi.got[0];
  };

  // Every load of STS carries the marker, and muir applies the guard to every
  // one and not only the first.
  auto LoadSts = [&]() {
    const uint32_t s = Load(Win(kWSts));
    if ((s & kMarkMask) != kMark) Fail("STS's MARK", s & kMarkMask, kMark);
    return s;
  };
  auto LoadFaults = [&]() {
    const uint32_t s = Load(Win(kWFaults));
    if ((s & kMarkMask) != kMark) Fail("FAULTS's MARK", s & kMarkMask, kMark);
    return s;
  };

  // The request word, muir's `Fabric::debug_request` builds it exactly so.
  unsigned seq = 0;
  auto Ctl = [&](unsigned a, bool write, uint16_t dbd) {
    seq = (seq + 1) & kSeqMask;
    return kReq | (write ? kWr : 0) | ((a & 3u) << kAShift)
           | (seq << kSeqShift) | (uint32_t(dbd) << kDbdShift);
  };

  // **A REQUEST IS THE STORE AND THEN THE LEAD, AND THE TESTBENCH LEARNT THAT
  // THE HARD WAY.**  The adapter puts the levels on the cable at once and
  // brings `-DEBUG IN REQ` down `LEAD_T` ticks later, as the MTD100 at DBGOUT
  // 0A10 does, so a request lifted inside that section never reaches the
  // 74S139 at all --- which is what the real cable does too, `-DEBUG OUT REQ`
  // being low only while `SELECT DEBUG` and its delayed copy are both high.
  // The first draft of this file stored the request and the lift back to back
  // and measured nothing: no strobe was ever made and every latch read zero.
  // muir cannot reach that, an AXI round trip through the interconnect being
  // many times 200 ns, but a testbench can.
  auto Request = [&](uint32_t w) { Store(Win(kWCtl), w); Idle(kLeadT + 4); };
  auto Lift = [&](uint32_t w) { Store(Win(kWCtl), w & ~kReq); Idle(kLeadT + 4); };

  // ------------------------------------------------------------------------
  // out of reset, and the machine running
  // ------------------------------------------------------------------------
  Idle(4);
  dut->rst = 0;
  Idle(4);

  // ------------------------------------------------------- the face
  {
    const uint32_t id = Load(Win(kWIdent));
    if (id != kIdent) Fail("IDENT", id, kIdent);
    for (unsigned i = 5; i < 16; ++i) {
      const uint32_t w = Load(Win(i));
      if (w != kUnmapped) Fail("an unmapped word", w, kUnmapped);
    }
    // Outside the window, in both directions, and a write dropped there.
    const uint32_t below = Load(kBase - 4);
    if (below != kUnmapped) Fail("the word below the window", below, kUnmapped);
    const uint32_t above = Load(kBase + 64);
    if (above != kUnmapped) Fail("the word above the window", above, kUnmapped);
    Store(kBase + 0x4000, 0xDEADBEEFu);
    if (Load(kBase + 0x4000) != kUnmapped) Say("a write outside the window landed");

    // A burst, so that RLAST is on the right beat and no other.
    Load(kBase, 4);
    if (axi.got.size() != 4) Fail("a four-beat read's beats", axi.got.size(), 4);
    else if (axi.got[0] != kIdent || axi.got[1] == kUnmapped)
      Say("a burst walked the wrong addresses");

    // muir's `Fabric::open`: the marker, and an adapter holding nothing.
    const uint32_t s = LoadSts();
    if (s != kMark) Fail("STS at rest", s, kMark);
    const uint32_t fl = LoadFaults();
    if (fl != kMark) Fail("FAULTS at rest", fl, kMark);
    const uint32_t cl = Load(Win(kWClear));
    if (cl != ((kLift & 0xFFFF0000u) | kMark)) Fail("CLEAR at rest", cl, (kLift & 0xFFFF0000u) | kMark);

    // A store of anything but the key does nothing at all.
    Store(Win(kWClear), kLift ^ 1u);
    Store(Win(kWClear), 0);
    Store(Win(kWClear), 0xFFFFFFFFu);
    if (LoadFaults() != kMark) Say("a write to CLEAR that was not the key did something");
  }

  // ------------------------------------------- phase 1: the three strobes
  //
  // The modifier first, because `ADDRESS_17` is a bit of it and every Unibus
  // address in this fabric needs it: `0o766000` is above `0o400000`.
  {
    // bit 0 ADDRESS_17, bit 2 TIMEOUT_INHIBIT.  **Not bit 1**, which is
    // `-DEBUGEE RESET` and would halt the machine; phase 10 is where that is
    // asked for.
    const uint32_t want_mod = 0b101;
    const long mod_before = mod_moved_at;
    const uint32_t w = Ctl(kAModifier, false, static_cast<uint16_t>(want_mod));
    Request(w);
    // Acknowledged at once: the 74S10 at DBGIN 0A14 is a gate, so by the time
    // a load of STS has crossed the port it is long up.
    uint32_t s = LoadSts();
    if (!(s & kReq)) Say("the adapter is not holding the modifier request");
    if (((s >> kSeqShift) & kSeqMask) != seq)
      Fail("STS's sequence", (s >> kSeqShift) & kSeqMask, seq);
    if (!(s & kAck_)) Say("a modifier strobe was not acknowledged at once");
    if (s & kDrv) Say("the debuggee drove DBD under -DB ADR1 CLK");
    // And the latch has NOT taken it yet: the 25LS2519 clocks on the strobe's
    // trailing edge.
    if (mod_moved_at != mod_before)
      Say("the modifier register took its word before the request lifted");
    // The lift.
    Lift(w);
    if (dut->modifier_o != want_mod) Fail("the modifier register", dut->modifier_o, want_mod);
    if (dut->timeout_inhibit_o != 1) Say("-DEBUG TIMEOUT INH does not follow modifier bit 2");
    if (dut->debuggee_reset_o != 0) Say("-DEBUGEE RESET is up with modifier bit 1 clear");
    s = LoadSts();
    if (s & kReq) Say("the adapter is still holding a lifted request");
  }

  // The address latches: `UAO<16:1>`, sixteen bits of `DBD`.
  const uint32_t clk_uaddr = SpyAddr(kSpyClk);
  {
    const uint16_t want = static_cast<uint16_t>((clk_uaddr >> 1) & 0xFFFFu);
    const uint32_t w = Ctl(kAAddress, false, want);
    const long addr_before = addr_moved_at;
    Request(w);
    const uint32_t s = LoadSts();
    if (!(s & kAck_)) Say("an address strobe was not acknowledged at once");
    if (addr_moved_at != addr_before)
      Say("the address latches took their word before the request lifted");
    Lift(w);
    if (dut->address_o != want) Fail("the address latches", dut->address_o, want);
  }

  // The status.  `-DB READ STATUS` drives `DBD<7:0>` and the cable's pull-ups
  // carry the rest, so the word is `0xff00 | status` --- which
  // `Rtl::try_debug_request` already writes that way and the adapter must not
  // zero.  The byte is moved between the two reads, so a module that latched
  // it or drove a constant fails here.
  for (uint8_t st : {uint8_t(0x5a), uint8_t(0xa5)}) {
    dut->err_status = st;
    const uint32_t w = Ctl(kAStatus, false, 0);
    Request(w);
    const uint32_t s = LoadSts();
    if (!(s & kAck_)) Say("a status strobe was not acknowledged at once");
    if (!(s & kDrv)) Say("the debuggee drove nothing under -DB READ STATUS");
    const uint32_t got = s >> kDbdShift;
    const uint32_t want = 0xff00u | st;
    if (got != want) Fail("the status word on DBD", got, want);
    Lift(w);
  }
  dut->err_status = 0x00;

  // ------------------- phase 1b: a lift and the next request, back to back
  //
  // **THIS IS WHERE THE MARGIN AT THE LATCHING EDGE IS MEASURED**, and it has
  // to be here rather than fall out of the phases above, whose own pacing
  // would be what got measured.  `cadr_dbgin.sv` clocks its latch at the edge
  // after the one that dropped `-DEBUG IN REQ`, so what protects it is that
  // the port cannot deliver a second write beat that soon --- four ticks,
  // W_RESP and W_ADDR to get there.  Storing the lift and the next request
  // with nothing at all between them is the closest anything can come, and
  // the first latch must still hold the first word.
  {
    const uint32_t w1 = Ctl(kAModifier, false, 0b101);
    Request(w1);
    Store(Win(kWCtl), w1 & ~kReq);        // the lift, and no waiting
    const uint32_t w2 = Ctl(kAModifier, false, 0b001);
    Store(Win(kWCtl), w2);                // the next request, at once
    if (dut->modifier_o != 0b101)
      Fail("the modifier after a lift the next request trod on",
           dut->modifier_o, 0b101);
    // The second request still has to stand for its own lead before it is
    // lifted, or it makes no strobe --- which is the rule the real cable has
    // and which this file has now tripped over twice.
    Idle(kLeadT + 4);
    Lift(w2);
    if (dut->modifier_o != 0b001)
      Fail("the modifier after the second of two back-to-back requests",
           dut->modifier_o, 0b001);
  }

  // ------------------------------------------ phase 2: the halt, over the cable
  //
  // CC's first act on a debuggee: `spy_write(CLK, 0)`, muir/tests/lashup.rs
  // :152-157.  Three cycles --- the modifier, the address, then the cycle
  // register --- which is `lashup::DebugProgram::dbg_write` exactly.
  auto CableCycle = [&](uint32_t uaddr, bool write, uint16_t word,
                        bool expect_ack, long poll_ticks) {
    // The modifier: `ADDRESS_17` alone, the machine left alone.
    uint32_t w = Ctl(kAModifier, false,
                     static_cast<uint16_t>((uaddr >> 17) & 1u));
    Request(w);
    Lift(w);
    // The address.
    w = Ctl(kAAddress, false, static_cast<uint16_t>((uaddr >> 1) & 0xFFFFu));
    Request(w);
    Lift(w);
    // The cycle.
    w = Ctl(kACycle, write, word);
    Request(w);
    uint32_t s = 0;
    long waited = 0;
    for (;;) {
      s = LoadSts();
      if (((s >> kSeqShift) & kSeqMask) != seq)
        Fail("the cycle's sequence", (s >> kSeqShift) & kSeqMask, seq);
      if (s & kAck_) break;
      if (waited >= poll_ticks) break;
      Idle(16);
      waited += 16;
    }
    const bool acked = (s & kAck_) != 0;
    if (acked != expect_ack)
      Say(expect_ack ? "a cycle at a slave's own address was not acknowledged"
                     : "a cycle at an address nothing answers was acknowledged");
    Lift(w);
    Idle(kReleaseT + 4);
    return s;
  };

  {
    if (dut->run_o != 1) Say("the machine is not running before the halt");
    const long before = microcycles;
    Idle(400);
    if (microcycles == before) Say("the machine retired nothing before the halt");
    CableCycle(clk_uaddr, true, 0, true, 4000);
    // `spy_write(CLK, 0)` --- the write lands at the machine's next look, so
    // give it a microcycle.
    Idle(200);
    if (dut->run_o != 0) Say("RUN is still set after a halt over the cable");
    machine_halted = true;
    const long at = microcycles;
    Idle(2000);
    if (microcycles != at)
      Fail("microcycles retired after the halt", microcycles - at, 0);
    last_edge = -1;   // the halt re-anchors the length comparison
    ++halt_skipped;
  }

  // ------------------------------------ phase 3: the program counter, read back
  //
  // The strongest claim here: muir's own debugger, over MIT's own cable,
  // reads a register whose value muir wrote down.  `k` is the row the machine
  // stopped at and `cur` is that row.
  {
    const Row &r = cur;
    const uint32_t s = CableCycle(SpyAddr(kSpyPc), false, 0, true, 4000);
    if (!(s & kDrv)) Say("the debuggee drove nothing on a read cycle");
    const uint16_t got = static_cast<uint16_t>(s >> kDbdShift);
    const uint16_t want = SpyWord(r, kSpyPc, true);
    if (got != want) Fail("PC read over the debug cable", got, want);

    const uint32_t s2 = CableCycle(SpyAddr(kSpyFlag1), false, 0, true, 4000);
    const uint16_t f1 = static_cast<uint16_t>(s2 >> kDbdShift);
    if (f1 != kFlag1Halted) Fail("FLAG-1 read over the debug cable", f1, kFlag1Halted);

    // And the register with no read select: the floating bus, all ones.
    // muir/src/spy.rs:488.  It is the one value a dead cable and a live one
    // agree on, so it is checked WITH the two above and never alone.
    const uint32_t s3 = CableCycle(SpyAddr(3), false, 0, true, 4000);
    if (static_cast<uint16_t>(s3 >> kDbdShift) != 0xffffu)
      Fail("the open bus read over the debug cable", s3 >> kDbdShift, 0xffffu);
  }

  // ------------------------------------- phase 4: a write cycle drives nothing
  {
    const uint32_t s = CableCycle(SpyAddr(kSpyClk), true, 1, true, 4000);
    if (s & kDrv) Say("the debuggee drove DBD on a write cycle");
    Idle(200);
    if (dut->run_o != 1) Say("RUN is not set after a start over the cable");
    machine_halted = false;
    last_edge = -1;
    ++halt_skipped;
    const long at = microcycles;
    Idle(2000);
    if (microcycles == at) Say("the machine retired nothing after the start");
  }

  // ------------- phase 4b: the word is the one at the acknowledgement
  //
  // **THE CARRIER'S LATCH, MADE LOAD-BEARING.**  `cadr_dbgin.sv` drives a read
  // cycle's word live, as the transceivers do, so with the machine running the
  // lines move under a standing acknowledgement --- MIT's own "read and write
  // at the same address are uncorrelated", the 74LS244s driving `SPY<15:0>`
  // asynchronously.  By the time the Arm gets round to loading `STS`, the word
  // the debuggee drove is long gone unless the adapter took it at the instant
  // `DEBUG IN ACK` first rose, which is what `cable::DebugIn::observe` records
  // on the simulated side.
  //
  // The run is required to have moved the lines, because a check made where
  // nothing moves is a check of nothing --- and that is why this one is here
  // and not beside the halted reads of phase 3.
  {
    if (dut->run_o != 1) Say("the machine is not running for the latch check");
    uint32_t w = Ctl(kAModifier, false,
                     static_cast<uint16_t>((SpyAddr(kSpyPc) >> 17) & 1u));
    Request(w);
    Lift(w);
    w = Ctl(kAAddress, false,
            static_cast<uint16_t>((SpyAddr(kSpyPc) >> 1) & 0xFFFFu));
    Request(w);
    Lift(w);

    const uint32_t wc = Ctl(kACycle, false, 0);
    Request(wc);
    long waited = 0;
    while (!dut->cab_ack && waited < 4000) { Tick(); ++waited; }
    if (!dut->cab_ack) Say("a read cycle with the machine running was never acknowledged");
    const uint16_t at_ack = dbd_at_ack;
    const bool drv = drv_at_ack;

    // Ten microcycles or so under the standing acknowledgement.
    Idle(300);
    if (!lines_moved_since_ack)
      Say("the lines never moved under a standing acknowledgement: the latch "
          "is untested and this phase proves nothing");

    const uint32_t s = LoadSts();
    if (!(s & kAck_)) Say("STS lost an acknowledgement that had already risen");
    if (((s & kDrv) != 0) != drv)
      Fail("DRV against the instant of the acknowledgement", (s & kDrv) != 0, drv);
    if (static_cast<uint16_t>(s >> kDbdShift) != at_ack)
      Fail("the word STS gives against the word on DBD at the acknowledgement",
           s >> kDbdShift, at_ack);
    Lift(wc);
    Idle(kReleaseT + 4);
  }

  // ------------------------- phase 5: a cycle nothing answers, and no timer
  //
  // `Rtl::debug_ack`: "a cycle at an address nothing answers is never
  // acknowledged, there being no timeout for this master".  Two thousand
  // ticks is twice the debugger's own 11.05 us at the 10 ns tick and five
  // times the bus's 4.25, so a fabric that ran either timer would end the
  // cycle inside this window.
  {
    const uint32_t s = CableCycle(kDeadAddr, false, 0, false, 2000);
    if (s & kAck_) Say("a cycle nothing answers was acknowledged");
    if (!(s & kReq)) Say("the adapter let go of a cycle nothing answered");
    const uint32_t fl = LoadFaults();
    if (fl & kFaultWatchdog) Say("the watchdog fired inside the debugger's own timeout");
  }

  // ------------------------------------------------- phase 6: the watchdog
  //
  // A bound nothing exercises is not a bound.  The harness shrinks
  // `WATCHDOG_T` to 4,096 ticks from the module's own one second.
  {
    Store(Win(kWClear), kLift);
    const uint32_t w = Ctl(kAModifier, false, 1);
    Request(w);
    Lift(w);
    const uint32_t wa = Ctl(kAAddress, false,
                            static_cast<uint16_t>((kDeadAddr >> 1) & 0xFFFFu));
    Request(wa);
    Lift(wa);

    const uint32_t wc = Ctl(kACycle, false, 0);
    Request(wc);
    if (!dut->cab_req) Say("the cycle never reached the cable");
    if (!dut->dbg_req_o) Say("-DB NEED UB is not down for a standing cycle");

    // Not yet.
    Idle(kWatchdogT / 2);
    if (!dut->cab_req) Say("the watchdog lifted a request early");

    Idle(kWatchdogT + 256);
    if (dut->cab_req) Say("the watchdog did not lift a standing request");
    if (dut->dbg_req_o) Say("the debug master still holds the Unibus after the watchdog");
    const uint32_t s = LoadSts();
    if (s & kReq) Say("STS still holds a request the watchdog lifted");
    const uint32_t fl = LoadFaults();
    if (!(fl & kFaultWatchdog)) Say("the watchdog fired and FAULTS does not say so");
    // And the machine has its Unibus back: a cycle of the processor's own.
    dut->cpu_addr = SpyAddr(kSpyPc);
    dut->cpu_write = 0;
    dut->cpu_msyn = 1;
    long waited = 0;
    while (!dut->cpu_ssyn && waited < 400) { Tick(); ++waited; }
    if (!dut->cpu_ssyn) Say("the processor's own Unibus cycle never answered after the watchdog");
    dut->cpu_msyn = 0;
    Idle(8);
  }

  // ----------------------------------------------------- phase 7: the faults
  {
    Store(Win(kWClear), kLift);
    if (LoadFaults() != kMark) Say("CLEAR did not clear FAULTS");

    // A lift with nothing standing.
    Store(Win(kWCtl), 0);
    uint32_t fl = LoadFaults();
    if (!(fl & kFaultIdleLift)) Say("a lift with nothing standing is not recorded");
    if ((fl >> kCountShift) != 0) Fail("COUNT after an idle lift", fl >> kCountShift, 0);

    // A request while one stands.
    const uint32_t w = Ctl(kAStatus, false, 0);
    Request(w);
    const uint32_t w2 = Ctl(kAStatus, false, 0xBEEF);
    Store(Win(kWCtl), w2);
    Idle(kLeadT + 4);
    fl = LoadFaults();
    if (!(fl & kFaultOnRequest)) Say("a request while one stands is not recorded");
    if ((fl >> kCountShift) != 1)
      Fail("COUNT after a request that was refused", fl >> kCountShift, 1);
    // And the standing request is untouched: its own sequence, not the second's.
    const uint32_t s = LoadSts();
    if (((s >> kSeqShift) & kSeqMask) != ((w >> kSeqShift) & kSeqMask))
      Fail("the standing request's sequence after a second was refused",
           (s >> kSeqShift) & kSeqMask, (w >> kSeqShift) & kSeqMask);
    Lift(w);
  }

  // --------------------------------------------- phase 8: the partial store
  //
  // A store that does not strobe all four lanes would set `REQ` beside
  // whatever `DBD` the last store left: the split-store hazard by another
  // door.  It makes no request at all.
  {
    Store(Win(kWClear), kLift);
    const long req_rises = lead_seen;
    for (uint32_t strb : {0x1u, 0x3u, 0x7u, 0xEu, 0x0u}) {
      seq = (seq + 1) & kSeqMask;
      Store(Win(kWCtl), kReq | (kACycle << kAShift) | (seq << kSeqShift)
                        | (0xFFFFu << kDbdShift), strb);
      Idle(kLeadT + 8);
      if (dut->cab_req) Say("a byte store made a request on the cable");
    }
    if (lead_seen != req_rises) Say("a byte store brought -DEBUG IN REQ down");
    const uint32_t fl = LoadFaults();
    if ((fl >> kCountShift) != 0)
      Fail("COUNT after five byte stores", fl >> kCountShift, 0);
    const uint32_t s = LoadSts();
    if (s & kReq) Say("a byte store left the adapter holding a request");
  }

  // ------------------------------------------------ phase 9: the arbitration
  {
    Store(Win(kWClear), kLift);
    // The processor holds the bus: the debug master waits and does not
    // truncate the cycle in flight.
    dut->cpu_addr = SpyAddr(kSpyPc);
    dut->cpu_write = 0;
    dut->cpu_msyn = 1;
    Idle(8);
    uint32_t w = Ctl(kAModifier, false, 1);
    Request(w);
    Lift(w);
    w = Ctl(kAAddress, false, static_cast<uint16_t>((SpyAddr(kSpyPc) >> 1) & 0xFFFFu));
    Request(w);
    Lift(w);
    const uint32_t wc = Ctl(kACycle, false, 0);
    Request(wc);
    Idle(40);
    if (dut->dbg_gnt_o) Say("the debug master took the bus with the processor's strobe down");
    long waited = 0;
    while (!dut->cpu_ssyn && waited < 400) { Tick(); ++waited; }
    if (!dut->cpu_ssyn) Say("the processor's cycle was truncated by the debug master");
    dut->cpu_msyn = 0;
    // Now the console asks too, and the debug master is first on the chain.
    dut->con_req = 1;
    dut->con_addr = SpyAddr(kSpyPc);
    dut->con_msyn = 1;
    waited = 0;
    while (!dut->dbg_gnt_o && waited < 400) { Tick(); ++waited; }
    if (!dut->dbg_gnt_o) Say("the debug master never took the bus");
    if (dut->con_gnt) Say("the console took the bus in front of the debug master");
    Idle(200);
    if (dut->con_gnt) Say("the console took the bus while the debug master held it");
    Lift(wc);
    Idle(kReleaseT + 8);
    // And now the console gets it.
    waited = 0;
    while (!dut->con_gnt && waited < 400) { Tick(); ++waited; }
    if (!dut->con_gnt) Say("the console never got the bus after the debug master let go");
    dut->con_req = 0;
    dut->con_msyn = 0;
    Idle(8);
  }

  // ------------------------------------------------------------- the totals
  //
  // The two instants the cable itself is built around, measured over the
  // whole run rather than asserted at one place.
  if (lead_seen == 0) Say("the request never went down: nothing was measured");
  if (lead_min != kLeadT)
    Fail("the shortest lead from the levels to -DEBUG IN REQ", lead_min, kLeadT);
  if (trail_seen == 0) Say("the levels never moved after a lift: nothing was measured");
  // **THE MARGIN AT THE LATCHING EDGE, MEASURED AND NOT ASSUMED.**
  // `cadr_dbgin.sv` takes `DBD` at the edge after the one that dropped
  // `-DEBUG IN REQ`, so the word it latches is the one standing at the end of
  // the lift's own write beat.  Nothing on the port can move the levels
  // there: a second beat has to pass W_RESP and W_ADDR to get out, which is
  // four ticks.  That is a derivation, and this is the measurement beside it
  // --- the window carried a twenty-tick guard in front of it until the two
  // were put side by side and the guard turned out to be unreachable.  The
  // day the port's shape changes, this number moves and the run says so.
  if (trail_min < 1)
    Fail("the levels moved on the tick the request lifted", trail_min, 1);
  if (cable_moved_with_req) Say("a level moved on the same tick as the request");

  if (cycles_run == 0) Say("no debug cycle ever reached a slave");
  if (msyn_lag_min != kMsynT || msyn_lag_max != kMsynT)
    Fail("the grant to -UB MSYN", msyn_lag_min, kMsynT);
  if (ssyn_lag_min != kSsynT || ssyn_lag_max != kSsynT)
    Fail("-UB MSYN to the register block's -UB SSYN", ssyn_lag_min, kSsynT);
  if (release_min != kReleaseT || release_max != kReleaseT)
    Fail("the lift to DBUB MASTER clearing", release_min, kReleaseT);

  // **"ACKNOWLEDGED AT ONCE" IS A CLAIM ABOUT AN INSTANT, AND THIS IS WHERE
  // IT IS MADE.**  A poll through the port cannot tell a gate from a bus
  // cycle, an AXI round trip being several ticks either way; the cable can.
  // `DEBUG ACK` for the three register strobes is
  // `NAND(-DB ADR1 CLK, -DB ADR0 CLK, -DB READ STATUS)` and rises on the tick
  // `-DEBUG IN REQ` falls, with nothing in between --- and a cycle's is
  // `DBUB MASTER AND SSYN T0`, which cannot be quicker than the arbitration
  // and the slave put together.
  static const char *kStrobeName[4] = {"-DB NEED UB", "-DB READ STATUS",
                                       "-DB ADR1 CLK", "-DB ADR0 CLK"};
  for (unsigned a = 1; a < 4; ++a) {
    if (ack_seen[a] == 0) {
      std::fprintf(stderr, "FAIL: %s was never acknowledged\n", kStrobeName[a]);
      ++bad;
    } else if (ack_lag_min[a] != 0 || ack_lag_max[a] != 0) {
      std::fprintf(stderr,
                   "tick %ld: %s was acknowledged %ld to %ld ticks after the "
                   "request, and it is a gate: 0\n",
                   tick, kStrobeName[a], ack_lag_min[a], ack_lag_max[a]);
      ++bad;
    }
  }
  if (ack_seen[0] == 0) Say("-DB NEED UB was never acknowledged");
  else if (ack_lag_min[0] < kMsynT + kSsynT)
    Fail("the quickest -DB NEED UB acknowledgement", ack_lag_min[0],
         kMsynT + kSsynT);

  std::fprintf(stderr,
               "dbgin: %zu microcycles compared, %ld lengths (%ld sub-tick, "
               "%ld arbitrated, %ld re-anchored at a halt)\n",
               k, lengths_checked, sub_tick, arb_skipped, halt_skipped);
  std::fprintf(stderr,
               "dbgin: %ld debug cycles, %ld requests on the cable, "
               "grant+%ld to -UB MSYN, +%ld to -UB SSYN, lift+%ld to the release\n",
               cycles_run, lead_seen, msyn_lag_min, ssyn_lag_min, release_min);
  std::fprintf(stderr,
               "dbgin: the levels stand %ld ticks before the request and at "
               "least %ld ticks past the lift, over %ld lifts\n",
               lead_min, trail_min, trail_seen);
  std::fprintf(stderr,
               "dbgin: %ld AXI reads, %ld writes, %ld write beats\n",
               axi_reads, axi_writes, axi_beats);
  std::fprintf(stderr,
               "dbgin: DEBUG ACK at +%ld on -DB NEED UB (%ld of them) and at "
               "+%ld on each of the three register strobes (%ld, %ld, %ld)\n",
               ack_lag_min[0], ack_seen[0], ack_lag_min[1], ack_seen[1],
               ack_seen[2], ack_seen[3]);

  // ---------------------------------------------------------- the rest of it
  //
  // The cable idle, the machine streaming the reference to the end: a cable
  // that disturbed the machine when nobody was using it would show here.
  Store(Win(kWClear), kLift);
  compare_rows = true;
  last_edge = -1;
  const size_t stop = limit ? (k + limit) : total_rows;
  long guard = 0;
  while (k < total_rows && k < stop) {
    Tick();
    if (++guard > 200000000L) { Say("the machine stopped retiring"); break; }
  }

  // --------------------------------------- phase 10: -DEBUGEE RESET, over the cable
  //
  // Modifier bit 1: "Resets the debuggee's Unibus and bus interface.  Write a
  // 1 here then write a 0."  A level, not a pulse, and it is that processor's
  // power-on reset --- so CC's reset of the debuggee goes down the cable and
  // needs nothing else.
  //
  // **IT IS LAST, AND IT HAS TO BE.**  A machine reset here re-runs MIT's
  // boot PROM from microcycle zero while the reference stream has gone on,
  // so nothing can be compared against the trace afterwards.  The claim made
  // instead is the one that does not need a trace: the machine is held while
  // the bit stands, and when it is cleared the program counter goes back to
  // the top and starts again.  `tb/cadr_console_tb.cpp` says at length why a
  // replay's datapath cannot be compared --- no reset this machine has clears
  // the scratchpads --- and none of that is re-derived here.
  {
    compare_rows = false;
    Store(Win(kWClear), kLift);
    if (dut->mach_rst_o) Say("the machine is in reset before the cable asks");
    const long before = microcycles;
    Idle(200);
    if (microcycles == before) Say("the machine was not running before the reset");

    uint32_t w = Ctl(kAModifier, false, 0b011);   // ADDRESS_17 and RESET
    Request(w);
    Lift(w);
    if (!dut->debuggee_reset_o) Say("-DEBUGEE RESET did not follow modifier bit 1");
    if (!dut->mach_rst_o) Say("the machine is not held in reset by -DEBUGEE RESET");
    const long held = microcycles;
    Idle(400);
    if (microcycles != held)
      Fail("microcycles retired while -DEBUGEE RESET stood", microcycles - held, 0);
    if (dut->pc != 0) Fail("PC while the machine is held in reset", dut->pc, 0);

    w = Ctl(kAModifier, false, 0b001);
    Request(w);
    Lift(w);
    if (dut->debuggee_reset_o) Say("-DEBUGEE RESET is still up after modifier bit 1 was cleared");
    Idle(8);
    if (dut->mach_rst_o) Say("the machine is still in reset after the cable let go");
    const long restarted = microcycles;
    Idle(400);
    if (microcycles == restarted) Say("the machine did not start again after the cable let go");
    if (dut->pc == 0) Say("PC did not move after the cable let the machine go");
  }

  if (dut->cab_req) Say("the cable is still holding a request at the end");

  std::fprintf(stderr, "dbgin: %zu of %zu microcycles reached\n", k, total_rows);

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  std::fprintf(stderr, "dbgin: ok\n");
  delete dut;
  return 0;
}
