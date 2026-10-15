// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Revision 15's DE25-Nano top level, simulated: `boards/de25-nano/quux15_de25.sv`
// around the shells of `tb/cadr_de25_sim_stubs.sv` (the PLLs, the Reset
// Release, the processor system) and `tb/quux15_core_shell.sv` (the
// core), with this file as the processor, its memory, the buttons, the
// switches and a person reading the lamps and the video pins.  It is
// `tb/cadr_de25_top_tb.cpp`'s check for this top level, and its header has
// the argument: lint holds that every port is connected and cannot tell a
// crossed pair of wires from a straight one; this does.  The top level is
// read only through its pins and through the ports of the shells.
//
// WHAT IS HELD, IN THE ORDER IT RUNS.
//
//   THE CORE'S TWO RESETS (`quux15_core.sv`'s `rq_*`), as the shell sees
//   them: the hard `rst` (the processor's reset, the clock's lock) and the
//   request `rst_req` (KEY1, the console's RESET key, the port not yet
//   live).  The shell's `rst_on` is played as a core whose port drains at
//   once: in reset while either stands.  Below, "in reset" is that.
//
//   THE MACHINE WAITS FOR ITS MEMORY.  With the processor in reset, and then
//   out of it with only the tally's select bit written, the core is held in
//   reset and LEDR6 is dark, by the request alone once the processor is out
//   of its reset; with the open bit the port is live within a handful of
//   clocks, LEDR6 lights and the core is let go.  The tally reads
//   the marker in both halves by the select bit.
//
//   ITS MEMORY IS THE PROCESSOR'S.  A write of the core's master reaches the
//   bridge with the machine's ID, 0, at its own address with its own beat,
//   and its response comes back to the core; a line fill of five beats
//   reaches the bridge with ID 0 and its beats come back in order, the last
//   with RLAST; the tally counts both.  The display reads the frame buffer
//   with ID 2 once the port is live.  The latency probe, started and
//   stopped on the console face's word 48, times both: one read and one
//   write, each sum its longest, none lost.
//
//   THE LAMPS, ONE SOURCE AT A TIME, in the console's steady mode: running,
//   microcycles, the disk, an error halt, each its own LED and no other, with
//   LEDR1 lit for the clock's lock, LEDR6 for the port, LEDR5 and LEDR7 dark.
//
//   THE CONSOLE'S RESET KEY asks for the core's reset, never the hard one,
//   and lets it go.  The console
//   face's word 40 is the period and word 37 main memory's 512 units.
//
//   KEY0 AND THE SWITCHES DO NOTHING: revision 15 has no `-BOOT2` and no
//   no-auto-boot.
//
//   SOFTWARE SHUTTING THE PORT leaves the core running and LEDR6 dark.
//
//   THE PROCESSOR'S RESET resets the core, which runs again when the reset
//   ends, the port still shut, and waits at its memory until software opens
//   it.
//
//   KEY1 AND THE CLOCK'S LOCK: either puts the core into reset for as long
//   as it lasts, KEY1 by the request and the lock by the hard reset, and
//   once it is over the core is let go again, the port being open already.
//
//   THE VIDEO BUS: HSYNC once a line of 1688 pixels for 112 of them, DE on
//   1280 pixels of a line, the forwarded clock running.
//
// The clocks allowed for each wire to answer are the synchronizers' own
// depth plus the registers behind them, written beside each check.

#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>

#include "Vquux15_de25.h"
#include "Vquux15_de25___024root.h"
#include "verilated.h"

