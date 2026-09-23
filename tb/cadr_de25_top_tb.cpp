// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The DE25-Nano's top level, simulated: `boards/de25-nano/cadr_de25.sv` built
// as the whole board (`CADR_DE25_DDR` and `CADR_DE25_HDMI`) around the shells
// in `tb/cadr_de25_sim_stubs.sv`, with this file as the processor, its
// memory, the ADV7513 on the two-wire bus, the buttons, the switch and a
// person reading the lamps and the video pins.
//
// WHY THIS EXISTS.  Every module under the top level has a check of its own,
// and until this file the top level itself had lint and a text check of its
// faces' addresses.  Lint holds that every port is connected and every signal
// read; it cannot tell a straight pair of wires from a crossed one of the
// same width, or a register taken on one edge from the other.  Measured: the
// open bit and the half bit of `h2f_gp_out` crossed, the memory port reset by
// the machine's reset, KEY0 and SW0 read the wrong way up, the two syncs
// crossed, red and blue crossed, the transmitter rewritten on sleep instead
// of wake, the clock gate on the rising edge and two lamps crossed all passed
// both.  This is what catches them.
//
// **EVERYTHING HERE IS HELD BY WHAT THE WIRE MEANS, NOT BY HOW THE FILE SAYS
// IT.**  The top level is read only through its pins and through the ports of
// the shells around it, which are the ports of the modules it instantiates:
// what the machine is given, what the processor is given, what reaches the
// lamps, the video bus and the two-wire bus.  A rewrite of the top level that
// kept the board's behavior passes; one that changed it fails.  THE ONE
// EXCEPTION is the enable of the gate on the forwarded pixel clock, read by
// name through `tb/cadr_de25_top.vlt`, and the reason is measured rather than
// assumed: in a simulation with no delays a gate enabled on the clock's rising
// edge and one enabled on its falling edge put out the same pulses, tick for
// tick, because the runt pulse the rising edge makes in the part is as wide
// as a flip-flop's clock-to-output delay and a zero-delay simulation has no
// such delay.  So the property is held where it lives: the enable moves only
// while the clock is low.  A top level that renames the net fails to build
// here, loudly, rather than passing unseen.
//
// WHAT IS HELD, IN THE ORDER IT RUNS.
//
//   THE MACHINE WAITS FOR ITS MEMORY.  With the processor in reset, and then
//   out of it with only the tally's select bit (`h2f_gp_out[1]`) written, the
//   machine is held in reset and LEDR6 is dark.  Written with the open bit
//   (`h2f_gp_out[0]`), the port is live within a handful of ticks, LEDR6
//   lights and the machine is let go.  The tally reads the marker in both
//   halves by the select bit.
//
//   ITS MEMORY IS THE PROCESSOR'S.  A word the machine writes reaches the
//   bridge at its own address in the right half of the beat, and a read
//   brings back what the bridge holds --- a word this file wrote into the
//   model, injective in the address.
//
//   A PROCESSOR RESET SHUTS THE PORT AND LEAVES THE MACHINE RUNNING, and so
//   does software clearing the open bit: LEDR6 goes dark within the
//   synchronizer's few ticks, and the machine's reset never rises.
//
//   THE LAMPS, ONE SOURCE AT A TIME, in the console's steady mode: MACHRUN,
//   PROMENABLE, ERRHALT (latched, and cleared by `-BOOT`), disk activity and
//   the microcycle, each lighting its own LED and no other, with LEDR1 lit
//   for the clock's lock, LEDR6 for the port and LEDR7 dark throughout.
//
//   KEY0 AND SW0 AT THE MACHINE: `-BOOT2` low while KEY0 is pressed (the key
//   reads low pressed) and high otherwise; the no-auto-boot level high with
//   SW0 on (up, which reads high) and low with it off.
//
//   THE VIDEO BUS: HSYNC once a line of 1688 pixels for 112 of them, VSYNC
//   once a frame of 1066 lines for three of them, both positive, DE on 1280
//   pixels of 1024 lines --- VESA DMT's 1280x1024 at 60 Hz --- the first
//   display's lit pixels white, and the color board's pixels the color map's
//   entry with red in the top byte, green in the middle and blue at the
//   bottom, which is what the ADV7513's `0x16` setting says the bus is.
//
//   THE TRANSMITTER'S PROGRAM, counted on the wires: once out of the fabric's
//   reset, not at all when the display goes to sleep, and once more when it
//   wakes.  While asleep the forwarded pixel clock is stopped, and awake it
//   runs; and the enable of its gate moves only while the clock is low.
//
//   KEY1 AND THE CLOCK'S LOCK: either puts the machine into reset, and once
//   it is over the machine is let go again, the port being open already.
//
// The ticks allowed for each wire to answer are the synchronizers' own depth
// plus the register behind them, written beside each check.

