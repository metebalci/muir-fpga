// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The machine behind real memory: `cadr_machine` with a modelled DDR3 behind
// `mem_*`, running MIT's boot PROM from reset.
//
// WHY THIS EXISTS AND WHY MUIR IS NOT THE REFERENCE.  Every other check here
// is held to muir, against a trace.  This one runs 200 ms of machine time ---
// 862,932 microcycles --- and the boot PROM trace is 600,000 rows, so past
// that there is no reference to be held to whatever the fabric does.  muir
// has no column for a word in DDR either.  So step four --- the machine with
// DDR behind it, which is what `DDR=1` puts on the part --- needs a
// simulation reference of its own, and this is it.
//
// **THAT PARAGRAPH USED TO SAY THE TWO MACHINES PART COMPANY AT MICROCYCLE
// 537,900 BECAUSE THE BOARD HAD NO DISK CONTROLLER, AND THAT IS NO LONGER
// TRUE.**  `rtl/machine/cadr_disk_controller.sv` is inside `cadr_machine` now and
// answers the boot PROM's 16,951 polls with the same `0x2321` muir's does, so
// the board's machine and muir's no-drive machine run the same program for as
// far as either is asked to.  The parting that remains is the DRIVE: muir's
// `rtl_sys` engine attaches one and diverges at microcycle 537,857, and this
// fabric has none.
//
// WHAT MUIR STILL BACKS, and it is the whole of the claim this check pins:
// `promh.text`'s PAGE-0-PARITY-FIX reads each of the 256 words of page 0 and
// writes the same word straight back to refresh parity, never looking at the
// data.  That is the boot PROM's ONLY main-memory traffic --- 512 bus cycles,
// one read and one write to each of physical 0..377 --- and
// `build/machine.pass` holds those same 512 cycles against muir microcycle
// for microcycle, -MEMACK included.  This check adds what muir has no column
// for: real words crossing `mem_*`, a memory that answers at a delay of its
// own, and what the machine does after muir has stopped being able to say.
//
// AN IDENTITY COPY AGAINST ZEROED MEMORY TESTS NOTHING.  CLAUDE.md's
// control-store entry verbatim: the loop writes back what it read, so against
// memory that comes up zero a bridge that never wrote reads back exactly like
// one that did.  So page 0 is poisoned from outside, injectively in the
// address --- and the injectivity is ASSERTED below rather than claimed,
// because a poison with a collision in it tests less than it looks like it
// does.
//
// THE TWO CONFIGURATIONS, AND WHY THE SECOND ASSERTS THAT NOTHING HAPPENS.
// Configuration A poisons page 0 with bit 0 clear in all 256 words.
// Configuration B is the same poison with bit 0 SET in word 255, the last
// word the parity loop touches, and asserts that the machine does not notice:
// the same 512 transactions to the same addresses, no 513th, page 0 back to
// its poison, the same microcycle count, the same timeouts, the machine still
// running at the end.  The two runs are compared to each other, column for
// column, and the only difference allowed anywhere is the one bit in the one
// word.
//
// THAT ASSERTION IS THE POINT, AND IT IS RECENT.  Before `cadr_xbus_ddr.sv`
// cleared its `rdata` register between cycles, an unanswered read strobed MD
// with whatever the bridge last returned --- `cadr_memory_path.sv` falls
// through to `memory_rdata` when nothing acknowledges --- so after the parity
// loop every one of the boot PROM's 16,951 disk polls read back the last word
// of page 0.  (The polls are answered now and no longer go through that
// fall-through at all, which does not retire the assertion: what it holds is
// that page 0's contents must not steer the machine, and the two cycles to
// empty Xbus space still take the unanswered path.)  Bit 0 of that word is what the PROM's JUMP-IF-BIT-CLEAR takes
// for "the disk controller is ready", so configuration B's poison made the
// machine write a CCW to physical 777 and halt at PC 40, ERROR-DISK-ERROR,
// with the clock frozen.  Measured, and then decided against: **an unanswered
// read gives MD zero.**  What page 0 happens to hold must not steer the
// machine, and configuration B is what says it does not.
//
// WHAT THAT COSTS STEP FOUR, said here rather than left to be wondered at.
// The halt was going to be the board's end-to-end witness that the WRITE path
// issues at all, because an identity copy cannot show that on its own: every
// write in the loop carries the word already at that address, so a bridge
// that never wrote reads back exactly like one that did, on the board as in
// simulation.  That witness is gone by decision.  The write path stands
// instead on step two of the board plan, which put the fabric's own word into
// real DDR through this same adapter and had the debugger read it back ---
// PROVE=1, passed on silicon at `51bc74a`, with the observer outside the
// design.  What this check still holds about writes is the address sequence,
// the direction, and the word: 256 writes, one to each address, each carrying
// the word its own read returned.
//
// THE MEMORY ANSWERS AT A DELAY THAT VARIES.  A fixed latency would let a
// bridge that assumed one pass.  The model answers `4 + (n * 7) % 23` ticks
// after the request first stands --- 20 to 130 ns, every one of them well
// inside the interface's 4.25 us timeout, and consecutive cycles never the
// same.  The machine's microcycle COUNT does not depend on it: a stall costs
// time and not a microcycle, so the microcycle numbers asserted below are
// invariant under the latency schedule while the tick numbers are not.  That
// is why the microcycles are what is pinned.
//
// WHAT IS HELD ABOUT -MEMACK, AND WHAT IS NOT.  muir's own instants are not
// reachable from here: `IDEAL_DEVICE_NS = 0`, so muir's responder answers a
// main-memory cycle at the setup boundary and this DDR answers somewhere muir
// never put it.  What is reachable is the RULE those instants obey --- a
// write is acknowledged at the answer by the 74S64 gate at REQLM 0C11, a read
// XBUS_ACK_NS later through the 60 ns tap of the TD100 at 0C09 --- and that
// is asserted here on every one of the 512, at delays muir never exercised.
//
// WHAT DRIVES THE DUT.  Nothing nearer than `mem_req`/`mem_done`, exactly as
// `boards/arty-z7-20/cadr_arty.sv` wires it with `DDR=1`: no interrupt, no Xbus device, 32
// boards of memory declared.  `mem_rdata` is held at a word with bit 0 SET
// whenever the model is not answering, so a bridge that latched at the wrong
// instant would take a word the PROM reads as a ready disk --- poison, never
// data.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <vector>

