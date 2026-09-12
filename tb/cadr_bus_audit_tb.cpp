// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ONE TRANSACTION PER BUS CYCLE, AND ITS DIRECTION IS THE PROCESSOR'S.
//
// The check the board's own bug has been living behind.  CLAUDE.md's account,
// in one paragraph: a word in MIT's page hash table is the faulting virtual
// address rather than a page table word; MD is exonerated by measurement, so
// main memory already held it, so the corruption is a WRITE that should not
// have happened; and `cadr_microcycle.sv` loads `wdata` from MD at MEMGO
// REGARDLESS OF DIRECTION, so on every read the whole of MD is standing on
// `mem_wdata` at the bridge.  One unwanted write therefore replaces a memory
// word with MD, at the read's own address, and neither the machine nor the
// microcode can tell afterwards.
//
// The shape that fits is an EXTRA transaction beside a correct one, and
// nothing in this repository counted transactions per bus cycle.
//
// WHAT THE NEIGHBOURING CHECKS DO AND DO NOT SEE, measured rather than
// asserted, by aiming each of this check's five records at every other check
// that builds the same file.  `tb/cadr_axi_master_tb.cpp` DOES catch an extra
// transaction born inside the adapter --- two of the five --- and it was wrong
// to say otherwise; what it cannot do is see one born above the adapter, its
// stimulus being the requests themselves, or say anything at all about WRCYC
// or about which cycles the decode called main memory, having no processor and
// no decode.  `tb/cadr_mem_count_tb.cpp` catches the same two, by holding the
// run's totals to 256 and 256 --- which is the boot PROM's own arithmetic and
// not a property, and is exactly what cannot be done on a board.  And the
// three checks whose business main memory IS --- `memory_path`, `machine`,
// `ddr_boot` --- all pass over a device write that also lands in real memory,
// which is the record `a-device-write-is-also-written-to-main-memory` and the
// nearest thing in the tree to the board's own symptom.
//
// WHAT IS HELD HERE, in four clauses.  The DUT is
// `tb/cadr_bus_audit_harness.sv`: `cadr_machine`, `cadr_axi_master` and
// `cadr_axi_widen`, wired as `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr` wires
// them, with a 64-bit AXI3 slave modelled here.
//
//   1  ONE ANSWER PER REQUEST.  Every rise of `mem_req` is followed by exactly
//      one transaction completed and then by `mem_req` falling.  No request is
//      answered twice and none is left unanswered.
//
//   2  ONE TRANSACTION PER REQUEST, AT THE PORT.  Between a rise of `mem_req`
//      and its fall the AXI address channels see exactly one handshake --- AR
//      for a read, AW for a write --- and none of the other kind.  And NO
//      address handshake happens while `mem_req` is low, which is the clause a
//      transaction invented downstream of the bridge falls over.
//
//   3  THE DIRECTION IS THE PROCESSOR'S OWN.  The channel a transaction goes
//      out on is compared against `wrcyc` --- `cadr_microcycle.sv` calls that
//      pair "one flip flop, the 74S175 at 1C23 on CLK2A", loaded at the
//      microcycle that starts the cycle and held for the whole of it.
//
//      HALF OF THIS CLAUSE IS ALREADY `tb/cadr_md_compose_tb.cpp`'S, and this
//      file builds BESIDE that one rather than extending it.  That check
//      compares `mem_write` against `wrcyc` at the port and found 0 of 512
//      wrong; the same comparison is made here, and then made AGAIN at the AXI
//      address channel, which is what puts the adapter and the widening inside
//      the claim.  Keeping both is deliberate and costs one line: with the two
//      of them, a direction that is right at the port and wrong at the channel
//      is localised to the adapter rather than merely reported.  And
//      `md_compose`'s subject is MD's staleness, not the port; none of that is
//      repeated here.
//
//   4  A CYCLE THAT IS NOT MAIN MEMORY'S ISSUES NOTHING AT ALL.  Measured over
//      the run this check makes: 88,695 cycles to the disk controller's four
//      registers, two to empty Xbus space and one to the Unibus, against 512
//      to main memory.  Every one of the 88,698 must leave the memory port
//      silent, so this clause is exercised a hundred and seventy-three times
//      harder than the memory clause is --- which is the opposite of what it
//      sounds like, because what the program does most of is what a spurious
//      transaction would most likely ride on.
//
// THE ANCHOR IS THE PROCESSOR'S OWN CYCLE AND NEVER THE BRIDGE'S.  CLAUDE.md's
// shadow-memory rule: a check keyed by the thing under test moves with the
// bug.  A bus cycle here is a rise of MBUSY, which `cadr_microcycle.sv` sets
// at MEMGO and clears MFINISHD_T ticks after -MEMACK; `nxm`, `unibus` and
// `device` say what the decode made of the address, and `wrcyc` says the
// direction.  All four are the processor's, upstream of every module this
// check is about.
//
// THE MODEL MEMORY IS KEYED BY THE SLAVE'S OWN BEAT ADDRESS, poisoned
// injectively, so a transaction that lands somewhere else lands somewhere this
// program can name.  What it CANNOT do is worth saying at the top: on
// PAGE-0-PARITY-FIX a spurious write at a read's own address is overwritten by
// the legitimate write that follows it in the same loop iteration, so page 0
// reads back correct either way.  The counts are what see it, not the data.
//
// AND WHAT THIS CHECK CANNOT DO AT ALL.  The boot PROM is the only program
// `cadr_machine` can run in simulation and it makes 512 main-memory cycles.
// The board's event is one in about a hundred and seventy-six million
// microcycles.  So green here does not mean the board is clean; it means the
// property holds for the one program we can run, and the instrument that could
// answer for the board is fabric-side.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

