// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE MAP'S TWO ACCESS BITS, TOLD APART.
//
// `build/map_boot.pass` compares a map entry written and then read through,
// across the whole machine, over MIT's boot PROM --- and its own output says
// what it cannot reach: muir refuses the access on 0 of those 600,000
// microcycles, and every map word the boot PROM writes has bits 23 and 22
// alike, so `-VMAOK` is compared only in its permitted direction and the two
// access bits cannot be told apart.  This check reaches that half.
//
// ================================================================
// WHAT THE TWO BITS ARE, AND WHERE THAT COMES FROM
// ================================================================
//
// A second-level map entry is 24 bits.  Bit 23 permits the access at all and
// bit 22 permits a write; the nets are `-PFR` off the 74S04 at VCTL2 1D26 and
// `-PFW` off the 74S00 at VCTL1 1D17, which is where `WRCYC` joins.  muir says
// it twice, once in each engine, and both are quoted rather than paraphrased:
//
//     ../muir/src/machine.rs  Machine::translate
//         write_permitted:  l2_data & (1 << 22) != 0,
//         access_permitted: l2_data & (1 << 23) != 0,
//     ../muir/src/machine.rs  Machine::vm_read / vm_write
//         self.vmaok = t.access_permitted;
//         self.vmaok = t.access_permitted && t.write_permitted;
//     ../muir/src/rtl.rs      Rtl::step
//         let pfr = bit(lvmo as u64, 23);
//         let pfw = !(!bit(lvmo as u64, 22) && self.wrcyc);
//         let vmaok = pfr && pfw;
//
// `Permits()` below is those three lines and nothing else, so the four
// combinations are muir's answer and not a table somebody wrote down:
//
//     bit 23   bit 22   a read        a write
//        0        0     refused       refused
//        0        1     refused       refused     bit 23 gates both
//        1        0     PERMITTED     refused     the asymmetric one
//        1        1     PERMITTED     PERMITTED
//
// **A REFUSAL HAS A SIGNATURE BEYOND ONE FLAG, and the check takes all of
// it.**  `-MEMRQ` off the 9S42 at VCTL1 1E25 is `MEMSTART AND VMAOK OR
// MBUSY`, so a refused reference raises no request, gets no `-MEMACK`, never
// strobes `-LOADMD` and leaves MD standing, and no address ever reaches the
// memory.  Each of those is counted separately below, because a fabric that
// dropped `VMAOK` out of `-MEMRQ` alone would still get the flag right, and
// one that kept it out of the flag alone would still not fetch.
//
// ================================================================
// HOW THE MACHINE IS MADE TO WRITE AN ASYMMETRIC WORD
// ================================================================
//
// **BY ONE FIELD OF ONE MICROINSTRUCTION OF MIT'S OWN BOOT PROM, and this is
// the part to read before believing anything below.**
//
// `SET-UP-FOUR-PAGES` writes four second-level entries, all from no access to
// MAP-ACCESS-CODE 3.  The word written is `VMA<23:0>`, VMA comes from OB, and
// at PROM address `0o274` --- the microcycle the trace shows at PC `0o275`,
// the PC column being the next address and the IR the word just run --- OB is
// built by the byte masker out of nothing but that instruction's own mask
// field:
//
//     ../muir/src/rtl.rs   mskr = ir[4:0];  mskl = (mskr + ir[9:5]) & 0o37
//                          msk  = (~0 >> (31 - mskl)) & (~0 << mskr)
//                          mo   = (msk & rotate_left(m, shift)) | (!msk & a)
//
// On that microcycle `a` is 0 and `m` is all ones, so **OB is the mask
// itself**: `ir[4:0]` = 22 and `ir[9:5]` = 3 give ones from bit 22 to bit 25,
// `0o360000000`.  Bit 25 is `MAPWR1D` at VCTL2 1C15, the enable that makes the
// write a second-level write at all; bits 23 and 22 are the access code; bit
// 24 is spare, the entry being `VMA<23:0>`.  That word goes to A memory and
// the other three entries are built from it, so **one field decides the access
// code of all four**.
//
// Moving the mask's right edge moves the access code and changes nothing else
// about the program:
//
//     ir[4:0]=22  ir[9:5]=3   bits 25..22   entry 0o60000000   code 3  {1,1}
//     ir[4:0]=23  ir[9:5]=2   bits 25..23   entry 0o40000000   code 2  {1,0}
//     ir[4:0]=24  ir[9:5]=1   bits 25..24   entry 0o00000000   code 0  {0,0}
//
// **WHAT THIS COSTS, PLAINLY.**  The `code 3` configuration is MIT's program
// unaltered and is held to muir's trace microcycle for microcycle.  The other
// two are MIT's program with ten bits of one word changed, and **muir has no
// trace of them**: no generator in `golden/` takes a PROM argument, so those
// runs are held to the columns a changed constant cannot move --- the
// instruction stream, the control flow, and the map and permission behaviour
// muir's rule above predicts.  That is weaker than `map_boot`'s comparison and
// stronger than a fabric-only property, and the output says which claim is
// which rather than letting a reader assume.
//
// **AND {0,1} IS NOT REACHABLE THIS WAY.**  A mask is contiguous, so bit 22
// without bit 23 would need bits {25,22} and cannot be one field; reaching it
// wants a microcode fragment of somebody's own, which nothing here has.  It
// costs less than it looks: {0,1} and {0,0} behave identically in a correct
// machine, and every mutation aimed at the two bits --- read permission taken
// from the write bit, the two swapped --- turns the `code 2` configuration's
// permitted reads into refusals and is caught there.  Stated on the output so
// that the gap is read and not noticed.
//
// **THE PATCH IS NOT TRUSTED, IT IS READ BACK.**  Two things could leave the
// run testing nothing: the patched word might not reach the fabric's PROM, and
// the machine might not write the entry the patch predicts.  Both are read out
// of the machine itself over `con_ro_addr`/`con_ro_data`, the console's
// readout window, which reaches the boot PROM and both levels of the map --- so
// if the field positions above were wrong the check fails naming the word it
// found instead of passing on a program that did something else.
//
// ================================================================
// WHAT DRIVES THE DUT
// ================================================================
//
// `tb/cadr_map_boot_tb.cpp`'s shape: the whole machine from reset, nothing
// driven nearer than `mem_req`/`mem_done`, a store keyed by `mem_addr` with
// page 0 holding muir's zeros and every other address a poison injective in
// it.  The acknowledgement instants come from the trace's own `ack` column.
// `device_ack` is low: the disk controller inside the machine answers the boot
// PROM's polls for itself.
//
// `MEMSTART` and `WRCYC` say which microcycles attempted an access and which
// way.  Both are registered off the microinstruction at the boundary ---
// `memstart <= memop`, `wrcyc <= memwr` --- so they are UPSTREAM of the map
// and no mutation of the permission logic can move them.  That is what makes
// it safe to key the accounting off the DUT here: CLAUDE.md's rule is that
// keying a stimulus off the DUT is dangerous only when it hands over something
// a correct DUT could plausibly be right about, and the instruction stream is
// compared against muir on the same run.

