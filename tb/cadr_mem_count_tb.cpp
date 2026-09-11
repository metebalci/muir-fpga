// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The memory port's tally, with the machine in front of it: does the number a
// debugger will read out of EMIO say what happened, and does it say nothing
// when nothing happened?
//
// WHY THERE IS A CHECK HERE AT ALL.  `rtl/plumbing/cadr_mem_count.sv` is an INSTRUMENT,
// and an instrument nothing checks is worse than no instrument: it will be
// read on a board, once, and believed.  Step four of the board plan is the
// machine running with DDR answering its 512 page-0 cycles, and the only
// thing that will say so is these four numbers --- the boot PROM's memory
// traffic is an identity copy, which leaves page 0 exactly as a dead port
// leaves it, and no lamp tells the two apart either.  So the numbers have to
// be right for reasons somebody can check without a board.
//
// THREE CONFIGURATIONS, AND THE SECOND IS THE ONE THE INSTRUMENT EXISTS FOR.
//
//   LIVE   `hp0_aresetn` released, an AXI3 slave behind the port answering at
//          a delay of its own.  The machine runs PAGE-0-PARITY-FIX, and the
//          tally must read 256 reads and 256 writes asked for and 256 and 256
//          answered.
//
//   DEAD   `hp0_aresetn` held low for the whole run, which is a board on
//          which nobody has run `ps7_post_config`: the adapter is in reset,
//          `S_AXI_HP0` answers nothing, and every one of the machine's 512
//          main-memory cycles ends on the NXM timer.  The tally must read the
//          SAME 256 and 256 asked for, and **nothing answered**.
//
//   HALF   the port takes a write and never answers it, and answers reads.
//          This one is not a board anybody expects to meet, and it is here
//          because THE BOOT PROM DOES EXACTLY AS MANY READS AS WRITES: 256
//          and 256, so a tally with its two directions crossed --- or with
//          both counters watching one channel --- reads 256 and 256 either
//          way and is invisible to LIVE and to DEAD alike.  Measured, not
//          assumed: swapping the two `answered` triggers changes no number
//          in either of the configurations above.  With the write channel
//          deaf the adapter stops in WRESP after the first write and the two
//          numbers part company --- one read answered and no writes --- which
//          is the only reading here where they differ, and so the only one
//          that can tell them apart.
//
// LIVE AND DEAD TOGETHER ARE THE CLAIM.  A counter of the fabric's own
// intentions --- `mem_req`, `awvalid`, anything this design decides for
// itself --- reads 256 and 256 in BOTH of them, and would report a working
// memory path on a board whose port was never brought up.  CLAUDE.md's
// shadow-memory lesson one level down: a witness that can move with the bug is
// not a witness.  The DEAD configuration is what makes the difference
// measurable, and `mutations/list.txt`'s
// `the-request-is-counted-as-a-write-answered` is the bug it catches.
//
// WHAT THE SLAVE IS AND IS NOT.  It is a 64-bit AXI3 slave with a model
// memory keyed by ITS OWN beat address --- never by anything the DUT says it
// meant --- offering ready at a varying delay on each channel independently
// and answering at a varying delay after that, because a master that only met
// one shape of handshake would pass a check that only offered one.  It is not
// a second copy of `tb/cadr_ddr_boot_tb.cpp`: that check holds the machine's
// memory traffic to the program, transaction by transaction, and this one
// holds the tally to the traffic.  What is asserted here about the traffic is
// only what the tally has to be read against.
//
// THE TALLY IS READ AS THE DEBUGGER READS IT, as sixty-four EMIO GPIO bits,
// and unpacked here the way `boards/arty-z7-20/vivado/ddr_run.tcl` unpacks them.  The packing
// is `rtl/plumbing/cadr_mem_count.sv`'s and its header has the table; what matters
// here is that a field placed one bit over is a number that still looks like
// a measurement, so this reads the word and not four counters.
//
// **AND THE MARKER BITS ARE ASSERTED.**  Bit 15 of each half set and bit 31
// clear, which is a pattern neither an all-ones nor an all-zeros reading can
// produce.  Measured on the board: with the level shifters on and nothing in
// the fabric driving EMIO --- a `DDR=0` bitstream --- both registers read
// 0xFFFFFFFF, which is exactly what four SATURATED counters would read.  The
// marker is what separates them.
//
// AND THE TALLY IS CROSS-CHECKED AGAINST THE SLAVE'S OWN BOOKS, not merely
// against itself: `answered_writes` must equal the number of writes this
// program COMMITTED to its model memory, and `answered_reads` the number of
// beats it FETCHED.  Those are counted where the slave does the work, on the
// request side of its own state machine, so a tally that counted its own
// response wires twice would disagree with them.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <vector>

