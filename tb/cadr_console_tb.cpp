// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console against muir: the machine runs MIT's boot PROM out of the same
// trace `tb/cadr_microcycle_tb.cpp` drives it from, and a program on
// `M_AXI_GP1` halts it, reads the sixteen diagnostic registers, and starts it
// again --- sixteen times over 600,000 microcycles.
//
// **WHAT IS HELD TO muir, AND WHERE THE REFERENCE IS.**
//
//   the sixteen reads  `Engine::spy_read`, muir/src/rtl.rs:2679-2721, whose
//                      sixteen answers are `IR` in three halves, `OPC`, `PC`,
//                      `OB` in two, `FLAG-1`, `FLAG-2`, `M`, `A` and `ST` in
//                      two each, and the open bus at register 3.  Every one
//                      of them is a column of `build/rtl.golden`, so the word
//                      the console reads back is compared against the
//                      reference's own value for the microcycle the console
//                      says it stopped at.  `SpyWord` below is that
//                      reconstruction, and it is muir's `spy.rs` bit for bit
//                      --- `Flag1::word`, `Flag2::word` and
//                      `Flag2::OPEN = 0xc0c0`, the four floating buffer
//                      inputs that read as ones.
//
//   halt               `spy_write(CLK, 0)`, muir/tests/lashup.rs:152-157 ---
//                      CC's first act on a debuggee --- and
//                      muir/tests/spy.rs:729-741, which pins what it means:
//                      "the microcycle in flight completes", `SRUN` being one
//                      master clock behind `RUN`, and then nothing moves
//                      while the master clock runs on.  Both halves are
//                      asserted here: the machine stops, and it stops at a
//                      microcycle boundary and not inside one.
//
//   start              `spy_write(CLK, 1)`, muir/tests/lashup.rs:311-315 ---
//                      and the claim this check exists to make is stronger
//                      than that: after sixteen halts and starts, **all
//                      600,000 microcycles still agree with muir, column for
//                      column.**  A halt that disturbed the datapath, or a
//                      start that lost or repeated a microcycle, is a
//                      mismatch on the next row.
//
//   `FLAG-1` halted    0xe800 exactly, which is muir/tests/spy.rs:706's own
//                      `HALTED` constant; running, 0xe900, its `RUNNING`.
//                      That is the question the console exists to answer ---
//                      is the machine running --- and it is a constant muir
//                      wrote down.
//
//   CYCLES             `Machine::cycles`, incremented at muir/src/rtl.rs:2386
//                      and **only there**: a halted master clock cycle
//                      returns at rtl.rs:2305 and a stall at 2325 without
//                      reaching it.  The fabric's `clock_edge` is registered
//                      `cpu_edge`, which is the same instant.  It is not
//                      compared against a column, because the reference has
//                      no column for it; it is compared against the row the
//                      testbench is on, which is the same claim from the
//                      other side and is what makes every register read above
//                      name the right microcycle.
//
// **WHAT IS A PROPERTY AND NOT muir.**  The GP1 face itself: no muir
// reference exists for it, as none exists for `cadr_axi_master.sv`, so it is
// held to the AXI3 protocol and to read-back --- one handshake a channel a
// burst, payload stable, RLAST where the length says, the ID echoed, and
// **every address answered**.  The engine's own bound, `LOST_T`, likewise:
// the property is that an AXI transaction completes whatever the diagnostic
// bus does, because a read that never completes hangs both Arm cores at one
// PC each, measured on the board.  And the arbiter: the property is that the
// console never truncates a Unibus cycle the processor has started, and that
// a processor cycle waiting behind the console waits less than the NXM timer.
//
// **THE FIVE FLAGS NOTHING ELSE HAS EVER CHECKED.**  `Rtl::spy()` names
// twelve signals and `cadr_microcycle.sv` brings out four of them.  `WMAPD`,
// `DESTSPCD`, `IMODD`, `PDLWRITED` and `SPUSHD` --- the write-pipeline
// enables, the six 74LS244 inputs on SPY2 3F15 --- are internal to the
// processor and appear on no port, so no check in this repository has ever
// compared them with muir.  They are `FLAG-2`'s bits 13, 12, 10, 9 and 8, and
// reading that register through the console is what compares them.  The
// counts are printed.
//
// **AND THE SINGLE STEP IS CHECKED HERE NOW, END TO END.**  It used to be in
// the list below as a thing this could not check: `cadr_microcycle.sv` had
// neither `SSTEP` nor `SSDONE` and `cadr_spy_registers.sv` took bit 0 of a
// CLK write and dropped bits 4:1, so a write of 2 went down the diagnostic
// bus and landed in nothing.  Both files have the rest of the register now.
// What this asserts is the WHOLE ROAD --- an AXI write on `M_AXI_GP1`, a
// Unibus cycle at `0o766006`, the register block's landing rule, and
// `MACHRUN`'s first term --- and it asserts the number muir gives: **one
// microcycle a step and exactly one**, with `FLAG-1`'s `SSDONE` up after it.
// `build/sstep.pass` holds the processor's half against a reference trace
// tick by tick; this holds that a console can reach it.
//
// **WHAT THIS CANNOT CHECK, said here rather than left to be assumed.**
//
//   The write-strobe aliasing.  muir's `spy::write_strobe` is `eadr & 7`:
//   `EADR3` does not reach the write decoder, so a write at register 13
//   loads the mode register.  `cadr_spy_registers.sv` compares all four bits
//   and does not.  Measured and printed below, for the same reason.
//
//   The two pulses.  `-PROG.RESET` and `PROG.BOOT`, bits 6 and 7 of a mode
//   write, leave `cadr_spy_registers` and are folded into `unused` at
//   `rtl/machine/cadr_machine.sv:425`.  This harness brings them out, so the pulses
//   themselves are checked here; what they should *do* is the machine's.

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "Vcadr_console_harness.h"
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

// The window on `M_AXI_GP1`, as `rtl/plumbing/cadr_console.sv` parameterises it.
constexpr uint32_t kBase     = 0x80000000u;
constexpr uint32_t kIdent    = 0x434F4E53u;   // "CONS"
constexpr uint32_t kUnmapped = ~kIdent;
constexpr uint32_t kLostT    = 4096u;

// Page 0, the console's own registers; page 1, the sixteen diagnostic ones.
uint32_t Con(unsigned i) { return kBase + 4u * i; }
uint32_t Spy(unsigned e) { return kBase + 0x40u + 4u * e; }
enum ConReg { kRegIdent = 0, kRegStat = 1, kRegCycles = 2, kRegCyclesH = 3,
              kRegTicks = 4, kRegTicksH = 5, kRegReset = 6, kRegVma = 7,
              kRegQ = 8, kRegMd = 9, kRegBoot = 13, kRegDebug = 14 };

// What `rtl/plumbing/xilinx7/cadr_machine.xdc`'s relaxed set asks of the three
// registers `rtl/machine/cadr_console_state.sv` holds: fifteen ticks, 75 ns.
// The file relaxes `-from $slow -to $slow` and every register of that module
// is in `slow`, so the claim being made about each of them is that its input
// is stable for a microcycle and its capture is at the end of one.  A claim
// nothing exercises is not a claim: the loop measures the shortest arc each
// of the three actually has and fails below this.
constexpr long kRelaxedT = 15;

// The reset register's key and the pulse it makes, as `rtl/plumbing/cadr_console.sv`
// parameterises them.  `RESET_KEY` is "RSET" --- four distinct bytes, none of
// them `00` or `FF`, so a write that does not strobe all four lanes cannot
// equal it however the lanes are merged, and neither a dead bus's zeros nor
// an undriven bus's ones can arrive at it.  `RESET_T` is 64 ticks, 320 ns.
constexpr uint32_t kResetKey  = 0x52534554u;   // "RSET"
constexpr uint32_t kResetMark = kResetKey >> 16;
constexpr long     kResetT    = 64;

// The light panel's button, page 0's word 13.  `BOOT_KEY` is "BOOT" on the
// same rule as "RSET", and `BOOT_T` is 64 ticks.  **It is `-BOOT2` and not
// `PROG.BOOT`**: the mode register's bit 7 reaches the same gate and is the
// DEBUG CABLE'S line, so a console pressing it would be a console pretending
// to be a debugger.  muir's prompt makes the same choice.
constexpr uint32_t kBootKey  = 0x424F4F54u;   // "BOOT"
constexpr uint32_t kBootMark = kBootKey >> 16;
constexpr long     kBootT    = 64;

// The debug cable's role, page 0's word 14.  `DEBUG_KEY` is "DBGR" on the same
// rule as the two above, and its COMPLEMENT gives the role back --- which
// differs from it in every bit, so no partial write of one can be the other.
// It is NOT a pulse: a role is held until somebody says otherwise, so the
// write completes at once and there is no length to count.
constexpr uint32_t kDebugKey   = 0x44424752u;   // "DBGR"
constexpr uint32_t kDebugUnkey = ~kDebugKey;
constexpr uint32_t kDebugMark  = kDebugKey >> 16;
// And which way round the JA ribbon was made: three more keys on the same
// word, and no complement, because there are three of them.
constexpr uint32_t kWireAuto  = 0x4155544Fu;   // "AUTO"
constexpr uint32_t kWireStr   = 0x53545241u;   // "STRA"
constexpr uint32_t kWireCross = 0x43524F53u;   // "CROS"
// Word 14's bits.  Bit 0 is the role this board HAS and bit 1 is the one it
// ASKED for, and they are two facts: the connector may refuse.
constexpr uint32_t kDbgEngaged = 1u << 0;
constexpr uint32_t kDbgAsked   = 1u << 1;
constexpr uint32_t kDbgForeign = 1u << 2;
constexpr uint32_t kDbgActive  = 1u << 3;
constexpr uint32_t kDbgLive    = 1u << 4;

// muir's own two constants, tests/spy.rs:703-707: `FLAG-1` with nothing
// wrong, running and halted.
constexpr uint16_t kFlag1Running = 0xe800u | 0x100u;
constexpr uint16_t kFlag1Halted  = 0xe800u;

int bad = 0;
long tick = 0;

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  std::fprintf(stderr, "tick %ld: %s is 0x%llx, the reference says 0x%llx\n",
               tick, what, got, want);
  // **A RUN THAT HAS FAILED TWENTY TIMES STOPS HERE AND SAYS SO**, rather
  // than carrying on into a transaction that never completed and throwing
  // out of a `std::vector::at`.  An abort's message is the C++ library's and
  // buries the line that matters twenty lines up; the first mismatch is what
  // a reader needs.
  if (++bad >= 20) {
    std::fprintf(stderr, "FAIL: stopping after %d mismatches\n", bad);
    std::exit(1);
  }
}

