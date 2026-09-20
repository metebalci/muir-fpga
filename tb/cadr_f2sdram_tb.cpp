// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine behind the DE25-Nano's memory: `cadr_machine` through
// `rtl/plumbing/cadr_f2sdram_port.sv` against a model of the Agilex 5's
// FPGA-to-SDRAM bridge, running MIT's boot PROM from reset.
//
// WHY THIS EXISTS AND WHAT IT IS HELD TO.  It is `tb/cadr_ddr_boot_tb.cpp`'s
// question on the other vendor's part --- does the machine's memory traffic
// reach real memory and come back unchanged --- and `tb/cadr_mem_count_tb.cpp`'s
// and `tb/cadr_memory_path_tb.cpp`'s configuration B besides: what the tally
// reads, and what another master on the same port costs a machine cycle.
// muir has no column for a word in memory and none for an AXI port, so what
// muir backs here is what it backs there: `promh.text`'s PAGE-0-PARITY-FIX
// reads each of the 256 words of page 0 and writes the same word straight
// back, 512 bus cycles and no others, and `build/machine.pass` holds those
// same cycles to muir microcycle for microcycle.  What this adds is the
// bridge: real beats, its own rules, its own delays, and the arbiter in
// front of it.
//
// THE POISON IS THE STIMULUS'S AND THE MEMORY IS THE MODEL'S.  An identity
// copy against zeroed memory tests nothing, so the region is poisoned from
// outside, injectively in the address, and the model memory is keyed by the
// address the BRIDGE was given and never by anything the fabric says it
// meant.  A bridge that dropped an address bit writes somewhere this program
// names, and the word that should have been there is missing.
//
// THE BRIDGE'S RULES, ASSERTED ON EVERY TRANSACTION.  The Agilex 5 HPS
// Technical Reference Manual (document 814346), section 11.8.3.1, tables 336
// and 337: the beat is the full bus width, the burst is INCR or WRAP, AxUSER
// is `0xE0`, AxCACHE is `0b0010`, and the ID is five bits.  With them, the
// rules of AXI itself that a shared port can break: a valid that moves before
// its ready, a payload that changes under a valid, a beat without its
// address, a response to a transaction nobody made, write data out of the
// order of the write addresses.  `rtl/plumbing/cadr_f2sdram_share.sv`'s header
// says where each rule comes from.
//
// THE FIVE CONFIGURATIONS.
//
//   OPEN     software has opened the port on `h2f_gp_out[0]`.  The machine
//            runs the parity loop: 512 transactions, 256 reads and 256
//            writes, each at its own address, each write carrying the word
//            its own read returned, the region its poison again afterwards,
//            and the tally reading 256 and 256 asked and answered.
//
//   SHUT     the port never opened, which is a board on which nobody has run
//            `bridge enable` or written the general-purpose register.  The
//            machine still asks 512 times and NOTHING reaches the bridge:
//            not an address, not a beat.  The tally must read the same 256
//            and 256 asked, and nothing answered --- the reading the whole
//            instrument exists to make possible, and the one a counter of
//            the fabric's own intentions cannot produce.
//
//   QUIET    the port open, the other two masters idle, and the bridge's
//            delays fixed rather than varying: the reference run for the one
//            below.
//
//   BUSY     the same, with the disk pack side's port and the display's
//            streaming bursts at the arbiter the whole time.  Every machine
//            cycle is compared with its own self in QUIET, and the growth is
//            bounded: see "THE BOUND" below.
//
//   HANDSHAKE  the processor asks the fabric to be quiet in the middle of the
//            parity loop, which is what its secure firmware does before it
//            resets the bridge.  Nothing new may be put to the bridge once
//            the request is seen, traffic must resume when the request goes
//            away, and the cycles that met the held port must end on the bus
//            interface's NXM timer and nothing else --- which is what a
//            memory cycle does on a board with no memory at all.
//
// THE BOUND, WHICH IS THE ARBITER'S WHOLE CLAIM.  A machine cycle waits at
// most for what was already in flight when it asked.  With the bridge model
// fixed at `kFixedArWait` ticks to take an address, `kFixedLatency` ticks to
// the first beat and one beat a tick, that is: the address on the bus when
// the machine asked (at most `kFixedArWait` + 1 ticks), plus the beats of the
// other masters' bursts already accepted ahead of it, which one in flight per
// master and direction caps at two bursts of sixteen.  The number below is
// measured and not rounded, so a tick more fails, and the mutations just
// outside it --- a second burst let through, the machine not first --- are in
// `mutations/list.txt`.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <set>
#include <vector>

#include "Vcadr_f2sdram_harness.h"
#include "verilated.h"
#include "cadr_tick.h"

namespace {

// `cadr_ddr_map::MAIN_BASE` with `CADR_DDR_MAP_DE25_NANO` defined, which is
// how this model is built: the second 128 MB from the top of the processor's
// 1 GB.  A model built against the Zynq's base would watch an address the
// machine never uses.
constexpr uint32_t kMainBase = 0xB0000000u;
constexpr uint32_t kReservedSize = 128u * 1024u * 1024u;
constexpr int kPageWords = 256;
// Sixteen times wider than page 0, so a transaction that lands off the page
// still lands somewhere this program can name rather than merely count.
constexpr int kWindowWords = 4096;

// Where the other two masters read and write, a megabyte and two megabytes
// into the region: inside the reservation, nowhere near page 0, and far
// enough apart that neither can touch the other's words.
constexpr uint32_t kPackBase = kMainBase + 0x00100000u;
constexpr uint32_t kDisplayBase = kMainBase + 0x00200000u;
constexpr int kOtherBeats = 16;   // the pack side's burst, and the display's
// **AND THE DISPLAY OFFERS MORE THAN ONE AT A TIME**, as the display output on
// the Zynq boards does: its port there is built with eight reads in flight
// (`cadr_display_out.sv`'s `OUTSTANDING`).  What holds it to one here is the
// arbiter, and a stimulus that offered one would leave that nothing to do ---
// the lesson that a stimulus more polite than the real consumer tests less.
constexpr int kDisplayOffered = 8;
// How long the pack side leaves its write response standing before it takes
// it: see the master's own code below.
constexpr long kPackBHold = 12;

// The IDs `cadr_f2sdram_share.sv` gives its three ports.
constexpr int kMachineId = 0, kPackId = 1, kDisplayId = 2;

// 200 ms of machine time for the run that has to show the region quiet
// afterwards, and 130 ms for the rest: the parity loop closes at about
// 118 ms.
constexpr long kTicksLong = 40000000L;
constexpr long kTicksShort = 26000000L;

// The parity loop's own microcycle, invariant under everything below.
constexpr long kFirstReqMicro = 536303;

// The bridge's fixed delays, for the two runs the bound is measured between.
constexpr int kFixedArWait = 2;     // ticks before an address is taken
constexpr int kFixedLatency = 6;    // ticks from the address to the first beat

int fails = 0;
constexpr int kFailuresPrinted = 20;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  if (fails > kFailuresPrinted) return;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: ");
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
  if (fails == kFailuresPrinted)
    std::fprintf(stderr, "  (further failures counted and not printed)\n");
}