#include "Vcadr_mem_count_harness.h"
#include "verilated.h"

namespace {

// cadr_ddr_map::MAIN_BASE, and the page the parity loop walks.
constexpr uint32_t kMainBase = 0x18000000u;
constexpr int kPageWords = 256;
// Sixteen times wider than page 0, so a transaction that lands off the page
// still lands somewhere this program can name rather than merely count.
constexpr int kWindowWords = 4096;

// 200 ms of machine time, the horizon `tb/cadr_ddr_boot_tb.cpp` uses. The
// parity loop closes at about 118 ms.
constexpr long kTicks = 40000000L;

// What the machine's page-0 parity loop is: one read and one write to each of
// physical 0..377, and nothing else for the rest of the run.
constexpr int kWantReads = 256;
constexpr int kWantWrites = 256;

int fails = 0;
constexpr int kFailuresPrinted = 20;

void Check(bool ok, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

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

// The poison, injective in the word address and with bit 0 clear --- bit 0 of
// what a read returns is what the boot PROM's disk poll takes for "ready", and
// `tb/cadr_ddr_boot_tb.cpp`'s header has the whole account. Words past page 0
// differ from their page-0 twin in the top byte.
uint32_t Poison(int word) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>((word % kPageWords) + 1)) ^
               0xA5A5A5A5u;
  p &= ~1u;
  p ^= static_cast<uint32_t>(word / kPageWords) << 24;
  return p;
}

// A small deterministic sequence for the handshake delays. Deterministic
// because a check that varies run to run cannot be compared with itself.
uint32_t Next(uint32_t &s) {
  s = s * 1103515245u + 12345u;
  return (s >> 16) & 0x7FFFu;
}

struct Run {
  // What the SLAVE did, counted where it did it.
  long writes_committed = 0;   // beats written into the model memory
  long reads_fetched = 0;      // beats handed back
  // What the port's wires did, counted by this program.
  long b_handshakes = 0;
  long r_handshakes = 0;
  long aw_handshakes = 0;
  long ar_handshakes = 0;
  bool any_request = false;    // awvalid or arvalid ever asserted

  // What the MACHINE did.
  long req_rises = 0, req_read_rises = 0, req_write_rises = 0;
  long micro = 0, timeouts = 0;
  long first_req_micro = -1, last_edge_tick = -1;
  long final_pc = -1;

  // Where the transactions landed.
  long misaligned = 0, outside_window = 0, bad_strobes = 0;

  // The tally, read at the end as a debugger would read it: the whole word,
  // and the four fields taken out of it here.
  uint64_t gpio = 0;
  long asked_reads = 0, asked_writes = 0;
  long answered_reads = 0, answered_writes = 0;
  bool marker_ok = false;

  std::vector<uint32_t> mem;
};

// The three configurations.  `kLive` is the board once `ps7_post_config` has
// run, `kDead` the board before it, and `kHalf` the one contrived to make the
// tally's two directions distinguishable.
enum Mode { kLive, kDead, kHalf };