namespace {

Vquux15_de25 *top = nullptr;
Vquux15_de25___024root *r = nullptr;
long t = 0;
int fails = 0;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  if (fails > 30) return;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: clock %ld: ", t);
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

// The shells' registers, by the names the two stub files give them.
#define HPS_O(n) (r->quux15_de25__DOT__u_hps__DOT__tbo_##n)
#define HPS_I(n) (r->quux15_de25__DOT__u_hps__DOT__tbi_##n)
#define CORE_O(n) (r->quux15_de25__DOT__u_core__DOT__tbo_##n)
#define CORE_I(n) (r->quux15_de25__DOT__u_core__DOT__tbi_##n)

// The board's main memory and frame buffer (`cadr_ddr_map.sv`, its map).
constexpr uint32_t kMainBase = 0xA0000000u, kDisplayBase = 0xB4000000u;
uint64_t Poison(uint32_t a) { return 0x5EED00005EED0000ull ^ (uint64_t(a) * 0x9E3779B97F4A7C15ull); }

// What the lamps are, lit LOW, by LED.
constexpr int kRun = 0, kClock = 1, kCycle = 2, kDisk = 3, kErrhalt = 4, kPort = 6;
bool Lit(int i) { return ((top->led >> i) & 1) == 0; }
unsigned LitSet() { return (~top->led) & 0xFFu; }

// ------------------------------------------------------------ the memory
//
// The FPGA-to-SDRAM bridge as a memory, as `tb/cadr_de25_top_tb.cpp` has
// it: every address taken at once, reads answered in order after a fixed
// latency, writes after the last beat.  Keyed by the address the BRIDGE was
// given, a beat at a time.
struct Memory {
  std::map<uint32_t, uint64_t> beats;
  struct Rd { int id; uint32_t addr; int n; int sent; long due; };
  std::deque<Rd> reads;
  struct Wr { int id; uint32_t addr; int n; int got; bool done; long at; };
  std::deque<Wr> writes;
  bool ar_hs = false, aw_hs = false, w_hs = false, r_hs = false, b_hs = false;
  uint32_t ar_addr = 0, aw_addr = 0;
  int ar_id = 0, aw_id = 0, ar_len = 0, aw_len = 0;
  uint64_t w_data = 0;
  uint32_t w_strb = 0;
  long machine_writes = 0, machine_reads = 0, display_reads = 0, other_ids = 0, display_off = 0;
  uint32_t last_aw = 0, last_ar = 0, last_strb = 0;
  int last_ar_len = 0;
  uint64_t last_data = 0;