#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

// cadr_ddr_map::MAIN_BASE, and the page the parity loop walks.
constexpr uint32_t kMainBase = 0x18000000u;
constexpr int kPageWords = 256;
// Sixteen times wider than page 0, so a transaction that lands off the page
// still lands somewhere this program can name and compare rather than merely
// count.  Physical 777 --- where the machine used to put a CCW --- is word
// 511 of it.
constexpr int kWindowWords = 4096;

// WHERE -MEMACK IS DUE, in ticks after the tick this harness saw the slave's
// answer in.  A write is a gate --- the 74S64 at REQLM 0C11 --- so it is the
// same tick, zero.  A read waits DESKEW_T, the 60 ns tap of the TD100 at
// 0C09, which is twelve ticks; **it reads as eleven here and the missing tick
// is the instrument, not the fabric.**  `answered_at` is `elapsed` sampled at
// the edge that captures the answer, and `elapsed` has already advanced past
// that value by the time the deskew's comparison first runs, so the twelve
// ticks are counted from one tick after the answer was seen.  The same
// one-tick offset is written up at greater length in
// `tb/cadr_machine_tb.cpp`, which observes -MEMACK the same way.
//
// The CONSTANT is not this check's to hold: `build/busint_xbus.pass` holds
// the interface to muir tick for tick and the deskew with it.  What is held
// here is the SHAPE, at answer instants muir never placed --- that a write is
// acknowledged in the tick of its answer whatever the delay was, and a read a
// fixed deskew later.
constexpr int kAckAfterWrite = 0;
constexpr int kAckAfterRead = 60 / 5 - 1;

// The word the model holds on `mem_rdata` when it is not answering.  Bit 0 is
// set on purpose, and it is not any word of the poison.
constexpr uint32_t kNotAnswering = 0xDEADBEE5u;