Run Simulate(Mode mode) {
  const bool live = (mode != kDead);
  const bool answers_writes = (mode != kHalf);
  Run out;
  out.mem.resize(kWindowWords);
  for (int i = 0; i < kWindowWords; ++i) out.mem[i] = Poison(i);

  auto *dut = new Vcadr_mem_count_harness;
  dut->clk = 0;
  dut->rst = 1;
  dut->hp0_aresetn = 0;
  dut->hp0_awready = 0;
  dut->hp0_wready = 0;
  dut->hp0_bvalid = 0;
  dut->hp0_bresp = 0;
  dut->hp0_arready = 0;
  dut->hp0_rvalid = 0;
  dut->hp0_rresp = 0;
  dut->hp0_rlast = 0;
  dut->hp0_rdata = 0;
  dut->eval();

  uint32_t seed = 0x5A5A1234u;
  bool aw_taken = false, w_taken = false, ar_taken = false;
  uint32_t aw_addr = 0, ar_addr = 0, w_strb = 0;
  uint64_t w_data = 0;
  int aw_delay = 0, w_delay = 0, ar_delay = 0;
  int b_wait = -1, r_wait = -1;
  bool req_last = false;
  int to_last = 0;

  for (long t = 0; t < kTicks; ++t) {
    dut->rst = (t < 8);
    // The port comes live after the machine's reset, which is the order the
    // board has: `ps7_post_config` is software and the fabric is already
    // running when it happens.
    dut->hp0_aresetn = (live && t >= 16) ? 1 : 0;

    // ------------------------------------------------------------ the slave
    if (live && !dut->rst) {
      if (dut->hp0_awvalid && !aw_taken) {
        if (aw_delay > 0) { --aw_delay; dut->hp0_awready = 0; }
        else dut->hp0_awready = 1;
      } else dut->hp0_awready = 0;

      if (dut->hp0_wvalid && !w_taken) {
        if (w_delay > 0) { --w_delay; dut->hp0_wready = 0; }
        else dut->hp0_wready = 1;
      } else dut->hp0_wready = 0;

      if (dut->hp0_arvalid && !ar_taken) {
        if (ar_delay > 0) { --ar_delay; dut->hp0_arready = 0; }
        else dut->hp0_arready = 1;
      } else dut->hp0_arready = 0;
    } else {
      // A DEAD PORT ANSWERS NOTHING AT ALL, which is what
      // `SAXIHP0ARESETN` low means: no ready, no response, no data.
      dut->hp0_awready = dut->hp0_wready = dut->hp0_arready = 0;
      dut->hp0_bvalid = dut->hp0_rvalid = 0;
      dut->hp0_rlast = 0;
    }

    // WHAT THE EDGE SAW, SAMPLED BEFORE IT. `eval()` at the rising edge
    // recomputes everything combinational from the new registers, so a
    // handshake read afterwards is the next cycle's.
    dut->eval();
    const int s_awvalid = dut->hp0_awvalid, s_awready = dut->hp0_awready;
    const int s_wvalid = dut->hp0_wvalid, s_wready = dut->hp0_wready;
    const int s_arvalid = dut->hp0_arvalid, s_arready = dut->hp0_arready;
    const int s_bvalid = dut->hp0_bvalid, s_bready = dut->hp0_bready;
    const int s_rvalid = dut->hp0_rvalid, s_rready = dut->hp0_rready;
    const int s_rlast = dut->hp0_rlast;
    const uint32_t s_awaddr = dut->hp0_awaddr, s_araddr = dut->hp0_araddr;
    const uint64_t s_wdata = dut->hp0_wdata;
    const uint32_t s_wstrb = dut->hp0_wstrb;
    if (s_awvalid || s_arvalid) out.any_request = true;

    dut->clk = 1;
    dut->eval();

    // ------------------------------------------------ what the edge did
    if (!dut->rst) {
      if (dut->mem_req && !req_last) {
        ++out.req_rises;
        if (dut->mem_write) ++out.req_write_rises;
        else ++out.req_read_rises;
        if (out.first_req_micro < 0) out.first_req_micro = out.micro;
      }
      req_last = dut->mem_req != 0;
    }

    if (live && !dut->rst) {
      if (s_awvalid && s_awready) {
        ++out.aw_handshakes;
        aw_taken = true;
        aw_addr = s_awaddr;
      }
      if (s_wvalid && s_wready) {
        w_taken = true;
        w_data = s_wdata;
        w_strb = s_wstrb;
      }
      if (s_arvalid && s_arready) {
        ++out.ar_handshakes;
        ar_taken = true;
        ar_addr = s_araddr;
      }

      // THE WRITE COMMITS WHEN BOTH HALVES HAVE BEEN TAKEN, and it commits
      // to the address THIS PROGRAM was given rather than to anything the
      // DUT says it meant --- byte by byte under the strobes, exactly as a
      // slave would, so a strobe pattern that opened both halves destroys
      // the neighbour here as it would on the board.
      if (aw_taken && w_taken && b_wait < 0) {
        const long w0 = (static_cast<long>(aw_addr) -
                         static_cast<long>(kMainBase)) / 4;
        if ((aw_addr & 7u) != 0) ++out.misaligned;
        if (w0 < 0 || w0 + 1 >= kWindowWords) {
          ++out.outside_window;
        } else {
          uint64_t beat = (static_cast<uint64_t>(out.mem[w0 + 1]) << 32) |
                          out.mem[w0];
          for (int b = 0; b < 8; ++b) {
            if (w_strb & (1u << b)) {
              const uint64_t m = 0xFFULL << (8 * b);
              beat = (beat & ~m) | (w_data & m);
            }
          }
          out.mem[w0] = static_cast<uint32_t>(beat);
          out.mem[w0 + 1] = static_cast<uint32_t>(beat >> 32);
        }
        // A word is four bytes in one half of the beat and nothing else.
        if (w_strb != 0x0Fu && w_strb != 0xF0u) ++out.bad_strobes;
        ++out.writes_committed;
        b_wait = 1 + static_cast<int>(Next(seed) % 5);
      }
      if (b_wait > 0) --b_wait;
      // A PORT THAT TAKES A WRITE AND NEVER ANSWERS IT.  The adapter waits in
      // WRESP for ever, so nothing else goes out either: what this
      // configuration produces is one read answered and no writes, and that
      // is the only reading here in which the two numbers differ.
      if (b_wait == 0 && !dut->hp0_bvalid && answers_writes) {
        dut->hp0_bvalid = 1;
        dut->hp0_bresp = 0;
      }
      if (s_bvalid && s_bready) {
        ++out.b_handshakes;
        dut->hp0_bvalid = 0;
        b_wait = -1;
        aw_taken = w_taken = false;
        aw_delay = static_cast<int>(Next(seed) % 5);
        w_delay = static_cast<int>(Next(seed) % 5);
      }

      if (ar_taken && r_wait < 0) {
        if ((ar_addr & 7u) != 0) ++out.misaligned;
        r_wait = 1 + static_cast<int>(Next(seed) % 5);
      }
      if (r_wait > 0) --r_wait;
      if (r_wait == 0 && !dut->hp0_rvalid) {
        const long w0 = (static_cast<long>(ar_addr) -
                         static_cast<long>(kMainBase)) / 4;
        uint64_t beat = 0;
        if (w0 < 0 || w0 + 1 >= kWindowWords) {
          ++out.outside_window;
        } else {
          beat = (static_cast<uint64_t>(out.mem[w0 + 1]) << 32) | out.mem[w0];
        }
        ++out.reads_fetched;
        dut->hp0_rdata = beat;
        dut->hp0_rresp = 0;
        dut->hp0_rlast = 1;
        dut->hp0_rvalid = 1;
      }
      if (s_rvalid && s_rready) {
        if (s_rlast) ++out.r_handshakes;
        dut->hp0_rvalid = 0;
        dut->hp0_rlast = 0;
        r_wait = -1;
        ar_taken = false;
        ar_delay = static_cast<int>(Next(seed) % 5);
      }
    }

    if (dut->clock_edge) {
      ++out.micro;
      out.last_edge_tick = t;
    }
    if (dut->timed_out && !to_last) ++out.timeouts;
    to_last = dut->timed_out;
    out.final_pc = dut->pc;

    dut->clk = 0;
    dut->eval();
  }

  // READ AS A DEBUGGER READS IT: the four counters, once, at the end, long
  // after anything has moved. On the board they are static from 118.4 ms and
  // the read happens whenever somebody asks.
  out.gpio = dut->gpio;
  const uint32_t d2 = static_cast<uint32_t>(out.gpio);
  const uint32_t d3 = static_cast<uint32_t>(out.gpio >> 32);
  out.answered_reads = d2 & 0x7FFFu;
  out.answered_writes = (d2 >> 16) & 0x7FFFu;
  out.asked_reads = d3 & 0x7FFFu;
  out.asked_writes = (d3 >> 16) & 0x7FFFu;
  out.marker_ok = (d2 & 0x80008000u) == 0x00008000u &&
                  (d3 & 0x80008000u) == 0x00008000u;

  dut->final();
  delete dut;
  return out;
}