// The poison: injective over the window, bit 0 clear in every word of page 0,
// and never a word this program could produce by accident.  The same shape as
// `tb/cadr_ddr_boot_tb.cpp`'s, because it is the same claim.
uint32_t Poison(int word) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>((word % kPageWords) + 1)) ^
               0xA5A5A5A5u;
  p &= ~1u;
  p ^= static_cast<uint32_t>(word / kPageWords) << 24;
  return p;
}

// What the model holds at a byte address outside the watched window: a word
// of its own, so that a stray read is not mistaken for a poisoned one.
uint32_t Elsewhere(uint32_t addr) { return 0xC0DE0000u ^ addr; }

// One transaction as the model took it.
struct Txn {
  long tick;
  long micro;
  int id;
  uint32_t addr;
  bool write;
  uint32_t data;    // a write's word, as the strobes place it
  uint64_t beat;    // a read's beat, as the bridge handed it back
  uint32_t strb;
};

struct Run {
  std::vector<Txn> machine;     // the machine's transactions, in order
  std::map<uint32_t, uint32_t> words;  // the model's memory, by byte address
  std::vector<long> cycle;      // each machine cycle's ticks, request to done
  long micro = 0;
  long timeouts = 0;
  long first_req_micro = -1;
  long last_edge_tick = -1;
  long final_pc = -1;
  long ar_seen = 0, aw_seen = 0;      // at the bridge, any master
  long machine_reads = 0, machine_writes = 0;
  long pack_bursts = 0, display_bursts = 0;
  long collisions = 0;          // machine cycles with another burst in flight
  long worst_ahead = 0;         // other addresses taken before the machine's
  long unbacked_dones = 0;      // cycles that ended before the bridge answered
  long machine_answers = 0;     // the bridge's answers to the machine
  long asked_reads = 0, asked_writes = 0;          // the tally's halves
  long answered_reads = 0, answered_writes = 0;
  uint32_t tally_low = 0, tally_high = 0;
  long held_issues = 0;         // transactions started while the port is held
  long ack_while_busy = 0;      // the handshake acknowledged with work in it
  long ack_ticks = -1;          // when the acknowledgment came
  long resumed = 0;             // transactions after the request went away
  long left_in_flight = 0;      // what the bridge took and never answered
  bool bad_protocol = false;
};

// ---------------------------------------------------------------- the model
//
// The bridge: an AXI4 slave at 64 bits with a memory of its own, in-order
// across IDs, which is the shape that makes the bound above meaningful ---
// out of order, a master's data can overtake another's and there is nothing
// to bound.  The Agilex 5's bridge may interleave, and a fabric that depended
// on it not to would be wrong; nothing here depends on the order, and the
// routing by ID is what the model's mixed IDs exercise.
struct Bridge {
  Run *run;
  bool varying;          // delays that change per transaction, or fixed
  uint32_t seed = 0x13579BDFu;
  // reads accepted and not yet finished, in the order they were accepted
  struct Rd { int id; uint32_t addr; int beats; int sent; long start; };
  std::deque<Rd> reads;
  // writes whose address has been taken, and their data as it arrives
  struct Wr { int id; uint32_t addr; int beats; int got; bool done; long at; };
  std::deque<Wr> writes;
  int ar_wait = 0, aw_wait = 0, w_wait = 0;
  long r_due = -1, b_due = -1;
  // the last payload seen under a valid that was not taken, for stability
  bool ar_held = false, aw_held = false, w_held = false;
  uint32_t ar_addr_held = 0, aw_addr_held = 0;
  uint64_t w_data_held = 0;
  uint32_t w_strb_held = 0;

  uint32_t Next() {
    seed = seed * 1103515245u + 12345u;
    return (seed >> 16) & 0x7FFFu;
  }

  int Wait(int fixed) { return varying ? static_cast<int>(Next() % 5) : fixed; }

  uint32_t Word(uint32_t addr) {
    auto it = run->words.find(addr);
    if (it != run->words.end()) return it->second;
    return Elsewhere(addr);
  }

  uint64_t Beat(uint32_t addr) {
    return (static_cast<uint64_t>(Word(addr + 4)) << 32) | Word(addr);
  }

  void PutBeat(uint32_t addr, uint64_t data, uint32_t strb) {
    uint64_t beat = Beat(addr);
    for (int b = 0; b < 8; ++b) {
      if (strb & (1u << b)) {
        const uint64_t m = 0xFFULL << (8 * b);
        beat = (beat & ~m) | (data & m);
      }
    }
    run->words[addr] = static_cast<uint32_t>(beat);
    run->words[addr + 4] = static_cast<uint32_t>(beat >> 32);
  }
};

// The rules of the bridge and of AXI, on one address.
void CheckAddress(Run &run, long t, const char *what, int id, uint32_t addr,
                  int len, int size, int burst, int cache, int prot,
                  int user, int qos, int lock, int region) {
  auto bad = [&](const char *why, long got, long want) {
    run.bad_protocol = true;
    Check(false, "tick %ld: the %s of %08x (id %d) %s: %ld, wanting %ld", t,
          what, addr, id, why, got, want);
  };
  if (size != 3) bad("is not a full-width beat", size, 3);
  if (burst != 1) bad("is not an INCR burst", burst, 1);
  if (cache != 2) bad("carries the wrong AxCACHE", cache, 2);
  if (prot != 3) bad("carries the wrong AxPROT", prot, 3);
  if (user != 0xE0) bad("carries the wrong AxUSER", user, 0xE0);
  if (qos != 0) bad("carries a QoS", qos, 0);
  if (lock != 0) bad("is an exclusive access", lock, 0);
  if (region != 0) bad("carries a region", region, 0);
  if ((addr & 7u) != 0) bad("is not beat-aligned", addr & 7u, 0);
  if (addr < kMainBase || addr >= kMainBase + kReservedSize)
    bad("is outside the reservation", addr, kMainBase);
  if (id == kMachineId && len != 0) bad("is not one beat", len, 0);
  // AXI4: a burst may not cross a 4 KB boundary.
  const uint32_t last = addr + static_cast<uint32_t>(len + 1) * 8u - 1u;
  if ((addr >> 12) != (last >> 12)) bad("crosses a 4 KB boundary", last, addr);
}

// Runs the machine with the model behind it.
struct Config {
  const char *name;
  bool open;            // software opens the port
  bool varying;         // the bridge's delays vary
  bool others;          // the pack side and the display stream
  long ticks;
  long quiet_from = -1; // tick the processor asks for quiet, or -1
  long quiet_to = -1;
};