#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

constexpr long kTickNs = 5;
constexpr int kXbusAckNs = 60;

// cadr_ddr_map::MAIN_BASE, and the page the parity loop walks.
constexpr uint32_t kMainBase = 0x18000000u;
constexpr int kPageWords = 256;

// The console readout window's own selectors out of `cadr_microcycle.sv`:
// `RO_PROM`, `RO_MAP2`, and the address it reads as "no memory".
constexpr uint32_t kRoProm = 1u;
constexpr uint32_t kRoMap1 = 7u;
constexpr uint32_t kRoMap2 = 8u;
constexpr uint32_t kRoNone = 0x3FFFFu;

// The microinstruction the patch moves, and what MIT put there.
constexpr int kPatchAddr = 0274;
constexpr uint64_t kPatchOriginal = 0x18020c993076ull;

// The four entries `SET-UP-FOUR-PAGES` writes, the physical page each carries
// and the level-2 index each lands at.  Taken from the trace --- muir writes
// 0o60000000, 0o60036777, 0o60037766 and 0o60000001 at MD 0, 0o400, 0o1000 and
// 0o1400 --- and asserted below, not assumed.
constexpr uint32_t kEntryPage[4] = {0u, 0x3dffu, 0x3ff6u, 0x1u};
constexpr uint32_t kEntryIndex[4] = {0u, 1u, 2u, 3u};

// THE DIRECTED RUN'S THREE ADDRESSES.  On the microcycle that writes the map
// MD is zero, so the level-1 index is 0 and `MAPI<4:0>` is 0.  The level-1
// entry goes from 0 to 0o37, so the two orderings put the level-2 word at
// index {0,0} = 0 and at {0o37,0} = 992, and the three writes after it land
// at 993, 994 and 995 in either ordering, the level-1 entry being 0o37 by
// then.  993 is the control: it says the level-1 write took effect.
constexpr uint32_t kL1Index = 0u;
constexpr uint32_t kOldBlockIndex = 0u;
constexpr uint32_t kNewBlockIndex = 992u;

// The microcycle the entries are read back at: after the last of them at
// 536,302 and before anything else touches the map, the only other writer
// being the clearing loop at 0o244 which has long finished.
constexpr uint64_t kReadbackAt = 536400;