#include "Vcadr_bus_audit_harness.h"
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

// The poison, injective in the word address and with bit 0 clear --- bit 0 of
// what a read returns is what the boot PROM's disk poll takes for "ready".
// Words past page 0 differ from their page-0 twin in the top byte.
uint32_t Poison(int word) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>((word % kPageWords) + 1)) ^
               0xA5A5A5A5u;
  p &= ~1u;
  p ^= static_cast<uint32_t>(word / kPageWords) << 24;
  return p;
}

// A small deterministic sequence for the handshake delays.
uint32_t Next(uint32_t &s) {
  s = s * 1103515245u + 12345u;
  return (s >> 16) & 0x7FFFu;
}

// One processor bus cycle, from the rise of MBUSY to its fall.
struct Cycle {
  long micro = 0;
  long tick = 0;
  int write = 0;      // WRCYC, held from the microcycle that started it
  int device = 0, unibus = 0, nxm = 0;
  uint32_t phys = 0, vma = 0, md = 0;
  long reqs = 0;      // rises of mem_req inside it
  long aw = 0, ar = 0;   // address handshakes inside it
};

struct Run {
  // What the machine did.
  long micro = 0, timeouts = 0, final_pc = 0;
  long cycles = 0, mem_cycles = 0, dev_cycles = 0, ub_cycles = 0, nxm_cycles = 0;
  long read_cycles = 0, write_cycles = 0;

  // What the port did.
  long req_rises = 0, req_read_rises = 0, req_write_rises = 0;
  long aw_handshakes = 0, ar_handshakes = 0;
  long w_handshakes = 0, b_handshakes = 0, r_handshakes = 0;
  long done_seen = 0;

  // The four clauses, each counted so that a zero can be read.
  long answers_per_request_wrong = 0;
  long transactions_per_request_wrong = 0;
  long transactions_outside_a_request = 0;
  long direction_wrong = 0;
  long transactions_on_a_non_memory_cycle = 0;
  long requests_on_a_non_memory_cycle = 0;
  long requests_per_cycle_wrong = 0;

  // Guards: a clause that never applied passed by not running.
  long requests_inside_a_cycle = 0;
  long channel_took_the_bus = 0;

  // Where the transactions landed.
  long misaligned = 0, outside_window = 0, bad_strobes = 0;
  long writes_committed = 0, reads_fetched = 0;

  // The word on the write-data lines during a read, which is the fabric fact
  // that makes a spurious write catastrophic.  Counted, not asserted: it is
  // the reason this check exists and not a thing it holds to.
  long read_carried_md = 0;

  std::map<long, long> reqs_per_cycle;   // histogram, for the report
  std::vector<uint32_t> mem;
  std::vector<uint32_t> page0_at_end;
};