Run Simulate(const Config &cfg) {
  Run out;
  for (int i = 0; i < kWindowWords; ++i)
    out.words[kMainBase + 4u * static_cast<uint32_t>(i)] = Poison(i);

  auto *dut = new Vcadr_f2sdram_harness;
  Bridge bridge;
  bridge.run = &out;
  bridge.varying = cfg.varying;

  dut->clk = 0;
  dut->rst = 1;
  dut->h2f_reset = 1;
  dut->gp_open = 0;
  dut->gp_half = 0;
  dut->warm_req_n = 1;
  dut->f2s_awready = 0;
  dut->f2s_wready = 0;
  dut->f2s_bvalid = 0;
  dut->f2s_bresp = 0;
  dut->f2s_bid = 0;
  dut->f2s_arready = 0;
  dut->f2s_rvalid = 0;
  dut->f2s_rresp = 0;
  dut->f2s_rlast = 0;
  dut->f2s_rid = 0;
  dut->f2s_rdata = 0;
  dut->p_awaddr = 0; dut->p_awlen = 0; dut->p_awsize = 3; dut->p_awburst = 1;
  dut->p_awvalid = 0; dut->p_wdata = 0; dut->p_wstrb = 0xFF; dut->p_wlast = 0;
  dut->p_wvalid = 0; dut->p_bready = 0;
  dut->p_araddr = 0; dut->p_arlen = 0; dut->p_arsize = 3; dut->p_arburst = 1;
  dut->p_arvalid = 0; dut->p_rready = 1;
  dut->d_araddr = 0; dut->d_arlen = 0; dut->d_arsize = 3; dut->d_arburst = 1;
  dut->d_arvalid = 0; dut->d_rready = 1;
  dut->eval();

  // The two other masters, each with one burst in flight: the pack side
  // alternates a write and a read of sixteen beats, and the display reads.
  int pack_phase = 0;             // 0 write address, 1 write data, 2 read
  int pack_beat = 0;
  uint32_t pack_addr = kPackBase, display_addr = kDisplayBase;
  bool pack_w_out = false, pack_r_out = false;
  int display_out = 0;          // the display's reads in flight
  long pack_b_left = 0;
  long pack_b_held = 0;

  long micro = 0;
  int to_last = 0;
  bool req_last = false, done_last = false;
  long req_at = -1;
  long done_count = 0;
  bool done_rose = false;
  // Other masters' addresses taken between a machine request and the
  // machine's own: what the machine's priority is worth.
  long ahead = 0;
  bool ar_seen_last = false;

  for (long t = 0; t < cfg.ticks; ++t) {
    dut->rst = (t < 8);
    // The port comes live after the fabric's reset, as on the board: the
    // fabric runs from configuration and software opens the port whenever it
    // gets there.
    dut->h2f_reset = (t < 16) ? 1 : 0;
    dut->gp_open = (cfg.open && t >= 24) ? 1 : 0;
    dut->warm_req_n =
        (cfg.quiet_from >= 0 && t >= cfg.quiet_from && t < cfg.quiet_to) ? 0 : 1;

    // ------------------------------------------------------- the bridge
    // Ready when it has no address of that kind in hand and its wait has
    // run out.  A write's data is taken beat by beat once its address is.
    dut->f2s_arready = 0;
    dut->f2s_awready = 0;
    dut->f2s_wready = 0;
    if (!dut->rst) {
      if (dut->f2s_arvalid) {
        if (bridge.ar_wait > 0) --bridge.ar_wait;
        else dut->f2s_arready = 1;
      } else {
        bridge.ar_wait = bridge.Wait(kFixedArWait);
      }
      if (dut->f2s_awvalid) {
        if (bridge.aw_wait > 0) --bridge.aw_wait;
        else dut->f2s_awready = 1;
      } else {
        bridge.aw_wait = bridge.Wait(kFixedArWait);
      }
      // **WRITE DATA IS TAKEN ONLY ONCE ITS ADDRESS IS**, which AXI allows a
      // slave to insist on ("the slave can wait for AWVALID or WVALID, or
      // both, before asserting AWREADY", and the same for WREADY), and which
      // is what makes a beat arriving before any address a fault worth
      // reporting rather than a legal ordering this model cannot place.
      bool open_write = false;
      for (const auto &w : bridge.writes) {
        if (!w.done) { open_write = true; break; }
      }
      if (dut->f2s_wvalid && open_write) {
        if (bridge.w_wait > 0) --bridge.w_wait;
        else dut->f2s_wready = 1;
      } else if (!dut->f2s_wvalid) {
        bridge.w_wait = bridge.Wait(0);
      }
    }

    // Read data: the head of the queue, one beat a tick, after its latency.
    if (!bridge.reads.empty()) {
      Bridge::Rd &rd = bridge.reads.front();
      if (t >= rd.start + (cfg.varying ? 4 + (rd.id * 3) % 7 : kFixedLatency)) {
        dut->f2s_rvalid = 1;
        dut->f2s_rid = static_cast<uint8_t>(rd.id);
        dut->f2s_rdata = bridge.Beat(rd.addr + 8u * static_cast<uint32_t>(rd.sent));
        dut->f2s_rresp = 0;
        dut->f2s_rlast = (rd.sent + 1 == rd.beats) ? 1 : 0;
      }
    }
    // The write response, once the data is in.
    if (!bridge.writes.empty() && bridge.writes.front().done) {
      const Bridge::Wr &wr = bridge.writes.front();
      if (t >= wr.at + (cfg.varying ? 3 : 2)) {
        dut->f2s_bvalid = 1;
        dut->f2s_bid = static_cast<uint8_t>(wr.id);
        dut->f2s_bresp = 0;
      }
    }

    // --------------------------------------------- the other two masters
    if (cfg.others && !dut->rst) {
      // The pack side: a sixteen-beat write, then a sixteen-beat read.
      dut->p_awvalid = (pack_phase == 0 && !pack_w_out) ? 1 : 0;
      dut->p_awaddr = pack_addr;
      dut->p_awlen = kOtherBeats - 1;
      dut->p_wvalid = (pack_phase == 1) ? 1 : 0;
      dut->p_wdata = (static_cast<uint64_t>(pack_addr) << 16) ^
                     (0x5151515151515151ULL + pack_beat);
      dut->p_wlast = (pack_beat + 1 == kOtherBeats) ? 1 : 0;
      dut->p_arvalid = (pack_phase == 2 && !pack_r_out) ? 1 : 0;
      dut->p_araddr = pack_addr;
      dut->p_arlen = kOtherBeats - 1;
      // **AND THE PACK SIDE IS SLOW TO TAKE ITS WRITE RESPONSE**, which is
      // what leaves a response standing on the bus for a while: a master
      // that took every response the tick it was offered would never let
      // another master be offered one it might take by mistake.  A response
      // stands here for `kPackBHold` ticks.
      if (dut->p_bvalid) ++pack_b_held; else pack_b_held = 0;
      dut->p_bready = (pack_b_held > kPackBHold) ? 1 : 0;
      // The display: sixteen-beat reads, as many at once as it is allowed.
      dut->d_arvalid = (display_out < kDisplayOffered) ? 1 : 0;
      dut->d_araddr = display_addr;
      dut->d_arlen = kOtherBeats - 1;
    }

    dut->eval();

    // WHAT THE EDGE SAW, sampled before it.
    const int s_arvalid = dut->f2s_arvalid, s_arready = dut->f2s_arready;
    const int s_awvalid = dut->f2s_awvalid, s_awready = dut->f2s_awready;
    const int s_wvalid = dut->f2s_wvalid, s_wready = dut->f2s_wready;
    const int s_rvalid = dut->f2s_rvalid, s_rready = dut->f2s_rready;
    const int s_bvalid = dut->f2s_bvalid, s_bready = dut->f2s_bready;
    const uint32_t s_araddr = dut->f2s_araddr, s_awaddr = dut->f2s_awaddr;
    const uint64_t s_wdata = dut->f2s_wdata;
    const uint32_t s_wstrb = dut->f2s_wstrb;
    const int s_arid = dut->f2s_arid, s_awid = dut->f2s_awid;
    const int s_wlast = dut->f2s_wlast;
    // AND THE OTHER TWO MASTERS' HANDSHAKES, SAMPLED HERE TOO.  Their state
    // machines below are driven from these and not from what the ports read
    // after the edge, which is the next cycle's: a master built on that
    // counts beats that have not happened.
    const int p_aw_hs = dut->p_awvalid && dut->p_awready;
    const int p_w_hs = dut->p_wvalid && dut->p_wready;
    const int p_ar_hs = dut->p_arvalid && dut->p_arready;
    const int p_r_hs = dut->p_rvalid && dut->p_rready;
    const int p_r_last = dut->p_rlast;
    const int d_ar_hs = dut->d_arvalid && dut->d_arready;

    // A VALID MAY NOT MOVE BEFORE ITS READY, AND ITS PAYLOAD MAY NOT CHANGE.
    if (s_arvalid && !s_arready) {
      if (bridge.ar_held && bridge.ar_addr_held != s_araddr) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a read address changed under its valid, %08x to %08x",
              t, bridge.ar_addr_held, s_araddr);
      }
      bridge.ar_held = true;
      bridge.ar_addr_held = s_araddr;
    } else if (!s_arvalid) {
      if (bridge.ar_held) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a read address was withdrawn before it was taken", t);
      }
      bridge.ar_held = false;
    } else {
      bridge.ar_held = false;
    }
    if (s_awvalid && !s_awready) {
      if (bridge.aw_held && bridge.aw_addr_held != s_awaddr) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a write address changed under its valid, %08x to %08x",
              t, bridge.aw_addr_held, s_awaddr);
      }
      bridge.aw_held = true;
      bridge.aw_addr_held = s_awaddr;
    } else if (!s_awvalid) {
      if (bridge.aw_held) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a write address was withdrawn before it was taken", t);
      }
      bridge.aw_held = false;
    } else {
      bridge.aw_held = false;
    }
    if (s_wvalid && !s_wready) {
      if (bridge.w_held &&
          (bridge.w_data_held != s_wdata || bridge.w_strb_held != s_wstrb)) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a write beat changed under its valid", t);
      }
      bridge.w_held = true;
      bridge.w_data_held = s_wdata;
      bridge.w_strb_held = s_wstrb;
    } else {
      bridge.w_held = false;
    }

    // NOTHING GOES OUT WHILE THE PORT IS SHUT OR HELD.  The gate's three
    // synchronizers are three ticks deep, so a request raised at `t` may
    // still see an address put at `t + 3`; after that, nothing.
    const bool held = (cfg.quiet_from >= 0 && t >= cfg.quiet_from + 4 &&
                       t < cfg.quiet_to);
    if ((s_arvalid && s_arready) || (s_awvalid && s_awready)) {
      if (!cfg.open) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a transaction reached the bridge with the port shut", t);
      }
      if (held) ++out.held_issues;
      if (cfg.quiet_to >= 0 && t >= cfg.quiet_to) ++out.resumed;
    }

    // **THE ACKNOWLEDGMENT IS THE FABRIC SAYING IT IS QUIET**, so it may not
    // be given while the bridge holds work of ours.  Both are read here,
    // before the edge, where the acknowledgment the processor would sample
    // and the bridge's own queues are of the same instant.
    if (!dut->warm_ack_n && !dut->rst) {
      if (out.ack_ticks < 0) out.ack_ticks = t;
      if (!bridge.reads.empty() || !bridge.writes.empty()) ++out.ack_while_busy;
    }

    dut->clk = 1;
    dut->eval();

    // ------------------------------------------------ what the edge did
    if (dut->clock_edge) {
      ++micro;
      out.last_edge_tick = t;
    }
    if (dut->timed_out && !to_last) ++out.timeouts;
    to_last = dut->timed_out;
    out.final_pc = dut->pc;

    if (!dut->rst) {
      if (dut->mem_req && !req_last) {
        req_at = t;
        ahead = 0;
        if (out.first_req_micro < 0) out.first_req_micro = micro;
      }
      // **A CYCLE MAY NOT END BEFORE THE BRIDGE HAS ANSWERED IT.**  Every
      // answer the bridge gives the machine is counted where the model gives
      // it, which is later in this tick, so the comparison is made at the end
      // of the tick: a `mem_done` with no answer behind it is the fabric
      // taking somebody else's answer for its own.
      if (dut->mem_done && !done_last) done_rose = true;
      if (dut->mem_done && !done_last && req_at >= 0) {
        out.cycle.push_back(t - req_at);
        // Was one of the OTHER masters' bursts in flight while this cycle
        // ran?  The machine's own transaction is in those queues too.
        bool other = false;
        for (const auto &rd : bridge.reads) if (rd.id != kMachineId) other = true;
        for (const auto &wr : bridge.writes) if (wr.id != kMachineId) other = true;
        if (other) ++out.collisions;
        req_at = -1;
      }
      req_last = dut->mem_req != 0;
      done_last = dut->mem_done != 0;
    }

    // The bridge takes what the edge handed it.
    if (s_arvalid && s_arready) {
      ++out.ar_seen;
      CheckAddress(out, t, "read", s_arid, s_araddr, dut->f2s_arlen,
                   dut->f2s_arsize, dut->f2s_arburst, dut->f2s_arcache,
                   dut->f2s_arprot, dut->f2s_aruser, dut->f2s_arqos,
                   dut->f2s_arlock, dut->f2s_arregion);
      bridge.reads.push_back({s_arid, s_araddr, dut->f2s_arlen + 1, 0, t});
      bridge.ar_wait = bridge.Wait(kFixedArWait);
      if (s_arid != kMachineId && req_at >= 0) ++ahead;
      if (s_arid == kMachineId) {
        if (req_at >= 0 && ahead > out.worst_ahead) out.worst_ahead = ahead;
        ++out.machine_reads;
        Txn x;
        x.tick = t; x.micro = micro; x.id = s_arid; x.addr = s_araddr;
        x.write = false; x.data = 0; x.beat = 0; x.strb = 0;
        out.machine.push_back(x);
      } else if (s_arid == kPackId) {
        ++out.pack_bursts;
      } else {
        ++out.display_bursts;
      }
    }
    if (s_awvalid && s_awready) {
      ++out.aw_seen;
      CheckAddress(out, t, "write", s_awid, s_awaddr, dut->f2s_awlen,
                   dut->f2s_awsize, dut->f2s_awburst, dut->f2s_awcache,
                   dut->f2s_awprot, dut->f2s_awuser, dut->f2s_awqos,
                   dut->f2s_awlock, dut->f2s_awregion);
      bridge.writes.push_back({s_awid, s_awaddr, dut->f2s_awlen + 1, 0, false, t});
      bridge.aw_wait = bridge.Wait(kFixedArWait);
      if (s_awid != kMachineId && req_at >= 0) ++ahead;
      if (s_awid == kMachineId && req_at >= 0 && ahead > out.worst_ahead)
        out.worst_ahead = ahead;
    }
    if (s_wvalid && s_wready) {
      // A BEAT WITHOUT ITS ADDRESS IS A BEAT NOBODY CAN PLACE, and write data
      // must arrive in the order of the write addresses: the bridge is AXI4
      // and has no write ID.
      Bridge::Wr *open = nullptr;
      for (auto &w : bridge.writes) {
        if (!w.done) { open = &w; break; }
      }
      if (open == nullptr) {
        out.bad_protocol = true;
        Check(false, "tick %ld: a write beat with no write address before it", t);
      } else {
        const uint32_t at = open->addr + 8u * static_cast<uint32_t>(open->got);
        if (dut->f2s_wuser != 0) {
          out.bad_protocol = true;
          Check(false, "tick %ld: a write beat carries WUSER %d", t, (int)dut->f2s_wuser);
        }
        if (open->id == kMachineId) {
          // The machine's word is four bytes in one half of the beat and
          // nothing else.
          if (s_wstrb != 0x0Fu && s_wstrb != 0xF0u) {
            out.bad_protocol = true;
            Check(false, "tick %ld: the machine's write carries strobes %02x", t, s_wstrb);
          }
          ++out.machine_writes;
          Txn x;
          x.tick = t; x.micro = micro; x.id = open->id; x.addr = at;
          x.write = true; x.strb = s_wstrb; x.beat = s_wdata;
          x.data = (s_wstrb == 0x0Fu) ? static_cast<uint32_t>(s_wdata)
                                      : static_cast<uint32_t>(s_wdata >> 32);
          out.machine.push_back(x);
        }
        bridge.PutBeat(at, s_wdata, s_wstrb);
        ++open->got;
        const bool last = (open->got == open->beats);
        if ((s_wlast != 0) != last) {
          out.bad_protocol = true;
          Check(false, "tick %ld: WLAST is %d on beat %d of %d", t, s_wlast,
                open->got, open->beats);
        }
        if (last) { open->done = true; open->at = t; }
      }
      bridge.w_wait = bridge.Wait(0);
    }
    if (s_rvalid && s_rready) {
      Bridge::Rd &rd = bridge.reads.front();
      if (rd.id == kMachineId && rd.sent + 1 == rd.beats) ++out.machine_answers;
      if (rd.id == kMachineId) {
        // WHAT THE BRIDGE HANDED BACK, WHOLE.  Which half of it is the
        // machine's word is the machine's own choice, and the check below
        // asks the write-back what it took; the beat is here so that the
        // model's own memory can be compared with the poison.
        out.machine.back().beat = bridge.Beat(rd.addr);
      }
      ++rd.sent;
      if (rd.sent == rd.beats) {
        bridge.reads.pop_front();
        if (rd.id == kPackId) pack_r_out = false;
        if (rd.id == kDisplayId) --display_out;
      }
      dut->f2s_rvalid = 0;
      dut->f2s_rlast = 0;
    }
    if (s_bvalid && s_bready) {
      const Bridge::Wr wr = bridge.writes.front();
      if (wr.id == kMachineId) ++out.machine_answers;
      bridge.writes.pop_front();
      if (wr.id == kPackId) {
        pack_w_out = false;
        pack_phase = 2;
      }
      dut->f2s_bvalid = 0;
    }

    // The other two masters' own state machines, after the edge.
    if (cfg.others && !dut->rst) {
      if (p_aw_hs) {
        pack_w_out = true;
        pack_phase = 1;
        pack_beat = 0;
      }
      if (p_w_hs) {
        ++pack_beat;
        if (pack_beat == kOtherBeats) {
          pack_phase = 3;   // waiting for the response
          (void)pack_b_left;
        }
      }
      if (p_ar_hs) {
        pack_r_out = true;
        pack_phase = 4;
      }
      if (p_r_hs && p_r_last) {
        pack_phase = 0;
        pack_addr += 8u * kOtherBeats;
        if (pack_addr >= kPackBase + 0x10000u) pack_addr = kPackBase;
      }
      if (d_ar_hs) {
        ++display_out;
        display_addr += 8u * kOtherBeats;
        if (display_addr >= kDisplayBase + 0x10000u) display_addr = kDisplayBase;
      }
      if (pack_phase == 3 && !pack_w_out) pack_phase = 2;
    }

    // The cycle that ended this tick, against the answers the bridge has
    // given by the end of it.
    if (done_rose) {
      if (out.machine_answers <= done_count) ++out.unbacked_dones;
      ++done_count;
      done_rose = false;
    }

    // The tally, as software reads it: the two halves, chosen by the second
    // general-purpose bit, which is driven from here.
    dut->gp_half = (t & 0x400) ? 1 : 0;
    if (t + 1 == cfg.ticks) {
      // Read both halves at the end, each after its synchronizers.
      for (int half = 0; half < 2; ++half) {
        dut->gp_half = half;
        for (int k = 0; k < 8; ++k) {
          dut->clk = 0; dut->eval();
          dut->clk = 1; dut->eval();
        }
        if (half == 0) out.tally_low = dut->gp_in;
        else out.tally_high = dut->gp_in;
      }
    }

    dut->clk = 0;
    dut->eval();
    (void)ar_seen_last;
  }

  // WHAT THE BRIDGE WAS GIVEN OF THE MACHINE'S AND NEVER ANSWERED.  A port
  // cut off in the middle of a transaction leaves one here, and nothing else
  // does.  The other two masters are counted out: they stream until the run
  // stops, so one of theirs is always in the air at the end.
  for (const auto &rd : bridge.reads)
    if (rd.id == kMachineId) ++out.left_in_flight;
  for (const auto &wr : bridge.writes)
    if (wr.id == kMachineId) ++out.left_in_flight;
  out.micro = micro;
  out.answered_reads = out.tally_low & 0x7FFFu;
  out.answered_writes = (out.tally_low >> 16) & 0x7FFFu;
  out.asked_reads = out.tally_high & 0x7FFFu;
  out.asked_writes = (out.tally_high >> 16) & 0x7FFFu;

  dut->final();
  delete dut;
  return out;
}