void CheckRun(const Run &r, Mode mode) {
  const char *name = mode == kLive ? "LIVE" : mode == kDead ? "DEAD" : "HALF";
  std::printf("\n%s: the port %s\n", name,
              mode == kLive
                  ? "answers, as it does once ps7_post_config has run"
                  : mode == kDead
                        ? "is held in reset, as it is before anybody runs "
                          "ps7_post_config"
                        : "takes a write and never answers it, and answers "
                          "reads");
  const bool live = (mode == kLive);

  // WHO WROTE THIS WORD.  Bit 15 of each half set and bit 31 clear, which
  // neither 0x00000000 nor 0xFFFFFFFF can be --- and those are the two things
  // the processing system reads off EMIO when the fabric is not driving it,
  // with the level shifters off and on respectively.
  Check(r.marker_ok,
        "%s: the tally reads %08x %08x, whose marker bits are not (w & "
        "0x80008000) == 0x00008000 in both halves, so nothing says the fabric "
        "wrote it", name, static_cast<uint32_t>(r.gpio >> 32),
        static_cast<uint32_t>(r.gpio));

  // THE MACHINE ASKS THE SAME THING EITHER WAY, and that is what makes the
  // answered pair mean anything at all.
  Check(r.req_read_rises == kWantReads,
        "%s: the machine asked for %ld reads, wanting %d", name,
        r.req_read_rises, kWantReads);
  Check(r.req_write_rises == kWantWrites,
        "%s: the machine asked for %ld writes, wanting %d", name,
        r.req_write_rises, kWantWrites);
  Check(r.asked_reads == r.req_read_rises,
        "%s: the tally counted %ld reads asked for and this program counted "
        "%ld rises of mem_req", name, r.asked_reads, r.req_read_rises);
  Check(r.asked_writes == r.req_write_rises,
        "%s: the tally counted %ld writes asked for and this program counted "
        "%ld rises of mem_req", name, r.asked_writes, r.req_write_rises);

  if (live) {
    Check(r.answered_reads == kWantReads,
          "%s: the tally counted %ld reads answered, wanting %d", name,
          r.answered_reads, kWantReads);
    Check(r.answered_writes == kWantWrites,
          "%s: the tally counted %ld writes answered, wanting %d", name,
          r.answered_writes, kWantWrites);
    // AND AGAINST THE SLAVE'S OWN BOOKS, counted where the slave does the
    // work rather than on the wires the tally watches.
    Check(r.answered_writes == r.writes_committed,
          "%s: the tally counted %ld writes answered and the slave committed "
          "%ld beats to its memory", name, r.answered_writes,
          r.writes_committed);
    Check(r.answered_reads == r.reads_fetched,
          "%s: the tally counted %ld reads answered and the slave fetched %ld "
          "beats", name, r.answered_reads, r.reads_fetched);
    Check(r.b_handshakes == kWantWrites,
          "%s: %ld B handshakes at the port, wanting %d", name,
          r.b_handshakes, kWantWrites);
    Check(r.r_handshakes == kWantReads,
          "%s: %ld last-beat R handshakes at the port, wanting %d", name,
          r.r_handshakes, kWantReads);
    Check(r.aw_handshakes == kWantWrites && r.ar_handshakes == kWantReads,
          "%s: %ld AW and %ld AR handshakes, wanting %d and %d", name,
          r.aw_handshakes, r.ar_handshakes, kWantWrites, kWantReads);
    Check(r.misaligned == 0, "%s: %ld beats were not 8-byte aligned", name,
          r.misaligned);
    Check(r.outside_window == 0,
          "%s: %ld beats landed outside the %d-word window", name,
          r.outside_window, kWindowWords);
    Check(r.bad_strobes == 0,
          "%s: %ld writes carried strobes that were neither half of the beat",
          name, r.bad_strobes);
    // The parity loop is an identity copy, so the window is its poison again.
    long changed = 0, first = -1;
    for (int i = 0; i < kWindowWords; ++i) {
      if (r.mem[i] != Poison(i)) {
        if (first < 0) first = i;
        ++changed;
      }
    }
    Check(changed == 0,
          "%s: %ld words of the window are not their poison, the first at "
          "word %ld, which holds %08x where the poison is %08x", name, changed,
          first, first >= 0 ? r.mem[first] : 0,
          first >= 0 ? Poison(static_cast<int>(first)) : 0);
  } else if (mode == kHalf) {
    // ONE READ ANSWERED AND NO WRITES.  The first cycle of the parity loop is
    // a read and it is answered; the write that follows it is taken and never
    // acknowledged, and the adapter waits in WRESP for the rest of the run,
    // so nothing further reaches the port at all.  What matters is not the
    // numbers themselves but that they DIFFER: a tally with its directions
    // crossed reads 0 and 1 here where a correct one reads 1 and 0.
    Check(r.answered_reads == 1,
          "%s: the tally counted %ld reads answered, wanting 1", name,
          r.answered_reads);
    Check(r.answered_writes == 0,
          "%s: the tally counted %ld writes answered on a channel that was "
          "never acknowledged", name, r.answered_writes);
    Check(r.b_handshakes == 0,
          "%s: %ld B handshakes happened on a channel the slave never "
          "answered", name, r.b_handshakes);
    Check(r.r_handshakes == 1 && r.reads_fetched == 1,
          "%s: %ld last-beat R handshakes and %ld beats fetched, wanting 1 "
          "and 1", name, r.r_handshakes, r.reads_fetched);
    Check(r.answered_reads != r.answered_writes,
          "%s: the two directions read the same, so nothing here can tell a "
          "tally whose directions are crossed from one that is not", name);
  } else {
    // **THE READING THE INSTRUMENT EXISTS FOR.** Nothing was answered, and
    // the tally says so, on a machine that asked for exactly as much as it
    // asks for when the port works.
    Check(r.answered_reads == 0,
          "%s: the tally counted %ld reads answered on a port that answers "
          "nothing", name, r.answered_reads);
    Check(r.answered_writes == 0,
          "%s: the tally counted %ld writes answered on a port that answers "
          "nothing", name, r.answered_writes);
    Check(r.b_handshakes == 0 && r.r_handshakes == 0,
          "%s: %ld B and %ld R handshakes happened at a port held in reset",
          name, r.b_handshakes, r.r_handshakes);
    Check(!r.any_request,
          "%s: the adapter put a request on the port while it was held in "
          "reset", name);
  }

  // THE MACHINE IS STILL RUNNING either way. It waits on a drive that is not
  // there --- `rtl/machine/cadr_disk_controller.sv` answers the polls and its status
  // says not on line --- and will do so for ever; what it must not do is
  // halt.
  Check(kTicks - r.last_edge_tick < 2000,
        "%s: the last clock edge was at tick %ld of %ld, %ld ticks back, so "
        "the machine is not running at the end", name, r.last_edge_tick,
        kTicks, kTicks - r.last_edge_tick);
  Check(r.final_pc != 040, "%s: the machine ended at PC 40, ERROR-DISK-ERROR",
        name);

  std::printf("  microcycles       %ld, first memory cycle at %ld\n", r.micro,
              r.first_req_micro);
  std::printf("  EMIO              %08x %08x  (DATA_3_RO, DATA_2_RO)\n",
              static_cast<uint32_t>(r.gpio >> 32),
              static_cast<uint32_t>(r.gpio));
  std::printf("  asked             %ld reads, %ld writes  (mem_req rose %ld "
              "times)\n", r.asked_reads, r.asked_writes, r.req_rises);
  std::printf("  answered          %ld reads, %ld writes\n",
              r.answered_reads, r.answered_writes);
  std::printf("  at the port       %ld AW, %ld B, %ld AR, %ld last-beat R\n",
              r.aw_handshakes, r.b_handshakes, r.ar_handshakes,
              r.r_handshakes);
  std::printf("  the slave's books %ld beats committed, %ld fetched\n",
              r.writes_committed, r.reads_fetched);
  std::printf("  NXM timeouts      %ld\n", r.timeouts);
  std::printf("  final PC          %lo, still running at tick %ld\n",
              r.final_pc, r.last_edge_tick);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  {
    std::set<uint32_t> seen;
    for (int i = 0; i < kWindowWords; ++i) seen.insert(Poison(i));
    Check(seen.size() == static_cast<size_t>(kWindowWords),
          "the poison collides: %zu distinct words for %d addresses",
          seen.size(), kWindowWords);
    for (int i = 0; i < kPageWords; ++i)
      Check((Poison(i) & 1u) == 0, "poison word %d has bit 0 set", i);
  }

  Run live = Simulate(kLive);
  CheckRun(live, kLive);
  Run dead = Simulate(kDead);
  CheckRun(dead, kDead);
  Run half = Simulate(kHalf);
  CheckRun(half, kHalf);

  // AND THE TWO RUNS ASKED FOR THE SAME THING, which is the sentence the
  // whole instrument rests on: what separates a board with memory from a
  // board without it is not what the machine did, it is what came back.
  std::printf("\nLIVE against DEAD\n");
  Check(live.asked_reads == dead.asked_reads &&
            live.asked_writes == dead.asked_writes,
        "the machine asked for %ld/%ld with the port live and %ld/%ld with it "
        "dead", live.asked_reads, live.asked_writes, dead.asked_reads,
        dead.asked_writes);
  Check(live.answered_reads != dead.answered_reads ||
            live.answered_writes != dead.answered_writes,
        "the tally reads the same with the port live and dead, so it cannot "
        "tell a memory that answered from one that did not");
  std::printf("  asked      %ld reads and %ld writes either way\n",
              live.asked_reads, live.asked_writes);
  std::printf("  answered   %ld/%ld live, %ld/%ld dead --- which is the "
              "difference a board is read for\n",
              live.answered_reads, live.answered_writes, dead.answered_reads,
              dead.answered_writes);
  std::printf("  and %ld/%ld on a port deaf to writes, which is the only "
              "reading here where the two directions differ\n",
              half.answered_reads, half.answered_writes);

  if (fails) {
    std::fprintf(stderr, "\n%d failure%s\n", fails, fails == 1 ? "" : "s");
    return 1;
  }
  std::printf("\nok\n");
  return 0;
}