// The microcycle the parity loop's first bus cycle is at, which is the floor
// the control flow has to reach for any of this to have been exercised.
constexpr uint64_t kFirstBusCycle = 536302;

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

// ------------------------------------------------------------ muir's rule
//
// `../muir/src/rtl.rs`, three lines, transcribed and not restated.
bool Permits(uint32_t l2word, bool write) {
  const bool pfr = (l2word >> 23) & 1u;
  const bool pfw = !(!((l2word >> 22) & 1u) && write);
  return pfr && pfw;
}

// A word that is not zero, not any other word's, and not the address.  The
// poison `tb/cadr_map_boot_tb.cpp` uses, for the reason it gives.
uint32_t Poison(uint32_t byte_addr) {
  const uint32_t w = byte_addr >> 2;
  uint32_t p = (0x9E3779B9u * (w + 1u)) ^ 0xA5A5A5A5u;
  if (p == 0) p = 0xFEEDFACEu;
  return p;
}

int fails = 0;
constexpr int kFailuresPrinted = 24;

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

// One configuration: the mask field the microinstruction is given.
struct Config {
  const char *name;
  const char *what;
  int mskr;        // ir[4:0]
  int len;         // ir[9:5], so the mask is bits mskr .. mskr+len
  bool two_level;  // the mask reaches VMA<26> as well, so both levels write
};

const Config kConfigs[] = {
    {"code 3", "both bits set: a read and a write are both permitted", 22, 3, false},
    {"code 2", "bit 23 alone: a read is permitted and a write is refused", 23, 2, false},
    {"code 0", "neither bit: a read and a write are both refused", 24, 1, false},
    {"two levels",
     "VMA<26> and VMA<25> together, so one microinstruction writes both levels",
     22, 9, true},
};
constexpr int kConfigCount = sizeof kConfigs / sizeof kConfigs[0];

uint64_t PatchedWord(const Config &c) {
  return (kPatchOriginal & ~0x3FFull) |
         (static_cast<uint64_t>(c.len) << 5) | static_cast<uint64_t>(c.mskr);
}

// The mask the byte masker makes from that field, which on this microcycle is
// the whole of OB and so the whole of VMA.
uint32_t MaskOf(const Config &c) {
  const int mskl = (c.mskr + c.len) & 037;
  return (0xFFFFFFFFu >> (31 - mskl)) & (0xFFFFFFFFu << c.mskr);
}

uint32_t EntryWord(const Config &c, int which) {
  return (MaskOf(c) & 0x00FFFFFFu) | kEntryPage[which];
}

// What one configuration measured.
struct Result {
  long attempts_read = 0, attempts_write = 0;
  long permitted_read = 0, permitted_write = 0;
  long refused_read = 0, refused_write = 0;
  long flag_wrong = 0;        // -VMAOK disagreed with muir's rule
  long request_wrong = 0;     // -MEMRQ went out when refused, or not when not
  long md_moved_on_refusal = 0;
  long mem_reads = 0, mem_writes = 0;
  long pc_agreed = 0;
  uint64_t pc_diverged_at = 0;   // 0 if it never did
  uint64_t pc_went_to = 0;       // where the fabric went instead
  uint64_t pc_muir_had = 0;
  long ir_mismatch = 0, md_mismatch = 0, vma_mismatch = 0;
  long trace_denied = 0;         // rows muir itself refused
  uint32_t entry[4] = {0, 0, 0, 0};
  uint64_t prom_word = 0;
  long stray_writes = 0;
  long page0_nonzero = 0;
  uint64_t ran = 0;
};

// Write the boot PROM out with one word replaced.  The destination is the file
// the model was verilated with; `$readmemh` runs when the model first
// evaluates, so this has to happen before `new Vcadr_machine`.
bool WritePatchedProm(const char *src, const char *dst, uint64_t word,
                      uint64_t *found_original) {
  std::FILE *in = std::fopen(src, "r");
  if (!in) {
    std::fprintf(stderr, "cannot read %s: %s\n", src, std::strerror(errno));
    return false;
  }
  std::vector<std::string> lines;
  char buf[64];
  while (std::fgets(buf, sizeof buf, in)) {
    std::string s(buf);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    lines.push_back(s);
  }
  std::fclose(in);
  if (static_cast<int>(lines.size()) <= kPatchAddr) {
    std::fprintf(stderr, "%s has %zu words, wanting more than %d\n", src,
                 lines.size(), kPatchAddr);
    return false;
  }
  *found_original = std::strtoull(lines[kPatchAddr].c_str(), nullptr, 16);
  char out[32];
  std::snprintf(out, sizeof out, "%012" PRIx64, word);
  lines[kPatchAddr] = out;
  std::FILE *o = std::fopen(dst, "w");
  if (!o) {
    std::fprintf(stderr, "cannot write %s: %s\n", dst, std::strerror(errno));
    return false;
  }
  for (const std::string &s : lines) std::fprintf(o, "%s\n", s.c_str());
  std::fclose(o);
  return true;
}

