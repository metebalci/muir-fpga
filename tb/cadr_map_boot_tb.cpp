// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE MAP, WRITTEN AND THEN READ THROUGH, AGAINST A REAL MEMORY.
//
// `cadr_machine` from reset on MIT's boot PROM, held to muir's own `rtl`
// engine microcycle for microcycle exactly as `build/machine.pass` is --- and
// with ONE thing changed, which is the whole reason this file exists: the word
// `mem_rdata` hands back is fetched from a store keyed by `mem_addr`, not
// handed over keyed by the trace's row.
//
// WHY THAT ONE CHANGE IS A DIFFERENT CHECK.  `tb/cadr_machine_tb.cpp` answers
// every main-memory read with `rdata_for[row]`, muir's own MD column for the
// microcycle the machine is on.  The word is therefore right whatever address
// the fabric put on the bus, so **the physical address the map produced is
// never used to fetch anything and a mistranslation is invisible there**.  It
// is invisible in `build/ddr_boot.pass` from the other side: that check has a
// real store and asserts the address sequence, but it has no muir reference at
// all, so it cannot compare -VMAOK, MD, or the instant anything happens.
// Neither of them runs the two together.  This does.
//
// WHAT THE BOOT PROM ACTUALLY DOES WITH THE MAP, MEASURED AGAINST muir AND
// NOT ASSUMED.  CLAUDE.md said "rtl.golden is the boot PROM, which never uses
// the map that way".  It does.  `SET-UP-FOUR-PAGES` writes FOUR second-level
// entries and the first main-memory cycle follows three microcycles after the
// last of them:
//
//     microcycle 536290   l2 <- 0o60000000   physical page 0        MAP-ACCESS-CODE 3
//     microcycle 536293   l2 <- 0o60036777   physical page 0o36777        the same
//     microcycle 536297   l2 <- 0o60037766   physical page 0o37766        the same
//     microcycle 536299   l2 <- 0o60000001   physical page 1              the same
//     microcycle 536302   the first bus cycle, through the first of them
//
// Every one of those entries goes from ZERO --- no access --- to access code
// 3, and the entry the parity loop then reads through was written TWELVE
// microcycles earlier.  That is the same shape as `PDL-BUFFER-REFILL`'s
// `((VMA-WRITE-MAP) IOR M-PGF-TEM ...)` seven microcycles ahead of `P-R-1`,
// which is where the board halted on 2026-09-10, and it is why this check can
// stand on the boot PROM instead of needing the band and a pack.  The gap is
// re-derived from the trace at every run below and printed, so that a
// reference which stopped exercising it would say so rather than pass.
//
// WHAT IS IN THE STORE, AND WHY PAGE 0 IS NOT POISONED.  muir's main memory is
// zero where this program reads it, and the reference is muir, so page 0 ---
// physical 0..0o377, the only main memory `promh.text`'s PAGE-0-PARITY-FIX
// touches --- holds zero here too and the comparison against muir is exact,
// with no exemption anywhere.  EVERY OTHER ADDRESS holds a poison injective in
// the address and never zero.  A correct fabric therefore never reads poison;
// one whose map sends a read a page wide takes a word that is not muir's and
// MD disagrees on the microcycle it happens.  The injectivity is asserted
// below rather than claimed, because a poison with a collision in it tests
// less than it looks like it does.
//
// AND THE WRITE HALF, which the zero page cannot hold on its own: the parity
// loop writes back what it read, so against a page of zeros a write that
// landed a page wide would put a zero somewhere harmless and read back
// unchanged --- CLAUDE.md's control-store lesson in main memory.  So a write
// anywhere but page 0 is a failure named at the address, and at the end page 0
// must be zero and NOTHING outside it may have been written.  Each of the 256
// words must have been read exactly once and written exactly once, which is
// what closes an aliasing mistranslation INSIDE the page: two virtual pages
// folded onto one physical page read the same word twice and another never.
//
// THE ANSWER IS PLACED WHERE muir PLACED IT.  The acknowledgement instants
// come from the trace's own `ack` column, as `tb/cadr_machine_tb.cpp` places
// them, so MD lands on the row muir's own row-keying rule says and the timing
// under the comparison is muir's.  A memory answering at a delay of its own is
// `ddr_boot`'s question and is not re-asked here; nor are the microcycle
// lengths or the -MEMACK histogram, which `machine.pass` holds.
//
// WHAT DRIVES THE DUT.  Nothing nearer than `mem_req`/`mem_done`.  `device_ack`
// is low and never raised: the disk controller inside the machine answers the
// boot PROM's 16,951 polls for itself.  The drive seam and the block store's
// seam are left at their reset zero, as `tb/cadr_ddr_boot_tb.cpp` leaves them.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <map>
#include <set>
#include <vector>