Run Simulate() {
  Run out;
  out.mem.resize(kWindowWords);
  for (int i = 0; i < kWindowWords; ++i) out.mem[i] = Poison(i);

  auto *dut = new Vcadr_bus_audit_harness;
  dut->clk = 0;
  dut->rst = 1;
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
  int to_last = 0, mbusy_last = 0;

  // The request window: open from the rise of `mem_req` to its fall.
  bool in_request = false;
  int req_write = 0;
  uint32_t req_addr = 0;
  long req_aw = 0, req_ar = 0, req_done = 0;
  long req_tick = 0;

  // The processor's own cycle, open from the rise of MBUSY to its fall.
  bool in_cycle = false;
  Cycle cyc;

  for (long t = 0; t < kTicks; ++t) {
    dut->rst = (t < 8);

    // ------------------------------------------------------------ the slave
    if (!dut->rst) {
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
      dut->hp0_awready = dut->hp0_wready = dut->hp0_arready = 0;
      dut->hp0_bvalid = dut->hp0_rvalid = 0;
      dut->hp0_rlast = 0;
    }

    // WHAT THE EDGE SAW, SAMPLED BEFORE IT.  `eval()` at the rising edge
    // recomputes everything combinational from the new registers, so a
    // handshake read afterwards is the next tick's.
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
    // The port's own boundary, sampled in the same breath as the handshakes
    // so that "inside a request" is decided by the same tick's values.
    const int s_req = dut->mem_req, s_req_write = dut->mem_write;
    const uint32_t s_req_addr = dut->mem_addr;
    const uint32_t s_req_wdata = dut->mem_wdata;
    const int s_done = dut->mem_done;
    const int s_md_on_the_lines = (dut->mem_wdata == dut->md);

    dut->clk = 1;
    dut->eval();

    if (!dut->rst) {
      // ------------------------------------------- the processor's own cycle
      //
      // MBUSY rises at MEMGO and falls MFINISHD_T ticks after -MEMACK.  Read
      // AFTER the edge, so `wrcyc`, `device`, `unibus` and `nxm` are the
      // values this cycle runs with.
      const int mbusy = dut->mbusy;
      if (mbusy && !mbusy_last) {
        cyc = Cycle();
        cyc.micro = out.micro;
        cyc.tick = t;
        cyc.write = dut->wrcyc;
        cyc.device = dut->device;
        cyc.unibus = dut->unibus;
        cyc.nxm = dut->nxm;
        cyc.phys = dut->phys;
        cyc.vma = dut->vma;
        cyc.md = dut->md;
        in_cycle = true;
        ++out.cycles;
        if (cyc.write) ++out.write_cycles; else ++out.read_cycles;
        if (cyc.device) ++out.dev_cycles;
        else if (cyc.unibus) ++out.ub_cycles;
        else if (cyc.nxm) ++out.nxm_cycles;
        else ++out.mem_cycles;
      }

      // ------------------------------------------------- the port's request
      if (s_req && !req_last) {
        ++out.req_rises;
        if (s_req_write) ++out.req_write_rises; else ++out.req_read_rises;
        in_request = true;
        req_write = s_req_write;
        req_addr = s_req_addr;
        req_aw = req_ar = req_done = 0;
        req_tick = t;
        if (!s_req_write && s_md_on_the_lines) ++out.read_carried_md;
        // CLAUSE 3, AT THE REQUEST.  The direction the bridge asks for must be
        // the one the processor's own flip flop holds.
        if ((s_req_write != 0) != (dut->wrcyc != 0)) {
          ++out.direction_wrong;
          Check(false,
                "microcycle %ld tick %ld: the port asks for a %s at %08x while "
                "WRCYC says %s",
                out.micro, t, s_req_write ? "write" : "read", s_req_addr,
                dut->wrcyc ? "write" : "read");
        }
        if (in_cycle) {
          ++cyc.reqs;
          ++out.requests_inside_a_cycle;
          // CLAUSE 4.  A cycle the decode did not call main memory must leave
          // the memory port silent.
          if (cyc.device || cyc.unibus || cyc.nxm) {
            ++out.requests_on_a_non_memory_cycle;
            Check(false,
                  "microcycle %ld tick %ld: a %s cycle at physical %o asked "
                  "the memory port for %08x",
                  out.micro, t,
                  cyc.device ? "device" : (cyc.unibus ? "Unibus" : "NXM"),
                  cyc.phys, s_req_addr);
          }
        }
      }
      if (!s_req && req_last && in_request) {
        // CLAUSE 1 and CLAUSE 2, closed at the fall of the request.
        if (req_done != 1) {
          ++out.answers_per_request_wrong;
          Check(false,
                "microcycle %ld: the request raised at tick %ld was answered "
                "%ld times",
                out.micro, req_tick, req_done);
        }
        const long want_aw = req_write ? 1 : 0;
        const long want_ar = req_write ? 0 : 1;
        if (req_aw != want_aw || req_ar != want_ar) {
          ++out.transactions_per_request_wrong;
          Check(false,
                "microcycle %ld: the %s raised at tick %ld for %08x issued "
                "%ld write and %ld read transactions, wanting %ld and %ld",
                out.micro, req_write ? "write" : "read", req_tick, req_addr,
                req_aw, req_ar, want_aw, want_ar);
        }
        in_request = false;
      }
      req_last = s_req != 0;

      if (s_done) ++out.done_seen;

      // ------------------------------------------------------- the handshakes
      if (s_awvalid && s_awready) {
        ++out.aw_handshakes;
        aw_taken = true;
        aw_addr = s_awaddr;
        ++req_aw;
        if (in_cycle) ++cyc.aw;
        // CLAUSE 2's other half, and the one a transaction invented downstream
        // of the bridge falls over.
        if (!in_request) {
          ++out.transactions_outside_a_request;
          Check(false,
                "microcycle %ld tick %ld: a write to %08x went out with no "
                "request standing at the memory port",
                out.micro, t, s_awaddr);
        }
        if (in_cycle && (cyc.device || cyc.unibus || cyc.nxm)) {
          ++out.transactions_on_a_non_memory_cycle;
        }
        // CLAUSE 3, at the channel: the direction is decided here by WHICH
        // channel the transaction went out on, so the adapter and the widening
        // are inside the claim.
        if (!dut->wrcyc) {
          ++out.direction_wrong;
          Check(false,
                "microcycle %ld tick %ld: a WRITE of %016" PRIx64 " went to "
                "%08x on a cycle whose WRCYC is clear",
                out.micro, t, s_wdata, s_awaddr);
        }
      }
      if (s_wvalid && s_wready) {
        ++out.w_handshakes;
        w_taken = true;
        w_data = s_wdata;
        w_strb = s_wstrb;
      }
      if (s_arvalid && s_arready) {
        ++out.ar_handshakes;
        ar_taken = true;
        ar_addr = s_araddr;
        ++req_ar;
        if (in_cycle) ++cyc.ar;
        if (!in_request) {
          ++out.transactions_outside_a_request;
          Check(false,
                "microcycle %ld tick %ld: a read of %08x went out with no "
                "request standing at the memory port",
                out.micro, t, s_araddr);
        }
        if (in_cycle && (cyc.device || cyc.unibus || cyc.nxm)) {
          ++out.transactions_on_a_non_memory_cycle;
        }
        if (dut->wrcyc) {
          ++out.direction_wrong;
          Check(false,
                "microcycle %ld tick %ld: a READ of %08x went out on a cycle "
                "whose WRCYC is set",
                out.micro, t, s_araddr);
        }
      }

      // The write commits when both halves have been taken, to the address
      // THIS PROGRAM was given rather than to anything the DUT says it meant.
      if (aw_taken && w_taken && b_wait < 0) {
        const long w0 =
            (static_cast<long>(aw_addr) - static_cast<long>(kMainBase)) / 4;
        if ((aw_addr & 7u) != 0) ++out.misaligned;
        if (w0 < 0 || w0 + 1 >= kWindowWords) {
          ++out.outside_window;
        } else {
          uint64_t beat =
              (static_cast<uint64_t>(out.mem[w0 + 1]) << 32) | out.mem[w0];
          for (int b = 0; b < 8; ++b) {
            if (w_strb & (1u << b)) {
              const uint64_t m = 0xFFULL << (8 * b);
              beat = (beat & ~m) | (w_data & m);
            }
          }
          out.mem[w0] = static_cast<uint32_t>(beat);
          out.mem[w0 + 1] = static_cast<uint32_t>(beat >> 32);
        }
        if (w_strb != 0x0Fu && w_strb != 0xF0u) ++out.bad_strobes;
        ++out.writes_committed;
        b_wait = 1 + static_cast<int>(Next(seed) % 5);
      }
      if (b_wait > 0) --b_wait;
      if (b_wait == 0 && !dut->hp0_bvalid) {
        dut->hp0_bvalid = 1;
        dut->hp0_bresp = 0;
      }
      if (s_bvalid && s_bready) {
        ++out.b_handshakes;
        ++req_done;
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
        const long w0 =
            (static_cast<long>(ar_addr) - static_cast<long>(kMainBase)) / 4;
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
        if (s_rlast) {
          ++out.r_handshakes;
          ++req_done;
        }
        dut->hp0_rvalid = 0;
        dut->hp0_rlast = 0;
        r_wait = -1;
        ar_taken = false;
        ar_delay = static_cast<int>(Next(seed) % 5);
      }

      // The cycle closes.
      if (!mbusy && mbusy_last && in_cycle) {
        ++out.reqs_per_cycle[cyc.reqs];
        const long want = (cyc.device || cyc.unibus || cyc.nxm) ? 0 : 1;
        if (cyc.reqs != want) {
          ++out.requests_per_cycle_wrong;
          Check(false,
                "microcycle %ld: the %s bus cycle at physical %o (VMA %o) "
                "asked the memory port %ld times, wanting %ld",
                cyc.micro, cyc.write ? "write" : "read", cyc.phys,
                cyc.vma, cyc.reqs, want);
        }
        in_cycle = false;
      }
      mbusy_last = mbusy;

      if (dut->ch_active) ++out.channel_took_the_bus;
    }

    if (dut->clock_edge) ++out.micro;
    if (dut->timed_out && !to_last) ++out.timeouts;
    to_last = dut->timed_out;

    dut->clk = 0;
    dut->eval();
  }

  out.final_pc = dut->pc;
  out.page0_at_end.assign(out.mem.begin(), out.mem.begin() + kPageWords);
  dut->final();
  delete dut;
  return out;
}