// 200 ms of machine time, the horizon `tb/cadr_nomem_tb.cpp` uses.  The
// parity loop closes at about 118 ms, so this is 82 ms of afterwards.
constexpr long kTicks = 40000000L;

// The parity loop's own microcycles, invariant under the latency schedule.
constexpr long kFirstReqMicro = 536303;

uint32_t Poison(int word, bool bit0_in_last) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>((word % kPageWords) + 1)) ^
               0xA5A5A5A5u;
  p &= ~1u;
  // Words past page 0 differ from their page-0 twin in the top byte, so a
  // transaction that strays off the page is not mistaken for one that did not.
  p ^= static_cast<uint32_t>(word / kPageWords) << 24;
  if (bit0_in_last && word == kPageWords - 1) p |= 1u;
  return p;
}

// One request the bridge made, as the model saw it.
struct Txn {
  long tick;
  long micro;
  uint32_t addr;
  bool write;
  uint32_t data;      // what was written, or what was returned
  long ack_delay;     // ticks from the answer to -MEMACK falling, -1 if none
};

struct Run {
  std::vector<Txn> txns;
  std::vector<uint32_t> mem;
  long micro = 0;
  long timeouts = 0;
  long first_req_tick = -1, first_req_micro = -1;
  long last_txn_tick = -1, last_txn_micro = -1;
  long misaligned = 0, outside_window = 0, off_page = 0;
  long final_pc = -1;
  long last_edge_tick = -1;
};

int fails = 0;