  uint64_t Beat(uint32_t a) {
    auto it = beats.find(a);
    return it == beats.end() ? Poison(a) : it->second;
  }
  void Reset() {
    reads.clear();
    writes.clear();
  }
  void Drive(bool in_reset) {
    HPS_O(hps_f2sdram_arready) = in_reset ? 0 : 1;
    HPS_O(hps_f2sdram_awready) = in_reset ? 0 : 1;
    HPS_O(hps_f2sdram_wready) = in_reset ? 0 : 1;
    HPS_O(hps_f2sdram_rvalid) = 0;
    HPS_O(hps_f2sdram_bvalid) = 0;
    if (in_reset) return;
    if (!reads.empty() && t >= reads.front().due) {
      const Rd &rd = reads.front();
      HPS_O(hps_f2sdram_rvalid) = 1;
      HPS_O(hps_f2sdram_rid) = static_cast<uint8_t>(rd.id);
      HPS_O(hps_f2sdram_rdata) = Beat(rd.addr + 8u * static_cast<uint32_t>(rd.sent));
      HPS_O(hps_f2sdram_rresp) = 0;
      HPS_O(hps_f2sdram_rlast) = (rd.sent + 1 == rd.n) ? 1 : 0;
    }
    if (!writes.empty() && writes.front().done && t >= writes.front().at + 2) {
      HPS_O(hps_f2sdram_bvalid) = 1;
      HPS_O(hps_f2sdram_bid) = static_cast<uint8_t>(writes.front().id);
      HPS_O(hps_f2sdram_bresp) = 0;
    }
  }
  void Sample() {
    ar_hs = HPS_I(hps_f2sdram_arvalid) && HPS_O(hps_f2sdram_arready);
    aw_hs = HPS_I(hps_f2sdram_awvalid) && HPS_O(hps_f2sdram_awready);
    w_hs = HPS_I(hps_f2sdram_wvalid) && HPS_O(hps_f2sdram_wready);
    r_hs = HPS_O(hps_f2sdram_rvalid) && HPS_I(hps_f2sdram_rready);
    b_hs = HPS_O(hps_f2sdram_bvalid) && HPS_I(hps_f2sdram_bready);
    ar_addr = HPS_I(hps_f2sdram_araddr);
    ar_id = HPS_I(hps_f2sdram_arid);
    ar_len = HPS_I(hps_f2sdram_arlen);
    aw_addr = HPS_I(hps_f2sdram_awaddr);
    aw_id = HPS_I(hps_f2sdram_awid);
    aw_len = HPS_I(hps_f2sdram_awlen);
    w_data = HPS_I(hps_f2sdram_wdata);
    w_strb = HPS_I(hps_f2sdram_wstrb);
  }
  void Commit() {
    if (ar_hs) {
      reads.push_back({ar_id, ar_addr, ar_len + 1, 0, t + 8});
      if (ar_id == 0) {
        ++machine_reads;
        last_ar = ar_addr;
        last_ar_len = ar_len;
      } else if (ar_id == 2) {
        ++display_reads;
        if (ar_addr < kDisplayBase || ar_addr >= kDisplayBase + 0x100000u) ++display_off;
      } else {
        ++other_ids;
      }
    }
    if (aw_hs) {
      writes.push_back({aw_id, aw_addr, aw_len + 1, 0, false, 0});
      if (aw_id != 0) ++other_ids;
    }
    if (w_hs) {
      Wr *open = nullptr;
      for (auto &w : writes)
        if (!w.done) {
          open = &w;
          break;
        }
      Check(open != nullptr, "a write beat reached the bridge with no address");
      if (open) {
        const uint32_t a = open->addr + 8u * static_cast<uint32_t>(open->got);
        uint64_t old = Beat(a);
        for (int k = 0; k < 8; ++k)
          if ((w_strb >> k) & 1) old = (old & ~(0xFFull << (8 * k))) | (w_data & (0xFFull << (8 * k)));
        beats[a] = old;
        if (open->id == 0) {
          ++machine_writes;
          last_aw = open->addr;
          last_data = w_data;
          last_strb = w_strb;
        }
        if (++open->got == open->n) {
          open->done = true;
          open->at = t;
        }
      }
    }
    if (r_hs) {
      Rd &rd = reads.front();
      if (++rd.sent == rd.n) reads.pop_front();
    }
    if (b_hs) writes.pop_front();
  }
};

// ------------------------------------------- the lightweight bridge's master
struct LwMaster {
  bool aw = false, w = false, b = false;
  bool aw_hs = false, w_hs = false, b_hs = false;
  bool ar = false, rd = false, ar_hs = false, r_hs = false;
  uint32_t rdata = 0, r_sampled = 0;
  void StartRead(uint32_t addr) {
    HPS_O(hps_lwhps2fpga_araddr) = addr;
    HPS_O(hps_lwhps2fpga_arid) = 1;
    HPS_O(hps_lwhps2fpga_arlen) = 0;
    HPS_O(hps_lwhps2fpga_arsize) = 2;
    HPS_O(hps_lwhps2fpga_arburst) = 1;
    ar = true;
    rd = false;
  }
  void Start(uint32_t addr, uint32_t data) {
    HPS_O(hps_lwhps2fpga_awaddr) = addr;
    HPS_O(hps_lwhps2fpga_awid) = 1;
    HPS_O(hps_lwhps2fpga_awlen) = 0;
    HPS_O(hps_lwhps2fpga_awsize) = 2;
    HPS_O(hps_lwhps2fpga_awburst) = 1;
    HPS_O(hps_lwhps2fpga_wdata) = data;
    HPS_O(hps_lwhps2fpga_wstrb) = 0xF;
    HPS_O(hps_lwhps2fpga_wlast) = 1;
    aw = w = true;
    b = false;
  }
  void Drive() {
    HPS_O(hps_lwhps2fpga_awvalid) = aw ? 1 : 0;
    HPS_O(hps_lwhps2fpga_wvalid) = w ? 1 : 0;
    HPS_O(hps_lwhps2fpga_bready) = 1;
    HPS_O(hps_lwhps2fpga_rready) = 1;
    HPS_O(hps_lwhps2fpga_arvalid) = ar ? 1 : 0;
  }
  void Sample() {
    aw_hs = aw && HPS_I(hps_lwhps2fpga_awready);
    w_hs = w && HPS_I(hps_lwhps2fpga_wready);
    b_hs = HPS_I(hps_lwhps2fpga_bvalid);
    ar_hs = ar && HPS_I(hps_lwhps2fpga_arready);
    r_hs = HPS_I(hps_lwhps2fpga_rvalid);
    r_sampled = HPS_I(hps_lwhps2fpga_rdata);
  }
  void Commit() {
    if (aw_hs) aw = false;
    if (w_hs) w = false;
    if (b_hs) b = true;
    if (ar_hs) ar = false;
    if (r_hs) {
      rd = true;
      rdata = r_sampled;
    }
  }
};

// ------------------------------------------------------ the video pins
struct Video {
  bool prev_hs = false, prev_de = false;
  long hs_rise = -1, hs_high = 0, de_run = 0;
  long hs_periods = 0, hs_bad_period = 0, hs_bad_width = 0, de_lines = 0, de_bad_run = 0;
  long pclk_pulses = 0;
  bool measure = false;
  void Step() {
    const bool hs = top->hdmi_hsync, de = top->hdmi_de;
    if (top->hdmi_pclk) ++pclk_pulses;
    if (hs) ++hs_high;
    if (hs && !prev_hs) {
      if (hs_rise >= 0 && measure) {
        ++hs_periods;
        if (t - hs_rise != 1688) ++hs_bad_period;
      }
      hs_rise = t;
      hs_high = 1;
    }
    if (!hs && prev_hs && measure && hs_high != 112) ++hs_bad_width;
    if (de) ++de_run;
    if (!de && prev_de) {
      if (measure) {
        ++de_lines;
        if (de_run != 1280) ++de_bad_run;
      }
      de_run = 0;
    }
    prev_hs = hs;
    prev_de = de;
  }
};

Memory mem;
LwMaster lw;
Video video;
bool hps_in_reset = true;

// The core in reset by either, as a core whose port drains at once.
bool InReset() { return CORE_I(rst) || CORE_I(rst_req); }
// The clocks the core's request and its hard reset have stood, counted by
// every tick.
long req_clocks = 0, hard_clocks = 0;

void Tick() {
  CORE_O(rst_on) = InReset();
  CORE_O(rst_pend) = 0;
  CORE_O(rst_cut) = 0;
  if (CORE_I(rst_req)) ++req_clocks;
  if (CORE_I(rst)) ++hard_clocks;
  top->clock50_0 = 0;
  top->eval();
  mem.Drive(hps_in_reset);
  lw.Drive();
  top->eval();
  mem.Sample();
  lw.Sample();
  top->clock50_0 = 1;
  top->eval();
  mem.Commit();
  lw.Commit();
  if (hps_in_reset) mem.Reset();
  // The two-wire bus, pulled up and nobody else on it.
  top->hdmi_scl = (top->hdmi_scl__en && !top->hdmi_scl__out) ? 0 : 1;
  top->hdmi_sda = (top->hdmi_sda__en && !top->hdmi_sda__out) ? 0 : 1;
  video.Step();
  ++t;
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

void LwWrite(uint32_t addr, uint32_t data) {
  lw.Start(addr, data);
  const long took = Until([] { return lw.b; }, 2000);
  Check(took >= 0, "the console did not answer a write of %08x at %03x", data, addr);
  Run(4);
}

uint32_t LwRead(uint32_t addr) {
  lw.StartRead(addr);
  const long took = Until([] { return lw.rd; }, 2000);
  Check(took >= 0, "the console did not answer a read at %03x", addr);
  Run(4);
  return lw.rdata;
}

// `quux15_face.sv`'s words, on the lightweight bridge at offset 0.
constexpr uint32_t kResetWord = 6 * 4, kMainWord = 37 * 4, kPeriodWord = 40 * 4, kLampsWord = 35 * 4;
constexpr uint32_t kResetKey = 0x52534554u, kLampSteadyKey = 0x53544459u;
// Page 3, the latency probe: word 48 and its keys, the figures from 49.
constexpr uint32_t kProbeWord = 48 * 4, kProbeRunKey = 0x5052554Eu, kProbeStopKey = 0x53544F50u;

// The core's master: one write of one beat, or one line fill of five.
void CoreIdle() {
  CORE_O(m_awvalid) = 0;
  CORE_O(m_wvalid) = 0;
  CORE_O(m_arvalid) = 0;
  CORE_O(m_bready) = 1;
  CORE_O(m_rready) = 1;
}

void CoreWrite(uint32_t addr, uint64_t data, uint8_t strb) {
  CORE_O(m_awaddr) = addr;
  CORE_O(m_awlen) = 0;
  CORE_O(m_awsize) = 3;
  CORE_O(m_awburst) = 1;
  CORE_O(m_awid) = 0;
  CORE_O(m_wdata) = data;
  CORE_O(m_wstrb) = strb;
  CORE_O(m_wlast) = 1;
  bool aw = true, w = true, b = false;
  for (long i = 0; i < 2000 && (aw || w || !b); ++i) {
    CORE_O(m_awvalid) = aw;
    CORE_O(m_wvalid) = w;
    top->clock50_0 = 0;
    top->eval();
    mem.Drive(hps_in_reset);
    lw.Drive();
    top->eval();
    const bool aw_hs = aw && CORE_I(m_awready), w_hs = w && CORE_I(m_wready), b_hs = CORE_I(m_bvalid);
    const int bresp = CORE_I(m_bresp);
    mem.Sample();
    lw.Sample();
    top->clock50_0 = 1;
    top->eval();
    mem.Commit();
    lw.Commit();
    video.Step();
    ++t;
    if (aw_hs) aw = false;
    if (w_hs) w = false;
    if (b_hs) {
      Check(!aw && !w, "the core was answered a write before it was taken");
      Check(bresp == 0, "the core's write answered %d", bresp);
      b = true;
    }
  }
  CoreIdle();
  Check(!aw && !w && b, "the core's write of %08x was never answered", addr);
}

// A line fill: five beats, the last with RLAST; returns how many came.
int CoreRead(uint32_t addr, uint64_t *got) {
  CORE_O(m_araddr) = addr;
  CORE_O(m_arlen) = 4;
  CORE_O(m_arsize) = 3;
  CORE_O(m_arburst) = 1;
  bool ar = true;
  int n = 0;
  for (long i = 0; i < 2000 && n < 5; ++i) {
    CORE_O(m_arvalid) = ar;
    top->clock50_0 = 0;
    top->eval();
    mem.Drive(hps_in_reset);
    lw.Drive();
    top->eval();
    const bool ar_hs = ar && CORE_I(m_arready);
    const bool r_hs = CORE_I(m_rvalid);
    if (r_hs) {
      got[n] = CORE_I(m_rdata);
      Check(CORE_I(m_rlast) == (n == 4 ? 1 : 0), "the fill's beat %d came with RLAST %d", n, CORE_I(m_rlast));
      Check(ar == false || ar_hs, "a beat reached the core before its address was taken");
      ++n;
    }
    mem.Sample();
    lw.Sample();
    top->clock50_0 = 1;
    top->eval();
    mem.Commit();
    lw.Commit();
    video.Step();
    ++t;
    if (ar_hs) ar = false;
  }
  CoreIdle();
  return n;
}

void Lamps(unsigned want, const char *after) {
  Check(LitSet() == want, "after %s the lit LEDs are %02x, wanting %02x", after, LitSet(), want);
}

// The core's reset held for all of `n` clocks, or never.
long RstTicks(long n) {
  long held = 0;
  for (long i = 0; i < n; ++i) {
    Tick();
    if (InReset()) ++held;
  }
  return held;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vquux15_de25;
  r = top->rootp;

  // THE BOARD AT POWER-ON.  The device still initializing, both keys up, the
  // switches down, the processor in reset with nothing written, the core
  // halted with nothing asked.
  r->quux15_de25__DOT__u_reset_release__DOT__tbo_ninit_done = 1;
  r->quux15_de25__DOT__u_pll__DOT__tbo_unlock = 0;
  top->btn = 3;
  top->sw = 0;
  top->hdmi_scl = 1;
  top->hdmi_sda = 1;
  HPS_O(hps_h2f_reset_reset) = 1;
  HPS_O(hps_hps_gp_gp_out) = 0;
  HPS_O(hps_h2f_warm_reset_handshake_reset_req) = 1;
  CoreIdle();
  CORE_O(obs_halted) = 1;
  CORE_O(obs_errhalt) = 0;
  CORE_O(obs_commit) = 0;
  CORE_O(ch_active) = 0;
  top->eval();
  Run(10);
  r->quux15_de25__DOT__u_reset_release__DOT__tbo_ninit_done = 0;

  // ================================= the machine waits for its memory
  long held = RstTicks(200);
  Check(held == 200, "the core was out of reset %ld clocks of 200 with the processor in reset", 200 - held);
  hps_in_reset = false;
  HPS_O(hps_h2f_reset_reset) = 0;
  HPS_O(hps_hps_gp_gp_out) = 2;   // only the tally's select bit
  held = 0;
  long lit6 = 0, hard = 0;
  for (int i = 0; i < 400; ++i) {
    Tick();
    if (InReset()) ++held;
    if (i >= 12 && CORE_I(rst)) ++hard;
    if (Lit(kPort)) ++lit6;
  }
  Check(held == 400, "with only h2f_gp_out[1] written the core was out of reset %ld clocks of 400", 400 - held);
  Check(hard == 0, "with the port not yet live the core had its hard reset %ld clocks, wanting the request alone",
        hard);
  Check(lit6 == 0, "with only h2f_gp_out[1] written LEDR6 was lit %ld clocks", lit6);
  const uint32_t tally_high = HPS_I(hps_hps_gp_gp_in);
  HPS_O(hps_hps_gp_gp_out) = 1;
  // Three synchronizer stages and the gate's register for the port; the
  // latch, the pending reset and the core's run register after it.
  const long to_live = Until([] { return Lit(kPort); }, 50);
  const long to_run = Until([] { return !InReset(); }, 50);
  Check(to_live >= 0 && to_live <= 6, "LEDR6 lit %ld clocks after h2f_gp_out[0], wanting within 6", to_live);
  Check(to_run >= 0 && to_run <= 4, "the core left reset %ld clocks after the port was live, wanting within 4",
        to_run);
  Run(8);
  const uint32_t tally_low = HPS_I(hps_hps_gp_gp_in);
  Check((tally_low & 0x80008000u) == 0x8000u && (tally_high & 0x80008000u) == 0x8000u,
        "h2f_gp_in reads %08x and %08x by the select bit, and each half carries the marker", tally_low, tally_high);
  std::printf("ok: the core held in reset until the port is live: LEDR6 %ld clocks after the open bit, the core "
              "%ld after that\n", to_live, to_run);

  // ================================ its memory is the processor's
  {
    LwWrite(kProbeWord, kProbeRunKey);
    Check(LwRead(kProbeWord) == 0x50420001u, "the probe's word 48 reads %08x after RUN, wanting the marker and "
          "running", LwRead(kProbeWord));
    const uint32_t wa = kMainBase + 0x12340u;
    const uint64_t wd = 0x0123456789ABCDEFull;
    CoreWrite(wa, wd, 0x1F);
    Check(mem.machine_writes == 1, "the core's write reached the bridge %ld times with ID 0", mem.machine_writes);
    Check(mem.last_aw == wa && mem.last_data == wd && mem.last_strb == 0x1F,
          "the core's write reached the bridge at %08x with %016" PRIx64 " and strobes %02x, wanting %08x, %016" PRIx64
          " and 1f", mem.last_aw, mem.last_data, mem.last_strb, wa, wd);
    const uint32_t ra = kMainBase + 40u * 77u;
    uint64_t got[5] = {};
    const int n = CoreRead(ra, got);
    Check(n == 5, "the core's line fill brought %d beats of 5", n);
    Check(mem.machine_reads == 1 && mem.last_ar == ra && mem.last_ar_len == 4,
          "the core's fill reached the bridge %ld times with ID 0, at %08x for %d beats", mem.machine_reads,
          mem.last_ar, mem.last_ar_len + 1);
    for (int k = 0; k < n; ++k)
      Check(got[k] == mem.Beat(ra + 8u * k), "the fill's beat %d is %016" PRIx64 ", and the bridge's %016" PRIx64, k,
            got[k], mem.Beat(ra + 8u * k));
    Run(10);
    const uint32_t lo = HPS_I(hps_hps_gp_gp_in);
    HPS_O(hps_hps_gp_gp_out) = 3;
    Run(8);
    const uint32_t hi = HPS_I(hps_hps_gp_gp_in);
    HPS_O(hps_hps_gp_gp_out) = 1;
    Run(8);
    Check(lo == 0x00018001u && hi == 0x00018001u,
          "the tally reads %08x answered and %08x asked, wanting one read and one write in each", lo, hi);
    const long shown = Until([] { return mem.display_reads > 4; }, 20000);
    Check(shown >= 0, "the display read nothing with ID 2 once the port was live");
    Check(mem.display_off == 0, "%ld of the display's reads are outside the frame buffer", mem.display_off);
    Check(mem.other_ids == 0, "%ld transactions reached the bridge with an ID the board does not use", mem.other_ids);
    LwWrite(kProbeWord, kProbeStopKey);
    uint32_t pw[9];
    for (int k = 0; k < 9; ++k) pw[k] = LwRead(kProbeWord + 4u * k);
    Check(pw[0] == 0x50420000u, "the probe's word 48 reads %08x after STOP, wanting the marker alone", pw[0]);
    Check(pw[1] == 1 && pw[5] == 1, "the probe timed %u reads and %u writes, wanting one of each", pw[1], pw[5]);
    Check(pw[2] == pw[4] && pw[2] > 0 && pw[3] == 0, "the probe's read sum %08x:%08x and longest %u, wanting one "
          "read's", pw[3], pw[2], pw[4]);
    Check(pw[6] == pw[8] && pw[6] > 0 && pw[7] == 0, "the probe's write sum %08x:%08x and longest %u, wanting one "
          "write's", pw[7], pw[6], pw[8]);
    std::printf("ok: the core's write and line fill reach the bridge with ID 0 and come back; the tally reads "
                "%08x and %08x; the display reads with ID 2; the probe timed the read at %u clocks and the write "
                "at %u\n", lo, hi, pw[4], pw[8]);
  }

  // ================================ the console face's words, and the lamps
  {
    const uint32_t period = LwRead(kPeriodWord), units = LwRead(kMainWord);
    Check(period == 45, "the console's word 40 reads %u, and the period is 45 half-nanoseconds", period);
    Check(units == 0x42440200u, "the console's word 37 reads %08x, and main memory is \"BD\" and 512 units",
          units);
    LwWrite(kLampsWord, kLampSteadyKey);
    Run(10);
    const unsigned base = (1u << kClock) | (1u << kPort);
    Lamps(base, "the steady lamps, the core halted");
    CORE_O(obs_halted) = 0;
    Run(4);
    Lamps(base | (1u << kRun), "the core running");
    CORE_O(obs_halted) = 1;
    Run(4);
    Lamps(base, "the core halted again");
    CORE_O(obs_errhalt) = 1;
    Run(4);
    Lamps(base | (1u << kErrhalt), "an error halt");
    CORE_O(obs_errhalt) = 0;
    Run(4);
    Lamps(base, "the error halt gone");
    CORE_O(ch_active) = 1;
    Tick();
    CORE_O(ch_active) = 0;
    Run(4);
    Lamps(base | (1u << kDisk), "a block moved");
    CORE_O(obs_commit) = 0x8000;
    Tick();
    CORE_O(obs_commit) = 0;
    Run(4);
    Lamps(base | (1u << kDisk) | (1u << kCycle), "a microcycle retired");
    std::printf("ok: the console's words 40 and 37 read %u and %08x; each lamp lights on its own source\n", period,
                units);
  }

  // ================================ the console's RESET key
  {
    Check(!InReset(), "the core in reset before the console's RESET key");
    // The write is answered once the core has been through its reset, so
    // the reset is over when it returns.
    req_clocks = hard_clocks = 0;
    LwWrite(kResetWord, kResetKey);
    Check(req_clocks > 0, "the console's RESET key never asked for the core's reset");
    Check(hard_clocks == 0, "the console's RESET key gave the core its hard reset for %ld clocks", hard_clocks);
    Check(!InReset(), "the core still in reset when the console's RESET write was answered");
    std::printf("ok: the console's RESET key asked for the core's reset %ld clocks, answered after it\n",
                req_clocks);
  }

  // ================================ KEY0 and the switches do nothing
  {
    const unsigned lamps = LitSet();
    top->btn = 2;   // KEY0 pressed
    top->sw = 0xF;
    held = RstTicks(200);
    Check(held == 0, "KEY0 or the switches put the core into reset for %ld clocks", held);
    Check(LitSet() == lamps, "KEY0 or the switches moved the lamps from %02x to %02x", lamps, LitSet());
    top->btn = 3;
    top->sw = 0;
    Run(10);
  }

  // ================================ software shuts the port
  {
    HPS_O(hps_hps_gp_gp_out) = 0;
    const long dark = Until([] { return !Lit(kPort); }, 50);
    Check(dark >= 0 && dark <= 6, "LEDR6 went dark %ld clocks after software shut the port, wanting within 6",
          dark);
    held = RstTicks(400);
    Check(held == 0, "the core went into reset for %ld clocks with the port shut by software", held);
    HPS_O(hps_hps_gp_gp_out) = 1;
    Check(Until([] { return Lit(kPort); }, 50) >= 0, "LEDR6 did not light again when the port was opened");
    std::printf("ok: software shutting the port leaves the core running\n");
  }

  // ================================ the processor resets
  {
    HPS_O(hps_h2f_reset_reset) = 1;
    HPS_O(hps_hps_gp_gp_out) = 0;   // the processor's reset clears them
    hps_in_reset = true;
    // Three synchronizer stages and a register into the request, a register
    // for it, and the pending reset and the run register: within 12.
    const long rose = Until([] { return CORE_I(rst) != 0; }, 100);
    Check(rose >= 0 && rose <= 12, "the core had its hard reset %ld clocks after the processor's, wanting within 12",
          rose);
    held = RstTicks(300);
    Check(held == 300, "the core was out of reset %ld clocks of 300 in the processor's reset", 300 - held);
    Check(!Lit(kPort), "LEDR6 lit in the processor's reset");
    HPS_O(hps_h2f_reset_reset) = 0;
    hps_in_reset = false;
    const long fell = Until([] { return !InReset(); }, 100);
    Check(fell >= 0 && fell <= 12, "the core left reset %ld clocks after the processor's, wanting within 12", fell);
    Check(!Lit(kPort), "LEDR6 lit with the port not yet opened again");
    HPS_O(hps_hps_gp_gp_out) = 1;
    Check(Until([] { return Lit(kPort); }, 50) >= 0, "LEDR6 did not light when the port was opened again");
    std::printf("ok: the processor's reset reset the core within %ld clocks, and it ran %ld after\n", rose, fell);
  }

  // ================================ KEY1 and the clock's lock
  {
    top->btn = 1;   // KEY1 pressed
    const long rose = Until([] { return InReset(); }, 100);
    Check(rose >= 0 && rose <= 12, "the core went into reset %ld clocks after KEY1, wanting within 12", rose);
    long key_hard = 0;
    held = 0;
    for (int i = 0; i < 300; ++i) {
      Tick();
      if (InReset()) ++held;
      if (CORE_I(rst)) ++key_hard;
    }
    Check(held == 300, "the core was out of reset %ld clocks of 300 with KEY1 held", 300 - held);
    Check(key_hard == 0, "KEY1 gave the core its hard reset for %ld clocks, wanting the request alone", key_hard);
    Check(!Lit(kRun), "LEDR0 lit with KEY1 held");
    top->btn = 3;
    const long fell = Until([] { return !InReset(); }, 200);
    Check(fell >= 0 && fell <= 30, "the core left reset %ld clocks after KEY1, wanting within 30", fell);
    r->quux15_de25__DOT__u_pll__DOT__tbo_unlock = 1;
    const long rose2 = Until([] { return CORE_I(rst) != 0; }, 100);
    Check(rose2 >= 0 && rose2 <= 12, "the core had its hard reset %ld clocks after the lock was lost", rose2);
    Run(100);
    r->quux15_de25__DOT__u_pll__DOT__tbo_unlock = 0;
    const long fell2 = Until([] { return !InReset(); }, 200);
    Check(fell2 >= 0 && fell2 <= 30, "the core left reset %ld clocks after the lock came back", fell2);
    std::printf("ok: KEY1 and the clock's lock each reset the core, within %ld and %ld clocks, and let it go\n", rose,
                rose2);
  }

  // ================================ the video bus
  {
    // A line to settle after the resets above restarted the raster.
    Run(4000);
    video.hs_rise = -1;
    video.measure = true;
    video.pclk_pulses = 0;
    Run(1688L * 24);
    Check(video.hs_periods >= 20 && video.hs_bad_period == 0 && video.hs_bad_width == 0,
          "HSYNC: %ld periods, %ld not 1688 pixels, %ld not 112 wide", video.hs_periods, video.hs_bad_period,
          video.hs_bad_width);
    Check(video.de_lines >= 10 && video.de_bad_run == 0, "DE: %ld lines, %ld not 1280 pixels", video.de_lines,
          video.de_bad_run);
    Check(video.pclk_pulses > 1000, "the forwarded pixel clock ran %ld clocks", video.pclk_pulses);
    std::printf("ok: the video bus: %ld lines of 1688 pixels, HSYNC 112, DE 1280 on %ld lines\n", video.hs_periods,
                video.de_lines);
  }

  delete top;
  if (fails) {
    std::fprintf(stderr, "quux15_de25_top: FAILED, %d checks\n", fails);
    return 1;
  }
  std::printf("quux15_de25_top: ok\n");
  return 0;
}