void Report(const Run &r) {
  std::printf("bus audit: %ld microcycles, PC %o at the end, %ld timeouts\n",
              r.micro, static_cast<unsigned>(r.final_pc), r.timeouts);
  std::printf("  processor bus cycles   %ld"
              "  (memory %ld, device %ld, Unibus %ld, NXM %ld)\n",
              r.cycles, r.mem_cycles, r.dev_cycles, r.ub_cycles, r.nxm_cycles);
  std::printf("  of them                %ld reads, %ld writes\n",
              r.read_cycles, r.write_cycles);
  std::printf("  memory port requests   %ld  (%ld reads, %ld writes)\n",
              r.req_rises, r.req_read_rises, r.req_write_rises);
  std::printf("  AXI address handshakes %ld AR, %ld AW\n",
              r.ar_handshakes, r.aw_handshakes);
  std::printf("  AXI answers            %ld R-last, %ld B, %ld W\n",
              r.r_handshakes, r.b_handshakes, r.w_handshakes);
  std::printf("  the slave's own books  %ld reads fetched, %ld writes "
              "committed\n", r.reads_fetched, r.writes_committed);
  std::printf("  reads whose write-data lines carried MD: %ld of %ld\n",
              r.read_carried_md, r.req_read_rises);
  std::printf("  requests per bus cycle:");
  for (const auto &kv : r.reqs_per_cycle)
    std::printf(" %ld:%ld", kv.first, kv.second);
  std::printf("\n");
}