#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>

#include "Vcadr_de25.h"
#include "Vcadr_de25___024root.h"
#include "verilated.h"

namespace {

Vcadr_de25 *top = nullptr;
Vcadr_de25___024root *r = nullptr;
long t = 0;
int fails = 0;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  if (fails > 30) return;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: tick %ld: ", t);
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

// The shells' registers, by the names `tb/cadr_de25_sim_stubs.sv` gives them.
#define HPS_O(n) (r->cadr_de25__DOT__u_hps__DOT__tbo_##n)
#define HPS_I(n) (r->cadr_de25__DOT__u_hps__DOT__tbi_##n)
#define MACH_O(n) (r->cadr_de25__DOT__u_machine__DOT__tbo_##n)
#define MACH_I(n) (r->cadr_de25__DOT__u_machine__DOT__tbi_##n)

// The board's memory, at the processor's addresses: the machine's reserved
// 128 MB at `0xB000_0000`, `cadr_ddr_map::MAIN_BASE` with the DE25-Nano's map.
constexpr uint32_t kMainBase = 0xB0000000u;
uint32_t Poison(uint32_t addr) { return 0x5EED0000u ^ (addr * 0x9E3779B1u); }

// What the lamps are, lit LOW, by LED.
constexpr int kMachrun = 0, kClock = 1, kCycle = 2, kDisk = 3, kErrhalt = 4,
              kPromenable = 5, kPort = 6;
bool Lit(int i) { return ((top->led >> i) & 1) == 0; }
unsigned LitSet() { return (~top->led) & 0xFFu; }

// ------------------------------------------------------------ the memory
//
// The FPGA-to-SDRAM bridge as a memory: an AXI4 slave at 64 bits that takes
// every address at once, answers reads in order after a fixed latency and
// writes after the last beat.  Keyed by the address the BRIDGE was given.
struct Memory {
  std::map<uint32_t, uint32_t> words;
  struct Rd { int id; uint32_t addr; int beats; int sent; long due; };
  std::deque<Rd> reads;
  struct Wr { int id; uint32_t addr; int beats; int got; bool done; long at; };
  std::deque<Wr> writes;
  bool ar_hs = false, aw_hs = false, w_hs = false, r_hs = false, b_hs = false;
  uint32_t ar_addr = 0, aw_addr = 0;
  int ar_id = 0, aw_id = 0, ar_len = 0, aw_len = 0;
  uint64_t w_data = 0;
  uint32_t w_strb = 0;
  // What the machine's port put on the bridge, for the memory checks.
  long machine_writes = 0;
  uint32_t last_write_addr = 0, last_write_strb = 0;
  uint64_t last_write_data = 0;
  long display_reads = 0;

  uint32_t Word(uint32_t a) {
    auto it = words.find(a);
    return it == words.end() ? Poison(a) : it->second;
  }
  uint64_t Beat(uint32_t a) {
    return (static_cast<uint64_t>(Word(a + 4)) << 32) | Word(a);
  }

  void Reset() {
    reads.clear();
    writes.clear();
    HPS_O(hps_f2sdram_rvalid) = 0;
    HPS_O(hps_f2sdram_bvalid) = 0;
  }