// What `Engine::spy_read` answers for this microcycle, off the reference's own
// columns.  muir/src/rtl.rs:2679-2721 for the sixteen, muir/src/spy.rs for the
// two flag words' bit order and polarities.
//
// `wait` is `FLAG-1` bit 15 and the trace has no column for it; every visit is
// made at a microcycle with no bus cycle in flight and no stall, where it is
// down, and the constant below says so.  A visit that landed anywhere else
// would fail here and say which register.
uint16_t SpyWord(const Row &r, int eadr, bool halted) {
  const uint64_t ir = r.v[kIr];
  switch (eadr) {
    case 0: return static_cast<uint16_t>(ir);
    case 1: return static_cast<uint16_t>(ir >> 16);
    case 2: return static_cast<uint16_t>(ir >> 32);
    // Register 3 has no read select --- Y3 of SPY0 1F01 is not connected ---
    // so the bus interface's 8304s read the floating bus as all ones.
    // muir/src/spy.rs:488, `OPEN_READ`.
    case 3: return 0xffffu;
    case 4: return static_cast<uint16_t>(r.v[kOpc] & 0x3fffu);
    case 5: return static_cast<uint16_t>(r.v[kPc] & 0x3fffu);
    case 6: return static_cast<uint16_t>(r.v[kOb]);
    case 7: return static_cast<uint16_t>(r.v[kOb] >> 16);
    case 8: {
      // `Flag1::word`.  -WAIT up, no map parity errors, PROMDISABLE off the
      // mode register, -STATHALT up, ERR from HALTED, SSDONE zero (there is
      // no console step in this fabric), SRUN.  The low byte is the ten
      // parity flags through an inverting driver and no memory here has
      // parity to get wrong.
      uint16_t w = 0xe000u;                                 // 15, 14, 13
      if (r.v[kPromdis]) w |= 1u << 12;
      w |= 1u << 11;                                        // -STATHALT
      if (r.v[kHalted]) w |= 1u << 10;
      if (!halted && r.v[kSrun]) w |= 1u << 8;
      return w;
    }
    case 9: {
      // `Flag2::word`, with `Flag2::OPEN`'s four floating inputs.
      uint16_t w = 0xc0c0u;
      if (r.v[kWmapd]) w |= 1u << 13;
      if (r.v[kDestspcd]) w |= 1u << 12;
      if (r.v[kIwrited]) w |= 1u << 11;
      if (r.v[kImodd]) w |= 1u << 10;
      if (r.v[kPdlwrited]) w |= 1u << 9;
      if (r.v[kSpushd]) w |= 1u << 8;
      // bit 5 is IR48, the control store's parity bit, which neither this
      // engine nor muir's carries
      if (r.v[kNop]) w |= 1u << 4;
      if (r.v[kNVmaok]) w |= 1u << 3;     // the net, low when permitted
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

const char *kSpyName[16] = {
    "IR<15:0>", "IR<31:16>", "IR<47:32>", "the open bus", "OPC", "PC",
    "OB<15:0>", "OB<31:16>", "FLAG-1", "FLAG-2", "M<15:0>", "M<31:16>",
    "A<15:0>", "A<31:16>", "ST<15:0>", "ST<31:16>"};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // The trace is streamed, not held --- as `tb/cadr_microcycle_tb.cpp` reads
  // it, and for the same reason.  One pass for the acknowledgement times, one
  // to drive.
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

  auto *dut = new Vcadr_console_harness;
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
  dut->gnt_inhibit = 0;
  dut->eval();

  auto read_next = [&](Row &r) {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      return ParseRow(line, r);
    }
    return false;
  };

  // ---- the processor's stimulus, exactly as `cadr_microcycle_tb.cpp` drives
  // ---- it: the console owns `run` and the mode register, so those are gone.
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

  // **THE READ-BACK'S LAG, MEASURED AND NOT ASSERTED.**
  // `rtl/machine/cadr_console_bus.sv` captures the diagnostic mux's answer at the
  // microcycle boundary and nowhere else, so that the sixteen-way mux has a
  // microcycle to settle instead of a tick --- which is what turned -12.837 ns
  // on 5,698 endpoints back into a met board.  The price is that the console
  // reads the machine as of the last boundary, and the price has to be a
  // number: these read `PC` while the machine RUNS and ask which row the
  // answer belongs to.  A halted read cannot resolve this at all, the machine
  // having stopped moving, which is exactly the "an exemption too wide tests
  // nothing" trap --- so the sweep is made where it bites.
  size_t pc_ring[8] = {0};
  bool   sample_pending = false;
  size_t sample_row = 0;
  size_t sample_ring[8] = {0};
  long   lag_samples = 0, lag_moving = 0;
  long   lag_seen = -1;
  size_t next_lag_row = 0;

  size_t k = 0;
  long last_edge = -1;
  uint64_t prev_ns = 0;
  bool bus_outstanding = false;
  long ack_at_tick = 0;
  long lengths_checked = 0, sub_tick = 0, arb_skipped = 0, resume_skipped = 0;
  long replay_rows = 0;
  bool machine_halted = false;

  // ---- the AXI master on GP1, one transaction at a time, driven from the
  // ---- same tick loop so that the machine runs while a program reads it.
  struct Axi {
    enum { IDLE, AW, W, B, AR, R } st = IDLE;
    uint32_t addr = 0, wdata = 0;
    unsigned len = 0;        // AWLEN/ARLEN: beats minus one
    unsigned beat = 0;
    unsigned id = 0;
    uint32_t strb = 0xF;
    std::vector<uint32_t> got;
    long began = 0;
    bool aw_hs = false, w_hs = false, b_hs = false, ar_hs = false, r_hs = false;
    int hold = 0;
  } axi;
  uint32_t jitter = 0x2F6E2B1u;
  auto rnd = [&]() { jitter = jitter * 1664525u + 1013904223u; return jitter >> 9; };

  long axi_reads = 0, axi_writes = 0, axi_beats = 0, axi_stalls = 0;

  // **THE REPLAY AFTER A CONSOLE RESET COMPARES THE CONTROL FLOW AND NOT THE
  // DATAPATH, AND THE REASON IS A PROPERTY OF EVERY RESET THIS MACHINE HAS.**
  // `amem`, `mmem`, `pdl` and `imem` in `rtl/machine/cadr_microcycle.sv` are RAM and
  // no reset clears them --- not this one, not the button's, and not MIT's own
  // `RESET`, which is a wire into flip flops and reaches no 93425A.  So a
  // machine reset a second time re-executes the boot PROM's instructions from
  // the top with the scratchpads its first run left, while muir's
  // `Machine::new` starts them at zero.  Measured: `amem` diverges on the
  // FIRST microcycle of the replay, A and M reading 0x1fc where the reference
  // says 0, and PC, IR, LPC and OPC agree.  That is the honest claim and it is
  // the right one --- a console reset that cleared memory would be a DIFFERENT
  // reset from the button's, and then there would be two resets to reason
  // about instead of one.  The microcycle's length goes with the datapath, a
  // stall being a wait for a word.
  bool replaying = false;

  // **THE MACHINE'S RESET, WATCHED EVERY TICK.**  A pulse is a thing you can
  // only see by looking every tick, and `RESET_T` is a length the module
  // states rather than "something happened" --- `LOST_T`'s lesson one
  // register along.  `mrst_runs` counts separate pulses, which is what says a
  // write that is not the key made none at all.
  long mrst_ticks = 0, mrst_runs = 0;
  bool mrst_prev = false;
  long mboot_ticks = 0, mboot_runs = 0;
  bool mboot_prev = false;

  // **THE CAPTURE'S OWN ARC, MEASURED EVERY TICK RATHER THAN DERIVED.**
  // `rtl/machine/cadr_console_state.sv` loads `con_vma`, `con_q` and `con_md`
  // at `mclk` and nowhere else, and being registers of `cadr_machine` with no
  // name in the fast list they are in `cadr_machine.xdc`'s relaxed set --- so
  // the FABRIC is told each of those three arcs has fifteen ticks.  That is a
  // claim about this machine's own behaviour and this is where it can be
  // checked: the tick of the last change of each source, the tick of each
  // capture, and the shortest distance between them over the whole run.
  //
  // It matters most for MD and that is why it is here rather than in anyone's
  // reasoning.  `vma` and `q` are written inside `if (mclk_edge)` in
  // `cadr_microcycle.sv` and nowhere else, so they cannot move between
  // boundaries at all; **MD can**, through `md_pending && hang` --- the word
  // `-LOADMD` deskewed, taken in the middle of a parked generator.  Whether
  // that leaves fifteen ticks before the boundary is a fact about
  // `RD_FINISH_T` and the generator's restart, not about anybody's intent.
  //
  // The convention, stated because a tick either way is the whole question:
  // a value settled at the end of tick t was launched by tick t's edge; an
  // `mclk` standing at the end of tick t is what a `posedge clk` sees at tick
  // t+1, so the capture edge is t+1 and the arc is t + 1 - t_launch.
  uint64_t cap_was[3] = {0, 0, 0};
  long cap_at[3] = {-1, -1, -1};
  long cap_min[3] = {-1, -1, -1};
  long cap_edges = 0;
  static const char *kCapName[3] = {"VMA", "Q", "MD"};

  // One tick, in `tb/cadr_microcycle_tb.cpp`'s own order: one evaluation with
  // the clock high, which is the edge, and one with it low, which settles the
  // combinational network for the next.  **THE ORDER IS NOT A DETAIL.**  The
  // AXI master's handshakes are sampled at the low evaluation and consummated
  // at the next high one, which is what "valid and ready as they stand before
  // the edge" means; and the processor's stimulus is presented exactly where
  // the microcycle check presents it, so that this harness and that one drive
  // the same processor the same way.  Presenting -MEMACK's release a tick
  // later --- which is what an evaluation moved from the end of one tick to
  // the start of the next does --- made twenty stalled microcycles of the
  // page-0 parity loop one generator cycle long, measured.
  auto Tick = [&]() {
    // -- the bus interface, as far as VCTL1 can see it
    dut->n_memgrant = bus_outstanding ? 0 : 1;
    const bool acking = bus_outstanding && tick >= ack_at_tick;
    dut->n_memack = acking ? 0 : 1;
    // "-LOADMD equals MEMACK and RDCYC": the interface puts it out on every
    // acknowledgement and the processor's own RDCYC decides.
    dut->n_loadmd = acking ? 0 : 1;
    // Poison on a write, for the reason `cadr_microcycle_tb.cpp` gives: an
    // extra load of MD is a no-op if the word handed back is the one MD
    // should hold, so a write cycle gets the complement and nothing should
    // take it.
    if (dut->wrcyc)
      dut->rdata = ~static_cast<uint32_t>(rdata_for[k < total_rows ? k : 0]);

    dut->clk = 1;
    dut->eval();

    // "MEMRQ drops when MEMACK rises, which causes MEMACK to drop."
    if (bus_outstanding && dut->n_memack == 0 && dut->n_memrq) {
      bus_outstanding = false;
      dut->n_memack = 1;
      dut->n_memgrant = 1;
    }

    // Past the last row the reference has nothing more to say, and the
    // machine runs on: the face's own checks below are made with the
    // trace exhausted and the comparison switched off, not with a stale row
    // standing in for one.
    if (dut->clock_edge && k < total_rows) {
      const Row &r = cur;
      if (prev.pc != r.v[kPc]) Fail("PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) Fail("IR", prev.ir, r.v[kIr]);
      if (prev.lpc != r.v[kLpc]) Fail("LPC", prev.lpc, r.v[kLpc]);
      if (prev.opc != r.v[kOpc]) Fail("OPC", prev.opc, r.v[kOpc]);
      if (!replaying) {
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
      }

      // The microcycle's own length.  A microcycle the console stopped the
      // clock in the middle of is as long as the halt, so `last_edge` is
      // dropped at each halt and the next edge re-anchors it; the exemption
      // is one microcycle a halt and is counted.
      if (last_edge >= 0 && !replaying) {
        const uint64_t want = r.v[kNs] - prev_ns;
        const uint64_t got = static_cast<uint64_t>(tick - last_edge) * kTickNs;
        if (got != want) {
          const long slip = static_cast<long>(got) - static_cast<long>(want);
          if (arbitrated[k]) ++arb_skipped;
          else if (r.v[kStall] && slip >= -kTickNs && slip <= kTickNs) ++sub_tick;
          else {
            std::fprintf(stderr,
                         "microcycle %zu (PC %" PRIo64 "): length %llu ns, the "
                         "reference says %llu (stall %llu, bus %llu)\n",
                         k, r.v[kPc], (unsigned long long)got,
                         (unsigned long long)want,
                         (unsigned long long)r.v[kStall],
                         (unsigned long long)r.v[kBus]);
            ++bad;
          }
        }
        ++lengths_checked;
      }
      if (replaying) ++replay_rows;
      pc_ring[k & 7] = static_cast<size_t>(r.v[kPc] & 0x3fffu);
      last_edge = tick;
      prev_ns = r.v[kNs];
      if (r.v[kBus]) {
        bus_outstanding = true;
        // Rounded up: muir's acknowledgement is not on the five-nanosecond
        // grid and the fabric can only see it at a tick at or after it.
        ack_at_tick = tick + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
      }
      ++k;
      if (k < total_rows) {
        if (!read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu\n", path, k);
          ++bad;
        }
        // The row's stimulus, as `drive()` presents it there: the word the
        // interface would hand back over this microcycle, and the interrupt
        // off the cables.  `run` and the mode register are NOT here --- they
        // are the console's, and come out of the register block.
        dut->rdata = static_cast<uint32_t>(rdata_for[k]);
        dut->sintr = static_cast<uint8_t>(cur.v[kSintr]);
      }
    }

    // The instant the register block answered this console cycle: what the
    // console takes is `con_rdata` as it stands here, and `con_rdata` was
    // loaded at the last microcycle boundary before it.
    if (sample_pending && dut->con_ssyn_o) {
      sample_pending = false;
      sample_row = k;
      for (int i = 0; i < 8; ++i) sample_ring[i] = pc_ring[i];
      sample_ring[k & 7] = static_cast<size_t>(cur.v[kPc] & 0x3fffu);
    }

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
    if (axi.st != Axi::IDLE && tick - axi.began > static_cast<long>(kLostT) + 4096) {
      Fail("an AXI transaction did not complete inside the engine's own bound",
           axi.st, Axi::IDLE);
      axi.st = Axi::IDLE;
    }

    // -- what the master offers at the next edge
    dut->s_awvalid = (axi.st == Axi::AW) && axi.hold == 0;
    dut->s_wvalid  = (axi.st == Axi::W) && axi.hold == 0;
    dut->s_wlast   = (axi.st == Axi::W) && (axi.beat == axi.len);
    dut->s_bready  = (axi.st == Axi::B) && axi.hold == 0;
    dut->s_arvalid = (axi.st == Axi::AR) && axi.hold == 0;
    dut->s_rready  = (axi.st == Axi::R) && axi.hold == 0;

    dut->clk = 0;
    dut->eval();
    prev = take();

    // The three sources as they stand at the end of this tick, and the
    // boundary that will capture them at the next edge.  See the declaration
    // for the convention; `cap_at` is the launching edge and `tick + 1` the
    // capturing one.
    {
      const uint64_t now[3] = {dut->vma, dut->q, dut->md};
      for (int i = 0; i < 3; ++i)
        if (now[i] != cap_was[i]) { cap_was[i] = now[i]; cap_at[i] = tick; }
      if (dut->mclk_o) {
        ++cap_edges;
        for (int i = 0; i < 3; ++i) {
          if (cap_at[i] < 0) continue;
          const long arc = tick + 1 - cap_at[i];
          if (cap_min[i] < 0 || arc < cap_min[i]) cap_min[i] = arc;
        }
      }
    }

    const bool mrst_now = dut->mach_rst_o != 0;
    if (mrst_now) {
      ++mrst_ticks;
      if (!mrst_prev) ++mrst_runs;
    }
    mrst_prev = mrst_now;

    const bool mboot_now = dut->mach_boot_o != 0;
    if (mboot_now) {
      ++mboot_ticks;
      if (!mboot_prev) ++mboot_runs;
    }
    mboot_prev = mboot_now;

    // -- the handshakes, as they stand before the edge that consummates them
    axi.aw_hs = dut->s_awvalid && dut->s_awready;
    axi.w_hs  = dut->s_wvalid && dut->s_wready;
    axi.b_hs  = dut->s_bready && dut->s_bvalid;
    axi.ar_hs = dut->s_arvalid && dut->s_arready;
    axi.r_hs  = dut->s_rready && dut->s_rvalid;
    if (dut->s_bvalid && !axi.b_hs) ++axi_stalls;
    if (dut->s_rvalid && !axi.r_hs) ++axi_stalls;
    // A response offered before the data is in, or a beat before the address,
    // is a slave answering a transaction nobody made.
    if (dut->s_bvalid && axi.st != Axi::B) Fail("BVALID with no write awaiting one", 1, 0);
    if (dut->s_rvalid && axi.st != Axi::R) Fail("RVALID with no read awaiting one", 1, 0);
    if (axi.b_hs) {
      if (dut->s_bresp != 0) Fail("BRESP", dut->s_bresp, 0);
      if (dut->s_bid != axi.id) Fail("BID", dut->s_bid, axi.id);
    }
    if (axi.r_hs) {
      if (dut->s_rresp != 0) Fail("RRESP", dut->s_rresp, 0);
      if (dut->s_rid != axi.id) Fail("RID", dut->s_rid, axi.id);
      const bool last = (axi.beat == axi.len);
      if ((dut->s_rlast != 0) != last)
        Fail(last ? "RLAST missing on the last beat"
                  : "RLAST on a beat that is not the last",
             dut->s_rlast, last);
      axi.got.push_back(dut->s_rdata);
      ++axi_beats;
    }
    if (axi.w_hs) ++axi_beats;

    // **THE TICK IS COUNTED AT THE END, WHERE `cadr_microcycle_tb.cpp`'s loop
    // variable stands.**  Counted at the edge instead, `ack_at_tick` is one
    // tick further off than the reference puts it, every hang ends a tick
    // late, and twenty stalled microcycles of the page-0 parity loop come out
    // a whole 220 ns generator cycle long --- a tick's error crossing a
    // boundary and costing a cycle.  Measured, twice, before it was
    // understood.
    ++tick;
  };

  // Blocking helpers over that state machine.  A transaction runs while the
  // machine runs, which is what a program on the processing system does.
  auto Run = [&](long n) { for (long i = 0; i < n; ++i) Tick(); };
  auto DoRead = [&](uint32_t addr, unsigned len) {
    axi.st = Axi::AR; axi.addr = addr; axi.len = len; axi.beat = 0;
    axi.id = rnd() & 0xFFF; axi.got.clear(); axi.began = tick;
    axi.hold = rnd() % 3;
    dut->s_araddr = addr; dut->s_arlen = len; dut->s_arid = axi.id;
    ++axi_reads;
    while (axi.st != Axi::IDLE && bad < 20) Tick();
    // A run that has already failed twenty times is stopping; hand back
    // something of the right shape rather than throwing out of the check.
    while (axi.got.size() < static_cast<size_t>(len) + 1) axi.got.push_back(0);
    return axi.got;
  };
  auto ReadWord = [&](uint32_t addr) { return DoRead(addr, 0).at(0); };
  auto DoWrite = [&](uint32_t addr, uint32_t data, uint32_t strb) {
    axi.st = Axi::AW; axi.addr = addr; axi.wdata = data; axi.len = 0;
    axi.beat = 0; axi.id = rnd() & 0xFFF; axi.strb = strb; axi.began = tick;
    axi.hold = rnd() % 3;
    dut->s_awaddr = addr; dut->s_awlen = 0; dut->s_awid = axi.id;
    dut->s_wdata = data; dut->s_wstrb = strb;
    ++axi_writes;
    while (axi.st != Axi::IDLE && bad < 20) Tick();
  };
  auto SpyRead = [&](unsigned e) { return ReadWord(Spy(e)); };
  auto SpyWrite = [&](unsigned e, uint16_t v) { DoWrite(Spy(e), v, 0xF); };
  // CYCLES, the machine's own count of retired microcycles, as two words of
  // page 0.  It is the witness of a step that does not depend on the
  // reference, and once the reference is exhausted it is the only one.
  auto Cycles = [&]() {
    const std::vector<uint32_t> c = DoRead(Con(kRegCycles), 1);
    return c.at(0) | (static_cast<uint64_t>(c.at(1)) << 32);
  };

  // ---- the run ----------------------------------------------------------
  Run(4);
  dut->rst = 0;
  Run(2);

  // The first read of all: a program's own guard.  IDENT says the face is
  // there and is this one.
  const uint32_t ident = ReadWord(Con(kRegIdent));
  if (ident != kIdent) Fail("IDENT", ident, kIdent);
  if (ReadWord(Con(kRegStat)) & 1) Fail("STAT says busy with nothing asked", 1, 0);

  // Where the console stops the machine.  Sixteen points spread over the run,
  // each taken at the first quiet microcycle at or after it: no bus cycle in
  // flight, none starting, and no stall, so that `FLAG-1`'s -WAIT is down and
  // the register block is not being asked for by the processor at the same
  // moment.
  const size_t targets[] = {1, 64, 997, 5003, 20011, 50021, 120017, 220019,
                            330023, 440021, 520019, 536200, 537000, 537900,
                            560003, 590009};
  size_t next_target = 0;
  // A switch for bring-up only: with no halts at all this is
  // `microcycle.pass` run through this harness, which is what says whether a
  // disagreement is the console's or the wiring's.
  const bool no_halts = std::getenv("CADR_CONSOLE_NO_HALTS") != nullptr;
  long visits = 0, regs_compared = 0, regs_hunted = 0;
  // **THE VIRTUAL ADDRESS REGISTER AND `Q`, page 0's words 7 and 8.**  They
  // are not on the diagnostic bus --- MIT's sixteen carry `IR`, `OPC`, `PC`,
  // `OB`, the two flag words, `M`, `A` and `ST` and nothing else, so a console
  // on that bus alone cannot see either --- and they are here because the
  // board's halt inside `PDL-BUFFER-REFILL` is decided by their DIFFERENCE:
  // three faults injected into muir give the same PC, the same OPC, the same
  // two flag words, the same `IR`, `A`, `M` and `OB`, and differ only in
  // whether `VMA` and `Q` are equal or a page apart.
  //
  // `vq_distinct` is the count that makes the comparison evidence: a halt
  // where the two read alike cannot tell a console that reads `Q` where the
  // virtual address should be from one that does not, which is the PC lag
  // sweep's own lesson --- a sample whose candidates read alike is not a
  // sample.  `vq_latch_moving` is the same for the latch: a read of word 8
  // alone must hand back what the LAST read of word 7 latched beside it, and
  // that says nothing at a halt where the latched `Q` and the live one agree.
  //
  // **AND MD BESIDE THEM, page 0's word 9.**  It is the third value from the
  // same instant and it is what the faulting read RETURNED: at the board's
  // halt it holds either the map word the microcode wrote back or the word
  // that came through the entry it had just hacked.  It is not on the
  // diagnostic bus either --- `../muir/src/spy.rs` names the sixteen and MD
  // is not among them --- and it joins the pair's latch rather than standing
  // beside it, so the three name ONE microcycle.  `md_off_vma` and `md_off_q`
  // are what make the crossing records evidence: a halt where MD reads alike
  // with the register it might be crossed with cannot tell a console that
  // crosses them from one that does not.
  long vq_compared = 0, vq_distinct = 0;
  long vq_latch_samples = 0, vq_latch_moving = 0;
  long md_off_vma = 0, md_off_q = 0;
  long md_latch_samples = 0, md_latch_moving = 0;
  bool vq_have_prev = false;
  uint32_t vq_prev_q = 0, vq_prev_md = 0;
  long flag2_wmapd = 0, flag2_destspcd = 0, flag2_imodd = 0;
  long flag2_pdlwrited = 0, flag2_spushd = 0, flag2_iwrited = 0;
  long distinct_pc = 0;
  uint64_t last_pc = ~0ull;
  long step_moved = 0, alias_landed = 0;
  // **THE FLAG HUNT.**  `FLAG-2` is compared at every halt, but which of its
  // six write-pipeline enables a given microcycle carries is the boot PROM's
  // business and not this check's --- and five of the six are compared with
  // muir nowhere else in this repository.  So where the reference says an
  // enable lives, the console halts, reads `FLAG-2` alone and starts again,
  // until it has met each of them.  The windows are measured off
  // `build/rtl.golden`: PDLWRITED on rows 83 to 9,299, DESTSPCD on 9,303 to
  // 9,427 (every fourth row), SPUSHD from 9,303, IWRITED on 410,840 to
  // 525,521.  WMAPD and IMODD are on a fifth and a sixteenth of all rows and
  // need no hunting.
  //
  // **A BUDGET PER FLAG AND NOT ONE POOL**, because one pool is spent by the
  // first window it meets: three hundred hunts starting at row 80 never
  // reached row 9,300, and DESTSPCD, SPUSHD and IWRITED went unmet while the
  // run reported itself content.  Measured.
  struct HuntWindow { size_t lo, hi; long *seen; long budget; };
  long hunts = 0;

  // The windows, off `build/rtl.golden` itself: PDLWRITED on rows 83 to
  // 9,299; DESTSPCD on 9,303 to 9,427, every fourth row and nowhere else in
  // the run; SPUSHD from 9,303 on; IWRITED on 410,840 to 525,521, the
  // WRITE-I-MEMs.  WMAPD is on a fifth of all rows and IMODD on a
  // sixteenth, so neither is hunted.
  HuntWindow hunt_windows[] = {
      {80, 9299, &flag2_pdlwrited, 40},
      {9300, 9430, &flag2_destspcd, 40},
      {9300, 60000, &flag2_spushd, 60},
      {410840, 525521, &flag2_iwrited, 60},
  };

  const long kMaxTicks = static_cast<long>(total_rows) * 96 + 2000000;
  while (k < total_rows && tick < kMaxTicks && bad < 20) {
    Tick();
    const bool quiet = !bus_outstanding && cur.v[kBus] == 0 && cur.v[kStall] == 0 &&
                       !arbitrated[k < total_rows ? k : 0];
    // ---- the lag sweep, with the machine RUNNING and nothing halted.
    if (!no_halts && lag_samples < 48 && k >= next_lag_row && quiet && bad < 20) {
      next_lag_row = k + 4001;
      sample_pending = true;
      sample_row = 0;
      const uint32_t w = SpyRead(5);
      if (w >> 16) Fail("a lag probe's read was not answered", w >> 16, 0);
      if (sample_pending) {
        Fail("a lag probe never saw the acknowledgement", 1, 0);
        sample_pending = false;
      } else {
        const size_t got = w & 0x3fffu;
        ++lag_samples;
        // **A SAMPLE WHERE THE CANDIDATE ROWS READ ALIKE IS NOT EVIDENCE**,
        // and taking it as evidence is how this measurement first went
        // wrong: the search returns the SMALLEST matching lag, so a PC that
        // did not move between two rows reads as a lag of nothing whatever
        // the design does.  Twenty of twenty-one samples said one and the
        // first said nothing, which is the check reporting the boot PROM's
        // program rather than the fabric.  So only a sample whose two
        // candidates differ is counted, and there is a floor on how many.
        const bool discriminating =
            sample_row >= 2 &&
            sample_ring[sample_row & 7] != sample_ring[(sample_row - 1) & 7];
        if (!discriminating) continue;
        ++lag_moving;
        // Which row does the answer belong to?  The search runs over the
        // last eight and the result has to be the same every time.
        int lag = -1;
        for (int L = 0; L < 8 && lag < 0; ++L)
          if (sample_row >= static_cast<size_t>(L) &&
              sample_ring[(sample_row - L) & 7] == got)
            lag = L;
        if (lag < 0) {
          std::fprintf(stderr,
                       "microcycle %zu: the console read PC %zo, which is no "
                       "row of the last eight\n", sample_row, got);
          ++bad;
        } else if (lag_seen < 0) {
          lag_seen = lag;
        } else if (lag != lag_seen) {
          Fail("the read-back's lag in microcycles", lag, lag_seen);
        }
      }
      continue;
    }
    if (no_halts) continue;
    // The hunt, which is a halt, one register and a start.
    if (next_target >= sizeof targets / sizeof *targets ||
        k < targets[next_target]) {
      HuntWindow *w = nullptr;
      for (HuntWindow &h : hunt_windows)
        if (k >= h.lo && k <= h.hi && *h.seen == 0 && h.budget > 0) { w = &h; break; }
      if (quiet && w) {
        ++hunts;
        --w->budget;
        SpyWrite(3, 0);
        Run(4 * 44);
        const size_t at = k;
        const uint32_t w = SpyRead(9);
        const uint16_t want2 = SpyWord(cur, 9, true);
        if ((w & 0xffffu) != want2) {
          std::fprintf(stderr,
                       "microcycle %zu (PC %" PRIo64 "): FLAG-2 reads %04x, the "
                       "reference says %04x\n",
                       at, cur.v[kPc], w & 0xffffu, want2);
          ++bad;
        }
        ++regs_hunted;
        if (cur.v[kWmapd]) ++flag2_wmapd;
        if (cur.v[kDestspcd]) ++flag2_destspcd;
        if (cur.v[kImodd]) ++flag2_imodd;
        if (cur.v[kPdlwrited]) ++flag2_pdlwrited;
        if (cur.v[kSpushd]) ++flag2_spushd;
        if (cur.v[kIwrited]) ++flag2_iwrited;
        last_edge = -1;
        ++resume_skipped;
        SpyWrite(3, 1);
        Run(4 * 44);
      }
      continue;
    }
    if (!quiet) continue;
    ++next_target;

    // ---- HALT.  `spy_write(CLK, 0)`, CC's first act: muir/tests/lashup.rs
    // ---- :152, and tests/spy.rs:729-741 for what it means.
    const size_t before = k;
    SpyWrite(3, 0);
    // `SRUN` is one master clock behind `RUN`, so the microcycle in flight
    // completes and at most one more begins.  Give it four generator cycles
    // at the slowest speed and require it to be still by then.
    Run(4 * 44);
    machine_halted = true;
    const size_t at = k;
    if (at < before) Fail("the machine went backwards over a halt", at, before);

    // It is halted, and it stays halted.  muir/tests/halt.rs:100-105 makes
    // the same claim of a machine stopped another way: stepped on and never
    // moved.
    Run(2000);
    if (k != at) Fail("a halted machine ran a microcycle", k, at);

    // ---- CYCLES.  `Machine::cycles`, muir/src/rtl.rs:2386.  The console's
    // ---- own count of retired microcycles is what names the row every
    // ---- register below is compared against, so if it is wrong every one of
    // ---- them says so.
    const std::vector<uint32_t> c = DoRead(Con(kRegCycles), 1);
    const uint64_t cycles = c.at(0) | (static_cast<uint64_t>(c.at(1)) << 32);
    if (cycles != at) Fail("CYCLES", cycles, at);
    // **THE HIGH HALVES ARE ZERO THROUGHOUT AND THE LATCH IS THEREFORE
    // UNTESTED IN VALUE.**  The boot PROM is 600,000 microcycles and 27
    // million ticks, so neither counter comes near its thirty-second bit; the
    // burst above reads both halves as one transaction, which exercises the
    // latch's shape, but nothing here can tell a latched high half from a
    // live one.  Asserted rather than assumed, so that a longer reference
    // re-opens it, and said on this check's own output.
    if (c.at(1) != 0) Fail("CYCLESH before the counter has a high half", c.at(1), 0);

    // ---- the sixteen.  `Engine::spy_read`, muir/src/rtl.rs:2679.
    for (int e = 0; e < 16; ++e) {
      const uint32_t w = SpyRead(e);
      if (w >> 16) Fail("a diagnostic read said it was not answered", w >> 16, 0);
      const uint16_t want = SpyWord(cur, e, true);
      if ((w & 0xffff) != want) {
        std::fprintf(stderr,
                     "microcycle %zu (PC %" PRIo64 "): diagnostic register %d, %s, "
                     "reads %04x, the reference says %04x\n",
                     at, cur.v[kPc], e, kSpyName[e], w & 0xffffu, want);
        ++bad;
      }
      ++regs_compared;
    }
    if (cur.v[kWmapd]) ++flag2_wmapd;
    if (cur.v[kDestspcd]) ++flag2_destspcd;
    if (cur.v[kImodd]) ++flag2_imodd;
    if (cur.v[kPdlwrited]) ++flag2_pdlwrited;
    if (cur.v[kSpushd]) ++flag2_spushd;
    if (cur.v[kIwrited]) ++flag2_iwrited;
    if (cur.v[kPc] != last_pc) { ++distinct_pc; last_pc = cur.v[kPc]; }

    // ---- FLAG-1 halted is muir's own constant.
    const uint16_t f1 = SpyRead(8) & 0xffffu;
    if (f1 != kFlag1Halted) Fail("FLAG-1 while halted", f1, kFlag1Halted);

    // ---- VMA AND Q, against the reference's own columns for this row.
    //
    // **THE LATCH FIRST, AND BEFORE ANYTHING RE-ARMS IT.**  Word 8 read on
    // its own must hand back the `Q` that the LAST read of word 7 latched
    // beside it --- the rule is VMA then Q, as it is CYCLES then CYCLESH ---
    // so the value here belongs to the previous halt and not to this one.  A
    // word 8 that read the machine live would give this row's `Q`, and the
    // two differ wherever `Q` moved in between.
    {
      const uint32_t q_alone = ReadWord(Con(kRegQ));
      if (vq_have_prev) {
        ++vq_latch_samples;
        if (vq_prev_q != static_cast<uint32_t>(cur.v[kQ])) ++vq_latch_moving;
        if (q_alone != vq_prev_q) {
          std::fprintf(stderr,
                       "microcycle %zu (PC %" PRIo64 "): Q read alone is "
                       "%08x, the last read of VMA latched %08x --- word 8 is "
                       "a latch armed by word 7, not the machine live\n",
                       at, cur.v[kPc], q_alone, vq_prev_q);
          ++bad;
        }
      }
      // **AND MD ALONE, FOR THE SAME REASON AND BEFORE ANYTHING RE-ARMS.**
      // Word 9 joins word 7's latch rather than reading the machine live, so
      // read on its own it must hand back the MD that the LAST read of word 7
      // took --- the previous halt's.  MD moves far more than `Q` does over
      // MIT's boot PROM, so this is evidence at nearly every halt where the
      // Q-alone test is evidence at two.
      const uint32_t md_alone = ReadWord(Con(kRegMd));
      if (vq_have_prev) {
        ++md_latch_samples;
        if (vq_prev_md != static_cast<uint32_t>(cur.v[kMd])) ++md_latch_moving;
        if (md_alone != vq_prev_md) {
          std::fprintf(stderr,
                       "microcycle %zu (PC %" PRIo64 "): MD read alone is "
                       "%08x, the last read of VMA latched %08x --- word 9 is "
                       "on word 7's latch, not the machine live\n",
                       at, cur.v[kPc], md_alone, vq_prev_md);
          ++bad;
        }
      }
      // And now the three, in one burst, which is the way a program reads
      // them: beat one is VMA and arms the latch, beats two and three are the
      // `Q` and the MD that were standing beside it at that same instant.
      const std::vector<uint32_t> vq = DoRead(Con(kRegVma), 2);
      const uint32_t vma_w = vq.at(0), q_w = vq.at(1), md_w = vq.at(2);
      if (vma_w != static_cast<uint32_t>(cur.v[kVma])) {
        std::fprintf(stderr,
                     "microcycle %zu (PC %" PRIo64 "): VMA reads %08x, the "
                     "reference says %08x\n",
                     at, cur.v[kPc], vma_w,
                     static_cast<uint32_t>(cur.v[kVma]));
        ++bad;
      }
      if (q_w != static_cast<uint32_t>(cur.v[kQ])) {
        std::fprintf(stderr,
                     "microcycle %zu (PC %" PRIo64 "): Q reads %08x, the "
                     "reference says %08x\n",
                     at, cur.v[kPc], q_w, static_cast<uint32_t>(cur.v[kQ]));
        ++bad;
      }
      if (md_w != static_cast<uint32_t>(cur.v[kMd])) {
        std::fprintf(stderr,
                     "microcycle %zu (PC %" PRIo64 "): MD reads %08x, the "
                     "reference says %08x\n",
                     at, cur.v[kPc], md_w, static_cast<uint32_t>(cur.v[kMd]));
        ++bad;
      }
      ++vq_compared;
      if (cur.v[kVma] != cur.v[kQ]) ++vq_distinct;
      if (cur.v[kMd] != cur.v[kVma]) ++md_off_vma;
      if (cur.v[kMd] != cur.v[kQ]) ++md_off_q;
      vq_prev_q = q_w;
      vq_prev_md = md_w;
      vq_have_prev = true;
    }

    // ---- and the machine did not move under all that reading.
    if (k != at) Fail("the machine ran while the console read it", k, at);
    const std::vector<uint32_t> c2 = DoRead(Con(kRegCycles), 1);
    if ((c2.at(0) | (static_cast<uint64_t>(c2.at(1)) << 32)) != cycles)
      Fail("CYCLES moved while the machine was halted", c2.at(0), cycles);

    // ---- A STEP, ASSERTED.  CC's `CC-CLOCK` is `2` then `0`, and muir's
    // ---- own words for it are "raising step clocks the machine once".  So
    // ---- the row must move by exactly one: a fabric that dropped the bit
    // ---- stands still, and one that took it as a level runs a microcycle
    // ---- every master clock the bit is up, which over these 176 ticks
    // ---- would be four or five.
    const size_t before_step = k;
    // The stepped microcycle straddles the halt exactly as the resumed one
    // does --- the generator has been running all through the reads --- so its
    // LENGTH is not the reference's and is not compared.  Its existence is,
    // which is the assertion below.
    last_edge = -1;
    ++resume_skipped;
    SpyWrite(3, 2);
    Run(4 * 44);
    // `SSDONE` is `FLAG-1` bit 9 and is the board's own witness that the step
    // it was asked for has run.  It is read while `STEP` is still up, where
    // muir shows it set: two master clocks behind the write, and it does not
    // fall until two after the bit is lowered.
    const uint16_t f1s = SpyRead(8) & 0xffffu;
    SpyWrite(3, 0);
    Run(4 * 44);
    if (k != before_step + 1)
      Fail("a write of 2 to the clock control register did not run exactly one "
           "microcycle",
           k - before_step, 1);
    if ((f1s & 0x200u) == 0)
      Fail("FLAG-1 SSDONE is down after a step", f1s, f1s | 0x200u);
    if ((f1s & 0x100u) != 0)
      Fail("FLAG-1 SRUN is up during a step, which is not a running machine",
           f1s, f1s & ~0x100u);
    ++step_moved;

    // ---- START.  muir/tests/lashup.rs:311-315.
    //
    // The microcycle that straddles the halt is as long as the halt, so its
    // length is not the reference's and is not compared: `last_edge` is
    // dropped before the machine moves and the next edge re-anchors it.  The
    // exemption is one microcycle a halt and is counted.
    last_edge = -1;
    ++resume_skipped;
    SpyWrite(3, 1);
    Run(4 * 44);
    machine_halted = false;
    if (k <= at) Fail("the machine did not start again", k, at);
    // Running, `FLAG-1` bit 8 is up: muir/tests/spy.rs:705, and `cc.rs`'s own
    // "running"/"halted" line reads exactly this bit.
    const uint16_t f1r = SpyRead(8) & 0xffffu;
    if ((f1r & 0x100u) == 0)
      Fail("FLAG-1 says the machine is halted after a start", f1r, kFlag1Running);
    ++visits;
  }

  if (k != total_rows && bad < 20) {
    std::fprintf(stderr,
                 "FAIL: the run stopped after %zu of %zu microcycles\n", k,
                 total_rows);
    ++bad;
  }
  if (!no_halts && visits != sizeof targets / sizeof *targets)
    Fail("halts made", visits, sizeof targets / sizeof *targets);

  // ---------------------------------------------------------------- the face
  //
  // No muir reference exists for any of this: it is the AXI3 protocol and the
  // rule that every address on the port is answered.

  // The machine is left halted for the rest, so that nothing below races it.
  //
  // The reference is exhausted by here --- 600,000 microcycles of MIT's boot
  // PROM and no more --- so what follows is the face's own, held to the AXI3
  // protocol and to read-back.
  SpyWrite(3, 0);
  Run(4 * 44);
  const size_t at_end = k;

  // ------------------------------------------- CC-EXECUTE, the whole road
  //
  // **THE ACT THE DEBUG CABLE EXISTS FOR, over every piece between an AXI
  // write and the machine's own IR.**  CC reads a scratchpad by writing a
  // microinstruction into the debug IR and asking for one clock with `NOP11`
  // and `IDEBUG` up: the instruction loads into `IR` and the datapath shows
  // the console its operands and its result on the A, M and O buses without
  // executing it.  On the board it came back with the debugger's own stale
  // OBUS, because the clock control register was one bit wide and the
  // machine never stepped.
  //
  // It is done HERE, after the reference is exhausted, and that is not
  // tidiness: a nopped debug clock still retires a microcycle and still
  // advances `PC`, so the PROM instruction it stands in for is SKIPPED.  Run
  // in the middle of the trace it would derail every row after it.
  //
  // **AND THE READ-BACK IS NOT A LOOPBACK.**  Registers 0, 1 and 2 are
  // written to the debug IR and read from `IR` --- "read and write at the
  // same address are uncorrelated", says the interface's own document --- so
  // the word comes back only if it went out to the debug IR, through
  // `IDEBUG` onto the I bus, and into `IR` at the step's own edge.  A
  // register block that put the middle half where the low one goes would
  // read back correctly at all three if this were a loopback, and does not.
  {
    // `((A-MEM 100) SETA A-MEM-3)`, muir's own filler instruction.  The A
    // destination is harmless and `NOP11` stops it happening in any case,
    // which is the whole point of a noop debug clock.
    const uint64_t kAluClass = 1ull << 12;              // IR<13:12> = 1
    const uint64_t kSetA = 5ull << 3;                   // IR<8:3> = 5, SETA
    const uint64_t insn = kAluClass | kSetA |
                          (3ull << 32) |                // IR<41:32>, A source
                          (1ull << 25) | (0100ull << 14);  // IR<25>, IR<23:14>

    SpyWrite(0, static_cast<uint16_t>(insn));
    SpyWrite(1, static_cast<uint16_t>(insn >> 16));
    SpyWrite(2, static_cast<uint16_t>(insn >> 32));
    Run(4 * 44);

    // CC-NOOP-DEBUG-CLOCK: `16` OCTAL --- STEP, NOP11 and IDEBUG, bits 3:1.
    // Decimal 16 is bit 4 alone, LDSTAT, which clocks nothing at all.
    const uint64_t cyc_before = Cycles();
    SpyWrite(3, 016);
    Run(4 * 44);

    // Read while the write is still up: `IR` holds the forced instruction and
    // `FLAG-2`'s NOP bit is what `NOP11` makes.
    const uint64_t got = static_cast<uint64_t>(SpyRead(0) & 0xffffu) |
                         static_cast<uint64_t>(SpyRead(1) & 0xffffu) << 16 |
                         static_cast<uint64_t>(SpyRead(2) & 0xffffu) << 32;
    const uint16_t f2x = SpyRead(9) & 0xffffu;
    const uint64_t cyc_after = Cycles();

    // **AND THE O BUS IS READ AFTER THE WRITE GOES BACK TO ZERO, WHICH IS
    // CC'S OWN ORDER AND NOT A CONVENIENCE.**  `cc_clock` is `16` then `0`
    // and only then the read, and it has to be: a nopped cycle decodes as no
    // class at all, so while `NOP11` is up the output select is `2'b00` and
    // the O bus carries the byte masker's output rather than the ALU's.
    // Measured, with the write still up: 0xfffffcff where the A bus reads
    // 0xffffffff.  Lowering the write does NOT take the instruction out of
    // `IR` --- only a clocked microcycle would, and the machine is halted ---
    // so what is read below is still the forced instruction's own result.
    SpyWrite(3, 0);
    Run(4 * 44);
    const uint32_t obx = static_cast<uint32_t>(SpyRead(6) & 0xffffu) |
                         static_cast<uint32_t>(SpyRead(7) & 0xffffu) << 16;
    const uint32_t ax = static_cast<uint32_t>(SpyRead(12) & 0xffffu) |
                        static_cast<uint32_t>(SpyRead(13) & 0xffffu) << 16;

    if (cyc_after != cyc_before + 1)
      Fail("a noop debug clock did not run exactly one microcycle",
           cyc_after - cyc_before, 1);
    if (got != insn) Fail("the debug IR read back through IR", got, insn);
    // `FLAG-2` bit 4 is `NOP`, which `NOP11` makes: the instruction is in
    // `IR` and is not being executed, which is what lets a console look at a
    // scratchpad without changing it.
    if ((f2x & 0x10u) == 0)
      Fail("FLAG-2 NOP is down under a noop debug clock", f2x, f2x | 0x10u);
    // The instruction is `SETA`, so the O bus IS the A bus --- the read
    // `(cadr:cc-read-a-mem 3)` makes, and the one that came back wrong on the
    // board.  Comparing them needs no reference: it is what the ALU function
    // means, and a fabric that answered a stale OBUS fails it.
    if (obx != ax)
      Fail("SETA put something other than the A bus on the OB", obx, ax);
  }

  // Every word of page 0, and the three that are still not registers.
  long unmapped_seen = 0;
  // 6 is RESET --- see the reset section --- 7, 8 and 9 are VMA, Q and MD,
  // read and compared at every halt above, and **10, 11 and 12 are the
  // readout of the machine's memories**, which `build/readout.pass` holds
  // in full against every array in the processor.  What is asserted here is
  // only that they are no longer unmapped and that the window's own idle
  // values are what they read before anything has been asked of it: the
  // machine has been halted since `SpyWrite(3, 0)` above and nothing has
  // ever written word 10, so the echo must still be the reserved selector
  // and the word the one a selector this fabric does not map answers with.
  // **A zero in either would be a window that cannot say "nothing has been
  // asked"**, which is the whole reason neither value is zero.
  {
    const uint32_t echo = ReadWord(Con(10));
    if (echo != 0x3FFFFu) Fail("the readout's echo before anything is asked", echo, 0x3FFFFu);
    const uint32_t lo = ReadWord(Con(11));
    if (lo != 0x5A5AA5A5u) Fail("the readout's low half before anything is asked", lo, 0x5A5AA5A5u);
    const uint32_t hi = ReadWord(Con(12));
    if (hi != 0xA5A5u) Fail("the readout's high half before anything is asked", hi, 0xA5A5u);
  }
  // **AND WORD 13 IS THE LIGHT PANEL'S BUTTON**, which the section at the end
  // of this file presses; what is asserted here is only that it reads the
  // key's own top half and not zero, so that a window pointed somewhere else
  // cannot look like a console with an unpressed button.
  {
    const uint32_t w = ReadWord(Con(kRegBoot));
    if ((w >> 16) != kBootMark) Fail("the boot register's marker", w >> 16, kBootMark);
  }
  // **AND WORD 14 IS THE DEBUG CABLE'S ROLE**, which the section at the end of
  // this file asks for and gives back; what is asserted here is only its own
  // marker, for word 13's reason.  A board that has never been told anything
  // is a DEBUGGEE, so the role's bit reads clear.
  {
    const uint32_t w = ReadWord(Con(kRegDebug));
    if ((w >> 16) != kDebugMark) Fail("the debug cable's marker", w >> 16, kDebugMark);
    if (w & 1u) Fail("a board that was told nothing says it has the role", 1, 0);
  }
  // **AND WORD 15 IS THE CABLE'S TWO COUNTS.**  A Pmod row is routed as
  // coupled pairs and this link drives all four of them single-ended, so an
  // edge can couple into the strobe beside it and misalign a frame; what that
  // costs is refused frames, and these two numbers are how often.  It carries
  // a marker of one byte, twenty-four bits of count leaving eight, and what is
  // asserted here is that and nothing else --- `build/dbg_cable.pass` is what
  // holds the counting itself, with two boards on a cable.
  {
    const uint32_t w = ReadWord(Con(15));
    if ((w >> 24) != 0x44u) Fail("the frame counts' marker", w >> 24, 0x44u);
    if (w == kUnmapped) Fail("word 15 reading as an unused word", w, 0x44000000u);
  }
  // Outside the window, across the port's gigabyte.  A read nothing answers
  // hangs both Arm cores at one PC each, measured on the board, so what is
  // held is that these complete at all --- and with a word a program can
  // recognise.
  const uint32_t outside[] = {kBase + 0x80u, kBase + 0x1000u, kBase + 0x10000000u,
                              kBase - 4u, 0xBFFFFFFCu, 0x00000000u, 0x40000000u};
  for (uint32_t a : outside) {
    const uint32_t w = ReadWord(a);
    if (w != kUnmapped) Fail("an address outside the window", w, kUnmapped);
    ++unmapped_seen;
    DoWrite(a, 0xFFFFFFFFu, 0xF);   // dropped, and it must still answer
  }

  // A burst walks the window a word a beat.
  {
    const std::vector<uint32_t> b = DoRead(Con(0), 5);
    if (b.size() != 6) Fail("beats in a burst of six", b.size(), 6);
    if (b.at(0) != kIdent) Fail("IDENT in a burst", b.at(0), kIdent);
    if (b.at(4) == b.at(5)) Fail("TICKS and TICKSH read alike", b.at(4), b.at(5));
    if (b.at(5) != 0) Fail("TICKSH before the counter has a high half", b.at(5), 0);
  }

  // The mode register: a write of PROMDISABLE shows in `FLAG-1` bit 12 ---
  // muir/src/spy.rs:207-212 for the bit in the register, spy.rs:353-356 for
  // the bit in the flag word --- and the harness sees the same bit leave the
  // register block.  This is the console's WRITE path, and the only one of
  // the three written registers whose effect a read can see.
  SpyWrite(5, 0x20);
  Run(4 * 44);
  if (!dut->promdisable_o) Fail("PROMDISABLE out of the register block", 0, 1);
  {
    const uint16_t f = SpyRead(8) & 0xffffu;
    if ((f & (1u << 12)) == 0) Fail("FLAG-1 bit 12 after a PROMDISABLE write", f, f | (1u << 12));
  }
  SpyWrite(5, 0x00);
  Run(4 * 44);
  if (dut->promdisable_o) Fail("PROMDISABLE after a write of zero", 1, 0);

  // The two pulses, bits 6 and 7: `-PROG.RESET` and `PROG.BOOT`, gated with
  // the strobe on OLORD2 and asserted `REGISTER_PULSE_NS` before the register
  // loads --- muir/src/spy.rs:229-234 and busint.rs:254-263.  They leave the
  // register block here and are folded into `unused` in `cadr_machine.sv`;
  // what they reach is the machine's business, that they are made is this
  // module's.
  bool saw_reset = false, saw_boot = false;
  {
    axi.st = Axi::AW; axi.addr = Spy(5); axi.len = 0; axi.beat = 0;
    axi.id = rnd() & 0xFFF; axi.began = tick; axi.hold = 0;
    dut->s_awaddr = Spy(5); dut->s_awlen = 0; dut->s_awid = axi.id;
    dut->s_wdata = 0xC0; dut->s_wstrb = 0xF;
    ++axi_writes;
    while (axi.st != Axi::IDLE && bad < 20) {
      Tick();
      if (dut->prog_reset_o) saw_reset = true;
      if (dut->prog_boot_o) saw_boot = true;
    }
    Run(64);
  }
  if (!saw_reset) Fail("-PROG.RESET on a mode write with bit 6", 0, 1);
  if (!saw_boot) Fail("PROG.BOOT on a mode write with bit 7", 0, 1);
  SpyWrite(5, 0);
  Run(4 * 44);

  // muir's `write_strobe` is `eadr & 7`: `EADR3` does not reach the write
  // decoder, so a write at register 13 loads the mode register.  Measured,
  // not asserted --- the decoder is `cadr_spy_registers.sv`'s.
  SpyWrite(13, 0x20);
  Run(4 * 44);
  if (dut->promdisable_o) ++alias_landed;
  SpyWrite(5, 0);
  Run(4 * 44);

  // ---- the arbiter.  The processor's own Unibus master stands here.
  long cpu_cycles = 0, cpu_waited = 0;
  {
    // The console must not take the bus from a cycle already running.
    dut->cpu_addr = 0766012u;  dut->cpu_write = 0;  dut->cpu_wdata = 0;
    dut->cpu_msyn = 1;
    long waited = 0;
    while (!dut->cpu_ssyn && waited < 400) { Tick(); ++waited; }
    if (!dut->cpu_ssyn) Fail("the processor's own Unibus cycle was never answered", 0, 1);
    ++cpu_cycles;
    // With the processor's strobe up, the console asks and must wait.
    axi.st = Axi::AR; axi.addr = Spy(5); axi.len = 0; axi.beat = 0;
    axi.id = rnd() & 0xFFF; axi.got.clear(); axi.began = tick; axi.hold = 0;
    dut->s_araddr = Spy(5); dut->s_arlen = 0; dut->s_arid = axi.id;
    ++axi_reads;
    for (int i = 0; i < 200; ++i) {
      Tick();
      if (dut->con_gnt) Fail("the console took the bus with the processor's strobe up", 1, 0);
      ++cpu_waited;
    }
    if (!dut->cpu_ssyn) Fail("the processor's cycle was truncated", 0, 1);
    dut->cpu_msyn = 0;
    while (axi.st != Axi::IDLE && bad < 20) Tick();
    if (axi.got.at(0) >> 16) Fail("the console's cycle after the processor let go", 1, 0);
  }

  // ---- the engine's own bound.  The grant held off for ever: the AXI read
  // ---- must still complete, and say it was not answered.  A bound nothing
  // ---- exercises is not a bound.
  {
    dut->gnt_inhibit = 1;
    const long began = tick;
    const uint32_t w = ReadWord(Spy(5));
    dut->gnt_inhibit = 0;
    const long took = tick - began;
    if ((w & 0x10000u) == 0) Fail("a lost diagnostic read did not say so", w, w | 0x10000u);
    if (took > static_cast<long>(kLostT) + 256)
      Fail("a lost read took longer than the bound", took, kLostT);
    // STAT's two bits say different things and the difference is the point:
    // `answered` is the LAST cycle's and `lost` is sticky since reset.  A
    // check that read them only after a lost cycle could not tell one from
    // the other, so both are read twice.
    const uint32_t s = ReadWord(Con(kRegStat));
    if ((s & 0x8u) == 0) Fail("STAT's lost bit after a lost cycle", s, s | 8u);
    if ((s & 0x4u) != 0) Fail("STAT's answered bit after a lost cycle", s, s & ~4u);
    const uint32_t g = SpyRead(5);
    if (g >> 16) Fail("a good read after a lost one", g >> 16, 0);
    const uint32_t s2 = ReadWord(Con(kRegStat));
    if ((s2 & 0x4u) == 0) Fail("STAT's answered bit after a good cycle", s2, s2 | 4u);
    if ((s2 & 0x8u) == 0) Fail("STAT's lost bit is not sticky", s2, s2 | 8u);
  }
  // And the machine is unharmed by all of it.
  if (k != at_end) Fail("the machine ran while it was halted", k, at_end);

  // ------------------------------------------------------------------ the reset
  //
  // **A CONSOLE THAT CANNOT RESTART THE MACHINE CAN ONLY WATCH IT DIE.**  On
  // the board `boards/arty-z7-20/cadr_arty.sv`'s reset is MMCM lock or BTN1, and BTN1 is a
  // finger on a board nobody is sitting at.  Page 0's word 6 takes
  // `RESET_KEY` and pulses the machine's reset for `RESET_T` ticks; nothing
  // else it can be written with does anything at all.
  //
  // What is held, and where the reference is:
  //
  //   a wrong value does nothing   a property, and this project's own idiom:
  //                                zero is what a dead bus reads and all ones
  //                                what an undriven one reads, so neither may
  //                                be a value the instrument can mean.
  //                                Twelve writes below --- the key
  //                                byte-reversed, two single-bit neighbours
  //                                of it, the key with the strobes short, and
  //                                the key at the words either side.
  //   the key pulses               and the pulse is `RESET_T` ticks, COUNTED.
  //                                `LOST_T`'s lesson one register along: a
  //                                length nobody asserts is not a length, and
  //                                a reset that is a level a program can
  //                                leave asserted is not a pulse.
  //   the machine comes back up    muir: `Engine::boot` is reset then run,
  //                                and `cadr_spy_registers.sv`'s own reset
  //                                block calls itself the boot button held
  //                                --- `run` up, `promdisable` down.  So the
  //                                machine re-runs MIT's boot PROM from
  //                                microcycle zero, and the trace is REWOUND
  //                                and compared column for column again.
  //   the console does not         a decision, argued in the module.  The
  //   reset itself                 count in register 6 reads back non-zero
  //                                after the reset, which a console the
  //                                machine's reset reached could not do; and
  //                                STAT's sticky `lost` bit, set just above,
  //                                survives it.
  //   CYCLES and TICKS restart     because they ARE the machine's:
  //                                `Machine::cycles` is zero at reset and
  //                                `Rtl::ns()` with it, so a CYCLES that went
  //                                on counting would name a microcycle no row
  //                                of any trace has.

  // The register before anything has been asked of it.  **NEITHER ZERO NOR
  // ALL ONES**: a virgin read that answered zero would be indistinguishable
  // from a bus that is not there, which is the trap the EMIO tally's marker
  // bits and `UNMAPPED` both exist to avoid.
  {
    const uint32_t w = ReadWord(Con(kRegReset));
    if (w == 0u || w == 0xFFFFFFFFu)
      Fail("the reset register before any reset", w, kResetMark << 16);
    if ((w >> 16) != kResetMark)
      Fail("the reset register's marker", w >> 16, kResetMark);
    if (((w >> 8) & 0xFFu) != 0u)
      Fail("resets counted before any was asked", (w >> 8) & 0xFFu, 0u);
    if (w & 1u) Fail("the reset register says a pulse is up", 1, 0);
  }

  // ---- a write of anything but the key does nothing at all.
  long wrong_writes = 0;
  {
    const struct { const char *what; uint32_t at; uint32_t v; uint32_t strb; }
        wrong[] = {
            {"zero", Con(kRegReset), 0u, 0xFu},
            {"all ones", Con(kRegReset), 0xFFFFFFFFu, 0xFu},
            {"IDENT written back", Con(kRegReset), kIdent, 0xFu},
            {"UNMAPPED written back", Con(kRegReset), kUnmapped, 0xFu},
            {"the register's own read-back", Con(kRegReset), kResetMark << 16, 0xFu},
            {"the key byte-reversed", Con(kRegReset), 0x54455352u, 0xFu},
            {"the key with bit 0 flipped", Con(kRegReset), kResetKey ^ 1u, 0xFu},
            {"the key with bit 31 flipped", Con(kRegReset), kResetKey ^ 0x80000000u, 0xFu},
            {"the key with only the low byte strobed", Con(kRegReset), kResetKey, 0x1u},
            {"the key with the top byte held off", Con(kRegReset), kResetKey, 0x7u},
            {"the key at the word beside it", Con(kRegReset + 1), kResetKey, 0xFu},
            {"the key at the word before it", Con(kRegReset - 1), kResetKey, 0xFu},
        };
    for (const auto &t : wrong) {
      const long runs_before = mrst_runs;
      DoWrite(t.at, t.v, t.strb);
      Run(kResetT * 4);
      if (mrst_runs != runs_before) {
        std::fprintf(stderr,
                     "tick %ld: a write of %s pulsed the machine's reset\n",
                     tick, t.what);
        ++bad;
      }
      const uint32_t w = ReadWord(Con(kRegReset));
      if (((w >> 8) & 0xFFu) != 0u) {
        std::fprintf(stderr,
                     "tick %ld: a write of %s reset the machine: the reset "
                     "count reads %u, the reference says 0\n",
                     tick, t.what, (w >> 8) & 0xFFu);
        ++bad;
      }
      if (dut->run_o) {
        std::fprintf(stderr,
                     "tick %ld: a write of %s started the halted machine\n",
                     tick, t.what);
        ++bad;
      }
      ++wrong_writes;
    }
  }

  // ---- and the key does.  PROMDISABLE is set first, so that the reset has
  // ---- something to clear that a program can see through the same face.
  SpyWrite(5, 0x20);
  Run(4 * 44);
  if (!dut->promdisable_o) Fail("PROMDISABLE before the reset", 0, 1);
  if (dut->run_o) Fail("RUN before the reset", 1, 0);
  if (k != at_end) Fail("the machine ran before the reset", k, at_end);

  const long runs_before_key  = mrst_runs;
  const long ticks_before_key = mrst_ticks;
  DoWrite(Con(kRegReset), kResetKey, 0xF);
  const long pulse = mrst_ticks - ticks_before_key;

  // **THE PULSE IS `RESET_T` TICKS AND THE CHECK ASSERTS THE NUMBER.**  A
  // check that only asked whether the machine came back would call any length
  // right, and a reset is precisely the kind of thing that works at the wrong
  // length --- every register inside the machine takes a synchronous reset, so
  // one tick clears them all and the machine boots.  That is `RD_FINISH_T`
  // and `LOST_T` a third time: the constant is the claim.
  //
  // AND THE SAME MEASUREMENT SAYS THE WRITE DID NOT ANSWER EARLY.  `DoWrite`
  // returns at the B handshake, so every one of the 64 ticks having been
  // counted by the time it returns is exactly the statement that `BVALID` was
  // offered after the machine left reset.  A console that answered the moment
  // it armed the countdown would report a pulse of two or three.
  //
  // **THE TWO ARE ASKED IN THIS ORDER SO THAT EACH MUTATION GETS ITS OWN
  // LINE.**  A console that answered the moment it armed the countdown fails
  // both --- the write returns with the line still up AND the ticks counted
  // so far are two --- and asked the other way round both records
  // (`console-reset-pulse-a-tick-short` and
  // `console-answers-the-reset-write-before-the-machine-is-back`) print the
  // same first line.  Measured, both ways.
  if (mrst_runs != runs_before_key + 1)
    Fail("pulses on a write of the key", mrst_runs - runs_before_key, 1);
  if (dut->mach_rst_o)
    Fail("the write answered with the machine still in reset", 1, 0);
  if (pulse != kResetT)
    Fail("the ticks the machine's reset was held for", pulse, kResetT);

  // **CHECKED HERE AND NOT A TICK LATER**, because the trace is rewound in
  // the next statement and the machine's first microcycle after the reset has
  // to be its own.  The write does not answer until the pulse is over, which
  // is what makes these two reads of the machine's own state legitimate this
  // early: `run` up and `promdisable` down is `Engine::boot`, and it is what
  // `cadr_spy_registers.sv`'s reset block means by the boot button held.
  if (!dut->run_o) Fail("RUN after a console reset", 0, 1);
  if (dut->promdisable_o) Fail("PROMDISABLE after a console reset", 1, 0);

  // ---- AND THE MACHINE RE-RUNS MIT'S BOOT PROM FROM MICROCYCLE ZERO.
  //
  // The claim worth making, and the only one that says the reset reached
  // everything rather than the two bits a status read happens to show: the
  // trace is rewound, `k` goes back to nothing, and every column is compared
  // again from row 0 --- the same comparison the 600,000 microcycles above
  // were held to, against a machine that has already run all of them once.
  std::rewind(f);
  k = 0;
  if (!read_next(cur)) {
    std::fprintf(stderr, "FAIL: %s: cannot be rewound\n", path);
    ++bad;
  }
  dut->rdata = static_cast<uint32_t>(rdata_for[0]);
  dut->sintr = static_cast<uint8_t>(cur.v[kSintr]);
  last_edge = -1;
  bus_outstanding = false;
  replaying = true;
  // **THE WHOLE REFERENCE AND NOT A PREFIX.**  It costs ten seconds on top of
  // this check's seven, and it buys the only evidence there is that a console
  // reset leaves a machine that WORKS rather than one that merely starts: the
  // boot PROM's control-store pass, PROMDISABLE, and the 16,951 disk polls are
  // all past microcycle 500,000, and on the replay every one of them is being
  // executed against an `imem` the FIRST run filled with zeros where a cold
  // fabric has all ones.  A twenty-thousand-microcycle prefix would have said
  // nothing about any of it.
  const size_t kReplay = total_rows;
  const long replay_deadline = tick + static_cast<long>(kReplay) * 96 + 100000;
  while (k < kReplay && tick < replay_deadline && bad < 20) Tick();
  if (k < kReplay && bad < 20) {
    std::fprintf(stderr,
                 "FAIL: after the console's reset the machine reached %zu of "
                 "the first %zu microcycles\n", k, kReplay);
    ++bad;
  }
  // The comparison is switched off the way the main run switches it off ---
  // by exhausting the rows --- rather than left on to compare the second
  // reset below against a trace that knows nothing about it.
  const size_t at_replay = k;
  k = total_rows;
  replaying = false;

  // ---- CYCLES restarted with it, and the console did not.
  {
    const std::vector<uint32_t> c = DoRead(Con(kRegCycles), 1);
    const uint64_t cy = c.at(0) | (static_cast<uint64_t>(c.at(1)) << 32);
    // The machine is running, so CYCLES may have moved on by a microcycle or
    // two between the last `Tick()` above and the beat that answered: what is
    // held is that it counts from the reset and not from the beginning of
    // time, which is a difference of 600,000.
    if (cy < at_replay || cy > at_replay + 8)
      Fail("CYCLES after a console reset", cy, at_replay);
  }
  // **THE CONSOLE DID NOT RESET ITSELF**, and that is the decision the module
  // argues rather than a detail of it.  A console the machine's reset reached
  // would count zero here, would have lost STAT's sticky `lost` bit set a few
  // lines above --- and, the one that matters on the board, would have
  // abandoned the very AXI write that asked for the reset, leaving the Arm
  // core waiting for a response that never comes.  That is the freeze
  // `rtl/plumbing/cadr_gp0_default.sv` exists to prevent, delivered by the console
  // itself.
  {
    const uint32_t w = ReadWord(Con(kRegReset));
    if ((w >> 16) != kResetMark)
      Fail("the reset register's marker after a reset", w >> 16, kResetMark);
    if (((w >> 8) & 0xFFu) != 1u)
      Fail("resets counted after one reset", (w >> 8) & 0xFFu, 1u);
    if (w & 1u) Fail("the reset register says a pulse is still up", 1, 0);
    const uint32_t id = ReadWord(Con(kRegIdent));
    if (id != kIdent) Fail("IDENT after a console reset", id, kIdent);
    const uint32_t s = ReadWord(Con(kRegStat));
    if ((s & 0x8u) == 0)
      Fail("STAT's sticky lost bit across a machine reset", s, s | 8u);
  }

  // ---- a second reset, so that the count is a count and not a flag, and so
  // ---- that the machine can be reset twice without a power cycle --- which
  // ---- is the whole request.
  const long ticks_before_key2 = mrst_ticks;
  DoWrite(Con(kRegReset), kResetKey, 0xF);
  const long pulse2 = mrst_ticks - ticks_before_key2;
  if (pulse2 != kResetT)
    Fail("the ticks the second reset was held for", pulse2, kResetT);
  Run(4 * 44);
  {
    const uint32_t w = ReadWord(Con(kRegReset));
    if (((w >> 8) & 0xFFu) != 2u)
      Fail("resets counted after two resets", (w >> 8) & 0xFFu, 2u);
    if (!dut->run_o) Fail("RUN after the second console reset", 0, 1);
  }

  // ------------------------------------------------- the light panel's button
  //
  // **A CONSOLE THAT CAN RESET THE MACHINE AND CANNOT BOOT IT IS MISSING THE
  // CONTROL A CADR ACTUALLY HAS.**  Page 0's word 13 takes `BOOT_KEY` and
  // holds `-BOOT2` down for `BOOT_T` ticks; the 74S02 at OLORD2 1A07 makes
  // `-BOOT` of it, beside the keyboard's `-BOOT1` and the debug cable's
  // `PROG.BOOT`, and the processor cannot tell the three apart.
  //
  // What is held here, and how it differs from the reset above:
  //
  //   a wrong value does nothing   the same twelve shapes as word 6, for the
  //                                same reason: zero off a dead bus and all
  //                                ones off an undriven one must not stop a
  //                                machine.
  //   the key presses              and the press is `BOOT_T` ticks, COUNTED,
  //                                and the write does not answer until the
  //                                button is back up.
  //   RUN preset, PROMDISABLE      `Engine::boot`, which is what `-BOOT`
  //   clear                        does at the 74S74 at OLORD1 1A14 and
  //                                through `RESET` at the 74S10 at 1C08.
  //   **THE PROM RUNS FROM WORD 0** the claim the reset's replay makes at
  //                                length and this one makes cheaply: word 0
  //                                is `jump 45`, so the PC goes 0 then `0o45`.
  //                                muir's `starts_the_prom` in
  //                                `tests/keyboard_boot.rs` is the same test.
  //   **AND THE CONSOLE'S OWN      the difference that says a boot is not a
  //   COUNTERS DO NOT RESTART**    reset: `cycles` counts the machine's
  //                                microcycles since the CONSOLE came up and
  //                                `-BOOT` has no pin on the console, so
  //                                CYCLES goes on from where it was.  A
  //                                console wired to reset itself on a boot,
  //                                or a boot wired to the fabric's reset,
  //                                fails here and nowhere else.
  {
    const uint32_t w = ReadWord(Con(kRegBoot));
    if (w == 0u || w == 0xFFFFFFFFu)
      Fail("the boot register before any press", w, kBootMark << 16);
    if ((w >> 16) != kBootMark) Fail("the boot register's marker", w >> 16, kBootMark);
    if (((w >> 8) & 0xFFu) != 0u)
      Fail("presses counted before any was asked", (w >> 8) & 0xFFu, 0u);
    if (w & 1u) Fail("the boot register says the button is down", 1, 0);
  }

  long wrong_boot_writes = 0;
  {
    const struct { const char *what; uint32_t at; uint32_t v; uint32_t strb; }
        wrong[] = {
            {"zero", Con(kRegBoot), 0u, 0xFu},
            {"all ones", Con(kRegBoot), 0xFFFFFFFFu, 0xFu},
            {"IDENT written back", Con(kRegBoot), kIdent, 0xFu},
            {"UNMAPPED written back", Con(kRegBoot), kUnmapped, 0xFu},
            {"the register's own read-back", Con(kRegBoot), kBootMark << 16, 0xFu},
            {"the key byte-reversed", Con(kRegBoot), 0x544F4F42u, 0xFu},
            {"the key with bit 0 flipped", Con(kRegBoot), kBootKey ^ 1u, 0xFu},
            {"the key with bit 31 flipped", Con(kRegBoot), kBootKey ^ 0x80000000u, 0xFu},
            {"the key with only the low byte strobed", Con(kRegBoot), kBootKey, 0x1u},
            {"the key with the top byte held off", Con(kRegBoot), kBootKey, 0x7u},
            {"the key at the word beside it", Con(kRegBoot + 1), kBootKey, 0xFu},
            {"the key at the word before it", Con(kRegBoot - 1), kBootKey, 0xFu},
            // And the RESET key at the BOOT word, which is the one mistake
            // two keyed registers on one page make possible.
            {"the reset key at the boot word", Con(kRegBoot), kResetKey, 0xFu},
        };
    for (const auto &t : wrong) {
      const long runs_before = mboot_runs;
      DoWrite(t.at, t.v, t.strb);
      Run(kBootT * 4);
      if (mboot_runs != runs_before) {
        std::fprintf(stderr, "tick %ld: a write of %s pressed the boot button\n", tick, t.what);
        ++bad;
      }
      const uint32_t w = ReadWord(Con(kRegBoot));
      if (((w >> 8) & 0xFFu) != 0u) {
        std::fprintf(stderr,
                     "tick %ld: a write of %s pressed the button: the press count reads "
                     "%u, the reference says 0\n", tick, t.what, (w >> 8) & 0xFFu);
        ++bad;
      }
      ++wrong_boot_writes;
    }
  }

  // ---- and the key does.  The machine is halted and PROMDISABLE set first,
  // ---- so the button has both of the things `-BOOT` undoes to undo.
  SpyWrite(3, 0);
  SpyWrite(5, 0x20);
  Run(8 * 44);
  if (!dut->promdisable_o) Fail("PROMDISABLE before the boot", 0, 1);
  if (dut->run_o) Fail("RUN before the boot", 1, 0);

  const std::vector<uint32_t> cyc_before = DoRead(Con(kRegCycles), 1);
  const uint64_t cycles_before_boot =
      cyc_before.at(0) | (static_cast<uint64_t>(cyc_before.at(1)) << 32);

  const long boot_runs_before  = mboot_runs;
  const long boot_ticks_before = mboot_ticks;
  const long mrst_runs_before_boot = mrst_runs;
  DoWrite(Con(kRegBoot), kBootKey, 0xF);
  const long press = mboot_ticks - boot_ticks_before;

  if (mboot_runs != boot_runs_before + 1)
    Fail("presses on a write of the key", mboot_runs - boot_runs_before, 1);
  // The write answered with the button already up, which is what makes the
  // reads below reads of a machine already running the PROM.
  if (dut->mach_boot_o)
    Fail("the write answered with the button still down", 1, 0);
  if (press != kBootT)
    Fail("the ticks the boot button was held for", press, kBootT);
  if (!dut->run_o) Fail("RUN after a console boot", 0, 1);
  if (dut->promdisable_o) Fail("PROMDISABLE after a console boot", 1, 0);
  // **A BOOT IS NOT A RESET**, and this is the line that says so: the
  // machine's reset must not have been pulsed by it.  `-BOOT` clears the
  // console's own registers through `RESET` at OLORD2 1C08, which is a
  // different wire from the one `cadr_arty.sv` gives `cadr_machine`'s `rst`.
  if (mrst_runs != mrst_runs_before_boot)
    Fail("machine resets over a boot", mrst_runs - mrst_runs_before_boot, 0);

  // ---- THE PROM RUNS FROM WORD 0: the PC goes 0, then `0o45`.
  {
    std::vector<unsigned> seen;
    const long until = tick + 12 * 44;
    while (tick < until) {
      if (seen.empty() || seen.back() != dut->pc) seen.push_back(dut->pc);
      Tick();
    }
    bool started = false;
    for (size_t i = 0; i + 1 < seen.size(); ++i)
      if (seen[i] == 0 && (seen[i + 1] == 045 ||
                           (seen[i + 1] == 1 && i + 2 < seen.size() && seen[i + 2] == 045)))
        started = true;
    if (!started) {
      std::fprintf(stderr, "FAIL: after a console boot the PROM did not start from 0; PC saw:");
      for (size_t i = 0; i < seen.size() && i < 12; ++i)
        std::fprintf(stderr, " %o", seen[i]);
      std::fprintf(stderr, "\n");
      ++bad;
    }
  }

  // ---- the press counted, and the console's own counters NOT restarted.
  {
    const uint32_t w = ReadWord(Con(kRegBoot));
    if ((w >> 16) != kBootMark)
      Fail("the boot register's marker after a press", w >> 16, kBootMark);
    if (((w >> 8) & 0xFFu) != 1u)
      Fail("presses counted after one press", (w >> 8) & 0xFFu, 1u);
    if (w & 1u) Fail("the boot register says the button is still down", 1, 0);
    const std::vector<uint32_t> c = DoRead(Con(kRegCycles), 1);
    const uint64_t cy = c.at(0) | (static_cast<uint64_t>(c.at(1)) << 32);
    if (cy < cycles_before_boot)
      Fail("CYCLES went backwards over a boot, which is a reset and not a boot", cy,
           cycles_before_boot);
    const uint32_t s = ReadWord(Con(kRegStat));
    if ((s & 0x8u) == 0)
      Fail("STAT's sticky lost bit across a console boot", s, s | 8u);
  }

  // ---- a second press, so that the count is a count and not a flag.
  {
    const long before = mboot_ticks;
    DoWrite(Con(kRegBoot), kBootKey, 0xF);
    if (mboot_ticks - before != kBootT)
      Fail("the ticks the second press was held for", mboot_ticks - before, kBootT);
    Run(4 * 44);
    const uint32_t w = ReadWord(Con(kRegBoot));
    if (((w >> 8) & 0xFFu) != 2u)
      Fail("presses counted after two presses", (w >> 8) & 0xFFu, 2u);
    if (!dut->run_o) Fail("RUN after the second console boot", 0, 1);
  }

  // ------------------------------------------- the debug cable's role, word 14
  //
  // **WHAT THIS HOLDS AND WHAT IT DOES NOT.**  `build/dbg_cable.pass` is the
  // check that has a real connector on it, with two boards and sixteen pads
  // the testbench can see contention on; what a console cannot be asked about
  // there is whether its own word works.  So the four the connector answers
  // with are STIMULUS here and the testbench is what plays the connector ---
  // which is the only way to ask the one question that matters about this
  // word: it reports what the fabric HAS beside what it was TOLD, and those
  // differ exactly when the connector refuses.
  //
  //   a wrong value does nothing   the same shapes as words 6 and 13, for the
  //                                same reason, and the two keys are a value
  //                                and its complement so that neither is a
  //                                partial write of the other
  //   the key asks                 `dbg_connect` rises and the connects are
  //                                COUNTED, and the write does NOT wait --- a
  //                                role is a level and not a pulse, and a
  //                                write that waited for a role the fabric
  //                                may refuse would hang the store that made
  //                                it
  //   the complement gives it back and does not count
  //   **AND ASKED IS NOT HAD**     the connector held down while the console
  //                                asks: bit 1 up, bit 0 DOWN, and bit 2
  //                                saying why.  A console that reported one
  //                                bit would be lying about the other.
  long wrong_debug_writes = 0;
  {
    // Nothing has been asked yet, and nothing is plugged in.
    dut->dbg_engaged = 0;
    dut->dbg_foreign = 0;
    dut->dbg_live = 0;
    dut->dbg_active = 0;
    Run(8);
    const uint32_t w = ReadWord(Con(kRegDebug));
    if ((w >> 16) != kDebugMark)
      Fail("the debug register's marker", w >> 16, kDebugMark);
    if (((w >> 9) & 0x7Fu) != 0u)
      Fail("connects counted before any was asked", (w >> 9) & 0x7Fu, 0u);
    if (w & (kDbgEngaged | kDbgAsked))
      Fail("a board told nothing says it asked for the role or has it", w & 3u, 0u);
    if (dut->dbg_connect) Fail("the console asks for the role unasked", 1, 0);
  }

  // A write of anything but a key does nothing at all.  The same twelve
  // shapes the reset and the button are given, plus each key at the word
  // either side --- which is the mistake three keyed registers on one page
  // make possible.
  {
    const struct { uint32_t at; uint32_t v; uint32_t strb; } wrong[] = {
        {Con(kRegDebug), 0u, 0xF},
        {Con(kRegDebug), 0xFFFFFFFFu, 0xF},
        {Con(kRegDebug), kIdent, 0xF},
        {Con(kRegDebug), kUnmapped, 0xF},
        {Con(kRegDebug), ReadWord(Con(kRegDebug)), 0xF},
        {Con(kRegDebug), 0x52474244u, 0xF},              // the key, byte-reversed
        {Con(kRegDebug), kDebugKey ^ 1u, 0xF},
        {Con(kRegDebug), kDebugKey ^ 0x80000000u, 0xF},
        {Con(kRegDebug), kDebugKey & 0x00FFFFFFu, 0xF},
        {Con(kRegDebug), kDebugKey & 0xFFFFFF00u, 0xF},
        {Con(kRegDebug), kDebugKey, 0x3},                // the key, strobes short
        {Con(kRegDebug), kResetKey, 0xF},
        {Con(kRegDebug), kBootKey, 0xF},
        {Con(kRegBoot), kDebugKey, 0xF},
        {Con(kRegReset), kDebugKey, 0xF},
    };
    for (const auto &t : wrong) {
      DoWrite(t.at, t.v, t.strb);
      Run(8);
      ++wrong_debug_writes;
    }
    const uint32_t w = ReadWord(Con(kRegDebug));
    if (((w >> 8) & 0xFFu) != 0u)
      Fail("a write that is not a key was counted as a connect", (w >> 8) & 0xFFu, 0u);
    if (w & kDbgAsked) Fail("a write that is not a key asked for the role", 1, 0);
    if (dut->dbg_connect) Fail("a write that is not a key reached the connector", 1, 0);
  }

  // The key asks, and the connector refuses: somebody else has the role.
  {
    dut->dbg_foreign = 1;
    dut->dbg_active = 1;
    DoWrite(Con(kRegDebug), kDebugKey, 0xF);
    Run(8);
    if (!dut->dbg_connect) Fail("the key reached the connector", 0, 1);
    const uint32_t w = ReadWord(Con(kRegDebug));
    if (((w >> 9) & 0x7Fu) != 1u)
      Fail("connects counted after one", (w >> 9) & 0x7Fu, 1u);
    if (!(w & kDbgAsked)) Fail("word 14 says what was asked for", 0, 1);
    if (w & kDbgEngaged)
      Fail("word 14 says this board HAS a role the connector refused", 1, 0);
    if (!(w & kDbgForeign)) Fail("word 14 says why it was refused", 0, 1);
    if (!(w & kDbgActive)) Fail("word 14 reports the connector as driven", 0, 1);
  }

  // And then the connector takes it, with the far end answering.
  {
    dut->dbg_foreign = 0;
    dut->dbg_active = 0;
    dut->dbg_engaged = 1;
    dut->dbg_live = 1;
    Run(8);
    const uint32_t w = ReadWord(Con(kRegDebug));
    if ((w & (kDbgEngaged | kDbgAsked)) != (kDbgEngaged | kDbgAsked))
      Fail("word 14 with the role taken", w & 3u, 3u);
    if (w & kDbgForeign) Fail("word 14 says somebody else has it too", 1, 0);
    if (!(w & kDbgLive)) Fail("word 14 reports good frames arriving", 0, 1);
  }

  // The complement gives it back, and does not count.
  {
    DoWrite(Con(kRegDebug), kDebugUnkey, 0xF);
    Run(8);
    if (dut->dbg_connect) Fail("the complement let the role go", 1, 0);
    dut->dbg_engaged = 0;
    dut->dbg_live = 0;
    Run(8);
    const uint32_t w = ReadWord(Con(kRegDebug));
    if (w & (kDbgEngaged | kDbgAsked))
      Fail("word 14 after giving the role back", w & 3u, 0u);
    if (((w >> 9) & 0x7Fu) != 1u)
      Fail("a disconnect counted as a connect", (w >> 9) & 0x7Fu, 1u);
  }

  // And a second connect, so that the count is a count and not a flag.
  {
    DoWrite(Con(kRegDebug), kDebugKey, 0xF);
    Run(8);
    const uint32_t w = ReadWord(Con(kRegDebug));
    if (((w >> 9) & 0x7Fu) != 2u)
      Fail("connects counted after two", (w >> 9) & 0x7Fu, 2u);
    DoWrite(Con(kRegDebug), kDebugUnkey, 0xF);
    Run(8);
  }

  // ---- WHICH WAY ROUND THE JA RIBBON WAS MADE ----------------------------
  //
  // Three more keys on the same word, and the console's own half of the rule:
  // a setting may not move under a board that is already the debugger.  What
  // the connector makes of the setting is `build/dbg_cable.pass`'s, with two
  // real boards on a real cable; what is here is the register.
  {
    if (dut->dbg_wiring != 0)
      Fail("the wiring a board comes up with", dut->dbg_wiring, 0);
    DoWrite(Con(kRegDebug), kWireCross, 0xF);
    Run(8);
    if (dut->dbg_wiring != 2) Fail("the crossover key", dut->dbg_wiring, 2);
    DoWrite(Con(kRegDebug), kWireStr, 0xF);
    Run(8);
    if (dut->dbg_wiring != 1) Fail("the straight key", dut->dbg_wiring, 1);
    // **AND NOT WHILE THIS BOARD IS THE DEBUGGER.**  The wiring decides which
    // four pins the connector drives, so a setting moving inside a session
    // would take them out from under a standing cycle.
    DoWrite(Con(kRegDebug), kDebugKey, 0xF);
    Run(8);
    dut->dbg_engaged = 1;
    Run(8);
    DoWrite(Con(kRegDebug), kWireCross, 0xF);
    Run(8);
    if (dut->dbg_wiring != 1)
      Fail("a wiring moved under a board that already had the role", dut->dbg_wiring, 1);
    dut->dbg_engaged = 0;
    DoWrite(Con(kRegDebug), kDebugUnkey, 0xF);
    Run(8);
    DoWrite(Con(kRegDebug), kWireAuto, 0xF);
    Run(8);
    if (dut->dbg_wiring != 0) Fail("the auto key", dut->dbg_wiring, 0);
    // **AND A KEY IS THE WHOLE WORD.**  Word 14's other writes take a key for
    // the reason the machine's reset and the light panel's button take one: a
    // value that means nothing must not change what the connector is doing.
    // A board that came up `crossover` off a stray store would drive four pins
    // nobody is listening to and report that nothing was answering.
    {
      const uint32_t near_miss[] = {
          kWireStr ^ 1u, kWireStr ^ 0x80000000u, kWireStr & 0xFFFF0000u,
          kWireCross ^ 0xFFu, kWireAuto | 0x00000100u, 0u, 0xFFFFFFFFu,
      };
      for (unsigned q = 0; q < sizeof near_miss / sizeof near_miss[0]; ++q) {
        DoWrite(Con(kRegDebug), near_miss[q], 0xF);
        Run(8);
        if (dut->dbg_wiring != 0)
          Fail("a write that is not a key moved the wiring", dut->dbg_wiring, 0);
      }
    }
    // And what the connector made of it is reported, one value a meaning,
    // beside the bit that says a mirrored ribbon is on the pins this board
    // answers on.
    dut->dbg_wire_state = 5;   // crossover, detected
    dut->dbg_peer_far = 1;
    Run(8);
    const uint32_t w = ReadWord(Con(kRegDebug));
    if (((w >> 5) & 7u) != 5u)
      Fail("what the connector made of the wiring", (w >> 5) & 7u, 5u);
    if (!(w & (1u << 8)))
      Fail("the connector saying the two ends disagree about the cable", 0, 1);
    dut->dbg_wire_state = 0;
    dut->dbg_peer_far = 0;
    Run(8);
  }

  dut->final();
  delete dut;
  std::fclose(f);

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %zu microcycles\n", bad, k);
    return 1;
  }

  int thin = 0;
  if (regs_compared != visits * 16) {
    std::fprintf(stderr, "FAIL: %ld register reads over %ld halts\n", regs_compared, visits);
    ++thin;
  }
  // The lag is a number the module states, and the check has to be able to
  // tell it from the next one along.  `lag_moving` is how many of the samples
  // were taken where the two candidate rows carry different PCs --- on the
  // others a lag of one and a lag of nothing read alike, and the sample says
  // nothing.
  if (lag_seen != 1) {
    std::fprintf(stderr,
                 "FAIL: the console's read-back is %ld microcycles behind the "
                 "machine; `rtl/machine/cadr_console_bus.sv` says one, being loaded at "
                 "the microcycle boundary and nowhere else\n", lag_seen);
    ++thin;
  }
  if (lag_moving < 8) {
    std::fprintf(stderr,
                 "FAIL: only %ld of %ld lag samples were taken where the two "
                 "candidate rows differ, so the measurement is nearly vacuous\n",
                 lag_moving, lag_samples);
    ++thin;
  }
  // **VMA AND Q ARE EVIDENCE ONLY WHERE THEY DIFFER.**  These two words exist
  // to tell one fault from another BY THEIR DIFFERENCE, so a check made where
  // they read alike cannot tell a console that crosses them from one that does
  // not.  The same floor the PC lag sweep puts on its own discriminating
  // samples, for the same reason, and a reference that stopped carrying a
  // moving VMA would re-open it rather than quietly narrowing the claim.
  if (vq_compared != visits) {
    std::fprintf(stderr, "FAIL: VMA and Q read at %ld of %ld halts\n",
                 vq_compared, visits);
    ++thin;
  }
  if (vq_distinct < 8) {
    std::fprintf(stderr,
                 "FAIL: VMA and Q differed at only %ld of %ld halts, so a "
                 "console that read one where the other was wanted would pass "
                 "here on no evidence\n", vq_distinct, vq_compared);
    ++thin;
  }
  if (vq_latch_moving < 1) {
    std::fprintf(stderr,
                 "FAIL: none of the %ld reads of Q alone was taken at a halt "
                 "where the latched Q and the live one differ, so the latch is "
                 "untested\n", vq_latch_samples);
    ++thin;
  }
  // **AND MD IS EVIDENCE ONLY WHERE IT DIFFERS FROM WHAT IT MIGHT BE CROSSED
  // WITH.**  The mistake this word exists to be safe from is being handed
  // back where VMA or `Q` was asked for, and a halt where two of the three
  // read alike cannot tell a console that crosses them from one that does
  // not.  Two floors and not one, because a crossing is with one register at
  // a time.
  if (md_off_vma < 8) {
    std::fprintf(stderr,
                 "FAIL: MD differed from VMA at only %ld of %ld halts, so a "
                 "console that read one where the other was wanted would pass "
                 "here on no evidence\n", md_off_vma, vq_compared);
    ++thin;
  }
  if (md_off_q < 8) {
    std::fprintf(stderr,
                 "FAIL: MD differed from Q at only %ld of %ld halts, so a "
                 "console that read one where the other was wanted would pass "
                 "here on no evidence\n", md_off_q, vq_compared);
    ++thin;
  }
  if (md_latch_moving < 1) {
    std::fprintf(stderr,
                 "FAIL: none of the %ld reads of MD alone was taken at a halt "
                 "where the latched MD and the live one differ, so the latch "
                 "is untested\n", md_latch_samples);
    ++thin;
  }
  // **AND THE ARC THE CONSTRAINTS CLAIM, WHICH IS THE ONE THING HERE THAT IS
  // ABOUT THE BOARD AND NOT ABOUT THE FACE.**  `cadr_machine.xdc` gives each
  // of the three captures fifteen ticks because every register of
  // `cadr_console_state.sv` falls in its relaxed set.  An exemption too wide
  // tests nothing and looks exactly like one that is right, so the shortest
  // arc each source actually has is measured here and this is where it fails.
  for (int i = 0; i < 3; ++i) {
    if (cap_min[i] < 0) {
      std::fprintf(stderr,
                   "FAIL: %s never moved, so nothing here says what arc the "
                   "capture of it has\n", kCapName[i]);
      ++thin;
    } else if (cap_min[i] < kRelaxedT) {
      std::fprintf(stderr,
                   "FAIL: the shortest arc from a change of %s to the boundary "
                   "that captures it is %ld ticks, and cadr_machine.xdc's "
                   "relaxed set asks the fabric for %ld\n",
                   kCapName[i], cap_min[i], kRelaxedT);
      ++thin;
    }
  }
  if (distinct_pc < 8) {
    std::fprintf(stderr,
                 "FAIL: the console stopped the machine at %ld distinct PCs; a "
                 "check that reads one microcycle sixteen times reads one\n",
                 distinct_pc);
    ++thin;
  }
  // **ALL SIX, OR THE CLAIM ABOVE IS NOT MADE.**  Five of these are compared
  // with muir nowhere else in this repository, and a `FLAG-2` read at a
  // microcycle where an enable happens to be down says nothing about that
  // enable.  A trace that stops carrying one re-opens this rather than
  // quietly narrowing the claim.
  const struct { const char *name; long n; } enables[] = {
      {"WMAPD", flag2_wmapd},         {"DESTSPCD", flag2_destspcd},
      {"IWRITED", flag2_iwrited},     {"IMODD", flag2_imodd},
      {"PDLWRITED", flag2_pdlwrited}, {"SPUSHD", flag2_spushd}};
  for (const auto &e : enables)
    if (e.n == 0) {
      std::fprintf(stderr,
                   "FAIL: FLAG-2's %s was down at every microcycle the console "
                   "stopped at, so the bit is unchecked; the reference does "
                   "carry it, so the hunt's window or its budget is wrong\n",
                   e.name);
      ++thin;
    }
  if (thin) return 1;

  std::printf(
      "ok: the console halts the machine, reads it and starts it again\n"
      "    %ld halts over %zu microcycles of MIT's boot PROM, each at a\n"
      "      microcycle the reference names; %ld PCs distinct; every one of\n"
      "      the 600,000 microcycles still agrees with muir column for column\n"
      "      across the halts (%ld lengths checked, %ld exempt for the\n"
      "      Unibus arbitration this interface does not have, %ld inside a\n"
      "      tick on a stalled row, %ld re-anchored at a step or a resume)\n"
      "    %ld diagnostic registers read and compared against `Engine::spy_read`\n"
      "      --- IR in three halves, OPC, PC, OB, FLAG-1, FLAG-2, M, A, ST,\n"
      "      and the open bus at register 3 reading all ones\n"
      "    %ld more halts read FLAG-2 alone, where the reference says an\n"
      "      enable lives, until each had been met.  **FIVE OF ITS SIX\n"
      "      WRITE-PIPELINE ENABLES ARE COMPARED WITH muir NOWHERE ELSE IN\n"
      "      THIS REPOSITORY**, `cadr_microcycle.sv` bringing out only\n"
      "      IWRITED: WMAPD up at %ld of them, DESTSPCD %ld, IMODD %ld,\n"
      "      PDLWRITED %ld, SPUSHD %ld, IWRITED %ld\n"
      "    VMA, Q and MD --- page 0's words 7, 8 and 9, which are NOT on the\n"
      "      diagnostic bus and which MIT's sixteen have no register for ---\n"
      "      read at %ld halts and compared against the reference's own vma, q\n"
      "      and md columns for the row the console says it stopped at.  %ld\n"
      "      of them carry VMA != Q and so can tell one from the other; %ld\n"
      "      carry MD != VMA and %ld carry MD != Q, which is what makes a\n"
      "      console that handed MD back where one of the others was asked\n"
      "      for visible here.  The rest are not evidence and are not counted\n"
      "    the latch, which is what makes the THREE one microcycle: words 8\n"
      "      and 9 are read ALONE first at every halt and must give the Q and\n"
      "      the MD that the LAST read of word 7 took --- the previous halt's.\n"
      "      Q: %ld reads, of which %ld where that latched Q and the live one\n"
      "      differ.  MD: %ld reads, of which %ld --- MD moves over MIT's boot\n"
      "      PROM where Q barely does, so the same test is evidence at nearly\n"
      "      every halt for one word and at a handful for the other\n"
      "    NOT TESTED: that the THREE are one instant rather than three reads\n"
      "      a few ticks apart.  Every read here is made at a HALT, where none\n"
      "      of the three is moving, so three instants and one read alike; and\n"
      "      Q is 0xfffffffe on all but the first thousand rows besides.  No\n"
      "      arrangement of this reference can tell them apart.  What IS held\n"
      "      is that all three name the row the console stopped at\n"
      "    the arc cadr_machine.xdc relaxes, MEASURED over %ld boundaries: the\n"
      "      shortest distance from a change of the source to the boundary\n"
      "      that captures it --- VMA %ld ticks, Q %ld, MD %ld, against the\n"
      "      fifteen that file's relaxed set asks the fabric for.  vma and q\n"
      "      are written only inside `if (mclk_edge)` and cannot move between\n"
      "      boundaries at all; **MD can**, through `md_pending && hang` ---\n"
      "      the word -LOADMD deskewed, taken under a parked generator --- so\n"
      "      the third of these three numbers is the one that had to be asked\n"
      "    FLAG-1 read 0xe800 halted and 0xe900 running, which are muir's own\n"
      "      HALTED and RUNNING; CYCLES named the reference's own row every time\n"
      "    the face: %ld reads and %ld writes, %ld beats, %ld held until taken,\n"
      "      %ld addresses answered with 0x%08x inside the window and out of\n"
      "      it, a burst of six walking the window, OKAY everywhere\n"
      "    the mode register written and read back through FLAG-1; both\n"
      "      pulses seen; the arbiter kept the processor's own cycle whole\n"
      "      over %ld ticks of contention; a grant held off for ever still\n"
      "      completed the read and said it was lost\n"
      "    the read-back is %ld microcycle behind the machine, MEASURED on %ld\n"
      "      reads of PC with the machine RUNNING, of which %ld were taken\n"
      "      where the two candidate rows carry different PCs and so are\n"
      "      evidence at all --- the others say nothing and are not counted.\n"
      "      `cadr_console_bus.sv` loads the diagnostic mux's answer at the\n"
      "      microcycle boundary and nowhere else, which is what gives that\n"
      "      sixteen-way mux a microcycle to settle instead of a tick; a halted\n"
      "      read is exact, MCLK running whether or not MACHRUN does\n"
      "    NOT TESTED IN VALUE: the high halves of CYCLES and TICKS, which are\n"
      "      zero over a 600,000-microcycle reference; the burst reads both\n"
      "      halves so the latch's shape is exercised and its value is not\n"
      "    the reset: %ld writes that are not the key pulsed nothing --- zero,\n"
      "      all ones, IDENT, UNMAPPED, the register's own read-back, the key\n"
      "      byte-reversed, two single-bit neighbours of it, the key with the\n"
      "      strobes short, and the key at the words either side.  The key\n"
      "      itself held the machine's reset for %ld ticks and the second one\n"
      "      for %ld, which is the length `RESET_T` states, and the write did\n"
      "      not answer until it was over.  The machine came back up with RUN\n"
      "      set and PROMDISABLE clear --- muir's `Engine::boot`, and\n"
      "      `cadr_spy_registers.sv`'s own boot button held --- and RE-EXECUTED\n"
      "      ALL %ld MICROCYCLES OF MIT'S BOOT PROM FROM MICROCYCLE ZERO, on a\n"
      "      machine that had already run every one of them once.  PC, IR, LPC\n"
      "      and OPC compared against the same reference on every row; the\n"
      "      DATAPATH IS NOT COMPARED THERE and must not be, because `amem`,\n"
      "      `mmem`, `pdl` and `imem` are RAM and NO reset this machine has\n"
      "      clears them --- not this one, not the button's, not MIT's own RESET,\n"
      "      which is a wire into flip flops and reaches no 93425A.  A is\n"
      "      0x1fc on the replay's first row where the reference says 0, and\n"
      "      that is right: a console reset that cleared memory would be a\n"
      "      DIFFERENT reset from the button's.  The console survived its own\n"
      "      reset: IDENT, STAT's sticky lost bit and the reset count all\n"
      "      stand, and the AXI write that asked for the reset completed\n"
      "    THE LIGHT PANEL'S BUTTON, page 0's word 13: %ld writes that are not\n"
      "      the key pressed nothing --- the same twelve shapes as the reset's,\n"
      "      and the RESET key at the BOOT word, which is the one mistake two\n"
      "      keyed registers on one page make possible.  The key itself held\n"
      "      -BOOT2 down for %ld ticks and the second press for %ld, the length\n"
      "      `BOOT_T` states, and the write did not answer until the button was\n"
      "      back up.  RUN was preset and PROMDISABLE cleared, and THE BOOT PROM\n"
      "      RAN FROM WORD 0 --- PC 0 then 0o45, which is muir's own test in\n"
      "      tests/keyboard_boot.rs.  **AND IT IS NOT A RESET**: the machine's\n"
      "      reset was not pulsed, CYCLES did not go back to zero, and STAT's\n"
      "      sticky lost bit stood.  It is -BOOT2 and not the mode register's\n"
      "      PROG.BOOT, which is the debug cable's line and the other machine's\n"
      "    a write of 2 to the clock control register ran EXACTLY ONE\n"
      "      microcycle on %ld of %ld halts, with FLAG-1's SSDONE up and SRUN\n"
      "      down --- the whole road from an AXI write to MACHRUN's first term\n"
      "    THE DEBUG CABLE'S ROLE, page 0's word 14: %ld writes that are not a\n"
      "      key asked for nothing --- the same shapes as the reset's and the\n"
      "      button's, each key at the words either side, and the other two\n"
      "      keys at this one.  The key asked and was COUNTED and the write did\n"
      "      not wait, a role being a level and not a pulse; the key's\n"
      "      COMPLEMENT gave it back and counted nothing.  **AND ASKED IS NOT\n"
      "      HAD**: with the connector refusing, word 14 read bit 1 up, bit 0\n"
      "      DOWN and bit 2 saying why, which is the one thing about this word\n"
      "      a check with no cable on it can settle\n"
      "    MEASURED, NOT ASSERTED, because the file is not this slice's:\n"
      "      a mode write at register 13 landed %ld times (muir's\n"
      "      write_strobe is `eadr & 7`, so: once)\n",
      visits, total_rows, distinct_pc, lengths_checked, arb_skipped, sub_tick,
      resume_skipped, regs_compared, regs_hunted, flag2_wmapd, flag2_destspcd,
      flag2_imodd, flag2_pdlwrited, flag2_spushd, flag2_iwrited,
      vq_compared, vq_distinct, md_off_vma, md_off_q,
      vq_latch_samples, vq_latch_moving, md_latch_samples, md_latch_moving,
      cap_edges, cap_min[0], cap_min[1], cap_min[2],
      axi_reads, axi_writes,
      axi_beats, axi_stalls, unmapped_seen, kUnmapped, cpu_waited,
      lag_seen, lag_samples, lag_moving,
      wrong_writes, pulse, pulse2, replay_rows,
      wrong_boot_writes, press, mboot_ticks - boot_ticks_before - press,
      step_moved, visits, wrong_debug_writes, alias_landed);
  return 0;
}