void CheckRun(const Run &r) {
  // THE GUARDS FIRST.  A clause that never applied passed by not running, and
  // this check has four of them.
  Check(r.cycles > 0, "the machine ran no bus cycle at all");
  Check(r.mem_cycles == kWantReads + kWantWrites,
        "%ld main-memory bus cycles, wanting %d", r.mem_cycles,
        kWantReads + kWantWrites);
  Check(r.dev_cycles > 1000,
        "only %ld device bus cycles: clause 4 is not being exercised",
        r.dev_cycles);
  Check(r.requests_inside_a_cycle == r.req_rises,
        "%ld of the %ld memory-port requests fell outside a processor bus "
        "cycle, so the audit's anchor is not the anchor",
        r.req_rises - r.requests_inside_a_cycle, r.req_rises);
  Check(r.channel_took_the_bus == 0,
        "the disk channel took the bus on %ld ticks: the accounting here is "
        "the processor's and does not apply",
        r.channel_took_the_bus);
  // A read whose write-data lines did NOT carry MD would mean the fabric fact
  // this check was written around has changed, and the check should be read
  // again before it is believed.
  Check(r.read_carried_md == r.req_read_rises,
        "%ld of %ld reads carried MD on the write-data lines: "
        "`cadr_microcycle.sv` no longer loads `wdata` at MEMGO regardless of "
        "direction, and this check's reason for existing has moved",
        r.read_carried_md, r.req_read_rises);

  // CLAUSE 1.
  Check(r.answers_per_request_wrong == 0,
        "%ld memory-port requests were answered other than exactly once",
        r.answers_per_request_wrong);
  // CLAUSE 2.
  Check(r.transactions_per_request_wrong == 0,
        "%ld memory-port requests issued other than exactly one transaction "
        "of their own direction", r.transactions_per_request_wrong);
  Check(r.transactions_outside_a_request == 0,
        "%ld AXI transactions went out with no request standing",
        r.transactions_outside_a_request);
  Check(r.requests_per_cycle_wrong == 0,
        "%ld processor bus cycles asked the memory port other than the number "
        "of times the decode says they should have",
        r.requests_per_cycle_wrong);
  // CLAUSE 3.
  Check(r.direction_wrong == 0,
        "%ld transactions went out in the direction the processor's own WRCYC "
        "does not name", r.direction_wrong);
  // CLAUSE 4.
  Check(r.requests_on_a_non_memory_cycle == 0,
        "%ld bus cycles the decode did not call main memory reached the "
        "memory port", r.requests_on_a_non_memory_cycle);
  Check(r.transactions_on_a_non_memory_cycle == 0,
        "%ld AXI transactions went out on a bus cycle the decode did not call "
        "main memory", r.transactions_on_a_non_memory_cycle);

  // THE TOTALS RECONCILE, which is the same property read from the other end.
  Check(r.ar_handshakes == r.req_read_rises,
        "%ld read transactions against %ld read requests", r.ar_handshakes,
        r.req_read_rises);
  Check(r.aw_handshakes == r.req_write_rises,
        "%ld write transactions against %ld write requests", r.aw_handshakes,
        r.req_write_rises);
  Check(r.r_handshakes == r.ar_handshakes,
        "%ld read answers against %ld read transactions", r.r_handshakes,
        r.ar_handshakes);
  Check(r.b_handshakes == r.aw_handshakes,
        "%ld write answers against %ld write transactions", r.b_handshakes,
        r.aw_handshakes);
  Check(r.w_handshakes == r.aw_handshakes,
        "%ld write-data beats against %ld write transactions", r.w_handshakes,
        r.aw_handshakes);
  Check(r.req_read_rises == kWantReads && r.req_write_rises == kWantWrites,
        "%ld reads and %ld writes asked for, wanting %d and %d",
        r.req_read_rises, r.req_write_rises, kWantReads, kWantWrites);

  // WHERE THEY LANDED.
  Check(r.misaligned == 0, "%ld transactions at an address that is not a "
        "64-bit beat", r.misaligned);
  Check(r.outside_window == 0, "%ld transactions outside the modelled window",
        r.outside_window);
  Check(r.bad_strobes == 0, "%ld writes whose strobes were not one half of a "
        "beat", r.bad_strobes);

  // AND THE PROGRAM'S OWN PROPERTY.  PAGE-0-PARITY-FIX reads each word and
  // writes the same word straight back, so page 0 must end as it began.  It is
  // here as a control and not as the check: a spurious write at a READ's own
  // address is overwritten by the legitimate write that follows it in the same
  // loop iteration, so this clause cannot see the fault the counts see.
  long moved = 0;
  for (int i = 0; i < kPageWords; ++i)
    if (r.page0_at_end[i] != Poison(i)) ++moved;
  Check(moved == 0, "%ld of page 0's %d words are not what the poison put "
        "there", moved, kPageWords);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const Run r = Simulate();
  Report(r);
  // The failures go to stderr and the report to stdout, so without this the
  // two arrive in the wrong order and the numbers a failure has to be read
  // against come after it.
  std::fflush(stdout);
  CheckRun(r);
  if (fails) {
    std::fprintf(stderr, "bus audit: %d failure%s\n", fails,
                 fails == 1 ? "" : "s");
    return 1;
  }
  std::printf("bus audit: ok --- one transaction per bus cycle, in the "
              "direction WRCYC names, and none anywhere else\n");
  return 0;
}