struct Sample {
  uint64_t pc = 0, ir = 0, md = 0, vma = 0;
  uint8_t vmaok = 0, memstart = 0, wrcyc = 0, n_memrq = 1;
};

Result Run(const Config &cfg, const char *trace_path, const char *prom_path,
           const char *src_prom, uint64_t cycles) {
  Result res;

  std::FILE *f = std::fopen(trace_path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", trace_path,
                 std::strerror(errno));
    std::exit(2);
  }

  // The acknowledgement instants, as `tb/cadr_map_boot_tb.cpp` takes them.
  std::vector<uint64_t> ack_for;
  size_t total_rows = 0;
  {
    char line[512];
    std::vector<uint64_t> bus_at, acks;
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "%s: row %zu has the wrong column count\n",
                     trace_path, total_rows);
        std::exit(2);
      }
      acks.push_back(r.v[kAck]);
      if (r.v[kBus]) bus_at.push_back(total_rows);
      ++total_rows;
    }
    ack_for.assign(total_rows, 0);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
    }
  }
  std::rewind(f);
  if (cycles > total_rows) cycles = total_rows;

  const uint64_t patched = PatchedWord(cfg);
  uint64_t was = 0;
  if (!WritePatchedProm(src_prom, prom_path, patched, &was)) std::exit(2);
  Check(was == kPatchOriginal,
        "%s: the boot PROM's word at 0o%o is %012" PRIx64 ", and this check "
        "was written against %012" PRIx64 " --- MIT's program moved under it",
        cfg.name, kPatchAddr, was, kPatchOriginal);

  // The store: page 0 is muir's, zero; everything else is poison.
  std::vector<uint32_t> page0(kPageWords, 0u);
  std::map<uint32_t, uint32_t> elsewhere;

  auto in_page0 = [](uint32_t a) {
    return a >= kMainBase && a < kMainBase + 4u * kPageWords && (a & 3u) == 0;
  };

  auto *dut = new Vcadr_machine;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->con_ro_addr = kRoNone;
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
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n",
                 trace_path);
    std::exit(1);
  }
  Sample prev;

  // The readout window: five words, asked for one at a time once the map has
  // been set up, each held until the echo says the word in `con_ro_data` is
  // the one that was asked for.
  uint32_t ro_want[5] = {
      (kRoProm << 14) | static_cast<uint32_t>(kPatchAddr),
      (kRoMap2 << 14) | kEntryIndex[0], (kRoMap2 << 14) | kEntryIndex[1],
      (kRoMap2 << 14) | kEntryIndex[2], (kRoMap2 << 14) | kEntryIndex[3]};
  if (cfg.two_level) {
    // The directed run asks a different question, so it reads different
    // words: the level-1 entry the same microinstruction wrote, the two
    // level-2 indices the two orderings would put the word at, and one
    // entry of the new block as the control that says the level-1 write
    // took effect at all.
    ro_want[1] = (kRoMap1 << 14) | kL1Index;
    ro_want[2] = (kRoMap2 << 14) | kOldBlockIndex;
    ro_want[3] = (kRoMap2 << 14) | kNewBlockIndex;
    ro_want[4] = (kRoMap2 << 14) | (kNewBlockIndex + 1u);
  }
  uint64_t ro_got[5] = {0, 0, 0, 0, 0};
  int ro_at = 5;   // 5 means "not started"; set to 0 at kReadbackAt

  size_t k = 0;
  bool pc_ok = true;
  bool answered = false;
  bool bus_outstanding = false;
  uint32_t held_rdata = 0;
  long ack_at_tick = 0;
  bool req_seen = false;
  uint64_t md_at_last_edge = 0;

  const long kMaxTicks = static_cast<long>(cycles) * 96 + 4096;
  for (long t = 0; t < kMaxTicks && k < cycles; ++t) {
    if (t == 4) dut->rst = 0;

    dut->con_ro_addr = (ro_at < 5) ? ro_want[ro_at] : kRoNone;

    dut->mem_done = 0;
    dut->mem_rdata = Poison(dut->mem_addr ^ 0x5A5A5A5Au);
    const long answer_tick =
        ack_at_tick - (dut->mem_write ? 0 : kXbusAckNs / kTickNs);
    if (dut->mem_req && bus_outstanding && t >= answer_tick) {
      if (!answered) {
        answered = true;
        const uint32_t a = dut->mem_addr;
        const bool wr = dut->mem_write != 0;
        const bool here = in_page0(a);
        const int w = here ? static_cast<int>((a - kMainBase) / 4) : -1;
        if (wr) {
          ++res.mem_writes;
          if (here) {
            page0[w] = dut->mem_wdata;
          } else {
            ++res.stray_writes;
            elsewhere[a] = dut->mem_wdata;
          }
        } else {
          ++res.mem_reads;
          if (here) {
            held_rdata = page0[w];
          } else {
            auto it = elsewhere.find(a);
            held_rdata = (it != elsewhere.end()) ? it->second : Poison(a);
          }
        }
      }
      if (!dut->mem_write) dut->mem_rdata = held_rdata;
      dut->mem_done = 1;
    }

    dut->clk = 1;
    dut->eval();

    if (bus_outstanding && !dut->mem_req && !dut->dev_rq && t > ack_at_tick)
      bus_outstanding = false;

    // -MEMRQ low at any tick of the microcycle means a request went out.
    if (!dut->n_memrq_o) req_seen = true;

    if (ro_at < 5 && dut->con_ro_echo == ro_want[ro_at]) {
      ro_got[ro_at] = dut->con_ro_data;
      ++ro_at;
    }

    if (dut->clock_edge) {
      const Row &r = cur;
      if (r.v[kNVmaok]) ++res.trace_denied;

      // THE INSTRUCTION STREAM IS MIT'S.  A changed constant cannot move the
      // control flow, so PC must agree with muir's trace; where it stops
      // agreeing is reported and not exempted.
      if (pc_ok) {
        if (prev.pc == r.v[kPc]) {
          ++res.pc_agreed;
        } else {
          pc_ok = false;
          res.pc_diverged_at = r.v[kCycle];
          res.pc_went_to = prev.pc;
          res.pc_muir_had = r.v[kPc];
        }
      }
      // The word fetched is the word in the PROM: muir's everywhere but at the
      // one address, and the patch there.
      // Gated on the control flow still agreeing: past a divergence the two
      // machines are at different addresses and a fetched word says nothing.
      if (pc_ok && prev.ir != r.v[kIr] &&
          !(prev.ir == patched && r.v[kIr] == kPatchOriginal))
        ++res.ir_mismatch;
      if (pc_ok) {
        if (prev.md != r.v[kMd]) ++res.md_mismatch;
        if (prev.vma != r.v[kVma]) ++res.vma_mismatch;
      }

      // ---- THE ACCESS THE MICROCYCLE JUST ENDED ATTEMPTED.
      //
      // `MEMSTART` is up for the whole of it and `WRCYC` says which way.  The
      // entry every one of them goes through carries this configuration's two
      // bits --- asserted from the readout below, not assumed --- so muir's
      // rule gives the answer for all of them from the one word.
      // The directed run wrecks the map on purpose --- the level-1 entry it
      // writes sends every later lookup into a block of zeros --- so the
      // permission accounting is not asked of it.  What it measures is which
      // index the level-2 write landed at, read back below.
      if (prev.memstart && !cfg.two_level) {
        const bool write = prev.wrcyc != 0;
        const bool want = Permits(EntryWord(cfg, 0), write);
        if (write) {
          ++res.attempts_write;
          if (want) ++res.permitted_write; else ++res.refused_write;
        } else {
          ++res.attempts_read;
          if (want) ++res.permitted_read; else ++res.refused_read;
        }
        if ((prev.vmaok != 0) != want) {
          ++res.flag_wrong;
          Check(false,
                "%s: microcycle %" PRIu64 " attempted a %s through an entry of "
                "%06x and -VMAOK says %s where muir's rule says %s",
                cfg.name, r.v[kCycle], write ? "write" : "read",
                EntryWord(cfg, 0), prev.vmaok ? "permitted" : "refused",
                want ? "permitted" : "refused");
        }
        if (req_seen != want) {
          ++res.request_wrong;
          Check(false,
                "%s: microcycle %" PRIu64 " attempted a %s that muir's rule %s "
                "and -MEMRQ %s",
                cfg.name, r.v[kCycle], write ? "write" : "read",
                want ? "permits" : "refuses",
                req_seen ? "went out" : "did not go out");
        }
        // A refused reference never strobes -LOADMD, so MD stands.  Compared
        // only on a refused READ: a write leaves MD alone whatever happens,
        // so it would pass for the wrong reason.
        if (!want && !write && prev.md != md_at_last_edge)
          ++res.md_moved_on_refusal;
      }
      req_seen = false;
      md_at_last_edge = prev.md;

      if (r.v[kBus]) {
        bus_outstanding = true;
        answered = false;
        ack_at_tick =
            t + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
      }

      ++k;
      if (k == kReadbackAt) ro_at = 0;
      if (k < cycles && !read_next(cur)) {
        std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu of %" PRIu64 "\n",
                     trace_path, k, cycles);
        std::exit(1);
      }
    }

    dut->clk = 0;
    dut->eval();
    prev.pc = dut->pc;
    prev.ir = dut->ir;
    prev.md = dut->md;
    prev.vma = dut->vma;
    prev.vmaok = dut->vmaok;
    prev.memstart = dut->memstart;
    prev.wrcyc = dut->wrcyc;
    prev.n_memrq = dut->n_memrq_o;
  }

  res.ran = k;
  res.prom_word = ro_got[0];
  for (int i = 0; i < 4; ++i) res.entry[i] = static_cast<uint32_t>(ro_got[1 + i]);
  for (int i = 0; i < kPageWords; ++i)
    if (page0[i] != 0) ++res.page0_nonzero;
  Check(ro_at == 5,
        "%s: the console readout never answered; %d of 5 words came back",
        cfg.name, ro_at < 5 ? ro_at : 5);

  dut->final();
  delete dut;
  std::fclose(f);
  return res;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  // One argument is the trace, as `mutations/run.py` invokes every check
  // here.  The two PROM images live beside it: the source is muir's own
  // `boot_prom.hex` and the patched copy is the file the model was verilated
  // with.  The Makefile names all three so that nothing depends on a layout.
  const char *trace = (argc > 1) ? argv[1] : "build/rtl.golden";
  std::string dir(trace);
  const size_t slash = dir.find_last_of('/');
  dir = (slash == std::string::npos) ? std::string(".") : dir.substr(0, slash);
  const std::string prom_default = dir + "/map_access_prom.hex";
  const std::string src_default = dir + "/boot_prom.hex";
  const char *prom = (argc > 2) ? argv[2] : prom_default.c_str();
  const char *src = (argc > 3) ? argv[3] : src_default.c_str();
  const uint64_t cycles = (argc > 4) ? std::strtoull(argv[4], nullptr, 0) : 600000;

  Result r[kConfigCount];
  for (int i = 0; i < kConfigCount; ++i)
    r[i] = Run(kConfigs[i], trace, prom, src,
               kConfigs[i].two_level ? 537000 : cycles);

  // ---------------------------------------------------------------- what held
  for (int i = 0; i < kConfigCount; ++i) {
    const Config &c = kConfigs[i];
    const Result &x = r[i];
    const uint32_t word = EntryWord(c, 0);

    // The patch reached the fabric, and the machine wrote the entry it was
    // meant to.  Without these two the rest of the configuration is a test of
    // whatever the machine happened to do.
    Check(x.prom_word == PatchedWord(c),
          "%s: the fabric's boot PROM holds %012" PRIx64 " at 0o%o, wanting "
          "%012" PRIx64,
          c.name, x.prom_word, kPatchAddr, PatchedWord(c));

    // ---- THE DIRECTED RUN, which asks one question and not the others.
    //
    // ONE MICROINSTRUCTION WRITING BOTH LEVELS.  `Rtl::step` computes `adr1`
    // BEFORE it performs the level-1 write, so it uses the OLD level-1 entry;
    // `Machine::write_map` re-reads `self.l1_map[l1_index]` AFTER, so it uses
    // the NEW one.  muir's two engines therefore disagree, and neither trace
    // can see it: WMAPD with both VMA<26> and VMA<25> occurs on 0 of the
    // 600,000 microcycles of the boot PROM and 0 of the band's 2,800,000, and
    // no VMA-WRITE-MAP in MIT's whole microcode names both enables.  This
    // measures which one the fabric does.
    if (c.two_level) {
      Check(x.entry[0] == 037,
            "the level-1 entry holds %u after a write of 0o37, so the "
            "microinstruction did not write level 1 at all", x.entry[0]);
      Check(x.entry[3] == EntryWord(kConfigs[0], 1),
            "the control entry at %u holds %06x, wanting %06x --- the later "
            "writes did not land in the new block, so this run measures "
            "nothing", kNewBlockIndex + 1u, x.entry[3],
            EntryWord(kConfigs[0], 1));
      const bool old_block = x.entry[1] == 0xC00000u;
      const bool new_block = x.entry[2] == 0xC00000u;
      Check(old_block != new_block,
            "the level-2 word 0xc00000 is at index %u:%s and at index %u:%s, "
            "which is neither ordering", kOldBlockIndex,
            old_block ? " yes" : " no", kNewBlockIndex,
            new_block ? " yes" : " no");
      Check(old_block,
            "the level-2 write landed in the NEW level-1 block, where "
            "Rtl::step --- the engine every golden trace comes from and the "
            "one this fabric is held to --- puts it in the OLD one");
      continue;
    }

    for (int e = 0; e < 4; ++e)
      Check(x.entry[e] == EntryWord(c, e),
            "%s: second-level entry %u holds %06x, wanting %06x --- the "
            "machine did not write the map word the patch predicts",
            c.name, kEntryIndex[e], x.entry[e], EntryWord(c, e));

    // MIT's program, taking MIT's path.
    Check(x.ir_mismatch == 0,
          "%s: %ld microcycles fetched a word that is neither muir's nor the "
          "patch", c.name, x.ir_mismatch);
    Check(x.pc_agreed >= static_cast<long>(kFirstBusCycle),
          "%s: PC agreed with muir for %ld microcycles, which does not reach "
          "the first bus cycle at %" PRIu64, c.name, x.pc_agreed,
          kFirstBusCycle);

    // The property.
    Check(x.flag_wrong == 0,
          "%s: -VMAOK disagreed with muir's rule on %ld attempted accesses",
          c.name, x.flag_wrong);
    Check(x.request_wrong == 0,
          "%s: -MEMRQ disagreed with the permission on %ld attempted accesses",
          c.name, x.request_wrong);
    Check(x.md_moved_on_refusal == 0,
          "%s: MD moved across %ld refused reads; a refusal never strobes "
          "-LOADMD", c.name, x.md_moved_on_refusal);
    Check(x.stray_writes == 0,
          "%s: %ld words were written outside page 0", c.name, x.stray_writes);

    // THE PROPERTY HAS TO BE LIVE.  A configuration whose refusals never
    // happen, or whose permitted accesses never happen, passes a fabric that
    // does the wrong thing everywhere.
    if (Permits(word, false)) {
      Check(x.permitted_read > 0,
            "%s permits a read and the run made none", c.name);
      Check(x.mem_reads > 0,
            "%s permits a read and the memory was never asked for a word",
            c.name);
    } else {
      Check(x.refused_read > 0,
            "%s refuses a read and the run attempted none", c.name);
      Check(x.mem_reads == 0,
            "%s refuses every read and the memory answered %ld of them",
            c.name, x.mem_reads);
    }
    if (Permits(word, true)) {
      Check(x.permitted_write > 0,
            "%s permits a write and the run made none", c.name);
      Check(x.mem_writes > 0,
            "%s permits a write and the memory was never given a word", c.name);
    } else {
      Check(x.mem_writes == 0,
            "%s refuses every write and the memory took %ld of them", c.name,
            x.mem_writes);
      // A configuration that refuses READS never gets as far as a write: the
      // program is stopped by the first refused read.  Only the one that
      // permits reads can show a refused write, and that is the asymmetry
      // this file exists for, demanded unconditionally below.
      if (Permits(word, false))
        Check(x.refused_write > 0,
              "%s permits a read and refuses a write, and the run attempted "
              "no write", c.name);
    }
  }

  // The control: MIT's own program, unaltered, against muir's own trace.
  Check(r[0].pc_agreed == static_cast<long>(r[0].ran),
        "the unaltered program's PC agreed with muir for %ld of %" PRIu64
        " microcycles", r[0].pc_agreed, r[0].ran);
  Check(r[0].md_mismatch == 0,
        "the unaltered program disagreed with muir's MD on %ld microcycles",
        r[0].md_mismatch);
  Check(r[0].vma_mismatch == 0,
        "the unaltered program disagreed with muir's VMA on %ld microcycles",
        r[0].vma_mismatch);
  Check(r[0].page0_nonzero == 0,
        "%ld words of page 0 are not zero at the end of the unaltered run",
        r[0].page0_nonzero);
  Check(r[0].trace_denied == 0,
        "muir's own trace refuses %ld accesses, so this check is no longer the "
        "only thing reaching that half", r[0].trace_denied);

  // THE ASYMMETRY ITSELF, which is the whole reason the file exists: one
  // configuration in which a read through an entry succeeds and a write
  // through the SAME entry does not.
  // AND THE MACHINE SEES THE REFUSAL.  `PAGE-0-PARITY-FIX` puts
  // `JUMP-IF-PAGE-FAULT ERROR-PAGE-FAULT` after its read and after its write
  // (`sys/ucadr/promh.text:397-403`), so a refused read and a refused write
  // both leave for the same address.  That is the flag reaching a jump
  // condition rather than a testbench, and it is the shape the board halts in.
  Check(r[1].pc_went_to != 0 && r[1].pc_went_to == r[2].pc_went_to,
        "the refused write left for 0o%" PRIo64 " and the refused read for "
        "0o%" PRIo64 "; MIT's two JUMP-IF-PAGE-FAULTs go to one place",
        r[1].pc_went_to, r[2].pc_went_to);
  Check(r[1].pc_went_to != r[1].pc_muir_had,
        "the refused write went where muir went, so nothing was refused");

  Check(r[1].permitted_read > 0 && r[1].refused_write > 0,
        "no configuration both read through an entry and was refused a write "
        "through it, so the two access bits are still not told apart");

  if (fails) {
    std::fprintf(stderr, "\nFAILED: %d\n", fails);
    return 1;
  }

  std::printf(
      "ok: the map's two access bits, told apart on the whole machine\n"
      "    MIT's boot PROM with ONE field of ONE microinstruction moved --- the\n"
      "    mask at PROM 0o%o, which is the whole of the map word\n"
      "    SET-UP-FOUR-PAGES writes --- run four times against a real memory\n"
      "    keyed by mem_addr, poisoned outside page 0 injectively in the\n"
      "    address, with nothing driven nearer than mem_req/mem_done\n",
      kPatchAddr);
  for (int i = 0; i < kConfigCount; ++i) {
    const Config &c = kConfigs[i];
    const Result &x = r[i];
    if (c.two_level) {
      std::printf(
          "\n    %s --- %s\n"
          "      level-1 entry %u went to 0o%o, the level-2 word 0xc00000 is at\n"
          "        index %u and not at %u, and the control entry at %u holds\n"
          "        %06x --- so the fabric indexes the level-2 write by the OLD\n"
          "        level-1 entry, which is Rtl::step's ordering and not\n"
          "        Machine::write_map's.  Neither reference trace reaches this\n"
          "        and no VMA-WRITE-MAP in MIT's microcode asks for it.\n",
          c.name, c.what, kL1Index, x.entry[0], kOldBlockIndex,
          kNewBlockIndex, kNewBlockIndex + 1u, x.entry[3]);
      continue;
    }
    std::printf(
        "\n    %s --- %s\n"
        "      the word %012" PRIx64 " read back out of the fabric's own PROM,\n"
        "        and the four entries %06x %06x %06x %06x read back out of the\n"
        "        machine's own level-2 map over the console's readout window\n"
        "      %ld microcycles of PC agreeing with muir%s\n"
        "      %ld reads attempted, %ld permitted and %ld refused;\n"
        "        %ld writes attempted, %ld permitted and %ld refused\n"
        "      the memory was asked for %ld words and given %ld\n"
        "      -VMAOK agreed with muir's rule on all %ld attempts, -MEMRQ went\n"
        "        out on exactly the permitted ones, and MD stood across every\n"
        "        refused read\n",
        c.name, c.what, x.prom_word, x.entry[0], x.entry[1], x.entry[2],
        x.entry[3], x.pc_agreed,
        x.pc_diverged_at ? " before it parted" : " --- all of them",
        x.attempts_read, x.permitted_read, x.refused_read, x.attempts_write,
        x.permitted_write, x.refused_write, x.mem_reads, x.mem_writes,
        x.attempts_read + x.attempts_write);
    if (x.pc_diverged_at)
      std::printf(
          "      it parts from muir at microcycle %" PRIu64 ", going to PC 0o%"
          PRIo64 " where\n"
          "        muir has 0o%" PRIo64 " --- MIT's own `JUMP-IF-PAGE-FAULT\n"
          "        ERROR-PAGE-FAULT`, which PAGE-0-PARITY-FIX puts after both its\n"
          "        read and its write (sys/ucadr/promh.text:397-403).  So the\n"
          "        refusal reached the microcode's own jump condition and not\n"
          "        merely a flag a check reads.  Nothing past there is compared\n"
          "        to muir\n",
          x.pc_diverged_at, x.pc_went_to, x.pc_muir_had);
  }
  std::printf(
      "\n    NOT REACHED BY THIS CHECK, and said here rather than left to be\n"
      "      noticed: {bit 23 clear, bit 22 set} is not writable by moving one\n"
      "      contiguous mask, so the fourth combination is untested.  It\n"
      "      behaves identically to {0,0} in a correct machine, and every\n"
      "      mutation aimed at the two bits turns code 2's permitted reads into\n"
      "      refusals and is caught there.\n"
      "    AND THE TWO PATCHED RUNS ARE NOT COMPARED TO muir PAST THE PATCH:\n"
      "      no generator in golden/ takes a PROM, so what holds them is the\n"
      "      instruction stream, the control flow, and muir's own permission\n"
      "      rule quoted at the top of this file.\n");
  return 0;
}