void Check(bool ok, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

// Printed in full up to a bound: one broken address makes 512 failures and
// the first twenty of them say the same thing as all of them.
constexpr int kFailuresPrinted = 20;

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

// The latency the model answers transaction `n` at, in ticks.
long Latency(size_t n) { return 4 + (static_cast<long>(n) * 7) % 23; }

// Runs the machine from reset with the model behind it.
Run Simulate(bool bit0_in_last) {
  Run out;
  out.mem.resize(kWindowWords);
  for (int i = 0; i < kWindowWords; ++i) out.mem[i] = Poison(i, bit0_in_last);

  auto *dut = new Vcadr_machine;
  // The DDR=1 board's configuration exactly.  Change any of these and this is
  // measuring a different board.
  dut->clk = 0;
  dut->rst = 1;
  // `sintr` was driven here and the line is DELETED rather than left: the
  // machine's -XBUS.INTR is its own now --- the display's interrupt ORed with
  // the disk's inside `cadr_machine` --- and it comes out as `sintr_o`.
  // CLAUDE.md's `md` trap is exactly this: a driven input that becomes an
  // output goes on being driveable, and the check goes green with the signal
  // unchecked.
  dut->boards = 32;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->mem_done = 0;
  dut->mem_rdata = kNotAnswering;
  dut->eval();

  int to_last = 0;
  long pending = -1;          // ticks left before the model answers
  bool req_last = false;
  long ack_watch_until = -1;  // armed at an answer, disarmed at -MEMACK
  size_t ack_for_txn = 0;
  long answered_tick = -1;

  for (long t = 0; t < kTicks; ++t) {
    dut->rst = (t < 8);

    dut->mem_done = 0;
    dut->mem_rdata = kNotAnswering;
    if (dut->mem_req) {
      if (out.first_req_tick < 0) {
        out.first_req_tick = t;
        out.first_req_micro = out.micro;
      }
      if (!req_last) pending = Latency(out.txns.size());
      if (pending > 0) --pending;
      if (pending == 0) {
        Txn x;
        x.tick = t;
        x.micro = out.micro;
        x.addr = dut->mem_addr;
        x.write = dut->mem_write != 0;
        x.ack_delay = -1;
        const long w =
            (static_cast<long>(x.addr) - static_cast<long>(kMainBase)) / 4;
        if ((x.addr & 3u) != 0) ++out.misaligned;
        if (w < 0 || w >= kPageWords) ++out.off_page;
        if (w >= 0 && w < kWindowWords && (x.addr & 3u) == 0) {
          if (x.write) {
            out.mem[w] = dut->mem_wdata;
            x.data = dut->mem_wdata;
          } else {
            dut->mem_rdata = out.mem[w];
            x.data = out.mem[w];
          }
        } else {
          ++out.outside_window;
          x.data = x.write ? dut->mem_wdata : kNotAnswering;
        }
        dut->mem_done = 1;
        pending = -1;
        answered_tick = t;
        ack_for_txn = out.txns.size();
        // -MEMACK cannot be more than a microcycle from the answer; 64 ticks
        // is twice the longest microcycle this program runs.
        ack_watch_until = t + 64;
        out.txns.push_back(x);
        out.last_txn_tick = t;
        out.last_txn_micro = out.micro;
      }
    } else {
      pending = -1;
    }
    req_last = dut->mem_req != 0;

    dut->clk = 1;
    dut->eval();

    if (ack_watch_until >= 0) {
      if (!dut->n_memack_o) {
        out.txns[ack_for_txn].ack_delay = t - answered_tick;
        ack_watch_until = -1;
      } else if (t > ack_watch_until) {
        ack_watch_until = -1;
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
  dut->final();
  delete dut;
  return out;
}

// Everything both configurations must satisfy on their own.
void CheckRun(const Run &r, bool bit0, char name) {
  std::printf("\nconfiguration %c: page 0 poisoned, bit 0 %s\n", name,
              bit0 ? "SET in word 255 and clear in the other 255"
                   : "clear in all 256 words");

  Check(r.txns.size() == 512, "%c: %zu DDR transactions, wanting 512", name,
        r.txns.size());
  long reads = 0, writes = 0;
  for (const Txn &x : r.txns) (x.write ? writes : reads)++;
  Check(reads == 256, "%c: %ld reads, wanting 256", name, reads);
  Check(writes == 256, "%c: %ld writes, wanting 256", name, writes);
  Check(r.misaligned == 0, "%c: %ld transactions were not word-aligned", name,
        r.misaligned);
  Check(r.outside_window == 0,
        "%c: %ld transactions landed outside the %d-word window", name,
        r.outside_window, kWindowWords);
  Check(r.off_page == 0,
        "%c: %ld of them landed outside page 0, %08x..%08x", name,
        r.off_page, kMainBase, kMainBase + 4u * (kPageWords - 1));

  // THE ADDRESS SEQUENCE, FROM THE PROGRAM AND NOT FROM THE DUT.
  // PAGE-0-PARITY-FIX walks physical 0..377 in order, reading each word and
  // writing it straight back, so all 512 addresses are known before the
  // machine runs: base + 4i, twice, read first.
  for (int i = 0; i < kPageWords && 2 * i + 1 < static_cast<int>(r.txns.size());
       ++i) {
    const Txn &rd = r.txns[2 * i];
    const Txn &wr = r.txns[2 * i + 1];
    const uint32_t want_addr = kMainBase + 4u * i;
    Check(!rd.write && rd.addr == want_addr,
          "%c: transaction %d is a %s of %08x, wanting a read of %08x", name,
          2 * i, rd.write ? "write" : "read", rd.addr, want_addr);
    Check(wr.write && wr.addr == want_addr,
          "%c: transaction %d is a %s of %08x, wanting a write of %08x", name,
          2 * i + 1, wr.write ? "write" : "read", wr.addr, want_addr);
    Check(rd.data == Poison(i, bit0),
          "%c: the read of word %d returned %08x, wanting the poison %08x",
          name, i, rd.data, Poison(i, bit0));
    Check(wr.data == rd.data,
          "%c: word %d was read as %08x and written back as %08x, so the copy "
          "is not the identity", name, i, rd.data, wr.data);
  }

  // WHERE -MEMACK LANDS RELATIVE TO THE ANSWER.  Not muir's instant --- a DDR
  // answering at a delay of its own puts it somewhere muir never did --- but
  // the rule muir's instants obey, on every one of the 512.
  for (const Txn &x : r.txns) {
    const long want_delay = x.write ? kAckAfterWrite : kAckAfterRead;
    Check(x.ack_delay == want_delay,
          "%c: the %s of %08x was answered at tick %ld and -MEMACK fell %ld "
          "ticks later, wanting %ld", name, x.write ? "write" : "read", x.addr,
          x.tick, x.ack_delay, want_delay);
  }

  // PAGE 0 AFTERWARDS.  Every word of the window is its poison again: the 256
  // the loop touched, because it wrote back what it read, and the rest
  // because nothing went near them.
  long changed = 0, first_changed = -1;
  for (int i = 0; i < kWindowWords; ++i) {
    if (r.mem[i] != Poison(i, bit0)) {
      if (first_changed < 0) first_changed = i;
      ++changed;
    }
  }
  Check(changed == 0,
        "%c: %ld words of the window are not their poison, the first at word "
        "%ld, which holds %08x where the poison is %08x", name, changed,
        first_changed,
        first_changed >= 0 ? r.mem[first_changed] : 0,
        first_changed >= 0 ? Poison(static_cast<int>(first_changed), bit0) : 0);

  // THE MACHINE IS STILL RUNNING.  It waits for a drive that is not there ---
  // the controller answers, and its status says not on line --- and will do
  // so for ever; what it must not do is halt, which is what it did when an
  // unanswered read handed MD the last word of page 0.  The bound is two
  // thousand ticks, which was a couple of NXM timeouts when the polls were
  // ending on the timer at about 850 ticks each and is now some seventy
  // microcycles of a loop that runs at full speed.  A halt is not near it
  // either way: it leaves the last edge sixteen million ticks back.
  Check(kTicks - r.last_edge_tick < 2000,
        "%c: the last clock edge was at tick %ld of %ld, %ld ticks back, so "
        "the machine is not running at the end", name, r.last_edge_tick,
        kTicks, kTicks - r.last_edge_tick);
  Check(r.final_pc != 040, "%c: the machine ended at PC 40, ERROR-DISK-ERROR",
        name);

  Check(r.first_req_micro == kFirstReqMicro,
        "%c: the first memory cycle is at microcycle %ld, wanting %ld", name,
        r.first_req_micro, kFirstReqMicro);
  Check(r.last_txn_tick > 0 && kTicks - r.last_txn_tick > 15000000L,
        "%c: the last DDR transaction is at tick %ld of %ld, leaving too "
        "little quiet afterwards to say the window has closed", name,
        r.last_txn_tick, kTicks);

  std::printf("  poison            injective over %d words, bit 0 clear in "
              "%d of them\n", kPageWords, bit0 ? kPageWords - 1 : kPageWords);
  std::printf("  window watched    %d words, %08x..%08x\n", kWindowWords,
              kMainBase, kMainBase + 4u * (kWindowWords - 1));
  std::printf("  ticks             %ld (%.1f ms of machine time)\n", kTicks,
              kTicks * 5.0 / 1e6);
  std::printf("  microcycles       %ld\n", r.micro);
  std::printf("  first mem_req     microcycle %ld, tick %ld (%.3f ms)\n",
              r.first_req_micro, r.first_req_tick,
              r.first_req_tick * 5.0 / 1e6);
  std::printf("  last transaction  microcycle %ld, tick %ld (%.3f ms)\n",
              r.last_txn_micro, r.last_txn_tick, r.last_txn_tick * 5.0 / 1e6);
  std::printf("  quiet afterwards  %.1f ms with no DDR access at all\n",
              (kTicks - r.last_txn_tick) * 5.0 / 1e6);
  std::printf("  transactions      %zu (%ld reads, %ld writes), every one in "
              "%08x..%08x\n", r.txns.size(), reads, writes, kMainBase,
              kMainBase + 4u * (kPageWords - 1));
  std::printf("  words copied      %d, each read once and written once, the "
              "write carrying the word its own read returned\n", kPageWords);
  std::printf("  DDR latency       %ld..%ld ticks, varying per transaction\n",
              Latency(0), Latency(3));
  std::map<long, long> ack_hist;
  for (const Txn &x : r.txns) ack_hist[x.ack_delay]++;
  std::printf("  -MEMACK after the answer:");
  for (const auto &kv : ack_hist)
    std::printf(" %ld ticks x%ld", kv.first, kv.second);
  std::printf("\n");
  // Two, and they are the boot PROM's two cycles to Xbus space with nothing
  // in it --- not disk polls, which the disk controller answers now, and not
  // memory, which DDR answers.  It read 13,710 before that module landed.
  std::printf("  NXM timeouts      %ld, Xbus space with nothing in it\n",
              r.timeouts);
  std::printf("  final PC          %lo, still running at tick %ld\n",
              r.final_pc, r.last_edge_tick);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  (void)argc;
  (void)argv;

  // THE POISON IS INJECTIVE, ASSERTED.  A collision would make two words
  // indistinguishable and the identity claim weaker than it reads.
  {
    std::set<uint32_t> seen;
    for (int i = 0; i < kWindowWords; ++i) seen.insert(Poison(i, false));
    Check(seen.size() == static_cast<size_t>(kWindowWords),
          "the poison collides: %zu distinct words for %d addresses",
          seen.size(), kWindowWords);
    for (int i = 0; i < kPageWords; ++i) {
      Check((Poison(i, false) & 1u) == 0, "poison word %d has bit 0 set", i);
      Check(Poison(i, false) != kMainBase + 4u * i,
            "poison word %d is its own address", i);
      Check(Poison(i, false) != 0 && Poison(i, false) != 0xFFFFFFFEu &&
                Poison(i, false) != (kNotAnswering & ~1u),
            "poison word %d is a word this harness could produce by accident",
            i);
    }
  }

  Run a = Simulate(false);
  CheckRun(a, false, 'A');
  Run b = Simulate(true);
  CheckRun(b, true, 'B');

  // AND THE TWO RUNS ARE THE SAME RUN.  What page 0 holds must not reach the
  // machine, so setting a bit in it may move nothing but the word that bit is
  // in.  This is the assertion the whole second configuration exists for.
  std::printf("\nA against B, which may differ only in word 255's bit 0\n");
  Check(a.micro == b.micro, "A ran %ld microcycles and B ran %ld", a.micro,
        b.micro);
  Check(a.timeouts == b.timeouts, "A took %ld NXM timeouts and B took %ld",
        a.timeouts, b.timeouts);
  Check(a.first_req_tick == b.first_req_tick,
        "A's first memory cycle is at tick %ld and B's at %ld",
        a.first_req_tick, b.first_req_tick);
  Check(a.last_txn_tick == b.last_txn_tick,
        "A's last transaction is at tick %ld and B's at %ld", a.last_txn_tick,
        b.last_txn_tick);
  Check(a.final_pc == b.final_pc, "A ended at PC %lo and B at PC %lo",
        a.final_pc, b.final_pc);
  Check(a.txns.size() == b.txns.size(),
        "A made %zu transactions and B made %zu", a.txns.size(),
        b.txns.size());
  long differing = 0;
  for (size_t i = 0; i < a.txns.size() && i < b.txns.size(); ++i) {
    const Txn &x = a.txns[i], &y = b.txns[i];
    Check(x.tick == y.tick && x.micro == y.micro && x.addr == y.addr &&
              x.write == y.write && x.ack_delay == y.ack_delay,
          "transaction %zu differs between the runs: A %s %08x at tick %ld, "
          "B %s %08x at tick %ld", i, x.write ? "wrote" : "read", x.addr,
          x.tick, y.write ? "wrote" : "read", y.addr, y.tick);
    if (x.data != y.data) {
      ++differing;
      Check((x.data ^ y.data) == 1u && x.addr == kMainBase + 4u * 255,
            "transaction %zu carries %08x in A and %08x in B, which is not "
            "bit 0 of word 255", i, x.data, y.data);
    }
  }
  Check(differing == 2,
        "%ld transactions carry a different word between the runs, wanting 2 "
        "--- the read of word 255 and the write back of it", differing);
  std::printf("  identical in %zu of %zu transactions, in the microcycle "
              "count, the timeout count, the tick of every transaction and "
              "the final PC\n",
              a.txns.size() - static_cast<size_t>(differing), a.txns.size());
  std::printf("  differing in the 2 that carry word 255, by exactly bit 0\n");

  if (fails) {
    std::fprintf(stderr, "\n%d failure%s\n", fails, fails == 1 ? "" : "s");
    return 1;
  }
  std::printf("\nok\n");
  return 0;
}