  // Before the edge: readies and the head of each answer.
  void Drive(bool in_reset) {
    HPS_O(hps_f2sdram_arready) = in_reset ? 0 : 1;
    HPS_O(hps_f2sdram_awready) = in_reset ? 0 : 1;
    HPS_O(hps_f2sdram_wready) = in_reset ? 0 : 1;
    HPS_O(hps_f2sdram_rvalid) = 0;
    HPS_O(hps_f2sdram_bvalid) = 0;
    if (in_reset) return;
    if (!reads.empty() && t >= reads.front().due) {
      const Rd &rd = reads.front();
      const uint32_t a = rd.addr + 8u * static_cast<uint32_t>(rd.sent);
      HPS_O(hps_f2sdram_rvalid) = 1;
      HPS_O(hps_f2sdram_rid) = static_cast<uint8_t>(rd.id);
      HPS_O(hps_f2sdram_rdata) = Beat(a);
      HPS_O(hps_f2sdram_rresp) = 0;
      HPS_O(hps_f2sdram_rlast) = (rd.sent + 1 == rd.beats) ? 1 : 0;
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
      if (ar_id == 2) ++display_reads;
    }
    if (aw_hs) writes.push_back({aw_id, aw_addr, aw_len + 1, 0, false, 0});
    if (w_hs) {
      Wr *open = nullptr;
      for (auto &w : writes) {
        if (!w.done) { open = &w; break; }
      }
      Check(open != nullptr, "a write beat reached the bridge with no address");
      if (open) {
        const uint32_t a = open->addr + 8u * static_cast<uint32_t>(open->got);
        for (int half = 0; half < 2; ++half) {
          if (((w_strb >> (4 * half)) & 0xFu) == 0xFu)
            words[a + 4u * half] = static_cast<uint32_t>(w_data >> (32 * half));
        }
        if (open->id == 0) {
          ++machine_writes;
          last_write_addr = a;
          last_write_strb = w_strb;
          last_write_data = w_data;
        }
        if (++open->got == open->beats) { open->done = true; open->at = t; }
      }
    }
    if (r_hs) {
      Rd &rd = reads.front();
      if (++rd.sent == rd.beats) reads.pop_front();
    }
    if (b_hs) writes.pop_front();
  }
};

// ------------------------------------------- the lightweight bridge's master
//
// Software on the processor, writing one word at a time: the console's
// settings are how the lamps, the display's output and its sleep are asked
// for, exactly as `cadr-console` asks for them.
struct LwMaster {
  bool aw = false, w = false, b = false;
  bool aw_hs = false, w_hs = false, b_hs = false;
  void Start(uint32_t addr, uint32_t data, uint32_t strb) {
    HPS_O(hps_lwhps2fpga_awaddr) = addr;
    HPS_O(hps_lwhps2fpga_awid) = 1;
    HPS_O(hps_lwhps2fpga_awlen) = 0;
    HPS_O(hps_lwhps2fpga_awsize) = 2;
    HPS_O(hps_lwhps2fpga_awburst) = 1;
    HPS_O(hps_lwhps2fpga_wdata) = data;
    HPS_O(hps_lwhps2fpga_wstrb) = strb;
    HPS_O(hps_lwhps2fpga_wlast) = 1;
    aw = w = true;
    b = false;
  }
  void Drive() {
    HPS_O(hps_lwhps2fpga_awvalid) = aw ? 1 : 0;
    HPS_O(hps_lwhps2fpga_wvalid) = w ? 1 : 0;
    HPS_O(hps_lwhps2fpga_bready) = 1;
    HPS_O(hps_lwhps2fpga_rready) = 1;
    HPS_O(hps_lwhps2fpga_arvalid) = 0;
  }
  void Sample() {
    aw_hs = aw && HPS_I(hps_lwhps2fpga_awready);
    w_hs = w && HPS_I(hps_lwhps2fpga_wready);
    b_hs = HPS_I(hps_lwhps2fpga_bvalid);
  }
  void Commit() {
    if (aw_hs) aw = false;
    if (w_hs) w = false;
    if (b_hs) b = true;
  }
};

// ----------------------------------------------------- the two-wire bus
//
// The ADV7513 as far as the bus goes: it acknowledges every byte, putting its
// acknowledge up well after the falling edge and taking it down well after
// the next, as `tb/cadr_adv7513_tb.cpp`'s part does and for its reason.  And
// an analyzer that counts starts, bytes and stops off the two lines, which is
// all this file needs: how many writes the program made and when.
struct TwoWire {
  bool sda_low = false;
  bool live = false;
  int bitcnt = 0;
  long ack_in = -1, release_in = -1;
  bool prev_scl = true, prev_sda = true;
  long starts = 0, stops = 0, bytes = 0, nacks = 0;
  int nbits = 0;

  // `m_scl` and `m_sda` are the lines as the fabric alone would leave them.
  void Step(bool m_scl, bool m_sda, bool *scl_out, bool *sda_out) {
    const bool scl = m_scl;
    const bool sda_now = m_sda && !sda_low;
    if (prev_scl && scl && sda_now != prev_sda) {
      if (!sda_now) { live = true; bitcnt = 0; ++starts; nbits = 0; }
      else {
        live = false; bitcnt = 0; sda_low = false; ack_in = release_in = -1;
        ++stops;
      }
    }
    const bool rise = scl && !prev_scl;
    const bool fall = !scl && prev_scl;
    if (rise && live) {
      ++bitcnt;
      if (bitcnt == 8) ++bytes;
      if (bitcnt == 9 && sda_now) ++nacks;
    }
    if (fall && live) {
      if (bitcnt == 8) ack_in = 300;
      else if (bitcnt == 9) { release_in = 200; bitcnt = 0; }
    }
    if (ack_in > 0) --ack_in;
    else if (ack_in == 0) { sda_low = true; ack_in = -1; }
    if (release_in > 0) --release_in;
    else if (release_in == 0) { sda_low = false; release_in = -1; }
    const bool sda = m_sda && !sda_low;
    prev_scl = scl;
    prev_sda = sda;
    *scl_out = scl;
    *sda_out = sda;
  }
};

// ------------------------------------------------------ the video pins
struct Video {
  bool prev_hs = false, prev_vs = false, prev_de = false;
  long hs_rise = -1, vs_rise = -1, hs_high = 0, vs_high = 0;
  long hs_periods = 0, hs_bad_period = 0, hs_bad_width = 0;
  long vs_periods = 0, vs_bad_period = 0, vs_bad_width = 0;
  long hs_first_period = -1, vs_first_period = -1;
  long hs_first_width = -1, vs_first_width = -1;
  long de_run = 0, de_lines = 0, de_bad_run = 0, de_lines_in_frame = 0;
  long frames = 0, frames_bad_lines = 0;
  long pclk_pulses = 0;
  // pixels while DE, by what they are
  long black = 0, white = 0, want_color = 0, other = 0;
  uint32_t color = 0, first_other = 0;
  bool measure = false;