// What the parity loop must have done, whatever else the run was about.
void CheckParityLoop(const Run &r, const char *name) {
  Check(r.machine.size() == 512, "%s: %zu machine transactions, wanting 512",
        name, r.machine.size());
  Check(r.machine_reads == 256, "%s: %ld machine reads, wanting 256", name,
        r.machine_reads);
  Check(r.machine_writes == 256, "%s: %ld machine writes, wanting 256", name,
        r.machine_writes);
  Check(r.first_req_micro == kFirstReqMicro,
        "%s: the first memory cycle is at microcycle %ld, wanting %ld", name,
        r.first_req_micro, kFirstReqMicro);
  // THE ADDRESSES ARE THE PROGRAM'S AND NOT THE FABRIC'S: base + 4i, read
  // then written, for each of the 256 words of page 0.
  for (int i = 0; i < kPageWords && 2 * i + 1 < static_cast<int>(r.machine.size());
       ++i) {
    const Txn &rd = r.machine[2 * i];
    const Txn &wr = r.machine[2 * i + 1];
    const uint32_t want = kMainBase + 4u * static_cast<uint32_t>(i);
    // The read's address is the beat's; the word's own is the read lane.
    const uint32_t want_beat = want & ~7u;
    Check(!rd.write && rd.addr == want_beat,
          "%s: transaction %d is a %s of %08x, wanting a read of %08x", name,
          2 * i, rd.write ? "write" : "read", rd.addr, want_beat);
    Check(wr.write && wr.addr == want_beat,
          "%s: transaction %d is a %s of %08x, wanting a write of %08x", name,
          2 * i + 1, wr.write ? "write" : "read", wr.addr, want_beat);
    Check(wr.strb == ((want & 4u) ? 0xF0u : 0x0Fu),
          "%s: word %d is written with strobes %02x, wanting %02x", name, i,
          wr.strb, (want & 4u) ? 0xF0u : 0x0Fu);
    // **WHAT THE MACHINE TOOK OUT OF THE BEAT IS THE WRITE-BACK'S WORD**, and
    // it must be the poison of the word it was asked for.  A lane chosen
    // wrongly reads the neighbor, whose poison is another word entirely, and
    // the write-back then carries it here.
    const uint32_t returned = (want & 4u)
                                  ? static_cast<uint32_t>(rd.beat >> 32)
                                  : static_cast<uint32_t>(rd.beat);
    Check(returned == Poison(i),
          "%s: the bridge returned %08x for word %d, and the poison there is "
          "%08x", name, returned, i, Poison(i));
    Check(wr.data == Poison(i),
          "%s: word %d was written back as %08x, and the word its read "
          "returned is the poison %08x, so the copy is not the identity",
          name, i, wr.data, Poison(i));
  }
}