#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

constexpr long kTickNs = 5;
constexpr int kXbusAckNs = 60;

// cadr_ddr_map::MAIN_BASE, and the page the parity loop walks.
constexpr uint32_t kMainBase = 0x18000000u;
constexpr int kPageWords = 256;

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

// A word that is not zero, not any other word's, and not the address.  Odd
// multiplication is a bijection on 32 bits and the XOR is another, so the
// whole of it is injective; `Injective()` below asserts it over the range this
// run can actually reach rather than trusting the arithmetic.
uint32_t Poison(uint32_t byte_addr) {
  const uint32_t w = byte_addr >> 2;
  uint32_t p = (0x9E3779B9u * (w + 1u)) ^ 0xA5A5A5A5u;
  if (p == 0) p = 0xFEEDFACEu;
  return p;
}

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

int Fail(const Row &r, const char *what, uint64_t got, uint64_t want) {
  if (fails < kFailuresPrinted)
    std::fprintf(stderr,
                 "microcycle %" PRIu64 " (PC %" PRIo64 "): %s is %" PRIx64
                 ", muir says %" PRIx64 "\n",
                 r.v[kCycle], r.v[kPc], what, got, want);
  ++fails;
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // The trace is streamed, not held: it is 84 MB for the boot PROM and the
  // only things needing to be known before their row are the acknowledgement
  // instants and where the map is written.
  std::vector<uint64_t> ack_for;
  std::vector<char> arbitrated;
  size_t total_rows = 0;
  // Microcycles at which muir wrote a SECOND-LEVEL map entry: `WMAPD` with
  // `VMA<25>`, which is `MAPWR1D` at VCTL2 1C15 --- MIT's own enable, taken
  // from the trace and not from a list here.
  std::vector<uint64_t> l2_writes;
  uint64_t first_bus_row = 0;
  bool any_bus = false;
  {
    char line[512];
    std::vector<uint64_t> bus_at, acks;
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "%s: row %zu has the wrong column count\n", path,
                     total_rows);
        return 2;
      }
      acks.push_back(r.v[kAck]);
      if (r.v[kWmapd] && (r.v[kVma] & (1u << 25))) l2_writes.push_back(total_rows);
      if (r.v[kBus]) {
        bus_at.push_back(total_rows);
        if (!any_bus) { first_bus_row = total_rows; any_bus = true; }
      }
      ++total_rows;
    }
    ack_for.assign(total_rows, 0);
    arbitrated.assign(total_rows, 0);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
      // A cycle whose answer is not known at the boundary it started on had to
      // arbitrate for the Unibus first, which this fabric's Xbus half cannot
      // do.  `machine.pass` exempts those microcycles' lengths; nothing here
      // compares a length, so they are only counted.
      if (j != i) for (size_t x = i; x <= j && x < total_rows; ++x) arbitrated[x] = 1;
    }
  }

  if (total_rows == 0) {
    std::printf("skipped: %s carries no microcycles\n", path);
    std::fclose(f);
    return 0;
  }
  std::rewind(f);

  // THE PROPERTY MUST BE LIVE IN THE REFERENCE, and this is what says so.  A
  // trace with no second-level map write, or one whose first memory cycle is
  // nowhere near one, would let every assertion below pass while testing
  // nothing about a map that had just been written.
  Check(!l2_writes.empty(),
        "the reference writes no second-level map entry, so nothing here is a "
        "map that was written and then read through");
  Check(any_bus, "the reference starts no bus cycle");
  //
  // `WMAPD AND VMA<25>` counts every microcycle whose write phase drives the
  // second level, and this program's loop at 0o240 drives it 65,536 times
  // with whatever VMA happens to hold, changing nothing.  What matters is the
  // WINDOW: how many of them fall in the sixty-four microcycles before the
  // machine first reads through the map, and how far ahead the earliest of
  // those is.  `SET-UP-FOUR-PAGES` puts four there, twelve to three
  // microcycles ahead, each taking an entry from no access to MAP-ACCESS-CODE
  // 3 --- `PDL-BUFFER-REFILL`'s own shape, seven microcycles instead of
  // twelve.
  constexpr uint64_t kWindow = 64;
  uint64_t gap_last = 0, gap_first = 0;
  long l2_in_window = 0;
  if (!l2_writes.empty() && any_bus) {
    for (uint64_t w : l2_writes) {
      if (w >= first_bus_row || first_bus_row - w > kWindow) continue;
      ++l2_in_window;
      if (l2_in_window == 1) gap_first = first_bus_row - w;
      gap_last = first_bus_row - w;
    }
    Check(l2_in_window > 0,
          "no second-level map write falls in the %" PRIu64 " microcycles "
          "before the first bus cycle, so nothing here is a map entry read "
          "through soon after it was written",
          kWindow);
  }

  // The store.  Page 0 is muir's --- zero --- and everything else is poison.
  // Held as a page and a map rather than as a window, so that a mistranslation
  // to ANY of the 2^32 addresses is answered and named instead of falling off
  // the end of an array.
  std::vector<uint32_t> page0(kPageWords, 0u);
  std::map<uint32_t, uint32_t> elsewhere;   // what was written outside page 0
  {
    std::set<uint32_t> seen;
    for (int i = 0; i < 4096; ++i) {
      const uint32_t p = Poison(kMainBase + 4u * (kPageWords + i));
      Check(p != 0, "the poison is zero at word %d", kPageWords + i);
      Check(seen.insert(p).second, "the poison collides at word %d",
            kPageWords + i);
    }
  }

  auto in_page0 = [](uint32_t a) {
    return a >= kMainBase && a < kMainBase + 4u * kPageWords && (a & 3u) == 0;
  };

  auto *dut = new Vcadr_machine;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;      // Machine::new: MAIN_WORDS >> 16
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->eval();

  auto read_next = [&](Row &r) {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      return ParseRow(line, r);
    }
    return false;
  };

  struct Sample {
    uint64_t pc, ir, lpc, opc, st, a, m, alu, r, ob, q, dc, lc, vma, md, vmaok,
        jcond, nop, pcs1, pcs0, iwrited, promdis;
  };
  auto take = [&]() {
    return Sample{dut->pc,  dut->ir,   dut->lpc,  dut->opc, dut->st,
                  dut->a,   dut->m,    dut->alu,  dut->r,   dut->ob,
                  dut->q,   dut->dc,   dut->lc,   dut->vma, dut->md,
                  dut->vmaok, dut->jcond, dut->nop, dut->pcs1, dut->pcs0,
                  dut->iwrited, dut->promdisable};
  };

  Row cur;
  if (!read_next(cur)) {
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n", path);
    return 1;
  }
  Sample prev = take();

  size_t k = 0;
  int bad = 0;
  bool bus_outstanding = false;
  // ONE TRANSACTION PER BUS CYCLE.  `mem_req` stands until the bridge has
  // taken the word, so `mem_done` is held up for more than one tick and the
  // store must be touched exactly once or a write lands twice and a read is
  // counted twice.  Armed at the grant edge, disarmed at the answer.
  bool answered = false;
  uint32_t held_rdata = 0;
  long ack_at_tick = 0;
  long reads = 0, writes = 0, off_page = 0, misaligned = 0, arb = 0;
  std::vector<int> read_count(kPageWords, 0), write_count(kPageWords, 0);
  std::vector<uint32_t> first_stray;   // the addresses that left page 0
  long stray_writes = 0;
  long map_writes_seen = static_cast<long>(l2_writes.size());
  long denied = 0;   // microcycles muir refused the access on

  const long kMaxTicks = static_cast<long>(total_rows) * 96 + 1024;
  for (long t = 0; t < kMaxTicks && k < total_rows; ++t) {
    if (t == 4) dut->rst = 0;

    dut->mem_done = 0;
    // POISON WHILE NOTHING IS ANSWERING, and never a word of the store: a
    // bridge that latched at the wrong instant takes something nothing should
    // ever hold.  It is a function of the address so that it is not one
    // constant either.
    dut->mem_rdata = Poison(dut->mem_addr ^ 0x5A5A5A5Au);
    const long answer_tick =
        ack_at_tick - (dut->mem_write ? 0 : kXbusAckNs / kTickNs);
    if (dut->mem_req && bus_outstanding && t >= answer_tick) {
      if (!answered) {
        answered = true;
        // THE WORD IS FETCHED AT THE ADDRESS THE FABRIC ASKED FOR, which is
        // the whole point of this check.
        const uint32_t a = dut->mem_addr;
        if ((a & 3u) != 0) ++misaligned;
        const bool wr = dut->mem_write != 0;
        const bool here = in_page0(a);
        const int w = here ? static_cast<int>((a - kMainBase) / 4) : -1;
        if (wr) {
          ++writes;
          if (here) {
            page0[w] = dut->mem_wdata;
            ++write_count[w];
          } else {
            ++stray_writes;
            elsewhere[a] = dut->mem_wdata;
            if (first_stray.size() < 4) first_stray.push_back(a);
          }
        } else {
          ++reads;
          if (here) {
            held_rdata = page0[w];
            ++read_count[w];
          } else {
            auto it = elsewhere.find(a);
            held_rdata = (it != elsewhere.end()) ? it->second : Poison(a);
            if (first_stray.size() < 4) first_stray.push_back(a);
          }
        }
        if (!here) {
          ++off_page;
          Check(false,
                "microcycle %zu: the map sent a main-memory %s to %08x, which "
                "is not page 0 (%08x..%08x)",
                k, wr ? "write" : "read", a, kMainBase,
                kMainBase + 4u * (kPageWords - 1));
        }
      }
      if (!dut->mem_write) dut->mem_rdata = held_rdata;
      dut->mem_done = 1;
    }

    dut->clk = 1;
    dut->eval();

    if (bus_outstanding && !dut->mem_req && !dut->dev_rq && t > ack_at_tick)
      bus_outstanding = false;

    if (dut->clock_edge) {
      const Row &r = cur;
      if (prev.pc != r.v[kPc]) bad += Fail(r, "PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) bad += Fail(r, "IR", prev.ir, r.v[kIr]);
      if (prev.lpc != r.v[kLpc]) bad += Fail(r, "LPC", prev.lpc, r.v[kLpc]);
      if (prev.opc != r.v[kOpc]) bad += Fail(r, "OPC", prev.opc, r.v[kOpc]);
      if (prev.st != r.v[kSt]) bad += Fail(r, "ST", prev.st, r.v[kSt]);
      if (prev.lc != r.v[kLc]) bad += Fail(r, "LC", prev.lc, r.v[kLc]);
      if (prev.a != r.v[kA]) bad += Fail(r, "the A bus", prev.a, r.v[kA]);
      if (prev.m != r.v[kM]) bad += Fail(r, "the M bus", prev.m, r.v[kM]);
      if (prev.alu != r.v[kAlu]) bad += Fail(r, "the ALU", prev.alu, r.v[kAlu]);
      if (prev.r != r.v[kR]) bad += Fail(r, "R", prev.r, r.v[kR]);
      if (prev.ob != r.v[kOb]) bad += Fail(r, "OB", prev.ob, r.v[kOb]);
      if (prev.q != r.v[kQ]) bad += Fail(r, "Q", prev.q, r.v[kQ]);
      if (prev.dc != r.v[kDc]) bad += Fail(r, "DC", prev.dc, r.v[kDc]);
      if (prev.vma != r.v[kVma]) bad += Fail(r, "VMA", prev.vma, r.v[kVma]);
      // THE WORD OUT OF A REAL MEMORY, AT THE ADDRESS THE MAP MADE.  This is
      // the one comparison `machine.pass` cannot make: there the word is
      // handed over keyed by the row and is right whatever the address was.
      if (prev.md != r.v[kMd]) bad += Fail(r, "MD", prev.md, r.v[kMd]);
      // The net is -VMAOK, `NAND(-PFR, -PFW)` at VCTL1 1D17: *low* when the
      // access is permitted, the opposite of the logical VMAOK.  This is the
      // access bits of the entry the map just gave, compared to muir's.
      if (prev.vmaok == r.v[kNVmaok])
        bad += Fail(r, "-VMAOK", !prev.vmaok, r.v[kNVmaok]);
      if (r.v[kNVmaok]) ++denied;
      if (prev.jcond != r.v[kJcond]) bad += Fail(r, "JCOND", prev.jcond, r.v[kJcond]);
      if (prev.nop != r.v[kNop]) bad += Fail(r, "NOP", prev.nop, r.v[kNop]);
      if (prev.pcs1 != r.v[kPcs1]) bad += Fail(r, "PCS1", prev.pcs1, r.v[kPcs1]);
      if (prev.pcs0 != r.v[kPcs0]) bad += Fail(r, "PCS0", prev.pcs0, r.v[kPcs0]);
      if (prev.iwrited != r.v[kIwrited])
        bad += Fail(r, "IWRITED", prev.iwrited, r.v[kIwrited]);
      if (prev.promdis != r.v[kPromdis])
        bad += Fail(r, "PROMDISABLE", prev.promdis, r.v[kPromdis]);

      if (r.v[kBus]) {
        bus_outstanding = true;
        answered = false;
        if (arbitrated[k]) ++arb;
        // Rounded up, for the reason `tb/cadr_machine_tb.cpp` gives: muir's
        // acknowledgement is not on the five-nanosecond grid and the fabric
        // can only see it at a tick at or after it.
        ack_at_tick =
            t + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
      }

      ++k;
      if (k < total_rows && !read_next(cur)) {
        std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu of %zu\n", path,
                     k, total_rows);
        return 1;
      }
      if (bad >= kFailuresPrinted) {
        std::fprintf(stderr, "stopping after %d mismatches\n", bad);
        break;
      }
    }

    dut->clk = 0;
    dut->eval();
    prev = take();
  }
  dut->final();
  delete dut;
  std::fclose(f);

  fails += bad;

  Check(k == total_rows, "%zu of %zu microcycles ran", k, total_rows);
  // The program's own shape: one read and one write of each of the 256 words,
  // and nothing else in main memory.  Stated as counts rather than as an
  // address list, so that an aliasing mistranslation INSIDE the page --- two
  // virtual pages folded onto one physical one --- shows up as a word read
  // twice and another never, which an ordered list would report as a wrong
  // address and a count alone would not see at all.
  Check(reads == kPageWords, "%ld main-memory reads, wanting %d", reads,
        kPageWords);
  Check(writes == kPageWords, "%ld main-memory writes, wanting %d", writes,
        kPageWords);
  Check(off_page == 0, "%ld main-memory cycles left page 0", off_page);
  Check(misaligned == 0, "%ld transactions were not word-aligned", misaligned);
  Check(stray_writes == 0, "%ld words were written outside page 0",
        stray_writes);
  Check(elsewhere.empty(), "%zu addresses outside page 0 hold a written word",
        elsewhere.size());
  long read_once = 0, written_once = 0;
  for (int i = 0; i < kPageWords; ++i) {
    if (read_count[i] == 1) ++read_once;
    if (write_count[i] == 1) ++written_once;
    Check(read_count[i] == 1, "physical %o was read %d times, wanting once", i,
          read_count[i]);
    Check(write_count[i] == 1, "physical %o was written %d times, wanting once",
          i, write_count[i]);
    Check(page0[i] == 0,
          "physical %o holds %08x at the end; the parity loop writes back what "
          "it read and muir's memory is zero here",
          i, page0[i]);
  }

  if (fails) {
    std::fprintf(stderr, "\nFAILED: %d\n", fails);
    return 1;
  }
  std::printf(
      "ok: %zu microcycles of the whole machine agree with muir's rtl engine\n"
      "    on MIT's boot PROM, with a REAL memory behind mem_*: the word MD\n"
      "    takes is fetched at the address the map made, not handed over\n"
      "    keyed by the row\n"
      "    PC, IR, LPC, OPC, ST, LC, the A and M buses, the ALU, R, OB, Q, DC,\n"
      "    VMA, MD, -VMAOK, JCOND, NOP, PCS1, PCS0, IWRITED and PROMDISABLE\n"
      "    every microcycle, with no exemption anywhere and %ld exempt rows\n"
      "    the map: %ld microcycles drove the second level, %ld of them in the\n"
      "      sixty-four before the first bus cycle, the earliest %" PRIu64
      " microcycles\n"
      "      ahead of it and the latest %" PRIu64
      " --- a map entry read through soon\n"
      "      after it was written, which is what the board halted on\n"
      "    main memory: %ld reads and %ld writes, %ld of the 256 words read\n"
      "      exactly once and %ld written exactly once, 0 cycles off page 0,\n"
      "      0 words written outside it, page 0 zero at the end\n"
      "    everything outside page 0 is poison injective in the address, so a\n"
      "      read a page wide takes a word muir never had; %ld Unibus\n"
      "      arbitrations counted and not exempted\n"
      "    NOT REACHED BY THIS PROGRAM, and so not checked: muir refuses the\n"
      "      access on %ld of these %zu microcycles, so -VMAOK is compared\n"
      "      only in its PERMITTED direction --- an access wrongly permitted\n"
      "      is invisible here, and every map word the boot PROM writes has\n"
      "      MAP-ACCESS-CODE 3, both bits alike, so the two access bits\n"
      "      cannot be told apart either.  That is the half of the map the\n"
      "      board halted in, and only a program with an asymmetric map word\n"
      "      --- PDL-BUFFER-REFILL's 0o27200352 --- reaches it\n"
      "    not re-asked here, being held elsewhere: the microcycle lengths and\n"
      "      the -MEMACK histogram (machine.pass), a memory answering at a\n"
      "      delay of its own and the address sequence in order (ddr_boot)\n",
      total_rows, 0L, map_writes_seen, l2_in_window, gap_first, gap_last,
      reads, writes, read_once, written_once, arb, denied, total_rows);
  return 0;
}