  void Clear() {
    hs_periods = hs_bad_period = hs_bad_width = 0;
    vs_periods = vs_bad_period = vs_bad_width = 0;
    hs_first_period = vs_first_period = hs_first_width = vs_first_width = -1;
    de_lines = de_bad_run = 0;
    frames = frames_bad_lines = 0;
    pclk_pulses = 0;
    black = white = want_color = other = 0;
    first_other = 0;
  }

  // After each rising edge of the pixel clock, which in this simulation is
  // the machine's clock: the bus is registered on it.
  void Step() {
    const bool hs = top->hdmi_hsync, vs = top->hdmi_vsync, de = top->hdmi_de;
    if (top->hdmi_pclk) ++pclk_pulses;
    if (hs) ++hs_high;
    if (vs) ++vs_high;
    if (hs && !prev_hs) {
      if (hs_rise >= 0 && measure) {
        const long p = t - hs_rise;
        if (hs_first_period < 0) hs_first_period = p;
        ++hs_periods;
        if (p != 1688) ++hs_bad_period;
      }
      hs_rise = t;
      hs_high = 1;
    }
    if (!hs && prev_hs && measure) {
      if (hs_first_width < 0) hs_first_width = hs_high;
      if (hs_high != 112) ++hs_bad_width;
    }
    if (vs && !prev_vs) {
      if (vs_rise >= 0 && measure) {
        const long p = t - vs_rise;
        if (vs_first_period < 0) vs_first_period = p;
        ++vs_periods;
        if (p != 1688L * 1066L) ++vs_bad_period;
        ++frames;
        if (de_lines_in_frame != 1024) ++frames_bad_lines;
      }
      vs_rise = t;
      vs_high = 1;
      de_lines_in_frame = 0;
    }
    if (!vs && prev_vs && measure) {
      if (vs_first_width < 0) vs_first_width = vs_high;
      if (vs_high != 3L * 1688L) ++vs_bad_width;
    }
    if (de) {
      ++de_run;
      if (measure) {
        const uint32_t px = top->hdmi_d & 0xFFFFFFu;
        if (px == 0) ++black;
        else if (px == 0xFFFFFFu) ++white;
        else if (px == color) ++want_color;
        else { if (!other) first_other = px; ++other; }
      }
    }
    if (!de && prev_de) {
      if (measure) {
        ++de_lines;
        if (de_run != 1280) ++de_bad_run;
      }
      ++de_lines_in_frame;
      de_run = 0;
    }
    prev_hs = hs; prev_vs = vs; prev_de = de;
  }
};

Memory mem;
LwMaster lw;
TwoWire bus;
Video video;
bool hps_in_reset = true;
// The gate's enable, read by name: see the header.
long gate_moves = 0, gate_moves_high = 0;

void Tick() {
  // The falling edge: the gate's enable may move here and only here.
  top->clock50_0 = 0;
  const uint8_t on_before_fall = r->cadr_de25__DOT__pclk_on;
  top->eval();
  if (r->cadr_de25__DOT__pclk_on != on_before_fall) ++gate_moves;

  // Before the rising edge: the models put up what they drive.
  mem.Drive(hps_in_reset);
  lw.Drive();
  top->eval();
  mem.Sample();
  lw.Sample();

  // The rising edge.
  const uint8_t on_before_rise = r->cadr_de25__DOT__pclk_on;
  top->clock50_0 = 1;
  top->eval();
  if (r->cadr_de25__DOT__pclk_on != on_before_rise) {
    ++gate_moves;
    ++gate_moves_high;
  }
  mem.Commit();
  lw.Commit();
  if (hps_in_reset) mem.Reset();

  // The two-wire bus, open drain: a line is low if anybody pulls it.
  const bool m_scl = !(top->hdmi_scl__en && !top->hdmi_scl__out);
  const bool m_sda = !(top->hdmi_sda__en && !top->hdmi_sda__out);
  bool scl, sda;
  bus.Step(m_scl, m_sda, &scl, &sda);
  top->hdmi_scl = scl ? 1 : 0;
  top->hdmi_sda = sda ? 1 : 0;

  video.Step();
  ++t;
}

void Run(long n) {
  for (long i = 0; i < n; ++i) Tick();
}

// Ticks until `cond` holds, at most `limit`; -1 if it never did.
template <typename F>
long Until(F cond, long limit) {
  for (long i = 0; i <= limit; ++i) {
    if (cond()) return i;
    Tick();
  }
  return -1;
}

void LwWrite(uint32_t addr, uint32_t data, uint32_t strb = 0xFu) {
  lw.Start(addr, data, strb);
  const long took = Until([] { return lw.b; }, 2000);
  Check(took >= 0, "the console did not answer a write of %08x at %03x", data,
        addr);
  Run(4);
}

// The console's page 2, on the lightweight bridge at offset 0: word 34 says
// what the display output shows, 35 whether the lamps blink, 36 its sleep.
constexpr uint32_t kHdmiWord = 0x88, kLampsWord = 0x8C, kSleepWord = 0x90;
constexpr uint32_t kHdmiTvKey = 0x48545631u, kHdmiColorKey = 0x48545632u;
constexpr uint32_t kLampSteadyKey = 0x53544459u;
constexpr uint32_t kSleepKey = 0x48530000u, kWakeKey = 0x57414B45u;

// One word through the machine's own port.
uint32_t MachineCycle(bool write, uint32_t addr, uint32_t data) {
  MACH_O(mem_req) = 1;
  MACH_O(mem_write) = write ? 1 : 0;
  MACH_O(mem_addr) = addr;
  MACH_O(mem_wdata) = data;
  const long took = Until([] { return MACH_I(mem_done) != 0; }, 2000);
  Check(took >= 0, "the machine's %s of %08x was never answered",
        write ? "write" : "read", addr);
  const uint32_t got = MACH_I(mem_rdata);
  MACH_O(mem_req) = 0;
  Until([] { return MACH_I(mem_done) == 0; }, 100);
  Run(2);
  return got;
}

// The lamps the board should show, as a set, against the pins.
void Lamps(unsigned want, const char *after) {
  Check(LitSet() == want,
        "after %s the lit LEDs are %02x, wanting %02x", after, LitSet(), want);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vcadr_de25;
  r = top->rootp;

  // THE BOARD AT POWER-ON.  The device still initializing, both keys up, the
  // switches down, the processor in reset with nothing written, the machine's
  // outputs all quiet and `-BOOT` up.  The color map's every entry is one
  // color with three different channels, so a crossed pair of channels is a
  // different color.
  constexpr uint32_t kMapColor = 0x102030u;
  video.color = kMapColor;
  r->cadr_de25__DOT__u_reset_release__DOT__tbo_ninit_done = 1;
  r->cadr_de25__DOT__u_pll__DOT__tbo_unlock = 0;
  top->btn = 3;
  top->sw = 0;
  top->hdmi_scl = 1;
  top->hdmi_sda = 1;
  HPS_O(hps_h2f_reset_reset) = 1;
  HPS_O(hps_hps_gp_gp_out) = 0;
  // The warm-reset handshake's request is LOW when asserted.
  HPS_O(hps_h2f_warm_reset_handshake_reset_req) = 1;
  MACH_O(n_boot_o) = 1;
  MACH_O(disp_color_map_q) = kMapColor;
  top->eval();

  Run(10);
  r->cadr_de25__DOT__u_reset_release__DOT__tbo_ninit_done = 0;

  // ================================= the machine waits for its memory
  long held = 0;
  for (int i = 0; i < 200; ++i) {
    Tick();
    if (MACH_I(rst)) ++held;
  }
  Check(held == 200, "the machine was out of reset %ld ticks of 200 with the "
        "processor still in reset", 200 - held);
  hps_in_reset = false;
  HPS_O(hps_h2f_reset_reset) = 0;
  // Only the tally's select bit: it must not open the port.
  HPS_O(hps_hps_gp_gp_out) = 2;
  held = 0;
  long lit6 = 0;
  for (int i = 0; i < 400; ++i) {
    Tick();
    if (MACH_I(rst)) ++held;
    if (Lit(kPort)) ++lit6;
  }
  Check(held == 400, "with only h2f_gp_out[1] written the machine was out of "
        "reset %ld ticks of 400, and bit 1 is the tally's select, not the open",
        400 - held);
  Check(lit6 == 0, "with only h2f_gp_out[1] written LEDR6 was lit %ld ticks",
        lit6);
  const uint32_t tally_high = HPS_I(hps_hps_gp_gp_in);
  // The open bit, and the tally's select back to the answered half.
  HPS_O(hps_hps_gp_gp_out) = 1;
  // Three synchronizer stages and the register behind them for the port; one
  // more for the latch and one for the machine's reset register.
  const long to_live = Until([] { return Lit(kPort); }, 50);
  const long to_run = Until([] { return MACH_I(rst) == 0; }, 50);
  Check(to_live >= 0 && to_live <= 6,
        "LEDR6 lit %ld ticks after h2f_gp_out[0], wanting within 6", to_live);
  Check(to_run >= 0 && to_run <= 4,
        "the machine left reset %ld ticks after the port was live, wanting "
        "within 4", to_run);
  Run(8);
  const uint32_t tally_low = HPS_I(hps_hps_gp_gp_in);
  Check((tally_low & 0x80008000u) == 0x8000u && (tally_high & 0x80008000u) == 0x8000u,
        "h2f_gp_in reads %08x and %08x by the select bit, and each half "
        "carries the marker", tally_low, tally_high);

  // ================================ its memory is the processor's
  const uint32_t kWordA = kMainBase + 0x1004u;   // the upper half of a beat
  const uint32_t kWordB = kMainBase + 0x2000u;   // the lower half of one
  MachineCycle(true, kWordA, 0xCAFEF00Du);
  Check(mem.machine_writes == 1 && mem.last_write_addr == (kWordA & ~7u) &&
            mem.last_write_strb == 0xF0u &&
            static_cast<uint32_t>(mem.last_write_data >> 32) == 0xCAFEF00Du,
        "the machine's write of %08x at %08x reached the bridge as %08x at "
        "%08x with strobes %02x", 0xCAFEF00Du, kWordA,
        static_cast<uint32_t>(mem.last_write_data >> 32), mem.last_write_addr,
        mem.last_write_strb);
  const uint32_t back = MachineCycle(false, kWordA, 0);
  Check(back == 0xCAFEF00Du, "the machine read %08x back from %08x, wanting "
        "the %08x it wrote", back, kWordA, 0xCAFEF00Du);
  const uint32_t other = MachineCycle(false, kWordB, 0);
  Check(other == Poison(kWordB), "the machine read %08x from %08x, and the "
        "memory holds %08x there", other, kWordB, Poison(kWordB));

  // ===================== a processor reset leaves the machine running
  HPS_O(hps_h2f_reset_reset) = 1;
  hps_in_reset = true;
  long rst_seen = 0;
  long dark_at = -1;
  for (int i = 0; i < 100; ++i) {
    Tick();
    if (MACH_I(rst)) ++rst_seen;
    if (dark_at < 0 && !Lit(kPort)) dark_at = i + 1;
  }
  Check(dark_at >= 0 && dark_at <= 6,
        "LEDR6 went dark %ld ticks into the processor's reset, wanting within "
        "6: the port must shut when the processor resets", dark_at);
  HPS_O(hps_h2f_reset_reset) = 0;
  hps_in_reset = false;
  const long relit = Until([] { return Lit(kPort); }, 50);
  Check(relit >= 0, "the port did not come back after the processor's reset");
  for (int i = 0; i < 20; ++i) { Tick(); if (MACH_I(rst)) ++rst_seen; }
  // And software clearing the open bit.
  HPS_O(hps_hps_gp_gp_out) = 0;
  dark_at = -1;
  for (int i = 0; i < 100; ++i) {
    Tick();
    if (MACH_I(rst)) ++rst_seen;
    if (dark_at < 0 && !Lit(kPort)) dark_at = i + 1;
  }
  Check(dark_at >= 0 && dark_at <= 6,
        "LEDR6 went dark %ld ticks after h2f_gp_out[0] was cleared, wanting "
        "within 6", dark_at);
  HPS_O(hps_hps_gp_gp_out) = 1;
  Until([] { return Lit(kPort); }, 50);
  for (int i = 0; i < 20; ++i) { Tick(); if (MACH_I(rst)) ++rst_seen; }
  Check(rst_seen == 0,
        "the machine was in reset %ld ticks while the port was shut under it, "
        "and a running machine is not reset by its memory going away",
        rst_seen);

  // ============================================ the lamps, one at a time
  LwWrite(kLampsWord, kLampSteadyKey);
  Run(4);
  const unsigned base = (1u << kClock) | (1u << kPort);
  Lamps(base, "the lamps were made steady");
  MACH_O(machrun) = 1; Run(3); Lamps(base | 1u << kMachrun, "MACHRUN rose");
  MACH_O(machrun) = 0; Run(3); Lamps(base, "MACHRUN fell");
  MACH_O(promenable) = 1; Run(3); Lamps(base | 1u << kPromenable, "PROMENABLE rose");
  MACH_O(promenable) = 0; Run(3); Lamps(base, "PROMENABLE fell");
  MACH_O(errhalt) = 1; Run(3); Lamps(base | 1u << kErrhalt, "ERRHALT rose");
  MACH_O(errhalt) = 0; Run(3); Lamps(base | 1u << kErrhalt, "ERRHALT fell, which it latches");
  MACH_O(n_boot_o) = 0; Run(3); MACH_O(n_boot_o) = 1; Run(3);
  Lamps(base, "-BOOT cleared the ERRHALT lamp");
  MACH_O(ch_active) = 1; Run(1); MACH_O(ch_active) = 0; Run(3);
  Lamps(base | 1u << kDisk, "a disk transfer");
  MACH_O(clock_edge) = 1; Run(1); MACH_O(clock_edge) = 0; Run(3);
  Lamps(base | 1u << kDisk | 1u << kCycle, "a microcycle");

  // ======================================== KEY0 and SW0 at the machine
  Check(MACH_I(n_boot2) == 1, "-BOOT2 is %d with KEY0 up", MACH_I(n_boot2));
  top->btn = 2;   // KEY0 pressed, which reads low
  const long boot_down = Until([] { return MACH_I(n_boot2) == 0; }, 10);
  Check(boot_down >= 0 && boot_down <= 3,
        "-BOOT2 fell %ld ticks after KEY0 was pressed, wanting within 3",
        boot_down);
  top->btn = 3;
  const long boot_up = Until([] { return MACH_I(n_boot2) == 1; }, 10);
  Check(boot_up >= 0 && boot_up <= 3,
        "-BOOT2 rose %ld ticks after KEY0 was let go, wanting within 3",
        boot_up);
  Check(MACH_I(no_auto_boot) == 0, "no-auto-boot is %d with SW0 off",
        MACH_I(no_auto_boot));
  top->sw = 1;    // SW0 on, which reads high
  const long nab_on = Until([] { return MACH_I(no_auto_boot) == 1; }, 10);
  Check(nab_on >= 0 && nab_on <= 4,
        "no-auto-boot rose %ld ticks after SW0 was put on, wanting within 4",
        nab_on);
  top->sw = 0;
  const long nab_off = Until([] { return MACH_I(no_auto_boot) == 0; }, 10);
  Check(nab_off >= 0 && nab_off <= 4,
        "no-auto-boot fell %ld ticks after SW0 was put off, wanting within 4",
        nab_off);

  // ================================================== the video bus
  //
  // The transmitter's program has been running since the fabric's reset;
  // let it finish, then take two whole frames of the first display.
  const long prog = Until([] { return bus.stops >= 33; }, 3000000);
  Check(prog >= 0, "the transmitter's program did not finish: %ld writes",
        bus.stops);
  Check(bus.starts == 33 && bus.bytes == 99 && bus.nacks == 0,
        "the program out of reset was %ld writes of %ld bytes with %ld "
        "refused, wanting 33, 99 and none", bus.starts, bus.bytes, bus.nacks);
  const long first_program = bus.starts;
  Until([] { return top->hdmi_vsync != 0; }, 2000000);
  Run(1688L * 1066L);           // one frame for the fill to settle
  video.Clear();
  video.measure = true;
  Run(2L * 1688L * 1066L + 10);
  video.measure = false;
  Check(video.hs_periods > 2000 && video.hs_bad_period == 0 &&
            video.hs_bad_width == 0,
        "HSYNC: %ld periods, %ld not 1688 pixels (the first %ld), %ld pulses "
        "not 112 wide (the first %ld)", video.hs_periods, video.hs_bad_period,
        video.hs_first_period, video.hs_bad_width, video.hs_first_width);
  Check(video.vs_periods >= 1 && video.vs_bad_period == 0 &&
            video.vs_bad_width == 0,
        "VSYNC: %ld periods, %ld not a frame of 1066 lines (the first %ld), %ld "
        "pulses not three lines wide (the first %ld)", video.vs_periods,
        video.vs_bad_period, video.vs_first_period, video.vs_bad_width,
        video.vs_first_width);
  Check(video.de_lines > 2000 && video.de_bad_run == 0 &&
            video.frames_bad_lines == 0,
        "DE: %ld lines, %ld not 1280 pixels long, %ld frames not 1024 lines",
        video.de_lines, video.de_bad_run, video.frames_bad_lines);
  Check(video.white > 10000 && video.want_color == 0 && video.other == 0,
        "the first display: %ld white pixels, %ld of the map's color and %ld "
        "of anything else (the first %06x), and a lit pixel is white",
        video.white, video.want_color, video.other, video.first_other);
  const long first_white = video.white;

  // The color board alone.
  LwWrite(kHdmiWord, kHdmiColorKey);
  Run(3L * 1688L * 1066L);
  video.Clear();
  video.measure = true;
  Run(1688L * 1066L + 10);
  video.measure = false;
  Check(video.want_color > 576L * 454L / 2 && video.other == 0 &&
            video.white == 0,
        "the color board: %ld pixels of the map's %06x, %ld white and %ld of "
        "anything else (the first %06x): red is the top byte of the bus and "
        "blue the bottom", video.want_color, kMapColor, video.white,
        video.other, video.first_other);
  const long color_pixels = video.want_color;

  // ================================================ sleep, and the wake
  //
  // A setting of one second, the least there is.  The display sleeps at the
  // first frame boundary after it, stops the forwarded clock, and the
  // transmitter is NOT written; a wake starts the clock at the next boundary
  // and writes the whole program again.
  const long moves_before = gate_moves;
  LwWrite(kSleepWord, kSleepKey | 1u);
  const long starts_at_sleep = bus.starts;
  // A second of the fabric's clock and two frames.
  Run(100000000L + 2L * 1688L * 1066L);
  video.Clear();
  Run(1688L * 1066L);
  Check(video.pclk_pulses == 0,
        "asleep, the forwarded pixel clock still pulsed %ld times in a frame",
        video.pclk_pulses);
  Check(bus.starts == starts_at_sleep,
        "the transmitter was written %ld times as the display went to sleep, "
        "and it is written out of reset and at a wake, never at a sleep",
        bus.starts - starts_at_sleep);
  LwWrite(kSleepWord, kWakeKey);
  Run(2L * 1688L * 1066L);
  video.Clear();
  Run(1688L * 1066L);
  Check(video.pclk_pulses == 1688L * 1066L,
        "awake, the forwarded pixel clock pulsed %ld times in a frame of %ld",
        video.pclk_pulses, 1688L * 1066L);
  const long rewrite = Until([&] { return bus.stops >= starts_at_sleep + 33; },
                             3000000);
  Check(rewrite >= 0 && bus.starts == starts_at_sleep + 33 && bus.nacks == 0,
        "at the wake the transmitter was written %ld times, wanting the whole "
        "program of 33", bus.starts - starts_at_sleep);
  Check(gate_moves - moves_before >= 2,
        "the gate's enable moved %ld times across a sleep and a wake, so the "
        "edge it moves on was not seen", gate_moves - moves_before);
  Check(gate_moves_high == 0,
        "the gate's enable moved %ld times on the rising edge of the pixel "
        "clock, while the forwarded clock was high: a runt pulse to the part",
        gate_moves_high);

  // ================================================ KEY1 and the lock
  top->btn = 1;   // KEY1 pressed, which reads low
  const long key1 = Until([] { return MACH_I(rst) != 0; }, 20);
  Check(key1 >= 0 && key1 <= 7,
        "the machine went into reset %ld ticks after KEY1 was pressed, wanting "
        "within 7", key1);
  Run(20);
  top->btn = 3;
  const long key1_run = Until([] { return MACH_I(rst) == 0; }, 100);
  Check(key1_run >= 0, "the machine was not let go after KEY1");
  r->cadr_de25__DOT__u_pll__DOT__tbo_unlock = 1;
  const long unlock = Until([] { return MACH_I(rst) != 0; }, 20);
  Check(unlock >= 0 && unlock <= 7,
        "the machine went into reset %ld ticks after the PLL lost lock, "
        "wanting within 7", unlock);
  r->cadr_de25__DOT__u_pll__DOT__tbo_unlock = 0;
  const long relock_run = Until([] { return MACH_I(rst) == 0; }, 100);
  Check(relock_run >= 0, "the machine was not let go after the PLL locked");

  top->final();
  delete top;

  if (fails) {
    std::fprintf(stderr, "\n%d failure%s\n", fails, fails == 1 ? "" : "s");
    return 1;
  }
  std::printf(
      "ok: the DE25-Nano's top level, simulated around its processor.\n"
      "    the machine held in reset until h2f_gp_out[0] opened the port, LEDR6\n"
      "      lit %ld ticks after it and the machine let go %ld after that;\n"
      "      bit 1 alone opened nothing; the tally's two halves marked.\n"
      "    the machine's write and two reads through the bridge, each at its\n"
      "      own address and half; a processor reset and the open bit cleared\n"
      "      each shut the port with the machine left running.\n"
      "    the lamps one source at a time; KEY0, SW0, KEY1 and the lock.\n"
      "    HSYNC every 1688 pixels for 112, VSYNC every 1066 lines for 3, DE on\n"
      "      1280 of 1024; %ld white pixels of the first display and %ld of\n"
      "      the color board's %06x.\n"
      "    the transmitter written %ld times out of reset, none at the sleep,\n"
      "      33 at the wake; the clock stopped asleep, and its gate moved\n"
      "      %ld times, never on the rising edge.\n",
      to_live, to_run, first_white, color_pixels, kMapColor, first_program,
      gate_moves);
  return 0;
}