// The region afterwards: every word its poison again, the 256 the loop
// touched because it wrote back what it read, and the rest untouched.
void CheckRegion(const Run &r, const char *name) {
  long changed = 0, first = -1;
  for (int i = 0; i < kWindowWords; ++i) {
    const uint32_t addr = kMainBase + 4u * static_cast<uint32_t>(i);
    const auto it = r.words.find(addr);
    const uint32_t got = (it == r.words.end()) ? 0u : it->second;
    if (got != Poison(i)) {
      if (first < 0) first = i;
      ++changed;
    }
  }
  Check(changed == 0,
        "%s: %ld words of the region are not their poison, the first at word "
        "%ld, which holds %08x where the poison is %08x", name, changed, first,
        first >= 0 ? r.words.at(kMainBase + 4u * static_cast<uint32_t>(first)) : 0,
        first >= 0 ? Poison(static_cast<int>(first)) : 0);
}

// The tally's markers, which say the fabric and not an undriven register
// wrote the word: bit 15 set and bit 31 clear in each half.
void CheckMarkers(const Run &r, const char *name) {
  Check((r.tally_low & 0x80008000u) == 0x00008000u,
        "%s: the tally's answered half reads %08x, which does not carry the "
        "marker", name, r.tally_low);
  Check((r.tally_high & 0x80008000u) == 0x00008000u,
        "%s: the tally's asked half reads %08x, which does not carry the "
        "marker", name, r.tally_high);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  // The poison is injective, asserted: a collision would make two words
  // indistinguishable and the identity claim weaker than it reads.
  {
    std::set<uint32_t> seen;
    for (int i = 0; i < kWindowWords; ++i) seen.insert(Poison(i));
    Check(seen.size() == static_cast<size_t>(kWindowWords),
          "the poison collides: %zu distinct words for %d addresses",
          seen.size(), kWindowWords);
    for (int i = 0; i < kPageWords; ++i) {
      Check((Poison(i) & 1u) == 0, "poison word %d has bit 0 set", i);
      Check(Poison(i) != kMainBase + 4u * static_cast<uint32_t>(i),
            "poison word %d is its own address", i);
      Check(Poison(i) != Elsewhere(kMainBase + 4u * static_cast<uint32_t>(i)),
            "poison word %d is what this model returns outside its window", i);
    }
  }

  // ----------------------------------------------------------------- OPEN
  const Config open_cfg{"OPEN", true, true, false, kTicksLong};
  Run open = Simulate(open_cfg);
  std::printf("\nOPEN: software opened the port; the bridge's delays vary\n");
  CheckParityLoop(open, "OPEN");
  CheckRegion(open, "OPEN");
  CheckMarkers(open, "OPEN");
  Check(!open.bad_protocol, "OPEN: the bridge saw a rule broken");
  Check(open.unbacked_dones == 0,
        "OPEN: %ld machine cycles ended before the bridge had answered them",
        open.unbacked_dones);
  Check(open.machine_answers == 512,
        "OPEN: the bridge answered the machine %ld times, wanting 512",
        open.machine_answers);
  Check(open.left_in_flight == 0,
        "OPEN: the bridge was left holding %ld transactions nobody took",
        open.left_in_flight);
  Check(open.answered_reads == 256 && open.answered_writes == 256,
        "OPEN: the tally answers %ld reads and %ld writes, wanting 256 and 256",
        open.answered_reads, open.answered_writes);
  Check(open.asked_reads == 256 && open.asked_writes == 256,
        "OPEN: the tally asks %ld reads and %ld writes, wanting 256 and 256",
        open.asked_reads, open.asked_writes);
  Check(open.ar_seen == 256 && open.aw_seen == 256,
        "OPEN: the bridge took %ld read and %ld write addresses, wanting 256 "
        "and 256", open.ar_seen, open.aw_seen);
  Check(kTicksLong - open.last_edge_tick < 2000,
        "OPEN: the last clock edge was at tick %ld of %ld, so the machine is "
        "not running at the end", open.last_edge_tick, kTicksLong);
  Check(open.final_pc != 040, "OPEN: the machine ended at PC 40, ERROR-DISK-ERROR");
  std::printf("  %zu transactions, %ld reads and %ld writes, every one at its\n"
              "    own address, each write carrying the word its own read\n"
              "    returned; %d words of the region are their poison again\n",
              open.machine.size(), open.machine_reads, open.machine_writes,
              kWindowWords);
  std::printf("  the tally reads %08x and %08x: %ld and %ld asked, %ld and %ld\n"
              "    answered, with the marker in each half\n",
              open.tally_high, open.tally_low, open.asked_reads,
              open.asked_writes, open.answered_reads, open.answered_writes);
  std::printf("  microcycles %ld, first memory cycle at microcycle %ld, NXM "
              "timeouts %ld\n", open.micro, open.first_req_micro, open.timeouts);

  // ----------------------------------------------------------------- SHUT
  const Config shut_cfg{"SHUT", false, true, false, kTicksShort};
  Run shut = Simulate(shut_cfg);
  std::printf("\nSHUT: software never opened the port\n");
  Check(shut.ar_seen == 0 && shut.aw_seen == 0,
        "SHUT: %ld read and %ld write addresses reached the bridge, wanting "
        "none at all", shut.ar_seen, shut.aw_seen);
  Check(shut.asked_reads == 256 && shut.asked_writes == 256,
        "SHUT: the tally asks %ld reads and %ld writes, wanting the same 256 "
        "and 256 as the open port", shut.asked_reads, shut.asked_writes);
  Check(shut.answered_reads == 0 && shut.answered_writes == 0,
        "SHUT: the tally answers %ld reads and %ld writes, wanting none",
        shut.answered_reads, shut.answered_writes);
  CheckMarkers(shut, "SHUT");
  CheckRegion(shut, "SHUT");
  Check(shut.timeouts >= 512,
        "SHUT: %ld NXM timeouts, wanting at least the 512 memory cycles",
        shut.timeouts);
  std::printf("  nothing reached the bridge; the tally reads %08x and %08x:\n"
              "    %ld and %ld asked, nothing answered, and %ld cycles ended on\n"
              "    the NXM timer\n",
              shut.tally_high, shut.tally_low, shut.asked_reads,
              shut.asked_writes, shut.timeouts);

  // --------------------------------------------------------- QUIET, BUSY
  const Config quiet_cfg{"QUIET", true, false, false, kTicksShort};
  const Config busy_cfg{"BUSY", true, false, true, kTicksShort};
  Run quiet = Simulate(quiet_cfg);
  Run busy = Simulate(busy_cfg);
  std::printf("\nQUIET and BUSY: the same machine cycles, with the pack side "
              "and the display idle and streaming\n");
  CheckParityLoop(quiet, "QUIET");
  CheckParityLoop(busy, "BUSY");
  CheckRegion(quiet, "QUIET");
  Check(!quiet.bad_protocol, "QUIET: the bridge saw a rule broken");
  Check(!busy.bad_protocol, "BUSY: the bridge saw a rule broken");
  Check(quiet.left_in_flight == 0 && busy.left_in_flight == 0,
        "QUIET left %ld transactions in the bridge and BUSY %ld, and both must "
        "leave none", quiet.left_in_flight, busy.left_in_flight);
  // **AND THE TALLY COUNTS THE MACHINE'S ANSWERS AND NOBODY ELSE'S.**  With
  // two other masters on the port, a tally that counted every response would
  // read hundreds of thousands here.
  CheckMarkers(busy, "BUSY");
  Check(busy.answered_reads == 256 && busy.answered_writes == 256,
        "BUSY: the tally answers %ld reads and %ld writes, wanting the "
        "machine's own 256 and 256", busy.answered_reads, busy.answered_writes);
  Check(busy.asked_reads == 256 && busy.asked_writes == 256,
        "BUSY: the tally asks %ld reads and %ld writes, wanting 256 and 256",
        busy.asked_reads, busy.asked_writes);
  Check(quiet.cycle.size() == busy.cycle.size(),
        "QUIET ran %zu machine cycles and BUSY %zu", quiet.cycle.size(),
        busy.cycle.size());
  Check(busy.pack_bursts > 0 && busy.display_bursts > 0,
        "BUSY: the pack side moved %ld bursts and the display %ld, so nothing "
        "was in the machine's way", busy.pack_bursts, busy.display_bursts);
  Check(busy.collisions > 0,
        "BUSY: not one machine cycle began with another master's burst in "
        "flight, so the bound below tested nothing");
  // **AND BOTH OTHER MASTERS KEPT MOVING**, which is what says the arbiter
  // shared the port rather than swallowing them: a routing that sent their
  // answers to the machine would leave them waiting for ever, and the bound
  // below would then be measuring a port with one master on it.
  Check(busy.pack_bursts > 1000 && busy.display_bursts > 1000,
        "BUSY: the pack side moved %ld read bursts and the display %ld, and "
        "both stream for the whole run", busy.pack_bursts, busy.display_bursts);
  // **AND THE MACHINE WENT FIRST.**  What it waits for at the arbiter is the
  // address already on the bus when it asked; the measured worst is two, one
  // for each of the ticks its own adapter takes to raise its request behind
  // it, and a master that did not go first waits for more.
  const long ahead_bound = 2;
  Check(busy.worst_ahead <= ahead_bound,
        "BUSY: %ld of the other masters' addresses were taken between a "
        "machine request and the machine's own, against a bound of %ld",
        busy.worst_ahead, ahead_bound);
  Check(busy.unbacked_dones == 0 && quiet.unbacked_dones == 0,
        "QUIET ended %ld machine cycles and BUSY %ld before the bridge had "
        "answered them", quiet.unbacked_dones, busy.unbacked_dones);
  Check(busy.machine_answers == 512 && quiet.machine_answers == 512,
        "the bridge answered the machine %ld times in QUIET and %ld in BUSY, "
        "wanting 512 each", quiet.machine_answers, busy.machine_answers);
  // **THE BOUND, MEASURED AND NOT ROUNDED.**  What a machine cycle may wait
  // for is what was already in flight when it asked: the address on the bus
  // (at most `kFixedArWait` + 1 ticks) and the beats of the bursts the two
  // other masters have accepted ahead of it, which one in flight per master
  // and direction caps at two of sixteen --- a ceiling of 35 ticks.  What the
  // two runs below actually reach is 27, and that is the number held to: a
  // tick more fails.  The mutations just outside it are a second burst let
  // through, and the hold that keeps the other masters from being granted
  // anything new while the machine is asking taken away;
  // `mutations/list.txt` has both.
  const long bound = 27;
  long worst = 0;
  size_t worst_at = 0;
  for (size_t i = 0; i < quiet.cycle.size() && i < busy.cycle.size(); ++i) {
    const long grew = busy.cycle[i] - quiet.cycle[i];
    if (grew > worst) { worst = grew; worst_at = i; }
  }
  Check(worst <= bound,
        "BUSY: machine cycle %zu grew %ld ticks against a bound of %ld, which "
        "is one address on the bus and one burst of each other master",
        worst_at, worst, bound);
  std::printf("  %zu machine cycles, %ld of them with another master's burst "
              "in flight;\n    the pack side moved %ld read bursts and the "
              "display %ld; the worst cycle grew\n    %ld ticks against a "
              "bound of %ld, and at most %ld other addresses were taken "
              "before\n    a machine request's own\n",
              busy.cycle.size(), busy.collisions, busy.pack_bursts,
              busy.display_bursts, worst, bound, busy.worst_ahead);

  // ------------------------------------------------------------ HANDSHAKE
  //
  // The processor asks for quiet in the middle of the parity loop.  The
  // window is 20,000 ticks, which is 200 us: long enough that the machine
  // meets it with cycles of its own, short enough to leave the loop time to
  // finish.
  // **WITH THE OTHER TWO MASTERS STREAMING**, because the request is for the
  // whole fabric to be quiet and the machine alone would hardly test it: its
  // own port goes into reset as soon as it is idle, and it is idle most of
  // the time, so what the hold has to stop is the masters that are not.
  Config hs_cfg{"HANDSHAKE", true, true, true, kTicksShort};
  // WHERE THE WINDOW GOES IS THE LOOP'S OWN, taken from the run above: the
  // tick of its hundredth transaction, which is well inside the loop
  // whatever the delays do to it.  A window at a tick chosen by hand would
  // stop testing the day the loop moved.
  hs_cfg.quiet_from = open.machine[100].tick;
  hs_cfg.quiet_to = hs_cfg.quiet_from + 20000L;
  Run hs = Simulate(hs_cfg);
  std::printf("\nHANDSHAKE: the processor asked the fabric to be quiet for "
              "200 us in the middle of the loop\n");
  Check(hs.held_issues == 0,
        "HANDSHAKE: %ld transactions reached the bridge while the processor "
        "had asked for quiet, and the fabric must put nothing to it then --- "
        "not the machine's and not the other masters'", hs.held_issues);
  Check(hs.pack_bursts > 1000 && hs.display_bursts > 1000,
        "HANDSHAKE: the pack side moved %ld read bursts and the display %ld, "
        "so the window had little to stop", hs.pack_bursts, hs.display_bursts);
  Check(hs.resumed > 0,
        "HANDSHAKE: no transaction reached the bridge after the request went "
        "away, so the port did not come back");
  Check(!hs.bad_protocol, "HANDSHAKE: the bridge saw a rule broken");
  Check(hs.left_in_flight == 0,
        "HANDSHAKE: the bridge was left holding %ld transactions nobody took, "
        "so the port was cut off in the middle of one", hs.left_in_flight);
  // **THE ACKNOWLEDGMENT: GIVEN, AND ONLY WHEN THERE IS NOTHING IN FLIGHT.**
  // The processor's reset manager waits for it before it resets the bridge,
  // and its whole meaning is that the fabric has gone quiet.
  Check(hs.ack_ticks >= 0,
        "HANDSHAKE: the request was never acknowledged, and the processor "
        "waits 300 ms for it");
  Check(hs.ack_ticks >= hs_cfg.quiet_from && hs.ack_ticks < hs_cfg.quiet_to,
        "HANDSHAKE: the acknowledgment came at tick %ld, outside the window "
        "%ld to %ld", hs.ack_ticks, hs_cfg.quiet_from, hs_cfg.quiet_to);
  Check(hs.ack_while_busy == 0,
        "HANDSHAKE: the acknowledgment stood for %ld ticks while the bridge "
        "still held work of ours", hs.ack_while_busy);
  Check(open.ack_ticks < 0,
        "OPEN: the handshake was acknowledged at tick %ld with no request for "
        "it", open.ack_ticks);
  // **WHAT THE WINDOW COSTS IS NXM TIMEOUTS AND NOTHING ELSE.**  A memory
  // cycle that meets a port holding its traffic ends on the bus interface's
  // timer, exactly as one does on a board with no memory, and the machine
  // carries on: every transaction the window took away is one timeout more
  // than the open port's run, and the loop still ends.
  const long missing = 512 - static_cast<long>(hs.machine.size());
  Check(missing > 0,
        "HANDSHAKE: the window took no transaction away, so it did not reach "
        "the loop and nothing was asked of the gate");
  Check(hs.timeouts == open.timeouts + missing,
        "HANDSHAKE: %ld NXM timeouts against the open port's %ld, and %ld "
        "transactions are missing: a cycle the port held must end on the "
        "timer and nothing else", hs.timeouts, open.timeouts, missing);
  // AND WHAT IT COSTS THE REGION IS ITS OWN AND NOT THE GATE'S: a read
  // nobody answers gives MD zero, and the parity loop writes back what it
  // read, so a word whose read fell in the window comes back zero.  Every
  // word outside page 0 is untouched, and page 0 loses at most one word per
  // transaction the window took.
  long changed_page = 0, changed_outside = 0;
  for (int i = 0; i < kWindowWords; ++i) {
    const uint32_t addr = kMainBase + 4u * static_cast<uint32_t>(i);
    const auto it = hs.words.find(addr);
    const uint32_t got = (it == hs.words.end()) ? 0u : it->second;
    if (got != Poison(i)) {
      if (i < kPageWords) ++changed_page;
      else ++changed_outside;
    }
  }
  Check(changed_outside == 0,
        "HANDSHAKE: %ld words outside page 0 changed, and the loop never "
        "touches them", changed_outside);
  Check(changed_page <= missing,
        "HANDSHAKE: %ld words of page 0 changed, and the window took only %ld "
        "transactions away", changed_page, missing);
  std::printf("  nothing was put to the bridge while the request stood, %ld "
              "transactions after it;\n    the acknowledgment came at tick %ld "
              "and never with work in the bridge;\n    %ld of the loop's 512 "
              "ended on the NXM timer instead, and %ld words\n    of page 0 "
              "went with them\n", hs.resumed, hs.ack_ticks, missing,
              changed_page);

  if (fails) {
    std::fprintf(stderr, "\n%d failure%s\n", fails, fails == 1 ? "" : "s");
    return 1;
  }
  std::printf("\nok\n");
  return 0;
}
